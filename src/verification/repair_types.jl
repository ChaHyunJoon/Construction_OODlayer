# =============================================================================
# repair_types.jl — zone-repair verification 계약(T1). 설계 docs/superpowers/specs/
#   2026-09-24-zone-repair-verification-design.md §4·§5·§7·§9.2.
#
# 로드: 독립 모듈이다. `include("src/verification/repair_types.jl")` 한 번이면 `RepairTypes` 가 생긴다
#   (시험은 Main 에, 나중에 ConstructionBots.jl 이 배선하면 `ConstructionBots.RepairTypes`).
#   🔴 같은 모듈 안에서 두 번 include 하지 말 것 — 뒤 파일들은 `RepairTypes.` 로 부른다.
#
# 🔴 schema 두 파일이 규칙의 단일 진실원이다. 이 파일은 그 JSON 을 **읽어** 검사하고 규칙을 다시 적지
#   않는다. 이 검사기가 모르는 schema 키워드가 나오면 조용히 무시하지 않고 에러를 낸다.
# 🔴 거절은 예외가 아니라 `"reject:<code>:…"` 문자열/보고서다(레포 규약 — minted_registration.jl 과 같다).
#   기본값을 채워 넣지 않는다: 빠진 필드는 거절이지 보완이 아니다.
# =============================================================================
module RepairTypes

using JSON3
using SHA: sha256

const TOOL_PROPOSAL_SCHEMA_PATH =
    normpath(joinpath(@__DIR__, "..", "respec", "llm_service", "tool_proposal.schema.json"))
const MANIFEST_SCHEMA_PATH =
    normpath(joinpath(@__DIR__, "..", "..", "tools", "monitor", "grid",
                      "repair_verification_manifest.schema.json"))
const TOOL_PROPOSAL_SCHEMA_VERSION = "tool-proposal/1"
const ENVELOPE_VALIDATOR_VERSION   = "envelope-validator/1"   # 모델·프롬프트와 별도로 올린다

read_json(path) = JSON3.read(read(path, String), Dict{String,Any})
file_sha256(path) = bytes2hex(sha256(read(path)))

# ---- JSON Schema 부분집합 검사기 ------------------------------------------------------------
# Python 쪽(jsonschema, Draft 2020-12)과 같은 corpus 로 대조한다: test/fixtures/repair_verification/
# contracts/corpus.json. 이 집합 밖 키워드는 에러 — 모르는 규칙을 통과시키는 것이 가장 나쁘다.
const _SCHEMA_KEYWORDS = Set(["\$schema", "\$id", "\$defs", "\$ref", "\$comment", "title",
    "description", "type", "required", "properties", "additionalProperties", "enum", "const",
    "minimum", "maximum", "exclusiveMinimum", "minLength", "pattern", "items", "minItems",
    "uniqueItems", "minProperties"])

_jtype(x) = x === nothing ? "null" : x isa Bool ? "boolean" : x isa Integer ? "integer" :
            x isa Real ? "number" : x isa AbstractString ? "string" :
            x isa AbstractVector ? "array" : x isa AbstractDict ? "object" : string(typeof(x))
_is_type(t, x) = t == "number" ? _jtype(x) in ("integer", "number") : _jtype(x) == t
# JSON 동치: Bool 은 수가 아니다(Julia 의 `true == 1` 을 막는다), 1 == 1.0 은 같다.
_jeq(a, b) = (a isa Bool || b isa Bool) ? (a isa Bool && b isa Bool && a == b) :
    (a isa AbstractDict && b isa AbstractDict) ?
        (Set(keys(a)) == Set(keys(b)) && all(k -> _jeq(a[k], b[k]), keys(a))) :
    (a isa AbstractVector && b isa AbstractVector) ?
        (length(a) == length(b) && all(_jeq(x, y) for (x, y) in zip(a, b))) :
    (a isa Real && b isa Real) ? a == b : isequal(a, b)

