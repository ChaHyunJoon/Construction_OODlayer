#!/usr/bin/env bash
# =============================================================================
# svc_supervisor.sh -- DSPy 서비스를 스윕 내내 **살아 있게** 유지한다. (Task 7, 2026-08-14)
#
# 왜: 스윕 중간에 서비스가 죽으면 policy.jl 이 조용히 canonical 로 폴백하고, 요약 행에는
# 여전히 policy="surrogate" 로 찍힌다 -- 판이 조용히 무효가 된다(CLAUDE.md: dspy 3.3.0 의
# numpy lazy-proxy import 순서 버그로 실제로 일어났던 사고). 그래서 죽으면 되살리고,
# **되살렸다는 사실을 반드시 로그에 남긴다**. 기록 없는 재시작은 나중에 설명 불가한 결과가 된다.
#
# 사용:  PORT=8091 bash _night/svc_supervisor.sh &
# 정지:  touch _night/.svc_stop   (또는 kill 이 스크립트)
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PY="$REPO/.venv/bin/python"
SVC_DIR="$REPO/src/respec/llm_service"
PORT="${PORT:-8091}"
NIGHT="$HERE/_night"
LOG="$NIGHT/svc_supervisor.log"
UVLOG="$NIGHT/svc_uvicorn.log"
STOP="$NIGHT/.svc_stop"
INTERVAL="${INTERVAL:-30}"

mkdir -p "$NIGHT"
rm -f "$STOP"

log() { printf '%s %s\n' "$(date -Iseconds)" "$*" >> "$LOG"; }

healthy() {
    local body
    body=$(curl -s --max-time 10 "http://127.0.0.1:$PORT/health" 2>/dev/null) || return 1
    [ -n "$body" ] || return 1
    printf '%s' "$body" | "$PY" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
s = d.get("surrogate") or ""
# surrogate 가 미로드/에러면 "살아 있다"로 치지 않는다 -- 그 상태로 스윕이 돌면 레인이 조용히
# canonical 로 폴백한다. 여기서 죽은 것으로 판정해 재기동시킨다.
sys.exit(0 if (d.get("status") == "ok" and s and not s.startswith("ERROR")) else 1)
' >/dev/null 2>&1
}

start_svc() {
    # DSPY_PROGRAM=__seed_only__ 는 **계약**이다(CLAUDE.md Gotchas). 컴파일된
    # dspy_real_program_gpt4o.json 은 battery 전용이라 zone·RelocateBuild 어휘가 없어서,
    # 그걸로 스윕을 돌리면 zone case 는 어휘 밖 사건을 재게 된다. 직전 스윕의 provenance 도
    # program="(seed only)" 였다 -- 여기서 갈리면 dspy 레인의 old/new 비교가 무효가 된다.
    #
    # `exec` 가 중요하다(2026-08-14 실측 버그): 없으면 백그라운드 서브셸이 python 의 **부모**로
    # 남아 `$!` 가 그 껍데기 PID 를 기록한다. 그 PID 를 kill 해도 python 은 init 으로 재부모화돼
    # 포트를 계속 쥐고, 감시기는 "죽였는데 살아 있다"를 보게 된다. exec 로 서브셸을 python 으로
    # **치환**하면 $! 가 곧 포트 소유자다.
    ( cd "$SVC_DIR" && \
      exec env OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 \
        DSPY_PROGRAM="${DSPY_PROGRAM:-__seed_only__}" \
        "$PY" -m uvicorn dspy_service:app --host 127.0.0.1 --port "$PORT" \
        >> "$UVLOG" 2>&1 ) &
    echo $! > "$NIGHT/.svc_pid"
    log "START uvicorn port=$PORT pid=$(cat "$NIGHT/.svc_pid" 2>/dev/null)"
}

restarts=0
if ! healthy; then
    log "INIT: 서비스가 없다 -> 기동"
    start_svc
else
    log "INIT: 이미 건강한 서비스가 포트 $PORT 에 있다"
fi

# 최초 기동 대기 (모델 적합 포함, 넉넉히 180s)
for _ in $(seq 1 60); do
    healthy && break
    sleep 3
done
if healthy; then
    log "INIT OK: $(curl -s --max-time 10 "http://127.0.0.1:$PORT/health")"
else
    log "INIT FAIL: 180s 안에 health 가 오지 않았다 -- $UVLOG 를 볼 것"
fi

while [ ! -f "$STOP" ]; do
    sleep "$INTERVAL"
    [ -f "$STOP" ] && break
    if ! healthy; then
        restarts=$((restarts + 1))
        log "DEAD (health 실패) -> 재기동 #$restarts"
        pkill -f "uvicorn dspy_service:app --host 127.0.0.1 --port $PORT" 2>/dev/null
        sleep 2
        start_svc
        for _ in $(seq 1 60); do healthy && break; sleep 3; done
        if healthy; then
            log "RESTART OK #$restarts: $(curl -s --max-time 10 "http://127.0.0.1:$PORT/health")"
        else
            log "RESTART FAIL #$restarts -- 스윕 결과를 신뢰하지 말 것"
        fi
    fi
done
log "STOP 요청 -- 감시 종료 (재시작 총 $restarts 회)"
