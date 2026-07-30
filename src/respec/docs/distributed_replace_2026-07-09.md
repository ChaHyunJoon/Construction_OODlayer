# Distributed ReplaceAgent — completion fix for mid-build robot-breakdown (2026-07-09)

## Problem (verified)
A mid-build robot-BREAKDOWN handed the dead robot's **several** transport tasks to a **single** spare
(`replace_robot!`). One spare can only be in one place, so the other transport units wait forever and a
downstream `OpenBuildStep` never activates — a **cyclic cargo-dependency** that leaves the build
INCOMPLETE (verified: no-OOD control completes; every mid-build fault wedged near the end; WEDGE_DEBUG
showed e.g. `OpenBuildStep v140` never active with 3 `TransportUnitGo` waiting on it). The reassign
re-solve path wedges too (documented double-booking, bug #1).

## Fix: `replace_robot_distributed!` (replace_robot.jl)
Distribute the dead robot's N tasks across **N nearest spares — one task each** — instead of piling
them on one spare. Each spare then has ≤1 active transport task, so no serialization is needed and
nothing double-books; the freed tasks run concurrently exactly like the original multi-robot build.
- **Proximity**: each task → `nearest_pool(task pickup goal)` so a close spare reacts immediately
  (not a far parked robot arriving late) — the requested "nearest available robot responds".
- **Wired**: replan.jl ReplaceAgent path, BEFORE the single-spare splice; `:single_task` / `:no_frontier`
  / `:insufficient_spares` fall through to the existing single-spare (or reassign) path.
- **LLM/RL symmetry preserved**: both still emit only `ReplaceAgent`; the distribution is enactment.
- **Verified**: forced R1 fault, LLM demo (R2), RL demo (R2, RL chose Replace), and the full-sim
  comparison all reach `PROJECT COMPLETE`.

## Robustness

### B1 — 2-phase transactional (DONE)
`replace_robot_distributed!` reserves a spare per task in PHASE 1 (no schedule mutation); if any task
can't get a spare it ROLLS BACK every popped spare (`register_spare!`) and returns `:insufficient_spares`
with the schedule untouched, so the caller's single-spare fallback runs on a clean graph. PHASE 2
commits all re-routes at once. No half-mutated state.

### B2 — spare exhaustion (ample provisioning now; renewable = future)
Spares are a **consumable** resource (`pop_spare!` removes permanently). Distribution uses N spares per
fault, so repeated faults deplete the pools; when spares < tasks it falls back to the single-spare
splice (which re-wedges). **Current mitigation**: provision amply (`n_spare_per_pool` ≥ expected
faults × tasks/fault; 4 dirs × k). **Future (renewable spares)**: when a distributed spare finishes its
task (its `DepositCargo` closes → it is free), return it to a pool for reuse. Requires making a finished
spare's TERMINAL rest `RobotGo` usable as a fresh idle entry (generalize `_idle_free_node` to accept a
closed terminal rest, un-close it, and re-splice) so the pool is renewable — unlocks UNBOUNDED faults.

### B3 — graceful fallback (DONE via B1)
On `:insufficient_spares` the schedule is left clean (B1 rollback) and the single-spare path runs; it
may not complete a dense multi-team fault, so ample provisioning (B2) is the reliable guard. The
endgame `resolve_schedule_wedge!` remains as a last-resort recovery for serialization-gate wedges.

## Making an unaddressed breakdown CONSEQUENTIAL (for fair comparison)
`fault_robot!(safe=true)` targets a transporter whose carry is SOLO so the replace never trips
`has_edge`. The picker tries `pick_solo_fault_target` (STRICT: all remaining teams solo) first and,
if none qualifies, falls back to `pick_solo_frontier_target` (RELAXED: solo FRONTIER carry at a clean
task boundary). The relaxed path is now the usual one: once phantom spares are excluded from the
initial assignment (`is_spare` skip in task_assignment.jl) NO real robot on tractor has all-solo teams,
so STRICT alone would defer forever and the fault could never fire. A get_cmd guard (route_planning.jl)
sets a faulted robot's `max_speed=0` until replaced, so an UNADDRESSED breakdown STALLS the build
(no-adapt → INCOMPLETE); once ReplaceAgent parks the faulted nodes they aren't driven, so adapt is
unaffected. Combined with `clear=true` (tow the dead body off-grid) the immobilized robot doesn't block
the build (non-fragile).

## Multi-OOD status (findings)
CORRECTION (2026-07-11): the earlier claim "single robot-breakdown completes reliably, 292/313" was an
ARTIFACT. The `n_spare_per_pool` "spares" were injected BEFORE task assignment, so greedy gave all of
them real work (phantom spares); the fault then landed on a phantom spare and `replace_robot_distributed!`
double-booked its already-assigned free node → permanent `all_missing` wedge. FIXED by A-1 (exclude
spares from assignment) + B1 (`_idle_free_node` rejects a node with an outgoing assignment edge). With
the fix, a GENUINE real-robot breakdown under RVO=1 (seed 1, Bot 1) gives: control COMPLETE 291/313;
no-adapt INCOMPLETE 174/313; Replace INCOMPLETE **195/313** (Replace > no-adapt, so Replace is oracle-best
and the instance is admissible — the double-book that made Replace *worse* than no-adapt is gone). Replace
still does not fully COMPLETE: that is the SEPARATE mid-build completion limit below (cyclic OpenBuildStep
over-subscription), not the double-book. Two multi-OOD streams hit further SEPARATE limitations:
- **Multi-FAULT (2–3 breakdowns on one build)**: the SECOND replace can trip
  `has_edge(scene_tree, agent, robot_id)` in `FormTransportUnit.apply_cmd!`. Root: `_restamp_robot_go!`
  swaps the FTU team dict (`swap_robot_id!`) but a later fault whose target is already captured
  in/entangled with a unit modified by the FIRST distributed replace leaves a stale scene-tree capture
  edge. FIX NEEDED: make the re-stamp update the scene-tree capture edge (remove old, add new) so
  distributed replaces COMPOSE. (Recovery spares are now excluded from fault targets, which helps but
  does not fully close it.)
- **Battery→DeprioritizeAgent in the full sim**: the soft-bias enactment does a full MILP re-solve
  which wedges the build very early (61/313, worse than no-adapt) — the same re-solve/double-booking
  fragility as the reassign path. FIX NEEDED: apply the Deprioritize objective bias WITHOUT a full
  re-solve (bias future assignments only), or make the re-solve preserve the running frontier.

## Files
`src/respec/replace_robot.jl` (replace_robot_distributed!), `src/respec/replan.jl` (wiring),
`src/respec/ood_injection.jl` (pick_solo_fault_target, fault_robot! safe), `src/route_planning.jl`
(breakdown immobilization), `src/navigator/ood_stream.jl` (schedule_random_ood! safe_fault),
`tools/ood_compare_fullsim.jl` (completing comparison, single + multi-OOD).
