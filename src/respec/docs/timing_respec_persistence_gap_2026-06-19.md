# Respec layer: timing-only re-specs are not persisted at commit (2026-06-19)

**Status: ✅ FIXED & VERIFIED 2026-06-22.** Discovered while building the per-OOD-class
evaluation harness (`eval_respec_ood.jl`, see `ood_eval_design_2026-06-19.md`).
Everything below the `---` is the original diagnosis (kept for the record); the
**RESOLUTION** section immediately below describes the fix that closed it.

---

## ✅ RESOLUTION (2026-06-22): hybrid timing-persistent commit

The gap is closed by a single shared commit function `commit_respec!(env, milp, proposal)`
(in `replan.jl`), now used by the production replan path, the eval-harness gold
runners, AND the e2e test (the commit logic was previously duplicated in all three).
It makes a re-spec STICK two complementary ways:

1. **`persist_milp_times!(env, milp)`** — writes the MILP's solved `t0`/`tF` for every
   future node into the schedule PathSpecs. The structural pass `update_schedule_times!`
   is monotone-up (starts from the stored value, only raises via `max`), so writing the
   *full feasible* MILP schedule makes the subsequent `process_schedule!` a **fixed point**
   instead of snapping times back to earliest-start. Realized history is never
   overwritten (CLOSED nodes keep both ends; ACTIVE nodes keep their started `t0`).
   → persists **Deadline / ForbidWindow / the time side of Precede** (no graph edge needed).
2. **`persist_precede_edges!(sched, proposal)`** — additionally encodes each `Precede(a,b)`
   as a REAL graph edge `a→b` (cycle-guarded; the verifier's feasibility gate already
   rejects cyclic precedence). An edge is the one thing that survives *any* from-scratch
   time recompute, so `Precede` is robust even against paths that reset times.

Why BOTH (belt-and-suspenders): `update_project_schedule!` rebuilds edges from the
assignment matrix (drops respec edges) but does NOT reset times (keeps written times);
a hypothetical time-reset path would do the reverse. Each mechanism covers the other's
blind spot.

### Verification (`test_respec_timing_persist.jl`, LLM-free, `julia +lts`)

On a FRESHLY-BUILT tractor env (289 nodes), hand-written proposals through
`verify → commit_respec!`:

- **TEST 1 — `Precede(asm3, asm8)` via full `commit_respec!`** (binding: tF[a]=9.37 > t0[b]=2.53
  before). After commit: tF[a]=9.37, t0[b]=**9.37**, edge present. ✅ PERSISTED — exactly the
  case the diagnostic below showed reverting to 2.53.
- **TEST 2 — same Precede via `persist_milp_times!` ALONE (no edge)**, instrumented per stage:
  ```
  [MILP soln]            tF[a]=9.37 t0[b]=9.37
  [after update_project] tF[a]=9.37 t0[b]=2.53   ← the original bug (structural revert)
  [after persist_times!] tF[a]=9.37 t0[b]=9.37   ← write
  [after reset_cache!]   tF[a]=9.37 t0[b]=9.37   ← STAYS (process_schedule! is a fixed point)
  ```
  ✅ Proves the write mechanism persists timing WITHOUT an edge → Deadline/ForbidWindow covered.

### Gotchas found along the way
- **`update_schedule_times!` is ALREADY monotone-up** (treats stored t0/tF as lower bounds),
  so the fix is "write the MILP values in," NOT "modify the recompute logic." The earlier
  "highest risk / touches core pass" worry applied only to the rewrite-the-pass variant.
- **Do NOT cache the built env via `Serialization`** for these tests: serialize/deserialize
  subtly corrupts cached transforms/schedule state, which inflates the committed makespan
  ~6× and produces a FALSE "write mechanism broken" failure. `deepcopy` IS faithful; only
  serialize is not. The verification builds fresh every run.

---

## TL;DR

The verified LLM re-specification layer **enacts structural re-specs but silently
drops timing-only ones at commit.** A `Precede` / `Deadline` / `ForbidWindow` is
correctly translated by the LLM, correctly enforced in the verifier's MILP trial
solve, and `Admit`ed — but when the re-solve is committed to the schedule of
record, the constraint's effect on the timeline is **thrown away**. Only
`ForbidAgent` (which changes the *assignment structure* → reassignment) actually
persists into the executed schedule.

This is the commit-time analogue of the earlier "hollow admit": the gate says yes,
but the committed world does not reflect it.

## Root cause

Both commit-path functions recompute the schedule's start/finish times
**structurally** and discard the MILP's solved `t0`/`tF`:

- `reset_cache!(cache, sched)` → calls `process_schedule!(sched)`
  (`essential_tg_coponents.jl:1327-1328`).
- `update_project_schedule!(…, model, sched, …)` likewise rebuilds the schedule
  from the assignment matrix and re-runs the structural time pass.

`process_schedule!` computes `t0`/`tF` from the schedule **graph structure**
(precedence edges + per-node min durations, a critical-path forward pass). It has
no knowledge of constraints that live only in the MILP. So:

- **ForbidAgent** changes the *adjacency/assignment* (a robot is removed, tasks are
  re-assigned). `update_project_schedule!` writes that new structure, and
  `process_schedule!` then derives times from it → the reassignment **persists**.
- **Precede / Deadline / ForbidWindow** are *soft MILP constraints* over the existing
  `t0`/`tF` variables. They do **not** add a graph edge or change min-durations, so
  after `process_schedule!` re-derives times from the unchanged structure, the
  constraint's effect is **gone**.

