"""트랜스포트 손잡이 — `DSPY_MODEL_TYPE` 이 dspy 의 엔드포인트 선택을 정한다 (2026-09-04).

**왜 이 파일이 있나.** `gpt-5.6-sol` 로 재시작한 유료 런이 결정 0건으로 죽었다:

    LMInvalidRequestError: [gpt-5.6-sol] litellm.BadRequestError: OpenAIException -
    Function tools with reasoning_effort are not supported for gpt-5.6-sol in
    /v1/chat/completions. To use function tools, use /v1/responses or set
    reasoning_effort to 'none'.

이 레인은 native FC 가 **존재 이유**라 `reasoning_effort='none'` 은 답이 아니다. 답은
/v1/responses 이고, dspy 3.3.0 에서 그 갈림길은 `dspy.LM(model_type=...)` 하나다
(`clients/lm.py::LM.forward` 가 이 값으로 `litellm_completion` 과
`litellm_responses_completion` 중 하나를 고른다).

🔴 이 파일이 못박는 것은 **두 방향 다**이다:
  · 손잡이가 실제로 트랜스포트를 고른다 (`_configure_dspy` 가 만든 LM 의 `model_type`).
  · **기본값이 안 변했다** — 오늘의 `gpt-4o` 는 `"chat"` · `temperature=0.2` 로 계속 간다.
    이쪽이 더 중요하다: 이 태스크의 유일한 회귀 위험은 chat 경로를 조용히 바꾸는 것이다.

🔴 모델 이름표(`if model.startswith("gpt-5")`)를 **안 쓴다**는 것도 여기서 잰다. 그런 표는
반드시 낡고 이 레포는 이미 그 부류에 물렸다 — 모델 이름을 무엇으로 바꿔도 트랜스포트는
환경변수만 따라야 한다.

🔴 **`importlib.reload` 를 쓰지 않는다** (실측으로 배운 자리다). 상수는 import 시각에 정해지니
해석 규칙을 재려면 모듈을 다시 읽고 싶어지는데, 그러면 `from dspy_service import X` 로 이름을
먼저 묶어 둔 다른 파일들이 낡은 객체를 붙들어 **조용히 무너진다** — 실측: reload 판을 같은
프로세스에 넣자 `test_scorable_gap_prefix.py` 4건 + `test_support_is_data.py` 1건이 빨개졌고
(`5 failed, 14 passed`), 이 파일만 빼면 같은 두 파일이 `8 passed` 였다. 그래서 규칙은
`_resolve_model_type` / `_resolve_temperature` 라는 **순수 함수**로 나와 있고 시험은 그것을
env 사전과 함께 직접 부른다. 모듈은 한 번도 다시 안 읽힌다.

라이브 대조(2026-09-04, 유료 호출). 둘 다 tool 정의를 실은 요청이다:
  · `gpt-4o` + chat + temperature=0.2  -> tool_call 반환 (회귀 대조, 초록)
  · `gpt-5.6-sol` + responses + temperature 없음 -> tool_call 반환 (초록)
  · `gpt-5.6-sol` + responses + temperature=0.2 -> BadRequest
    "Unsupported parameter: 'temperature' is not supported with this model."
그래서 `DSPY_TEMPERATURE=none` 이 **키째로 빼는** 손잡이다(1.0 으로 바꿔치기하지 않는다).

과금 0건: `dspy.LM(...)` 객체 생성은 provider 를 안 부른다.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

# 🔴 import 순서가 계약이다 — `import dspy` 보다 `dspy_service` 가 먼저여야 한다
#    (numpy/sklearn 초기화 순서. test_native_fc_wired.py 상단 주석 참조).
import dspy_service  # noqa: E402
from dspy_service import (_configure_dspy, _resolve_model_type,  # noqa: E402
                          _resolve_temperature)
import pytest  # noqa: E402


@pytest.fixture
def restored_dspy_globals():
    """`_configure_dspy()` 는 `dspy.configure` 로 **전역**을 갈아끼운다. 이 파일이 손잡이를
    바꿔 부른 뒤 그 전역을 남겨 두면 뒤따르는 파일이 다른 세계에서 돌게 된다 — 끝나고 진짜
    상수로 한 번 더 설치해 원상복구한다."""
    yield
    _configure_dspy()


# ---- 기본값은 안 변했다 (회귀 게이트) -------------------------------------------------------

def test_the_default_transport_is_chat():
    """🔴 이 태스크의 회귀 게이트. 손잡이를 **안 주면** 오늘의 `gpt-4o` 요청과 바이트 동일해야
    한다 — 트랜스포트도 온도도. 빈 env 사전을 주는 것이 "아무것도 설정 안 한 상태"다."""
    assert _resolve_model_type({}) == "chat"
    assert _resolve_temperature({}) == 0.2


def test_the_live_module_constants_came_from_those_rules():
    """상수가 규칙의 결과라는 것 자체를 못박는다 — 규칙만 고치고 상수를 딴 데서 만들면 빨갛다."""
    assert dspy_service.MODEL_TYPE == _resolve_model_type()
    assert dspy_service.TEMPERATURE == _resolve_temperature()


def test_the_default_reaches_the_lm(monkeypatch, restored_dspy_globals):
    monkeypatch.setattr(dspy_service, "MODEL_TYPE", _resolve_model_type({}))
    monkeypatch.setattr(dspy_service, "TEMPERATURE", _resolve_temperature({}))
    lm = _configure_dspy()
    assert lm.model_type == "chat"
    assert lm.kwargs["temperature"] == 0.2
    assert lm.kwargs["max_tokens"] == dspy_service.MAX_TOKENS


# ---- 손잡이가 트랜스포트를 고른다 ----------------------------------------------------------

def test_the_knob_selects_the_responses_transport():
    assert _resolve_model_type({"DSPY_MODEL_TYPE": "responses"}) == "responses"


def test_the_knob_reaches_the_lm(monkeypatch, restored_dspy_globals):
    """🔴 손잡이가 계산만 되고 `dspy.LM(...)` 까지 안 가면 여기서 빨개진다."""
    monkeypatch.setattr(dspy_service, "MODEL_TYPE",
                        _resolve_model_type({"DSPY_MODEL_TYPE": "responses"}))
    assert _configure_dspy().model_type == "responses"


def test_the_transport_does_not_depend_on_the_model_name():
    """🔴 이름표 금지. 모델 이름이 5.x 여도 손잡이를 안 주면 chat 이고, `gpt-4o` 여도 손잡이를
    주면 responses 다. 트랜스포트를 정하는 것은 **환경변수 하나**다."""
    assert _resolve_model_type({"DSPY_MODEL": "gpt-5.6-sol"}) == "chat"
    assert _resolve_model_type({"DSPY_MODEL": "gpt-4o",
                                "DSPY_MODEL_TYPE": "responses"}) == "responses"


# ---- temperature 손잡이 -------------------------------------------------------------------

@pytest.mark.parametrize("raw", ["none", "NONE", "", "  "])
def test_temperature_can_be_removed_from_the_request(raw):
    """`None` 은 "온도를 안 정했다"가 아니라 **키가 요청에 안 실린다**는 뜻이다. dspy 의
    프로바이더 경계(`openai_format.py::responses_config_kwargs`)가 `is not None` 으로 거른다.
    실측: 보낸 요청이 `{'model': ..., 'max_output_tokens': 2000}` — temperature 가 없다."""
    assert _resolve_temperature({"DSPY_TEMPERATURE": raw}) is None


def test_temperature_none_is_not_silently_swapped_for_a_number():
    """🔴 1.0(또는 0)으로 바꿔치기하는 구현은 여기서 빨개진다. 그건 다른 요청이고, 조용히
    그러면 산출물이 어느 온도에서 나왔는지 아무도 모른다."""
    got = _resolve_temperature({"DSPY_TEMPERATURE": "none"})
    assert got is None
    assert not isinstance(got, float)


def test_temperature_none_reaches_the_lm_as_none(monkeypatch, restored_dspy_globals):
    monkeypatch.setattr(dspy_service, "TEMPERATURE",
                        _resolve_temperature({"DSPY_TEMPERATURE": "none"}))
    assert _configure_dspy().kwargs["temperature"] is None


def test_an_explicit_temperature_is_honoured():
    assert _resolve_temperature({"DSPY_TEMPERATURE": "1.0"}) == 1.0


# ---- 레짐을 산출물이 말한다 ---------------------------------------------------------------

def test_health_reports_the_transport_regime(monkeypatch):
    """장수 프로세스는 자기가 어느 세계에서 도는지 스스로 신고해야 한다 — `cache` 와 같은
    이유다(이 레포는 나흘 묵은 uvicorn 이 `/health` 200 을 내는 사고를 이미 겪었다)."""
    monkeypatch.setattr(dspy_service, "MODEL_TYPE", "responses")
    monkeypatch.setattr(dspy_service, "TEMPERATURE", None)
    h = dspy_service.health()
    assert h["model_type"] == "responses"
    assert h["temperature"] is None


def test_health_reports_the_default_regime_by_default():
    h = dspy_service.health()
    assert h["model_type"] == dspy_service.MODEL_TYPE
    assert h["temperature"] == dspy_service.TEMPERATURE
