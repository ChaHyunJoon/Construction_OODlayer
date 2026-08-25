"""SoC 임계값은 한 곳에서만 정의된다 -- 두 채점기가 같은 severity class 를 내야 한다."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import reference_policy  # noqa: E402

# Julia 쪽 ood_truth.jl 의 REPLACE_SOC_THRESHOLD 와 같은 값이어야 한다(심볼로 찾을 것 -- 줄번호는
# 이 레포에서 자주 밀린다).
JULIA_REPLACE_SOC_THRESHOLD = 0.2


def test_threshold_matches_julia():
    assert reference_policy.BATTERY_DEEP_SOC == JULIA_REPLACE_SOC_THRESHOLD


def test_scoring_grid():
    """SoC 격자에서 정답/채점제외가 임계값과 정확히 일치하는지."""
    valid = ["NOOP", "Replace", "SwapBattery"]
    for soc, expected in ((0.02, "SwapBattery"), (0.15, "SwapBattery"),
                          (0.20, "SwapBattery"), (0.25, None), (0.45, None), (0.60, None)):
        ev = {"truth": "BatteryTruth", "soc": soc, "valid": valid}
        a_star, basis, _ = reference_policy.reference_action(ev)
        assert basis == "battery"
        assert a_star == expected, "SoC %.2f -> %r (기대 %r)" % (soc, a_star, expected)
