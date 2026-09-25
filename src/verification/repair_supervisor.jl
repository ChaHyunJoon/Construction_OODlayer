# =============================================================================
# repair_supervisor.jl — 선택기 · certificate · commit worker 전환 (T7). 설계 §7.2·§7.3.
#
# 🔴 이 모듈은 ConstructionBots 를 **로드하지 않고 생성 코드를 한 줄도 eval 하지 않는다**. 입력은 부모(t0 에서 멈춘
#    원래 세계)가 쓴 contract/task_contract 파일, worker 가 쓴 고정 code-free export(enactment·effect_trace·terminal),
#    그리고 supervisor 자신이 쓴 제안 파일뿐이다.
#
# 상태 기계(`STATES`·`TRANSITIONS` — 이 파일이 단일 진실원):
#   CAPTURED → IDENTITY_VERIFIED → PROPOSALS_FROZEN → BASELINE_AND_CANDIDATE_ROLLOUTS
#            → SELECTED_NOOP | SELECTED_TOOL → PRECOMMIT_VERIFIED → COMMITTED → REPLAY_CHECKED
#   검증 오류 → REJECT_CANDIDATE(선택된 도구의 commit 실패 → NOOP 로) 또는 CERTIFICATION_UNAVAILABLE(→ NOOP).
#
# 선택(`select_repair`, 순수 함수): 설계 §7.2 표. 여러 후보가 통과하면 **최초 제출 순서**(submission_index, 동률이면
#   입력 순서). 기하 이동량·config 수로 순위를 매기지 않는다 — 그런 값은 이 함수의 입력에 없다.
#
# commit(`commit_tool!`): 원래 worker(부모)는 t0 에서 그대로 기다린다. **새** commit worker 가 같은 checkpoint 에서
#   certificate 가 묶은 **같은** 제안 파일을 검증과 같은 경로(`ToolExecution.execute_tool_isolated`, mode "commit")로
#   다시 등록·집행하고 t1 에서 멈춘다. supervisor 가 (a) trusted 판정(`judge_candidate(...).precommit_ok` — 효과·후처리·
#   post-enactment 계약·신원 교차검사)과 (b) 검증 분기 enactment 와의 대조(`compare_enactments`)를 둘 다 통과할 때만
#   `activate` 를 보내고 부모를 은퇴시킨다. 하나라도 어긋나면 commit worker 를 버리고(`exit`·프로세스 트리 kill) 손대지
#   않은 부모에서 NOOP 로 재개한다. 새 함수 정의를 부모에서 undo 하려 하지 않는다(부모는 생성 코드를 본 적이 없다).
#   shadow 의 terminal 상태를 복사하지 않고 미래 simulated time 을 건너뛰지 않는다 — 활성 worker 는 t1 부터 실제로 굴린다.
#   활성화 뒤 그 worker 의 궤적·종료를 검증 분기와 대조(`replay_compare`)하고, 어긋나면 보장 위반으로 기록하고 campaign
#   인증을 멈춘다(`stop_certification!` — 이후 `verify_identity!` 가 인증 불가로 돈다).
#
# 🔴 enforce 는 여전히 닫혀 있다(T4 `sandbox_capabilities(...)["enforce_allowed"] == false`). 이 파일은 commit/활성화를
#    구현하고 시험하지만 production enforce 의 문은 T8 이 그 값을 보고 연다.
# =============================================================================
isdefined(Main, :ToolExecution) || include(joinpath(@__DIR__, "tool_execution.jl"))
isdefined(Main, :ReplayCompare) || include(joinpath(@__DIR__, "replay_compare.jl"))

module RepairSupervisor

using JSON3, SHA
import ..RepairTypes as R
import ..TaskContract as TC
import ..EffectValidation as EV
import ..ToolProposalGate as PG
import ..BranchRunner as BR
import ..ToolExecution as TX
import ..ReplayCompare as RC

const SUPERVISOR_VERSION = "repair-supervisor/1"
const CERTIFICATE_SCHEMA = "repair-certificate/1"
const ACTIVE_WORLD_SCHEMA = "active-world/1"
const STOP_FILE = "CERTIFICATION_STOPPED.json"
"부모 capture 가 T5 이전 문구로 남기는 gap. 부모가 t0 에서 유도한 `task_contract.json` 의 digest 가 맞으면 해소된다."
const TASK_CONTRACT_GAP = "task_world: original task contract not supplied"

_json(p) = JSON3.read(read(p, String), Dict{String,Any})
_write(p, d) = open(io -> JSON3.pretty(io, JSON3.write(d)), p, "w")
_fsha(p) = isfile(p) ? bytes2hex(sha256(read(p))) : nothing
"파일에 쓰였다 다시 읽힌 모양(JSON 왕복)의 digest — worker 가 읽은 제안의 `proposal_sha256` 과 같은 값이 된다."
_rt_digest(x) = TC.digest(JSON3.read(JSON3.write(x), Dict{String,Any}))

# =============================================================================
# 상태 기계
# =============================================================================
const STATES = (:CAPTURED, :IDENTITY_VERIFIED, :PROPOSALS_FROZEN, :BASELINE_AND_CANDIDATE_ROLLOUTS,
                :SELECTED_NOOP, :SELECTED_TOOL, :PRECOMMIT_VERIFIED, :COMMITTED, :REPLAY_CHECKED,
                :REJECT_CANDIDATE, :CERTIFICATION_UNAVAILABLE)
"""
허용 전이. NOOP 도 PRECOMMIT_VERIFIED(부모 t0 재확인) → COMMITTED(부모 재개) → REPLAY_CHECKED 를 탄다.
`SELECTED_NOOP → COMMITTED` 직행은 인증 불가일 때뿐(확인할 보장이 없다 — 그래도 원래 세계는 재개한다).
"""
const TRANSITIONS = Dict{Symbol,Tuple}(
    :CAPTURED => (:IDENTITY_VERIFIED, :CERTIFICATION_UNAVAILABLE),
    :IDENTITY_VERIFIED => (:PROPOSALS_FROZEN,),
    :PROPOSALS_FROZEN => (:BASELINE_AND_CANDIDATE_ROLLOUTS,),
    :BASELINE_AND_CANDIDATE_ROLLOUTS => (:SELECTED_NOOP, :SELECTED_TOOL, :CERTIFICATION_UNAVAILABLE),
    :CERTIFICATION_UNAVAILABLE => (:SELECTED_NOOP,),
    :SELECTED_NOOP => (:PRECOMMIT_VERIFIED, :COMMITTED),
    :SELECTED_TOOL => (:PRECOMMIT_VERIFIED, :REJECT_CANDIDATE),
    :PRECOMMIT_VERIFIED => (:COMMITTED, :REJECT_CANDIDATE),
    :REJECT_CANDIDATE => (:SELECTED_NOOP,),
    :COMMITTED => (:REPLAY_CHECKED,),
    :REPLAY_CHECKED => ())

"`from → to` 가 허용이면 `to`, 아니면 ArgumentError."
function transition(from::Symbol, to::Symbol)
    to in get(TRANSITIONS, from, ()) || throw(ArgumentError("illegal supervisor transition $(from) → $(to)"))
    return to
