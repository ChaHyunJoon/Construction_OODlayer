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
#   [1] `agent` 를 안 주면(기본) **오늘과 같은 동작** — 기존 호출자가 안 깨진다.
#   [2] `agent` 를 주면 그 로봇이 소유한 미래 배정 간선만 뗀다(그리고 그것은 전체의 진부분집합).
#   [3] `faulted` 와 `agent` 를 둘 다 주면 `ArgumentError` — 하나는 범위를 넓히고 하나는
#       좁히므로 합성 의미가 유일하지 않다. 조용히 하나를 무시하는 것이 최악이다.
#
#  🔴 빈-통과 방지: 각 팔이 **실제로 뗀 간선이 있는지**를 먼저 단언한다. 재분배 창은 빌드
#     후반(closed ≈ 247/287)에 닫히므로, 0개를 처리하고 초록인 것이 이 시험의 최대 위험이다.
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
function fixture(; board = "tractor.mpd", nr = 10, target_closed = 60)
    env = CB.run_lego_demo(; ldraw_file = board, project_name = "cargoban", num_robots = nr,
                             assignment_mode = :greedy, n_spare_per_pool = 2,
                             open_animation_at_end = false, save_animation = false,
                             write_results = false, return_env_before_sim = true,
                             rng = Random.MersenneTwister(1))
    # 🔴 셋 다 필요하다. run_lego_demo 는 배터리를 초기화하지 않고(→ :no_fleet),
    #    init_objective_weights! 없이는 목적함수가 edge_costs 를 통째로 버린다.
    CB.enable_battery!(env); CB.enable_hazard!(env; seed = 7); CB.init_objective_weights!()
    k = 0
    while length(CB.simstate_of(env).prog.closed) < target_closed && k < 6000
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0); k += 1; CB.set_sim_step!(k)
    end
    return env
end

"""
미래 배정 간선을 가장 많이 가진 로봇. 🔴 문자열은 **모듈 한정 형태**다 —
`"ConstructionBots.BotID{ConstructionBots.DeliveryBot}(4)"`. 손으로 짧게 쓰면 조용히 못 찾는다.
"""
function busiest_pending_agent_string(env)
    sched = env.sched; inv = CB.build_invariant(env)
    act = Set{CB.AbstractID}(CB.get_vtx_id(sched, v) for v in env.cache.active_set)
    t = Dict{String,Int}()
    for e in Graphs.edges(CB.get_graph(sched))
        v, v2 = e.src, e.dst
        CB.is_assignment_edge(sched, v, v2) || continue
        i1 = CB.get_vtx_id(sched, v); i2 = CB.get_vtx_id(sched, v2)
        (i1 in inv.closed_nodes || i2 in inv.closed_nodes || i1 in act || i2 in act) && continue
        o = CB._edge_owner_id(sched, v); o === nothing && continue
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

@testset "agent 를 안 주면 오늘과 같은 동작이다" begin
    e1 = fork(ENV0); e2 = fork(ENV0)          # 같은 씬, 같은 시점 (deepcopy 가 보장)
    # 🔴 invariant 는 release 대상 env 와 **같은 인스턴스**에서 만든다 — InvariantSpec 은
    #    정점 인덱스 기반 frozen_t0/frozen_tF 를 들고 있어 남의 env 에 먹이면 미정의다.
    r1 = CB.release_pending_assignments!(e1, CB.build_invariant(e1))
    r2 = CB.release_pending_assignments!(e2, CB.build_invariant(e2); agent = nothing)
    @test !isempty(r1)                        # 🔴 빈-통과 방지: 실제로 뗀 게 있어야 비교가 뜻이 있다
    @test length(r1) == length(r2)
    @test Set(r1) == Set(r2)
end

@testset "agent 를 주면 그 로봇 것만 뗀다" begin
    ef = fork(ENV0)
    full_removed = CB.release_pending_assignments!(ef, CB.build_invariant(ef))
    full = length(full_removed)
    @test !isempty(full_removed)              # 🔴 빈-통과 방지

    env = fork(ENV0)
    a = busiest_pending_agent_string(env)
    scoped = CB.release_pending_assignments!(env, CB.build_invariant(env); agent = a)
    @test !isempty(scoped)                    # 🔴 0 개면 이 시험은 공허하다
    @test length(scoped) < full               # 좁아졌다
    @test issubset(Set(scoped), Set(full_removed))   # 넓힌 게 아니라 좁힌 것이다

    # 뗀 간선의 출발점이 전부 그 로봇 소유인가. release 는 dst 슬롯(v2)만
    # `reset_slot_to_invalid!` 하고 src(u) 는 안 건드리므로 사후 조회가 성립한다.
    for (u, _) in scoped
        o = CB._edge_owner_id(env.sched, u)
        @test o !== nothing && string(o) == a
    end
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
