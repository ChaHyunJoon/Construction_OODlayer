#!/usr/bin/env python3
"""격자 축을 **현행 세대 스윕에서** 유도해 grid_spec.json 을 쓴다.

왜 재유도하는가
==============
원 설계(dp-oracle-design.md §3)의 구간은 구세대 스윕에서 나왔다. 2026-08-13 저녁 배터리 물리
복구(용량 축소 제거 + stall/derate 켬)로 세계가 갈렸다 — noop 의 battery 완주가 30/30 -> 0/30
으로 뒤집혔고, 자연 방전이 무시할 수준이 되어 SoC 를 떨어뜨리는 것은 주입된 OOD 뿐이다.
옛 구간으로 격자를 깔면 예산의 다수가 도달하지 않는 칸에 들어간다.

2026-08-14 실측 지지집합 (results_4pol, 630행 / 3953 결정, 세대 단일)
-------------------------------------------------------------------
    progress       [0.1853, 0.9105]      (uniq 147)
    soc            [0.0,    0.1000]      (battery 결정 703건에만 있다)
    spare_count    {8, 9, 10, 11, 12}
    agent_pending  {-1, 0, 1, 2, 3, 4}   (-1 = 미기록)
    zone           787건 **전부** root_covered==0 & n_nav_blocked>0  = blk 계열
                   -> `zone_s=cov` 는 이 스트림이 만들지 않는다. UNREACHABLE 로 남는다.

원 설계 대비 의도적 편차 2개 (실행자가 임의로 바꾼 것이 아니라 실측이 강제한 것)
-----------------------------------------------------------------------------
D-a. **`pend_f` 의 정의.** 원문은 "미해결 고장 수" 라고 적었지만 그런 카운터는 이 하니스의
     어디에도 없다(결정 레코드에도 스트림에도 없다). 실제로 존재하고 **fault 축을 실측으로
     가르는** 변수는 `agent_pending`(그 로봇이 지고 있던 일감 수)이다 — firegrid 격자에서
     `agent_pending>0` 이 42 instance 를 완전분리했고, `reference_policy.py:190` 과
     `oracle_macro` 가 둘 다 그 술어를 쓴다. 그래서 `pend_f` 를 `agent_pending` 의 버킷으로
     정의한다. 없는 변수를 지어내는 대신 있는 변수를 이름 붙여 쓴다.

D-b. 그 귀결로 **원문 §3.2 의 가지치기 규칙 `evt=Fault ∧ pend_f=0 → INFEASIBLE` 을 뺀다.**
     원문의 정의("미해결 고장이 없는데 고장 결정")에서는 불가능하지만, D-a 의 정의에서는
     **실재하고 이미 측정된 칸**이다(일감 없는 로봇의 고장 = `faultidle` instance 계열).
     정의를 바꾸고 규칙을 그대로 두면 측정된 칸을 "정의상 불가능" 으로 지우게 된다.

`cell_key` 의 문자열 형식은 계약이다
===================================
`dp_solve._bucket()` 이 첫 성분(prog_b)을 잘라 backward induction 의 버킷으로 쓰고,
`tools/monitor/dp_lane.jl` 의 `dp_cell_key` 가 **같은 문자열**을 Julia 쪽에서 만든다.
형식을 바꾸면 솔버가 조용히 전부 버킷 0 으로 보고, Julia/Python 이 다른 칸을 가리킨다.
그 동치는 `test_cellkey_parity.py` 가 두 구현에 같은 합성 상태를 먹여 기계로 잡는다.
"""
import argparse
import collections
import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))

# 축 순서는 **고정**이다. cell_key 가 이 순서로 문자열을 만든다.
AXES = ("prog_b", "soc_b", "spares_b", "pend_f", "zone_s", "evt")

ZONE_STATES = ("none", "blk", "cov")
EVENTS = ("Battery", "Fault", "Zone", "Reform")

