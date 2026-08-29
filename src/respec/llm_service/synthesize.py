"""T2 — 낯선 사건에 **새 tool 을 합성**한다 (Plan B / T6b, spec §5).

이 파일이 하는 일은 넷이다.

  ① `SynthesizeTool` 시그니처 (spec §5-1 을 **그대로**).
  ② `context` 를 짓는다 — 이 빌드의 물리 원리 · 현재 상태 · 최종 목표 · 사건의 새로운 성질 ·
     무엇이 바뀌어야 하는가 · 현재 가진 tool 들 · 그리고 **원시 인벤토리와 각 원시의 mechanism**.
  ③ 출력의 **정규화**(canon) · ψ 거리 **기록** · `|K|` 카운터.
  ④ 발화 여부와 `tool_minted` 네 값의 판정.

🔴 이 파일은 파이썬 쪽만이다. 결정 행에 `tool_minted` 를 싣는 줄리아 배선(`policy.jl` 의
`TOOL_LANE_KEYS` · `run_demo.jl` 의 `this_decision`)은 **일부러 미룬 것**이고, 여기서는 값을
서비스 응답으로 **돌려주기만** 한다. 소비처는 T6b 보고서가 줄 단위로 짚는다.

────────────────────────────────────────────────────────────────────────────────
🔴 R13 — 합성은 `TOOL_SYNTHESIS=1` 로만 켠다. 기본 OFF.
────────────────────────────────────────────────────────────────────────────────
합성 1회 = 사용자 계정의 **유료 OpenAI 호출**이다. 그러나 꺼져 있을 때 조용히 성공 모양의
출력을 내지 않는다 — 이 레포의 `force_advance_stuck_carrier!` 가 정확히 그 함정이다
(`CARRIER_RESCUE` 없이 no-op 인데 로그만 보면 정상). 그래서:

    tool_minted == "disabled"  ->  발화할 사건이었는데 **플래그가 꺼져 있었다**
    tool_minted is None        ->  발화할 사건이 아니었다 (expressible != False)

🔴 **판정 순서는 "발화 조건 먼저, 플래그 나중"이다.** 반대로 하면(플래그 먼저) 기본 실행의
**모든 결정 행**이 `"disabled"` 가 되고, 그 순간 `expressible == false` 비율(spec §8-1 이
승격 게이트의 대체 신호로 지목한 바로 그 숫자)을 이 필드에서 되살릴 수 없다. 지금 순서에서는
`"disabled"` 의 개수가 곧 "켰다면 몇 번 발화했을 것인가" 다.

🔴 **네 값은 분할이 아니다.** 다섯 번째 사건이 있다: **돌았는데 LM/파싱이 실패했다.**
그 행은 `tool_minted is None` 이지만 `synthesis_event=True · ran=True · error!=None` 이라
"발화할 사건이 아니었다"(`synthesis_event=False`)와 **구별된다.** 이 레포는 한 레인의 사건이
다른 레인의 버킷에 실려 비율이 부풀려지는 사고를 이미 두 번 밟았다(C8 의 세 사건,
fault 발화율 100% vs 23%). 소비자 규칙:

    발화 안 함      synthesis_event == False                      -> tool_minted is None
    꺼져 있었음     synthesis_event == True and ran == False      -> tool_minted == "disabled"
    돌다가 실패     ran == True and error is not None             -> tool_minted is None
    재유도          ran == True and error is None                 -> tool_minted == False
    새 canon        ran == True and error is None                 -> tool_minted == True

────────────────────────────────────────────────────────────────────────────────
🔴 R19 — ψ 거리는 **기록 전용**이다. 어떤 임계값으로도 병합하지 않는다.
────────────────────────────────────────────────────────────────────────────────
T6a 실측이 이 공간의 변별력을 깎았다: `a_cost` 19개 중 실제 숫자에 닻이 있는 것은 4개뿐이고
그중 둘은 ψ 충돌을 깨려고 넣은 값이다 · `a_intervenes` 는 19개 전부 1.0(거리에 정보 0) ·
두 이름공간이 같은 물리 행동에서 `a_reversible` 이 어긋난다. 그래서 이 파일은 거리를
**계산해서 기록만** 하고, τ 를 지어내지 않는다. 표준화 통계의 출처는 `psi_stats()` 가
`provenance` 로 같이 낸다 — 숫자만 남기고 출처를 안 남기면 그 15개 판단이 기록에서 사라진다.

────────────────────────────────────────────────────────────────────────────────
🔴 R7 — `when_to_use` 는 어떤 프롬프트 경로에도 닿지 않는다.
────────────────────────────────────────────────────────────────────────────────
그것은 **정답 조건**이고, 프롬프트에 실으면 재는 것이 추론이 아니라 프롬프트 준수가 된다
(spec §6-2, `dspy_service.py:155-165` 의 실측). 이 파일의 인벤토리 렌더는 `when_to_use` 를
**읽지 않는다** — 필드 이름이 이 모듈 안에 딱 한 번, 아래 `_NEVER_RENDER` 에만 나온다.
게이트는 `test_synthesize.py` 의 **치환 불변성** 검사다(`when_to_use` 를 전부 센티넬로 바꿔도
렌더가 바이트 단위로 같은가). 살아 있는 레지스트리에서 20자 슬라이딩 윈도우를
`when_to_use` **원문**에 그대로 걸 수 없는 이유는 그 테스트의 docstring 에 실측과 함께 있다.

────────────────────────────────────────────────────────────────────────────────
🔴 params 는 **평평한 스칼라만** — T1 이 남긴 함정을 여기서 닫는다.
────────────────────────────────────────────────────────────────────────────────
줄리아의 `_tool_args_dict`(`tools/monitor/policy.jl`, `TOOL_LANE_KEYS` 바로 아래)는
**얕다**. 오늘 그것이 정확한 이유는 세 tool 이
전부 평평한 `str` 인자 하나만 받기 때문이다(그 함수의 실측 주석). 중첩 인자를 가진 tool 을
합성하는 순간 그 값은 `JSON3.Object` 로 남아 `Dict{String,Any}` 가정을 **에러 없이** 깬다.
줄리아를 못 건드리는 이 태스크는 브리프가 준 두 길 중 **둘째**를 택한다: `params` 를 평평한
스칼라로 제약하고 그 제약을 게이트로 잡는다(`params_flatness`). ⚠️ 제약을 어긴 출력도
**버리지 않는다** — `params_flat=False` 로 기록만 하고 정의는 끝까지 남긴다(spec §5-1).
"""
import json
import os
import re
import sys
from typing import Any, Dict, List, Optional, Sequence, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
# HERE = <repo>/src/respec/llm_service -> 세 단계 위가 repo 루트. `dspy_service.py:47-51` 과
# 같은 규칙이고, 여기 독립적으로 있는 이유는 이 모듈이 그 파일보다 **먼저** import 될 수 있기
# 때문이다(pytest 수집 순서 · 다른 파일에서의 직접 import).
WM = os.environ.get("WM_DIR") or os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(HERE))),
    "wm4spacecraft_manufacturing")
