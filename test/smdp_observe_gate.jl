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

# 🔴 **왜 120 스텝인가 (리뷰 라운드 1 이 잡은 결함)**. 초판은 40 스텝이었는데, 그 지점에서는
# `mode` 가 14/14 로봇 전부 `:transit` 한 값이고 `payload` 는 14/14 전부 `nothing` 이다. 그러면
# 두 축의 검사가 **반증 불가능**해진다 — `mode = :transit` 상수를 돌려주는 구현도, `payload` 로
# 무조건 `nothing` 을 돌려주는 구현도 초록으로 통과한다. 실측(probe, 5스텝 간격 260스텝):
#
#     step   distinct modes            non-nothing payload
#     1-79   1  [:transit]             0
#     80-90  1  [:transit]             0
#     95     3  [:transit,:manip,:carry]  6
#     100-170 2 [:transit,:carry]      6      ← 안정 구간
#     175-260 2 [:transit,:carry]      2..4
#
# 120 은 그 안정 구간 한복판이다(t=3.0s · closed 63 · active 10 · mode 2종 · payload 6/14).
# 아래 두 testset 이 그 도메인이 실제로 비퇴화인지를 **명시적으로 단언**한다 — 나중에 픽스처가
# 바뀌어 도메인이 다시 납작해지면 그 단언이 먼저 빨개진다.
#
# 명목 루프의 최소 형태(demo_utils.jl:157-158)를 그대로 돌린다.
#
# `FIRST_ACTIVE_T` = 이 시험이 **직접 관측한** "그 정점이 처음 활성으로 보인 절대 sim 초".
# 엔진에는 이런 기록이 없다 — 그것이 아래 `prog.active` 단언의 요점이다.
const FIRST_ACTIVE_T = Dict{Int,Float64}()
for k in 1:120
    CB.step_environment!(env)
    CB.update_planning_cache!(env, 0.0)
    CB.set_sim_step!(k)
    let t = CB.sim_time(env.dt)
        for v in env.cache.active_set
            get!(FIRST_ACTIVE_T, v, t)
        end
    end
end

h() = CB.state_hash(CB.simstate_of(env))
const FLEET = CB.BATTERY_FLEET[]
const HZ    = CB.HAZARD_STATE[]
const RIDS  = sort!(collect(keys(FLEET.soc)); by = string)
const RID   = first(RIDS)
const RID2  = RIDS[2]

@testset "_int_key 는 예상 못 한 id 모양에서 죽는다 (hash 폴백 없음)" begin
    @test CB._int_key(CB.RobotID(7)) === 7
    @test CB._int_key(CB.ObjectID(7)) === 7            # 타입 태그는 지워진다(문서화된 성질)
    @test_throws ErrorException CB._int_key(7)          # `.id` 가 없다
    @test_throws ErrorException CB._int_key("R7")       # `.id` 가 없다
    @test_throws ErrorException CB._int_key((id = 7.0,))    # Float 은 정수 키가 아니다
    # 🔴 `Bool <: Integer` 다. 이 한 줄이 없으면 `.id === true` 가 `1` 로 통과해
    # `RobotID(1)` 과 조용히 충돌한다 — 이 함수가 막으려는 사고 그 자체다(리뷰 라운드 2).
    @test_throws ErrorException CB._int_key((id = true,))
end

