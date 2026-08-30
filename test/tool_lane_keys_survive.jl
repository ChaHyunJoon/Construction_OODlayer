# =============================================================================
# tool 레인 키 **열하나**가 서비스 응답 → `policy_entry` → `decide_all(...).tool_lane` 까지
# **살아서** 도착하는지 못박는다. (2026-08-29, Plan B / T1 · T-C · 단일 채널 T6)
#
# 🔴 T-C(2026-08-29)가 여덟에 **둘을 더했다**: `tool_choice`(이 요청의 첫 시도에 실제로 실린
# 레짐 표식)와 `text_rescue`(강제가 텍스트 채널을 비웠고 그것을 두 번째 호출로 되찾았는가).
# 🔴 같은 날 **T6(단일 채널)이 `text_rescue` 를 빼고 둘을 더했다**: `decision_source`
# (`"tool"`|`"no_tools"`|`"no_call"`)와 `tool_arg_error`(인자 접지 실패 사유). `text_rescue`
# 가 사라진 이유는 **되찾을 텍스트 채널이 없기 때문**이다 — T3 이 텍스트 `OutputField` 다섯을
# 전부 지웠고 결정 성분은 이제 tool 인자로만 온다. 개수를 이 파일이 손으로 들고 있는 자리는
# (0)절 한 곳뿐이고, 나머지는 전부 `TOOL_LANE_KEYS` 를 돈다.
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
#  (5) 🔴 **null 이 될 수 있는 키는 전부 실제로 null 로 고정된다** (2026-08-29 수정 라운드, F3).
#      라운드 1 의 픽스처는 여덟 중 **둘**(`macro_tool_agree` · `tool_lane_error`)만 null 로
#      보냈다. 그래서 `expressible` 에 `something(x, false)` 를 씌워도 79개 어서션이 **전부
#      초록**이었다 — 삼상 계약이 그 키에서만 조용히 죽는다. 서비스가 실제로 `null` 을 낼 수
#      있는 키는 **여섯**(`tool_called` · `expressible` · `tool_lane_error` ·
#      `macro_tool_agree` · `tool_choice` · `native_fc`)이고, `:decline` 시나리오가 그
#      여섯을 **동시에** null 로 보낸다.
#      🔴 `tool_choice === nothing` = **강제를 안 했다**(옛 레짐, 또는 T5 의 `no_tools` 조기
#      반환처럼 요청 자체를 안 낸 사건).
#      🔴 **`native_fc` 가 이 목록에 들어왔다 (2026-08-29 / T5·T6).** 여기 있던
#      *"`native_fc` 는 그 넷에 없다 … 어떤 서비스 응답도 `native_fc: null` 을 못 만든다"* 는
#      **이제 거짓이다**: T5 의 `no_tools` 조기 반환은 LM 을 **아예 안 부르고** 돌아오므로
#      `_blank_decision` 이 `native_fc: None` 을 낸다. 그 `nothing` 은 "못 쟀다" 이지
#      `false`("물었는데 안 켜졌다")가 아니다 — 접으면 두 사건이 섞인다.
#      (옛 근거 자체는 여전히 참이다: `native_fc_active()` 는 언제나 `True`/`False` 를 낸다.
#       바뀐 것은 그 함수를 **부르지 않고** 반환하는 경로가 생겼다는 것이다.)
#      ⚠️ `text_rescue` 는 T6 이 지웠다 — 그 삼상 계약을 이 파일이 재던 자리는 이제
#      `decision_source` 가 진다(그쪽은 null 이 아니라 **세 문자열**이라 다른 종류의 계약이다).
#  (6) 🔴 **교차언어 결속**: Julia 의 `TOOL_LANE_KEYS` 가 파이썬 `dspy_service.py` 의
#      `out["dspy"]` 리터럴에서 실제로 유도된 키 집합과 **같다**. 라운드 1 에서 Julia 의
#      목록은 파이썬 이름의 **손으로 쓴 사본**이었고 둘을 잇는 것이 아무것도 없었다 —
#      파이썬에서 키 이름을 바꾸면 값이 여기서 조용히 `nothing`("못 쟀다")으로 도착하고
#      **양쪽 게이트가 전부 초록**이었다. `tools/test_policy_oracle.jl` 0절이
#      (`ORACLE_BATTERY_DEEP_SOC` ↔ `reference_policy.BATTERY_DEEP_SOC`) 같은 자리에 이미
#      가진 계약과 같은 모양이다.
#      🔴 파이썬에 못 닿으면 **skip 이 아니라 빨개진다.** skip 은 같은 구멍에 단계만 더한 것이다.
#      🔴 서비스를 **import 하지 않는다** — `ast` 로 소스만 읽는다(부팅도 과금도 없다).
#         모든 호출은 `env -u OPENAI_API_KEY` 로 감싼다.
#  (7) 삼분 규칙: `tool_lane` 은 여덟 옆에 `"lane"` · `"lane_available"` 을 같이 낸다
#      (`tool_lane_view` docstring 에 규칙 한 벌). (a) 레인이 dspy 가 아니었다 /
#      (b) dspy 인데 항목이 폴백이었다 / (c) 서비스가 진짜 null 을 냈다 — 셋이 갈린다.
#
# ℹ️ 이 파일의 `haskey` 어서션들은 **구조적으로 실패할 수 없다**(같은 dict comprehension 이
#    여덟을 언제나 짓는다). 남겨 두지만 **존재는 증거가 아니다** — 하중은 전부 바로 아래
#    붙어 있는 값 어서션이 진다. 키가 사라지는 회귀는 `(0)` 의 길이/집합 검사와 (6) 의
#    교차언어 대조가 잡는다.
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
#   :decline   dspy 가용인데 **결정이 안 왔다** — null 가능한 **여섯**이 전부 null
#              (T6 이후 이 픽스처는 T5 의 `no_tools` 조기 반환 모양이다: `decision_source`
#               가 그 사건에 이름을 붙이고 `native_fc` 는 "못 쟀다" 로 온다)
const _MODE = Ref{Symbol}(:lane)

