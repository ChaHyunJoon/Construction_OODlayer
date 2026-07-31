# Reviewer Response Plan — 3 concerns

**Draft 2026-07-15.** Responds to three reviewer concerns:
1. Justification (당위성) for surrogate modeling + verification/validation.
2. LLM proposer hallucination (data contamination during simulation / labeling ground truth).
3. Graph trees vs GNN — reviewer says the graph model is more interpretable than a GNN.

The three are not independent. They share a single root cause — **the original OOD benchmark was
decision-easy** — so this document leads with that diagnosis and then answers each concern from it.

---

## 0. Root cause first — why the original OOD was a decision-easy situation

This is the linchpin. If we do not state it plainly, the surrogate looks unjustified (concern 1) and
the GNN looks like capacity with nothing to earn (concern 3). The honest, defensible framing is:
**we diagnosed the triviality ourselves, and fixed it.**

### 0.1 The identity that made it easy

```
best_macro = f(kind)            H(best_macro | kind) = 0 bits
  fault   -> Replace     (23/23 instances)
  zoneblk -> ForbidZone  ( 9/ 9 instances)
```

With this identity a **4-way one-hot on the OOD kind** (plus the `macro_in_valid` mask) is a
*decision-perfect* policy at **zero planner calls**. The surrogate never needed to read severity, SoC,
spare_count, or progress. That is exactly why:
- a learned surrogate could not beat the state-blind `always_per_kind` lookup (regret tie at 0.000), and
- a GNN had zero headroom — a 19-feature Ridge was already decision-perfect (`DESIGN_NEXT.md` §1).

### 0.2 Four mechanisms produced the identity (all had to be removed)

Two are label-rule artifacts, two are engine bugs (`GRADED_OOD_DESIGN.md` §1, §6b):

| # | mechanism | effect | fix |
|---|---|---|---|
| 1 | **Admissibility filter** (`instance_admissible`, `e1_analyze.py:54`) keeps an instance only if NOOP is strictly worse than the healthy control | every "restraint is correct" case deleted *by construction*; model learns it can never choose NOOP | retire the filter in `--cost-aware`; keep every fired instance, keep `admissible` as a column |
| 2 | **One dominant macro per kind** — intervention always pays (spare always available, zone always blocks a pending staging area) | no cheap/expensive trade-off ⇒ argmax constant within kind | charge adaptation cost `y = closed − λ·cost(macro)` so restraint can win ties |
| 3 | **battery injector hit a parked spare** — `argmax(SoC)` targets idle spares (`agent_pending=0`) | all 5 macros returned byte-identical sims (closed=291) ⇒ "battery is harmless" was an artifact | `_pick_battery_target` prefers a cleanly-replaceable *working* robot |
| 4 | **NOOP arm was not NOOP** — the stall raised its own breakdown alarm, which the background policy answered with a canonical Replace *inside* the NOOP arm | the restraint arm secretly intervened | cascade rule forces downstream consequential alarms to NOOP so each arm owns its consequences (`gen_oracle_dataset.jl:258`) |

### 0.3 The fix — graded OOD makes the correct macro vary WITHIN a kind

Grade each kind along a severity axis whose two ends have **different** correct macros, keyed on state
the model can read (`GRADED_OOD_DESIGN.md` §2):

- **battery** — post-drop SoC ladder: deep→**Replace** / marginal→**Deprioritize** / mild→**NOOP**.
  The flip point is not constant in SoC; it depends on `severity × agent_pending` (a learnable
  interaction).
- **fault** — severity = *reparability*: `n_spare=0`→**ReformTeam/NOOP**; idle victim (no pending
  work)→**NOOP**. `fault` is 72% of the data, so its harmless↔consequential split matters most.
- **zone** — severity = *what it covers*: pending staging circle→**ForbidZone**; closed assembly or
  transit corridor→**NOOP**. `severity = overlap_fraction_with_pending_staging`.

