"""T2 -- **synthesise a NEW tool** for an unfamiliar event (Plan B / T6b, spec §5).

🔴 2026-09-03 (D5 · D7 · D8). The **primitive inventory is gone.** There is no
`primitive_registry` any more: the vocabulary is generated at runtime, so this file no longer
renders an alphabet, no longer parses a body against one, and no longer computes a ψ distance
over one. With the inventory went the **single-agent lane** (`SynthesizeTool` ·
`maybe_synthesize` · `build_context`) -- it could not run without a registry, and keeping a lane
that cannot run is a comparison arm that only looks like one. The deletion list is in
`docs/superpowers/specs/2026-09-03-generated-primitive-synthesis-design.md`.

This file does three things.

  (1) The 3-agent pipeline (observe / design / compose) and its prompt blocks.
  (2) **Canonicalisation** of the output and the `|K|` counter.
  (3) The verdict on whether T2 fires, and the four values of `tool_minted`.

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

    tool_minted == "disabled"  ->  the flag was off, so the pipeline never ran
                                  🔴 NOT "this event would have fired" -- see the 09-03 note below
    tool_minted is None        ->  it did not fire, or it fired and minted nothing, **or we
                                  refused to spend on it** (G1, 2026-09-03). `None` is not one
                                  event; `refused` and `ran` are what tell those apart, and the
                                  rules table below is the normative way to index them.

🔴 **The order of the verdict was "firing condition first, flag second."** Reversed (flag
first), **every decision row** of a default run becomes `"disabled"`, and at that moment the
`expressible == false` rate (the very number spec §8-1 names as the substitute signal for the
promotion gate) can no longer be recovered from this field.

⚠️ **2026-09-03 -- that ordering no longer holds, and the reading it licensed is now false.**
It belonged to the deleted single-agent lane, where `expressible` arrived as a caller argument
and could be judged before spending anything. On the surviving 3-agent lane the firing verdict
is **agent-2's own output field**, so it does not exist until the pipeline has already run --
which means `synthesize_multi` must check the flag first and returns `"disabled"` with
`synthesis_event=False`. ⟹ **Do not read the count of `"disabled"` as "how many times it would
have fired".** With the flag off, that number is "how many decisions there were", and the
`expressible == false` rate is simply not observable without paying for it.

🔴 **The values are not a partition, and `synthesis_event` no longer separates the buckets.**
This repo has twice already stepped on the accident of one lane's events landing in another
lane's bucket and inflating the rate (the three events of C8, the 100% vs 23% fault firing
rate), so the rules below are normative for consumers -- index by them, not by intuition.

⚠️ **2026-09-03: the old table said "was switched off -> `synthesis_event == True` and
`ran == False`". That is now FALSE and it collided two buckets.** `synthesize_multi` cannot set
`synthesis_event` before it knows agent-2's answer, and with the flag off agent-2 is never
called -- so a switched-off row carries `synthesis_event == False` **and**
`tool_minted == "disabled"` together, which the old table's first row read as "did not fire".

🔴 **The key that separates "did not fire" from "was switched off" is now `enabled`** (the
record's own field, stamped from `synthesis_enabled()` when the record is created), and
equivalently `tool_minted == "disabled"`. It is NOT `synthesis_event`.

🔴 **The table lives in code, as `CONSUMER_RULES` below.** What follows is the same nine rows
spelled out for a human, and `test_synthesis_record_contract.py` asserts the two do not fork --
one source of truth, because this repo has been burned three times by the same fact living in
two places. Every row's condition is **sufficient on its own**: exactly one of them matches any
record `synthesize_multi` returns, and the same file drives every exit path to prove it.

⚠️ **2026-09-03 (fix round 2): "re-derived" and "new canon" used to carry byte-identical
conditions** (`ran == True and error is None and body_names != []`) and opposite outcomes. The
fact that actually separates them is the **ledger novelty of the canon key**, and the record
carries it as `canon_count` (1 = this record is the first of its canonical form). It is in the
conditions now; without it a consumer indexing by this table cannot tell the two apart.

⚠️ **2026-09-03 (R3): those two conditions left a hole.** `body_names != []` with `canon_count`
absent or `0` matched **no** row at all -- "re-derived" wants `> 1` and "new canon" wants `== 1`.
A normative table with a hole is the failure mode this table was rewritten to remove, so the
third case is a row of its own now ("canon count unmeasured"), and the three are read through
**one** helper (`_canon_count`) so they cannot drift apart again.

    was switched off  enabled == False
                      (synthesis_event == False · ran == False · error is None · stages == []
                       · refused is None -- the G1 guard never ran)
                                                              -> tool_minted == "disabled"
    refused           enabled == True and refused is a str
                      (G1: the compose stage would have been handed no interface. NOTHING was
                       billed -- stages == [] · ran == False · error is None)
                                                              -> tool_minted is None
    a stage failed    enabled == True and refused == False and ran == False
                      and error is not None
                      (observe / design / redesign died; the verdict never existed)
                                                              -> tool_minted is None
    did not fire      enabled == True and refused == False and ran == False
                      and error is None
                      (agent-2 answered expressible != False)  -> tool_minted is None
    ran and failed    ran == True and error is not None
                      (the compose stage died)                 -> tool_minted is None
    ran, no body      ran == True and error is None and body_names == []
                      (see the Task 8 note below; agent-3 declining -- `needs_primitive` --
                       lands here, and `ran == True` is what separates it from "refused")
                                                              -> tool_minted is None
    re-derived        ran == True and error is None and body_names != []
                      and canon_count > 1                     -> tool_minted == False
    new canon         ran == True and error is None and body_names != []
                      and canon_count == 1                    -> tool_minted == True
    canon count unmeasured
                      ran == True and error is None and body_names != []
                      and canon_count is absent or < 1
                      (🔴 R3. `_finish_record` writes `canon_count` from the ledger, where it
                       is >= 1 by construction -- so absent or 0 means **the ledger never
                       observed this record**, e.g. a row written by a producer that does not
                       keep one. That is "could not measure", which is `None`, and NOT the
                       `False` of "we measured, and the model re-derived". Unreachable today
                       only because the `body_names` pin holds; Task 8 opens it)
                                                              -> tool_minted is None

⚠️ Records written **before 2026-09-03** carry no `refused` key at all. Absent is not `False`:
it means the guard did not exist yet, and such a row cannot be indexed by the two rows that
mention `refused`. Read the lane's date before pooling old rows with new ones.

🔴 **`ran == True` implies `synthesis_event == True` and vice versa** on this lane -- they are
set on the same line. Keep reading both anyway: a future lane may separate them, and a consumer
that silently depends on the coincidence is how the C8 accident happened.

✅ **Task 8 (2026-09-03) opened the last two rows.** `body_names` was pinned to `[]`
(R-BODYNAMES) because agent-3 had no name to fill it with; now agent-3 (`WriteToolImpl`) writes
`impl_name`, and `body_names` is `[impl_name]`. A kind's records no longer all collapse onto one
canonical form, so "already observed" is a fact about the tool again and `tool_minted` can be
`True`/`False`, not only `None`. **`|K|` is a curve now** -- it counts behaviours, not just kinds.

────────────────────────────────────────────────────────────────────────────────
🔴 R19 (2026-09-03) -- the ψ distance is **gone**, not merely record-only.
────────────────────────────────────────────────────────────────────────────────
ψ was a vector over the 19 operational primitives of the deleted registry, and the
standardisation population was those same 19. With the registry gone there is no population and
no axis table, so `psi_stats` · `psi_of` · `standardized_distance` · `reference_psis` and every
`psi*` field of the record went with it. 🔴 The fields are **removed, not nulled**: a `psi` key
that is always `None` would read as "we could not measure it" on a lane where the quantity does
not exist at all, and this repo has been burned by exactly that conflation.

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
import sys
from collections import namedtuple
from typing import Any, Dict, List, Optional, Sequence, Tuple, Union

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

import world_interface as WI  # noqa: E402  -- Task 8: agent-3 이 받는 세계 인터페이스의 렌더러

# 🔴 2026-09-03. `import features_agnostic as _fa` 와 `import primitive_registry as _prim` 은
#    여기 있었다. `primitive_registry` 는 삭제됐고(그 순간 이 모듈의 import 가 죽어 서비스
#    전체가 못 떴다), `_fa` 는 ψ 하나에만 쓰였는데 ψ 가 통째로 사라졌다. 어느 쪽도 되살리지
#    말 것 — 알파벳은 이제 런타임에 생성되고, 파일에서 읽는 어휘는 없다.

SYNTHESIS_ENV = "TOOL_SYNTHESIS"


def synthesis_enabled() -> bool:
    """R13. True only when `TOOL_SYNTHESIS=1`. **Exactly `"1"`** -- `"true"`/`"yes"` are not
    accepted: this switch opens billable calls, so a typo must not pass on leniency."""
    return os.environ.get(SYNTHESIS_ENV, "") == "1"


# ==========================================================================================
# (1) The shared prompt blocks
# ==========================================================================================
# 🔴 2026-09-03 (D8). `class SynthesizeTool(dspy.Signature)` stood here -- the single-agent
#    lane's whole signature, whose `context` field advertised "the PRIMITIVE INVENTORY with each
#    primitive's mechanism". There is no inventory to advertise, so the signature is gone and so
#    is the lane it drove. The 3-agent signatures below are the only ones left.
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
   step of its own, and the alphabet a body is composed from deliberately contains no
   primitive that performs one.

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


# 🔴 2026-09-03 (D5). `_fmt_params` · `primitive_inventory_lines` · `predicate_inventory_lines`
#    stood here and rendered `primitive_registry.json` into prompt lines. The registry is gone.
#    Nothing in this file reads an alphabet from a file any more; do not rebuild one.


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


# 🔴 2026-09-03 (D8). `_NOVEL_FALLBACK` · `_MUST_CHANGE_FALLBACK` · `build_context` stood here.
#    They existed for exactly one caller -- `SynthesizeTool.context` of the single-agent lane --
#    and their last two blocks were the inventory render. Both are gone. The 3-agent lane has
#    its own three context builders below, each worded for where it is actually rendered.


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


# 🔴 2026-09-03 (F8), 실측이 계기. 09-03 런2 에서 두 레인 다 agent-3 이 `needs_primitive`
#    를 냈고, 없던 것은 인벤토리 이해가 아니라 **agent-2 가 고른 기전**이었다(zone: 수직
#    lift — 인벤토리는 수평 이동뿐 / mild: 특정 대체 로봇 지정 + 우선순위 조정). agent-2 는
#    인벤토리를 일부러 못 보므로(계약 B), 기전을 고르게 두는 한 그 선택은 어휘 밖으로 나간다.
#
# 🔴 그때까지 agent-2 를 미는 문장 셋이 **전부 같은 방향**이었다 — 이 필드 설명의 "Be
#    exhaustive", 접지 게이트의 "Commit to one mechanism", F2 의 "commit to a different
#    mechanism". "효과를 적고 기전은 강제될 때만 골라라" 라고 말하는 자리는 없었다. 셋이
#    **이 한 문자열을 공유한다** — 세 벌로 두면 갈리고, 갈리면 서로를 지운다.
_EFFECT_NOT_MECHANISM = (
    "Specify the REQUIRED EFFECT: the difference between the world before and after the tool "
    "runs, stated over the objects the account above already mentions. Fix a mechanism only "
    "where the physics leaves no alternative; where more than one way of producing that effect "
    "would do, state the effect and say that the way is open.")


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
        "what this tool changes; what it consumes; preconditions; whether it can be undone. "
        + _EFFECT_NOT_MECHANISM)


# ==========================================================================================
# 🔴 Task 8 (2026-09-03). agent-3 이 조합기에서 **Julia 구현 작성자**로 바뀐다.
# ==========================================================================================
# 이 자리에는 "DO NOT RUN A PAID SYNTHESIS BEFORE TASK 8" 경고와 `ComposeToolBody` 가 있었다 --
# 인벤토리 없이 "인벤토리에서 조합하라" 고 시키는 거짓 프롬프트였다. `WriteToolImpl` 은 그
# 거짓을 안 든다: 알파벳이 아니라 **세계 인터페이스**(타입·필드·이미 있는 함수·호출 규약)를
# 받고, 조합이 아니라 **코드를 쓴다.** `compose_interface()` 가 이제 그 인터페이스를 실제로
# 채워 넣으므로(아래) 이 자리부터는 살아 있는 프롬프트다.
class WriteToolImpl(dspy.Signature):
    """You are given a tool specification and the schema and function signatures of a
    running multi-robot construction simulator. WRITE THE JULIA IMPLEMENTATION of the
    specified tool as a single function. You are not given a catalogue of ready-made
    operations -- there is none. Read the world's types and the functions the module
    already has, and write the code that produces the specified effect."""
    spec: str = dspy.InputField(desc=
        "physical principles of this build, the final goal, what the event broke, and the "
        "tool to build: name, parameter schema, mechanism")
    world_interface: str = dspy.InputField(desc=
        "the world's types and fields, the functions the module already has, and the hard "
        "requirements your function must satisfy to be callable")

    # 🔴 **출력 순서는 계약이다** (2026-09-03 B1). 첫 유료 런에서 응답이 `params` 한가운데서
    #    잘렸다 — 그때의 순서는 `impl_name · impl_code · params · calls · surface ·
    #    reversible · wrote` 였고, 값싼 스칼라 넷이 **가장 긴 필드 뒤에** 있었다.
    #
    #    ⚠️ 정직하게: **순서만으로는 잘림이 구제되지 않는다.** DSPy 의 JSONAdapter 는 선언된
    #    출력 필드가 하나라도 없으면 `AdapterParseError` 를 던지므로(dspy 3.3.0 소스 직독:
    #    `AdapterParseError(..., parsed_result=...)`), 어느 순서든 잘리면 그 단계는 죽고
    #    기록에는 `stages == [...,'design']` 만 남는다. 잘림을 실제로 막는 것은 위
    #    `MAX_TOKENS` 이고, 이 순서가 사는 이유는 그 다음이다:
    #      (1) 예산이 그래도 모자란 판에서 **먼저 완성되는 것**이 판정에 필요한 값이 된다.
    #          `wrote` 는 F2 되먹임의 트리거이고, `impl_name` 은 Julia 경계의 미끼이며,
    #          `surface`·`reversible` 은 등록 행의 나머지 전부다 — 넷 다 한 줄짜리다.
    #      (2) `impl_code` 를 `params`·`calls` **앞**에 둔다. 그 둘은 코드에서 **유도되는**
    #          값이라(키워드 스키마 · 이 사건에서 쓸 인자) 코드보다 먼저 내라고 하면 모델은
    #          시그니처를 확정하기 전에 그것을 약속해야 한다. 이 브랜치가 재는 단 하나의
    #          측정(D6)이 바로 그 body 의 품질이므로 그 의존 순서는 뒤집지 않는다.
    #      (3) 실제로 잘린 그 판에서 `impl_code` 는 **완전했다**(잘린 것은 `params` 였다) —
    #          즉 이 순서였다면 그 응답은 여덟 필드 중 일곱까지 갔다.
    #    🔴 `impl_code` 를 맨 앞으로 되돌리지 말 것: 그러면 잘림이 스칼라 넷을 통째로 먹는다.
    wrote: bool = dspy.OutputField(desc="false if you could not write an implementation")
    impl_name: str = dspy.OutputField(desc="the Julia function name; must end with `!`")
    surface: str = dspy.OutputField(desc="which world surface this edits")
    reversible: bool = dspy.OutputField(desc="can this be undone")
    needs: str = dspy.OutputField(desc=
        "a capability your body required that you could not find in the world interface; "
        "empty string if none")
    impl_code: str = dspy.OutputField(desc=
        "exactly one `function <impl_name>(env; k=<default>, ...) ... end` and nothing else")
    params: str = dspy.OutputField(desc="JSON schema of the keyword arguments")
    calls: List[Dict[str, Any]] = dspy.OutputField(desc=
        'the arguments to use for THIS event: [{"primitive": "<impl_name>", '
        '"args": {<keyword>: <value>}}]')


# ==========================================================================================
# D17 -- 거절 사유 되먹임. agent-3 에게 **한 번** 더 묻는다.
# ==========================================================================================
# 🔴 이것은 엔드포인트가 아니라 **채널**이다. `impl_rejected_why` 는 여기가 생기기 전까지
#    `tools/monitor/enact.jl` 안에만 있었고 파이썬으로 돌아오는 길이 없었다 — 즉 경계가
#    "무엇이 왜 거절됐는가" 를 정확히 알면서 그것을 쓴 당사자에게 말할 방법이 없었다.
#    `WriteToolImpl` 과 **별개의 시그니처**인 이유: 저쪽은 "빈 종이에서 써라" 이고 이쪽은
#    "이 한 가지를 고쳐라" 다. 하나로 합치면 프롬프트가 두 과제를 동시에 시키게 되고,
#    D6 이 재려는 것(첫 시도의 품질)과 이 채널이 재려는 것(되먹임이 무엇을 고치는가)이
#    같은 숫자로 뭉개진다.
class RewriteToolImpl(dspy.Signature):
    """Your previous Julia implementation was REJECTED before it ran. You are given the
    exact rejection reason. Fix that one problem and return the corrected implementation.
    Change nothing else. The same hard requirements still apply."""
    spec: str = dspy.InputField(desc="the tool specification you were given")
    world_interface: str = dspy.InputField(desc=
        "the world's types and fields, the functions the module already has, and the hard "
        "requirements your function must satisfy to be callable")
    # 🔴 **`impl_code` 라고 부를 수 없다.** dspy 시그니처는 pydantic 모델이라 한 이름이
    #    입력이면서 동시에 출력일 수 없고, 둘 다 선언하면 **에러 없이 뒤엣것만 남는다.**
    #    브리프의 코드 블록이 정확히 그랬고, 실측하면 대가가 둘이었다(2026-09-04):
    #      (1) 입력 `impl_code` 가 통째로 사라져 시그니처가
    #          `(spec, world_interface, impl_rejected_why -> ...)` 로 해소됐다 —
    #          **agent-3 이 고쳐야 할 코드를 못 본다.** 이 채널의 존재 이유가 없어진다.
    #      (2) 출력 순서가 `impl_code, wrote, impl_name, …` 로 뒤집혔다. 입력 선언이 그
    #          슬롯을 먼저 잡기 때문이다 — `WriteToolImpl` 이 굵은 빨강으로 "맨 앞으로
    #          되돌리지 말 것" 이라고 적은 바로 그 순서다(잘림이 스칼라 넷을 먹는다).
    #    출력 이름 `impl_code` 는 전선 계약이라(줄리아가 `f.impl_code` 로 읽는다) 못 바꾼다.
    #    그러므로 **입력**을 개명한다.
    rejected_impl_code: str = dspy.InputField(desc="the implementation that was rejected")
    impl_rejected_why: str = dspy.InputField(desc=
        "the exact reason it was rejected -- fix this and only this")

    # 🔴 출력 순서는 `WriteToolImpl` 과 **같은 계약**이다(그 자리의 긴 근거를 여기 안 베낀다):
    #    값싼 스칼라가 먼저, `impl_code` 가 `params`·`calls` 앞. 잘림이 스칼라 넷을 먹지 않게.
    wrote: bool = dspy.OutputField(desc="false if you cannot fix it")
    impl_name: str = dspy.OutputField(desc="the Julia function name; must end with `!`")
    surface: str = dspy.OutputField(desc="which world surface this edits")
    reversible: bool = dspy.OutputField(desc="can this be undone")
    impl_code: str = dspy.OutputField(desc=
        "exactly one `function <impl_name>(env; k=<default>, ...) ... end` and nothing else")
    params: str = dspy.OutputField(desc="JSON schema of the keyword arguments")
    calls: List[Dict[str, Any]] = dspy.OutputField(desc=
        'the arguments to use for THIS event: [{"primitive": "<impl_name>", '
        '"args": {<keyword>: <value>}}]')


def rewrite_impl(*, tool_name, spec, impl_name, impl_code, impl_rejected_why,
                 blob=None, program=None):
    """agent-3 을 **한 번** 더 돌려 거절을 고치게 한다.

    🔴 **절대 안 던진다.** 이 경로에서 새는 예외는 Julia 쪽 집행부가 기록 대신 예외로
       끝나게 하고, 호출자는 세계 상태를 알 방법을 잃는다.
    🔴 삼상: `wrote` 는 `None`("못 쟀다") · `False`("못 고치겠다") · `True`.

    🔴 **재시도 상한은 여기가 아니라 호출자(Julia)가 지킨다** — 이 함수는 상태가 없고,
       한 번 부르면 한 번 묻는다. 상한이 하나인 것은 `enact.jl` 의 구조(두 번째 거절은
       `_reject_malformed` 로 **즉시 반환**)가 보장한다.

    ⚠️ `tool_name` 은 받아만 두고 프롬프트에 안 싣는다. 이름은 `impl_code` 의 시그니처와
       `spec` 안에 이미 두 번 들어 있고, 세 번째 사본을 만들면 셋이 갈릴 자리가 생긴다.
       그래도 인자로 받는 이유는 전선 계약(`RewriteRequest`)이 그것을 나르기 때문이다.
    """
    out = {"wrote": None, "impl_name": None, "impl_code": None, "params": None,
           "calls": None, "surface": None, "reversible": None, "error": None,
           "rewrite_of_why": impl_rejected_why}
    try:
        # 🔴 브리프는 `prog = program or dspy.ChainOfThought(...)` 를 `try` **밖**에 뒀다.
        #    그 한 줄이 이 함수에서 유일하게 보호되지 않는 실제 호출이었다(시그니처 해석·
        #    어댑터 구성이 거기서 돈다). "절대 안 던진다" 가 구조로 참이어야 하므로 안으로
        #    옮긴다 — 측정되는 경로는 하나도 안 바뀐다(가짜 program 은 이 줄을 건너뛴다).
        prog = program or dspy.ChainOfThought(RewriteToolImpl)
        p = prog(spec=spec, world_interface=compose_interface(blob),
                 rejected_impl_code=impl_code, impl_rejected_why=impl_rejected_why)
    except Exception as e:                      # noqa: BLE001 -- 위 규약
        out["error"] = "rewrite: %s: %s" % (type(e).__name__, e)
        return out
    try:
        w = getattr(p, "wrote", None)
        out["wrote"] = w if isinstance(w, bool) else None
        out["impl_name"] = getattr(p, "impl_name", None) or None
        out["impl_code"] = strip_code_fence(getattr(p, "impl_code", None) or "") or None
        # 🔴 2026-09-04 실측 정정. 브리프는 `getattr(p, "params", None) or None` 로 **날것**
        #    을 실었다. 그런데 `RewriteToolImpl.params` 는 `str` 이고, 이 값은 경계를 건너
        #    `register_minted_primitive!(params = ...)` 로 **그대로** 들어간다 — 그 가드는
        #    `AbstractDict` 를 요구한다(`enact.jl` 의 `reject:params_not_an_object:`).
        #    즉 되먹임이 성공해도 고친 body 가 **우리 쪽 직렬화 때문에** 거절되고,
        #    기록에는 "agent-3 이 또 실패했다" 로 남는다 — 이 채널이 재려는 바로 그 수치를
        #    오염시킨다. 본 경로(`_finish_record`)는 `params_object` 로 파싱해서 건넨다.
        #    **같은 정규화기를 쓴다** — 두 벌을 만들지 않는다(판정 R17: 정규화는 파이썬이).
        out["params"] = params_object(getattr(p, "params", None))
        out["calls"] = normalize_calls(getattr(p, "calls", None))
        out["surface"] = getattr(p, "surface", None) or None
        rv = getattr(p, "reversible", None)
        out["reversible"] = rv if isinstance(rv, bool) else None
    except Exception as e:                      # noqa: BLE001
        # 🔴 **접두어가 다르다.** 응답을 못 받은 것(`rewrite:`)과 받아 놓고 못 읽은 것
        #    (`rewrite_read:`)은 처방이 다른 사건이다 — 하나로 뭉개면 프로바이더를
        #    탓하면서 우리 파서를 고치지 않게 된다. 여기까지 왔으면 `wrote` 는 이미
        #    갱신됐을 수도 있으므로 삼상을 "못 쟀다" 로 되돌린다.
        out["wrote"] = None
        out["error"] = "rewrite_read: %s: %s" % (type(e).__name__, e)
    return out


# ---- The task-side blocks, per stage ------------------------------------------------------
# 🔴 2026-09-02. `NOVEL PROPERTIES` and `WHAT MUST CHANGE` were missing from BOTH multi-agent
#    context builders: agent-2 was specifying a tool without ever being told what counts as
#    success. They go in now -- but NOT by reusing the single-agent strings. Those contain the
#    deictics "the observation above" and "the existing tools below", and for agent-2 neither
#    referent is in its context (the observation is the bottleneck, the vocabulary is a separate
#    input field). A pointer to something that is not there reads as a missing block, so each
#    stage gets the wording that is true where it is rendered.
# 🔴 These strings must name NO implementation function and NO predicate.
# ✅ 2026-09-03 (Task 10): **the gate is back, with a different population.** It used to
#    enumerate `syn._prim` (the 19-name registry), which D5 deleted -- the test then died
#    with AttributeError before asserting anything, and a red test is not a gate. It now
#    enumerates the **147 method names in `world_interface.json`**
#    (`test_synthesize_multi.py::_impl_names`), which is the live vocabulary agent-3 is
#    legitimately handed and agent-2 must not be. Measured at the time of the swap: zero
#    false positives against these strings, and the detector is proved to fire by a
#    planted-name control (`test_the_leak_population_is_not_empty_and_the_detector_fires`).
# 🔴 Do not read this as "contract (B) is alive". Contract (B) -- hiding the alphabet from
#    agent-2 -- is **abolished** (D5, controller ruling R13), and the recompose block below
#    says so where it sends the feedback raw. What survives is narrower and is a property of
#    *these strings*: a prompt builder must not teach agent-2 an implementation name. The
#    design's actual protection for the withheld capabilities is that they are absent from
#    `world_interface.json` altogether, pinned by
#    `test_the_withheld_capabilities_are_absent_from_the_rendered_interface`.
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

# ---- F7 (2026-09-02): 명세자에게의 분업 ---------------------------------------------------
# 🔴 왜 (F2 런의 실측). agent-2 와 agent-3 이 **같은 것**을 없다고 지목했다. agent-2 는
#    "속도·전하·우선순위·에너지비용을 동시에 고려해 최적 배정을 찾는" 도구를 명세했고,
#    agent-3 의 WHY 는 *"The inventory lacks a primitive that can optimize task allocation
#    based on multiple parameters"* 였다. 둘 다 맞다 — 그런 원시는 없다. **MILP 가 그
#    일을 하기 때문이다.** 두 agent 가 harness 자신을 없는 원시로 지목하고 있었다.
#
# 🔴 그리고 agent-2 는 그 사실을 **이미 읽는다**(실측): `PHYSICAL_PRINCIPLES` §1 의
#    "THE HARNESS RE-SOLVES THAT MILP AUTOMATICALLY AFTER EVERY TOOL BODY" 가 그 컨텍스트에
#    들어 있다. 없던 것은 **명세자에게의 귀결**이다 — 그 문단의 결론 문장은 *body* 작성자
#    에게 말하고("a body that edits assignment edges ... is completed by that re-solve"),
#    게다가 "this inventory" 라는, agent-2 의 문맥에 **없는 것을 가리키는 지시어**를 달고
#    있었다(위에서 같이 고쳤다 — 그 대가는 단일 agent 레인의 프롬프트도 바이트가 바뀐다는
#    것이고, 그 문장은 어느 렌더에서나 참인 형태로만 바뀌었다).
#
# 🔴 **탈출로를 막지 않는다 (사용자 결정, 2026-09-02).** "그러니 기존 어휘로 충분하다고
#    답하지 말라" 류의 문장을 여기 넣으면 이 개입의 대가가 **관측 불가능해진다.** 대가는
#    `expressible` **한 필드로** 드러나야 한다: 모델이 "그 최적화가 자동이면 새 도구는
#    필요 없다" 로 도망가면 그 답은 `expressible=True` 로 나오고, agent-3 는 안 불리며
#    (`synthesis_event=False`) 그 사건은 기록에서 "발화 아님" 으로 남는다.
#    ⟹ **이 문단은 세계만 서술하고 답을 서술하지 않는다.** 그 규칙을 게이트가 어휘로
#    강제한다(`test_the_division_clause_describes_the_world_not_the_answer`).
#
# ⚠️ F1 과 같은 범주다: "무엇을 하라" 가 아니라 **누가 무엇을 하는가**라는 세계 사실이고,
#    어느 원시도 어느 편집 표면도 지목하지 않는다.
_DIVISION_DESIGN = """\
WHAT IS ALREADY DONE FOR YOU
Choosing which robot does which slot is not your tool's work. After your tool runs, that
assignment problem is solved again from scratch on the graph your tool leaves behind, by the
same solver that produced the plan you are repairing -- ordering, load balancing and the
trade-off between delay and energy are settled there, with each robot's charge and speed
already inside that model. So a tool whose mechanism is to compute a better allocation
specifies work that is then done a second time, and it is the second one that stands.
Specify instead what your tool CHANGES about the situation that solver is handed: which
possibilities it closes off or opens up, which restriction holds while it is in force, which
geometry moves. An optimiser over speeds, charges, priorities and costs is not a capability
this build is missing -- it is the part that already runs, and naming it as the missing piece
is not a finding."""

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
                         must_change: Optional[str] = None,
                         division: Optional[str] = None) -> str:
    """agent-2's context.

    🔴 It takes no `state` -- that is the bottleneck. 🔴 It carries no inventory -- that is the
    blindness. Add a parameter to this function that lets either one in and
    `test_synthesize_multi.py` goes red.
    🔴 F7: the division of labour goes to **agent-2 only**. agent-3 already reads the same fact
    from `PHYSICAL_PRINCIPLES` §1 in the form addressed to a body author, and agent-1 designs
    nothing.
    """
    return "\n".join([principles or PHYSICAL_PRINCIPLES, "",
                      goal or FINAL_GOAL, "",
                      novel or _NOVEL_DESIGN, "",
                      must_change or _MUST_CHANGE_DESIGN, "",
                      division or _DIVISION_DESIGN, "",
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


# 🔴 2026-09-03 (D5). `build_inventory_block` stood here -- the alphabet agent-3 read. There is
#    no alphabet. `compose_interface()` below is what the compose stage is handed, and Task 8
#    is where it starts returning the **world interface** instead of the empty string.
def compose_interface(blob=None) -> str:
    """**One source of truth** for the interface text the compose stage (agent-3) is handed.

    🔴 Task 8. It now returns `world_interface.build_world_interface_block(blob)` -- agent-3 is
    handed the world's types, fields and existing functions instead of an alphabet. The G1 guard
    in `synthesize_multi` is untouched: it only ever asked "is this empty", never what filled it,
    so a real interface passes it exactly the way the old empty string failed it. Both compose
    call sites still read this one function, so there is still exactly one place that decides
    what agent-3 sees.

    ⚠️ It is a **function, not a constant**, so a test can supply an interface without a paid
    call and without an extra parameter threaded through `run_synthesis`.
    """
    return WI.build_world_interface_block(blob)


# ==========================================================================================
# (3) canonicalisation · |K|
# ==========================================================================================
# 🔴 2026-09-03 (D5 · D7). `_CALL_RE` · `_WORD_RE` · `parse_body` stood here. `parse_body` read a
#    body's prose and matched it **against the registry** -- both of its two ways did (the
#    paren form for the shape, the name scan for membership). With no registry there is nothing
#    to match against, and a parser that silently matches nothing is worse than no parser.
#    Task 8 fills `body_names` from agent-3's own `impl_name` instead.
# ✅ Task 8. `_norm` (stripped a trailing `!` so a call's `primitive` would match a registry key
#    that never carried one) is **gone, not kept**. Its premise no longer holds: `calls_match_body`
#    now compares against `body_names = [impl_name]`, which keeps the `!` (`WriteToolImpl.calls`
#    is defined to name `"<impl_name>"` verbatim), so stripping it here would make a correct
#    self-report read as a mismatch.


#: 호출 인자로 허용되는 값의 타입. `params_flatness` 의 `_SCALAR_TYPES` 와 **같은 축**이지만
#: 저쪽은 JSON *스키마*의 타입 이름을, 이쪽은 실제 *값*을 본다 — 다른 것을 재므로 다른 표다.
_SCALAR_VALUES = (str, int, float, bool, type(None))


def normalize_calls(raw) -> Optional[List[Dict[str, Any]]]:
    """agent-3 의 `calls` 를 `[{"primitive": str, "args": dict}, ...]` 로. 못 읽으면 `None`.

    🔴 **전부 아니면 없음이다.** 한 항목이라도 못 읽으면 전체가 `None` 이다. 이 값은 집행에
    먹일 인자이고 이 알파벳에는 undo 가 없다 — 절반만 읽어 넘기는 것은 "반쯤 굴린 body" 와
    같은 종류의 사고다. 부분 성공을 성공으로 보고하지 않는다.

    🔴 **삼상이다.** `[]` 는 "읽었는데 비었다", `None` 은 "못 읽었다". 두 사건을 뭉개면
    "모델이 호출을 하나도 안 냈다" 와 "우리가 그 필드를 못 읽었다" 가 구별 불가능해진다.

    받아 주는 변형은 **둘뿐**이고 둘 다 이유가 있다:
      · `name` 을 `primitive` 대신 쓴 경우 — 같은 것을 가리키는 흔한 표기이고, 이 하나 때문에
        유료 런을 통째로 잃는 것은 비싸다.
      · 리스트가 아니라 JSON **문자열**로 온 경우 — dspy 의 타입 강제가 실패하면 그렇게 온다.
    그 밖의 관용은 넣지 않는다: 여기서 넓히는 만큼 "모델이 계약을 지켰는가" 를 못 재게 된다.
    """
    if raw is None:
        return None
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except Exception:
            return None
    if not isinstance(raw, list):
        return None
    out: List[Dict[str, Any]] = []
    for item in raw:
        if not isinstance(item, dict):
            return None
        nm = item.get("primitive", item.get("name"))
        if not isinstance(nm, str) or not nm.strip():
            return None
        args = item.get("args", {})
        if args is None:
            args = {}
        if not isinstance(args, dict):
            return None
        out.append({"primitive": nm.strip(), "args": dict(args)})
    return out


def calls_flatness(calls) -> Tuple[Optional[bool], str]:
    """호출 인자가 전부 평평한 스칼라인가. `(verdict, reason)`, 못 쟀으면 `(None, ...)`.

    `params_flatness` 와 같은 이유로 존재한다: 중첩 값은 Julia 경계의 **얕은** 변환
    (`tools/monitor/policy.jl` 의 `_tool_args_dict`)을 에러 없이 통과한 뒤 `JSON3.Object` 인
    채로 남아 `Dict{String,Any}` 가정을 깨뜨린다. 여기서도 **기록만 하고 강제하지 않는다.**
    """
    if calls is None:
        return None, "calls unreadable -- nothing to measure"
    if not calls:
        return None, "calls is empty -- nothing to measure"
    bad = []
    for c in calls:
        for k, v in c["args"].items():
            if not isinstance(v, _SCALAR_VALUES):
                bad.append("%s.%s: %s" % (c["primitive"], k, type(v).__name__))
    if bad:
        return False, ("non-scalar argument values would silently break the Julia boundary: "
                       + "; ".join(bad))
    return True, "all argument values are flat scalars"


def canon(names: Sequence[str], kind: Optional[str]) -> Tuple[Tuple[str, ...], str]:
    """The canonical form of spec §5-2-2: `(sorted(primitive names of the body), target kind)`.

    🔴 Parameters do not go in -- `names` carries names only, never arguments (they travel on
    the `calls` channel). If there is no `kind` it stays `""` (the empty string and `"battery"`
    are different canonical forms).
    ✅ Task 8 (2026-09-03): `body_names` is `[impl_name]` now, so records of the same kind no
    longer collapse onto one canonical form.
    """
    return (tuple(sorted(names)), kind or "")


def canon_key(c) -> str:
    """A JSON-safe key for the canonical form. It rides out in the response and becomes the
    dict key of the ledger."""
    return "%s::%s" % ("|".join(c[0]), c[1])


# 🔴 2026-09-03 (D5 · D7). Five things stood here and all five were registry-shaped:
#      `classify`             split a body's names into the registry's four namespaces
#      `_PSI_STATS_CACHE`     memoised the standardisation statistics **by registry blob id**
#      `psi_stats`            standardised over the 19 operational primitives of the registry
#      `psi_of`               `features_agnostic.psi(names)` -- KeyError outside that alphabet
#      `standardized_distance` the per-axis distance those statistics were for
#    With the alphabet generated at runtime there is no population to standardise over and no
#    namespace table to classify into, so the ψ record fields are **removed, not nulled** (a
#    permanently-`None` field reads as "could not measure", which is a different claim).


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

    def observe(self, c, params: Union[None, str, Dict[str, Any]] = None,
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

    # 🔴 2026-09-03. `reference_psis()` stood here: the ledger's canons whose ψ was
    #    computable, i.e. the reference set of the ψ distance. ψ is gone (see above), and with
    #    it its only caller. The ledger keeps its one job -- counting distinct canons (|K|).


LEDGER = SynthesisLedger()      # process-global |K|. Tests pass their own ledger.


# ==========================================================================================
# params flatness
# ==========================================================================================
_SCALAR_TYPES = {"string", "number", "integer", "boolean", "null"}
_NESTING_KEYS = ("properties", "items", "$ref", "allOf", "anyOf", "oneOf", "patternProperties",
                 "additionalProperties", "prefixItems")


def params_flatness(params_text: Union[None, str, Dict[str, Any]]) -> Tuple[Optional[bool], str]:
    """Is the `params` JSON schema **flat scalars only**? (verdict, reason).

    A verdict of `None` means **we could not measure** (it is not JSON, or the shape differs) --
    do not mix that with `False` ("we measured it and it violates"). This repo has been burned
    several times by conflating the two.

    Two accepted shapes:
      {"dx": {"type": "number"}, ...}                      (properties only)
      {"type": "object", "properties": {"dx": {...}}}      (a full schema)

    🔴 2026-09-03 (B2). `rec["params"]` is a **parsed object** now, not schema text -- so this
    takes either. A `dict` skips the parse (there is nothing left to fail at); a `str` is still
    accepted because agent-2's schema (`spec_params`, and `rec["params"]` before the write
    stage overwrites it) is text and callers pass it here in tests.
    """
    if isinstance(params_text, dict):
        blob = params_text
        if not blob:
            return None, "params is empty -- nothing to measure"
    else:
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
#: The consumer rules of this module's docstring, **as code**. The prose table up there is the
#: same nine rows for a human reader, and `test_synthesis_record_contract.py` asserts the two
#: never fork -- name, condition string **and the `tool_minted` outcome column** are all read
#: back out of `__doc__` (before R3 the outcome column was never checked, so a fork in exactly
#: the column finding I5 was about passed green).
#:
#: 🔴 Each `condition` is **sufficient on its own** -- exactly one rule matches any record
#: `synthesize_multi` returns, and that file drives every exit path to prove it rather than
#: reasoning about it. The 09-03 defect this replaces was two rows with byte-identical
#: conditions and opposite `tool_minted`.
#: 🔴 `matches` uses `.get` throughout: a record that returned early does not carry the keys of
#: the later stages, and a KeyError in a rule would turn "this row does not apply" into a crash.
ConsumerRule = namedtuple("ConsumerRule", "name condition tool_minted matches")


def _canon_count(rec):
    """`canon_count` as a **measured** ledger count, or `None` when it was not measured.

    🔴 One source of truth for the last three rows. `_finish_record` takes this value from
    `SynthesisLedger.entries[key]["count"]`, which is `>= 1` the moment `observe` has run --
    so absent, `0`, or a non-int all mean the same thing: no ledger observation stands behind
    this record. Three-state, as everywhere in this file: `None` is "could not measure", and
    it must not collapse into the `False` of "measured, and the canon was already seen".
    ⚠️ `bool` is excluded explicitly -- `isinstance(True, int)` is `True` in Python, and
    `True == 1`, so a stray boolean would otherwise be read as the count `1` ("new canon").
    """
    v = rec.get("canon_count")
    if isinstance(v, bool) or not isinstance(v, int) or v < 1:
        return None
    return v

CONSUMER_RULES = (
    ConsumerRule(
        "was switched off", "enabled == False", "disabled",
        lambda r: r.get("enabled") is False),
    ConsumerRule(
        "refused", "enabled == True and refused is a str", None,
        lambda r: r.get("enabled") is True and isinstance(r.get("refused"), str)),
    ConsumerRule(
        "a stage failed",
        "enabled == True and refused == False and ran == False and error is not None", None,
        lambda r: (r.get("enabled") is True and r.get("refused") is False
                   and r.get("ran") is False and r.get("error") is not None)),
    ConsumerRule(
        "did not fire",
        "enabled == True and refused == False and ran == False and error is None", None,
        lambda r: (r.get("enabled") is True and r.get("refused") is False
                   and r.get("ran") is False and r.get("error") is None)),
    ConsumerRule(
        "ran and failed", "ran == True and error is not None", None,
        lambda r: r.get("ran") is True and r.get("error") is not None),
    ConsumerRule(
        "ran, no body", "ran == True and error is None and body_names == []", None,
        lambda r: (r.get("ran") is True and r.get("error") is None
                   and r.get("body_names") == [])),
    ConsumerRule(
        "re-derived",
        "ran == True and error is None and body_names != [] and canon_count > 1", False,
        lambda r: (r.get("ran") is True and r.get("error") is None
                   and bool(r.get("body_names")) and (_canon_count(r) or 0) > 1)),
    ConsumerRule(
        "new canon",
        "ran == True and error is None and body_names != [] and canon_count == 1", True,
        lambda r: (r.get("ran") is True and r.get("error") is None
                   and bool(r.get("body_names")) and _canon_count(r) == 1)),
    # 🔴 R3. The three rows above split `_canon_count(r)` into `None` / `== 1` / `> 1`, which
    #    is exhaustive and disjoint by construction -- a body-bearing record can no longer fall
    #    through the table.
    ConsumerRule(
        "canon count unmeasured",
        "ran == True and error is None and body_names != [] "
        "and canon_count is absent or < 1", None,
        lambda r: (r.get("ran") is True and r.get("error") is None
                   and bool(r.get("body_names")) and _canon_count(r) is None)),
)


def _blank(rec_kind, expressible, ledger) -> Dict[str, Any]:
    # 🔴 `refused` is three-state and starts at `None` = **the G1 guard did not run**. It is
    #    `False` once the guard has run and passed, and a string (the reason code) when it
    #    refused. A blank record never enters `synthesize_multi`, so `None` is the true value
    #    there -- and it is what keeps "the lane was switched off" from colliding with
    #    "we refused to spend on this event".
    return {"tool_minted": None,
            "synthesis_event": False, "ran": False,
            "enabled": synthesis_enabled(), "refused": None,
            "kind": rec_kind, "expressible": expressible,
            "K": ledger.K, "error": None, "reason": None,
            # 🔴 삼상 (D13). `_blank` 은 `_BODY_FIELDS` 를 순회하지 않는다 — 나머지 body 필드는
            # (`impl_name` 등) agent-3 가 실제로 불릴 때까지 이 딕셔너리에 아예 없다. `needs` 만
            # 예외로 명시하는 이유: "못 쟀다" (`None`)와 "쟀는데 없다" (`""`)를 가르는 삼상 값이
            # 정의역에 없는 채로 있으면 안 되고, blank 기록은 정의상 agent-3 를 아직 안 불렀으므로
            # 참값은 `None` 하나뿐이다.
            "needs": None}


def _finish_record(rec, kind, led, blob):
    """Take a `rec` whose output fields are filled and finish it: canon, ledger, |K|.

    🔴 2026-09-03. This used to open by parsing `rec["body"]` against the registry and by
    computing a ψ distance over it. Both are gone with the registry (D5 · D7). What is left is
    the part that never depended on an alphabet: the canonical form, the ledger, and `|K|`.
    """
    # ✅ Task 8. `body_names` is filled **before** this function runs -- `synthesize_multi` sets
    #    it from agent-3's own `impl_name` right after the write stage (and again after a
    #    recompose). This function used to overwrite it to `[]` unconditionally (R-BODYNAMES);
    #    it must not do that any more, or every generated body would read as empty. The record
    #    shape itself did not change: the key stays a **list**, and both Julia readers
    #    (`minted_tool.jl` `_synth_get(synth, "body_names", String[])` ·
    #    `enact.jl` `something(get(sl, "body_names", nothing), [])`) already type it that way.
    # 🔴 `reach`/`missing_primitive` are kept in the record (R1 -- they are not renamed or
    #    deleted), but `WriteToolImpl` does not declare them as output fields, so they are
    #    agent-3's self-report only when a caller's fake still sets them; on a live run they are
    #    simply `""`. `missing_primitive_recorded` below is therefore `None` on every live row --
    #    the concept it measured (a named, non-empty missing primitive) does not exist for a
    #    writer that either writes code or says `wrote=False`.
    rec["missing_primitive_recorded"] = (
        None if rec["reach"] != "needs_primitive" else bool(rec["missing_primitive"].strip()))

    rec["params_flat"], rec["params_flat_detail"] = params_flatness(rec["params"])

    # ---- 인자 채널 (2026-09-03, A) ----------------------------------------------------------
    # 🔴 `normalize_calls` 는 "필드가 없었다" 와 "있었는데 못 읽었다" 를 둘 다 `None` 으로
    #    낸다(전부-아니면-전무의 대가). 줄리아는 `nothing` 을 "못 쟀다 → 옛 `params` 경로" 로
    #    읽으므로 세계는 안 상하지만 **기록이 상한다** — 못 읽은 판이 안 낸 판과 구별되지
    #    않는다. 그래서 원문의 유무를 옆에 적어 셋을 일대일로 만든다.
    _raw_calls = rec.get("calls")
    rec["calls"] = normalize_calls(_raw_calls)
    rec["calls_unreadable"] = (_raw_calls is not None and rec["calls"] is None)
    # 🔴 기록만 하고 강제하지 않는다(옛 `reach_matches_body` 와 같은 관용).
    # 🔴 `body_names` 가 비어 있으면(= agent-3 이 안 썼다, `wrote is False`) **`None`("못
    #    쟀다")이다.** `False` 는 "쟀고 어긋났다" 는 주장이라, 쓰지도 않은 판을 그렇게 적으면
    #    지속되는 jsonl 을 읽는 사람에게는 **모델이 자기모순을 냈다**고 보인다. 잰 것이 없으므로
    #    `None` 이다(이 파일의 삼상 규약). ✅ Task 8 이 `body_names` 를 `[impl_name]` 로 채우는
    #    한, agent-3 이 실제로 쓴 판에서는 이 식이 다시 측정 가능하다.
    rec["calls_match_body"] = (
        None if (rec["calls"] is None or not rec["body_names"]) else
        [c["primitive"] for c in rec["calls"]] == rec["body_names"])
    rec["calls_flat"], rec["calls_flat_detail"] = calls_flatness(rec["calls"])

    c = canon(rec["body_names"], kind)
    rec["canon"] = {"primitives": list(c[0]), "kind": c[1]}
    rec["canon_key"] = canon_key(c)

    minted = led.observe(c, params=rec["params"], tool_name=rec["tool_name"])
    rec["K"] = led.K
    rec["canon_count"] = led.entries[rec["canon_key"]]["count"]
    # 🔴 `body_names` 가 비어 있으면(agent-3 이 아무 이름도 못 냈다) `tool_minted` 는
    #    **`None`("못 쟀다")이지 `False`("이미 본 canon")가 아니다.** `led.observe` 는 그래도
    #    부른다 -- 빈 canon (`()::kind`) 도 하나의 canonical form이고, `canon_count` 는 "이
    #    (빈) canon 을 몇 개의 기록이 공유했나" 라는 참인 사실이다. 그것을 `tool_minted` 로
    #    올리지 않는 이유는 빈 body 에 대한 "새 canon"/"재도출" 은 도구에 대한 사실이 아니라
    #    **쓰지 않았다는 사실**이기 때문이다.
    if not rec["body_names"]:
        rec["tool_minted"] = None
        rec["reason"] = ("tool_minted is not knowable: agent-3 wrote no implementation for this "
                         "event (body_names is empty, canon %s), so there is no behaviour to "
                         "check against the ledger (spec 5-2-3)" % rec["canon_key"])
    else:
        rec["tool_minted"] = bool(minted)
        rec["reason"] = ("new canon" if minted else
                         "canon already observed -- the model re-derived a behaviour it already "
                         "had; this is a point on the |K| curve, not a failure (spec 5-2-3)")
    return rec


def blank_synthesis_record(kind: Optional[str] = None,
                           expressible=None,
                           ledger: Optional[SynthesisLedger] = None) -> Dict[str, Any]:
    """The record of an event that is **not a firing event**. No LM, no socket, no charge.

    🔴 One source of truth for the blank shape. `dspy_service._blank_decision` used to obtain it
    by calling `maybe_synthesize(expressible=None, ...)` purely for the shape of that function's
    early return; `maybe_synthesize` is gone with the single-agent lane (D8), and replacing that
    call with `run_synthesis` would have run the **paid** 3-agent pipeline for a shape. So the
    early-return branch moved here, verbatim, `reason` string included -- a hand-built constant
    dict on the service side would fork from this one the first time either grew.

    The firing condition is exactly the rate spec §8-1 names as the substitute signal:
    **`expressible == False`**. Neither `None` ("we could not measure it") nor `True` fires.
    """
    led = ledger if ledger is not None else LEDGER
    rec = _blank(kind, expressible, led)
    rec["reason"] = ("not a firing event: expressible is %r; T2 fires only on False "
                     "(spec 8-1)" % (expressible,))
    return rec


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

# 🔴 F8. 이 되먹임은 09-03 까지 **함수 안의 리터럴**이었고 끝에서 끝까지 재본 적이 없었다.
# 🔴 옛 문구는 "Commit to one mechanism and specify it directly." 로 끝났다. 그런데 이 게이트는
#    `params` 만 보고 `mechanism` 산문은 절대 안 본다 — 그래서 그 문장이 낸 결과는 선택이
#    사라지는 것이 아니라 **선택이 산문으로 이사하는 것**이었고, 그게 정확히 agent-3 이 조합
#    못 하는 상태다. (zone 런2: 재설계를 한 번 돌고도 `bypass_method` 가 그대로 남았다.)
_UNGROUNDED_FEEDBACK = (
    "These parameters of your previous specification cannot be supplied by the world -- each "
    "names a choice among behaviours rather than a value: %s. Replace each one with the effect "
    "it was standing in for, or with a value the world can hand you. Do not move the choice "
    "into the mechanism description: a behaviour named there and implemented nowhere is the "
    "same undecided choice in another place.\n\n" + _EFFECT_NOT_MECHANISM)


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
    """Read `params` as `(dict, shape)`.

    🔴 2026-09-03 정정. 여기 "줄리아의 `normalize_params` 의 파이썬 짝" 이라고 적혀 있었는데
    **그런 함수는 없다**(레포 전수 0건). 줄리아 쪽 짝은 `minted_tool.jl::enact_minted!` 안에서
    `params` 를 dict 으로 펴는 자리이고, 그쪽은 값만 본다.

    ⚠️ Two copies and only one of them grows. Here we return **both values and schemas as they
    are** -- this gate has to judge declarations as well as values, so unlike the Julia side it
    does not blank the schema out.
    """
    if params_text is None:
        return {}, "unparseable"
    # 🔴 2026-09-03 (B2). A `dict` used to short-circuit **before** the `properties` unwrapping
    #    below and was always reported as shape "values". That was harmless while `rec["params"]`
    #    was text and only hand-built dicts reached here; it stops being harmless the moment the
    #    live record carries a parsed **schema** (`{"type": "object", "properties": {...}}`),
    #    because then `ungrounded_params` would walk `{"type", "properties", "required"}` as if
    #    those were the parameter names. Both inputs take the same road now.
    if isinstance(params_text, dict):
        blob = params_text
    else:
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
# 🔴 2026-09-03 (D5). The feedback used to be **redacted**: `_REDACTED_NAME` ·
#    `_inventory_names` · `redact_inventory_names` stood here and replaced every registry name
#    in agent-3's prose with a neutral placeholder, because contract (B) of
#    `test_synthesize_multi.py` said agent-2 must not see the alphabet. **Contract (B) is
#    abolished**: there is no alphabet to leak. agent-3 no longer holds a fixed inventory, so a
#    name it mentions is a name it wrote itself, not a vocabulary item agent-2 would project
#    onto. The feedback now travels verbatim and `compose_feedback_redacted` is `None`
#    ("no redaction ran"), never `[]` ("redaction ran and hit nothing").


# 🔴 The last sentence is not decoration. Without it a model that genuinely cannot re-specify
#    invents *something* to fill the field, and "the gap is real" becomes unobservable. Asking
#    it to repeat the specification unchanged makes that answer a **measurable** one
#    (`spec_changed_by_feedback`).
# ✅ Task 8 (fix round 1). This used to say "a composer holding a fixed inventory ... tried to
#    realise your specification and could not", with `%s` filled by `missing_primitive` -- a
#    field `WriteToolImpl` does not emit. Left unchanged, the slot was always empty and every
#    firing spent two more billable calls (a redesign + a recompose) asking agent-2 to react to
#    nothing. There is no composer and no inventory any more: agent-3 was asked to WRITE Julia
#    code and self-reported `wrote=false`. The only thing it actually produces that could explain
#    why is `reasoning` -- the chain-of-thought `dspy.ChainOfThought` attaches to every stage --
#    so that is the evidence slot now, and the trigger below refuses to fire without one.
_COMPOSE_FEEDBACK = (
    "A writer was given your specification and the world interface and asked to WRITE a Julia "
    "implementation. It reported it could not (wrote=false). Its own account of why:\n\n%s\n\n"
    "There is no fixed catalogue it composes from -- it may write any function the world "
    "interface supports, so a missing capability is not the same kind of gap it used to be. "
    "Restate the tool as the effect it must produce; do not name a specific mechanism, since "
    "choosing one is the writer's job, not yours. If it is the effect itself that cannot be "
    "produced, repeat your previous specification unchanged.\n\n" + _EFFECT_NOT_MECHANISM)

_SPEC_FIELDS = ("tool_name", "params", "mechanism")
# ✅ Task 8. agent-3(`WriteToolImpl`) 의 출력 모양이 바뀌었다: `body`/`reach`/`missing_primitive`
#    대신 `impl_name`/`impl_code`/`surface`/`reversible`/`wrote`. 🔴 R1 (컨트롤러 결정) --
#    `reach`·`missing_primitive` 는 기록에서 **지우지 않는다**: `WriteToolImpl` 이 그 둘을
#    선언하지 않으므로 `getattr` 은 그냥 기본값(`""`)으로 떨어진다 -- 필드를 지운 것이 아니라
#    자기신고가 더 이상 그것을 내지 않는 것이다.
_BODY_FIELDS = ("impl_name", "impl_code", "surface", "reversible", "wrote", "calls",
               "reach", "missing_primitive", "needs")

#: `_BODY_FIELDS` 중 **`or ""` 로 접으면 안 되는** 것. `calls` 는 예전과 같은 이유
#: (`[]` = "읽었는데 비었다" 가 `""` = "못 읽었다" 로 접히면 삼상이 깨진다). `reversible`·
#: `wrote` 는 **bool** 이다 -- 표가 없으면 `getattr(p, "wrote", "") or ""` 가
#: `wrote=False`(못 쓰겠다는 자기신고)를 `""`(못 읽었다)로 접어 F2 의 `wrote is False`
#: 분기가 영영 못 켜진다. ✅ fix round 1 -- `reversible` 도 `_copy_body_fields` 안에서 같은
#: `isinstance(..., bool)` 판정을 받는다: 모델이 `"true"` 처럼 문자열을 내면 그 판정이 없으면
#: jsonl 의 이 열은 독자가 bool 로 읽는데 실제로는 문자열이 저장된다 -- 삼상이 깨지는 자리는
#: `enact.jl` 의 `=== true` 가드가 세계는 지키지만 **기록**은 안 지킨다.
_NON_STR_BODY_FIELDS = frozenset({"calls", "reversible", "wrote"})


def params_object(raw):
    """agent-3 이 **텍스트로 쓴** JSON 스키마 -> 파싱된 객체. 못 읽으면 `None`.

    🔴 2026-09-03 (B2, 컨트롤러 판정 R17). `rec["params"]` 는 경계를 건너 Julia 의
    `register_minted_primitive!(params = ...)` 로 **그대로** 들어가고, 그 가드는
    `AbstractDict` 를 요구한다(`enact.jl` 의 `reject:params_not_an_object:$(typeof(praw))`).
    문자열을 보내면 등록이 거절되고 `Core.eval` 에 **도달조차 못 한다** — 실측: 라이브
    모양은 거절/0 steps, `Dict{String,Any}` 는 `admit, registered=true`. 이 브랜치의 유일한
    측정(D6)이 그 거절 뒤에 있으므로 오늘의 배선으로는 아무것도 기록되지 않는다.

    🔴 **파싱은 여기(파이썬)서 한다, 줄리아가 아니라.** 스키마는 모델이 텍스트로 쓰고, 그
    텍스트를 이미 파이썬이 검증한다(`params_flatness` · `ungrounded_params`). 줄리아에서
    다시 파싱하면 같은 사실의 진실원이 둘이 된다.

    🔴 **삼상.** 못 읽으면 `None`("못 쟀다")이지 `{}`("쟀는데 비었다")가 아니다. 이 둘은
    다른 사건이고, `{}` 를 보내면 **빈 스키마로 등록이 성공한 뒤** `enact_minted!` 이
    모든 호출 인자를 스키마 밖이라고 거절해 원시가 평생 호출 불가가 된다 — 조용한 실패다.
    (`None` 이면 `enact.jl` 의 `praw === nothing` 갈래로 가 빈 스키마로 등록되는 것은
    같지만, **기록**은 "스키마를 못 읽었다" 를 정직하게 남긴다.) 반대로 모델이 **읽히는
    빈 객체**를 냈으면 `{}` 를 그대로 낸다 — "키워드가 없는 함수를 썼다" 는 참인 관측이다.

    🔴🔴 **타입만이 아니라 모양도 맞춰야 한다** (2026-09-03, 새 교차언어 게이트가 실측으로
    잡았다 — 그 게이트가 없었으면 이 층은 또 안 보였다). 줄리아 등록 행의 `params` 는
    JSON Schema **봉투**가 아니라 **키워드 맵**이다: `_enactability` 의 연언지 (iii) 이
    "레지스트리 `params` 의 키가 전부 그 메서드의 키워드여야 한다" 를 요구하므로,
    라이브 모델이 실제로 내는 `{"type": "object", "properties": {...}, "required": [...]}`
    를 그대로 파싱해 보내면 키가 `type`·`properties`·`required` 가 되어 원시가
    `reject:unenactable:<name>:kwargs` 로 **등록은 되고 영영 호출 불가**가 된다
    (실측: 파이썬이 실제로 낸 기록으로 그 거절을 재현했다 — 첫 유료 런의 잘린 응답도
    정확히 이 봉투 모양이었다). 그래서 봉투를 여기서 벗긴다. 무엇이 "파라미터 맵" 인가는
    `_params_view` **하나**가 정하고(이 파일이 이미 그 판정을 갖고 있다) 여기서 다시 적지
    않는다 — 두 벌이 되는 순간 한쪽이 조용히 낡는다.
    """
    if raw is None:
        return None
    if not isinstance(raw, dict) and not str(raw).strip():
        return None                      # 필드는 있었는데 빈 문자열 = 읽을 것이 없었다
    d, shape = _params_view(raw)
    if shape == "unparseable":
        return None
    return d


def strip_code_fence(code):
    """agent-3 이 코드를 감싼 마크다운 펜스를 벗긴다. 펜스가 없으면 **바이트 동일**로 통과.

    🔴 2026-09-03 (R18, 컨트롤러 판정). 두 번째 유료 런은 레인을 끝까지 돌았는데
    (`stages` 셋 · `wrote=True` · `params` 진짜 dict · `calls_match_body=True`) 등록이
    `reject:impl_not_a_function` 으로 거절됐다. 모델이 낸 것은 ` ```julia\\n…\\n``` ` 였다.
    **코드를 펜스로 감싸는 것은 모든 LM 의 보편 행동이지 규약 위반이 아니다** — 그것을
    거절하면 우리가 재는 것은 모델의 준수도가 아니라 **우리 파서**다.

    🔴 **정규화는 파이썬이 한다, 줄리아가 아니라** (판정 R17 의 선례 그대로). 이 파일은
    이미 `params` 를 파싱하고(`params_object`) `calls` 를 정규화한다(`normalize_calls`) —
    LM 응답을 먼저 보는 것이 파이썬이고, 진실원은 하나여야 한다. 줄리아 쪽
    `check_impl_conventions` 의 `reject:impl_code_is_fenced` 는 **고침이 아니라 진단**이다:
    여기까지 펜스가 도착했다는 것은 이 함수가 실패했다는 뜻이고 그것은 시끄러워야 한다.

    🔴 **삼상.** 코드가 비었거나 벗기고 나면 비는 경우는 `""`("쟀는데 아무것도 없다")이지
    `None`("못 쟀다")이 아니다 — `_copy_body_fields` 가 필드가 **아예 없을 때** 내는 값이
    이미 `""` 다(`getattr(pred, f, "") or ""`). 여기서 `None` 을 내면 그 둘이 갈라지는 것이
    아니라 **한 사건이 두 이름을 갖게 된다**.

    🔴 **예외가 아니라 거절.** 문자열이 아닌 값은 그대로 통과시킨다 — 타입 위반을 말하는
    자리는 줄리아의 `reject:impl_code_not_a_string` 하나이고, 여기서 던지면 그 사유가
    영영 기록되지 않는다.

    받아 주는 모양(모델이 실제로 내는 것): ` ```julia ` · ` ```jl ` · 맨 ` ``` ` ·
    대문자/공백이 섞인 info string · 펜스 **바깥**의 앞뒤 공백 · **닫히지 않은** 펜스(잘림).
    ⚠️ **안쪽은 한 줄도 안 건드린다.** 벗기는 것은 여는 줄과 **마지막** 줄의 닫는 펜스뿐이라,
    몸통 한가운데의 ` ``` ` 처럼 생긴 줄은 그대로 남는다.
    """
    if not isinstance(code, str):
        return code
    s = code.strip()
    if not s.startswith("```"):
        return code                      # 펜스가 아니다 — 한 바이트도 안 건드린다
    first, _, rest = s.partition("\n")
    n = len(first) - len(first.lstrip("`"))
    if "`" in first[n:]:
        return code                      # info string 에 백틱은 못 온다 = 펜스가 아니다
    lines = rest.split("\n") if rest else []
    if lines:
        tail = lines[-1].strip()
        # 닫는 펜스는 백틱만으로 된 줄이고 여는 것보다 짧지 않다(CommonMark).
        if tail and tail == "`" * len(tail) and len(tail) >= n:
            lines = lines[:-1]
    out = "\n".join(lines)
    return out + "\n" if out else ""


def _copy_body_fields(rec, pred):
    """agent-3(`WriteToolImpl`) 의 출력을 기록으로. 문자열 필드만 `""` 로 접고 `calls`·
    `reversible`·`wrote` 는 **날것 그대로** 둔다(정규화는 `_finish_record` 가 한 번만 한다 --
    두 자리에서 하면 갈린다). `wrote`·`reversible` 는 bool 이 아니면 `None`("못 읽었다")으로
    접고, `body_names` 는 여기서 바로 `[impl_name]` 로 채운다 -- 집행부가 읽는 자리다.

    🔴 R6 (컨트롤러 결정, fix round 1). `params` 는 **agent-3 가 이긴다.** `enact.jl` 이
    `synth["params"]` 를 `register_minted_primitive!` 에 그대로 넘기고, 그 스키마에 없는
    키워드로 부르면 `enact_minted!` 가 거절한다 -- agent-2 의 명세가 아니라 **agent-3 가 실제로
    쓴 함수의 키워드**가 호출 가능성을 정하므로, 둘이 갈리면 agent-3 쪽이 맞아야 primitive 가
    평생 호출 불가가 되지 않는다. agent-2 의 스키마를 잃지 않도록 `spec_params` 에 옮겨 둔다
    (덮어쓰기 직전 값 -- 재설계가 있었으면 그 재설계의 스키마). 둘이 다르다는 사실 자체가 첫
    라이브 런에서 읽을 가치가 있는 관측이다.
    """
    for f in _BODY_FIELDS:
        if f in _NON_STR_BODY_FIELDS:
            rec[f] = getattr(pred, f, None)
        else:
            rec[f] = (getattr(pred, f, "") or "")
    # 🔴 R18 FIX A. 펜스는 **여기서** 벗긴다 — 기록에도, 경계 너머 줄리아에도 맨 Julia 만
    #    간다(근거 전문은 `strip_code_fence`). 삼상은 안 바뀐다: 위 루프가 이미 `""` 로
    #    접은 값에 대해 이 함수는 `""` 를 그대로 낸다.
    rec["impl_code"] = strip_code_fence(rec["impl_code"])
    w = rec["wrote"]
    rec["wrote"] = w if isinstance(w, bool) else None
    r = rec["reversible"]
    rec["reversible"] = r if isinstance(r, bool) else None
    rec["body_names"] = [rec["impl_name"]] if rec["impl_name"] else []
    # 🔴 `spec_params` 는 **문자열로 남긴다** (B2 에서 명시적으로 결정). agent-2 의 스키마는
    #    (a) 경계를 안 건너고(`SYNTH_LANE_KEYS` 에 없다) (b) 이 파일에서 하는 일이
    #    `spec_changed_fields` 의 **텍스트 동일성 비교** 하나뿐이다
    #    (`spec2["params"].strip() != first_agent2_params.strip()`). 파싱하면 그 비교가
    #    dict 과 str 을 견주게 되고, "agent-2 가 명세를 바꿨나" 를 재던 관측이 죽는다.
    #    agent-3 의 `params` 만 파싱되는 이유는 그것만이 등록 스키마로 쓰이기 때문이다(R6).
    rec["spec_params"] = rec.get("params")
    _praw = getattr(pred, "params", None)
    rec["params"] = params_object(_praw)
    # 🔴 `calls_unreadable`(`_finish_record`)와 **같은 이유, 같은 관용구**. `params_object` 는
    #    "필드가 없었다" 와 "있었는데 못 읽었다" 를 둘 다 `None` 으로 낸다 — 파싱이 이 자리로
    #    올라오면서 `params_flat_detail` 이 나르던 그 구별("params is not JSON (...)")이
    #    사라지기 때문에, 원문이 **있었는지**를 옆에 적어 셋을 일대일로 되돌린다.
    #    경계로는 안 보낸다(줄리아는 `praw === nothing` 하나만 알면 되고, 진단은 jsonl 의 몫이다).
    rec["params_unreadable"] = (_praw is not None and str(_praw).strip() != ""
                                and rec["params"] is None)


# ==========================================================================================
# (5) The 3-agent pipeline itself
# ==========================================================================================
# 🔴 2026-09-03 (D8). `MULTI_AGENT_ENV` · `multi_agent_enabled()` stood here and chose between
#    two lanes. There is one lane now, so the switch is gone from this file and `run_synthesis`
#    has no branch. ⚠️ The env var name `SYNTH_MULTI_AGENT` still lives in `dspy_service.py`,
#    read there by a local `_synth_multi_agent_stamp()` for `/health` **only** -- as a generation
#    stamp, not as a lane switch. Do not reintroduce a reader here.


# ==========================================================================================
# (5-b) 합성 기록을 파일로 — 라이브 판을 사후에 읽을 수 있게
# ==========================================================================================
# 🔴 왜 (2026-09-03 라이브 실측). mild 보드에서 합성이 **발화했는데** `empty body` 로 거절됐고,
#    agent-3 이 무엇을 답했는지는 어디에도 안 남았다: `[minted]` 의 발화 분기가 그것을 안 찍었고
#    (같은 날 고쳤다), 스트림 jsonl 은 프레임 기록이라 합성 필드가 0개이며, 서비스는 결정을
#    파일로 안 쓴다. 유료 런을 하고도 "왜 body 가 비었나" 를 답할 수 없었다.
#
# 🔴 `body` 산문은 `SYNTH_LANE_KEYS` 로 **안 올린다.** 그 경계의 계약은 "집행부가 읽는 것" 이고
#    산문은 집행이 안 읽는다. 진단은 파일로 남기고 경계는 좁게 둔다.
SYNTH_RECORD_ENV = "SYNTH_RECORD_LOG"


def default_record_path() -> str:
    """`<repo>/results/synth_lane_records.jsonl`. 🔴 `results/` 는 gitignore 다 — 기본 경로가
    추적되는 자리면 아무도 재현하지 않은 숫자가 커밋된다(이 레포의 규약)."""
    repo = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
    return os.path.join(repo, "results", "synth_lane_records.jsonl")


def append_synthesis_record(rec, path=None) -> Optional[str]:
    """기록 한 줄을 append 한다. 쓴 경로, 또는 `None`(안 썼다).

    🔴 **절대 던지지 않는다.** 진단이 결정을 죽이면 진단을 켠 것이 사고의 원인이 된다 —
    줄리아 집행부가 같은 이유로 예외 대신 거절을 내는 것과 같은 규약이다.
    🔴 인코딩 못 하는 값은 `default=str` 로 접는다. 값 하나 때문에 줄 전체를 잃지 않는다.
    """
    if path is None:
        env = os.environ.get(SYNTH_RECORD_ENV)
        if env is not None and env.strip() in ("", "0"):
            return None
        path = env or default_record_path()
    try:
        d = os.path.dirname(path)
        if d:
            os.makedirs(d, exist_ok=True)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False, default=str) + "\n")
        return path
    except Exception:
        return None


def run_synthesis(expressible, kind=None, state="", tools=None, ledger=None,
                  programs=None, blob=None) -> Dict[str, Any]:
    """The single door the service calls. **There is no branch** -- one lane, always.

    🔴 The caller's `expressible` is accepted and **not used**. agent-2 emits that verdict as its
    own output field, so the record has one source for it; taking it from the caller as well
    would compute the same-named rate over two different denominators -- a place this repo has
    already stood, with `macro_tool_agree`. The parameter stays in the signature because the
    service passes it positionally and its absence would be a silent API break.

    ✅ Task 8 (2026-09-03): `blob` is read again. It used to be the registry blob (dead since
    D5 -- `build_compose_context` / `_finish_record` never looked at it, and `compose_interface`
    returned `""` regardless of `blob`). Now `compose_interface(blob)` forwards it to
    `world_interface.build_world_interface_block(blob)`, which uses it as an override for the
    on-disk `world_interface.json` when a caller (a test) supplies one -- the same reason a test
    can drive `synthesize_multi` without touching disk. `build_compose_context` / `_finish_record`
    still do not read it.
    """
    return synthesize_multi(state=state, tools=tools, kind=kind, ledger=ledger,
                            programs=programs, blob=blob)


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

    🔴 G1 (2026-09-03). Before any of that it **refuses** -- without spending a cent -- when
    `compose_interface()` is empty, i.e. when agent-3 would be handed no catalogue at all. The
    refusal is a record (`refused == "no_compose_interface"`), never an exception, and it is a
    distinct observable from both "the lane was switched off" and "agent-3 declined".
    """
    led = ledger if ledger is not None else LEDGER
    rec = _blank(kind, None, led)
    rec["stages"] = []

    if not synthesis_enabled():
        rec["tool_minted"] = "disabled"
        rec["reason"] = ("%s != '1': synthesis is OFF by default because one firing is a "
                         "billable OpenAI call (R13)" % SYNTHESIS_ENV)
        return rec

    # ---- G1: refuse rather than bill when agent-3 would be handed no interface -------------
    # 🔴 Why this is here and not one line above the compose call: by then agent-1 and
    #    agent-2 have already been paid for. A run that ends in this refusal spends **nothing**
    #    -- `stages` stays empty and the spy in `test_synthesis_record_contract.py` sees no
    #    stage at all.
    # ✅ Task 8. `WriteToolImpl` is fed `compose_interface()`, which now renders the real world
    #    interface -- this guard stays because a caller (a test, or a broken `WM_DIR`) can still
    #    monkeypatch or starve it back to empty, and the guard's job was always "is this empty",
    #    never "what generation of catalogue was this".
    # 🔴 A rejection, not an exception (the repo's idiom): it returns a record whose
    #    `refused` field a reader can index. Three-state -- `None` never ran (above), `False`
    #    ran and passed, a string is the reason code. It is NOT collapsed into `enabled`
    #    ("the lane was switched off") nor into `wrote is False` ("agent-3 declined", which has
    #    `ran == True`): this repo has twice paid for folding distinct events into one observable.
    # ✅ Fix round 1. `compose_interface(blob)` can now raise: it calls
    #    `world_interface.load_world_interface()`, which dies loudly (`os.stat` uncaught) when
    #    `world_interface.json` is missing or `WM_DIR` points at nothing -- Task 7's ruling, kept
    #    on purpose (no silent empty interface). Left uncaught here, that exception would escape
    #    `synthesize_multi` and, above it, the `/macro` handler's only `try` (`dspy_service.py`),
    #    turning into an HTTP 500 that Julia reads as "service down" with no record of why -- an
    #    exception on the enactment path, which this repo does not allow. The fix is a fourth
    #    `refused` reason code, right where the other three already live, so Task 7's loudness and
    #    "rejection, not exception" both hold: the exception is caught **here**, once, and turned
    #    into a record before it can reach any caller.
    try:
        iface = compose_interface(blob)
    except Exception as e:
        rec["refused"] = "world_interface_unreadable: %s: %s" % (type(e).__name__, e)
        rec["reason"] = (
            "refused before spending: compose_interface(blob) raised (%s) while building the "
            "world interface -- Task 7's world_interface.load_world_interface() is meant to die "
            "loudly on a missing/unreadable world_interface.json rather than fall back to an "
            "empty interface, and this guard is what stops that loudness from becoming an "
            "uncaught exception on the enactment path; nothing was billed (stages == [])"
            % rec["refused"])
        return rec
    rec["refused"] = False if (iface or "").strip() else "no_compose_interface"
    if rec["refused"]:
        rec["reason"] = (
            "refused before spending: the compose stage would have been handed no world "
            "interface (compose_interface() returned empty), so agent-3 would be asked to write "
            "code blind and the run would measure nothing; nothing was billed (stages == [])")
        return rec

    progs = programs or {}
    observe = progs.get("observe") or dspy.ChainOfThought(ObserveEvent)
    design = progs.get("design") or dspy.ChainOfThought(DesignToolSpec)
    compose = progs.get("compose") or dspy.ChainOfThought(WriteToolImpl)

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
        fb = _UNGROUNDED_FEEDBACK % ", ".join(bad)
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
        # ✅ Task 8. agent-3 receives the **world interface** (`iface`, already computed by the
        #    G1 guard above) instead of an inventory -- reusing `iface` rather than calling
        #    `compose_interface(blob)` again keeps the guard's verdict and what agent-3 actually
        #    sees from being able to drift apart.
        p3 = compose(spec=build_compose_context(spec, rec["reasoning_log"], blob),
                     world_interface=iface)
    except Exception as e:
        rec["error"] = "compose: %s: %s" % (type(e).__name__, e)
        rec["reason"] = "stage 3 (compose) failed; nothing was minted"
        return rec
    rec["stages"].append("compose")
    _copy_body_fields(rec, p3)
    rec["reasoning"] = (getattr(p3, "reasoning", "") or "")

    # ---- (F2) agent-3 -> agent-2: the composer's verdict, redacted, **once** ---------------
    # ✅ Task 8. Fires on `wrote is False` -- agent-3 no longer reports
    #    `reach == "needs_primitive"` (that field is `WriteToolImpl`'s dead vocabulary now, kept
    #    in the record per R1 but never populated by a live run). `wrote is False` is agent-3's
    #    own refusal to write an implementation, the direct analogue of the old "could not
    #    compose from the inventory" signal. `None` (unreadable) does NOT fire -- "we could not
    #    read the verdict" must not look like "the verdict was acted on".
    # 🔴 Fix round 1. `wrote is False` alone is not enough: the old trigger's second clause
    #    (`and rec["missing_primitive"].strip()`) existed precisely to stop a firing with nothing
    #    to say, and dropping it along with the first clause let two billable calls go out with
    #    an empty evidence slot (measured live-shaped: the feedback string had `"\n\n\n\n"` where
    #    the missing primitive used to be). `reasoning` -- `WriteToolImpl`'s own chain-of-thought,
    #    the only thing agent-3 actually produces that could explain a refusal -- plays that role
    #    now: no non-empty account, no feedback call.
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

    if rec["wrote"] is False and rec["reasoning"].strip():
        first = {f: rec[f] for f in _SPEC_FIELDS + _BODY_FIELDS}
        # ✅ Fix round 1 (a side effect of R6 above). `first["params"]` is agent-3's code schema
        #    now (`_copy_body_fields` already overwrote `rec["params"]` for the first attempt) --
        #    right for restoring `rec["params"]` if the recompose write fails below, WRONG as the
        #    baseline for "did agent-2's own specification change" a few lines down. `spec_params`
        #    is agent-2's schema at this same point (also just set by `_copy_body_fields`), so it
        #    is captured here, before anything downstream can move it.
        first_agent2_params = rec.get("spec_params")
        for f, v in first.items():
            rec[f + "_first"] = v          # the first attempt survives whatever happens below
        # 🔴 2026-09-03 (D5). 되먹임은 이제 **날것 그대로** 간다. 옛 코드는
        #    `redact_inventory_names` 로 레지스트리 이름을 가렸는데, 그 목적은 계약 (B)
        #    (agent-2 가 알파벳을 보면 설계가 어휘로의 투영이 된다)였다. 알파벳이 없으므로
        #    가릴 것이 없고 계약 (B) 도 폐지됐다.
        # 🔴 `compose_feedback_redacted` 는 `None`("가림이 안 돌았다")이지 `[]`("돌았는데
        #    하나도 안 걸렸다")가 아니다 — 이 파일이 지키는 삼상 규약.
        # ⚠️ 긴장 하나를 정직하게 적어 둔다(컨트롤러가 **고치지 말라고** 보류한 항목):
        #    이 파일의 R19 주석은 "영영 `None` 인 필드는 삼상을 오독시키므로 키째 지운다" 고
        #    적고 ψ 를 그렇게 처리했는데, 이 필드는 브리프 지시대로 남아서 영영 `None` 이다.
        #    같은 파일이 같은 상황에 두 규칙을 쓴다.
        # ✅ Fix round 1. 되먹임의 증거는 이제 `missing_primitive`(agent-3 가 더는 안 낸다)가
        #    아니라 `reasoning`(`WriteToolImpl` 의 chain-of-thought, `wrote=false` 를 설명하는
        #    유일한 실제 출력)이다.
        red = rec["reasoning"]
        rec["compose_feedback"] = _COMPOSE_FEEDBACK % red
        rec["compose_feedback_redacted"] = None
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
                # ✅ Fix round 1. `params` compares against `first_agent2_params`, not `first`
                #    (which holds agent-3's code schema) -- otherwise this would compare agent-2's
                #    redesigned schema against agent-3's *code*, two different authors' schemas,
                #    and read a difference as "agent-2 changed its spec" when agent-2 may not have
                #    moved at all.
                rec["spec_changed_fields"] = [
                    f for f in _SPEC_FIELDS
                    if spec2[f].strip() != (first_agent2_params if f == "params"
                                            else first[f]).strip()]
                rec["spec_changed_by_feedback"] = bool(rec["spec_changed_fields"])
                rec["ungrounded_params_after_recompose"] = ungrounded_params(rec["params"])
                try:
                    p3b = compose(spec=build_compose_context(spec2, rec["reasoning_log"], blob),
                                  world_interface=iface)
                except Exception as e:
                    rec["recompose_error"] = "compose(recompose): %s: %s" % (type(e).__name__, e)
                    rec.update(first)      # every captured field goes back -- never a spliced record
                else:
                    rec["stages"].append("compose")
                    _copy_body_fields(rec, p3b)
                    rec["reasoning"] = (getattr(p3b, "reasoning", "") or "")
                    rec["recomposed"] = True

    return _finish_record(rec, kind, led, blob)
