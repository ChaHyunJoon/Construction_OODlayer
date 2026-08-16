#!/usr/bin/env bash
# =============================================================================
# gate_courier_sweep.sh -- SwapBattery 배송 세대 재스윕 **직전** 게이트 4종.
# 넷 다 "조용히 실패" 하는 종류라, 630 판을 돌린 뒤에 알게 되면 2시간을 버린다.
#   G1 배송이 스윕 엔진에서 실제로 켜지고 발화하는가 (이름만 새 세대인 판 방지)
#   G2 창고 예비가 고장 대상에서 빠지는가 (_faultable 회귀)
#   G3 DSPy 서비스가 떠 있는가 (없으면 dspy/surrogate 가 canonical 로 조용히 폴백)
#   G4 objective_hash 가 현행인가
# 사용: bash gate_courier_sweep.sh
#
# ⚠️ 2026-08-15 실측 정정 (Task 2): G2 는 원안대로 stdout 을 그렙하면 **항상 무증상 통과한다**.
#    "Robot R{n} has broken down..." 텍스트는 `fault_robot!`(ood_injection.jl:1099)가 만들어
#    `record_ood_truth!` → `monitor_record_respec!` 로 흘러가는데, 그 함수(monitor.jl:354)는
#    **메모리에만** 쌓고 아무것도 출력하지 않는다 — stdout 에도, `@info`/`@warn` 로그에도 안 찍힌다.
#    실제로 그 문자열이 나타나는 곳은 `MONITOR_STREAM` 이 여는 JSONL 스트림 파일뿐이다
#    (monitor.jl:492 `"respec" => MONITOR_RESPEC[]`가 프레임마다 그 딕셔너리를 실어 보낸다 —
#    실측 확인: g2probe_stream.jsonl 에 `"detail":"Robot R1 has broken down at ..."` 가 찍혔다).
#    그래서 G2 는 MONITOR_STREAM 을 이 스크립트가 쥔 임시 파일로 명시적으로 돌려 그 파일을 그렙한다.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
cd "$REPO"
PY="$REPO/.venv/bin/python"
DSPY_URL="${DSPY_URL:-http://127.0.0.1:8090}"
fail=0

echo "== G1: 스윕 엔진(run_demo.jl)에서 SwapBattery 가 배송으로 집행되는가 =="
# DEMO_FORCE_MACRO 로 배터리 사건의 팔을 SwapBattery 로 못박는다(policy.jl:664).
# 그러지 않으면 시드에 따라 Replace 가 뽑혀 이 게이트가 아무것도 검사하지 못한다.
#
# 세 grep 이 각각 무엇을 검사하는지(2026-08-15 실측, file:line):
#   1) "courier=true"                  -- run_demo.jl:620 println. DEMO_BATTERY_COURIER
#      (기본 "1")가 꺼져 있으면 "courier=false" 가 찍혀 이 grep 이 실패한다.
#   2) "swap=battery_courier_dispatched" -- run_demo.jl:379 println("[battery] swap=$(sw.status) ...").
#      sw 는 CB.swap_battery!(replace_robot.jl:1419)의 반환값. 창고에 배송 가능한 예비가 있으면
#      dispatch_battery_courier!(battery_courier.jl:167)가 :battery_courier_dispatched 를 돌려주고
#      (replace_robot.jl:1434), 심볼 보간은 콜론 없이 "battery_courier_dispatched" 그대로 찍힌다
#      (Julia println 이 Symbol 을 print() 로 쓰기 때문 — 실측 확인).
#      **예비가 하나도 없으면** swap_battery!(replace_robot.jl:1429-1439)가 즉시 교체 폴백으로
#      떨어져 _apply_battery_swap!(:1461)의 :battery_swapped 가 대신 찍힌다 — 그러면 이 grep 은
#      실패하고, 그것이 "이름만 새 세대, 동작은 구세대" 판을 잡는 지점이다.
#   3) "PROJECT COMPLETE"               -- run_demo.jl:828 println(">>> PROJECT COMPLETE @ step ...").
#      max_steps 안에 안 끝나면(run_demo.jl:835 "reached max_steps") 안 찍힌다.
G1LOG=$(mktemp)
DEMO_MODEL=tractor.mpd DEMO_OOD=battery DEMO_SEED=1 DEMO_OOD_SEED=3 DEMO_N=2 \
DEMO_POLICY=canonical DEMO_FORCE_MACRO=SwapBattery DEMO_BSOC=0.9 \
CARRIER_RESCUE=1 RELOCATE_GATE=1 \
  julia +lts --project=. --startup-file=no tools/monitor/run_demo.jl > "$G1LOG" 2>&1
