#!/usr/bin/env bash
# zrv_replay_episode.sh <model:tractor|xwing> <case:zone|all3> <seed> <outroot> [runs]
# T3 재생 게이트 한 에피소드: 같은 디렉터리·빌드·solver 설정에서 **순차로**
#   orig-a  원본 NOOP(pi0) 끝까지 (trace)
#   orig-b  같은 원본을 한 번 더 (레포 자체 run-to-run 잡음 바닥)
#   capture 같은 원본 + t0 에서 checkpoint export (export 가 세계를 안 바꾸는지도 잰다)
#   resume  **새 julia 프로세스**가 capture 의 t0 checkpoint 를 import → NOOP 끝까지
# runs 기본값 "orig-a orig-b capture resume". 비교는 `zrv_replay_compare.jl`.
set -u
model=$1; case=$2; seed=$3; root=$4; runs=${5:-"orig-a orig-b capture resume"}
ROOT=/home/chahj578/Construction_OODlayer
case "$model" in
  tractor) M="tractor.mpd" ;;
  xwing)   M="30051-1 - X-wing Fighter - Mini.mpd" ;;
  *) echo "bad model $model" >&2; exit 2 ;;
esac
case "$case" in
  zone) C=(DEMO_OOD=none DEMO_ZONE=1) ;;
  all3) C=(DEMO_OOD=fault_battery DEMO_OOD_SEED=$seed DEMO_ZONE=1) ;;
  *) echo "bad case $case" >&2; exit 2 ;;
esac
ep="$root/${model}__${case}__s${seed}"
mkdir -p "$ep"
# pi0 = 존 NOOP(canonical 레인은 존에 NOOP 을 고른다) + 존 복구 base/사다리 차단(REPAIR_ABLATION=all)
#       + 공통 fault/battery(canonical). 나머지는 9/23 캠페인 set_env 그대로(DSPY_URL 제외 — 서비스 없음).
PI0=(DEMO_ROUTER=0 DEMO_POLICY=canonical REPAIR_ABLATION=all
     CARRIER_RESCUE=1 DEMO_ANIM=0 ENERGY_OBJECTIVE=1 RESPEC_DEPRIO_KAPPA=0.25
     RESPEC_TRANSLATE_ON_INFEASIBLE=0 RESTAGE_NAV_BUFFER=0 RESTAGE_RING_STEP_FRAC=0.34
     RESTAGE_ZONE_MARGIN_FRAC=0.5 SPARE_PRIORITY=1 TEAM_PRIORITY=1 ZONE_CAUSAL_RULE=0
     ZONE_CHECK_PATHS=0 ZONE_DOMAIN_GATE=0 ZONE_RESCUE=1)
for r in $runs; do
  d="$ep/$r"; rm -rf "$d"; mkdir -p "$d"
  case "$r" in
    orig-*) Z=(ZRV_REPLAY_MODE=trace) ;;
    capture) Z=(ZRV_REPLAY_MODE=capture) ;;
    resume) Z=(ZRV_REPLAY_MODE=resume ZRV_CHECKPOINT="$ep/capture/t0.envelope.json") ;;
  esac
  st=$(date +%s)
  ( cd "$ROOT" && env -i HOME="$HOME" PATH="$PATH" USER="${USER:-}" LANG="${LANG:-C.UTF-8}" \
      "${PI0[@]}" "${C[@]}" DEMO_MODEL="$M" DEMO_SEED="$seed" DEMO_ZONE_SEED="$seed" \
      DEMO_CASE_TAG="pi0_${case}" DEMO_OUT_DIR="$d/out" ZRV_REPLAY_DIR="$d" ${ZRV_TRACE_DETAIL:+ZRV_TRACE_DETAIL=$ZRV_TRACE_DETAIL} \
      ${ZRV_DIAG_INVENTORY:+ZRV_DIAG_INVENTORY=$ZRV_DIAG_INVENTORY} \
      "${Z[@]}" \
      timeout "${RUN_TIMEOUT:-3600}" julia +lts --project="$ROOT" -L "$ROOT/src/verification/episode_replay.jl" \
      "$ROOT/tools/monitor/render_demo.jl" ) > "$d/run.log" 2>&1
  rc=$?
  echo "$model,$case,$seed,$r,rc=$rc,$(( $(date +%s) - st ))s" | tee -a "$root/wall.csv"
done
