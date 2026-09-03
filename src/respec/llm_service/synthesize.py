"""T2 -- **synthesise a NEW tool** for an unfamiliar event (Plan B / T6b, spec §5).

This file does four things.

  (1) The `SynthesizeTool` signature (spec §5-1, **verbatim**).
  (2) It builds the `context` -- the physical principles of this build, the current state,
      the final goal, the novel properties of the event, what must change, the tools we
      already have, and **the primitive inventory with each primitive's mechanism**.
  (3) **Canonicalisation** of the output, ψ-distance **recording**, and the `|K|` counter.
  (4) The verdict on whether T2 fires, and the four values of `tool_minted`.

🔴 This file is the Python half only. The Julia wiring that puts `tool_minted` on a decision
row (`TOOL_LANE_KEYS` in `policy.jl`, `this_decision` in `run_demo.jl`) was **deliberately
deferred**; here the value is merely **returned** in the service response. The T6b report
points at the consumers line by line.

────────────────────────────────────────────────────────────────────────────────
🔴 R13 -- synthesis is enabled ONLY by `TOOL_SYNTHESIS=1`. OFF by default.
────────────────────────────────────────────────────────────────────────────────
One synthesis = one **billable OpenAI call** on the user's account. But when it is off it must
not quietly emit success-shaped output -- `force_advance_stuck_carrier!` in this repo is
exactly that trap (a no-op without `CARRIER_RESCUE`, yet the log looks normal). Hence:

    tool_minted == "disabled"  ->  this event WOULD have fired, but **the flag was off**
    tool_minted is None        ->  this was not a firing event (expressible != False)

🔴 **The order of the verdict is "firing condition first, flag second."** Reversed (flag
first), **every decision row** of a default run becomes `"disabled"`, and at that moment the
`expressible == false` rate (the very number spec §8-1 names as the substitute signal for the
promotion gate) can no longer be recovered from this field. In the present order, the count of
`"disabled"` IS "how many times it would have fired had we turned it on".

🔴 **The four values are not a partition.** There is a fifth event: **it ran and the LM/parse
failed.** That row has `tool_minted is None` but `synthesis_event=True · ran=True ·
error!=None`, which **distinguishes** it from "this was not a firing event"
(`synthesis_event=False`). This repo has twice already stepped on the accident of one lane's
events landing in another lane's bucket and inflating the rate (the three events of C8, the
100% vs 23% fault firing rate). Consumer rules:

    did not fire     synthesis_event == False                      -> tool_minted is None
    was switched off synthesis_event == True and ran == False      -> tool_minted == "disabled"
    ran and failed   ran == True and error is not None             -> tool_minted is None
    re-derived       ran == True and error is None                 -> tool_minted == False
    new canon        ran == True and error is None                 -> tool_minted == True

────────────────────────────────────────────────────────────────────────────────
🔴 R19 -- the ψ distance is **record-only**. It merges on no threshold whatsoever.
────────────────────────────────────────────────────────────────────────────────
The T6a measurement cut the discriminating power of this space: of the 19 `a_cost` values only
4 are anchored to real numbers, and two of those exist to break a ψ collision · `a_intervenes`
is 1.0 for all 19 (zero information in the distance) · the two namespaces disagree on
`a_reversible` for the same physical action. So this file **computes the distance and records
it only**, and does not invent a τ. The provenance of the standardisation statistics comes out
alongside them from `psi_stats()` -- keeping the numbers without the provenance would erase
those 15 judgements from the record.

────────────────────────────────────────────────────────────────────────────────
🔴 R7 -- `when_to_use` touches no prompt path whatsoever.
────────────────────────────────────────────────────────────────────────────────
It is the **answer condition**, and putting it in the prompt would mean what we measure is not
reasoning but prompt compliance (spec §6-2, the measurement at `dspy_service.py:155-165`). The
inventory render in this file **does not read** that field -- the field name occurs exactly once
in this module, in `_NEVER_RENDER` below. The gate is the **substitution-invariance** check in
`test_synthesize.py` (replace every when_to_use with a sentinel: is the render byte-identical?).
Why a 20-character sliding window cannot be run against the **original** when_to_use text of the
live registry is in that test's docstring, with the measurement.

────────────────────────────────────────────────────────────────────────────────
🔴 params must be **flat scalars only** -- this closes a trap left behind by T1.
────────────────────────────────────────────────────────────────────────────────
Julia's `_tool_args_dict` (`tools/monitor/policy.jl`, immediately below `TOOL_LANE_KEYS`) is
**shallow**. The reason it is correct today is that all three tools take a single flat `str`
argument (see that function's measurement comment). The moment a tool with nested arguments is
synthesised, that value stays a `JSON3.Object` and breaks the `Dict{String,Any}` assumption
**without an error**. This task, which cannot touch Julia, takes the **second** of the two paths
the brief offered: constrain `params` to flat scalars and catch that constraint with a gate
(`params_flatness`). ⚠️ Output that violates the constraint is **not discarded** -- it is merely
recorded with `params_flat=False`, and the definition is kept in full (spec §5-1).
"""
import json
import os
import re
import sys
from typing import Any, Dict, List, Optional, Sequence, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
# HERE = <repo>/src/respec/llm_service -> three levels up is the repo root. Same rule as
# `dspy_service.py:47-51`; it exists independently here because this module can be imported
# **before** that file (pytest collection order · a direct import from another file).
WM = os.environ.get("WM_DIR") or os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(HERE))),
    "wm4spacecraft_manufacturing")
for _d in (os.path.join(WM, "core"),):
    if _d not in sys.path:
        sys.path.append(_d)

# 🔴 The **same contract** as `dspy_service.py:44` · `tool_registry.py`, and it is independently
# needed in this file too. At `import dspy` time, dspy 3.3.0 swaps sys.modules["numpy"] for a
# lazy-import proxy, and anyone importing sklearn.ensemble afterwards re-enters through that
# proxy and dies with `numpy/_core/_methods.py:17: TypeError: data type 'bool' not understood`.
# If the collection order changes, **this file plants dspy first, on its own** -- which makes
# the order pinning in the other two files meaningless. Never delete this or move it after dspy.
import numpy, sklearn.ensemble  # noqa: F401,E401  -- pinned order: before dspy

import dspy  # noqa: E402

import features_agnostic as _fa       # noqa: E402  (psi -- takes operational primitive names, KeyError if unknown)
import primitive_registry as _prim    # noqa: E402  (registry loader. never copy-paste literals)

# 🔴 This is the **only place** in this whole module where the name `when_to_use` occurs. The
#    render functions never read that key from a primitive dict -- and the gate measures that
#    very fact as substitution invariance. It is here so the code distinguishes "forgotten"
#    from "deliberately left out".
_NEVER_RENDER = ("when_to_use",)

# ---- F5 (2026-09-02): 못 부르는 원시의 표식과, 그 표식을 지목하는 body 규칙 -----------------
# 🔴 **BODY RULE 은 한 벌이다.** 2026-09-02 까지 이 문자열이 `build_context` 와
#    `build_inventory_block` 에 **두 벌**로 복사돼 있었다 — 한쪽만 고치면 단일 agent 레인과
#    3-agent 레인이 서로 다른 규칙을 읽는데 어느 시험도 안 빨개진다(둘 다 자기 사본을 본다).
#    게이트가 두 렌더러 모두에 대해 이 상수를 요구한다.
_NOT_CALLABLE_MARK = "[NOT CALLABLE BY THE HARNESS TODAY]"

