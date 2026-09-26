#!/usr/bin/env bash
# fast_gates.sh — T1–T10b 빠른 게이트(에피소드 없음)를 순차로 돌려 명령·exit code·요약 줄을 원장에 적는다.
set -u
ROOT=/home/chahj578/Construction_OODlayer
V=$ROOT/results/2026-09-24-zone-repair-verification/validation/gates
mkdir -p $V/logs
LEDGER=$V/fast_ledger.tsv
printf "task\tcommand\texit\tsummary\tlog\tstarted\tsecs\tcommit\n" > $LEDGER
run() {  # task name cmd...
  t=$1; n=$2; shift 2
  lf=$V/logs/$n.log; st=$(date +%s); s0=$(date +%T)
  ( cd $ROOT && "$@" ) > $lf 2>&1; rc=$?
  sum=$(grep -E "^[^[:space:]].*\|[[:space:]]+[0-9]+|passed|failed|Test Summary|error" $lf | grep -vE "juliaup|lts" | tail -3 | tr '\t\n' '  ')
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$t" "$*" "$rc" "$sum" "logs/$n.log" "$s0" "$(( $(date +%s)-st ))" "$(git -C $ROOT rev-parse --short HEAD)" >> $LEDGER
  echo "[gate] $n rc=$rc $(( $(date +%s)-st ))s"
}
J="julia +lts --project=."
PY="$ROOT/.venv/bin/python -m pytest -q -p no:cacheprovider"
run T0 build_repair_cohort $PY tools/monitor/test_build_repair_cohort.py
run T1 repair_contracts $J test/repair_contracts.jl
run T1 repair_contract_schemas $PY src/respec/llm_service/test_repair_contract_schemas.py
run T2 repair_checkpoint $J test/repair_checkpoint.jl
run T3 repair_checkpoint_replay $J test/repair_checkpoint_replay.jl
run T4 repair_rollout $J test/repair_rollout.jl
run T5 repair_tool_proposal $J test/repair_tool_proposal.jl
run T5 repair_task_contract $J test/repair_task_contract.jl
run T5 repair_effect_validation $J test/repair_effect_validation.jl
run T6 repair_tool_execution $J test/repair_tool_execution.jl
run T6 repair_resync $J test/repair_resync.jl
run T7 repair_selection $J test/repair_selection.jl
run T8 repair_runtime_wiring_fast $J test/repair_runtime_wiring.jl
run T9 repair_service_slot $J test/repair_service_slot.jl
run T9 zone_repair_lane $PY src/respec/llm_service/test_zone_repair_lane.py
run T9 llm_service_suite $PY src/respec/llm_service
run ablation repair_ablation_core $J test/repair_ablation_core.jl
run ablation repair_ablation_registration $J test/repair_ablation_registration.jl
run ablation repair_ablation_wiring $J test/repair_ablation_wiring.jl
run ablation repair_ablation_dspy_ready $J test/repair_ablation_dspy_ready.jl
run ablation repair_ablation_py $PY src/respec/llm_service/test_repair_ablation.py
run T4 config_digest_inventory $J test/config_digest_inventory.jl
run T10a campaign $PY tools/monitor/grid/test_campaign.py
run T10a analyze_b0 $PY tools/monitor/grid/test_analyze_b0.py
echo "=== fast gates done"
