# =============================================================================
# replay_repair_cohort.jl — T10b 역사적 body 사슬 재생(한 판). CB 를 싣지 않는다 — 생성/역사 코드는 worker 에서만 돈다.
#
#   julia +lts --project=. tools/monitor/replay_repair_cohort.jl <key> <outroot> [arms=GP,L0,L1] [campaign_dir]
#     <key> = legacy fixture 이름(예: tractor_zone_s5) — `test/fixtures/repair_verification/tools/legacy_chains.json`
#
# 한 판 = 원래 세계(부모, pi0)를 t0 에 세우고 같은 checkpoint 에서 분기들을 **순차로**:
#   L0  (arms 에 L0) 역사적 집행기 통제 재생 — 신뢰 action 파일이 집행된 body 를 원장 순서대로 production
#       `register_minted_primitive!` + `enact_minted!`(envelope = true: 역사적 집행기의 캐시 재개·공통 재풀이 봉투)로 부른다.
#       body 가 던져도 다음 body 로 간다(역사적 되먹임 사슬이 그랬다). 하니스 resync·효과 검사·후처리 **없음**.
#   L1  L0 와 같은 body·params·순서 + `resync_scene_to_schedule!(env)` 를 **각 body 의 enact_minted! 반환 직후**
#       (그 body 의 봉투 뒤, 다음 body/continuation 앞)에 한 번씩 — 차이는 그것뿐이다.
#   GP  일반 ToolProposal 경로(주 경로): 같은 body 원문을 ToolProposal 로 싸서 supervisor(`RepairSupervisor`)의
#       NOOP 기준 + 후보 rollout → 선택(§7.2). body 가 하나면 원문 그대로(원래 이름), 둘 이상이면 원문을 바이트 그대로
#       `let` 안에 둔 사슬 래퍼(`zrv_legacy_chain!`)가 원장 순서로 부른다(각 body 의 throw 는 역사적 집행기처럼 삼키고
#       기록 — 원문은 한 글자도 안 바꾼다). body 안의 `step_environment!` 는 trusted engine adapter 가 중재한다.
# 선택 뒤 원래 세계는 **재개하지 않고 은퇴**시킨다(비용 — NOOP 재개 replay 는 T7/T8 가 쟀다). noise floor 는 `true`(T10a 가
# 같은 빌드에서 순차=병렬·NOOP 두 분기 동일을 쟀다)로 넘긴다 — noop-b 를 안 돈다.
# 산출물: `<outroot>/episode.json`(schema `zrv-t10b-episode/1`), `<outroot>/{parent,branches,supervision,actions}/`.
# =============================================================================
using JSON3, SHA
include(joinpath(@__DIR__, "..", "..", "src", "verification", "repair_supervisor.jl"))
const S = RepairSupervisor
const BR = BranchRunner
const TX = ToolExecution
const TC = TaskContract

const FX = joinpath(BR.ROOT, "test", "fixtures", "repair_verification")
const CHAIN_IMPL = "zrv_legacy_chain!"
# 검증 재생 한도: sim 예산(max_time_steps·무진전 한도)은 부모 contract 그대로다. wall 은 하니스 한도일 뿐 simulated horizon 을
# 바꾸지 않는다(설계 §7.1) — 8 병렬 부하에서 X-wing FAIL 판이 production 3600 s 에 근접해(T10a §14-1) 5400 s 로 둔다.
const LIMITS = BR.Limits(wall_s = 5400, cpu_s = 10800, mem_bytes = 24 * 2^30)

_json(p) = BR._json(p)
_w(p, d) = BR._write(p, d)
logln(x...) = (println("[t10b ", Libc.strftime("%H:%M:%S", time()), "] ", x...); flush(stdout))

function body_code(b)
    code = read(joinpath(FX, b["file"]), String)
    bytes2hex(sha256(code)) == b["code_sha256"] || error("body file $(b["file"]) sha256 != legacy manifest")
    return code
end

