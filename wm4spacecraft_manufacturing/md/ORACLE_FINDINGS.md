# Oracle harness findings (2026-07-09)

What the first oracle attempt taught us. Two of these are **corrections to `EVALUATION.md`**, not
just implementation bugs — they change what "success" means.

## 1. 🔴 The speed metric was measuring the wrong quantity

`makespan(env.sched)` is the **planned** schedule makespan (max `tF` over the schedule). A no-op
performs no re-plan, so `tF` never changes → **the planned makespan is invariant under no-op and is
blind to the cost of the disruption.**

Measured on the healthy vs faulted build (bare-loop harness, tractor):

| | closed | planned makespan | **realized steps** |
|---|---|---|---|
| healthy control | 283/297 | 10.425 | **419** |
| no-op + fault | 283/297 | 10.425 | **887** (2.1×) |

The disruption cost is entirely in the **realized execution time**, which `full_demo.jl` reports as
`stats[:Makespan] = time_steps * env.dt`. **Use the realized makespan.** This invalidated the first
sweep, which concluded "the fault is harmless / deprioritize ties no-op."

## 2. 🔴 Missing control ⇒ no way to know if an OOD instance is informative

The first design had no **no-fault control**, so "no-op completes fine" was unreadable. Adopt:

> **Instance-admissibility rule.** An OOD instance enters the oracle eval set **only if `no-op` is
> strictly worse than the healthy no-fault control** (on completion, or closed-node count, or
> realized makespan). If `no-op == control`, the fault was harmless and the instance teaches nothing
> about adaptation — discard it.

This is exactly the trap `_pick_active_robot`'s own comment warns about ("a fault on an already-done
robot is a no-op either way, which makes adaptation look irrelevant").

Corollary: `project_complete` is a **weak predicate** — the healthy control closes only 283/297
nodes yet reports complete. So `completion_rate = closed/nv` is *not* "fraction of build done"; it
is only meaningful **relative to the control**.

## 3. 🔴 The hand-rolled harness diverged from the production sim

`gen_oracle_faults.jl` used a bare `step_environment!` loop with RVO **off** (forced by `deepcopy`,
since the RVO2 sim is a Python object in module globals). That harness:

- never ran `ood_inject_step!` / `respec_step!` per step, nor the reform recovery / no-progress guard;
- ran without the motion stack, changing the dynamics;
- measured planned rather than realized makespan.

**The repo already has the correct harness**: `tools/ood_compare_fullsim.jl::run_one(producer)` —
which is precisely the `run_pipeline` seam the literature-gap survey noted was missing. It rebuilds
the env per run (so the non-deepcopyable RVO sim and module globals are never aliased), runs the
production `simulate!` loop, and reads the realized `stats[:Makespan]`.

`gen_oracle_fullsim.jl` is the oracle rebuilt on it: same `run_one`, sweeping **candidate macros**
instead of controllers, plus the no-fault control.

## 4. Candidate set must match the engine's actual repertoire

`decpomdp/examples/ood_env_mdp.jl` defines the closed action space
`0:NOOP 1:Replace 2:Deprioritize 3:ForbidZone 4:ReformTeam`, and `valid_actions` **masks a `:fault`
to `[0,1]`**. The first sweep enumerated `ForbidAgent`, which is *not in the DSL action space at
all*, and `Deprioritize`, which is masked out for faults. For ranking richness the oracle may still
sweep the unmasked "mistake" arms (2, 4) — but it must know they are mistakes, not legal choices.

## 5. Known engine pathologies the oracle will faithfully record

Reproduced independently, and documented in `src/respec/docs/distributed_replace_2026-07-09.md`:

- **Replace wedges with too few spares.** One spare cannot serve a dead robot's several transport
  tasks → cyclic `OpenBuildStep` dependency → build never completes. Fix: `replace_robot_distributed!`
  + ample provisioning (`n_spare_per_pool` ≥ faults × tasks/fault). With `n_spare=1` our sweep saw
  Replace fail (0.636 completion) — an artifact of under-provisioning, not a property of Replace.
