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
    # 리뷰 라운드 1 판정 G: 도장은 "오늘 참인 것"을 선언한다.
    # 2026-08-24 의 3팔 축소가 어휘를 "v4-3arms" 로 올렸다(`v3-4arms` 는 그 이전 세대,
    # `v2-6arms`·`v1-9arms` 는 그 앞). 🔴 **리터럴인 것이 이 시험의 요점이다** — 세대가 갈리면
    # 사람이 여기 와서 갱신하도록 강제한다. 레지스트리에서 읽어 오면 항진명제가 된다.
    # (2026-08-21 갱신: 이 세 시험이 한 세대 낡은 채로 방치돼 있었다 — 보고서 §9.)
    assert action_registry.VOCAB == "v4-3arms"


def test_vocab_declares_todays_true_arm_count():
    # dynamics_stamp() 는 hazard_enabled() 에서 **유도**되는데 vocab 문자열은 리터럴이라
    # 유도할 수 없다 — 그래서 유도 대신 "선언 <n>arms == 실제 registry 항목 수"를 기계로
    # 대조한다(리뷰 판정 G).
    #
    # 🔴 **2026-08-21 정정 — v2 시대의 논법은 이 세대에 성립하지 않는다.**
    #    v2 는 은퇴를 "retired 표식"으로 집행해서 `len(MACROS)`(9)와 `n_non_retired`(6)가
    #    갈렸고, **그 갈림 자체가 은퇴의 기계적 증거**였다. v3 의 4팔 축소도, v4 의 3팔 축소도
    #    은퇴를 **재번호로** 집행했다 — 이름표를 안 남긴다. 그래서 오늘은 둘이 **같다**(3 == 3)
    #    이고 `RETIRED` 는 언제나 비어 있다. 옛 어서션을 그대로 두면 영원히 빨간불이다.
    #
    #    ⚠️ 그 대가는 CLAUDE.md 가 적어 뒀다: 재번호 뒤에는 **어휘 도장이 유일한 방어선**이다
    #    (v3-4arms 의 macro 2(RelocateBuild) 행이 새 어휘의 유효 id(SwapBattery)로 **조용히**
    #    읽힌다). 그래서 이 시험이 빨간 채로 방치되면 안 되는 것이었다.
    assert len(action_registry.MACROS) == 3
    assert action_registry.n_non_retired(action_registry.REGISTRY) == 3
    # 그리고 그 개수가 **도장 문자열이 선언한 값**과 같은가 — 리터럴 두 벌을 만들지 않고
    # 도장의 파서를 태워서 대조한다. 이것이 "선언 == 실제" 계약의 본체다.
    action_registry.assert_vocab_arm_count(
        action_registry.VOCAB, action_registry.n_non_retired(action_registry.REGISTRY))


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
    action_registry.require_vocab({"vocab": "v4-3arms"}, "테스트")


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
# 2026-08-24: 3팔 축소 (4팔 -> 3팔, RelocateBuild 삭제 · SwapBattery 3 -> 2 재번호)
# 은퇴 표식이 아니라 **엔트리 삭제** 정책 그대로다. zone 사건을 결정 레인에서 뺐으므로
# (spec 2026-08-24 §5.1) 그 개입 팔인 RelocateBuild 도 어휘에서 사라졌고, 남은 두 사건
# 종류(fault·battery)가 둘 다 채점 가능해졌다.
# 그 대가로 **도장(vocab)이 유일한 방어선**이다 — v3-4arms 세대의 macro 2 행은 이제
# KeyError 가 아니라 SwapBattery 로 조용히 읽힌다.
# =============================================================================
def test_no_retired_macros_remain():
    """은퇴 표식 대신 삭제 정책 — RETIRED 는 비어 있어야 한다."""
    assert action_registry.RETIRED == {}


def test_active_macros_are_the_three_arms():
    assert action_registry.ACTIVE_MACROS == [0, 1, 2]


