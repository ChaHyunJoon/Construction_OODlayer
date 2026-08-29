"""`tool_choice="required"` 가 **프로바이더 요청까지 실제로 도달하는가**, 그리고 그것이
`expressible` 과 R26 을 안 부수는가 (Plan B, 2026-08-29).

왜 이 파일이 있나 (실측, 2026-08-28 유료 스윕 — 재도출하지 않는다):
    fault  : tools_offered=2 · native_fc=True · tool_called=None · tool_calls_n=0 · 오류 없음
    battery: tools_offered=3 · native_fc=True · tool_called=None · tool_calls_n=0 · 오류 없음
tool 을 내밀고 native FC 가 진짜로 켜진 판에서 gpt-4o 가 **호출을 거절하고 텍스트로 답했다.**
유력한 설명은 이 레인이 `tool_choice` 를 한 번도 안 보냈다는 것이다.

🔴 2026-08-29 (T-C) 정정 — **무조건 강제는 반증됐다.** 컨트롤러가 같은 요청·같은 빌드로
   `DSPY_TOOL_CHOICE` 만 갈라 유료 2콜을 냈고, `required` 판이 텍스트 채널을 통째로 비웠다
   (`reasoning=""` · `expressible=null` · `chosen=""` -> `coerced` NOOP, **예외 없음**).
   그래서 `TOOL_CHOICE_DEFAULT` 는 `None` 이 됐고 강제는 **요청이 사건마다** 정한다
   (`MacroRequest.tool_choice`, 유도는 `policy.jl` 의 `tool_choice_for`). 이 파일의 `_req()` 는
   그 새 규약에 맞춰 **요청에 `tool_choice="required"` 를 싣는다** — 그래야 아래 기존 단언들이
   예전과 같은 레짐을 계속 잰다. 우선순위·기본값·텍스트 구제는 (5)(6) 절이 새로 잰다.

🔴 이 파일은 **라이브 LM 을 한 번도 안 부른다.** 단언은 전부 "보내질 kwargs" 에 대해 한다.
   `svc.macro()` 는 가짜 LM 으로만 돌리고, 그 가짜 LM 이 `__call__` 로 받은 것이 곧
   `adapters/base.py:236` 의 `lm(messages=..., **data)` 이고 `data` 는
   `clients/openai_format.py:to_openai_chat_request` 의 산출물 — 즉 **프로바이더 요청 본문**이다.

⚠️ `DummyLM.supports_function_calling` 은 `False` 다(`clients/base_lm.py`). 그래서 기본
   DummyLM 왕복은 **텍스트 폴백 경로**를 재는 것이고 native FC 가 켜졌다는 증명이 될 수 없다.
   여기서는 `test_macro_returns_tool_call.py` 와 같은 `_FCDummy` 규약으로 그 속성을 True 로
   덮어 native FC 분기(`adapters/base.py:110`)를 실제로 태운 뒤, **어댑터가 만든 kwargs** 를
   단언한다. native FC 배선 자체의 감시자는 `test_native_fc_wired.py` 이고 생략 불가다.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import dspy_service as svc  # noqa: E402  (numpy/sklearn-before-dspy 계약: dspy 보다 먼저)
import dspy  # noqa: E402
import pytest  # noqa: E402
from dspy.utils.dummies import DummyLM  # noqa: E402

AGENTS = [{"id": "ConstructionBots.BotID{ConstructionBots.DeliveryBot}(5)", "label": "Robot R5 / robot 5"}]
RID = AGENTS[0]["id"]
# 🔴 2026-08-29 (T4): `{"agent": RID}` 하나였다. 결정 성분이 tool 인자로 옮겨간 뒤로는
#    공통 인자 넷이 없으면 T2 의 `check_tool_args` 가 `missing_args` 를 내고, 그 호출은
#    집행에서 빠져 **조립을 재려던 시험이 조용히 접지 실패 경로를 재게 된다.**
def _args(**kw):
    a = {"agent": RID, "macro": "SwapBattery", "reasoning": "battery is flat",
         "expressible": True, "ranking": "SwapBattery, NOOP, Replace"}
    a.update(kw)
    return {k: v for k, v in a.items() if v is not None}


def _call(name="deliver_battery", **kw):
    return {"tool_calls": [{"name": name, "args": _args(**kw)}]}


CALL = _call()


def _req(**kw):
    # 🔴 `tool_choice="required"` 는 **요청 채널**이다(T-C). 환경변수가 없을 때만 이긴다 —
    #    `_clean_env` 픽스처가 그 환경변수를 지우므로 이 파일의 기본 판은 "요청이 강제한 판"이다.
    base = dict(kind="battery", soc=0.1, agents=AGENTS,
                valid=["NOOP", "Replace", "SwapBattery"],
                tool_choice="required",
                nl="Robot R5 has run its battery down and stopped.")
    base.update(kw)
    return svc.MacroRequest(**base)


def _answer(**kw):
    base = {"reasoning": "r", "expressible": "True", "action": {"tool_calls": []},
            "macro": "NOOP", "ranking": "NOOP, Replace, SwapBattery", "margin": "0.0"}
    base.update(kw)
    return base


class _CaptureLM(DummyLM):
    """**프로바이더로 나갈 kwargs 를 그대로 붙잡는** 가짜 LM.

    🔴 `self.seen` 에 쌓이는 dict 이 곧 `to_openai_chat_request(request)` 의 결과다
    (`adapters/base.py:235-236` 의 `lm(messages=..., **data)`). 소스 텍스트가 아니라
    **요청 본문**을 재는 자리.
    """

    _fc = False

    def __init__(self, answers):
        super().__init__(answers)
        self.seen = []

    @property
    def supports_function_calling(self):
        return self._fc

    def __call__(self, **kw):
        self.seen.append(kw)
        return super().__call__(**kw)


class _FCCaptureLM(_CaptureLM):
    """`supports_function_calling` 이 True 인 판. 이때만 어댑터가 `tools`/`tool_choice` 를
    **안 지우고** 프로바이더 요청에 싣는다(`adapters/base.py:97` 의 pop 루프는
    `if not self.use_native_function_calling:` 안에만 있고, `:110` 분기는 이 속성을 본다)."""

    _fc = True


# 🔴 두 판이 필요한 이유 (실측). `fc=True` 면 어댑터가 시그니처에서 `action`(ToolCalls) 필드를
#    **삭제한다**(`adapters/base.py:119`) — 호출은 프로바이더 응답의 `tool_calls` 로 오게 되어
#    있는데 가짜 LM 은 그것을 못 만든다. 그래서 그 판에서는 `tool_called` 이 **언제나 None** 이고
#    R26·응답 모양을 잴 수 없다. 반대로 `fc=False` 판에서는 `action` 이 텍스트로 파싱돼 호출
#    모양을 만들 수 있지만 `tool_choice` 는 pop 되어 요청에 안 남는다.
#    → **kwargs 단언은 fc=True 에서, 응답 모양·R26 단언은 fc=False 에서** 한다. 한 판으로
#      둘 다 하려다 조용히 아무것도 안 재는 시험이 되는 자리다.
def _install(*answers, fc=False):
    lm = (_FCCaptureLM if fc else _CaptureLM)(list(answers))
    dspy.configure(lm=lm, adapter=svc.build_adapter())
    svc._state["program"] = None          # 프로그램 재조립을 강제한다
    svc._load_program()
    return lm


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    """손잡이는 호출 시점에 읽힌다. 바깥 환경이 이 파일의 판정을 흔들지 못하게 지운다."""
    monkeypatch.delenv(svc.TOOL_CHOICE_ENV, raising=False)


# ---------------------------------------------------------------------------------------------
# (1) tool_choice 가 프로바이더 요청까지 도달한다
# ---------------------------------------------------------------------------------------------

def test_tool_choice_required_reaches_the_provider_request():
    """🔴 이 파일이 존재하는 이유. 소스에 문자열이 있는지가 아니라 **나갈 요청에 있는지**를 잰다.

    변이 증명: `dspy_service._ask` 에서 `kw["config"] = {"tool_choice": choice}` 를 지우면
    이 단언이 빨개진다(수정 보고서가 그 실행 출력을 인용한다).
    """
    lm = _install(_answer(action=CALL, macro="SwapBattery"), fc=True)
    out = svc.macro(_req())
    assert lm.seen, "가짜 LM 이 한 번도 안 불렸다 — 이 시험은 아무것도 안 쟀다"
    first = lm.seen[0]
    assert first.get("tool_choice") == "required", (
        "프로바이더로 나갈 요청에 tool_choice 가 없다(또는 값이 다르다): %r" % (first.get("tool_choice"),))
    # 양성 대조: tool 도 실제로 실려 있어야 한다. tool 없이 tool_choice 만 가면 400 이다.
    assert first.get("tools"), "tools 가 요청에 없다 — tool_choice 만으로는 프로바이더가 400 을 낸다"
    assert out["tools_offered"] == 3


def test_tool_choice_is_not_sent_when_no_tool_is_offered():
    """🔴 400 방지 계약. `clients/openai_format.py` 는 `tool_choice` 를 `:81` 에서, `tools` 를
    `:83` 의 `if request.tools:` 에서 **따로** 싣는다 — 즉 tool 이 0개여도 tool_choice 는
    그대로 나간다. C8 축약(메뉴가 빈 요청)이 그 조합을 만들면 안 된다."""
    lm = _install(_answer(), fc=True)
    out = svc.macro(_req(agents=[], valid=["Replace", "SwapBattery"]))
    # ⚠️ `valid=["NOOP"]` 로는 이 판이 안 만들어진다 — `no_intervention` 은 agent 를
    #    안 받아 로봇 id 가 없어도 tool 이 **1개** 나온다(`tool_registry._needs_agent`).
    #    agent 를 받는 팔만 남겨야 `build_tools` 가 진짜로 `[]` 를 낸다.
    assert out["tools_offered"] == 0
    # 🔴 2026-08-29 (T4): 계약이 **더 강해졌다.** 예전에는 "요청은 나가되 tool_choice 키가
    #    안 실린다" 였는데(`assert lm.seen`), 단일 채널에서는 tool 이 0개면 결정을 받을 채널이
    #    아예 없으므로 **요청 자체를 안 보낸다** — 400 이 구조적으로 불가능해지고 과금도 0 이다.
    assert lm.seen == [], "tool 0개인데 LM 을 불렀다 — 담을 그릇이 없는 질문이고 과금만 한다"
    assert out["tool_choice"] is None
    assert out["decision_source"] == "no_tools"


def test_the_env_knob_restores_the_previous_regime(monkeypatch):
    """비교 판을 로직 편집 없이 돌릴 수 있어야 한다. 빈 값이면 **키 자체가 안 나간다** =
    2026-08-29 이전과 같은 요청."""
    monkeypatch.setenv(svc.TOOL_CHOICE_ENV, "")
    lm = _install(_answer(action=CALL, macro="SwapBattery"), fc=True)
    out = svc.macro(_req())
    assert lm.seen and "tool_choice" not in lm.seen[0]
    assert out["tool_choice"] is None, "옛 레짐의 행은 표식이 None 이어야 한다"


def test_the_env_knob_can_also_send_auto(monkeypatch):
    """`auto` 는 `""` 와 다르다 — 의미는 프로바이더 기본값과 같아도 **키가 실린다**. 그 차이가
    응답의 표식에 남아 세 판(안 보냄 / auto / required)이 구별된다."""
    monkeypatch.setenv(svc.TOOL_CHOICE_ENV, "auto")
    lm = _install(_answer(action=CALL, macro="SwapBattery"), fc=True)
    out = svc.macro(_req())
    assert lm.seen[0].get("tool_choice") == "auto"
    assert out["tool_choice"] == "auto"


def test_a_bare_kwarg_would_never_reach_the_provider():
    """🔴 음성 대조 겸 함정 표식. `prog(tool_choice=...)` 로 주면 dspy 는 그것을 "시그니처에
    없는 입력 필드" 로 보고 **경고 한 줄 내고 버린다**(`predict.py:191-198`). 즉 그 배선은
    소스만 읽으면 맞아 보이는데 프로바이더에는 아무것도 안 간다. `config=` 여야 한다.

    이 시험이 초록인 동안에는 "맨 kwarg 로 바꿔도 되지 않나" 라는 편집이 조용히 통과하지 못한다.
    """
    lm = _install(_answer(action=CALL, macro="SwapBattery"), fc=True)
    prog = svc._state["program"]
    prog(signature=prog.signature, state="x", valid_actions="NOOP",
         tools=svc.build_tools(AGENTS, ["NOOP", "SwapBattery"]), tool_choice="required")
    assert lm.seen, "LM 이 안 불렸다"
    assert "tool_choice" not in lm.seen[-1], (
        "맨 kwarg 가 프로바이더까지 갔다 — 이 시험의 전제(그리고 _ask 의 config= 근거)가 틀렸다")


# ---------------------------------------------------------------------------------------------
# (2) expressible 은 여전히 도달 가능하고 여전히 합성을 발화시킨다
# ---------------------------------------------------------------------------------------------

def test_expressible_false_survives_a_forced_tool_call():
    """🔴 절대 깨면 안 되는 것. 호출을 강제해도 모델은 여전히 "가진 어떤 tool 도 내가 본 것을
    표현 못 한다" 고 **말할 수 있어야** 한다. `expressible` 은 별도의 bool OutputField 라
    tool 호출과 독립이고, 이 시험이 그 독립성을 못박는다.

    🔴 2026-08-29 (T4): "별도의 bool OutputField" 는 더 이상 참이 아니다 — `expressible` 은
    이제 **같은 tool 호출의 인자**다. 그래서 독립성 주장은 채널이 아니라 **의미**로 옮겨간다:
    호출을 강제받은 모델이 그 호출 안에서 "이걸로는 안 된다" 고 말할 수 있어야 한다."""
    _install(_answer(action=_call(expressible=False)))
    out = svc.macro(_req())
    assert out["expressible"] is False, "강제 호출이 expressible 을 도달 불가로 만들었다"
    assert out["tool_calls_n"] == 1, "호출은 실제로 있었다"
    assert out["tool_arg_error"] is None, "억제 이유가 R26 이지 접지 실패가 아니어야 한다"


def test_expressible_false_still_fires_the_synthesis_lane():
    """합성 레인의 **유일한** 발화 조건이 `expressible == False` 다(spec §8-1). 강제 호출이
    그 발화를 삼키면 T2 가 영원히 안 돈다."""
    _install(_answer(action=_call(expressible=False)))
    out = svc.macro(_req())
    assert out["synthesis"]["synthesis_event"] is True, (
        "강제 호출이 온 사건에서 합성 발화가 사라졌다 — R26 구현이 expressible 을 덮었다는 뜻")


# ---------------------------------------------------------------------------------------------
# (3) R26 — 강제된 호출은 집행의 근거가 아니다
# ---------------------------------------------------------------------------------------------

def test_r26_a_forced_call_with_expressible_false_yields_no_importable_agent():
    """🔴 컨트롤러 판정 R26. 줄리아 집행 경로(`tools/monitor/enact.jl` 의 `enact_target`)가
    읽는 것은 `tool_called` · `tool_args` 두 값이므로, 거절을 그 **값 안에서** 말해야 한다."""
    _install(_answer(action=_call(expressible=False)))
    out = svc.macro(_req())
    assert out["tool_called"] is None, "집행 채널에 강제된 호출 이름이 남았다"
    assert out["tool_args"] == {}, "집행 채널에 강제된 호출의 agent 가 남았다"
    assert RID not in repr(out["tool_args"]), "로봇 id 가 집행 채널로 샜다"
    # 기록은 남는다 — 그것은 데이터다.
    assert out["tool_called_forced"] == "deliver_battery"
    assert out["tool_args_forced"] == {"agent": RID}
    assert out["tool_calls_n"] == 1


def test_r26_leaves_the_julia_grounding_with_nothing_to_admit():
    """줄리아 쪽 계약을 파이썬에서 재현한다. `CB.ground_tool_args`
    (`src/respec/llm_bridge.jl:306-307`)의 첫 줄은 `tool_called` 가 **비지 않은 문자열**이
    아니면 `("deferred:no_tool_call", ...)` 를 낸다. `enact_target` 은 `admit` 이 아니면
    agent 를 안 들인다. 그러므로 아래 두 값이면 줄리아를 한 줄도 안 고치고 R26 이 선다."""
    _install(_answer(action=_call(expressible=False)))
    tl = svc.decide(_req())["dspy"]
    tc = tl["tool_called"]
    assert not (isinstance(tc, str) and tc), (
        "ground_tool_args 의 첫 줄을 통과해 버린다 — deferred 가 아니라 판정이 계속된다: %r" % (tc,))


def test_r26_does_not_fire_when_expressible_is_true():
    """억제는 `expressible == False` 에서만이다. True 인 사건의 호출은 그대로 집행으로 간다 —
    아니면 이 커밋이 tool 레인 전체를 조용히 죽인다."""
    _install(_answer(action=_call(expressible=True)))
    out = svc.macro(_req())
    assert out["tool_called"] == "deliver_battery"
    assert out["tool_args"] == {"agent": RID}
    assert out["tool_called_forced"] is None
    assert out["tool_args_forced"] == {}


def test_a_non_bool_expressible_is_suppressed_for_a_different_reason_than_r26():
    """`None` 은 "못 쟀다" 이지 "표현 못 한다" 가 아니다(spec §9-2).

    🔴 2026-08-29 (T4): 이 시험의 이름과 주장이 **둘 다 바뀌었다.** 예전 주장은 "억제는
    `expressible is False` 에서만" 이었고, `None` 사건에서 호출이 집행으로 그대로 갔다.
    지금은 `expressible` 이 tool **인자**라서 bool 이 아니면 T2 의 `check_tool_args` 가
    `expressible_not_a_bool` 을 내고, **접지 실패**를 이유로 같은 억제가 걸린다.
    ⟹ 두 억제가 겹치는 것은 의도된 것이다. 지켜야 할 것은 **이유가 섞이지 않는 것**이고,
      가르는 키는 `tool_arg_error` 다. 그리고 합성 레인은 여전히 `False` 에서만 발화한다 —
      그것이 이 시험이 지키는 spec §9-2 의 실질이다."""
    _install(_answer(action=_call(expressible="maybe")))
    out = svc.macro(_req())
    assert out["expressible"] is None, "'maybe' 를 False 로 접으면 안 된다"
    assert out["tool_arg_error"] is not None and "expressible" in out["tool_arg_error"], \
        "억제 이유가 R26 으로 기록되면 두 사건이 한 버킷에 들어간다"
    assert out["synthesis"]["synthesis_event"] is not True, \
        "'못 쟀다' 가 합성을 발화시켰다 — 그 방아쇠는 모델이 **말한** False 하나다"


def test_r26_keeps_the_agreement_measurable():
    """🔴 억제는 **집행 채널**만 비운다. `macro_tool_agree` 가 재는 것은 모델의 출력에 대한
    사실이므로 억제 전 호출로 재야 한다 — 아니면 R26 부분모집단 전체가 조용히 "못 쟀다" 로
    빠져 불일치율이 편향된다(강등 전 이름 `said` 를 쓰는 기존 논증과 같은 축)."""
    _install(_answer(action=_call(expressible=False)))
    out = svc.macro(_req())
    assert out["macro_tool_agree"] is True, (
        "R26 이 일치 판정까지 지웠다 — 억제는 집행 채널에만 걸려야 한다")


# ---------------------------------------------------------------------------------------------
# (4) 레짐 표식 — 두 세대의 행이 한 표에서 갈린다
# ---------------------------------------------------------------------------------------------

def test_the_regime_marker_is_present_and_correct_on_both_endpoints():
    _install(_answer(action=CALL, macro="SwapBattery"))
    req = _req()
    assert svc.macro(req)["tool_choice"] == "required"
    _install(_answer(action=CALL, macro="SwapBattery"))
    assert svc.decide(req)["dspy"]["tool_choice"] == "required", (
        "라이브 레인은 /decide 로만 들어온다 — 여기 없으면 표식이 실제로 도는 곳에서 안 보인다")


def test_an_r26_row_is_distinguishable_from_a_declined_menu():
    """🔴 이 레포가 두 번 밟은 함정. 억제된 행은 `tool_called is None` 이라 "모델이 거절했다"
    (C8 ②)와 **글자 그대로 같은 모양**이 된다. 가르는 키가 실제로 있는지 두 행을 나란히
    만들어 못박는다."""
    _install(_answer(action=_call(expressible=False)))
    r26 = svc.macro(_req())
    _install(_answer(action={"tool_calls": []}))
    declined = svc.macro(_req())

    # 옛 세 키짜리 규칙으로는 **구별 불가**다.
    def old_rule(d):
        return d["tools_offered"] > 0 and d["tool_called"] is None and d["tool_lane_error"] is None
    assert old_rule(r26) and old_rule(declined), (
        "전제가 깨졌다 — 두 행이 옛 규칙에서 같은 모양이 아니면 이 시험은 아무것도 안 지킨다")
    # 가르는 키는 `tool_calls_n` 이고, 그것은 줄리아가 이미 나르는 여덟 키 안에 있다.
    assert r26["tool_calls_n"] > 0 and declined["tool_calls_n"] == 0


def test_the_forced_regime_marks_every_row_it_produced():
    """세대 경계. 이 커밋 이전 행에는 `tool_choice` 키가 아예 없고, 이후 강제 판의 행은
    `"required"` 를 단다. 그래서 한 표에 섞여도 경계가 보인다."""
    _install(_answer(action=CALL))
    forced = svc.macro(_req())
    assert forced["tool_choice"] == "required"
    assert forced["tools_offered"] > 0
    # 강제 판에서 "모델이 거절했다"(C8 ②)는 원리상 관측되지 않는다. 소비자 규칙이 그것을
    # 반영해야 한다는 사실을 여기 못박는다.
    assert not (forced["tool_called"] is None and forced["tool_calls_n"] == 0), (
        "강제 판에서 호출 0건이 나왔다 — 그 행을 '거절'로 세면 두 레짐이 섞인다")


def test_the_new_keys_stay_above_the_tool_lane_marker():
    """🔴 교차언어 결속의 파이썬 쪽 절반. `test/tool_lane_keys_survive.jl` (6)절은
    `out["dspy"]` 의 `# ---- tool 레인 …` 표식 **아래** 키 집합을 Julia 의 `TOOL_LANE_KEYS`
    와 양방향 등호로 대조한다. 여기서는 그 집합이 **의도한 그대로인지**를 잰다.

    🔴 2026-08-29 (T4): 기대 집합이 바뀌었다 — `text_rescue` 가 빠지고
    `decision_source`·`tool_arg_error` 가 들어왔다. ⚠️ **줄리아 쪽 `TOOL_LANE_KEYS` 는 아직
    옛 열 개다.** 그래서 `test/tool_lane_keys_survive.jl` **(6)절**이 지금 **정당하게
    빨갛다**(실측: T4 가 더한 실패는 정확히 2개) — T6 이 그 튜플 하나를 고치면 닫힌다. 파이썬에서 키를 표식 위로 숨겨 초록을
    만들지 않는 이유: 그러면 줄리아가 이 셋을 영원히 안 나르는 상태가 조용해진다.
    `test_synthesize.py` 의 같은 이름 시험과 짝이다."""
    import ast as _ast
    import re as _re
    src = open(os.path.join(HERE, "dspy_service.py"), encoding="utf-8").read()
    lines = src.split("\n")
    lits = [n.value for n in _ast.walk(_ast.parse(src))
            if isinstance(n, _ast.Assign) and len(n.targets) == 1
            and isinstance(n.targets[0], _ast.Subscript)
            and isinstance(n.targets[0].value, _ast.Name)
            and n.targets[0].value.id == "out"
            and isinstance(n.targets[0].slice, _ast.Constant)
            and n.targets[0].slice.value == "dspy"
            and isinstance(n.value, _ast.Dict)]
    assert len(lits) == 1
    d = lits[0]
    # 표식 정규식은 줄리아 추출기의 것과 같아야 한다. 베끼지 않고 그 파일에서 읽는다.
    repo = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
    jl = os.path.join(repo, "test", "tool_lane_keys_survive.jl")
    assert os.path.exists(jl), "%s 가 없다 — 이 결속의 반대편이 사라졌다" % jl
    m = _re.search(r'_PY_EXTRACT = raw"""\n(.*?)\n"""', open(jl, encoding="utf-8").read(), _re.S)
    assert m
    pat = _re.search(r're\.match\(r"([^"]+)"', m.group(1))
    assert pat
    marker_re = _re.compile(pat.group(1))
    marks = [i + 1 for i in range(d.lineno - 1, d.end_lineno) if marker_re.match(lines[i])]
    assert len(marks) == 1, (
        "`out['dspy']` 안의 표식이 %d 개다 — 줄리아 추출기는 정확히 1개를 요구하고, 아니면 "
        "그 게이트는 빨개지는 게 아니라 추출 실패로 죽는다." % len(marks))
    lane = [k.value for k in d.keys if k.lineno > marks[0]]
    # 🔴 2026-08-29 (T4): `text_rescue` 는 사라졌고(되찾을 텍스트 채널이 없다)
    #    `decision_source`·`tool_arg_error` 가 들어왔다. 줄리아 쪽 동기화는 T6.
    assert set(lane) == {"tool_called", "tool_args", "tool_calls_n", "tools_offered",
                         "expressible", "native_fc", "tool_lane_error", "macro_tool_agree",
                         "tool_choice", "decision_source", "tool_arg_error"}, lane
    allk = [k.value for k in d.keys]
    # R26 기록 둘은 **범위 밖**이라 표식 위에 그대로 남는다(줄리아가 아직 안 읽는다).
    for k in ("tool_called_forced", "tool_args_forced"):
        assert k in allk, "%s 가 /decide 응답에서 사라졌다" % k
        assert k not in lane


# ---------------------------------------------------------------------------------------------
# (5) 우선순위 — 요청이 정하고 환경변수가 킬스위치다 (T-C, 2026-08-29)
# ---------------------------------------------------------------------------------------------

def test_tool_choice_survives_the_pydantic_boundary():
    """🔴 이 레포가 이미 두 번 밟은 함정(`total_nodes` · `zones`): pydantic 은 **선언 안 된 키를
    조용히 버린다.** 선언이 없으면 호출자가 실어 보내도 서비스는 못 보고, 모든 사건이 "요청이
    강제를 안 했다" 로 굳는데 증상은 호출자 쪽 결함처럼 보인다."""
    assert _req().tool_choice == "required"
    assert _req(tool_choice=None).tool_choice is None


