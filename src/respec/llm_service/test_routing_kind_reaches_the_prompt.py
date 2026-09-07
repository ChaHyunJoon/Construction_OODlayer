"""라우터의 **낯섦 판정**이 LLM 이 실제로 읽는 문자열까지 도달하는지 못박는다 (§A-1).

무엇이 부족했는가
-----------------
kind 색인 라우터(`tools/monitor/lane_select.jl:routing_kind`)는 처음 보는 `OODTruth` 타입을
`"unknown:<타입이름>"` 으로 알아보고 그 사건을 LLM 으로 보낸다. 그런데 T8~T12 시점까지 **그
판정이 프롬프트에 한 글자도 안 실렸다**: 페이로드의 `kind` 는 `ood_features` 의 `else` 분기라
`"fault"` 이고, 서비스의 `_valid_for` 는 fault 메뉴를 준다. 즉 모델은 자기가 처음 보는 사건을
받았다는 사실을 모른 채, 가장 가까운 알려진 스키마로의 **투영**을 사실로 읽고 답했다.

🔴 왜 `_valid_for`(메뉴)를 재지 않는가
--------------------------------------
§A-1 은 **메뉴를 안 바꾼다**. 그래서 메뉴를 재는 시험은 이 변경에 구조적으로 눈이 멀다 —
`routing_kind` 를 실어도 안 실어도 같은 값이 나오므로 통과할 수만 있고 실패할 수는 없다.
이 파일이 재는 것은 **`_llm_input` 의 산출물**, 즉 모델이 실제로 읽는 바이트다.
(그 불변성 자체는 마지막 절에서 별도로 못박는다 — 메뉴가 조용히 갈리는 것도 회귀다.)

재는 것 다섯
------------
  (1) `MacroRequest` 가 `routing_kind` 를 **보존한다**(pydantic 이 안 버린다).
  (2) `_llm_input` 이 그 타입 이름을 **포함한다** — nl 있는 경로.
  (3) 같은 것을 **`nl=None` 폴백 경로**(옛 호출자)에서도 잰다.
  (4) **음성 대조 셋**: `routing_kind="fault"` · `None` · 필드를 아예 안 준 요청 →
      세 경우 모두 산출물이 **바이트 단위로** 그 필드가 없을 때와 같다.
  (5) `_valid_for` 는 안 바뀐다 — `routing_kind` 유무가 메뉴를 안 가른다.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import dspy_service as svc  # noqa: E402

# `policy.jl:ood_features` 가 모르는 타입에 대해 실제로 내는 페이로드 모양 그대로:
# `kind` 는 `else` 분기라 `"unknown"` 이고, `soc`/`zone_overlap` 같은 kind 전용 열은 없다.
# 🔴 2026-09-07. 여기는 `"fault"` 였다. 그 리터럴을 지키던 이유가 "모르는 타입을 fault 로
#    접는 것은 surrogate 피처로는 옳다" 였는데 **surrogate 는 `kind` 를 안 읽는다**
#    (`_surro_row` 가 일부러 안 싣는다). 근거가 거짓이었고, 그 값은 폴백 경로에서
#    `"OOD kind=fault"` 를 찍어 바로 아래 `_unfamiliar_block` 과 모순됐다.
#    ⚠️ 픽스처가 세계와 갈리면 이 파일은 **허구를 재는 시험**이 된다 — 통과하면서.
# 🔴 `routing_kind` 는 **일부러 안 넣는다** — 각 시험이 자기가 재는 값만 얹는다.
BASE = dict(
    kind="unknown", severity=0.0, progress=0.31, n_active=6,
    spare_count=2, agent_pending=1, closed_at_fire=79, total_nodes=255,
    nl="A structural beam collapsed across the north staging lane.",
    descriptors=[0.41, 0.22, 0.0, 0.5, 0.31, 0.7])

UNKNOWN = "unknown:MeteorTruth"


def _req(**kw):
    d = dict(BASE)
    d.update(kw)
    return svc.MacroRequest(**d)


# ---------------------------------------------------------------------------------------------
# (1) 경계를 넘어 값이 살아남는가 — Step 2 의 선언이 살아 있다
# ---------------------------------------------------------------------------------------------
def test_routing_kind_survives_the_pydantic_boundary():
    """pydantic 은 **선언 안 된 키를 조용히 버린다.** 선언을 지우면 이 단언이 빨개진다.

    (선언이 없던 시절의 증상은 에러가 아니라 `AttributeError` 또는 값 소실이고, 원인이
    호출자 쪽에 있는 것처럼 보인다 — 이 레포가 `total_nodes`·`zones`·`lanes` 에서
    이미 세 번 밟은 함정이다.)
    """
    assert _req(routing_kind=UNKNOWN).routing_kind == UNKNOWN
    # 하위호환: 이 필드를 안 싣는 옛 호출자의 요청이 422 로 죽으면 안 된다.
    assert _req().routing_kind is None


# ---------------------------------------------------------------------------------------------
# (2)(3) 모델이 실제로 읽는 문자열에 그 사실이 있는가 — **두 반환 경로 모두**
# ---------------------------------------------------------------------------------------------
def test_the_unfamiliar_verdict_reaches_the_prompt_on_the_nl_path():
    """라이브 경로(nl 이 있다). 타입 이름 자체가 보여야 한다 — 이름이 곧 유일한 단서다."""
    text = svc._llm_input(_req(routing_kind=UNKNOWN))
    assert "MeteorTruth" in text
    assert "UNFAMILIAR EVENT" in text
    # 🔴 프롬프트가 나르는 것은 **사실**이다(Global Constraint 5). 지시절이 아니다.
    # 🔴 2026-08-30: 여기 있던 `assert "projection" in text and "candidate list" in text` 를
    #    **지웠다.** 그 두 단어가 실린 문장이 거짓이었기 때문이다(둘 다 실측으로 반증 —
    #    `_unfamiliar_block` 의 docstring §②③ 이 근거를 진다). 시험이 거짓 주장을 **못박고**
    #    있었으므로, 그 자리를 비워 두지 않고 지금 실제로 참인 둘로 갈아 끼운다:
    #    ① 학습된 범주에 못 놓았다는 사실 ② 이 행에는 종류별 측정값이 없다는 사실.
    assert "could not place this disruption" in text
    assert "placeholder" in text                    # 미지 타입이라 severity 가 상수다
    # 음성 대조 — 결정을 지시하는 어법이 새어 들어가면 측정되는 것이 추론이 아니라 준수가 된다.
    lowered = text.lower()
    for imperative in ("you should", "you must", "prefer ", "instead choose", "therefore choose"):
        assert imperative not in lowered


def test_the_unfamiliar_verdict_reaches_the_prompt_on_the_state_line_fallback():
    """옛 호출자(nl 없음)의 경로. 🔴 한쪽만 붙이면 여기서 그 사실이 조용히 사라진다."""
    text = svc._llm_input(_req(nl=None, routing_kind=UNKNOWN))
    assert "MeteorTruth" in text
    assert "UNFAMILIAR EVENT" in text
    # 이 경로를 정말 탔다는 확인(= 위 시험의 사본이 아니다): 폴백은 `_state_line` 으로 시작한다.
    assert text.startswith(svc._state_line(_req(nl=None, routing_kind=UNKNOWN)))


# ---------------------------------------------------------------------------------------------
# (4) 음성 대조 셋 — 이 시험이 **실패할 수 있음**을 보인다
# ---------------------------------------------------------------------------------------------
def test_known_kinds_and_absent_field_leave_the_prompt_byte_identical():
    """알려진 kind · `None` · 필드 없음 → 산출물이 **바이트 단위로** 기준선과 같다.

    이것이 없으면 위 두 시험은 "블록을 언제나 붙인다"로도 통과한다 — 그러면 모든 fault
    사건의 프롬프트가 "이건 처음 보는 사건이다"라고 거짓말하게 된다.
    """
    for nl in (BASE["nl"], None):
        baseline = svc._llm_input(_req(nl=nl))                       # 필드를 아예 안 준 요청
        assert svc._llm_input(_req(nl=nl, routing_kind=None)) == baseline
        assert svc._llm_input(_req(nl=nl, routing_kind="fault")) == baseline
        assert svc._llm_input(_req(nl=nl, routing_kind="battery")) == baseline
        assert "UNFAMILIAR EVENT" not in baseline
        # 그리고 같은 요청에 `unknown:` 을 얹으면 **실제로 달라진다**(항진명제 방지).
        assert svc._llm_input(_req(nl=nl, routing_kind=UNKNOWN)) != baseline


def test_the_block_is_the_only_thing_that_changes():
    """차이는 **덧붙은 블록 하나**여야 한다 — 기존 프롬프트를 재배치하지 않는다."""
    baseline = svc._llm_input(_req())
    with_block = svc._llm_input(_req(routing_kind=UNKNOWN))
    assert with_block.startswith(baseline)
    assert with_block[len(baseline):] == svc._unfamiliar_block(_req(routing_kind=UNKNOWN))


# ---------------------------------------------------------------------------------------------
# (4-b) 2026-08-30 — `unknown:` 을 다는 세 사건 전부가 블록을 받는다
# ---------------------------------------------------------------------------------------------
def test_every_unknown_prefixed_routing_kind_gets_the_block():
    """LLM 레인 표식이 `"unknown:"` 접두사 하나로 통일됐다(2026-08-30 사용자 결정).

    🔴 이 시험이 막는 회귀는 실재했던 것이다: 2026-08-30 이전 zone 의 `routing_kind` 는
    `"zone"` 이라 접두사가 없었고, `"zone" ∉ known_kinds` 라는 **간접 경로**로만 dspy 에
    갔다. 레인은 갈렸는데 이 블록은 **한 번도 안 붙었다** — 모델은 자기가 학습 범위 밖
    사건을 받았다는 것을 모른 채 답했다.
    """
    for rk in ("unknown:MeteorTruth", "unknown:battery_mild", "unknown:zone"):
        assert "UNFAMILIAR EVENT" in svc._llm_input(_req(routing_kind=rk))


def test_the_placeholder_sentence_only_fires_when_no_measurement_exists():
    """둘째 문장은 **종류별 측정값이 하나도 없는 행**에만 붙는다.

    🔴 2026-08-30. 옛 블록은 모든 `unknown:` 사건에 *"raw feature row 를 가장 가까운 알려진
    스키마로 접었다"* 고 적었는데, 그것은 `battery_mild`·`zone` 에서 **거짓**이다 — 그 둘은
    `ood_features` 의 자기 분기를 타서 `soc`/`zone_overlap` 이 실제 측정값으로 실린다.
    접히는(=측정값이 없는) 것은 미지 타입뿐이고, 그 행에서만 `severity` 가 상수 1.0 이다.

    ⚠️ 조건은 **`soc` 와 `zone_overlap` 이 둘 다 없는 것**이다. `kind` 문자열을 보지 않는다.
    2026-09-07 이전에는 그 이유가 "미지 타입의 `kind` 는 `"fault"` 로 접혀 오므로 그 값으로는
    두 사건을 못 가른다" 였다. 지금은 `"unknown"` 이라 **가를 수는 있지만 그래도 안 본다** —
    판정 기준은 "종류별 측정값이 실렸나" 라는 사실이지 라벨이 아니고, 라벨을 보기 시작하면
    새 kind 가 하나 늘 때마다 이 함수가 갈린다.
    """
    # 미지 타입: 종류별 측정값이 없다 → 붙는다.
    assert "placeholder" in svc._unfamiliar_block(_req(routing_kind=UNKNOWN))
    # mild battery: `soc` 가 실측이다 → 안 붙는다.
    mild = svc._unfamiliar_block(_req(kind="battery", soc=0.55,
                                      routing_kind="unknown:battery_mild"))
    assert "UNFAMILIAR EVENT" in mild
    assert "placeholder" not in mild
    # zone: `zone_overlap` 이 실측이다 → 안 붙는다.
    zone = svc._unfamiliar_block(_req(kind="zone", zone_overlap=0.4,
                                      routing_kind="unknown:zone"))
    assert "UNFAMILIAR EVENT" in zone
    assert "placeholder" not in zone
    # 🔴 0.0 은 "없음" 이 아니다 — falsy 로 접으면 겹침 0인 구역이 "못 쟀다" 로 집계된다.
    zero = svc._unfamiliar_block(_req(kind="zone", zone_overlap=0.0,
                                      routing_kind="unknown:zone"))
    assert "placeholder" not in zero
    assert "placeholder" not in svc._unfamiliar_block(
        _req(kind="battery", soc=0.0, routing_kind="unknown:battery_mild"))


def test_the_block_no_longer_claims_a_projection_or_a_derived_menu():
    """지운 두 주장이 되살아나지 않는지 본다 (2026-08-30).

    🔴 둘 다 실측으로 거짓이었다. ② 유사도 계산은 어디에도 없다 — `ood_features` 의
    `else` 가 리터럴을 쓰는 것뿐이고(2026-09-07 부터 `"unknown"`, 그 전에는 `"fault"`),
    숫자 서술자는
    `features_agnostic.descriptors_from_row` 가 `row['kind']` 를 **안 읽으므로** 애초에
    투영되지 않는다. ③ 메뉴는 줄리아의 `valid_macros(env, truth)` 가 세계에서 계산해
    `payload["valid"]` 로 싣고 `_valid_for` 가 그것을 우선한다.
    """
    for rk in ("unknown:MeteorTruth", "unknown:battery_mild", "unknown:zone"):
        block = svc._unfamiliar_block(_req(routing_kind=rk))
        for lie in ("closest", "folded", "projection", "candidate list"):
            assert lie not in block, (rk, lie)


# ---------------------------------------------------------------------------------------------
# (5) 메뉴는 안 바뀐다 — §A-1 이 못박은 범위를 시험이 지킨다
# ---------------------------------------------------------------------------------------------
def test_routing_kind_does_not_move_the_candidate_menu():
    """`_valid_for` 는 `kind`(그리고 호출자의 `valid`)만 읽는다. 그 계약을 여기서 고정한다.

    🔴 메뉴가 갈리면 surrogate 학습셋과 다른 행동공간으로 배포되는 조용한 발산이다 —
    §A-1 은 프롬프트만 고치고 메뉴는 **한 글자도 안 건드린다**.
    """
    baseline = svc._valid_for(_req())
    assert svc._valid_for(_req(routing_kind=UNKNOWN)) == baseline
    assert svc._valid_for(_req(routing_kind="fault")) == baseline
    assert svc._valid_for(_req(routing_kind=None)) == baseline
    # 항진명제 방지: 이 메뉴는 실제로 비어 있지 않고, 호출자의 `valid` 에는 여전히 반응한다.
    assert baseline
    assert svc._valid_for(_req(routing_kind=UNKNOWN, valid=[baseline[0]])) == [baseline[0]]
