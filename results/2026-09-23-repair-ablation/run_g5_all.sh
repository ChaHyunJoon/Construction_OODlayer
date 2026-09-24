#!/usr/bin/env bash
# G5 A2 전용 드라이버(2026-09-23 23:4x 사용자 결정으로 보류 해제): 팔 all 만, 두 모델 동시 W=8. run_g5.sh 의 한 팔 사본.
# detached tmux 세션 abl-g5-driver 에서 돈다(SSH 끊김·조종 세션 죽음에 살아남도록 루프·wait 가 여기 있다).
# 팔 사이에서 멈추는 조건: cost_watchdog 의 STOP 파일, 또는 init 거절·지문 표류(파일럿과 합칠 수 없다).
set -u
ROOT=/home/chahj578/Construction_OODlayer
R=$ROOT/results/2026-09-23-repair-ablation
cd "$ROOT" || exit 2
echo "=== G5 A2-only driver start $(date +%F' '%T) HEAD $(git rev-parse --short HEAD) ==="
for pair in all:8113; do
  lvl=${pair%%:*}; port=${pair##*:}
  [ -e "$R/STOP" ] && { echo "STOP file present — not starting arm $lvl"; exit 4; }
  echo "--- arm $lvl start $(date +%T)"
  for m in tractor xwing; do
    model=$([ $m = tractor ] && echo tractor.mpd || echo "30051-1 - X-wing Fighter - Mini.mpd")
    (
      export GRID_OUT=$R/$lvl-$m DEMO_MODEL="$model" CAMPAIGN_ID=abl-$lvl-$m-20260923 \
             DSPY_URL=http://127.0.0.1:$port REPAIR_ABLATION=$lvl
      bash tools/monitor/grid/render_grid.sh "router" "zone all3" "$(seq -s ' ' 1 30)" 8
      echo "EXIT=$?"
    ) > "$R/full_${lvl}_$m.out" 2>&1 &
  done
  wait        # 팔 하나가 끝나야 다음 팔
  echo "--- arm $lvl done $(date +%T): $(tail -qn1 "$R/full_${lvl}_tractor.out" "$R/full_${lvl}_xwing.out" | tr '\n' ' ')"
  if /usr/bin/grep -lE 'init refused|fingerprint differs|\[DRIFT\]' "$R/full_${lvl}_"*.out; then
    echo "init refused / drift in arm $lvl — stopping"; exit 3
  fi
done
echo "=== G5 driver done $(date +%F' '%T) ==="
