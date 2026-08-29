# =============================================================================
# `service_decide` 가 실재 로봇 목록을 payload 에 실어 보내는지 못박는다.
# (2026-08-26, tool-lane step A, Task 2 — 리뷰 라운드 1 F2 · 라운드 2 G1+G2)
#
# 왜 이 파일이 필요한가
# ----------------------
# Task 2 가 고친 두 줄(payload 조립부의 `agents === nothing || (payload["agents"] = agents)`,
# 그리고 `decide_all` 호출부의 `agents = CB.open_agent_descriptors(env)`)은
# `policy_macro_binding.jl` · `battery_menu_lanes_agree.jl` 어느 쪽도 건드리지 않는다 —
# 둘 다 `service_decide` 를 부르지 않거나, 부르더라도 `agents` kwarg 없이 부른다.
# `tools/test_policy_oracle.jl` 도 `decide_all` 을 부르지만 `withenv("DEMO_ALL_POLICIES"=>"0")`
# 아래서다 — 그건 정확히 `agents` 를 건너뛰는 삼항식의 `then` 가지다.
#
# 🔴 라운드 1 (F2) 은 이 구멍을 **부분적으로만** 메웠다. 실측(라운드 2 validator, 각 줄을
# `error(...)` 로 바꿔치기): 아래 (1)~(3) 은 `service_decide` 의 **시그니처**(kwarg 선언)와
# `open_agent_descriptors` **원시 함수**만 잰다. payload 조립 줄(policy.jl:~550)과 `decide_all`
# 호출부 줄(policy.jl:~1134)은 둘 다 (1)~(3) 이 한 번도 안 태운다 — 실제로 `env.sched` 로 되돌린
# 원래 버그를 되살려도 (1)~(3) 은 Pass 5/5 로 그대로 초록이었다. 이제 (4) 가 `decide_all` 을
# **직접 실행**해서 그 두 줄을 진짜로 태운다: `dspy_ready()` 를 `true` 로, `HTTP.post` 를
# 요청 본문을 가로채는 스텁으로 바꿔치기하고, `decide_all(env, truth)` 를 부른 뒤 가로챈 본문의
# `"agents"` 가 `CB.open_agent_descriptors(env)` 와 같은지 확인한다. 이 경로는 (a) payload 조립
# 줄이 실제로 도는지, (b) `decide_all` 호출부가 실제로 그 값을 실어 보내는지, 둘 다 하나의
# 실행으로 잰다 — 아래 GREEN/RED 근거는 두 줄을 각각 `error(...)` 로 바꾼 스크래치패드 사본에서
# 이 파일 전체가 실제로 빨개지는 것으로 실측했다(수정 라운드 2 보고서 참조).
#
# 이 파일이 재는 네 가지:
#   1. `service_decide` 가 `agents` 라는 키워드 인자를 **선언한다** — 메서드 객체에서 직접
#      확인한다(주석이 아니라). (커버: kwarg 선언 줄만. payload 조립·호출부는 아래 (4).)
#   2. 실제 env 에서 `CB.open_agent_descriptors(env)` 가 **비어 있지 않은**
#      `Vector{Dict{String,String}}` 을 내고, 모든 원소가 `"id"`·`"label"` 을 둘 다 가진다.
#      (커버: `open_agent_descriptors` 원시 함수 자체. 호출부가 이 함수를 **부르는지**는 안 잰다.)
#   3. **음성 대조**: `CB.open_agent_descriptors(env.sched)` 는 던진다. `env` 대신 `env.sched` 를
#      넘기면 함수가 안에서 다시 `.sched` 를 찾다가 죽는다는, 이 계획이 잡은 정확한 버그를 그
#      원시 함수 수준에서 못박는다. (커버: 원시 함수의 인자 계약. `decide_all` 호출부가 실제로
#      `env` 를 넘기는지는 이 어서션 혼자로는 안 잰다 — 그건 아래 (4) 의 몫이다.)
#   4. **payload 조립 + `decide_all` 호출부, 둘 다 실제 실행으로**: `decide_all(env, truth)` 가
#      네트워크로 나가는 요청 본문에 `open_agent_descriptors(env)` 와 같은 `"agents"` 를 싣는다.
#
# 실행: julia +lts --project=. test/service_decide_ships_agents.jl
# =============================================================================
module ServiceDecideShipsAgents

using Test
using ConstructionBots
const CB = ConstructionBots
import HTTP, JSON3
import Random
# Graphs 는 policy.jl 의 `_agent_pending`(ood_features 경유, service_decide 가 부른다)이 쓴다
# -- policy.jl 은 스크립트라 자기 의존성을 안 들고 온다(CLAUDE.md Gotchas). policy_macro_binding.jl
# ·battery_menu_lanes_agree.jl 은 service_decide 를 안 불러서 이게 없어도 됐다; 이 파일은 (4)
# 에서 실제로 부르므로 있어야 한다(tools/test_policy_oracle.jl 과 같은 이유로 같은 import).
import Graphs

const REPO = normpath(joinpath(@__DIR__, ".."))