end

# =============================================================================
# 선택 (순수)
# =============================================================================
"""
    candidate_outcome(c) -> Symbol ∈ RepairTypes.CANDIDATE_OUTCOMES

`c` = `(; proposal_id, submission_index, outcome, eligible)` — `outcome` 은 rollout 결과(`nothing` = rollout 없음:
제안 문 거절·폐기), `eligible` = `judge_candidate(...).eligible`(+ supervisor 의 native·제안 파일 확인).
eligible 인데 rollout 이 COMPLETE 가 아니면 입력이 모순이다(던진다).
"""
function candidate_outcome(c)
    if c.eligible
        c.outcome === :COMPLETE || throw(ArgumentError("candidate $(c.proposal_id) eligible without a COMPLETE rollout"))
        return :COMPLETE
    end
    c.outcome in (:FAIL_WITHIN_BUDGET, :UNKNOWN) && return c.outcome
    return :REJECTED            # rollout 없음, 또는 COMPLETE 인데 효과/계약/신원 검사에서 떨어짐
end

"""
    select_repair(checkpoint_id, baseline::Symbol, candidates; gaps = String[], baseline_note = "") -> SelectionReport

설계 §7.2 표(pure function):

| 기준(NOOP) | 후보 | 선택 |
|---|---|---|
| COMPLETE | 무엇이든 | NOOP (`:baseline_complete`; 실패·거절 후보는 `raw_regressions`) |
| FAIL_WITHIN_BUDGET | COMPLETE + 원본 계약 통과(`eligible`) | TOOL (`:rescued`) — 최초 제출 순서의 첫 후보 |
| FAIL_WITHIN_BUDGET | 실패·거절·UNKNOWN | NOOP (`:unsolved`) |
| UNKNOWN / identity mismatch | 무엇이든 | NOOP (`:certification_unavailable`) |

`gaps`(identity·noise floor·checkpoint gap·native 의무·campaign 정지)가 비어 있지 않으면 기준 rollout 결과와 무관하게
인증 불가다 — 기준은 `:UNKNOWN` 으로 싣고 실제 rollout 결과는 사유에 남긴다(rescue 분모에서 조용히 빼지 않는다).
`raw_regressions` = 기준 COMPLETE 에서 `:FAIL_WITHIN_BUDGET`·`:REJECTED` 후보(분해는 `candidate_outcomes`). UNKNOWN 후보는
regression 이 아니라 `candidate_unknown:` 사유로 남는다.
"""
function select_repair(checkpoint_id::AbstractString, baseline::Symbol, cands::AbstractVector;
                       gaps::AbstractVector = String[], baseline_note::AbstractString = "")
    baseline in R.ROLLOUT_OUTCOMES || throw(ArgumentError("baseline $(baseline) not in $(R.ROLLOUT_OUTCOMES)"))
    ids = [String(c.proposal_id) for c in cands]
    allunique(ids) || throw(ArgumentError("duplicate proposal_id among candidates: $(ids)"))
    reasons = String["certification_unavailable: $(g)" for g in gaps]
    base = isempty(gaps) ? baseline : :UNKNOWN
    isempty(gaps) || baseline === :UNKNOWN ||
        push!(reasons, "baseline rollout was $(baseline) but is not certified (gaps above) — kept in the denominator")
    isempty(baseline_note) || push!(reasons, "baseline: $(baseline_note)")
    outs = Dict{String,Symbol}(String(c.proposal_id) => candidate_outcome(c) for c in cands)
    ord = [ids[i] for i in sortperm([(Int(c.submission_index), i) for (i, c) in enumerate(cands)])]
    for id in ord
        outs[id] === :UNKNOWN && push!(reasons, "candidate_unknown: $(id)")
    end
    if base === :COMPLETE
        regs = String[id for id in ord if outs[id] in (:FAIL_WITHIN_BUDGET, :REJECTED)]
        return R.SelectionReport(checkpoint_id, base, :noop, nothing, :baseline_complete, regs, outs, reasons)
    elseif base === :FAIL_WITHIN_BUDGET
        k = findfirst(id -> outs[id] === :COMPLETE, ord)
        k === nothing && return R.SelectionReport(checkpoint_id, base, :noop, nothing, :unsolved, String[], outs,
                                                  push!(reasons, "no candidate COMPLETE with task/transaction checks passed"))
        return R.SelectionReport(checkpoint_id, base, :tool, ord[k], :rescued, String[], outs, reasons)
    end
    isempty(reasons) && push!(reasons, "baseline UNKNOWN")
    return R.SelectionReport(checkpoint_id, base, :noop, nothing, :certification_unavailable, String[], outs, reasons)
end

# =============================================================================
# 인증 전제 (T3/T4 결과를 인증에 연결)
# =============================================================================
"""
    checkpoint_gaps(contract, parent_dir) -> Vector{String}

부모 contract 의 checkpoint gap(`EpisodeCheckpoint.uncertifiable`) — 부모가 t0 에서 유도한 `task_contract.json` 이 있고
digest 가 contract 기록과 같을 때만 T5 이전 문구의 task-contract gap 을 해소로 친다. 그 밖의 gap 은 그대로 남는다.
"""
function checkpoint_gaps(contract::AbstractDict, parent_dir::AbstractString)
    tcm = get(contract, "task_contract", Dict{String,Any}())
    tcp = joinpath(parent_dir, "task_contract.json")
    tc_ok = tcm isa AbstractDict && haskey(tcm, "sha256") && _fsha(tcp) == tcm["sha256"]
    gaps = String[String(g) for g in get(contract, "gaps", String[]) if !(tc_ok && startswith(String(g), TASK_CONTRACT_GAP))]
    tc_ok || push!(gaps, "task_contract unavailable: $(tcm isa AbstractDict ? get(tcm, "error", "missing or digest mismatch") : tcm)")
    return gaps
end

"부모 `verify` 답의 인증 gap(블록 digest·tick 카운터·RNG)."
function identity_gaps(v::AbstractDict)
    g = String[]
    mb = get(v, "mismatched_blocks", ["<no answer>"])
    isempty(mb) || push!(g, "identity: parent t0 world blocks differ: $(join(mb, ","))")
    get(v, "counters_equal", false) === true || push!(g, "identity: parent tick counters changed while holding")
    get(v, "rng_equal", false) === true || push!(g, "identity: parent RNG changed while holding")
    return g
end

"""
분기 terminal 의 native 의무(`EpisodeCheckpointIO.NATIVE_OBLIGATIONS`): RVO KdTree 가 정확히 복원됐거나(`kd_restored`)
tie 가 관측되지 않았어야(`ties == []`) 원본 궤적 재현을 주장할 수 있다. terminal 이 없으면 판단 불가도 gap 이다.
"""
function native_gaps(dir::AbstractString)
    tp = joinpath(dir, "terminal.json")
    isfile(tp) || return ["native: no terminal.json in $(basename(dir)) — obligation not checkable"]
    ws = try _json(tp)["resume"]["rvo_tie_watch"] catch; nothing end
    ws isa AbstractVector || return ["native: terminal.json of $(basename(dir)) has no rvo_tie_watch"]
    return String["native: $(get(w, "global", "?")) ties=$(length(get(w, "ties", [1]))) kd_restored=$(get(w, "kd_restored", nothing))"
                  for w in ws if !(get(w, "kd_restored", false) === true || isempty(get(w, "ties", [1])))]
