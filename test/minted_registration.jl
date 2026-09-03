# =============================================================================
# 🔴 R-RERUN: 이 파일은 같은 Julia 세션에서 **한 번만** 안전하게 돈다.
#    testset (5)(`register_minted_primitive!`, Task 4)가 `adjust_thing!` 을
#    `Core.eval` 로 ConstructionBots 에 심는다. 같은 세션에서 이 파일을 다시
#    include 하면 testset (4)의
#    `check_impl_conventions("adjust_thing!", OK_CODE) === nothing` 이
#    `"reject:impl_name_exists:..."` 로 빨개진다 — `adjust_thing!` 이 이제
#    "기존 이름" 이기 때문이다(규약 5). 검증은 매번 새 프로세스로 할 것:
#    `julia +lts --project=. -e 'include("test/minted_registration.jl")'`
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
end
end # module