"GP 제안: body 하나면 원문 그대로, 여럿이면 원문을 `let` 에 넣은 사슬 래퍼(원문 바이트 불변)."
function gp_proposal(key, E, cid)
    bs = E["bodies"]
    if length(bs) == 1
        nm, code = bs[1]["impl_name"], body_code(bs[1])
    else
        nm = CHAIN_IMPL
        defs = join(["    __zrv_f$(i) = let\n$(body_code(b))\n    end" for (i, b) in enumerate(bs)], "\n")
        fs = join(["__zrv_f$(i)" for i in eachindex(bs)], ", ")
        code = """
function $(nm)(env)
    __zrv_log = String[]
$(defs)
    for (__zrv_i, __zrv_f) in enumerate(($(fs),))
        try
            __zrv_out = __zrv_f(env)
            push!(__zrv_log, "body" * string(__zrv_i) * "=" * (hasproperty(__zrv_out, :status) ? string(__zrv_out.status) : "returned"))
        catch __zrv_e
            push!(__zrv_log, "body" * string(__zrv_i) * "=threw(" * first(split(sprint(showerror, __zrv_e), "\\n")) * ")")
        end
    end
    return (status = :chain_done, detail = join(__zrv_log, "; "))
end"""
    end
    return Dict{String,Any}("schema_version" => "tool-proposal/1", "checkpoint_id" => cid, "proposal_id" => "legacy-$(key)",
        "submission_index" => 1, "tool_name" => nm,
        "specification" => Dict{String,Any}("mechanism" => "historical A2 executed body chain (T10b replay fixture, not model output): " *
                                            join([b["record_id"] for b in bs], " -> ")),
        "impl_name" => nm, "impl_code" => code, "params" => Dict{String,Any}(),
        "calls" => [Dict{String,Any}("primitive" => nm, "args" => Dict{String,Any}())],
        "surface" => String(bs[1]["surface"]), "reversible" => all(b -> b["reversible"] === true, bs),
        "provenance" => Dict{String,Any}("source" => "fixture", "legacy" => key,
            "record_ids" => [b["record_id"] for b in bs], "code_sha256" => [b["code_sha256"] for b in bs],
            "wrapper" => length(bs) == 1 ? "none (original source)" : "chain wrapper: original sources byte-identical inside let blocks"))
end

"L0/L1 신뢰 action 파일(역사적 집행기 재생). body 원문은 파일 안에 문자열 리터럴로 싣는다(샌드박스가 이 파일만 읽게 한다)."
function action_file(path, E; resync::Bool, out::AbstractString)
    bs = E["bodies"]
    items = join(["    (name = $(repr(b["impl_name"])), code = $(repr(body_code(b))), surface = $(repr(String(b["surface"]))), " *
                  "reversible = $(b["reversible"] === true), n = $(b["n"]))" for b in bs], ",\n")
    write(path, """
# T10b generated trusted action (not a generated tool): historical executor replay, $(resync ? "L1 (+ resync after each body)" : "L0")
using ConstructionBots, JSON3
const CB = ConstructionBots
const BODIES = [
$(items)
]
const L1_RESYNC = $(resync)
const OUT = $(repr(out))
_a(s) = filter(isascii, string(s))
function branch_action!(env)
    lg = CB.ood_truth_log(); j = findlast(e -> e.truth isa CB.ZoneTruth, lg)
    truth = j === nothing ? nothing : lg[j].truth
    rec = Any[]; prev = nothing
    for (i, b) in enumerate(BODIES)
        why = CB.register_minted_primitive!(name = b.name, code = b.code, params = Dict{String,Any}(), surface = b.surface,
                                            reversible = b.reversible, allow_redefine = (prev == b.name))
        if why !== nothing
            push!(rec, Dict("body" => i, "registration" => _a(why))); continue
        end
        prev = b.name
        synth = Dict{String,Any}("impl_name" => b.name, "body_names" => [b.name], "impl_code" => b.code,
                                 "params" => Dict{String,Any}(), "surface" => b.surface,
                                 "calls" => [Dict{String,Any}("primitive" => b.name, "args" => Dict{String,Any}())])
        r = CB.enact_minted!(env, truth, synth)
        push!(rec, Dict("body" => i, "n" => b.n, "verdict" => string(r.verdict), "partial" => r.partial,
                        "resume" => string(r.resume), "resolve" => string(r.resolve),
                        "steps" => [_a(string(s.name, ":", s.status, isempty(string(s.detail)) ? "" : "(" * first(_a(s.detail), 160) * ")")) for s in r.steps]))
        if L1_RESYNC
            CB.resync_scene_to_schedule!(env)
            push!(rec, Dict("body" => i, "inserted" => "resync_scene_to_schedule!"))
        end
    end
    open(io -> JSON3.write(io, rec), OUT, "w")
    return "legacy chain replayed: " * join([string(get(x, "body", "?"), "=", get(x, "verdict", get(x, "registration", get(x, "inserted", "")))) for x in rec], ", ")[1:min(end, 400)]
end
""")
    return path
