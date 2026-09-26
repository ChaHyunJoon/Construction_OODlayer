#!/usr/bin/env bash
# chain.sh <b0_root> <logdir> [W=8] — 순차 동등성 기준 2판(부하 없음) → B0 120 + 무하네스 대조 3(W 병렬)
#   → 분석 → easy_lost 판을 REPAIR_ABLATION=none 으로(W/2 병렬) → 분석. 판마다 campaign.py run-one(run1.sh).
R=$1; LOG=$2; W=${3:-8}; H="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$H/../../../.." && pwd)"; mkdir -p $LOG
echo "=== seq start $(date +%F' '%T) ==="
"$H/run1.sh" $R/seq/tractor canonical zone 27
"$H/run1.sh" $R/seq/xwing canonical zone 27
echo "=== seq done $(date +%F' '%T) ==="
J=$LOG/grid_jobs.txt; : > $J
echo "$R/control_off/xwing canonical zone 27" >> $J; echo "$R/control_off/tractor canonical zone 27" >> $J
echo "$R/control_off/xwing canonical all3 11" >> $J
for m in xwing tractor; do for c in all3 zone; do for s in $(seq 1 30); do echo "$R/$m canonical $c $s" >> $J; done; done; done
echo "=== B0 grid $(wc -l < $J) runs W=$W start $(date +%F' '%T) ==="
xargs -P "$W" -L 1 "$H/run1.sh" < $J; echo "=== grid done $(date +%F' '%T) xargs_rc=$? ==="
python3 $ROOT/tools/monitor/grid/analyze_b0.py $R $R/out > $LOG/analyze.json
D=$LOG/decomp_jobs.txt
python3 -c "import json,sys; [print('%s/decomp_none/%s canonical %s %s' % (sys.argv[1], *k.replace('__s','__').split('__'))) for k in json.load(open(sys.argv[1]+'/out/b0_summary.json'))['easy_lost']]" $R > $D
echo "=== decomp $(wc -l < $D) runs start $(date +%F' '%T) ==="
xargs -P $(( W / 2 )) -L 1 "$H/run1.sh" < $D; echo "=== decomp done $(date +%F' '%T) xargs_rc=$? ==="
python3 $ROOT/tools/monitor/grid/analyze_b0.py $R $R/out > $LOG/analyze.json
for m in xwing tractor; do python3 $ROOT/tools/monitor/grid/campaign.py summarize $R/$m; done
