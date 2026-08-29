"""payload 의 `agents` 가 스키마에 선언돼 있어야 한다.

🔴 pydantic 은 **선언 안 된 키를 조용히 버린다.** 이 선언이 없으면 Julia 가 실어 보내도
서비스에는 도착하지 않고, 동적 enum 이 빈 목록으로 굳어 tool 호출이 전부 막힌다.
같은 사고가 이 파일에 이미 있다(total_nodes, zone_nav_* 주석 참조).
"""
import os
import sys

import pytest
from pydantic import ValidationError

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from dspy_service import MacroRequest  # noqa: E402

# id 형태는 실측한 것이다 — `RobotID`(= `BotID{DeliveryBot}`, src/graph_utils_essentials.jl:56)는
# 어느 쪽도 export 되지 않아 `string(rid)`(open_agent_descriptors 가 id 를 만드는 바로 그 호출,
# src/respec/llm_bridge.jl:143-150)가 항상 완전정규화된 이름을 낸다. 재측정하려면:
#   julia +lts --project=. -e \
#     'using ConstructionBots; println(repr(string(ConstructionBots.RobotID(5))))'
#   -> "ConstructionBots.BotID{ConstructionBots.DeliveryBot}(5)"
AGENTS = [{"id": "ConstructionBots.BotID{ConstructionBots.DeliveryBot}(5)",
           "label": "Robot R5 / robot 5"},
          {"id": "ConstructionBots.BotID{ConstructionBots.DeliveryBot}(11)",
           "label": "Robot R11 / robot 11"}]


def test_agents_survives_validation():
    r = MacroRequest(kind="battery", agents=AGENTS)
    assert r.agents == AGENTS


def test_agents_defaults_to_none_not_empty():
    """None 과 [] 를 구분한다 — 전자는 '옛 호출자', 후자는 '이 판에 로봇이 없다'."""
    r = MacroRequest(kind="battery")
    assert r.agents is None


def test_agents_rejects_wrong_shaped_elements():
    """`Optional[List[Dict[str, str]]]` 이 실제로 검사되는지 핀다.

    타입 애노테이션을 `list` 로 뭉개도 이 파일의 다른 두 테스트는 여전히 통과한다(둘 다
    올바른 형태만 넣는다) -- 이 테스트가 그 구멍을 막는다. value 가 str 이 아니면 거부돼야 한다.
    """
    with pytest.raises(ValidationError):
        MacroRequest(kind="battery", agents=[{"id": 5}])
