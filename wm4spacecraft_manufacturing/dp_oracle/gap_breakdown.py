#!/usr/bin/env python3
"""§8.7 gap 을 **원인별로 쪼개서** 본다 (계획 2026-08-15 Task 7).

gap 이 0 이 아닐 때 "천장" 이라는 이름을 안 쓰는 것까지는 `build_compare_table.py` 가 자동으로
한다. 이 스크립트는 그 다음 질문에 답한다 — **어느 칸에서 넘겼고, 그 칸의 φ̃ 가 무엇을 버렸나.**

세 가지를 분리한다:
  1. **백오프가 더한 편향.** 같은 gap 을 `value.json`(백오프 ON)과 `value_L0_nobackoff.json`
     (정밀 격자만) 두 표로 각각 재서 대비한다. L0 에서도 남는 gap 이 격자 자체의 손실이다.
  2. **레벨별 gap.** 칸이 어느 `dp_level` 에서 답했는지로 쪼갠다. 거친 레벨일수록 한 칸에 물리적
     으로 다른 상태가 많이 섞이므로 gap 이 커야 한다 — 그 예측이 맞는지 본다.
  3. **어느 축이 버려졌나.** gap 이 큰 칸의 `dp_level_key` 를 보면 그 칸이 어떤 축을 덜어낸
     투영에서 답했는지가 그대로 나온다.

비교 단위는 **그 칸부터의 실현 cost-to-go** 다 — `build_compare_table.py` 와 같은 규칙이어야
두 산출물이 안 갈린다.
"""
import collections
import glob
import json
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
WM = os.path.join(HERE, "..")
sys.path.insert(0, WM)
sys.path.insert(0, HERE)

from derive_grid import cell_key, state_of                 # noqa: E402
from sample_grid import decompose_board                    # noqa: E402

POLICIES = ("canonical", "surrogate", "dspy")
MIN_N = 3


def realized_ctg(results_dir):
    """(칸, 정책) -> 실현 cost-to-go 목록. 분해 불가 행은 세어서 같이 낸다."""
    per = collections.defaultdict(lambda: collections.defaultdict(list))
    skipped = collections.Counter()
    axes = json.load(open(os.path.join(HERE, "grid_spec.json")))["axes"]
    for p in sorted(glob.glob(os.path.join(results_dir, "*.jsonl"))):
        for line in open(p):
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            if r.get("policy") not in POLICIES:
                continue
            dec = decompose_board(r)
            if not dec["ok"]:
                skipped[str(dec["reason"]).split(":")[0]] += 1
                continue
            run = dec["c_prefix"]
            seen = set()
            for i, d in enumerate(r.get("decisions") or []):
                st = state_of(d, axes)
                ctg = dec["J"] - run
                run += dec["cs"][i]
                if st is None:
                    continue
                k = cell_key(st)
                if k in seen:
                    continue
                seen.add(k)
                per[k][r["policy"]].append(ctg)
    return per, skipped


def gap_of(vpath, per):
    v = json.load(open(vpath))
    cells = v["cells"]
    V = {c: d["V"] for c, d in cells.items() if d.get("V") is not None}
    rows, worse, tot = [], 0, 0
    for k, bypol in per.items():
        if k not in V:
            continue
        for pol, xs in bypol.items():
            if len(xs) < MIN_N:
                continue
            tot += 1
            m = statistics.mean(xs)
            beat = m < V[k] - 1e-9
            worse += beat
            rows.append({"cell": k, "policy": pol, "n": len(xs), "mean_ctg": m,
                         "V": V[k], "beat": beat, "margin": V[k] - m,
                         "dp_level": cells[k].get("dp_level"),
                         "dp_level_key": cells[k].get("dp_level_key"),
                         "a_star": cells[k].get("a_star"),
                         "reason": cells[k].get("unresolved_reason")})
    return v, rows, worse, tot


