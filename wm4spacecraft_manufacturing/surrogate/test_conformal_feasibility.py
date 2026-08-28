"""conformal 실현가능성 추정기의 **산술**을 합성 픽스처로 못박는다.

🔴 왜 합성인가: 실데이터에는 정답이 없다. 여기서 확인하는 것은 "측정값이 맞다"가 아니라
"추정량이 정의대로 계산된다"이다. 실데이터 측정은 Task 2 가 하고, 그 숫자의 재유도는
독립 에이전트(Task 3)가 한다. 이 파일이 그 둘 사이의 유일한 산술 보증이다.
"""
import io
import json
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


# ---- measure(): "못 잰다" 대 "쟀는데 크다" — 리뷰가 잡은 결함 -----------------------------
# `measure()` 는 `oof_predictions`/`true_J` 를 통해서만 모델 적합에 닿는다. 여기서는 둘 다
# monkeypatch 해서 합성 oof/잔차를 직접 주입한다 — 실 라벨셋도, 모델 적합도 필요 없다.
def _patch_oof_and_truth(monkeypatch, oof, jt):
    monkeypatch.setattr(cf, "oof_predictions", lambda rows: np.asarray(oof, dtype=float))
    monkeypatch.setattr(cf, "true_J", lambda rows: np.asarray(jt, dtype=float))


def test_measure_marks_unmeasurable_when_all_q_infinite(monkeypatch):
    # 3 instance, 각 1행 -> instance 하나를 빼면 다른 잔차가 2개뿐이다.
    # alpha=0.01 이면 k = ceil(3*0.99) = 3 > 2 -> 모든 instance 의 q_i 가 +inf.
    rows = _rows({"i1": [0], "i2": [0], "i3": [0]})
    oof = np.array([1.0, 2.0, 3.0])
    _patch_oof_and_truth(monkeypatch, oof, jt=np.zeros(3))   # res = |oof-0| = oof
    got = cf.measure(rows, alphas=[0.01])
    row = got["alphas"][0]
    assert row["n_q_infinite"] == 3
    assert row["honest_unmeasurable"] is True
    assert row["R4"] == "UNMEASURABLE"
    # 🔴 이게 이 회귀의 핵심이다: 트리비얼한 1.0 이 아니라 None 이어야 한다.
    assert row["coverage_holdout"] is None
    assert row["escalation_rate_honest"] is None
    # per_instance_q 는 여전히 내보내져서 독자가 "왜" 를 볼 수 있어야 한다.
    assert set(row["per_instance_q"]) == {"i1", "i2", "i3"}
    assert all(math.isinf(v) for v in row["per_instance_q"].values())


def test_measure_n_q_infinite_counts_partial_correctly(monkeypatch):
    # i1 은 2행(자기를 빼면 다른 잔차 3개), i2/i3/i4 는 1행씩(자기를 빼면 다른 잔차 4개).
    # alpha=0.2 로 두 그룹을 가른다: n_oth=3 -> k=ceil(4*0.8)=4>3 (i1 만 +inf).
    # n_oth=4 -> k=ceil(5*0.8)=4<=4 (i2/i3/i4 는 유한).
    rows = _rows({"i1": [0, 1], "i2": [0], "i3": [0], "i4": [0]})
    oof = np.array([5.0, 6.0, 1.0, 2.0, 3.0])
    _patch_oof_and_truth(monkeypatch, oof, jt=np.zeros(5))
    got = cf.measure(rows, alphas=[0.2])
    row = got["alphas"][0]
    assert row["n_q_infinite"] == 1
    assert math.isinf(row["per_instance_q"]["i1"])
    assert not math.isinf(row["per_instance_q"]["i2"])
    assert not math.isinf(row["per_instance_q"]["i3"])
    assert not math.isinf(row["per_instance_q"]["i4"])
    # 하나라도 무한이면 그 alpha 행 전체가 UNMEASURABLE (부분 측정을 PASS/FAIL 로 안 낸다).
    assert row["R4"] == "UNMEASURABLE"
    assert row["coverage_holdout"] is None


