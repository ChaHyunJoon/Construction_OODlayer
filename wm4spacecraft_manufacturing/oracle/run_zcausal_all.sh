#!/usr/bin/env bash
# =============================================================================
# run_zcausal_all.sh -- STEP 10 본 실행: **복구 사다리(reform) ON** 으로 7개 팔 전부.
#
# 왜 다시 도는가: reform 없이 돌린 1차 측정에서 네 팔이 전부 closed 254~258 에서 멈췄다.
# 이 트윈의 완주 실패는 언제나 루트 엔드게임에서 나므로(그래서 데모가 DEMO_REFORM 을 켠다),
# 복구가 없으면 구역의 효과가 그 교착에 통째로 가려진다. 이번엔 모든 팔에 같은 사다리를 건다.
# 1차(무복구) 결과는 out/zcausal/ 에 그대로 둔다 — 그것도 하나의 발견이다.
#
# 가족 3종 × {NOOP, RelocateBuild} + control:
#   blk_*      구역이 nav 목표 위 (막힘 > 0, 커버리지 0)   <- 커버리지 규칙이 못 보는 사건
#   cov_*      core zone (커버리지 8/8, 막힘 작음)
#   harmless_* 운동학 목표 위 (커버리지 > 0, 막힘 = 0)     <- 두 규칙이 정반대로 답하는 사건
# =============================================================================
set -u
cd "$(dirname "$0")/../.." || exit 1
OUT=wm4spacecraft_manufacturing/oracle/out/zcausal_reform
mkdir -p "$OUT"

wait_for_free_lanes() {
    while [ "$(tasklist //FI 'IMAGENAME eq julia.exe' 2>/dev/null | grep -c julia.exe)" -gt 0 ]; do
        sleep 20
    done
}

run_arm() {
    [ -s "$OUT/$1.json" ] && { echo "[skip] $1"; return; }      # 재개 안전
    ZC_ARM="$1" ZC_OUT="$OUT/$1.json" ZC_REFORM=400 ZC_REFORM_MAX=3 \
        julia +lts --project=. tools/restage.jl causal > "$OUT/$1.log" 2>&1
    echo "[done] $1 -> $(grep -h '^RESULT' "$OUT/$1.log" 2>/dev/null | tail -1)"
}

wait_for_free_lanes
for pair in "control blk_noop" "blk_reloc cov_noop" "cov_reloc harmless_noop" "harmless_reloc"; do
    for a in $pair; do run_arm "$a" & done
    wait
done

echo "===== ALL RESULTS ====="
grep -h "^RESULT" "$OUT"/*.log 2>/dev/null