_INVENTORY_HEADER = [
    "PRIMITIVE INVENTORY -- the alphabet a body may be composed from.",
    "Each entry states which surface it edits, what it consumes, whether it can be undone, "
    "and its full mechanism including the conditions under which it does nothing at all.",
]

# 🔴 2026-09-01 의 두 문장(harness 가 재풀이의 주체다)은 그대로 둔다 — 그것이 없으면 모델이
#    body 끝에 commit 단계를 **지어낸다**(`commit_respec` 이 실제로 그렇게 나왔다).
# 🔴 2026-09-02 가 더한 것은 마지막 문장 하나다: 표식의 **귀결**. 표식만 붙이고 귀결을 안
#    적으면 모델은 그것을 경고로 읽고 그냥 쓴다.
_BODY_RULE = (
    "BODY RULE: use ONLY names that appear in this inventory, exactly as spelled. "
    "The harness re-solves the MILP after every body, so never write a commit, "
    "re-solve, formulate, or persist step -- there is no such primitive here, and a "
    "body naming one cannot be enacted at all. If what you need is genuinely absent, "
    "do not invent a name inside the body: set reach to \"needs_primitive\" and "
    "describe it in missing_primitive. "
    "An entry marked " + _NOT_CALLABLE_MARK + " is listed so you can reason about what "
    "this build can and cannot do, but the harness cannot call it: naming one anywhere in "
    "a body makes the WHOLE body unenactable, so cite it in missing_primitive instead.")

SYNTHESIS_ENV = "TOOL_SYNTHESIS"


def synthesis_enabled() -> bool:
    """R13. True only when `TOOL_SYNTHESIS=1`. **Exactly `"1"`** -- `"true"`/`"yes"` are not
    accepted: this switch opens billable calls, so a typo must not pass on leniency."""
    return os.environ.get(SYNTHESIS_ENV, "") == "1"


