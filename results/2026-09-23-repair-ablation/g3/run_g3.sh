#!/usr/bin/env bash
# G3 실현 가능성 오라클(A2 어휘). 무료, 서비스 없음. 격자와 같은 세계(고정 env·사건)로 돈다.
# DEMO_SYNTH_FIXTURE_KINDS=zone: 픽스처를 zone 결정에만 꽂는다(policy.jl `SYNTH_FIXTURE_KINDS`). 없으면 all3 의
#   battery·fault 결정에도 존 오라클이 집행돼 handled=true 로 SwapBattery/Replace 를 건너뛴다(첫 스윕 실측: tractor all3 0/28).
# PIN = `campaign.py init`(REPAIR_ABLATION=all, 2026-09-23 HEAD 654ec60b) 의 set_env 에서 REPAIR_ABLATION 을 뺀 것(아래에서 명시).
set -u
ROOT=/home/chahj578/Construction_OODlayer; OUT=$(cd "$(dirname "$0")" && pwd); mkdir -p "$OUT/log"
PIN="CARRIER_RESCUE=1 DEMO_ANIM=0 ENERGY_OBJECTIVE=1 RESPEC_DEPRIO_KAPPA=0.25 RESPEC_TRANSLATE_ON_INFEASIBLE=0 RESTAGE_NAV_BUFFER=0 RESTAGE_RING_STEP_FRAC=0.34 RESTAGE_ZONE_MARGIN_FRAC=0.5 SPARE_PRIORITY=1 TEAM_PRIORITY=1 ZONE_CAUSAL_RULE=0 ZONE_CHECK_PATHS=0 ZONE_DOMAIN_GATE=0 ZONE_RESCUE=1"
while read -r tag case seed; do
  case $tag in tractor) model="tractor.mpd" ;; xwing) model="30051-1 - X-wing Fighter - Mini.mpd" ;; *) echo "bad tag $tag"; exit 2 ;; esac
  case $case in zone) ood=none ;; all3) ood=fault_battery ;; *) echo "bad case $case"; exit 2 ;; esac
  log="$OUT/log/${tag}__${case}__s${seed}.log"
  timeout 3600 env $PIN DEMO_MODEL="$model" DEMO_OOD=$ood DEMO_ZONE=1 DEMO_ZONE_SEED="$seed" DEMO_SEED="$seed" \
    DEMO_ROUTER=0 DEMO_POLICY=canonical DEMO_OUT_DIR="$OUT" DEMO_CASE_TAG="g3_${tag}_${case}_s${seed}" \
    DEMO_SYNTH_FIXTURE="$ROOT/tools/fixtures/oracle_zone_clear_nobase.json" DEMO_SYNTH_FIXTURE_KINDS=zone REPAIR_ABLATION=all \
    MONITOR_RUN_ID="g3_${tag}_${case}_s${seed}" julia +lts --project="$ROOT" "$ROOT/tools/monitor/render_demo.jl" </dev/null \
    > "$log" 2>&1
  echo "$tag $case s$seed rc=$? $(/usr/bin/grep -ho '^\[score\].*' "$log" | tail -1) | $(/usr/bin/grep -ho '^\[ablation\].*' "$log" | tail -1 | cut -c1-80)" | tee -a "$OUT/drive.log"
done
