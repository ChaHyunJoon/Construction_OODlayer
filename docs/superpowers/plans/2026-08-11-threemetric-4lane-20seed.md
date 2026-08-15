# Three-Metric Evaluation at 4 Lanes × 20 Seeds — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a defensible 7-failure-case × 4-controller table reporting **all three** designed evaluation metrics — success rate, total building time, and energy efficiency via battery SoC — at 20 OOD seeds, with the rule-based controller measured as a genuinely enacted lane instead of a mislabelled `noop`.

**Architecture:** No new simulator behavior and no new instrumentation — every metric this plan reports is *already* written to `results_4pol/<case>.jsonl` by the existing runner (`sim_seconds`, `battery.{mean_soc,min_soc,energy_per_closed,total_energy_J,n_depleted}`) and *already* aggregated by `llm_ood_eval.summarize()`. Three things are missing and this plan supplies them: (a) the `canonical` (rule-based) lane is never enacted because `run_4pol.sh:30` hardcodes a 3-policy list, and the runner's row-count and cost arithmetic hardcode the literal `3`; (b) build time and SoC are aggregated but never subjected to the paired statistics or surfaced in the cross-case grid the slide needs; (c) the data itself is still n=5. We fix (a) and (b) first, prove the new lane enacts with a one-seed smoke run, then collect 560 boards across two sequential sessions using the runner's existing `--resume` and per-case deadline guard.

**Tech Stack:** Python 3 (`.venv`: numpy 2.4.6, scipy 1.18.0), bash, Julia 1.10 LTS (invoked, never modified), DSPy service on uvicorn.

**Relationship to the sibling plan:** [2026-08-11-seed20-verification.md](2026-08-11-seed20-verification.md) Tasks 1–6 are **already committed** (verified by git log: `9e9a86b`, `2d977f1`, `45073bb`, `68f9c24`, `d74fc8f`). This plan **supersedes that plan's Tasks 7–10** — same sweep, but 4 lanes instead of 3, plus SoC as a tested endpoint and a slide-shaped output. Task 1 below re-verifies the earlier tasks landed before spending 26 hours on top of them.

---

## Global Constraints

Apply to **every** task. Copied verbatim from the repo's own contracts (`.claude/CLAUDE.md`, `md/README.md`, sibling plan).

- **Python interpreter is `/home/chahj578/Construction_OODlayer/.venv/bin/python`.** `run_4pol.sh` hardcodes this as `$PY`. Never use bare `python`.
- **Working directory for all Python analysis tools is `wm4spacecraft_manufacturing/`.** Module-relative paths assume it.
- **Comparison runs are strictly sequential** (`md/README.md` trap 30). Parallel Julia = different HiGHS schedules = invalid comparison, plus ~2.5 GB/process → OOM. Gate P5 in `run_4pol.sh` enforces "no julia already running". Never bypass it.
- **`DSPY_PROGRAM=__seed_only__` is mandatory for the `dspy` lane.** The compiled `dspy_real_program_gpt4o.json` is battery-only vocabulary; measuring `zone` with it measures out-of-vocabulary events. Gate P2 records which program was used into `_night/provenance_4pol.json` — read it, don't assume.
- **`world_seed` stays fixed at 1.** Layout generalization is explicitly not claimed. The limitation must remain in the generated report.
- **Never hardcode a sample size, p-value, seed list, board count, or lane count into generated report prose.** Every such number is computed from loaded rows. `test_report_sample_size.py` is the regression gate for this; extend it, never weaken it.
- **Do not modify `tools/monitor/run_demo.jl`, `tools/monitor/policy.jl`, or `reference_policy.py`.** Changing any of them silently re-scores every number and destroys comparability with the frozen `baseline_n5/`. The known `reference_policy.py` zone defect (REPORT §3-B) stays reported-not-fixed.
- **Process-per-board stays.** Each board spawns a fresh `julia +lts` (`llm_ood_eval.py:run_one`). The ~60–100 s startup+JIT is the price of the isolation the comparison depends on. Do not attempt to reuse a warm Julia process.
- **There is no pytest in this repo.** Tests are standalone scripts following `test_report_sample_size.py`: a `check(name, ok, detail)` helper printing `PASS`/`FAIL`, module-level `FAILED` counter, ending `sys.exit(1 if FAILED else 0)`. Run as `python test_x.py`. Do not add pytest.
- **Action vocabulary single source of truth is `action_registry.json`.** No literal macro lists.
- **Commit after every task.** Work on `oracle-rebuild-night-2026-08-10` or a branch off it. Never commit to `master`.
- **Expected baseline, not a failure:** `julia +lts --project=. -e 'using Pkg; Pkg.test()'` = 11 pass / 1 error (Gurobi license). `python verify.py oracle/out/n44_plus78.jsonl` dies at S1 with `KeyError: 7`. Both pre-exist this work.

---

## Background: what scoping established (read this first)

Seven facts from direct inspection. They drive every task.

1. **The metrics were never missing from the harness — only from the slide.** Every summary row already carries `sim_seconds` and a `battery` dict. Confirmed by reading `results_4pol/all.jsonl`: `{"sim_seconds": 38.725, "battery": {"mean_soc": 0.976, "min_soc": 0.953, "energy_per_closed": 594.5, "total_energy_J": 173012.4, "n_depleted": 0, ...}}`. `llm_ood_eval.py:323-334` already aggregates these into `sim_seconds_complete`, `sim_seconds_sd`, `energy_per_closed`, `mean_soc`, `min_soc`, `n_depleted`. **No instrumentation task exists in this plan** because none is needed.

2. **The slide's CANONICAL column is not the rule-based controller.** `run_4pol.sh:30` is `POLICIES="noop,surrogate,dspy"`. `canonical` is a first-class runnable lane — `policy.jl:17` (`DEMO_POLICY` default is literally `canonical`), `policy.jl:441-475` (`canonical_macro(env, truth)` projects the `CB.canonical_respec` rule table onto the currently-executable vocabulary), `llm_ood_eval.py:490` (`--policies` default includes it) — but it was never enacted in this experiment. The slide footnote "Canonical lane = noop" is the tell, and `acc 0%` in every CANONICAL cell is the consequence: rule decisions were shadow-scored while `noop` was enacted.

3. **`canonical` needs no DSPy service.** `policy.jl:486` short-circuits for `POLICY in ("canonical","noop")` with the router disabled. The lane is cheap and cannot fail-open into an LLM call.

4. **Build time is only meaningful conditioned on completion.** `llm_ood_eval.py:322` states it: a stalled board's `steps` includes the 2500-step stall-detection wait, so mixing stalls in flips "failure is slow" into "failure is fast". `sim_seconds_complete` averages completed boards only, and `build_final_table._time_if_complete` returns `None` for non-completers. This makes E4 **selection-biased by construction** — where a lane completes 0/20, build time is *undefined*, not zero, and must print `— (완주 0)`.

5. **The real per-board cost is 143.9–212.3 s, not the 67.9 s the JSONL suggests.** `wall_seconds` in the summary row is Julia's internal sim clock; it omits process startup + JIT. The bash-measured truth is in `_night/status_4pol.jsonl` (per case, 15 boards each): battery 143.9, fault 154.6, zone 164.3, battery_zone 162.1, fault_zone 175.4, fault_battery 186.2, all 212.3. `run_4pol.sh:66-78` already prices from these (×1.15 padding). **Total for 7 cases × 4 lanes × 20 seeds = 560 boards ≈ 26.6 h measured, 30.9 h at the script's padded prices.** That exceeds the 86400 s default deadline, which would silently `skipped` the tail cases — hence the two-session split.

6. **The runner's arithmetic hardcodes 3 lanes in two places.** `run_4pol.sh:57` `EXPECTED_ROWS=$(( N_SEEDS * 3 ))` and `:196` `EST_COST=$(( UNIT_PRICE * N_SEEDS * 3 ))`. Left alone with 4 lanes, every case would be judged complete at 80% of its rows (`fail` → wrongly `ok` on resume) and every deadline estimate would be 25% low.

7. **The statistics and rendering are lane-count-driven but pair-list-frozen.** `build_final_table.py:196` `PAIRS` lists 3 pairs; `apply_holm_correction` builds its family *from the data* (`pmap[ep][case__pair]`), so adding pairs grows the family automatically from 21 to **42** (7 cases × 6 pairs) — only the docstring's literal `21` must be corrected. `ROW_ORDER` (`:53`) has no `canonical` row, and `build_md_report.py:533` iterates `BFT.ROW_ORDER`, so one edit fixes both documents. `check_v4` (`:366`) is already dynamic (`n_seeds × n_pol`) — no change needed.

---

## Experiment Design (the thing being built)

| Axis | Value | Rationale |
|---|---|---|
| `ood_seed` | 1, 2, …, 20 | Matches frozen `PREREG_SEED20.md`. Sign-test floor 2·0.5²⁰ = 1.9e-06. |
| `world_seed` | 1 (fixed) | Scope decision; layout generalization not claimed. |
| Cases (7) | `battery`, `fault`, `zone`, `battery_zone`, `fault_zone`, `fault_battery`, `all` | `zonecore` dropped — `run_demo.jl:433` rewrites `:zonecore → :zone` under `DEMO_OOD_STREAM3=1`, so it duplicates `zone`. |
| Lanes (4) | `noop`, `canonical`, `surrogate`, `dspy` | `canonical` added (fact 2). `oracle` is **not** a lane. |
| Boards | 7 × 4 × 20 = **560** | ≈26.6 h measured, split across two sessions. |
| Oracle | Ceiling row only | `policy.jl` has no oracle branch, and the only forcing hook (`DEMO_FORCE_MACRO`, `policy.jl:453`) applies **one macro to a whole run** — it cannot enact a per-event a\*. Oracle keeps its completion/decision ceiling; its build-time and SoC cells print "— (실행 불가 정책)". |

**Endpoints.** E1–E4 carry over from the sibling prereg; **E5 is new** and is what makes "energy efficiency via battery SoC" a tested claim rather than a printed number.

| # | Endpoint | Field | Test | Family size |
|---|---|---|---|---|
| E1 | Success rate (**primary**) | `complete` | Paired sign test on `(case, ood_seed)`, ties dropped | 42 |
| E2 | Decision fidelity vs a\* | `decisions[].correct` | Cluster bootstrap over boards, 10000 reps, seed 0 | 42 |
| E3 | Energy per closed node | `battery.energy_per_closed` | Paired Wilcoxon signed-rank | 42 |
| E4 | Total building time | `sim_seconds` (complete only) | Paired Wilcoxon, **selection-bias caveat mandatory** | 42 |
| E5 | Battery SoC floor | `battery.min_soc` | Paired Wilcoxon | 42 |

42 = 7 cases × 6 lane pairs (C(4,2)). **Holm–Bonferroni within each endpoint family, never pooled across families.** α = 0.05.

`min_soc` is the honest SoC axis for E5: `mean_soc` is dominated by the many robots that never move (the n=5 rows show `mean_soc` ≈ 0.93 even on boards where a robot hit 0.0), whereas `min_soc` is exactly the depletion event the metric is meant to catch. `n_depleted` is reported descriptively alongside, untested.

**Two-session schedule** (case-split, using the existing `--resume`):

