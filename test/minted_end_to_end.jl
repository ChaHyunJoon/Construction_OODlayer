# =============================================================================
# 경계 e2e: 생성 코드가 서비스 응답에서 등록·집행부까지 간다. (2026-09-03, Task 9)
#
# 재는 명제: `policy_entry` 가 SYNTH_LANE_KEYS 로 실은 `impl_name`·`impl_code`·
# `surface`·`reversible` 가 `enact_minted_decision!` 안에서 `register_minted_primitive!`
# 로 등록되고, 그 직후 같은 프레임에서 `enact_minted!` 가 그 이름을 부를 수 있어야 한다
# (world age — `test/minted_registration.jl` (9) 의 F1 과 같은 모양). 그리고 `registered`·
# `impl_rejected_why`(R2/R7) 가 성공 · 등록 거절 · (등록은 됐는데 그 뒤가 던졌다) 를
# 가른다. 🔴 `registered === nothing`(판정 불가) 은 2026-09-03 최종 리뷰 F7 **직후엔
# 아직 있었다** — F7 은 `register_minted_primitive!` 자신의 `params` 키-타입 위반만
# 고쳤는데, 그 함수가 먼저 부르는 `check_impl_conventions` 안에 콜리(함수 시그니처
# 이름)가 `Symbol` 이 아닌 세 모양(한정 이름·보간·callable 객체)에서 던지는 **다른**
# 자리가 남아 있었다(F9 최종 리뷰가 잡았다 — 그중 한정 이름은 D6 이 재려는 사건과
# 겹쳐서 이 계획의 핵심 측정을 raw MethodError 로 날릴 뻔했다). F9 가 그것도 고친
# **지금은** 이 두 함수 안에서 실측한 모델-도달가능 모양 중 던지는 자리가 없다 —
# `tools/monitor/enact.jl` 의 `registered` docstring 이 그 재도출을 적는다(모든 AST
# 모양을 남김없이 센 증명은 아니라고 그 자리에 명시한다).
#
# 🔴 **픽스처 방법론 — 이 파일의 모든 `synth_lane` 은 JSON3 왕복을 거친다.**
#    손으로 지은 `Dict{String,Any}` 를 `enact_minted_decision!` 에 **직접** 넘기면 라이브
#    에서만 나는 실패를 못 잡는다. 🔴 2026-09-03 최종 리뷰가 잡은 것: 이 머리말이 이미
#    그렇게 적고 있었는데 **testset (3)·(4) 는 손으로 지은 `Dict{String,Any}` 를 그대로
#    넘기고 있었다** — 그리고 이 파일의 자기 서술이 참이 아니었던 그 자리가 정확히
#    `params` 타입 파열(C-F1)이 다섯 라운드를 살아남은 이유다. 지금은 넷 다 아래
#    `_resp(...)` 를 지나간다: 실제 서비스 응답과 같은 모양을 짓고 `JSON3.write` →
#    `JSON3.read` 로 왕복시킨 뒤 **`policy_entry` 를 실제로 태운다.**
#
# 🔴 2026-09-03 최종 리뷰 F5. 이전 판은 이 파일 전체가 `registered`·`impl_rejected_why`
#    에 단언을 **하나도** 안 걸었다 — `if why !== nothing … return` 갈래를 통째로 지워도
#    스위트가 전부 초록이었다(실측). testset (2)·(3) 이 그 구멍을 메운다.
#
# 🔴 2026-09-03 최종 리뷰 B3 — **(5) 가 이 파일의 새 무게중심이다.** 그 전까지 이 레포에는
#    *파이썬이 실제로 만든 기록을 줄리아에 먹이는 시험이 하나도 없었다*: 줄리아 픽스처는
#    전부 줄리아 저자가 손으로 지은 것이고, 파이썬 시험은 `params` 의 문자열 모양을
#    하드코딩하고 통과했으며, 교차언어 게이트(`test/synth_lane_keys_survive.jl`)는
#    **키 이름만** AST 로 견줬다 — 타입도 값도 안 봤다. 그래서 양쪽 스위트가 초록인 채로
#    치명적 계약 파열이 살아남았다. (5) 는 `synthesize_multi` 를 **가짜 프로그램으로**
#    돌려(유료 0건) 진짜 기록을 만들고, 그것을 JSON 으로 건너보내 **경계 키마다 타입을
#    못박은** 뒤 실제로 등록·집행한다. 그리고 음성 대조로 `params` 를 문자열로 되돌려
#    거절되는 것까지 본다 — 표가 공허하지 않다는 증거다.
#
# 🔴 2026-09-03 최종 리뷰 B6 — **(6) 은 행동을 안 바꾸고 잰다.** 무동작 생성 body 도
#    `world_maybe_dirty=true` ⇒ `handled=true` 라 기본 복구 사슬을 건너뛴다. 그것은
#    `_step_touched_world` 의 **의도된 계약**이고(더러워졌을 수 있는 세계 위에 폴백을 쌓는
#    것이 더 나쁘다) 문서에 그렇게 적혀 있다. 그런데 그 값을 **생성 경로에서 재는 단언이
#    레포 어디에도 없었다**: `tools/monitor/test_minted_wiring.jl` 은 일부러 `impl_code` 를
#    안 실어(등록 경로를 안 태운다) 여섯 개의 `handled === true` 가 전부 손으로 씨 뿌린
#    비-생성 행이고, 이 파일의 네 testset 은 전부 `handled === false` 였다(env 에 `cache`/
#    `sched` 가 없다). 생산이 읽는 유일한 값이 미측정이었다.
# =============================================================================
module MintedEndToEnd
using Test
using ConstructionBots
import JSON3
import HTTP
const CB = ConstructionBots

# =============================================================================
# 🔴 D2 (Wave D, 2026-09-04) — **이 파일은 살아 있는 서비스로 한 요청도 안 낸다.**
#
# 결함(실측, 이 파동 전): `enact_minted_decision!` 은 등록 거절마다 `$DSPY_URL/rewrite`
# 로 POST 한다(D17). 이 파일은 등록 거절을 **셋** 만들므로 한 번 돌 때마다 요청 3건이
# 8077 로 나갔다 — 오늘은 그 포트의 서비스가 09-03 세대라 `/rewrite` 라우트가 없어
# 404 이고 그래서 공짜였다(실측: `[minted] rewrite: 왕복 실패 … StatusError(404` ×3).
# 🔴 그 공짜는 **서비스 세대에 우연히 의존한다**: Task 10 이 현행 세대를 8077 에 올리는
#    순간 `Pkg.test()` 한 번이 유료 호출 3건이 되고, 그 프롬프트가 `~/.dspy_cache`
#    (공유 · `cache=True`)에 들어앉아 정작 측정할 런의 캐시를 오염시킨다. 🔴 캐시 오염이
#    과금보다 나쁘다 — 나중의 음성 대조가 바이트 동일 프롬프트로 **옛 응답을 재생**한다.
#
# 처방: **루프백 대역 서버**다(환경변수 opt-in 이 아니라). 근거 셋 —
#   (1) opt-in 플래그는 기본값에서 게이트를 **끄는** 것이라, 되먹임 경로가 아무도 안 돌린
#       채 유료 런에 들어간다. 이 레포의 서명 실패 모드(빨개질 수 없는 게이트)와 같은 자리다.
#   (2) 루프백은 그 경로를 **매번** 태우면서 유료 0건이다 — 그리고 이 파일이 필요로 하는
#       것(고친 body 를 실제로 받는 판)은 가짜 응답 없이는 아예 못 짓는다(testset (20)).
#   (3) 이 레포에 이미 정본 관용구가 있다(`test/tool_lane_keys_survive.jl` ·
#       `test/runtests.jl` 의 agents/zones/routing_kind 게이트): 루프백 `HTTP.serve!` +
#       `policy.jl` 의 `const DSPY_URL` 을 include 하는 동안만 치환 + `finally` 복원.
#
# 🔴 **구조적 보장**: `DSPY_URL` 은 `policy.jl:20` 의 `const` 라 include 시점에 **한 번**
#    ENV 에서 읽힌다. 그 순간 값이 우리 포트이므로, 이 모듈 안의 어떤 코드도 8077 로 갈
#    수 없다 — 문자열이 그 자리에 없다. testset (0) 이 그것을 단언으로 못박고,
#    testset (20) 이 우리 서버가 받은 요청 수를 **비-0 대조**로 센다.
#
# 기본 모드는 `:off` = 404 다. 그래서 (2)(4)(5) 의 거절 판은 이 파동 **전과 바이트 동일한
# 경로**를 탄다(왕복 실패 → 원래 거절 보존). 그것이 D17 의 계약이고, 그 계약이 여기서
# 계속 측정된다.
# =============================================================================
const _RW_MODE = Ref{Symbol}(:off)
const _RW_HITS = Ref{Int}(0)
const _RW_LAST = Ref{Any}(nothing)          # 마지막으로 받은 요청 본문(payload 단언용)

"고친 body 한 벌. `surface`/`params` 는 인자로 열어 둔다 — D4 가 그 둘을 겨눈다."
_rw_fix(nm; code = nothing, surface = "env_param", params = nothing, reversible = false) =
    Dict{String,Any}(
        "wrote" => true, "impl_name" => nm,
        "impl_code" => code === nothing ?
            "function $(nm)(env; note = \"x\")\n    return (status = :rw_ok, note = note)\nend\n" :
            code,
        "surface" => surface, "reversible" => reversible,
        "params" => params === nothing ?
            Dict{String,Any}("note" => Dict{String,Any}("type" => "string")) : params,
        "calls" => [Dict{String,Any}("primitive" => nm,
                                     "args" => Dict{String,Any}("note" => "rw"))],
        "error" => nothing, "rewrite_of_why" => "n/a")

const _RW_RESPONSES = Dict{Symbol,Function}(
    # 🔴 D1 의 측정 장치: 고친 body 의 **이름이 바뀐다**. 이름을 바꿔야만 고쳐지는 거절
    #    가족(`impl_name_must_end_with_bang` … `impl_name_exists_withheld`)의 모양이다.
    :rename      => () -> _rw_fix("rw_fixed!"),
    # 같은 변이를 (20c) 가 사본 위에서 다시 태운다. 🔴 이름을 재사용할 수 없다 —
    # `_MINTED_EVER` 가 프로세스 수명 내내 막는다(`impl_name_already_minted`).
    :rename_mut  => () -> _rw_fix("rw_mut_fixed!"),
    # 대조(A2): 이름을 **유지**한다. D1 이전에도 통과하던 유일한 갈래다.
    :keep        => () -> _rw_fix("rw_keep!"),
    # D4: 되먹임이 문자열이 아닌 `surface` 를 낸다. 본 경로는 이 모양을 거절한다.
    :bad_surface => () -> _rw_fix("rw_surf!"; surface = 7),
    # D4: 되먹임이 날것 문자열 `params` 를 낸다(파이썬 `params_object` 가 죽은 판).
    :bad_params  => () -> _rw_fix("rw_praw!"; params = "{\"note\": {\"type\": \"string\"}}"),
    # D5: 고친 body 가 **인터페이스 함수를 부른다** — L3 이 참인 판.
    :l3          => () -> _rw_fix("rw_l3!";
        code = "function rw_l3!(env; note = \"x\")\n" *
               "    n = length(env.active_build_steps)\n" *
               "    push!(env.active_build_steps, RobotID(7))\n" *
               "    return (status = :rw_ok, n = n)\nend\n"))

const _RW_SERVER = HTTP.serve!(HTTP.Sockets.localhost, 0;
                               listenany = true, verbose = -1) do req
    if req.target == "/rewrite"
        _RW_HITS[] += 1
        _RW_LAST[] = try JSON3.read(String(req.body)) catch; nothing end
        # 🔴 (30) Task 1 — 일부러 **깨진 JSON** 을 200으로 돌려준다. `_rewrite_once` 의
        #    `JSON3.read(String(resp.body))` 가 다줄 `ArgumentError` 를 던지게 만드는
        #    실제 트리거다(손으로 예외를 짓지 않는다). `_RW_RESPONSES` 의 값들은 전부
        #    `JSON3.write(::Dict)` 를 지나가므로 늘 유효한 JSON 만 낸다 — 그래서 이 모드는
        #    그 표를 우회하는 별도 분기다.
        _RW_MODE[] === :bad_json && return HTTP.Response(200, "{SENTINEL_CAUSE")
        haskey(_RW_RESPONSES, _RW_MODE[]) || return HTTP.Response(404, "")
        return HTTP.Response(200, JSON3.write(_RW_RESPONSES[_RW_MODE[]]()))
    end
    # 🔴 `/health`·`/decide` 도 404 다. 이 파일은 그 둘을 안 태우는데, 태우게 되는 날
    #    조용히 8077 로 나가는 것보다 빨개지는 쪽이 옳다.
    return HTTP.Response(404, "")
end
const _RW_PORT = HTTP.Servers.port(_RW_SERVER)

# `const DSPY_URL`(policy.jl)은 include 시점에 한 번만 ENV 를 읽는다. 그 순간에만 우리
# 포트로 돌려놓고 곧바로 되돌린다(같은 프로세스의 다른 게이트가 물들지 않도록).
const _PREV_DSPY_URL = get(ENV, "DSPY_URL", nothing)
ENV["DSPY_URL"] = "http://127.0.0.1:$(_RW_PORT)"
try
    include(joinpath(@__DIR__, "..", "tools", "monitor", "policy.jl"))
catch
    close(_RW_SERVER)
    rethrow()
finally
    _PREV_DSPY_URL === nothing ? delete!(ENV, "DSPY_URL") :
                                 (ENV["DSPY_URL"] = _PREV_DSPY_URL)
end
include(joinpath(@__DIR__, "..", "tools", "monitor", "enact.jl"))

@testset "(0) 🔴 D2: 되먹임은 루프백으로만 나간다 — 유료 경로가 구조적으로 닫혔다" begin
    # 🔴 이 단언이 D2 의 증명이다: `DSPY_URL` 은 `const` 이고 그 값이 우리 포트다.
    #    `_rewrite_once` 는 `DSPY_URL * "/rewrite"` 만 부르므로 다른 목적지가 없다.
    @test DSPY_URL == "http://127.0.0.1:$(_RW_PORT)"
    @test occursin(r"^http://127\.0\.0\.1:\d+$", DSPY_URL)
    @test !occursin("8077", DSPY_URL)
    # 🔴 ENV 는 원래대로 복원됐다 — 같은 프로세스의 다음 게이트가 물들지 않는다.
    @test get(ENV, "DSPY_URL", nothing) == _PREV_DSPY_URL
    # 비-0 대조: 서버가 실제로 살아 있고 우리 포트에서 응답한다(없으면 위 단언들은
    # "아무 데도 안 간다"와 구별이 안 된다).
    @test _RW_PORT > 0
    local probe = HTTP.post(DSPY_URL * "/rewrite", ["Content-Type" => "application/json"],
                            "{}"; status_exception = false, retries = 0)
    @test probe.status == 404          # 기본 모드 `:off`
    @test _RW_HITS[] == 1              # **우리** 서버가 받았다
    _RW_HITS[] = 0
end

"""
    _resp(synth::Dict{String,Any}) -> JSON3.Object

서비스 응답 한 벌을 짓고 **JSON3 왕복**시킨다. 결정 행이 아니라 `policy_entry` 의 입력이
필요한 것이므로 최상위 필드도 실제 응답과 같은 이름으로 채운다(`policy_entry` 는 `b` 를
Symbol 키로 읽는다 — `Dict{String,Any}` 를 그대로 주면 전부 미스해 **실패 분기**가 조용히
탄다). 🔴 픽스처를 여기 한 벌만 두는 이유: 이 파일의 머리말이 "모든 픽스처가 왕복한다" 고
주장하는데, 왕복을 testset 마다 손으로 적으면 그 주장이 다시 갈릴 수 있다.
"""
_resp(synth::Dict{String,Any}) = JSON3.read(JSON3.write(Dict{String,Any}(
    "chosen" => "NOOP", "ranking" => ["NOOP"], "margin" => nothing, "rationale" => "r",
    "policy" => "dspy", "coerced" => false, "error" => nothing,
    "tool_minted" => true, "synthesis" => synth)))

_lane(synth::Dict{String,Any}) = policy_entry(_resp(synth), "dspy")
_dec(sl) = (macro_name = "NOOP", synth_lane = sl)

# `_issue_resume!`/`_resolve_if_needed!` 가 요구하는 필드가 **없는** env. 그래서 아래 (1)~(4)
# 는 전부 `handled === false` 다 — 그것이 결함이 아니라 이 env 의 성질이라는 것을 (6) 이
# 같은 body 모양에 **완전한** env 를 주어 반대편에서 보여 준다.
const BARE_ENV = (staging_circles = Dict{Symbol,Any}(),)

"""
    live_cache_env() -> NamedTuple

`reset_cache_resume!` 이 실제로 나갈 수 있는 최소 env. 낡은 정점 하나를 심어 두어 **재개가
실제로 나갔는지가 `active_set` 으로 관측 가능**하게 만든다.

🔴 **m2(2026-09-03 리뷰): 여기 있던 "`tools/monitor/test_minted_wiring.jl` 의
`throw_env_with_live_cache()` 와 같은 관용구" 라는 문장은 낡았다.** D18 이 아래
`active_build_steps` 를 더하면서 **둘이 갈렸다** — 그쪽 픽스처는 그 필드가 없고, 그래서 그
파일의 모든 판에서 `world_delta` 가 **언제나 `nothing`** 이다(그 게이트는 다이제스트를 아예
못 본다). 그 파일은 이 파동의 경로 밖이라 안 건드렸다. 여기서 그 사실을 적어 두는 이유:
"wiring 게이트도 초록이다" 를 "다이제스트가 거기서도 검증됐다" 로 읽으면 틀린다.

🔴 2026-09-04 (D18). `active_build_steps` 는 **이 시험을 위해 나중에 더한 필드다.** 그 전
판은 `(cache, sched)` 둘뿐이었고, 그래서 `_world_digest` 가 이 env 에서 통째로 `nothing`
을 냈다(실측: `type NamedTuple has no field active_build_steps` → 다이제스트의 `catch` 가
`nothing` 으로 삼킨다). 즉 **"쟀는데 0" 과 "못 쟀다" 를 가르는 testset (10)(11) 이 이 env
에서는 후자만 볼 수 있었다.** 필드 이름·타입의 진실원은 `PlannerEnv`(`src/route_planning.jl`
의 `active_build_steps::Set{AbstractID}`)이고 여기는 그 모양을 빈 채로 흉내낼 뿐이다.
⚠️ 다이제스트는 **다섯을 전부**(2026-09-04 Task 2 가 `sched.weights` 를 더했다) 읽어야
지문을 낸다 — 하나라도 없으면 `nothing` 이다. 그것이
설계다(반쯤 잰 지문의 차분은 무엇을 뜻하는지 아무도 못 적는다).
"""
function live_cache_env()
    sched = CB.OperatingSchedule()
    cache = CB.initialize_planning_cache(sched)
    push!(cache.active_set, 999)
    return (cache = cache, sched = sched,
            active_build_steps = Set{CB.AbstractID}())
end

const OK_SYNTH = Dict{String,Any}(
    "synthesis_event" => true, "ran" => true, "error" => nothing,
    "tool_name" => "T", "impl_name" => "e2e_touch!",
    "impl_code" => "function e2e_touch!(env; note = \"x\")\n    return (status = :e2e_ok, note = note)\nend\n",
    "surface" => "sched", "reversible" => true,
    "params" => Dict{String,Any}("note" => Dict{String,Any}("type" => "string")),
    "body_names" => ["e2e_touch!"], "wrote" => true,
    "calls" => [Dict{String,Any}("primitive" => "e2e_touch!",
                                 "args" => Dict{String,Any}("note" => "hi"))])

@testset "(1) 생성 코드가 응답에서 등록·집행부까지 간다" begin
    CB.reset_minted_table!()
    e = _lane(OK_SYNTH)
    for k in ("impl_name", "impl_code", "surface", "reversible")
        @test haskey(e, k)
    end
    r = enact_minted_decision!(BARE_ENV, nothing, _dec(e))
    @test r.verdict === :admit
    @test r.args_from === :calls && r.n_calls == 1
    @test length(r.steps) == 1 && r.steps[1].status === :e2e_ok
    # 🔴 F5. 행복 경로: 등록이 실제로 됐고, 거절 사유는 없다.
    @test r.registered === true
    @test r.impl_rejected_why === nothing
    # 🔴 F6(5)(2026-09-03 최종 리뷰). 이 fixture 의 `env` 는 `staging_circles` 하나뿐이라
    #    `_issue_resume!`/`_resolve_if_needed!` 가 요구하는 `cache`/`sched` 필드가 없다 —
    #    그래서 `resume=:failed`(재개 시도가 예외로 끝남)·`resolve=:threw` 가 나고
    #    `minted_handled` 의 네 연언지 중 둘이 깨져 `handled === false` 다(실측). 이것은
    #    이 시험의 **결함이 아니라 측정값**이다. 🔴 그리고 그 사실은 **이 env 의 성질이지
    #    생성 경로의 성질이 아니다** — 아래 (6) 이 완전한 env 로 같은 모양을 굴려
    #    `handled === true` 를 잰다(B6).
    @test r.handled === false
end

@testset "(2) 🔴 F5: 규약 위반 impl_code 는 registered=false·impl_rejected_why 를 남기고 집행을 시도하지 않는다" begin
    CB.reset_minted_table!()
    e2 = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "e2e_bad!",
        # 규약 위반: 위치인자가 `env` 하나가 아니다(`check_impl_conventions` 가 거절한다).
        "impl_code" => "function e2e_bad!(x; note = \"x\")\n    return :ok\nend\n",
        "surface" => "sched", "reversible" => true,
        "params" => Dict{String,Any}(),
        "body_names" => ["e2e_bad!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "e2e_bad!",
                                     "args" => Dict{String,Any}())]))
    r2 = enact_minted_decision!(BARE_ENV, nothing, _dec(e2))
    @test r2.verdict === :reject
    @test r2.registered === false
    @test r2.impl_rejected_why !== nothing &&
          occursin("reject:", r2.impl_rejected_why) &&
          occursin("positional", r2.impl_rejected_why)
    # 🔴 집행이 시도되지 않았다 — 등록 거절이 `CB.enact_minted!` 호출보다 먼저 돌아선다.
    @test isempty(r2.steps)
    @test r2.handled === false
    @test !isdefined(CB, :e2e_bad!)   # Core.eval 자체가 안 됐다는 것을 직접 잰다
end

@testset "(3) 🔴 F5/F2: 등록은 성공했는데 enact_minted! 가 던지면 registered=true 가 정직하게 남는다" begin
    # 🔴 2026-09-03 최종 리뷰 F7 재작성, F9 로 근거 갱신. 이전 판은 `registered === nothing`
    #    을 `register_minted_primitive!` 자신의 계약 위반(`params` 가 정수 키 dict 이면
    #    `String(::Int64)` 로 **던졌다** — R8 이 고쳤다, `src/respec/minted_registration.jl`
    #    참고)에 기대어 재고 있었다. F7 시점엔 "그 던지기가 유일한 생산자다" 라고 적었는데
    #    **틀렸다** — 그 함수가 먼저 부르는 `check_impl_conventions` 안에 **다른** 던지는
    #    자리(콜리가 `Symbol` 이 아닌 세 모양 — 한정 이름·보간·callable 객체)가 남아 있었고,
    #    F9 최종 리뷰가 그것을 잡았다. 두 결함을 다 고친 **지금**, 실측한 모델-도달가능
    #    모양 중 이 두 함수가 던지는 자리는 없다(`registered` docstring 이 재도출을 적는다).
    #    **나중에 `Bool` 로 되돌리거나 이 상태를 재려고 또 다른 버그에 기대는 시험을 짓지 말 것.**
    #
    #    F5 가 진짜로 재려던 것은 "등록 뒤에 다른 자리가 던지면 그 사실을 안 잃는가" 다 —
    #    R2 의 옛 리터럴 `false` 가 거짓말하던 자리가 정확히 이것이다. 깨끗한 예: 등록은
    #    정상 규약이고, `body_names` 가 `[1, 2]`(정수) 라서 `enact_minted!` 이
    #    `String.(body_names)` 에서 던진다 — 등록 자체는 아무 규약도 안 어겼다.
    CB.reset_minted_table!()
    e3 = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "alt_ok!",
        "impl_code" => "function alt_ok!(env; note = \"x\")\n    return :ok\nend\n",
        "surface" => "sched", "reversible" => false,
        "params" => Dict{String,Any}(),
        "body_names" => [1, 2], "wrote" => true, "calls" => nothing))
    r3 = enact_minted_decision!(BARE_ENV, nothing, _dec(e3))
    @test r3.verdict === :reject
    @test occursin("threw", r3.reason) && occursin("String", r3.reason)
    # 🔴 핵심 단언 — R2 시절 리터럴 `false` 가 거짓말했을 자리. 등록은 실제로 성공했다
    #    (`minted_table()` 에 행이 있다) — 이 예외는 그 **뒤** `enact_minted!` 안에서
    #    났다. `registered` 는 그 사실을 안 잃는다.
    @test r3.registered === true
    @test r3.impl_rejected_why === nothing
    @test haskey(CB.minted_table(), "alt_ok!")
    @test r3.handled === false
    # 🔴 B4(2026-09-03 최종 리뷰). **이 값을 못박는다.** 이것은 바깥 `catch` 의 반환이고,
    #    그 자리는 `false`(F20 전) → `nothing`(F20) → `true`(B4) 로 세 번 바뀌는 동안
    #    **레포 전체에 단언이 하나도 없어서** 셋 다 초록이었다. 오늘의 계약은 `true` 다:
    #    이 필드는 가능성 술어("세계가 더러울 **수** 있는가")라 "못 쟀다" 가 "그럴 수 있다"
    #    로 무너지고, 소비자(`minted_handled`)가 `&&` 의 항으로 읽어 `Bool` 을 요구한다.
    @test r3.world_maybe_dirty === true
    @test r3.world_maybe_dirty isa Bool
end

@testset "(4) 🔴 F9(R9): 한정 이름(D6-모양) 이 경계 끝까지 던지지 않고 자기 사유로 거절된다" begin
    # 🔴 2026-09-03 최종 리뷰 F9. 셋 중 **가장 위험한 모양** — 모델이 가려진 능력을 다시
    #    이름 붙이려 할 때 실제로 쓸 법한 것은 한정 이름(`ConstructionBots.foo!`)이다.
    #    F9 전에는 이 payload 가 `check_impl_conventions` 안의 `String(sig.args[1])` 에서
    #    던져 `verdict=:reject, registered=nothing, impl_rejected_why=nothing,
    #    reason="...threw: MethodError..."` 로 도착했다 — D6 신호가 기록되지 않고
    #    소실됐다. 지금은 등록 단계에서 **거절**로 잡혀 사유가 남는다.
    CB.reset_minted_table!()
    e4 = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "qual_e2e_touch!",
        "impl_code" => "function ConstructionBots.qual_e2e_touch!(env; note = \"x\")\n    return :ok\nend\n",
        "surface" => "sched", "reversible" => false,
        "params" => Dict{String,Any}(),
        "body_names" => ["qual_e2e_touch!"], "wrote" => true, "calls" => nothing))
    r4 = enact_minted_decision!(BARE_ENV, nothing, _dec(e4))
    @test r4.verdict === :reject
    @test !occursin("threw", r4.reason)   # 예외가 아니라 거절이다 — 던진 적이 없다
    # 🔴 핵심 단언. `registered` 는 `nothing`(판정 불가)이 아니라 `false`(봤는데 안
    #    됐다)다 — 등록 시도가 실제로 돌아 규약 위반으로 거절됐음을 안다.
    @test r4.registered === false
    @test r4.impl_rejected_why !== nothing &&
          startswith(r4.impl_rejected_why, "reject:impl_name_is_qualified:")
    @test isempty(r4.steps)
    @test !isdefined(CB, :qual_e2e_touch!)
    @test r4.handled === false
end

# =============================================================================
# (5) 🔴 교차언어 **타입** 계약 — 파이썬이 실제로 낸 기록을 줄리아가 먹는다
#
# 🔴 유료 0건. `synthesize_multi` 를 **가짜 프로그램 셋**으로 돌린다(dspy 프로그램이 전부
#    주입되므로 LM 은 만들어지지도 않는다). 호출은 `env -u OPENAI_API_KEY` 로 감싼다.
# 🔴 **자극과 단언을 가른다.** 아래 파이썬 블록의 리터럴(스키마 문자열 등)은 *모델이 낼
#    법한 것*, 즉 **자극**이다 — 그래서 일부러 라이브 모양(JSON Schema 봉투)으로 적는다.
#    반면 단언은 파이썬 리터럴을 **하나도 안 베낀다**: 값을 전부 `synthesize_multi` 가 실제로
#    낸 기록에서 읽고, 타입은 아래 `BOUNDARY_TYPES` 표 하나가 갖는다. C-F1 이 살아남은 이유가
#    정확히 그 구별이 없었기 때문이다 — `test_write_tool_impl.py` 가 자극 자리에 **이미
#    정규화된** 평평한 맵을 박아 두어, 단언이 통과해도 라이브에서는 아무 말도 못 했다.
# =============================================================================
const _PY_BIN = normpath(joinpath(@__DIR__, "..", ".venv", "bin", "python"))
const _PY_DIR = normpath(joinpath(@__DIR__, "..", "src", "respec", "llm_service"))

# 🔴 이 블록 안에 큰따옴표 **세 개 연속**이나 `\` + 큰따옴표를 쓰지 말 것. 줄리아의 raw
#    삼중따옴표 리터럴은 (a) 따옴표 셋에서 **끝나고** (b) 역슬래시+따옴표를 따옴표 하나로
#    **접는다** — 그래서 파이썬 소스 안의 큰따옴표는 `chr(34)` 로 짓는다(이스케이프를 두
#    언어에 걸쳐 세는 순간 한쪽이 조용히 틀린다).
const _PY_RECORD = raw"""
import json, os, sys
sys.path.insert(0, sys.argv[1])
import synthesize as SY
os.environ[SY.SYNTHESIS_ENV] = "1"
NAME = sys.argv[2]

class _P:
    def __init__(self, **kw): self.__dict__.update(kw)

# 큰따옴표는 chr(34) 로 짓는다 — 이유는 줄리아 쪽 `_PY_RECORD` 의 주석에 있다.
Q = chr(34)
BARE = ("function " + NAME + "(env; note = " + Q + "x" + Q + ")\n"
        "    return (status = :crosslang_ok, note = note)\nend\n")
# 🔴 R18 (2026-09-03) — **자극**이 라이브 모양으로 바뀌었다: 모델은 코드를 마크다운
#    펜스로 감싼다(두 번째 유료 런의 실측 모양). 이것을 벗기는 것은 파이썬의 몫이고
#    (`synthesize.strip_code_fence`), 이 게이트는 그 정규화가 **경계를 건너 살아 있는지**
#    를 잰다 — 펜스가 그대로 오면 줄리아 등록이 `reject:impl_code_is_fenced` 로 거절해
#    아래 (5-b) 가 통째로 빨개진다.
CODE = "```julia\n" + BARE + "```"
progs = {
    "observe": lambda **kw: _P(reasoning_log="the robot is degraded"),
    "design":  lambda **kw: _P(expressible=False, tool_name="CrossLangProbe",
                               params='{"note": {"type": "string"}}', mechanism="m"),
    "compose": lambda **kw: _P(wrote=True, impl_name=NAME, surface="env_param",
                               reversible=True, impl_code=CODE,
                               params='{"type": "object", "properties": {"note": {"type": "string"}}}',
                               calls=[{"primitive": NAME, "args": {"note": "hi"}}]),
}
rec = SY.synthesize_multi(state="s", tools=[], ledger=SY.SynthesisLedger(), programs=progs)
print("__RECORD__" + json.dumps({
    "chosen": "NOOP", "ranking": ["NOOP"], "margin": None, "rationale": "r",
    "policy": "dspy:offline", "coerced": False, "error": None,
    "tool_minted": rec["tool_minted"], "synthesis": rec}, ensure_ascii=False))
"""

"""
    py_service_response(name) -> JSON3.Object

`synthesize.py` 가 **실제로 짓는** 합성 기록을 서비스 응답 모양으로 감싸 돌려준다.
🔴 파이썬에 못 닿으면 **skip 이 아니라 빨개진다** — skip 은 이 시험이 막으려는 구멍에
단계만 하나 더한 것이다(`synth_lane_keys_survive.jl` 의 같은 규약).
"""
function py_service_response(name::AbstractString)
    isfile(_PY_BIN) || error("교차언어 타입 게이트: 파이썬이 없다 — $(_PY_BIN) (skip 하지 않는다)")
    local o = IOBuffer(); local e = IOBuffer()
    local pr = run(pipeline(ignorestatus(
        `env -u OPENAI_API_KEY $(_PY_BIN) -c $(_PY_RECORD) $(_PY_DIR) $(name)`);
        stdout = o, stderr = e))
    local out = String(take!(o)); local errs = String(take!(e))
    pr.exitcode == 0 || error("교차언어 타입 게이트: 기록 생성 실패 (rc=$(pr.exitcode))\n$(errs)")
    local marked = filter(l -> startswith(l, "__RECORD__"), split(out, "\n"))
    length(marked) == 1 ||
        error("교차언어 타입 게이트: `__RECORD__` 줄이 정확히 하나가 아니다 ($(length(marked)))\n$(out)")
    return JSON3.read(chop(marked[1], head = length("__RECORD__"), tail = 0))
end

"""
    BOUNDARY_TYPES

**경계 키마다: 파이썬이 내는 값이 줄리아에서 무슨 타입으로 물질화돼야 하는가.**

🔴 이 표가 이 파일이 새로 지는 하중이다. `SYNTH_LANE_KEYS`(이름 축)는
`test/synth_lane_keys_survive.jl` 이 파이썬 소스의 AST 로 지키는데, 그 게이트는 **타입도 값도
안 본다** — 그래서 파이썬이 `params` 를 JSON 스키마 **문자열**로 내고 줄리아 등록 가드가
`AbstractDict` 를 요구하는 파열이 양쪽 스위트가 초록인 채로 다섯 리뷰 라운드를 살아남았다.
오른쪽 타입은 **줄리아 소비자가 실제로 요구하는 것**이고, 요구하는 자리를 같이 적는다:

| 키 | 요구하는 자리 |
|---|---|
| `impl_name`  | `enact.jl`: `nm isa AbstractString ‖ reject:impl_name_not_a_string` |
| `impl_code`  | `enact.jl`: `cd isa AbstractString ‖ reject:impl_code_not_a_string` |
| `surface`    | `enact.jl`: `surf_raw isa AbstractString ‖ reject:surface_not_a_string` |
| `params`     | `enact.jl`: `praw isa AbstractDict ‖ reject:params_not_an_object` 🔴 B2 |
| `reversible` | `enact.jl`: `... === true` (Bool 이 아니면 조용히 false 가 된다) |
| `body_names` | `minted_tool.jl`: `String.(body_names)` — 벡터여야 한다 |
| `calls`      | `minted_tool.jl`: `normalize`가 원소마다 `primitive`/`args` 를 읽는다 |
| `wrote`      | `enact.jl` 의 조기반환 로그(줄리아 유일 독자) — 삼상이라 Bool 이어야 한다 |
| `refused`    | 같은 로그. 이 판은 G1 가드가 돌고 통과했으므로 `false` 다 |
"""
const BOUNDARY_TYPES = [
    "tool_minted"     => Bool,
    "synthesis_event" => Bool,
    "synthesis_ran"   => Bool,
    "refused"         => Bool,
    "tool_name"       => AbstractString,
    "body_names"      => AbstractVector,
    "params"          => AbstractDict,
    "calls"           => AbstractVector,
    "impl_name"       => AbstractString,
    "impl_code"       => AbstractString,
    "surface"         => AbstractString,
    "reversible"      => Bool,
    "wrote"           => Bool,
]

