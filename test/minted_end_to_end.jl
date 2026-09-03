# =============================================================================
# 경계 e2e: 생성 코드가 서비스 응답에서 집행까지 간다. (2026-09-03, Task 9)
#
# 재는 명제 하나: `policy_entry` 가 SYNTH_LANE_KEYS 로 실은 `impl_name`·`impl_code`·
# `surface`·`reversible` 가 `enact_minted_decision!` 안에서 `register_minted_primitive!`
# 로 등록되고, 그 직후 같은 프레임에서 `enact_minted!` 가 그 이름을 부를 수 있어야 한다
# (world age — `test/minted_registration.jl` (9) 의 F1 과 같은 모양).
#
# 🔴 서비스 응답과 **같은 타입**으로 왕복시킨다. 손으로 지은 Dict{String,Any} 픽스처는
#    JSON3.Object 가 아니라서, 라이브에서만 나는 실패를 못 잡는다.
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

@testset "생성 코드가 응답에서 집행까지 간다" begin
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
end
end # module
