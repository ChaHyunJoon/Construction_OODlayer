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

# 🔴 tool 이름 -> 매크로 이름. `MACRO_TO_TOOL` 에서 **유도한다** — 손으로 두 벌 적으면 갈린다.
#    이 설계에서 `chosen` 은 오직 이 표를 통해 나오므로, 여기가 틀리면 결정이 틀린다.
TOOL_TO_MACRO = {v: k for k, v in MACRO_TO_TOOL.items()}
assert len(TOOL_TO_MACRO) == len(MACRO_TO_TOOL), \
    "MACRO_TO_TOOL 이 두 매크로를 같은 tool 에 보낸다 — 역표가 성립하지 않는다"

# ---- 결정 성분을 나르는 공통 인자 (2026-08-29, 단일 채널) ------------------------------------
# 🔴 왜 인자인가. `tool_choice="required"` 판에서 프로바이더는 tool 호출만 내고 message content
#    를 비운다. 그러면 텍스트 OutputField 는 `adapters/base.py:168·181` 이 **예외 없이** 전부
#    `None` 으로 만든다. 즉 강제 하에서 결정을 받을 수 있는 채널은 tool 인자 **하나뿐**이다.
_EXPRESSIBLE_DESC = (
    "false if NOTHING in this tool menu can remove the CAUSE of what you observed -- "
    "i.e. you are calling a tool only because you must, not because it fixes anything. "
    "Answering NOOP because intervening is unnecessary is NOT this: that is true. "
    "Set false when the fix this event needs is outside the menu entirely.")
# 🔴 마지막 두 문장이 하중을 받는다. 실측(2026-08-29): 이 두 문장이 없는 옛 문구
#    ("false if NO available tool can address what you observed")로는 어휘 밖 사건 셋 중
#    **하나만** False 였고, 개정 후 3/3 이 됐다. 대조군(진짜 배터리 사건)은 양쪽 다 True —
#    거짓 양성은 안 생겼다.
#    ⚠️ 대가: 이 문구는 모델에게 *언제 false 라고 말할지*를 가르친다. 그래서 `expressible ==
#    False` 비율은 부분적으로 **프롬프트 준수**를 잰다. 세대를 가르는 키는 `decision_source` 다.

_REASONING_DESC = (
    "one sentence: why this action, and how clearly it beats the runner-up -- "
    "say that in words (e.g. \"clearly better than X\" / \"only marginally better than X\" / "
    "\"essentially tied with X\"), not as a number.")
# 🔴 `margin` 스칼라를 없앤 자리다(spec §3-3). 그 값은 계산된 적이 없는 자기 신고였고 무엇과도
#    대조된 적이 없다(실측: harm 0.88 사건이 0.5, soc 12% 사건이 0.8). 실측(2026-08-29): 이
#    문구로 3/3 이 비교 절을 산문에 담았고, 어느 대안보다 나은지까지 말해 숫자보다 정보가 많다.


def COMMON_ARGS(valid):
    """세 tool 이 **전부** 갖는 결정 성분 인자. 고유 인자(`agent`/`reason`)와 합쳐 쓴다.

    🔴 `valid` 를 받는 이유는 `macro` enum 이 **이 사건의** legal 매크로여야 하기 때문이다.
    모듈 상수로 굳히면 사건마다 다른 메뉴를 못 따라간다.

    🔴 fix round 1 (finding 2): `valid` 는 "이 사건에서 legal 한 매크로 전체" 가 아니라
    **호출자가 실제로 tool 로 내보낼 매크로** 여야 한다 -- `build_tools` 참고. `ranking` 의
    description 은 건드리지 않는다: 그건 스코어링 메뉴(legal 매크로 전체)를 말하고, `macro`
    enum 은 콜 가능한 메뉴(실제로 나가는 tool)를 말한다 -- 원래 다른 것을 가리키므로 이건
    "비대칭"이 아니라 설계다.
    """
    return {
        "macro": {"type": "string", "enum": list(valid),
                  "description": "the macro name this call enacts"},
        "reasoning": {"type": "string", "description": _REASONING_DESC},
        "expressible": {"type": "boolean", "description": _EXPRESSIBLE_DESC},
        "ranking": {"type": "string",
                    "description": "ALL legal macros ordered best-first, comma separated"},
    }


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

    🔴 2026-08-29: 각 tool 이 `COMMON_ARGS(valid)` 를 함께 싣는다 — 그것이 이 설계에서 결정을
    받는 유일한 채널이다.

    🔴 fix round 1 (finding 2): `COMMON_ARGS` 에는 `valid` 그대로가 아니라 **실제로 tool 로
    나가는 매크로만** 넘긴다. 안 그러면(예: `agents=[]` 에 `valid=["Replace","NOOP"]`) agent
    가 하나도 없어 `swap_body` 는 안 나가는데 남은 `no_intervention` 의 `macro` enum 에는
    여전히 `"Replace"` 가 남아, 모델이 존재하지 않는 tool 을 legal 하다고 답할 길이 생긴다.
    그 답은 Task 4 에서 `macro_tool_agree=False` 로 기록되는데, 이는 모델의 실수가 아니라
    스키마 자신이 만든 불일치다.
    """
    agent_ids = [a["id"] for a in (agents or []) if a.get("id")]
    emitted_macros = [m for m in (valid or [])
                       if MACRO_TO_TOOL.get(m) is not None
                       and (agent_ids or not _needs_agent(MACRO_TO_TOOL[m]))]
    common = COMMON_ARGS(emitted_macros)
    out = []
    for macro in (valid or []):
        name = MACRO_TO_TOOL.get(macro)
        if name is None:
            continue
        if _needs_agent(name):
            if not agent_ids:
                continue
            args = dict(_agent_arg(agent_ids))
        else:
            args = {"reason": {
                "type": "string",
                "description": "what you observed that made intervention unnecessary"}}
        args.update(common)
        out.append(dspy.Tool(_FUNCS[name], args=args))
    return out
