#!/usr/bin/env bash
# Graded-OOD dataset driver (GRADED_OOD_DESIGN.md §7 step 4).
#
# ONE JULIA PROCESS PER INSTANCE. gen_oracle_dataset.jl leaks memory across instances (env + geometry
# + HiGHS are not reclaimed), and a single process running the whole sweep dies with OutOfMemoryError
# after ~3 instances. Per-instance processes pay a ~3 min startup each but keep memory bounded.
#
# Usage:  bash oracle/run_graded.sh <seed> <outdir>
# Then:   cat <outdir>/*.jsonl > oracle/out/graded.jsonl
set -u
SEED="${1:?seed}"
OUT="${2:-oracle/out/graded}"
mkdir -p "$OUT"

# NOPROG must be large enough that a CORRECT arm can actually FINISH before the cap: at 3000 a Replace
# that would complete gets cut off at ~240/313 and is mislabelled INCOMPLETE. 30000 matches the demo
# that completes. (Cost is only paid by arms that genuinely wedge; correct arms finish long before it.)
export DS_NOPROG="${DS_NOPROG:-30000}"
export DS_NOCTRL="${DS_NOCTRL:-1}"      # cost-aware labelling needs no admissibility control run
export DS_REFORM="${DS_REFORM:-120}"    # fast background recovery — the value the completing demo uses
export CARRIER_RESCUE="${CARRIER_RESCUE:-1}"   # safety net for a stuck formed carrier (see replace_robot.jl)
export DS_SEEDS="$SEED"

run () {           # run <tag> <KEY=VAL>...
  local tag="$1"; shift
  local f="$OUT/${tag}_s${SEED}.jsonl"
  if [ -s "$f" ]; then echo "[skip] $tag s$SEED (already have $(wc -l < "$f") rows)"; return; fi
  echo "[run ] $tag s$SEED  ($*)"
  env "$@" DS_OUT="$f" julia +lts --project=.. oracle/gen_oracle_dataset.jl \
      > "$OUT/${tag}_s${SEED}.log" 2>&1
  echo "[done] $tag s$SEED -> $(wc -l < "$f" 2>/dev/null || echo 0) rows"
}

# --- battery: the severity LADDER (deep -> Replace ... mild -> NOOP). The crown jewel: same kind,
#     flipping answer, flip point depends on how much work the robot still owns.
#     BSOC_GRID is deliberately DENSE around the measured flip (0.12 -> Replace, 0.20 -> NOOP): points
#     far from the threshold are already predicted correctly and teach the model nothing.
for s in ${BSOC_GRID:-0.05 0.12 0.2 0.35 0.6}; do
  run "battery${s}" DS_KINDS=battery DS_BSOC="$s" DS_SPARES=3
done
# --- fault: consequential (a full pending chain) at two provisioning levels. sp0 => no spare exists,
#     so Replace degenerates and the correct macro must move.
run fault_sp3 DS_KINDS=fault DS_SPARES=3
run fault_sp0 DS_KINDS=fault DS_SPARES=0
# --- fault: HARMLESS variant (victim owns no work) - same `kind` label, NOOP is correct.
run faultidle DS_KINDS=faultidle DS_SPARES=3
# --- zone: consequential (covers a pending staging area) vs harmless (open floor). The measured flip
#     is in zone_overlap ~0.31 (NOOP) .. 0.49 (ForbidZone), so sweep the offset knob around it.
for z in ${ZFRAC_GRID:-0.9}; do
  run "zoneblk${z}" DS_KINDS=zoneblk DS_ZFRACS="$z" DS_SPARES=3
done
run zoneharm DS_KINDS=zoneharm DS_SPARES=3
echo "=== seed $SEED complete: $(cat "$OUT"/*_s${SEED}.jsonl 2>/dev/null | wc -l) rows"
