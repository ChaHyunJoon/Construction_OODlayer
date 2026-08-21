# =============================================================================
# test/smdp_observe_gate.jl  —  게이트 N-G0′ (독립 실행. runtests.jl 에 넣지 않는다)
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
# 🔴 이 파일은 **직전 세대의 같은 게이트**(2026-08-20, 19→26필드 시절)의 재작성이다. Task R1
# (커밋 b578cd3c)이 `SimState` 를 7필드로 더 줄이면서 `role`·`payload`·`courier`·`prog.active`·
# `prog.t`·`build_delta`·`wedge_edges`·`dissolved_gates`·`eff` 가 통째로 빠졌다 — 그 축을 재던
# testset(또는 testset 의 절반)들은 **referent 가 없어져** 삭제했다(정확히 어떤 것이 왜 삭제
# 됐는지는 task-R2-report.md 의 per-testset 표를 볼 것). 반대로 `_int_key` 음성 대조, `edges`·
# `binding`(Graph 축), `poses`(Geo 축), `closed`(Prog 축)처럼 **필드 자체가 여전히 실재하는**
# 축은 옮겼다 — 커버리지는 줄지 않는다, 좁아진 것은 필드 개수뿐이다.
#
# 🔴 **씬 생성은 SCENE-INCANTATION.md 가 정본이다** — 계획서 브리프의 스니펫은 두 겹으로
# 틀렸다(`return_env_before_sim` 없이는 판이 끝까지 굴러 퇴화한 세계를 잰다 + 반환값이
# `PlannerEnv` 가 아니라 `Tuple{PlannerEnv,Dict}` 가 된다). 아래는 그 정본을 그대로 베낀 것.
# =============================================================================
using ConstructionBots, Test
import Random
import Graphs
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

# colored_8x8.ldr = 33부품 x 1층, 실측 ~4초. 가장 싼 실제 씬. 확장자는 `.ldr` 이다(`.mpd` 아님).
env = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "ng0r2",
                         num_robots = 6, assignment_mode = :greedy,
                         n_spare_per_pool = 2,
                         open_animation_at_end = false, save_animation = false,
                         write_results = false, return_env_before_sim = true,
                         rng = Random.MersenneTwister(1))
CB.enable_battery!(env)
CB.enable_hazard!(env; seed = 11)

# 120 스텝 — SCENE-INCANTATION.md §2: step ≤ 90 은 전 로봇이 `:transit` 인 퇴화 구간이라
# 반증 불가능한 게이트가 된다. 이 태스크의 축(fleet 멤버십·soc·usage_s·zone 기하)은 사실
# step 수와 무관하게 갈리지만(모드/부하 축이 아니다), 정본을 그대로 따른다.
for k in 1:120
    CB.step_environment!(env)
    CB.update_planning_cache!(env, 0.0)
    CB.set_sim_step!(k)
end

h() = CB.state_hash(CB.simstate_of(env))

@testset "_int_key 는 예상 못 한 id 모양에서 죽는다 (hash 폴백 없음)" begin
    # 🔴 직전 세대 게이트에서 그대로 옮겨 왔다(브리프 Interfaces 절이 `_int_key` RETAINED 라고
    # 명시). `Bool <: Integer` 가드 줄은 리뷰 라운드 2 가 잡은 실제 충돌 경로다 — 지우면
    # `.id === true` 인 id 가 `1` 로 통과해 `RobotID(1)` 과 조용히 충돌한다.
    @test CB._int_key(CB.RobotID(7)) === 7
    @test CB._int_key(CB.ObjectID(7)) === 7            # 타입 태그는 지워진다(문서화된 성질)
    @test_throws ErrorException CB._int_key(7)          # `.id` 가 없다
    @test_throws ErrorException CB._int_key("R7")       # `.id` 가 없다
    @test_throws ErrorException CB._int_key((id = 7.0,))    # Float 은 정수 키가 아니다
    @test_throws ErrorException CB._int_key((id = true,))
end

@testset "simstate_of 는 읽기 전용이다" begin
    before = (length(env.cache.closed_set), length(env.cache.active_set),
              copy(CB.BATTERY_FLEET[].soc))
    s = CB.simstate_of(env)
    @test length(env.cache.closed_set) == before[1]
    @test length(env.cache.active_set) == before[2]
    @test CB.BATTERY_FLEET[].soc == before[3]
    @test CB.state_hash(s) == CB.state_hash(CB.simstate_of(env))