@testset "simstate_of 는 읽기 전용이다" begin
    # 🔴 리뷰 라운드 1: 초판은 `BATTERY_DELIVERIES`·`RESTRICTION_ZONES` 를 **빈 채로** 대조했다
    # (`0 == 0`, `Dict() == Dict()`) — 어떤 구현도 통과하는 공허한 단언이다. 두 레지스트리를
    # 먼저 채워 도메인을 비우지 않는다. (여기서 넣은 둘은 이 testset 끝에서 다시 뺀다.)
    CB.RESTRICTION_ZONES[][:ng0ro] = CB.LazySets.Ball2([1.0, 2.0], 0.75)
    CB.BATTERY_DELIVERIES[][RIDS[3]] =
        CB.BatteryDelivery(RIDS[4], RIDS[3], :north, Float64[1.0, 2.0], :outbound,
                           Float64[3.0, 4.0], 5, -1)

    before_closed  = length(env.cache.closed_set)
    before_active  = length(env.cache.active_set)
    before_soc     = copy(FLEET.soc)
    before_usage   = copy(HZ.usage_s)
    before_eff     = copy(HZ.eff)          # 🔴 _hz_ensure! 를 부르면 여기가 늘어난다(난수도 태운다)
    before_broken  = copy(HZ.broken)
    # 배송은 가변 struct 라 `copy(Dict)` 는 **같은 객체**를 가리킨다 — 내용이 바뀌어도 등호가
    # 참이다. 필드를 렌더해서 뜬다.
    _deliv_snap() = Dict(k => (d.target, d.courier, d.depot, copy(d.home), d.phase,
                               copy(d.goal), d.step_out, d.step_swap)
                         for (k, d) in CB.BATTERY_DELIVERIES[])
    before_deliv   = _deliv_snap()
    before_zones   = copy(CB.RESTRICTION_ZONES[])
    before_step    = CB.SIM_STEP[]
    # 🔴 가장 미묘한 자리: `global_transform`(hierarchical_geom_essentials.jl:347)은
    # `get_cached_value!` 라 캐시가 낡았으면 **재계산하면서 `_CACHE_TIMESTAMP_COUNTER` 를 올린다**.
    # 그 카운터는 ξ(재생 상태)로 분류돼 있다(simstate.jl `ReplayState.cache_counter`).
    # ⚠️ **일반적으로 0회라는 뜻이 아니다** — 캐시가 낡아 있으면 관측이 실제로 올린다(이 파일의
    # 뒤쪽 testset 들이 `set_desired_global_transform!` 로 캐시를 무효화한 직후 `h()` 를 부르는
    # 것이 바로 그 경우다). 여기서 재는 것은 **이 관측 지점**(스텝 직후, 전부 최신)의 실측값이다.
    # 컨트롤러 판정: 이 부작용은 유지한다(ξ 이고, 갱신을 건너뛰면 `s` 에 **낡은 pose** 가 들어간다).
    before_cachect = CB._CACHE_TIMESTAMP_COUNTER[]

    s = CB.simstate_of(env)

    @test length(env.cache.closed_set) == before_closed
    @test length(env.cache.active_set) == before_active
    @test FLEET.soc   == before_soc
    @test HZ.usage_s  == before_usage
    @test HZ.eff      == before_eff
    @test HZ.broken   == before_broken
    @test !isempty(before_deliv) && !isempty(before_zones)   # 도메인이 비어 있지 않다
    @test _deliv_snap() == before_deliv
    @test CB.RESTRICTION_ZONES[] == before_zones
    @test CB.SIM_STEP[] == before_step
    @test CB._CACHE_TIMESTAMP_COUNTER[] == before_cachect
    # 두 번 불러도 같은 해시 (관측이 부작용을 남기지 않는다).
    # 🔴 예전에는 이 줄이 **바이트 동일하게 두 번** 있었다 — 같은 단언을 두 번 쓰는 것은
    # "두 번 관측했다" 를 증명하지 않는다(둘 다 같은 `s` 를 같은 `h()` 와 댄다). 한 줄로 줄이고,
    # 대신 **관측을 세 번 더 굴린 뒤에도** 같은지를 본다 — 그것이 원래 재려던 성질이다.
    @test CB.state_hash(s) == h()
    @test all(h() == CB.state_hash(s) for _ in 1:3)

    # 🔴 **`_hz_ensure!` 를 부르지 않는다** — 반증 가능한 형태로.
    # 리뷰 라운드 1 이 잡은 결함: `enable_hazard!`(hazard.jl:250-255)가 `simstate_of` 가 훑는
    # **바로 그 키 집합**을 미리 등록해 두므로, 위의 `HZ.eff == before_eff` 는 설령 관측이
    # `_hz_ensure!` 를 부르더라도 `haskey(st.eff,id) && return`(hazard.jl:292) 단락에 걸려
    # 그대로 통과한다 = 아무것도 증명하지 못한다.
    # 그래서 RID 의 등록을 **일부러 지우고** 관측한다. 관측이 `_hz_ensure!` 를 부르면 그 자리가
    # 다시 채워지고(그리고 그 로봇 스트림에서 난수 3개 — `_lognorm1` 의 randn 1 + `_exp1` 2 —
    # 를 태워 CRN 을 민다) 아래 두 단언이 즉시 빨개진다.
    saved_eff, saved_usage = HZ.eff[RID], HZ.usage_s[RID]
    delete!(HZ.eff, RID); delete!(HZ.usage_s, RID)
    s_unreg = CB.simstate_of(env)
    @test !haskey(HZ.eff, RID)
    @test !haskey(HZ.usage_s, RID)
    # 그리고 미등록 로봇이 문서화된 값으로 읽히는지 — observe.jl 의 "지어내지 않는다" 경로.
    @test s_unreg.fleet[CB._int_key(RID)].usage_s == 0.0
    @test s_unreg.fleet[CB._int_key(RID)].eff == 1.0
    HZ.eff[RID] = saved_eff; HZ.usage_s[RID] = saved_usage

    delete!(CB.RESTRICTION_ZONES[], :ng0ro)
    delete!(CB.BATTERY_DELIVERIES[], RIDS[3])
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
    # ProgBlock 도 같이 갈린다). 그래서 값 동등 검사로 대체하는데, 그 검사는 `observe.jl:79` 와
    # **같은 호출**이라 `f(x) == f(x)` 다 — 그것만으로는 `_hz_modes` 가 비결정적일 때만 빨개진다.
    # 🔴 리뷰 라운드 1: 초판의 구제책 `any(!== :idle)` 은 step 40 에서 mode 가 14/14 `:transit`
    # **한 값**이라 `mode = :transit` 상수 구현도 통과시켰다. 이제 픽스처를 120 스텝으로 옮기고
    # **서로 다른 값이 2종 이상**임을 단언한다 — 상수 구현은 여기서 죽는다.
    s = CB.simstate_of(env)
    modes = CB._hz_modes(env)
    for rid in RIDS
        @test s.fleet[CB._int_key(rid)].mode === get(modes, rid, :idle)
    end
    mode_domain = Set(r.mode for r in values(s.fleet))
    @test length(mode_domain) >= 2        # 실측 step 120: {:transit, :carry}
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
    # 🔴 리뷰 라운드 1: 초판은 `k in [...]`(멤버십)이었다. 그러면 P2 의 결정성 수정
    # (`observe.jl:64` 의 `first(sort(rs; by = string))`)을 **아무것도 검증하지 않는다** —
    # `rs[1]` 을 그대로 쓰는 비결정적 구현도 멤버십은 만족한다. 실측: 담당 로봇이 2대 이상인
    # 정점이 99개이고 그중 12개에서 `first(sort(rs; by=string)) != rs[1]` 이다. 등호로 바꾼다.
    nmulti = 0
    for (v, k) in s.g.binding
        rs = CB._responsible_robots(CB.get_node(env.sched, v).node)
        length(rs) > 1 && (nmulti += 1)
        @test k == CB._int_key(first(sort(rs; by = string)))
    end
    @test nmulti > 0        # 정렬이 실제로 갈림길인 정점이 존재한다(= 위 등호가 공허하지 않다)
