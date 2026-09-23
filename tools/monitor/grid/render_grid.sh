#!/usr/bin/env bash
# render_grid.sh "<lanes>" "<cases>" "<seeds>" <W>
# 렌더 엔진 격자. GRID_OUT·DEMO_MODEL 필수. surrogate/router 레인은 DSPY_URL 필수(없으면
# policy.jl 기본 8077 — 낡은 서비스일 수 있다). CAMPAIGN_ID 를 주면 그 이름을 쓴다.
# 🔴 2026-09-23 (Task 7): campaign.py init 이 campaign.json(지문·set_env)과 jobs.jsonl(계획 판
#    전부)을 쓴다. 이미 있으면 지문이 같을 때만 계획을 합친다(파일럿 → 전체). 끝에 summarize 가
#    계획 판별 상태를 내고, 채점 안 된 판이 하나라도 있으면 **nonzero 로 끝난다**.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${GRID_OUT:?GRID_OUT unset}; mkdir -p "$OUT"/log
LANES=$1; CASES=$2; SEEDS=$3; W=$4
case " $LANES " in *" surrogate "*|*" router "*)
  [ -n "${DSPY_URL:-}" ] || { echo "DSPY_URL unset for a service lane" >&2; exit 2; } ;;
esac
python3 "$HERE/campaign.py" init "$OUT" --model "${DEMO_MODEL:?DEMO_MODEL unset}" \
  --lanes "$LANES" --cases "$CASES" --seeds "$SEEDS" ${CAMPAIGN_ID:+--campaign-id "$CAMPAIGN_ID"} \
  || exit $?
JOBS="$OUT/jobs.$$.txt"
python3 - "$OUT/jobs.jsonl" "$LANES" "$CASES" "$SEEDS" > "$JOBS" <<'PY'
import json, sys
p, lanes, cases, seeds = sys.argv[1], sys.argv[2].split(), sys.argv[3].split(), sys.argv[4].split()
for j in map(json.loads, filter(str.strip, open(p))):
    if j["lane"] in lanes and j["case"] in cases and str(j["seed"]) in seeds:
        print(j["lane"], j["case"], j["seed"])
PY
n=$(wc -l < "$JOBS")
echo "=== render grid: $n runs, W=$W, DSPY_URL=${DSPY_URL:-unset}, start $(date +%F' '%T) ==="
xargs -P "$W" -L 1 "$HERE/render_one.sh" < "$JOBS"; xrc=$?
rm -f "$JOBS"
echo "=== done $(date +%F' '%T) xargs_rc=$xrc ==="
python3 "$HERE/campaign.py" summarize "$OUT"; src=$?
[ $xrc -eq 0 ] && [ $src -eq 0 ]
