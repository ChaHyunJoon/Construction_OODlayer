# =============================================================================
# run_firegrid.ps1 -- 발화 시점을 흩뿌린 라벨 생성 (2026-08-04)
#
# 왜 이걸 돌리나
# --------------
# CANONICAL 덤프(openworld_merged.jsonl)의 60 instance 는 `closed_at_fire` 가 {50,58} 두 값뿐이다.
# FIRE_POINTS 가 grid 가 아니라 **재시도 사다리**인데 tractor 가 첫 배치에서 이미 ~58 노드를 닫아
# 사다리 전체가 같은 순간에 due 가 되기 때문이다. 그 결과 novelty 교정의 `progress` 축 sd 가
# 0.005 가 되고, 중반에 터지는 데모 battery(progress 0.41)가 **종류와 무관하게** novel 로 판정된다.
#
# 이 스크립트는 DS_FIRE_GRID 로 발화 시점을 instance 차원으로 올려 그 축에 실제 분산을 넣는다.
#
# 발화 가능 구간은 추측이 아니라 측정이다 (oracle/out/fire_probe.csv, probe_fire_points.jl):
#     battery : closed 58~280 전 구간 가능 (대상 로봇 2~10대)
#     zoneblk : closed 58~220 (막을 pending staging 원이 8→3개로 감소)
#     fault   : closed 58~60 에서만 가능. 80 이상에서는 **안전한 대상이 아예 없다**
#               (single/solo/frontier 피커 전부 nothing) -> fault 는 진행도 분산에 기여 불가.
#               이건 피커의 한계이지 이 스크립트의 한계다: 후반 fault 를 원하면 엔진 쪽
#               (pick_solo_* / fault_action safe 조건)을 먼저 고쳐야 한다.
#
# TIER A (기본, 여기서 돌리는 것) -- DS_MACROS=0 DS_NOCTRL=1
#   novelty 교정은 **결정 순간의 상태 서술자만** 읽는다(라벨을 안 읽는다). 그래서 교정을 고치는 데는
#   매크로 스윕이 필요 없고 instance 당 판 하나면 된다 = 6배 싸다. 이렇게 만든 행은
#   `calib_only=true` 로 표시되어 oracle 라벨로 오용되지 않는다.
#
# TIER B (선택, 훨씬 비쌈) -- DS_MACROS/DS_NOCTRL 없이 같은 그리드로 다시
#   surrogate 까지 새 진행도에서 학습시키려면 필요하다. 교정만 고치면 라우터는 "익숙하다"고 말하는데
#   정작 surrogate 는 그 진행도의 학습 근거가 없는 상태가 된다 -- 그건 게이트가 막으려던 바로 그 상황이다.
#   $env:TIER_B = "1" 로 이 스크립트를 돌리면 전체 스윕으로 간다.
#
# 실행 (ConstructionBots.jl 저장소 루트에서):
#     pwsh -File wm4spacecraft_manufacturing/oracle/run_firegrid.ps1
# =============================================================================
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))  # ConstructionBots.jl
$gen  = Join-Path $repo "wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl"
$out  = Join-Path $repo "wm4spacecraft_manufacturing/oracle/out"
New-Item -ItemType Directory -Force -Path $out | Out-Null

$tierB = ($env:TIER_B -eq "1")
$common = @{
    DS_RESUME  = "1"          # 중단해도 이어서. instance id 에 _f<closed> 가 들어가 진행도별로 따로 센다.
    DS_REFORM  = "120"
    DS_HOTSWAP = "1"          # 데모와 같은 세계에서 라벨링(정체성 보존 hot-swap)
}
if (-not $tierB) { $common["DS_MACROS"] = "0"; $common["DS_NOCTRL"] = "1" }

# lane = (이름, 환경변수 해시). 두 lane 을 **병렬**로 돌린다. 프로세스당 DS_STACK(2GB)을 통째로 잡으므로
# 16GB 머신에서 3개 이상은 OutOfMemoryError 가 난다(저장소 실측). 2개까지만.
# severity 사다리는 CANONICAL 에 **이미 있는 범위 안**으로 고른다. 이 실험은 발화 시점 하나만
# 바꾸는 것이므로, 심각도까지 넓히면 두 변수를 동시에 바꾸는 셈이 된다. 구체적으로 soc=0.6(=
# resource_loss 0.40)을 넣으면 resource_loss 축의 sd 가 넓어지는데, 그 축은 "로봇 사건 vs 공간
# 사건"을 담는 유일한 축이라(features_agnostic.py 주석) LOKO 교정에서 zone 이 novel 로 남는 근거다.
# CANONICAL 의 battery resource_loss 는 [0.65, 0.95] -> soc 0.05/0.2/0.35 가 그 범위 안이다.
$lanes = @(
    @{ name = "batt"; env = @{ DS_KINDS = "battery"; DS_SEEDS = "1,2"; DS_BSOC = "0.05,0.2,0.35";
                               DS_FIRE_GRID = "58,100,140,180,220,260" } },
    @{ name = "zone"; env = @{ DS_KINDS = "zoneblk"; DS_SEEDS = "1"; DS_ZFRACS = "0.5,0.9,1.3";
                               DS_FIRE_GRID = "58,100,140,180" } }
)

$jobs = @()
foreach ($lane in $lanes) {
    $name = $lane.name
    # 두 해시테이블을 합친다. PS 5.1 에서는 .GetEnumerator() 결과를 `+` 로 이을 수 없으므로
    # 새 해시에 복사한다(그냥 이으면 "op_Addition 없음" 파서 오류).
    $merged = @{}
    foreach ($h in @($common, $lane.env)) { foreach ($k in $h.Keys) { $merged[$k] = $h[$k] } }
    $envAssign = ($merged.Keys | ForEach-Object { "`$env:$_='$($merged[$_])'" }) -join "; "
    $file = Join-Path $out "firegrid_s$name.jsonl"
    $log  = Join-Path $out "firegrid_s$name.log"
    $cmd  = "$envAssign; `$env:DS_OUT='$file'; " +
            "julia +lts --project='$repo' '$gen' *>&1 | Tee-Object -FilePath '$log'"
    Write-Host "[firegrid] lane=$name -> $file"
    $jobs += Start-Job -ScriptBlock ([scriptblock]::Create($cmd))
}
Write-Host "[firegrid] $($jobs.Count) lanes running (tier $(if ($tierB) {'B: full sweep'} else {'A: descriptors only'}))"
$jobs | Wait-Job | Out-Null
$jobs | ForEach-Object { Receive-Job $_ | Select-Object -Last 5 }

Write-Host "`n[firegrid] merging + refitting calibration"
Push-Location (Join-Path $repo "wm4spacecraft_manufacturing")
python merge_firegrid.py
python export_novelty_calibration.py oracle/out/firegrid_merged.jsonl --out=novelty_calibration.json
python export_novelty_calibration.py oracle/out/firegrid_merged.jsonl --exclude=zoneblk --out=novelty_calibration_no_zoneblk.json
python verify_router_calibration.py novelty_calibration_no_zoneblk.json
Pop-Location
