# =============================================================================
# repair_branch_isolation.jl — T4 에피소드 수준 게이트(단독 실행, runtests.jl 미포함; 한 에피소드 20–60 분).
#
#   julia +lts --project=. test/repair_branch_isolation.jl <model> <case> <seed> <outroot> [isolation|noop] [orig_trace]
#
# 부모(원래 세계)를 t0 에 **tick 없이** 세워 두고 분기를 순차로 새 프로세스에서 돌린다:
#   isolation: N1 A1 N2 A2 E X K V H   (N=NOOP, A=RVO/zone/cache/spare/ID/RNG 변경, E=탈출 시도+override+pi0 변경,
#              X=예외, K=SIGABRT, V=어댑터 없는 engine 진행, H=프로세스 트리 + 무한 loop → wall timeout)
#   noop     : N1 만 (T3 재생 칸 재검증용)
# 분기마다 부모 `verify`(t0 세계 digest·tick 카운터·RNG). 끝나면 실제 원장 digest 대조 → 부모 `resume` 으로
# 원래 세계를 pi0 로 끝까지 굴려 **그 궤적**과 NOOP 분기 궤적을 t0 이후 전 스텝 비교한다.
# [orig_trace] 를 주면(T3 의 orig-a trace — 같은 런타임 코드) 그것과도 비교한다.
# =============================================================================
using Test, JSON3, Sockets
include(joinpath(@__DIR__, "..", "src", "verification", "branch_runner.jl"))
include(joinpath(@__DIR__, "..", "src", "verification", "replay_compare.jl"))
const BR = BranchRunner
const RC = ReplayCompare

model, case, seed, root = ARGS[1], ARGS[2], parse(Int, ARGS[3]), abspath(ARGS[4])
seq = length(ARGS) >= 5 ? ARGS[5] : "isolation"
orig = length(ARGS) >= 6 ? ARGS[6] : ""
FIX = joinpath(@__DIR__, "fixtures", "repair_verification", "branch_actions")
mkpath(root)
env = BR.pi0_launch_env(model, case, seed)
# worker 예산(설계 §7.1: 분기마다 같은 절대 예산). wall 은 역사적 episode wall(3600 s)과 같다 —
# 분기는 render_demo 를 처음부터 띄운 뒤 t0 에서 잇기 때문에 한 판 전체와 같은 일을 한다.
LIM = BR.Limits(wall_s = 3600, cpu_s = 7200, mem_bytes = 24 * 2^30)
log(x...) = (println("[t4 ", Libc.strftime("%H:%M:%S", time()), "] ", x...); flush(stdout))

par = BR.start_parent(joinpath(root, "parent"), env)
held = BR.wait_held(par)
contract = BR._json(joinpath(par.dir, "contract.json"))
log("parent held at t0 iter=", held["t0_iter"], " gaps=", contract["gaps"])
ledger0 = BR.ledger_digest(contract)
pdir0 = BR.dir_digest(par.dir)
verifies = Dict{String,Any}("before" => BR.parent_command(par, "verify"))
results = Dict{String,Any}()

function branch!(id, action; limits = LIM, extra = Dict{String,String}())
    log("branch ", id, " action=", isempty(action) ? "noop" : basename(action))
    v = BR.run_branch(; parent_dir = par.dir, branch_id = id, outroot = root, launch_env = env, limits,
                      action_file = action, extra_env = extra)
    d = BR.report_dict(v); d["supervisor"] = Dict(String(k) => x for (k, x) in pairs(v.supervisor))
    BR._write(joinpath(root, id, "rollout_report.json"), d)
    results[id] = d
    verifies[id] = BR.parent_command(par, "verify")
    log("  → ", d["outcome"], " cause=", d["unknown_cause"], " reason=", d["terminal_reason"], " steps=", d["sim_steps"],
        " wall=", round(Int, d["wall_s"]), "s violations=", d["violations"], " parent_verify=", verifies[id]["mismatched_blocks"],
        " counters_equal=", verifies[id]["counters_equal"])
    return v
end

branch!("N1", "")
if seq in ("isolation", "escape")
if seq == "isolation"
    branch!("A1", joinpath(FIX, "mutate_all.jl"))
    branch!("N2", "")
    branch!("A2", joinpath(FIX, "mutate_all.jl"))