"""
    schema_error(x, schema) -> Union{Nothing,String}

첫 위반을 `"<json-path>:<keyword>[:detail]"` 로 돌려준다. 통과면 `nothing`.
"""
schema_error(x, schema::AbstractDict) = _schema_error(x, schema, schema, "")

function _schema_error(x, s::AbstractDict, root, path)
    for k in keys(s)
        k in _SCHEMA_KEYWORDS ||
            error("schema keyword `$(k)` at `$(path)` is not supported by RepairTypes.schema_error")
    end
    if haskey(s, "\$ref")
        r = s["\$ref"]
        startswith(r, "#/\$defs/") || error("unsupported \$ref `$(r)`")
        return _schema_error(x, root["\$defs"][r[9:end]], root, path)
    end
    p = isempty(path) ? "/" : path
    if haskey(s, "type")
        ts = s["type"] isa AbstractVector ? s["type"] : [s["type"]]
        any(t -> _is_type(t, x), ts) || return "$(p):type:expected $(join(ts, "|")) got $(_jtype(x))"
    end
    haskey(s, "const") && !_jeq(x, s["const"]) && return "$(p):const"
    haskey(s, "enum") && !any(e -> _jeq(x, e), s["enum"]) && return "$(p):enum:$(repr(x))"
    if x isa Real && !(x isa Bool)
        haskey(s, "minimum") && x < s["minimum"] && return "$(p):minimum"
        haskey(s, "maximum") && x > s["maximum"] && return "$(p):maximum"
        haskey(s, "exclusiveMinimum") && x <= s["exclusiveMinimum"] && return "$(p):exclusiveMinimum"
    end
    if x isa AbstractString
        haskey(s, "minLength") && length(x) < s["minLength"] && return "$(p):minLength"
        haskey(s, "pattern") && !occursin(Regex(s["pattern"]), x) && return "$(p):pattern"
    end
    if x isa AbstractVector
        haskey(s, "minItems") && length(x) < s["minItems"] && return "$(p):minItems"
        get(s, "uniqueItems", false) === true &&
            any(_jeq(x[i], x[j]) for i in eachindex(x) for j in eachindex(x) if i < j) &&
            return "$(p):uniqueItems"
        if haskey(s, "items")
            for (i, v) in enumerate(x)
                e = _schema_error(v, s["items"], root, "$(path)/$(i - 1)")
                e === nothing || return e
            end
        end
    end
    if x isa AbstractDict
        for r in get(s, "required", String[])
            haskey(x, r) || return "$(p):required:$(r)"
        end
        haskey(s, "minProperties") && length(x) < s["minProperties"] && return "$(p):minProperties"
        props = get(s, "properties", Dict{String,Any}())
        for k in sort!(collect(keys(x)))
            if haskey(props, k)
                e = _schema_error(x[k], props[k], root, "$(path)/$(k)")
                e === nothing || return e
            elseif get(s, "additionalProperties", true) === false
                return "$(p):additionalProperties:$(k)"
            end
        end
    end
    return nothing
end

# ---- 지문 --------------------------------------------------------------------------------
"""
checkpoint·certificate·manifest 가 싣는 지문. 전부 필수 — 모르는 값은 호출자가 `"none"` 처럼
**명시적으로** 적는다(빈 문자열은 거절). 모델 쪽(`model`…`schema_digest`)과 신뢰 쪽
(`validator_version`·`scorer_version`·`capability_contract_version`)은 따로 올라간다.
"""
Base.@kwdef struct Fingerprints
    code_rev::String
    code_dirty_digest::String
    dirty_snapshot_digest::String
    config_digest::String
    julia_version::String
    manifest_digest::String
    build_id::String
    julia_threads::Int
    solver_name::String
    solver_version::String
    solver_seed::Int
    solver_threads::Int
    model::String
    service_code_fingerprint::String
    prompt_digest::String
    schema_digest::String
    validator_version::String
    scorer_version::String
    capability_contract_version::String
    function Fingerprints(a...)
        for (f, v) in zip(fieldnames(Fingerprints), a)
            v isa AbstractString && isempty(v) && throw(ArgumentError("Fingerprints.$(f) is empty"))
        end
        new(a...)
    end