end

@testset "계약 (3) — role 분기 목록이 _responsible_robots 와 어긋나면 여기서 죽는다 (I4)" begin
    # `observe.jl` 계약 (3) 은 `mode` 에만 걸린다 — `role` 은 `_hz_modes` 의 분류기를 못 쓴다
    # (`_node_mode` 는 전력 모드라 경계가 다르다: RobotStart·LiftIntoPlace). 그 대신
    # `_sched_roles` 의 태그 분기 목록이 `_responsible_robots` 의 분기 목록과 **같은 모양**임을
    # 여기서 기계로 지킨다. 한쪽에 노드 타입이 추가되고 다른 쪽에 안 되면 빨개진다.
    #
    # 🔴 active_set 이 아니라 **스케줄 전체 정점**을 훑는다. step 120 의 active_set 은
    # `RobotGo`·`TransportUnitGo` 두 종뿐이라(실측) 거기서만 재면 항진명제다.
    tagged_only, resp_only, ntypes = 0, 0, Set{Symbol}()
    for v in Graphs.vertices(env.sched)
        n = CB.get_node(env.sched, v).node
        push!(ntypes, typeof(n).name.name)
        tagged = (n isa CB.RobotGo || n isa CB.RobotStart || n isa CB.TransportUnitGo ||
                  n isa CB.FormTransportUnit || n isa CB.DepositCargo)
        resp = !isempty(CB._responsible_robots(n))
        tagged && !resp && (tagged_only += 1)
        !tagged && resp && (resp_only += 1)
    end
    # 도메인이 비퇴화인지 먼저 — 다섯 분기 타입이 전부 스케줄에 실제로 있어야 위 루프가 뜻이 있다.
    for t in (:RobotGo, :RobotStart, :TransportUnitGo, :FormTransportUnit, :DepositCargo)
        @test (t, t in ntypes) == (t, true)
    end
    @test tagged_only == 0      # _sched_roles 가 태그를 주는데 담당 로봇이 없다
    @test resp_only   == 0      # 담당 로봇은 있는데 _sched_roles 가 태그를 안 준다

    # 🔴 **알려진 드리프트를 실측값으로 못 박는다** (리뷰 I4 가 지목한 자리, 이 파일이 만든 것이
    # 아니다): `_node_mode` 는 `LiftIntoPlace → MANIPULATE` 로 보내는데 `_responsible_robots`
    # 에는 그 분기가 없어 `Any[]` 다. 그래서 들어올리는 중인 로봇은 `mode` 도 `role` 도 `:idle`
    # 로 읽힌다. **누가 `_responsible_robots` 에 `LiftIntoPlace` 를 추가하면 이 단언이 빨개진다**
    # — 그때 `_sched_roles` 의 태그 분기도 같이 손봐야 한다(안 그러면 role 만 조용히 뒤처진다).
    lifts = [CB.get_node(env.sched, v).node for v in Graphs.vertices(env.sched)
             if CB.get_node(env.sched, v).node isa CB.LiftIntoPlace]
    @test !isempty(lifts)                                     # 실측 colored_8x8: 33개
    @test all(n -> CB._node_mode(n) == CB.MANIPULATE, lifts)  # 모드는 준다
    @test all(n -> isempty(CB._responsible_robots(n)), lifts) # 그런데 받을 로봇이 없다
