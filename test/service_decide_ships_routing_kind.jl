# =============================================================================
# `service_decide` 가 **라우터의 kind 판정**(`routing_kind`)을 요청 본문에 실어 보내는지
# 못박는다. (2026-08-29, §A-1)
#
# 왜 이 파일이 필요한가
# ----------------------
# kind 색인 라우터(T11)는 처음 보는 `OODTruth` 타입을 `routing_kind = "unknown:<타입이름>"`
# 으로 알아보고 그 사건을 **LLM 으로 보낸다**. 그런데 §A-1 이전에는 **그 판정이 페이로드에
# 한 글자도 안 실렸다**: 본문의 `kind` 는 `ood_features` 의 `else` 분기라 `"unknown"` 이고
# (2026-09-07 이전에는 `"fault"` 였다 — 그 리터럴은 자기모순이라 지웠다),
# 서비스의 `_valid_for` 는 fault 메뉴를 준다. 즉 모델은 자기가 **처음 보는 사건**을 받았다는
# 사실을 모른 채, 가장 가까운 알려진 스키마로의 **투영**을 사실로 읽고 답했다.
#
# 고친 줄은 `tools/monitor/policy.jl` 의 `service_decide` 안 한 줄이다:
#   payload["routing_kind"] = routing_kind(String(nameof(typeof(truth))))
# 🔴 이 값은 **키워드로 받지 않는다**(Ruling R1). `agents`/`zones`/`lanes` 는 호출자만 아는
#    값이라 키워드가 옳지만, `routing_kind` 는 타입 이름의 **전총 순수 함수**이고 `decide_all`
#    의 라우터가 이미 같은 함수로 같은 값을 만든다. 유도를 `service_decide` 안에 두면 라우터와
#    페이로드가 **구조적으로** 갈릴 수 없다 — 그 갈림이 §A-1 이 지목한 결함 그 자체다.
#
# 🔴 왜 "선언·순수 함수 검사"만으로는 부족한가
# --------------------------------------------
# `routing_kind` 자체는 `test/tool_choice_gate.jl` 이 이미 전수로 잰다. 그러나 그 시험은
# 위 한 줄을 **한 번도 안 태운다** — 원래 결함(값은 유도되는데 페이로드에 안 실린다)이 정확히
# 거기 살아 있었다. 그래서 이 파일은 `service_decide_ships_zones.jl` 과 같은 방식으로 잰다:
# **루프백에 진짜 HTTP 서버를 띄우고** `DSPY_URL` 이 그것을 가리키는 상태에서 policy.jl 을
# include 한 뒤 `decide_all` 을 **실제로 실행**해, 네트워크로 나간 요청 본문을 붙잡아 읽는다.
#
# 🔴 **8077(진짜 DSPy 서비스)로는 한 요청도 안 나간다.** `/decide` 는 사용자 계정에 과금되는
#    OpenAI 호출이다. `const DSPY_URL`(policy.jl)은 include 시점에 ENV 에서 **한 번** 읽히므로,
#    우리 포트를 가리키는 동안에만 include 하고 곧바로 되돌린다.
#
# 🔴 `import Sockets` 를 **하지 않는다**(agents 게이트 라운드 5 K1 의 실측). stdlib 이라도
#    `Project.toml` 의 `[deps]` 에 없으면 `Pkg.test()` 샌드박스에서 안 풀려 게이트가 통째로
#    **에러**가 된다 — 단독 실행은 `@stdlib` 덕에 초록이라 그 차이가 안 보인다. `HTTP` 가
#    `Sockets` 를 의존하므로 `HTTP.Sockets.*` 로 닿는다.
#
# 이 파일이 재는 것
# ------------------
#   (1) **알려진 kind**(`FaultTruth` · `BatteryTruth`): 본문의 `routing_kind` 가 `kind` 와 같다.
#       두 유도가 알려진 셋에서 갈리면 그 자체가 회귀다.
#   (2) 🔴 **모르는 타입**(`MeteorTruth`, 이 모듈이 정의): **같은 본문 하나 안에서**
#       `routing_kind == "unknown:MeteorTruth"` 이면서 `kind == "unknown"` 이다.
#       둘을 함께 단언하는 것이 §A-1 의 비대칭이 페이로드까지 살아서 도착했다는 유일한 증거다
#       (`kind` 는 surrogate 피처라 **일부러 안 고친다** — Global Constraint 3).
#   (3) 그 사건이 실제로 **LLM 레인으로 라우팅됐다** — 즉 (2)의 본문은 라우터가 "처음 보는
#       사건"이라고 판정한 바로 그 사건의 본문이다.
#
# 음성 대조는 이 파일 밖에서 돌렸다(레포 파일을 깨지 않는다): `/tmp` 사본에서 위 payload
# 한 줄을 지우면 (1)(2)가 `routing_kind` 키 부재로 빨개진다. 출력은 태스크 보고서
# `.superpowers/sdd/2026-08-29-t8-t12-gap-closure/task-1-report.md` 에 있다.
#
# 실행: julia +lts --project=. test/service_decide_ships_routing_kind.jl
# =============================================================================
module ServiceDecideShipsRoutingKind