def main():
    per, skipped = realized_ctg(os.path.join(WM, "results_4pol"))
    print("실행 정책 행에서 뽑은 (칸,정책) 쌍: %d개  (분해 불가로 제외: %s)"
          % (sum(len(b) for b in per.values()), dict(skipped) or "없음"))

    tables = [("백오프 ON  (value.json, 현행)", os.path.join(HERE, "value.json")),
              ("L0 만     (value_L0_nobackoff.json)",
               os.path.join(HERE, "value_L0_nobackoff.json"))]
    old = os.path.join(HERE, "_gen_constantarm_2026-08-14", "value.json")
    if os.path.exists(old):
        tables.append(("2026-08-14 상수-팔 (참고: 단위가 판 전체 J 라 직접 비교 불가)", old))

    detail = None
    print("\n== 1) 표별 gap ==")
    for name, p in tables:
        if not os.path.exists(p):
            continue
        v, rows, worse, tot = gap_of(p, per)
        if "상수-팔" in name:
            # 단위가 다르므로 수치를 내되 **비교하지 말라고 이름에 적는다**.
            print("  %-46s n=%-4d gap=%-4d (%.1f%%)   [단위 불일치 — 참고용]"
                  % (name, tot, worse, 100.0 * worse / max(tot, 1)))
            continue
        print("  %-46s n=%-4d gap=%-4d (%.1f%%)"
              % (name, tot, worse, 100.0 * worse / max(tot, 1)))
        if detail is None:
            detail = rows

    v = json.load(open(os.path.join(HERE, "value.json")))
    _, rows, _, _ = gap_of(os.path.join(HERE, "value.json"), per)

    print("\n== 2) 레벨별 gap (거친 레벨일수록 한 칸에 다른 상태가 많이 섞인다) ==")
    bylvl = collections.defaultdict(lambda: [0, 0])
    for r in rows:
        b = bylvl[r["dp_level"]]
        b[0] += r["beat"]
        b[1] += 1
    for lvl in sorted(bylvl):
        w, t = bylvl[lvl]
        drop = v["backoff_levels"][lvl]["dropped_axes"] if lvl is not None else []
        print("  L%s (덜어낸 축 %-22s) : %3d/%3d = %5.1f%%"
              % (lvl, drop or "없음", w, t, 100.0 * w / max(t, 1)))

    print("\n== 3) gap 이 큰 칸 상위 12 (margin = V − 실행정책 평균; 클수록 V 가 헐겁다) ==")
    for r in sorted([r for r in rows if r["beat"]], key=lambda x: -x["margin"])[:12]:
        print("  margin %9.2f  n=%-3d %-9s L%s  %s"
              % (r["margin"], r["n"], r["policy"], r["dp_level"], r["cell"]))
        if r["dp_level"]:
            print("      답한 칸: %s" % r["dp_level_key"])

    print("\n== 3b) 사건(evt)별 gap — 표집 팔 메뉴가 그 사건의 정답을 갖고 있는가 ==")
    # 이 절이 답하는 질문: **그 사건의 정답이 표집 팔 메뉴에 있었는가.** 없으면 그 칸의 V 는
    # "정답이 메뉴에 없는 정책군의 최선" 이라 실행 레인보다 나쁠 수밖에 없다 — φ̃ 추상화
    # 손실과는 **다른 원인**이므로 뭉뚱그리지 않는다.
    #
    # 2026-08-16: 메뉴를 `("0","1","2","7","8")` 로 하드코딩하고 있었다. 그 다섯은 배포 학습셋의
    # 지원집합을 베낀 것이고, 바로 그 하드코딩이 이 진단이 지목하던 병의 원인이었다. 이제
    # `sample_grid.arm_menu()` 에서 받는다 — 표집이 실제로 쓴 그 함수다. 여기서 다시 쓰면
    # 진단과 표집이 갈려, 메뉴를 고친 뒤에도 이 절이 옛 목록으로 "메뉴 밖" 을 찍는다.
    import re
    from sample_grid import arm_menu                                   # noqa: E402
    reg = json.load(open(os.path.join(WM, "action_registry.json")))["macros"]
    menu = {i for i, _ in arm_menu()}
    print("  표집 팔 메뉴: %s" % sorted("%d:%s" % (k, reg[str(k)]["name"]) for k in menu))
    print("  메뉴 밖 매크로: %s"
          % sorted("%s:%s" % (k, m["name"]) for k, m in reg.items() if int(k) not in menu))
    byevt = collections.defaultdict(lambda: [0, 0])
    enacted = collections.defaultdict(collections.Counter)
    for r in rows:
        m = re.search(r"evt=([A-Za-z]+)", r["cell"])
        e = m.group(1) if m else "?"
        b = byevt[e]
        b[0] += r["beat"]
        b[1] += 1
    # 실행 레인이 그 사건에서 실제로 무엇을 집행했는지 — 메뉴 밖이면 V 가 그것을 못 봤다.
    axes = json.load(open(os.path.join(HERE, "grid_spec.json")))["axes"]
    for p in sorted(glob.glob(os.path.join(WM, "results_4pol", "*.jsonl"))):
        for line in open(p):
            line = line.strip()
            if not line:
                continue
            rr = json.loads(line)
            if rr.get("policy") not in POLICIES:
                continue
            for d in (rr.get("decisions") or []):
                st = state_of(d, axes)
                if st is not None:
                    enacted[st["evt"]][d.get("macro")] += 1
    names = {m["name"]: int(k) for k, m in reg.items()}
    for e in sorted(byevt):
        w, t = byevt[e]
        top = enacted[e].most_common(3)
        tag = ", ".join("%s%s×%d" % (mc, "" if names.get(mc) in menu else " ⚠️메뉴밖", n)
                        for mc, n in top)
        print("  %-8s gap %3d/%3d = %5.1f%%   실행 레인이 집행한 매크로: %s"
              % (e, w, t, 100.0 * w / max(t, 1), tag))

    print("\n== 4) 넘긴 쌍이 **없는** 칸 (V 가 실제로 천장이었던 곳) ==")
    ok_cells = sorted({r["cell"] for r in rows if not r["beat"]}
                      - {r["cell"] for r in rows if r["beat"]})
    print("  %d칸" % len(ok_cells))
    for c in ok_cells[:10]:
        print("    %s" % c)


if __name__ == "__main__":
    main()
