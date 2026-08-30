# =============================================================================
# T3 (Plan B) — **tool 호출 접지 판정**의 게이트.
#
# 오늘 이 레인에서 tool 호출을 거르는 자리는 `CB.ground_tool_args` **하나뿐이다**
# (디코드 시점 차단이 없다: `dspy.Tool` 에 `strict` 필드 자체가 없고 `tool_choice` 도 안
# 보낸다. 두 번째 방어선 `grammar_ground_check` 는 `RespecProposal` 을 받아서 tool 레인을
# 못 본다). 그러니 **이 게이트가 약하면 방어선이 없는 것과 같다.**
#
# 🔴 이 파일이 지키는 명제 넷:
#   (a) 판정은 **삼상이고 셋 다 도달 가능하다.** 상태가 셋인데 둘만 닿을 수 있으면 그것은
#       거짓말이 하나 든 이상 상태다 — 그래서 각 값마다 그것을 내는 **실재 입력**을 만든다.
#   (b) 🔴 spec §4-1 — **tool 실패가 결정을 지우지 않는다.** `reject` 는 "tool 레인이
#       실패했다" 이지 "결정이 사라졌다" 가 아니다. 매크로 결정은 그대로 서고 그대로
#       집행된다(`truth.robot` 으로). 그래서 reject 판에서도 `enact_applied === true` 이고
#       세계가 실제로 바뀌는 것을 잰다.
#   (c) 🔴 **이름과 스키마도 잰다** (2026-08-29 검증 항목 7·9·10). 그 전에는 접지 함수가
#       **인자만 보고 이름을 안 봤다**: 실측으로 `ground_tool_args(env, "teleport", …)` 가
#       `"admit"` 을 냈고, `no_intervention` 에 스키마 밖 `agent` 를 얹어도 `admit` 이었다.
#   (d) 🔴 **교차축** (항목 8). `macro="Replace"` + 다른 팔의 tool 호출에서 그 인자가
#       수입되면 두 측정축이 다 초록인 채 세계가 바뀐다. 출처(provenance) 일치가 그것을 막고,
#       그 사실을 (8) 이 **순수 함수로** · (9) 가 **진짜 `decide_all` 출력으로** 잰다.
#
# 변이시험(스크래치패드 오버레이 사본, 레포 파일은 안 부순다)으로 실제 RED 를 확인한 것:
#   * `deferred:*` 를 `"admit"` 으로 바꾼다            → (3)·(4) 가 빨개진다
#   * 집행 조건에서 `verdict == "admit"` 를 뺀다       → (5) 의 deferred 쪽이 빨개진다
#   * `reject` 일 때 예외를 던진다                     → (2) 가 빨개진다(결정이 지워진다)
#   * 이름 검사(`reject:unknown_tool`)를 뺀다          → (7) 이 빨개진다
#   * 출처 일치(0b)를 뺀다                             → (8)·(9) 가 빨개진다
#   * `TOOL_PARAM_SCHEMA` 를 파이썬과 갈라 놓는다      → (7) 의 교차언어 대조가 빨개진다
# 출력은 수정 라운드 보고서에 그대로 붙였다.
#
# 🔴 `127.0.0.1:8077`(진짜 DSPy 서비스)로는 **한 요청도 안 나간다** — `/decide` 는 사용자
# 계정의 유료 OpenAI 호출이다. (9) 는 **루프백에 우리 대역 서버를 하나 띄우고** `const
# DSPY_URL`(policy.jl:19)이 읽히는 그 순간에만 `ENV["DSPY_URL"]` 을 그 포트로 돌려놓는다 —
# `test/tool_lane_keys_survive.jl` 과 같은 수법이다.
#
# ⚠️ `Sockets` 를 직접 import 하지 않는다(`Project.toml` 의 `[deps]` 에 없어 `Pkg.test()` 의
#    샌드박스에서 안 풀린다). `HTTP` 가 들고 있으므로 `HTTP.Sockets.*` 로 닿는다.
#    `Graphs` 는 policy.jl 의 `_agent_pending`(`ood_features` 경유)이 쓴다.
#
# 실행: julia +lts --project=. test/tool_args_grounding.jl
# =============================================================================

module ToolArgsGrounding

using Test
using ConstructionBots
const CB = ConstructionBots
import HTTP, JSON3
import Random
import Graphs

const REPO = normpath(joinpath(@__DIR__, ".."))

# BatteryTruth / BATTERY_FLEET / init_battery_fleet! 는 런타임 include 계층에 산다.
isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))

