"""tool 스키마가 **그 요청에 실재하는 id 만** 담는지 못박는다."""
import os
import re
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

# fix round 1 (H7): MACRO_TO_TOOL 이 레지스트리의 활성 어휘와 대조되는지 재려면
# wm4spacecraft_manufacturing/core 의 action_registry 가 필요하다. dspy_service.py:65-66 과
# 같은 이유로 insert(0,...) 이 아니라 append 다 -- 이 프로세스에도 결국 dspy 가 올라오므로
# wm4 경로를 최우선에 두면 동명 모듈을 가릴 위험이 있다.
_WM_CORE = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(HERE))),
                         "wm4spacecraft_manufacturing", "core")
if _WM_CORE not in sys.path:
    sys.path.append(_WM_CORE)

import tool_registry  # noqa: E402
from tool_registry import (build_tools, MACRO_TO_TOOL, _FUNCS, _needs_agent,  # noqa: E402
                            swap_body, deliver_battery, no_intervention, _NEVER)
import action_registry  # noqa: E402

AGENTS = [{"id": "ConstructionBots.BotID{ConstructionBots.DeliveryBot}(5)", "label": "Robot R5 / robot 5"},
          {"id": "ConstructionBots.BotID{ConstructionBots.DeliveryBot}(11)", "label": "Robot R11 / robot 11"}]

# fix round 1 (H1): 필요하다 -- 원래의 AGENTS 하나뿐이면 "enum == 실재 id" 라는 명제는
# "하드코딩된 enum" 과 "agents 인자를 실제로 읽는 코드" 를 구분하지 못한다(측정: agents 인자를
# 무시하고 AGENTS 의 두 id 를 리터럴로 박은 구현도 test_agent_enum_is_exactly_the_live_ids 를
# 통과한다 -- W4). 서로 다른 두 번째 요청으로 enum 이 **그 요청을 따라 바뀌는지** 를 잰다.
AGENTS_2 = [{"id": "ConstructionBots.BotID{ConstructionBots.DeliveryBot}(7)", "label": "Robot R7 / robot 7"}]


def _schema(tool):
    return tool.format_as_litellm_function_call()["function"]


def _by_name(tools):
    return {_schema(t)["name"]: _schema(t) for t in tools}


def test_agent_enum_is_exactly_the_live_ids():
    """🔴 모델에게 **보여주는** id 가 살아 있는 것뿐인지 재는 자리.

    🔴 2026-08-29 정정. 이 독스트링에 있던 *"환각 id 를 디코드 시점에 막는 자리. enum 밖은
    모델이 생성할 수 없다"* 는 **거짓이다.** 이 검사가 재는 것은 `enum` 의 **내용물**이지
    집행이 아니다. 실측: `format_as_litellm_function_call()` 의 `parameters` 키는
    `{properties, required, type}` — `strict` 도 `additionalProperties` 도 없고, dspy 3.3.0 의
    `dspy.Tool` 에는 `strict` 필드 자체가 없다. `tool_choice` 도 안 보낸다. 비-strict `enum`
    에 프로바이더가 문법 제약을 거는지는 **안 잰 프로바이더 동작**이다(라이브 호출이 있어야
    판정된다). 그러니 이 검사의 초록을 "환각 id 가 불가능하다" 로 읽지 말 것."""
    got = _by_name(build_tools(AGENTS, ["NOOP", "Replace", "SwapBattery"]))
    for name in ("swap_body", "deliver_battery"):
        enum = got[name]["parameters"]["properties"]["agent"]["enum"]
        assert enum == ["ConstructionBots.BotID{ConstructionBots.DeliveryBot}(5)", "ConstructionBots.BotID{ConstructionBots.DeliveryBot}(11)"]


def test_agent_enum_actually_tracks_this_requests_agents_not_a_hardcoded_list():
    """fix round 1 (H1): 위 테스트 하나만으로는 "실재 id 를 반영" 과 "AGENTS 리터럴을
    하드코딩" 을 구분할 수 없다(측정: `agents` 인자를 통째로 무시하고 AGENTS 의 두 id 를
    상수로 박은 구현이 이 파일의 원래 7 개 테스트를 전부 통과했다 -- W4). 서로 다른 두 요청을
    넣어 enum 이 **그 요청을 따라 바뀌는지** 를 잰다: 한쪽에만 있는 id 는 그쪽 enum 에만
    있어야 한다."""
    got1 = _by_name(build_tools(AGENTS, ["Replace"]))
    got2 = _by_name(build_tools(AGENTS_2, ["Replace"]))
    enum1 = got1["swap_body"]["parameters"]["properties"]["agent"]["enum"]
    enum2 = got2["swap_body"]["parameters"]["properties"]["agent"]["enum"]
    assert enum1 != enum2
    assert AGENTS[0]["id"] in enum1 and AGENTS[0]["id"] not in enum2
    assert AGENTS_2[0]["id"] in enum2 and AGENTS_2[0]["id"] not in enum1


def test_agent_param_keeps_its_description():
    """⚠️ dspy 는 `args` 를 주면 `arg_desc` 를 무시한다 — description 이 조용히 사라진다."""
    got = _by_name(build_tools(AGENTS, ["NOOP", "Replace", "SwapBattery"]))
    d = got["swap_body"]["parameters"]["properties"]["agent"]["description"]
    assert "exact robot id" in d


def test_mechanism_lands_in_the_tool_description():
    """모델이 읽는 tool 설명은 오직 여기뿐이다 — native FC 는 이 필드를 프롬프트에서 지운다."""
    got = _by_name(build_tools(AGENTS, ["NOOP", "Replace", "SwapBattery"]))
    assert "depot" in got["swap_body"]["description"].lower()
    assert "schedule graph" in got["swap_body"]["description"].lower()