def test_the_three_arms_are_named_as_expected():
    """사건 종류당 개입 팔 하나 + NOOP. 이름-비용 쌍은 구 어휘에서 그대로 옮겼다."""
    assert action_registry.MACRO_NAME == {0: "NOOP", 1: "Replace", 2: "SwapBattery"}
    assert action_registry.MACRO_COST == {0: 0.0, 1: 1.0, 2: 0.2}


def test_removed_arms_are_gone_entirely():
    """Deprioritize / ReformTeam / ForbidZone / RelocateBuild / 조합 팔은 레지스트리에 없다.
    `is_active` 는 registry 밖 id 에 대해 False 여야 한다(KeyError 가 아니라)."""
    assert set(action_registry.MACROS) == {0, 1, 2}
    for gone_name in ("Deprioritize", "ReformTeam", "ForbidZone", "RelocateBuild"):
        assert gone_name not in action_registry.NAME2ID
    for gone in (3, 4, 5, 6, 7, 8, -1, 99):
        assert action_registry.is_active(gone) is False


def test_reform_and_zone_are_not_event_kinds():
    """팀 교착은 외생 실패 사건이 아니라 Replace 의 2차 결과였다 — decision epoch 에서 뺐다.
    zone 은 2026-08-24 에 뺐다: 개입 팔(RelocateBuild)이 어휘에서 사라졌으므로 zone 결정에는
    NOOP 밖에 안 남고, 그런 사건 종류는 채점할 것이 없다(spec 2026-08-24 §5.1)."""
    assert set(action_registry.KIND_VALID) == {"fault", "battery"}
    assert action_registry.KIND_VALID["fault"] == [0, 1]
    assert action_registry.KIND_VALID["battery"] == [0, 1, 2]
    assert "zone" not in action_registry.KIND_VALID


def test_vocab_stamp_declares_three_arms():
    """도장이 실제 팔 수와 일치해야 한다 — 로드 시점 어서션이 이미 강제하지만 명시한다."""
    assert action_registry.VOCAB == "v4-3arms"
    assert action_registry.n_non_retired(action_registry.REGISTRY) == 3


