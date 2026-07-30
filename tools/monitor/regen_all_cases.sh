#!/usr/bin/env bash
# 모든 데모 케이스를 render_demo.jl 로 재생성한다 = 스트림(세 정책 기록) + MeshCat 애니메이션.
#
# 왜 전부 다시 만드는가: 기존 ①~⑥ 스트림은 run_demo.jl(정책 기록 O, 애니메이션 X) 또는 07-22 구버전으로
# 만들어져 policies/enacted 필드가 없다. 이제 두 엔진이 policy.jl 을 공유하므로 render_demo 로 한 번에
# 둘 다 얻는다. 기존 산출물은 _backup_2026-07-28/ 에 백업되어 있다.
#
# **순차 실행이어야 한다**: 렌더가 MeshCat(포트 8700)을 쓰므로 동시에 두 개를 돌리면 충돌한다.
#
# 사전조건: DSPy 서비스(:8077)가 떠 있어야 surrogate/dspy 결정이 기록된다. 없으면 canonical 로 폴백되고
#           그 사실이 verdict 에 남는다(조용히 규칙 결과가 LLM 결과로 둔갑하지 않음).
#
# Usage: bash tools/monitor/regen_all_cases.sh [case ...]     (인자 없으면 전체)
set -u
cd "$(dirname "$0")/../.."                      # ConstructionBots.jl
LOGD=tools/monitor/regen_case_logs; mkdir -p "$LOGD"
POLICY="${DEMO_POLICY:-dspy}"                   # 실행(enact)할 정책. 세 정책의 판단은 어차피 모두 기록된다.

curl -s --max-time 5 http://127.0.0.1:8077/health >/dev/null \
  || echo "!! DSPy service (:8077) not reachable — runs will fall back to canonical"

run_case() {                                    # $1=케이스 키  $2..=추가 env
  local case="$1"; shift
  echo "== $case ($(date +%H:%M:%S)) =="
  env DEMO_MODEL=tractor.mpd DEMO_OOD="$case" DEMO_POLICY="$POLICY" "$@" \
    julia +lts --project=. tools/monitor/render_demo.jl > "$LOGD/$case.log" 2>&1
  local rc=$?
  local done_line
  done_line=$(tr '\r' '\n' < "$LOGD/$case.log" | grep -aE "PROJECT (COMPLETE|INCOMPLETE)|\[policy\]" | tail -3)
  echo "   exit=$rc"; echo "$done_line" | sed 's/^/   /'
}

CASES=("$@")
[ ${#CASES[@]} -eq 0 ] && CASES=(none battery fault zone fault_battery fault_zone battery_zone)

for c in "${CASES[@]}"; do run_case "$c"; done

# ⑦ 애매한 배터리(SoC≈0.55): 정책마다 **실행 결과 자체가 다르므로** 두 번 렌더해 나란히 비교한다.
#   dspy   → NOOP        (개입 없음: 정말 완주하는지 눈으로 확인)
#   rule   → Deprioritize(rebalance_for_battery! 로 장거리·중량 작업을 실제로 덜어내는지 확인)
for pol in dspy canonical; do
  echo "== battery_mild ($pol) ($(date +%H:%M:%S)) =="
  env DEMO_MODEL=tractor.mpd DEMO_OOD=battery DEMO_BSOC=0.45 DEMO_POLICY="$pol" \
    julia +lts --project=. tools/monitor/render_demo.jl > "$LOGD/battery_mild_$pol.log" 2>&1
  echo "   exit=$?"
  tr '\r' '\n' < "$LOGD/battery_mild_$pol.log" | grep -aE "PROJECT (COMPLETE|INCOMPLETE)|\[policy\]" | tail -2 | sed 's/^/   /'
  suffix=$([ "$pol" = "dspy" ] && echo "battery_mild" || echo "battery_mild_rule")
  mv -f tools/monitor/streams/tractor__battery.jsonl "tools/monitor/streams/tractor__${suffix}.jsonl" 2>/dev/null
  mv -f tools/monitor/anim/tractor__battery.html     "tools/monitor/anim/tractor__${suffix}.html"     2>/dev/null
done

# 위 루프가 plain battery 산출물을 소비했으므로 마지막에 원래 battery 케이스를 복원한다.
echo "== battery (restore severe case) ($(date +%H:%M:%S)) =="
env DEMO_MODEL=tractor.mpd DEMO_OOD=battery DEMO_POLICY="$POLICY" \
  julia +lts --project=. tools/monitor/render_demo.jl > "$LOGD/battery_restore.log" 2>&1
echo "   exit=$?"

echo "ALL CASES DONE ($(date +%H:%M:%S))"
ls -la tools/monitor/streams/tractor__*.jsonl | awk '{print $5, $NF}'
