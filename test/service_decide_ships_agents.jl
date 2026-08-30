# =============================================================================
# `service_decide` 가 실재 로봇 목록을 payload 에 실어 보내는지 못박는다.
# (2026-08-26, tool-lane step A, Task 2 — 리뷰 라운드 1 F2 · 라운드 2 G1+G2 · 라운드 3 H1-H3
#  · 라운드 4 J1-J5)
#
# 왜 이 파일이 필요한가
# ----------------------
# Task 2 가 고친 두 줄(payload 조립부의 `agents === nothing || (payload["agents"] = agents)`,
# 그리고 `decide_all` 호출부의 `agents = CB.open_agent_descriptors(env)`)은
# `policy_macro_binding.jl` · `battery_menu_lanes_agree.jl` 어느 쪽도 건드리지 않는다 —
# 둘 다 `service_decide` 를 부르지 않거나, 부르더라도 `agents` kwarg 없이 부른다.
# `tools/test_policy_oracle.jl` 도 `decide_all` 을 부르지만 `agents` 를 건너뛰는 삼항식의
# `then` 가지 아래서다. 그 가지에 들어가려면 세 조건이 **모두** 필요한데, 그 파일은 셋을 다
# 만족시킨다: `POLICY` 기본 `"canonical"`, `tools/test_policy_oracle.jl:48` 의
# `ENV["DEMO_ROUTER"] = "0"`(→ `router_drives()` 가 false), `:352` 의
# `withenv("DEMO_ALL_POLICIES" => "0")`. (라운드 5 L1: 예전 주석은 `DEMO_ALL_POLICIES=0`
# 하나만으로 `then` 가지에 간다고 읽혔다 — 아니다. `DEMO_ROUTER=0` 이 같이 있어야 한다.)
#
# 🔴 라운드 1 (F2) 은 이 구멍을 **부분적으로만** 메웠다. 실측(라운드 2 validator, 각 줄을
# `error(...)` 로 바꿔치기): 아래 (1)~(3) 은 `service_decide` 의 **시그니처**(kwarg 선언)와
# `open_agent_descriptors` **원시 함수**만 잰다. payload 조립 줄(policy.jl:~550)과 `decide_all`
# 호출부 줄(policy.jl:~1134)은 둘 다 (1)~(3) 이 한 번도 안 태운다 — 실제로 `env.sched` 로 되돌린
# 원래 버그를 되살려도 (1)~(3) 은 Pass 5/5 로 그대로 초록이었다. 이제 (4) 가 `decide_all` 을
# **직접 실행**해서 그 두 줄을 진짜로 태운다: 이 파일이 **루프백에 진짜 HTTP 서버를 하나 띄우고**
# `DSPY_URL` 이 그 서버를 가리키게 한 뒤 `decide_all(env, truth)` 를 부른다. 서버 핸들러가 받은
# 요청 본문의 `"agents"` 가 `CB.open_agent_descriptors(env)` 와 같은지 확인한다. 이 경로는
# (a) payload 조립 줄이 실제로 도는지, (b) `decide_all` 호출부가 실제로 그 값을 실어 보내는지,
# 둘 다 하나의 실행으로 잰다 — GREEN/RED 근거는 두 줄을 각각 `error(...)` 로 바꾼 스크래치패드
# 사본에서 이 파일 전체가 실제로 빨개지는 것으로 실측했다(수정 라운드 2·4 보고서 참조).
#
# 🔴 **라운드 4 (J1): 왜 `HTTP.post` 스텁이 아니라 진짜 서버인가.**
# 라운드 2~3 은 `function HTTP.post(url::AbstractString, headers, body::AbstractString; kwargs...)`
# 로 **패키지 제네릭을 해적질(method piracy)** 해서 본문을 가로챘다. 그 정의 하나가 메서드를
# **셋** 심는다: (i) `methods(HTTP.post)` 의 위치인자 메서드, (ii) 별도 테이블의
# `Core.kwcall` 정렬 메서드, (iii) 이 모듈 안의 `#post#NN` 본체. 라운드 3 의
# `Base.delete_method` 는 (i) 만 지웠고 — 그런데 이 레포의 **모든 실제 호출자는 키워드 인자를
# 넘기므로 전부 (ii) 로 디스패치한다.** 즉 "지웠다"고 주장한 뒤에도 해적 메서드가 실제 호출에
# 계속 응답했다(라운드 3 validator 실측). ⚠️ 2026-08-29 정정: 아래가 인용하는 **호출 경로**
# (`llm_bridge` 의 `HTTP.post` → `replan.jl` 의 3회 재시도)는 Anthropic 레인과 함께 삭제됐다.
# 위험의 **모양**은 그대로다 — 심각도 분기가 producer 경로에 남아 있어 soft 이벤트는 여전히
# 조용히 `:noop` 으로 떨어진다. 옛 경로 서술을 근거로 남긴다: `src/respec/llm_bridge.jl:76` 이
# 키워드 인자로 `HTTP.post` 를 부르고, 그 호출자인 `src/respec/replan.jl:726` 이
# `llm_to_proposal` 의 **모든 예외를 잡아 3회 재시도**한다. 끝내 실패했을 때의 처리는 이벤트
# 안전도로 갈린다(라운드 5 L4 로 좁힌 서술 — 예전 주석은 이 갈림을 뭉갰다):
# `_event_criticality(event) === :soft` 이면(`:740`) `@warn` 하나 남기고 `:noop`(`:742`),
# critical 이면 `engage_fallback!` 후 `:fallback`(`:746`) — 후자는 line-stop 이지 침묵이 아니다.
# 그래서 조용한-실패 위험은 **soft 이벤트 경로 하나**다: 이 파일 뒤(`test/runtests.jl:137` 이후)
# 에 그 경로를 타는 respec LLM 레인 인프로세스 시험이 생기면, 그 시험은 스텁의 시끄러운
# `error(...)` 를 soft 폴백이 삼킨 채 **초록인데 아무것도 안 재는** 상태가 된다 — 이 레포의
# 정본 조용한-실패 모양이다.
#   → 라운드 4 는 **해적질 자체를 없앴다.** `policy.jl:19` 의 `const DSPY_URL` 은 include 시점에
#     `ENV["DSPY_URL"]` 에서 읽히므로, policy.jl 을 include 하기 **전에** 로컬 `HTTP.serve!`
#     리스너를 띄우고 `ENV["DSPY_URL"]` 을 그 포트로 돌려놓으면 요청 본문을 **아무 메서드도 안
#     심고** 가로챌 수 있다. 지울 것도, 지움을 검증할 것도 없다. `HTTP.post` 는 이 파일이 도는
#     내내 진짜 `HTTP.post` 다 — 아래 (5) 가 그걸 **행동으로** 잰다(메서드 테이블 조회가 아니라
#     실제 호출로: 라운드 3 의 테이블 조회 어서션 셋은 정확히 delete_method 가 청소한 그 한
#     테이블만 봤기 때문에 해적이 살아 있는데도 3/3 초록이었다).
#     포트는 `listenany=true` + 포트 0 이라 커널이 비어 있는 것을 골라 준다(고정 포트 충돌 없음).
#     `ENV["DSPY_URL"]` 은 include 직후 원래 값으로 되돌린다(다른 게이트가 같은 프로세스에서
#     policy.jl 을 다시 include 해도 안 물들도록) — 서버는 이 파일 끝의 `finally` 가 닫는다.
#   🔴 **8077(진짜 DSPy 서비스)로는 한 요청도 안 나간다** — `DSPY_URL` 이 우리 루프백 포트를
#     가리키는 상태에서만 policy.jl 이 include 되고, `/decide` 는 과금되는 OpenAI 호출이다.
#
# ⚠️ **숨은 전제 (라운드 3 H3 · 라운드 4 J5 · 🔴 라운드 5 L1/L2 정정)**: (4) 가 `decide_all`
# 호출부 줄을 실제로 태우는 것은 **현재 환경변수 상태에 달려 있다.** `policy.jl:1131` 의
# 삼항식은 `POLICY in (canonical,noop,oracle) && !router_drives() && DEMO_ALL_POLICIES=="0"`
# 세 조건이 **모두** 참일 때만 `service_decide` 호출을 건너뛴다.
#
# 🔴 라운드 3 H3 은 그 이유를 **틀리게** 적었다("`DEMO_ALL_POLICIES` 가 기본 `\"1\"` 이라는
# 사실이 유일하게 건너뛰기를 막는다"). 실제 정의를 읽으면 그렇지 않다:
#     const ROUTER_MODE = lowercase(get(ENV, "DEMO_ROUTER", "auto"))
#     router_drives()   = ROUTER_MODE != "0" && POLICY != "noop"
# `router_drives()` 는 novelty 교정 파일을 **전혀 보지 않는다.** 그래서 기본값
# (`DEMO_ROUTER` 미설정 → `"auto"`, `DEMO_POLICY` 미설정 → `"canonical"`)에서 `router_drives()`
# 는 **참**이고, `!router_drives()` 가 거짓이라 삼항식은 **그것만으로** 건너뛰지 않는다.
# 🔴 [역사 · 2026-08-29 §B-1] 그때 이 술어와 헷갈리던 상대가 `router_enabled()`(= 교정 JSON
# 유무까지 나르던 술어)였고, "novelty calibration not found -> router disabled" 로그도 그쪽
# 이야기였다. **그 함수와 novelty 축 전체가 §B-1 에서 삭제됐다** — 이제 헷갈릴 상대가 없고,
# 위 두 줄이 라우터 손잡이의 전부다. 실측(coordinator, 라운드 5): `withenv("DEMO_ALL_POLICIES"=>"0")`
# 아래서도 요청 본문은 **여전히 잡혔다**(9 Pass / 1 Fail — 전제 어서션 하나만 실패).
#
# 그래서 (4) 안의 전제 어서션은 `DEMO_ALL_POLICIES` 한 항이 아니라 **삼항식의 skip 조건
# 자체를 부정한** 형태다(라운드 5 L2): 하중을 지는 항이 무엇이든, 이 게이트가 서비스 호출을
# 건너뛰는 설정에서 돌면 "본문을 못 받았다"는 하류 증상 대신 전제 자체가 빨개진다.
#
# 이 파일이 재는 다섯 가지:
#   1. `service_decide` 가 `agents` 라는 키워드 인자를 **선언한다** — 메서드 객체에서 직접
#      확인한다(주석이 아니라). (커버: kwarg 선언 줄만. payload 조립·호출부는 아래 (4).)
#   2. 실제 env 에서 `CB.open_agent_descriptors(env)` 가 **비어 있지 않은**
#      `Vector{Dict{String,String}}` 을 내고, 모든 원소가 `"id"`·`"label"` 을 둘 다 가진다.
#      (커버: `open_agent_descriptors` 원시 함수 자체. 호출부가 이 함수를 **부르는지**는 안 잰다.)
#   3. **음성 대조**: `CB.open_agent_descriptors(env.sched)` 는 던진다. `env` 대신 `env.sched` 를
#      넘기면 함수가 안에서 다시 `.sched` 를 찾다가 죽는다는, 이 계획이 잡은 정확한 버그를 그
#      원시 함수 수준에서 못박는다. (커버: 원시 함수의 인자 계약. `decide_all` 호출부가 실제로
#      `env` 를 넘기는지는 이 어서션 혼자로는 안 잰다 — 그건 아래 (4) 의 몫이다.)
#   4. **payload 조립 + `decide_all` 호출부, 둘 다 실제 실행으로**: `decide_all(env, truth)` 가
#      네트워크로 나가는 요청 본문에 `open_agent_descriptors(env)` 와 같은 `"agents"` 를 싣는다.
#   5. **위생**: 이 파일은 `HTTP.post` 를 해적질하지 않는다 — 진짜 `HTTP.post` 가 진짜
#      `ConnectError` 를 낸다는 것을 **실제 호출로** 확인한다.
#
# 실행: julia +lts --project=. test/service_decide_ships_agents.jl
# =============================================================================
module ServiceDecideShipsAgents