end

@testset "🔴 prog.active 는 **계획된** 시작이지 실제 시작이 아니다 (알려진 결함, 못 박아 둠)" begin
    # simstate.jl:105 와 spec §3-2 는 이 필드를 "그 정점이 **실제로 시작한** 시각" 이라고 적었다.
    # **아니다.** `get_t0` 는 MILP/구조적 계획값이고, 그것을 쓰는 유일한 경로
    # `process_schedule!`(route_planning.jl:506)는 `update_schedule_times!` 를 `Δt > 0` 일 때만
    # 태우는데 레포의 **모든 호출자가 t = 0.0 을 넘긴다**(demo_utils.jl:80·158,
    # route_planning.jl:273, tools/monitor/run_demo.jl:483·795·815, render_demo.jl:597).
    # 실행 중 실제 시작을 기록하는 곳은 `MONITOR_NODE_T`(monitor.jl:220) 하나뿐인데 그것은
    # `:log` 로 분류돼 있고(state_globals.jl:318) 모니터가 꺼져 있으면 아예 안 채워진다 —
    # `s` 의 출처로 쓸 수 없다. 그래서 **지어내지 않고** `get_t0` 를 그대로 나르고, 그 사실을
    # 여기에 단언으로 못 박는다. 누가 진짜 출처를 배선하면 아래 둘이 빨개진다.
    # (Task 8 의 `T_plan_next` 가 이것 위에 서면 구조적으로 틀린다 — 이 태스크 범위 밖.)
    s = CB.simstate_of(env)

    # (1) 이 필드가 지금 무엇을 나르는가 — 계획값.
    @test s.prog.active ==
          Dict(v => Float64(CB.get_t0(env.sched, v)) for v in env.cache.active_set)

    # (2) 그것이 실제 시작이 **아니라는** 직접 증거: 아직 활성인(=안 끝난) 정점이 자기
    #     계획 소요시간 전체보다 오래 "경과" 했다고 말한다. 실제 시작이면 불가능하다.
    #     실측 step 120: 10개 활성 중 8개가 `t0 = 0.0`·`duration = 0.0` 인데 경과 3.0초.
    impossible = [v for v in keys(s.prog.active)
                  if s.prog.t - s.prog.active[v] > Float64(CB.get_duration(env.sched, v))]
    @test !isempty(impossible)

    # (3) 이 시험이 **직접 관측한** 첫 활성 시각과 하나도 안 맞는다. 진짜 출처가 배선되면
    #     둘은 같은 스텝 경계에서 찍히므로 일치하게 되고, 이 단언이 빨개진다.
    @test count(v -> s.prog.active[v] == FIRST_ACTIVE_T[v], keys(s.prog.active)) == 0
