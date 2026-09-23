"""미등록 매크로 id 는 **조용히 NOOP 이 되면 안 된다**.

🔴 왜 (2026-08-27 실측): `psi()` 가 `MACRO_SPECS.get(int(action), [])` 로 읽고 바로 아래
`if not names:` 가 NOOP 의 ψ 를 돌려줬다. 그래서 `psi(99) == psi(0)` 이 True 였고,
`predict_J([macro=99 행])` 이 **예외 없이** NOOP 의 값을 그럴듯하게 돌려줬다.
매크로를 주조하는 세계에서는 낡은 id 가 돌아다니므로 이 자리가 거짓 라벨을 만든다.

⚠️ NOOP(0)은 레지스트리에 **키로 존재하고 값이 빈 리스트다**(`MACRO_SPECS == {0: [],
1: ['ReplaceAgent'], 2: ['SwapBattery']}`). 그래서 판정 기준은 truthiness 가 아니라
**멤버십**이다 — 그걸 뒤집으면 NOOP 이 죽는다.
"""
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import features_agnostic  # noqa: E402


def test_unknown_macro_id_raises():
    with pytest.raises(KeyError):
        features_agnostic.psi(99)


def test_noop_still_works_it_is_registered_with_an_empty_spec():
    """🔴 회귀 방지: 멤버십이 아니라 truthiness 로 고치면 NOOP 이 여기서 죽는다."""
    v = features_agnostic.psi(0)
    assert isinstance(v, dict)
    assert v["a_intervenes"] == 0.0
    assert v["a_reversible"] == 1.0


def test_registered_macros_are_unchanged():
    for mid in features_agnostic.MACRO_SPECS:
        v = features_agnostic.psi(mid)
        assert set(v) == set(features_agnostic.PSI_AXES)


def test_primitive_name_lists_still_bypass_the_registry():
    """리스트 입력은 레지스트리를 안 거친다 — 그 경로는 안 건드린다."""
    v = features_agnostic.psi(["ReplaceAgent"])
    assert v["a_intervenes"] == 1.0


def test_the_error_names_the_id_and_the_registry():
    with pytest.raises(KeyError) as e:
        features_agnostic.psi(99)
    msg = str(e.value)
    assert "99" in msg
    assert "action_registry" in msg