def test_deliver_battery_description_carries_its_own_mechanism():
    """fix round 1 (H4): swap_body 만 내용을 검사하면 deliver_battery 의 docstring을
    비워도(모델이 읽는 유일한 설명이 사라져도) 8/8 이 green 이었다. 여기서 독립적으로 잰다."""
    got = _by_name(build_tools(AGENTS, ["SwapBattery"]))
    d = got["deliver_battery"]["description"].lower()
    assert "courier" in d
    assert "not edited" in d


def test_no_intervention_description_carries_its_own_mechanism():
    """fix round 1 (H4): no_intervention 도 마찬가지로 내용 검사가 없었다."""
    got = _by_name(build_tools(AGENTS, ["NOOP"]))
    d = got["no_intervention"]["description"].lower()
    assert "no graph is edited" in d


def _leak_windows(text, window=20):
    """`text` 에서 길이 `window` 인 모든 연속 부분문자열. `text` 가 window 보다 짧으면
    `text` 전체 하나만. wm4spacecraft_manufacturing/core/test_registry_doc_split.py 의
    `_leak_windows` 와 같은 모양(fix round 2, K2) -- 그 파일이 이번 주 자기 round 3(S1)에서
    같은 버그를 겪고 이 방식으로 고쳤다."""
    text = text.strip()
    if not text:
        return []
    if len(text) <= window:
        return [text]
    return [text[i:i + window] for i in range(len(text) - window + 1)]


def test_no_applicability_verdict_leaks_into_descriptions():
    """spec §6: 기전은 말하고 정답 조건은 말하지 않는다.

    fix round 1 (H3): 이 게이트는 `build_tools` 가 `[]` 를 내도(순회 0 회) green 이었다
    -- 이 레포가 Task 3 에서 네 번 만든 바로 그 공허통과 모양이다. 순회 전에 개수를 못박아
    구조적으로 막는다.
    """
    tools = _by_name(build_tools(AGENTS, ["NOOP", "Replace", "SwapBattery"]))
    assert len(tools) == 3, "이 호출은 3 개 tool 을 내야 정상이다 -- 0 이면 아래 for 는 순회 없이 통과한다"
    for s in tools.values():
        assert "best when" not in s["description"].lower()
        assert "best on" not in s["description"].lower()


def test_no_applicability_verdict_leaks_via_a_sliding_window_over_the_live_registry():
    """fix round 2 (K2, Important): 위 테스트의 `"best when"`/`"best on"` 블록리스트는
    구조가 아니라 우연히 걸린다 -- action_registry.json 의 `when_to_use` 세 개 중 둘
    (NOOP, Replace)만 그 두 문구로 **시작**하고, SwapBattery 는 "Cheaper than Replace
    when the body is sound and only charge is missing." 로 시작해서 안 걸린다. 측정: 그
    문장을 `deliver_battery` 의 docstring 에 그대로 붙여넣어도(모델이 읽는 유일한 설명에
    정답 조건이 그대로 실려도) 위 블록리스트 테스트를 포함해 fix round 1 까지의 13 개
    테스트가 전부 green 이었다. SwapBattery 는 이 tool lane 전체가 존재하는 이유인
    바로 그 팔이다(canonical 이 1533 번 중 0 번 고른다).

    wm4spacecraft_manufacturing/core/test_registry_doc_split.py 가 이 레포에서 이미 같은
    모양의 버그를 이번 주 자기 round 3(S1)/round 5(V1)에서 겪었다 -- 블록리스트와 접두
    검사 둘 다 부분적으로만 잡았고, 최종 해법은 `when_to_use` 전체를 20자 슬라이딩
    윈도우로 쪼개 그 어떤 연속 20자 구간도 모델이 읽는 텍스트에 있으면 안 된다는 것이었다.
    같은 방식을 여기 쓴다: **살아 있는** action_registry(테스트가 이미 H7 에서 읽고
    있다)의 `when_to_use` 세 개 전부를, 세 tool description 을 합친 텍스트와 대조한다.
    """
    tools = _by_name(build_tools(AGENTS, ["NOOP", "Replace", "SwapBattery"]))
    assert len(tools) == 3, "이 호출은 3 개 tool 을 내야 정상이다 -- 0 이면 검사가 공허해진다"
    rendered = "\n".join(s["description"].lower() for s in tools.values())
    executed = 0
    for mid, m in action_registry.REGISTRY.items():
        for chunk in _leak_windows(m["when_to_use"].lower()):
            executed += 1
            assert chunk not in rendered, (
                "macro %s(%s) 의 when_to_use 에서 %d자 연속 구간이 tool description 으로 "
                "샜다: %r -- 정답 조건이 모델이 읽는 유일한 설명에 실렸다."
                % (mid, m["name"], len(chunk), chunk)
            )
    assert executed > 0, (
        "when_to_use 윈도우가 하나도 안 생겼다 -- 레지스트리의 when_to_use 가 전부 비어서 "
        "위 루프가 공허하게 통과했을 수 있다(register round 1 의 H3 와 같은 모양)."
    )


def test_illegal_macros_are_not_offered_as_tools():
    """valid 메뉴 밖의 팔은 tool 로 나오면 안 된다 — 메뉴 계약이 tool 층에서도 성립해야 한다."""
    got = _by_name(build_tools(AGENTS, ["NOOP", "SwapBattery"]))
    assert "swap_body" not in got
    assert "deliver_battery" in got
    assert "no_intervention" in got


def test_empty_agent_list_drops_agent_tools_rather_than_emitting_an_empty_enum():
    """🔴 빈 enum 은 provider 가 거부하거나 아무 문자열이나 통과시킨다 — 둘 다 나쁘다.
    로봇을 지목할 수 없으면 그 tool 을 **아예 안 낸다**."""
    got = _by_name(build_tools([], ["NOOP", "Replace", "SwapBattery"]))
    assert "swap_body" not in got
    assert "deliver_battery" not in got
    assert "no_intervention" in got


