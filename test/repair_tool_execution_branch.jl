# =============================================================================
# repair_tool_execution_branch.jl — T6 에피소드 수준 게이트(단독 실행, runtests.jl 미포함; 한 판 ≈ 30–40 분).
#
#   julia +lts --project=. test/repair_tool_execution_branch.jl <model> <case> <seed> <outroot>
#
# T4 부모/분기 경로 그대로(부모 = 원래 세계, t0 에서 tick 없이 대기, 생성 코드 0). 후보마다 **새 샌드박스 worker**
# (`ToolExecution.execute_tool_isolated` → `BranchRunner.run_branch(…; proposal_file)`)에서 fixture 도구 source 를
# production 등록(Core.eval) → body → 효과별 후처리 → (full) continuation 한다. 순서(순차, 한 디렉터리):
#   P1  preflight — step 을 부르는 도구: 첫 step 직전에 멈춘다(requires_runtime, 피드백 가능)
#   X1  첫 상태 변경 뒤 throw   X2 일부 API 성공 후 실패   X3 후처리 실패(ZRV_PROBE_POSTPROCESS_FAIL) — 셋 다 폐기
#   N1  NOOP 분기(폐기 셋 **뒤**) — 부모 재개 궤적과 t0 이후 전 스텝 같아야 한다
#   S1  full — 도구 안에서 3 step(trusted adapter) 후 continuation: 궤적이 N1·부모와 **전 스텝** 같아야 한다
#   G1  기하(resync 를 잊은 빌드 강체 이동)   A1 비기하(스페어 인계)   M1 혼합 — 실제로 돈 검사를 단언
# 끝으로 부모 verify(카운터·블록·RNG 불변)·부모 디렉터리 digest 불변 → 부모 resume → 궤적 비교.
# =============================================================================
using Test, JSON3, SHA
include(joinpath(@__DIR__, "..", "src", "verification", "tool_execution.jl"))
include(joinpath(@__DIR__, "..", "src", "verification", "replay_compare.jl"))
include(joinpath(@__DIR__, "fixtures", "repair_verification", "t6_tool_sources.jl"))
const BR = BranchRunner
const TX = ToolExecution
const RC = ReplayCompare

model, case, seed, root = ARGS[1], ARGS[2], parse(Int, ARGS[3]), abspath(ARGS[4])
mkpath(root)
env = BR.pi0_launch_env(model, case, seed)
LIM = BR.Limits(wall_s = 3600, cpu_s = 7200, mem_bytes = 24 * 2^30)
log(x...) = (println("[t6 ", Libc.strftime("%H:%M:%S", time()), "] ", x...); flush(stdout))

function prop(key, id, cid)
    nm = "t6_$(key)_$(id)!"
    code = replace(T6_TOOL_SOURCES[key], r"function t6_\w+!" => "function $(nm)", count = 1)
    return Dict{String,Any}("schema_version" => "tool-proposal/1", "checkpoint_id" => cid, "proposal_id" => "p-$(id)",
        "submission_index" => 1, "tool_name" => nm, "specification" => Dict("mechanism" => "t6 fixture $(key)"),
        "impl_name" => nm, "impl_code" => code, "params" => Dict{String,Any}(),
        "calls" => [Dict{String,Any}("primitive" => nm, "args" => Dict{String,Any}())])
end
jd(j) = j === nothing ? nothing : Dict{String,Any}(
    "status" => String(j.enactment.status), "exception" => j.enactment.exception, "engine_steps" => j.enactment.sim_steps,
    "effects" => j.effects === nothing ? nothing : String(j.effects.verdict),
    "effect_reasons" => j.effects === nothing ? nothing : j.effects.reasons,
    "contract_post" => j.contract_post === nothing ? nothing : String(j.contract_post.verdict),
    "contract_terminal" => j.contract_terminal === nothing ? nothing : String(j.contract_terminal.verdict),
    "outcome" => j.rollout === nothing ? nothing : String(j.rollout.outcome),
    "terminal_reason" => j.rollout === nothing ? nothing : String(j.rollout.terminal_reason),
    "eligible" => j.eligible, "reasons" => j.reasons, "checks_run" => j.checks_run,
    "validator_adapters" => j.validator_adapters, "effect_classes" => j.effect_classes, "harness_log" => j.harness_log,
    "body_changes" => j.enactment.body_changes, "harness_changes" => j.enactment.harness_changes,
    "notes" => j.notes, "feedback_allowed" => j.feedback_allowed, "unobserved" => j.unobserved)

