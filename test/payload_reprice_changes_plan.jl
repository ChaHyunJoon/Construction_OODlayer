# test/payload_reprice_changes_plan.jl
#   julia +lts --project=. test/payload_reprice_changes_plan.jl
# 🔴 이 파일이 막으려는 실패 모양은 **침묵 성공**이다: 원시가 `:repriced` 를 내는데 세계는
#    바이트 동일인 것. 그래서 반환 심볼을 증거로 쓰지 않고 edge_costs 를 직접 비교한다.
#    음성 대조 둘을 짝으로 갖는다 — (a) release 없음, (b) light_bias = 0.
#
# 🔴 ADDENDUM (task-5-addendum.md, Rulings 7/8/9) 반영:
#   (1) fresh_env() 는 CB.enable_battery! 로 함대를 켠다 — run_lego_demo 는 함대를 안 켠다.
#   (2) G-2 의 `Dict()==Dict()` 타당론을 막기 위해 훅 호출 횟수 대조를 추가한다.
#   (3) costs()/busiest_agent() 는 CB.INVALID_ID_COUNTERS 를 스냅샷/복원한다.
module PayloadRepriceChangesPlanTest
using Test
using ConstructionBots
import Random, Graphs
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))

function fresh_env()
    env = CB.run_lego_demo(; ldraw_file = "tractor.mpd", project_name = "s2chain",
                       num_robots = 10, assignment_mode = :greedy, n_spare_per_pool = 2,
                       open_animation_at_end = false, save_animation = false,
                       write_results = false, return_env_before_sim = true,
                       rng = Random.MersenneTwister(1))
    CB.enable_battery!(env; params = CB.BatteryParams())   # 🔴 addendum 정정 1: 함대를 켠다
    return env
end

"""
    count_hook_calls!() -> Union{Nothing,Ref{Int}}

`EDGE_PAYLOAD_MULTIPLIER[]` 에 설치된 훅을 세는 래퍼로 감싼다. 훅이 안 꽂혀 있으면 `nothing`
(삼상 규약: "못 쟀다" ≠ 0). 반드시 `Ref` 에 담는다 — top-level for 안의 평범한 정수는 soft
scope 라 조용한 0 이 된다.
"""
function count_hook_calls!()
    inner = CB.EDGE_PAYLOAD_MULTIPLIER[]
    inner === nothing && return nothing
    n = Ref(0)
    CB.EDGE_PAYLOAD_MULTIPLIER[] = (sched, v, v2) -> (n[] += 1; inner(sched, v, v2))
    return n
end

"release 여부와 재가격 여부를 조합해 edge_costs 를 낸다. `call_counter` 를 넘기면 그 Ref 에
훅 호출 횟수를 채운다(설치가 안 됐으면 `nothing` 인 채로 둔다)."
function costs(env; release::Bool, agent = nothing, light_bias = 0.5, call_counter::Ref{Union{Nothing,Ref{Int}}} = Ref{Union{Nothing,Ref{Int}}}(nothing))
    saved_ids = copy(CB.INVALID_ID_COUNTERS)              # 🔴 addendum 정정 3
    return try
        sched, tree = deepcopy((env.sched, env.scene_tree))
        shim = (sched = sched, scene_tree = tree, cache = env.cache)
        release && CB.release_pending_assignments!(shim, CB.build_invariant(env))
        CB.clear_payload_bias!()
        if agent !== nothing
            r = CB.reprice_agent_by_payload!(shim; agent = agent, light_bias = light_bias)
            @assert r.status === :repriced "reprice did not install: $(r.status)"   # 전제조건일 뿐, 증거 아님
        end
        call_counter[] = count_hook_calls!()
        sent = Dict{Tuple{Int,Int},Float64}()
        CB.LAST_EDGE_COSTS[] = sent
        CB.formulate_milp(CB.SparseAdjacencyMILP(), sched, tree; optimizer = CB._respec_optimizer())
        @assert !(CB.LAST_EDGE_COSTS[] === sent) "formulate 가 안 돌았다"
        out = copy(CB.LAST_EDGE_COSTS[])
        CB.clear_payload_bias!()
        out
    finally
        empty!(CB.INVALID_ID_COUNTERS); merge!(CB.INVALID_ID_COUNTERS, saved_ids)
    end