grep -aq 'courier=true' "$G1LOG"                       || { echo "  !! courier 가 꺼진 채로 돈다"; fail=1; }
grep -aq 'swap=battery_courier_dispatched' "$G1LOG"    || { echo "  !! SwapBattery 가 배송으로 안 갔다(즉시 교체 폴백?)"; fail=1; }
# 위 grep 이 실패했을 때 "왜"를 이름으로 남긴다: 폴백 경로는 @warn 을 낸다(replace_robot.jl:1437-1438).
# 전역 로거가 Warn 이상만 통과시키므로(run_demo.jl:554) 이 문자열은 stdout+stderr 캡처에 실제로 남는다.
grep -aq 'no depot spare free to deliver a battery' "$G1LOG" \
  && { echo "  !! 배송 예비가 없어 즉시 교체로 폴백했다 — 창고 예비 재고를 늘리거나 DEMO_SPARES 를 확인할 것"; fail=1; }
grep -aq 'PROJECT COMPLETE' "$G1LOG"                   || { echo "  !! 이 판이 완주하지 않았다"; fail=1; }
[ "$fail" -eq 0 ] && echo "  OK  ($G1LOG)"

echo "== G2: 창고 예비가 고장 대상에서 빠지는가 =="
# 예비 id 는 실제 로봇 수보다 크다(tractor: 실로봇 1..10, 예비 11..18).
#   실측 확인(project_params.jl:63 num_robots=10; full_demo.jl:457 add_robots_to_scene! 이 먼저
#   1..10 을 발급하고, :464 add_directional_spare_pools! 가 그 뒤에 get_unique_id(RobotID) 로
#   예비를 이어서 발급한다; DEMO_SPARES 기본값 2 × 4방위 = 8대 → 11..18). 브리핑의 수치가 맞다.
# fault 판을 하나 돌려 고장 대상 id 가 예비 대역에 들어오면 회귀다.
#
# ⚠️ 이 grep 은 G1LOG(stdout)이 아니라 별도 MONITOR_STREAM 파일을 본다 — 위 헤더의 실측 정정 참고.
G2LOG=$(mktemp)
G2STREAM=$(mktemp --suffix=.jsonl)
MONITOR_STREAM="$G2STREAM" \
DEMO_MODEL=tractor.mpd DEMO_OOD=fault DEMO_SEED=1 DEMO_OOD_SEED=10 DEMO_N=2 \
DEMO_POLICY=canonical CARRIER_RESCUE=1 RELOCATE_GATE=1 \
  julia +lts --project=. --startup-file=no tools/monitor/run_demo.jl > "$G2LOG" 2>&1
n_faults=$(grep -acE 'Robot R[0-9]+ has broken down' "$G2STREAM")
if [ "${n_faults:-0}" -eq 0 ]; then
  # 고장 사건이 하나도 안 잡혔으면 이 게이트는 아무것도 검사한 게 아니다 — 통과가 아니라 실패로 취급한다
  # (grep 이 아무 것도 못 찾아 무증상 통과하는 바로 그 함정을 여기서도 피한다).
  echo "  !! 고장 사건이 하나도 안 잡혔다 — 게이트가 무의미하다(스트림: $G2STREAM, 로그: $G2LOG)"; fail=1
elif grep -aoE 'Robot R[0-9]+ has broken down' "$G2STREAM" | grep -oE '[0-9]+' \
     | awk '$1 > 10 {print; found=1} END {exit !found}' >/dev/null; then
  echo "  !! 예비 로봇(id>10)이 고장 대상으로 뽑혔다 — _faultable 회귀"; fail=1
else
  echo "  OK  ($n_faults 건 · $G2STREAM)"
fi

echo "== G3: DSPy 서비스 =="
if curl -s --max-time 5 "$DSPY_URL/health" | grep -q '"status":"ok"'; then
  echo "  OK  $DSPY_URL"
else
  echo "  !! $DSPY_URL 응답 없음 — dspy/surrogate 가 canonical 로 조용히 폴백한다"; fail=1
fi

echo "== G4: objective_hash =="
"$PY" wm4spacecraft_manufacturing/audit_objective.py >/dev/null 2>&1 \
  && echo "  OK" || { echo "  !! audit_objective.py 실패"; fail=1; }

echo
[ "$fail" -eq 0 ] && echo "GATES PASS — 스윕 시작 가능" || echo "GATES FAIL — 스윕을 시작하지 말 것"
exit "$fail"