end

@testset "N-G0 — Prog 축(t · closed · active)" begin
    # 시계
    h0 = h()
    CB.set_sim_step!(CB.SIM_STEP[] + 1)
    @test h() != h0
    CB.set_sim_step!(CB.SIM_STEP[] - 1)
    @test h() == h0

    # closed 집합. 🔴 리뷰 라운드 1 이후 픽스처가 120 스텝으로 깊어져 `maximum(vertices)` 는
    # **이미 닫혀 있다** — 그러면 push! 가 무동작이라 대조가 성립하지 않는다. 아직 닫히지도
    # 열리지도 않은 정점을 고른다(비면 이 단언이 먼저 죽는다 = 조용히 넘어가지 않는다).
    future = sort!(collect(setdiff(Set(Graphs.vertices(env.sched)),
                                   env.cache.closed_set, env.cache.active_set)))
    @test !isempty(future)
    victim = first(future)
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
    # `s.prog.t ≈ CB.sim_time(env.dt)` 는 삭제했다 — `observe.jl` 이 그 필드를 **바로 그 호출로**
    # 채우므로 `f(x) == f(x)` 라 절대 못 죽는다(리뷰 라운드 2). 이 축의 진짜 대조는
    # "N-G0 — Prog 축" 의 `SIM_STEP` 교란이고, 아래 한 줄이 값 자체를 계산된 기대치로 잡는다.
    @test s.prog.t ≈ Float64(env.dt) * 120        # 픽스처가 정확히 120 스텝을 굴렸다
    @test length(s.fleet) == length(FLEET.soc)
    # payload 도 격리된 교란이 없다(로봇 재부모화 = 씬트리 수술). 엔진의 부모 관계와 직접 대조.
    # 🔴 리뷰 라운드 1: step 40 에서는 14/14 가 `nothing` 이라 **무조건 `nothing` 을 돌려주는
    # 구현이 14/14 통과**했다. 120 스텝 픽스처에서는 6/14 가 실제로 운반유닛에 포획돼 있다 —
    # 그 도메인이 비퇴화인지를 먼저 단언하고, 그 다음에 값을 대조한다.
    @test count(r -> r.payload !== nothing, values(s.fleet)) >= 1   # 실측 step 120: 6/14
    for rid in RIDS
        p = CB.get_parent(env.scene_tree, rid)
        expect = Graphs.has_vertex(env.scene_tree, p) ?
                 CB._int_key(CB.node_id(CB.get_node(env.scene_tree, p))) : nothing
        @test s.fleet[CB._int_key(rid)].payload == expect
    end
end