# 정의상 불가능한 조합(원문 §3.2, D-b 로 한 줄 뺐다). **데이터로 적는다** — 코드에 흩어 놓으면
# 격자 정의가 두 곳이 된다. `"max"` 는 그 축의 최상단 버킷을 뜻한다.
PRUNE_RULES = [
    {"name": "battery_but_high_soc", "cond": {"evt": "Battery", "soc_b": "max"}},
    {"name": "zone_but_no_zone",     "cond": {"evt": "Zone",    "zone_s": "none"}},
    {"name": "nonzone_but_zone_set", "cond": {"evt": "Battery", "zone_s": "cov"}},
    {"name": "early_but_no_spares",  "cond": {"prog_b": 0,      "spares_b": 0}},
]


def bucket_of(x, edges):
    """오름차순 **상단경계** 목록에서 x 가 드는 칸의 0-기반 인덱스.

    마지막 칸은 열려 있다(x > edges[-1] 이면 len-1). `dp_lane.jl` 의 `dp_bucket` 과 같은 규칙."""
    for i, e in enumerate(edges):
        if x <= e:
            return i
    return len(edges) - 1


def bins_from_support(values, max_bins=4):
    """관측 지지집합을 덮는 **상단경계** 목록 (원문 §3, 격자 B).

    전구간을 깔지 않는 이유: 실측에서 spare_count 는 8~12 만, soc 는 0~0.0999 만 나왔다.
    축을 전구간으로 깔면 예산의 다수가 현재 스트림이 절대 만들지 않는 칸에 들어간다.
    결정적이다 — 같은 입력에 같은 출력(원문 §8.8)."""
    vs = sorted(set(float(v) for v in values if v is not None))
    if not vs:
        return []
    if len(vs) <= max_bins:
        return vs
    out = []
    for i in range(max_bins):
        idx = int(round(i * (len(vs) - 1) / (max_bins - 1)))
        if not out or vs[idx] != out[-1]:
            out.append(vs[idx])
    return out


def cell_key(state):
    """축 순서를 고정한 격자칸 키. dict 삽입 순서에 흔들리지 않는다.

    형식: "prog_b=1|soc_b=0|spares_b=2|pend_f=1|zone_s=none|evt=Battery"
    **dp_solve._bucket() 이 첫 성분을 자른다 — 형식을 바꾸면 솔버가 버킷을 못 읽는다.**"""
    return "|".join("%s=%s" % (a, state.get(a)) for a in AXES)


def is_infeasible(state, axes_spec=None):
    """정의상 불가능한 칸인가 (원문 §3.2). 표집하지 않고 INFEASIBLE 로 기록한다."""
    for rule in PRUNE_RULES:
        hit = True
        for k, want in rule["cond"].items():
            got = state.get(k)
            if want == "max":
                top = (len(axes_spec[k]["bins"]) - 1) if axes_spec else 3
                hit = got == top
            else:
                hit = (got == want)
            if not hit:
                break
        if hit:
            return True
    return False


def load_grid(path=None):
    return json.load(open(path or os.path.join(HERE, "grid_spec.json")))


# =====================================================================================
# 스윕에서 축을 유도한다
# =====================================================================================
TRUTH_TO_EVT = {"BatteryTruth": "Battery", "FaultTruth": "Fault",
                "ZoneTruth": "Zone", "ReformTruth": "Reform"}


def zone_state_of(decision):
    """zone_primitives -> {none, blk, cov}. `dp_lane.jl` 의 같은 규칙."""
    zp = decision.get("zone_primitives")
    if not zp:
        return "none"
    if (zp.get("root_covered") or 0) > 0:
        return "cov"
    if (zp.get("n_nav_blocked") or 0) > 0:
        return "blk"
    return "none"


