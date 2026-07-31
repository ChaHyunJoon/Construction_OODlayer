# Proving the surrogate is necessary — consolidated comparison-group & metric design

**2026-07-15.** Consolidates `EVALUATION.md` (metric ladder), `PROPOSAL.md` (E1–E4 = prior-art
regimes), `E4_RESULTS.md` (ablation grid), `ORACLE_FINDINGS.md` (validity corrections),
`GRADED_OOD_DESIGN.md` (decision-hard task), and `verify.py` (verification battery) into **one
question**: *what evaluation proves the surrogate is needed at all?*

The value of the surrogate is not one claim but **three**, and each is only proven by killing a
specific "you don't need the surrogate" objection with a **dedicated comparison group and metric**.
Organizing the evaluation around the objections (not around the metrics) is the point of this doc.

---

## 0. The three claims and the objection each must kill

| # | Claim the surrogate makes | Objection it must kill | Comparison group that kills it | Headline metric |
|---|---|---|---|---|
| **C1 Necessity** | you must *read state*, not just look up the OOD kind | "a 4-line lookup table (kind→macro) is as good" | **zero-call decision rules**: always-X, **always_per_kind**, heuristic, random | top-1 regret **at k=0** (0 planner calls) |
| **C2 Amortization** | near-oracle decisions at a fraction of planner compute | "just run the real planner on every candidate" | **verify-budget policies**: oracle verify-all (A), LLM→solver (B), LLM→surrogate top-k (C/D) | **quality–compute frontier** (regret vs planner calls) |
| **C3 Robustness** | the cheap surrogate stays safe as the OOD distribution drifts | "a static surrogate is fine / retraining is overkill" | **frozen (C) vs active-retrain (D) vs always-oracle (B)** on a drift stream | post-drift regret, time-to-recover, area-between-curves |

If C1 fails, the surrogate is *unnecessary* (a lookup wins). If C2 fails, it is *pointless* (the oracle
is as cheap). If C3 fails, it is *unsafe* (drift breaks it). All three must hold **simultaneously on the
same benchmark** — and that benchmark must be the **graded** one (§4), because the un-graded task is
decision-easy and C1 fails there by construction (`E4_RESULTS.md` caveat).

---

## 1. The comparison groups (the baseline zoo)

Two families. Family 1 answers **C1** (is a learned model needed?); Family 2 answers **C2/C3** (does it
save compute and stay safe?). Every member is either a **prior-art regime** or an **ablation** of the
full system — so the same table is the "vs prior art" comparison (`PROPOSAL.md` E-grid = `E4_RESULTS.md`
cells).

### Family 1 — zero-planner-call decision rules (for C1: necessity)
These spend **0 planner calls**; they decide from the event alone. If any ties the surrogate at k=0, the
surrogate buys nothing over it.

| baseline | decision rule | what it tests | why it can win on the easy task |
|---|---|---|---|
| `random` | uniform over valid macros | floor | — |
| `always-X` | one global fixed macro (the modal oracle-best) | is there *any* structure? | if one macro is usually best |
| **`always_per_kind`** ⭐ | best fixed macro **per OOD kind**, fitted fold-locally | **is state beyond `kind` needed?** | **wins iff `H(best\|kind)=0`** — the decision-easy trap |
| `heuristic` | hand rule ("fault→Replace, zone→ForbidZone") | is a naive rule enough? | ties `always_per_kind` when kind⇒macro |
| **surrogate (k=0)** | argmax of predicted value, no verification | **ours, at 0 calls** | must beat all of the above |

⭐ `always_per_kind` is **the** opponent for C1. It is exactly the policy a model exploiting
`H(best|kind)=0` collapses to (`GRADED_OOD_DESIGN.md` §5). **The necessity claim is precisely
`surrogate < always_per_kind` at k=0, with a paired bootstrap CI that excludes 0.** It must be fitted
**fold-locally** (training instances only) — fitting on all instances leaks the held-out label and
unfairly strengthens it (this bug hid the effect until `verify.py` S1 caught it).

### Family 2 — verify-budget policies (for C2 amortization & C3 robustness)
These spend **k true-planner calls** to verify the surrogate's top-k, then commit to the best verified.
k=0 trusts the surrogate; k=N is the oracle. The four named cells are the `E4_RESULTS.md` ablation grid;
each drops exactly one component and equals one prior-art regime.

