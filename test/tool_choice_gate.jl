# =============================================================================
# 라우터 게이팅 `tool_choice` — 세 상태 전수 · 그리고 그것이 **요청까지 실제로 간다**
# (2026-08-29, Plan B / T-C)
#
# 무엇을 지키는가
# ----------------
# 🔴 `tool_choice="required"` 는 공짜가 아니다. 컨트롤러가 같은 요청·같은 빌드로 그 손잡이만
# 갈라 유료 2콜을 냈고(실측), `required` 판에서 프로바이더가 tool 호출만 내고 message content
# 를 **비웠다**: `reasoning=""` · `expressible=null` · `chosen=""` → `coerced` NOOP, 그리고
# **예외가 안 난다.** 그래서 무조건 강제는 `expressible` 을 전 사건에서 지운다 — 사용자가
# 명시적으로 원하지 않는다고 말한 상태다.
#
# 사용자 지시(2026-08-29): **라우터가 familiar 라고 판정한 사건에만** 강제한다.
#
# 🔴 그런데 `route_verdict` 는 **세 사건을 두 값으로 접고 있었다**: 교정 JSON 이 없어도
# (`!have_det`) 서술자가 없어도(`v === nothing`) `novel == false` 다 — "익숙하다" 와 정확히
# 같은 값. 이 작업 트리에는 `wm4spacecraft_manufacturing/novelty/novelty_calibration.json` 이
# **없으므로**, `novel == false` 만 보고 강제하면 **모든 사건이 강제된다** = 지우지 말라고 한
# 그 필드가 전 사건에서 사라진다. `novelty_measured` 가 그 붕괴를 푸는 키다.
# (같은 축의 선례: 같은 파일의 `surrogate_support_measured` — `supported::Bool` 옆에 "쟀는가"를
#  따로 놓은 F4. 이 파일은 그 형식을 그대로 따른다.)
#
# 검사하는 명제 넷
# ----------------
#  (1) `tool_choice_for` 진리표 **3상태 전수**: 못 쟀다 / 낯설다 / 익숙하다.
#  (2) `route_verdict` 의 `novelty_measured` 가 **세 분기 전부**에서 옳다(교정 없음 /
#      descriptors 없음 / 실제 판정). 실제 판정 분기는 `v` 를 주입해 만든다.
#      🔴 그리고 `novel` 의 값은 **한 글자도 안 바뀌었다** — 기존 녹화와의 비교 가능성이
#      거기 걸려 있다. 두 키를 나란히 단언한다.
#  (3) 🔴 **배선이 아니라 발화.** `decide_all` 을 진짜로 돌려 **나가는 요청 본문**을 잰다.
#      교정이 없는 기본 작업 트리에서는 `tool_choice` 키가 요청에 **아예 없다** = 2026-08-29
#      이전과 바이트 단위로 같은 요청. 그리고 합성 감지기를 설치해 novelty 축을 **실제로
#      재게 만들면**, familiar 사건에서 `"required"` 가 실리고 novel 사건에서는 안 실린다.
#      (합성 감지기 = `CB.set_novelty_detector!` 로 직접 설치한다. `install_novelty!()` 는
#       감지기가 이미 있으면 즉시 `true` 를 돌려주므로 교정 **파일**이 필요 없다.)
#  (4) `service_decide` 의 payload 줄 자체 — 키워드가 `nothing` 이면 안 싣고, 값이 있으면 싣는다
#      (`agents`/`zones` 와 정확히 같은 규약).
#
# 🔴 **8077(진짜 DSPy 서비스)로는 한 요청도 안 나간다.** `/decide` 는 사용자 계정의 유료
# OpenAI 호출이다. `const DSPY_URL`(policy.jl)은 include 시점에 한 번 ENV 에서 읽히므로, 그
# 순간에만 우리 루프백 포트로 돌려놓고 곧바로 되돌린다 —
# `test/tool_lane_keys_survive.jl` · `test/service_decide_ships_zones.jl` 과 같은 패턴이다.
# 같은 이유로 `Sockets` 를 **직접 import 하지 않는다**(`Project.toml` 의 `[deps]` 에 없으면
# `Pkg.test()` 샌드박스에서 안 풀린다 — 그 함정이 형제 게이트를 통째로 에러로 만든 이력이 있다).
#
# ⚠️ 이 파일은 **전역을 하나 건드린다**: `CB.NOVELTY_DETECTOR[]`. 스위트의 다른 게이트가 그
# 값을 보므로, 들어올 때의 값을 저장하고 `finally` 에서 **반드시** 되돌린다.
#
# 실행: julia +lts --project=. test/tool_choice_gate.jl
# =============================================================================
module ToolChoiceGate