@testset "(5) 🔴 교차언어: 파이썬이 낸 기록의 **타입**이 줄리아 경계와 맞고, 그대로 집행된다" begin
    CB.reset_minted_table!()
    local NAME = "crosslang_probe!"
    local resp = py_service_response(NAME)
    local e = policy_entry(resp, "dspy")

    # 먼저 성공 분기가 실제로 탔는지 — 아니면 아래 표는 "실패 분기가 우연히 nothing 이 아니다"
    # 를 재는 것이 된다.
    @test e["available"] === true
    @test e["impl_name"] == NAME

    # ---- (5-0) 🔴 R18 FIX A: 펜스는 경계를 못 건넌다 ------------------------------------------
    # 자극은 펜스로 감싼 코드였다(위 `_PY_RECORD`). 경계에 도착하는 것은 맨 Julia 다 —
    # 정규화는 파이썬 하나가 하고(`strip_code_fence`), 줄리아는 진단만 한다.
    @test !occursin("`", e["impl_code"])
    @test startswith(e["impl_code"], "function " * NAME)

    # ---- (5-a) 타입 계약 -------------------------------------------------------------------
    for (k, T) in BOUNDARY_TYPES
        @test haskey(e, k)
        @test e[k] isa T
    end
    # 삼상: 이 판은 성공이므로 오류 필드는 "쟀고 없다" 가 아니라 `nothing` 이다.
    @test e["synthesis_error"] === nothing
    # 🔴 B2 가 고친 그 축을 **따로** 못박는다. 위 루프만 있으면 누가 표의 `params` 행을
    #    `Any` 로 넓히는 순간 조용히 통과한다.
    @test !(e["params"] isa AbstractString)
    # 🔴 **모양도 계약이다.** 라이브 모델은 JSON Schema **봉투**
    #    (`{"type":"object","properties":{...},"required":[...]}`)를 낸다 — 위 가짜
    #    프로그램도 그 모양을 낸다. 줄리아 등록 행의 `params` 는 봉투가 아니라 **키워드
    #    맵**이어야 한다(`_enactability` 연언지 (iii): 키가 전부 그 메서드의 키워드).
    #    봉투를 그대로 보내면 키가 `type`/`properties`/`required` 가 되어 원시가
    #    **등록은 되고 영영 호출 불가**(`reject:unenactable:…:kwargs`)가 된다 — 이 게이트가
    #    실제로 잡아낸 층이다. 파이썬의 `params_object` 가 봉투를 벗긴다.
    @test e["params"]["note"]["type"] == "string"
    @test !haskey(e["params"], "properties")
    @test !haskey(e["params"], "type")

    # ---- (5-b) 그 기록이 실제로 등록·집행된다 ------------------------------------------------
    local r = enact_minted_decision!(BARE_ENV, nothing, _dec(e))
    @test r.verdict === :admit
    @test r.registered === true
    @test r.impl_rejected_why === nothing
    @test r.args_from === :calls && r.n_calls == 1
    @test length(r.steps) == 1 && r.steps[1].status === :crosslang_ok

    # ---- (5-c) 🔴 음성 대조: 그 타입이 정말로 하중을 지는가 ------------------------------------
    # `params` **만** 라이브 이전 모양(JSON 스키마 문자열)으로 되돌린다. 나머지는 그대로다.
    # 이것이 2026-09-03 이전의 파이썬이 실제로 내던 값이고, 그때 이 경계는 등록을 거절하며
    # `Core.eval` 에 도달조차 못 했다.
    local as_text = Dict{String,Any}(String(k) => v for (k, v) in pairs(resp[:synthesis]))
    as_text["params"] = JSON3.write(resp[:synthesis][:params])
    as_text["impl_name"] = "crosslang_probe_text!"
    as_text["impl_code"] = replace(String(resp[:synthesis][:impl_code]),
                                   NAME => "crosslang_probe_text!")
    as_text["body_names"] = ["crosslang_probe_text!"]
    as_text["calls"] = nothing
    local r_text = enact_minted_decision!(BARE_ENV, nothing, _dec(_lane(as_text)))
    @test r_text.verdict === :reject
    @test r_text.registered === false
    @test r_text.impl_rejected_why == "reject:params_not_an_object:String"
    @test isempty(r_text.steps)
    @test !isdefined(CB, :crosslang_probe_text!)   # Core.eval 에 도달조차 못 했다

    # ---- (5-d) 🔴 R18 FIX C 음성 대조: 펜스가 **정말로** 경계에서 거절되는가 -------------------
    # 위 (5-0) 은 "파이썬이 벗겼다" 를 잰다. 그것이 하중을 지려면 **안 벗겼을 때 실제로
    # 거절된다**는 것이 참이어야 한다 — 아니면 (5-0) 은 아무것도 안 지키는 단언이다.
    # 🔴 이 사유는 **진단이지 둘째 고침이 아니다**: 정상 배관에서 펜스는 여기 못 온다.
    #    오면 파이썬 정규화가 실패했다는 뜻이고, `impl_not_a_function`(=agent-3 에게 가는
    #    틀린 수리 신호)이 아니라 배관 고장을 가리키는 이름으로 도착해야 한다.
    local as_fenced = Dict{String,Any}(String(k) => v for (k, v) in pairs(resp[:synthesis]))
    as_fenced["impl_name"] = "crosslang_probe_fenced!"
    as_fenced["impl_code"] = "```julia\n" *
        replace(String(e["impl_code"]), NAME => "crosslang_probe_fenced!") * "```"
    as_fenced["body_names"] = ["crosslang_probe_fenced!"]
    as_fenced["calls"] = nothing
    local r_fenced = enact_minted_decision!(BARE_ENV, nothing, _dec(_lane(as_fenced)))
    @test r_fenced.verdict === :reject
    @test r_fenced.registered === false
    @test r_fenced.impl_rejected_why == "reject:impl_code_is_fenced"
    @test isempty(r_fenced.steps)
    @test !isdefined(CB, :crosslang_probe_fenced!)
end

@testset "(6) 🔴 B6: 무동작 생성 원시도 handled=true 다 — 행동이 아니라 **측정**이다" begin
    # 🔴 **행동을 바꾸지 마라.** `world_maybe_dirty = touched || partial` 이고 생성 원시에
    #    대해 `_step_touched_world` 는 **일부러** true 다(`src/respec/minted_tool.jl` 이
    #    근거를 적는다: 임의의 생성 코드가 라이브 `env` 를 받아 끝까지 돌았으므로 "손을 댔을
    #    **수** 있는가" 의 답은 참이고, 더러워졌을 수 있는 세계 위에 폴백을 쌓는 것이 더
    #    나쁘다). 이 testset 은 그 계약의 **귀결**을 잰다:
    #      · body 가 세계를 한 바이트도 안 바꿔도 `world_maybe_dirty === true`
    #      · ⟹ `handled === true` ⟹ 기본 복구 사슬을 건너뛰고 그 OOD 사건은 소비된다
    #      · 그런데 `applied === nothing` 이다 — "노린 적응이 일어났나" 는 **못 쟀다**.
    #    🔴 Task 11 의 귀결(사전등록에 적힌 것): 성공률을 `handled` 로 세면 생성 어휘는
    #    구조적으로 100% 가 된다. 세어야 하는 것은 `applied` 이고 그 값은 오늘 삼상이다.
    CB.reset_minted_table!()
    local env = live_cache_env()
    local e = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "b6_noop_probe!",
        # 세계를 한 바이트도 안 건드린다 — `env` 를 읽지도 않는다.
        "impl_code" => "function b6_noop_probe!(env; note = \"x\")\n    return (status = :b6_noop, note = note)\nend\n",
        # 🔴 `surface` 가 `RESOLVE_SURFACES`(sched·milp) 밖이라 공통 재풀이가 안 돈다
        #    (`resolve = :not_needed_surface`). 넷째 연언지를 고립시키려는 것이 아니라,
        #    무동작 body 에 진짜 MILP 재풀이를 얹으면 이 시험이 재려는 것이 흐려진다.
        "surface" => "env_param", "reversible" => true,
        "params" => Dict{String,Any}("note" => Dict{String,Any}("type" => "string")),
        "body_names" => ["b6_noop_probe!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "b6_noop_probe!",
                                     "args" => Dict{String,Any}("note" => "hi"))]))
    local r = enact_minted_decision!(env, nothing, _dec(e))
    # 전제 — 이 판이 정말 **생성** 경로이고 body 가 돌았는가.
    @test r.registered === true
    @test r.verdict === :admit
    @test length(r.steps) == 1 && r.steps[1].status === :b6_noop
    # 🔴 파킹된 C1 의 행동, 이제 **잰다**.
    @test r.applied === nothing              # "적응했나" 는 못 쟀다(생성 원시의 status 어휘가 없다)
    @test r.world_maybe_dirty === true       # "손을 댔을 수 있나" 는 쟀다 — 참이다
    @test r.resume === :issued
    @test r.resolve === :not_needed_surface
    @test isempty(env.cache.active_set)      # 재개가 실제로 나갔다 — 세계에 보인다
    # 🔴 생산이 읽는 유일한 값. 이 줄이 없으면 이 브랜치 전체에서 생성 경로의 `handled` 를
    #    재는 단언이 0개다.
    @test r.handled === true
end


@testset "(7) 🔴 D16: JSON3 배열·객체가 선언 타입으로 변환돼 호출이 산다" begin
    CB.reset_minted_table!()
    # 🔴 2026-09-04 fix round 1 (F4). 이 testset 의 **이름**은 처음부터 "배열·객체" 였는데
    #    배열과 `Int` 만 태우고 있었다 — 객체 사례가 세 시험 어디에도 없었다. 그리고 그
    #    빈 자리에 실제 결함이 있었다: `JSON3.Object` 의 `keytype` 은 `Symbol` 이라
    #    `convert(Dict{String,Any}, ::JSON3.Object)` 는 **던진다**. 즉 이 레포가 도처에서
    #    쓰는 가장 자연스러운 철자로 주석한 객체 인자가 전부 `reject:param_convert:` 로
    #    막혀 원시가 영영 안 돌았다(거절이라 안전하지만 채널은 닫힌 것이다).
    code = """
    function d16_array_tool!(env; task_ids::Array{String,1}=String[], k::Int=0,
                             meta::Dict{String,Any}=Dict{String,Any}())
        return (status = Symbol("saw_", length(task_ids), "_", k, "_", length(meta)),)
    end
    """
    params = Dict{String,Any}("task_ids" => Dict("type" => "array",
                                                 "items" => Dict("type" => "string")),
                              "k" => Dict("type" => "integer"),
                              "meta" => Dict("type" => "object"))
    @test CB.register_minted_primitive!(name = "d16_array_tool!", code = code,
                                        params = params, surface = "sched",
                                        reversible = false) === nothing
    prim = CB.resolve_primitive("d16_array_tool!")
    @test prim !== nothing
    # 🔴 S6 (2026-09-05): 원소가 `"t1","t2","t3"` 이었는데, 그것은 `_is_placeholder_token`
    #    가 **일부러 잡는** 모양이라(알파벳 낱말+숫자) 인자가 통째로 안 묶여 이 시험이
    #    `saw_0_7_2` 로 빨개졌다. 이 절이 재는 것은 정체가 아니라 **D16 변환**이므로,
    #    픽스처를 세계가 실제로 발행하는 id 철자로 바꾼다(길이 3 은 그대로다).
    calls = CB.normalize_calls(JSON3.read(
        """[{"primitive":"d16_array_tool!","args":{"task_ids":["AssemblyID(1)","AssemblyID(2)","AssemblyID(3)"],"k":7,""" *
        """"meta":{"a":1,"b":2}}}]"""))
    @test !(calls isa String)
    b = CB.bind_primitive_args(prim, (env = :DUMMY, truth = nothing, params = calls[1][2]))
    @test !(b isa String)
    # 🔴 뷰가 아니라 네이티브 컨테이너여야 한다
    @test b[2].task_ids isa Vector{String}
    # 🔴 F4: 키를 `Symbol` 에서 `String` 으로 옮겨 주는 것은 **경계의 몫**이다.
    @test b[2].meta isa Dict{String,Any}
    @test b[2].meta["a"] == 1 && b[2].meta["b"] == 2
    r = Base.invokelatest(getfield(CB, Symbol("d16_array_tool!")), b[1]...; b[2]...)
    @test r.status === :saw_3_7_2
end

@testset "(8) 🔴 D16: 변환 실패는 예외가 아니라 거절이다" begin
    CB.reset_minted_table!()
    code = """
    function d16_bad_tool!(env; n::Int=0)
        return (status = :ok,)
    end
    """
    @test CB.register_minted_primitive!(name = "d16_bad_tool!", code = code,
        params = Dict{String,Any}("n" => Dict("type" => "string")),
        surface = "sched", reversible = false) === nothing
    calls = CB.normalize_calls(JSON3.read(
        """[{"primitive":"d16_bad_tool!","args":{"n":"not a number"}}]"""))
    b = CB.bind_primitive_args(CB.resolve_primitive("d16_bad_tool!"),
                               (env = :DUMMY, truth = nothing, params = calls[1][2]))
    @test b isa String
    @test startswith(b, "reject:param_convert:n:")
end

@testset "(9) 🔴 D16: 주석 없는 키워드는 오늘 그대로 흐른다" begin
    CB.reset_minted_table!()
    code = """
    function d16_plain_tool!(env; anything="x")
        return (status = :ok,)
    end
    """
    @test CB.register_minted_primitive!(name = "d16_plain_tool!", code = code,
        params = Dict{String,Any}("anything" => Dict("type" => "string")),
        surface = "sched", reversible = false) === nothing
    prim = CB.resolve_primitive("d16_plain_tool!")
    @test !haskey(prim.param_types, "anything")   # 키가 **없다** (nothing 을 넣지 않는다)
end


@testset "(10) 🔴 D18: 집행 전후 세계 다이제스트가 기록된다" begin
    # 🔴 사전등록 결정 1(R11)이 "못 잰다" 고 적은 축. 오늘의 관측 넷 중 어느 것도 **세계가
    #    바뀌었다** 를 못 잰다: `handled` 는 생성 body 면 구성상 ~100%, `applied` 는 항상
    #    `nothing`, `world_maybe_dirty` 는 무조건 `true`(testset (6) 이 그것을 실측한다),
    #    `steps.status` 는 모델의 자기신고다. `world_delta` 가 그 자리를 대신한다.
    # 🔴 브리핑의 픽스처(`enact_minted_decision!(env, nothing, sl)` — 손으로 지은
    #    `Dict{String,Any}` 를 **decision 자리에** 직접)는 이 파일에서 못 쓴다: 셋째 인자는
    #    `decision` 이라 `decision.synth_lane` 을 읽는데 `Dict` 에는 그 필드가 없어
    #    조기 `:deferred` 로 떨어진다(= body 가 아예 안 돈다). 이 파일의 규약대로
    #    `_lane(...)`(JSON3 왕복) → `_dec(...)` 를 지나간다.
    # ⚠️ `surface` 는 `env_param` 이다(브리핑의 `sched` 가 아니라). `sched` 는
    #    `RESOLVE_SURFACES` 안이라 공통 MILP 재풀이가 돌고, 그러면 이 시험이 재려는 차분에
    #    body 가 아닌 재풀이의 편집이 섞인다 — testset (6) 이 같은 이유로 같은 선택을 했다.
    CB.reset_minted_table!()
    local env = live_cache_env()
    local before = length(env.cache.closed_set)
    local e = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "d18_touch_tool!",
        "impl_code" => "function d18_touch_tool!(env; v::Int = 1)\n" *
                       "    push!(env.cache.closed_set, v)\n" *
                       "    return (status = :d18_touched,)\nend\n",
        "surface" => "env_param", "reversible" => false,
        "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
        "body_names" => ["d18_touch_tool!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "d18_touch_tool!",
                                     "args" => Dict{String,Any}("v" => 999_001))]))
    local r = enact_minted_decision!(env, nothing, _dec(e))
    # 전제 — 이 판이 정말 생성 경로이고 body 가 돌았는가(음성 대조 없이 0 을 읽지 않는다).
    @test r.registered === true
    @test r.verdict === :admit
    @test length(r.steps) == 1 && r.steps[1].status === :d18_touched
    @test 999_001 in env.cache.closed_set
    # 🔴 재는 것.
    @test r.world_delta !== nothing
    @test r.world_delta.closed == length(env.cache.closed_set) - before
    @test r.world_delta.closed == 1
end

@testset "(11) 🔴 D18: 무동작 원시의 차분은 0 이다 — nothing 이 아니다" begin
    # 🔴 **이 testset 이 삼상 규약 그 자체다.** `nothing`("못 쟀다")과 0 의 튜플("쟀는데
    #    안 바뀌었다")은 서로 다른 관측이고, `_world_digest` 의 `catch` 가 그 둘을 뭉개면
    #    D18 은 아무것도 안 재는 필드가 된다 — 세계를 안 바꾸는 body 가 정확히 오늘의
    #    지배적인 판이므로(testset (6)), 뭉개진 판에서는 **모든** 판이 `nothing` 으로 보인다.
    CB.reset_minted_table!()
    local env = live_cache_env()
    local e = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "d18_noop_tool!",
        # 세계를 한 바이트도 안 건드린다 — `env` 를 읽지도 않는다((6) 과 같은 body 모양).
        "impl_code" => "function d18_noop_tool!(env; v::Int = 1)\n" *
                       "    return (status = :d18_did_nothing,)\nend\n",
        "surface" => "env_param", "reversible" => false,
        "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
        "body_names" => ["d18_noop_tool!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "d18_noop_tool!",
                                     "args" => Dict{String,Any}("v" => 1))]))
    local r = enact_minted_decision!(env, nothing, _dec(e))
    @test r.registered === true
    @test r.verdict === :admit
    @test length(r.steps) == 1 && r.steps[1].status === :d18_did_nothing
    @test r.world_delta !== nothing            # 🔴 "쟀는데 0" 이지 "못 쟀다" 가 아니다
    @test r.world_delta.closed == 0
    @test r.world_delta.active == 0
    @test r.world_delta.n_edges == 0
    @test r.world_delta.n_binding_changed == 0
    # 🔴 음성 대조. 지문을 못 찍는 env 에서는 **같은 모양의 body** 가 `nothing` 을 낸다 —
    #    이 줄이 없으면 위 네 0 이 "다이제스트가 살아 있다" 의 증거가 못 된다(`world_delta`
    #    로 상수 0-튜플을 돌려주는 구현도 위 넷을 전부 통과한다). `BARE_ENV` 에는
    #    `cache`/`sched`/`active_build_steps` 가 하나도 없다.
    # 🔴 **이름을 바꿔야 한다.** 위 body 를 그대로 재사용하면 등록이
    #    `reject:impl_name_already_minted` 로 먼저 돌아서서(실측) 다이제스트 자리에 아예
    #    도달하지 않는다 — 그러면 `nothing` 은 "지문을 못 찍었다" 가 아니라 "집행 전에
    #    거절됐다" 의 증거가 되어 이 대조가 재려던 것을 못 잰다.
    local e0 = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "d18_noop_bare!",
        "impl_code" => "function d18_noop_bare!(env; v::Int = 1)\n" *
                       "    return (status = :d18_did_nothing,)\nend\n",
        "surface" => "env_param", "reversible" => false,
        "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
        "body_names" => ["d18_noop_bare!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "d18_noop_bare!",
                                     "args" => Dict{String,Any}("v" => 1))]))
    local r0 = enact_minted_decision!(BARE_ENV, nothing, _dec(e0))
    @test r0.registered === true                      # 집행 자리까지 실제로 갔다
    @test r0.verdict === :admit
    @test length(r0.steps) == 1 && r0.steps[1].status === :d18_did_nothing
    @test r0.world_delta === nothing                  # 🔴 그런데 지문은 못 찍었다
end

@testset "(12) 🔴 D16/F2: zone 블록이 선언 타입 변환을 덮어쓰지 않는다" begin
    # 🔴 2026-09-04 fix round 1 (F2). `bind_primitive_args` 의 키워드 루프 **뒤**에 오는
    #    zone 블록이 `kw[:zone_keys]` 를 **무조건** `Vector{Symbol}` 로 갈아 끼웠다.
    #    생성 원시가 `zone_keys::Array{String,1}` 로 주석하면 D16 이 만들어 준
    #    `Vector{String}` 이 그 자리에서 되돌아가고, 호출이
    #    `TypeError: in keyword argument zone_keys, expected Vector{String}, got
    #    Vector{Symbol}` 로 죽는다 — **거절이 아니라 예외**라 `enact_minted!` 의 catch 가
    #    손도 안 댄 세계를 `partial=true → handled=true` 로 적어 폴백을 삼킨다. 그것이
    #    정확히 이 태스크가 없애려던 사건이다.
    CB.reset_minted_table!()
    code = """
    function d16_zone_tool!(env; zone_keys::Array{String,1}=String[])
        return (status = Symbol("zones_", length(zone_keys)),)
    end
    """
    CB.RESTRICTION_ZONES[][:d16zone] = CB.LazySets.Ball2([0.0, 0.0], 1.0)
    try
        @test CB.register_minted_primitive!(name = "d16_zone_tool!", code = code,
            params = Dict{String,Any}("zone_keys" =>
                Dict("type" => "array", "items" => Dict("type" => "string"))),
            surface = "sched", reversible = false) === nothing
        prim = CB.resolve_primitive("d16_zone_tool!")
        @test prim.param_types["zone_keys"] === Vector{String}
        calls = CB.normalize_calls(JSON3.read(
            """[{"primitive":"d16_zone_tool!","args":{"zone_keys":["d16zone"]}}]"""))
        b = CB.bind_primitive_args(prim, (env = :DUMMY, truth = nothing, params = calls[1][2]))
        @test !(b isa String)
        @test b[2].zone_keys isa Vector{String}
        r = Base.invokelatest(getfield(CB, Symbol("d16_zone_tool!")), b[1]...; b[2]...)
        @test r.status === :zones_1
        # 🔴 음성 대조 — 비켜서기가 **살아 있는 존 검사까지** 끄지 않았다. 이 줄이 없으면
        #    zone 블록을 통째로 건너뛰는 구현도 위를 전부 통과한다.
        calls2 = CB.normalize_calls(JSON3.read(
            """[{"primitive":"d16_zone_tool!","args":{"zone_keys":["d16_not_a_live_zone"]}}]"""))
        b2 = CB.bind_primitive_args(prim, (env = :DUMMY, truth = nothing, params = calls2[1][2]))
        @test b2 isa String
        @test startswith(b2, "reject:unknown_zone_key:")
    finally
        delete!(CB.RESTRICTION_ZONES[], :d16zone)
    end
end

@testset "(13) 🔴 D16/F3: 못 읽는 주석은 **거절**이지 예외가 아니다" begin
    # 🔴 2026-09-04 fix round 1 (F3). `Vector{<:AbstractString}` 는
    #    `Expr(:curly, :Vector, Expr(:<:, :AbstractString))` 이라 `_is_type_shape` 가
    #    거짓이다. 초판은 그 키를 **버렸고**, 그러면 JSON3 뷰가 그대로 흘러 호출이
    #    `TypeError` 로 죽는다 — F2 와 같은 `partial=true → handled=true` 삼킴이다.
    #    즉 "키를 조용히 버린다" 는 이 태스크가 고치려던 바로 그 실패를 남기는 선택지다.
    #    그래서 **삼상**으로 만들었다: 키 없음(주석 없음, testset (9)) · `Type`(읽었다) ·
    #    `String`(주석은 있는데 못 읽었다) — 셋째는 값이 실제로 올 때만 거절이 된다.
    CB.reset_minted_table!()
    code = """
    function d16_where_tool!(env; xs::Vector{<:AbstractString}=String[])
        return (status = :ok,)
    end
    """
    @test CB.register_minted_primitive!(name = "d16_where_tool!", code = code,
        params = Dict{String,Any}("xs" =>
            Dict("type" => "array", "items" => Dict("type" => "string"))),
        surface = "sched", reversible = false) === nothing
    prim = CB.resolve_primitive("d16_where_tool!")
    @test haskey(prim.param_types, "xs")            # 🔴 키가 **있다** — (9) 와 다른 상태다
    @test !(prim.param_types["xs"] isa Type)        #    값은 못 읽은 주석의 **원문**이다
    calls = CB.normalize_calls(JSON3.read(
        """[{"primitive":"d16_where_tool!","args":{"xs":["a","b"]}}]"""))
    b = CB.bind_primitive_args(prim, (env = :DUMMY, truth = nothing, params = calls[1][2]))
    @test b isa String
    @test startswith(b, "reject:param_annotation_unreadable:xs:")
end

# =============================================================================
# 유료 런 직전 배선 파동 (Wave A, 2026-09-04) — W1~W6
#
# 🔴 사전등록 결정 6 은 `world_delta` **하나**를 L4 판정으로 쓴다(다른 넷은 구성상 상수거나
#    모델의 자기신고다). 그러므로 유료 런 전에 그 필드에 대해 참이어야 하는 것 셋:
#      · 네 반환 자리 **전부**가 그 필드를 나른다 — 소비자가 `try` **밖**에서 읽는다 (W1)
#      · 그 값이 stdout 만이 아니라 **구조화된 행**으로도 나간다 (W2)
#      · 네 성분이 **전부** 0 이외의 값을 낼 수 있다는 것이 실측돼 있다 (W3)
#    아래 다섯 testset 이 그 셋과 F4·m1·m3·m4·m5 를 잰다.
# =============================================================================

const ENACT_PATH  = normpath(joinpath(@__DIR__, "..", "tools", "monitor", "enact.jl"))
const RENDER_PATH = normpath(joinpath(@__DIR__, "..", "tools", "monitor", "render_demo.jl"))

"""
    _return_site_fieldsets(path, fname) -> Vector{Tuple{Int,Vector{Symbol}}}

`path` 를 **파싱해서**(로드하지 않는다) `fname` 함수 본문의 `return (a = …, b = …)` 자리마다
`(줄번호, 필드 이름 순서)` 를 낸다. 중첩 클로저의 `return` 도 그 함수 본문 안이므로 포함된다
(`_reject_malformed` 가 그 자리다 — 넷 중 하나다).

🔴 **왜 AST 인가.** 이 규약("네 자리가 같은 NamedTuple 을 낸다")은 2026-09-03 리뷰까지
사람이 손으로만 지켰고, 검증자의 변이 M8 이 그것을 실측했다: **넷 중 셋에서 `world_delta` 를
지워도 두 게이트가 전부 초록**이다. 문법적 사실이므로 문법으로 잰다 — 값이 아니라 모양을
재는 것이라 픽스처도 env 도 필요 없고, 라이브에서만 도달하는 자리(조기 `:deferred` — 유료
런에서 **가장 흔한 판**)까지 덮는다.
"""
function _return_site_fieldsets(path::AbstractString, fname::Symbol)
    local top = Meta.parseall(read(path, String); filename = path)
    local fdef = Ref{Any}(nothing)
    function findfn(x)
        fdef[] === nothing || return
        x isa Expr || return
        if x.head === :function && x.args[1] isa Expr &&
           x.args[1].head === :call && x.args[1].args[1] === fname
            fdef[] = x; return
        end
        for a in x.args; findfn(a); end
    end
    findfn(top)
    fdef[] === nothing && error("AST 게이트: $(fname) 를 $(path) 에서 못 찾았다")
    local res = Vector{Tuple{Int,Vector{Symbol}}}()
    local cur = Ref(0)
    function walk(x)
        if x isa LineNumberNode; cur[] = x.line; return; end
        x isa Expr || return
        if x.head === :return && length(x.args) == 1 &&
           x.args[1] isa Expr && x.args[1].head === :tuple
            local ks = Symbol[]; local ok = true
            for e in x.args[1].args
                if e isa Expr && (e.head === :(=) || e.head === :kw) && e.args[1] isa Symbol
                    push!(ks, e.args[1])
                else
                    ok = false
                end
            end
            ok && !isempty(ks) && push!(res, (cur[], ks))
        end
        for a in x.args; walk(a); end
    end
    walk(fdef[])
    return res
end

@testset "(14) 🔴 W1: 반환 자리 넷의 필드 집합을 **기계가** 지킨다" begin
    local sites = _return_site_fieldsets(ENACT_PATH, :enact_minted_decision!)
    println("    return sites = ", length(sites), " → ",
            join([string("~", ln, "(n=", length(ks), ")") for (ln, ks) in sites], " "))
    # 자리 넷 = 조기 `:deferred` · `_reject_malformed` 클로저 · 성공 · 바깥 `catch`.
    @test length(sites) == 4
    local first_keys = sites[1][2]
    for (ln, ks) in sites
        # 🔴 집합만이 아니라 **순서**까지 같다 — 파일의 규약이 그렇고, 순서가 갈리면 diff 를
        #    읽는 사람이 필드 하나가 빠진 것과 옮겨진 것을 못 가른다.
        @test ks == first_keys
        # 🔴 소비자가 `enact_minted_decision!` 의 `try` **밖**에서 읽는 둘. 여기가 비면
        #    `type NamedTuple has no field …` 가 `policy_producer` 안에서 터져 렌더가 선다.
        @test :world_delta in ks
        @test :handled in ks
        # 🔴 D5(Wave D): L3 도 네 자리 전부에 있어야 한다 — L4 와 같은 이유로
        #    소비자가 `try` 밖에서 읽는다.
        @test :interface_calls in ks
    end

    # ---- 🔴 음성 대조: 이 게이트가 정말로 빨개질 수 있는가 (변이 M8 을 in-test 로) ----------
    # 생산 소스는 안 건드린다 — 전부 `mktempdir()` 안의 사본이다
    # (`test/synth_lane_keys_survive.jl` 의 관용구와 같다).
    mktempdir() do dir
        local lines = split(read(ENACT_PATH, String), "\n")
        # ⚠️ D5(Wave D) 뒤로 `world_delta` 는 튜플의 **마지막 필드가 아니다** —
        #    `interface_calls` 가 그 뒤에 붙었다. 그래서 변이 지점의 모양이 `…)` 가 아니라
        #    `…,` 다. 이 줄이 낡으면 `length(idx) == 4` 가 먼저 빨개진다(조용히 안 샌다).
        local idx = findall(l -> occursin(r"^\s*world_delta = world_delta,\s*$", l), lines)
        @test length(idx) == 4                      # 변이 지점을 실제로 넷 다 찾았다
        lines[idx[1]] = replace(lines[idx[1]], "world_delta = world_delta," => "")
        local p = joinpath(dir, "enact_dropped_field.jl")
        write(p, join(lines, "\n"))
        local mut = _return_site_fieldsets(p, :enact_minted_decision!)
        @test length(mut) == 4                       # 자리 수는 그대로 — 필드만 빠졌다
        @test !all(ks == mut[1][2] for (_, ks) in mut)          # 동일성이 깨진다
        @test !all(:world_delta in ks for (_, ks) in mut)       # 그리고 그 필드가 빠진 것이다
    end
end

@testset "(15) 🔴 W3: active·n_edges·n_binding_changed 양성 대조" begin
    # 🔴 F3(2026-09-03 리뷰). `world_delta` 의 네 성분 중 **`closed` 만** 움직이는 것이
    #    관측된 적이 있다. 그러면 라이브의 `active=0 n_edges=0` 을 "안 바뀌었다" 로 읽을
    #    근거가 없다 — "이 축은 원래 안 움직인다"(=배선이 죽었다) 와 구별이 안 된다.
    #    결정 6 이 `world_delta` **만** 본다고 적었으므로 그 구별이 곧 유료 런의 결론이다.
    # ⚠️ 함정(검증자 실측): `Graphs.add_vertex!(sched.graph)` 로 정점만 늘리면
    #    `assignment_binding` 이 `get_node` 에서 던져 **지문이 통째로 `nothing`** 이 된다.
    #    반드시 `add_node!(sched, ScheduleNode(node_id(n), n))` 를 쓸 것.
    # ⚠️ `surface` 는 (10)(11) 과 같은 이유로 `env_param` 이다 — 아래 `resolve` 단언이
    #    이 판이 **body 단독** 체제라는 것을 재유도한다(W4/F4).
    CB.reset_minted_table!()
    local env = live_cache_env()
    local e = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "d18_move_world!",
        "impl_code" => "function d18_move_world!(env; v::Int = 1)\n" *
                       "    push!(env.active_build_steps, RobotID(1))\n" *
                       "    push!(env.active_build_steps, RobotID(2))\n" *
                       "    a = RobotStart(RobotNode(RobotID(1), GeomNode(nothing)))\n" *
                       "    b = RobotGo(RobotNode(RobotID(2), GeomNode(nothing)))\n" *
                       "    add_node!(env.sched, ScheduleNode(node_id(a), a))\n" *
                       "    add_node!(env.sched, ScheduleNode(node_id(b), b))\n" *
                       "    add_edge!(env.sched, node_id(a), node_id(b))\n" *
                       "    return (status = :d18_moved,)\nend\n",
        "surface" => "env_param", "reversible" => false,
        "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
        "body_names" => ["d18_move_world!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "d18_move_world!",
                                     "args" => Dict{String,Any}("v" => 1))]))
    local r = enact_minted_decision!(env, nothing, _dec(e))
    # 전제 — 이 판이 정말 생성 경로이고 body 가 끝까지 돌았는가.
    @test r.registered === true
    @test r.verdict === :admit
    @test length(r.steps) == 1 && r.steps[1].status === :d18_moved
    # 🔴 재는 것 — 세 축이 **각각** 0 이 아닌 값을 낸다.
    @test r.world_delta !== nothing
    @test r.world_delta.active == 2
    @test r.world_delta.n_edges == 1
    @test r.world_delta.n_binding_changed == 2
    # 🔴 음성 대조: 넷이 뭉뚱그려 움직이는 것이 아니다. body 는 `closed_set` 을 안 건드렸고
    #    그 축은 0 이다 — 이 줄이 없으면 위 셋은 "지문이 아무 숫자나 낸다" 와 구별이 안 된다.
    @test r.world_delta.closed == 0
    # 🔴 W4/F4: 이 차분에 하네스의 공통 MILP 재풀이가 안 섞였다는 것을 재유도한다.
    @test r.resolve === :not_needed_surface
    @test _delta_scope(r.resolve) == "body_only"
end

@testset "(16) 🔴 W2: world_delta 가 **구조화된 행**으로도 나간다" begin
    # 🔴 F1(2026-09-03 리뷰). `record_decision!`(`render_demo.jl`)은 집행 **앞**에서 결정 행을
    #    닫고, 집행 뒤에는 `_m.handled` 하나만 읽혔다 — `world_delta` 는 stdout 으로만 나갔다.
    #    (stdout 채점은 실제로 가능하다: `println` 이라 `global_logger(…, Logging.Warn)` 를
    #    통과하는 것을 검증자가 짝지은 대조로 확인했다. 즉 write-only 도장은 아니었다.
    #    그래도 스윕 규모의 집계는 행이 있어야 한다.)
    # 🔴 패턴은 `monitor_record_verification!`(`src/monitor/monitor.jl`)의 **제자리 변이**
    #    그대로다 — `MONITOR_RESPEC[]` 은 `monitor_emit!` 때 직렬화되는 살아 있는 Dict 다.
    #    두 번째 패턴을 만들지 않는다(진실원 하나).
    local saved = CB.MONITOR_RESPEC[]
    try
        local row = Dict{String,Any}()
        CB.MONITOR_RESPEC[] = row
        # ---- 삼상이 **행 안에서** 살아남는가 ------------------------------------------------
        record_world_delta!((world_delta = nothing,))
        @test haskey(row, "world_delta")            # 키는 언제나 있다(부재 = 이 코드 이전 세대)
        @test row["world_delta"] === nothing        # 🔴 "못 쟀다" 는 0 도 {} 도 아니다
        @test occursin("\"world_delta\":null", JSON3.write(row))   # 직렬화까지 살아남는다
        record_world_delta!((world_delta = (closed = 0, active = 0, n_edges = 0,
                                            n_binding_changed = 0, n_weights_changed = 0),))
        @test row["world_delta"] isa AbstractDict   # 🔴 "쟀는데 0" 은 **다른 관측**이다
        @test row["world_delta"]["closed"] == 0
        # ⚠️ 2026-09-04 (Task 2): 넷 → **다섯**. `n_weights_changed` 가 다섯째 축이다.
        #    2026-09-05 (B1): 다섯 → **여섯**. `n_staging_moved` 가 여섯째(기하) 축이다.
        #    단언을 지우지 않고 **옮긴다** — 키 수를 안 세면 축이 조용히 빠져도 안 보인다.
        @test length(row["world_delta"]) == 6
        @test row["world_delta"]["n_weights_changed"] == 0
        # 🔴 위 튜플은 **다섯 필드**다(여섯째 축 이전 세대의 모양). 그 판의 정직한 값은
        #    키가 있고 값이 `null` 이다 — 행이 통째로 죽지도(계측이 기록을 죽인다), 0 을
        #    참칭하지도 않는다.
        @test haskey(row["world_delta"], "n_staging_moved")
        @test row["world_delta"]["n_staging_moved"] === nothing
        @test occursin("\"n_staging_moved\":null", JSON3.write(row))
        record_world_delta!((world_delta = (closed = 1, active = 2, n_edges = 3,
                                            n_binding_changed = 4, n_weights_changed = 5),))
        @test row["world_delta"]["active"] == 2
        @test row["world_delta"]["n_binding_changed"] == 4
        @test row["world_delta"]["n_weights_changed"] == 5
        # ---- 🔴 안 던진다. 이 호출은 `enact_minted_decision!` 의 `try` **밖**이다 ----------
        record_world_delta!((;))                    # 필드가 아예 없는 반환(구세대 집행부)
        @test row["world_delta"]["active"] == 2     # 직전 값이 그대로 — 덮어쓰지도 죽지도 않았다
        CB.MONITOR_RESPEC[] = nothing               # 결정 행이 아예 없는 판(레인 미개시)
        @test record_world_delta!((world_delta = nothing,)) === nothing
    finally
        CB.MONITOR_RESPEC[] = saved
    end
    # ---- 생산 경로가 실제로 그 함수를 부르는가, 그리고 **조기 반환보다 먼저** 부르는가 ------
    # 🔴 순서가 하중이다: `_m.handled` 가 참인 판(생성 body 의 지배적인 판)에서 뒤에 두면
    #    행에 아무것도 안 실린다.
    local rd = read(RENDER_PATH, String)
    local i_call = findfirst("record_world_delta!(_m)", rd)
    local i_ret  = findfirst("_m.handled && return nothing", rd)
    @test i_call !== nothing
    @test i_ret !== nothing
    @test first(i_call) < first(i_ret)