| Session | Cases | Boards | Measured | Padded (deadline to pass) |
|---|---|---|---|---|
| A | `battery`, `fault`, `zone`, `battery_zone` | 320 | 13.9 h | 16.1 h → `--deadline-seconds 58000` |
| B | `fault_zone`, `fault_battery`, `all` | 240 | 12.8 h | 14.8 h → `--deadline-seconds 53200` |

Session A takes the four cheapest cases so that if the machine is reclaimed early, the surviving data is four *complete* cases rather than seven partial ones. `canonical` is priced as if it cost as much as `dspy`; it has no LLM call, so both estimates are conservative.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `wm4spacecraft_manufacturing/PREREG_SEED20.md` | Modify | Append a **Deviations** section: 4 lanes, 42-test families, E5, two-session schedule. Never silently edit §1–§7. |
| `wm4spacecraft_manufacturing/run_4pol.sh` | Modify | `--policies` flag; `N_POLICIES` replaces the literal `3` in row-count and cost arithmetic. |
| `wm4spacecraft_manufacturing/test_run_4pol_lanes.py` | Create | Regression: no `* 3` lane literal survives; the flag parses. |
| `wm4spacecraft_manufacturing/build_final_table.py` | Modify | `LANES`/derived `PAIRS` (6); `canonical` in `ROW_ORDER`+`ROW_LABEL_TEXT`; E5 in `paired_tests` and Holm; SoC column in `render_row_cells`; computed family size in prose. |
| `wm4spacecraft_manufacturing/build_md_report.py` | Modify | Case-table header gains the SoC column (`:531`). |
| `wm4spacecraft_manufacturing/test_report_sample_size.py` | Modify | Extend: family size and lane count must be computed, not literal. |
| `wm4spacecraft_manufacturing/test_four_lane_table.py` | Create | Regression: 6 pairs, 5 endpoints, canonical row renders, oracle SoC cell is the not-runnable token. |
| `wm4spacecraft_manufacturing/build_slide_grid.py` | Create | The deliverable: 7 cases × 4 lanes grid, three metrics per cell, Markdown + CSV. |
| `wm4spacecraft_manufacturing/compare_seed_scale.py` | Create | n=5 → n=20 stability, restricted to the three lanes the baseline shares. |
| `wm4spacecraft_manufacturing/md/RESULTS_3METRIC_20SEED.md` | Create | Generated conclusion document. |

`build_slide_grid.py` is a separate script rather than another emitter inside `build_final_table.py` because it has a different consumer (a slide) and a different shape (cases as rows, lanes as columns, three metrics per cell). It **reads the case JSONs that `build_md_report.py` already wrote** — it never recomputes a statistic. That rule is what keeps the slide and the report from drifting apart.

---

## Task 1: Verify the sibling plan's tasks landed, then amend the prereg

Nothing here is ceremony. Task 1 exists because Tasks 5–6 spend 26 hours of machine time on top of code five commits claim to have fixed, and "claims to have fixed" is not evidence.

**Files:**
- Modify: `wm4spacecraft_manufacturing/PREREG_SEED20.md` (append only)

**Interfaces:**
- Consumes: `stats_paired.holm`, `stats_paired.paired_wilcoxon`, `stats_paired.cluster_bootstrap_ci`, `stats_paired.pair_boards` (all exist, `stats_paired.py:17,36,66,90`).
- Produces: an amended prereg that Task 9 quotes when judging outcomes.

- [ ] **Step 1: Run the three existing regression gates and read the output**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
PY=/home/chahj578/Construction_OODlayer/.venv/bin/python
$PY test_stats_paired.py;        echo "rc=$?"
$PY test_report_sample_size.py;  echo "rc=$?"
$PY test_surrogate_support.py;   echo "rc=$?"
$PY audit_action_vocab.py;       echo "rc=$?"
```

Expected: all four `rc=0`. `test_surrogate_support.py` must print `support=[0, 1, 2, 3, 4, 7, 8]` (7/7 PASS) — that is the only mechanical proof the current-generation action vocabulary is in play. If any gate fails, **stop and fix it before touching anything else**; a red gate means the committed Tasks 2–6 are not actually in the state the git log claims.

- [ ] **Step 2: Confirm the frozen baseline exists and is the 3-lane n=5 data**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
ls baseline_n5/ | wc -l          # expect 27
cat baseline_n5/PROVENANCE.txt
/home/chahj578/Construction_OODlayer/.venv/bin/python - <<'EOF'
import json, glob
for f in sorted(glob.glob("results_4pol/*.jsonl")):
    rows = [json.loads(l) for l in open(f)]
    print(f, len(rows), sorted({r["ood_seed"] for r in rows}), sorted({r["policy"] for r in rows}))
EOF
```

Expected: every case shows `[1,2,3,4,5]` and `['dspy','noop','surrogate']`. This is the state Task 5 will archive and replace.

- [ ] **Step 3: Append the Deviations section to the prereg**

Append exactly this to `PREREG_SEED20.md`. Append — do not edit §1–§7; the document's own header forbids silent edits.

```markdown

## 8. Deviations (appended 2026-08-11, before any 20-seed data)

Recorded before collection, per this document's own rule. Reason for each.

D1 **Lanes: 3 -> 4.** `canonical` is added as an enacted lane. §1 said 3 policies
   (noop, surrogate, dspy). Reason: the rule-based controller was never enacted --
   run_4pol.sh:30 hardcoded a 3-policy list, so the "canonical" column of every
   prior table was the `noop` lane with rule decisions shadow-scored (hence acc 0%
   everywhere). `canonical` is runnable (policy.jl:17,441-475) and needs no DSPy
   service (policy.jl:486). Boards: 420 -> 560.

D2 **Family size: 21 -> 42 per endpoint.** 7 cases x C(4,2)=6 lane pairs. Holm
   still applies WITHIN each endpoint family and families are still never pooled.
   alpha unchanged at 0.05.

D3 **E5 added: battery SoC floor** (`battery.min_soc`), paired Wilcoxon, family 42.
   Reason: "energy efficiency via battery SoC" is a designed evaluation metric that
   §2 tested only indirectly through E3 (J/closed). `min_soc` rather than `mean_soc`
   because mean_soc is dominated by idle robots -- n=5 rows show mean_soc ~= 0.93 on
   boards where a robot reached 0.0. `n_depleted` is reported descriptively, untested.

D4 **Collection split across two sessions**, case-split, via the existing --resume:
   session A = battery, fault, zone, battery_zone (320 boards, ~13.9 h measured);
   session B = fault_zone, fault_battery, all (240 boards, ~12.8 h measured).
   Reason: 560 boards at the bash-measured 143.9-212.4 s/board is ~26.6 h, over the
   86400 s default deadline; a single run would let the per-case deadline guard
   silently mark tail cases `skipped`. The split is by case, so no case is ever
   half-collected. Session A takes the cheap cases so an early abort leaves whole
   cases rather than seven partial ones.

D5 **Oracle build-time and SoC are not measured.** The oracle row keeps its
   completion/decision ceiling only. Reason: policy.jl has no oracle branch, and the
   only enactment override (DEMO_FORCE_MACRO, policy.jl:453) forces ONE macro for a
   whole run, so it cannot enact a per-event a*. Those cells print
   "— (실행 불가 정책)", never a number and never a blank.

D6 **Unchanged and still binding:** world_seed = 1; 7 cases (zonecore still dropped);
   E1 primary; the §4 ceiling-effect declaration; the §5 stability criteria
   (REL_TOL = 0.20); the §7 non-claims. §6's claims C1-C7 remain under test, and are
   judged only against the three lanes the n=5 baseline actually contains.
```

- [ ] **Step 4: Verify the append did not disturb the frozen sections**

```bash
cd /home/chahj578/Construction_OODlayer
git diff --stat wm4spacecraft_manufacturing/PREREG_SEED20.md
git diff -U0 wm4spacecraft_manufacturing/PREREG_SEED20.md | grep '^-' | grep -v '^---'
```

Expected: `1 file changed, N insertions(+)` with **zero deletion lines** in the second command's output. Any `-` line means §1–§7 were edited; revert and re-append.