def test_measure_marks_vacuous_when_need_nonpositive(monkeypatch):
    # alpha=0.99 -> need = 1 - 0.99 - 0.05 = -0.04 <= 0 -> 문지방이 항상 통과라 재는 의미가 없다.
    # (alpha=0.95 는 need 가 부동소수 오차로 정확히 0.0 이 아니라 미세하게 양수가 될 수 있어
    # 피한다 — -0.04 는 그 오차 폭보다 훨씬 커서 안정적이다.)
    rows = _rows({"i1": [0, 1], "i2": [0], "i3": [0], "i4": [0]})
    oof = np.array([5.0, 6.0, 1.0, 2.0, 3.0])
    _patch_oof_and_truth(monkeypatch, oof, jt=np.zeros(5))
    got = cf.measure(rows, alphas=[0.99])
    row = got["alphas"][0]
    assert row["coverage_required"] == pytest.approx(-0.04)
    assert row["R4"] == "VACUOUS"


def test_dump_raises_on_nan_instead_of_emitting_literal_nan():
    # 🔴 `allow_nan=False` 가 없으면 json.dump 가 리터럴 NaN 을 조용히 써 버린다 — 그건
    # JSON 표준도 아니고 다음 소비처가 못 읽는다. NaN 은 시끄럽게 죽어야 한다.
    payload = cf._jsonable({"x": float("nan"), "y": [1.0, float("inf")]})
    # +inf 는 여전히 "Infinity" 문자열로 살아남아야 한다(회귀 아님).
    assert payload["y"][1] == "Infinity"
    buf = io.StringIO()
    with pytest.raises(ValueError):
        json.dump(payload, buf, allow_nan=False)


def test_jsonable_preserves_the_sign_of_negative_infinity():
    # 🔴 -inf 를 "Infinity" 로 접으면 부호가 사라진다. 소비처가 그것을 float 로 되읽으면
    # `gap <= 2q` 가 트리비얼하게 참이 되어 **모든 escalate 가 False -> True 로 뒤집힌다.**
    # 오늘의 산출물에 음의 무한대는 없지만, "없으니 접어도 된다" 는 논리는 검사 없는 도장과
    # 같은 논리다.
    payload = cf._jsonable({"pos": float("inf"), "neg": float("-inf"),
                            "nested": [{"q": float("-inf")}]})
    assert payload["pos"] == "Infinity"
    assert payload["neg"] == "-Infinity"
    assert payload["nested"][0]["q"] == "-Infinity"
    # 왕복: 두 문자열이 서로 다른 값으로 되읽혀야 한다.
    assert float(payload["neg"]) == -math.inf
    assert float(payload["pos"]) == math.inf


# ---- require_objective_stamp: 찍기 전에 읽는다 -------------------------------------------
# 🔴 합성 픽스처로만 시험한다. 실 라벨셋은 오늘 일치하므로 불일치 경로를 못 밟고, 실데이터에
# 매인 시험은 라벨이 바뀔 때 같이 무너진다.
def _stamped_rows(stamps):
    return [{"instance": "i%d" % i, "macro": 0, "objective_hash": h}
            for i, h in enumerate(stamps)]


def test_objective_stamp_passes_when_all_rows_match_current_config():
    cur = cf.objective.objective_hash()
    cf.require_objective_stamp(_stamped_rows([cur, cur, cur]), "synthetic")


def test_objective_stamp_raises_on_stale_stamp():
    # 구세대 도장 하나짜리 파일: `true_J` 가 현행 config 로 J 를 다시 계산하므로 세대 혼합이다.
    with pytest.raises(ValueError) as e:
        cf.require_objective_stamp(_stamped_rows(["deadbeefdeadbeef"] * 3), "synthetic")
    assert "목적함수 도장 불일치" in str(e.value)


def test_objective_stamp_raises_on_mixed_stamps_even_if_one_is_current():
    # 🔴 반은 현행, 반은 구세대 -- `n44_plus78` 이 정확히 이 모양이었다. 균일성도 요구한다.
    cur = cf.objective.objective_hash()
    with pytest.raises(ValueError) as e:
        cf.require_objective_stamp(_stamped_rows([cur, "deadbeefdeadbeef"]), "synthetic")
    assert "목적함수 도장 불일치" in str(e.value)


def test_objective_stamp_raises_when_column_is_absent():
    with pytest.raises(ValueError) as e:
        cf.require_objective_stamp([{"instance": "i1", "macro": 0}], "synthetic")
    assert "없는 행이" in str(e.value)