end

"후보 간선에서 가장 많이 등장하는 유효 owner id (재가격 대상으로 쓴다)."
function busiest_agent(env)
    saved_ids = copy(CB.INVALID_ID_COUNTERS)              # 🔴 addendum 정정 3
    return try
        sched, tree = deepcopy((env.sched, env.scene_tree))
        shim = (sched = sched, scene_tree = tree, cache = env.cache)
        CB.release_pending_assignments!(shim, CB.build_invariant(env))
        sent = Dict{Tuple{Int,Int},Float64}(); CB.LAST_EDGE_COSTS[] = sent
        CB.formulate_milp(CB.SparseAdjacencyMILP(), sched, tree; optimizer = CB._respec_optimizer())
        tally = Dict{String,Int}()
        for (v, _) in keys(CB.LAST_EDGE_COSTS[])
            id = CB._edge_owner_id(sched, v)
            id === nothing && continue
            tally[string(id)] = get(tally, string(id), 0) + 1
        end
        first(sort(collect(tally), by = kv -> -kv[2]))[1]
    finally
        empty!(CB.INVALID_ID_COUNTERS); merge!(CB.INVALID_ID_COUNTERS, saved_ids)
    end
end

@testset "G-2 · release 가 없으면 후보 간선이 없고 재가격은 무동작이다" begin
    env = fresh_env()
    a = busiest_agent(env)
    cnt_plain = Ref{Union{Nothing,Ref{Int}}}(nothing)
    cnt_bias  = Ref{Union{Nothing,Ref{Int}}}(nothing)
    no_rel_plain = costs(env; release = false, call_counter = cnt_plain)
    no_rel_bias  = costs(env; release = false, agent = a, light_bias = 2.0, call_counter = cnt_bias)
    @test length(no_rel_plain) == 0                 # 🔴 실측된 사실: release 없이는 0
    @test no_rel_plain == no_rel_bias               # 세계가 바이트 동일
    # 🔴 addendum 정정 2: 타당론 방지 — 훅이 실제로 설치돼 0번 불렸는지 대조한다.
    @test cnt_plain[] === nothing                    # release=false, agent=nothing: 훅이 설치조차 안 됐다
    @test cnt_bias[] !== nothing                     # release=false, agent 지정: 훅은 설치됐다
    @test cnt_bias[][] == 0                          # …하지만 후보 간선이 0 개라 0번 불렸다
end

@testset "G-4 · release 뒤에는 재가격이 실제로 비용을 바꾼다" begin
    env = fresh_env()
    a = busiest_agent(env)
    cnt_base = Ref{Union{Nothing,Ref{Int}}}(nothing)
    cnt_zero = Ref{Union{Nothing,Ref{Int}}}(nothing)
    cnt_hot  = Ref{Union{Nothing,Ref{Int}}}(nothing)
    base = costs(env; release = true, call_counter = cnt_base)
    zero = costs(env; release = true, agent = a, light_bias = 0.0, call_counter = cnt_zero)   # 음성 대조
    hot  = costs(env; release = true, agent = a, light_bias = 2.0, call_counter = cnt_hot)
    @test length(base) > 0
    @test keys(base) == keys(zero) == keys(hot)     # 실행가능집합은 안 바뀐다
    @test base == zero                              # 🔴 bias 0 이면 바이트 동일
    @test base != hot                               # 🔴 bias > 0 이면 달라진다
    @test all(hot[k] >= base[k] - 1e-9 for k in keys(base))   # 절대 싸지지 않는다
    changed = count(k -> hot[k] > base[k] + 1e-9, collect(keys(base)))
    @test changed > 0
    @test changed < length(base)                    # 대상 로봇의 간선만 바뀐다(전역 배율이 아니다)
    # 🔴 addendum 정정 2: 호출-횟수 대조. base 에는 agent 가 없으므로 훅이 안 설치된다(nothing).
    @test cnt_base[] === nothing
    @test cnt_zero[] !== nothing && cnt_zero[][] == length(base)   # 후보 간선마다 한 번씩
    @test cnt_hot[]  !== nothing && cnt_hot[][]  == length(base)
end
end # module
