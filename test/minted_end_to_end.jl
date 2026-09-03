# =============================================================================
# 경계 e2e: 생성 코드가 서비스 응답에서 등록·집행부까지 간다. (2026-09-03, Task 9)
#
# 재는 명제: `policy_entry` 가 SYNTH_LANE_KEYS 로 실은 `impl_name`·`impl_code`·
# `surface`·`reversible` 가 `enact_minted_decision!` 안에서 `register_minted_primitive!`
# 로 등록되고, 그 직후 같은 프레임에서 `enact_minted!` 가 그 이름을 부를 수 있어야 한다
# (world age — `test/minted_registration.jl` (9) 의 F1 과 같은 모양). 그리고 `registered`·
# `impl_rejected_why`(R2/R7) 가 그 셋을 실제로 가른다 — 성공 · 등록 거절 · 판정 불가.
#
# 🔴 서비스 응답과 **같은 타입**으로 왕복시킨다. 손으로 지은 Dict{String,Any} 픽스처는
#    JSON3.Object 가 아니라서, 라이브에서만 나는 실패를 못 잡는다.
#
# 🔴 2026-09-03 최종 리뷰 F5. 이전 판은 이 파일 전체가 `registered`·`impl_rejected_why`
#    에 단언을 **하나도** 안 걸었다 — `if why !== nothing … return` 갈래를 통째로 지워도
#    스위트가 전부 초록이었다(실측, 이 파일 맨 아래 "변이 기록" 참고). 아래 testset (2)·(3)
#    이 그 구멍을 메운다.
# =============================================================================
module MintedEndToEnd
using Test
using ConstructionBots
import JSON3
const CB = ConstructionBots
include(joinpath(@__DIR__, "..", "tools", "monitor", "policy.jl"))
include(joinpath(@__DIR__, "..", "tools", "monitor", "enact.jl"))

const RESP = JSON3.read(JSON3.write(Dict{String,Any}(
    "chosen" => "NOOP", "ranking" => ["NOOP"], "margin" => nothing, "rationale" => "r",
    "policy" => "dspy", "coerced" => false, "error" => nothing, "tool_minted" => true,
    "synthesis" => Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "e2e_touch!",
        "impl_code" => "function e2e_touch!(env; note = \"x\")\n    return (status = :e2e_ok, note = note)\nend\n",
        "surface" => "sched", "reversible" => true,
        "params" => Dict{String,Any}("note" => Dict{String,Any}("type" => "string")),
        "body_names" => ["e2e_touch!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "e2e_touch!",
                                     "args" => Dict{String,Any}("note" => "hi"))]))))

@testset "(1) 생성 코드가 응답에서 등록·집행부까지 간다" begin
    CB.reset_minted_table!()
    e = policy_entry(RESP, "dspy")
    for k in ("impl_name", "impl_code", "surface", "reversible")
        @test haskey(e, k)
    end
    dec = (macro_name = "NOOP", synth_lane = e)
    r = enact_minted_decision!((staging_circles = Dict{Symbol,Any}(),), nothing, dec)
    @test r.verdict === :admit
    @test r.args_from === :calls && r.n_calls == 1
    @test length(r.steps) == 1 && r.steps[1].status === :e2e_ok
    # 🔴 F5. 행복 경로: 등록이 실제로 됐고, 거절 사유는 없다.
    @test r.registered === true
    @test r.impl_rejected_why === nothing
    # 🔴 F6(5)(2026-09-03 최종 리뷰). 이 fixture 의 `env` 는 `staging_circles` 하나뿐이라
    #    `_issue_resume!`/`_resolve_if_needed!` 가 요구하는 `cache`/`sched` 필드가 없다 —
    #    그래서 `resume=:failed`(재개 시도가 예외로 끝남)·`resolve=:threw` 가 나고
    #    `minted_handled` 의 네 연언지 중 둘이 깨져 `handled === false` 다(실측). 이것은
    #    이 시험의 **결함이 아니라 측정값**이다: 이 파일 제목의 "집행부까지 간다" 는
    #    등록→`enact_minted!` 왕복(= verdict·args_from·steps)까지만 가리키고, 렌더 루프
    #    전체의 조용하지 않은 폴백 배선(`handled`)까지는 안 가리킨다 — 그것은
    #    `tools/monitor/test_minted_wiring.jl` 의 몫이다(완전한 fake env 를 갖췄다). 여기서
    #    `handled` 를 명시적으로 단언해 그 경계를 감춘 사실 대신 **잰 사실**로 남긴다.
    @test r.handled === false
