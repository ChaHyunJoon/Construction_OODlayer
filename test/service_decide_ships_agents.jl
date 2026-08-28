# =============================================================================
# `service_decide` 가 실재 로봇 목록을 payload 에 실어 보내는지 못박는다.
# (2026-08-26, tool-lane step A, Task 2 — 리뷰 라운드 1 F2)
#
# 왜 이 파일이 필요한가
# ----------------------
# Task 2 가 고친 두 줄(payload 조립부의 `agents === nothing || (payload["agents"] = agents)`,
# 그리고 `decide_all` 호출부의 `agents = CB.open_agent_descriptors(env)`)은
# `policy_macro_binding.jl` · `battery_menu_lanes_agree.jl` 어느 쪽도 건드리지 않는다 —
# 둘 다 `service_decide` 를 부르지 않거나, 부르더라도 `agents` kwarg 없이 부른다. 실측:
# 두 줄을 각각 `error(...)` 로 바꿔치기해도 두 게이트는 바이트 동일하게 초록이었다.
# `tools/test_policy_oracle.jl` 도 `DEMO_ALL_POLICIES=0` 아래 `decide_all` 을 부르는데,
# 그건 정확히 `agents` 를 건너뛰는 삼항식의 `then` 가지다. 즉 이 두 줄은 **어떤 기존 게이트도
# 통과하지 않고 지나갈 수 있었다** — `open_agent_descriptors(env.sched)` 를 던졌던 옛 버전이
# 처음 이 자리에 들어올 수 있었던 것과 같은 구멍이다.
#
# 이 파일이 재는 세 가지:
#   1. `service_decide` 가 `agents` 라는 키워드 인자를 **선언한다** — 메서드 객체에서 직접
#      확인한다(주석이 아니라).
#   2. 실제 env 에서 `CB.open_agent_descriptors(env)` 가 **비어 있지 않은**
#      `Vector{Dict{String,String}}` 을 내고, 모든 원소가 `"id"`·`"label"` 을 둘 다 가진다.
#   3. **음성 대조**: `CB.open_agent_descriptors(env.sched)` 는 던진다. 이게 이 계획이 잡은
#      정확한 버그다(`env.sched` 를 넘기면 함수가 안에서 다시 `.sched` 를 찾다 죽는다) —
#      누가 호출부를 "간단히" `env.sched` 로 되돌리면 이 어서션이 빨개진다.
#
# 실행: julia +lts --project=. test/service_decide_ships_agents.jl
# =============================================================================
module ServiceDecideShipsAgents

using Test
using ConstructionBots
const CB = ConstructionBots
import HTTP, JSON3
import Random

const REPO = normpath(joinpath(@__DIR__, ".."))

# policy.jl 은 이 모듈 안으로 include 된다(policy_macro_binding.jl 과 같은 패턴) — `service_decide`
# 도 `ActionRegistry` 도 그 include 를 통해 같이 들어온다.
isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))
include(joinpath(REPO, "tools", "monitor", "policy.jl"))

# 실 env 를 짓는 것이 이 파일에서 가장 비싼 부분이다(policy_macro_binding.jl 의 env 구축과
# 비슷한 비용 — 이 시험이 도는 값이다). 씬은 SCENE-INCANTATION 정본과 같되, 여기서는
# 시뮬레이션을 한 스텝도 돌리지 않는다 — `open_agent_descriptors` 가 읽는 것은 배정이 끝난
# **스케줄 그래프**뿐이고, 그것은 `run_lego_demo` 가 return_env_before_sim=true 로 돌려주는
# 시점에 이미 완성돼 있다(로봇 배정까지 끝난 뒤). `@testset` 블록은 로컬 스코프라 `const` 를
# 그 안에 못 두므로, 모듈 최상위(테스트 블록 바깥)에서 짓는다.
const TENV = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr",
                                project_name = "service_decide_agents",
                                num_robots = 4, assignment_mode = :greedy,
                                n_spare_per_pool = 2,
                                open_animation_at_end = false, save_animation = false,
                                write_results = false, return_env_before_sim = true,
                                rng = Random.MersenneTwister(1))

@testset "service_decide 가 agents 를 payload 에 싣는다" begin

@testset "(1) service_decide 는 agents 키워드를 선언한다" begin
    local decls = Iterators.flatten(Base.kwarg_decl(m) for m in methods(service_decide))
    @test :agents in collect(decls)
end

@testset "(2) open_agent_descriptors(env) 가 실재 로봇을 낸다" begin
    local ag = CB.open_agent_descriptors(TENV)
    @test ag isa Vector{Dict{String,String}}
    @test !isempty(ag)
    @test all(d -> haskey(d, "id") && haskey(d, "label"), ag)
end

@testset "(3) 음성 대조 — env.sched 를 넘기면 던진다" begin
    # 브리프가 못박은 바로 그 버그: `open_agent_descriptors` 는 `env` 를 받아 **안에서**
    # `sched = env.sched` 를 꺼낸다. `env.sched` 를 직접 넘기면 그게 다시 `.sched` 를 찾다가
    # 죽는다. 호출부(policy.jl:1130 근방)가 나중에 `env.sched` 로 "단순화"되면 이 테스트가
    # 그 회귀를 잡는다.
    @test_throws ErrorException CB.open_agent_descriptors(TENV.sched)
end

end # testset

end # module