- [ ] **Step 5: Commit**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/PREREG_SEED20.md
git commit -m "prereg(seed20): record deviations D1-D6 -- 4 lanes, 42-test families, E5 SoC, 2-session split"
```

---

## Task 2: Make `run_4pol.sh` lane-count-correct

**Files:**
- Modify: `wm4spacecraft_manufacturing/run_4pol.sh` (header comment, `:30`, `:57`, `:196`, arg parser at `:39-53`)
- Create: `wm4spacecraft_manufacturing/test_run_4pol_lanes.py`

**Interfaces:**
- Produces: `bash run_4pol.sh --policies noop,canonical,surrogate,dspy --seeds 1,...,20 --cases <csv> --deadline-seconds <N> [--resume]`. Tasks 4, 5, 6 all invoke exactly this.

- [ ] **Step 1: Write the failing test**

Create `wm4spacecraft_manufacturing/test_run_4pol_lanes.py`:

```python
"""test_run_4pol_lanes.py -- run_4pol.sh 의 lane 수 산술이 하드코딩이 아니라는 회귀 테스트.

실행: /home/chahj578/Construction_OODlayer/.venv/bin/python test_run_4pol_lanes.py

이 파일이 막는 결함: 4개 lane 으로 돌리는데 EXPECTED_ROWS 가 N_SEEDS*3 이면 case 가
80줄 중 60줄에서 'ok' 로 판정되고, --resume 이 미완성 case 를 완성으로 착각한다.
그리고 EST_COST 가 25% 낮게 잡혀 데드라인 가드가 뒤 case 를 조용히 skip 한다.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SH = os.path.join(HERE, "run_4pol.sh")

FAILED = 0


def check(name, ok, detail=""):
    global FAILED
    print("  %s  %s   %s" % ("PASS" if ok else "FAIL", name, detail))
    if not ok:
        FAILED += 1


print("== run_4pol.sh lane 수 산술 회귀 테스트 ==")
src = open(SH, encoding="utf-8").read()

# 1) 정책 개수를 세는 변수가 존재한다.
check("N_POLICIES 를 정책 목록에서 센다",
      re.search(r"N_POLICIES=\$\{#POL_ARR\[@\]\}", src) is not None)

# 2) 행 수 기대값과 비용 추정에 리터럴 3 이 없다.
check("EXPECTED_ROWS 가 N_POLICIES 를 쓴다",
      re.search(r"EXPECTED_ROWS=\$\(\(\s*N_SEEDS \* N_POLICIES\s*\)\)", src) is not None)
check("EST_COST 가 N_POLICIES 를 쓴다",
      re.search(r"EST_COST=\$\(\(\s*UNIT_PRICE \* N_SEEDS \* N_POLICIES\s*\)\)", src) is not None)
check("lane 수 리터럴 3 이 산술에 남아 있지 않다",
      "N_SEEDS * 3" not in src and "N_SEEDS \\* 3" not in src)

# 3) --policies 를 파싱한다.
check("--policies 플래그를 파싱한다", "--policies)" in src)

# 4) 기본 lane 집합이 4개다(canonical 포함).
m = re.search(r'^POLICIES="\$\{POLICIES:-([^"}]*)\}"', src, re.M)
check("POLICIES 기본값이 4 lane 이다",
      m is not None and [s.strip() for s in m.group(1).split(",")] ==
      ["noop", "canonical", "surrogate", "dspy"],
      m.group(1) if m else "패턴 불일치")

# 5) 스크립트가 문법적으로 유효하다(bash -n 은 실행하지 않고 파싱만 한다).
rc = subprocess.run(["bash", "-n", SH], capture_output=True, text=True)
check("bash -n 통과", rc.returncode == 0, rc.stderr.strip()[:200])

# 6) 헤더 주석이 3정책이라고 거짓말하지 않는다.
check("헤더 주석이 lane 수를 잘못 적지 않는다", "3개 실행 정책" not in src)

print()
print("FAILED=%d" % FAILED)
sys.exit(1 if FAILED else 0)
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_run_4pol_lanes.py
```

Expected: FAIL on `N_POLICIES`, `EXPECTED_ROWS`, `EST_COST`, `lane 수 리터럴 3`, `--policies`, `POLICIES 기본값`, and the header comment — 7 FAILs, `rc=1`. `bash -n` should already PASS.

- [ ] **Step 3: Edit the runner — header comment**

In `run_4pol.sh:3`, replace:

```
# run_4pol.sh -- 무인 ~5시간 스윕: 3개 실행 정책(noop, surrogate, dspy) x 8개 OOD case.
```

with:

```
# run_4pol.sh -- 무인 스윕: 실행 정책 목록(--policies) x OOD case 목록(--cases).
# 기본은 4 lane(noop, canonical, surrogate, dspy) x 7 case. lane 수는 어디에도
# 리터럴로 박지 않는다 -- N_POLICIES 가 유일한 출처다(test_run_4pol_lanes.py 가 계약).
```

- [ ] **Step 4: Edit the runner — default policy list**

In `run_4pol.sh:30`, replace:

```bash
POLICIES="noop,surrogate,dspy"
```

with:

```bash
# canonical(규칙 기반)은 policy.jl:441-475 의 CB.canonical_respec 룩업을 실제로 집행하는
# lane 이다. 2026-08-11 이전에는 이 목록에 없어서, 표의 "canonical" 열이 실은 noop 판이었다
# (규칙 결정은 shadow 채점만 됨 -- 그래서 acc 가 전부 0% 였다).
POLICIES="${POLICIES:-noop,canonical,surrogate,dspy}"
```

- [ ] **Step 5: Edit the runner — argument parser**

In `run_4pol.sh:45-46`, after the `--cases` branch, add a `--policies` branch:

```bash
        --cases)
            CASES_CSV="$2"; shift 2 ;;
        --policies)
            POLICIES="$2"; shift 2 ;;
```

- [ ] **Step 6: Edit the runner — lane count arithmetic**

In `run_4pol.sh:55-57`, replace:

```bash
IFS=',' read -r -a SEED_ARR <<< "$SEEDS"
N_SEEDS=${#SEED_ARR[@]}
EXPECTED_ROWS=$(( N_SEEDS * 3 ))
```

with:

```bash
IFS=',' read -r -a SEED_ARR <<< "$SEEDS"
N_SEEDS=${#SEED_ARR[@]}
IFS=',' read -r -a POL_ARR <<< "$POLICIES"
N_POLICIES=${#POL_ARR[@]}
# 리터럴 3 이었다. 4 lane 으로 돌리면 case 가 80줄 중 60줄에서 'ok' 가 되고, --resume 이
# 미완성 case 를 완성으로 착각해 영구히 건너뛴다.
EXPECTED_ROWS=$(( N_SEEDS * N_POLICIES ))
echo "[cfg] seeds=$N_SEEDS policies=$N_POLICIES ($POLICIES) -> expected rows/case=$EXPECTED_ROWS"
```

Then in `run_4pol.sh:196`, replace:

```bash
    EST_COST=$(( UNIT_PRICE * N_SEEDS * 3 ))
```

with:

```bash
    EST_COST=$(( UNIT_PRICE * N_SEEDS * N_POLICIES ))
```

- [ ] **Step 7: Run the test to verify it passes**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_run_4pol_lanes.py
```

Expected: 7 PASS, `FAILED=0`, `rc=0`.

- [ ] **Step 8: Verify the config echo reports 4 lanes and 80 rows without running a board**

The gates run before any board, so a deliberately-failing gate is a safe way to see the config line. Point `DSPY_URL` at a dead port so P1 fails immediately:

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
DSPY_URL=http://127.0.0.1:1 bash run_4pol.sh --seeds 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20 2>&1 | head -5
```

Expected: `[cfg] seeds=20 policies=4 (noop,canonical,surrogate,dspy) -> expected rows/case=80`, then `PREREQ FAIL: P1`. Seeing `policies=4` and `rows/case=80` is the whole point; the P1 failure is expected and correct.

- [ ] **Step 9: Commit**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/run_4pol.sh wm4spacecraft_manufacturing/test_run_4pol_lanes.py
git commit -m "fix(4pol): lane count from N_POLICIES, add --policies, default to 4 lanes incl canonical"
```

---

## Task 3: Four lanes, six pairs, and E5 (SoC) in the table and statistics

**Files:**
- Modify: `wm4spacecraft_manufacturing/build_final_table.py` (`:50-53`, `:196`, `:199-236`, `:252-256`, `:509-543`, `:591`)
- Modify: `wm4spacecraft_manufacturing/build_md_report.py` (`:531`)
- Modify: `wm4spacecraft_manufacturing/test_report_sample_size.py`
- Create: `wm4spacecraft_manufacturing/test_four_lane_table.py`

**Interfaces:**
- Consumes (exact, verified by reading `stats_paired.py:17,36,90` and `build_final_table.py:208-236`):
  - `stats_paired.paired_wilcoxon(a, b)` → **a dict** with keys `p`, `median_diff`, `n_used`, `note`. It is **not** a tuple; `e3 = paired_wilcoxon(...)` then `e3["p"]`. Lists may contain `None`; the function drops those pairs itself and reports the surviving count in `n_used`.
  - `stats_paired.pair_boards(rows, a, b, key)` → `(list_a, list_b)`, where `key` is a **field-name string** (e.g. `"complete"`), not a callable. For derived quantities the existing code uses `_rows_for(rows, lane)` plus an extractor function instead — follow that pattern for E5.
  - `stats_paired.holm(pvals)` → list of adjusted p-values in input order.
- Produces: `build_final_table.LANES` (list of 4 strings), `PAIRS` (6 tuples), `paired_tests(rows)` returning per-pair dicts with keys `e1_sign_p`, `e3_wilcoxon_p`, `e4_wilcoxon_p`, `e5_wilcoxon_p`; `render_row_cells(...) -> list[str]` of **5** cells; `apply_holm_correction(...) -> {"e1"|"e3"|"e4"|"e5": {...}}`. Task 7's `build_slide_grid.py` reads the `<case>.json` files these produce.

- [ ] **Step 1: Write the failing test**

Create `wm4spacecraft_manufacturing/test_four_lane_table.py`:

```python
"""test_four_lane_table.py -- 4 lane / 6 쌍 / 5 endpoint 계약 회귀 테스트.

실행: /home/chahj578/Construction_OODlayer/.venv/bin/python test_four_lane_table.py

이 파일이 막는 결함 세 가지:
  1) canonical lane 을 돌렸는데 표에 행이 없어 조용히 사라진다.
  2) PAIRS 가 3쌍이라 canonical 을 포함한 검정이 아예 수행되지 않는다.
  3) oracle 행의 SoC 칸에 숫자나 빈칸이 들어간다(오라클은 실행 가능한 정책이 아니다).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import build_final_table as BFT

FAILED = 0


def check(name, ok, detail=""):
    global FAILED
    print("  %s  %s   %s" % ("PASS" if ok else "FAIL", name, detail))
    if not ok:
        FAILED += 1


print("== 4 lane / 6 쌍 / 5 endpoint 계약 ==")

check("LANES 가 4개다", BFT.LANES == ["noop", "canonical", "surrogate", "dspy"], repr(BFT.LANES))
check("PAIRS 가 6쌍이다", len(BFT.PAIRS) == 6, repr(BFT.PAIRS))
check("PAIRS 가 LANES 에서 파생된다(리터럴 아님)",
      set(BFT.PAIRS) == {(a, b) for i, a in enumerate(BFT.LANES) for b in BFT.LANES[i + 1:]})
check("canonical 쌍이 실제로 들어있다",
      ("noop", "canonical") in BFT.PAIRS and ("canonical", "dspy") in BFT.PAIRS)

labels = [lbl for lbl, _ in BFT.ROW_ORDER]
check("ROW_ORDER 에 canonical 행이 있다", "canonical" in labels, repr(labels))
check("ROW_LABEL_TEXT 가 모든 행을 덮는다",
      all(lbl in BFT.ROW_LABEL_TEXT for lbl in labels))

# ---- paired_tests: 5 endpoint 키 + canonical 쌍 ----------------------------------
def board(seed, pol, complete, sim_s, jpc, min_soc):
    return {"case": "battery", "ood_seed": seed, "policy": pol, "complete": complete,
            "sim_seconds": sim_s, "closed": 300 if complete else 200,
            "battery": {"energy_per_closed": jpc, "min_soc": min_soc}}

rows = []
for s in range(1, 6):
    rows.append(board(s, "noop",      False, 120.0, 900.0, 0.00))
    rows.append(board(s, "canonical", True,   60.0, 700.0, 0.40))
    rows.append(board(s, "surrogate", True,   40.0, 600.0, 0.95))
    rows.append(board(s, "dspy",      True,   35.0, 520.0, 0.96))

pt = BFT.paired_tests(rows)
check("paired_tests 가 6쌍을 낸다", len(pt) == 6, repr(sorted(pt)))
check("canonical 쌍 키가 있다", "noop__canonical" in pt, repr(sorted(pt)))
for k in ("e1_sign_p", "e3_wilcoxon_p", "e4_wilcoxon_p", "e5_wilcoxon_p"):
    check("모든 쌍이 %s 를 낸다" % k, all(k in v for v in pt.values()))

# E4 는 완주판만 본다 -- noop 이 0/5 완주면 짝이 하나도 없어 검정 불가여야 한다.
check("E4 는 완주 0 인 쌍에서 정의 불가다",
      pt["noop__dspy"].get("e4_n") == 0, repr(pt["noop__dspy"].get("e4_n")))
# E5 는 완주 여부와 무관하게 모든 판을 본다(방전은 미완주 판에서 일어난다).
check("E5 는 미완주 판도 센다", pt["noop__dspy"].get("e5_n") == 5,
      repr(pt["noop__dspy"].get("e5_n")))

# ---- Holm 족 크기가 데이터에서 계산된다 -----------------------------------------
pmap = {"%s__%s__%s" % (c, a, b): 0.01
        for c in BFT.CASES[:7] for a, b in BFT.PAIRS}
adj = BFT.holm_family(pmap)
check("Holm 족이 42 검정이다(7 case x 6 쌍)", len(adj) == 42, "len=%d" % len(adj))

