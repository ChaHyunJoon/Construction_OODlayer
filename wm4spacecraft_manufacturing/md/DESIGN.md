# Design — GNN surrogate & Graded-severity OOD

> Provenance: consolidated from `DESIGN_NEXT.md` ("Design: GNN surrogate & Graded Consequential OOD", 2026-07-12) and `GRADED_OOD_DESIGN.md` ("Graded-severity OOD — making the decision problem non-trivial", 2026-07-13). Originals retained.

This doc consolidates the designs for the two open ingredients after E1–E4 are complete: a **GNN model upgrade** (Part 1) and the **graded-severity OOD generator** that turns the decision task from *easy* (OOD-kind ⇒ macro) into a graded ranking with a smooth quality–compute curve (Part 2). The GNN is gated by the E1 feature-model milestone, **which passed**; the graded OOD is the one missing piece that makes ranking non-trivial and therefore gives the GNN (and the verification budget) something to earn.

---

## GNN surrogate

*(from `DESIGN_NEXT.md` §1 — GNN surrogate over `(scene tree + schedule DAG)`)*

### Why

The E1 feature-HistGBR predicts the re-plan outcome from ~13 scalar features (R²≈0.83). It ranks
perfectly on the current easy task, but scalar features throw away the **structure** the true planner
reasons over — which robot is where in the schedule DAG, which transport teams feed which build steps,
how far the disruption propagates. On a *graded/harder* taxonomy (Part 2) that structure is what
separates close candidates. Per `PROPOSAL.md` the feature-model go-signal **gates** this GNN
investment; the signal is met.

### Graph representation (de-risked — all extractable from `env.sched`)

- **Nodes** = schedule DAG vertices. 10 node types confirmed present: `RobotStart, ObjectStart,
  AssemblyComplete, RobotGo, TransportUnitGo, LiftIntoPlace, OpenBuildStep, CloseBuildStep,
  FormTransportUnit, DepositCargo`.
- **Node features**: type one-hot (10) · `t0`,`tF` (scheduled start/end, normalized) · closed/active/future
  flag (from `env.cache.closed_set`/`active_set`) · is-the-OOD-target flag (the faulted robot / the
  blocked assembly / the low-SoC robot) · agent id-hash bucket · staging-circle overlap for zone nodes.
- **Edges** = DAG edges (`Graphs.edges(sched)`), typed by endpoint pair (assignment edge RobotGo→RobotGo,
  precedence, team-membership). Add reverse edges for bidirectional message passing.
- **Global**: the candidate macro (one-hot) + OOD descriptor (kind/severity/spare_count) as a graph-level
  conditioning vector concatenated into readout — so the SAME graph, scored under different macros, gives
  different predictions.

### Architecture (no PyG required — hand-rolled message passing in torch; torch 2.5+CUDA present)

- 3–4 layers of `h_v ← MLP(h_v, Σ_{u∈N(v)} MLP_edge(h_u, e_uv))` (GraphSAGE/GIN-style; relational by
  edge type). Hidden 64–128.
- Readout: attention or mean-pool over nodes → concat the global (macro + OOD) vector → MLP head →
  predict the RunMetrics targets (completion logit, closed-count, realized makespan, min-SoC).
- Loss: **decision-focused** (SPO+/pairwise rank on the per-instance macro ordering), NOT plain MSE —
  the EVALUATION.md value-equivalence point. Keep an MSE aux head for the L0 diagnostic.
- Train an **ensemble (5–10)** for the conformal/uncertainty gate the E2/E3 verify-top-k and drift
  monitor consume.

### Dump seam (the only new Julia work)

Extend `gen_oracle_dataset.jl`'s `capture_features` to also serialize, per instance, the DAG at the OOD
event: `nodes[]` (type, t0, tF, status, flags) + `edges[]` (src, dst, type) as a JSON sub-object. One
graph per instance (shared across its 5 macro rows); the macro is the global conditioning vector. Python
loads it into a torch geometric-style batch. Instance count and graph size are modest (≈300 nodes), so a
single GPU trains in minutes.

