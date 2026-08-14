#!/usr/bin/env python3
"""surrogate_gates 의 단위검사 — 게이트가 실제로 붕괴를 잡는지 합성 데이터로 증명한다."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from surrogate_gates import (constant_policy_baseline, gate_g3_beats_constant,
                             gate_g4_kind_discrimination)

FAILS = []


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + ("   " + detail if detail else ""))
    if not cond:
        FAILS.append(name)


# battery 에서는 8(SwapBattery)이, fault 에서는 1(Replace)이 정답인 합성 격자.
INSTANCES = (
    [{"instance": "b%d" % i, "kind": "battery",
      "truth": {0: 0.0, 1: 5.0, 8: 10.0}, "valid": [0, 1, 8]} for i in range(10)] +
    [{"instance": "f%d" % i, "kind": "fault",
      "truth": {0: 0.0, 1: 10.0, 8: 2.0}, "valid": [0, 1, 8]} for i in range(10)]
)

PERFECT  = {r["instance"]: (8 if r["kind"] == "battery" else 1) for r in INSTANCES}
ALWAYS_1 = {r["instance"]: 1 for r in INSTANCES}          # 2026-08-13 의 실제 결함 모양
ALWAYS_0 = {r["instance"]: 0 for r in INSTANCES}


def main():
    print("== surrogate_gates 단위검사 ==")

    base = constant_policy_baseline(INSTANCES)
    check("상수 baseline 이 세 팔 전부를 계산한다", set(base) == {0, 1, 8}, str(base))
    # 항상 1 = battery 에서 5 손해, fault 에서 0 손해 -> 평균 2.5
    check("항상-Replace 의 평균 regret = 2.5", abs(base[1] - 2.5) < 1e-9, str(base[1]))

    ok, info = gate_g3_beats_constant(INSTANCES, PERFECT)
    check("G3: 완벽한 정책은 통과", ok, str(info["model_regret"]))

    ok, info = gate_g3_beats_constant(INSTANCES, ALWAYS_1)
    check("G3: 상수 정책은 **실패**해야 한다", not ok,
          "model=%.2f best_const=%.2f" % (info["model_regret"], info["best_constant_regret"]))

    ok, info = gate_g3_beats_constant(INSTANCES, ALWAYS_0)
    check("G3: 다른 상수 정책도 실패", not ok)

    ok, info = gate_g4_kind_discrimination(INSTANCES, PERFECT)
    check("G4: kind 마다 다른 답이면 통과", ok, str(info["by_kind"]))

    ok, info = gate_g4_kind_discrimination(INSTANCES, ALWAYS_1)
    check("G4: 모든 kind 에 같은 답이면 **실패**", not ok,
          str(info["identical_kind_pairs"]))

    print("\n%s" % ("전부 통과" if not FAILS else "실패 %d개: %s" % (len(FAILS), FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