# ---- 루프백 DSPy 대역 서버 ((9) 전용) -----------------------------------------------------
# 응답의 tool 레인 값을 Ref 로 갈아 끼운다 — 로봇 id 는 TENV 가 생긴 뒤에야 알 수 있다.
const _CALL_REF = Ref{Any}(nothing)
const _ARGS_REF = Ref{Any}(nothing)

const _SERVER = HTTP.serve!(HTTP.Sockets.localhost, 0; listenany = true, verbose = -1) do req
    if req.target == "/health"
        # `dspy_ready()` 가 찌르는 자리. 200 을 안 주면 `service_decide` 가 곧장 nothing 을
        # 돌려주고 (9) 가 "레인이 안 왔다" 로 **빨개진다**(조용히 안 샌다).
        # 🔴 2026-08-29 (T11): `surro_kinds` 를 **반드시** 싣는다. kind 색인 라우터가 이 값을
        #    `/health` 에서만 받고, 없으면 "못 쟀다"로 캐시한 뒤 `select_lane` 이 그 사건에서
        #    **죽는다**(§0-C 결정 3 의 설계된 동작). 실측: 이 줄이 없으면 `decide_all` 을
        #    부르는 절이 "surrogate kind support is unknown" 으로 정당하게 빨개진다.
        # 🔴 그리고 여기서는 **빈 목록**이다. 이 파일의 (9)절은 **dspy 가 집행된 판**을 재는데,
        #    새 라우터에서 그것을 만드는 손잡이는 kind 축이다: 아는 kind 가 없으면 battery
        #    사건도 `ood_kind` 로 판정돼 LLM 으로 간다. `[]` 는 "쟀는데 비었다" 이고
        #    `null`("못 쟀다", → 죽는다)과 **다른 사건**이다(삼상 규약).
        return HTTP.Response(200, "{\"status\":\"ok\",\"surro_kinds\":[]}")
    elseif req.target == "/decide"
        local out = Dict{String,Any}(
            "dspy" => Dict{String,Any}(
                "chosen" => _ARM_NAME, "ranking" => [_ARM_NAME, _NOOP_NAME],
                "margin" => 0.4, "rationale" => "fake service", "policy" => "dspy:test",
                "unsupported" => String[],
                # ---- tool 레인 여덟 ----
                "tool_called" => _CALL_REF[], "tool_args" => _ARGS_REF[],
                "tool_calls_n" => 1, "tools_offered" => 3, "expressible" => true,
                "native_fc" => true, "tool_lane_error" => nothing,
                "macro_tool_agree" => nothing),
            # 🔴 2026-08-29 (T11): 여기 있던 근거 *"surrogate 를 불가로 두면 select_lane 이
            #    dspy 를 고른다"* 는 **거짓이 됐다** — 가용성으로 레인을 바꾸는 것이 곧
            #    조용한 폴백이라 §0-C 결정 3 이 그 경로를 없앴다. 지금 dspy 를 고르게 하는
            #    것은 위 `/health` 의 `surro_kinds: []` 하나다. 이 키는 남겨 두지만
            #    **라우팅에 아무 영향이 없다**(라우터가 dspy 만 청구하므로 읽히지도 않는다).
            "surrogate" => nothing)
        return HTTP.Response(200, JSON3.write(out))
    end
    return HTTP.Response(404, "")
end
const _PORT = HTTP.Servers.port(_SERVER)

# 🔴 `_SERVER` 를 연 뒤 밖으로 나가는 **모든 길**에 `close(_SERVER)` 가 있어야 한다.
const _PREV_DSPY_URL = get(ENV, "DSPY_URL", nothing)
ENV["DSPY_URL"] = "http://127.0.0.1:$(_PORT)"
try
    include(joinpath(REPO, "tools", "monitor", "policy.jl"))
catch
    close(_SERVER)
    rethrow()
finally
    _PREV_DSPY_URL === nothing ? delete!(ENV, "DSPY_URL") : (ENV["DSPY_URL"] = _PREV_DSPY_URL)
end

# 🔴 생산 코드를 실제로 태운다 — `run_demo.jl` 이 부르는 바로 그
# `enact_target`/`enact_macro!`/`enact_decision!`.
include(joinpath(REPO, "tools", "monitor", "enact.jl"))

# ---- 어휘는 레지스트리에서 유도한다 -------------------------------------------------------
# 🔴 매크로 이름 리터럴을 쓰지 않는다(`test/policy_macro_binding.jl:134` 의 규칙). `ActionRegistry`
#    는 policy.jl 의 가드 있는 include 로 같이 들어온다. id 0 = 절제(NOOP)는 이 레지스트리의 규약.
const _NOOP_NAME = ActionRegistry.NAME[0]
const _BATT_ARMS = String[ActionRegistry.NAME[i] for i in ActionRegistry.kind_valid(:battery)
                          if ActionRegistry.NAME[i] != _NOOP_NAME]