end

# =============================================================================
# 궤적·종료 대조 (noise floor · commit 뒤 replay · NOOP 재개 뒤 replay)
# =============================================================================
_trace_eq(c) = c.first_divergent_iter === nothing && c.only_a == 0 && c.only_b == 0 && c.n_common > 0

"""
    replay_compare(ref_dir, act_dir; t0) -> (; match, reasons, trace)

`trace.tsv` 를 t0 이후 공통 iter 에서 비교(rng 열 제외 — 기본 RNG 는 런타임이 소비하지 않는다, T3/T6 과 같은 규칙)하고
terminal 의 `iter`·`complete`·`terminal_reason`, 둘 다 있으면 `branch.task_state` digest 를 대조한다.
"""
function replay_compare(ref_dir::AbstractString, act_dir::AbstractString; t0::Integer)
    reasons = String[]
    tr(d) = joinpath(d, "trace.tsv")
    c = (isfile(tr(ref_dir)) && isfile(tr(act_dir))) ?
        RC.compare_traces(tr(ref_dir), tr(act_dir); from_iter = Int(t0), ignore = ("rng",)) : nothing
    if c === nothing
        push!(reasons, "trace.tsv missing ($(isfile(tr(ref_dir))) / $(isfile(tr(act_dir))))")
    elseif !_trace_eq(c)
        push!(reasons, "trajectory diverges: first_divergent_iter=$(c.first_divergent_iter) columns=$(c.divergent_columns) " *
                       "only_ref=$(c.only_a) only_active=$(c.only_b) common=$(c.n_common)")
    end
    a = try _json(joinpath(ref_dir, "terminal.json")) catch; nothing end
    b = try _json(joinpath(act_dir, "terminal.json")) catch; nothing end
    if a === nothing || b === nothing
        push!(reasons, "terminal.json missing (ref=$(a !== nothing) active=$(b !== nothing))")
    else
        for k in ("iter", "complete", "terminal_reason")
            get(a, k, missing) == get(b, k, missing) || push!(reasons, "terminal $(k): $(get(a, k, nothing)) != $(get(b, k, nothing))")
        end
        ta = try a["branch"]["task_state"] catch; nothing end
        tb = try b["branch"]["task_state"] catch; nothing end
        (ta === nothing || tb === nothing || TC.digest(ta) == TC.digest(tb)) || push!(reasons, "terminal task_state digest differs")
    end
    return (; match = isempty(reasons), reasons, trace = c)
end

"campaign 인증 정지 기록(보장 위반). 이후 `verify_identity!` 가 이 파일을 보고 인증 불가로 돈다."
function stop_certification!(campaign_dir::AbstractString, entry::AbstractDict)
    mkpath(campaign_dir)
    p = joinpath(campaign_dir, STOP_FILE)
    rows = isfile(p) ? JSON3.read(read(p, String), Vector{Any}) : Any[]
    push!(rows, merge(Dict{String,Any}("at" => time()), entry))
    _write(p, rows)
    return p
end
certification_stopped(campaign_dir::AbstractString) = isfile(joinpath(campaign_dir, STOP_FILE))

# =============================================================================
# certificate
# =============================================================================
_rollout_dict(r::R.RolloutReport) = Dict{String,Any}("branch" => r.branch, "checkpoint_id" => r.checkpoint_id,
    "outcome" => String(r.outcome), "unknown_cause" => r.unknown_cause === nothing ? nothing : String(r.unknown_cause),
    "terminal_reason" => String(r.terminal_reason), "sim_steps" => r.sim_steps, "zone_ladder_fired" => r.zone_ladder_fired,
    "general_recovery" => r.general_recovery)
selection_dict(s::R.SelectionReport) = Dict{String,Any}("checkpoint_id" => s.checkpoint_id,
    "baseline_outcome" => String(s.baseline_outcome), "selected" => String(s.selected),
    "selected_proposal_id" => s.selected_proposal_id, "classification" => String(s.classification),
    "raw_regressions" => s.raw_regressions, "candidate_outcomes" => Dict(k => String(v) for (k, v) in s.candidate_outcomes),
    "reasons" => s.reasons)

"stale 판정에 쓰는 **지금** 사실(부모 파일 digest · 부모 verify · campaign 정지)."
function current_facts(parent_dir::AbstractString, verify::AbstractDict; campaign_dir::AbstractString)
    contract = _json(joinpath(parent_dir, "contract.json"))
    return Dict{String,Any}("checkpoint_id" => contract["checkpoint_id"],
        "envelope_sha256" => _fsha(String(contract["envelope"])),
        "contract_sha256" => _fsha(joinpath(parent_dir, "contract.json")),
        "task_contract_sha256" => _fsha(joinpath(parent_dir, "task_contract.json")),
        "identity_gaps" => identity_gaps(verify), "campaign_stopped" => certification_stopped(campaign_dir))
end

