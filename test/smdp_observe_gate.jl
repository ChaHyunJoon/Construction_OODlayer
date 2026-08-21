# =============================================================================
# test/smdp_observe_gate.jl  —  게이트 N-G0 (독립 실행. runtests.jl 에 넣지 않는다)
#
#   julia +lts --project=. test/smdp_observe_gate.jl
#
# `simstate_of(env)` 가 실제 env 를 충실히 읽는가. 방법은 **음성 대조**다: env(또는 그 env 가
# 사는 프로세스 전역)를 한 군데씩 흔들고 해시가 갈리는지 본다. 안 갈리는 필드는 그 자리에서
# 두 세계를 조용히 합친다 — MCTS 트리 노드 하나에 서로 다른 두 상황의 통계가 섞인다.
#
# 그리고 `simstate_of` 는 **읽기 전용**이어야 한다 — 관측이 세계를 바꾸면 같은 상태를 두 번
# 관측한 것만으로 롤아웃이 갈라진다.
#
# 🔴 **계획서(task-4-brief.md)의 시험 코드는 그대로 못 쓴다.** 확인된 오류는 보고서
# (.superpowers/sdd/2026-08-20-sojourn-generative-smdp/task-4-report.md) 에 전부 적었다.
# 요약: 세 전역이 전부 `Ref` 라 `[]` 가 필요하고(`RESTRICTION_ZONES[]` …), 씬 파일 이름은
# `colored_8x8.mpd` 가 아니라 `colored_8x8.ldr` 이며, `rendering`·`process_animation_tasks` 는
# `run_lego_demo` 의 키워드가 아니다.
#
# 🔴 **왜 대조를 매번 그 자리에서 다시 재는가**: 각 블록이 `h()` 를 자기 시작점에서 새로 뽑는다.
# 하나의 전역 h0 를 쓰면, 앞의 어떤 교란이 완벽하게 복원되지 않았을 때 그 오염이 뒤의 모든
# 단언으로 번져 "무엇이 실제로 갈렸는가"를 못 읽게 된다.
# =============================================================================
using ConstructionBots, Test
import Random
import Graphs
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

# colored_8x8 = 33부품 x 1층. 이 레포에서 가장 싼 실제 씬(project_params.jl:19 "33 x 1, 4 sec").
# `return_env_before_sim=true` 로 **시뮬 루프 직전의 완성된 env** 만 받는다(full_demo.jl:861) —
# 판을 끝까지 굴리지 않으므로 게이트가 분 단위에서 끝난다.
# `n_spare_per_pool=2` 는 창고 예비를 채운다: 그게 없으면 `role=:spare_parked` 와 배송(courier)
# 축이 통째로 도메인이 비어 시험이 항진명제가 된다.
env = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "ng0",
                         num_robots = 6, assignment_mode = :greedy,
                         n_spare_per_pool = 2,
                         open_animation_at_end = false, save_animation = false,
                         write_results = false, return_env_before_sim = true,
                         rng = Random.MersenneTwister(1))
CB.enable_battery!(env)
CB.enable_hazard!(env; seed = 11)

# 스텝 하나만 굴리면 로봇이 전부 :idle 이라 `mode` 축이 상수가 된다(= 아무것도 못 가른다).
# 명목 루프의 최소 형태(demo_utils.jl:157-158)를 그대로 40스텝 돌려 진짜 진행 상태를 만든다.
for k in 1:40
    CB.step_environment!(env)
    CB.update_planning_cache!(env, 0.0)
    CB.set_sim_step!(k)
end

h() = CB.state_hash(CB.simstate_of(env))
const FLEET = CB.BATTERY_FLEET[]
const HZ    = CB.HAZARD_STATE[]
const RIDS  = sort!(collect(keys(FLEET.soc)); by = string)
const RID   = first(RIDS)
const RID2  = RIDS[2]