# policy.jl 은 이 모듈 안으로 include 된다(policy_macro_binding.jl 과 같은 패턴) — `service_decide`
# 도 `decide_all` 도 `dspy_ready` 도 그 include 를 통해 **이 모듈 안에서만** 정의된다(각 파일이
# policy.jl 을 저마다의 모듈로 include 하므로 `dspy_ready` 는 파일마다 별개 함수다 — 아래 스텁이
# 다른 게이트로 새지 않는 이유).
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

# ---- (4) 를 위한 스텁 --------------------------------------------------------
# `dspy_ready` 는 이 모듈 안에서만 정의된 함수라(위 주석), 아래 재정의는 진짜로
# module-local 이다 — 다른 파일이 include 한 policy.jl 의 `dspy_ready` 에는 안 닿는다.
dspy_ready() = true

# `HTTP.post` 는 다르다 — `HTTP` 는 패키지 모듈이라 프로세스 전체가 공유하고,
# `import HTTP` 로 가져온 이름은 그 **하나뿐인** 전역 바인딩을 가리킨다. 그래서 아래
# 재정의는 module-local 이 아니라 **프로세스 전역**이다(2026-08-28 리뷰 라운드 2 — coordinator
# 가 승인한 경로: "policy.jl 을 건드리지 않고 닿을 수 있는" 유일한 자리). 위험을 좁히는 두 장치:
#   · 타입을 3-positional-arg(url·body 둘 다 AbstractString)로 좁힌다 — 레포 전체에서 이 서명과
#     맞아떨어지는 `HTTP.post` 호출은 이 파일과 `src/respec/llm_bridge.jl` 단 둘뿐이고, 후자는
#     in-process 스위트(runtests.jl)에서 한 번도 안 돈다(grep 실측, 이 파일 마지막 절 참조).
#   · `_STUB_ACTIVE[]` 가 꺼져 있으면(테스트 밖에서 우연히 걸리면) 조용히 진짜 네트워크로 새는
#     대신 **크게 던진다** — 8077 에 진짜 DSPy 서비스가 떠 있어도(이 리뷰가 실측한 상태) 이
#     스텁이 안 걸리면 침묵하는 실패 대신 시끄러운 실패를 낸다.
const _CAPTURED_BODY = Ref{Union{Nothing,String}}(nothing)
const _STUB_ACTIVE = Ref(false)

function HTTP.post(url::AbstractString, headers, body::AbstractString; kwargs...)
    _STUB_ACTIVE[] ||
        error("HTTP.post stub (test/service_decide_ships_agents.jl) 이 무장 안 된 채 호출됐다 " *
              "-- 진짜 네트워크로 새는 대신 여기서 던진다. 이 서명과 맞는 새 호출자가 생겼다면 " *
              "이 스텁의 타입을 좁히거나 스텁을 이 파일에서만 켜고 끄는 범위를 다시 봐야 한다.")
    _CAPTURED_BODY[] = String(body)
    return (status = 200,
            body = Vector{UInt8}(codeunits(JSON3.write(Dict("dspy" => nothing, "surrogate" => nothing)))))
end

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
    # 죽는다. 이 어서션은 그 원시 함수의 인자 계약을 잰다 — `decide_all` 호출부가 실제로
    # `env`(아닌 `env.sched`)를 넘기는지는 이 원시 함수 검사 혼자로는 못 잰다(라운드 2에서
    # 실측된 한계). 그건 바로 아래 (4) 가 `decide_all` 을 직접 실행해서 잰다.
    @test_throws ErrorException CB.open_agent_descriptors(TENV.sched)
end

@testset "(4) decide_all → service_decide 가 실제로 agents 를 실어 보낸다 (스텁 HTTP)" begin
    # 라운드 2 (G1+G2) 가 요구한 바로 그 시험: payload 조립 줄과 decide_all 호출부 줄을
    # 둘 다 **실제로** 태운다. `decide_all` 을 부르면 그 안에서 (조건에 따라) `service_decide`
    # 가 불리고, 그 안에서 `HTTP.post` 가 불린다 — 우리 스텁이 그 요청 본문을 가로챈다.
    _CAPTURED_BODY[] = nothing
    _STUB_ACTIVE[] = true
    local truth = CB.BatteryTruth(CB.RobotID(1), 0.5)
    try
        decide_all(TENV, truth; nl = "")
    finally
        _STUB_ACTIVE[] = false     # 이 시험 밖에서는 다시 무장 해제 -- 밖에서 걸리면 위에서 던진다.
    end
    # 스텁이 실제로 맞았는가 -- 안 맞았으면 진짜 8077 로 샌 것이고, 그러면 이 assert 이전에
    # `decide_all` 자체가 (네트워크가 살아있다면) 성공해 버려 `_CAPTURED_BODY[]` 가 `nothing` 인
    # 채로 남는다. 그래서 이 assert 가 없으면 "네트워크로 조용히 샜다" 를 "통과했다" 로 오독한다.
    @test _CAPTURED_BODY[] !== nothing
    local parsed = JSON3.read(something(_CAPTURED_BODY[], "{}"))
    @test haskey(parsed, "agents")
    local wire_agents = [Dict{String,String}(string(k) => string(v) for (k, v) in pairs(a))
                         for a in get(parsed, "agents", [])]
    @test wire_agents == CB.open_agent_descriptors(TENV)
end

end # testset

end # module