"""
    build_certificate(; parent_dir, verify, selection, baseline, gaps, launch_env, limits, cand = nothing) -> Dict

설계 §7.3 의 certificate. `cand` = 선택된 후보 `(; raw, dir, rollout::RolloutReport, judged)`(NOOP 이면 `nothing`).
지문 블록: checkpoint · config · task · proposal/source/params/calls · effect trace · post-state · continuation ·
RNG · budget · validator · 두 분기 결과 · 선택 · 관측 경계(`unobserved`). digest 는 `certificate_sha256(cert)`.
"""
function build_certificate(; parent_dir::AbstractString, verify::AbstractDict, selection::R.SelectionReport,
                           baseline::Union{Nothing,R.RolloutReport}, gaps::AbstractVector, launch_env::AbstractDict,
                           limits::BR.Limits, cand = nothing)
    contract = _json(joinpath(parent_dir, "contract.json"))
    clean, _ = BR.scrub(launch_env)
    cert = Dict{String,Any}("schema" => CERTIFICATE_SCHEMA, "supervisor_version" => SUPERVISOR_VERSION,
        "checkpoint" => Dict{String,Any}("checkpoint_id" => contract["checkpoint_id"],
            "envelope_sha256" => _fsha(String(contract["envelope"])),
            "contract_sha256" => _fsha(joinpath(parent_dir, "contract.json")),
            "t0_iter" => contract["t0_iter"], "batch_pos" => contract["batch_pos"],
            "certification_gaps" => collect(String, gaps), "parent_verify_identity_gaps" => identity_gaps(verify)),
        "config" => Dict{String,Any}("launch_env_sha256" => TC.digest(clean), "pi0" => contract["pi0"]),
        "task" => Dict{String,Any}("task_contract_sha256" => _fsha(joinpath(parent_dir, "task_contract.json")),
            "validator_version" => TC.TASK_CONTRACT_VALIDATOR_VERSION),
        "rng" => Dict{String,Any}("parent_rng_equal" => get(verify, "rng_equal", nothing),
            "exogenous_seeds" => Dict{String,Any}(k => clean[k] for k in ("DEMO_SEED", "DEMO_ZONE_SEED", "DEMO_OOD_SEED") if haskey(clean, k))),
        "budget" => Dict{String,Any}("sim_params" => contract["sim_params"],
            "worker_limits" => Dict{String,Any}("wall_s" => limits.wall_s, "cpu_s" => limits.cpu_s, "mem_bytes" => limits.mem_bytes)),
        "validators" => Dict{String,Any}("supervisor" => SUPERVISOR_VERSION, "effect" => EV.EFFECT_VALIDATOR_VERSION,
            "task_contract" => TC.TASK_CONTRACT_VALIDATOR_VERSION, "tool_execution" => TX.TOOL_EXECUTION_VERSION,
            "enactment_schema" => TX.ENACTMENT_SCHEMA, "branch_contract" => BR.CONTRACT_SCHEMA,
            "branch_export" => BR.EXPORT_SCHEMA, "proposal_gate" => PG.PROPOSAL_GATE_VERSION,
            "envelope" => R.ENVELOPE_VALIDATOR_VERSION),
        "outcomes" => Dict{String,Any}("baseline" => baseline === nothing ? nothing : _rollout_dict(baseline),
                                       "candidate" => nothing),
        "selection" => selection_dict(selection), "certification_available" => isempty(gaps),
        "proposal" => nothing, "source" => nothing, "params_sha256" => nothing, "calls_sha256" => nothing,
        "effect" => nothing, "post_state_sha256" => nothing,
        "continuation" => Dict{String,Any}("policy" => "pi0", "pi0" => contract["pi0"], "t1_iter" => contract["t0_iter"]),
        "unobserved" => String[])
    cand === nothing && return cert
    raw = JSON3.read(JSON3.write(cand.raw), Dict{String,Any})
    g = PG.gate_proposal(raw; checkpoint_id = String(contract["checkpoint_id"]),
                         ablation_level = Symbol(contract["pi0"]["REPAIR_ABLATION"]))
    b = something(g.binding, Dict{String,Any}())
    X = _json(joinpath(cand.dir, "enactment.json"))
    term = try _json(joinpath(cand.dir, "terminal.json")) catch; nothing end
    ts = term === nothing ? nothing : get(get(term, "branch", Dict()), "task_state", nothing)
    cert["proposal"] = Dict{String,Any}("proposal_id" => raw["proposal_id"], "submission_index" => raw["submission_index"],
        "file_sha256" => TC.digest(raw), "binding_sha256" => get(b, "proposal_sha256", nothing),
        "gate_version" => get(b, "gate_version", nothing), "capability_contract_version" => get(b, "capability_contract_version", nothing),
        "ablation_level" => get(b, "ablation_level", nothing))
    cert["source"] = Dict{String,Any}("impl_name" => raw["impl_name"], "source_sha256" => get(b, "source_sha256", nothing))
    cert["params_sha256"] = TC.digest(raw["params"]); cert["calls_sha256"] = TC.digest(raw["calls"])
    au = get(X, "audit", Dict{String,Any}())
    cert["effect"] = Dict{String,Any}("trace_digest" => X["trace_digest"],
        "effect_trace_file_sha256" => _fsha(joinpath(cand.dir, "effect_trace.json")),
        "effect_classes" => get(X, "effect_classes", String[]), "body_changes" => get(X, "body_changes", String[]),
        "harness_changes" => get(X, "harness_changes", String[]),
        "fields_changed_by_action" => get(au, "fields_changed_by_action", String[]),
        "methods_changed_by_action" => get(au, "methods_changed_by_action", String[]),
        "adapter_log_sha256" => TC.digest(get(X, "adapter_log", Any[])),
        "checks_run" => get(get(X, "postprocess", Dict()), "checks_run", String[]),
        "engine_steps" => X["engine_steps"], "batch_pos_after" => X["batch_pos"])
    cert["post_state_sha256"] = X["post_state_sha256"]
    cert["continuation"]["t1_iter"] = Int(contract["t0_iter"]) + Int(X["engine_steps"])
    cert["continuation"]["terminal_task_state_sha256"] = ts === nothing ? nothing : TC.digest(ts)
    cert["continuation"]["trace_sha256"] = _fsha(joinpath(cand.dir, "trace.tsv"))
    cert["outcomes"]["candidate"] = _rollout_dict(cand.rollout)
    cert["unobserved"] = collect(String, cand.judged.unobserved)
    return cert
end
certificate_sha256(cert::AbstractDict) = _rt_digest(cert)

"""
    stale_reasons(cert, cur; raw = nothing) -> Vector{String}

certificate 를 지금 사실과 대조한다(비면 유효). checkpoint/contract/task contract 파일 digest, 부모 identity, campaign 정지,
그리고 commit 하려는 제안(`raw`)이 certificate 가 묶은 제안과 같은가 — 같은 함수 이름을 다른 코드로 다시 내면 여기서 걸린다.
"""
function stale_reasons(cert::AbstractDict, cur::AbstractDict; raw = nothing)
    out = String[]
    ck = cert["checkpoint"]
    ck["checkpoint_id"] == cur["checkpoint_id"] || push!(out, "checkpoint_id $(ck["checkpoint_id"]) != $(cur["checkpoint_id"])")
    for k in ("envelope_sha256", "contract_sha256")
        ck[k] == cur[k] || push!(out, "checkpoint $(k) changed")
    end
    cert["task"]["task_contract_sha256"] == cur["task_contract_sha256"] || push!(out, "task_contract_sha256 changed")
    isempty(cur["identity_gaps"]) || push!(out, "parent t0 changed: " * join(cur["identity_gaps"], "; "))
    cur["campaign_stopped"] === true && push!(out, "campaign certification stopped")
    cert["certification_available"] === true || push!(out, "certificate was issued with certification unavailable")
    if raw !== nothing
        p = cert["proposal"]
        if p === nothing
            push!(out, "certificate binds no proposal (NOOP) but a proposal was given")
        else
            _rt_digest(raw) == p["file_sha256"] ||
                push!(out, "proposal differs from the certified one (impl_name $(get(raw, "impl_name", "?")) — same name re-registered with other code?)")
        end
    end
    return out
end

# =============================================================================
# commit
# =============================================================================
"`enactment.json` 두 장에서 대조할 경로. 시간(wall_s)·세부 반환 문자열은 뺀다(재현 대상이 아니다)."
const COMPARE_PATHS = (("status",), ("proposal_sha256",), ("checkpoint_id",), ("impl_name",), ("mode",),
    ("post_state_sha256",), ("trace_digest",), ("engine_steps",), ("batch_pos",), ("effect_classes",),
    ("body_changes",), ("harness_changes",), ("adapter_log",), ("unobservable",),
    ("audit", "fields_changed_by_action"), ("audit", "methods_changed_by_action"), ("audit", "fields_changed_by_engine"),
    ("postprocess", "checks_run"), ("postprocess", "failures"), ("postprocess", "unsupported"), ("postprocess", "log"),
    ("postprocess", "fields_changed"), ("body", "verdict"), ("body", "partial"), ("registration", "why"))