const _ARM_NAME   = _BATT_ARMS[1]          # 집행되는 팔
const _OTHER_ARM  = _BATT_ARMS[end]        # **다른** 팔 — (8)(9) 의 교차축이 이걸 쓴다
# tool 이름도 리터럴이 아니라 `CB.MACRO_TO_TOOL` 에서 유도한다(그 표는 (7) 이 파이썬과 묶는다).
const _TOOL       = CB.MACRO_TO_TOOL[_ARM_NAME]
const _OTHER_TOOL = CB.MACRO_TO_TOOL[_OTHER_ARM]
const _NOOP_TOOL  = CB.MACRO_TO_TOOL[_NOOP_NAME]

const TENV = try
    CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr",
                       project_name = "tool_args_grounding",
                       num_robots = 4, assignment_mode = :greedy,
                       n_spare_per_pool = 4,
                       open_animation_at_end = false, save_animation = false,
                       write_results = false, return_env_before_sim = true,
                       rng = Random.MersenneTwister(1))
catch
    close(_SERVER)
    rethrow()
end

const _PREV_FLEET = CB.BATTERY_FLEET[]
const _PREV_ACCT  = CB.BATTERY_ACCOUNTING[]

# `decide_all` 이 만드는 것과 **같은 모양**의 8키 레인. 🔴 키 여덟은 항상 존재하고 값만
# `nothing` 일 수 있다 — `haskey` 는 값이 실려 왔다는 증거가 아니다(T1 소비자 규칙 1).
# 그래서 `tool_called` 와 `tool_args` 를 **따로** 받는다: 둘은 서로 독립적으로 비어 있을 수 있고,
# 그 조합이 바로 아래 (5) 가 재는 자리다.
_lane(called, args) = Dict{String,Any}("tool_called" => called, "tool_args" => args,
                                       "tool_calls_n" => nothing, "tools_offered" => nothing,
                                       "expressible" => nothing, "native_fc" => nothing,
                                       "tool_lane_error" => nothing, "macro_tool_agree" => nothing)

# 이 역할에 대해 자산 장부에 남은 행 수. 🔴 **팔에 무관한 "세계가 바뀌었다" 관측**이다:
# `hot_swap_robot!` 과 `_apply_battery_swap!` 이 **둘 다** `record_asset_swap!` 을 부른다.
_rows(r) = count(a -> a.role == r, CB.asset_ledger())

# ---- (7) 교차언어: 파이썬 tool 알파벳을 **소스에서** 뽑는다 --------------------------------
# 🔴 서비스를 부팅하지 않는다 — `tool_registry.py` 만 import 해서 `inspect.signature` 로
#    선언을 읽는다. 🔴 `env -u OPENAI_API_KEY` 로 감싼다(과금 경로에 손이 닿을 여지 자체를 없앤다).
# 🔴 못 닿으면 **skip 이 아니라 빨개진다.** skip 은 같은 구멍에 단계만 하나 더한 것이다.
const _PY_BIN = joinpath(REPO, ".venv", "bin", "python")
const _PY_SRC = get(ENV, "TOOL_REGISTRY_PY_SRC",
                    joinpath(REPO, "src", "respec", "llm_service"))
const _PY_EXTRACT = raw"""
import sys, json, inspect
sys.path.insert(0, sys.argv[1])
import tool_registry as tr
schema = {}
for name, fn in tr._FUNCS.items():
    schema[name] = {p.name: (p.default is inspect.Parameter.empty)
                    for p in inspect.signature(fn).parameters.values()}
print(json.dumps({"macro_to_tool": tr.MACRO_TO_TOOL, "schema": schema}, ensure_ascii=False))
"""

function _py_tool_alphabet()
    isfile(_PY_BIN) || error("교차언어 게이트: 파이썬이 없다 — $(_PY_BIN) (skip 하지 않는다)")
    isdir(_PY_SRC) || error("교차언어 게이트: 서비스 소스 디렉토리가 없다 — $(_PY_SRC)")
    local o = IOBuffer(); local e = IOBuffer()
    local pr = run(pipeline(ignorestatus(
        `env -u OPENAI_API_KEY $(_PY_BIN) -c $(_PY_EXTRACT) $(_PY_SRC)`); stdout = o, stderr = e))
    local out = String(take!(o)); local errs = String(take!(e))
    pr.exitcode == 0 || error("교차언어 게이트: 추출 실패 (rc=$(pr.exitcode))\n$(errs)")
    local j = JSON3.read(out)
    local m2t = Dict{String,String}(String(k) => String(v) for (k, v) in pairs(j["macro_to_tool"]))
    local sch = Dict{String,Dict{String,Bool}}(
        String(k) => Dict{String,Bool}(String(kk) => Bool(vv) for (kk, vv) in pairs(v))
        for (k, v) in pairs(j["schema"]))
    return (macro_to_tool = m2t, schema = sch)
