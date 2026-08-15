#!/usr/bin/env python3
"""반사실 표집기 — 팔을 고정한 판을 굴려 **(칸, 팔, c, 다음칸)** 전이 표본을 만든다.

무엇을 재는가 (이름을 정확히 붙인다)
====================================
한 rollout = **한 판 전체**를 `DEMO_FORCE_MACRO=<팔>` 로 굴린 것이다. 그 판의 모든 OOD 결정은
그 팔로 집행된다. 2026-08-15 부터 `run_demo.jl` 이 **결정마다 (sim_t, 누적 energy, closed)** 를
남기므로, 연속한 두 결정 사이의 구간 비용 `c_k` 와 다음 칸 `s̃′` 가 실제로 만들어진다. 그래서
이 표집기가 내는 것은 판 단위 J 하나가 아니라 **전이 목록**이고, `dp_solve.py` 는 그 위에서
진짜 Bellman backward induction 을 푼다.

    c_k = Δmakespan_k + w_E · Δenergy_k        (완주 분기 형태로 **고정**)
    V(goal) = 0,   V(dead_end) = J − c_prefix − Σ_k c_k        (종단에서 차액을 정산)

**왜 러닝 코스트를 완주 분기로 고정하는가.** `objective.J` 의 두 분기는 러닝 코스트가 다르다 —
완주는 `makespan + w_E·energy`(구간에 정확히 가법적), 미완주는
`C_fail + C_unclosed·unclosed + tie_eps·makespan`(**에너지가 아예 안 들어간다**). 그런데 결정
시점에는 그 판이 완주할지 모른다. 그래서 러닝 코스트는 한 형태로 고정하고, 두 분기의 차액을
**종단값 하나로** 정산한다. 이건 발명이 아니라 정산이고, 발명이 아님을 아래 §충실성 게이트가
기계로 못박는다.

★ `c_prefix` — 계획서(2026-08-15) 대비 유일한 편차이자 필수 정정
==============================================================
항등식 `Σ_k c_k = makespan + w_E·energy` 는 구간이 **판의 시작 (t=0, e=0) 부터** 덮일 때만
참이다. 그런데 결정 k=1..n 이 만드는 구간은 `[t_1, T]` 뿐이고 **`[0, t_1]` — 첫 결정 이전 —
이 빠진다.** 이 구간을 `c_1` 에 접어 넣으면 *결정이 내려지기도 전에 발생한 비용*이 첫 팔에
귀속된다. 그 양은 판마다 다르므로(사건 발화 시각이 case/seed 마다 다르다) 같은 칸에 모인
표본들에 서로 다른 상수가 실려 **Q 에 편향**이 된다 — 즉 배분 규칙을 지어내는 것이 된다.
그래서 접지 않고 **`c_prefix` 라는 판 단위 상수로 이름 붙여 분리**한다.

  · DP 는 `c_prefix` 를 쓰지 않는다. `V(s̃_1)` 은 정의상 **첫 결정부터의 cost-to-go** 이고,
    `c_prefix` 는 어떤 정책도 바꿀 수 없는(첫 결정 이전의) 상수다.
  · 대신 충실성 게이트가 그것을 명시적으로 포함한다:  `c_prefix + Σc_k + terminal == J_row`.
    게이트의 강도는 계획서 원안과 같다 — 빠진 항을 0 으로 두지 않고 **재서 넣기** 때문이다.

§충실성 게이트 — 이 파일에서 가장 중요한 것
==========================================
판마다 두 항등식을 확인한다. 하나라도 어긋나면 그 판을 **버리지 않고 표시해서 세고**, 그런
판이 하나라도 있으면 표집 종료 시 **exit 1** 이다.
    (1) 텔레스코핑:  c_prefix + Σc_k  ==  makespan + w_E·energy
    (2) 정산:        c_prefix + Σc_k + terminal_value  ==  objective.J_row(row)
(1) 은 두 분기 모두에서 비자명하다(구간 원자료가 실제로 종단값과 맞는지 본다). (2) 는 미완주
분기에서는 terminal_value 의 정의상 자명하지만, 완주 분기에서는 `terminal_value = 0` 이라
**J 의 완주식 자체를 검사**한다. 합성 판 단위검사는 `test_cost_decomposition.py`.

요청 칸이 아니라 **착지 칸**으로 라벨한다 (원 설계 §4.2·§5)
==========================================================

요청 칸이 아니라 **착지 칸**으로 라벨한다 (원 설계 §4.2·§5)
==========================================================
칸을 세우는 ψ 를 새로 짓지 않는다. 기존 case/seed 조합이 자연히 만드는 상태를 굴리고, **주입
후 실제 상태에서 φ̃ 를 다시 계산해** 착지한 칸의 표본으로 센다. 어떤 조합으로도 표본이 안 생기는
칸은 UNREACHABLE 로 남고 값을 지어내지 않는다.

사용법
    ../../.venv/bin/python sample_grid.py --jobs 24 --seeds 1,2,3,4,5,6,7,8,9,10
"""
import argparse
import collections
import json
import math
import os
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
WM = os.path.join(HERE, "..")
REPO = os.path.join(WM, "..")
sys.path.insert(0, WM)
sys.path.insert(0, HERE)

