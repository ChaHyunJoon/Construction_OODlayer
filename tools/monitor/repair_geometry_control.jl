# =============================================================================
# repair_geometry_control.jl — 보조 G4 팔의 trusted adapter (T9, 설계 2026-09-24 §9.2).
#
# G4 = 기하 전용 안내 + GeometryPatch(`src/respec/llm_service/geometry_patch.schema.json`). 주 팔 U1/U4/V4 는 이 파일을
# 전혀 안 거친다 — 일반 ToolProposal 을 그대로 집행한다.
#
# 두 조각, 두 프로세스:
#   * `geometry_context(env, CB)` — CB 를 실은 **일회용 observe worker**(t0 복원)에서: 이름 붙일 수 있는 staging 구성의
#     **현재** 전역 위치·staging 반경·완료 여부와 존(key·center·radius). 🔴 추천 좌표·필요 이동량·빈 자리는 계산하지 않는다
#     (`_find_min_translation`·`find_clear_staging_center` 같은 해법 함수를 안 부른다).
#   * `patch_to_proposal(patch, context; checkpoint_id)` — CB 없는 driver 에서: schema 검사(`RepairTypes.schema_error`, 같은
#     부분집합 검사기) → config_ref 가 그 문맥에 있는지 → 모델이 낸 (ref, x, y) 를 **숫자 그대로** 박은 고정 body 를 가진
#     ToolProposal. 그 body 는 엔진 API(`set_desired_global_transform!`)로 각 구성을 제출된 절대 XY 로 옮기고(회전·높이 보존),
#     실제로 움직인 조립체의 staging 원을 **같은 측정 변위**만큼 옮긴다(같은 위치의 두 표현을 맞춘다 — 새 좌표를 고르지 않는다).
#     이후는 주 팔과 **같은** 봉투다: 격리 worker 등록·집행, 실제 효과 판별 → 기하 변경이면 공통 resync·잔차 검사,
#     같은 원본 task contract, 같은 전체 rollout·선택기(`ToolExecution.execute_tool_isolated` → `RepairSupervisor`).
# =============================================================================
isdefined(Main, :RepairTypes) || include(joinpath(@__DIR__, "..", "..", "src", "verification", "repair_types.jl"))

module RepairGeometryControl

using JSON3, SHA
import ..RepairTypes as R

const ADAPTER_VERSION = "repair-geometry-control/1"
const GEOMETRY_PATCH_SCHEMA_VERSION = "geometry-patch/1"
const GEOMETRY_PATCH_SCHEMA_PATH =
    normpath(joinpath(@__DIR__, "..", "..", "src", "respec", "llm_service", "geometry_patch.schema.json"))
"config_ref 로 받는 문자열 모양(`string(::AssemblyID)` = `AssemblyID(3)` 류). body 에 문자열 리터럴로 박히므로 좁게 둔다."
const REF_RE = r"^[A-Za-z0-9_.{}()]+$"

"""
    geometry_context(env, CB) -> Dict

G4 의 직접 기하 입력(CB 프로세스). `configs` = staging 원이 있는 조립체마다 `AssemblyComplete` 의 start_config 전역 XY·
staging 반경·그 노드의 완료 여부, `zones` = 살아 있는 존의 key·center·radius(`open_zone_descriptors` 중 그 셋만).
"""
function geometry_context(env, CB)
    configs = Dict{String,Any}[]
    for aid in sort!(collect(keys(env.staging_circles)); by = string)
        n = CB.get_node(env.sched, CB.AssemblyComplete(CB.get_node(env.scene_tree, aid)))
        g = CB.global_transform(CB.start_config(n)).translation
        closed = try CB.get_vtx(env.sched, CB.node_id(n)) in env.cache.closed_set catch; nothing end
        push!(configs, Dict{String,Any}("config_ref" => string(aid), "x" => Float64(g[1]), "y" => Float64(g[2]),
            "staging_radius" => Float64(CB.get_radius(env.staging_circles[aid])), "closed" => closed))
    end
    zones = [Dict{String,Any}("key" => z["key"], "center" => z["center"], "radius" => z["radius"])
             for z in CB.open_zone_descriptors(env)]
    return Dict{String,Any}("schema" => "geometry-context/1", "adapter_version" => ADAPTER_VERSION,
                            "configs" => configs, "zones" => zones)
end