# 🔴 삭제 (2026-08-29 T5): `test_the_default_is_no_longer_unconditionally_required` —
#    "요청도 환경변수도 없으면 키를 안 보낸다" 를 재던 것. **그 기본값이 뒤집혔다**(F3: 강제
#    없이 호출률 0/3). 반증됐던 것은 "무조건 강제" 자체가 아니라 텍스트 채널을 죽이면서
#    강제하는 것이었고, T3 이 그 채널을 없애 인과를 끊었다. 그 자리는 위 (6b)절의
#    `test_the_default_is_required` 와 `test_parallel_tool_calls_reaches_the_provider_request`
#    가 메운다. **요청이 명시적으로 `""` 를 실으면 여전히 안 보낸다** — 그건
#    `test_every_legal_value_still_passes_untouched` 가 계속 지킨다.


def test_an_explicit_empty_string_in_the_request_still_sends_nothing():
    """🔴 기본값이 `"required"` 가 된 뒤에도 **요청이 끄는 길**은 살아 있어야 한다.
    `None`(안 실었다)과 `""`(끄라고 실었다)는 다른 사건이고, 접으면 호출자가 이 레인을
    사건 단위로 끌 방법이 사라진다."""
    lm = _install(_answer(action=CALL), fc=True)
    out = svc.macro(_req(tool_choice=""))
    assert out["tools_offered"] > 0, "tool 이 0개면 이 시험은 400 방지 계약을 다시 재는 것이다"
    assert "tool_choice" not in lm.seen[0], (
        "요청이 명시적으로 껐는데 키가 나갔다: %r" % (lm.seen[0].get("tool_choice"),))
    assert "parallel_tool_calls" not in lm.seen[0], "두 키는 같은 조건 아래 있어야 한다"
    assert out["tool_choice"] is None