def test_no_intervention_takes_a_reason():
    got = _by_name(build_tools(AGENTS, ["NOOP"]))
    assert "reason" in got["no_intervention"]["parameters"]["properties"]


def test_a_menu_with_no_expressible_tool_yields_an_empty_list_not_a_stub():
    """🔴 빈 tools 를 native FC 에 넘기면 provider 가 400 을 낸다. 여기서 [] 를 내는 것은
    정상이고, 그 [] 를 **호출자가** 보고 tool 레인을 꺼야 한다(Task 6). 가짜 tool 을
    끼워 넣어 메뉴 계약을 깨지 않는다."""
    assert build_tools([], ["Replace"]) == []


def test_tool_bodies_never_actually_run():
    """fix round 1 (H5): 계약 ①("함수 본체는 절대 호출되지 않는다 … raise 로 막아 둔다")이
    파일 docstring 에만 있고 어떤 테스트도 그 raise 를 재지 않았다. 세 raise 를 각각 전부
    `return` 으로 바꿔도(=계약 위반) 이 테스트 없이는 8/8 이 green 이었다. 여기서 재는 것은
    "Julia 가 이걸 두 번 집행하지 않는다" 는 안전장치 자체다.

    fix round 2 (K4): `pytest.raises(AssertionError)` 에 `match=` 가 없었다 -- 아무 관계
    없는 이유로 `AssertionError` 를 던지는 본체도 이 테스트를 통과시켰을 것이다(예: 인자
    타입 체크를 넣었다가 실수로 raise 문 자체를 지우면서 다른 assert 만 남기는 편집).
    `_NEVER` 문자열이 바로 여기 있으므로 이걸로 잡는다."""
    with pytest.raises(AssertionError, match=re.escape(_NEVER)):
        swap_body("some-agent-id")
    with pytest.raises(AssertionError, match=re.escape(_NEVER)):
        deliver_battery("some-agent-id")
    with pytest.raises(AssertionError, match=re.escape(_NEVER)):
        no_intervention("some reason")


def test_macro_to_tool_keys_match_the_active_vocabulary():
    """fix round 1 (H7): `MACRO_TO_TOOL` 은 어휘(action_registry.json)의 리터럴 복사본이다.
    넷째 팔을 등록에 추가해도 `MACRO_TO_TOOL.get(macro)` 는 그냥 `None` 을 돌려주고 그 팔이
    tool 메뉴에서 조용히 빠진다 -- 이 레포가 `SwapBattery` 로 이미 겪은 0/6 → 6/6 실패와
    같은 모양이다. 여기서 두 표를 직접 대조한다: 하나라도 다르면 여기서 죽는다."""
    active = {action_registry.MACRO_NAME[i] for i in action_registry.ACTIVE_MACROS}
    assert set(MACRO_TO_TOOL) == active, (
        "MACRO_TO_TOOL %r 이 action_registry 의 활성 어휘 %r 와 다르다 -- 레지스트리가 바뀌면 "
        "이 표도 같이 고칠 것. 조용한 드리프트를 여기서 막는다." % (set(MACRO_TO_TOOL), active))


_MEASURED_RE = re.compile(
    r"Measured:\s*\+([0-9.]+)\s*sim s per event,\s*energy/closed\s*\+([0-9]+)%")


def test_measured_costs_in_the_docstrings_still_match_the_live_registry():
    """fix round 3 (K5): H7 은 `MACRO_TO_TOOL` 의 **이름**만 레지스트리와 대조한다 --
    각 tool 의 docstring 이 담고 있는 측정치(`+13.3`/`+228%`, `+4.1`/`+25%`)는 손으로
    옮겨 적은 두 번째 사본이고, 어느 쪽도 대조되지 않는다. `action_registry.json` 의
    mechanism 산문을 고치면(Task 3 이 이번 주에 그렇게 했다) 모델이 읽는 숫자가 조용히
    낡아도 아무것도 안 울린다.

    이 파일은 이미 `action_registry` 를 import 하고 있으므로(H7) 진실원은 손에 있다.
    렌더링으로 통째로 고치는 대신(그 트레이드오프는 이 라운드의 report 에 판단으로
    적었다 -- action_registry 를 tool_registry.py 의 import 경로에 끌어들이는 것은 K1 이
    막 정리한 바로 그 영역에 두 번째 모듈을 심는 것과 같은 모양이라 하지 않았다) **숫자만**
    앵커로 대조한다. 숫자를 고른 이유: 산문은 tool 설명으로 다시 쓰면서 의도적으로
    갈렸다(예: swap_body 는 "The replaced body does not come back." 을 추가로 들고
    있고 mechanism 의 "(replace_robot.jl)" 언급은 뺐다) -- 문장 전체를 대조하면 이
    합법적인 재서술 자체가 항상 걸린다. 숫자는 재서술돼도 값이 같아야 하는 유일한
    부분이고, 실제로 드리프트했을 때 독자가 신뢰해서 쓰는 바로 그 값이다.

    NOOP 은 cost 가 0 이고 mechanism 에 "Measured: ..." 절 자체가 없다 -- 앵커가 없으므로
    건너뛴다(레지스트리를 실측: `_MEASURED_RE` 가 NOOP 에는 안 걸리고 Replace·SwapBattery
    둘에만 걸린다). 그래서 `executed` 는 3 이 아니라 2 를 기대한다 -- `test_registry_doc_split.py`
    가 세 번 겪은 공허통과를 막는 것과 같은 이유로, 정확한 개수를 못박아 "필터가 전부를
    걸러서 루프가 안 돈" 경우와 "정상적으로 하나(NOOP)를 건너뛴" 경우를 구분한다."""
    tools = _by_name(build_tools(AGENTS, ["NOOP", "Replace", "SwapBattery"]))
    assert len(tools) == 3, "이 호출은 3 개 tool 을 내야 정상이다"
    executed = 0
    for mid, m in action_registry.REGISTRY.items():
        match = _MEASURED_RE.search(m["mechanism"])
        if match is None:
            continue
        executed += 1
        tool_name = MACRO_TO_TOOL[m["name"]]
        desc = tools[tool_name]["description"]
        seconds, pct = match.group(1), match.group(2)
        assert ("+%s" % seconds) in desc, (
            "macro %s(%s) 의 레지스트리 mechanism 은 +%s sim s/event 를 측정치로 든다. "
            "tool %r 의 description 에는 그 숫자가 없다 -- mechanism 이 편집되면서 이 "
            "docstring 의 사본이 낡았을 수 있다." % (mid, m["name"], seconds, tool_name))
        assert ("+%s%%" % pct) in desc, (
            "macro %s(%s) 의 레지스트리 mechanism 은 energy/closed +%s%% 를 측정치로 든다. "
            "tool %r 의 description 에는 그 숫자가 없다 -- mechanism 이 편집되면서 이 "
            "docstring 의 사본이 낡았을 수 있다." % (mid, m["name"], pct, tool_name))
    assert executed == 2, (
        "이 라운드에서 실측한 값(2, Replace 와 SwapBattery 만 'Measured: ...' 절을 가진다)과 "
        "다르다(%d) -- 레지스트리에 측정치가 있는 macro 가 늘거나 줄었으면 이 테스트와 그 "
        "실측을 같이 갱신할 것. 0 이면 이 검사 전체가 공허하게 통과한다는 뜻이니 그 경우는 "
        "특히 조용히 넘기지 말 것." % executed)


