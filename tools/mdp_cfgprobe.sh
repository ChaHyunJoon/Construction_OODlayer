#!/usr/bin/env bash
# =============================================================================
# mdp_cfgprobe.sh — 에피소드 발화구간 설정을 **대량 생성 전에** 실측으로 고른다.
#
# 왜 필요한가 (실측으로 드러난 구조적 제약):
#   · 이 빌드는 첫 배치에서 closed 0 -> 58 로 뛴다. [8,60] 구간은 세 사건이 전부
#     같은 스텝에 몰려 터져 tau_to_next 가 전부 0 이었다(에피소드가 사실은 동시사건).
#   · 그렇다고 [70,230] 으로 늦추면 **fault 가 한 번도 안 터진다**(실측 0건).
#     single_solo_fault_target 은 "남은 solo 운반작업이 정확히 1개인 로봇"을 찾는데,
#     빌드 후반에는 그런 로봇이 없다. 게다가 늦을수록 결정이 무의미해져 동점률이
#     closed<120 67% -> closed>=120 95% 로 치솟는다.
#   두 제약이 반대 방향이므로 구간을 **추측하지 말고 재서** 정해야 한다.
#
# 각 lane 이 1 seed 씩 서로 다른 구간으로 돌고, 끝나면 fault 발화/tau/동점률을 비교한다.
# =============================================================================
cd "$(dirname "$0")/.." || exit 1
WM="$PWD"; OUT="$WM/results/artifacts_mdp"; LOG="$OUT/cfgprobe.log"
mkdir -p "$OUT"; export PYTHONIOENCODING=utf-8
say () { echo "[$(date '+%H:%M:%S')] [probe] $*" | tee -a "$LOG"; }

run_cfg () {   # $1=tag  $2=lo  $3=hi  $4=seed
  DS_EPISODE_N=3 DS_SEEDS="$4" DS_MC_K=1 DS_VALID_ONLY=1 DS_HOTSWAP=1 \
  DS_EP_LO=$2 DS_EP_HI=$3 DS_EP_KINDS="fault,fault,battery,battery,zoneblk" \
  DS_NOPROG=6000 DS_STACK=1000000000 \
  DS_OUT="$WM/data/oracle/probe_${1}.jsonl" \
  julia +lts --project=. "$WM/tools/oracle/gen_oracle_dataset.jl" > "$OUT/cfgprobe_${1}.log" 2>&1
  echo "$(date '+%H:%M:%S') $1 lo=$2 hi=$3 seed=$4 rc=$?" >> "$LOG"
}

say "구간 후보 2개 × 2 seed = 4 판, 2병렬"
rm -f "$WM"/data/oracle/probe_*.jsonl
( run_cfg a55 55 130 201 ; run_cfg a55b 55 130 202 ) &
( run_cfg b59 59 110 201 ; run_cfg b59b 59 110 202 ) &
wait
say "비교 분석"
# 상대경로로 부른다. msys 스타일 절대경로(/c/...)는 Windows python 이 못 연다.
( cd "$WM" && python tools/probe_report.py ) > "$OUT/cfgprobe_report.txt" 2>&1
say "=== 완료: artifacts_mdp/cfgprobe_report.txt ==="
