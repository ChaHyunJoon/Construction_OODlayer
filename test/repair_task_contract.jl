# =============================================================================
# test/repair_task_contract.jl — T5 원본 작업 계약 게이트 (단독 실행, runtests.jl 미포함 — 브리프 요구 없음).
#
#   julia +lts --project=. test/repair_task_contract.jl
#
# 실제 씬(colored_8x8, 로봇 6 + 스페어 8)을 짓고 **끝까지 굴린다**(≈1500 스텝, 10 s). 각 음성 사례는 실제 세계에
# 심은 위반이다. 계약은 t0(시뮬 직전) 세계에서 유도하고 JSON 으로 왕복한 값만 판정에 쓴다 — 판정 함수는 파싱된
# Dict 만 본다. [8] 은 ConstructionBots 를 **싣지 않은** 자식 프로세스에서 같은 판정을 다시 돌린다.
# =============================================================================
using ConstructionBots, Test, Random, JSON3
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
include(joinpath(@__DIR__, "..", "src", "verification", "task_contract.jl"))
include(joinpath(@__DIR__, "..", "src", "verification", "episode_checkpoint.jl"))
const TC = TaskContract
const E = EpisodeCheckpointIO
fields(env) = (w = E.world_lines(env; modules = [CB]); E.field_digests(w.lines, w.fields))

mkenv() = (e = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "t5contract",
        num_robots = 6, assignment_mode = :greedy, n_spare_per_pool = 2,
        open_animation_at_end = false, save_animation = false, write_results = false,
        return_env_before_sim = true, rng = Random.MersenneTwister(1)); CB.enable_battery!(e); CB.set_sim_step!(0); e)
function runall!(env; kmax = 20_000)
    k = CB.SIM_STEP[]
    while !CB.project_complete(env) && k < kmax
        k += 1
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0); CB.set_sim_step!(k)
    end
    return k
end
rt(x) = JSON3.read(JSON3.write(x), Dict{String,Any})
state(env) = rt(TC.task_state(env, CB))
contract(env) = rt(TC.derive_task_contract(env, CB; checkpoint_id = "t0"))
ev(C, env; terminal = false) = TC.evaluate_task_contract(C, state(env); terminal)
nodes_of(env, T) = [n for n in CB.get_nodes(env.sched) if CB.matches_template(T, n)]
vtx(env, n) = CB.get_vtx(env.sched, CB.node_id(n))
has(vs, prefix) = any(v -> startswith(v, prefix), vs)

const OUT = mktempdir()

