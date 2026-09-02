# test/scoped_release.jl
# ============================================================================
#  이 파일이 지키는 것: `release_pending_assignments!` 의 **`agent` 범위 인자**.
#
#  왜 있는가 — 전체 release 는 후보 배정 간선을 3832개까지 열고, 뒤따르는 MILP 재풀이가
#  60초 상한을 **전 구간에서 다 쓴다**(closed=250, 후보 364 에서도 TIME_LIMIT).
#  대상 로봇이 소유한 간선으로 좁히면 후보가 **~1/19** 로 줄고 0.2초에 `OPTIMAL` 이 나온다
#  (`tools/probes/probe_release_in_harness.jl` · `probe_scoped_release.jl` 실측).
#
#  이 파일이 못 박는 것 셋:
#   [1] 기본 경로(`agent` 없음/`nothing`)가 떼는 집합 == 계약이 정의하는 해제가능 집합 **전부**.
#   [2] `agent` 를 주면 떼는 집합 == 계약이 정의하는 **그 로봇 소유분 전부**(건전성 + 완전성).
#   [3] `faulted` 와 `agent` 를 둘 다 주면 `ArgumentError` — 하나는 범위를 넓히고 하나는
#       좁히므로 합성 의미가 유일하지 않다. 조용히 하나를 무시하는 것이 최악이다.
#
#  🔴 [1]·[2] 는 **독립 오라클과의 집합 동일성**이다. 이전 판은 (a) `f(e1,inv1)` 을
#     `f(e2,inv2; agent=nothing)` 과 비교했는데 두 호출은 **같은 인자값으로 같은 메서드**에
#     들어가므로 기본 경로의 어떤 회귀도 못 잡았고(fork 의 결정성만 쟀다), (b) 뗀 간선이 전부
#     `a` 소유인지(**건전성**)만 보고 `a` 소유가 전부 떼졌는지(**완전성**)는 안 봤다.
#     덜 떼는 구현 — 이 원시의 목적이 "후보를 충분히 여는 것"이므로 가장 아픈 실패 —
#     이 그 단언을 전부 통과했다. 집합 동일성이 둘을 한 번에 막는다.
#
#  🔴 오라클은 **계약(docstring)에서 다시 유도**한다. 생산 코드를 베끼면 둘이 함께 틀린 채
#     초록이 된다. 그리고 release 는 그래프를 **변형**하므로 오라클은 호출 **전에** 잰다.
# ============================================================================
module ScopedReleaseTests

using Test
using ConstructionBots, Graphs, Random
const CB = ConstructionBots

# 🔴 런타임 include 는 **module 최상위**에 있어야 한다(world-age). 순서도 load-bearing:
#    `mdp.jl` 머리말이 "navigator.jl 을 먼저" 라고 명시한다(`observe.jl` 이
#    `_responsible_robots`·`SPARE_POOLS` 등을 쓴다). 바꾸지 말 것.
const REPO = joinpath(@__DIR__, "..")
isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))
isdefined(CB, :simstate_of)  || CB.include(joinpath(REPO, "src", "smdp", "mdp.jl"))

# --- 공용 픽스처 (계획 README 의 정본을 복사) ---------------------------------