using Test
using ConstructionBots
const CB = ConstructionBots
import HTTP, JSON3
import Random
# 🔴 `Sockets` 를 **직접 import 하지 않는다**(라운드 5 K1). stdlib 이라도 `Project.toml` 의
# `[deps]` 에 없으면 `Pkg.test()` 가 만드는 **샌드박스 환경**에서 안 풀린다 — 실측:
# `LoadError: ArgumentError: Package Sockets not found in current path.` 로 이 게이트가 통째로
# 에러였다(`test/runtests.jl:137`). 단독 실행(`julia --project=.`)은 기본 `LOAD_PATH` 의
# `@stdlib` 덕에 그냥 풀려서 초록이었다 — 그래서 라운드 4 의 "단독 초록" 은 스위트에 대한
# 증거가 아니었다. `HTTP` 가 `Sockets` 에 의존하고 그 바인딩을 그대로 들고 있으므로
# `HTTP.Sockets.*` 로 닿는다: 공유 파일인 `Project.toml` 을 건드릴 이유가 없다.
# Graphs 는 policy.jl 의 `_agent_pending`(ood_features 경유, service_decide 가 부른다)이 쓴다
# -- policy.jl 은 스크립트라 자기 의존성을 안 들고 온다(CLAUDE.md Gotchas). policy_macro_binding.jl
# ·battery_menu_lanes_agree.jl 은 service_decide 를 안 불러서 이게 없어도 됐다; 이 파일은 (4)
# 에서 실제로 부르므로 있어야 한다(tools/test_policy_oracle.jl 과 같은 이유로 같은 import).
import Graphs

