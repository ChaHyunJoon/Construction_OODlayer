# =============================================================================
# run_ood_sweep.ps1 -- **무작위 OOD 스트림 스위프** (2026-08-05)
#
# 무엇을 재는가
# -------------
# "어느 시점에 어떤 고장이 나든 적응하는가" 를 실제로 측정하는 실험. 지금까지 저장소의 모든
# 평가는 사건 시점을 **고정**해 두고 돌렸다(오라클 라벨은 DS_FIRE_GRID 격자, 데모는 슬롯
# [0.10, 0.32, 0.55]). 그래서 "적응적"이라는 주장의 근거가 사실은 한두 개의 대본이었다.
#
# 이 스크립트는 축을 둘로 분리한다:
#
#   world (DEMO_SEED)      = 로봇 초기 배치 = **공장**.  같은 셀에서 같은 우주선을 반복 제조하는
#                            도메인이므로 **1 로 고정**한다. 판마다 도크 위치가 달라지는 것은
#                            제조 일관성 자체를 흔드는 것이고, 배포 세계와도 어긋난다.
#   OOD_SEED               = 언제 · 어떤 사건이 · 얼마나 심하게 = **확률성**. 이것만 스위프한다.
#
# 각 (ood_seed, policy) 조합마다 tools/monitor/run_demo.jl 을 한 판 돌리고, 그 결과 한 줄
# (완주 여부 · closed · 사건별 결정)을 DEMO_SUMMARY JSONL 에 덧붙인다. 분석은
#   python wm4spacecraft_manufacturing/ood_sweep_report.py
#
# 정책
# ----
#   noop       개입 안 함 = 바닥선. 이게 없으면 완주율 비교의 분모가 없다.
#   canonical  규칙 lookup = 상한선(정답 규칙을 이미 아는 정책)
#   surrogate  배포 RandomForest  ┐ 파이썬 서비스 필요:
#   dspy       MIPROv2 컴파일 LLM ┘  python src/respec/llm_service/dspy_service.py (포트 8077)
#   router     라우터 ON(낯설면 LLM, 익숙하면 surrogate). 서비스 필요.
#
# **정책 비교에서는 라우터를 끈다**(DEMO_ROUTER=0). 안 그러면 라우터가 정책을 갈아치워서
# "surrogate 를 쟀다"는 판이 사실은 LLM 판이 된다. 라우터 자체를 재려면 policy=router 를 쓴다.
#
# 실행 (저장소 루트에서)
#   pwsh -File tools/monitor/run_ood_sweep.ps1
#   $env:SWEEP_SEEDS="1,2,3,4,5"; $env:SWEEP_POLICIES="noop,canonical"; pwsh -File ...
#
# ENV
#   SWEEP_SEEDS     쉼표목록 (기본 1..20)
#   SWEEP_POLICIES  쉼표목록 (기본 noop,canonical)   ※ surrogate/dspy/router 는 서비스 필요
#   SWEEP_OUT       요약 JSONL (기본 wm4spacecraft_manufacturing/results/ood_sweep.jsonl)
#   SWEEP_CASE      DEMO_OOD (기본 fault_battery = 두 종류가 섞인 스트림)
#   SWEEP_N         판당 사건 수 (기본 4)
#   SWEEP_SPARES    예비 로봇 수 (기본 3 = 오라클 라벨러의 DS_SPARES 와 일치)
#   SWEEP_RESUME    1(기본) = 요약에 이미 있는 (seed, policy) 는 건너뜀
# =============================================================================
$ErrorActionPreference = "Stop"
# .../ConstructionBots.jl/tools/monitor/run_ood_sweep.ps1 -> 세 단계 위가 저장소 루트
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
$runner = Join-Path $repo "tools/monitor/run_demo.jl"

function _env_or($name, $default) {
    $v = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $default } else { return $v }
}

