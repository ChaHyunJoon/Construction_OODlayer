#!/usr/bin/env bash
# B6 (scoped): regenerate ONLY the oracle tags whose labels change once ReplaceAgent is enacted as an
# identity-preserving HOT-SWAP (no schedule re-stamp) instead of the distributed re-stamp that left
# Replace INCOMPLETE. Those are the tags where a macro actually REPLACES a robot and now COMPLETES:
#   - fault_sp3 / fault_sp0 / faultidle  (fault -> Replace)
#   - battery0.05 / battery0.12          (deep battery -> Replace)
# The mild-battery (0.2/0.35/0.6 -> NOOP) and zone (-> ForbidZone/NOOP) tags do NOT Replace-complete,
# so their existing reform=120 labels are unaffected and are reused from oracle/out/graded/.
#
# Speed: with hot-swap the Replace arm COMPLETES (makes continuous progress) so DS_NOPROG never truncates
# it; only the wedging NOOP/other arms hit the cap, so a low DS_NOPROG is safe and fast here.
#
# Usage:  DS_HOTSWAP=1 bash oracle/run_hotswap_relabel.sh <seed> <outdir>
set -u
SEED="${1:?seed}"
OUT="${2:-oracle/out/graded_hs}"
mkdir -p "$OUT"
export DS_HOTSWAP="${DS_HOTSWAP:-1}"
export CARRIER_RESCUE="${CARRIER_RESCUE:-1}"
export DS_REFORM="${DS_REFORM:-120}"
export DS_NOPROG="${DS_NOPROG:-5000}"     # completing arms finish on progress; only wedged arms are capped
export DS_NOCTRL="${DS_NOCTRL:-1}"
export DS_SEEDS="$SEED"

run () {
  local tag="$1"; shift
  local f="$OUT/${tag}_s${SEED}.jsonl"
  if [ -s "$f" ]; then echo "[skip] $tag s$SEED ($(wc -l < "$f") rows)"; return; fi
  echo "[run ] $tag s$SEED ($*)"
  env "$@" DS_OUT="$f" julia +lts --project=.. oracle/gen_oracle_dataset.jl \
      > "$OUT/${tag}_s${SEED}.log" 2>&1
  echo "[done] $tag s$SEED -> $(wc -l < "$f" 2>/dev/null || echo 0) rows"
}

run fault_sp3   DS_KINDS=fault    DS_SPARES=3
run fault_sp0   DS_KINDS=fault    DS_SPARES=0
run faultidle   DS_KINDS=faultidle DS_SPARES=3
run battery0.05 DS_KINDS=battery  DS_BSOC=0.05 DS_SPARES=3
run battery0.12 DS_KINDS=battery  DS_BSOC=0.12 DS_SPARES=3
echo "=== seed $SEED hot-swap relabel complete: $(cat "$OUT"/*_s${SEED}.jsonl 2>/dev/null | wc -l) rows"
