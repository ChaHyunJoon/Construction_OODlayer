#!/usr/bin/env bash
# =============================================================================
# run_zcausal_rest.sh -- STEP 10 의 나머지 팔 + STEP 11 을 2레인으로 이어 돌린다.
#
# 왜 팔마다 프로세스를 새로 띄우나: RVO 시뮬레이터와 그 id 맵이 **전역**이라, 한 프로세스에서
# 두 팔을 돌리면 두 번째 팔이 첫 팔이 남긴 모션 상태 위에서 시작한다 = 비교가 허구가 된다.
# 왜 2레인인가: julia 프로세스 하나가 ~1.1GB 를 쓰고 이 기계의 여유가 그 정도다(측정).
# =============================================================================
set -u
cd "$(dirname "$0")/../.." || exit 1          # repo root (ConstructionBots.jl)
OUT=wm4spacecraft_manufacturing/oracle/out/zcausal
mkdir -p "$OUT"

# 현재 돌고 있는 julia 가 다 끝날 때까지 기다린다(레인 확보).
wait_for_free_lanes() {
    while [ "$(tasklist //FI 'IMAGENAME eq julia.exe' 2>/dev/null | grep -c julia.exe)" -gt 0 ]; do
        sleep 20
    done
}

run_arm() {   # $1 = arm 이름
    ZC_ARM="$1" ZC_OUT="$OUT/$1.json" \
        julia +lts --project=. tools/restage.jl causal > "$OUT/$1.log" 2>&1
    echo "[done] $1 rc=$?"
}

wait_for_free_lanes
echo "[lane] free -> blk_reloc + cov_reloc"
run_arm blk_reloc &
run_arm cov_reloc &
wait

echo "[lane] free -> control + STEP 11 (zone_team_causal)"
run_arm control &
julia +lts --project=. tools/tests.jl zone_team_causal > "$OUT/team_causal.log" 2>&1 &
wait

echo "===== RESULT lines ====="
grep -h "^RESULT" "$OUT"/*.log 2>/dev/null
echo "===== STEP 11 ====="
tr '\r' '\n' < "$OUT/team_causal.log" | grep -E "PASS|FAIL|ALL GREEN|SOME FAILED|->" | tail -25
