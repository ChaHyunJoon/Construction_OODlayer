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
    _is_env_positional(a) -> Bool

규약 1 의 위치인자 하나가 `env` 인가. **`env` 와 `env::T`(어떤 `T` 든) 둘 다 참이다.**

🔴 **왜 타입 표기가 허용인가** (2026-09-03, 컨트롤러 판정 R18 — 다음 독자가 이것을 다시
   "조이지" 않도록 이유를 여기 적는다). 규약 1 이 존재하는 이유는 아래
   `check_impl_conventions` 의 docstring 이 적는 그대로 `_enactability` 의
   **arity·kwargs 연언지를 구성상 통과시키는 것**이다. 타입
   표기는 그 둘 중 **어느 것도 안 바꾼다**: `f(env::PlannerEnv; k=1)` 의 위치인자 수는
   여전히 1 이고 `f(env; k=1)` 과 똑같이 부를 수 있다. 오히려 `env::PlannerEnv` 는
   `env` 보다 **더 좁다** — 규약이 지키려는 것을 더 강하게 지킨다.
   그래서 이것을 거절하면 우리는 모델이 아니라 **우리 쪽 엄격함**을 재게 된다. 두 번째
   유료 런에서 실제로 그랬다(라이브 모델이 낸 시그니처가 정확히 `env::PlannerEnv` 였다).

⚠️ **넓어지는 것은 이 한 축뿐이다.** 이름이 다른 위치인자 · 위치인자가 둘 이상 · slurp
   (`env...`) · 기본값(`env = 1`) · 이름 없는 표기(`::PlannerEnv`)는 **전과 똑같이**
   거절된다. `Expr(:(::), :env, T)` 는 인자가 정확히 둘이고 첫째가 `:env` 여야 참이다 —
   이름 없는 `::T` 는 `Expr(:(::), T)` 로 인자가 하나라 여기 안 걸린다(실측).
"""
_is_env_positional(a) =
    a === :env ||
    (a isa Expr && a.head === :(::) && length(a.args) == 2 && a.args[1] === :env)

"""
    _walk_body!(calls, fields, locals, ex)

body 의 AST 를 걸어 (1) 호출 대상 이름 (2) `수신자.필드` 쌍 (3) 지역 결속 이름을 모은다.
🔴 **보수적이다.** 모르면 안 모은다 — 거짓 거절은 모델의 옳은 코드를 우리 파서의 한계로
   막고, 그것은 이 레인이 재려는 것 자체를 파괴한다.

