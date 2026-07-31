# DESIGN_CLASSIFIER — success / known-disturbance / OOD, in our coordinates

Status: design frozen 2026-07-30. Implemented by `scores.py`, `calibrate.py`, `classify_report.py`.
Reference: Ho et al., *World Model Failure Classification and Anomaly Detection for Autonomous
Inspection*, arXiv:2602.16182 (hereafter **the paper**).

---

## 0. What we are building, in one paragraph

At the moment an out-of-distribution event fires in the build simulation, the system must decide
**who answers it**: the surrogate (0.11 ms, knows the disturbance kinds it was trained on) or the
DSPy LLM (~1.5 s, can interpret something it has never seen). That decision is a *classification*
— is this event familiar or not — and today it is made by a single threshold on a single score.
The paper shows a better shape: **two decision functions, calibrated independently by conformal
prediction, whose agreement pattern yields three classes**. This document maps that shape onto our
simulator, fixes the sign convention, defines the classes operationally, and — most importantly —
settles which score function `ℓ` each decision point is allowed to use.

---

## 1. Mapping the paper onto this repo

| paper | ours |
|---|---|
| world model backbone (Cosmos tokenizer + latent WM) | the build **simulation** + the surrogate `Q̂(s,a)` |
| observation `O(s_t)`, video frames | 6 kind-agnostic state descriptors + the per-step monitor stream |
| `M_success` trained on successful videos | `M_nominal` trained on **undisturbed** runs |
| `M_fail` trained on failure videos | `M_disturb` trained on the **3 known disturbance kinds** |
| CP threshold `η_s`, `η_f` | CP quantile on each model's score set |
| success / known failure / anomaly | **nominal / known-disturbance / OOD** |
| corrective action per class | NOOP / surrogate-chosen macro / DSPy LLM re-spec |
| (paper: future work) adaptive recalibration | **already built** — `assimilation_stream.py` C4 + `refresh_gate` |

Two deliberate differences, to be stated plainly in any writeup:

- **Ours is not perception.** The paper classifies whether a camera reading is trustworthy. We
  classify whether a *decision problem* is one the surrogate has seen. Their output feeds a
  re-inspection; ours feeds a re-specification of the build plan.
- **Ours is real-time in simulation, not on hardware.** `route(env, truth)` in
  `ConstructionBots.jl/tools/monitor/policy.jl` runs inside the sim loop on the live `env`. The
  dashboard is a replay of the emitted JSONL — that is *display*, not the classifier. We must not
  claim hardware deployment.

---

## 2. Why two decision functions, not one

A single "is this familiar?" score gives two classes. The paper's third class is free **only
because we already own the second model**: the original SISL repo is the undisturbed build.
That is `M_nominal`. This is exactly why the missing `kind="none"` rows in the dataset matter —
they are not a missing baseline, they are **a missing decision function**.

Paper's Eq. (1)/(3), rewritten in our terms:

```
D_nominal(x) = 1  ⟺  ℓ_nominal(x) > η_nominal      "does not look like an undisturbed build"
D_disturb(x) = 1  ⟺  ℓ_disturb(x) > η_disturb      "does not look like a known disturbance"

D_nominal = 0 ∧ D_disturb = 1   →  nominal              (no intervention needed)
D_nominal = 1 ∧ D_disturb = 0   →  known disturbance    (surrogate picks the macro)
D_nominal = 1 ∧ D_disturb = 1   →  OOD                  (DSPy LLM interprets)
D_nominal = 0 ∧ D_disturb = 0   →  ambiguous            (see §5)
```

The paper does not name the fourth cell (both inside). We must, because ours can occur: an event
that looks both like a healthy build and like a known disturbance is a *low-severity* event, and
the honest answer is NOOP with a logged flag, not silence.

---

## 3. Sign convention — read this before touching any code

The two codebases disagree and it will cause a bug otherwise.

| | convention | "this is OOD" means |
|---|---|---|
| the paper | `ℓ > η` | score **above** threshold |
| our existing gate (`conformal_p`) | `p < α` | p-value **below** alpha |

They are equivalent (`p` is the upper-tail mass of `ℓ`), but they point opposite ways. Rule for
this repo:

> **Every score function reports `higher_is_ood: bool` as part of its metadata, and `scores.py`
> normalises internally so that the calibration layer only ever sees "higher = more novel".**

`decision_margin` and `Q̂` are the traps: for those, *lower* means more suspicious.

---

## 4. The score `ℓ` — what each decision point is allowed to use

This is the core design decision and it was settled by evidence already in the repo.

### 4.1 Can `ℓ` just be the state–action value `Q̂(s,a)`?

Three forms, three different answers.

**(a) `Q̂` itself — no, structurally.** A RandomForest prediction is a mean of leaf values, so it is
**bounded by the training target range**. A never-before-seen input cannot produce an extreme
score, and CP thresholding is entirely about extremeness. Measured consequence already in the
repo: the `gate=disagreement` arm (tree variance, the natural "confidence" reading of the forest)
achieved **recall 0.00** on a novel kind. The forest is not uncertain on novel input — it is
*confidently wrong*.

**(b) The residual `|Q̂ − y_realized|` alone — no, measured.** This was tried and it failed.
`md/FINDINGS_ADWIN.md` concludes verbatim that *"현재 E3/E4가 쓰는 value-residual은 이 과제의
drift 신호가 아니다"*:

| detector / signal | fires | spurious |
|---|---|---|
| CUSUM / **value-residual** | 4 | **3** |
| CUSUM / value-residual (long stream) | 8.6 | **7.8** |
| CUSUM / covariate novelty | 2 | **0** |

Cause: residual magnitude is dominated by **scenario difficulty**, not by novelty. The residual was
already large before any drift, so the threshold fired from `t=0`.

**(c) The residual *contrast* between two models — yes, and this is the paper's actual mechanism.**
The paper never uses a raw prediction error either. It scores the *same* sample under two models
and reads the pattern. The contrast cancels the scenario-difficulty term that killed (b):

```
ℓ_nominal(x) = |Q̂_nominal(s,a) − y| / span(scenario)
ℓ_disturb(x) = |Q̂_disturb(s,a) − y| / span(scenario)
```

Per-scenario normalisation by `span` is not optional — it is the second half of the fix, and it is
the same normalisation `verify.norm_regret` already applies.

### 4.2 The timing table — which score is legal when

`y_realized` does not exist until the run ends. That single fact partitions the design:

| decision point | information available | admissible `ℓ` | status |
|---|---|---|---|
| **event fires** (routing) | `s`, `a` only | distance-based only — Mahalanobis, z-RMS | **`Q̂` is inadmissible** |
| **run ends** (calibration / assimilation) | `s`, `a`, `y` | **residual contrast (c)** | new tonight |
| **每 step** (anticipatory) | partial progress trajectory | residual of a *progress* prediction | future work |

The third row is where the paper's headline lives. Its best metric — latent prediction error, 91%
across three classes, classifying 1–3 s **earlier than a human observer** — is a per-timestep
prediction residual. We cannot claim "anticipatory" until we score per step. The monitor stream
(`tools/monitor/streams/`, per-step JSONL) is the raw material; the scoring interface below leaves
the slot open, and this is explicitly *not* implemented tonight.

### 4.3 The score menu (paper Table I, translated)

| # | score | type | our status |
|---|---|---|---|
| S1 | `z_rms` — clipped per-feature z, RMS | distance (diagonal cov) | **deployed today**; = paper's "Latent L2 distance" |
| S2 | `mahalanobis` — full covariance | distance | **new**; paper's best OOD metric (100%) |
| S3 | `tree_variance` — forest member spread | ensemble | measured, recall 0.00 |
| S4 | `residual_contrast` — §4.1(c) | residual | **new**; post-hoc only |
| S5 | `train_loss` — in-sample residual | miscellaneous | paper's control arm |
| S6 | `decision_margin` — `Q̂(1st) − Q̂(2nd)` | probability-based | already in `novelty.jl` |

The paper warns Mahalanobis overfits its calibration set in high dimension (covariance inversion
instability). Our descriptor space is **6-dimensional**, so the inversion is well-conditioned —
their failure mode is unlikely to be ours, which makes S2 the highest-value cheap experiment.

---

## 5. Class definitions, operationally

`kind` (`battery` / `fault` / `zoneblk`) is a **cause** label, not an outcome label. The paper's
"known failure" is an outcome. Do not conflate them.