# ==========================================================================================
# (1) The signature -- spec §5-1 **verbatim**. Do not casually reword field names or descs.
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
# (2) context
# ==========================================================================================
# The physical principles of this build. Why a literal: this is not a registry but **the
# structure of this simulator**, and there is no machine-readable single source of truth for it.
# The evidence is annotated line by line so whoever updates it can check.
PHYSICAL_PRINCIPLES = """\
PHYSICAL PRINCIPLES OF THIS BUILD

1. SCHEDULE (a DAG). The build is a precedence graph of nodes. A node becomes active exactly
   when ALL of its predecessors are closed -- the frontier rule is pure DAG reachability, with
   no side conditions (ConstructionBots essential_tg_coponents.jl). The build is finished when
   every node is closed. Assignment edges (which robot does which slot) are chosen by a MILP.
   THE HARNESS RE-SOLVES THAT MILP AUTOMATICALLY AFTER EVERY TOOL BODY, on the graph the body
   leaves behind, with no extra constraints. So a body that edits assignment edges or edge
   weights is completed by that re-solve; it must NOT contain a commit, re-solve, or formulate
   step of its own, and this inventory deliberately contains no primitive that performs one.

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
    """Render the 19 operational primitives as prompt lines.

    🔴 Only each primitive's **`mechanism`** goes in. when_to_use is not read (R7).
    ⚠️ **The trap entries go in as they are** -- `force_advance_stuck_carrier` is a no-op
    without `CARRIER_RESCUE=1`, `rethread_robot_ids` needs PARKED, `deprioritize_agent` is void
    without a MILP re-solve. Those facts are already inside each entry's `mechanism` prose,
    which is why the mechanism goes in **in full, never truncated**. Truncate it and the
    synthesiser builds a tool that quietly does nothing.
    """
    b = blob if blob is not None else _prim.REGISTRY
    out: List[str] = []
    for p in b["primitives"]:
        # 🔴 2026-09-02 (F5). 이 알파벳은 19개를 광고하는데 harness 가 실제로 부를 수 있는
        #    것은 8개다. 표시하지 않았을 때의 대가는 실측이다: F1 직후 재측정에서 mild 레인이
        #    처음 낸 body 의 두 번째 원시가 `deprioritize_agent`(집행 불가)였고, 그 body 는
        #    `enact_minted!` 에서 `reject:unenactable` 로 **한 발도 안 굴러간다.**
        # 🔴 판정은 파이썬이 못 한다 — Julia `_enactability` 가 메서드 시그니처를 읽어 정하고
        #    레지스트리에 도장으로 실린다. 여기서는 그 도장을 읽기만 한다.
        # 🔴 도장이 **없으면 "부를 수 있음" 으로 기울지 않는다.** 부재는 "못 쟀다" 이고, 그
        #    상태에서 body 에 넣는 것은 여전히 위험하므로 보수적으로 표시하되 이유를 그렇게
        #    적는다. 부재 자체는 게이트가 빨갛게 만든다
        #    (`test_every_primitive_declares_whether_the_harness_can_call_it`).
        stamped = p.get("enactable")
        callable_ = stamped is True
        out.append("- %s   [surface=%s  reversible=%s  consumes=%s]%s" % (
            p["name"], p["surface"],
            "yes" if p["reversible"] else "NO",
            (", ".join(p["consumes"]) if p["consumes"] else "nothing"),
            "" if callable_ else "   " + _NOT_CALLABLE_MARK))
        if not callable_:
            out.append("    why not callable: %s" % (
                (p.get("unenactable_why") or "").strip()
                or "callability was never recorded for this primitive"))
        out.append("    params: %s" % _fmt_params(p["params"]))
        if p.get("preconditions"):
            out.append("    preconditions: %s" % "; ".join(p["preconditions"]))
        out.append("    mechanism: %s" % p["mechanism"])
    return out


def predicate_inventory_lines(blob=None) -> List[str]:
    """Pure predicates. **They must not go in a body** -- we tell the model so.

    Why this is needed: `features_agnostic.psi()` raises KeyError on a predicate name (and the
    message says separately "this is a predicate"). If a predicate lands in a body, the ψ
    distance in this file becomes uncomputable, and that fact is recorded as `psi_error` -- it
    does not quietly become 0.
    """
    b = blob if blob is not None else _prim.REGISTRY
    out: List[str] = []
    for q in b["predicates"]:
        out.append("- %s   [PURE PREDICATE -- reads geometry, edits nothing. It has no effect "
                   "descriptor and MUST NOT appear in a tool body.]" % q["name"])
        out.append("    mechanism: %s" % q["mechanism"])
    return out


def _tool_lines(tools) -> List[str]:
    """The tools we already have. Takes a list of `dspy.Tool` (= the output of
    `tool_registry.build_tools`).

    A tool's `desc` is that function's docstring, and that is **the only tool description the
    model reads** (once native FC is on, dspy strips the tools field from the prompt). It goes
    in here as-is too.
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
    """The body of `SynthesizeTool.context`.

    Seven blocks, in the order of the signature's desc: physical principles · current state ·
    final goal · novel properties of the event · what must change · the tools we have ·
    the primitive inventory.

    🔴 There is no path at all that reads when_to_use (R7). Gate: substitution invariance.
    🔴 It carries no answers: `min_shift_to_clear_m` (= the answer **solved** by
       `_find_min_translation`) was deleted from the prompt by T4a, and since this file takes
       the `state` string as-is it inherits that removal automatically. Neither fallback above
       writes a single line of "what to do".
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
    # 🔴 2026-09-02: 머리말도 BODY RULE 도 이제 **모듈 상수 한 벌**이다(위 `_BODY_RULE`).
    #    `build_inventory_block` 이 같은 상수를 쓴다 — 두 벌이던 시절에는 한쪽만 고쳐도
    #    어느 시험도 안 빨개졌다.
    parts += [""] + _INVENTORY_HEADER + [_BODY_RULE]
    parts += primitive_inventory_lines(blob)
    parts += ["",
              "PURE PREDICATES -- measurement only. Never put one in a body."]
    parts += predicate_inventory_lines(blob)
    return "\n".join(parts)


# ==========================================================================================
# (2-b) The 3-agent pipeline -- observe / design / compose
# ==========================================================================================
# Why (2026-08-30, the user's decision). On the single-prompt version the model answered
# `expressible: true`. That answer was **not unreasonable for the input it saw** -- `_zones_block`
# deliberately withholds `build_center`/`build_radius`/`max_shift`/`work_reach` so the oracle
# cannot leak. So the place to change is not the wording but the **decomposition of the
# reasoning**, and these three signatures are that decomposition.
#
# 🔴 Two blindnesses are the heart of the design, and the tests pin both
#    (`test_synthesize_multi.py`):
#      · agent-2 **cannot see the observation** (information bottleneck: needed to measure
#        whether the decomposition actually processed information)
#      · agent-2 **cannot see the primitives** (showing the existing vocabulary to whoever
#        designs a tool for an unfamiliar event turns the measurement from design into
#        projection onto that vocabulary)
#    The price is paid honestly: if agent-3 cannot compose it, `reach="needs_primitive"`, and
#    that `missing_primitive` is **this lane's output** (not an enacted world).


class ObserveEvent(dspy.Signature):
    """You are looking at a disruption in a running multi-robot construction build.
    Describe what this event has BROKEN -- which capabilities, reachability, or resources
    are no longer what the plan assumed. Report only what the observation supports.
    Do not propose a repair, do not name a tool, and do not guess a numeric fix."""
    context: str = dspy.InputField(desc=
        "physical principles of this build, the final goal, what is known about the event's "
        "novelty, what must change, and the decision-time observation")
    observation: str = dspy.InputField(desc="the measured state at the moment of the event")

    reasoning_log: str = dspy.OutputField(desc=
        "natural-language account of what the event broke and what is now unreachable or "
        "frozen; the ONLY account the later stages will read")


class DesignToolSpec(dspy.Signature):
    """You are given an account of what a disruption broke. Decide whether the existing
    recovery vocabulary can express a response, and specify the tool that IS needed.
    Specify it freely: name the parameters the tool must take for its mechanism to be
    well-defined, even if you do not know what implements it. You are not shown an
    inventory on purpose -- do not restrict the design to operations you can name."""
    context: str = dspy.InputField(desc=
        "physical principles of this build, the final goal, what is known about the event's "
        "novelty, and what must change")
    reasoning_log: str = dspy.InputField(desc="what the event broke")
    existing_vocabulary: str = dspy.InputField(desc=
        "the response options this event was actually offered")
    ungrounded_feedback: str = dspy.InputField(desc=
        "empty on the first attempt. On a redesign it names the parameters of your previous "
        "specification that the world cannot supply -- each of them selects among behaviours "
        "instead of carrying a value. Replace them by committing to one mechanism.")
    composer_feedback: str = dspy.InputField(desc=
        "empty on the first attempt. On a redesign it reports that the stage which builds "
        "your tool out of primitive operations could not realise the mechanism you "
        "specified, and which capability it found missing. The operations it holds are "
        "deliberately not shown to you.")

    expressible: bool = dspy.OutputField(desc=
        "true if the existing vocabulary above can already express an adequate response; "
        "false if a new tool is required")
    tool_name: str = dspy.OutputField()
    params: str = dspy.OutputField(desc=
        "JSON schema of the parameters the tool must take")
    mechanism: str = dspy.OutputField(desc=
        "exactly what this tool changes and how; what it consumes; preconditions; whether "
        "it can be undone. Be exhaustive -- this is the specification the next stage builds.")


class ComposeToolBody(dspy.Signature):
    """You are given a tool specification and a fixed inventory of primitive operations.
    Write the tool's BODY as an ordered sequence of primitive calls from the inventory.
    You never write code. If the inventory cannot express the specified mechanism, say so
    and name the missing primitive precisely -- that answer is as valuable as a body."""
    spec: str = dspy.InputField(desc=
        "physical principles of this build, the final goal, what the event broke, and the "
        "tool to build: name, parameter schema, mechanism")
    inventory: str = dspy.InputField(desc=
        "the alphabet a body may be composed from, with each primitive's full mechanism")

    body: str = dspy.OutputField(desc="ordered list of primitive calls, with arguments")
    reach: str = dspy.OutputField(desc=
        '"composed" if every primitive in the body exists in the inventory; '
        '"needs_primitive" otherwise')
    missing_primitive: str = dspy.OutputField(desc=
        "if reach is needs_primitive: name, edit surface (sched|scene_tree|env_param|"
        "physical), params, preconditions, reversibility, what it consumes, and WHY no "
        "composition over the inventory can substitute for it. Empty otherwise.")


# ---- The task-side blocks, per stage ------------------------------------------------------
# 🔴 2026-09-02. `NOVEL PROPERTIES` and `WHAT MUST CHANGE` were missing from BOTH multi-agent
#    context builders: agent-2 was specifying a tool without ever being told what counts as
#    success. They go in now -- but NOT by reusing the single-agent strings. Those contain the
#    deictics "the observation above" and "the existing tools below", and for agent-2 neither
#    referent is in its context (the observation is the bottleneck, the vocabulary is a separate
#    input field). A pointer to something that is not there reads as a missing block, so each
#    stage gets the wording that is true where it is rendered.
# 🔴 These strings must name NO primitive and NO predicate -- `test_design_context_names_no_primitive`
#    checks the whole registry against agent-2's context.
_NOVEL_OBSERVE = """\
NOVEL PROPERTIES OF THE EVENT
The monitor did not classify this event. Its novelty is exactly what the observation reports --
no event-type label was applied, and no field named after a known failure mode was populated.
Do not assume it is one of the failure modes this build has met before."""

_NOVEL_DESIGN = """\
NOVEL PROPERTIES OF THE EVENT
The monitor did not classify this event -- no event-type label was applied, and no field named
after a known failure mode was populated. The account you are given is all that is known about
it, and the response options you are shown separately were built for failure modes this event
was never matched to."""

_MUST_CHANGE_OBSERVE = """\
WHAT MUST CHANGE
The schedule must reach a state in which every remaining node can close. The observation is the
ONLY evidence of what currently prevents that; nothing here tells you which edit is correct, and
no minimum repair has been computed for you."""

# 🔴 2026-09-02, R2 실측. 이 문단이 없을 때 agent-2 는 **두 레인 모두에서 disturbance 자체를
#    되돌리는** 도구를 설계했다: zone 에서는 존을 옮기거나 지우는 `ExclusionZoneModifier`,
#    battery 에서는 물리적으로 존재하지 않는 "일시적 배터리 증폭". agent-3 는 둘 다 조합하지
#    못해 `needs_primitive` 로 끝났고, 그 `missing_primitive` 는 **알파벳에 답이 있는데도**
#    "없다" 고 적었다.
#
# 🔴 이것이 왜 정답 누수가 **아닌가.** 여기 적는 것은 "무엇을 하라" 가 아니라 **"무엇이
#    불변인가"** 다 — `PHYSICAL_PRINCIPLES` 의 "depot spares are scarce and are NOT
#    replenished" 와 같은 범주의 세계 사실이다. 어느 편집 표면을 쓰라고도, 어느 원시를
#    쓰라고도 말하지 않는다. 게이트가 그것을 지킨다:
#    `test_the_invariant_clause_names_no_primitive_and_no_oracle_field` 가 레지스트리
#    전수 + 오라클 필드 + 매크로/사건 이름을 이 문자열에 대고 훑는다.
#
# ⚠️ 대가(공개): 이 문단은 "undo 는 답이 아니다" 라고 말하므로, 모델이 설계를 포기하고
#    `expressible=True` 로 도망갈 여지를 만든다. 그래서 마지막 문장이 **대안의 모양**을
#    명시한다 — 어휘가 충분하다고 선언하라는 것이 아니라, disturbance 가 선 채로 빌드가
#    무엇을 달리 할지 적으라는 것. 이 대가가 실현되는지는 재측정의 `expressible` 이 답한다.
_INVARIANT_DESIGN = """\
WHAT MAY NOT CHANGE
The disruption is exogenous. It is a fact of the world at this moment -- not an object your tool
is allowed to edit, move, relax, or delete. A restriction that has been imposed on a region, a
charge level that has fallen, a body that has failed: your tool does not get to revoke any of
them, and none of the edit surfaces described above exposes them as something a recovery may
write to. Your tool may only change what the build DOES while they stand.
If the only repair you can imagine is undoing the disruption, that is not a repair, and naming
the power to undo it as a missing primitive is not a finding. Specify instead what the build
must do differently while the disruption stands."""

_MUST_CHANGE_DESIGN = """\
WHAT MUST CHANGE
The schedule must reach a state in which every remaining node can close. The account you are
given is the ONLY evidence of what currently prevents that; nothing here tells you which edit is
correct, and no minimum repair has been computed for you.

