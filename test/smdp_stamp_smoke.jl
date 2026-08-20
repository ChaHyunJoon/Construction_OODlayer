# test/smdp_stamp_smoke.jl
# 도장 계약의 Julia 쪽. Python 과 **같은 문자열**을 읽는지, 그리고 도장 없는 입력에서
# 정말 죽는지(음성 대조)를 본다.
#   julia +lts --project=. test/smdp_stamp_smoke.jl
using ConstructionBots
using Test
const CB = ConstructionBots

CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))
include(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "oracle", "action_registry.jl"))

@testset "어휘 도장" begin
    # 리뷰 라운드 1 판정 G: 도장은 "오늘 참인 것"을 선언한다. 오늘 registry 는 3/5/6 이
    # 아직 은퇴 전인 9팔이므로 "v1-9arms" 다("v2-6arms" 는 태스크 5 이후의 END-STATE).
    @test ActionRegistry.VOCAB == "v1-9arms"
    @test length(ActionRegistry.IDS) == 9
    @test ActionRegistry.require_vocab(Dict("vocab" => "v1-9arms"), "ok") === nothing
    @test_throws ErrorException ActionRegistry.require_vocab(Dict{String,Any}(), "도장 없음")
    @test_throws ErrorException ActionRegistry.require_vocab(Dict("vocab" => "v1-8arms"), "구세대")

    # arm-count 일관성 어서션 — Python 쪽 assert_vocab_arm_count 의 Julia 대응. 오늘은
    # (선언 9, 실제 9)로 통과해야 하고, 태스크 5 가 은퇴를 집행하며 "v2-6arms"/6 으로 바꾸는
    # 순간의 통과가 그 은퇴가 실제로 됐다는 증거다(load-bearing, action_registry.jl 주석 참고).
    @test ActionRegistry.assert_vocab_arm_count("v1-9arms", 9) === nothing
    @test_throws ErrorException ActionRegistry.assert_vocab_arm_count("v1-9arms", 7)
    @test_throws ErrorException ActionRegistry.assert_vocab_arm_count("not-a-vocab-stamp", 9)

    # 리뷰 Minor: 정수 등 문자열이 아닌 도장 값도 계약 메시지(ErrorException)로 죽어야 한다 —
    # 이전엔 `String(::Int64)` 메서드가 없어 MethodError 로 죽었다(죽긴 죽지만 계약 메시지가 아님).
    @test_throws ErrorException ActionRegistry.require_vocab(Dict("vocab" => 3), "정수 도장")
end

@testset "동역학 도장" begin
    CB.disable_hazard!()
    @test CB.dynamics_stamp() == "hazard-off"

    # 리뷰 [Important]: hazard-on 분기가 실제로 hazard 상태를 읽는지 확인한다. 이게 없으면
    # dynamics_stamp() = "hazard-off" 리터럴로도 위 검사와 DEMO_SUMMARY 의 assert 를 그대로
    # 통과한다(2026-08-16 의 "영원히 실패할 수 없는 검사"와 같은 모양). 전역 상태를 직접
    # 세우고 반드시 disable_hazard!() 로 복구한다 — 다른 테스트로 새면 안 된다.
    try
        CB.HAZARD_STATE[] = CB._new_hazard_state(CB.HazardParams(), 7)
        CB.HAZARD_ENABLED[] = true
        @test CB.dynamics_stamp() == "hazard-on"
    finally
        CB.disable_hazard!()
    end
    @test CB.dynamics_stamp() == "hazard-off"
end
