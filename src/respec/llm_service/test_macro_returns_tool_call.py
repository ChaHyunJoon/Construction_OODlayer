"""`/macro` 가 tool 호출을 응답에 싣는지, 그리고 tool↔macro 불일치를 **재기만** 하는지.

🔴 spec §4-1: 불일치를 지금 강제하지 않는다. 얼마나 나는지 모르는 상태에서 강제하면
어느 쪽이 옳은지도 모른 채 한쪽을 지우게 된다.

⚠️ **이 파일은 native FC 를 증명하지 않는다.** `DummyLM.supports_function_calling` 이 `False` 라
`adapters/base.py:110` 분기가 안 탄다. 여기서 재는 것은 **응답 모양**과 **무엇이 프로그램에
실제로 넘어갔는가**뿐이다. native FC 의 감시자는 `test_native_fc_wired.py` 이고 생략 불가다.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import dspy_service as svc  # noqa: E402  (numpy/sklearn-before-dspy 계약: dspy 보다 먼저)
import dspy  # noqa: E402
from dspy.utils.dummies import DummyLM  # noqa: E402
from dspy.utils.exceptions import AdapterParseError, LMError  # noqa: E402

AGENTS = [{"id": "ConstructionBots.BotID{ConstructionBots.DeliveryBot}(5)", "label": "Robot R5 / robot 5"}]
RID = AGENTS[0]["id"]


def _req(**kw):
    base = dict(kind="battery", soc=0.1, agents=AGENTS,
                valid=["NOOP", "Replace", "SwapBattery"],
                nl="Robot R5 has run its battery down and stopped.")
    base.update(kw)
    return svc.MacroRequest(**base)


class _FCDummy(DummyLM):
    """`supports_function_calling` 을 True 로 바꾼 가짜 LM.

    🔴 이게 없으면 native FC 분기(`adapters/base.py:110`)가 **한 번도 안 탄다** — 기본 DummyLM
    은 이 속성이 False 다(`clients/base_lm.py:267`). 그러면 `tools` 를 넘기든 말든 응답이
    같아서, 이 태스크가 고치는 바로 그 결함(`KeyError: 'tools'`)이 시험에서 도달 불가가 된다.
    실측(probe): 이 클래스로는 `native_fc_active(prog.signature) is True` 이고 tool 필드를 뺀
    시그니처에서는 False 다 — 즉 `native_fc` 단언들이 **혼자 붉어질 수 있다.**

    ⚠️ 그래도 이 파일은 native FC 를 증명하지 않는다: 진짜 provider 의 tool_calls 직렬화는
    여기 없다(이 LM 은 tool 을 부르지 않아 `action` 이 언제나 None 이다). 그 감시자는
    `test_native_fc_wired.py` 이고 생략 불가다.
    """

    @property
    def supports_function_calling(self):
        return True


def _install(*answers, fc=False):
    dspy.configure(lm=(_FCDummy if fc else DummyLM)(list(answers)), adapter=svc.build_adapter())
    svc._state["program"] = None          # 프로그램 재조립을 강제한다
    svc._load_program()


def _answer(**kw):
    base = {"reasoning": "r", "expressible": "True", "action": {"tool_calls": []},
            "macro": "NOOP", "ranking": "NOOP, Replace, SwapBattery", "margin": "0.0"}
    base.update(kw)
    return base


class _Spy:
    """실행 중인 프로그램을 감싸 **무엇이 넘어갔는지** 기록한다. `macro()` 가 `prog(...)` 에
    무엇을 주는지는 응답 모양으로는 안 보인다(DummyLM 은 `tools` 가 없어도 경고만 내고 답한다)."""

    def __init__(self, inner):
        self.inner, self.calls = inner, []
        self.signature = inner.signature

    def __call__(self, **kw):
        self.calls.append(kw)
        return self.inner(**kw)


def _spy():
    s = _Spy(svc._state["program"])
    svc._state["program"] = s
    return s


# ---------------------------------------------------------------------------------------------
# 계획서 본문의 세 검사
# ---------------------------------------------------------------------------------------------

def test_tool_call_is_reported():
    _install(_answer(expressible="True",
                     action={"tool_calls": [{"name": "deliver_battery", "args": {"agent": RID}}]},
                     macro="SwapBattery", ranking="SwapBattery, NOOP, Replace", margin="0.4"))
    out = svc.macro(_req())
    assert out["tool_called"] == "deliver_battery"
    assert out["tool_args"] == {"agent": RID}
    assert out["expressible"] is True


def test_agreement_is_measured_not_enforced():
    """macro 와 tool 이 어긋나도 macro 는 산다 — 기록만 한다."""
    _install(_answer(action={"tool_calls": [{"name": "no_intervention",
                                             "args": {"reason": "absorbed by slack"}}]},
                     macro="SwapBattery", ranking="SwapBattery, NOOP, Replace", margin="0.1"))
    out = svc.macro(_req())
    assert out["macro_tool_agree"] is False
    assert out["chosen"] == "SwapBattery", "불일치가 결정을 지우면 안 된다"


def test_no_tool_call_is_not_an_error():
    """tool 을 안 부른 것과 부를 tool 이 없던 것은 다르다 — 둘 다 기록된다."""
    _install(_answer(expressible="False", action={"tool_calls": []}, macro="NOOP"))
    out = svc.macro(_req())
    assert out["tool_called"] is None
    assert out["expressible"] is False
    assert out["macro_tool_agree"] is None, "부른 tool 이 없으면 일치 여부는 '못 쟀다'"
    assert out["tools_offered"] == 3, "부를 tool 은 **있었다** — 그래서 '안 불렀다'가 맞다"


# ---------------------------------------------------------------------------------------------
# 이 태스크의 본체: tools 가 실제로 프로그램까지 간다
# ---------------------------------------------------------------------------------------------

def test_the_tools_actually_reach_the_program():
    """🔴 이 태스크가 존재하는 이유. `tools` 를 안 넘기면 native FC 가 켜진 LM 에서 dspy 가
    `KeyError: 'tools'` 로 죽고(`dspy/adapters/base.py:111` — 실측), `/macro` 의 포괄 except 가
    그것을 `chosen=""` -> NOOP + `coerced=True` 로 바꾼다. 여기서는 **그 실패를 실제로
    도달 가능하게** 해 둔다(`_FCDummy`).

    기본 DummyLM 으로는 이 분기가 안 타서 `tools` 가 없어도 경고 한 줄로 정상 응답한다 —
    그 설정에서는 이 검사가 붉어지지 않는다. 그래서 fc=True 다."""
    _install(_answer(macro="SwapBattery", ranking="SwapBattery, NOOP, Replace"), fc=True)
    s = _spy()
    out = svc.macro(_req())
    assert len(s.calls) == 1
    assert [t.name for t in s.calls[0]["tools"]] == \
        ["no_intervention", "swap_body", "deliver_battery"]
    # 배선이 빠지면 위 한 줄이 KeyError 로 죽기 전에 아래 셋이 먼저 그 결과를 말한다.
    assert out["error"] is None, "native FC 가 켜진 LM 에 tools 를 안 넘겼다"
    assert out["chosen"] == "SwapBattery" and out["coerced"] is False
    assert out["native_fc"] is True


def test_the_agent_enum_carries_this_requests_robot_ids():
    """②접지: enum 에 실린 id 는 요청이 실어 보낸 것뿐이다."""
    _install(_answer())
    s = _spy()
    svc.macro(_req())
    by_name = {t.name: t for t in s.calls[0]["tools"]}
    assert by_name["deliver_battery"].args["agent"]["enum"] == [RID]


def test_the_resolved_menu_is_used_not_the_raw_request_field():
    """🔴 `req.valid` 는 **fault 사건에서 언제나 None 이다** — `policy.jl:553-554` 가
    `valid_macros` 가 비면 `payload["valid"]` 를 안 싣고, `valid_macros` 는 Battery/Zone 이
    아닌 truth 에 `String[]` 을 돌려준다(`policy.jl:362`). 그러므로 `build_tools` 에
    `req.valid` 를 그대로 주면 **모든 fault 사건에서 tool 레인이 조용히 꺼진다.**
    해소된 메뉴(`_valid_for`)를 쓰는지 본다."""
    _install(_answer(macro="Replace", ranking="Replace, NOOP"))
    s = _spy()
    out = svc.macro(_req(kind="fault", valid=None))
    assert out["valid"] == svc._valid_for(_req(kind="fault", valid=None))
    assert out["tools_offered"] > 0, "fault 사건에서 tool 레인이 꺼졌다"
    assert [t.name for t in s.calls[0]["tools"]] == ["no_intervention", "swap_body"]


# ---------------------------------------------------------------------------------------------
# 사용자 결정 ① — `expressible` 파싱 실패는 `None` 이다 (`True` 아님)
# ---------------------------------------------------------------------------------------------

def test_a_non_bool_expressible_is_none_not_a_false_true():
    """🔴 `bool()` 로 감싸면 `bool("False") is True` 라 **거짓 True** 가 조용히 기록된다.

    ⚠️ 이 검사는 프로그램을 직접 갈아 끼운다. 어댑터는 진짜 bool 로 파싱하거나 예외를 내므로
    (`parse_value(v, bool)`), 어댑터 경유로는 이 방어선에 **도달할 수 없다** — 즉 이건
    도달 가능한 실패에 대한 검사가 아니라 `macro()` 의 좌표 변환에 대한 검사다."""
    _install(_answer())
    real = svc._state["program"]

    class Bad:
        signature = real.signature

        def __call__(self, **kw):
            return dspy.Prediction(reasoning="r", expressible="False", macro="NOOP",
                                   ranking="NOOP", margin=0.0, action=None)

    svc._state["program"] = Bad()
    out = svc.macro(_req())
    assert out["expressible"] is None
    assert out["chosen"] == "NOOP", "expressible 을 못 읽은 것이 결정을 지우면 안 된다"


# ---------------------------------------------------------------------------------------------
# spec §4-1 — **필드 하나의 파싱 실패가 결정을 지우면 안 된다**
# ---------------------------------------------------------------------------------------------

def test_a_field_level_parse_failure_does_not_erase_the_decision():
    """🔴 이것이 이 태스크가 지키는 불변식이다.

    `expressible` 이 bool 로 안 읽히면 `AdapterParseError` 가 나고(ChatAdapter 가 JSONAdapter
    로 폴백하며 두 번 시도한다), 예전 포괄 `except` 는 그것을 `chosen=""` -> NOOP + coerced
    으로 바꿨다 = **tool 레인의 필드 하나가 결정을 통째로 지웠다.**

    새 계약: 파싱 실패는 tool 레인만 끄고(`tool_lane_error`), 결정은 tool 필드를 뺀
    시그니처로 다시 물어 살린다. `error` 는 **None 으로 남는다** — `policy.jl:1036-1037`
    의 `policy_entry` 가 `error !== nothing` 이면 그 레인을 `available=false` 로 버리므로,
    여기에 문자열을 넣으면 줄리아 경계에서 결정이 도로 지워진다(실측: 그 두 줄)."""
    _install(_answer(expressible="maybe", macro="SwapBattery",
                     ranking="SwapBattery, NOOP, Replace", margin="0.7"),
             _answer(expressible="maybe", macro="SwapBattery",
                     ranking="SwapBattery, NOOP, Replace", margin="0.7"),
             _answer(macro="SwapBattery", ranking="SwapBattery, NOOP, Replace", margin="0.7"),
             fc=True)
    out = svc.macro(_req())
    assert out["chosen"] == "SwapBattery", "필드 파싱 실패가 결정을 지웠다"
    assert out["coerced"] is False
    assert out["error"] is None, "결정이 살았으면 error 는 None 이다(줄리아가 레인을 버린다)"
    assert out["tool_lane_error"] is not None and "AdapterParseError" in out["tool_lane_error"]
    assert out["expressible"] is None, "못 쟀다 — True/False 로 뭉개지 않는다"
    assert out["tool_called"] is None
    assert out["macro_tool_agree"] is None
    assert out["native_fc"] is False, "구제 호출은 tool 필드가 없다 = native FC 는 안 탔다"
    # 🔴 F2: 이 행의 C8 두 키는 "메뉴가 있었는데 거절했다" 와 **같다.** 구제 호출은
    #    `tools=None` 이라 부를 수 없었는데도 개수는 첫 시도의 것이 남는다. 아래
    #    `test_a_parse_failure_row_is_not_a_declined_menu` 가 그 충돌을 정면으로 못박는다.
    assert out["tools_offered"] > 0, "첫 시도의 개수가 남아 있어야 한다(C8 ③의 전제)"


def test_a_parse_failure_row_is_not_a_declined_menu():
    """🔴 F2 — 이 레인의 헤드라인 숫자(거절률)가 파싱 실패율만큼 부풀려지는 자리.

    §4-1 구제 호출은 시그니처에서 tool 필드를 빼고 `tools=None` 으로 다시 묻는다 = 그 요청은
    tool 을 **부를 수 없었다.** 그런데 `tools_offered` 는 첫 시도의 개수를 그대로 나르므로,
    그 행은 C8 의 두 키(`tools_offered > 0` · `tool_called is None`)만 보면 "메뉴가 있었는데
    모델이 거절했다" 와 **글자 그대로 같다.** 이 레포는 같은 모양 — 한 레인의 사건이 다른
    레인의 버킷에 실려 fault 발화율이 100% vs 23% 로 읽힌 것 — 을 이미 한 번 밟았다.

    설계 결정: **새 필드를 더하지 않는다.** 가르는 키(`tool_lane_error`)가 이미 두 엔드포인트의
    응답에 실려 있다. 대신 그 규칙이 주석에만 살지 않도록 여기서 **두 행을 나란히 만들어**
    (a) C8 두 키로는 구별 불가이고 (b) `tool_lane_error` 가 실제로 가른다는 것을 못박는다.

    ⚠️ `native_fc` 로 가르지 말 것 — 여기서는 갈리지만(False vs True), 그건 `_FCDummy` 가
    native FC 를 켜 주기 때문이다. native FC 를 안 켜는 프로바이더에서는 거절 행도 False 라
    이 축은 두 사건을 못 가른다. 가르는 키는 `tool_lane_error` 하나다."""
    # ③ 파싱 실패 -> 구제. tool 을 부를 수 **없었다**.
    _install(_answer(expressible="maybe", macro="SwapBattery",
                     ranking="SwapBattery, NOOP, Replace", margin="0.7"),
             _answer(expressible="maybe", macro="SwapBattery",
                     ranking="SwapBattery, NOOP, Replace", margin="0.7"),
             _answer(macro="SwapBattery", ranking="SwapBattery, NOOP, Replace", margin="0.7"),
             fc=True)
    salvaged = svc.macro(_req())

    # ② 진짜 거절. 메뉴가 있었고, 부를 수 있었고, 안 불렀다.
    _install(_answer(expressible="False", action={"tool_calls": []}, macro="NOOP"), fc=True)
    declined = svc.macro(_req())

    # (a) C8 의 두 키만으로는 구별 불가 — 이 단언이 초록인 동안 "tools_offered > 0 이고
    #     tool_called is None 이면 거절" 은 **거짓 규칙**이다.
    assert (salvaged["tools_offered"] > 0, salvaged["tool_called"]) == \
           (declined["tools_offered"] > 0, declined["tool_called"]), \
        "두 행이 C8 두 키에서 갈렸다면 이 검사의 전제가 바뀐 것이다 — 불변식 주석을 고칠 것"

    # (b) 가르는 키는 `tool_lane_error` 다.
    assert salvaged["tool_lane_error"] is not None, "부를 수 없었던 행이 거절과 구별 불가가 됐다"
    assert declined["tool_lane_error"] is None, "거절 행에 레인 오류가 붙었다 — 규칙이 반대로 샌다"

    # (c) 소비자 규칙 자체를 돌려 본다: 거절로 세어야 하는 것은 한 행뿐이다.
    def is_declined(row):
        return (row["tools_offered"] > 0 and row["tool_called"] is None
                and row["tool_lane_error"] is None)

    assert [is_declined(r) for r in (salvaged, declined)] == [False, True]


def test_a_provider_failure_is_not_retried_and_is_not_salvaged():
    """음성 대조. 구제는 **파싱 실패에만** 건다.

    실제 프로바이더 장애는 전부 `LMError` 다(`dspy/clients/lm.py:185` 가 감싼다). 거기서
    다시 물으면 장애 하나마다 과금 leg 을 배로 태우면서 아무것도 못 건진다. 그러니 옛 동작
    (`error` 기록 + NOOP 강등)이 그대로 남아야 하고, 호출은 **한 번**이어야 한다."""
    _install(_answer())
    real = svc._state["program"]

    class Boom:
        signature = real.signature

        def __init__(self):
            self.n = 0

        def __call__(self, **kw):
            self.n += 1
            raise LMError("provider is down")

    b = Boom()
    svc._state["program"] = b
    out = svc.macro(_req())
    assert b.n == 1, "장애를 다시 물었다 — 과금 leg 이 배가 된다"
    assert out["error"] is not None and "LMError" in out["error"]
    assert out["tool_lane_error"] is None, "레인 실패가 아니라 결정 실패다"
    assert out["chosen"] == "NOOP" and out["coerced"] is True


def test_a_parse_failure_that_survives_the_retry_still_reports_the_decision_error():
    """구제도 실패하면 옛 동작으로 되돌아간다 — 조용히 성공한 척하지 않는다.

    🔴 실패를 **진짜 두 번째 파싱 실패**로 만든다 (fix round 1). 처음 판은 DummyLM 의 답을
    바닥내서(`"No more responses"`) 같은 분기에 도달했는데, 그건 docstring 이 말하는 기전이
    아니었다 — "구제 호출이 파싱에 또 실패했다" 가 아니라 "가짜 LM 이 할 말이 없었다" 였다.
    지금은 첫 요청이 `expressible` 로, 구제 요청이 `margin` 으로 깨진다. 둘 다 실제 어댑터가
    내는 `AdapterParseError` 다.

    답이 넷인 이유: 두 번의 요청이 각각 ChatAdapter -> JSONAdapter 로 두 leg 씩 쓴다
    (실측: 이 시나리오의 총 leg = 4).
    """
    _install(_answer(expressible="maybe"), _answer(expressible="maybe"),
             _answer(margin="not-a-number"), _answer(margin="not-a-number"))
    out = svc.macro(_req())
    assert out["chosen"] == "NOOP" and out["coerced"] is True
    assert out["error"] is not None and "AdapterParseError" in out["error"]
    assert out["tool_lane_error"] is not None and "AdapterParseError" in out["tool_lane_error"]
    assert out["expressible"] is None and out["tool_called"] is None


# ---------------------------------------------------------------------------------------------
# C8 — `tools` 가 비면 레인을 끄되 조용히 넘어가지 않는다
# ---------------------------------------------------------------------------------------------

def test_an_empty_tool_menu_asks_without_tools_instead_of_sending_an_empty_list():
    """🔴 `build_tools` 는 `[]` 를 낼 수 있고 그건 정상이다(Task 5). 그럴 때 tool 입출력
    필드를 뺀 시그니처로 tool **없이** 묻는다.

    ⚠️ **여기 적혀 있던 이유는 거짓이었다**(2026-08-29 fix round 1 정정). 옛 문구는
    *"빈 목록을 넘기면 provider 가 400 을 낸다"* 였는데, 실측하면 빈 목록은 LM 경계에
    **도달조차 안 한다**: `_call_preprocess` 뒤 `lm_kwargs == {'tools': []}` 이지만
    `dspy/clients/openai_format.py:83` 의 `if request.tools:` 가 falsy 로 떨어뜨린다.
    native FC 판에서 두 프롬프트는 바이트 단위로 같다(2994자).

    실제로 막는 것 둘:
      ① `_ask` 가 빈 목록의 kwarg 를 안 넘기므로, 시그니처에 `tools` 필드가 남아 있으면
         native FC 분기가 `inputs["tools"]` 에서 `KeyError: 'tools'`
         (`dspy/adapters/base.py:111`) 로 죽는다 — 이 태스크가 고치는 그 실패 그대로다.
      ② native FC 가 안 켜진 판에서는 빈 tool 목록이 **프롬프트 본문에** 렌더된다
         (실측 2994 -> 3960자, +966자).
    """
    _install(_answer(macro="Replace", ranking="Replace"), fc=True)
    s = _spy()
    out = svc.macro(_req(valid=["Replace"], agents=[]))
    assert "tools" not in s.calls[0], "빈 목록을 그대로 넘겼다"
    # 🔴 위 한 줄만으로는 **혼자 붉어질 수 없다** — 배선 전 `macro()` 도 `tools` 를 안 넘겼다
    #    (RED 실측: 이 검사만 19개 중 유일하게 PASSED). 그래서 "안 넘겼다"가 아니라
    #    **"tool 필드를 뺀 시그니처로 물었다"** 를 잰다. `_call_preprocess` 가 native FC 분기에서
    #    `tools` 키를 채우는 조건이 시그니처의 그 두 필드이므로(base.py:100-110), 이것이 곧
    #    "provider 로 `tools: []` 가 안 나간다" 이다(실측: 빈 목록을 넘기면 lm_kwargs == {'tools': []}).
    sig = s.calls[0]["signature"]
    assert svc._FC_IN not in sig.input_fields and svc._FC_OUT not in sig.output_fields
    assert svc._EXPR in sig.output_fields, \
        "메뉴가 비었을 때야말로 '어떤 tool 로도 안 된다' 를 물어야 한다"
    assert out["chosen"] == "Replace", "레인을 껐다고 결정까지 지우면 안 된다"


def test_no_tool_to_call_is_a_different_event_from_not_calling_one():
    """C8 의 구분. `tool_called is None` 하나로는 두 사건이 같은 값으로 무너진다.
    `tools_offered` 가 그 둘을 가른다: 0 = 부를 tool 이 **없었다**, >0 = 있었는데 **안 불렀다**."""
    _install(_answer(macro="Replace", ranking="Replace"), fc=True)
    none_offered = svc.macro(_req(valid=["Replace"], agents=[]))
    _install(_answer(expressible="False", macro="NOOP"), fc=True)
    offered_not_called = svc.macro(_req())
    assert none_offered["tool_called"] is None and offered_not_called["tool_called"] is None
    assert none_offered["tools_offered"] == 0
    assert offered_not_called["tools_offered"] == 3
    # 🔴 `native_fc` 는 이 요청이 **실제로 쓴** 시그니처로 재어져야 한다. 두 값이 갈리는 것이
    #    그 증거다 — 모듈 상수나 `prog.signature` 로 재면 둘 다 True 가 되어 붉어진다.
    assert none_offered["native_fc"] is False, "tool 필드가 없으면 native FC 는 못 탄다"
    assert offered_not_called["native_fc"] is True


# ---------------------------------------------------------------------------------------------
# 여럿 온 tool 호출을 조용히 버리지 않는다
# ---------------------------------------------------------------------------------------------

def test_extra_tool_calls_are_counted_not_silently_dropped():
    """이 레인의 결정은 사건당 행동 하나다. 여럿 오면 첫 번째만 쓰되 그 사실이 남는다."""
    _install(_answer(action={"tool_calls": [{"name": "deliver_battery", "args": {"agent": RID}},
                                            {"name": "swap_body", "args": {"agent": RID}}]},
                     macro="SwapBattery", ranking="SwapBattery, NOOP, Replace"))
    out = svc.macro(_req())
    assert out["tool_called"] == "deliver_battery"
    assert out["tool_calls_n"] == 2


# ---------------------------------------------------------------------------------------------
# 일치 판정은 **모델이 말한 macro** 로 잰다
# ---------------------------------------------------------------------------------------------

def test_agreement_is_measured_on_what_the_model_said_not_on_the_coerced_macro():
    """🔴 계획서 본문은 `MACRO_TO_TOOL.get(chosen)` 을 강등(coercion) **뒤에** 뒀다. 그러면
    어휘 밖 macro 를 낸 사건에서 일치 여부가 모델의 출력이 아니라 `NOOP` 에 대해 재어진다 —
    "채점 어휘와 행동 어휘가 갈리는 빈도" 를 재겠다는 이 신호의 정의와 다른 것을 재게 된다.
    강등 사실은 이미 `coerced` 가 나른다. 여기서는 모델이 말한 것을 그대로 잰다."""
    _install(_answer(action={"tool_calls": [{"name": "swap_body", "args": {"agent": RID}}]},
                     macro="Replace", ranking="Replace, NOOP"))
    out = svc.macro(_req(valid=["NOOP", "SwapBattery"]))   # Replace 는 이 메뉴에 없다
    assert out["coerced"] is True and out["chosen"] == "NOOP"
    assert out["macro_tool_agree"] is True, \
        "모델은 Replace 라 말하고 swap_body 를 불렀다 = 두 어휘는 **일치했다**"


def test_a_macro_outside_the_table_is_unmeasurable_not_a_disagreement():
    """🔴 fix round 1 (M2). spec §9-2 붕괴를 이름 그대로 밟고 있었다.

    모델의 macro 가 `MACRO_TO_TOOL` 밖이면(빈 문자열 · 환각한 이름) 등식의 오른쪽이 `None` 이고
    `None` 은 어떤 tool 이름과도 같지 않다 — 그래서 그 부분모집단에서 `macro_tool_agree` 가
    **언제나 `False`** 였다. 즉 "못 쟀다" 가 "재서 어긋났다" 로 기록된다. 실측(실제 어댑터 경유):

        macro=""         + deliver_battery -> macro_tool_agree = False
        macro="Teleport" + deliver_battery -> macro_tool_agree = False

    이 레인에서 사람이 제일 먼저 읽을 숫자가 불일치율인데, 그것이 이만큼 부풀려진다.

    ⚠️ `coerced` 로는 이 구분을 **복원할 수 없다.** legal 하지만 이 메뉴에 없는 macro 도
    `coerced=True` 인데 그쪽은 진짜로 잴 수 있다(같은 파일의
    `test_agreement_is_measured_on_what_the_model_said_not_on_the_coerced_macro` 가 바로 그 예다).
    두 사건이 `coerced=True` 로 합쳐지므로 정보가 응답에서 사라진다.
    """
    for macro in ("", "Teleport"):
        _install(_answer(action={"tool_calls": [{"name": "deliver_battery",
                                                 "args": {"agent": RID}}]},
                         macro=macro, ranking="NOOP"))
        out = svc.macro(_req())
        assert out["tool_called"] == "deliver_battery", macro
        assert out["macro_tool_agree"] is None, \
            "macro=%r 는 표 밖이다 — '못 쟀다'(None)이지 '어긋났다'(False)가 아니다" % macro


def test_a_macro_inside_the_table_still_yields_a_real_verdict():
    """음성 대조. 위 수정이 `macro_tool_agree` 를 통째로 None 으로 만들지 않았는지 본다 —
    표 안의 macro 는 True/False 를 그대로 낸다."""
    for macro, tool, want in [("SwapBattery", "deliver_battery", True),
                              ("SwapBattery", "swap_body", False),
                              ("NOOP", "no_intervention", True)]:
        _install(_answer(action={"tool_calls": [{"name": tool, "args": {"agent": RID}}]},
                         macro=macro, ranking=macro))
        assert svc.macro(_req())["macro_tool_agree"] is want, (macro, tool)


# ---------------------------------------------------------------------------------------------
# 사용자 결정 ② — 다섯 키(+ C8·중복호출 구분)가 `/decide` 에도 실린다
# ---------------------------------------------------------------------------------------------

_LANE_KEYS = ("tool_called", "tool_args", "expressible", "macro_tool_agree", "native_fc",
              "tools_offered", "tool_calls_n", "tool_lane_error")


def test_macro_reports_every_lane_key():
    _install(_answer())
    out = svc.macro(_req())
    assert set(_LANE_KEYS) <= set(out)


def test_decide_carries_the_lane_keys_into_the_dspy_block():
    """🔴 `/macro` 는 이 레포에 **호출자가 없다**(실측: `grep -rn '/macro' --include='*.jl'
    --include='*.py' src tools wm4spacecraft_manufacturing test` = 정의 1건
    (`@app.post("/macro")`) · 주석/독스트링 언급 3건 · **호출 0건**). 라이브 레인은 `/decide`
    로만 들어온다(`tools/monitor/policy.jl:559`). 여기 안 실으면 접지가 실제로 도는 곳에서
    영원히 안 보인다.

    🔴 **키의 존재만 재면 안 된다** (fix round 1, M1). 값은 여덟 번의 손으로 적은 전사를
    거치므로, 존재만 재면 그중 여섯이 프로덕션에서 틀린 값을 나르면서 게이트가 초록이다 —
    실측: `decide()` 가 `native_fc=True` / `tools_offered=0` / `expressible=True` 를 못박는
    변이 셋이 이 파일의 검사 전부를 통과했다. **같은 요청의 `/macro` 응답과 값이 같은지** 잰다.

    ⚠️ 시나리오가 넷인 이유: 하나만 쓰면 하드코딩 변이가 우연히 그 값과 같아 살아남는다. 아래
    마지막 블록이 **여덟 키 각각이 시나리오 사이에서 최소 두 값을 가지는지** 확인한다 — 그게
    "어떤 상수 하드코딩도 붉어진다" 의 통제다. 이 통제가 없으면 위 루프는 공허할 수 있다.
    """
    A = _answer(expressible="True", macro="SwapBattery", ranking="SwapBattery, NOOP, Replace")
    B = _answer(expressible="False", macro="Replace", ranking="Replace")
    C = _answer(expressible="True", macro="SwapBattery", ranking="SwapBattery, NOOP, Replace",
                action={"tool_calls": [{"name": "deliver_battery", "args": {"agent": RID}},
                                       {"name": "swap_body", "args": {"agent": RID}}]})
    Dbad = _answer(expressible="maybe", macro="NOOP", ranking="NOOP")
    Dok = _answer(macro="NOOP", ranking="NOOP")
    scenarios = [
        # (라벨, 한 번의 macro() 가 소비하는 답들, fc, 요청 kwargs)
        ("A native FC on, tools present", (A,), True, {}),
        ("B native FC on, empty menu (C8)", (B,), True, dict(valid=["Replace"], agents=[])),
        # 🔴 fc=False 라야 tool 호출이 **텍스트 채널로** 돌아온다 — `_FCDummy` 는 native
        #    tool_call 을 낼 줄 모른다(이 파일 상단 참조). tool_* 네 키는 여기서만 움직인다.
        ("C text channel, two tool calls", (C,), False, {}),
        ("D parse failure -> salvage", (Dbad, Dbad, Dok), False, {}),
    ]
    seen = {k: set() for k in _LANE_KEYS}
    for label, answers, fc, kw in scenarios:
        _install(*(answers + answers), fc=fc)   # macro() 가 한 벌, decide() 가 한 벌 쓴다
        m = svc.macro(_req(**kw))
        d = svc.decide(_req(**kw))["dspy"]
        assert set(_LANE_KEYS) <= set(d), label
        for k in _LANE_KEYS:
            assert d[k] == m[k], "%s: decide()[%r]=%r != macro()[%r]=%r" % (label, k, d[k], k, m[k])
            seen[k].add(repr(m[k]))
    # 🔴 통제: 여덟 키 전부가 시나리오 사이에서 값이 갈려야 위 루프가 하드코딩을 붙잡는다.
    flat = {k: sorted(v) for k, v in seen.items() if len(v) < 2}
    assert not flat, "이 키들은 시나리오 사이에서 상수라 하드코딩 변이를 못 잡는다: %r" % flat


# ---------------------------------------------------------------------------------------------
# 구조 계약
# ---------------------------------------------------------------------------------------------

def test_the_stripped_field_names_are_real_fields_of_the_signature():
    """🔴 `Signature.delete` 는 없는 이름에 **에러를 안 낸다**(`signature.py:446`,
    `fields.pop(name, None)`). 그래서 필드를 개명하면 위 두 축약(C8 · §4-1 구제)이 조용히
    아무것도 안 지우고, C8 은 `tools=[]` 를 provider 로 흘리고 구제는 같은 파싱 실패를
    다시 밟는다 — 둘 다 에러가 안 난다. 이름이 실재하는지 여기서 못박는다."""
    assert svc._FC_IN in svc.SelectTool.input_fields
    assert svc._FC_OUT in svc.SelectTool.output_fields
    assert svc._EXPR in svc.SelectTool.output_fields


def test_tool_registry_is_imported_below_import_dspy():
    """C9. numpy/sklearn-before-dspy 계약(`dspy_service.py:44` < `:46`)을 이 import 가
    깨지 않게 소스 순서를 못박는다.

    ⚠️ **이 검사가 재는 것은 줄 순서뿐이다.** 오늘 실제 TypeError 를 막는 것은
    `tool_registry.py` 자신의 순서 가드(H2)이고 그건 `test_tool_registry.py::
    test_tool_registry_import_does_not_poison_a_later_sklearn_import` 가 지킨다. 그 가드를
    지우고 이 import 를 44행 위로 올리는 **두 변이가 동시에** 일어나야 프로세스가 죽는다.
    이 검사는 그 둘 중 하나를 기계로 붙잡는다 — 증거의 폭을 넓혀 읽지 말 것."""
    src = open(svc.__file__, encoding="utf-8").read().splitlines()

    def line_of(pred):
        return next(i for i, ln in enumerate(src) if pred(ln))

    i_np = line_of(lambda ln: ln.startswith("import numpy"))
    i_dspy = line_of(lambda ln: ln.strip() == "import dspy")
    i_tr = line_of(lambda ln: ln.startswith("from tool_registry import"))
    assert i_np < i_dspy < i_tr, (i_np, i_dspy, i_tr)


def test_the_agreement_table_is_not_a_second_copy():
    """`MACRO_TO_TOOL` 은 `tool_registry` 의 것 하나뿐이다 — 두 벌 두면 조용히 갈린다."""
    from tool_registry import MACRO_TO_TOOL
    assert svc.MACRO_TO_TOOL is MACRO_TO_TOOL