end

@testset "(17) 🔴 W4/m3/m4: delta 의 **범위**가 읽히고, 로그 문구의 진실원이 하나다" begin
    # 🔴 F4. `_issue_resume!`/`_resolve_if_needed!` 는 `CB.enact_minted!` **안**에서 돈다.
    #    그래서 `surface ∈ {"sched","milp"}` 인 판의 사후 지문에는 하네스의 공통 MILP
    #    재풀이가 한 편집이 들어온다 — 그리고 `resolve_assignments!` 의 `n_reassigned` 과
    #    `world_delta.n_binding_changed` 는 **같은 `assignment_binding`** 에서 나온다.
    #    집행을 바꾸지 않는다. 이미 손에 있는 `r.resolve` 로 그 판독을 명시할 뿐이다.
    @test _delta_scope(:not_needed_surface) == "body_only"
    @test _delta_scope(:resolved) == "body+harness_resolve"
    # ⚠️ 실패 셋과 `:none` 은 **모른다**로 남긴다 — "body 단독" 으로 넓히면 못 쟀다가
    #    측정처럼 보인다.
    @test _delta_scope(:none) == "unknown"
    @test _delta_scope(:threw) == "unknown"
    @test _delta_scope(nothing) == "unknown"

    # ---- m3·m4: 네 로그 자리가 **한 벌**의 문구를 쓴다 ------------------------------------
    # m3 — 조기 두 자리가 값을 안 읽고 `n/a(not measured)` 를 **손으로** 적고 있었다. 오늘은
    #      참이지만 거절 자리가 지문 뒤로 옮겨지는 순간 그 리터럴이 조용히 거짓말한다.
    # m4 — 성공 줄에는 하한 각주가 붙고 catch 줄에는 없었다. 로그를 정규식으로 읽는 소비자가
    #      두 모양을 따로 다뤄야 했다.
    # ⚠️ 이 단언은 **어휘적**이다(소스 문자열을 센다). 그래서 잡는 것은 "리터럴이 두 벌
    #    생겼다" 뿐이고, 포맷터가 잘못 계산하는 것은 위 (10)(11)(15) 가 잡는다.
    local src = read(ENACT_PATH, String)
    # ⚠️ **백틱 인용만** 뺀다(주석·docstring 에서 이 문구를 인용하는 것은 사본이 아니라
    #    설명이다). 🔴 처음엔 `"n/a(not measured)"` 를 따옴표까지 붙여 셌는데, 그러면
    #    `" world_delta=n/a(not measured)"` 처럼 **문자열 안에 박힌** 사본을 놓친다 —
    #    그리고 그것이 정확히 m3 이 고친 옛 코드의 모양이었다(2026-09-04 변이로 실측:
    #    그 판의 게이트는 초록이었다).
    @test length(collect(eachmatch(r"(?<!`)n/a\(not measured\)", src))) == 1
    @test length(collect(eachmatch(r"n_binding_changed 는 하한이다", src))) == 1
    @test _world_delta_str(nothing) == "n/a(not measured)"
    # ⚠️ 2026-09-04 (Task 2): 다섯째 항 `n_weights_changed` 가 붙었다. 단언은 **이동**이다 —
    #    네 항을 지우지 않고 다섯 항을 그대로 못박는다.
    local s = _world_delta_str((closed = 1, active = 2, n_edges = 3,
                                n_binding_changed = 4, n_weights_changed = 5))
    @test occursin("closed=1 active=2 n_edges=3 n_binding_changed=4 n_weights_changed=5", s)
    @test occursin("하한", s)     # 🔴 하한 각주가 **네 자리 전부**에 붙는다(m4)
end

@testset "(18) 🔴 m1/m5: CB.Graphs 가 하중을 지고, _world_delta 는 안 던진다" begin
    # ---- m1. 검증자의 변이 M3: 맨 `Graphs.ne` 로 되돌려도 **두 게이트가 전부 초록**이었다.
    #      `CB.` 를 붙이는 판단은 옳았는데 그 위험을 잡는 시험이 레포에 0개였다.
    #      (그리고 그 자리의 docstring 이 든 예가 반대로 적혀 있었다 — `minted_end_to_end.jl`
    #      은 `policy.jl` 경유로 `Graphs` 를 **갖는다**. 진짜 예는 `test_minted_wiring.jl` 등
    #      넷이다. 그래서 이 게이트는 예를 인용하는 대신 **그 모양의 모듈을 만들어** 잰다.)
    local env = live_cache_env()
    local m = Module(:D18NoGraphsProbe)
    Core.eval(m, :(const CB = $(CB)))
    Base.include(m, ENACT_PATH)
    # 🔴 음성 대조가 공허하지 않다는 증거: 이 모듈에 `Graphs` 는 **실제로 없다**.
    @test Core.eval(m, :(isdefined(@__MODULE__, :Graphs))) === false
    @test Base.invokelatest(Core.eval(m, :(_world_digest)), env) !== nothing
    # 🔴 그리고 맨 이름으로 되돌리면 지문이 **통째로 꺼진다**(변이 M3 을 in-test 로).
    mktempdir() do dir
        local p = joinpath(dir, "enact_bare_graphs.jl")
        write(p, replace(read(ENACT_PATH, String), "CB.Graphs.ne" => "Graphs.ne"))
        local m2 = Module(:D18BareGraphsProbe)
        Core.eval(m2, :(const CB = $(CB)))
        Base.include(m2, p)
        @test Base.invokelatest(Core.eval(m2, :(_world_digest)), env) === nothing
    end

    # ---- m5. `_world_delta` 에는 `try`/`catch` 가 없었다. 오늘 도달 불가지만(`assignment_binding`
    #      이 `Dict{Int,Int}` 고정) 던지면 **body 가 이미 세계를 편집한 뒤**에 바깥 catch 가
    #      그것을 삼켜 `verdict=:reject reason="… threw"` 로 기록된다 — `_world_digest` 가
    #      막겠다고 적은 사고의 나머지 반쪽이다.
    # 🔴 2026-09-04 실측 — 리뷰의 처방(`try`/`catch`)만으로는 **반쪽**이다. 두 방향이 서로
    #    다른 사고를 낸다:
    #      · `_world_delta(ok, bad)` → 던진다(사후 지문의 `binding` 을 순회하다 죽는다).
    #        `try`/`catch` 가 그것을 `nothing`("못 쟀다")으로 바꾼다.
    #      · `_world_delta(bad, ok)` → **안 던진다.** `String` 이 `get`·`keys` 를 둘 다 갖고
    #        있어 두 루프가 조용히 돌고 `n_binding_changed = 10`(= 문자열 길이)이 나온다.
    #        `try`/`catch` 로는 절대 못 잡는다 — 그리고 이쪽이 더 나쁘다: 예외는 "못 쟀다"
    #        가 되는데 이 거짓 숫자는 **"쟀다"를 참칭한다**(삼상 규약이 막으려는 것 그 자체).
    #    그래서 모양 가드가 `try` **앞**에 있다.
    # ⚠️ 2026-09-04 (Task 2): 지문에 다섯째 축 `weights` 가 생겼다. 픽스처를 **옮긴다** —
    #    같은 명제를 다섯 필드 모양으로 다시 적는다(약화가 아니다).
    local ok  = (closed = 0, active = 0, n_edges = 0, binding = Dict{Int,Int}(1 => 1),
                 weights = Dict{Int,Float64}(1 => 1.0))
    local bad = (closed = 0, active = 0, n_edges = 0, binding = "not a dict",
                 weights = Dict{Int,Float64}(1 => 1.0))
    @test _world_delta(ok, bad) === nothing
    @test _world_delta(bad, ok) === nothing
    # 🔴 비-0 대조: 이 함수가 여전히 **잰다**(항진적으로 nothing 을 내는 것이 아니다).
    local moved = (closed = 1, active = 0, n_edges = 0, binding = Dict{Int,Int}(1 => 2),
                   weights = Dict{Int,Float64}(1 => 1.0))
    # ⚠️ 2026-09-05 (B1): 여섯째 자리 `n_staging_moved`. 위 두 지문은 **다섯 필드**라
    #    (여섯째 축 이전 세대의 모양) 이 축은 `nothing`("못 쟀다")이고, 나머지 다섯은
    #    **수인 채로 산다** — 그것이 이 축을 전부-아니면-무 밖에 둔 이유 그 자체다.
    @test _world_delta(ok, moved) == (closed = 1, active = 0, n_edges = 0,
                                      n_binding_changed = 1, n_weights_changed = 0,
                                      n_staging_moved = nothing)
end

@testset "(19) 🔴 W5: /rewrite 의 spec 이 더 이상 **구조적으로** 비지 않는다" begin
    # 🔴 Task 9 실측: 가짜 `/rewrite` 서버가 받은 payload 의 `spec` 이 `''` 였다 —
    #    **생산 경로의 모든 판에서**. 원인은 모델이 아니라 배선이었다: `mechanism` 은
    #    파이썬 기록에 있었는데(`synthesize.py` 의 `_SPEC_FIELDS`) `SYNTH_LANE_KEYS` 에
    #    없어 `_synth_view` 가 안 실었다. 그 상태의 유료 런은 "명세 없이 고치라는 요청에
    #    agent-3 이 실패한 비율" 을 재게 되고, D17 이 재려는 것은 그 수치가 아니다.
    # 🔴 이름 축의 게이트는 `test/synth_lane_keys_survive.jl` 이 소유한다(파이썬 AST 대조
    #    포함). 여기서 재는 것은 **값이 집행부의 그 읽기 자리까지 실제로 도착하는가** 다.
    local sl = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "w5_probe!", "wrote" => true,
        "mechanism" => "release the pending assignments, then re-solve"))
    @test _synth_lane_field(sl, "mechanism") == "release the pending assignments, then re-solve"
    @test !isempty(something(_synth_lane_field(sl, "mechanism"), ""))
    # 🔴 음성 대조 — 기전이 없는 판은 **여전히** 비어 있고, 이제 그것은 배선이 아니라
    #    사건에 대한 사실이다(design 단계 전에 빠져나온 이른 탈출). 이 줄이 없으면 위 둘은
    #    "이 필드는 언제나 값이 있다" 라는 항진명제와 구별이 안 된다.
    local sl0 = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => false, "error" => "no_missing_primitive"))
    @test _synth_lane_field(sl0, "mechanism") === nothing
end


# =============================================================================
# (20) 🔴 D1(Critical) — 되먹임이 **이름을 바꾸면** 고친 body 가 실제로 불리는가.
#
# 결함(리뷰 C1, 실측): 되먹임 성공 시 `sl` 에 쓰는 키는 다섯이었다 —
# `impl_name`·`impl_code`·`params`·`calls`·`surface`. 그런데 `enact_minted!` 이
# **실행할 원시를 고르는 자리**는 그 다섯이 아니라 `body_names` 다. 그래서 고친 body 가
# 등록되고(`Core.eval` 까지 돌고) **영영 안 불렸다**:
#   `verdict=reject registered=true impl_rejected_why=nothing reason="unknown primitive:
#    rw_bad — 알파벳 밖이다"`
#
# 🔴 왜 Critical 인가. 이름을 **반드시** 바꿔야만 고쳐지는 거절 가족이 있고, 그 가족이
#    하필 D6 신호 그 자체다(`impl_name_must_end_with_bang` · `_not_an_identifier` ·
#    `_already_minted` · `_exists_shown` · 🔴 `_exists_withheld`(감춘 능력을 스스로 다시
#    유도했다는 유일한 자기신고) · `_exists_imported`). 그 전부에서 되먹임은 **성공하는데**
#    기록은 "모델이 어휘 밖 이름을 냈다" 로 남는다 — 우리 배선의 실패를 agent-3 의 실패로
#    적는 것이고, 문구가 하필 "알파벳 밖이다" 다.
#
# 이 절은 **A/B 대조**다. 유일한 차이는 고친 body 의 이름이 바뀌는가이고, 두 판이 같은
# 결과(`:admit`, 그 body 가 실제로 불림)를 내야 한다. D1 이전에는 (20a) 만 빨갛다.
# =============================================================================

"등록이 **거절되는** 합성 레인 한 벌. `why` 가 이름 축이면 되먹임이 개명해야만 고친다."
_rw_lane(nm, code) = _lane(Dict{String,Any}(
    "synthesis_event" => true, "ran" => true, "error" => nothing,
    "tool_name" => "T", "impl_name" => nm, "impl_code" => code,
    "surface" => "env_param", "reversible" => false,
    "params" => Dict{String,Any}("note" => Dict{String,Any}("type" => "string")),
    "body_names" => [nm], "wrote" => true, "mechanism" => "fix it",
    "calls" => [Dict{String,Any}("primitive" => nm,
                                 "args" => Dict{String,Any}("note" => "hi"))]))

@testset "(20) 🔴 D1: 되먹임이 고친 body 가 실제로 불린다 (이름 A/B 대조)" begin

@testset "(20a) 🔴 이름이 **바뀌는** 판 — C1 그 자체" begin
    CB.reset_minted_table!()
    _RW_MODE[] = :rename
    _RW_HITS[] = 0
    # 이름 축의 거절: `!` 로 안 끝난다 ⟹ 고치려면 **반드시** 이름이 바뀐다.
    local sl = _rw_lane("rw_bad",
        "function rw_bad(env; note = \"x\")\n    return (status = :nope,)\nend\n")
    local m = enact_minted_decision!(live_cache_env(), nothing, _dec(sl))
    @test _RW_HITS[] == 1                       # 왕복은 정확히 한 번(구조로)
    @test m.registered === true                 # 고친 body 는 등록됐다
    @test isdefined(CB, :rw_fixed!)             # 그리고 Core.eval 까지 됐다
    # 🔴 여기가 D1 이다. 고치기 전에는 `:reject` 이고 사유가
    #    "unknown primitive: rw_bad — 알파벳 밖이다" 였다.
    @test m.verdict === :admit
    @test !occursin("unknown primitive", m.reason)
    @test length(m.steps) == 1
    @test m.steps[1].name == "rw_fixed!"        # **고친** 이름이 불렸다
    @test m.steps[1].status !== nothing
    @test m.args_from === :calls
    @test m.n_calls == 1
    # 🔴 `body_names` 가 갱신됐다는 것을 자리에서 직접 잰다(사후 상태가 진실원).
    @test String[String(x) for x in sl["body_names"]] == ["rw_fixed!"]
    # 🔴 되먹임은 **원래 사유**를 실어 보냈다 — 이 채널의 존재 이유(D17).
    @test _RW_LAST[] !== nothing
    @test occursin("impl_name_must_end_with_bang", String(_RW_LAST[][:impl_rejected_why]))
    # ⚠️ 전선 이름은 `impl_code` 다(`_rewrite_once` 의 payload). 파이썬 시그니처의
    #    입력 이름 `rejected_impl_code` 는 `dspy_service.py` 가 그 값에 붙이는 이름이다.
    @test String(_RW_LAST[][:impl_code]) != ""
    @test String(_RW_LAST[][:spec]) == "fix it"     # W5 의 값이 실제로 실린다
end

@testset "(20b) 대조(A2): 이름을 **유지**하는 판 — D1 이전에도 통과하던 유일한 갈래" begin
    CB.reset_minted_table!()
    _RW_MODE[] = :keep
    _RW_HITS[] = 0
    # 이름 축이 아닌 거절: 최상위 정의가 둘이다 ⟹ 이름을 안 바꾸고 고칠 수 있다.
    local sl = _rw_lane("rw_keep!",
        "function rw_keep!(env; note = \"x\")\n    return (status = :nope,)\nend\n" *
        "function rw_helper(x)\n    return x\nend\n")
    local m = enact_minted_decision!(live_cache_env(), nothing, _dec(sl))
    @test _RW_HITS[] == 1
    @test m.registered === true
    @test m.verdict === :admit
    @test length(m.steps) == 1 && m.steps[1].name == "rw_keep!"
    # 🔴 이 대조가 비어 있지 않다는 증거: (20a) 와 **같은 env·같은 경로**인데 (20a) 만
    #    고치기 전에 빨갰다. 즉 (20a) 의 실패는 env 의 성질이 아니라 배선 결함이다.
    @test String[String(x) for x in sl["body_names"]] == ["rw_keep!"]
end

@testset "(20c) 🔴 D3: 되먹임 채널을 지우면 이 게이트가 빨개진다 (변이 대조)" begin
    # 🔴 리뷰 I1: `enact.jl` 의 D17 블록 27줄을 통째로 지워도 이 파일이 **대조와 동일**했다
    #    (Pass 수까지). 즉 채널이 무방비였다. 이 절은 그 변이를 **시험 안에서** 실행한다 —
    #    생산 소스는 안 건드리고 `mktempdir()` 사본만 태운다((14) 의 관용구와 같다).
    local src = read(ENACT_PATH, String)
    # 변이 지점: 되먹임 성공 후 `body_names` 를 갱신하는 줄(D1)을 지운다.
    @test occursin("sl[\"body_names\"] = [fx.impl_name]", src)
    mktempdir() do dir
        local p = joinpath(dir, "enact_no_body_names.jl")
        write(p, replace(src, "sl[\"body_names\"] = [fx.impl_name]" => "", count = 1))
        @test !occursin("sl[\"body_names\"] = [fx.impl_name]", read(p, String))
        # 사본을 **별도 모듈**에 include 해서 생산 정의를 덮지 않는다.
        local M = Module(:EnactMutant)
        Core.eval(M, :(using Test; using ConstructionBots; import JSON3; import HTTP))
        Core.eval(M, :(const CB = ConstructionBots))
        Core.eval(M, :(const DSPY_URL = $(DSPY_URL)))
        Base.include(M, p)
        CB.reset_minted_table!()
        _RW_MODE[] = :rename_mut
        _RW_HITS[] = 0
        local sl = _rw_lane("rw_mut",
            "function rw_mut(env; note = \"x\")\n    return (status = :nope,)\nend\n")
        local m = Base.invokelatest(getfield(M, :enact_minted_decision!),
                                    live_cache_env(), nothing, _dec(sl))
        @test _RW_HITS[] == 1
        @test m.registered === true            # 등록은 됐는데
        @test m.verdict === :reject            # 🔴 아무도 안 불렀다
        @test occursin("unknown primitive", m.reason)
        @test occursin("rw_mut", m.reason)     # 그리고 **옛** 이름을 탓한다
    end
    _RW_MODE[] = :off
end

end


# =============================================================================
# (21) 🔴 D4 — 재등록 자리의 가드 둘. 본 경로에는 있고 되먹임 경로에는 없었다.
#
# (a) `surface` 타입 가드. 본 경로는 `surf_raw isa AbstractString` 을 먼저 보는데
#     되먹임 경로는 `String(something(fx.surface, "unknown"))` 을 가드 없이 불렀다.
#     실측(리뷰 I3): `surface: 7` → `MethodError: no method matching String(::Int64)` →
#     바깥 `catch` → `verdict=reject registered=nothing impl_rejected_why=nothing`.
#     🔴 대가 셋: 헌장의 "예외가 아니라 거절" 이 깨지고 · **이미 측정돼 있던 첫 거절
#     사유가 사라지고**(삼상이 "못 쟀다" 로 붕괴) · 세계를 확실히 안 건드렸는데
#     `world_maybe_dirty=true` 다.
# (b) `params_not_an_object` 사전 가드. 없으면 같은 결함이 시도 1 과 시도 2 에서
#     **다른 사유 이름**을 낸다(`params_not_an_object:String` vs
#     `params_keys_not_strings:Int64`) — D17 이 재려는 것이 정확히 "되먹임이 무엇을
#     고쳤고 무엇을 못 고쳤나" 의 **사유 히스토그램**이라, 어휘가 갈리면 그 표가 거짓이 된다.
#
# ⚠️ 오늘 이 둘이 도달 불가한 이유는 파이썬 쪽 한 겹뿐이다(`RewriteToolImpl.surface: str` ·
#    `params_object` 정규화). 본 경로가 같은 자리를 굳이 막고 있는데 이쪽만 안 막는 것은
#    비대칭이고, 이 파일이 그 비대칭을 없앤다.
# =============================================================================
@testset "(21) 🔴 D4: 되먹임 payload 도 본 경로와 같은 사유로 거절된다" begin

@testset "(21a) surface 가 문자열이 아니면 **예외가 아니라 거절**이다" begin
    CB.reset_minted_table!()
    _RW_MODE[] = :bad_surface
    _RW_HITS[] = 0
    local sl = _rw_lane("rw_surf",
        "function rw_surf(env; note = \"x\")\n    return (status = :nope,)\nend\n")
    local m = enact_minted_decision!(live_cache_env(), nothing, _dec(sl))
    @test _RW_HITS[] == 1
    @test m.verdict === :reject
    # 🔴 예외로 새면 이 셋이 전부 반대로 나온다(nothing · nothing · true).
    @test m.registered === false
    @test m.impl_rejected_why !== nothing
    @test m.impl_rejected_why == "reject:surface_not_a_string:Int64"
    @test m.world_maybe_dirty === false
    @test !occursin("threw", m.reason)
    # 🔴 갱신 **전에** 거절한다 — 못 쓸 값이 `sl` 에 남지 않는다.
    @test sl["surface"] == "env_param"
    @test sl["impl_name"] == "rw_surf"
    @test !isdefined(CB, :rw_surf!)
end

@testset "(21b) 날것 params 는 본 경로와 **같은 이름**의 사유를 낸다" begin
    CB.reset_minted_table!()
    _RW_MODE[] = :bad_params
    _RW_HITS[] = 0
    local sl = _rw_lane("rw_praw",
        "function rw_praw(env; note = \"x\")\n    return (status = :nope,)\nend\n")
    local m = enact_minted_decision!(live_cache_env(), nothing, _dec(sl))
    @test _RW_HITS[] == 1
    @test m.verdict === :reject
    @test m.registered === false
    # 🔴 히스토그램 계약: 시도 1 과 시도 2 가 같은 결함에 **같은 어휘**를 쓴다.
    @test m.impl_rejected_why == "reject:params_not_an_object:String"
    @test !occursin("params_keys_not_strings", m.impl_rejected_why)
    @test sl["params"] isa AbstractDict          # 못 쓸 값이 안 실렸다
    _RW_MODE[] = :off
end

@testset "(21c) 🔴 변이 대조: 가드 둘을 지우면 이 게이트가 빨개진다" begin
    # 생산 소스는 안 건드린다 — `mktempdir()` 사본만 태운다((14)(20c) 의 관용구).
    local src = read(ENACT_PATH, String)
    local marker_s = "reject:surface_not_a_string:\$(typeof(surf2))"
    local marker_p = "reject:params_not_an_object:\$(typeof(praw2))"
    @test occursin(marker_s, src)
    @test occursin(marker_p, src)
    mktempdir() do dir
        local q = joinpath(dir, "enact_no_guards.jl")
        # 가드 둘의 `||` 반환줄만 항진으로 바꾼다(다른 줄은 안 건드린다).
        local mut = replace(src,
            "(surf2 === nothing || surf2 isa AbstractString) ||" =>
                "(surf2 === nothing || true) ||",
            "(praw2 === nothing || praw2 isa AbstractDict) ||" =>
                "(praw2 === nothing || true) ||")
        @test !occursin(marker_s * "\")", mut) || true   # 문자열 자체는 남는다(도달 불가일 뿐)
        write(q, mut)
        local M = Module(:EnactNoGuards)
        Core.eval(M, :(using Test; using ConstructionBots; import JSON3; import HTTP))
        Core.eval(M, :(const CB = ConstructionBots))
        Core.eval(M, :(const DSPY_URL = $(DSPY_URL)))
        Base.include(M, q)
        CB.reset_minted_table!()
        _RW_MODE[] = :bad_surface
        local sl = _rw_lane("rw_surf2",
            "function rw_surf2(env; note = \"x\")\n    return (status = :nope,)\nend\n")
        local m = Base.invokelatest(getfield(M, :enact_minted_decision!),
                                    live_cache_env(), nothing, _dec(sl))
        # 🔴 가드가 없으면 예외로 샌다: 삼상이 "못 쟀다" 로 붕괴한다.
        @test m.registered === nothing
        @test m.impl_rejected_why === nothing
        @test occursin("threw", m.reason)
        _RW_MODE[] = :off
    end
end

end


# =============================================================================
# (22) 🔴 D7 — `_world_digest` 도 **잘못된 타입에서 수를 지어내면 안 된다**.
#
# Wave A 자체 발견 1 과 **같은 부류**다: `_world_delta(bad, ok)` 가 `binding = "not a dict"`
# 에서 안 던지고 `n_binding_changed = 10`(문자열의 길이)을 조용히 돌려줬다. Wave A 는
# `try` **앞에** 모양 가드를 두어 그것을 닫았다. 검증자가 실측한 것은 그 가드의 **위쪽 짝**이
# 아직 열려 있다는 것이다:
#   `closed_set = "abcdefghij"` → `closed = 10` · `active_build_steps = "xyz"` → `active = 3`
# 둘 다 안 던진다. 🔴 예외라면 `catch` 가 `nothing`("못 쟀다")으로 바꿔 주는데, 이 수들은
# **"쟀다" 를 참칭한다** — 그리고 여기가 더 나쁘다: `_world_digest` 의 docstring 이 임의의
# env 모양을 **의도된 입력**이라고 적으므로, 읽는 사람에게 그 수가 허구라는 신호가 없다.
#
# ⚠️ "진짜 `PlannerEnv` 로는 도달 불가" 는 근거가 못 된다 — Wave A 가 `_world_delta` 에서
#    바로 그 논거를 불충분하다고 판정하고 가드를 넣었다. 같은 기준을 여기 적용한다.
#    생산 타입은 둘 다 `Set` 이다(`essential_tg_coponents.jl` 의 `closed_set::Set{Int}` ·
#    `route_planning.jl` 의 `active_build_steps::Set{AbstractID}`).
# =============================================================================
@testset "(22) 🔴 D7: 잘못된 타입의 세계는 수가 아니라 nothing 이다" begin
    local ok = live_cache_env()
    # 🔴 양성 대조 먼저 — 0 을 비-0 과 짝지어 읽는다. 진짜 모양에서는 지문이 **나온다**.
    local d_ok = _world_digest(ok)
    @test d_ok !== nothing
    @test d_ok.closed == 0 && d_ok.active == 0

    # (a) `closed_set` 이 문자열 — 실측된 거짓 측정값 `closed = 10`.
    local bad_c = (cache = (closed_set = "abcdefghij",), sched = ok.sched,
                   active_build_steps = ok.active_build_steps)
    @test _world_digest(bad_c) === nothing

    # (b) `active_build_steps` 가 문자열 — 실측된 거짓 측정값 `active = 3`.
    local bad_a = (cache = ok.cache, sched = ok.sched, active_build_steps = "xyz")
    @test _world_digest(bad_a) === nothing

    # (c) 문자열이 아닌 다른 잘못된 모양도 마찬가지다 — 술어는 "문자열이 아니다" 가 아니라
    #     **"집합이다"** 여야 한다(`length` 를 갖는 모양은 문자열 말고도 많다).
    @test _world_digest((cache = (closed_set = [1, 2, 3],), sched = ok.sched,
                         active_build_steps = ok.active_build_steps)) === nothing
    @test _world_digest((cache = ok.cache, sched = ok.sched,
                         active_build_steps = Dict(1 => 2))) === nothing

    # (d) 🔴 그리고 **차분이 그 붕괴를 삼키지 않는다**: 한쪽이 `nothing` 이면 `nothing` 이다.
    @test _world_delta(_world_digest(bad_c), d_ok) === nothing
    @test _world_delta(d_ok, _world_digest(bad_a)) === nothing
    # 비-0 대조: 진짜 둘의 차분은 `nothing` 이 **아니라** 0 의 튜플이다(삼상).
    @test _world_delta(d_ok, d_ok) !== nothing
    @test _world_delta(d_ok, d_ok).closed == 0

    # ---- 🔴 변이 대조: 가드를 지우면 거짓 측정값이 되돌아온다 ------------------------------
    local src = read(ENACT_PATH, String)
    @test occursin("_is_countable_world_set", src)
    mktempdir() do dir
        local q = joinpath(dir, "enact_no_digest_guard.jl")
        # 술어를 항진으로 만든다(다른 줄은 안 건드린다).
        write(q, replace(src, "_is_countable_world_set(x) = x isa AbstractSet" =>
                              "_is_countable_world_set(x) = true", count = 1))
        local M = Module(:EnactNoDigestGuard)
        Core.eval(M, :(using Test; using ConstructionBots; import JSON3; import HTTP))
        Core.eval(M, :(const CB = ConstructionBots))
        Core.eval(M, :(const DSPY_URL = $(DSPY_URL)))
        Base.include(M, q)
        local mut = Base.invokelatest(getfield(M, :_world_digest), bad_c)
        @test mut !== nothing         # 🔴 가드가 없으면 "쟀다" 고 주장한다
        @test mut.closed == 10        # 그리고 그 수는 문자열의 길이다
    end
end

# =============================================================================
# (23) 🔴 D5 — L3(spec §0)이 **기록까지** 간다. L4 를 읽는 것과 같은 방법으로.
#
# Wave C2 가 생산자를 지었다(`impl_interface_calls`, `Core.eval` **전에** 등록 행에 실린다).
# 그러나 그 값은 행에만 있었고 집행 경로에도 결정 행에도 없었다 — 유료 런이 L4(`world_delta`)
# 는 읽는데 L3 은 못 읽는 상태였다. 이 절이 두 자리를 잰다:
#   (a) `resolve_primitive(...).interface_calls` — 삼상 그대로
#   (b) 집행 결과 `m.interface_calls` + `record_world_delta!` 이 쓰는 결정 행의 키
# =============================================================================
@testset "(23) 🔴 D5: L3 이 집행 결과와 결정 행까지 간다" begin

@testset "(23a) 인터페이스를 부르는 body — L3 = 참" begin
    CB.reset_minted_table!()
    local env = live_cache_env()
    local e = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "d5_l3_true!",
        "impl_code" => "function d5_l3_true!(env; v::Int = 1)\n" *
                       "    a = RobotStart(RobotNode(RobotID(v), GeomNode(nothing)))\n" *
                       "    add_node!(env.sched, ScheduleNode(node_id(a), a))\n" *
                       "    return (status = :d5_ok,)\nend\n",
        "surface" => "env_param", "reversible" => false,
        "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
        "body_names" => ["d5_l3_true!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "d5_l3_true!",
                                     "args" => Dict{String,Any}("v" => 1))]))
    local prev = CB.MONITOR_RESPEC[]
    try
        CB.MONITOR_RESPEC[] = Dict{String,Any}()
        local m = enact_minted_decision!(env, nothing, _dec(e))
        @test m.verdict === :admit
        # (a) 집행 경로가 그 값을 든다.
        local p = CB.resolve_primitive("d5_l3_true!")
        @test p.interface_calls isa Vector{String}
        @test !isempty(p.interface_calls)
        @test issorted(p.interface_calls)
        # ⚠️ 교집합은 `names(CB)` 와 진다 — `add_node!` 는 CB 가 export 하지 않아
        #    빠지고, 실려 있는 타입 생성자들이 남는다(실측). 인용하지 않고 **자리에서**
        #    확인한다: 이 값이 곧 L3 의 증거다.
        @test "ScheduleNode" in p.interface_calls
        # ⚠️ 인터페이스 집합 자체의 계약(교집합의 정의)은 Wave C2 의
        #    `test/minted_registration.jl` (32)(33) 이 소유한다 — 여기서 다시 안 잰다.
        # 🔴 진실원 하나: 행과 집행 경로가 같은 값을 든다.
        @test p.interface_calls ==
              String[String(x) for x in CB.minted_table()["d5_l3_true!"]["interface_calls"]]
        # (b) 집행 결과가 나른다 — L4 를 읽는 것과 같은 자리에서.
        @test m.interface_calls == p.interface_calls
        # (c) 결정 행까지 간다(삼상이 JSON 직전 모양에서도 산다).
        record_world_delta!(m)
        local rs = CB.MONITOR_RESPEC[]
        @test haskey(rs, "interface_calls")
        @test rs["interface_calls"] == p.interface_calls
        @test haskey(rs, "world_delta")                # L4 는 그대로 있다
    finally
        CB.MONITOR_RESPEC[] = prev
    end
end

@testset "(23b) 아무것도 안 부르는 body — L3 = `[]`(재서 없다), `nothing` 이 아니다" begin
    CB.reset_minted_table!()
    local prev = CB.MONITOR_RESPEC[]
    try
        CB.MONITOR_RESPEC[] = Dict{String,Any}()
        # ⚠️ 이름을 재사용할 수 없다 — `_MINTED_EVER` 가 프로세스 수명 내내 막는다
        #    (testset (1) 이 `e2e_touch!` 를 이미 주조했다). 같은 **모양**의 새 이름을 쓴다.
        local m = enact_minted_decision!(live_cache_env(), nothing, _dec(_lane(
            merge(OK_SYNTH, Dict{String,Any}(
                "impl_name" => "d5_l3_none!",
                "impl_code" => "function d5_l3_none!(env; note = \"x\")\n" *
                               "    return (status = :d5_ok, note = note)\nend\n",
                "body_names" => ["d5_l3_none!"],
                "calls" => [Dict{String,Any}("primitive" => "d5_l3_none!",
                                             "args" => Dict{String,Any}("note" => "hi"))])))))
        @test m.verdict === :admit
        @test m.interface_calls == String[]
        @test m.interface_calls !== nothing         # 🔴 삼상의 가운데 상태다
        record_world_delta!(m)
        @test CB.MONITOR_RESPEC[]["interface_calls"] == String[]
    finally
        CB.MONITOR_RESPEC[] = prev
    end
end

@testset "(23c) 등록조차 안 된 판 — L3 = `nothing`(못 쟀다)" begin
    CB.reset_minted_table!()
    local prev = CB.MONITOR_RESPEC[]
    try
        CB.MONITOR_RESPEC[] = Dict{String,Any}()
        # 규약 위반이라 등록 자체가 거절된다 ⟹ 걸어 본 적이 없다.
        local sl = _rw_lane("d5_never",
            "function d5_never(env; note = \"x\")\n    return (status = :nope,)\nend\n")
        local m = enact_minted_decision!(live_cache_env(), nothing, _dec(sl))
        @test m.verdict === :reject
        @test m.registered === false
        # 🔴 `[]` 이면 "재서 없다" 를 주장하게 된다 — 안 잰 것을 잰 것처럼 적는 것이다.
        @test m.interface_calls === nothing
        record_world_delta!(m)
        # 🔴 키는 **언제나** 쓰인다(`world_delta` 와 같은 규약): `null` 로 직렬화되고
        #    `[]` 가 되지 않는다. 키의 **부재**는 셋째 사건(이 코드 이전 세대)을 뜻한다.
        @test haskey(CB.MONITOR_RESPEC[], "interface_calls")
        @test CB.MONITOR_RESPEC[]["interface_calls"] === nothing
        @test JSON3.write(CB.MONITOR_RESPEC[]) |> x -> occursin("\"interface_calls\":null", x)
    finally
        CB.MONITOR_RESPEC[] = prev
    end
end

@testset "(23d) 손으로 씨 뿌린 행 — 기본값이 `[]` 가 아니라 `nothing` 이다" begin
    # 🔴 Wave C2 §7 이 못박은 자리. 씨앗 행(`test/minted_seed_fixture.jl` 의
    #    `MINTED_FIXTURE_ROWS`)에는 이 열이 **아예 없다** — 그 body 는 한 번도 안 걸렸다.
    #    `[]` 를 기본값으로 두면 "재서 인터페이스 호출이 없더라" 를 주장하게 된다.
    # 여기서는 그 모양을 **실제로 만든다**(씨앗 파일을 include 하지 않는다 — 이 파일의
    # 다른 절이 표에 등호를 걸므로 표를 오염시키지 않는 쪽이 옳다).
    CB.reset_minted_table!()
    local why = CB.register_minted_primitive!(
        name = "d5_seedlike!",
        code = "function d5_seedlike!(env; v::Int = 1)\n    return (status = :ok,)\nend\n",
        params = Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
        surface = "env_param", reversible = false)
    @test why === nothing
    # 열을 지워 **씨앗 행과 바이트 동일한 모양**으로 만든다.
    delete!(CB.minted_table()["d5_seedlike!"], "interface_calls")
    @test !haskey(CB.minted_table()["d5_seedlike!"], "interface_calls")
    @test CB.resolve_primitive("d5_seedlike!").interface_calls === nothing
    # 🔴 음성 대조 — 열이 있으면 `nothing` 이 아니다(위 단언이 항진이 아니다).
    CB.minted_table()["d5_seedlike!"]["interface_calls"] = ["zzz"]
    @test CB.resolve_primitive("d5_seedlike!").interface_calls == ["zzz"]
