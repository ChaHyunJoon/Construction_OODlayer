# LLM Design-Space Navigator for ConstructionBots — Implementation Plan

## Thesis (read first — this drives everything)

A multi-robot manufacturing & assembly system must be judged by — and optimized
for — **SPEED, EFFICIENCY, and ADAPTABILITY** of the *built* product, not by how
fast a plan is generated. The ConstructionBots paper (Brown, Asmar, Schwager,
Kochenderfer; *Robotics and Autonomous Systems* 194, 2025; arXiv 2311.00192)
explicitly states in its conclusion that current experiments "focus solely on
generation time" and that future work should incorporate spatial-efficiency,
execution-time, robustness, utilization, energy, and handling-distance metrics,
exposed through the modular stack's knobs (buffer sizes, team configs, collision
tolerances, objective weights). The paper's **closing sentence** states the
field's promise in exactly these terms — multi-robot assembly/manufacturing can
*"revolutionize the **speed, efficiency, and adaptability** of the production
process."* Our three optimization axes, in the authors' own words. The thesis is
thus anchored twice: (1) the trade-off conclusion paragraph and (2) the closing
sentence.

> **Therefore the objective function MUST change.** Generation-time-only is
> replaced by a multi-axis objective over {completion, speed, efficiency,
> adaptability}. This is non-negotiable for the contribution to hold.

The **LLM's role** = the *navigator* of the knob→metric design space: it maps a
natural-language intent (offline) **or** a runtime OOD observation (online) to a
concrete knob configuration, runs the classical solver, reads the resulting
metric vector, and iterates across the competing objectives. The existing
OOD-respec work (ForbidZone / ReplaceAgent DSL) is the **online special case** of
this single loop.

This is, verbatim, the original authors' stated future work — implemented with an
LLM. Positioning win: "we implement the future work the original authors proposed."

```
[NL intent / OOD observation]
        │  LLM translate
        ▼
   knob config (JSON/DSL)
        │  verifier (solver feasibility — NOT an LLM)
        ▼
  ConstructionBots run (classical optimal plan)
        │
        ▼
   metric vector {speed, efficiency, adaptability, completion}
        │  LLM evaluate vs intent
        └──────────── refine config ◄─────────────┐
                          (Pareto navigation)      │
```

---

## The 7-step plan

| # | Step | Why it is ordered here |
|---|------|------------------------|
| 1 | **Metric instrumentation** — `run_config(cfg) -> RunMetrics` returning the multi-axis vector (makespan, throughput, utilization, energy, handling distance, completion rate, replan latency, schedule deviation). | The paper measures only generation time. Without a metric vector there is **no objective to navigate** — so this is first. (`src/navigator/metrics.jl`) |
| 2 | **Knob config schema** — `NavigatorConfig` capturing buffer, collision tol, team cap, slack, spare capacity, redundant paths, and `ObjectiveWeights`, with Dict/JSON (de)serialization so the LLM can emit/partially-edit it. | The thing the LLM writes. (`src/navigator/config_schema.jl`) |
| 3 | **Single-shot translate** — LLM: NL intent → one `NavigatorConfig`; run through a solver-feasibility verifier before execution. | Simplest closed path (ProgPrompt / LLM+P pattern). |
| 4 | **Propose→evaluate→refine loop** — run config, read metrics, LLM re-proposes ("makespan good, utilization low → cut team, grow buffer"). | OPRO-style LLM-as-optimizer over the metric feedback. |
| 5 | **Multi-candidate Pareto** — LLM proposes N spread configs (safety-biased / speed-biased / balanced) → build Pareto front → LLM explains trade-offs in NL and recommends. | Directly realizes the paper's "generate multiple candidate designs and evaluate across metrics." |
| 6 | **DSL unification** — extend the DSL beyond ForbidZone/ReplaceAgent with knob-edits (`SetBuffer`, `SetWeight`, `AddSlack`, `ReserveSpare`, `SetCollisionTol`); one DSL serves offline (Mode A) and online OOD (Mode B). | Note: the `extra_constraints` hook is **add-constraint-only**, so `SetWeight`-type edits route through the *build/cost_model* path, not the hook. |
| 7 | **Evaluation** — sweep OOD severity × methods (LLM-navigator vs classical exact re-solve vs greedy/heuristic) × the multi-axis metrics; Pareto plot of quality vs replan cost. | The thesis is only proven if the new objective is measured against baselines. |