using Test
using ConstructionBots
const CB = ConstructionBots
import HTTP, JSON3
import Random
# policy.jl 의 `_agent_pending`(ood_features 경유, service_decide 가 부른다)이 Graphs 를 쓴다.
# policy.jl 은 스크립트라 자기 의존성을 안 들고 온다(CLAUDE.md Gotchas).
import Graphs

const REPO = normpath(joinpath(@__DIR__, ".."))

# FaultTruth / BatteryTruth / OODTruth 는 런타임 include 계층(navigator.jl)에 산다.
isdefined(CB, :ZoneTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))

# 🔴 **이 시험의 핵심 픽스처.** 레포의 어떤 코드도 모르는 `OODTruth` 구상 타입이다 —
#    `ood_features` 는 이것을 `else` 분기로 접어 `kind="unknown"` 을 주고, `routing_kind` 는
#    이름을 그대로 살려 `"unknown:MeteorTruth"` 를 준다. 그 **두 값이 갈리는 것**이 곧
#    §A-1 이 말하는 OOD 사건이고, 이 파일이 재는 대상이다.
#    (필드가 없는 struct 인 것이 의도적이다: 알려진 kind 의 필드를 하나도 안 가진 사건에서도
#     결정 레인이 살아 있어야 한다. `canonical_respec` 에 이 타입의 메서드가 없지만
#     `canonical_macro` 가 try/catch 로 "NOOP" 을 내므로 `decide_all` 은 죽지 않는다.)
struct MeteorTruth <: CB.OODTruth end

# ---- 로컬 DSPy 대역 서버 -----------------------------------------------------
# policy.jl 이 찌르는 두 엔드포인트만 답한다. `/decide` 의 본문이 이 시험의 측정값이다.
# 핸들러는 서버 태스크에서 돌지만 클라이언트가 응답을 받을 때까지 블록하므로, 아래에서
# `_CAPTURED_BODY[]` 를 읽는 시점엔 쓰기가 이미 끝나 있다.
const _CAPTURED_BODY = Ref{Union{Nothing,String}}(nothing)
const _SERVER = HTTP.serve!(HTTP.Sockets.localhost, 0; listenany = true, verbose = -1) do req
    if req.target == "/health"
        # 🔴 `surro_kinds` 를 **반드시** 싣는다(Global Constraint 10). kind 색인 라우터가 이
        #    값을 `/health` 에서만 받고, 없으면 "못 쟀다"로 캐시한 뒤 `select_lane` 이 그
        #    사건에서 **죽는다**(§0-C 결정 3 의 설계된 동작).
        #    값은 서비스의 실측 기준값(`oracle_dataset.jsonl` 33행)과 같다 — 그래서 아래
        #    `MeteorTruth` 가 **그 집합 밖**이라는 것이 이 픽스처 안에서 참이다.
        return HTTP.Response(200, "{\"status\":\"ok\",\"surro_kinds\":[\"battery\",\"fault\"]}")
    elseif req.target == "/decide"
        _CAPTURED_BODY[] = String(req.body)
        # 🔴 요청된 레인마다 최소한의 유효 결정을 돌려준다. 새 라우터는 고른 레인이
        #    unavailable 이면 `error()` 로 죽으므로(§0-C 결정 3), 죽지 않는 최소치가 필요하다.
        #    `payload["lanes"]` 를 읽으므로 라우팅이 또 바뀌어도 이 픽스처는 안 깨진다.
        #    이 파일은 여전히 응답이 아니라 **요청**을 잰다.
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

