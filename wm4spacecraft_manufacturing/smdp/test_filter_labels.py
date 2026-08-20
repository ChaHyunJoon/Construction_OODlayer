"""라벨 필터의 단위검사. 핵심은 **remap 이 절대 일어나지 않는 것**이다 —
정수 remap 을 넣으면 구세대 macro 3 행이 ReformTeam 으로 에러 없이 재해석된다.

Task 6b (task-6-review.md 가 찾은 두 Critical 결함을 닫는다):
  - valid_mask 등 메뉴 필드에서도 은퇴 id 를 뺀다 (macro 열만 빼면 불변식이 깨진다).
  - RETIRED 는 이제 action_registry 에서 오고(Task 5 착지), 어긋나면 import 시점에 죽는다.
"""
import importlib
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "core"))
import filter_labels  # noqa: E402
import action_registry  # noqa: E402


def test_drops_only_retired_macros():
    rows = [{"macro": m, "kind": "fault"} for m in (0, 1, 2, 3, 4, 5, 6, 7, 8)]
    kept, diag = filter_labels.filter_rows(rows)
    assert [r["macro"] for r in kept] == [0, 1, 2, 4, 7, 8]
    assert diag["dropped_by_macro"] == {3: 1, 5: 1, 6: 1}


def test_macro_column_is_never_remapped():
    rows = [{"macro": 7, "kind": "zone"}, {"macro": 8, "kind": "battery"}]
    kept, _ = filter_labels.filter_rows(rows)
    assert [r["macro"] for r in kept] == [7, 8]   # 0..5 로 다시 매기지 않는다


def test_survivors_get_the_vocab_stamp():
    kept, diag = filter_labels.filter_rows([{"macro": 1, "kind": "fault"}])
    assert kept[0]["vocab"] == action_registry.VOCAB
    assert diag["stamped"] == 1


def test_empty_input_is_not_a_silent_pass():
    kept, diag = filter_labels.filter_rows([])
    assert kept == [] and diag["kept"] == 0


def test_retired_macros_derived_from_registry():
    """RETIRED_MACROS 는 이제 하드코드가 아니라 action_registry.RETIRED(dict) 에서 온다."""
    assert filter_labels.RETIRED_MACROS == frozenset(action_registry.RETIRED)
    assert filter_labels.RETIRED_MACROS == frozenset({3, 5, 6})


def test_valid_mask_strips_retired_ids():
    """task-6-review.md 2-b: macro 열만 빼고 valid_mask 를 그대로 두면 은퇴 팔(5)이
    surrogate_gates.max_cost_menu_policy 같은 소비처에 메뉴로 계속 닿는다."""
    rows = [{"macro": 0, "kind": "battery", "valid_mask": [0, 1, 2, 4, 5, 6]}]
    kept, _ = filter_labels.filter_rows(rows)
    assert kept[0]["valid_mask"] == [0, 1, 2, 4]


def test_valid_mask_without_retired_ids_is_untouched():
    rows = [{"macro": 7, "kind": "zone", "valid_mask": [0, 7]}]
    kept, _ = filter_labels.filter_rows(rows)
    assert kept[0]["valid_mask"] == [0, 7]


def test_valid_mask_absent_or_none_is_untouched():
    rows = [{"macro": 0, "kind": "fault"}, {"macro": 0, "kind": "fault", "valid_mask": None}]
    kept, _ = filter_labels.filter_rows(rows)
    assert "valid_mask" not in kept[0]
    assert kept[1]["valid_mask"] is None


def test_conservation_invariant_holds_on_normal_input():
    rows = [{"macro": m, "kind": "fault"} for m in (0, 1, 2, 3, 4, 5, 6, 7, 8)] * 10
    kept, diag = filter_labels.filter_rows(rows)
    assert len(kept) + sum(diag["dropped_by_macro"].values()) == len(rows)


def test_arms_labeled_recomputed_from_survivors():
    """task-6b-review: arms_labeled 는 그 instance 의 생존 행 수를 나타내는 instance-level
    파생 집계다. 필터 이전 값(6, macro 5/6 포함)을 그대로 남기면 은퇴 행 두 개가 빠진 뒤에도
    거짓말을 한다 — 실제 생존 행 수(4)로 다시 세야 한다."""
    rows = [{"instance": "i1", "macro": m, "arms_labeled": 6} for m in (0, 1, 2, 4, 5, 6)]
    kept, _ = filter_labels.filter_rows(rows)
    assert [r["arms_labeled"] for r in kept] == [4, 4, 4, 4]


def test_arms_labeled_absent_field_is_untouched():
    rows = [{"instance": "i2", "macro": 0}]
    kept, _ = filter_labels.filter_rows(rows)
    assert "arms_labeled" not in kept[0]


def test_cross_arm_aggregate_check_catches_perturbation():
    """음성 대조 — 표본 검사가 아니라 전수 검사임을 증명한다. 두 행 중 하나만 부패시켜도
    (filter_rows 를 통하지 않고) `_assert_cross_arm_aggregates_fresh` 를 직접 걸면 빨개진다."""
    kept = [{"instance": "i3", "arms_labeled": 2}, {"instance": "i3", "arms_labeled": 2}]
    filter_labels._assert_cross_arm_aggregates_fresh(kept)  # 부패 전 — 조용히 통과해야 정상
    kept[1]["arms_labeled"] = 999  # 주입한 부패
    with pytest.raises(AssertionError):
        filter_labels._assert_cross_arm_aggregates_fresh(kept)


def test_registry_mismatch_kills_import():
    """음성 대조: action_registry.RETIRED 가 기대(3,5,6)와 달라지면 filter_labels 를
    다시 불러오는 순간 죽어야 한다 — 조용히 넘어가면 이 assert 는 장식이다."""
    original = action_registry.RETIRED
    action_registry.RETIRED = {1: "bogus"}
    try:
        with pytest.raises(AssertionError):
            importlib.reload(filter_labels)
    finally:
        action_registry.RETIRED = original
        importlib.reload(filter_labels)  # 정상 상태로 복구
