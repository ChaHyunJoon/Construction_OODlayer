# 20-Seed Verification of the 4-Policy OOD Report — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-run the 4-policy OOD sweep at `ood_seed` 1–20 (up from 5) across 7 cases, and determine — under a pre-registered analysis — which claims in `artifacts_4pol/REPORT.md` survive the larger sample and which were artifacts of n=5.

**Architecture:** No new simulator behavior. The Julia side is untouched. We (a) fix the analysis toolchain so it reports its *actual* sample size instead of hardcoded "n=5 / p=0.062" strings, (b) add the paired statistics the larger sample makes possible (Wilcoxon on continuous endpoints, cluster-robust CIs on decision fidelity, Holm correction across the 21 pairwise tests), (c) pre-register the analysis before any data is collected, then (d) run 420 boards sequentially overnight and compare against the frozen n=5 baseline.

**Tech Stack:** Python 3 (`.venv`, numpy 2.4.6, scipy 1.18.0), bash, Julia 1.10 LTS (invoked, not modified), DSPy service on uvicorn.

---

## Global Constraints

These apply to **every** task. Copied verbatim from the repo's own contracts.

- **Python interpreter is `/home/chahj578/Construction_OODlayer/.venv/bin/python`.** `run_4pol.sh` hardcodes this as `$PY`. Do not use bare `python`.
- **Working directory for all Python analysis tools is `wm4spacecraft_manufacturing/`.** Module-relative paths assume it.
- **Comparison runs must be strictly sequential** (README trap 30). Parallel Julia = different HiGHS schedules = invalid comparison, plus ~2.5 GB/process → OOM. Gate P5 in `run_4pol.sh` enforces "no julia already running"; never bypass it.
- **`world_seed` stays fixed at 1 for this experiment.** This is a deliberate scope decision. The limitation "다른 공장 배치에 대한 일반화는 재지 않는다" must remain in the generated report — do not delete it while editing §7.
- **Never hardcode a sample size, p-value, or seed list into generated report prose.** Every such number must be computed from the loaded rows. This is the single defect class this plan exists to remove.
- **Do not modify `tools/monitor/run_demo.jl`, `tools/monitor/policy.jl`, or `reference_policy.py`.** Changing any of them silently re-scores every number in the report and destroys comparability with the n=5 baseline. The known `reference_policy.py` zone defect (REPORT §3-B) is explicitly **out of scope** and stays reported-not-fixed.
- **There is no pytest in this repo.** `.venv` has numpy 2.4.6 and scipy 1.18.0 only (verified 2026-08-11). Tests follow the existing convention of `test_surrogate_support.py`: a standalone script with a `check(name, ok, detail)` helper that prints `PASS`/`FAIL`, ending in `sys.exit(1 if FAILED else 0)`. Run them as `python test_x.py`, never `python -m pytest`. Do not add pytest as a dependency for this work.
- **Action vocabulary single source of truth is `wm4spacecraft_manufacturing/action_registry.json`.** No literal macro lists.
- **Commit after every task.** Branch: work on `oracle-rebuild-night-2026-08-10` or a new branch off it; never commit directly to `master`.

---

## Background: what we found while scoping (read this first)

Six facts established by direct inspection of the code and data. They drive every task below.

1. **`--world-seed` already exists** (`llm_ood_eval.py:495`, default 1, forwarded as `DEMO_SEED` at `llm_ood_eval.py:98`), but **`run_4pol.sh` never passes it.** So the report's "world_seed 고정(=1)" is a consequence of the runner, not a limitation of the harness. We are keeping it fixed by choice.

2. **`zonecore` and `zone` are the same experiment.** `run_demo.jl:433` does `replace!(skinds, :zonecore => :zone)` whenever `DEMO_OOD_STREAM3=1`, and `llm_ood_eval.py:95` sets `DEMO_OOD_STREAM3="1"` unconditionally. That is why `diff artifacts_4pol/zone.md artifacts_4pol/zonecore.md` is empty. We drop `zonecore` and reclaim its budget. We do **not** fix the rewrite (that would change simulator behavior).

3. **The report hardcodes its own sample size as prose.** `build_md_report.py:649` emits the literal string `"통계적 유의성 없음 -- 시드 5개, 부호검정 최소 p=0.062"`, and `:684` emits `"bash run_4pol.sh --deadline-seconds <N> --seeds 1,2,3,4,5"` with a `# 1) 120 판 스윕` comment. `build_final_table.py:311` hardcodes `"V4 [PASS] 판 수 15 (5 seeds x 3 policies)"`. Regenerating at 20 seeds without fixing these produces a document whose tables say n=20 and whose prose says n=5.

4. **The deadline cost model is calibrated ~2.4× too high.** `run_4pol.sh:unit_price_for_case` charges 150–200 s/board; measured means from `results_4pol/*.jsonl` are 43.9–94.3 s/board (grand mean 67.9 s; 120 boards = 2.26 h actual, versus the "~5h" the script assumed). At `N_SEEDS=20` the stale prices estimate 18.8 h and the per-case deadline guard would start skipping cases that would in fact have finished.

5. **`sign_test` excludes ties** (`ood_sweep_report.py:75-83`). In `battery`, all three policies complete 5/5 → 5 ties → effective n=0 → p=1.000. **More seeds cannot fix a ceiling effect.** Completion rate is degenerate wherever every policy always finishes; the continuous endpoints (J/closed, build time) are where added seeds actually buy power. The plan must state this rather than let a reader infer that 20 seeds will make everything significant.

6. **Decision-fidelity CIs treat nested data as independent.** `shadow_score.py:133` calls `wilson(c, s)` over N=435 *decisions*, but decisions nest within 120 *boards* (~3.6 decisions/board). Wilson on the decision count understates the interval. At 20 seeds this gets worse (~1740 decisions), so a cluster-robust interval is required before the numbers grow.

Additionally, **the DSPy program identity is not recorded.** `dspy_service.py:90` is `PROGRAM = os.environ.get("DSPY_PROGRAM") or _default_program()`, so with `DSPY_PROGRAM` unset the service silently loads the compiled `dspy_real_program_gpt4o.json` — which CLAUDE.md warns is **battery-only vocabulary** and therefore wrong for zone/RelocateBuild measurement. Gate P2 in `run_4pol.sh` checks only `http_code == 200` and throws the body away, so the existing REPORT.md has no record of which program produced it. Task 4 closes this.

---

## Experiment Design (the thing being built)

| Axis | Value | Rationale |
|---|---|---|
| `ood_seed` | 1, 2, …, 20 | 4× the current sample. Sign-test floor drops from p=0.062 to p=1.9e-06. |
| `world_seed` | 1 (fixed) | Scope decision. Layout generalization explicitly not claimed. |
| Cases (7) | `battery`, `fault`, `all`, `fault_battery`, `fault_zone`, `battery_zone`, `zone` | `zonecore` dropped as a proven duplicate of `zone` (fact 2). |
| Policies (3) | `noop`, `surrogate`, `dspy` | Unchanged. `oracle` is a ceiling, not a runnable lane. |
| Boards | 7 × 3 × 20 = **420** | At 67.9 s/board measured → **~7.9 h expected**. |

**Endpoints** (all four selected; primary vs secondary matters for the correction):

| # | Endpoint | Test | Family size | Role |
|---|---|---|---|---|
| E1 | Completion (`complete` bool) | Paired sign test on `(case, ood_seed)`, ties dropped | 21 | **Primary** |
| E2 | Decision fidelity vs a\* | Cluster bootstrap over boards | 21 | Secondary |
| E3 | Energy `J/closed` | Paired Wilcoxon signed-rank | 21 | Secondary |
| E4 | Build time (completed boards only) | Paired Wilcoxon, **selection-bias caveated** | 21 | Secondary |

21 = 7 cases × 3 policy pairs (`noop`↔`surrogate`, `noop`↔`dspy`, `surrogate`↔`dspy`). **Holm–Bonferroni applied within each endpoint family**, not across families.

E4 carries a mandatory caveat: it conditions on `complete == true`, so it compares survivors. Where `noop` completes 0/20, E4 is undefined for that pair and must print "정의 불가 (완주 0)" rather than a number.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `wm4spacecraft_manufacturing/PREREG_SEED20.md` | Create | Frozen analysis plan + the n=5 baseline claims to be checked. Written **before** data. |
| `wm4spacecraft_manufacturing/stats_paired.py` | Create | Paired-statistics primitives: Wilcoxon, cluster bootstrap, Holm. Pure functions, no I/O. |
| `wm4spacecraft_manufacturing/test_stats_paired.py` | Create | Unit tests for the above. |
| `wm4spacecraft_manufacturing/test_report_sample_size.py` | Create | Regression tests proving no hardcoded n=5/p=0.062/15 survives. |
| `wm4spacecraft_manufacturing/run_4pol.sh` | Modify | `--cases` flag, recalibrated cost model, DSPy provenance capture. |
| `wm4spacecraft_manufacturing/build_final_table.py` | Modify | Dynamic V4 board count; wire E3/E4 Wilcoxon + Holm. |
| `wm4spacecraft_manufacturing/build_md_report.py` | Modify | Computed limitations §7 and repro block; Holm columns. |
| `wm4spacecraft_manufacturing/shadow_score.py` | Modify | Cluster-robust CI replacing decision-level Wilson. |
| `wm4spacecraft_manufacturing/compare_seed_scale.py` | Create | n=5 vs n=20 stability report — the actual verification deliverable. |

`stats_paired.py` is deliberately separate from `ood_sweep_report.py`: that file is an entry-point script with a `main()`, and importing more from it widens an already-load-bearing import (`llm_ood_eval.py:46`, `shadow_score.py:28`). New primitives go in a new pure module. We **reuse** `ood_sweep_report.sign_test` and `wilson` rather than reimplementing them.

---

## Task 1: Freeze the n=5 baseline and pre-register the analysis