end

@testset "(23e) 되먹임으로 고친 body 의 L3 도 기록된다 — **고친** 이름의 것이다" begin
    CB.reset_minted_table!()
    _RW_MODE[] = :l3
    _RW_HITS[] = 0
    local sl = _rw_lane("d5_rw",
        "function d5_rw(env; note = \"x\")\n    return (status = :nope,)\nend\n")
    local m = enact_minted_decision!(live_cache_env(), nothing, _dec(sl))
    @test _RW_HITS[] == 1
    @test m.verdict === :admit
    @test m.steps[1].name == "rw_l3!"
    # 🔴 D1 과 같은 이유로 **고친** 이름의 값이어야 한다 — 옛 이름은 등록조차 안 됐다.
    @test m.interface_calls == CB.resolve_primitive("rw_l3!").interface_calls
    @test m.interface_calls !== nothing
    _RW_MODE[] = :off
end

end


# =============================================================================
# (24) 🔴 D8 — `[minted]` **기록 줄은 한 줄이다**, 모델이 개행을 보내도.
#
# 실측(검증자): `impl_name = "bad\nname!"` 로 `enact_minted_decision!` 을 끝까지 몰면
# 기록 줄이 **실제로 두 줄로 쪼개졌다**. 등록 거절 사유가 그 이름을 그대로 보간하는데
# (`reject:impl_name_not_an_identifier:$(name)`), 그 사유가 `reason=` 뒤에 실리기 때문이다.
# Task 7 fix round 2 가 더한 `_one_line` 은 `enact_minted!` 의 `_r`(= **사유** 문자열)에
# 살아서, 등록 거절 경로와 조기 `:deferred` 경로와 성공 줄은 그 보호 밖이었다.
#
# 🔴 왜 계약인가. 유료 런은 `world_delta` 와 `interface_calls` 를 **`[minted]` 줄을
#    grep 해서** 읽는다(사전등록 결정). 줄이 쪼개지면 파서가 그 결정을 통째로 잃는다 —
#    그리고 그것은 에러가 아니라 **누락**으로만 드러난다.
# 🔴 접는 자리는 하나다(`_rec_line`). 값마다 손으로 접으면 새 값을 더하는 사람이 빠뜨린다.
# =============================================================================
@testset "(24) 🔴 D8: 기록 줄은 개행이 든 payload 에서도 한 줄이다" begin
    CB.reset_minted_table!()
    local sl = _rw_lane("bad\nname!",
        "function bad_name!(env; note = \"x\")\n    return (status = :nope,)\nend\n")
    local out
    mktemp() do path, io
        redirect_stdout(io) do
            enact_minted_decision!(live_cache_env(), nothing, _dec(sl))
        end
        flush(io); out = read(path, String)
    end
    local recs = [l for l in split(out, "\n") if startswith(l, "[minted] lane=")]
    # 🔴 기록 줄이 **정확히 하나**다(쪼개지면 둘이 되고, 둘째 조각은 `[minted]` 로 시작하지
    #    않으므로 이 개수가 아니라 아래 단언이 그것을 잡는다).
    @test length(recs) == 1
    @test occursin("impl_name_not_an_identifier", recs[1])
    # 🔴 사유의 **꼬리까지** 같은 줄에 있다 — 쪼개지면 이 조각이 다음 줄로 넘어간다.
    @test occursin("name!", recs[1])
    @test occursin("verdict=reject", recs[1])
    # 🔴 그리고 어떤 줄도 `[minted]`/`(` 로 시작하지 않은 채 사유 조각을 들고 있지 않다.
    @test !any(l -> startswith(l, "name!"), split(out, "\n"))

    # ---- 자리 계약: 네 기록 줄이 **전부** 같은 접는 자리를 지난다 -------------------------
    local src = read(ENACT_PATH, String)
    @test occursin("_one_line_rec(x::AbstractString)", src)
    # `[minted] lane=` 으로 시작하는 println 은 0 이어야 한다 — 전부 `_rec_line` 이다.
    @test !occursin("println(\"[minted] lane=", src)
    @test count(i -> true, findall("_rec_line(\"[minted] lane=", src)) == 4

    # ---- 🔴 변이 대조: 접기를 항진으로 만들면 이 게이트가 빨개진다 -----------------------
    mktempdir() do dir
        local q = joinpath(dir, "enact_no_collapse.jl")
        write(q, replace(src,
            "_one_line_rec(x::AbstractString) = String(strip(replace(x, r\"\\s+\" => \" \")))" =>
            "_one_line_rec(x::AbstractString) = String(x)", count = 1))
        local M = Module(:EnactNoCollapse)
        Core.eval(M, :(using Test; using ConstructionBots; import JSON3; import HTTP))
        Core.eval(M, :(const CB = ConstructionBots))
        Core.eval(M, :(const DSPY_URL = $(DSPY_URL)))
        Base.include(M, q)
        CB.reset_minted_table!()
        local sl2 = _rw_lane("bad\nname2!",
            "function bad_name2!(env; note = \"x\")\n    return (status = :nope,)\nend\n")
        local out2
        mktemp() do path, io
            redirect_stdout(io) do
                Base.invokelatest(getfield(M, :enact_minted_decision!),
                                  live_cache_env(), nothing, _dec(sl2))
            end
            flush(io); out2 = read(path, String)
        end
        local recs2 = [l for l in split(out2, "\n") if startswith(l, "[minted] lane=")]
        @test length(recs2) == 1
        # 🔴 접기가 없으면 기록이 쪼개진다: 사유의 꼬리가 **다음 줄**에 있다.
        @test !occursin("name2!", recs2[1])
        @test any(l -> startswith(l, "name2!"), split(out2, "\n"))
    end
end

@testset "(25) 🔴 T1: `:threw` 의 예외 메시지가 기록 줄과 결정 행까지 간다" begin
    # 🔴 왜. 유료 런 1 이 `:threw` 로 죽었는데 **어떤 예외인지 어디에도 없었다** — 실행자가
    #    격리 프로브로 사후에 재유도해야 했다(`NamedTuple{(:status,)}(:success)` →
    #    `MethodError: no method matching length(::Symbol)`). 그런데 메시지는 이미
    #    `steps[i].detail` 에 실려 있었다(`src/respec/minted_tool.jl` 의 catch 절이
    #    `first(split(sprint(showerror, e), "\n"))` 를 담는다). 버려지던 자리는 **기록 줄의
    #    렌더 하나**였다. 새 채널을 만드는 것이 아니라 있는 값을 안 버린다.

@testset "(25a) 순수 렌더 — `_step_render` 의 네 갈래" begin
    # 🔴 detail 이 없거나 비면 **오늘과 바이트 동일**이어야 한다. 이 줄이 없으면 로그 문구를
    #    못박는 다른 게이트들이 왜 안 움직이는지가 우연이 된다.
    @test _step_render((name = "a", status = :ok)) == "a:ok"
    @test _step_render((name = "a", status = :ok, detail = "")) == "a:ok"
    @test _step_render((name = "a", status = :ok, detail = nothing)) == "a:ok"
    # 있으면 괄호로 싣는다.
    @test _step_render((name = "a", status = :threw, detail = "boom")) == "a:threw(boom)"
    # 🔴 개행 대조: 접혀서 **한 줄**로 남는다(D8 — 기록 줄 하나 = 판 하나).
    local nl = _step_render((name = "a", status = :threw, detail = "up\ndown"))
    @test nl == "a:threw(up down)"
    @test !occursin("\n", nl)
    # 🔴 절단 대조: 250자는 200자 + `…` 다. 199·200 자는 **안 잘린다**(경계 대조가 없으면
    #    "언제나 자른다" 는 구현도 위 단언을 통과한다).
    local long = _step_render((name = "a", status = :threw, detail = repeat("Z", 250)))
    @test occursin(repeat("Z", 200) * "…", long)
    @test !occursin(repeat("Z", 201), long)
    @test length(long) == length("a:threw(") + 200 + 1 + 1
    @test _step_render((name = "a", status = :threw, detail = repeat("Z", 200))) ==
          "a:threw(" * repeat("Z", 200) * ")"
    @test _step_render((name = "a", status = :threw, detail = repeat("Z", 199))) ==
          "a:threw(" * repeat("Z", 199) * ")"
    # 상한의 진실원이 하나다(두 소비자가 같은 상수를 읽는다).
    @test _STEP_DETAIL_CAP == 200
end

@testset "(25b) 던지는 body — 메시지가 `steps` 에 있고, 기록 줄에 나타난다" begin
    CB.reset_minted_table!()
    local env = live_cache_env()
    local e = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "t1_boom!",
        "impl_code" => "function t1_boom!(env; v::Int = 1)\n" *
                       "    error(\"T1BOOMZQ 유료런이 못 본 그 메시지\")\nend\n",
        "surface" => "env_param", "reversible" => false,
        "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
        "body_names" => ["t1_boom!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "t1_boom!",
                                     "args" => Dict{String,Any}("v" => 1))]))
    local m, out
    mktemp() do path, io
        redirect_stdout(io) do
            m = enact_minted_decision!(env, nothing, _dec(e))
        end
        flush(io); out = read(path, String)
    end
    # 전제 — 정말 생성 경로였고 body 가 실제로 던졌는가(음성 대조 없이 읽지 않는다).
    @test m.registered === true
    @test length(m.steps) == 1
    @test m.steps[1].status === :threw
    # 🔴 필드는 **이미 있었다**. 이 단언이 그 사실을 못박는다.
    @test m.steps[1].detail isa AbstractString
    @test !isempty(m.steps[1].detail)
    @test occursin("T1BOOMZQ", m.steps[1].detail)
    # 🔴 재는 것: 그 메시지가 **기록 줄에** 나타난다.
    local recs = [l for l in split(out, "\n") if startswith(l, "[minted] lane=")]
    @test length(recs) == 1
    @test occursin("t1_boom!:threw(", recs[1])
    @test occursin("T1BOOMZQ", recs[1])
end

@testset "(25c) 절단은 라이브 경로에서도 돈다 — 250자 예외" begin
    CB.reset_minted_table!()
    local e = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "t1_longboom!",
        "impl_code" => "function t1_longboom!(env; v::Int = 1)\n" *
                       "    error(\"T1LONGQ\" * repeat(\"Z\", 250))\nend\n",
        "surface" => "env_param", "reversible" => false,
        "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
        "body_names" => ["t1_longboom!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "t1_longboom!",
                                     "args" => Dict{String,Any}("v" => 1))]))
    local m, out
    mktemp() do path, io
        redirect_stdout(io) do
            m = enact_minted_decision!(live_cache_env(), nothing, _dec(e))
        end
        flush(io); out = read(path, String)
    end
    @test m.steps[1].status === :threw
    @test length(m.steps[1].detail) > _STEP_DETAIL_CAP      # 원본은 길다(전제)
    local recs = [l for l in split(out, "\n") if startswith(l, "[minted] lane=")]
    @test length(recs) == 1
    @test occursin("T1LONGQ", recs[1])
    @test occursin("…", recs[1])
    # 🔴 줄에 실린 것은 200자다 — 원본 250자가 통째로 새지 않았다.
    @test !occursin("T1LONGQ" * repeat("Z", 200), recs[1])
    @test occursin("T1LONGQ" * repeat("Z", 193) * "…", recs[1])
end

@testset "(25d) 결정 행의 셋째 칸 `steps` — 세 키, 그리고 삼상" begin
    local saved = CB.MONITOR_RESPEC[]
    try
        local row = Dict{String,Any}()
        CB.MONITOR_RESPEC[] = row
        record_world_delta!((world_delta = nothing, interface_calls = nothing,
                             steps = [(name = "p!", status = :threw,
                                       detail = "up\ndown " * repeat("Z", 250))]))
        @test haskey(row, "steps")
        @test row["steps"] isa AbstractVector && length(row["steps"]) == 1
        local st = row["steps"][1]
        @test st isa AbstractDict
        @test sort(collect(keys(st))) == ["detail", "name", "status"]
        @test st["name"] == "p!" && st["name"] isa String
        @test st["status"] == "threw" && st["status"] isa String
        @test st["detail"] isa String
        # 🔴 줄과 **같은** 접기·상한을 쓴다(진실원 하나 — `_step_detail_render`).
        @test !occursin("\n", st["detail"])
        @test startswith(st["detail"], "up down ")
        @test endswith(st["detail"], "…")
        @test length(st["detail"]) == _STEP_DETAIL_CAP + 1
        # 직렬화까지 산다.
        @test occursin("\"status\":\"threw\"", JSON3.write(row))
        # 🔴 "쟀는데 없다" 는 `[]` 다 — `nothing` 이 아니다.
        record_world_delta!((world_delta = nothing, interface_calls = nothing,
                             steps = NamedTuple[]))
        @test row["steps"] == []
        @test row["steps"] !== nothing
        @test occursin("\"steps\":[]", JSON3.write(row))
        # 🔴 "못 쟀다" 는 `nothing` 이다 — 필드가 아예 없는 구세대 집행부.
        record_world_delta!((world_delta = nothing, interface_calls = nothing))
        @test row["steps"] === nothing
        @test occursin("\"steps\":null", JSON3.write(row))
    finally
        CB.MONITOR_RESPEC[] = saved
    end
end

@testset "(25e) 생산 경로의 `m` 이 그대로 행에 실린다" begin
    CB.reset_minted_table!()
    local saved = CB.MONITOR_RESPEC[]
    try
        CB.MONITOR_RESPEC[] = Dict{String,Any}()
        local e = _lane(Dict{String,Any}(
            "synthesis_event" => true, "ran" => true, "error" => nothing,
            "tool_name" => "T", "impl_name" => "t1_rowboom!",
            "impl_code" => "function t1_rowboom!(env; v::Int = 1)\n" *
                           "    error(\"T1ROWQ boom\")\nend\n",
            "surface" => "env_param", "reversible" => false,
            "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
            "body_names" => ["t1_rowboom!"], "wrote" => true,
            "calls" => [Dict{String,Any}("primitive" => "t1_rowboom!",
                                         "args" => Dict{String,Any}("v" => 1))]))
        local m = enact_minted_decision!(live_cache_env(), nothing, _dec(e))
        record_world_delta!(m)
        local rs = CB.MONITOR_RESPEC[]
        @test haskey(rs, "world_delta")          # 앞 두 칸은 그대로다
        @test haskey(rs, "interface_calls")
        @test rs["steps"] isa AbstractVector && length(rs["steps"]) == 1
        @test rs["steps"][1]["name"] == "t1_rowboom!"
        @test rs["steps"][1]["status"] == "threw"
        @test occursin("T1ROWQ", rs["steps"][1]["detail"])
    finally
        CB.MONITOR_RESPEC[] = saved
    end
end

@testset "(25f) 🔴 음성 대조: 렌더를 되돌리면 이 게이트가 빨개진다" begin
    # 🔴 **레포 안의 것은 안 건드린다** — 사본을 임시 디렉토리에 만들어 그 위에서만 되돌린다
    #    (testset (24) 의 변이 대조와 **같은 관용구**다).
    local src = read(ENACT_PATH, String)
    mktempdir() do dir
        local q = joinpath(dir, "enact_no_step_detail.jl")
        local reverted = replace(src,
            "join([_step_render(s) for s in r.steps], \" \")" =>
            "join([string(s.name, \":\", s.status) for s in r.steps], \" \")", count = 1)
        @test reverted != src           # 변이가 실제로 적용됐다(무동작 변이가 아니다)
        write(q, reverted)
        local M = Module(:EnactNoStepDetail)
        Core.eval(M, :(using Test; using ConstructionBots; import JSON3; import HTTP))
        Core.eval(M, :(const CB = ConstructionBots))
        Core.eval(M, :(const DSPY_URL = $(DSPY_URL)))
        Base.include(M, q)
        CB.reset_minted_table!()
        local e = _lane(Dict{String,Any}(
            "synthesis_event" => true, "ran" => true, "error" => nothing,
            "tool_name" => "T", "impl_name" => "t1_mut_boom!",
            "impl_code" => "function t1_mut_boom!(env; v::Int = 1)\n" *
                           "    error(\"T1MUTQ 되돌린 판에서는 이 문자열이 안 보여야 한다\")\nend\n",
            "surface" => "env_param", "reversible" => false,
            "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
            "body_names" => ["t1_mut_boom!"], "wrote" => true,
            "calls" => [Dict{String,Any}("primitive" => "t1_mut_boom!",
                                         "args" => Dict{String,Any}("v" => 1))]))
        local m2, out2
        mktemp() do path, io
            redirect_stdout(io) do
                m2 = Base.invokelatest(getfield(M, :enact_minted_decision!),
                                       live_cache_env(), nothing, _dec(e))
            end
            flush(io); out2 = read(path, String)
        end
        local recs2 = [l for l in split(out2, "\n") if startswith(l, "[minted] lane=")]
        @test length(recs2) == 1
        # 🔴 값은 **거기 있었다** — 버려진 것은 렌더뿐이다.
        @test occursin("T1MUTQ", m2.steps[1].detail)
        # 🔴 그런데 기록 줄에는 없다 = (25b) 의 단언이 이 사본에서 빨갛다.
        @test !occursin("T1MUTQ", recs2[1])
        @test occursin("t1_mut_boom!:threw", recs2[1])
        @test !occursin("t1_mut_boom!:threw(", recs2[1])
    end
end

end

# =============================================================================
# (26) 🔴 T2 — L4 의 두 구멍. **둘은 독립이다.**
#   (1) `sched.weights` 축이 없었다. 유료 런 1 의 body 는 정확히 그것을 편집했는데
#       `world_delta` 의 네 축이 전부 0 이었다 — 로그가 "안 바뀌었다" 와 "그 축을 안 잰다" 를
#       같은 관측으로 만들었다.
#   (2) `delta_scope` 가 `body+harness_resolve` 라 0 이든 아니든 **귀속 불가**였다.
#       `_issue_resume!`/`_resolve_if_needed!` 가 `CB.enact_minted!` **안**에서 돌기 때문이다.
# =============================================================================
@testset "(26) 🔴 T2: 다섯째 축 `weights` 와 body 만의 다이제스트" begin

@testset "(26a) 양성 대조 — weights 를 바꾸는 body 가 `n_weights_changed > 0` 을 낸다" begin
    CB.reset_minted_table!()
    local env = live_cache_env()
    local before = length(env.sched.weights)
    local e = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "t2_weights!",
        "impl_code" => "function t2_weights!(env; v::Int = 1)\n" *
                       "    env.sched.weights[v] = 3.5\n" *
                       "    return (status = :t2_w,)\nend\n",
        "surface" => "env_param", "reversible" => false,
        "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
        "body_names" => ["t2_weights!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "t2_weights!",
                                     "args" => Dict{String,Any}("v" => 7))]))
    local m, out
    mktemp() do path, io
        redirect_stdout(io) do
            m = enact_minted_decision!(env, nothing, _dec(e))
        end
        flush(io); out = read(path, String)
    end
    # 전제 — 생성 경로였고 body 가 실제로 그 dict 을 편집했다.
    @test m.registered === true && m.verdict === :admit
    @test length(m.steps) == 1 && m.steps[1].status === :t2_w
    @test haskey(env.sched.weights, 7) && env.sched.weights[7] == 3.5
    @test length(env.sched.weights) == before + 1
    # 🔴 재는 것.
    @test m.world_delta !== nothing
    @test m.world_delta.n_weights_changed == 1
    # 🔴 음성 대조: 다섯이 뭉뚱그려 움직이는 것이 아니다 — 나머지 넷은 0 이다.
    @test m.world_delta.closed == 0 && m.world_delta.active == 0
    @test m.world_delta.n_edges == 0 && m.world_delta.n_binding_changed == 0
    # 🔴 그리고 그 수가 **로그 줄**에 있다(스윕이 grep 하는 채널).
    local wl = [l for l in split(out, "\n") if startswith(l, "[minted] world_delta=")]
    @test length(wl) == 1
    @test occursin("n_weights_changed=1", wl[1])
end

@testset "(26b) 음성 대조 — 아무것도 안 바꾸는 body 는 0 이다, `nothing` 이 아니다" begin
    CB.reset_minted_table!()
    local e = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "t2_noweights!",
        "impl_code" => "function t2_noweights!(env; v::Int = 1)\n" *
                       "    return (status = :t2_nw,)\nend\n",
        "surface" => "env_param", "reversible" => false,
        "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
        "body_names" => ["t2_noweights!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "t2_noweights!",
                                     "args" => Dict{String,Any}("v" => 1))]))
    local m = enact_minted_decision!(live_cache_env(), nothing, _dec(e))
    @test m.verdict === :admit
    @test m.world_delta !== nothing            # 🔴 "쟀는데 0" 이지 "못 쟀다" 가 아니다
    @test m.world_delta.n_weights_changed == 0
end

@testset "(26c) 🔴 얕은 참조 대조 — `copy` 를 빼면 (26a) 가 빨개진다" begin
    # 🔴 `get_root_node_weights` 는 살아 있는 `Dict` 를 **참조로** 돌려준다. `copy` 가 없으면
    #    사전 지문이 body 가 편집할 바로 그 dict 을 가리켜 차분이 **언제나 0** 이 된다.
    #    레포 안의 것은 안 건드린다 — 사본을 임시 디렉토리에 만든다.
    local src = read(ENACT_PATH, String)
    # ⚠️ 2026-09-05 (B1): 여섯째 축이 붙어 이 줄의 꼬리가 `))` 에서 `,` 로 바뀌었다.
    #    단언은 **이동**이다 — 변이 지점은 여전히 `copy(w)` 하나다.
    @test occursin("weights  = copy(w),", src)     # 변이 지점이 실제로 있다
    mktempdir() do dir
        local q = joinpath(dir, "enact_aliased_weights.jl")
        local mutated = replace(src, "weights  = copy(w)," => "weights  = w,", count = 1)
        @test mutated != src
        write(q, mutated)
        local M = Module(:EnactAliasedWeights)
        Core.eval(M, :(using Test; using ConstructionBots; import JSON3; import HTTP))
        Core.eval(M, :(const CB = ConstructionBots))
        Core.eval(M, :(const DSPY_URL = $(DSPY_URL)))
        Base.include(M, q)
        CB.reset_minted_table!()
        local env = live_cache_env()
        local e = _lane(Dict{String,Any}(
            "synthesis_event" => true, "ran" => true, "error" => nothing,
            "tool_name" => "T", "impl_name" => "t2_alias_w!",
            "impl_code" => "function t2_alias_w!(env; v::Int = 1)\n" *
                           "    env.sched.weights[v] = 3.5\n" *
                           "    return (status = :t2_w,)\nend\n",
            "surface" => "env_param", "reversible" => false,
            "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
            "body_names" => ["t2_alias_w!"], "wrote" => true,
            "calls" => [Dict{String,Any}("primitive" => "t2_alias_w!",
                                         "args" => Dict{String,Any}("v" => 7))]))
        local m2 = Base.invokelatest(getfield(M, :enact_minted_decision!),
                                     env, nothing, _dec(e))
        # 🔴 편집은 **실제로 일어났다** — 잃은 것은 측정뿐이다.
        @test env.sched.weights[7] == 3.5
        @test m2.world_delta !== nothing
        @test m2.world_delta.n_weights_changed == 0     # 🔴 (26a) 의 `== 1` 이 여기서 빨갛다
    end
end

@testset "(26d) 모양 가드 — 문자열 weights 는 수가 아니라 `nothing` 이다" begin
    local ok = live_cache_env()
    local d_ok = _world_digest(ok)
    @test d_ok !== nothing
    @test d_ok.weights isa AbstractDict          # 다섯째 축이 지문에 실제로 있다
    # ---- `_world_delta` 쪽 가드(여기가 **거짓 측정값**이 나던 자리다) --------------------
    local base = (closed = 0, active = 0, n_edges = 0, binding = Dict{Int,Int}(),
                  weights = Dict{Int,Float64}(1 => 1.0))
    local bad  = (closed = 0, active = 0, n_edges = 0, binding = Dict{Int,Int}(),
                  weights = "not a dict")
    @test _world_delta(base, bad) === nothing
    @test _world_delta(bad, base) === nothing    # 🔴 이쪽이 `try` 로는 **못 막는** 방향이다
    # 다섯째 축 이전 세대의 네-필드 지문이 오면 던지지 않고 `nothing` 이다.
    local old_shape = (closed = 0, active = 0, n_edges = 0, binding = Dict{Int,Int}())
    @test _world_delta(base, old_shape) === nothing
    @test _world_delta(old_shape, base) === nothing
    # 🔴 비-0 대조: 이 함수가 여전히 **잰다**(항진적 `nothing` 이 아니다).
    local moved = (closed = 0, active = 0, n_edges = 0, binding = Dict{Int,Int}(),
                   weights = Dict{Int,Float64}(1 => 2.0, 5 => 0.5))
    @test _world_delta(base, moved).n_weights_changed == 2   # 값 변경 1 + 새 키 1
    @test _world_delta(moved, base).n_weights_changed == 2   # 값 변경 1 + 사라진 키 1
    # 🔴 `!=` 가 아니라 `!isequal` — NaN 이 매 판 "바뀌었다" 로 세면 안 된다.
    local nan1 = (closed = 0, active = 0, n_edges = 0, binding = Dict{Int,Int}(),
                  weights = Dict{Int,Float64}(1 => NaN))
    local nan2 = (closed = 0, active = 0, n_edges = 0, binding = Dict{Int,Int}(),
                  weights = Dict{Int,Float64}(1 => NaN))
    @test _world_delta(nan1, nan2).n_weights_changed == 0
    # ---- `_world_digest` 쪽 가드 ---------------------------------------------------------
    # ⚠️ **이 대조는 가드에 안 닿는다 — 그리고 그것이 실측이다.**
    #    `get_root_node_weights` 는 `OperatingSchedule` 로 한정된 메서드라, 가짜 sched 는
    #    모양과 **무관하게** `MethodError` → `catch` → `nothing` 이다. 아래 짝지은 두 줄이
    #    그 사실을 못박는다(하나만 적으면 "가드가 잡았다" 로 잘못 읽힌다).
    @test _world_digest((cache = ok.cache, active_build_steps = ok.active_build_steps,
                         sched = (graph = ok.sched.graph, weights = "문자열"))) === nothing
    @test _world_digest((cache = ok.cache, active_build_steps = ok.active_build_steps,
                         sched = (graph = ok.sched.graph,
                                  weights = Dict{Int,Float64}()))) === nothing
    # 🔴 그래서 다이제스트 쪽 가드는 `binding` 가드와 **같은 지위**다: 도달 불가에 기대지
    #    않으려고 둔 방어선이고, 이 파일이 그 원칙을 이미 세 번 적용했다.
    @test occursin("w isa AbstractDict || return nothing", read(ENACT_PATH, String))
end

@testset "(26e) 🔴 `world_delta_body` — 봉투가 귀속 불가여도 body 는 재진다" begin
    # 🔴 이것이 이 Step 의 존재 이유다. `surface="sched"` 는 `RESOLVE_SURFACES` 안이라
    #    `_resolve_if_needed!` 가 **실제로** 하네스 재풀이를 시도한다 — 그 순간 봉투 차분
    #    (`world_delta`)은 body 에 귀속할 수 없게 되고 `_delta_scope` 가 그것을 말한다.
    #    그런데 `world_delta_body` 는 그 걸음들 **앞**에서 찍은 지문이라 여전히 잰다.
    # ⚠️ 🔴 **브리핑 정정.** 브리핑은 `delta_scope=="body+harness_resolve"`(= `resolve ===
    #    :resolved`)를 요구했는데, 이 파일의 픽스처로는 **도달 불가**다: `resolve_assignments!`
    #    는 `env.scene_tree` 로 MILP 를 정식화해 푸는데(`common_resolve.jl`), 빈 스케줄에서는
    #    `get_objective_expr` 가 `map(f, ::Set{Int})` 로 던진다(2026-09-04 실측). 그래서
    #    여기서 나오는 것은 `:threw` 이고 `_delta_scope` 는 `unknown` 이다 — **둘 다 "귀속
    #    불가"** 라는 같은 사실이고, 이 절이 재려는 명제는 그대로다. `:resolved` 자체의
    #    판독은 (17) 이 단위로 못박는다.
    CB.reset_minted_table!()
    local env = live_cache_env()
    local e = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "t2_sched_w!",
        "impl_code" => "function t2_sched_w!(env; v::Int = 1)\n" *
                       "    env.sched.weights[v] = 9.25\n" *
                       "    return (status = :t2_sw,)\nend\n",
        "surface" => "sched", "reversible" => false,
        "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
        "body_names" => ["t2_sched_w!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "t2_sched_w!",
                                     "args" => Dict{String,Any}("v" => 3))]))
    local m, out
    mktemp() do path, io
        redirect_stdout(io) do
            m = enact_minted_decision!(env, nothing, _dec(e))
        end
        flush(io); out = read(path, String)
    end
    @test m.verdict === :admit
    # 전제 — 하네스 재풀이 자리에 **실제로 갔다**(`:not_needed_surface` 가 아니다).
    @test m.resolve !== :not_needed_surface
    # 🔴 봉투의 판독은 body 단독이 **아니다** — 귀속 불가다.
    @test _delta_scope(m.resolve) != "body_only"
    # 🔴 그런데 body 는 재졌다. 이 두 줄이 짝일 때만 이 Step 이 무언가를 한 것이다.
    @test m.world_delta_body !== nothing
    @test m.world_delta_body.n_weights_changed == 1
    # 로그가 **두 쌍**을 찍는다.
    local wl = [l for l in split(out, "\n") if startswith(l, "[minted] world_delta=")]
    @test length(wl) == 1
    @test occursin("delta_scope=", wl[1])
    @test occursin("world_delta_body=closed=0 active=0 n_edges=0 " *
                   "n_binding_changed=0 n_weights_changed=1", wl[1])
    @test occursin("body_scope=" * BODY_ONLY_PROBED, wl[1])
    @test BODY_ONLY_PROBED == "body_only(probed)"
    # 🔴 `body_scope` 는 `_delta_scope` 의 값이 아니다 — 다른 근거의 이름이다.
    @test BODY_ONLY_PROBED != _delta_scope(:not_needed_surface)

    # ---- 🔴 못 잰 판에는 범위 이름을 안 붙인다 (m3 과 같은 논거) --------------------------
    #      `BARE_ENV` 에는 `cache`/`sched` 가 없어 사전 지문이 `nothing` 이고, 그러면
    #      `world_delta_body` 도 `nothing` 이다 — 그 줄에 `body_only(probed)` 를 찍으면
    #      "재지도 않은 것의 범위" 라는 형용모순이 된다.
    CB.reset_minted_table!()
    local e0 = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "t2_bare_w!",
        "impl_code" => "function t2_bare_w!(env; v::Int = 1)\n" *
                       "    return (status = :t2_bw,)\nend\n",
        "surface" => "env_param", "reversible" => false,
        "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
        "body_names" => ["t2_bare_w!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "t2_bare_w!",
                                     "args" => Dict{String,Any}("v" => 1))]))
    local m0, out0
    mktemp() do path, io
        redirect_stdout(io) do
            m0 = enact_minted_decision!(BARE_ENV, nothing, _dec(e0))
        end
        flush(io); out0 = read(path, String)
    end
    @test m0.verdict === :admit                 # 전제: 집행 자리까지 실제로 갔다
    @test m0.world_delta_body === nothing
    local wl0 = [l for l in split(out0, "\n") if startswith(l, "[minted] world_delta=")]
    @test length(wl0) == 1
    @test occursin("world_delta_body=n/a(not measured)", wl0[1])
    @test occursin("body_scope=unknown", wl0[1])
    @test !occursin("body_scope=" * BODY_ONLY_PROBED, wl0[1])
end

@testset "(26f) 🔴 `probe = nothing` 이면 오늘과 같다 (회귀 대조)" begin
    CB.reset_minted_table!()
    # 등록만 시키고(집행 결과는 안 본다) 같은 `synth` 로 직접 두 번 부른다.
    local e = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "t2_reg!",
        "impl_code" => "function t2_reg!(env; v::Int = 1)\n" *
                       "    env.sched.weights[v] = 1.5\n" *
                       "    return (status = :t2_r,)\nend\n",
        "surface" => "env_param", "reversible" => false,
        "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
        "body_names" => ["t2_reg!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "t2_reg!",
                                     "args" => Dict{String,Any}("v" => 4))]))
    enact_minted_decision!(live_cache_env(), nothing, _dec(e))
    @test haskey(CB.minted_table(), "t2_reg!")
    local synth = Dict{String,Any}(
        "reach" => "composed", "body_names" => ["t2_reg!"], "impl_name" => "t2_reg!",
        "tool_name" => "t", "params" => Dict{String,Any}(), "missing_primitive" => nothing,
        "calls" => [Dict{String,Any}("primitive" => "t2_reg!",
                                     "args" => Dict{String,Any}("v" => 4))])
    local ra = CB.enact_minted!(live_cache_env(), nothing, synth)                       # 오늘
    local rb = CB.enact_minted!(live_cache_env(), nothing, synth; probe = () -> :SENTINEL)
    @test ra.verdict === :admit                       # 전제: 두 판 다 실제로 굴렀다
    @test rb.verdict === :admit
    # 🔴 `probe` 를 안 주면 필드는 있고 값은 `nothing` 이다.
    @test hasproperty(ra, :body_probe)
    @test ra.body_probe === nothing
    @test rb.body_probe === :SENTINEL                 # 비-0 대조: 채널이 살아 있다
    # 🔴 **다른 모든 필드가 같다.** 이 루프가 없으면 "probe 가 무해하다" 가 주장으로만 남는다.
    for k in keys(ra)
        k === :body_probe && continue
        @test getproperty(ra, k) == getproperty(rb, k)
    end
    # 🔴 계측이 집행을 못 죽인다 — probe 가 던지면 삼키고 `nothing` 이다.
    local rc = CB.enact_minted!(live_cache_env(), nothing, synth;
                                probe = () -> error("probe boom"))
    @test rc.verdict === :admit
    @test rc.body_probe === nothing
    for k in keys(ra)
        k === :body_probe && continue
        @test getproperty(ra, k) == getproperty(rc, k)
    end
    # 🔴 조기 반환도 필드를 갖는다(`_r` 이 모양을 소유한다 — 열한 자리가 한 기본값을 쓴다).
    local rd = CB.enact_minted!(BARE_ENV, nothing, nothing)
    @test rd.verdict === :deferred
    @test hasproperty(rd, :body_probe) && rd.body_probe === nothing
    local re_ = CB.enact_minted!(BARE_ENV, nothing, synth; probe = () -> :NEVER)
    @test hasproperty(re_, :body_probe)
end

@testset "(26g) 결정 행의 넷째 칸 `world_delta_body`" begin
    local saved = CB.MONITOR_RESPEC[]
    try
        local row = Dict{String,Any}()
        CB.MONITOR_RESPEC[] = row
        record_world_delta!((world_delta = nothing, interface_calls = nothing,
                             steps = NamedTuple[], world_delta_body = nothing))
        @test haskey(row, "world_delta_body")           # 키는 언제나 있다
        @test row["world_delta_body"] === nothing       # 🔴 "못 쟀다"
        @test occursin("\"world_delta_body\":null", JSON3.write(row))
        record_world_delta!((world_delta = nothing, interface_calls = nothing,
                             steps = NamedTuple[],
                             world_delta_body = (closed = 1, active = 2, n_edges = 3,
                                                 n_binding_changed = 4,
                                                 n_weights_changed = 5)))
        @test row["world_delta_body"] isa AbstractDict
        @test length(row["world_delta_body"]) == 6      # 여섯 축이 전부 실린다
        @test row["world_delta_body"]["n_weights_changed"] == 5
        # 🔴 안 던진다: 필드가 아예 없는 구세대 집행부는 `nothing` 이다.
        record_world_delta!((world_delta = nothing, interface_calls = nothing,
                             steps = NamedTuple[]))
        @test row["world_delta_body"] === nothing
    finally
        CB.MONITOR_RESPEC[] = saved
    end
end

end

