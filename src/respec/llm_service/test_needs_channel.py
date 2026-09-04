"""agent-3 이 "없다" 를 말할 채널. 유료 0건."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def test_writetoolimpl_declares_needs():
    import synthesize as SY
    assert "needs" in SY.WriteToolImpl.output_fields


def test_needs_comes_before_impl_code():
    """🔴 잘림이 스칼라를 먹지 않게 — run 1 이 `params` 한가운데서 잘려 죽었다."""
    import synthesize as SY
    order = list(SY.WriteToolImpl.output_fields)
    assert order.index("needs") < order.index("impl_code")


def test_needs_is_a_recorded_body_field():
    import synthesize as SY
    assert "needs" in SY._BODY_FIELDS
    assert "needs" not in SY._NON_STR_BODY_FIELDS   # 문자열이다


def test_blank_record_carries_needs_as_none():
    """삼상: 못 쟀으면 None 이지 "" 가 아니다."""
    import synthesize as SY
    rec = SY.blank_synthesis_record(kind="battery")
    assert rec.get("needs", "MISSING") is None
