#!/usr/bin/env bash
# 에피소드 데이터 확장 생성기.
#   · 2병렬 고정: 3병렬 × 1GB 스택이 OutOfMemoryError 로 샤드를 죽였다(실측 2회).
#     프로세스당 실측 ~2.5GB(heap+stack), 여유 5.5GB -> 2개가 상한.
#   · seed 그룹 단위로 돌려 한 그룹이 죽어도 나머지는 계속된다. JSONL 은 행 단위 flush 라
#     죽은 그룹의 데이터도 거기까지는 살아남는다.
#   · 스크립트명으로 프로세스를 죽이는 감시기는 두지 않는다(지난번 그게 보완 생성을 잘랐다).
cd "$(dirname "$0")/.." || exit 1
WM="$PWD/wm4spacecraft_manufacturing"; OUT="$WM/artifacts_mdp"; LOG="$OUT/ep_gen.log"
mkdir -p "$OUT"
say () { echo "[$(date '+%H:%M:%S')] [epgen] $*" | tee -a "$LOG"; }

SEED_GROUPS=("9,10,11" "12,13,14" "15,16,17" "18,19,20" "21,22,23" "24,25,26" "27,28,29" "30,31,32")
say "시작: ${#SEED_GROUPS[@]} 그룹 × 3 seed, 2병렬"
i=0
while [ $i -lt ${#SEED_GROUPS[@]} ]; do
  for slot in 1 2; do
    [ $i -ge ${#SEED_GROUPS[@]} ] && break
    S="${SEED_GROUPS[$i]}"; TAG="g$(printf '%02d' $i)"
    ( DS_EPISODE_N=3 DS_SEEDS="$S" DS_MC_K=1 DS_VALID_ONLY=1 DS_HOTSWAP=1 \
      DS_NOPROG=6000 DS_STACK=1000000000 \
      DS_OUT="$WM/oracle/out/ep_${TAG}.jsonl" \
      julia +lts --project=. "$WM/oracle/gen_oracle_dataset.jl" > "$OUT/epgen_${TAG}.log" 2>&1
      echo "$(date '+%H:%M:%S') $TAG seeds=$S rc=$? rows=$(wc -l < "$WM/oracle/out/ep_${TAG}.jsonl" 2>/dev/null || echo 0)" >> "$LOG" ) &
    i=$((i+1))
  done
  wait
  say "누적 행수: $(cat "$WM"/oracle/out/ep_*.jsonl 2>/dev/null | grep -c . )"
done
say "생성 완료. 재분석 실행."
( cd "$WM" && PYTHONIOENCODING=utf-8 python -u overnight_mdp.py --glob='oracle/out/ep_*.jsonl' ) \
  > "$OUT/ep_analysis.txt" 2>&1
say "=== 완료: artifacts_mdp/ep_analysis.txt ==="