## Evidence (diagnostic trace)

Hand-written `Precede(asm2, asm4)` on a real tractor env, instrumented through the
commit pipeline:

```
BEFORE respec:                 tF[asm2]=8.88   t0[asm4]=6.28   (natural: asm4 starts before asm2 finishes → Precede violated)
verify:                        Admit
MILP solution (post-optimize): tF[asm2]=8.88   t0[asm4]=8.88   satisfies tF[a]<=t0[b]: TRUE   ← MILP honored the constraint
AFTER update_project_schedule!: tF[asm2]=8.88  t0[asm4]=6.28   ← REVERTED to the natural time
AFTER reset_cache!:            tF[asm2]=8.88   t0[asm4]=6.28   ← still reverted
```

The MILP pushed `asm4`'s start to 8.88 to satisfy the precedence; the commit threw
that away and restored 6.28.

## How it surfaced (why it wasn't caught before)

The behavioral evaluation harness runs a **gold** (LLM-free) reference for each OOD
case and checks effect predicates. For `precede_rework`, the gold itself
(`commit_proposal!` with a hand-written `Precede(asm2,asm4)`) **failed its own
predicate** `tF[asm2] <= t0[asm4]` after commit — proving the gap is in the layer,
not the LLM.

It was invisible earlier because:
- `ForbidAgent` (the only case exercised end-to-end before) persists structurally.
- A `Deadline(node, 100)` / `ForbidWindow([20,50])` used in tests were **non-binding**
  (the schedule already satisfied them), so the dropped constraint changed nothing.
- An earlier `precede_rework` run scored 6/6 only because *that* env build happened
  to order `asm2` before `asm4` naturally — a **false positive**, not enforcement.
  A different env build (different greedy placement) exposed it.

## Impact by DSL kind

| DSL kind      | LLM translation | MILP enforces | **Persists at commit / execution** |
|---------------|-----------------|---------------|------------------------------------|
| `ForbidAgent` | ✅ (6/6)         | ✅             | ✅ (structural reassignment)        |
| `Deadline`    | ✅ (6/6)         | ✅             | ✅ FIXED 2026-06-22 (`persist_milp_times!`) |
| `Precede`     | ✅ FIXED 2026-06-22 (12/12, see note) | ✅ | ✅ FIXED 2026-06-22 (`persist_milp_times!` + edge) |
| `ForbidWindow`| ✅ (6/6, incl. spatial grounding) | ✅ | ✅ FIXED 2026-06-22 (`persist_milp_times!`) |

> Persistence column was ❌ for the 3 timing kinds before 2026-06-22; see the
> **RESOLUTION** section at the top.

So the layer's safety story (gate admits only feasible, invariant-preserving specs)
holds, but its **enactment** story currently only covers structural re-specs.

> Secondary note (RESOLVED 2026-06-22): `Precede` translation-target regressed from
> 6/6 (P2 run) to 3/6 after P3b appended spatial labels to *all* node labels. The two
> candidate causes (label noise vs a/b order flips) were finally diagnosed: **a/b
> order**, NOT label noise. Root cause — the `a`/`b` fields had NO description
> anywhere the model could see: the Pydantic `Precede` docstring ("a must complete
> before b") is never sent (only `TOOL_SCHEMA` is), and the prompt said nothing about
> ordering, so the model guessed a/b from the field names and the sentence's surface
> word order. Fix: add `a`/`b` field descriptions to `TOOL_SCHEMA` (schema.py) + a
> PRECEDE ORDERING block to the prompt (propose.py) stating a=prerequisite (finishes
> first), b=dependent (waits), decided by DEPENDENCY not sentence order. Verified
> env-free via `tools/translate_eval.py --case precede --samples 4`: **12/12** target
> (was 3/6), incl. the order-trap paraphrase "hold sub-assembly 4 until sub-assembly 2
> is complete" → 4/4 Precede(2,4). The spatial labels were still present in the
> fixture, confirming noise was NOT the cause.

## Possible fixes (not implemented)

1. **`Precede` → real precedence edge.** In `compile_constraint!(…, ::Precede)`,
   besides the MILP `@constraint`, also `add_edge!(sched, a, b)` (or the schedule's
   edge API) so `process_schedule!` derives `tF[a] <= t0[b]` structurally. Clean,
   and would make `Precede` genuinely persist. Verify by re-running the precede gold
   predicate (should pass on any env build). **Caveat:** must not create a cycle
   (verifier feasibility gate should already reject those).
2. **`Deadline` / `ForbidWindow`** have no pure-edge encoding (an upper bound / a
   forbidden interval). Options: carry them as schedule-level time *bounds* that
   `process_schedule!` clamps to, or insert dummy/anchor nodes. Harder.
3. **Honor MILP times at commit.** After `optimize!`, write `value.(milp[:t0/:tF])`
   into the schedule and make `process_schedule!` treat them as lower/again-bounds
   rather than recomputing from scratch. Most general but touches the core
   scheduling pass — highest risk.

## What was validated regardless

The LLM **translation** layer is solid and is the part the eval set out to measure:
NL → formal DSL with correct grounding works for ForbidAgent (robot id),
Deadline (assembly milestone), ForbidWindow (spatial zone → node set), and partially
Precede. The persistence gap is downstream of translation, in the solver-commit seam.