""" + _INVARIANT_DESIGN


def build_observe_context(state: str, principles: Optional[str] = None,
                          goal: Optional[str] = None,
                          novel: Optional[str] = None,
                          must_change: Optional[str] = None) -> str:
    """agent-1's context. The observation enters the pipeline **only through here**."""
    return "\n".join([principles or PHYSICAL_PRINCIPLES, "",
                      goal or FINAL_GOAL, "",
                      novel or _NOVEL_OBSERVE, "",
                      must_change or _MUST_CHANGE_OBSERVE, "",
                      "CURRENT STATE (decision-time observation, produced without "
                      "classifying the event)", state or "(no observation was supplied)"])


def build_design_context(reasoning_log: str, principles: Optional[str] = None,
                         goal: Optional[str] = None,
                         novel: Optional[str] = None,
                         must_change: Optional[str] = None) -> str:
    """agent-2's context.

    🔴 It takes no `state` -- that is the bottleneck. 🔴 It carries no inventory -- that is the
    blindness. Add a parameter to this function that lets either one in and
    `test_synthesize_multi.py` goes red.
    """
    return "\n".join([principles or PHYSICAL_PRINCIPLES, "",
                      goal or FINAL_GOAL, "",
                      novel or _NOVEL_DESIGN, "",
                      must_change or _MUST_CHANGE_DESIGN, "",
                      "WHAT THE EVENT BROKE (an account produced from the measured state)",
                      reasoning_log or "(no account was produced)"])


def build_compose_context(spec: Dict[str, Any], reasoning_log: str = "", blob=None,
                          principles: Optional[str] = None,
                          goal: Optional[str] = None) -> str:
    """agent-3's spec string. The inventory travels in the signature's own separate field.

    🔴 2026-09-02. This used to be four lines -- name, parameters, mechanism -- against a
    ~25,000-character inventory, a task-to-alphabet ratio of about 1:29. agent-3 was composing
    a body without being told what event the tool is for, that there are five edit surfaces, or
    that the harness re-solves the MILP by itself. The principles, the goal and agent-1's
    account go in for that reason.
    🔴 The account goes in HERE rather than as a fourth signature field so it is rendered once
    and so the leak guards stay on exactly the three prompt builders (contract (C) of
    `test_synthesize_multi.py`). The bottleneck is unaffected: what crosses is agent-1's prose
    account, never the raw observation.
    """
    return "\n".join([
        principles or PHYSICAL_PRINCIPLES,
        "",
        goal or FINAL_GOAL,
        "",
        "WHAT THE EVENT BROKE (an account produced from the measured state)",
        reasoning_log or "(no account was produced)",
        "",
        "TOOL TO BUILD",
        "  name: %s" % (spec.get("tool_name") or "(unnamed)"),
        "  parameters: %s" % (spec.get("params") or "(none specified)"),
        "  mechanism: %s" % (spec.get("mechanism") or "(none specified)"),
    ])


def build_inventory_block(blob=None) -> str:
    """The alphabet agent-3 reads. Uses **the same renderer** as `build_context` -- two copies
    and only one of them grows.

    🔴 2026-09-02: that sentence was only half true until today. `primitive_inventory_lines`
    was indeed shared, but the header and the BODY RULE were **literal copies** here and in
    `build_context` -- edit one and the single-agent lane and the 3-agent lane read different
    rules, with no test going red (each asserted against its own copy). Both now come from
    `_INVENTORY_HEADER` / `_BODY_RULE`.
    """
    parts = list(_INVENTORY_HEADER) + [_BODY_RULE]
    parts += primitive_inventory_lines(blob)
    parts += ["", "PURE PREDICATES -- measurement only. Never put one in a body."]
    parts += predicate_inventory_lines(blob)
    return "\n".join(parts)

