# =============================================================================
# run_rb_validate.ps1 -- RelocateBuild(매크로 7) 검증 실행기 (2026-08-03).
#
# run_night_k1.ps1 은 "seed 하나 = job 하나"라서 **심각도(offset)를 seed 마다 다르게** 줄 수 없다.
# 이 스크립트는 (seed, DS_EP_ZFRAC, 팔목록, 로그레벨)을 job 단위로 지정한다.
#
# 두 가지를 잰다:
#   1) diag  -- DS_LOG=info 로 팔 7 만 한 판. [WHOLE-BUILD] / [RESPEC] 로그를 남겨 **엔진이 실제로
#               평행이동을 채택했는지(:admitted)** 를 눈으로 확인한다. 행 데이터만으로는 "왜 그런지"를
#               알 수 없다(dispatch 가 fallback 을 걸어도 행은 똑같이 나온다).
#   2) grad  -- 같은 seed 를 offset(=zone 이 적치 중심에서 얼마나 비켜났나) 여러 값으로 돌려,
#               정답 팔이 심각도에 따라 **뒤집히는지** 본다. 뒤집히지 않으면 zone 종류는
#               "종류만 보면 되는" 문제라 상태를 읽는 서로게이트가 값을 못 한다.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File oracle\run_rb_validate.ps1 -Lanes 2
# =============================================================================
param(
    [int]$Lanes = 2,
    [double]$MinFreeGB = 0.8,
    [int]$MaxMinutes = 0
)
$ErrorActionPreference = "Continue"
$wm   = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $wm
$gen  = Join-Path $wm "oracle\gen_oracle_dataset.jl"

# 모든 job 이 공유하는 설정 — hz_k1(기존 데이터셋)과 같은 세계여야 비교가 성립한다.
$Common = @{
    DS_EPISODE_N = "1"
    DS_EP_KINDS  = "zoneblk"
    DS_EP_LO     = "55"
    DS_EP_HI     = "60"
    DS_VALID_ONLY = "1"
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

# --- job 목록 ---------------------------------------------------------------
# diag 를 맨 앞에 둔다: 가장 답이 급한 질문(엔진이 정말 채택했나)을 가장 먼저 끝내기 위해.
$Jobs = @()
$Jobs += @{ tag="diag_s301"; dir="rb_diag"; seed=301;
            env=@{ DS_EP_ZFRAC="0.9"; DS_EP_MACROS="7"; DS_LOG="info" } }
# seed 303·304 는 2차(top-up)로 추가했다. 이미 행이 있는 job 은 아래에서 건너뛰므로
# 이 스크립트를 다시 돌리면 **새 job 만** 돈다(재개 안전).
foreach ($zf in @("0.0", "1.3")) {
    foreach ($s in @(301, 302, 303, 304)) {
        $Jobs += @{ tag=("zf{0}_s{1}" -f $zf, $s); dir=("rb_zf" + $zf.Replace(".", "")); seed=$s;
                    env=@{ DS_EP_ZFRAC=$zf } }
    }
}

function AvailGB { try { (Get-Counter '\Memory\Available MBytes' -EA Stop).CounterSamples[0].CookedValue / 1024 } catch { 99 } }
function JuliaCount { (Get-Process julia -ErrorAction SilentlyContinue | Measure-Object).Count }

$log = Join-Path $wm "oracle\out\run_rb_validate.log"
function Say($m) { $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m; $line | Tee-Object -FilePath $log -Append | Out-Host }

$queue = New-Object System.Collections.Queue
foreach ($j in $Jobs) {
    $od = Join-Path $wm ("oracle\out\" + $j.dir)
    New-Item -ItemType Directory -Force $od | Out-Null
    $f = Join-Path $od ("ep_s{0}.jsonl" -f $j.seed)
    # 재개: 이미 행이 있으면 건너뛴다(Ctrl-C 후 재실행 안전).
    if ((Test-Path $f) -and ((Get-Content $f | Measure-Object -Line).Lines -ge 1)) { Say ("[skip] " + $j.tag); continue }
    $queue.Enqueue(@{ job = $j; file = $f })
}
Say ("queued {0} jobs, lanes {1}" -f $queue.Count, $Lanes)

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
        Say ("[stop] 마감 도달 — 남은 {0} job 은 띄우지 않는다" -f $queue.Count); $queue.Clear()
    }
    while ($running.Count -lt $Lanes -and $queue.Count -gt 0) {
        # 이 스크립트 밖에서 도는 julia(직전 풀의 잔여 seed)도 자리를 차지한다.
        if ((JuliaCount) -ge $Lanes) { break }
        if ((AvailGB) -lt $MinFreeGB) { Say ("[wait] RAM {0:N1} GB" -f (AvailGB)); break }
        $u = $queue.Dequeue(); $j = $u.job
        foreach ($k in $Common.Keys) { Set-Item -Path ("env:" + $k) -Value $Common[$k] }
        # job 마다 다른 값. 이전 job 이 남긴 값이 새는 것을 막기 위해 매번 먼저 지운다.
        foreach ($k in @("DS_EP_ZFRAC", "DS_EP_MACROS", "DS_LOG", "DS_MC_K")) {
            Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue
        }
        foreach ($k in $j.env.Keys) { Set-Item -Path ("env:" + $k) -Value $j.env[$k] }
        $env:DS_SEEDS = "$($j.seed)"
        $env:DS_OUT   = $u.file
        $p = Start-Process -FilePath "julia" `
            -ArgumentList @("+lts", "--project=$repo", $gen) -WorkingDirectory $wm `
            -RedirectStandardOutput ([System.IO.Path]::ChangeExtension($u.file, ".log")) `
            -RedirectStandardError  ([System.IO.Path]::ChangeExtension($u.file, ".err")) `
            -NoNewWindow -PassThru
        $running += @{ proc = $p; tag = $j.tag; file = $u.file; t0 = (Get-Date) }
        # PowerShell 5.1 에는 ?? (null 병합) 연산자가 없다 — if/else 로 쓴다.
        $macroTxt = if ([string]::IsNullOrEmpty($env:DS_EP_MACROS)) { "valid" } else { $env:DS_EP_MACROS }
        Say ("[run ] {0}  pid {1}  zfrac={2} macros={3} (avail {4:N1} GB)" -f `
             $j.tag, $p.Id, $env:DS_EP_ZFRAC, $macroTxt, (AvailGB))
        Start-Sleep -Seconds 10
    }
    Start-Sleep -Seconds 15
}
Say ("[all ] {0} jobs 완료 ({1:N1} min)" -f $done, ((Get-Date) - $t0).TotalMinutes)
