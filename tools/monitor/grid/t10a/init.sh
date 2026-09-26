#!/usr/bin/env bash
# init.sh <b0_root> <manifest> — T10a 격자 초기화: B0 120(tractor·xwing) · 순차 동등성 기준 2(seq/) ·
# 무하네스 대조(control_off/, plain render_demo off) · REPAIR_ABLATION=none 분해(decomp_none/, 60+60 계획; 실제로는 easy_lost 만 돈다).
set -eu
R=$1; M=$2; H="$(cd "$(dirname "$0")" && pwd)"; source "$H/b0env.sh"; cd "$H/../../../.."
CP=tools/monitor/grid/campaign.py
OFF=(); NONE=()
for x in "${B0ENV[@]}"; do case $x in ZONE_REPAIR_VERIFICATION=*) ;; *) OFF+=("$x");; esac; done
for x in "${OFF[@]}"; do case $x in REPAIR_ABLATION=*) NONE+=(REPAIR_ABLATION=none);; *) NONE+=("$x");; esac; done
model() { [ $1 = xwing ] && echo "30051-1 - X-wing Fighter - Mini.mpd" || echo tractor.mpd; }
for m in tractor xwing; do
  env -i "${B0ENV[@]}" python3 $CP init $R/$m --model "$(model $m)" --lanes canonical --cases "zone all3" --seeds "$(seq -s ' ' 1 30)" --runner b0 --manifest $M --campaign-id zrv-t10a-b0-$m
  env -i "${B0ENV[@]}" python3 $CP init $R/seq/$m --model "$(model $m)" --lanes canonical --cases zone --seeds 27 --runner b0 --manifest $M --campaign-id zrv-t10a-b0seq-$m
  env -i "${OFF[@]}" python3 $CP init $R/control_off/$m --model "$(model $m)" --lanes canonical --cases "zone all3" --seeds "11 27" --campaign-id zrv-t10a-control-off-$m
  env -i "${NONE[@]}" python3 $CP init $R/decomp_none/$m --model "$(model $m)" --lanes canonical --cases "zone all3" --seeds "$(seq -s ' ' 1 30)" --campaign-id zrv-t10a-decomp-none-$m
  python3 $CP snapshot $R/$m
done