# 🔴 2026-08-29 (T11): 라우팅 손잡이. 위 `/health` 가 이 값을 그대로 낸다.
const _KINDS = Ref{Vector{String}}(["battery", "fault"])

"""
    _route_kinds!(ks)

`/health` 가 낼 kind 집합을 바꾸고 **캐시를 무효화한다.** `dspy_ready()` 는 한 번만 묻고
`DSPY_HEALTHY[]`·`SURRO_KINDS[]` 에 캐시하므로, 이 두 줄이 없으면 첫 testset 의 값이 파일
전체를 지배한다(에러 없이 — 그래서 위험하다).
"""
function _route_kinds!(ks)
    _KINDS[] = collect(String, ks)
    DSPY_HEALTHY[] = nothing
    SURRO_KINDS[] = nothing
    return ks
end

# 응답에 싣는 tool 레인 값.
# 🔴 (2026-08-29 수정 라운드, F7) 이 주석은 **거짓이었다** — (1) 절이 `"deliver_battery"` 같은
#    인라인 리터럴로 대조했고, 그래서 이 상수와 검사가 실제로는 두 벌이었다. 지금은 (1)·(5)
#    둘 다 `TOOL_LANE_KEYS` 를 돌며 **이 dict 에서 기대값을 읽는다**. 서버가 보내는 것과
#    검사가 기대하는 것이 같은 리터럴 하나라, 갈릴 자리가 없다.
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
    "macro_tool_agree" => true,
    # T-C: 강제 판이다.
    "tool_choice" => "required",
    # T6(단일 채널): 정상 행 = tool 호출이 왔고 인자 접지가 성공했다.
    "decision_source" => "tool",
    "tool_arg_error" => nothing)

# (2) 를 위해 **삼상의 왼쪽 끝**을 실제로 보낸다: 두 키를 `null` 로. `nothing` 은 JSON3.write
# 가 `null` 로 직렬화한다.
const _LANE_WITH_NULLS = merge(_LANE_FULL, Dict{String,Any}(
    "macro_tool_agree" => nothing, "tool_lane_error" => nothing))

# (5) 를 위한 **거절 행**(dspy_service.py 의 C8 ②: 메뉴는 있었는데 모델이 tool 을 안 불렀다).
# 🔴 서비스가 실제로 `null` 을 낼 수 있는 **넷을 전부** 동시에 null 로 보낸다:
#    `tool_called`(안 불렀다) · `expressible`(bool 로 안 읽혔다) · `tool_lane_error`(실패 없음)
#    · `macro_tool_agree`(비교할 오른쪽이 없다). 위 `_LANE_WITH_NULLS` 는 뒤의 둘만 덮어서
#    앞의 둘이 한 번도 null 로 안 왔다 — 그게 F3 이 잡은 구멍이다.
# ⚠️ `tool_args` 는 여기서도 **`nothing` 이 아니라 `{}`** 다. 서비스의 `_first_tool_call` 이
#    호출이 없으면 빈 dict 를 내기 때문이다(F5). 즉 이 층에서 "안 불렀다" 를 가르는 키는
#    `tool_called` **하나뿐**이고, `tool_args` 의 빈 여부가 아니다 — 아래 (5) 가 그것을 못박는다.
# ⚠️ `native_fc` 는 `false`(재서 꺼져 있었다). `nothing` 은 **서비스가 만들 수 없는 상태**라
#    지어내지 않는다 — 머리말 (5) 참조. 이 시나리오가 그 키의 두 번째(그리고 마지막) 실상태다.
const _LANE_DECLINED = Dict{String,Any}(
    "tool_called" => nothing,
    "tool_args" => Dict{String,Any}(),
    "tool_calls_n" => 0,
    "tools_offered" => 3,
    "expressible" => nothing,
    # 🔴 T6: `nothing` 이다(옛 픽스처는 `false` 였다). 이 행은 **T5 의 `no_tools` 조기 반환**
    #    모양으로 다시 맞춰졌다 — LM 을 아예 안 불렀으므로 `native_fc` 를 **못 쟀다**.
    #    `false`("물었는데 native FC 가 안 켜졌다")와 다른 사건이고, 그 구별이 이 파일이
    #    지키는 삼상 계약의 여섯 번째 자리다.
    "native_fc" => nothing,
    "tool_lane_error" => nothing,
    "macro_tool_agree" => nothing,
    # 🔴 T-C: 거절 행은 **강제하지 않은 판**에서만 나온다(강제 판에서 C8 ② 는 원리상 관측되지
    #    않는다 — `dspy_service.py` 의 소비자 규칙 ⑤). 그래서 이것도 `nothing` 이다.
    "tool_choice" => nothing,
    # 🔴 T6: 이 행의 **이름**. `no_tools` 는 우리가 메뉴를 못 만든 것이고 `no_call` 은
    #    프로바이더가 `required` 계약을 어긴 것이다 — 접지 않는다. `tool_arg_error` 는
    #    `nothing` 인데, 그것은 "접지에 성공했다" 가 아니라 **"접지할 호출이 없었다"** 이다
    #    (§0-B ⑤ 와 같은 함정: `nothing` 을 성공 분자에 넣지 말 것).
    "decision_source" => "no_tools",
    "tool_arg_error" => nothing)