end

"다른 지문 필드 이름들. 비어 있으면 같은 세계/도구/검사기다."
fingerprint_mismatches(a::Fingerprints, b::Fingerprints) =
    Symbol[f for f in fieldnames(Fingerprints) if getfield(a, f) != getfield(b, f)]

# ---- 실행 권한(capability) 계약 -------------------------------------------------------------
"""
원본 의미(보호)와 변경 가능한 runtime 구조를 가른 계약(설계 §4.2). **graph 수정 전체를 금지하지
않는다** — 임시 edge·배정·보조 노드는 `mutable_runtime` 이고 T5 의 효과 검사가 의미로 판정한다.

`forbidden_api` 는 host/런타임 탈출 이름의 **어휘적** 목록이다. 판정 규칙은 `api_hits` 에 있다
(맨 이름·모듈 한정 이름·동적 이름 구성만 — 필드 접근 `m.schedule`·로그 문자열은 안 본다).
경계가 아니다: 문자열 조립(`Symbol("r"*"un")`)은 못 잡는다. 실제 경계는 T4 의 OS 권한 제거다.
`adapter_mediated` 는 거절이 아니다 — 시간 진행은 trusted engine adapter 로 중재된다(설계 §6.1).
"""
struct CapabilityContract
    version::String
    protected::Vector{Symbol}
    mutable_runtime::Vector{Symbol}
    forbidden_api::Vector{Symbol}
    adapter_mediated::Vector{Symbol}
end

const DEFAULT_CAPABILITY_CONTRACT = CapabilityContract(
    "capability-contract/1",
    # 보호: 필수 제품·작업·물리 선행조건, 자원 의미, 원본 존·사건·완료, 물리 상태·시간, 코드·실행기
    Symbol[:required_products, :required_tasks, :physical_preconditions, :assembly_relations,
           :resource_conservation, :zones, :events, :completion_status, :scorer,
           :clock, :sim_budget, :robot_pose_without_engine, :runtime_methods, :sensors,
           :validator, :zone_repair_base_ablation],
    # 변경 가능(검사 대상): 배정·팀, 보조 노드, 임시 edge·실행 순서, 자원 예약/요청, 작업 위치·기하
    Symbol[:task_assignment, :team_composition, :auxiliary_nodes, :temporary_edges,
           :runtime_schedule_order, :resource_reservation, :resource_requests,
           :staging_geometry, :work_positions, :route_parameters],
    Symbol[
        # 코드 실행·정의 탈출
        :eval, Symbol("@eval"), :Core, :Main, :Meta, :include, :include_string, :evalfile,
        # native·메모리
        :ccall, Symbol("@ccall"), :cglobal, :llvmcall, :Libc, :Libdl, :dlopen,
        :unsafe_load, :unsafe_store!, :unsafe_wrap, :unsafe_pointer_to_objref, :pointer_from_objref,
        # host 프로세스·파일·네트워크·자격 증명
        :run, :pipeline, Symbol("@cmd"), :Cmd, :kill, :exit, :ENV, :homedir, :cd,
        :open, :read, :readline, :readlines, :readdir, :write, :rm, :mv, :cp, :mkdir, :mkpath,
        :touch, :chmod, :chown, :symlink, :tempname, :mktemp, :mktempdir, :download,
        :Sockets, :Distributed, :addprocs, Symbol("@everywhere"), :HTTP, :PyCall, :pyimport,
        # 지속 callback·동시성 (재현·효과 관측 불가)
        :Timer, :Task, :schedule, Symbol("@async"), Symbol("@spawn"), Symbol("@threads"),
        :Threads, :atexit, :finalizer],
    Symbol[:step_environment!, :simulate!])

