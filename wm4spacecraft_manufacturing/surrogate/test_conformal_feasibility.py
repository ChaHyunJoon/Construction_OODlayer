"""conformal 실현가능성 추정기의 **산술**을 합성 픽스처로 못박는다.

🔴 왜 합성인가: 실데이터에는 정답이 없다. 여기서 확인하는 것은 "측정값이 맞다"가 아니라
"추정량이 정의대로 계산된다"이다. 실데이터 측정은 Task 2 가 하고, 그 숫자의 재유도는
독립 에이전트(Task 3)가 한다. 이 파일이 그 둘 사이의 유일한 산술 보증이다.
"""
import math
import os
import sys

import numpy as np
import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "core"))

import conformal_feasibility as cf                            # noqa: E402


# ---- conformal_quantile: 유한표본 보정 k = ceil((n+1)(1-alpha)) --------------------------
def test_quantile_picks_kth_smallest():
    # n=9, alpha=0.1 -> k = ceil(10*0.9) = 9 -> 9번째로 작은 값 = 90
    res = [10, 20, 30, 40, 50, 60, 70, 80, 90]
    assert cf.conformal_quantile(res, 0.1) == 90


def test_quantile_is_infinite_when_sample_too_small():
    # n=9, alpha=0.05 -> k = ceil(10*0.95) = 10 > 9 -> 표본 부족
    # 🔴 이것은 "q 가 크다"가 아니라 "q 를 못 잰다"다. 큰 수로 뭉개지 않는다.
    assert cf.conformal_quantile([10, 20, 30, 40, 50, 60, 70, 80, 90], 0.05) == math.inf


def test_quantile_is_order_invariant():
    assert cf.conformal_quantile([90, 10, 50, 30, 70], 0.3) == \
           cf.conformal_quantile([10, 30, 50, 70, 90], 0.3)


def test_quantile_rejects_empty():
    with pytest.raises(ValueError):
        cf.conformal_quantile([], 0.1)


# ---- escalation: gap <= 2q -------------------------------------------------------------
def _rows(spec):
    """spec = {instance: [macro,...]} -> 최소 행들. Ĵ 는 oof 배열로 따로 준다."""
    out = []
    for iid, macros in spec.items():
        for m in macros:
            out.append({"instance": iid, "macro": m, "kind": "synthetic"})
    return out


def test_escalates_when_gap_below_two_q():
    rows = _rows({"i1": [0, 1]})
    oof = np.array([100.0, 105.0])          # gap = 5
    got = cf.escalation(oof, rows, q=3.0)   # 2q = 6 >= 5 -> 격상
    assert got["per_instance"]["i1"]["escalate"] is True
    assert got["per_instance"]["i1"]["gap"] == pytest.approx(5.0)
    assert got["rate"] == pytest.approx(1.0)


def test_does_not_escalate_when_gap_above_two_q():
    rows = _rows({"i1": [0, 1]})
    oof = np.array([100.0, 105.0])          # gap = 5
    got = cf.escalation(oof, rows, q=2.0)   # 2q = 4 < 5 -> 격상 안 함
    assert got["per_instance"]["i1"]["escalate"] is False
    assert got["rate"] == pytest.approx(0.0)


def test_gap_uses_top1_and_top2_not_file_order():
    # 파일 순서는 [큰, 작은, 중간]. top-1=10, top-2=20 이므로 gap=10.
    rows = _rows({"i1": [0, 1, 2]})
    oof = np.array([50.0, 10.0, 20.0])
    got = cf.escalation(oof, rows, q=100.0)
    assert got["per_instance"]["i1"]["gap"] == pytest.approx(10.0)


def test_single_arm_escalates_as_information_absence():
    # 🔴 팔이 하나면 확신이 아니라 **정보 부재**다 (설계서 §3).
    rows = _rows({"i1": [0]})
    got = cf.escalation(np.array([100.0]), rows, q=0.0)
    assert got["per_instance"]["i1"]["escalate"] is True
    assert got["per_instance"]["i1"]["reason"] == "single_arm"


def test_infinite_q_escalates_everything():
    rows = _rows({"i1": [0, 1], "i2": [0, 1, 2]})
    oof = np.array([1.0, 1e9, 1.0, 2.0, 3.0])
    got = cf.escalation(oof, rows, q=math.inf)
    assert got["rate"] == pytest.approx(1.0)


def test_rate_is_over_instances_not_rows():
    # i1: 3행 격상 / i2: 2행 격상 안 함 -> instance 기준 rate = 0.5 (행 기준이면 0.6)
    rows = _rows({"i1": [0, 1, 2], "i2": [0, 1]})
    oof = np.array([100.0, 101.0, 102.0, 0.0, 1000.0])
    got = cf.escalation(oof, rows, q=1.0)   # 2q = 2
    assert got["n"] == 2
    assert got["rate"] == pytest.approx(0.5)


# ---- coverage_leave_instance_out -------------------------------------------------------
def test_coverage_excludes_own_instance_from_quantile():
    # i1 의 잔차는 거대하다. 자기를 포함해 q 를 뽑으면 자기가 덮이지만,
    # 빼고 뽑으면 안 덮인다. 그 차이가 이 함수의 존재 이유다.
    rows = _rows({"i1": [0], "i2": [0], "i3": [0], "i4": [0], "i5": [0]})
    res = np.array([1000.0, 1.0, 2.0, 3.0, 4.0])
    got = cf.coverage_leave_instance_out(res, rows, alpha=0.5)
    # i1 의 q 는 {1,2,3,4} 에서 뽑히므로 1000 을 못 덮는다.
    assert got["per_instance_q"]["i1"] < 1000.0
    assert got["coverage"] < 1.0


def test_coverage_is_one_when_all_residuals_equal():
    rows = _rows({"i1": [0], "i2": [0], "i3": [0], "i4": [0], "i5": [0]})
    res = np.array([7.0, 7.0, 7.0, 7.0, 7.0])
    got = cf.coverage_leave_instance_out(res, rows, alpha=0.3)
    assert got["coverage"] == pytest.approx(1.0)