const BODY_TEMPLATE = raw"""
function __NAME__(env)
    W = Tuple{String,Float64,Float64}[__WRITES__]
    tf(aid) = start_config(get_node(env.sched, AssemblyComplete(get_node(env.scene_tree, aid))))
    before = Dict(aid => global_transform(tf(aid)).translation for aid in keys(env.staging_circles))
    for (ref, x, y) in W
        hit = [a for a in keys(env.staging_circles) if string(a) == ref]
        length(hit) == 1 || error("geometry patch: config_ref $(ref) does not name exactly one staging configuration")
        t = tf(hit[1])
        g = global_transform(t)
        set_desired_global_transform!(t, CoordinateTransformations.Translation(x - g.translation[1], y - g.translation[2], 0.0) ∘ g)
    end
    for aid in collect(keys(env.staging_circles))
        d = global_transform(tf(aid)).translation .- before[aid]
        (d[1] == 0.0 && d[2] == 0.0) && continue
        b = env.staging_circles[aid]
        env.staging_circles[aid] = LazySets.Ball2(Vector{Float64}(get_center(b)[1:2]) .+ [d[1], d[2]], Float64(get_radius(b)))
    end
    return (; status = :success)
end
"""

"모델이 낸 (ref, x, y) 를 그대로 박은 body source. 숫자는 `repr(Float64)` — 반올림도 보정도 없다."
render_body(name::AbstractString, writes) =
    replace(replace(BODY_TEMPLATE, "__NAME__" => name),
            "__WRITES__" => join(("($(repr(r)), $(repr(x)), $(repr(y)))" for (r, x, y) in writes), ", "))

_reject(why) = (; proposal = nothing, reasons = ["reject:geometry_patch:" * why])

"""
    patch_to_proposal(patch, context; checkpoint_id) -> (; proposal::Union{Nothing,Dict}, reasons::Vector{String})

GeometryPatch → ToolProposal(일반 봉투). 거절이면 `proposal = nothing` 과 t0 에서 정해진 정적 사유(`reject:geometry_patch:…`)
— 그 사유는 G4 의 수정 호출로 되먹일 수 있다. 모델 도장(`provenance`)은 그대로 옮기고 `arm = "G4"`·원본 patch·adapter 판을 더한다.
"""
function patch_to_proposal(patch::AbstractDict, context::AbstractDict; checkpoint_id::AbstractString)
    e = R.schema_error(patch, R.read_json(GEOMETRY_PATCH_SCHEMA_PATH))
    e === nothing || return _reject("malformed:$(e)")
    patch["checkpoint_id"] == checkpoint_id || return _reject("stale_checkpoint:$(patch["checkpoint_id"]) != $(checkpoint_id)")
    known = Set(String(c["config_ref"]) for c in get(context, "configs", Any[]))
    writes = Tuple{String,Float64,Float64}[]
    for w in patch["writes"]
        ref = String(w["config_ref"])
        occursin(REF_RE, ref) && ref in known || return _reject("unknown_config_ref:$(repr(ref)) is not in the geometry context")
        x, y = Float64(w["xy"]["x"]), Float64(w["xy"]["y"])
        isfinite(x) && isfinite(y) || return _reject("non_finite_xy:$(ref)")
        push!(writes, (ref, x, y))
    end
    allunique(first.(writes)) || return _reject("duplicate_config_ref: one write per configuration")
    name = "g4_patch_" * bytes2hex(sha256(String(patch["proposal_id"])))[1:12] * "!"
    prov = Dict{String,Any}(String(k) => v for (k, v) in get(patch, "provenance", Dict{String,Any}()))
    prov["arm"] = "G4"
    prov["adapter"] = ADAPTER_VERSION
    prov["geometry_patch"] = Dict{String,Any}(String(k) => v for (k, v) in patch if k != "provenance")
    p = Dict{String,Any}("schema_version" => R.TOOL_PROPOSAL_SCHEMA_VERSION, "checkpoint_id" => checkpoint_id,
        "proposal_id" => String(patch["proposal_id"]), "submission_index" => Int(patch["submission_index"]),
        "tool_name" => "g4_geometry_patch",
        "specification" => Dict{String,Any}("mechanism" => "G4 geometry patch applied by the trusted adapter " *
            "$(ADAPTER_VERSION): the listed staging configurations are set to the submitted global XY (rotation and height preserved)"),
        "impl_name" => name, "impl_code" => render_body(name, writes), "params" => Dict{String,Any}(),
        "calls" => [Dict{String,Any}("primitive" => name, "args" => Dict{String,Any}())],
        "claimed_effects" => String.(get(patch, "claimed_effects", String[])), "surface" => "scene_tree",
        "reversible" => true, "provenance" => prov)
    par = get(patch, "parent_proposal_id", nothing)
    par === nothing || (p["parent_proposal_id"] = String(par))
    return (; proposal = p, reasons = String[])
end

end # module RepairGeometryControl
