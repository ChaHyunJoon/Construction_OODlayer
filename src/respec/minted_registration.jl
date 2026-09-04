# =============================================================================
# 생성 원시의 표와 등록. (2026-09-03, 설계 §6)
#
# 🔴 **무엇이 런 스코프이고 무엇이 아닌가** (2026-09-03 최종 리뷰 I1 이 정정. 이 머리말은
#    전에 "런끼리 오염되지 않는다" 라고만 적어서, 참이 아닌 절반을 참인 절반으로 덮었다).
#
#    · **표(`_MINTED_TABLE`)는 런 스코프다.** `reset_minted_table!()` 이 비우고, 파일에
#      안 쓴다. 그래서 앞 런이 등록한 원시가 뒤 런의 **어휘**로 남지 않는다 —
#      `resolve_primitive` 는 이 표만 읽으므로 리셋 뒤에는 그 이름이 해석되지 않는다.
#    · 🔴 **`Core.eval` 로 심은 함수는 런 스코프가 아니다.** 그것은 `ConstructionBots`
#      모듈에 프로세스 수명 내내 남고, 되돌리는 길이 없다(Julia 는 메서드 정의를 못 지운다).
#      `reset_minted_table!` 은 표만 비운다 — 이름은 여전히 `isdefined` 다.
#
#    귀결(한 프로세스가 런을 둘 처리할 때): 뒤 런이 앞 런과 **같은 이름**을 다시 주조하려
#    하면 규약 5 에 걸려 거절된다. 그 거절은 아래 표에서 **네 번째 사유**
#    (`reject:impl_name_already_minted`)로 따로 나간다 — 안 가르면 그것이 C3 의 D6 신호
#    (`…_withheld` = 모델이 비공개 능력을 스스로 재유도했다)로 오분류되고, 이 레인의 첫
#    측정이 프로세스 재사용이라는 배관 사실 때문에 거짓 양성을 낸다.
#    (같은 부류의 두 번째 누출을 R1 이 막았다: CB 가 `using` 하는 모듈의 이름도 export 는
#    안 돼 있어 D6 신호로 새고 있었다 → `reject:impl_name_exists_imported`.)
#
#    ⚠️ **런 경계를 세우는 기전은 아직 없다.** `reset_minted_table!` 의 생산 호출자는
#    **0개**이고(시험만 부른다) 어느 코드도 "런이 끝났다" 를 이 파일에 알리지 않는다.
#    그 배선은 Task 9 의 몫이다 — 여기서 지어내지 않는다.
# =============================================================================
const _MINTED_TABLE = Ref{Dict{String,Any}}(Dict{String,Any}())

"""
    _MINTED_EVER

이 **프로세스**가 `Core.eval` 로 심은 생성 원시 이름 전부. 🔴 표와 달리 절대 안 비운다 —
비우면 거짓말이 된다(함수는 여전히 모듈에 있다). 위 머리말의 비대칭을 기계가 볼 수 있게
만드는 유일한 자리이고, `check_impl_conventions` 의 세 번째 충돌 사유가 이것을 읽는다.
"""
const _MINTED_EVER = Set{String}()

"이 런에서 등록된 원시들. `resolve_primitive` 가 읽는 유일한 표다."
minted_table() = _MINTED_TABLE[]

"""
표를 비운다. 시험과 런 경계에서 부른다.

🔴 **`Core.eval` 은 안 되돌린다** — 심긴 함수는 프로세스에 그대로 남는다(머리말). 이 함수가
지우는 것은 어휘이지 정의가 아니다.
"""
reset_minted_table!() = (_MINTED_TABLE[] = Dict{String,Any}(); nothing)