# =============================================================================
# (27) 🔴 F2 (2026-09-04 fix round 1) — 잘린 detail 이 `steps=[...]` 를 못 깬다.
#
# 기록 줄의 `steps=[...]` 는 **구조**다. 채점기 `tools/monitor/ladder_report.py` 가
# `steps=[` 에서 괄호 깊이를 세어 닫는 `]` 를 찾고(`find_bracket_close`), 항목마다
# `name:status(detail)` 의 detail 도 깊이로 되찾는다(`parse_step_entry`). 예외 메시지는
# 괄호류를 일상적으로 담는데(`at index [4]` · `f(::Vector{Int64}, ::Int64)`), 200자에서
# 자르는 순간 그 균형이 깨진다 — 그러면 채점기가 `ValueError: ']' never balances` 로 죽고
# **L2b 가 UNMEASURED** 가 된다. 짝 없는 `]` 하나는 더 나쁘다: 조용히 일찍 닫힌다.
# 🔴 이 결함은 옛 `name:status` 포맷에서 **구조적으로 불가능**했다 — Task 1 의 포맷 변경이
#    들여왔고, 하필 L2b 는 유료 런이 움직이려는 바로 그 칸이다.
#
# ⚠️ 아래 `_balances`/`_first_entry_parses` 는 `ladder_report.py` 의 두 규칙을 **줄리아로
#    옮겨 적은 거울**이다(진실원은 그 파이썬 파일이다). 실제 채점기 왕복은 스위트 밖에서
#    돌려 보고서에 붙인다 — 여기서 파이썬 서브프로세스를 띄우면 이 파일이 (19) 와 같은
#    간헐 실패를 얻는다.
# =============================================================================
"`text` 의 `open_idx` 위치 여는 괄호가 균형을 이루며 닫히는 자리. `ladder_report.py` 의 거울."
function _balance_close(text::AbstractString, open_idx::Int)
    # ⚠️ 바이트 인덱스로 순회하지 않는다 — 이 줄에는 `…`(멀티바이트) 가 들어 있고
    #    `text[i]` 가 `StringIndexError` 를 낸다(2026-09-04 실측).
    local depth = 0
    local i = open_idx
    while i <= ncodeunits(text)
        local c = text[i]
        if c == '(' || c == '['
            depth += 1
        elseif c == ')' || c == ']'
            depth -= 1
            depth == 0 && return i
        end
        i = nextind(text, i)
    end
    return nothing
end

"기록 줄에서 `steps=[...]` 를 구조적으로 떼어낸다. 못 떼면 `nothing`(= 채점기의 UNMEASURED)."
function _extract_steps_raw(line::AbstractString)
    local r = findfirst("steps=", line)
    r === nothing && return nothing
    local open_idx = last(r) + 1
    open_idx > lastindex(line) && return nothing
    line[open_idx] == '[' || return nothing
    local close_idx = _balance_close(line, open_idx)
    close_idx === nothing && return nothing
    return line[open_idx:close_idx]
end

@testset "(27) 🔴 F2: 잘린 예외 메시지가 `steps=[...]` 를 못 깬다" begin

@testset "(27a) 중화 — 추적되는 괄호가 하나도 안 남는다" begin
    # 브리핑이 지목한 적대적 detail 넷.
    local adversarial = [
        "BoundsError: attempt to access 3-element Vector{Int64} at index [4]",
        "no method matching f(::Vector{Int64}, ::Int64)",
        # 🔴 200자 자르기가 **정확히 대괄호 한복판**에 떨어지도록 길이를 계산했다(추측 아님):
        #    1..199 = 'A', 200 = '[', 201 = '4', 202 = ']'.
        repeat("A", 199) * "[4]" * repeat("B", 50),
        repeat("[](){}", 60),                      # 전부 괄호
    ]
    for d in adversarial
        local out = _step_detail_line(d)
        @test !occursin('(', out)
        @test !occursin(')', out)
        @test !occursin('[', out)
        @test !occursin(']', out)
        @test length(out) <= _STEP_DETAIL_CAP + 1   # 상한은 그대로다(`…` 한 글자)
    end
    # 🔴 치환이 **1:1 문자 대응**이라 상한 자리가 행 렌더러와 바이트 단위로 같다.
    for d in adversarial
        @test length(_step_detail_line(d)) == length(_step_detail_render(d))
    end
    # 🔴 자르는 자리가 대괄호 한복판이라는 것을 **실측으로** 못박는다(위 셋째 픽스처).
    local mid = adversarial[3]
    @test collect(mid)[200] == '['            # 원문의 200번째 글자가 여는 대괄호다
    @test endswith(_step_detail_line(mid), "<…")
    @test endswith(_step_detail_render(mid), "[…")   # 중화 없는 쪽은 **짝 없는 `[`** 로 끝난다
    # 판독성은 산다.
    @test _step_detail_line("no method matching length(::Symbol)") ==
          "no method matching length<::Symbol>"
end

@testset "(27b) 라이브 경로 — 네 적대적 예외가 전부 파싱되는 줄을 낸다" begin
    local cases = [
        ("f2_bounds!",  "BoundsError_LIKE: at index [4]"),
        ("f2_method!",  "no method matching f(::Vector{Int64}, ::Int64)"),
        ("f2_midcut!",  repeat("A", 199) * "[4]" * repeat("B", 50)),
        ("f2_allbr!",   repeat("[](){}", 60)),
        # 🔴 짝 없는 `]` 하나 — 이쪽은 **에러가 안 난다**. 채점기가 거기서 `steps=` 를
        #    조용히 일찍 닫아 뒤가 통째로 사라진다(중화 없는 사본에서 실측:
        #    `steps='[…:threw(MethodError]'` — 꼬리가 없다). 조용한 쪽이 더 나쁘다.
        ("f2_stray!",   "MethodError] TAIL_MUST_SURVIVE_QZ trailing part"),
    ]
    for (nm, msg) in cases
        CB.reset_minted_table!()
        local e = _lane(Dict{String,Any}(
            "synthesis_event" => true, "ran" => true, "error" => nothing,
            "tool_name" => "T", "impl_name" => nm,
            "impl_code" => "function $(nm)(env; v::Int = 1)\n" *
                           "    error($(repr(msg)))\nend\n",
            "surface" => "env_param", "reversible" => false,
            "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
            "body_names" => [nm], "wrote" => true,
            "calls" => [Dict{String,Any}("primitive" => nm,
                                         "args" => Dict{String,Any}("v" => 1))]))
        local m, out
        mktemp() do path, io
            redirect_stdout(io) do
                m = enact_minted_decision!(live_cache_env(), nothing, _dec(e))
            end
            flush(io); out = read(path, String)
        end
        # 전제 — 정말 던졌고 detail 에 그 메시지가 있다.
        @test length(m.steps) == 1 && m.steps[1].status === :threw
        local recs = [l for l in split(out, "\n") if startswith(l, "[minted] lane=")]
        @test length(recs) == 1
        # 🔴 재는 것: 채점기의 두 규칙이 이 줄에서 성립한다.
        local raw = _extract_steps_raw(recs[1])
        @test raw !== nothing                       # `]` 가 균형을 이루며 닫힌다
        @test startswith(raw, "[") && endswith(raw, "]")
        @test occursin(nm * ":threw(", raw)
        # 🔴 그리고 항목 하나를 통째로 담았다 — 조용히 일찍 닫히지 않았다.
        @test endswith(raw, ")]")
        # 🔴 꼬리가 살아 있다(짝 없는 `]` 판의 조용한 절단을 이 줄이 잡는다).
        nm == "f2_stray!" && @test occursin("TAIL_MUST_SURVIVE_QZ", raw)
    end
end

@testset "(27c) 🔴 음성 대조: 중화를 빼면 (27b) 가 빨개진다" begin
    # 레포 안의 것은 안 건드린다 — `/tmp` 사본에서만 `_step_detail_line` 을 행 렌더러로 되돌린다.
    local src = read(ENACT_PATH, String)
    @test occursin("_step_detail_line(hasproperty(s, :detail)", src)   # 변이 지점이 있다
    mktempdir() do dir
        local q = joinpath(dir, "enact_no_neutralize.jl")
        local mutated = replace(src,
            "_step_detail_line(hasproperty(s, :detail) ? s.detail : nothing)" =>
            "_step_detail_render(hasproperty(s, :detail) ? s.detail : nothing)", count = 1)
        @test mutated != src
        write(q, mutated)
        local M = Module(:EnactNoNeutralize)
        Core.eval(M, :(using Test; using ConstructionBots; import JSON3; import HTTP))
        Core.eval(M, :(const CB = ConstructionBots))
        Core.eval(M, :(const DSPY_URL = $(DSPY_URL)))
        Base.include(M, q)
        CB.reset_minted_table!()
        local nm = "f2_mut_midcut!"
        local msg = repeat("A", 199) * "[4]" * repeat("B", 50)
        local e = _lane(Dict{String,Any}(
            "synthesis_event" => true, "ran" => true, "error" => nothing,
            "tool_name" => "T", "impl_name" => nm,
            "impl_code" => "function $(nm)(env; v::Int = 1)\n    error($(repr(msg)))\nend\n",
            "surface" => "env_param", "reversible" => false,
            "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
            "body_names" => [nm], "wrote" => true,
            "calls" => [Dict{String,Any}("primitive" => nm,
                                         "args" => Dict{String,Any}("v" => 1))]))
        local m2, out2
        mktemp() do path, io
            redirect_stdout(io) do
                m2 = Base.invokelatest(getfield(M, :enact_minted_decision!),
                                       live_cache_env(), nothing, _dec(e))
            end
            flush(io); out2 = read(path, String)
        end
        local recs2 = [l for l in split(out2, "\n") if startswith(l, "[minted] lane=")]
        @test length(recs2) == 1
        # 🔴 값은 거기 있다 — 깨진 것은 **구조**다.
        @test occursin("AAA", recs2[1])
        # 🔴 (27b) 의 단언이 여기서 빨갛다: `]` 가 균형을 못 이룬다 = 채점기의 ValueError.
        @test _extract_steps_raw(recs2[1]) === nothing
    end
end

@testset "(27d) 결정 행은 원문을 지킨다 — 중화는 **줄 전용**이다" begin
    # 🔴 행은 JSON 문자열이라 괄호가 어떤 구조도 못 닫는다. 거기서까지 접으면 충실도만 잃는다.
    local saved = CB.MONITOR_RESPEC[]
    try
        local row = Dict{String,Any}()
        CB.MONITOR_RESPEC[] = row
        record_world_delta!((world_delta = nothing, interface_calls = nothing,
                             world_delta_body = nothing,
                             steps = [(name = "p!", status = :threw,
                                       detail = "at index [4] f(::Int64)")]))
        @test row["steps"][1]["detail"] == "at index [4] f(::Int64)"
        @test occursin("[4]", row["steps"][1]["detail"])
        # 그리고 줄 쪽은 같은 detail 을 중화한다 — 둘이 **의도적으로** 다르다.
        @test _step_render((name = "p!", status = :threw,
                            detail = "at index [4] f(::Int64)")) ==
              "p!:threw(at index <4> f<::Int64>)"
    finally
        CB.MONITOR_RESPEC[] = saved
    end
end

end

# =============================================================================
# (28) 🔴 F1 (2026-09-04 fix round 1) — `world_delta_body` 의 게이트가 비어 있었다.
#
# `enact.jl` 의 `world_delta_body = _world_delta(_pre, r.body_probe)` 를
# `_world_delta(_pre, _world_digest(env))`(= 봉투 차분과 동일)로 바꿔도 452/452 가 초록이었다.
# 원인은 실측이다: 하네스가 두 지문 사이에서 움직이는 유일한 것이 `cache.active_set` 인데
# (`reset_cache_resume!` 가 그것을 비우고 다시 짓는다), **그 필드는 다이제스트의 축이 아니다**
# (`closed_set`·`active_build_steps`·`ne(graph)`·`binding`·`weights` 다섯).
# 2026-09-04 실측: 노드 둘·간선 하나·weights 하나를 심고 `reset_cache_resume!` 를 부르면
# `active_set` 은 `Set([999])` → `Set([1])` 로 바뀌는데 다섯 축의 차분은 **전부 0** 이다.
#
# ⚠️ 그래서 이 절의 픽스처는 `active_build_steps` 를 `cache.active_set` **그 객체로** 준다.
#    그러면 하네스의 재개가 다이제스트의 `active` 축을 실제로 움직여 두 지문이 갈린다.
#    🔴 이것은 **계측 장치이지 `PlannerEnv` 에 대한 주장이 아니다** — 생산 타입에서 그 둘은
#    다른 필드다(`route_planning.jl`). 여기서 필요한 것은 "봉투가 더 이상 반영하지 않는
#    순간에 probe 가 찍혔다" 를 다섯 축 **안에서** 관측 가능하게 만드는 것뿐이다.
#    🔴 **그 장치의 대가를 여기 적는다**(2026-09-04 fix round 2, 재리뷰가 잡은 사각지대):
#    두 필드가 별칭이므로 `_world_digest` 의 `active` 축을 `env.active_build_steps` 에서
#    `env.cache.active_set` 으로 **바꿔도 이 절은 전부 초록이다.** 즉 (28) 이 지키는 것은
#    `world_delta_body` 의 **출처와 시점**(probe 에서 왔는가, 하네스 앞에서 찍혔는가)이고,
#    `active` 축이 **어느 필드를 읽는가** 는 지키지 않는다. 그 정체성을 지키는 것은
#    (10)(11)(15)(22) 의 `active_build_steps` 픽스처들이다(그쪽은 별칭이 아니다).
# =============================================================================
"""
    aliased_active_env() -> NamedTuple

`active_build_steps` 가 `cache.active_set` **그 객체**인 env. (28) 의 계측 장치다 —
근거는 위 블록 주석이 소유한다.
"""
function aliased_active_env()
    local sched = CB.OperatingSchedule()
    local cache = CB.initialize_planning_cache(sched)
    push!(cache.active_set, 999)          # 낡은 정점 하나 — 재개가 이것을 지운다
    return (cache = cache, sched = sched, active_build_steps = cache.active_set)
end

@testset "(28) 🔴 F1: body 차분이 **봉투 뒤** 지문에서 오면 빨개진다" begin

@testset "(28a) probe 는 재개 **앞**에서 찍힌다 (`enact_minted!` 직접)" begin
    CB.reset_minted_table!()
    local e = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "f1_pre_resume!",
        "impl_code" => "function f1_pre_resume!(env; v::Int = 1)\n" *
                       "    env.sched.weights[v] = 3.5\n" *
                       "    return (status = :f1,)\nend\n",
        "surface" => "env_param", "reversible" => false,
        "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
        "body_names" => ["f1_pre_resume!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "f1_pre_resume!",
                                     "args" => Dict{String,Any}("v" => 1))]))
    enact_minted_decision!(aliased_active_env(), nothing, _dec(e))   # 등록만 시킨다
    @test haskey(CB.minted_table(), "f1_pre_resume!")
    local synth = Dict{String,Any}(
        "reach" => "composed", "body_names" => ["f1_pre_resume!"],
        "impl_name" => "f1_pre_resume!", "tool_name" => "t",
        "params" => Dict{String,Any}(), "missing_primitive" => nothing,
        "calls" => [Dict{String,Any}("primitive" => "f1_pre_resume!",
                                     "args" => Dict{String,Any}("v" => 1))])
    local env = aliased_active_env()
    local r = CB.enact_minted!(env, nothing, synth;
                               probe = () -> copy(env.cache.active_set))
    @test r.verdict === :admit
    @test r.resume === :issued                    # 전제: 재개가 실제로 돌았다
    # 🔴 probe 는 재개가 지우기 **전**의 집합을 봤다.
    @test r.body_probe == Set([999])
    # 🔴 그리고 반환 시점에는 그것이 없다 — 즉 봉투는 그 순간을 더 이상 반영하지 않는다.
    @test isempty(env.cache.active_set)
    @test r.body_probe != env.cache.active_set    # 비-0 대조: 둘이 실제로 다르다
end

@testset "(28b) 🔴 `world_delta_body` 가 봉투와 **다른 수**를 낸다" begin
    CB.reset_minted_table!()
    local env = aliased_active_env()
    local e = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "f1_split!",
        "impl_code" => "function f1_split!(env; v::Int = 1)\n" *
                       "    env.sched.weights[v] = 3.5\n" *
                       "    return (status = :f1,)\nend\n",
        "surface" => "env_param", "reversible" => false,
        "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
        "body_names" => ["f1_split!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "f1_split!",
                                     "args" => Dict{String,Any}("v" => 1))]))
    local m, out
    mktemp() do path, io
        redirect_stdout(io) do
            m = enact_minted_decision!(env, nothing, _dec(e))
        end
        flush(io); out = read(path, String)
    end
    @test m.verdict === :admit
    @test m.resume === :issued                   # 전제: 하네스가 실제로 한 걸음 더 갔다
    @test m.world_delta !== nothing && m.world_delta_body !== nothing
    # 🔴 **이 두 줄이 F1 이 요구한 게이트다.** 봉투는 재개가 지운 정점을 보고, body 는 못 본다.
    @test m.world_delta.active == -1
    @test m.world_delta_body.active == 0
    @test m.world_delta != m.world_delta_body    # 항진적으로 같지 않다
    # body 가 실제로 한 편집은 **양쪽 다** 본다(대조군: 갈린 것이 `active` 축 하나다).
    @test m.world_delta.n_weights_changed == 1
    @test m.world_delta_body.n_weights_changed == 1
    # 로그도 두 수를 다르게 찍는다.
    local wl = [l for l in split(out, "\n") if startswith(l, "[minted] world_delta=")]
    @test length(wl) == 1
    @test occursin("world_delta=closed=0 active=-1", wl[1])
    @test occursin("world_delta_body=closed=0 active=0", wl[1])
end

@testset "(28c) 🔴 음성 대조: 봉투 뒤 지문으로 바꾸면 (28b) 가 빨개진다" begin
    local src = read(ENACT_PATH, String)
    @test occursin("world_delta_body = _world_delta(_pre, r.body_probe)", src)
    mktempdir() do dir
        local q = joinpath(dir, "enact_body_is_envelope.jl")
        local mutated = replace(src,
            "world_delta_body = _world_delta(_pre, r.body_probe)" =>
            "world_delta_body = _world_delta(_pre, _world_digest(env))", count = 1)
        @test mutated != src
        write(q, mutated)
        local M = Module(:EnactBodyIsEnvelope)
        Core.eval(M, :(using Test; using ConstructionBots; import JSON3; import HTTP))
        Core.eval(M, :(const CB = ConstructionBots))
        Core.eval(M, :(const DSPY_URL = $(DSPY_URL)))
        Base.include(M, q)
        CB.reset_minted_table!()
        local e = _lane(Dict{String,Any}(
            "synthesis_event" => true, "ran" => true, "error" => nothing,
            "tool_name" => "T", "impl_name" => "f1_mut_split!",
            "impl_code" => "function f1_mut_split!(env; v::Int = 1)\n" *
                           "    env.sched.weights[v] = 3.5\n" *
                           "    return (status = :f1,)\nend\n",
            "surface" => "env_param", "reversible" => false,
            "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
            "body_names" => ["f1_mut_split!"], "wrote" => true,
            "calls" => [Dict{String,Any}("primitive" => "f1_mut_split!",
                                         "args" => Dict{String,Any}("v" => 1))]))
        local m2 = Base.invokelatest(getfield(M, :enact_minted_decision!),
                                     aliased_active_env(), nothing, _dec(e))
        @test m2.verdict === :admit                  # 전제: 사본도 끝까지 굴렀다
        @test m2.world_delta.active == -1
        # 🔴 (28b) 의 `== 0` 이 여기서 빨갛다 — body 차분이 봉투와 **같아졌다**.
        @test m2.world_delta_body.active == -1
        @test m2.world_delta == m2.world_delta_body
    end
end

end

# =============================================================================
# (29) 🔴 N2 (2026-09-04 fix round 2) — `status` 도 모델의 텍스트다.
#
# F2 는 `detail` 만 중화했다. 그런데 항목은 `name:status(detail)` 이고 `status` 는
# `_step_status` 가 `Symbol(getproperty(out, :status))` 로 만든다 — 즉 **body 가 반환한
# 문자열 그대로**다. `status = "moved 3 robots [east"` 를 내는 body 하나면 F2 가 닫은 그
# 실패가 그대로 돌아온다: 채점기가 `']' never balances` 로 죽고 L2b 가 UNMEASURED 가 된다.
# ⚠️ `name`·`status` 는 **안 잘린다** — 그래서 F2 의 상한·바이트 동일성 논증은 그대로다.
# =============================================================================
@testset "(29) 🔴 N2: 괄호를 담은 `status` 도 `steps=[...]` 를 못 깬다" begin

@testset "(29a) 순수 렌더 — 중화는 항목 전체에 걸린다" begin
    @test _step_render((name = "p!", status = Symbol("moved 3 robots [east"))) ==
          "p!:moved 3 robots <east"
    @test _step_render((name = "p!", status = Symbol("done] extra"))) == "p!:done> extra"
    @test _step_render((name = "p!", status = Symbol("a[b]c(d)e"))) == "p!:a<b>c<d>e"
    # detail 이 함께 있어도 둘 다 중화된다.
    @test _step_render((name = "p!", status = Symbol("st[1]"), detail = "at index [4]")) ==
          "p!:st<1>(at index <4>)"
    # 🔴 중화의 진실원이 하나다 — 두 소비자가 같은 함수를 부른다.
    @test _neutralize_brackets("a(b)c[d]e") == "a<b>c<d>e"
    @test occursin("_neutralize_brackets(string(s.name", read(ENACT_PATH, String))
    # 🔴 괄호가 없는 status 는 **오늘과 바이트 동일**이다(기존 게이트가 안 움직이는 이유).
    @test _step_render((name = "a", status = :ok)) == "a:ok"
end

@testset "(29b) 라이브 경로 — 괄호를 담은 status 셋이 파싱되는 줄을 낸다" begin
    local cases = [
        ("n2_open!",  "moved 3 robots [east"),
        ("n2_close!", "done] N2_TAIL_MUST_SURVIVE_QZ"),
        ("n2_both!",  "a[b]c(d)e N2BOTHQ"),
    ]
    for (nm, st) in cases
        CB.reset_minted_table!()
        local e = _lane(Dict{String,Any}(
            "synthesis_event" => true, "ran" => true, "error" => nothing,
            "tool_name" => "T", "impl_name" => nm,
            # 🔴 body 가 **문자열 status** 를 낸다 — `_step_status` 가 그것을 Symbol 로 만든다.
            "impl_code" => "function $(nm)(env; v::Int = 1)\n" *
                           "    return (status = $(repr(st)),)\nend\n",
            "surface" => "env_param", "reversible" => false,
            "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
            "body_names" => [nm], "wrote" => true,
            "calls" => [Dict{String,Any}("primitive" => nm,
                                         "args" => Dict{String,Any}("v" => 1))]))
        local m, out
        mktemp() do path, io
            redirect_stdout(io) do
                m = enact_minted_decision!(live_cache_env(), nothing, _dec(e))
            end
            flush(io); out = read(path, String)
        end
        # 전제 — 모델의 텍스트가 정말 status 자리에 도착했다.
        @test length(m.steps) == 1
        @test string(m.steps[1].status) == st
        local recs = [l for l in split(out, "\n") if startswith(l, "[minted] lane=")]
        @test length(recs) == 1
        # 🔴 재는 것: 채점기의 규칙이 이 줄에서 성립한다.
        local raw = _extract_steps_raw(recs[1])
        @test raw !== nothing
        @test startswith(raw, "[") && endswith(raw, "]")
        @test occursin(nm * ":", raw)
        # 🔴 꼬리가 살아 있다(짝 없는 `]` 판의 조용한 절단을 이 줄이 잡는다).
        nm == "n2_close!" && @test occursin("N2_TAIL_MUST_SURVIVE_QZ", raw)
        nm == "n2_both!"  && @test occursin("N2BOTHQ", raw)
    end
end

@testset "(29c) 🔴 음성 대조: status 중화를 빼면 (29b) 가 빨개진다" begin
    local src = read(ENACT_PATH, String)
    mktempdir() do dir
        local q = joinpath(dir, "enact_status_raw.jl")
        local mutated = replace(src,
            "_neutralize_brackets(string(s.name, \":\", s.status))" =>
            "string(s.name, \":\", s.status)", count = 1)
        @test mutated != src
        write(q, mutated)
        local M = Module(:EnactStatusRaw)
        Core.eval(M, :(using Test; using ConstructionBots; import JSON3; import HTTP))
        Core.eval(M, :(const CB = ConstructionBots))
        Core.eval(M, :(const DSPY_URL = $(DSPY_URL)))
        Base.include(M, q)
        CB.reset_minted_table!()
        local nm = "n2_mut_open!"
        local e = _lane(Dict{String,Any}(
            "synthesis_event" => true, "ran" => true, "error" => nothing,
            "tool_name" => "T", "impl_name" => nm,
            "impl_code" => "function $(nm)(env; v::Int = 1)\n" *
                           "    return (status = \"moved 3 robots [east\",)\nend\n",
            "surface" => "env_param", "reversible" => false,
            "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
            "body_names" => [nm], "wrote" => true,
            "calls" => [Dict{String,Any}("primitive" => nm,
                                         "args" => Dict{String,Any}("v" => 1))]))
        local m2, out2
        mktemp() do path, io
            redirect_stdout(io) do
                m2 = Base.invokelatest(getfield(M, :enact_minted_decision!),
                                       live_cache_env(), nothing, _dec(e))
            end
            flush(io); out2 = read(path, String)
        end
        local recs2 = [l for l in split(out2, "\n") if startswith(l, "[minted] lane=")]
        @test length(recs2) == 1
        @test occursin("moved 3 robots [east", recs2[1])   # 값은 거기 있다
        # 🔴 (29b) 의 단언이 여기서 빨갛다 = 채점기의 ValueError.
        @test _extract_steps_raw(recs2[1]) === nothing
    end
end

@testset "(29d) 결정 행은 원문 status 를 지킨다" begin
    local saved = CB.MONITOR_RESPEC[]
    try
        local row = Dict{String,Any}()
        CB.MONITOR_RESPEC[] = row
        record_world_delta!((world_delta = nothing, interface_calls = nothing,
                             world_delta_body = nothing,
                             steps = [(name = "p!", status = Symbol("moved [east"),
                                       detail = "")]))
        @test row["steps"][1]["status"] == "moved [east"    # 🔴 행은 원문이다
        @test occursin("[", row["steps"][1]["status"])
        # 줄 쪽은 중화한다 — 둘이 **의도적으로** 다르다(detail 과 같은 규약).
        @test _step_render((name = "p!", status = Symbol("moved [east"))) == "p!:moved <east"
    finally
        CB.MONITOR_RESPEC[] = saved
    end
end

end

@testset "(30) 🔴 Task 1 (2026-09-04, P2): `_rewrite_once` 의 catch 가 예외 원인을 로그에 싣는다" begin
    # 🔴 왜. `/rewrite` 왕복 실패는 라이브 유료 런에서 **사유 없이** 죽었다(브리프). 원인:
    #    옛 catch 절이 `first(split(sprint(showerror, e), "\n"))` 를 썼는데,
    #    `HTTP.RequestError` 의 `showerror` 는 1번째 줄이 리터럴 `"HTTP.RequestError:"`
    #    이고 진짜 원인은 **마지막 줄**(`"Underlying error:"` 다음)에 있다 — 그래서 로그에
    #    남는 것은 언제나 `"HTTP.RequestError:"` 뿐이었다. 고침은 이 파일이
    #    `steps[i].detail` 에 이미 쓰는 접합(`_step_detail_render` 의
    #    `_cap_detail∘_one_line_rec`)을 그대로 재사용한다 — 새 접는 자리를 만들지 않는다.

@testset "(30a) 브리프의 재현 — `HTTP.RequestError` 는 원인이 마지막 줄에 있다" begin
    local e = HTTP.RequestError(HTTP.Request("POST", "/rewrite"),
                                 ErrorException("SENTINEL_CAUSE"))
    local raw = sprint(showerror, e)
    @test occursin("SENTINEL_CAUSE", raw)                    # 원인은 전문에 있다
    local firstline = first(split(raw, "\n"))
    @test firstline == "HTTP.RequestError:"                  # 그런데 1번째 줄은 이것뿐이다
    @test !occursin("SENTINEL_CAUSE", firstline)              # 옛 코드가 보던 값
    # `_rewrite_once` 의 catch 가 실제로 쓰는 접합 — 원인이 살아남는다.
    @test occursin("SENTINEL_CAUSE", _cap_detail(_one_line_rec(raw)))
end

@testset "(30b) 라이브 경로 — `_rewrite_once` 를 실제로 태워 다줄 원인을 건진다" begin
    # 진짜 network round-trip: 루프백 서버가 **깨진 JSON** 을 200으로 돌려주면
    # `JSON3.read(String(resp.body))` 가 다줄 `ArgumentError` 를 던진다(원인 스니펫이
    # 2번째 줄에 있다) — `HTTP.RequestError` 를 손으로 안 지어도 `_rewrite_once` 의 catch
    # 가 실제 운영에서 겪는 것과 같은 모양(사유가 첫 줄에 없다)이다.
    _RW_MODE[] = :bad_json
    local sl = Dict{String,Any}("mechanism" => "m", "tool_name" => "t")
    local out
    mktemp() do path, io
        redirect_stdout(io) do
            local r = _rewrite_once(sl, "impl_fn!", "function impl_fn!(env) end", "reject:x")
            @test r === nothing   # 절대 안 던진다(docstring 의 규약) — 그리고 못 고쳤다
        end
        flush(io); out = read(path, String)
    end
    _RW_MODE[] = :off
    local recs = [l for l in split(out, "\n") if startswith(l, "[minted] rewrite: 왕복 실패")]
    @test length(recs) == 1
    @test occursin("SENTINEL_CAUSE", recs[1])
    @test occursin("ArgumentError", recs[1])
end

@testset "(30c) 🔴 음성 대조: catch 를 옛 `first(split(...))` 로 되돌리면 (30b) 가 빨개진다" begin
    local src = read(ENACT_PATH, String)
    @test occursin("_cap_detail(_one_line_rec(_showerror_cause(e)))", src)
    mktempdir() do dir
        local q = joinpath(dir, "enact_rewrite_no_cap.jl")
        write(q, replace(src,
            "_cap_detail(_one_line_rec(_showerror_cause(e)))" =>
            "first(split(sprint(showerror, e), \"\\n\"))", count = 1))
        local M = Module(:EnactRewriteNoCap)
        Core.eval(M, :(using Test; using ConstructionBots; import JSON3; import HTTP))
        Core.eval(M, :(const CB = ConstructionBots))
        Core.eval(M, :(const DSPY_URL = $(DSPY_URL)))
        Base.include(M, q)
        _RW_MODE[] = :bad_json
        local sl2 = Dict{String,Any}("mechanism" => "m", "tool_name" => "t")
        local out2
        mktemp() do path, io
            redirect_stdout(io) do
                Base.invokelatest(getfield(M, :_rewrite_once),
                                  sl2, "impl_fn2!", "function impl_fn2!(env) end", "reject:x")
            end
            flush(io); out2 = read(path, String)
        end
        _RW_MODE[] = :off
        local recs2 = [l for l in split(out2, "\n") if startswith(l, "[minted] rewrite: 왕복 실패")]
        @test length(recs2) == 1
        # 🔴 이 assertion 은 (30b)와 정반대다 — 옛 접합으로 되돌리면 원인이 다시 안
        #    보이는 것이 **관측된 사실**이라 초록으로 남는다(이 파일의 (24)와 같은 관용구:
        #    변이 아래에서 참인 것을 적어야 회귀 게이트가 영구히 초록이다). 검증 방법론은
        #    별개다 — 이 assertion 을 그대로 (30b) 자리에 옮겨 심으면(즉 `occursin` 그대로)
        #    빨개지는 것을 개발 중 수동으로 확인했다(태스크 보고서의 변이 기록).
        @test !occursin("SENTINEL_CAUSE", recs2[1])
    end
end

@testset "(30d) 🔴 2026-09-05 (P2, 남은 구멍): 1800바이트 요청 덤프 뒤의 원인이 상한 안으로 들어온다" begin
    # 🔴 재현. 유료 런 9 의 로그 줄은 정확히 여기서 죽었다:
    #      `HTTP.RequestError: HTTP.Request: HTTP.Messages.Request: """ POST /rewrite …
    #       Content-Length: 1821 Acce…`
    #    `showerror(::RequestError)` 는 **요청 덤프를 먼저**, `Underlying error:` 를 **맨
    #    뒤**에 찍는다. `bca635f1` 이 첫-줄-만-보던 결함을 고쳐 원인이 문자열 안에는
    #    살아남게 됐지만, 200자 상한이 원인보다 1000자 앞에서 잘렸다.
    local payload = JSON3.write(Dict(
        "tool_name" => "t", "spec" => "s"^400, "impl_name" => "impl_fn!",
        "impl_code" => "function impl_fn!(env)\n" * ("    # pad\n"^120) * "end\n",
        "impl_rejected_why" => "reject:x"))
    @test ncodeunits(payload) > 1800                     # 브리프가 요구한 크기다
    local req = HTTP.Request("POST", "/rewrite",
        ["Content-Type" => "application/json", "Host" => "127.0.0.1:8077",
         "Accept" => "*/*", "User-Agent" => "HTTP.jl/1.10.11",
         "Content-Length" => string(ncodeunits(payload))], payload)
    local e = HTTP.RequestError(req, ErrorException("SENTINEL_DUMP_CAUSE"))

    # (a) 옛 접합 — 원인이 상한 밖이다. **이것이 브리프의 결함 그 자체다.**
    local old_line = _cap_detail(_one_line_rec(sprint(showerror, e)))
    @test !occursin("SENTINEL_DUMP_CAUSE", old_line)
    @test occursin("Content-Length", old_line)           # 남는 것은 우리 요청의 사본뿐
    # 비-0 대조: 원인은 **전문에는** 있다(즉 잃은 것은 상한이지 `showerror` 가 아니다).
    @test occursin("SENTINEL_DUMP_CAUSE", sprint(showerror, e))

    # (b) 새 접합 — 원인이 산다.
    local new_line = _cap_detail(_one_line_rec(_showerror_cause(e)))
    @test occursin("SENTINEL_DUMP_CAUSE", new_line)
    @test occursin("HTTP.RequestError", new_line)        # 어떤 단계의 실패인지도 남는다
    @test !occursin("Content-Length", new_line)          # 요청 덤프는 버렸다

    # (c) 계약: 한 줄이다(기록 파서가 이 줄을 읽는다).
    @test !occursin("\n", new_line) && !occursin("\r", new_line)
    # (d) 계약: 공유 상한을 안 건드렸다 — `steps[i].detail` 과 같은 200 그대로다.
    @test _STEP_DETAIL_CAP == 200
    @test length(new_line) <= _STEP_DETAIL_CAP + 1       # +1 = 말미의 `…`
    # (e) 계약: ASCII 표식만 쓴다(치환이 없으므로 상한 자리가 바이트로 계산 가능하다).
    @test all(isascii, _UNDERLYING_MARK)
    @test _UNDERLYING_MARK == "Underlying error:"

    # (f) 🔴 표식이 없는 예외 가족은 **오늘과 바이트 동일하다**. 그 가족을 재는 게이트가
    #     안 움직인다는 것을 여기서 못박는다(이 파일의 (30b) 가 바로 그 가족이다).
    local plain = ArgumentError("SENTINEL_PLAIN")
    @test _showerror_cause(plain) == sprint(showerror, plain)
end

end

# =============================================================================
# (31) 🔴 B1 (2026-09-05) — 여섯째 축 `n_staging_moved`(기하).
#
# 사건: 손으로 쓴 zone 오라클이 zone 에 막힌 빌드를 `n_closed=270/305`(PROJECT INCOMPLETE)
# → `287/305`(PROJECT COMPLETE) 로 끌어올렸는데 `world_delta_body` 의 **다섯 축이 전부 0**
# 이었다(`docs/superpowers/reports/2026-09-05-zone-oracle-an-advertised-verb-rescues-the-build.md`).
# 원인은 구조적이다: 다섯 축은 전부 배정/스케줄 그래프 위에 있고, zone 수리는 **기하**를
# 편집한다 — `translate_whole_build!`/`_apply_uniform_translation!`/`restage_assembly!`
# (`src/respec/restage_zone.jl`)가 `start_config` 변환과 `env.staging_circles` 를 옮긴다.
# 계측기가 **측정된 양성을 측정된 0 으로** 읽었다(이 레포가 기록한 최악의 실패 모드).
#
# 🔴 이 절이 재는 것은 셋이다:
#   (a) 양성 — 적치원을 옮기는 body 에서 이 축이 **혼자** 움직인다(다섯은 0 이다: 그 다섯 0 이
#       바로 사건의 재현이다).
#   (b) 음성 — 스케줄만 고치는 body 에서 이 축은 `0`("쟀는데 안 움직였다")이다.
#   (c) 삼상 — `staging_circles` 가 없는 env 에서 이 축만 `nothing` 이고 **다섯은 수로 산다**.
#       그것이 "여섯째를 전부-아니면-무 밖에 둔다" 는 결정 그 자체다.
# =============================================================================
@testset "(31) 🔴 B1: 여섯째 축 — 기하 수리가 보인다" begin

