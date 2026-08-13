#!/usr/bin/env bash
# =============================================================================
# run_4pol_parallel.sh -- 7 case x 30 seed x 3 policy = 630 판을 K 병렬로 돈다.
#
# run_4pol.sh 를 대체하지 않는다. 그쪽은 순차 재현 경로로 남겨 둔다.
#
# 병렬이 가능한 근거 (docs/superpowers/specs/2026-08-12-parallel-30seed-sweep-design.md §2):
#   · HiGHS 경합 -- 이 경로는 run_demo.jl:387 이 assignment_mode=:greedy 라 MILP 를 안 푼다.
#   · OOM -- bethpage 가용 121 GB. K=16 이면 약 40 GB.
#   · MeshCat 포트 8700 -- run_demo.jl 에 MeshCat 이 없다(렌더는 render_demo.jl).
# 셋 다 이 경로에서 성립하지 않는다. 다만 그것이 "안전의 증명"은 아니므로 P7 게이트가 따로 있다.
#
# 사용법
#   bash run_4pol_parallel.sh --jobs 16
#   bash run_4pol_parallel.sh --dry-run                  # 작업 목록만 출력
#   bash run_4pol_parallel.sh --jobs 16 --seeds 1,2,3    # 일부만
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
cd "$HERE"

JOBS=16
SEEDS="1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30"
CASES="battery,fault,all,fault_battery,fault_zone,battery_zone,zone"
DEADLINE_SECONDS=28800          # 8 h
SHARDS_DIR="results_4pol/shards"
SKIP_GATES=0
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --jobs)              JOBS="$2"; shift 2 ;;
        --seeds)             SEEDS="$2"; shift 2 ;;
        --cases)             CASES="$2"; shift 2 ;;
        --deadline-seconds)  DEADLINE_SECONDS="$2"; shift 2 ;;
        --shards-dir)        SHARDS_DIR="$2"; shift 2 ;;
        --skip-gates)        SKIP_GATES=1; shift ;;
        --dry-run)           DRY_RUN=1; shift ;;
        *) echo "[error] 알 수 없는 인자: $1" >&2; exit 2 ;;
    esac
done

NIGHT_DIR="$HERE/_night"
STATUS_FILE="$NIGHT_DIR/status_shards.jsonl"
LOCK_FILE="$NIGHT_DIR/.status.lock"
mkdir -p "$NIGHT_DIR" "$SHARDS_DIR"

