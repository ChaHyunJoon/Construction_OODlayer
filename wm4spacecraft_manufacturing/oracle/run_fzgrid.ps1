# =============================================================================
# run_fzgrid.ps1 -- TASK 5: 매크로 7(RelocateBuild) 첫 학습 근거를 만드는 격자 (2026-08-06).
#
# run_step6_zonegrid.ps1 을 원형으로 하되 세 가지만 바꾼다 (task-5-brief.md Step 2):
#   1. $Lanes = 1 고정 (하드코딩, param 아님) -- 팔 교차는 비교다. 병렬이면 HiGHS 가 다른
#      스케줄을 내 팔끼리 비교가 무효가 된다(함정 30).
#   2. DS_ZONE_ELIGIBLE 을 설정하지 않는다 -- 기본값 workdisc 가 매크로 7(RelocateBuild ->
#      translate_whole_build!) 의 수리기와 일치한다. (원형도 이미 이 변수를 안 썼으므로
#      지울 줄이 없다 -- 원형의 Common 블록에 DS_ZONE_ELIGIBLE 자체가 없음.)
#   3. DS_EP_MACROS = "0,7" (원형의 "0,3,7" 에서 3 을 뺀다) -- 매크로 3(ForbidZone) 은
#      라벨 경로에서 도달 불가로 실측됐다(Task 1). 3 을 끼워 넣으면 도메인이 비어
#      restage_all_blocked! 이 :none 으로 조기 반환하고, 그 행은 NOOP 과 바이트 동일해진다
#      -- 결정을 재는 게 아니라 동점을 제조하는 것.
#
# 그 외(DS_REFORM=120 포함)는 원형 그대로 -- 브리프가 명시한 변경은 이 세 가지뿐이다.
#
# job 축: zone 위치(DS_EP_ZFRAC) x seed. 발화 구간(DS_EP_LO/HI)은 기본값을 쓴다 -- 라벨러의
# 발화점은 슬롯이 아니라 closed 카운터에 걸리므로 배치 경계로 끌려간다(Task 1 D2), 좁게
# 지정해도 의미가 없다. 기본값이 기존 zone 덤프와 같은 세계라 비교가 성립한다.
#
# 실행:
#   powershell -NoProfile -ExecutionPolicy Bypass -File oracle\run_fzgrid.ps1 -MaxMinutes 120
# 결과: oracle\out\fzgrid_0806\fz_<tag>.jsonl  (+ .log/.err)
# 재개 안전: 이미 행이 있는 job 은 건너뛴다.
# 마감 도달 시: 남은 job 을 띄우지 않고 그 목록을 stdout 에 찍는다(조용한 절단 금지).
# =============================================================================
param(
    [double]$MinFreeGB = 0.8,
    [int]$MaxMinutes = 0
)
$ErrorActionPreference = "Continue"
$Lanes = 1     # 고정 -- 팔 교차 비교의 전제. param 으로 노출하지 않는다(실수로 못 바꾸게).
$wm   = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $wm
$gen  = Join-Path $wm "oracle\gen_oracle_dataset.jl"

# 세계 설정은 run_step6_zonegrid.ps1(원형)과 동일 -- 브리프가 바꾸라고 지목한 것은
# DS_EP_MACROS 하나뿐이다. DS_ZONE_ELIGIBLE 은 원형에도 없으므로 그대로 미설정 = 기본 workdisc.
$Common = @{
    DS_EPISODE_N = "1"
    DS_EP_KINDS  = "zoneblk"
    DS_VALID_ONLY = "1"
    DS_EP_MACROS = "0,7"        # TASK 5 변경: 원형의 "0,3,7" 에서 3 을 뺀다
    DS_ZONE_DIAG = "1"          # 진단 배선 ON = 팔/기준정책이 기하로 정해짐
    DS_SPARES    = "3"
    DS_NOPROG    = "8000"
    DS_NOCTRL    = "1"
    DS_REFORM    = "120"
    CARRIER_RESCUE = "1"
    DS_HOTSWAP   = "1"
    DS_STACK     = "1000000000"
    JULIA_NUM_THREADS = "1"
    OMP_NUM_THREADS   = "1"
    OPENBLAS_NUM_THREADS = "1"
}

