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
CALL = {"tool_calls": [{"name": "deliver_battery", "args": {"agent": RID}}]}


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
    assert lm.seen
    assert "tool_choice" not in lm.seen[0], (
        "tool 0개인 요청에 tool_choice 가 실렸다 — 프로바이더 400 이다: %r" % (lm.seen[0].get("tool_choice"),))
    assert out["tool_choice"] is None


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
    tool 호출과 독립이고, 이 시험이 그 독립성을 못박는다."""
    _install(_answer(expressible="False", action=CALL, macro="SwapBattery"))
    out = svc.macro(_req())
    assert out["expressible"] is False, "강제 호출이 expressible 을 도달 불가로 만들었다"
    assert out["tool_calls_n"] == 1, "호출은 실제로 있었다"


def test_expressible_false_still_fires_the_synthesis_lane():
    """합성 레인의 **유일한** 발화 조건이 `expressible == False` 다(spec §8-1). 강제 호출이
    그 발화를 삼키면 T2 가 영원히 안 돈다."""
    _install(_answer(expressible="False", action=CALL, macro="SwapBattery"))
    out = svc.macro(_req())
    assert out["synthesis"]["synthesis_event"] is True, (
        "강제 호출이 온 사건에서 합성 발화가 사라졌다 — R26 구현이 expressible 을 덮었다는 뜻")


# ---------------------------------------------------------------------------------------------
# (3) R26 — 강제된 호출은 집행의 근거가 아니다
# ---------------------------------------------------------------------------------------------

def test_r26_a_forced_call_with_expressible_false_yields_no_importable_agent():
    """🔴 컨트롤러 판정 R26. 줄리아 집행 경로(`tools/monitor/enact.jl` 의 `enact_target`)가
    읽는 것은 `tool_called` · `tool_args` 두 값이므로, 거절을 그 **값 안에서** 말해야 한다."""
    _install(_answer(expressible="False", action=CALL, macro="SwapBattery"))
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
    _install(_answer(expressible="False", action=CALL, macro="SwapBattery"))
    tl = svc.decide(_req())["dspy"]
    tc = tl["tool_called"]
    assert not (isinstance(tc, str) and tc), (
        "ground_tool_args 의 첫 줄을 통과해 버린다 — deferred 가 아니라 판정이 계속된다: %r" % (tc,))


def test_r26_does_not_fire_when_expressible_is_true():
    """억제는 `expressible == False` 에서만이다. True 인 사건의 호출은 그대로 집행으로 간다 —
    아니면 이 커밋이 tool 레인 전체를 조용히 죽인다."""
    _install(_answer(expressible="True", action=CALL, macro="SwapBattery"))
    out = svc.macro(_req())
    assert out["tool_called"] == "deliver_battery"
    assert out["tool_args"] == {"agent": RID}
    assert out["tool_called_forced"] is None
    assert out["tool_args_forced"] == {}


def test_r26_does_not_fire_when_expressible_was_not_measured():
    """`None` 은 "못 쟀다" 이지 "표현 못 한다" 가 아니다(spec §9-2). 억제는 False 에서만."""
    _install(_answer(expressible="maybe", action=CALL, macro="SwapBattery"))
    out = svc.macro(_req())
    if out["expressible"] is None and out["tool_lane_error"] is None:
        assert out["tool_called"] == "deliver_battery", "None 에서 억제가 돌았다"


def test_r26_keeps_the_agreement_measurable():
    """🔴 억제는 **집행 채널**만 비운다. `macro_tool_agree` 가 재는 것은 모델의 출력에 대한
    사실이므로 억제 전 호출로 재야 한다 — 아니면 R26 부분모집단 전체가 조용히 "못 쟀다" 로
    빠져 불일치율이 편향된다(강등 전 이름 `said` 를 쓰는 기존 논증과 같은 축)."""
    _install(_answer(expressible="False", action=CALL, macro="SwapBattery"))
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
    _install(_answer(expressible="False", action=CALL, macro="SwapBattery"))
    r26 = svc.macro(_req())
    _install(_answer(expressible="True", action={"tool_calls": []}, macro="NOOP"))
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
    _install(_answer(action=CALL, macro="SwapBattery"))
    forced = svc.macro(_req())
    assert forced["tool_choice"] == "required"
    assert forced["tools_offered"] > 0
    # 강제 판에서 "모델이 거절했다"(C8 ②)는 원리상 관측되지 않는다. 소비자 규칙이 그것을
    # 반영해야 한다는 사실을 여기 못박는다.
    assert not (forced["tool_called"] is None and forced["tool_calls_n"] == 0), (
        "강제 판에서 호출 0건이 나왔다 — 그 행을 '거절'로 세면 두 레짐이 섞인다")


def test_the_new_keys_stay_above_the_tool_lane_marker():
    """🔴 교차언어 결속을 안 깬다. `test/tool_lane_keys_survive.jl` (6)절은 `out["dspy"]` 의
    `# ---- tool 레인 …` 표식 **아래** 키 집합을 Julia 의 `TOOL_LANE_KEYS` **여덟**과 양방향
    등호로 대조한다. 이 커밋이 더한 세 키가 표식 아래로 내려가면 그 게이트가 정당하게
    빨개진다(줄리아는 이 태스크의 파일 범위 밖이다). `test_synthesize.py` 의 같은 이름
    시험과 짝이다."""
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
    # 🔴 2026-08-29 (T-C): `tool_choice` 와 `text_rescue` 는 이제 표식 **아래**다 — 줄리아의
    #    `TOOL_LANE_KEYS` 가 그 둘을 나르기 때문이고, 같은 커밋이 두 쪽을 함께 옮겼다.
    assert set(lane) == {"tool_called", "tool_args", "tool_calls_n", "tools_offered",
                         "expressible", "native_fc", "tool_lane_error", "macro_tool_agree",
                         "tool_choice", "text_rescue"}, lane
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


def test_the_default_is_no_longer_unconditionally_required():
    """🔴 §0 실측의 직접적 귀결. 요청도 환경변수도 없으면 **키를 안 보낸다.**

    변이 증명: `TOOL_CHOICE_DEFAULT` 를 `"required"` 로 되돌리면 이 세 단언이 빨개진다.
    """
    assert svc.TOOL_CHOICE_DEFAULT is None, "무조건 강제가 기본값으로 돌아왔다"
    lm = _install(_answer(action=CALL, macro="SwapBattery"), fc=True)
    out = svc.macro(_req(tool_choice=None))
    assert out["tools_offered"] > 0, "tool 이 0개면 이 시험은 400 방지 계약을 다시 재는 것이다"
    assert "tool_choice" not in lm.seen[0], (
        "요청도 환경변수도 강제를 안 했는데 키가 나갔다: %r" % (lm.seen[0].get("tool_choice"),))
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
    assert svc.tool_choice(None) is None
    assert svc.tool_choice(_req(tool_choice="required")) == "required"
    assert svc.tool_choice(_req(tool_choice="")) is None      # 빈 문자열은 키를 안 보낸다
    monkeypatch.setenv(svc.TOOL_CHOICE_ENV, "auto")
    assert svc.tool_choice(_req(tool_choice="required")) == "auto"
    monkeypatch.setenv(svc.TOOL_CHOICE_ENV, "")
    assert svc.tool_choice(_req(tool_choice="required")) is None


# ---------------------------------------------------------------------------------------------
# (6) 텍스트 채널 붕괴 구제 (T-C, 2026-08-29)
# ---------------------------------------------------------------------------------------------
#
# 🔴 무엇을 재는가. `tool_choice="required"` 판에서 프로바이더가 message content 를 비우면
#    텍스트 OutputField 전부가 빈 채로 파싱되고 **예외가 안 난다** — 그래서 spec §4-1 의
#    `AdapterParseError` 구제가 발화조차 안 한다. 이 절이 그 별도 감지와 병합을 잰다.
#
# ⚠️ **오프라인 한계 (반드시 읽을 것).** `DummyLM.supports_function_calling` 은 `False` 다
#    (`dspy/clients/base_lm.py:266-269`). 아래 시험들은 `fc=False` 판으로 도는데, 그 판에서
#    `action`(ToolCalls)은 프로바이더의 `tool_calls` 가 아니라 **텍스트로 파싱된다.** 즉 이
#    절이 재는 것은 **텍스트 폴백 경로**이고, "native FC 가 켜진 채로 붕괴가 났다" 는 주장을
#    여기서 **하지 않는다.** 이 절이 실제로 못박는 것은 붕괴 **감지**와 두 채널의 **병합
#    규칙**이며, 그 둘은 native FC 여부와 무관한 `macro()` 안의 순수 제어흐름이다.
#    native FC 배선 자체의 감시자는 `test_native_fc_wired.py` 이고 생략 불가다.

# 붕괴한 1차 응답: **`macro` 만 비었다** — 그리고 tool 호출은 왔다. 나머지 텍스트 필드까지 전부
# 비우면 어댑터 사슬이 파싱에 실패해 §4-1 경로로 새고(실측), 그러면 이 절이 다른 것을 재게 된다.
_COLLAPSED = {"reasoning": "", "expressible": "True", "action": CALL,
              "macro": "", "ranking": "", "margin": "0.0"}


def _text(**kw):
    """구제 호출(2차)이 낼 응답. tool 채널은 비어 있다 — 그 호출에는 tool 이 안 실린다."""
    base = {"reasoning": "battery is flat", "expressible": "True", "action": {"tool_calls": []},
            "macro": "SwapBattery", "ranking": "SwapBattery, NOOP, Replace", "margin": "0.5"}
    base.update(kw)
    return base


def test_a_collapsed_text_channel_is_rescued_and_both_channels_survive():
    """🔴 이 절의 본체. 결과 dict 이 **두 채널을 다** 갖는다: 행동은 1차에서, 텍스트는 2차에서.

    변이 증명: 병합에서 `text_src` 를 `pred` 로 되돌리면(= 구제 결과를 안 쓰면) 아래
    `reasoning`·`macro`·`expressible` 단언이 빨개진다.
    """
    _install(dict(_COLLAPSED), _text())
    out = svc.macro(_req())
    # ---- 2차에서 온 것 (텍스트 채널) ----
    assert out["chosen"] == "SwapBattery", "붕괴한 macro 가 안 살아났다"
    assert out["coerced"] is False, "구제했는데도 강등됐다 — 감지가 강등 뒤에 있다는 뜻"
    assert out["reasoning"] == "battery is flat"
    assert out["expressible"] is True, "🔴 이 태스크 목적의 절반이 사라졌다"
    assert out["ranking"][0] == "SwapBattery"
    assert out["margin"] == 0.5
    # ---- 1차에서 온 것 (행동 채널) ----
    assert out["tool_called"] == "deliver_battery"
    assert out["tool_args"] == {"agent": RID}
    assert out["tool_calls_n"] == 1
    # ---- 레인은 실패하지 않았다: 아무것도 안 던졌다 ----
    assert out["error"] is None, "구제가 결정을 죽였다 — 줄리아가 이 레인을 통째로 버린다"
    assert out["tool_lane_error"] is None, (
        "붕괴는 파싱 실패가 아니다 — 여기에 문자열이 들어가면 C8 ③ 버킷이 오염된다")
    assert out["text_rescue"] is True


def test_the_rescue_carries_the_first_attempts_stamps():
    """스탬프 셋은 **1차의 것**이다(`tools_offered` 주석의 "첫 시도를 기록한다" 규약)."""
    _install(dict(_COLLAPSED), _text())
    out = svc.macro(_req())
    assert out["tools_offered"] == 3, "구제 호출(tools=None)의 0 이 스탬프를 덮었다"
    assert out["tool_choice"] == "required", "구제 호출에는 이 키가 없다 — 1차의 값이어야 한다"
    assert out["native_fc"] is False, (
        "native_fc 를 구제 호출의 시그니처로 다시 쟀다 — 행동 채널은 여전히 1차의 것이다")


def test_the_rescue_keeps_macro_tool_agree_measurable():
    """🔴 이 순서를 택한 이유. `macro` 는 별도 OutputField 로 남고(spec §4-1) tool 은 1차에서
    오므로, 둘이 **서로 다른 채널**이라 일치 여부가 계속 잴 수 있는 양이다.
    macro 를 `tool_called` 에서 유도하는 안은 이 값을 정의상 `True` 로 만들어 측정을 죽인다."""
    _install(dict(_COLLAPSED), _text())
    agree = svc.macro(_req())["macro_tool_agree"]
    assert agree is True
    # 음성 대조: 같은 배선이 **불일치도** 낼 수 있어야 한다 — 아니면 위 True 는 상수다.
    _install(dict(_COLLAPSED), _text(macro="Replace", ranking="Replace, NOOP, SwapBattery"))
    out2 = svc.macro(_req())
    assert out2["chosen"] == "Replace"
    assert out2["macro_tool_agree"] is False, "일치 판정이 상수다 — 두 채널이 하나로 합쳐졌다"


def test_the_rescue_costs_one_more_predicting_call():
    """💰 강제된 사건은 leg 2개다. `_state["calls"]` 의 계약은 "leg 수" 가 아니라
    **"예측을 낸 호출 수"** 이므로(§4-1 블록의 같은 주석), 여기서 정확히 +2 다."""
    _install(dict(_COLLAPSED), _text())
    before = svc._state["calls"]
    out = svc.macro(_req())
    assert out["llm_calls"] - before == 2, (
        "구제 사건의 호출 수가 2 가 아니다: %d" % (out["llm_calls"] - before))


# ---- `text_rescue` 세 상태를 **전부 실제로 도달시킨다** --------------------------------------
# 🔴 도달 불가능한 상태는 거짓말이다. 셋 각각을 내는 입력이 아래에 하나씩 있다.

def test_text_rescue_is_none_when_nothing_collapsed():
    """강제했는데 텍스트가 멀쩡히 왔다 → 구제가 필요 없었다. `False` 가 **아니다**."""
    _install(_answer(action=CALL, macro="SwapBattery"))
    out = svc.macro(_req())
    assert out["text_rescue"] is None
    assert out["chosen"] == "SwapBattery"


def test_text_rescue_is_none_when_the_request_did_not_force():
    """강제 자체를 안 했으면 이 레인은 아예 안 돈다 — 빈 macro 가 와도 마찬가지다.
    (그 사건은 예전과 똑같이 `coerced` 로 NOOP 이 된다: 동작을 안 바꾼다.)"""
    _install(dict(_COLLAPSED))
    out = svc.macro(_req(tool_choice=None))
    assert out["tool_choice"] is None
    assert out["text_rescue"] is None, "강제를 안 했는데 구제가 돌았다 — 공짜 leg 을 태운다"
    assert out["coerced"] is True and out["chosen"] == "NOOP"


def test_text_rescue_is_false_when_the_text_channel_stays_empty():
    """붕괴했고 **구제도 되찾지 못했다.** 이것이 이 레인의 유일한 손실이고, `None` 과 같은 값이
    되면 손실률을 셀 수 없다(spec §9-2).

    ⚠️ `False` 는 두 사건을 덮는다(구제 호출이 던졌다 / 호출은 됐는데 또 비었다). 오늘 그 둘을
    가르는 키는 없고, 그 사실은 `dspy_service.macro` 의 발화 블록에 적혀 있다."""
    _install(dict(_COLLAPSED), _text(macro="", ranking=""))
    out = svc.macro(_req())
    assert out["text_rescue"] is False
    # 옛 동작과 같은 결과로 떨어진다 — 구제는 leg 만 더 쓰고 아무것도 못 건졌다.
    assert out["coerced"] is True and out["chosen"] == "NOOP"
    # 그래도 결정은 안 죽었고 행동 채널은 살아 있다.
    assert out["error"] is None
    assert out["tool_called"] == "deliver_battery"


def test_the_three_states_are_distinct_values():
    """셋이 **서로 다른 값**인지 한자리에서 못박는다. 두 개로 접는 편집이 여기서 빨개진다."""
    _install(_answer(action=CALL, macro="SwapBattery"))
    none_row = svc.macro(_req())["text_rescue"]
    _install(dict(_COLLAPSED), _text())
    true_row = svc.macro(_req())["text_rescue"]
    _install(dict(_COLLAPSED), _text(macro="", ranking=""))
    false_row = svc.macro(_req())["text_rescue"]
    assert none_row is None and true_row is True and false_row is False
    assert len({repr(none_row), repr(true_row), repr(false_row)}) == 3


# ---- R26 × 구제 상호작용 ----------------------------------------------------------------------

def test_a_rescued_expressible_false_fires_r26():
    """🔴 지금까지 **한 번도 못 울린 상호작용**. 강제 판에서는 `expressible` 이 언제나 `None`
    이었으므로(content 가 비었으니까) R26 의 발화 조건이 성립할 수 없었다. 구제가 그 필드를
    되찾는 순간 R26 은 **발화해야 한다** — 되찾은 `False` 는 "가진 어떤 tool 도 내가 본 것을
    표현 못 한다" 라는 모델의 진술이고, 그 사건의 강제된 호출은 집행의 근거가 아니다."""
    _install(dict(_COLLAPSED), _text(expressible="False"))
    out = svc.macro(_req())
    assert out["text_rescue"] is True
    assert out["expressible"] is False, "구제가 expressible 을 못 되찾았다 — R26 은 발화조차 못 한다"
    # 집행 채널은 비었다.
    assert out["tool_called"] is None, "R26 이 안 울렸다 — 강제된 호출이 집행으로 간다"
    assert out["tool_args"] == {}
    assert RID not in repr(out["tool_args"])
    # 기록은 남는다 · 거절(C8 ②)과 가르는 키도 그대로다.
    assert out["tool_called_forced"] == "deliver_battery"
    assert out["tool_args_forced"] == {"agent": RID}
    assert out["tool_calls_n"] == 1
    # 억제는 집행 채널만이다 — 일치 판정은 여전히 잴 수 있다.
    assert out["macro_tool_agree"] is True


