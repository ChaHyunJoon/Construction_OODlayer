"""요청마다 `dspy.Tool` 목록을 만든다 — T1 알파벳.

왜 별도 파일인가: `dspy_service.py` 는 이미 서비스·surrogate·프롬프트 렌더를 다 이고 있고,
여기는 Plan B 에서 **합성 tool 이 쌓이는 자리**라 따로 사는 편이 낫다.

🔴 두 가지 계약이 이 파일에 있다.
  ① 함수 본체는 **절대 호출되지 않는다.** native FC 경로는 tool 을
     `format_as_litellm_function_call()` 로 포맷만 한다. 집행은 Julia 가 하므로 본체가
     실제로 뭔가 하면 세계가 두 번 바뀐다. 그래서 `raise` 로 막아 둔다.
  ② docstring 이 곧 tool 의 `description` 이고, 그것이 **모델이 읽는 유일한 tool 설명**이다
     (native FC 가 켜지면 dspy 가 `tools` 필드를 프롬프트에서 지운다). 그러므로 여기에는
     **기전만** 적는다 — "언제 쓰는가" 는 적지 않는다(spec §6).
"""
import inspect
from typing import Any, Dict, List

# 🔴 fix round 1 (H2) -- `dspy_service.py:44` 와 같은 계약, 이 파일에도 독립적으로 필요하다.
# dspy 3.3.0 은 `import dspy` 시점에 sys.modules["numpy"] 를 lazy-import 프록시로 바꿔치기한다.
# 그 뒤 **이 프로세스 안에서 누구든** sklearn.ensemble 을 import 하면(joblib -> numpy 경유)
# 그 프록시로 재진입해 `numpy/_core/_methods.py:17: TypeError: data type 'bool' not understood`
# 로 죽는다. 이 파일이 `dspy_service.py` 보다 먼저 import 되는 두 경로가 실재한다:
#   (a) Task 6 이후: `dspy_service.py` 안에서 `from tool_registry import ...` 를 하면 그 줄이
#       실행되는 시점의 import 순서를 이 파일이 정한다 -- 이 파일이 numpy/sklearn 보다 먼저
#       `dspy` 를 심으면 dspy_service.py 의 44행 순서 고정이 무의미해진다.
#   (b) pytest 수집: 디렉토리 안 파일 이름이 알파벳순과 다르게 재배열되거나(-p no:randomly
#       류 플러그인, 파일 이름 변경 등) `test_tool_registry.py` 가 `test_macro_request_agents.py`
#       보다 먼저 수집되면, 이 파일 혼자 먼저 `dspy` 를 심어 버린다.
# 실측(2026-08-28, fix round 1 H2): `pytest test_tool_registry.py test_macro_request_agents.py`
# (이 순서)는 수집 단계에서 TypeError 로 죽는다; 역순은 11 passed. 이 파일 혼자 `import
# tool_registry` 뒤에 `import sklearn.ensemble` 또는 `import dspy_service` 를 해도 같은
# TypeError 로 죽는다. 절대 "정리"한다고 아래 줄을 지우거나 dspy 뒤로 옮기지 말 것.
import numpy, sklearn.ensemble  # noqa: F401  -- 순서 고정: dspy 보다 먼저 진짜 numpy/sklearn 을 초기화

import dspy

_NEVER = "never called: Julia enacts this"


def _agent_arg(agent_ids: List[str]) -> Dict[str, Any]:
    # ⚠️ dspy 는 `args` 를 주면 `arg_desc` 를 **무시한다**. description 을 여기 직접 넣는다.
    # 🔴 fix round 1 (H6): 예전 문구("copied verbatim from the prompt")는 존재하지 않는 채널을
    # 주장했다 -- `req.agents` 는 프롬프트 본문에 렌더되지 않는다(그 id 들이 사는 곳은 오직 이
    # enum 뿐이다). 모델이 읽는 이 설명이 없는 소스를 가리키면 안 되므로 enum 을 가리키게 고친다.
    return {"agent": {"type": "string", "enum": list(agent_ids),
                      "description": "exact robot id, copied verbatim from this parameter's "
                                      "enum list (these ids are not restated in the prompt text)"}}


