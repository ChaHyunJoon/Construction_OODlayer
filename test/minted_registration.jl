# =============================================================================
# 🔴 R-RERUN: 이 파일은 같은 Julia 세션에서 **한 번만** 안전하게 돈다.
#    testset (5)(`register_minted_primitive!`, Task 4)가 `adjust_thing!` 을
#    `Core.eval` 로 ConstructionBots 에 심는다. 같은 세션에서 이 파일을 다시
#    include 하면 testset (4)의
#    `check_impl_conventions("adjust_thing!", OK_CODE) === nothing` 이
#    `"reject:impl_name_exists:..."` 로 빨개진다 — `adjust_thing!` 이 이제
#    "기존 이름" 이기 때문이다(규약 5). 검증은 매번 새 프로세스로 할 것:
#    `julia +lts --project=. -e 'include("test/minted_registration.jl")'`
#    🔴 이 파일이 CB 에 **영구히** 심는 이름(2026-09-03 최종 리뷰로 늘었다):
#    `adjust_thing!` · `touch_nothing!` · `single_frame_thing!` · `measures_nothing!` ·
#    `returns_a_symbol!` · `twice_minted!`. 되돌리는 길은 없다 — testset (13) 이 그 사실
#    자체를 잰다.
# =============================================================================
module MintedRegistration
using Test
using ConstructionBots
const CB = ConstructionBots

@testset "(1) 표는 런 스코프이고 빈 채로 시작한다" begin
    CB.reset_minted_table!()
    @test isempty(CB.minted_table())
    # 🔴 파일에서 씨를 받지 않는다 — 지운 레지스트리를 다시 읽으려 하면 여기서 죽는다.
    @test CB.resolve_primitive("release_pending_assignments") === nothing
    @test CB.resolve_primitive("anything_at_all") === nothing
end

@testset "(2) 표에 넣으면 해석된다" begin
    CB.reset_minted_table!()
    CB.minted_table()["reform_stuck_teams"] = Dict{String,Any}(
        "name" => "reform_stuck_teams", "impl" => "reform_stuck_teams!",
        "surface" => "sched", "harness_args" => ["env"],
        "params" => Dict{String,Any}(), "reversible" => false)
    r = CB.resolve_primitive("reform_stuck_teams")
    @test r !== nothing && r.name == "reform_stuck_teams"
    @test r.harness_args == ["env"]
end

@testset "(3) 리셋은 실제로 비운다" begin
    @test !isempty(CB.minted_table())
    CB.reset_minted_table!()
    @test isempty(CB.minted_table())
end

const OK_CODE = """
function adjust_thing!(env; factor = 1.0)
    return (status = :adjusted, factor = factor)
end
"""