- **ForbidAgent / MILP reassignment double-books** (documented bug #1).
- **Deprioritize in the full sim** does a full MILP re-solve that wedges the build early
  (61/313, worse than no-adapt).

These are *true outcomes of this world*, so the oracle should record them — and they are precisely
the kind of **non-obvious, rule-defying dynamics a learned surrogate must capture** (a naive rule
"broken robot → replace" mispredicts them). Good evidence for why the surrogate has something to
learn. But they must not be confounded with under-provisioning artifacts: **provision spares amply**
so a candidate's failure reflects the decision, not the setup.

## 6. `pick_solo_fault_target` returns `nothing` on tractor at closed=8

No robot has *all* transport teams of size 1 (observed team sizes `[1,1,1,2]`, `[1,2,4]`, `[2,2,2]`).
That is why `fault_action(safe=true)` **defers**, and why `ood_compare_fullsim.jl` schedules the
trigger at *several* progress points `(12, 20, 30, 45, 60)` — it fires at the first point where a
solo target exists. Do the same; do not hand-pick a target.

## 7. 🔴 Turning RVO off **inverts the correct decision** — no cheap world

The oracle costs ~1 h per candidate with the full motion stack, so we tested whether the reactive
motion stack (RVO / TangentBug / dispersion) could be disabled while keeping the production
`simulate!` loop. **It cannot.** Measured (tractor, 10 robots, `NSPARE=3`, `n_total=313`):

| candidate | RVO **on** (per `distributed_replace_2026-07-09.md`) | RVO **off** (measured) |
|---|---|---|
| healthy control | — | COMPLETE 291/313, makespan 8.9 |
| `0:NOOP` | **INCOMPLETE 245/313** | COMPLETE 291/313, makespan 19.3 |
| `1:Replace` | **COMPLETE 292/313** | **wedged** 219/313 (30 000 iters no progress) |
| ⇒ oracle best | Replace | NOOP |

The ranking **flips**. So the motion stack is **decision-relevant**: the correct macro depends on
reactive-navigation congestion (recovery spares get RVO priority to cut through a congested late
build; without RVO the distributed hand-off wedges). The oracle must run `RVO=1`.

Two consequences:
- **Cost reduction must come from elsewhere** — process-level parallelism across candidates and
  instances (each run is an independent `julia` process; embarrassingly parallel over CPU cores),
  and/or a smaller assembly model. Not from disabling physics.
- **This is a concrete instance of "invest fidelity only where it flips decisions."** Motion fidelity
  flips the decision here, so the learned surrogate must capture congestion-dependent outcomes —
  which is precisely the kind of non-obvious dynamics that makes the surrogate worth learning (a
  naive rule "broken robot → replace" is right only *because of* the motion stack).

Note: `ADMISSIBLE = true` did hold under RVO-off (NOOP 19.3 vs control 8.9 realized makespan), so the
admissibility machinery works — but an admissible instance in the *wrong world* still yields the
wrong ground truth.

## 8. 🔴 A candidate must vary the response to the STUDIED event only

First RVO=1 sweep (8 runs, seeds 1 & 2): the healthy control completed (291/313, realized makespan
15.95) but **every candidate failed to complete** — NOOP 237, Replace 255, Deprioritize 237,
ReformTeam 237 (seed 2: NOOP 233, Replace 263). The documented result is Replace **COMPLETE
292/313**.

Cause: `oracle_prod(a)` replayed the fixed action `a` at **every** OOD event. But the simulator
also auto-emits `:reform` ("team deadlocked") events (`set_reform_interval!(400)`), and for a
`:reform` context `ctx.agent === nothing`, so `action_to_proposal(ctx, 1)` returns `nothing`.
Replaying a fault-action at reform events therefore **silently disabled the endgame recovery**
(`recover_stalled_teams!` → `resolve_schedule_wedge!`) for all candidates, wedging every run.
(The `event_type:"reform"` in the records was the same bug: `SEEN[]` kept the *last* event.)

**Rule.** The candidate action varies **only at the studied event**; all background events take the
**canonical** response, identically for every candidate. That makes the studied decision the only
variable — the fairness invariant — and matches how `ood_compare_fullsim.jl`'s controllers behave
(they dispatch on `ctx.type` per event).

Silver lining: even crippled, the direction was right and reproducible across seeds
(**Replace > NOOP** by closed-node count: 255>237 and 263>233), and the instance was **admissible**
(NOOP incomplete vs control complete).

### This also cleans up the RVO evidence (§7)
§7 originally compared *our* (fixed-action) producer at RVO=0 against the *doc's* (per-event)
producer at RVO=1 — apples to oranges. With the **same** fixed-action producer on both sides:

| | RVO **off** | RVO **on** |
|---|---|---|
| `0:NOOP` | COMPLETE 291/313 | incomplete 237/313 |
| `1:Replace` | wedged 219/313 | incomplete **255**/313 |
| ordering | Replace **<** NOOP | Replace **>** NOOP |

The inversion is real and now properly controlled. Re-verify after the §8 fix.

---

## Net effect on the plan

- `EVALUATION.md`: speed axis = **realized** makespan; add the **healthy control** and the
  **instance-admissibility rule** to the four methodological must-haves.
- Oracle generator: `gen_oracle_fullsim.jl` (on `run_one`), not `gen_oracle_faults.jl` (kept only as
  a record of the bare-loop approach and its failure modes).
- Cost: one full `run_lego_demo` per candidate — the oracle is expensive **by design**. That expense
  is the very thing E1's surrogate is meant to amortize.
