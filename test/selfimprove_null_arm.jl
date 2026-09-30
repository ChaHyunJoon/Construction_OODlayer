# =============================================================================
# selfimprove T_null (plan Task 12, spec §0.0 R3): Python `static_check.null_arm` 이 만든 대조 팔이
# Julia 쪽 등록·집행 경로를 실제로 통과하는가. 고정 후보 body 둘(키워드 없음 / 기본값 있는 키워드).
#   (a) check_impl_conventions 통과 (b) register_minted_primitive! 성공
#   (c) enact_minted! 에서 calls 인자 바인딩 성공, steps[1].status ≠ :threw (d) calls_disagree_with_body 없음
# 실행: julia +lts --project=. test/selfimprove_null_arm.jl
# =============================================================================
module SelfimproveNullArm

using Test
using ConstructionBots
const CB = ConstructionBots
import JSON3

const REPO = normpath(joinpath(@__DIR__, ".."))
const PY = joinpath(REPO, ".venv", "bin", "python")

const BODIES = [
    Dict("impl_name" => "cand_a!", "impl_code" => "function cand_a!(env)\n    return (status = :ok,)\nend\n",
         "calls" => [Dict("primitive" => "cand_a!", "args" => Dict())], "params" => Dict(),
         "surface" => "geom", "reversible" => false, "body_names" => ["cand_a!"]),
    Dict("impl_name" => "cand_b!",
         "impl_code" => "function cand_b!(env; dx::Float64 = 0.5, tag::String = \"a(b\")\n" *
                        "    return (status = :ok, dx = dx)\nend\n",
         "calls" => [Dict("primitive" => "cand_b!", "args" => Dict("dx" => 1.25, "tag" => "z"))],
         "params" => Dict("dx" => Dict("type" => "number"), "tag" => Dict("type" => "string")),
         "surface" => "geom", "reversible" => false, "body_names" => ["cand_b!"]),
]

"Python 이 만든 null arm (레포 루트에서 static_check 를 부른다)."
function py_null(row)
    src = """
import json, sys
from tools.selfimprove import static_check as sc
row = json.loads(sys.stdin.read())
print(json.dumps(sc.null_arm(sc.arm_json(row, 900, "candidate", "cand_c0_" + row["impl_name"]))))
"""
    out = read(pipeline(`$(PY) -c $(src)`; stdin = IOBuffer(JSON3.write(row))), String)
    return JSON3.read(out, Dict{String,Any})
end

live_env() = (s = CB.OperatingSchedule(); c = CB.initialize_planning_cache(s);
              (cache = c, sched = s, active_build_steps = Set{CB.AbstractID}()))

@testset "selfimprove null arm" begin
    for (i, body) in enumerate(BODIES)
        n = cd(() -> py_null(body), REPO)
        @test n["impl_name"] == "selfimprove_null_arm!"
        @test CB.check_impl_conventions(n["impl_name"], n["impl_code"]; allow_redefine = i > 1) === nothing
        @test CB.register_minted_primitive!(; name = n["impl_name"], code = n["impl_code"], params = n["params"],
                                            surface = n["surface"], reversible = n["reversible"],
                                            allow_redefine = i > 1) === nothing
        synth = Dict{String,Any}(k => n[k] for k in ("impl_name", "body_names", "calls", "params", "surface", "reversible"))
        r = CB.enact_minted!(live_env(), nothing, synth)
        @test r.verdict === :admit
        @test !isempty(r.steps) && r.steps[1].status !== :threw
        @test !occursin("calls_disagree_with_body", r.reason)
    end
end

end # module
