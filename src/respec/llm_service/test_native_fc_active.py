"""`native_fc_active()` 는 **발화 여부**를 잰다 — 배선 여부가 아니다 (spec §2-4).

`test_native_fc_wired.py` 는 우리가 코드로 통제하는 셋(플래그·입력 필드·출력 필드)을 못박는다.
이 파일은 그 셋 **더하기 조건 4**(`lm.supports_function_calling`)를 런타임에서 읽는 도우미를
못박는다. 조건 4 는 LM 이 정하므로 코드를 읽어서는 알 수 없고, 그래서 이 값이 `/macro` 응답에
실려야 라이브 런에서 "배선했다"와 "실제로 켜졌다"가 구분된다.

🔴 실패는 `False` 가 아니라 `None` 이다. "못 쟀다"(None)와 "재서 꺼져 있었다"(False)는 다른
사건이다 — Global Constraint "deferred 를 unknown/agree 로 뭉개지 않는다"(spec §9-2).

이 파일이 별도인 이유: 브리프가 `test_native_fc_wired.py` 의 기대값을 **정확히 `6 passed`** 로
못박았다. 거기에 시험을 더하면 그 수가 틀려진다.
"""
import contextlib
import os
import sys
from typing import List

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

# 🔴 import 순서가 계약이다 — `import dspy` 보다 `dspy_service` 가 먼저여야 한다.
#    이유와 실측은 test_native_fc_wired.py 상단 주석 참조.
import dspy_service  # noqa: E402  (this import is what fixes the numpy/dspy ordering)
from dspy_service import (SelectTool, build_adapter, native_fc_active,  # noqa: E402
                          _configure_dspy, _load_program)
import dspy  # noqa: E402

# 네트워크·과금 0건: litellm 의 **로컬** 모델 맵 조회라 LM 객체를 만들기만 해도 조건 4 가 참이 된다.
_NO_CALL_KEY = "sk-DOES-NOT-MATTER-no-call-is-made"


def _real_lm():
    return dspy.LM("openai/gpt-4.1", api_key=_NO_CALL_KEY)


@contextlib.contextmanager
def _dspy_settings_restored():
    """🔴 아래 두 시험은 `dspy.configure` 를 **전역으로** 부른다 — 그게 감시 대상인 프로덕션
    줄이라 `dspy.context` 로는 대신할 수 없다. 끝나고 되돌리지 않으면
    `test_vocabulary_gap_fires.py` 가 자기 docstring 에 적어 둔 전제("`decide()` 가 오늘 유료
    호출을 내지 않는 것은 아무도 `dspy.configure` 를 안 불렀다는 우연일 뿐")가 깨진다. 그 파일은
    알파벳순으로 이 파일보다 **뒤**에 돈다. `_state["program"]` 도 함께 되돌린다 —
    `native_fc_active()` 가 그걸 읽으므로 남겨 두면 앞선 시험들의 폴백 경로가 달라진다."""
    lm0 = dspy.settings.lm
    ad0 = dspy.settings.adapter
    prog0 = dspy_service._state["program"]
    try:
        yield
    finally:
        dspy.configure(lm=lm0, adapter=ad0)
        dspy_service._state["program"] = prog0


def test_active_is_true_when_all_four_conditions_hold():
    """네 조건이 전부 참인 배포 구성. `_startup()` 이 만드는 것과 같은 어댑터다."""
    with dspy.context(lm=_real_lm(), adapter=build_adapter()):
        assert native_fc_active() is True


def test_active_is_false_when_the_flag_is_off():
    """조건 1. 이게 dspy 기본값이고, tools 가 조용히 pop 되는(base.py:96-97) 바로 그 상태다."""
    with dspy.context(lm=_real_lm(), adapter=dspy.ChatAdapter()):
        assert native_fc_active() is False


def test_active_is_false_without_the_tool_input_field():
    """조건 2. 이 구성은 dspy 가 `ValueError` 를 던지는 구성이기도 하다(base.py:104)."""

    class NoToolInput(dspy.Signature):
        state: str = dspy.InputField()
        action: dspy.ToolCalls = dspy.OutputField()

    with dspy.context(lm=_real_lm(), adapter=build_adapter()):
        assert native_fc_active(NoToolInput) is False


def test_active_is_false_without_the_toolcalls_output_field():
    """조건 3. 입력 tools 만 있고 ToolCalls 출력이 없으면 native 분기는 안 탄다."""

    class NoToolCallsOutput(dspy.Signature):
        state: str = dspy.InputField()
        tools: List[dspy.Tool] = dspy.InputField()
        macro: str = dspy.OutputField()

    with dspy.context(lm=_real_lm(), adapter=build_adapter()):
        assert native_fc_active(NoToolCallsOutput) is False


def test_active_is_false_when_the_lm_does_not_support_function_calling():
    """조건 4. `DummyLM.supports_function_calling` 은 False 다 — 실측(dspy 3.3.0).

    🔴 그래서 DummyLM 왕복 시험은 native FC 를 증명하지 못한다. 배선이 전부 옳아도
    이 함수는 False 를 내야 한다.
    """
    lm = dspy.utils.DummyLM([{"macro": "NOOP"}])
    # ⚠️ 환경 전제다(DummyLM 의 속성). dspy_service.py 변이로는 붉어지지 않는다.
    assert lm.supports_function_calling is False
    with dspy.context(lm=lm, adapter=build_adapter()):
        assert native_fc_active() is False


