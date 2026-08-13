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

# 파일이 없거나 비어도 정수 하나만 낸다.
# (컨트롤러 수정: grep -c 는 매치 0건이어도 stdout 에 "0" 을 찍고 rc=1 로 끝나므로
#  `grep -c . "$f" 2>/dev/null || echo 0` 형태에서는 "0" 출력과 "|| echo 0" 의 "0" 출력이
#  둘 다 잡혀 "$rows" 가 "0\n0" 두 줄짜리 문자열이 된다. 그러면 뒤의
#  `[ "$rows" -lt "$N_POLICIES" ]` 가 "integer expression expected" 를 내며 거짓으로 평가돼,
#  rows.jsonl 이 비어 있는 샤드도 [shard] OK 로 보고되는 조용한 오탐이 생긴다.)
count_rows() {
    local f="$1" n
    [ -f "$f" ] || { echo 0; return; }
    n=$(grep -c . "$f" 2>/dev/null)
    echo "${n:-0}"
}

# 재개: 이미 기대한 행 수가 있으면 다시 돌지 않는다.
if [ -f "$ROWS" ]; then
    have=$(count_rows "$ROWS")
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

rows=$(count_rows "$ROWS")

if [ "$rc" -ne 0 ] || [ "$rows" -lt "$N_POLICIES" ]; then
    echo "[shard] FAIL  case=$CASE seed=$SEED rc=$rc rows=$rows/$N_POLICIES ${dt}s -> $OUTDIR/shard.log"
    exit 1
fi
echo "[shard] OK    case=$CASE seed=$SEED rows=$rows ${dt}s"
exit 0