for _d in (os.path.join(WM, "core"),):
    if _d not in sys.path:
        sys.path.append(_d)

# 🔴 `dspy_service.py:44` · `tool_registry.py` 와 **같은 계약**이고, 이 파일에도 독립적으로
# 필요하다. dspy 3.3.0 은 `import dspy` 시점에 sys.modules["numpy"] 를 lazy-import 프록시로
# 바꿔치기하고, 그 뒤 누구든 sklearn.ensemble 을 import 하면 그 프록시로 재진입해
# `numpy/_core/_methods.py:17: TypeError: data type 'bool' not understood` 로 죽는다.
# 수집 순서가 바뀌면 **이 파일이 혼자 먼저 dspy 를 심는다** — 그러면 다른 두 파일의 순서 고정이
# 무의미해진다. 절대 지우거나 dspy 뒤로 옮기지 말 것.
import numpy, sklearn.ensemble  # noqa: F401,E401  -- 순서 고정: dspy 보다 먼저

import dspy  # noqa: E402

import features_agnostic as _fa       # noqa: E402  (psi -- 운용 원시 이름을 받고 모르면 KeyError)
import primitive_registry as _prim    # noqa: E402  (레지스트리 로더. 리터럴 복붙 금지)

# 🔴 이 모듈 전체에서 `when_to_use` 라는 이름이 나오는 **유일한 자리**다. 렌더 함수는 원시
#    dict 에서 이 키를 한 번도 읽지 않는다 — 읽지 않는다는 사실 자체를 게이트가 치환 불변성으로
#    잰다. 여기 있는 이유는 "빠뜨린 것"과 "일부러 뺀 것"을 코드에서 구분하기 위해서다.
_NEVER_RENDER = ("when_to_use",)

SYNTHESIS_ENV = "TOOL_SYNTHESIS"


def synthesis_enabled() -> bool:
    """R13. `TOOL_SYNTHESIS=1` 일 때만 True. **정확히 `"1"`** 이다 — `"true"`/`"yes"` 를
    받아 주지 않는다: 유료 호출을 여는 스위치라 오타가 관대함으로 통과하면 안 된다."""
    return os.environ.get(SYNTHESIS_ENV, "") == "1"


