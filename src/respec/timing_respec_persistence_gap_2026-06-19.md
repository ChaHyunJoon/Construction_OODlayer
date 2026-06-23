# Respec layer: timing-only re-specs are not persisted at commit (2026-06-19)

**Status: DOCUMENTED, NOT FIXED.** Discovered while building the per-OOD-class
evaluation harness (`eval_respec_ood.jl`, see `ood_eval_design_2026-06-19.md`).

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
| `Deadline`    | ✅ (6/6)         | ✅             | ❌ (timing dropped; passes iff non-binding) |
| `Precede`     | ⚠️ (3/6, see note) | ✅           | ❌ (timing dropped)                 |
| `ForbidWindow`| ✅ (6/6, incl. spatial grounding) | ✅ | ❌ (timing dropped; passes iff non-binding) |

So the layer's safety story (gate admits only feasible, invariant-preserving specs)
holds, but its **enactment** story currently only covers structural re-specs.

> Secondary note: `Precede` translation-target regressed from 6/6 (P2 run) to 3/6
> after P3b appended spatial labels to *all* node labels. Unconfirmed cause
> (label noise vs a/b order flips); not investigated.

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
