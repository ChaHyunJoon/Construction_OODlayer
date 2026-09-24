#!/usr/bin/env bash
# G5 격자의 raw_lm 추정 비용(세 ledger_<lvl>.jsonl 합)이 $150 을 넘으면 그 격자만 멈춘다.
# 대상은 /proc environ 으로 고른다(패턴 kill 은 자기 셸을 죽인다); 서비스·tmux 세션은 건드리지 않는다.
# 드라이버 세션 abl-g5-driver 가 생길 때까지 기다리고, 그 세션이 끝날 때까지 돈다.
D=/home/chahj578/Construction_OODlayer/results/2026-09-23-repair-ablation
COST=/home/chahj578/Construction_OODlayer/results/2026-09-23-router-sol/cost.py
CAP=150
active() { for p in $(ps -eo pid=,user= | awk '$2=="chahj578"{print $1}'); do
  { tr '\0' '\n' < /proc/$p/environ; } 2>/dev/null | /usr/bin/grep -qE '^(GRID_OUT=.*repair-ablation/|DEMO_CAMPAIGN_ID=abl-)' && echo $p; done; }
usd_now() { local t=0 u; for l in none translate all; do
  [ -f $D/ledger_$l.jsonl ] || continue
  u=$(python3 $COST $D/ledger_$l.jsonl 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['usd_raw_lm'])" 2>/dev/null || echo 0)
  t=$(python3 -c "print($t+$u)"); done; echo $t; }
until tmux has-session -t abl-g5-driver 2>/dev/null; do sleep 5; done
echo "$(date +%T) watchdog armed, cap \$$CAP" >> $D/cost_watchdog.log
while tmux has-session -t abl-g5-driver 2>/dev/null; do
  usd=$(usd_now)
  if python3 -c "import sys;sys.exit(0 if float('$usd')>$CAP else 1)"; then
    touch $D/STOP
    echo "$(date +%T) COST CAP HIT usd_raw_lm=$usd — stopping repair-ablation grids" >> $D/cost_watchdog.log
    for p in $(active); do [ $p -ne $$ ] && kill -TERM $p; done; exit 0
  fi
  echo "$(date +%T) usd_raw_lm=$usd active=$(active | wc -l)" >> $D/cost_watchdog.log; sleep 60
done
echo "$(date +%T) driver ended; last usd_raw_lm=$(usd_now)" >> $D/cost_watchdog.log
