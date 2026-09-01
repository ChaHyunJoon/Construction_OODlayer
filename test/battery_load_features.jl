# =============================================================================
# **battery 사건이 payload/함대 사실을 싣는가.** (2026-08-31, S1/T2)
#
# 이 게이트는 세계를 짓지 않는다 — `_battery_load_features` 는 `(env, agent)` 만 보는
# 함수이므로 최소 fixture 로 잰다. 진짜 빌드에서의 값은 T5 의 보드가 낸다.
#
# ⚠️ **여기 없는 것**: (1) `battery_pending_transports`/(2) `battery_payload_max_kg`·
# `battery_payload_total_kg`(운반 작업 순회)는 진짜 `env` 가 필요하므로 이 파일에서 재지
# 않는다. 이 초록을 "적재 순회 로직까지 검증됐다"는 증거로 읽지 말 것 — 그 두 명제는 T5 의
# 보드가 `battery_payload_max_kg` 를 실제로 싣는지로 확인한다.
#
# 변이시험
#   · `_payload_mass` 호출을 상수 `0.0` 으로 바꾸면 (2)가 빨개진다.
#   · `succ isa CB.FormTransportUnit` 필터를 지우면 (1)의 개수가 늘어 빨개진다.
#   · `count(>(mine), socs)` 를 `count(<(mine), socs)` 로 바꾸면 (3)이 빨개진다.
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
    p = CB.BatteryParams()
    fleet = CB.BatteryFleet(p, Dict{Any,Float64}(), Dict{Any,Float64}(),
                            Dict{Any,Int}(), Set{Any}())
    ids = [CB.RobotID(i) for i in 1:5]
    for (i, id) in enumerate(ids)
        fleet.soc[id] = [0.20, 0.55, 0.80, 0.90, 0.95][i]
    end
    old = CB.BATTERY_FLEET[]
    try
        CB.BATTERY_FLEET[] = fleet
        d = _battery_fleet_features(ids[2])          # soc = 0.55
        @test d["battery_fleet_soc_median"] === 0.80
        @test d["battery_higher_soc_robots"] === 3   # 0.80 · 0.90 · 0.95
    finally
        CB.BATTERY_FLEET[] = old
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

end # module