@testset "simstate_of 는 읽기 전용이다" begin
    before_closed  = length(env.cache.closed_set)
    before_active  = length(env.cache.active_set)
    before_soc     = copy(FLEET.soc)
    before_usage   = copy(HZ.usage_s)
    before_eff     = copy(HZ.eff)          # 🔴 _hz_ensure! 를 부르면 여기가 늘어난다(난수도 태운다)
    before_broken  = copy(HZ.broken)
    before_deliv   = length(CB.BATTERY_DELIVERIES[])
    before_zones   = copy(CB.RESTRICTION_ZONES[])
    before_step    = CB.SIM_STEP[]
    # 🔴 가장 미묘한 자리: `global_transform`(hierarchical_geom_essentials.jl:347)은
    # `get_cached_value!` 라 캐시가 낡았으면 **재계산하면서 `_CACHE_TIMESTAMP_COUNTER` 를 올린다**.
    # 그 카운터는 ξ(재생 상태)로 분류돼 있다(simstate.jl `ReplayState.cache_counter`) — 즉 관측이
    # 재생 상태를 건드릴 수 있다는 뜻이다. 스텝 직후에는 전부 최신이라 0회여야 한다.
    before_cachect = CB._CACHE_TIMESTAMP_COUNTER[]

    s = CB.simstate_of(env)

    @test length(env.cache.closed_set) == before_closed
    @test length(env.cache.active_set) == before_active
    @test FLEET.soc   == before_soc
    @test HZ.usage_s  == before_usage
    @test HZ.eff      == before_eff
    @test HZ.broken   == before_broken
    @test length(CB.BATTERY_DELIVERIES[]) == before_deliv
    @test CB.RESTRICTION_ZONES[] == before_zones
    @test CB.SIM_STEP[] == before_step
    @test CB._CACHE_TIMESTAMP_COUNTER[] == before_cachect
    # 두 번 불러도 같은 해시 (관측이 부작용을 남기지 않는다)
    @test CB.state_hash(s) == h()
    @test CB.state_hash(s) == h()
end

@testset "N-G0 — Fleet 축(soc·usage_s·eff·health·role)" begin
    # soc
    h0 = h(); old = FLEET.soc[RID]
    FLEET.soc[RID] = old - 0.1
    @test h() != h0
    FLEET.soc[RID] = old
    @test h() == h0                        # 복원하면 되돌아온다

    # usage_s (hazard 상태 — λ_r 의 인자)
    h0 = h(); oldu = HZ.usage_s[RID]
    HZ.usage_s[RID] = oldu + 5.0
    @test h() != h0
    HZ.usage_s[RID] = oldu
    @test h() == h0

    # eff (ε_r)
    h0 = h(); olde = HZ.eff[RID]
    HZ.eff[RID] = olde * 1.01
    @test h() != h0
    HZ.eff[RID] = olde
    @test h() == h0

    # health — 주입 레인(FAULTED_ROBOTS)
    h0 = h()
    CB.FAULTED_ROBOTS[][RID] = Float64[0.0, 0.0]
    @test h() != h0
    delete!(CB.FAULTED_ROBOTS[], RID)
    @test h() == h0

    # health — hazard 레인(st.broken). 두 레인이 **둘 다** 보여야 한다.
    h0 = h()
    push!(HZ.broken, RID2)
    @test h() != h0
    delete!(HZ.broken, RID2)
    @test h() == h0

    # role — SPARE_POOLS 가 :spare_parked 를 만든다(state_globals.jl:111 "role_r 이 여기서 유도된다")
    pool = first(sort!(collect(keys(CB.SPARE_POOLS[])); by = string))
    @test !isempty(CB.SPARE_POOLS[][pool])
    h0 = h(); popped = pop!(CB.SPARE_POOLS[][pool])
    @test h() != h0
    push!(CB.SPARE_POOLS[][pool], popped)
    @test h() == h0

    # pose — 로봇 본체의 씬 위치. `Replace` 의 본체 교체·복구 스냅이 움직이는 축이다.
    rn = CB.get_node(env.scene_tree, RID)
    orig_rp = CB.global_transform(rn)
    h0 = h()
    CB.set_desired_global_transform!(rn,
        CB.CoordinateTransformations.Translation(0.5, 0.0, 0.0) ∘ orig_rp)
    @test h() != h0
    CB.set_desired_global_transform!(rn, orig_rp)
    @test h() == h0

    # mode — 활성 노드의 전력 모드. 이 축만은 **격리된 교란이 없다**(active_set 을 흔들면
    # ProgBlock 도 같이 갈린다). 대신 두 가지를 단언한다:
    #   (a) hazard 의 분류기와 정확히 같은 값을 나른다 (계약 (3): 재분류 금지)
    #   (b) 이 상태에서 실제로 정보를 나른다 — 전부 :idle 이면 아무것도 못 가른다
    s = CB.simstate_of(env)
    modes = CB._hz_modes(env)
    for rid in RIDS
        @test s.fleet[CB._int_key(rid)].mode === get(modes, rid, :idle)
    end
    @test any(r -> r.mode !== :idle, values(s.fleet))