def test_combo_arms_flag_does_not_resurrect_deleted():
    """DS_COMBO_ARMS=1 으로도 5·6 은 안 살아난다 — 이제는 엔트리 자체가 없다."""
    os.environ["DS_COMBO_ARMS"] = "1"
    try:
        import importlib
        m = importlib.reload(action_registry)
        assert m.ACTIVE_MACROS == [0, 1, 2]
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
    채점 기준이 되는 구멍이었다(리뷰 라운드 2 F3).

    🔴 2026-08-24 (spec §5.1, Task 4) 로 이 테스트가 **뒤집혔다.** 예전에는 첫 케이스가
    `a_star == "RelocateBuild"` 를 요구했다 — 즉 "zone 은 RelocateBuild 로 답한다" 는 규칙을
    테스트가 못박고 있었다. RelocateBuild 는 3팔 축소로 어휘에서 사라졌고 zone 자체가 LLM
    결정 레인에서 빠졌으므로, 두 케이스 다 unscored 여야 한다. 어느 쪽이든 **은퇴/삭제된
    매크로가 채점 기준이 되지 않는다** 는 이 테스트의 원래 계약은 그대로다."""
    sys.path.insert(0, os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "core"))
    import reference_policy as rp

    ev_relocatable = {"truth": "ZoneTruth", "valid": ["NOOP", "RelocateBuild"],
                       "zone_primitives": {"n_nav_blocked": 2, "root_covered": 0}}
    a_star, basis, note = rp.reference_action(ev_relocatable)
    assert a_star is None, "zone 은 LLM 결정 레인에서 빠졌다 -> 정답이 없다(unscored)"
    assert basis == "zone", "zone 이 함수 끝의 reform 폴백으로 새면 사유가 잘못 찍힌다"

    ev_not_relocatable = {"truth": "ZoneTruth", "valid": ["NOOP"],
                          "zone_primitives": {"n_nav_blocked": 2, "root_covered": 0}}
    a_star, basis, note = rp.reference_action(ev_not_relocatable)
    assert a_star != "ForbidZone"
    assert a_star is None, "RelocateBuild 불가 + ForbidZone 은퇴 -> 닫힌 어휘에 답이 없다(unscored)"
    assert basis == "zone"


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
    assert cfg["generation"] == "2026-08-21-reduced-state-sojourn-drainsigma0", cfg["generation"]


# =============================================================================
# ✅ 확인판(2026-08-21, 태스크 6 라운드 3) — 옛 트립와이어를 그 자신의 지시대로 뒤집었다.
#
# 옛 도장 `"2026-08-20-4arms-sojourn-spare-off-zone-on"` 은 spare-off/zone-on 을 **아직
# 오지 않은** 동역학으로 미리 선언했고, 그때 이 시험은 "손잡이가 아직 안 뒤집혔다"를
# 단언하는 트립와이어였다(그래서 이름이 forward_declares_..._not_landed) — 초록인 이유가
# "아직 안 왔기 때문"인, 손잡이가 뒤집히는 순간 죽도록 설계된 시험.
#
# 태스크 6 이 실제로 두 손잡이를 뒤집었고, generation 을
# `"2026-08-21-reduced-state-sojourn-drainsigma0"` 로 다시 올렸다(바로 위
# test_generation_declares_the_sojourn_dynamics 가 그 정확한 문자열을 등호로 고정한다).
# 새 문자열은 옛 명명 관례(`spare-off`/`zone-on` 서브스트링)를 안 쓴다 — 그건
# `"...-spare-off-zone-on"` 도장 전용 관례였고, 문자열 자체의 정확한 값은 이미 등호로
# 고정돼 있다. 이 시험이 지금부터 지키는 것은 문자열 안의 서브스트링이 아니라 **문자열이
# 실제로 주장하는 것**이다: hazard.jl 의 기본값이 정말로 뒤집힌 채로 남아 있는가.
#
# 되돌리면(hazard.jl 을 롤백하면서 generation 은 안 내리면) 이 시험이 죽는다 — 그것이
# 이 시험의 유일한 존재 이유다: pre-T6 산출물과 post-T6 산출물이 같은 도장을 공유하는
# 사고를 잡는다. `build_delta` · `prog.active` 와 같은 트립와이어 패턴의 확인판.
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


def test_generation_confirms_dynamics_have_landed():
    """도장이 주장하는 sojourn 동역학(D-3 spare-independent 발화, D-4 유한 zone MTBF)이
    hazard.jl 에 실제로 착륙했는지 확인한다. 예전 이름은
    test_generation_forward_declares_dynamics_that_have_not_landed 였다 — 그건 "아직 안
    왔다"를 단언하는 트립와이어였고, 태스크 6 이 손잡이를 뒤집은 뒤 자신의 주석이 지시한
    대로("그리고 이 시험을 도장이 참임을 확인하는 형태로 뒤집을 것") 이 확인판으로 바뀌었다."""
    assert _hazard_default("fire_require_spare") == "false", (
        "fire_require_spare 가 다시 true 로 돌아갔다 — generation 은 여전히 spare-independent "
        "발화(D-3)를 주장하는데 코드가 아니다. hazard.jl 을 되돌렸다면 generation 도 구세대로 "
        "내릴 것(그러지 않으면 서로 다른 동역학이 같은 도장을 공유한다).")
    assert _hazard_default("mtbf_zone_s") == "1800.0", (
        "mtbf_zone_s 가 1800.0 이 아니다 — generation 은 여전히 유한 zone MTBF(D-4)를 주장하는데 "
        "코드가 아니다. hazard.jl 을 되돌렸다면 generation 도 구세대로 내릴 것.")