# ==========================================================================================
# ① 시그니처 — spec §5-1 을 **그대로**. 필드 이름·desc 문구를 임의로 바꾸지 않는다.
# ==========================================================================================
class SynthesizeTool(dspy.Signature):
    """You design a NEW recovery tool for a disruption that no existing tool addresses.
    A tool is a NAME, a PARAMETER SCHEMA, a MECHANISM description, and a BODY.
    The BODY is a sequence of primitive operations. Prefer primitives from the inventory
    you are given. If the inventory cannot express what is needed, you may still define
    the tool -- but you must name the missing primitive precisely (what it edits, its
    preconditions, whether it can be undone) and set reach to "needs_primitive".
    You never write code: a body is a call sequence, a missing primitive is a spec."""
    context: str  = dspy.InputField(desc=
        "physical principles of this build (3-layer robot policy, scene tree, DAG design), "
        "current state, final goal, novel properties of the event, what should change, "
        "existing tools, and the PRIMITIVE INVENTORY with each primitive's mechanism")
    question: str = dspy.InputField(desc="the properties of the OOD failure event")

    tool_name: str = dspy.OutputField()
    params: str    = dspy.OutputField(desc="JSON schema of the parameters")
    mechanism: str = dspy.OutputField(desc=
        "exactly which graph surface this edits and how; what it consumes; preconditions; "
        "whether it can be undone. Be exhaustive -- a later decision reads only this.")
    body: str      = dspy.OutputField(desc=
        "ordered list of primitive calls, with arguments")
    reach: str     = dspy.OutputField(desc=
        '"composed" if every primitive in the body exists in the inventory; '
        '"needs_primitive" otherwise')
    missing_primitive: str = dspy.OutputField(desc=
        "if reach is needs_primitive: name, edit surface (sched|scene_tree|env_param|"
        "physical), params, preconditions, reversibility, what it consumes, and WHY no "
        "composition over the inventory can substitute for it. Empty otherwise.")


# ==========================================================================================
# ② context
# ==========================================================================================
# 이 빌드의 물리 원리. 리터럴인 이유: 이것은 레지스트리가 아니라 **이 시뮬레이터의 구조**이고
# 기계가 읽는 단일 진실원이 없다. 근거를 줄 단위로 달아 두어 갱신할 사람이 확인할 수 있게 한다.
PHYSICAL_PRINCIPLES = """\
PHYSICAL PRINCIPLES OF THIS BUILD

1. SCHEDULE (a DAG). The build is a precedence graph of nodes. A node becomes active exactly
   when ALL of its predecessors are closed -- the frontier rule is pure DAG reachability, with
   no side conditions (ConstructionBots essential_tg_coponents.jl). The build is finished when
   every node is closed. Assignment edges (which robot does which slot) are chosen by a MILP;
   editing those edges without a following MILP re-solve leaves the schedule with fewer
   assignments and no replacement plan.

2. SCENE TREE (geometry). A separate tree holds the nested assembly geometry: where each
   sub-assembly is staged, where cargo is deposited, and the transforms that relate them.
   Moving staging areas or translating the whole build edits THIS tree, not the schedule.
   No existing recovery macro edits the scene tree.

3. THREE-LAYER ROBOT POLICY (motion). Every mover runs three stacked layers:
     (a) TangentBugPolicy      -- nominal navigation around staging circles and obstacles
     (b) PotentialFieldController -- dispersion under congestion (mutual repulsion)
     (c) RVO / VelocityController -- collision avoidance that produces the final velocity
   CONSEQUENCE THAT MATTERS FOR TOOL DESIGN: exclusion zones are enforced only on RVO-driven
   navigating agents. A goal whose cargo is moved by a lift transform, not by a navigating
   agent, is not stopped by a zone at all. "Covered by a zone" and "blocked by a zone" are
   different facts.

4. THREE EDIT SURFACES, NOT ONE. Recovery is not "graph editing" with one abstraction:
     sched      -- the schedule graph and its assignment edges
     scene_tree -- staging poses and build placement
     env_param  -- solver-visible parameters (cost biases, thresholds)
     physical   -- side channels that move real robots (couriers, teleports)
     milp       -- constraint compilation and commit
   Each primitive below declares which surface it edits.

5. TIME AND RESOURCES. Depot spares are scarce and are NOT replenished. A courier is borrowed
   and returned; a body replacement is consumed forever. Intervening always costs simulated
   time and energy, so doing nothing is a real option when nothing the schedule still needs
   is actually violated."""

FINAL_GOAL = """\
FINAL GOAL
Close every node of the schedule DAG. Nothing else is the goal: a plan that keeps every robot
alive but leaves one node permanently unclosable has failed, and a plan that spends a scarce
spare to close a node that would have closed anyway has paid for nothing."""


def _fmt_params(p: Dict[str, Any]) -> str:
    return json.dumps(p, ensure_ascii=False, sort_keys=True)


def primitive_inventory_lines(blob=None) -> List[str]:
    """운용 원시 19종을 프롬프트 줄로 렌더한다.

    🔴 각 원시의 **`mechanism` 만** 싣는다. `when_to_use` 는 읽지 않는다(R7).
    ⚠️ **함정 항목을 그대로 싣는다** — `force_advance_stuck_carrier` 는 `CARRIER_RESCUE=1`
    없이 no-op, `rethread_robot_ids` 는 PARKED, `deprioritize_agent` 는 MILP 재풀이가 없으면
    무효. 그 사실들은 각 항목의 `mechanism` 산문 안에 이미 있고, 그래서 mechanism 을 **자르지
    않고 전문으로** 싣는다. 자르면 합성기가 조용히 아무 일도 안 하는 tool 을 만든다.
    """
    b = blob if blob is not None else _prim.REGISTRY
    out: List[str] = []
    for p in b["primitives"]:
        out.append("- %s   [surface=%s  reversible=%s  consumes=%s]" % (
            p["name"], p["surface"],
            "yes" if p["reversible"] else "NO",
            (", ".join(p["consumes"]) if p["consumes"] else "nothing")))
        out.append("    params: %s" % _fmt_params(p["params"]))
        if p.get("preconditions"):
            out.append("    preconditions: %s" % "; ".join(p["preconditions"]))
        out.append("    mechanism: %s" % p["mechanism"])
    return out