# ---- 렌더: 5칸, oracle 의 SoC 칸은 비실행 토큰 ----------------------------------
cells = BFT.render_row_cells("oracle", "all", {}, {})
check("행이 5칸을 낸다(완주/결정/시간/에너지/SoC)", len(cells) == 5, repr(cells))
check("oracle SoC 칸이 비실행 토큰이다", cells[4] == BFT.NOT_RUNNABLE_TOKEN, repr(cells[4]))
check("oracle 시간 칸도 비실행 토큰이다", cells[3] == BFT.NOT_RUNNABLE_TOKEN, repr(cells[3]))

jd = {"policies": {"canonical": {"n": 20, "n_complete": 17, "decision_rate": 0.8,
                                 "n_decisions_correct": 40, "n_decisions_scored": 50,
                                 "sim_seconds_complete": 61.2, "sim_seconds_sd": 4.1,
                                 "energy_per_closed": 705.5, "min_soc": 0.412}}}
cc = BFT.render_row_cells("canonical", "battery", jd, {})
check("canonical 행이 렌더된다", cc[0] == "17/20", repr(cc))
check("canonical SoC 가 숫자로 렌더된다", "0.41" in cc[4], repr(cc[4]))

missing = BFT.render_row_cells("canonical", "battery", {"policies": {}}, {})
check("데이터 없는 lane 도 5칸을 낸다", len(missing) == 5, repr(missing))

print()
print("FAILED=%d" % FAILED)
sys.exit(1 if FAILED else 0)
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_four_lane_table.py
```

Expected: FAIL — the first failure will be `AttributeError: module 'build_final_table' has no attribute 'LANES'`. That is the correct starting point; the remaining checks cannot run until `LANES` exists.

- [ ] **Step 3: Add `LANES`, derive `PAIRS`, add the not-runnable token**

In `build_final_table.py:50-53`, replace:

```python
CASES = ["battery", "fault", "zonecore", "all", "fault_battery", "fault_zone", "battery_zone", "zone"]

# 최종표 행 순서: oracle(천장) -> surrogate -> noop -> llm(dspy). plan §8 그대로.
ROW_ORDER = [("oracle", None), ("surrogate", "surrogate"), ("noop", "noop"), ("llm", "dspy")]
```

with:

```python
CASES = ["battery", "fault", "zonecore", "all", "fault_battery", "fault_zone", "battery_zone", "zone"]

# 실행 lane 의 단일 진실원. PAIRS 도 ROW_ORDER 도 여기서 파생된다 -- lane 을 늘릴 때
# 고쳐야 할 곳이 한 군데여야 한다(2026-08-11: canonical 이 빠져 있던 것이 표의 "canonical"
# 열을 noop 판으로 만들었다).
LANES = ["noop", "canonical", "surrogate", "dspy"]

# 최종표 행 순서: oracle(천장) -> canonical(규칙) -> surrogate -> noop(바닥선) -> llm(dspy).
ROW_ORDER = [("oracle", None), ("canonical", "canonical"), ("surrogate", "surrogate"),
             ("noop", "noop"), ("llm", "dspy")]

# 오라클은 실행 가능한 온라인 정책이 아니다(policy.jl 에 oracle 분기 없음). 시간·SoC 는
# 결측이 아니라 **측정 불가**다 -- DASH 로 적으면 "아직 안 쟀다"로 읽힌다.
NOT_RUNNABLE_TOKEN = "— (실행 불가 정책)"
```

- [ ] **Step 4: Derive `PAIRS` from `LANES`**

In `build_final_table.py:196`, replace:

```python
PAIRS = [("noop", "surrogate"), ("noop", "dspy"), ("surrogate", "dspy")]
```

with:

```python
# C(len(LANES), 2) 쌍. 리터럴 목록이었고, 그래서 canonical 을 lane 에 추가해도 검정이
# 조용히 3쌍에만 돌았다. 4 lane -> 6 쌍 -> endpoint 족은 7 case x 6 = 42 검정.
PAIRS = [(a, b) for i, a in enumerate(LANES) for b in LANES[i + 1:]]
```

- [ ] **Step 5: Add the `min_soc` extractor and E5 to `paired_tests`**

In `build_final_table.py:199-206`, after `_time_if_complete`, add:

```python
def _min_soc(r):
    """E5. 완주 여부로 걸러내지 **않는다** -- 방전은 미완주 판에서 일어나므로, 완주판만
    보면 SoC 지표가 정확히 재야 할 사건을 표본에서 빼버린다(E4 와 다른 이유로 다른 규칙)."""
    return ((r or {}).get("battery") or {}).get("min_soc")
```

Then add E5 to `paired_tests`. The existing E1/E3/E4 computation is already correct and already emits `e3_n`/`e4_n` from `n_used` — **change nothing in it**. Two insertions only.

First, in `build_final_table.py:208-209`, fix the docstring's stale lane count:

```python
def paired_tests(rows):
    """case 하나의 판들에 대해 len(PAIRS) 개 정책쌍 x E1/E3/E4/E5 검정. 반환 {"a__b": {...}}."""