end

@testset "(2) 🔴 F5: 규약 위반 impl_code 는 registered=false·impl_rejected_why 를 남기고 집행을 시도하지 않는다" begin
    CB.reset_minted_table!()
    resp2 = JSON3.read(JSON3.write(Dict{String,Any}(
        "chosen" => "NOOP", "ranking" => ["NOOP"], "margin" => nothing, "rationale" => "r",
        "policy" => "dspy", "coerced" => false, "error" => nothing, "tool_minted" => true,
        "synthesis" => Dict{String,Any}(
            "synthesis_event" => true, "ran" => true, "error" => nothing,
            "tool_name" => "T", "impl_name" => "e2e_bad!",
            # 규약 위반: 위치인자가 `env` 하나가 아니다(`check_impl_conventions` 가 거절한다).
            "impl_code" => "function e2e_bad!(x; note = \"x\")\n    return :ok\nend\n",
            "surface" => "sched", "reversible" => true,
            "params" => Dict{String,Any}(),
            "body_names" => ["e2e_bad!"], "wrote" => true,
            "calls" => [Dict{String,Any}("primitive" => "e2e_bad!",
                                         "args" => Dict{String,Any}())]))))
    e2 = policy_entry(resp2, "dspy")
    dec2 = (macro_name = "NOOP", synth_lane = e2)
    r2 = enact_minted_decision!((staging_circles = Dict{Symbol,Any}(),), nothing, dec2)
    @test r2.verdict === :reject
    @test r2.registered === false
    @test r2.impl_rejected_why !== nothing &&
          occursin("reject:", r2.impl_rejected_why) &&
          occursin("positional", r2.impl_rejected_why)
    # 🔴 집행이 시도되지 않았다 — 등록 거절이 `CB.enact_minted!` 호출보다 먼저 돌아선다.
    @test isempty(r2.steps)
    @test r2.handled === false
    @test !isdefined(CB, :e2e_bad!)   # Core.eval 자체가 안 됐다는 것을 직접 잰다
end

@testset "(3) 🔴 F5/F2: 등록 도중 던지면 registered 는 false 가 아니라 nothing 이다" begin
    CB.reset_minted_table!()
    # 🔴 `register_minted_primitive!` 는 "던지지 않는다" 를 약속하지만(그 자신의 docstring),
    #    `params` 의 키 타입은 검사하지 않는다 — `Dict{String,Any}(String(k) => v for (k,v)
    #    in pairs(params))` 가 `String(::Int64)` 에서 던진다(실측, 이 파일 맨 아래 "변이
    #    기록" 참고). `enact.jl` 의 F3 타입 가드는 `praw isa AbstractDict` 만 보므로
    #    Int-키 dict 은 통과해 그 안쪽 던지기에 그대로 노출된다 — JSON 은 키가 항상
    #    문자열이라 이 모양은 라이브 payload 로는 못 오지만(JSON3 round-trip 으로는 못
    #    만든다), **바깥 `try` 가 그 예외를 삼킨 뒤에도 `registered` 가 거짓말을 하지
    #    않는지**(R7 이 진짜로 지키는 계약)를 재는 유일한 창이다. 그래서 여기만 raw Dict
    #    픽스처를 쓴다.
    sl3 = Dict{String,Any}("impl_name" => "e2e_nothing_check!",
                            "impl_code" => "function e2e_nothing_check!(env; note = \"x\")\n    return :ok\nend\n",
                            "surface" => "sched", "reversible" => false,
                            "params" => Dict{Int,Any}(1 => "x"),
                            "body_names" => ["e2e_nothing_check!"], "calls" => nothing)
    dec3 = (macro_name = "NOOP", synth_lane = sl3)
    r3 = enact_minted_decision!((staging_circles = Dict{Symbol,Any}(),), nothing, dec3)
    @test r3.verdict === :reject
    @test occursin("threw", r3.reason)
    # 🔴 핵심 단언. `false` 가 아니라 `nothing` 이어야 한다 — R2 시절이었다면 이 자리에
    #    리터럴 `false` 가 나와 "등록이 안 됐다" 고 **확정 진술**했을 것이다. 실제로는
    #    `Core.eval` 이 돌았는지조차 이 함수가 판정할 자리에 못 닿고 던졌다 — "몰라서
    #    못 쟀다" 가 정직한 값이다.
    @test r3.registered === nothing
    @test r3.impl_rejected_why === nothing
    @test r3.handled === false
end

end # module