def predicate_inventory_lines(blob=None) -> List[str]:
    """순수 술어. **body 에 넣으면 안 된다** — 그 사실을 모델에게 말해 준다.

    왜 필요한가: `features_agnostic.psi()` 는 술어 이름에 KeyError 를 던진다(그 메시지가
    "이건 술어다"를 따로 말한다). 술어가 body 에 들어오면 이 파일의 ψ 거리가 계산 불가가 되고,
    그 사실이 `psi_error` 로 기록된다 — 조용히 0 이 되지 않는다.
    """
    b = blob if blob is not None else _prim.REGISTRY
    out: List[str] = []
    for q in b["predicates"]:
        out.append("- %s   [PURE PREDICATE -- reads geometry, edits nothing. It has no effect "
                   "descriptor and MUST NOT appear in a tool body.]" % q["name"])
        out.append("    mechanism: %s" % q["mechanism"])
    return out


def _tool_lines(tools) -> List[str]:
    """지금 가진 tool 들. `dspy.Tool` 목록(= `tool_registry.build_tools` 의 산출물)을 받는다.

    tool 의 `desc` 는 그 함수의 docstring 이고, 그것이 **모델이 읽는 유일한 tool 설명**이다
    (native FC 가 켜지면 dspy 가 프롬프트에서 tools 필드를 지운다). 여기서도 그대로 싣는다.
    """
    out: List[str] = []
    for t in (tools or []):
        out.append("- %s(%s)" % (getattr(t, "name", "?"),
                                 ", ".join(sorted((getattr(t, "args", None) or {}).keys()))))
        desc = (getattr(t, "desc", "") or "").strip()
        for ln in desc.splitlines():
            out.append("    %s" % ln.strip() if ln.strip() else "")
    if not out:
        out.append("- (none: this event was offered no tool at all)")
    return out


_NOVEL_FALLBACK = """\
The monitor did not classify this event. Its novelty is exactly what the observation above
reports and what the existing tools below cannot address -- no event-type label was applied,
and no field named after a known failure mode was populated."""

_MUST_CHANGE_FALLBACK = """\
The schedule must reach a state in which every remaining node can close. The observation above
is the ONLY evidence of what currently prevents that; nothing here tells you which edit is
correct, and no minimum repair has been computed for you."""


def build_context(state: str,
                  tools=None,
                  novel: Optional[str] = None,
                  must_change: Optional[str] = None,
                  goal: Optional[str] = None,
                  principles: Optional[str] = None,
                  blob=None) -> str:
    """`SynthesizeTool.context` 의 본문.

    일곱 블록이고 순서는 시그니처 desc 의 순서를 따른다: 물리 원리 · 현재 상태 · 최종 목표 ·
    사건의 새로운 성질 · 무엇이 바뀌어야 하는가 · 현재 가진 tool · 원시 인벤토리.

    🔴 `when_to_use` 를 읽는 경로가 하나도 없다(R7). 게이트: 치환 불변성.
    🔴 정답을 싣지 않는다: `min_shift_to_clear_m`(= `_find_min_translation` 이 **푼 답**)은
       T4a 가 프롬프트에서 지웠고, 이 파일은 `state` 문자열을 그대로 받으므로 그 제거를
       자동으로 승계한다. 위 두 폴백 문구도 "무엇을 하라"를 한 줄도 적지 않는다.
    """
    parts = [
        principles or PHYSICAL_PRINCIPLES,
        "",
        "CURRENT STATE (decision-time observation, produced without classifying the event)",
        state or "(no observation was supplied)",
        "",
        goal or FINAL_GOAL,
        "",
        "NOVEL PROPERTIES OF THE EVENT",
        novel or _NOVEL_FALLBACK,
        "",
        "WHAT MUST CHANGE",
        must_change or _MUST_CHANGE_FALLBACK,
        "",
        "TOOLS YOU ALREADY HAVE (a new tool must do something these cannot)",
    ]
    parts += _tool_lines(tools)
    parts += ["",
              "PRIMITIVE INVENTORY -- the alphabet a body may be composed from.",
              "Each entry states which surface it edits, what it consumes, whether it can be "
              "undone, and its full mechanism including the conditions under which it does "
              "nothing at all."]
    parts += primitive_inventory_lines(blob)
    parts += ["",
              "PURE PREDICATES -- measurement only. Never put one in a body."]
    parts += predicate_inventory_lines(blob)
    return "\n".join(parts)