# 🔴 매크로 이름 리터럴을 쓰지 않는다 (2026-08-29 수정 라운드, F6). 이 레포의 규칙은
#    `test/policy_macro_binding.jl:134` 에 적혀 있다 — 어휘 이름을 테스트에 적으면 그 파일이
#    **어휘의 또 다른 사본**이 되고, 레지스트리에서 이름을 바꾸면 여기가 죽은 이름을 계속
#    단언한다. 아래 둘은 `wm4spacecraft_manufacturing/core/action_registry.json` 에서
#    유도된다(`_ARM_NAME`/`_NOOP_NAME`, policy.jl include 뒤에 정의). 두 함수 모두 **호출
#    시점에** 그 전역을 읽으므로 정의 순서는 문제되지 않는다.
_dspy_body(lane) = merge(Dict{String,Any}(
    "chosen" => _ARM_NAME, "ranking" => [_ARM_NAME, _NOOP_NAME], "margin" => 0.4,
    "rationale" => "fake service", "policy" => "dspy:test", "unsupported" => String[]), lane)

_surro_body() = Dict{String,Any}(
    "chosen" => _NOOP_NAME, "ranking" => [_NOOP_NAME, _ARM_NAME], "margin" => 0.2,
    "rationale" => "fake surrogate", "policy" => "surrogate:test",
    "scores" => Dict(_NOOP_NAME => 0.7, _ARM_NAME => 0.3), "unsupported" => String[])

const _SERVER = HTTP.serve!(HTTP.Sockets.localhost, 0; listenany = true, verbose = -1) do req
    if req.target == "/health"
        # `dspy_ready()` 가 찌르는 자리. 200 을 안 주면 `service_decide` 가 곧장 nothing 을
        # 돌려주고 아래 검사들이 "레인이 안 왔다"로 **빨개진다**(조용히 안 샌다).
        # 🔴 2026-08-29 (T11): `surro_kinds` 를 **반드시** 싣는다. 없으면 `dspy_ready()` 가
        #    "못 쟀다"(nothing)로 캐시하고 kind 색인 라우터가 그 사건에서 **죽는다** —
        #    그것이 §0-C 결정 3 의 설계된 동작이다(실측: 이 픽스처를 안 고치면 (1)~(5)가
        #    "surrogate kind support is unknown" 으로 정당하게 빨개졌다).
        # 🔴 2026-08-29 (T11): 어느 레인이 집행되는가는 이제 **kind 축**이 정한다. 그래서
        #    이 값이 곧 시나리오 손잡이다: `["battery","fault"]` → battery 사건은 surrogate,
        #    `String[]` → 아는 kind 가 없으므로 battery 사건도 dspy. `_MODE[]` 는 서비스가
        #    무엇을 **돌려주는가**만 정하고, 누가 **불리는가**는 여기가 정한다.
        #    ⚠️ `dspy_ready()` 가 첫 호출만 캐시하므로 시험이 `DSPY_HEALTHY[]`/`SURRO_KINDS[]`
        #    를 직접 되돌려야 한다 — `_route_kinds!` 가 그것을 한다.
        return HTTP.Response(200, JSON3.write(Dict("status" => "ok",
                                                   "surro_kinds" => _KINDS[])))
    elseif req.target == "/decide"
        local m = _MODE[]
        local out = if m === :lane
            Dict{String,Any}("dspy" => _dspy_body(_LANE_WITH_NULLS), "surrogate" => nothing)
        elseif m === :surro
            Dict{String,Any}("dspy" => _dspy_body(_LANE_FULL), "surrogate" => _surro_body())
        elseif m === :decline
            # 성공 분기다(`error` 없음) — 그래서 여기의 `nothing` 들은 전부 **서비스가 보낸
            # null** 이지 "레인이 안 돌았다" 가 아니다. 삼분의 (c).
            Dict{String,Any}("dspy" => _dspy_body(_LANE_DECLINED), "surrogate" => nothing)
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

