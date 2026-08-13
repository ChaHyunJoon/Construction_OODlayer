# ============================================================================
#  목적함수 J 의 단일 진실원 로더 (Julia 쪽). objective.py 와 **같은 수식**을 낸다.
#
#    J(run) = complete ? makespan + w_E * energy_J
#                      : C_fail + C_unclosed * (total - closed) + tie_eps * makespan
#    w_E    = kappa * M_ref / E_ref
#
#  두 구현이 갈리면 오라클 라벨과 Python 분석이 다른 것을 최소화하게 된다 —
#  test_objective.py 가 그 일치를 기계적으로 검사한다.
#
#  ENV 우선순위: MC_COST_FAIL / MC_COST_UNCLOSED 가 있으면 ENV 가 이기고 해시가 갈린다.
# ============================================================================
module Objective

using JSON3
using SHA
using Printf

const OBJECTIVE_PATH = joinpath(@__DIR__, "objective.json")
const ENV_OVERRIDES = ("C_fail" => "MC_COST_FAIL", "C_unclosed" => "MC_COST_UNCLOSED")
const SCALE_KEYS = ("kappa", "M_ref", "E_ref")

# 미완주 분기가 쓰는 상수 — null 이면 그 분기를 계산할 수 없다 (M-5: MethodError 로 새지 않게).
const INCOMPLETE_KEYS = ("C_fail", "C_unclosed", "tie_eps")

# objective_hash() 가 실제로 해싱하는 J-정의 스칼라 8개, 정렬된 순서. objective.py 와 동일.
const HASH_SCALAR_KEYS = (
    "C_fail", "C_unclosed", "E_ref", "Eg_scale", "M_ref", "T_scale", "kappa", "tie_eps",
)

# 문자열로 해싱하는 키 (숫자 포맷을 거치지 않고 **원문 그대로**). objective.py 와 동일.
#
# 왜 필요한가 (2026-08-13 컨트롤러 재정): 스칼라만 해싱하면 **목적함수의 유효 의미가 바뀌었는데
# 스칼라는 그대로인 변경**을 해시가 표현하지 못한다. 실제로 그런 일이 났다 — 태스크 6 이 κ 를
# DeprioritizeAgent 국소 스코프에서 전역 기본값으로 승격하면서 오라클 fault 재풀이
# (release_pending_assignments! → verifier/커밋 풀이)가 이전 라벨과 **다른 목적함수**를
# 최적화하게 됐는데, objective.json 의 스칼라는 하나도 안 바뀌어 해시가 동일했다.
# spec §7 의 "해시가 다르면 다른 세대" 기계적 판정이 그 단절을 볼 수 없었다.
#
# 규칙: **목적함수의 유효 의미가 바뀌면 스칼라가 그대로여도 bump 한다.** 플래너 재배선 포함.
const HASH_STRING_KEYS = ("generation",)

# 실제 해싱 순서 = 스칼라 + 문자열 키를 합쳐 한 번 정렬한 것.
# 코드포인트 정렬이라 대문자 키가 먼저 온다: C_fail, C_unclosed, E_ref, Eg_scale, M_ref,
# T_scale, generation, kappa, tie_eps. Python 의 sorted() 와 같은 순서다.
const HASH_KEYS = Tuple(sort(collect(String[HASH_SCALAR_KEYS..., HASH_STRING_KEYS...])))

struct ObjectiveError <: Exception
    msg::String
end
Base.showerror(io::IO, e::ObjectiveError) = print(io, "ObjectiveError: ", e.msg)

const _CACHE = Ref{Union{Nothing,Dict{String,Any}}}(nothing)