**Known disturbance** = the event is inside the calibration band **and** its outcome matches one of
the declared failure signatures below. All seven are computable from existing dump columns:

| id | signature | rule |
|---|---|---|
| F1 | spare exhausted | Replace requested with `spare_count == 0` |
| F2 | energy stall | `min_soc ≤ 0` and `n_stalled > 0` |
| F3 | zone wedge | `closed` frozen while `zone_overlap` high |
| F4 | precedence deadlock | cyclic `OpenBuildStep` |
| F5 | verifier escape | admitted but infeasible |
| F6 | phantom spare double-book | same spare assigned twice |
| F7 | no-progress timeout | horizon exhausted, `closed < total` |

**Complete OOD** = outside the band **and** matching no `F_i`.

**The two contradictory cells are the interesting ones** and must be logged, never silently
bucketed: inside-band-but-no-signature (a new benign mode) and outside-band-but-signature-matched
(a known failure reached by a novel route). These are how the taxonomy grows.

---

## 6. Calibration and assimilation (paper Fig. 5 → our loop)

The paper calibrates once and lists adaptive recalibration as future work. Ours already closes:

```
OOD detected → DSPy LLM proposes → verifier admits → enacted → oracle labels the event
             → event enters the training pool → surrogate refits → band refits (refresh_gate)
             → the same kind is "known" next time
```

`refresh_gate` is load-bearing: without it the gate keeps flagging an assimilated kind forever and
C4 cannot be demonstrated. Calibration artifacts carry `format_version`, `descriptor_fingerprint`
and `dataset_fingerprint`; `load_novelty_detector` throws `CalibrationError` on mismatch rather
than scoring against a distribution that no longer exists (2026-07-30).

---

## 7. Evaluation tonight, and its honest limit

The dataset has **no `kind="none"` rows**, so `M_nominal` cannot be fitted yet and the 3-class
table is not producible tonight. Tonight's stand-in:

- **Protocol**: leave-one-kind-out. Hold out one of {battery, fault, zoneblk}; calibrate on the
  other two; the held-out kind plays the role of OOD.
- **Output**: 2-class (known-disturbance vs OOD) accuracy per score × quantile {90, 95, 100},
  laid out like the paper's Table II, plus overlaid score histograms with the threshold drawn
  (their Fig. 6).
- **Not claimed**: 3-class accuracy, detection lead time, anticipatory behaviour.

`n = 60` instances over 6 seeds. The 30-seed set is a **held-out robustness test** and is
deliberately generated *after* this design is frozen — generating it now would both invalidate it
as held-out and guarantee regeneration when the dump schema changes (§ dump schema freeze).

---

## 7a. FIRST RESULT (2026-07-30) — the deployed gate has a blind fold

`classify_report.py --repeats=40`, artifacts in `artifacts_classifier/`. Averaged over folds the
table looks unremarkable; **split by held-out kind it is not**:

| score | battery held out | fault held out | zoneblk held out | mean AUROC |
|---|---|---|---|---|
| `z_rms` (deployed) | **0.078** / 0% recall | 0.878 / 57% | 0.974 / 95% | 0.643 |
| `mahalanobis` | 0.252 / 1% | 0.878 / 69% | 0.986 / 95% | **0.705** |
| `tree_variance` | 0.785 / 32% | 0.658 / 16% | 0.379 / 8% | 0.607 |
| `residual_contrast` | 0.744 / 41% | 0.734 / 32% | 0.699 / 67% | **0.726** |
| `train_loss` | 0.534 / 28% | 0.514 / 33% | 0.885 / 70% | 0.644 |
| `decision_margin` | 0.203 / 0% | 0.199 / 0% | 0.837 / 42% | 0.413 |

Four things follow, and they change what we should build next.

**(1) The "recall 0.94" headline is the zoneblk fold.** The deployed calibration is generated with
`--exclude=zoneblk`, so the published number describes exactly the fold where the score works
(0.974 AUROC / 95% recall). It is not wrong; it is not representative. The fold average is ~50%.