using Test
using ConstructionBots
const CB = ConstructionBots
import HTTP, JSON3
import Random
import Graphs

const REPO = normpath(joinpath(@__DIR__, ".."))
isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))

# ---- 루프백 DSPy 대역 서버 — **요청 본문을 붙잡는다** --------------------------------------
# 이 파일이 재는 것은 응답이 아니라 **나간 요청**이다(`test_tool_choice_forced.py` 가 파이썬
# 쪽에서 "보내질 kwargs" 를 재는 것과 같은 축).
const _LAST_PAYLOAD = Ref{Any}(nothing)
const _N_DECIDE = Ref(0)

const _SERVER = HTTP.serve!(HTTP.Sockets.localhost, 0; listenany = true, verbose = -1) do req
    if req.target == "/health"
        return HTTP.Response(200, "{\"status\":\"ok\"}")
    elseif req.target == "/decide"
        _LAST_PAYLOAD[] = JSON3.read(String(req.body))
        _N_DECIDE[] += 1
        # 두 레인 다 가용하게 낸다 — 어느 레인이 집행되든 이 파일의 단언은 요청 본문에만 걸린다.
        local body = Dict{String,Any}(
            "dspy" => Dict{String,Any}("chosen" => _NOOP_NAME, "ranking" => [_NOOP_NAME],
                                       "margin" => 0.1, "rationale" => "fake",
                                       "policy" => "dspy:test", "unsupported" => String[]),
            "surrogate" => Dict{String,Any}("chosen" => _NOOP_NAME, "ranking" => [_NOOP_NAME],
                                            "margin" => 0.1, "rationale" => "fake",
                                            "policy" => "surrogate:test",
                                            "scores" => Dict(_NOOP_NAME => 1.0),
                                            "unsupported" => String[]))
        return HTTP.Response(200, JSON3.write(body))
    end
    return HTTP.Response(404, "")
end
const _PORT = HTTP.Servers.port(_SERVER)

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

# 🔴 매크로 이름 리터럴을 쓰지 않는다(`test/policy_macro_binding.jl:134` 의 규칙) — 레지스트리
#    에서 유도한다. 위 서버 클로저는 **호출 시점에** 이 전역을 읽으므로 정의 순서는 무관하다.
const _NOOP_NAME = ActionRegistry.NAME[0]

const TENV = try
    CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr",
                       project_name = "tool_choice_gate",
                       num_robots = 4, assignment_mode = :greedy,
                       n_spare_per_pool = 2,
                       open_animation_at_end = false, save_animation = false,
                       write_results = false, return_env_before_sim = true,
                       rng = Random.MersenneTwister(1))
catch
    close(_SERVER)
    rethrow()
end

_truth() = CB.BatteryTruth(CB.RobotID(1), 0.5)

"""
    _detector(mu) -> CB.NoveltyDetector

`mu` 를 중심으로 한 합성 감지기. 교정 **파일** 없이 novelty 축을 켜는 유일한 방법이고,
`install_novelty!()` 가 `novelty_detector() !== nothing` 이면 즉시 `true` 를 내므로
(`policy.jl` 의 그 함수 첫 줄) 이것만으로 `have_det == true` 가 된다.

  · `mu == desc`  -> score 0 -> 모든 cal_score(1.0)가 그보다 크다 -> p ≈ 1 -> **familiar**
  · `mu` 가 멀다  -> score = cap -> cal_score 가 하나도 안 크다 -> p = 0.5/(n+1) -> **novel**

`feature_names` 는 `CB.NOVELTY_FEATURES` 와 **같아야** 하지만(로더가 강제한다) 여기서는
로더를 거치지 않으므로 그 상수를 그대로 쓴다 — 이름을 손으로 적으면 사본이 하나 더 생긴다.
"""
_detector(mu) = CB.NoveltyDetector(copy(CB.NOVELTY_FEATURES), collect(Float64, mu),
                                   fill(1.0, length(mu)), 5.0,
                                   fill(1.0, 99), 0.05, 1e-6,
                                   Dict{String,Any}("synthetic" => true))

const _PREV_DET = CB.novelty_detector()

