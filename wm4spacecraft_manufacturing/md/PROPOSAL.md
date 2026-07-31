# A Learned Surrogate World Model for OOD-Adaptive Multi-Robot Spacecraft Assembly

**One-page research proposal** · 2026-07-09 · project root: `wm4spacecraft_manufacturing/`

## Problem
Multi-robot assembly planners (TAMP + MILP scheduling + reactive navigation) are the "expensive known world": correct but too slow to query repeatedly when an out-of-distribution (OOD) disruption — robot breakdown, battery depletion, a new no-go zone — demands a re-plan. Real spacecraft manufacturing does not plan from scarce real data either; it plans over expensive **digital twins**. So the deployable pattern is *not* sim-to-real perception but **MuZero-style amortization of a known expensive world**: learn a fast surrogate of the twin, decide in imagination, verify sparingly.

## Novelty gap (verified 2026-07-09, 105-agent survey, 25/25 claims confirmed)
Every ingredient exists separately; the combination does not, and none in spacecraft.
| Ingredient | Closest prior | Where it stops |
|---|---|---|
| Learned surrogate amortizing an expensive twin | ST-GNN/CVAE mfg surrogates; MoSim (2504.07095) | amortizes FEA/throughput/physics, **never a TAMP/scheduling planner**; single-body only |
| LLM re-specification over a scheduler | arXiv 2506.18178, 2505.22804 | calls **exact** CP-SAT/IP, **no learned surrogate, no retraining**, not aerospace |
| Aerospace assembly surrogate + multi-agent RL | S0278612525002201 (2025) | DRL not LLM; component-agents not mobile fleet; no re-spec, no retraining |
| Spacecraft assembly digital twin | In-Orbit Factory (2401.17799) | twin used for **monitoring only**, no planner/surrogate/LLM |

**Contribution = the integration, not any single ingredient:** the first framework that (1) amortizes a full multi-robot TAMP/scheduling planner with a learned surrogate world model, (2) drives it with an LLM OOD **re-specification** layer instead of an exact solver, (3) **retrains the surrogate closed-loop** as the OOD distribution drifts, (4) instantiated on **spacecraft assembly**.

## Approach
ConstructionBots.jl is the deterministic ground-truth twin (scene tree + schedule DAG + MILP + RVO2 + DSL macros). A GNN surrogate maps `(state, ood_event, candidate DSL macro) → RunMetrics` (makespan, completion, min-SoC, feasibility). An LLM proposes candidate macros; the surrogate ranks them in imagination; only top-k are verified against the real planner. A residual monitor triggers active-learning retraining under drift. Offline data-dump seam (Julia → Parquet → PyG) keeps learning decoupled from the sim (avoids juliacall coupling).

## Experimental program (each E is a paper unit **and** an ablation cell of E4)
| Exp | Fills gap | Core claim | Key baseline (= prior regime) | Success |
|---|---|---|---|---|
| **E1** planner-amortization surrogate | 1 | surrogate predicts re-plan outcome at «1% planner compute | true planner (oracle) / heuristic / no-model | low top-1 macro regret @ «1% compute |
| **E2** LLM-over-surrogate | 2 | LLM+surrogate matches LLM+solver quality at ≪planner calls, explores more candidates | LLM→exact solver (2506.18178) | equal quality, ≪calls/latency |
| **E3** closed-loop retraining | 3 | active-triggered retrain holds quality under drift at ≪full-retrain cost | frozen surrogate / always-oracle / full-retrain | near-oracle quality, frozen degrades |
| **E4** integration + spacecraft | 4 | full system dominates on adaptability+compute; recipe transfers to a satellite-bus twin | ablation grid {surrogate×LLM×retrain} | full cell dominates at equal completion |

**Metrics:** decision quality (4-axis: completion/speed/efficiency/adaptability) + **compute saved** (planner/MILP calls avoided). **Held-out:** severity_split fairness protocol.

## Resources & sequencing
Data generation is **CPU-bound** (parallel planner rollouts + Gurobi); surrogate training needs a **single GPU** — no cluster. Dependency: E1 is foundational → **E1 → E2 → E3 → E4**. First de-risk milestone: dump a few-thousand `(state, ood, macro, metrics)` grid, train a feature-MLP baseline, confirm the surrogate ranks macros in correlation with truth before investing in the GNN.

## Honest scope boundary
The spacecraft twin here is a **representative proxy**, not validated against flight hardware (real spacecraft data is unavailable — that is the premise). The deliverable that transfers is the **method + DSL + OOD taxonomy + retraining procedure**, re-fittable onto a facility's own high-fidelity twin — not the trained weights. Novelty window is narrow (closest works 2024–2026): **re-run the survey before submission**.

## Reuse from existing assets
`ood_stream.jl`, `navigator/metrics.jl`, `respec/{spec_dsl,compiler,verifier}.jl`, `respec/llm_service/propose.py`, decpomdp MAPPO (as an RL producer arm vs the LLM). See memory: `constructionbots-wm-novelty-gap`, `constructionbots-wm-experiment-plan`, `ood-control-comparison-plan`.
