# =============================================================================
# repair_task_contract_branch.jl — T5 원본 작업 계약의 에피소드 수준 확인(단독 실행, runtests.jl 미포함; 한 판 ≈10 분).
#
#   julia +lts --project=. test/repair_task_contract_branch.jl <model> <case> <seed> <outroot>
#
# T4 의 부모/분기 경로 그대로: 부모(생성 코드 0)가 t0 에서 `task_contract.json` 을 쓰고 멈춘다. 분기 N1(NOOP)과
# G1(goal=start 를 심은 신뢰 시험 동작)을 새 프로세스에서 끝까지 굴린 뒤, **CB 를 싣지 않은 이 프로세스**가 분기
# terminal export 의 `task_state` 를 부모 계약으로 재판정한다. N1 은 통과해야 하고(음성 대조), G1 은 운반 생략으로
# 떨어져야 한다 — 종료 결과(COMPLETE 여부)와 무관하게.
# =============================================================================
using Test, JSON3
include(joinpath(@__DIR__, "..", "src", "verification", "branch_runner.jl"))
include(joinpath(@__DIR__, "..", "src", "verification", "task_contract.jl"))
const BR = BranchRunner
const TC = TaskContract

model, case, seed, root = ARGS[1], ARGS[2], parse(Int, ARGS[3]), abspath(ARGS[4])
mkpath(root)
env = BR.pi0_launch_env(model, case, seed)
LIM = BR.Limits(wall_s = 3600, cpu_s = 7200, mem_bytes = 24 * 2^30)
log(x...) = (println("[t5 ", Libc.strftime("%H:%M:%S", time()), "] ", x...); flush(stdout))

par = BR.start_parent(joinpath(root, "parent"), env)
@testset "T5 task contract on T4 branches ($(model) $(case) s$(seed))" begin
    try
        BR.wait_held(par)
        contract = BR._json(joinpath(par.dir, "contract.json"))
        tci = contract["task_contract"]
        log("parent task_contract: ", tci)
        @test haskey(tci, "path")
        C = BR._json(tci["path"])
        @test bytes2hex(BR.SHA.sha256(read(tci["path"]))) == tci["sha256"]
        @test Set(contract["required_ids"]) ⊆ Set(keys(C["required_nodes"]))     # T4 완료 조건 ⊆ 원본 필수 작업
        log("contract: required=", length(C["required_nodes"]), " semantic=", length(C["semantic_edges"]),
            " chains=", length(C["transport_chains"]), " closed_at_t0=", length(C["closed_at_t0"]), " zones=", collect(keys(C["zones"])))
        out = Dict{String,Any}()
        for (id, action) in (("N1", ""), ("G1", joinpath(@__DIR__, "fixtures", "repair_verification", "branch_actions", "goal_to_start.jl")))
            v = BR.run_branch(; parent_dir = par.dir, branch_id = id, outroot = root, launch_env = env, limits = LIM, action_file = action)
            term = BR._json(joinpath(root, id, "terminal.json"))
            r = TC.evaluate_task_contract(C, term["branch"]["task_state"]; terminal = true)
            out[id] = Dict("outcome" => String(v.report.outcome), "terminal_reason" => String(v.report.terminal_reason),
                           "steps" => v.report.sim_steps, "branch_violations" => v.violations,
                           "contract_violations" => r.violations, "contract_unsupported" => r.unsupported,
                           "action_returned" => get(term["branch"]["action"], "returned", nothing))
            log(id, " → ", out[id])
        end
        BR._write(joinpath(root, "t5_contract_results.json"), out)
        @test out["N1"]["outcome"] == "COMPLETE"
        @test isempty(out["N1"]["contract_violations"]) && isempty(out["N1"]["contract_unsupported"])
        @test any(v -> startswith(v, "transport_skipped:"), out["G1"]["contract_violations"])
    finally
        try BR.parent_command(par, "exit") catch; end
    end
end
