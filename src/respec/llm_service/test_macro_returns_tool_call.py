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
    """🔴 2026-08-29 (T4): 결정 성분이 **tool 인자**에서 온다. 예전 판은 `expressible` 을
    텍스트 `OutputField` 에서 읽었는데 그 필드는 T3 이 지웠다."""
    _install(_call("deliver_battery"), fc=False)
    out = svc.macro(_req())
    assert out["tool_called"] == "deliver_battery"
    assert out["tool_args"] == {"agent": RID}, "접지 인자만 나간다(F9)"
    assert out["expressible"] is True


def test_agreement_is_measured_not_enforced():
    """macro 인자와 tool 이 어긋나도 **기록만** 한다 — 다만 결정은 tool 이 낸다.

    🔴 2026-08-29 (T4): 이 시험의 마지막 단언이 **뒤집혔다.** 예전에는
    `chosen == "SwapBattery"`(모델이 말한 macro) 였다 — 그것이 정확히 F5 였다: 채점은
    `SwapBattery` 인데 집행은 `no_intervention` 이라 두 어휘가 갈렸다(실측 3/3). 단일
    채널에서 `chosen` 은 tool 이름에서 나오므로 갈릴 수가 없다."""
    _install(_call("no_intervention", macro="SwapBattery", agent=None,
                   reason="absorbed by slack"), fc=False)
    out = svc.macro(_req())
    assert out["macro_tool_agree"] is False, "어긋남은 여전히 재어진다"
    assert out["chosen"] == "NOOP", "집행이 결정이다 — 두 어휘가 갈릴 수 없다(F5)"


