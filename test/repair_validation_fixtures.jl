# =============================================================================
# repair_validation_fixtures.jl — T10b 에피소드 게이트(단독 실행, runtests.jl 미포함; 한 판 ≈ 1–1.5 시간).
#
#   julia +lts --project=. test/repair_validation_fixtures.jl <model> <case> <seed> <outroot>   # 실행 + 단언
#   julia +lts --project=. test/repair_validation_fixtures.jl rejudge <outroot>                  # 저장된 분기로 재판정 + 단언
#
# 일반 ToolProposal 경로(`ToolExecution.execute_tool_isolated` — 제안 문 → 새 샌드박스 worker 등록·body·효과별 후처리 →
# 전체 continuation → 신뢰 판정)에 손으로 쓴 fixture(`test/fixtures/repair_verification/tools/validation_tools.jl`)를 넣는다.
#   · 고장 주입 13(정적 문 2 · 실행 감사 · OS 샌드박스 · 효과 · step 앞 계약 · 부분 적용 · 등록 메서드 잔존) — 전부 거절,
#     부모 t0 와 NOOP 궤적은 그대로.
#   · 합법 비기하 3 + 기하·배정 혼합 1 — 일반 경로가 받는다(effects accept · 후처리 통과 · post-enactment 계약 accept).
#     완주 여부는 측정값이다(받는 것 ≠ 완주) — `eligible == (COMPLETE ∧ terminal 계약 accept)` 로만 묶는다.
# 순서: 고장 → NOOP(N1) → 합법. 끝으로 부모 verify·디렉터리 digest 불변 → 부모 resume → N1 과 전 스텝 대조.
# `rejudge` 는 worker 를 다시 돌리지 않고 신뢰 판정만 다시 한다(판정 쪽 변이 측정용 — `T10B_VERIF_DIR` 로 다른
# `src/verification` 사본을 싣는다).
# =============================================================================
using Test, JSON3, SHA
const VDIR = get(ENV, "T10B_VERIF_DIR", joinpath(@__DIR__, "..", "src", "verification"))
include(joinpath(VDIR, "tool_execution.jl"))
include(joinpath(VDIR, "replay_compare.jl"))
include(joinpath(@__DIR__, "fixtures", "repair_verification", "tools", "validation_tools.jl"))
const BR = BranchRunner
const TX = ToolExecution
const RC = ReplayCompare
const LIM = BR.Limits(wall_s = 5400, cpu_s = 10800, mem_bytes = 24 * 2^30)
const FAULTS = ["f_override_static", "f_host_write_static", "f_partial", "f_zone_blink", "f_override_dynamic",
                "f_host_write_dynamic", "f_residue_a", "f_residue_b2", "f_residue_b1", "f_task_delete", "f_complete_forge",
                "f_resource_forge"]
const LEGIT = ["reassign", "temp_edge", "resource_job", "mixed"]
logln(x...) = (println("[t10b-fx ", Libc.strftime("%H:%M:%S", time()), "] ", x...); flush(stdout))

function jd(x)
    j = x.judged
    d = Dict{String,Any}("gate" => String(x.gate.verdict), "gate_reasons" => x.gate.reasons, "eligible" => x.eligible,
                         "reasons" => x.reasons)
    j === nothing && return merge(d, Dict{String,Any}("status" => "gate_rejected", "outcome" => nothing, "effects" => nothing,
                                                      "effect_classes" => String[], "checks_run" => String[], "exception" => nothing))
    merge(d, Dict{String,Any}("status" => String(j.enactment.status), "exception" => j.enactment.exception,
        "engine_steps" => j.enactment.sim_steps,
        "effects" => j.effects === nothing ? nothing : String(j.effects.verdict),
        "effect_reasons" => j.effects === nothing ? String[] : j.effects.reasons,
        "contract_post" => j.contract_post === nothing ? nothing : String(j.contract_post.verdict),
        "contract_post_reasons" => j.contract_post === nothing ? String[] : j.contract_post.reasons,
        "contract_terminal" => j.contract_terminal === nothing ? nothing : String(j.contract_terminal.verdict),
        "contract_terminal_reasons" => j.contract_terminal === nothing ? String[] : j.contract_terminal.reasons,
        "outcome" => j.rollout === nothing ? nothing : String(j.rollout.outcome),
        "terminal_reason" => j.rollout === nothing ? nothing : String(j.rollout.terminal_reason),
        "checks_run" => j.checks_run, "effect_classes" => j.effect_classes, "harness_log" => j.harness_log,
        "unobserved" => j.unobserved))