# ==========================================================================================
# ③ 정규화 · ψ · |K|
# ==========================================================================================
# `name(` 또는 `name!(` 를 부른 자리. 줄리아 impl 이름은 `!` 로 끝나므로(레지스트리 `impl`)
# 모델이 둘 중 어느 쪽으로 써도 같은 이름으로 정규화한다.
_CALL_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)!?\s*\(")
_WORD_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*!?")


def _norm(name: str) -> str:
    return name[:-1] if name.endswith("!") else name


def parse_body(text: Optional[str]) -> Tuple[List[str], str]:
    """body 텍스트 -> (원시 이름들, 파싱 방식).

    🔴 **인자는 돌려주지 않는다.** 이것이 spec §5-2-2 의 *"파라미터는 정규형에 안 들어간다"* 가
    사는 자리다 — `shift_build(dx=2.38)` 과 `shift_build(dx=2.40)` 은 같은 행동이고, 그 차이는
    파라미터 축에 있다. 이름만 뽑는 것이 그 규칙의 **구조적** 집행이다.

    방식은 둘이고 어느 쪽이었는지를 함께 돌려준다(조용히 다른 것을 세지 않기 위해):
      "calls" : `name(...)` 꼴을 찾았다.
      "names" : 괄호가 하나도 없었다 -> 알려진 원시 이름을 **등장 순서대로** 스캔했다.
                (모델이 "1. translate_whole_build then commit_respec" 처럼 쓰는 경우.)
      "empty" : 아무것도 못 찾았다.
    ⚠️ 중복은 **접지 않는다.** 같은 원시를 두 번 부르는 body 는 ψ 의 `a_cost` 가 합이라
    다른 점이고, 그것을 정규형에서 지우면 그 차이가 기록에서 사라진다.
    """
    t = text or ""
    names = [_norm(m.group(1)) for m in _CALL_RE.finditer(t)]
    if names:
        return names, "calls"
    known = set(_prim.PRIMITIVE_NAMES) | set(_prim.PREDICATE_NAMES)
    scan = [_norm(m.group(0)) for m in _WORD_RE.finditer(t)]
    names = [n for n in scan if n in known]
    return (names, "names") if names else ([], "empty")


def canon(names: Sequence[str], kind: Optional[str]) -> Tuple[Tuple[str, ...], str]:
    """spec §5-2-2 의 정규형: `(sorted(body 의 원시 이름), 대상 kind)`.

    🔴 파라미터는 들어가지 않는다 — `names` 에 애초에 인자가 없다(`parse_body` 참조).
    `kind` 가 없으면 `""` 로 둔다(빈 문자열과 `"battery"` 는 다른 정규형이다).
    """
    return (tuple(sorted(names)), kind or "")


def canon_key(c) -> str:
    """정규형의 JSON 안전 키. 응답에 실려 나가고 원장의 dict 키가 된다."""
    return "%s::%s" % ("|".join(c[0]), c[1])


def classify(names: Sequence[str]) -> Dict[str, List[str]]:
    """이름들을 네 이름공간으로 가른다. 순서를 보존한다.

    operational : `primitive_registry.json` 의 운용 원시 (ψ 가 있다)
    predicate   : 같은 파일의 순수 술어 (ψ 가 **없다** -- body 에 오면 안 된다)
    dsl         : `features_agnostic._PRIMITIVE_TABLE` 의 DSL 원시 (ReplaceAgent …)
    unknown     : 어디에도 없다 -- 오타이거나 아직 없는 원시
    """
    op, pred, dsl, unk = [], [], [], []
    for n in names:
        if n in _prim.PSI_TABLE:
            op.append(n)
        elif n in _prim.PREDICATE_NAMES:
            pred.append(n)
        elif n in _fa._PRIMITIVE_TABLE:
            dsl.append(n)
        else:
            unk.append(n)
    return {"operational": op, "predicate": pred, "dsl": dsl, "unknown": unk}


_PSI_STATS_CACHE: Dict[int, Dict[str, Any]] = {}


def psi_stats(blob=None) -> Dict[str, Any]:
    """축별 표준화 통계 + **그 통계의 출처**.

    ⚠️ ψ 축은 스케일이 제각각이다(`a_cost` 연속 · `a_scope` 정수 · 나머지 0/1). 축별 표준화
    없이 유클리드 거리를 쓰면 `a_cost` 가 거리를 독점한다. 모집단은 **운용 원시 19종의
    단일 원시 ψ 벡터**이고, 그것 말고 이 레포에 합성 tool 의 ψ 분포를 말해 주는 표본이 없다
    (첫 관측이 그 분포를 준다 -- spec §5-2-2).

    🔴 `provenance` 를 같이 내는 것이 이 함수의 절반이다. 숫자만 남기면 T6a 가 실측한 것 —
    `a_cost` 19개 중 4개만 실제 숫자에 닻이 있고 그중 둘은 ψ 충돌을 깨려고 넣은 값이며
    `a_intervenes` 는 19개 전부 1.0 이라 거리에 정보가 0 이라는 것 — 이 기록에서 사라진다.

    분산이 0 인 축은 거리에서 **빠진다**(0 으로 나눌 수 없다). 그 목록도 기록한다 —
    "축이 10개 있다"와 "거리에 실제로 기여하는 축이 몇 개다"는 다른 사실이다.
    """
    b = blob if blob is not None else _prim.REGISTRY
    key = id(b)
    if key in _PSI_STATS_CACHE:
        return _PSI_STATS_CACHE[key]
    names = sorted(_prim.psi_table(b))
    vecs = [_fa.psi([n]) for n in names]
    axes = list(_fa.PSI_AXES)
    mean, std = {}, {}
    for a in axes:
        col = [v[a] for v in vecs]
        m = sum(col) / len(col)
        mean[a] = m
        std[a] = (sum((x - m) ** 2 for x in col) / len(col)) ** 0.5
    zero = [a for a in axes if std[a] == 0.0]
    out = {
        "axes": axes,
        "mean": mean,
        "std": std,
        "zero_variance_axes": zero,
        "n_population": len(names),
        "provenance": {
            "population": "the %d operational primitives of primitive_registry.json, each as "
                          "psi([name])" % len(names),
            "source_file": "wm4spacecraft_manufacturing/core/primitive_registry.json",
            "schema_version": b.get("schema_version"),
            "statistic_used_in_distance": "per-axis population std (mean cancels in a "
                                          "difference and is recorded for audit only)",
            "machine_derived_axes": ["a_reversible", "a_consumes_spare", "a_spatial"],
            "hand_judged_axes": ["a_cost", "a_intervenes", "a_soft", "a_restores_capacity",
                                 "a_relocates_work", "a_scope"],
            "a_cost_note": "T6a measurement: of 19 a_cost values only 4 are anchored to real "
                           "numbers (SwapBattery 0.2 / ReplaceAgent 1.0 / RelocateBuild 1.5 "
                           "and the registry MACRO_COST scale); the other 15 are ordering "
                           "judgements, and 2 of those (1.2 / 1.3) exist only to break psi "
                           "collisions. a_cost is the only continuous axis, so the whole "
                           "standardisation rests on those 15 judgements.",
            "zero_variance_note": "axes with zero variance carry no information and are "
                                  "dropped from the distance; a_intervenes is 1.0 for all 19.",
            "merging": "R19: distance is RECORDED ONLY. No threshold, no merge. The first "
                       "observations are what give the distance distribution.",
        },
    }
    _PSI_STATS_CACHE[key] = out
    return out


def psi_of(names: Sequence[str]) -> Dict[str, float]:
    """운용 원시 이름들의 ψ. 술어·미등재 이름이면 `KeyError` 로 죽는다(features_agnostic)."""
    return _fa.psi(list(names))


def standardized_distance(u: Dict[str, float], v: Dict[str, float], stats) -> float:
    """축별 표준화 유클리드 거리. 분산 0 인 축은 빠진다."""
    s = 0.0
    for a in stats["axes"]:
        sd = stats["std"][a]
        if sd == 0.0:
            continue
        s += ((u[a] - v[a]) / sd) ** 2
    return s ** 0.5


class SynthesisLedger:
    """관측된 정규형의 원장. `|K|` 곡선의 저장소다 (spec §5-2-3).

        |K|(t) = 시각 t 까지 관측된 서로 다른 canon 의 개수

    포화 ⟹ 폭발이 없다(파라미터화가 흡수한다). 선형 증가 ⟹ 우려가 옳았다.
    상한은 원시 개수 n 에 대해 구조적으로 2ⁿ 인 **유계 개방 어휘**다.

    🔴 `minted == False`(= 이미 본 정규형)는 **실패가 아니다** — 이 곡선의 한 점이다.
    그래서 중복은 차단이 아니라 **측정**이고, 파라미터만 따로 쌓는다.
    """

    def __init__(self):
        self.entries: Dict[str, Dict[str, Any]] = {}
        self.order: List[str] = []

    @property
    def K(self) -> int:
        return len(self.entries)

    def observe(self, c, params: Optional[str] = None,
                tool_name: Optional[str] = None) -> bool:
        """정규형 하나를 기록한다. **새 정규형이면 True.**"""
        k = canon_key(c)
        e = self.entries.get(k)
        if e is None:
            self.entries[k] = {"primitives": list(c[0]), "kind": c[1], "count": 1,
                               "params": [params], "tool_names": [tool_name]}
            self.order.append(k)
            return True
        e["count"] += 1
        e["params"].append(params)          # 🔴 중복에서 **파라미터만** 기록한다 (spec §5-2-2 ①)
        e["tool_names"].append(tool_name)
        return False

    def reference_psis(self) -> List[Tuple[str, Dict[str, float]]]:
        """ψ 거리의 기준집합: 원장이 든 정규형 중 **ψ 가 계산되는 것들**.

        ⚠️ T1 의 세 tool(`swap_body`·`deliver_battery`·`no_intervention`)은 여기 **없다.**
        그것들은 운용 원시로 된 body 가 없고, DSL 이름공간의 ψ 를 빌려 오면 두 이름공간이
        같은 물리 행동에서 `a_reversible` 이 어긋나므로(T6a 실측) 같은 행동이 두 점으로
        보인다. 그 제외 사실을 거리 기록의 `reference` 가 함께 나른다.
        """
        out = []
        for k, e in self.entries.items():
            if not e["primitives"]:
                continue
            try:
                out.append((k, psi_of(e["primitives"])))
            except KeyError:
                continue
        return out


LEDGER = SynthesisLedger()      # 프로세스 전역 |K|. 시험은 자기 원장을 넘긴다.


# ==========================================================================================
# params 평평함
# ==========================================================================================
_SCALAR_TYPES = {"string", "number", "integer", "boolean", "null"}
_NESTING_KEYS = ("properties", "items", "$ref", "allOf", "anyOf", "oneOf", "patternProperties",
                 "additionalProperties", "prefixItems")


def params_flatness(params_text: Optional[str]) -> Tuple[Optional[bool], str]:
    """`params` JSON 스키마가 **평평한 스칼라만**인가. (판정, 사유).

    판정이 `None` 이면 **못 쟀다**(JSON 이 아니거나 모양이 다르다) — `False`("재서 어겼다")와
    섞지 않는다. 이 레포는 그 둘을 섞어 여러 번 데였다.

    받아 주는 두 모양:
      {"dx": {"type": "number"}, ...}                      (properties 만 준 것)
      {"type": "object", "properties": {"dx": {...}}}      (온전한 스키마)
    """
    if params_text is None or not str(params_text).strip():
        return None, "params is empty -- nothing to measure"
    try:
        blob = json.loads(params_text)
    except Exception as e:
        return None, "params is not JSON (%s: %s)" % (type(e).__name__, e)
    if not isinstance(blob, dict):
        return None, "params is JSON but not an object (got %s)" % type(blob).__name__
    props = blob.get("properties") if isinstance(blob.get("properties"), dict) else blob
    if not isinstance(props, dict) or not props:
        return None, "params has no property map to measure"
    bad = []
    for name, spec in props.items():
        if name in ("type", "required", "additionalProperties") and props is blob:
            continue                       # 온전한 스키마의 형제 키를 파라미터로 오독하지 않는다
        if not isinstance(spec, dict):
            bad.append("%s: not an object" % name)
            continue
        for nk in _NESTING_KEYS:
            if nk in spec:
                bad.append("%s: has %r (nested)" % (name, nk))
        t = spec.get("type")
        ts = t if isinstance(t, list) else [t]
        for one in ts:
            if one is None:
                bad.append("%s: no type" % name)
            elif one not in _SCALAR_TYPES:
                bad.append("%s: type %r is not a flat scalar" % (name, one))
    if bad:
        return False, ("nested or non-scalar params would silently break the Julia boundary "
                       "(_tool_args_dict in tools/monitor/policy.jl is a SHALLOW conversion, "
                       "so a nested value stays a JSON3.Object and breaks the "
                       "Dict{String,Any} assumption WITHOUT an error): " + "; ".join(bad))
    return True, "all %d parameters are flat scalars" % len(props)


# ==========================================================================================
# ④ 발화 · tool_minted
# ==========================================================================================
def _blank(rec_kind, expressible, ledger) -> Dict[str, Any]:
    return {"tool_minted": None,
            "synthesis_event": False, "ran": False,
            "enabled": synthesis_enabled(),
            "kind": rec_kind, "expressible": expressible,
            "K": ledger.K, "error": None, "reason": None}


def maybe_synthesize(expressible,
                     kind: Optional[str] = None,
                     state: str = "",
                     tools=None,
                     novel: Optional[str] = None,
                     must_change: Optional[str] = None,
                     ledger: Optional[SynthesisLedger] = None,
                     program=None,
                     blob=None) -> Dict[str, Any]:
    """T2 를 발화시킬지 판정하고, 켜져 있으면 실제로 합성한다.

    발화 조건은 spec §8-1 이 대체 신호로 지목한 바로 그 비율이다: **`expressible == False`**
    — 닫힌 tool 집합이 이 사건을 표현 못 한다는 신호. `None`("못 쟀다")도 `True` 도 발화가
    아니다. 그 다음에야 R13 의 플래그를 본다(맨 위 모듈 docstring 의 순서 논증).

    🔴 이 함수는 `TOOL_SYNTHESIS != "1"` 이면 **어떤 LM 도 부르지 않고, context 도 짓지 않고,
    소켓도 열지 않는다.** 게이트가 소켓을 가로채 실측한다.
    """
    led = ledger if ledger is not None else LEDGER
    rec = _blank(kind, expressible, led)

    if expressible is not False:
        rec["reason"] = ("not a firing event: expressible is %r; T2 fires only on False "
                         "(spec 8-1)" % (expressible,))
        return rec

    rec["synthesis_event"] = True
    if not synthesis_enabled():
        # 🔴 R13. `None` 이 아니라 `"disabled"` 다 — "꺼져서 안 돌았다"와 "돌았는데 아무것도
        #    안 주조했다"는 다른 사건이고, 이 레포에는 꺼진 채 성공 모양의 출력을 내는 원시가
        #    실재한다(`force_advance_stuck_carrier!` + `CARRIER_RESCUE`).
        rec["tool_minted"] = "disabled"
        rec["reason"] = ("%s != '1': synthesis is OFF by default because one firing is a "
                         "billable OpenAI call (R13)" % SYNTHESIS_ENV)
        return rec

    ctx = build_context(state=state, tools=tools, novel=novel,
                        must_change=must_change, blob=blob)
    rec["context_chars"] = len(ctx)
    prog = program if program is not None else dspy.ChainOfThought(SynthesizeTool)
    rec["ran"] = True
    try:
        pred = prog(context=ctx, question=(novel or state or ""))
    except Exception as e:
        # 다섯 번째 사건. `tool_minted` 는 None 이지만 `ran=True · error!=None` 이 그것을
        # "발화할 사건이 아니었다"(synthesis_event=False)와 가른다 — 모듈 docstring 의 표.
        rec["error"] = "%s: %s" % (type(e).__name__, e)
        rec["reason"] = "synthesis ran but the call failed; nothing was minted"
        return rec

    # ---- 출력을 통째로 보존한다. 🔴 표현 불가여도 정의는 끝까지 기록된다 (spec §5-1). --------
    for f in ("tool_name", "params", "mechanism", "body", "reach", "missing_primitive"):
        rec[f] = (getattr(pred, f, "") or "")
    rec["reasoning"] = (getattr(pred, "reasoning", "") or "")

    names, how = parse_body(rec["body"])
    cls = classify(names)
    rec["body_names"] = names
    rec["body_parse"] = how
    rec.update({"body_%s" % k: v for k, v in cls.items()})
    # `reach` 가 body 와 어긋나는가 — 강제하지 않고 **기록만** 한다.
    rec["reach_matches_body"] = (
        None if rec["reach"] not in ("composed", "needs_primitive") else
        (rec["reach"] == "composed") == (not cls["unknown"]))
    # 🔴 표현 불가인데 정의가 비어 있으면 그 사건에서 무엇이 필요했는지가 기록에 안 남는다.
    rec["missing_primitive_recorded"] = (
        None if rec["reach"] != "needs_primitive" else bool(rec["missing_primitive"].strip()))

    rec["params_flat"], rec["params_flat_detail"] = params_flatness(rec["params"])

    c = canon(names, kind)
    rec["canon"] = {"primitives": list(c[0]), "kind": c[1]}
    rec["canon_key"] = canon_key(c)

    # ---- ② ψ 근접 — **거리만 기록하고 접지 않는다** (R19). 원장에 넣기 **전에** 잰다: --------
    #      넣고 나서 재면 자기 자신과의 거리 0 이 언제나 최소가 된다.
    stats = psi_stats(blob)
    rec["psi_provenance"] = stats["provenance"]
    rec["psi_zero_variance_axes"] = stats["zero_variance_axes"]
    rec["psi"] = rec["psi_distance"] = rec["psi_nearest"] = None
    rec["psi_error"] = None
    rec["psi_reference_n"] = 0
    if cls["operational"] and not (cls["predicate"] or cls["dsl"] or cls["unknown"]):
        try:
            v = psi_of(names)
        except KeyError as e:
            rec["psi_error"] = "KeyError: %s" % e
        else:
            rec["psi"] = v
            refs = led.reference_psis()
            rec["psi_reference_n"] = len(refs)
            if refs:
                d = [(standardized_distance(v, u, stats), k) for k, u in refs]
                d.sort()
                rec["psi_distance"], rec["psi_nearest"] = d[0][0], d[0][1]
            else:
                rec["psi_error"] = ("no reference points yet: the ledger holds no canon with a "
                                    "computable psi (T1's three tools are deliberately not in "
                                    "the reference set -- see reference_psis)")
    else:
        rec["psi_error"] = (
            "psi not computed: the body is not made only of operational primitives "
            "(predicates=%r dsl=%r unknown=%r). Predicates change nothing so they have no "
            "effect descriptor; mixing the DSL namespace in would put the same physical "
            "action at two points (T6a: a_reversible disagrees across the two namespaces)."
            % (cls["predicate"], cls["dsl"], cls["unknown"]))

    minted = led.observe(c, params=rec["params"], tool_name=rec["tool_name"])
    rec["tool_minted"] = bool(minted)
    rec["K"] = led.K
    rec["canon_count"] = led.entries[rec["canon_key"]]["count"]
    rec["reason"] = ("new canon" if minted else
                     "canon already observed -- the model re-derived a behaviour it already "
                     "had; this is a point on the |K| curve, not a failure (spec 5-2-3)")
    return rec
