"""tool 스키마가 **그 요청에 실재하는 id 만** 담는지 못박는다."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from tool_registry import build_tools  # noqa: E402

AGENTS = [{"id": "ConstructionBots.BotID{ConstructionBots.DeliveryBot}(5)", "label": "Robot R5 / robot 5"},
          {"id": "ConstructionBots.BotID{ConstructionBots.DeliveryBot}(11)", "label": "Robot R11 / robot 11"}]


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


def test_no_applicability_verdict_leaks_into_descriptions():
    """spec §6: 기전은 말하고 정답 조건은 말하지 않는다."""
    for s in _by_name(build_tools(AGENTS, ["NOOP", "Replace", "SwapBattery"])).values():
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