end

"저장된 분기 디렉터리로 `execute_tool_isolated` 결과 모양을 다시 만든다(worker 재실행 없음)."
function rejudge_one(root, id, parent_dir)
    raw = BR._json(joinpath(root, "proposals", id * ".json"))
    contract = BR._json(joinpath(parent_dir, "contract.json"))
    g = ToolProposalGate.gate_proposal(raw; checkpoint_id = String(contract["checkpoint_id"]),
                         ablation_level = Symbol(contract["pi0"]["REPAIR_ABLATION"]))
    g.report.verdict === :accept || return (; gate = g.report, judged = nothing, eligible = false, reasons = copy(g.report.reasons))
    dir = joinpath(root, id)
    sd = BR._json(joinpath(dir, "supervisor.json"))
    sup = (; (Symbol(k) => v for (k, v) in sd)...)
    v = BR.validate_branch(dir, contract; branch_id = id, sup)
    j = TX.judge_candidate(parent_dir, dir; rollout = v, proposal_file = joinpath(root, id * ".proposal.json"))
    return (; gate = g.report, judged = j, eligible = j.eligible, reasons = j.reasons)
end

has(xs, s) = any(x -> occursin(s, String(x)), xs)

rejudge = !isempty(ARGS) && ARGS[1] == "rejudge"
if rejudge
    root = abspath(ARGS[2])
    S = BR._json(joinpath(root, "t10b_fixtures.json"))
    pdir = joinpath(root, "parent")
    R = Dict{String,Any}(id => jd(rejudge_one(root, id, pdir)) for id in vcat(FAULTS, LEGIT))
    merge!(R, Dict(k => S["results"][k] for k in ("N1",)))
    logln("rejudged ", length(R) - 1, " candidates from saved branch dirs (verification code: ", VDIR, ")")
else
    model, case, seed, root = ARGS[1], ARGS[2], parse(Int, ARGS[3]), abspath(ARGS[4])
    mkpath(joinpath(root, "proposals"))
    env = BR.pi0_launch_env(model, case, seed)
    probe = joinpath(root, "HOST_WRITE_PROBE.txt")
    par = BR.start_parent(joinpath(root, "parent"), env)
    R = Dict{String,Any}(); verifies = Dict{String,Any}(); pterm = nothing; contract = nothing; pdir0 = pdir1 = nothing
    try
        held = BR.wait_held(par)
        global contract = BR._json(joinpath(par.dir, "contract.json"))
        cid = String(contract["checkpoint_id"])
        logln("parent held t0=", held["t0_iter"])
        global pdir0 = BR.dir_digest(par.dir)
        for id in vcat(FAULTS, ["N1"], LEGIT)
            if id == "N1"
                v = BR.run_branch(; parent_dir = par.dir, branch_id = "N1", outroot = root, launch_env = env, limits = LIM)
                R["N1"] = BR.report_dict(v)
            else
                raw = t10b_proposal(id, cid; probe_path = probe)
                BR._write(joinpath(root, "proposals", id * ".json"), raw)
                x = TX.execute_tool_isolated(; parent_dir = par.dir, raw, outroot = root, branch_id = id, launch_env = env, limits = LIM)
                R[id] = jd(x)
            end
            verifies[id] = BR.parent_command(par, "verify")
            logln(id, " → status=", get(R[id], "status", "-"), " gate=", get(R[id], "gate", "-"), " effects=", get(R[id], "effects", "-"),
                  " outcome=", get(R[id], "outcome", "-"), " eligible=", get(R[id], "eligible", "-"))
        end
        global pdir1 = BR.dir_digest(par.dir)
        verifies["resume"] = BR.parent_command(par, "resume")
        wait(par.process); close(par.log)
        global pterm = BR._json(joinpath(par.dir, "terminal.json"))
    finally
        process_running(par.process) && (try BR.parent_command(par, "exit") catch; end)
    end
    cmp = RC.compare_traces(joinpath(par.dir, "trace.tsv"), joinpath(root, "N1", "trace.tsv"); from_iter = contract["t0_iter"], ignore = ("rng",))
    S = Dict{String,Any}("episode" => "$(model)__$(case)__s$(seed)", "t0_iter" => contract["t0_iter"], "results" => R,
        "parent_verifies" => verifies, "parent_dir" => Dict("before" => pdir0, "after" => pdir1),
        "parent_terminal" => Dict(k => pterm[k] for k in ("complete", "terminal_reason", "closed", "iter")),
        "N1_vs_parent" => Dict(String(k) => v for (k, v) in pairs(cmp)), "host_write_probe_exists" => isfile(probe))
    BR._write(joinpath(root, "t10b_fixtures.json"), S)
