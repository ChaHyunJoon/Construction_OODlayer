# run_nominal_shard.ps1 -- generate the missing kind="none" rows for one shard.
#
# WHY A LAUNCHER SCRIPT INSTEAD OF INLINE ENV VARS
# ------------------------------------------------
# The first attempt ran the shards as background jobs of the interactive session. When that
# session ended they were killed with 0 rows written -- a ~1.8 h job cannot be a child of a
# shell that may exit sooner. Start-Process needs a single command to detach, and env vars do
# not survive Start-Process, so the configuration has to live in a file. That file is this one.
#
# USAGE (detached, survives the parent shell):
#   Start-Process powershell -ArgumentList '-NoProfile','-File',
#       '<abs path>\run_nominal_shard.ps1','-Shard','1','-Of','2' -WindowStyle Hidden
#
# 한국어: 첫 시도는 셸의 백그라운드 작업으로 돌렸다가 세션이 끝나면서 0행으로 죽었다.
#   1.8시간짜리 작업은 셸보다 오래 살아야 하므로 Start-Process 로 떼어내야 하고,
#   Start-Process 는 환경변수를 물려주지 않으므로 설정을 이 파일에 넣는다.
param(
    [int]$Shard = 1,
    [int]$Of = 2,
    [string]$From = "oracle/out/openworld_merged.jsonl",
    # 기본 2GB -> 1GB. 2026-07-30 에 샤드 2개(각 2GB) 가 다른 작업과 겹치면서 14.7분 만에
    # OutOfMemoryError 로 죽었다(22/60 지점). 이 스택은 판 하나마다 통째로 잡히므로 N 병렬이면
    # N x DS_STACK 이다. 1GB 로 낮춰 마진을 만든다 -- 깊은 재귀가 있으면 StackOverflowError 가
    # 나므로, 첫 instance 가 통과하는지가 곧 스모크 테스트다(DS_RESUME 덕에 실패해도 손실 1판).
    [string]$Stack = "1000000000"
)

$ErrorActionPreference = "Continue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path      # ...\wm4spacecraft_manufacturing\oracle
$wm = Split-Path -Parent $here                                # ...\wm4spacecraft_manufacturing
Set-Location $wm

# nominal 행만 만든다: 매크로 5판은 openworld_merged.jsonl 에 이미 있다(작업량 1/6).
$env:DS_NOMINAL      = "1"
$env:DS_NOMINAL_ONLY = "1"
$env:DS_DRYRUN       = "0"
$env:DS_SMOKE        = "0"
# instance 목록은 원본 덤프에서 그대로 읽는다. 환경변수로 재구성하면 추측이 섞여
# (faultidle 은 sp3 만 있는데 DS_SPARES=1,3 이면 sp1 이 더 생긴다) 조인이 깨진다.
$env:DS_INSTANCES_FROM = $From
$env:DS_HOTSWAP      = "1"        # 라벨을 데모와 같은 완주 세계에서 측정 (run_one 주석 참조)
$env:DS_SHARD        = "$Shard/$Of"
$env:DS_OUT          = "oracle/out/nominal_shard$Shard.jsonl"
# 죽었다 다시 떠도 이미 만든 행은 건너뛴다. 이 작업은 시간 단위라 재개가 없으면
# 중간에 한 번만 끊겨도 전부 다시 해야 한다(첫 시도가 그렇게 0행으로 끝났다).
$env:DS_RESUME       = "1"
$env:DS_STACK        = $Stack

$log = "artifacts_classifier/nominal_shard$Shard.log"
New-Item -ItemType Directory -Force -Path "artifacts_classifier" | Out-Null

# 로그도 append -- 재시작 이력이 남아야 무슨 일이 있었는지 추적된다.
"[launch] shard $Shard/$Of  pid=$PID  $(Get-Date -Format o)" | Out-File -FilePath $log -Encoding utf8 -Append
$t0 = Get-Date
julia +lts --project=.. oracle/gen_oracle_dataset.jl 2>&1 |
    Out-File -FilePath $log -Encoding utf8 -Append
$mins = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)
"[done] shard $Shard/$Of  elapsed_min=$mins  exit=$LASTEXITCODE  $(Get-Date -Format o)" |
    Out-File -FilePath $log -Encoding utf8 -Append