end

@testset "N-G0 — Geo 축(zones 기하 · 빌드 poses)" begin
    # zone 기하 — 이름이 아니라 반지름만 바꾼다
    h0 = h()
    CB.RESTRICTION_ZONES[][:ng0probe] = CB.LazySets.Ball2([0.0, 0.0], 1.0)
    h1 = h()
    @test h1 != h0
    CB.RESTRICTION_ZONES[][:ng0probe] = CB.LazySets.Ball2([0.0, 0.0], 2.0)
    @test h() != h1                        # 🔴 이름 같고 반지름만 달라도 갈려야 한다
    CB.RESTRICTION_ZONES[][:ng0probe] = CB.LazySets.Ball2([3.0, 0.0], 2.0)
    @test h() != h1                        # 중심만 달라도 갈려야 한다
    delete!(CB.RESTRICTION_ZONES[], :ng0probe)
    @test h() == h0

    # geo.poses = **빌드 기하**(AssemblyComplete 의 start_config). RelocateBuild 가 강체 Δ 를
    # 거는 바로 그 변환트리 루트다(restage_zone.jl:610-624). 로봇 pose 가 아니다 —
    # 그건 RobotRec.pose 가 따로 나른다.
    s = CB.simstate_of(env)
    @test !isempty(s.geo.poses)
    v = first(sort!([v for v in Graphs.vertices(env.sched)
                     if CB.matches_template(CB.AssemblyComplete, CB.get_node(env.sched, v).node)]))
    tnode = CB.start_config(CB.get_node(env.sched, v).node)
    orig  = CB.global_transform(tnode)
    h0 = h()
    CB.set_desired_global_transform!(tnode,
        CB.CoordinateTransformations.Translation(1.0, 0.0, 0.0) ∘ orig)
    @test h() != h0                        # 빌드를 옮기면 s 가 본다 (= RelocateBuild 가 보인다)
    CB.set_desired_global_transform!(tnode, orig)
    @test h() == h0

    # 🔴 build_delta 는 **출처가 없다**. HEAD 어디에도 누적 build translation 을 들고 있는
    # 전역이 없다(restage_zone.jl:610-624 가 Δ 를 적용만 하고 기록하지 않는다). 그래서 이
    # 필드는 상수이고, 이 게이트로 흔들 방법이 없다 — 그 사실을 단언으로 못박아 둔다.
    # 누군가 출처를 붙이면 이 줄이 빨개져서 **이 주석을 다시 읽게** 된다.
    @test s.geo.build_delta === (0.0, 0.0)
end

@testset "N-G0 — Graph 축(wedge_edges · dissolved_gates)" begin
    h0 = h()
    push!(CB.WEDGE_EDGES[], (7, 9))
    @test h() != h0
    pop!(CB.WEDGE_EDGES[])
    @test h() == h0

    h0 = h()
    push!(CB.DISSOLVED_GATES[], (7, 9))
    @test h() != h0
    delete!(CB.DISSOLVED_GATES[], (7, 9))
    @test h() == h0

    # edges·binding 은 격리된 교란이 없다(스케줄 그래프 수술은 in-process 로 되돌릴 수 없다).
    # 대신 엔진의 원본과 **집합으로** 같은지 직접 단언한다.
    s = CB.simstate_of(env)
    @test s.g.edges == Set{Tuple{Int,Int}}((Graphs.src(e), Graphs.dst(e))
                                            for e in Graphs.edges(env.sched))
    @test !isempty(s.g.edges)
    @test !isempty(s.g.binding)
    for (v, k) in s.g.binding
        rs = CB._responsible_robots(CB.get_node(env.sched, v).node)
        @test k in [CB._int_key(r) for r in rs]
    end
