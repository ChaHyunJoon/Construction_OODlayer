#!/usr/bin/env bash
# =============================================================================
# run_step_d_zcausal.sh -- STEP D 파트 2: 구역 인과성 실험의 4팔 순차 러너
#
# [목적]
#   게이트 test_llm7h.py 가 읽는 네 팔의 JSON 출력물을 재생성한다.
#   - 팔 4개: blk_noop, blk_reloc, cov_noop, cov_reloc
#   - 각 팔마다 프로세스를 새로 띄워야 한다(RVO 상태 격리).
#   - 순차 실행(병렬 금지: HiGHS 상이 스케줄 → 비교 무효).
#
# [복구 사다리(reform)]
#   모든 팔에 동일한 사다리를 건다:
#   - ZC_REFORM=400 (무진전 400 스텝마다 복구 시도)
#   - ZC_REFORM_MAX=3 (연속 허용 횟수)
#   이 사다리가 없으면 네 팔이 전부 루트 엔드게임에서 교착해 구역 효과가 가려진다.
#
# [실패 모드]
#   이 스크립트에서 가장 취약한 지점: ZC_OUT 이 append 모드이므로
#   같은 파일에 두 번 쓰면 JSON 객체가 이어붙어 json.load() 가 깬다.
#   [ -s "$OUT/$arm.json" ] 스킵 가드가 이를 막는다 — 이 가드를 빼지 말 것.
#
# [재개 안전성]
#   스크립트가 중단되고 다시 실행되면, 완료한 팔의 파일이 존재해서
#   [ -s ... ] 조건이 참이 되고 그 팔은 건너뛴다(재개 안전).
#   부분 실패한 팔(깨진 JSON): 그 .json 만 지우고 스크립트를 다시 돌린다.
# =============================================================================

set -u
cd "$(dirname "$0")/../.." || exit 1

# ---- 설정 --------
OUT=wm4spacecraft_manufacturing/oracle/out/zcausal_reform
ARMS=("blk_noop" "blk_reloc" "cov_noop" "cov_reloc")
REFORM=400
REFORM_MAX=3

# ---- 명령줄 인자 파싱 --------
# 환경변수와 CLI 둘 다 지원: STEP_D_DRY_RUN 또는 --dry-run 인자
DRY_RUN="${STEP_D_DRY_RUN:-}"  # 환경변수 기본값
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run)
                DRY_RUN="1"
                shift
                ;;
            *)
                echo "[error] 알 수 없는 인자: $1"
                echo "사용법: bash run_step_d_zcausal.sh [--dry-run]"
                exit 1
                ;;
        esac
    done
}

parse_args "$@"

# ---- Julia 프로세스 사전 점검 (Global Constraint 1 방어) --------
# 이미 실행 중인 Julia가 있으면 중단 — 두 번째 프로세스는 HiGHS 다중 실행으로 비교를 무효화한다.
check_no_julia_running() {
    if tasklist 2>/dev/null | grep -qi "julia.exe"; then
        echo "[FATAL] julia.exe 프로세스가 이미 실행 중입니다!"
        echo "  → 이미 실행 중인 Julia를 종료한 후 다시 시도하세요."
        echo "  → HiGHS 다중 실행은 스케줄을 변경하여 비교 실험을 무효화합니다."
        exit 1
    fi
}

# dry-run 아니면 사전 점검
if [ -z "$DRY_RUN" ]; then
    check_no_julia_running
fi

# ---- 준비 --------
mkdir -p "$OUT"
completed=0
failed=0

