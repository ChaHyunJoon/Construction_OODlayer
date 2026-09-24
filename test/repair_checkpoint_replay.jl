# =============================================================================
# test/repair_checkpoint_replay.jl — T3 게이트 (독립 실행, runtests.jl 미포함).
#
#   julia +lts --project=. test/repair_checkpoint_replay.jl
#
# 무엇을 재나 — 전부 **원본 계속 실행 vs 복원 실행**이다(두 복원 분기끼리 비교하지 않는다):
#   [1] RVO native adapter: 실제 씬(colored_8x8)의 RVO 를 export→새 sim 에 import 하면 모든 에이전트 필드가
#       비트 동일하고, 원본 sim 과 복원 sim 에 같은 pref 속도를 200 스텝 넣으면 **매 스텝 전 필드가 비트
#       동일**하다(원본은 globalTime 이 앞서 있다 — 그 값이 동역학 비관여라는 측정이다).
#   [2] 위치만 옮긴 재구축(= 옛 `rvo_rebuild!` 가 하는 일)은 **갈린다** — 속도·pref·alpha 가 지워진다.
#       "위치 일치 = 복원" 이 거짓임을 같은 씬에서 잰다(음성 대조).
#   [3] KdTree 순열(읽기·쓰기 불가)은 정확한 거리 동률에서 결과를 바꾼다(측정). RVOTieWatch 는 그 격자에서
#       동률을 보고하고, 무작위 배치에서는 보고하지 않는다.
#   [4] 교차 프로세스 재생: 씬을 굴리다 capture → 부모는 원본을 N 스텝 더 굴리고, **새 julia 프로세스**가
#       artifact 를 import 해 같은 N 스텝을 굴린다. 스텝마다 `EpisodeReplay.step_columns` digest 가 같아야 한다.
# 전체 에피소드(render_demo.jl 경로) 재생 행렬은 `tools/monitor/zrv_replay_episode.sh` 가 돌린다(보고서).
# =============================================================================
using ConstructionBots, Test, Random, Serialization
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
include(joinpath(@__DIR__, "..", "src", "verification", "episode_replay.jl"))   # ZRV_REPLAY_MODE 없음 → 훅 미설치
const E = EpisodeCheckpointIO
const RP = EpisodeReplay
const MODS = [CB]

step!(env) = (CB.step_environment!(env); CB.update_planning_cache!(env, 0.0))
function build_world(nsteps)
    env = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "ckpt-replay",
        num_robots = 6, assignment_mode = :greedy, n_spare_per_pool = 2,
        open_animation_at_end = false, save_animation = false, write_results = false,
        return_env_before_sim = true, rng = Random.MersenneTwister(1))
    CB.enable_battery!(env)
    for _ in 1:nsteps; step!(env); end
    return env
end
agent_state(s) = [Tuple(getproperty(s, Symbol(:getAgent, f))(i) for f in CB.RVO_AGENT_FIELDS)
                  for i in 0:s.getNumAgents()-1]
pref(i, k) = (1.5 * sin(0.37 * i + 0.05 * k), 1.5 * cos(0.23 * i - 0.03 * k))
function lockstep(A, B, n)
    for k in 1:n
        for s in (A, B), i in 0:s.getNumAgents()-1; s.setAgentPrefVelocity(i, pref(i, k)); end
        A.doStep(); B.doStep()
        agent_state(A) == agent_state(B) || return k
    end
    return nothing
end

const ENV0 = build_world(60)