try
    @testset "라우터 게이팅 tool_choice" begin

    @testset "(0) 전제 — 이 게이트가 실제로 서비스를 부르는 설정인가" begin
        # `decide_all` 의 삼항식은 세 조건이 모두 참이면 `service_decide` 를 통째로 건너뛴다.
        # 그러면 (3) 이 "요청이 아예 없었다" 로 빨개지므로 원인을 여기서 직접 이름 붙인다.
        @test !(POLICY in ("canonical", "noop", "oracle") && !router_drives() &&
                get(ENV, "DEMO_ALL_POLICIES", "1") == "0")
        # 이 워킹트리의 전제: 교정 파일이 **없다**. 있으면 (3-a) 가 다른 것을 재게 된다.
        @test CB.novelty_detector() === nothing
    end

    # -----------------------------------------------------------------------------------------
    @testset "(1) tool_choice_for 진리표 — 3상태 전수" begin
        # 🔴 세 상태다. 둘로 접으면(예: `!novel` 하나로) "못 쟀다" 가 "익숙하다" 로 새고,
        #    교정이 없는 이 작업 트리에서 **모든 사건이 강제된다.**
        # ① 못 쟀다 -> 강제하지 않는다. `novel` 값과 무관하다(둘 다 친다).
        @test tool_choice_for(novelty_measured = false, novel = false) === nothing
        @test tool_choice_for(novelty_measured = false, novel = true)  === nothing
        # ② 재서 낯설다 -> 강제하지 않는다. 합성 레인(T2)의 유일한 방아쇠가
        #    `expressible == false` 인데, 강제는 그 필드를 비운다.
        @test tool_choice_for(novelty_measured = true, novel = true)   === nothing
        # ③ 재서 익숙하다 -> **여기서만** 강제한다.
        @test tool_choice_for(novelty_measured = true, novel = false)  == "required"
        # 타입까지 본다: `nothing` 이지 `""` 가 아니다(빈 문자열은 payload 에 키를 싣는다).
        @test tool_choice_for(novelty_measured = false, novel = false) !== ""
        @test tool_choice_for(novelty_measured = true, novel = false) isa String
        # 진리표가 **상수가 아니다**: 네 조합이 두 값을 다 낸다.
        @test length(unique([tool_choice_for(novelty_measured = m, novel = n)
                             for m in (false, true), n in (false, true)])) == 2
    end

    # -----------------------------------------------------------------------------------------
    @testset "(2) route_verdict 의 novelty_measured — 세 분기 전부" begin
        local DESC = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6]
        # (a) 교정 JSON 이 없다 = **못 쟀다**.
        #     🔴 변이: 이 분기의 `false` 를 `true` 로 바꾸면 여기가 빨개진다.
        local a = route_verdict(desc = DESC, have_det = false, drives = false, policy = "canonical")
        @test haskey(a, "novelty_measured")
        @test a["novelty_measured"] === false
        @test a["novel"] === false          # 🔴 `novel` 의 값은 안 바뀐다
        # 그리고 그 조합이 `tool_choice_for` 에서 "강제하지 않는다" 로 떨어진다.
        @test tool_choice_for(novelty_measured = a["novelty_measured"], novel = a["novel"]) === nothing

        # (b) descriptors 가 없다(= `v === nothing`) = **못 쟀다**.
        local b = route_verdict(desc = nothing, have_det = true, drives = true, policy = "canonical")
        @test b["novelty_measured"] === false
        @test b["novel"] === false
        @test tool_choice_for(novelty_measured = b["novelty_measured"], novel = b["novel"]) === nothing

        # (c) 실제 판정 — `v` 를 주입해 만든다. 여기서만 `true` 다.
        local c_fam = route_verdict(desc = DESC, have_det = true, drives = true, policy = "canonical",
                                    v = (novel = false, p = 0.9, score = 0.1), eps = 0.05)
        @test c_fam["novelty_measured"] === true
        @test c_fam["novel"] === false
        @test tool_choice_for(novelty_measured = c_fam["novelty_measured"],
                              novel = c_fam["novel"]) == "required"

        local c_nov = route_verdict(desc = DESC, have_det = true, drives = true, policy = "canonical",
                                    v = (novel = true, p = 0.01, score = 2.0), eps = 0.05)
        @test c_nov["novelty_measured"] === true
        @test c_nov["novel"] === true
        @test tool_choice_for(novelty_measured = c_nov["novelty_measured"],
                              novel = c_nov["novel"]) === nothing

        # 🔴 두 키가 **다른 것을 주장한다**: (a)/(b) 와 (c_fam) 은 `novel` 이 같은데
        #    `novelty_measured` 가 갈린다. 이 줄이 곧 이 태스크의 함정 자체다 — 붕괴가
        #    살아 있으면 세 사건이 여기서 같은 값을 낸다.
        @test a["novel"] == b["novel"] == c_fam["novel"] == false
        @test a["novelty_measured"] == b["novelty_measured"] == false
        @test c_fam["novelty_measured"] == true
    end

    # -----------------------------------------------------------------------------------------
    @testset "(3) 배선이 아니라 발화 — decide_all 이 낸 **진짜 요청 본문**" begin
        # (3-a) 교정이 없는 기본 작업 트리: 키가 **아예 없다** = 2026-08-29 이전과 바이트 동일.
        CB.clear_novelty_detector!()
        _LAST_PAYLOAD[] = nothing
        local n0 = _N_DECIDE[]
        decide_all(TENV, _truth(); nl = "")
        @test _N_DECIDE[] == n0 + 1          # 전제: 요청이 실제로 나갔다
        @test _LAST_PAYLOAD[] !== nothing
        @test !haskey(_LAST_PAYLOAD[], :tool_choice)

        # (3-b) novelty 축을 **실제로 재게** 만든다: 이 사건의 서술자를 중심으로 한 감지기 =
        #       familiar. 이 분기에서만 `"required"` 가 실린다.
        local desc = event_descriptors_of(TENV, _truth())
        CB.set_novelty_detector!(_detector(desc))
        try
            # 전제: 정말로 재서 익숙하다고 나왔는가. 아니면 아래 단언은 다른 것을 잰다.
            local rt = route(TENV, _truth())
            @test rt["novelty_measured"] === true
            @test rt["novel"] === false
            _LAST_PAYLOAD[] = nothing
            decide_all(TENV, _truth(); nl = "")
            @test _LAST_PAYLOAD[] !== nothing
            @test haskey(_LAST_PAYLOAD[], :tool_choice)
            @test String(_LAST_PAYLOAD[][:tool_choice]) == "required"
        finally
            CB.clear_novelty_detector!()
        end

        # (3-c) 같은 배선이 **낯선** 사건에서는 안 싣는다 = (3-b) 의 값이 상수가 아니다.
        #       `mu` 를 서술자에서 멀리 떼면 z 가 cap 에 붙어 p 가 바닥이다.
        CB.set_novelty_detector!(_detector(desc .+ 50.0))
        try
            local rt = route(TENV, _truth())
            @test rt["novelty_measured"] === true
            @test rt["novel"] === true
            _LAST_PAYLOAD[] = nothing
            decide_all(TENV, _truth(); nl = "")
            @test _LAST_PAYLOAD[] !== nothing
            @test !haskey(_LAST_PAYLOAD[], :tool_choice)
        finally
            CB.clear_novelty_detector!()
        end
    end

    # -----------------------------------------------------------------------------------------
    @testset "(4) service_decide 의 payload 줄 — agents/zones 와 같은 규약" begin
        # 🔴 이 절은 `decide_all` 을 **거치지 않고** 그 줄만 직접 태운다. (3) 은 유도까지
        #    포함한 사슬 전체를, 여기는 실을지 말지의 규약 하나를 잰다.
        _LAST_PAYLOAD[] = nothing
        service_decide(TENV, _truth())
        @test _LAST_PAYLOAD[] !== nothing
        @test !haskey(_LAST_PAYLOAD[], :tool_choice)   # 기본값 nothing = 안 싣는다

        _LAST_PAYLOAD[] = nothing
        service_decide(TENV, _truth(); tool_choice = "required")
        @test haskey(_LAST_PAYLOAD[], :tool_choice)
        @test String(_LAST_PAYLOAD[][:tool_choice]) == "required"

        # 다른 값도 그대로 나른다 — 이 층은 값을 해석하지 않는다(해석은 서비스의 몫).
        _LAST_PAYLOAD[] = nothing
        service_decide(TENV, _truth(); tool_choice = "auto")
        @test String(_LAST_PAYLOAD[][:tool_choice]) == "auto"

        # 나머지 채널은 그대로다 — 이 kwarg 가 기존 payload 를 건드리지 않는다.
        @test haskey(_LAST_PAYLOAD[], :nl_mode)
    end

    end # testset
finally
    close(_SERVER)
    # ⚠️ 전역 복원. 이 파일이 설치한 합성 감지기를 남기면 뒤따르는 게이트가 다른 세계를 본다.
    _PREV_DET === nothing ? CB.clear_novelty_detector!() : CB.set_novelty_detector!(_PREV_DET)
end

end # module