@testset "(4) 규약 다섯" begin
    @test CB.check_impl_conventions("adjust_thing!", OK_CODE) === nothing

    # 규약 1: env 만 위치인자
    bad1 = "function f!(env, other; k = 1)\n    return :ok\nend\n"
    @test occursin("positional", something(CB.check_impl_conventions("f!", bad1), ""))

    # 규약 1: 키워드는 기본값이 있어야 한다
    bad2 = "function f!(env; k)\n    return :ok\nend\n"
    @test CB.check_impl_conventions("f!", bad2) !== nothing
    # 🔴 F3(2026-09-03): 실제로 나는 사유를 못박는다 — `!== nothing` 만 재면 사유가 틀려도
    #    초록이다. `:parameters` 블록이 `Expr(:call,...)` 의 args 에서 위치인자보다 **먼저**
    #    오는 것을 실측으로 확인했다(`f!(env; k)` → `Expr(:call, :f!, Expr(:parameters, :k),
    #    :env)`) — `check_impl_conventions` 는 `findfirst` 로 위치 무관하게 찾으므로 이 사유가
    #    맞다.
    @test CB.check_impl_conventions("f!", bad2) == "reject:impl_keyword_needs_a_default:k"

    # 규약 4: 최상위 표현식이 둘
    bad3 = "const X = 1\nfunction f!(env; k = 1)\n    return :ok\nend\n"
    @test occursin("single_expression", something(CB.check_impl_conventions("f!", bad3), ""))

    # 규약 4: 함수가 아니다
    @test CB.check_impl_conventions("f!", "x = 1\n") !== nothing

    # 이름 불일치
    @test occursin("name_mismatch",
                   something(CB.check_impl_conventions("g!", OK_CODE), ""))

    # 규약 5: 🔴 기존 이름을 덮으면 시뮬레이터 코드를 런타임에 교체하는 것이다
    clash = "function reform_stuck_teams!(env; k = 1)\n    return :ok\nend\n"
    @test occursin("name_exists",
                   something(CB.check_impl_conventions("reform_stuck_teams!", clash), ""))

    # 파싱 불가 — 잘린 입력(unterminated). 🔴 F3(2026-09-03, 컨트롤러 실측 재확인): 이 코드는
    #    `Meta.parseall` 이 **던지지 않는다** — 대신 `top.args` 안에 `Expr(:incomplete, ...)`
    #    를 데이터로 심는다. 옛 단언(`!== nothing`)은 사유가 `impl_not_a_function`(완전히
    #    틀린 사유 — agent-3 에게 "함수를 안 냈다" 대신 "잘렸다"고 말해야 한다)이어도 초록
    #    이었다. 사유 문자열 자체를 못박는다.
    trunc = CB.check_impl_conventions("f!", "function f!(env; k = 1)\n")
    @test trunc !== nothing
    @test startswith(something(trunc, ""), "reject:impl_parse_failed:")

    # 파싱 불가 — 또 다른 깨진 입력 종류: 남는 `end`(뒤쪽 문에서 깨진다. 앞쪽 문은 완전한
    # 함수라 `Expr(:function,...)` 로 정상 파싱된다 — `:error` 노드는 **두 번째** top.args
    # 원소로 온다는 것까지 실측으로 확인했다).
    stray_end = "function f!(env; k = 1)\n    return :ok\nend\nend\n"
    r_stray = CB.check_impl_conventions("f!", stray_end)
    @test r_stray !== nothing
    @test startswith(something(r_stray, ""), "reject:impl_parse_failed:")
end

@testset "(5) 등록하면 해석되고 집행 가능하다" begin
    CB.reset_minted_table!()
    why = CB.register_minted_primitive!(
        name = "adjust_thing!", code = OK_CODE,
        params = Dict{String,Any}("factor" => Dict{String,Any}("type" => "number")),
        surface = "env_param", reversible = true)
    @test why === nothing
    r = CB.resolve_primitive("adjust_thing!")
    @test r !== nothing
    # 🔴 규약 1 의 값: 구성상 집행 가능해야 한다. 오늘 19개 중 9개를 막는 arity 결함이
    #    새 원시에서는 안 생긴다는 것이 이 한 줄로 측정된다.
    @test r.enactable === true
    @test r.harness_args == ["env"]
    @test haskey(r.params, "factor")
end

@testset "(6) 규약 위반은 거절이고 표를 안 건드린다" begin
    CB.reset_minted_table!()
    why = CB.register_minted_primitive!(
        name = "bad!", code = "function bad!(env, x; k = 1)\n    return :ok\nend\n",
        params = Dict{String,Any}(), surface = "sched", reversible = false)
    @test why !== nothing && occursin("positional", why)
    @test isempty(CB.minted_table())          # 부분 등록이 없다
end

@testset "(7) eval 실패는 예외가 아니라 거절이다" begin
    CB.reset_minted_table!()
    why = CB.register_minted_primitive!(
        name = "boom!", code = "function boom!(env; k = 1)\n    @no_such_macro\nend\n",
        params = Dict{String,Any}(), surface = "sched", reversible = false)
    @test why !== nothing && occursin("eval_failed", why)
    @test isempty(CB.minted_table())