def test_tool_registry_import_does_not_poison_a_later_sklearn_import():
    """fix round 2 (K1, Important): fix round 1 의 numpy/sklearn 가드(`tool_registry.py`
    상단의 `import numpy, sklearn.ensemble`)는 주석 하나로만 지켜지고 있었다. 측정: 그
    가드를 지워도 `pytest test_tool_registry.py` 단독(13 passed), `pytest
    src/respec/llm_service/`(47 passed) 둘 다 green 이다 -- 이 디렉터리의 알파벳순 수집이
    `test_macro_request_agents.py`(dspy_service 를 먼저 로드) 를 먼저 만나서 우연히 가려진다.

    실제 위험 시나리오(Task 6 이후 `dspy_service.py` 가 `from tool_registry import ...`
    를 하는 시점, 또는 이 파일이 알파벳순보다 먼저 수집되는 임의의 pytest 호출)는 **이
    프로세스 안에서 tool_registry 가 먼저 import 되고 그 뒤 누군가 sklearn.ensemble 을
    import 하는** 것이다. 그 순서를 이 테스트 프로세스 자체를 오염시키지 않고 재려면
    별도 서브프로세스가 필요하다 -- 이 파일이 이미 (H7 을 통해) `action_registry` 를,
    (fix round 1 을 통해) `dspy` 를 이 인터프리터에 로드해 놓았으므로, 여기서 직접
    `import sklearn.ensemble` 을 하면 이미 늦었을 수도 있고 다른 테스트의 import 순서에
    따라 우연히 안전할 수도 있다 -- 정확히 이 가드가 보호하려는 비결정성이다."""
    code = (
        "import sys\n"
        "sys.path.insert(0, %r)\n"
        "import tool_registry\n"
        "import sklearn.ensemble\n"
        "print('OK')\n"
    ) % HERE
    r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
    assert r.returncode == 0 and "OK" in r.stdout, (
        "새 서브프로세스에서 tool_registry 를 먼저 import 한 뒤 sklearn.ensemble 을 "
        "import 하면 죽었다 -- numpy/sklearn-before-dspy 가드(fix round 1, H2)가 지워졌거나 "
        "무력화됐다.\nreturncode=%r\nstdout=%r\nstderr=%r" % (r.returncode, r.stdout, r.stderr))


def test_needs_agent_is_derived_from_function_signatures_not_a_hand_maintained_set():
    """fix round 2 (K3, Minor): 예전 `_NEEDS_AGENT` 는 손으로 든 집합이었다. 측정: 넷째
    agent-taking 팔을 `MACRO_TO_TOOL`·`_FUNCS` 에 추가하면서 그 집합만 깜빡해도(측정
    당시) 13 개 테스트가 전부 green 이었다 -- `build_tools` 가 조용히 `reason: string`
    분기로 빠져 agent enum 이 안 나갔다(`_FUNCS` 를 깜빡하면 `KeyError` 로 시끄럽게
    죽는 것과 대조적으로, 에러가 없다). 고친 코드는 `_needs_agent(name)` 이 `_FUNCS[name]`
    의 실제 파라미터 이름에서 유도한다 -- 손으로 든 표가 아예 없으므로 "깜빡함" 자체가
    불가능해졌다. monkeypatch 로 새 agent-taking 함수 하나를 주입해(원 저장소는 건드리지
    않고) 그 유도가 실제로 작동하는지 잰다: `_FUNCS` 에만 추가해도(다른 어떤 표도 손대지
    않고) `_needs_agent` 가 즉시 True 를 본다."""
    def relocate(agent: str):
        raise AssertionError(_NEVER)

    assert "relocate" not in _FUNCS, "이 이름이 이미 _FUNCS 에 있다 -- 테스트 준비가 잘못됐다"
    _FUNCS["relocate"] = relocate
    try:
        assert _needs_agent("relocate") is True, (
            "_FUNCS 에 agent 파라미터를 가진 함수를 추가했는데 _needs_agent 가 못 봤다 -- "
            "유도가 실제로 시그니처를 읽지 않고 있다."
        )
    finally:
        del _FUNCS["relocate"]
    assert _needs_agent("no_intervention") is False, (
        "reason 만 받는 함수를 agent-taking 으로 오판했다.")