const REPO = normpath(joinpath(@__DIR__, ".."))

isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))

# ---- (4) 를 위한 로컬 DSPy 대역 서버 (라운드 4 J1, route b) ------------------
# policy.jl 이 부르는 두 엔드포인트만 답한다. `/decide` 의 본문이 이 시험의 측정값이다.
# 핸들러는 서버 태스크에서 돌지만, 클라이언트(`HTTP.post`)가 응답을 받을 때까지 블록하므로
# `_CAPTURED_BODY[]` 를 아래에서 읽는 시점엔 쓰기가 이미 끝나 있다.
const _CAPTURED_BODY = Ref{Union{Nothing,String}}(nothing)
const _SERVER = HTTP.serve!(HTTP.Sockets.localhost, 0; listenany = true, verbose = -1) do req
    if req.target == "/health"
        # policy.jl 의 `dspy_ready()` 가 찌르는 자리. 여기서 200 을 안 주면 `service_decide` 가
        # 곧장 nothing 을 돌려주고 (4) 는 "본문을 못 받았다"로 **빨개진다**(조용히 안 샌다).
        # 🔴 2026-08-29 (T11): `surro_kinds` 를 **반드시** 싣는다. kind 색인 라우터가 이 값을
        #    `/health` 에서만 받고, 없으면 "못 쟀다"로 캐시한 뒤 `select_lane` 이 그 사건에서
        #    **죽는다**(§0-C 결정 3 의 설계된 동작). 실측: 이 줄이 없으면 `decide_all` 을
        #    부르는 절이 "surrogate kind support is unknown" 으로 정당하게 빨개진다.
        #    값은 서비스의 실측 기준값(`oracle_dataset.jsonl` 33행)과 같다.
        return HTTP.Response(200, "{\"status\":\"ok\",\"surro_kinds\":[\"battery\",\"fault\"]}")
    elseif req.target == "/decide"
        _CAPTURED_BODY[] = String(req.body)
        # 🔴 2026-08-29 (T11): 여기 있던 `Dict("dspy"=>nothing,"surrogate"=>nothing)` 은 이제
        #    **못 쓴다.** 근거였던 *"둘 다 null 이면 policy_entry 가 unavailable 로 채운다"* 는
        #    참이지만, 새 라우터는 고른 레인이 unavailable 이면 `error()` 로 **죽는다**
        #    (§0-C 결정 3) — 그러면 요청을 잰다는 이 파일의 목적 자체가 도달 불가가 된다.
        #    ⟹ **요청된 레인마다 최소한의 유효 결정을 돌려준다.** `payload["lanes"]` 를 읽으므로
        #    라우팅이 또 바뀌어도 이 픽스처는 안 깨진다(kind 축이 무엇을 고르든 따라간다).
        #    이 파일은 여전히 응답이 아니라 **요청**을 잰다 — 아래 값은 죽지 않기 위한 최소치다.
        local _req_lanes = try
            local pl = JSON3.read(_CAPTURED_BODY[])
            haskey(pl, :lanes) ? String.(collect(pl[:lanes])) : ["dspy", "surrogate"]
        catch
            ["dspy", "surrogate"]
        end
        local _ok = Dict{String,Any}("chosen" => _NOOP_NAME, "ranking" => [_NOOP_NAME],
                                     "margin" => 0.0, "rationale" => "fake (request gate)",
                                     "policy" => "test", "unsupported" => String[])
        return HTTP.Response(200, JSON3.write(Dict{String,Any}(l => _ok for l in _req_lanes)))
    end
    return HTTP.Response(404, "")