end

# 🔴 이 testset 혼자서는 invokelatest 누락을 못 잡는다(2026-09-03 컨트롤러 F1 실측).
#    `@testset` 본문은 top-level 인터프리터 경로로 평가되므로, 그 안에서
#    `register_minted_primitive!` 를 부른 뒤 **별도의 문**으로 `enact_minted!` 를 불러도
#    각 문이 그때그때 최신 world 를 다시 조회한다 — world age 가 얼지 않는다. 실제로
#    `src/respec/minted_tool.jl` 의 `invokelatest` 를 원래의 raw 호출로 되돌려도 이 testset은
#    5/5 로 통과한다(측정 완료, 아래 testset (9) 참고). world age 동결은 **eval 과 그 결과를
#    부르는 호출이 하나의 컴파일된 함수 프레임 안에** 같이 있을 때만 걸린다 — 계획의
#    Task 9(`enact_minted_decision!`)가 만들 실제 프로덕션 모양이 정확히 그것이다.
@testset "(8) 🔴 방금 eval 한 함수를 같은 호출 스택에서 부를 수 있다 (world age)" begin
    # Julia 는 `Core.eval` 로 정의된 메서드를 **현재 world** 에서 직접 못 부른다.
    # `invokelatest` 없이는 여기서 MethodError 가 나고, 집행부의 try 가 그것을
    # `:threw`/`partial=true` 로 적어 "세계가 절반일 수 있다" 는 **거짓 기록**이 남는다.
    CB.reset_minted_table!()
    code = """
    function touch_nothing!(env; note = "x")
        return (status = :did_nothing, note = note)
    end
    """
    @test CB.register_minted_primitive!(name = "touch_nothing!", code = code,
                                        params = Dict{String,Any}("note" => Dict{String,Any}("type" => "string")),
                                        surface = "sched", reversible = true) === nothing
    fake = (staging_circles = Dict{Symbol,Any}(),)
    synth = Dict{String,Any}("reach" => "composed", "body_names" => ["touch_nothing!"],
                             "tool_name" => "t", "params" => Dict{String,Any}(),
                             "missing_primitive" => nothing,
                             "calls" => [Dict{String,Any}("primitive" => "touch_nothing!",
                                                          "args" => Dict{String,Any}("note" => "hi"))])
    r = CB.enact_minted!(fake, nothing, synth)
    @test r.verdict === :admit
    @test length(r.steps) == 1 && r.steps[1].status === :did_nothing
    @test r.partial === false                   # 🔴 world age 로 던지지 않았다
    @test r.args_from === :calls && r.n_calls == 1
    # 🔴 C1 (2026-09-03 최종 리뷰, CRITICAL): 이 testset 이 **바로 이 시나리오**를 굴리면서
    #    `applied` 를 한 번도 안 봤다 — 그래서 "생성 어휘 전체가 표 미스라 `applied=true` 로
    #    떨어진다" 가 여덟 커밋을 살아남았다. `:did_nothing` 은 이름 그대로 아무 일도 안 했다는
    #    자기신고인데 집행부는 그것을 "노린 적응이 일어났다" 로 적고 있었다.
    @test r.applied === nothing                 # 못 쟀다 — status 어휘가 선언돼 있지 않다
    @test r.world_maybe_dirty === true          # 🔴 임의의 생성 코드가 라이브 env 로 돌았다
end

# 🔴 F1 (컨트롤러 fix round 1, 2026-09-03): register 와 enact 를 **같은 컴파일된 함수 프레임
#    안에서** 잇달아 부른다 — 계획의 Task 9(`enact_minted_decision!`)가 실제로 이 모양이다.
#    testset (8) 은 두 호출을 서로 다른 top-level 문으로 적어서 world age 가 안 얼기 때문에
#    invokelatest 가 없어도 통과한다(위 (8) 머리말 참고, 컨트롤러가 직접 변이시켜 확인했다).
#    이 함수 하나가 그 자리를 메운다: eval 과 호출이 한 프레임 안에 있다.
function _register_then_enact_single_frame(; name, code, params, surface, reversible, fake, synth)
    why = CB.register_minted_primitive!(name = name, code = code, params = params,
                                        surface = surface, reversible = reversible)
    why === nothing || return why
    return CB.enact_minted!(fake, nothing, synth)   # 위 register 의 eval 과 같은 프레임