**(2) On battery, the deployed score is not weak — it is inverted.** AUROC 0.078 means held-out
battery events score *systematically lower* (= more familiar) than known events. A novel battery
disturbance would be routed to the surrogate with confidence, every time. This is the
"confidently wrong" failure of §4.1(a) showing up in the distance score too, and it is a live
defect in what is deployed today.

**(3) `decision_margin` at 0.413 quantifies the same thing.** Below 0.5 means anti-correlated:
novel events produce *larger* decision margins than familiar ones. Forest confidence is not just
uninformative here, it points the wrong way.

**(4) No single score covers the space, but the failures are complementary.** `z_rms` /
`mahalanobis` own zoneblk and fault and collapse on battery; `tree_variance` is the only
routing-admissible score that works *on* battery (0.785) and it collapses on zoneblk (0.379).
`residual_contrast` is the only score that never collapses — 0.699–0.744 across all three — which
is the two-model-contrast argument of §4.1(c) behaving exactly as predicted, though it stays
post-hoc.

**Consequences for the plan.** A single-score gate is the wrong target; the next experiment is a
*combination* over routing-admissible scores (at minimum `mahalanobis` ∨ `tree_variance`), and the
combination must be evaluated per fold, never on the fold mean. Reporting any gate number without
its per-kind breakdown is how (1) happened.

### 7b. Why battery inverts — tested, and it is not a tuning problem

Checked without any train/cal/test split (fit on the two known kinds, score the held-out one):

| held out | trained-on median | held-out median | AUROC |
|---|---|---|---|
| battery | 0.803 | **0.527** | **0.049** |
| fault | 0.575 | 1.133 | 0.903 |
| zoneblk | 0.638 | 3.472 | 1.000 |

So the inversion is a property of the data, not of the harness. The descriptor medians say why:

| kind | harm | work_at_risk | resource_loss |
|---|---|---|---|
| fault | 1.000 | 0.271 | 1.000 |
| zoneblk | 0.374 | 0.374 | 0.000 |
| **battery** | **0.840** | 0.431 | **0.840** |

Fault and zoneblk sit at **opposite extremes** of `harm` and `resource_loss`. Battery sits
*between* them. Train on {fault, zoneblk} and battery lands essentially on the centroid of the
calibration set — so it scores as *more typical than typical*.

**The general statement: a distance-based novelty score can only detect extrapolative novelty.**
Held-out zoneblk is outside the training hull → AUROC 1.000. Held-out fault likewise → 0.903.
Held-out battery is an **interpolant** → 0.049. No distance metric fixes this: full-covariance
Mahalanobis only moves battery from 0.049 to 0.272, because the problem is not the shape of the
metric, it is that the point is genuinely in the middle.

**Consequence.** Interpolative novelty needs a signal that can be large in the *interior* of the
input distribution — i.e. a **model-residual** signal, which is exactly why `residual_contrast`
reaches 0.744 on the battery fold where every distance score collapses. This reframes the score
menu: distance and residual are not competing options to be ranked, they cover **different kinds of
novelty**, and a deployable gate needs both. The residual half needs an outcome, so making it work
at routing time is precisely the per-step scoring reserved in §4.2 — which is now the highest-value
next build, not an optional extra.

---

### 7c. The combined gate — measured, and the correction matters

`classify_report.py` now evaluates OR-combinations of the **routing-admissible** scores
(`residual_contrast` is excluded: it needs the outcome). OOD recall @95%, per held-out kind:

| arm | battery | fault | zoneblk | known-acc |
|---|---|---|---|---|
| `mahalanobis` alone | **1%** | 70% | 100% | 90.6% |
| **`mahalanobis` ∨ `tree_variance`** | **29%** | 72% | 100% | 84.3% |
| `z_rms` ∨ `tree_variance` | 29% | 54% | 98% | 85.1% |
| `mahalanobis` ∨ `tree_variance`, *no correction* | 31% | 72% | 100% | 83.4% |

**The complementarity thesis holds**: combining lifts battery from 1% → 29% without losing
anything on the other folds. This is the first arm that is not blind on any kind.

**The Bonferroni correction is doing real work.** OR-ing N bands at quantile q inflates the
false-alarm rate roughly N-fold, so `CombinedGate` tightens each band to `1 − α/N`. Dropping it
(last row) buys +2 points of recall and pays 0.9 points of known-accuracy — i.e. part of any
"combination wins" effect is just a looser threshold. Any future combination result must be
reported with the correction on, or it is not a comparison.