import objective                                              # noqa: E402
from derive_grid import cell_key, state_of, load_grid         # noqa: E402

PY = os.path.join(REPO, ".venv", "bin", "python")
DSPY_URL = os.environ.get("DSPY_URL", "http://127.0.0.1:8090")

CASES = ["battery", "fault", "all", "fault_battery", "fault_zone", "battery_zone", "zone"]

# 팔 메뉴는 `action_registry.json` 에서 온다 — 630판 로그의 `valid` 를 읽으면 FaultTruth/
# ReformTruth 가 빈 리스트라 그 축이 **조용히 0팔**이 된다(원 설계 §3.3).
#
# ---- 2026-08-16: 하드코딩한 5팔을 없앴다 -------------------------------------------------
# 무엇이 잘못이었나. 예전 메뉴는 `want = ("0","1","2","7","8")` = **배포 학습셋의 support 를
# 그대로 베낀 것**이었다. 그런데 그 support 는 "이긴 팔"이 아니라 "굴려서 라벨한 팔"이고
# (`dspy_service.py:229` 가 학습 행의 macro 열에서 유도한다), 재라벨(2026-08-14)이 reform
# 인스턴스를 0건 만들면서 `ReformTeam(4)` 과 `ForbidZone(3)` 이 거기서 빠져 있었다.
#
# 그래서 DP 는 **셋 중 가장 좁은 레인(surrogate)에 메뉴를 맞춘 셈**이 됐고, 그러면 천장이 될 수
# 없다: 2026-08-15 실측에서 실행 레인은 Reform 사건에 `ReformTeam` 을 1182회 집행하는데 DP 는
# 그 팔을 볼 수조차 없어 Reform 축 gap 이 13/13 = 100% 였고, 표집 판 338개가 전부 reform 에서
# 죽었다(V 중앙값 4418.6). 비교가 성립하지 않는 축이었다.
#
# 이제 어휘의 진실원에서 받는다. 실험 팔(5·6)은 `is_active()` 가 DS_COMBO_ARMS 로 건다 —
# 즉 이 함수는 **환경이 정한 활성 집합**을 그대로 따르고, 여기서 다시 좁히지 않는다.
def arm_menu():
    import action_registry as reg
    return [(i, reg.MACRO_NAME[i]) for i in reg.ACTIVE_MACROS]


def run_board(case, seed, arm_id, arm_name, outroot, world_seed=1):
    """판 하나를 팔 고정으로 굴린다. 반환: rows.jsonl 경로 또는 None."""
    outdir = os.path.join(outroot, "%s_s%d_a%d" % (case, seed, arm_id))
    rows = os.path.join(outdir, "rows.jsonl")
    if os.path.exists(rows) and os.path.getsize(rows) > 0:
        return rows                                    # 재개: 이미 끝난 판은 다시 굴리지 않는다
    os.makedirs(outdir, exist_ok=True)
    env = dict(os.environ)
    env.update(
        DEMO_FORCE_MACRO=arm_name,
        # 팔을 고정하므로 실행 정책은 무엇이든 결과가 같다. canonical 로 둬서 DSPy 호출을 없앤다
        # (표집 350판 x LLM 호출은 비용이고, 어차피 집행은 FORCE_MACRO 가 덮는다).
        DEMO_ALL_POLICIES="0",
        JULIA_NUM_THREADS="1", OPENBLAS_NUM_THREADS="1",
        OMP_NUM_THREADS="1", MKL_NUM_THREADS="1")
    cmd = [PY, os.path.join(WM, "llm_ood_eval.py"), "run",
           "--case", case, "--seeds", str(seed), "--policies", "canonical",
           "--out", rows, "--dspy-url", DSPY_URL, "--router", "0",
           "--world-seed", str(world_seed)]
    with open(os.path.join(outdir, "board.log"), "w") as lg:
        rc = subprocess.call(cmd, stdout=lg, stderr=subprocess.STDOUT, cwd=WM, env=env)
    if rc != 0 or not os.path.exists(rows) or os.path.getsize(rows) == 0:
        return None
    return rows


