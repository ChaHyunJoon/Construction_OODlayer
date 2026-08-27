"""스윕 사후 게이트 `_router_drove` 가 **라우터가 실제로 몰았는지**를 잰다.

🔴 왜 (2026-08-27, 최종 리뷰 F7): 이 게이트는 `router_target ∈ {surrogate, dspy}` 로
"라우터가 몰았다" 를 추론했는데, Task 3 이 격상·레인 선택을 novelty 교정에서 뗀 뒤로 그
추론이 **양방향으로** 틀려졌다.

  · 거짓 음성 — `--router 1 --policies canonical` + 교정 없음: 라우터가 레인을 몰아도
    `rt["target"]` 은 기본 정책 이름에 머문다(target 을 덮어쓰는 것은 novelty 축뿐). 실제로
    몬 런이 `"gate failed open"` 으로 보고된다.
  · 거짓 양성 — `--policies surrogate`: 라우터가 꺼져 있어도 target 이 "surrogate" 라 통과한다.

그래서 이제 진실원(`router_axis` · `router_drives`)을 직접 읽는다. 그리고 그 변경이 `router_axis`
의 **첫 소비처**다 — 설계서 §5("도장만 찍고 소비처를 안 만드는 것이 …그 실패다").

무엇이 바뀌면 이 파일이 빨개지나: `_router_drove` 가 다시 `router_target` 만 보게 되거나
(→ `test_router_drove_...canonical` 이 빨강), 축 도장이 없는 옛 산출물의 폴백을 지우면
(→ `test_pre_task3_artifact_still_uses_the_old_target_test` 가 빨강).
"""
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import llm_ood_eval as ev  # noqa: E402


def _summary(tmp_path, decisions):
    """요약 jsonl 한 줄을 쓴다 — `_router_drove` 가 읽는 실제 형식."""
    row = {"case": "c", "ood_seed": 1, "policy": "canonical", "router": "1",
           "decisions": decisions}
    p = tmp_path / "summary.jsonl"
    io.open(str(p), "w", encoding="utf-8").write(json.dumps(row) + "\n")
    return p


def test_router_drove_is_true_when_the_lane_was_selected_under_canonical(tmp_path):
    """🔴 거짓 음성이 닫힌다: 라우터가 몰았는데 target 은 기본 정책에 머문 실제 모양."""
    p = _summary(tmp_path, [{"router_target": "canonical", "router_axis": "vocabulary_gap",
                             "router_drives": True, "support_measured": True}])
    ok, why = ev._router_drove(p, "c", 1, "canonical", "1")
    assert ok, why


def test_router_did_not_drive_when_no_decision_selected_a_lane(tmp_path):
    """음성 대조: 도장은 있는데(=이 세대 산출물) 레인 선택이 한 번도 안 돌았다 → 빨강."""
    p = _summary(tmp_path, [{"router_target": "canonical", "router_axis": None,
                             "router_drives": False, "support_measured": None}])
    ok, why = ev._router_drove(p, "c", 1, "canonical", "1")
    assert not ok
    assert "failed open" in why


def test_router_target_alone_is_no_longer_enough_to_pass(tmp_path):
    """🔴 거짓 양성이 닫힌다: `--policies surrogate` 라 target 이 surrogate 지만 라우터는 안 몰았다."""
    p = _summary(tmp_path, [{"router_target": "surrogate", "router_axis": None,
                             "router_drives": False}])
    ok, why = ev._router_drove(p, "c", 1, "canonical", "1")
    assert not ok, "router_target 만으로 통과하면 F7 의 거짓 양성이 그대로다"


def test_pre_task3_artifact_still_uses_the_old_target_test(tmp_path):
    """축 도장 자체가 없는 옛 산출물(Task 3 이전)은 예전 판정으로 되돌아간다."""
    p = _summary(tmp_path, [{"router_target": "dspy"}])
    ok, why = ev._router_drove(p, "c", 1, "canonical", "1")
    assert ok, why
    p2 = _summary(tmp_path, [{"router_target": "canonical"}])
    ok2, why2 = ev._router_drove(p2, "c", 1, "canonical", "1")
    assert not ok2
    assert "pre-Task-3" in why2


def test_flag_mismatch_is_still_reported_first(tmp_path):
    p = _summary(tmp_path, [{"router_axis": "vocabulary_gap"}])
    ok, why = ev._router_drove(p, "c", 1, "canonical", "0")
    assert not ok
    assert "flag not passed" in why
