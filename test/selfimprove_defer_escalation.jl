# =============================================================================
# selfimprove (spec §5.3, §0.0 R2): surrogate 가 `DEFER:` 로 답하면 `decide_all` 이 **같은 사건을
# dspy 레인으로 다시 물어** 집행한다. `UNSUPPORTED:` 는 격상하지 않고 계속 죽는다(§0-C 결정 3).
#
# 대역 서버: `/health` 는 fault 를 학습했다고 답하고, `/decide` 는 요청된 레인마다 —
# surrogate 에는 `_SURRO_ERR[]`(빈 chosen), dspy 에는 NOOP 결정을 준다. 요청 레인 목록을 기록한다.
# 실행: julia +lts --project=. test/selfimprove_defer_escalation.jl
# =============================================================================
module SelfimproveDeferEscalation

using Test
using ConstructionBots
const CB = ConstructionBots
import HTTP, JSON3
import Random
import Graphs

const REPO = normpath(joinpath(@__DIR__, ".."))
isdefined(CB, :ZoneTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))

const _SURRO_ERR = Ref("DEFER:low_confidence:0.4000")
const _LANES_SEEN = Vector{Vector{String}}()
const _SERVER = HTTP.serve!(HTTP.Sockets.localhost, 0; listenany = true, verbose = -1) do req
    if req.target == "/health"
        return HTTP.Response(200, "{\"status\":\"ok\",\"surro_kinds\":[\"battery\",\"fault\"]}")
    elseif req.target == "/decide"
        local lanes = String.(collect(JSON3.read(String(req.body))[:lanes]))
        push!(_LANES_SEEN, lanes)
        local out = Dict{String,Any}()
        for l in lanes
            out[l] = l == "surrogate" ?
                Dict{String,Any}("chosen" => "", "ranking" => String[], "scores" => Dict(),
                                 "margin" => 0.0, "unsupported" => String[],
                                 "policy" => "surrogate:SurrogateV2", "error" => _SURRO_ERR[]) :
                Dict{String,Any}("chosen" => _NOOP_NAME, "ranking" => [_NOOP_NAME], "margin" => 0.0,
                                 "rationale" => "fake", "policy" => "test", "unsupported" => String[])
        end
        return HTTP.Response(200, JSON3.write(out))
    end
    return HTTP.Response(404, "")
end
const _PORT = HTTP.Servers.port(_SERVER)

const _PREV_DSPY_URL = get(ENV, "DSPY_URL", nothing)
ENV["DSPY_URL"] = "http://127.0.0.1:$(_PORT)"
try
    include(joinpath(REPO, "tools", "monitor", "policy.jl"))
catch
    close(_SERVER); rethrow()
finally
    _PREV_DSPY_URL === nothing ? delete!(ENV, "DSPY_URL") : (ENV["DSPY_URL"] = _PREV_DSPY_URL)
end
const _NOOP_NAME = try ActionRegistry.NAME[0] catch; close(_SERVER); rethrow() end

const TENV = try
    CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "selfimprove_defer",
                       num_robots = 4, assignment_mode = :greedy, n_spare_per_pool = 2,
                       open_animation_at_end = false, save_animation = false,
                       write_results = false, return_env_before_sim = true,
                       rng = Random.MersenneTwister(1))
catch
    close(_SERVER); rethrow()
end

const FAULT = CB.FaultTruth(CB.RobotID(1), Float64[0.0, 0.0])

try
    @testset "selfimprove DEFER escalation" begin
        @test router_drives()
        @testset "DEFER → dspy 로 격상, 기록이 남는다" begin
            _SURRO_ERR[] = "DEFER:low_confidence:0.4000"; empty!(_LANES_SEEN)
            local d = decide_all(TENV, FAULT; nl = "")
            @test _LANES_SEEN == [["surrogate"], ["dspy"]]
            @test d.enacted == "dspy"
            @test d.router["escalated_from"] == "surrogate"
            @test d.router["defer_reason"] == "DEFER:low_confidence:0.4000"
            @test d.router["router_axis"] == "low_confidence"
            @test d.router["target"] == "dspy"
            @test haskey(d.router, "ood_features")               # 학습 행의 원천 (spec §11.4)
            @test d.router["valid_menu"] isa AbstractVector      # 학습 행의 valid_mask 원천 (plan Task 9)
        end
        @testset "DEFER:no_arm 도 같다" begin
            _SURRO_ERR[] = "DEFER:no_arm"; empty!(_LANES_SEEN)
            local d = decide_all(TENV, FAULT; nl = "")
            @test d.enacted == "dspy" && d.router["router_axis"] == "no_arm"
        end
        @testset "UNSUPPORTED 는 격상하지 않고 죽는다" begin
            _SURRO_ERR[] = "UNSUPPORTED:Replace"; empty!(_LANES_SEEN)
            @test_throws ErrorException decide_all(TENV, FAULT; nl = "")
            @test _LANES_SEEN == [["surrogate"]]
        end
    end
finally
    close(_SERVER)
end

end # module