# 한정 이름의 왼쪽이 이것이면 모듈 접근으로 본다(`Base.run`·`Base.Filesystem.rm`).
const _MODULE_NAMES = Set([:Base, :Core, :Main, :Libc, :Libdl, :Sys, :Meta, :Filesystem, :Threads,
    :Sockets, :Distributed, :Pkg, :InteractiveUtils, :ConstructionBots, :CB])

"""
`code` 안의 `names`. 잡는 것은 셋뿐이다:
 1. 맨 이름 `run(…)`·`ENV`·`@eval`;
 2. 모듈 한정 이름 `Base.run`·`Base.Filesystem.rm`(왼쪽이 `_MODULE_NAMES` 에서 시작);
 3. 동적 이름 구성 — `Symbol("run")` 의 문자열 인자, `getfield/getproperty(<모듈>, :run|"run")`.
필드 접근(`m.schedule`·`robot.Task`), 로그 문자열(`@warn "read"`), 일반 `:sym` 리터럴은 안 잡는다 —
그것까지 잡으면 `mutable_runtime`(배정의 `schedule` 필드 등)을 만지는 합법 도구가 거절돼 K 를 태운다.
"""
function api_hits(code::AbstractString, names::Vector{Symbol})
    hits = Symbol[]
    strs = Dict(string(n) => n for n in names)   # `Symbol(x)` 는 NUL 든 문자열에서 던진다
    lit(x) = x isa QuoteNode ? lit(x.value) : x isa Symbol ? (x in names && push!(hits, x)) :
             x isa AbstractString ? (haskey(strs, x) && push!(hits, strs[x])) : nothing
    ismod(x) = x isa Symbol ? x in _MODULE_NAMES :
               x isa Expr && x.head === :. && length(x.args) == 2 && ismod(x.args[1])
    callee(f) = f isa Symbol ? f :
                f isa Expr && f.head === :. && length(f.args) == 2 && f.args[2] isa QuoteNode ? f.args[2].value : nothing
    function walk(x)
        x isa Symbol && return (x in names && push!(hits, x); nothing)
        x isa Expr || return nothing
        foreach(walk, x.args)          # QuoteNode·문자열은 여기서 안 잡힌다
        if x.head === :. && length(x.args) == 2 && x.args[2] isa QuoteNode
            ismod(x.args[1]) && lit(x.args[2])
        elseif x.head === :call && !isempty(x.args)
            f = callee(x.args[1])
            f === :Symbol && foreach(lit, x.args[2:end])
            f in (:getfield, :getproperty) && length(x.args) >= 3 && ismod(x.args[2]) && lit(x.args[3])
        end
        return nothing
    end
    walk(Meta.parseall(code))
    return unique!(hits)
end

# ---- 결과 어휘 ---------------------------------------------------------------------------
# 검사 판정. `requires_runtime` 은 거절이 아니다(preflight 가 첫 engine 진행 직전에 멈춤, §6.1).
# `unsupported` = 검증기가 그 효과를 모른다(모델 실패와 구분). `noop_equivalent` = 실제 상태·예약·
# trace 가 비었다. `certification_unavailable` = 복원·관측·지문이 보장을 못 받친다.
const VALIDATION_VERDICTS = (:accept, :reject, :unsupported, :noop_equivalent,
                             :requires_runtime, :certification_unavailable)
const VALIDATION_STAGES   = (:envelope, :capability, :source, :effects, :task_contract)
const EFFECT_CLASSES      = (:geometry, :assignment, :schedule_graph, :resource, :other)
const ROLLOUT_OUTCOMES    = (:COMPLETE, :FAIL_WITHIN_BUDGET, :UNKNOWN)
# `:contract_violation`(T4) = 분기가 끝까지 돌았지만 pi0/예산 계약 밖에서 돌았다(ablation 해제·존 비-NOOP·
# 예산 변경·지평 초과) — 정의된 실험의 결과가 아니므로 모른다(`BranchRunner.validate_branch` 가 사유를 싣는다).
const UNKNOWN_CAUSES      = (:wall_timeout, :worker_crash, :solver_error, :provider_error,
                             :identity_mismatch, :resource_limit, :contract_violation)