def test_the_request_decides_when_the_env_knob_is_absent():
    """환경변수가 **아예 없을 때**만 요청이 이긴다. 그 값은 호출자가 사건마다 계산한 것이다
    (`policy.jl` 의 `tool_choice_for`: novelty 를 실제로 재서 familiar 인 사건에만 required)."""
    lm = _install(_answer(action=CALL, macro="SwapBattery"), fc=True)
    out = svc.macro(_req(tool_choice="required"))
    assert lm.seen[0].get("tool_choice") == "required"
    assert out["tool_choice"] == "required"


def test_the_env_knob_beats_the_request_in_both_directions(monkeypatch):
    """🔴 **양방향** 킬스위치다. 한 방향만 재면 절반이 조용히 죽는다.

    ⚠️ 판정은 `os.environ.get(...) is not None` 이지 truthiness 가 아니다 — `""` 는 "안 걸었다"
    가 아니라 **"끄라고 걸었다"** 이고, 그 둘을 접으면 OFF 방향이 사라진다(그러면 이미
    녹화된 강제 판을 로직 편집 없이 되돌릴 수 없다).
    """
    # (a) OFF 방향: 요청이 강제해도 환경변수가 끈다.
    monkeypatch.setenv(svc.TOOL_CHOICE_ENV, "")
    lm = _install(_answer(action=CALL, macro="SwapBattery"), fc=True)
    out = svc.macro(_req(tool_choice="required"))
    assert "tool_choice" not in lm.seen[0], "요청이 킬스위치를 이겼다"
    assert out["tool_choice"] is None
    # (b) ON 방향: 요청이 아무 말도 안 해도 환경변수가 켠다.
    monkeypatch.setenv(svc.TOOL_CHOICE_ENV, "required")
    lm = _install(_answer(action=CALL, macro="SwapBattery"), fc=True)
    out = svc.macro(_req(tool_choice=None))
    assert lm.seen[0].get("tool_choice") == "required", "환경변수가 요청의 침묵을 못 이겼다"
    assert out["tool_choice"] == "required"


