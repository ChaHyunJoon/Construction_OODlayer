# =============================================================================
# tool 레인 키 8개가 서비스 응답 → `policy_entry` → `decide_all(...).tool_lane` 까지
# **살아서** 도착하는지 못박는다. (2026-08-29, Plan B / T1)
#
# 무엇을 지키는가
# ----------------
# DSPy 서비스는 `tool_called · tool_args · tool_calls_n · tools_offered · expressible ·
# native_fc · tool_lane_error · macro_tool_agree` 여덟을 `/decide` 의 `dspy` 본체에 **이미
# 싣고 있었다**(`dspy_service.py:1029-1073` · `:1103-1107`). 그런데 Julia 의 `policy_entry` 가
# 키 목록을 손으로 들고 있어 여덟을 전부 떨어뜨렸다 — 실측 당시
# `grep -rn tool_args --include='*.jl' .` 는 주석 1건만 냈다. T1 이 그 배선을 놓았고,
# 이 파일이 그것을 지킨다.
#
# 🔴 왜 **손으로 만든 dict 를 검사하지 않는가**
# ---------------------------------------------
# 이 레포는 정확히 그 사고를 이미 밟았다: `tools/test_policy_escalation.jl` 의 `unavail()` 이
# `policy_entry` 의 **손으로 쓴 복제본**이었고, 실측 결과 폴백 분기에서 `"unsupported" => miss0`
# 를 지워도 9개 검사가 **전부 초록**이었다(그 회귀가 그대로 복원된다). 복제본을 검사하면
# 복제본만 지켜진다. 그래서 이 파일은 **생산 경로를 실제로 태운다**:
# `test/service_decide_ships_agents.jl` 과 같은 패턴으로 **루프백에 진짜 HTTP 서버를 하나 띄우고**
# `ENV["DSPY_URL"]` 이 그 서버를 가리키는 동안에만 `policy.jl` 을 include 한 뒤
# `decide_all(env, truth)` 를 **실제로 실행**한다.
#
# 🔴 **8077(진짜 DSPy 서비스)로는 한 요청도 안 나간다.** `/decide` 는 사용자 계정의 유료
# OpenAI 호출이다. `const DSPY_URL`(policy.jl:19)은 include 시점에 한 번 ENV 에서 읽히므로,
# 그 순간에만 우리 루프백 포트로 돌려놓고 곧바로 되돌린다.
#
# ⚠️ `Sockets` 를 **직접 import 하지 않는다**. stdlib 이라도 `Project.toml` 의 `[deps]` 에 없으면
# `Pkg.test()` 가 만드는 **샌드박스 환경**에서 안 풀린다 — `service_decide_ships_agents.jl` 이
# 그것으로 게이트 통째가 에러였던 이력이 그 파일 머리말(:106-112)에 있다. 단독 실행은 기본
# `LOAD_PATH` 의 `@stdlib` 덕에 그냥 풀려서 초록이었다 = **단독 초록은 스위트 초록의 증거가
# 아니다.** `HTTP` 가 `Sockets` 를 들고 있으므로 `HTTP.Sockets.*` 로 닿는다.
# `Graphs` 는 policy.jl 의 `_agent_pending`(`ood_features` 경유, `service_decide` 가 부른다)이
# 쓴다 — policy.jl 은 스크립트라 자기 의존성을 안 들고 온다(CLAUDE.md Gotchas).
#
# 검사하는 명제 넷
# ----------------
#  (1) 서버가 8키를 실어 응답하고 그 레인이 실제로 집행되면(`enacted == "dspy"`),
#      `decide_all(...).tool_lane` 이 8키를 **값까지 그대로** 나른다.
#  (2) 🔴 **null 이 null 로 살아온다.** 응답의 `macro_tool_agree`(그리고 `tool_lane_error`)를
#      `null` 로 보내고 `tool_lane` 에서 그것이 `nothing` 인지 단언한다 — `false` 가 아니라.
#      이 단언 하나가 spec §9-2 의 삼상 계약(`nothing`="못 쟀다" ≠ `false`="재서 어긋났다")
#      전체를 진다. Julia 쪽에서 `something(x, false)` 나 `Bool(x)` 로 감싸면 여기서 빨개진다.
#  (3) `enacted` 가 dspy 가 **아닌** 실행에서는 `tool_lane` 의 8개가 전부 `nothing` 이다.
#      🔴 이 검사는 **`pol["dspy"]` 가 그 실행에서 값을 들고 있을 때만** 하중을 진다 — 그래서
#      서버는 dspy 에 8키를 **채워** 보내면서 surrogate 도 가용하게 만들어 `select_lane` 이
#      surrogate 를 고르게 한다. `pol[enacted]` 를 `pol["dspy"]` 로 되돌리면 이 검사가 빨개진다.
#      (dspy 를 unavailable 로 만드는 구성으로 재면 두 표현이 **같은 값**을 내므로 아무것도
#       안 잰다 — 그 구성이 이 파일이 피한 함정이다.)
#  (4) 폴백 분기(서비스가 `error` 를 냄)에서도 `pol["dspy"]` 에 키 8개가 **존재하고** 전부
#      `nothing` 이다 — 키가 사라지지 않는다. 키를 있을 때만 싣는 설계는 "키가 없다"와
#      "값이 null 이다"를 구분 불가능하게 만든다(Plan A 가 밟은 presence-gated 결함).
#
# 실행: julia +lts --project=. test/tool_lane_keys_survive.jl
# =============================================================================
module ToolLaneKeysSurvive

