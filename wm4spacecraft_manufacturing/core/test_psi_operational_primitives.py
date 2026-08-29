# -*- coding: utf-8 -*-
"""`psi()` 의 **리스트 경로**가 운용 원시 알파벳을 실제로 읽는지 못박는다.

🔴 왜 (2026-08-29 실측, Plan B / T6a. spec `2026-08-26-tool-synthesis-lane-design` §5-2-1
의 정정이 근거):

    psi(['release_pending_assignments','deprioritize_agent'])  -> 10축 전부 0.0
    psi(['nonsense_operation_xyz'])                            -> 10축 전부 0.0
    psi(['release_pending_assignments']) == psi(['translate_whole_build'])  -> True

`_PRIMITIVE_TABLE` 은 **DSL 원시 8종**의 표인데 `primitive_registry.json` 의 **운용 원시
19종**은 거기 없었고, `if n in _PRIMITIVE_TABLE` 가 모르는 이름을 조용히 걸러낸 뒤
영벡터 폴백이 그것을 삼켰다. 그 상태로 T2(tool 합성)를 켜면 spec §5-2-2 ②(ψ 근접으로
"기존 것의 변형" 판정)가 **항진명제**가 된다 -- 모든 합성 tool 이 서로 거리 0 이다.

이것은 `psi(int)` 경로가 2026-08-27 에 이미 고친 결함(`test_psi_unknown_macro.py`)의
**다른 가지**이고, 이 파일은 같은 처방이 리스트 경로에도 걸렸는지를 잰다.

⚠️ 이 파일이 재지 **않는** 것: ψ 값이 그 원시의 실제 효과와 맞는지. `a_reversible` ·
`a_consumes_spare` · `a_spatial` 세 축만 같은 항목의 다른 필드에서 기계로 유도되고
(아래 (6)), 나머지 여섯 축(a_cost 포함)은 `mechanism` 산문을 사람이 읽어 넣은 값이다.
"""
import os
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import features_agnostic  # noqa: E402
import primitive_registry  # noqa: E402

ZERO = 0.0


# ---- (1) 운용 원시 조합이 영벡터가 아니다 ---------------------------------------------------
def test_operational_combo_is_not_the_zero_vector():
    v = features_agnostic.psi(["release_pending_assignments", "deprioritize_agent"])
    assert set(v) == set(features_agnostic.PSI_AXES)
    assert any(abs(x) > 1e-12 for x in v.values()), v
    # 조합 규칙이 실제로 돌았는가: n_specs 는 len, soft 는 min(하나라도 하드면 하드).
    assert v["a_n_specs"] == 2.0
    assert v["a_soft"] == 0.0        # deprioritize 는 soft=1 이지만 release 가 하드다


def test_every_registered_operational_primitive_is_visible_to_psi():
    """19종 중 하나라도 영벡터면 그 원시는 ψ 공간에서 NOOP 과 구분되지 않는다."""
    zeros = []
    for name in primitive_registry.PRIMITIVE_NAMES:
        v = features_agnostic.psi([name])
        if all(abs(x) < 1e-12 for k, x in v.items() if k != "a_n_specs"):
            zeros.append(name)
    assert zeros == [], zeros


# ---- (2) 🔴 서로 다른 두 body 의 ψ 가 다르다 ------------------------------------------------
def test_two_different_bodies_have_different_psi():
    """§5-2-2 ②를 항진명제에서 구해내는 유일한 단언."""
    a = features_agnostic.psi(["release_pending_assignments"])
    b = features_agnostic.psi(["translate_whole_build"])
    assert a != b, (a, b)


def test_all_nineteen_operational_primitives_are_pairwise_distinguishable():
    """전부 서로 다른 점이어야 ψ 거리가 정보를 나른다. 같은 점 쌍은 여기서 이름이 뜬다."""
    seen = {}
    for name in primitive_registry.PRIMITIVE_NAMES:
        key = tuple(features_agnostic.psi([name])[a] for a in features_agnostic.PSI_AXES)
        seen.setdefault(key, []).append(name)
    collisions = {k: v for k, v in seen.items() if len(v) > 1}
    assert collisions == {}, collisions


# ---- (3) 모르는 이름은 KeyError -------------------------------------------------------------
def test_unknown_primitive_name_raises_instead_of_returning_zeros():
    with pytest.raises(KeyError):
        features_agnostic.psi(["nonsense_operation_xyz"])


def test_the_error_names_the_offender_and_both_namespaces():
    with pytest.raises(KeyError) as e:
        features_agnostic.psi(["nonsense_operation_xyz"])
    msg = str(e.value)
    assert "nonsense_operation_xyz" in msg
    assert "spec_dsl" in msg                      # DSL 이름 공간
    assert "primitive_registry.json" in msg       # 운용 이름 공간