# ---- 팔 실행 함수 --------
run_arm() {
    local arm="$1"
    local armfile="$OUT/$arm.json"

    # 재개 안전: 이미 완료한 팔은 건너뛴다
    if [ -s "$armfile" ]; then
        echo "[skip] $arm (파일 존재: $armfile)"
        ((completed++))
        return 0
    fi

    # Julia 명령 조립
    local julia_cmd="julia +lts --project=. tools/restage.jl causal"
    local log_file="$OUT/${arm}.log"

    # 환경 변수 설정
    local env_cmd="ZC_ARM='$arm' ZC_OUT='$armfile' ZC_REFORM=$REFORM ZC_REFORM_MAX=$REFORM_MAX"

    # 전체 명령
    local full_cmd="$env_cmd $julia_cmd > '$log_file' 2>&1"

    if [ -z "$DRY_RUN" ]; then
        # 실제 실행 (이 코드는 실행되지 않음 - Task 에서 금지됨)
        eval "$full_cmd"
        local exit_code=$?
    else
        # --dry-run: 명령만 출력
        echo "[dry-run] 팔=$arm"
        echo "  $env_cmd \\"
        echo "  $julia_cmd > '$log_file' 2>&1"
        local exit_code=0
    fi

    if [ "$exit_code" -ne 0 ]; then
        echo "[error] $arm 실행 실패 (exit=$exit_code)"
        ((failed++))
        return 1
    fi

    # JSON 파싱 검증 (실제 실행할 때만)
    if [ -z "$DRY_RUN" ]; then
        if [ ! -s "$armfile" ]; then
            echo "[error] $arm: 출력 파일이 없거나 비어있음: $armfile"
            ((failed++))
            return 1
        fi

        # Python으로 JSON 파싱 (json.load() 호환성 확인)
        # 만약 append 중복이 있으면 파싱이 실패한다
        if ! python -c "import json; json.load(open('$armfile'))" 2>/dev/null; then
            echo "[error] $arm: JSON 파싱 실패 → 파일 깨짐 (append 중복?)"
            echo "  → 파일을 삭제하고 이 팔을 다시 실행하세요: rm '$armfile'"
            ((failed++))
            return 1
        fi

        echo "[done] $arm ✓"
        ((completed++))
    else
        echo "[dry-run check] $arm JSON 파싱 (실제 실행 시 검증됨)"
        ((completed++))
    fi

    return 0
}

# ---- 순차 루프 (병렬 금지) --------
echo "=========================================="
echo "STEP D 파트 2: zcausal 4팔 순차 실행"
echo "복구 사다리: ZC_REFORM=$REFORM ZC_REFORM_MAX=$REFORM_MAX"
echo "=========================================="
echo ""

for arm in "${ARMS[@]}"; do
    echo ">>> 실행: $arm"
    run_arm "$arm"
    echo ""
done

# ---- 최종 검증 --------
echo "=========================================="
echo "최종 검증"
echo "=========================================="

all_exist=true
all_valid=true

for arm in "${ARMS[@]}"; do
    armfile="$OUT/$arm.json"

    # 파일 존재 확인
    if [ ! -s "$armfile" ]; then
        echo "[error] 파일 없음: $armfile"
        all_exist=false
    else
        echo "[ok] 파일 존재: $armfile"

        # 파일이 있으면 JSON 파싱 검증 (dry-run이 아닐 때만)
        if [ -z "$DRY_RUN" ]; then
            if ! python -c "import json; json.load(open('$armfile'))" 2>/dev/null; then
                echo "  [error] JSON 파싱 실패!"
                all_valid=false
            else
                echo "  [ok] JSON 파싱 성공"
            fi
        fi
    fi
done

echo ""
echo "=========================================="

# ---- 최종 상태 출력 --------
if $all_exist && $all_valid && [ "$failed" -eq 0 ]; then
    status="ok"
    echo "STATUS stepD_zcausal ok arms=$completed/4"
else
    status="fail"
    echo "STATUS stepD_zcausal fail arms=$completed/4"
    if [ ! "$all_exist" = "true" ]; then
        echo "  → 누락된 파일이 있습니다."
    fi
    if [ ! "$all_valid" = "true" ]; then
        echo "  → 깨진 JSON이 있습니다. 해당 .json 파일을 삭제하고 다시 실행하세요."
    fi
    exit 1
fi

exit 0