end

@testset "(9) 🔴 F1: register→enact 가 한 프레임 안에 있으면 invokelatest 가 진짜로 필요하다" begin
    CB.reset_minted_table!()
    code = """
    function single_frame_thing!(env; note = "y")
        return (status = :did_nothing, note = note)
    end
    """
    fake = (staging_circles = Dict{Symbol,Any}(),)
    synth = Dict{String,Any}("reach" => "composed", "body_names" => ["single_frame_thing!"],
                             "tool_name" => "t", "params" => Dict{String,Any}(),
                             "missing_primitive" => nothing,
                             "calls" => [Dict{String,Any}("primitive" => "single_frame_thing!",
                                                          "args" => Dict{String,Any}("note" => "hi"))])
    out = _register_then_enact_single_frame(
        name = "single_frame_thing!", code = code,
        params = Dict{String,Any}("note" => Dict{String,Any}("type" => "string")),
        surface = "sched", reversible = true, fake = fake, synth = synth)
    @test out isa NamedTuple   # register 성공(문자열이 아니라 enact_minted! 의 NamedTuple 이 왔다)
    r = out
    @test r.verdict === :admit
    @test length(r.steps) == 1 && r.steps[1].status === :did_nothing
    @test r.partial === false                   # 🔴 이게 이 testset 의 핵심 단언 — 여기가 빨개져야 진짜 게이트다
    @test r.args_from === :calls && r.n_calls == 1
    @test r.applied === nothing                 # 🔴 C1 — 위 (8) 과 같은 이유
    @test r.world_maybe_dirty === true
end

# 🔴 C1 (2026-09-03 최종 리뷰, CRITICAL). 세 표(`SILENT_SUCCESS_STATUSES` ·
#    `WORLD_UNCHANGED_STATUSES` · `PRIMITIVE_RESUMES_CACHE`)는 **원시 이름**으로 색인되고
#    그 이름들은 고정 어휘 19가 있던 시절에 손으로 적혔다. 런타임에 주조된 이름은 **전부
#    미스**이고, 미스 기본값은 `applied=true`·`dirty=true` 였다 — 즉 집행된 모든 생성 body 가
#    "적응했다" 로 기록됐다. 게이트 (11)(`test/minted_tool_enacts.jl`)이 그것을 못 잡는 이유는
#    그 게이트가 `keys(SILENT_SUCCESS_STATUSES) == ENACTABLE_TODAY`(정적 8)만 못 박아
#    **런타임 이름을 볼 길이 없기** 때문이다.
@testset "(10) 🔴 C1: 생성 원시의 applied 는 삼상의 nothing 이다" begin
    CB.reset_minted_table!()
    code = """
    function measures_nothing!(env; k = 1)
        return (status = :did_nothing, k = k)
    end
    """
    @test CB.register_minted_primitive!(name = "measures_nothing!", code = code,
                                        params = Dict{String,Any}(), surface = "sched",
                                        reversible = false) === nothing
    # 🔴 못 쟀다. 이 원시의 status 가 "조용한 성공" 인지 "노린 적응" 인지 아는 표가 없다.
    @test CB._step_applied("measures_nothing!", :did_nothing) === nothing
    @test CB._step_applied("measures_nothing!", :whatever)    === nothing
    @test CB._step_applied("measures_nothing!", :unreadable_return) === nothing
    # 🔴 그런데 `world_maybe_dirty` 는 `nothing` 이 **아니다**. 이 필드가 묻는 것은 "세계에
    #    손을 댔을 수 있는가" 이고, 임의의 생성 코드가 라이브 env 를 받아 돌았다는 것은 그
    #    가능성에 대한 **측정된 참**이다(못 쟀다가 아니다). 소비자도 그것을 요구한다 —
    #    `tools/monitor/enact.jl` 의 `minted_handled` 는 이 값을 `&&` 에 넣으므로
    #    `nothing` 이 오면 TypeError 로 죽는다.
    @test CB._step_touched_world("measures_nothing!", :did_nothing) === true
    @test CB._step_touched_world("measures_nothing!", :whatever)    === true

    # 음성 대조: 표에 **손으로 씨 뿌린** 알려진 원시는 생성물이 아니므로 정적 표로 판정된다.
    #    (판별자가 "표에 있는가" 가 아니라 "`Core.eval` 로 주조됐는가" 라는 것이 이 세 줄이다.)
    CB.minted_table()["reform_stuck_teams"] = Dict{String,Any}(
        "name" => "reform_stuck_teams", "impl" => "reform_stuck_teams!",
        "surface" => "sched", "harness_args" => ["env"],
        "params" => Dict{String,Any}(), "reversible" => false)
    @test CB._step_applied("reform_stuck_teams", :moved_none) === false
    @test CB._step_applied("reform_stuck_teams", :moved)      === true
    @test CB._step_touched_world("reform_stuck_teams", :moved_none) === false