def test_a_known_name_next_to_an_unknown_one_still_raises():
    """🔴 옛 결함의 정확한 모양: 하나만 알아도 걸러진 나머지가 조용히 사라졌다."""
    with pytest.raises(KeyError):
        features_agnostic.psi(["swap_battery", "nonsense_operation_xyz"])


def test_pure_predicates_raise_and_the_message_says_they_are_predicates():
    """술어는 아무것도 안 바꾸므로 ψ 가 없다 -- 오타와 구분해서 말해 준다."""
    for q in sorted(primitive_registry.PREDICATE_NAMES):
        with pytest.raises(KeyError):
            features_agnostic.psi([q])
    with pytest.raises(KeyError) as e:
        features_agnostic.psi(["goal_engulfed"])
    assert "술어" in str(e.value)


# ---- (4) 빈 리스트는 여전히 NOOP ------------------------------------------------------------
def test_empty_list_is_still_the_noop_vector():
    """🔴 회귀 방지: '모르는 이름' 분기를 고치면서 진짜 NOOP 을 같이 죽이면 안 된다.
    빈 리스트는 다른 사건이고 `if not names:` 가 이미 옳게 처리한다."""
    v = features_agnostic.psi([])
    assert v["a_intervenes"] == ZERO
    assert v["a_reversible"] == 1.0
    assert v["a_n_specs"] == ZERO
    assert v == features_agnostic.psi(0)          # 매크로 NOOP 과 같은 점


# ---- (5) DSL 경로 · 매크로 경로 회귀 핀 -----------------------------------------------------
# 🔴 리터럴 표다 -- 여기는 **의도적으로** 복붙이다. 회귀 핀의 요점이 "코드에서 다시 유도하면
# 함께 틀린다" 를 피하는 것이므로(psi_registry_check 가 항진명제가 된 사고가 그것이었다).
# surrogate 레인이 이 벡터를 그대로 먹는다:
#   dspy_service._load_surrogate -> surrogate_v2 -> surrogate_features.build_features -> psi
_DSL_PIN = {
    #                       cost  int  soft rest reloc spat nspec cons rev  scope
    "DeprioritizeAgent":   (0.3, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 1.0),
    "ForbidAgent":         (0.8, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 1.0),
    "ForbidWindow":        (0.5, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 2.0),
    "ForbidZone":          (1.0, 1.0, 0.0, 0.0, 1.0, 1.0, 1.0, 0.0, 0.0, 2.0),
    "ReformTeam":          (1.0, 1.0, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 3.0),
    "RelocateBuild":       (1.5, 1.0, 0.0, 0.0, 1.0, 1.0, 1.0, 0.0, 0.0, 3.0),
    "ReplaceAgent":        (1.0, 1.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 1.0),
    "SwapBattery":         (0.2, 1.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 1.0, 1.0),
}
_MACRO_PIN = {
    0: (0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0),
    1: (1.0, 1.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 1.0),
    2: (0.2, 1.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 1.0, 1.0),
}


def _vec(action):
    v = features_agnostic.psi(action)
    return tuple(v[a] for a in features_agnostic.PSI_AXES)


@pytest.mark.parametrize("name", sorted(_DSL_PIN))
def test_dsl_primitive_path_did_not_move_one_digit(name):
    assert _vec([name]) == _DSL_PIN[name]


def test_the_dsl_table_still_has_exactly_these_eight_names():
    """새 이름이 몰래 늘거나 줄면 위 핀이 조용히 부분검사가 된다."""
    assert set(features_agnostic._PRIMITIVE_TABLE) == set(_DSL_PIN)


@pytest.mark.parametrize("mid", sorted(_MACRO_PIN))
def test_macro_path_did_not_move_one_digit(mid):
    assert _vec(mid) == _MACRO_PIN[mid]


def test_macro_vocabulary_is_still_the_three_pinned_arms():
    assert set(features_agnostic.MACRO_SPECS) == set(_MACRO_PIN)


# ---- (6) 레지스트리 교차검사: 손으로 넣은 값의 오타를 잡는다 --------------------------------
def test_psi_axes_agree_with_the_other_fields_of_the_same_entry():
    """a_reversible == reversible · a_consumes_spare == (consumes 가 비지 않음)
    · a_spatial == (surface == "scene_tree"). 세 축만 기계로 유도된다."""
    assert primitive_registry.check_psi_consistency() == []


