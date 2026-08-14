# tools/monitor/test_narrate.jl
# 서술기 계약 검사. 합성 레코드만 쓴다 — 시뮬을 돌리지 않으므로 즉시 끝난다.
#
# 실행: julia +lts --project=. tools/monitor/test_narrate.jl
using Test
include(joinpath(@__DIR__, "narrate.jl"))

@testset "narrate_event" begin
    ev = Dict("kind" => "battery", "severity" => 0.9, "soc" => 0.02, "spare_count" => 3,
              "agent_pending" => 5, "progress" => 0.43, "robot" => "R7",
              "enacted" => "surrogate", "macro_name" => "SwapBattery",
              "fell_back" => false,
              "policies" => Dict("surrogate" => Dict("rationale" => "learned model",
                                                     "available" => true)))
    s = narrate_event(ev)
    @test occursin("battery", lowercase(s))
    @test occursin("SwapBattery", s)
    @test occursin("R7", s)

    # 계약 2: 없는 필드를 지어내지 않는다.
    bare = Dict("kind" => "fault", "enacted" => "canonical", "macro_name" => "Replace",
                "fell_back" => false)
    b = narrate_event(bare)
    @test !occursin("soc", lowercase(b))
    @test !occursin("nothing", lowercase(b))
    @test !occursin("missing", lowercase(b))

    # 계약 4: 폴백은 반드시 말한다.
    fb = Dict(bare..., "fell_back" => true, "requested" => "dspy")
    f = narrate_event(fb)
    @test occursin("fell back", lowercase(f)) || occursin("fallback", lowercase(f))
    @test occursin("dspy", lowercase(f))

    # 에너지가 결정적이었을 때만 그 문장이 뜬다(지어내지 않는다).
    @test !occursin("energy", lowercase(b))
    e = narrate_event(Dict(bare..., "energy_decisive" => true))
    @test occursin("energy", lowercase(e))
end

@testset "narrate_outcome" begin
    # 계약 3: 완주인데 closed<total 을 미완주로 서술하지 않는다.
    #         이 하니스는 완주해도 closed<total 이다(실측 291/313, md/README.md §6).
    done = Dict("complete" => true, "closed" => 291, "total" => 313, "n_stalled" => 0)
    d = narrate_outcome(done)
    @test occursin("complete", lowercase(d))
    @test !occursin("incomplete", lowercase(d))
    @test !occursin("did not finish", lowercase(d))

    # 계약 5: 정지 0 을 "문제 없음" 으로 서술하지 않는다 — 미완주는 정지 없이도 일어난다.
    nostall = Dict("complete" => false, "closed" => 254, "total" => 313, "n_stalled" => 0)
    n = narrate_outcome(nostall)
    @test occursin("incomplete", lowercase(n))
    @test !occursin("no problem", lowercase(n))
    @test !occursin("healthy", lowercase(n))

    stalled = Dict("complete" => false, "closed" => 254, "total" => 313, "n_stalled" => 43)
    st = narrate_outcome(stalled)
    @test occursin("43", st)
    @test occursin("stall", lowercase(st))

    # 계약 2: n_stalled 가 없으면 정지를 아예 언급하지 않는다.
    #         (로그의 [STALL] 은 Logging.Warn 에 삼켜지므로 n_stalled 가 유일한 기계적 증거다.)
    unknown = Dict("complete" => false, "closed" => 254, "total" => 313)
    u = narrate_outcome(unknown)
    @test !occursin("stall", lowercase(u))
    # energy_J 가 없으면 에너지도 언급하지 않는다.
    @test !occursin(" j", lowercase(u))

    # energy_J 가 있으면 J/closed 까지 말한다(energy 가 J 의 축이므로).
    withE = Dict("complete" => true, "closed" => 291, "total" => 313, "energy_J" => 77600.0)
    w = narrate_outcome(withE)
    @test occursin("77600", replace(w, "," => "")) || occursin("J", w)
    @test occursin("per closed node", w)
end

@testset "purity" begin
    ev = Dict("kind" => "zone", "enacted" => "canonical", "macro_name" => "RelocateBuild",
              "fell_back" => false)
    @test narrate_event(ev) == narrate_event(ev)
    sm = Dict("complete" => true, "closed" => 291, "total" => 313)
    @test narrate_outcome(sm) == narrate_outcome(sm)
end