def test_no_tool_call_is_not_an_error():
    """tool 을 안 부른 것과 부를 tool 이 없던 것은 다르다 — 둘 다 기록된다.

    🔴 2026-08-29 (T4): `expressible` 단언이 `False` -> `None` 으로 바뀌었다. 그 값은 이제
    tool 인자로만 오는데 **호출이 없으면 인자도 없다** — 즉 "못 쟀다" 가 맞다. 예전에는
    텍스트 필드로 따로 왔으므로 호출 없이도 값이 있었다. F15 사건에서 합성 레인이 발화하지
    않게 된 것이 이 변화의 실질이고, 그건 의도된 것이다(발화 조건은 모델이 **말한** False
    이지 우리가 못 받은 것이 아니다)."""
    _install({"action": {"tool_calls": []}}, fc=False)
    out = svc.macro(_req())
    assert out["tool_called"] is None
    assert out["decision_source"] == "no_call"
    assert out["expressible"] is None
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
    _install(_answer(), fc=True)
    s = _spy()
    out = svc.macro(_req())
    assert len(s.calls) == 1, "🔴 단일 채널에는 2차 호출이 없다 — 구제 경로를 전부 지웠다"
    assert [t.name for t in s.calls[0]["tools"]] == \
        ["no_intervention", "swap_body", "deliver_battery"]
    # 배선이 빠지면 위 한 줄이 KeyError 로 죽기 전에 아래 둘이 먼저 그 결과를 말한다.
    assert out["error"] is None, "native FC 가 켜진 LM 에 tools 를 안 넘겼다"
    assert out["native_fc"] is True
    # 🔴 `chosen` 단언은 여기서 **뺐다.** `_FCDummy` 는 native tool_call 을 직렬화할 줄
    #    모르므로(파일 상단 docstring) fc=True 판에서는 호출이 아예 안 도착한다 — 단일
    #    채널에서 그것은 `no_call` 이고 `chosen` 은 정의상 빈 문자열이다. 이 시험이 재는
    #    것은 **tools 가 프로그램까지 가는가** 하나이고, 조립은 `_call` 을 쓰는 시험들이 잰다.
    assert out["decision_source"] == "no_call"


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

    🔴 2026-08-29 (T4): 이 방어선이 **도달 가능해졌다.** 예전에는 `expressible` 이 시그니처의
    bool 필드라 어댑터가 진짜 bool 로 파싱하거나 예외를 냈고(`parse_value(v, bool)`), 그래서
    프로그램을 직접 갈아 끼워야만 이 줄에 닿았다. 지금 그 값은 **tool 인자**로 오는데 tool
    인자는 프로바이더가 보낸 JSON 그대로라 문자열 `"False"` 가 그냥 도착한다. 즉 이건
    좌표 변환 검사가 아니라 **실제 실패 모드**에 대한 검사다.
    (T2 의 `check_tool_args` 가 같은 축에 `expressible_not_a_bool` 을 낸다 — 두 층이 겹치는
    것은 의도된 것이다: 이쪽은 값을 안 믿고, 저쪽은 사유를 남긴다.)"""
    _install(_call(expressible="False"), fc=False)
    out = svc.macro(_req())
    assert out["expressible"] is None, "bool() 로 감싸면 여기가 True 가 된다"
    assert out["tool_arg_error"] is not None and "expressible" in out["tool_arg_error"]
    assert out["chosen"] == "SwapBattery", "expressible 을 못 읽은 것이 결정을 지우면 안 된다"


# ---------------------------------------------------------------------------------------------
# spec §4-1 — **필드 하나의 파싱 실패가 결정을 지우면 안 된다**
# ---------------------------------------------------------------------------------------------

# 🔴 삭제 (2026-08-29 T4): `test_a_field_level_parse_failure_does_not_erase_the_decision` — spec §4-1 의 재질의 구제를 재던 것. 단일 채널에서 tool 필드를 뺀 시그니처는 출력 필드가 0개라 살릴 것이 없다 — 구제 코드가 사라졌고, 그 사건은 이제 `decision_source='no_call'` + `tool_lane_error` 로 이름이 붙는다(`test_a_parse_failure_is_a_contract_violation_not_a_provider_outage`)


# 🔴 삭제 (2026-08-29 T4): `test_a_parse_failure_row_is_not_a_declined_menu` — 구제 행과 거절 행이 C8 두 키로 구별 불가임을 못박던 것. 그 재구성 자체가 사라졌다 — `decision_source` 가 사건 이름을 응답에 직접 싣는다


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
    assert out["tool_lane_error"] is None, "파싱 실패가 아니라 프로바이더 장애다"
    # 🔴 2026-08-29 (T4): 예전에는 `chosen == "NOOP"` · `coerced is True` 였다. 결정을 못 낸
    #    사건을 **NOOP 을 골랐다** 로 기록하던 것이고, 그러면 그 행이 진짜 NOOP 결정과 섞인다.
    #    지금은 빈 문자열 + `decision_source` 로 이유가 남는다(`policy_entry` 가 그 행을
    #    `available=false` 로 떨어뜨려 canonical 폴백이 서는 것은 그대로다).
    assert out["chosen"] == "" and out["coerced"] is False
    assert out["decision_source"] == "no_call"


# 🔴 삭제 (2026-08-29 T4): `test_a_parse_failure_that_survives_the_retry_still_reports_the_decision_error` — 재질의가 또 실패하는 경로를 재던 것. 재질의가 없다


# ---------------------------------------------------------------------------------------------
# C8 — `tools` 가 비면 레인을 끄되 조용히 넘어가지 않는다
# ---------------------------------------------------------------------------------------------

# 🔴 삭제 (2026-08-29 T4): `test_an_empty_tool_menu_asks_without_tools_instead_of_sending_an_empty_list` — C8 축약(tool 필드를 뺀 시그니처로 텍스트로 묻기)을 재던 것. 단일 채널에서는 물어봐야 담을 그릇이 없어 **아예 안 묻는다** — `test_an_empty_menu_never_calls_the_lm` 이 그 자리다


def test_no_tool_to_call_is_a_different_event_from_not_calling_one():
    """C8 의 구분. `tool_called is None` 하나로는 두 사건이 같은 값으로 무너진다.

    🔴 2026-08-29 (T4): 예전에는 `tools_offered`(0 vs >0)로 **재구성**해야 했다. 지금은
    `decision_source` 가 그 이름을 직접 싣는다 — 재구성 규칙이 주석에만 살던 것이 이 레포가
    두 번 데인 자리다. `tools_offered` 도 함께 잰다(옛 규칙이 여전히 참인지 본다).

    🔴 `native_fc` 도 갈린다. `no_tools` 행은 **LM 을 아예 안 불렀으므로** `None`("못 쟀다")
    이지 `False`("재서 안 켜졌다")가 아니다 — 예전 판은 tool 필드를 뺀 시그니처로 실제로
    물어서 `False` 를 쟀다. 두 값을 접으면 "안 물었다" 가 "물었는데 native FC 가 안 섰다" 로
    둔갑한다."""
    _install(_call(), fc=True)
    none_offered = svc.macro(_req(valid=["Replace"], agents=[]))
    _install({"action": {"tool_calls": []}}, fc=True)
    offered_not_called = svc.macro(_req())
    assert none_offered["tool_called"] is None and offered_not_called["tool_called"] is None
    assert none_offered["decision_source"] == "no_tools"
    assert offered_not_called["decision_source"] == "no_call"
    assert none_offered["tools_offered"] == 0
    assert offered_not_called["tools_offered"] == 3
    assert none_offered["native_fc"] is None, "안 물었으면 '못 쟀다' 다"
    assert offered_not_called["native_fc"] is True


# ---------------------------------------------------------------------------------------------
# 여럿 온 tool 호출을 조용히 버리지 않는다
# ---------------------------------------------------------------------------------------------

def test_extra_tool_calls_are_counted_not_silently_dropped():
    """이 레인의 결정은 사건당 행동 하나다. 여럿 오면 첫 번째만 쓰되 그 사실이 남는다."""
    first = _call("deliver_battery")["action"]["tool_calls"][0]
    second = _call("swap_body", macro="Replace")["action"]["tool_calls"][0]
    _install({"action": {"tool_calls": [first, second]}}, fc=False)
    out = svc.macro(_req())
    assert out["tool_called"] == "deliver_battery"
    assert out["tool_calls_n"] == 2


# ---------------------------------------------------------------------------------------------
# 일치 판정은 **모델이 말한 macro** 로 잰다
# ---------------------------------------------------------------------------------------------

# 🔴 삭제 (2026-08-29 T4): `test_agreement_is_measured_on_what_the_model_said_not_on_the_coerced_macro` — 강등 전/후로 일치 판정이 갈리는 사건을 재던 것. 🔴 그 사건이 **구조적으로 도달 불가**가 됐다(실측 논증): 갈리려면 `MACRO_TO_TOOL[said] == 부른 tool` 이면서 `TOOL_TO_MACRO[부른 tool] ∉ valid` 여야 하는데, 그 둘이 동시에 참이면 `said ∉ valid` 라 T2 의 `check_tool_args` 가 `macro_outside_menu` 로 먼저 걸러 `said` 를 안 읽는다. 강등 전 이름으로 잰다는 계약 자체는 구현에 남아 있다(`called_said`/`said` 주석)


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
        _install(_call("deliver_battery", macro=macro), fc=False)
        out = svc.macro(_req())
        # 🔴 2026-08-29 (T4): 표 밖 macro 는 이제 **접지 실패**이기도 하다(T2 의
        #    `macro_outside_menu`). 그래서 호출이 집행에서 빠지고 `tool_called_forced` 로
        #    옮겨간다. 재려는 축(불일치율이 부풀려지는가)은 그대로다.
        assert out["tool_called_forced"] == "deliver_battery", macro
        assert out["tool_arg_error"] is not None and "macro" in out["tool_arg_error"], macro
        assert out["macro_tool_agree"] is None, \
            "macro=%r 는 표 밖이다 — '못 쟀다'(None)이지 '어긋났다'(False)가 아니다" % macro
        assert out["chosen"] == "SwapBattery", "접지 실패가 결정을 지우면 안 된다(F7)"


def test_a_macro_inside_the_table_still_yields_a_real_verdict():
    """음성 대조. 위 수정이 `macro_tool_agree` 를 통째로 None 으로 만들지 않았는지 본다 —
    표 안의 macro 는 True/False 를 그대로 낸다."""
    for macro, tool, want in [("SwapBattery", "deliver_battery", True),
                              ("SwapBattery", "swap_body", False),
                              ("NOOP", "no_intervention", True)]:
        extra = dict(agent=None, reason="nothing to fix") if tool == "no_intervention" else {}
        _install(_call(tool, macro=macro, **extra), fc=False)
        out = svc.macro(_req())
        assert out["tool_arg_error"] is None, (macro, tool, out["tool_arg_error"])
        assert out["macro_tool_agree"] is want, (macro, tool)


# ---------------------------------------------------------------------------------------------
# 사용자 결정 ② — 다섯 키(+ C8·중복호출 구분)가 `/decide` 에도 실린다
# ---------------------------------------------------------------------------------------------

_LANE_KEYS = ("tool_called", "tool_args", "expressible", "macro_tool_agree", "native_fc",
              "tools_offered", "tool_calls_n", "tool_lane_error",
              # ---- 2026-08-29 (단일 채널, T4) ------------------------------------------------
              # 🔴 `decision_source` 는 옛 재구성 규칙(다섯 키를 조합해 사건 종류를 알아내던
              #    것)을 대체한다. `tool_arg_error` 는 R26 억제와 접지 실패 억제를 가른다 —
              #    둘 다 `tool_called is None` 이다.
              "decision_source", "tool_arg_error",
              # ---- 2026-09-02 (귀속용 두 번째 질문) ------------------------------------------
              # 🔴 셋이 **한 커밋에서 함께** 움직여야 하는 자리다: `/decide` 의 `out["dspy"]`
              #    dict(표식 아래) · 줄리아 `TOOL_LANE_KEYS` · 이 튜플. 하나만 고치면
              #    `test/tool_lane_keys_survive.jl` (6)절의 **양방향 등호**가 즉시 빨개진다
              #    (실측: 셋 다 고치기 전 양쪽 11, 고친 뒤 양쪽 12).
              "menu_expressible")


def test_macro_reports_every_lane_key():
    _install(_call(), fc=False)
    out = svc.macro(_req())
    assert set(_LANE_KEYS) <= set(out)


def test_decide_carries_the_lane_keys_into_the_dspy_block():
    """🔴 `/macro` 는 이 레포에 **호출자가 없다**(실측: `grep -rn '/macro' --include='*.jl'
    --include='*.py' src tools wm4spacecraft_manufacturing test` = 정의 1건
    (`@app.post("/macro")`) · 주석/독스트링 언급 3건 · **호출 0건**). 라이브 레인은 `/decide`
    로만 들어온다(`tools/monitor/policy.jl:559`). 여기 안 실으면 접지가 실제로 도는 곳에서
    영원히 안 보인다.

    🔴 **키의 존재만 재면 안 된다** (fix round 1, M1). 값은 열 번의 손으로 적은 전사를
    거치므로, 존재만 재면 그중 여럿이 프로덕션에서 틀린 값을 나르면서 게이트가 초록이다 —
    실측: `decide()` 가 `native_fc=True` / `tools_offered=0` / `expressible=True` 를 못박는
    변이 셋이 이 파일의 검사 전부를 통과했다. **같은 요청의 `/macro` 응답과 값이 같은지** 잰다.

    ⚠️ 시나리오가 다섯인 이유: 하나만 쓰면 하드코딩 변이가 우연히 그 값과 같아 살아남는다.
    아래 마지막 블록이 **열 키 각각이 시나리오 사이에서 최소 두 값을 가지는지** 확인한다 —
    그게 "어떤 상수 하드코딩도 붉어진다" 의 통제다. 이 통제가 없으면 위 루프는 공허할 수 있다.

    🔴 2026-08-29 (T4): 시나리오 D 가 "파싱 실패 -> 구제" 였다. 그 경로가 사라졌으므로
    **`AdapterParseError` 를 던지는 프로그램**으로 바꿨다 — `tool_lane_error` 를 움직이는
    유일한 남은 축이고, 그것이 없으면 그 키가 상수가 되어 통제가 죽는다(실측: 그 상태로
    이 시험이 정확히 그 사실을 붉혔다).
    """
    two = {"action": {"tool_calls": [_call("deliver_battery")["action"]["tool_calls"][0],
                                     _call("swap_body", macro="Replace")["action"]["tool_calls"][0]]}}

    def _plain():
        # 🔴 2026-09-02: 대조용 두 번째 질문을 **이 시나리오에서만** 싣는다. 다른 셋은 `None`
        #    이므로 그 키가 시나리오 사이에서 실제로 **변한다** — 이 시험의 계약이 바로
        #    "상수인 키는 하드코딩 변이를 못 잡는다" 이고, 안 싣고 키만 더했을 때 이 시험이
        #    정확히 그 사실을 붉혔다(실측).
        _install(_call(menu_expressible=True), _call(menu_expressible=True), fc=False)

    def _bad_agent():
        bad = _call(agent="ConstructionBots.BotID{ConstructionBots.DeliveryBot}(99)")
        _install(bad, bad, fc=False)

    def _empty_menu():
        _install(_call(), _call(), fc=True)

    def _two_calls():
        _install(two, two, fc=False)

    def _parse_failure():
        class _Boom(_FCDummy):
            def __call__(self, *a, **kw):
                raise AdapterParseError(adapter_name="ChatAdapter", signature=svc.SelectTool,
                                        lm_response="",
                                        message="The LM returned an empty or null response.")
        dspy.configure(lm=_Boom([]), adapter=svc.build_adapter())
        svc._state["program"] = None
        svc._load_program()

    scenarios = [
        # (라벨, 프로그램을 세우는 함수, 요청 kwargs)
        # 🔴 fc=False 라야 tool 호출이 **텍스트 채널로** 돌아온다 — `_FCDummy` 는 native
        #    tool_call 을 낼 줄 모른다(이 파일 상단 참조). tool_* 키는 여기서만 움직인다.
        ("A tool call, grounded", _plain, {}),
        ("B tool call, grounding failure", _bad_agent, {}),
        ("C empty menu -> no_tools", _empty_menu, dict(valid=["Replace"], agents=[])),
        ("D two tool calls", _two_calls, {}),
        ("E empty response -> no_call", _parse_failure, {}),
    ]
    seen = {k: set() for k in _LANE_KEYS}
    for label, prep, kw in scenarios:
        prep()                                  # macro() 가 한 벌, decide() 가 한 벌 쓴다
        m = svc.macro(_req(**kw))
        d = svc.decide(_req(**kw))["dspy"]
        assert set(_LANE_KEYS) <= set(d), label
        for k in _LANE_KEYS:
            assert d[k] == m[k], "%s: decide()[%r]=%r != macro()[%r]=%r" % (label, k, d[k], k, m[k])
            seen[k].add(repr(m[k]))
    # 🔴 통제: 열 키 전부가 시나리오 사이에서 값이 갈려야 위 루프가 하드코딩을 붙잡는다.
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
    # 🔴 `svc._EXPR` 단언은 T3 이 지웠다 — `expressible` 은 더 이상 시그니처 필드가 아니라
    #    tool 인자다. 그 자리를 메우는 것은 `test_tool_registry.py::
    #    test_the_common_args_keep_their_json_schema_types` 다.


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


# ---- 2026-08-29 단일 채널 (T4) ----------------------------------------------------------------
# 🔴 계획서 Step 1 의 코드에서 **바꾼 것 하나**: `_call` 의 기본 `agent` 를 계획서의 리터럴
#    `"RobotID(DeliveryBot)(1)"` 이 아니라 이 파일의 `RID` 로 둔다. 계획서 값은 이 파일의
#    `AGENTS` 에 없는 id 라 T2 의 `check_tool_args` 가 `agent_outside_enum` 을 내고, 그러면
#    접지 실패 억제가 걸려 `tool_called` 이 None 이 된다 — 즉 계획서 그대로 쓰면 조립을
#    재려던 시험 넷이 전부 **접지 실패 경로**를 재게 된다(실측).
def _call(name="deliver_battery", **argkw):
    """tool 호출 하나를 낸 가짜 예측. 인자는 기본 완전형이고 kw 로 덮는다.

    🔴 이걸 쓰는 시험은 전부 `fc=False` 다 — 계획서 Step 1 의 `fc=True` 는 **이 harness 에서
    틀리다**(실측). `_FCDummy` 는 `supports_function_calling` 만 True 로 바꾼 DummyLM 이라
    native tool_call 을 직렬화할 줄 모르는데, 그 플래그가 켜지면 어댑터가 `action` 을 처리
    시그니처에서 **지우고**(`adapters/base.py:118-119`) 텍스트 경로로 보낸다 ⟹ `tool_calls`
    가 아예 안 도착해 `tool_called is None` 이 된다. 이 파일 상단 `_FCDummy` docstring 이
    같은 말을 하고, 기존 시나리오 C 도 같은 이유로 `fc=False` 다.
    ⟹ 그래서 **이 파일은 native FC 를 증명하지 않는다**(상단 모듈 docstring). 여기서 재는
    것은 조립 로직이고, native FC 발화의 감시자는 `test_native_fc_active.py` 다."""
    args = {"agent": RID, "macro": "SwapBattery", "reasoning": "r",
            "expressible": True, "ranking": "SwapBattery, Replace, NOOP"}
    args.update(argkw)
    # 🔴 `None` 인 인자는 **키째로 뺀다.** 안 그러면 `no_intervention` 호출에 `agent=None` 이
    #    남아 T2 의 `check_tool_args` 가 `off_schema_args` 를 내고, 조립을 재려던 시험이
    #    조용히 **접지 실패 경로**를 재게 된다(값이 아니라 키 집합으로 판정하기 때문).
    args = {k: v for k, v in args.items() if v is not None}
    return {"action": {"tool_calls": [{"name": name, "args": args}]}}


def test_chosen_comes_from_the_tool_name_not_from_any_text_field():
    """🔴 F5. `enact_target` 이 읽는 것은 `tool_called` 다. `chosen` 을 같은 값에서 유도해야
    집행과 채점이 갈릴 수 없다 — 실측에서 그 둘이 3/3 갈렸다."""
    _install(_call("deliver_battery", macro="SwapBattery"), fc=False)
    out = svc.macro(_req())
    assert out["tool_called"] == "deliver_battery"
    assert out["chosen"] == "SwapBattery" == svc.TOOL_TO_MACRO["deliver_battery"]
    assert out["decision_source"] == "tool"


def test_a_disagreeing_macro_arg_does_not_move_the_decision():
    """🔴 F5 의 핵심. macro 인자가 어긋나도 **집행이 이긴다.** 어긋난 사실은 기록만 된다."""
    _install(_call("deliver_battery", macro="Replace"), fc=False)
    out = svc.macro(_req())
    assert out["chosen"] == "SwapBattery", "tool 이 결정이다"
    assert out["macro_tool_agree"] is False, "어긋남은 기록된다"


def test_tool_args_carries_only_the_grounding_arg():
    """🔴 F9 — 이 계획에서 가장 위험한 자리. 줄리아 `TOOL_PARAM_SCHEMA`(llm_bridge.jl:148-151)
    는 `agent`/`reason` 둘만 선언한다. 공통 인자가 새면 `ground_tool_args` 가
    `reject:off_schema_param` 을 내고 **집행이 전 사건에서 정지한다.**"""
    _install(_call(), fc=False)
    out = svc.macro(_req())
    assert set(out["tool_args"]) == {"agent"}, \
        "공통 인자가 tool_args 로 새면 줄리아 집행이 멈춘다"


def test_the_python_and_julia_param_schemas_agree():
    """🔴 F9 교차 게이트. 두 표를 집합 등식으로 묶는다 — 한쪽만 늘리면 여기서 죽는다.

    🔴 이 게이트는 `_GROUNDING_ARGS`(2키) ↔ 줄리아 `TOOL_PARAM_SCHEMA` 만 묶는다. **`build_tools()`
    가 내는 JSON 스키마(5키) ↔ 줄리아 축은 아무도 안 지킨다** — 그걸 지킨다고 주장하는
    `test/tool_args_grounding.jl` 은 파이썬 **함수 시그니처**를 읽어서 이 축에 눈이 멀었고,
    T1 이 인자 넷을 더했을 때 145/145 초록이었다(실측, 계획서 §0-B ②). 재조준은 T6 몫이다."""
    import re
    import pathlib
    from tool_registry import MACRO_TO_TOOL, _needs_agent
    src = pathlib.Path(__file__).resolve().parents[2] / "respec" / "llm_bridge.jl"
    text = src.read_text(encoding="utf-8")
    block = text[text.index("const TOOL_PARAM_SCHEMA"):]
    block = block[:block.index("\n\n")]
    julia = {m[0]: set(m[1].split()) for m in
             [(a, " ".join(re.findall(r'"(\w+)"\s*=>\s*(?:true|false)', b)))
              for a, b in re.findall(r'"(\w+)"\s*=>\s*Dict\{String,Bool\}\((.*?)\)', block)]}
    assert julia, "TOOL_PARAM_SCHEMA 블록을 못 읽었다 — 게이트가 공허해진다"
    for name in MACRO_TO_TOOL.values():
        want = {"agent"} if _needs_agent(name) else {"reason"}
        assert julia[name] == want, "%s: julia=%s python=%s" % (name, julia[name], want)
    # 🔴 파이썬이 실제로 내보내는 집합과도 묶는다 — 위 루프만이면 `_GROUNDING_ARGS` 를 통째로
    #    바꿔도 초록이다(그 상수를 아무도 안 읽는다).
    assert svc._GROUNDING_ARGS == {k for d in julia.values() for k in d}


def test_margin_key_survives_as_none():
    """키가 사라지면 소비자가 '레인이 안 돌았다' 와 '값이 없다' 를 못 가른다."""
    _install(_call(), fc=False)
    out = svc.macro(_req())
    assert "margin" in out and out["margin"] is None


def test_text_rescue_key_is_gone():
    _install(_call(), fc=False)
    assert "text_rescue" not in svc.macro(_req())


def test_r26_suppresses_enactment_but_keeps_the_decision():
    """🔴 F7. R26 은 `tool_called` 를 지우지만 `chosen` 은 억제 **전** 이름에서 나온다 —
    규약이 '기록은 하되 집행에는 안 넘긴다' 이지 '결정을 지운다' 가 아니다."""
    _install(_call("no_intervention", macro="NOOP", expressible=False,
                   agent=None, reason="menu cannot fix this"), fc=False)
    out = svc.macro(_req())
    assert out["tool_called"] is None, "집행에 안 넘긴다"
    assert out["tool_called_forced"] == "no_intervention", "기록은 남는다"
    assert out["chosen"] == "NOOP", "결정은 살아 있다"
    assert out["tool_calls_n"] == 1, "F8 — 메뉴 거절(0)과 가르는 판별키다"
    assert out["expressible"] is False, "T2 합성의 방아쇠"


def test_a_forced_regime_with_no_call_is_named():
    """🔴 F15. `required` 인데 호출이 없다 = 계약 위반. `error` 와 가려야 한다."""
    _install({"action": {"tool_calls": []}}, fc=True)
    out = svc.macro(_req())
    assert out["decision_source"] == "no_call"
    assert out["chosen"] == ""
    assert out["error"] is None, "프로바이더 장애가 아니다 — error 를 쓰면 두 사건이 섞인다"
    assert out["tool_lane_error"] is None, "파싱도 안 깨졌다 — 호출만 안 왔다"


def test_an_empty_menu_never_calls_the_lm():
    """🔴 F2 의 짝. tool 이 0개면 결정을 받을 채널이 없다 — 부를 이유가 없고 과금만 한다."""
    _install(_call(), fc=False)
    before = svc._state["calls"]
    out = svc.macro(_req(agents=[], valid=["Replace"]))   # agent 없는 Replace -> tool 0개
    assert out["decision_source"] == "no_tools"
    assert out["tools_offered"] == 0
    assert svc._state["calls"] == before, "LM 을 부르면 안 된다"


def test_bad_tool_args_are_reported_not_enacted():
    """🔴 F10·F12. 접지 실패는 집행에 안 넘기되 **사유를 남긴다.**"""
    _install(_call(agent="ConstructionBots.BotID{ConstructionBots.DeliveryBot}(99)"), fc=False)
    out = svc.macro(_req())
    assert out["tool_arg_error"] is not None and "agent" in out["tool_arg_error"]
    assert out["tool_called"] is None, "접지 안 된 호출을 집행에 넘기지 않는다"
    assert out["tool_called_forced"] == "deliver_battery", "무엇이 왔는지는 남는다"
    assert out["tool_calls_n"] == 1, "호출은 왔다는 사실은 남는다"
    assert out["chosen"] == "SwapBattery", "F7 과 같은 축 — 결정은 살아 있다"
    # 🔴 접지 실패는 `agent` 축의 사건이다. 그것 때문에 `macro` 축의 측정까지 지우면
    #    접지 실패 부분모집단 전체가 불일치율의 분모에서 조용히 빠진다 — 이 레포가
    #    R26 에서 이미 한 번 피한 편향과 같은 모양이다(음성 대조 M6 가 이 자리를 붙잡는다).
    assert out["macro_tool_agree"] is True, \
        "agent 축의 접지 실패가 macro 축의 일치 판정까지 지웠다"


def test_a_parse_failure_is_a_contract_violation_not_a_provider_outage():
    """🔴 F14 재정의 (계획서 §0-B ③). `dspy/adapters/base.py:171-176` 은 텍스트도 tool_calls
    도 없으면 **시그니처와 무관하게** `AdapterParseError` 를 던진다 — native FC 판에서
    §4-1 구제가 도달하는 유일한 방아쇠다. 그런데 그 사건은 **프로바이더 장애가 아니다.**
    `error` 에 넣으면 `policy.jl` 의 `policy_entry` 가 레인을 통째로 `available=false` 로
    버리고, 계약 위반과 장애가 같은 자리에 섞인다."""
    class _Boom(_FCDummy):
        def __call__(self, *a, **kw):
            raise AdapterParseError(adapter_name="ChatAdapter", signature=svc.SelectTool,
                                    lm_response="", message="The LM returned an empty or null response.")
    dspy.configure(lm=_Boom([]), adapter=svc.build_adapter())
    svc._state["program"] = None
    svc._load_program()
    out = svc.macro(_req())
    assert out["decision_source"] == "no_call"
    assert out["error"] is None, "장애가 아니다"
    assert out["tool_lane_error"] is not None and "AdapterParseError" in out["tool_lane_error"]


def test_a_provider_outage_still_fills_error():
    """음성 대조. 위와 **가려져야** 한다 — `LMError` 는 진짜 장애이고 `error` 가 그 자리다."""
    class _Down(_FCDummy):
        def __call__(self, *a, **kw):
            raise LMError("provider is down")
    dspy.configure(lm=_Down([]), adapter=svc.build_adapter())
    svc._state["program"] = None
    svc._load_program()
    out = svc.macro(_req())
    assert out["decision_source"] == "no_call"
    assert out["error"] is not None and "LMError" in out["error"]
    assert out["tool_lane_error"] is None, "파싱 실패가 아니다"


# =================================================================================================
# 2026-09-02 — 대조용 두 번째 질문이 응답에 실린다 (G-4)
# spec: docs/superpowers/specs/2026-09-02-expressible-attribution-design.md
# =================================================================================================

def test_menu_expressible_is_reported_when_the_model_answers_it():
    """모델이 두 질문에 **다르게** 답한 사건이 이 레인이 재려는 바로 그 사건이다.

    `expressible=False`(NOOP 빼면 못 고친다) + `menu_expressible=True`(메뉴 전체로는 된다)
    = **메뉴 artifact 가 실재한다**.
    """
    _install(_call("deliver_battery", expressible=False, menu_expressible=True), fc=False)
    out = svc.macro(_req())
    assert out["expressible"] is False
    assert out["menu_expressible"] is True
    assert out["tool_arg_error"] is None, "정상 호출이 거절되면 안 된다: %r" % out["tool_arg_error"]


def test_a_missing_menu_expressible_is_none_not_false():
    """🔴 삼상 규약. 안 실린 것은 **못 쟀다**(`None`)이지 `False` 가 아니다.

    `False` 로 접으면 "메뉴 artifact 가 실재한다" 칸의 집계가 거짓으로 부풀어 오른다 --
    이 레인이 재려는 바로 그 값이다.
    """
    _install(_call("deliver_battery", expressible=False), fc=False)   # 새 필드 없이
    out = svc.macro(_req())
    assert out["expressible"] is False
    assert out["menu_expressible"] is None, "빠진 것을 False 로 접었다"
    assert out["tool_arg_error"] is None, "선택 필드 부재가 거절이 되면 안 된다"


def test_a_non_bool_menu_expressible_is_none_and_never_erases_the_decision():
    """파싱 실패도 `None` 이고, **결정은 살아남는다.**

    기존 `expressible` 이 같은 축에서 그렇게 동작한다
    (`test_a_non_bool_expressible_is_none_not_a_false_true`) -- 측정용 필드가 그보다 더 큰
    권한을 가지면 안 된다.
    """
    _install(_call("deliver_battery", menu_expressible="False"), fc=False)
    out = svc.macro(_req())
    assert out["menu_expressible"] is None, "bool() 로 감싸면 여기가 True 가 된다"
    assert out["chosen"] == "SwapBattery", "측정용 필드가 결정을 지웠다"
    assert out["tool_arg_error"] is not None and "menu_expressible" in out["tool_arg_error"]


def test_the_blank_decision_carries_the_key_too():
    """레인이 안 돈 사건에서도 **키는 있어야** 한다 -- 없으면 소비자가 두 사건을 못 가른다."""
    blank = svc._blank_decision(["NOOP"], "state line", "no_tools", [])
    assert "menu_expressible" in blank, "키가 통째로 사라지면 '안 돌았다' 와 '값 없다' 가 같아진다"
    assert blank["menu_expressible"] is None