const TERMINAL_REASONS    = (:project_complete, :no_progress_limit, :max_sim_steps, :none)
const ENACTMENT_STATUSES  = (:enacted, :threw, :partial, :timeout, :unobservable,
                             :registration_rejected, :requires_runtime)
const SELECTIONS          = (:noop, :tool)
const SELECTION_CLASSES   = (:baseline_complete, :rescued, :unsolved, :certification_unavailable)
# 후보 하나의 선택용 결과(T7). `:COMPLETE` = rollout COMPLETE **이고** 효과·원본 계약까지 통과(`judge_candidate(...).eligible`).
# `:REJECTED` = 끝까지 못 갔거나(제안 문 거절·폐기) COMPLETE 인데 검사에서 떨어짐. rollout COMPLETE 만으로는 `:COMPLETE` 가 아니다.
const CANDIDATE_OUTCOMES  = (:COMPLETE, :FAIL_WITHIN_BUDGET, :UNKNOWN, :REJECTED)
const COMMIT_STATUSES     = (:committed, :aborted_resumed_noop, :replay_mismatch)
# 설계 §5 의 checkpoint 블록. 빠진 블록이 있으면 인증 불가다.
const CHECKPOINT_BLOCKS   = (:model_code, :task_world, :execution, :globals, :native,
                             :events_rng, :ledger_boundary)
# 팔별 제안 형식(§9.2). 🔴 주 팔 U1/U4/V4 는 일반 ToolProposal 이다 — 함수를 수치 geometry patch 로
# 바꾸는 경로는 없다. GeometryPatch 는 보조 G4 에만 있고 그 schema/adapter 는 T9 가 만든다.
const ARM_PROPOSAL_FORMAT = Dict(:B0 => :none, :L0 => :historical_body, :L1 => :historical_body,
    :U1 => :tool_proposal, :U4 => :tool_proposal, :V4 => :tool_proposal,
    :G4 => :geometry_patch_auxiliary)

_need(ok, msg) = ok || throw(ArgumentError(msg))
_in(x, set, what) = _need(x in set, "$(what)=$(repr(x)) not in $(set)")

# ---- 타입 --------------------------------------------------------------------------------
struct CallSpec
    primitive::String
    args::Dict{String,Any}      # `{}` 이 정상이다 — body 가 env 센서로 대상을 스스로 찾는다
end

"""
생성 도구 하나. `impl_code` + `calls` 가 실행의 실체이고 `claimed_effects` 는 참고다 — 어떤 검사도
그것으로 범위를 좁히거나 권한을 주지 않는다. 필드 이름은 현행 합성 기록과 같다
(`synthesize.py` 의 `tool_name`·`impl_name`·`impl_code`·`params`·`calls`·`surface`·`reversible`,
`specification.mechanism`/`.params` = Design 의 `mechanism`/`spec_params`).
"""
struct ToolProposal
    schema_version::String
    checkpoint_id::String
    proposal_id::String
    parent_proposal_id::Union{Nothing,String}
    submission_index::Int
    tool_name::String
    specification::Dict{String,Any}
    impl_name::String
    impl_code::String
    params::Dict{String,Any}
    calls::Vector{CallSpec}
    claimed_effects::Vector{String}
    surface::String             # 없으면 register_minted_primitive! 의 기본값과 같은 "unknown"
    reversible::Bool            # 없으면 register_minted_primitive! 의 기본값과 같은 false
    provenance::Dict{String,Any}  # record_id·response_id·run_ctx 등 감사용
end

