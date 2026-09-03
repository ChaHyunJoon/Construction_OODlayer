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
        # 🔴 벨트-앤-브레이시스다, 주 경로가 아니다(2026-09-03 F3 실측). Julia 1.10 의
        #    `Meta.parseall` 은 불완전/깨진 입력 11종(잘림 · 쓰레기 연산자 · 남는 `end` ·
        #    나쁜 토큰 · null byte · 잘못된 UTF-8 · 300단 중첩 괄호 · 빈 문자열 등) **어느
        #    쪽에서도 안 던졌다** — 대신 `:incomplete`/`:error` head 를 가진 `Expr` 을 결과
        #    안에 **데이터로** 심어 정상 반환한다(아래에서 그것을 찾는다). 이 `catch` 는 미래
        #    Julia 판이 실제로 던질 경우에 대비한 방어일 뿐, 지금은 도달하지 않는다(비용은
        #    거의 0이라 남겨 둔다).
        return "reject:impl_parse_failed:" * first(split(sprint(showerror, e), "\n"))
    end
    # 🔴 F3: 위 `try`/`catch` 가 못 잡는 진짜 경로. `parseall` 은 불완전/깨진 입력을
    #    `Expr(:incomplete, ParseError(...))` 또는 `Expr(:error, ParseError(...))` 로 결과의
    #    `:toplevel` 블록 **안에** 심는다(여러 문 중 뒤쪽 문에서 깨져도 마찬가지 — 실측
    #    확인). 아래를 안 넣으면 이 경우 잘린 코드가 `impl_not_a_function`(또는 문장 수가
    #    둘 이상이면 `impl_not_single_expression`)으로 새어나가 agent-3 에게 틀린 수리
    #    신호를 준다 — verdict 는 여전히 거절(`!== nothing`)이라 낡은 단언(`!== nothing` 만
    #    보는 시험)은 이걸 못 잡는다(설계 §8, 컨트롤러 F3).
    bad = findfirst(x -> x isa Expr && x.head in (:incomplete, :error), top.args)
    if bad !== nothing
        pe = top.args[bad].args[1]
        msg = pe isa Base.Meta.ParseError ? replace(pe.msg, "\n" => " / ") :
                                             sprint(showerror, pe)
        return "reject:impl_parse_failed:$(msg)"
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
