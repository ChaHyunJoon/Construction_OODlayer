#!/usr/bin/env bash
# 보완 생성: NOOP 이 정답인 "무해 변형"(faultidle / zoneharm) 을 추가해 결정 문제를 되살린다.
#
# 왜 필요한가: 1차 생성은 DS_KINDS=fault,battery,zoneblk 만 써서 **개입이 항상 옳은** 데이터가
# 됐다. admissible 18개의 정답이 전부 Replace 라 surrogate 가 "항상 Replace"만 해도 regret 0 —
# Router 를 평가할 판별 문제가 존재하지 않는다. 무해 변형을 넣어야 "언제 개입하지 않을 것인가"가
# 학습·평가 대상이 된다.
#
# 메모리: 앞서 6병렬 × 1GB 스택이 OOM 으로 샤드 3개를 죽였다. 3병렬 고정 + STEP6 종료 후 시작.
cd "$(dirname "$0")/.." || exit 1
REPO="$PWD"; WM="$REPO/wm4spacecraft_manufacturing"; OUT="$WM/artifacts_mdp"
LOG="$OUT/overnight.log"
say () { echo "[$(date '+%H:%M:%S')] [supp] $*" | tee -a "$LOG"; }

say "STEP 6 시뮬 종료 대기 (메모리 경합 방지)"
W=0
while [ $W -lt 7200 ]; do
  [ "$(ps -W 2>/dev/null | grep -ci julia)" -eq 0 ] && break
  sleep 60; W=$((W+60))
done
say "보완 생성 시작 (faultidle + zoneharm, 3병렬, seeds 1-9)"
for tag in a b c; do
  case $tag in a) S="1,2,3";; b) S="4,5,6";; c) S="7,8,9";; esac
(
  DS_SEEDS="$S" DS_KINDS="faultidle,zoneharm" DS_SPARES=3 \
  DS_MC_K=5 DS_VALID_ONLY=1 DS_HZ_SEED0=1000 DS_HOTSWAP=1 DS_NOPROG=6000 \
  DS_STACK=1000000000 \
  DS_OUT="$WM/oracle/out/mcds_harm_${tag}.jsonl" \
  julia +lts --project=. "$WM/oracle/gen_oracle_dataset.jl" > "$OUT/supp_${tag}.log" 2>&1
) &
done
wait
say "보완 생성 완료. 총 원시 행: $(cat "$WM"/oracle/out/mcds_*.jsonl 2>/dev/null | wc -l)"

say "재분석 (집계/admissibility/T1/T2/Router)"
( cd "$WM" && python overnight_mdp.py ) > "$OUT/rerun_analysis.txt" 2>&1
say "재측정 STEP 3 (MC 라벨 위)"
( cd "$WM" && python step3_loao.py "artifacts_mdp/mc_dataset.jsonl" ) > "$OUT/step3_on_mc_labels.txt" 2>&1

say "최종 리포트 갱신"
{
  echo "# 야간 MDP 파이프라인 결과 (갱신 $(date '+%Y-%m-%d %H:%M'))"
  echo
  echo "## !! 1차 실행의 결함과 보완"
  echo "1차 생성은 DS_KINDS 에 무해 변형(faultidle/zoneharm)을 빼서 **개입이 항상 옳은** 데이터가 되었다."
  echo "admissible 18개의 정답이 전부 Replace -> surrogate 가 '항상 Replace'로 regret 0 -> Router 평가 불가."
  echo "무해 변형을 추가 생성해 재분석한 결과가 아래다. 1차 결과는 artifacts_mdp/overnight.log 에 보존."
  echo
  echo "## STEP 2~5 (재분석)"; echo '```'; cat "$OUT/rerun_analysis.txt" 2>/dev/null; echo '```'
  echo; echo "## STEP 3 (MC 라벨 위)"; echo '```'; tail -45 "$OUT/step3_on_mc_labels.txt" 2>/dev/null; echo '```'
  echo; echo "## STEP 6 옵션-제한 gap"; echo '```'; cat "$OUT/step6_gap.txt" 2>/dev/null; echo '```'
  echo; echo "## 알려진 한계"
  echo "- 1차 생성에서 6병렬 × 1GB 스택이 OutOfMemoryError 로 샤드 3개(seed 3,4,9,10,11,12 일부)를 죽였다."
  echo "  살아남은 데이터만 사용했으므로 instance 수가 계획(60)보다 적다."
  echo "- T2(이력 추가 regret)는 instance 당 사건이 1개라 원리적으로 수행 불가 -> BLOCKED."
  echo "- STEP 6 gap 은 원시 배정공간이 아니라 옵션의 연속 파라미터만 연 것이라 **하한**이다."
} > "$OUT/OVERNIGHT_REPORT.md"
say "=== 보완 파이프라인 완료: $OUT/OVERNIGHT_REPORT.md ==="