end

@testset "N-G0′ 필드 민감도 — env 를 흔들면 해시가 갈린다" begin
    h0  = h()
    rid = first(sort!(collect(keys(CB.BATTERY_FLEET[].soc)); by = string))

    old = CB.BATTERY_FLEET[].soc[rid]
    CB.BATTERY_FLEET[].soc[rid] = old - 0.1
    @test h() != h0
    CB.BATTERY_FLEET[].soc[rid] = old
    @test h() == h0        # 복원하면 되돌아온다

    st   = CB.HAZARD_STATE[]
    oldu = st.usage_s[rid]; st.usage_s[rid] = oldu + 5.0
    @test h() != h0
    st.usage_s[rid] = oldu
    @test h() == h0

    # zone 기하 — 이름이 아니라 반지름만 바꾼다
    CB.RESTRICTION_ZONES[][:ng0probe] = CB.LazySets.Ball2([0.0, 0.0], 1.0)
    h1 = h()
    @test h1 != h0
    CB.RESTRICTION_ZONES[][:ng0probe] = CB.LazySets.Ball2([0.0, 0.0], 2.0)
    @test h() != h1        # 🔴 반지름만 달라도 갈려야 한다
    delete!(CB.RESTRICTION_ZONES[], :ng0probe)
    @test h() == h0
end

@testset "🔴 멤버십이 _hz_excluded 와 정확히 일치한다 (spec §2-4)" begin
    s  = CB.simstate_of(env)
    ex = CB._hz_excluded()
    all_ids = collect(keys(CB.BATTERY_FLEET[].soc))
    expect  = Set(CB._int_key(r) for r in all_ids if !(r in ex))
    @test Set(keys(s.fleet)) == expect
    # 음성 대조: 하나를 제외 집합에 넣으면 fleet 에서 빠져야 한다
    victim = first(sort!(collect(expect)))
    vid    = first(r for r in all_ids if CB._int_key(r) == victim)
    push!(CB.CHECKED_OUT_SPARES[], vid)
    @test !(victim in keys(CB.simstate_of(env).fleet))
    delete!(CB.CHECKED_OUT_SPARES[], vid)
    @test victim in keys(CB.simstate_of(env).fleet)
end

@testset "🔴 시계·배송·역할이 s 에 없다 (음성 대조)" begin
    s0 = CB.simstate_of(env)
    CB.set_sim_step!(2)
    @test CB.state_hash(CB.simstate_of(env)) == CB.state_hash(s0)   # t 가 없다
    CB.set_sim_step!(1)
    @test !hasproperty(s0.prog, :t)
    @test !hasproperty(s0.prog, :active)
    @test !hasproperty(s0, :courier)
    @test !hasproperty(first(values(s0.fleet)), :role)
    @test !hasproperty(first(values(s0.fleet)), :mode)
end

@testset "진행 상태가 실제 캐시를 반영한다" begin
    s = CB.simstate_of(env)
    @test s.prog.closed == Set(env.cache.closed_set)
end

@testset "🔴 g.edges·g.binding 이 엔진 원본과 일치한다 (구세대 Graph 축에서 이설)" begin
    # 구세대(HEAD:test/smdp_observe_gate.jl "N-G0 — Graph 축")는 이 testset 에 `wedge_edges`·
    # `dissolved_gates` 대조도 같이 있었다 — Task R1 이 `GraphBlock` 에서 그 두 필드를 뺐으므로
    # (`edges`·`binding` 둘뿐, simstate.jl:76-79) 그 절반은 referent 가 없어 버렸다. 나머지 절반
    # (`edges`·`binding`)은 여전히 실재하는 필드라 옮긴다 — 특히 binding 의 결정성 수정(P2:
    # `first(sort(rs; by=string))`)이 실제로 갈림길인 정점에서 검증되는지(`nmulti > 0`)는
    # 멤버십(`k in [...]`)만으로는 못 잡는 회귀라 등호로 유지한다.
    s = CB.simstate_of(env)
    @test s.g.edges == Set{Tuple{Int,Int}}((Graphs.src(e), Graphs.dst(e))
                                            for e in Graphs.edges(env.sched))
    @test !isempty(s.g.edges)
    @test !isempty(s.g.binding)
    nmulti = 0
    for (v, k) in s.g.binding
        rs = CB._responsible_robots(CB.get_node(env.sched, v).node)
        length(rs) > 1 && (nmulti += 1)
        @test k == CB._int_key(first(sort(rs; by = string)))
    end
    @test nmulti > 0        # 정렬이 실제로 갈림길인 정점이 존재한다(= 위 등호가 공허하지 않다)
