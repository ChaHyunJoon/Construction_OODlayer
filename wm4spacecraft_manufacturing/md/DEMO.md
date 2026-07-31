# DEMO — the learned surrogate world model deciding, visibly

**Updated 2026-07-14.** Script: `ConstructionBots.jl/tools/demo_surrogate_stream_anim.jl`
(the older single-OOD version, `demo_surrogate_anim.jl`, is kept as a minimal reference).

## What it shows

A **stream of different OOD events** arrives at unpredictable points in the build — a robot breaks
down, a battery discharges, a no-go zone appears — and at each one the learned surrogate **scores all
five DSL macros in imagination** (`NOOP, Replace, Deprioritize, ForbidZone, ReformTeam`), predicting the
re-plan outcome for each **without running the true planner even once**, and enacts the argmax. A
docked sidebar shows the OOD timeline, the surrogate's imagined scores, and a **live per-robot battery
SoC bar** synced to the animation playhead.

The decision that matters most is no longer "which repair" but **whether to repair at all** — see
"What changed in the surrogate itself" below.

## Run

```powershell
cd C:\Users\chahj\PythonCodes\venv\ConstructionBots.jl
julia +lts --project=. tools/demo_surrogate_stream_anim.jl
```

| knob | default | meaning |
|---|---|---|
| `OOD_N` | 4 | how many OOD events in the stream |
| `OOD_KINDS` | `fault,battery,zone` | which kinds may be drawn (drawn WITHOUT replacement) |
| `OOD_SEED` | 3 | stream RNG: kinds, timings, battery severities |
| `SAVE_ANIM` | 1 | `0` = fast check, no animation |
| `SIDEBAR_W` | 380 | sidebar width (px) |
| `SHRINK` / `STALL_SOC` | 200 / 0.15 | battery physics — **must match the oracle's `DS_SHRINK`/`DS_STALL`**, or the surrogate is predicting a different world |

Output (animation **and** all three panels in one file):
`results\tractor\greedy_RVO_Dispersion_TangentBug\visualization.html`

## The three UI fixes

1. **Panels no longer overlap the 3D scene.** The old build drew a `position:fixed` overlay on top of
   the MeshCat canvas and its controls. Now a left sidebar is docked and the MeshCat pane is *shrunk*
   beside it (`margin-left` + `width: calc(100vw - Wpx)`, plus a `resize` event so MeshCat refits).
2. **Live battery SoC.** The battery layer is on from step 1; `BATTERY_STEP_HOOK` records a per-step SoC
   snapshot, and the HTML interpolates those against the MeshCat playhead — the bars drain in real time
   as you scrub (red ≤25%, orange ≤50%; parked spares stay full).
3. **A real stream, not a pile-up.** The first version drew its fire points from `[10,55]` closed nodes
   and all four events landed within 5 nodes of each other (the build closes nodes in bursts). Points
   are now spread over `[20,190]`, and kinds are drawn **without replacement**, so a 4-event stream is
   4 genuinely different disruptions rather than three breakdowns in a row.

## What changed in the surrogate itself (the important part)

Rendering the stream exposed a hole the E1–E4 numbers could not: **the surrogate had never seen a
battery event.** Its `kind_battery` and `soc` coefficients were exactly `0.000`, because the oracle's
admissibility rule (keep an instance only if NOOP is strictly worse than the healthy control) had
discarded every battery instance. On a battery OOD it emitted a near-tie and picked whatever macro had
the largest main effect — a non-decision dressed up as one.

Closing it took two engine fixes and a re-labelled dataset:

* **The battery OOD was hitting a parked spare.** `inject_battery_fault!` picked the highest-SoC robot;
  once the battery layer is on, that is always an idle spare in a depot (it never drains and owns no
  work). Every macro therefore produced a byte-identical simulation — which is what made battery look
  "harmless" in `DESIGN_NEXT.md` §2. Fixed (`_pick_battery_target`): hit a *working* robot that a
  Replace can actually act on. The same event now costs 151 vs 291 closed nodes if ignored.
* **The NOOP arm was not really NOOP.** A deep discharge stalls the robot, and the stall raises its own
  breakdown alarm — which the fixed background policy answered with a canonical Replace, *inside the
  NOOP arm*. Every macro came out identical again. The studied decision now owns its own consequences;
  only `:reform` (background navigation/team recovery) stays canonical.
