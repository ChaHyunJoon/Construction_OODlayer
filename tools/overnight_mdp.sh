#!/usr/bin/env bash
# =============================================================================
# overnight_mdp.sh -- MDP 로드맵을 사람 없이 끝까지 돌리는 야간 오케스트레이터.
#   (설계: wm4spacecraft_manufacturing/MDP_DESIGN_FROM_SCRATCH.md)
#
# 왜 한 파일인가: 알림-체이닝(작업 끝나면 사람이/에이전트가 다음 걸 띄우는 방식)에 의존하면
# 한 군데만 끊겨도 밤새 아무것도 안 돈다. 전 과정을 한 프로세스가 순서대로 책임진다.
#
# 순서
#   0) 이미 돌고 있는 MC 데이터셋 생성(mcds_*.jsonl) 이 끝날 때까지 대기
#   1) STEP 6 시뮬(확장 행동공간)을 백그라운드로 먼저 띄운다 — 가장 오래 걸리므로 앞세운다
#   2) STEP 2~5 분석(집계/선별/T1/T2/Router)을 파이썬으로 수행
#   3) STEP 3 재측정(LOAO/누출) — MC 라벨 위에서
#   4) STEP 6 시뮬 완료 대기 -> gap 집계
#   5) 최종 리포트 md 작성
#
# 모든 단계는 실패해도 다음으로 넘어간다(set -e 를 쓰지 않는 이유). 로그는 $LOG 에 쌓인다.
# =============================================================================
cd "$(dirname "$0")/.." || exit 1
REPO="$PWD"
WM="$REPO/wm4spacecraft_manufacturing"
OUT="$WM/artifacts_mdp"
LOG="$OUT/overnight.log"
mkdir -p "$OUT"

say () { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

say "=== overnight MDP pipeline 시작 ==="

# ---------------------------------------------------------------------------
# 0) 진행 중인 MC 데이터셋 생성이 끝날 때까지 대기
#    판정: julia 프로세스가 더 이상 gen_oracle_dataset.jl 을 돌리고 있지 않으면 완료.
#    최대 6시간까지만 기다린다(그 이상이면 뭔가 잘못된 것).
# ---------------------------------------------------------------------------
say "0) MC 데이터셋 생성 완료 대기…"
WAITED=0
while [ $WAITED -lt 21600 ]; do
  RUNNING=$(ps -W 2>/dev/null | grep -ci "julia" || true)
  ACTIVE=$(ls -1 "$WM"/oracle/out/mcds_*.jsonl 2>/dev/null | wc -l)
  # julia 가 하나도 안 돌면 생성 종료로 본다
  if [ "$RUNNING" -eq 0 ]; then
    say "   julia 프로세스 없음 -> 생성 완료로 판단 (shard 파일 $ACTIVE개)"
    break
  fi
  sleep 60; WAITED=$((WAITED+60))
  [ $((WAITED % 900)) -eq 0 ] && say "   …대기 ${WAITED}s (julia $RUNNING개 실행 중)"
done
ROWS=$(cat "$WM"/oracle/out/mcds_*.jsonl 2>/dev/null | wc -l)
say "   MC 원시 행 $ROWS개"

# ---------------------------------------------------------------------------
# 1) STEP 6: 확장 행동공간 gap 시뮬을 백그라운드로 시작 (가장 긴 작업)
#    arms: 0 NOOP / 1 Replace / 10,11,12 Replace(after=0,5,15) / 20,21,22 Deprioritize(f=10,50,200)
#    3개 build seed x 8 arm x K=2 = 48 sim. 4-way 병렬.
# ---------------------------------------------------------------------------
say "1) STEP 6 확장-행동공간 시뮬 시작(백그라운드, 4-way)"
S6LOG="$OUT/step6"; mkdir -p "$S6LOG"
for s in 1 2 3; do
(
  MC_BATCH="$(for a in 0 1 10 11 12 20 21 22; do for k in 1 2; do printf '%s:%s,' $a $k; done; done)" \
  MC_SHARD="s6_${s}" ORACLE_SEED="$s" MC_SEED0=3000 MC_K=2 NSPARE=3 \
  MC_REFERENCE=0 HOT_SWAP=1 NOPROG=6000 \
  julia +lts --project=. "$WM/oracle/gen_oracle_mc.jl" > "$S6LOG/seed${s}.log" 2>&1
  echo "STEP6 seed $s DONE" >> "$LOG"
) &
done
S6_PIDS=$(jobs -p)

# ---------------------------------------------------------------------------
# 2) STEP 2~5 분석 (파이썬, 빠름)
# ---------------------------------------------------------------------------
say "2) STEP 2~5 분석 (집계/선별/T1/T2/Router)"
( cd "$WM" && python overnight_mdp.py ) >> "$LOG" 2>&1
say "   -> artifacts_mdp/overnight_results.json"

# ---------------------------------------------------------------------------
# 3) STEP 3 재측정 — MC 라벨 위에서 표현 비교 (누출/LOAO)
# ---------------------------------------------------------------------------
say "3) STEP 3 재측정 (MC 라벨 위 LOAO/누출)"
( cd "$WM" && python step3_loao.py "artifacts_mdp/mc_dataset.jsonl" ) \
  > "$OUT/step3_on_mc_labels.txt" 2>&1
say "   -> artifacts_mdp/step3_on_mc_labels.txt"

# ---------------------------------------------------------------------------
# 4) STEP 6 시뮬 대기 -> gap 집계
# ---------------------------------------------------------------------------
say "4) STEP 6 시뮬 완료 대기…"
wait $S6_PIDS 2>/dev/null
say "   STEP 6 시뮬 완료. gap 집계."
( cd "$WM" && python - << 'PYEOF' > "$OUT/step6_gap.txt" 2>&1
import glob, os, csv, math, json
import numpy as np
HERE = os.path.dirname(os.path.abspath("."))
files = sorted(glob.glob("oracle/out/oracle_mc_units_s*_s6_*.csv"))
MACRO = {0,1,2,3,4}                      # A_macro (기존 옵션 집합)
rows = []
for f in files:
    seed = os.path.basename(f).split("_s")[1].split("_")[0]
    with open(f, encoding="utf-8") as fh:
        for r in csv.DictReader(fh):
            try:
                rows.append({"seed": seed, "action": int(r["action"]), "rollout": int(r["rollout"]),
                             "cost": float(r["cost"]), "complete": r["complete"] == "true"})
            except Exception:
                pass
print(f"읽은 행 {len(rows)}개, 파일 {len(files)}개")
if not rows:
    print("STEP 6 데이터 없음 — 시뮬이 실패했거나 아직 안 끝남.")
else:
    print("\nSTEP 6: 옵션 제한의 대가  V^macro - V*  (설계 §4.4)")
    print("  A_macro = {0,1,2,3,4} (기존 5개 옵션) / A_ext = A_macro + 파라미터 변형(10~12, 20~22)")
    print("  주의: A_ext 는 원시 배정공간 전체가 아니라 **옵션의 연속 파라미터만** 연 것이므로,")
    print("        여기서 측정되는 gap 은 진짜 gap 의 **하한(lower bound)** 이다.\n")
    print(f"  {'seed':>6} {'V^macro':>12} {'V*(ext)':>12} {'gap':>10} {'gap%':>8}  {'ext best':>10}")
    gaps = []
    for seed in sorted({r["seed"] for r in rows}):
        g = [r for r in rows if r["seed"] == seed]
        q = {}
        for r in g:
            q.setdefault(r["action"], []).append(r["cost"])
        qm = {a: float(np.mean(v)) for a, v in q.items()}
        mac = {a: v for a, v in qm.items() if a in MACRO}
        if not mac or not qm: continue
        v_mac = min(mac.values()); v_ext = min(qm.values())
        best_ext = min(qm, key=qm.get)
        gap = v_mac - v_ext
        pct = 100.0 * gap / abs(v_mac) if v_mac else 0.0
        gaps.append(gap)
        print(f"  {seed:>6} {v_mac:>12.2f} {v_ext:>12.2f} {gap:>10.2f} {pct:>7.1f}%  {best_ext:>10}")
    if gaps:
        print(f"\n  평균 gap = {np.mean(gaps):.2f}   (0 이면 옵션 제한의 대가가 관측되지 않음)")
        print("  gap=0 의 해석: 이 파라미터 범위에서는 기본 옵션이 이미 최적. 더 넓은 원시공간에서도")
        print("                 그렇다는 뜻은 아니다(측정된 것은 하한).")
    json.dump({"gaps": gaps}, open("artifacts_mdp/step6_gap.json", "w"), indent=2)
PYEOF
)
say "   -> artifacts_mdp/step6_gap.txt"

# ---------------------------------------------------------------------------
# 5) 최종 리포트
# ---------------------------------------------------------------------------
say "5) 최종 리포트 작성"
{
  echo "# 야간 MDP 파이프라인 결과 ($(date '+%Y-%m-%d %H:%M'))"
  echo
  echo "생성 데이터: MC 원시 행 ${ROWS}개 -> artifacts_mdp/mc_dataset.jsonl"
  echo
  echo "## STEP 2~5 (집계 / admissibility / T1 / T2 / Router)"
  echo '```'
  sed -n '/A. 원시 rollout/,$p' "$LOG" | head -200
  echo '```'
  echo
  echo "## STEP 3 재측정 (MC 라벨 위)"
  echo '```'
  tail -40 "$OUT/step3_on_mc_labels.txt" 2>/dev/null
  echo '```'
  echo
  echo "## STEP 6 옵션-제한 gap"
  echo '```'
  cat "$OUT/step6_gap.txt" 2>/dev/null
  echo '```'
} > "$OUT/OVERNIGHT_REPORT.md"

say "=== 완료. 리포트: $OUT/OVERNIGHT_REPORT.md ==="
