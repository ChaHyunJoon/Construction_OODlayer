#!/usr/bin/env bash
# =============================================================================
# run_4pol.sh -- 무인 ~5시간 스윕: 3개 실행 정책(noop, surrogate, dspy) x 8개 OOD case.
#
# 이 스크립트가 하는 일: 순수 바깥 루프뿐이다. 판(board) 하나 = (case, ood_seed, policy) 하나이고,
# 실제 순차 실행(시드 x 정책)은 llm_ood_eval.py run 이 내부에서 이미 한다 -- 이 스크립트는
# 그 호출을 case 마다 한 번씩 걸고, 데드라인/재개/STATUS 기록만 얹는다.
#
# `oracle` 은 실행 가능한 온라인 정책이 아니다(policy.jl 에 oracle 분기 없음) -- 일부러 3정책에서
# 뺐다. 최종 표에는 별도 계산되는 상한선 행으로만 들어간다.
#
# Usage:
#   bash run_4pol.sh [--deadline-seconds N] [--seeds 1,2,3,4,5] [--resume]
# =============================================================================
set -euo pipefail

START_TIME=$(date +%s)

# ---- 경로 -- 이 스크립트는 wm4spacecraft_manufacturing/ 에 있다(모듈 상대 경로가 그 가정을 깐다).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

PY="/home/chahj578/Construction_OODlayer/.venv/bin/python"
RESULTS_DIR="$HERE/results_4pol"
NIGHT_DIR="$HERE/_night"
LOG_DIR="$NIGHT_DIR/logs"
STATUS_FILE="$NIGHT_DIR/status_4pol.jsonl"

DSPY_URL="${DSPY_URL:-http://127.0.0.1:8090}"
POLICIES="noop,surrogate,dspy"

# ---- 인자 --------------------------------------------------------------
# 기본은 7 case -- zonecore 는 뺐다(run_demo.jl:433 이 :zonecore 를 :zone 으로 바꾸므로 `zone` 과 같은 실험).
CASES_CSV="battery,fault,all,fault_battery,fault_zone,battery_zone,zone"
DEADLINE_SECONDS=86400
SEEDS="1,2,3,4,5"
RESUME=0

while [ $# -gt 0 ]; do
    case "$1" in
        --deadline-seconds)
            DEADLINE_SECONDS="$2"; shift 2 ;;
        --seeds)
            SEEDS="$2"; shift 2 ;;
        --cases)
            CASES_CSV="$2"; shift 2 ;;
        --resume)
            RESUME=1; shift ;;
        *)
            echo "[error] 알 수 없는 인자: $1" >&2
            exit 1 ;;
    esac
done

IFS=',' read -r -a SEED_ARR <<< "$SEEDS"
N_SEEDS=${#SEED_ARR[@]}
EXPECTED_ROWS=$(( N_SEEDS * 3 ))

# ---- case 목록: 실행 순서 그대로 (TIER1 -> TIER2 -> TIER3) --------------
IFS=',' read -r -a CASES <<< "$CASES_CSV"

# 2026-08-11 재보정 (2차): 1차 재보정은 results_4pol/*.jsonl 의 `wall_seconds` 필드를 썼는데,
# 그건 julia 가 자기 시뮬레이션만 잰 값이라 julia 프로세스 기동 + JIT(~100 s/판)이 빠져 있다.
# 판마다 julia 를 새로 띄우므로 그 시간은 실제 비용이다. 아래는 _night/status_4pol.jsonl 의
# bash 실측 벽시계(T1-T0, case 당 15판)에서 유도한 값 x1.15.
unit_price_for_case() {
    case "$1" in
        all)           echo 245 ;;   # 실측 212.3
        fault_battery) echo 215 ;;   # 실측 186.2
        fault_zone)    echo 205 ;;   # 실측 175.4
        zone)          echo 190 ;;   # 실측 164.3
        battery_zone)  echo 190 ;;   # 실측 162.1
        fault)         echo 180 ;;   # 실측 154.6
        battery)       echo 165 ;;   # 실측 143.9
        zonecore)      echo 200 ;;   # 실측 172.5 (기본 목록엔 없다 -- zone 과 같은 실험)
        *)             echo 245 ;;   # 미지의 case 는 가장 비싼 값으로
    esac
}

count_rows() {
    local f="$1"
    if [ -f "$f" ]; then
        wc -l < "$f" | tr -d ' '
    else
        echo 0
    fi
}

# =========================================================================
# R1 -- 사전 조건 게이트. 여섯 가지 다 통과해야 case 를 하나라도 돈다.
#        실패하면 어느 게이트인지 찍고 즉시 exit 1 -- 조용한 폴백 없음.
# =========================================================================
echo "=== run_4pol.sh: R1 사전 조건 게이트 ==="