"배터리·hazard·에너지 가중치가 켜진 env 를 만들어 `target_closed` 작업이 끝난 시점까지 전진."
function fixture(; board = "tractor.mpd", nr = 10, target_closed = 60, maxstep = 6000)
    env = CB.run_lego_demo(; ldraw_file = board, project_name = "cargoban", num_robots = nr,
                             assignment_mode = :greedy, n_spare_per_pool = 2,
                             open_animation_at_end = false, save_animation = false,
                             write_results = false, return_env_before_sim = true,
                             rng = Random.MersenneTwister(1))
    # 🔴 셋 다 필요하다. run_lego_demo 는 배터리를 초기화하지 않고(→ :no_fleet),
    #    init_objective_weights! 없이는 목적함수가 edge_costs 를 통째로 버린다.
    CB.enable_battery!(env); CB.enable_hazard!(env; seed = 7); CB.init_objective_weights!()
    k = 0
    while length(CB.simstate_of(env).prog.closed) < target_closed && k < maxstep
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0); k += 1; CB.set_sim_step!(k)
    end
    # 🔴 스텝 상한에 걸리면 씬은 요청한 시점이 **아니다** — 조용히 돌려주면 아래의 모든
    #    숫자가 다른 세계에서 온 것이 된다. 경고가 아니라 에러다(삼상 규약: 못 만들었으면
    #    "만들었다"고 말하지 않는다).
    got = length(CB.simstate_of(env).prog.closed)
    got < target_closed && error(
        "fixture: 스텝 상한 $maxstep 에 걸렸다 — closed = $got < target_closed = $target_closed. " *
        "씬이 요청한 시점이 아니므로 이 판의 어떤 수치도 쓸 수 없다.")
    return env
end

"""
계약에서 **다시 유도한** 해제가능 배정 간선의 집합 — 생산 코드의 사본이 아니다.

`release_pending_assignments!` 의 docstring 이 정의하는 것을 문장 그대로 옮긴다:
정상(= `faulted` 없음) 경로에서 배정 간선은 **양 끝이 모두** closed 도 active 도 아닐 때에만
해제 가능하고, `agent` 가 주어지면 **추가로** 출발점의 `_edge_owner_id` 가 그 문자열이어야 한다.

🔴 release 는 그래프를 변형하므로 반드시 release **전에** 부를 것.
"""
function releasable_edges(env; agent::Union{Nothing,AbstractString} = nothing)
    sched  = env.sched
    frozen = CB.build_invariant(env).closed_nodes                       # "끝난 것"
    running = Set{CB.AbstractID}(CB.get_vtx_id(sched, v) for v in env.cache.active_set)  # "진행 중"
    untouchable(id) = id in frozen || id in running                     # 계약: 이 둘은 못 건드린다
    want = Set{Tuple{Int,Int}}()
    for e in Graphs.edges(CB.get_graph(sched))
        CB.is_assignment_edge(sched, e.src, e.dst) || continue
        untouchable(CB.get_vtx_id(sched, e.src)) && continue            # 양 끝 각각을 따로 본다
        untouchable(CB.get_vtx_id(sched, e.dst)) && continue
        if agent !== nothing                                            # 범위: 소유자 일치만
            o = CB._edge_owner_id(sched, e.src)
            (o !== nothing && string(o) == agent) || continue
        end
        push!(want, (e.src, e.dst))
    end
    return want
end

"""
미래 배정 간선을 가장 많이 가진 로봇. 🔴 문자열은 **모듈 한정 형태**다 —
`"ConstructionBots.BotID{ConstructionBots.DeliveryBot}(4)"`. 손으로 짧게 쓰면 조용히 못 찾는다.
"""
function busiest_pending_agent_string(env)
    sched = env.sched
    t = Dict{String,Int}()
    for (u, _) in releasable_edges(env)
        o = CB._edge_owner_id(sched, u); o === nothing && continue
        t[string(o)] = get(t, string(o), 0) + 1
    end
    isempty(t) && error("미래 배정 간선이 0 — 재분배 창이 닫혔다. target_closed 를 줄여라")
    return sort(collect(t), by = kv -> -kv[2])[1][1]
end

# 🔴 `deepcopy` 만으로는 전역 RVO 시뮬레이터 상태를 공유한다 → `rvo_rebuild!` 가 필수다.
#    (`test/smdp_common_resolve.jl:36` · `test/smdp_generative.jl:97` 에 같은 관용구.)
#    씬을 **한 번만** 짓고 각 팔은 fork 로 복제한다 — "같은 시드, 같은 시점" 을 재실행이
#    아니라 **정의상** 보장한다.
fork(e) = (x = deepcopy(e); CB.rvo_rebuild!(x); x)

const ENV0 = fixture()

# ---------------------------------------------------------------------------