_dig(d, path) = (x = d; for k in path; x = x isa AbstractDict ? get(x, k, missing) : missing; end; x)

"""
    compare_enactments(a, b) -> Vector{String}

검증 분기와 commit worker 의 enactment 대조(순수). 다른 경로 이름 목록(비면 같음). body 단계는 이름·상태만 본다.
두 쪽 모두 `post_state_sha256 == digest(post_state)` 여야 한다(아니면 `post_state_digest_self`).
"""
function compare_enactments(a::AbstractDict, b::AbstractDict)
    out = String[join(p, ".") for p in COMPARE_PATHS if !isequal(_dig(a, p), _dig(b, p))]
    st(x) = (s = _dig(x, ("body", "steps")); s isa AbstractVector ? [(get(e, "name", nothing), get(e, "status", nothing)) for e in s] : nothing)
    isequal(st(a), st(b)) || push!(out, "body.steps")
    for (n, x) in (("a", a), ("b", b))
        ps = get(x, "post_state", nothing)
        (ps === nothing && get(x, "post_state_sha256", nothing) === nothing) || (ps isa AbstractDict && TC.digest(ps) == get(x, "post_state_sha256", nothing)) ||
            push!(out, "post_state_digest_self:$(n)")
    end
    return out
end

"""
    precommit_check(parent_dir, verif_dir, commit_dir, cert) -> (; ok, reasons, judged, mismatches, held)

commit worker 가 t1 에서 멈춘 뒤: trusted 판정(`judge_candidate(...).precommit_ok`) + 검증 분기와의 대조 + certificate 와의 대조.
"""
function precommit_check(parent_dir::AbstractString, verif_dir::AbstractString, commit_dir::AbstractString, cert::AbstractDict)
    reasons = String[]
    j = TX.judge_candidate(parent_dir, commit_dir; proposal_file = commit_dir * ".proposal.json")
    j.precommit_ok || append!(reasons, isempty(j.reasons) ? ["commit trusted check failed"] : ["commit trusted check: $(r)" for r in j.reasons])
    V = try _json(joinpath(verif_dir, "enactment.json")) catch; Dict{String,Any}() end
    C = try _json(joinpath(commit_dir, "enactment.json")) catch; Dict{String,Any}() end
    H = try _json(joinpath(commit_dir, "held_t1.json")) catch; Dict{String,Any}() end
    mm = compare_enactments(V, C)
    isempty(mm) || push!(reasons, "commit enactment differs from the verification branch: $(join(mm, ", "))")
    get(C, "post_state_sha256", nothing) == cert["post_state_sha256"] || push!(reasons, "commit post_state_sha256 != certificate")
    get(C, "proposal_sha256", nothing) == cert["proposal"]["file_sha256"] || push!(reasons, "commit proposal_sha256 != certificate")
    get(H, "post_state_sha256", nothing) == get(C, "post_state_sha256", missing) || push!(reasons, "held_t1 post_state_sha256 != enactment")
    get(H, "t1_iter", nothing) == cert["continuation"]["t1_iter"] ||
        push!(reasons, "held at iter $(get(H, "t1_iter", nothing)) != certificate t1 $(cert["continuation"]["t1_iter"])")
    return (; ok = isempty(reasons), reasons, judged = j, mismatches = mm, held = H)
end

"프로세스가 끝날 때까지 기다린다(초과면 kill). 반환: 제때 끝났나."
function _await(p::Base.Process, timeout_s::Real)
    t = time()
    while process_running(p)
        time() - t > timeout_s && (kill(p, Base.SIGKILL); wait(p); return false)
        sleep(1)
    end
    return true
end

"부모(원래 세계)를 은퇴시킨다: `exit` 명령, 안 들으면 kill. 반환: 기록."
function retire_parent!(parent; why::AbstractString)
    process_running(parent.process) || return Dict{String,Any}("retired" => true, "how" => "already exited", "why" => why)
    how = try
        BR.parent_command(parent, "exit"; timeout_s = 120); "exit command"
    catch e
        "exit command failed ($(first(sprint(showerror, e), 200)))"
    end
    _await(parent.process, 30) || (how *= "; killed")
    return Dict{String,Any}("retired" => !process_running(parent.process), "how" => how, "why" => why)
end

"""
활성 세계 전환 기록(`<commit_dir>.active_world.json`, supervisor 소유 — worker 는 쓸 수 없는 자리). 도구가 engine 을 진행했으면
t0→t1 의 step(engine 카운터)·사건·비용·하니스 로그와 원장 경계를 **실제 집행으로** 인계한다. t1 을 t0 로 적지 않는다.
"""
function handover_record(; contract, commit_dir, commit_id, held, cert_sha, parent_retire)
    X = _json(joinpath(commit_dir, "enactment.json"))
    tr = JSON3.read(read(joinpath(commit_dir, "effect_trace.json"), String), Vector{Any})
    return Dict{String,Any}("schema" => ACTIVE_WORLD_SCHEMA, "active" => "commit_worker", "commit_worker_id" => commit_id,
        "dir" => commit_dir, "pid" => held["pid"], "certificate_sha256" => cert_sha,
        "t0_iter" => contract["t0_iter"], "t1_iter" => held["t1_iter"], "engine_steps" => held["engine_steps"],
        "handover" => Dict{String,Any}(
            "events" => [Dict{String,Any}("kind" => e["kind"], "engine" => get(e, "engine", nothing)) for e in tr],
            "adapter_log" => get(X, "adapter_log", Any[]), "postprocess_log" => get(get(X, "postprocess", Dict()), "log", Any[]),
            "cost" => Dict{String,Any}("enactment_wall_s" => get(X, "wall_s", nothing), "engine_steps" => X["engine_steps"]),
            "ledger" => Dict{String,Any}("real_until_t0" => contract["real_ledger"],
                                         "active_from_t0" => joinpath(commit_dir, "shadow_MONITOR_IO.jsonl"),
                                         "active_bytes_at_t1" => held["ledger_bytes_at_t1"])),
        "parent" => merge(Dict{String,Any}("pid" => contract["parent_pid"]), parent_retire))
end