end

@testset "🔴 prog.closed 이 실제로 흔들린다 (구세대 Prog 축에서 이설)" begin
    # 구세대 "N-G0 — Prog 축(t·closed·active)" 은 t(시계)·active(계획 시작시각)·closed 셋을 같이
    # 흔들었다. Task R1 이 `ProgBlock` 에서 `t`·`active` 를 뺐으므로(`closed` 하나뿐,
    # simstate.jl:108-116) 그 둘은 referent 가 없어 버렸다(위 "🔴 시계·배송·역할이 s 에 없다"
    # testset 이 그 삭제 자체를 음성 대조로 못박는다). `closed` 는 여전히 실재하는 필드라 그
    # 부분만 옮긴다.
    future = sort!(collect(setdiff(Set(Graphs.vertices(env.sched)),
                                   env.cache.closed_set, env.cache.active_set)))
    @test !isempty(future)      # 아직 닫히지도 활성이지도 않은 정점이 있어야 대조가 성립한다
    victim = first(future)
    @test !(victim in env.cache.closed_set)
    h0 = h()
    push!(env.cache.closed_set, victim)
    @test h() != h0
    delete!(env.cache.closed_set, victim)
    @test h() == h0
end

@testset "🔴 geo.poses 가 RelocateBuild 의 실제 집행부를 관측하는가 (독립 검증자 지적사항, 실측)" begin
    # `_apply_uniform_translation!`(restage_zone.jl:610-624, RelocateBuild 의 실제 집행부)는
    # `AssemblyComplete.start_config` 를 **무조건** 옮기고, 이어서 `_resync_scene_drift!`
    # (restage_zone.jl:157-176)가 씬트리 쪽을 스냅한다 — 단 **free(미포획) 노드에 한해, 드리프트가
    # `tol`(기본 `default_robot_radius()`)보다 클 때만.** `simstate_of` 의 `geo.poses` 는 씬트리
    # `AssemblyNode` 를 읽으므로(`get_nodes(env.scene_tree)` + `matches_template(AssemblyNode,·)`),
    # `tol` 미만의 이동은 씬트리에 전혀 안 남을 위험이 있다 — 이 축이 `RelocateBuild` 가 `s` 에
    # 남기는 유일한 흔적이라 못 박혔으므로(simstate.jl `GeoBlock` docstring), 조용히 안 보이면
    # `RelocateBuild` 와 `NOOP` 이 그 결정 직후엔 구분 불가능해진다(SwapBattery 트립와이어와 같은
    # 종류). 여기서 **실측**한다 — 작은 Δ 는 tol 미만, 큰 Δ 는 tol 초과(배선 자체가 살아있다는
    # 대조군)로 각각 적용·복원한다. `_apply_uniform_translation!` 은 **누적형**이라 역방향 Δ 로
    # 정확히 되돌아온다(docstring: "Translations COMPOSE").
    r = CB.default_robot_radius()
    s0 = CB.simstate_of(env)
    @test !isempty(s0.geo.poses)
    h0 = CB.state_hash(s0)

    small_Δ = [r * 0.2, 0.0]     # tol 의 20% — 확실히 tol 미만
    CB._apply_uniform_translation!(env, small_Δ)
    h_small = CB.state_hash(CB.simstate_of(env))
    CB._apply_uniform_translation!(env, -small_Δ)     # 누적형이므로 역Δ 로 복원
    h_small_restored = CB.state_hash(CB.simstate_of(env))

    big_Δ = [r * 3.0, 0.0]       # tol 의 3배 — 확실히 tol 초과
    CB._apply_uniform_translation!(env, big_Δ)
    h_big = CB.state_hash(CB.simstate_of(env))
    CB._apply_uniform_translation!(env, -big_Δ)
    h_big_restored = CB.state_hash(CB.simstate_of(env))

    @test h_small_restored == h0
    @test h_big_restored == h0
    @test h_big != h0             # 대조군: 큰 이동은 반드시 s 에 보인다 — 배선 자체는 죽어있지 않다

    # 본검사 — 실측값을 그대로 단언으로 못박는다 (아래 참조: RED 로 실측한 뒤 결정됨)
    @test h_small != h0
end
