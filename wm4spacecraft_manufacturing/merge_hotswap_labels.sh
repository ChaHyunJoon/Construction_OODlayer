#!/usr/bin/env bash
# B6 merge + retrain: combine the HOT-SWAP-world labels (fault + deep battery, where Replace now
# COMPLETES) with the still-valid existing labels (mild battery -> NOOP, zone -> ForbidZone/NOOP; these
# do not Replace-complete so hot-swap does not change them), then export + audit the surrogate.
set -eu
cd "$(dirname "$0")"
HS=oracle/out/graded_hs           # new hot-swap tags: fault_sp3/sp0/faultidle, battery0.05/0.12
OLD=oracle/out/graded             # existing tags to reuse: mild battery + zone
OUT=oracle/out/graded_v2.jsonl

: > "$OUT"
echo "== hot-swap (fault + deep battery) =="
cat "$HS"/*.jsonl >> "$OUT" 2>/dev/null && ls "$HS"/*.jsonl
echo "== reuse (mild battery + zone, unaffected by hot-swap) =="
for pat in "battery0.2_" "battery0.35_" "battery0.6_" "zoneblk" "zoneharm_"; do
  for f in "$OLD"/${pat}*.jsonl; do [ -s "$f" ] && cat "$f" >> "$OUT" && echo "  + $(basename "$f")"; done
done
echo "== merged rows: $(wc -l < "$OUT") =="

echo "== export cost-aware surrogate =="
python export_surrogate.py "$OUT" --cost-aware -o surrogate_hotswap.json
echo "== audit =="
python e1_analyze.py "$OUT" --cost-aware