# ---- 2026-08-29 (단일 채널): reg 별칭 -- 위 test_tool_registry.py 는 tool_registry 를 그
# 이름 그대로 import 한다(line 22). 아래 새 시험들만 `reg.` 접두를 쓰므로 별칭을 하나 둔다.
reg = tool_registry

# ---- 2026-08-29 (단일 채널): 결정 성분이 tool 인자로 들어간다 --------------------------------
_COMMON = ("macro", "reasoning", "expressible", "ranking")


def test_every_tool_carries_the_four_common_args():
    """🔴 텍스트 OutputField 가 사라지므로 이 넷이 결정의 **유일한** 운반체다."""
    tools = reg.build_tools([{"id": "r1", "label": "a"}], ["Replace", "SwapBattery", "NOOP"])
    assert len(tools) == 3
    for t in tools:
        props = t.format_as_litellm_function_call()["function"]["parameters"]["properties"]
        for name in _COMMON:
            assert name in props, "%s 에 %s 가 없다" % (t.name, name)


def test_the_unique_args_are_untouched():
    """음성 대조: 공통 인자를 더하는 것이 접지용 고유 인자를 밀어내면 안 된다."""
    tools = {t.name: t for t in
             reg.build_tools([{"id": "r1", "label": "a"}], ["Replace", "SwapBattery", "NOOP"])}
    for name in ("swap_body", "deliver_battery"):
        p = tools[name].format_as_litellm_function_call()["function"]["parameters"]["properties"]
        assert p["agent"]["enum"] == ["r1"], "agent enum 이 접지의 재료다"
    p = tools["no_intervention"].format_as_litellm_function_call()["function"]["parameters"]["properties"]
    assert p["reason"]["type"] == "string"


def test_macro_arg_is_an_enum_of_this_events_emitted_macros():
    """어휘 밖 macro 를 낼 여지를 스키마에서 줄인다(강제는 아니다 -- F10).

    fix round 2 (N3): 이 시험은 원래 "legal_macros" 라는 이름이었지만 실제로 재는 건 **emitted**
    (실제로 tool 로 나간) 매크로다 -- legal 메뉴 ⊇ callable 메뉴이고 그 둘은 다른 것이다.
    이 요청(`r1` 이 있어 agent-taking 팔도 나간다)에서는 둘이 같아서 이름이 안 갈렸을 뿐이다.
    `ranking` 이 legal 메뉴(스코어링 대상 전체)를 나르고, 이 `macro` enum 은 callable 메뉴
    (emitted)를 나른다 -- `COMMON_ARGS` 의 `emitted` 파라미터가 그 계약을 이름으로 말한다.

    fix round 1 (finding 6): `tools[0]` 하나만 보면 불변이 나머지 tool 에서 깨져도 못 잡는다.
    나오는 tool 전부를 돈다."""
    tools = reg.build_tools([{"id": "r1", "label": "a"}], ["Replace", "NOOP"])
    for t in tools:
        p = t.format_as_litellm_function_call()["function"]["parameters"]["properties"]
        assert p["macro"]["enum"] == ["Replace", "NOOP"]


def test_macro_enum_equals_the_tools_actually_emitted():
    """🔴 fix round 2 (N1): "이 매크로가 tool 로 나가는가" 를 결정하는 곳이 두 곳이면 몰래
    갈릴 수 있다 -- 리뷰가 실측: 실제 tool 구성 루프에만 스킵 규칙 하나를 얹어도(예:
    `if macro == "SwapBattery" and len(agent_ids) >= 3: continue`) 25개 시험이 전부 green
    인 채로, 3-agent 요청에서 `deliver_battery` 는 안 나가는데 남은 tool 들의 `macro` enum
    에는 여전히 `"SwapBattery"` 가 남았다 -- finding 2 의 결함이 소리 없이 되살아난 것이다.

    이 시험은 오늘의 어휘(Replace/SwapBattery/NOOP)나 특정 fixture 값에 기대지 않는다 --
    구조적 불변만 잰다: `build_tools` 가 실제로 낸 tool 목록에서 `TOOL_TO_MACRO` 로 유도한
    매크로 리스트가, 그 tool 들이 들고 있는 `macro` enum 과 **항상** 같아야 한다. "emit 여부를
    결정하는 곳이 한 곳뿐" 이라는 계약이 깨지면 이 등식이 깨진다."""
    cases = [
        ([{"id": "r1", "label": "a"}], ["Replace", "SwapBattery", "NOOP"]),
        ([], ["Replace", "NOOP"]),
        ([{"id": "r1", "label": "a"}, {"id": "r2", "label": "b"}, {"id": "r3", "label": "c"}],
         ["Replace", "SwapBattery", "NOOP"]),
    ]
    for agents, valid in cases:
        tools = reg.build_tools(agents, valid)
        expected = [reg.TOOL_TO_MACRO[t.name] for t in tools]
        for t in tools:
            p = t.format_as_litellm_function_call()["function"]["parameters"]["properties"]
            assert p["macro"]["enum"] == expected, (
                "%r 의 macro enum %r 이 실제로 나간 tool 에서 유도한 매크로 %r 과 다르다 -- "
                "emit 여부를 결정하는 곳이 두 군데로 갈렸다" % (t.name, p["macro"]["enum"], expected))


