# test/payload_reprice_install.jl
#   julia +lts --project=. test/payload_reprice_install.jl
module PayloadRepriceInstallTest
using Test
using Graphs
using ConstructionBots
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))

# 🔴 FIX ROUND 1 / Finding 3 재료: get_vtx_id · get_node_from_id · Graphs.outneighbors 를
# 이 더미 타입에 대해서만 확장해, 실제 스케줄/씬 없이 payload_edge_multiplier 의 두 내부
# 1.0-반환 분기(소유자 불일치 · 화물 못잼)를 각각 단독으로 겨냥한다. 구조체는 module 최상위에
# 둬야 한다(로컬 스코프에서 struct 정의는 피한다).
struct _StubSched end

@testset "함대가 없으면 설치하지 않는다" begin
    CB.BATTERY_FLEET[] = nothing
    # 🔴 FIX ROUND 1 / Finding 1: :no_fleet 은 agent 문자열을 비교하기 전에 반환되므로 아래
    #    값은 임의의 자리채움이다 — 실제 agent 포맷(모듈-한정, string(id) 파생)은
    #    "실제 함대: 설치(:repriced)와 오식별(:unknown_agent)" 테스트셋에서 파생해 검증한다.
    #    원래 여기 있던 짧은 리터럴 "BotID{DeliveryBot}(2)" 는 이 시스템에 존재하지 않는
    #    형태라 지웠다 — 다음 독자가 그걸 베껴 쓰지 않도록.
    r = CB.reprice_agent_by_payload!(nothing; agent = "placeholder-no-fleet-short-circuits")
    @test r.status === :no_fleet
    @test r.installed === false
    @test CB.EDGE_PAYLOAD_MULTIPLIER[] === nothing   # 🔴 실패했으면 훅을 안 남긴다
end

@testset "훅이 없을 때 배수는 1.0 이다 (음성 대조)" begin
    CB.PAYLOAD_BIAS[] = nothing
    @test CB.payload_edge_multiplier(nothing, nothing, 1, 2) == 1.0
end

# 🔴 FIX ROUND 1 / Finding 2: 실제 함대를 설치해 :repriced 경로와 (함대가 있는) :unknown_agent
# 경로를 둘 다 실측한다. 이전엔 :no_fleet 짧은회로만 덮여 있어 id 포맷 함정이 안 보였다.
@testset "실제 함대: 설치(:repriced)와 오식별(:unknown_agent)" begin
    saved_fleet = CB.BATTERY_FLEET[]
    try
        rid = CB.RobotID(7)
        fleet = CB.BatteryFleet(CB.BatteryParams(), Dict{Any,Float64}(rid => 1.0),
                                 Dict{Any,Float64}(), Dict{Any,Int}(), Set{Any}())
        CB.BATTERY_FLEET[] = fleet
        CB.PAYLOAD_BIAS[] = nothing
        CB.EDGE_PAYLOAD_MULTIPLIER[] = nothing

        # 음성 대조 먼저: 함대에는 있지만 이 문자열은 그 안에 없다.
        r_bad = CB.reprice_agent_by_payload!(nothing; agent = "no-such-agent")
        @test r_bad.status === :unknown_agent
        @test r_bad.installed === false
        @test CB.EDGE_PAYLOAD_MULTIPLIER[] === nothing

        # 🔴 agent 문자열은 실제 함대 키에서 string(id) 로 파생한다 — 리터럴을 하드코딩하지
        #    않는다. 파생 자체가 포맷 계약을 고정한다(Finding 1 이 잡은 함정을 되풀이하지 않음).
        agent_str = string(rid)
        r_ok = CB.reprice_agent_by_payload!(nothing; agent = agent_str)
        @test r_ok.status === :repriced
        @test r_ok.installed === true
        @test CB.EDGE_PAYLOAD_MULTIPLIER[] !== nothing
    finally
        CB.BATTERY_FLEET[] = saved_fleet
        CB.PAYLOAD_BIAS[] = nothing
        CB.EDGE_PAYLOAD_MULTIPLIER[] = nothing
    end
end

# 🔴 FIX ROUND 1 / Finding 3: payload_edge_multiplier 의 두 내부 1.0-반환 분기(삼상 규약의
# 실제 방어선)를 PAYLOAD_BIAS[] 가 켜진 채로 각각 단독으로 때린다. _StubSched 에 대해서만
# get_vtx_id/get_node_from_id/Graphs.outneighbors 를 확장해 실제 스케줄 없이 재현한다.
@testset "payload_edge_multiplier 의 두 방어선: 소유자 불일치 · 화물 못잼 (둘 다 1.0, 0.0 아님)" begin
    try
        CB.PAYLOAD_BIAS[] = (agent = "target-agent", light_bias = 0.5, params = CB.BatteryParams())
        CB.get_vtx_id(::_StubSched, v) = v

        # (a) 소유자가 있지만 재가격 대상과 다르다.
        CB.get_node_from_id(::_StubSched, id) = (entity = (id = "someone-else",),)
        @test CB.payload_edge_multiplier(nothing, _StubSched(), 1, 2) == 1.0

        # (b) 소유자는 일치하지만 화물을 못 잰다(outneighbors 가 비어 있음 =
        #     candidate_edge_payload_mass 가 nothing). 1.0 이어야 한다 — 0.0 도, 예외도 아니다.
        CB.get_node_from_id(::_StubSched, id) = (entity = (id = "target-agent",),)
        Graphs.outneighbors(::_StubSched, v) = Int[]
        @test CB.payload_edge_multiplier(nothing, _StubSched(), 1, 2) == 1.0
    finally
        CB.PAYLOAD_BIAS[] = nothing
    end
end

@testset "clear_payload_bias! 는 SoC 훅을 건드리지 않는다" begin
    CB.EDGE_COST_MULTIPLIER[] = (sched, v) -> 3.0      # SoC 축이 꽂혀 있다고 가정
    CB.EDGE_PAYLOAD_MULTIPLIER[] = (sched, v, v2) -> 2.0
    try
        @test CB.edge_cost_multiplier(nothing, 1, 2) == 6.0
        CB.clear_payload_bias!()
        @test CB.EDGE_PAYLOAD_MULTIPLIER[] === nothing
        @test CB.edge_cost_multiplier(nothing, 1, 2) == 3.0   # 🔴 SoC 항은 살아 있다
    finally
        CB.EDGE_COST_MULTIPLIER[] = nothing
        CB.EDGE_PAYLOAD_MULTIPLIER[] = nothing
        CB.PAYLOAD_BIAS[] = nothing
    end
end

@testset "알파벳이 이 원시를 해석하고 결선한다" begin
    CB.include(joinpath(pkgdir(CB), "src", "respec", "minted_tool.jl"))
    tbl = CB.PRIMITIVE_TABLE()
    @test haskey(tbl, "reprice_agent_by_payload")
    r = CB.resolve_primitive("reprice_agent_by_payload")
    @test r.impl === CB.reprice_agent_by_payload!
    @test r.harness_args == ["env"]
    @test Set(keys(r.params)) == Set(["agent", "light_bias"])
end
end # module