---

## Objective change — the concrete spec

Replaces `SumOfMakeSpans` (generation-time-only framing) with a four-axis
objective. Default mode = **completion-first lexicographic** (preemptive):

```
① completion     min  U = Σ_d ρ_d (1 − z_d)        # feasibility-first (no human repair)
② speed          min  C_max  (makespan) ; throughput = parts / C_max
③ efficiency     min  energy + handling_distance + (1 − utilization)
④ adaptability   min  schedule_deviation + replan_latency
```

- **Lexicographic** (recommended): solve ①, fix `U ≤ U*`, solve ②, fix, ③, fix, ④.
  Each "fix" is one added inequality — matches the existing add-constraint-only
  `extra_constraints` hook. No weight tuning, interpretable.
- **Weighted** (alternative, fragile): `J = Σ w_axis · cost_axis` with
  `w_completion ≫ w_speed ≫ w_efficiency ≫ w_adaptability`. Discouraged — the
  model already carries Big-M `Mm=10000`; adding huge weights blows up the
  condition number.

The four axes are exactly the knobs the paper names: objective weights = the axis
priorities; spare capacity / slack feed adaptability; buffer / collision tol feed
safety-vs-speed; team config feeds efficiency.

---

## Where the LLM is warranted (honest boundary)

- **Strong**: OOD that is *not cheaply pre-formalizable* — arrives as a
  natural-language-level observation that must first be translated into a repaired
  spec/instance before any solver can run. There is no instance to re-solve until
  the spec is repaired.
- **Weak**: OOD that is *already fully formalizable* (known robot ID drops, a
  geometric keep-out box). Here a classical exact re-solve dominates the LLM.
  → Experiments must use genuinely non-pre-formalized OOD, or the baseline wins.

## Scope boundary — two distinct future-work threads

The paper's conclusion names two *separable* future-work threads. Only the first
is ours; conflating them would over-claim.

1. **Planning-layer multi-objective + adaptability — OURS.** "Trade-offs between
   competing objectives," metrics beyond generation time, knob→metric navigation,
   adaptability to unseen events. The LLM navigator lives here, and the authors'
   admission that the system has *"no theoretical guarantees ... vulnerable to edge
   cases that do not appear in our demo projects"* is precisely the OOD-robustness
   opening for it.

2. **Execution-layer certifiable deadlock-freedom — NOT ours; keep classical.**
   "Continuous space-distributed execution strategies that are certifiably free
   from deadlocks," via dynamic prioritization (controller layers 2–3:
   TangentBug → PotentialField → RVO), sophisticated potential fields
   (decentralized caging/pushing), or virtual highways (AGV research). This is a
   formal control-theoretic *guarantee*. **The LLM does NOT belong here** —
   deep-research confirmed there is no certifiable pre-deployment safety method for
   foundation-model robotic systems. Claiming the LLM adds deadlock-freedom would
   be false.

**Boundary rule:** scope the LLM claim to *adaptability / graceful spec-repair
under unseen events* (thread 1), never to deadlock-freedom (thread 2). The
navigator's verifier checks instance feasibility / constraint satisfaction; it must
not pretend to certify continuous-execution safety — that stays the execution
layer's classical job. Threads 1 and 2 are complementary layers, not competitors.

## Closest prior art (cite + differentiate)

- **NL → formal spec → repair → re-plan**: arXiv 2603.27583 (UAV STL translation
  AND repair), VernaCopter (STL), LLM+P (NL→PDDL→classical planner). The loop
  itself is **not novel**.
- **LLM-as-optimizer / configurator**: OPRO ("LLMs as Optimizers"), LLAMBO
  (LLM-proposed Bayesian-opt candidates).