end

# 🔴 C2 (2026-09-03 최종 리뷰, CRITICAL). 프롬프트(`world_interface.py` 의 `_RULES` 3)는
#    반환 모양 **둘**을 합법이라고 약속한다 — 맨 Symbol, 또는 `status::Symbol` 필드를 가진
#    NamedTuple. 하네스는 뒤엣것만 읽었다. 판정: **하네스를 넓힌다**(프롬프트를 좁히지 않는다).
@testset "(11) 🔴 C2: 맨 Symbol 반환도 읽을 수 있는 status 다" begin
    CB.reset_minted_table!()
    @test CB._step_status("anything", :did_the_thing) === :did_the_thing
    # 🔴 detail 도 같은 사실을 읽어야 한다 — status 는 읽혔는데 detail 이 "못 읽었다" 면
    #    한 줄 안에서 두 말이 어긋난다(`_step_detail` 의 EDGELIST 문단과 같은 논거).
    @test !occursin("unreadable", CB._step_detail(:did_the_thing, "anything"))
    code = """
    function returns_a_symbol!(env; note = "x")
        return :did_the_thing
    end
    """
    @test CB.register_minted_primitive!(name = "returns_a_symbol!", code = code,
                                        params = Dict{String,Any}("note" => Dict{String,Any}("type" => "string")),
                                        surface = "sched", reversible = false) === nothing
    fake = (staging_circles = Dict{Symbol,Any}(),)
    synth = Dict{String,Any}("reach" => "composed", "body_names" => ["returns_a_symbol!"],
                             "tool_name" => "t", "params" => Dict{String,Any}(),
                             "missing_primitive" => nothing,
                             "calls" => [Dict{String,Any}("primitive" => "returns_a_symbol!",
                                                          "args" => Dict{String,Any}("note" => "hi"))])
    r = CB.enact_minted!(fake, nothing, synth)
    @test r.verdict === :admit
    @test length(r.steps) == 1
    @test r.steps[1].status === :did_the_thing      # 🔴 `:unreadable_return` 이 아니다
    @test !occursin("unreadable", r.steps[1].detail)
end

