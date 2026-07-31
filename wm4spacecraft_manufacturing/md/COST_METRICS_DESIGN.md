# Cost-of-Adaptation metrics — proving the surrogate beats a general LLM planner on cost

**2026-07-15.** The existing evaluation (`EVALUATION.md`, `SURROGATE_NECESSITY_EVAL.md`) proves the
surrogate is *accurate* (C1 necessity) and *compute-efficient in an abstract unit* — **# true-planner
calls** (C2). What it never does is convert that abstract unit into **operational cost** (seconds,
tokens, dollars) or put the surrogate **head-to-head against a general LLM planner** in those units.

This doc designs that missing layer. One question: **at the moment an OOD event fires mid-build, what
does it actually cost — in wall-clock, in money, in whether the build finishes — to decide what to do,
and is the surrogate cheaper than an LLM planner at equal or better decision quality?**

Everything here is measured or swept, never asserted. The two dominant costs (the planner-sim call and
the surrogate inference) are **measured from this repo's own artifacts**; the LLM planner's latency and
token cost are **measured live** when an API key is present and otherwise swept across published price/
latency tiers so the conclusion is shown to hold for the whole plausible range.

---

## 1. The decision event and the policies being priced

A single **decision event** = one OOD fires mid-build (a robot faults, a battery hits low SoC, a no-go
zone appears). A policy must choose one of 5 DSL macros {NOOP, Replace, Deprioritize, ForbidZone,
ReformTeam}. We price the five policies that span the design space; each is a member of the existing
baseline zoo (`SURROGATE_NECESSITY_EVAL.md` §1), now costed in real units.

| policy | decision rule at the event | planner-sim calls | LLM calls | what it represents |
|---|---|---|---|---|
| **Oracle (A)** | run the true sim on all 5 macros, take the feasibility-lexicographic best | **5** | 0 | brute-force TAMP ceiling (regret 0, max cost) |
| **LLM→solver (B)** | LLM proposes C candidates from the event text, verify **every** one with the true sim, commit to best | **C** (≈3) | 1 | LLM + exact solver (arXiv 2506.18178) — the strong prior-art baseline |
| **LLM-only planner** | LLM reads the event and picks a macro directly, **no verification** | **0** | 1 | a general LLM planner used as the decision-maker |
| **Surrogate→verify-k (ours)** | LLM (or the full repertoire) proposes C, the surrogate ranks them in imagination, verify only the **top-k**, commit to best | **k** (0…C) | 0–1 | the amortized system, verification optional |
| **Surrogate-only, k=0 (ours, deployed)** | surrogate reads state, picks a macro, **0 verification, 0 LLM** | **0** | 0 | what the V4 demo actually runs |

The cost of a policy at one event is
```
cost = LLM_calls · (T_llm , $_llm)  +  planner_calls · T_sim  +  surrogate_infer · T_surr
```
and its quality is the decision regret + whether the resulting build completes.

---

## 2. The metric ladder (five axes the user named, made precise)

Each axis has a **unit**, a **source** (measured / swept), and the **policy it indicts**.

### M1 — Planning latency (wall-clock **per decision**)
Time from "OOD fired" to "macro chosen", the quantity that decides whether adaptation keeps pace with
the running build.
- `T_sim` (one true-planner verification) — **measured** = `label_seconds` in the oracle rows.
  Distribution reported (median / mean / P90) with a bootstrap CI, not a point estimate.
- `T_surr` (one surrogate forest evaluation) — **measured** by timing the deployed
  `surrogate_hotswap.json` (60 trees) on real feature rows, single-row (a decision is one event).
- `T_llm` (one LLM planning round-trip) — **measured live** if an API key is present (median over N
  real calls); else swept over published latency tiers.
- **Headline:** `latency(policy) = LLM_calls·T_llm + planner_calls·T_sim + surrogate_infer·T_surr`.
  Report per-decision latency for every policy, and the **speed-up ratio** surrogate-only vs each.

### M2 — Planning accuracy (decision quality)
Reuses the validated Level-1 metric so the cost axes attach to the *same* ground truth.
- **Top-1 decision regret** (feasibility-lexicographic, per-scenario normalized), leave-one-instance-out,
  paired — **measured** on `graded_hs_all.jsonl`.
  - Oracle: 0 by construction. Surrogate-only: the LOO regret (measured). LLM→solver: the
    candidate-set residual (true best-in-set vs global best — measured from the data, ≈0).
  - **LLM-only planner accuracy** is modeled *in the LLM's favour*: a general LLM handed the OOD-kind
    text but no simulation can, at best, apply the textbook per-kind macro — which is exactly the
    `always_per_kind` policy. So we score the LLM-only planner at `always_per_kind` regret (its **best
    case**; a real LLM that misreads the kind does worse). Giving the LLM its best case makes the
    surrogate's win conservative. We also sweep LLM accuracy from `random`→`heuristic`→`always_per_kind`.
