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
import objective  # noqa: E402


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


# =============================================================================
# 리뷰 라운드 3 Minor — is_active() 는 registry 밖 id 에서 두 언어가 같아야 한다
# =============================================================================
def test_is_active_false_for_out_of_registry_ids():
    """전에는 이 가드가 없어서 -1/9/10 같은 registry 밖 id 가 True 로 나왔다 — Julia 쪽은
    `haskey(REGISTRY, i)` 로 이미 막고 있었는데 여기가 안 막아서 "같은 규칙" 이라는 두 언어
    docstring 이 거짓이었다(리뷰 라운드 3). 지금은 둘 다 False."""
    for i in (-1, 9, 10, -3, 12):
        assert action_registry.is_active(i) is False, i
    # 살아 있는 팔은 여전히 살아 있어야 한다(과잉 수정 방지).
    assert action_registry.is_active(0) is True
    assert action_registry.is_active(1) is True


# =============================================================================
# 2026-08-20: sojourn 동역학 세대 도장 — fire_require_spare / mtbf_zone_s 가 동역학을
# 가르는데 objective.json 의 스칼라는 하나도 안 바뀌므로 objective_hash 가 그 단절을
# 볼 수 없다. generation 이 그 자리를 메운다(spec §7 규칙).
# =============================================================================
def test_generation_declares_the_sojourn_dynamics():
    """generation 은 '오늘 참인 것'을 선언한다. 4팔 축소 + hazard 두 손잡이 변경 뒤에도
    구세대 문자열이 남아 있으면, 서로 다른 동역학의 산출물이 같은 도장을 공유한다."""
    cfg = objective.load()
    assert cfg["generation"] == "2026-08-20-4arms-sojourn-spare-off-zone-on", cfg["generation"]


# =============================================================================
# 🔴 트립와이어 — generation 도장이 **아직 오지 않은** 동역학을 미리 선언하고 있다
# (2026-08-20 최종 리뷰 I1. 컨트롤러 판정: 문자열은 **그대로 둔다** — 계획서 태스크 2 가
#  그 값을 명시했고 generation 어휘는 사용자 계획의 소유다.)
#
# 도장 `"2026-08-20-4arms-sojourn-spare-off-zone-on"` 은 세 가지를 주장한다:
#   4arms      — 어휘가 4팔이다
#   spare-off  — hazard 의 `fire_require_spare` 가 꺼졌다
#   zone-on    — hazard 의 `mtbf_zone_s` 가 유한하다(zone 레인이 켜졌다)
# 뒤 둘은 **오늘 거짓이다.** 태스크 6 이 그 두 손잡이를 실제로 뒤집기 전까지는 도장이
# 미래를 선언하고 있는 상태다.
#
# 위험한 것은 틀린 라벨 자체가 아니라 **아무도 두 번째 범프를 안 하게 된다는 것**이다:
# 도장이 이미 post-C5 동역학의 이름을 달고 있으므로, 태스크 6 이 손잡이를 뒤집어도
# "도장은 이미 맞는데?" 로 보인다. 그러면 pre-C5 산출물과 post-C5 산출물이 **같은
# generation 을 공유한다** — 이 필드가 막으려던 바로 그 충돌이다.
#
# 그래서 이 시험은 "손잡이가 **아직** 도장이 말하는 상태가 아니다" 를 단언한다.
# **지금 초록인 이유는 그 변경이 아직 안 왔기 때문이다.**
# ⚠️ **태스크 6 이 이 두 손잡이를 뒤집는 순간 이 시험이 빨개진다. 그때 generation 을 다시
#    올릴 것** (그리고 이 시험을 도장이 참임을 확인하는 형태로 뒤집을 것).
# 이 브랜치가 `build_delta` · `prog.active` 에 쓴 것과 같은 트립와이어 패턴이다.
# =============================================================================
_HAZARD_JL = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "src", "smdp", "hazard.jl")


def _hazard_default(field):
    """`@kwdef HazardParams` 의 기본값을 소스에서 읽는다 — 여기에 복제본을 두지 않는다.
    (복제하면 hazard.jl 이 바뀌어도 이 시험이 옛 값을 보고 계속 초록일 수 있다.)"""
    import re
    src = open(_HAZARD_JL, encoding="utf-8").read()
    m = re.search(r"^\s*%s\s*::\s*\w+\s*=\s*([^\s#]+)" % re.escape(field), src, re.M)
    assert m is not None, "hazard.jl 에서 %s 의 기본값을 못 찾았다 (개명됐나?)" % field
    return m.group(1)


def test_generation_forward_declares_dynamics_that_have_not_landed():
    """도장은 spare-off / zone-on 을 선언하지만 hazard.jl 은 아직 그 반대다.
    태스크 6 이 손잡이를 뒤집으면 이 시험이 죽고, 그것이 generation 을 다시 올리라는 신호다."""
    cfg = objective.load()
    assert "spare-off" in cfg["generation"]
    assert "zone-on" in cfg["generation"]

    # 아직 안 왔다 = 도장이 미래를 말하고 있다.
    assert _hazard_default("fire_require_spare") == "true", (
        "fire_require_spare 가 뒤집혔다 — 도장이 선언한 spare-off 가 이제 실제다. "
        "generation 을 다시 올릴 것(pre-C5 / post-C5 산출물이 같은 도장을 공유하면 안 된다).")
    assert _hazard_default("mtbf_zone_s") == "Inf", (
        "mtbf_zone_s 가 유한해졌다 — 도장이 선언한 zone-on 이 이제 실제다. "
        "generation 을 다시 올릴 것.")