struct ValidationReport
    stage::Symbol
    verdict::Symbol
    proposal_id::Union{Nothing,String}
    reasons::Vector{String}
    validator_version::String
    effect_classes::Vector{Symbol}   # 실제 diff/trace 에서 유도(T5). 모델 선언이 아니다
    adapter_calls::Vector{Symbol}    # trusted engine adapter 로 중재할 호출
    # 이 판정이 **보지 못한** 것(T5 fix): 검사 경계 밖이라 accept 여도 보장하지 않는 항목. 비어 있으면 "주장 없음" 이
    # 아니라 그 단계가 관측 경계를 선언하지 않았다는 뜻이다(봉투 단계 등).
    unobserved::Vector{String}
    function ValidationReport(stage, verdict, proposal_id, reasons, validator_version,
                              effect_classes = Symbol[], adapter_calls = Symbol[], unobserved = String[])
        _in(stage, VALIDATION_STAGES, "stage")
        _in(verdict, VALIDATION_VERDICTS, "verdict")
        _need(verdict === :accept || !isempty(reasons), "non-accept verdict needs a reason")
        foreach(c -> _in(c, EFFECT_CLASSES, "effect_class"), effect_classes)
        new(stage, verdict, proposal_id, reasons, validator_version, effect_classes, adapter_calls, unobserved)
    end
end

"""
전체 checkpoint 의 **봉투**(내용은 T2 가 채운다). `artifact_sha256` 은 정확한 직렬화 digest 다 —
`SimState.state_hash`·반올림 해시를 여기 넣지 말 것(설계 §5).
"""
struct EpisodeCheckpoint
    checkpoint_id::String
    t0_hook::String                          # 어느 hook 경계에서 잡았나
    zone_dispatch_in_progress::Bool
    fingerprints::Fingerprints
    artifact_path::String
    artifact_sha256::String
    block_sha256::Dict{Symbol,String}        # 키 ⊆ CHECKPOINT_BLOCKS
    pre_injection_sha256::String
    post_injection_sha256::String
    uncertifiable::Vector{String}            # 직렬화 못 한 상태 등. 비지 않으면 인증 불가
    function EpisodeCheckpoint(id, hook, zdip, fp, apath, asha, blocks, pre, post, unc)
        _need(!isempty(id), "checkpoint_id is empty")
        foreach(k -> _in(k, CHECKPOINT_BLOCKS, "checkpoint block"), keys(blocks))
        new(id, hook, zdip, fp, apath, asha, blocks, pre, post, unc)
    end
end

"인증 불가 사유. 빠진 블록도 사유다 — 비어 있어야 인증 가능."
certification_gaps(cp::EpisodeCheckpoint) =
    vcat(cp.uncertifiable,
         ["missing checkpoint block: $(b)" for b in CHECKPOINT_BLOCKS if !haskey(cp.block_sha256, b)])

struct EnactmentReport
    proposal_id::String
    checkpoint_id::String
    worker_id::String
    status::Symbol
    exception::Union{Nothing,String}
    effect_trace::Vector{Dict{String,Any}}   # 신뢰 감사 경로의 기록
    body_changes::Vector{String}
    harness_changes::Vector{String}
    sim_steps::Int
    wall_s::Float64
    cpu_s::Float64
    post_state_sha256::Union{Nothing,String}
    function EnactmentReport(pid, cid, wid, status, exc, trace, body, harness, steps, wall, cpu, post)
        _in(status, ENACTMENT_STATUSES, "enactment status")
        _need(status !== :threw || exc !== nothing, ":threw needs the exception text")
        _need(status !== :enacted || post !== nothing, ":enacted needs post_state_sha256")
        new(pid, cid, wid, status, exc, trace, body, harness, steps, wall, cpu, post)
    end
end

