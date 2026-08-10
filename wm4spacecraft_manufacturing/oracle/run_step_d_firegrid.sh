#!/usr/bin/env bash
# =============================================================================
# run_step_d_firegrid.sh -- STEP D 파트 1: firegrid 야간 러너 (2026-08-10)
#
# [목적]
#   run_firegrid_fault.ps1 을 fault/faultidle 두 레인만 돌리는 얇은 래퍼.
#   battB(=battery TIER B) 는 oracle/out/battgrid_0805_s1.jsonl 이 그 축을 이미 덮으므로
#   야간에는 건너뛴다 (ORACLE_REBUILD_2026-08-09.md §II STEP 1).
#   실행 뒤 merge_firegrid.py 로 CANONICAL + firegrid_s*.jsonl -> firegrid_merged.jsonl 을 만든다.
#
# [재개 안전성]
#   레인 필터는 run_firegrid_fault.ps1 의 $common 에 이미 있는 DS_RESUME=1 위에 얹힐 뿐이다 --
#   gen_oracle_dataset.jl 이 DS_OUT 파일에 이미 있는 instance 는 건너뛰고 이어서 쓴다. 그래서
#   이 래퍼는 "출력 파일이 있으면 통째로 건너뛴다" 같은 레인 단위 스킵 가드를 **일부러 두지 않는다**
#   -- ps1 을 항상 다시 부르고, 이미 끝난 instance 를 건너뛰는 판단은 Julia 쪽(DS_RESUME)에 맡긴다.
#   (run_step_d_zcausal.sh 의 [-s "$OUT/$arm.json"] 가드와는 다른 이유: ZC_OUT 은 append-only 라
#   중복 실행이 파일을 깨뜨리지만, firegrid 의 DS_OUT 은 instance 단위로 안전하게 재개된다.)
#   병합(merge_firegrid.py)도 매번 소스 파일에서 다시 계산하는 멱등 연산이라 재실행해도 안전하다.
#
# [조용한 실패 방지]
#   각 레인 산출물이 실제로 존재/non-empty 인지, 이름이 `firegrid_s*.jsonl` 규칙(merge_firegrid.py
#   의 glob 대상)을 지키는지 검사한다. 하나라도 어기면 병합을 건너뛰고 fail 로 죽는다.
#
# Usage:
#   bash oracle/run_step_d_firegrid.sh              # 실제 실행 (julia 를 돈다, PowerShell 경유)
#   bash oracle/run_step_d_firegrid.sh --dry-run     # 무엇을 돌릴지만 찍고 아무것도 실행하지 않음
# =============================================================================
set -u

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
    esac
done

# ---- 경로 --------
# 이 스크립트는 wm4spacecraft_manufacturing/oracle/ 에 있다. 두 단계 위가 repo 루트.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WM="$REPO/wm4spacecraft_manufacturing"
PS1="$WM/oracle/run_firegrid_fault.ps1"
OUT="$WM/oracle/out"
LOGDIR="$REPO/_night/logs"
LOG="$LOGDIR/stepD_firegrid.log"
MERGE_PY="$WM/merge_firegrid.py"

LANES="fault,faultidle"

mkdir -p "$LOGDIR" "$OUT"

echo "[step-d-firegrid] lanes=$LANES -> $PS1"
echo "[step-d-firegrid] log -> $LOG"