def test_the_cross_check_is_derived_independently_not_from_psi_itself():
    """🔴 위 검사가 항진명제가 아닌지 스스로 잰다 -- 어긋난 사본을 만들어 실제로 잡히는지 본다.
    (이 레포는 '두 표가 같은 리터럴이라 함께 틀려도 초록' 인 게이트에 이미 한 번 데였다.)"""
    import copy
    blob = copy.deepcopy(primitive_registry.REGISTRY)
    victim = blob["primitives"][0]
    victim["psi"]["a_reversible"] = 1.0 - victim["psi"]["a_reversible"]
    bad = primitive_registry.check_psi_consistency(blob)
    assert [b[0] for b in bad] == [victim["name"]]
    assert bad[0][1] == "a_reversible"


# ---- (7) 두 이름 공간이 서로소다 ------------------------------------------------------------
def test_the_two_primitive_namespaces_are_disjoint():
    """겹치면 psi 의 조회 순서(DSL -> 운용)가 '어느 표가 이기는가' 라는 조용한 결정이 된다."""
    dsl = set(features_agnostic._PRIMITIVE_TABLE)
    op = set(primitive_registry.PRIMITIVE_NAMES)
    assert dsl and op                              # 빈 집합에 대한 서로소는 공허하다
    assert dsl & op == set()


def test_operational_names_are_also_disjoint_from_the_scoring_vocabulary():
    """spec §7-2: 원시가 채점 어휘로 밀반입되면 없는 사건 클래스가 채점기에 들어간다."""
    import action_registry
    macro = set(action_registry.NAME2ID)
    assert macro
    assert macro & set(primitive_registry.PRIMITIVE_NAMES) == set()


# ---- (8) 축 이름 집합이 PSI_AXES 와 정확히 일치한다 -----------------------------------------
def test_registry_axis_names_match_psi_axes_exactly_modulo_a_n_specs():
    """🔴 축을 하나 빠뜨리면 그 축이 조용히 0 이 되므로 이 단언이 필요하다."""
    want = [a for a in features_agnostic.PSI_AXES if a != "a_n_specs"]
    assert primitive_registry.PSI_AXES == want     # 이름도 **순서도** 같아야 한다


def test_a_n_specs_is_not_carried_by_any_primitive():
    """파생축이라 원시 표에 실으면 진실원이 둘이 된다."""
    for name, row in primitive_registry.PSI_TABLE.items():
        assert "a_n_specs" not in row, name


# ---- 로더 규약: 조용한 폴백이 없다 ----------------------------------------------------------
def _load_with(path):
    """오염된 사본을 PRIMITIVE_REGISTRY 로 물려 **별도 프로세스**에서 import 시킨다.
    (같은 프로세스에서는 이미 import 된 모듈이 캐시돼 있어 재현되지 않는다.)"""
    return subprocess.run(
        [sys.executable, "-c",
         "import sys; sys.path.insert(0, %r); import primitive_registry" % HERE],
        env=dict(os.environ, PRIMITIVE_REGISTRY=path),
        capture_output=True, text=True)


def test_loader_dies_loudly_on_a_missing_file(tmp_path):
    r = _load_with(str(tmp_path / "nope.json"))
    assert r.returncode != 0
    assert "FileNotFoundError" in r.stderr


def test_loader_dies_loudly_when_a_primitive_has_no_psi_block(tmp_path):
    """검사 (8) 의 변이시험을 게이트 안에 박아 둔다 -- 축 하나가 조용히 0 이 되는 경로."""
    import copy
    import json
    blob = copy.deepcopy(primitive_registry.REGISTRY)
    del blob["primitives"][0]["psi"]
    p = tmp_path / "mutated.json"
    p.write_text(json.dumps(blob, ensure_ascii=False), encoding="utf-8")
    r = _load_with(str(p))
    assert r.returncode != 0
    assert "'psi' 블록이 없다" in r.stderr


def test_loader_dies_loudly_when_one_axis_is_dropped(tmp_path):
    import copy
    import json
    blob = copy.deepcopy(primitive_registry.REGISTRY)
    del blob["primitives"][0]["psi"]["a_scope"]
    p = tmp_path / "mutated.json"
    p.write_text(json.dumps(blob, ensure_ascii=False), encoding="utf-8")
    r = _load_with(str(p))
    assert r.returncode != 0
    assert "psi_axes 와 다르다" in r.stderr


def test_loader_dies_loudly_when_a_reversible_contradicts_reversible(tmp_path):
    import copy
    import json
    blob = copy.deepcopy(primitive_registry.REGISTRY)
    v = blob["primitives"][0]["psi"]
    v["a_reversible"] = 1.0 - v["a_reversible"]
    p = tmp_path / "mutated.json"
    p.write_text(json.dumps(blob, ensure_ascii=False), encoding="utf-8")
    r = _load_with(str(p))
    assert r.returncode != 0
    assert "a_reversible" in r.stderr