using Test
using ConstructionBots
const CB = ConstructionBots
import HTTP, JSON3
import Random
import Graphs

const REPO = normpath(joinpath(@__DIR__, ".."))

isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))

# ---- 루프백 DSPy 대역 서버 ---------------------------------------------------------------
# 한 서버가 세 응답 모양을 낸다(`_MODE[]`). 세 모양 전부 `decide_all` 을 **실제로** 태우고,
# 서로 다른 레인이 집행되게 만드는 것이 이 파일의 측정 장치다.
#   :lane      dspy 가용(8키 적재, 두 개는 null) · surrogate 불가 → select_lane 이 dspy 를 고른다
#   :surro     dspy 가용(8키 적재, null 없음)   · surrogate 가용  → select_lane 이 surrogate 를 고른다
#   :err       dspy 가 error → policy_entry 의 **폴백 분기** · surrogate 불가 → canonical
const _MODE = Ref{Symbol}(:lane)

# 응답에 싣는 tool 레인 값. 검사가 이 상수를 그대로 대조하므로 두 벌이 갈릴 수 없다.
# `tool_args` 는 서비스에서 JSON 객체로 오고, 현행 tool 알파벳(`tool_registry.py`)의 인자는
# `agent::String` 또는 `reason::String` 하나뿐이라 평평하다.
const _LANE_FULL = Dict{String,Any}(
    "tool_called" => "deliver_battery",
    "tool_args" => Dict{String,Any}("agent" => "robot-1"),
    "tool_calls_n" => 1,
    "tools_offered" => 3,
    "expressible" => true,
    "native_fc" => true,
    "tool_lane_error" => "tool-call parse failed: unterminated JSON",
    "macro_tool_agree" => true)

# (2) 를 위해 **삼상의 왼쪽 끝**을 실제로 보낸다: 두 키를 `null` 로. `nothing` 은 JSON3.write
# 가 `null` 로 직렬화한다.
const _LANE_WITH_NULLS = merge(_LANE_FULL, Dict{String,Any}(
    "macro_tool_agree" => nothing, "tool_lane_error" => nothing))

_dspy_body(lane) = merge(Dict{String,Any}(
    "chosen" => "SwapBattery", "ranking" => ["SwapBattery", "NOOP"], "margin" => 0.4,
    "rationale" => "fake service", "policy" => "dspy:test", "unsupported" => String[]), lane)

