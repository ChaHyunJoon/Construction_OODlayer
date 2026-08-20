#!/usr/bin/env bash
# =============================================================================
# render_all.sh -- 판(case × policy × seed)마다 `tools/monitor/render_demo.jl` 을 돌려
#                  **스트림 + MeshCat 3D 애니메이션**을 함께 만든다.
#
# run_4pol_parallel.sh 와의 차이: 저쪽은 `run_demo.jl` 로 **숫자**(rows.jsonl)를 만든다.
# 이쪽은 `render_demo.jl` 로 **대시보드 Factory View 의 3D 화면**(anim/*.html)을 만든다.
# 두 엔진은 같은 세계를 만들지 않는다 -- 자세한 것은 tools/monitor/README_RENDER_3D.md §1.
# **여기서 나온 숫자는 논문 표의 근거가 아니다. 표의 근거는 results_4pol/ 이 그대로 유지한다.**
#
# 왜 병렬에 별도 장치(모델 별칭)가 필요한가 -- README_RENDER_3D.md §5
# ---------------------------------------------------------------------
# render_demo.jl:1034 는 애니메이션을 **고정 경로**에서 집어 온다:
#     <repo>/results/<model_base>_render/greedy_RVO_Dispersion_TangentBug/visualization.html
# `model_base` 는 DEMO_MODEL 의 파일명에서만 나온다(render_demo.jl:107). 그래서 같은 모델을
# 동시에 여러 개 렌더하면 **모두 같은 파일에 쓰고 같은 파일을 집어 간다**. demo_utils.jl:413 의
# 저장은 `open(path,"w")` 로 먼저 파일을 **비운 뒤** 5 MB 짜리 HTML 문자열을 만들어 쓰므로,
# 그 사이에 다른 판이 자기 것을 집어 가면 **빈/잘린 애니**를 자기 판의 결과로 발행한다. 조용히.
#
# 그래서 이 스크립트는 워커마다 **모델 별칭**을 쓴다:
#     LDraw_files/_render_workers/<base>_w<K>.mpd  ->  ../<base>.mpd (심링크)
# 별칭이면 model_base 가 달라져 results/ 경로가 워커마다 갈린다. 시뮬레이션은 바뀌지 않는다 --
# tractor 의 파라미터(project_params.jl:59-63: model_scale=0.008, num_robots=10)가
# render_demo.jl:104-106 의 폴백(SCALE=0.008, NROB=DEMO_ROBOTS 기본 10)과 **같은 값**이기 때문.
# 다른 모델은 이 등식이 성립하지 않으므로 별칭을 끄고 K=1 로 떨어뜨린다.
# 별칭으로 나온 산출물 이름은 판이 끝날 때마다 정규 이름(<base>__...)으로 되돌린다.
#
# ⚠ 심링크 위험 -- README_RENDER_3D.md §2
# ---------------------------------------------------------------------
# tools/monitor/streams/ 에는 render/publish_streams.sh 가 건 **심링크**가 있고, 그 끝은
# results_4pol/shards/.../logs/*.jsonl (git 에 없는, 재생성에 40시간 걸리는 밤샘 산출물)이다.
# 렌더가 같은 이름에 쓰면 심링크를 타고 원본이 0 바이트로 잘린다(실측). 이 스크립트는 계획한
# 이름 중 하나라도 심링크면 **아무것도 돌리지 않고 멈춘다**.
#
# 사용법
#   bash render/render_all.sh --dry-run                        # 계획만 출력
#   bash render/render_all.sh --jobs 8                         # 기본 21판(7 case × 3 policy × seed 1)
#   bash render/render_all.sh --cases battery --policies dspy --jobs 1
#   bash render/render_all.sh --seeds 1,2,3 --jobs 8           # 63판
#   bash render/render_all.sh --force                          # 이미 있는 anim 도 다시 만든다
# =============================================================================
set -uo pipefail

# 2026-08-18 폴더 분류: 이 스크립트가 render/ 로 내려갔다. HERE=render/ ·
# WM=wm4spacecraft_manufacturing/ · REPO=레포 루트(tools/ · LDraw_files/ · .venv 가 있는 곳).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WM="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$WM/.." && pwd)"
MON="$REPO/tools/monitor"
ANIM_DIR="$MON/anim"
STREAM_DIR="$MON/streams"
NIGHT_DIR="$WM/_night"
LOG_DIR="$NIGHT_DIR/render_logs"
STATUS_FILE="$NIGHT_DIR/status_render.jsonl"
LOCK_FILE="$NIGHT_DIR/.render.lock"

