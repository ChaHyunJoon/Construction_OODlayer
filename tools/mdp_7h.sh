#!/usr/bin/env bash
# =============================================================================
# mdp_7h.sh — 7시간 무인 파이프라인 (2026-08-02)
#
# PHASE 1  STEP 6 재실행 (노이즈 대조군 + K=4)      ~2.5h, 2병렬
# PHASE 2  φ 확장(X_C 커밋먼트 블록) 에피소드 재생성  ~2.5h, 2병렬
#          — φ 코드가 준비됐다는 표시(PHI_READY)를 기다렸다가, 1인스턴스 스모크로
#            새 컬럼이 실제로 나오는지 확인한 뒤에만 대량 생성으로 넘어간다.
# PHASE 3  분석(T1/T2/Router) + STEP 6 gap 집계 + 리포트
#
# 운영 규칙(지난 사고에서 얻은 것):
#   · 병렬 2개 상한(프로세스당 ~2.5GB, 여유 5.8GB)
#   · 스크립트명으로 프로세스를 죽이는 감시기 금지
#   · 인라인 python 은 PYTHONIOENCODING=utf-8
#   · 실패해도 다음 단계로 (set -e 안 씀)
# =============================================================================
cd "$(dirname "$0")/.." || exit 1
REPO="$PWD"; WM="$REPO/wm4spacecraft_manufacturing"; OUT="$WM/artifacts_mdp"
LOG="$OUT/mdp_7h.log"; mkdir -p "$OUT" "$WM/oracle/out"
export PYTHONIOENCODING=utf-8

