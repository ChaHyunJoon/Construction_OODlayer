#!/usr/bin/env bash
# episode_gates.sh <offdir> — T3–T10b 에피소드 게이트를 최종 코드에서 다시 돈다(무료, 서비스는 가짜 LM). 명령·exit·요약을 원장에.
# 동시성: 1파(분기 순차 게이트 5개) → T5·T4 가 끝나면 2파(T9 가짜-LM 에피소드 둘, preflight 가 순간 4 병렬).
set -u
OFF=$1
ROOT=/home/chahj578/Construction_OODlayer
V=$ROOT/results/2026-09-24-zone-repair-verification/validation/gates
mkdir -p $V/logs $V/ep
LEDGER=$V/episode_ledger.tsv
[ -f $LEDGER ] || printf "task\tcommand\texit\tsummary\tlog\tstarted\tsecs\tcommit\n" > $LEDGER
run() {
  t=$1; n=$2; shift 2
  lf=$V/logs/$n.log; st=$(date +%s); s0=$(date +%T)
  ( cd $ROOT && "$@" ) > $lf 2>&1; rc=$?
  sum=$(grep -E "\|[[:space:]]+[0-9]+|Test Summary|did not pass" $lf | tail -2 | tr '\t\n' '  ')
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$t" "$*" "$rc" "$sum" "logs/$n.log" "$s0" "$(( $(date +%s)-st ))" "$(git -C $ROOT rev-parse --short HEAD)" >> $LEDGER
  echo "[epgate] $n rc=$rc $(( $(date +%s)-st ))s"
}
J="julia +lts --project=."
run T4 branch_isolation $J test/repair_branch_isolation.jl tractor zone 26 $V/ep/t4-iso isolation &
run T5 task_contract_branch $J test/repair_task_contract_branch.jl tractor zone 26 $V/ep/t5-branch &
p5=$!
run T6 tool_execution_branch $J test/repair_tool_execution_branch.jl tractor zone 26 $V/ep/t6-branch &
run T7 commit_replay $J test/repair_commit_replay.jl tractor zone 26 $V/ep/t7-commit &
run T8 runtime_wiring_episodes $J test/repair_runtime_wiring.jl episodes $V/ep/t8-ep $OFF &
wait $p5
run T9 service_episode_general $J test/repair_service_episode.jl $V/ep/t9-general $OFF general &
run T9 service_episode_geometry $J test/repair_service_episode.jl $V/ep/t9-geometry $OFF geometry &
wait
echo "=== episode gates done"
