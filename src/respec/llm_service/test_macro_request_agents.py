"""payload 의 `agents` 가 스키마에 선언돼 있어야 한다.

🔴 pydantic 은 **선언 안 된 키를 조용히 버린다.** 이 선언이 없으면 Julia 가 실어 보내도
서비스에는 도착하지 않고, 동적 enum 이 빈 목록으로 굳어 tool 호출이 전부 막힌다.
같은 사고가 이 파일에 이미 있다(total_nodes, zone_nav_* 주석 참조).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from dspy_service import MacroRequest  # noqa: E402

AGENTS = [{"id": "RobotID(5)", "label": "Robot R5 / robot 5"},
          {"id": "RobotID(11)", "label": "Robot R11 / robot 11"}]


def test_agents_survives_validation():
    r = MacroRequest(kind="battery", agents=AGENTS)
    assert r.agents == AGENTS


def test_agents_defaults_to_none_not_empty():
    """None 과 [] 를 구분한다 — 전자는 '옛 호출자', 후자는 '이 판에 로봇이 없다'."""
    r = MacroRequest(kind="battery")
    assert r.agents is None