"objective.json 을 읽고 ENV 덮어쓰기를 적용한 유효 설정."
function load(; path::AbstractString = OBJECTIVE_PATH, refresh::Bool = false)
    if _CACHE[] !== nothing && !refresh && path == OBJECTIVE_PATH
        return _CACHE[]
    end
    isfile(path) || throw(ObjectiveError("objective.json 이 없다: $path"))
    cfg = Dict{String,Any}(JSON3.read(read(path, String), Dict{String,Any}))
    delete!(cfg, "_doc")
    # `generation` 은 해시에 **문자열 그대로** 들어간다. 문자열이 아니면 두 언어의 표기가
    # 갈릴 수 있다 — 특히 JSON 불리언은 Julia 가 "true", Python 이 "True" 를 내서 해시가
    # 조용히 달라진다(이미 닫은 -0.0 발산과 같은 부류). 타입을 여기서 못 박아 원천 봉쇄한다.
    if haskey(cfg, "generation") && !(cfg["generation"] isa AbstractString)
        throw(ObjectiveError("objective.json 의 generation 은 문자열이어야 한다 (해시에 원문 " *
            "그대로 들어가므로 Python/Julia 표기가 갈릴 수 있다): $(repr(cfg["generation"]))"))
    end
    ov = Dict{String,String}()
    for (key, env_name) in ENV_OVERRIDES
        haskey(ENV, env_name) || continue
        cfg[key] = parse(Float64, ENV[env_name])
        ov[env_name] = ENV[env_name]
    end
    cfg["_env_overrides"] = ov
    path == OBJECTIVE_PATH && (_CACHE[] = cfg)
    return cfg
end

"""
해시용 값 포맷. null 은 "null".

NaN/Inf 는 소문자 "nan"/"inf"/"-inf" 로 고정한다 — Julia 의 @sprintf("%.17g", ...) 는
"NaN"/"Inf" (대문자)를 내지만 Python 의 "%.17g" % v 는 이미 소문자를 낸다. 맞추지 않으면
(예: MC_COST_FAIL=inf) 두 언어의 해시가 갈린다.

-0.0 은 0.0 으로 정규화한다 — JSON3 는 정수값 float 를 Int64 로 낮춰 읽어 -0.0 을 부호 없는
0 으로 지워버리지만(이 Julia 쪽에서는 사실 이미 무해하다) Python 의 json 모듈은 부호를
보존한다. Python 쪽에서도 같은 정규화를 하므로 어느 쪽에서 -0.0 이 들어와도 두 언어가
합의한 하나의 표기("0")로 수렴한다.

그 외에는 %.17g (C printf 의미, Python 과 바이트가 일치한다).
"""
function _fmt_hash_value(v)
    v === nothing && return "null"
    f = Float64(v)
    isnan(f) && return "nan"
    isinf(f) && return f > 0 ? "inf" : "-inf"
    f == 0.0 && (f = 0.0)  # normalize -0.0 -> +0.0
    return @sprintf("%.17g", f)
end

"키 하나의 해시 표기. 문자열 키는 원문 그대로, 그 외는 %.17g 숫자 규약."
function _fmt_hash_entry(key, v)
    key in HASH_STRING_KEYS && return v === nothing ? "null" : string(v)
    return _fmt_hash_value(v)
end

"""
    objective_hash(cfg=nothing)

유효 설정의 sha256(앞 16자).

해시 대상: J 를 정의하는 8개 스칼라(C_fail, C_unclosed, E_ref, Eg_scale, M_ref,
T_scale, kappa, tie_eps) **+ 세대 딱지 `generation`**(문자열, 원문 그대로) 을 합쳐
한 번 정렬한 순서로, 그리고 실제로 적용된 ENV 덮어쓰기(ENV 변수명 정렬순, 원본
문자열 그대로)를 "key=value" 줄로 나열해 "\\n" 로 join 하고 끝에 "\\n" 을 붙인 뒤
UTF-8 로 sha256 한다.

`_doc`/`calibrated_from` 은 문서·출처일 뿐 J 의 파라미터가 아니므로 제외한다 —
두 파일이 파라미터는 같고 출처만 다르면 같은 목적함수이므로 같은 해시를 내야 한다
(§7 의 "해시가 다르면 다른 세대" 규약이 문서 오타 수정으로 허투루 깨지지 않게).

`generation` 은 그 반대쪽 구멍을 막는다: **스칼라가 그대로인데 유효 의미가 바뀐**
변경(플래너 재배선 등)을 해시가 볼 수 있게 한다. 그런 변경을 했으면 반드시 bump 할 것.

Python 과 이 텍스트 규약을 그대로 공유한다(JSON 직렬화 바이트 매칭에 기대지
않는다) — 그래서 두 언어가 항상 같은 해시를 낸다.
"""
function objective_hash(cfg = nothing)
    cfg = cfg === nothing ? load() : cfg
    lines = String[]
    for key in HASH_KEYS
        push!(lines, "$(key)=$(_fmt_hash_entry(key, get(cfg, key, nothing)))")
    end
    overrides = get(cfg, "_env_overrides", Dict{String,String}())
    for env_name in sort(collect(keys(overrides)))
        push!(lines, "ENV:$(env_name)=$(overrides[env_name])")
    end
    blob = Vector{UInt8}(join(lines, "\n") * "\n")
    return bytes2hex(SHA.sha256(blob))[1:16]
