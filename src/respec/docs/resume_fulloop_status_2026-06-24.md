# Reassignment double-booking — Option 1 & Option 2 ruled out; real cause is identity, not timing (2026-06-24)

Continues `resume_fulloop_status_2026-06-23.md`. That doc proposed two fixes for the
reassignment double-booking that blocks `reassign_resume_test()` from reaching
`:complete`. Both were investigated today with the LLM-free loop and **ruled out with
evidence**. The bug is still open, but the diagnosis is now corrected: it is an
**identity-labeling** failure, not an id-propagation-keeps-a-stale-id failure and not a
temporal one.

## TL;DR

- ❌ **Option 1 (consistent id re-threading) — INSUFFICIENT.** Implemented
  `rethread_robot_ids!` (authoritative override of every `RobotGo` id along graph
  edges, rooted at `RobotStart`). `resume_test()` stays green; `reassign_resume_test()`
  still returns `:asserted` (failure point only moved from closed≈208 to ≈245).
- ❌ **Option 2 (MILP temporal exclusion) — WRONG LAYER.** Not implemented after
  reading the MILP: it cannot fix this bug *in principle* (see below).
- ✅ **Corrected root cause.** A cluster of deep-future post-deposit `RobotGo`s are
  **geometry-miss orphans**: `get_matching_child_id(DepositCargo, RobotGo)` returns
  `nothing`, so their identity is not derivable from the post-reassign graph. They keep
  stale ids and that is the double-booking. Separately, the **faulted robot is not
  cleanly removed** from future active work.

The code change is left UNWIRED (`rethread_robot_ids!` is defined but not called from
`fault_robot_and_reassign!`) so the production path matches this recorded known state.

## Option 1 — what was built and why it fails

`rethread_robot_ids!(sched, scene_tree)` in `reassign.jl`: in topological order it
OVERRIDES each `RobotGo`'s robot id from its single graph predecessor —
`RobotStart`/`RobotGo` → predecessor's robot; `DepositCargo` → the team member
released at this node's geometric slot — then re-keys the successor
`FormTransportUnit` team (the `TransportUnitNode` entity is shared with
`DepositCargo`, so the deposit team is fixed too). Unlike `propagate_valid_ids!`'s
`first_valid`, it never keeps a stale id **when it can derive one**.

The hole is the `DepositCargo` branch. Instrumented trace (single tractor build, fault
robot 1, target_closed=24):

```
[RETHREAD] vtx=274 oldid=9 pred=DepositCargo(171) -> newid=9     # most threads OK
...
[RETHREAD] vtx=268 oldid=8 pred=DepositCargo(159) -> SKIP        # geometry miss
[RETHREAD] vtx=269 oldid=4 pred=DepositCargo(159) -> SKIP
[RETHREAD] vtx=278 oldid=6 pred=DepositCargo(175) -> SKIP
[RETHREAD] vtx=272 oldid=-85 pred=DepositCargo(164) -> SKIP      # already invalid placeholder
... (vtx 262-281 cluster) ...
```

`get_matching_child_id` returns `nothing` for these (NOT an invalid team — the
post-commit `DepositCargo` team dump shows **zero** invalid slots). So the orphan's
`start_config` geometry does not align with any slot of its predecessor deposit. These
nodes keep stale ids; downstream slots fed by them (e.g. vtx 273←280, 265←279) inherit
the stale id. The double-booked robot 8 is exactly one of these (vtx 268).

Forcing the SKIPs to invalid instead is the failure mode the 06-23 doc already
recorded (`propagate_valid_ids!` then leaves RobotGos invalid → `rvo_get_agent_idx`
`BoundsError`). So re-threading cannot win here: keep-stale → double-book; force-invalid
→ rvo crash. The identity is simply not present in the post-reassign graph.

## Option 2 — why MILP temporal exclusion is the wrong layer

From `essential_tg_coponents.jl` `formulate_milp(SparseAdjacencyMILP,...)`:

1. **Each robot's chain is already time-serialized.** The assignment edge
   `free RobotGo → slot` is an `Xa` decision var; choosing it forces
   `t0[slot] >= tF[free]` (:1002), and the forced `Deposit → free` edge gives
   `t0[free] >= tF[Deposit]` (:971). Consecutive tasks of a robot cannot overlap in the
   `Xa` solution.
2. **The MILP has no robot identity.** `Xa` assigns *edges*; *which* robot flows down a
   chain is layered on AFTER the solve by `propagate_valid_ids!`. The existing job-shop
   temporal exclusion (:1038-1059) keys off `resources_reserved(node)` — a STATIC
   resource (a station) known at formulation time. A robot is dynamically assigned, so
   it is not a static reserved resource, and there is no `Xa`-expressible "tasks i and j
   share robot R" term to constrain.

The assertion that fires, `has_parent(robot,robot)` in `preprocess_env!`
(route_planning.jl:383), is purely **identity + scene-tree capture, not time**. A
temporal constraint only moves `t0/tF`; it cannot un-mislabel a robot. A post-solve
"add `Precede`, re-solve" lazy-cut variant has the same flaw: it serializes times
without removing the wrong identity, so the assertion would still fire.

## Evidence runs (all LLM-free, single tractor, fault robot 1)

| Check | Result |
|-------|--------|
| `resume_test()` (control, no reassign) | ✅ resumes to complete, monotone |
| `reassign_resume_test()` with Option 1 wired | ❌ `:asserted` (closed≈245) |
| Post-commit `DepositCargo` team scan | all teams VALID (no invalid slots) |
| Rethread trace | ~10 RobotGos in vtx 262-281 cluster SKIP (geometry miss) |
| Step resumed sim | `rvo_get_agent_idx(robot 1)` `BoundsError` — faulted robot still driven |

## The two open root causes to chase next

1. **Geometry-miss orphans.** Why does `get_matching_child_id(DepositCargo, RobotGo)`
   miss for the deep-future post-deposit `RobotGo`s (vtx 262-281)? Candidates: their
   `start_config` global transform is stale because `process_schedule!` did not update
   future-node transforms after the reassignment; or these `RobotGo`s belong to a
   multi-robot unit whose slot geometry the match can't disambiguate. Until the deposit
   geometrically contains the orphan, NO identity layer can thread it.
2. **Faulted-robot removal.** After `fault_robot_and_reassign!`, a `RobotGo` still bound
   to the faulted robot becomes active and the sim tries to drive it
   (`rvo_get_agent_idx` on the faulted id). `ForbidAgent` blocks new ASSIGNMENTS but the
   faulted robot's own frontier free node still exists and can go active. Determine
   whether the faulted robot's residual nodes should be pruned/parked on reassignment.

## Tooling left in place (LLM-free, reusable next session)

- `tools/diag_rethread.jl` — builds env once, runs fault→reassign→commit on the resume
  path, dumps `DepositCargo` teams, the rethread decisions (set `CB.RETHREAD_DEBUG[]` —
  NOTE: the debug Ref was removed when unwiring; re-add a print if needed), and steps to
  the real runtime double-book. The `backtrace_to_start` helper follows `first` inneighbor
  and wanders into build-step structure — fix it to follow the robot thread
  (RobotGo/RobotStart/DepositCargo→TransportUnitGo) before trusting its chains.
- `tools/run_rethread_check.jl` — self-contained (no Revise) one-shot of `resume_test` +
  `reassign_resume_test`. CAVEAT: running multiple reassign trials in one process
  pollutes the global RVO id map (`RVO_ID_GLOBAL_MAP`) and the 2nd+ trial crashes in
  `rvo_get_agent_idx`. Run ONE reassign per process, or reset the rvo map per trial.

`rethread_robot_ids!` stays in `reassign.jl` as a documented, UNWIRED parked building
block — a correct consistent re-thread is still likely part of the eventual fix, once
the orphan nodes are made threadable.