end
const _PORT = HTTP.Servers.port(_SERVER)

# policy.jl 은 이 모듈 안으로 include 된다(policy_macro_binding.jl 과 같은 패턴) — `service_decide`
# 도 `decide_all` 도 `dspy_ready` 도 그 include 를 통해 **이 모듈 안에서만** 정의된다.
# `const DSPY_URL`(policy.jl:19)은 **include 시점에 한 번** ENV 에서 읽히므로, 그 순간에만
# ENV 를 우리 포트로 돌려놓고 곧바로 되돌린다.
#
# 🔴 (라운드 5 K3) `_SERVER` 를 연 뒤부터 모듈 본문이 끝날 때까지, **밖으로 나가는 모든 길**에
# `close(_SERVER)` 가 있어야 한다. 아래 세 곳이 그 전부다: (i) 이 include, (ii) `TENV` 구축,
# (iii) 테스트 블록. 라운드 4 는 (iii) 만 감쌌다 — (i)/(ii) 가 던지면 모듈 본문이 (iii) 의
# `try/finally` 에 닿기 전에 중단돼 리스너가 프로세스 수명 내내 샜다(실측: 아래 K3-a/K3-b).
const _PREV_DSPY_URL = get(ENV, "DSPY_URL", nothing)
ENV["DSPY_URL"] = "http://127.0.0.1:$(_PORT)"
try
    include(joinpath(REPO, "tools", "monitor", "policy.jl"))
