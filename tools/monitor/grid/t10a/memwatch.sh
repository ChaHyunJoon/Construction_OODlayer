#!/usr/bin/env bash
# memwatch.sh <log> — 60 s 마다 호스트 메모리·julia 프로세스 수·부하
while true; do
  echo "$(date +%T) $(free -m | awk '/Mem:/{print "used="$3"MB avail="$7"MB"}') $(free -m | awk '/Swap:/{print "swap_used="$3"MB"}') julia=$(pgrep -c -u $USER julia) load=$(cut -d' ' -f1-3 /proc/loadavg)" >> "$1"
  sleep 60
done
