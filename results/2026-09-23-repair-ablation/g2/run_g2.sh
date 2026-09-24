#!/usr/bin/env bash
# G2 음성 대조: translate 를 부르는 기존 오라클 픽스처가 ablation 팔에서 막히는가(무료, 서비스 없음).
set -u
ROOT=/home/chahj578/Construction_OODlayer; OUT=$(cd "$(dirname "$0")" && pwd); mkdir -p "$OUT/log"
# campaign 의 고정 env(9/23 sol campaign.json set_env 에서 DSPY_URL 만 뺀 것) — 격자와 같은 세계여야 한다
PIN="CARRIER_RESCUE=1 DEMO_ANIM=0 ENERGY_OBJECTIVE=1 RESPEC_DEPRIO_KAPPA=0.25 RESPEC_TRANSLATE_ON_INFEASIBLE=0 RESTAGE_NAV_BUFFER=0 RESTAGE_RING_STEP_FRAC=0.34 RESTAGE_ZONE_MARGIN_FRAC=0.5 SPARE_PRIORITY=1 TEAM_PRIORITY=1 ZONE_CAUSAL_RULE=0 ZONE_CHECK_PATHS=0 ZONE_DOMAIN_GATE=0 ZONE_RESCUE=1"
for lvl in none translate all; do
  timeout 3600 env $PIN DEMO_MODEL=tractor.mpd DEMO_OOD=none DEMO_ZONE=1 DEMO_ZONE_SEED=1 DEMO_SEED=1 \
    DEMO_ROUTER=0 DEMO_POLICY=canonical DEMO_OUT_DIR="$OUT" DEMO_CASE_TAG="g2_$lvl" \
    DEMO_SYNTH_FIXTURE="$ROOT/tools/fixtures/oracle_zone_clear.json" REPAIR_ABLATION=$lvl \
    MONITOR_RUN_ID="g2_$lvl" julia +lts --project="$ROOT" "$ROOT/tools/monitor/render_demo.jl" </dev/null \
    > "$OUT/log/$lvl.log" 2>&1
  echo "$lvl rc=$? $(/usr/bin/grep -ho '^\[score\].*' "$OUT/log/$lvl.log" | tail -1)"
  /usr/bin/grep -hoE 'reject:ablated_primitive:[^ ]+|AblatedPrimitiveError[^\n]{0,80}|^\[ablation\].*' "$OUT/log/$lvl.log" | head -5
done