# 🔴 `_SERVER` 를 연 뒤 모듈 본문이 끝날 때까지 **밖으로 나가는 모든 길**에 `close(_SERVER)`
#    가 있어야 한다(agents 게이트 라운드 5 K3 이 실측한 누수). 아래 넷이 그 전부다:
#    (i) 이 include, (i-b) `_NOOP_NAME` 유도, (ii) TENV 구축, (iii) 테스트 블록.
#    ((i-b) 는 2026-08-29 fix round 1 에서 더했다 — 그때까지 감싸여 있지 않았다.)
const _PREV_DSPY_URL = get(ENV, "DSPY_URL", nothing)
ENV["DSPY_URL"] = "http://127.0.0.1:$(_PORT)"
try
    include(joinpath(REPO, "tools", "monitor", "policy.jl"))
catch
    close(_SERVER)   # (i)
    rethrow()
finally
    _PREV_DSPY_URL === nothing ? delete!(ENV, "DSPY_URL") : (ENV["DSPY_URL"] = _PREV_DSPY_URL)
end

# 🔴 매크로 이름 리터럴을 쓰지 않는다(`test/policy_macro_binding.jl:134` 의 규칙) —
#    레지스트리에서 유도한다. `ActionRegistry` 는 위 policy.jl include 가 들여온다.
#    위 서버 클로저는 **호출 시점에** 이 전역을 읽으므로 정의 순서는 무관하다.
# 🔴 2026-08-29 (fix round 1): 이 줄이 **`close(_SERVER)` 가 없는 유일한 밖으로 나가는 길**이었다
#    — 레지스트리 색인 0 이 사라지거나 `ActionRegistry` 가 안 들여와지면 여기서 던지고, 그러면
#    리스너가 열린 채 `Pkg.test()` 의 나머지로 샌다(위 주석이 "아래 셋이 그 전부다" 라고 적은
#    목록에서 빠져 있던 네 번째 길이다). 형제 게이트 셋과 같은 규약으로 감싼다.
const _NOOP_NAME = try
    ActionRegistry.NAME[0]
catch
    close(_SERVER)   # (i-b)
    rethrow()
end

# 실 env 구축이 이 파일에서 가장 비싼 부분이다. 씬은 zones/agents 게이트의 정본과 같다.
# 시뮬레이션은 한 스텝도 안 돌린다 — `ood_features` 가 읽는 것(스케줄 그래프 · cache)은
# `return_env_before_sim=true` 시점에 이미 완성돼 있다.
const TENV = try
    CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr",
                       project_name = "service_decide_routing_kind",
                       num_robots = 4, assignment_mode = :greedy,
                       n_spare_per_pool = 2,
                       open_animation_at_end = false, save_animation = false,
                       write_results = false, return_env_before_sim = true,
                       rng = Random.MersenneTwister(1))
catch
    close(_SERVER)   # (ii)
    rethrow()
end

"`decide_all` 을 한 번 돌리고 붙잡힌 요청 본문을 파싱해 돌려준다. 못 받았으면 nothing."
function _capture_decide(truth)
    _CAPTURED_BODY[] = nothing
    local out = decide_all(TENV, truth; nl = "")
    local b = _CAPTURED_BODY[]
    return (body = (b === nothing ? nothing : JSON3.read(b)), decision = out)
end