### Expected benefit & how it plugs in

Drop-in replacement for `build_model()` in `e1_analyze.py` / `e3` / `e4`. On the current easy task it
also scores regret 0 (so it is *not* a completion blocker — deferred, as documented). Its payoff is
Level-0 accuracy (tighter R², calibrated uncertainty) which **matters once ranking is non-trivial** —
i.e. together with the graded OOD below.

---

## Graded-severity OOD

*(authoritative spec from `GRADED_OOD_DESIGN.md`, with unique material from `DESIGN_NEXT.md` §2 folded in and marked)*

Written against the E1/E2 finding that the frontier is a *step*, not a curve: `model` regret is 0.000 at
**k=0** for every budget, so only the `random` column moves. This part specifies exactly what to change so
the ranking becomes non-trivial, how to measure that it worked, and what would falsify it.

### 1. The precise diagnosis (not "severity is missing")

The current task is easy because of one identity:

```
best_macro = f(kind)          H(best_macro | kind) = 0 bits
  fault   -> Replace     (23/23 instances)
  zoneblk -> ForbidZone  ( 9/ 9 instances)
```

The surrogate does not need to read severity, SoC, spare count, or progress: a 4-way one-hot on the
OOD kind, plus the `macro_in_valid` mask, already determines the argmax. Two mechanisms produced
that identity, and **both must be removed** — a severity scalar alone fixes neither:

1. **Admissibility discards the ambiguity.** `instance_admissible` keeps an instance only if NOOP is
   strictly worse than the healthy control. Every instance where "do nothing" was the right call was
   deleted from the dataset *by construction*. The model therefore never sees a case where restraint
   wins, and learns `coef[macro_NOOP] = -15.9` — it is structurally incapable of choosing NOOP.
2. **One dominant macro per kind.** Within a kind, the intervention always pays: a spare is always
   available, a zone always blocks a pending staging area. There is no cheap/expensive trade-off.

So the target is not "add a severity number." It is:

> **Make the correct macro vary WITHIN a kind, as a function of state the model can read
> (severity, SoC, spare_count, agent_pending, progress) — and let NOOP be correct sometimes.**

Formally, the acceptance criterion is on the *label distribution*, not on the model:
`H(best_macro | kind) > 0` and a per-kind majority vote must be materially wrong.

*(DESIGN_NEXT §2 phrases the same finding as: every consequential OOD has ONE dominant recovery macro,
the admissibility rule removes the ambiguous "should I even intervene?" cases, so the surrogate's top-1
is always right and the regret-vs-compute frontier is a **step, not a curve** — E1_RESULTS §caveat. We
need instances where the best macro **depends continuously on a state variable** so ranking near the
threshold is genuinely hard.)*

### 2. The three graded axes

Each OOD kind gets a severity axis whose two ends have **different** correct macros. Severity is
already a dataset column and a model feature, so the surrogate can learn the threshold; the
state-blind baselines cannot.

#### 2.1 `battery` — a genuine 3-way ladder (the strongest axis)

This one only became available today. The battery injector's target picker was
`argmax(SoC)` over the whole fleet — and once the battery layer is on, the highest-SoC robots are the
**parked spares** (idle ⇒ never drain, and they own no tasks). Every battery OOD was therefore hitting
a robot with `agent_pending = 0`, so Replace had nothing to hand over and **all five macros returned
byte-identical sims** (closed=291, makespan=18.45). "Battery is harmless in the tractor twin" — the
conclusion recorded in `DESIGN_NEXT.md` §2 — was an artifact of that bug, not a property of the
environment. Fixed in `src/navigator/battery.jl::_pick_battery_target` (prefer a cleanly-replaceable
working robot; never a spare).

With a *working* robot as the target, post-drop SoC becomes a real severity axis, because the robot's
fate depends on SoC **relative to the energy its remaining work costs**:

| severity (post-drop SoC) | what happens under NOOP | correct macro |
|---|---|---|
| **deep** (≤ stall threshold, e.g. 0.05) | robot stalls immediately, mid-haul, holding a pending chain | **Replace** (spare adopts the chain) |
| **marginal** (just above stall, e.g. 0.15–0.30) | robot keeps working but runs flat *later*, mid-haul | **Deprioritize** (offload the heavy/long hauls; it finishes its light ones) |
| **mild** (e.g. 0.5–0.7) | robot completes everything on the remaining charge | **NOOP** (restraint — a spare would be wasted) |

The marginal band is the interesting one: the flip point is **not** a constant in SoC. It depends on
how much work the robot still owns (`agent_pending`) and how far the build has progressed
(`progress`). A model that reads only `severity` gets the band wrong; one that reads
`severity × agent_pending` gets it right. That is a learnable interaction — exactly what was missing.

**Knobs that make the ladder real:** the drain rate must be fast enough that "runs flat later" can
actually happen. `DS_SHRINK` (battery capacity ÷ SHRINK) controls this: the current 200 is the
*gentle* setting where natural drain never depletes anyone, which collapses the marginal band onto
the mild one. Calibration procedure in §4.

Sweep: `DS_BSOC = 0.05, 0.12, 0.20, 0.30, 0.45, 0.60` × seeds.

*(DESIGN_NEXT §2 path 3 adds the critical-path nuance: to make deep→Replace vs mild→Deprioritize
genuinely split, target the drain at a robot whose loss **blocks a downstream build step**, co-tuning
`shrink`/`ENERGY_W`/target-selection — the E1 attempt drained a non-critical robot that spares absorbed.)*

#### 2.2 `fault` — severity = *reparability*, not damage

A breakdown is not intrinsically graded; what varies is whether the repair is available and worth it.
Two orthogonal knobs, both already state-visible:

- **`n_spare = 0`** — `ReplaceAgent` has no spare to draw on, so it degenerates (or wastes a replan).
  The correct macro becomes `ReformTeam` (re-establish the wedged team without the dead robot) or
  `NOOP`. The model must read `spare_count`, which it currently ignores (coef 0.686, noise-level).
- **victim selection** — fault a robot with **no pending assignment** (it just delivered its last
  cargo). The breakdown is real, the event fires, the NL is identical — but it costs nothing.
  Correct macro: **NOOP**. This is the harmless↔consequential split *within* `fault`, and it is the
  single most important addition, because `fault` is 72% of the dataset.

Severity encoding: `severity = agent_pending_at_fire / max_pending` (0 = harmless, 1 = holds a full
chain). Note `agent_pending` is *already* a feature (and already the largest-magnitude coefficient,
−44.9) — it just never varied, because the injector always picked a robot with work.

Sweep: `DS_FAULT_TARGET = frontier | idle` × `DS_SPARES = 0, 1, 3, 6`.

*(DESIGN_NEXT §2 path 2 adds a **late-vs-early fault timing** axis: a very-late fault on a near-done
robot lets NOOP complete (loses little) while Replace adds churn → best flips to NOOP on the speed axis.
This needs the safe-target picker relaxed to fire late — the current window is `closed ∈ [58,80]`.)*

#### 2.3 `zone` — severity = *what the zone actually covers*

The earlier graded attempt (sweeping the zone radius fraction 0.5→1.3, and the offset 0→2.0) produced
**no flip**: NOOP=239 / ForbidZone=291 at every setting. That is a property of the tractor layout —
the staging circles are packed tightly enough that any zone near one blocks it. Grading the *radius*
is the wrong axis. Grade **what it covers**:

| variant | correct macro |
|---|---|
| zone over a **pending** assembly's staging circle (current `zoneblk`) | **ForbidZone** (restage) |
| zone over an **already-closed** assembly's staging circle | **NOOP** (nothing left to stage there) |
| zone over open floor / a transit corridor only | **NOOP** (RVO + TangentBug detour absorbs it) |

`severity = overlap_fraction_with_pending_staging ∈ [0,1]`, computed at fire time from the geometry —
a continuous feature, with a genuine flip at the low end.

Sweep: `DS_ZONE_TARGET = pending | closed | corridor` × the existing `DS_ZFRACS`.

