# Zone-repair base ablation — G5, three arms (none · A1 translate · A2 all), 2026-09-23/24

> **A2 는 23:4x 보류 → 사용자 결정으로 재개(STOP.held-2026-09-23 보존), 서비스 abl-svc-all 을 사용자 승인으로 재기동(같은 지문).**
> - 23:32: the driver finished none and A1, then did not start A2 because a `STOP` file said "User requested holding A2/all".
> - 23:44: with user approval, the controller restarted `abl-svc-all` on 8113 (same `code_fingerprint 5894a2ce8a532bd8`, same `ledger_all.jsonl`, appending) and moved `STOP` → `STOP.held-2026-09-23`. It then ran `run_g5_all.sh`, a one-arm copy of `run_g5.sh`, from 23:44:38 to 01:52:29.
> - The A2 grid merged with the G4 pilot (config `1222b1ee8525025a`).

Scope: 존 복구 base 제거; CARRIER_RESCUE·스냅·reform 은 세 팔 공통.

## Allowed claim (spec §9) — one row
> **"A2 ≪ none, 오라클은 완주 | base 가 성과의 원천이다; LLM 은 base 를 고르는 데 강하다"**

Evidence:
- **Completion:** none 115/120, A2 18/116. Same-seed pairs: 93 where only none completed, 0 where only A2 completed; exact McNemar p = 2.0e-28.
- **Oracle:** the G3 oracle uses only A2 vocabulary and completed 106/120. On those feasible seeds, A2 completes **17/102** (4 of the 106 feasible seeds are A2 timeouts), against none 102/106.
- **Checks:** denied = 0 and identity failures = 0 on all 354 scored runs.
- A1 behaves the same way: 14/118, with 99 pairs where only none completed and 0 where only A1 completed, p = 3.2e-30. So the §9 row "A1 ≈ none, A2 ≪ none" does not hold: removing the translation base alone already costs almost all of the completions.
- **Ladder-skip robustness:** in each ablation arm, 13 runs skipped the replace-robot zone ladder, and all 13 were incomplete. Even if every one of those runs is counted as complete, A2 is at most 31/116. So the ladder skip does not change which row of the table applies.
- **Provider overload (final-review I1):** 3 of the A2 runs counted above (X-wing all3 s10, s11, s22) failed from a live provider outage on compose, not from the arm — see "Provider overload" under Results. Excluding them: A2 **18/113**, none vs A2 **91/0**, p = 8.1e-28, oracle-feasible A2 **17/100**. The conclusion (A2 ≪ none) is unchanged; both the headline and the corrected figures are reported below.

## Setup
- **Code:** HEAD `13d18a19`, tree clean in `src/` and `tools/` for the whole run. Campaign `code_dirty_digest 1e5442d8117b721b` (includes untracked files that were already present).
- **Services:** the command lines are under "Services" in the G4 section below; the key comes from the environment. `gpt-5.6-sol` (responses), cache off, `TOOL_SYNTHESIS=1 SYNTH_MULTI_AGENT=1`, `code_fingerprint 5894a2ce8a532bd8`.
  - none and translate were stopped at 23:3x.
  - all was restarted at 23:44 and stopped after the run.
  - `/health` after the run (`health_<lvl>.post.json`): none calls/billed 120/120, translate 120/120, all 116/116 (counted after the restart; the 4 pilot calls came before it). `ledger_append_failures 0` on each.
- **Drivers:** `run_g5.sh` (none → translate) and `run_g5_all.sh` (all). Within an arm, tractor and X-wing run concurrently at W=8 each.
- **Watchdog:** `cost_watchdog.sh` (cap $150 across the three ledgers) never triggered.

