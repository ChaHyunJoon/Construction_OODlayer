#!/usr/bin/env bash
# edge_probe.sh <case> <seed> <out> — xwing pi0 셀을 t0 까지 돌려 간선 스냅샷(edge_probe.jl)
source "$(dirname "$0")/b0env.sh"
case=$1; seed=$2; out=$3; mkdir -p $out
C=(DEMO_OOD=none DEMO_ZONE=1); [ $case = all3 ] && C=(DEMO_OOD=fault_battery DEMO_OOD_SEED=$seed DEMO_ZONE=1)
cd "$(dirname "$0")/../../../.."
env -i "${B0ENV[@]}" ZONE_REPAIR_VERIFICATION=off "${C[@]}" DEMO_MODEL="30051-1 - X-wing Fighter - Mini.mpd" DEMO_SEED=$seed DEMO_ZONE_SEED=$seed \
  DEMO_CASE_TAG=probe_$case DEMO_OUT_DIR=$out/out ZRV_EDGE_PROBE_OUT=$out \
  julia +lts --project=. -L tools/monitor/grid/t10a/edge_probe.jl tools/monitor/render_demo.jl > $out/run.log 2>&1
echo EXIT=$? >> $out/run.log