**Detail on the failed radius/offset attempt (from `DESIGN_NEXT.md` §2).** The mechanism was
`place_blocking_zone!(env; offset, rfrac)`, exposing two continuous knobs — zone radius as a fraction of
the target staging circle (`rfrac`) and the zone's offset from the staging centre (`offset`). Two sweeps
at seed 1 (`DS_ZFRACS`):

| sweep | values | NOOP | Replace | ForbidZone | oracle-best |
|---|---|---|---|---|---|
| radius `frac` (centred) | 0.5,0.7,0.9,1.1,1.3 | 239 (incomplete) | 239 | **291 (complete)** | ForbidZone — **no flip** |
| `offset` toward core | 0.0,0.5,1.0,1.5,2.0 | 239 (incomplete) | 239 | **291 (complete)** | ForbidZone — **no flip** |

NOOP sits at *exactly* 239 across every setting — evidence that in this tractor layout **any zone placed
near a staging area blocks the build**: shrinking it still covers the centre; offsetting it toward the
core just blocks a *different* staging/core region. The build area is too tightly packed for a
"harmless-but-present" zone to exist at these fire points — a genuine environmental property, not a
tuning miss. Hence the pivot above to grading *what the zone covers* rather than its radius.

### 3. The label rule must change too (or the ambiguity is deleted again)

Three coupled changes. Without **all three** the new instances get filtered out or mislabelled.

**(a) Retire admissibility; keep every fired instance.** Harmless instances are no longer noise — they
carry the restraint signal. (Keep the `admissible` flag as a *column* so E1–E4's published numbers
remain reproducible by filtering.)

**(b) Charge the adaptation cost.** With harmless instances included, `closed` ties across macros and
the argmax becomes arbitrary. Charge each macro what it actually consumes (the `OODRewardCfg` vector
from `decpomdp/examples/ood_env_mdp.jl`):

```
y = closed − λ · cost(macro),    cost = {NOOP 0, Deprioritize 0.3, Replace 1.0, ForbidZone 1.0, Reform 1.0}
```

λ is in schedule-nodes; λ = 3 leaves consequential decisions untouched (Replace buys ≈ +21 nodes on a
real fault, ForbidZone ≈ +52 on a real zone) while making NOOP win every tie. **λ is a stated
preference, not a tuned hyperparameter** — report the frontier's sensitivity to λ ∈ {1, 3, 6} rather
than picking the flattering one.

**(c) Score the makespan tiebreak *within* the cost-adjusted class**, as
`lex = (complete, closed − λ·cost, −makespan)`. Unchanged from EVALUATION.md except for the cost term.

Implemented behind `--cost-aware` in `export_surrogate.py`; must be mirrored in `e1_analyze.py` /
`e1_frontier.py` as a `--cost-aware` scoring mode (the default path stays byte-identical, so E1–E4 do
not move).