def swap_body(agent: str):
    """Replace the affected robot with a spare BODY from the depot pool.

    Edits the SCHEDULE GRAPH: a new node takes the same node id and the assignment
    edges are re-hung. Consumes one spare robot from the depot -- a scarce resource
    that is not replenished. Measured cost: +13.3 simulated seconds per event and
    +228% energy per closed node. The replaced body does not come back.
    """
    raise AssertionError(_NEVER)


def deliver_battery(agent: str):
    """Send a borrowed depot robot to carry a fresh battery to the affected robot.

    The courier drives there physically; the swap applies on arrival, then the courier
    returns to its slot and recharges. The SCHEDULE GRAPH IS NOT EDITED -- no node is
    created for the delivery. The affected robot keeps its body and its identity.
    No depot spare is consumed: the courier is borrowed and returned. The cost is
    travel time plus a line stop while the swap is pending. Measured: +4.1 simulated
    seconds per event and +25% energy per closed node.
    """
    raise AssertionError(_NEVER)


def no_intervention(reason: str):
    """Change nothing. No graph is edited, no resource is spent, no time is lost.

    State plainly what you observed that made intervention unnecessary. Do not infer
    facts about the world from the shape of this menu.
    """
    raise AssertionError(_NEVER)


# 매크로 이름(채점 어휘) -> tool 이름(행동 어휘). 두 어휘를 섞지 않되 대응은 명시한다.
# 🔴 공개 이름이다 — Task 6 의 `dspy_service` 가 `macro_tool_agree` 를 계산할 때 **이 표를**
#    쓸 것이다(2026-08-28 현재 `dspy_service.py` 는 이 표를 아직 참조하지 않는다 -- `grep -n
#    MACRO_TO_TOOL src/respec/llm_service/dspy_service.py` = 0 hits, fix round 1 H6 실측).
#    두 벌 두면 조용히 갈린다.
MACRO_TO_TOOL = {"Replace": "swap_body", "SwapBattery": "deliver_battery", "NOOP": "no_intervention"}
_FUNCS = {"swap_body": swap_body, "deliver_battery": deliver_battery,
          "no_intervention": no_intervention}


def _needs_agent(name: str) -> bool:
    """fix round 2 (K3): 예전에는 `_NEEDS_AGENT` 가 손으로 든 집합이었다. 측정: 넷째
    agent-taking 팔을 `MACRO_TO_TOOL`·`_FUNCS` 에는 추가하면서 이 집합만 깜빡해도 13 개
    테스트가 전부 green 이었다 -- `build_tools` 가 else 분기로 빠져 agent enum 대신
    `reason: string` 을 낸다. 접지(그 요청에 실재하는 id 만 담기)가 조용히 사라지는데
    에러가 하나도 없다(`_FUNCS` 를 깜빡하면 `KeyError` 로 시끄럽게 죽는 것과 대조적이다).
    손으로 든 집합을 아예 없애고 `_FUNCS[name]` 의 실제 파라미터 이름에서 유도한다 --
    `agent` 파라미터가 있으면 agent 분기, 없으면 reason 분기. 이제 이 실수 자체가
    구조적으로 불가능하다: 깜빡할 별도의 표가 없다."""
    return "agent" in inspect.signature(_FUNCS[name]).parameters


def build_tools(agents, valid) -> List[dspy.Tool]:
    """이 요청에서 호출 가능한 tool 목록.

    `agents` : [{"id": ..., "label": ...}, ...] — 실재하는 로봇만.
    `valid`  : 이 사건에서 legal 한 **매크로** 이름 목록(호출자가 세계를 보고 계산한 것).

    🔴 로봇 id 가 하나도 없으면 로봇을 지목하는 tool 을 **아예 안 낸다.** 빈 enum 은 provider 가
    거부하거나 아무 문자열이나 통과시키는데, 후자면 ②접지가 조용히 뚫린다.
    """
    agent_ids = [a["id"] for a in (agents or []) if a.get("id")]
    out = []
    for macro in (valid or []):
        name = MACRO_TO_TOOL.get(macro)
        if name is None:
            continue
        if _needs_agent(name):
            if not agent_ids:
                continue
            out.append(dspy.Tool(_FUNCS[name], args=_agent_arg(agent_ids)))
        else:
            out.append(dspy.Tool(_FUNCS[name], args={"reason": {
                "type": "string",
                "description": "what you observed that made intervention unnecessary"}}))
    return out