# 🔴 C3 (2026-09-03 최종 리뷰). 규약 5 는 `isdefined(CB, name)` 로 **모든** 결속을 보는데
#    모델이 본 표면은 `names(CB)`(export 된 것)뿐이다 — 설계 D6 이 일부러 그렇게 좁혔다.
#    그러므로 충돌은 **두 개의 다른 사건**이다:
#      (a) 보여준 이름을 덮으려 했다 = 모델이 인터페이스를 안 읽었다.
#      (b) **안 보여준** 비공개 능력의 이름을 스스로 골랐다 = 그 능력을 처음부터 다시
#          유도했다는 뜻이고, 그것이 설계 §9 가 "첫 번째 실현 가능성 위험 · 첫 측정 대상"
#          이라고 적은 바로 그 신호다. 사유가 하나뿐이면 그 측정이 파괴된다.
@testset "(12) 🔴 C3: 이름 충돌 두 사건이 서로 다른 사유를 낸다 (D6 신호)" begin
    # 전제부터 못 박는다 — 정말로 하나는 export 됐고 하나는 아니다.
    @test isdefined(CB, :release_pending_assignments!)
    @test !(:release_pending_assignments! in names(CB))     # 모델은 이 이름을 본 적이 없다
    @test :reform_stuck_teams! in names(CB)                 # 모델은 이 이름을 봤다

    shown = CB.check_impl_conventions(
        "reform_stuck_teams!", "function reform_stuck_teams!(env; k = 1)\n    return :ok\nend\n")
    withheld = CB.check_impl_conventions(
        "release_pending_assignments!",
        "function release_pending_assignments!(env; k = 1)\n    return :ok\nend\n")
    @test shown !== nothing && withheld !== nothing
    # 🔴 오늘의 red 는 "문자열이 같다" 가 **아니다** — 이름이 박혀 있어 문자열은 이미 달랐다.
    #    같았던 것은 **사유 코드**다(둘 다 `reject:impl_name_exists:`). agent-3 에게 되먹임되는
    #    것이 그 코드이므로, 갈라야 하는 것도 그것이다.
    @test startswith(something(shown, ""),    "reject:impl_name_exists_shown:")
    @test startswith(something(withheld, ""), "reject:impl_name_exists_withheld:")
    _reason_code(w) = join(split(w, ":")[1:2], ":")
    @test _reason_code(something(shown, "")) != _reason_code(something(withheld, ""))
    # 낡은 소비자 호환: 둘 다 여전히 "name_exists" 를 포함한다.
    @test occursin("name_exists", something(shown, ""))
    @test occursin("name_exists", something(withheld, ""))
end

# 🔴 I1 (2026-09-03 최종 리뷰). "런 스코프" 는 **표**에 대해서만 참이다. `Core.eval` 은
#    프로세스 전역이고 되돌려지지 않는다. 이 testset 이 그 비대칭을 박제하고, 동시에 위
#    (12) 의 D6 신호가 그 비대칭 때문에 **오염되지 않는다**는 것을 잰다 — 한 프로세스가 런을
#    둘 처리하면 앞 런이 주조한 이름은 "숨겨진 비공개 결속" 과 구별되지 않게 생겼었다.
@testset "(13) 🔴 I1: 표는 런 스코프, eval 은 아니다 — 그리고 그 사실이 D6 신호를 안 더럽힌다" begin
    CB.reset_minted_table!()
    code = """
    function twice_minted!(env; k = 1)
        return :ok
    end
    """
    @test CB.register_minted_primitive!(name = "twice_minted!", code = code,
                                        params = Dict{String,Any}(), surface = "sched",
                                        reversible = false) === nothing
    CB.reset_minted_table!()                      # ← "런 경계" 라고 부르던 것
    @test isempty(CB.minted_table())              # 표는 비었다
    @test isdefined(CB, :twice_minted!)           # 🔴 그런데 함수는 그대로 남아 있다
    why = CB.register_minted_primitive!(name = "twice_minted!", code = code,
                                        params = Dict{String,Any}(), surface = "sched",
                                        reversible = false)
    @test why !== nothing
    @test occursin("already_minted", why)         # 세 번째 사건이다
    @test !occursin("withheld", why)              # 🔴 D6 신호로 오분류되지 않는다
end
end # module