def test_the_pure_helper_reads_both_sources_in_order(monkeypatch):
    """`tool_choice(req)` 자체를 직접 태운다 — `macro()` 를 통과하지 않고도 우선순위가 못박힌다."""
    monkeypatch.delenv(svc.TOOL_CHOICE_ENV, raising=False)
    # 🔴 2026-08-29 (T5): 예전엔 `is None` 이었다. 요청 객체가 없으면 **기본값**이 서고,
    #    그 기본값이 `"required"` 로 바뀌었다(F3). `""` 와 갈리는 것이 요점이다:
    #    `None`("안 실었다") -> 기본값 · `""`("끄라고 실었다") -> 안 보냄.
    assert svc.tool_choice(None) == "required"
    assert svc.tool_choice(_req(tool_choice="required")) == "required"
    assert svc.tool_choice(_req(tool_choice="")) is None      # 빈 문자열은 키를 안 보낸다
    monkeypatch.setenv(svc.TOOL_CHOICE_ENV, "auto")
    assert svc.tool_choice(_req(tool_choice="required")) == "auto"
    monkeypatch.setenv(svc.TOOL_CHOICE_ENV, "")
    assert svc.tool_choice(_req(tool_choice="required")) is None


# ---------------------------------------------------------------------------------------------
# (6) 텍스트 채널 붕괴 구제 — 🔴 **절 전체 삭제** (2026-08-29, T4)
# ---------------------------------------------------------------------------------------------
#
# 무엇이 사라졌나: `text_rescue` 삼상과 그것을 재던 시험 열 개
#   test_a_collapsed_text_channel_is_rescued_and_both_channels_survive
#   test_the_rescue_carries_the_first_attempts_stamps
#   test_the_rescue_keeps_macro_tool_agree_measurable
#   test_the_rescue_costs_one_more_predicting_call
#   test_text_rescue_is_none_when_nothing_collapsed
#   test_text_rescue_is_none_when_the_request_did_not_force
#   test_text_rescue_is_false_when_the_text_channel_stays_empty
#   test_the_three_states_are_distinct_values
#   test_a_rescued_expressible_false_fires_r26
#   test_a_rescued_expressible_false_still_fires_the_synthesis_lane
#   test_decide_carries_the_rescue_flag
#
# 🔴 왜 고치지 않고 지우나. 이 절이 재던 것은 **강제가 텍스트 채널을 비웠을 때 두 번째 호출로
#    그것을 되찾는 동작**이다. T3 이 다섯 텍스트 `OutputField` 를 전부 지웠으므로 되찾을
#    채널이 없다 — 구제 함수가 아니라 **구제 대상**이 사라졌다. 고치려면 무엇을 재는지부터
#    새로 지어야 하고, 그건 시험이 아니라 설계다.
# 🔴 그 자리를 메우는 것: 붕괴가 **원인이던** 실패(빈 응답)는 이제 `decision_source="no_call"`
#    + `tool_lane_error` 로 이름이 붙는다 —
#    `test_macro_returns_tool_call.py::test_a_parse_failure_is_a_contract_violation_not_a_provider_outage`.
#    `expressible` 을 되찾는다는 이 절의 목적 절반은 그 값이 tool 인자가 되면서 **애초에 잃지
#    않는 것**으로 바뀌었다 — 위 (2)절이 그것을 잰다.
# ⚠️ `tool_choice` 를 되돌리는 길(`DSPY_TOOL_CHOICE=""`)은 그대로 남아 있다 — 위 (5)절.