# --- job 목록: zone 위치(DS_EP_ZFRAC) x seed -- task-5-brief.md Step 2 그대로 -----------------
# 0.9 = 기존 덤프와 같은 자리, 0.5 = 더 안쪽(더 많이 겹침). 발화 구간은 기본값(DS_EP_LO/HI 미지정).
$Jobs = @()
foreach ($zf in @("0.9", "0.5")) {
    foreach ($s in @(1, 2, 3)) {
        $Jobs += @{ tag = ("fz_zf{0}_s{1}" -f $zf.Replace(".", ""), $s); seed = $s; zfrac = $zf }
    }
}

function AvailGB { try { (Get-Counter '\Memory\Available MBytes' -EA Stop).CounterSamples[0].CookedValue / 1024 } catch { 99 } }
function JuliaCount { (Get-Process julia -ErrorAction SilentlyContinue | Measure-Object).Count }

$od = Join-Path $wm "oracle\out\fzgrid_0806"
New-Item -ItemType Directory -Force $od | Out-Null
$log = Join-Path $od "run.log"
function Say($m) { $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m; $line | Tee-Object -FilePath $log -Append | Out-Host }

$queue = New-Object System.Collections.Queue
foreach ($j in $Jobs) {
    $f = Join-Path $od ($j.tag + ".jsonl")
    if ((Test-Path $f) -and ((Get-Content $f | Measure-Object -Line).Lines -ge 1)) { Say ("[skip] " + $j.tag + " (already has rows)"); continue }
    $queue.Enqueue(@{ job = $j; file = $f; tag = $j.tag })
}
Say ("queued {0} jobs, lanes {1} (MaxMinutes={2})" -f $queue.Count, $Lanes, $MaxMinutes)

$running = @(); $t0 = Get-Date; $done = 0
while ($queue.Count -gt 0 -or $running.Count -gt 0) {
    $still = @()
    foreach ($r in $running) {
        if ($r.proc.HasExited) {
            $rows = if (Test-Path $r.file) { (Get-Content $r.file | Measure-Object -Line).Lines } else { 0 }
            $done++
            Say ("[done] {0}  {1:N1} min  {2} rows" -f $r.tag, ((Get-Date) - $r.t0).TotalMinutes, $rows)
        } else { $still += $r }
    }
    $running = $still
    if ($MaxMinutes -gt 0 -and ((Get-Date) - $t0).TotalMinutes -ge $MaxMinutes -and $queue.Count -gt 0) {
        # 조용한 절단 금지 -- 못 띄운 job 을 전부 이름으로 찍는다.
        $skipped = @($queue.ToArray() | ForEach-Object { $_.tag })
        Say ("[stop] 마감 도달 — 남은 {0} job 은 띄우지 않는다: {1}" -f $queue.Count, ($skipped -join ", "))
        $queue.Clear()
    }
    while ($running.Count -lt $Lanes -and $queue.Count -gt 0) {
        if ((JuliaCount) -ge $Lanes) { break }
        if ((AvailGB) -lt $MinFreeGB) { Say ("[wait] RAM {0:N1} GB" -f (AvailGB)); break }
        $u = $queue.Dequeue(); $j = $u.job
        foreach ($k in $Common.Keys) { Set-Item -Path ("env:" + $k) -Value $Common[$k] }
        foreach ($k in @("DS_EP_ZFRAC", "DS_EP_LO", "DS_EP_HI", "DS_LOG", "DS_MC_K")) {
            Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue
        }
        $env:DS_EP_ZFRAC = $j.zfrac
        $env:DS_SEEDS = "$($j.seed)"
        $env:DS_OUT   = $u.file
        $p = Start-Process -FilePath "julia" `
            -ArgumentList @("+lts", "--project=$repo", $gen) -WorkingDirectory $wm `
            -RedirectStandardOutput ([System.IO.Path]::ChangeExtension($u.file, ".log")) `
            -RedirectStandardError  ([System.IO.Path]::ChangeExtension($u.file, ".err")) `
            -NoNewWindow -PassThru
        $running += @{ proc = $p; tag = $j.tag; file = $u.file; t0 = (Get-Date) }
        Say ("[run ] {0}  pid {1}  zfrac={2} seed={3} (avail {4:N1} GB)" -f `
             $j.tag, $p.Id, $env:DS_EP_ZFRAC, $env:DS_SEEDS, (AvailGB))
        Start-Sleep -Seconds 10
    }
    Start-Sleep -Seconds 15
}
Say ("[all ] {0} jobs 완료 ({1:N1} min)" -f $done, ((Get-Date) - $t0).TotalMinutes)
