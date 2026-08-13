#!/usr/bin/env bash
# =============================================================================
# gate_prereq.sh -- 병렬 스윕의 사전 조건 게이트.
#
# run_4pol.sh 의 P1~P6 을 계승하되 병렬 전제에 맞춰 고쳤다:
#   · P5 (pgrep julia 없어야 함) 는 **제거**했다. 병렬이 전제이므로 성립할 수 없고, 동시 실행
#     수는 스케줄러(xargs -P)가 보장한다.
#   · P6 (결과 디렉토리 청결) 은 샤드 단위 재개 판정으로 옮겼다(run_shard.sh).
#   · P8 (LLM 동시성) 을 새로 넣었다.
#
# 사용법:  bash gate_prereq.sh [JOBS]     (JOBS 기본 16)
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PY="$REPO/.venv/bin/python"
DSPY_URL="${DSPY_URL:-http://127.0.0.1:8090}"
JOBS="${1:-16}"
NIGHT_DIR="$HERE/_night"

cd "$HERE"
mkdir -p "$NIGHT_DIR"

echo "=== 사전 조건 게이트 (DSPY_URL=$DSPY_URL, JOBS=$JOBS) ==="

# ---- P1 살아있는 LLM 프로브 --------------------------------------------
P1_BODY='{"kind":"battery","severity":0.6,"soc":0.12,"spare_count":2,"agent_pending":1,"progress":0.4,"n_active":4,"nl":"A transport robot reports state of charge 12 percent while carrying an assembly."}'
P1_RESP=$(curl -s -w '\n%{http_code}' -X POST "$DSPY_URL/macro" \
    -H 'Content-Type: application/json' -d "$P1_BODY" 2>/dev/null)
P1_RC=$?
if [ $P1_RC -ne 0 ] || [ -z "$P1_RESP" ]; then
    echo "PREREQ FAIL: P1 -- curl 이 $DSPY_URL/macro 에 닿지 못했다 (rc=$P1_RC)"
    echo "  서비스를 띄웠는가?  cd $REPO/src/respec/llm_service && $PY -m uvicorn dspy_service:app --host 127.0.0.1 --port 8090"
    exit 1
fi
P1_CODE=$(printf '%s' "$P1_RESP" | tail -n1)
P1_BODY_OUT=$(printf '%s' "$P1_RESP" | sed '$d')
if [ "$P1_CODE" != "200" ]; then
    echo "PREREQ FAIL: P1 -- http_code=$P1_CODE"
    exit 1
fi
P1_OK=$(printf '%s' "$P1_BODY_OUT" | "$PY" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("0"); sys.exit(0)
pol = d.get("policy") or ""
print("1" if (d.get("error") is None and isinstance(pol, str) and pol.startswith("dspy")) else "0")
' 2>/dev/null || echo "0")
if [ "$P1_OK" != "1" ]; then
    echo "PREREQ FAIL: P1 -- error:null 이면서 policy 가 'dspy' 로 시작해야 한다: $P1_BODY_OUT"
    exit 1
fi
echo "[gate] P1 OK (살아있는 LLM 프로브)"

# ---- P2 health + 프로그램 신원 기록 -------------------------------------
# dspy_service.py:90 은 DSPY_PROGRAM 이 비면 컴파일된 gpt4o 프로그램으로 조용히 폴백한다.
# 그건 battery 전용 어휘라 zone 을 재면 어휘 밖을 재게 된다. 어느 프로그램이었는지 남기지
# 않으면 사후에 알 방법이 없다.
P2_RESP=$(curl -s -w '\n%{http_code}' "$DSPY_URL/health" 2>/dev/null)
P2_CODE=$(printf '%s' "$P2_RESP" | tail -n1)
P2_BODY=$(printf '%s' "$P2_RESP" | sed '$d')
if [ "$P2_CODE" != "200" ]; then
    echo "PREREQ FAIL: P2 -- http_code=$P2_CODE"
    exit 1
fi
printf '%s\n' "$P2_BODY" > "$NIGHT_DIR/provenance_4pol.json"
DSPY_PROGRAM=$(printf '%s' "$P2_BODY" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("program","?"))' 2>/dev/null || echo "?")
echo "[gate] P2 OK (health) -- program=$DSPY_PROGRAM"

# ---- P9 surrogate 레인이 실제로 로드됐는가 -------------------------------
# 2026-08-12: dspy 3.3.0 의 lazy numpy 프록시가 sklearn 경유로 재진입하면 _load_surrogate() 가
# 예외를 삼켜서 서비스는 정상 기동하고 P1/P2 도 통과하지만, surrogate 는 조용히 미로드 상태로
# 남는다. 그러면 policy.jl 이 surrogate 정책을 canonical 로 폴백시키는데, summary 에는 여전히
# policy="surrogate" 로 찍혀 회귀를 알아챌 수 없다. P2 와 같은 health 응답을 다시 확인해
# surrogate 필드가 비어있거나 "ERROR"로 시작하면 여기서 막는다.
P9_RESP=$(curl -s -w '\n%{http_code}' "$DSPY_URL/health" 2>/dev/null)
P9_CODE=$(printf '%s' "$P9_RESP" | tail -n1)
P9_BODY=$(printf '%s' "$P9_RESP" | sed '$d')
if [ "$P9_CODE" != "200" ]; then
    echo "PREREQ FAIL: P9 -- http_code=$P9_CODE"
    exit 1
fi
P9_SURRO=$(printf '%s' "$P9_BODY" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("surrogate") or "")' 2>/dev/null || echo "")
if [ -z "$P9_SURRO" ] || [ "${P9_SURRO#ERROR}" != "$P9_SURRO" ]; then
    echo "PREREQ FAIL: P9 -- surrogate 미로드/에러: $P9_SURRO"
    exit 1
fi
echo "[gate] P9 OK (surrogate=$P9_SURRO)"

# ---- P3 행동 어휘 감사 --------------------------------------------------
if ! "$PY" audit_action_vocab.py; then
    echo "PREREQ FAIL: P3 (audit_action_vocab.py)"
    exit 1
fi
echo "[gate] P3 OK (audit_action_vocab.py)"

# ---- P4 surrogate 지원 집합 계약 ----------------------------------------
if ! "$PY" test_surrogate_support.py; then
    echo "PREREQ FAIL: P4 (test_surrogate_support.py)"
    exit 1
fi
echo "[gate] P4 OK (test_surrogate_support.py)"

# ---- P8 LLM 동시성 ------------------------------------------------------
if ! "$PY" gate_llm_concurrency.py --url "$DSPY_URL" --jobs "$JOBS"; then
    echo "PREREQ FAIL: P8 (동시 $JOBS 요청)"
    exit 1
fi
echo "[gate] P8 OK (동시 $JOBS 요청)"

echo "=== 게이트 전부 통과 (program=$DSPY_PROGRAM) ==="
exit 0