# ---------------------------------------------------------------------------------------------
# (6b) 강제가 기본이고, 다중 호출은 원천 차단된다 (2026-08-29, T5)
# ---------------------------------------------------------------------------------------------
#
# 🔴 **`parallel_tool_calls` 를 `build_adapter()` 에 걸지 않는 이유 — 실측으로 반증된 계획서안.**
#    계획서 T5 Step 3 은 `dspy.ChatAdapter(use_native_function_calling=True,
#    parallel_tool_calls=False)` 를 지시한다. 그대로 하면 **이 파일의 계약 넷이 깨진다**(실측:
#    그 한 줄만 넣고 스위트를 돌려 4 failed 를 확인했다).
#
#    원인은 dspy 3.3.0 이 두 손잡이를 **프로바이더 경계에서 한 객체로 접기** 때문이다:
#      `core/types.py:538-542` — `if "tool_choice" in kwargs or "parallel_tool_calls" in kwargs:`
#         -> `LMToolChoice.from_value(kwargs.get("tool_choice", ...), parallel=...)`
#      `clients/openai_format.py:396-398` — `data = {"tool_choice": choice.mode}` 뒤에
#         `if choice.parallel is not None: data["parallel_tool_calls"] = choice.parallel`
#    ⟹ `parallel_tool_calls` 만 실으면 dspy 가 `tool_choice: "auto"` 를 **지어내서 함께 보낸다.**
#    실측 (`LMRequest.from_call` -> `to_openai_chat_request`):
#      tool_choice=required + parallel=False -> {"tool_choice":"required","parallel_tool_calls":false}
#      parallel=False 만                      -> {"tool_choice":"auto",    "parallel_tool_calls":false}  🔴
#      둘 다 없음                              -> 두 키 다 없음
#
#    귀결: 어댑터에 걸면 `DSPY_TOOL_CHOICE=""` 킬스위치가 **더 이상 2026-08-29 이전과 바이트
#    동일한 요청을 못 낸다** — 그 손잡이의 존재 이유 전체가 A/B 비교판을 로직 편집 없이 내는
#    것인데, 그 판이 `tool_choice: "auto"` 를 달고 나간다. 이 레포가 반복해 데인 자리가
#    "라벨 레인과 실행 레인이 조용히 다른 세계" 이고, 망가진 A/B 기준선이 정확히 그 모양이다.
#
# ⟹ 그래서 `_ask` 의 `config=` 로 **`tool_choice` 와 같은 블록에서 함께** 싣는다. dspy 가 둘을
#   한 객체로 접으니 우리도 한 자리에서 결정한다. 세 판이 전부 옳게 선다:
#     · 기본(`required`)   : 두 키가 다 나간다 — F11 차단
#     · 킬스위치(`""`)     : 두 키가 다 안 나간다 — 바이트 동일 유지
#     · tool 0개           : `macro()` 가 아예 안 묻는다 — 400 불가
# ⚠️ 어댑터에 도로 걸고 싶어지면 아래 `test_the_adapter_does_not_carry_the_parallel_flag` 가
#   막는다. 그 시험이 이 판정의 하중을 진다.