### 0.4 Measured evidence the fix worked (2026-07-14, 30 instances, seeds 1–3)

| statistic | easy (original E1) | graded | target |
|---|---|---|---|
| `H(best_macro \| kind)` | 0.00 bits | **0.97** | > 0.5 |
| per-kind majority accuracy | 100% | **57%** | ≤ 70% |
| NOOP is best | 0% | **50%** | 15–35% |
| `model` regret at k=0 | 0.000 | **0.181** | > 0 |
| `always_per_kind` regret | 0.000 | **0.662** | ≥ 0.20 |

Learning claim (was vacuous before, now holds with significance):

| policy | norm-regret | catastrophic |
|---|---|---|
| **model (state-reading surrogate)** | **0.181** | 2/30 |
| always (one fixed macro) | 0.447 | 4/30 |
| always_per_kind (strong state-blind opponent) | 0.662 | 8/30 |
| random | 0.663 | 6/30 |

`model` beats `always_per_kind` by **+0.481, 95% CI [+0.261, +0.683]** (paired bootstrap, n=30).
On the old dataset the same comparison was **+0.000, CI [0.000, 0.000]**.

> **One-sentence answer to the reviewer:** "Our original benchmark was decision-easy
> (`H(best|kind)=0`), which we diagnosed and fixed. On the graded benchmark the correct macro varies
> within each OOD kind, the surrogate reads state to track it, and it beats the strongest state-blind
> baseline with a significant margin. Every concern below is answered on the *graded* benchmark, not the
> easy one."

---

## Verification harness — IMPLEMENTED (2026-07-15) — `verify.py`

**Decisions locked**: (1) keep the graph-tree / tabular surrogate; **do not switch to a GNN now** (GNN
stays gated future work, Concern 3). (2) Secure *verification* of the LLM proposer and the surrogate
first. `verify.py` is that battery; it runs on `oracle/out/graded.jsonl` (30 instances) and prints a
PASS/FAIL report. Both the deployed RandomForest and the E1–E4 HistGBR pass identically.

```
python verify.py oracle/out/graded.jsonl --model=rf     # or --model=hgb
```

| id | check | result |
|---|---|---|
| **V0** | ground-truth isolation — LLM never authors a label | **PASS** — 30/30 full 5-macro enumeration; labels from `{complete,closed,makespan}` rollout; no LLM field in schema |
| **S1** | decision-equivalence: `model < always_per_kind` (fold-local baseline, paired bootstrap) | **PASS** — regret 0.236 vs 0.666, advantage **+0.430 CI [+0.178,+0.669]** (RF); +0.434 (HGB) |
| **S2** | level-0 world-model fidelity | **PASS** — held-out closed R²=0.786, MAE=10.8 nodes |
| **S3** | decision monotonicity (gap vs NOOP, aggregate slope) | **PASS** — 3/3 core: `agent_pending↑`(fault), `soc↓`/`severity↓`(battery) |
| **S4** | state-blind ablation | **PASS** — full 0.236 vs kind-only 0.514 (state buys +0.279) |
| **L1** | LLM proposal applicability | **PASS (gated)** — ungated stub is inapplicable 30/30; `valid_mask` gate fixes all 30 at **zero recall cost** |
| **L2** | LLM candidate recall (oracle-best ∈ set) | **PASS** — 30/30 = 100% (per kind: battery 16/16, fault 8/8, zoneblk 6/6) |
| **L3** | fallback safety bound | **PASS** — verify-all-5 recovers any recall miss at cost 5 |

**What verification surfaced (the point of running it):**
- **S1 was fragile until a leakage bug was fixed** — `always_per_kind` must be fitted *fold-locally*;
  fitting it on all instances leaked the held-out label and shrank the margin (CI crossed 0). After the
  fix the surrogate's advantage is significant and matches the published +0.481.