| grid | campaign | config_digest | planned | scored |
|---|---|---|---|---|
| none-tractor | abl-none-tractor-20260923 | 78d684a66eefbb3a | 60 | 60 (4 G4 pilot) |
| none-xwing | abl-none-xwing-20260923 | 78d684a66eefbb3a | 60 | 60 |
| translate-tractor | abl-translate-tractor-20260923 | da5094f5d8e98f6c | 60 | 60 (4 pilot) |
| translate-xwing | abl-translate-xwing-20260923 | da5094f5d8e98f6c | 60 | 58 (2 timeout) |
| all-tractor | abl-all-tractor-20260923 | 1222b1ee8525025a | 60 | 58 (4 pilot; 2 timeout) |
| all-xwing | abl-all-xwing-20260923 | 1222b1ee8525025a | 60 | 58 (2 timeout) |

## Results (`compare3.py` → `compare3.json`)
The table counts complete runs out of scored runs that passed the identity checks with denied = 0.

| cell | none | A1 translate | A2 all | none vs A1: none-only / A1-only, p | none vs A2: none-only / A2-only, p | oracle-feasible seeds (none · A1 · A2) |
|---|---|---|---|---|---|---|
| tractor zone | 28/30 | 3/30 | 5/30 | 25/0, 6.0e-8 | 23/0, 2.4e-7 | 27: 25 · 3 · 5/27 |
| tractor all3 | 30/30 | 3/30 | 4/28 | 27/0, 1.5e-8 | 24/0, 1.2e-7 | 27: 27 · 3 · 3/25 |
| X-wing zone | 29/30 | 4/29 | 5/29 | 24/0, 1.2e-7 | 23/0, 2.4e-7 | 26: 25 · 4 · 5/25 |
| X-wing all3 | 28/30 | 4/29 | 4/29 | 23/0, 2.4e-7 | 23/0, 2.4e-7 | 26: 25 · 4 · 4/25 |
| **total** | **115/120** | **14/118** | **18/116** | **99/0, 3.2e-30** | **93/0, 2.0e-28** | 106: 102 · 14 · **17/102** |

- **Provider overload (I1):** the headline A2 figures above (18/116, 93/0, 17/102) include 3 runs that did not fail from the arm. `ledger_all.jsonl` shows the compose call for X-wing all3 s10, s11 and s22 returning `error = "compose: LMServerError … ServiceUnavailableError … servers are currently overloaded"` (`decide_outcome=synthesis_failed`, no body), logged 06:56–07:08Z = 23:56–00:08 local — 0 such errors occur in none or A1. This is the time-of-day confound (below) actually materializing, not an ablation effect. Of the discordant none-vs-A2 pairs, s10 and s22 are none-only; s11 and s22 are also oracle-feasible seeds.
  - **Excluding these 3 (labelled, not replacing the headline):** A2 **18/113**, none vs A2 **91/0**, p = 8.1e-28; oracle-feasible A2 **17/100**. A2 ≪ none holds either way.