# ---- 어휘는 레지스트리에서 유도한다 (F6) --------------------------------------------------
# `ActionRegistry` 는 policy.jl 의 가드 있는 include 로 같이 들어온다(두 번째 로더 경로를
# 만들지 않는다 — `test/policy_macro_binding.jl:39-45` 와 같은 이유).
# id 0 = 절제(NOOP)라는 것은 이 레지스트리의 규약이고 `policy.jl:359-360` ·
# `action_registry.jl:battery_arms` 가 이미 그 규약으로 `vcat(0, kind_valid(...))` 를 쓴다.
# **이름**은 어디에도 안 적는다 — 레지스트리에서 이름을 바꾸면 이 파일이 따라간다.
const _NOOP_NAME = ActionRegistry.NAME[0]
const _ARM_NAME  = first(a for a in
                         (ActionRegistry.NAME[i] for i in ActionRegistry.kind_valid(:battery))
                         if a != _NOOP_NAME)

# ---- (6) 교차언어: 파이썬 서비스의 키를 **소스에서** 뽑는다 ---------------------------------
# 🔴 서비스를 **import 하지 않는다.** `ast` 로 `out["dspy"] = {...}` 리터럴만 읽는다 —
#    import 하면 FastAPI 앱과 dspy 설정이 딸려 오고, 그건 이 게이트가 지불하지 않기로 한 값이다.
# 🔴 `env -u OPENAI_API_KEY` 로 감싼다(과금 경로에 손이 닿을 여지 자체를 없앤다).
# 레인 키의 경계는 파이썬 소스가 **스스로 선언한다**: `out["dspy"]` dict 안의
# `# ---- tool 레인 ...` 표식 아래 줄에 있는 키가 레인 키다. 표식이 없거나 둘이면 죽는다.
# ⚠️ 알려진 한계: 표식 **위**에 레인 키를 끼워 넣으면 이 추출이 그것을 레인 키로 안 센다.
#    그 대신 아무것도 안 잡는 게 아니라, `all` 대조(아래)가 여전히 Julia 목록의 소멸·개명을 잡는다.
const _PY_EXTRACT = raw"""
import ast, json, re, sys
src = open(sys.argv[1], encoding="utf-8").read()
lines = src.split("\n")
lits = [n.value for n in ast.walk(ast.parse(src))
        if isinstance(n, ast.Assign) and len(n.targets) == 1
        and isinstance(n.targets[0], ast.Subscript)
        and isinstance(n.targets[0].value, ast.Name) and n.targets[0].value.id == "out"
        and isinstance(n.targets[0].slice, ast.Constant) and n.targets[0].slice.value == "dspy"
        and isinstance(n.value, ast.Dict)]
if len(lits) != 1:
    sys.exit('expected exactly 1 out[dspy] dict literal, found %d' % len(lits))
d = lits[0]
keys = []
for k in d.keys:
    if not (isinstance(k, ast.Constant) and isinstance(k.value, str)):
        sys.exit("non-literal key in out['dspy'] at line %s" % getattr(k, "lineno", "?"))
    keys.append((k.value, k.lineno))
marks = [i + 1 for i in range(d.lineno - 1, d.end_lineno)
         if re.match(r"^\s*#\s*-{2,}\s*tool ", lines[i])]
if len(marks) != 1:
    sys.exit("expected exactly 1 `# ---- tool ...` marker inside out['dspy'], found %d" % len(marks))
print(json.dumps({"all": [k for k, _ in keys],
                  "lane": [k for k, ln in keys if ln > marks[0]],
                  "marker": marks[0]}, ensure_ascii=False))
"""

const _PY_BIN = joinpath(REPO, ".venv", "bin", "python")
# 🔴 기본값은 **생산 소스**다. ENV 손잡이는 이 게이트가 실제로 빨개지는지 보이기 위한
#    변형 증명 전용이고(수정 보고서가 그 실행을 인용한다), CI 는 이것을 세팅하지 않는다.
const _PY_SERVICE_SRC = get(ENV, "TOOL_LANE_PY_SRC",
                            joinpath(REPO, "src", "respec", "llm_service", "dspy_service.py"))

"""
    _py_decide_keys(pysrc) -> (all, lane)

`dspy_service.py` 의 `out["dspy"]` dict 리터럴에서 키 이름을 뽑는다.

🔴 **못 하면 예외로 죽는다 — skip 하지 않는다.** 파이썬에 못 닿는다는 이유로 이 검사를
건너뛰면 F1 이 지적한 구멍(두 언어의 목록이 조용히 갈린다)이 "단계만 하나 더한 채" 그대로
남는다. 그래서 인터프리터 부재도, 소스 부재도, 추출 실패도 전부 빨간색이다.
"""
function _py_decide_keys(pysrc::AbstractString)
    isfile(_PY_BIN) || error("교차언어 게이트: 파이썬이 없다 — $(_PY_BIN) (skip 하지 않는다)")
    isfile(pysrc) || error("교차언어 게이트: 서비스 소스가 없다 — $(pysrc)")
    local o = IOBuffer(); local e = IOBuffer()
    local pr = run(pipeline(ignorestatus(
        `env -u OPENAI_API_KEY $(_PY_BIN) -c $(_PY_EXTRACT) $(pysrc)`); stdout = o, stderr = e))
    local out = String(take!(o)); local errs = String(take!(e))
    pr.exitcode == 0 || error("교차언어 게이트: 키 추출 실패 (rc=$(pr.exitcode))\n$(errs)")
    local j = JSON3.read(out)
    return (Set(String.(j["all"])), Set(String.(j["lane"])), Int(j["marker"]))
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