MODEL="tractor.mpd"
CASES="battery,fault,all,fault_battery,fault_zone,battery_zone,zone"
POLICIES="noop,surrogate,dspy"
SEEDS="1"
JOBS=8
EVENTS=4                      # llm_ood_eval.py --events 기본값 = 스윕이 쓴 값
DSPY_URL="${DSPY_URL:-http://127.0.0.1:8090}"
# 돌릴 엔진 파일. 기본은 저장소의 것. 패치본/사본으로 검증할 때만 바꾼다 -- 사본을 쓸 때는 그
# 사본이 있는 폴더에 streams·anim 이 있어야 한다(render_demo.jl:113-114 가 @__DIR__ 를 쓴다).
RENDER_JL="${RENDER_DEMO_JL:-$MON/render_demo.jl}"
DRY_RUN=0
FORCE=0
USE_ALIAS=1

while [ $# -gt 0 ]; do
    case "$1" in
        --cases)     CASES="$2";    shift 2 ;;
        --policies)  POLICIES="$2"; shift 2 ;;
        --seeds)     SEEDS="$2";    shift 2 ;;
        --jobs)      JOBS="$2";     shift 2 ;;
        --events)    EVENTS="$2";   shift 2 ;;
        --model)     MODEL="$2";    shift 2 ;;
        --dspy-url)  DSPY_URL="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=1;     shift ;;
        --force)     FORCE=1;       shift ;;
        --no-alias)  USE_ALIAS=0;   shift ;;
        -h|--help)   sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "[error] 알 수 없는 인자: $1" >&2; exit 2 ;;
    esac
done

# server.jl:26 safe_base 와 같은 변환. 산출물 이름의 왼쪽 절반이다.
BASE="$(printf '%s' "${MODEL%.*}" | sed 's/[^A-Za-z0-9][^A-Za-z0-9]*/_/g')"

# 별칭은 "폴백 파라미터 == 실제 파라미터" 가 성립하는 모델에서만 안전하다(위 주석).
if [ "$USE_ALIAS" = "1" ] && [ "$MODEL" != "tractor.mpd" ]; then
    echo "[warn] --model $MODEL 은 별칭 등식이 검증돼 있지 않다 -> 별칭 끄고 K=1 로 내린다."
    USE_ALIAS=0
fi
if [ "$USE_ALIAS" = "0" ] && [ "$JOBS" -gt 1 ]; then
    echo "[warn] 별칭 없이 동시 렌더는 애니메이션을 조용히 서로 덮어쓴다 -> K=1 로 내린다."
    JOBS=1
fi

IFS=',' read -r -a CASE_ARR   <<< "$CASES"
IFS=',' read -r -a POL_ARR    <<< "$POLICIES"
IFS=',' read -r -a SEED_ARR   <<< "$SEEDS"

mkdir -p "$ANIM_DIR" "$STREAM_DIR" "$NIGHT_DIR" "$LOG_DIR"

# render_demo.jl 의 NSUF 규칙(render_demo.jl:57-58)을 그대로 다시 만든다.
nsuf_for() {   # $1=seed
    local s="$1" n=""
    [ "$EVENTS" -gt 0 ] && n="_n$EVENTS"
    [ "$s" != "1" ] && n="${n}_s$s"
    printf '%s' "$n"
}

# ---- 계획 + 안전 점검 ---------------------------------------------------
JOBLIST="$NIGHT_DIR/render_joblist.txt"
: > "$JOBLIST"
planned=0; skipped=0; danger=0
for seed in "${SEED_ARR[@]}"; do
    for case in "${CASE_ARR[@]}"; do
        for pol in "${POL_ARR[@]}"; do
            nsuf="$(nsuf_for "$seed")"
            name="${BASE}__${case}__${pol}${nsuf}"
            anim="$ANIM_DIR/$name.html"
            stream="$STREAM_DIR/$name.jsonl"
            # ⚠ 심링크면 렌더가 원본(밤샘 스윕 데이터)을 타고 들어가 잘라 버린다.
            if [ -L "$stream" ] || [ -L "$anim" ]; then
                echo "  DANGER  $name -> 심링크다: $(readlink "$stream" 2>/dev/null)$(readlink "$anim" 2>/dev/null)" >&2
                danger=$((danger + 1)); continue
            fi
            if [ "$FORCE" = "0" ] && [ -s "$anim" ]; then
                skipped=$((skipped + 1)); continue
            fi
            echo "$case $pol $seed" >> "$JOBLIST"
            planned=$((planned + 1))
        done
    done
