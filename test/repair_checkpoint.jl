# =============================================================================
# test/repair_checkpoint.jl — T2 전체 checkpoint capture/export/import 게이트 (독립 실행).
#
#   julia +lts --project=. test/repair_checkpoint.jl
#
# runtests.jl 에 넣지 않는다(브리프가 요구하지 않음 — 단독 게이트). 실제 씬(colored_8x8, 로봇 6)을
# 짓고 40 스텝 굴린 뒤, zone·대기 사건·예약 closure·hazard 누적값·스크립트 전역·env↔전역 alias 를
# 채워 capture 한다. 그다음 세계를 여러 축으로 망가뜨리고 import 해서 **정확히** 돌아오는지 본다.
#
# 🔴 mdp.jl 을 include 하는 것은 **시험에서만**이다: HAZARD_STATE(누적 위험·Exp(1) 문턱·로봇별
#    MersenneTwister)가 세계에 있어야 "RNG/hazard 누적값" 을 잴 수 있다. production 은 이 파일을
#    통째로 include 하지 않는다(브리프).
# 🔴 `FakeScript` 는 render_demo.jl/policy.jl 이 Main 에 두는 "모듈 밖" 스크립트 전역을 흉내 낸다.
#    Main 을 대상에 넣지 않는 이유: 시험 자신의 지역 변수를 복원이 되감으면 시험이 무의미해진다.
# =============================================================================
using ConstructionBots, Test, Random, Graphs, SHA, Serialization
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))
include(joinpath(@__DIR__, "..", "src", "verification", "episode_checkpoint.jl"))
const E = EpisodeCheckpointIO
const R = RepairTypes

const FAKE_SCRIPT_SRC = """
module FakeScript
const _ZONE_CT = Ref(0)            # const Ref (render_demo.jl 의 _ZONE_CT 모양)
COUNTER = 0                        # 비-const 전역(재바인딩으로 복원돼야 한다)
const HOLDER = Ref{Any}(nothing)   # env 안의 노드를 가리킨다 → alias 가 살아남아야 한다
OPAQUE = nothing                   # 직렬화 불가 값을 심는 자리(인증 불가 시험)
end
"""
include_string(Main, FAKE_SCRIPT_SRC)   # [9] 의 자식 프로세스가 같은 글자로 다시 정의한다
const MODS = [CB, FakeScript]

const OUT = mktempdir()
const FP = R.Fingerprints(code_rev = "test", code_dirty_digest = "none",
    dirty_snapshot_digest = "none", config_digest = "none", julia_version = string(VERSION),
    manifest_digest = "none", build_id = "none", julia_threads = Threads.nthreads(),
    solver_name = "none", solver_version = "none", solver_seed = 0, solver_threads = 1,
    model = "none", service_code_fingerprint = "none", prompt_digest = "none",
    schema_digest = "none", validator_version = "none", scorer_version = "none",
    capability_contract_version = "none")
const CONTRACT = (kind = "test-contract", total = 0)   # 진짜 task contract 는 T5

step!(env, k) = (CB.step_environment!(env); CB.update_planning_cache!(env, 0.0); CB.set_sim_step!(k))
robots(env) = sort!([n for n in CB.get_nodes(env.scene_tree) if CB.matches_template(CB.RobotNode, n)];
                    by = n -> string(CB.node_id(n)))
lines_of(w) = E.world_lines(w.env; modules = MODS, loop_state = w.loop_state,
                            task_contract = w.task_contract, fingerprints = w.fingerprints)

function build_world()
    env = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "ckpt",
        num_robots = 6, assignment_mode = :greedy, n_spare_per_pool = 2,
        open_animation_at_end = false, save_animation = false, write_results = false,
        return_env_before_sim = true, rng = Random.MersenneTwister(1))
    CB.enable_battery!(env)
    CB.enable_hazard!(env; seed = 7)
    for k in 1:40; step!(env, k); end
    CB.add_restriction_zone!(:ckpt_zone, [0.5, 0.5], 0.3)
    CB.push_ood!("ckpt: pending event")
    CB.schedule_ood_at_closed!(10_000, e -> "never fires")      # closure 가 든 예약 사건
    FakeScript.HOLDER[] = first(robots(env))
    FakeScript._ZONE_CT[] = 3
    FakeScript.COUNTER = 7
    Random.seed!(1234); rand(3)                                  # 기본 RNG 를 알려진 상태로
    return (; env, loop_state = (k = 40, no_progress = 0, cursor = 1),
            task_contract = CONTRACT, fingerprints = FP)
end