| cell | producer (candidates) | scorer | retrain | = prior-art regime | role |
|---|---|---|---|---|---|
| **A** | all 5 macros | oracle (verify all) | — | brute-force TAMP oracle | **quality ceiling** (regret 0, max compute) |
| **B** | LLM (N candidates) | oracle (verify all) | frozen | LLM→exact solver (arXiv 2506.18178) | strong prior-art baseline |
| **C** | LLM (N candidates) | **surrogate (top-1)** | frozen | learned surrogate, no retrain (E2 static) | cheapest; the C3 straw-man |
| **D** | LLM (N candidates) | **surrogate (top-1)** | **active** | **FULL system (ours)** | must sit on the Pareto front |
| `verify-top-k` sweep | LLM or all | surrogate, verify k | frozen | — | traces the C2 **frontier** (k=0…N) |
| `random-order verify` | all | **no surrogate**, verify k in random order | — | ablate the ranking | isolates the surrogate's ranking value at each k |

---

## 2. The evaluation metrics (the ladder, re-indexed by which claim it proves)

From `EVALUATION.md`, restated so each level maps to a claim. **Two governing principles:**
1. **Measure the decision, not the prediction.** A surrogate with terrible value-MAE but correct macro
   *ranking* makes identical decisions (value-equivalence, à la MuZero). Headline is decision-level.
2. **Quality and compute are measured jointly.** Quality alone makes "just run the true world" win; the
   frontier is the deliverable.

| level | metric | proves | headline? |
|---|---|---|---|
| **L0** intrinsic | closed/makespan/min-SoC MAE·R², completion AUC/Brier, **calibration ECE** | it is a *world model* (diagnostic; ECE matters because verify-top-k & active-learning trust its uncertainty) | no (Level-0 trap) |
| **L1** decision-fidelity | **top-1 decision regret**, NDCG@k / Kendall τ, top-k recall, agreement rate | **C1** — regret=0 ⇒ right decision even if all values are wrong | core |
| **L2** quality–compute frontier | 2D: regret vs #planner calls, sweeping k/N/retrain; **iso-quality compute reduction**, amortization ratio, **break-even query count** (incl. data-gen+train cost) | **C2** — near-oracle at X% compute | **HEADLINE** |
| **L3** beat-the-oracle | at matched compute, quality(LLM+surrogate, N_large) − quality(LLM+oracle, N_small) | upside — cheap scoring lets the LLM explore more candidates | optional |
| **L4** drift robustness | regret time-series, **area between** frozen-degradation & retrained-recovery, **time-to-recover**, retraining efficiency, held-out-severity regret | **C3** | core for E3/E4 |

**Scoring rules that make the numbers trustworthy (all levels):**
- **Feasibility-lexicographic**: `(complete, then closed-count, then realized makespan)`. A
  good-makespan-but-non-completing macro must lose. In cost-aware mode: `(complete, closed − λ·cost(macro),
  −makespan)` so restraint (NOOP) can win a tie; report λ∈{1,3,6} sensitivity, not one flattering value.
- **Catastrophic-choice rate** — fraction of decisions where the surrogate picks an infeasible/
  non-completing macro the oracle avoided. Always report alongside mean regret; one catastrophic pick can
  outweigh average regret.
- **Per-scenario normalization** — normalize regret by the per-instance oracle-best→worst span before
  averaging, so easy/hard scenarios weigh equally.
- **Paired statistics** — surrogate and every baseline decide on the **same** OOD instance → paired
  bootstrap / Wilcoxon CIs. Many seeds × assembly models × OOD events.

---

## 3. Validity guards — six must-haves without which the ground truth is an artifact

From `ORACLE_FINDINGS.md`. These are not optional hygiene; several **flip the oracle's answer**, so a
surrogate trained/evaluated without them learns the wrong thing.

1. **Oracle eval set** — for each held-out OOD event, brute-force the true outcome of *every* candidate
   macro (expensive, eval-time only). This is the ground truth the surrogate amortizes.
2. **Realized, not planned, makespan** ⚠️ — planned `makespan(sched)` is invariant under a no-op re-plan
   (measured: healthy 419 vs faulted-noop 887 realized steps, *identical* planned makespan). Use
   `stats[:Makespan] = time_steps·dt`.
3. **Healthy control + admissibility** ⚠️ — run each OOD once with no fault (control). *(Original rule:
   an instance enters only if no-op is strictly worse than control.)* **Note the graded task retires this
   filter** (§4) — harmless instances carry the restraint signal — replacing it with the cost-aware
   objective; keep `admissible` as a column for reproducibility.
4. **Feasibility-lexicographic + catastrophic-choice rate** — as in §2.
5. **Per-scenario normalization** before aggregation.
6. **Paired stats** across many seeds/models/events.

**Two guards that literally invert the answer (fairness invariants):**
- **RVO must be ON** (`ORACLE_FINDINGS.md` §7). With the reactive motion stack off, the oracle-best
  flips (NOOP beats Replace because the distributed hand-off wedges without RVO priority). The correct
  macro is **congestion-dependent** — precisely the non-obvious dynamics that justify a learned surrogate
  over a naive rule. Cost reduction must come from process-parallelism, **not** from cheaper physics.