@testset "(31a) 양성 — 적치원을 옮기면 그 축만 움직인다 (다섯은 0)" begin
    CB.reset_minted_table!()
    # `live_cache_env()` + 적치원 하나. 생산 타입의 진실원은
    # `PlannerEnv.staging_circles::Dict{AbstractID,LazySets.Ball2}`(`src/route_planning.jl`).
    local staged_env = function ()
        local sched = CB.OperatingSchedule()
        local cache = CB.initialize_planning_cache(sched)
        push!(cache.active_set, 999)
        return (cache = cache, sched = sched,
                active_build_steps = Set{CB.AbstractID}(),
                staging_circles = Dict{CB.AbstractID,Any}(
                    CB.AssemblyID(1) => CB.LazySets.Ball2([0.0, 0.0], 1.0)))
    end
    local env = staged_env()
    # body 의 편집은 `_apply_uniform_translation!` 이 쓰는 자리와 **같은 자리**다
    # (`env.staging_circles[aid] = LazySets.Ball2(...)`) — 아래 (31e) 가 그 문장을 소스에서
    # 못박아 이 픽스처가 실제 수리와 같은 필드를 건드린다는 것을 증거로 만든다.
    local e = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "b1_move_staging!",
        "impl_code" => "function b1_move_staging!(env; dx::Float64 = 5.0)\n" *
                       "    for k in collect(keys(env.staging_circles))\n" *
                       "        env.staging_circles[k] = LazySets.Ball2([dx, 0.0], 1.0)\n" *
                       "    end\n" *
                       "    return (status = :b1_moved,)\nend\n",
        "surface" => "env_param", "reversible" => false,
        "params" => Dict{String,Any}("dx" => Dict{String,Any}("type" => "number")),
        "body_names" => ["b1_move_staging!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "b1_move_staging!",
                                     "args" => Dict{String,Any}("dx" => 5.0))]))
    local m, out
    mktemp() do path, io
        redirect_stdout(io) do
            m = enact_minted_decision!(env, nothing, _dec(e))
        end
        flush(io); out = read(path, String)
    end
    # 전제 — 생성 경로로 실제로 갔고 body 가 돌았다(음성 대조 없이 0 도 1 도 안 읽는다).
    @test m.registered === true && m.verdict === :admit
    @test length(m.steps) == 1 && m.steps[1].status === :b1_moved
    @test Float64(CB.get_center(env.staging_circles[CB.AssemblyID(1)])[1]) == 5.0
    # 🔴 **재는 것.** 사건의 재현: 다섯 축이 전부 0 이다.
    @test m.world_delta !== nothing && m.world_delta_body !== nothing
    @test m.world_delta_body.closed == 0
    @test m.world_delta_body.active == 0
    @test m.world_delta_body.n_edges == 0
    @test m.world_delta_body.n_binding_changed == 0
    @test m.world_delta_body.n_weights_changed == 0
    # 🔴 그런데 여섯째는 움직인다 — 오늘의 계측기가 못 보던 그 편집이다.
    @test m.world_delta_body.n_staging_moved == 1
    @test m.world_delta.n_staging_moved == 1
    # 로그도 그 수를 찍는다(둘 다).
    local wl = [l for l in split(out, "\n") if startswith(l, "[minted] world_delta=")]
    @test length(wl) == 1
    @test occursin("world_delta=closed=0 active=0 n_edges=0 n_binding_changed=0 " *
                   "n_weights_changed=0 n_staging_moved=1", wl[1])
    @test occursin("world_delta_body=closed=0 active=0 n_edges=0 n_binding_changed=0 " *
                   "n_weights_changed=0 n_staging_moved=1", wl[1])
end

@testset "(31b) 음성 — 스케줄만 고치는 body 에서는 `0` 이다 (`nothing` 이 아니다)" begin
    CB.reset_minted_table!()
    local sched = CB.OperatingSchedule()
    local cache = CB.initialize_planning_cache(sched)
    push!(cache.active_set, 999)
    local env = (cache = cache, sched = sched,
                 active_build_steps = Set{CB.AbstractID}(),
                 staging_circles = Dict{CB.AbstractID,Any}(
                     CB.AssemblyID(1) => CB.LazySets.Ball2([0.0, 0.0], 1.0)))
    local e = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "b1_only_weights!",
        "impl_code" => "function b1_only_weights!(env; v::Int = 1)\n" *
                       "    env.sched.weights[v] = 9.25\n" *
                       "    return (status = :b1_w,)\nend\n",
        "surface" => "env_param", "reversible" => false,
        "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
        "body_names" => ["b1_only_weights!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "b1_only_weights!",
                                     "args" => Dict{String,Any}("v" => 3))]))
    local m = enact_minted_decision!(env, nothing, _dec(e))
    @test m.verdict === :admit
    # 🔴 짝지은 비-0 대조: 같은 판에서 **다른 축은 움직인다**. 이 줄이 없으면 아래 0 은
    #    "축이 죽었다" 와 구별되지 않는다.
    @test m.world_delta_body.n_weights_changed == 1
    @test m.world_delta_body.n_staging_moved == 0        # 쟀는데 안 움직였다
    @test m.world_delta_body.n_staging_moved !== nothing # 🔴 0 은 `nothing` 이 아니다
end

@testset "(31c) 🔴 삼상 — `staging_circles` 가 없으면 이 축만 `nothing` 이고 다섯은 산다" begin
    # 🔴 **이 절이 설계 결정 그 자체다.** 여섯째를 앞 다섯과 같은 전부-아니면-무로 뒀다면
    #    `live_cache_env()`(= (10)(11)(15)(26e) 의 픽스처, `staging_circles` 없음)의 지문이
    #    통째로 `nothing` 이 되어 **기하 축을 더한 대가로 기존 다섯이 눈을 감는다.**
    CB.reset_minted_table!()
    local env = live_cache_env()
    @test !hasproperty(env, :staging_circles)          # 전제
    local e = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "b1_nostage!",
        "impl_code" => "function b1_nostage!(env; v::Int = 1)\n" *
                       "    push!(env.cache.closed_set, v)\n" *
                       "    return (status = :b1_ns,)\nend\n",
        "surface" => "env_param", "reversible" => false,
        "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
        "body_names" => ["b1_nostage!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "b1_nostage!",
                                     "args" => Dict{String,Any}("v" => 777))]))
    local m, out
    mktemp() do path, io
        redirect_stdout(io) do
            m = enact_minted_decision!(env, nothing, _dec(e))
        end
        flush(io); out = read(path, String)
    end
    @test m.verdict === :admit
    @test m.world_delta !== nothing                    # 🔴 지문이 살아 있다
    @test m.world_delta.closed == 1                    # 🔴 다섯 축이 **수로** 산다
    @test m.world_delta.n_staging_moved === nothing    # 🔴 이 축만 "못 쟀다"
    # 로그가 셋을 셋으로 나른다 — `0` 이 아니라 "못 쟀다" 라고 찍는다.
    local wl = [l for l in split(out, "\n") if startswith(l, "[minted] world_delta=")]
    @test length(wl) == 1
    @test occursin("n_staging_moved=n/a(not measured)", wl[1])
    @test !occursin("n_staging_moved=0", wl[1])
end

@testset "(31d) `_staging_snapshot`/`_world_delta` 단위 — 못 읽는 기하는 축 하나만 끈다" begin
    # 축 자체가 못 읽는 모양들.
    @test _staging_snapshot(nothing) === nothing
    @test _staging_snapshot("not a dict") === nothing          # `length` 가 조용히 성공하는 모양
    @test _staging_snapshot(Dict(1 => "not a ball")) === nothing
    @test _staging_snapshot(Dict{Symbol,Any}()) == Dict{Any,NTuple{3,Float64}}()  # 비었어도 **쟀다**
    # 🔴 그 모양이 와도 **지문은 산다** — 축 하나만 `nothing` 이다.
    local sched = CB.OperatingSchedule()
    local cache = CB.initialize_planning_cache(sched)
    local bad_geom = (cache = cache, sched = sched,
                      active_build_steps = Set{CB.AbstractID}(),
                      staging_circles = Dict(1 => "not a ball"))
    local d = _world_digest(bad_geom)
    @test d !== nothing                                        # 🔴 다섯 축은 그대로 잰다
    @test d.staging === nothing
    @test d.closed == 0
    # 차분 쪽 삼상·계수.
    local base = (closed = 0, active = 0, n_edges = 0, binding = Dict{Int,Int}(),
                  weights = Dict{Int,Float64}(),
                  staging = Dict{Any,NTuple{3,Float64}}(1 => (0.0, 0.0, 1.0)))
    local moved = (closed = 0, active = 0, n_edges = 0, binding = Dict{Int,Int}(),
                   weights = Dict{Int,Float64}(),
                   staging = Dict{Any,NTuple{3,Float64}}(1 => (5.0, 0.0, 1.0),
                                                         2 => (0.0, 0.0, 1.0)))
    @test _world_delta(base, base).n_staging_moved == 0
    @test _world_delta(base, moved).n_staging_moved == 2   # 값 변경 1 + 새 키 1
    @test _world_delta(moved, base).n_staging_moved == 2   # 값 변경 1 + 사라진 키 1
    # 반지름만 바뀐 판도 기하 변화다.
    local grown = (closed = 0, active = 0, n_edges = 0, binding = Dict{Int,Int}(),
                   weights = Dict{Int,Float64}(),
                   staging = Dict{Any,NTuple{3,Float64}}(1 => (0.0, 0.0, 2.0)))
    @test _world_delta(base, grown).n_staging_moved == 1
    # 🔴 `!=` 가 아니라 `!isequal` — NaN 좌표가 매 판 "움직였다" 로 세면 안 된다.
    local nan1 = (closed = 0, active = 0, n_edges = 0, binding = Dict{Int,Int}(),
                  weights = Dict{Int,Float64}(),
                  staging = Dict{Any,NTuple{3,Float64}}(1 => (NaN, 0.0, 1.0)))
    local nan2 = (closed = 0, active = 0, n_edges = 0, binding = Dict{Int,Int}(),
                  weights = Dict{Int,Float64}(),
                  staging = Dict{Any,NTuple{3,Float64}}(1 => (NaN, 0.0, 1.0)))
    @test _world_delta(nan1, nan2).n_staging_moved == 0
    # 한쪽만 기하를 못 쟀으면 이 축은 `nothing` 이고 나머지 다섯은 수다.
    local blind = (closed = 1, active = 0, n_edges = 0, binding = Dict{Int,Int}(),
                   weights = Dict{Int,Float64}(), staging = nothing)
    @test _world_delta(base, blind).n_staging_moved === nothing
    @test _world_delta(base, blind).closed == 1
    # 로그 렌더도 셋을 셋으로 나른다(리터럴의 진실원은 `_world_delta_str` 하나다 — m3/m4).
    @test occursin("n_staging_moved=2", _world_delta_str(_world_delta(base, moved)))
    @test occursin("n_staging_moved=n/a(not measured)",
                   _world_delta_str(_world_delta(base, blind)))
end

@testset "(31e) 🔴 이 축이 **실제 zone 수리가 쓰는 필드**를 읽는다 (소스 결속)" begin
    # 🔴 픽스처가 진짜 수리와 같은 자리를 건드린다는 것을 증거로 만든다. 데모를 돌리지 않고
    #    할 수 있는 가장 강한 결속이고, 이 파일이 이미 쓰는 관용구다((26d) 의 소스 단언).
    local rz = read(normpath(joinpath(@__DIR__, "..", "src", "respec", "restage_zone.jl")), String)
    # 통째 이동(Phase B) — `translate_whole_build!` 이 부르는 유일한 편집 함수.
    @test occursin("function _apply_uniform_translation!", rz)
    @test occursin("env.staging_circles[aid] =", rz)
    # 조립체별 이동 — `restage_all_blocked!` 이 반복해서 부르는 함수.
    @test occursin("function restage_assembly!", rz)
    @test occursin("env.staging_circles[assembly_id] = LazySets.Ball2(c1, R)", rz)
    # 🔴 그리고 다섯 축 중 어느 것도 그 함수들 안에 없다: zone 수리는 `closed_set` 도
    #    `active_build_steps` 도 `sched.graph` 의 간선도 `weights` 도 안 건드린다.
    local body = rz[findfirst("function _apply_uniform_translation!", rz)[1]:end]
    body = body[1:findfirst("\nend", body)[1]]
    @test !occursin("closed_set", body)
    @test !occursin("active_build_steps", body)
    @test !occursin("weights", body)
end

end

# =============================================================================
# (32) 🔴 B1 판정 (2026-09-05) — 오라클 런의 `applied` 가 `nothing` 이었던 이유, 그리고
#      그것을 **그대로 둔다**는 판정을 못박는다.
#
# 사실: zone 오라클이 `:translated` 를 냈는데 `applied === nothing` 이었다. 원인은
# `_step_applied`(`src/respec/minted_tool.jl`)의 판정 1 — **생성 원시면 `nothing`** 이다.
#
# 🔴 판정: 그대로 둔다. `:translated`/`:restaged_all` 을 어떤 표에 넣어 값으로 올리는 길은
#   둘 다 틀렸다.
#   (a) 생성 이름을 `SILENT_SUCCESS_STATUSES` 에 못 넣는다 — 이름이 런타임에 주조되므로
#       키가 존재할 수 없다(그 상수의 docstring 이 그 정적성을 소유한다).
#   (b) "status 를 등록 행에 **선언**하게 한다" 는 길은 `applied` 를 **모델의 자기신고**로
#       만든다. body 는 `translate_whole_build!` 를 부르지 않고도 `(status = :translated,)`
#       를 리터럴로 낼 수 있다 — 그러면 유료 런의 성공률이 모델이 고른 심볼의 함수가 된다.
#       그것이 이 태스크가 금지한 **거짓 양성 제조**다.
#   ✅ 대신 같은 사실을 **세계에서** 재는 자리를 이 커밋이 열었다: `n_staging_moved`(31).
#      `applied` 는 "못 쟀다" 로 정직하게 남고, "세계가 바뀌었나" 는 자기신고가 아닌 축이
#      대답한다. `nothing` 을 성공값으로 접지 않는 것이 이 판정의 전부다.
# =============================================================================
@testset "(32) 🔴 B1 판정: 생성 원시의 `:translated` 는 `applied=nothing` 으로 남는다" begin
    CB.reset_minted_table!()
    # ---- 대조군: 손으로 적은 어휘에서는 같은 status 가 **참**이다(표가 공허하지 않다) ----
    @test haskey(CB.SILENT_SUCCESS_STATUSES, "translate_whole_build")
    @test !(:translated in CB.SILENT_SUCCESS_STATUSES["translate_whole_build"])
    @test CB._step_applied("translate_whole_build", :translated) === true
    @test CB._step_applied("translate_whole_build", :already_clear) === false
    # ---- 재는 것: **생성** 원시가 같은 status 를 내면 `nothing` 이다 ----------------------
    local env = live_cache_env()
    local e = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "b1_zone_like!",
        "impl_code" => "function b1_zone_like!(env; v::Int = 1)\n" *
                       "    return (status = :translated,)\nend\n",
        "surface" => "env_param", "reversible" => false,
        "params" => Dict{String,Any}("v" => Dict{String,Any}("type" => "integer")),
        "body_names" => ["b1_zone_like!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "b1_zone_like!",
                                     "args" => Dict{String,Any}("v" => 1))]))
    local m = enact_minted_decision!(env, nothing, _dec(e))
    @test m.verdict === :admit
    @test length(m.steps) == 1 && m.steps[1].status === :translated   # 전제: 그 status 다
    # 🔴 삼상. `true` 도 `false` 도 아니다 — "못 쟀다" 다.
    @test m.applied === nothing
    @test m.applied !== true
    @test m.applied !== false
    # 🔴 그리고 그 이유가 기록 줄에 **글자로** 남는다(조용한 `nothing` 이 아니다).
    @test occursin("status 어휘가 선언돼 있지 않다", m.reason)
end


# =============================================================================
# D17b (2026-09-05) — 되먹임 채널을 **등록 거절**에서 **집행 예외**로 넓힌다.
#
# 재는 명제: `CB.enact_minted!` 이 돌려준 판의 마지막 걸음이 `:threw` 이면, 그 예외
# 메시지가 `/rewrite` 로 나가고(같은 전선 계약 — 다섯 키), 고친 body 가 재등록·재집행되며,
# 그 사실이 `[minted] lane=present` 줄의 **`enact_retry=`** 한 칸으로 첫-시도 성공판과
# 구별된다. 그리고 세계가 더러울 수 있는 판에서는 **거절**되고 그 거절이 사유별로 남는다.
#
# 🔴 유료 호출 0건이다 — 위 `_RW_SERVER`(루프백) 하나만 쓴다. (0) 이 그 사실을 못박는다.
# =============================================================================

"`live_cache_env()` + `staging_circles`. 여섯째 축까지 **재는** env — 게이트가 그것을 요구한다."
function retry_env()
    local e = live_cache_env()
    return (cache = e.cache, sched = e.sched,
            active_build_steps = e.active_build_steps,
            staging_circles = Dict{Symbol,Any}())
end

"stdout 전문을 잡는다(이 파일의 다른 게이트와 같은 관용구)."
function _d17b_cap(f)
    local out
    mktemp() do path, io
        redirect_stdout(io) do; f(); end
        flush(io); out = read(path, String)
    end
    return out
end

"`MINTED_RE` 가 고르는 그 줄 — 리터럴 `[minted] lane=present` 로 **시작**하는 줄."
_d17b_rec(out) = (local r = [l for l in split(out, "\n")
                             if startswith(l, "[minted] lane=present")];
                  length(r) == 1 ? r[1] : "")

"한 원시짜리 합성 레인. `code` 는 `nm` 을 정의해야 한다."
_d17b_lane(nm, code; params = Dict{String,Any}("goal" => Dict{String,Any}("type" => "string")),
           args = Dict{String,Any}("goal" => "goal1")) = _lane(Dict{String,Any}(
    "synthesis_event" => true, "ran" => true, "error" => nothing,
    "tool_name" => "T", "impl_name" => nm, "impl_code" => code,
    "surface" => "env_param", "reversible" => false,
    "params" => params, "body_names" => [nm], "wrote" => true,
    "calls" => [Dict{String,Any}("primitive" => nm, "args" => args)]))

# 던지지만 세계는 **안 건드리는** body. 유료 런 2·4·5·7 이 죽은 모양 그대로:
# 지어낸 식별자를 조회하다 죽는다.
_d17b_boom(nm) = "function $(nm)(env; goal = \"g\")\n" *
                 "    error(\"KeyError: key \\\"\$(goal)\\\" not found\")\n" *
                 "end\n"

@testset "(33) 🔴 D17b: 집행 예외가 되먹임으로 나가고 고친 body 가 다시 집행된다" begin
    CB.reset_minted_table!()
    _RW_HITS[] = 0; _RW_LAST[] = nothing
    # 🔴 고친 body 는 **같은 이름**으로 돌아온다 — `RewriteToolImpl` 의 "Change nothing
    #    else" 가 그 모양이고, 그것이 `allow_redefine` 이 없으면 채널을 죽이는 자리다.
    _RW_RESPONSES[:d17b_same] = () -> _rw_fix("d17b_boom_a!")
    _RW_MODE[] = :d17b_same
    local m = enact_minted_decision!(retry_env(), nothing,
                  _dec(_d17b_lane("d17b_boom_a!", _d17b_boom("d17b_boom_a!"))))
    # ---- 되먹임이 실제로 나갔다 ------------------------------------------------------
    @test _RW_HITS[] == 1
    @test m.enact_retry === :retried
    # ---- 전선 계약: **두 번째 철자를 만들지 않았다** — D17 과 같은 다섯 키다 ------------
    local body = _RW_LAST[]
    @test body !== nothing
    # 🔴 2026-09-22: 원장 신원 다섯이 더해졌다(record_id·parent_record_id·attempt·trigger·
    #    run_ctx). 옛 다섯의 **철자는 그대로**다 — 두 번째 철자를 만들지 않는다는 명제는 유지.
    @test Set(String.(keys(body))) ==
          Set(["tool_name", "spec", "impl_name", "impl_code", "impl_rejected_why",
               "record_id", "parent_record_id", "attempt", "trigger", "run_ctx"])
    @test body.attempt == 2
    @test String(body.trigger) == "threw"
    # ---- 사유는 **예외 메시지 자신**이다 (모양-맞추기가 못 닫는 가족을 닫는 자리) --------
    @test startswith(String(body.impl_rejected_why), "enact_threw:d17b_boom_a!: ")
    @test occursin("KeyError", String(body.impl_rejected_why))
    # ⚠️ **실측된 상호작용(2026-09-05)** — 여기 원래 `occursin("goal1", …)` 를 적었고
    #    빨개졌다. 지어낸 `goal="goal1"` 은 인자 채널 필터(`86b5be25`)가 **이미 버렸고**
    #    body 는 선언된 기본값 `"g"` 로 떨어진다(같은 런의 `dropped fabricated identifier`
    #    줄이 그 사실을 찍는다). 그래서 예외가 이름 붙이는 것은 모델이 쓴 값이 아니라
    #    **body 가 실제로 본 값**이다 — 그리고 그것이 옳다: agent-3 이 고쳐야 하는 자리는
    #    실행된 코드가 실패한 자리다.
    @test occursin("key \"g\" not found", String(body.impl_rejected_why))
    # ---- 두 번째 시도가 실제로 굴렀다 --------------------------------------------------
    @test m.verdict === :admit
    @test length(m.steps) == 1 && m.steps[1].status === :rw_ok
    @test m.partial === false                 # 두 번째 body 는 안 던졌다
    @test m.registered === true
    @test m.impl_rejected_why === nothing
    _RW_MODE[] = :off
end

@testset "(34) 🔴 D17b: 재시도판은 기록 줄에서 첫-시도 성공판과 **구별된다**" begin
    CB.reset_minted_table!()
    _RW_HITS[] = 0
    _RW_RESPONSES[:d17b_same_b] = () -> _rw_fix("d17b_boom_b!")
    _RW_MODE[] = :d17b_same_b
    local retried = _d17b_cap(() -> enact_minted_decision!(retry_env(), nothing,
                        _dec(_d17b_lane("d17b_boom_b!", _d17b_boom("d17b_boom_b!")))))
    _RW_MODE[] = :off
    # 첫 시도에 성공하는 판(되먹임을 안 탄다).
    CB.reset_minted_table!()
    # 🔴 **2026-09-05 (D17c) 로 이 대조군이 바뀌었다 — 그리고 그 변경이 이 파일의 측정이다.**
    #    옛 body 는 status 만 돌려주고 세계를 안 건드렸다 = **잰 무동작**이다. D17c 가 그것을
    #    되먹임 사건으로 만들었으므로(정본은 `_noop_gate`), 그 body 는 더 이상 "첫 시도에
    #    깨끗하게 성공한 판" 이 아니다 — 실측하면 `enact_retry=noop_roundtrip_failed` 가 된다.
    #    "첫 시도 성공" 의 대조군은 이제 **잰 축 하나를 실제로 움직이는** body 여야 한다.
    local clean = _d17b_cap(() -> enact_minted_decision!(retry_env(), nothing,
                      _dec(_d17b_lane("d17b_clean_b!",
                          "function d17b_clean_b!(env; goal = \"g\")\n" *
                          "    push!(env.active_build_steps, ConstructionBots.RobotID(7))\n" *
                          "    return (status = :rw_ok, goal = goal)\nend\n"))))
    # 🔴 두 줄의 **나머지가 같다**: 같은 verdict, 같은 status, 같은 registered.
    local rl = _d17b_rec(retried); local cl = _d17b_rec(clean)
    @test !isempty(rl) && !isempty(cl)
    @test occursin("verdict=admit", rl) && occursin("verdict=admit", cl)
    @test occursin("steps=[d17b_boom_b!:rw_ok]", rl)
    @test occursin("steps=[d17b_clean_b!:rw_ok]", cl)
    # 🔴 **가르는 것은 이 한 칸뿐이다.** 없으면 사다리가 둘을 같은 판으로 센다.
    @test occursin("enact_retry=retried", rl)
    @test occursin("enact_retry=n/a", cl)
    @test !occursin("enact_retry=retried", cl)
    # 🔴 첫 시도의 걸음은 **어디에도 안 사라진다** — 별도 진단 줄이 나른다.
    @test occursin("[minted] enact_retry: 되먹임 1회 — 첫 시도 steps=[", retried)
    @test occursin("d17b_boom_b!:threw", retried)
    # 🔴 그런데 그 줄은 `MINTED_RE`(`lane=present` 로 **시작**) 에 안 걸린다.
    @test !occursin("[minted] enact_retry:", rl)
    # 🔴 그리고 `lane=present` 줄은 **정확히 하나**다 — 재시도가 기록 줄을 둘로 만들지 않는다.
    @test count(l -> startswith(l, "[minted] lane=present"), split(retried, "\n")) == 1
end

@testset "(35) 🔴 D17b 판정: 더러울 수 있는 세계에서는 **거절**하고, 거절을 사유별로 남긴다" begin
    # ---- (a) 던진 단계가 첫 단계가 아니다 = 앞선 원시가 확실히 끝까지 돌았다 -------------
    CB.reset_minted_table!()
    _RW_HITS[] = 0
    @test CB.register_minted_primitive!(
        name = "d17b_first_ok!", code = "function d17b_first_ok!(env; goal = \"g\")\n" *
            "    return (status = :rw_ok, goal = goal)\nend\n",
        params = Dict{String,Any}("goal" => Dict{String,Any}("type" => "string")),
        surface = "env_param", reversible = false) === nothing
    local two = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "d17b_second_boom!",
        "impl_code" => _d17b_boom("d17b_second_boom!"),
        "surface" => "env_param", "reversible" => false,
        "params" => Dict{String,Any}("goal" => Dict{String,Any}("type" => "string")),
        "body_names" => ["d17b_first_ok!", "d17b_second_boom!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "d17b_first_ok!",
                                     "args" => Dict{String,Any}("goal" => "g")),
                    Dict{String,Any}("primitive" => "d17b_second_boom!",
                                     "args" => Dict{String,Any}("goal" => "goal2"))]))
    local ma = enact_minted_decision!(retry_env(), nothing, _dec(two))
    @test length(ma.steps) == 2 && ma.steps[2].status === :threw
    @test ma.enact_retry === :refused_not_first_step
    @test _RW_HITS[] == 0        # 🔴 유료 호출이 **안 나갔다** — 거절은 왕복 앞이다

    # ---- (b) 던진 body 가 세계를 **실제로 바꿨다** ---------------------------------------
    CB.reset_minted_table!()
    _RW_HITS[] = 0
    local dirty = _d17b_lane("d17b_dirty_boom!",
        "function d17b_dirty_boom!(env; goal = \"g\")\n" *
        "    push!(env.active_build_steps, ConstructionBots.RobotID(7))\n" *
        "    error(\"KeyError: key \\\"\$(goal)\\\" not found\")\nend\n")
    local mb = enact_minted_decision!(retry_env(), nothing, _dec(dirty))
    @test length(mb.steps) == 1 && mb.steps[1].status === :threw
    @test mb.world_delta_body !== nothing && mb.world_delta_body.active == 1
    @test mb.enact_retry === :refused_world_changed
    @test _RW_HITS[] == 0

    # ---- (c) 지문을 못 찍었다 = **못 쟀다**. 못 잰 것을 깨끗하다고 안 읽는다 --------------
    CB.reset_minted_table!()
    _RW_HITS[] = 0
    # `live_cache_env()` 에는 `staging_circles` 가 없다 → 여섯째 축이 `nothing` 이다.
    local mc = enact_minted_decision!(live_cache_env(), nothing,
                   _dec(_d17b_lane("d17b_unmeas_boom!", _d17b_boom("d17b_unmeas_boom!"))))
    @test mc.world_delta_body !== nothing
    @test mc.world_delta_body.n_staging_moved === nothing
    @test mc.enact_retry === :refused_world_unmeasured
    @test _RW_HITS[] == 0

    # 🔴 셋은 **서로 다른 심볼**이다 — 하나로 뭉개면 "왜 안 갔나" 가 로그에서 사라진다.
    @test length(Set([ma.enact_retry, mb.enact_retry, mc.enact_retry])) == 3
end

@testset "(36) 🔴 D17b 삼상: 시도 안 했다 / 왕복이 실패했다 / 고친 body 가 왔다" begin
    # ---- 시도 안 했다: 집행이 안 던졌다 -------------------------------------------------
    CB.reset_minted_table!()
    _RW_HITS[] = 0; _RW_MODE[] = :off
    # 🔴 이 body 는 **세계를 움직인다**(D17c 로 대조군이 바뀌었다 — (34) 의 같은 문단이
    #    근거를 소유한다). 안 움직이면 그것은 "시도 안 했다" 가 아니라 **잰 무동작**이고,
    #    D17c 의 채널이 정당하게 발화한다.
    local ok = enact_minted_decision!(retry_env(), nothing,
                   _dec(_d17b_lane("d17b_tri_ok!",
                       "function d17b_tri_ok!(env; goal = \"g\")\n" *
                       "    push!(env.active_build_steps, ConstructionBots.RobotID(7))\n" *
                       "    return (status = :rw_ok, goal = goal)\nend\n")))
    @test ok.enact_retry === nothing            # 삼상의 첫째 — `n/a`
    @test _RW_HITS[] == 0

    # ---- 왕복이 실패했다: 서버가 404 를 낸다(모드 `:off`) --------------------------------
    CB.reset_minted_table!()
    _RW_HITS[] = 0
    local rt = enact_minted_decision!(retry_env(), nothing,
                   _dec(_d17b_lane("d17b_tri_rt!", _d17b_boom("d17b_tri_rt!"))))
    @test _RW_HITS[] == 1                       # 🔴 실제로 나갔다(비-0 대조)
    @test rt.enact_retry === :roundtrip_failed  # 삼상의 둘째
    @test rt.verdict === :admit                 # 원래 판이 그대로 남는다
    @test rt.partial === true
    @test length(rt.steps) == 1 && rt.steps[1].status === :threw

    # ---- 고친 body 가 왔는데 **재등록이 거절했다** ---------------------------------------
    CB.reset_minted_table!()
    _RW_HITS[] = 0; _RW_MODE[] = :bad_surface   # `surface: 7` — 본 경로와 같은 사유 이름
    local rj = enact_minted_decision!(retry_env(), nothing,
                   _dec(_d17b_lane("d17b_tri_rj!", _d17b_boom("d17b_tri_rj!"))))
    @test _RW_HITS[] == 1
    @test rj.enact_retry === :rejected
    @test rj.impl_rejected_why == "reject:surface_not_a_string:Int64"
    _RW_MODE[] = :off

    # ---- 그리고 셋 + `retried` 는 서로 다르다 -------------------------------------------
    @test length(Set([ok.enact_retry, rt.enact_retry, rj.enact_retry, :retried])) == 4
end

@testset "(37) 🔴 D17b: `allow_redefine` 은 **좁다** — 이 채널 밖에서는 아무것도 안 바뀐다" begin
    CB.reset_minted_table!()
    local code = "function d17b_narrow!(env; goal = \"g\")\n    return (status = :rw_ok)\nend\n"
    local p = Dict{String,Any}("goal" => Dict{String,Any}("type" => "string"))
    @test CB.register_minted_primitive!(name = "d17b_narrow!", code = code,
              params = p, surface = "env_param") === nothing
    # 🔴 기본값(`false`)에서는 오늘과 **바이트 동일**하다.
    local w = CB.register_minted_primitive!(name = "d17b_narrow!", code = code,
                  params = p, surface = "env_param")
    @test w !== nothing && startswith(w, "reject:impl_name_already_minted:")
    # 🔴 켜면 통과하고, 그때도 **다른 충돌 갈래는 안 열린다**(D6 신호가 안 샌다).
    @test CB.register_minted_primitive!(name = "d17b_narrow!", code = code,
              params = p, surface = "env_param", allow_redefine = true) === nothing
    # D6: 감춰진 능력 이름은 `allow_redefine` 을 켜도 그대로 거절이다 —
    # `_MINTED_EVER` 멤버가 아니므로 첫 갈래가 안 걸리고 충돌 셋이 그대로 판정한다.
    local hid = CB.register_minted_primitive!(
        name = "release_pending_assignments!",
        code = "function release_pending_assignments!(env; x = 1)\n    return (status = :ok,)\nend\n",
        params = Dict{String,Any}(), surface = "sched", allow_redefine = true)
    @test hid !== nothing
    @test occursin("impl_name_exists", hid)
    @test !occursin("already_minted", hid)
end


# =============================================================================
# D17c (2026-09-05) — 되먹임 채널을 **잰 무동작**까지 넓힌다.
#
# 재는 명제: body 가 **안 던지고** 끝났는데 `world_delta_body` 의 여섯 축이 **전부 잰 0**
# 이면, 그 관측이 같은 전선 계약(다섯 키)으로 `/rewrite` 에 실려 나가고 고친 body 가
# 재등록·재집행되며, 그 사실이 `enact_retry=noop_*` 로 **던져서 되먹인 판과 구별된다**.
# 그리고 (a) 못 잰 판은 되먹이지 않고 (b) 세계를 **움직인** body 는 되먹이지 않는다.
#
# 🔴 유료 호출 0건 — `_RW_SERVER`(루프백) 하나만 쓴다.
# 🔴 유료 런 8 (2026-09-05)이 죽은 자리다: body 가 zone 키를 좌표에서 **지어 만들고**
#    원시의 반환 status 를 **올바르게** 검사한 뒤 `:failure` 를 돌려줬다 — 예외가 없으니
#    D17b 의 채널이 한 번도 안 발화했고 기록은 `verdict=admit partial=false
#    enact_retry=n/a` 에 여섯 축 전부 0 이었다.
# =============================================================================

"세계를 **안 건드리고** status 만 돌려주는 body = 유료 런 8 의 모양."
_d17c_noop(nm; status = ":failure") =
    "function $(nm)(env; goal = \"g\")\n" *
    "    return (status = $(status), goal = goal)\nend\n"

"🔴 음성 대조용. 잰 축 하나(`active`)를 **실제로** 움직인다."
_d17c_moves(nm) =
    "function $(nm)(env; goal = \"g\")\n" *
    "    push!(env.active_build_steps, ConstructionBots.RobotID(7))\n" *
    "    return (status = :moved, goal = goal)\nend\n"

@testset "(38) 🔴 D17c: 잰 무동작이 되먹임으로 나가고 고친 body 가 다시 집행된다" begin
    CB.reset_minted_table!()
    _RW_HITS[] = 0; _RW_LAST[] = nothing
    _RW_RESPONSES[:d17c_same] = () -> _rw_fix("d17c_noop_a!")
    _RW_MODE[] = :d17c_same
    local m = enact_minted_decision!(retry_env(), nothing,
                  _dec(_d17b_lane("d17c_noop_a!", _d17c_noop("d17c_noop_a!"))))
    # ---- 되먹임이 실제로 나갔다 — 예외가 **하나도 없는** 판에서 -------------------------
    @test _RW_HITS[] == 1
    @test m.enact_retry === :noop_retried
    # 🔴 두 트리거가 안 뭉개진다.
    @test m.enact_retry !== :retried
    # ---- 전선 계약: **두 번째 철자를 만들지 않았다** — D17/D17b 와 같은 다섯 키다 --------
    local body = _RW_LAST[]
    @test body !== nothing
    # 🔴 2026-09-22: (33) 과 같은 열 키 — 옛 다섯의 철자는 그대로, 원장 신원 다섯이 더해졌다.
    @test Set(String.(keys(body))) ==
          Set(["tool_name", "spec", "impl_name", "impl_code", "impl_rejected_why",
               "record_id", "parent_record_id", "attempt", "trigger", "run_ctx"])
    @test String(body.trigger) == "noop"
    @test startswith(String(body.impl_rejected_why), "enact_noop:")
    # 🔴 `enact_threw:` 접두가 **아니다** — agent-3 이 두 사건을 접두로 가른다.
    @test !startswith(String(body.impl_rejected_why), "enact_threw:")
    # ---- 두 번째 시도가 실제로 굴렀다 --------------------------------------------------
    @test m.verdict === :admit
    @test length(m.steps) == 1 && m.steps[1].status === :rw_ok
    # 🔴 **상한 1 이 구조로 지켜진다.** 고친 body(`_rw_fix`)도 세계를 안 건드리는
    #    **무동작**이다 — 그런데도 왕복은 여전히 하나다(두 번째 결과는 되먹이지 않는다).
    @test m.world_delta_body !== nothing
    @test _wd_is_zero(m.world_delta_body)      # 두 번째도 잰 0 이다(전제)
    @test _RW_HITS[] == 1                      # 🔴 그래도 왕복은 **하나**다
    _RW_MODE[] = :off
end