"""
    commit_tool!(; parent, cert, cert_sha, raw, verif_dir, outroot, commit_id, launch_env, limits, campaign_dir,
                 extra_env = Dict()) -> NamedTuple

§7.3 의 commit. 부모는 t0 에서 기다리는 채로 두고:
1. stale 검사(`stale_reasons` — 부모 verify 포함). stale 이면 worker 를 띄우지 않는다.
2. 새 commit worker(`execute_tool_isolated`, mode "commit", 새 branch id — 후보 프로세스를 재사용하지 않는다)가 같은
   제안을 등록·집행하고 t1 에서 멈춘다.
3. `precommit_check` 통과 → `activate` → 부모 은퇴(`retire_parent!`) → 전환 기록. 실패 → `exit`(worker 폐기).
4. 활성 worker 가 끝나면 `replay_compare(verif_dir, commit_dir)` + 결과 대조. 어긋나면 `:replay_mismatch` + campaign 정지.
반환 `(; report::CommitReport, activated, precommit, handover, exec, replay)`. **부모 재개는 하지 않는다** — 활성화가 안 됐으면
호출자(`commit!`)가 NOOP 로 재개한다(`activated == false` ⟹ 부모는 t0 에서 그대로다).
"""
function commit_tool!(; parent, cert::AbstractDict, cert_sha::AbstractString, raw::AbstractDict, verif_dir::AbstractString,
                      outroot::AbstractString, commit_id::AbstractString, launch_env::AbstractDict, limits::BR.Limits,
                      campaign_dir::AbstractString, extra_env::AbstractDict = Dict{String,String}())
    contract = _json(joinpath(parent.dir, "contract.json"))
    cid = String(contract["checkpoint_id"])
    pid = String(get(raw, "proposal_id", "?"))
    abort(reasons; post = nothing, extra...) =
        (; report = R.CommitReport(cid, pid, cert_sha, commit_id, :aborted_resumed_noop, post, nothing, reasons),
           activated = false, extra...)
    stale = stale_reasons(cert, current_facts(parent.dir, BR.parent_command(parent, "verify"); campaign_dir); raw)
    isempty(stale) || return abort(["stale_certificate: " * s for s in stale]; precommit = nothing, handover = nothing,
                                   exec = nothing, replay = nothing)
    cdir = joinpath(outroot, commit_id)
    pre = Ref{Any}(nothing); hand = Ref{Any}(nothing); ctl_err = Ref{Any}(nothing)
    tick = function (p)
        (pre[] === nothing && ctl_err[] === nothing && isfile(joinpath(cdir, "held_t1.json"))) || return nothing
        try
            sleep(0.3)                                     # worker 가 held 파일을 다 쓰고 닫을 시간
            d = precommit_check(parent.dir, verif_dir, cdir, cert)
            pre[] = d
            w = (dir = cdir, process = p)
            if d.ok
                BR.parent_command(w, "activate"; timeout_s = 120)
                pr = retire_parent!(parent; why = "commit worker $(commit_id) activated")
                hand[] = handover_record(; contract, commit_dir = cdir, commit_id, held = d.held, cert_sha, parent_retire = pr)
                _write(cdir * ".active_world.json", hand[])
            else
                BR.parent_command(w, "exit"; timeout_s = 120)
            end
        catch e
            e isa InterruptException && rethrow()
            ctl_err[] = first(sprint(showerror, e), 400)
        end
        return nothing
    end
    x = TX.execute_tool_isolated(; parent_dir = parent.dir, raw, outroot, branch_id = commit_id, launch_env, limits,
                                 mode = "commit", extra_env, on_tick = tick)
    d = pre[]
    if hand[] === nothing
        reasons = String[]
        ctl_err[] === nothing || push!(reasons, "commit control error: $(ctl_err[])")
        if d === nothing
            push!(reasons, "commit worker never reached t1 (registration/enactment failed or discarded)")
            x.judged === nothing ? append!(reasons, ["gate: $(r)" for r in x.reasons]) : append!(reasons, ["commit: $(r)" for r in x.judged.reasons])
        else
            append!(reasons, d.reasons)
        end
        post = d === nothing ? nothing : (get(d.held, "post_state_sha256", nothing) == cert["post_state_sha256"])
        return abort(reasons; post, precommit = d, handover = nothing, exec = x, replay = nothing)
    end
    # ---- 활성화된 뒤: 같은 continuation 을 실제로 굴린 결과를 검증 분기와 대조 ------------------------------
    rp = replay_compare(verif_dir, cdir; t0 = contract["t0_iter"])
    reasons = copy(rp.reasons)
    rep = x.run.report
    co = cert["outcomes"]["candidate"]
    (String(rep.outcome) == co["outcome"] && rep.sim_steps == co["sim_steps"] && String(rep.terminal_reason) == co["terminal_reason"]) ||
        push!(reasons, "active outcome $(rep.outcome)/$(rep.terminal_reason)/$(rep.sim_steps) != certified $(co["outcome"])/$(co["terminal_reason"])/$(co["sim_steps"])")
    x.judged.eligible || append!(reasons, ["active world failed the trusted terminal check: $(r)" for r in x.judged.reasons])
    ok = isempty(reasons)
    if !ok
        stop_certification!(campaign_dir, Dict{String,Any}("kind" => "post_activation_replay_mismatch", "checkpoint_id" => cid,
            "proposal_id" => pid, "certificate_sha256" => cert_sha, "commit_worker" => cdir, "reasons" => reasons))
        pushfirst!(reasons, "GUARANTEE VIOLATION: the activated world diverged from the verification branch — campaign certification stopped")
    end
    return (; report = R.CommitReport(cid, pid, cert_sha, commit_id, ok ? :committed : :replay_mismatch, true, ok,
                                      ok ? String[] : reasons),
            activated = true, precommit = d, handover = hand[], exec = x, replay = rp)
end

# =============================================================================
# 한 사건의 supervisor (상태 기계를 실제로 도는 쪽)
# =============================================================================
mutable struct Supervision
    parent::Any                                  # BranchRunner.start_parent 의 결과(t0 에서 기다리는 원래 세계)
    outroot::String
    campaign_dir::String
    launch_env::Dict{String,String}
    limits::BR.Limits
    state::Symbol
    transitions::Vector{Dict{String,Any}}
    contract::Dict{String,Any}
    verify0::Dict{String,Any}
    gaps::Vector{String}
    frozen::Vector{Dict{String,Any}}             # raw · proposal_id · submission_index · file_sha256 · within_budget
    baseline::Any                                # run_branch 결과
    candidates::Dict{String,Any}                 # proposal_id → (; exec, dir, native, file_ok, eligible, outcome)
    selection::Union{Nothing,R.SelectionReport}
    certificate::Union{Nothing,Dict{String,Any}}
    certificate_sha256::String
    commit::Any
    replay::Any
    resumed::Bool
end

"""
    Supervision(parent; outroot, launch_env, limits, campaign_dir = outroot)

`parent` 는 이미 t0 에서 기다리는 중이어야 한다(`BranchRunner.wait_held` 뒤). 상태 = `:CAPTURED`.
"""
function Supervision(parent; outroot::AbstractString, launch_env::AbstractDict, limits::BR.Limits,
                     campaign_dir::AbstractString = outroot)
    isfile(joinpath(parent.dir, "held.json")) || error("parent is not holding at t0 yet (no held.json)")
    mkpath(outroot)
    sv = Supervision(parent, String(outroot), String(campaign_dir), Dict{String,String}(String(k) => String(v) for (k, v) in launch_env),
                     limits, :CAPTURED, Dict{String,Any}[], _json(joinpath(parent.dir, "contract.json")), Dict{String,Any}(),
                     String[], Dict{String,Any}[], nothing, Dict{String,Any}(), nothing, nothing, "", nothing, nothing, false)
    push!(sv.transitions, Dict{String,Any}("to" => "CAPTURED", "why" => "parent holding at t0 iter=$(sv.contract["t0_iter"])", "at" => time()))
    return sv
end