"""
    _assert_lane_values(tl, want)

`tl`(= `decide_all(...).tool_lane`)의 여덟 키를 **서버가 실제로 보낸 픽스처 dict** `want` 와
대조한다. F7: 인라인 리터럴을 쓰면 픽스처와 검사가 두 벌이 되어 갈릴 수 있다 — 여기서는
갈릴 자리가 없다.

🔴 타입까지 본다. `nothing` 은 `===` 로(그래야 `false`·`""` 로 접힌 것이 빨개진다), `Bool` 도
`===` 로(그래야 `1`/`"true"` 가 안 통과한다).
"""
function _assert_lane_values(tl, want)
    for k in TOOL_LANE_KEYS
        local w = want[k]
        if w === nothing
            @test tl[k] === nothing
        elseif w isa Bool
            @test tl[k] === w
        elseif w isa Integer
            @test tl[k] === w
        else
            @test tl[k] == w
        end
    end
end

try
    @testset "tool 레인 키 열 개가 decide_all 까지 살아온다" begin

    @testset "(0) 전제 — 이 게이트가 실제로 서비스를 부르는 설정인가" begin
        # `policy.jl` 의 삼항식은 세 조건이 **모두** 참이면 `service_decide` 를 통째로
        # 건너뛴다. 그 설정에서 이 파일을 돌리면 아래 전부가 "레인이 안 왔다"는 하류 증상으로
        # 빨개지므로, 원인을 여기서 직접 이름 붙인다(skip 조건을 그대로 부정한 형태).
        @test !(POLICY in ("canonical", "noop", "oracle") && !router_drives() &&
                get(ENV, "DEMO_ALL_POLICIES", "1") == "0")
        # 개수도 여기서 못박는다 — 목록이 조용히 줄면 나머지 검사가 그만큼 덜 잰다.
        # 여덟(T1) → 열(T-C) → **열하나**(T6: `text_rescue` 빼고 `decision_source` ·
        # `tool_arg_error` 더함).
        @test length(TOOL_LANE_KEYS) == 11
        @test !("text_rescue" in TOOL_LANE_KEYS)
        @test Set(TOOL_LANE_KEYS) == Set(keys(_LANE_FULL))
        @test Set(TOOL_LANE_KEYS) == Set(keys(_LANE_DECLINED))
        # 픽스처의 매크로 이름이 **정말 레지스트리에서 왔는가**(F6). 둘이 같으면 아래
        # `enacted` 판정이 두 레인을 구별 못 해 (3) 이 하중을 잃는다.
        local _reg = [ActionRegistry.NAME[i] for i in ActionRegistry.active_ids()]
        @test _NOOP_NAME != _ARM_NAME
        @test _NOOP_NAME in _reg
        @test _ARM_NAME in _reg
    end

    @testset "(1)+(2) dspy 가 집행되면 8키가 값까지 그대로 오고, null 은 null 로 온다" begin
        _MODE[] = :lane
        # 🔴 2026-08-29 (T11): dspy 가 집행되게 하는 것은 이제 **kind 축**이다. 아는 kind 가
        #    비면 battery 사건도 `ood_kind` 로 판정돼 LLM 으로 간다. (예전에는 `_MODE[]` 가
        #    양쪽 레인을 다 내고 novelty 가 골랐다 — 그 축은 사라졌다.)
        _route_kinds!(String[])
        local d = decide_all(TENV, _truth(); nl = "")
        # 전제: 실제로 dspy 가 집행됐는가. 아니면 이 블록은 (3) 을 다시 재는 것이 되어
        # 아무것도 안 잰다.
        @test d.enacted == "dspy"
        @test hasproperty(d, :tool_lane)
        local tl = d.tool_lane
        # ---- (1) 여덟이 전부 있고 값이 그대로다 ------------------------------------------
        # ℹ️ `haskey` 는 **구조적으로 실패할 수 없다**(같은 comprehension 이 여덟을 언제나 짓는다) —
        #    존재는 증거가 아니다. 하중은 바로 아래 값 대조가 진다.
        for k in TOOL_LANE_KEYS
            @test haskey(tl, k)
        end
        # 🔴 F7: 기대값을 **서버가 실제로 보낸 dict 에서 읽는다.** 인라인 리터럴을 쓰면
        #    `_LANE_*` 상수와 검사가 두 벌이 되고, 위 주석이 다시 거짓이 된다.
        _assert_lane_values(tl, _LANE_WITH_NULLS)
        # `tool_args` 는 dict 다. 경계에서 `Dict{String,Any}` 로 고정된다(JSON3.Object 가 아니라).
        @test tl["tool_args"] isa Dict{String,Any}
        # ---- (2) 🔴 삼상 보존: null 이 `nothing` 으로 온다. `false` 도 `""` 도 아니다 ------
        @test tl["macro_tool_agree"] !== false
        @test tl["tool_lane_error"] != ""
        # ---- (7) 출처 두 키: 이 사건은 삼분의 (c) 다 ---------------------------------------
        @test tl["lane"] == "dspy"
        @test tl["lane"] == d.enacted
        @test tl["lane_available"] === true
        # 결정 자체는 지워지지 않았다(spec §4-1) — 레인 키가 실렸다고 chosen 이 상하지 않는다.
        @test d.macro_name == _ARM_NAME
    end

    @testset "(3) enacted 가 dspy 가 아니면 8키가 전부 nothing 이다" begin
        _MODE[] = :surro
        # battery ∈ 아는 kind ⟹ surrogate. 이것이 이 절의 라우팅 전제다.
        _route_kinds!(["battery", "fault"])
        local d = decide_all(TENV, _truth(); nl = "")
        #   ① 실제로 다른 레인이 집행됐는가
        @test d.enacted == "surrogate"
        #   ② 🔴 **옛 전제는 소멸했다** (2026-08-29, T11). 여기 있던 두 줄은
        #        `@test d.policies["dspy"]["tool_called"] == _LANE_FULL["tool_called"]`
        #        `@test d.policies["dspy"]["macro_tool_agree"] === true`
        #      즉 *"surrogate 가 집행된 사건에서도 `pol["dspy"]` 가 값을 들고 있다"* 였다.
        #      라우터가 사건당 레인 **하나만** 청구하므로 그 상태를 이제 **만들 수 없다** —
        #      주석 처리하거나 `@test_skip` 으로 남기지 않고 지운다(이 레포의 규칙).
        #      🔴 대신 그 자리를 새 계약이 받는다: **키 자체가 없다.** 그리고 그것이 곧
        #      비용 절감의 증거다(안 부른 레인 = 안 낸 LM 호출, §0-C 충돌 ⑦).
        @test !haskey(d.policies, "dspy")
        # ⚠️ 하중 보존. 옛 전제 ②가 막던 것은 "`pol[enacted]` 와 `pol["dspy"]` 가 같은 값을
        #    내서 검사가 항진적이 되는 것" 이었다. 이제는 그 자리를 이렇게 잰다:
        #    surrogate 항목은 `policy_entry` 규약대로 레인 키를 **들고는 있되**(두 분기 모두
        #    나른다) 서비스가 그 키를 안 보냈으므로 값이 전부 `nothing` 이다.
        #    🔴 실측 정정(2026-08-29): 여기 `!haskey(..., "tool_called")` 를 적었다가 빨갰다 —
        #    `policy_entry` 는 레인과 무관하게 열한 키를 언제나 짓는다. 존재가 아니라 **값**이
        #    이 절의 하중이다.
        @test haskey(d.policies["surrogate"], "tool_called")
        @test d.policies["surrogate"]["tool_called"] === nothing
        @test d.policies["surrogate"]["macro_tool_agree"] === nothing
        for k in TOOL_LANE_KEYS
            @test haskey(d.tool_lane, k)   # ℹ️ 존재는 증거가 아니다 — 다음 줄이 하중을 진다
            @test d.tool_lane[k] === nothing
        end
        # ---- (7) 삼분의 (a): "레인이 dspy 가 아니었다" 가 `tool_lane` 만으로 읽힌다 --------
        # 🔴 여기가 `"lane"` 의 하중점이다. `tool_lane_view` 가 레인 이름을 `pol[enacted]` 가
        #    아닌 곳(예: 리터럴 "dspy")에서 가져오면 이 줄이 빨개진다.
        @test d.tool_lane["lane"] == "surrogate"
        @test d.tool_lane["lane"] == d.enacted
        @test d.tool_lane["lane"] != "dspy"
        @test d.tool_lane["lane_available"] === true
    end

    # 🔴 2026-08-29 (T11): 옛 (4)절 *"폴백 분기에서도 8키가 존재하고 전부 nothing 이다"* 는
    #    **명제가 뒤집혔다.** 그 절은 dspy 가 실패하면 `enacted` 가 조용히 `"canonical"` 로
    #    떨어지는 것을 전제했는데, §0-C 사용자 결정 3 이 그 조용한 폴백을 없앴다 —
    #    고른 레인이 그 사건에서 실패하면 `decide_all` 이 `error()` 로 **죽는다**.
    #    ⟹ 그 절이 재던 상태(`d.enacted == "canonical"` 인 행)를 **이제 만들 수 없다.**
    #    지우고, 같은 픽스처(`:err`)로 새 계약을 잰다. 8키가 폴백 dict 에 살아 있다는 명제
    #    자체는 `policy_entry` 축으로 (7)절이 계속 잰다.
    @testset "(4) 고른 레인이 실패하면 조용히 폴백하지 않고 죽는다 (§0-C 결정 3)" begin
        _MODE[] = :err
        _route_kinds!(String[])                     # battery → ood_kind → dspy 를 고른다
        # 🔴 조용한 canonical 폴백이 돌아오면 이 줄이 빨개진다. 그게 이 절의 전부다 —
        #    산출물이 "라우팅했다" 고 주장하면서 규칙표가 돈 행을 섞어 담는 상태를 막는다.
        @test_throws ErrorException decide_all(TENV, _truth(); nl = "")
        # 사유가 산문에 남는가. 삼킨 뒤 일반 메시지를 내면 진단이 사라진다.
        local msg = try
            decide_all(TENV, _truth(); nl = ""); ""
        catch e
            sprint(showerror, e)
        end
        @test occursin("[router]", msg)
        @test occursin("dspy", msg)
        @test occursin("service blew up", msg)      # 서비스가 낸 사유가 그대로 실린다
    end

    @testset "(5) null 가능한 키 여섯이 전부 null 로 살아온다 (결정 없음 행)" begin
        # 🔴 F3. 라운드 1 픽스처는 여덟 중 **둘**만 null 로 보냈다. `expressible` 과
        #    `tool_called` 은 어느 시나리오에서도 null 이 아니어서, 그 둘에 `something(x, false)`
        #    를 씌워도 79개가 전부 초록이었다. 이 절이 그 구멍을 막는다.
        _MODE[] = :decline
        _route_kinds!(String[])                     # battery → ood_kind → dspy
        local d = decide_all(TENV, _truth(); nl = "")
        # 전제: 이 응답은 **성공 분기**다. 그래야 아래 `nothing` 들이 "서비스가 보낸 null"
        # 이라는 뜻이 된다(폴백이면 (4) 를 다시 재는 것이 되어 아무것도 안 잰다).
        @test d.enacted == "dspy"
        @test d.policies["dspy"]["available"] === true
        local tl = d.tool_lane
        _assert_lane_values(tl, _LANE_DECLINED)
        # ---- null 가능한 넷을 **이름으로** 다시 못박는다 ------------------------------------
        # 🔴 `=== nothing` 이지 `""`·`false` 가 아니다. Julia 쪽에서 접으면 여기서 빨개진다.
        @test tl["tool_called"] === nothing
        @test tl["tool_called"] != ""
        @test tl["expressible"] === nothing
        @test tl["expressible"] !== false
        @test tl["tool_lane_error"] === nothing
        @test tl["macro_tool_agree"] === nothing
        # ---- T-C·T6 가 더한 것들도 **이름으로** 못박는다 ------------------------------------
        # 🔴 `nothing` 이지 `""`·`false` 가 아니다.
        @test tl["tool_choice"] === nothing
        @test tl["tool_choice"] != ""
        # 🔴 T6: `decision_source` 는 null 이 **아니다** — 결정을 못 낸 사건에도 **이름이
        #    붙는 것**이 이 키의 존재 이유다. `nothing` 으로 오면 그 사건이 다시 무명이 된다.
        @test tl["decision_source"] === "no_tools"
        @test tl["decision_source"] !== nothing
        # 🔴 그리고 `tool_arg_error === nothing` 을 "접지 성공" 으로 읽지 말 것 — 이 행은
        #    접지할 호출 자체가 없었다(§0-B ⑤).
        @test tl["tool_arg_error"] === nothing
        # ---- F5: `tool_args` 는 **null 이 아니다** ------------------------------------------
        # 서비스의 `_first_tool_call` 이 호출이 없으면 `{}` 를 낸다. 그러므로 이 층에서
        # "tool 을 안 불렀다" 를 가르는 키는 `tool_called` 하나뿐이고, `tool_args` 의 빈 여부가
        # **아니다**. 아래 두 줄이 그 사실을 못박는다(그리고 `nothing`↔`{}` 접기를 둘 다 막는다).
        @test tl["tool_args"] !== nothing
        @test tl["tool_args"] == Dict{String,Any}()
        @test tl["tool_calls_n"] === 0
        # ---- 🔴 native_fc 는 이제 **3/3 이 실재한다** (2026-08-29 / T5·T6) -------------------
        # 여기 있던 *"`false` 가 마지막 실상태다 — 어떤 서비스 응답도 `native_fc: null` 을 못
        # 만든다"* 는 **거짓이 됐다**: T5 의 `no_tools` 조기 반환이 LM 을 안 부르고 돌아오고
        # `_blank_decision` 이 `native_fc: None` 을 낸다. 이 픽스처가 바로 그 행이다.
        # `true`(_LANE_FULL) · `false` · `nothing` 셋 다 실재하며, 이 절은 `nothing` 을 잰다.
        @test tl["native_fc"] === nothing
        @test tl["native_fc"] !== false
        # 삼분의 (c): 레인은 dspy 이고 항목도 성공이다 → 위 `nothing` 들은 전부 "서비스가 못 쟀다".
        @test tl["lane"] == "dspy"
        @test tl["lane_available"] === true
    end

    @testset "(6) 🔴 교차언어 — Julia 의 키 목록이 파이썬 소스에 묶여 있다" begin
        # `tools/test_policy_oracle.jl` 0절과 같은 계약이다. 못 닿으면 skip 이 아니라 예외로
        # 죽는다(`_py_decide_keys` 가 그렇게 짜여 있다).
        local (all_keys, lane_keys, marker) = _py_decide_keys(_PY_SERVICE_SRC)
        println("    python out[\"dspy\"] lane keys = ", join(sort(collect(lane_keys)), " · "))
        println("    julia  TOOL_LANE_KEYS        = ", join(sort(collect(TOOL_LANE_KEYS)), " · "))
        # 🔴 양방향 등호. `⊆` 만 재면 파이썬에 **키를 더한** 사건을 못 잡는다.
        @test lane_keys == Set(TOOL_LANE_KEYS)
        # Julia 가 읽는 이름이 실제로 응답에 있는가(개명·삭제를 잡는 두 번째 그물).
        @test issubset(Set(TOOL_LANE_KEYS), all_keys)

        # ---- 음성 대조: 이 대조가 정말 하중을 지는가 ----------------------------------------
        # 🔴 위 두 줄은 **언제나 참일 수도** 있다(추출이 Julia 목록을 그대로 베껴 오는 식으로
        #    망가지면). 그래서 파이썬 소스를 실제로 변형해 두 방향 모두 빨개지는지 확인한다.
        # 🔴 변형은 **파이썬 소스의 리터럴을 베끼지 않고** 만든다. 추출기가 돌려준 표식 줄
        #    번호와 Julia 쪽 키 이름만 쓴다 — 파이썬 코드를 한 줄이라도 여기 적으면 그것이
        #    또 하나의 사본이 되고, 그 사본이 낡는 순간 음성 대조가 조용히 죽는다.
        local lines = split(read(_PY_SERVICE_SRC, String), "\n")
        @test 0 < marker <= length(lines)
        mktempdir() do dir
            # ① 표식 **바로 아래**에 키를 하나 더 끼운다 → 파이썬 레인 집합이 커진다.
            local add = joinpath(dir, "dspy_service_add.py")
            write(add, join(vcat(lines[1:marker],
                                 ["                   \"tool_provider\": d[\"policy\"],"],
                                 lines[marker+1:end]), "\n"))
            local (_, lane_add, _) = _py_decide_keys(add)
            @test "tool_provider" in lane_add
            @test lane_add != Set(TOOL_LANE_KEYS)
            # ② 레인 키 하나의 **이름을 바꾼다** → Julia 가 읽는 이름이 응답에서 사라진다.
            #    패턴은 Julia 쪽 목록에서 만든다(파이썬 리터럴이 아니다).
            local kk = "native_fc"
            @test kk in TOOL_LANE_KEYS
            local ren = joinpath(dir, "dspy_service_rename.py")
            write(ren, replace(join(lines, "\n"), "\"$(kk)\":" => "\"$(kk)_renamed\":"))
            local (all_ren, lane_ren, _) = _py_decide_keys(ren)
            @test !(kk in all_ren)
            @test !issubset(Set(TOOL_LANE_KEYS), all_ren)
            @test lane_ren != Set(TOOL_LANE_KEYS)
        end
    end

    @testset "(7) 삼분의 (b) — dspy 인데 항목이 폴백이다" begin
        # (a)·(c) 는 위 (1)(3)(4)(5) 가 **진짜 `decide_all`** 로 잰다. (b) 만 그렇게 못 잰다:
        # `decide_all` 의 가용성 그물(`!pol[enacted]["available"] → canonical`)과
        # `escalation_target` 의 `pol["dspy"]["available"]` 가드 때문에 `enacted == "dspy"` 이면
        # 그 항목은 **언제나 available** 이다. 즉 위 절들에서 `lane_available === true` 는
        # 오늘 상수다 — 그 사실을 숨기지 않고, (b) 는 여기서 직접 잰다.
        # 🔴 손으로 쓴 dict 를 검사하는 것이 아니다: 항목은 **진짜 생산자** `policy_entry` 가,
        #    노출은 **진짜 생산자** `tool_lane_view` 가 짓는다.
        local fb = policy_entry(nothing, "dspy:LLM")
        @test fb["available"] === false
        local v = tool_lane_view(Dict{String,Any}("dspy" => fb), "dspy")
        @test v["lane"] == "dspy"
        @test v["lane_available"] === false
        for k in TOOL_LANE_KEYS
            @test v[k] === nothing
        end
        # 대조군: 같은 함수가 **성공 항목**에서는 `true` 를 낸다 = 위 `false` 가 상수가 아니다.
        # `policy_entry` 는 `b.chosen` 처럼 **속성**으로 읽으므로 NamedTuple 로 준다
        # (그 docstring 이 그렇게 부를 수 있다고 적는다). 키 목록은 픽스처에서 유도한다.
        local ok = policy_entry(merge((chosen = _ARM_NAME, ranking = [_ARM_NAME], margin = 0.4,
                                       rationale = "fake", policy = "dspy:test",
                                       unsupported = String[]),
                                      NamedTuple{Tuple(Symbol.(collect(keys(_LANE_FULL))))}(
                                          Tuple(collect(values(_LANE_FULL))))), "dspy:LLM")
        @test ok["available"] === true
        local vok = tool_lane_view(Dict{String,Any}("dspy" => ok), "dspy")
        @test vok["lane_available"] === true
        @test vok["tool_lane_error"] == _LANE_FULL["tool_lane_error"]
        # 🔴 (b) 의 대가(ruling R1): 서비스가 **실제로 잰** `tool_lane_error` 가 폴백 dict 에서
        #    `nothing` 으로 접힌다. 위 두 항목이 나란히 그것을 보여 준다 — 같은 응답 본체인데
        #    성공 분기는 문자열을 나르고 폴백 분기는 `nothing` 을 낸다. 그러므로 (b) 에서
        #    `tool_lane_error === nothing` 은 "파싱 실패가 없었다"는 뜻이 **아니다**.
        #    (그 사건의 원문이 `policies["dspy"]["error"]` 에만 남는다는 것은 (4) 가 진짜
        #     `decide_all` 로 이미 잰다.)
        @test _LANE_FULL["tool_lane_error"] !== nothing
        @test fb["tool_lane_error"] === nothing
    end

    end # testset
finally
    close(_SERVER)
end

end # module