# P1 -- 살아있는 LLM 프로브: POST $DSPY_URL/macro
P1_BODY='{"kind":"battery","severity":0.6,"soc":0.12,"spare_count":2,"agent_pending":1,"progress":0.4,"n_active":4,"nl":"A transport robot reports state of charge 12 percent while carrying an assembly."}'
set +e
P1_RESP=$(curl -s -w '\n%{http_code}' -X POST "$DSPY_URL/macro" \
    -H 'Content-Type: application/json' -d "$P1_BODY" 2>/dev/null)
P1_CURL_RC=$?
set -e
if [ $P1_CURL_RC -ne 0 ] || [ -z "$P1_RESP" ]; then
    echo "PREREQ FAIL: P1 (live LLM probe) -- curl could not reach $DSPY_URL/macro (rc=$P1_CURL_RC)"
    exit 1
fi
P1_HTTP_CODE=$(printf '%s' "$P1_RESP" | tail -n1)
P1_JSON_BODY=$(printf '%s' "$P1_RESP" | sed '$d')
if [ "$P1_HTTP_CODE" != "200" ]; then
    echo "PREREQ FAIL: P1 (live LLM probe) -- http_code=$P1_HTTP_CODE"
    exit 1
fi
P1_OK=$(printf '%s' "$P1_JSON_BODY" | "$PY" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("0"); sys.exit(0)
err_ok = d.get("error") is None
pol = d.get("policy") or ""
pol_ok = isinstance(pol, str) and pol.startswith("dspy")
print("1" if (err_ok and pol_ok) else "0")
' 2>/dev/null || echo "0")
if [ "$P1_OK" != "1" ]; then
    echo "PREREQ FAIL: P1 (live LLM probe) -- response did not satisfy error:null AND policy startswith 'dspy': $P1_JSON_BODY"
    exit 1
fi
echo "[gate] P1 OK (live LLM probe)"

# P2 -- 헬스체크 + 프로그램 신원 기록.
# (2026-08-11) 예전엔 http_code 만 봤다. dspy_service.py:90 은 DSPY_PROGRAM 이 비면 컴파일된
# gpt4o 프로그램으로 조용히 폴백하는데, 그건 battery 전용 어휘라 zone 을 재면 어휘 밖을 재게 된다.
# 어느 프로그램으로 쟀는지 남기지 않으면 사후에 알 방법이 없다.
set +e
P2_RESP=$(curl -s -w '\n%{http_code}' "$DSPY_URL/health" 2>/dev/null)
set -e
P2_CODE=$(printf '%s' "$P2_RESP" | tail -n1)
P2_BODY=$(printf '%s' "$P2_RESP" | sed '$d')
if [ "$P2_CODE" != "200" ]; then
    echo "PREREQ FAIL: P2 (health check) -- http_code=$P2_CODE"
    exit 1
fi
mkdir -p "$NIGHT_DIR"
printf '%s\n' "$P2_BODY" > "$NIGHT_DIR/provenance_4pol.json"
DSPY_PROGRAM_USED=$(printf '%s' "$P2_BODY" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("program","?"))' 2>/dev/null || echo "?")
echo "[gate] P2 OK (health check) -- program=$DSPY_PROGRAM_USED"

# P3 -- 행동 어휘 감사
if ! "$PY" audit_action_vocab.py; then
    echo "PREREQ FAIL: P3 (audit_action_vocab.py) -- non-zero exit"
    exit 1
fi
echo "[gate] P3 OK (audit_action_vocab.py)"

# P4 -- surrogate 지원 집합 계약
if ! "$PY" test_surrogate_support.py; then
    echo "PREREQ FAIL: P4 (test_surrogate_support.py) -- non-zero exit"
    exit 1
fi
echo "[gate] P4 OK (test_surrogate_support.py)"

# P5 -- 이미 도는 julia 없어야 함 (내 uid 한정, README 함정 30)
if pgrep -x -u "$(id -u)" julia >/dev/null 2>&1; then
    echo "PREREQ FAIL: P5 (julia already running for uid $(id -u)) -- HiGHS 경합으로 비교가 무효화된다"
    exit 1
fi
echo "[gate] P5 OK (no running julia)"

# P6 -- results_4pol/ 비어있거나 없어야 함, --resume 이면 예외
if [ "$RESUME" -eq 0 ]; then
    if [ -d "$RESULTS_DIR" ] && [ -n "$(ls -A "$RESULTS_DIR" 2>/dev/null)" ]; then
        echo "PREREQ FAIL: P6 (results_4pol/ exists and is non-empty; pass --resume to continue a prior sweep)"
        exit 1
    fi
fi
echo "[gate] P6 OK (results_4pol/ clean or --resume passed)"

echo "=== R1 게이트 통과 ==="

mkdir -p "$RESULTS_DIR" "$NIGHT_DIR" "$LOG_DIR"

emit_status() {
    local c="$1" status="$2" rows="$3" wall="$4"
    printf '{"case":"%s","status":"%s","rows":%d,"wall_seconds":%d,"seeds":"%s","policies":"%s","program":"%s"}\n' \
        "$c" "$status" "$rows" "$wall" "$SEEDS" "$POLICIES" "$DSPY_PROGRAM_USED" >> "$STATUS_FILE"
    echo "STATUS 4pol $c $status rows=$rows"
}

SUMMARY_CASES=()
SUMMARY_STATUS=()
SUMMARY_ROWS=()
ALL_OK=1

for CASE in "${CASES[@]}"; do
    OUT_FILE="$RESULTS_DIR/$CASE.jsonl"
    UNIT_PRICE=$(unit_price_for_case "$CASE")
    EST_COST=$(( UNIT_PRICE * N_SEEDS * 3 ))
    CUR_ROWS=$(count_rows "$OUT_FILE")

    # R4 -- resume: 이미 n_seeds x 3 줄이 있으면 다시 돌리지 않는다. 데드라인보다 먼저 본다
    # (재개된 case 는 남은 시간과 무관하게 재개다).
    if [ "$RESUME" -eq 1 ] && [ "$CUR_ROWS" -ge "$EXPECTED_ROWS" ]; then
        emit_status "$CASE" "resumed" "$CUR_ROWS" 0
        SUMMARY_CASES+=("$CASE"); SUMMARY_STATUS+=("resumed"); SUMMARY_ROWS+=("$CUR_ROWS")
        ALL_OK=0
        continue
    fi

    # R3 -- 데드라인 가드: case 마다 남은 시간을 새로 잰다(값싼 뒤 case 가 비싼 앞 case 자리에
    # 들어갈 수 있으므로, 하나가 안 맞아도 루프를 끝까지 돈다).
    NOW=$(date +%s)
    ELAPSED=$(( NOW - START_TIME ))
    REMAINING=$(( DEADLINE_SECONDS - ELAPSED ))
    if [ "$REMAINING" -lt "$EST_COST" ]; then
        emit_status "$CASE" "skipped" "$CUR_ROWS" 0
        SUMMARY_CASES+=("$CASE"); SUMMARY_STATUS+=("skipped"); SUMMARY_ROWS+=("$CUR_ROWS")
        continue
    fi

    echo "=== [$CASE] 시작 (est=${EST_COST}s, remaining=${REMAINING}s) ==="
    LOG_FILE="$LOG_DIR/4pol_$CASE.log"
    T0=$(date +%s)
    set +e
    "$PY" llm_ood_eval.py run \
        --seeds "$SEEDS" \
        --policies "$POLICIES" \
        --out "$OUT_FILE" \
        --case "$CASE" \
        --dspy-url "$DSPY_URL" \
        --router 0 \
        > "$LOG_FILE" 2>&1
    RC=$?
    set -e
    T1=$(date +%s)
    WALL=$(( T1 - T0 ))

    ROWS=$(count_rows "$OUT_FILE")
    if [ "$RC" -ne 0 ] || [ "$ROWS" -lt "$EXPECTED_ROWS" ]; then
        emit_status "$CASE" "fail" "$ROWS" "$WALL"
        SUMMARY_CASES+=("$CASE"); SUMMARY_STATUS+=("fail"); SUMMARY_ROWS+=("$ROWS")
        ALL_OK=0
    else
        emit_status "$CASE" "ok" "$ROWS" "$WALL"
        SUMMARY_CASES+=("$CASE"); SUMMARY_STATUS+=("ok"); SUMMARY_ROWS+=("$ROWS")
    fi
done

# =========================================================================
# R7 -- 최종 요약
# =========================================================================
echo ""
echo "===== run_4pol.sh SUMMARY ====="
for i in "${!SUMMARY_CASES[@]}"; do
    printf '  %-14s %-8s rows=%s\n' "${SUMMARY_CASES[$i]}" "${SUMMARY_STATUS[$i]}" "${SUMMARY_ROWS[$i]}"
done
echo "================================"

if [ "$ALL_OK" -eq 1 ]; then
    echo "ALL non-skipped cases ok."
    exit 0
else
    echo "One or more non-skipped cases did not end 'ok' -- see status_4pol.jsonl."
    exit 1
fi
