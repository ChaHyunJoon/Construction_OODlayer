#!/usr/bin/env bash
# zrv_replay_matrix.sh <outroot> — T3 재생 게이트 행렬(순차). 에피소드는 코호트
# (test/fixtures/repair_verification/cohort.json)에서 model × case × 역사적 class × 존 대상(robot/TU)
# 칸마다 canonical 경과시간이 가장 짧은 판을 골랐다. 한 줄 = "model case seed # class target".
set -u
root=$1; mkdir -p "$root"
ROOT=/home/chahj578/Construction_OODlayer
while read -r model case seed _ class target; do
  [ -z "$model" ] && continue
  echo "=== $model $case s$seed ($class, $target) $(date +%T)"
  "$ROOT/tools/monitor/zrv_replay_episode.sh" "$model" "$case" "$seed" "$root"
  ( cd "$ROOT" && julia +lts --project=. tools/monitor/zrv_replay_compare.jl "$root/${model}__${case}__s${seed}" \
      > "$root/${model}__${case}__s${seed}/compare.stdout" 2>&1 )
  grep -A4 '"verdict"' "$root/${model}__${case}__s${seed}/compare.json" | tr -d '\n '; echo
done <<'EOF'
tractor all3 5 # hard transport
tractor zone 10 # hard transport
tractor all3 26 # easy robot
tractor zone 26 # easy robot
tractor all3 4 # hard robot
tractor zone 27 # hard robot
tractor all3 29 # easy transport
tractor zone 9 # easy transport
xwing all3 4 # hard transport
xwing zone 27 # easy robot
EOF
echo "=== matrix done $(date +%T)"