# ==========================================================================================
# (3) canonicalisation · ψ · |K|
# ==========================================================================================
# Where `name(` or `name!(` is called. Julia impl names end in `!` (the registry's `impl`), so
# whichever of the two the model writes normalises to the same name.
_CALL_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)!?\s*\(")
_WORD_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*!?")


def _norm(name: str) -> str:
    return name[:-1] if name.endswith("!") else name


def parse_body(text: Optional[str]) -> Tuple[List[str], str]:
    """body text -> (primitive names, how it was parsed).

    🔴 **Arguments are not returned.** This is where spec §5-2-2's *"parameters are not part of
    the canonical form"* lives -- `shift_build(dx=2.38)` and `shift_build(dx=2.40)` are the same
    behaviour, and their difference lies on the parameter axis. Extracting names only is the
    **structural** enforcement of that rule.

    There are two ways, and which one it was is returned alongside (so we never quietly count
    something else):
      "calls" : found `name(...)` forms.
      "names" : there were no parentheses at all -> scanned for known primitive names **in
                order of appearance**. (For when the model writes "1. translate_whole_build
                then restage_all_blocked".)
                🔴 The scan only picks up **names inside the alphabet**. Names outside it
                vanish silently, whereas the parenthesised form (`_CALL_RE`) does not consult
                the registry and so comes out and gets rejected downstream as an "unknown
                primitive" -- the same intent forks on notation.
      "empty" : nothing was found.
    ⚠️ Duplicates are **not collapsed.** A body that calls the same primitive twice is a
    different point because ψ's `a_cost` is a sum, and erasing that in the canonical form would
    erase the difference from the record.
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
    """The canonical form of spec §5-2-2: `(sorted(primitive names of the body), target kind)`.

    🔴 Parameters do not go in -- `names` has no arguments in it to begin with (see
    `parse_body`). If there is no `kind` it stays `""` (the empty string and `"battery"` are
    different canonical forms).
    """
    return (tuple(sorted(names)), kind or "")


def canon_key(c) -> str:
    """A JSON-safe key for the canonical form. It rides out in the response and becomes the
    dict key of the ledger."""
    return "%s::%s" % ("|".join(c[0]), c[1])


def classify(names: Sequence[str]) -> Dict[str, List[str]]:
    """Split names into four namespaces. Order is preserved.

    operational : operational primitives of `primitive_registry.json` (they have a ψ)
    predicate   : pure predicates from the same file (they have **no** ψ -- must not be in a body)
    dsl         : DSL primitives of `features_agnostic._PRIMITIVE_TABLE` (ReplaceAgent …)
    unknown     : nowhere to be found -- either a typo or a primitive that does not exist yet
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
    """Per-axis standardisation statistics + **the provenance of those statistics**.

    ⚠️ The ψ axes have wildly different scales (`a_cost` continuous · `a_scope` integer · the
    rest 0/1). Use a Euclidean distance without per-axis standardisation and `a_cost` monopolises
    it. The population is **the single-primitive ψ vectors of the 19 operational primitives**,
    and there is no other sample in this repo that speaks to the ψ distribution of synthesised
    tools (the first observations are what give that distribution -- spec §5-2-2).

    🔴 Emitting `provenance` alongside is half of what this function is for. Keep the numbers
    only and what T6a measured disappears from the record -- that of the 19 `a_cost` values only
    4 are anchored to real numbers, that two of those exist to break a ψ collision, and that
    `a_intervenes` is 1.0 for all 19 and therefore carries zero information in the distance.

    Zero-variance axes are **dropped** from the distance (you cannot divide by zero). That list
    is recorded too -- "there are 10 axes" and "this many axes actually contribute to the
    distance" are different facts.
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
    """The ψ of operational primitive names. Dies with `KeyError` on a predicate or an
    unregistered name (features_agnostic)."""
    return _fa.psi(list(names))


def standardized_distance(u: Dict[str, float], v: Dict[str, float], stats) -> float:
    """Per-axis standardised Euclidean distance. Zero-variance axes drop out."""
    s = 0.0
    for a in stats["axes"]:
        sd = stats["std"][a]
        if sd == 0.0:
            continue
        s += ((u[a] - v[a]) / sd) ** 2
    return s ** 0.5


class SynthesisLedger:
    """The ledger of observed canonical forms. It is the store of the `|K|` curve (spec §5-2-3).

        |K|(t) = the number of distinct canons observed up to time t

    Saturation ⟹ there is no explosion (parameterisation absorbs it). Linear growth ⟹ the
    worry was right. The upper bound is a **bounded open vocabulary**, structurally 2ⁿ in the
    number of primitives n.

    🔴 `minted == False` (= a canonical form already seen) is **not a failure** -- it is a point
    on this curve. So a duplicate is a **measurement**, not a rejection, and only the parameters
    are accumulated separately.
    """

    def __init__(self):
        self.entries: Dict[str, Dict[str, Any]] = {}
        self.order: List[str] = []

    @property
    def K(self) -> int:
        return len(self.entries)

    def observe(self, c, params: Optional[str] = None,
                tool_name: Optional[str] = None) -> bool:
        """Record one canonical form. **True if it is a new one.**"""
        k = canon_key(c)
        e = self.entries.get(k)
        if e is None:
            self.entries[k] = {"primitives": list(c[0]), "kind": c[1], "count": 1,
                               "params": [params], "tool_names": [tool_name]}
            self.order.append(k)
            return True
        e["count"] += 1
        e["params"].append(params)          # 🔴 on a duplicate, record **the parameters only** (spec §5-2-2 ①)
        e["tool_names"].append(tool_name)
        return False

    def reference_psis(self) -> List[Tuple[str, Dict[str, float]]]:
        """The reference set for the ψ distance: those canonical forms in the ledger **whose ψ
        is computable**.

        ⚠️ T1's three tools (`swap_body`·`deliver_battery`·`no_intervention`) are **not** here.
        They have no body made of operational primitives, and borrowing a ψ from the DSL
        namespace would put the same behaviour at two points, because the two namespaces
        disagree on `a_reversible` for the same physical action (T6a measurement). The
        `reference` of the distance record carries that exclusion fact alongside.
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


LEDGER = SynthesisLedger()      # process-global |K|. Tests pass their own ledger.


# ==========================================================================================
# params flatness
# ==========================================================================================
_SCALAR_TYPES = {"string", "number", "integer", "boolean", "null"}
_NESTING_KEYS = ("properties", "items", "$ref", "allOf", "anyOf", "oneOf", "patternProperties",
                 "additionalProperties", "prefixItems")


def params_flatness(params_text: Optional[str]) -> Tuple[Optional[bool], str]:
    """Is the `params` JSON schema **flat scalars only**? (verdict, reason).

    A verdict of `None` means **we could not measure** (it is not JSON, or the shape differs) --
    do not mix that with `False` ("we measured it and it violates"). This repo has been burned
    several times by conflating the two.

    Two accepted shapes:
      {"dx": {"type": "number"}, ...}                      (properties only)
      {"type": "object", "properties": {"dx": {...}}}      (a full schema)
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
            continue                       # do not misread a full schema's sibling keys as parameters
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
# (4) firing · tool_minted
# ==========================================================================================
def _blank(rec_kind, expressible, ledger) -> Dict[str, Any]:
    return {"tool_minted": None,
            "synthesis_event": False, "ran": False,
            "enabled": synthesis_enabled(),
            "kind": rec_kind, "expressible": expressible,
            "K": ledger.K, "error": None, "reason": None}


def _finish_record(rec, kind, led, blob):
    """Take a `rec` whose six output fields are filled and finish it: parse, psi, canon, ledger.

    🔴 The single-agent lane (`maybe_synthesize`) and the 3-agent lane (`synthesize_multi`) use
    **the same function**. Kept as two copies, only one of them grows, and then the two lanes'
    records quietly come to mean different things -- the failure shape this repo already walked
    into with `train_kinds` and `require_vocab`.
    """
    names, how = parse_body(rec["body"])
    cls = classify(names)
    rec["body_names"] = names
    rec["body_parse"] = how
    rec.update({"body_%s" % k: v for k, v in cls.items()})
    # Does `reach` disagree with the body -- **recorded only**, never enforced.
    rec["reach_matches_body"] = (
        None if rec["reach"] not in ("composed", "needs_primitive") else
        (rec["reach"] == "composed") == (not cls["unknown"]))
    # 🔴 If it is inexpressible and the definition is empty, the record loses what was needed
    #    in that event.
    rec["missing_primitive_recorded"] = (
        None if rec["reach"] != "needs_primitive" else bool(rec["missing_primitive"].strip()))

    rec["params_flat"], rec["params_flat_detail"] = params_flatness(rec["params"])

    c = canon(names, kind)
    rec["canon"] = {"primitives": list(c[0]), "kind": c[1]}
    rec["canon_key"] = canon_key(c)

    # ---- (2) ψ proximity -- **the distance is recorded, nothing is folded** (R19). Measure it
    #      **before** putting the entry in the ledger: measure it after, and the distance 0 to
    #      itself is always the minimum. -------------------------------------------------------
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


def maybe_synthesize(expressible,
                     kind: Optional[str] = None,
                     state: str = "",
                     tools=None,
                     novel: Optional[str] = None,
                     must_change: Optional[str] = None,
                     ledger: Optional[SynthesisLedger] = None,
                     program=None,
                     blob=None) -> Dict[str, Any]:
    """Decide whether to fire T2, and actually synthesise if it is switched on.

    The firing condition is exactly the rate spec §8-1 names as the substitute signal:
    **`expressible == False`** -- the signal that the closed tool set cannot express this event.
    Neither `None` ("we could not measure it") nor `True` fires. Only then do we look at R13's
    flag (the ordering argument is in the module docstring at the top).

    🔴 If `TOOL_SYNTHESIS != "1"`, this function **calls no LM, builds no context, and opens no
    socket.** The gate measures that by intercepting the socket.
    """
    led = ledger if ledger is not None else LEDGER
    rec = _blank(kind, expressible, led)

    if expressible is not False:
        rec["reason"] = ("not a firing event: expressible is %r; T2 fires only on False "
                         "(spec 8-1)" % (expressible,))
        return rec

    rec["synthesis_event"] = True
    if not synthesis_enabled():
        # 🔴 R13. `"disabled"`, not `None` -- "it did not run because it was off" and "it ran and
        #    minted nothing" are different events, and this repo really does contain a primitive
        #    that emits success-shaped output while switched off
        #    (`force_advance_stuck_carrier!` + `CARRIER_RESCUE`).
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
        # The fifth event. `tool_minted` is None, but `ran=True · error!=None` separates it from
        # "this was not a firing event" (synthesis_event=False) -- the table in the module docstring.
        rec["error"] = "%s: %s" % (type(e).__name__, e)
        rec["reason"] = "synthesis ran but the call failed; nothing was minted"
        return rec

    # ---- Preserve the output whole. 🔴 Even when inexpressible, the definition is recorded in
    #      full (spec §5-1). ------------------------------------------------------------------
    for f in ("tool_name", "params", "mechanism", "body", "reach", "missing_primitive"):
        rec[f] = (getattr(pred, f, "") or "")
    rec["reasoning"] = (getattr(pred, "reasoning", "") or "")

    return _finish_record(rec, kind, led, blob)


# ==========================================================================================
# (4-b) The groundability gate -- between agent-2 and agent-3
# ==========================================================================================
# 🔴 Why (2026-08-30, measured). On the live version agent-2 put `resolution_strategy` into its
#    specification, and **that one parameter alone** made agent-3 give up on composing. But it
#    is not a value, it is a **choice of mechanism** -- the design decision was deferred, not
#    made, and no implementation can meaningfully receive it.
#
# 🔴 **This is not written as a check against the alphabet.** The reduced alphabet has no
#    scene_tree surface at all, so `blocked_areas`, `zone` and `resolution_strategy` would all
#    three come back as "no primitive takes this" -- it cannot tell them apart. And feeding the
#    alphabet back here would leak agent-2's blindness.
#
# ⟹ The single criterion is **is it grounded in the world**. This is the SAME axis as the
#    derived-param channel: only a parameter the harness can supply is legitimate.

# Names that refer to an object in the world. The harness can confirm they exist, or derive
# them from `env`.
# 🔴 Written as a literal on purpose: derive it from the registry and the alphabet leaks into
#    this verdict, and the moment the alphabet shrinks a perfectly good world reference flips to
#    "ungrounded" (which is exactly why this gate must not be an alphabet check).
_WORLD_REFERENT_NAMES = frozenset({
    "agent", "agents", "assembly_id", "assembly_ids", "blocked_areas", "faulted", "spare",
    "pool", "robot", "robots", "slot_v", "target", "zone", "zones", "zone_key", "zone_keys",
})

# Names that select a mechanism. They carry not a value but **a choice among behaviours that
# have not been implemented yet**.
_MECHANISM_CHOICE_SUFFIXES = ("_strategy", "_method", "_approach", "_mode", "_policy",
                              "_algorithm", "_scheme", "_tactic",
                              # 🔴 2026-09-02, R2 실측. agent-2 가 zone 레인에서 낸
                              #    `"action": "string"`(= move/resize/remove 중 택1)을 이
                              #    표가 **못 잡았고**, 그래서 재설계가 0회 돌고 agent-3 이
                              #    미정 명세를 조합하지 못해 `needs_primitive` 로 끝났다.
                              #    이 셋은 앞의 여덟과 같은 범주다 — 값이 아니라 행동의 선택.
                              "_action", "_operation", "_command")

# 맨이름 형태. 🔴 **접미사에서 유도한다.** 예전에는 `("strategy","method","approach","mode")`
# 라는 손으로 든 두 번째 목록이 아래 판정식 안에 박혀 있었고, 그것이 이미 접미사 여덟 중
# 넷만 덮고 있었다(`policy`·`algorithm`·`scheme`·`tactic` 은 맨이름으로 오면 안 잡혔다).
# 두 벌은 갈린다 — 이 레포가 반복해 밟은 모양이라 진실원을 하나로 접는다.
_MECHANISM_CHOICE_BARE = tuple(s.lstrip("_") for s in _MECHANISM_CHOICE_SUFFIXES)

_SCALAR_JSON_TYPES = frozenset({"integer", "number", "boolean", "null"})


def ungrounded_params(params_text):
    """The **names** of the parameters that are not grounded. `None` if unreadable (which is
    not the same thing as an empty list).

    One of three ways to pass:
      (1) the harness can derive it from `env`         -> `_WORLD_REFERENT_NAMES`
      (2) it refers to an object in the world          -> the same table
      (3) it is a value a callee can receive           -> scalar, or a closed string enum

    🔴 `None` ("could not measure") and `[]` ("measured and passed") are never mixed. This repo
    has been burned by mixing those two more than once, and mixing them here would record a run
    whose params failed to parse as "no groundability problem", so the redesign never fires.
    """
    d, shape = _params_view(params_text)
    if shape == "unparseable":
        return None
    bad = []
    for name, spec in d.items():
        if name in _WORLD_REFERENT_NAMES:
            continue
        # Schema shape: read the declaration -- scalar, or carrying an enum, means grounded.
        if isinstance(spec, dict):
            t = spec.get("type")
            ts = t if isinstance(t, list) else [t]
            if any(isinstance(x, str) and x in _SCALAR_JSON_TYPES for x in ts):
                continue
            if spec.get("enum"):
                continue
        # Value shape: look at the type of the value.
        elif not isinstance(spec, str):
            continue                      # number, boolean, list -- not a mechanism choice
        # What is left is a free string with no enum. If the name selects a mechanism, it is
        # not grounded.
        if name.endswith(_MECHANISM_CHOICE_SUFFIXES) or name in _MECHANISM_CHOICE_BARE:
            bad.append(name)
    return sorted(bad)


def _params_view(params_text):
    """Read `params` as `(dict, shape)`. The Python counterpart of Julia's `normalize_params`.

    ⚠️ Two copies and only one of them grows. Here we return **both values and schemas as they
    are** -- this gate has to judge declarations as well as values, so unlike the Julia side it
    does not blank the schema out.
    """
    if params_text is None:
        return {}, "unparseable"
    if isinstance(params_text, dict):
        return params_text, "values"
    s = str(params_text).strip()
    if not s:
        return {}, "unparseable"
    try:
        blob = json.loads(s)
    except Exception:
        return {}, "unparseable"
    if not isinstance(blob, dict):
        return {}, "unparseable"
    props = blob.get("properties")
    if isinstance(props, dict):
        return props, "schema"
    return blob, "values"


# ==========================================================================================
# (4-c) The composer's verdict travels back to agent-2 -- F2
# ==========================================================================================
# 🔴 Why (2026-09-02, measured on the F5 run). agent-3 answered `reach="needs_primitive"` on a
#    body it had **already composed**: `release_pending_assignments(agent=R4)` was in the body,
#    and the only thing it declared missing was the **priority ordering agent-2 had asked for**
#    ("... can release tasks, but it does not consider task priority"). Nothing in the pipeline
#    read that verdict. The redesign loop above fires on ungrounded **parameters** only, so a
#    specification that is perfectly grounded and simply unrealisable ends the run.
#
# 🔴 Why the feedback is REDACTED (the user's decision, 2026-09-02). agent-3's prose **names the
#    inventory** -- the sentence above quotes `release_pending_assignments` by name. Handing it
#    to agent-2 verbatim would end contract (B) of `test_synthesize_multi.py` (agent-2 must not
#    see the alphabet), and from that point on this lane no longer measures design, it measures
#    projection onto the vocabulary. So every registry name is replaced by a neutral placeholder
#    before agent-2 reads it; what survives is the part that carries the signal ("the ordering
#    you asked for is not implementable"). The names that were removed are **recorded**, so a
#    run where the redaction destroyed the feedback can be told apart from one where it removed
#    nothing at all.
_REDACTED_NAME = "[an operation the composer already has]"


def _inventory_names(blob=None) -> List[str]:
    """Every name agent-2 must not read -- primitives **and** pure predicates.

    🔴 Read from the registry, never a literal list: the leak guards in
    `test_synthesize_multi.py` iterate the same registry, so a primitive added tomorrow is
    redacted and asserted on without either side being edited.
    """
    b = blob if blob is not None else _prim.REGISTRY
    return [p["name"] for p in b["primitives"]] + [q["name"] for q in b["predicates"]]


def redact_inventory_names(text: Optional[str], blob=None) -> Tuple[str, List[str]]:
    """Replace every inventory name in `text` with `_REDACTED_NAME`. Returns (text, names hit).

    🔴 Longest name first. `release_pending_assignments` and a hypothetical
    `release_pending` would otherwise leave the tail of the longer name behind as a bare
    fragment -- half a name is still a name.
    🔴 The Julia impls end in `!`, and the model quotes both spellings, so the trailing `!` is
    swallowed by the same match rather than left dangling.
    """
    s = text or ""
    hits: List[str] = []
    for name in sorted(set(_inventory_names(blob)), key=len, reverse=True):
        pat = re.compile(r"(?<![A-Za-z0-9_])%s!?(?![A-Za-z0-9_])" % re.escape(name))
        s, n = pat.subn(_REDACTED_NAME, s)
        if n:
            hits.append(name)
    return s, hits


# 🔴 The last sentence is not decoration. Without it a model that genuinely cannot re-specify
#    invents *something* to fill the field, and "the gap is real" becomes unobservable. Asking
#    it to repeat the specification unchanged makes that answer a **measurable** one
#    (`spec_changed_by_feedback`).
_COMPOSE_FEEDBACK = (
    "A composer holding a fixed inventory of primitive operations tried to realise your "
    "specification and could not. It reported that this capability is missing from "
    "everything it has:\n\n%s\n\n"
    "The operations it does have are withheld from you on purpose -- do not try to guess "
    "their names. Re-specify the tool so that its mechanism no longer depends on the "
    "capability above: either drop the part of the mechanism that requires it, or commit to "
    "a different mechanism that reaches the same goal. If no such re-specification is "
    "possible, repeat your previous specification unchanged.")

_SPEC_FIELDS = ("tool_name", "params", "mechanism")
_BODY_FIELDS = ("body", "reach", "missing_primitive")


# ==========================================================================================
# (5) The 3-agent pipeline itself
# ==========================================================================================
MULTI_AGENT_ENV = "SYNTH_MULTI_AGENT"


def multi_agent_enabled() -> bool:
    """True only when `SYNTH_MULTI_AGENT=1`. **Exactly `"1"`**.

    🔴 Two reasons the default is off. (a) This lane turns one billable call per decision into
    three. (b) The comparison against the old (single-agent) version only holds if the default
    path does not change -- if the new lane quietly becomes the default, earlier runs cannot be
    put in the same table.
    """
    return os.environ.get(MULTI_AGENT_ENV, "") == "1"


def run_synthesis(expressible, kind=None, state="", tools=None, ledger=None,
                  programs=None, blob=None) -> Dict[str, Any]:
    """The single door the service calls. One flag decides which lane runs.

    🔴 The multi lane **does not use** the caller's `expressible`. On the single-agent version
    that value was a tool argument of the decision agent (omitted by the model = `None` = "could
    not measure"); in the multi version agent-2 emits it as its own output field. Mixing the two
    sources computes the same-named rate over different denominators -- a place this repo has
    already stood, with `macro_tool_agree`.
    """
    if multi_agent_enabled():
        return synthesize_multi(state=state, tools=tools, kind=kind, ledger=ledger,
                                programs=programs, blob=blob)
    return maybe_synthesize(expressible=expressible, kind=kind, state=state, tools=tools,
                            ledger=ledger, blob=blob)


def synthesize_multi(state: str,
                     tools=None,
                     kind: Optional[str] = None,
                     ledger: Optional[SynthesisLedger] = None,
                     programs: Optional[Dict[str, Any]] = None,
                     blob=None) -> Dict[str, Any]:
    """observe -> design -> compose. The record has **the same shape** as the single-agent lane.

    🔴 The source of the firing verdict changes. On the single version `expressible` was a **tool
    argument of the decision agent** (`dspy_service.py`), and if the model omitted that argument
    it became `None` ("could not measure") and synthesis quietly did not run. Here agent-2 emits
    it as **its own output field** -- the omission risk disappears and the verdict has one source.

    ⚠️ **The price is recorded right here.** The `expressible=false` rate is now not a measurement
    but a **construction**: the pipeline decomposes the reasoning so that this answer comes out.
    So reading this lane's result as "the model noticed on its own that its vocabulary was short"
    is **false**. What this lane measures is "given the right decomposition, does it design the
    right tool", and those are different questions.

    🔴 If agent-2 answers `expressible=True`, **agent-3 is not called** -- it saves one billable
    call, and it separates "this was not an event to synthesise for" from "we synthesised and
    minted nothing" in the record.
    """
    led = ledger if ledger is not None else LEDGER
    rec = _blank(kind, None, led)
    rec["stages"] = []

    if not synthesis_enabled():
        rec["tool_minted"] = "disabled"
        rec["reason"] = ("%s != '1': synthesis is OFF by default because one firing is a "
                         "billable OpenAI call (R13)" % SYNTHESIS_ENV)
        return rec

    progs = programs or {}
    observe = progs.get("observe") or dspy.ChainOfThought(ObserveEvent)
    design = progs.get("design") or dspy.ChainOfThought(DesignToolSpec)
    compose = progs.get("compose") or dspy.ChainOfThought(ComposeToolBody)

    # ---- agent-1: observation -> what broke ------------------------------------------------
    octx = build_observe_context(state)
    rec["observe_context_chars"] = len(octx)
    try:
        p1 = observe(context=octx, observation=state or "")
    except Exception as e:
        rec["error"] = "observe: %s: %s" % (type(e).__name__, e)
        rec["reason"] = "stage 1 (observe) failed; nothing was minted"
        return rec
    rec["reasoning_log"] = (getattr(p1, "reasoning_log", "") or "")
    rec["stages"].append("observe")

    # ---- agent-2: the log -> what tool is needed (+ expressible) ---------------------------
    # 🔴 `state` is not passed (the bottleneck). 🔴 Nor is the inventory (the blindness). The
    #    tests pin both.
    dctx = build_design_context(rec["reasoning_log"])
    rec["design_context_chars"] = len(dctx)
    vocab = "\n".join(_tool_lines(tools))

    def _design(feedback="", composer_feedback=""):
        return design(context=dctx, reasoning_log=rec["reasoning_log"],
                      existing_vocabulary=vocab, ungrounded_feedback=feedback,
                      composer_feedback=composer_feedback)

    try:
        p2 = _design()
    except Exception as e:
        rec["error"] = "design: %s: %s" % (type(e).__name__, e)
        rec["reason"] = "stage 2 (design) failed; nothing was minted"
        return rec
    rec["stages"].append("design")

    ex = getattr(p2, "expressible", None)
    # 🔴 Not wrapped in `bool()` -- `bool("False") is True`, so a false True would be recorded.
    rec["expressible"] = ex if isinstance(ex, bool) else None
    for f in ("tool_name", "params", "mechanism"):
        rec[f] = (getattr(p2, f, "") or "")

    # ---- the groundability gate: if the world cannot supply a parameter, redesign **once** --
    # 🔴 Only the parameter **names** are fed back. Leak the alphabet and agent-2's blindness
    #    breaks, and that blindness is the premise of "design a tool for an unfamiliar event".
    # 🔴 The redesign runs **at most once**. If it does not converge we record and move on -- an
    #    infinite loop is the worst outcome, and a second failure is itself data
    #    (`ungrounded_after_redesign`).
    rec["redesigned"] = False
    rec["ungrounded_after_redesign"] = None
    bad = ungrounded_params(rec["params"])
    rec["ungrounded_params"] = bad
    if bad:
        fb = ("These parameters of your previous specification cannot be supplied by the "
              "world -- each names a choice among behaviours rather than a value: %s. "
              "Commit to one mechanism and specify it directly." % ", ".join(bad))
        try:
            p2b = _design(fb)
        except Exception as e:
            rec["error"] = "design(redesign): %s: %s" % (type(e).__name__, e)
            rec["reason"] = "stage 2 redesign failed; nothing was minted"
            return rec
        rec["stages"].append("design")
        rec["redesigned"] = True
        ex = getattr(p2b, "expressible", None)
        rec["expressible"] = ex if isinstance(ex, bool) else rec["expressible"]
        for f in ("tool_name", "params", "mechanism"):
            rec[f] = (getattr(p2b, f, "") or "")
        # 🔴 `ungrounded_params` keeps **what was caught the first time**. Overwrite it when the
        #    redesign succeeds and the fact that the gate fired disappears from the record, and
        #    the gate's effect can no longer be counted afterwards. Whether it survived is
        #    carried separately by the two fields below.
        again = ungrounded_params(rec["params"])
        rec["ungrounded_params_after"] = again
        rec["ungrounded_after_redesign"] = bool(again)

    if rec["expressible"] is not False:
        rec["reason"] = ("not a firing event: agent-2 reported expressible=%r; the pipeline "
                         "fires only on False" % (rec["expressible"],))
        return rec
    rec["synthesis_event"] = True
    rec["ran"] = True

    # ---- agent-3: the specification -> a body ----------------------------------------------
    spec = {k: rec[k] for k in ("tool_name", "params", "mechanism")}
    try:
        p3 = compose(spec=build_compose_context(spec, rec["reasoning_log"], blob),
                     inventory=build_inventory_block(blob))
    except Exception as e:
        rec["error"] = "compose: %s: %s" % (type(e).__name__, e)
        rec["reason"] = "stage 3 (compose) failed; nothing was minted"
        return rec
    rec["stages"].append("compose")
    for f in _BODY_FIELDS:
        rec[f] = (getattr(p3, f, "") or "")
    rec["reasoning"] = (getattr(p3, "reasoning", "") or "")

    # ---- (F2) agent-3 -> agent-2: the composer's verdict, redacted, **once** ---------------
    # 🔴 Fires on `needs_primitive` **only**, and only when the definition is non-empty. Any
    #    other `reach` (including a malformed one) is not worth two more billable calls, and
    #    "we could not read the verdict" must not look like "the verdict was acted on".
    # 🔴 At most one round trip, for the same reason the groundability loop is capped: a loop
    #    that does not converge is the worst outcome, and a second failure is itself data.
    # 🔴 `expressible` is NOT overwritten here. It is the firing verdict of this event and it
    #    has already fired; a second answer to the same question is recorded beside it
    #    (`expressible_after_recompose`) so the rate keeps one denominator.
    rec["recomposed"] = False
    rec["compose_feedback"] = None
    rec["compose_feedback_redacted"] = None
    rec["recompose_skipped"] = None
    rec["recompose_error"] = None
    rec["spec_changed_by_feedback"] = None
    rec["spec_changed_fields"] = None
    rec["expressible_after_recompose"] = None
    rec["ungrounded_params_after_recompose"] = None

    if rec["reach"] == "needs_primitive" and rec["missing_primitive"].strip():
        first = {f: rec[f] for f in _SPEC_FIELDS + _BODY_FIELDS}
        for f, v in first.items():
            rec[f + "_first"] = v          # the first attempt survives whatever happens below
        red, hits = redact_inventory_names(rec["missing_primitive"], blob)
        rec["compose_feedback"] = _COMPOSE_FEEDBACK % red
        rec["compose_feedback_redacted"] = hits
        try:
            p2c = _design(composer_feedback=rec["compose_feedback"])
        except Exception as e:
            rec["recompose_error"] = "design(recompose): %s: %s" % (type(e).__name__, e)
        else:
            rec["stages"].append("design")
            ex2 = getattr(p2c, "expressible", None)
            rec["expressible_after_recompose"] = ex2 if isinstance(ex2, bool) else None
            spec2 = {f: (getattr(p2c, f, "") or "") for f in _SPEC_FIELDS}
            if not (spec2["tool_name"].strip() or spec2["mechanism"].strip()):
                # 🔴 Do not spend the second compose call on an empty specification, and do not
                #    leave the record half-and-half (spec from attempt 2, body from attempt 1).
                rec["recompose_skipped"] = ("the redesign returned no specification; the first "
                                            "attempt stands")
            else:
                rec.update(spec2)
                # 🔴 Which field moved, not just "something moved" (measured 2026-09-02):
                #    on the mild lane the redesign rewrote the mechanism prose to claim it no
                #    longer needs the missing capability and left `params` **byte-identical**.
                #    A single boolean calls that a change, and the record can then no longer
                #    tell a real re-specification from an assertion of compliance.
                rec["spec_changed_fields"] = [f for f in _SPEC_FIELDS
                                              if spec2[f].strip() != first[f].strip()]
                rec["spec_changed_by_feedback"] = bool(rec["spec_changed_fields"])
                rec["ungrounded_params_after_recompose"] = ungrounded_params(rec["params"])
                try:
                    p3b = compose(spec=build_compose_context(spec2, rec["reasoning_log"], blob),
                                  inventory=build_inventory_block(blob))
                except Exception as e:
                    rec["recompose_error"] = "compose(recompose): %s: %s" % (type(e).__name__, e)
                    rec.update(first)      # all six go back -- never a spliced record
                else:
                    rec["stages"].append("compose")
                    for f in _BODY_FIELDS:
                        rec[f] = (getattr(p3b, f, "") or "")
                    rec["reasoning"] = (getattr(p3b, "reasoning", "") or "")
                    rec["recomposed"] = True

    return _finish_record(rec, kind, led, blob)