catch
    close(_SERVER)   # (i) 여기서 죽으면 아래 (iii) 의 finally 에 영영 못 닿는다
    rethrow()
finally
    _PREV_DSPY_URL === nothing ? delete!(ENV, "DSPY_URL") : (ENV["DSPY_URL"] = _PREV_DSPY_URL)
end

# 🔴 매크로 이름 리터럴을 쓰지 않는다(`test/policy_macro_binding.jl:134` 의 규칙) —
#    레지스트리에서 유도한다. `ActionRegistry` 는 위 policy.jl include 가 들여온다.
#    위 서버 클로저는 **호출 시점에** 이 전역을 읽으므로 정의 순서는 무관하다.
const _NOOP_NAME = ActionRegistry.NAME[0]

# 실 env 를 짓는 것이 이 파일에서 가장 비싼 부분이다(policy_macro_binding.jl 의 env 구축과
# 비슷한 비용 — 이 시험이 도는 값이다). 씬은 SCENE-INCANTATION 정본과 같되, 여기서는
# 시뮬레이션을 한 스텝도 돌리지 않는다 — `open_agent_descriptors` 가 읽는 것은 배정이 끝난
# **스케줄 그래프**뿐이고, 그것은 `run_lego_demo` 가 return_env_before_sim=true 로 돌려주는
# 시점에 이미 완성돼 있다(로봇 배정까지 끝난 뒤). `@testset` 블록은 로컬 스코프라 `const` 를
# 그 안에 못 두므로, 모듈 최상위(테스트 블록 바깥)에서 짓는다.
const TENV = try
    CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr",
                       project_name = "service_decide_agents",
                       num_robots = 4, assignment_mode = :greedy,
                       n_spare_per_pool = 2,
                       open_animation_at_end = false, save_animation = false,
                       write_results = false, return_env_before_sim = true,
                       rng = Random.MersenneTwister(1))
catch
    close(_SERVER)   # (ii) 씬 구축이 던져도 리스너는 남기지 않는다
    rethrow()
end

