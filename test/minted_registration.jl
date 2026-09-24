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
#    `returns_a_symbol!` · `twice_minted!` · `l3_row_tool!` · `l3_row_empty!`(Wave C2).
#    되돌리는 길은 없다 — testset (13) 이 그 사실 자체를 잰다.
# =============================================================================
module MintedRegistration
using Test
using ConstructionBots
using JSON3          # 🔴 (26): D15 의 이름 우주 게이트가 산출물에서 광고 목록을 읽는다
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
    # 🔴 2026-09-03 최종 리뷰. `!== nothing` 만 재면 이 자리가 **파싱 실패**로 오진돼도,
    #    **이름 충돌**로 오진돼도 초록이다 — 바로 위 세 줄과 바로 아래 두 줄이 이미
    #    사유 문자열을 못박아 경화한 그 축이고, 여기만 안 하고 있었다. 사유는
    #    agent-3 으로 가는 되먹임 채널이므로(설계 §8 `impl_rejected_why`) 오진은
    #    "엉뚱한 것을 고치라" 는 지시가 된다.
    @test CB.check_impl_conventions("f!", "x = 1\n") == "reject:impl_not_a_function"
    # 같은 사유의 둘째 모양 — 최상위 표현식이 **하나**이고 그것이 함수가 아니다
    # (`single_expression` 도 `parse_failed` 도 아니라는 것을 음성으로 가른다).
    @test CB.check_impl_conventions("f!", "const f! = 1\n") == "reject:impl_not_a_function"

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
    # 🔴 F1(2026-09-03 최종 리뷰). `reach` 대신 `impl_name` — 경계를 건너오는 실제 미끼다
    #    (`enact_minted!` 의 step (1) 게이트가 보는 것이 그것이다, R1).
    synth = Dict{String,Any}("impl_name" => "touch_nothing!", "body_names" => ["touch_nothing!"],
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
    # 🔴 F1(2026-09-03 최종 리뷰). `reach` 대신 `impl_name`(R1).
    synth = Dict{String,Any}("impl_name" => "single_frame_thing!", "body_names" => ["single_frame_thing!"],
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
    # 🔴 F1(2026-09-03 최종 리뷰). `reach` 대신 `impl_name`(R1).
    synth = Dict{String,Any}("impl_name" => "returns_a_symbol!", "body_names" => ["returns_a_symbol!"],
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
    # 🔴 S4 (2026-09-04): 이 자리의 withheld 예시는 `release_pending_assignments!` 였다.
    #    그 이름이 **광고로 넘어갔으므로**(export) 이제 `shown` 쪽이다. 갈래를 정하는 것은
    #    하드코딩 목록이 아니라 `names(@__MODULE__)` 를 런타임에 읽는 판정이므로 재분류는
    #    자동으로 따라온다 — 아래 마지막 단언이 바로 그 사실을 잰다.
    @test isdefined(CB, :recover_stalled_teams!)
    @test !(:recover_stalled_teams! in names(CB))           # 모델은 이 이름을 본 적이 없다
    @test :reform_stuck_teams! in names(CB)                 # 모델은 이 이름을 봤다

    shown = CB.check_impl_conventions(
        "reform_stuck_teams!", "function reform_stuck_teams!(env; k = 1)\n    return :ok\nend\n")
    withheld = CB.check_impl_conventions(
        "recover_stalled_teams!",
        "function recover_stalled_teams!(env; k = 1)\n    return :ok\nend\n")
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
    # 🔴 S4 의 재판정 [실측]. 규약 5 의 갈래는 산출물이 아니라 `names(CB)` 를 읽으므로
    #    광고된 이름은 자동으로 `…_shown` 이 된다. 하드코딩 목록이었다면 여기가 빨갛다.
    @test :release_pending_assignments! in names(CB)
    rel = something(CB.check_impl_conventions(
        "release_pending_assignments!",
        "function release_pending_assignments!(env; k = 1)\n    return :ok\nend\n"), "")
    @test startswith(rel, "reject:impl_name_exists_shown:")
    @test !occursin("withheld", rel)
    # 🔴 S5 (2026-09-05) 의 같은 재판정. 화물 금지 동사도 광고로 넘어갔으므로 `shown` 이다 —
    #    갈래가 하드코딩 목록이었다면 이 두 줄이 빨갛다(둘째 export 가 그 사실을 재확인한다).
    @test :forbid_heavy_cargo! in names(CB)
    fhc = something(CB.check_impl_conventions(
        "forbid_heavy_cargo!",
        "function forbid_heavy_cargo!(env; k = 1)\n    return :ok\nend\n"), "")
    @test startswith(fhc, "reject:impl_name_exists_shown:")
    @test !occursin("withheld", fhc)
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
# 🔴 R1 (2026-09-03, 최종 수정 라운드). testset (12) 의 `withheld` 갈래는
#    `isdefined(CB, sym) && !exported` 로 계산됐는데, 그 술어는 뜻보다 **훨씬 넓다**:
#    `ConstructionBots` 는 `Graphs`·`MetaGraphs`·`DataStructures`·`Base` 등 ~30 모듈을
#    `using` 하므로 평범한 이름들이 전부 "정의됐지만 export 안 됨" 이다(실측:
#    `add_edge!`→Graphs.SimpleGraphs · `set_prop!`→MetaGraphs · `push!`/`empty!`→Base).
#    ⟹ 그래프를 편집하는 원시를 `add_edge!` 라 이름 붙인 모델이 **D6 신호로 기록된다** —
#    Task 11 의 첫 유료 런이 재려는 단 하나의 측정에 거짓양성이 실린다.
#    가르는 사실은 **결속의 소유 모듈**이고, `Base.binding_module` 이 그것을 낸다
#    (`parentmodule` 은 함수·타입에만 있어 `_MINTED_TABLE` 같은 값에서 MethodError 를
#    던진다 — 이 경로는 거절이지 예외가 아니어야 한다).
#    🔴 `push!` 은 CB 가 **확장**하는 이름이다. 소유 모듈은 여전히 `Base` 이고, 그것이
#    우리가 원하는 분류다 — "모델이 Base 가 이미 쓰는 이름을 골랐다" 는 "우리가 감춘
#    능력을 재유도했다" 와 다른 사실이다.
@testset "(14) 🔴 R1: 남의 모듈에서 온 이름은 D6 신호가 아니다" begin
    # 전제 — 넷 다 `isdefined && !exported` 다. 옛 술어는 이것을 전부 withheld 로 읽었다.
    for s in (:add_edge!, :set_prop!, :rem_edge!, :push!, :empty!)
        @test isdefined(CB, s)
        @test !(s in names(CB))
    end
    _code(n) = "function $(n)(env; k = 1)\n    return :ok\nend\n"
    _reason_code(w) = join(split(w, ":")[1:2], ":")

    imported = Dict(n => something(CB.check_impl_conventions(n, _code(n)), "")
                    for n in ("add_edge!", "set_prop!", "rem_edge!", "push!", "empty!"))
    for (n, w) in imported
        @test startswith(w, "reject:impl_name_exists_imported:")
        # 🔴 이것이 오늘의 red 다: 넷 다 `withheld` 로 나온다 = D6 거짓양성.
        @test !occursin("withheld", w)
        @test occursin("name_exists", w)          # 낡은 소비자 호환(테스트셋 12 와 같은 계약)
    end

    # CB 자신의 비공개 결속은 **여전히** D6 신호다 — 좁히기가 신호를 죽이지 않았다.
    # (S4: 예시를 `release_pending_assignments!` → `recover_stalled_teams!` 로 옮겼다.
    #  앞의 것은 이제 export 돼 있어 `shown` 이다.)
    withheld = something(CB.check_impl_conventions(
        "recover_stalled_teams!", _code("recover_stalled_teams!")), "")
    @test startswith(withheld, "reject:impl_name_exists_withheld:")

    # 셋이 서로 다른 사유 **코드**다(agent-3 에게 되먹임되는 것이 그것이다).
    shown = something(CB.check_impl_conventions(
        "reform_stuck_teams!", _code("reform_stuck_teams!")), "")
    codes = _reason_code.([shown, withheld, imported["add_edge!"]])
    @test length(unique(codes)) == 3
end

# 🔴 R1 의 두 번째 절반: 사유들이 공간을 **분할**한다(빠짐없이 · 겹치지 않게). 위 넷은
#    표본이고, 이것은 그 표본을 낳은 결정 트리 자체를 잰다.
@testset "(15) 🔴 R1: 규약 5 의 네 사유가 이름 공간을 분할한다" begin
    _code(n) = "function $(n)(env; k = 1)\n    return :ok\nend\n"
    # 사유 → 그 사유를 내야 하는 실제 이름 하나. 넷을 덮는다.
    cases = [("reject:impl_name_already_minted:",   "twice_minted!"),          # (13) 이 심었다
             ("reject:impl_name_exists_shown:",     "reform_stuck_teams!"),
             ("reject:impl_name_exists_withheld:",  "recover_stalled_teams!"),
             ("reject:impl_name_exists_imported:",  "set_prop!")]
    for (prefix, n) in cases
        w = something(CB.check_impl_conventions(n, _code(n)), "")
        @test startswith(w, prefix)
        # 겹치지 않는다: 다른 셋 중 어느 접두사도 이 사유의 접두사가 아니다.
        @test count(p -> startswith(w, p), first.(cases)) == 1
    end
    # 빠짐없다: 정의된 이름은 넷 중 하나로 **반드시** 떨어진다. 규약 5 를 통과하는 유일한
    # 길은 `isdefined == false` 다.
    for n in ("add_edge!", "push!", "release_pending_assignments!", "reform_stuck_teams!",
              "twice_minted!")
        w = something(CB.check_impl_conventions(n, _code(n)), "")
        @test count(p -> startswith(w, p), first.(cases)) == 1
    end
    @test !isdefined(CB, :a_name_no_module_owns!)
    @test CB.check_impl_conventions(
        "a_name_no_module_owns!", _code("a_name_no_module_owns!")) === nothing
end

# 🔴 (16) F9(2026-09-03 최종 리뷰, 컨트롤러 판정 R9). `sig.args[1]`(파싱된 함수 정의의
#    콜리)이 `Symbol` 이 아닌 세 모양에서 `String(sig.args[1])` 이 예전엔 **던졌다**
#    (`MethodError`) — 한정 이름(`Base.foo!`) · 보간(`$(...)`) · callable 객체
#    (`(o::T)(...)`). 셋 중 한정 이름이 가장 위험하다: 모델이 D6 이 재려는 가려진
#    능력을 다시 이름 붙이려 할 때 가장 흔히 쓸 모양이고, 던지면 그 사건이
#    `impl_rejected_why=nothing` 인 raw MethodError 로 새어 나가 D6 신호 자체가
#    소실된다. 이 testset 은 셋 다 던지지 않고 자기 사유로 거절되는지, 그리고 각
#    거절이 `Core.eval` **전**이라 `isdefined`/`_MINTED_EVER`/표 셋이 일관되게 "없음"
#    으로 남는지 잰다.
#
# 변이시험(실제로 빨갛게 만든 뒤 되돌렸다): `minted_registration.jl` 의 F9 가드
# (`callee isa Symbol` 검사와 그 뒤 세 갈래)를 지우면 이 testset 의 "안 던진다" 단언
# 셋이 전부 `MethodError` 로 죽는다(재현: `git stash`/수동 되돌림으로 확인, 이 파일의
# fix-round-3 보고서에 실측 로그가 있다).
@testset "(16) 🔴 F9: 콜리가 Symbol 이 아닌 세 모양은 던지지 않고 자기 사유로 거절된다" begin
    _sig_code(sig_src) = "function $(sig_src)(env; note = 1)\n    return :ok\nend\n"
    cases = [
        # (신고할 이름, 실제 정의 시그니처 소스, 기대 사유 접두사)
        ("qual_target!", "ConstructionBots.qual_target!", "reject:impl_name_is_qualified:"),
        ("interp_target!", "\$(Symbol(\"interp_target!\"))", "reject:impl_name_is_interpolated:"),
        ("callable_target!", "(o::T)", "reject:impl_signature_is_callable_object:"),
    ]
    for (name, sig_src, prefix) in cases
        local code = _sig_code(sig_src)
        local w
        try
            w = CB.check_impl_conventions(name, code)
        catch e
            @test false   # 던지면 이 자리에서 바로 실패로 남긴다(어느 사례인지 이름으로 보인다)
            println("  ($(name)) 던졌다: ", sprint(showerror, e))
            continue
        end
        @test w !== nothing && startswith(w, prefix)
        # 🔴 이 세 사례는 규약 5(이름 충돌)를 통과한 뒤 파싱 단계에서 거절되므로 —
        #    `Core.eval` 자체가 도달 불가다. 셋이 일관되게 "없음" 이어야 한다.
        @test !isdefined(CB, Symbol(name))
        @test !(name in CB._MINTED_EVER)
        @test !haskey(CB.minted_table(), name)
    end

    # 🔴 D6-모양 자체: 위 표본은 `sig.args[1]` 만 겨냥했다 — 실제로 `register_minted_primitive!`
    #    를 끝까지 불러도 던지지 않는지, 그리고 D6 이 원하는 신호(`impl_name_is_qualified`,
    #    또는 이름 자체가 이미 존재하면 `withheld`)가 살아 나오는지 직접 확인한다.
    CB.reset_minted_table!()
    local why = CB.register_minted_primitive!(
        name = "qual_e2e!", code = "function ConstructionBots.qual_e2e!(env; note = 1)\n    return :ok\nend\n",
        params = Dict{String,Any}(), surface = "sched", reversible = false)
    @test why !== nothing && startswith(why, "reject:impl_name_is_qualified:")
    @test !isdefined(CB, :qual_e2e!) && !("qual_e2e!" in CB._MINTED_EVER) &&
          !haskey(CB.minted_table(), "qual_e2e!")
end

# 🔴 (17) F14(2026-09-03 최종 리뷰, 컨트롤러 판정). `Base.isidentifier(chop(name))` 는
#    `name` 을 문자 단위로 훑는다 — 유효하지 않은 UTF-8(외톨이 연속 바이트 등)이 섞여
#    있으면 `Base.InvalidCharError` 로 **던졌다**(실측: `String(UInt8[0x67,0xff,0x21])`).
#    F9 의 헤지("두 함수 안에 무가드 변환이 없다")가 놓친 축이었다 — F9 는 **AST 모양**
#    (콜리가 Symbol 인가)만 봤고, 이것은 **`name` 인자의 바이트 내용** 축이다.
#    `isvalid(name)` 가드를 함수 맨 앞에 넣어 막는다.
#
# 변이시험(실제로 빨갛게 만든 뒤 되돌렸다): `isvalid(name) || return "reject:..."` 줄을
# 지우면 이 testset 의 "안 던진다" 단언이 `Base.InvalidCharError` 로 죽는다(재현 로그는
# 이 파일의 fix-round-4 보고서에 있다).
@testset "(17) 🔴 F14: 유효하지 않은 UTF-8 이름은 던지지 않고 자기 사유로 거절된다" begin
    local bad_name = String(UInt8[0x67, 0xff, 0x21])   # "g" + 외톨이 연속 바이트 + "!"
    @test !isvalid(bad_name)   # 전제부터 못 박는다 — 정말로 유효하지 않은 UTF-8 이다
    local code = "function foo!(env; note = 1)\n    return :ok\nend\n"
    local why
    try
        why = CB.check_impl_conventions(bad_name, code)
    catch e
        @test false   # 던지면 여기서 실패로 남긴다
        println("  던졌다: ", sprint(showerror, e))
        why = nothing
    end
    @test why !== nothing && startswith(why, "reject:impl_name_not_utf8:")
    # 🔴 이 자리는 규약 1(문자 검사)보다도 먼저이므로 `Core.eval` 근처에 얼씬도 못 한다 —
    #    셋이 일관되게 "없음" 이다.
    @test !isdefined(CB, Symbol(bad_name))
    @test !(bad_name in CB._MINTED_EVER)
    @test !haskey(CB.minted_table(), bad_name)

    # register_minted_primitive! 를 끝까지 불러도 던지지 않는지 직접 확인한다.
    CB.reset_minted_table!()
    local why2 = CB.register_minted_primitive!(
        name = bad_name, code = code, params = Dict{String,Any}(),
        surface = "sched", reversible = false)
    @test why2 !== nothing && startswith(why2, "reject:impl_name_not_utf8:")
end

# =============================================================================
# 🔴 R18 (2026-09-03) — **두 번째 유료 런의 진짜 코드**가 픽스처다
#
# 그 런은 레인을 끝까지 돌았고(`stages` 셋 · `wrote=True` · `calls_match_body=True`)
# 등록에서 거절됐다. 원인이 셋 쌓여 있었고, 컨트롤러 판정 R18 이 **무엇을 재는가**로
# 그것을 갈랐다:
#
#   | 층 | 사유 | 누구의 것인가 |
#   |---|---|---|
#   | 마크다운 펜스 | `impl_not_a_function` | **우리 것** — 코드를 펜스로 감싸는 것은 모든 LM 의 보편 행동이지 규약 위반이 아니다. 파이썬이 벗긴다(FIX A) |
#   | 최상위 함수 **둘** | `impl_not_single_expression:2` | 🔴 **모델의 것** — 프롬프트가 "최상위 도우미는 금지, 도우미는 몸통 **안**" 이라고 명시하는데 모델이 `find_suitable_robot` 을 최상위로 냈다. 이 거절은 규약이 제 일을 한 것이고 **모델 준수도의 정직한 측정**이다. 절대 완화하지 않는다 |
#   | `env::PlannerEnv` | `impl_positional_args_must_be_exactly_env` | **우리 것** — 타입 표기는 arity 도 호출가능성도 안 바꾼다(FIX B) |
#
# 그래서 이 파일이 못박는 명제는 **"우리 쪽 둘이 사라지고 모델의 것 하나가 남는다"** 다.
#
# 🔴 **출처**: `results/synth_lane_records.jsonl` 의 마지막 줄, `impl_code` 필드(1387 바이트,
#    2026-09-03 20:39). 아래는 그 값에서 여는/닫는 펜스 줄만 뺀 것이고 안쪽은 **바이트 그대로**다.
#    `results/` 는 gitignore 이므로 픽스처를 여기 박아 둔다 — 그 파일을 읽는 시험을 쓰면
#    체크아웃에 따라 조용히 skip 되거나 다른 런의 코드를 잰다.
# =============================================================================
const LIVE_BARE = raw"""
function TaskRedistributor!(env::PlannerEnv; affected_robot::String="R1", current_soc::Float64=0.5, current_speed::Float64=0.5, available_robots::Vector{String}=String[], slack_value::Float64=0.1)
    # Extract the operating schedule
    sched = env.sched
    nodes = sched.nodes
    vtx_map = sched.vtx_map

    # Identify tasks assigned to the affected robot
    affected_tasks = [node for node in nodes if node.assigned_robot == affected_robot]

    # Redistribute tasks based on available robots and their capabilities
    for task in affected_tasks
        # Find a suitable robot from the available list
        suitable_robot = find_suitable_robot(available_robots, current_soc, current_speed, slack_value)
        if suitable_robot !== nothing
            # Reassign the task to the suitable robot
            task.assigned_robot = suitable_robot
        end
    end

    return NamedTuple{(:status,)}((:success,))
end

function find_suitable_robot(available_robots::Vector{String}, current_soc::Float64, current_speed::Float64, slack_value::Float64)
    # Placeholder logic to find a suitable robot
    # In a real scenario, this would involve more complex logic considering SOC, speed, and slack
    for robot in available_robots
        if robot != "R1" # Avoid reassigning to the affected robot
            return robot
        end
    end
    return nothing
end
"""
const LIVE_FENCED = "```julia\n" * LIVE_BARE * "```"

# 위 코드의 **첫 함수만** — 최상위가 하나가 되면 그다음 관문이 규약 1 이다.
# 🔴 이것을 손으로 다시 적지 않는다: 진실원은 `LIVE_BARE` 하나다.
const LIVE_FIRST_FN = LIVE_BARE[1:(findfirst("\nend\n", LIVE_BARE)).stop]

@testset "(18) 🔴 R18 FIX B: 위치인자 env 는 타입 표기를 달아도 된다" begin
    # 라이브 모양 그대로 — `env::PlannerEnv` + 타입 붙은 키워드 + 기본값.
    # 🔴 D15(Task 6, 2026-09-03)로 이 단언이 `=== nothing` 에서 바뀌었다 — **완화가 아니라
    #    조임이다.** 브리프 Step 4 진단을 실제로 돌린 결과
    #    (`julia +lts --project=. -e 'using ConstructionBots; …isdefined(CB,s)/Base/Core'`)
    #    `find_suitable_robot` 은 **CB=false Base=false Core=false** 였다 — 즉 이 라이브 body 는
    #    부르면 집행 중에 UndefVarError 로 죽는 코드였고, 옛 `=== nothing` 은 그 느슨함에
    #    기대고 있었다(브리프 Step 4 의 둘째 갈래: "존재하지 않는다 → 시험을 고치되 왜
    #    고쳤는지 그 자리에 적는다").
    #    🔴 이 자리가 재는 것은 **여전히 규약 1** 이다: 규약 1 이 회귀하면 사유가
    #    `impl_positional_args_must_be_exactly_env` 로 바뀐다 — 그 검사는 D15 보다 **앞**에서
    #    돌기 때문이다. 그래서 아래 두 줄은 `=== nothing` 보다 더 많은 것을 못박는다.
    local why18 = CB.check_impl_conventions("TaskRedistributor!", LIVE_FIRST_FN)
    @test why18 !== nothing
    @test startswith(something(why18, ""), "reject:impl_unknown_call:find_suitable_robot")
    # 표기 없는 옛 모양도 그대로 통과한다(넓히기이지 갈아타기가 아니다).
    @test CB.check_impl_conventions("f!", "function f!(env; k = 1)\n    return :ok\nend\n") === nothing
    @test CB.check_impl_conventions("f!", "function f!(env::Any; k = 1)\n    return :ok\nend\n") === nothing
    @test CB.check_impl_conventions("f!", "function f!(env::PlannerEnv)\n    return :ok\nend\n") === nothing

    # 🔴 나머지는 **한 톨도** 안 넓어진다. 다섯 음성 대조:
    for bad in ("function f!(other::PlannerEnv; k = 1)\n    return :ok\nend\n",   # 이름이 다르다
                "function f!(env::PlannerEnv, other; k = 1)\n    return :ok\nend\n", # 위치인자 둘
                "function f!(env...; k = 1)\n    return :ok\nend\n",              # slurp
                "function f!(env::PlannerEnv...; k = 1)\n    return :ok\nend\n",   # 타입 붙은 slurp
                "function f!(env = 1; k = 1)\n    return :ok\nend\n",              # 기본값
                "function f!(::PlannerEnv; k = 1)\n    return :ok\nend\n",         # 이름이 없다
                "function f!(; k = 1)\n    return :ok\nend\n")                     # 위치인자 0
        local why = CB.check_impl_conventions("f!", bad)
        @test why !== nothing &&
              startswith(why, "reject:impl_positional_args_must_be_exactly_env:")
    end
    # 키워드 규약은 타입 표기가 붙어도 그대로다 — 기본값 없는 키워드는 여전히 거절.
    @test CB.check_impl_conventions("f!", "function f!(env::PlannerEnv; k::Int)\n    return :ok\nend\n") ==
          "reject:impl_keyword_needs_a_default:k::Int"
end

@testset "(19) 🔴 R18 FIX C: 펜스가 줄리아까지 오면 그 사실을 이름으로 말한다" begin
    # 진단이지 둘째 고침이 아니다 — FIX A 뒤로 펜스는 여기 오면 안 된다. 오면
    # 그것은 파이썬 정규화가 실패했다는 뜻이고, 조용하지 말고 시끄러워야 한다.
    @test CB.check_impl_conventions("TaskRedistributor!", LIVE_FENCED) ==
          "reject:impl_code_is_fenced"
    for fenced in ("```julia\nfunction f!(env; k = 1)\n    return :ok\nend\n```",
                   "```\nfunction f!(env)\n    return :ok\nend\n```",
                   "  \n```jl\nfunction f!(env)\nend\n")   # 안 닫힌 펜스도 펜스다
        @test CB.check_impl_conventions("f!", fenced) == "reject:impl_code_is_fenced"
    end
    # 🔴 음성 대조: 맨 Julia 는 이 사유를 절대 안 받는다.
    @test CB.check_impl_conventions("f!", "function f!(env)\n    run(`ls`)\nend\n") === nothing
end

@testset "(20) 🔴 R18: 우리 쪽 둘이 사라지고 **모델의 것** 하나가 남는다" begin
    # 펜스를 벗긴 라이브 코드에 남는 유일한 거절은 최상위 함수가 둘이라는 것이다.
    # 🔴 이 단언이 빨개지면 규약을 고칠 것이 아니라 **그것이 발견**이다.
    @test CB.check_impl_conventions("TaskRedistributor!", LIVE_BARE) ==
          "reject:impl_not_single_expression:2"
end

@testset "(21) 🔴 D15: 미정의 호출 대상은 eval 전에 거절된다" begin
    # run 2·3 이 실제로 쓴 모양이다.
    code = """
    function d15_probe_a!(env; x::Int=1)
        r = find_suitable_robot(x)
        return (status = :ok,)
    end
    """
    why = CB.check_impl_conventions("d15_probe_a!", code)
    @test why !== nothing
    @test startswith(why, "reject:impl_unknown_call:")
    @test occursin("find_suitable_robot", why)
    # 🔴 M-1(2026-09-04 독립 검증). 옛 줄 `@test !isdefined(CB, :d15_probe_a!)` 는 **아무것도
    #    안 쟀다** — 이 테스트셋은 `check_impl_conventions` 만 부르므로 `Core.eval` 경로에
    #    애초에 들어가지 않고, 그래서 그 단언은 항진이었다. 재려던 성질은 "**등록 자체가
    #    막힌다**" 이므로 등록을 **실제로 시도**한다. 이제 D15 를 빼면 이 세 줄이 빨개진다.
    local why_reg = CB.register_minted_primitive!(name = "d15_probe_a!", code = code,
                                                  params = Dict{String,Any}())
    @test why_reg == why                        # 등록은 규약 검사와 **같은 사유**로 거절된다
    @test !isdefined(CB, :d15_probe_a!)         # ⟹ 항진이 아니다: eval 이 안 돌았다
    @test !haskey(CB.minted_table(), "d15_probe_a!")

    # 🔴 C5(같은 검증). 이 사유는 Task 9 의 `/rewrite` 가 agent-3 에게 **바이트 그대로**
    #    나른다. 필드 거절은 실제 필드를 싣는데 호출 거절은 아무 대안도 안 실었다 —
    #    되먹임 채널의 두 갈래 중 한쪽만 행동 가능했다. 이제 둘 다 싣는다.
    local cands = CB._near_miss_names(:find_suitable_robot)
    @test !isempty(cands)
    @test all(c -> Symbol(c) in names(CB), cands)          # 지어내지 않는다
    @test cands == CB._near_miss_names(:find_suitable_robot)   # 결정적이다
    @test occursin(first(cands), why)
end

@testset "(22) 🔴 D15: 없는 필드 접근도 eval 전에 거절된다" begin
    code = """
    function d15_probe_b!(env; x::Int=1)
        return (status = Symbol(env.sched.nodes[1].assigned_robot),)
    end
    """
    why = CB.check_impl_conventions("d15_probe_b!", code)
    @test why !== nothing
    @test startswith(why, "reject:impl_unknown_field:")
    @test occursin("assigned_robot", why)
    # 되먹임이 쓸모 있으려면 **실제 필드가 문장 안에** 있어야 한다
    @test occursin("id", why) && occursin("node", why) && occursin("spec", why)
end

@testset "(23) 🔴 D15 음성 대조 — 옳은 body 는 통과한다" begin
    # 기존 함수를 부르고 존재하는 필드만 읽는다. 지역 클로저도 쓴다(규약 4 는 허용).
    code = """
    function d15_probe_ok!(env; t::Float64=0.0)
        pick(v) = v
        update_planning_cache!(env, t)
        n = length(env.cache.closed_set)
        return (status = Symbol("closed_", pick(n)),)
    end
    """
    @test CB.check_impl_conventions("d15_probe_ok!", code) === nothing
end

@testset "(24) 🔴 D15 는 모르면 통과시킨다 (거짓 거절 금지)" begin
    # 수신자 타입을 정적으로 못 아는 필드 접근은 **막지 않는다**.
    code = """
    function d15_probe_dyn!(env; x::Int=1)
        y = env.agent_policies
        z = first(values(y)).nominal_policy
        return (status = :ok,)
    end
    """
    @test CB.check_impl_conventions("d15_probe_dyn!", code) === nothing
end

# =============================================================================
# 🔴 2026-09-04 fix round 1 — 독립 검증(task-6-review.md)의 C1·C2·C4·C5.
# =============================================================================

@testset "(25) 🔴 C1: 함수를 담은 지역 이름을 부르는 여섯 모양은 거절되지 않는다" begin
    # 🔴 이것은 D15 의 **"모르면 거절" 자리 둘 중 하나**였다 — 검사의 나머지 전부가
    #    "모르면 통과" 인데 지역 정의 수집만 `f(x) = …` 와 중첩 `function f(x)` 두 모양만
    #    봤다. ⚠️ **정정(Wave C2, 2026-09-04)**: 이 주석의 앞 판은 "유일하게" 라고 적었고
    #    그것은 거짓이었다 — 둘째 자리가 점 연산자(`Expr(:call, :.+, …)`)이고 이 여섯보다
    #    흔했다. 그 자리의 게이트는 테스트셋 (31) 이다. 아래 여섯은 **전부 이 세계에 대해 옳은 Julia** 이고, 우리 파서의 한계로
    #    모델의 옳은 코드를 막는 것은 이 레인이 재려는 것 자체를 파괴한다.
    #    (2026-09-04 실측: 고치기 전 여섯 다 `reject:impl_unknown_call:<지역이름>`.)
    local shapes = Dict(
        "lambda"      => "function d15_l1!(env; x::Int=1)\n    g = y -> y + 1\n    return (status = Symbol(g(x)),)\nend\n",
        "let"         => "function d15_l2!(env; x::Int=1)\n    let q = y -> y + 1\n        return (status = Symbol(q(x)),)\n    end\nend\n",
        "assign_call" => "function d15_l3!(env; x::Int=1)\n    hh = get(Dict(), :k, identity)\n    return (status = Symbol(hh(x)),)\nend\n",
        "alias"       => "function d15_l4!(env; x::Int=1)\n    cb = identity\n    return (status = Symbol(cb(x)),)\nend\n",
        "tuple"       => "function d15_l5!(env; x::Int=1)\n    (aa, bb) = (identity, identity)\n    return (status = Symbol(aa(x)),)\nend\n",
        "for"         => "function d15_l6!(env; x::Int=1)\n    for zz in (identity,)\n        zz(x)\n    end\n    return (status = :ok,)\nend\n",
    )
    for (tag, code) in sort(collect(shapes))
        local nm = match(r"function (\w+!)", code).captures[1]
        @test CB.check_impl_conventions(nm, code) === nothing
    end
    # 🔴 음성 대조 — 넓힘이 검사를 은퇴시키지 않았다. 지역에 **안 담긴** 지어낸 이름은
    #    같은 모양 안에서도 여전히 거절된다.
    local ctl = "function d15_l7!(env; x::Int=1)\n    g = y -> y + 1\n    return (status = Symbol(g(zzz_still_undefined(x))),)\nend\n"
    @test startswith(something(CB.check_impl_conventions("d15_l7!", ctl), ""),
                     "reject:impl_unknown_call:zzz_still_undefined")
end

@testset "(26) 🔴 C2: D15 의 이름 우주 ⊇ 인터페이스가 광고하는 이름 전부" begin
    # 🔴 재는 명제: **게이트 레인과 집행 레인의 세계가 같다.** 광고한 이름을 거절하면
    #    우리는 agent-3 에게 부를 수 있다고 말해 놓고 그 body 를 막는 것이다.
    #    실측(2026-09-04): 148개 중 `battery_report` **하나**가 `isdefined` 삼중으로
    #    안 보였다 — 정의가 런타임 include 되는 `src/navigator/battery.jl` 에 있어서
    #    **프로세스 상태에 따라 판정이 갈렸다**(include 전 거절 / 후 통과). 이 레포가
    #    `DS_HOTSWAP` 으로 이미 밟은 자리다. 리터럴 복붙 금지 — 산출물에서 읽는다.
    local art = joinpath(pkgdir(CB), "src", "decision", "core",
                         "world_interface.json")
    @test isfile(art)
    local j = JSON3.read(read(art, String))
    local advertised = String[]
    for m in j["methods"];  push!(advertised, String(m["name"]));  end
    for a in j["ambient"];  push!(advertised, String(first(split(String(a["accessor"]), "("))));  end
    unique!(advertised)
    @test length(advertised) > 100          # 🔴 빈 목록이 공허하게 초록이 되는 것을 막는다
    @test "battery_report" in advertised    # 🔴 정확히 그 한 이름이 목록 안에 있다
    local invisible = String[n for n in advertised if !CB._d15_name_is_visible(Symbol(n))]
    @test invisible == String[]
    # 음성 대조 — 술어가 항진이 아니다.
    @test !CB._d15_name_is_visible(:find_suitable_robot)
    @test !CB._d15_name_is_visible(:zzz_definitely_not_a_name)

    # -------------------------------------------------------------------------
    # 🔴 2026-09-04 스위트 회귀 수정 — 이 게이트가 재는 명제는
    #    **"`names` 갈래가 `isdefined` 삼중이 못 보는 이름을 들여보낸다"** 하나다.
    #    그 명제는 `isdefined(CB, :battery_report) == false` 인 상태에서만 관측되는데,
    #    앞 판은 그 전제를 **이 프로세스**에 대해 단언했다. 단독 실행에서는 참이지만
    #    `Pkg.test()` 안에서는 `runtests.jl` 이 :182·:294 에서 navigator 를 이미
    #    include 한 뒤라(둘 다 이 파일이 도는 :394 보다 앞) 전제가 거짓이 되고 그
    #    한 줄만 빨개졌다 — CLAUDE.md 가 이름 댄 "스위트 안에서만 빨개지는 시험" 이다.
    #
    # ⚠️ 이 프로세스 안에서는 그 상태를 **복원할 수 없다**: Julia 에 undefine 이 없고,
    #    `Core.eval(CB, :(export …))` 로 팬텀 이름을 심는 길은 `names(CB)` 를 영구히
    #    바꿔 바로 앞에서 도는 "world interface is current" 의 산출물 핀을 오염시킨다.
    # ⟹ **깨끗한 자식 프로세스**에서 잰다. 전제가 순서와 무관하게 성립하고, 부모가
    #    무엇을 include 했든 판정이 같다. (`runtests.jl` 이 이미 쓰는 패턴이고,
    #    "world interface is current" 의 testset (2) 도 같은 이유로 서브프로세스다.)
    # -------------------------------------------------------------------------
    local amb_body = "function d15_amb!(env; x::Int=1)\n    r = battery_report()\n" *
                     "    return (status = Symbol(x),)\nend\n"
    local child = """
    using ConstructionBots
    const CB = ConstructionBots
    isdefined(CB, :battery_report) && error("PREMISE_BROKEN: 새 프로세스인데 이미 정의돼 있다")
    CB._d15_name_is_visible(:zzz_definitely_not_a_name) && error("CONTROL_BROKEN: 술어가 항진이다")
    CB._d15_name_is_visible(:battery_report) || error("NAMES_BRANCH_MISSING: 광고한 이름이 안 보인다")
    CB.check_impl_conventions("d15_amb!", $(repr(amb_body))) === nothing ||
        error("REJECTED: " * string(CB.check_impl_conventions("d15_amb!", $(repr(amb_body)))))
    println("D15_NAMES_BRANCH_OK")
    """
    local out = Pipe()
    local proc = run(pipeline(`$(Base.julia_cmd()) --project=$(pkgdir(CB)) -e $child`,
                              stdout = out, stderr = out), wait = false)
    close(out.in)
    local txt = read(out, String)
    wait(proc)
    proc.exitcode == 0 || @error "(26) 자식 프로세스 로그" txt
    @test proc.exitcode == 0
    @test occursin("D15_NAMES_BRANCH_OK", txt)
end

@testset "(27) 🔴 C4: `:ref` 걸음은 인덱스가 리터럴 정수일 때만 나아간다" begin
    # 실측(2026-09-04, 고치기 전): `env.sched.nodes[1:2]` 를 `ScheduleNode` 로 답했다.
    # 실제 타입은 `Vector{ScheduleNode}` 다 — 즉 docstring 의 "각 걸음은 타입이 확정될
    # 때만 나아간다" 가 그 자리에서 참이 아니었다. 오늘 그 결과로 거절되는 것은 이미
    # 틀린 코드뿐이라 거짓 거절은 아직 없었지만, 과장된 머리말은 다음 세션이 검증 없이
    # 전제로 읽는다.
    @test CB._static_receiver_type(:(env.sched.nodes[1])) !== nothing
    for e in (:(env.sched.nodes[1:2]), :(env.sched.nodes[i]), :(env.sched.nodes[end]),
              :(env.sched.nodes[1, 2]))
        @test CB._static_receiver_type(e) === nothing
    end
    # 귀결(보수적인 쪽): 슬라이스에 대한 필드 접근은 **거절되지 않는다**.
    @test CB.check_impl_conventions("d15_slice!", """
    function d15_slice!(env; x::Int=1)
        return (status = Symbol(env.sched.nodes[1:2].assigned_robot),)
    end
    """) === nothing
end

@testset "(28) 🔴 C5: 덮개 구멍 넷 — 둘은 닫았고 둘은 **일부러** 열려 있다" begin
    # 🔴 이 네 줄이 구멍 목록의 단일 진실원이다(생산 쪽 docstring 이 여기를 가리킨다).
    # 닫은 둘 — 둘 다 진짜 집행-중 UndefVarError 경로다.
    @test startswith(something(CB.check_impl_conventions("d15_h1!",
        "function d15_h1!(env; x::Int = zzz_kwdefault_undefined())\n    return (status = Symbol(x),)\nend\n"), ""),
        "reject:impl_unknown_call:zzz_kwdefault_undefined")   # 기본값은 매 호출에서 평가된다
    @test startswith(something(CB.check_impl_conventions("d15_h2!",
        "function d15_h2!(env; x::Int=1)\n    zzz_bcast_undefined.([1])\n    return (status = :ok,)\nend\n"), ""),
        "reject:impl_unknown_call:zzz_bcast_undefined")       # `f.(x)` 는 흔한 관용구다
    # 열어 둔 둘 — 보수적이다(거짓 거절을 안 낸다). 매크로는 지역에 못 담기지만 한정
    # 매크로(`@Base.foo`)와 패키지 매크로를 우리가 못 가르고, 한정 호출은 모듈 경로를
    # 풀어야 한다 — 둘 다 풀려다 틀리면 **거짓 거절**이 나는 쪽이라 안 건드린다.
    @test CB.check_impl_conventions("d15_h3!",
        "function d15_h3!(env; x::Int=1)\n    @zzz_undefined_macro env\n    return (status = :ok,)\nend\n") === nothing
    @test CB.check_impl_conventions("d15_h4!",
        "function d15_h4!(env; x::Int=1)\n    Main.zzz_qualified_undefined(x)\n    return (status = :ok,)\nend\n") === nothing
end

@testset "(29) 🔴 D16/F1: `f(…).x` 모양 주석은 shape 게이트를 못 넘는다" begin
    # 🔴 2026-09-04 fix round 1 (F1). `_is_type_shape` 의 `:.` 갈래가 `e.args[2]` 만
    #    `QuoteNode` 인지 봤고 `e.args[1]` 은 **아무 표현식이나** 될 수 있었다 — `:call`
    #    포함. 그래서 `f(…).x` 모양 주석이 모양 게이트를 통과해 `impl_param_types` 의
    #    `Core.eval` 이 그것을 돌렸다(파일 생성·삭제를 리뷰가 실측). 시그니처에 있는
    #    호출이라 `_walk_body!`(= 몸통만 걷는다)의 `impl_unknown_call` 도 못 본다.
    CB.reset_minted_table!()
    local dir = mktempdir()
    try
        local p1 = joinpath(dir, "PWNED.txt")
        local p2 = joinpath(dir, "SILENT.txt")
        local p3 = joinpath(dir, "NOT_A_SANDBOX.txt")
        # (a) 시끄러운 변종 — `write` 는 `Int` 를 내고 `.x` 가 던진다.
        local code1 = "function d16_pwn_tool!(env; n::(write($(repr(p1)), \"PWNED\").x) = 0)\n" *
                      "    return (status = :ok,)\nend\n"
        # (b) 🔴 완전히 조용한 변종 — 부작용을 내면서 **진짜 `Type`** 을 돌려준다.
        #     초판에서는 이것이 `param_types[\"n\"] == Int64` 로 등록까지 성공했다(사유 0개).
        local code2 = "function d16_silent_tool!(env; n::(open(io -> (T = Int,), $(repr(p2)), \"a\").T) = 0)\n" *
                      "    return (status = :ok,)\nend\n"
        @test CB._is_type_shape(Meta.parse("write(\"a\", \"b\").x")) === false
        @test CB._is_type_shape(Meta.parse("Vector{write(\"a\", \"b\").y}")) === false
        @test !(get(CB.impl_param_types(code1), "n", nothing) isa Type)
        @test !isfile(p1)              # 🔴 `impl_param_types` 가 세계를 안 건드렸다
        @test !(get(CB.impl_param_types(code2), "n", nothing) isa Type)
        @test !isfile(p2)
        # 🔴 **이 검사는 샌드박스가 아니다 — 좁힘이다.** Julia 는 kwarg 타입 주석을 메서드
        #    정의 시점에 평가하므로, 같은 문자열을 등록에 주면 본래의 `Core.eval` 이 그것을
        #    똑같이 돌린다(부모 커밋 `80c62d49` 에서도 그랬다 — 리뷰가 실측). 즉 D16 이
        #    도달 가능한 능력을 넓히지는 않았고, 이 고침도 그것을 닫지는 못한다. 이 두 줄이
        #    그 사실의 진실원이다(두 docstring 이 여기를 가리킨다) — 다음 세션이
        #    "모양 검사가 eval 을 막는다" 를 전제로 물려받지 않도록.
        local why = CB.register_minted_primitive!(name = "d16_notsandbox_tool!",
            code = "function d16_notsandbox_tool!(env; n::(write($(repr(p3)), \"X\").x) = 0)\n" *
                   "    return (status = :ok,)\nend\n",
            params = Dict{String,Any}("n" => Dict("type" => "integer")),
            surface = "sched", reversible = false)
        @test why !== nothing                       # 등록은 거절됐다(`.x` 가 던진다)
        @test isfile(p3)                            # 🔴 그런데 세계는 이미 만져졌다
    finally
        rm(dir; recursive = true, force = true)
    end
end

@testset "(30) 🔴 D16/F5: `_is_type_shape` 의 열한 모양 — 여덟은 참, 셋은 **일부러** 거짓" begin
    # 🔴 2026-09-04 fix round 1 (F5). 이 프로브는 Task 7 보고서와 docstring 에만 있었고
    #    스위트에 없었다 — `Val{:x}`·`NTuple{3,Int}` 갈래가 나중에 좁아져도 아무것도
    #    안 빨개졌다(덮이던 유일한 모양이 `Array{String,1}` 하나였다). 여기가 그 게이트다.
    for s in ["Array{String,1}", "Vector{String}", "Int", "Base.RefValue{Int}",
              "Dict{String,Any}", "Matrix{Float64}", "Val{:x}", "NTuple{3,Int}"]
        @test CB._is_type_shape(Meta.parse(s)) === true
    end
    # 셋은 설계상 거짓이다: 호출 · 보간 · `where`(UnionAll).
    for s in ["f(x)", "\$(T)", "Array{String,N} where N"]
        @test CB._is_type_shape(Meta.parse(s)) === false
    end
    # `impl_param_types` 직접 단위 — 삼상이 한 판에 다 나온다.
    local pt = CB.impl_param_types(
        "function d16_unit_probe!(env; xs::Vector{String}=String[], y::Int=0,\n" *
        "                         zs::Vector{<:AbstractString}=String[], w=1)\n" *
        "    return (status = :ok,)\nend\n")
    @test pt["xs"] === Vector{String}          # 읽었다
    @test pt["y"]  === Int                     # 읽었다
    @test haskey(pt, "zs") && !(pt["zs"] isa Type)   # 주석은 있는데 못 읽었다
    @test !haskey(pt, "w")                     # 주석이 없다 (키가 없다)
end

# =============================================================================
# 🔴 2026-09-04 Wave C2 — 판정 R24(L3 생산자) · Task 6 out-of-scope 1(점 연산자).
# =============================================================================

@testset "(31) 🔴 B: 점 연산자는 거짓 거절이 아니다" begin
    # 🔴 `Meta.parse("a .+ b")` 는 `Expr(:call, :.+, :a, :b)` 다 — 즉 점 연산자는
    #    **호출 대상 이름**으로 실린다. 그런데 `isdefined(Base, Symbol(".+")) == false`
    #    이므로 D15 의 이름 우주에 없고, 고치기 전에는 전부 `reject:impl_unknown_call:.+`
    #    이었다(2026-09-04 실측: 31모양 프로브 중 **19개** 거짓 거절 — 리뷰가 적은 7보다
    #    넓다). 벡터 산술은 수치 Julia 에서 가장 흔한 관용구이고, 모델이 `soc .< 0.1` 을
    #    쓰면 그 거절이 유료 런에서 **모델의 실패**로 기록된다.
    #    가족별로 한 줄씩 — 하나가 열려도 그 가족이 통째로 샌다.
    local families = [
        ("arith",      "    y = [1] .+ [2] .- [3] .* [4] ./ [5] .^ 2\n"),
        ("intdiv",     "    y = [4] .÷ [2] .% [3]\n"),
        ("compare",    "    y = ([1] .== [2]) .!= ([1] .< [2]) .| ([1] .<= [2]) .| ([1] .> [2])\n"),
        ("bitwise",    "    y = ([true] .& [false]) .| [true]\n"),
        ("pipe",       "    y = [1] .|> identity\n"),
        ("membership", "    y = [1] .∈ Ref([1, 2])\n"),
        ("unary",      "    y = .-([1])\n"),
        ("unary_not",  "    y = .!([true])\n"),
        ("soc_idiom",  "    y = [0.5] .< 0.1\n"),
    ]
    for (tag, b) in families
        local nm = "d15_dot_$(tag)!"
        @test CB.check_impl_conventions(nm,
            "function $(nm)(env; x::Int=1)\n$(b)    return (status = :ok,)\nend\n") === nothing
    end
    # 🔴 음성 대조 — 넓힘이 검사를 은퇴시키지 않는다. 점 연산자 **안에** 든 지어낸 이름은
    #    여전히 거절된다(순회가 인자까지 들어가므로).
    @test startswith(something(CB.check_impl_conventions("d15_dot_ctl!",
        "function d15_dot_ctl!(env; x::Int=1)\n    y = zzz_inside_broadcast(x) .+ [1]\n    return (status = :ok,)\nend\n"), ""),
        "reject:impl_unknown_call:zzz_inside_broadcast")
    # 🔴 점 이름이 **아닌** 진짜 호출은 그대로 걷힌다 — 접두 `.` 규칙이 너무 넓지 않다.
    @test startswith(something(CB.check_impl_conventions("d15_dot_ctl2!",
        "function d15_dot_ctl2!(env; x::Int=1)\n    y = zzz_plain_undefined.([1])\n    return (status = :ok,)\nend\n"), ""),
        "reject:impl_unknown_call:zzz_plain_undefined")

    # 🔴 **연산자꼴 중 호출 노드가 아닌 것들** — 여기서 핀으로 못박는다(덮개 서술의 진실원).
    #    `.=` · `.+=` · `.&&` · `.||` 는 `:call` 이 아니라 자기 head 를 가지므로 애초에
    #    호출 대상으로 안 모인다(실측: 고치기 전에도 넷 다 통과했다). `:comparison`
    #    (`1 < x < 3`)도 마찬가지다. 그러나 그 **안에 든** 지어낸 호출은 재귀 순회가 잡는다 —
    #    이 두 성질이 함께 참이어야 "구멍이 아니라 모양" 이다.
    for (tag, b) in [("dotassign",  "    y = [1, 2]\n    y .= 3\n"),
                     ("dotupdate",  "    y = [1, 2]\n    y .+= 1\n"),
                     ("dotand",     "    y = [true] .&& [false]\n"),
                     ("dotor",      "    y = [true] .|| [false]\n"),
                     ("comparison", "    y = 1 < x < 3\n")]
        local nm = "d15_op_$(tag)!"
        @test CB.check_impl_conventions(nm,
            "function $(nm)(env; x::Int=1)\n$(b)    return (status = :ok,)\nend\n") === nothing
    end
    @test startswith(something(CB.check_impl_conventions("d15_op_ctl!",
        "function d15_op_ctl!(env; x::Int=1)\n    y = [1, 2]\n    y .= zzz_inside_dotassign(x)\n    return (status = :ok,)\nend\n"), ""),
        "reject:impl_unknown_call:zzz_inside_dotassign")
    @test startswith(something(CB.check_impl_conventions("d15_op_ctl2!",
        "function d15_op_ctl2!(env; x::Int=1)\n    y = 1 < zzz_inside_comparison(x) < 3\n    return (status = :ok,)\nend\n"), ""),
        "reject:impl_unknown_call:zzz_inside_comparison")
end

@testset "(32) 🔴 A(R24): L3 생산자 — 삼상이고, 정렬되고, 교집합이다" begin
    # 🔴 spec §0 의 L3 판정식은 "정적 호출 대상 ∩ 인터페이스 ≠ ∅" 이고, 괄호가
    #    "D15 의 AST 순회가 이미 만드는 값" 이라고 적는다. 그런데 그 값(`cs`)은
    #    `check_impl_conventions` 안에서 **버려진다**(Task 6 리뷰 §7-2 · Task 10 결정 12).
    #    그래서 사전등록은 L3 을 `nothing`("못 쟀다") 으로 적어야 했다. 이 게이트가
    #    그 생산자를 못박는다.

    # ① 인터페이스 함수를 실제로 부른 body → 비어 있지 않다
    local hit = CB.impl_interface_calls("""
    function l3_hit!(env; x::Int=1)
        r = battery_report()
        s = active_spares(env)
        return (status = :ok,)
    end
    """)
    @test hit == ["active_spares", "battery_report"]      # 정렬됨 · 교집합만
    # ② 아무것도 안 부른 body → `String[]`("재서 없다"), `nothing` 이 **아니다**
    local none = CB.impl_interface_calls("""
    function l3_none!(env; x::Int=1)
        y = x + 1
        z = string(y)
        return (status = :ok,)
    end
    """)
    @test none == String[]
    @test none !== nothing                                # 🔴 삼상이 안 무너진다
    # ③ 걷지 못한 입력 → `nothing`("못 쟀다")
    for bad in ["function l3_broken!(env; x::Int=1",           # 잘림
                "1 + 1",                                        # 함수가 아니다
                "function a!(env) end\nfunction b!(env) end\n", # 최상위 정의 둘
                ""]                                             # 빈 입력
        @test CB.impl_interface_calls(bad) === nothing
    end
    # 🔴 ②와 ③은 **다른 상태**여야 한다 — 이 구분이 L3 이 오늘 `nothing` 인 이유 그 자체다.
    #    ⚠️ `a !== b` 로 쓰면 안 된다: 서로 다른 두 `String[]` 도 `!==` 라 삼상이 무너져도
    #    초록인 항진이 된다(변이 MUT-D 로 확인). 상태 자체를 비교한다.
    @test (CB.impl_interface_calls("1 + 1") === nothing) !=
          (CB.impl_interface_calls(
              "function l3_none2!(env; x::Int=1)\n    return (status = :ok,)\nend\n") === nothing)

    # 교집합이다: Base 이름도, 지역 이름도, 자기 이름도 안 실린다.
    local filt = CB.impl_interface_calls("""
    function l3_filter!(env; x::Int=1)
        g = y -> y + 1
        a = string(g(x))
        b = close_node!
        l3_filter!(env; x = x - 1)
        return (status = :ok,)
    end
    """)
    @test filt == String[]        # `string`(Base) · `g`(지역) · `l3_filter!`(자기) 전부 빠진다
    # 🔴 음성 대조: 같은 자리에 인터페이스 이름을 **부르면** 실린다(위 0 이 항진이 아니다).
    @test CB.impl_interface_calls("""
    function l3_filter2!(env; x::Int=1)
        a = string(x)
        close_node!(env, x)
        return (status = :ok,)
    end
    """) == ["close_node!"]
    # 키워드 **기본값**의 호출도 같은 순회가 본다(D15 와 같은 값이라는 것이 요점이다).
    @test CB.impl_interface_calls(
        "function l3_kw!(env; x = active_spares(env))\n    return (status = :ok,)\nend\n") ==
        ["active_spares"]
    # 결정성 — 다섯 번 불러도 바이트 동일이고 정렬돼 있다(`Set`/`Dict` 순회 금지 규약).
    local reps = [CB.impl_interface_calls("""
    function l3_det!(env; x::Int=1)
        swap_battery!(env, x)
        battery_report()
        active_spares(env)
        close_node!(env, x)
        return (status = :ok,)
    end
    """) for _ in 1:5]
    @test all(r -> r == reps[1], reps)
    @test reps[1] == sort(reps[1])
    @test length(reps[1]) == 4
end

@testset "(33) 🔴 A(R24): L3 값이 등록 행까지 산다 — 그리고 삼상이 거기서도 산다" begin
    # 🔴 진실원 하나: 이름은 `interface_calls` **하나**이고, 그 열이 이 사실의 유일한
    #    자리다. 나중 구현자(집행 기록 배선)가 읽을 곳:
    #        `ConstructionBots.minted_table()[name]["interface_calls"]`
    #    L3 판정 = `v !== nothing && !isempty(v)`; `nothing` 은 "못 쟀다" 다.
    #    ⚠️ `resolve_primitive`(`src/respec/minted_tool.jl`)에 같은 이름의 필드를 얹는 것은
    #    한 줄이지만 그 파일은 이 라운드의 경로 밖이라 안 건드렸다 — 얹을 때도 **이름은
    #    `interface_calls` 하나**여야 하고 기본값은 `[]` 가 아니라 `nothing` 이어야 한다
    #    (손으로 씨 뿌린 행은 순회한 적이 없다).
    CB.reset_minted_table!()
    local code = """
    function l3_row_tool!(env; x::Int=1)
        r = battery_report()
        return (status = :ok,)
    end
    """
    @test CB.register_minted_primitive!(name = "l3_row_tool!", code = code,
                                        params = Dict("x" => 1)) === nothing
    local row = CB.minted_table()["l3_row_tool!"]
    @test haskey(row, "interface_calls")
    @test row["interface_calls"] == ["battery_report"]
    @test row["interface_calls"] isa Vector{String}
    # 🔴 아무것도 안 부른 원시는 같은 열에 `[]` 를 싣는다 — `nothing` 이 아니다.
    #    (등록되는 모든 행은 `check_impl_conventions` 를 통과했으므로 순회는 항상 됐다.)
    @test CB.register_minted_primitive!(name = "l3_row_empty!", code =
        "function l3_row_empty!(env; x::Int=1)\n    y = x + 1\n    return (status = :ok,)\nend\n",
        params = Dict("x" => 1)) === nothing
    @test CB.minted_table()["l3_row_empty!"]["interface_calls"] == String[]
    # 🔴 손으로 씨 뿌린 행에는 이 열이 **없다** → 읽는 쪽이 `nothing`("못 쟀다")을 본다.
    #    `[]` 로 채우면 "안 불렀다" 와 "순회한 적 없다" 가 무너진다.
    CB.minted_table()["hand_seeded"] = Dict{String,Any}(
        "name" => "hand_seeded", "impl" => "l3_row_tool!", "surface" => "unknown",
        "harness_args" => ["env"], "params" => Dict{String,Any}(), "reversible" => false)
    @test get(CB.minted_table()["hand_seeded"], "interface_calls", nothing) === nothing
end

# =============================================================================
# 🔴 F-2 (2026-09-04). 아래 둘이 재는 명제 하나: **L3 의 "인터페이스" 는 산출물이다.**
#
#    Wave C2 는 그것을 `names(CB)` 로 놨고 docstring 이 그 차 39를 "전부 모델에게 보이는
#    표면" 이라고 적었다. 실측(2026-09-04, 이 게이트가 매번 다시 유도한다): 39 중 **21은
#    산출물이 이름으로 광고하지 않는다** — 그리고 그 21에는 D-9 이 행동공간에서 뺀
#    `SwapBattery` · `ForbidZone` · `TranslateBuild` · `ReplaceAgent` · `RelocateBuild` 가
#    **생성자로 여전히 부를 수 있는 채** 들어 있다. 즉 모델이 본 적 없는 이름을 찍으면
#    "우리가 준 인터페이스를 썼다" 는 뜻의 등급이 초록이 됐다.
#
#    ⚠️ **D15 는 이 좁힘의 대상이 아니다**(`_d15_name_is_visible`). 그쪽 질문은 "이 이름이
#    실재하는가 = 거절하면 안 되는가" 라서 `names(CB)` 가 맞다(테스트셋 (26)). 두 술어는
#    다른 질문이고, 이 게이트 둘이 그 분리를 못박는다.
# =============================================================================

"산출물이 **이름으로** 광고하는 것 전부. 🔴 리터럴 복붙 금지 — 산출물에서 읽는다."
function _advertised_names_from_artifact()
    local art = joinpath(pkgdir(CB), "src", "decision", "core",
                         "world_interface.json")
    local j = JSON3.read(read(art, String))
    local out = Set{String}()
    for m in j["methods"];  push!(out, String(m["name"]));  end
    for t in j["types"]
        push!(out, String(t["name"]))
        for s in (get(t, :subtypes, nothing) === nothing ? String[] : t["subtypes"])
            push!(out, String(s))
        end
    end
    for a in j["ambient"];  push!(out, String(first(split(String(a["accessor"]), "("))));  end
    return out
end

_l3_probe_body(n) =
    "function l3_adv_probe!(env; x::Int=1)\n    " * n * "(env)\n    return (status = :ok,)\nend\n"

@testset "(34) 🔴 F-2: 광고 안 한 이름은 L3 을 못 받는다" begin
    local adv = _advertised_names_from_artifact()
    local ident = r"^[A-Za-z_][A-Za-z0-9_!]*$"
    @test length(adv) > 150                       # 🔴 빈 집합이 공허하게 초록이 되는 것을 막는다

    # ① 음성: `names(CB)` 에는 있는데 산출물이 광고 안 하는 이름 — 전수.
    local unadv = sort(String[String(n) for n in names(CB)
                              if !(String(n) in adv) && occursin(ident, String(n))])
    @test !isempty(unadv)
    @test length(unadv) == 21                     # 실측 2026-09-05 (아래 ③ 의 검산식 참조)
    #    🔴 카나리아: D-9 이 행동공간에서 뺀 행동 타입들이 바로 그 안에 있다.
    for n in ["SwapBattery", "ForbidZone", "TranslateBuild", "ReplaceAgent", "RelocateBuild"]
        @test n in unadv
    end
    local scored = String[n for n in unadv if CB.impl_interface_calls(_l3_probe_body(n)) != String[]]
    @test scored == String[]                      # 🔴 F-2 그 자체: 하나도 L3 을 못 받는다

    # ② 양성 대조 — 위 0 이 항진이 아니다. 광고된 이름은 전수로 실린다.
    local advc = sort(String[n for n in adv if occursin(ident, n)])
    @test length(advc) > 150
    local missed = String[n for n in advc if CB.impl_interface_calls(_l3_probe_body(n)) != [n]]
    @test missed == String[]

    # ③ `names(CB)` 중 산출물이 실제로 광고하는 이름 — 모델이 본 **export 표면**이다.
    #    🔴 이 지역변수는 `advtype` 이었고 주석은 "광고된 **타입** 이름" 이라 적었다. 둘 다
    #       틀렸다 [실측]: 이 집합은 메서드 이름을 함께 담는다(`forbid_heavy_cargo!` ·
    #       `release_pending_assignments!` 가 여기 들어온다). 세는 것에 이름을 맞춘다.
    local advexp = sort(String[String(n) for n in names(CB) if String(n) in adv])
    # 🔴 **이 숫자는 export 를 하나 더할 때마다 낡는다 — 그리고 실제로 낡은 채 커밋됐다.**
    #    `09204a2c`(S3)가 `ood_event_target` 을 export 하고 이 줄을 안 고쳐서 HEAD 가
    #    `168 == 167` 로 빨갰다. 그러므로 이 값을 **인용하지 말고 재유도할 것**.
    #    검산식(2026-09-05 S5 직후 실측, 셋이 서로를 검산한다):
    #      length(names(CB)) 190 = advexp 169 + unadv 21     (ident 밖 이름은 오늘 0)
    #    빨개졌을 때 "몇 개" 만으로는 **어느 이름이 움직였는지** 알 수 없으므로 목록을 남긴다.
    # 🔴 169 → **174** (2026-09-23, 재유도·전수 확인). 둘로 갈린다:
    #    (a) **9da7caca**(나-1, 2026-09-05, 이 파일의 5a2ede9d 직후 커밋인데 이 줄을 안 고쳤다)가
    #        `global_transform`·`project_to_2d`·`get_center` 를 export 했다 — **+3**, 존 복구
    #        base ablation 과 무관한 선행 미수정 staleness다(이 이름 셋은 옛 `world_interface.json`
    #        에도 이미 광고돼 있었다 — 실측: 재생성 전 산출물에서도 advexp=172 였다).
    #    (b) 이 태스크(zone_facts 추가 + 레포 정리 100a7735 의 inplace_breakdown_marks)가 그 위에
    #        **+2** 더한다(172 → 174). 이 둘만 재생성으로 새로 광고된다(diff 로 확인).
    #    169 + 3 + 2 = 174.
    # 🔴 174 → **175** (2026-09-23 G3 D1): `resync_scene_to_schedule!` export(`_resync_scene_drift!` 공개 래퍼).
    if length(advexp) != 175
        @info("광고된 export 표면이 움직였다 — 목록을 대조하고 이 줄과 위 unadv 를 함께 고쳐라",
              n_advexp = length(advexp), n_unadv = length(unadv),
              n_names = length(names(CB)), advexp)
    end
    @test length(advexp) == 175
end

@testset "(35) 🔴 F-2: 못 읽은 산출물은 `nothing` 이지 `[]` 가 아니다" begin
    # 🔴 삼상 규약. 인터페이스를 못 읽었으면 "재서 없다"(`[]`) 가 아니라 "못 쟀다" 다.
    #    그리고 **틀린 타입에서 값을 조용히 재지 않는다** — 모양이 아닌 JSON 은 빈 집합이
    #    아니라 `nothing` 이다(이 계획이 이미 두 번 밟은 자리: `_world_delta(bad, ok)` 가
    #    문자열 길이를 `n_binding_changed` 로 냈다).
    @test CB._artifact_interface_names(joinpath(mktempdir(), "no_such_file.json")) === nothing
    @test CB._artifact_interface_names(mktempdir()) === nothing          # 디렉터리
    @test CB._artifact_interface_names(nothing) === nothing
    local d = mktempdir()
    local bad = joinpath(d, "broken.json");   write(bad, "{not json at all")
    @test CB._artifact_interface_names(bad) === nothing
    for (fn, txt) in (("arr.json", "[1, 2, 3]"),
                      ("wrongtype.json", "{\"methods\": 5, \"types\": [], \"ambient\": []}"),
                      ("noname.json", "{\"methods\": [{\"signature\": \"(x)\"}], \"types\": [], \"ambient\": []}"),
                      ("empty.json", "{\"methods\": [], \"types\": [], \"ambient\": []}"))
        local p = joinpath(d, fn);  write(p, txt)
        @test CB._artifact_interface_names(p) === nothing
    end
    # 양성 대조 — 진짜 산출물은 `nothing` 이 아니고 크다.
    local real = CB._artifact_interface_names()
    @test real !== nothing && length(real) > 150

    # 🔴 그리고 그 `nothing` 이 `impl_interface_calls` 까지 산다: 같은 body, 같은 순회,
    #    산출물만 못 읽었을 때 — `[]` 가 아니라 `nothing`.
    local body = "function l3_art!(env; x::Int=1)\n    battery_report()\n    return (status = :ok,)\nend\n"
    @test CB.impl_interface_calls(body) == ["battery_report"]
    @test CB.impl_interface_calls(body, artifact = joinpath(d, "no_such_file.json")) === nothing
    # 삼상이 여기서도 안 무너진다: 세 상태가 서로 유도 불가다.
    local st = v -> v === nothing ? :unmeasured : (isempty(v) ? :measured_none : :measured_some)
    @test st(CB.impl_interface_calls(body)) === :measured_some
    @test st(CB.impl_interface_calls(
        "function l3_art2!(env; x::Int=1)\n    return (status = :ok,)\nend\n")) === :measured_none
    @test st(CB.impl_interface_calls(body, artifact = joinpath(d, "no_such_file.json"))) === :unmeasured
    @test st(CB.impl_interface_calls("1 + 1")) === :unmeasured
end

@testset "(36) 🔴 자기-가림 대입은 eval 전에 거절된다 (2026-09-06 라이브 실측)" begin
    # 유료 런의 `/rewrite` 가 실제로 낸 코드다. `Core.eval` 을 통과하고 **집행 중에**
    # `UndefVarError: restriction_zones not defined` 로 죽었다 — 그때 세계는 이미 반쯤
    # 편집됐을 수 있고(그 판의 기록: `applied=false partial=true world_maybe_dirty=true`),
    # agent-3 에게 돌아갈 문장도 raw 예외였다. 그것이 D15 를 만든 이유인데, 이 모양은
    # 그 게이트가 **구조적으로** 못 덮었다.
    #
    # 🔴 왜 D15 가 못 잡았나. `_walk_body!` 는 `:(=)` 의 좌변 Symbol 을 `locals` 에 넣고,
    #    거절 루프의 `(c in ls) && continue` 가 같은 이름의 **호출**을 건너뛴다. 그런데
    #    "본문 어딘가에서 대입됐다" 는 것이 바로 Julia 에서 그 이름을 **본문 전체에서
    #    지역**으로 만드는 조건이다 — 대입 **전** 사용은 UndefVarError 다. 즉 억제가
    #    버그의 원인을 안전의 근거로 삼고 있었다. `restriction_zones` 는 실제로 CB 에
    #    정의돼 있고 export 도 되므로 `_d15_name_is_visible` 은 참이다 — 가시성은 이
    #    실패와 무관하다.
    local live = """
    function reroute_navigation!(env)
        restriction_zones = restriction_zones()
        zone_key = nothing
        for (key, zone) in restriction_zones
            zone_key = key
        end
        return (; status = :ok, k = zone_key)
    end
    """
    local why = CB.check_impl_conventions("reroute_navigation!", live)
    @test why !== nothing
    @test startswith(something(why, ""), "reject:impl_self_shadowed_name:restriction_zones")

    # ---- 음성 대조 다섯. 한 톨도 넓히거나 좁히지 않는다 -------------------------------
    # (a) 오라클 픽스처의 **작동하는** body 모양 — 이름을 가리지 않고 호출한다. 통과해야 한다.
    @test CB.check_impl_conventions("OracleZoneClear!", """
    function OracleZoneClear!(env)
        zk = [k for (k, _) in active_restriction_zones()]
        isempty(zk) && return (; status = :no_zone)
        return restage_all_blocked!(env; zone_keys = zk, resume = true, verbose = true)
    end
    """) === nothing

    # (b) 매개변수 재대입은 합법이다 — `env`·키워드는 이미 바인딩돼 있다.
    @test CB.check_impl_conventions("f!", """
    function f!(env; n::Int = 1)
        n = n + 1
        return (; status = :ok, n = n)
    end
    """) === nothing

    # (c) 이름이 겹치지 않는 평범한 대입.
    @test CB.check_impl_conventions("f!", """
    function f!(env)
        zs = active_restriction_zones()
        return (; status = :ok, n = length(collect(zs)))
    end
    """) === nothing

    # (d) 자기 이름을 **호출로 안 쓰고** 값으로만 가리는 대입도 같은 런타임 오류다.
    local why_d = CB.check_impl_conventions("f!", """
    function f!(env)
        zs = zs
        return (; status = :ok, z = zs)
    end
    """)
    @test why_d !== nothing
    @test startswith(something(why_d, ""), "reject:impl_self_shadowed_name:zs")

    # (e) 🔴 항진명제 방지 — 이 검사가 꺼져 있으면 (a)~(c) 가 통과하는 것만으로는
    #     아무것도 증명되지 않는다. 위 (live)·(d) 가 그 음성 대조다.
    @test CB.check_impl_conventions("f!", """
    function f!(env)
        return (; status = :ok)
    end
    """) === nothing
end

@testset "(37) 🔴 인터페이스 호출에 리터럴 `nothing` 키워드는 거절된다 (2026-09-06 라이브 실측)" begin
    # 유료 런의 **첫** 시도가 이 모양으로 죽었다:
    #   `restage_all_blocked!(env; zone_keys=nothing, resume=true, verbose=false)`
    #   -> MethodError: no method matching iterate(::Nothing)
    # 🔴 모델을 탓할 자리가 아니다. 광고된 시그니처는 `(env; zone_keys, resume::Bool,
    #    verbose::Bool)` 이고 그것은 Julia 문법으로 **필수 키워드** 모양이다. 기본값은
    #    렌더되지 않는다 — `tools/gen_world_interface.jl` 이 "Julia 가 기본값을 노출하지
    #    않는다" 고 스스로 적는다. 즉 값을 모르는 키워드를 **생략**하는 것이 옳다는 사실이
    #    agent-3 에게 광고된 적이 없었다. 이 검사는 그 무지의 대가를 **세계가 반쯤 편집되기
    #    전에** 문장으로 되돌린다(`impl_rejected_why` -> `/rewrite`).
    local live = """
    function reroute_navigation!(env)
        result = restage_all_blocked!(env; zone_keys=nothing, resume=true, verbose=false)
        return (; status = result.status)
    end
    """
    local why = CB.check_impl_conventions("reroute_navigation!", live)
    @test why !== nothing
    @test startswith(something(why, ""),
                     "reject:impl_keyword_literal_nothing:restage_all_blocked!.zone_keys")

    # ---- 음성 대조 — 한 톨도 안 넓힌다 ------------------------------------------------
    # (a) 키워드를 **생략**한 같은 호출은 통과한다(그것이 처방이다).
    @test CB.check_impl_conventions("f!", """
    function f!(env)
        return restage_all_blocked!(env; resume = true, verbose = false)
    end
    """) === nothing

    # (b) 오라클의 작동하는 모양 — 실제 목록을 넘긴다.
    @test CB.check_impl_conventions("f!", """
    function f!(env)
        zk = [k for (k, _) in active_restriction_zones()]
        return restage_all_blocked!(env; zone_keys = zk, resume = true, verbose = true)
    end
    """) === nothing

    # (c) 🔴 **변수**가 `nothing` 일 수 있는 것은 거절하지 않는다. 규약 6 이 "id 를 나르는
    #     키워드는 `nothing` 으로 기본값을 준다" 고 가르치므로, 그 값을 그대로 흘리는 것은
    #     정상 관용구다. 이 검사가 보는 것은 **리터럴** 하나다.
    @test CB.check_impl_conventions("f!", """
    function f!(env; target = nothing)
        return restage_all_blocked!(env; zone_keys = target)
    end
    """) === nothing

    # (d) body **안쪽**에 정의한 도우미에는 안 걸린다(인터페이스 호출이 아니다).
    @test CB.check_impl_conventions("f!", """
    function f!(env)
        helper(x; k = 1) = (; status = :ok, k = k)
        return helper(env; k = nothing)
    end
    """) === nothing

    # (e) 주조 함수 **자신의** 키워드 기본값 `nothing` 은 규약 1·6 이 요구하는 모양이다.
    @test CB.check_impl_conventions("f!", """
    function f!(env; agent = nothing)
        return (; status = :ok, a = agent)
    end
    """) === nothing
end

end # module