end

"w_E = kappa * M_ref / E_ref. 스케일이 null 이면 에러 — 0/1 로 폴백하지 않는다."
function energy_weight(cfg = nothing)
    cfg = cfg === nothing ? load() : cfg
    missing = [k for k in SCALE_KEYS if get(cfg, k, nothing) === nothing]
    isempty(missing) || throw(ObjectiveError(
        "objective.json 의 $(join(missing, ", ")) 가 null 이다 — 파일럿 측정 없이는 완주 런의 J 를 " *
        "계산할 수 없다. 0 이나 1 로 폴백하지 않는다 (spec §5)."))
    e_ref = Float64(cfg["E_ref"])
    (isfinite(e_ref) && e_ref > 0) || throw(ObjectiveError("E_ref 가 양의 유한값이 아니다: $(cfg["E_ref"])"))
    return Float64(cfg["kappa"]) * Float64(cfg["M_ref"]) / e_ref
end

"실현된 런 하나의 목적함수 값 (작을수록 좋다)."
function J(; complete, closed, total, makespan, energy_J = nothing, cfg = nothing)
    cfg = cfg === nothing ? load() : cfg
    ms = makespan === nothing ? NaN : Float64(makespan)
    if !complete
        # 미완주 분기에는 에너지가 들어가지 않는다 (spec §3.1).
        missing = [k for k in INCOMPLETE_KEYS if get(cfg, k, nothing) === nothing]
        isempty(missing) || throw(ObjectiveError(
            "objective.json 의 $(join(missing, ", ")) 가 null 이다 — 미완주 분기의 J 를 " *
            "계산할 수 없다. 0/1 로 조용히 폴백하지 않는다 (spec §5)."))
        # (total - closed) 를 0 밑으로 클램프한다 (I-1) — complete==true 인데 closed<total 인
        # 장부 노드가 있을 수 있다는 건 이미 문서화돼 있고(CLAUDE.md §6), 그 역(기록 드리프트로
        # closed>total)도 배제할 근거가 없다. 클램프가 없으면 미완주 J 가 0 이하로 떨어져
        # 기록 오류가 세상에서 가장 좋은 결과로 둔갑할 수 있다 — spec §3.1 이 막으려는 결함이다.
        return Float64(cfg["C_fail"]) +
               Float64(cfg["C_unclosed"]) * max(0, Int(total) - Int(closed)) +
               Float64(cfg["tie_eps"]) * (isfinite(ms) ? ms : 0.0)
    end
    isfinite(ms) || throw(ObjectiveError("완주 런인데 makespan 이 유한하지 않다: $makespan"))
    (energy_J !== nothing && isfinite(Float64(energy_J))) || throw(ObjectiveError(
        "완주 런인데 energy_J 가 없다/유한하지 않다: $energy_J — 구세대 덤프이거나 배터리가 꺼진 " *
        "런이다. J 는 이를 조용히 0 으로 두지 않는다 (spec §5)."))
    return ms + energy_weight(cfg) * Float64(energy_J)
end

end # module