**29% is still not deployable.** Distance and ensemble scores together cannot close the
interpolative gap; only the residual family reaches 0.744 there, and it needs the outcome. This is
the concrete argument for per-step residual scoring, not a preference.

---

### 7d. FIRST THREE-CLASS RESULT (2026-07-30, after the nominal arm landed)

60 nominal instances generated (control-run-only pass, 22 min wall clock), merged 1:1 onto the
base 300 rows → `oracle/out/openworld_nominal.jsonl`, 360 rows. `classify3_report.py --repeats=30`.

Best score (`z_rms`) @95%, confusion (rows = truth):

| truth ↓ / predicted → | nominal | known-disturbance | OOD | ambiguous |
|---|---|---|---|---|
| **nominal** | **50.7%** | 0.0% | 4.3% | **44.9%** |
| **known-disturbance** | 3.4% | **81.2%** | 7.0% | 8.4% |
| **OOD** | 12.7% | **54.2%** | **32.5%** | 0.7% |

Per-class accuracy @95%:

| score | nominal | known | OOD | overall |
|---|---|---|---|---|
| `z_rms` | 50.7% | 80.8% | 36.1% | **52.4%** |
| `mahalanobis` | 43.5% | 79.4% | 38.7% | 50.2% |
| `residual_contrast` (real nominal reference) | 21.0% | 68.3% | 21.3% | 33.4% |
| `train_loss` | 0.0% | 87.2% | 43.4% | 39.4% |
| `tree_variance` | 1.2% | 2.4% | 0.6% | 1.2% |
| `decision_margin` | — | — | — | **excluded, undefined** |

**Four things this says.**

1. **The structure works, one axis does not.** Known-disturbance is identified 81% of the time and
   nominal is never mistaken for a disturbance (0.0%). The weak axis is OOD: 32.5% correct with
   **54.2% of OOD read as a known disturbance** — the interpolative failure of §7b, now visible as
   a specific cell rather than an AUROC.

2. **`ambiguous` is not a rounding error — it absorbs 44.9% of nominal.** Those instances fall
   *inside both* bands. Folding that cell into a neighbour, as a 3-way forced choice would, would
   have reported nominal accuracy near 95% by hiding the indecision. It is reported.

3. **The two-model residual contrast, finally given its real reference, does not win.** 33.4%
   overall vs 52.4% for a plain distance score. Note the comparison is not clean: here it also
   runs at `row_scope="noop"` (§ below) while the 2-class figure used all five macro rows, so the
   0.726 AUROC and this number measure different things. What can be said is narrow and worth
   saying: *having* the nominal model did not by itself rescue the residual family.

4. **We are far from the paper's >90% on all three classes.** Their setting is perception with a
   video world model; ours is a decision problem over 6 descriptors. The gap is not explained away
   by that, and should be quoted as-is.

**A confound found and removed on the way.** A nominal instance has **1 row** (NOOP only); a
disturbed instance has **5**. Every row-aggregated score was therefore comparing max-of-1 against
max-of-5 — a difference driven by sample count, not novelty. Measured before the fix: every
nominal instance received an *identical* value under `tree_variance` (0.0000) and
`decision_margin` (−1.0000), so those bands were degenerate and their "0.0% accuracy" was an
artifact, not a measurement. Scores now take `row_scope="noop"` in the 3-class harness (the one
row every instance has), and `decision_margin` — which needs a 1st and a 2nd candidate — returns
`NaN` and is excluded rather than silently returning a constant. The 2-class numbers are unchanged
(`row_scope="all"` remains the default, and there every instance has 5 rows).

---

## 8. Decisions recorded

1. Two decision functions, not one — the second is free because the original repo is the nominal build.
2. Routing uses distance scores; `Q̂` enters only after the run ends, and only as a two-model contrast.
3. Every score declares `higher_is_ood`; the calibration layer sees one convention.
4. `kind` ≠ failure mode. Known-disturbance requires band membership **and** an `F_i` signature.
5. Mahalanobis is tested because our 6-d space avoids the paper's instability, not because it won for them.
6. Per-step anticipatory scoring is scoped out tonight; the interface reserves the slot.