def test_active_is_None_not_False_when_it_cannot_be_measured():
    """spec §9-2. 아무도 `dspy.configure` 를 안 부른 상태에서 조건 1·4 는 **읽을 수 없다**.

    dspy 의 폴백 기본값을 추론해 `False` 를 내면 그것은 측정이 아니라 코드 읽기다.
    """
    with dspy.context(lm=None, adapter=None):
        assert native_fc_active() is None


def test_active_is_None_when_reading_condition_4_itself_raises():
    """조건 4 를 **읽다가** 터진 것도 '재서 꺼져 있었다'가 아니라 '못 쟀다'다(spec §9-2).

    (이 자리에 원래 `native_fc_active(SelectTool)` 이 한 줄 더 있었으나, 기본 인자가 곧
    `SelectTool` 이던 시절에는 위 줄과 **글자 그대로 같은 식**이라 정보량이 0이었다 —
    컨트롤러 실측 B3. 다른 실패 방식을 재는 시험으로 바꾼다.)"""

    class ExplodingLM:
        @property
        def supports_function_calling(self):
            raise RuntimeError("litellm 모델 맵 조회가 터졌다")

    with dspy.context(lm=ExplodingLM(), adapter=build_adapter()):
        assert native_fc_active(SelectTool) is None


def test_configure_dspy_installs_the_native_fc_adapter():
    """🔴 B2. 프로덕션에서 native FC 를 켜는 것은 `_configure_dspy()` 안의 `adapter=` **한 줄**이다.

    이 파일의 다른 시험들은 `build_adapter()` 를 손수 부르거나 `dspy.context` 로 어댑터를 직접
    꽂아 보므로 **그 줄을 지워도 전부 초록**이었다 — 컨트롤러 실측 변이
    `V6 _startup() drops adapter=build_adapter() -> 12 passed *** SURVIVED ***`.
    그 줄이 빠지면 레인은 조용히 텍스트 직렬화 경로로 돌아간다(spec §10 risk 4).
    이 시험이 그 줄의 유일한 감시자다.

    과금 0건: `dspy.LM(...)` 은 객체를 만들 뿐이고 `supports_function_calling` 은 litellm 의
    **로컬** 모델 맵 조회다."""
    with _dspy_settings_restored():
        _configure_dspy()
        assert dspy.settings.adapter is not None
        assert dspy.settings.adapter.use_native_function_calling is True
        assert dspy.settings.lm.supports_function_calling is True


def test_the_program_that_actually_runs_is_what_gets_measured():
    """🔴 B1/V7. `native_fc_active()` 는 모듈 상수 `SelectTool` 이 아니라 **실제로 도는
    프로그램의 시그니처**를 읽어야 한다.

    컨트롤러 실측: 프로그램에서 tool 필드를 빼면 provider 로 나가는 tools 는 0개
    (`lm_kwargs["tools"] == []`)인데, `SelectTool` 을 읽는 판독기는 여전히 True 를 냈다.
    그건 "배선했다"와 "발화했다"를 가르려고 만든 필드가 바로 그 축에서 거짓말하는 것이다.
    변이 `V7 _load_program uses a tool-less signature` 가 이 시험 없이는 살아남았다
    (`-> 12 passed *** SURVIVED ***`)."""
    with _dspy_settings_restored():
        _configure_dspy()
        prog = _load_program()
        # 이름으로 본다 — 여기서는 이름이 곧 계약이다. Task 5/6 은
        # `prog(state=..., tools=[...], valid_actions=...)` 로 부를 것이고, 그 키워드가 이것이다.
        assert "tools" in prog.signature.input_fields
        assert native_fc_active() is True


def test_active_reads_the_live_program_not_the_module_constant():
    """🔴 B1 을 **단독으로** 붉히는 시험. 위 시험은 V7(tool 없는 프로그램)과 B1(모듈 상수를
    읽음)이 **함께** 있어야 붉어진다 — 프로그램이 옳으면 둘은 같은 답을 내기 때문이다.
    여기서는 둘을 일부러 갈라 놓고, 인자 없는 호출이 어느 쪽을 읽는지 직접 못박는다.

    실측(컨트롤러 B1): 이 상태에서 provider 로 나가는 tools 는 0개인데
    옛 구현은 `native_fc_active()` 로 True 를 냈다."""
    tool_less = dspy.Predict(SelectTool.delete("tools").delete("action"))
    with _dspy_settings_restored():
        _configure_dspy()
        dspy_service._state["program"] = tool_less
        # 도는 프로그램을 읽으면 False (조건 2·3 이 없다)
        assert native_fc_active() is False
        # 같은 순간 모듈 상수를 읽으면 True — 즉 둘은 정말로 갈리고, 어느 쪽을 읽는지가 중요하다
        assert native_fc_active(SelectTool) is True
