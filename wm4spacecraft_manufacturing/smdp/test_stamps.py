"""도장 계약의 단위검사. **핵심은 음성 대조다** — 도장이 없거나 다른 파일을 읽으면
정말로 죽는가. 죽지 않으면 이 게이트는 영원히 실패할 수 없는 검사이고, 그런 검사는
2026-08-16 에 실제로 하나 만들어 봤다(그렙 대상 문자열이 stdout 에 한 번도 안 나왔다)."""
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "core"))
import action_registry  # noqa: E402


def test_vocab_constant_is_declared():
    # 리뷰 라운드 1 판정 G: 도장은 "오늘 참인 것"을 선언한다. 오늘 registry 는 3/5/6 이
    # 아직 은퇴하지 않은 9팔이므로 "v2-6arms"(태스크 5 이후의 END-STATE)가 아니라
    # "v1-9arms" 다. 태스크 5 가 3/5/6 을 실제로 은퇴시키는 순간 이 문자열이
    # "v2-6arms" 로 바뀌고, 그 변경이 옳다는 것은 아래 arm-count 어서션이 증명한다.
    assert action_registry.VOCAB == "v1-9arms"


def test_vocab_declares_todays_true_arm_count():
    # dynamics_stamp() 는 hazard_enabled() 에서 **유도**되는데 vocab 문자열은 리터럴이라
    # 유도할 수 없다 — 그래서 유도 대신 "선언 <n>arms == 실제 registry 항목 수"를 기계로
    # 대조한다(리뷰 판정 G). 오늘 registry 는 은퇴 집행 전이라 9개 전부가 실제 항목이다.
    assert len(action_registry.MACROS) == 9


def test_vocab_arm_count_assertion_accepts_matching_count():
    action_registry.assert_vocab_arm_count("v1-9arms", 9)


def test_vocab_arm_count_assertion_dies_on_mismatch():
    # 이것이 판정 G 의 핵심 계약이다: 도장의 <n>arms 가 실제 registry 크기와 다르면 죽는다.
    # 태스크 5 가 3/5/6 을 은퇴시키고도 문자열을 "v2-6arms" 로 안 바꾸면 이 어서션이
    # (선언 6 vs 실제 6, 통과) 하므로 갱신을 놓치는 실수를 이 방향으로는 못 잡는다 —
    # 그러나 그 반대(문자열만 바꾸고 은퇴를 안 하거나, 은퇴하고 문자열을 안 바꾸는 실수)는
    # 정확히 이 어서션이 잡는다.
    with pytest.raises(ValueError) as e:
        action_registry.assert_vocab_arm_count("v1-9arms", 7)
    assert "9" in str(e.value)
    assert "7" in str(e.value)


def test_vocab_arm_count_assertion_dies_on_malformed_stamp():
    with pytest.raises(ValueError):
        action_registry.assert_vocab_arm_count("not-a-vocab-stamp", 9)


def test_require_vocab_accepts_matching_stamp():
    action_registry.require_vocab({"vocab": "v1-9arms"}, "테스트")


def test_require_vocab_dies_on_missing_stamp():
    with pytest.raises(ValueError) as e:
        action_registry.require_vocab({"objective_hash": "19819377a7f8ebb2"}, "구세대 파일")
    assert "vocab" in str(e.value)


def test_require_vocab_dies_on_stale_stamp():
    with pytest.raises(ValueError) as e:
        action_registry.require_vocab({"vocab": "v1-8arms"}, "구세대 파일")
    assert "v1-8arms" in str(e.value)


def test_require_dynamics_dies_on_mismatch():
    action_registry.require_dynamics({"dynamics": "hazard-on"}, "hazard-on", "신세대")
    with pytest.raises(ValueError):
        action_registry.require_dynamics({"dynamics": "hazard-off"}, "hazard-on", "구세대")
    with pytest.raises(ValueError):
        action_registry.require_dynamics({}, "hazard-on", "도장 없음")
