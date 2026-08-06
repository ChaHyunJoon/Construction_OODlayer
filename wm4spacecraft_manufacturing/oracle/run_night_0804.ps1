# =============================================================================
# run_night_0804.ps1 -- 2026-08-03 야간: (A) NOPROG confound 확정 -> (B) sanity ladder 바닥.
#
# 왜 이 순서인가
#   A 의 결과가 B 의 해석을 바꾼다. 완주율 0% 가 DS_NOPROG=8000 캡 아티팩트였다면,
#   "harm 축 없음"(md/RELOCATEBUILD_2026-08-03.md §3-g)과 "2층 분해 퇴화"가 둘 다 잠정으로
#   돌아간다. 그래서 A 를 큐 맨 앞에 둔다.
#
#   근거(2026-08-03 측정): 같은 kind(zoneblk)·같은 발화시점(closed=58)인데
#     openworld  DS_NOPROG=30000 -> 완주 33.3% (30/90)
#     hz_k1/rb_* DS_NOPROG= 8000 -> 완주  0.0%
#   run_parallel_openworld.ps1 의 주석이 이미 경고하고 있었다:
#     "a CORRECT arm must be able to finish; 3000 mislabels Replace"
#
# 큐 (우선순위 순, 전부 재개 가능 — 이미 행이 있으면 건너뛴다)
#   A   rb_core30   : rb_core 와 **DS_NOPROG 만 다른** 재실행 (seed 301,302, zonecore frac=1.0)
#   B1  nom30       : OOD 없는 control 판 30 seed  (= sanity ladder 의 바닥칸, 완주율 ±SE 의 분모)
#   B2  lad*        : 1-OOD 를 종류별·심각도별로 (사다리 칸). 시간이 남는 만큼만 돌고 나머지는 다음에.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File oracle\run_night_0804.ps1 -Lanes 2 -MaxMinutes 420
# =============================================================================
param(
    [int]$Lanes = 2,
    [double]$MinFreeGB = 0.8,
    [int]$MaxMinutes = 420,
    [int]$NomSeeds = 30,
    [string]$Only = ""          # "A" / "B1" / "B2" 로 한 단계만 돌릴 수 있다(디버깅용)
)
$ErrorActionPreference = "Continue"
$wm   = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $wm
$gen  = Join-Path $wm "oracle\gen_oracle_dataset.jl"

# 모든 job 이 공유하는 "완주하는 세계" 설정. DS_NOPROG 는 여기 두지 않는다 — 그게 이번 변수다.
$Common = @{
    DS_SPARES    = "3"
    DS_REFORM    = "120"
    CARRIER_RESCUE = "1"
    DS_HOTSWAP   = "1"
    DS_STACK     = "1000000000"
    JULIA_NUM_THREADS = "1"
    OMP_NUM_THREADS   = "1"
    OPENBLAS_NUM_THREADS = "1"
}
# job 마다 달라지는 키. 이전 job 이 남긴 값이 새는 것을 막으려면 매번 먼저 지워야 한다.
$PerJobKeys = @("DS_EPISODE_N","DS_EP_KINDS","DS_EP_LO","DS_EP_HI","DS_EP_ZFRAC","DS_EP_CFRAC",
                "DS_EP_BSOC","DS_EP_MACROS","DS_VALID_ONLY","DS_NOCTRL","DS_NOPROG","DS_LOG",
                "DS_NOMINAL","DS_NOMINAL_ONLY","DS_KINDS","DS_ZFRACS","DS_BSOC","DS_MC_K")

$Jobs = @()

# ---- A : NOPROG confound ----------------------------------------------------
# rb_core 와 **오직 DS_NOPROG 만** 다르다(8000 -> 30000). 그래야 차이를 캡 하나로 귀속할 수 있다.
if ($Only -eq "" -or $Only -eq "A") {
    foreach ($s in @(301, 302)) {
        $Jobs += @{ tag="A_core30_s$s"; dir="rb_core30"; seed=$s; rows=2;
                    env=@{ DS_EPISODE_N="1"; DS_EP_KINDS="zonecore"; DS_EP_LO="55"; DS_EP_HI="60";
                           DS_EP_CFRAC="1.0"; DS_VALID_ONLY="1"; DS_NOCTRL="1";
                           DS_NOPROG="30000"; DS_LOG="info" } }
    }
}

# ---- B1 : nominal (OOD 없음) 30 seed ---------------------------------------
# 단위(unit) 모드에서만 동작한다 -- DS_EPISODE_N>0 이면 run_episodes 로 빠져 nominal 경로를 안 탄다.
# DS_NOCTRL 을 켜면 control 판 자체를 건너뛰므로 여기서는 **절대 켜지 않는다**.
# DS_NOMINAL=1(캡처) + DS_NOMINAL_ONLY=1(매크로 판 생략) 둘 다 필요하다.
if ($Only -eq "" -or $Only -eq "B1") {
    foreach ($s in 1..$NomSeeds) {
        $Jobs += @{ tag="B1_nom_s$s"; dir="nom30"; seed=$s; rows=1;
                    env=@{ DS_NOMINAL="1"; DS_NOMINAL_ONLY="1"; DS_KINDS="zoneblk"; DS_ZFRACS="0.9";
                           DS_NOPROG="30000" } }
    }
}