"""
    check_impl_conventions(name, code) -> Union{Nothing,String}

설계 §5 의 규약 다섯. 통과하면 `nothing`, 아니면 **거절 사유**다. 순수 함수 —
`eval` 도 세계도 건드리지 않는다.

🔴 규약 1 이 존재 이유의 절반이다: `f(env; kw…)` 로 고정하면 `_enactability` 의
   arity·kwargs 연언지를 **구성상** 통과한다. 오늘 19개 중 9개를 막고 있는 그 결함
   (impl 이 params 를 위치인자로 받는다)이 새 원시에서는 원천적으로 안 생긴다.

🔴 **규약 2("문장 하나")는 "정의 하나"를 재지 "결속 하나"를 재지 않는다 — 결정, 사고가
   아니다**(2026-09-03 최종 리뷰 F16, 컨트롤러 판정 R15). `body` **안에** 중첩된 내부
   함수(예: `function outer!(env); helper(x) = x+1; return helper(1); end`)는 지금도
   통과한다(실측: `exprs` 가 `Expr(:function, ...)` 하나만 요구하고, 그 함수의 몸통
   안쪽은 안 들여다본다). **이것은 앞으로도 허용이다** — 재는 것은 "최상위 정의가
   정확히 하나" 이고, 그 하나의 정의 안에 사는 도우미 클로저는 그 규약을 하나도 안
   어긴다. 모델이 긴 몸통을 내부 클로저로 나눈 것은 잘못이 아니다. ⚠️ 이 규약은
  agent-3 에게 보여주는 프롬프트 문구(`src/respec/llm_service/world_interface.py`
  의 "No other definitions -- no `const`, no macros, no helper functions.")와
  글자로는 어긋난다 — 그 문구는 이 파일(`src/respec/minted_registration.jl`) 소유가
  아니라서 여기서 못 고친다. 프롬프트 쪽 문구를 "최상위(top-level) 정의는 하나뿐" 으로
  누그러뜨리는 쪽이 맞다(모델이 몸통을 내부 클로저로 나눈 것은 잘못이 아니라는 것이
  컨트롤러 판정이다) — 이 파일의 검사를 좁혀 지금 통과하는 것을 막는 쪽이 아니다.
🔴 규약 5 는 이 사슬에서 가장 나쁜 사고를 막는다 — `Core.eval` 이 기존 이름을 덮으면
   시뮬레이터 코드를 런타임에 교체한다. **검사 자체는 그대로 `isdefined` 다**(export
   여부로 좁히면 그 사고가 비공개 이름으로 그대로 열린다). 아래에서 갈리는 것은 **거절
   사유**뿐이고, 무엇을 거절하는지는 한 톨도 안 좁아진다.

🔴 **그런데 충돌은 한 사건이 아니라 넷이고, 사유가 갈려야 한다** (2026-09-03 최종 리뷰
   C3 이 셋으로 갈랐고, R1 이 넷째를 더했다).
   모델이 본 표면은 `names(@__MODULE__)`(export 된 것)뿐이다 — 산출물
   `world_interface.json` 이 바로 그 집합에서 생성되고, 설계 D6 이 비공개 impl 열을
   **일부러** 안 보여준다. 그래서:

   | 사유 | 뜻 | 이것이 말하는 것 |
   |---|---|---|
   | `impl_name_exists_shown` | 인터페이스에 실린 이름을 덮으려 했다 | 모델이 준 인터페이스를 안 읽었다 = 모델의 실수 |
   | `impl_name_exists_withheld` | **안 보여준** 비공개 결속이고 **CB 자신의 것**이다 | 🔴 **D6 신호** — 우리가 감춘 능력을 스스로 다시 유도했다 |
   | `impl_name_exists_imported` | CB 가 `using` 하는 **남의 모듈**의 이름이다 | 모델이 `Base`/`Graphs` 가 이미 쓰는 이름을 골랐다 — 위 둘 **어느 쪽도 아니다** |
   | `impl_name_already_minted` | 이 프로세스가 앞서 주조한 이름이다 | 배관 사실(머리말 I1)이지 모델에 대한 사실이 **아니다** |

   🔴 둘째 줄(`…_withheld`)이 이 레인의 **첫 측정 대상**이다. 설계 §9 는 "모델이 export 안 된 능력
   (`release_pending_assignments!`)을 처음부터 못 쓸 수 있다" 를 첫 번째 실현 가능성
   위험으로 적었다 — 그 이름을 **모델이 스스로 골랐다**는 것은 그 위험이 실현되지 않았다는
   증거이고, 사유가 하나뿐이던 어제까지는 그 증거가 "너는 기존 이름을 덮으려 했다" 라는
   되먹임 문장 안에서 통째로 파괴됐다. 실측 대상 다섯(`isdefined` 참 · export 거짓):
   `release_pending_assignments!` · `recover_stalled_teams!` · `resolve_schedule_wedge!` ·
   `force_advance_stuck_carrier!` · `forbid_heavy_cargo!`.

   ⚠️ 넷째 줄이 없으면 둘째 줄이 오염된다: `Core.eval` 한 이름은 export 되지 않으므로,
   앞 런이 주조한 이름을 다시 주조하려는 시도가 **D6 신호로 오분류**된다(머리말 I1).

   🔴 **셋째 줄이 없어도 둘째 줄이 오염된다** (R1, 2026-09-03). `isdefined && !exported`
   는 뜻보다 훨씬 넓다 — CB 는 `Graphs`·`MetaGraphs`·`DataStructures`·`Base` 등 ~30 모듈을
   `using` 하므로 평범한 이름이 전부 그 술어를 만족한다(실측: `add_edge!`·`rem_edge!` →
   `Graphs.SimpleGraphs`, `set_prop!` → `MetaGraphs`, `push!`·`empty!` → `Base`). 그래프를
   편집하는 원시를 `add_edge!` 라 이름 붙이는 것은 전혀 이상하지 않은데, 좁히기 전에는
   그것이 **D6 적중으로 기록됐다** — Task 11 의 첫 유료 런이 재려는 단 하나의 측정이다.
   가르는 사실은 **결속의 소유 모듈**이고 `Base.binding_module(@__MODULE__, sym)` 이 낸다.
   ⚠️ `parentmodule` 이 아니다: 그것은 함수·타입에만 있어 `_MINTED_TABLE` 같은 값 결속에서
   `MethodError` 를 던진다(실측) — 이 경로는 거절이지 예외가 아니어야 한다.
   🔴 **CB 가 남의 모듈에서 확장하는 이름**(`push!`)의 소유 모듈은 여전히 `Base` 이고,
   그것이 우리가 원하는 분류다. D6 은 "우리가 **감춘** 능력" 에 대한 사건인데 `push!` 은
   감춘 능력이 아니라 누구나 아는 이름이다 — CB 가 거기에 메서드를 얹었다는 사실은 모델이
   무엇을 재유도했는지에 대해 아무 말도 하지 않는다.

   🔴 **네 사유는 이름 공간을 분할한다**(시험 (15)). 결정 트리는 ① 이 프로세스가
   주조했나 → ② export 됐나 → ③ 소유 모듈이 CB 인가 이고, 물음이 셋 다 이지선다라 잎이
   정확히 하나 골라진다(겹치지 않음). `isdefined` 가 거짓인 이름만 규약 5 를 통과한다 —
   그것이 사유 없이 빠져나가는 유일한 길이다(빠짐없음).
   ⚠️ **순서가 뜻을 정한다.** ①이 ③보다 앞이어야 한다: `Core.eval` 로 심은 이름의 소유
   모듈은 CB 이므로, 순서를 바꾸면 앞 런이 주조한 이름이 다시 `withheld` 로 샌다
   (시험 (13) 이 그 순서를 잰다).

   ⚠️ 이 함수는 이제 프로세스 상태(`_MINTED_EVER`·모듈 심볼 표)를 **읽는다**. 여전히
   세계도 `eval` 도 안 건드린다 — 순수함의 뜻은 그것이었다.
"""
function check_impl_conventions(name::AbstractString, code::AbstractString)
    # 🔴 F14(2026-09-03 최종 리뷰, 컨트롤러 판정). `Base.isidentifier(chop(name))` 는
    #    `name` 을 문자 단위로 훑는다 — 유효하지 않은 UTF-8(예: 외톨이 연속 바이트
    #    `0xff`)이 섞여 있으면 `Base.InvalidCharError` 를 **던진다**(실측). `endswith`·
    #    문자열 보간은 안 던지므로 그 자리만 놓치기 쉬웠다. F9 의 헤지("두 함수 안에
    #    무가드 변환이 없다")가 놓친 축이 정확히 이것이다 — AST 모양이 아니라 **`name`
    #    인자의 바이트 내용**. `isvalid` 로 여기서 먼저 잡는다.
    isvalid(name) || return "reject:impl_name_not_utf8:$(repr(name))"
    endswith(name, "!") || return "reject:impl_name_must_end_with_bang:$(name)"
    Base.isidentifier(chop(name)) || return "reject:impl_name_not_an_identifier:$(name)"
    # 규약 5 — 충돌 셋을 가른다(위 표). 순서가 뜻을 정한다: 이 프로세스가 스스로 심은
    # 이름이 먼저다(그것은 모델에 대한 사실이 아니다), 그다음이 모델이 본/못 본 표면이다.
    local sym = Symbol(name)
    if String(name) in _MINTED_EVER
        return "reject:impl_name_already_minted:$(name) — 이 프로세스가 앞서 주조해 " *
               "`Core.eval` 한 이름이다. 표는 리셋돼도 정의는 안 지워진다(파일 머리말 I1)"
    elseif isdefined(@__MODULE__, sym)
        if sym in names(@__MODULE__)
            return "reject:impl_name_exists_shown:$(name) — 세계 인터페이스에 실려 있는 " *
                   "이름이다. 기존 이름을 덮을 수 없다 — 다른 이름을 고르라"
        end
        # 🔴 R1. export 안 됐다는 것만으로는 **비공개 CB 능력**이 아니다 — 결속의 소유
        #    모듈을 봐야 한다(위 표 둘째·셋째 줄). `Base.binding_module` 은 정의된 결속마다
        #    모듈을 **하나** 내므로 아래 둘은 서로 배타적이고 함께 빠짐없다.
        owner = Base.binding_module(@__MODULE__, sym)
        # 🔴 괄호가 필요하다 — `@__MODULE__ ?` 는 매크로가 `?` 를 삼켜 파스가 깨진다.
        return owner === (@__MODULE__) ?
            "reject:impl_name_exists_withheld:$(name) — 🔴 이 이름은 모듈에 **있지만** " *
            "인터페이스에는 안 실린다(설계 D6, export 안 됨). 덮을 수는 없으니 다른 이름을 " *
            "고르라 — 그러나 이 거절은 모델이 감춰진 능력을 스스로 다시 유도했다는 신호다" :
            "reject:impl_name_exists_imported:$(name) — 이 이름은 `ConstructionBots` 가 " *
            "`using` 하는 모듈($(owner))의 것이다. 덮을 수는 없으니 다른 이름을 고르라 — " *
            "그러나 이것은 D6 신호가 **아니다**: 우리가 감춘 능력이 아니라 남의 모듈이 이미 " *
            "쓰는 이름을 골랐다는 사실이다"
    end

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
    # 🔴 F9(2026-09-03 최종 리뷰, 컨트롤러 판정 R9). `sig.args[1]` 이 `Symbol` 이 아닌
    #    모델-도달가능 모양 셋에서 바로 아래 `String(sig.args[1])` 이 던진다(실측: 셋 다
    #    `MethodError`) — 한정 이름(`Base.foo!`) · 보간(`$(...)`) · callable 객체
    #    (`(o::T)(...)`). 이 검사는 `register_minted_primitive!` 의 `params` 검사보다
    #    **먼저** 도는데(호출 순서: 규약 검사 → `params` 검사 → eval), 여기서 던지면
    #    그 아래 F7 의 "검증이 먼저면 이 함수 안에 던질 자리가 없다" 는 불변식이 이
    #    함수(`check_impl_conventions`) 자체 안에서는 성립하지 않은 채였다.
    # 🔴 셋 중 가장 위험한 것은 한정 이름이다 — 모델이 쓸 법한 가장 흔한 한정 이름은
    #    바로 D6 이 재려는 사건(`ConstructionBots.release_pending_assignments!` 처럼
    #    가려진 능력을 다시 이름 붙이려는 시도)이다. 던지면 그 사건이
    #    `impl_rejected_why=nothing` 인 raw `MethodError` 로 새어 나가 D6 신호가
    #    **오염이 아니라 소실**된다 — 이 계획이 재려는 단 하나의 관측이 기록조차 안 된다.
    #    agent-3 에게 되먹임될 수 있는 것이 이 사유 문자열이므로(F2 recompose 루프),
    #    셋을 뭉뚱그리지 않고 각자 자기 사유를 낸다 — F3 가 `impl_name`/`impl_code`/
    #    `surface`/`params` 타입 위반에 준 것과 같은 결.
    callee = sig.args[1]
    if !(callee isa Symbol)
        return callee isa Expr && callee.head === :. ?
            "reject:impl_name_is_qualified:$(callee) — 정의는 한정 이름(모듈 접두사)으로 " *
            "못 쓴다. 이름 하나만 적으라" :
        callee isa Expr && callee.head === :$ ?
            "reject:impl_name_is_interpolated:$(callee) — 정의 이름 자리에 보간을 못 쓴다. " *
            "리터럴 이름을 적으라" :
        callee isa Expr && callee.head === :(::) ?
            "reject:impl_signature_is_callable_object:$(callee) — callable 객체 정의 " *
            "(`(o::T)(...)`)는 규약 밖이다. 이름 있는 함수로 적으라" :
            "reject:impl_name_unreadable:$(typeof(callee))"
    end
    String(callee) == String(name) ||
        return "reject:impl_name_mismatch:$(callee) != $(name)"

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