**Concept-validation (from `DESIGN_NEXT.md` §2, path 1 — the recommended path, "VALIDATED IN CONCEPT,
no environment change").** The realistic decision the operator faces is: an OOD appeared — do I pay to
intervene (Replace/ForbidZone: consumes a spare, churns the schedule, adds makespan) or not (NOOP)?
Scoring feasibility-lexicographic with the `OODRewardCfg` cost as the tiebreak among completing macros
was **verified in Python** on the existing dataset + the harmless battery instances: the best-macro
distribution becomes **{Replace 23, ForbidZone 9, NOOP 2}** — for a *harmless* OOD (all macros complete)
NOOP wins (intervention is wasted cost), giving a 3rd "restraint" decision class. To finish: (a) bake the
cost-aware ordering into `e1_analyze.py` as a scoring mode; (b) generate a *matched* harmless set
(small-far zone / mild no-stall battery — already generatable, they were only being filtered out by
admissibility). This manufactures NOOP-best vs intervene-best instances on the existing physics.
**Remaining for full non-triviality:** a WITHIN-kind harmless↔consequential split (e.g. battery
mild→NOOP vs deep-critical→Replace) so `kind` alone can't separate them — that still needs the
critical-path battery of §2.1.

### 4. Calibration — the step that decides whether this works

The marginal battery band and the harmless-fault class only exist if the physics cooperates. Do **not**
generate the full dataset before this is checked; that is how the previous graded attempt burned hours.

**Probe (cheap, ~6 sims):** for one seed, run **NOOP only** at `DS_BSOC ∈ {0.05, 0.15, 0.25, 0.40, 0.60}`
and record `(complete, closed, n_stalled, min_soc)`.

Acceptance for the ladder — the NOOP outcome must be **monotone and non-degenerate**:
- `soc = 0.05` ⇒ `n_stalled ≥ 1` and `closed` materially below the control (the robot dies holding work).
- `soc = 0.60` ⇒ `n_stalled = 0`, `closed = control` (harmless — NOOP is correct).
- **at least one middle value must land strictly between them.** If every middle value behaves like
  0.60, raise `DS_SHRINK` (faster drain) until it doesn't. If every middle value behaves like 0.05,
  lower it.

If no `DS_SHRINK` produces a strict middle, **abandon the 3-way ladder and keep the 2-way
(deep→Replace / mild→NOOP) split.** A 2-way split *already* breaks `H(best|kind) = 0` and is enough
for a curved frontier — the 3-way is a bonus, not a requirement. Say so in the results rather than
tuning until it appears.

Same idea for `fault`: confirm the idle-victim run gives `closed == control` (harmless) before
generating the sweep.

### 5. Evaluation changes — a harder baseline, and a difficulty audit

The current `always` baseline is a single global macro. Against a per-kind-labelled dataset that is a
straw man. Add the **strongest state-blind opponent**:

- **`always_per_kind`** — the best fixed macro *per OOD kind*, fitted on the training folds. This is
  precisely the policy that a model exploiting `H(best|kind)=0` would collapse to. **The learning
  claim is `model < always_per_kind`, with a paired bootstrap CI.** If the surrogate cannot beat it,
  the severity axis did not bite, and no amount of GNN capacity will help.

Report a **difficulty audit** with every dataset, before any model is fit:

| statistic | easy (today) | target |
|---|---|---|
| `H(best_macro \| kind)` | 0.00 bits | **> 0.5 bits** |
| per-kind majority accuracy | 100% | **≤ 70%** |
| fraction of instances where NOOP is best | 0% | **15–35%** |
| `model` regret at k=0 | 0.000 | **> 0** (a curve exists to improve) |
| `always_per_kind` regret | 0.000 | **≥ 0.20** |

The last two are the ones that turn the frontier back into a curve: `model` must be *imperfect but
much better than the state-blind policy at equal compute*. A dataset that pushes `model` to regret 0
again has simply moved the triviality somewhere else.

**Falsification.** If, after the sweeps, `always_per_kind` still reaches regret ≈ 0, the OOD taxonomy
itself is the limit (kind ⇒ macro is a true property of this twin), and the honest move is to report
that as a finding about the environment and to change the *action space* (e.g. Replace-with-which-spare,
Deprioritize-by-how-much) rather than the OOD generator. Do not keep tuning severities to manufacture
a curve.

**Success test (from `DESIGN_NEXT.md` §2).** `run_e1_e2.py`'s self-check turns GREEN (frontier no longer
flat) when the dataset contains both NOOP-best and intervene-best admissible instances with a transition
region; the surrogate then shows a small-but-nonzero k=0 regret that verification (k≥1) buys down — the
real amortization curve, and the graded drift that makes E3's monitor sensitivity a live tradeoff.

### 6. Why this comes before the GNN

Part 1 already argued this and the E1 numbers confirm it: on a dataset where a 19-feature
Ridge is decision-perfect at zero planner calls, a graph network changes nothing — there is no headroom
to buy. Graded severity creates the headroom (state-dependent flip points, interactions like
`severity × agent_pending`, geometry-dependent zone overlap). *Then* the GNN's structural inductive
bias has something to earn, and the verification budget has something to spend.

### 6b. MEASURED (2026-07-14) — the axes bite

