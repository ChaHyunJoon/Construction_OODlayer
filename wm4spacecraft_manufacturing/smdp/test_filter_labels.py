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


def _row(**kw):
    """단위검사용 행. `hz_seed` 를 기본으로 실어 준다 — 필터가 `dynamics` 도장을 **행이 나르는
    증거에서 유도**하므로(hz_seed == -1 <=> hazard-off), 증거가 없는 행은 일부러 죽는다.
    그 하드 스톱 자체는 아래 test_dynamics_* 가 따로 잡는다."""
    kw.setdefault("hz_seed", -1)
    return kw


def test_drops_only_retired_macros():
    rows = [_row(macro=m, kind="fault") for m in (0, 1, 2, 3, 4, 5, 6, 7, 8)]
    kept, diag = filter_labels.filter_rows(rows)
    assert [r["macro"] for r in kept] == [0, 1, 2, 4, 7, 8]
    assert diag["dropped_by_macro"] == {3: 1, 5: 1, 6: 1}


def test_macro_column_is_never_remapped():
    rows = [_row(macro=7, kind="zone"), _row(macro=8, kind="battery")]
    kept, _ = filter_labels.filter_rows(rows)
    assert [r["macro"] for r in kept] == [7, 8]   # 0..5 로 다시 매기지 않는다


def test_survivors_get_the_vocab_stamp():
    kept, diag = filter_labels.filter_rows([_row(macro=1, kind="fault")])
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
    rows = [_row(macro=0, kind="battery", valid_mask=[0, 1, 2, 4, 5, 6])]
    kept, _ = filter_labels.filter_rows(rows)
    assert kept[0]["valid_mask"] == [0, 1, 2, 4]


def test_valid_mask_without_retired_ids_is_untouched():
    rows = [_row(macro=7, kind="zone", valid_mask=[0, 7])]
    kept, _ = filter_labels.filter_rows(rows)
    assert kept[0]["valid_mask"] == [0, 7]


def test_valid_mask_absent_or_none_is_untouched():
    rows = [_row(macro=0, kind="fault"), _row(macro=0, kind="fault", valid_mask=None)]
    kept, _ = filter_labels.filter_rows(rows)
    assert "valid_mask" not in kept[0]
    assert kept[1]["valid_mask"] is None


def test_conservation_invariant_holds_on_normal_input():
    rows = [_row(macro=m, kind="fault") for m in (0, 1, 2, 3, 4, 5, 6, 7, 8)] * 10
    kept, diag = filter_labels.filter_rows(rows)
    assert len(kept) + sum(diag["dropped_by_macro"].values()) == len(rows)


def test_arms_labeled_recomputed_from_survivors():
    """task-6b-review: arms_labeled 는 그 instance 의 생존 행 수를 나타내는 instance-level
    파생 집계다. 필터 이전 값(6, macro 5/6 포함)을 그대로 남기면 은퇴 행 두 개가 빠진 뒤에도
    거짓말을 한다 — 실제 생존 행 수(4)로 다시 세야 한다."""
    rows = [_row(instance="i1", macro=m, arms_labeled=6) for m in (0, 1, 2, 4, 5, 6)]
    kept, _ = filter_labels.filter_rows(rows)
    assert [r["arms_labeled"] for r in kept] == [4, 4, 4, 4]


def test_arms_labeled_absent_field_is_untouched():
    rows = [_row(instance="i2", macro=0)]
    kept, _ = filter_labels.filter_rows(rows)
    assert "arms_labeled" not in kept[0]


def test_cross_arm_aggregate_check_catches_perturbation():
    """음성 대조 — 표본 검사가 아니라 전수 검사임을 증명한다. 두 행 중 하나만 부패시켜도
    빨개진다. 기대값은 **입력**(첫 인자)에서 독립적으로 유도된다."""
    rows = [_row(instance="i3", macro=0), _row(instance="i3", macro=1)]
    kept = [dict(r, arms_labeled=2) for r in rows]
    filter_labels._assert_cross_arm_aggregates_fresh(rows, kept)  # 부패 전 — 통과해야 정상
    kept[1]["arms_labeled"] = 999
    with pytest.raises(AssertionError):
        filter_labels._assert_cross_arm_aggregates_fresh(rows, kept)


def test_aggregate_check_catches_a_wrong_formula_not_just_a_skipped_write():
    """🔴 final-review D-1 이 지적한 항진성. 옛 판은 `_fix_cross_arm_aggregates` 와 **같은
    공식**(kept 그룹 크기)을 다시 돌려 대조했으므로 "썼는가"만 볼 수 있었다. 이제 기대값은
    입력에서 따로 유도되므로, 쓰기가 **돌았지만 공식이 틀린** 경우에도 빨개진다."""
    rows = [_row(instance="i4", macro=m, arms_labeled=6) for m in (0, 1, 2, 4, 5, 6)]
    kept = [dict(r) for r in rows if r["macro"] not in filter_labels.RETIRED_MACROS]
    for r in kept:                       # 생존 4행인데 공식이 +1 로 틀렸다
        r["arms_labeled"] = len(kept) + 1
    with pytest.raises(AssertionError):
        filter_labels._assert_cross_arm_aggregates_fresh(rows, kept)


def test_premise_check_rejects_a_field_that_is_not_the_group_size(monkeypatch):
    """🔴 옛 판이 **놓치던** 실패 모양(실측 확인): 뜻이 "행 수"가 아닌 필드를
    CROSS_ARM_AGGREGATE_FIELDS 에 넣으면 `_fix_cross_arm_aggregates` 가 그것을 조용히
    덮어썼고, 같은 공식을 다시 돌리는 사후 검사는 그 부패를 **확인해 줬다**. 이제
    덮어쓰기 이전의 입력에서 전제를 검사하므로 즉시 빨개진다."""
    monkeypatch.setattr(filter_labels, "CROSS_ARM_AGGREGATE_FIELDS",
                        ("arms_labeled", "n_spare_cfg"))
    rows = [_row(instance="i5", macro=m, arms_labeled=2, n_spare_cfg=0) for m in (0, 1)]
    with pytest.raises(AssertionError, match="전제 위반"):
        filter_labels.filter_rows(rows)


def test_dynamics_stamp_is_derived_from_hz_seed_not_invented():
    """hz_seed == -1  <=>  enable_hazard! 를 한 번도 안 불렀다  <=>  hazard-off
    (gen_oracle_dataset.jl:1844/:2118, src/smdp/hazard.jl:166)."""
    kept, _ = filter_labels.filter_rows([_row(macro=0, hz_seed=-1),
                                         _row(macro=1, hz_seed=7)])
    assert [r["dynamics"] for r in kept] == ["hazard-off", "hazard-on"]


def test_dynamics_stamp_refuses_to_guess():
    """증거가 없는 행에서는 도장을 짐작으로 찍지 않고 죽는다 — 짐작하면 이 도장이 막으려는
    바로 그 실패(낡은 행이 신세대로 위장하는 것)를 이 코드가 만들게 된다."""
    with pytest.raises(AssertionError, match="hz_seed"):
        filter_labels.filter_rows([{"macro": 0, "kind": "fault"}])


def test_objective_hash_is_never_restamped():
    """🔴 필터는 목적함수를 바꾸지 않았다. 행의 (구세대) 해시가 그 행에 대한 참이므로
    현행 해시로 갈아 끼우지 않는다 — .claude/CLAUDE.md §2026-08-19."""
    kept, _ = filter_labels.filter_rows([_row(macro=0, objective_hash="19819377a7f8ebb2")])
    assert kept[0]["objective_hash"] == "19819377a7f8ebb2"


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