@testset "(39) 🔴 D17c: 되먹임 문장은 **관측만** 말한다 — 처방을 한 글자도 안 말한다" begin
    # 🔴 이 게이트가 이 태스크의 실험적 유효성을 지킨다. 모델은 **무엇을 해야 하는지 스스로
    #    알아내야** 한다 — 우리가 동사를 이름 붙이면 측정하는 것이 모델이 아니라 우리다.
    local fake_r = (steps = [(name = "ZoneBypassTool!", status = :failure,
                              detail = nothing)],)
    local wdb = (closed = 0, active = 0, n_edges = 0, n_binding_changed = 0,
                 n_weights_changed = 0, n_staging_moved = 0)
    local msg = _noop_feedback_reason(fake_r, wdb)
    # ---- 관측 넷이 전부 있다 (그리고 전부 **잰 것**이다) --------------------------------
    @test startswith(msg, "enact_noop: ")
    @test occursin("ran to completion and raised no error", msg)
    @test occursin("ZoneBypassTool!=failure", msg)       # 모델 자신의 반환 status
    # 🔴 축의 글자는 기록 줄과 **같은 렌더러**가 낸다 — 두 벌이 갈릴 수 없다.
    @test occursin(_wd_axes_str(wdb), msg)
    @test occursin("closed=0 active=0 n_edges=0 n_binding_changed=0 " *
                   "n_weights_changed=0 n_staging_moved=0", msg)
    # ---- 헤지 둘: 하한이라는 것, 그리고 **여섯 축이 세계의 전부가 아니라는 것** ----------
    @test occursin("n_binding_changed is a lower bound", msg)
    @test occursin("only part of the world that was measured", msg)
    @test occursin("not a claim that nothing at all happened", msg)
    # ---- 🔴 금지: 처방·힌트·`expressible` --------------------------------------------
    for w in ("restriction_zones", "expressible", "enumerate", "should", "must",
              "instead", "escalat", "try ", "you can", "available")
        @test !occursin(w, msg)
    end
    # ---- 🔴 어휘 게이트: **내보낸 이름을 하나도 안 부른다** ------------------------------
    local exported = Set{String}()
    for n in names(CB)
        isdefined(CB, n) || continue
        local v = getfield(CB, n)
        (v isa Function || v isa Type) && push!(exported, string(n))
    end
    # 대조: 표가 공허하지 않고, 이 사건이 실제로 쓰고 싶어했을 이름이 그 안에 있다.
    @test length(exported) > 100
    @test "restriction_zones" in exported
    local toks = Set(String[mm.match for mm in
                            eachmatch(r"[A-Za-z_][A-Za-z0-9_!]*", msg)])
    @test isempty(intersect(toks, exported))
    # 🔴 음성 대조: 그 교집합 검사가 **공허하지 않다** — 이름을 하나 심으면 잡힌다.
    @test !isempty(intersect(
        Set(String[mm.match for mm in eachmatch(r"[A-Za-z_][A-Za-z0-9_!]*",
                                                msg * " restriction_zones")]), exported))
end

@testset "(40) 🔴 D17c 판정: 못 잰 판은 안 되먹이고, **세계를 움직인 body 는 안 되먹인다**" begin
    # ---- (a) 못 쟀다. 🔴 못 잰 것을 두고 "너는 아무것도 안 바꿨다" 고 말하지 않는다 -------
    CB.reset_minted_table!(); _RW_HITS[] = 0; _RW_MODE[] = :off
    # `live_cache_env()` 에는 `staging_circles` 가 없다 → 여섯째 축이 `nothing` 이다.
    local mu = enact_minted_decision!(live_cache_env(), nothing,
                   _dec(_d17b_lane("d17c_unmeas!", _d17c_noop("d17c_unmeas!"))))
    @test mu.world_delta_body !== nothing
    @test mu.world_delta_body.n_staging_moved === nothing
    @test mu.enact_retry === :noop_refused_unmeasured
    @test _RW_HITS[] == 0                    # 🔴 왕복이 **안 나갔다**
    # 🔴 그리고 그 값은 `n/a`(트리거 없음)와 **다른 값**이다 — 히스토그램이 참이 되려면.
    @test mu.enact_retry !== nothing

    # ---- (b) 🔴 **음성 대조**: 세계를 움직인 body 는 재시도되지 않는다 --------------------
    CB.reset_minted_table!(); _RW_HITS[] = 0
    # 서버는 **살아 있다**(응답을 등록해 둔다) — 그래도 부르지 않는다는 것이 이 대조의 요점.
    _RW_RESPONSES[:d17c_never] = () -> _rw_fix("d17c_never!")
    _RW_MODE[] = :d17c_never
    local mv = enact_minted_decision!(retry_env(), nothing,
                   _dec(_d17b_lane("d17c_moves!", _d17c_moves("d17c_moves!"))))
    @test mv.world_delta_body !== nothing && mv.world_delta_body.active == 1
    @test !_wd_is_zero(mv.world_delta_body)          # 전제: 정말로 움직였다
    @test mv.enact_retry === nothing                 # `n/a` — 트리거가 아예 없다
    @test _RW_HITS[] == 0                            # 🔴 유료 왕복이 **안 나갔다**
    _RW_MODE[] = :off

    # ---- (c) 게이트 단위: 걸음이 없으면 "무동작" 이 아니라 **안 불렀다** ------------------
    local zero6 = (closed = 0, active = 0, n_edges = 0, n_binding_changed = 0,
                   n_weights_changed = 0, n_staging_moved = 0)
    @test _noop_gate((steps = NamedTuple[],), zero6) === :none
    @test _noop_gate((steps = [(name = "x!", status = :ok)],), zero6) === :ok
    # 던진 걸음이 하나라도 있으면 이 채널이 **비켜선다**(왕복이 둘이 되지 않는다).
    @test _noop_gate((steps = [(name = "x!", status = :threw)],), zero6) === :none
    @test _noop_gate((steps = [(name = "x!", status = :ok)],), nothing) ===
          :noop_refused_unmeasured
    @test _noop_gate((steps = [(name = "x!", status = :ok)],),
                     (closed = 0, active = 0, n_edges = 0, n_binding_changed = 0,
                      n_weights_changed = 0, n_staging_moved = nothing)) ===
          :noop_refused_unmeasured
    @test _noop_gate((steps = [(name = "x!", status = :ok)],),
                     (closed = 1, active = 0, n_edges = 0, n_binding_changed = 0,
                      n_weights_changed = 0, n_staging_moved = 0)) === :none

    # 🔴 셋은 서로 다른 값이다 — 하나로 뭉개면 "왜 안 갔나" 가 로그에서 사라진다.
    @test length(Set([mu.enact_retry, mv.enact_retry, :noop_retried])) == 3
end

@testset "(41) 🔴 D17c 사상: 기록 줄이 **두 트리거**를 가른다" begin
    # ---- 잰 무동작으로 되먹인 판 --------------------------------------------------------
    CB.reset_minted_table!(); _RW_HITS[] = 0
    _RW_RESPONSES[:d17c_rec] = () -> _rw_fix("d17c_rec!")
    _RW_MODE[] = :d17c_rec
    local noop_out = _d17b_cap(() -> enact_minted_decision!(retry_env(), nothing,
                         _dec(_d17b_lane("d17c_rec!", _d17c_noop("d17c_rec!")))))
    # ---- 던져서 되먹인 판 ----------------------------------------------------------------
    CB.reset_minted_table!()
    _RW_RESPONSES[:d17c_thr] = () -> _rw_fix("d17c_thr!")
    _RW_MODE[] = :d17c_thr
    local threw_out = _d17b_cap(() -> enact_minted_decision!(retry_env(), nothing,
                          _dec(_d17b_lane("d17c_thr!", _d17b_boom("d17c_thr!")))))
    _RW_MODE[] = :off
    # ---- 첫 시도에 **세계를 움직여** 성공한 판 -------------------------------------------
    CB.reset_minted_table!()
    local clean_out = _d17b_cap(() -> enact_minted_decision!(retry_env(), nothing,
                          _dec(_d17b_lane("d17c_clean!", _d17c_moves("d17c_clean!")))))

    local nl = _d17b_rec(noop_out); local tl = _d17b_rec(threw_out)
    local cl = _d17b_rec(clean_out)
    @test !isempty(nl) && !isempty(tl) && !isempty(cl)
    # 🔴 세 판이 **한 칸으로** 갈린다.
    @test occursin("enact_retry=noop_retried", nl)
    @test occursin("enact_retry=retried", tl)
    @test occursin("enact_retry=n/a", cl)
    # 🔴 그리고 두 되먹임판이 서로 **섞이지 않는다** — `noop_` 접두가 그 구별을 나른다.
    @test !occursin("enact_retry=retried", nl)      # `noop_retried` 는 이것과 다른 글자다
    @test !occursin("noop_", tl)
    @test !occursin("noop_", cl) && !occursin("=retried", cl)
    # 🔴 세 판 다 `verdict=admit` 이고 `partial=false` 다 — 가르는 것은 이 칸 하나뿐이다.
    for l in (nl, tl, cl); @test occursin("verdict=admit", l); end
    # ---- 첫 시도의 걸음은 진단 줄이 나른다(무동작 판에서도) --------------------------------
    @test occursin("[minted] enact_retry: 되먹임 1회 — 첫 시도 steps=[", noop_out)
    @test occursin("d17c_rec!:failure", noop_out)
    @test occursin("사유=enact_noop:", noop_out)
    # 🔴 그런데 그 줄은 `MINTED_RE`(`lane=present` 로 **시작**) 에 안 걸린다.
    @test !occursin("[minted] enact_retry:", nl)
    @test count(l -> startswith(l, "[minted] lane=present"), split(noop_out, "\n")) == 1
    # ---- 결정 행에도 실린다(부재 = 구세대 · `null` = 시도 안 함 · 문자열 = 나머지) --------
    @test occursin(" enact_retry=noop_retried ", string(" ", nl, " "))
end


@testset "(42) 🔴 D17c: 한 런의 왕복 예산은 **1** — 되먹임 자리가 셋이어도" begin
    # 🔴 재는 명제: 등록이 거절돼 D17 이 왕복을 한 번 쓴 판에서, 고쳐진 body 가 집행에서
    #    무동작이거나 던져도 **두 번째 왕복이 안 나간다**. 그 판은 실재하고(아래가 그것을
    #    실제로 만든다) D17b 시점에는 아무 게이트도 그것을 안 막고 있었다.
    CB.reset_minted_table!()
    _RW_HITS[] = 0
    # 고친 body 는 **무동작**이다(status 만 낸다) → 예산이 없으면 D17c 가 발화한다.
    _RW_RESPONSES[:d17c_budget] = () -> _rw_fix("d17c_budget_fixed!";
        code = "function d17c_budget_fixed!(env; note = \"x\")\n" *
               "    return (status = :rw_ok, note = note)\nend\n")
    _RW_MODE[] = :d17c_budget
    # 첫 등록을 **거절**시킨다: `!` 없는 이름 = `impl_name_must_end_with_bang`.
    local sl = _lane(Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "d17c_budget_bad",
        "impl_code" => "function d17c_budget_bad(env; note = \"x\")\n" *
                       "    return (status = :bad, note = note)\nend\n",
        "surface" => "env_param", "reversible" => false,
        "params" => Dict{String,Any}("note" => Dict{String,Any}("type" => "string")),
        "body_names" => ["d17c_budget_bad"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "d17c_budget_bad",
                                     "args" => Dict{String,Any}("note" => "x"))]))
    local m = enact_minted_decision!(retry_env(), nothing, _dec(sl))
    _RW_MODE[] = :off
    # ---- 전제: D17 이 실제로 발화했고 고친 body 가 집행됐다 ------------------------------
    @test m.registered === true
    @test length(m.steps) == 1 && m.steps[1].status === :rw_ok
    # ---- 전제: 그 고친 body 는 **잰 무동작**이다(= 예산이 없으면 D17c 가 열린다) ---------
    @test m.world_delta_body !== nothing && _wd_is_zero(m.world_delta_body)
    # ---- 🔴 재는 것: 왕복은 **하나**다 ---------------------------------------------------
    @test _RW_HITS[] == 1
    # ---- 그리고 그 사실이 기록에 **자기 이름으로** 남는다 --------------------------------
    @test m.enact_retry === :refused_budget_spent
    # 🔴 `n/a`(사건이 없었다)로도, `noop_*`(시도했다)로도 안 적는다 — 셋이 다른 값이다.
    @test m.enact_retry !== nothing
    @test length(Set([m.enact_retry, :noop_retried, :noop_refused_unmeasured])) == 3
end

# 🔴 나가는 모든 길에서 서버를 닫는다. (테스트셋이 빨개지면 그 testset 이 스스로 던져
#    여기 못 오지만, 그때는 프로세스가 곧 끝난다 — 포트는 프로세스와 함께 반납된다.)

# =============================================================================
# (43) 🔴 2026-09-05 (P2 의 진짜 원인) — **`/rewrite` 왕복이 완주한다.**
#
# 사건. `bca635f1`·`94bd8132`·`fbf6d17c` 가 되먹임 채널을 끝에서 끝까지 배선했는데
# **한 번도 성공하지 못했다**. 유료 런 9 의 기록은 `enact_retry=noop_roundtrip_failed`
# 였고(방아쇠는 설계대로 열렸다), 서비스 로그의 `/rewrite` 는 **0건**이었다 — 요청이
# 서버에 닿지 않았다. 그런데 **빨간 것이 하나도 없었다**: 이 파일의 (20) 가족은 왕복이
# 되는 판만 재고, 왕복이 **깨지는** 판을 재는 게이트가 없었다.
#
# 원인(실측). `_rewrite_once` 는 `retries = 0` 으로 POST 했다. keep-alive 로 풀에 남은
# 소켓을 서버가 닫은 뒤(uvicorn 기본 5초) 그 소켓으로 쓰면 `HTTP.RequestError` 가 나고,
# `retries = 0` 은 HTTP.jl 이 바로 그 판을 위해 가진 복구를 **꺼 버린다**. 같은 프로세스의
# `/decide` 가 멀쩡한 이유가 여기 있다 — `policy.jl` 이 이미 `retries = 3,
# retry_non_idempotent = true` 로 이 대가를 치렀고 그 주석이 사건까지 적어 뒀다.
#
# 🔴 이 게이트가 재는 것은 **왕복의 완주**이지 응답의 모양이 아니다. 그래서 스텁은
#    클라이언트가 **쓴 뒤** 연결을 끊는다 — 유료 런의 실패 모양 그대로다(유료 0건).
# 🔴 `DSPY_URL` 은 `const` 라 이 파일의 `_RW_PORT` 에 묶여 있다. 그래서 (30c) 와 같은
#    관용구를 쓴다: `enact.jl` 을 **새 모듈**에 실으면서 `DSPY_URL` 만 이 스텁으로 준다.
# =============================================================================

"""
    _flaky_rewrite_stub(; kill_first = true) -> (srv, port, killed, served)

`/rewrite` 스텁 한 벌. 첫 연결은 요청을 **다 읽은 뒤 응답 없이 끊는다**(죽은 keep-alive
소켓의 모양). 그 뒤의 연결은 정상적으로 고친 body 를 돌려준다. `served` 는 **비-0 대조**다 —
0 이면 "왕복이 됐다" 는 주장이 "아무 데도 안 갔다" 와 구별되지 않는다.
"""
function _flaky_rewrite_stub(; kill_first = true)
    srv = HTTP.Sockets.listen(HTTP.Sockets.localhost, 0)
    port = HTTP.Sockets.getsockname(srv)[2]
    killed = Ref(false); served = Ref(0); kill = Ref(kill_first)
    @async while true
        sock = try HTTP.Sockets.accept(srv) catch; break end
        @async begin
            try
                local clen = 0
                while true
                    local l = readline(sock)
                    isempty(l) && break
                    startswith(lowercase(l), "content-length:") &&
                        (clen = parse(Int, strip(split(l, ":")[2])))
                end
                clen > 0 && read(sock, clen)
                if kill[]
                    kill[] = false; killed[] = true      # 쓴 뒤 끊는다 — 응답 없음
                else
                    served[] += 1
                    local p = JSON3.write(_rw_fix("rw_roundtrip!"))
                    write(sock, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" *
                                "Content-Length: $(ncodeunits(p))\r\n\r\n" * p)
                    sleep(0.05)
                end
            catch
            finally
                close(sock)
            end
        end
    end
    return (srv, port, killed, served)
end

"""
    _enact_at(url; mutate = identity) -> Module

`enact.jl` 을 **새 모듈**에 싣고 `DSPY_URL` 을 `url` 로 준다. `mutate` 는 원본 소스에
가하는 변이(회귀 증명용). (30c) 가 쓰는 관용구와 같은 것이고, 진실원은 파일 하나다.
"""
function _enact_at(url; mutate = identity)
    local src = mutate(read(ENACT_PATH, String))
    local dir = mktempdir()
    local q = joinpath(dir, "enact_at.jl")
    write(q, src)
    local M = Module(gensym(:EnactAt))
    Core.eval(M, :(using Test; using ConstructionBots; import JSON3; import HTTP))
    Core.eval(M, :(const CB = ConstructionBots))
    Core.eval(M, :(const DSPY_URL = $(url)))
    Base.include(M, q)
    return M
end

"`_rewrite_once` 를 태우고 (반환값, 찍힌 `[minted] rewrite:` 줄들) 을 준다."
function _drive_rewrite(M, url)
    local sl = Dict{String,Any}("mechanism" => "m", "tool_name" => "t")
    local r, out
    mktemp() do path, io
        redirect_stdout(io) do
            r = try
                Base.invokelatest(getfield(M, :_rewrite_once), sl, "impl_rt!",
                                  "function impl_rt!(env) end", "reject:x")
            catch e
                e                                   # 규약 위반도 값으로 돌려 단언한다
            end
        end
        flush(io); out = read(path, String)
    end
    return (r, [l for l in split(out, "\n") if startswith(l, "[minted] rewrite:")])
end

@testset "(43) 🔴 P2: `/rewrite` 왕복이 죽은 keep-alive 소켓을 넘어 완주한다" begin

@testset "(43a) 본 경로 — 첫 소켓이 끊겨도 왕복이 끝난다" begin
    local srv, port, killed, served = _flaky_rewrite_stub()
    try
        local M = _enact_at("http://127.0.0.1:$port")
        local r, lines = _drive_rewrite(M, "http://127.0.0.1:$port")
        @test killed[]                       # 실패 판을 실제로 만들었다(대조)
        @test served[] == 1                  # 🔴 비-0 대조: 서버가 **한 번** 처리했다
        @test r isa NamedTuple               # 왕복이 완주해 고친 body 가 왔다
        @test r.impl_name == "rw_roundtrip!"
        @test isempty(lines)                 # 실패 줄이 안 찍혔다
    finally
        close(srv)
    end
end

@testset "(43b) 🔴 음성 대조: 스텁이 안 끊으면 서버 처리는 그대로 1건이다" begin
    # (43a) 의 `served[] == 1` 이 "재시도 덕에 1" 인지 "원래 1" 인지 가른다.
    local srv, port, killed, served = _flaky_rewrite_stub(kill_first = false)
    try
        local M = _enact_at("http://127.0.0.1:$port")
        local r, _ = _drive_rewrite(M, "http://127.0.0.1:$port")
        @test !killed[]
        @test served[] == 1
        @test r isa NamedTuple
    finally
        close(srv)
    end
end

@testset "(43c) 🔴 회귀 변이: `retries = 0` 으로 되돌리면 왕복이 못 끝난다" begin
    # 이것이 유료 런 9 의 코드다. 여기서 빨개져야 이 채널이 다시 조용히 새지 않는다.
    local srv, port, killed, served = _flaky_rewrite_stub()
    try
        local M = _enact_at("http://127.0.0.1:$port";
            mutate = s -> replace(s, r"retries = 2,\s*retry_non_idempotent = true" =>
                                     "retries = 0", count = 1))
        local r, lines = _drive_rewrite(M, "http://127.0.0.1:$port")
        @test killed[]
        @test served[] == 0                  # 🔴 요청이 서버에 **한 번도 안 닿았다**
        @test r === nothing                  # 규약은 지킨다(안 던진다) — 그러나 못 고쳤다
        @test length(lines) == 1
        @test occursin("왕복 실패", lines[1])
        # 🔴 그리고 **이제는 사유가 보인다**(Task 1 의 성과가 여기서 측정된다).
        @test occursin("HTTP.RequestError", lines[1])
        @test occursin("EOFError", lines[1]) || occursin("IOError", lines[1])
    finally
        close(srv)
    end
end

@testset "(43d) 🔴 `retry_non_idempotent` 가 load-bearing 이다 — `retries` 만으로는 못 산다" begin
    # 바이트가 나간 뒤의 실패라 `nothing_written` 이 거짓이고 POST 는 멱등이 아니다
    # (`HTTP/src/Messages.jl` 의 `retryable(::Request)`). 그래서 `retries` 만 켜면
    # **재시도가 안 걸린다** — 이 변이가 그것을 못박는다.
    local srv, port, killed, served = _flaky_rewrite_stub()
    try
        local M = _enact_at("http://127.0.0.1:$port";
            mutate = s -> replace(s, r"retries = 2,\s*retry_non_idempotent = true" =>
                                     "retries = 2", count = 1))
        local r, lines = _drive_rewrite(M, "http://127.0.0.1:$port")
        @test killed[] && served[] == 0
        @test r === nothing
        @test length(lines) == 1
    finally
        close(srv)
    end
end

end


# =============================================================================
# (44) 🔴 2026-09-05 (유료 런 10) — **고친 body 가 등록 가능해진다.**
#
# 사건. `730951cd` 로 `/rewrite` 왕복이 처음으로 성공했다. agent-3 이 고친 body 를 돌려줬고,
# 재등록도 통과했고(`registered=true`), 그리고 **집행의 인자 바인딩에서** 죽었다:
#     reason=reject:param_type:zone_radius:no_declared_type (원시 ZoneBypassTool!)
#
# 실측 진단(추론이 아니라 소거법). 그 런의 `results/synth_lane_records.jsonl` 은 원래 스키마를
# 그대로 들고 있고 거기엔 `zone_radius: {"type": "number"}` 가 **있다**. 첫 시도는 그 선언으로
# 정상 바인딩됐다(같은 런의 `dropped fabricated identifier arg: affected_goals=…` 줄이 그
# 증거다 — 그 필터는 타입 검사 **뒤**에 있다). 두 시도 사이에 바뀐 것은 `sl["params"]` 하나뿐이고,
# 되먹임이 `params` 를 **안** 냈다면 옛 코드는 그것을 안 건드렸다(`fx.params !== nothing &&`).
# 그러므로 되먹임은 `params` 를 **냈고**, 그 안의 `zone_radius` 에 읽히는 선언이 없었다.
# (파이썬 `_params_view` 의 "values" 갈래가 정확히 그 모양을 통과시킨다 — `RewriteToolImpl`
#  에는 compose 쪽의 `ungrounded_params`·재설계 루프가 없다.)
#
# 🔴 그러므로 이것은 **모델의 실패가 아니라 우리 설치기의 회귀**다: 옛 `_install_rewrite!` 은
#    되먹임이 낸 `params` 로 **쓸 만한 스키마를 통째로 덮어썼다**.
#
# 처방(정본은 `_merge_rewrite_params` 의 docstring): 되먹임이 **스스로 이름 붙인** kwarg 중
# 선언이 못 쓸 것만, **같은 이름에 대한 원래 선언**을 옮긴다. 키는 하나도 안 더하고, 타입은
# 하나도 안 지어내고, 쓸 만한 선언은 하나도 안 덮는다. 🔴 `_param_type_reject` 는 한 글자도
# 안 넓어진다 — (44a) 가 그 동치를 못박고 (44c) 가 음성 대조를 세운다.
#
# 🔴 유료 호출 0건이다 — 위 `_RW_SERVER`(루프백) 하나만 쓴다. (0) 이 그 사실을 못박는다.
# =============================================================================

"되먹임 응답 한 벌. `params`·`code`·`args` 를 전부 열어 둔다 — (44) 가 그 셋을 겨눈다."
_rwp_fix(nm, params; code = nothing, args = Dict{String,Any}("goal" => "carried")) =
    Dict{String,Any}(
        "wrote" => true, "impl_name" => nm,
        "impl_code" => code === nothing ?
            "function $(nm)(env; goal = \"g\")\n    return (status = :rwp_ok, goal = goal)\nend\n" :
            code,
        "surface" => "env_param", "reversible" => false,
        "params" => params,
        "calls" => [Dict{String,Any}("primitive" => nm, "args" => args)],
        "error" => nothing, "rewrite_of_why" => "n/a")

"""
`M`(생산 또는 변이 사본) 을 태워 D17c 되먹임 한 판을 돌린다. `(m, stdout전문, 기록줄)`.

🔴 이름은 호출마다 달라야 한다 — `_MINTED_EVER` 는 `reset_minted_table!` 로 안 지워지는
   프로세스 수명 표라(testset (37) 이 그 계약을 소유한다) 같은 이름을 두 번 쓰면 두 번째 판이
   `impl_name_already_minted` 로 죽어 이 게이트가 **측정하려던 것과 다른 것**을 잰다.
"""
function _rwp_drive(M, mode, nm; params, args, code)
    CB.reset_minted_table!(); _RW_HITS[] = 0; _RW_MODE[] = mode
    local m = nothing
    local out = _d17b_cap(() -> (m = Base.invokelatest(
        getfield(M, :enact_minted_decision!), retry_env(), nothing,
        _dec(_d17b_lane(nm, code; params = params, args = args)))))
    _RW_MODE[] = :off
    return (m, out, _d17b_rec(out))
end

# ---- 유료 런 10 의 모양 그대로 -------------------------------------------------------
# 원래 body 는 kwarg 둘(`goal`·`extra`)을 갖고 **잰 무동작**이다(D17c 의 트리거).
_rwp_orig_params() = Dict{String,Any}("goal"  => Dict{String,Any}("type" => "string"),
                                      "extra" => Dict{String,Any}("type" => "integer"))
_rwp_orig_code(nm) = "function $(nm)(env; goal = \"g\", extra = 0)\n" *
                     "    return (status = :failure, goal = goal, extra = extra)\nend\n"
_rwp_orig_args()   = Dict{String,Any}("goal" => "g0", "extra" => 1)
# 🔴 고친 body 는 kwarg 를 **하나 버렸고**(`extra` 없음) `params` 를 **값 맵**으로 냈다 —
#    파이썬 `_params_view` 의 "values" 갈래. 이것이 런 10 을 죽인 그 모양이다.
_rwp_values_params() = Dict{String,Any}("goal" => "g")

@testset "(44) 🔴 유료 런 10: 고친 body 의 kwarg 가 선언 없이 도착해도 등록·집행된다" begin

@testset "(44a) 단위: 선언 판정이 값 판정에서 **갈라져 나왔을 뿐**이다" begin
    # ---- 선언 넷은 이름이 그대로다 ------------------------------------------------------
    local no_t  = Dict{String,Any}("description" => "r")
    local unk   = Dict{String,Any}("type" => "widget")
    local empty = Dict{String,Any}("type" => String[])
    local ok    = Dict{String,Any}("type" => "number")
    @test CB._param_type_undeclared(no_t)  == "no_declared_type"
    @test CB._param_type_undeclared(unk)   == "unknown_declared_type:widget"
    @test CB._param_type_undeclared(empty) == "empty_declared_type"
    @test CB._param_type_undeclared(ok)    === nothing
    # 스키마가 아니라 **값**이 온 자리(파이썬 "values" 갈래)도 같은 이름으로 답한다.
    @test CB._param_type_undeclared(0.07)  == "no_declared_type"
    @test CB._param_type_undeclared("g")   == "no_declared_type"
    # ---- 🔴 동치: 선언이 못 쓸 것이면 `_param_type_reject` 는 **값과 무관하게** 같은 글자다 --
    for spec in (no_t, unk, empty, 0.07, "g"), v in (1, "x", 2.0, nothing, [1], true)
        @test CB._param_type_reject(spec, v) == CB._param_type_undeclared(spec)
    end
    # ---- 🔴 그리고 게이트는 **안 넓어졌다**: 선언이 쓸 만해도 값은 여전히 판정된다 ----------
    @test CB._param_type_undeclared(ok) === nothing
    @test CB._param_type_reject(ok, "0.07") !== nothing     # 문자열 → number 불가
    @test CB._param_type_reject(ok, 0.07)   === nothing
    # 표가 공허하지 않다는 대조(합집합 선언도 산다).
    @test CB._param_type_undeclared(Dict{String,Any}("type" => ["string", "null"])) === nothing
end

@testset "(44b) 단위: 병합의 규칙 셋" begin
    local orig = JSON3.read(JSON3.write(_rwp_orig_params()))
    # (1) 키를 **안 더한다** — 되먹임이 버린 `extra` 는 안 살아난다.
    local a = _merge_rewrite_params(orig, JSON3.read(JSON3.write(_rwp_values_params())))
    @test a.note == "carried:goal"
    @test Set(keys(a.params)) == Set(["goal"])              # 🔴 `extra` 가 없다
    @test a.params["goal"]["type"] == "string"
    @test CB._param_type_reject(a.params["goal"], "carried") === nothing
    # (2) 쓸 만한 선언은 **안 덮는다** — 되먹임이 타입을 바꾼 것도 그 모델의 권리다.
    local b = _merge_rewrite_params(orig, JSON3.read(JSON3.write(
                  Dict{String,Any}("goal" => Dict{String,Any}("type" => "integer")))))
    @test b.note == "supplied"
    @test b.params["goal"]["type"] == "integer"
    @test CB._param_type_reject(b.params["goal"], 7) === nothing
    # (3) 타입을 **안 지어낸다** — 원래에 없는 이름은 선언 없이 남고 거절된다.
    local c = _merge_rewrite_params(orig, JSON3.read(JSON3.write(
                  Dict{String,Any}("radius" => 0.07))))
    @test c.note == "undeclared:radius"
    @test CB._param_type_reject(c.params["radius"], 0.07) == "no_declared_type"
    # (3') 원래 선언도 못 쓸 것이면 옮기지 않는다.
    local d = _merge_rewrite_params(
        JSON3.read(JSON3.write(Dict{String,Any}("w" => Dict{String,Any}("type" => "widget")))),
        JSON3.read(JSON3.write(Dict{String,Any}("w" => 3))))
    @test d.note == "undeclared:w"
    @test CB._param_type_reject(d.params["w"], 3) == "no_declared_type"
    # 삼상: `nothing` 은 "건드리지 마라" 다 — `{}` 로 붕괴하지 않는다.
    @test _merge_rewrite_params(orig, nothing) == (params = nothing, note = "absent")
    # 되먹임의 나머지 바이트는 산다(우리가 더하는 것은 `type` 하나다).
    local e = _merge_rewrite_params(orig, JSON3.read(JSON3.write(
                  Dict{String,Any}("goal" => Dict{String,Any}("description" => "the goal")))))
    @test e.note == "carried:goal"
    @test e.params["goal"]["description"] == "the goal"
    @test e.params["goal"]["type"] == "string"
    # 섞인 판은 **둘 다** 적는다 — 읽는 사람이 추측하지 않는다.
    local f = _merge_rewrite_params(orig, JSON3.read(JSON3.write(
                  Dict{String,Any}("goal" => "g", "radius" => 0.07))))
    @test f.note == "carried:goal|undeclared:radius"
end

@testset "(44c) 🔴 라이브 경로: 런 10 의 판이 이제 **집행된다**" begin
    _RW_RESPONSES[:rwp_values] = () -> _rwp_fix("rwp_live_a!", _rwp_values_params())
    local m, out, rec = _rwp_drive(@__MODULE__, :rwp_values, "rwp_live_a!";
        params = _rwp_orig_params(), args = _rwp_orig_args(),
        code = _rwp_orig_code("rwp_live_a!"))
    # 전제: 되먹임이 실제로 나갔고(잰 무동작), 재등록이 통과했다.
    @test _RW_HITS[] == 1
    @test m.enact_retry === :noop_retried
    @test m.registered === true
    # 🔴 재는 것: 고친 body 가 **굴렀다**. 런 10 은 여기서 죽었다.
    @test m.verdict === :admit
    @test length(m.steps) == 1 && m.steps[1].status === :rwp_ok
    @test !occursin("no_declared_type", m.reason)
    # 🔴 그리고 그 사실이 기록 줄에 **자기 이름으로** 남는다.
    @test occursin("rewrite_params=carried:goal", rec)
    @test !occursin("rewrite_params=supplied", rec)
    # 옮긴 **값**은 별도 진단 줄이 나른다(기록 줄은 공백 없는 key=value 다).
    @test occursin("rewrite params: kwarg `goal`", out)
    @test occursin("type=string", out)
    @test !occursin("rewrite params: kwarg `extra`", out)   # 🔴 버린 키는 안 살아난다
end

@testset "(44d) 🔴 음성 대조: 선언 없는 kwarg 는 **여전히 거절된다**" begin
    # 되먹임이 원래에 **없던** 이름을 선언 없이 낸다 — 옮길 것이 없다.
    _RW_RESPONSES[:rwp_undecl] = () -> _rwp_fix("rwp_live_b!",
        Dict{String,Any}("radius" => 0.07);
        code = "function rwp_live_b!(env; radius = 0.0)\n" *
               "    return (status = :rwp_ok, radius = radius)\nend\n",
        args = Dict{String,Any}("radius" => 0.07))
    local m, out, rec = _rwp_drive(@__MODULE__, :rwp_undecl, "rwp_live_b!";
        params = _rwp_orig_params(), args = _rwp_orig_args(),
        code = _rwp_orig_code("rwp_live_b!"))
    @test _RW_HITS[] == 1
    @test m.registered === true                 # 등록은 통과한다(이름은 정상이다)
    # 🔴 **이 게이트는 빨간 채로 남아야 한다.** 선언 없는 kwarg 는 안 묶인다.
    @test m.verdict === :reject
    @test occursin("reject:param_type:radius:no_declared_type", m.reason)
    @test occursin("rewrite_params=undeclared:radius", rec)
    @test occursin("지어내지 않는다", out)
end

@testset "(44e) 🔴 삼상+: 넷이 기록 줄에서 서로 다르다" begin
    # ---- `supplied` — 되먹임이 스스로 쓸 만한 스키마를 냈다 -------------------------------
    _RW_RESPONSES[:rwp_sup] = () -> _rwp_fix("rwp_sup!",
        Dict{String,Any}("goal" => Dict{String,Any}("type" => "string")))
    local ms, _, rs = _rwp_drive(@__MODULE__, :rwp_sup, "rwp_sup!";
        params = _rwp_orig_params(), args = _rwp_orig_args(),
        code = _rwp_orig_code("rwp_sup!"))
    @test ms.verdict === :admit && ms.steps[1].status === :rwp_ok
    @test occursin("rewrite_params=supplied", rs)

    # ---- `absent` — 되먹임이 `params` 를 아예 안 냈다. 원래 스키마가 **통째로** 산다 -------
    # 🔴 이 갈래는 이 태스크가 **안 건드린** 옛 동작이다(`fx.params === nothing` 이면
    #    `sl["params"]` 를 안 만진다). 여기서 옮길 것도 버릴 것도 없다: 되먹임이 kwarg 에
    #    대해 **아무 말도 안 했으므로** 우리가 그 이름들을 유추할 근거가 없다.
    _RW_RESPONSES[:rwp_abs] = () -> _rwp_fix("rwp_abs!", nothing;
        code = "function rwp_abs!(env; goal = \"g\", extra = 0)\n" *
               "    return (status = :rwp_ok, goal = goal)\nend\n")
    local ma, _, ra = _rwp_drive(@__MODULE__, :rwp_abs, "rwp_abs!";
        params = _rwp_orig_params(), args = _rwp_orig_args(),
        code = _rwp_orig_code("rwp_abs!"))
    @test occursin("rewrite_params=absent", ra)
    # 🔴 원래 스키마가 살아 있다는 **비-0 대조**: `goal` 이 실제로 묶여 body 가 굴렀다.
    @test ma.verdict === :admit && ma.steps[1].status === :rwp_ok

    # ---- 🔴 그 갈래의 **한계를 정직하게 잰다** (2026-09-05 실측) ---------------------------
    # 되먹임이 `params` 를 안 내면서 kwarg 를 **바꾸면** 원래 스키마가 새 시그니처와 안 맞는다.
    # 그 판은 조용히 틀리지 않는다 — `_enactability` 연언지 (iii) 이 **시끄럽게 거절**한다.
    # (이것이 브리프의 옵션 1 — "원래 것을 통째로 옮긴다" — 을 안 고른 이유의 실측이다.)
    _RW_RESPONSES[:rwp_abs2] = () -> _rwp_fix("rwp_abs2!", nothing)   # 기본 code = `goal` 만
    local ma2, _, ra2 = _rwp_drive(@__MODULE__, :rwp_abs2, "rwp_abs2!";
        params = _rwp_orig_params(), args = _rwp_orig_args(),
        code = _rwp_orig_code("rwp_abs2!"))
    @test occursin("rewrite_params=absent", ra2)
    @test ma2.verdict === :reject
    @test occursin("unenactable", ma2.reason)      # 🔴 조용한 오바인딩이 아니라 거절이다

    # ---- `n/a` — 되먹임 설치기가 아예 안 돌았다(첫 시도가 세계를 움직였다) ------------------
    CB.reset_minted_table!(); _RW_HITS[] = 0; _RW_MODE[] = :off
    local mn = nothing
    local outn = _d17b_cap(() -> (mn = enact_minted_decision!(retry_env(), nothing,
        _dec(_d17b_lane("rwp_na!", _d17c_moves("rwp_na!"))))))
    local rn = _d17b_rec(outn)
    @test mn.enact_retry === nothing
    @test _RW_HITS[] == 0
    @test occursin("rewrite_params=n/a", rn)

    # ---- 🔴 넷이 서로 다르다 — 하나로 뭉개면 "무엇이 일어났나" 가 로그에서 사라진다 ---------
    local vals = String[]
    for l in (rs, ra, rn)
        local mm = match(r"rewrite_params=(\S+)", l)
        @test mm !== nothing
        push!(vals, mm.captures[1])
    end
    @test vals == ["supplied", "absent", "n/a"]
    @test length(Set(vals)) == 3
    # 다섯째(`carried:…`)·여섯째(`undeclared:…`)는 (44c)(44d) 가 각각 못박았다.