function advance!(sv::Supervision, to::Symbol; why::AbstractString = "")
    sv.state = transition(sv.state, to)
    push!(sv.transitions, Dict{String,Any}("to" => String(to), "why" => why, "at" => time()))
    return sv
end
_verify(sv) = BR.parent_command(sv.parent, "verify")

"CAPTURED → IDENTITY_VERIFIED | CERTIFICATION_UNAVAILABLE. `noise_floor::Bool` 을 주면 그 값(같은 칸의 기존 측정)을 쓴다."
function verify_identity!(sv::Supervision; noise_floor::Union{Bool,Symbol} = :measure)
    sv.verify0 = _verify(sv)
    append!(sv.gaps, checkpoint_gaps(sv.contract, sv.parent.dir))
    append!(sv.gaps, identity_gaps(sv.verify0))
    certification_stopped(sv.campaign_dir) && push!(sv.gaps, "campaign certification stopped ($(joinpath(sv.campaign_dir, STOP_FILE)))")
    noise_floor === false && push!(sv.gaps, "noise floor: supplied measurement says the cell is not reproducible")
    advance!(sv, isempty(sv.gaps) ? :IDENTITY_VERIFIED : :CERTIFICATION_UNAVAILABLE; why = join(sv.gaps, "; "))
end

"IDENTITY_VERIFIED → PROPOSALS_FROZEN. 후보는 rollout 전에 동결된다(digest 기록). K 초과분은 rollout 없이 거절로 남는다."
function freeze!(sv::Supervision, proposals::AbstractVector; max_candidates::Int = 4)
    for (i, raw) in enumerate(proposals)
        push!(sv.frozen, Dict{String,Any}("raw" => raw, "proposal_id" => String(raw["proposal_id"]),
            "submission_index" => Int(get(raw, "submission_index", i)), "file_sha256" => _rt_digest(raw),
            "within_budget" => i <= max_candidates, "branch_id" => "cand-$(i)"))
    end
    _write(joinpath(sv.outroot, "frozen_proposals.json"), [Dict(k => v for (k, v) in f if k != "raw") for f in sv.frozen])
    sv.state === :IDENTITY_VERIFIED && advance!(sv, :PROPOSALS_FROZEN; why = "$(length(proposals)) proposals, K=$(max_candidates)")
    return sv
end

"""
PROPOSALS_FROZEN → BASELINE_AND_CANDIDATE_ROLLOUTS. NOOP 기준(+ `noise_floor == :measure` 면 두 번째 NOOP 로 잡음 바닥)과
후보마다 새 worker(full). 매 분기 뒤 부모 verify — t0 가 흔들리면 인증 불가.
"""
function rollouts!(sv::Supervision; noise_floor::Union{Bool,Symbol} = :measure)
    t0 = sv.contract["t0_iter"]
    sv.baseline = BR.run_branch(; parent_dir = sv.parent.dir, branch_id = "noop", outroot = sv.outroot,
                                launch_env = sv.launch_env, limits = sv.limits)
    append!(sv.gaps, native_gaps(sv.baseline.dir))
    if noise_floor === :measure
        nb = BR.run_branch(; parent_dir = sv.parent.dir, branch_id = "noop-b", outroot = sv.outroot,
                           launch_env = sv.launch_env, limits = sv.limits)
        nf = replay_compare(sv.baseline.dir, nb.dir; t0)
        nb.report.outcome === sv.baseline.report.outcome || push!(nf.reasons, "outcome $(nb.report.outcome) != $(sv.baseline.report.outcome)")
        isempty(nf.reasons) || push!(sv.gaps, "noise floor: two NOOP branches from the same checkpoint differ: " * join(nf.reasons, "; "))
    end
    for f in sv.frozen
        id = f["proposal_id"]
        if !f["within_budget"]
            sv.candidates[id] = (; exec = nothing, dir = nothing, native = String[], file_ok = true, eligible = false,
                                 outcome = nothing, reasons = ["over the candidate budget (K) — not run"])
            continue
        end
        x = TX.execute_tool_isolated(; parent_dir = sv.parent.dir, raw = f["raw"], outroot = sv.outroot,
                                     branch_id = f["branch_id"], launch_env = sv.launch_env, limits = sv.limits, mode = "full")
        dir = x.run === nothing ? nothing : x.run.dir
        pf = joinpath(sv.outroot, f["branch_id"] * ".proposal.json")
        file_ok = x.run === nothing || (isfile(pf) && TC.digest(_json(pf)) == f["file_sha256"])
        nat = dir === nothing ? String[] : native_gaps(dir)
        reasons = vcat(copy(x.reasons), file_ok ? String[] : ["frozen proposal digest != the file the worker ran"], nat)
        sv.candidates[id] = (; exec = x, dir, native = nat, file_ok, eligible = x.eligible && file_ok && isempty(nat),
                             outcome = x.run === nothing ? nothing : x.run.report.outcome, reasons)
        g = identity_gaps(_verify(sv))
        isempty(g) || push!(sv.gaps, "parent changed during candidate $(id): " * join(g, "; "))
    end
    advance!(sv, :BASELINE_AND_CANDIDATE_ROLLOUTS; why = "baseline $(sv.baseline.report.outcome); $(length(sv.candidates)) candidates")
end

"선택 + certificate. → SELECTED_TOOL | SELECTED_NOOP | CERTIFICATION_UNAVAILABLE."
function select!(sv::Supervision)
    cid = String(sv.contract["checkpoint_id"])
    ran = sv.baseline !== nothing
    cands = [(; proposal_id = f["proposal_id"], submission_index = f["submission_index"],
              outcome = ran ? sv.candidates[f["proposal_id"]].outcome : :UNKNOWN,
              eligible = ran && sv.candidates[f["proposal_id"]].eligible) for f in sv.frozen]
    base = ran ? sv.baseline.report.outcome : :UNKNOWN
    note = ran ? (sv.baseline.report.unknown_cause === nothing ? "" : "UNKNOWN cause $(sv.baseline.report.unknown_cause)") :
                 "not run (certification unavailable before rollouts)"
    sv.selection = select_repair(cid, base, cands; gaps = unique(sv.gaps), baseline_note = note)
    cand = nothing
    if sv.selection.selected === :tool
        f = only(filter(f -> f["proposal_id"] == sv.selection.selected_proposal_id, sv.frozen))
        c = sv.candidates[f["proposal_id"]]
        cand = (; raw = f["raw"], dir = c.dir, rollout = c.exec.run.report, judged = c.exec.judged)
    end
    sv.certificate = build_certificate(; parent_dir = sv.parent.dir, verify = sv.verify0, selection = sv.selection,
        baseline = ran ? sv.baseline.report : nothing, gaps = unique(sv.gaps), launch_env = sv.launch_env,
        limits = sv.limits, cand)
    sv.certificate_sha256 = certificate_sha256(sv.certificate)
    _write(joinpath(sv.outroot, "certificate.json"), sv.certificate)
    if sv.state === :CERTIFICATION_UNAVAILABLE
        return advance!(sv, :SELECTED_NOOP; why = "certification unavailable → NOOP")
    end
    to = sv.selection.selected === :tool ? :SELECTED_TOOL :
         sv.selection.classification === :certification_unavailable ? :CERTIFICATION_UNAVAILABLE : :SELECTED_NOOP
    advance!(sv, to; why = "$(sv.selection.classification)")
    to === :CERTIFICATION_UNAVAILABLE && advance!(sv, :SELECTED_NOOP; why = "certification unavailable → NOOP")
    return sv
