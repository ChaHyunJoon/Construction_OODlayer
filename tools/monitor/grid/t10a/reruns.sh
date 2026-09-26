#!/usr/bin/env bash
# reruns.sh <logdir> <t8_off_dir> — T9 fake-LM 두 판 + T8 E1 을 현재 코드에서 한 번씩(동시, tmux). 실행 중 코드 편집 금지(신원 지문).
S=$1; OFF=$2; cd "$(dirname "$0")/../../../.."; mkdir -p $S
tmux new-session -d -s zrv-t10a-t9gen "julia +lts --project=. test/repair_service_episode.jl $S/t9-ep-general $OFF general > $S/t9-ep-general.log 2>&1; echo EXIT=\$? >> $S/t9-ep-general.log"
tmux new-session -d -s zrv-t10a-t9geo "julia +lts --project=. test/repair_service_episode.jl $S/t9-ep-geometry $OFF geometry > $S/t9-ep-geometry.log 2>&1; echo EXIT=\$? >> $S/t9-ep-geometry.log"
tmux new-session -d -s zrv-t10a-t8e1 "T8_EPISODES=E1 julia +lts --project=. test/repair_runtime_wiring.jl episodes $S/t8E1 $OFF > $S/t8E1.log 2>&1; echo EXIT=\$? >> $S/t8E1.log"
