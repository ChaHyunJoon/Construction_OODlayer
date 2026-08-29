"""native FC 의 네 조건 중 우리가 통제하는 셋을 못박는다 (spec §2-4).

🔴 플래그가 False 면 dspy 가 `tools`/`tool_choice`/`parallel_tool_calls` 를 **조용히 pop 한다**
(adapters/base.py:96-97). 예외도 경고도 없고 출력은 여전히 tool 처럼 생겼다.
출력 모양으로는 절대 못 잡으므로, 어댑터와 시그니처를 직접 단언한다.

줄번호는 `grep -n` 실측(dspy 3.3.0, .venv/lib/python3.12/site-packages/dspy/adapters/base.py):
pop 루프 `:96-97` · `ValueError` `:104` · `lm.supports_function_calling` 분기 `:110` ·
`_get_tool_call_input_field_name` `:609` · `_get_tool_call_output_field_name` `:619`.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

# 🔴 import 순서가 계약이다 — `import dspy` 보다 `dspy_service` 가 **먼저**여야 한다.
#    dspy 3.3.0 은 import 시점에 sys.modules["numpy"] 를 lazy 프록시로 갈아 끼우고, 그 뒤에
#    dspy_service 가 sklearn -> joblib -> numpy 를 건드리면 numpy 가 절반만 초기화된 자기
#    자신으로 재진입하며 `numpy/_core/_methods.py:17: TypeError: data type 'bool' not
#    understood` 로 죽는다(dspy_service.py:44 의 주석이 그 계약의 진실원).
#    실측: 반대 순서로 두고 이 파일을 단독으로 돌리면 **수집 단계에서 ERROR** 가 난다
#    (`.venv/bin/python -m pytest src/respec/llm_service/test_native_fc_wired.py`).
#    전체 게이트에서는 앞 알파벳 파일이 이미 dspy_service 를 올려 놔서 그 결함이 가려진다.
from dspy_service import SelectTool, build_adapter  # noqa: E402  (must precede `import dspy`)
import dspy  # noqa: E402


def test_adapter_has_native_fc_on():
    ad = build_adapter()
    assert ad.use_native_function_calling is True


def test_signature_has_the_tool_input_field():
    """조건 2. 이게 없으면 dspy 가 ValueError 를 던진다 (base.py:104)."""
    ad = build_adapter()
    assert ad._get_tool_call_input_field_name(SelectTool) == "tools"


def test_signature_has_the_toolcalls_output_field():
    """조건 3."""
    ad = build_adapter()
    assert ad._get_tool_call_output_field_name(SelectTool) == "action"


def test_macro_stays_a_separate_output_field():
    """spec §4-1 불변식: tool 실패가 결정을 지우면 안 된다."""
    assert "macro" in SelectTool.output_fields
    assert SelectTool.output_fields["macro"].annotation is str


def test_expressible_is_declared():
    """T2 를 발화시키는 신호. 없으면 '어휘가 무능했다'를 셀 자리가 없다."""
    assert "expressible" in SelectTool.output_fields
    assert SelectTool.output_fields["expressible"].annotation is bool


def test_native_branch_actually_fires_with_a_real_lm_object():
    """조건 4. base.py:110 분기를 실제로 태운다 — LM 객체만 만들고 호출은 0건.

    🔴 DummyLM 으로는 이 분기가 안 탄다(supports_function_calling=False). 그래서
    Task 6 의 왕복 시험은 응답 모양만 증명하고 배선은 증명하지 못한다.
    """
    ad = build_adapter()
    lm = dspy.LM("openai/gpt-4.1", api_key="sk-DOES-NOT-MATTER-no-call-is-made")
    # ⚠️ 이 한 줄은 우리 코드에 대한 검사가 아니라 **환경 전제**다(litellm 의 모델 cost map).
    #    dspy_service.py 를 어떻게 변이시켜도 붉어지지 않는다 — 독립 검사로 읽지 말 것.
    # 🔴 그리고 이 읽기는 **로컬 조회가 아니다**(2026-08-28 정정). 위 docstring 의 "호출은 0건"
    #    은 **provider(과금) 호출** 이야기다. 이 속성을 읽으면 litellm 이 원격 cost map
    #    (raw.githubusercontent.com) fetch 를 시도하고 실패 시 로컬 백업으로 폴백한다 —
    #    실측 connect 시도 8건. 과금은 여전히 0건이지만 네트워크 0건은 아니다.
    assert lm.supports_function_calling is True
    kw = {}
    sig = ad._call_preprocess(
        lm, kw, SelectTool,
        {"state": "x", "tools": [dspy.Tool(lambda agent: "ok", name="deliver_battery")],
         "valid_actions": "NOOP"})
    # ⚠️ 아래 셋은 **하나의 분기**(base.py:110-121)의 세 관측이다. 그 분기가 타면 tools 채움과
    #    두 필드 삭제가 함께 일어나므로, dspy_service.py 의 어떤 변이도 셋을 따로 붉히지
    #    못한다(변이 M1·M2·M3 이 전부 셋을 함께 붉힌다). 독립 검사 셋으로 읽지 말 것.
    assert kw["tools"][0]["function"]["name"] == "deliver_battery"
    # 🔴 이름의 부재가 아니라 **삭제가 일어났는가**를 잰다. 옛 단언
    #    (`"action" not in sig.output_fields`)은 필드를 `act` 로 개명하기만 해도 초록이었다 —
    #    삭제를 잰 게 아니라 이름의 부재를 쟀기 때문이다(컨트롤러 실측 B3). 아래는 삭제 자체를
    #    잰다: 분기가 안 타면 제거 집합이 비어(`set()`) 붉어진다.
    assert set(SelectTool.output_fields) - set(sig.output_fields) == \
        {ad._get_tool_call_output_field_name(SelectTool)}
    assert set(SelectTool.input_fields) - set(sig.input_fields) == \
        {ad._get_tool_call_input_field_name(SelectTool)}
