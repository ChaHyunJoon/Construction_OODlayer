module WorldInterfaceCurrent
using Test
using ConstructionBots
import JSON3
const CB = ConstructionBots
const ART = normpath(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "core",
                              "world_interface.json"))

@testset "(1) 산출물이 있고 모양이 맞다" begin
    @test isfile(ART)
    j = JSON3.read(read(ART, String))
    @test haskey(j, :types) && haskey(j, :methods)
    @test !isempty(j.types) && !isempty(j.methods)
end

@testset "(2) 🔴 현행 코드와 일치한다 — 재생성해서 대조한다" begin
    # 손으로 유지되는 사본은 반드시 낡는다. `code_fingerprint` 와 같은 논거다.
    mktempdir() do dir
        out = joinpath(dir, "regen.json")
        run(`julia +lts --project=$(normpath(joinpath(@__DIR__, ".."))) $(normpath(joinpath(@__DIR__, "..", "tools", "gen_world_interface.jl"))) $(out)`)
        @test read(out, String) == read(ART, String)
    end
end

@testset "(3) PlannerEnv 의 필드가 전부 실려 있다" begin
    j = JSON3.read(read(ART, String))
    t = only(filter(x -> x.name == "PlannerEnv", collect(j.types)))
    @test Set(String.([f.name for f in t.fields])) ==
          Set(String.(collect(fieldnames(CB.PlannerEnv))))
end

@testset "(4) 🔴 비공개 impl 은 실리지 않는다 (설계 D6)" begin
    # 사용자 결정: 표면은 `names(CB)` 그대로. 모델은 `release_pending_assignments!` 를
    # 모른다 — 그 능력을 처음부터 다시 써야 하는 것이 이 설계의 첫 측정 대상이다.
    j = JSON3.read(read(ART, String))
    ms = Set(String.([m.name for m in j.methods]))
    @test !("release_pending_assignments!" in ms)
    @test "reform_stuck_teams!" in ms          # 빈-통과 방지: export 된 것은 실린다
end

@testset "(5) 🔴 D10: 무타입 Dict 두 개가 값 타입을 말한다" begin
    j = JSON3.read(read(ART, String))
    t = only(filter(x -> x.name == "PlannerEnv", collect(j.types)))
    ft = Dict(String(f.name) => String(f.type) for f in t.fields)
    # 🔴 이것이 없으면 모델은 `robot.charge` 를 지어낸다 (설계 §1.5)
    @test occursin("VelocityController", ft["agent_policies"])
    @test occursin("Bool", ft["agent_parent_build_step_active"])
    # 빈-통과 방지: 이미 타입이 실려 있던 필드는 그대로여야 한다
    @test occursin("Ball2", ft["staging_circles"])
    @test occursin("Float64", ft["staging_buffers"])
end
end # module