```

Second, immediately after the existing E4 block (the `e4_note = ...` line at `:226`) and before the `out[...] = {` assignment, insert the E5 block — following the same `_rows_for` + extractor shape E3 uses, because `pair_boards` takes a field-name string and `min_soc` lives nested under `battery`:

```python
        # E5. _time_if_complete 와 달리 완주 필터가 없다 -- 방전은 미완주 판에서 일어난다.
        sa = [_min_soc(r) for r in _rows_for(rows, a)]
        sb = [_min_soc(r) for r in _rows_for(rows, b)]
        e5 = paired_wilcoxon(sa, sb)
```

Then add three keys to the returned dict, inside the existing `out["%s__%s" % (a, b)] = { ... }` literal:

```python
            "e5_wilcoxon_p": e5["p"], "e5_median_diff": e5["median_diff"], "e5_n": e5["n_used"],
            "e5_note": e5["note"],
```

`e4_n == 0` (already emitted) is how a caller learns build time is undefined for that pair — the machine-readable form of the "완주 0" caveat. `e5_n` should equal the seed count for every pair, since SoC is defined on stalled boards too; a smaller `e5_n` means `min_soc` was null somewhere and must be investigated, not averaged over.

- [ ] **Step 6: Add E5 to the Holm families and stop the docstring lying about 21**

In `build_final_table.py:252-256`, replace the docstring's literal family size and add `e5`:

```python
def apply_holm_correction(all_artifacts, out_dir: Path):
    """모든 case 의 paired_tests 가 다 모인 뒤(2-pass 의 2단계)에만 부를 것 -- Holm 은 case 하나가
    아니라 endpoint 족(len(CASES 데이터) x len(PAIRS) 검정) 전체에 적용된다. 족 크기는 pmap 에서
    세어지며 산문에 리터럴로 적지 않는다(4 lane 이면 7 x 6 = 42, 3 lane 이면 21 이었다).
    E1/E3/E4/E5 는 서로 다른 물음이라 **족을 절대 섞지 않는다**(endpoint 별로 따로 보정)."""
    pmap = {"e1": {}, "e3": {}, "e4": {}, "e5": {}}
```

and inside the collection loop add:

```python
            pmap["e5"][k] = t["e5_wilcoxon_p"]
```

- [ ] **Step 7: Render five cells, with the not-runnable token for oracle**

In `build_final_table.py:509-537`, `render_row_cells` must return 5 cells. Replace the oracle branch's returns and the policy branch's return:

```python
def render_row_cells(row_label, case, json_data, ceilings):
    if row_label == "oracle":
        if case not in CASE_TO_CEILING_KEY:
            return [NA_MIXED_KIND_TOKEN, "100% (정의상)", NOT_RUNNABLE_TOKEN, NOT_RUNNABLE_TOKEN,
                    NOT_RUNNABLE_TOKEN]
        summary = oracle_ceiling_summary_for_case(case, ceilings)
        if summary is None:
            return [MISSING_TOKEN, "100% (정의상)", NOT_RUNNABLE_TOKEN, NOT_RUNNABLE_TOKEN,
                    NOT_RUNNABLE_TOKEN]
        completion = fmt_pct(summary["completion_rate"], summary["n_complete"], summary["n"])
        # 격자의 makespan 은 강제집행 런의 상한선이고 온라인 정책의 빌드 시간이 아니다 --
        # 같은 열에 섞어 적으면 비교 가능한 숫자처럼 읽힌다. 시간/에너지/SoC 는 비실행이다.
        return [completion, "100% (정의상)", NOT_RUNNABLE_TOKEN, NOT_RUNNABLE_TOKEN,
                NOT_RUNNABLE_TOKEN]
    pol_key = dict(ROW_ORDER)[row_label]
    policies = (json_data or {}).get("policies") or {}
    d = policies.get(pol_key)
    if d is None:
        return ["정책 없음 (case 데이터에 `%s` 미포함)" % pol_key, DASH, DASH, DASH, DASH]
    completion = "%d/%d" % (d.get("n_complete", 0), d.get("n", 0))
    decision = fmt_pct(d.get("decision_rate"), d.get("n_decisions_correct"), d.get("n_decisions_scored"))
    btime = fmt_time(d.get("sim_seconds_complete"), d.get("sim_seconds_sd"))
    energy = fmt_num(d.get("energy_per_closed"))
    soc = fmt_num(d.get("min_soc"), nd=3)
    return [completion, decision, btime, energy, soc]
```

Note the oracle `makespan` branch is deliberately dropped: `summary["mean_makespan"]` comes from single-macro forced-enactment grids, not from an online policy, so printing it in the build-time column invites exactly the false comparison D5 forbids.

- [ ] **Step 8: Add `canonical` to `ROW_LABEL_TEXT` and widen both table headers**

In `build_final_table.py:538-543`:

```python
ROW_LABEL_TEXT = {
    "oracle": "`oracle` (천장·비실행)",
    "canonical": "`canonical` (규칙 기반)",
    "surrogate": "`surrogate`",
    "noop": "`noop` (바닥선)",
    "llm": "`llm` (dspy)",
}
```

In `build_final_table.py:591-592`:

```python
    lines.append("| 정책 | 완주율 | 옳은 결정 (vs oracle a*) | 빌드 시간(완주판) | J/closed | min SoC |")
    lines.append("|---|---|---|---|---|---|")
```

In `build_md_report.py:531-532`:

```python
        L.append("| 정책 | 완주율 | 옳은 결정 (vs a\\*) | 빌드 시간(완주판) | J/closed | min SoC |")
        L.append("|---|---|---|---|---|---|")
```

- [ ] **Step 9: Extend the sample-size regression test to cover lane count**

Append to `wm4spacecraft_manufacturing/test_report_sample_size.py`, before its final `sys.exit`:

```python
# ---- (2026-08-11) lane 수와 족 크기도 계산값이어야 한다 -------------------------
body4 = "\n".join(build_final_table.limitations_lines(
    {"battery": _boards(20, policies=("noop", "canonical", "surrogate", "dspy"))}))
check("한계 문구에 lane 수 리터럴 3 이 없다", " 3개 정책" not in body4 and "3 정책" not in body4)
check("한계 문구가 실제 판 수(80)를 쓴다", "80" in body4, body4[:200])
src_bft = open(os.path.join(HERE, "build_final_table.py"), encoding="utf-8").read()
check("족 크기 21 이 산문에 리터럴로 남아 있지 않다", "= 21 검정" not in src_bft)
check("PAIRS 가 리터럴 목록이 아니다",
      'PAIRS = [("noop", "surrogate")' not in src_bft)
```

If `limitations_lines` does not yet mention the board count, make it compute one — `len(boards)` per case — rather than weakening the check. The constraint "no hardcoded sample size in prose" covers lane count too.

- [ ] **Step 10: Run both tests to verify they pass**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
PY=/home/chahj578/Construction_OODlayer/.venv/bin/python
$PY test_four_lane_table.py
$PY test_report_sample_size.py
$PY test_stats_paired.py
```

Expected: all three `FAILED=0`, `rc=0`.

- [ ] **Step 11: Regenerate the report from the existing n=5 data and confirm nothing broke**

This is a smoke test of the renderers, not a measurement. The n=5 data has no `canonical` lane, so that row must print the "정책 없음" token — proving the missing-lane path works before 26 hours of collection depends on it.

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
PY=/home/chahj578/Construction_OODlayer/.venv/bin/python
$PY build_md_report.py --results-dir results_4pol --out-dir /tmp/claude-1035/-home-chahj578/9298bbb7-5381-43e8-b11a-d6bd196d8e9b/scratchpad/art_smoke --oracle-dir oracle/out
grep -c "min SoC" /tmp/claude-1035/-home-chahj578/9298bbb7-5381-43e8-b11a-d6bd196d8e9b/scratchpad/art_smoke/REPORT.md
grep -m2 "canonical" /tmp/claude-1035/-home-chahj578/9298bbb7-5381-43e8-b11a-d6bd196d8e9b/scratchpad/art_smoke/REPORT.md
```

Expected: exit 0; `min SoC` appears once per case block; the `canonical` rows read `정책 없음 (case 데이터에 canonical 미포함)`. Write to the scratchpad, **not** to `artifacts_4pol/` — that directory still holds the n=5 artifacts the baseline comparison needs.

- [ ] **Step 12: Commit**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/build_final_table.py wm4spacecraft_manufacturing/build_md_report.py \
        wm4spacecraft_manufacturing/test_four_lane_table.py wm4spacecraft_manufacturing/test_report_sample_size.py
git commit -m "feat(report): 4 lanes / 6 pairs / E5 min-SoC endpoint, oracle time+SoC marked not-runnable"
```

---

## Task 4: Smoke run — prove `canonical` actually enacts before spending 26 hours

One seed, one cheap case, four lanes: ~10 minutes. Its only job is to answer "does the `canonical` lane enact rule decisions, or does it silently fall back?" — because `policy.jl:519` contains a `canonical` fallback path, and a fallback that fires everywhere would produce a full 26-hour sweep of four lanes where two are secretly identical.

**Files:**
- Create (transient): `/tmp/claude-1035/-home-chahj578/9298bbb7-5381-43e8-b11a-d6bd196d8e9b/scratchpad/smoke_4lane/`

**Interfaces:**
- Consumes: the `run_4pol.sh` CLI from Task 2.
- Produces: nothing committed. A go/no-go decision for Tasks 5–6.

- [ ] **Step 1: Start the DSPy service with the seed-only program**

```bash
cd /home/chahj578/Construction_OODlayer
DSPY_PROGRAM=__seed_only__ .venv/bin/python -m uvicorn src.respec.llm_service.server:app \
  --host 127.0.0.1 --port 8090 > /tmp/claude-1035/-home-chahj578/9298bbb7-5381-43e8-b11a-d6bd196d8e9b/scratchpad/dspy_8090.log 2>&1 &
sleep 20
curl -s http://127.0.0.1:8090/health | .venv/bin/python -m json.tool
```

Expected: `"program"` containing `__seed_only__`. If it reports `dspy_real_program_gpt4o.json`, `DSPY_PROGRAM` did not reach the process — fix that before continuing. The compiled program has battery-only vocabulary and would measure out-of-vocabulary events on every zone case.

- [ ] **Step 2: Run one seed × four lanes on `battery`**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
SMOKE=/tmp/claude-1035/-home-chahj578/9298bbb7-5381-43e8-b11a-d6bd196d8e9b/scratchpad/smoke_4lane
mkdir -p "$SMOKE"
DSPY_URL=http://127.0.0.1:8090 /home/chahj578/Construction_OODlayer/.venv/bin/python llm_ood_eval.py run \
  --seeds 1 --policies noop,canonical,surrogate,dspy \
  --out "$SMOKE/battery.jsonl" --case battery --dspy-url http://127.0.0.1:8090 --router 0
```

Expected: `=== 4 runs (1 seeds x 4 policies), STRICTLY SEQUENTIAL ===`, then four `ok` lines. ~10 min total (battery is the cheapest case at ~144 s/board).

- [ ] **Step 3: Verify the canonical lane enacted rule decisions and is not a `noop` clone**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python - <<'EOF'
import json
SMOKE = "/tmp/claude-1035/-home-chahj578/9298bbb7-5381-43e8-b11a-d6bd196d8e9b/scratchpad/smoke_4lane"
rows = {json.loads(l)["policy"]: json.loads(l) for l in open(SMOKE + "/battery.jsonl")}
print("lanes present:", sorted(rows))
for p in ("noop", "canonical", "surrogate", "dspy"):
    r = rows.get(p)
    if r is None:
        print("  %-10s MISSING" % p); continue
    ds = r.get("decisions") or []
    enacted = [d.get("enacted") for d in ds]
    rule = [d.get("rule") for d in ds]
    b = r.get("battery") or {}
    print("  %-10s complete=%-5s sim_s=%-7.1f min_soc=%-6.3f J/closed=%-7.1f n_dec=%d"
          % (p, r.get("complete"), r.get("sim_seconds") or -1, b.get("min_soc") or -1,
             b.get("energy_per_closed") or -1, len(ds)))
    print("               enacted=%s" % enacted)
    print("               rule   =%s" % rule)
EOF
```

Two things must hold:
1. **`canonical`'s `enacted` values track its `rule` values** — the lane is enacting the rule table, not falling back to nothing. (`enacted` is lowercase, `rule` is CamelCase, e.g. `enacted="replace"` vs `rule="Replace"`; compare case-insensitively.)
2. **`canonical`'s `enacted` list differs from `noop`'s** on at least one decision. If they are identical, the rule table chose NOOP everywhere on this seed — try `--case fault` before concluding the lane is broken, since `fault` is where the rule table most clearly diverges (the n=5 data shows `rule="Replace"` on every `FaultTruth` event while `noop` enacted `noop`).

Also confirm all three metrics are non-null for every lane: `sim_seconds`, `min_soc`, `energy_per_closed`. If any lane reports `min_soc=None`, stop — the SoC endpoint would be silently empty for that lane across all 560 boards.

- [ ] **Step 4: Record the smoke result, then delete the smoke data**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
mkdir -p _night
{
  echo "# smoke 4lane $(date -Iseconds)"
  echo "git_commit: $(git rev-parse HEAD)"
  echo "verdict: canonical lane enacts rule decisions and differs from noop  # 실제 결과로 대체할 것"
} >> _night/smoke_4lane.txt
rm -rf /tmp/claude-1035/-home-chahj578/9298bbb7-5381-43e8-b11a-d6bd196d8e9b/scratchpad/smoke_4lane
```

The smoke data is deleted deliberately: it is seed 1 of `battery` at `world_seed` 1, i.e. exactly a board the real sweep will produce, and leaving it where `--resume` might count it would corrupt the row count.

- [ ] **Step 5: Commit the smoke record**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/_night/smoke_4lane.txt
git commit -m "test(4pol): smoke-verify canonical lane enacts rule decisions before the 26h sweep"
```

**Gate:** do not start Task 5 unless both conditions in Step 3 held. A `canonical` lane that mirrors `noop` makes 140 of the 560 boards worthless.

---

## Task 5: Session A sweep — the four cheap cases (320 boards, ~13.9 h)

**Files:**
- Modify (data): `wm4spacecraft_manufacturing/results_4pol/{battery,fault,zone,battery_zone}.jsonl`
- Modify (data): `wm4spacecraft_manufacturing/_night/status_4pol.jsonl`

**Interfaces:**
- Consumes: `run_4pol.sh` from Task 2; the smoke gate from Task 4.
- Produces: 80 rows per case, each row carrying `complete`, `sim_seconds`, and `battery.{min_soc,energy_per_closed}` for all four lanes.

- [ ] **Step 1: Archive the n=5 results out of the way**

`run_4pol.sh` gate P6 refuses to start on a non-empty `results_4pol/` without `--resume`, and `--resume` would treat the existing 15-row files as partial 80-row files. The n=5 rows are 3-lane and cannot be mixed with 4-lane rows in one file.

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
mv results_4pol results_n5_3lane
mv artifacts_4pol artifacts_n5_3lane
ls results_n5_3lane/*.jsonl | wc -l     # expect 8
```

`baseline_n5/` already holds the frozen artifacts; these two moves preserve the raw rows as well, which Task 8 needs.

- [ ] **Step 2: Confirm the DSPy service is up with the seed-only program**

```bash
curl -s http://127.0.0.1:8090/health | /home/chahj578/Construction_OODlayer/.venv/bin/python -m json.tool
```

Expected: HTTP 200 and `"program"` containing `__seed_only__`. If the service died since Task 4, restart it exactly as in Task 4 Step 1. Gate P1/P2 will refuse to run without it — which is correct, but you would rather find out now than after a `pgrep` wait.

- [ ] **Step 3: Launch session A**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
nohup bash run_4pol.sh \
  --seeds 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20 \
  --policies noop,canonical,surrogate,dspy \
  --cases battery,fault,zone,battery_zone \
  --deadline-seconds 58000 \
  > _night/sessionA.log 2>&1 &
echo "pid=$!"
```

The deadline is the padded cost of exactly these four cases at 4 lanes × 20 seeds (165+180+190+190 = 725 s/board-set × 80 = 58000 s). Measured expectation is ~13.9 h; the guard exists so that if a case runs long, the *last* case is skipped explicitly and recorded rather than the run being killed mid-board.

- [ ] **Step 4: Verify the run started correctly, then leave it alone**

```bash
sleep 120
head -20 /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/_night/sessionA.log
```

Expected: six `[gate] Pn OK` lines, `[cfg] seeds=20 policies=4 ... expected rows/case=80`, then `=== [battery] 시작 (est=13200s, remaining=...) ===`. If any gate failed, the log says which one — fix and relaunch. Do **not** run anything else that spawns Julia while this is running; gate P5 protects the start of the run, not its middle.

- [ ] **Step 5: On completion, verify row counts and metric completeness**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
tail -15 _night/sessionA.log
/home/chahj578/Construction_OODlayer/.venv/bin/python - <<'EOF'
import json, glob
for f in sorted(glob.glob("results_4pol/*.jsonl")):
    rows = [json.loads(l) for l in open(f)]
    lanes = sorted({r["policy"] for r in rows})
    seeds = sorted({r["ood_seed"] for r in rows})
    miss_t = sum(1 for r in rows if r.get("complete") and r.get("sim_seconds") is None)
    miss_s = sum(1 for r in rows if ((r.get("battery") or {}).get("min_soc")) is None)
    miss_e = sum(1 for r in rows if ((r.get("battery") or {}).get("energy_per_closed")) is None)
    print("%-16s rows=%3d lanes=%d seeds=%2d  missing: time=%d soc=%d energy=%d"
          % (f, len(rows), len(lanes), len(seeds), miss_t, miss_s, miss_e))
    assert lanes == ["canonical", "dspy", "noop", "surrogate"], lanes
EOF
```

Expected: `rows=80 lanes=4 seeds=20` for all four cases, and `missing: time=0 soc=0 energy=0`. A non-zero missing count on any metric means that metric is unusable for that case — record it, do not paper over it.

- [ ] **Step 6: Commit the session A data**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/results_4pol wm4spacecraft_manufacturing/_night/status_4pol.jsonl \
        wm4spacecraft_manufacturing/_night/sessionA.log wm4spacecraft_manufacturing/_night/provenance_4pol.json
git commit -m "data(4pol): session A -- battery/fault/zone/battery_zone at 20 seeds x 4 lanes (320 boards)"
```

---

## Task 6: Session B sweep — the three expensive cases (240 boards, ~12.8 h)

**Files:**
- Modify (data): `wm4spacecraft_manufacturing/results_4pol/{fault_zone,fault_battery,all}.jsonl`

**Interfaces:**
- Consumes: `run_4pol.sh` with `--resume` (session A's four case files are already complete and must not be re-run).
- Produces: all seven case files at 80 rows each — the complete input for Tasks 7–9.

- [ ] **Step 1: Restart the DSPy service if needed and confirm the program identity**

```bash
curl -s http://127.0.0.1:8090/health | /home/chahj578/Construction_OODlayer/.venv/bin/python -m json.tool
```

Expected: `"program"` containing `__seed_only__`. If it was restarted between sessions, note that `_night/provenance_4pol.json` is overwritten by gate P2 on each launch — Task 9 must confirm both sessions used the same program, so copy the session A file aside first:

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
cp _night/provenance_4pol.json _night/provenance_sessionA.json
```

- [ ] **Step 2: Launch session B with `--resume`**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
nohup bash run_4pol.sh --resume \
  --seeds 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20 \
  --policies noop,canonical,surrogate,dspy \
  --cases battery,fault,zone,battery_zone,fault_zone,fault_battery,all \
  --deadline-seconds 53200 \
  > _night/sessionB.log 2>&1 &
echo "pid=$!"
```

All seven cases are listed deliberately. With `--resume` and the Task 2 fix, the four session-A cases have 80 rows ≥ `EXPECTED_ROWS` and are reported `resumed` without running a board — which is also a *verification* that session A really produced 80 rows, since a short file would silently be re-run instead. The deadline is the padded cost of the three remaining cases (205+215+245 = 665 × 80 = 53200 s).

- [ ] **Step 3: Verify the resume skipped exactly the right four cases**

```bash
sleep 120
grep "STATUS 4pol" /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/_night/sessionB.log
```

Expected within the first two minutes: `STATUS 4pol battery resumed rows=80`, and the same for `fault`, `zone`, `battery_zone`. Then `=== [fault_zone] 시작 ... ===`. If any session-A case says `시작` instead of `resumed`, its file is short — kill the run, investigate, and do not let it overwrite good data.

- [ ] **Step 4: On completion, verify all seven cases**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
tail -20 _night/sessionB.log
/home/chahj578/Construction_OODlayer/.venv/bin/python - <<'EOF'
import json, glob
CASES = ["battery", "fault", "zone", "battery_zone", "fault_zone", "fault_battery", "all"]
total = 0
for c in CASES:
    rows = [json.loads(l) for l in open("results_4pol/%s.jsonl" % c)]
    total += len(rows)
    lanes = sorted({r["policy"] for r in rows})
    dup = len(rows) - len({(r["ood_seed"], r["policy"]) for r in rows})
    print("%-14s rows=%3d lanes=%s dup=%d" % (c, len(rows), lanes, dup))
print("total boards =", total, "(expect 560)")
EOF
```

Expected: seven lines of `rows=80`, `dup=0`, `total boards = 560`.

- [ ] **Step 5: Commit the session B data**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/results_4pol wm4spacecraft_manufacturing/_night/status_4pol.jsonl \
        wm4spacecraft_manufacturing/_night/sessionB.log wm4spacecraft_manufacturing/_night/provenance_sessionA.json \
        wm4spacecraft_manufacturing/_night/provenance_4pol.json
git commit -m "data(4pol): session B -- fault_zone/fault_battery/all; 560 boards complete at 4 lanes x 20 seeds"
```

---

## Task 7: Build the slide-shaped three-metric grid

The deliverable the slide needs: cases as rows, controllers as columns, three metrics per cell. It reads the case JSONs that `build_md_report.py` wrote — it never recomputes a statistic, because two code paths computing the same number is how a deck and a report come to disagree.

**Files:**
- Create: `wm4spacecraft_manufacturing/build_slide_grid.py`
- Create: `wm4spacecraft_manufacturing/test_slide_grid.py`
- Modify (generated): `wm4spacecraft_manufacturing/artifacts_4pol/{SLIDE_GRID.md,SLIDE_GRID.csv}`

**Interfaces:**
- Consumes: `artifacts_4pol/<case>.json` written by `build_md_report.py`, each containing `policies.<lane>.{n,n_complete,success,sim_seconds_complete,sim_seconds_sd,energy_per_closed,min_soc,n_depleted}` and `holm_adjusted.{e1,e3,e4,e5}`; `build_final_table.{LANES,CASES,NOT_RUNNABLE_TOKEN}`.
- Produces: `cell_text(d) -> str`, `build_grid(artifacts_dir, cases, lanes) -> (md_lines, csv_rows)`.

- [ ] **Step 1: Regenerate the artifacts from the full 560-board data**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
PY=/home/chahj578/Construction_OODlayer/.venv/bin/python
$PY build_md_report.py --results-dir results_4pol --out-dir artifacts_4pol --oracle-dir oracle/out
$PY build_final_table.py --results-dir results_4pol --out-dir artifacts_4pol --oracle-dir oracle/out
ls artifacts_4pol/
grep -m1 "V4" artifacts_4pol/FINAL.md
```

Expected: `V4 [PASS] 판 수 80 (20 seeds x 4 policies) 그대로.` for each case. A `V4 [WARN]` here means the data is not what Task 6 claimed.

- [ ] **Step 2: Write the failing test**

Create `wm4spacecraft_manufacturing/test_slide_grid.py`:

```python
"""test_slide_grid.py -- 슬라이드 격자가 통계를 재계산하지 않고, 결측을 숫자로 위장하지 않는다.

실행: /home/chahj578/Construction_OODlayer/.venv/bin/python test_slide_grid.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import build_slide_grid as BSG
import build_final_table as BFT

FAILED = 0


def check(name, ok, detail=""):
    global FAILED
    print("  %s  %s   %s" % ("PASS" if ok else "FAIL", name, detail))
    if not ok:
        FAILED += 1


print("== 슬라이드 격자 계약 ==")

full = {"n": 20, "n_complete": 17, "sim_seconds_complete": 61.2, "sim_seconds_sd": 4.1,
        "energy_per_closed": 705.5, "min_soc": 0.412, "n_depleted": 0.0}
txt = BSG.cell_text(full)
check("완주율이 분수로 들어간다", "17/20" in txt, txt)
check("빌드 시간이 표준편차와 함께 들어간다", "61.2" in txt and "4.1" in txt, txt)
check("SoC 가 들어간다", "0.412" in txt, txt)

zero = dict(full, n_complete=0, sim_seconds_complete=None, sim_seconds_sd=None)
tz = BSG.cell_text(zero)
check("완주 0 이면 시간이 '정의 불가'다", "완주 0" in tz, tz)
check("완주 0 이어도 SoC 는 보고된다", "0.412" in tz, tz)

check("결측 lane 은 숫자를 만들지 않는다", BSG.cell_text(None) == BSG.MISSING_CELL,
      BSG.cell_text(None))

# 오라클 열은 시간/SoC 를 비실행으로 적는다.
oc = BSG.oracle_cell_text({"completion_rate": 1.0, "n_complete": 22, "n": 22})
check("오라클 칸이 비실행 토큰을 쓴다", BFT.NOT_RUNNABLE_TOKEN in oc, oc)

check("lane 목록을 build_final_table 에서 가져온다", BSG.LANES is BFT.LANES)

print()
print("FAILED=%d" % FAILED)
sys.exit(1 if FAILED else 0)
```

- [ ] **Step 3: Run it to verify it fails**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_slide_grid.py
```

Expected: `ModuleNotFoundError: No module named 'build_slide_grid'`.

- [ ] **Step 4: Write `build_slide_grid.py`**

```python
"""build_slide_grid.py -- 슬라이드용 3지표 격자: case(행) x 컨트롤러(열).

실행:
  /home/chahj578/Construction_OODlayer/.venv/bin/python build_slide_grid.py \
      --artifacts-dir artifacts_4pol --out-dir artifacts_4pol

이 스크립트는 **통계를 계산하지 않는다.** build_md_report.py 가 써 놓은 <case>.json 을 읽어
모양만 바꾼다. 숫자를 여기서 다시 계산하면 슬라이드와 리포트가 조용히 갈라지고, 그 어긋남은
아무도 눈치채지 못한 채 인용된다(REPORT.md 표를 손으로 옮겨 적던 시절의 결함).

세 지표(설계된 evaluation metric 그대로):
  ① 완주율            n_complete/n
  ② 총 빌드 시간      sim_seconds_complete ± sd  (완주판만 -- 미완주 판의 steps 는 정지 판정
                      대기 2500 step 을 포함하므로 섞으면 "실패가 빠르다"로 뒤집힌다)
  ③ 배터리 SoC        min_soc (+ J/closed). mean_soc 이 아니라 min_soc 인 이유는 PREREG D3.
"""
import argparse
import csv
import json
import os
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import build_final_table as BFT

LANES = BFT.LANES
MISSING_CELL = "— (lane 없음)"
UNDEFINED_TIME = "시간: — (완주 0)"

# 슬라이드 열 순서. oracle 은 천장이라 맨 왼쪽에 두고, 실행 lane 은 LANES 순서를 따른다.
CASES = ["battery", "fault", "zone", "battery_zone", "fault_zone", "fault_battery", "all"]

CASE_LABEL = {
    "battery": "Battery depletion",
    "fault": "Robot breakdown",
    "zone": "Keep-out zone",
    "battery_zone": "Battery + zone",
    "fault_zone": "Breakdown + zone",
    "fault_battery": "Breakdown + battery",
    "all": "All three at once",
}

LANE_LABEL = {
    "noop": "NO REPAIR (noop)",
    "canonical": "CANONICAL (rule based)",
    "surrogate": "SURROGATE (random forest)",
    "dspy": "LLM (DSPy)",
}


def cell_text(d):
    """한 칸 = 한 (case, lane). 세 지표를 세 줄로. d 가 None 이면 결측을 결측으로 적는다."""
    if not d:
        return MISSING_CELL
    n, k = d.get("n") or 0, d.get("n_complete") or 0
    lines = ["완주 %d/%d" % (k, n)]
    if d.get("sim_seconds_complete") is None or k == 0:
        lines.append(UNDEFINED_TIME)
    else:
        lines.append("시간 %.1f ± %.1f s" % (d["sim_seconds_complete"], d.get("sim_seconds_sd") or 0.0))
    soc = d.get("min_soc")
    jpc = d.get("energy_per_closed")
    lines.append("minSoC %s · %s J/closed"
                 % ("%.3f" % soc if soc is not None else "—",
                    "%.0f" % jpc if jpc is not None else "—"))
    dep = d.get("n_depleted")
    if dep:
        lines.append("방전 %.1f대/판" % dep)
    return "<br>".join(lines)


def oracle_cell_text(summary):
    """오라클 열. 완주 천장만 있고 시간·SoC 는 측정 불가다(PREREG D5)."""
    if not summary:
        return "%s<br>%s" % (BFT.MISSING_TOKEN, BFT.NOT_RUNNABLE_TOKEN)
    return "완주 %d/%d (천장)<br>시간 %s<br>SoC %s" % (
        summary.get("n_complete") or 0, summary.get("n") or 0,
        BFT.NOT_RUNNABLE_TOKEN, BFT.NOT_RUNNABLE_TOKEN)


def load_case(artifacts_dir, case):
    p = os.path.join(artifacts_dir, "%s.json" % case)
    if not os.path.exists(p):
        return None
    with open(p, encoding="utf-8") as fh:
        return json.load(fh)


def build_grid(artifacts_dir, cases=None, lanes=None):
    cases = cases or CASES
    lanes = lanes or LANES
    header = ["FAILURE CASE"] + [LANE_LABEL.get(l, l) for l in lanes]
    md = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    rows = [header]
    n_seeds_seen = set()
    for case in cases:
        jd = load_case(artifacts_dir, case)
        pols = ((jd or {}).get("policies") or {})
        cells = []
        for lane in lanes:
            d = pols.get(lane)
            if d and d.get("n"):
                n_seeds_seen.add(d["n"])
            cells.append(cell_text(d))
        md.append("| **%s** | %s |" % (CASE_LABEL.get(case, case), " | ".join(cells)))
        rows.append([CASE_LABEL.get(case, case)] +
                    [c.replace("<br>", " · ") for c in cells])
    md.append("")
    md.append("지표: ① 완주율 ② 총 빌드 시간(완주판 sim s, ± sd) ③ 배터리 SoC 하한(min SoC) "
              "및 닫힌 노드당 에너지(J/closed).")
    md.append("")
    md.append("빌드 시간은 **완주한 판만** 평균낸다 -- 미완주 판의 step 수는 정지 판정 대기를 "
              "포함하므로 섞으면 실패가 빠른 것처럼 읽힌다. 그래서 완주 0 인 lane 의 시간은 "
              "0 이 아니라 **정의 불가**다(선택편향: 이 열은 생존자만 비교한다).")
    md.append("")
    md.append("`oracle` 은 실행 가능한 온라인 정책이 아니라 천장이다(policy.jl 에 oracle 분기 없음). "
              "완주 천장만 있고 시간·SoC 는 측정되지 않는다.")
    if n_seeds_seen:
        md.append("")
        md.append("판 수: lane 당 시드 %s개 x %d case x %d lane." %
                  (sorted(n_seeds_seen), len(cases), len(lanes)))
    return md, rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--artifacts-dir", default="artifacts_4pol")
    ap.add_argument("--out-dir", default="artifacts_4pol")
    args = ap.parse_args()
    md, rows = build_grid(args.artifacts_dir)
    out_md = os.path.join(args.out_dir, "SLIDE_GRID.md")
    out_csv = os.path.join(args.out_dir, "SLIDE_GRID.csv")
    with open(out_md, "w", encoding="utf-8") as fh:
        fh.write("# 슬라이드용 3지표 격자 (case x 컨트롤러)\n\n")
        fh.write("\n".join(md) + "\n")
    with open(out_csv, "w", encoding="utf-8", newline="") as fh:
        csv.writer(fh).writerows(rows)
    print("wrote %s" % out_md)
    print("wrote %s" % out_csv)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_slide_grid.py
```

Expected: 7 PASS, `FAILED=0`.

- [ ] **Step 6: Generate the grid and read it**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python build_slide_grid.py \
  --artifacts-dir artifacts_4pol --out-dir artifacts_4pol
cat artifacts_4pol/SLIDE_GRID.md
```

Expected: 7 case rows × 4 lane columns, every cell carrying a completion fraction, a build time (or `— (완주 0)`), and a min-SoC value. Check specifically that `noop` on `fault`/`zone`/`all` shows `시간: — (완주 0)` and not a number — those are the cells where the n=5 data had 0/5 completion.

- [ ] **Step 7: Commit**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/build_slide_grid.py wm4spacecraft_manufacturing/test_slide_grid.py \
        wm4spacecraft_manufacturing/artifacts_4pol
git commit -m "feat(slide): 3-metric case x controller grid (completion, build time, battery SoC)"
```

---

## Task 8: n=5 → n=20 stability comparison

Answers "which n=5 claims survived", restricted to the three lanes the baseline actually contains. `canonical` has no n=5 counterpart and is reported as **NEW**, per prereg §5.

**Files:**
- Create: `wm4spacecraft_manufacturing/compare_seed_scale.py`
- Create (generated): `wm4spacecraft_manufacturing/artifacts_4pol/STABILITY.md`

**Interfaces:**
- Consumes: `baseline_n5/<case>.json` (frozen, 3-lane) and `artifacts_4pol/<case>.json` (new, 4-lane); prereg §5 thresholds.
- Produces: `classify_proportion(old, old_ci, new) -> str`, `classify_continuous(old, new, rel_tol=0.20) -> str`, both returning one of `REPRODUCED`/`ATTENUATED`/`REVERSED`/`NEW`/`정의 불가`.

- [ ] **Step 1: Write the failing test**

Create `wm4spacecraft_manufacturing/test_compare_seed_scale.py`:

```python
"""test_compare_seed_scale.py -- PREREG §5 안정성 판정 규칙이 코드에서 그대로 구현되는지."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import compare_seed_scale as CSS

FAILED = 0


def check(name, ok, detail=""):
    global FAILED
    print("  %s  %s   %s" % ("PASS" if ok else "FAIL", name, detail))
    if not ok:
        FAILED += 1


print("== PREREG §5 안정성 판정 ==")

# 비율: n=20 점추정이 n=5 CI 안 + 같은 방향 -> REPRODUCED
check("CI 안 + 같은 방향 = REPRODUCED",
      CSS.classify_proportion(0.80, (0.55, 0.95), 0.85) == "REPRODUCED")
check("같은 방향 + CI 밖 = ATTENUATED",
      CSS.classify_proportion(0.80, (0.70, 0.95), 0.60) == "ATTENUATED")
check("0.5 를 건너면 REVERSED",
      CSS.classify_proportion(0.80, (0.55, 0.95), 0.30) == "REVERSED")
check("n=5 값이 없으면 NEW", CSS.classify_proportion(None, None, 0.85) == "NEW")

# 연속: REL_TOL = 0.20 이 이 파일에 고정돼 있어야 한다(사후에 바꾸면 사전등록이 아니다).
check("REL_TOL 이 0.20 이다", CSS.REL_TOL == 0.20, repr(CSS.REL_TOL))
check("상대변화 20% 이내 = REPRODUCED", CSS.classify_continuous(600.0, 700.0) == "REPRODUCED")
check("상대변화 20% 초과 = ATTENUATED", CSS.classify_continuous(600.0, 900.0) == "ATTENUATED")
check("연속 지표에 REVERSED 는 없다",
      "REVERSED" not in {CSS.classify_continuous(600.0, 100.0),
                         CSS.classify_continuous(600.0, 1200.0)})
check("한쪽이 None 이면 정의 불가", CSS.classify_continuous(None, 700.0) == "정의 불가")

print()
print("FAILED=%d" % FAILED)
sys.exit(1 if FAILED else 0)
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_compare_seed_scale.py
```

Expected: `ModuleNotFoundError: No module named 'compare_seed_scale'`.

- [ ] **Step 3: Write `compare_seed_scale.py`**

```python
"""compare_seed_scale.py -- n=5(3 lane) -> n=20(4 lane) 안정성 비교.

실행:
  /home/chahj578/Construction_OODlayer/.venv/bin/python compare_seed_scale.py \
      --baseline-dir baseline_n5 --new-dir artifacts_4pol --out artifacts_4pol/STABILITY.md

판정 규칙은 PREREG_SEED20.md §5 에 데이터 수집 **전에** 고정된 것을 그대로 옮긴 것이다.
사후에 여기서 임계값을 바꾸면 사전등록이 아니게 된다 -- REL_TOL 은 상수로 박아 두고,
test_compare_seed_scale.py 가 그 값을 계약으로 검사한다.

`canonical` 은 n=5 baseline 에 존재하지 않는 lane 이므로 전부 NEW 로 보고된다(비교 대상이
없다는 뜻이고, "안정적"이라는 뜻이 아니다).
"""
import argparse
import json
import os
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import build_final_table as BFT

REL_TOL = 0.20          # PREREG §5, 데이터 전에 고정
BASELINE_LANES = ["noop", "surrogate", "dspy"]   # n=5 가 실제로 담고 있는 lane


def classify_proportion(old, old_ci, new):
    """비율 지표(완주율, 결정 적중률). PREREG §5 그대로."""
    if old is None or new is None:
        return "NEW"
    same_dir = (old >= 0.5) == (new >= 0.5)
    if not same_dir:
        return "REVERSED"
    if old_ci and old_ci[0] <= new <= old_ci[1]:
        return "REPRODUCED"
    return "ATTENUATED"


def classify_continuous(old, new, rel_tol=REL_TOL):
    """연속 지표(J/closed, 빌드 시간, min SoC). CI 가 없으니 상대변화로 본다.
    REVERSED 는 정의하지 않는다 -- 줄/초로 재는 양에 '0.5 기준 방향'은 무의미하다."""
    if old is None or new is None:
        return "정의 불가"
    if old == 0:
        return "정의 불가"
    return "REPRODUCED" if abs(new - old) / abs(old) <= rel_tol else "ATTENUATED"


def load(d, case):
    p = os.path.join(d, "%s.json" % case)
    if not os.path.exists(p):
        return None
    with open(p, encoding="utf-8") as fh:
        return json.load(fh)


METRICS = [
    ("완주율", "success", "success_ci", classify_proportion),
    ("결정 적중률", "decision_rate", "decision_ci", classify_proportion),
    ("J/closed", "energy_per_closed", None, classify_continuous),
    ("빌드 시간", "sim_seconds_complete", None, classify_continuous),
    ("min SoC", "min_soc", None, classify_continuous),
]


def compare(baseline_dir, new_dir, cases):
    lines = ["# n=5 -> n=20 안정성 (PREREG §5 규칙)", "",
             "판정 규칙은 데이터 수집 전에 PREREG_SEED20.md §5 에 고정된 것이다. "
             "연속 지표의 REL_TOL = %.2f." % REL_TOL, "",
             "`canonical` lane 은 n=5 baseline 에 없다 -- 전부 NEW 이며, 이는 "
             "'안정적'이 아니라 '비교 대상이 없다'는 뜻이다.", "",
             "| case | lane | 지표 | n=5 | n=20 | 판정 |", "|---|---|---|---|---|---|"]
    counts = {}
    for case in cases:
        old_jd, new_jd = load(baseline_dir, case), load(new_dir, case)
        if new_jd is None:
            lines.append("| %s | — | — | — | — | 신규 데이터 없음 |" % case)
            continue
        for lane in BFT.LANES:
            o = ((old_jd or {}).get("policies") or {}).get(lane)
            n = ((new_jd or {}).get("policies") or {}).get(lane)
            for label, key, ci_key, fn in METRICS:
                ov = (o or {}).get(key)
                nv = (n or {}).get(key)
                oci = (o or {}).get(ci_key) if ci_key else None
                if lane not in BASELINE_LANES:
                    verdict = "NEW"
                elif fn is classify_proportion:
                    verdict = fn(ov, oci, nv)
                else:
                    verdict = fn(ov, nv)
                counts[verdict] = counts.get(verdict, 0) + 1
                fmt = (lambda v: "—" if v is None else
                       ("%.3f" % v if abs(v) < 10 else "%.1f" % v))
                lines.append("| %s | `%s` | %s | %s | %s | %s |"
                             % (case, lane, label, fmt(ov), fmt(nv), verdict))
    lines += ["", "## 판정 집계", ""]
    for k in sorted(counts):
        lines.append("- %s: %d" % (k, counts[k]))
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline-dir", default="baseline_n5")
    ap.add_argument("--new-dir", default="artifacts_4pol")
    ap.add_argument("--out", default="artifacts_4pol/STABILITY.md")
    args = ap.parse_args()
    cases = ["battery", "fault", "zone", "battery_zone", "fault_zone", "fault_battery", "all"]
    lines = compare(args.baseline_dir, args.new_dir, cases)
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    print("wrote %s" % args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_compare_seed_scale.py
```

Expected: 9 PASS, `FAILED=0`.

- [ ] **Step 5: Generate the stability report**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python compare_seed_scale.py \
  --baseline-dir baseline_n5 --new-dir artifacts_4pol --out artifacts_4pol/STABILITY.md
tail -12 artifacts_4pol/STABILITY.md
```

Expected: a verdict tally. Every `canonical` row must read `NEW`.

- [ ] **Step 6: Commit**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/compare_seed_scale.py \
        wm4spacecraft_manufacturing/test_compare_seed_scale.py \
        wm4spacecraft_manufacturing/artifacts_4pol/STABILITY.md
git commit -m "feat(report): n=5 -> n=20 stability comparison under frozen PREREG §5 rules"
```

---

## Task 9: Write the conclusion and the slide-replacement numbers

**Files:**
- Create: `wm4spacecraft_manufacturing/md/RESULTS_3METRIC_20SEED.md`
- Modify: `wm4spacecraft_manufacturing/md/STATUS.md`

**Interfaces:**
- Consumes: `artifacts_4pol/{REPORT.md,FINAL.md,SLIDE_GRID.md,STABILITY.md,<case>.json}`, `_night/provenance_{sessionA,4pol}.json`, `PREREG_SEED20.md` §8.
- Produces: the document to cite; nothing downstream reads it.

- [ ] **Step 1: Verify both sessions used the same DSPy program**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
for f in _night/provenance_sessionA.json _night/provenance_4pol.json; do
  echo -n "$f: "; /home/chahj578/Construction_OODlayer/.venv/bin/python -c \
    "import json,sys; print(json.load(open('$f')).get('program'))"
done
```

Expected: both print the same `__seed_only__` program. If they differ, the two sessions are not one experiment — record that as a limitation in Step 3 rather than hiding it.

- [ ] **Step 2: Pull the Holm-adjusted results for the three metrics**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python - <<'EOF'
import json
jd = json.load(open("artifacts_4pol/battery.json"))
holm = jd.get("holm_adjusted") or {}
for ep in ("e1", "e3", "e4", "e5"):
    fam = holm.get(ep) or {}
    sig = {k: v for k, v in fam.items() if v is not None and v < 0.05}
    print("%s: family=%d  Holm-significant=%d" % (ep, len(fam), len(sig)))
    for k in sorted(sig, key=lambda k: sig[k])[:10]:
        print("    %-40s p_adj=%.4g" % (k, sig[k]))
EOF
```

Expected: each family reports 42. Record which pairs survive Holm for E1 (success), E4 (build time), and E5 (SoC) — those three are the slide's claims.

- [ ] **Step 3: Write the conclusion document**

Create `wm4spacecraft_manufacturing/md/RESULTS_3METRIC_20SEED.md` with these sections, filling every number from the artifacts (never retyped from memory, never from the old slide):

```markdown
# 3지표 평가 -- 7 failure case x 4 컨트롤러 x 20 시드 (2026-08-11)

## 0. 한 문장
[측정 결과 한 문장. 세 지표를 각각 언급하고, 어느 것이 Holm 보정 후에도 유의했는지 명시한다.]

## 1. 이 문서가 재는 것 / 재지 않는 것
- 잰다: 완주율(E1), 총 빌드 시간(E4, 완주판만), 배터리 SoC 하한(E5) + J/closed(E3), 결정 적중률(E2)
- 재지 않는다: 레이아웃 일반화(world_seed=1 고정) · oracle 의 시간/SoC(실행 불가 정책)
  · root-covered zone(PREREG §7)

## 2. 3지표 격자
[artifacts_4pol/SLIDE_GRID.md 를 그대로 인용. 손으로 옮겨 적지 않는다.]

## 3. 지표별 판정 (Holm 보정 후, 족 42 검정)
| endpoint | 유의한 쌍 | 천장/정의 불가로 검정 불가한 셀 |
[artifacts_4pol/*.json 의 holm_adjusted 에서 채운다.]

## 4. canonical(규칙 기반) lane 을 처음 실제로 집행한 결과
[이 실험 전에는 이 열이 noop 판이었다는 사실과, 실제로 집행했을 때 무엇이 달라졌는지.]

## 5. 빌드 시간의 선택편향 (반드시 읽을 것)
[완주판만 평균낸다는 것, 완주 0 인 lane 은 정의 불가라는 것, 그래서 이 열은 생존자 비교라는 것.]

## 6. n=5 -> n=20 에서 바뀐 결론
[artifacts_4pol/STABILITY.md 의 집계와, 뒤집힌 청구(PREREG §6 C1-C7)를 이름으로 적는다.]

## 7. 재현 절차
[run_4pol.sh 두 세션의 실제 명령줄, DSPY_PROGRAM, git commit, 실측 소요 시간.]
```

- [ ] **Step 4: Verify the document contains no number absent from the artifacts**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
grep -o '[0-9]\+\.[0-9]\+' md/RESULTS_3METRIC_20SEED.md | sort -u > /tmp/claude-1035/-home-chahj578/9298bbb7-5381-43e8-b11a-d6bd196d8e9b/scratchpad/doc_nums.txt
cat artifacts_4pol/*.md artifacts_4pol/*.json | grep -o '[0-9]\+\.[0-9]\+' | sort -u > /tmp/claude-1035/-home-chahj578/9298bbb7-5381-43e8-b11a-d6bd196d8e9b/scratchpad/art_nums.txt
comm -23 /tmp/claude-1035/-home-chahj578/9298bbb7-5381-43e8-b11a-d6bd196d8e9b/scratchpad/doc_nums.txt /tmp/claude-1035/-home-chahj578/9298bbb7-5381-43e8-b11a-d6bd196d8e9b/scratchpad/art_nums.txt
```

Expected: empty output, apart from numbers that are legitimately new (elapsed hours, dates, commit counts). Any decimal in the prose that is not in an artifact is a hand-copied number — the exact defect the repo's constraints exist to prevent. Fix it by quoting the artifact.

- [ ] **Step 5: Run the full regression suite one final time**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
PY=/home/chahj578/Construction_OODlayer/.venv/bin/python
for t in test_stats_paired.py test_report_sample_size.py test_run_4pol_lanes.py \
         test_four_lane_table.py test_slide_grid.py test_compare_seed_scale.py \
         test_surrogate_support.py; do
  echo "--- $t"; $PY $t; echo "rc=$?"
done
$PY audit_action_vocab.py; echo "rc=$?"
```

Expected: every `rc=0`. Report the actual output — if one fails, say which and why rather than reporting the task complete.

- [ ] **Step 6: Update `STATUS.md` and commit**

Add a dated entry to `md/STATUS.md` naming the new document, the 560-board dataset, the two session logs, and the fact that `canonical` is now a measured lane. Then:

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/md/RESULTS_3METRIC_20SEED.md wm4spacecraft_manufacturing/md/STATUS.md
git commit -m "docs: 3-metric conclusion at 20 seeds x 4 lanes (success, build time, battery SoC)"
```

---

## Risk register

| Risk | Signal | Response |
|---|---|---|
| `canonical` silently falls back and mirrors `noop` | Task 4 Step 3 shows identical `enacted` lists | Retry on `--case fault`; if still identical, `canonical` is not a distinct lane on this vocabulary — stop and report rather than collecting 140 duplicate boards. |
| DSPy service dies mid-session | `run_s*_dspy.log` shows connection refused; `policy.jl:377` warns and falls back to canonical | The `dspy` lane silently becomes `canonical`. Grep every dspy log for "DSPy service unreachable" **before** trusting the data; re-run affected boards. |
| Another Julia process starts mid-sweep | Gate P5 only guards the start | Do not run any Julia during Tasks 5–6. If it happened, the affected case's HiGHS schedules differ — discard and re-run that case. |
| Deadline guard skips a case | `STATUS 4pol <case> skipped` in the log | Re-launch with `--resume` and a larger `--deadline-seconds`. Skips are recorded, not silent — but they are only visible if you read the summary. |
| `min_soc` is null for a lane | Task 5 Step 5 reports `soc>0` | E5 is unusable for that case; report it as unmeasured rather than dropping the case quietly. |
| Two sessions used different DSPy programs | Task 9 Step 1 prints differing `program` | Record as a limitation; the two sessions are not one experiment for the `dspy` lane. |
| n=5 and n=20 artifacts get mixed | `V4 [WARN]` or `dup>0` | `results_n5_3lane/` and `artifacts_n5_3lane/` are the 3-lane past; `results_4pol/` is 4-lane only. Never merge them. |

## Out of scope (deliberately)

- **A runnable oracle lane.** Prereg D5. Would require new `policy.jl` code for per-event a\* enactment and would re-score every comparison.
- **`world_seed` variation.** Layout generalization stays unclaimed.
- **The `reference_policy.py` zone defect** (REPORT §3-B). Reported, not fixed — fixing it re-scores E2 everywhere.
- **Reusing a warm Julia process** to cut the ~26 h. Rejected: it changes HiGHS/RNG continuity across boards and breaks comparability with `baseline_n5/`.
- **`zonecore`.** A proven duplicate of `zone` (`run_demo.jl:433`).
