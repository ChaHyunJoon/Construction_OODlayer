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
    # 🔴 최종 리뷰 F1: 여기 있던 `CB.include(.../minted_tool.jl)` 을 지웠다. minted_tool.jl
    # 은 이미 패키지 안에 있다(`src/respec/respec.jl:34`) — 이 include 는 중복일 뿐 아니라
    # `enact_minted!`·`bind_primitive_args`·`_step_status`·`_step_detail`·`_synth_get` 등
    # ~5개 운영 메서드를 런타임에 **재정의**해, 이 파일을 `runtests.jl` 안에 실으면 그
    # 재정의가 뒤따르는 모든 파일에 남는다.
    tbl = CB.PRIMITIVE_TABLE()
    @test haskey(tbl, "reprice_agent_by_payload")
    r = CB.resolve_primitive("reprice_agent_by_payload")
    @test r.impl === CB.reprice_agent_by_payload!
    @test r.harness_args == ["env"]
    @test Set(keys(r.params)) == Set(["agent", "light_bias"])
end

# 🔴 최종 리뷰 F7 — 알려진 구멍을 못박는다(고치지 않는다). `reprice_agent_by_payload!` 는
# **필수 kwarg**(`agent`, 기본값 없음)를 가진 첫 번째 enactable 원시다 — 다른 여섯은 kwarg
# 를 전부 기본값으로 채운다. `bind_primitive_args`(src/respec/minted_tool.jl:521-536) 는
# `ctx.params` 를 순회해 "레지스트리가 아는 키인가/타입이 맞는가"만 검사하고, impl 이 요구하는
# 필수 kwarg 가 빠졌는지는 **절대 검사하지 않는다** — body 가 `["reprice_agent_by_payload"]`,
# params 가 `{}`(agent 없음)면 바인더를 통과해 `impl(env)` 가 그대로 불리고, Julia 가 호출
# 경계에서 `UndefKeywordError` 를 던진다. `enact_minted!` 은 이것을 다른 모든 예외와 똑같이
# `partial=true` 로 적고, `world_maybe_dirty = touched || partial` 이 참이 되어
# `handled = (verdict===:admit) && world_maybe_dirty && (resume !== :failed)`
# (tools/monitor/enact.jl:869) 가 **참**이 된다 — 세계는 증명 가능하게 한 바이트도 안 건드렸는데
# (Ref 둘을 쓰기도 전에 던졌다) 정책 프로듀서는 이것을 "처리됐다"로 읽고 폴백 복구 사슬을
# 건너뛰며, 그 OOD 사건은 이미 소비돼 다시 오지 않는다.
#
# 🔴 **이 테스트는 그 구멍을 고치지 않는다.** `bind_primitive_args` 를 고치면 원시 전부의
# 행동이 바뀌므로 그 자체가 별도 레인이다(spec/ledger 가 이미 그렇게 범위를 그었다). 여기서는
# 오늘의 동작을 기록만 해서, `bind_primitive_args` 가 나중에 조용히 넓어져도(혹은 좁아져도)
# 이 자리가 들키게 한다.
# 🔴 **바른 장기 수선은 여기가 아니라 `bind_primitive_args` 안에서 필수 kwarg 미충족을
# `reject:missing_param:agent` 로 거절하는 것**이다(거절 = 세계 무접촉 = 폴백이 정상적으로
# 돈다) — 이 lane 의 범위 밖이라 손대지 않는다.
@testset "🔴 알려진 구멍: agent 없이 부르면 UndefKeywordError 가 던져지고 handled=true 가 된다" begin
    # 🔴 `Ref(:dummy_env)` 는 안 쓴다: `_issue_resume!` 이 `env.cache`/`env.sched` 를 읽는데,
    # 그게 없으면 그 자체가 던져서 `resume=:failed` 가 되고 `handled` 가 거짓으로 떨어져
    # (세계를 못 건드린 자리에서도) 구멍을 못 잡는다. `PlanningCache()`/`OperatingSchedule()`
    # 빈 기본 생성자는 씬을 안 지어도 되고(둘 다 `@with_kw` 기본값이 있다) `reset_cache_resume!`
    # 가 실제로 성공한다(측정: `resume=(:issued, "")`) — 이게 "진짜 env" 에서 나는 값이다.
    env = (cache = CB.PlanningCache(), sched = CB.OperatingSchedule())
    synth = Dict{String,Any}("reach" => "composed",
                              "body_names" => ["reprice_agent_by_payload"],
                              "params" => Dict{String,Any}())
    r = CB.enact_minted!(env, nothing, synth)
    @test r.verdict === :admit
    @test r.applied === false
    @test r.partial === true
    @test r.world_maybe_dirty === true
    @test length(r.steps) == 1
    @test r.steps[1].status === :threw
    @test occursin("UndefKeywordError", r.steps[1].detail)
    @test occursin("agent", r.steps[1].detail)
    # 정책 레인의 실제 handled 계산(tools/monitor/enact.jl:869)을 그대로 재현한다.
    handled = (r.verdict === :admit) && r.world_maybe_dirty && (r.resume !== :failed)
    @test handled === true   # 🔴 세계를 안 건드렸는데도 참 — 이것이 구멍이다, 통과가 아니다.
end
end # module