par = BR.start_parent(joinpath(root, "parent"), env)
R = Dict{String,Any}(); verifies = Dict{String,Any}()
pterm = nothing; contract = nothing; pdir0 = pdir1 = nothing
try
    held = BR.wait_held(par)
    global contract = BR._json(joinpath(par.dir, "contract.json"))
    cid = String(contract["checkpoint_id"])
    log("parent held at t0 iter=", held["t0_iter"], " batch_pos=", contract["batch_pos"], " task_contract=", haskey(contract["task_contract"], "path"))
    global pdir0 = BR.dir_digest(par.dir)
    function cand!(id, key; mode = "full", extra = Dict{String,String}())
        log("candidate ", id, " (", key, ", ", mode, ")")
        x = TX.execute_tool_isolated(; parent_dir = par.dir, raw = prop(key, id, cid), outroot = root, branch_id = id,
                                     launch_env = env, limits = LIM, mode, extra_env = extra)
        R[id] = something(jd(x.judged), Dict{String,Any}("status" => "gate_rejected", "reasons" => x.reasons,
                                                         "outcome" => nothing, "eligible" => false, "checks_run" => String[],
                                                         "effect_classes" => String[], "exception" => nothing))
        R[id]["gate"] = String(x.gate.verdict)
        x.run === nothing || (R[id]["rollout_violations"] = x.run.violations)
        verifies[id] = BR.parent_command(par, "verify")
        BR._write(joinpath(root, id * ".t6_judged.json"), R[id])
        log("  → ", R[id]["status"], " outcome=", R[id]["outcome"], " eligible=", R[id]["eligible"], " checks=", R[id]["checks_run"],
            " classes=", R[id]["effect_classes"], " exc=", R[id]["exception"], " parent_verify_ok=",
            isempty(verifies[id]["mismatched_blocks"]) && verifies[id]["counters_equal"])
    end
    cand!("P1", "step3"; mode = "preflight")
    cand!("X1", "shift_throw")
    cand!("X2", "api_then_fail")
    cand!("X3", "shift"; extra = Dict("ZRV_PROBE_POSTPROCESS_FAIL" => "1"))
    log("branch N1 (noop)")
    v = BR.run_branch(; parent_dir = par.dir, branch_id = "N1", outroot = root, launch_env = env, limits = LIM)
    R["N1"] = BR.report_dict(v); verifies["N1"] = BR.parent_command(par, "verify")
    log("  → ", R["N1"]["outcome"], " steps=", R["N1"]["sim_steps"])
    cand!("S1", "step3")
    cand!("G1", "shift")
    cand!("A1", "replace")
    cand!("M1", "mixed")
    global pdir1 = BR.dir_digest(par.dir)
    fin = BR.parent_command(par, "resume"); verifies["resume"] = fin
    wait(par.process); close(par.log)
    global pterm = BR._json(joinpath(par.dir, "terminal.json"))
    log("parent terminal complete=", pterm["complete"], " iter=", pterm["iter"])
finally
    process_running(par.process) && (try BR.parent_command(par, "exit") catch; end)
end

t0 = contract["t0_iter"]
tr(d) = joinpath(d, "trace.tsv")
cmp(a, b) = RC.compare_traces(tr(a), tr(b); from_iter = t0, ignore = ("rng",))
eq(c) = c.first_divergent_iter === nothing && c.only_a == 0 && c.only_b == 0 && c.n_common > 0
S = Dict{String,Any}("episode" => "$(model)__$(case)__s$(seed)", "t0_iter" => t0, "results" => R, "parent_verifies" => verifies,
    "parent_dir" => Dict("before" => pdir0, "after" => pdir1),
    "parent_terminal" => Dict(k => pterm[k] for k in ("complete", "terminal_reason", "closed", "iter")),
    "N1_vs_parent" => cmp(par.dir, joinpath(root, "N1")), "S1_vs_parent" => cmp(par.dir, joinpath(root, "S1")),
    "S1_vs_N1" => cmp(joinpath(root, "N1"), joinpath(root, "S1")))
BR._write(joinpath(root, "t6_summary.json"), S)
log("N1_vs_parent=", S["N1_vs_parent"], " S1_vs_parent=", S["S1_vs_parent"])