end

"L0/L1 판정: 등록된 body 이름만 메서드 변경으로 나온 것은 역사적 집행기의 등록 발자국이다(그 밖은 그대로 위반)."
function l_outcome(v, names)
    pre = "runtime methods changed by the action: "
    reg(m) = any(n -> m == "ConstructionBots.$(n)" || startswith(m, "ConstructionBots.#$(n)#"), names)
    other, footprint = String[], String[]
    for x in v.violations
        if startswith(x, pre)
            ms = split(x[length(pre)+1:end], ", ")
            append!(footprint, filter(reg, ms))
            bad = filter(!reg, ms)
            isempty(bad) || push!(other, pre * join(bad, ", "))
        else
            push!(other, x)
        end
    end
    tr = v.report.terminal_reason
    oc = if v.report.unknown_cause === nothing || (v.report.unknown_cause === :contract_violation && isempty(other))
        tr === :project_complete ? "COMPLETE" : tr in (:no_progress_limit, :max_sim_steps) ? "FAIL_WITHIN_BUDGET" : "UNKNOWN"
    else
        "UNKNOWN"
    end
    return (; outcome = oc, footprint, other)
end

term_facts(dir) = (p = joinpath(dir, "terminal.json"); isfile(p) ? (t = _json(p);
    Dict{String,Any}(k => get(t, k, nothing) for k in ("complete", "terminal_reason", "closed", "total", "iter", "no_progress", "n_blocked"))) : nothing)

function contract_terminal(C, dir)
    p = joinpath(dir, "terminal.json")
    isfile(p) || return nothing
    ts = try _json(p)["branch"]["task_state"] catch; nothing end
    ts === nothing && return nothing
    r = TC.evaluate_task_contract(C, ts; terminal = true)
    return Dict{String,Any}("violations" => r.violations, "unsupported" => r.unsupported, "notes" => r.notes)
end

jd(j) = j === nothing ? nothing : Dict{String,Any}(
    "status" => String(j.enactment.status), "exception" => j.enactment.exception, "engine_steps" => j.enactment.sim_steps,
    "effects" => j.effects === nothing ? nothing : String(j.effects.verdict),
    "effect_reasons" => j.effects === nothing ? nothing : j.effects.reasons,
    "contract_post" => j.contract_post === nothing ? nothing : String(j.contract_post.verdict),
    "contract_post_reasons" => j.contract_post === nothing ? nothing : j.contract_post.reasons,
    "contract_terminal" => j.contract_terminal === nothing ? nothing : String(j.contract_terminal.verdict),
    "contract_terminal_reasons" => j.contract_terminal === nothing ? nothing : j.contract_terminal.reasons,
    "outcome" => j.rollout === nothing ? nothing : String(j.rollout.outcome),
    "terminal_reason" => j.rollout === nothing ? nothing : String(j.rollout.terminal_reason),
    "eligible" => j.eligible, "precommit_ok" => j.precommit_ok, "reasons" => j.reasons, "checks_run" => j.checks_run,
    "effect_classes" => j.effect_classes, "harness_log" => j.harness_log, "notes" => j.notes, "unobserved" => j.unobserved,
    "body_changes" => j.enactment.body_changes, "harness_changes" => j.enactment.harness_changes)