Two engine bugs had to be fixed before any severity axis could work; both had silently flattened the
labels (details in `DEMO.md`): the battery OOD was hitting a **parked spare** (so every macro produced a
byte-identical sim), and the stall it caused raised its own breakdown alarm that the **background policy
answered with a canonical Replace inside the NOOP arm** (so "NOOP" was not NOOP). With those fixed:

| kind | severity axis | measured flip |
|---|---|---|
| battery | post-drop SoC | 0.05–0.12 → **Replace** (172 vs 151) · 0.20 → **NOOP** (213 vs 172) · 0.35–0.60 → **NOOP** (291 ✓ vs 172) |
| fault | victim's pending work | full chain → **Replace** · idle standby robot → **NOOP** (291 ✓, every macro) |
| zone | `zone_overlap` with a pending staging circle | 0.00 → **NOOP** · 0.31 → **NOOP** (244 vs 225!) · 0.49 → **ForbidZone** (291 ✓ vs 239) |

Difficulty audit on the graded set (**30 instances**, seeds 1–3), against the §5 targets:

| statistic | before (E1 dataset) | graded | target |
|---|---|---|---|
| `H(best_macro \| kind)` | 0.00 bits | **0.97** | > 0.5 |
| per-kind majority accuracy | 100% | **57%** | ≤ 70% |
| NOOP is best | 0% | **50%** | 15–35% (still too high) |
| `model` regret at k=0 | 0.000 | **0.181** | > 0 |
| `always_per_kind` regret | 0.000 | **0.662** | ≥ 0.20 |

And the learning claim, which was vacuous before, now holds **with significance**:

| policy | norm-regret | catastrophic |
|---|---|---|
| model (state-reading surrogate) | **0.181** | 2/30 |
| always (one fixed macro) | 0.447 | 4/30 |
| **always_per_kind** (best fixed macro *per kind* — the strong opponent) | 0.662 | 8/30 |
| random | 0.663 | 6/30 |

`model` beats `always_per_kind` by **+0.481, 95% CI [+0.261, +0.683]** (paired bootstrap, n = 30). On the
old E1 dataset the same comparison was **+0.000, CI [0.000, 0.000]** — i.e. everything the surrogate
"learned" was reproducible by a 4-entry lookup table on the OOD kind. It now genuinely reads severity.

The frontier is a curve again (`model` regret at k = 0 is 0.181, not 0), so verification budget has
something to buy back and a GNN has headroom to earn.

**Remaining imbalance:** NOOP is best in 50% of instances, well above the 15–35% target — the severity
grid over-samples the harmless region. Rebalance by adding consequential points (more `fault` with a
full pending chain, more `zoneblk` at overlap > 0.45) rather than by removing harmless ones, which
carry the restraint signal.

One model-class consequence worth recording: a **linear** surrogate cannot express this task. The
correct macro flips at a threshold, and an additive model gives every macro the same slope, so their
value curves never cross (Ridge scored 0.500 decision-regret on the zone instances even with explicit
interaction columns). The demo now deploys a RandomForest — the same *class* as the HistGBR used in
E1–E4. Trees were never the bottleneck when the task was trivial; they are the bottleneck now.

### 7. Work order

1. ~~Fix the battery injector target~~ — **done** (`_pick_battery_target`), it was the blocker.
2. **Calibration probe** (§4) — `DS_SHRINK` × `DS_BSOC`, NOOP-only. Cheap. Decides 3-way vs 2-way.
3. Generator knobs: `DS_BSOC`, `DS_FAULT_TARGET`, `DS_SPARES=0,…`, `DS_ZONE_TARGET`.
4. Full graded dataset (all kinds, all severities, ≥ 4 seeds).
5. `--cost-aware` scoring in `e1_analyze.py` / `e1_frontier.py` + the `always_per_kind` baseline +
   the §5 difficulty audit printed before any fit.
6. Re-run E1/E2 on the graded dataset; re-run E3/E4 (the drift story only gets sharper when the
   post-drift regime differs in *severity*, not just in kind).
