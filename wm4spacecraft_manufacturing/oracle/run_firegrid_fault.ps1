# =============================================================================
# run_firegrid_fault.ps1 -- fault 계열 라벨을 **여러 진행도에서** 다시 만든다 (2026-08-05)
#
# 왜 이걸 돌리나
# --------------
# run_firegrid.ps1 은 battery/zoneblk 만 진행도 그리드로 돌렸다. fault 는 못 돌렸는데, 이유는
# 스크립트가 아니라 **피커**였다:
#
#   `pick_solo_fault_target` / `pick_solo_frontier_target` 은 둘 다 `_first_pending_assignment` 를
#   요구한다 = "아직 안 닫힌 RobotGo 인데 선행자가 RobotStart 이거나 이미 closed" = **깨끗한 작업
#   경계**에 서 있는 로봇만 통과. 빌드가 굴러가면 로봇은 운반 사슬(FTU→TUGo→DepositCargo) 안에
#   들어가 그 경계를 스쳐 지나갈 뿐이라, closed>=80 스냅샷에서는 후보가 **0** 이다
#   (실측: oracle/out/fire_probe.csv 의 fault_* 열이 전부 0, n_frontier=0).
#
#   그래서 fault 는 언제나 closed∈{50,58} 에서만 터졌고 = progress 축이 점 하나 = novelty 교정의
#   그 축 sd 가 0.005 = 중반에 터지는 데모 사건은 종류와 무관하게 novel (LABELING_MANUAL §6).
#
# 고침: `CB.pick_hotswap_fault_target` (src/respec/ood_injection.jl). 그 술어들이 지키려던 것은
# 스케줄 재각인 경로의 `@assert has_edge(scene_tree, agent, robot_id)` 인데, 정체성 보존 HOT-SWAP 은
# id 를 유지한 채 본체만 갈아끼우므로 운반 도중 교체도 안전하다 — 엔진이 이미 같은 예외를 두 곳
# (mdp/hazard.jl `_hz_safe_target`, navigator/battery.jl)에서 쓰고 있었다. 새 피커는 "예비가 아니고
# 아직 안 닫힌 운반팀의 멤버"(= 남은 일이 있어 고장이 결과를 낳는다)를 고르며, 전 구간에서 후보가 있다.
#
# 두 lane 을 돌리는 이유 (n 늘리기가 아니라 **정답이 갈리게** 하려고)
# ------------------------------------------------------------------
#   · fault      : 희생자가 남은 운반 일을 갖고 있다 -> NOOP 이면 그 팀이 영구 정지 -> Replace 가 정답
#   · faultidle  : 같은 "fault" 라벨·같은 NL 이지만 희생자가 일이 없다 -> NOOP 이 정답
# 한쪽만 만들면 늦은 진행도의 fault 라벨이 전부 Replace 가 되어 kind 안 정답이 다시 하나가 된다.
# 두 변종을 같은 발화점 그리드에서 만들어야 "종류·시점이 아니라 상태를 읽어야 한다"가 유지된다.
#
# TIER B (full sweep) 로 돈다. DS_VALID_ONLY=1 이라 그 사건에서 **실행 가능한 매크로만** 라벨링한다
# (fault 계열 = NOOP/Replace/Deprioritize 3팔) + control 1판 = instance 당 4판. DS_MACROS 를 쓰지
# 않으므로 `calib_only=false` = 진짜 oracle 라벨이다(교정용 TIER A 행과 섞이지 않는다).
#
# 실행 (ConstructionBots.jl 저장소 루트에서):
#     pwsh -File wm4spacecraft_manufacturing/oracle/run_firegrid_fault.ps1
# 중단해도 DS_RESUME=1 이라 이어서 돈다(instance id 에 _f<closed> 가 들어가 진행도별로 따로 센다).
# =============================================================================
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))  # ConstructionBots.jl
$gen  = Join-Path $repo "wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl"
$out  = Join-Path $repo "wm4spacecraft_manufacturing/oracle/out"
New-Item -ItemType Directory -Force -Path $out | Out-Null