end

"""
NOOP 재개: 부모 verify(인증 가능하면 PRECOMMIT_VERIFIED) → `resume` → 종료까지 기다림 → COMMITTED → 기준 NOOP 분기와 replay
대조 → REPLAY_CHECKED. 인증 가능한데 어긋나면 보장 위반(campaign 정지).
"""
function resume_noop!(sv::Supervision)
    v = _verify(sv)
    certified = isempty(sv.gaps) && isempty(identity_gaps(v))
    certified && advance!(sv, :PRECOMMIT_VERIFIED; why = "parent unchanged at t0")
    BR.parent_command(sv.parent, "resume"); sv.resumed = true
    fin = _await(sv.parent.process, sv.limits.wall_s)
    advance!(sv, :COMMITTED; why = "original world resumed under pi0" * (certified ? "" : " (uncertified)"))
    rp = sv.baseline === nothing ? (; match = false, reasons = ["no NOOP baseline branch to compare with"], trace = nothing) :
         replay_compare(sv.baseline.dir, sv.parent.dir; t0 = sv.contract["t0_iter"])
    fin || push!(rp.reasons, "parent did not finish within $(sv.limits.wall_s) s (killed)")
    violation = certified && !isempty(rp.reasons)
    violation && stop_certification!(sv.campaign_dir, Dict{String,Any}("kind" => "noop_resume_replay_mismatch",
        "checkpoint_id" => sv.contract["checkpoint_id"], "reasons" => rp.reasons, "parent" => sv.parent.dir))
    sv.replay = (; kind = :noop, match = isempty(rp.reasons), reasons = rp.reasons, trace = rp.trace, certified, violation)
    advance!(sv, :REPLAY_CHECKED; why = isempty(rp.reasons) ? "NOOP resume replays the baseline branch" :
                                         (violation ? "GUARANTEE VIOLATION: " : "uncertified mismatch: ") * join(rp.reasons, "; "))
end

"""
SELECTED_TOOL → commit(`commit_tool!`) → 활성화면 PRECOMMIT_VERIFIED → COMMITTED → REPLAY_CHECKED;
실패면 REJECT_CANDIDATE → SELECTED_NOOP → `resume_noop!`. SELECTED_NOOP → `resume_noop!`.
"""
function commit!(sv::Supervision; commit_id::AbstractString = "commit", extra_env::AbstractDict = Dict{String,String}())
    if sv.state === :SELECTED_TOOL
        pid = sv.selection.selected_proposal_id
        f = only(filter(f -> f["proposal_id"] == pid, sv.frozen))
        sv.commit = commit_tool!(; parent = sv.parent, cert = sv.certificate, cert_sha = sv.certificate_sha256, raw = f["raw"],
            verif_dir = sv.candidates[pid].dir, outroot = sv.outroot, commit_id, launch_env = sv.launch_env,
            limits = sv.limits, campaign_dir = sv.campaign_dir, extra_env)
        if sv.commit.activated
            advance!(sv, :PRECOMMIT_VERIFIED; why = "commit worker t1 state/effects match the verification branch; trusted checks passed")
            advance!(sv, :COMMITTED; why = "commit worker $(commit_id) is the active world; parent retired")
            sv.replay = (; kind = :tool, match = sv.commit.replay.match, reasons = sv.commit.report.reasons,
                         trace = sv.commit.replay.trace, certified = true, violation = sv.commit.report.status === :replay_mismatch)
            return advance!(sv, :REPLAY_CHECKED; why = String(sv.commit.report.status))
        end
        advance!(sv, :REJECT_CANDIDATE; why = join(sv.commit.report.reasons, "; "))
        advance!(sv, :SELECTED_NOOP; why = "commit aborted → resume the untouched original world")
    end
    sv.state === :SELECTED_NOOP || error("commit! from state $(sv.state)")
    return resume_noop!(sv)
end

"`finally` 용: 부모가 아직 살아 있고 재개되지 않았으면 exit/kill, 재개됐는데 살아 있으면 kill(고아 방지)."
function retire!(sv::Supervision)
    p = sv.parent.process
    process_running(p) || return nothing
    sv.resumed ? (kill(p, Base.SIGKILL); wait(p)) : retire_parent!(sv.parent; why = "supervisor exiting")
    return nothing
end

"기록용 요약(JSON)."
function summary(sv::Supervision)
    c = sv.commit
    Dict{String,Any}("supervisor_version" => SUPERVISOR_VERSION, "state" => String(sv.state), "transitions" => sv.transitions,
        "gaps" => unique(sv.gaps), "selection" => sv.selection === nothing ? nothing : selection_dict(sv.selection),
        "certificate_sha256" => sv.certificate_sha256,
        "candidates" => Dict(k => Dict{String,Any}("dir" => v.dir, "eligible" => v.eligible,
                                                   "outcome" => v.outcome === nothing ? nothing : String(v.outcome),
                                                   "native" => v.native, "file_ok" => v.file_ok, "reasons" => v.reasons)
                             for (k, v) in sv.candidates),
        "baseline" => sv.baseline === nothing ? nothing : BR.report_dict(sv.baseline),
        "commit" => c === nothing ? nothing : Dict{String,Any}("status" => String(c.report.status),
            "post_state_match" => c.report.post_state_match, "replay_match" => c.report.replay_match,
            "reasons" => c.report.reasons, "activated" => c.activated, "commit_worker" => c.report.commit_worker_id),
        "replay" => sv.replay === nothing ? nothing : Dict{String,Any}("kind" => String(sv.replay.kind),
            "match" => sv.replay.match, "reasons" => sv.replay.reasons, "certified" => sv.replay.certified,
            "violation" => sv.replay.violation))
end

"""
    supervise_episode!(sv; proposals, noise_floor = :measure, max_candidates = 4, commit_id = "commit") -> Supervision

한 사건 전체(§7.2). 🔴 어떤 경로로 끝나든(예외 포함) `finally` 가 부모를 은퇴/kill 한다 — t0 에서 기다리는 부모를 고아로
남기지 않는다(T4 우려). 인증 불가면 rollout 없이 NOOP 으로 재개한다(분모에는 `:certification_unavailable` 로 남는다).
"""
function supervise_episode!(sv::Supervision; proposals::AbstractVector, noise_floor::Union{Bool,Symbol} = :measure,
                            max_candidates::Int = 4, commit_id::AbstractString = "commit")
    try
        verify_identity!(sv; noise_floor)
        freeze!(sv, proposals; max_candidates)
        sv.state === :PROPOSALS_FROZEN && rollouts!(sv; noise_floor)
        select!(sv)
        commit!(sv; commit_id)
        _write(joinpath(sv.outroot, "supervision.json"), summary(sv))
    finally
        retire!(sv)
    end
    return sv
end

end # module RepairSupervisor
