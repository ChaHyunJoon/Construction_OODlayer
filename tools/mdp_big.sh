#!/usr/bin/env bash
# =============================================================================
# mdp_big.sh — 구간 probe 결과를 받아 **확률 전이(hazard ON) 에피소드**를 대량 생성.
#
# 왜 hazard ON 인가 (결정론 K=1 을 폐기하는 근거):
#   결정론 에피소드는 **85% 가 동점**이었다(모든 팔의 비용이 완전히 동일 = 결정정보 0).
#   반면 STEP 6(이른 발화 + hazard ON, MTBF 500)에서는 같은 결정 상태에서
#   NOOP 50% vs Replace 75% 완주로 **팔이 확실히 갈렸다**(Q̂ 13117 vs 3573).
#   게다가 hazard 가 만드는 사후 사건은 **물리가 만드는 시간분리**라, 발화점을 손으로
#   배치해서 tau 를 확보하려던 시도(그러다 fault 가 아예 안 터졌다)가 필요 없어진다.
#   결정론은 애초에 "커플링만 먼저 보려는" 변수분리용 임시 조치였고, 그 실험은 끝났다.
#
# 절차
#   0) 구간 probe 완료 대기 -> 보고서에서 (fault>0 & tau>0 & 결정적 비율 최대) 구간 채택
#   1) 2병렬 대량 생성 (DS_MC_K=3 -> hazard 자동 arm)
#   2) 그룹마다 중간 분석 갱신 (중단돼도 최신 결과가 남는다)
# =============================================================================
cd "$(dirname "$0")/.." || exit 1
WM="$PWD/wm4spacecraft_manufacturing"; OUT="$WM/artifacts_mdp"; LOG="$OUT/big.log"
mkdir -p "$OUT"; export PYTHONIOENCODING=utf-8
say () { echo "[$(date '+%m-%d %H:%M:%S')] [big] $*" | tee -a "$LOG"; }

# ---------------------------------------------------------------------------
# 0) probe 대기 + 구간 채택
# ---------------------------------------------------------------------------
say "구간 probe 완료 대기 (최대 90분)"
W=0
while [ ! -s "$OUT/cfgprobe_report.txt" ] && [ $W -lt 5400 ]; do sleep 30; W=$((W+30)); done

read -r LO HI < <(python - << 'PYEOF'
# probe 보고서에서 구간을 고른다. 규칙: fault 발화 0 이거나 tau>0 이 0 이면 탈락,
# 남은 것 중 결정적(non-tie) instance 가 가장 많은 구간. 아무것도 못 고르면 55/130 로 간다
# (STEP 6 가 실제로 쓴 이른 구간 = fault 가 확실히 터지는 것이 확인된 영역).
import os, re
CAND = {"a55": (55, 130), "b59": (59, 110)}
best, bestn = None, -1
p = os.path.join("wm4spacecraft_manufacturing", "artifacts_mdp", "cfgprobe_report.txt")
try:
    for line in open(p, encoding="utf-8"):
        f = line.split()
        if len(f) < 9 or f[0] not in CAND:
            continue
        cfg, inst, flt, bat, zon, taupos, taumed, tie, dec = f[:9]
        try:
            flt, taupos, dec = int(flt), int(taupos), int(dec)
        except ValueError:
            continue
        if flt <= 0 or taupos <= 0:
            continue
        if dec > bestn:
            best, bestn = cfg, dec
except Exception:
    pass
lo, hi = CAND.get(best, (55, 130))
print(lo, hi)
PYEOF
)
LO=${LO:-55}; HI=${HI:-130}
say "채택 구간 = [$LO, $HI]"

# ---------------------------------------------------------------------------
# 1) 대량 생성 — hazard ON (DS_MC_K=3), 2병렬
# ---------------------------------------------------------------------------
# 12 그룹 × 2 seed = 24 seed × 3 결정 = 최대 72 instance.
# 실측 근거: probe 에서 K=1 6 sim 이 ~7분(1.2분/sim). hazard ON 이면 미완주가 늘어
# 평균 ~2.5분/sim -> seed 당 18 sim = 45분, 그룹(2 seed) = ~1.6시간, 12그룹/2레인 = ~10시간.
# **그룹마다 중간 분석을 갱신하므로 anytime 이다** — 2그룹(1.6h)이면 12 instance,
# 6그룹(5h)이면 36, 12그룹(10h)이면 72. 언제 멈춰도 최신 결과가 남는다.
SEED_GROUPS=("301,302" "303,304" "305,306" "307,308" "309,310" "311,312"
             "313,314" "315,316" "317,318" "319,320" "321,322" "323,324")
say "생성 시작: ${#SEED_GROUPS[@]} 그룹 × 2 seed, K=3(hazard ON), 2병렬"
i=0
while [ $i -lt ${#SEED_GROUPS[@]} ]; do
  for slot in 1 2; do
    [ $i -ge ${#SEED_GROUPS[@]} ] && break
    S="${SEED_GROUPS[$i]}"; TAG="h$(printf '%02d' $i)"
    ( DS_EPISODE_N=3 DS_SEEDS="$S" DS_MC_K=3 DS_VALID_ONLY=1 DS_HOTSWAP=1 \
      DS_EP_LO=$LO DS_EP_HI=$HI DS_EP_KINDS="fault,fault,battery,battery,zoneblk" \
      DS_MTBF_BREAK=500 DS_MTBF_CELL=500 DS_HZ_SEED0=7000 \
      DS_NOPROG=6000 DS_STACK=1000000000 DS_PROBE_EVERY=0 \
      DS_OUT="$WM/oracle/out/ep3_${TAG}.jsonl" \
      julia +lts --project=. "$WM/oracle/gen_oracle_dataset.jl" > "$OUT/big_${TAG}.log" 2>&1
      echo "$(date '+%H:%M:%S') $TAG seeds=$S rc=$? rows=$(wc -l < "$WM/oracle/out/ep3_${TAG}.jsonl" 2>/dev/null || echo 0)" >> "$LOG" ) &
    i=$((i+1))
  done
  wait
  say "   $i/${#SEED_GROUPS[@]} 그룹, 결정행 누적 $(cat "$WM"/oracle/out/ep3_h[0-9][0-9].jsonl 2>/dev/null | grep -c .)"
  ( cd "$WM" && python -u overnight_mdp.py --glob='oracle/out/ep3_h[0-9][0-9].jsonl' ) \
    > "$OUT/ep3_analysis.txt" 2>&1
  say "   중간 분석 -> artifacts_mdp/ep3_analysis.txt"
done
say "=== 완료 ==="
