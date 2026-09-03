# =============================================================================
# 생성 원시의 표와 등록. (2026-09-03, 설계 §6)
#
# 🔴 왜 파일이 아니라 런-스코프인가. 어휘는 이제 **런타임에 생성된다**. 파일에 쓰면 런끼리
#    오염되고(앞 런이 만든 원시를 뒤 런이 물려받는다), 추적되는 파일을 LLM 이 쓰는 것이 된다.
# =============================================================================
const _MINTED_TABLE = Ref{Dict{String,Any}}(Dict{String,Any}())

"이 런에서 등록된 원시들. `resolve_primitive` 가 읽는 유일한 표다."
minted_table() = _MINTED_TABLE[]

"표를 비운다. 시험과 런 경계에서 부른다."
reset_minted_table!() = (_MINTED_TABLE[] = Dict{String,Any}(); nothing)

"""
    check_impl_conventions(name, code) -> Union{Nothing,String}

설계 §5 의 규약 다섯. 통과하면 `nothing`, 아니면 **거절 사유**다. 순수 함수 —
`eval` 도 세계도 건드리지 않는다.

🔴 규약 1 이 존재 이유의 절반이다: `f(env; kw…)` 로 고정하면 `_enactability` 의
   arity·kwargs 연언지를 **구성상** 통과한다. 오늘 19개 중 9개를 막고 있는 그 결함
   (impl 이 params 를 위치인자로 받는다)이 새 원시에서는 원천적으로 안 생긴다.
🔴 규약 5 는 이 사슬에서 가장 나쁜 사고를 막는다 — `Core.eval` 이 기존 이름을 덮으면
   시뮬레이터 코드를 런타임에 교체한다.
"""
function check_impl_conventions(name::AbstractString, code::AbstractString)
    endswith(name, "!") || return "reject:impl_name_must_end_with_bang:$(name)"
    Base.isidentifier(chop(name)) || return "reject:impl_name_not_an_identifier:$(name)"
    isdefined(@__MODULE__, Symbol(name)) &&
        return "reject:impl_name_exists:$(name) — 기존 이름을 덮을 수 없다"

    local top
    try
        top = Meta.parseall(code)          # 🔴 parse 가 아니라 parseall — parse 는 첫 식만 읽는다
    catch e
        return "reject:impl_parse_failed:" * first(split(sprint(showerror, e), "\n"))
    end
    exprs = [x for x in top.args if !(x isa LineNumberNode)]
    length(exprs) == 1 ||
        return "reject:impl_not_single_expression:$(length(exprs))"
    f = exprs[1]
    (f isa Expr && f.head === :function) || return "reject:impl_not_a_function"

    sig = f.args[1]
    (sig isa Expr && sig.head === :call) || return "reject:impl_signature_unreadable"
    String(sig.args[1]) == String(name) ||
        return "reject:impl_name_mismatch:$(sig.args[1]) != $(name)"

    rest = sig.args[2:end]
    kwblock = findfirst(x -> x isa Expr && x.head === :parameters, rest)
    kws = kwblock === nothing ? Any[] : rest[kwblock].args
    pos = kwblock === nothing ? rest : rest[setdiff(eachindex(rest), kwblock)]
    (length(pos) == 1 && pos[1] === :env) ||
        return "reject:impl_positional_args_must_be_exactly_env:$(pos)"
    for k in kws
        (k isa Expr && k.head === :kw) ||
            return "reject:impl_keyword_needs_a_default:$(k)"
    end
    return nothing
end

"""
    register_minted_primitive!(; name, code, params, surface, reversible) -> Union{Nothing,String}

규약 검사 → `Core.eval` → 런-스코프 표에 등록. 통과하면 `nothing`, 아니면 거절 사유.

🔴 **던지지 않는다.** 여기서 예외가 새면 집행부가 기록 대신 예외로 끝나고 호출자는 세계
   상태를 알 방법을 잃는다 — 이 파일 전체가 지키는 규약이다.
🔴 **부분 등록이 없다.** eval 이 실패하면 표에 아무것도 안 남는다.
"""
function register_minted_primitive!(; name::AbstractString, code::AbstractString,
                                     params, surface::AbstractString = "unknown",
                                     reversible::Bool = false)
    why = check_impl_conventions(name, code)
    why === nothing || return why
    try
        Core.eval(@__MODULE__, Meta.parseall(code))
    catch e
        return "reject:impl_eval_failed:" * first(split(sprint(showerror, e), "\n"))
    end
    minted_table()[String(name)] = Dict{String,Any}(
        "name"         => String(name),
        "impl"         => String(name),   # 함수 자신이 원시다 — 이름이 둘일 이유가 없다
        "surface"      => String(surface),
        "harness_args" => ["env"],        # 규약 1
        "params"       => Dict{String,Any}(String(k) => v for (k, v) in pairs(params)),
        "reversible"   => reversible)
    return nothing
end