const _SURRO_BODY = Dict{String,Any}(
    "chosen" => "NOOP", "ranking" => ["NOOP", "SwapBattery"], "margin" => 0.2,
    "rationale" => "fake surrogate", "policy" => "surrogate:test",
    "scores" => Dict("NOOP" => 0.7, "SwapBattery" => 0.3), "unsupported" => String[])

const _SERVER = HTTP.serve!(HTTP.Sockets.localhost, 0; listenany = true, verbose = -1) do req
    if req.target == "/health"
        # `dspy_ready()` 가 찌르는 자리. 200 을 안 주면 `service_decide` 가 곧장 nothing 을
        # 돌려주고 아래 검사들이 "레인이 안 왔다"로 **빨개진다**(조용히 안 샌다).
        return HTTP.Response(200, "{\"status\":\"ok\"}")
    elseif req.target == "/decide"
        local m = _MODE[]
        local out = if m === :lane
            Dict{String,Any}("dspy" => _dspy_body(_LANE_WITH_NULLS), "surrogate" => nothing)
        elseif m === :surro
            Dict{String,Any}("dspy" => _dspy_body(_LANE_FULL), "surrogate" => _SURRO_BODY)
        else
            # 폴백 분기: `error` 가 있으면 `policy_entry` 가 성공 분기를 통째로 건너뛴다.
            # 🔴 그런데 tool 레인 키는 **여전히 응답에 실려 있다** — 그래도 폴백은 8키를
            #    전부 `nothing` 으로 내야 한다(spec §4-1: tool 실패가 결정을 지우지 않는다는
            #    계약의 Julia 쪽 짝은 "레인이 안 돌았다"를 `available` 로 가르는 것이다).
            Dict{String,Any}("dspy" => merge(_dspy_body(_LANE_FULL),
                                             Dict{String,Any}("error" => "service blew up")),
                             "surrogate" => nothing)
        end
        return HTTP.Response(200, JSON3.write(out))
    end
    return HTTP.Response(404, "")
end
const _PORT = HTTP.Servers.port(_SERVER)

# `const DSPY_URL`(policy.jl:19)은 include 시점에 한 번만 ENV 를 읽는다. 그 순간에만 우리
# 포트로 돌려놓고 곧바로 되돌린다(같은 프로세스의 다른 게이트가 물들지 않도록).
# 🔴 `_SERVER` 를 연 뒤 밖으로 나가는 **모든 길**에 `close(_SERVER)` 가 있어야 한다 —
#    아래 셋이 그 전부다: (i) 이 include, (ii) TENV 구축, (iii) 테스트 블록.
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

const TENV = try
    CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr",
                       project_name = "tool_lane_keys_survive",
                       num_robots = 4, assignment_mode = :greedy,
                       n_spare_per_pool = 2,
                       open_animation_at_end = false, save_animation = false,
                       write_results = false, return_env_before_sim = true,
                       rng = Random.MersenneTwister(1))
catch
    close(_SERVER)   # (ii)
    rethrow()
end

_truth() = CB.BatteryTruth(CB.RobotID(1), 0.5)