# =============================================================================
#  축 결정 (2026-08-05) — world 는 고정, 확률성은 시점에만
# =============================================================================
# `DS_SEEDS` 는 **로봇 초기 배치**만 바꾼다(시뮬레이터가 rng 를 쓰는 유일한 지점 =
# full_demo.jl 의 `StatsBase.sample(rng, vtxs, num_robots)`). 그 뒤는 전부 결정론적이라
# (seed, policy) 가 궤적 전체를 고정한다 — gen_oracle_dataset.jl 의 DETERMINISM 주석 참조.
#
# 즉 DS_SEEDS 를 늘리는 것은 "**다른 공장**에서 재보기"다. 그런데 이 과제의 도메인은 같은 셀에서
# 같은 우주선을 반복 제조하는 것이고, 배포 world 도 항상 seed 1(= full_demo.jl 의 기본
# `MersenneTwister(1)` = 데모가 도는 그 world)이다. 판마다 도크 위치가 달라지는 세계는 존재하지
# 않으므로, 거기에 라벨 예산을 쓰면 배포와 무관한 축을 채우게 된다.
#
# **그래서 world 는 seed 1 로 고정하고, 예산은 전부 "언제 터지는가"(DS_FIRE_GRID)에 쓴다.**
# 이 문서의 이전 판에 있던 "seed 를 30 까지 채운다"(≈51시간)는 계획은 그래서 철회했다.
#   · 확률적으로 뽑힌 시점에서의 성능은 라벨이 아니라 **평가**에서 잰다:
#     tools/monitor/run_ood_sweep.ps1 (OOD_SEED 스위프) → wm4.../ood_sweep_report.py
#   · 라벨은 그 반대여야 한다. 팔마다 **같은 사건이 같은 시점에** 터져야 반사실 비교
#     (NOOP 미완주 176 vs Replace 완주 291)가 성립하므로, 발화 시점은 무작위가 아니라 격자다.
# =============================================================================
$common = @{
    DS_RESUME     = "1"
    DS_REFORM     = "120"     # 데모와 같은 배경 복구 주기
    DS_HOTSWAP    = "1"       # 데모와 같은 세계(정체성 보존 교체). 새 피커의 안전 근거이기도 하다.
    DS_VALID_ONLY = "1"       # 그 사건에서 유효한 팔만(fault 계열 = 0/1/2) → calib_only 는 false 로 유지
    DS_FAULT_PICK = "auto"    # 기존 3피커 → 전부 실패하면 hot-swap 피커(중반 이후 담당)
    DS_SPARES     = "3"
    DS_NOPROG     = "8000"    # CANONICAL 덤프와 같은 캡(섞으면 완주율이 설정의 함수가 된다)
}

# 발화 가능 구간은 추측이 아니라 측정이다: oracle/out/fire_probe_hotswap.csv 의 n_hotswap 열.
# closed 280 은 후보가 진짜 0 이다(남은 운반 일이 없다) — 그래서 격자는 260 에서 끝난다.
#
# 격자 조밀화 (6 점 → 11 점). 기존 6 점은 이미 라벨이 있으므로 DS_RESUME=1 이 그대로 건너뛰고,
# 새로 도는 것은 사이에 낀 80/120/160/200/240 뿐이다.
$FIRE_FAULT = "58,80,100,120,140,160,180,200,220,240,260"
# battery 는 **정답이 뒤집히는 구간**을 집중해서 뚫는다. seed 1 은 progress 0.447(closed 140)에서
# 아직 Replace 가 필요했고 seed 2 는 0.450 에서 이미 흡수됐다 = 경계가 0.45~0.58 사이 어딘가인데
# 6 점 격자로는 그 구간에 점이 하나도 없다. 140~180 을 10 노드 간격으로 채운다.
#
# 주의: 기존 6 점은 **요청값** 58/100/140/180/220/260 으로 라벨돼 있다(instance id 에 요청값이
# 들어간다 — 실제 발화는 배치 경계 때문에 181/222 로 어긋나 보고서에 그렇게 찍힌 것뿐이다).
# 여기서 181/222 를 쓰면 같은 판을 이름만 바꿔 한 번 더 돌리게 되므로 요청값 쪽에 맞춘다.
$FIRE_BATT  = "58,100,140,150,160,170,180,200,220,260"