end

end


# =============================================================================
# (45) 🔴 변이 대조 열 — (44) 의 게이트가 **정말로 빨개질 수 있는가**.
#
# 생산 소스는 한 바이트도 안 건드린다: `_enact_at` 이 `mktempdir()` 사본을 별도 모듈에
# include 한다((43) 가족의 관용구와 같다). 🔴 각 변이는 **자기 원시 이름**을 쓴다 —
# `_MINTED_EVER` 는 프로세스 수명 표라 이름을 재사용하면 다른 것을 재게 된다.
# =============================================================================
@testset "(45) 🔴 변이 대조 열 — 열 가지 변이가 전부 다른 곳을 빨갛게 만든다" begin

local URL = DSPY_URL
_RW_RESPONSES[:rwp_values]  = () -> _rwp_fix("__mut__", _rwp_values_params())   # 이름은 아래서 덮는다

"변이 사본을 태워 런 10 의 판을 돌린다."
function _mut_run(nm, mut; resp = nothing, params = _rwp_orig_params(),
                  args = _rwp_orig_args(), code = nothing)
    _RW_RESPONSES[Symbol(nm)] = resp === nothing ?
        (() -> _rwp_fix(nm, _rwp_values_params())) : resp
    local M = _enact_at(URL; mutate = mut)
    return _rwp_drive(M, Symbol(nm), nm; params = params, args = args,
                      code = code === nothing ? _rwp_orig_code(nm) : code)
end

# ---- M1: 병합을 통째로 지운다(= 런 10 의 코드) ----------------------------------------
local A1 = "local pmerge = _merge_rewrite_params(_synth_lane_field(sl, \"params\"), praw2)"
@test occursin(A1, read(ENACT_PATH, String))
local m1, _, r1 = _mut_run("rwp_m1!",
    s -> replace(s, A1 => "local pmerge = (params = praw2, note = \"mut\")", count = 1))
@test m1.verdict === :reject
@test occursin("reject:param_type:goal:no_declared_type", m1.reason)   # 🔴 런 10 그 줄

# ---- M2: 되먹임이 **버린** 키를 되살린다 ------------------------------------------------
local A2 = "    return (params = out, note = join(parts, \"|\"))"
@test occursin(A2, read(ENACT_PATH, String))
local m2, _, r2 = _mut_run("rwp_m2!",
    s -> replace(s, A2 => "    for (ko, vo) in orig; haskey(out, String(ko)) || " *
                          "(out[String(ko)] = vo); end\n" * A2, count = 1))
@test m2.verdict === :reject
@test occursin("unenactable", m2.reason)      # 🔴 등록은 되고 **영영 호출 불가**가 된다

# ---- M3: 옮길 것이 없을 때 타입을 **지어낸다** ------------------------------------------
local A3 = "                out[ks] = v\n                push!(undecl, ks)"
@test occursin(A3, read(ENACT_PATH, String))
local m3, _, r3 = _mut_run("rwp_m3!",
    s -> replace(s, A3 => "                out[ks] = Dict{String,Any}(\"type\" => \"number\")\n" *
                          "                push!(undecl, ks)", count = 1),
    resp = () -> _rwp_fix("rwp_m3!", Dict{String,Any}("radius" => 0.07);
        code = "function rwp_m3!(env; radius = 0.0)\n    return (status = :rwp_ok,)\nend\n",
        args = Dict{String,Any}("radius" => 0.07)))
# 🔴 (44d) 가 지키는 그 거절이 **사라진다** — 지어낸 타입으로 값이 묶인다.
@test m3.verdict === :admit
@test !occursin("no_declared_type", m3.reason)

# ---- M4: 되먹임이 스스로 낸 **쓸 만한** 선언을 덮는다 ------------------------------------
local A4 = "            if CB._param_type_undeclared(v) === nothing"
@test occursin(A4, read(ENACT_PATH, String))
local m4, _, r4 = _mut_run("rwp_m4!", s -> replace(s, A4 => "            if false", count = 1),
    resp = () -> _rwp_fix("rwp_m4!", Dict{String,Any}("goal" => Dict{String,Any}("type" => "integer"));
        code = "function rwp_m4!(env; goal = 0)\n    return (status = :rwp_ok, goal = goal)\nend\n",
        args = Dict{String,Any}("goal" => 7)))
@test m4.verdict === :reject
@test occursin("reject:param_type:goal:string:got", m4.reason)   # 낡은 선언이 새 값을 막는다

# ---- M5: 기록 줄에서 그 칸을 지운다 ------------------------------------------------------
local A5 = "                \" rewrite_params=\", _rwp_str(rewrite_params),\n" *
           "                \" n_body_names=\""
@test occursin(A5, read(ENACT_PATH, String))
local m5, _, r5 = _mut_run("rwp_m5!", s -> replace(s, A5 => "                \" n_body_names=\"", count = 1))
@test m5.verdict === :admit                       # 세계는 오늘과 같다
@test !occursin("rewrite_params=", r5)            # 🔴 그런데 로그가 못 말한다

# ---- M6: 출처를 기록까지 안 나른다 -------------------------------------------------------
local A6 = "                rewrite_params = rn.params_from\n"
@test occursin(A6, read(ENACT_PATH, String))
local m6, _, r6 = _mut_run("rwp_m6!", s -> replace(s, A6 => "", count = 1))
@test m6.verdict === :admit
@test occursin("rewrite_params=n/a", r6)          # 🔴 옮겼는데 "안 돌았다" 고 적는다

# ---- M7: `absent` 와 `supplied` 를 한 글자로 뭉갠다 ---------------------------------------
local A7 = "new === nothing && return (params = nothing, note = \"absent\")"
@test occursin(A7, read(ENACT_PATH, String))
local m7, _, r7 = _mut_run("rwp_m7!",
    s -> replace(s, A7 => "new === nothing && return (params = nothing, note = \"supplied\")",
                 count = 1),
    resp = () -> _rwp_fix("rwp_m7!", nothing))
@test occursin("rewrite_params=supplied", r7)     # 🔴 하네스가 옮긴 판과 구별 불가가 된다
@test !occursin("rewrite_params=absent", r7)

# ---- M8: 병합을 덮어쓰기 **뒤로** 옮긴다(자기 자신을 원본이라고 읽는다) --------------------
local m8, _, r8 = _mut_run("rwp_m8!",
    s -> replace(s, A1 => "sl[\"params\"] = praw2\n    " * A1, count = 1))
@test m8.verdict === :reject
@test occursin("reject:param_type:goal:no_declared_type", m8.reason)

# ---- M9: 되먹임의 선언을 **무조건** 믿는다 ------------------------------------------------
local m9, _, r9 = _mut_run("rwp_m9!",
    s -> replace(s, "CB._param_type_undeclared(v) === nothing" => "true", count = 1))
@test m9.verdict === :reject
@test occursin("reject:param_type:goal:no_declared_type", m9.reason)

# ---- M10: **원래**의 선언을 무조건 믿는다(못 쓸 선언도 옮긴다) -----------------------------
local A10 = "if ov !== nothing && CB._param_type_undeclared(ov) === nothing"
@test occursin(A10, read(ENACT_PATH, String))
local w_params = Dict{String,Any}("goal" => Dict{String,Any}("type" => "string"),
                                  "w"    => Dict{String,Any}("type" => "widget"))
local w_code(nm) = "function $(nm)(env; goal = \"g\", w = 0)\n" *
                   "    return (status = :failure, goal = goal)\nend\n"
local w_resp(nm) = () -> _rwp_fix(nm, Dict{String,Any}("w" => 3);
    code = "function $(nm)(env; w = 0)\n    return (status = :rwp_ok, w = w)\nend\n",
    args = Dict{String,Any}("w" => 3))
# 생산: 못 쓸 원래 선언은 **안 옮긴다** — 사유는 `no_declared_type` 이다.
local p10, _, rp10 = _mut_run("rwp_m10a!", identity; resp = w_resp("rwp_m10a!"),
    params = w_params, args = Dict{String,Any}("goal" => "g0"), code = w_code("rwp_m10a!"))
@test p10.verdict === :reject
@test occursin("reject:param_type:w:no_declared_type", p10.reason)
@test occursin("rewrite_params=undeclared:w", rp10)
# 변이: 무조건 믿으면 `widget` 이 옮겨져 **사유도 기록도 갈린다**.
local m10, _, r10 = _mut_run("rwp_m10b!",
    s -> replace(s, A10 => "if ov !== nothing", count = 1);
    resp = w_resp("rwp_m10b!"), params = w_params,
    args = Dict{String,Any}("goal" => "g0"), code = w_code("rwp_m10b!"))
@test m10.verdict === :reject
@test occursin("reject:param_type:w:unknown_declared_type:widget", m10.reason)
@test occursin("rewrite_params=carried:w", r10)

# 🔴 열 변이가 **서로 다른 곳**을 빨갛게 만들었다(뭉치면 하나가 다른 하나를 가린다).
@test length(Set([m1.reason, m2.reason, m3.verdict, m4.reason, r5, r6, r7,
                  m8.reason, m9.reason, m10.reason])) == 10
end

# =============================================================================
# (46) 🔴 D17d — **집행 전 거절**도 되먹임을 받는다 (2026-09-05)
#
# 유료 런 14·15 는 `reject:calls_disagree_with_body` 로 죽었다(모델이 `calls = []` 를 냈고
# `body_names` 는 한 칸이었다). 그 판은 되먹임 트리거 어디에도 안 걸렸다:
#   · D17  = **등록** 거절 — 등록은 성공했다.
#   · D17b = 집행 **예외** — body 가 안 굴렀으니 던진 것이 없다.
#   · D17c = **잰 무동작** — body 가 안 굴렀으니 잴 무동작도 없다.
# 그래서 기록이 `enact_retry=n/a rewrite_params=n/a` 였고 **모델은 자기가 왜 거절됐는지
# 들은 적이 없다.** 이 테스트셋이 그 구멍이 메워졌는지를 잰다. 유료 0건(루프백 서버).
# =============================================================================
"`calls` 가 body 와 어긋나는 레인. 유료 런 14·15 의 모양 그대로 — 빈 목록이다."
_d17d_lane(nm) = _lane(Dict{String,Any}(
    "synthesis_event" => true, "ran" => true, "error" => nothing,
    "tool_name" => "T", "impl_name" => nm,
    "impl_code" => "function $(nm)(env; note = \"x\")\n    return (status = :never,)\nend\n",
    "surface" => "env_param", "reversible" => false,
    "params" => Dict{String,Any}("note" => Dict{String,Any}("type" => "string")),
    "body_names" => [nm], "wrote" => true,
    "calls" => Any[]))

@testset "(46) 🔴 D17d: 집행 전 거절이 되먹임으로 나가고 고친 body 가 집행된다" begin
    # ---- (a) 라이브 경로: 런 14·15 의 판이 이제 **두 번째로 집행된다** -------------------
    CB.reset_minted_table!(); _RW_HITS[] = 0; _RW_LAST[] = nothing
    # 🔴 고친 body 는 **같은 이름**으로 돌아온다 — 첫 등록이 성공한 판이므로
    #    `allow_redefine` 이 없으면 채널이 `already_minted` 로 죽는다(D17b 와 같은 자리).
    _RW_RESPONSES[:d17d_ok] = () -> _rw_fix("d17d_a!")
    _RW_MODE[] = :d17d_ok
    local ra = enact_minted_decision!(retry_env(), nothing, _dec(_d17d_lane("d17d_a!")))
    @test _RW_HITS[] == 1                        # 🔴 왕복이 **나갔다**(옛 코드에서는 0)
    @test ra.enact_retry === :prerun_retried
    @test ra.verdict === :admit                  # 두 번째 집행의 결과가 기록된다
    @test length(ra.steps) == 1 && ra.steps[1].name == "d17d_a!"
    # 🔴 전선에 실린 사유: 접두가 셋을 가르고, 사유 자신은 **그대로** 실린다.
    local why_sent = String(_RW_LAST[].impl_rejected_why)
    @test startswith(why_sent, "enact_rejected:")
    @test occursin("calls_disagree_with_body", why_sent)
    @test occursin("body=[d17d_a!]", why_sent)   # 모델이 고칠 것을 이름으로 듣는다
    _RW_MODE[] = :off

    # ---- (b) 🔴 음성 대조: 왕복이 실패하면 **원래 거절이 그대로 남는다** ------------------
    CB.reset_minted_table!(); _RW_HITS[] = 0
    local rb = enact_minted_decision!(retry_env(), nothing, _dec(_d17d_lane("d17d_b!")))
    @test _RW_HITS[] == 1                        # 시도는 했다(404 가 돌아왔다)
    @test rb.enact_retry === :prerun_roundtrip_failed
    @test rb.verdict === :reject
    @test occursin("calls_disagree_with_body", rb.reason)

    # ---- (c) 판독기 단위: 연언지 넷 ------------------------------------------------------
    local ok = (verdict = :reject, steps = NamedTuple[], world_maybe_dirty = false,
                reason = "reject:calls_disagree_with_body: calls=[] body=[x!]")
    @test _prerun_reject_reason(ok) ==
          "enact_rejected:reject:calls_disagree_with_body: calls=[] body=[x!]"
    # 🔴 `:deferred` 는 트리거가 아니다 — agent-3 에게 되먹일 것이 없는 판이다.
    @test _prerun_reject_reason(merge(ok, (verdict = :deferred,))) === nothing
    @test _prerun_reject_reason(merge(ok, (verdict = :admit,))) === nothing
    # 걸음이 있으면 body 가 굴렀다 = 이 갈래의 안전 논거가 성립하지 않는다.
    @test _prerun_reject_reason(merge(ok, (steps = [(name = "x!", status = :ok)],))) === nothing
    # 하네스가 "손댔을 수 있다" 고 말하면 물러선다(음성 대조로만 쓴다).
    @test _prerun_reject_reason(merge(ok, (world_maybe_dirty = true,))) === nothing
    # 빈 사유를 되먹이면 `/rewrite` 는 고칠 것을 못 듣는다.
    @test _prerun_reject_reason(merge(ok, (reason = "",))) === nothing
    # 🔴 안 던진다 — 필드가 없는 모양도 `nothing` 이다.
    @test _prerun_reject_reason((verdict = :reject,)) === nothing
    @test _prerun_reject_reason(nothing) === nothing

    # ---- (d) 🔴 세 트리거가 로그에서 갈린다 ----------------------------------------------
    CB.reset_minted_table!(); _RW_HITS[] = 0
    _RW_RESPONSES[:d17d_rec] = () -> _rw_fix("d17d_c!")
    _RW_MODE[] = :d17d_rec
    local out = _d17b_cap(() -> enact_minted_decision!(retry_env(), nothing,
                              _dec(_d17d_lane("d17d_c!"))))
    local rec = _d17b_rec(out)
    local rx = match(r"enact_retry=(\S+)", rec)
    @test rx !== nothing && rx.captures[1] == "prerun_retried"
    # 접두 없는 판독은 이 판을 D17b 로 **오독하지 않는다**(이 파일의 관용구).
    @test !occursin("enact_retry=retried", rec)
    @test !occursin("enact_retry=noop_retried", rec)
    _RW_MODE[] = :off

    # 🔴 셋 다 서로 다른 이름이다 — 뭉개면 "왜 되먹였나" 가 로그에서 사라진다.
    @test length(Set([_RETRY_SYMS_THREW.retried, _RETRY_SYMS_NOOP.retried,
                      _RETRY_SYMS_PRERUN.retried])) == 3
end

# =============================================================================
# (34a)~(34i) 🔴 2026-09-22 (Task 5, 재시도 보존) — 되먹임 한 번이 스트림의
# `respec["attempts"]` 에 남는다.
#
# 사건(F2·F3·F4). 스트림은 첫 시도 body 만 싣는다: `synth_lane` 은 `policy.jl` 이 만든
# **사본**이고 `_install_rewrite!` 은 그 사본만 고친다. 첫 시도의 `steps` 는 stdout 에만
# 찍히고, `_rewrite_once` 는 `wrote≠true` 면 서비스의 `error` 를 버렸다. 그래서 현재 스트림의
# `retried`·`noop_retried` 28판은 최종 body 를 복구할 수 없다.
#
# 🔴 이름: 이 파일에는 이미 `(34)`(D17b 기록 줄) 이 있다. 브리프의 번호 `(34a)~(34d)` 를
#    그대로 쓰고(전역 제약·리뷰 포커스가 그 번호로 가리킨다), 수락 조건이 더한 판은
#    `(34e)~(34i)` 로 잇는다.
# 🔴 유료 0건 — `_RW_SERVER`(루프백) 하나만 쓴다.
# =============================================================================
# (34e) 는 생산의 `record_decision!`(policy.jl)을 그대로 부른다 — 그 함수는 `CB.FaultTruth` 등
# 런타임 include 되는 사건 타입을 본다. `render_demo.jl`·`test/ood_truth_keys.jl` 과 같은 관용구로
# **testset 밖에서** 싣는다(같은 최상위 식 안에서 싣고 부르면 world age 가 끼어든다).
isdefined(CB, :FaultTruth) ||
    CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))

@testset "(34*) 🔴 2026-09-22: 재시도 한 번이 스트림의 respec.attempts 에 남는다" begin

@testset "(34a) 던진 판 — 고친 body·첫 시도 steps·원장 id 사슬" begin
    CB.reset_minted_table!()
    _RW_HITS[] = 0; _RW_LAST[] = nothing
    # 가짜 서비스도 진짜처럼 **처리마다** `response_id` 를 싣는다(서비스 94aef446 의 계약).
    _RW_RESPONSES[:d34_same] = () -> merge(_rw_fix("d34_boom!"), Dict{String,Any}(
        "record_id" => get(_RW_LAST[], :record_id, nothing),
        "response_id" => "srv-resp-34a"))
    _RW_MODE[] = :d34_same
    CB.MONITOR_RESPEC[] = Dict{String,Any}()
    set_run_ctx!(campaign_id = "c34a")
    local sl = _d17b_lane("d34_boom!", _d17b_boom("d34_boom!"))
    sl["record_id"] = "parent-rid-34a"
    sl["response_id"] = "parent-resp-34a"
    local m = enact_minted_decision!(retry_env(), nothing, _dec(sl))
    set_run_ctx!()
    _RW_MODE[] = :off
    @test m.enact_retry === :retried
    local atts = CB.MONITOR_RESPEC[]["attempts"]
    @test length(atts) == 1
    local a = atts[1]
    @test a["attempt"] == 2
    @test a["trigger"] == "threw"
    @test startswith(a["why"], "enact_threw:d34_boom!")
    @test a["roundtrip"] == "ok"
    @test a["wrote"] === true
    @test a["service_error"] === nothing
    @test a["parent_record_id"] == "parent-rid-34a"
    @test a["parent_response_id"] == "parent-resp-34a"
    @test a["response_id"] == "srv-resp-34a"
    @test occursin(r"^[0-9a-f]{24}$", a["record_id"])
    @test a["prev_impl_name"] == "d34_boom!"
    @test occursin("function d34_boom!", String(a["impl_code"]))
    @test a["impl_name"] == "d34_boom!"
    @test a["install_why"] === nothing
    @test a["prev_steps"] isa Vector && length(a["prev_steps"]) == 1
    @test occursin(":threw", a["prev_steps"][1])
    @test a["steps"] isa Vector && !isempty(a["steps"])
    @test occursin("d34_boom!:rw_ok", a["steps"][1])
    @test a["steps_ref"] === nothing                  # 이 갈래는 steps 를 자기 칸에 싣는다
    # 전선: 같은 id 가 서비스로 갔다 — 원장 행과 조인되는 키다.
    @test String(_RW_LAST[][:record_id]) == a["record_id"]
    @test String(_RW_LAST[][:parent_record_id]) == "parent-rid-34a"
    @test _RW_LAST[][:attempt] == 2
    @test String(_RW_LAST[][:trigger]) == "threw"
    # 🔴 `run_ctx` 는 `RUN_CTX[]` 의 값을 싣는다(사본이다 — 정본은 policy.jl 의 `_stamp_identity!`).
    @test String(_RW_LAST[][:run_ctx][:campaign_id]) == "c34a"
    # 사본(sl)은 고쳐졌다 — 원본 불변의 증명은 이것이 **아니다**((34e) 가 잰다).
    @test String(sl["impl_code"]) == String(a["impl_code"])
end

@testset "(34b) 왕복 실패 — 원인이 남고 판정은 오늘과 같다" begin
    CB.reset_minted_table!()
    _RW_HITS[] = 0; _RW_LAST[] = nothing
    _RW_MODE[] = :bad_json
    CB.MONITOR_RESPEC[] = Dict{String,Any}()
    local m = enact_minted_decision!(retry_env(), nothing,
                  _dec(_d17b_lane("d34_rt!", _d17b_boom("d34_rt!"))))
    _RW_MODE[] = :off
    @test m.enact_retry === :roundtrip_failed
    local a = only(CB.MONITOR_RESPEC[]["attempts"])
    @test startswith(String(a["roundtrip"]), "failed:")
    @test occursin("SENTINEL_CAUSE", String(a["roundtrip"]))   # 원인이 칸에 산다
    @test a["impl_code"] === nothing
    @test a["response_id"] === nothing
    @test a["parent_record_id"] === nothing          # 합성 레인에 id 가 없던 판
    # 🔴 요청은 나갔다(서버가 받았다) — id 가 있어야 원장 쪽에서 행을 찾을 수 있다.
    @test occursin(r"^[0-9a-f]{24}$", a["record_id"])
    @test _RW_HITS[] == 1
end

@testset "(34c) MONITOR_RESPEC 이 없어도 던지지 않는다" begin
    CB.reset_minted_table!()
    _RW_RESPONSES[:d34_nomon] = () -> _rw_fix("d34_nomon!")
    _RW_MODE[] = :d34_nomon
    CB.MONITOR_RESPEC[] = nothing
    local m = enact_minted_decision!(retry_env(), nothing,
                  _dec(_d17b_lane("d34_nomon!", _d17b_boom("d34_nomon!"))))
    _RW_MODE[] = :off
    @test m.enact_retry === :retried
    @test CB.MONITOR_RESPEC[] === nothing
end

@testset "(34d) 등록 거절 되먹임도 같은 칸에 남는다 — trigger=register_reject" begin
    CB.reset_minted_table!()
    # 🔴 새 이름을 쓴다 — (20a) 가 `rw_fixed!` 를 CB 에 이미 심었고, 재등록은
    #    `allow_redefine` 없이 이 갈래에서 거절될 수 있다(이 시험이 재려는 것과 다른 사건).
    _RW_RESPONSES[:d34_rename] = () -> _rw_fix("rw_fixed34!")
    _RW_MODE[] = :d34_rename
    _RW_HITS[] = 0
    CB.MONITOR_RESPEC[] = Dict{String,Any}()
    local sl = _rw_lane("rw_bad34",
        "function rw_bad34(env; note = \"x\")\n    return (status = :nope,)\nend\n")
    local m = enact_minted_decision!(live_cache_env(), nothing, _dec(sl))
    _RW_MODE[] = :off
    @test m.registered === true
    # ⚠️ 브리프는 `only(...)` 였다. 실측: 칸이 **둘**이다 — 고친 body 는 무동작이고
    #    `live_cache_env()` 에는 `staging_circles` 가 없어 여섯째 축을 못 잰다 ⟹ 두 번째
    #    트리거(`noop`)가 `noop_refused_unmeasured` 로 **부르지 않고 거절**했고, 그 거절도
    #    (R8 대로) 칸을 남긴다. 순서가 일어난 순서다.
    @test m.enact_retry === :noop_refused_unmeasured
    local atts = CB.MONITOR_RESPEC[]["attempts"]
    @test length(atts) == 2
    @test atts[2]["trigger"] == "noop" && atts[2]["roundtrip"] == "not_requested"
    @test atts[2]["why"] == "noop_refused_unmeasured"
    local a = atts[1]
    @test a["trigger"] == "register_reject"
    @test a["impl_name"] == "rw_fixed34!"
    @test a["install_why"] === nothing
    @test a["prev_impl_name"] == "rw_bad34"
    @test a["prev_steps"] === nothing                 # 첫 시도는 집행 전에 거절됐다
    # 🔴 재집행 steps 는 정상 흐름이 `respec["steps"]` 에 쓴다 — 검증기가 따라갈 자리를 적는다.
    @test a["steps"] === nothing
    @test a["steps_ref"] == "respec.steps"
    @test String(_RW_LAST[][:trigger]) == "register_reject"
end

@testset "(34e) 🔴 첫 시도의 진실원(decision.policies)은 바이트 동일하고, 고친 body 는 attempts 에만 산다 — 직렬화된 프레임에서 잰다" begin
    CB.reset_minted_table!()
    _RW_HITS[] = 0; _RW_LAST[] = nothing
    _RW_RESPONSES[:d34_pol] = () -> _rw_fix("d34_pol!")
    _RW_MODE[] = :d34_pol
    local orig_code = _d17b_boom("d34_pol!")
    local pol = Dict{String,Any}("dspy" => _d17b_lane("d34_pol!", orig_code))
    pol["dspy"]["record_id"] = "parent-rid-34e"
    # 🔴 생산의 사본 한 줄 그대로다(`policy.jl` 의 `local synth_lane = let e = get(pol, enacted,
    #    nothing) … Dict{String,Any}(k => get(e, k, nothing) for k in SYNTH_LANE_KEYS)`).
    local sl = Dict{String,Any}(k => get(pol["dspy"], k, nothing) for k in SYNTH_LANE_KEYS)
    local before = JSON3.write(pol)
    local env = retry_env()
    local decision = (macro_name = "NOOP", candidates = Any[], policies = pol,
                      enacted = "dspy", policy = "dspy", rule_macro = "NOOP",
                      llm_macro = "NOOP", verdict = "ADMITTED", router = nothing,
                      narrative = nothing, detail = "r", agree = nothing, synth_lane = sl)
    CB.MONITOR_RESPEC[] = nothing; empty!(CB.MONITOR_RESPEC_HISTORY)
    # 생산 순서 그대로: 결정 행을 먼저 연다(render_demo 의 `record_decision!` → 집행).
    record_decision!(env, nothing, decision, "event nl")
    @test CB.MONITOR_RESPEC[] isa AbstractDict        # 전제: 결정 행이 열렸다
    local m = enact_minted_decision!(env, nothing, decision)
    _RW_MODE[] = :off
    @test m.enact_retry === :retried
    # ---- 원본 dict 은 한 바이트도 안 바뀌었다 -----------------------------------------------
    @test JSON3.write(pol) == before
    @test String(pol["dspy"]["impl_code"]) == orig_code
    @test String(sl["impl_code"]) != orig_code         # 대조: 사본은 **고쳐졌다**
    # ---- 스트림 프레임: `monitor_emit!` 이 싣는 두 칸 그대로 직렬화해 되읽는다 -------------
    #      (`monitor_emit!` 자체는 scene_tree·로봇이 있는 env 가 있어야 돈다 — 아래 소스 결속이
    #       그 두 칸이 이 모양이라는 것을 못박는다.)
    local frame = JSON3.read(JSON3.write(Dict{String,Any}(
        "respec" => CB.MONITOR_RESPEC[],
        "respec_history" => copy(CB.MONITOR_RESPEC_HISTORY))))
    local fr = frame.respec
    @test String(fr.input.policies.dspy.impl_code) == orig_code
    @test length(fr.attempts) == 1
    local fa = fr.attempts[1]
    @test occursin("(status = :rw_ok", String(fa.impl_code))
    @test String(fa.impl_code) != orig_code
    @test String(fa.parent_record_id) == "parent-rid-34e"
    @test fa.roundtrip == "ok"
    @test length(frame.respec_history) == 1
    @test String(frame.respec_history[1].attempts[1].record_id) == String(fa.record_id)
    # 🔴 고친 body 는 결정 행의 input 어디에도 없다 — attempts 에만 산다.
    @test !occursin("rw_ok", JSON3.write(fr.input))
    # 소스 결속: 스트림 작성기가 이 두 칸을 이 모양으로 싣는다.
    local msrc = read(joinpath(@__DIR__, "..", "src", "monitor", "monitor.jl"), String)
    @test occursin("\"respec\"     => MONITOR_RESPEC[],", msrc)
    @test occursin("\"respec_history\" => copy(MONITOR_RESPEC_HISTORY),", msrc)
    CB.MONITOR_RESPEC[] = nothing; empty!(CB.MONITOR_RESPEC_HISTORY)
end

@testset "(34f) 무동작·집행 전 거절 트리거도 같은 칸에 남는다 — trigger 가 갈린다" begin
    # ---- noop -------------------------------------------------------------------------
    CB.reset_minted_table!(); _RW_HITS[] = 0; _RW_LAST[] = nothing
    _RW_RESPONSES[:d34_noop] = () -> _rw_fix("d34_noop!")
    _RW_MODE[] = :d34_noop
    CB.MONITOR_RESPEC[] = Dict{String,Any}()
    local mn = enact_minted_decision!(retry_env(), nothing,
                   _dec(_d17b_lane("d34_noop!", _d17c_noop("d34_noop!"))))
    @test mn.enact_retry === :noop_retried
    local an = only(CB.MONITOR_RESPEC[]["attempts"])
    @test an["trigger"] == "noop"
    @test an["roundtrip"] == "ok"
    @test startswith(an["why"], "enact_noop:")
    @test String(_RW_LAST[][:record_id]) == an["record_id"]
    @test String(_RW_LAST[][:trigger]) == "noop"
    @test length(an["prev_steps"]) == 1 && occursin("d34_noop!:failure", an["prev_steps"][1])
    @test an["steps"] isa Vector && !isempty(an["steps"])
    @test an["steps_ref"] === nothing
    # ---- prerun -----------------------------------------------------------------------
    CB.reset_minted_table!(); _RW_HITS[] = 0; _RW_LAST[] = nothing
    _RW_RESPONSES[:d34_pre] = () -> _rw_fix("d34_pre!")
    _RW_MODE[] = :d34_pre
    CB.MONITOR_RESPEC[] = Dict{String,Any}()
    local mp = enact_minted_decision!(retry_env(), nothing, _dec(_d17d_lane("d34_pre!")))
    _RW_MODE[] = :off
    @test mp.enact_retry === :prerun_retried
    local ap = only(CB.MONITOR_RESPEC[]["attempts"])
    @test ap["trigger"] == "prerun"
    @test ap["roundtrip"] == "ok"
    @test startswith(ap["why"], "enact_rejected:")
    @test ap["prev_steps"] isa Vector && isempty(ap["prev_steps"])   # body 가 안 굴렀다
    @test ap["steps"] isa Vector && !isempty(ap["steps"])
    @test String(_RW_LAST[][:trigger]) == "prerun"
end

@testset "(34g) 🔴 F3: wrote=false — 왕복은 ok, 서비스의 error 가 칸에 남고 판정은 오늘과 같다" begin
    CB.reset_minted_table!(); _RW_HITS[] = 0
    _RW_RESPONSES[:d34_nowrite] = () -> Dict{String,Any}(
        "wrote" => false, "impl_name" => nothing, "impl_code" => nothing,
        "params" => nothing, "calls" => nothing,
        "error" => "rewrite_declined: SENTINEL_SVC_ERR", "response_id" => "srv-resp-34g")
    _RW_MODE[] = :d34_nowrite
    CB.MONITOR_RESPEC[] = Dict{String,Any}()
    local m = enact_minted_decision!(retry_env(), nothing,
                  _dec(_d17b_lane("d34_nw!", _d17b_boom("d34_nw!"))))
    _RW_MODE[] = :off
    @test _RW_HITS[] == 1
    @test m.enact_retry === :roundtrip_failed          # 🔴 판정 심볼은 오늘과 같다
    local a = only(CB.MONITOR_RESPEC[]["attempts"])
    @test a["roundtrip"] == "ok"                        # 서비스는 **답했다**
    @test a["wrote"] === false
    @test a["service_error"] == "rewrite_declined: SENTINEL_SVC_ERR"
    @test a["response_id"] == "srv-resp-34g"
    @test a["impl_code"] === nothing
    @test a["install_why"] === nothing && a["steps"] === nothing
end

@testset "(34h) 🔴 요청하지 않은 거절도 사유가 남는다 — roundtrip=not_requested" begin
    # ---- (a) refused_world_changed: 서버는 살아 있는데 **안 부른다** ------------------------
    CB.reset_minted_table!(); _RW_HITS[] = 0
    _RW_RESPONSES[:d34_never] = () -> _rw_fix("d34_never!")
    _RW_MODE[] = :d34_never
    CB.MONITOR_RESPEC[] = Dict{String,Any}()
    local dirty = _d17b_lane("d34_dirty!",
        "function d34_dirty!(env; goal = \"g\")\n" *
        "    push!(env.active_build_steps, ConstructionBots.RobotID(7))\n" *
        "    error(\"KeyError: key \\\"\$(goal)\\\" not found\")\nend\n")
    dirty["record_id"] = "parent-rid-34h"
    local mb = enact_minted_decision!(retry_env(), nothing, _dec(dirty))
    @test mb.enact_retry === :refused_world_changed
    @test _RW_HITS[] == 0
    local a = only(CB.MONITOR_RESPEC[]["attempts"])
    @test a["trigger"] == "threw"
    @test a["roundtrip"] == "not_requested"
    @test startswith(a["why"], "refused_world_changed")
    @test occursin("enact_threw:d34_dirty!", a["why"])  # 원래 사유도 같이 남는다
    @test a["record_id"] === nothing                     # 전선에 안 나갔다 = 원장 행이 없다
    @test a["parent_record_id"] == "parent-rid-34h"
    @test a["prev_steps"] isa Vector && occursin(":threw", a["prev_steps"][1])
    @test a["wrote"] === nothing && a["impl_code"] === nothing

    # ---- (b) noop_refused_unmeasured: 못 잰 판 --------------------------------------------
    CB.reset_minted_table!(); _RW_HITS[] = 0
    CB.MONITOR_RESPEC[] = Dict{String,Any}()
    local mu = enact_minted_decision!(live_cache_env(), nothing,
                   _dec(_d17b_lane("d34_unmeas!", _d17c_noop("d34_unmeas!"))))
    @test mu.enact_retry === :noop_refused_unmeasured
    @test _RW_HITS[] == 0
    local au = only(CB.MONITOR_RESPEC[]["attempts"])
    @test au["trigger"] == "noop"
    @test au["roundtrip"] == "not_requested"
    @test au["why"] == "noop_refused_unmeasured"
    @test au["record_id"] === nothing

    # ---- (c) refused_budget_spent: 등록 거절이 예산을 쓴 판 → 두 칸, 일어난 순서대로 --------
    CB.reset_minted_table!(); _RW_HITS[] = 0
    _RW_RESPONSES[:d34_budget] = () -> _rw_fix("d34_budget_fixed!")   # 고친 body 는 무동작
    _RW_MODE[] = :d34_budget
    CB.MONITOR_RESPEC[] = Dict{String,Any}()
    local sg = _rw_lane("d34_budget_bad",
        "function d34_budget_bad(env; note = \"x\")\n    return (status = :bad, note = note)\nend\n")
    local mg = enact_minted_decision!(retry_env(), nothing, _dec(sg))
    _RW_MODE[] = :off
    @test mg.enact_retry === :refused_budget_spent
    @test _RW_HITS[] == 1
    local ag = CB.MONITOR_RESPEC[]["attempts"]
    @test length(ag) == 2
    @test ag[1]["trigger"] == "register_reject" && ag[1]["roundtrip"] == "ok"
    @test ag[2]["trigger"] == "noop" && ag[2]["roundtrip"] == "not_requested"
    @test startswith(ag[2]["why"], "refused_budget_spent")
    @test ag[2]["prev_impl_name"] == "d34_budget_fixed!"  # 그 순간의 body 는 **고친** 것이다
    @test ag[2]["record_id"] === nothing
end

@testset "(34i) _sl_is_rewritable 거절 — roundtrip=skipped_not_rewritable, 전선에 안 나간다" begin
    _RW_HITS[] = 0
    CB.MONITOR_RESPEC[] = Dict{String,Any}()
    local att = _open_attempt!(trigger = "register_reject", why = "reject:x", prev_name = "nr!")
    local slS = Dict{Symbol,Any}(:impl_name => "nr!", :mechanism => "m")
    @test _rewrite_once(slS, "nr!", "function nr!(env) end", "reject:x"; attempt = att) === nothing
    @test att["roundtrip"] == "skipped_not_rewritable"
    @test att["record_id"] === nothing
    @test _RW_HITS[] == 0
    @test only(CB.MONITOR_RESPEC[]["attempts"]) === att
    CB.MONITOR_RESPEC[] = nothing
end

end # (34*)

close(_RW_SERVER)

end # module