def test_the_default_is_required(monkeypatch):
    """🔴 F3. 강제 없이는 호출이 **0/3** 이었다(실측). 프롬프트에 호출 지시를 넣어도, 텍스트
    출력 필드를 전부 없애도, 행위자 프레이밍을 지시문 맨 앞에 놔도 전부 0/3 이었다.
    양성 대조(산술 과제)는 tool 3개에도 부른다 — 배선이 아니라 **과제의 성질**이다.

    그리고 강제가 예전에 텍스트 채널을 죽이던 인과는 T3 이 끊었다(텍스트 필드가 없다)."""
    monkeypatch.delenv(svc.TOOL_CHOICE_ENV, raising=False)
    assert svc.TOOL_CHOICE_DEFAULT == "required"
    assert svc.tool_choice(_req(tool_choice=None)) == "required"


def test_the_env_knob_can_still_turn_it_off(monkeypatch):
    """음성 대조: 되돌려 재는 길이 막히면 안 된다."""
    monkeypatch.setenv(svc.TOOL_CHOICE_ENV, "")
    assert svc.tool_choice(_req(tool_choice=None)) is None


def test_parallel_tool_calls_reaches_the_provider_request(monkeypatch):
    """🔴 F11. 예전에는 여럿 오면 `_first_tool_call` 이 첫 번째만 쓰고 나머지를 버렸다
    (`tool_calls_n` 에 기록은 했다). 프로바이더에게 애초에 하나만 내라고 말할 수 있다.

    **배선이 아니라 도달을 잰다** — `lm.seen[0]` 은 `to_openai_chat_request(request)` 의
    결과다(`adapters/base.py:249-254` 의 `_legacy_call_kwargs`)."""
    monkeypatch.delenv(svc.TOOL_CHOICE_ENV, raising=False)
    lm = _install(_answer(action=CALL), fc=True)
    out = svc.macro(_req(tool_choice=None))
    assert out["tools_offered"] > 0, "tool 이 0개면 이 시험은 다른 것을 잰다"
    assert lm.seen[0].get("tool_choice") == "required"
    assert lm.seen[0].get("parallel_tool_calls") is False, (
        "다중 호출이 원천 차단되지 않았다: %r" % (lm.seen[0].get("parallel_tool_calls"),))


