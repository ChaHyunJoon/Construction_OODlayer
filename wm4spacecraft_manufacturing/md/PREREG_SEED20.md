# PREREG — 20-seed verification of artifacts_4pol/REPORT.md

Frozen before any 20-seed data was collected. Commit hash of freeze recorded in
`baseline_n5/PROVENANCE.txt`. Deviations from this document must be recorded in
a "Deviations" section appended at analysis time, never by silent edit.

## 1. Design

- ood_seed = 1..20; world_seed = 1 (fixed, layout generalization NOT claimed)
- cases (7): battery, fault, all, fault_battery, fault_zone, battery_zone, zone
  (zonecore dropped: run_demo.jl:433 rewrites :zonecore -> :zone under
   DEMO_OOD_STREAM3=1, so it duplicates `zone`)
- policies (3): noop, surrogate, dspy
- 420 boards, strictly sequential

## 2. Endpoints

E1 (PRIMARY) completion rate  -- paired sign test on (case, ood_seed), ties dropped
E2 decision fidelity vs a*    -- cluster bootstrap over boards, 10000 reps, seed 0
E3 energy J/closed            -- paired Wilcoxon signed-rank
E4 build time (complete only) -- paired Wilcoxon; SELECTION-BIASED, caveat mandatory

## 3. Multiplicity

21 tests per family (7 cases x 3 policy pairs). Holm-Bonferroni WITHIN each
endpoint family. alpha = 0.05. Families are not pooled.

## 4. Known degeneracy (declared in advance, not discovered after)

Where every policy completes every board, E1 is all-ties and the sign test
returns p=1.000 by construction. At n=5 this already occurred in `battery`
(surrogate vs dspy: 0W 0L 5T). Additional seeds CANNOT resolve a ceiling
effect. Such cells will be reported as "ceiling (all ties)", never as
"no significant difference".

## 5. Stability criteria -- how we judge the n=5 report

Fixed before data. Two rules, because two kinds of metric.

Proportions (`success`/`success_ci`, `decision_rate`/`decision_ci`):
  REPRODUCED   -- n=20 point estimate within the n=5 95% CI, AND same direction
  ATTENUATED   -- same direction, point estimate outside the n=5 CI
  REVERSED     -- direction flips (crosses 0.5)

Continuous (`energy_per_closed`, `sim_seconds_complete`) -- no CI is emitted for
these, so containment is unavailable. Judged on relative change, tolerance fixed
here in advance at REL_TOL = 0.20:
  REPRODUCED   -- |new - old| / |old| <= 0.20
  ATTENUATED   -- otherwise
  (REVERSED is not defined for these -- "direction relative to 0.5" is meaningless
   for a quantity measured in joules or seconds.)

Applied to test outcomes rather than point estimates:
  NOW-RESOLVED -- was non-significant at n=5, significant (Holm-adj) at n=20
  UNRESOLVED   -- non-significant at both
  NEW          -- no comparable n=5 estimate exists

## 6. Specific n=5 claims under test

C1 `dspy` battery decision fidelity = 100% (20/20)
C2 `surrogate` battery decision fidelity = 0% (0/20)
C3 `dspy` zone decision fidelity = 65% (13/20) vs `surrogate` 100% (19/19)
C4 `noop` fails to complete fault/zone/all (0/5)
C5 `dspy` beats `surrogate` on J/closed in battery_zone (399 vs 720)
C6 shadow: llm 84.4% > surrogate 70.6% > rule 26.2% (N=435)
C7 B1 kind->macro lookup scores 100% (435/435) -- the caveat that makes C6 weak

## 7. What this experiment does NOT establish

- Layout generalization (world_seed fixed at 1)
- Anything about root-covered zones: REPORT §3-B shows reference_policy.py's
  zone rule is wrong for `cov`-family events, and all 193 swept zone events had
  root_covered==0. This sweep does not widen that coverage, so the defect
  remains latent and unmeasured.
- Any causal claim about WHY a policy wins.