$lanes = @(
    # world 는 전 lane 고정(DS_SEEDS=1). 이 값을 바꾸면 위 "축 결정" 주석을 먼저 읽을 것.
    @{ name = "fault";     env = @{ DS_KINDS = "fault";     DS_SEEDS = "1"; DS_FIRE_GRID = $FIRE_FAULT } },
    @{ name = "faultidle"; env = @{ DS_KINDS = "faultidle"; DS_SEEDS = "1"; DS_FIRE_GRID = $FIRE_FAULT } },
    # battery TIER B: deep(0.05) 은 Replace↔NOOP 이 뒤집히는 팔, mild(0.35) 는 동점 대조군.
    @{ name = "battB";     env = @{ DS_KINDS = "battery";   DS_SEEDS = "1"; DS_FIRE_GRID = $FIRE_BATT;
                                    DS_BSOC = "0.05,0.35" } }
)

# 순차 실행이 기본이다 (2026-08-05 실측). 두 lane 을 병렬로 돌렸더니 4번째 instance 에서
#   ERROR: LoadError: OutOfMemoryError()  @ run_with_stack (gen_oracle_dataset.jl)
# 가 났다. 판 하나마다 `DS_STACK`(기본 2GB) 스택을 통째로 잡으므로 프로세스 2개 = 4GB 예약인데,
# 편집기/파이썬 서비스가 이미 메모리를 쥐고 있으면 16GB 머신에서도 모자란다. 다행히 DS_RESUME=1
# 덕에 죽은 지점부터 이어지지만, 몇십 분을 날린다. 정말 병렬이 필요하면 $env:FG_PARALLEL=1 로 켜되
# 남은 물리 메모리를 먼저 확인할 것(lane 당 최소 2.5GB 여유).
$parallel = ($env:FG_PARALLEL -eq "1")

$jobs = @()
foreach ($lane in $lanes) {
    $name = $lane.name
    # PS 5.1: 해시테이블은 `+` 로 못 이으므로 새 해시에 복사해 합친다.
    $merged = @{}
    foreach ($h in @($common, $lane.env)) { foreach ($k in $h.Keys) { $merged[$k] = $h[$k] } }
    $envAssign = ($merged.Keys | ForEach-Object { "`$env:$_='$($merged[$_])'" }) -join "; "
    # 이름은 `firegrid_s<lane>.jsonl` 로 맞춘다 — merge_firegrid.py 의 기본 glob 이 `firegrid_s*.jsonl` 이라
    # 이 규칙을 벗어나면 병합에서 조용히 빠진다.
    $file = Join-Path $out "firegrid_s$name.jsonl"
    $log  = Join-Path $out "firegrid_s$name.log"
    $cmd  = "$envAssign; `$env:DS_OUT='$file'; " +
            "julia +lts --project='$repo' '$gen' *>&1 | Tee-Object -FilePath '$log'"
    Write-Host "[firegrid-fault] lane=$name -> $file"
    if ($parallel) {
        $jobs += Start-Job -ScriptBlock ([scriptblock]::Create($cmd))
    } else {
        # 순차: 한 lane 을 끝까지 돌리고 다음으로. 메모리 사고가 안 나고, 중간에 죽어도 DS_RESUME 로 이어진다.
        & powershell -NoProfile -Command $cmd
    }
}
if ($parallel) {
    Write-Host "[firegrid-fault] $($jobs.Count) lanes running in PARALLEL (메모리 주의)"
    $jobs | Wait-Job | Out-Null
    $jobs | ForEach-Object { Receive-Job $_ | Select-Object -Last 5 }
}
Write-Host "[firegrid-fault] done. 다음: python merge_firegrid.py; python export_novelty_calibration.py ..."