def test_turning_the_knob_off_sends_neither_key(monkeypatch):
    """🔴 킬스위치의 OFF 방향. **이 시험이 위 (6b) 판정의 하중을 진다** — 계획서대로
    어댑터에 `parallel_tool_calls` 를 걸면 여기서 `tool_choice: "auto"` 가 잡힌다(실측)."""
    monkeypatch.setenv(svc.TOOL_CHOICE_ENV, "")
    lm = _install(_answer(action=CALL), fc=True)
    out = svc.macro(_req())
    assert lm.seen and "tool_choice" not in lm.seen[0], (
        "킬스위치를 걸었는데 tool_choice 가 나갔다: %r" % (lm.seen[0].get("tool_choice"),))
    assert "parallel_tool_calls" not in lm.seen[0], (
        "킬스위치를 걸었는데 parallel_tool_calls 가 나갔다 — dspy 가 그 키만으로 "
        "tool_choice='auto' 를 지어내므로 요청이 2026-08-29 이전과 바이트 동일하지 않다")
    assert out["tool_choice"] is None


def test_the_adapter_does_not_carry_the_parallel_flag():
    """🔴 위 (6b) 판정의 잠금장치. 어댑터에 걸면 그 값이 **모든** 요청에 실리고, dspy 가
    `tool_choice` 없이 그 키만 보면 `"auto"` 를 지어낸다 — 킬스위치가 죽는다.
    계획서 T5 의 `test_parallel_tool_calls_is_disabled_at_the_source` 를 이것으로 **대체했다.**"""
    assert svc.build_adapter().parallel_tool_calls is None, (
        "어댑터가 이 플래그를 들고 있다 — `_ask` 의 config= 로 tool_choice 와 함께 실을 것")


def test_the_two_knobs_are_decided_in_one_place():
    """🔴 dspy 가 둘을 한 객체(`LMToolChoice`)로 접으므로 우리도 한 자리에서 결정한다.
    `_ask` 안에서 `parallel_tool_calls` 가 `tool_choice` 와 **같은 조건**(`if choice:`) 아래
    있는지 소스로 못박는다 — 갈리면 킬스위치가 한쪽만 끄게 된다.

    ⚠️ 소스 검사다. 도달을 재는 것은 위 두 시험이고, 이것은 그 둘이 **왜** 함께 서는지를
    구조로 고정한다(하중은 여전히 위 둘이 진다)."""
    import ast as _ast
    src = open(os.path.join(HERE, "dspy_service.py"), encoding="utf-8").read()
    fn = next(n for n in _ast.walk(_ast.parse(src))
              if isinstance(n, _ast.FunctionDef) and n.name == "_ask")
    ifs = [n for n in _ast.walk(fn) if isinstance(n, _ast.If)]
    hit = [n for n in ifs
           if isinstance(n.test, _ast.Name) and n.test.id == "choice"
           and "parallel_tool_calls" in _ast.dump(n) and "tool_choice" in _ast.dump(n)]
    assert len(hit) == 1, (
        "`_ask` 안에서 두 키가 `if choice:` 하나 아래 함께 있지 않다 — dspy 는 둘을 한 객체로 "
        "접으므로 조건이 갈리면 킬스위치가 한쪽만 끈다")