IFS=',' read -r -a SEED_ARR <<< "$SEEDS"
IFS=',' read -r -a CASE_ARR <<< "$CASES"
TOTAL=$(( ${#SEED_ARR[@]} * ${#CASE_ARR[@]} ))

# ---- 작업 목록 ----------------------------------------------------------
# seed 를 바깥, case 를 안쪽에 둔다. case 를 바깥에 두면 한 case 가 통째로 같은 시간대에
# 몰려 case 와 부하 조건이 교락된다. 이 순서면 어느 시각에도 여러 case 가 섞여 돈다.
# 값싼 case 를 앞세우는 비용 기반 재정렬은 하지 않는다 -- 같은 이유다.
JOBLIST="$NIGHT_DIR/joblist.txt"
: > "$JOBLIST"
for seed in "${SEED_ARR[@]}"; do
    for case in "${CASE_ARR[@]}"; do
        echo "$case $seed" >> "$JOBLIST"
    done
done

echo "=== run_4pol_parallel.sh ==="
echo "  case  ${#CASE_ARR[@]}개: $CASES"
echo "  seed  ${#SEED_ARR[@]}개: ${SEED_ARR[0]}..${SEED_ARR[${#SEED_ARR[@]}-1]}"
echo "  샤드  $TOTAL개 (판 $(( TOTAL * 3 ))개), 병렬 K=$JOBS"
echo "  데드라인 ${DEADLINE_SECONDS}s, 샤드 트리 $SHARDS_DIR"

if [ "$DRY_RUN" = "1" ]; then
    echo "--- 작업 목록 (앞 10줄 / 총 $(wc -l < "$JOBLIST")줄) ---"
    head -10 "$JOBLIST"
    exit 0
fi

# ---- 게이트 ------------------------------------------------------------
if [ "$SKIP_GATES" = "0" ]; then
    if ! bash gate_prereq.sh "$JOBS"; then
        echo "게이트 불합격 -- 스윕을 시작하지 않는다."
        exit 1
    fi
else
    echo "[warn] --skip-gates: 사전 조건 게이트를 건너뛴다."
fi

START_TIME=$(date +%s)
export START_TIME DEADLINE_SECONDS SHARDS_DIR STATUS_FILE LOCK_FILE HERE

# ---- 워커 --------------------------------------------------------------
# xargs 가 부르는 함수. 인자: CASE SEED
worker() {
    local case="$1" seed="$2"
    local outdir="$SHARDS_DIR/$case/s$seed"

    local now elapsed
    now=$(date +%s); elapsed=$(( now - START_TIME ))
    if [ "$elapsed" -ge "$DEADLINE_SECONDS" ]; then
        # 데드라인을 넘으면 새 샤드를 투입하지 않는다. 이미 도는 샤드는 건드리지 않는다.
        record_status "$case" "$seed" "deadline" 0 0
        echo "[deadline] SKIP case=$case seed=$seed (elapsed=${elapsed}s)"
        return 0
    fi

    local t0 rc dt rows
    t0=$(date +%s)
    bash "$HERE/run_shard.sh" "$case" "$seed" "$outdir"
    rc=$?
    dt=$(( $(date +%s) - t0 ))
    rows=$(count_rows "$outdir/rows.jsonl")
    record_status "$case" "$seed" "$([ $rc -eq 0 ] && echo ok || echo fail)" "$rows" "$dt"
    return 0        # 샤드 하나가 죽어도 스윕 전체는 계속 간다. 집계는 병합기가 판정한다.
}

# 파일이 없거나 비어도 **정수 하나만** 낸다(run_shard.sh 와 같은 헬퍼).
# 여기 있던 `rows=$(grep -c . "$f" 2>/dev/null || echo 0)` 는 조용히 틀렸다: grep -c 는 매치가
# 0건이어도 stdout 에 "0" 을 찍고 rc=1 로 끝나므로 `|| echo 0` 까지 같이 터져 rows 가 "0\n0"
# 두 줄이 된다. 그 값이 record_status 의 printf 로 들어가면 JSON 한 줄이 두 줄로 쪼개져
# 둘 다 파싱 불가가 되고, 아래 요약 파서는 JSONDecodeError 를 그냥 continue 로 삼킨다 --
# 그래서 **실패한 샤드가 리포트에서 통째로 사라지고** 운영자는 fail 0 을 읽는다.
count_rows() {
    local f="$1" n
    [ -f "$f" ] || { echo 0; return; }
    n=$(grep -c . "$f" 2>/dev/null)
    echo "${n:-0}"
}

# status 한 줄은 200 B 미만이라 O_APPEND 로 원자적이지만, flock 을 걸어 확실히 한다.
record_status() {
    local case="$1" seed="$2" status="$3" rows="$4" wall="$5"
    (
        flock 9
        printf '{"case":"%s","seed":%s,"status":"%s","rows":%s,"wall_seconds":%s}\n' \
            "$case" "$seed" "$status" "$rows" "$wall" >> "$STATUS_FILE"
    ) 9>"$LOCK_FILE"
}

export -f worker record_status count_rows

# ---- 실행 --------------------------------------------------------------
echo "=== 시작 $(date +%F' '%H:%M:%S) ==="
xargs -a "$JOBLIST" -n 2 -P "$JOBS" bash -c 'worker "$@"' _
echo "=== 종료 $(date +%F' '%H:%M:%S) ==="

# ---- 요약 --------------------------------------------------------------
# 요약은 **끝까지 다 찍고 나서** 종료 코드를 정한다. 예전에는 마지막이 무조건 `exit 0` 이라
# 실패 샤드가 몇 개든, `기록된 샤드 N / 계획 M` 이 어긋나든 오케스트레이터는 성공을 보고했다.
# 밤새 도는 스윕을 rc 로 감시하는 쪽에서는 그게 곧 "문제 없음" 이라 아무도 재시도하지 않는다.
"$REPO/.venv/bin/python" - "$STATUS_FILE" "$TOTAL" <<'PYEOF'
import json, sys
from collections import Counter
path, total = sys.argv[1], int(sys.argv[2])
seen, counts = {}, Counter()
bad_lines = 0
with open(path, encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            # 예전에는 여기서 조용히 continue 했다. record_status 가 깨진 줄을 쓰면(과거의
            # rows="0\n0" 버그) 그 샤드가 리포트에서 통째로 사라졌다 -- 이제는 세어서 알린다.
            bad_lines += 1
            continue
        seen[(r["case"], r["seed"])] = r["status"]      # 재실행 시 마지막 기록이 이긴다
for st in seen.values():
    counts[st] += 1
print("===== 샤드 요약 =====")
for st in ("ok", "fail", "deadline"):
    print("  %-9s %d" % (st, counts[st]))
print("  기록된 샤드 %d / 계획 %d" % (len(seen), total))
if bad_lines:
    print("  파싱 불가한 status 줄 %d개 -- 그만큼의 샤드가 이 요약에서 빠져 있다: %s"
          % (bad_lines, path))
if counts["fail"]:
    print("  실패 샤드:")
    for (c, s), st in sorted(seen.items()):
        if st == "fail":
            print("    case=%s seed=%s" % (c, s))
if counts["deadline"]:
    print("  데드라인으로 투입되지 않은 샤드:")
    for (c, s), st in sorted(seen.items()):
        if st == "deadline":
            print("    case=%s seed=%s" % (c, s))

problems = []
if counts["fail"]:
    problems.append("실패 샤드 %d개" % counts["fail"])
if counts["deadline"]:
    problems.append("데드라인으로 못 돈 샤드 %d개" % counts["deadline"])
if len(seen) < total:
    problems.append("기록된 샤드가 %d개로 계획(%d)보다 모자람" % (len(seen), total))
if bad_lines:
    problems.append("파싱 불가한 status 줄 %d개" % bad_lines)
if problems:
    print("\n[verdict] 스윕 미완: " + ", ".join(problems)
          + " -- 병합/리포트 전에 재시도할 것.")
    sys.exit(1)
print("\n[verdict] 계획한 샤드 %d개 전부 ok." % total)
PYEOF
summary_rc=$?

exit "$summary_rc"
