# Labeling & OOD Pipeline — Operations Manual

*How the oracle labeling works, how it was restored after `decpomdp/` was deleted, and how it
operates in the monitor UI.*

---

## 0. TL;DR

- **Labeling** = for each OOD situation, run every candidate recovery macro through the *real*
  simulator to the end and record its outcome (`complete` / `closed` / `makespan`). The macro with
  the best outcome is the **oracle label** the surrogate learns to predict.
- `decpomdp/examples/` was deleted; it only supplied **4 adapter functions**. They are rebuilt in
  [`oracle/ood_mdp_shim.jl`](oracle/ood_mdp_shim.jl) on surviving `CB` code, so labeling runs again.
- **Generate labels** (Julia): `julia --project=. ../wm4.../oracle/gen_oracle_dataset.jl` with `DS_*`
  env vars. **Consume labels** (Python): `e1_analyze.py`, `sweep_surrogate.py`, `ladder.py`.
- **Watch it in the UI**: `run_demo.jl` emits a monitor stream → open `tools/monitor/dashboard.html`.
  The OOD Feed + "environment descriptors" panel show exactly the state each label is keyed on; the
  respec panel shows the macro (the same DSL the labeler sweeps).

---

## 1. What "labeling" means here

The surrogate's job is to pick a recovery **macro** the instant an out-of-distribution (OOD) event
fires. To train it we need ground truth: *which macro was actually best?* We get that by brute force.

For one **instance** = (OOD kind × severity × seed × spare-provisioning):

1. Run the build until the OOD fires; **capture the decision-time state features** (the public info a
   controller can see: `soc`, `severity`, `spare_count`, `agent_pending`, `zone_overlap`, `progress`…).
2. For **each** candidate macro `a ∈ {0 NOOP, 1 Replace, 2 Deprioritize, 3 ForbidZone, 4 ReformTeam}`,
   apply that macro at the event and **run the whole build to completion**, recording `RunMetrics`
   (`complete`, `closed` nodes, realized `makespan`, `feasible`).
3. Write **one JSONL row per (instance, macro)**. The **oracle-best** macro is the feasibility-
   lexicographic winner (complete first, then most closed nodes, then shortest makespan).

The surrogate has something to learn only because the best macro **varies with state** — deep battery
→ Replace, mild battery → Deprioritize/NOOP, blocking zone → ForbidZone, idle-robot fault → NOOP.
That variation is encoded in the state features, so a state-reading model beats any "always macro X".

**Files that produce/consume labels**

| Stage | File | Role |
|---|---|---|
| produce | `oracle/gen_oracle_dataset.jl` | the labeler (sweeps macros, writes JSONL) |
| **restore** | `oracle/ood_mdp_shim.jl` | **rebuilt** MDP adapter (was `decpomdp/examples`) |
| consume | `e1_analyze.py` | load + featurize + LOO decision-regret audit |
| consume | `sweep_surrogate.py` / `ladder.py` / `master_experiment.py` | HP sweep · severity ladder · tie/λ |

---

## 2. What broke and how it was restored

`gen_oracle_dataset.jl` used to `include` two files from a now-deleted folder:
`decpomdp/examples/ood_env.jl` and `ood_env_mdp.jl`. Investigation showed:

- The generator body references **only 4 symbols** from those files:
  `event_context`, `valid_actions`, `canonical_action`, `action_to_proposal`.
- `run_one`, `RunMetrics`, and all environment setup are **local or `CB.*`** — nothing else was lost.
- The files were **never committed**, so git cannot restore them.

So the fix is one replacement file, [`oracle/ood_mdp_shim.jl`](oracle/ood_mdp_shim.jl), rebuilt on
surviving `CB` code. The generator's include block now points at it:

```julia
# oracle/gen_oracle_dataset.jl (patched)
include(joinpath(@__DIR__, "ood_mdp_shim.jl"))   # was: decpomdp/examples/ood_env.jl + ood_env_mdp.jl
```

**What each rebuilt function does** (all keyed to surviving code, so labels stay compatible):

