# Evaluation Design

**Companion to `PROPOSAL.md`** · 2026-07-09 · how we prove E1–E4 succeeded.

## Two principles (everything derives from these)
1. **Measure the decision, not the prediction.** A surrogate with low makespan MAE is *not* evidence of success — if its values are all wrong but the candidate-macro *ranking* is right, the decision is identical (value-equivalence, à la MuZero). The headline metric must be decision-level.
2. **Quality and compute are always measured jointly.** Quality alone makes "just run the true world" win. The **quality–compute frontier** is the deliverable.

## Metric ladder

### Level 0 — surrogate intrinsic accuracy (diagnostic only, NOT headline)
makespan MAE/MAPE, min-SoC MAE, completion/feasibility AUC & Brier, and **calibration (ECE)**. ECE matters for real: the "verify only top-k" gate and E3 active-learning trust the surrogate's uncertainty.

### Level 1 — decision-fidelity (CORE)

> **Terminology, revised 2026-08-06.** What this repo has always called *regret* is
> **normalized suboptimality** (`subopt_norm` in `verify.py`) — the per-instance loss divided by that
> instance's best→worst span. It is now **demoted to a diagnostic**, for three reasons: it carries no
> unit, its denominator differs per instance, and it is contaminated by λ (pitfall 21 already forbade
> comparing it across λ). *regret* in the literature usually means bandit **cumulative** regret; the
> one-shot quantity here is a **simple regret / suboptimality gap**. See `README.md` §4.

The headline is now reported in **simulator units**, split along the lexicographic cost model:

| Metric (`verify.py`) | Definition | Unit | Role |
|---|---|---|---|
| **`optimal_action_rate`** | `P(a = a*)`, **ties excluded from the denominator** (pitfall 17) | % | **HEADLINE** |
| **`excess_cost.d_feasibility`** | picked a non-completing arm when a completing one existed | count · % | **HEADLINE** (= catastrophic choice) |
| **`excess_cost.d_closed`** | nodes lost vs the oracle-best | nodes | **HEADLINE** |
| **`excess_cost.d_makespan`** | seconds lost (only meaningful when both complete) | s | **HEADLINE** |
| **`excess_cost.d_cost`** | intervention cost spent above the oracle-best (≈ resource burned) | — | **HEADLINE** |
| `subopt_norm` (old `regret`) | `(V* − V^π)/(V* − V_worst)` | 0–1 | diagnostic / paired tests only |
| **Ranking fidelity** | Kendall τ / **NDCG@k** between surrogate and true ranking of candidates | — | only top-k get verified → top-of-list order matters |
| **Top-k recall** | `P(oracle-best ∈ surrogate top-k)` | — | directly justifies the "verify top-k" design |

**Report all four `excess_cost` axes, always.** Measured 2026-08-06 on the canonical 60 instances:
`always-NOOP` and `always-Replace` score an indistinguishable `subopt_norm` (0.490 vs 0.500) while
failing in completely different ways — NOOP misses completion 40% of the time and loses 97 nodes;
Replace never misses completion, loses 0.3 s, and burns spares. **One axis hides the mechanism.**

**Verdict sentence template** (what goes in a paper/deck):
> "Over N events: **optimal-action rate XX%**, **Y.Y nodes / Z.Z s lost when wrong**,
> **W completion misses (W.W%)**, **+C.CC intervention cost above oracle**."

