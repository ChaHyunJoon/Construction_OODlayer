# =============================================================================
# repair_rollout.jl — T4 단독 게이트(runtests.jl 미포함, ConstructionBots 를 로드하지 않는다; ≈1–2 분).
#
#   julia +lts --project=. test/repair_rollout.jl
#
# [1] OS 경계 능력표: 경계마다 음성 시험(샌드박스 안 금지 동작)과 양성 대조(밖에서는 됨). 못 막는 것은 못 막는다고
#     측정되고, 그래서 enforce 모드가 닫혀 있어야 한다(설계 §6.1).
# [2] worker env 는 상속하지 않고 세척된다.
# [3] trusted validator: worker 의 주장 대신 원본 contract 로 판정 · UNKNOWN 원인 · 계약 위반.
# [4] pi0 env 가 T3 드라이버(zrv_replay_episode.sh)와 같은 값이다.
# 에피소드 수준 격리·NOOP 동일성은 `test/repair_branch_isolation.jl`(수십 분)이 잰다.
# =============================================================================
using Test, JSON3
include(joinpath(@__DIR__, "..", "src", "verification", "branch_runner.jl"))
const BR = BranchRunner
const R = RepairTypes

scratch = mktempdir()

@testset "T4 rollout / sandbox / validator" begin
    @testset "[1] sandbox capabilities (negative tests + positive controls)" begin
        c = BR.sandbox_capabilities(joinpath(scratch, "cap"))
        caps = c["capabilities"]
        for k in ("host_write_outside_branch_dir", "read_foreign_proc_environ", "read_home_dotfiles",
                  "credential_env_scrubbed", "tcp_connect", "signal_outside_domain", "cpu_limit",
                  "memory_limit", "wall_timeout_kills_tree")
            haskey(caps, k) || continue            # read_home_dotfiles needs ~/.bashrc
            @test caps[k]["enforced"] === true
        end
        @test caps["tcp_connect"]["positive_control"] == 1               # the same connect works outside
        @test caps["wall_timeout_kills_tree"]["positive_control"] >= 3   # the tree existed before the kill
        # measured holes → enforce stays closed
        @test caps["udp_send"]["enforced"] === false
        @test caps["pathname_unix_socket_connect"]["enforced"] === false
        @test caps["same_process_runtime_override"]["enforced"] === false
        @test c["enforce_allowed"] === false
        @test Set(c["not_enforced"]) ⊇ Set(["udp_send", "same_process_runtime_override"])
    end

    @testset "[2] worker env: rebuilt, never inherited, credentials removed" begin
        ENV["ZRV_T4_FAKE_SECRET_TOKEN"] = "zrv-dummy"            # present in the supervisor
        env, removed = BR.worker_env(Dict("DEMO_SEED" => "3", "OPENAI_API_KEY" => "zrv-dummy", "DSPY_URL" => "http://x",
                                          "SOME_AUTH_HEADER" => "zrv-dummy"), Dict("ZRV_BRANCH_TOKEN" => "t"))
        @test !haskey(env, "ZRV_T4_FAKE_SECRET_TOKEN")
        @test !any(k -> haskey(env, k), ("OPENAI_API_KEY", "DSPY_URL", "SOME_AUTH_HEADER"))
        @test removed == ["DSPY_URL", "OPENAI_API_KEY", "SOME_AUTH_HEADER"]
        @test env["DEMO_SEED"] == "3" && env["ZRV_BRANCH_TOKEN"] == "t"
        @test Set(keys(env)) == Set(["HOME", "PATH", "USER", "LANG", "DEMO_SEED", "ZRV_BRANCH_TOKEN"])
        delete!(ENV, "ZRV_T4_FAKE_SECRET_TOKEN")
    end

    @testset "[3] trusted validator" begin
        contract = Dict{String,Any}("checkpoint_id" => "t0", "t0_iter" => 1,
            "sim_params" => Dict("max_time_steps" => 100000, "max_num_iters_no_progress" => 3000, "sim_batch_size" => 50),
            "required_ids" => ["PC1"],
            "pi0" => Dict("DEMO_POLICY" => "canonical", "DEMO_ROUTER" => "0", "REPAIR_ABLATION" => "all",
                          "ablation_level" => "all", "ablation_armed" => true))
        pi0 = Dict{String,Any}(contract["pi0"]..., "respec_hold" => false)
        ok_sup = (exitcode = 0, termsignal = 0, timed_out = false, leftover = 0, token_procs_at_kill = 1, wall_s = 10.0, cpu_s = 9.0)
        ledger_row(; zone = "NOOP nothing") = Dict("respec_history" => [
            Dict("input" => Dict("event" => "ZONE"), "chosen" => zone),
            Dict("input" => Dict("event" => "FAULT"), "chosen" => "Replace R1")],
            "recovery" => [Dict("action" => "reform", "status" => "recovered")])
        function term(; closed = ["PC1", "a"], complete = true, reason = "project_complete", iter = 900, np = 3,
                      sp = contract["sim_params"], pi0_end = pi0, blocks = String[], ladder = 0, methods = String[])
            Dict{String,Any}("complete" => complete, "terminal_reason" => reason, "iter" => iter, "no_progress" => np,
                "resume" => Dict("mismatched_blocks" => blocks, "dispatch_guard" => String[],
                                 "fingerprint_mismatches" => String[], "rvo_tie_watch" => Any[]),
                "branch" => Dict{String,Any}("schema" => BR.EXPORT_SCHEMA, "id" => "b", "checkpoint_id" => "t0",
                    "sim_params" => sp, "pi0_t0" => pi0, "pi0_end" => pi0_end,
                    "ablation_counts" => Dict("ladder_zone_fired" => ladder), "closed_node_ids" => closed,
                    "audit" => Dict("methods_changed_by_action" => methods)))
        end
        n = Ref(0)
        function case(; t = term(), err = nothing, sup = ok_sup, row = ledger_row())
            d = joinpath(scratch, "v$(n[] += 1)"); mkpath(d)
            t === nothing || BR._write(joinpath(d, "terminal.json"), t)
            err === nothing || BR._write(joinpath(d, "error.json"), err)
            row === nothing || write(joinpath(d, "shadow_MONITOR_IO.jsonl"), JSON3.write(Dict("respec_history" => [], "recovery" => [])) * "\n" * JSON3.write(row) * "\n")
            return BR.validate_branch(d, contract; branch_id = "b", sup)
        end
        v = case()
        @test v.report.outcome === :COMPLETE && v.report.terminal_reason === :project_complete
        @test v.report.sim_steps == 899
        @test v.report.general_recovery == Dict("decision:ZONE:NOOP" => 1, "decision:FAULT:Replace" => 1,
                                                "recovery:reform:recovered" => 1)
        # the worker's own claim is not used: required node not closed → not COMPLETE even if it says so
        v = case(t = term(closed = ["a"], complete = true, np = 3000))
        @test v.report.outcome === :FAIL_WITHIN_BUDGET && v.report.terminal_reason === :no_progress_limit
        @test v.checks["claim_agrees"] === false
        # and the reverse: says incomplete, but the original contract is met
        @test case(t = term(complete = false, reason = "no_progress_limit")).report.outcome === :COMPLETE
        @test case(t = term(closed = ["a"], complete = false, reason = "max_sim_steps", iter = 100000, np = 5)).report.terminal_reason === :max_sim_steps
        # UNKNOWN causes
        @test case(sup = merge(ok_sup, (timed_out = true, termsignal = 9, exitcode = 137))).report.unknown_cause === :wall_timeout
        @test case(t = nothing, sup = merge(ok_sup, (termsignal = 24, exitcode = 152))).report.unknown_cause === :resource_limit
        @test case(t = nothing, sup = merge(ok_sup, (termsignal = 9,))).report.unknown_cause === :resource_limit
        @test case(t = nothing, sup = merge(ok_sup, (termsignal = 6, exitcode = 134))).report.unknown_cause === :worker_crash
        @test case(t = nothing, sup = merge(ok_sup, (exitcode = 3,)), err = Dict("kind" => "identity_mismatch", "stage" => "restore")).report.unknown_cause === :identity_mismatch
        @test case(t = nothing, sup = merge(ok_sup, (exitcode = 3,)), err = Dict("kind" => "solver_error", "stage" => "continuation")).report.unknown_cause === :solver_error
        @test case(t = nothing, sup = merge(ok_sup, (exitcode = 3,)), err = Dict("kind" => "exception", "stage" => "action")).report.unknown_cause === :worker_crash
        @test case(t = nothing).report.unknown_cause === :worker_crash                      # exit 0 but no export
        @test case(t = term(blocks = ["native"])).report.unknown_cause === :identity_mismatch
        @test case(t = term(closed = ["a"], complete = false, reason = "none", np = 5)).report.unknown_cause === :worker_crash
        # contract violations: budget, horizon, pi0, zone decision, ladder, observed override
        viol(v) = (v.report.outcome === :UNKNOWN && v.report.unknown_cause === :contract_violation, v.violations)
        @test viol(case(t = term(sp = merge(contract["sim_params"], Dict("max_time_steps" => 200000)))))[1]
        @test viol(case(t = term(iter = 100001)))[1]
        @test viol(case(t = term(pi0_end = merge(pi0, Dict("REPAIR_ABLATION" => "none")))))[1]
        @test viol(case(t = term(pi0_end = merge(pi0, Dict("ablation_armed" => false)))))[1]
        @test viol(case(row = ledger_row(zone = "RelocateBuild x")))[1]
        @test viol(case(row = nothing))[1]
        @test viol(case(t = term(ladder = 1)))[1]
        @test viol(case(t = term(methods = ["ConstructionBots.project_complete"])))[1]
        tb = term(); tb["branch"]["id"] = "other"
        @test viol(case(t = tb))[1]
        # malformed export (worker 가 쓴 파일은 적대적 입력): 던지지 않고 UNKNOWN contract_violation
        function raw_case(text; sup = ok_sup, row = ledger_row(), ledger_text = nothing)
            d = joinpath(scratch, "v$(n[] += 1)"); mkpath(d)
            write(joinpath(d, "terminal.json"), text)
            ledger_text === nothing ? write(joinpath(d, "shadow_MONITOR_IO.jsonl"), JSON3.write(row) * "\n") :
                                      write(joinpath(d, "shadow_MONITOR_IO.jsonl"), ledger_text)
            return BR.validate_branch(d, contract; branch_id = "b", sup)
        end
        malformed(v) = v.report.outcome === :UNKNOWN && v.report.unknown_cause === :contract_violation &&
                       any(startswith("malformed export"), v.violations)
        @test malformed(raw_case("{not json"))                                  # invalid JSON
        @test malformed(raw_case("[1, 2, 3]"))                                  # non-object JSON
        @test malformed(raw_case(JSON3.write(Dict("iter" => "x"))))             # mistyped field
        t_bad = term(); t_bad["resume"] = "oops"
        @test malformed(raw_case(JSON3.write(t_bad)))                           # mistyped nested block
        t_bad = term(); t_bad["branch"]["sim_params"] = [1]
        @test malformed(raw_case(JSON3.write(t_bad)))
        t_bad = term(); t_bad["resume"] = Dict{String,Any}(t_bad["resume"]..., "mismatched_blocks" => "")  # "" passes isempty() untyped
        @test malformed(raw_case(JSON3.write(t_bad)))
        @test malformed(raw_case(JSON3.write(term()); ledger_text = "[]\n"))    # ledger row not an object
        @test malformed(raw_case(JSON3.write(term()); row = Dict("respec_history" => 5, "recovery" => [])))
        # supervisor-observed cause wins over a malformed export
        v = raw_case("{not json"; sup = merge(ok_sup, (timed_out = true, termsignal = 9)))
        @test v.report.unknown_cause === :wall_timeout
        # malformed error.json alone (crash) is still UNKNOWN, never a throw
        d = joinpath(scratch, "v$(n[] += 1)"); mkpath(d); write(joinpath(d, "error.json"), "nope")
        @test BR.validate_branch(d, contract; branch_id = "b", sup = merge(ok_sup, (exitcode = 3,))).report.outcome === :UNKNOWN
        # RolloutReport invariant: UNKNOWN ⟺ cause
        @test_throws ArgumentError R.RolloutReport("b", "t0", :UNKNOWN, nothing, :none, 0, 0.0, 0.0, 0, Dict{String,Int}())
    end

    @testset "[4] pi0 launch env == T3 driver" begin
        sh = read(joinpath(BR.ROOT, "tools", "monitor", "zrv_replay_episode.sh"), String)
        body = match(r"PI0=\(([^)]*)\)"s, sh).captures[1]
        kv = Dict(split(t, "=", limit = 2)[1] => split(t, "=", limit = 2)[2] for t in split(body))
        @test kv == BR.PI0
        e = BR.pi0_launch_env("tractor", "all3", 5)
        @test e["DEMO_OOD"] == "fault_battery" && e["DEMO_OOD_SEED"] == "5" && e["DEMO_CASE_TAG"] == "pi0_all3"
    end
end