🔴 2026-09-03 (Task 9 최종 리뷰 F7, 컨트롤러 판정 R8). 이 둘을 한꺼번에 어기는 자리가
있었다 — `params` 의 키를 `Dict{String,Any}(String(k) => v for (k,v) in pairs(params))`
로 바꾸는 자리가 `Core.eval` **뒤**였다. 정수·부동소수 키(`Dict{Int,Any}`·`Dict{Float64,Any}`)
는 `String(k)` 가 없어 여기서 던졌고(실측: `String`·`Symbol` 키는 통과, `Int`·`Float64` 는
`MethodError`), 그 순간 `Core.eval` 은 이미 끝나 있었다 — `isdefined(CB, name) == true` 이고
`name ∈ _MINTED_EVER == true` 인데 `minted_table()` 에는 행이 없다.
🔴 **정정(2026-09-03): D6 신호는 안 오염된다 — 그 자리를 근거로 적지 말 것.** 처음엔
이 반쪽 상태 뒤 같은 이름을 재등록하면 그 재시도가 `check_impl_conventions` 의
"withheld"(D6 신호, C3) 로 오분류된다고 판단했는데 틀렸다. `push!(_MINTED_EVER, …)` 가
`Dict` 컴프리헨션(그 자리에서 던지는 지점)**보다 앞**이라, 재시도는 `_MINTED_EVER` 멤버십
검사(`check_impl_conventions` 의 규약 5, D6 판정보다 **먼저** 도는 이름-충돌 검사)에서
`reject:impl_name_already_minted` 로 걸린다(직접 재현: 반쪽 상태를 만든 뒤 재등록하면
정확히 이 사유가 나오고 "withheld" 는 안 나온다). **그래도 Critical 인 진짜 이유는 둘이다**
(D6 과 무관): (1) 이 함수의 docstring 이 "던지지 않는다" 를 약속하는데 여기서 던지면
그 약속을 지키는 방어선이 `enact_minted_decision!` 의 바깥 `try` **하나뿐**이 된다(이
계획의 구속 조건인 예외가 아니라 거절이 한 겹짜리 방어로 줄어든다). (2) `push!(
_MINTED_EVER, …)` 가 던지는 지점보다 앞이므로, 이 반쪽 상태를 만든 뒤에는 그 **이름이
프로세스 수명 내내 영구히 막힌다** — `Core.eval` 로 실제로 쓸모 있는 것은 아무것도 안
심겼는데도 그 이름으로의 모든 재시도가 `already_minted` 로 거절된다. 이것은 모델의 재시도
자체를 스스로 막는 자기부과 거부이고, D6 신호와 무관하게 그 자체로 고칠 이유가 충분하다.
**고친 방법: 검증을 eval **앞**으로 옮긴다**(설계 §8 이 제시한 두 갈래 중 이쪽을 골랐다 —
"eval 을 기록해 두고 재시도가 정직하게 읽게 한다" 쪽은 eval 자체를 되돌릴 길이 없는 이
파일의 전제와 충돌해 상태 기계가 하나 더 필요해진다). 검증이 먼저이면 eval 은 **검증을
통과한 뒤에만** 돈다 — 그 뒤로는 이 함수 안에 던질 자리가 없으므로 "부분 등록" 자체가
구조적으로 불가능해지고, 위 (2)의 영구 차단도 함께 사라진다(검증에서 거절되면
`_MINTED_EVER` 에 아예 안 들어간다 — 재시도가 자유롭다).
"""
function register_minted_primitive!(; name::AbstractString, code::AbstractString,
                                     params, surface::AbstractString = "unknown",
                                     reversible::Bool = false)
    why = check_impl_conventions(name, code)
    why === nothing || return why
    # 🔴 F7. `Core.eval` **전에** 검증한다 — 이 검증이 eval 뒤에 있었던 것이 결함의
    #    전부였다. `pairs(params)` 자체가 못 도는 모양(비-순회형)도 예외가 아니라 거절이다.
    local _pk
    try
        _pk = collect(pairs(params))
    catch e
        return "reject:params_unreadable:" * first(split(sprint(showerror, e), "\n"))
    end
    for (k, _) in _pk
        (k isa AbstractString || k isa Symbol) ||
            return "reject:params_keys_not_strings:$(typeof(k))"
    end
    try
        Core.eval(@__MODULE__, Meta.parseall(code))
    catch e
        return "reject:impl_eval_failed:" * first(split(sprint(showerror, e), "\n"))
    end
    push!(_MINTED_EVER, String(name))    # 🔴 표와 달리 안 비운다 — 정의가 안 지워지므로
    minted_table()[String(name)] = Dict{String,Any}(
        "name"         => String(name),
        "impl"         => String(name),   # 함수 자신이 원시다 — 이름이 둘일 이유가 없다
        "surface"      => String(surface),
        "harness_args" => ["env"],        # 규약 1
        # 🔴 2026-09-03 최종 리뷰(deferred item). `pairs(params)` 를 여기서 **다시** 부르지
        #    않는다 — 위에서 이미 `_pk` 로 한 번 모았다. 두 번째 순회를 상태 있는
        #    반복자(예: 스스로 소진되는 제너레이터)에게 시키면 여기서는 **던지지 않고
        #    조용히 빈 dict** 을 남긴다 — 예외보다 나쁜 조용한 오값이다. `_pk` 를 그대로
        #    쓰면 순회가 한 번이라 이 사고 자체가 안 생긴다.
        "params"       => Dict{String,Any}(String(k) => v for (k, v) in _pk),
        "reversible"   => reversible,
        # 🔴 C1 (2026-09-03 최종 리뷰). **이 행이 생성 코드에서 왔다**는 표시. 집행부의
        #    `_step_applied`·`_step_touched_world` 가 이것을 읽어 "이 원시의 status 어휘를
        #    아는 표가 없다" 를 안다. 판별자가 "`minted_table()` 에 있는가" 이면 안 되는
        #    이유: 알려진 원시 여덟도 (시험·프로브가) **손으로 씨 뿌려** 같은 표에 들어온다.
        #    구별되는 사실은 오직 "`Core.eval` 로 주조됐는가" 이고, 그것을 아는 곳은 여기뿐이다.
        "generated"    => true)
    return nothing
end