def _terminal_energy(row):
    """4pol 레인은 에너지를 **최상위가 아니라 `battery` 하위**에 낸다(objective.J_row 가 두
    스키마를 다 읽는 이유가 이것이다). 최상위만 보면 조용히 None 이 되어 표에서 에너지 열이
    통째로 비는데, 그건 "에너지를 안 썼다" 가 아니라 "잘못된 키를 봤다" 다."""
    e = row.get("energy_J")
    if e is None:
        e = (row.get("battery") or {}).get("total_energy_J")
    return e


def _finite(x):
    try:
        return x is not None and math.isfinite(float(x))
    except (TypeError, ValueError):
        return False


FIDELITY_TOL = 1e-6


def new_report():
    """충실성 게이트의 집계. `boards_bad > 0` 이면 표집이 exit 1 한다."""
    return {"boards": 0, "boards_bad": 0, "decisions": 0, "decisions_unstateable": 0,
            "by_reason": collections.Counter(), "examples": [], "max_resid": 0.0}


def decompose_board(row, w_E=None, cfg=None):
    """판 하나 -> 구간 분해. **순수 함수 — 시뮬을 부르지 않는다.**

    반환 dict:
        ok             : 두 항등식이 모두 성립했나 (충실성 게이트가 세는 값)
        reason         : ok 가 아닐 때 **이름**. 조용히 버리지 않는다.
        c_prefix       : [0, t_1] 구간 비용. DP 는 쓰지 않는다(위 ★ 절).
        cs             : [c_1 .. c_n]. c_k 는 결정 k 에서 k+1(마지막은 종단)까지.
        terminal       : "goal" | "dead_end"
        terminal_value : 완주 0.0 / 미완주 J − c_prefix − Σc. J 채점 불가면 None.
        J, sum_c, resid_telescope, resid_settle, n_decisions

    `cs[k]` 는 `decisions[k]` 의 팔이 집행된 뒤 다음 결정까지 실제로 든 비용이다. 러닝
    코스트는 **완주 분기 형태로 고정**한다 — 결정 시점에는 그 판이 완주할지 모르기 때문이다.
    """
    cfg = cfg if cfg is not None else objective.load()
    if w_E is None:
        w_E = objective.energy_weight(cfg)

    ds = list(row.get("decisions") or [])
    n = len(ds)

    # 종단값. makespan 은 4pol/MC 두 레인의 키 이름이 달라 J_row 와 같은 폴백을 쓴다.
    T = row.get("makespan")
    if T is None:
        T = row.get("sim_seconds")
    E_T = _terminal_energy(row)

    try:
        J = objective.J_row(row)
        j_reason = None
    except objective.ObjectiveError as e:
        # 채점 불가 판은 **버리지 않고 이름으로 남긴다.** 조용히 빼면 표가 낙관 편향된다.
        J, j_reason = None, "J_unscorable: " + str(e)[:120]

    base = {"c_prefix": None, "cs": [], "J": J, "sum_c": None,
            "resid_telescope": None, "resid_settle": None, "n_decisions": n,
            "terminal": ("goal" if row.get("complete") else "dead_end"),
            "terminal_value": None, "w_E": w_E, "makespan": T, "energy_J": E_T}

    if not (_finite(T) and _finite(E_T)):
        # 구간 원자료가 없으면 분해가 성립하지 않는다. 값을 지어내지 않는다.
        return dict(base, ok=False, reason="terminal_missing: makespan=%r energy_J=%r" % (T, E_T))
    T, E_T = float(T), float(E_T)

    for i, d in enumerate(ds):
        if not (_finite(d.get("sim_t_at")) and _finite(d.get("energy_at_J"))):
            return dict(base, ok=False,
                        reason="decision_%d_missing: sim_t_at=%r energy_at_J=%r"
                               % (i, d.get("sim_t_at"), d.get("energy_at_J")))

    ts = [float(d["sim_t_at"]) for d in ds]
    es = [float(d["energy_at_J"]) for d in ds]

    # 결정 목록은 `_DECISIONS` 에 시간순으로 append 된 것이라 이미 정렬돼 있다. 그래도 확인한다 —
    # 어긋나면 정렬해서 덮는 대신 **이름으로 멈춘다**(순서가 틀렸다면 그건 계측의 결함이다).
    for i in range(1, n):
        if ts[i] < ts[i - 1] - FIDELITY_TOL:
            return dict(base, ok=False,
                        reason="sim_t_not_monotone at %d: %r < %r" % (i, ts[i], ts[i - 1]))
    if n and ts[-1] > T + FIDELITY_TOL:
        return dict(base, ok=False,
                    reason="last_decision_after_terminal: %r > makespan %r" % (ts[-1], T))

    # 판의 시작은 (t=0, e=0) 이다. c_prefix 가 그 구간을 덮고, 나머지를 c_k 가 덮는다.
    c_prefix = (ts[0] - 0.0) + w_E * (es[0] - 0.0) if n else (T + w_E * E_T)
    cs = []
    for i in range(n):
        t1, e1 = (ts[i + 1], es[i + 1]) if i + 1 < n else (T, E_T)
        cs.append((t1 - ts[i]) + w_E * (e1 - es[i]))
    sum_c = sum(cs)

    # (1) 텔레스코핑 항등식 — 러닝코스트의 합이 **objective 가 말하는 완주 분기 값**과 같은가.
    #
    # ⚠️ 기준값을 `T + w_E*E_T` 로 직접 쓰면 안 된다. 그러면 양변이 같은 w_E 를 쓰므로 잔차가
    # w_E 와 무관하게 **언제나 정확히 0** 이 되어, 이 검사가 아무것도 막지 못한다. 미완주
    # 분기에서는 terminal_value 가 정의상 차액을 흡수하므로 (2) 도 자명해지고, 결국 그 분기
    # 전체가 무검사로 남는다. (단위검사 T-06d 가 이 결함을 잡았다.)
    #
    # 그래서 기준값은 **objective.J 의 완주 분기를 직접 불러서** 받는다 — 계획서가 말하는
    # "러닝 코스트를 완주 분기로 고정한다" 가 문자 그대로 이 한 줄이다. 공식을 복제하지 않으므로
    # J 에 항이 추가되면 여기서 즉시 잔차가 벌어진다(audit_objective.py 항목 1 의 취지와 같다).
    # closed/total 은 objective.J 의 **완주 분기가 쓰지 않는** 인자라 결측이어도 기준값이
    # 흔들리지 않는다(미완주 분기에서만 쓰인다). 그래도 시그니처가 요구하므로 0 으로 채운다.
    running_ref = objective.J(complete=True, closed=int(row.get("closed") or 0),
                              total=int(row.get("total") or row.get("total_nodes") or 0),
                              makespan=T, energy_J=E_T, cfg=cfg)
    resid_tel = c_prefix + sum_c - running_ref

    terminal = "goal" if row.get("complete") else "dead_end"
    if J is None:
        return dict(base, ok=False, reason=j_reason, c_prefix=c_prefix, cs=cs,
                    sum_c=sum_c, resid_telescope=resid_tel, terminal=terminal)
    # 종단 정산. 완주는 0(그래서 (2)가 J 의 완주식 자체를 검사한다), 미완주는 차액.
    tv = 0.0 if row.get("complete") else (J - c_prefix - sum_c)
    resid_set = c_prefix + sum_c + tv - J

    ok = abs(resid_tel) < FIDELITY_TOL and abs(resid_set) < FIDELITY_TOL
    return dict(base, ok=ok,
                reason=(None if ok else
                        "fidelity_violation: telescope=%.3e settle=%.3e" % (resid_tel, resid_set)),
                c_prefix=c_prefix, cs=cs, sum_c=sum_c, terminal=terminal,
                terminal_value=tv, resid_telescope=resid_tel, resid_settle=resid_set)


