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
_REPO="$(pwd)"                                  # 🔴 여기서 한 번 고정한다 — 아래 게이트가 쓴다.
                                                #    이 스크립트는 뒤에서 더 깊이 cd 하므로
                                                #    상대 $0 재평가는 그때 깨진다(2026-09-03 실측).
MODE="${1:?usage: regen_d20.sh oracle|matrix <seed>|ui}"
DSPY="${DSPY_URL:-http://127.0.0.1:8077}"

case "$MODE" in
  oracle)
    cd tools/oracle || exit 2
    OUT="${2:-$_REPO/data/oracle/n44_plus78_d20.jsonl}"
    echo "=== oracle grid start $(date +%H:%M:%S) -> $OUT ==="
    # DS_HOTSWAP / CARRIER_RESCUE 는 라벨러의 기본값이 OFF 인데(gen_oracle_dataset.jl:1352,
    # replace_robot.jl:804) 평가 데모는 둘 다 ON 이다(run_demo.jl:404,408). 그대로 두면 오라클과
    # 평가가 서로 다른 세계를 돌아, 로봇이 대열에서 빠지는 팔(fault/deep battery 의 NOOP·Replace)이
    # 오라클에서만 영영 완주하지 못한다 — 낀 carrier 가 하역 목표에 못 닿고 reform 은 forming 팀만
    # 건드려 원리적으로 못 구하기 때문(replace_robot.jl:715-727).
    # 2026-08-12 같은 세션 A/B 실측: 이 두 줄만 붙이면 fault 의 Replace 가 미완주(closed 243,
    # makespan Inf) -> 완주(closed 291, 22.75s)로 바뀌고, 그 값이 평가 런의 fault 결과와 일치한다.
    DS_KINDS=battery,fault,zone DS_SEEDS=1 DS_SPARES=3 DS_VALID_ONLY=1 DS_RESUME=1 \
    DS_HOTSWAP=1 CARRIER_RESCUE=1 \
    DS_OUT="$OUT" julia +lts --project=../.. gen_oracle_dataset.jl
    echo "=== oracle grid done rc=$? $(date +%H:%M:%S) rows=$(wc -l < "$OUT" 2>/dev/null || echo 0) ==="
    ;;
  matrix)
    SEED="${2:?usage: regen_d20.sh matrix <seed>}"
    OUT="${3:-results/matrix_d20.jsonl}"
    cd "$_REPO" || exit 2
    # 🔴 2026-09-03: 이 자리는 원래도 중단했지만 **200 만** 봤다 — 낡은 서비스는 200 을 낸다.
    #    이제 세대까지 본다. 사유는 CLI 가 코드로 찍는다(unstamped/blind/stale/flag_off).
    source "$_REPO/tools/require_current_service.sh"
    if ! require_current_service "$DSPY"; then
      echo "ABORT  요약 행은 policy=dspy 라고 적힐 텐데 그 열은 오염된다. 생성을 거부한다."
      exit 3
    fi
    # 기본은 7 케이스 전부. REGEN_CASES 로 부분집합만 돌릴 수 있다 — zone 축만 재측정할 때 쓴다
    # (예: REGEN_CASES="zone fault_zone battery_zone all"). 같은 OUT 에 append 되므로 부분 재실행
    # 결과와 기존 행이 한 파일에 섞인다. 섞으면 안 되는 재측정이면 OUT 을 새로 줄 것.
    for CASE in ${REGEN_CASES:-battery fault zone fault_battery fault_zone battery_zone all}; do
      start=$SECONDS
      echo "=== seed=$SEED case=$CASE $(date +%H:%M:%S) ==="
      python tools/sweep/llm_ood_eval.py run --case "$CASE" --seeds "$SEED" \
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
