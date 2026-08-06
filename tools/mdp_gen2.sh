#!/usr/bin/env bash
# =============================================================================
# mdp_gen2.sh — 교정된 에피소드 설정으로 대량 생성 (2026-08-02 12:15~)
#
# 무엇이 교정됐나 (이전 데이터와 섞으면 안 되는 이유):
#   · DS_EP_LO/HI = [70,230].  기본 [8,60] 은 이 빌드가 첫 배치에서 closed 0->58 로
#     한 번에 뛰므로 세 사건이 **같은 스텝에 동시 발화**했다(tau_to_next 전부 0).
#     교정 후 tau = 21~103 으로 실제 분리 확인됨.
#   · capture_raw 가 X_C(커밋먼트)/X_G(기하)/X_A(부품 위치) 원자료를 덤프한다.
#   · 에피소드 행에 hist_* 이력 채널이 붙는다(T2 검정의 전제).
# 옛 ep_*.jsonl 에는 이 셋이 전부 없다 -> 합쳐 읽으면 결측이 0.0 으로 채워져
# **가짜 신호**가 된다. 그래서 이 스크립트의 산출물은 ep2_ 접두로만 읽는다.
#
# 운영: 2병렬 고정(프로세스당 ~2.5GB), 스크립트명 기반 킬러 없음, 그룹 단위 내구성.
# =============================================================================
cd "$(dirname "$0")/.." || exit 1
WM="$PWD/wm4spacecraft_manufacturing"; OUT="$WM/artifacts_mdp"; LOG="$OUT/gen2.log"
mkdir -p "$OUT"
export PYTHONIOENCODING=utf-8
say () { echo "[$(date '+%m-%d %H:%M:%S')] [gen2] $*" | tee -a "$LOG"; }

# 이전 실행 seeds 41~58 은 이미 있다. 이어서 59~ 로 확장한다.
SEED_GROUPS=("59,60,61" "62,63,64" "65,66,67" "68,69,70" "71,72,73" "74,75,76"
             "77,78,79" "80,81,82" "83,84,85" "86,87,88" "89,90,91" "92,93,94"
             "95,96,97" "98,99,100" "101,102,103" "104,105,106")
say "시작: ${#SEED_GROUPS[@]} 그룹 × 3 seed = $((${#SEED_GROUPS[@]}*3)) seed, 2병렬"

i=0
while [ $i -lt ${#SEED_GROUPS[@]} ]; do
  for slot in 1 2; do
    [ $i -ge ${#SEED_GROUPS[@]} ] && break
    S="${SEED_GROUPS[$i]}"; TAG="q$(printf '%02d' $i)"
    ( DS_EPISODE_N=3 DS_SEEDS="$S" DS_MC_K=1 DS_VALID_ONLY=1 DS_HOTSWAP=1 \
      DS_EP_LO=70 DS_EP_HI=230 \
      DS_NOPROG=6000 DS_STACK=1000000000 \
      DS_OUT="$WM/oracle/out/ep2_${TAG}.jsonl" \
      julia +lts --project=. "$WM/oracle/gen_oracle_dataset.jl" > "$OUT/gen2_${TAG}.log" 2>&1
      echo "$(date '+%H:%M:%S') $TAG seeds=$S rc=$? rows=$(wc -l < "$WM/oracle/out/ep2_${TAG}.jsonl" 2>/dev/null || echo 0)" >> "$LOG" ) &
    i=$((i+1))
  done
  wait
  N=$(cat "$WM"/oracle/out/ep2_[pq][0-9][0-9].jsonl 2>/dev/null | grep -c .)
  say "   $i/${#SEED_GROUPS[@]} 그룹 완료, 결정행 누적 $N"
  # 그룹이 끝날 때마다 중간 분석을 갱신한다. 도중에 중단돼도 최신 결과가 남는다.
  ( cd "$WM" && python -u overnight_mdp.py --glob='oracle/out/ep2_[pq][0-9][0-9].jsonl' ) \
    > "$OUT/ep2_only_analysis.txt" 2>&1
  say "   중간 분석 갱신 -> artifacts_mdp/ep2_only_analysis.txt"
done

say "=== 생성 완료 ==="