try
    @testset "tool 레인 키 8개가 decide_all 까지 살아온다" begin

    @testset "(0) 전제 — 이 게이트가 실제로 서비스를 부르는 설정인가" begin
        # `policy.jl` 의 삼항식은 세 조건이 **모두** 참이면 `service_decide` 를 통째로
        # 건너뛴다. 그 설정에서 이 파일을 돌리면 아래 전부가 "레인이 안 왔다"는 하류 증상으로
        # 빨개지므로, 원인을 여기서 직접 이름 붙인다(skip 조건을 그대로 부정한 형태).
        @test !(POLICY in ("canonical", "noop", "oracle") && !router_drives() &&
                get(ENV, "DEMO_ALL_POLICIES", "1") == "0")
        # 여덟이라는 사실도 여기서 못박는다 — 목록이 조용히 줄면 나머지 검사가 그만큼 덜 잰다.
        @test length(TOOL_LANE_KEYS) == 8
        @test Set(TOOL_LANE_KEYS) == Set(keys(_LANE_FULL))
    end

    @testset "(1)+(2) dspy 가 집행되면 8키가 값까지 그대로 오고, null 은 null 로 온다" begin
        _MODE[] = :lane
        local d = decide_all(TENV, _truth(); nl = "")
        # 전제: 실제로 dspy 가 집행됐는가. 아니면 이 블록은 (3) 을 다시 재는 것이 되어
        # 아무것도 안 잰다.
        @test d.enacted == "dspy"
        @test hasproperty(d, :tool_lane)
        local tl = d.tool_lane
        # ---- (1) 여덟이 전부 있고 값이 그대로다 ------------------------------------------
        for k in TOOL_LANE_KEYS
            @test haskey(tl, k)
        end
        @test tl["tool_called"] == "deliver_battery"
        @test tl["tool_calls_n"] == 1
        @test tl["tools_offered"] == 3
        @test tl["expressible"] === true
        @test tl["native_fc"] === true
        # `tool_args` 는 dict 다. 경계에서 `Dict{String,Any}` 로 고정된다(JSON3.Object 가 아니라).
        @test tl["tool_args"] isa Dict{String,Any}
        @test tl["tool_args"] == Dict{String,Any}("agent" => "robot-1")
        # ---- (2) 🔴 삼상 보존: null 이 `nothing` 으로 온다. `false` 도 `""` 도 아니다 ------
        @test tl["macro_tool_agree"] === nothing
        @test tl["macro_tool_agree"] !== false
        @test tl["tool_lane_error"] === nothing
        @test tl["tool_lane_error"] != ""
        # 결정 자체는 지워지지 않았다(spec §4-1) — 레인 키가 실렸다고 chosen 이 상하지 않는다.
        @test d.macro_name == "SwapBattery"
    end

    @testset "(3) enacted 가 dspy 가 아니면 8키가 전부 nothing 이다" begin
        _MODE[] = :surro
        local d = decide_all(TENV, _truth(); nl = "")
        # 전제 둘. 이 둘이 없으면 아래 어서션은 항진적이다.
        #   ① 실제로 다른 레인이 집행됐는가
        @test d.enacted == "surrogate"
        #   ② 🔴 그 실행에서 `pol["dspy"]` 는 값을 **들고 있는가**. 안 들고 있으면
        #      `pol[enacted]` 와 `pol["dspy"]` 가 같은 값을 내므로 이 검사가 하중을 잃는다.
        @test d.policies["dspy"]["tool_called"] == "deliver_battery"
        @test d.policies["dspy"]["macro_tool_agree"] === true
        for k in TOOL_LANE_KEYS
            @test haskey(d.tool_lane, k)
            @test d.tool_lane[k] === nothing
        end
    end

    @testset "(4) 폴백 분기에서도 8키가 존재하고 전부 nothing 이다" begin
        _MODE[] = :err
        local d = decide_all(TENV, _truth(); nl = "")
        local e = d.policies["dspy"]
        # 전제: 정말 폴백 분기로 떨어졌는가.
        @test e["available"] === false
        @test e["error"] == "service blew up"
        # 🔴 키가 **사라지지 않는다** — 소비자는 `available` 로 "레인이 안 돌았다"를 가른다.
        for k in TOOL_LANE_KEYS
            @test haskey(e, k)
            @test e[k] === nothing
        end
        # 그 사건에서 집행된 레인(canonical)의 노출도 같은 모양이다.
        @test d.enacted == "canonical"
        for k in TOOL_LANE_KEYS
            @test haskey(d.tool_lane, k)
            @test d.tool_lane[k] === nothing
        end
    end

    end # testset
finally
    close(_SERVER)
end

end # module
