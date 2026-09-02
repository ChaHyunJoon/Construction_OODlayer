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
    parts += ["",
              "PRIMITIVE INVENTORY -- the alphabet a body may be composed from.",
              "Each entry states which surface it edits, what it consumes, whether it can be "
              "undone, and its full mechanism including the conditions under which it does "
              "nothing at all.",
              # 🔴 2026-09-01. Without these two lines the model **invents** a commit step at
              #    the end of the body (`commit_respec` actually came out that way). The cause
              #    was a prompt that says in four places "a re-solve must follow" while giving
              #    no primitive that performs one. Those sentences now name the harness as the
              #    subject, and this line nails it down once more.
              #    `test_body_rule_forbids_a_commit_step` guards this line.
              "BODY RULE: use ONLY names that appear in this inventory, exactly as spelled. "
              "The harness re-solves the MILP after every body, so never write a commit, "
              "re-solve, formulate, or persist step -- there is no such primitive here, and a "
              "body naming one cannot be enacted at all. If what you need is genuinely absent, "
              "do not invent a name inside the body: set reach to \"needs_primitive\" and "
              "describe it in missing_primitive."]
    parts += primitive_inventory_lines(blob)
    parts += ["",
              "PURE PREDICATES -- measurement only. Never put one in a body."]
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
