# =============================================================================
# tool_proposal.jl — 일반 ToolProposal 의 제안 문(門)과 source 묶음(T5). 설계 §4·§6.1·§6.2 1단계.
#
# 🔴 정적 검사다 — 효과를 **증명하지 않는다**. 통과한 제안도 격리 worker 에서 실제로 돌려 `EffectValidation` 과
#    `TaskContract` 로 판정해야 한다. 이 파일은 도구 이름·기전·호출 목록을 고정하지 않는다(template 목록 없음):
#    생성된 helper·계산·조건 분기·반복을 모두 통과시키고, 거르는 것은 봉투 형식·host/런타임 탈출 이름·차단된 존 복구 base
#    이름뿐이다.
#
# 두 문이 있다 — 어느 프로세스에서 도는지가 다르다:
#   * `gate_proposal`(supervisor — CB 를 **안** 싣는다, T4 성질 유지): T1 봉투·실행 권한(`RepairTypes.validate_tool_proposal`
#     — `api_hits` 의 좁은 규칙) + 존 복구 base ablation 이름 스캔(`src/respec/repair_ablation.jl` 의
#     `ablated_symbols_in`·`ablation_reserved_names` 를 **같은 파일**에서 싣는다 — 목록을 다시 적지 않는다) + source 묶음 digest.
#   * `source_gate`(CB 를 실은 프로세스 — T6 의 worker, 또는 코드를 eval 하지 않는 CB preflight): 현행 등록 규약
#     `check_impl_conventions`(parse·단일 함수·`(env; kw=default)` 시그니처·지어낸 호출/필드 D15·자기 가림 D18·리터럴
#     nothing 키워드 D19·ablation) 을 그대로 부른다. `Core.eval` 은 하지 않는다(그것은 `register_minted_primitive!`, T6).
#
# 두 이름 보행기가 같이 남는 이유(T1 minor "api_hits 가 ablated_symbols_in 을 중복"): T1 fix 1 뒤 둘은 규칙이 **다르다**.
# `api_hits` 는 금지 API 이름이 흔한 필드 이름(`schedule`·`read`·`Task`)과 겹쳐 모듈 한정·동적 구성만 잡도록 좁혔고,
# `ablated_symbols_in` 은 차단 이름이 CB 고유 함수 이름이라 모든 Symbol·QuoteNode·문자열을 잡는다(`getfield(m, :restage_all_blocked!)`
# 처럼 모듈이 변수에 담긴 경우도 잡아야 한다). 한 보행기로 합치면 어느 한쪽이 과차단 또는 누락된다.
# =============================================================================
isdefined(Main, :RepairTypes) || include(joinpath(@__DIR__, "repair_types.jl"))

module ToolProposalGate

using JSON3, SHA
import ..RepairTypes as R

"존 복구 base ablation 목록의 **단일 진실원** — CB 가 include 하는 바로 그 파일을 CB 없이 싣는다."
module AblationNames
include(joinpath(@__DIR__, "..", "respec", "repair_ablation.jl"))
end

const PROPOSAL_GATE_VERSION = "proposal-gate/1"

_canon(x) = x isa AbstractDict ? "{" * join(("$(JSON3.write(string(k))):$(_canon(x[k]))" for k in sort!(collect(keys(x)); by = string)), ",") * "}" :
            x isa AbstractVector ? "[" * join((_canon(v) for v in x), ",") * "]" : JSON3.write(x)

"""
    proposal_binding(p; contract, ablation_level) -> Dict{String,Any}

실행의 실체를 묶는 digest. `proposal_sha256` 은 source·params·calls·이름·checkpoint 를 덮는다 — 같은 digest 면 같은 코드를
같은 인자로 같은 checkpoint 에서 부른다(T7 commit 재생이 대조할 값). `claimed_effects`·`specification`·`provenance` 는
실행에 영향이 없으므로 **넣지 않는다**(설명이 바뀌어도 같은 도구다).
"""
function proposal_binding(p::R.ToolProposal; contract::R.CapabilityContract = R.DEFAULT_CAPABILITY_CONTRACT,
                          ablation_level::Symbol)
    body = Dict{String,Any}("schema_version" => p.schema_version, "checkpoint_id" => p.checkpoint_id,
        "tool_name" => p.tool_name, "impl_name" => p.impl_name, "impl_code" => p.impl_code, "params" => p.params,
        "calls" => [Dict{String,Any}("primitive" => c.primitive, "args" => c.args) for c in p.calls],
        "surface" => p.surface, "reversible" => p.reversible)
    return Dict{String,Any}("proposal_sha256" => bytes2hex(sha256(_canon(body))),
        "source_sha256" => bytes2hex(sha256(p.impl_code)),
        "capability_contract_version" => contract.version, "ablation_level" => String(ablation_level),
        "gate_version" => PROPOSAL_GATE_VERSION)
end

"""
    gate_proposal(raw, contract=DEFAULT_CAPABILITY_CONTRACT; checkpoint_id, ablation_level)
        -> (; report::RepairTypes.ValidationReport, proposal, binding, static_only = true)

supervisor 쪽 문. 거절 사유는 현행 이름과 같다(`reject:malformed_envelope`… T1, `reject:ablated_primitive:<name> — this
function is not available in this world` 은 `check_impl_conventions` 와 **바이트 동일** — 기계장치의 존재를 알리지 않는다).
`step_environment!`·`simulate!` 은 거절이 아니라 `adapter_calls`(trusted engine adapter 로 중재, 설계 §6.1).
`ablation_level` 은 부모 t0 contract 의 pi0(`REPAIR_ABLATION`)에서 온다.
"""
function gate_proposal(raw::AbstractDict, contract::R.CapabilityContract = R.DEFAULT_CAPABILITY_CONTRACT;
                       checkpoint_id::AbstractString, ablation_level::Symbol)
    rep = R.validate_tool_proposal(raw, contract; checkpoint_id)
    rep.verdict === :accept || return (; report = rep, proposal = nothing, binding = nothing, static_only = true)
    p = R.parse_tool_proposal(raw; checkpoint_id)
    denied = AblationNames.ablation_reserved_names(ablation_level)
    if !isempty(denied)
        hits = AblationNames.ablated_symbols_in(Meta.parseall(p.impl_code), denied)
        isempty(hits) || return (; report = R.ValidationReport(:capability, :reject, p.proposal_id,
            ["reject:ablated_primitive:$(first(hits)) — this function is not available in this world"], PROPOSAL_GATE_VERSION),
            proposal = p, binding = nothing, static_only = true)
    end
    b = proposal_binding(p; contract, ablation_level)
    return (; report = R.ValidationReport(:capability, :accept, p.proposal_id, String[], PROPOSAL_GATE_VERSION,
                                          Symbol[], rep.adapter_calls),
            proposal = p, binding = b, static_only = true)
end

"""
    source_gate(p, cb::Module) -> RepairTypes.ValidationReport

현행 등록 규약(`cb.check_impl_conventions`)을 그대로 부른다 — CB 를 실은 프로세스에서만. 세계·`Core.eval` 을 건드리지
않는다(그 함수는 프로세스의 심볼 표만 읽는다). stage `:source`.
"""
function source_gate(p::R.ToolProposal, cb::Module)
    why = cb.check_impl_conventions(p.impl_name, p.impl_code)
    return why === nothing ? R.ValidationReport(:source, :accept, p.proposal_id, String[], PROPOSAL_GATE_VERSION) :
                             R.ValidationReport(:source, :reject, p.proposal_id, [String(why)], PROPOSAL_GATE_VERSION)
end

end # module ToolProposalGate
