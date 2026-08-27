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

@testset "어휘 미달이 novelty 보다 먼저다 (2026-08-27, 축 1)" begin
    UP = Dict("surrogate" => true, "dspy" => true, "canonical" => true)

    # (A) 지원 밖 팔이 있으면, 상태가 익숙해도 LLM 으로 간다.
    r = select_lane(novel = false, available = UP, supported = false, policy = "dspy")
    @test r.lane == "dspy"
    @test r.axis == "vocabulary_gap"

    # (B) 🔴 두 축이 동시에 참이면 **어휘 미달이 이긴다.** 순서가 뒤집히면 기록이
    #     "낯설어서 올렸다" 가 되는데 사실은 "그 팔을 배운 적이 없어서" 다 — 다른 사건이고,
    #     전자는 교정 파일에 의존하지만 후자는 안 한다.
    r2 = select_lane(novel = true, available = UP, supported = false, policy = "dspy")
    @test r2.lane == "dspy"
    @test r2.axis == "vocabulary_gap"

    # (C) 어휘는 되는데 상태가 낯설면 novelty 축이다 (축 2 가 생기기 전 임시 자리).
    r3 = select_lane(novel = true, available = UP, supported = true, policy = "dspy")
    @test r3.lane == "dspy"
    @test r3.axis == "novelty"

    # (D) 둘 다 아니면 surrogate 이고, 발화한 축이 없다.
    r4 = select_lane(novel = false, available = UP, supported = true, policy = "dspy")
    @test r4.lane == "surrogate"
    @test r4.axis == "none"

    # (E) 통제 바닥선은 축 판정 자체를 안 한다.
    r5 = select_lane(novel = true, available = UP, supported = false, policy = "noop")
    @test r5.lane == "noop"
    @test r5.axis == "control"

    # (F) 어휘 미달인데 LLM 이 없으면 canonical 로 떨어지되 **축은 그대로 기록된다** —
    #     "못 올렸다" 와 "올릴 일이 없었다" 는 다른 사건이다.
    r6 = select_lane(novel = false,
                     available = Dict("surrogate" => true, "dspy" => false, "canonical" => true),
                     supported = false, policy = "dspy")
    @test r6.lane == "canonical"
    @test r6.axis == "vocabulary_gap"
end
