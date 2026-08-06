#!/usr/bin/env bash
# MC 데이터셋 생성에 마감시각을 건다. 마감이 되면 **gen_oracle_dataset.jl 프로세스만** 정리해서
# 오케스트레이터의 대기 루프가 풀리게 한다. STEP 6 은 gen_oracle_mc.jl 이라 명령줄로 구분되므로
# 절대 오폭하지 않는다(둘이 동시에 살아있는 경우에도 안전).
# JSONL 은 행 단위로 flush 되므로 중간에 끊어도 그때까지의 라벨은 온전하다.
DEADLINE="${1:-03:30}"
LOG="$(dirname "$0")/../wm4spacecraft_manufacturing/artifacts_mdp/overnight.log"
say () { echo "[$(date '+%H:%M:%S')] [deadline] $*" | tee -a "$LOG"; }
say "MC 생성 마감 $DEADLINE 설정 (넘으면 gen_oracle_dataset.jl 만 정리)"
while true; do
  NOW=$(date '+%H:%M')
  # 자정을 넘긴 상태에서 00:00 <= NOW < DEADLINE 이면 계속 대기
  if [[ "$NOW" > "$DEADLINE" || "$NOW" == "$DEADLINE" ]]; then break; fi
  sleep 60
done
N=$(powershell.exe -NoProfile -Command "(Get-CimInstance Win32_Process -Filter \"Name='julialauncher.exe'\" | Where-Object { \$_.CommandLine -like '*gen_oracle_dataset.jl*' }).Count" 2>/dev/null | tr -d '\r ')
say "마감 도달. 남은 생성 샤드 ${N:-0}개 정리."
powershell.exe -NoProfile -Command "
  \$L = Get-CimInstance Win32_Process -Filter \"Name='julialauncher.exe'\" | Where-Object { \$_.CommandLine -like '*gen_oracle_dataset.jl*' }
  foreach (\$p in \$L) {
    Get-CimInstance Win32_Process -Filter \"ParentProcessId=\$(\$p.ProcessId)\" | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }
    Stop-Process -Id \$p.ProcessId -Force -ErrorAction SilentlyContinue
  }
" 2>/dev/null
say "정리 완료 — 오케스트레이터가 분석 단계로 진행한다."
