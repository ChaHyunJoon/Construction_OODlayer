"""라벨 필터의 단위검사. 핵심은 **remap 이 절대 일어나지 않는 것**이다 —
정수 remap 을 넣으면 구세대 macro 3 행이 ReformTeam 으로 에러 없이 재해석된다."""
import os
import sys

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