def test_macro_enum_excludes_macros_that_have_no_emitted_tool():
    """🔴 fix round 1 (finding 2): agents 가 비면 agent-taking 매크로(`Replace`)는 tool 자체가
    안 나간다(`build_tools` 의 기존 설계, agent id 가 없으면 그 tool 을 아예 안 낸다). 그런데
    `macro` enum 이 원래의 `valid` 를 그대로 받으면 안 나간 매크로 이름이 남아, 모델이
    존재하지 않는 tool 을 legal 하다고 답할 길이 생긴다 -- 그 답은 Task 4 에서
    `macro_tool_agree=False` 로 기록되는 불일치인데, 원인은 모델이 아니라 스키마다.
    `no_intervention` 하나만 나가는 요청에서는 그 tool 의 `macro` enum 도 `["NOOP"]`
    하나여야 한다."""
    tools = reg.build_tools([], ["Replace", "NOOP"])
    assert len(tools) == 1 and tools[0].name == "no_intervention"
    p = tools[0].format_as_litellm_function_call()["function"]["parameters"]["properties"]
    assert p["macro"]["enum"] == ["NOOP"], \
        "안 나간 매크로(Replace)가 여전히 enum 에 남아있다 -- 스키마가 스스로 불일치를 만든다"


def test_all_args_are_required():
    """🔴 `expressible` 이 빠지면 T2 합성의 방아쇠가 사라진다 -- 이 시험의 핵심 주장은 첫
    assert: 네 공통 인자가 전부 `required` 에 있다는 것이다.

    fix round 1 (finding 4): 원래 이 시험은 `set(required) == set(properties)` 하나만
    쟀는데, 이는 더 약한 별개의 불변이다 -- `expressible` 을 `COMMON_ARGS` 에서 통째로
    지워도 이 등식은 (존재하는 인자들에 대해) 공허하게 계속 참이라 green 으로 남는다
    (측정: dspy 는 `required = [k for k in args if "default" not in args[k]]` 로 계산한다
    -- `dspy/adapters/types/tool.py:157` -- 그러니 이 등식이 지키는 것은 "인자 집합이
    `expressible` 을 포함하는가" 가 아니라 "어떤 인자가 `default` 를 얻어 조용히 optional
    이 되지 않았는가" 뿐이다). 그래서 두 번째 assert 로 그 원래 불변을 남기고, 첫 assert 로
    docstring 이 실제로 주장하는 것을 잰다."""
    tools = reg.build_tools([{"id": "r1", "label": "a"}], ["Replace", "SwapBattery", "NOOP"])
    for t in tools:
        params = t.format_as_litellm_function_call()["function"]["parameters"]
        for name in _COMMON:
            assert name in params["required"], "%s 에 %s 가 required 에 없다" % (t.name, name)
        assert set(params["required"]) == set(params["properties"]), \
            "인자가 `default` 를 얻어 조용히 optional 이 됐다"


def test_expressible_description_separates_the_two_events():
    """🔴 실측(2026-08-29): 옛 문구로는 어휘 밖 사건에서 1/3 만 False 였다. 나머지 둘은
    reasoning 에서 "근본 원인을 못 고친다" 고 말하면서 True 를 냈다 -- 모델이 "표현 불가" 와
    "개입 불필요" 를 혼동한다. 개정 문구가 그 둘을 **명시적으로** 가르고, 그때 3/3 이 됐다.
    이 시험은 그 두 문장이 사라지지 않게 지킨다."""
    d = reg.COMMON_ARGS(["Replace", "NOOP"])["expressible"]["description"]
    assert "unnecessary" in d and "outside the menu" in d, \
        "두 사건을 가르는 문장이 빠지면 발화율이 1/3 로 돌아간다"


def test_reasoning_description_asks_for_the_gap_in_words():
    """`margin` 스칼라를 없앤 대가로 이 문장이 그 자리를 나른다(spec §3-3)."""
    d = reg.COMMON_ARGS(["Replace", "NOOP"])["reasoning"]["description"]
    assert "runner-up" in d and "not as a number" in d


def test_tool_to_macro_is_the_exact_inverse():
    """🔴 두 표가 갈리면 `chosen` 이 조용히 틀린다 -- 이 설계에서 `chosen` 은 tool 이름에서만
    나오므로 이 등식이 곧 결정의 정확성이다."""
    assert reg.TOOL_TO_MACRO == {v: k for k, v in reg.MACRO_TO_TOOL.items()}
    assert len(reg.TOOL_TO_MACRO) == len(reg.MACRO_TO_TOOL), "역표가 값 충돌로 줄면 안 된다"


def test_grounding_accepts_a_well_formed_call():
    """음성 대조 먼저 — 검증이 정상 호출을 막으면 레인이 통째로 죽는다."""
    ok = reg.check_tool_args(
        "swap_body",
        {"agent": "r1", "macro": "Replace", "reasoning": "x", "expressible": True,
         "ranking": "Replace, NOOP"},
        ["Replace", "NOOP"], ["r1"])
    assert ok is None


def test_grounding_rejects_an_agent_outside_the_enum():
    """🔴 F10. dspy.Tool 에 strict 가 없으므로 enum 은 권고다 — 실제로 뚫릴 수 있다.

    🔴 fix round 2 (Cheap 1): 사유의 **머리**를 고정한다 -- 느슨한 `"agent" in why` 는 다른
    가드가 대신 걸려도(예: `agent_ids_not_a_sequence`) 통과했을 것이다."""
    why = reg.check_tool_args(
        "swap_body",
        {"agent": "r9", "macro": "Replace", "reasoning": "x", "expressible": True,
         "ranking": "Replace"},
        ["Replace", "NOOP"], ["r1"])
    assert why is not None and why.startswith("agent_outside_enum:") and "r9" in why