end
    # E: 탈출 시도. supervisor 가 TCP listener 를 열고 받은 연결 수를 센다(= 서비스 호출 수가 늘었나).
    srv = listen(ip"127.0.0.1", 0); port = Int(getsockname(srv)[2]); n_conn = Ref(0)
    @async while true
        c = try accept(srv) catch; break end
        n_conn[] += 1; close(c)
    end
    branch!("E", joinpath(FIX, "escape.jl"); extra = Dict("ZRV_PROBE_PORT" => string(port), "ZRV_PROBE_PID" => string(getpid(par.process))))
    close(srv); results["E"]["tcp_accepted"] = n_conn[]
if seq == "isolation"
    branch!("X", joinpath(FIX, "throw.jl"))
    branch!("K", joinpath(FIX, "abort.jl"))
    branch!("V", joinpath(FIX, "advance.jl"))
    # H: wall 을 줄여 timeout 을 강제한다(한도만 다르다 — 시뮬 예산은 같다).
    t_startup = something(tryparse(Float64, get(ENV, "ZRV_T4_HANG_WALL", "")), 420.0)
    branch!("H", joinpath(FIX, "hang.jl"); limits = BR.Limits(wall_s = t_startup, cpu_s = LIM.cpu_s, mem_bytes = LIM.mem_bytes))
end
end
ledger1 = BR.ledger_digest(contract)
pdir1 = BR.dir_digest(par.dir)
log("real ledger before=", ledger0, " after=", ledger1)
fin = BR.parent_command(par, "resume")
log("parent resumed (counters_equal=", fin["counters_equal"], ") — running the original world to its terminal")
wait(par.process); close(par.log)
pterm = BR._json(joinpath(par.dir, "terminal.json"))
log("parent terminal complete=", pterm["complete"], " reason=", pterm["terminal_reason"], " iter=", pterm["iter"])

t0 = contract["t0_iter"]
tr(d) = joinpath(d, "trace.tsv")
cmp(a, b) = RC.compare_traces(tr(a), tr(b); from_iter = t0, ignore = ("rng",))
eq(c) = c.first_divergent_iter === nothing && c.only_a == 0 && c.only_b == 0 && c.n_common > 0
summary = Dict{String,Any}("episode" => "$(model)__$(case)__s$(seed)", "sequence" => seq, "t0_iter" => t0,
    "parent_terminal" => Dict(k => pterm[k] for k in ("complete", "terminal_reason", "closed", "iter")),
    "results" => results, "parent_verifies" => verifies, "real_ledger" => Dict("before" => ledger0, "after" => ledger1),
    "parent_dir" => Dict("before" => pdir0, "after" => pdir1),
    "noop_vs_parent" => Dict(), "rng_parent_after_t0_advanced" => get(pterm, "rng_advanced_after_t0", nothing))
for n in ("N1", "N2")
    isdir(joinpath(root, n)) || continue
    summary["noop_vs_parent"][n] = cmp(par.dir, joinpath(root, n))
end
# 🔴 다른 빌드(컴파일 캐시)의 trace 와는 `rvo`·`globals` 열을 비교할 수 없다(T4 실측): `rvo` 열에 CB 모듈 최상위의
#    `RVO_SIM_WRAPPER = CachedElement(…, time())` — **precompile 시각** — 이 실리고, `globals` 의 `VALID_ID_COUNTERS`
#    (DataType 키 Dict)의 순회 순서가 빌드마다 다르다(내용은 같다). 그래서 옛 trace 와는 loop·cache·sched·scene 네 열만 본다.
const CROSS_BUILD_IGNORE = ("rng", "rvo", "globals")
isempty(orig) || (summary["parent_vs_orig_4col"] = RC.compare_traces(orig, tr(par.dir); from_iter = t0, ignore = CROSS_BUILD_IGNORE))
isempty(orig) || (summary["N1_vs_orig_4col"] = RC.compare_traces(orig, tr(joinpath(root, "N1")); from_iter = t0, ignore = CROSS_BUILD_IGNORE))
if seq == "isolation"
    summary["N1_vs_N2"] = cmp(joinpath(root, "N1"), joinpath(root, "N2"))
    summary["A1_vs_A2"] = cmp(joinpath(root, "A1"), joinpath(root, "A2"))
    summary["A1_vs_N1"] = cmp(joinpath(root, "A1"), joinpath(root, "N1"))