def state_of(decision, axes):
    """결정 레코드 -> 격자칸 상태. **온라인(dp_lane.jl)과 같은 필드에서, 같은 규칙으로.**"""
    prog = decision.get("progress")
    soc = decision.get("soc")
    spares = decision.get("spare_count")
    pend = decision.get("agent_pending")
    if prog is None or spares is None:
        return None
    # pend_f 는 **영향받은 로봇**의 일감 수다. Zone/Reform 사건에는 해당 로봇이 없어서
    # run_demo.jl 이 -1(미기록)을 찍는다. 그것을 결측으로 보고 결정을 버리면 실측 3953건 중
    # 2568건(= zone 787 + reform 1781, 정확히 일치)이 통째로 사라져 **격자에서 zone 축이
    # 조용히 증발한다.** "일감 0" 과 "이 축이 적용되지 않음" 은 다른 상태이므로 섞지 않고,
    # 별도 칸 "na" 로 이름 붙여 남긴다.
    pend_b = bucket_of(float(pend), axes["pend_f"]["bins"]) if (
        isinstance(pend, (int, float)) and pend >= 0) else "na"
    # soc 는 battery 결정에만 있다. 다른 evt 에서는 최상단 칸(= "배터리 문제 아님")으로 둔다.
    soc_b = (bucket_of(float(soc), axes["soc_b"]["bins"])
             if isinstance(soc, (int, float)) else len(axes["soc_b"]["bins"]) - 1)
    return {
        "prog_b": bucket_of(float(prog), axes["prog_b"]["bins"]),
        "soc_b": soc_b,
        "spares_b": bucket_of(float(spares), axes["spares_b"]["bins"]),
        "pend_f": pend_b,
        "zone_s": zone_state_of(decision),
        "evt": TRUTH_TO_EVT.get(decision.get("truth"), "Reform"),
    }