$seeds    = (_env_or "SWEEP_SEEDS" (1..20 -join ",")).Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$policies = (_env_or "SWEEP_POLICIES" "noop,canonical").Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$outPath  = _env_or "SWEEP_OUT" (Join-Path $repo "wm4spacecraft_manufacturing/results/ood_sweep.jsonl")
$case     = _env_or "SWEEP_CASE" "fault_battery"
$nEvents  = _env_or "SWEEP_N" "4"
$spares   = _env_or "SWEEP_SPARES" "3"
$resume   = (_env_or "SWEEP_RESUME" "1") -eq "1"

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
# 스트림은 sweep 전용 폴더로 보낸다. 기본 경로(streams/tractor__fault.jsonl)를 쓰면 대시보드가
# 읽는 **녹화 데모 스트림을 덮어쓴다** -- 이 스위프는 수십 판을 돌리므로 반드시 분리한다.
$streamDir = Join-Path $repo "tools/monitor/streams/sweep"
New-Item -ItemType Directory -Force -Path $streamDir | Out-Null

# ---- 이미 돈 조합 건너뛰기 ---------------------------------------------------------------
$done = New-Object System.Collections.Generic.HashSet[string]
if ($resume -and (Test-Path $outPath)) {
    foreach ($line in Get-Content $outPath) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $r = $line | ConvertFrom-Json
            [void]$done.Add("$($r.ood_seed)|$($r.policy)|$($r.router)")
        } catch { }
    }
    Write-Host "[sweep] resume: 요약에 이미 $($done.Count) 판이 있음 -> 건너뜀"
}

$total = $seeds.Count * $policies.Count
$i = 0
$t0 = Get-Date
foreach ($seed in $seeds) {
    foreach ($pol in $policies) {
        $i++
        # policy=router : 라우터를 켜고 시작 정책만 surrogate 로 둔다(라우터가 사건마다 갈아탄다).
        $demoPolicy = if ($pol -eq "router") { "surrogate" } else { $pol }
        $routerMode = if ($pol -eq "router") { "1" } else { "0" }
        $key = "$seed|$demoPolicy|$routerMode"
        if ($done.Contains($key)) { Write-Host "[sweep] ($i/$total) skip seed=$seed policy=$pol"; continue }

        $stream = Join-Path $streamDir "s$($seed)_$($pol).jsonl"
        # 규칙/바닥선 판은 다른 정책의 비교값을 수집하지 않는다(= 파이썬 서비스 호출 0회).
        $allPolicies = "1"
        if ($pol -eq "noop" -or $pol -eq "canonical") { $allPolicies = "0" }
        $envAssign = @(
            "`$env:DEMO_MODEL='tractor.mpd'",
            "`$env:DEMO_OOD='$case'",
            "`$env:DEMO_N='$nEvents'",
            "`$env:DEMO_SPARES='$spares'",
            "`$env:DEMO_SEED='1'",              # world 고정 = 같은 공장/같은 제품
            "`$env:DEMO_OOD_SEED='$seed'",      # 확률성만 스위프
            "`$env:DEMO_POLICY='$demoPolicy'",
            "`$env:DEMO_ROUTER='$routerMode'",
            "`$env:DEMO_ALL_POLICIES='$allPolicies'",
            # 루트 엔드게임 교착 복구. 이게 없으면 완주 실패가 정책 탓인지 교착 탓인지 구분이 안 된다.
            "`$env:DEMO_REFORM='120'",
            "`$env:MONITOR_STREAM='$stream'",
            "`$env:DEMO_SUMMARY='$outPath'"
        ) -join "; "

        $log = Join-Path $streamDir "s$($seed)_$($pol).log"
        Write-Host "[sweep] ($i/$total) seed=$seed policy=$pol -> $stream"
        $cmd = "$envAssign; julia +lts --project='$repo' '$runner' *>&1 | Tee-Object -FilePath '$log'"
        & powershell -NoProfile -Command $cmd
        if ($LASTEXITCODE -ne 0) { Write-Warning "[sweep] seed=$seed policy=$pol 이 0 이 아닌 코드로 종료($LASTEXITCODE) — 로그: $log" }
    }
}

$mins = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)
Write-Host "`n[sweep] done in $mins min -> $outPath"
Write-Host "[sweep] 다음: python wm4spacecraft_manufacturing/ood_sweep_report.py"
