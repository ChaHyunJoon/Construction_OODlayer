#!/usr/bin/env bash
# Render the four MeshCat clips the evolution deck needs (make_evolution_deck.py, "VIDEO PLAN").
#
# Every demo writes to results/<project>/greedy_RVO_Dispersion_TangentBug/visualization.html, so running
# them back-to-back silently OVERWRITES the previous clip. This copies each render to its own file the
# moment it is produced, and refuses to report success for a clip whose html was not (re)written.
#
# Usage:  bash tools/render_deck_videos.sh [V1 V2 V3 V4]   (default: all four)
# Output: results/deck/V<n>_<name>.html — open each in a browser and screen-record it.
set -u
cd "$(dirname "$0")/.."
OUT=results/deck; mkdir -p "$OUT"
SRC=results/tractor/greedy_RVO_Dispersion_TangentBug/visualization.html
WANT="${*:-V1 V2 V3 V4}"

render () {                     # render <tag> <name> <script> <env...>
  local tag="$1" name="$2" script="$3"; shift 3
  case " $WANT " in *" $tag "*) ;; *) echo "[skip] $tag"; return;; esac
  rm -f "$SRC"                                            # so a failed run cannot leave a stale clip
  echo "[render] $tag  $name  ($script)"
  env "$@" SAVE_ANIM=1 OPEN_ANIM=0 julia +lts --project=. "tools/$script" > "$OUT/$tag.log" 2>&1
  if [ ! -f "$SRC" ]; then
    echo "[FAIL ] $tag produced no animation — see $OUT/$tag.log"; return 1
  fi
  cp "$SRC" "$OUT/${tag}_${name}.html"
  echo "[ok   ] $tag -> $OUT/${tag}_${name}.html  ($(du -h "$OUT/${tag}_${name}.html" | cut -f1))"
  grep -aoE "PROJECT (COMPLETE|INCOMPLETE)" "$OUT/$tag.log" | head -1
}

# V4 first: it is the headline clip, so it should not be the one that runs out of time.
# ANIM_FPS=60 matches the V1/V2 deck clips (868kf→~15s, 1716kf→~29s); V4 (1669kf) → ~28s.
# SURROGATE=surrogate_hotswap.json is the honest completing-world forest (lambda=15: SoC ladder intact,
# fault→Replace, zone→ForbidZone). Override either with V4_SEED / SURROGATE env.
render V4 surrogate_stream demo_surrogate_stream_anim.jl \
       HOT_SWAP=1 CARRIER_RESCUE=1 OOD_N=4 OOD_SEED="${V4_SEED:-3}" NOPROG=20000 \
       ANIM_FPS="${ANIM_FPS:-60}" \
       SURROGATE="${SURROGATE:-C:/Users/chahj/PythonCodes/venv/wm4spacecraft_manufacturing/surrogate_hotswap.json}"
render V1 baseline_build  demo_wholebuild_anim.jl
render V2 llm_replace     demo_respec_replace_anim.jl   CARRIER_RESCUE=1
render V3 rl_replace      demo_rl_replace_anim.jl       CARRIER_RESCUE=1
echo "=== clips in $OUT:"; ls -la "$OUT"/*.html 2>/dev/null | awk '{print "   ",$9,$5"B"}'