- **`severity` is not monotone in harshness across kinds** — for `battery` it *is* the post-drop SoC
  (low = deep = harsh). Any V&V or feature-attribution that treats `severity` as a single "harshness"
  scalar is wrong; tests must be kind-scoped.
- **Two honest diagnostics (not graded)**: `spare_count` is under-sampled in `fault` (only {0,12} →
  grade `DS_SPARES=0,1,3,6`); `zone_overlap`'s oracle-best is **non-monotone** (NOOP→ForbidZone→NOOP;
  full overlap can't restage) → needs a band/threshold test, not a monotone one. A *correct* surrogate
  is non-monotone here.
- **L1 is a real proposer gap with a free fix**: the static candidate set proposes macros outside the
  state-dependent `valid_mask` (battery deep valid=`(0,1)`, marginal valid=`(0,2)`). Intersecting the
  proposal with `valid_mask` removes every violation and preserves oracle-best recall 30/30 — and shrinks
  the verification set for free.

---

## Concern 1 — Justification for surrogate modeling + V&V

### 1.1 Justification is conditional, and we state the condition

The surrogate amortizes an oracle that, at each OOD decision, rolls **every** candidate macro to
completion — impossible to do in a real closed loop (latency). The surrogate replaces that with a
one-forward-pass value estimate. But amortization alone is not enough justification: **the surrogate is
justified only when it sits on a better point of the decision-regret vs planner-compute frontier than
(a) the `always_per_kind` lookup and (b) LLM→solver verify-all.** That condition holds only on the
graded benchmark (§0.4). We say so explicitly rather than claiming unconditional value.

### 1.2 V&V battery — split verification from validation

**Verification** ("built the model right" — decision/value fidelity):
- Decision-equivalence: held-out top-1 decision-regret (`e1_analyze.py:252`) — the surrogate reproduces
  the oracle's *choice*.
- Level-0 world-model diagnostic: held-out closed-count MAE / R² (`e1_analyze.py:280`) — it is really a
  value model, not just a classifier.
- **Monotonicity/sanity unit tests** (to add): severity↑ ⇒ predicted `closed`↓; `spare_count`↑ ⇒
  Replace value↑; `soc`↓ ⇒ Replace/Deprioritize value↑. Tree ensembles admit monotonic constraints —
  wire them as automatic falsification tests.
- State-blind ablation: a kind-one-hot-only model must fail; proves the surrogate uses state, not kind
  memorization. Backed by the difficulty audit `H(best|kind)` (`e1_analyze.py:124`).

**Validation** ("built the right model" — generalization/deployment):
- Current: leave-one-**instance**-out grouped CV.
- Add **leave-one-KIND-out** and **severity-held-out** splits (extrapolation to unseen OOD; aligns with
  the `severity_split` design in `OOD_ADAPTIVE_CONTROL_COMPARISON_PLAN.md`).
- Calibration: predicted vs realized `closed` (reliability curve).
- Closed-loop drift: `e3_drift.py` FROZEN vs ACTIVE — decisions stay good under distribution shift.
- Safety: report catastrophic-choice rate (picking a macro that fails to complete) separately.

### 1.3 Falsification we pre-commit to

Pre-register the null "surrogate ≤ `always_per_kind`" and try to reject it with a paired bootstrap CI.
If on some benchmark it cannot be rejected, we report that the OOD taxonomy is decision-easy there and
change the *action space*, not tune severities to manufacture a curve (`GRADED_OOD_DESIGN.md` §5
falsification clause).

---

## Concern 2 — LLM proposer hallucination

Split the worry into two distinct risks; they have different answers.

### 2.1 Grammar-level hallucination — already structurally bounded

The LLM does not emit free-text actions. It is constrained to the **closed `ConstraintSpec` DSL**
(`spec_dsl.jl:46`, 6 subtypes → 5 numeric macros) via **JSON-schema structured output**
(`llm_service/schema.py`). Semantically-inapplicable proposals are caught by the `macro_in_valid`
applicability check and rejected/NOOP'd before touching the sim; we log the rejection rate.

