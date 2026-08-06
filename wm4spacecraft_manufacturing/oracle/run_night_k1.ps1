# =============================================================================
# run_night_k1.ps1 -- 에피소드 모드 야간 생성기 (창 [55,130], K=1, valid-only).
#
# 왜 이 스크립트인가
#   run_parallel.ps1 은 **단일사건 유닛 모드**용이다. DS_EP_LO/HI 는 에피소드 모드
#   (DS_EPISODE_N>0)에서만 동작하므로 창 교정 실험에는 쓸 수 없다.
#
# 왜 K=1 인가 (2026-08-02 실측)
#   판당 벽시계가 ~14분이다. K=3(hazard ON)이면 seed 당 18판 = 4.2시간 -> 하룻밤에
#   seed 4개(= instance 12개)뿐이라 어떤 검정도 불가능하다. K=1 은 seed 당 6판 = 1.4시간
#   이므로 같은 시간에 instance 를 3배 얻는다. hazard 의 확률성은 별도 seed 하나
#   (hz_v1/smoke_s102, K=3)로 따로 증거를 남긴다.
#
# 재개 가능: 이미 6행 이상인 seed 는 건너뛴다. Ctrl-C 후 다시 실행하면 이어서 돈다.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File oracle\run_night_k1.ps1 `
#       -Seeds 201-230 -Lanes 2 -Out oracle\out\hz_k1
# =============================================================================
param(
    [string]$Seeds = "201-230",
    [int]$Lanes    = 2,
    [string]$Out   = "oracle\out\hz_k1",
    [double]$MinFreeGB = 1.5,
    [int]$RowsDone = 6,             # seed 당 기대 행수 (3 결정 x 2 유효팔 x K1)
    [int]$Episodes = 3,             # 에피소드당 계획 사건 수. 완주율을 좌우한다(아래 주석)
    [int]$EpLo = 55,
    [int]$EpHi = 130,
    [string]$Kinds = "fault,battery,zoneblk",   # 생성할 사건 종류
    [int]$MaxMinutes = 0,           # >0 이면 이 시간이 지난 뒤에는 **새 seed 를 띄우지 않는다**
                                    # (진행 중인 것은 끝까지 간다). 아침 분석 시간을 확보하는 용도.
    [string]$ThenRun = ""           # 풀이 모두 비면 실행할 명령(분석 파이프라인)
)
# 종류 선택에 관한 실측(2026-08-03 00:40, 창[55,130] 75 instance):
#   fault   n=24  결정적 83%   정답 Replace 12 : NOOP 8
#   battery n=20  결정적 85%   정답 Replace 14 : NOOP 3
#   zoneblk n=33  결정적  0%   <- NOOP 과 ForbidZone 의 closed 가 **완전히 동일**(조용한 no-op)
# zoneblk 를 섞으면 결정정보 0인 행이 44% 들어온다. 결정적 표본을 모으는 국면에서는 빼는 게 맞다.
# 사건 수와 완주율: 사건이 많을수록 빌드가 회복하지 못해 완주율이 떨어지고, 완주율이 떨어지면
# 평가셋은 "누가 완주하나"가 아니라 "누가 더 늦게 죽나"를 재게 된다(2층 분해가 p≡0 으로 퇴화).
# 그래서 3-사건 설정과 2-사건 설정을 **짝으로** 돌려 아침에 비교할 수 있게 한다.

$ErrorActionPreference = "Continue"
$wm   = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $wm
$gen  = Join-Path $wm "oracle\gen_oracle_dataset.jl"
$OutDir = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $wm $Out }
New-Item -ItemType Directory -Force $OutDir | Out-Null

$SeedList = @()
foreach ($part in ($Seeds -split ",")) {
    $p = $part.Trim()
    if ($p -match '^(\d+)\s*-\s*(\d+)$') { $SeedList += [int]$matches[1]..[int]$matches[2] }
    elseif ($p -match '^\d+$')           { $SeedList += [int]$p }
}