🔴 **`locals` 는 "정의" 가 아니라 "결속" 을 모은다** (2026-09-04 독립 검증 C-1 이 정정).
   처음에는 `helper(x) = …` 와 중첩 `function helper(x)` **두 모양만** 모았다. 그래서
   함수를 담은 지역 이름을 부르는 **여섯 모양**이 전부 거짓 거절이 났다(실측):
   람다 대입 · `let` 결속 · 호출 결과 대입 · 별칭(`cb = println`) · 튜플 분해 ·
   `for` 루프 변수.
   🔴 **정정 (Wave C2, 2026-09-04): 그 자리가 "유일하게 모르면 거절" 이라던 이 머리말의
   앞 판은 측정으로 거짓이었다** — 커밋 `2b63ffae` 의 제목("모르면 통과를 마지막 한
   자리까지 밀고")도 같은 것을 주장했고 같이 틀렸다. **둘째 자리는 위 `:call` 갈래
   자신**이고(점 연산자 심볼), 여섯 지역-결속 모양보다 **훨씬 흔했다**(31모양 프로브 중
   19개 거짓 거절). 그 자리는 이 라운드에서 닫혔다(테스트셋 (31)). 이 파일은 머리말이
   적은 근거를 다음 세션이 검증 없이 전제로 읽는 자리다 — **"유일한/마지막" 이라고 다시
   적지 말 것.** 오늘 남아 있는 "모르면 거절" 자리를 세는 단일 진실원은 테스트셋 (31)·(28)
   두 개이고, 산문이 아니라 그 단언들이다.
   지금은 `Expr(:(=))` 의 좌변이 Symbol 이거나 튜플이면 결속으로 본다. `let`·`for` 는
   자기 결속을 `Expr(:(=))` 로 싣기 때문에 재귀 순회가 같은 두 갈래로 덮는다 —
   네 갈래를 따로 쓰지 않는다. 여섯 모양의 회귀 시험은 테스트셋 **(25)** 다.

🔴 **덮개 구멍은 넷이고, 그 목록의 단일 진실원은 테스트셋 (28) 이다**(2026-09-04 독립
   검증 M-2 가 하나에서 넷으로 정정). 넷 다 **거절을 안 하는** 쪽이라 거짓 거절은 없다.
   그중 둘(키워드 기본값 · 브로드캐스트 `f.(x)`)은 이 라운드에서 닫혔고 — 앞의 것은
   기본값이 매 호출에서 평가되므로 **진짜 집행-중 UndefVarError 경로**였다 — 나머지
   둘(매크로 호출 · 한정 호출 `Mod.f(x)`)은 **일부러 연 채로 둔다**: 매크로 이름 해석과
   모듈 경로 해석은 틀리면 **거짓 거절**이 나는 쪽이고, 그 대가가 이 레인이 재려는 것보다
   비싸다.
"""
function _walk_body!(calls, fields, locals, ex)
    ex isa Expr || return
    if ex.head === :call && !isempty(ex.args) && ex.args[1] isa Symbol
        # 🔴 B (Wave C2, 2026-09-04). 점 연산자(`.+` · `.==` · `.<` · `.|>` · `.∈` · 단항
        #    `.-`/`.!` …)는 `Expr(:call, :.+, …)` 로 실려 여기 그대로 모였는데,
        #    `isdefined(Base, Symbol(".+")) == false` 라 이름 우주에 없어 **전부 거짓
        #    거절**이었다(실측 2026-09-04: 31모양 프로브 중 19개). 벡터 산술은 수치
        #    Julia 에서 가장 흔한 관용구다 — 모델이 `soc .< 0.1` 을 쓰면 그 거절이 유료
        #    런에서 모델의 실패로 기록된다. 식별자는 `.` 로 시작할 수 없으므로 이 규칙이
        #    진짜 이름을 하나도 안 삼킨다(음성 대조는 테스트셋 (31)). 인자는 아래 재귀가
        #    그대로 걷으므로 점 연산자 **안**의 지어낸 호출은 여전히 잡힌다.
        startswith(String(ex.args[1]), ".") || push!(calls, ex.args[1])
    elseif ex.head === :(=) && ex.args[1] isa Expr && ex.args[1].head === :call &&
           ex.args[1].args[1] isa Symbol
        push!(locals, ex.args[1].args[1])            # `helper(x) = …` 지역 정의
    elseif ex.head === :(=) && ex.args[1] isa Symbol
        push!(locals, ex.args[1])                    # C-1: 람다·별칭·호출결과 대입,
                                                     # 그리고 `let q = …` · `for zz in …`
    elseif ex.head === :(=) && ex.args[1] isa Expr && ex.args[1].head === :tuple
        for t in ex.args[1].args                     # C-1: `(aa, bb) = (identity, identity)`
            t isa Symbol && push!(locals, t)
        end
    elseif ex.head === :function && ex.args[1] isa Expr && ex.args[1].head === :call &&
           ex.args[1].args[1] isa Symbol
        push!(locals, ex.args[1].args[1])            # 중첩 `function helper(x) … end`
    elseif ex.head === :. && length(ex.args) == 2 && ex.args[2] isa QuoteNode
        push!(fields, (ex.args[1], ex.args[2].value))
    elseif ex.head === :. && length(ex.args) == 2 && ex.args[1] isa Symbol &&
           ex.args[2] isa Expr && ex.args[2].head === :tuple
        push!(calls, ex.args[1])                     # C-5: 브로드캐스트 `f.(x)`
    end
    for a in ex.args; _walk_body!(calls, fields, locals, a); end
end

"""
    _d15_name_is_visible(s::Symbol) -> Bool

D15 가 "이 이름은 이 세계에 있다" 고 판정하는 **단일 술어**. 거절 루프도, 그 판정을 전수로
재는 테스트셋 (26) 도 이 함수 하나를 부른다 — 판정식을 두 곳에 적지 않는다.

🔴 **`names(@__MODULE__)` 이 네 번째 갈래인 이유**(2026-09-04 독립 검증 I-1).
   `isdefined` 삼중만으로는 인터페이스가 광고하는 148개 이름 중 **`battery_report`
   하나**가 안 보였다 — 정의가 **런타임 include** 되는 `src/navigator/battery.jl` 에 있어서
   include 전에는 `isdefined(CB, :battery_report) == false` 이고 include 후에는 `true` 다
   (실측). 즉 D15 의 판정이 **프로세스 상태에 의존**했다: 집행 하네스 넷은 navigator 를
   include 하므로 통과하고, navigator 를 안 켜는 레인에서는 같은 body 가 거절됐다.
   이 레포는 그 모양을 이미 밟았다(`DS_HOTSWAP` 하나가 발화율을 100%에서 23%로 옮겼다).
   `export battery_report` 는 `ConstructionBots.jl` 에 있고 Julia 의 `names(M)` 은 정의
   여부와 **무관하게** export 를 싣는다 — 그리고 `world_interface.json` 이 바로 그
   `names(CB)` 집합에서 생성된다. 그래서 이 갈래를 더하면 **D15 가 보는 이름 우주와
   agent-3 에게 광고한 이름 우주가 구성상 같아진다** — 하네스가 무엇을 include 했는지와
   무관하게. 넓히는 방향이므로 거절이 줄지 늘지 않는다.
"""
_d15_name_is_visible(s::Symbol) =
    isdefined(@__MODULE__, s) || isdefined(Base, s) || isdefined(Core, s) ||
    s in names(@__MODULE__)

"""
    _near_miss_names(c::Symbol; limit = 5) -> Vector{String}

거절된 호출 이름 `c` 와 `_` 토큰을 공유하는, **이 모듈이 실제로 export 하는** 이름들.
겹치는 토큰 수(내림) → 사전순으로 고르므로 **결정적**이다(`Dict`/`Set` 순회가 사유
문자열에 안 들어간다 — 시드 재현성 규약).

🔴 **왜 있는가**(2026-09-04 독립 검증 M-3). Task 9 의 `/rewrite` 가 이 사유 문자열을
   agent-3 에게 **바이트 그대로** 나른다. 필드 거절은 실제 필드 목록을 실어서 행동
   가능한데(`— fields are (id, node, spec)`) 호출 거절은 대안을 하나도 안 실었다 —
   되먹임 채널의 두 갈래 중 한쪽만 쓸모가 있었다. 지어내지 않는다: 후보는 전부
   `names(@__MODULE__)` 에서 오고, 그 집합이 산출물이 광고하는 표면과 같은 집합이다.
"""
function _near_miss_names(c::Symbol; limit::Int = 5)
    target = String(c)
    toks = Set(t for t in split(target, '_') if length(t) >= 3)
    isempty(toks) && return String[]
    scored = Tuple{Int,String}[]
    for n in names(@__MODULE__)
        str = String(n)
        (isempty(str) || str == target || startswith(str, "#")) && continue
        k = count(t -> t in toks, split(str, '_'))
        k == 0 && continue
        push!(scored, (-k, str))          # 겹침이 많을수록 앞, 같으면 사전순
    end
    sort!(scored)
    return String[str for (_, str) in scored[1:min(end, limit)]]
end

"""
    _concrete_struct(T) -> Union{Nothing,DataType}

`T` 를 **필드를 물어봐도 되는 타입**으로 좁힌다. 아니면 `nothing`("못 쟀다").

두 조건을 요구한다: (1) 비추상 struct 여야 필드 **이름**이 확정된다 — `Float64`·`Int64`
같은 primitive 와 추상 타입은 여기서 떨어진다(실측: `isstructtype(Float64)` = `false`).
🔴 **구체성(`isconcretetype`)을 요구하면 안 된다** — 처음에 그렇게 썼다가 시험 (22) 가
빨갰다. `ScheduleNode` 는 파라미터 있는 struct 라 `isconcretetype` 이 **false** 인데
(실측 2026-09-04), 파라미터를 몰라도 `fieldnames` 는 `(:id, :node, :spec)` 로 확정된다 —
우리가 묻는 것은 필드의 **타입**이 아니라 **이름**이므로 그 정도면 충분하다.

(2) 🔴 **`getproperty` 가 기본 구현이어야 한다.** 재정의한 타입에서는 `x.foo` 가
필드일 필요가 없으므로 `fieldnames` 로 판정하면 **거짓 거절**이 난다 — 아래
`_static_receiver_type` 이 `env` 에서 임의 깊이로 걸어 들어가므로 남의 패키지(LazySets ·
Graphs · DataStructures) 타입에 닿을 수 있고, 그 축은 우리가 통제 못 한다.

🔴 **모집단은 여덟이 아니라 39다** (2026-09-04 독립 검증 I-2 가 정정했고, 이 라운드에서
   다시 유도했다). 앞서 이 자리는 "오늘 닿는 여덟 타입" 이라고 적었는데 그 여덟은 시험이
   실제로 지나간 경로였지 폐포가 아니었다 — 이 레포는 머리말이 적은 근거를 다음 세션이
   검증 없이 전제로 읽는다.
   **39가 어떻게 유도된 집합인가**: `PlannerEnv` 에서 출발해 `_static_receiver_type` 이
   취하는 **두 걸음의 고정점**이다 — (a) 모든 필드에 대해 `fieldtype(S, f)`,
   (b) `S <: AbstractArray` 이면 `eltype(S)`. 각 후보는 위 (1) 의 술어
   (`isstructtype && !isabstracttype`, UnionAll 언랩)로 거른다. 그 폐포에는
   `LazySets.Ball2` · `Graphs.SimpleDiGraph` · `DataStructures.PriorityQueue` 처럼
   **남의 패키지 타입이 실제로 들어 있다** — 이 가드가 지키려는 축은 가상이 아니다.
   판정 결과: 가드가 판정을 요구받은 38개 타입 중 **`getproperty` 재정의 = 0개**.
   즉 결론("오늘은 전부 기본 구현")은 전수로 다시 재도 참이고, 가드가 없어도 **오늘은**
   같은 답이 나온다. 🔴 그래도 지운다는 뜻이 아니다: 재유도는 오늘의 스냅샷이고 그것을
   지키는 게이트는 여전히 없다.
   ⚠️ 0 은 반드시 비-0 대조와 짝지어 읽는다 — 같은 프로브에서
   `Base.Pairs`(= `getproperty` 재정의 타입)는 정확히 `false` 로 갈렸다.
"""
function _concrete_struct(T)
    T isa Type || return nothing
    S = T isa UnionAll ? Base.unwrap_unionall(T) : T
    (S isa DataType && isstructtype(S) && !isabstracttype(S)) || return nothing
    which(Base.getproperty, Tuple{S,Symbol}).sig ===
        Tuple{typeof(Base.getproperty),Any,Symbol} || return nothing
    return S
end

"""
    _static_receiver_type(recv) -> Union{Nothing,DataType}

`recv` 의 타입을 **확실히 아는 경우에만** 낸다. 그 외에는 전부 `nothing` — 모른다고 답한다.

뿌리는 `env`(= `PlannerEnv`) 하나뿐이고, 거기서 두 걸음만 인정한다:
필드 접근(`x.f`)과 **구체 eltype 을 가진 배열의 리터럴 정수 인덱싱**(`x[1]`).

🔴 **인덱스 모양을 본다** (2026-09-04 독립 검증 I-3). 전에는 `head === :ref` 이기만 하면
   `eltype` 로 나아갔고, 그래서 `env.sched.nodes[1:2]` 를 `ScheduleNode` 라고 답했다 —
   실제 타입은 `Vector{ScheduleNode}` 다(실측). 그 결과로 오늘 거절되는 것은 이미 틀린
   코드뿐이라 거짓 거절은 아직 없었지만, 아래 "각 걸음은 타입이 확정될 때만 나아간다" 는
   이 머리말의 주장이 그 자리에서 **참이 아니었다** — 과장된 머리말은 다음 세션이 검증
   없이 전제로 읽는 종류다. 지금은 인덱스가 **리터럴 `Integer` 하나**일 때만 나아간다:
   슬라이스(`[1:2]`) · 변수(`[i]`) · `[end]` · 다차원(`[1,2]`)은 전부 `nothing`("모른다")
   으로 떨어져 **통과**한다. 회귀 시험은 테스트셋 **(27)** 이다.

🔴 **왜 브리프가 적은 `env` / `env.<f>` 두 모양보다 넓은가 — 실측이 그렇게 시켰다.**
   브리프의 시험 (22) 은 `env.sched.nodes[1].assigned_robot` 이 거절되고 그 문장이
   `ScheduleNode` 의 실제 필드 `(id, node, spec)` 을 실어야 한다고 못박는다. 그런데
   그 수신자의 AST 는 `Expr(:ref, Expr(:., Expr(:., :env, :sched), :nodes), 1)` 이라
   `env.<f>` 두 모양으로는 **구조적으로 도달 불가능**이다 — 브리프의 도우미를 글자
   그대로 옮기고 돌린 결과 (22) 는 `why === nothing` 으로 빨갰다(실측 2026-09-04).
   그래서 넓힌 것은 **딱 그 두 걸음**이고, 각 걸음은 여전히 타입이 확정될 때만 나아간다.
🔴 **넓힌 방향은 안전한 쪽이 아니다 — 거짓 거절이 늘 수 있는 쪽이다.** 그래서 방어를
   `_concrete_struct` 에 몰아넣었고(위 docstring), 모르는 모양은 전부 `nothing` 으로
   떨어진다: `Dict` 인덱싱(`AbstractArray` 가 아니다), 호출 결과(`first(...)`), 지역
   변수(`sched.nodes` 처럼 `env` 에 뿌리를 안 둔 것), 추상 필드 타입. 시험 (24) 가 그 성질을
   음성으로 잰다.
"""
function _static_receiver_type(recv)
    recv === :env && return PlannerEnv
    if recv isa Expr && recv.head === :. && length(recv.args) == 2 &&
       recv.args[2] isa QuoteNode
        S = _static_receiver_type(recv.args[1])
        S === nothing && return nothing
        f = recv.args[2].value
        f in fieldnames(S) || return nothing      # 모르는 필드 → 타입도 모른다
        return _concrete_struct(fieldtype(S, f))
    end
    if recv isa Expr && recv.head === :ref && length(recv.args) == 2 &&
       recv.args[2] isa Integer
        S = _static_receiver_type(recv.args[1])
        (S === nothing || !(S <: AbstractArray)) && return nothing
        return _concrete_struct(eltype(S))
    end
    return nothing
end

"""
    check_impl_conventions(name, code) -> Union{Nothing,String}

설계 §5 의 규약 다섯. 통과하면 `nothing`, 아니면 **거절 사유**다. 순수 함수 —
`eval` 도 세계도 건드리지 않는다.

🔴 규약 1 이 존재 이유의 절반이다: `f(env; kw…)` 로 고정하면 `_enactability` 의
   arity·kwargs 연언지를 **구성상** 통과한다. 오늘 19개 중 9개를 막고 있는 그 결함
   (impl 이 params 를 위치인자로 받는다)이 새 원시에서는 원천적으로 안 생긴다.
   ✅ 2026-09-03 (판정 R18): 그 위치인자는 `env` **와 `env::T` 둘 다**다. 타입 표기는
   arity 도 호출가능성도 안 바꾸므로 규약 1 의 존재 이유를 하나도 안 흔든다 — 근거 전문은
   `_is_env_positional` 의 docstring 에 있다. **다시 조이지 말 것.**

🔴 **규약 2("문장 하나")는 "정의 하나"를 재지 "결속 하나"를 재지 않는다 — 결정, 사고가
   아니다**(2026-09-03 최종 리뷰 F16, 컨트롤러 판정 R15). `body` **안에** 중첩된 내부
   함수(예: `function outer!(env); helper(x) = x+1; return helper(1); end`)는 지금도
   통과한다(실측: `exprs` 가 `Expr(:function, ...)` 하나만 요구하고, 그 함수의 몸통
   안쪽은 안 들여다본다). **이것은 앞으로도 허용이다** — 재는 것은 "최상위 정의가
   정확히 하나" 이고, 그 하나의 정의 안에 사는 도우미 클로저는 그 규약을 하나도 안
   어긴다. 모델이 긴 몸통을 내부 클로저로 나눈 것은 잘못이 아니다. ✅ 2026-09-03
  (같은 리뷰 라운드): agent-3 에게 보여주는 프롬프트 문구(`src/respec/llm_service/
  world_interface.py` 의 규약 4)가 예전엔 "No other definitions -- no `const`,
  no macros, no helper functions." 라고 적어 이 규약과 글자로 어긋났다 — 컨트롤러가
  그 파일을 이 태스크에 임시로 열어 줘서 "최상위(top-level) 정의는 하나뿐, 몸통
  **안**의 도우미 클로저는 괜찮다" 로 고쳤다. 지금은 프롬프트와 이 검사기가 같은
  결론을 낸다.
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
   되먹임 문장 안에서 통째로 파괴됐다. 실측 대상 **넷**(`isdefined` 참 · export 거짓):
   `recover_stalled_teams!` · `resolve_schedule_wedge!` · `force_advance_stuck_carrier!` ·
   `forbid_heavy_cargo!`.
   🔴 **S4 (2026-09-04): `release_pending_assignments!` 는 이 목록에서 빠졌다.** 그 첫 측정은
   끝났고 답은 "모델이 그 능력을 다시 유도하지 못한다" 였다 — 세계 delta 5축이 전부 0 이고
   모델이 재배정 로직을 **주석으로** 썼다. 그래서 그 동사를 광고 목록에 넣었다(`export`).
   이제 그 이름을 고르면 `…_exists_shown` 이다(갈래는 `names(@__MODULE__)` 를 런타임에
   읽으므로 자동으로 따라온다 — `test/minted_registration.jl` 의 testset (12) 가 잰다).

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

    # 🔴 FIX C (2026-09-03, 판정 R18) — **진단이지 둘째 고침이 아니다.**
    #    마크다운 펜스를 벗기는 것은 **파이썬**의 몫이다(`llm_service/synthesize.py` 의
    #    `strip_code_fence`, 판정 R17 의 선례: LM 이 쓴 것을 정규화하는 자리는 LM 응답을
    #    먼저 보는 파이썬 하나다 — `params` 파싱도 `calls` 정규화도 거기서 한다).
    #    그러므로 정상 배관에서는 펜스가 **여기까지 못 온다.**
    #    🔴 진실원은 여전히 하나다: 파이썬은 **정규화**하고 줄리아는 **진단**한다. 여기
    #    펜스가 도착했다는 것은 파이썬의 정규화가 실패했다는 뜻이고, 그 사건은 조용하지
    #    말고 시끄러워야 한다. 이 사유가 없으면 그 사건은 `impl_not_a_function` 으로
    #    도착하는데(실측: Julia 가 ` ``` ` 를 삼중 백틱 **명령 리터럴**로 파싱해
    #    `Expr(:macrocall, Symbol("@cmd"), …)` 하나를 낸다), 그것은 모델에게 "함수를 안
    #    냈다" 는 **틀린** 수리 신호이고(agent-3 되먹임 채널이다) 우리에게는 배관 고장을
    #    가리키는 이름이 아니다.
    occursin(r"^\s*`{3,}", code) && return "reject:impl_code_is_fenced"

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
    (length(pos) == 1 && _is_env_positional(pos[1])) ||
        return "reject:impl_positional_args_must_be_exactly_env:$(pos)"
    for k in kws
        (k isa Expr && k.head === :kw) ||
            return "reject:impl_keyword_needs_a_default:$(k)"
    end

    # 🔴 D15. 지어낸 이름·필드는 **eval 전에** 거절한다. 실측(프로브 P2·P3): 오늘은
    #    둘 다 `Core.eval` 을 통과해 **집행 중에** UndefVarError 로 터진다 — 그때는 세계가
    #    이미 반쯤 편집됐을 수 있고, agent-3 에게 돌아갈 문장도 raw 예외다.
    # 🔴 **자리가 계약이다** — 이 검사는 규약 다섯 **전부의 뒤**에 온다. 특히
    #    `impl_not_single_expression`(규약 4) 뒤여야 한다: run 2 의 실제 코드는 최상위
    #    정의가 둘이면서 **동시에** 미정의 `find_suitable_robot` 을 부르므로, 앞으로
    #    옮기면 시험 (20) 의 바이트 고정(`reject:impl_not_single_expression:2`)이 D15
    #    사유로 갈린다. 그 시험은 규약 4 를 지키는 게이트다(D14) — 옮기지 말 것.
    local body = length(f.args) >= 2 ? f.args[2] : nothing
    if body !== nothing
        local cs, fs, ls = Symbol[], Tuple{Any,Symbol}[], Symbol[]
        _walk_body!(cs, fs, ls, body)
        # 시그니처의 키워드 이름도 지역이고, 🔴 **기본값도 걷는다**(2026-09-04 독립 검증
        # M-2). 기본값은 매 호출에서 평가되므로 거기 있는 지어낸 이름은 진짜 집행-중
        # UndefVarError 경로다. 🔴 **body 를 걸은 뒤에** 걷는 것은 계약이다: 사유는
        # `unique(cs)` 의 **첫** 미지 이름이 정하므로, 순서를 바꾸면 시험 (18)·(20) 이
        # 바이트로 고정한 사유가 갈릴 수 있다.
        for k in kws
            k isa Expr && !isempty(k.args) || continue
            local a1 = k.args[1]
            a1 isa Symbol && push!(ls, a1)
            a1 isa Expr && a1.head === :(::) && !isempty(a1.args) &&
                a1.args[1] isa Symbol && push!(ls, a1.args[1])
            k.head === :kw && length(k.args) >= 2 && _walk_body!(cs, fs, ls, k.args[2])
        end
        push!(ls, :env, Symbol(name))
        for c in unique(cs)
            (c in ls) && continue
            _d15_name_is_visible(c) && continue        # 🔴 판정식은 그 술어 하나다
            local near = _near_miss_names(c)
            return "reject:impl_unknown_call:$(c) — 이 이름의 함수는 이 모듈에도 Base 에도 " *
                   "없다. 세계 인터페이스가 실제로 가진 함수만 부르거나, 도우미를 body " *
                   "**안쪽**에 정의하라" *
                   (isempty(near) ? "" : " — 가까운 이름: " * join(near, ", "))
        end
        for (recv, fld) in fs
            S = _static_receiver_type(recv)
            S === nothing && continue                # 🔴 모르면 통과 (시험 (24))
            fld in fieldnames(S) && continue
            return "reject:impl_unknown_field:$(nameof(S)).$(fld) — fields are " *
                   "($(join(String.(collect(fieldnames(S))), ", ")))"
        end
    end
    return nothing
end

"""
    impl_param_types(code) -> Dict{String,Any}

시그니처의 키워드에서 **타입 주석**만 뽑는다. 값은 **삼상**이다:

| 이 키워드는 | `param_types` 에서 | `bind_primitive_args` 는 |
|---|---|---|
| 주석이 없다 | **키가 없다** | 값을 그대로 흘린다 (오늘의 동작) |
| 주석이 있고 우리가 읽었다 | `Type` | `convert` 하거나 `reject:param_convert:` |
| 주석이 있는데 못 읽었다 | 주석의 **원문**(`String`) | `reject:param_annotation_unreadable:` |

🔴 `nothing` 은 어느 상태에서도 값으로 안 들어간다(삼상 규약).

🔴 **셋째 상태는 2026-09-04 fix round 1 (F3) 에 생겼다.** 초판은 못 읽는 주석의 키를
   **버렸는데**, 버리면 `Vector{<:AbstractString}` 같은 철자에서 JSON3 뷰가 그대로 흘러
   호출이 `TypeError` 로 죽는다 — 그리고 그것은 거절이 아니라 **예외**라 `enact_minted!`
   의 catch 가 손도 안 댄 세계를 `partial=true → handled=true` 로 적어 폴백을 삼킨다.
   즉 조용히 버리는 것이 이 태스크가 없애려던 바로 그 사건을 남기는 선택지였다.
   ⚖️ 대신 갚는 대가: 못 읽는 주석을 단 키워드는 값이 **실제로 올 때** 거절된다(안 오면
   오늘과 같다). 모양을 더 읽는 쪽(`:<:`·`:where` 갈래 추가)을 안 고른 이유는 둘이다 —
   (1) 그 모양들은 읽어 봐야 `convert(Vector{<:AbstractString}, ::JSON3.Array)` 자체가
   `MethodError` 라 결국 같은 거절로 끝난다, (2) F1 의 구멍이 바로 모양 게이트라 그것을
   닫은 커밋에서 같은 게이트를 넓히는 것은 방향이 반대다.

🔴 **eval 을 돈다. 그리고 이 함수의 모양 검사는 샌드박스가 아니다** (F1, 2026-09-04).
   `T` 는 모델이 쓴 **AST 조각**이지 `Type` 이 아니라 `Core.eval` 이 필요하다.
   `_is_type_shape` 는 그 eval 에 들어가는 것을 **타입 표현식의 모양**으로 좁힐 뿐이고,
   좁힘은 봉쇄가 아니다: Julia 는 kwarg 타입 주석을 **메서드 정의 시점에** 평가하므로
   같은 주석이 아래 `register_minted_primitive!` 의 본래 `Core.eval` 에서 어차피 돈다
   (부모 커밋 `80c62d49` 에서도 그랬다 — 실측). 그러므로 이 검사의 값은 "임의 코드를
   막는다" 가 아니라 **"이 조용한 eval(`catch; continue`)이 본래의 eval 보다 먼저,
   사유 없이 도는 일을 줄인다"** 이다.
   진실원: `test/minted_registration.jl` testset (29).

🔴 **`check_impl_conventions` 와 일부러 중복한다**(P5). 그 함수는 `Union{Nothing,String}` 을
   돌려주므로 타입을 실어 보낼 자리가 없고, 반환형을 넓히면 호출자 전부와 시험 열몇이
   따라 바뀐다. 키워드 블록을 두 번 걷는 값이 그것보다 싸다.
"""
function impl_param_types(code::AbstractString)
    out = Dict{String,Any}()
    local top
    try; top = Meta.parseall(code); catch; return out; end
    exprs = [x for x in top.args if !(x isa LineNumberNode)]
    length(exprs) == 1 || return out
    f = exprs[1]
    (f isa Expr && f.head === :function) || return out
    sig = f.args[1]
    (sig isa Expr && sig.head === :call) || return out
    kb = findfirst(x -> x isa Expr && x.head === :parameters, sig.args[2:end])
    kb === nothing && return out
    for k in sig.args[2:end][kb].args
        (k isa Expr && k.head === :kw) || continue
        lhs = k.args[1]
        (lhs isa Expr && lhs.head === :(::) && length(lhs.args) == 2 &&
         lhs.args[1] isa Symbol) || continue
        local nm = String(lhs.args[1])
        texpr = lhs.args[2]
        if !_is_type_shape(texpr)
            out[nm] = _unreadable_annotation(texpr); continue
        end
        local T
        try
            T = Core.eval(@__MODULE__, texpr)
        catch
            out[nm] = _unreadable_annotation(texpr); continue
        end
        if !(T isa Type)
            out[nm] = _unreadable_annotation(texpr); continue
        end
        out[nm] = T
    end
    return out
end

"""
못 읽은 주석을 **원문**으로 적는다. `Type` 이 아닌 값이 param_types 에 들어가는 유일한
자리이고, `bind_primitive_args` 는 `T isa Type` 하나로 그 상태를 가른다.
거절 사유에 그대로 실리므로 길이를 자른다 — 사유 문자열은 D17 이 모델에게 되먹인다.

🔴 **파서가 붙인 라인노트는 안 싣는다**(2026-09-04 fix round 2, NEW-4). 주석이 블록
   표현식이면 `string(texpr)` 이 `#= none:1 =#` 를 섞어 넣는데(실측:
   `q::(if true; Int; else; Float64; end)`), 그것은 **모델이 쓴 원문이 아니라** 파서의
   부산물이고 D17 이 그것을 agent-3 에게 되먹인다.
   ⚠️ 기록의 "사유는 **한 줄**" 계약을 지키는 자리는 여기가 아니다 — 사유가 레코드로
   들어가는 유일한 자리(`enact_minted!` 안의 `_r`)가 진다. 원천이 이 함수만이 아니기
   때문이다(`unknown_zone_key` 도 모델이 준 값을 그대로 싣는다).
"""
function _unreadable_annotation(texpr)
    local t = try string(texpr) catch; "?" end
    t = replace(t, r"#=.*?=#" => "")
    return length(t) > 120 ? first(t, 117) * "..." : t
end

"""
타입 표현식의 **모양**인가. 호출·보간·매크로는 전부 거짓이다.

🔴 **이것은 샌드박스가 아니라 좁힘이다** (2026-09-04 fix round 1, F1). `false` 를 냈다고
   그 주석이 안 돌아가는 것이 아니다 — Julia 는 kwarg 타입 주석을 **메서드 정의 시점에**
   평가하므로 `register_minted_primitive!` 의 본래 `Core.eval` 이 어차피 돌린다(부모 커밋
   에서도 그랬다). 여기가 막는 것은 `impl_param_types` 의 **조용한** eval
   (`catch; continue` — 사유를 안 남긴다)뿐이다. 진실원: `test/minted_registration.jl`
   testset (29). 이 docstring 의 이전 판은 "eval 이 임의 코드를 돌릴 수 있다, 그래서
   모양만 통과시킨다" 고 적어 봉쇄를 주장했고 그것이 **측정으로 거짓**이었다.

🔴 `:.` 갈래는 `e.args[1]` 도 **재귀로** 검사한다. 안 하면 `args[1]` 이 아무 표현식이나
   될 수 있어 `write(path, "PWNED").x` 가 모양 게이트를 통과했다(리뷰가 파일 생성·삭제를
   실측했고, `open(io->(T=Int,), path, "a").T` 는 진짜 `Type` 을 돌려주며 **사유 없이**
   등록까지 성공시켰다). 시그니처에 있는 호출이라 `_walk_body!`(몸통만 걷는다)의
   `impl_unknown_call` 도 못 본다. 재귀를 넣어도 정당한 여덟 모양은 하나도 안 깎인다(실측).

🔴 `Integer`·`QuoteNode` 갈래는 계획서 초안에 없었고 **실측으로 더했다**(2026-09-04).
   초안의 세 갈래(`Symbol` · `:curly` · 점 이름)만으로는 `Array{String,1}` 이 거짓이다 —
   `Expr(:curly, :Array, :String, 1)` 의 셋째 인자가 `Symbol` 도 `Expr` 도 아닌 `Int` 라
   `all(_is_type_shape, …)` 가 무너진다. 그것은 정확히 시험 (7) 이 쓰는 주석이고,
   `Vector{String}` 의 가장 흔한 다른 철자다. 같은 구멍에 `NTuple{3,Int}`·`Val{:x}` 도
   걸렸다(11 모양 프로브: 초안은 5/11, 지금은 8/11 — 나머지 셋 `f(x)`·`\$(T)`·`where` 는
   **일부러** 거짓이다). 리터럴 정수와 `QuoteNode(:sym)` 은 코드가 아니라 값이므로
   `Core.eval` 로 무엇도 실행시킬 수 없다 — 넓히는 대가가 없다.
"""
_is_type_shape(e) =
    e isa Symbol ||
    e isa Integer ||                                     # `Array{String,1}` 의 `1`
    (e isa QuoteNode && e.value isa Symbol) ||           # `Val{:x}`
    (e isa Expr && e.head === :curly && all(_is_type_shape, e.args)) ||
    (e isa Expr && e.head === :. && length(e.args) == 2 &&
     _is_type_shape(e.args[1]) && e.args[2] isa QuoteNode)   # 🔴 F1: 수신자도 모양이어야 한다

"""
    _world_interface_path() -> Union{Nothing,String}

agent-3 에게 렌더되는 세계 인터페이스 산출물의 경로. 패키지 뿌리를 못 찾으면 `nothing`
이다(그 경우 L3 은 "못 쟀다" 가 된다 — 지어낸 경로로 조용히 넘어가지 않는다).
"""
_world_interface_path() =
    (d = pkgdir(@__MODULE__);
     d === nothing ? nothing :
     joinpath(d, "wm4spacecraft_manufacturing", "core", "world_interface.json"))

"""
    _artifact_interface_names(path = _world_interface_path()) -> Union{Nothing,Set{Symbol}}

**"모델에게 보여 준 이름" 의 유일한 자리**(F-2 · 판정 R32). 산출물에서 읽는다 — 여기에
리터럴 목록을 적지 않는다. 네 갈래는 `build_world_interface_block`
(`src/respec/llm_service/world_interface.py`)이 프롬프트에 실제로 렌더하는 것 그대로다:

  · `methods[].name`        — "FUNCTIONS YOU CAN CALL NOW" · "…CANNOT OBTAIN YET" 두 표제
  · `types[].name`          — "WORLD TYPES" 표제(생성자로 부를 수 있는 이름이다)
  · `types[].subtypes[]`    — 같은 표제의 `(abstract; one of: …)` 줄
  · `ambient[].accessor`    — "AMBIENT WORLD STATE" 표제, `(` 앞까지

🔴 **던지지 않는다.** 등록 경로가 이것을 부르는데, 이 파일 전체의 규약이 "예외가 아니라
   거절" 이다. 없는 파일 · 디렉터리 · 깨진 JSON · **모양이 아닌 JSON** 전부 `nothing` 이다.

🔴 **틀린 타입에서 값을 조용히 재지 않는다.** `{"methods": 5}` 는 빈 집합이 아니라
   `nothing` 이다 — 빈 집합을 냈다면 그 뒤의 교집합이 **아무 이름도 없는 인터페이스**로
   조용히 `[]`("재서 없다") 를 만들어 낸다. 이 계획은 그 모양을 이미 두 번 밟았다
   (`_world_delta(bad, ok)` 가 문자열 길이를 `n_binding_changed` 로 냈다). 같은 이유로
   **빈 결과도 `nothing`** 이다 — 이름 0개인 인터페이스는 측정이 아니라 고장이다.

⚠️ **캐시가 없다**(의도). 파일은 83KB 고 이 함수는 등록 한 번에 한 번 돈다. 도장 캐시를
   두면 다시 생성된 산출물을 조용히 놓치는 창이 생긴다 — 이 레포는 나흘 묵은 서비스
   프로세스로 이미 그 값을 치렀다.
"""
function _artifact_interface_names(path::Union{Nothing,AbstractString} = _world_interface_path())
    path isa AbstractString || return nothing
    out = Set{Symbol}()
    try
        isfile(path) || return nothing
        j = JSON3.read(read(path, String))
        j isa JSON3.Object || return nothing
        for k in (:methods, :types, :ambient)
            haskey(j, k) && j[k] isa JSON3.Array || return nothing
        end
        for m in j[:methods]
            m isa JSON3.Object && haskey(m, :name) && m[:name] isa AbstractString ||
                return nothing
            push!(out, Symbol(m[:name]))
        end
        for t in j[:types]
            t isa JSON3.Object && haskey(t, :name) && t[:name] isa AbstractString ||
                return nothing
            push!(out, Symbol(t[:name]))
            haskey(t, :subtypes) || continue
            t[:subtypes] isa JSON3.Array || return nothing
            for sub in t[:subtypes]
                sub isa AbstractString || return nothing
                push!(out, Symbol(sub))
            end
        end
        for a in j[:ambient]
            a isa JSON3.Object && haskey(a, :accessor) && a[:accessor] isa AbstractString ||
                return nothing
            push!(out, Symbol(first(split(a[:accessor], "("))))
        end
    catch
        return nothing                      # 🔴 예외가 아니라 "못 쟀다"
    end
    return isempty(out) ? nothing : out
end

"""
    impl_interface_calls(code; artifact = _world_interface_path()) -> Union{Nothing,Vector{String}}

**L3 의 생산자** (spec §0, 판정 R24). body 의 정적 호출 대상 중 **세계 인터페이스에 있는
것들**을 정렬된 이름 목록으로 낸다. `eval` 도 세계도 표도 안 건드리고 던지지도 않는다.
⚠️ **순수하지는 않다**(F-2 이후): 인터페이스 목록을 산출물 파일에서 읽는다 — 아래
`_artifact_interface_names` 하나를 통해서다.

🔴 **왜 별도 함수인가** (P5). spec §0 의 L3 행은 이 값을 "D15 의 AST 순회가 이미 만드는
   값" 이라고 적는데, 그 `cs` 는 `check_impl_conventions` 안에서 **버려진다**(Task 6 리뷰
   §7-2 가 실측했고 Task 10 사전등록이 독립적으로 같은 결론에 도달해 결정 12 로 적었다 —
   그래서 L3 이 오늘 `nothing` 이다). 그 함수의 반환형(`Union{Nothing,String}`)을 넓히면
   호출자 전부와 시험 열몇이 따라 바뀐다. 그래서 `impl_param_types` 와 **같은 패턴**으로
   짓는다: 같은 도우미(`_walk_body!`)를 다시 부르는 독립 순수 함수.

🔴 **삼상 규약** — 이 셋이 무너지면 L3 을 못 읽는다.

| 반환 | 뜻 | 언제 |
|---|---|---|
| `nothing` | **못 쟀다** | 순회할 함수 정의에 도달 못 했다(파스 실패 · 최상위 정의가 하나가 아님 · `function` 이 아님 · 시그니처가 호출 모양이 아님) **또는 인터페이스 목록을 못 읽었다**(F-2: 산출물이 없다 · 못 읽는다 · 모양이 아니다). 🔴 못 읽은 인터페이스는 `[]` 가 아니다 — 그렇게 적으면 "안 불렀다" 와 "인터페이스를 모른다" 가 한 값이 된다 |
| `String[]` | **재서 없다** | 걸었는데 인터페이스 이름을 하나도 안 불렀다 |
| 비어 있지 않은 `Vector{String}` | 인터페이스 함수를 불렀다 | L3 = `!isempty(...)` |

🔴 **왜 원본 호출 대상이 아니라 교집합을 내는가.** L3 의 판정식 자체가
   "정적 호출 대상 ∩ 인터페이스 ≠ ∅" 이다. 원본을 실어 보내면 **인터페이스 술어가 두
   곳에 살게 되고**(여기와 읽는 쪽), 기록에 실린 값의 뜻이 나중에 누가 어떤 필터를
   거는지에 달린다 — 이 파일이 지키는 진실원 하나 규약을 어긴다. 그리고 원본에는 지역
   이름 · Base · 자기 자신이 섞여 있어 L3 의 증거가 **아니다**. 이름을 불리언이 아니라
   **목록**으로 남기는 이유는 그 반대쪽이다: 나중에 더 좁게(예: 산출물의 `methods` 블록만)
   다시 세고 싶으면 목록에서 재유도할 수 있지만 불리언에서는 못 한다.

🔴 **인터페이스 = 산출물이 광고하는 이름**(F-2 · 판정 R32, 2026-09-04). `names(CB)` 가
   **아니다.** spec §0 의 L3 판정식은 "정적 호출 대상 ∩ **인터페이스**" 이고 인터페이스는
   **모델에게 보여 준 것**이다. 그 목록의 유일한 자리는 `_artifact_interface_names` 다.

   🔴 **왜 `names(CB)` 가 틀렸는가.** 이 자리의 옛 머리말은 `names(CB)`(187)와 산출물이
   광고하는 메서드 이름(148)의 차 39를 "전부 모델에게 보이는 표면" 이라고 적었다. 그것이
   거짓이었다(2026-09-04 재유도). 39 중 **18** 은 산출물의 `types` 블록이 실제로
   광고하므로 인터페이스가 맞지만, 나머지 **21** 은 산출물이 이름으로 광고하지 않는다 —
   그중 18 은 산출물 본문에 **한 글자도 안 나오고**(`SwapBattery` · `ForbidZone` ·
   `TranslateBuild` · `ReplaceAgent` · `RelocateBuild` 를 포함한다 — D-9 이 행동공간에서
   뺀 행동 타입들인데 **생성자로는 여전히 부를 수 있다**), 셋(`ConstructionBots` ·
   `NoveltyDetector` · `RespecProposal`)은 남의 시그니처 문자열 안에만 나온다.
   좁히기 전에는 그 21 중 하나를 **찍기만 해도** "우리가 준 인터페이스를 썼다" 는 뜻의
   등급이 초록이 됐다. 🔴 숫자와 목록의 진실원은 이 주석이 아니라 테스트셋 (34) 다 —
   그것이 산출물에서 매번 다시 유도한다.

   ⚠️ **대가**(R32 가 알고 고른 것). 우리가 광고하지 않은 진짜 CB 함수를 부른 body 는
   이제 `[]` 를 받는다. "우리가 준 인터페이스를 썼는가" 에는 그것이 정직한 답이고,
   "실재하는 무엇을 불렀는가" 는 L3 의 질문이 아니다(그 질문의 자리는 D15 다).

   🔴 **`_d15_name_is_visible` 은 이 좁힘의 대상이 아니다** — 좁히면 안 된다. 그쪽 질문은
   "이 이름이 실재하는가 = 거절하면 안 되는가" 라서 `names(CB)` 가 맞고, 그 폭이 게이트
   레인과 집행 레인을 구성상 같게 만든다(테스트셋 (26)). 두 술어는 다른 질문이다.
   그리고 그것을 여기서 그대로 쓰면 **안 된다** — `Base`/`Core` 까지 포함하는 넓은
   술어라 `println` 호출이 L3 을 초록으로 만든다.

⚠️ **`check_impl_conventions` 와 같은 순회를 쓴다**(body → 키워드 기본값 순). 그것이
   spec §0 의 괄호("D15 의 AST 순회가 이미 만드는 값")가 뜻하는 바다. 지역 결속 이름 ·
   `env` · 자기 이름은 D15 와 **같은 규칙으로** 제외된다 — 지역에 담긴 이름을 부른 것은
   인터페이스를 부른 것이 아니다.

⚠️ **이 함수는 거절을 만들지 않는다.** 무엇을 돌려주든 등록은 안 막힌다 — 계측 채널이다.
"""
function impl_interface_calls(code::AbstractString;
                              artifact::Union{Nothing,AbstractString} = _world_interface_path())
    local top
    try; top = Meta.parseall(code); catch; return nothing; end
    any(x -> x isa Expr && x.head in (:incomplete, :error), top.args) && return nothing
    exprs = [x for x in top.args if !(x isa LineNumberNode)]
    length(exprs) == 1 || return nothing
    f = exprs[1]
    (f isa Expr && f.head === :function) || return nothing
    sig = f.args[1]
    (sig isa Expr && sig.head === :call) || return nothing
    local cs, fs, ls = Symbol[], Tuple{Any,Symbol}[], Symbol[]
    # 🔴 순서는 `check_impl_conventions` 와 같다: body 먼저, 키워드 기본값 나중.
    length(f.args) >= 2 && _walk_body!(cs, fs, ls, f.args[2])
    local rest = sig.args[2:end]
    local kwblock = findfirst(x -> x isa Expr && x.head === :parameters, rest)
    if kwblock !== nothing
        for k in rest[kwblock].args
            k isa Expr && !isempty(k.args) || continue
            local a1 = k.args[1]
            a1 isa Symbol && push!(ls, a1)
            a1 isa Expr && a1.head === :(::) && !isempty(a1.args) &&
                a1.args[1] isa Symbol && push!(ls, a1.args[1])
            k.head === :kw && length(k.args) >= 2 && _walk_body!(cs, fs, ls, k.args[2])
        end
    end
    push!(ls, :env)
    sig.args[1] isa Symbol && push!(ls, sig.args[1])   # 자기 이름(재귀)은 인터페이스가 아니다
    # 🔴 F-2. 인터페이스는 산출물이다. 못 읽으면 `[]`("재서 없다") 가 아니라
    #    `nothing`("못 쟀다") — 순회는 됐지만 **무엇과 교집합할지를 모른다**.
    #    순회 뒤에 읽는다: 걷지도 못한 입력은 파일 I/O 를 치르지 않는다.
    local iface = _artifact_interface_names(artifact)
    iface === nothing && return nothing
    local out = String[String(c) for c in unique(cs) if !(c in ls) && c in iface]
    sort!(out)                       # 🔴 결정적 — `Set`/`Dict` 순회가 기록에 안 들어간다
    return out
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
    # 🔴 D16. 키워드의 **선언 타입**을 여기서 뽑는다 — 규약 검사가 통과한 뒤, `Core.eval`
    #    **전에**(F7 의 "검증은 eval 앞" 불변식 안쪽이다). 던지지 않으므로 부분 등록을 새로
    #    만들지 않는다. 못 읽는 주석은 거절도 아니고 버려지지도 않는다 — 원문이 실려
    #    `bind_primitive_args` 가 **값이 실제로 올 때** 거절한다(삼상, F3).
    #    ⚠️ 이 함수는 타입 표현식에 `Core.eval` 을 돈다. 아래 `Core.eval` 이 어차피 같은
    #    주석을 평가하므로 새 능력은 아니지만 **순수하지도 않다** — 그 docstring 을 볼 것.
    local _ptypes = impl_param_types(code)
    # 🔴 L3 의 생산자(판정 R24). `impl_param_types` 와 같은 자리·같은 성질이다 — 규약 검사
    #    통과 뒤, `Core.eval` 전, 순수, 던지지 않음, 거절을 만들지 않음.
    local _icalls = impl_interface_calls(code)
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
        # 🔴 D16. 키워드 이름 → `Type`(읽었다) 또는 주석 원문 `String`(못 읽었다).
        #    `bind_primitive_args` 가 이것으로 JSON3 의 지연 뷰를 네이티브 컨테이너로
        #    바꾼다 — Julia 의 키워드 인자는 `convert` 가 아니라 **타입 단언**이라 경계가
        #    안 바꿔 주면 호출이 `TypeError` 로 죽는다(실측 P1).
        #    주석 없는 키워드는 **키가 없다**(삼상 규약 — `impl_param_types` 의 표).
        "param_types"  => _ptypes,
        # 🔴 L3 (spec §0, 판정 R24). body 의 정적 호출 대상 ∩ 세계 인터페이스, 정렬됨.
        #    판정은 `!isempty(...)` 이고, **삼상**이다: `nothing`(못 쟀다) ≠ `[]`(재서 없다).
        #    이름은 여기 하나뿐이다 — 같은 사실에 둘째 이름을 붙이지 말 것(진실원 하나).
        #    읽는 자리: 이 열, 또는 `resolve_primitive(name).interface_calls`.
        "interface_calls" => _icalls,
        # 🔴 C1 (2026-09-03 최종 리뷰). **이 행이 생성 코드에서 왔다**는 표시. 집행부의
        #    `_step_applied`·`_step_touched_world` 가 이것을 읽어 "이 원시의 status 어휘를
        #    아는 표가 없다" 를 안다. 판별자가 "`minted_table()` 에 있는가" 이면 안 되는
        #    이유: 알려진 원시 여덟도 (시험·프로브가) **손으로 씨 뿌려** 같은 표에 들어온다.
        #    구별되는 사실은 오직 "`Core.eval` 로 주조됐는가" 이고, 그것을 아는 곳은 여기뿐이다.
        "generated"    => true)
    return nothing
end
