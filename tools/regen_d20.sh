#!/usr/bin/env bash
# tools/regen_d20.sh -- D=20 기하로 오라클 격자 / 평가 행렬 / UI 녹화본을 재생성한다.
#
# 왜 저장소 안에 두는가: 이전 세대의 드라이버는 .superpowers/sdd/ 아래(=git-ignored)에 있어
# 재현이 불가능했다. 재현 명령은 결과 문서가 가리킬 수 있는 곳에 있어야 한다.
#
# 사용법:
#   bash tools/regen_d20.sh oracle              # 오라클 격자 (~15분)
#   bash tools/regen_d20.sh matrix <seed>       # 평가 런 7케이스 x 3정책 x 시드 1개 (~95분)
#   bash tools/regen_d20.sh ui                  # 대시보드 녹화본 8종 (~25분)
#
# 전부 순차 실행이다. 동시에 두 개를 돌리면 HiGHS 가 다른 스케줄을 내 비교가 무효가 된다.
set -u
cd "$(dirname "$0")/.." || exit 2
MODE="${1:?usage: regen_d20.sh oracle|matrix <seed>|ui}"
DSPY="${DSPY_URL:-http://127.0.0.1:8077}"

case "$MODE" in
  oracle)
    cd wm4spacecraft_manufacturing/oracle || exit 2
    OUT="${2:-out/n44_plus78_d20.jsonl}"
    echo "=== oracle grid start $(date +%H:%M:%S) -> $OUT ==="
    DS_KINDS=battery,fault,zone DS_SEEDS=1 DS_SPARES=3 DS_VALID_ONLY=1 DS_RESUME=1 \
    DS_OUT="$OUT" julia +lts --project=../.. gen_oracle_dataset.jl
    echo "=== oracle grid done rc=$? $(date +%H:%M:%S) rows=$(wc -l < "$OUT" 2>/dev/null || echo 0) ==="
    ;;
  matrix)
    SEED="${2:?usage: regen_d20.sh matrix <seed>}"
    OUT="${3:-results/matrix_d20.jsonl}"
    cd wm4spacecraft_manufacturing || exit 2
    if ! curl -s --max-time 5 "$DSPY/health" > /dev/null; then
      echo "ABORT  DSPy service down at $DSPY -- surrogate/dspy would silently fall back to canonical"
      echo "       while the summary row still says policy=dspy. Refusing to generate a corrupt column."
      exit 3
    fi
    for CASE in battery fault zone fault_battery fault_zone battery_zone all; do
      start=$SECONDS
      echo "=== seed=$SEED case=$CASE $(date +%H:%M:%S) ==="
      python llm_ood_eval.py run --case "$CASE" --seeds "$SEED" \
          --policies canonical,surrogate,dspy --dspy-url "$DSPY" --out "$OUT"
      echo "--- seed=$SEED case=$CASE rc=$? in $((SECONDS-start))s ; rows now: $(wc -l < "$OUT" 2>/dev/null || echo 0)"
    done
    echo "ALL DONE seed=$SEED $(date +%H:%M:%S)"
    ;;
  ui)
    # 대시보드 케이스 키 8종 전부(dashboard.html:797-806). 기본 3종만 도는 스크립트에
    # 인자로 넘겨서 전부 렌더한다.
    DSPY_URL="$DSPY" bash tools/monitor/regen_router_cases.sh \
        none battery fault zone fault_battery fault_zone battery_zone battery_mild
    ;;
  *) echo "unknown mode: $MODE"; exit 2 ;;
esac