# (iii) 마지막 길. `try/finally` 는 오직 **서버를 닫기 위한** 것이다(테스트가 통과하든,
# 어서션이 예외를 던지든). 예외를 삼키지 않으므로 실패는 그대로 위로 전파된다 — 라운드 3 의
# `catch e` / 재던짐 분기는
# 라운드 4 에서 제거했다(J4): `test/runtests.jl:136-137` 아래서는 이 testset 이 **중첩**이라
# 실패한 `@test` 가 부모로 기록될 뿐 `TestSetException` 이 여기서 던져지지 않는다 — 그 분기는
# 실제로 도는 배선에서 한 번도 안 탔다(단독 실행에서만 탔다).
try
    @testset "service_decide 가 agents 를 payload 에 싣는다" begin

    @testset "(1) service_decide 는 agents 키워드를 선언한다" begin
        local decls = Iterators.flatten(Base.kwarg_decl(m) for m in methods(service_decide))
        @test :agents in collect(decls)
    end

    @testset "(2) open_agent_descriptors(env) 가 실재 로봇을 낸다" begin
        local ag = CB.open_agent_descriptors(TENV)
        @test ag isa Vector{Dict{String,String}}
        @test !isempty(ag)
        @test all(d -> haskey(d, "id") && haskey(d, "label"), ag)
    end

    @testset "(3) 음성 대조 — env.sched 를 넘기면 던진다" begin
        # 브리프가 못박은 바로 그 버그: `open_agent_descriptors` 는 `env` 를 받아 **안에서**
        # `sched = env.sched` 를 꺼낸다. `env.sched` 를 직접 넘기면 그게 다시 `.sched` 를 찾다가
        # 죽는다. 이 어서션은 그 원시 함수의 인자 계약을 잰다 — `decide_all` 호출부가 실제로
        # `env`(아닌 `env.sched`)를 넘기는지는 이 원시 함수 검사 혼자로는 못 잰다(라운드 2에서
        # 실측된 한계). 그건 바로 아래 (4) 가 `decide_all` 을 직접 실행해서 잰다.
        @test_throws ErrorException CB.open_agent_descriptors(TENV.sched)
    end

    @testset "(4) decide_all → service_decide 가 실제로 agents 를 실어 보낸다 (로컬 HTTP 서버)" begin
        # 라운드 2 (G1+G2) 가 요구한 바로 그 시험: payload 조립 줄과 decide_all 호출부 줄을
        # 둘 다 **실제로** 태운다. `decide_all` 을 부르면 그 안에서 (조건에 따라 -- 위 헤더의
        # H3/J5 경고 참조) `service_decide` 가 불리고, 그 안에서 진짜 `HTTP.post` 가 위
        # `_SERVER` 로 나간다 -- 핸들러가 그 요청 본문을 붙잡는다.
        #
        # (J5, 라운드 5 L2 로 정정) (4) 의 커버리지가 매달려 있는 숨은 전제를 하류 증상 대신
        # 여기서 직접 이름 붙인다. 라운드 4 형태(`DEMO_ALL_POLICIES != "0"` 한 항)는 **틀린
        # 항**을 쟀다 — 기본 설정에서 하중을 지는 것은 `!router_drives()` 가 거짓인 쪽이고,
        # `DEMO_ALL_POLICIES=0` 만으로는 건너뛰지 않는다(위 헤더 L1 문단, 실측 포함).
        # 그러니 `policy.jl:1131` 의 skip 조건을 **그대로 부정해서** 쓴다.
        @test !(POLICY in ("canonical", "noop", "oracle") && !router_drives() &&
                get(ENV, "DEMO_ALL_POLICIES", "1") == "0")
        _CAPTURED_BODY[] = nothing
        local truth = CB.BatteryTruth(CB.RobotID(1), 0.5)
        decide_all(TENV, truth; nl = "")
        # 서버가 실제로 요청을 받았는가 -- 안 받았으면 `service_decide` 가 아예 안 불렸거나
        # (삼항식의 then 가지) `dspy_ready()` 가 false 로 떨어진 것이고, 어느 쪽이든 이 시험은
        # 아무것도 안 잰 것이다. 그래서 이 assert 가 없으면 "호출이 통째로 없었다" 를
        # "통과했다" 로 오독한다.
        @test _CAPTURED_BODY[] !== nothing
        local parsed = JSON3.read(something(_CAPTURED_BODY[], "{}"))
        @test haskey(parsed, "agents")
        local wire_agents = [Dict{String,String}(string(k) => string(v) for (k, v) in pairs(a))
                             for a in get(parsed, "agents", [])]
        @test wire_agents == CB.open_agent_descriptors(TENV)
    end

    @testset "(5) 이 파일은 HTTP.post 를 해적질하지 않는다" begin
        # 🔴 이 어서션은 **행동**을 잰다(라운드 4 J2). 메서드 테이블 조회(`methods`/`which`)로는
        # 이 성질을 못 잰다 -- 라운드 3 이 그렇게 쟀고, `Core.kwcall` 정렬 메서드가 살아서 실제
        # 키워드 호출에 계속 응답하는 동안에도 3/3 초록이었다. 그러니 진짜로 **부른다**:
        # 포트 9(discard)는 아무도 안 듣고 있어 커널이 즉시 RST 를 준다. 진짜 `HTTP.post` 면
        # `ConnectError` 가 나고, 누군가 이 제네릭을 이 시그니처로 해적질해 뒀으면 그 스텁의
        # 반환값이나 그 스텁의 예외가 대신 나와 이 어서션이 빨개진다.
        # 모양은 실제 생산 호출자와 맞춘다(키워드 인자 -- 그게 kwcall 로 가는 경로다):
        # policy.jl:559 (readtimeout/retries/retry_non_idempotent) · llm_bridge.jl:76.
        @test_throws HTTP.Exceptions.ConnectError HTTP.post(
            "http://127.0.0.1:9/x", ["a" => "b"], "{}";
            retries = 0, readtimeout = 2, connect_timeout = 2)
    end

    end # testset
finally
    close(_SERVER)
end

end # module
