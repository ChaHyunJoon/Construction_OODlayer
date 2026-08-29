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
    """🔴 환각 id 를 디코드 시점에 막는 자리. enum 밖은 모델이 생성할 수 없다."""
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