def test_grounding_rejects_a_missing_required_arg():
    """🔴 F12. `expressible` 이 없으면 T2 합성의 방아쇠가 조용히 사라진다.

    🔴 fix round 1 (Minor 6): `"expressible" in why` 는 동어반복이었다 -- `expressible` 은
    swap_body 의 `want`(요구 인자) 집합에 **항상** 들어 있으므로, missing_args 메시지의
    `요구=...` 절에 실제로 무엇이 빠졌든 상관없이 항상 나타난다(예: 코드가 엉뚱하게
    `macro` 를 빠뜨렸다고 오판해도 이 substring 검사는 여전히 통과했을 것이다). 실제로
    빠진 키가 메시지 **머리**(`missing_args: <키> (...)`)에 정확히 그 이름으로 나오는지를
    본다 -- `reasoning` 이 `reason` 을 포함하듯, 다른 요구 키가 우연히 겹치는 사고를
    막으려면 뒤에 공백이 오는 것까지 확인해야 한다."""
    why = reg.check_tool_args(
        "swap_body", {"agent": "r1", "macro": "Replace", "reasoning": "x", "ranking": "Replace"},
        ["Replace", "NOOP"], ["r1"])
    assert why is not None and why.startswith("missing_args: expressible ")


def test_grounding_rejects_a_macro_outside_this_events_menu():
    """🔴 fix round 2 (Cheap 1): 사유의 머리를 고정한다 -- 느슨한 `"macro" in why` 는
    `missing_args`/`off_schema_args`(둘 다 요구 키 목록에 `macro` 를 늘 담는다) 가 대신
    걸려도 통과했을 것이다."""
    why = reg.check_tool_args(
        "swap_body",
        {"agent": "r1", "macro": "SwapBattery", "reasoning": "x", "expressible": True,
         "ranking": "Replace"},
        ["Replace", "NOOP"], ["r1"])
    assert why is not None and why.startswith("macro_outside_menu:") and "SwapBattery" in why


def test_grounding_rejects_an_unknown_tool():
    """🔴 fix round 2 (Important). 삭제 대조: `unknown_tool` 가드를 지우면 이 호출은
    round-1 에서 새로 추가된 `tool_missing_impl` 가드(같은 이름이 `MACRO_TO_TOOL` 에는
    없으니 `_FUNCS` 에도 당연히 없다 -- 그 가드가 대신 걸린다)로 흘러들어가 **버젓이 걸린다**
    (구체적으로 `tool_missing_impl: 'teleport' (...)`). 그 문자열도 옛 느슨한 단언
    (`"teleport" in why`)을 만족시키므로, 이 시험은 자신이 지키려던 가드가 사라져도 green 으로
    남았을 것이다 -- 게다가 그 상태의 사유 문자열은 "MACRO_TO_TOOL 에는 있으나" 라고 주장하는데
    `teleport` 는 애초에 `MACRO_TO_TOOL` 에 없으므로 그 문장 자체가 거짓이 된다. 사유의 머리를
    `unknown_tool:` 로 고정해 정확히 그 가드가 걸렸는지를 잰다."""
    why = reg.check_tool_args("teleport", {}, ["NOOP"], ["r1"])
    assert why is not None and why.startswith("unknown_tool:") and "teleport" in why


def test_grounding_rejects_a_non_bool_expressible():
    """🔴 F13 의 짝. `bool("False") is True` 라 문자열을 받아 주면 거짓 True 가 기록된다.

    🔴 fix round 2 (Cheap 1): 사유의 머리를 고정한다 -- 느슨한 `"expressible" in why` 는
    `missing_args`(요구 키 목록에 `expressible` 이 늘 있다) 가 대신 걸려도 통과했을 것이다."""
    why = reg.check_tool_args(
        "swap_body",
        {"agent": "r1", "macro": "Replace", "reasoning": "x", "expressible": "False",
         "ranking": "Replace"},
        ["Replace", "NOOP"], ["r1"])
    assert why is not None and why.startswith("expressible_not_a_bool:")


def test_grounding_accepts_expressible_false():
    """🔴 fix round 1 (Important 1). 기존 7개 시험은 전부 `expressible: True` 만 썼다 --
    `expressible=False` 는 이 설계 전체가 존재하는 이유인 **바로 그 트리거**다(어휘 밖 사건에서
    T2 합성 방아쇠를 당기는 값). 실측: `if args["expressible"] is not True:` 로 바꿔치면 이
    시험 추가 전에는 33개 전부 green 이었는데, 그 뮤테이션은 `expressible=False` 인 정상 호출을
    `expressible_not_a_bool: False` 로 거절한다 -- 즉 이 레인이 존재하는 이유를 검증기가 조용히
    막아도 초록으로 보였을 것이다. 이 시험은 그 뮤테이션에서 반드시 빨개져야 한다."""
    ok = reg.check_tool_args(
        "swap_body",
        {"agent": "r1", "macro": "Replace", "reasoning": "x", "expressible": False,
         "ranking": "Replace"},
        ["Replace", "NOOP"], ["r1"])
    assert ok is None


def test_grounding_rejects_an_off_schema_extra_arg():
    """🔴 fix round 1 (Important 2). 삭제 대조: `off_schema_args` 가드를 지우면 아래 호출이
    `None`(접지 성공)을 돌려준다 -- 정확히 줄리아의 `ground_tool_args`(`llm_bridge.jl:238`)가
    `reject:off_schema_param` 으로 거부하는 그 축이다. 스키마에 없는 키가 조용히 통과하면
    Task 1 이 스키마로 좁힌 채널을 Task 2 가 도로 넓히는 셈이다."""
    why = reg.check_tool_args(
        "swap_body",
        {"agent": "r1", "macro": "Replace", "reasoning": "x", "expressible": True,
         "ranking": "Replace", "zone": "z1", "margin": 0.5},
        ["Replace", "NOOP"], ["r1"])
    assert why is not None and why.startswith("off_schema_args:")
    assert "zone" in why and "margin" in why


