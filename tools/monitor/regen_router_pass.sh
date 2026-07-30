#!/usr/bin/env bash
# ============================================================================================
# 라우터 주도 패스 — 8 케이스 × 1 런. 정책을 런 전체에 고정하지 않는다.
#
# regen_case_policy_matrix.sh 와 무엇이 다른가
# --------------------------------------------
#   매트릭스(DEMO_ROUTER=0) : 정책을 고정해 놓고 "각 정책을 실제로 실행하면 세계가 어떻게 갈리는가"를 본다.
#                             그래서 케이스당 3 런이 필요하다.
#   이 패스(DEMO_ROUTER=1)  : **사건마다 시스템이 producer 를 고른다**(낯설면 LLM, 익숙하면 surrogate).
#                             정책 축이 사라지므로 케이스당 1 런이면 된다. 혼합 케이스(fault_zone,
#                             battery_zone)에서는 한 런 안에서 두 사건이 서로 다른 producer 에게 간다 --
#                             이게 이 화면이 주장하려는 그림이다.
#
# 산출물 이름에 정책 접미사를 붙이지 않는다 -> streams/tractor__<case>.jsonl.
# 대시보드의 `Enacted policy = auto (legacy / router run)` 가 정확히 이 파일을 가리킨다.
#
# 사전조건
#   · DSPy 서비스 기동(:8077). 없으면 dspy 결정을 못 받아 canonical 로 폴백하고 그 사실이 verdict 에 남는다.
#   · 순차 실행(MeshCat 8700 충돌 방지).
#
# 사용법
#   bash tools/monitor/regen_router_pass.sh                 # 8 케이스
#   bash tools/monitor/regen_router_pass.sh fault zone      # 일부만
#   NOVELTY_CALIB=<path> bash ...                           # 교정 파일 교체(예: zoneblk 제외본)
# ============================================================================================
set -u
cd "$(dirname "$0")/../.."                      # ConstructionBots.jl
LOGD=tools/monitor/regen_case_logs; mkdir -p "$LOGD"
STREAMS=tools/monitor/streams
ANIM=tools/monitor/anim; mkdir -p "$ANIM"

DSPY_URL="${DSPY_URL:-http://127.0.0.1:8077}"
export DSPY_URL
export DEMO_ROUTER=1                            # ← 라우터가 사건마다 실행 정책을 고른다
export DEMO_SEED="${DEMO_SEED:-1}"              # 매트릭스와 같은 seed = 같은 교란, 다른 결정 주체

curl -s --max-time 5 "$DSPY_URL/health" >/dev/null \
  || echo "!! DSPy service not reachable at $DSPY_URL — LLM 경로가 canonical 로 폴백됩니다"

CASES=("$@")
[ ${#CASES[@]} -eq 0 ] && CASES=(none battery fault zone fault_battery fault_zone battery_zone battery_mild)

total=${#CASES[@]}
i=0
echo "=== router-driven: $total runs (seed=$DEMO_SEED) start $(date +%H:%M:%S) ==="

for case in "${CASES[@]}"; do
  i=$((i+1))
  # ⑦ battery_mild 는 battery 를 애매한 SoC(0.45)로 돌린 것. 표시 이름은 DEMO_CASE_TAG 로 유지한다.
  ood="$case"; extra=()
  if [ "$case" = "battery_mild" ]; then ood="battery"; extra=(DEMO_BSOC=0.45); fi

  echo "== [$i/$total] $case (router) ($(date +%H:%M:%S)) =="
  dst_stream="$STREAMS/tractor__${case}.jsonl"
  dst_anim="$ANIM/tractor__${case}.html"
  # 실행 전에 자리를 비운다: 렌더가 애니 발행을 거부해도 옛 파일이 남아 "이번 런의 산출물"로 오인되지 않게.
  rm -f "$dst_stream" "$dst_anim"

  env DEMO_MODEL=tractor.mpd DEMO_OOD="$ood" DEMO_CASE_TAG="$case" "${extra[@]}" \
    julia +lts --project=. tools/monitor/render_demo.jl \
    > "$LOGD/${case}__router.log" 2>&1
  rc=$?

  if [ -s "$dst_stream" ]; then
    lines=$(wc -l < "$dst_stream")
    if [ -s "$dst_anim" ]; then
      echo "   exit=$rc  -> tractor__${case}.jsonl ($lines frames) + anim"
    else
      echo "   exit=$rc  -> tractor__${case}.jsonl ($lines frames), anim 없음(미완주면 정상)"
    fi
  else
    echo "   exit=$rc  !! 스트림이 비었습니다 — $LOGD/${case}__router.log 확인"
  fi
  tr '\r' '\n' < "$LOGD/${case}__router.log" \
    | grep -aE "\[router\]|\[policy\]|\[ood\]|PROJECT (COMPLETE|INCOMPLETE)" | tail -5 | sed 's/^/   /'
done

echo "=== done $(date +%H:%M:%S) ==="
