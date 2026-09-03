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

# 🔴 2026-09-02 (cargo-ban T7): 이 testset 은 **뒤집혔다.** 예전에는 이 원시가 알파벳에
# 있다는 것을 못 박았는데, 사용자 결정으로 `reprice_agent_by_payload` 는 **레지스트리에서만**
# 빠졌다 — 실측상 argmin 을 못 움직이기 때문이다(두 판·전 체크포인트·`light_bias` 32 까지
# 대상 로봇이 일을 하나도 안 잃고, 음성 대조와 `n_reassigned` 이 완전히 같다). 구현
# (`src/navigator/payload_bias.jl`)과 이 파일의 나머지 testset 은 **음성 대조로 남는다**.
# 🔴 그러므로 여기서 재는 것은 **부재**다. 부재 게이트는 공허해지기 쉬우므로 양성 대조를
#    함께 단다: (a) 구현은 여전히 CB 에 있고 부를 수 있다, (b) 그 자리를 이어받은
#    `forbid_heavy_cargo` 는 알파벳에 있고 해석된다. 셋이 함께 있어야 "레지스트리를 못 읽어서
#    전부 없다" 와 "이 하나만 뺐다" 가 구별된다.
@testset "🔴 알파벳은 이 원시를 더 이상 모른다 (구현은 남는다)" begin
    tbl = CB.PRIMITIVE_TABLE()
    @test !haskey(tbl, "reprice_agent_by_payload")
    @test CB.resolve_primitive("reprice_agent_by_payload") === nothing
    # (a) 양성 대조 — 구현은 살아 있다. 지워진 것은 알파벳 항목뿐이다.
    @test isdefined(CB, :reprice_agent_by_payload!)
    @test CB.reprice_agent_by_payload! isa Function
    # (b) 양성 대조 — 표 자체는 읽혔고, 그 자리를 이어받은 원시가 실제로 있다.
    @test haskey(tbl, "forbid_heavy_cargo")
    local r = CB.resolve_primitive("forbid_heavy_cargo")
    @test r.impl === CB.forbid_heavy_cargo!
    @test r.harness_args == ["env"]
    @test Set(keys(r.params)) == Set(["agent", "n"])
    # (c) 그리고 body 에 옛 이름을 쓰면 **한 발도 안 나가고** 거절된다.
    local rej = CB.enact_minted!(nothing, nothing,
        Dict{String,Any}("reach" => "composed",
                         "body_names" => ["reprice_agent_by_payload"],
                         "params" => Dict{String,Any}()))
    @test rej.verdict === :reject
    @test isempty(rej.steps)
    @test rej.world_maybe_dirty === false
end

# 🔴 최종 리뷰 F7 — 알려진 구멍을 못박는다(고치지 않는다). 🔴 2026-09-02 (T7): 이 구멍의
# 표본이 `reprice_agent_by_payload!` 에서 `forbid_heavy_cargo!` 로 **옮겨졌다** — 전자가
# 알파벳에서 빠지면서 그 자리(**필수 kwarg `agent`, 기본값 없음**를 가진 유일한 enactable
# 원시)를 후자가 그대로 이어받았다. 구멍은 `bind_primitive_args` 의 성질이라 원시와 무관하다.
# 다른 일곱은 kwarg
# 를 전부 기본값으로 채운다. `bind_primitive_args`(`src/respec/minted_tool.jl`) 는
# `ctx.params` 를 순회해 "레지스트리가 아는 키인가/타입이 맞는가"만 검사하고, impl 이 요구하는
# 필수 kwarg 가 빠졌는지는 **절대 검사하지 않는다** — body 가 `["forbid_heavy_cargo"]`,
# params 가 `{}`(agent 없음)면 바인더를 통과해 `impl(env)` 가 그대로 불린다. 🔴 **그 다음이
# 2026-09-02 (T0.5/R1-B) 에 바뀌었다**: 예전엔 Julia 가 호출 경계에서 `UndefKeywordError` 를
# 던졌고, `enact_minted!` 이 그것을 다른 모든 예외와 똑같이 `partial=true` 로 적어
# `world_maybe_dirty = touched || partial` 이 참이 됐다 — 세계는 증명 가능하게 한 바이트도 안
# 건드렸는데(보관소에 한 항목도 쓰기 전에 던졌다) 정책 프로듀서가 이것을 "처리됐다"로 읽고 폴백
# 복구 사슬을 건너뛰며, 그 OOD 사건은 이미 소비돼 다시 오지 않았다.
# **오늘은 던지지 않는다** — `agent` 에 기본값이 생겨 `impl` 이 `:missing_agent` status 로
# 돌아서고 `world_maybe_dirty=false` 다(아래 testset 이 그것을 박제한다).
# `handled` 의 정본은 `tools/monitor/enact.jl` 의 `minted_handled`(**네** 연언지)다.
# 🔴 여기에 그 식을 다시 베끼지 마라: 예전 3-연언지 복사본은 실측에서 프로덕션과 갈렸다(2026-09-02).
#
# 🔴 **바인더의 구멍 자체는 아직 열려 있다** — 닫힌 것은 `forbid_heavy_cargo!` 라는 입력 모양
# 하나뿐이고, `bind_primitive_args` 는 여전히 필수 kwarg 미충족을 검사하지 않는다.
#
# 🔴 **이 테스트는 그 구멍을 고치지 않는다.** `bind_primitive_args` 를 고치면 원시 전부의
# 행동이 바뀌므로 그 자체가 별도 레인이다(spec/ledger 가 이미 그렇게 범위를 그었다). 여기서는
# 오늘의 동작을 기록만 해서, `bind_primitive_args` 가 나중에 조용히 넓어져도(혹은 좁아져도)
# 이 자리가 들키게 한다.
# 🔴 **바른 장기 수선은 여기가 아니라 `bind_primitive_args` 안에서 필수 kwarg 미충족을
# `reject:missing_param:agent` 로 거절하는 것**이다(거절 = 세계 무접촉 = 폴백이 정상적으로
# 돈다) — 이 lane 의 범위 밖이라 손대지 않는다.
@testset "🟢 그 구멍은 닫혔다: agent 없이 부르면 :missing_agent 이고 폴백이 정상으로 돈다" begin
    # 🔴 2026-09-02 (R1-B). 예전엔 여기서 `UndefKeywordError` 가 나 `partial=true` 가 되고,
    #    **세계를 한 바이트도 안 건드린 판이** `handled=true` 로 기본 복구 사슬을 삼켰다.
    #    (그 사실을 이 자리가 박제하고 있었다 — 이제 그 반대를 박제한다.)
    env = (cache = CB.PlanningCache(), sched = CB.OperatingSchedule())
    synth = Dict{String,Any}("reach" => "composed",
                              "body_names" => ["forbid_heavy_cargo"],
                              "params" => Dict{String,Any}())
    r = CB.enact_minted!(env, nothing, synth)
    @test r.verdict === :admit
    @test r.applied === false
    @test r.partial === false                    # 던지지 않는다
    @test r.world_maybe_dirty === false          # 세계 무접촉이 그대로 보고된다
    @test length(r.steps) == 1
    @test r.steps[1].status === :missing_agent
    # 🔴 `handled` 를 손으로 베끼지 않는다 — 복사본은 실측에서 프로덕션과 갈렸다
    #    (T0: copy3=true vs prod4=false). 정본 술어를 부른다.
    @test CB.minted_handled_verdict_ok(r.verdict) === true    # 아래 B 참조
    @test r.world_maybe_dirty === false          # ⟹ handled=false ⟹ 폴백이 정상으로 돈다
end
end # module