### Level 2 — quality–compute frontier (HEADLINE)
2D curve: **decision quality (normalized suboptimality or final 4-axis cost) vs compute (# true planner / MILP calls)**, sweeping k (verify budget), N (candidate count), retrain cadence.
- **Headline number = iso-quality compute reduction:** "oracle-level decisions (subopt_norm ≤ ε) at X% of planner calls."
- **Amortization ratio** = oracle calls / surrogate calls at matched quality. Report honestly **including data-gen + training cost** → the **break-even query count** (how many queries until the surrogate pays back its training).

### Level 3 — does it BEAT the oracle? (upside)
At matched compute: `quality(LLM+surrogate, N_large) − quality(LLM+oracle, N_small)`. Positive ⇒ cheap scoring lets the LLM explore more candidates and exceed the oracle.

### Level 4 — robustness under OOD drift (E3)
- **subopt_norm time-series** over the non-stationary OOD stream.
- **area between** frozen-degradation and retrained-recovery curves.
- **time-to-recover** after a drift point (adaptability axis).
- **retraining efficiency**: quality maintained per planner-call spent retraining (active-learning should dominate periodic/full).
- **held-out severity (severity_split) subopt_norm** — generalization, not memorization.

## Experiment → primary metric
| Exp | Primary metric | Success threshold (example) |
|---|---|---|
| E1 | Top-1 decision suboptimality & NDCG@k vs compute | subopt_norm ≤ ε @ «1% planner calls |
| E2 | quality @ iso-compute (frontier) | match-or-beat LLM+solver at ≪ calls |
| E3 | area between drift subopt_norm curves + time-to-recover | active-retrain ≫ frozen, near-oracle |
| E4 | ablation grid: 4-axis cost + compute | full cell dominates at equal completion |

## Six methodological must-haves (what makes it rigorous)
1. **Oracle eval set** — for held-out OOD events, brute-force the *true* outcome of *every* candidate macro to get ground-truth ranking & best (expensive, but only at eval time).
2. **Realized, not planned, makespan** ⚠️ — the speed axis MUST be the realized execution time (`stats[:Makespan] = time_steps * dt`). The scheduled `makespan(sched)` is invariant under a no-op re-plan and is blind to the disruption's cost (measured: healthy 419 steps vs faulted no-op 887 steps, *identical* planned makespan). See `ORACLE_FINDINGS.md` §1.
3. **Healthy control + instance-admissibility rule** ⚠️ — every OOD instance must be run once with **no fault** (the control). An instance enters the eval set **only if `no-op` is strictly worse than the control** (completion, closed-nodes, or realized makespan). If `no-op == control` the fault was harmless and the instance teaches nothing about adaptation. Corollary: `project_complete` is a weak predicate (healthy closes 283/297), so `completion_rate` is meaningful only *relative to the control*.
4. **Feasibility-lexicographic scoring** — completion/feasibility FIRST, then realized makespan/energy (a good-makespan-but-non-completing macro, cf. the Replace completion limit, must be penalized). Also report **catastrophic-choice rate** = fraction of decisions where the surrogate picks an infeasible/non-completing macro the oracle would have avoided (a single catastrophic pick can outweigh average subopt_norm).
5. **Per-scenario normalization before aggregation** — normalize subopt_norm against the oracle-best→worst-macro span per scenario so large models don't dominate the mean.
6. **Statistical rigor** — many seeds × assembly models × OOD events; surrogate- and oracle-pipelines are **paired** on the same OOD event → paired bootstrap / Wilcoxon for CIs. Randomness source is OOD sampling + candidate generation → need many distinct scenarios.

**Setup hygiene (else the ground truth is an artifact):** provision spares amply (`n_spare_per_pool` ≥ faults × tasks/fault) so a candidate's failure reflects the *decision*, not under-provisioning; use the production sim loop (`run_lego_demo`, full motion stack), not a bare step loop; and let `fault_action(safe=true)` pick the target at whichever progress point admits one. See `ORACLE_FINDINGS.md`.

## Metrics that mislead if used alone (avoid)
- makespan MAE alone (may be decision-irrelevant, Level-0 trap)
- quality without compute (oracle always wins)
- mean subopt_norm only (hides catastrophic / non-completion choices → always report catastrophic-choice rate)
- in-distribution subopt_norm only (no drift/held-out ⇒ no E3 claim)

**One line:** the headline is a single 2D frontier — **decision suboptimality (feasibility-lexicographic) as a function of true-planner compute** — and everything else (ranking fidelity, top-k recall, time-to-recover, catastrophic-choice, calibration) dissects and justifies that frontier.
