#!/usr/bin/env bash
# =============================================================================
# finish_tables.sh -- 샤드 트리 -> case jsonl -> 아티팩트 -> FINAL.md + COMPARE.md/html
#
# 왜 스크립트인가: 이 다섯 단계는 **순서와 인자가 서로 물려 있다.** 손으로 치면 정책 목록이
# 한 군데만 어긋나도 병합기가 "OK" 를 내면서 조용히 부분 파일을 만든다(sweep/merge_shards.py 머리말의
# 사고 그대로). 한 곳에 적어 두고 그것만 돌린다.
#
# 3정책 샤드와 dp 샤드가 **다른 트리**에 있는 이유: sweep/run_shard.sh 의 provenance 도장은
# (commit, policies) 쌍이라, 같은 OUTDIR 에 다른 정책 목록으로 들어가면 STALE 로 판정해
# **이미 끝난 3정책 결과를 지우고 다시 돈다.** 트리를 갈라 그 충돌을 피한다.
#
# 사용법:  bash reporting/finish_tables.sh [SEEDS]   (어느 cwd 에서 불러도 된다)
# =============================================================================
set -uo pipefail

# 2026-08-18 폴더 분류: 이 스크립트가 reporting/ 으로 내려갔다. 아래 인자(results_4pol,
# artifacts_4pol)는 전부 **wm4 폴더 기준 상대경로**라 cwd 는 계속 WM 이어야 한다.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"      # reporting/
WM="$(cd "$HERE/.." && pwd)"                              # wm4spacecraft_manufacturing/
cd "$WM"
PY="$WM/../.venv/bin/python"

SEEDS="${1:-1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30}"
CASES="battery,fault,all,fault_battery,fault_zone,battery_zone,zone"
POL3="canonical,surrogate,dspy"

echo "=== 1) 3정책 샤드 병합 ==="
"$PY" "$WM/sweep/merge_shards.py" --shards-dir results_4pol/shards --out-dir /tmp/merge3 \
      --cases "$CASES" --seeds "$SEEDS" --policies "$POL3"
rc3=$?
echo "merge3 rc=$rc3"

DP_OK=0
if [ -d results_4pol/shards_dp ]; then
    echo "=== 2) dp 샤드 병합 ==="
    "$PY" "$WM/sweep/merge_shards.py" --shards-dir results_4pol/shards_dp --out-dir /tmp/mergedp \
          --cases "$CASES" --seeds "$SEEDS" --policies "dp"
    rcdp=$?
    echo "mergedp rc=$rcdp"
    [ "$rcdp" -eq 0 ] && DP_OK=1
else
    echo "=== 2) dp 샤드 트리 없음 -- dp 열은 '이 레인은 스윕에 없음' 으로 남는다 ==="
fi

echo "=== 3) case 파일 합치기 ==="
# 행마다 `policy` 필드가 있으므로 이어붙이기가 정당하다. 정렬은 각 병합기가 이미 결정적으로
# 해 놨고, 두 블록의 순서(3정책 다음 dp)도 고정이라 이 결과도 결정적이다.
mkdir -p results_4pol
IFS=',' read -r -a CARR <<< "$CASES"
for c in "${CARR[@]}"; do
    : > "results_4pol/$c.jsonl"
    [ -f "/tmp/merge3/$c.jsonl" ]  && cat "/tmp/merge3/$c.jsonl"  >> "results_4pol/$c.jsonl"
    [ "$DP_OK" -eq 1 ] && [ -f "/tmp/mergedp/$c.jsonl" ] && cat "/tmp/mergedp/$c.jsonl" >> "results_4pol/$c.jsonl"
    printf '  %-14s %s rows\n' "$c" "$(grep -c . "results_4pol/$c.jsonl")"
done

echo "=== 4) 세대 단일성 + 정책 구성 확인 ==="
"$PY" - <<'PYEOF'
import json, glob, collections, sys
rows=[json.loads(l) for p in glob.glob('results_4pol/*.jsonl') for l in open(p) if l.strip()]
gens=collections.Counter((r.get('objective_hash'), r.get('energy_objective')) for r in rows)
pols=collections.Counter(r.get('policy') for r in rows)
print('  행 %d' % len(rows))
print('  세대 쌍:', dict(gens))
print('  정책:', dict(pols))
if len(gens) != 1:
    print('  !! 세대가 섞였다 -- 표를 내지 않는다'); sys.exit(1)
PYEOF
[ $? -ne 0 ] && { echo "세대 확인 실패 -- 중단"; exit 1; }

echo "=== 5) 아티팩트 + FINAL.md ==="
"$PY" "$HERE/build_final_table.py" --results-dir results_4pol --out-dir artifacts_4pol
echo "build_final_table rc=$?"

echo "=== 6) 4정책 x 7case 비교표 ==="
"$PY" "$HERE/build_compare_table.py" --artifacts artifacts_4pol \
      --out-md artifacts_4pol/COMPARE.md --out-html artifacts_4pol/compare.html
echo "build_compare_table rc=$?"

echo "=== 완료 ==="
ls -la artifacts_4pol/FINAL.md artifacts_4pol/COMPARE.md artifacts_4pol/compare.html 2>/dev/null
