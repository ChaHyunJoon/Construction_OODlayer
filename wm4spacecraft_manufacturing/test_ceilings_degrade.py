#!/usr/bin/env python3
"""compute_ceilings 가 J 불가 행에서 죽지 않고 미측정으로 낮추는지 검사한다.

왜 이 검사가 있는가
==================
2026-08-14 실측: fault kind 라벨 행은 `energy_J=None` 이다(배터리 레이어가
`kind===:battery` instance 에서만 켜지기 때문 — gen_oracle_dataset.jl:1176 `_arm_battery!`).
`objective.J` 는 그런 행을 설계대로 던진다. 그 예외가 build_final_table.py 전체를 죽여서
**표가 하나도 안 나왔다.**

고치는 방향이 중요하다: J 를 0 으로 채우거나 그 행을 조용히 빼면 천장이 낙관 편향된다.
계산할 수 없는 행은 **세어서 이름으로 남긴다.**

축 값의 두 가지 모양 (실제 코드에 맞춘 계약)
--------------------------------------------
  · `None`  — 라벨 **파일 자체가 없다**. 예전부터 있던 모양이고 소비처가 MISSING_TOKEN 을 낸다.
  · dict    — 파일이 있다. 그러면 반드시 `scored`/`unscorable` 를 담는다.
              `scored == 0` 이면 `n == 0` 이고 통계는 전부 None 이다(0.0 이 아니다).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import objective                                # noqa: E402
from build_md_report import compute_ceilings    # noqa: E402

FAILS = []


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + ("   " + detail if detail else ""))
    if not cond:
        FAILS.append(name)


def main():
    print("== compute_ceilings 미측정 강등 ==")

    from pathlib import Path
    oracle_dir = Path(os.path.dirname(os.path.abspath(__file__))) / "oracle" / "out"

    # 계약 (a): 실제 라벨 디렉토리로 불러도 예외가 안 난다.
    try:
        ceilings = compute_ceilings(oracle_dir)
        raised = None
    except objective.ObjectiveError as e:
        ceilings, raised = None, e
    check("실제 라벨셋에서 ObjectiveError 가 안 난다", raised is None, str(raised or ""))

    if ceilings is None:
        print("\n실패 1개 이상 — 아래 검사는 건너뛴다")
        return 1

    axes = sorted(ceilings)
    check("축이 하나 이상 있다", len(axes) > 0, str(axes))

    present = [k for k in axes if ceilings[k] is not None]
    absent = [k for k in axes if ceilings[k] is None]
    print("  ..  라벨 파일 있는 축: %s / 없는 축: %s" % (present, absent))

    # 계약 (b): 파일이 있는 축은 scored/unscorable 를 센다.
    for k in present:
        v = ceilings[k]
        check("축 %s 에 scored 가 있다" % k, isinstance(v, dict) and "scored" in v, str(v)[:120])
        check("축 %s 에 unscorable 이 있다" % k, isinstance(v, dict) and "unscorable" in v,
              str(v)[:120])

    # 계약 (c): 채점 가능한 행이 0 이면 통계가 None 이다 (0 이 아니다).
    for k in present:
        v = ceilings[k]
        if v.get("scored", 0) == 0:
            check("축 %s: 채점 0건이면 completion_rate 가 None" % k,
                  v.get("completion_rate") is None, str(v.get("completion_rate")))
            check("축 %s: 채점 0건이면 n 이 0" % k, v.get("n") == 0, str(v.get("n")))

    # 계약 (d): 아무 축도 0.0 으로 채워지지 않았다.
    zero_filled = [k for k in present
                   if ceilings[k].get("scored", 0) == 0
                   and ceilings[k].get("completion_rate") == 0.0]
    check("채점 0건인 축이 0.0 으로 채워지지 않았다", not zero_filled, str(zero_filled))

    # 계약 (e): 하나라도 unscorable 이 실제로 있다 — 없으면 이 검사가 아무것도 안 지킨다.
    #           (2026-08-14 실측: fault 축 라벨 행에 energy_J 가 없다.)
    total_unscorable = sum(ceilings[k].get("unscorable", 0) for k in present)
    check("unscorable 이 실제로 세어졌다(검사가 헛돌지 않는다)", total_unscorable > 0,
          "총 %d" % total_unscorable)

    # 계약 (f): 채점된 축은 통계가 실제로 나온다(전부 미측정으로 뭉개지 않는다).
    scored_axes = [k for k in present if ceilings[k].get("scored", 0) > 0]
    check("채점 가능한 축이 하나 이상 있다", len(scored_axes) > 0, str(scored_axes))

    for k in present:
        v = ceilings[k]
        print("  ..  %-14s scored=%-3s unscorable=%-3s n=%-3s completion_rate=%s"
              % (k, v.get("scored"), v.get("unscorable"), v.get("n"), v.get("completion_rate")))

    print("\n%s" % ("전부 통과" if not FAILS else "실패 %d개: %s" % (len(FAILS), FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
