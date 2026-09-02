# =============================================================================
# **battery 사건이 payload/함대 사실을 싣는가.** (2026-08-31, S1/T2)
#
# 이 게이트는 세계를 짓지 않는다 — `_battery_load_features` 는 `(env, agent)` 만 보는
# 함수이므로 최소 fixture 로 잰다. 진짜 빌드에서의 값은 T5 의 보드가 낸다.
#
# ⚠️ **여기 없는 것** (Fix round 1, I-3 — 가짜 세계를 짓지 않는다. 이름만 붙여 정직하게
#    비워 둔다): `battery_pending_transports`/`battery_payload_proxy_max`/`battery_payload_proxy_total`
#    를 내는 운반 작업 순회(`_battery_load_features` 의 `for v in Graphs.vertices(sched)` 루프)
#    는 진짜 `OperatingSchedule`/`env` 가 필요해 이 파일의 최소 fixture 로는 못 잰다. 특히
#    **`succ`(FormTransportUnit) 대신 `RobotGo` 를 `_payload_mass` 에 넘기는 버그**(가드에
#    걸려 조용히 `0.0` 이 된다 — 정확히 정책이 코드 옆 주석으로 경고하는 그 사고)는 이 스위트를
#    그대로 두고 넣어도 **초록이 안 빨개진다.** 이 초록을 "적재 순회 로직까지 검증됐다"는
#    증거로 읽지 말 것 — 그 명제는 T5 의 보드가 `battery_payload_proxy_max` 가 실제로 0 이 아닌
#    값으로 실리는지로, 오직 거기서만 확인한다.
#
# 변이시험(전부 이 파일에서 실행해 확인한 것만 적는다 — Fix round 1, I-2: 검증 안 한 주장을
# 적으면 위 정직한 경계 서술과 모순된다)
#   · `count(>(mine), socs)` 를 `count(<(mine), socs)` 로 바꾸면 (3)이 빨개진다.
#   · (5)의 스페어 제외 필터(`!(CB.is_spare(id) || CB.is_recovery_spare(id))`)를 지우고
#     `fleet.soc` 를 그대로 쓰면 (5)가 빨개진다(Fix round 1, I-1 음성 대조 — 실행해 확인).
#
# 실행: julia +lts --project=. test/battery_load_features.jl
# =============================================================================
module BatteryLoadFeatures

using Test
using ConstructionBots
const CB = ConstructionBots
const REPO = normpath(joinpath(@__DIR__, ".."))
isdefined(CB, :BatteryFleet) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))
include(joinpath(REPO, "tools", "monitor", "policy.jl"))

@testset "(3) 함대 SoC 통계는 fleet 에서 유도된다" begin
    # `_battery_load_features` 의 함대 절만 잰다 — env 없이 fleet 전역만 세운다.
    #
    # 🔴 [Fix round 1 후속] `_battery_fleet_features` 가 이제 `CB.SPARE_POOLS[]`/
    #    `CB.RECOVERY_SPARES[]` 를 읽는다(I-1). 그 둘은 **전역 Ref** 라 같은 프로세스 안에서
    #    먼저 도는 다른 테스트 파일이 자기 fixture 로 채워 놓고 안 지우면, 여기서 쓰는 작은
    #    정수 `RobotID` 들과 우연히 겹쳐 이 테스트가 실측: 전체 스위트 안에서 median=0.9·
    #    KeyError 로 빨개졌다(단독 실행에서는 안 보였다 — 오염원이 없었으니까). 그래서 이
    #    테스트가 그 두 전역을 **직접 소유**한다: 비워 놓고 시작해 되돌린다.
    p = CB.BatteryParams()
    fleet = CB.BatteryFleet(p, Dict{Any,Float64}(), Dict{Any,Float64}(),
                            Dict{Any,Int}(), Set{Any}())
    ids = [CB.RobotID(i) for i in 1:5]
    for (i, id) in enumerate(ids)
        fleet.soc[id] = [0.20, 0.55, 0.80, 0.90, 0.95][i]
    end
    old = CB.BATTERY_FLEET[]
    old_pools = CB.SPARE_POOLS[]
    old_recovery = CB.RECOVERY_SPARES[]
    try
        CB.BATTERY_FLEET[] = fleet
        CB.SPARE_POOLS[] = Dict{Symbol,Vector{CB.RobotID}}()
        CB.RECOVERY_SPARES[] = Set{CB.RobotID}()
        d = _battery_fleet_features(ids[2])          # soc = 0.55
        @test d["battery_fleet_soc_median"] === 0.80
        @test d["battery_higher_soc_robots"] === 3   # 0.80 · 0.90 · 0.95
    finally
        CB.BATTERY_FLEET[] = old
        CB.SPARE_POOLS[] = old_pools
        CB.RECOVERY_SPARES[] = old_recovery
    end
