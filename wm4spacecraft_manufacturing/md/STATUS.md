# Status — mid-build Replace completion + deck demos

> Provenance: consolidated from `HANDOFF_2026-07-14.md` (2026-07-14) + `PATH_B_COMPLETE_2026-07-15.md` (2026-07-15).

This document consolidates `HANDOFF_2026-07-14.md` and `PATH_B_COMPLETE_2026-07-15.md` into one current status.
It is current as of **2026-07-15**. The 07-15 result (mid-build fault→Replace now COMPLETES) supersedes the
07-14 handoff's core open goal; the still-relevant handoff context (remaining sub-tasks, how-to, gotchas) is
retained below, with resolved items marked `✅ DONE (see Current state)`.

---

## Current state (2026-07-15)

**Result:** the mid-build robot-breakdown Replace, which every prior session left INCOMPLETE (~172–249
/305) and the memory `constructionbots-replace-completion-limit` had declared a *structural* hard
limit, now **COMPLETES the tractor build** — verified **6/6 across 3 seeds × 2 repeats** (closed
275–280, BoundsError=0). The 3-OOD surrogate stream (fault + battery + zone) also completes end-to-end.
This **overturns the earlier "structural hard limit"** conclusion.

### What actually fixed it — the pivot

The wedge was chased for many sessions as a *distributed-replace endgame* problem (cyclic OpenBuildStep
dependencies from splitting the faulted robot's tasks across several spares). This session:

1. **Diagnosed it precisely** (B0–B2, engine changes retained as a safety net):
   - `is_goal(TransportUnitGo)` for a stuck carrier failed on `within_goal=true` but
     `next DepositCargo blocked by an OPEN OpenBuildStep` → a **schedule** block, not spatial.
   - Made the carrier rescue *stick*: teleport + pin RVO speed 0 + **force-close via
     `update_planning_cache!(env,0.0)`** (before RVO pushes it back). This closed the Object-17
     keystone (2 carriers force-closed, BoundsError=0) and advanced 200→210 — but a **second-order
     cyclic wedge** (AssemblyID-7 deposit blocked by an OPEN build step, bots double-owing interlocking
     chains) remained. Distributed replace inherently creates these interlocks.

2. **Pivoted to the robust enactment (B4).** The engine already had an **identity-preserving
   scene-tree HOT-SWAP** (`hot_swap_robot!`, `HOT_SWAP_REPLACE` flag, 21/21 unit tests) that keeps the
   faulted robot's `RobotID` and swaps only its physical body from the depot. **No schedule re-stamp →
   the cyclic-OpenBuildStep wedge is structurally impossible** (replan.jl:370 says exactly this). It was
   built earlier but left OFF; the oracle and demos used distributed replace.

   Enacting `ReplaceAgent` via hot-swap makes Replace complete cleanly. A mid-carry victim is healed in
   place (never disbanded), so no `has_edge` crash.

### Changes made this session (ConstructionBots.jl, uncommitted)

- `src/respec/replace_robot.jl` — `force_advance_stuck_carrier!` now **force-closes** a pinned at-goal
  carrier (teleport → RVO pin speed 0 → `update_planning_cache!(env,0.0)`), iterates ALL stuck carriers,
  returns `:carrier_closed` on real progress; enhanced `_carrier_goal_diag` (walks the OPEN-ancestor
  chain: ACTIVE-wait vs OPEN-cycle). [B1]
- `src/respec/replace_robot.jl` — `recover_stalled_teams!` resets `SNAP_COUNT` only on `:carrier_closed`
  (kills the reset-livelock). [B2]
- `src/respec/replan.jl` — reform-recovery path admits `:carrier_closed`/`:carrier_advanced` and
  re-derives the frontier (`reset_cache_resume!`). [B1/B2]
- `tools/demo_respec_replace_anim.jl` — `HOT_SWAP` env hook; `NOPROG` env knob (was hardcoded 30000).
- `tools/demo_surrogate_stream_anim.jl` — `HOT_SWAP` hook (default **ON**); fault event switched to
  `clear=false` so the faulted node survives for hot-swap identity preservation.
- `tools/render_deck_videos.sh` — V4 line passes `HOT_SWAP=1`, `V4_SEED` override (default 3).
- `tools/verify_fault_completion.sh` — B5 multi-seed completion harness (PASS = all COMPLETE, BoundsError=0,
  hot-swap admitted).

wm4spacecraft_manufacturing (uncommitted):
- `oracle/gen_oracle_dataset.jl` — `DS_HOTSWAP` (or `HOT_SWAP`) enacts Replace via hot-swap so fault
  labels are measured in the SAME completing world the demo runs.
- `oracle/run_hotswap_relabel.sh` — B6 scoped driver: regenerate only the tags whose label changes under
  hot-swap (fault_sp3/sp0/faultidle + battery0.05/0.12); mild-battery/zone reused.

### Evidence

- **B5 completion (verify_fault_completion.sh, HOT_SWAP=1):**
  ```
  seed rep  outcome    closed  bounderr  hotswap
   1   1    COMPLETE     280      0        1
   1   2    COMPLETE     276      0        1
   2   1    COMPLETE     280      0        1
   2   2    COMPLETE     275      0        1
   3   1    COMPLETE     280      0        1
   3   2    COMPLETE     275      0        1
   PASS 6/6
  ```
- **B7 3-OOD stream (seed 3):** stream `battery@54 zone@105 fault@139 battery@189` → PROJECT COMPLETE
  (284), 0 planner calls/decision; zone→ForbidZone, fault→Replace→hot-swap(ADMITTED), mild battery→NOOP.

### Why the surrogate story is unchanged (decision-level)

The oracle already labels consequential faults `Replace` (Replace closed more than NOOP even when it
wedged). Hot-swap turns that Replace from INCOMPLETE(~210) into COMPLETE(~280): the **decision is the
same**, the **margin is larger and now feasibility-dominant**. So the 3-OOD surrogate demo works with the
existing surrogate; regenerating labels (B6) only makes the recorded labels honest to the completing world.

### B6 label validation (DS_HOTSWAP=1, seeds 1&2) — the labels are now honest

Per-macro `complete/closed` in the completing world (C = PROJECT COMPLETE):
```
fault_sp3    best=Replace | NOOP:x154 Replace:C291 Depri:x154 Forbid:x154 Reform:x154   <- Replace now COMPLETES (was ~172-210 INCOMPLETE)
fault_sp0    best=Replace | NOOP:x142 Replace:x228 ...   (no spare -> Replace can't fully help; still best, still incomplete)
faultidle    best=NOOP    | all macros C291            (harmless victim -> restraint; Replace wastes a spare)
battery0.05  best=Replace | NOOP:x154 Replace:C291 ...  (deep battery -> Replace COMPLETES)
battery0.12  best=Replace | NOOP:x154 Replace:C291 ...
```
So the completing world yields the correct, feasibility-dominant decision structure: consequential
fault / deep battery -> Replace (complete), harmless fault -> NOOP (restraint), no-spare fault ->
Replace-but-incomplete. On the fault kind the retrained surrogate scores **regret 0.000, top-1 100%**.

#### Consistent single-world surrogate (deployed) — `surrogate_hotswap.json`

A naive merge of the hot-swap fault/deep-battery rows with OLD-world mild-battery/zone rows gave a weak
aggregate (Frankenstein of two worlds). Fixed by regenerating **ALL tags under hot-swap** (seeds 1&2,
`run_hotswap_relabel.sh` + `run_graded.sh` fill-in; mild-battery/zone complete fast, no wedge) →
`oracle/out/graded_hs_all.jsonl` (20 instances, 100 rows, single world).

Retrained cost-aware forest at **lambda=15** (the cost weight that keeps the SoC ladder sharp now that
hot-swap makes even a mild-battery Replace *complete*, so only the spare-cost separates it from NOOP):
- **LOO decision-regret 0.100**, fault regret **0.000 (top-1 100%)**, 0 catastrophic.
- Forest per-kind choices show the intended structure: battery → {NOOP×5, Replace×5} (**SoC ladder
  intact**), fault → {Replace×4, NOOP×2}, zone → {ForbidZone×2, NOOP×2}.
- Beats the strong state-blind `always_per_kind` by **+0.636** (paired-bootstrap significant).

Deployed to the demo via `SURROGATE=surrogate_hotswap.json`. Smoke (seed 5) confirms the clean story in
one stream: **fault→Replace(hot-swap), zone→ForbidZone, battery SoC 0.52→NOOP, SoC 0.02→Replace** — the
SoC-ladder flip live — all with 0 planner calls, PROJECT COMPLETE.

#### V4 render settings

Re-rendered `results/deck/V4_surrogate_stream.html` with **OOD_SEED=5**, **ANIM_FPS=60** (matches the
V1/V2 deck clips: their 868/1716 keyframes → ~15 s / ~29 s at 60 fps; V4's ~1669 → ~28 s) and the
hot-swap surrogate. `render_deck_videos.sh` V4 line now defaults ANIM_FPS=60 + SURROGATE=hotswap.

### Battery HUD consistency fix (demo integrity)

A deep-battery OOD (e.g. "R15 SoC 0.02 → Replace") was invisible in the live SoC HUD: the injection
drops the robot to 0.02, but the chosen Replace hot-swap calls `_reset_robot_health!` which sets
`fleet.soc = 1.0` within the SAME step, and the HUD snapshots `fleet.soc` once per step (after the
reset) — so 0.02 never lands in a frame, and the target (R13–R22) is scrolled below the visible R1–R12.
The bars then only ever showed the mild-battery/NOOP'd robots (~50%), contradicting the log.

Demo-only fix (no engine change) in `demo_surrogate_stream_anim.jl`:
- `BATT_CRIT` records (robot, post-drop SoC, frame) at each battery injection; before building the HUD,
  the critical SoC is re-injected into `SOC_HISTORY` for a short HOLD (~5% of frames) so the bar visibly
  slams to red before the replacement refills it.
- `_battery_live` now lists any robot that hit ≤0.25 anywhere FIRST, so the deep-battery target is
  visible without scrolling the 22-robot panel.

---

## Remaining / how to resume

### Still-open refinement (from PATH_B_COMPLETE, not blocking)

- **B6:** run `DS_HOTSWAP=1 bash oracle/run_hotswap_relabel.sh <seed> oracle/out/graded_hs`, merge with the
  existing mild-battery/zone rows, `python export_surrogate.py … --cost-aware`, `e1_analyze.py … --cost-aware`.
  Expected: fault + deep-battery Replace rows flip to COMPLETE; may sharpen the battery decision (the
  smoke's battery@54→ReformTeam blemish).
- Optional: re-render V4 after B6 for the cleanest decision narrative.

### The goal (unchanged)

Four demo clips for `wm4spacecraft_manufacturing/ConstructionBots_evolution.pptx`
(plan in `ConstructionBots.jl/tools/make_evolution_deck.py`, "VIDEO PLAN"):
- V1 · baseline healthy build — `tools/demo_wholebuild_anim.jl` (15 s)
- V2 · LLM repairs a breakdown — `tools/demo_respec_replace_anim.jl` (30 s)
- V3 · RL on the same fault — `tools/demo_rl_replace_anim.jl` (20 s)
- V4 · **HEADLINE** surrogate scoring 5 macros over an OOD stream — `tools/demo_surrogate_stream_anim.jl` (45–60 s)

All four write `results/tractor/greedy_RVO_Dispersion_TangentBug/visualization.html` (they overwrite
each other — `tools/render_deck_videos.sh` copies each to `results/deck/V<n>_<name>.html`). User then
screen-records each in a browser → mp4 → Insert ▸ Video into the deck. Only that last step is manual.

### Deck demo status

- **V1** renders + completes (`results/deck/V1_baseline_build.html`). ✅ done during 07-14 session.
- **V2** — during 07-14, because no robot-breakdown fault target both fired AND completed, V2 was
  switched to the LLM ZONE respec demo (`tools/demo_respec_forbidzone_anim.jl`) per the FALLBACK below —
  zone OOD → mock LLM → `ForbidZone` → restage 7/7 → whole-build translate Δ=[10.4,2.79] → **PROJECT
  COMPLETE**, RESPEC panel embedded (`results/deck/V2_llm_zone_respec.html`). NOTE (2026-07-15): the
  robot-breakdown Replace clip is **no longer blocked** — hot-swap makes it complete (see Current state);
  the V2 substitution can be revisited if the breakdown clip is now preferred.
- **V3** · RL on the same fault — `tools/demo_rl_replace_anim.jl` (20 s) — still to render.
- **V4** · surrogate stream — ✅ DONE (see Current state; re-rendered with OOD_SEED=5, ANIM_FPS=60,
  hot-swap surrogate → `results/deck/V4_surrogate_stream.html`).

### The core completion goal — ✅ DONE (see Current state)

The 07-14 handoff's central open task was: *make a mid-build robot breakdown (Replace) actually COMPLETE
the tractor build, regenerate the oracle labels in that completing world, then render the four
evolution-deck demo videos.* The demo the user watched builds a tractor but ended INCOMPLETE (~184 s,
~200/305 nodes) after a robot breakdown; the decision (Replace) is correct; the build did not finish.
**This is now resolved via hot-swap enactment — ✅ DONE (see Current state).** The material below is
retained for context on what was tried and the traps encountered.

### CONFIRMED (07-14 facts, verified by runs)

1. **A healthy (no-OOD) build COMPLETES**: `PROJECT COMPLETE`, 287/313 closed, seed 1, reform=120,
   NSPARE=3. So the environment CAN finish; incompletion is caused by the fault response, not the twin.
   (313 is total nodes; a full build closes ~287–291. "Complete" = the flag, not 313.)

2. **The LLM Replace demo COMPLETES**: `tools/demo_respec_replace_anim.jl` → `PROJECT COMPLETE`, 275
   closed, with `CARRIER_RESCUE=1`. This is the reference "Replace that finishes."
   (Caveat found later 07-14: does NOT reliably reproduce — see UPDATE below.)

3. **BUG #1 (FIXED) — RVO registration crash.** A transport unit formed by a respec Replace splice can
   reach `DepositCargo` without being registered in the RVO sim. Then
   `apply_cmd!(DepositCargo)` → `rvo_set_agent_max_speed!` → `rvo_get_agent_idx` throws
   `BoundsError[-1]` and **aborts the whole simulation** — this is what froze the build at ~240/313.
   Fix in `src/route_planning.jl::apply_cmd!(DepositCargo)`: if `use_rvo() && !has_vertex(rvo_global_id_map(), node_id(agent))`
   call `update_rvo_sim!(env)`; if still unregistered, skip the RVO speed-set instead of crashing.
   Verified: `BoundsError=0` everywhere after; LLM demo still completes (no regression).

4. **BUG #2 (FIXED) — oracle used reform interval 400.** The completing demos use `set_reform_interval!(120)`
   (since 2026-07-09); the oracle and the surrogate stream demo were still on 400, so the background
   team/nav recovery reacted too slowly and the endgame wedged. Unified to 120:
   - `oracle/gen_oracle_dataset.jl`: `set_reform_interval!(DS_REFORM, default 120)`
   - `tools/demo_surrogate_stream_anim.jl`: `set_reform_interval!(REFORM_INTERVAL, default 120)`
   This lifted oracle Replace from 172 → 200/240. Necessary but NOT sufficient.

5. **ROOT CAUSE of the remaining gap (07-14 identified; superseded by hot-swap fix) — fault TARGET.**
   The LLM demo's own code comment (`tools/demo_respec_replace_anim.jl`, `_single_solo_fault_target`)
   says completion is GUARANTEED only when the faulted robot has EXACTLY ONE remaining solo transport
   task: the spare then inherits a single clean task, `_serialize_spare_frontiers!` adds ZERO
   serialization gates, and the documented multi-task cyclic-cargo wedge cannot arise. The oracle used
   `pick_solo_fault_target` (solo TEAM, any number of tasks) → a multi-task victim → spare
   over-subscribed → Replace stalls at ~191–200/305.
   **BUT**: the stricter `single_solo_fault_target` finds NO candidate at the fire points (12,20,30,45,60
   OR 40..150) → `fired=false` → every arm equals the no-fault control (291, no fault happened).
   So the completing target either doesn't exist at those closed-counts, or the picker/fire-timing is wrong.
   (This whole line of attack was ultimately bypassed by the hot-swap enactment — see Current state.)

### The key UNRESOLVED question (07-14) — ✅ resolved via hot-swap

The LLM demo fires at the SAME closed-counts `(12,20,30,45,60)` and completes — but it uses
`_solo_fault_target` (solo team, lowest id), NOT the stricter single-task one. So **why does the LLM
demo complete with a solo-team fault while the oracle stalls with what should be the same fault?**

Leading hypotheses (07-14, tested in this order — each was cheap):
- **(a) It's the distributed replace, not the picker.** The LLM demo comment says the spare
  over-subscription is "now handled by the distributed replace (each task → its own nearest spare)".
  Confirm the oracle's `action_to_proposal(ctx,1)` → `ReplaceAgent` actually routes through
  `replace_robot_distributed!` and not the single-spare splice. Grep a verbose (`DS_LOG=info`) Replace
  run for "distributed" / "took over" / nearest-pool evidence. If distributed replace is NOT firing in
  the oracle, THAT is the bug — align the enactment, don't touch the picker.
- **(b) NSPARE.** LLM demo default NSPARE=2 (8 spares); oracle DS_SPARES=3 (12). More spares →
  more endgame congestion. Tested NSPARE=2 single-fire: still 191/305, so probably not the whole story,
  but retest once (a) is aligned.
- **(c) sim-step vs closed-count timing.** The LLM demo's default is `OOD_STEP=20` (a raw sim step,
  very early) when `FAULT_CLOSED=0`; the oracle fires on closed-count. Early sim-step = simpler robot
  state = single-task victim exists. If (a) and (b) fail, make the oracle fire at an early sim-step.

A scan script to list, per closed-count, how many robots are single-solo vs solo-team vs any-pending
was attempted (`/tmp/scan_targets.jl`) but produced no output (needs the navigator include + likely a
world-age fix). Re-do it — it directly answers whether a completing target exists and when.
(Answered in the UPDATE below; ultimately made moot by the hot-swap pivot.)

### UPDATE 2026-07-14 (evening) — target-availability scan DONE; hypothesis (a) ANSWERED

Ran the scan (as `FAULT_DIAG` instrumentation inside `tools/demo_respec_replace_anim.jl::ood_action!`,
env `FAULT_DIAG=1`, fast `SAVE_ANIM=0`). Findings, all reproduced across ≥3 runs (seed = demo default):

1. **`_solo_fault_target` (solo team + pending assignment) finds NO candidate for the whole build.**
   At closed 54→77 there ARE pending transporters (10→1) but EVERY one is a multi-robot TEAM
   (`soloTarget=none` at every probe). After closed=80 `withPending=0`. So the shipped demo, run fresh,
   **silently no-fires** → a clean ~283 baseline with an EMPTY RESPEC panel (`_PIPE` empty). The
   handoff's "LLM demo completes at 275 WITH a fault" does NOT reproduce on this seed — it was a lucky
   RVO draw where a solo-with-pending robot briefly existed at a closed-count trigger.

2. **Solo transport exists but is RARE + TRANSIENT.** A new probe counting active solo `FormTransportUnit`
   teams (a robot carrying ONE part alone, regardless of pending) shows `soloFTU=1` for a SINGLE probe
   window (~closed 67, e.g. `DeliveryBot(1)`), zero otherwise. The ~45-node first-iteration batch closes
   before any closed-count trigger can see the early solo transports, so a closed-count ladder can never
   catch them. New picker `_solo_ftu_fault_target` + a per-step early trigger ladder DO catch it.

3. **Hypothesis (a) is CONFIRMED but is NOT the bug.** Faulting via `_solo_ftu_fault_target` (robot R6,
   which had 3 remaining tasks) fires cleanly and the log shows distributed replace already working:
   `[REPLACE-DIST] distributed 3 task(s) across 3 nearest spare(s) (1 each); parked-faulted 4. No
   over-subscription.` → `ADMITTED`. **Yet the build STILL wedges at 249/305** with **514 `ReformTeam`
   deadlock/recovery cycles** (mock LLM admits ReformTeam over and over; `force_snapped` /
   `carrier_advanced` fire but never fully unwedge). So the remaining failure is the **endgame
   team-RE-FORMATION deadlock loop AFTER the replace**, not spare over-subscription and not picker choice.
   Enactment is already aligned — do NOT keep chasing the picker or the distributed-replace routing.

4. **`_single_solo_fault_target` (the "guaranteed completion", exactly-1-task picker) finds NO candidate
   at ANY step** even with per-step early firing → confirms the completion-guaranteed target simply does
   not exist in this build/seed.

**Reframed next lever:** the wedge is in `recover_stalled_teams!` / ReformTeam re-formation, which loops
514× without converging. Investigate why re-formed teams immediately re-deadlock (carrier positions vs
moved deposit slots?), not the fault target. Fresh repro (fast, ~2 min):
`env FAULT_TARGET=ftu CARRIER_RESCUE=1 SAVE_ANIM=0 OPEN_ANIM=0 julia +lts --project=. tools/demo_respec_replace_anim.jl`
→ wedges at 249; grep for `ReformTeam` / `force_snapped` / `carrier_advanced` cycle.

#### UPDATE 2026-07-14 (later) — wedge STRUCTURE nailed via WEDGE_DEBUG (add FAULT_TARGET=ftu WEDGE_DEBUG=1)

The 249 wedge is STABLE and STRUCTURAL (not RVO jitter). Recovery-status tally over the whole run:
`193 force_snapped`, `64 carrier_advanced`, **`0 unwedged`**, `1 distributed replace`. `_dump_forming_team_blockers`
shows the SAME 3 FTUs stuck in all 64 dumps, NO graph cycle (`CYCLE` markers = 0):

- **FTU v124 (KEYSTONE)** — team `1 ready / 0 missing` (spare DeliveryBot 16 already snapped in its slot).
  Blocked chain: `AssemblyComplete 8 OPEN <- CloseBuildStep v3 <- LiftIntoPlace v5 <- DepositCargo v6 OPEN
  <- TransportUnitGo v7 ACTIVE (Object 17)`. So v124 CANNOT form until Object 17 is deposited; that carrier
  (v7) is ACTIVE but its `DepositCargo v6` never closes.
- **FTU v166 / v177** — team `0 ready / 2 missing`. Blocked on `AssemblyComplete 2 OPEN` via an entirely
  **OPEN** transport chain (`DepositCargo v175 OPEN <- TransportUnitGo v176 OPEN <- FormTransportUnit v177
  OPEN <- AssemblyComplete 2`). `force_advance_stuck_carrier!` only touches ACTIVE `TransportUnitGo`, so it
  NEVER acts on this class — Assembly 2's transport is OPEN, not stuck-en-route.

Why the machinery can't fix it:
1. **`resolve_schedule_wedge!` is a no-op here.** It only dissolves recorded `WEDGE_EDGES` serialization
   gates. The distributed replace reported "No over-subscription" (3 tasks → 3 DIFFERENT spares, 1 each),
   so `_serialize_spare_frontiers!` added ZERO gates → `:no_wedge` every time. It was built for the
   single-spare-multi-task residual, which this isn't.
2. **`force_advance_stuck_carrier!` reports success but doesn't stick.** `apply_cmd!(DepositCargo)`
   (route_planning.jl:1100) only closes on `is_goal` — the carrier must reach AND HOLD the deposit site.
   The rescue teleports v7's RVO agent to goal, but the deposit v6 still never closes over 64 advances →
   consistent with **SPATIAL GRIDLOCK at the deposit site** (the Assembly-2 tangle congests the goal, RVO
   pushes the teleported carrier back out before the deposit-check step). i.e. the endgame blocker is
   physical congestion at Object 17's deposit, not a schedule gate.
3. **SNAP_COUNT-reset livelock.** `carrier_advanced` sets `SNAP_COUNT=0` (replace_robot.jl:566), so the
   escalation threshold (`>=SNAP_ESCALATE_AT=3`) is re-hit forever and never sustained; every dump reads
   "force-snap #3". Escalation therefore never advances past resolve_schedule_wedge!→no_wedge.

**Two candidate fixes (07-14, untested; note the 07-15 fix used a different pivot):**
- (F1, keystone-first) In `force_advance_stuck_carrier!`, after teleporting a FORMED carrier to its deposit
  goal, also PIN it (zero RVO speed / lock position) and, if `is_goal` holds, directly close the
  `TransportUnitGo` so `DepositCargo` activates next step — bypassing the RVO push-back. Test if unblocking
  Object 17 → AssemblyComplete 8 cascades and lifts the whole wedge. Risk: scene-tree/RVO desync — verify
  BoundsError=0 and no capture-assert after.
- (F2, decongest) Before force-advancing, clear a radius around the target deposit site (disperse idle/
  parked robots out of it) so the carrier can actually hold the goal. Addresses the spatial-gridlock root
  rather than forcing the node closed.
The OPEN Assembly-2 chain (FTU v166/v177) may resolve on its own once the keystone frees the robots it's
starving; if not, it needs its own lever (why is Assembly 2 not being built at the endgame — which robot
that should build it is trapped in the v124 knot?).

Repro for the dumps: `env FAULT_TARGET=ftu CARRIER_RESCUE=1 WEDGE_DEBUG=1 SAVE_ANIM=0 OPEN_ANIM=0 julia
+lts --project=. tools/demo_respec_replace_anim.jl` → grep `"what are the forming teams waiting for"`.

**Deck impact (07-14, done):** V1 renders + completes (`results/deck/V1_baseline_build.html`). Because no fault
target both fired AND completed at that time, **V2 was switched to the LLM ZONE respec demo**
(`tools/demo_respec_forbidzone_anim.jl`) per the FALLBACK below — zone OOD → mock LLM → `ForbidZone` →
restage 7/7 → whole-build translate Δ=[10.4,2.79] → **PROJECT COMPLETE**, RESPEC panel embedded
(`results/deck/V2_llm_zone_respec.html`). The robot-breakdown Replace clip was then blocked on the
completion wedge above — **now unblocked by hot-swap (see Current state).**

**Uncommitted demo-script changes (07-14 session):** `tools/demo_respec_replace_anim.jl` now has
`_solo_ftu_fault_target`, an env-gated `FAULT_DIAG` probe, a `FAULT_TARGET=single|solo|ftu|auto` selector
(default `auto` → will fire via ftu fallback and wedge — this demo is NO LONGER the deck's V2), and a
per-step early trigger ladder (`FAULT_STEP0/D/1`). These are diagnostics/levers for the completion work,
not a demo fix — keep them.

### FALLBACK if completion proves too costly (07-14 decision for the user) — no longer needed

V4 does NOT have to use a fault. Battery and zone OODs do NOT over-subscribe spares, so a surrogate
stream of **battery + zone events only** completes the build cleanly. Option:
- V4 = surrogate stream with `OOD_KINDS=battery,zone` (completes, shows the SoC ladder + zone flip).
- V2 = the LLM Replace demo (already completes at 275) covers the "breakdown → Replace" story.
This delivers a completing multi-OOD headline demo WITHOUT the full oracle regeneration, if time is short.
(2026-07-15: hot-swap makes the fault path complete, so this fallback is retained only as a contingency.)

### Files changed 07-14 session (not yet committed)

Engine (`ConstructionBots.jl/`):
- `src/route_planning.jl` — apply_cmd!(DepositCargo) RVO-registration guard (**BUG #1 fix**)
- `src/respec/replace_robot.jl` — `force_advance_stuck_carrier!` (CARRIER_RESCUE, default OFF; a stuck
  formed carrier is advanced to its deposit; distance-tracked so it only fires when genuinely stuck),
  wired into `recover_stalled_teams!` at :no_team / after repeated snaps / :stuck; `SNAP_ESCALATE_AT`;
  WEDGE_DEBUG dumps. NOTE: carrier rescue logs "carrier_advanced" but did NOT by itself complete the
  oracle Replace — it's a safety net, not the fix. (07-15 extended this to force-close — see Current state.)
- `tools/demo_surrogate_stream_anim.jl` — reform=120; project_name="tractor" (was writing to
  results/tractor.mpd/); stale-html delete + idempotent `<!--CB-PANEL-->` injection; SoC playhead uses
  `animator.time`/`.duration`; SoC-moves sanity print; `zone_overlap` feature; forest surrogate eval.
- `tools/demo_surrogate_anim.jl` — project_name="tractor"; loud error if handed a forest/interaction surrogate.
- `tools/render_deck_videos.sh` — renders the 4 clips, copies each to results/deck/ (they share one path).

Oracle / analysis (`wm4spacecraft_manufacturing/`):
- `oracle/gen_oracle_dataset.jl` — DS_REFORM (120); `single_solo_fault_target` + `DS_FAULT_PICK`
  (auto|single|solo) + `DS_FIRE_FAULT` + `DS_FAULT_CLEAR`; DS_LOG=info toggle; cascade rule; graded
  variants (faultidle/zoneharm, DS_BSOC ladder, zone_overlap). **The fault-target change was the part
  still being debugged on 07-14 — resolved 07-15 via hot-swap (DS_HOTSWAP).**
- `oracle/run_graded.sh` — DS_NOPROG=30000, DS_REFORM=120, CARRIER_RESCUE=1 defaults.
- `export_surrogate.py` — `--cost-aware`, interaction features, RandomForest export (+ `--linear`).
- `e1_analyze.py` — `--cost-aware`, `always_per_kind` baseline, difficulty audit, zone_overlap feature.

Data / results already in hand (07-14):
- `oracle/out/graded/*.jsonl` — 31 graded instances (battery ladder + fault + zoneblk/zoneharm),
  measured under the OLD reform=400 / clear=true world. **These labels must be REGENERATED** once
  completion is fixed (fault labels especially: Replace was mislabelled ~172–200/INCOMPLETE).
  ✅ DONE (see Current state): regenerated under hot-swap → `oracle/out/graded_hs_all.jsonl`.
- `surrogate_linear.json` — cost-aware RandomForest, 26 instances / 130 rows, LOO regret 0.231.
  (Superseded by `surrogate_hotswap.json` — see Current state.)

### Prior results that still stand (from the graded-OOD work, pre-completion-fix)

The graded-OOD breakthrough is INDEPENDENT of the completion bug and still valid — decisions are
scored on closed-count, and non-completion is a separate feasibility class:
- H(best|kind): 0.00 → 0.97 bits; per-kind majority 100% → 57%; model regret 0.000 → 0.181.
- model beats `always_per_kind` by **+0.481 [+0.261, +0.683]** (was +0.000 [0,0] on the old E1 data).
- battery SoC ladder (Replace ↔ NOOP flip at ~0.15), zone_overlap flip at ~0.4, fault harmless↔consequential.
See `GRADED_OOD_DESIGN.md` §6b and memory `constructionbots-graded-ood-breakthrough`.
(Regenerating labels in the completing world may shift the battery/fault numbers; the METHOD stands.)

### Exact resume steps (07-14 — the completion-search steps are now ✅ DONE via hot-swap; retained for context)

1. Rebuild the target-availability scan (fix the include/world-age) and find a closed-count (or
   sim-step) where a completing fault target exists. OR go straight to hypothesis (a):
2. Verbose Replace probe, confirm distributed replace fires:
   `cd wm4spacecraft_manufacturing && DS_KINDS=fault DS_SEEDS=1 DS_SPARES=3 DS_FAULT_PICK=solo DS_SMOKE=1 \
    DS_NOPROG=30000 DS_NOCTRL=1 DS_REFORM=120 DS_LOG=info CARRIER_RESCUE=1 \
    DS_OUT=oracle/out/p.jsonl julia +lts --project=../ConstructionBots.jl oracle/gen_oracle_dataset.jl`
   Then grep the Replace arm for "distributed"/"took over"/nearest-pool. If absent → fix enactment.
3. Once a fault config COMPLETES (Replace ~287, fired=true): regenerate all seeds
   `bash oracle/run_graded.sh 1 oracle/out/graded_v2` (and seeds 2,3 in parallel, ≤2 julia procs — OOM).
4. Retrain + audit: `python export_surrogate.py oracle/out/graded_v2.jsonl --cost-aware` and
   `python e1_analyze.py oracle/out/graded_v2.jsonl --cost-aware` (confirm model < always_per_kind holds).
5. Render V4 (completing): `bash tools/render_deck_videos.sh V4`, then V1/V2/V3.
6. Verify each results/deck/*.html: one sidebar, SoC bars move, PROJECT COMPLETE, multiple OODs.

### Operational traps (bit me during 07-14 — still apply)
- **Wrong-file trap**: run_lego_demo's `project_name` defaults to the LDRAW filename → animation lands in
  results/**tractor.mpd**/ while panels go to results/**tractor**/. ALWAYS pass project_name="tractor",
  delete stale html before a run, verify the html's mtime/size after.
- **cwd drift**: background bash sometimes loses cwd; use absolute paths for result files.
- **OOM**: gen_oracle_dataset.jl leaks across instances — one julia process per instance (run_graded.sh),
  ≤2 concurrent.
- **Julia docstring before `const`**: errors at load ("cannot document"); use a `#` comment.
- **Non-determinism**: RVO makes runs vary (force-snap counts 75/64/52/1 across identical seeds);
  verify completion over a couple of runs, not one.
