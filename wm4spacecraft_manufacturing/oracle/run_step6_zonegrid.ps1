# =============================================================================
# run_step6_zonegrid.ps1 -- STEP 6: 구역 결정의 "가지별 격자" 라벨 생성 (2026-08-05).
#
# 왜 이 스크립트가 따로 필요한가
# ------------------------------
# STEP 1·2 로 구역 결정이 **기하로** 갈리게 됐다(zone_diagnosis -> 최소수복 규칙).
# 그게 정말 결정을 가르는지는 라벨을 다시 만들어 봐야 안다. 기존 러너(run_rb_validate.ps1)는
# 팔을 [0,7] 로 고정하고 발화 시점도 한 구간(55~60)만 쓴다 -- 그러면 ForbidZone(3) 가지가
# 아예 표집되지 않는다(그 팔의 도메인은 첫 배치 경계 이후 비므로 늦게 터뜨리면 항상 0).
#
# 그래서 두 축을 함께 훑는다:
#   · 발화 시점  early(10~16, 배치 경계 前 = 국소 재적치가 가능한 구간) / late(55~60, 그 後)
#   · 구역 위치  DS_EP_ZFRAC 0.0(적치 중심 위) / 1.3(가장자리만 스침)
# 팔은 [0,3,7] 로 넓혀 **세 팔을 모두 굴린다**(DS_EP_MACROS). 그래야 "그 시점에 어떤 팔이
# 실제로 무언가를 했는가"가 라벨로 남는다.
#
# 가지 분류는 미리 예측하지 않는다 -- 생성기가 행에 기하 원시값(zone_blocked /
# zone_restage_feasible / zone_teams_covered / zone_relocatable, STEP 3)을 함께 싣으므로
# **사후에** 각 instance 가 어느 가지였는지 정확히 알 수 있다. 예측을 안 하는 쪽이 정직하다.
#
# 실행:
#   powershell -NoProfile -ExecutionPolicy Bypass -File oracle\run_step6_zonegrid.ps1 -Lanes 2 -MaxMinutes 150
# 결과: oracle\out\zgrid_0805\ep_<tag>.jsonl  (+ .log/.err)
# 재개 안전: 이미 행이 있는 job 은 건너뛴다.
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

# 세계 설정은 run_rb_validate.ps1 과 동일하게 둔다 -- 기존 zone 덤프와 같은 세계여야 비교가 성립한다.
$Common = @{
    DS_EPISODE_N = "1"
    DS_EP_KINDS  = "zoneblk"
    DS_VALID_ONLY = "1"
    DS_EP_MACROS = "0,3,7"      # 세 팔을 전부 굴린다(STEP 6 의 핵심 변경)
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

# --- job 목록: (발화구간 × 구역위치 × seed) --------------------------------------
$Jobs = @()
foreach ($fire in @(@{tag="early"; lo="10"; hi="16"}, @{tag="late"; lo="55"; hi="60"})) {
    foreach ($zf in @("0.0", "1.3")) {
        foreach ($s in @(301, 302)) {
            $Jobs += @{ tag=("{0}_zf{1}_s{2}" -f $fire.tag, $zf.Replace(".", ""), $s); seed=$s;
                        env=@{ DS_EP_ZFRAC=$zf; DS_EP_LO=$fire.lo; DS_EP_HI=$fire.hi } }
        }
    }
}

function AvailGB { try { (Get-Counter '\Memory\Available MBytes' -EA Stop).CounterSamples[0].CookedValue / 1024 } catch { 99 } }
function JuliaCount { (Get-Process julia -ErrorAction SilentlyContinue | Measure-Object).Count }

$od = Join-Path $wm "oracle\out\zgrid_0805"
New-Item -ItemType Directory -Force $od | Out-Null
$log = Join-Path $od "run.log"
function Say($m) { $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m; $line | Tee-Object -FilePath $log -Append | Out-Host }

$queue = New-Object System.Collections.Queue
foreach ($j in $Jobs) {
    $f = Join-Path $od ("ep_{0}.jsonl" -f $j.tag)
    if ((Test-Path $f) -and ((Get-Content $f | Measure-Object -Line).Lines -ge 1)) { Say ("[skip] " + $j.tag); continue }
    $queue.Enqueue(@{ job = $j; file = $f; tag = $j.tag })
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
        if ((JuliaCount) -ge $Lanes) { break }
        if ((AvailGB) -lt $MinFreeGB) { Say ("[wait] RAM {0:N1} GB" -f (AvailGB)); break }
        $u = $queue.Dequeue(); $j = $u.job
        foreach ($k in $Common.Keys) { Set-Item -Path ("env:" + $k) -Value $Common[$k] }
        foreach ($k in @("DS_EP_ZFRAC", "DS_EP_LO", "DS_EP_HI", "DS_LOG", "DS_MC_K")) {
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
        Say ("[run ] {0}  pid {1}  zfrac={2} closed∈[{3},{4}] (avail {5:N1} GB)" -f `
             $j.tag, $p.Id, $env:DS_EP_ZFRAC, $env:DS_EP_LO, $env:DS_EP_HI, (AvailGB))
        Start-Sleep -Seconds 10
    }
    Start-Sleep -Seconds 15
}
Say ("[all ] {0} jobs 완료 ({1:N1} min)" -f $done, ((Get-Date) - $t0).TotalMinutes)