Nothing here is optional ceremony: without a frozen baseline we cannot later tell "the conclusion changed" from "the file changed". Data collection must not start until this is committed.

**Files:**
- Create: `wm4spacecraft_manufacturing/PREREG_SEED20.md`
- Create: `wm4spacecraft_manufacturing/baseline_n5/` (frozen copy of the n=5 artifacts)

**Interfaces:**
- Produces: `baseline_n5/*.json` — the n=5 per-case stats that `compare_seed_scale.py` (Task 9) reads as its left-hand side.

- [ ] **Step 1: Freeze the current n=5 artifacts**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
mkdir -p baseline_n5
cp artifacts_4pol/*.json artifacts_4pol/*.md baseline_n5/
ls baseline_n5 | wc -l    # expect 27 (8 case .json + 8 case .md + 9 shadow .md + FINAL.md + REPORT.md)
```

- [ ] **Step 2: Record the exact provenance of the baseline**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
{
  echo "# baseline_n5 provenance"
  echo "frozen_at: $(date -Iseconds)"
  echo "git_commit: $(git rev-parse HEAD)"
  echo "results_rows:"
  for f in results_4pol/*.jsonl; do echo "  $(basename $f): $(wc -l < $f)"; done
} > baseline_n5/PROVENANCE.txt
cat baseline_n5/PROVENANCE.txt
```

Expected: 8 files at 15 rows each.

- [ ] **Step 3: Write the pre-registration document**

Create `wm4spacecraft_manufacturing/PREREG_SEED20.md`:

```markdown
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
```

- [ ] **Step 4: Verify the baseline claims are transcribed correctly**

Spot-check three of them against the frozen copy:

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
grep -A6 "case = .battery." baseline_n5/REPORT.md | head -12   # C1, C2
grep "84.4%\|70.6%\|26.2%" baseline_n5/REPORT.md               # C6
grep "435/435" baseline_n5/REPORT.md                           # C7
```

Expected: each grep returns the numbers written into PREREG §6. If any differs, fix PREREG (the frozen file wins, never the other way).

- [ ] **Step 5: Commit**

```bash
git add wm4spacecraft_manufacturing/PREREG_SEED20.md wm4spacecraft_manufacturing/baseline_n5/
git commit -m "test(4pol): freeze n=5 baseline + pre-register 20-seed verification"
```

---

## Task 2: `stats_paired.py` — paired statistics primitives

Pure functions, no file I/O, no argparse. Written test-first.

**Files:**
- Create: `wm4spacecraft_manufacturing/stats_paired.py`
- Test: `wm4spacecraft_manufacturing/test_stats_paired.py`

**Interfaces:**
- Consumes: `ood_sweep_report.sign_test`, `ood_sweep_report.wilson` (reused, not reimplemented).
- Produces:
  - `holm(pvals: list[float]) -> list[float]` — Holm-adjusted p-values, same order as input.
  - `paired_wilcoxon(a: list[float], b: list[float]) -> dict` — keys: `n`, `n_used`, `statistic`, `p`, `median_diff`, `note`.
  - `cluster_bootstrap_ci(clusters: list[list[bool]], reps=10000, seed=0) -> tuple[float, float, float]` — returns `(point, lo, hi)`; resamples *clusters* (boards) with replacement, not individual decisions.
  - `pair_boards(rows: list[dict], a: str, b: str, key: str) -> tuple[list, list]` — extracts seed-matched value lists for policies `a`/`b`.

- [ ] **Step 1: Write the failing tests**

Create `wm4spacecraft_manufacturing/test_stats_paired.py`:

```python
"""test_stats_paired.py -- stats_paired.py 단위 테스트.

실행: /home/chahj578/Construction_OODlayer/.venv/bin/python test_stats_paired.py
이 저장소에는 pytest 가 없다(.venv 에 numpy/scipy 만 있다). test_surrogate_support.py 와
같은 관례를 따른다: check() 로 PASS/FAIL 을 찍고 실패 개수로 종료코드를 낸다.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from stats_paired import holm, paired_wilcoxon, cluster_bootstrap_ci, pair_boards
from ood_sweep_report import wilson

FAILED = 0


def check(name, ok, detail=""):
    global FAILED
    print("  %s  %s   %s" % ("PASS" if ok else "FAIL", name, detail))
    if not ok:
        FAILED += 1


def approx(a, b, tol=1e-9):
    return abs(a - b) <= tol


print("== stats_paired 단위 테스트 ==")

# 정렬해서 조정한 뒤 원래 순서로 되돌려주는지 -- 순서가 뒤바뀌면 p 값이 엉뚱한 검정에 붙는다.
# 0.01*3 은 이 파이썬에서 0.03 과 정확히 같지만, 부동소수 동등성에 의존하지 않는다.
adj = holm([0.04, 0.01, 0.03])
check("holm 입력 순서 보존", len(adj) == 3 and approx(adj[1], 0.03) and approx(adj[2], 0.06)
      and approx(adj[0], 0.06), str(adj))
check("holm 1.0 클램프", holm([0.9, 0.8])[0] == 1.0)
check("holm 빈 입력", holm([]) == [])

r = paired_wilcoxon([10.0, 11, 12, 13, 14, 15], [20.0, 21, 22, 23, 24, 25])
check("wilcoxon 일관된 차이 탐지", r["n_used"] == 6 and r["p"] < 0.05 and r["median_diff"] == -10.0,
      "p=%.5f" % r["p"])

# 전부 동점 -- scipy 가 예외를 던지는 입력. p=1.0 으로 받아내야 한다(천장효과 경로).
r = paired_wilcoxon([1.0, 2.0, 3.0], [1.0, 2.0, 3.0])
check("wilcoxon 전부 동점 -> p=1.0", r["p"] == 1.0 and bool(r["note"]), r["note"])

# None = 그 판이 완주하지 않아 값이 없다(E4 선택편향 경로). 짝 전체를 버린다.
r = paired_wilcoxon([1.0, None, 3.0, 4.0, 5.0, 6.0], [2.0, 5.0, None, 5.0, 6.0, 7.0])
check("wilcoxon None 짝 제거", r["n"] == 6 and r["n_used"] == 4, "n_used=%d" % r["n_used"])

# 같은 판 안의 결정이 완전상관일 때, 군집 부트스트랩 CI 는 결정 단위 Wilson 보다 넓어야 한다.
clusters = [[True] * 5 for _ in range(10)] + [[False] * 5 for _ in range(10)]
point, lo, hi = cluster_bootstrap_ci(clusters, reps=2000, seed=0)
w_lo, w_hi = wilson(50, 100)
check("군집 CI가 결정단위 Wilson보다 넓다", approx(point, 0.5) and (hi - lo) > (w_hi - w_lo),
      "cluster=%.3f wilson=%.3f" % (hi - lo, w_hi - w_lo))
check("군집 CI 빈 입력", cluster_bootstrap_ci([], reps=10, seed=0) == (0.0, 0.0, 0.0))

rows = [
    {"ood_seed": 1, "policy": "a", "v": 1.0},
    {"ood_seed": 1, "policy": "b", "v": 2.0},
    {"ood_seed": 2, "policy": "a", "v": 3.0},   # seed 2 / policy b 없음 -> 짝이 안 맞아 버려진다
]
xa, xb = pair_boards(rows, "a", "b", "v")
check("pair_boards 시드 짝맞춤", xa == [1.0] and xb == [2.0], "%s %s" % (xa, xb))

sys.exit(1 if FAILED else 0)
```

> This exact script was run against a prototype of `stats_paired.py` on 2026-08-11: **9/9 PASS, exit 0**, with the cluster CI measuring 0.401 wide against Wilson's 0.192 (2.1×). The numbers above are observed, not predicted.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_stats_paired.py
```

Expected: FAIL — `ModuleNotFoundError: No module named 'stats_paired'`.

- [ ] **Step 3: Implement `stats_paired.py`**

```python
"""stats_paired.py -- 짝지은 비교용 통계 원시함수 (2026-08-11, 20시드 검증).

이 모듈은 순수 함수만 담는다: 파일 I/O 없음, argparse 없음, 전역 상태 없음.
sign_test / wilson 은 여기서 다시 만들지 않는다 -- ood_sweep_report.py 의 것을 그대로 쓴다.
"""
import os
import sys

import numpy as np
from scipy.stats import wilcoxon as _scipy_wilcoxon

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ood_sweep_report import sign_test, wilson    # noqa: F401,E402  (재수출 -- 재구현 금지)


def holm(pvals):
    """Holm-Bonferroni 조정 p-value. 입력 순서 그대로 돌려준다.

    Bonferroni 처럼 모든 검정에 최대 계수를 곱하지 않는다 -- 순위가 낮은 검정일수록
    작은 계수를 곱하므로 검정력을 덜 잃는다. 단조성(정렬 후 비감소)을 강제한다.
    """
    n = len(pvals)
    if n == 0:
        return []
    order = sorted(range(n), key=lambda i: pvals[i])
    adj = [0.0] * n
    running = 0.0
    for rank, i in enumerate(order):
        val = pvals[i] * (n - rank)
        running = max(running, val)          # 단조성: 앞선 것보다 작아질 수 없다
        adj[i] = min(1.0, running)
    return adj


def paired_wilcoxon(a, b):
    """짝지은 Wilcoxon 부호순위 검정. a[i] 와 b[i] 는 같은 (case, ood_seed) 의 값.

    둘 중 하나라도 None 인 짝은 통째로 버린다 -- E4(완주판만 재는 빌드시간)에서
    한쪽이 완주하지 않으면 그 짝은 정의되지 않는다.
    차이가 전부 0 이면 scipy 가 예외를 던지므로 p=1.0 으로 받아낸다.
    """
    pairs = [(x, y) for x, y in zip(a, b) if x is not None and y is not None]
    n_used = len(pairs)
    out = {"n": len(a), "n_used": n_used, "statistic": None, "p": 1.0,
           "median_diff": None, "note": ""}
    if n_used == 0:
        out["note"] = "정의 불가 (짝 0개)"
        return out
    xa = np.array([p[0] for p in pairs], dtype=float)
    xb = np.array([p[1] for p in pairs], dtype=float)
    d = xa - xb
    out["median_diff"] = float(np.median(d))
    if np.all(d == 0):
        out["note"] = "전부 동점 -- 검정 불가(ceiling)"
        return out
    try:
        res = _scipy_wilcoxon(xa, xb)
        out["statistic"] = float(res.statistic)
        out["p"] = float(res.pvalue)
    except ValueError as e:                  # 표본이 너무 작거나 전부 동점인 경계
        out["note"] = "wilcoxon 실패: %s" % e
    return out


def cluster_bootstrap_ci(clusters, reps=10000, seed=0):
    """군집(=판) 단위 부트스트랩 비율 CI. 반환 (point, lo, hi).

    `clusters` 는 판마다 그 판의 결정별 정오(bool) 리스트다. 결정 하나하나를 독립으로
    보고 Wilson 을 씌우면(shadow_score.py:133 의 기존 방식) 같은 판 안의 결정이 서로
    상관돼 있다는 사실을 무시해 구간이 실제보다 좁게 나온다. 여기서는 결정이 아니라
    **판**을 복원추출한다.
    """
    clusters = [c for c in clusters if len(c) > 0]
    if not clusters:
        return (0.0, 0.0, 0.0)
    n_correct = sum(sum(1 for v in c if v) for c in clusters)
    n_total = sum(len(c) for c in clusters)
    point = n_correct / n_total
    sums = np.array([sum(1 for v in c if v) for c in clusters], dtype=float)
    sizes = np.array([len(c) for c in clusters], dtype=float)
    rng = np.random.default_rng(seed)
    idx = rng.integers(0, len(clusters), size=(reps, len(clusters)))
    boot_num = sums[idx].sum(axis=1)
    boot_den = sizes[idx].sum(axis=1)
    boot = np.where(boot_den > 0, boot_num / np.maximum(boot_den, 1), 0.0)
    return (float(point), float(np.percentile(boot, 2.5)), float(np.percentile(boot, 97.5)))


def pair_boards(rows, a, b, key):
    """같은 ood_seed 에서 정책 a/b 의 `key` 값을 뽑아 (list_a, list_b) 로 돌려준다.

    한쪽 판이 없는 시드는 통째로 버린다 -- 짝이 아닌 것을 짝으로 세면 안 된다.
    """
    idx = {}
    for r in rows:
        idx[(r.get("ood_seed"), r.get("policy"))] = r
    seeds = sorted({r.get("ood_seed") for r in rows if r.get("ood_seed") is not None})
    xa, xb = [], []
    for s in seeds:
        ra, rb = idx.get((s, a)), idx.get((s, b))
        if ra is None or rb is None:
            continue
        xa.append(ra.get(key))
        xb.append(rb.get(key))
    return xa, xb
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_stats_paired.py
```

Expected: exit 0, 9/9 PASS.

- [ ] **Step 5: Commit**

```bash
git add wm4spacecraft_manufacturing/stats_paired.py wm4spacecraft_manufacturing/test_stats_paired.py
git commit -m "feat(stats): paired Wilcoxon, cluster bootstrap CI, Holm correction"
```

---

## Task 3: Make the report tell the truth about its own sample size

This is the defect class from background fact 3. It must land **before** the sweep, so the 20-seed run regenerates honest prose on the first try.

**Files:**
- Modify: `wm4spacecraft_manufacturing/build_final_table.py:50-60` (duplicated §7 limitations), `:305-320` (V4 board count)
- Modify: `wm4spacecraft_manufacturing/build_md_report.py:645-660` (§7 limitations), `:680-690` (repro block)
- Test: `wm4spacecraft_manufacturing/test_report_sample_size.py`

**Interfaces:**
- Consumes: `stats_paired.sign_test` (re-exported in Task 2).
- Produces, **all defined in `build_final_table.py`**:
  - `limitations_lines(boards_by_case: dict) -> list[str]`
  - `repro_lines(n_boards: int, seeds: list[int], cases: list[str]) -> list[str]`
  - `check_v4(boards: list[dict]) -> list[str]`

> **Which module owns the shared text.** `build_md_report.py:46` already does `import build_final_table as BFT`. So the shared helpers must live in `build_final_table.py` (the lower module) and be called as `BFT.limitations_lines(...)` from `build_md_report.py`. Defining them in `build_md_report.py` and importing upward creates a circular import.

- [ ] **Step 1: Write the failing regression tests**

Create `wm4spacecraft_manufacturing/test_report_sample_size.py`:

```python
"""test_report_sample_size.py -- 리포트가 자기 표본 크기를 하드코딩하지 않는다는 회귀 테스트.

실행: /home/chahj578/Construction_OODlayer/.venv/bin/python test_report_sample_size.py

이 파일이 막는 결함: 표는 n=20 을 보여주는데 산문은 "시드 5개, 최소 p=0.062" 라고
적혀 있는 자가당착 문서(2026-08-11 실측: build_final_table.py:55, build_md_report.py:649, :684).
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import build_final_table
import build_md_report

FAILED = 0


def check(name, ok, detail=""):
    global FAILED
    print("  %s  %s   %s" % ("PASS" if ok else "FAIL", name, detail))
    if not ok:
        FAILED += 1


def _boards(n_seeds, policies=("noop", "surrogate", "dspy")):
    return [{"ood_seed": s, "policy": p, "world_seed": 1}
            for s in range(1, n_seeds + 1) for p in policies]


print("== 리포트 표본크기 하드코딩 회귀 테스트 ==")

body = "\n".join(build_final_table.limitations_lines({"battery": _boards(20)}))
check("한계 문구가 실제 시드 수를 쓴다", "시드 5개" not in body and "20" in body)
# n=20 짝이면 부호검정 하한은 2*0.5^20 = 1.9e-06 이다. n=5 의 0.062 가 아니다.
check("부호검정 하한이 계산된 값이다", "0.062" not in body)
# world_seed 는 이번에도 고정이다 -- 이 한계는 지워지면 안 된다.
check("world_seed 한계가 남아 있다", "world_seed" in body)
# 두 빌더가 같은 문구를 각자 들고 있으면 한쪽만 고쳐도 테스트가 통과해버린다.
check("build_md_report 가 단일 진실원에 위임한다",
      build_md_report.BFT.limitations_lines is build_final_table.limitations_lines)

rb = "\n".join(build_final_table.repro_lines(
    420, list(range(1, 21)),
    ["battery", "fault", "all", "fault_battery", "fault_zone", "battery_zone", "zone"]))
# 주의: "--seeds 1,2,3,4,5" 는 20시드 문자열의 **접두사**라 `not in` 으로 검사하면 언제나
# 실패한다(2026-08-11 실측). 정확히 5시드로 끝나는 경우만 잡아야 한다.
check("재현 절차가 실제 시드 목록을 쓴다",
      not re.search(r"--seeds 1,2,3,4,5(?![\d,])", rb)
      and "1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20" in rb
      and "420" in rb)

v4 = "\n".join(build_final_table.check_v4(_boards(20)))
check("V4 기대판수가 동적이다", "PASS" in v4 and "60" in v4 and "15" not in v4, v4)
check("V4 가 판 부족을 잡는다", "WARN" in "\n".join(build_final_table.check_v4(_boards(20)[:-1])))

# 문자열 리터럴로 남은 표본크기 주장을 통째로 금지한다. 두 파일 모두 검사한다 --
# 같은 문장이 양쪽에 복사돼 있어서(2026-08-11 실측) 한쪽만 고치면 샌다.
for fn in ("build_md_report.py", "build_final_table.py"):
    src = open(os.path.join(HERE, fn), encoding="utf-8").read()
    check("%s 에 표본크기 리터럴 없음" % fn,
          "시드 5개" not in src and "0.062" not in src
          and not re.search(r"5 seeds x 3 policies", src))

sys.exit(1 if FAILED else 0)
```

- [ ] **Step 2: Run to verify failure**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_report_sample_size.py
```

Expected: FAIL — `AttributeError: module 'build_final_table' has no attribute 'limitations_lines'`.

- [ ] **Step 3: Add `limitations_lines` to `build_final_table.py`**

Add this function to `build_final_table.py` (the lower module — see the interfaces note above), replacing the hardcoded `items` list at `:50-60`:

```python
def limitations_lines(boards_by_case):
    """§7 한계. 표본 크기 주장은 전부 실제 boards 에서 계산한다 -- 리터럴 금지.

    (2026-08-11) 예전에는 시드 수와 부호검정 하한이 문자열 리터럴이었고, 같은 문장이
    build_final_table.py 와 build_md_report.py **양쪽에** 복사돼 있었다. 시드를 20개로
    늘려 재생성하면 표는 n=20, 산문은 옛 표본크기인 자가당착 문서가 나온다. 그 결함을 여기서 막는다.

    주의: 이 파일은 test_report_sample_size.py 가 소스를 직접 grep 한다. 주석·독스트링에도
    옛 표본크기 문구를 그대로 적지 말 것 -- 적으면 그 회귀 테스트가 실패한다.
    """
    n_seeds_by_case = {c: len({b.get("ood_seed") for b in bs}) for c, bs in boards_by_case.items()}
    n_seeds = min(n_seeds_by_case.values()) if n_seeds_by_case else 0
    # 부호검정 하한: 무승부가 없고 전승/전패일 때의 양측 p = 2 * 0.5^n
    floor_p = 2.0 * (0.5 ** n_seeds) if n_seeds > 0 else 1.0
    floor_str = ("%.3f" % floor_p) if floor_p >= 1e-3 else ("%.1e" % floor_p)

    world_seeds = sorted({b.get("world_seed") for bs in boards_by_case.values()
                          for b in bs if b.get("world_seed") is not None})
    ws = world_seeds[0] if len(world_seeds) == 1 else world_seeds

    items = []
    if n_seeds < 6:
        items.append("통계적 유의성 없음 -- 시드 %d개, 부호검정(sign test) 최소 p=%s "
                     "(짝이 6개 미만이면 양측 p 가 0.05 아래로 내려갈 수 없다)." % (n_seeds, floor_str))
    else:
        items.append("시드 %d개 -- 부호검정 최소 양측 p=%s. 무승부는 검정에서 제외되므로 "
                     "천장효과(모든 정책이 항상 완주)인 case 에서는 시드를 늘려도 "
                     "유의해지지 않는다." % (n_seeds, floor_str))
    items.append("`world_seed` 고정(=%s) -- 다른 공장 배치(레이아웃)에 대한 일반화는 이번에 재지 않는다." % ws)
    items.append("빌드 시간(E4)은 **완주판만** 재므로 선택편향이 있다 -- 완주한 판끼리만 비교하는 것이라, "
                 "완주율이 낮은 정책일수록 살아남은 판만 뽑혀 유리하게 보인다.")
    items.append("shadow 채점은 **상태조건부 결정 충실도**다(\"이 상태에서 이 정책이 a\\* 를 골랐겠는가\"). "
                 "결과 비교가 아니다 -- shadow 숫자로 완주율/시간/에너지 주장을 하면 안 된다.")
    if "zonecore" in boards_by_case and "zone" in boards_by_case:
        items.append("`zone` 과 `zonecore` 는 같은 실험이다 -- `run_demo.jl:433` 이 "
                     "`DEMO_OOD_STREAM3=1` 에서 `:zonecore` 를 `:zone` 으로 바꾼다.")
    return ["## 7. 한계", ""] + ["- %s" % it for it in items] + [""]
```

Update the `build_final_table.py` call site to use it, passing the per-case boards dict already available in that function's scope.

- [ ] **Step 3b: Delete the second copy in `build_md_report.py:649` and delegate**

The same sentence is copy-pasted into **both** report builders. Fixing one leaves the claim alive in the other's output:

```
build_final_table.py:55:    "통계적 유의성 없음 -- 시드 5개, 부호검정(sign test) 최소 p=0.062 (RESULTS_LLM7H.md 와 같은 한계).",
build_md_report.py:649:    "통계적 유의성 없음 -- 시드 5개, 부호검정(sign test) 최소 p=0.062 (`RESULTS_LLM7H.md` 와 같은 한계).",
```

In `build_md_report.py`, delete the literal `items = [...]` list at `:645-660` and delegate to the module it already imports at `:46`:

```python
    L += BFT.limitations_lines(boards_by_case)     # 한계 문구의 단일 진실원 (재구현 금지)
```

Verify there is no import cycle (the direction is `build_md_report` → `build_final_table`, never the reverse):

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python -c "import build_final_table, build_md_report; print('no import cycle')"
grep -c "시드 5개" build_final_table.py build_md_report.py    # expect 0 and 0
```

- [ ] **Step 4: Add `repro_lines` to `build_final_table.py` and use it from `build_md_report.py:684`**

Define it alongside `limitations_lines`, then call it as `BFT.repro_lines(...)` from the report builder:

```python
def repro_lines(n_boards, seeds, cases):
    """재현 절차. 판 수·시드·case 목록을 전부 인자에서 받는다 -- 리터럴 금지."""
    seed_str = ",".join(str(s) for s in seeds)
    case_str = ",".join(cases)
    return [
        "재현 절차:", "",
        "```bash",
        "# 1) %d 판 스윕 (순차, julia 를 내부에서 부른다 -- 다른 julia 와 동시에 돌리지 말 것)" % n_boards,
        "bash run_4pol.sh --deadline-seconds 43200 --seeds %s --cases %s" % (seed_str, case_str),
        "",
        "# 2) 오라클 라벨(fault/zone 축) 재생성 -- julia, 순차 (README 함정 30)",
        "bash run_step_d_all.sh",
        "",
        "# 3) 스윕 산출물을 case별 report/shadow md+json 으로 조립 (순수 파이썬)",
        "python build_final_table.py --results-dir results_4pol --out-dir artifacts_4pol",
        "",
        "# 4) 이 문서 (순수 파이썬, julia 호출 없음, subprocess 없음)",
        "python build_md_report.py --results-dir results_4pol --out-dir artifacts_4pol --oracle-dir oracle/out",
        "```", "",
    ]
```

Update the call site to pass the real values computed from the loaded rows.

- [ ] **Step 5: Make V4 dynamic in `build_final_table.py`**

Replace the hardcoded block at `:305-320` with an extracted function:

```python
def check_v4(boards):
    """V4 -- 판 수가 (시드 수 x 정책 수) 인지. 기대값을 하드코딩하지 않는다.

    (2026-08-11) 예전에는 15 가 리터럴이었다 -- 20시드로 늘리면 60판이 정상인데도
    "판 수 초과" 로 경고해 정상 스윕을 결함처럼 보이게 만든다.
    """
    n_seeds = len({b.get("ood_seed") for b in boards})
    n_pol = len({b.get("policy") for b in boards})
    expected = n_seeds * n_pol
    n = len(boards)
    if n == expected:
        return ["V4 [PASS] 판 수 %d (%d seeds x %d policies) 그대로." % (n, n_seeds, n_pol)]
    if n < expected:
        return ["V4 [WARN] 판 수 부족: 기대 %d (%d seeds x %d policies), 실제 %d."
                % (expected, n_seeds, n_pol, n)]
    return ["V4 [WARN] 판 수 초과: 기대 %d (%d seeds x %d policies), 실제 %d."
            % (expected, n_seeds, n_pol, n)]
```

Update the original call site to delegate to `check_v4(boards)`.

**There are five literal sites, not one.** `grep -n "5 seeds x 3 policies\|판 수 15" build_final_table.py` finds them all (verified 2026-08-11):

```
build_final_table.py:308:    # ---- V4: 행 수 (5 seeds x 3 policies = 15) ----   <- 주석
build_final_table.py:311:        "V4 [PASS] 판 수 15 (5 seeds x 3 policies) 그대로."
build_final_table.py:313:        "V4 [WARN] 판 수 부족: 기대 15 (5 seeds x 3 policies), 실제 %d."
build_final_table.py:315:        "V4 [WARN] 판 수 초과: 기대 15 (5 seeds x 3 policies), 실제 %d "
build_final_table.py:516:    "· V3 빈 board 가 없는지 · V4 판 수가 5 seeds x 3 policies = 15 인지. 아래 각 case 마다 "
```

Line 516 is the §6 V1–V4 preamble prose — a **separate** statement from the V4 check itself, and easy to miss. Rewrite it to describe the rule rather than a fixed number, e.g. `"· V4 판 수가 (시드 수 x 정책 수) 인지."`. The comment at :308 counts too: the regression test greps raw source, so comments and docstrings must not carry the old sample-size wording either.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_report_sample_size.py
```

Expected: exit 0, 9/9 PASS.

- [ ] **Step 7: Confirm the n=5 report still regenerates identically**

The refactor must be behavior-preserving on the existing data (except the intentionally reworded §7).

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python build_final_table.py --results-dir results_4pol --out-dir /tmp/claude-1035/-home-chahj578-Construction-OODlayer/d76aa9d3-3c8f-4726-8f1e-732ada9515c9/scratchpad/regen
/home/chahj578/Construction_OODlayer/.venv/bin/python build_md_report.py --results-dir results_4pol --out-dir /tmp/claude-1035/-home-chahj578-Construction-OODlayer/d76aa9d3-3c8f-4726-8f1e-732ada9515c9/scratchpad/regen --oracle-dir oracle/out
diff <(sed -n '/## 2. 헤드라인/,/## 7/p' baseline_n5/REPORT.md) \
     <(sed -n '/## 2. 헤드라인/,/## 7/p' /tmp/claude-1035/-home-chahj578-Construction-OODlayer/d76aa9d3-3c8f-4726-8f1e-732ada9515c9/scratchpad/regen/REPORT.md)
```

Expected: **empty diff** for §2–§6. If not empty, the refactor changed a number — stop and fix before proceeding. §7 is expected to differ (that is the point).

- [ ] **Step 8: Commit**

```bash
git add wm4spacecraft_manufacturing/build_md_report.py wm4spacecraft_manufacturing/build_final_table.py wm4spacecraft_manufacturing/test_report_sample_size.py
git commit -m "fix(report): compute sample-size claims instead of hardcoding n=5/p=0.062/15"
```

---

## Task 4: Recalibrate the runner's cost model, add `--cases`, capture DSPy provenance

**Files:**
- Modify: `wm4spacecraft_manufacturing/run_4pol.sh`

**Interfaces:**
- Produces: `run_4pol.sh --cases <csv>` flag; `_night/status_4pol.jsonl` rows gain a `program` field; `_night/provenance_4pol.json`.

- [ ] **Step 1: Recalibrate `unit_price_for_case` from measured data**

Measured means (from `results_4pol/*.jsonl`, 120 boards): `all` 94.3 s, `fault_zone` 76.8, `fault_battery` 69.1, `zone` 64.8, `battery_zone` 62.8, `fault` 58.5, `battery` 43.9. Apply a 1.25× safety margin and round up:

```bash
# 2026-08-11 재보정: 예전 값(150/160/200)은 실측의 ~2.4배라 20시드에서 총 18.8h 를 추정,
# 데드라인 가드가 실제로는 끝났을 case 를 건너뛰게 만든다. 아래는 실측 평균 x1.25.
unit_price_for_case() {
    case "$1" in
        all)           echo 120 ;;   # 실측 94.3
        fault_zone)    echo 100 ;;   # 실측 76.8
        fault_battery) echo  90 ;;   # 실측 69.1
        zone)          echo  85 ;;   # 실측 64.8
        battery_zone)  echo  80 ;;   # 실측 62.8
        fault)         echo  75 ;;   # 실측 58.5
        battery)       echo  60 ;;   # 실측 43.9
        *)             echo 120 ;;   # 미지의 case 는 가장 비싼 값으로
    esac
}
```

- [ ] **Step 2: Add the `--cases` flag**

Change the fixed `CASES=(...)` array into a parameterized default, and add the arg parse branch:

```bash
# 기본은 7 case -- zonecore 는 뺐다(run_demo.jl:433 이 :zonecore 를 :zone 으로 바꾸므로 `zone` 과 같은 실험).
CASES_CSV="battery,fault,all,fault_battery,fault_zone,battery_zone,zone"
DEADLINE_SECONDS=43200
```

In the arg loop:

```bash
        --cases)
            CASES_CSV="$2"; shift 2 ;;
```

After the arg loop:

```bash
IFS=',' read -r -a CASES <<< "$CASES_CSV"
```

Delete the old hardcoded `CASES=(battery fault zonecore all fault_battery fault_zone battery_zone zone)` line.

- [ ] **Step 3: Capture DSPy program provenance in gate P2**

Gate P2 currently discards the response body. Replace it so the program identity is recorded — background fact: with `DSPY_PROGRAM` unset the service silently loads the battery-only compiled program.

```bash
# P2 -- 헬스체크 + 프로그램 신원 기록.
# (2026-08-11) 예전엔 http_code 만 봤다. dspy_service.py:90 은 DSPY_PROGRAM 이 비면 컴파일된
# gpt4o 프로그램으로 조용히 폴백하는데, 그건 battery 전용 어휘라 zone 을 재면 어휘 밖을 재게 된다.
# 어느 프로그램으로 쟀는지 남기지 않으면 사후에 알 방법이 없다.
set +e
P2_RESP=$(curl -s -w '\n%{http_code}' "$DSPY_URL/health" 2>/dev/null)
set -e
P2_CODE=$(printf '%s' "$P2_RESP" | tail -n1)
P2_BODY=$(printf '%s' "$P2_RESP" | sed '$d')
if [ "$P2_CODE" != "200" ]; then
    echo "PREREQ FAIL: P2 (health check) -- http_code=$P2_CODE"
    exit 1
fi
mkdir -p "$NIGHT_DIR"
printf '%s\n' "$P2_BODY" > "$NIGHT_DIR/provenance_4pol.json"
DSPY_PROGRAM_USED=$(printf '%s' "$P2_BODY" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("program","?"))' 2>/dev/null || echo "?")
echo "[gate] P2 OK (health check) -- program=$DSPY_PROGRAM_USED"
```

Note: `mkdir -p "$NIGHT_DIR"` must run here because the existing `mkdir` line sits after the gates.

- [ ] **Step 4: Record the program in each status row**

In `emit_status`, add the field:

```bash
emit_status() {
    local c="$1" status="$2" rows="$3" wall="$4"
    printf '{"case":"%s","status":"%s","rows":%d,"wall_seconds":%d,"seeds":"%s","policies":"%s","program":"%s"}\n' \
        "$c" "$status" "$rows" "$wall" "$SEEDS" "$POLICIES" "$DSPY_PROGRAM_USED" >> "$STATUS_FILE"
    echo "STATUS 4pol $c $status rows=$rows"
}
```

- [ ] **Step 5: Verify the script parses and the cost model is sane**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
bash -n run_4pol.sh && echo "SYNTAX OK"
# 20시드 총 추정치가 데드라인 안에 들어가는지 손으로 확인
/home/chahj578/Construction_OODlayer/.venv/bin/python -c "
p={'all':120,'fault_zone':100,'fault_battery':90,'zone':85,'battery_zone':80,'fault':75,'battery':60}
est=sum(v*20*3 for v in p.values())
print('estimated total: %.1f h' % (est/3600))
print('measured actual: %.1f h' % (sum([94.3,76.8,69.1,64.8,62.8,58.5,43.9])*20*3/3600))
print('deadline 43200s = 12.0 h -> headroom OK' if est < 43200 else 'DEADLINE TOO SMALL')
"
```

Expected: `SYNTAX OK`, estimated ~10.2 h, measured ~7.9 h, headroom OK.

- [ ] **Step 6: Commit**

```bash
git add wm4spacecraft_manufacturing/run_4pol.sh
git commit -m "feat(4pol): --cases flag, cost model recalibrated to measured, DSPy provenance recorded"
```

---

## Task 5: Cluster-robust CI for decision fidelity

**Files:**
- Modify: `wm4spacecraft_manufacturing/shadow_score.py:122-140`
- Test: extend `wm4spacecraft_manufacturing/test_stats_paired.py`

**Interfaces:**
- Consumes: `stats_paired.cluster_bootstrap_ci`.
- Produces: shadow markdown gains a `95% CI (군집)` column; the decision-level Wilson column is kept alongside and labelled as such.

- [ ] **Step 1: Write the failing test**

Append to `wm4spacecraft_manufacturing/test_stats_paired.py`:

Insert **before** the closing `sys.exit(1 if FAILED else 0)` line:

```python
# 결정을 판별로 묶는 헬퍼가 판 경계를 지키는지 -- 여기가 틀리면 군집 CI 가 결정 단위 CI 로
# 조용히 되돌아간다(그리고 숫자는 그럴듯해 보인다).
import shadow_score

_scored = [
    {"_board": ("battery", 1, "dspy"), "correct": True},
    {"_board": ("battery", 1, "dspy"), "correct": False},
    {"_board": ("battery", 2, "dspy"), "correct": True},
]
_clusters = shadow_score.group_by_board(_scored)
check("shadow 결정이 판 단위로 묶인다", sorted(len(c) for c in _clusters) == [1, 2],
      str(sorted(len(c) for c in _clusters)))
```

- [ ] **Step 2: Run to verify failure**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_stats_paired.py
```

Expected: FAIL — `AttributeError: module 'shadow_score' has no attribute 'group_by_board'`.

- [ ] **Step 3: Implement grouping and swap in the cluster CI**

Add to `shadow_score.py`:

```python
from stats_paired import cluster_bootstrap_ci     # noqa: E402


def group_by_board(scored):
    """채점된 결정들을 판(board) 단위 군집으로 묶는다. 반환: list[list[bool]].

    `_board` 키가 (case, ood_seed, policy) 를 담는다. 같은 판 안의 결정은 서로 독립이 아니다
    -- 같은 스트림·같은 정책·같은 상태 궤적이다. 그래서 CI 는 결정이 아니라 판을 재표집해야 한다.
    """
    buckets = {}
    for d in scored:
        buckets.setdefault(d.get("_board"), []).append(bool(d.get("correct")))
    return list(buckets.values())
```

In `build_report` (`shadow_score.py:129-134`), keep the Wilson column but add the cluster column and label both honestly:

```python
    L = [..., "| producer | n | 옳은 결정 (Wilson, 결정단위) | 95% CI (군집 부트스트랩, 판단위) |",
         "|---|---|---|---|"]
    for field in PRODUCERS:
        s, c, rows_scored = score_producer(decisions, field)
        lo, hi = wilson(c, s)
        _, clo, chi = cluster_bootstrap_ci(group_by_board(rows_scored), reps=10000, seed=0)
        L.append("| `%s` | %d | %s [%.2f, %.2f] | [%.2f, %.2f] |"
                 % (field, s, fmt(c, s), lo, hi, clo, chi))
```

You must ensure `score_producer` propagates a `_board` key onto each scored decision. `load_rows_and_decisions` (`shadow_score.py:46`) already carries `ood_seed`; extend it to stamp `_board = (case, ood_seed, policy)` when flattening.

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_stats_paired.py
```

Expected: exit 0, 10/10 PASS.

- [ ] **Step 5: Sanity-check on real n=5 data**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python shadow_score.py --in results_4pol/*.jsonl --md /tmp/claude-1035/-home-chahj578-Construction-OODlayer/d76aa9d3-3c8f-4726-8f1e-732ada9515c9/scratchpad/shadow_cluster.md
grep -A6 "producer" /tmp/claude-1035/-home-chahj578-Construction-OODlayer/d76aa9d3-3c8f-4726-8f1e-732ada9515c9/scratchpad/shadow_cluster.md
```

Expected: point estimates unchanged (`llm` 84.4%, `surrogate` 70.6%, `rule` 26.2%), and the cluster interval **wider** than the Wilson interval. If the cluster interval is narrower, grouping is broken — stop and fix.

- [ ] **Step 6: Commit**

```bash
git add wm4spacecraft_manufacturing/shadow_score.py wm4spacecraft_manufacturing/test_stats_paired.py
git commit -m "fix(shadow): cluster-robust CI over boards; decision-level Wilson was too narrow"
```

---

## Task 6: Wire E3/E4 (Wilcoxon) and Holm correction into the case report

**Files:**
- Modify: `wm4spacecraft_manufacturing/build_final_table.py` (per-case stats block)
- Modify: `wm4spacecraft_manufacturing/build_md_report.py` (§5 rendering)

**Interfaces:**
- Consumes: `stats_paired.paired_wilcoxon`, `stats_paired.pair_boards`, `stats_paired.holm`.
- Produces: each case's JSON gains `paired_tests: {pair: {e1_sign_p, e3_wilcoxon_p, e4_wilcoxon_p, e4_note}}`; after all cases are built, `holm_adjusted: {endpoint: {case__pair: p_adj}}` is written into every case JSON.

- [ ] **Step 1: Write the failing test**

Append to `wm4spacecraft_manufacturing/test_report_sample_size.py`:

Insert **before** the closing `sys.exit(1 if FAILED else 0)` line:

```python
_rows = []
for _s in range(1, 21):
    _rows.append({"ood_seed": _s, "policy": "noop", "complete": False,
                  "battery": {"energy_per_closed": 900.0}, "sim_seconds": None})
    _rows.append({"ood_seed": _s, "policy": "dspy", "complete": True,
                  "battery": {"energy_per_closed": 400.0}, "sim_seconds": 25.0})
_out = build_final_table.paired_tests(_rows)
_k = "noop__dspy"
check("case 별 짝검정이 나온다",
      _k in _out                             # 0승 20패 -> 유의 (sign p = 1.9e-06)
      and _out[_k]["e1_sign_p"] < 0.05
      and _out[_k]["e3_wilcoxon_p"] < 0.05   # 에너지 일관되게 낮음
      and bool(_out[_k]["e4_note"]),         # noop 완주 0 -> 빌드시간 정의 불가
      "e1=%.3g e3=%.3g" % (_out[_k]["e1_sign_p"], _out[_k]["e3_wilcoxon_p"]) if _k in _out else "missing")

_fam = {"battery__noop__dspy": 0.01, "fault__noop__dspy": 0.04, "zone__noop__dspy": 0.5}
_adj = build_final_table.holm_family(_fam)
check("Holm 이 case x pair 족 전체에 적용된다",
      abs(_adj["battery__noop__dspy"] - 0.03) < 1e-9      # 0.01 * 3
      and abs(_adj["zone__noop__dspy"] - 0.5) < 1e-9,     # 0.5 * 1
      str(_adj))
```

- [ ] **Step 2: Run to verify failure**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_report_sample_size.py
```

Expected: FAIL — `AttributeError: module 'build_final_table' has no attribute 'paired_tests'`.

- [ ] **Step 3: Implement in `build_final_table.py`**

```python
from stats_paired import paired_wilcoxon, pair_boards, holm, sign_test   # noqa: E402

PAIRS = [("noop", "surrogate"), ("noop", "dspy"), ("surrogate", "dspy")]


def _energy(r):
    return ((r or {}).get("battery") or {}).get("energy_per_closed")


def _time_if_complete(r):
    """E4 는 완주판만 잰다 -- 완주하지 않은 판은 None(짝에서 탈락). 이게 곧 선택편향의 출처다."""
    return r.get("sim_seconds") if r.get("complete") else None


def paired_tests(rows):
    """case 하나의 판들에 대해 3개 정책쌍 x E1/E3/E4 검정. 반환 {"a__b": {...}}."""
    out = {}
    for a, b in PAIRS:
        ca, cb = pair_boards(rows, a, b, "complete")
        w = sum(1 for x, y in zip(ca, cb) if bool(x) and not bool(y))
        l = sum(1 for x, y in zip(ca, cb) if not bool(x) and bool(y))
        t = sum(1 for x, y in zip(ca, cb) if bool(x) == bool(y))
        e1 = sign_test(w, l)

        ea = [_energy(r) for r in _rows_for(rows, a)]
        eb = [_energy(r) for r in _rows_for(rows, b)]
        e3 = paired_wilcoxon(ea, eb)

        ta = [_time_if_complete(r) for r in _rows_for(rows, a)]
        tb = [_time_if_complete(r) for r in _rows_for(rows, b)]
        e4 = paired_wilcoxon(ta, tb)
        e4_note = e4["note"] or ("완주판 짝 %d개만 비교 -- 선택편향(생존한 판끼리)" % e4["n_used"])

        out["%s__%s" % (a, b)] = {
            "e1_wins": w, "e1_losses": l, "e1_ties": t, "e1_sign_p": e1,
            "e1_note": "천장(전부 동점) -- 시드를 늘려도 유의해질 수 없다" if t and not (w or l) else "",
            "e3_wilcoxon_p": e3["p"], "e3_median_diff": e3["median_diff"], "e3_n": e3["n_used"],
            "e4_wilcoxon_p": e4["p"], "e4_median_diff": e4["median_diff"], "e4_n": e4["n_used"],
            "e4_note": e4_note,
        }
    return out


def _rows_for(rows, policy):
    """정책 하나의 판을 ood_seed 순으로. 짝맞춤은 pair_boards 와 같은 규칙(빠진 시드는 None)."""
    idx = {(r.get("ood_seed"), r.get("policy")): r for r in rows}
    seeds = sorted({r.get("ood_seed") for r in rows if r.get("ood_seed") is not None})
    return [idx.get((s, policy)) or {} for s in seeds]


def holm_family(pmap):
    """{"case__a__b": p} -> 같은 딕셔너리 모양의 Holm 조정 p. 족(family) 안에서만 조정한다."""
    keys = sorted(pmap)
    adj = holm([pmap[k] for k in keys])
    return dict(zip(keys, adj))
```

Note `_energy` and `_time_if_complete` are written to tolerate a missing board (`_rows_for` yields `{}` for a seed a policy never ran), so an unmatched seed becomes `None` and `paired_wilcoxon` drops that pair rather than crashing.

Then, after all cases are assembled, apply `holm_family` per endpoint across the 21 `case__a__b` keys and write the adjusted values back into each case JSON under `holm_adjusted`.

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_report_sample_size.py
```

Expected: exit 0, 11/11 PASS (9 from Task 3 + the 2 added here).

- [ ] **Step 5: Render the new columns in `build_md_report.py` §5**

Extend the paired-comparison lines from a single sign-test sentence to a table:

```python
    L.append("| 비교 | E1 완주 (승/패/무, sign p, Holm) | E3 에너지 (Wilcoxon p, Holm) | E4 빌드시간 (Wilcoxon p, Holm) |")
    L.append("|---|---|---|---|")
    for pair_key, t in sorted((json_data.get("paired_tests") or {}).items()):
        a, b = pair_key.split("__")
        hk = "%s__%s" % (case, pair_key)
        h = json_data.get("holm_adjusted") or {}
        e1 = "%d승 %d패 %d무, p=%.3f, Holm=%.3f" % (
            t["e1_wins"], t["e1_losses"], t["e1_ties"], t["e1_sign_p"],
            (h.get("e1") or {}).get(hk, 1.0))
        if t["e1_note"]:
            e1 += " — %s" % t["e1_note"]
        e3 = "p=%.3f, Holm=%.3f (Δmed=%s, n=%d)" % (
            t["e3_wilcoxon_p"], (h.get("e3") or {}).get(hk, 1.0),
            ("%.1f" % t["e3_median_diff"]) if t["e3_median_diff"] is not None else "—", t["e3_n"])
        e4 = "p=%.3f, Holm=%.3f (n=%d) — %s" % (
            t["e4_wilcoxon_p"], (h.get("e4") or {}).get(hk, 1.0), t["e4_n"], t["e4_note"])
        L.append("| `%s` vs `%s` | %s | %s | %s |" % (a, b, e1, e3, e4))
```

- [ ] **Step 6: Smoke the renderer on n=5 data**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python build_final_table.py --results-dir results_4pol --out-dir /tmp/claude-1035/-home-chahj578-Construction-OODlayer/d76aa9d3-3c8f-4726-8f1e-732ada9515c9/scratchpad/regen2
/home/chahj578/Construction_OODlayer/.venv/bin/python build_md_report.py --results-dir results_4pol --out-dir /tmp/claude-1035/-home-chahj578-Construction-OODlayer/d76aa9d3-3c8f-4726-8f1e-732ada9515c9/scratchpad/regen2 --oracle-dir oracle/out
grep -A5 "E1 완주" /tmp/claude-1035/-home-chahj578-Construction-OODlayer/d76aa9d3-3c8f-4726-8f1e-732ada9515c9/scratchpad/regen2/REPORT.md | head -20
```

Expected: the battery `surrogate` vs `dspy` row shows `0승 0패 5무` with the ceiling note — proving the degeneracy is surfaced, not hidden.

- [ ] **Step 7: Commit**

```bash
git add wm4spacecraft_manufacturing/build_final_table.py wm4spacecraft_manufacturing/build_md_report.py wm4spacecraft_manufacturing/test_report_sample_size.py
git commit -m "feat(report): E3/E4 paired Wilcoxon + Holm correction across 21 tests"
```

---

## Task 7: End-to-end smoke run before committing 8 hours

Do not start the 420-board sweep without this. It costs ~15 min and catches every wiring error that would otherwise be discovered at hour 8.

**Files:** none modified — this is a verification task.

- [ ] **Step 1: Start the DSPy service with the program pinned**

Per CLAUDE.md, the LLM lane must be `__seed_only__`; the compiled `gpt4o` program is battery-only vocabulary.

```bash
cd /home/chahj578/Construction_OODlayer
DSPY_PROGRAM=__seed_only__ DSPY_MODEL=gpt-4o \
  ./.venv/bin/uvicorn src.respec.llm_service.dspy_service:app --host 127.0.0.1 --port 8090 &
sleep 20
curl -s http://127.0.0.1:8090/health | ./.venv/bin/python -m json.tool
```

Expected: `"program": "(seed only)"`. If it names `dspy_real_program_gpt4o.json`, the env var did not take — stop and fix, otherwise every zone measurement is out-of-vocabulary.

- [ ] **Step 2: Run 2 seeds on 1 case**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
rm -rf /tmp/claude-1035/-home-chahj578-Construction-OODlayer/d76aa9d3-3c8f-4726-8f1e-732ada9515c9/scratchpad/smoke && mkdir -p /tmp/claude-1035/-home-chahj578-Construction-OODlayer/d76aa9d3-3c8f-4726-8f1e-732ada9515c9/scratchpad/smoke
/home/chahj578/Construction_OODlayer/.venv/bin/python llm_ood_eval.py run \
  --seeds 21,22 --policies noop,surrogate,dspy \
  --out /tmp/claude-1035/-home-chahj578-Construction-OODlayer/d76aa9d3-3c8f-4726-8f1e-732ada9515c9/scratchpad/smoke/battery.jsonl \
  --case battery --dspy-url http://127.0.0.1:8090 --router 0
```

Seeds 21/22 are deliberately outside the planned 1–20 range so the smoke output can never be mistaken for real data.

Expected: 6 boards, all `ok`, exit code 0.

- [ ] **Step 3: Verify seeds beyond 5 actually change the stream**

This is the load-bearing assumption of the whole experiment. If new seeds produce identical event streams, adding seeds buys nothing.

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python -c "
import json
new=[json.loads(l) for l in open('/tmp/claude-1035/-home-chahj578-Construction-OODlayer/d76aa9d3-3c8f-4726-8f1e-732ada9515c9/scratchpad/smoke/battery.jsonl')]
old=[json.loads(l) for l in open('results_4pol/battery.jsonl')]
def sig(r): return (r['policy'], r['n_decisions'], round(r['sim_seconds'],3), r['closed'])
print('new seeds:', sorted({r[\"ood_seed\"] for r in new}))
for r in new: print(' ', sig(r))
print('old seeds:', sorted({r[\"ood_seed\"] for r in old}))
ns={sig(r)[1:] for r in new}; os_={sig(r)[1:] for r in old}
print('DISTINCT STREAMS' if ns - os_ else 'WARNING: new seeds reproduced old outcomes exactly')
"
```

Expected: `DISTINCT STREAMS`. A warning here means `DEMO_OOD_SEED` is not reaching the sampler — investigate before spending 8 hours.

- [ ] **Step 4: Verify the analysis toolchain handles a non-15 board count**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python build_final_table.py \
  --results-dir /tmp/claude-1035/-home-chahj578-Construction-OODlayer/d76aa9d3-3c8f-4726-8f1e-732ada9515c9/scratchpad/smoke \
  --out-dir /tmp/claude-1035/-home-chahj578-Construction-OODlayer/d76aa9d3-3c8f-4726-8f1e-732ada9515c9/scratchpad/smoke_art
grep "V4" /tmp/claude-1035/-home-chahj578-Construction-OODlayer/d76aa9d3-3c8f-4726-8f1e-732ada9515c9/scratchpad/smoke_art/battery.md
```

Expected: `V4 [PASS] 판 수 6 (2 seeds x 3 policies) 그대로.` — not a warning about 15.

- [ ] **Step 5: Record the smoke result, do not commit scratch data**

```bash
cd /home/chahj578/Construction_OODlayer
git status --short    # confirm nothing under scratchpad is staged
```

---

## Task 8: Execute the 420-board sweep

**Files:** produces `results_4pol_seed20/*.jsonl`, `_night/status_4pol.jsonl`, `_night/provenance_4pol.json`.

Write to a **new** results directory. Overwriting `results_4pol/` would destroy the n=5 comparison data mid-plan.

- [ ] **Step 1: Confirm preconditions**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
pgrep -x -u "$(id -u)" julia && echo "STOP: julia already running" || echo "no julia -- ok"
curl -s http://127.0.0.1:8090/health | ./../.venv/bin/python -c 'import json,sys; d=json.load(sys.stdin); print("program:", d["program"]); print("calls:", d["calls"])'
df -h . | tail -1
```

Expected: no julia; `program: (seed only)`; at least a few GB free (n=5 produced ~500 KB of summaries plus per-board stream logs — budget ~4× that).

- [ ] **Step 2: Launch the sweep**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
nohup bash run_4pol.sh \
  --deadline-seconds 43200 \
  --seeds 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20 \
  --cases battery,fault,all,fault_battery,fault_zone,battery_zone,zone \
  > _night/sweep_seed20.log 2>&1 &
echo "launched pid $!"
```

Note: `run_4pol.sh` writes to `$HERE/results_4pol` by construction. Before launching, either (a) move the n=5 data aside with `mv results_4pol results_4pol_n5` and let the sweep create a fresh directory, or (b) parameterize `RESULTS_DIR`. **Option (a) is required if you have not parameterized it** — gate P6 will otherwise refuse to start on a non-empty directory. The frozen `baseline_n5/` from Task 1 is the artifact that matters; `results_4pol_n5/` preserves the raw rows for Task 9.

- [ ] **Step 3: Monitor**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
tail -f _night/sweep_seed20.log
# 다른 창에서 진행률:
watch -n 300 'wc -l results_4pol/*.jsonl; cat _night/status_4pol.jsonl'
```

Expected cadence: ~68 s/board, 60 boards/case. `battery` ≈ 44 min, `all` ≈ 94 min.

- [ ] **Step 4: Verify completion**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
for f in results_4pol/*.jsonl; do echo "$(basename $f): $(wc -l < $f)"; done
grep -c '"status":"ok"' _night/status_4pol.jsonl
```

Expected: 7 files at **60 rows** each = 420 boards; 7 `ok` statuses. Any `skipped` means the deadline guard fired — check remaining time and re-run those cases with `--resume`.

- [ ] **Step 5: Confirm the DSPy lane stayed alive for the whole run**

An 8-hour run can lose the service mid-way; V1 in the report checks for silent fallback, but check the call counter too.

```bash
curl -s http://127.0.0.1:8090/health | /home/chahj578/Construction_OODlayer/.venv/bin/python -c 'import json,sys; print("calls:", json.load(sys.stdin)["calls"])'
```

Expected: a call count in the low thousands (140 dspy boards × ~4–20 decisions, minus cache hits — `dspy_service.py:230` sets `cache=True`, so repeats are free). A count near zero means the lane never ran.

- [ ] **Step 6: Commit the raw results**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/results_4pol wm4spacecraft_manufacturing/_night/status_4pol.jsonl wm4spacecraft_manufacturing/_night/provenance_4pol.json
git commit -m "data(4pol): 420-board sweep at ood_seed 1-20, 7 cases, world_seed=1"
```

---

## Task 9: Build the n=5 → n=20 stability comparison

This is the actual deliverable: not "here are new numbers" but "here is which of the old claims survived".

**Files:**
- Create: `wm4spacecraft_manufacturing/compare_seed_scale.py`
- Test: `wm4spacecraft_manufacturing/test_compare_seed_scale.py`

**Interfaces:**
- Consumes: `baseline_n5/*.json` (Task 1), the regenerated `artifacts_4pol/*.json` (Task 8), `stats_paired.wilson`.
- Produces: `artifacts_4pol/STABILITY.md` — one row per (case, policy, metric) with a verdict from PREREG §5.

- [ ] **Step 1: Write the failing test**

Create `wm4spacecraft_manufacturing/test_compare_seed_scale.py`:

```python
"""test_compare_seed_scale.py -- PREREG §5 판정 규칙 테스트.

실행: /home/chahj578/Construction_OODlayer/.venv/bin/python test_compare_seed_scale.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from compare_seed_scale import classify

FAILED = 0


def check(name, ok, detail=""):
    global FAILED
    print("  %s  %s   %s" % ("PASS" if ok else "FAIL", name, detail))
    if not ok:
        FAILED += 1


print("== PREREG §5 안정성 판정 규칙 ==")

# 옛 추정 0.80 [0.38, 0.96], 새 추정 0.85 -> 구간 안 + 같은 방향
check("옛 CI 안이면 REPRODUCED", classify(0.80, (0.38, 0.96), 0.85) == "REPRODUCED")
# 주의: 방향 검사가 CI 검사보다 **먼저** 돈다. 0.30 은 0.5 아래라 ATTENUATED 가 아니라
# REVERSED 다(2026-08-11 실측 -- 이 케이스를 0.30 으로 쓰면 테스트가 틀린다).
# ATTENUATED 를 재려면 0.5 같은 편이면서 CI 밖인 값을 써야 한다.
check("옛 CI 밖이지만 같은 방향이면 ATTENUATED", classify(0.80, (0.60, 0.96), 0.55) == "ATTENUATED")
# 옛 추정이 0.5 위, 새 추정이 0.5 아래 -> 방향 반전
check("방향이 뒤집히면 REVERSED", classify(0.80, (0.38, 0.96), 0.10) == "REVERSED")
check("옛 추정이 없으면 NEW", classify(None, None, 0.85) == "NEW")

# 연속형: 에너지 720 -> 700 은 3% 변화라 재현. CI 가 없어도 NEW 로 빠지면 안 된다.
check("연속형은 상대변화로 판정한다",
      classify(720.0, None, 700.0, "continuous") == "REPRODUCED"
      and classify(720.0, None, 400.0, "continuous") == "ATTENUATED")
# 0.5 기준 방향 판정은 줄/초 단위 값에 의미가 없다 -- REVERSED 를 내면 안 된다.
check("연속형은 REVERSED 를 내지 않는다", classify(900.0, None, 0.4, "continuous") != "REVERSED")

sys.exit(1 if FAILED else 0)
```

- [ ] **Step 2: Run to verify failure**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_compare_seed_scale.py
```

Expected: FAIL — `ModuleNotFoundError: No module named 'compare_seed_scale'`.

- [ ] **Step 3: Implement `compare_seed_scale.py`**

```python
"""compare_seed_scale.py -- n=5 리포트의 주장이 n=20 에서 살아남았는지 판정한다 (2026-08-11).

PREREG_SEED20.md §5 의 기준을 그대로 구현한다. 새 숫자를 보여주는 게 목적이 아니라
**옛 주장이 재현됐는지**를 판정하는 게 목적이다.
"""
import argparse
import json
import os
from pathlib import Path

HERE = Path(os.path.dirname(os.path.abspath(__file__)))

# (값 키, CI 키, 표시명, 종류). 키 이름은 artifacts_4pol/<case>.json 의 실제 키다
# (2026-08-11 확인: success/success_ci, decision_rate/decision_ci 이며 completion_rate 는 없다).
# 연속형 두 개는 CI 를 내보내지 않으므로 상대변화 기준으로 판정한다.
METRICS = [
    ("success",              "success_ci",  "완주율",        "proportion"),
    ("decision_rate",        "decision_ci", "결정 충실도",   "proportion"),
    ("energy_per_closed",    None,          "J/closed",      "continuous"),
    ("sim_seconds_complete", None,          "빌드시간",      "continuous"),
]

REL_TOL = 0.20      # 연속형: 상대변화 20% 이내면 재현으로 본다 (PREREG §5 에 사전 고정)


def classify(old_point, old_ci, new_point, kind="proportion"):
    """PREREG §5 판정.

    비율(proportion): 옛 95% CI 안에 새 점추정이 들어오면 REPRODUCED. 방향(0.5 기준)이
      뒤집히면 REVERSED.
    연속형(continuous): CI 가 없으므로 상대변화 |new-old|/|old| 로 판정한다. 방향 개념이
      없으므로 REVERSED 를 내지 않는다 -- 에너지 400 vs 900 에 "0.5 기준 방향"은 무의미하다.
    """
    if old_point is None or new_point is None:
        return "NEW"
    if kind == "proportion":
        if old_ci is None:
            return "NEW"
        if (old_point >= 0.5) != (new_point >= 0.5):
            return "REVERSED"
        lo, hi = old_ci
        return "REPRODUCED" if lo <= new_point <= hi else "ATTENUATED"
    if old_point == 0:
        return "NEW"
    return "REPRODUCED" if abs(new_point - old_point) / abs(old_point) <= REL_TOL else "ATTENUATED"


def load_case(d, case):
    p = Path(d) / ("%s.json" % case)
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--old-dir", default=str(HERE / "baseline_n5"))
    ap.add_argument("--new-dir", default=str(HERE / "artifacts_4pol"))
    ap.add_argument("--out", default=str(HERE / "artifacts_4pol" / "STABILITY.md"))
    a = ap.parse_args()

    cases = ["battery", "fault", "all", "fault_battery", "fault_zone", "battery_zone", "zone"]
    L = ["# n=5 -> n=20 안정성 판정", "",
         "판정 기준은 `PREREG_SEED20.md` §5 에 데이터 수집 전에 고정했다.", "",
         "| case | 정책 | 지표 | n=5 | n=20 | 판정 |", "|---|---|---|---|---|---|"]
    tally = {}
    for case in cases:
        old, new = load_case(a.old_dir, case), load_case(a.new_dir, case)
        if new is None:
            L.append("| %s | — | — | — | 없음 | MISSING |" % case)
            continue
        for pol in ("noop", "surrogate", "dspy"):
            o = ((old or {}).get("policies") or {}).get(pol) or {}
            n = (new.get("policies") or {}).get(pol) or {}
            for key, ci_key, label, kind in METRICS:
                op, np_ = o.get(key), n.get(key)
                oci = o.get(ci_key) if ci_key else None
                verdict = classify(op, tuple(oci) if oci else None, np_, kind)
                tally[verdict] = tally.get(verdict, 0) + 1
                L.append("| `%s` | `%s` | %s | %s | %s | %s |" % (
                    case, pol, label,
                    "—" if op is None else "%.3f" % op,
                    "—" if np_ is None else "%.3f" % np_, verdict))
    L += ["", "## 집계", ""]
    for k in sorted(tally):
        L.append("- %s: %d" % (k, tally[k]))
    Path(a.out).write_text("\n".join(L) + "\n", encoding="utf-8")
    print("wrote %s" % a.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

The key names above were read off a real `artifacts_4pol/battery.json` on 2026-08-11 — the proportion metrics are `success`/`success_ci` and `decision_rate`/`decision_ci`; there is **no** `completion_rate` key. Confirm before implementing:

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python -c "
import json; print(sorted(json.load(open('baseline_n5/battery.json'))['policies']['dspy']))"
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_compare_seed_scale.py
```

Expected: exit 0, 6/6 PASS.

- [ ] **Step 5: Regenerate all artifacts at n=20 and produce the stability report**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python build_final_table.py --results-dir results_4pol --out-dir artifacts_4pol
/home/chahj578/Construction_OODlayer/.venv/bin/python build_md_report.py --results-dir results_4pol --out-dir artifacts_4pol --oracle-dir oracle/out
/home/chahj578/Construction_OODlayer/.venv/bin/python compare_seed_scale.py
```

- [ ] **Step 6: Verify the regenerated report is internally consistent**

The specific failure this catches: tables saying n=20 while prose says n=5.

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
grep -n "시드 5개\|0.062\|120 판\|1,2,3,4,5$\|5 seeds x 3" artifacts_4pol/REPORT.md && echo "FAIL: stale claim survived" || echo "PASS: no stale sample-size claims"
grep -n "n=20 seeds\|20개" artifacts_4pol/REPORT.md | head -3
grep -c "zonecore" artifacts_4pol/REPORT.md    # expect 0 outside the limitations note
/home/chahj578/Construction_OODlayer/.venv/bin/python test_stats_paired.py && \
/home/chahj578/Construction_OODlayer/.venv/bin/python test_report_sample_size.py && \
/home/chahj578/Construction_OODlayer/.venv/bin/python test_compare_seed_scale.py
```

Expected: `PASS: no stale sample-size claims`, and all tests green.

- [ ] **Step 7: Commit**

```bash
git add wm4spacecraft_manufacturing/compare_seed_scale.py wm4spacecraft_manufacturing/test_compare_seed_scale.py wm4spacecraft_manufacturing/artifacts_4pol/
git commit -m "feat(4pol): n=5 -> n=20 stability verdicts per PREREG criteria"
```

---

## Task 10: Write the verification conclusion

**Files:**
- Create: `wm4spacecraft_manufacturing/md/SEED20_VERIFICATION_2026-08-11.md`
- Modify: `wm4spacecraft_manufacturing/md/STATUS.md` (resume point)
- Modify: `.claude/CLAUDE.md` (point the "현행 측정 문서" line at the new result if it supersedes `RESULTS_LLM7H.md`)

- [ ] **Step 1: Write the conclusion document**

It must answer, claim by claim, the seven items in `PREREG_SEED20.md` §6 — each with a verdict from §5 and the Holm-adjusted p where a test applies. Structure:

```markdown
# 20시드 검증 결과 (2026-08-11)

## 0. 한 문장
[C1..C7 중 몇 개가 REPRODUCED / ATTENUATED / REVERSED 인지]

## 1. 이 문서가 재는 것 / 재지 않는 것
- 잰다: ood_seed 20개에서 n=5 리포트의 주장이 재현되는가
- 재지 않는다: 레이아웃 일반화(world_seed=1 고정), root-covered zone 영역(REPORT §3-B 결함은 여전히 잠복)

## 2. 청구별 판정
| 청구 | n=5 | n=20 | Holm p | 판정 |

## 3. 천장효과로 검정 불가한 셀
[E1 이 전부 동점인 (case, pair) 목록 -- "유의하지 않다"가 아니라 "검정 불가"로 적을 것]

## 4. 바뀐 결론
## 5. 재현 절차
```

- [ ] **Step 2: Add a generation banner to the superseded document**

If the n=20 result supersedes `RESULTS_LLM7H.md` as the current measurement of record, add the same 🔴 generation banner the repo already uses on the five superseded result docs, and update the CLAUDE.md line that says `현행 측정 문서는 md/RESULTS_LLM7H.md 하나뿐`.

- [ ] **Step 3: Verify every number in the conclusion traces to a file**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
# 문서의 모든 수치가 artifacts_4pol/ 산출물에 실제로 있는지 눈으로 대조
grep -o "[0-9]\+\.[0-9]\+%\|[0-9]\+/[0-9]\+" md/SEED20_VERIFICATION_2026-08-11.md | sort -u | head -40
```

Cross-check each against `artifacts_4pol/REPORT.md` and `artifacts_4pol/STABILITY.md`. Any number not present in a generated artifact must be deleted or recomputed — no hand-typed statistics.

- [ ] **Step 4: Run the full contract suite**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python audit_action_vocab.py          # exit 0 = 6/6
/home/chahj578/Construction_OODlayer/.venv/bin/python test_surrogate_support.py      # 7/7
/home/chahj578/Construction_OODlayer/.venv/bin/python test_stats_paired.py && \
/home/chahj578/Construction_OODlayer/.venv/bin/python test_report_sample_size.py && \
/home/chahj578/Construction_OODlayer/.venv/bin/python test_compare_seed_scale.py
```

Expected: all green. Note the known-failing baselines that are **not** this plan's problem: `Pkg.test()` = 11 pass / 1 error (Gurobi license), and `verify.py oracle/out/n44_plus78.jsonl` → `KeyError: 7`.

- [ ] **Step 5: Commit**

```bash
git add wm4spacecraft_manufacturing/md/SEED20_VERIFICATION_2026-08-11.md wm4spacecraft_manufacturing/md/STATUS.md .claude/CLAUDE.md
git commit -m "docs(4pol): 20-seed verification conclusion + supersede n=5 measurement of record"
```

---

## Risk register

| Risk | Detection | Mitigation |
|---|---|---|
| DSPy service dies mid-run | V1 check in report; `/health` `calls` counter (Task 8 Step 5) | Boards are written incrementally; re-run affected cases with `--resume` |
| Deadline guard skips cases | `"status":"skipped"` in `status_4pol.jsonl` | Cost model recalibrated in Task 4; 12 h deadline vs 10.2 h estimate |
| Ceiling effects make E1 uninformative | Pre-declared in PREREG §4; surfaced as an explicit note in the §5 table | Report as "검정 불가(천장)", never as "유의차 없음" |
| Refactor silently changes n=5 numbers | Task 3 Step 7 diff against frozen baseline | Empty diff required for §2–§6 before proceeding |
| Wrong DSPy program (battery-only vocab) | Task 7 Step 1 asserts `"(seed only)"`; recorded per-run in `provenance_4pol.json` | Pin `DSPY_PROGRAM=__seed_only__` explicitly |
| `results_4pol/` overwritten, losing baseline | Gate P6 refuses non-empty dir | `baseline_n5/` frozen in Task 1; raw rows moved to `results_4pol_n5/` |

## Out of scope (deliberately)

- Fixing the `reference_policy.py` zone rule defect (REPORT §3-B). Fixing it re-scores every number and destroys comparability. It stays reported.
- Fixing `run_demo.jl:433` so `zonecore` becomes a real case. Changes simulator behavior.
- `world_seed` / layout generalization. Explicitly excluded; the §7 limitation stays.
- Widening the sweep into root-covered zone territory, where the zone rule is known wrong.
