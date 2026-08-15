#!/usr/bin/env bash
# =============================================================================
# 2026-08-16 라벨 재생성 — 행동집합을 닫는다 (Task 1 Step 5)
#
# 무엇이 2026-08-14 판과 다른가:
#   1. `reform` kind 가 격자에 들어간다. 선행 fault 를 심고, 그 뒤 엔진이 스스로 올리는
#      팀 교착 알람(`maybe_emit_reform_ood!`)을 연구 대상으로 잡는다 — `run_demo.jl` 의
#      DEMO_REFORM 과 같은 조건·같은 NL.
#   2. kind 마다 **레지스트리가 legal 이라고 말하는 팔을 전부** 굴린다. shim 의
#      `valid_actions` 가 이제 `action_registry.json` 파생이라, DS_VALID_ONLY=1 이
#      자동으로 그 집합을 고른다(fault -> {0,1,2,4,5,6} · battery -> {0,1,2,8} ·
#      zone -> {0,3,7}∩가능 · reform -> {0,4}).
#   3. DS_COMBO_ARMS=1 — 조합 팔 5·6 을 켠다(2026-08-16 결정).
#   4. DS_BATTERY_SOC_SPLIT=0 — battery 상한 {0,1,2,8} 을 통째로 굴린다. 켜 두면 SoC 로
#      {0,1,8}/{0,2,8} 로 갈려 "깊은 방전에서 Deprioritize 가 이기는가"를 라벨이 못 답한다.
#
# 격자는 2026-08-14 판을 **그대로** 복원한 것에 reform 만 더했다(instance 165 -> 195):
#   seeds 1..5 · spares {0,3} · fire {58,140,220} · bsoc {0.02,0.3,0.5} · zfrac {0.5,0.9,1.3}
#
# 사용법:  bash oracle/run_relabel_20260816.sh [샤드수]      (기본 32)
# 결과:    oracle/out/relabel_2026-08-16.jsonl               (샤드를 합친 것)
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO="$(cd .. && pwd)"

NSHARD="${1:-32}"
OUTDIR="oracle/out/relabel_2026-08-16_shards"
FINAL="oracle/out/relabel_2026-08-16.jsonl"
LOGDIR="oracle/out/_relabel_logs_20260816"
mkdir -p "$OUTDIR" "$LOGDIR"

# --- 어휘·격자 (전 샤드 공통. 하나라도 샤드마다 다르면 세대가 갈린다) --------------------
export DS_COMBO_ARMS=1            # 조합 팔 5·6 활성 (action_registry.is_active 게이트)
export DS_BATTERY_SOC_SPLIT=0     # battery 상한 {0,1,2,8} 전부
export DS_VALID_ONLY=1            # kind 별 legal 팔만 (이제 레지스트리 파생)
export DS_SEEDS=1,2,3,4,5
export DS_KINDS=fault,faultidle,battery,zoneblk,zoneharm,reform
export DS_SPARES=0,3
export DS_FIRE_GRID=58,140,220
export DS_BSOC=0.02,0.3,0.5
export DS_ZFRACS=0.5,0.9,1.3
export DS_REFORM=120              # run_demo.jl 과 같은 교착 감지 간격 (run_one 기본값과 동일, 명시)

echo "[relabel] shards=$NSHARD  kinds=$DS_KINDS  combos=$DS_COMBO_ARMS"
echo "[relabel] -> $OUTDIR"

for i in $(seq 1 "$NSHARD"); do
  DS_SHARD="$i/$NSHARD" DS_OUT="$OUTDIR/shard_$i.jsonl" \
    julia +lts --project="$REPO" "$REPO/wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl" \
    > "$LOGDIR/shard_$i.log" 2>&1 &
done

wait
echo "[relabel] 전 샤드 종료. 합치는 중..."
cat "$OUTDIR"/shard_*.jsonl > "$FINAL"
echo "[relabel] $FINAL : $(wc -l < "$FINAL") rows"
