# tools/monitor/test_lane_select.jl
# 3-way 분기표 전수 검사. 순수 함수라 즉시 끝난다.
#
# 실행: julia +lts --project=. tools/monitor/test_lane_select.jl
using Test
include(joinpath(@__DIR__, "lane_select.jl"))

const ALL_UP = Dict("surrogate" => true, "dspy" => true, "canonical" => true)

@testset "3-way 분기" begin
    # 낯설다 -> LLM
    r = select_lane(novel = true, available = ALL_UP, supported = true, policy = "router")
    @test r.lane == "dspy"
    @test occursin("novel", lowercase(r.reason))

    # 익숙하다 -> surrogate
    r = select_lane(novel = false, available = ALL_UP, supported = true, policy = "router")
    @test r.lane == "surrogate"
    @test occursin("familiar", lowercase(r.reason))

    # 익숙한데 surrogate 가 그 팔을 지원하지 않는다 -> LLM 으로 에스컬레이션(기존 동작)
    r = select_lane(novel = false, available = ALL_UP, supported = false, policy = "router")
    @test r.lane == "dspy"
    @test occursin("support", lowercase(r.reason))

    # 지원도 없고 LLM 도 죽었다 -> canonical (신규 3번째 주자)
    down = Dict("surrogate" => true, "dspy" => false, "canonical" => true)
    r = select_lane(novel = false, available = down, supported = false, policy = "router")
    @test r.lane == "canonical"
    @test occursin("canonical", lowercase(r.reason))
    @test occursin("unavailable", lowercase(r.reason))

    # 낯선데 LLM 이 죽었다 -> canonical. surrogate 로 조용히 떨어지지 않는다.
    r = select_lane(novel = true, available = down, supported = true, policy = "router")
    @test r.lane == "canonical"

    # surrogate 도 dspy 도 죽었다 -> canonical
    allx = Dict("surrogate" => false, "dspy" => false, "canonical" => true)
    r = select_lane(novel = false, available = allx, supported = true, policy = "router")
    @test r.lane == "canonical"
end

@testset "noop 은 라우팅 대상이 아니다" begin
    # 통제 실험의 바닥선. 아무도 이 레인을 대신 판단해 주면 안 된다(policy.jl:333 규칙).
    r = select_lane(novel = true, available = ALL_UP, supported = true, policy = "noop")
    @test r.lane == "noop"
end

@testset "DP 는 절대 타깃이 아니다" begin
    # Global Constraint 10. DP 는 천장이라 실행 정책과 같은 줄에 세우지 않는다.
    for nov in (true, false), sup in (true, false)
        r = select_lane(novel = nov, available = Dict("surrogate" => sup, "dspy" => sup,
                                                      "canonical" => true, "dp" => true),
                        supported = sup, policy = "router")
        @test r.lane != "dp"
    end
end

@testset "reason 은 언제나 비지 않는다" begin
    for nov in (true, false), sup in (true, false), d in (true, false)
        r = select_lane(novel = nov,
                        available = Dict("surrogate" => true, "dspy" => d, "canonical" => true),
                        supported = sup, policy = "router")
        @test !isempty(r.reason)
    end
end