say () { echo "[$(date '+%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }
say "=== mdp_7h 파이프라인 시작 ==="

# ---------------------------------------------------------------------------
# PHASE 1 — STEP 6 재실행
#   arms: 0 NOOP / 1 Replace(macro) / 10 Replace@0 / 11 Replace@5 / 12 Replace@15
#         20 Deprio×10 / 21 Deprio×50 / 22 Deprio×200
#   ** 10 은 정의상 macro 1 과 동일한 행동 → 노이즈 대조군(noise floor) **
#      1 과 10 의 Q̂ 차이는 "실제 gap 0" 인 쌍에서 측정되는 몬테카를로 노이즈다.
#      확장 arm 의 gap 이 이 노이즈 바닥을 넘지 못하면 gap 은 없는 것이다.
#   K=4, seed 1..3, shard 태그 s6b (구 K=2 데이터 s6_* 는 건드리지 않는다)
# ---------------------------------------------------------------------------
S6DIR="$OUT/step6b"; mkdir -p "$S6DIR"
mkunits () {  # $1 = arm 목록(공백구분), $2 = K
  local s=""; for a in $1; do for k in $(seq 1 "$2"); do s="${s}${a}:${k},"; done; done; echo "${s%,}"
}
K6=4
HALF_A="0 1 10 11"
HALF_B="12 20 21 22"
say "PHASE 1) STEP 6 재실행: seed 1-3 × 8 arm × K=$K6 = $((3*8*K6)) sims, 2병렬"

JOBS=()
for s in 1 2 3; do
  JOBS+=("$s|A|$(mkunits "$HALF_A" $K6)")
  JOBS+=("$s|B|$(mkunits "$HALF_B" $K6)")
done

i=0
while [ $i -lt ${#JOBS[@]} ]; do
  for slot in 1 2; do
    [ $i -ge ${#JOBS[@]} ] && break
    IFS='|' read -r S H U <<< "${JOBS[$i]}"
    ( MC_BATCH="$U" MC_SHARD="s6b_${H}" ORACLE_SEED="$S" MC_SEED0=3000 MC_K=$K6 \
      NSPARE=3 MC_REFERENCE=0 HOT_SWAP=1 NOPROG=6000 MC_STACK=1000000000 \
      julia +lts --project=. "$WM/oracle/gen_oracle_mc.jl" > "$S6DIR/s${S}_${H}.log" 2>&1
      echo "$(date '+%H:%M:%S') STEP6 seed=$S half=$H rc=$?" >> "$LOG" ) &
    i=$((i+1))
  done
  wait
  say "   STEP 6 진행: $i/${#JOBS[@]} job 완료"
done
say "PHASE 1 완료."

# ---------------------------------------------------------------------------
# PHASE 2 — φ 확장 에피소드 재생성
# ---------------------------------------------------------------------------
say "PHASE 2) φ 확장 대기 (PHI_READY, 최대 100분)"
W=0
while [ ! -f "$OUT/PHI_READY" ] && [ $W -lt 6000 ]; do sleep 30; W=$((W+30)); done

if [ ! -f "$OUT/PHI_READY" ]; then
  say "   PHI_READY 없음 → φ 확장 건너뜀. 기존 φ 로 에피소드만 추가 생성."
  PHI_TAG="old"
else
  say "   PHI_READY 확인. 1인스턴스 스모크로 새 컬럼 검증."
  rm -f "$WM/oracle/out/phi_smoke.jsonl"
  ( DS_EPISODE_N=2 DS_SEEDS="101" DS_MC_K=1 DS_VALID_ONLY=1 DS_HOTSWAP=1 \
    DS_EP_LO=70 DS_EP_HI=230 \
    DS_NOPROG=6000 DS_STACK=1000000000 DS_OUT="$WM/oracle/out/phi_smoke.jsonl" \
    julia +lts --project=. "$WM/oracle/gen_oracle_dataset.jl" ) > "$S6DIR/phi_smoke.log" 2>&1
  SMOKE_OK=$(python - << 'PYEOF'
import json, os, sys
p = os.path.join("wm4spacecraft_manufacturing", "oracle", "out", "phi_smoke.jsonl")
need = ["raw_robot_mode", "raw_robot_x", "raw_cargo_id", "target_id"]
try:
    rows = [json.loads(l) for l in open(p, encoding="utf-8") if l.strip()]
except Exception as e:
    print("0"); sys.exit(0)
f0 = (rows[0].get("features") or {}) if rows else {}
ok = bool(rows) and all(k in f0 for k in need)
print("1" if ok else "0")
PYEOF
)
  if [ "$SMOKE_OK" = "1" ]; then say "   스모크 PASS — φ 확장본으로 대량 생성."; PHI_TAG="phi"
  else say "   스모크 FAIL(새 컬럼 없음) — 로그: $S6DIR/phi_smoke.log. 기존 φ 로 진행."; PHI_TAG="old"; fi
fi

say "PHASE 2) 에피소드 생성 시작 (tag=$PHI_TAG, 2병렬)"
SEED_GROUPS=("41,42,43" "44,45,46" "47,48,49" "50,51,52" "53,54,55" "56,57,58")
i=0
while [ $i -lt ${#SEED_GROUPS[@]} ]; do
  for slot in 1 2; do
    [ $i -ge ${#SEED_GROUPS[@]} ] && break
    S="${SEED_GROUPS[$i]}"; TAG="p$(printf '%02d' $i)"
    # DS_EP_LO/HI = 사건 발화점 구간(닫힌 노드 수). 기본 [8,60] 은 **쓰면 안 된다** —
    # 이 빌드는 첫 배치에서 closed 가 0 -> 58 로 한 번에 뛰므로(probe 실측) 60 이하의
    # 발화점은 전부 같은 스텝에 몰려 터진다. 그래서 "에피소드"가 실제로는 동시사건 3개였고
    # tau_to_next 가 전부 0 이었다. [70,230] 이면 배치가 ~10 씩 진행하는 구간이라 결정이
    # 시간적으로 분리되고 SMDP sojourn 이 의미를 갖는다.
    ( DS_EPISODE_N=3 DS_SEEDS="$S" DS_MC_K=1 DS_VALID_ONLY=1 DS_HOTSWAP=1 \
      DS_EP_LO=70 DS_EP_HI=230 \
      DS_NOPROG=6000 DS_STACK=1000000000 \
      DS_OUT="$WM/oracle/out/ep2_${TAG}.jsonl" \
      julia +lts --project=. "$WM/oracle/gen_oracle_dataset.jl" > "$OUT/ep2gen_${TAG}.log" 2>&1
      echo "$(date '+%H:%M:%S') ep2 $TAG seeds=$S rc=$? rows=$(wc -l < "$WM/oracle/out/ep2_${TAG}.jsonl" 2>/dev/null || echo 0)" >> "$LOG" ) &
    i=$((i+1))
  done
  wait
  say "   에피소드 진행: $i/${#SEED_GROUPS[@]} 그룹, 누적 행 $(cat "$WM"/oracle/out/ep2_*.jsonl 2>/dev/null | grep -c .)"
done
say "PHASE 2 완료."

# ---------------------------------------------------------------------------
# PHASE 3 — 분석 + STEP 6 gap 집계 + 리포트
# ---------------------------------------------------------------------------
say "PHASE 3) 분석"
( cd "$WM" && python -u overnight_mdp.py --glob='oracle/out/ep*.jsonl' ) \
  > "$OUT/ep2_analysis.txt" 2>&1
say "   -> artifacts_mdp/ep2_analysis.txt"

say "PHASE 3) STEP 6 gap 집계 (노이즈 대조군 포함)"
( cd "$WM" && python -u "$REPO/tools/step6_gap.py" ) > "$OUT/step6b_gap.txt" 2>&1
say "   -> artifacts_mdp/step6b_gap.txt"

say "=== mdp_7h 파이프라인 완료 ==="