"""
분기 하나의 종료 결과. `UNKNOWN` ⟺ 원인 있음. wall timeout 은 simulation 실패가 아니라 UNKNOWN 이다.
`COMPLETE` 는 terminal 이 `:project_complete` 여야 한다(`closed == total` 로 판정하지 않는다).
`zone_ladder_fired` 는 pi0 에서 0 이어야 하므로 **센 값**을 싣는다.
"""
struct RolloutReport
    branch::String                 # "noop" 또는 proposal_id
    checkpoint_id::String
    outcome::Symbol
    unknown_cause::Union{Nothing,Symbol}
    terminal_reason::Symbol
    sim_steps::Int
    wall_s::Float64
    cpu_s::Float64
    zone_ladder_fired::Int
    general_recovery::Dict{String,Int}
    function RolloutReport(branch, cid, outcome, cause, term, steps, wall, cpu, ladder, recov)
        _in(outcome, ROLLOUT_OUTCOMES, "outcome")
        _in(term, TERMINAL_REASONS, "terminal_reason")
        _need((outcome === :UNKNOWN) == (cause !== nothing), "UNKNOWN iff unknown_cause is set")
        cause === nothing || _in(cause, UNKNOWN_CAUSES, "unknown_cause")
        _need(outcome !== :COMPLETE || term === :project_complete, "COMPLETE needs :project_complete")
        _need(outcome !== :FAIL_WITHIN_BUDGET || term in (:no_progress_limit, :max_sim_steps),
              "FAIL_WITHIN_BUDGET needs a budget terminal")
        new(branch, cid, outcome, cause, term, steps, wall, cpu, ladder, recov)
    end
end

"""
선택 결과(설계 §7.2 표). `:tool` ⟺ `:rescued` ⟺ `selected_proposal_id` 있음.
`raw_regressions` = 기준이 COMPLETE 인데 실패한 후보 id(숨기지 않는다).
"""
struct SelectionReport
    checkpoint_id::String
    baseline_outcome::Symbol
    selected::Symbol
    selected_proposal_id::Union{Nothing,String}
    classification::Symbol
    raw_regressions::Vector{String}
    candidate_outcomes::Dict{String,Symbol}
    reasons::Vector{String}
    function SelectionReport(cid, base, sel, spid, cls, regs, cands, reasons)
        _in(base, ROLLOUT_OUTCOMES, "baseline_outcome")
        _in(sel, SELECTIONS, "selected")
        _in(cls, SELECTION_CLASSES, "classification")
        _need((sel === :tool) == (spid !== nothing) == (cls === :rescued),
              ":tool iff selected_proposal_id iff :rescued")
        _need((cls === :baseline_complete) == (base === :COMPLETE), ":baseline_complete iff baseline COMPLETE")
        _need(cls !== :certification_unavailable || base === :UNKNOWN,
              ":certification_unavailable needs baseline UNKNOWN")
        _need(cls !== :unsolved && cls !== :rescued || base === :FAIL_WITHIN_BUDGET,
              ":rescued/:unsolved need baseline FAIL_WITHIN_BUDGET")
        foreach(v -> _in(v, CANDIDATE_OUTCOMES, "candidate outcome"), values(cands))
        # T7: rescued ⟹ 선택된 후보가 (검사까지 통과한) COMPLETE. raw regression ⟹ 기준 COMPLETE 이고 그 후보는 COMPLETE 아님.
        _need(cls !== :rescued || get(cands, spid, nothing) === :COMPLETE, ":rescued needs the selected candidate :COMPLETE")
        _need(isempty(regs) || base === :COMPLETE, "raw_regressions need baseline COMPLETE")
        _need(all(r -> get(cands, r, :COMPLETE) !== :COMPLETE, regs), "a raw regression must be a non-COMPLETE candidate")
        new(cid, base, sel, spid, cls, regs, cands, reasons)
    end
end

struct CommitReport
    checkpoint_id::String
    proposal_id::String
    certificate_sha256::String
    commit_worker_id::String
    status::Symbol
    post_state_match::Union{Nothing,Bool}
    replay_match::Union{Nothing,Bool}
    reasons::Vector{String}
    function CommitReport(cid, pid, cert, wid, status, post, replay, reasons)
        _in(status, COMMIT_STATUSES, "commit status")
        _need(status === :aborted_resumed_noop || post === true, "activation needs post_state_match === true")
        _need(status !== :replay_mismatch || replay === false, ":replay_mismatch needs replay_match === false")
        _need(status === :committed || !isempty(reasons), "non-committed status needs a reason")
        new(cid, pid, cert, wid, status, post, replay, reasons)
    end
