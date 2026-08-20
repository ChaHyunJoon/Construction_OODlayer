"""도장 계약의 단위검사. **핵심은 음성 대조다** — 도장이 없거나 다른 파일을 읽으면
정말로 죽는가. 죽지 않으면 이 게이트는 영원히 실패할 수 없는 검사이고, 그런 검사는
2026-08-16 에 실제로 하나 만들어 봤다(그렙 대상 문자열이 stdout 에 한 번도 안 나왔다)."""
import json
import os
import subprocess
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "core"))
import action_registry  # noqa: E402


def test_vocab_constant_is_declared():
    # 리뷰 라운드 1 판정 G: 도장은 "오늘 참인 것"을 선언한다. 태스크 5(2026-08-19)가 3/5/6 을
    # 실제로 은퇴시켰으므로 오늘은 "v2-6arms" 다("v1-9arms" 는 그 이전 세대의 값).
    assert action_registry.VOCAB == "v2-6arms"


def test_vocab_declares_todays_true_arm_count():
    # dynamics_stamp() 는 hazard_enabled() 에서 **유도**되는데 vocab 문자열은 리터럴이라
    # 유도할 수 없다 — 그래서 유도 대신 "선언 <n>arms == 은퇴 제외 실제 registry 항목 수"를
    # 기계로 대조한다(리뷰 판정 G, 재리뷰로 정정). 태스크 5 이후 registry 항목 수는 여전히
    # 9(이름표는 안 지운다) 이지만 은퇴 제외 개수는 6 이다 — 그 둘이 갈리는 것 자체가 은퇴가
    # 실제로 집행됐다는 기계적 증거다.
    assert len(action_registry.MACROS) == 9
    assert action_registry.n_non_retired(action_registry.REGISTRY) == 6


def test_n_non_retired_ignores_only_entries_marked_retired():
    # 재리뷰가 잡은 핵심 결함: 태스크 5 의 은퇴는 엔트리를 지우지 않고 "retired" 표식만
    # 단다(이름·비용은 유지). len(MACROS) 는 그래서 은퇴 후에도 영원히 9 로 고정되고,
    # 어서션이 그걸 실제 개수로 쓰면 태스크 5 의 은퇴를 절대 못 본다. n_non_retired 는
    # "retired" 표식이 있는 엔트리만 빼고 센다.
    registry = {
        0: {"name": "A", "cost": 1.0},
        1: {"name": "B", "cost": 1.0, "retired": True},
        2: {"name": "C", "cost": 1.0, "retired": False},
    }
    assert action_registry.n_non_retired(registry) == 2


def test_vocab_arm_count_assertion_accepts_matching_count():
    action_registry.assert_vocab_arm_count("v1-9arms", 9)


def test_vocab_arm_count_assertion_dies_on_mismatch():
    # assert_vocab_arm_count 자체는 순수 산술 대조라 정의(무엇을 n_actual 로 넣는지)와
    # 무관하게 옳다 — 재리뷰가 잡은 결함은 호출부가 넘기는 n_actual 의 정의였다(아래
    # 태스크 5 시나리오 테스트가 그 정의를 서브프로세스로 검증한다).
    with pytest.raises(ValueError) as e:
        action_registry.assert_vocab_arm_count("v1-9arms", 7)
    assert "9" in str(e.value)
    assert "7" in str(e.value)


def test_vocab_arm_count_assertion_dies_on_malformed_stamp():
    with pytest.raises(ValueError):
        action_registry.assert_vocab_arm_count("not-a-vocab-stamp", 9)


# ---- 태스크 5 시나리오 (스크래치 registry, 서브프로세스) -----------------------------------
# action_registry 모듈은 최초 import 시 딱 한 번 평가되고(모듈 캐시), 그 순간 VOCAB 과
# assert_vocab_arm_count 호출이 이미 끝나 있다. 그래서 "다른 registry 를 넣으면 어떻게
# 되는가" 는 **같은 프로세스에서 재import 로는 검증할 수 없다** — 서브프로세스로 새
# 인터프리터를 띄워 ACTION_REGISTRY= 로 스크래치 파일을 주입한다. 커밋된
# action_registry.json 은 절대 건드리지 않는다.
def _synthetic_registry(vocab, retired_ids=()):
    macros = {}
    for i in range(9):
        entry = {"name": "Macro%d" % i, "cost": 1.0, "kinds": ["fault"], "doc": "synthetic"}
        if i in retired_ids:
            entry["retired"] = True
        macros[str(i)] = entry
    return {"vocab": vocab, "macros": macros}


def _write_scratch_registry(tmp_path, vocab, retired_ids=()):
    p = tmp_path / "scratch_action_registry.json"
    p.write_text(json.dumps(_synthetic_registry(vocab, retired_ids)), encoding="utf-8")
    return str(p)


def _load_in_subprocess(path):
    core_dir = os.path.dirname(os.path.abspath(action_registry.__file__))
    env = dict(os.environ)
    env["ACTION_REGISTRY"] = path
    env["PYTHONPATH"] = core_dir + os.pathsep + env.get("PYTHONPATH", "")
    return subprocess.run(
        [sys.executable, "-c", "import action_registry"],
        env=env, capture_output=True, text=True,
    )


def test_task5_scenario_today_nothing_retired_v1_9arms_loads(tmp_path):
    path = _write_scratch_registry(tmp_path, "v1-9arms", retired_ids=())
    r = _load_in_subprocess(path)
    assert r.returncode == 0, r.stderr