function main(args)
    key, outroot = args[1], abspath(args[2])
    arms = length(args) >= 3 ? String.(split(args[3], ",")) : ["GP", "L0", "L1"]
    campaign = length(args) >= 4 ? abspath(args[4]) : outroot
    E = _json(joinpath(FX, "tools", "legacy_chains.json"))["episodes"][key]
    env = BR.pi0_launch_env(E["model"], E["case"], E["seed"])
    ispath(outroot) && error("outroot exists: $(outroot)")
    mkpath(joinpath(outroot, "actions")); mkpath(campaign)
    names = unique([b["impl_name"] for b in E["bodies"]])
    R = Dict{String,Any}("schema" => "zrv-t10b-episode/1", "key" => key, "group" => E["group"], "arms" => arms,
        "legacy" => Dict(k => E[k] for k in ("a2_class", "enact_retry", "historical_a2_status", "historical_a2_closed", "b0_outcome",
                                             "b0_closed", "b0_iter")),
        "bodies" => [Dict(k => b[k] for k in ("n", "role", "impl_name", "record_id", "code_sha256", "historical_steps")) for b in E["bodies"]],
        "limits" => Dict("wall_s" => LIMITS.wall_s, "cpu_s" => LIMITS.cpu_s, "mem_bytes" => LIMITS.mem_bytes),
        "started_at" => time())
    logln(key, " start arms=", arms)
    par = BR.start_parent(joinpath(outroot, "parent"), env)
    sv = nothing
    try
        held = BR.wait_held(par)
        contract = _json(joinpath(par.dir, "contract.json")); cid = String(contract["checkpoint_id"])
        C = _json(joinpath(par.dir, "task_contract.json"))
        R["t0_iter"] = held["t0_iter"]
        logln(key, " parent held t0=", held["t0_iter"])
        R["verifies"] = Dict{String,Any}()
        for arm in ("L0", "L1")
            arm in arms || continue
            af = action_file(joinpath(outroot, "actions", "$(arm).jl"), E; resync = arm == "L1",
                             out = joinpath(outroot, "branches", arm, "legacy_action.json"))
            v = BR.run_branch(; parent_dir = par.dir, branch_id = arm, outroot = joinpath(outroot, "branches"),
                              launch_env = env, limits = LIMITS, action_file = af)
            lo = l_outcome(v, names)
            la = joinpath(v.dir, "legacy_action.json")
            R[arm] = Dict{String,Any}("report" => BR.report_dict(v), "outcome" => lo.outcome, "registration_footprint" => lo.footprint,
                "other_violations" => lo.other, "terminal" => term_facts(v.dir), "contract_terminal" => contract_terminal(C, v.dir),
                "action" => isfile(la) ? JSON3.read(read(la, String)) : nothing, "action_file_sha256" => bytes2hex(sha256(read(af))),
                "error" => get(v.checks, "error", nothing))
            R["verifies"][arm] = BR.parent_command(par, "verify")
            tf = something(term_facts(v.dir), Dict{String,Any}())
            logln(key, " ", arm, " → ", lo.outcome, " closed=", get(tf, "closed", "-"), " other=", lo.other)
        end
        if "GPR" in arms
            # GP 재판정(T10b fix): 검증기(감사·효과 규칙)가 바뀐 뒤 **후보 worker 만** 다시 돈다. NOOP 기준은 같은 세계·같은 CB 빌드의
            # 앞선 런(`<campaign>/../cohort/<key>/episode.json` 의 noop — T10a B0 와 31/31 전 열 동일)을 쓴다; 선택은 supervisor 의
            # 순수 함수 `select_repair`(폐기 표시 포함)다. 부모 verify 로 t0 불변을 앞뒤로 확인한다.
            prev = _json(get(ENV, "T10B_PREV_EPISODE", ""))
            base = Symbol(prev["noop"]["report"]["outcome"])
            gp = gp_proposal(key, E, cid)
            R["GP_proposal"] = Dict("impl_name" => gp["impl_name"], "proposal_sha256" => TC.digest(gp), "wrapper" => gp["provenance"]["wrapper"])
            v0 = BR.parent_command(par, "verify")
            x = TX.execute_tool_isolated(; parent_dir = par.dir, raw = gp, outroot = joinpath(outroot, "supervision"),
                                         branch_id = "cand-1", launch_env = env, limits = LIMITS, mode = "full")
            v1 = BR.parent_command(par, "verify")
            gaps = vcat(S.checkpoint_gaps(contract, par.dir), S.identity_gaps(v0), S.identity_gaps(v1))
            disc = x.judged !== nothing && x.judged.enactment.status in S.DISCARDED_ENACTMENTS
            c = (; proposal_id = gp["proposal_id"], submission_index = 1,
                 outcome = x.run === nothing ? nothing : x.run.report.outcome, eligible = x.eligible, discarded = disc)
            sel = S.select_repair(cid, base, [c]; gaps, baseline_note = "baseline = previous run's NOOP branch (same world, same CB build)")
            R["supervision"] = Dict{String,Any}("selection" => S.selection_dict(sel), "gaps" => gaps, "transitions" => Any[],
                "baseline_from" => get(ENV, "T10B_PREV_EPISODE", ""))
            R["GP"] = Dict{String,Any}("judged" => jd(x.judged), "gate" => String(x.gate.verdict), "gate_reasons" => x.gate.reasons,
                "candidate_outcome" => String(sel.candidate_outcomes[gp["proposal_id"]]),
                "terminal" => x.run === nothing ? nothing : term_facts(x.run.dir), "reasons" => x.reasons)
            R["noop"] = prev["noop"]
            logln(key, " GPR → ", R["GP"]["candidate_outcome"], " selection=", sel.classification, " selected=", sel.selected, " base=", base)
        end
        if "GP" in arms
            gp = gp_proposal(key, E, cid)
            R["GP_proposal"] = Dict("impl_name" => gp["impl_name"], "proposal_sha256" => TC.digest(gp), "wrapper" => gp["provenance"]["wrapper"])
            sv = S.Supervision(par; outroot = joinpath(outroot, "supervision"), launch_env = env, limits = LIMITS, campaign_dir = campaign)
            S.verify_identity!(sv; noise_floor = true)
            S.freeze!(sv, [gp])
            sv.state === :PROPOSALS_FROZEN && S.rollouts!(sv; noise_floor = true)
            S.select!(sv)
            S.shadow_fork!(sv)
            R["supervision"] = S.summary(sv)
            c = get(sv.candidates, gp["proposal_id"], nothing)
            R["GP"] = c === nothing ? nothing : Dict{String,Any}("judged" => jd(c.exec === nothing ? nothing : c.exec.judged),
                "gate" => c.exec === nothing ? nothing : String(c.exec.gate.verdict),
                "gate_reasons" => c.exec === nothing ? String[] : c.exec.gate.reasons,
                "candidate_outcome" => get(sv.selection.candidate_outcomes, gp["proposal_id"], nothing) |> x -> x === nothing ? nothing : String(x),
                "terminal" => c.dir === nothing ? nothing : term_facts(c.dir), "reasons" => c.reasons)
            R["noop"] = sv.baseline === nothing ? nothing : Dict{String,Any}("report" => BR.report_dict(sv.baseline),
                "terminal" => term_facts(sv.baseline.dir), "contract_terminal" => contract_terminal(C, sv.baseline.dir))
            logln(key, " GP → ", R["GP"] === nothing ? "-" : R["GP"]["candidate_outcome"], " selection=", sv.selection.classification,
                  " selected=", sv.selection.selected, " noop=", sv.baseline === nothing ? "-" : sv.baseline.report.outcome)
        end
    catch e
        R["driver_error"] = first(sprint(showerror, e, catch_backtrace()), 3000)
        logln(key, " DRIVER ERROR ", first(sprint(showerror, e), 300))
    finally
        if sv !== nothing
            try S.retire!(sv) catch; end
        elseif process_running(par.process)
            try BR.parent_command(par, "exit") catch; end
        end
        try BR.kill_tree!(par.process, par.token) catch; end
        R["finished_at"] = time()
        _w(joinpath(outroot, "episode.json"), R)
    end
    logln(key, " done")
    return haskey(R, "driver_error") ? 3 : 0
end

(abspath(PROGRAM_FILE) == @__FILE__) && exit(main(ARGS))
