# 30시드 630판 병렬 스윕 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `run_4pol.sh` 스윕을 7 case × 30 seed × 3 policy = 630 판으로 늘리고, bethpage 에서 K=16 병렬로 하룻밤 안에 완주시킨다.

**Architecture:** 샤드 = (case, seed). `llm_ood_eval.py` 의 `--out` 경로만 샤드마다 다르게 주면 `log_dir = out_path.parent / "logs"` 규칙 때문에 스트림·로그·요약이 전부 샤드별로 갈라진다 — 파이썬 평가 코드는 한 줄도 고치지 않는다. 210개 샤드를 `xargs -P 16` 으로 돌리고, 끝나면 샤드 산출물을 `results_4pol/<case>.jsonl` 평면 구조로 병합해 기존 리포트 도구에 그대로 먹인다.

**Tech Stack:** bash, Python 3.12 (`$REPO/.venv`), scipy 1.18, Julia 1.10.11 (juliaup `+lts`), FastAPI/uvicorn (DSPy 서비스)

## Global Constraints

- 저장소 루트: `/home/chahj578/Construction_OODlayer` (이하 `$REPO`). 새 파일은 전부 `$REPO/wm4spacecraft_manufacturing/` 아래.
- 파이썬 인터프리터는 **반드시** `$REPO/.venv/bin/python`. 시스템 python 은 rvo2 가 없다.
- **`llm_ood_eval.py`, `run_4pol.sh`, `tools/monitor/run_demo.jl` 을 수정하지 않는다.** 순차 재현 경로를 보존한다.
- pytest 가 없다. 테스트는 이 저장소 관행을 따른다 — 단독 실행 스크립트가 `check(name, ok, detail)` 로 PASS/FAIL 을 찍고 `sys.exit(1 if FAILED else 0)` 로 끝난다 (`test_surrogate_support.py` 참조).
- 정책 목록은 `noop,surrogate,dspy` 고정. `canonical` 과 `oracle` 은 이 스윕에 없다.
- case 목록은 `battery,fault,all,fault_battery,fault_zone,battery_zone,zone` (7개). `zonecore` 는 `run_demo.jl:433` 이 `:zone` 으로 바꾸므로 제외한다.
- 시드는 1..30, 병렬도 K=16.
- DSPy 서비스 주소는 `http://127.0.0.1:8090`.
- 모든 julia 워커에 `JULIA_NUM_THREADS=1`, `OPENBLAS_NUM_THREADS=1`, `OMP_NUM_THREADS=1` 을 건다.
- 새 요약 행은 `geometry.depot_distance == 20.0` 이어야 한다. `20` 은 `src/respec/ood_injection.jl:569` 의 기본값이다.
- **`git stash -u` 를 쓰지 않는다.** `.venv/` 와 `results_4pol/` 이 `.gitignore` 에 없어 16,833개 파일이 함께 쓸려 간다(2026-08-12 실측). 커밋은 경로를 명시해 `git add` 한다.

### 요약 행(JSONL 한 줄) 스키마 — 실측

`battery`, `bsoc`, `case`, `closed`, `complete`, `decisions`, `dt`, `model`, `n_decisions`,
`n_events_armed`, `ood_hi`, `ood_lo`, `ood_seed`, `policy`, `progress`, `robots`, `router`,
`sev_frac`, `sim_seconds`, `spares`, `spares_left`, `status`, `steps`, `stream`, `stream3`,
`total`, `wall_seconds`, `world_seed`, 그리고 신세대 행에만 `geometry`.

주의할 이름들: 닫힌 노드 수는 `n_closed` 가 아니라 **`closed`**. 시드는 `seed` 가 아니라
**`ood_seed`**. `geometry` 는 2026-08-12 이후 생성 행에만 있다.

---

## File Structure

| 파일 | 책임 |
|---|---|
| `wm4spacecraft_manufacturing/check_geometry.py` | 결과 jsonl 의 모든 행이 기대한 창고 거리로 생성됐는지 검사 |
| `wm4spacecraft_manufacturing/test_check_geometry.py` | 위 검사기의 테스트 |
| `wm4spacecraft_manufacturing/run_shard.sh` | 샤드 하나 = (case, seed) × 3정책 실행. 스레드 고정, 재개 판정 |
| `wm4spacecraft_manufacturing/merge_shards.py` | 샤드 rows.jsonl → `results_4pol/<case>.jsonl` 결정적 병합 + 행 수 검증 |
| `wm4spacecraft_manufacturing/test_merge_shards.py` | 위 병합기의 테스트 |
| `wm4spacecraft_manufacturing/gate_llm_concurrency.py` | P8 — `/macro` 동시 K 요청 검사 |
| `wm4spacecraft_manufacturing/gate_prereq.sh` | P1~P4 + P8 사전 조건 게이트 묶음 |
| `wm4spacecraft_manufacturing/gate_load_distribution.py` | P7 — 단독/부하 하 분포 비교 판정 |
| `wm4spacecraft_manufacturing/test_gate_load_distribution.py` | 위 판정 로직의 테스트 |
| `wm4spacecraft_manufacturing/run_4pol_parallel.sh` | 오케스트레이터 — 게이트 + 작업목록 + `xargs -P K` + 데드라인 + status |

---

## Task 1: 기하 provenance 검사기 + D=40 산출물 격리

**Files:**
- Create: `wm4spacecraft_manufacturing/check_geometry.py`
- Create: `wm4spacecraft_manufacturing/test_check_geometry.py`
- Move: `wm4spacecraft_manufacturing/results_4pol/*.jsonl`, `results_4pol/logs/`, `_night/status_4pol.jsonl` → `wm4spacecraft_manufacturing/_quarantine_D40_2026-08-12/`

**Interfaces:**
- Consumes: 없음 (첫 태스크)
- Produces: `check_geometry.py` — CLI `python check_geometry.py --results-dir DIR --expect-depot-distance FLOAT`, 위반 행이 하나라도 있으면 exit 1. Task 7 의 최종 검증에서 다시 쓴다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`wm4spacecraft_manufacturing/test_check_geometry.py`:

```python
"""check_geometry.py 계약 테스트.

왜 필요한가: 요약 행에는 창고 거리가 `geometry.depot_distance` 로만 남는다. 2026-08-12 이전
행에는 `geometry` 블록 자체가 없다. 그 두 세대를 한 파일에 섞으면 makespan 과 에너지가 서로
다른 세계에서 나온 값이 되는데, 표는 그걸 구분해 주지 않는다. 검사는 주장이 아니라 코드여야 한다.
"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable
CHECKER = os.path.join(HERE, "check_geometry.py")

FAILED = 0


def check(name, ok, detail=""):
    global FAILED
    print("  %s  %s   %s" % ("PASS" if ok else "FAIL", name, detail))
    if not ok:
        FAILED += 1


def run_checker(rows, expect="20.0"):
    """rows 를 임시 디렉토리의 case.jsonl 로 쓰고 검사기를 돌린다. 반환: (returncode, stdout)."""
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "battery.jsonl"), "w", encoding="utf-8") as fh:
            for r in rows:
                fh.write(json.dumps(r) + "\n")
        p = subprocess.run([PY, CHECKER, "--results-dir", d,
                            "--expect-depot-distance", expect],
                           capture_output=True, text=True)
        return p.returncode, p.stdout + p.stderr


GOOD = {"case": "battery", "ood_seed": 1, "policy": "noop",
        "geometry": {"depot_mode": "fixed", "depot_distance": 20.0,
                     "station_keeping": True}}
D40 = {"case": "battery", "ood_seed": 2, "policy": "noop",
       "geometry": {"depot_mode": "fixed", "depot_distance": 40.0,
                    "station_keeping": True}}
LEGACY = {"case": "battery", "ood_seed": 3, "policy": "noop"}   # geometry 블록 없음

print("== check_geometry.py ==")

rc, out = run_checker([GOOD, GOOD])
check("D=20 행만 있으면 통과", rc == 0, "rc=%d" % rc)

rc, out = run_checker([GOOD, D40])
check("D=40 행이 섞이면 실패", rc == 1, "rc=%d" % rc)
check("D=40 행의 ood_seed 를 찍는다", "ood_seed=2" in out, out.strip()[-200:])

rc, out = run_checker([GOOD, LEGACY])
check("geometry 블록이 없는 구세대 행은 실패", rc == 1, "rc=%d" % rc)
check("구세대 행임을 명시한다", "geometry" in out, out.strip()[-200:])

rc, out = run_checker([])
check("빈 파일은 통과", rc == 0, "rc=%d" % rc)

sys.exit(1 if FAILED else 0)
```

- [ ] **Step 2: 테스트를 돌려 실패를 확인한다**

Run:
```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python test_check_geometry.py
```
Expected: FAIL — `check_geometry.py` 가 없어서 subprocess 가 rc=2 로 끝나고 모든 check 가 FAIL.

- [ ] **Step 3: 검사기를 구현한다**

`wm4spacecraft_manufacturing/check_geometry.py`:

```python
"""결과 jsonl 의 모든 행이 기대한 창고 거리(D)로 생성됐는지 검사한다.

`run_demo.jl:665` 이 요약 행에 `geometry.depot_distance` 를 남긴다. 그 블록이 없는 행은
2026-08-12 이전 세대다 -- 그 시절 기본값은 D=40 이었으므로, 값을 모르는 게 아니라 **다른
세계에서 나온 행**으로 취급해 실패로 본다. 조용히 통과시키면 D=20 표에 D=40 행이 섞인다.
"""
import argparse, json, sys
from pathlib import Path


def scan(results_dir, expect):
    """(n_rows, violations) 를 돌려준다. violations 는 사람이 읽을 문자열 목록."""
    n_rows = 0
    violations = []
    for path in sorted(Path(results_dir).glob("*.jsonl")):
        with open(path, "r", encoding="utf-8") as fh:
            for lineno, line in enumerate(fh, 1):
                line = line.strip()
                if not line:
                    continue
                n_rows += 1
                try:
                    row = json.loads(line)
                except json.JSONDecodeError as e:
                    violations.append("%s:%d 파싱 불가 (%s)" % (path.name, lineno, e))
                    continue
                geom = row.get("geometry")
                seed = row.get("ood_seed")
                pol = row.get("policy")
                if not isinstance(geom, dict):
                    violations.append(
                        "%s:%d geometry 블록 없음 -- 2026-08-12 이전 세대 행 "
                        "(ood_seed=%s policy=%s)" % (path.name, lineno, seed, pol))
                    continue
                got = geom.get("depot_distance")
                if got != expect:
                    violations.append(
                        "%s:%d depot_distance=%r, 기대값 %r (ood_seed=%s policy=%s)"
                        % (path.name, lineno, got, expect, seed, pol))
    return n_rows, violations


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--results-dir", required=True)
    ap.add_argument("--expect-depot-distance", type=float, default=20.0)
    args = ap.parse_args()

    n_rows, violations = scan(args.results_dir, args.expect_depot_distance)
    print("== 기하 provenance 검사: %s (기대 D=%g) ==" % (args.results_dir,
                                                        args.expect_depot_distance))
    print("  행 %d개 검사" % n_rows)
    for v in violations:
        print("  FAIL  " + v)
    if violations:
        print("  위반 %d건" % len(violations))
        return 1
    print("  PASS  모든 행이 D=%g" % args.expect_depot_distance)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: 테스트를 돌려 통과를 확인한다**

Run:
```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python test_check_geometry.py
```
Expected: 6개 check 전부 PASS, exit 0.

- [ ] **Step 5: 검사기를 기존 D=40 산출물에 돌려 실제로 잡히는지 확인한다**

Run:
```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python check_geometry.py --results-dir results_4pol --expect-depot-distance 20.0; echo "rc=$?"
```
Expected: rc=1. 기존 행에는 `geometry` 블록이 없으므로 "2026-08-12 이전 세대 행" 위반이 대량으로 찍힌다. 이것이 격리해야 할 근거다.

- [ ] **Step 6: D=40 산출물을 격리한다 (삭제 아님)**

Run:
```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
Q=_quarantine_D40_2026-08-12
mkdir -p "$Q"
mv results_4pol "$Q"/results_4pol
mv _night/status_4pol.jsonl "$Q"/status_4pol.jsonl
mkdir -p results_4pol
ls "$Q"/results_4pol/*.jsonl | wc -l    # 8 이어야 한다
ls results_4pol | wc -l                 # 0 이어야 한다
```

- [ ] **Step 7: 빈 디렉토리에서 검사기가 통과하는지 확인한다**

Run:
```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python check_geometry.py --results-dir results_4pol --expect-depot-distance 20.0; echo "rc=$?"
```
Expected: rc=0, "행 0개 검사".

- [ ] **Step 8: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/check_geometry.py \
        wm4spacecraft_manufacturing/test_check_geometry.py
git commit -m "feat(eval): 요약 행의 창고 거리 provenance 검사기 -- D=40 행 혼입을 막는다"
```

격리된 `_quarantine_D40_2026-08-12/` 는 커밋하지 않는다(결과 데이터, 크기가 크고 폐기 대상).

---

## Task 2: 샤드 러너

**Files:**
- Create: `wm4spacecraft_manufacturing/run_shard.sh`

**Interfaces:**
- Consumes: 없음
- Produces: `run_shard.sh CASE SEED OUTDIR [POLICIES]` — `OUTDIR/rows.jsonl` 과 `OUTDIR/logs/` 를 만든다. 이미 완료된 샤드면 아무것도 하지 않고 exit 0. 환경변수 `DRY_RUN=1` 이면 실행할 명령만 찍고 exit 0. Task 5(P7 게이트)와 Task 6(오케스트레이터)이 둘 다 이걸 호출한다.

- [ ] **Step 1: 샤드 러너를 작성한다**

`wm4spacecraft_manufacturing/run_shard.sh`:

```bash
#!/usr/bin/env bash
# =============================================================================
# run_shard.sh -- 샤드 하나 = (case, seed) x 정책 3개 를 돈다.
#
# 왜 샤드 단위가 (case, seed) 인가
# --------------------------------
# llm_ood_eval.py:173 이 log_dir 을 `out_path.parent / "logs"` 로 잡고, :113 이 그 안에
# `stream_s{seed}_{policy}.jsonl` 을 쓴다. 파일명에 case 가 없으므로 모든 case 가 같은
# results_4pol/logs/ 를 쓰면 case 끼리 같은 파일을 덮어쓴다 -- 순차에서는 덮어쓰기지만 병렬에서는
# 동시 write 다. --out 을 샤드마다 다른 디렉토리로 주면 logs/ 도 따라 갈라진다.
# 요약 행도 마찬가지다: 한 행이 약 4.9 KB 라 PIPE_BUF(4096 B)를 넘어 O_APPEND 라도 동시 write
# 가 원자적이지 않다. 샤드마다 rows.jsonl 이 따로면 한 파일에 쓰는 프로세스가 언제나 하나다.
#
# 3정책이 샤드 **안에서** 순차로 도는 것도 의도다. 부하 조건이 정책 사이에서는 같고 샤드
# 사이에서만 달라지므로, 부하가 결과를 흔들어도 정책 대비에 실리는 계통 편향이 되지 않는다.
#
# 사용법
#   bash run_shard.sh battery 3 results_4pol/shards/battery/s3
#   bash run_shard.sh zone 1 results_gate/solo/rep1 noop
#   DRY_RUN=1 bash run_shard.sh battery 3 /tmp/x        # 명령만 출력
# =============================================================================
set -uo pipefail

if [ $# -lt 3 ]; then
    echo "usage: run_shard.sh CASE SEED OUTDIR [POLICIES]" >&2
    exit 2
fi

CASE="$1"; SEED="$2"; OUTDIR="$3"; POLICIES="${4:-noop,surrogate,dspy}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PY="$REPO/.venv/bin/python"
DSPY_URL="${DSPY_URL:-http://127.0.0.1:8090}"

# 정책 개수 = 완주 판정에 쓸 기대 행 수
N_POLICIES=$(printf '%s' "$POLICIES" | tr ',' '\n' | grep -c . )
ROWS="$OUTDIR/rows.jsonl"

# 재개: 이미 기대한 행 수가 있으면 다시 돌지 않는다.
if [ -f "$ROWS" ]; then
    have=$(grep -c . "$ROWS" 2>/dev/null || echo 0)
    if [ "$have" -ge "$N_POLICIES" ]; then
        echo "[shard] SKIP  case=$CASE seed=$SEED  (rows=$have >= $N_POLICIES)"
        exit 0
    fi
    # 행이 모자라면 부분 산출물이다. 이어 붙이면 중복 행이 생기므로 자리를 비우고 다시 돈다.
    echo "[shard] PARTIAL case=$CASE seed=$SEED rows=$have -> 디렉토리를 비우고 재실행"
    rm -rf "$OUTDIR"
fi

mkdir -p "$OUTDIR"

# BLAS/OpenMP 스레드를 1로 못박는다. 안 걸면 프로세스마다 코어 수만큼 스레드를 띄워
# K 배로 코어를 뺏는다(56 코어 x 16 프로세스 = 896 스레드).
export JULIA_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1

CMD=("$PY" llm_ood_eval.py run
     --case "$CASE"
     --seeds "$SEED"
     --policies "$POLICIES"
     --out "$OUTDIR/rows.jsonl"
     --dspy-url "$DSPY_URL"
     --router 0)

if [ "${DRY_RUN:-0}" = "1" ]; then
    printf '[shard] DRY case=%s seed=%s out=%s ::' "$CASE" "$SEED" "$OUTDIR"
    printf ' %q' "${CMD[@]}"
    printf '\n'
    exit 0
fi

cd "$HERE"
t0=$SECONDS
"${CMD[@]}" > "$OUTDIR/shard.log" 2>&1
rc=$?
dt=$(( SECONDS - t0 ))

rows=0
[ -f "$ROWS" ] && rows=$(grep -c . "$ROWS" 2>/dev/null || echo 0)

if [ "$rc" -ne 0 ] || [ "$rows" -lt "$N_POLICIES" ]; then
    echo "[shard] FAIL  case=$CASE seed=$SEED rc=$rc rows=$rows/$N_POLICIES ${dt}s -> $OUTDIR/shard.log"
    exit 1
fi
echo "[shard] OK    case=$CASE seed=$SEED rows=$rows ${dt}s"
exit 0
```

- [ ] **Step 2: DRY_RUN 으로 명령 조립을 확인한다**

Run:
```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
DRY_RUN=1 bash run_shard.sh battery 3 results_4pol/shards/battery/s3
DRY_RUN=1 bash run_shard.sh zone 1 /tmp/gate/rep1 noop
bash run_shard.sh; echo "rc=$? (2 여야 한다)"
```
Expected:
- 첫 줄에 `--case battery --seeds 3 --policies noop,surrogate,dspy --out results_4pol/shards/battery/s3/rows.jsonl` 이 보인다.
- 둘째 줄은 `--policies noop --out /tmp/gate/rep1/rows.jsonl`.
- 인자 없이 부르면 usage 를 찍고 rc=2.

- [ ] **Step 3: 재개 판정을 확인한다**

Run:
```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
mkdir -p /tmp/shardtest && printf 'a\nb\nc\n' > /tmp/shardtest/rows.jsonl
bash run_shard.sh battery 3 /tmp/shardtest; echo "rc=$? (0, SKIP 이어야 한다)"
printf 'a\n' > /tmp/shardtest/rows.jsonl
DRY_RUN=1 bash run_shard.sh battery 3 /tmp/shardtest; echo "rc=$? (0, PARTIAL 후 DRY)"
rm -rf /tmp/shardtest
```
Expected: 첫 호출은 `SKIP ... (rows=3 >= 3)`. 둘째는 `PARTIAL ... rows=1` 을 찍고 DRY 명령을 출력.

- [ ] **Step 4: 진짜 샤드 하나를 돌려 산출물 구조를 확인한다**

먼저 DSPy 서비스를 띄운다(Task 4 에서 게이트로 정식화하지만, 여기서는 손으로 확인):
```bash
cd /home/chahj578/Construction_OODlayer/src/respec/llm_service
nohup /home/chahj578/Construction_OODlayer/.venv/bin/python -m uvicorn dspy_service:app \
  --host 127.0.0.1 --port 8090 > /tmp/dspy_8090.log 2>&1 &
sleep 25 && curl -s 127.0.0.1:8090/health | head -c 300; echo
```
그다음 샤드 하나:
```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
time bash run_shard.sh battery 1 results_4pol/shards/battery/s1
find results_4pol/shards/battery/s1 -type f | sort
grep -c . results_4pol/shards/battery/s1/rows.jsonl
../.venv/bin/python check_geometry.py --results-dir results_4pol/shards/battery/s1 \
  --expect-depot-distance 20.0; echo "rc=$?"
```
Expected: `[shard] OK`, 3분 내외(약 165 s × 1.15 × 3정책 ≈ 9분까지는 정상). `rows.jsonl` 3행,
`logs/stream_s1_{noop,surrogate,dspy}.jsonl` 3개, `logs/run_s1_*.log` 3개, `shard.log` 1개.
기하 검사 rc=0 — 여기서 rc=1 이면 D=20 이 실제로는 안 걸린 것이니 **멈추고 원인을 찾는다**.

- [ ] **Step 5: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/run_shard.sh
git commit -m "feat(4pol): 샤드 러너 -- (case,seed) 단위 격리로 스트림 충돌 제거"
```

---

## Task 3: 샤드 병합기

**Files:**
- Create: `wm4spacecraft_manufacturing/merge_shards.py`
- Create: `wm4spacecraft_manufacturing/test_merge_shards.py`

**Interfaces:**
- Consumes: Task 2 가 만드는 `SHARDS/<case>/s<seed>/rows.jsonl`
- Produces: `merge_shards.py` — CLI `python merge_shards.py --shards-dir DIR --out-dir DIR --cases CSV --seeds CSV --policies CSV`. `OUT/<case>.jsonl` 을 `(ood_seed, policy 순서)` 로 정렬해 쓴다. 기대 행 수에 못 미치면 빠진 (seed, policy) 를 전부 찍고 exit 1. Task 7 이 호출한다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`wm4spacecraft_manufacturing/test_merge_shards.py`:

```python
"""merge_shards.py 계약 테스트.

왜 필요한가: 병렬 실행에서는 샤드 완료 순서가 실행마다 다르다. 그 순서대로 병합하면
results_4pol/<case>.jsonl 의 행 순서가 실행마다 달라지고, 그걸 먹는 리포트 산출물도 따라
달라진다. 병합은 완료 순서가 아니라 (ood_seed, policy) 로 결정적이어야 한다.
또 하나: 조용한 부분 병합을 막아야 한다. 90행이어야 할 파일이 87행인 채로 통과하면 표는
"n=30" 이라고 주장하면서 실제로는 29 시드로 계산된다.
"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable
MERGER = os.path.join(HERE, "merge_shards.py")

FAILED = 0


def check(name, ok, detail=""):
    global FAILED
    print("  %s  %s   %s" % ("PASS" if ok else "FAIL", name, detail))
    if not ok:
        FAILED += 1


def row(case, seed, policy):
    return {"case": case, "ood_seed": seed, "policy": policy,
            "complete": True, "sim_seconds": 1.0 * seed, "closed": 10 + seed,
            "geometry": {"depot_distance": 20.0}}


def build_shards(root, case, seeds, policies, skip=()):
    """샤드 트리를 만든다. skip 에 든 (seed, policy) 는 일부러 빠뜨린다."""
    for s in seeds:
        d = os.path.join(root, case, "s%d" % s)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "rows.jsonl"), "w", encoding="utf-8") as fh:
            # 정책을 일부러 뒤섞어 쓴다 -- 병합이 정렬하는지 보려면 입력이 정렬돼 있으면 안 된다.
            for p in reversed(policies):
                if (s, p) in skip:
                    continue
                fh.write(json.dumps(row(case, s, p)) + "\n")


def run_merge(shards, out, cases, seeds, policies):
    p = subprocess.run([PY, MERGER, "--shards-dir", shards, "--out-dir", out,
                        "--cases", cases, "--seeds", seeds, "--policies", policies],
                       capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


POLICIES = ["noop", "surrogate", "dspy"]

print("== merge_shards.py ==")

with tempfile.TemporaryDirectory() as tmp:
    shards = os.path.join(tmp, "shards"); out = os.path.join(tmp, "out")
    build_shards(shards, "battery", [1, 2, 3], POLICIES)
    rc, log = run_merge(shards, out, "battery", "1,2,3", ",".join(POLICIES))
    check("완전한 샤드 트리는 통과", rc == 0, "rc=%d %s" % (rc, log.strip()[-200:]))

    merged = [json.loads(l) for l in
              open(os.path.join(out, "battery.jsonl"), encoding="utf-8") if l.strip()]
    check("행 수 = seeds x policies", len(merged) == 9, "n=%d" % len(merged))

    got = [(r["ood_seed"], r["policy"]) for r in merged]
    want = [(s, p) for s in (1, 2, 3) for p in POLICIES]
    check("(ood_seed, policy 정의 순서)로 정렬된다", got == want, "%s" % (got,))

with tempfile.TemporaryDirectory() as tmp:
    shards = os.path.join(tmp, "shards"); out = os.path.join(tmp, "out")
    build_shards(shards, "battery", [1, 2, 3], POLICIES, skip={(2, "dspy")})
    rc, log = run_merge(shards, out, "battery", "1,2,3", ",".join(POLICIES))
    check("행이 모자라면 실패", rc == 1, "rc=%d" % rc)
    check("빠진 (seed, policy)를 찍는다",
          "seed=2" in log and "dspy" in log, log.strip()[-300:])

with tempfile.TemporaryDirectory() as tmp:
    shards = os.path.join(tmp, "shards"); out = os.path.join(tmp, "out")
    build_shards(shards, "battery", [1], POLICIES)
    rc, log = run_merge(shards, out, "battery,fault", "1", ",".join(POLICIES))
    check("샤드 디렉토리가 통째로 없는 case 는 실패", rc == 1, "rc=%d" % rc)
    check("없는 case 이름을 찍는다", "fault" in log, log.strip()[-300:])

with tempfile.TemporaryDirectory() as tmp:
    shards = os.path.join(tmp, "shards"); out = os.path.join(tmp, "out")
    build_shards(shards, "battery", [1, 2, 3], POLICIES)
    run_merge(shards, out, "battery", "1,2,3", ",".join(POLICIES))
    first = open(os.path.join(out, "battery.jsonl"), encoding="utf-8").read()
    run_merge(shards, out, "battery", "1,2,3", ",".join(POLICIES))
    second = open(os.path.join(out, "battery.jsonl"), encoding="utf-8").read()
    check("두 번 돌려도 같은 파일 (덮어쓰기, 이어붙이기 아님)", first == second,
          "len %d vs %d" % (len(first), len(second)))

sys.exit(1 if FAILED else 0)
```

- [ ] **Step 2: 테스트를 돌려 실패를 확인한다**

Run:
```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python test_merge_shards.py
```
Expected: FAIL — `merge_shards.py` 가 없다.

- [ ] **Step 3: 병합기를 구현한다**

`wm4spacecraft_manufacturing/merge_shards.py`:

```python
"""샤드별 rows.jsonl 을 case 단위 평면 jsonl 로 병합한다.

build_final_table.py:301 이 `results_dir / "<case>.jsonl"` 를 읽으므로, 병렬 스윕이 만든
샤드 트리를 그 형태로 되돌려 놓아야 기존 리포트 도구가 수정 없이 돈다.

정렬이 핵심이다. 병렬에서는 샤드 완료 순서가 실행마다 다르므로, 완료 순서대로 붙이면 같은
데이터에서 매번 다른 파일이 나온다. (ood_seed, policy 정의 순서)로 정렬해 결정적으로 만든다.
"""
import argparse, json, sys
from pathlib import Path


def read_shard(path):
    """샤드 rows.jsonl 을 읽어 (rows, bad_lines) 로 돌려준다."""
    rows, bad = [], 0
    if not path.exists():
        return rows, bad
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                bad += 1
    return rows, bad


def merge_case(shards_dir, case, seeds, policies):
    """(rows_sorted, problems) 를 돌려준다. problems 는 사람이 읽을 문자열 목록."""
    rank = {p: i for i, p in enumerate(policies)}
    case_dir = shards_dir / case
    problems = []
    if not case_dir.is_dir():
        problems.append("case=%s 의 샤드 디렉토리가 없다: %s" % (case, case_dir))
        return [], problems

    found = {}          # (seed, policy) -> row
    for seed in seeds:
        shard = case_dir / ("s%d" % seed) / "rows.jsonl"
        rows, bad = read_shard(shard)
        if bad:
            problems.append("case=%s seed=%d 파싱 불가한 줄 %d개" % (case, seed, bad))
        for r in rows:
            pol = r.get("policy")
            if pol not in rank:
                problems.append("case=%s seed=%d 알 수 없는 policy=%r" % (case, seed, pol))
                continue
            key = (seed, pol)
            if key in found:
                problems.append("case=%s seed=%d policy=%s 행이 중복" % (case, seed, pol))
                continue
            found[key] = r

    for seed in seeds:
        for pol in policies:
            if (seed, pol) not in found:
                problems.append("case=%s seed=%d policy=%s 행이 없다" % (case, seed, pol))

    ordered = [found[(s, p)] for s in seeds for p in policies if (s, p) in found]
    return ordered, problems


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--shards-dir", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--cases", required=True, help="쉼표 구분")
    ap.add_argument("--seeds", required=True, help="쉼표 구분")
    ap.add_argument("--policies", default="noop,surrogate,dspy")
    args = ap.parse_args()

    shards_dir = Path(args.shards_dir)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    cases = [c.strip() for c in args.cases.split(",") if c.strip()]
    seeds = [int(s) for s in args.seeds.split(",") if s.strip()]
    policies = [p.strip() for p in args.policies.split(",") if p.strip()]
    expected = len(seeds) * len(policies)

    all_problems = []
    print("== 샤드 병합: %s -> %s ==" % (shards_dir, out_dir))
    for case in cases:
        rows, problems = merge_case(shards_dir, case, seeds, policies)
        out_path = out_dir / ("%s.jsonl" % case)
        # 이어붙이기가 아니라 덮어쓰기다. 재실행이 행을 두 배로 만들면 안 된다.
        with open(out_path, "w", encoding="utf-8") as fh:
            for r in rows:
                fh.write(json.dumps(r, ensure_ascii=False) + "\n")
        status = "OK" if (not problems and len(rows) == expected) else "INCOMPLETE"
        print("  %-11s %-14s %d/%d 행 -> %s" % (status, case, len(rows), expected,
                                                out_path.name))
        for p in problems:
            print("      - " + p)
        all_problems.extend(problems)

    if all_problems:
        print("\n문제 %d건. 병합 결과를 리포트에 쓰지 말 것." % len(all_problems))
        return 1
    print("\n모든 case 가 %d행으로 완전하다." % expected)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: 테스트를 돌려 통과를 확인한다**

Run:
```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python test_merge_shards.py
```
Expected: 9개 check 전부 PASS, exit 0.

- [ ] **Step 5: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/merge_shards.py \
        wm4spacecraft_manufacturing/test_merge_shards.py
git commit -m "feat(4pol): 샤드 병합기 -- 완료 순서와 무관하게 결정적, 부분 병합은 실패로"
```

---

## Task 4: 사전 조건 게이트 (P1~P4, P8)

**Files:**
- Create: `wm4spacecraft_manufacturing/gate_llm_concurrency.py`
- Create: `wm4spacecraft_manufacturing/gate_prereq.sh`

**Interfaces:**
- Consumes: 없음
- Produces:
  - `gate_llm_concurrency.py` — CLI `python gate_llm_concurrency.py --url URL --jobs K`. 동시 K 요청이 전부 성공하면 exit 0.
  - `gate_prereq.sh` — `bash gate_prereq.sh [K]`. P1~P4 와 P8 을 순서대로 돌고 하나라도 실패하면 어느 게이트인지 찍고 exit 1. `_night/provenance_4pol.json` 에 DSPy 프로그램 신원을 남긴다. Task 6 이 호출한다.

- [ ] **Step 1: LLM 동시성 게이트를 구현한다**

`wm4spacecraft_manufacturing/gate_llm_concurrency.py`:

```python
"""P8 -- DSPy 서비스가 동시 K 요청을 견디는지 확인한다.

왜 필요한가: 이 스윕의 dspy 레인은 210 판이고 판당 4~9 결정이라 약 840~1,890 회의 gpt-4o
호출이 발생한다. 샤드 안에서 정책이 순차이므로 동시 dspy 판은 최대 K 개다. 계정 rate limit 을
넘으면 429 가 돌아오는데, run_demo.jl 쪽에서는 그게 "그 판의 결정 실패"로 조용히 흡수될 수
있다 -- 스윕이 끝난 뒤 표를 보고서야 dspy 레인이 비었음을 알게 된다. 미리 K 개를 던져 본다.
"""
import argparse, json, sys, time
from concurrent.futures import ThreadPoolExecutor

import urllib.request
import urllib.error

PROBE = {
    "kind": "battery", "severity": 0.6, "soc": 0.12, "spare_count": 2,
    "agent_pending": 1, "progress": 0.4, "n_active": 4,
    "nl": "A transport robot reports state of charge 12 percent while carrying an assembly.",
}


def one(url, timeout):
    """(ok, detail) 를 돌려준다."""
    body = json.dumps(PROBE).encode("utf-8")
    req = urllib.request.Request(url + "/macro", data=body,
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            code = resp.getcode()
            payload = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return False, "HTTP %d (%.1fs)" % (e.code, time.time() - t0)
    except Exception as e:
        return False, "%s (%.1fs)" % (type(e).__name__, time.time() - t0)
    dt = time.time() - t0
    if code != 200:
        return False, "http_code=%d" % code
    if payload.get("error") is not None:
        return False, "error=%r" % payload.get("error")
    pol = payload.get("policy") or ""
    if not (isinstance(pol, str) and pol.startswith("dspy")):
        return False, "policy=%r (dspy 로 시작해야 한다)" % pol
    return True, "%.1fs" % dt


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", default="http://127.0.0.1:8090")
    ap.add_argument("--jobs", type=int, default=16)
    ap.add_argument("--timeout", type=float, default=120.0)
    args = ap.parse_args()

    print("== P8 LLM 동시성: %s 에 동시 %d 요청 ==" % (args.url, args.jobs))
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        results = list(ex.map(lambda _: one(args.url, args.timeout), range(args.jobs)))
    wall = time.time() - t0

    n_ok = sum(1 for ok, _ in results if ok)
    for i, (ok, detail) in enumerate(results):
        if not ok:
            print("  FAIL  요청 %d: %s" % (i, detail))
    print("  %d/%d 성공, 벽시계 %.1fs" % (n_ok, args.jobs, wall))
    if n_ok < args.jobs:
        print("  실패. K 를 낮추거나 계정 rate limit 을 확인할 것.")
        return 1
    print("  PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: 게이트 묶음을 구현한다**

`wm4spacecraft_manufacturing/gate_prereq.sh`:

```bash
#!/usr/bin/env bash
# =============================================================================
# gate_prereq.sh -- 병렬 스윕의 사전 조건 게이트.
#
# run_4pol.sh 의 P1~P6 을 계승하되 병렬 전제에 맞춰 고쳤다:
#   · P5 (pgrep julia 없어야 함) 는 **제거**했다. 병렬이 전제이므로 성립할 수 없고, 동시 실행
#     수는 스케줄러(xargs -P)가 보장한다.
#   · P6 (결과 디렉토리 청결) 은 샤드 단위 재개 판정으로 옮겼다(run_shard.sh).
#   · P8 (LLM 동시성) 을 새로 넣었다.
#
# 사용법:  bash gate_prereq.sh [JOBS]     (JOBS 기본 16)
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PY="$REPO/.venv/bin/python"
DSPY_URL="${DSPY_URL:-http://127.0.0.1:8090}"
JOBS="${1:-16}"
NIGHT_DIR="$HERE/_night"

cd "$HERE"
mkdir -p "$NIGHT_DIR"

echo "=== 사전 조건 게이트 (DSPY_URL=$DSPY_URL, JOBS=$JOBS) ==="

# ---- P1 살아있는 LLM 프로브 --------------------------------------------
P1_BODY='{"kind":"battery","severity":0.6,"soc":0.12,"spare_count":2,"agent_pending":1,"progress":0.4,"n_active":4,"nl":"A transport robot reports state of charge 12 percent while carrying an assembly."}'
P1_RESP=$(curl -s -w '\n%{http_code}' -X POST "$DSPY_URL/macro" \
    -H 'Content-Type: application/json' -d "$P1_BODY" 2>/dev/null)
P1_RC=$?
if [ $P1_RC -ne 0 ] || [ -z "$P1_RESP" ]; then
    echo "PREREQ FAIL: P1 -- curl 이 $DSPY_URL/macro 에 닿지 못했다 (rc=$P1_RC)"
    echo "  서비스를 띄웠는가?  cd $REPO/src/respec/llm_service && $PY -m uvicorn dspy_service:app --host 127.0.0.1 --port 8090"
    exit 1
fi
P1_CODE=$(printf '%s' "$P1_RESP" | tail -n1)
P1_BODY_OUT=$(printf '%s' "$P1_RESP" | sed '$d')
if [ "$P1_CODE" != "200" ]; then
    echo "PREREQ FAIL: P1 -- http_code=$P1_CODE"
    exit 1
fi
P1_OK=$(printf '%s' "$P1_BODY_OUT" | "$PY" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("0"); sys.exit(0)
pol = d.get("policy") or ""
print("1" if (d.get("error") is None and isinstance(pol, str) and pol.startswith("dspy")) else "0")
' 2>/dev/null || echo "0")
if [ "$P1_OK" != "1" ]; then
    echo "PREREQ FAIL: P1 -- error:null 이면서 policy 가 'dspy' 로 시작해야 한다: $P1_BODY_OUT"
    exit 1
fi
echo "[gate] P1 OK (살아있는 LLM 프로브)"

# ---- P2 health + 프로그램 신원 기록 -------------------------------------
# dspy_service.py:90 은 DSPY_PROGRAM 이 비면 컴파일된 gpt4o 프로그램으로 조용히 폴백한다.
# 그건 battery 전용 어휘라 zone 을 재면 어휘 밖을 재게 된다. 어느 프로그램이었는지 남기지
# 않으면 사후에 알 방법이 없다.
P2_RESP=$(curl -s -w '\n%{http_code}' "$DSPY_URL/health" 2>/dev/null)
P2_CODE=$(printf '%s' "$P2_RESP" | tail -n1)
P2_BODY=$(printf '%s' "$P2_RESP" | sed '$d')
if [ "$P2_CODE" != "200" ]; then
    echo "PREREQ FAIL: P2 -- http_code=$P2_CODE"
    exit 1
fi
printf '%s\n' "$P2_BODY" > "$NIGHT_DIR/provenance_4pol.json"
DSPY_PROGRAM=$(printf '%s' "$P2_BODY" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("program","?"))' 2>/dev/null || echo "?")
echo "[gate] P2 OK (health) -- program=$DSPY_PROGRAM"

# ---- P3 행동 어휘 감사 --------------------------------------------------
if ! "$PY" audit_action_vocab.py; then
    echo "PREREQ FAIL: P3 (audit_action_vocab.py)"
    exit 1
fi
echo "[gate] P3 OK (audit_action_vocab.py)"

# ---- P4 surrogate 지원 집합 계약 ----------------------------------------
if ! "$PY" test_surrogate_support.py; then
    echo "PREREQ FAIL: P4 (test_surrogate_support.py)"
    exit 1
fi
echo "[gate] P4 OK (test_surrogate_support.py)"

# ---- P8 LLM 동시성 ------------------------------------------------------
if ! "$PY" gate_llm_concurrency.py --url "$DSPY_URL" --jobs "$JOBS"; then
    echo "PREREQ FAIL: P8 (동시 $JOBS 요청)"
    exit 1
fi
echo "[gate] P8 OK (동시 $JOBS 요청)"

echo "=== 게이트 전부 통과 (program=$DSPY_PROGRAM) ==="
exit 0
```

- [ ] **Step 3: 서비스가 꺼진 상태에서 게이트가 실패하는지 확인한다**

Run:
```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
pkill -f "uvicorn dspy_service" 2>/dev/null; sleep 2
bash gate_prereq.sh 4; echo "rc=$? (1 이어야 한다)"
```
Expected: `PREREQ FAIL: P1` 과 서비스 기동 명령 안내, rc=1. 조용한 통과가 없어야 한다.

- [ ] **Step 4: 서비스를 띄우고 게이트가 통과하는지 확인한다**

Run:
```bash
cd /home/chahj578/Construction_OODlayer/src/respec/llm_service
nohup /home/chahj578/Construction_OODlayer/.venv/bin/python -m uvicorn dspy_service:app \
  --host 127.0.0.1 --port 8090 > /tmp/dspy_8090.log 2>&1 &
sleep 30
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
bash gate_prereq.sh 16; echo "rc=$?"
cat _night/provenance_4pol.json
```
Expected: P1~P4, P8 전부 OK, rc=0. `provenance_4pol.json` 에 `program` 필드가 있다.
P8 이 실패하면 `--jobs 8` 로 낮춰 재시험하고, **그 값이 본 스윕의 K 상한**이다.

- [ ] **Step 5: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/gate_llm_concurrency.py \
        wm4spacecraft_manufacturing/gate_prereq.sh
git commit -m "feat(4pol): 병렬용 사전 조건 게이트 -- P5 제거, P8 LLM 동시성 추가"
```

---

## Task 5: P7 분포 게이트

**Files:**
- Create: `wm4spacecraft_manufacturing/gate_load_distribution.py`
- Create: `wm4spacecraft_manufacturing/test_gate_load_distribution.py`

**Interfaces:**
- Consumes: Task 2 의 `run_shard.sh` (반복 실행으로 표본을 만든다)
- Produces: `gate_load_distribution.py` — CLI `python gate_load_distribution.py --solo-dir DIR --loaded-dir DIR [--alpha 0.05]`. 각 디렉토리 아래 `rep*/rows.jsonl` 을 읽어 `sim_seconds`·`closed` 는 Mann-Whitney U, `complete` 는 Fisher exact 로 비교한다. 전부 p > alpha 면 exit 0.

**왜 동일성이 아니라 분포인가:** 이 저장소의 시뮬레이션은 **순차 재실행에서도 재현되지 않는다**
(동일 코드·동일 워크트리에서 monitor frames 214→204, n_closed 149→123, 2026-08-11 실측).
"단독과 부하 하의 요약 행이 완전히 같아야 한다" 는 판정은 병렬이 원인인지 원래 그런지 구분하지
못한 채 무조건 불합격을 낸다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`wm4spacecraft_manufacturing/test_gate_load_distribution.py`:

```python
"""gate_load_distribution.py 판정 로직 테스트.

판정이 틀리면 게이트가 있으나 마나다. 두 방향 다 확인한다: 분포가 같으면 통과해야 하고,
확실히 옮겨졌으면 불합격해야 한다. 합성 표본으로 검사하므로 시뮬레이션을 돌리지 않는다.
"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable
GATE = os.path.join(HERE, "gate_load_distribution.py")

FAILED = 0


def check(name, ok, detail=""):
    global FAILED
    print("  %s  %s   %s" % ("PASS" if ok else "FAIL", name, detail))
    if not ok:
        FAILED += 1


def build(root, samples):
    """samples = [(sim_seconds, closed, complete), ...] -> rep1..repN/rows.jsonl"""
    for i, (secs, closed, comp) in enumerate(samples, 1):
        d = os.path.join(root, "rep%d" % i)
        os.makedirs(d, exist_ok=True)
        row = {"case": "zone", "ood_seed": 1, "policy": "noop",
               "sim_seconds": secs, "closed": closed, "complete": comp,
               "geometry": {"depot_distance": 20.0}}
        with open(os.path.join(d, "rows.jsonl"), "w", encoding="utf-8") as fh:
            fh.write(json.dumps(row) + "\n")


def run_gate(solo, loaded, alpha="0.05"):
    p = subprocess.run([PY, GATE, "--solo-dir", solo, "--loaded-dir", loaded,
                        "--alpha", alpha], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


SAME_A = [(20.0, 100, True), (21.0, 101, True), (19.5, 99, True), (20.5, 100, True),
          (20.2, 102, True), (19.8, 98, True), (21.2, 101, True), (20.1, 100, True)]
SAME_B = [(20.3, 101, True), (19.7, 99, True), (20.8, 100, True), (20.0, 102, True),
          (19.9, 98, True), (21.1, 101, True), (20.4, 100, True), (20.6, 99, True)]
# 부하 하에서 sim_seconds 가 통째로 밀린 표본. 8 vs 8 완전 분리면 Mann-Whitney 양측 p 는
# 2/12870*2 ~= 0.00031 로 alpha 아래다.
SHIFTED = [(40.0, 100, True), (41.0, 101, True), (39.5, 99, True), (40.5, 100, True),
           (40.2, 102, True), (39.8, 98, True), (41.2, 101, True), (40.1, 100, True)]
# 완주율만 갈린 표본: 단독 8/8 완주 vs 부하 하 1/8 완주. Fisher exact 양측 p ~= 0.001.
COMPLETE_SPLIT = [(20.0, 100, True)] + [(20.0 + 0.1 * i, 100, False) for i in range(7)]

print("== gate_load_distribution.py ==")

with tempfile.TemporaryDirectory() as tmp:
    solo = os.path.join(tmp, "solo"); loaded = os.path.join(tmp, "loaded")
    build(solo, SAME_A); build(loaded, SAME_B)
    rc, log = run_gate(solo, loaded)
    check("같은 분포면 통과", rc == 0, "rc=%d %s" % (rc, log.strip()[-200:]))

with tempfile.TemporaryDirectory() as tmp:
    solo = os.path.join(tmp, "solo"); loaded = os.path.join(tmp, "loaded")
    build(solo, SAME_A); build(loaded, SHIFTED)
    rc, log = run_gate(solo, loaded)
    check("sim_seconds 가 옮겨지면 불합격", rc == 1, "rc=%d" % rc)
    check("sim_seconds 를 지목한다", "sim_seconds" in log, log.strip()[-300:])

with tempfile.TemporaryDirectory() as tmp:
    solo = os.path.join(tmp, "solo"); loaded = os.path.join(tmp, "loaded")
    build(solo, SAME_A); build(loaded, COMPLETE_SPLIT)
    rc, log = run_gate(solo, loaded)
    check("완주율이 갈리면 불합격", rc == 1, "rc=%d" % rc)
    check("complete 를 지목한다", "complete" in log, log.strip()[-300:])

with tempfile.TemporaryDirectory() as tmp:
    solo = os.path.join(tmp, "solo"); loaded = os.path.join(tmp, "loaded")
    build(solo, SAME_A[:2]); build(loaded, SAME_B)
    rc, log = run_gate(solo, loaded)
    check("표본이 너무 적으면 불합격 (조용한 통과 금지)", rc == 1, "rc=%d" % rc)

with tempfile.TemporaryDirectory() as tmp:
    solo = os.path.join(tmp, "solo"); loaded = os.path.join(tmp, "loaded")
    os.makedirs(solo); build(loaded, SAME_B)
    rc, log = run_gate(solo, loaded)
    check("한쪽이 비면 불합격", rc == 1, "rc=%d" % rc)

sys.exit(1 if FAILED else 0)
```

- [ ] **Step 2: 테스트를 돌려 실패를 확인한다**

Run:
```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python test_gate_load_distribution.py
```
Expected: FAIL — `gate_load_distribution.py` 가 없다.

- [ ] **Step 3: 판정기를 구현한다**

`wm4spacecraft_manufacturing/gate_load_distribution.py`:

```python
"""P7 -- CPU 부하가 시뮬레이션 결과 분포를 옮기는지 검사한다.

