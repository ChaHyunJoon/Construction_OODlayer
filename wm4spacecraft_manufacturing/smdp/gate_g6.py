"""G6 — `f` 무솔버 불변식 (spec §5.5 · §7).

주장: 6팔 전부에 대해 f(s,a) 가 **결정론적 그래프/기하 편집**이고 솔버를 부르지 않는다.
왜 필요한가: π_a 의 첫 스텝이 결정론적이어야 option 이 잘 정의되고(Sutton Thm 1),
스냅샷/K-rollout 예산이 예측 가능해지며, MILP 비용이 object-level 팔에 숨지 않는다.

이것은 가정이 아니라 **검사 가능한 불변식**이다 — run_demo 의 _milp_sentinel 이 결정마다
"이 분기가 formulate_milp 을 불렀는가" 를 실측한다.

  python gate_g6.py <rows.jsonl> [<rows.jsonl> ...]
  python gate_g6.py $(find ../results_4pol/shards -name rows.jsonl)

🔴 **2026-08-19 실측 (태스크 5, 컨트롤러 판정 L 의 양성 대조 창에서 발견)**: 이 게이트의
주장("6팔 전부가 무솔버")은 spec §1.3 이 이미 증명해 뒀다고 적혀 있었지만 실측은 다르다 —
surviving arm **Deprioritize(macro 2)** 가 `BatteryTruth` 사건에서 `rebalance_for_battery!`
(`src/navigator/battery.jl:715-724`)를 거쳐 **직접 `formulate_milp` 를 부른다**
(`DEMO_FORCE_MACRO=Deprioritize DEMO_OOD=battery` 로 재현: `ran_milp=true`,
`n_candidate_edges=0`). 즉 G6 은 실행 레인 기준으로 이 macro 에서 원리적으로 **FAIL** 할 수
있다 — 이 파일 스스로는 그 사실을 감추지 않는다: `by_macro`가 macro 별로 갈라 보여주고,
`pass` 는 `n_ran_milp==0`(전 팔 무솔버)를 요구하므로 Deprioritize+battery 조합이 산출물에
있으면 정직하게 FAIL 이 뜬다. 이 사실을 임의로 숨기거나 "실은 무해하다"고 재단하지 않는다
— 보고서에 그대로 남긴다(task-5-report.md).
"""
import json
import sys


def solver_free(paths):
    n, n_milp, by_macro, missing = 0, 0, {}, 0
    for p in paths:
        with open(p) as fh:
            for line in fh:
                row = json.loads(line)
                for d in row.get("decisions") or []:
                    n += 1
                    rm = d.get("ran_milp")
                    if rm is None:
                        missing += 1
                        continue
                    mac = d.get("macro")
                    slot = by_macro.setdefault(mac, [0, 0])
                    slot[0] += 1
                    if rm:
                        slot[1] += 1
                        n_milp += 1
    return {"n_decisions": n, "n_ran_milp": n_milp, "missing_field": missing,
            "by_macro": by_macro, "pass": (missing == 0 and n_milp == 0 and n > 0)}


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    out = solver_free(argv[1:])
    print("=== G6 — f 무솔버 불변식 ===")
    print("  결정 %d · ran_milp=true %d · 필드 없음 %d"
          % (out["n_decisions"], out["n_ran_milp"], out["missing_field"]))
    for mac, (tot, milp) in sorted(out["by_macro"].items(), key=lambda kv: str(kv[0])):
        flag = "  🔴 meta-level 로 가야 한다" if milp else ""
        print("    %-14s %4d 결정 · MILP %d%s" % (mac, tot, milp, flag))
    if out["missing_field"]:
        print("  🔴 ran_milp 필드가 없는 결정이 있다 — 구세대 산출물이다. 재스윕 없이는 못 잰다.")
    print("  판정: %s" % ("PASS" if out["pass"] else "FAIL"))
    return 0 if out["pass"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