end
BR._write(joinpath(root, "summary.json"), summary)

oc(id) = results[id]["outcome"]; cz(id) = results[id]["unknown_cause"]
parent_outcome = pterm["complete"] ? "COMPLETE" : "FAIL_WITHIN_BUDGET"
@testset "T4 branch isolation $(model) $(case) s$(seed) ($(seq))" begin
    @testset "parent stays at t0" begin
        for (k, v) in verifies
            @test isempty(v["mismatched_blocks"])
            @test v["counters_equal"] === true
            @test v["rng_equal"] === true
        end
        @test fin["counters_equal"] === true
    end
    @testset "NOOP rollout == original runtime" begin
        @test oc("N1") == parent_outcome
        @test results["N1"]["terminal_reason"] == pterm["terminal_reason"]
        @test eq(summary["noop_vs_parent"]["N1"])
        @test results["N1"]["violations"] == String[]
        @test results["N1"]["checks"]["claim_agrees"] === true
        @test results["N1"]["zone_ladder_fired"] == 0
        isempty(orig) || @test eq(summary["N1_vs_orig_4col"])
        isempty(orig) || @test eq(summary["parent_vs_orig_4col"])
    end
    @testset "shadow never touches the real ledger" begin
        @test ledger0 == ledger1
        @test pdir0 == pdir1 && pdir0.n_files > 5            # every parent output file (ckpt, trace, stream, …)
        @test ledger0["exists"] === true
        for (id, r) in results
            @test r["checks"]["leftover_processes"] == 0
        end
    end
    if seq == "isolation"
        @testset "A mutates; parent and B do not change; order does not matter" begin
            A = BR._json(joinpath(root, "A1", "terminal.json"))["branch"]["audit"]["fields_changed_by_action"]
            for f in ("globals.ConstructionBots.RESTRICTION_ZONES", "globals.ConstructionBots.SPARE_POOLS",
                      "globals.ConstructionBots.VALID_ID_COUNTERS", "rng.default", "env.cache")
                @test f in A
            end
            @test "globals.ConstructionBots.RVO_SIM_WRAPPER" in A          # native RVO state
            @test !eq(summary["A1_vs_N1"])                      # the mutation had an effect (not vacuous)
            @test eq(summary["N1_vs_N2"])                       # N before A == N after A
            @test eq(summary["A1_vs_A2"])                       # A after N == A after (N, A, N)
            @test oc("N2") == oc("N1")
            @test oc("A2") == oc("A1")
        end
    end
    if seq in ("isolation", "escape")
        @testset "escape attempts are blocked or flagged" begin
            act = BR._json(joinpath(root, "E", "terminal.json"))["branch"]["action"]["returned"]
            @test !occursin("WROTE", act)
            @test !occursin("READ\"", act) && occursin("read_parent_environ", act)
            @test !occursin("CONNECTED", act)
            @test results["E"]["tcp_accepted"] == 0
            @test !isfile(joinpath(par.dir, "INJECTED"))
            @test oc("E") == "UNKNOWN" && cz("E") == "contract_violation"
            @test any(occursin("runtime methods changed", v) for v in results["E"]["violations"])
            @test any(occursin("pi0 ablation_level at end", v) for v in results["E"]["violations"])
        end
    end
    if seq == "isolation"
        @testset "crash / timeout → UNKNOWN with cause; tree cleaned" begin
            @test oc("X") == "UNKNOWN" && cz("X") == "worker_crash"
            @test results["X"]["checks"]["error"]["stage"] == "action"
            @test oc("K") == "UNKNOWN" && cz("K") == "worker_crash"
            @test results["K"]["supervisor"]["termsignal"] == 6
            @test oc("V") == "UNKNOWN" && occursin("engine advanced", results["V"]["checks"]["error"]["message"])
            @test oc("H") == "UNKNOWN" && cz("H") == "wall_timeout"
            @test isfile(joinpath(root, "H", "hang_started"))
            @test results["H"]["supervisor"]["token_procs_at_kill"] >= 4
            @test results["H"]["supervisor"]["leftover"] == 0
        end
    end
end