# ---- B2 : 1-OOD 사다리 칸 ---------------------------------------------------
# 종류별로 심각도를 바꿔 "무해 -> 중간 -> 심각" 칸을 만든다. 시간이 모자라면 앞쪽 칸부터 채워진다.
if ($Only -eq "" -or $Only -eq "B2") {
    $rungs = @(
        @{ tag="fault";      kinds="fault";    extra=@{} },
        @{ tag="batt0.35";   kinds="battery";  extra=@{ DS_EP_BSOC="0.35" } },   # 가벼운 열화(무해 쪽)
        @{ tag="batt0.12";   kinds="battery";  extra=@{ DS_EP_BSOC="0.12" } },   # 중간
        @{ tag="batt0.05";   kinds="battery";  extra=@{ DS_EP_BSOC="0.05" } },   # 깊은 방전(심각)
        @{ tag="zone0.0";    kinds="zoneblk";  extra=@{ DS_EP_ZFRAC="0.0" } },   # 적치 중심 정통
        @{ tag="zone0.9";    kinds="zoneblk";  extra=@{ DS_EP_ZFRAC="0.9" } },   # 가장자리(포화 구간)
        @{ tag="core0.3";    kinds="zonecore"; extra=@{ DS_EP_CFRAC="0.3" } },   # root 목표 일부
        @{ tag="core1.0";    kinds="zonecore"; extra=@{ DS_EP_CFRAC="1.0" } }    # root 목표 전부
    )
    foreach ($r in $rungs) {
        foreach ($s in @(401, 402, 403, 404)) {
            $e = @{ DS_EPISODE_N="1"; DS_EP_KINDS=$r.kinds; DS_EP_LO="55"; DS_EP_HI="60";
                    DS_VALID_ONLY="1"; DS_NOCTRL="1"; DS_NOPROG="30000" }
            foreach ($k in $r.extra.Keys) { $e[$k] = $r.extra[$k] }
            $Jobs += @{ tag=("B2_" + $r.tag + "_s$s"); dir=("lad_" + $r.tag); seed=$s; rows=2; env=$e }
        }
    }
}

function AvailGB { try { (Get-Counter '\Memory\Available MBytes' -EA Stop).CounterSamples[0].CookedValue / 1024 } catch { 99 } }
function JuliaCount { (Get-Process julia -ErrorAction SilentlyContinue | Measure-Object).Count }

$log = Join-Path $wm "oracle\out\run_night_0804.log"
function Say($m) { $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m; $line | Tee-Object -FilePath $log -Append | Out-Host }

Say ("=== NEW RUN === lanes {0} maxmin {1} jobs {2}" -f $Lanes, $MaxMinutes, $Jobs.Count)

$queue = New-Object System.Collections.Queue
$skipped = 0
foreach ($j in $Jobs) {
    $od = Join-Path $wm ("oracle\out\" + $j.dir)
    New-Item -ItemType Directory -Force $od | Out-Null
    $f = Join-Path $od ("ep_s{0}.jsonl" -f $j.seed)
    if ((Test-Path $f) -and ((Get-Content $f | Measure-Object -Line).Lines -ge $j.rows)) { $skipped++; continue }
    $queue.Enqueue(@{ job = $j; file = $f })
}
Say ("queued {0}, skipped {1} (이미 완료)" -f $queue.Count, $skipped)

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
        Say ("[stop] 마감 도달 - 남은 {0} job 은 안 띄운다(재실행하면 이어서 감)" -f $queue.Count)
        $queue.Clear()
    }
    while ($running.Count -lt $Lanes -and $queue.Count -gt 0) {
        if ((JuliaCount) -ge $Lanes) { break }
        if ((AvailGB) -lt $MinFreeGB) { Say ("[wait] RAM {0:N1} GB" -f (AvailGB)); break }
        $u = $queue.Dequeue(); $j = $u.job
        foreach ($k in $Common.Keys) { Set-Item -Path ("env:" + $k) -Value $Common[$k] }
        foreach ($k in $PerJobKeys) { Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue }
        foreach ($k in $j.env.Keys) { Set-Item -Path ("env:" + $k) -Value $j.env[$k] }
        $env:DS_SEEDS = "$($j.seed)"
        $env:DS_OUT   = $u.file
        $p = Start-Process -FilePath "julia" `
            -ArgumentList @("+lts", "--project=$repo", $gen) -WorkingDirectory $wm `
            -RedirectStandardOutput ([System.IO.Path]::ChangeExtension($u.file, ".log")) `
            -RedirectStandardError  ([System.IO.Path]::ChangeExtension($u.file, ".err")) `
            -NoNewWindow -PassThru
        $running += @{ proc = $p; tag = $j.tag; file = $u.file; t0 = (Get-Date) }
        Say ("[run ] {0}  pid {1}  noprog={2} (avail {3:N1} GB, 남은 {4})" -f `
             $j.tag, $p.Id, $env:DS_NOPROG, (AvailGB), $queue.Count)
        Start-Sleep -Seconds 10
    }
    Start-Sleep -Seconds 15
}
Say ("[all ] {0} jobs 완료 ({1:N1} h)" -f $done, ((Get-Date) - $t0).TotalHours)