done

echo "=== render_all.sh ==="
echo "  model    $MODEL  (base=$BASE)   events=$EVENTS"
echo "  case     ${#CASE_ARR[@]}개: $CASES"
echo "  policy   ${#POL_ARR[@]}개: $POLICIES"
echo "  seed     ${#SEED_ARR[@]}개: $SEEDS"
echo "  판       계획 $planned · 건너뜀(이미 anim 있음) $skipped · 위험 $danger"
echo "  병렬     K=$JOBS   별칭 $([ "$USE_ALIAS" = 1 ] && echo ON || echo OFF)"

if [ "$danger" -gt 0 ]; then
    cat >&2 <<'EOF'

[abort] 계획한 산출물 이름 중 일부가 **심링크**다. 그대로 렌더하면 Julia 의 open(path,"w") 가
        심링크를 따라가 원본(results_4pol/shards/.../logs/*.jsonl)을 0 바이트로 자른다 -- 실측.
        그 원본은 git 에 없다(.gitignore:46). 복구 수단은 재실행뿐이다(630판 ≈ 40시간).

        먼저 발행물을 걷어라:
            wm4spacecraft_manufacturing/render/publish_streams.sh --clean
        렌더가 끝난 뒤 다시 걸면 된다:
            wm4spacecraft_manufacturing/render/publish_streams.sh
EOF
    exit 1
fi
[ "$planned" -eq 0 ] && { echo "[done] 할 일이 없다."; exit 0; }

if [ "$DRY_RUN" = "1" ]; then
    echo "--- 작업 목록 (앞 10줄 / 총 $planned줄) ---"
    head -10 "$JOBLIST"
    exit 0
fi

# ---- 워커별 모델 별칭 ---------------------------------------------------
ALIAS_SUBDIR="_render_workers"
ALIAS_DIR="$REPO/LDraw_files/$ALIAS_SUBDIR"
if [ "$USE_ALIAS" = "1" ]; then
    mkdir -p "$ALIAS_DIR"
    for w in $(seq 1 "$JOBS"); do
        ln -sfn "../$MODEL" "$ALIAS_DIR/${BASE}_w${w}.mpd"
    done
fi

# ---- 큐 ----------------------------------------------------------------
CURSOR="$NIGHT_DIR/.render_cursor"
echo 0 > "$CURSOR"

next_job() {
    (
        flock 9
        local n; n=$(cat "$CURSOR"); n=$((n + 1)); echo "$n" > "$CURSOR"
        sed -n "${n}p" "$JOBLIST"
    ) 9>"$LOCK_FILE"
}

record_status() {   # case policy seed status wall anim_bytes
    (
        flock 9
        printf '{"case":"%s","policy":"%s","seed":%s,"status":"%s","wall_seconds":%s,"anim_bytes":%s}\n' \
            "$1" "$2" "$3" "$4" "$5" "$6" >> "$STATUS_FILE"
    ) 9>"$LOCK_FILE.status"
}

# ---- 판 하나 ------------------------------------------------------------
render_board() {   # case policy seed worker_index
    local case="$1" pol="$2" seed="$3" w="$4"
    local nsuf name log t0 rc dt bytes
    nsuf="$(nsuf_for "$seed")"
    name="${BASE}__${case}__${pol}${nsuf}"
    log="$LOG_DIR/$name.log"

    local demo_model raw
    if [ "$USE_ALIAS" = "1" ]; then
        demo_model="$ALIAS_SUBDIR/${BASE}_w${w}.mpd"
        raw="${BASE}_w${w}__${case}__${pol}${nsuf}"
    else
        demo_model="$MODEL"
        raw="$name"
    fi

    t0=$(date +%s)
    # 스레드 고정: 안 걸면 프로세스마다 코어 수만큼 스레드를 띄워 K 배로 코어를 뺏는다
    # (sweep/run_shard.sh 와 같은 이유). 나머지 환경변수는 sweep/llm_ood_eval.py:91-114 가 스윕에서
    # 넘긴 것과 같은 값 -- 단, render_demo.jl 이 읽지 않는 것도 있다(README_RENDER_3D.md §1).
    env \
        JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 MKL_NUM_THREADS=1 \
        PYTHONIOENCODING=utf-8 \
        DEMO_MODEL="$demo_model" DEMO_OOD="$case" DEMO_N="$EVENTS" \
        DEMO_SEED="$seed" DEMO_POLICY="$pol" DEMO_ROUTER=0 \
        DEMO_SPARES=3 DEMO_REFORM=300 DEMO_REFORM_MAX=6 DEMO_BSOC=0.9 DEMO_OOD_SEVFRAC=0.5 \
        CARRIER_RESCUE=1 RELOCATE_GATE=1 DSPY_URL="$DSPY_URL" LLM_NL_MODE=observation \
        DEMO_ANIM=1 MONITOR_INTERACTIVE=0 DEMO_CASE_TAG="${case}__${pol}" \
        julia +lts --project="$REPO" --startup-file=no "$RENDER_JL" \
        > "$log" 2>&1
    rc=$?
    dt=$(( $(date +%s) - t0 ))

    # 별칭 이름 -> 정규 이름. mv 는 rename(2) 이라 목적지가 심링크여도 **심링크 자체를** 바꾼다.
    if [ "$raw" != "$name" ]; then
        [ -f "$ANIM_DIR/$raw.html" ]     && mv -f "$ANIM_DIR/$raw.html"     "$ANIM_DIR/$name.html"
        [ -f "$STREAM_DIR/$raw.jsonl" ]  && mv -f "$STREAM_DIR/$raw.jsonl"  "$STREAM_DIR/$name.jsonl"
        rm -rf "$REPO/results/${BASE}_w${w}_render"
    fi

    bytes=0
    [ -f "$ANIM_DIR/$name.html" ] && bytes=$(stat -c %s "$ANIM_DIR/$name.html")

    if [ "$rc" -ne 0 ] || [ "$bytes" -lt 1000 ]; then
        record_status "$case" "$pol" "$seed" fail "$dt" "$bytes"
        echo "[render] FAIL  $name rc=$rc anim=${bytes}B ${dt}s -> $log"
        if grep -q "cannot document the following expression" "$log" 2>/dev/null; then
            echo "         ^ render_demo.jl:263 의 docstring 이 include 앞에 붙어 있다." \
                 "README_RENDER_3D.md §0 의 한 줄 수정이 먼저다."
        fi
        return 1
    fi
    record_status "$case" "$pol" "$seed" ok "$dt" "$bytes"
    echo "[render] OK    $name anim=$(( bytes / 1024 ))KB ${dt}s"
    return 0
}

# ---- 실행 --------------------------------------------------------------
START_TIME=$(date +%s)
echo "=== 시작 $(date +%F' '%H:%M:%S) ==="
for w in $(seq 1 "$JOBS"); do
    (
        while :; do
            job="$(next_job)"
            [ -z "$job" ] && break
            # shellcheck disable=SC2086
            set -- $job
            render_board "$1" "$2" "$3" "$w"
        done
    ) &
done
wait
echo "=== 종료 $(date +%F' '%H:%M:%S)  (${SECONDS}s 경과) ==="

# ---- 요약 --------------------------------------------------------------
"$REPO/.venv/bin/python" - "$STATUS_FILE" "$planned" <<'PYEOF'
import json, sys
from collections import Counter
path, planned = sys.argv[1], int(sys.argv[2])
seen, bad = {}, 0
with open(path, encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            bad += 1
            continue
        seen[(r["case"], r["policy"], r["seed"])] = r      # 재실행 시 마지막 기록이 이긴다
counts = Counter(r["status"] for r in seen.values())
walls = [r["wall_seconds"] for r in seen.values() if r["status"] == "ok"]
print("===== 렌더 요약 =====")
print("  ok %d · fail %d · 기록 %d" % (counts["ok"], counts["fail"], len(seen)))
if walls:
    walls.sort()
    print("  판당 벽시계  중앙값 %ds · 최소 %ds · 최대 %ds · 합 %ds"
          % (walls[len(walls) // 2], walls[0], walls[-1], sum(walls)))
if bad:
    print("  파싱 불가한 status 줄 %d개 -- 그만큼 이 요약에서 빠져 있다: %s" % (bad, path))
if counts["fail"]:
    print("  실패 판:")
    for k, r in sorted(seen.items()):
        if r["status"] == "fail":
            print("    %s %s s%s" % k)
    sys.exit(1)
PYEOF
rc=$?
echo "다음: 대시보드 상단 OOD events 를 렌더에 쓴 값으로 맞춰야 Factory View 가 뜬다" \
     "(events=0 이 아니면 파일 이름에 _nN 이 붙는다)."
exit $rc