@testset "T5 task contract" begin
    @testset "[1] 유도: 필수 작업·의미 선행·운반 사슬 — 세계를 안 바꾼다" begin
        env = mkenv()
        f0 = fields(env)
        d0 = TC.digest(TC.task_state(env, CB))
        C = contract(env)
        @test TC.digest(TC.task_state(env, CB)) == d0
        # 부모가 t0 에서 유도해도 세계(변환 캐시·논리 시계 포함)가 한 필드도 안 바뀐다 — T4 부모 verify 가 이것을 요구한다
        @test [k for k in keys(f0) if fields(env)[k] != f0[k]] == String[]
        # 대조(항진 아님): 보통 센서 읽기(`zone_blockage` — 내부에서 `global_transform` 을 읽는다)는 같은 세계에서 필드를 바꾼다
        CB.zone_blockage(env; check_paths = false)
        @test "env.sched" in [k for k in keys(f0) if fields(env)[k] != f0[k]]
        s = state(env)
        ncon = count(t -> t in TC.CONSTRUCTION_TYPES, values(s["nodes"]))
        @test length(C["required_nodes"]) == ncon > 0
        @test all(t -> !(t in TC.CONSTRUCTION_TYPES), [s["nodes"][id] for id in keys(s["nodes"]) if !haskey(C["required_nodes"], id)])
        # 로봇 노드가 끼는 간선은 의미 선행이 아니다(배정). 의미 간선 = 건설↔건설 전부(t0 에 WEDGE 없음).
        @test all(e -> C["required_nodes"][e[1]] in TC.CONSTRUCTION_TYPES && C["required_nodes"][e[2]] in TC.CONSTRUCTION_TYPES,
                  C["semantic_edges"])
        @test length(C["semantic_edges"]) + length(C["runtime_edges_at_t0"]) == length(s["edges"])
        @test any(e -> s["nodes"][e[1]] == "RobotGo" || s["nodes"][e[2]] == "RobotGo", C["runtime_edges_at_t0"])
        @test length(C["transport_chains"]) == length(nodes_of(env, CB.TransportUnitGo))
        @test all(c -> all(k -> c[k] !== nothing, ("ftu", "tugo", "deposit", "lift", "assembly", "assembly_complete")),
                  C["transport_chains"])
        r = TC.evaluate_task_contract(C, s)
        @test isempty(r.violations) && isempty(r.unsupported)
    end

    @testset "[2] 음성 대조: NOOP 을 끝까지 굴린 세계는 계약을 통과한다" begin
        env = mkenv(); C = contract(env)
        runall!(env)
        @test CB.project_complete(env)
        s = state(env)
        r = TC.evaluate_task_contract(C, s; terminal = true)
        @test r.violations == String[] && r.unsupported == String[]
        @test TC.task_contract_report(C, s; terminal = true).verdict === :accept
        open(io -> JSON3.write(io, C), joinpath(OUT, "contract_noop.json"), "w")
        open(io -> JSON3.write(io, s), joinpath(OUT, "noop_terminal.json"), "w")
        # 반대 방향 대조: 같은 계약으로 **시작** 세계를 terminal 로 판정하면 미완료로 떨어진다(항진 아님)
        env0 = mkenv()
        @test has(TC.evaluate_task_contract(C, state(env0); terminal = true).violations, "required_tasks_not_closed")
    end

    @testset "[3] goal=start: 완주하지만 운반을 건너뛴 세계 → 계약 위반" begin
        env = mkenv(); C = contract(env)
        tug = first(nodes_of(env, CB.TransportUnitGo))
        CB.set_desired_global_transform!(CB.goal_config(tug), CB.global_transform(CB.start_config(tug)))   # 앵커 3판의 패턴
        @test CB.validate_schedule_transform_tree(env.sched; post_staging = true)   # 기존 장부 검사는 못 본다
        @test has(ev(C, env).violations, "transport_skipped:")
        runall!(env)
        @test CB.project_complete(env)                         # worker 가 "complete" 라고 말할 세계
        s = state(env)
        r = TC.evaluate_task_contract(C, s; terminal = true)
        @test has(r.violations, "transport_skipped:")
        @test !has(r.violations, "final_part_pose")            # 최종 제품만 보면 멀쩡하다 — 그래서 사슬 검사가 필요하다
        @test TC.task_contract_report(C, s; terminal = true).verdict === :reject
        open(io -> JSON3.write(io, C), joinpath(OUT, "contract_goal.json"), "w")
        open(io -> JSON3.write(io, s), joinpath(OUT, "goal_start_terminal.json"), "w")
    end

    @testset "[4] 합법 기하: 빌드 전체 강체 이동은 통과(기하를 금지하지 않는다)" begin
        env = mkenv(); C = contract(env)
        CB._apply_uniform_translation!(env, [0.3, -0.2])
        @test isempty(ev(C, env).violations)
        runall!(env)
        @test CB.project_complete(env)
        @test isempty(ev(C, env; terminal = true).violations)
    end

    @testset "[5] 필수 작업 삭제 · 의미 선행 끊기" begin
        env = mkenv(); C = contract(env)
        lift = last(nodes_of(env, CB.LiftIntoPlace))
        lid = string(CB.node_id(lift))
        CB.rem_node!(env.sched, CB.node_id(lift))
        @test "required_task_deleted:$(lid)" in ev(C, env).violations
        env = mkenv(); C = contract(env)
        tug = first(nodes_of(env, CB.TransportUnitGo))
        dep = CB.get_node(env.sched, CB.DepositCargo(CB.entity(tug)))
        CB.Graphs.rem_edge!(env.sched, vtx(env, tug), vtx(env, dep))
        @test has(ev(C, env).violations, "semantic_precedence_broken:")
    end

    @testset "[6] 임시 간선 제거는 통과 — WEDGE(런타임 직렬화)는 의미 선행이 아니다" begin
        env = mkenv()
        rob = sort!([n for n in CB.get_nodes(env.scene_tree) if CB.matches_template(CB.RobotNode, n)]; by = n -> string(CB.node_id(n)))
        spares = Set(vcat(values(CB.SPARE_POOLS[])...))
        f = first(CB.node_id(n) for n in rob if !(CB.node_id(n) in spares))
        sp = CB.pop_spare!(first(sort!(collect(keys(CB.SPARE_POOLS[])))))
        @test CB.replace_robot!(env, f, sp; verbose = false).status === :replaced    # all3: t0 이전의 fault 처리
        @test !isempty(CB.WEDGE_EDGES[])
        C = contract(env)                                                            # t0 = 그 뒤
        s = state(env)
        W = Set(Tuple.(s["wedge_edges"]))
        @test !isempty(W) && all(e -> !((e[1], e[2]) in W), C["semantic_edges"])
        for (a, b) in unique(CB.WEDGE_EDGES[]); CB.Graphs.rem_edge!(env.sched, a, b); end
        r = ev(C, env)
        @test isempty(r.violations)
        runall!(env)
        @test CB.project_complete(env) && isempty(ev(C, env; terminal = true).violations)
    end

    @testset "[7] 완료 위조 · 과거 재개방" begin
        env = mkenv(); C = contract(env)
        pc = only(nodes_of(env, CB.ProjectComplete))
        push!(env.cache.closed_set, vtx(env, pc))              # 선행이 안 끝났는데 완료 표시
        @test has(ev(C, env).violations, "closed_before_predecessor:")
        env = mkenv(); runall!(env; kmax = 300)
        C = contract(env)                                      # t0 = 300 스텝 뒤
        @test !isempty(C["closed_at_t0"])
        v = first(sort!(collect(env.cache.closed_set)))
        delete!(env.cache.closed_set, v)
        @test has(ev(C, env).violations, "past_reopened:")
    end

    @testset "[8] 존: 삭제·변경은 위반, 추가는 기록만" begin
        env = mkenv()
        CB.add_restriction_zone!(:t5_zone, [0.5, 0.5], 0.3)
        try
            C = contract(env)
            @test haskey(C["zones"], "t5_zone")
            delete!(CB.RESTRICTION_ZONES[], :t5_zone)
            @test "zone_removed:t5_zone" in ev(C, env).violations
            CB.add_restriction_zone!(:t5_zone, [0.5, 0.5], 0.2)            # 완화(반경 축소)
            @test "zone_changed:t5_zone" in ev(C, env).violations
            CB.add_restriction_zone!(:t5_zone, [0.5, 0.5], 0.3)
            CB.add_restriction_zone!(:t5_extra, [3.0, 3.0], 0.1)
            r = ev(C, env)
            @test isempty(r.violations) && r.notes == ["zone_added:t5_extra"]
        finally
            empty!(CB.RESTRICTION_ZONES[])
        end
    end

    @testset "[9] 조립 설치 자세 변경" begin
        env = mkenv(); C = contract(env)
        lift = first(nodes_of(env, CB.LiftIntoPlace))
        g = CB.goal_config(lift)
        CB.set_local_transform!(g, CB.CoordinateTransformations.Translation(0.05, 0.0, 0.0) ∘ CB.local_transform(g))
        @test has(ev(C, env).violations, "install_pose_changed:")
    end

    @testset "[12] 팀 자리를 벗어난 배정 목표 · 작업 시간 명세 변경" begin
        # FTU 로 들어가는 RobotGo(t0 에 68/68 이 팀 자리에서 끝난다 — 0 길이 이동)의 목표를 자리 밖으로 옮긴다.
        # 주의: 그 앞의 이동 RobotGo 를 goal=start 로 바꾸는 것은 물리 위반이 아니다 — 주행은 실제 위치에서 목표로 가므로
        # 로봇은 다음 노드에서 결국 자리로 간다(그래서 로봇 사슬 연속성은 계약에 넣지 않았다; 보고서).
        env = mkenv(); C = contract(env)
        s = state(env)
        u = first(e[1] for e in s["edges"] if s["nodes"][e[1]] == "RobotGo" && s["nodes"][e[2]] == "FormTransportUnit")
        rg = first(CB.get_node(env.sched, v) for v in CB.Graphs.vertices(env.sched) if string(CB.node_id(CB.get_node(env.sched, v))) == u)
        @test isempty(ev(C, env).violations)
        CB.set_desired_global_transform!(CB.goal_config(rg),
            CB.CoordinateTransformations.Translation(1.0, 1.0, 0.0) ∘ CB.global_transform(CB.goal_config(rg)))
        @test has(ev(C, env).violations, "robot_not_at_team_slot:$(u)")
        env = mkenv(); C = contract(env)
        tug = first(nodes_of(env, CB.TransportUnitGo))
        sp = CB.get_node(env.sched, CB.node_id(tug)).spec
        sp.min_duration = sp.min_duration + 0.5                # 소요시간 명세를 바꾼다(0 이어도 달라지게 +)
        @test "task_spec_changed:$(string(CB.node_id(tug)))" in ev(C, env).violations
    end

    @testset "[10] 대응 없는 새 건설 노드 = unsupported(모델 실패가 아니다)" begin
        env = mkenv(); C = contract(env)
        n = CB.ProjectComplete()
        CB.add_node!(env.sched, CB.ScheduleNode(CB.node_id(n), n))
        r = ev(C, env)
        @test isempty(r.violations) && has(r.unsupported, "task_refinement_without_correspondence:")
        @test TC.task_contract_report(C, state(env)).verdict === :unsupported
    end

    @testset "[11] 신뢰 판정은 CB 없는 프로세스에서 JSON 만 읽고 같은 답을 낸다" begin
        tc = joinpath(@__DIR__, "..", "src", "verification", "task_contract.jl")
        code = """
            using JSON3
            include($(repr(tc)))
            @assert !isdefined(Main, :ConstructionBots)
            rd(f) = JSON3.read(read(joinpath($(repr(OUT)), f), String), Dict{String,Any})
            a = TaskContract.evaluate_task_contract(rd("contract_noop.json"), rd("noop_terminal.json"); terminal = true)
            b = TaskContract.evaluate_task_contract(rd("contract_goal.json"), rd("goal_start_terminal.json"); terminal = true)
            println("NOOP=", length(a.violations), " GOALSTART=", join(b.violations, "|"))
            """
        out = read(`$(Base.julia_cmd()) --project=$(dirname(@__DIR__)) -e $code`, String)
        @test occursin("NOOP=0 ", out)
        @test occursin("GOALSTART=transport_skipped:", out)
    end
end