def test_task5_scenario_retired_but_stamp_not_bumped_dies(tmp_path):
    # 태스크 5 가 실제로 저지를 수 있는 실수: 3/5/6 을 은퇴시켰는데 도장 문자열을 그대로
    # "v1-9arms" 로 남겼다. 어서션이 이걸 못 잡으면(= 재리뷰 이전 상태) 도장은 장식이다.
    path = _write_scratch_registry(tmp_path, "v1-9arms", retired_ids=(3, 5, 6))
    r = _load_in_subprocess(path)
    assert r.returncode != 0
    assert "거짓말한다" in r.stderr


def test_task5_scenario_retired_and_stamp_correctly_bumped_loads(tmp_path):
    # 태스크 5 의 올바른 변경: 3/5/6 을 은퇴시키고 도장을 "v2-6arms" 로 갈아 끼웠다.
    # 어서션이 이걸 막으면(= 재리뷰 이전 상태, 선언 6 vs 실제 9 로 죽음) 태스크 5 가
    # 정상적으로 끝날 수 없다.
    path = _write_scratch_registry(tmp_path, "v2-6arms", retired_ids=(3, 5, 6))
    r = _load_in_subprocess(path)
    assert r.returncode == 0, r.stderr


def test_require_vocab_accepts_matching_stamp():
    action_registry.require_vocab({"vocab": "v2-6arms"}, "테스트")


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


# =============================================================================
# 태스크 5: 3·5·6 영구 은퇴 (spec §2) — 브리프 Step 1
# =============================================================================
def test_retired_macros_are_exactly_three_five_six():
    assert sorted(action_registry.RETIRED) == [3, 5, 6]


def test_active_macros_are_the_six_arms():
    assert action_registry.ACTIVE_MACROS == [0, 1, 2, 4, 7, 8]


def test_retired_macros_keep_their_names():
    """이름표는 지우지 않는다. 지우면 구세대 행을 읽을 때 KeyError 로 죽는데, 그건
    2026-08-02 에 실제로 난 사고다(gen_oracle_dataset.jl:118). 우리가 원하는 것은
    '읽을 때 도장 불일치로 죽는 것'이지 'KeyError 로 죽는 것'이 아니다."""
    assert action_registry.MACRO_NAME[3] == "ForbidZone"
    assert action_registry.MACRO_NAME[5] == "ForbidAgent+ReformTeam"


def test_combo_arms_flag_cannot_resurrect_retired():
    """DS_COMBO_ARMS=1 으로도 5·6 은 안 살아난다 — 은퇴가 실험 게이트를 이긴다."""
    os.environ["DS_COMBO_ARMS"] = "1"
    try:
        import importlib
        m = importlib.reload(action_registry)
        assert m.ACTIVE_MACROS == [0, 1, 2, 4, 7, 8]
    finally:
        os.environ.pop("DS_COMBO_ARMS", None)
        importlib.reload(action_registry)


# ---- 판정 K: retired 표식 형식 — 4경우 양 언어에서 (컨트롤러 부칙이 브리프의 Step 3 을 대체) ---
# 공유 truthy 규약으로 합의하지 않는다 — 갈린 것이 바로 truthiness 다. 그래서 여기서는
# "retired" 가 **boolean 이 아니면 무조건 에러**(강제변환·추측 금지)를 대조한다.
def _registry_with_retired(value, present=True):
    entry = {"name": "X", "cost": 1.0, "kinds": ["fault"], "doc": "d"}
    if present:
        entry["retired"] = value
    return {0: entry}


def test_retired_field_string_is_an_error_naming_the_macro():
    with pytest.raises(ValueError) as e:
        action_registry.n_non_retired(_registry_with_retired("2026-08-19 spec §2.1 ..."))
    assert "0" in str(e.value)


def test_retired_field_true_means_retired():
    assert action_registry.n_non_retired(_registry_with_retired(True)) == 0


def test_retired_field_false_means_not_retired():
    assert action_registry.n_non_retired(_registry_with_retired(False)) == 1


def test_retired_field_absent_means_not_retired():
    assert action_registry.n_non_retired(_registry_with_retired(None, present=False)) == 1


# =============================================================================
# 리뷰 F3 (판정: Important) — reference_policy 는 은퇴한 macro 를 채점 답으로 못 낸다
# =============================================================================
def test_reference_policy_never_answers_with_a_retired_macro():
    """core/reference_policy.reference_action 의 zone 가지는 `RelocateBuild` 가 안 뜨면
    `"ForbidZone"`(2026-08-19 영구 은퇴)을 답으로 냈다 — 은퇴한 매크로가 `decision_acc` 의
    채점 기준이 되는 구멍이었다(리뷰 라운드 2 F3). 이제 그 구간은 unscored(None)여야 한다."""
    sys.path.insert(0, os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "core"))
    import reference_policy as rp

    ev_relocatable = {"truth": "ZoneTruth", "valid": ["NOOP", "RelocateBuild"],
                       "zone_primitives": {"n_nav_blocked": 2, "root_covered": 0}}
    a_star, basis, note = rp.reference_action(ev_relocatable)
    assert a_star == "RelocateBuild"

    ev_not_relocatable = {"truth": "ZoneTruth", "valid": ["NOOP"],
                          "zone_primitives": {"n_nav_blocked": 2, "root_covered": 0}}
    a_star, basis, note = rp.reference_action(ev_not_relocatable)
    assert a_star != "ForbidZone"
    assert a_star is None, "RelocateBuild 불가 + ForbidZone 은퇴 -> 닫힌 어휘에 답이 없다(unscored)"
