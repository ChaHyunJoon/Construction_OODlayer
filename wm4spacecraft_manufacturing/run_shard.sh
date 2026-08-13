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
# 재개(SKIP)와 provenance -- SHARD_IGNORE_PROVENANCE
# --------------------------------------------------
# 샤드가 완주하면 OUTDIR/.shard_meta 에 "어느 코드 세대가 이걸 만들었나"(git HEAD 짧은 SHA +
# 정책 문자열)를 남긴다. 재개할 때는 행 수만 보지 않고 그 도장을 본다:
#   · 도장이 있고 SHA 가 지금 HEAD 와 같다  -> SKIP (same commit)
#   · 도장이 없거나 SHA/정책이 다르다        -> STALE, 디렉토리를 비우고 **재실행**
# 왜: 행 수만 보는 재개는 "버그 수정 **전에** 만들어진 샤드"를 그대로 SKIP 하고 병합에 넣는다.
# 2026-08-12 밤에 실제로 그럴 뻔했다. 행 수는 옳은 판과 틀린 판을 구분하지 못한다.
# 옛 동작(행 수만 보고 SKIP)이 정말 필요하면 `SHARD_IGNORE_PROVENANCE=1` 을 준다.
# 한계: HEAD SHA 는 **커밋된 것**만 본다. 작업 트리의 미커밋 수정은 잡지 못한다.
#
# 사용법
#   bash run_shard.sh battery 3 results_4pol/shards/battery/s3
#   bash run_shard.sh zone 1 results_gate/solo/rep1 noop
#   DRY_RUN=1 bash run_shard.sh battery 3 /tmp/x        # 명령만 출력
#   SHARD_IGNORE_PROVENANCE=1 bash run_shard.sh ...     # 옛 동작(행 수만 보고 SKIP)
# =============================================================================
set -uo pipefail

if [ $# -lt 3 ]; then
    echo "usage: run_shard.sh CASE SEED OUTDIR [POLICIES]" >&2
    exit 2
fi

CASE="$1"; SEED="$2"; OUTDIR="$3"; POLICIES="${4:-noop,surrogate,dspy}"

# OUTDIR 을 **지금 이 cwd 기준으로** 절대경로로 못박는다. 아래에서 `cd "$HERE"` 를 하는데,
# 재개 검사/rm -rf/mkdir 는 cd 전에 일어나고 llm_ood_eval.py 에는 cd 후에 같은 문자열을 넘긴다 --
# 상대 OUTDIR 를 다른 cwd 에서 주면 한 디렉토리를 검사하고 다른 디렉토리에 쓰게 된다.
case "$OUTDIR" in
    /*) ;;
    *)  OUTDIR="$PWD/$OUTDIR" ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PY="$REPO/.venv/bin/python"
DSPY_URL="${DSPY_URL:-http://127.0.0.1:8090}"

# 정책 개수 = 완주 판정에 쓸 기대 행 수
N_POLICIES=$(printf '%s' "$POLICIES" | tr ',' '\n' | grep -c . )
# POLICIES 가 퇴화하면(빈 문자열, "," 등) N_POLICIES 가 0 이 되고, 그러면 `rows -lt 0` 이 영영
# 거짓이라 **행이 하나도 없는 샤드도 [shard] OK** 로 보고된다. 인자 오류로 잡는다.
if [ "${N_POLICIES:-0}" -lt 1 ]; then
    printf 'usage: run_shard.sh CASE SEED OUTDIR [POLICIES]\n' >&2
    printf '       POLICIES=%q 에서 정책 이름을 하나도 뽑지 못했다(개수 0).\n' "$POLICIES" >&2
    printf '       콤마로 구분된 이름이 최소 하나 있어야 한다 (예: noop,surrogate,dspy).\n' >&2
    exit 2
fi
ROWS="$OUTDIR/rows.jsonl"
META="$OUTDIR/.shard_meta"

# 지금 코드 세대. git 을 못 읽으면 빈 문자열(그 경우 provenance 검사를 켤 수 없다).
HEAD_SHA="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || true)"

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

# .shard_meta 에서 key 하나를 읽는다(없으면 빈 문자열).
meta_get() {
    local key="$1"
    [ -f "$META" ] || return 0
    sed -n "s/^${key}=//p" "$META" | head -1
}

# 재개: 이미 기대한 행 수가 있으면 다시 돌지 않는다 -- 단, 같은 코드 세대에서 나온 것일 때만.
if [ -f "$ROWS" ]; then
    have=$(count_rows "$ROWS")
    if [ "$have" -ge "$N_POLICIES" ]; then
        built_sha="$(meta_get commit)"
        built_pol="$(meta_get policies)"
        if [ "${SHARD_IGNORE_PROVENANCE:-0}" = "1" ]; then
            echo "[shard] SKIP  case=$CASE seed=$SEED  (rows=$have >= $N_POLICIES, SHARD_IGNORE_PROVENANCE=1 -- 세대 검사 생략)"
            exit 0
        elif [ -z "$HEAD_SHA" ]; then
            echo "[shard] SKIP  case=$CASE seed=$SEED  (rows=$have >= $N_POLICIES, git HEAD 을 읽을 수 없어 세대 검사 불가)"
            exit 0
        elif [ -z "$built_sha" ]; then
            echo "[shard] STALE case=$CASE seed=$SEED  (provenance 도장 없음, now $HEAD_SHA) -> 재실행"
            rm -rf "$OUTDIR"
        elif [ "$built_sha" != "$HEAD_SHA" ]; then
            echo "[shard] STALE case=$CASE seed=$SEED  (built at $built_sha, now $HEAD_SHA) -> 재실행"
            rm -rf "$OUTDIR"
        elif [ "$built_pol" != "$POLICIES" ]; then
            echo "[shard] STALE case=$CASE seed=$SEED  (built with policies=$built_pol, now $POLICIES) -> 재실행"
            rm -rf "$OUTDIR"
        else
            echo "[shard] SKIP  case=$CASE seed=$SEED  (rows=$have >= $N_POLICIES, same commit $HEAD_SHA)"
            exit 0
        fi
    else
        # 행이 모자라면 부분 산출물이다. 이어 붙이면 중복 행이 생기므로 자리를 비우고 다시 돈다.
        echo "[shard] PARTIAL case=$CASE seed=$SEED rows=$have -> 디렉토리를 비우고 재실행"
        rm -rf "$OUTDIR"
    fi
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

# provenance 도장은 **완주한 샤드에만** 남긴다. 실패/부분 산출물에 남기면 다음 재개가 그걸
# "이 세대의 완성품" 으로 읽는다.
{
    printf 'commit=%s\n'   "$HEAD_SHA"
    printf 'policies=%s\n' "$POLICIES"
    printf 'case=%s\n'     "$CASE"
    printf 'seed=%s\n'     "$SEED"
    printf 'rows=%s\n'     "$rows"
    printf 'built_at=%s\n' "$(date -Iseconds)"
} > "$META"

echo "[shard] OK    case=$CASE seed=$SEED rows=$rows ${dt}s (commit ${HEAD_SHA:-unknown})"
exit 0