def test_grounding_rejects_non_dict_args():
    """🔴 fix round 1 (Minor 3). 이 가드가 없으면 문자열·리스트는 `missing_args` 로 흘러들어
    (`set(args)` 가 문자열의 글자 하나하나·리스트의 원소를 키처럼 다뤄) 오도하는 사유를 내고,
    `None`·정수는 `set(args)` 에서 바로 `TypeError` 로 죽는다(raise 는 안 된다는 총함수
    계약 위반). 넷 다 `args_not_a_dict` 로 깔끔하게 거절되는지 잰다."""
    for bad in ("not a dict", ["a", "list"], None, 42):
        why = reg.check_tool_args("swap_body", bad, ["Replace", "NOOP"], ["r1"])
        assert why is not None and why.startswith("args_not_a_dict:"), (bad, why)


def test_grounding_is_total_over_none_valid():
    """🔴 fix round 1 (Minor 4). `build_tools` 는 `agents or []` 로 방어하는데 이 함수는 그동안
    `list(None)` 에서 raise 했다 -- Task 4 가 이 함수를 `macro()` 안에서 부르므로, raise 하면
    그 예외가 응답의 `error` 필드로 삼켜지고 `policy.jl` 의 `policy_entry` 가 이 lane 전체를
    `available=false` 로 끈다(사유 문자열을 돌려주는 게 임무인 검증기가 레인 전체를 죽이는
    본말전도). `valid=None` 은 빈 메뉴로 취급되어 어떤 `macro` 값도 메뉴 밖이 된다."""
    why = reg.check_tool_args(
        "swap_body",
        {"agent": "r1", "macro": "Replace", "reasoning": "x", "expressible": True,
         "ranking": "Replace"},
        None, ["r1"])
    assert why is not None and why.startswith("macro_outside_menu:")


def test_grounding_is_total_over_none_agent_ids():
    """🔴 fix round 1 (Minor 4) 의 짝. `agent_ids=None` 도 raise 없이 빈 enum 으로 취급된다."""
    why = reg.check_tool_args(
        "swap_body",
        {"agent": "r1", "macro": "Replace", "reasoning": "x", "expressible": True,
         "ranking": "Replace"},
        ["Replace", "NOOP"], None)
    assert why is not None and why.startswith("agent_outside_enum:")


def test_grounding_reports_a_tool_missing_its_impl_instead_of_raising():
    """🔴 fix round 1 (Minor 4). `MACRO_TO_TOOL` 에는 있는데 `_FUNCS` 에는 없는 이름은 두 표가
    갈리는 드리프트를 흉내낸다 -- 원 표는 건드리지 않고 monkeypatch 로 임시 항목만 얹는다
    (`test_needs_agent_is_derived_from_function_signatures_not_a_hand_maintained_set` 와 같은
    패턴). 이 상태에서 `_needs_agent` 가 `_FUNCS[name]` 을 그대로 인덱싱하면 `KeyError` 로
    raise 하므로, `check_tool_args` 는 그보다 먼저 `_FUNCS` 존재를 확인해 사유 문자열로
    돌려줘야 한다."""
    tool_registry.MACRO_TO_TOOL["GhostMacro"] = "ghost_tool"
    try:
        assert "ghost_tool" not in _FUNCS, "준비 오류: 이미 _FUNCS 에 있다"
        why = reg.check_tool_args("ghost_tool", {}, ["GhostMacro"], ["r1"])
        assert why is not None and why.startswith("tool_missing_impl:") and "ghost_tool" in why
    finally:
        del tool_registry.MACRO_TO_TOOL["GhostMacro"]


def test_grounding_rejects_a_string_valid_instead_of_a_list():
    """🔴 fix round 2 (Cheap 2). `valid` 가 문자열이면 `args["macro"] not in valid` 는 리스트
    멤버십이 아니라 **부분문자열 검사**가 된다 -- `valid="Replace,SwapBattery"` 에
    `macro="Swap"` 을 주면 `"Swap" not in "Replace,SwapBattery"` 가 `False` 라 접지가 조용히
    성공한다(부분일치, 실측: 고치기 전에는 이 호출이 `None` 을 돌려줬다). 이 시험은 그 정확한
    함정을 재현해 명시적으로 거부되는지 잰다."""
    why = reg.check_tool_args(
        "swap_body",
        {"agent": "r1", "macro": "Swap", "reasoning": "x", "expressible": True,
         "ranking": "Replace"},
        "Replace,SwapBattery", ["r1"])
    assert why is not None and why.startswith("valid_not_a_sequence:"), (
        "문자열 valid 가 부분일치로 새 'Swap' 이 legal 매크로로 접지됐다")


def test_grounding_rejects_a_string_agent_ids_instead_of_a_list():
    """🔴 fix round 2 (Cheap 2) 의 짝 -- `agent_ids` 가 문자열이면 `args["agent"] not in
    agent_ids` 도 같은 부분일치 함정에 빠진다."""
    why = reg.check_tool_args(
        "swap_body",
        {"agent": "r1", "macro": "Replace", "reasoning": "x", "expressible": True,
         "ranking": "Replace"},
        ["Replace", "NOOP"], "r1")
    assert why is not None and why.startswith("agent_ids_not_a_sequence:")


def test_no_intervention_needs_reason_not_agent():
    assert reg.check_tool_args(
        "no_intervention",
        {"reason": "nothing broke", "macro": "NOOP", "reasoning": "x", "expressible": True,
         "ranking": "NOOP"},
        ["NOOP"], []) is None
    why = reg.check_tool_args(
        "no_intervention",
        {"macro": "NOOP", "reasoning": "x", "expressible": True, "ranking": "NOOP"},
        ["NOOP"], [])
    # 🔴 fix round 1 (Minor 6): `"reason" in why` 는 동어반복이었다 -- `reasoning` 이 요구 키
    # 목록에 항상 있고 그 단어가 이미 "reason" 을 부분문자열로 포함하므로, 실제로 무엇이
    # 빠졌는지와 무관하게 항상 참이었다. 메시지 머리가 정확히 `reason`(그 뒤에 공백, "reasoning"
    # 이 아니라)으로 시작하는지를 본다.
    assert why is not None and why.startswith("missing_args: reason ")
