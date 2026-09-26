#!/usr/bin/env bash
# cohort.sh <W> — T10b 역사적 body 재생 31판(긴 판 먼저), 판 안은 순차, 판끼리 W 병렬. 한 디렉터리.
set -u
W=${1:-6}
ROOT=/home/chahj578/Construction_OODlayer
R=$ROOT/results/2026-09-24-zone-repair-verification/validation/t10b
L=$ROOT/.superpowers/sdd/2026-09-24-zone-repair-verification/logs/t10b
mkdir -p $R/cohort $R/campaign $L/cohort
python3 - > $L/cohort.jobs <<'PY'
import json
d=json.load(open('/home/chahj578/Construction_OODlayer/test/fixtures/repair_verification/tools/legacy_chains.json'))['episodes']
rank=lambda k:( {'xwing':0,'tractor':1}[d[k]['model']], {'anchor':0,'drift':0,'easy_kept':1}[d[k]['group']])
for k in sorted(d,key=rank):
    print(k, 'GP' if d[k]['group']=='easy_kept' else 'GP,L0,L1')
PY
echo "=== cohort $(wc -l < $L/cohort.jobs) jobs W=$W start $(date +%T) HEAD=$(git -C $ROOT rev-parse --short HEAD)"
cat $L/cohort.jobs | xargs -P $W -L 1 bash -c 'cd '"$ROOT"' && julia +lts --project=. tools/monitor/replay_repair_cohort.jl "$0" '"$R"'/cohort/"$0" "$1" '"$R"'/campaign > '"$L"'/cohort/"$0".log 2>&1; echo "[job] $0 rc=$? $(date +%T)"'
echo "=== cohort done $(date +%T)"