- **Secondary, A1 vs A2:** 0 pairs where only A1 completed, 4 where only A2 completed; p = 0.125 (per cell 0.5, 1, 1, 1). This is **underpowered, not evidence of equivalence** — only 4 discordant pairs exist. Completion is similar, but the failure *mechanisms* differ (see "How A2 fails" below): A1 locks on a restage move with the zone still blocking in all 104 incomplete runs, while A2 clears the zone in 41. That split traces to m4 (A1's advertisement drops the escalation meaning of `:residual_blocked`), not to the two arms being equivalent.
- **Identity (I2), per run, all 354 scored runs:** every run passes all of these:
  - an `[ablation]` line is present (a missing line would count as a failure, not as denied = 0)
  - level = arm
  - armed = true
  - exempt sites ⊆ {policy_payload, reference_label, monitor_record, dp_lane}; seen: monitor_record, policy_payload, reference_label
  - `run_ctx.repair_ablation` = arm
  - `campaign.json set_env.REPAIR_ABLATION` = arm
  - `health_<lvl>.pre.json repair_ablation` = arm

  **Identity failures: 0.** **denied>0: 0.** **zone_place mismatches: 0** (both none vs A1 and none vs A2).
- **Error and timeout runs (6):** every one hit `RUN_TIMEOUT` = 3600 s, with rc=124 and no `[score]` line. The stream is empty because the process was killed.

  | arm | run | rc | elapsed |
  |---|---|---|---|
  | A1 | X-wing `router__all3__s10` | 124 | 3600.7 |
  | A1 | X-wing `router__zone__s24` | 124 | 3600.7 |
  | A2 | tractor `router__all3__s22` | 124 | 3600.7 |
  | A2 | tractor `router__all3__s25` | 124 | 3600.9 |
  | A2 | X-wing `router__all3__s3` | 124 | 3600.8 |
  | A2 | X-wing `router__zone__s15` | 124 | 3600.8 |

  - **These are hangs inside the arm's own rewritten body, not neutral or world-caused stalls (final-review I2).** In every one of the six, the `rewrite` ledger row was logged 35–88 s after `decide`, and the log ends at `[minted] enact_retry: 되먹임 1회` with no subsequent `[minted] lane=present` line — the rewritten LLM body never returned. The failure is caused by the arm.
  - They stay in the planned denominator (60 per grid) but are excluded from the completion and McNemar figures above.
  - **Report /120 as the primary denominator: A1 14/120, A2 18/120** (the headline figures above, 14/118 and 18/116, exclude them). In every one of the 6 pairs none completed, so excluding them only inflates the none-only discordant count — **excluding them flatters both ablation arms.**
- **How A2 fails:** 98 runs are incomplete, and every one ends in `stall`.
  - 57 end with the zone still blocking (n_blocked ≥ 1, project_blocked).
  - **41 end with the zone cleared** (n_blocked = 0, project_blocked = false) and the build stalled anyway. All 41 used a setter (`set_desired_global_transform!`) rather than the base's staging-circle move.
  - **Mechanism (final-review I3): 36 of these 41 never called `resync_scene_to_schedule!`.** G3 had already diagnosed exactly this failure mode (setter without resync → scene drift → stall). So part of what "the base, including the scene resync it performs implicitly," supplies is that resync call, not just the translation itself — the gloss "the world does not recover afterwards" should be read as "because the scene was never resynced." The row still holds even under the most generous counterfactual: if all 36 had completed instead, A2 would be at most **54/116**, still ≪ none.
  - **Compare A1:** all 104 incomplete A1 runs had the zone still blocking (0 cleared it). So while A1 and A2 land at similar completion (§ Secondary above), they fail by different mechanisms — A2 clears the zone and then drifts, A1 never clears it at all. Do not read "A1 ≈ A2" as the arms being interchangeable.
- **Ladder:** zone_rescue was never skipped or fired in any arm. The replace-robot zone ladder was skipped in 0 none runs, 13 A1 runs and 13 A2 runs, and all 26 of those were incomplete. It was never fired.

### Body mechanism (`mechanism()` in compare3.py; `calls_base` split into A1-blocked vs restage-only)
| arm | first-attempt rows | rewrite rows | last body × outcome |
|---|---|---|---|
| none | calls_base:translate 108, restage_only 4, graph_surgery 2, hand_geometry 1, other 1, empty 4 | translate 12, restage_only 2, graph_surgery 2 | translate→complete 108 / incomplete 3; restage_only→incomplete 2; graph_surgery→complete 2; other→complete 1; no body→complete 4 |
| A1 translate | restage_only 109, graph_surgery 6, empty 5 | restage_only 109, graph_surgery 3 | restage_only→complete 3 / incomplete 104; graph_surgery→complete 6; no body→complete 5 |
| **A2 all** | **hand_geometry 73**, other 31, graph_surgery 6, hand_translate 1, empty 9 | hand_geometry 77, other 26, hand_translate 7, graph_surgery 5 | hand_geometry→**complete 10** / incomplete 63; hand_translate→incomplete 7; graph_surgery→**complete 7**; other→complete 1 / incomplete 25; no body→incomplete 3 |

How the A2 bodies worked without the base:
- **Hand-written geometry:** most bodies moved things themselves with `set_desired_global_transform!` without using `staging_circles` (hand_geometry). By last body, 10/73 of those runs completed; by first attempt on scored runs, 9/69 (the raw first-attempt count of 73 also includes the 3 timeout runs, which have no scored outcome). Bodies that did a staging-circle translation by hand (hand_translate) went 0/7.
- **Graph surgery:** 7/7 runs completed. Graph surgery also completed every time it appeared in A1 (6/6) and none (2/2). That is a small n and no causal claim is made.
- **`resync_scene_to_schedule!`** (exposed under D1): only 22 of the 226 A2 bodies call it. On a run's last body, it was used in 2 completed and 14 incomplete runs. The G3 oracle needed that call for its hand translation, and the LLM rarely used it.
- In A1, no body wrote the whole-build move with a setter. 109/120 first attempts fell back to `restage_all_blocked!` and similar calls, which fail with `residual_blocked`. There were 0 `reject:ablated_primitive` lines: the model did not try the removed names.

## Verification
- `verify_retry_chain.py` ran on every planned run, against `ledger_<lvl>.final.jsonl`. Flags: `--require-decisions 1`, `--expect-ctx` (manifest values plus `repair_ablation=<lvl>`) and `--health-json health_<lvl>.post.json`. Results are in `<grid>/verify/`, with exit codes in `verify/exit_codes.txt`.

  | grid | exit 0 | exit 2 |
  |---|---|---|
  | none-tractor | 60/60 | 0 |
  | none-xwing | 60/60 | 0 |
  | translate-tractor | 60/60 | 0 |
  | translate-xwing | 58/60 | 2 |
  | all-tractor | 58/60 | 2 |
  | all-xwing | 58/60 | 2 |

  Every exit-2 run is `input_error: stream is empty` on one of the six timeouts.
- Ledger sha256:
  - none: `5719071c…` (136 rows)
  - translate: `a3a60bc8…` (232 rows)
  - all: `6f3d753b…` (235 rows, pilot included)

## Cost (`../2026-09-23-router-sol/cost.py`, raw_lm usage × $4/M in, $20/M out — an estimate, not the billed total)
Total **$87.43**:
- none: $20.83 ($0.17 per run)
- translate: $27.42 ($0.23 per run)
- all: $39.18 ($0.33 per run, pilot included)

| stage | none calls / $ / share | A1 calls / $ / share | A2 calls / $ / share |
|---|---|---|---|
| observe | 121 / 2.08 / 10% | 120 / 2.06 / 8% | 120 / 2.05 / 5% |
| design | 127 / 4.29 / 21% | 120 / 4.30 / 16% | 172 / 5.49 / 14% |
| compose | 123 / 13.13 / 63% | 115 / 11.54 / 42% | 168 / 21.07 / 54% |
| rewrite | 16 / 1.32 / 6% | 112 / 9.52 / 35% | 115 / 10.57 / 27% |

## Summary of earlier gates
- **G2** (`g2/README.md`), negative control, free: the translate-calling oracle fixture completed under none (287) and was blocked under both translate and all (147) by the **registration** layer (`reject:ablated_primitive`). The execution guard never fired (denied = 0).
- **G3** (`g3/README.md`), A2-vocabulary oracle, 120 runs, free: **106/120 complete** (tractor 27+27, X-wing 26+26), denied>0 = 0. **D1 = expose**: `resync_scene_to_schedule!` is advertised in all three arms.
- **G4** (below): services, handshake negative control, pilot. none 4/4, translate 0/4, all 0/4.

## Notes
- **m4:** A1 drops the whole meaning of the `:residual_blocked` status from the advertisement. In none, that meaning points the model to the escalation into `translate_whole_build!`.
- **m7:** the early return in `recover_stalled_teams!` is symmetric across arms.
- **m8, side report:** the none arm also newly advertises `inplace_breakdown_marks` and `resync_scene_to_schedule!` compared with this morning's 117-run baseline (`../2026-09-23-router-sol`). Together with the §5 common changes and the code cleanup, the new none gives **115/120 vs 117/120**:
  - tractor zone 28 vs 30
  - tractor all3 30 vs 29
  - X-wing zone 29 vs 29
  - X-wing all3 28 vs 29
  - Same-seed pairs: new none-only 1, 9/23-only 3.
  - This is not attributed to any single cause.
- **m-b:** the identity check's `health_ok` for A2 reads `health_all.pre.json`, which came from the pre-restart process. The G4 post snapshot (calls=4) was overwritten by the restart, so this check is not reading the post-restart service's own pre-run snapshot for A2.
- **m-c:** each grid's `campaign.json` shows `pinned.REPAIR_ABLATION = "none"`. That field is `CONFIG_ENV_PINNED_DEFAULTS` (`campaign.py:292`), a defaults list, not the effective value — `set_env` (also in `campaign.json`, and checked above) wins and matches the arm in every grid. The `pinned` field alone would mislead a reader.
- **m-d:** the origin of the 22:49 `STOP` file (renamed to `STOP.held-2026-09-23`) is still unknown. It has no effect on the data: fingerprint and dirty digest are constant across the hold and restart.
- **m-e:** the 6 `RUN_TIMEOUT` runs (I2, above) have no `[ablation]` line at all, so `denied=0` cannot be shown for them the way it is for the 354 scored runs — deferred as T8-M1.
- **Time of day:** the arms ran in sequence (none 21:03–21:45, A1 21:45–23:32, A2 23:44–01:52), so API latency is confounded with arm. Median run times:
  - none: 276 s tractor, 321 s X-wing
  - A1: 325 s tractor, 413 s X-wing
  - A2: 398 s tractor, 502 s X-wing

  This confound materialized twice in A2: the 3 provider-overload failures (I1, above) and, in all three arms, part of the wall time from runs that hang inside the arm's own rewritten body until `RUN_TIMEOUT` (I2, above). The phrase "stalled runs run until they time out" is wrong for those 6 — they are hangs waiting on a rewrite call that never returned, not the `stall` world-state failure mode described under "How A2 fails."
- **Of the 5 incomplete none runs:**
  - 4 had the zone cleared and then stalled: tractor zone s12 (closed 64) and s20 (266), X-wing zone s11 and all3 s11 (455).
  - 1, X-wing all3 s24, still had the zone blocking.

## Files
- Committed: `run_g5.sh`, `run_g5_all.sh`, `cost_watchdog.sh`, `compare3.py`, `g4_check.py`, `README.md`, `compare3.json`, `health_*.json`, `STOP.held-2026-09-23`, and each grid's `campaign.json` / `sweep.json`.
- Kept on disk only: logs, streams, verify output, ledgers.

---


> (이력 — 23:4x 사용자 결정으로 해제됨, 위 G5 머리말 참조) **사용자 지시 — 2026-09-23: A2 (`all`) 본 실험 보류.** `STOP` 파일은 비용 초과가 아니라 사용자 요청으로 생성했다. 현재 A1은 마무리하되 A2를 시작하거나 STOP을 제거하지 않는다. 이후 작업은 A1 실패 분석과 workflow 개선안 검토이며, A2 재개는 사용자의 새 지시가 필요하다.

# Zone-repair base ablation — G4 (services + pilot), 2026-09-23

Code: HEAD `13d18a19` (fix: `dspy_ready()` parses /health once), tree clean (`git status --short -- src tools` = 0).

## Services (tmux, left running for Task 13)
`R=/home/chahj578/Construction_OODlayer/results/2026-09-23-repair-ablation`. Each service was launched as follows (the key comes from the environment and is not printed):
```
tmux new-session -d -s abl-svc-<lvl> "cd /home/chahj578/Construction_OODlayer/src/respec/llm_service && \
  REPAIR_ABLATION=<lvl> DSPY_MODEL=gpt-5.6-sol DSPY_MODEL_TYPE=responses DSPY_TEMPERATURE=none \
  DSPY_MAX_TOKENS=16000 DSPY_CACHE=0 TOOL_SYNTHESIS=1 SYNTH_MULTI_AGENT=1 \
  SYNTH_RECORD_LOG=$R/ledger_<lvl>.jsonl \
  exec /home/chahj578/Construction_OODlayer/.venv/bin/python -m uvicorn dspy_service:app \
  --host 127.0.0.1 --port <port> > $R/svc_<lvl>.log 2>&1"
```
| session | port | /health repair_ablation | code_fingerprint | policy | cache | generation.py gate |
|---|---|---|---|---|---|---|
| abl-svc-none | 8111 | none | 5894a2ce8a532bd8 | dspy:gpt-5.6-sol (responses) | off | OK |
| abl-svc-translate | 8112 | translate | 5894a2ce8a532bd8 | dspy:gpt-5.6-sol (responses) | off | OK |
| abl-svc-all | 8113 | all | 5894a2ce8a532bd8 | dspy:gpt-5.6-sol (responses) | off | OK |

- The gate was run with `generation.py --url … --require-tool-synthesis --require-multi-agent`.
- Snapshots: `health_<lvl>.pre.json` and `health_<lvl>.post.json`. After the pilot, each post snapshot shows calls=4, billed=4, ledger_append_failures=0.

## Handshake negative control (`hsneg.log`)
- Setup: Julia at level `none`, pointed at the `all` service on 8113.
- Result: `ERROR: LoadError: [ablation] service repair_ablation="all" != julia "none" at http://127.0.0.1:8113`, EXIT=1.
- `svc_all.log` still had 0 /decide and 0 /rewrite calls after the run, and no ledger was written.
- `hsneg.prefix.log` and `hspos.prefix.log` are the runs from before the fix. There the service value read as `nothing` at every level, because `/health` was double-parsed (fixed in 13d18a19).

## Pilot: router, tractor zone, seeds 1–4, W=4 per arm, all three arms at once
| arm | campaign id | set_env.REPAIR_ABLATION | config_digest | complete | closed s1/s2/s3/s4 |
|---|---|---|---|---|---|
| none | abl-none-tractor-20260923 | none | 78d684a66eefbb3a | 4/4 | 287/287/287/287 |
| translate | abl-translate-tractor-20260923 | translate | da5094f5d8e98f6c | 0/4 | 147/170/218/184 |
| all | abl-all-tractor-20260923 | all | 1222b1ee8525025a | 0/4 | 147/170/219/184 |

- Grids are in `<lvl>-tractor/`, drivers in `pilot_<lvl>.out`, and the full check table in `g4_check.out` (produced by `python3 g4_check.py`).
- All 12 runs have status `scored`. The incomplete runs exit with rc=1, which the campaign still records as scored.
- In both ablation arms, every run minted one body (`verdict=admit`). All 8 were rewritten (translate: 4 threw; all: 3 threw, 1 noop), and none completed.

## Checks
- **a PASS.** All 12 runs have `[ablation] level=<arm> armed=true denied=0 exempt=5`. The detail is `exempt:monitor_record=1, exempt:policy_payload=3, exempt:reference_label=1`, all of which are allowed sites.
- **b PASS.** `zone_place` is identical per seed across the three arms.
- **c PASS.** `[run-ctx] repair_ablation` equals the arm in every run. config_digest is constant within each arm and different across arms.
- **d PASS, but trivially.** The ledgers have 8 rows each for translate and all. None of them names a reserved name (12 blocked plus machinery; 36 names for translate, 39 for all), so the registration gate was never exercised. There are also 0 `reject:ablated_primitive` lines in the logs. The matcher was spot-checked on synthetic bodies.
- **e (for information).** The none arm gives complete/287 on s1–4. The 9/23 sol run (`results/2026-09-23-router-sol-tractor`) gives complete/287 on s1–4. They are identical.
- **f.** Ledger rows: none 4, translate 8, all 8. Cost from `cost.py` (usd_raw_lm): none $0.81, translate $0.92, all $1.39, **total $3.12**, or about $0.26 per run. This is an estimate: it excludes macro calls and responses that never arrived.