if [ "$DRY_RUN" = "1" ]; then
    PS1_WIN="$(cygpath -w "$PS1" 2>/dev/null || echo "$PS1")"
    echo "[dry-run] would execute:"
    echo "[dry-run]   FG_LANES='$LANES' powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"$PS1_WIN\" >> \"$LOG\" 2>&1"
    echo "[dry-run] then:"
    echo "[dry-run]   python \"$MERGE_PY\" >> \"$LOG\" 2>&1"
    echo "[dry-run]"
    echo "[dry-run] --- 참고용(정보 제공 목적): run_firegrid_fault.ps1 이 각 레인에 실제로 넣는 env"
    echo "[dry-run]     (진짜 값은 그 파일 \$common/\$lanes 이 유일한 출처 -- 여기는 검증용 요약일 뿐) ---"
    echo "[dry-run]   [common]  DS_RESUME=1 DS_REFORM=120 DS_HOTSWAP=1 DS_VALID_ONLY=1 DS_FAULT_PICK=auto DS_SPARES=3 DS_NOPROG=8000"
    echo "[dry-run]   [fault]     DS_KINDS=fault     DS_SEEDS=1 DS_FIRE_GRID=58,80,100,120,140,160,180,200,220,240,260"
    echo "[dry-run]               -> $OUT/firegrid_sfault.jsonl"
    echo "[dry-run]   [faultidle] DS_KINDS=faultidle DS_SEEDS=1 DS_FIRE_GRID=58,80,100,120,140,160,180,200,220,240,260"
    echo "[dry-run]               -> $OUT/firegrid_sfaultidle.jsonl"
    echo "STATUS stepD_firegrid dry-run rows=0 lanes=$LANES"
    exit 0
fi

# ---- 실행: run_firegrid_fault.ps1 (FG_LANES 로 battB 제외) --------
FG_LANES="$LANES" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$PS1")" 2>&1 | tee -a "$LOG"
PS1_RC=${PIPESTATUS[0]}
if [ "$PS1_RC" -ne 0 ]; then
    echo "[step-d-firegrid] ERROR: run_firegrid_fault.ps1 exit=$PS1_RC"
    echo "STATUS stepD_firegrid fail rows=0 lanes=$LANES"
    exit 1
fi

# ---- 산출물 검증: 이름 규칙(firegrid_s*.jsonl) + non-empty --------
# STATUS 의 rows=<n> 은 이번 실행의 두 레인 파일(firegrid_sfault/faultidle.jsonl)에 담긴 원본
# JSONL 줄 수 합이다 (병합/중복제거 전, "라벨이 실제로 나왔는가"의 최소 신호). merge_firegrid.py
# 이후의 "CANONICAL 18 + 신규분 > 18" instance 판정은 별도 검증기(verify_night.py, Task 6)의 몫이다.
total_rows=0
fail=0
for lane in fault faultidle; do
    f="$OUT/firegrid_s${lane}.jsonl"
    base="$(basename "$f")"
    case "$base" in
        firegrid_s*.jsonl) ;;
        *)
            echo "[step-d-firegrid] ERROR: $f 가 firegrid_s*.jsonl 명명 규칙을 어긴다 (merge_firegrid.py 가 조용히 빠뜨린다)"
            fail=1
            continue
            ;;
    esac
    if [ ! -s "$f" ]; then
        echo "[step-d-firegrid] ERROR: $f 가 없거나 비어 있다 (lane=$lane 조용한 실패)"
        fail=1
        continue
    fi
    n=$(wc -l < "$f" | tr -d ' ')
    echo "[step-d-firegrid] $lane -> $f ($n rows)"
    total_rows=$((total_rows + n))
done

if [ "$fail" -ne 0 ]; then
    echo "STATUS stepD_firegrid fail rows=$total_rows lanes=$LANES"
    exit 1
fi

# ---- 병합: CANONICAL + firegrid_s*.jsonl -> firegrid_merged.jsonl (CANONICAL 은 덮어쓰지 않음) --------
python "$MERGE_PY" 2>&1 | tee -a "$LOG"
MERGE_RC=${PIPESTATUS[0]}
if [ "$MERGE_RC" -ne 0 ]; then
    echo "[step-d-firegrid] ERROR: merge_firegrid.py exit=$MERGE_RC"
    echo "STATUS stepD_firegrid fail rows=$total_rows lanes=$LANES"
    exit 1
fi

echo "STATUS stepD_firegrid ok rows=$total_rows lanes=$LANES"
