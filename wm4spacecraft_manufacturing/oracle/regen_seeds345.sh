#!/usr/bin/env bash
# Grow the labeled set: add seeds 3,4,5 for the VALIDATED kinds (battery + fault + faultidle),
# matching the existing graded_hs configuration exactly so the new instances merge with the old 20.
#   - hot-swap ON (DS_HOTSWAP=1)  -> same world as graded_hs_all
#   - battery severities 0.05,0.12,0.2,0.35,0.6  (the ladder already in the set; NOT the DS_BSOC default)
#   - fault spare levels 0,3 ; faultidle spares 3
# zoneblk/zoneharm are deliberately EXCLUDED: the manual flags zone recovery as blocked upstream
# (every new zone label collapses to NOOP until the staging-geometry drift is fixed).
# (검증된 kind만 seed 3,4,5 추가 -> 인스턴스 20 -> 44. zone은 상류 이슈로 제외.)
#
# MEMORY: each labeler process peaks around 1.2-2 GB (run_with_stack allocates a big stack). On a
# 16 GB box, 9 at once exhausted RAM and three jobs died with OutOfMemoryError -- hence the strict
# one-at-a-time launch gate below and a default cap of 4.
# (동시 9개는 메모리 초과로 3개가 죽었다. 그래서 한 개씩 띄우며 상한을 지킨다. 기본 4.)
#
# Usage:  bash oracle/regen_seeds345.sh [max_parallel]
set -u
# 경로는 스크립트 위치에서 유도(절대경로 하드코딩은 다른 머신에서 깨진다).
WM="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CB="$(cd "$WM/.." && pwd)"
OUTDIR="$WM/oracle/out/graded_hs_s345"
LOGDIR="$WM/sweep_lab/regen_logs"
MAXP="${1:-5}"
# 판당 스택. 기본 2GB는 5병렬에서 메모리를 다 먹는다. 512MB로 1인스턴스 스모크를 돌려
# 라벨이 2GB 실행과 완전히 동일함을 확인했으므로(closed/makespan 일치, StackOverflow 없음) 512MB를 쓴다.
STACK="${DS_STACK:-536870912}"
mkdir -p "$OUTDIR" "$LOGDIR"
touch "$LOGDIR/_progress.log"

# job 목록: "tag|기대행수|DS_* 환경변수들"
JOBS=()
for seed in 3 4 5; do
  JOBS+=("battery_s${seed}|25|DS_KINDS=battery DS_SEEDS=$seed DS_BSOC=0.05,0.12,0.2,0.35,0.6")
  JOBS+=("fault_s${seed}|10|DS_KINDS=fault DS_SEEDS=$seed DS_SPARES=0,3")
  JOBS+=("faultidle_s${seed}|5|DS_KINDS=faultidle DS_SEEDS=$seed DS_SPARES=3")
done

for spec in "${JOBS[@]}"; do
  tag="${spec%%|*}"; rest="${spec#*|}"; want="${rest%%|*}"; vars="${rest#*|}"
  # 이미 완결된 job은 건너뛴다(OOM으로 중단된 실행을 이어서 돌리기 위함).
  have=$(wc -l < "$OUTDIR/${tag}.jsonl" 2>/dev/null || echo 0)
  if [ "$have" -ge "$want" ]; then
    echo "[skip] $tag already complete ($have/$want rows)" >> "$LOGDIR/_progress.log"; continue
  fi
  while [ "$(jobs -r | wc -l)" -ge "$MAXP" ]; do sleep 10; done   # 상한을 넘지 않게 한 개씩 대기 후 투입
  echo "[launch] $tag ($(date +%H:%M:%S))" >> "$LOGDIR/_progress.log"
  ( cd "$CB" && env $vars DS_HOTSWAP=1 DS_STACK="$STACK" DS_OUT="$OUTDIR/${tag}.jsonl" \
      julia +lts --project=. "$WM/oracle/gen_oracle_dataset.jl" \
      > "$LOGDIR/${tag}.log" 2>&1
    echo "[done] $tag exit=$? rows=$(wc -l < "$OUTDIR/${tag}.jsonl" 2>/dev/null) ($(date +%H:%M:%S))" \
      >> "$LOGDIR/_progress.log" ) &
  sleep 20                                    # 시작 시점을 어긋나게 해 프리컴파일/스택 할당 동시 폭주 방지
done
wait
echo "ALL JOBS FINISHED"
cat "$LOGDIR/_progress.log"
wc -l "$OUTDIR"/*.jsonl 2>/dev/null