end

@testset "N-G0 — Prog 축(t · closed · active)" begin
    # 시계
    h0 = h()
    CB.set_sim_step!(CB.SIM_STEP[] + 1)
    @test h() != h0
    CB.set_sim_step!(CB.SIM_STEP[] - 1)
    @test h() == h0

    # closed 집합
    victim = maximum(Graphs.vertices(env.sched))
    @test !(victim in env.cache.closed_set)
    h0 = h()
    push!(env.cache.closed_set, victim)
    @test h() != h0
    delete!(env.cache.closed_set, victim)
    @test h() == h0

    # active 의 **값**(= 그 정점이 실제로 시작한 시각)
    av = first(sort!(collect(env.cache.active_set)))
    old_t0 = CB.get_t0(env.sched, av)
    h0 = h()
    CB.set_t0!(env.sched, av, old_t0 + 3)
    @test h() != h0
    CB.set_t0!(env.sched, av, old_t0)
    @test h() == h0
end

@testset "N-G0 — Courier 축(8 필드 전부)" begin
    # 배송 하나를 손으로 넣고, **그 상태를 기준선으로** 필드를 하나씩 흔든다. 기준선에 배송이
    # 이미 들어 있으므로 courier 로봇의 role(:courier) 은 내내 고정이고, 갈리는 것은 그
    # 레코드의 해당 필드 하나뿐이다.
    cid, tid = RIDS[3], RIDS[4]
    d = CB.BatteryDelivery(tid, cid, :north, Float64[1.0, 2.0], :outbound,
                           Float64[3.0, 4.0], 5, -1)
    empty_before = isempty(CB.BATTERY_DELIVERIES[])
    @test empty_before
    h_none = h()
    CB.BATTERY_DELIVERIES[][cid] = d
    hb = h()
    @test hb != h_none                      # 배송이 하나 생긴 것 자체가 보인다

    probe(f!, undo!) = (f!(); r = h(); undo!(); (r, h()))

    for (name, f!, undo!) in (
        ("target",   () -> (d.target = RIDS[5]),          () -> (d.target = tid)),
        ("courier",  () -> (d.courier = RIDS[5]),         () -> (d.courier = cid)),
        ("depot",    () -> (d.depot = :south),            () -> (d.depot = :north)),
        ("home",     () -> (d.home = Float64[9.0, 2.0]),  () -> (d.home = Float64[1.0, 2.0])),
        ("goal",     () -> (d.goal = Float64[3.0, 9.0]),  () -> (d.goal = Float64[3.0, 4.0])),
        ("phase",    () -> (d.phase = :returning),        () -> (d.phase = :outbound)),
        ("step_out", () -> (d.step_out = 6),              () -> (d.step_out = 5)),
        ("step_swap",() -> (d.step_swap = 7),             () -> (d.step_swap = -1)),
    )
        moved, restored = probe(f!, undo!)
        @test (name, moved != hb) == (name, true)
        @test (name, restored == hb) == (name, true)
    end

    # C-3: `-1` 센티넬("아직 안 바뀜")은 절대시각 0.0 으로 무너지면 안 된다.
    s = CB.simstate_of(env)
    rec = only(s.courier)
    @test rec.t_swap == -1.0
    @test rec.t_out ≈ Float64(env.dt) * 5

    delete!(CB.BATTERY_DELIVERIES[], cid)
    @test h() == h_none
end

@testset "진행 상태가 실제 캐시를 반영한다" begin
    s = CB.simstate_of(env)
    @test s.prog.closed == Set(env.cache.closed_set)
    @test Set(keys(s.prog.active)) == Set(env.cache.active_set)
    @test s.prog.t ≈ CB.sim_time(env.dt)
    @test length(s.fleet) == length(FLEET.soc)
    # payload 도 격리된 교란이 없다(로봇 재부모화 = 씬트리 수술). 엔진의 부모 관계와 직접 대조.
    for rid in RIDS
        p = CB.get_parent(env.scene_tree, rid)
        expect = Graphs.has_vertex(env.scene_tree, p) ?
                 CB._int_key(CB.node_id(CB.get_node(env.scene_tree, p))) : nothing
        @test s.fleet[CB._int_key(rid)].payload == expect
    end
end