def rows_to_samples(rows_path, case, seed, arm_id, arm_name, axes, report=None):
    """판 하나 -> **전이 표본**. 결정 k 에서 (칸, 팔, c_k, 다음칸) 을 낸다.

    `report` 는 `new_report()` 가 만든 충실성 집계."""
    out = []
    rep = report if report is not None else new_report()
    for line in open(rows_path):
        line = line.strip()
        if not line:
            continue
        r = json.loads(line)
        board_id = "%s_s%d_a%d" % (case, seed, arm_id)
        dec = decompose_board(r)
        rep["boards"] += 1
        if not dec["ok"]:
            rep["boards_bad"] += 1
            rep["by_reason"][str(dec["reason"]).split(":")[0]] += 1
            if len(rep["examples"]) < 20:
                rep["examples"].append((board_id, dec["reason"]))
            # 분해가 성립하지 않은 판에서는 전이를 만들지 않는다. **버리는 것이 아니라**
            # 위 카운터에 이름으로 남고, main() 이 그 수를 세어 exit 1 한다.
            continue
        rep["max_resid"] = max(rep["max_resid"],
                               abs(dec["resid_telescope"]), abs(dec["resid_settle"]))

        ds = list(r.get("decisions") or [])
        # 칸으로 라벨할 수 없는 결정은 그 자리에 None 으로 남긴다 — 앞 전이의 next_cell 이
        # 조용히 "그 다음 결정" 으로 건너뛰면 전이 그래프가 실제와 달라진다.
        cells = []
        for d in ds:
            st = state_of(d, axes)
            cells.append(cell_key(st) if st is not None else None)
        rep["decisions"] += len(ds)
        rep["decisions_unstateable"] += sum(1 for c in cells if c is None)

        _bat = r.get("battery") or {}
        for i, d in enumerate(ds):
            if cells[i] is None:
                continue                       # 이 결정은 칸이 없다(표본이 안 된다). 위에서 셌다.
            is_last = (i + 1 == len(ds))
            nxt_cell = None if is_last else cells[i + 1]
            out.append({
                # ---- backward induction 이 읽는 네 값 --------------------------------------
                "cell": cells[i], "arm": arm_id, "arm_name": arm_name,
                "c": dec["cs"][i],
                "next_cell": nxt_cell,
                "terminal": (dec["terminal"] if is_last else None),
                "terminal_value": (dec["terminal_value"] if is_last else None),
                # 다음 결정은 있는데 **칸으로 라벨할 수 없는** 경우. V 를 0 으로 두면 미지의
                # 미래가 공짜가 되므로, 솔버가 dangling 으로 세게 이름을 남긴다.
                "next_unstateable": (not is_last and nxt_cell is None),
                # ---- 상수-팔 판(2026-08-14)과 **나란히 비교**하기 위한 판 단위 J ------------
                # solve_constant_arm() 이 이 열을 그대로 읽는다. 두 세대를 한 표본 파일로
                # 비교할 수 있어야 이번 작업이 무엇을 바꿨는지 말할 수 있다(계획 Task 7).
                "cost": dec["J"], "unscorable": (None if dec["J"] is not None else dec["reason"]),
                "c_prefix": dec["c_prefix"], "board_sum_c": dec["sum_c"],
                "capped": False, "sampling_mode": "transition",
                "seed": seed, "case": case, "at": d.get("at"),
                "enacted_macro": d.get("macro"),
                "complete": bool(r.get("complete")), "closed": r.get("closed"),
                "total": r.get("total"), "makespan": r.get("makespan"),
                "energy_J": dec["energy_J"], "energy_per_closed": _bat.get("energy_per_closed"),
                "objective_hash": r.get("objective_hash"),
                "energy_objective": r.get("energy_objective"),
                "board_id": board_id,
                "board_n_decisions": len(ds),
            })
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=24)
    ap.add_argument("--seeds", default="1,2,3,4,5,6,7,8,9,10")
    ap.add_argument("--cases", default=",".join(CASES))
    ap.add_argument("--work", default=os.path.join(HERE, "_sample_work"))
    ap.add_argument("--out", default=os.path.join(HERE, "samples.jsonl"))
    ap.add_argument("--keep-work", action="store_true")
    a = ap.parse_args()

    seeds = [int(x) for x in a.seeds.split(",") if x.strip()]
    cases = [c for c in a.cases.split(",") if c.strip()]
    arms = arm_menu()
    grid = load_grid()
    axes = grid["axes"]

    jobs = [(c, s, aid, an) for s in seeds for c in cases for (aid, an) in arms]
    print("표집 계획: case %d x seed %d x 팔 %d = **%d 판**, 병렬 %d"
          % (len(cases), len(seeds), len(arms), len(jobs), a.jobs))
    print("팔 메뉴 (action_registry.json):", ", ".join("%d:%s" % x for x in arms))
    os.makedirs(a.work, exist_ok=True)

    t0 = time.time()
    done = {"n": 0, "fail": 0}

    def work(j):
        c, s, aid, an = j
        p = run_board(c, s, aid, an, a.work)
        done["n"] += 1
        if p is None:
            done["fail"] += 1
        if done["n"] % 25 == 0:
            el = time.time() - t0
            print("  %d/%d 판  (실패 %d)  경과 %.1f분  예상 총 %.1f분"
                  % (done["n"], len(jobs), done["fail"], el / 60,
                     el / 60 * len(jobs) / max(done["n"], 1)), flush=True)
        return (j, p)

    with ThreadPoolExecutor(max_workers=a.jobs) as ex:
        results = list(ex.map(work, jobs))

    samples = []
    n_boards_ok = 0
    rep = new_report()
    for (c, s, aid, an), p in results:
        if p is None:
            continue
        n_boards_ok += 1
        samples.extend(rows_to_samples(p, c, s, aid, an, axes, report=rep))

    # 세대 단일성: 표본이 두 세대에서 오면 멈춘다. 섞인 값을 표에 각인시키지 않는다.
    gens = {(r.get("objective_hash"), r.get("energy_objective")) for r in samples}
    if len(gens) > 1:
        sys.exit("표본에 세대가 %d 종 섞여 있다: %s" % (len(gens), gens))

    with open(a.out, "w") as f:
        for r in samples:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    by_cell = collections.Counter(r["cell"] for r in samples)
    by_cell_arm = collections.Counter((r["cell"], r["arm"]) for r in samples)
    n_unscorable = sum(1 for r in samples if r["cost"] is None)
    n_terminal = sum(1 for r in samples if r["terminal"] is not None)
    n_next_unstateable = sum(1 for r in samples if r.get("next_unstateable"))
    print("\n판 %d/%d 성공 · 전이 %d행 · 칸 %d개 · (칸,팔) 쌍 %d개"
          % (n_boards_ok, len(jobs), len(samples), len(by_cell), len(by_cell_arm)))
    print("  종단 전이 %d · 다음칸 미상태화 %d · J 채점불가 표본 %d (버리지 않고 표시)"
          % (n_terminal, n_next_unstateable, n_unscorable))
    print("관측 격자 대비 커버리지: %d / %d = %.1f%%"
          % (len(by_cell), grid["n_observed_cells"],
             100.0 * len(by_cell) / max(grid["n_observed_cells"], 1)))

    # ---- §충실성 게이트 -------------------------------------------------------------------
    # 배분 규칙을 지어내면 그 규칙이 곧 결과가 된다. 그래서 "지어내지 않았다"를 여기서 기계로
    # 못박는다. 어긋난 판이 하나라도 있으면 뒤의 모든 숫자가 무효이므로 exit 1 이다.
    print("\n§분해 충실성: 판 %d 중 어긋남 %d · 최대잔차 %.3e (허용 %.0e) · 미상태화 결정 %d/%d"
          % (rep["boards"], rep["boards_bad"], rep["max_resid"], FIDELITY_TOL,
             rep["decisions_unstateable"], rep["decisions"]))
    for k, v in sorted(rep["by_reason"].items()):
        print("    %-24s %d" % (k, v))
    for bid, why in rep["examples"]:
        print("    예: %s -> %s" % (bid, why))

    print("벽시계 %.1f분  ->  %s" % ((time.time() - t0) / 60, a.out))

    if not a.keep_work:
        shutil.rmtree(a.work, ignore_errors=True)

    if rep["boards_bad"]:
        sys.exit("분해 충실성 위반 %d판 — 그 뒤의 모든 숫자가 무효다(exit 1)." % rep["boards_bad"])


if __name__ == "__main__":
    main()