* **Cost-aware labels.** Harmless instances are kept, and each macro is charged its adaptation cost
  (`y = closed − λ·cost(macro)`, λ = 3 nodes). A spare, a restage and a team re-form are not free, so
  when an OOD is absorbed anyway **NOOP wins** — the model can finally learn restraint.

The demo's producer is now a **RandomForest** (60 × depth 6) exported to JSON and walked natively in
Julia. A linear model was tried first and cannot do this job: the correct macro flips at a *threshold*
(SoC ≈ 0.15, zone overlap ≈ 0.4), and an additive model gives every macro the same slope, so the curves
never cross (it scored 0.500 decision-regret on the zone instances, top-1 0%). Trees represent
thresholds natively — and trees are the model class E1–E4 actually use. Julia still needs no Python at
decision time, which matters because PyCall's environment carries `rvo2` only and must not be disturbed.

## The severity ladder the demo now exercises

Measured by the oracle (see `GRADED_OOD_DESIGN.md`) — same OOD kind, opposite answers:

| battery SoC after the discharge | what happens if ignored | correct macro |
|---|---|---|
| 0.05 – 0.12 (deep) | stalls immediately, mid-haul, holding 4 pending tasks | **Replace** (172 vs 151 closed) |
| 0.20 (marginal) | stalls *later*; replacing it is **worse** | **NOOP** (213 vs 172) |
| 0.35 – 0.60 (mild) | finishes on the remaining charge | **NOOP** (291 ✓complete vs 172) |

| zone overlap with a pending staging circle | correct macro |
|---|---|
| 0.00 (open floor) | **NOOP** — every macro completes |
| 0.31 | **NOOP** — the restage costs more than it saves (244 vs 225) |
| 0.49 | **ForbidZone** — 291 ✓complete vs 239 |

A state-blind policy — even the strongest one, "the best fixed macro *per OOD kind*" — is wrong on
roughly half of these. That is what the demo makes visible.

## Known limitation, honestly stated

A **mid-build Replace still does not let the build finish** (it closes more nodes than doing nothing, so
the *decision* is right, but the run ends INCOMPLETE). Diagnosed 2026-07-14 with `WEDGE_DEBUG=1`:

```
DepositCargo v38 (TransportUnit 12)   OPEN
   <- TransportUnitGo v39             ACTIVE     # a FORMED carrier, en route, that never arrives
FTU v84  OPEN (2 ready / 0 missing)   <- RobotGo(R10) <- DepositCargo v38
FTU v109 OPEN (2 ready / 0 missing)   <- AssemblyComplete <- CloseBuildStep <- LiftIntoPlace <- v38
```

Every waiting team traces back to **one carrier that never reaches its deposit** — and it is a vicious
cycle: reform snaps the waiting teams into their exact carrying slots, where they sit motionless and
become obstacles in that carrier's path, so it never arrives, so the deposit never closes, so reform
snaps them again (75× observed, then the no-progress cap). Force-snapping only ever touches *forming*
teams, so it can never help a formed one. This corrects the earlier "endgame navigation congestion"
guess: the jam is one specific carrier, not a broad gridlock.

`force_advance_stuck_carrier!` (`respec/replace_robot.jl`) implements the fix and is **off by default**
(`CARRIER_RESCUE=1`): switching it on changes the twin's dynamics, so every oracle label measured
without it — Replace = 172 closed, and so on — would have to be regenerated before the surrogate could
be trained against the rescued world. It also did not reproduce on every run (RVO makes the sim
non-deterministic; the stall appeared with 75, 64, 52 and 1 force-snaps across runs). Enabling it
together with a full dataset regeneration is the next step, not a tonight step.

## Regenerate the surrogate after new data

```powershell
python export_surrogate.py oracle\out\graded.jsonl --cost-aware      # forest (what the demo deploys)
python export_surrogate.py oracle\out\graded.jsonl --cost-aware --linear   # Ridge, for comparison
python e1_analyze.py oracle\out\graded.jsonl --cost-aware            # difficulty audit + baselines
```
