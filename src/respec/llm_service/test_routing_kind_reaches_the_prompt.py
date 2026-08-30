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
# `kind` 는 `else` 분기라 "fault" 이고, `soc`/`zone_overlap` 같은 kind 전용 열은 없다.
# 🔴 `routing_kind` 는 **일부러 안 넣는다** — 각 시험이 자기가 재는 값만 얹는다.
BASE = dict(
    kind="fault", severity=0.0, progress=0.31, n_active=6,
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
    # 🔴 프롬프트가 나르는 것은 **사실 셋**이다(Global Constraint 5). 지시절이 아니다.
    assert "projection" in text and "candidate list" in text
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