### 2.2 Label / data contamination — the real risk, and our strongest defense

The reviewer's "stack the data during simulation / label ground-truth cases" worry is that if the LLM's
proposed candidate set decides which macros get rolled out and labeled, a hallucinating LLM that omits
the true-best macro corrupts the ground truth. **Our design makes this structurally impossible**, and we
state it as an invariant:

> **Invariant: ground truth is defined by exhaustive enumeration over the closed DSL, never by the LLM.**

- `gen_oracle_dataset.jl` sweeps **all 5 macros** per instance, independent of any LLM proposal, and
  labels each by **simulator rollout** (physics/schedule fact) — not LLM judgment. Hallucination cannot
  reach the label.
- **Value surrogate trains only on oracle-enumeration rows.** LLM-proposed rows are used *only* for the
  E2 candidate-recall analysis, never as labels. → add an explicit **`producer` provenance column**
  (`oracle-enum` / `llm-proposed` / `surrogate-enacted`) and filter to `oracle-enum` at fit time, so
  leakage is auditable.
- **Contamination firewall already exists**: snapshot/restore of mutable globals
  (`SPARE_POOLS, FAULTED_ROBOTS, RESTRICTION_ZONES, …`) between candidate arms + the cascade-NOOP rule
  (`gen_oracle_dataset.jl:258`). One instance's proposal cannot leak state into another — this is the
  direct answer to "stacking data during simulation."

### 2.3 The one residual LLM risk we quantify honestly — candidate-set recall

In E2 the LLM narrows 5→k candidates to save verification compute (`e2_llm_surrogate.py:31`). If it
drops the true-best, regret results. We do not hide this:
- Report **oracle-in-candidate-set rate** (recall of the LLM's proposal set vs the enumerated oracle).
- When recall < 1, measure the regret cost of the miss.
- **Worst-case bound**: if the LLM set fails applicability, or disagrees with the surrogate top-1 by a
  large value margin, fall back to enumerate-all (verify-all) — bounding worst-case regret to the
  solver's. Add self-consistency (k samples, majority proposal) to suppress hallucination.

---

## Concern 3 — Graph trees vs GNN (reviewer: graph model is more interpretable)

### 3.1 Terminology (avoid talking past the reviewer)

Three distinct "tree/graph" objects live in this repo:
- **graph trees** = the ground-truth twin's structure: **SceneTree** (assembly hierarchy,
  `ConstructionBots.jl:542`) + **schedule DAG** (`env.sched`, 10 node types). ← the reviewer's "graph
  model" input.
- **decision trees** = the *deployed* surrogate today (RandomForest / HistGBR over ~13–60 scalars).
- **GNN** = a net consuming SceneTree⊕DAG end-to-end — **designed only** (`DESIGN_NEXT.md` §1), no code.

### 3.2 We agree with the reviewer *for the current task*

A GNN earns its keep only when the decision depends on graph topology that scalars cannot summarize.
On the easy task there was zero headroom (§0.1), and even on the graded task the ~13-scalar model
already reads the flips (regret 0.181, beating lookup). So a GNN would add capacity and *cost
interpretability* with nothing to buy back yet. We keep the interpretable tabular model as the deployed
default (feature importance / SHAP; monotonic constraints).

### 3.3 Recommended middle path — interpretable AND structure-aware (a 3-rung ablation)

Do not jump to end-to-end GNN. Feed **graph-derived hand-engineered features** off SceneTree/DAG into
the existing interpretable tree ensemble:
- subtree size / depth below the faulted node, # downstream `OpenBuildStep` dependencies,
  critical-path slack of the affected node, betweenness of the cut transport edge.

Present all three rungs on the decision-regret vs compute frontier and let the data pick:

| rung | model | interpretable? | when it wins |
|---|---|---|---|
| 1 | scalar-only tabular (current) | yes | current graded task (regret 0.181) |
| 2 | **+ graph-derived features** | **yes** (recommended default) | when the flip depends on *which* node/edge is hit |
| 3 | GNN (end-to-end) | no (upper-bound/ablation only) | only if rung 2 cannot close the gap |

**Rule:** deploy the *most interpretable* model that reaches oracle-equivalence; promote to GNN only if
graph features cannot close a demonstrated gap. This directly satisfies the reviewer's interpretability
preference while keeping the GNN as a governed experiment, not a default.

### 3.4 "How many trees should be designed?" — direct answer

- **Not one graph per OOD kind.** Each build problem has exactly **one** ground-truth structure:
  `(SceneTree ⊕ schedule DAG)`. The OOD kind is a one-hot *on top of* that structure, not a new graph.
- So the number of graphs to *design* = **one canonical (SceneTree ⊕ DAG) per build problem**.
  Generalization comes from varying the **build** (different LEGO models / seeds), not from
  hand-designing multiple trees per kind.
- The forest's estimator count (currently 60) is a CV-tuned hyperparameter, not a design decision — keep
  it out of this question.

---

## Unified action — one experiment suite answers all three

The three concerns collapse onto one deliverable: **run the full evaluation on the graded benchmark**,
where (a) surrogate beats `always_per_kind` on the frontier (concern 1), (b) the scalar/graph-feature/GNN
ablation decides whether structure is needed (concern 3), and (c) provenance-tagged enumeration labels
prove LLM isolation (concern 2).

### Deliverables checklist

- [x] **Verification harness** `verify.py` (V0/S1–S4/L1–L3) — 8/8 PASS on graded, both model classes.
- [x] **GT-isolation verified** (V0) — enumeration+rollout labels; LLM absent from dump (concern 2).
- [x] **Candidate-recall metric** (L2) + verify-all fallback (L3) reported (concern 2).
- [x] **Applicability gate finding + remedy** (L1) — gate proposals on `valid_mask` (concern 2).
- [x] **Monotonicity / state-use / fidelity** verified (S1–S4) with the leakage & physics fixes (concern 1).
- [ ] **Wire the `valid_mask` gate into the actual proposer** (`e2_llm_surrogate.py` / the real LLM bridge),
      not just the harness — L1's remedy in production code.
- [ ] **Rebuttal §0 narrative**: "we diagnosed decision-easy (`H=0`) and fixed it" — with the §0.4 tables.
- [ ] **Provenance column** in the dump seam + `oracle-enum`-only training filter — make the V0 invariant
      explicit in code (currently satisfied structurally because the dump has no LLM at all).
- [ ] **Validation** (distinct from the verification just done): leave-one-KIND-out / severity-held-out
      splits + calibration curve + closed-loop drift (E3) (concern 1).
- [ ] **Grade the under-sampled axes** the harness flagged: `DS_SPARES=0,1,3,6` (fault) so `spare_count`
      is testable; add a band test for the non-monotone `zone_overlap`.
- [ ] **Rebalance graded set**: NOOP-best is 50% (target 15–35%) — add consequential points, don't
      delete harmless ones (`GRADED_OOD_DESIGN.md` §6b).
- [ ] **3-rung ablation** (scalar / graph-feature / GNN) — deferred; GNN stays gated future work.

### Open decisions to confirm before finalizing

1. λ sensitivity for the cost-aware objective — report `{1, 3, 6}` (per `GRADED_OOD_DESIGN.md` §3b)
   rather than the single flattering value; the harness currently uses λ=3.
2. Real-LLM verification: when the LLM bridge is live, dump its emitted proposals per instance to a
   `{instance: [macros]}` JSONL and feed it to `verify.py` (replace the `LLM_CANDIDATES` stub) so L1/L2
   measure the *real* proposer, not the hardcoded candidate map.
3. Whether to now proceed to **validation** (generalization/drift) or first harden the proposer
   (wire the `valid_mask` gate + provenance column).