# --- 공통 환경 ---------------------------------------------------------------
# DS_NOPROG=8000 : 무진행 상한. 30000 으로 두면 실패 팔이 판당 30분 넘게 끌어 예산이 3배가 된다
#                  (2026-08-02 실측). 8000 은 생성기 기본값.
# DS_MC_K 미설정  : 1 = hazard 프로세스 꺼짐 = 결정론 라벨(그 세계에서는 1판이 정확한 Q).
$Common = @{
    DS_EPISODE_N = "$Episodes"
    DS_EP_KINDS  = "$Kinds"
    DS_EP_LO     = "$EpLo"       # 함정 17: 배치 경계 58 아래로 내리면 사건이 한 스텝에 몰린다
    DS_EP_HI     = "$EpHi"       # 함정 18: 더 늦추면 fault 타깃이 사라지고 동점률이 치솟는다
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

function AvailGB {
    try { (Get-Counter '\Memory\Available MBytes' -EA Stop).CounterSamples[0].CookedValue / 1024 }
    catch { 99 }
}
function JuliaCount { (Get-Process julia -ErrorAction SilentlyContinue | Measure-Object).Count }

$queue = New-Object System.Collections.Queue
$skipped = 0
foreach ($s in $SeedList) {
    $f = Join-Path $OutDir ("ep_s{0}.jsonl" -f $s)
    if ((Test-Path $f) -and ((Get-Content $f | Measure-Object -Line).Lines -ge $RowsDone)) {
        $skipped++; continue
    }
    $queue.Enqueue(@{ seed = $s; file = $f })
}
$log = Join-Path $OutDir "run_night_k1.log"
function Say($m) {
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m
    $line | Tee-Object -FilePath $log -Append | Out-Host
}
Say ("queued {0} seeds, {1} already done, lanes {2}, out={3}" -f $queue.Count, $skipped, $Lanes, $OutDir)
Say ("추정 소요: seed 당 ~1.4h (6판 x 14분) / {0} lane" -f $Lanes)

$running = @()
$done = 0
$t0 = Get-Date
while ($queue.Count -gt 0 -or $running.Count -gt 0) {
    $still = @()
    foreach ($r in $running) {
        if ($r.proc.HasExited) {
            $rows = if (Test-Path $r.file) { (Get-Content $r.file | Measure-Object -Line).Lines } else { 0 }
            $done++
            Say ("[done] seed {0}  {1:N1} min  {2} rows" -f $r.seed, ((Get-Date) - $r.t0).TotalMinutes, $rows)
        } else { $still += $r }
    }
    $running = $still

    # 마감 시각이 지나면 새 seed 를 띄우지 않는다(진행 중인 것은 끝까지). 분석 시간 확보용.
    if ($MaxMinutes -gt 0 -and ((Get-Date) - $t0).TotalMinutes -ge $MaxMinutes -and $queue.Count -gt 0) {
        Say ("[stop] 마감({0}분) 도달 — 남은 {1} seed 는 띄우지 않는다(재실행하면 이어서 감)" -f $MaxMinutes, $queue.Count)
        $queue.Clear()
    }

    # 이 스크립트 밖에서 도는 julia(= hazard seed)도 자리를 차지한다. 총 동시 julia 를 Lanes 로 제한.
    while ($running.Count -lt $Lanes -and $queue.Count -gt 0) {
        if ((JuliaCount) -ge $Lanes) { break }
        if ((AvailGB) -lt $MinFreeGB) { Say ("[wait] RAM {0:N1} GB" -f (AvailGB)); break }
        $u = $queue.Dequeue()
        foreach ($k in $Common.Keys) { Set-Item -Path ("env:" + $k) -Value $Common[$k] }
        Remove-Item env:DS_MC_K -ErrorAction SilentlyContinue      # K=1 (hazard OFF)
        $env:DS_SEEDS = "$($u.seed)"
        $env:DS_OUT   = $u.file
        $p = Start-Process -FilePath "julia" `
            -ArgumentList @("+lts", "--project=$repo", $gen) `
            -WorkingDirectory $wm `
            -RedirectStandardOutput ([System.IO.Path]::ChangeExtension($u.file, ".log")) `
            -RedirectStandardError  ([System.IO.Path]::ChangeExtension($u.file, ".err")) `
            -NoNewWindow -PassThru
        $running += @{ proc = $p; seed = $u.seed; file = $u.file; t0 = (Get-Date) }
        Say ("[run ] seed {0}  pid {1}  (avail {2:N1} GB, julia {3}개)" -f $u.seed, $p.Id, (AvailGB), (JuliaCount))
        Start-Sleep -Seconds 20
    }
    Start-Sleep -Seconds 20
}
Say ("[all ] {0} seeds 완료 ({1:N1} h)" -f $done, ((Get-Date) - $t0).TotalHours)

# 생성이 끝나면 분석을 이어서 돌린다. 사람이 자는 동안 "데이터만 쌓이고 아무도 안 본" 상태를
# 만들지 않기 위한 것 — 아침에는 리포트가 이미 있어야 한다.
if ($ThenRun -ne "") {
    Say ("[then] $ThenRun")
    $env:PYTHONIOENCODING = "utf-8"
    try {
        Push-Location $wm
        & cmd /c $ThenRun 2>&1 | Tee-Object -FilePath $log -Append | Out-Host
        Say ("[then] 완료 (exit $LASTEXITCODE)")
    } catch {
        Say ("[then] 실패: $_")
    } finally { Pop-Location }
}
