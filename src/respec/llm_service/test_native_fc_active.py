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
import os
import sys
from typing import List

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

# 🔴 import 순서가 계약이다 — `import dspy` 보다 `dspy_service` 가 먼저여야 한다.
#    이유와 실측은 test_native_fc_wired.py 상단 주석 참조.
from dspy_service import SelectTool, build_adapter, native_fc_active  # noqa: E402
import dspy  # noqa: E402

# 네트워크·과금 0건: litellm 의 **로컬** 모델 맵 조회라 LM 객체를 만들기만 해도 조건 4 가 참이 된다.
_NO_CALL_KEY = "sk-DOES-NOT-MATTER-no-call-is-made"


def _real_lm():
    return dspy.LM("openai/gpt-4.1", api_key=_NO_CALL_KEY)


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
        assert native_fc_active(SelectTool) is None
