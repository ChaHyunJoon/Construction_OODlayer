# =============================================================================
# repair_ablation.jl — 존 복구 base ablation (2026-09-23, 명세 docs/superpowers/specs/
#   2026-09-23-zone-repair-base-ablation-design.md). 사람이 쓴 존 복구 해법·실행부를 LLM 과 자동 복구
#   경로 모두에서 뺀다. 네 층(광고·등록·실행 가드·사다리)이 이 파일 하나를 읽는다.
# 🔴 export 하지 않는다 — export 하면 세계 인터페이스에 실려 모델이 이 기계장치를 본다.
# =============================================================================

const REPAIR_ABLATION_LEVELS = (:none, :translate, :all)

const _ABLATE_TRANSLATE = Symbol[
    :translate_whole_build!, :_apply_uniform_translation!, :_find_min_translation,
    :_find_clear_translation, :_minimum_clear_translation, :zone_relocatable,
    :core_zone_for_severity, :zone_diagnosis, :zone_diagnoses]
const _ABLATE_ALL = vcat(_ABLATE_TRANSLATE,
    Symbol[:find_clear_staging_center, :restage_assembly!, :restage_all_blocked!])

"레벨의 차단 목록. 모르는 레벨은 에러다(조용히 `none` 으로 안 떨어진다)."
function ablated_names(level::Symbol)
    level === :none      && return Symbol[]
    level === :translate && return _ABLATE_TRANSLATE
    level === :all       && return _ABLATE_ALL
    error("repair_ablation: unknown level $(repr(level)); allowed: none, translate, all")
end

function parse_repair_ablation(s::AbstractString)
    s in ("none", "translate", "all") ||
        error("REPAIR_ABLATION=$(repr(s)) — allowed exactly: none, translate, all")
    return Symbol(s)
end

repair_ablation_from_env(env = ENV) =
    parse_repair_ablation(haskey(env, "REPAIR_ABLATION") ? env["REPAIR_ABLATION"] : "none")

const REPAIR_ABLATION = Ref{Symbol}(:none)
const _ABLATION_ARMED = Ref(false)
const _ABLATION_EXEMPT_DEPTH = Ref(0)
const _ABLATION_COUNTS = Ref(Dict{String,Int}())

set_repair_ablation!(level::Symbol) = (ablated_names(level); REPAIR_ABLATION[] = level; nothing)
arm_repair_ablation!() = (_ABLATION_COUNTS[] = Dict{String,Int}(); _ABLATION_ARMED[] = true; nothing)
disarm_repair_ablation!() = (_ABLATION_ARMED[] = false; nothing)
repair_ablation_armed() = _ABLATION_ARMED[]
_ablation_bump!(key::String) = (d = _ABLATION_COUNTS[]; d[key] = get(d, key, 0) + 1; nothing)
ablation_counts() = copy(_ABLATION_COUNTS[])
ablation_blocks_zone_ladder() = _ABLATION_ARMED[] && REPAIR_ABLATION[] !== :none

struct AblatedPrimitiveError <: Exception
    name::Symbol
    level::Symbol
end
Base.showerror(io::IO, e::AblatedPrimitiveError) =
    print(io, "AblatedPrimitiveError: `", e.name, "` is not available in this world (repair_ablation=",
          e.level, ")")

"차단 함수의 **첫 줄**. 무장 전·목록 밖·면제 안이면 무동작이다."
function _ablation_gate(name::Symbol)
    _ABLATION_ARMED[] || return nothing
    name in ablated_names(REPAIR_ABLATION[]) || return nothing
    _ABLATION_EXEMPT_DEPTH[] > 0 && return nothing
    _ablation_bump!("denied:$(name)")
    _ablation_bump!("denied_by:$(_ablation_caller())")
    throw(AblatedPrimitiveError(name, REPAIR_ABLATION[]))
end

"가드 바깥의 첫 프레임 — 누가 차단 함수를 불렀는가(주조 body 는 file 이 `none`/`string` 으로 나온다)."
function _ablation_caller()
    for fr in stacktrace()
        f = basename(String(fr.file))
        f in ("repair_ablation.jl", "restage_zone.jl", "zone_diagnosis.jl") && continue
        return string(fr.func, "@", f, ":", fr.line)
    end
    return "unknown"
end

"LLM 에 안 보이는 경로의 명시적 면제. 무장돼 있으면 레벨과 무관하게 센다."
function ablation_exempt(f, site::Symbol)
    _ABLATION_ARMED[] && _ablation_bump!("exempt:$(site)")
    _ABLATION_EXEMPT_DEPTH[] += 1
    try
        return f()
    finally
        _ABLATION_EXEMPT_DEPTH[] -= 1
    end
end

"판 끝의 한 줄. 0 이어도 항상 같은 키를 찍는다(조용한 0 방지)."
function ablation_summary_line()
    d = _ABLATION_COUNTS[]
    nd = sum((v for (k, v) in d if startswith(k, "denied:")); init = 0)
    ne = sum((v for (k, v) in d if startswith(k, "exempt:")); init = 0)
    detail = join(("$(k)=$(v)" for (k, v) in sort!(collect(d); by = first)), ",")
    return string("level=", REPAIR_ABLATION[], " armed=", _ABLATION_ARMED[], " denied=", nd,
                  " exempt=", ne, " ladder_zone_skipped=", get(d, "ladder_zone_skipped", 0),
                  " ladder_zone_fired=", get(d, "ladder_zone_fired", 0), " detail=", detail)
end
