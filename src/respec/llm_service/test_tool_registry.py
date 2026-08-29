"""tool 스키마가 **그 요청에 실재하는 id 만** 담는지 못박는다."""
import os
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

from tool_registry import build_tools, MACRO_TO_TOOL, swap_body, deliver_battery, no_intervention  # noqa: E402
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
    "Julia 가 이걸 두 번 집행하지 않는다" 는 안전장치 자체다."""
    with pytest.raises(AssertionError):
        swap_body("some-agent-id")
    with pytest.raises(AssertionError):
        deliver_battery("some-agent-id")
    with pytest.raises(AssertionError):
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