end

@testset "(4) 배터리 레이어가 꺼져 있으면 SoC 셋이 안 실린다" begin
    old = CB.BATTERY_FLEET[]
    try
        CB.BATTERY_FLEET[] = nothing
        d = _battery_fleet_features(CB.RobotID(1))
        @test isempty(d)                             # 🔴 0 으로 접지 않는다 — 아예 안 싣는다
    finally
        CB.BATTERY_FLEET[] = old
    end
end

@testset "(5) 스페어는 함대 통계에서 제외된다 (Fix round 1, I-1)" begin
    # `init_battery_fleet!` 는 창고 예비까지 soc0=1.0(안 닳음)으로 `fleet.soc` 에 채운다.
    # `_pick_battery_target`(battery.jl:428-429)가 후보에서 예비를 빼는 것과 같은 이유로,
    # 여기서도 빼지 않으면 median·higher_soc_robots 가 둘 다 "함대가 실제보다 낫다" 쪽으로 샌다.
    p = CB.BatteryParams()
    fleet = CB.BatteryFleet(p, Dict{Any,Float64}(), Dict{Any,Float64}(),
                            Dict{Any,Int}(), Set{Any}())
    ids = [CB.RobotID(i) for i in 1:5]
    for (i, id) in enumerate(ids)
        fleet.soc[id] = [0.20, 0.55, 0.80, 0.90, 0.95][i]
    end
    spare_id = CB.RobotID(99)
    fleet.soc[spare_id] = 1.0    # 창고 예비 — 절대 안 닳는다. 빼지 않으면 두 통계 모두 움직인다.
    # 🔴 [Fix round 1 후속] 여기서도 (3)과 같은 이유로 `SPARE_POOLS`/`RECOVERY_SPARES` 를
    #    직접 소유한다 — 오염원이 있으면 이 테스트가 검증하려는 바로 그 필터가 오작동해도
    #    (즉 `ids[2]`("mine") 자신이 잘못 스페어로 잡혀도) 통과처럼 보일 수 있다.
    old_fleet = CB.BATTERY_FLEET[]
    old_pools = CB.SPARE_POOLS[]
    old_recovery = CB.RECOVERY_SPARES[]
    try
        CB.BATTERY_FLEET[] = fleet
        CB.SPARE_POOLS[] = Dict{Symbol,Vector{CB.RobotID}}(:west => [spare_id])
        CB.RECOVERY_SPARES[] = Set{CB.RobotID}()
        d = _battery_fleet_features(ids[2])           # soc = 0.55
        @test d["battery_fleet_soc_median"] === 0.80          # 스페어(1.0)가 안 끼면 그대로
        @test d["battery_higher_soc_robots"] === 3            # 0.80·0.90·0.95 만(스페어 제외)
    finally
        CB.BATTERY_FLEET[] = old_fleet
        CB.SPARE_POOLS[] = old_pools
        CB.RECOVERY_SPARES[] = old_recovery
    end
end

end # module