# ---------------------------------------------------------------------------------------------
# (7) 오설정 값은 **일찍 시끄럽게** 죽는다 (2026-08-29, fix round)
# ---------------------------------------------------------------------------------------------
#
# 🔴 왜 생겼나 (실측). `tool_choice()` 는 문자열을 **검증 없이** 통과시켰다. 그런데 그 값이
#    닿는 타입은 닫힌 enum 이다 — `dspy/core/types.py:327` 의
#    `mode: Literal["auto", "required", "none"]` (+ `ConfigDict(extra="forbid")`), 그리고 그
#    Literal 은 dspy 가 좁힌 것이 아니라 OpenAI 스펙 그대로다
#    (`openai/types/chat/chat_completion_tool_choice_option_param.py:15`).
#    ⟹ `DSPY_TOOL_CHOICE=false` 같은 오설정은 `LMRequest.from_call` 안에서 pydantic
#      `ValidationError` 로 죽고, 그것은 `AdapterParseError` 가 **아니므로** `macro()` 의
#      포괄 `except` 로 떨어져 `error` 가 되고, `policy.jl:1301` 의 `policy_entry` 가
#      `err !== nothing` 을 보고 **레인을 통째로 `available=false` 로 버린다.**
#      즉 tool 하나가 아니라 **결정 전체가 매 사건 사라지고**, 아무도 그 말을 안 해 준다.
#
# 🔴 고칠 자리는 dspy 가 아니다. site-packages 편집은 재설치에 날아가고 이 레포 밖에서 돌리는
#    사람과 조용히 갈린다(`build_adapter()` docstring, spec §2-4). 그리고 Literal 을 늘려도
#    `openai_format.py:396` 이 그 값을 그대로 실어 보내 **프로바이더 400** 이 될 뿐이다 —
#    자리만 옮기고 왕복과 재시도 비용이 붙는다.
#
# 🔴 "끄는" 값은 이미 있다: `""`(키 자체를 안 보냄) 또는 `"none"`. 그래서 이 검증은 무엇도
#    막지 않는다 — 오타를 조용한 레인 사망 대신 **즉시 읽히는 에러**로 바꿀 뿐이다.
# 🔴 `"auto "` 는 여기 **없다** — 앞뒤 공백은 오설정이 아니라 흔한 사고이고 `.strip()` 이
#    정상 처리한다(아래 음성 대조가 그 사실을 못박는다). 대문자 `"REQUIRED"` 는 있다:
#    프로바이더가 대소문자를 가리므로 조용히 접으면 우리가 스펙보다 넓어진다.
_BAD = ("false", "False", "0", "true", "requiredd", "REQUIRED", "yes", "off")


def test_a_misconfigured_value_dies_loudly_instead_of_killing_the_lane():
    """🔴 이 절의 본체. 예전에는 이 값들이 그대로 통과해 dspy 안에서 죽었다."""
    for bad in _BAD:
        with pytest.raises(ValueError) as e:
            svc.tool_choice(_req(tool_choice=bad))
        # 사람이 읽고 바로 고칠 수 있어야 한다: 나쁜 값과 허용된 값이 둘 다 보인다.
        assert bad in str(e.value), "에러가 **어떤 값이** 틀렸는지 말해야 한다"
        assert "required" in str(e.value) and "none" in str(e.value), \
            "에러가 허용된 값을 말해야 한다"


def test_the_env_knob_is_validated_too(monkeypatch):
    """환경변수가 요청을 이기므로(우선순위), 검증도 같이 걸려야 한다 — 아니면 킬스위치가
    조용한 레인 사망의 **두 번째 입구**로 남는다."""
    monkeypatch.setenv(svc.TOOL_CHOICE_ENV, "false")
    with pytest.raises(ValueError):
        svc.tool_choice(_req(tool_choice="required"))


def test_every_legal_value_still_passes_untouched(monkeypatch):
    """🔴 음성 대조. 검증이 **끄는 길을 막지 않는다** — 이게 막히면 되돌리기가 불가능해진다."""
    monkeypatch.delenv(svc.TOOL_CHOICE_ENV, raising=False)
    assert svc.tool_choice(_req(tool_choice="required")) == "required"
    assert svc.tool_choice(_req(tool_choice="auto")) == "auto"
    assert svc.tool_choice(_req(tool_choice="none")) == "none"
    assert svc.tool_choice(_req(tool_choice="")) is None          # 키를 안 보냄
    assert svc.tool_choice(_req(tool_choice="  ")) is None        # 공백만도 같다
    assert svc.tool_choice(_req(tool_choice="auto ")) == "auto"   # 앞뒤 공백은 사고지 오설정이 아니다
    assert svc.tool_choice(_req(tool_choice=" required")) == "required"
    assert svc.tool_choice(None) == "required"   # 🔴 T5: 요청이 없으면 기본값이 선다
    monkeypatch.setenv(svc.TOOL_CHOICE_ENV, "")
    assert svc.tool_choice(_req(tool_choice="required")) is None  # 킬스위치 OFF 방향


def test_the_allowed_set_matches_what_the_provider_accepts():
    """🔴 이 시험이 감시하는 것은 우리 목록이 **dspy/OpenAI 의 것과 갈리지 않는다**는 것이다.
    한쪽만 늘리면 통과시킨 값이 프로바이더 400 이 된다."""
    from dspy.core.types import LMToolChoice
    for v in svc.TOOL_CHOICE_ALLOWED:
        LMToolChoice.from_value(v)      # 던지면 우리 목록이 dspy 보다 넓다


def test_a_misconfigured_env_knob_refuses_to_boot(monkeypatch):
    """🔴 환경변수가 틀리면 **매 사건이 500** 이 되고 이유는 서비스 로그에만 남는다.
    그 판은 아예 안 뜨는 것이 맞다 — 반나절 뒤 산출물이 전부 폴백이었음을 발견하는 것보다."""
    monkeypatch.setenv(svc.TOOL_CHOICE_ENV, "false")
    with pytest.raises(ValueError) as e:
        svc._startup()
    assert "false" in str(e.value)


def test_a_legal_env_knob_does_not_block_boot(monkeypatch):
    """음성 대조: 검증이 정상 부팅을 막지 않는다. 킬스위치 OFF(`""`) 도 포함한다."""
    for good in ("", "required", "auto", "none"):
        monkeypatch.setenv(svc.TOOL_CHOICE_ENV, good)
        svc._startup()          # 던지면 실패