end

try
    CB.init_battery_fleet!(TENV)
    local fleet = CB.BATTERY_FLEET[]

    local descs = CB.open_agent_descriptors(TENV)
    local A = CB.resolve_agent_id(TENV, descs[1]["id"])
    local B = CB.resolve_agent_id(TENV, descs[2]["id"])
    # 이 판의 truth 는 **A** 에 대한 배터리 사건이다. LLM 은 아래에서 **B** 를 낸다.
    local truth = CB.BatteryTruth(A, 0.1)

    @testset "tool 인자 접지 판정 — 삼상 (Plan B / T3)" begin

    @testset "(0) 전제 — A ≠ B 이고 둘 다 실재 로봇이다" begin
        @test length(descs) >= 2
        @test A !== nothing && B !== nothing && A != B
        @test truth.robot == A
        @test haskey(fleet.soc, A) && haskey(fleet.soc, B)
        # 어휘가 레지스트리에서 왔고, 두 팔이 실제로 다르다(아니면 (8)(9) 가 하중을 잃는다).
        @test length(_BATT_ARMS) >= 2
        @test _ARM_NAME != _OTHER_ARM
        @test _TOOL != _OTHER_TOOL != _NOOP_TOOL
        # `decide_all` 이 이 실행에서 실제로 서비스를 부르는 설정인가((9) 의 전제).
        @test !(POLICY in ("canonical", "noop", "oracle") && !router_drives() &&
                get(ENV, "DEMO_ALL_POLICIES", "1") == "0")
    end

    @testset "(1) admit — 열거에 실재하는 id" begin
        local v, d = CB.ground_tool_args(TENV, _TOOL,
                                         Dict{String,Any}("agent" => string(B)))
        @test v == "admit"                       # 🔴 정확히 "admit". 접미사 없음.
        @test occursin(string(B), d)
        # 보여 준 집합 전체가 admit 이다(같은 열거에서 나오므로 갈라질 수 없다).
        for dd in descs
            @test CB.ground_tool_args(TENV, _OTHER_TOOL,
                                      Dict{String,Any}("agent" => dd["id"]))[1] == "admit"
        end
        # 집행도 그것을 쓴다.
        local tgt = enact_target(TENV, truth, _lane(_TOOL,
                        Dict{String,Any}("agent" => string(B))), Dict{String,Any}(), _ARM_NAME)
        @test tgt.verify == "admit"
        @test tgt.source == "tool"
        @test tgt.agent == B
        @test tgt.reject === nothing
    end

    @testset "(2) 🔴 reject:ungrounded_agent — 열거 밖 문자열. 그래도 결정은 안 지워진다" begin
        local v, d = CB.ground_tool_args(TENV, _TOOL,
                                         Dict{String,Any}("agent" => "RobotID(9999)"))
        @test v == "reject:ungrounded_agent"
        @test startswith(v, "reject:")
        @test occursin("9999", d)
        # 파싱이 없다는 것(정수를 파싱해 RobotID(n) 을 지으면 이 셋이 통과하고 접지가 사라진다).
        for bad in ("9999", string(A) * " ", "")
            @test CB.ground_tool_args(TENV, _TOOL,
                                      Dict{String,Any}("agent" => bad))[1] == "reject:ungrounded_agent"
        end
        # 문자열이 아닌 값도 "재서 어긋났다" 다 — 인자는 실려 왔고 열거에 없다.
        @test CB.ground_tool_args(TENV, _TOOL,
                                  Dict{String,Any}("agent" => 5))[1] == "reject:ungrounded_agent"
        # 🔴 항목 11 — `"agent": null` 과 `"agent"` **부재**는 다른 사건이다. 예전에는 둘 다
        # 같은 판정으로 접혔고, 그 둘을 가르는 `detail` 은 계산된 뒤 버려졌다.
        local vn, dn = CB.ground_tool_args(TENV, _TOOL, Dict{String,Any}("agent" => nothing))
        local vm, dm = CB.ground_tool_args(TENV, _TOOL, Dict{String,Any}())
        @test vn == "reject:ungrounded_agent"        # 키는 실려 왔고 값이 null 이다
        @test vm == "reject:missing_required_param"  # 키가 아예 없다 (항목 10)
        @test vn != vm
        @test dn != dm
        @test occursin("null", dn)

        # 🔴 spec §4-1: tool 실패가 **결정을 지우지 않는다.** 집행은 그대로 일어난다.
        local tgt = enact_target(TENV, truth, _lane(_TOOL,
                        Dict{String,Any}("agent" => "RobotID(9999)")), Dict{String,Any}(), _ARM_NAME)
        @test tgt.verify == "reject:ungrounded_agent"
        @test tgt.source == "truth"               # T2 의 세 값은 그대로다
        @test tgt.agent == truth.robot            # = A
        @test tgt.tool_agent == "RobotID(9999)"   # 원문은 버리지 않는다
        @test tgt.reject == "verify:reject:ungrounded_agent"
        @test occursin("9999", tgt.verify_detail) # 🔴 사유 문자열이 집행부까지 살아온다(항목 11)
        fleet.soc[A] = 0.42
        fleet.soc[B] = 0.11
        local res = enact_macro!(TENV, truth, _ARM_NAME, tgt.agent)
        @test res.enact_applied === true          # ← 결정이 그대로 집행됐다
        @test fleet.soc[A] == 1.0
        @test fleet.soc[B] == 0.11                # 음성 대조: LLM 이 지목한 B 는 안 바뀐다
    end

    @testset "(3) deferred:no_tool_call — tool 호출 자체가 없다" begin
        # 🔴 "못 쟀다" 는 "재서 통과했다" 가 아니다(spec §9-2).
        @test CB.ground_tool_args(TENV, nothing, nothing)[1] == "deferred:no_tool_call"
        # 인자가 **실재 id 로 실려 있어도** 호출 이름이 없으면 못 잰 것이다.
        @test CB.ground_tool_args(TENV, nothing,
                Dict{String,Any}("agent" => string(B)))[1] == "deferred:no_tool_call"
        @test CB.ground_tool_args(TENV, "", nothing)[1] == "deferred:no_tool_call"
        @test CB.ground_tool_args(TENV, 7, nothing)[1] == "deferred:no_tool_call"
        # 호출은 있는데 인자 dict 이 통째로 없다 — 이것도 못 잰 것이다.
        @test CB.ground_tool_args(TENV, _TOOL, nothing)[1] == "deferred:no_tool_args"
        # 🔴 admit 이 아니다.
        @test CB.ground_tool_args(TENV, nothing, nothing)[1] != "admit"
        # 8키가 전부 nothing 인 레인(= `policy_entry` 폴백 분기가 내는 그 모양)도 같다.
        local tgt = enact_target(TENV, truth, _lane(nothing, nothing), Dict{String,Any}(), _ARM_NAME)
        @test tgt.verify == "deferred:no_tool_call"
        @test tgt.source == "truth"
        # `tool_lane` 자체가 없는 호출자도 같은 답을 얻는다.
        @test enact_target(TENV, truth, nothing, nothing, _ARM_NAME).verify == "deferred:no_tool_call"
    end

    @testset "(4) 🔴 deferred:no_groundable_param — 접지할 파라미터가 없는 tool" begin
        # NOOP tool 의 선언된 인자는 `reason` 뿐이다(`tool_registry.py`). 접지할 것이 없다.
        # 🔴 이것을 `admit` 으로 기록하면 나중에 "접지 통과율" 을 세는 사람이 **NOOP 을
        #    통과로 센다.** 공허한 참은 통과가 아니다.
        local v, d = CB.ground_tool_args(TENV, _NOOP_TOOL,
                        Dict{String,Any}("reason" => "SoC 0.9 이고 진전이 있다"))
        @test v == "deferred:no_groundable_param"
        @test v != "admit"
        @test occursin("reason", d)
        local tgt = enact_target(TENV, truth,
                        _lane(_NOOP_TOOL, Dict{String,Any}("reason" => "x")),
                        Dict{String,Any}(), _NOOP_NAME)
        @test tgt.verify == "deferred:no_groundable_param"
        @test tgt.source == "truth"
        @test tgt.tool_agent === nothing
        # ⚠️ 인자가 **아예 비어** 있으면 이제 `deferred` 가 아니라 `reject` 다 — 필수 인자
        #    `reason` 이 없는 것은 **잴 수 있는 실패**이기 때문이다(항목 10). 예전에는 그
        #    사건이 "못 쟀다" 로 기록됐고, 같은 보고서가 이 레인에 디코드 시점 강제가 없다고
        #    재놓은 것과 자기모순이었다.
        @test CB.ground_tool_args(TENV, _NOOP_TOOL,
                                  Dict{String,Any}())[1] == "reject:missing_required_param"
    end

    @testset "(5) 🔴 admit 일 때만 LLM 의 agent 가 세계를 바꾼다" begin
        # (a) admit → B 가 바뀌고 A 는 안 바뀐다.
        fleet.soc[A] = 0.31
        fleet.soc[B] = 0.22
        local ok = enact_target(TENV, truth, _lane(_TOOL,
                        Dict{String,Any}("agent" => string(B))), Dict{String,Any}(), _ARM_NAME)
        @test ok.verify == "admit"
        enact_macro!(TENV, truth, _ARM_NAME, ok.agent)
        @test fleet.soc[B] == 1.0
        @test fleet.soc[A] == 0.31

        # (b) 🔴 **접지 판정이 admit 이 아니면 그 agent 는 세계를 못 바꾼다.**
        #     여기서 인자는 **실재하는 B** 다 — 그런데 `tool_called` 값이 없어서 판정이
        #     `deferred` 다. 집행 조건에서 `verdict == "admit"` 를 빼면 이 판이 B 로 가고
        #     이 검사가 빨개진다.
        fleet.soc[A] = 0.55
        fleet.soc[B] = 0.66
        local def = enact_target(TENV, truth, _lane(nothing,
                        Dict{String,Any}("agent" => string(B))), Dict{String,Any}(), _ARM_NAME)
        @test def.verify == "deferred:no_tool_call"
        @test def.source == "truth"
        @test def.agent == truth.robot             # = A
        @test def.tool_agent == string(B)          # 원문은 남는다
        enact_macro!(TENV, truth, _ARM_NAME, def.agent)
        @test fleet.soc[A] == 1.0
        @test fleet.soc[B] == 0.66                 # ← B 는 한 비트도 안 바뀐다
    end

    @testset "(6) 삼상 그 자체 — 셋 다 도달했고 서로 안 겹친다" begin
        local seen = String[
            CB.ground_tool_args(TENV, _TOOL, Dict{String,Any}("agent" => string(A)))[1],
            CB.ground_tool_args(TENV, _TOOL, Dict{String,Any}("agent" => "RobotID(9999)"))[1],
            CB.ground_tool_args(TENV, nothing, nothing)[1],
            CB.ground_tool_args(TENV, _NOOP_TOOL, Dict{String,Any}("reason" => "x"))[1]]
        _state(v) = v == "admit" ? "admit" :
                    startswith(v, "reject:") ? "reject" :
                    startswith(v, "deferred:") ? "deferred" : "🔴 문법 밖: " * v
        @test _state.(seen) == ["admit", "reject", "deferred", "deferred"]
        @test length(Set(seen)) == 4               # 네 입력이 네 개의 서로 다른 판정을 낸다
        # R16(강제 팔)은 **접지 판정을 덮지 않는다** — 접지는 인자에 대한 사실이고, 강제 팔의
        # 거절은 `enact_agent_source` 가 나른다. 두 축을 한 필드에 섞지 않는다.
        local tgt = enact_target(TENV, truth, _lane(_TOOL,
                        Dict{String,Any}("agent" => string(B))),
                        Dict{String,Any}("deviated" => true), _ARM_NAME)
        @test tgt.verify == "admit"
        @test tgt.source == "truth"
        @test tgt.reject == "arm_overridden"
    end

    @testset "(7) 🔴 tool 의 **이름**이 접지된다 + 파이썬 알파벳과 묶인다 (항목 7·9)" begin
        # 🔴 실측이었던 구멍: `ground_tool_args(env, "teleport", Dict("agent" => B))` → "admit".
        #    존재하지도 않는 tool 이름이 통과했다 — 접지 함수가 **인자만 보고 이름을 안 봤다.**
        local v, d = CB.ground_tool_args(TENV, "teleport",
                                         Dict{String,Any}("agent" => string(B)))
        @test v == "reject:unknown_tool"
        @test v != "admit"
        @test occursin("teleport", d)
        for bogus in ("replace_agent", "swap_body_v2", "SWAP_BODY", "no_intervention ")
            @test CB.ground_tool_args(TENV, bogus,
                                      Dict{String,Any}("agent" => string(B)))[1] == "reject:unknown_tool"
        end
        # 집행도 그 이름을 안 쓴다.
        local tgt = enact_target(TENV, truth, _lane("teleport",
                        Dict{String,Any}("agent" => string(B))), Dict{String,Any}(), _ARM_NAME)
        @test tgt.source == "truth"
        @test tgt.agent == truth.robot

        # 🔴 항목 9 — **스키마 밖 인자**. dspy 3.3.0 은 `strict` 도 `additionalProperties` 도
        #    안 붙이고 `ToolCalls` 가 여분 인자를 안 걸러서 이 입력이 실제로 여기까지 온다.
        #    실측이었던 구멍: `no_intervention` + `agent` → "admit".
        local v2, d2 = CB.ground_tool_args(TENV, _NOOP_TOOL,
                        Dict{String,Any}("reason" => "x", "agent" => string(B)))
        @test v2 == "reject:off_schema_param"
        @test v2 != "admit"
        @test occursin("agent", d2)
        @test CB.ground_tool_args(TENV, _TOOL,
                Dict{String,Any}("agent" => string(B),
                                 "zone" => "z1"))[1] == "reject:off_schema_param"
        # 그 판에서 집행이 그 agent 를 쓰지 않는다.
        local t2 = enact_target(TENV, truth, _lane(_NOOP_TOOL,
                        Dict{String,Any}("reason" => "x", "agent" => string(B))),
                        Dict{String,Any}(), _NOOP_NAME)
        @test t2.verify == "reject:off_schema_param"
        @test t2.source == "truth"

        # 🔴 **교차언어 결속.** Julia 의 두 표가 `tool_registry.py` 에서 실제로 유도된 것과
        #    같은가. 손으로 쓴 사본을 두고 게이트를 안 걸면 파이썬에서 tool 을 하나 더해도
        #    Julia 는 그것을 `reject:unknown_tool` 로 **조용히** 죽인다 — 그리고 양쪽 게이트가
        #    전부 초록이다. 못 닿으면 skip 이 아니라 빨개진다.
        local py = _py_tool_alphabet()
        @test py.macro_to_tool == CB.MACRO_TO_TOOL
        @test py.schema == CB.TOOL_PARAM_SCHEMA
        # 위 두 줄이 **집합 등식**이라는 것을 눈에 보이게 다시 못박는다(부분집합이 아니다).
        @test Set(keys(py.schema)) == Set(keys(CB.TOOL_PARAM_SCHEMA))
        @test Set(values(py.macro_to_tool)) == Set(keys(CB.TOOL_PARAM_SCHEMA))
        # 접지 가능한 파라미터가 실제로 어느 tool 에 선언돼 있는지도 파이썬에서 확인한다.
        @test any(haskey(v, "agent") for v in values(py.schema))
        @test !haskey(py.schema[_NOOP_TOOL], "agent")
    end

    @testset "(8) 🔴🔴 교차축 — 다른 팔의 tool 호출에서 인자를 수입하지 않는다 (항목 8)" begin
        # 🔴 실측이었던 구멍:
        #      macro="Replace" · tool_called="no_intervention" · tool_args=(agent=B)
        #        → verify=="admit" · enact_agent_source=="tool" · **Replace 가 B 에서 집행됐다**
        #    두 측정축이 다 초록인데 세계가 NOOP tool 의 인자로 바뀌었다.
        #
        # (a) 그 입력 자체는 이제 스키마 층에서 이미 죽는다(항목 9).
        local t0 = enact_target(TENV, truth, _lane(_NOOP_TOOL,
                        Dict{String,Any}("agent" => string(B))), Dict{String,Any}(), _ARM_NAME)
        @test t0.verify != "admit"
        @test t0.source == "truth"
        # (b) 🔴 **출처 일치가 하중을 받는 자리**: 다른 팔의 tool 을 **스키마대로 정확히**
        #     부른 판. 접지 판정은 `admit` 이다(인자에 대한 사실은 참이다) — 그래도 집행되는
        #     팔의 호출이 아니므로 그 인자를 수입하지 않는다.
        local tl = _lane(_OTHER_TOOL, Dict{String,Any}("agent" => string(B)))
        local tgt = enact_target(TENV, truth, tl, Dict{String,Any}(), _ARM_NAME)
        @test tgt.verify == "admit"                # ← 접지 축은 그대로 초록이다
        @test tgt.source == "truth"                # ← 그런데 인자를 안 쓴다
        @test tgt.agent == truth.robot             # = A
        @test tgt.tool_agent == string(B)          # 원문은 남는다(무엇을 거절했는지 보이게)
        @test tgt.reject == "tool_arm_mismatch"    # **왜** 안 썼는지가 남는다
        # 그리고 세계도 그렇게 바뀐다: A 가 바뀌고 B 는 한 비트도 안 바뀐다.
        fleet.soc[A] = 0.37
        fleet.soc[B] = 0.73
        local rowsB0 = _rows(B)
        enact_macro!(TENV, truth, _ARM_NAME, tgt.agent)
        @test fleet.soc[A] == 1.0
        @test fleet.soc[B] == 0.73
        @test _rows(B) == rowsB0                   # B 의 세계는 편집되지 않았다
        # (c) 같은 팔의 tool 이면 그대로 쓴다 — 이 검사가 없으면 (b) 가 "언제나 거절"과
        #     구별되지 않는다(항진명제 방지).
        local same = enact_target(TENV, truth, _lane(_TOOL,
                        Dict{String,Any}("agent" => string(B))), Dict{String,Any}(), _ARM_NAME)
        @test same.source == "tool"
        @test same.agent == B
        # (d) 대응하는 tool 이 아예 없는 팔(zone 팔 등)에서는 어떤 호출도 그 팔의 것이 아니다.
        @test !haskey(CB.MACRO_TO_TOOL, "ForbidZone")
        local nz = enact_target(TENV, truth, _lane(_TOOL,
                        Dict{String,Any}("agent" => string(B))), Dict{String,Any}(), "ForbidZone")
        @test nz.source == "truth"
        @test nz.reject == "tool_arm_mismatch"
    end

    @testset "(9) 🔴 진짜 `decide_all` 출력으로 집행부를 태운다 (항목 0·13)" begin
        # 🔴 위 검사들은 전부 **손으로 지은 레인 dict** 을 먹인다. 이 레포는 정확히 그 사고를
        #    이미 밟았다(`tools/test_policy_escalation.jl` 의 `unavail()` 이 `policy_entry` 의
        #    손으로 쓴 복제본이었다 — 복제본을 검사하면 복제본만 지켜진다). 그래서 최소 한
        #    검사는 **루프백 대역 서버 → `decide_all` → `enact_decision!`** 경로로 태운다.
        # 🔴 8077 로는 한 요청도 안 나간다 — `DSPY_URL` 은 위에서 우리 포트로 고정됐다.
        # (a) 같은 팔의 호출: 세계가 **B** 에서 바뀐다.
        _CALL_REF[] = _TOOL
        _ARGS_REF[] = Dict{String,Any}("agent" => string(B))
        local tr1 = CB.BatteryTruth(A, 0.1)
        fleet.soc[A] = 0.44
        fleet.soc[B] = 0.12
        local rowsA0 = _rows(A)
        local d1 = decide_all(TENV, tr1; nl = "")
        @test d1.enacted == "dspy"                 # 전제: 레인이 실제로 집행됐다
        @test d1.macro_name == _ARM_NAME
        @test d1.tool_lane["tool_called"] == _TOOL # 진짜 `decide_all` 이 나른 값이다
        local e1 = enact_decision!(TENV, tr1, d1)
        @test e1.row["enact_agent_source"] == "tool"
        @test e1.row["enact_agent"] == string(B)
        @test e1.row["tool_agent"] == string(B)
        @test e1.row["verify"] == "admit"
        @test e1.row["enact_agent_reject"] === nothing
        @test e1.row["enact_applied"] === true
        @test e1.target.agent == B
        @test fleet.soc[B] == 1.0
        @test fleet.soc[A] == 0.44                 # 음성 대조
        @test _rows(A) == rowsA0                   # A 의 세계는 편집되지 않았다

        # (b) 🔴 **교차축을 진짜 레인으로**: 서비스가 **다른 팔의 tool** 을 불렀다. 접지 축은
        #     `admit` 인데 집행은 그 인자를 안 쓴다 — 그리고 세계는 A 에서 바뀐다.
        _CALL_REF[] = _OTHER_TOOL
        _ARGS_REF[] = Dict{String,Any}("agent" => string(B))
        local tr2 = CB.BatteryTruth(A, 0.1)
        fleet.soc[A] = 0.29
        fleet.soc[B] = 0.71
        local rowsB1 = _rows(B)
        local d2 = decide_all(TENV, tr2; nl = "")
        @test d2.enacted == "dspy"
        @test d2.macro_name == _ARM_NAME
        @test d2.tool_lane["tool_called"] == _OTHER_TOOL
        local e2 = enact_decision!(TENV, tr2, d2)
        @test e2.row["verify"] == "admit"                       # 접지 축은 초록
        @test e2.row["enact_agent_source"] == "truth"           # 그래도 인자를 안 쓴다
        @test e2.row["enact_agent"] == string(A)
        @test e2.row["tool_agent"] == string(B)
        @test e2.row["enact_agent_reject"] == "tool_arm_mismatch"
        @test fleet.soc[A] == 1.0
        @test fleet.soc[B] == 0.71
        @test _rows(B) == rowsB1
    end

    end
finally
    CB.BATTERY_FLEET[] = _PREV_FLEET
    CB.BATTERY_ACCOUNTING[] = _PREV_ACCT
    close(_SERVER)
end

end # module