| function | rebuilt from | behaviour |
|---|---|---|
| `event_context(env, ev)` | `CB.ood_truth_log()` (`ood_truth.jl`) | `ev` is only the NL string; the real event (type/agent/zone/soc) is recovered from the OOD **truth log** every injector auto-writes. Returns `(type, agent, zone, assembly, soc, after)`. |
| `valid_actions(ctx)` | `random_macro_respec` repertoires (`baselines.jl`) | legal macros per type: fault/battery `{0,1,2}`, zone `{0,3}`, reform `{0,4}`. |
| `canonical_action(ctx)` | `canonical_respec` (`baselines.jl`) | default macro: fault→Replace, zone→ForbidZone (if it blocks an assembly), battery→Replace if `soc ≤ REPLACE_SOC_THRESHOLD` else Deprioritize, reform→ReformTeam. |
| `action_to_proposal(ctx, a)` | DSL ctors in `spec_dsl.jl` | macro id → `RespecProposal([ReplaceAgent / DeprioritizeAgent / ForbidZone / ReformTeam])`; NOOP and any invalid cross-type macro → `nothing`. |

This is the **same `RespecProposal`** the LLM path (`replan.jl`) and the monitor UI produce — so
verify → dispatch → re-solve downstream is unchanged.

> **Status by OOD kind** (full record: [`sweep_lab/shim_validation.txt`](sweep_lab/shim_validation.txt)):
> - **fault, battery — VALIDATED.** 14/14 logic unit tests pass; an end-to-end battery run reproduces
>   the pre-deletion **decision** (Replace is oracle-best for a deep-discharge battery, old and new)
>   on an identical scenario. Two fixes make `valid_mask` + the "invalid-macro == NOOP" structure match
>   the dumps exactly. Absolute `closed` drifts ±3 nodes (MILP 5%-gap), which the label is robust to.
> - **zone (zoneblk) — shim correct, but FLAGGED.** `DS_SHIM_DEBUG=1` proves `event_context` recovers
>   the zone + assembly and `action_to_proposal` builds the ForbidZone proposal. But the current CB
>   stalls zone builds low and ForbidZone no longer recovers them (NOOP itself: 131 now vs 235 in the
>   dumps; same seed+severity gives a **different overlap**, so the zone is placed differently). That is
>   **CB code drift in staging-geometry / restage / nav-wedging — outside the 4 restored adapter
>   functions** — and needs a separate look at `restage_zone.jl`. Zone labels are recorded honestly but
>   don't yet reproduce the dumps' ForbidZone-recovery regime.

---

## 3. Running the labeler (Julia)

Run from the **`ConstructionBots.jl` repo root** (needs its `--project`):

```bash
julia --project=. ../wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl
```

Everything is controlled by environment variables:

| env var | default | meaning |
|---|---|---|
| `DS_KINDS` | `fault,zone,battery` | OOD kinds to generate (also `faultidle`, `zoneharm`, `zoneblk`) |
| `DS_SEEDS` | `1,2,3` | RNG seeds → distinct instances |
| `DS_SPARES` | `3` | spare-robots-per-pool levels (fault instances vary this) |
| `DS_SMOKE` | `0` | `1` = just **one** instance (fast end-to-end check) |
| `DS_OUT` | `out/oracle_dataset.jsonl` | output JSONL path |
| `DS_FIRE_FAULT` | `12,20,30,45,60` | build-progress points (closed-node counts) at which to fire |
| `DS_NOPROG` | `8000` | no-progress cap (lower = faster gen, coarser stall labels) |
| `DS_HOTSWAP` / `HOT_SWAP` | `0` | `1` = enact Replace as an identity-preserving depot hot-swap |

**Examples**

```bash
# smoke: one battery instance, confirm the pipeline runs end to end
DS_SMOKE=1 DS_KINDS=battery DS_OUT=sweep_lab/shim_smoke.jsonl \
  julia --project=. ../wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl

# fill the gaps found in the study: more seeds (boost n) + the missing zone severities
DS_KINDS=battery,fault,zoneblk DS_SEEDS=4,5,6,7 DS_OUT=oracle/out/graded/more_s4-7.jsonl \
  julia --project=. ../wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl
```

Each row is `{kind, severity, soc, spare_count, agent_pending, zone_overlap, progress, macro,
complete, closed, makespan, fired, valid_mask, …}`. Cost per macro ≈ one full simulation, so a full
kind×severity×seed grid is minutes-to-hours — run larger grids in the background.

**Consume** the labels in Python (no Julia needed):

```bash
python e1_analyze.py <dataset.jsonl>            # LOO decision-regret audit + difficulty
python sweep_surrogate.py <dataset.jsonl> --cost-aware   # HP sweep (regret + tie-rate)
python ladder.py                                # per-kind severity ladder validity
```

---

## 4. How it operates in the UI

The monitor UI is a **browser dashboard** that replays (or live-drives) a simulation and shows the OOD
events, the recovery macro chosen, and the state the decision was made on — i.e. the same material the
labeler records, made visible.