def _decisions(results_dir):
    rows = []
    for p in sorted(glob.glob(os.path.join(results_dir, "*.jsonl"))):
        if os.path.basename(p) == "all.jsonl":
            continue          # all.jsonl 은 case 파일의 부분집합이 아니라 별도 case 다
        for line in open(p):
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    # all.jsonl 도 case 다(=세 사건 동시). 위에서 뺐으니 여기서 따로 넣는다.
    p = os.path.join(results_dir, "all.jsonl")
    if os.path.exists(p):
        for line in open(p):
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", default=os.path.join(HERE, "..", "results_4pol"))
    ap.add_argument("--out", default=os.path.join(HERE, "grid_spec.json"))
    a = ap.parse_args()

    import objective

    rows = _decisions(a.results)
    # 세대 단일성: 섞인 표본에서 축을 유도하면 혼입이 격자에 각인된다.
    gens = collections.Counter((r.get("objective_hash"), r.get("energy_objective")) for r in rows)
    if len(gens) != 1:
        sys.exit("스윕에 세대가 %d 종 섞여 있다 — 축을 유도하지 않는다: %s" % (len(gens), dict(gens)))
    cur = objective.objective_hash()
    got = list(gens)[0][0]
    if got != cur:
        sys.exit("스윕이 구세대다(행 %s vs 현행 %s) — 축을 유도하지 않는다." % (got, cur))

    ds = [d for r in rows for d in (r.get("decisions") or [])]
    print("행 %d · 결정 %d · 세대 단일 확인" % (len(rows), len(ds)))

    def col(k):
        return [d[k] for d in ds if isinstance(d.get(k), (int, float)) and d[k] >= 0]

    axes = {
        # prog_b 는 **단조 비감소** — backward induction 의 DAG 를 보장하는 유일한 축이다.
        "prog_b": {"bins": bins_from_support(col("progress"), 4),
                   "source": "results_4pol 결정 %d건의 progress 지지집합 + 분위 4구간" % len(col("progress"))},
        # 0.02 는 완주로 갈리는 칸이라 경계로 유지한다(원문 §3). 0.10 위는 "배터리 문제 아님".
        "soc_b": {"bins": [0.02, 0.05, 0.10, 1.0],
                  "source": "실측 지지 0~0.0999 + 한 칸 밖. 0.02 는 완주가 갈리는 경계라 유지"},
        "spares_b": {"bins": bins_from_support(col("spare_count"), 4),
                     "source": "실측 spare_count 지지집합"},
        # D-a: agent_pending 의 버킷이다. 위 독스트링 참조.
        "pend_f": {"bins": [0, 1, 99], "extra_values": ["na"],
                   "source": "agent_pending 을 {0, 1, >=2} 로, 영향 로봇이 없는 사건(zone/reform)은 "
                             "'na'. 원문의 '미해결 고장 수' 는 이 하니스에 존재하지 않는 변수라 "
                             "실측 가능한 축으로 대체(편차 D-a)"},
        "zone_s": {"values": list(ZONE_STATES),
                   "source": "zone_primitives (root_covered>0 -> cov, n_nav_blocked>0 -> blk)"},
        "evt": {"values": list(EVENTS), "source": "결정 레코드의 truth 타입"},
    }

    # 칸 세기 + 실측 도달 칸
    pend_vals = list(range(len(axes["pend_f"]["bins"]))) + ["na"]
    n_cells = (len(axes["prog_b"]["bins"]) * len(axes["soc_b"]["bins"]) *
               len(axes["spares_b"]["bins"]) * len(pend_vals) *
               len(ZONE_STATES) * len(EVENTS))
    n_feasible = 0
    for pb in range(len(axes["prog_b"]["bins"])):
        for sb in range(len(axes["soc_b"]["bins"])):
            for spb in range(len(axes["spares_b"]["bins"])):
                for pf in pend_vals:
                    for zs in ZONE_STATES:
                        for ev in EVENTS:
                            st = dict(prog_b=pb, soc_b=sb, spares_b=spb, pend_f=pf,
                                      zone_s=zs, evt=ev)
                            if not is_infeasible(st, axes):
                                n_feasible += 1

    observed = collections.Counter()
    n_unstateable = 0
    for d in ds:
        st = state_of(d, axes)
        if st is None:
            n_unstateable += 1
            continue
        observed[cell_key(st)] += 1

    spec = {
        "axes": axes,
        "prune": PRUNE_RULES,
        "axis_order": list(AXES),
        "generation": objective.load()["generation"],
        "objective_hash": cur,
        "n_cells_raw": n_cells,
        "n_feasible_cells": n_feasible,
        # **실측으로 도달한 칸**이 표집 대상의 상한이다. 도달하지 않는 칸에 예산을 쓰지 않는다.
        "n_observed_cells": len(observed),
        "observed_cells": dict(sorted(observed.items(), key=lambda kv: -kv[1])),
        "n_decisions": len(ds),
        "n_unstateable_decisions": n_unstateable,
        "source_results": os.path.abspath(a.results),
        "deviations": [
            "D-a: pend_f = agent_pending 의 버킷. 원문의 '미해결 고장 수' 는 이 하니스에 "
            "존재하지 않는 변수다.",
            "D-b: 원문 §3.2 의 'evt=Fault & pend_f=0 -> INFEASIBLE' 을 뺐다. D-a 의 정의에서는 "
            "실재하고 이미 측정된 칸이다(faultidle 계열).",
            "D-c: pend_f 에 'na' 칸을 뒀다. zone/reform 사건에는 영향 로봇이 없어 "
            "agent_pending=-1 인데, 이를 결측으로 버리면 결정 3953건 중 2568건(zone+reform 전부)이 "
            "사라져 격자에서 zone 축이 증발한다.",
        ],
    }
    with open(a.out, "w") as f:
        json.dump(spec, f, indent=1, ensure_ascii=False)

    print("원시 칸 %d · 가지치기 후 %d · **실측 도달 %d**  (미상태화 결정 %d)"
          % (n_cells, n_feasible, len(observed), n_unstateable))
    print("-> %s" % a.out)


if __name__ == "__main__":
    main()