end

st(id) = R[id]["status"]
insist(id) = (e = R[id]; vcat(e["gate_reasons"], something(e["exception"], ""), e["reasons"], get(e, "effect_reasons", String[])))
@testset "T10b validator fixtures on the general ToolProposal path ($(S["episode"]))$(rejudge ? " [rejudge]" : "")" begin
    @testset "parent stays at t0 through every candidate; NOOP after the faults = the original world" begin
        if !rejudge
            for (k, v) in S["parent_verifies"]
                k == "resume" && continue
                @test isempty(v["mismatched_blocks"]) && v["counters_equal"] === true && v["rng_equal"] === true
            end
            @test S["parent_dir"]["before"] == S["parent_dir"]["after"]
        end
        c = S["N1_vs_parent"]
        @test c["first_divergent_iter"] === nothing && c["only_a"] == 0 && c["only_b"] == 0 && c["n_common"] > 0
        @test R["N1"]["outcome"] == (S["parent_terminal"]["complete"] ? "COMPLETE" : "FAIL_WITHIN_BUDGET")
    end
    @testset "fault $(id) is rejected" for id in filter(!=("f_residue_b1"), FAULTS)
        t = T10B_TOOLS[id]
        @test R[id]["eligible"] === false
        if t.expect.layer == "gate"
            @test R[id]["gate"] == "reject" && has(R[id]["gate_reasons"], t.expect.reason)
            @test !isdir(joinpath(root, id))                                   # worker 를 띄우지 않았다
        elseif t.expect.layer == "enactment"
            @test st(id) in ("partial", "threw", "unobservable", "registration_rejected")
            @test has(insist(id), t.expect.reason) || st(id) == t.expect.reason
            @test !isfile(joinpath(root, id, "terminal.json"))                 # 폐기 — continuation 없음
        else   # effects: body 의 실제 diff 가 금지 효과 → 신뢰 효과 판정이 거절(worker 의 집행 상태와 무관하게 판정한다)
            @test R[id]["effects"] == "reject" && has(R[id]["effect_reasons"], t.expect.reason)
        end
    end
    @testset "host write never reached the host (static gate + OS sandbox)" begin
        rejudge || @test S["host_write_probe_exists"] === false
        @test has(insist("f_host_write_dynamic"), "denied") || has(insist("f_host_write_dynamic"), "ermission") ||
              has(insist("f_host_write_dynamic"), "SystemError")
    end
    @testset "registered-method residue: a same-name candidate runs in a fresh process" begin
        @test st("f_residue_a") == "unobservable" && has(insist("f_residue_a"), "zrv_t10b_residue_marker")
        @test st("f_residue_b1") == "enacted" && R["f_residue_b1"]["effects"] == "noop_equivalent"
        body = BR._json(joinpath(root, "f_residue_b1", "enactment.json"))["body"]
        @test any(s -> occursin("no zrv_t10b_residue_marker", String(s["detail"])), body["steps"])
        @test st("f_residue_b2") == "registration_rejected"
    end
    @testset "legitimate tool $(id) is accepted by the general path" for id in LEGIT
        t = T10B_TOOLS[id]
        @test R[id]["gate"] == "accept" && st(id) == "enacted"
        @test R[id]["effects"] == "accept" && R[id]["contract_post"] == "accept"
        @test issubset(t.expect.classes, R[id]["effect_classes"]) && isempty(intersect(t.expect.not_classes, R[id]["effect_classes"]))
        @test !any(r -> startswith(String(r), "postprocess_failed") || startswith(String(r), "unsupported"), R[id]["reasons"])
        # 완주는 측정값 — 기대값을 고정하지 않는다(항진 아님: 위의 accept 단언이 고정 기대다)
        @test R[id]["eligible"] == (R[id]["outcome"] == "COMPLETE" && R[id]["contract_terminal"] == "accept")
    end
    @testset "geometry is resynced only when the real diff has geometry" begin
        @test "scene_resync" in R["mixed"]["checks_run"]
        for id in ("reassign", "temp_edge", "resource_job")
            @test !("scene_resync" in R[id]["checks_run"]) &&
                  !any(l -> get(l, "action", "") == "resync_scene_to_schedule!", R[id]["harness_log"])
        end
    end
end