### 4a. Produce a stream, then open the dashboard

```bash
# from ConstructionBots.jl root — emits tools/monitor/streams/<model>__<case>.jsonl
DEMO_OOD=fault DEMO_N=3 DEMO_ROBOTS=10 DEMO_MODEL=tractor.mpd \
  julia --project=. tools/monitor/run_demo.jl
```

- `DEMO_OOD ∈ {none, battery, fault, zone, fault_battery, fault_zone, battery_zone}` — **which** kinds.
- `DEMO_N` — **how many** OOD events to inject (0 = case default = one per kind). `>0` overrides the
  fault/battery count, cycling the case's robot kinds across the build; a zone always fires once up
  front (spatial re-staging is only transform-safe before any build step opens). Verified: `DEMO_N=3`
  fault → 3 breakdowns at closed≈[30,130,229], build still completes.

Then run through the control server and open the dashboard: **in the case bar, set the `OOD events`
number field** (0–20) and press `Start live session` — the server passes it as `DEMO_N`. (Or open
`dashboard.html` for replay and point `STREAM_URL` at an emitted `.jsonl`.)

### 4b. What each panel shows

| Panel | Shows | Relation to labeling |
|---|---|---|
| **Header** | sim time, completed assemblies, fleet size, **OOD count** | the OOD count = how many events fired this run |
| **Control bar** | play/pause, timeline **scrub**, model + **OOD-group** selectors | pick the scenario; scrub to the moment an OOD fires |
| **Factory View** (MeshCat) | live 3-D build; **inject bar** (X/Y/R + "Inject Forbid Zone") | in a **live session** you can inject a zone by hand and watch the respec |
| **OOD Event Feed** | each event, its type, and the **macro** chosen | the macro = `action_to_proposal`'s output = a labeled candidate |
| **OOD input · environment descriptors** | the decision-time **state features** | exactly the features a label row is keyed on (`soc`, `severity`, `spare_count`, …) |
| **Fleet States / Assembly Tree / Robot Schedule** | per-robot status, build DAG, Gantt | the consequences a macro's `RunMetrics` label summarizes |

### 4c. Replay vs live

- **Replay** (default, `LIVE:false`): load a finished `.jsonl` once and scrub the timeline. Use this to
  review what the labeler saw for a given instance.
- **Live session** ("Start live session", `LIVE:true`): the dashboard polls appended frames and you can
  **inject a Forbid Zone interactively** (set X/Y/R → "Inject Forbid Zone"). The event flows through the
  same seam the labeler uses, so the macro shown is the same one `canonical_action` would pick.

### 4d. Reading a labeling decision in the UI

1. Pick a scenario (`DEMO_OOD=battery`), run `run_demo.jl`, open the dashboard.
2. Scrub to the OOD event in the **feed** — note its type and the **environment descriptors** (e.g.
   `soc=0.12`). This is one label instance's feature vector.
3. The feed shows the chosen macro (e.g. **Replace**, because `soc ≤ 0.2`). That's
   `canonical_action` — the same rule the labeler's canonical background policy uses.
4. To see *why* that macro is best, the offline labeler ran **all five** macros to completion; the
   dashboard shows the one enacted. Cross-reference the JSONL row set for that instance to see the
   full `closed`/`complete` outcome of every macro.

---

## 5. Filling the gaps the study found

The parameter study surfaced three data gaps the restored labeler can now close:

1. **n too small for significance** — the HP-tuning win was significant at n=31 but not n=20. Add
   **fault/battery** seeds (`DS_SEEDS=4,5,6,7,8`) to push n up. These kinds are validated, so new
   labels are trustworthy.
2. **more graded battery severities** (`DS_KINDS=battery`, varied severities) to straddle the decision
   boundary and reduce the 29% tie rate.

Generate into `oracle/out/graded/`, then re-run `python ladder.py` and
`python sweep_surrogate.py <combined> --cost-aware`.

> **zoneblk is blocked upstream.** Regenerating zone data will NOT fix the WEAK zone ladder until the
> CB staging-geometry / restage drift (see the zone status above) is resolved — the current CB doesn't
> reproduce ForbidZone recovery, so every new zone label collapses to NOOP. Fix `restage_zone.jl` /
> the zone placement first, then regenerate. Until then, keep the study's fault+battery conclusions and
> treat the zone ladder as pending. A wrong-regime gap-fill attempt was archived to
> `sweep_lab/archive_unusable/`.
