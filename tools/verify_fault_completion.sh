#!/usr/bin/env bash
# B5 verification harness: does the mid-build fault->Replace now COMPLETE, structurally, across
# several seeds/runs? (RVO is non-deterministic, so one success is not proof.)
#
# For each (seed, repeat) it runs the fault demo fast (no anim) with the carrier-rescue completion
# fixes ON, then greps the outcome. PASS requires PROJECT COMPLETE + BoundsError=0 every run.
#
# Usage: bash tools/verify_fault_completion.sh "1 2 3" 2        # seeds, repeats-per-seed
set -u
SEEDS="${1:-1 2 3}"
REPEATS="${2:-2}"
OUTDIR="${OUTDIR:-/c/Users/chahj/AppData/Local/Temp/claude/c--Users-chahj-PythonCodes-venv/f79e6d12-0856-4576-a15f-281ca3047dc3/scratchpad/b5}"
mkdir -p "$OUTDIR"
pass=0; total=0
echo "seed repeat  outcome         closed  bounderr  carrier_closed"
for s in $SEEDS; do
  for r in $(seq 1 "$REPEATS"); do
    total=$((total+1))
    log="$OUTDIR/fault_s${s}_r${r}.log"
    SEED="$s" HOT_SWAP="${HOT_SWAP:-1}" FAULT_TARGET="${FAULT_TARGET:-ftu}" CARRIER_RESCUE=1 \
      NOPROG="${NOPROG:-8000}" SAVE_ANIM=0 OPEN_ANIM=0 \
      julia +lts --project=. tools/demo_respec_replace_anim.jl > "$log" 2>&1
    complete=$(grep -c "PROJECT COMPLETE" "$log")
    bounderr=$(grep -c "BoundsError" "$log")
    closed=$(grep -aoE "n_closed: [0-9]+" "$log" | grep -oE "[0-9]+" | sort -n | tail -1)
    hotswap=$(grep -c "ADMITTED hot-swap" "$log")
    fired=$(grep -c "HOTSWAP\|ADMITTED hot-swap\|fault_robot\|OOD event.*fault\|ReplaceAgent" "$log")
    outcome="INCOMPLETE"; [ "$complete" -gt 0 ] && outcome="COMPLETE"
    [ "$complete" -gt 0 ] && [ "$bounderr" -eq 0 ] && [ "$hotswap" -gt 0 ] && pass=$((pass+1))
    printf "%4s %6s  %-14s  %6s  %8s  hotswap=%s fired=%s\n" "$s" "$r" "$outcome" "${closed:-?}" "$bounderr" "$hotswap" "$fired"
  done
done
echo "----"
echo "PASS $pass / $total  (need all COMPLETE with BoundsError=0 for a structural fix)"