- **Catastrophic-choice rate** — fraction of events where the policy picks an infeasible/non-completing
  macro the oracle avoided. Reported beside mean regret (one catastrophe outweighs average regret).

### M3 — Whole adaptation time (per **build**, over an OOD stream)
A build sees a *stream* of D OOD events (the B7 demo: `battery@54 zone@105 fault@139 battery@189`,
D=4). The build cannot proceed past an event until its decision is made, so per-build adaptation cost is
`Σ latency(policy, event)`. **Headline number:** total wall-clock spent *deciding* during one build,
oracle vs LLM→solver vs surrogate-only. This is the axis where minutes-per-decision compounds into
hours-per-build.

### M4 — Planning completion (feasibility outcome)
Does the build actually finish under each policy's decisions? — **measured** from the per-macro
`complete` flags: enact each policy's chosen macro at each event and read whether the resulting world
completes. A policy that is fast and cheap but stalls the build (e.g. LLM-only NOOP's a deep-battery
robot) fails the only outcome that matters. Reported as completion-rate across instances.

### M5 — Monetary cost (**$ per decision** and **$ per build**)
- Surrogate-only: `$≈0` at decision time (one-time training cost amortized — see break-even below).
- LLM policies: `$_llm = input_tokens·price_in + output_tokens·price_out` — **measured live** (real
  token counts) or computed from published per-token prices across tiers.
- LLM→solver additionally pays the compute of C planner sims (wall-clock → cloud-CPU-hour $ if desired).
- **Break-even query count:** how many decision events until the surrogate's one-time data-generation +
  training cost (measured: 6.0 h of oracle sim to build `graded_hs_all.jsonl`, plus seconds to train)
  is repaid by the per-decision saving vs LLM→solver. Reported honestly — the surrogate is not free,
  it is *amortized*, and we state the amortization point.

---

## 3. The headline deliverables

1. **Per-decision cost table** — every policy × {latency, regret, catastrophic, $}. One row shows the
   surrogate makes a near-oracle decision in ~milliseconds and ~$0 while the only zero-regret LLM policy
   (LLM→solver) needs C·T_sim ≈ minutes and the LLM-only planner is fast-but-wrong.
2. **The cost–quality frontier, in real units** — x = latency (log s) or $/decision, y = decision
   regret. The surrogate-only point sits at the bottom-left (low regret, low latency); oracle at
   bottom-right (0 regret, high latency); LLM-only at top-left (low latency, high regret); LLM→solver at
   bottom-far-right (0 regret, highest latency). The surrogate **dominates** — nothing is both cheaper
   and more accurate.
3. **Per-build adaptation-time bar** — Σ latency over the D=4 stream, oracle vs LLM→solver vs
   surrogate, annotated with completion (✓/✗).
4. **LLM sensitivity band** — the surrogate's latency and $ advantage plotted across the whole
   published range of LLM latency/price, showing the conclusion is not tuned to one price point.
5. **Break-even curve** — cumulative cost vs #decisions for surrogate vs LLM→solver; the crossover is
   the amortization point.

## 4. Validity guards (carried over, so the cost numbers attach to honest quality)
The cost layer sits on top of the already-validated accuracy ground truth, so every guard from
`SURROGATE_NECESSITY_EVAL.md` §3 still binds: **realized (not planned) makespan**, **RVO on** (else the
oracle-best flips and the task looks cheaper than it is), **candidate varies only at the studied event**,
**ample spares**, **feasibility-lexicographic + catastrophic-choice**, **per-scenario normalization**,
**paired bootstrap CIs**, and the **graded** benchmark (the un-graded task is decision-easy so accuracy —
and therefore the whole cost argument — would be an artifact). `T_sim` is measured **with RVO on**, so
the verification cost the surrogate saves is the honest one.

## 5. What is measured vs modeled (stated up front, no hidden assumptions)
| quantity | status | source |
|---|---|---|
| `T_sim` planner-call wall-clock | **measured** | `label_seconds`, 100 rows, `graded_hs_all.jsonl` |
| `T_surr` surrogate inference | **measured** | timed `surrogate_hotswap.json` eval, this repo |
| decision regret / completion / catastrophic | **measured** | LOO on `graded_hs_all.jsonl` |
| training/data-gen cost (break-even numerator) | **measured** | Σ `label_seconds` = 6.0 h |
| `T_llm`, `$_llm` | **measured live if API key**, else **swept** | OpenAI call, or published price/latency tiers |
| LLM-only planner accuracy | **modeled, in the LLM's favour** | `always_per_kind` (best case) + a sweep |

The only genuinely modeled input is the LLM planner's own latency/price/accuracy, and each is either
measured live or swept across its full plausible range — so the surrogate's dominance is demonstrated,
not assumed.
