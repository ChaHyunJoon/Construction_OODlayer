# DUMP_SCHEMA — frozen 2026-07-30

The record `gen_oracle_dataset.jl` writes per `(instance, macro)`. Frozen **before** the 30-seed
held-out set is generated, so that set is produced once, by this schema.

Freezing rule: **record raw measured quantities, derive nothing that a later analysis could want
differently.** Tonight's first result is the reason — see §0.

---

## 0. Why this freeze is not cosmetic

`classify_report.py` found that the deployed novelty score **inverts on the battery fold**
(AUROC 0.078: novel battery events look *more* familiar than known ones). The leading hypothesis
is descriptor-side: `harm = 1 − soc` lands mid-range for battery while fault/zoneblk drive the band
with extreme `agent_pending` / `zone_overlap`.

If that is right, the fix is to redefine the descriptors — and **redefining descriptors on stored
data is only possible if the raw inputs were stored.** Today the dump keeps `soc`, `agent_pending`,
`zone_overlap` (good) but not the fleet-level denominators that make them comparable. So §2 exists.

---

## 1. Existing columns — keep, unchanged

Renaming any of these breaks `features_agnostic.descriptors_from_row`, `e1_analyze.featurize`,
the Julia labeller shim, and every stored calibration.

| group | columns |
|---|---|
| identity | `instance`, `kind`, `variant`, `severity`, `seed`, `n_spare_cfg` |
| action | `macro`, `macro_name`, `valid_mask`, `fired` |
| outcome | `complete`, `closed`, `total`, `makespan`, `label_seconds` |
| control arm | `ctrl_complete`, `ctrl_closed`, `ctrl_makespan` |
| state at fire | `closed_at_fire`, `total_nodes`, `progress`, `n_active`, `agent_pending`, `soc`, `zone_overlap`, `zone_radius`, `spare_count` |
| battery | `min_soc`, `n_stalled` |

---

## 2. NEW — system performance metrics

All of these are **already computed** in `ConstructionBots.jl/src/navigator/metrics.jl` (`RunMetrics`).
The gap is purely that the dump seam does not carry them. This is wiring, not new measurement.

| column | source field | why |
|---|---|---|
| `energy` | `RunMetrics.energy` | total actuation energy [J]. The advisor asked for energy efficiency; there is currently **no energy column at all** |
| `energy_per_part` | `energy / placed_parts` | comparable across builds of different size |
| `completion_rate` | `completion_rate` | placed/total; finer than the boolean `complete` |
| `robot_utilization` | `robot_utilization` | idle time is part of "efficient" |
| `soc_spread` | `soc_spread` | max−min SoC = wear levelling |
| `soc_mean_end` | derived | with `min_soc`, gives depletion shape rather than only the worst robot |
| `handling_distance` | `handling_distance` | transport cost |
| `recovery_rate` | `recovery_rate` | fraction of OOD events survived without permanent stall |
| `reaction_latency` | `reaction_latency` | steps from fire → first admitted adaptation |
| `time_to_recover` | `time_to_recover` | steps from fire → progress resumes |

Reporting convention (advisor feedback, 2026-07-29): **mean ± standard error over seeds**, paired
within seed when comparing methods. `classify_report.py` already reports in that form.

---

## 3. NEW — raw denominators, so descriptors stay re-derivable

This is §0's consequence. Store the quantities the six descriptors are built *from*, not only the
descriptors.

| column | why |
|---|---|
| `n_robots_total` | fleet size. `slack` currently divides by a hard-coded `FLEET_REF = 30.0` |
| `pending_at_fire` | `total_nodes − closed_at_fire`, stored explicitly rather than recomputed |
| `agent_pending_mean` | mean pending per active robot — the denominator `descriptor_ablation.py`'s "fixed" variant needs |
| `soc_all` | per-robot SoC vector at fire, not just the affected robot's |
| `spare_reserved` | spares already promised to a pending Replace (the phantom-double-book quantity) |
| `zone_active_count` | number of simultaneously active no-go zones |

With these, a new descriptor definition can be evaluated on the **existing** 300 rows and on the
30-seed set without regenerating either.

---

## 4. NEW — failure signature inputs (F1–F7)

`DESIGN_CLASSIFIER.md` §5 defines known-disturbance as band membership **plus** a failure
signature. Most signatures are already derivable; these close the gaps.

| column | closes |
|---|---|
| `stall_reason` | F2 vs F7 — enum: `none, soc_zero, blocked, deadlock, timeout` |
| `verifier_admitted`, `verifier_feasible` | F5 verifier escape |
| `spare_assignments` | F6 double-book (list of `(spare_id, assignee)`) |
| `cycle_detected` | F4 precedence deadlock |

---

## 5. NEW — the nominal arm

| column | value |
|---|---|
| `kind` | gains the value **`"none"`** |
| `fired` | `false` for nominal rows |
| `macro` | `0` (NOOP) only — a nominal run has no adaptation to choose |

`load_df()` filters `fired == True`, so nominal rows are invisible to every existing analysis by
construction. That is deliberate: nothing that reads the dataset today changes behaviour, and
`M_nominal` opts in explicitly.

---

## 6. Per-step stream — referenced, not duplicated

Anticipatory scoring (`DESIGN_CLASSIFIER.md` §4.2, row 3) needs per-timestep progress, which lives
in `ConstructionBots.jl/tools/monitor/streams/*.jsonl`, not here. The dump carries a pointer only:

| column | why |
|---|---|
| `stream_path` | monitor JSONL for this run, relative to repo root |
| `stream_frames` | frame count, so a truncated stream is detectable without opening it |

Do **not** inline per-step data into the dump — it would multiply row size by the horizon for a
feature that is explicitly out of scope tonight.

---

## 7. Compatibility

- Additive only. Every new column is optional; readers use `row.get(col, default)`.
- Old files stay loadable. `graded_hs_*` predate this and must keep working — they are pinned
  legacy datasets in `wm_datasets.py`.
- The calibration blob's `dataset_fingerprint` changes when the dataset is regenerated, and
  `load_novelty_detector` rejects a mismatched calibration, so a stale band cannot survive a
  schema change silently.

## 8. Order of operations

1. Freeze this document ✅
2. Implement §2 + §3 + §5 in `gen_oracle_dataset.jl`
3. Throughput probe — one instance, measured wall clock
4. Generate the 30-seed **held-out** set, once, with the frozen schema
5. Only then look at it