@testset "T3 RVO·재생 게이트" begin
    @testset "[1] RVO export→import 는 비트 동일하고 이후 궤적도 같다" begin
        orig = CB._rvo_raw(CB.rvo_global_sim())
        # 원본을 몇 스텝 더 굴려 globalTime·KdTree 순열에 이력을 쌓는다
        for k in 1:25; for i in 0:orig.getNumAgents()-1; orig.setAgentPrefVelocity(i, pref(i, -k)); end; orig.doStep(); end
        x = CB.rvo_export_state()
        @test isempty(x.gaps)
        @test x.residual.global_time > 0
        n = orig.getNumAgents()
        @test n >= 4
        w = CB.rvo_import_state!(x.state, x.residual)       # run_lego_demo 는 기록 없이 sim 을 만들었다 → 감시 모드
        @test w isa CB.RVOSimHarness && w.watch && !w.kd_restored
        B = CB._rvo_raw(CB.rvo_global_sim())
        @test B !== orig
        @test agent_state(B) == agent_state(orig)                    # 모든 필드 비트 동일
        @test CB.rvo_export_state().state == x.state                 # 정준 행 입력이 같다
        @test B.getGlobalTime() == 0.0 && orig.getGlobalTime() > 0   # 옮기지 못한 값(동역학 비관여)
        @test lockstep(orig, B, 200) === nothing
    end

    @testset "[2] 음성 대조: 위치만 옮긴 재구축은 갈린다" begin
        orig = CB._rvo_raw(CB.rvo_global_sim())
        for k in 1:10; for i in 0:orig.getNumAgents()-1; orig.setAgentPrefVelocity(i, pref(i, k)); end; orig.doStep(); end
        st = CB.rvo_export_state().state
        P = CB.rvo_python_module().PyRVOSimulator(st.element.time_step, 2.0, 5, 2.0, 1.0, 0.5,
                                                   CB.rvo_default_max_speed(), (0.0, 0.0))
        for a in st.element.agents                                   # rvo_add_agent! 가 쓰는 필드만
            i = P.addAgent(a.Position)
            P.setAgentNeighborDist(i, a.NeighborDist); P.setAgentMaxSpeed(i, a.MaxSpeed); P.setAgentRadius(i, a.Radius)
        end
        @test [s[1] for s in agent_state(P)] == [s[1] for s in agent_state(orig)]   # 위치는 같다
        @test agent_state(P) != agent_state(orig)                                    # 상태는 아니다
        k = lockstep(orig, P, 200)
        @test k !== nothing
        @info "position-only rebuild diverged at doStep" k
    end

    @testset "[3] KdTree 순열은 동률에서 결과를 바꾼다; TieWatch 가 동률을 잡는다" begin
        rvo = CB.rvo_python_module()
        mk() = rvo.PyRVOSimulator(1 / 40, 2.0, 5, 2.0, 1.0, 0.5, 4.0, (0.0, 0.0))
        lat = [(Float64(x), Float64(y)) for x in -3:2 for y in -3:2]
        rng = Random.MersenneTwister(5)
        diverged = 0; unresolved = 0; detected = 0; unsound = 0; replay_diverged = 0; replay_restored = 0
        for t in 1:300
            A = CB.RVOSimHarness(mk(); record = true); order = Random.shuffle(rng, lat)
            for p in order; i = A.addAgent(p); A.setAgentRadius(i, 0.3); end
            for k in 1:rand(rng, 1:30)
                for i in 0:length(order)-1; A.setAgentPrefVelocity(i, (4 * rand(rng) - 2, 4 * rand(rng) - 2)); end
                A.doStep()
            end
            for (i, p) in enumerate(order)
                A.setAgentPosition(i - 1, p); A.setAgentVelocity(i - 1, (rand(rng, (-0.5, 0.5)), rand(rng, (-0.5, 0.5))))
                A.setAgentPrefVelocity(i - 1, (rand(rng, (-1.5, 1.5)), rand(rng, (-1.5, 0.5, 1.5))))
            end
            st = (element = (time_step = A.getTimeStep(), n_agents = length(order),
                             agents = [NamedTuple{CB.RVO_AGENT_FIELDS}(s) for s in agent_state(A)]),
                  is_up_to_date = true, timestamp = 0.0, module_file = String(rvo.__file__))
            idmap = CB.rvo_global_id_map()
            w = CB.rvo_import_state!(st)                                   # (b) 이력 없음 → 감시 모드
            x = CB.rvo_import_state!(st, CB._rvo_residual(A, CB._rvo_raw(A)))   # (a) 이력 재연 → 정확 복원
            CB.set_rvo_global_id_map!(idmap)
            replay_restored += x.kd_restored && x.py.getGlobalTime() == A.getGlobalTime()
            w.doStep(); x.doStep(); A.doStep()
            replay_diverged += agent_state(A) != agent_state(x.py)
            div = agent_state(A) != agent_state(w.py)
            diverged += div
            unresolved += !isempty(w.ties)
            detected += (w.resolved + length(w.ties)) > 0
            unsound += div && isempty(w.ties)                 # 갈렸는데 "순서 무관" 이라 한 경우
        end
        @info "exact-tie lattice (300 trials)" diverged unresolved detected unsound replay_diverged replay_restored
        @test diverged >= 1              # 순열은 실제로 숨은 상태다(항진 아님)
        @test replay_restored == 300     # 이력 재연은 globalTime 까지 원본과 같게 만든다
        @test replay_diverged == 0       # 이력 재연 복원은 동률 격자에서도 원본과 비트 동일
        @test detected == 300            # 모든 격자 시행에서 동률을 본다
        @test unsound == 0               # 갈린 시행은 전부 '증명 못 함' 으로 남는다(해소기가 거짓 증명을 안 한다)
        # 무작위 배치: 동률 없음
        B = mk()
        for i in 1:30; B.addAgent((10 * rand(rng), 10 * rand(rng))); end
        wb = CB.RVOSimHarness(B; watch = true)
        for k in 1:50
            for i in 0:29; B.setAgentPrefVelocity(i, pref(i, k)); end
            wb.doStep()
        end
        @test wb.n_steps == 50 && isempty(wb.ties)
    end

    @testset "[4] 교차 프로세스: 원본 계속 vs 새 프로세스 import 계속" begin
        CB.RVO_RECORD_BUILDS[] = true          # 하니스와 같이: 새 sim 마다 doStep 직전 위치 기록
        env = build_world(80)
        N = 300
        dir = mktempdir()
        ls = (k = 80,)
        cp, cap = E.export_checkpoint(dir, "mini", env; modules = MODS, t0_hook = "test:step-80",
            zone_dispatch_in_progress = false, fingerprints = RP.fingerprints(), loop_state = ls,
            pre_injection_sha256 = "n/a", post_injection_sha256 = "n/a")
        @test !any(g -> startswith(g, "native:"), cap.gaps)
        @test !any(g -> occursin("dependency module", g), cap.gaps)
        serialize(joinpath(dir, "cp.jls"), cp)
        cols(e, k) = join((RP._h(getfield(RP.step_columns(e, (k = k,)), Symbol(c)))
                           for c in Main.ReplayCompare.TRACE_COLUMNS), ' ')
        parent = String[]
        for k in 1:N; step!(env); push!(parent, cols(env, k)); end
        child = joinpath(dir, "child.jl")
        write(child, """
            using ConstructionBots, Random, Serialization
            const CB = ConstructionBots
            CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
            include($(repr(joinpath(@__DIR__, "..", "src", "verification", "episode_replay.jl"))))
            r = EpisodeCheckpointIO.import_checkpoint(deserialize($(repr(joinpath(dir, "cp.jls")))); modules = [CB])
            println("MISMATCH=[", join(r.mismatched_blocks, ","), "]")
            step!(env) = (CB.step_environment!(env); CB.update_planning_cache!(env, 0.0))
            cols(e, k) = join((EpisodeReplay._h(getfield(EpisodeReplay.step_columns(e, (k = k,)), Symbol(c)))
                               for c in ReplayCompare.TRACE_COLUMNS), ' ')
            out = String[]
            for k in 1:$(N); step!(r.env); push!(out, cols(r.env, k)); end
            w = r.native_handles["ConstructionBots.RVO_SIM_WRAPPER"]
            println("TIES=", length(w.ties), " RESOLVED=", w.resolved, " WATCHED=", w.n_steps, " KD_RESTORED=", w.kd_restored)
            serialize($(repr(joinpath(dir, "child_cols.jls"))), out)
            """)
        out = read(`$(Base.julia_cmd()) --project=$(pkgdir(CB)) $(child)`, String)
        @info "child" out = filter(l -> occursin(r"^(MISMATCH|TIES)", l), split(out, '\n'))
        ch = deserialize(joinpath(dir, "child_cols.jls"))
        first_div = findfirst(k -> parent[k] != ch[k], 1:N)
        first_div === nothing || @info "first divergent step" first_div parent[first_div] ch[first_div]
        @test occursin("MISMATCH=[]", out)
        @test occursin("KD_RESTORED=true", out)
        @test first_div === nothing
    end
end
