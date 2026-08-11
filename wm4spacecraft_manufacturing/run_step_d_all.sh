#!/usr/bin/env bash
# =============================================================================
# run_step_d_all.sh -- STEP D 두 축(fault=firegrid, zone=zcausal)을 한 번에, 순차로.
#
# 왜 한 스크립트인가: 두 러너 다 julia 를 직접 띄운다. 따로 돌리다 겹치면 HiGHS 가 다른
# 스케줄을 내 라벨 자체가 오염된다(README 함정 30). 여기서 순서를 강제한다.
#
# 두 축은 서로 독립이므로 한쪽이 죽어도 다른 쪽은 돈다 -- 대신 마지막에 어느 쪽이 죽었는지
# 반드시 찍고 non-zero 로 나간다(조용한 부분성공 금지).
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
cd "$REPO" || exit 1

PY="$REPO/.venv/bin/python"
FIRE_RC=0
ZC_RC=0

echo "===== STEP D part 1/2: firegrid (fault 축) ====="
bash "$HERE/oracle/run_step_d_firegrid.sh"
FIRE_RC=$?
echo "[driver] firegrid rc=$FIRE_RC"

echo ""
echo "===== STEP D part 2/2: zcausal (zone 축) ====="
bash "$HERE/oracle/run_step_d_zcausal.sh"
ZC_RC=$?
echo "[driver] zcausal rc=$ZC_RC"

echo ""
echo "===== STEP D 산출물 확인 ====="
FM="$HERE/oracle/out/firegrid_merged.jsonl"
if [ -s "$FM" ]; then
    echo "  firegrid_merged.jsonl: $(wc -l < "$FM" | tr -d ' ') rows"
else
    echo "  firegrid_merged.jsonl: 없음/비어있음"
fi
ZD="$HERE/oracle/out/zcausal_reform"
echo "  zcausal_reform/: $(ls -1 "$ZD" 2>/dev/null | wc -l | tr -d ' ') files"
ls -1 "$ZD" 2>/dev/null | sed 's/^/    /'

echo ""
echo "===== 게이트 재검사: test_llm7h.py ====="
# 이 게이트가 원래 fault 축에서 FileNotFoundError 로 죽고 zone 축은 n=0 으로 조용히 통과했다.
# STEP D 의 목적이 정확히 이 두 줄을 실측으로 바꾸는 것이다.
cd "$HERE" && "$PY" test_llm7h.py
GATE_RC=$?
echo "[driver] test_llm7h.py rc=$GATE_RC"

echo ""
echo "STATUS stepD_all firegrid=$FIRE_RC zcausal=$ZC_RC gate=$GATE_RC"
if [ "$FIRE_RC" -ne 0 ] || [ "$ZC_RC" -ne 0 ]; then
    exit 1
fi
exit 0
