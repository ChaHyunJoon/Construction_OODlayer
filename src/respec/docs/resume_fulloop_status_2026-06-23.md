# Resume full-loop (Piece 1) — status & the reassignment double-booking bug (2026-06-23)

Implements **Piece 1 (Resume full-loop, ⑥⑦)** of
`autonomy_impl_workflow_2026-06-22.md`: make a committed re-spec STICK while the sim
keeps running to a finished build, instead of restarting from the project roots.

## TL;DR

- ✅ **Resume infrastructure is DONE and VERIFIED.** `reset_cache_resume!` lets a
  mid-build sim continue to a complete, valid build (`closed_set` monotone, never
  regressing) — the blocker the workflow doc identified (`reset_cache!` wiped
  `closed_set` and re-seeded from ROOT) is closed.
- ❌ **A separate, pre-existing reassignment bug was uncovered** by actually resuming
  to completion: `fault_robot_and_reassign!` can produce a schedule that
  **double-books a healthy (non-faulted) robot** across two un-serialized branches.
  It is invisible unless you resume (the old standalone reassign reset the cache from
  ROOT and never executed the result), and it is **still open**.

So the user's stated blocker ("after robot reassignment there is no simulation code
that continues the build to the end") is addressed at the infrastructure level; the
reassignment path additionally needs the id-threading fix below before it completes.

## What was built

In `replan.jl`:
- **`reset_cache_resume!(cache, sched)`** — resume-preserving sibling of
  `reset_cache!` (essential_tg_coponents.jl:1327). Keeps `closed_set`; rebuilds
  `active_set` as the **frontier** = every not-closed vertex whose predecessors are
  all closed (roots qualify vacuously — same readiness test `update_planning_cache!`
  uses to activate a successor); rebuilds `node_queue` via `isps_queue_cost`. Keeps
  `process_schedule!` (a fixed point on the persisted MILP times).
- **`commit_respec!(env, milp, proposal; resume=false)`** — `resume=true` routes to
  `reset_cache_resume!`. Default `false` keeps every existing caller (tests, eval,
  from-scratch re-plan) byte-identical.

In `reassign.jl`:
- **`fault_robot_and_reassign!(...; resume=false)`** — `resume=true` uses
  `reset_cache_resume!` instead of `reset_cache!`.

In `replan.jl maybe_respecify!` (the live-sim production path): both the
`commit_respec!` and `fault_robot_and_reassign!` calls now pass `resume=true`.

Exported `reset_cache_resume!` (ConstructionBots.jl).

Fast loops (`tools/dev_session.jl`, LLM-free, Revise):
- **`resume_test()`** — VERIFIED green: mid-build env → `reset_cache_resume!` (no
  schedule change) → resumes to a complete build, `closed_set` monotone.
- **`reassign_resume_test()`** — KNOWN-OPEN: fault → reassign → resume; currently
  returns `:asserted` (the double-booking below). Flips to `:complete` once fixed.
- `tools/run_full_loop.jl` — enabled-seam e2e driver (production seam
  `step_environment! → respec_step! → update_planning_cache!`); reaches completion on
  the resume path, blocked on the reassign path by the same bug.

## Evidence (single tractor build, 289 nodes, fault robot 1 at closed=46, LLM-free)

| Test | Result |
|------|--------|
| **(A) plain resume** — `reset_cache_resume!`, no schedule change | ✅ **complete** 46→279/289, iters=585, monotone |
| **(B) reassign + resume** to completion | ❌ **asserted** at closed≈208–223 (varies w/ solver), `has_parent(robot,robot)` in `preprocess_env!` |

(A) isolates the frontier recompute and proves it sound. (B) fails inside the
*reassigned* schedule, not in the resume logic.

## Root cause of (B): healthy robot double-booked

At the assertion, the offending node is a free `RobotGo` whose robot is still
physically captured by a transport unit. Dumping that robot's full schedule timeline
(robot 9, **not** the faulted robot 1) shows it on **two concurrent, un-linked
branches**:

```
FormTransportUnit-19  CLOSED  t=31.17   <- robot 9 captured by TU-19
TransportUnitGo-19    ACTIVE  t=31.22   <- TU-19 transporting (robot 9 inside)
RobotGo-274           ACTIVE  t=34.65   <- robot 9 ALSO "free", moving       (graph pred = DepositCargo-3)
DepositCargo-19       future  t=39.25   <- TU-19 not yet deposited
```

`RobotGo-274` (free) and `TransportUnitGo-19` (robot 9 captured) are both ACTIVE in
overlapping time windows with no precedence edge between them → robot 9 is doing two
things at once. `preprocess_env!` (route_planning.jl:383) catches it: a free
`RobotGo`'s robot must be its own parent, but robot 9's parent is TU-19.

**Why:** `release_pending_assignments!` (reassign.jl) clears stale valid ids only on
the **faulted** agent's downstream `RobotGo`s. A HEALTHY robot's future `RobotGo`s
also carry stale valid ids; `propagate_valid_ids!`'s `first_valid` keeps them, so the
re-solve can thread that robot onto a transport team it is not serialized with. This
never mattered before because the old reassign discarded the schedule (reset from
ROOT); resuming executes it and the inconsistency surfaces.

## Fix attempt that did NOT work

Clearing stale ids on **every** non-frozen, non-active, non-origin `RobotGo` (not just
the faulted agent's) before the re-solve — so id propagation re-derives all future
threads. Result: `propagate_valid_ids!` then leaves some `RobotGo`s with invalid ids,
so `rvo_get_agent_idx` throws a `BoundsError` (the robot isn't in the RVO id map)
during stepping. Over-resetting breaks id threading worse than the original bug. The
code change was reverted; the faulted-only clearing remains, with a `KNOWN-OPEN`
comment in `release_pending_assignments!`.

## Next step (the actual reassignment fix)

The re-solve must produce a schedule where each robot is a single serial thread. Two
candidate directions:
1. **Consistent re-threading:** after `update_project_schedule!`, walk each robot's
   chain from its `RobotStart` origin and re-stamp ids strictly along graph edges,
   so a robot cannot appear on two branches (don't rely on `first_valid` picking up
   stale ids). Verify with `reassign_resume_test()` → `:complete`.
2. **MILP-level exclusion:** ensure the assignment model forbids a robot occupying
   two transport tasks whose time windows overlap (if it currently only links via
   ids, add the structural/temporal constraint).

Iterate LLM-free via `tools/dev_session.jl`: edit `reassign.jl` → Revise reloads →
`reassign_resume_test()`; it should flip from `:asserted` to `:complete`. The resume
infrastructure underneath (`reset_cache_resume!`) is already proven by `resume_test()`.