@testset "기본 경로는 해제가능 간선을 하나도 빠짐없이 전부 뗀다" begin
    e1 = fork(ENV0)
    want = releasable_edges(e1)               # 🔴 release **전에** 잰다(호출이 그래프를 바꾼다)
    @test !isempty(want)                      # 🔴 빈-통과 방지: 빈 집합과의 동일성은 공허하다
    # 🔴 invariant 는 release 대상 env 와 **같은 인스턴스**에서 만든다 — InvariantSpec 은
    #    정점 인덱스 기반 frozen_t0/frozen_tF 를 들고 있어 남의 env 에 먹이면 미정의다.
    r1 = CB.release_pending_assignments!(e1, CB.build_invariant(e1))
    @test Set(r1) == want                     # 건전성 + 완전성 (독립 오라클 대조)
    @test length(r1) == length(want)          # 같은 간선을 두 번 세지 않았다

    # `agent = nothing` 을 **명시**해도 같은 집합이다(기본값이 기본 경로다).
    e2 = fork(ENV0)
    r2 = CB.release_pending_assignments!(e2, CB.build_invariant(e2); agent = nothing)
    @test Set(r2) == want
end

@testset "agent 를 주면 그 로봇 것을 전부, 그리고 그것만 뗀다" begin
    ef = fork(ENV0)
    want_all = releasable_edges(ef)
    full = length(CB.release_pending_assignments!(ef, CB.build_invariant(ef)))
    @test full == length(want_all)
    @test full > 0                            # 🔴 빈-통과 방지

    env = fork(ENV0)
    a = busiest_pending_agent_string(env)
    want_a = releasable_edges(env; agent = a) # 🔴 release 전에
    @test !isempty(want_a)                    # 🔴 0 개면 이 시험은 공허하다
    scoped = CB.release_pending_assignments!(env, CB.build_invariant(env); agent = a)
    # 🔴 이 한 줄이 건전성("전부 a 소유")과 완전성("a 소유가 전부")을 동시에 못 박는다.
    #    앞 판의 per-edge 소유 루프는 완전성을 못 봤고, 스위트 총 pass 수를 씬에 의존하게 했다.
    @test Set(scoped) == want_a
    @test length(scoped) == length(want_a)
    @test length(scoped) < full               # 좁아졌다
    # 🔴 여기 있던 `@test issubset(want_a, want_all)` 은 **삭제했다** — 오라클끼리의 비교라
    #    `releasable_edges` 와 fork 의 결정성만으로 참이고, 어떤 생산 변경으로도 빨개질 수
    #    없었다(이 레포가 `@test r.n_reassigned >= 0` 항진으로 무동작 기능을 몇 주 놓친 자리다).
    #    포함관계는 위 두 집합 동일성이 이미 함의한다: testset 1 이 기본 경로 == want_all 을,
    #    여기가 좁힌 경로 == want_a 를 못 박고, want_a 는 정의상 want_all 의 부분집합이다.
end

@testset "faulted 와 agent 를 둘 다 주면 ArgumentError" begin
    e = fork(ENV0)
    a = busiest_pending_agent_string(e)
    inv = CB.build_invariant(e)
    # `faulted` 는 범위를 **넓히고**(그 로봇의 진행 중 목표까지 뗀다) `agent` 는 **좁힌다**.
    # 합성 의미가 유일하지 않으므로 조용히 하나를 무시하지 않고 막는다.
    @test_throws ArgumentError CB.release_pending_assignments!(
        e, inv; faulted = CB.RobotID(1), agent = a)
    # 🔴 음성 대조: 각각 하나만 주는 것은 여전히 통과해야 한다(위 단언이 항진이 아님을 보인다).
    e2 = fork(ENV0)
    @test CB.release_pending_assignments!(e2, CB.build_invariant(e2); agent = a) isa Vector
    e3 = fork(ENV0)
    @test CB.release_pending_assignments!(e3, CB.build_invariant(e3);
                                          faulted = CB.RobotID(1)) isa Vector
end

end # module