st(id) = R[id]["status"]
@testset "T6 tool execution on branch workers ($(model) $(case) s$(seed))" begin
    @testset "parent stays at t0 through every candidate (incl. discarded ones)" begin
        for (k, v) in verifies
            k == "resume" && (@test v["counters_equal"] === true; continue)
            @test isempty(v["mismatched_blocks"]) && v["counters_equal"] === true && v["rng_equal"] === true
        end
        @test pdir0 == pdir1 && pdir0.n_files > 5
    end
    @testset "preflight stops right before the first engine step" begin
        @test st("P1") == "requires_runtime" && R["P1"]["engine_steps"] == 0 && R["P1"]["feedback_allowed"] === true
        @test R["P1"]["effects"] == "requires_runtime" && R["P1"]["outcome"] === nothing
        @test !isfile(joinpath(root, "P1", "terminal.json"))                  # continuation 없음
    end
    @testset "throw / partial API / postprocess failure → worker discarded, NOOP trajectory unchanged" begin
        @test st("X1") == "partial" && occursin("boom after moving", R["X1"]["exception"])
        @test st("X2") == "partial"
        @test st("X3") == "partial" && occursin("postprocess_failed", R["X3"]["exception"])
        @test any(l -> l["action"] == "resync_scene_to_schedule!", R["X3"]["harness_log"])   # 하니스가 이미 바꾼 뒤였다
        for id in ("X1", "X2", "X3")
            @test R[id]["eligible"] === false && !isfile(joinpath(root, id, "terminal.json"))
        end
        @test eq(S["N1_vs_parent"]) && R["N1"]["outcome"] == (pterm["complete"] ? "COMPLETE" : "FAIL_WITHIN_BUDGET")
    end
    @testset "tool-internal steps go through the trusted adapter: same trajectory as the production loop" begin
        @test st("S1") == "enacted" && R["S1"]["engine_steps"] == 3 && R["S1"]["effects"] == "accept"
        @test eq(S["S1_vs_parent"]) && eq(S["S1_vs_N1"])
        # 도구 안 step 동안 pi0 가 존 사건을 처리하며 바꾼 보호 전역(사건 큐 등)은 engine 구간에 적히고 도구 탓이 아니다
        au = BR._json(joinpath(root, "S1", "enactment.json"))["audit"]
        @test "globals.ConstructionBots.RESPEC_QUEUE" in au["fields_changed_by_engine"] &&
              !("globals.ConstructionBots.RESPEC_QUEUE" in au["fields_changed_by_action"])
        @test R["S1"]["outcome"] == R["N1"]["outcome"] && isempty(R["S1"]["rollout_violations"])
    end
    @testset "effect-specific checks actually ran" begin
        @test st("G1") == "enacted" && "geometry" in R["G1"]["effect_classes"]
        @test issubset(["scene_resync", "geometry_residual", "cache_resume"], R["G1"]["checks_run"])
        @test any(l -> l["action"] == "resync_scene_to_schedule!" && l["by"] == "harness", R["G1"]["harness_log"])
        @test st("A1") == "enacted" && "assignment" in R["A1"]["effect_classes"] && !("geometry" in R["A1"]["effect_classes"])
        @test issubset(["assignment_availability", "assignment_completeness", "cache_resume"], R["A1"]["checks_run"])
        @test !("scene_resync" in R["A1"]["checks_run"]) && !any(l -> l["action"] == "resync_scene_to_schedule!", R["A1"]["harness_log"])
        @test st("M1") == "enacted" && issubset(["geometry", "assignment"], R["M1"]["effect_classes"])
        @test issubset(["scene_resync", "geometry_residual", "assignment_availability", "assignment_completeness"], R["M1"]["checks_run"])
        # 판정은 실제 결과대로 — COMPLETE 이면 계약까지 통과해야 eligible, 아니면 eligible 아님(항진 아님: 기대값을 고정하지 않는다)
        for id in ("S1", "G1", "A1", "M1")
            @test R[id]["eligible"] == (R[id]["outcome"] == "COMPLETE" && R[id]["contract_terminal"] == "accept" &&
                                        R[id]["contract_post"] == "accept" && R[id]["effects"] in ("accept", "noop_equivalent") &&
                                        isempty(R[id]["rollout_violations"]))
        end
    end
end
