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
from typing import Any, Dict, List

import dspy

_NEVER = "never called: Julia enacts this"


def _agent_arg(agent_ids: List[str]) -> Dict[str, Any]:
    # ⚠️ dspy 는 `args` 를 주면 `arg_desc` 를 **무시한다**. description 을 여기 직접 넣는다.
    return {"agent": {"type": "string", "enum": list(agent_ids),
                      "description": "exact robot id, copied verbatim from the prompt"}}


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
# 🔴 공개 이름이다 — dspy_service 가 `macro_tool_agree` 를 계산할 때 **이 표를** 쓴다.
#    두 벌 두면 조용히 갈린다.
MACRO_TO_TOOL = {"Replace": "swap_body", "SwapBattery": "deliver_battery", "NOOP": "no_intervention"}
_NEEDS_AGENT = {"swap_body", "deliver_battery"}
_FUNCS = {"swap_body": swap_body, "deliver_battery": deliver_battery,
          "no_intervention": no_intervention}


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
        if name in _NEEDS_AGENT:
            if not agent_ids:
                continue
            out.append(dspy.Tool(_FUNCS[name], args=_agent_arg(agent_ids)))
        else:
            out.append(dspy.Tool(_FUNCS[name], args={"reason": {
                "type": "string",
                "description": "what you observed that made intervention unnecessary"}}))
    return out