- **Novelty = the intersection**: (a) multi-robot **assembly** design space,
  (b) offline design + runtime OOD unified in one DSL loop, (c) completion-first
  multi-objective under space-irreversibility, (d) first implementation of the
  ConstructionBots authors' stated future work. Drop any one and it collapses into
  the prior art above.

## Evaluating whether the LLM did well (not the solver)

`RunMetrics` measures the *plan* the solver produced — it conflates LLM quality
with solver quality. To score the LLM, isolate its contribution
(`src/navigator/llm_eval.jl`):

- **Level 0 — reference frame**: oracle (true-OOD optimal re-solve, upper bound),
  no-adapt (floor), classical-respec (the real competitor). Outcomes are reported
  *relative* to these, never raw.
- **Level 1 — grounding/translation accuracy** (the LLM's real job): precision /
  recall / F1 of emitted DSL vs ground-truth OOD; hallucination = false positives.
  Requires the synthetic OOD generator to emit ground-truth labels alongside the NL
  observation. (`grounding_prf`)
- **Level 2 — outcome, normalized**: `optimality_gap` to oracle + `lift` over
  baseline, per lexicographic axis. (LLM ~never beats oracle on outcome — expected.)
- **Level 3 — cost + reliability**: replan latency, repair iterations, success RATE
  + gap variance across N seeds (single run is meaningless — LLM is stochastic),
  and **false-accept rate** (verifier escapes — weighted heavily; a no-human-repair
  setting makes a false-accept far worse than a false-reject). (`is_success`,
  `reliability`)
- **Headline experiment — lift vs OOD-formalizability**: sweep OOD from
  fully-formalizable → NL-only. Classical-respec matches the LLM (lift≈0) when
  formalizable and fails when NL-only; the region where lift>0 is the LLM's
  justified zone. This one curve answers "did the LLM do well AND was it needed."

## Status / next

- [x] **Objective redefined in the real MILP** — `essential_tg_coponents.jl`: `PLANNING_OBJECTIVE_WEIGHTS` Ref + `set_planning_objective_weights!(; speed, efficiency, adaptability)`; `get_objective_expr(SumOfMakeSpans)` adds an EFFICIENCY = flow-time (Σ all tF) term. Default (efficiency=0) = original makespan objective byte-for-byte. Adaptability = replan-time deviation term (not in the initial-plan objective). Ran end-to-end (colored_8x8, `:milp`, HiGHS): objective is live (solver optimizes `speed + w·flowtime`, valid plan), and the plan changes (makespan 31.8 → 54.3 at eff=0.05).
  - **Efficiency term redefined: flow-time → ENERGY / handling distance** (`Σ d·Xa` over chosen assignment edges). Flow-time was just another time term (collapsed into speed); distance/energy is ORTHOGONAL to makespan (parallelism cuts time without distance; smarter assignment cuts distance without time). Ran: distance term IMPROVED MILP convergence (gap 86.6%→31.6%, dual bound 3.1→68.9) — a linear cost over Xa gives the LP relaxation a tighter objective, unlike flow-time which made it harder.
  - **Lightweight ENERGY model + battery hook** — `ENERGY_MODEL` Ref + `set_energy_model!(; pickup_overhead, idle_power, load_power)` + `edge_energy(dt_min; payload_mass=1.0)`. `edge_costs[(v,v2)] = edge_energy(dt_min)`. Default (overhead=0,idle=1,load=0) = pure distance (preserved). This energy = the SoC-depletion quantity a future per-robot battery budget draws down. Smoke-tested.
  - ⚠️ To CLAIM an efficiency gain (distance↓ at makespan≈same): both instances still hit the 120s limit (non-converged → makespan numbers are noisy feasible points), and energy is not in `stats`. Next: instrument `stats[:HandlingEnergy] = Σ edge_costs·value(Xa)` + solve to optimality (smaller instance / longer limit).

### Battery extension (lightweight, from analysis)
SoC (within-episode energy budget), NOT SoH (cross-episode degradation — ~0 within one build). "Identical batteries" but DIFFERENTIAL usage → divergent health → wear-leveling objective. Needs: per-robot state (SoC/SoH/throughput), energy-per-task (= `edge_energy` with payload), per-robot energy ACCOUNTING (group Xa by physical robot — missing in current MILP), linear degradation law. Payoff is mostly a NEW gradual/anticipatory OOD for the LLM (battery health drop → respec) + grounds the adaptability axis. Keep lightweight (don't become a battery-physics paper). `edge_cost → energy` is step 1 (done).

#### Energy-aware ADAPTIVE replanning — IMPLEMENTED (2026-06-30)
Per-robot SoC accounting + battery-aware re-planning that fires at EVERY OOD, all NON-INVASIVE
(defaults reproduce prior behavior byte-for-byte; verified by full-module precompile + a 31/31
offline unit smoke `tools/test_battery_smoke.jl`).

- **VERIFIED facts** (against current code): `env.dt = 1/40 s` (full_demo.jl:272) and schedule
  durations are seconds (task_assignment.jl:25) → energy in Joules is consistent; robot max speed
  `=4.0 m/s` (rvo_interface.jl:119) → `v_ref=4.0`; `robot_team` keys are `BotID/RobotID`
  (hierarchical_geom_essentials.jl:757). **Consequence:** with REAL spec numbers gradual depletion
  is negligible per build (idle drain/step ≈ 3e-7), so SoC is used as a REPLAN-TIME BIAS and the
  battery OOD is a SUDDEN health/SoC drop — not gradual drain.
- **Per-robot SoC accounting** — `src/navigator/battery.jl`: `BatteryParams` (Optimus spec, SI),
  `BatteryFleet` (per-RobotID soc/energy/active_steps/depleted), `account_battery_step!` debits
  each robot every step from REALIZED motion (mode-classified power: idle/transit/carry/manip,
  payload-linear, `k_move`=CoT·g calibrated to the 100/500/1000 W anchors). Installed via an inert
  Ref hook `route_planning.BATTERY_STEP_HOOK` (default `nothing` → step_environment! unchanged).
- **SoC-aware objective (per-robot grouping, done at edge level)** — every re-solve runs
  `formulate_milp(SparseAdjacencyMILP)` → `edge_costs[(v,v2)] = edge_energy(dt_min)·edge_cost_multiplier(sched,v)`.
  New `EDGE_COST_MULTIPLIER` Ref (essential_tg_coponents.jl, default `nothing`→1.0) is pointed at
  `battery_edge_multiplier` by `install_battery_objective_hook!`: an assignment edge owned by a
  low-SoC robot is scaled up (`1+gain·deficit`, hard `1e3` when depleted), so EVERY OOD replan
  routes work toward healthier robots. **No replan.jl change needed** — replan rebuilds the
  objective and reads the global Refs.
- **Battery-health OOD** — `inject_battery_fault!` drops a robot's SoC and enqueues an NL event
  (`push_ood!`). ⚠️ Live demo finding: the LLM currently CANNOT translate "battery degraded" to a
  DSL constraint → `:fallback` (no re-route). So `rebalance_for_battery!(env)` re-solves the
  REMAINING schedule with the SoC-biased objective in force (NO LLM, NO new DSL kind — the
  `EDGE_COST_MULTIPLIER` re-prices edges), re-routing work off the degraded robot. The demo calls
  it whenever a battery OOD fires. (A proper LLM path needs a `DeprioritizeAgent`/budget DSL kind.)
- **Multi-time random OOD** — `src/navigator/ood_stream.jl`: `schedule_random_ood!(; n, kinds=
  [:fault,:battery,:zone], closed_lo, closed_hi, seed)` registers N one-shot triggers at random
  build-progress points; the LLM (or offline canonical reassign) replans at each. Fixes the prior
  one-shot-only injection.
- **Smaller forbid zones** — `random_restriction_zone!` `max_radius` 3→2·rr, auto-size 0.25→0.18
  (on-path) / 0.2→0.15 (centroid), floor 1.5→1.2·rr.
- **Metric wiring** — `RunMetrics` gains `min_soc` + `soc_spread`; `axis_costs` efficiency now adds
  `soc_spread` (wear-leveling); `battery_metrics_kwargs(fleet)` splats `(energy,min_soc,soc_spread)`
  into `metrics_from_schedule`.
- **One-call enable** — `enable_battery!(env)` (fleet + both hooks). **Demo**:
  `tools/demo_energy_adaptive.jl` (LLM mode when the Python service is up; offline canonical-reassign
  fallback otherwise).

#### Safety model + LLM battery path + A/B proof — IMPLEMENTED (2026-06-30, round 2)
The "LLM systems live or die by how safe + verifiable they are" pass. Three things, each
offline-verified (`tools/test_battery_safety.jl` 27/27, `tools/test_deprioritize_integration.jl`).

- **Two-tier safety model (the new spec_dsl.jl design invariant).** Every `ConstraintSpec` is
  now classed as **Tier 1 — HARD constraint** (ForbidWindow/Agent/Zone/Replace/Reform: can only
  SHRINK the feasible set → gated by the FEASIBILITY verifier; reject ⇒ safe line-stop) or
  **Tier 2 — SOFT objective bias** (DeprioritizeAgent: PRESERVES the feasible set exactly →
  *feasibility-preserving by construction* → can NEVER stall the build or break a feasibility-
  expressed safety property; it only re-orders preference among already-safe plans). This is the
  safest re-spec class and the right shape for a battery/degradation OOD.
- **DeprioritizeAgent (TIER-2 DSL kind) — the LLM battery path.** `agent + factor`. Enacted by
  `deprioritize_agent!(id, factor)` → `AGENT_COST_BIAS` registry; `edge_cost_multiplier(sched,v)`
  now composes `agent_bias(owner) × battery_fn`. SAFETY: `factor` is CLAMPED to `[1, MAX_AGENT_COST_BIAS=1e3]`
  (can't go <1 = can't incentivize a robot; can't blow up). Gate `verify_deprioritize` does NO
  feasibility solve (unnecessary — feasibility preserved) — only grounding (agent exists, not
  closed). Dispatched in `maybe_respecify!` via `_is_deprioritize` (pure-soft proposals) → register
  bias → re-solve → commit. Compiles to a no-op constraint (`compile_constraint!`=0) so a mixed
  proposal is harmless. Full stack: `spec_dsl.jl` + `compiler.jl` + `verifier.jl` + `replan.jl` +
  `llm_bridge.jl` (`_parse_proposal` branch) + Python `schema.py`/`propose.py` (low-battery → this
  kind, NOT ForbidAgent/ReplaceAgent). **Live-LLM translation VERIFIED** (`tools/verify_battery_translation.py`,
  claude-opus-4-8): 3/3 battery paraphrases → `DeprioritizeAgent` grounded to the right robot
  (factor 5–50, in the safe clamp band); a contrast HARD breakdown → `ReplaceAgent` (NOT softened)
  — the model correctly separates DEGRADED (soft) from DEAD (hard). (The OLD schema returns
  `ForbidAgent` for a battery event and the model's own rationale admits it "cannot express a
  partial/weighting" — the exact gap this kind closes.)
- **Energy A/B + handling-energy instrumentation.** `formulate_milp` stashes `LAST_EDGE_COSTS`;
  `handling_energy(milp)=Σ edge_energy·Xa` scores the chosen assignment. `tools/ab_energy_objective.jl`
  builds one instance, RELEASES future assignment edges, and re-solves at a weight sweep — same
  per-edge energy, only the chosen Xa differs → apples-to-apples (+ a deterministic greedy baseline).
  **Findings (tractor, HiGHS):** the makespan MILP does NOT reach optimality in budget (gaps
  0.45–0.86 — known hardness), so the textbook "makespan identical, energy lower" is not provable
  here. What IS robust: (1) the energy term consistently LOWERS handling energy (−34% to −63% vs
  w=0 / greedy); (2) it REGULARIZES the MILP — w>0 always finds a better feasible point than the
  degenerate w=0 (gap ~0.86, makespan 45–55); (3) in the 10-robot sweep, makespan stays ≈15 (±5%)
  across w∈[0.001,0.05] while energy ranges 27.6–34.2, with **w≈0.01 minimizing BOTH** → safe
  operating band ≈ 0.01. **DeprioritizeAgent integration (`tools/test_deprioritize_integration.jl`,
  6/6 on a real env):** the gate admits a real robot / rejects a fake; after a clamped factor-1000
  bias the robot's chosen assignment edges drop 4.0 → 0.0 (fully avoided) with **feasibility
  PRESERVED** (the soft spec cannot stall) — makespan is the controllable trade-off.
- Remaining: true minimax wear-leveling still needs the explicit robot×task grouping (the edge bias
  approximates it); battery-OOD grounding truth label for the eval harness; a smaller instance (or
  warm-started / time-boxed exact solve) for a converged makespan≈same A/B.
- [x] Step 1 metric design — `src/navigator/metrics.jl` (minimal, pure)
- [x] Step 2 config schema — `src/navigator/config_schema.jl` (minimal, pure)
- [x] LLM-eval layer — `src/navigator/llm_eval.jl` (grounding PRF, oracle gap, baseline lift, success rate, verifier-escape); smoke-tested
- [x] Ground-truth OOD labels — `src/navigator/ood_truth.jl` (FaultTruth/ZoneTruth, evaluator-only truth log, `grounding_against_truth`); non-invasive wrappers `fault_action`/`zone_action` around the existing generators; smoke-tested standalone
- [ ] **Call-site opt-in**: in the demo, schedule OOD via `schedule_ood!(step, fault_action(target=rid))` / `zone_action(key=:z1)` instead of a bare `env -> fault_robot!(...)` closure, so the truth is recorded. (Bare closures still work, just record no truth.)
- [x] Baselines B0–B2 — `src/navigator/baselines.jl`: B0 `no_adapt_respec` (floor), B1 `canonical_respec` (rule map from structured truth = oracle detector; also the grounding ground-truth), B2 `parse_observation`/`b2_respec` (deliberately brittle fixed-template regex parser). Smoke-tested incl. B2 failing on 4/4 NL/novel phrasings.
- [x] B3 oracle producer — `oracle_respec` (`ForbidAgent` MILP-reassign enactment); oracle outcome = better of {B1,B3} (`baselines.jl`)
- [x] Eval harness — `src/navigator/compare.jl` (`compare_baselines`/`print_comparison`): B0–B3 + LLM through one injected `run_pipeline`, tabulating feasibility, completion, makespan, grounding F1, gap-to-oracle, lift-over-B2, success. Smoke-tested across two scenarios (template NL: B2 copes, lift=0; novel NL: B2 fails, LLM lift>0 — the headline).
- [ ] Wire `run_pipeline` to the REAL downstream (verify → `maybe_respecify!` → solve → `metrics_from_schedule`)
- [ ] Wire metrics adapter to a real solved schedule (verify `get_t0`/busy-time/distance accessors)
- [ ] Step 3 LLM single-shot translate + solver verifier
- [ ] Steps 4–7

### Wiring note — how the truth channel attaches (the WHO/WHEN, in code)

A human authors the canonical label RULE **once** by choosing the wrapper:
`fault_action` → `FaultTruth` → canonical `ReplaceAgent`; `zone_action` →
`ZoneTruth` → canonical `ForbidZone`. At injection the wrapper fills the per-instance
values automatically (which robot, which zone) and calls `record_ood_truth!` — the
evaluator-only channel. The LLM still only sees the NL via `push_ood!`. Grounding is
then `grounding_against_truth(proposal.constraints, ground_truth_labels())`. Entity
grounding is strategy-invariant (ForbidAgent and ReplaceAgent both ground the right
robot); zones match on registered key identity (no IoU needed — the DSL names a key,
not new geometry).