def test_a_rescued_expressible_false_still_fires_the_synthesis_lane():
    """합성 레인(T2)의 **유일한** 방아쇠가 `expressible == False` 다(spec §8-1). 구제가
    그 필드를 되찾지 못하면 강제 판에서 T2 는 영원히 안 돈다 — 이 태스크의 목적 절반이 그것이다."""
    _install(dict(_COLLAPSED), _text(expressible="False"))
    out = svc.macro(_req())
    assert out["synthesis"]["synthesis_event"] is True
    # 음성 대조: 되찾은 값이 True 면 발화하지 않는다 = 위 True 가 상수가 아니다.
    _install(dict(_COLLAPSED), _text(expressible="True"))
    assert svc.macro(_req())["synthesis"]["synthesis_event"] is False


def test_decide_carries_the_rescue_flag():
    """라이브 레인은 `/decide` 로만 들어온다. 여기 없으면 `text_rescue` 는 실제로 도는 곳에서
    영원히 안 보인다(`tool_minted` 가 같은 이유로 여기 실린다)."""
    _install(dict(_COLLAPSED), _text())
    d = svc.decide(_req())["dspy"]
    assert d["text_rescue"] is True
    assert d["tool_choice"] == "required"
    assert d["chosen"] == "SwapBattery" and d["tool_called"] == "deliver_battery"