# (iii) 마지막 길. `try/finally` 는 오직 리스너를 닫기 위한 것이다 — 예외를 삼키지 않는다.
try
    @testset "service_decide 가 routing_kind 를 payload 에 싣는다" begin

    # 이 게이트가 무언가를 재려면 `decide_all` 이 `service_decide` 를 **실제로 불러야** 한다.
    # 하류 증상("본문을 못 받았다") 대신 전제 자체를 여기서 이름 붙여 빨개지게 한다.
    @testset "(0) 전제: 라우터가 이 런에서 레인을 고른다" begin
        # `router_drives()` 가 false 면 레인이 `POLICY` 로 고정돼 dspy/surrogate 를 안 부를 수
        # 있고, 그러면 아래 절들이 "본문 없음"으로 죽는다 — 이유를 여기서 이름 붙인다.
        @test router_drives()
        # 그리고 대역 `/health` 가 실제로 읽혔다 = 라우터가 kind 지원집합을 쟀다.
        # (못 쟀으면 `select_lane` 이 정당하게 죽으므로 이 게이트 전체가 도달 불가가 된다.)
        @test surro_kinds() == Set(["battery", "fault"])
    end

    @testset "(1) 알려진 kind — routing_kind 가 payload 의 kind 와 같다" begin
        # 두 유도(`ood_features` 의 `isa` 축 · `routing_kind` 의 이름 축)는 **다른 함수**다.
        # 알려진 셋에서 갈리면 그것 자체가 회귀이고, 여기서 **실제로 나간 본문**으로 잰다.
        # 🔴 **battery 는 severe 여야 한다** (2026-08-30). `routing_kind` 가 이 날부터 심각도를
        #    보므로, 옛 픽스처(`soc_after = 0.5`)는 이제 `"unknown:battery_mild"` 를 낸다 —
        #    즉 이 절의 "알려진 kind" 라는 이름이 그 픽스처에 대해 더 이상 참이 아니다.
        #    경계는 `lane_select.jl` 의 `ROUTING_SEVERE_SOC`(0.1) 이고, 그 상수 주석에 근거와
        #    대가가 있다. mild 판은 아래 (1-b) 가 **갈린다는 것 자체**를 잰다.
        for truth in (CB.FaultTruth(CB.RobotID(1), Float64[0.0, 0.0]),
                      CB.BatteryTruth(CB.RobotID(1), 0.02))
            local cap = _capture_decide(truth)
            @test cap.body !== nothing          # 못 받았으면 아무것도 안 잰 것이다
            @test haskey(cap.body, "routing_kind")
            @test String(cap.body["routing_kind"]) == String(cap.body["kind"])
            # 항진명제 방지: 그 공통값이 실제로 이 사건의 kind 다(둘 다 빈 문자열이 아니다).
            @test String(cap.body["kind"]) ==
                  (truth isa CB.FaultTruth ? "fault" : "battery")
        end
    end

    @testset "(1-b) mild battery — 같은 타입인데 본문 안에서 두 값이 갈린다" begin
        # 🔴 이것이 2026-08-30 사용자 결정의 페이로드 쪽 증거다. (2)의 `MeteorTruth` 는 **타입이
        #    미지**라서 갈리는데, 여기서는 **타입이 알려져 있고 심각도만 다르다.** 즉 갈림이
        #    "모르는 타입" 축이 아니라 **"학습 범위 밖" 축**에서도 페이로드까지 도착하는가를 잰다.
        # ⚠️ `kind` 는 여전히 `"battery"` 다 — surrogate 행의 열이라 한 글자도 안 건드린다
        #    (Global Constraint 3). 갈리는 것은 `routing_kind` 뿐이다.
        local cap = _capture_decide(CB.BatteryTruth(CB.RobotID(1), 0.5))
        @test cap.body !== nothing
        @test String(cap.body["kind"]) == "battery"
        @test String(cap.body["routing_kind"]) == "unknown:battery_mild"
        @test String(cap.body["routing_kind"]) != String(cap.body["kind"])
        # 그리고 그 판정대로 실제 레인이 갈렸다 — 이름만 갈리고 라우팅이 안 갈리면 무의미하다.
        @test cap.decision.enacted == "dspy"
        @test cap.decision.router["router_axis"] == "ood_kind"
        @test String.(collect(cap.body["lanes"])) == ["dspy"]
    end

    @testset "(1-c) zone — 접두사가 붙고 LLM 레인으로 간다" begin
        # 🔴 2026-08-30 이전 zone 은 `routing_kind` 가 `"zone"` 을 냈다. dspy 로 가긴 갔지만
        #    (`"zone" ∉ known_kinds`) 접두사가 없어서 `_unfamiliar_block` 이 **한 번도 안 붙었다.**
        #    이 절은 그 조용한 구멍이 다시 열리는 것을 막는다.
        local cap = _capture_decide(CB.ZoneTruth(:rk_gate_zone, [0.0, 0.0, 0.0], 1.0))
        @test cap.body !== nothing
        @test String(cap.body["kind"]) == "zone"                  # 피처 열은 그대로
        @test String(cap.body["routing_kind"]) == "unknown:zone"  # 라우팅만 갈린다
        @test cap.decision.enacted == "dspy"
    end

    @testset "(2) 모르는 타입 — 같은 본문에서 routing_kind 와 kind 가 갈린다" begin
        local cap = _capture_decide(MeteorTruth())
        @test cap.body !== nothing
        @test haskey(cap.body, "routing_kind")
        # 🔴 **둘을 같은 본문에서 함께 단언한다.** 이것이 §A-1 의 비대칭이 페이로드까지
        #    살아서 도착했다는 유일한 증거다.
        @test String(cap.body["routing_kind"]) == "unknown:MeteorTruth"
        # 🔴 2026-09-07. 여기는 `"fault"` 였고 그 옆에 *"Global Constraint 3 — 이 값은 안
        #    고친다"* 가 붙어 있었다. 그 제약의 **유일한 근거**가 "모르는 타입을 `"fault"` 로
        #    접는 것은 surrogate 피처로는 옳다" 였는데, 그 전제가 거짓이다: surrogate 는
        #    `kind` 를 안 읽는다(`dspy_service._surro_row` 가 일부러 안 싣고,
        #    `descriptors_from_row` 는 계약상 `row['kind']` 를 절대 안 읽는다).
        #    근거가 사라졌으므로 제약도 사라진다 — `ood_features` 의 `else` 는 이제
        #    `("unknown", nothing)` 이다(사용자 결정).
        #    왜 고쳐야 했나: 옛 값은 **같은 프롬프트 안에서 자기모순**이었다. 폴백 경로가
        #    `"OOD kind=fault"` 를 찍는 바로 아래에서 `_unfamiliar_block` 이 "어떤 학습된
        #    범주에도 못 놓았다" 고 말했다.
        @test String(cap.body["kind"]) == "unknown"
        # 갈림 자체는 그대로다 — 이것이 §A-1 의 비대칭이 페이로드까지 도착했다는 증거다.
        @test String(cap.body["routing_kind"]) != String(cap.body["kind"])
    end

    @testset "(3) 그 사건은 실제로 LLM 레인으로 라우팅됐다" begin
        # (2)의 본문이 "라우터가 처음 보는 사건이라고 판정한 그 사건"의 본문임을 못박는다.
        # 이 절이 없으면 (2)는 라우팅과 무관한 어떤 요청에 대해서도 참일 수 있다.
        local cap = _capture_decide(MeteorTruth())
        @test cap.decision.enacted == "dspy"
        @test cap.decision.router["routing_kind"] == "unknown:MeteorTruth"
        @test cap.decision.router["router_axis"] == "ood_kind"
        # 청구된 레인도 그 하나뿐이다 = 본문은 LLM 레인 요청의 본문이다.
        @test String.(collect(cap.body["lanes"])) == ["dspy"]
    end

    end # testset
finally
    close(_SERVER)
end

end # module