- **The candidate varies only at the studied event** (`ORACLE_FINDINGS.md` §8). All background events
  (e.g. `:reform`) take the canonical response identically for every candidate; otherwise a replayed
  fault-action silently disables endgame recovery and wedges every arm. This is the same **cascade-NOOP /
  own-your-consequences** rule `verify.py` V0 checks.
- **Spare provisioning** — under-provisioning makes Replace fail (0.636 completion at n_spare=1) as an
  *artifact*, not a property of the decision. Provision `n_spare ≥ faults × tasks/fault`.

---

## 4. The benchmark this must run on — graded, not easy

**All three claims must be evaluated on `oracle/out/graded.jsonl`, not the original `e1_dataset.jsonl`.**
Reason: the un-graded tractor taxonomy is decision-easy — `best_macro = f(kind)`, `H(best|kind)=0` — so
**C1 fails by construction** (`always_per_kind` ties the surrogate; `E4_RESULTS.md` caveat; `e1_frontier`
self-check reports a flat frontier). The graded generator (`GRADED_OOD_DESIGN.md`) makes the correct
macro vary *within* a kind (battery SoC ladder, fault reparability, zone coverage) and charges an
adaptation cost, which:
- restores `H(best|kind)` 0→0.97, `always_per_kind` regret 0→0.662 → **C1 becomes provable**;
- makes the surrogate imperfect at k=0 (regret 0.18, not 0) → **the C2 frontier becomes a curve** with
  headroom for verification to buy back;
- sharpens C3 because post-drift severity differs, not just kind.

---

## 5. Success thresholds (per claim) and current status

| claim | comparison | metric | success threshold | status |
|---|---|---|---|---|
| **C1** necessity | surrogate(k=0) vs `always_per_kind` | top-1 regret, paired CI | CI on advantage excludes 0 | ✅ **verified** — 0.236 vs 0.666, **+0.430 CI [+0.178,+0.669]** (`verify.py` S1, graded, RF & HGB) |
| C1 support | surrogate vs kind-only ablation | regret | state strictly helps | ✅ +0.279 (`verify.py` S4) |
| C1 support | difficulty audit | `H(best\|kind)`, per-kind maj. acc | H>0.5, maj≤70% | ✅ H=0.97, maj=57% (`GRADED_OOD_DESIGN.md` §6b) |
| **C2** amortization | verify-top-k sweep vs verify-all | iso-quality compute reduction | regret≤ε at k≪N | ⚠️ **re-run on graded** — `e1_frontier.py`/`e2` still use the admissibility path (easy); need cost-aware + `always_per_kind` overlay |
| C2 support | model-order vs random-order verify | regret at each k | surrogate ranks > random | partial (`e1_frontier` random column) |
| C2 support | break-even | queries to repay data-gen+train | finite, reported | ❌ not yet computed |
| **C3** robustness | C (frozen) vs D (retrain) vs B (oracle) on drift | post-drift regret, time-to-recover | D≈oracle, C collapses | ✅ on easy data (D 0.040/post-drift 0.111 @41 calls vs C 0.360/1.000 @25; B 0 @75) `E4_RESULTS.md`; ⚠️ **re-run on graded** |
| validity | all | 6 must-haves + RVO-on + cascade | enforced | ✅ enforced in `gen_oracle_dataset.jl`; V0 re-checks |

**Headline sentence when all green:** *On the graded benchmark, the surrogate makes near-oracle
decisions (regret ≤ ε) reading state that a per-kind lookup cannot (C1: +0.430 CI-significant), at a
fraction of planner compute (C2: X% fewer calls at iso-quality), and — unlike a static surrogate —
stays safe under OOD drift because it retrains (C3: post-drift regret 0.11 vs 1.00).*

---

## 6. The concrete gap to close (what to run next)

The necessity claim (C1) and validity (V0–L3) are **done on graded**. The two remaining are **C2 and C3
on the graded dataset** — the existing `e1_frontier.py`, `e2_llm_surrogate.py`, `e4_ablation.py` still
run the **old admissibility path on `e1_dataset.jsonl`** (decision-easy), so their published frontiers
are flat/uninformative for C1 and don't overlay `always_per_kind`.

**Action:** add a `--cost-aware` scoring mode (mirroring `e1_analyze.py`) to `e1_frontier.py` /
`e2_llm_surrogate.py` / `e4_ablation.py`, run them on `oracle/out/graded.jsonl`, and overlay the
Family-1 zero-call baselines (`always_per_kind`, heuristic) as horizontal lines on the frontier. Then all
three claims are proven on one benchmark, with one figure: **the decision-regret vs planner-compute
frontier, with the lookup baselines as the flat line the surrogate must beat at k=0 and the oracle as
the point it must approach as k→N.**