const W0 = build_world()
const RID = CB.node_id(first(robots(W0.env)))

@testset "T2 전체 checkpoint" begin
    L0 = lines_of(W0)
    @info "world" lines = length(L0.lines) inventory = length(E.global_inventory(MODS))

    @testset "[0] 목록이 잡아야 할 것을 잡는다" begin
        names_ = Set(e.name for e in E.global_inventory(MODS))
        for n in (:RESPEC_QUEUE, :OOD_SCHEDULE, :HAZARD_STATE, :RESTRICTION_ZONES, :SPARE_POOLS,
                  :BATTERY_FLEET, :BATTERY_DELIVERIES, :FAULTED_ROBOTS, :VALID_ID_COUNTERS,
                  :INVALID_ID_COUNTERS, :SNAP_COUNT, :RESPEC_HOLD, :SIM_STEP, :CARRIER_LAST_D,
                  :_CACHE_TIMESTAMP_COUNTER, :RVO_ID_GLOBAL_MAP, :RVO_SIM_WRAPPER,
                  :_ZONE_CT, :COUNTER, :HOLDER, :OPAQUE)
            @test n in names_
        end
        @test !(:_FAULT_RE in names_)                       # Regex 는 사유 있는 제외
        # STATE_GLOBALS(사람이 적은 표)의 :state/:split 중 이 프로세스에 정의된 것은 전부 잡힌다.
        want = [k for (k, v) in CB.STATE_GLOBALS if v in (:state, :split) && isdefined(CB, k)]
        @test isempty(setdiff(want, names_))
    end

    @testset "[1] capture 는 세계와 RNG 를 바꾸지 않는다" begin
        rng0 = copy(Random.default_rng())
        c1 = E.capture_checkpoint(W0.env; modules = MODS, loop_state = W0.loop_state,
                                  task_contract = CONTRACT, fingerprints = FP)
        @test copy(Random.default_rng()) == rng0
        @test lines_of(W0).lines == L0.lines
        c2 = E.capture_checkpoint(W0.env; modules = MODS, loop_state = W0.loop_state,
                                  task_contract = CONTRACT, fingerprints = FP)
        @test c1.artifact_sha256 == c2.artifact_sha256      # 같은 세계 → 같은 바이트
        @test c1.lines == L0.lines
    end

    cp, cap = E.export_checkpoint(OUT, "cp-test", W0.env; modules = MODS, t0_hook = "test:after-step-40",
        zone_dispatch_in_progress = false, fingerprints = FP, loop_state = W0.loop_state,
        task_contract = CONTRACT)
    rng_at_capture = copy(Random.default_rng())
    hz_at_capture = deepcopy(CB.HAZARD_STATE[])

    @testset "[2] export: digest 와 인증 불가 사유" begin
        @test bytes2hex(sha256(read(cp.artifact_path))) == cp.artifact_sha256
        @test Set(keys(cp.block_sha256)) == Set(R.CHECKPOINT_BLOCKS)
        @test isfile(joinpath(OUT, "cp-test.fields.json"))
        gaps = R.certification_gaps(cp)
        # T3: RVO 는 native adapter 가 옮긴다 — native gap 이 없어야 하고, 정준 행에 에이전트 필드가 있어야 한다.
        @test !any(g -> startswith(g, "native:"), gaps)
        @test any(l -> occursin("RVO_SIM_WRAPPER.element.agents[1].Velocity", l), cap.lines)
        @test any(g -> occursin("pre-injection", g), gaps)
        @test !any(g -> occursin("loop cursor", g), gaps)                   # 넘겼으므로 없어야 한다
        bare = E.capture_checkpoint(W0.env; modules = MODS)
        @test any(g -> occursin("loop cursor", g), bare.gaps)
        @test any(g -> occursin("task contract", g), bare.gaps)
    end

    # ---- 세계를 여러 축으로 망가뜨린다 -----------------------------------------------------------
    env = W0.env
    for k in 41:45; step!(env, k); end                        # 위치·cache·시간·SoC·hazard 누적
    vs = collect(Graphs.vertices(env.sched))
    added = false
    for u in vs, v in reverse(vs)
        u != v && !Graphs.has_edge(env.sched, u, v) && (added = Graphs.add_edge!(env.sched, u, v)) && break
    end
    CB.push_ood!("ckpt: late event")
    rand(100)
    CB.HAZARD_STATE[].thr_zone += 1.0
    rand(CB.HAZARD_STATE[].rng_zone, 10)
    FakeScript.HOLDER[] = deepcopy(FakeScript.HOLDER[])       # alias 를 끊는다
    FakeScript.COUNTER += 5
    FakeScript._ZONE_CT[] = 99
    CB.get_unique_id(CB.TransformNodeID)
    delete!(CB.RESTRICTION_ZONES[], :ckpt_zone)
    CB.SNAP_COUNT[] += 1

    # 🔴 RNG 를 읽는 것은 전부 **바깥 testset 수준**에서 한다: `@testset` 은 들어갈 때 기본 RNG 를 다시
    #    seed 하고 나올 때 되돌린다(Test stdlib). 중첩 testset 안에서 `default_rng()` 를 비교하면 복원이
    #    아니라 Test 의 재시드를 재게 된다 — 첫 판이 실제로 그렇게 항진적으로 초록이었다.
    Lm = lines_of((; env, W0.loop_state, task_contract = CONTRACT, fingerprints = FP))
    mismatch_before_import = E.verify_world(cp, (; env, W0.loop_state, task_contract = CONTRACT,
                                                  fingerprints = FP); modules = MODS)
    rng_mutated = copy(Random.default_rng())

    r = E.import_checkpoint(cp; modules = MODS)
    rng_after_import = copy(Random.default_rng())
    L1 = lines_of(r)
    c3 = E.capture_checkpoint(r.env; modules = MODS, loop_state = r.loop_state,
                              task_contract = r.task_contract, fingerprints = r.fingerprints)

    @testset "[3] 망가뜨린 세계는 다르다 (대조)" begin
        @test added
        @test rng_mutated != rng_at_capture
        d = E.diff_worlds(L0, Lm; per_field = 1)
        @test !isempty(d)
        # 필드별 차이가 망가뜨린 자리를 **이름으로** 가리킨다
        for needle in ("RESTRICTION_ZONES", "FakeScript.HOLDER", "FakeScript.COUNTER", "SNAP_COUNT",
                       "rng.default", "HAZARD_STATE", "RESPEC_QUEUE", "env.sched", "VALID_ID_COUNTERS")
            @test (needle, any(l -> occursin(needle, l), d)) == (needle, true)
        end
        @test !isempty(mismatch_before_import)
    end

    @testset "[4] import 가 graph·queue·RNG·alias·전역을 정확히 되돌린다" begin
        @test isempty(r.mismatched_blocks)
        d = E.diff_worlds(L0, L1)
        isempty(d) || E.print_diff(stdout, d)
        @test isempty(d)
        @test L1.lines == L0.lines                            # 정준 행 전체가 비트 동일
        @test r.env !== W0.env
        @test !added || Graphs.ne(r.env.sched) == Graphs.ne(W0.env.sched) - 1
        @test CB.RESPEC_QUEUE.pending[end] == "ckpt: pending event"
        @test rng_after_import == rng_at_capture
        hz = CB.HAZARD_STATE[]
        @test hz.thr_zone == hz_at_capture.thr_zone && hz.cum_break == hz_at_capture.cum_break
        @test hz.rng_zone == hz_at_capture.rng_zone
        # alias: 스크립트 전역이 가리키는 노드 = 복원된 씬트리의 그 노드(같은 객체)
        @test FakeScript.HOLDER[] === CB.get_node(r.env.scene_tree, RID)
        @test FakeScript.COUNTER == 7 && FakeScript._ZONE_CT[] == 3
        @test haskey(CB.RESTRICTION_ZONES[], :ckpt_zone)
        @test r.loop_state == W0.loop_state
        # 복원된 세계를 다시 capture 하면 블록 정준 digest 가 같다. 바이트 digest 는 같지 않을 수 있다 —
        # 익명 closure 의 타입은 역직렬화 때 새로 만들어진다(`__deserialized_types__`).
        @test c3.block_sha256 == cp.block_sha256
        @info "rehashed dicts on import" r.n_dicts_rehashed c3.artifact_sha256 == cp.artifact_sha256
    end

    @testset "[5] 필드별 차이 출력기 — 심은 차이 하나를 정확히 짚는다 (음성 대조)" begin
        old = CB._CACHE_TIMESTAMP_COUNTER[]
        CB._CACHE_TIMESTAMP_COUNTER[] = old + 1e-3
        d = E.diff_worlds(L0, lines_of(r))
        @test length(d) == 1 && occursin("_CACHE_TIMESTAMP_COUNTER", d[1])
        @test isempty(E.diff_worlds(L0, lines_of(r); atol = 1e-2))   # 명시적 tolerance 안이면 같다
        @test E.verify_world(cp, r; modules = MODS) == [:globals]
        CB._CACHE_TIMESTAMP_COUNTER[] = old
        # alias 만 끊고 값은 같게: 정준 행이 @ref 차이로 잡는다
        FakeScript.HOLDER[] = deepcopy(FakeScript.HOLDER[])
        d2 = E.diff_worlds(L0, lines_of(r))
        @test !isempty(d2) && all(l -> occursin("FakeScript.HOLDER", l), d2)
        @test E.verify_world(cp, r; modules = MODS) == [:globals]
        FakeScript.HOLDER[] = CB.get_node(r.env.scene_tree, RID)
        @test isempty(E.verify_world(cp, r; modules = MODS))
    end

    @testset "[6] 다른 파일은 import 를 거절한다" begin
        bad = joinpath(OUT, "tampered.jls")
        b = read(cp.artifact_path); b[end÷2] ⊻= 0x01; write(bad, b)
        cp2 = R.EpisodeCheckpoint(cp.checkpoint_id, cp.t0_hook, false, FP, bad, cp.artifact_sha256,
                                  cp.block_sha256, "", "", String[])
        @test_throws ErrorException E.import_checkpoint(cp2; modules = MODS)
    end

    @testset "[7] 직렬화 불가 상태는 인증 불가 사유가 된다" begin
        FakeScript.OPAQUE = Ptr{Cvoid}(1)
        try
            c = E.capture_checkpoint(r.env; modules = MODS, loop_state = r.loop_state,
                                     task_contract = CONTRACT, fingerprints = FP)
            @test any(g -> occursin("unserializable: globals.Main.FakeScript.OPAQUE", g), c.gaps)
        finally
            FakeScript.OPAQUE = nothing
        end
    end

    @testset "[8] Dict 순서: 표준 Serializer 는 바꾸고 이 직렬화기는 보존한다" begin
        d = Dict{Symbol,Int}(Symbol("k", i) => i for i in 1:50)
        for i in 1:20; delete!(d, Symbol("k", 2i)); end
        io = IOBuffer(); serialize(io, d)
        @test collect(keys(deserialize(seekstart(io)))) != collect(keys(d))   # 표준: 순서가 바뀐다
        back, nfix = E._deserialize_bytes(E._serialize_bytes(d))
        @test collect(keys(back)) == collect(keys(d)) && nfix == 0
    end

    @testset "[9] 다른 프로세스가 같은 artifact 를 import 한다 (교차 프로세스)" begin
        # 원본 없이 기록된 블록 digest 만으로 검사한다 — worker(T4)가 쓸 경로와 같다. Dict 레이아웃이
        # 이 프로세스의 해시로 다시 맞는지(`REHASHED`), 익명 closure 가 새 타입이 돼도 같은 정준 행을
        # 내는지가 여기서만 잰다.
        envfile = joinpath(OUT, "cp-test.envelope.jls")
        serialize(envfile, cp)
        child = joinpath(OUT, "child.jl")
        write(child, """
            using ConstructionBots, Random, Serialization
            const CB = ConstructionBots
            CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
            CB.include(joinpath(pkgdir(CB), "src", "smdp", "mdp.jl"))
            include($(repr(joinpath(@__DIR__, "..", "src", "verification", "episode_checkpoint.jl"))))
            include_string(Main, $(repr(FAKE_SCRIPT_SRC)))
            r = EpisodeCheckpointIO.import_checkpoint(deserialize($(repr(envfile))); modules = [CB, FakeScript])
            println("MISMATCH=[", join(r.mismatched_blocks, ","), "]")
            println("REHASHED=", r.n_dicts_rehashed)
            println("HOLDER_ALIAS=", FakeScript.HOLDER[] === CB.get_node(r.env.scene_tree, CB.node_id(FakeScript.HOLDER[])))
            W = EpisodeCheckpointIO.world_lines(r.env; modules = [CB, FakeScript], loop_state = r.loop_state,
                    task_contract = r.task_contract, fingerprints = r.fingerprints)
            serialize($(repr(joinpath(OUT, "child_lines.jls"))), (W.lines, W.fields))
            """)
        out = read(`$(Base.julia_cmd()) --project=$(pkgdir(CB)) $(child)`, String)
        @info "child import" out = filter(l -> occursin(r"^(MISMATCH|REHASHED|HOLDER)", l), split(out, '\n'))
        cl, cf = deserialize(joinpath(OUT, "child_lines.jls"))
        d = E.diff_worlds(L0, (; lines = cl, fields = cf))
        isempty(d) || E.print_diff(stdout, d)
        @test isempty(d)
        @test occursin("MISMATCH=[]", out)
        @test occursin("HOLDER_ALIAS=true", out)
    end
end