end

# ---- 검사 --------------------------------------------------------------------------------
"""
    parse_tool_proposal(raw; checkpoint_id) -> Union{ToolProposal,String}

schema(단일 진실원) → 의미 검사 → 타입. 거절은 `"reject:<code>:…"`:
`malformed_envelope`(schema) · `stale_checkpoint` · `calls_disagree_with_body`(현행 enact 와 같은
사유 이름) · `self_parent`.
"""
function parse_tool_proposal(raw::AbstractDict; checkpoint_id::AbstractString,
                             schema = read_json(TOOL_PROPOSAL_SCHEMA_PATH))
    e = schema_error(raw, schema)
    e === nothing || return "reject:malformed_envelope:$(e)"
    raw["checkpoint_id"] == checkpoint_id ||
        return "reject:stale_checkpoint:$(raw["checkpoint_id"]) != $(checkpoint_id)"
    parent = get(raw, "parent_proposal_id", nothing)
    parent == raw["proposal_id"] && return "reject:self_parent:$(parent)"
    calls = CallSpec[CallSpec(c["primitive"], c["args"]) for c in raw["calls"]]
    cnames = [c.primitive for c in calls]
    cnames == [raw["impl_name"]] ||
        return "reject:calls_disagree_with_body: calls=[$(join(cnames, ", "))] body=[$(raw["impl_name"])]"
    return ToolProposal(raw["schema_version"], raw["checkpoint_id"], raw["proposal_id"], parent,
        raw["submission_index"], raw["tool_name"], raw["specification"], raw["impl_name"],
        raw["impl_code"], raw["params"], calls, get(raw, "claimed_effects", String[]),
        get(raw, "surface", "unknown"), get(raw, "reversible", false),
        get(raw, "provenance", Dict{String,Any}()))
end

"""
    validate_tool_proposal(raw, contract; checkpoint_id) -> ValidationReport

설계 §4 의 이름. 봉투 + 실행 권한(어휘적)만 본다 — source 규약·등록·효과는 T5/T6 이다.
`claimed_effects` 는 읽지 않는다.
"""
function validate_tool_proposal(raw::AbstractDict, contract::CapabilityContract = DEFAULT_CAPABILITY_CONTRACT;
                                checkpoint_id::AbstractString)
    pid = get(raw, "proposal_id", nothing)
    pid isa AbstractString || (pid = nothing)
    p = parse_tool_proposal(raw; checkpoint_id = checkpoint_id)
    p isa String && return ValidationReport(:envelope, :reject, pid, [p], ENVELOPE_VALIDATOR_VERSION)
    hits = api_hits(p.impl_code, contract.forbidden_api)
    isempty(hits) || return ValidationReport(:capability, :reject, p.proposal_id,
        ["reject:forbidden_api:$(join(hits, ","))"], ENVELOPE_VALIDATOR_VERSION)
    return ValidationReport(:capability, :accept, p.proposal_id, String[], ENVELOPE_VALIDATOR_VERSION,
        Symbol[], api_hits(p.impl_code, contract.adapter_mediated))
end

"""
    validate_repair_manifest(m) -> Union{Nothing,String}

통과면 `nothing`. 예산 위반은 `"reject:budget_invalid:…"`, 나머지는 `"reject:manifest_invalid:…"`.
`m` 을 바꾸지 않는다(기본값 보완 없음).
"""
function validate_repair_manifest(m::AbstractDict; schema = read_json(MANIFEST_SCHEMA_PATH))
    e = schema_error(m, schema)
    e === nothing && return nothing
    return (startswith(e, "/budget") || e == "/:required:budget") ?
        "reject:budget_invalid:$(e)" : "reject:manifest_invalid:$(e)"
end

end # module RepairTypes