이 저장소의 시뮬레이션은 순차 재실행에서도 재현되지 않는다(2026-08-11 실측: 동일 코드에서
monitor frames 214->204, n_closed 149->123, 원인 미상). 따라서 "단독과 부하 하가 완전히
같아야 한다"는 판정은 쓸 수 없다 -- 병렬이 원인인지 원래 그런지 구분하지 못한 채 무조건
불합격을 낸다. 대신 **분포**를 본다.

한계를 분명히 해 둔다: 8+8 표본은 큰 효과만 잡는다. 이 게이트는 "부하가 결과를 바꾸지
않는다"를 증명하지 않으며, **바꾼다는 뚜렷한 증거가 없음**을 확인하는 장치다.
"""
import argparse, json, sys
from pathlib import Path

from scipy.stats import mannwhitneyu, fisher_exact

MIN_N = 5     # 이보다 적으면 검정력이 사실상 0 이라 "통과"가 의미를 잃는다


def load_samples(root):
    """root/rep*/rows.jsonl 을 읽어 행 목록을 돌려준다."""
    rows = []
    for shard in sorted(Path(root).glob("rep*/rows.jsonl")):
        with open(shard, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    rows.append(json.loads(line))
    return rows


def compare_continuous(name, a, b, alpha):
    """(ok, detail). 두 표본이 모두 상수이고 값이 같으면 검정 없이 통과."""
    if set(a) == set(b) and len(set(a)) == 1:
        return True, "%s: 양쪽 모두 상수 %r -- 검정 생략" % (name, a[0])
    stat, p = mannwhitneyu(a, b, alternative="two-sided")
    ok = p > alpha
    return ok, ("%s: Mann-Whitney U=%.1f p=%.4f  (단독 중앙값 %.3f / 부하 중앙값 %.3f)"
                % (name, stat, p, sorted(a)[len(a) // 2], sorted(b)[len(b) // 2]))


def compare_complete(a, b, alpha):
    """a, b 는 bool 목록. 2x2 분할표에 Fisher exact."""
    table = [[sum(1 for x in a if x), sum(1 for x in a if not x)],
             [sum(1 for x in b if x), sum(1 for x in b if not x)]]
    if table[0][1] == 0 and table[1][1] == 0:
        return True, "complete: 양쪽 모두 전판 완주 -- 검정 생략"
    _, p = fisher_exact(table, alternative="two-sided")
    ok = p > alpha
    return ok, ("complete: Fisher exact p=%.4f  (단독 %d/%d 완주 / 부하 %d/%d 완주)"
                % (p, table[0][0], len(a), table[1][0], len(b)))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--solo-dir", required=True)
    ap.add_argument("--loaded-dir", required=True)
    ap.add_argument("--alpha", type=float, default=0.05)
    args = ap.parse_args()

    solo = load_samples(args.solo_dir)
    loaded = load_samples(args.loaded_dir)

    print("== P7 분포 게이트 (alpha=%g) ==" % args.alpha)
    print("  단독 표본 %d, 부하 하 표본 %d" % (len(solo), len(loaded)))

    if len(solo) < MIN_N or len(loaded) < MIN_N:
        print("  FAIL  표본이 %d 미만이다. 검정력이 없는 '통과'는 통과가 아니다." % MIN_N)
        return 1

    failures = []
    for key in ("sim_seconds", "closed"):
        a = [r[key] for r in solo if r.get(key) is not None]
        b = [r[key] for r in loaded if r.get(key) is not None]
        if len(a) < MIN_N or len(b) < MIN_N:
            print("  FAIL  %s 값이 있는 행이 부족하다 (단독 %d, 부하 %d)" % (key, len(a), len(b)))
            failures.append(key)
            continue
        ok, detail = compare_continuous(key, a, b, args.alpha)
        print("  %s  %s" % ("PASS" if ok else "FAIL", detail))
        if not ok:
            failures.append(key)

    a = [bool(r.get("complete")) for r in solo]
    b = [bool(r.get("complete")) for r in loaded]
    ok, detail = compare_complete(a, b, args.alpha)
    print("  %s  %s" % ("PASS" if ok else "FAIL", detail))
    if not ok:
        failures.append("complete")

    if failures:
        print("\n불합격 지표: %s" % ", ".join(failures))
        print("K 를 낮춰 재시험하고, 그래도 불합격이면 K=1 순차로 후퇴할 것.")
        return 1
    print("\n부하가 분포를 옮겼다는 증거 없음. 병렬 진행 가능.")
    print("주의: 8+8 표본은 큰 효과만 잡는다. 이것은 안전의 증명이 아니다.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: 테스트를 돌려 통과를 확인한다**

Run:
```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python test_gate_load_distribution.py
```
Expected: 7개 check 전부 PASS, exit 0.

- [ ] **Step 5: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/gate_load_distribution.py \
        wm4spacecraft_manufacturing/test_gate_load_distribution.py
git commit -m "feat(4pol): P7 분포 게이트 -- 동일성 판정은 순차에서도 실패하므로 분포로 본다"
```

---

## Task 6: 병렬 오케스트레이터

**Files:**
- Create: `wm4spacecraft_manufacturing/run_4pol_parallel.sh`

**Interfaces:**
- Consumes: `run_shard.sh` (Task 2), `gate_prereq.sh` (Task 4)
- Produces: `run_4pol_parallel.sh [--jobs K] [--seeds CSV] [--cases CSV] [--deadline-seconds N] [--shards-dir DIR] [--skip-gates] [--dry-run]`. 샤드를 `SHARDS/<case>/s<seed>/` 에 만들고 `_night/status_shards.jsonl` 에 샤드별 결과를 남긴다. Task 7 이 호출한다.

- [ ] **Step 1: 오케스트레이터를 작성한다**

`wm4spacecraft_manufacturing/run_4pol_parallel.sh`:

```bash
#!/usr/bin/env bash
# =============================================================================
# run_4pol_parallel.sh -- 7 case x 30 seed x 3 policy = 630 판을 K 병렬로 돈다.
#
# run_4pol.sh 를 대체하지 않는다. 그쪽은 순차 재현 경로로 남겨 둔다.
#
# 병렬이 가능한 근거 (docs/superpowers/specs/2026-08-12-parallel-30seed-sweep-design.md §2):
#   · HiGHS 경합 -- 이 경로는 run_demo.jl:387 이 assignment_mode=:greedy 라 MILP 를 안 푼다.
#   · OOM -- bethpage 가용 121 GB. K=16 이면 약 40 GB.
#   · MeshCat 포트 8700 -- run_demo.jl 에 MeshCat 이 없다(렌더는 render_demo.jl).
# 셋 다 이 경로에서 성립하지 않는다. 다만 그것이 "안전의 증명"은 아니므로 P7 게이트가 따로 있다.
#
# 사용법
#   bash run_4pol_parallel.sh --jobs 16
#   bash run_4pol_parallel.sh --dry-run                  # 작업 목록만 출력
#   bash run_4pol_parallel.sh --jobs 16 --seeds 1,2,3    # 일부만
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
cd "$HERE"

JOBS=16
SEEDS="1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30"
CASES="battery,fault,all,fault_battery,fault_zone,battery_zone,zone"
DEADLINE_SECONDS=28800          # 8 h
SHARDS_DIR="results_4pol/shards"
SKIP_GATES=0
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --jobs)              JOBS="$2"; shift 2 ;;
        --seeds)             SEEDS="$2"; shift 2 ;;
        --cases)             CASES="$2"; shift 2 ;;
        --deadline-seconds)  DEADLINE_SECONDS="$2"; shift 2 ;;
        --shards-dir)        SHARDS_DIR="$2"; shift 2 ;;
        --skip-gates)        SKIP_GATES=1; shift ;;
        --dry-run)           DRY_RUN=1; shift ;;
        *) echo "[error] 알 수 없는 인자: $1" >&2; exit 2 ;;
    esac
done

NIGHT_DIR="$HERE/_night"
STATUS_FILE="$NIGHT_DIR/status_shards.jsonl"
LOCK_FILE="$NIGHT_DIR/.status.lock"
mkdir -p "$NIGHT_DIR" "$SHARDS_DIR"

IFS=',' read -r -a SEED_ARR <<< "$SEEDS"
IFS=',' read -r -a CASE_ARR <<< "$CASES"
TOTAL=$(( ${#SEED_ARR[@]} * ${#CASE_ARR[@]} ))

# ---- 작업 목록 ----------------------------------------------------------
# seed 를 바깥, case 를 안쪽에 둔다. case 를 바깥에 두면 한 case 가 통째로 같은 시간대에
# 몰려 case 와 부하 조건이 교락된다. 이 순서면 어느 시각에도 여러 case 가 섞여 돈다.
# 값싼 case 를 앞세우는 비용 기반 재정렬은 하지 않는다 -- 같은 이유다.
JOBLIST="$NIGHT_DIR/joblist.txt"
: > "$JOBLIST"
for seed in "${SEED_ARR[@]}"; do
    for case in "${CASE_ARR[@]}"; do
        echo "$case $seed" >> "$JOBLIST"
    done
done

echo "=== run_4pol_parallel.sh ==="
echo "  case  ${#CASE_ARR[@]}개: $CASES"
echo "  seed  ${#SEED_ARR[@]}개: ${SEED_ARR[0]}..${SEED_ARR[${#SEED_ARR[@]}-1]}"
echo "  샤드  $TOTAL개 (판 $(( TOTAL * 3 ))개), 병렬 K=$JOBS"
echo "  데드라인 ${DEADLINE_SECONDS}s, 샤드 트리 $SHARDS_DIR"

if [ "$DRY_RUN" = "1" ]; then
    echo "--- 작업 목록 (앞 10줄 / 총 $(wc -l < "$JOBLIST")줄) ---"
    head -10 "$JOBLIST"
    exit 0
fi

# ---- 게이트 ------------------------------------------------------------
if [ "$SKIP_GATES" = "0" ]; then
    if ! bash gate_prereq.sh "$JOBS"; then
        echo "게이트 불합격 -- 스윕을 시작하지 않는다."
        exit 1
    fi
else
    echo "[warn] --skip-gates: 사전 조건 게이트를 건너뛴다."
fi

START_TIME=$(date +%s)
export START_TIME DEADLINE_SECONDS SHARDS_DIR STATUS_FILE LOCK_FILE HERE

# ---- 워커 --------------------------------------------------------------
# xargs 가 부르는 함수. 인자: CASE SEED
worker() {
    local case="$1" seed="$2"
    local outdir="$SHARDS_DIR/$case/s$seed"

    local now elapsed
    now=$(date +%s); elapsed=$(( now - START_TIME ))
    if [ "$elapsed" -ge "$DEADLINE_SECONDS" ]; then
        # 데드라인을 넘으면 새 샤드를 투입하지 않는다. 이미 도는 샤드는 건드리지 않는다.
        record_status "$case" "$seed" "deadline" 0 0
        echo "[deadline] SKIP case=$case seed=$seed (elapsed=${elapsed}s)"
        return 0
    fi

    local t0 rc dt rows
    t0=$(date +%s)
    bash "$HERE/run_shard.sh" "$case" "$seed" "$outdir"
    rc=$?
    dt=$(( $(date +%s) - t0 ))
    rows=0
    [ -f "$outdir/rows.jsonl" ] && rows=$(grep -c . "$outdir/rows.jsonl" 2>/dev/null || echo 0)
    record_status "$case" "$seed" "$([ $rc -eq 0 ] && echo ok || echo fail)" "$rows" "$dt"
    return 0        # 샤드 하나가 죽어도 스윕 전체는 계속 간다. 집계는 병합기가 판정한다.
}

# status 한 줄은 200 B 미만이라 O_APPEND 로 원자적이지만, flock 을 걸어 확실히 한다.
record_status() {
    local case="$1" seed="$2" status="$3" rows="$4" wall="$5"
    (
        flock 9
        printf '{"case":"%s","seed":%s,"status":"%s","rows":%s,"wall_seconds":%s}\n' \
            "$case" "$seed" "$status" "$rows" "$wall" >> "$STATUS_FILE"
    ) 9>"$LOCK_FILE"
}

export -f worker record_status

# ---- 실행 --------------------------------------------------------------
echo "=== 시작 $(date +%F' '%H:%M:%S) ==="
xargs -a "$JOBLIST" -n 2 -P "$JOBS" bash -c 'worker "$@"' _
echo "=== 종료 $(date +%F' '%H:%M:%S) ==="

# ---- 요약 --------------------------------------------------------------
"$REPO/.venv/bin/python" - "$STATUS_FILE" "$TOTAL" <<'PYEOF'
import json, sys
from collections import Counter
path, total = sys.argv[1], int(sys.argv[2])
seen, counts = {}, Counter()
with open(path, encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        seen[(r["case"], r["seed"])] = r["status"]      # 재실행 시 마지막 기록이 이긴다
for st in seen.values():
    counts[st] += 1
print("===== 샤드 요약 =====")
for st in ("ok", "fail", "deadline"):
    print("  %-9s %d" % (st, counts[st]))
print("  기록된 샤드 %d / 계획 %d" % (len(seen), total))
if counts["fail"]:
    print("  실패 샤드:")
    for (c, s), st in sorted(seen.items()):
        if st == "fail":
            print("    case=%s seed=%s" % (c, s))
PYEOF

exit 0
```

- [ ] **Step 2: 작업 목록 순서를 확인한다**

Run:
```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
bash run_4pol_parallel.sh --dry-run
wc -l _night/joblist.txt
head -8 _night/joblist.txt
```
Expected: `샤드 210개 (판 630개)`, `joblist.txt` 210줄. 앞 8줄이
`battery 1 / fault 1 / all 1 / fault_battery 1 / fault_zone 1 / battery_zone 1 / zone 1 / battery 2`
— seed 가 바깥, case 가 안쪽이다. case 가 연달아 뭉쳐 있으면 순서가 잘못된 것이다.

- [ ] **Step 3: 좁은 범위로 실제 병렬 실행을 확인한다**

DSPy 서비스가 떠 있는 상태에서:
```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
rm -f _night/status_shards.jsonl
time bash run_4pol_parallel.sh --jobs 4 --seeds 1,2 --cases battery,fault \
     --shards-dir /tmp/shards_smoke
```
Expected: 샤드 4개(`battery s1, fault s1, battery s2, fault s2`), 게이트 전부 OK, 요약에
`ok 4 / fail 0 / deadline 0`. 벽시계가 순차 예상(4 샤드 × 3판 × 약 180 s ≈ 36분)보다 뚜렷이
짧아야 한다 — K=4 면 10~15분.

동시에 다른 터미널에서 병렬이 실제로 도는지 확인:
```bash
watch -n 5 'pgrep -c -u $(id -u) julia; free -g | head -2'
```
julia 프로세스가 4개까지 올라가고 메모리가 여유 안에 머무는지 본다.

- [ ] **Step 4: 데드라인 가드를 확인한다**

Run:
```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
rm -f _night/status_shards.jsonl
bash run_4pol_parallel.sh --jobs 2 --seeds 1,2 --cases battery \
     --deadline-seconds 1 --shards-dir /tmp/shards_deadline --skip-gates
grep -c deadline _night/status_shards.jsonl
```
Expected: 데드라인이 1초라 모든 샤드가 `deadline` 로 기록되고 julia 가 하나도 뜨지 않는다.
요약에 `deadline 2`.

- [ ] **Step 5: 재개를 확인한다**

Run:
```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
time bash run_4pol_parallel.sh --jobs 4 --seeds 1,2 --cases battery,fault \
     --shards-dir /tmp/shards_smoke --skip-gates
```
Expected: 4개 샤드 전부 `[shard] SKIP`, 전체가 몇 초 안에 끝난다. 요약은 `ok 4`.

- [ ] **Step 6: 정리하고 커밋**

```bash
rm -rf /tmp/shards_smoke /tmp/shards_deadline
cd /home/chahj578/Construction_OODlayer
rm -f wm4spacecraft_manufacturing/_night/status_shards.jsonl
git add wm4spacecraft_manufacturing/run_4pol_parallel.sh
git commit -m "feat(4pol): 210샤드 K=16 병렬 오케스트레이터 + 데드라인/재개/샤드 status"
```

---

## Task 7: P7 게이트 실행 → 본 스윕 → 병합 → 리포트

**Files:**
- Modify: 없음 (앞 태스크들의 산출물을 실행한다)
- Create: `wm4spacecraft_manufacturing/results_4pol/*.jsonl` (7개, 각 90행), `_night/status_4pol.jsonl`

**Interfaces:**
- Consumes: Task 1~6 의 모든 산출물
- Produces: `artifacts_4pol/` 아래 최종 표와 리포트

- [ ] **Step 1: DSPy 서비스를 띄우고 살아 있는지 확인한다**

```bash
pkill -f "uvicorn dspy_service" 2>/dev/null; sleep 2
cd /home/chahj578/Construction_OODlayer/src/respec/llm_service
nohup /home/chahj578/Construction_OODlayer/.venv/bin/python -m uvicorn dspy_service:app \
  --host 127.0.0.1 --port 8090 > /tmp/dspy_8090.log 2>&1 &
sleep 30
curl -s 127.0.0.1:8090/health | head -c 400; echo
```
Expected: `program` 필드가 있는 JSON. 비어 있거나 연결이 안 되면 `/tmp/dspy_8090.log` 를 본다.

- [ ] **Step 2: P7 게이트의 단독 표본 8개를 만든다 (순차)**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
rm -rf results_gate && mkdir -p results_gate
for i in 1 2 3 4 5 6 7 8; do
  bash run_shard.sh zone 1 results_gate/solo/rep$i noop
done
grep -ch . results_gate/solo/rep*/rows.jsonl | paste -sd+ | bc   # 8 이어야 한다
```
`noop` 만 쓰는 이유: LLM 이 끼지 않아 부하 효과와 API 지연이 섞이지 않는다.
Expected: 8개 rep 디렉토리, 합계 8행. 판당 약 190 s 라 순차로 약 25분.

- [ ] **Step 3: P7 게이트의 부하 하 표본 8개를 만든다**

부하는 **본 스윕과 같은 종류의 샤드** 15개로 만든다. 인공 부하 생성기는 CPU/메모리 프로필이
달라 대표성이 없다. 이 15개 샤드의 산출물은 본 스윕에서 재개 규칙에 따라 그대로 재사용된다.

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
# 배경 부하: 본 스윕 샤드 15개를 K=15 로 띄운다
bash run_4pol_parallel.sh --jobs 15 --seeds 1,2 --cases battery,fault,all,fault_battery,fault_zone,battery_zone,zone \
     --shards-dir results_4pol/shards --skip-gates > _night/gate_load_background.log 2>&1 &
BG=$!
sleep 20        # 부하가 실제로 올라오길 기다린다
pgrep -c -u "$(id -u)" julia    # 15 근처여야 한다

# 부하가 도는 동안 측정 표본 8개를 순차로 뽑는다
for i in 1 2 3 4 5 6 7 8; do
  bash run_shard.sh zone 1 results_gate/loaded/rep$i noop
done

wait $BG
grep -ch . results_gate/loaded/rep*/rows.jsonl | paste -sd+ | bc   # 8 이어야 한다
```
Expected: 측정 8행. 배경 부하는 본 스윕 샤드 14개(zone s1 은 게이트가 쓰므로 겹치지 않게
`--seeds 1,2` 14샤드 중 진행된 만큼)를 만들어 두므로 버리지 않는다.

**주의:** 측정 중 `pgrep -c julia` 가 15 밑으로 떨어지면 부하가 빠진 것이다. 그 상태로 얻은
표본은 "부하 하"가 아니다. 배경 작업이 먼저 끝나면 `--seeds` 를 늘려 부하를 다시 채우고
측정을 처음부터 다시 한다.

- [ ] **Step 4: P7 판정을 돌린다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python gate_load_distribution.py \
  --solo-dir results_gate/solo --loaded-dir results_gate/loaded --alpha 0.05
echo "rc=$?"
```
Expected: rc=0 이면 K=16 으로 진행.
rc=1 이면 **본 스윕을 시작하지 않는다.** `--jobs 4` 로 Step 3~4 를 다시 하고, 그래도 불합격이면
K=1 순차로 후퇴한 뒤 시드 수를 줄이는 것을 사용자와 다시 상의한다.

- [ ] **Step 5: 게이트 결과를 기록으로 남긴다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
{
  echo "# P7 분포 게이트 결과 ($(date +%F' '%H:%M:%S), K=16)"
  echo '```'
  ../.venv/bin/python gate_load_distribution.py \
    --solo-dir results_gate/solo --loaded-dir results_gate/loaded --alpha 0.05
  echo '```'
} > _night/gate_p7_result.md
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/_night/gate_p7_result.md
git commit -m "data(4pol): P7 분포 게이트 실측 결과 (단독 8 vs 부하 하 8)"
```

이 기록은 비결정성 원인 규명(별도 과제)의 첫 체계적 표본이기도 하다 — 같은 (case, seed,
policy) 를 16회 반복한 원자료다.

- [ ] **Step 6: 본 스윕을 돌린다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
nohup bash run_4pol_parallel.sh --jobs 16 --deadline-seconds 28800 \
  > _night/parallel_sweep.log 2>&1 &
echo "PID=$!"
```
진행 확인:
```bash
tail -f /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/_night/parallel_sweep.log
# 다른 터미널에서
watch -n 30 'cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing; \
  echo "완료 샤드: $(find results_4pol/shards -name rows.jsonl | xargs grep -l . 2>/dev/null | wc -l)/210"; \
  pgrep -c -u $(id -u) julia; free -g | head -2'
```
Expected: 약 2.2~3.0 시간. 끝나면 요약에 `ok 210 / fail 0 / deadline 0`.
`fail` 이 있으면 Step 7 로 가기 전에 재실행한다 — 같은 명령을 다시 돌리면 완료된 샤드는
`SKIP` 되고 실패한 것만 다시 돈다.

- [ ] **Step 7: 샤드를 병합한다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
SEEDS=$(seq -s, 1 30)
../.venv/bin/python merge_shards.py \
  --shards-dir results_4pol/shards \
  --out-dir results_4pol \
  --cases battery,fault,all,fault_battery,fault_zone,battery_zone,zone \
  --seeds "$SEEDS" \
  --policies noop,surrogate,dspy
echo "rc=$?"
wc -l results_4pol/*.jsonl
```
Expected: rc=0, 7개 파일이 각각 90행. rc=1 이면 빠진 (case, seed, policy) 가 찍히므로 그
샤드만 다시 돌리고(`bash run_shard.sh <case> <seed> results_4pol/shards/<case>/s<seed>`)
병합을 다시 한다.

- [ ] **Step 8: 기하 provenance 를 검증한다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python check_geometry.py --results-dir results_4pol --expect-depot-distance 20.0
echo "rc=$?"
```
Expected: rc=0, "행 630개 검사 / 모든 행이 D=20".
rc=1 이면 D=40 행이나 구세대 행이 섞인 것이다 — **리포트를 만들지 말고 멈춘다.**

- [ ] **Step 9: case 단위 status 를 만든다**

`build_final_table.py:284` 가 `_night/status_4pol.jsonl` 을 읽는다. 병렬 스윕은 샤드 단위
status 를 쓰므로 case 단위로 접어 준다.

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python - <<'PYEOF'
import json
from collections import defaultdict
from pathlib import Path

night = Path("_night")
program = "?"
prov = night / "provenance_4pol.json"
if prov.exists():
    program = json.loads(prov.read_text(encoding="utf-8")).get("program", "?")

seen = {}
with open(night / "status_shards.jsonl", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if line:
            r = json.loads(line)
            seen[(r["case"], r["seed"])] = r      # 재실행 시 마지막 기록이 이긴다

agg = defaultdict(lambda: {"rows": 0, "wall": 0, "bad": 0})
for (case, _seed), r in seen.items():
    a = agg[case]
    a["rows"] += r["rows"]
    a["wall"] += r["wall_seconds"]
    if r["status"] != "ok":
        a["bad"] += 1

seeds = ",".join(str(i) for i in range(1, 31))
out = night / "status_4pol.jsonl"
with open(out, "w", encoding="utf-8") as fh:
    for case in sorted(agg):
        a = agg[case]
        fh.write(json.dumps({
            "case": case,
            "status": "ok" if a["bad"] == 0 else "fail",
            "rows": a["rows"],
            "wall_seconds": a["wall"],       # 샤드 벽시계의 합 = 코어·시간. 벽시계 아님
            "seeds": seeds,
            "policies": "noop,surrogate,dspy",
            "program": program,
        }, ensure_ascii=False) + "\n")
print("wrote %s (%d case)" % (out, len(agg)))
PYEOF
cat _night/status_4pol.jsonl
```
Expected: 7줄, 각 `rows: 90`, `status: "ok"`.
`wall_seconds` 는 **샤드 벽시계의 합**이라 병렬 실행의 실제 벽시계가 아니다 — 코어·시간이다.
`_night/parallel_sweep.log` 의 시작/종료 시각이 실제 벽시계다.

- [ ] **Step 10: 리포트를 생성한다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python build_final_table.py --results-dir results_4pol --out-dir artifacts_4pol
echo "final_table rc=$?"
../.venv/bin/python build_md_report.py --results-dir results_4pol --out-dir artifacts_4pol \
  --oracle-dir oracle/out --night-dir _night
echo "md_report rc=$?"
ls -la artifacts_4pol/
```
Expected: 둘 다 rc=0. `artifacts_4pol/` 에 표와 마크다운 리포트.
표의 n 이 30 으로 찍히는지 확인한다 — 5 나 20 으로 남아 있으면 `--seeds` 가 안 먹은 것이다.

- [ ] **Step 11: 결과를 커밋한다**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/results_4pol/*.jsonl \
        wm4spacecraft_manufacturing/_night/status_4pol.jsonl \
        wm4spacecraft_manufacturing/_night/status_shards.jsonl \
        wm4spacecraft_manufacturing/_night/provenance_4pol.json \
        wm4spacecraft_manufacturing/artifacts_4pol
git commit -m "data(4pol): 7case x 30seed x 3policy = 630판, D=20 기하, K=16 병렬"
```

샤드 트리(`results_4pol/shards/`)는 커밋하지 않는다 — 스트림 로그까지 합쳐 수 GB 다.
`git add` 에 경로를 명시하는 것에 주의한다. **`git add -A` 나 `git stash -u` 를 쓰지 않는다**
(`.venv/` 가 `.gitignore` 에 없어 16,833개 파일이 함께 딸려 온다).

---

## Self-Review

**1. 스펙 커버리지**

| 스펙 절 | 담당 태스크 |
|---|---|
| §1 목표·성공기준 1 (case 당 90행) | Task 3 병합기 검증, Task 7 Step 7 |
| §1 성공기준 2 (전부 D=20) | Task 1 검사기, Task 7 Step 8 |
| §1 성공기준 3 (병렬 편향 사전 증거) | Task 5, Task 7 Step 2~5 |
| §1 성공기준 4 (리포트 도구 무수정) | Task 3 평면 병합, Task 7 Step 9~10 |
| §2 금지 근거 재검토 | Task 6 스크립트 머리말에 근거 기록 |
| §3 샤딩 | Task 2 |
| §4 드라이버 (xargs, 스레드 고정, 데드라인, 작업 순서) | Task 6 |
| §5 게이트 P1~P4, P5 제거, P6 재정의, P8 | Task 4 (P6 재정의는 Task 2 의 재개 판정) |
| §5.1 P7 분포 게이트 | Task 5, Task 7 Step 2~5 |
| §6 병합 + status | Task 3, Task 7 Step 7·9 |
| §7 오류 처리·재개 | Task 2 재개, Task 6 워커, Task 7 Step 6 재실행 |
| §8 D=40 격리 | Task 1 Step 6 |
| §9 범위 밖 | Task 7 Step 5 가 원자료를 남긴다 |

빠진 요구사항 없음.

**2. 플레이스홀더 점검** — TBD/TODO 없음. 모든 코드 단계에 실제 코드가 있다.

**3. 타입·이름 일관성**

- 요약 행 키: `ood_seed`, `policy`, `closed`, `sim_seconds`, `complete`, `geometry.depot_distance` — Task 1·3·5·7 에서 동일하게 쓴다. `n_closed`/`seed` 로 쓴 곳 없음.
- `run_shard.sh CASE SEED OUTDIR [POLICIES]` — Task 6 워커와 Task 7 Step 2·3 이 같은 시그니처로 호출한다.
- `merge_shards.py --shards-dir/--out-dir/--cases/--seeds/--policies` — Task 3 정의와 Task 7 Step 7 호출이 일치한다.
- `gate_load_distribution.py --solo-dir/--loaded-dir/--alpha` — Task 5 정의와 Task 7 Step 4·5 호출이 일치한다.
- `check_geometry.py --results-dir/--expect-depot-distance` — Task 1 정의와 Task 2 Step 4, Task 7 Step 8 호출이 일치한다.
- 샤드 경로 규약 `<shards-dir>/<case>/s<seed>/rows.jsonl` — Task 2·3·6·7 에서 동일.
