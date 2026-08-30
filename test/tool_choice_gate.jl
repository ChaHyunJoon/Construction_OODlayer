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
#      🔴 **2026-08-29 (단일 채널 / T6) 에 이 절의 명제가 뒤집혔다.** 옛 명제는 "familiar
#      사건에서만 `"required"` 가 실린다" 였다. T6 이 `service_decide` 의 키워드와 `decide_all`
#      의 유도 호출부를 지웠으므로 지금 참인 것은 **"세 novelty 상태 전부에서 그 키가 요청에
#      없다"** 이고, 그것은 강제하지 않는다는 뜻이 **아니다** — T5 가 서비스 기본값을
#      `"required"` 로 세웠으므로 안 싣는 것이 곧 강제다. 즉 (3) 이 재는 것은
#      **게이팅이 죽었다는 사실**이다.
#      (합성 감지기 = `CB.set_novelty_detector!` 로 직접 설치한다. `install_novelty!()` 는
#       감지기가 이미 있으면 즉시 `true` 를 돌려주므로 교정 **파일**이 필요 없다.)
#  (4) `service_decide` 가 `tool_choice` 를 **받지도 싣지도 않는다** — 키워드의 부재를
#      `MethodError` 로 못박는다(T6 이 지웠다).
#  (5) 단일 채널 키 집합: `text_rescue` 가 빠지고 `decision_source` · `tool_arg_error` 가
#      들어왔고, 폴백 dict 이 같은 집합을 낸다(T6).
#
# 🔴 **(1)절의 초록을 "강제가 게이팅된다" 의 증거로 인용하지 말 것.** 그 절은 순수 함수의
# 반환값만 재고 그 **효과**는 안 잰다. 효과를 재는 것은 (3)·(4) 이고, 둘 다 T6 뒤에는
# **게이팅이 작동하지 않는다**를 못박는다. (§0-B ⑦ 과 같은 종류의 함정 — 소스만 읽는 게이트
# 셋이 `macro()` 가 매 호출 NameError 로 죽는 동안에도 초록이었던 그 자리다.)
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
        # 🔴 2026-08-29 (T11): `surro_kinds` 를 **반드시** 싣는다. 없으면 `dspy_ready()` 가
        #    `SURRO_KINDS[] = nothing`("못 쟀다")로 캐시하고 `select_lane` 이 그 사건에서
        #    **죽는다** — 그것이 §0-C 결정 3 의 설계된 동작이므로 이 픽스처를 안 고치면
        #    (3)절이 "라우터가 못 쟀다" 로 정당하게 빨개진다(실측: 그렇게 빨갰다).
        #    값은 서비스의 실측 기준값(`oracle_dataset.jsonl` 33행)과 같다.
        return HTTP.Response(200, "{\"status\":\"ok\",\"surro_kinds\":[\"battery\",\"fault\"]}")
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
        # (3-a) 의 전제: 이 시점에 감지기가 **설치돼 있지 않다**.
        # 🔴 여기 있던 *"이 워킹트리의 전제: 교정 파일이 없다"* 는 **거짓이다**(2026-08-29 실측):
        #    `wm4spacecraft_manufacturing/novelty/novelty_calibration.json` 이 존재하고
        #    `install_novelty!()` 가 실제로 로드한다(n_cal=82, alpha=0.05). 이 단언이 참인
        #    이유는 파일의 부재가 아니라 **설치가 게으르기 때문**이다 — `install_novelty!()`
        #    는 `decide_all` 안에서야 불린다. 그래서 (3-a) 는 "교정이 없는 트리" 가 아니라
        #    "이 호출 직전에 감지기를 지웠다" 로 만들어진다(바로 아래 (3) 의 첫 줄).
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
        # 🔴 **2026-08-29 (단일 채널 / T6): 이 절의 주장이 뒤집혔다.**
        #    T-C 판에서 이 절은 *"familiar 사건에서만 `"required"` 가 실린다"* 를 셋으로 갈라
        #    쟀다. T6 이 `service_decide` 의 `tool_choice` 키워드와 `decide_all` 의 유도
        #    호출부를 지웠으므로, 이제 참인 명제는 하나다: **어떤 novelty 상태에서도 요청에
        #    그 키가 없다.**
        #
        #    🔴 그리고 그것은 "강제하지 않는다" 를 뜻하지 **않는다** — 정확히 반대다.
        #    T5 가 서비스의 `TOOL_CHOICE_DEFAULT` 를 `"required"` 로 세웠으므로 키를 안 싣는
        #    것이 곧 **강제**다. 즉 이 절이 재는 것은 "게이팅이 산다" 가 아니라
        #    **"게이팅이 죽었다"** 이고, 세 분기가 실제로 한 값으로 붕괴하는지를 못박는다.
        #    (§0-B ⑯. 이 절 없이 (1)절만 초록이면 순수 함수의 진리표가 살아 있다는 이유로
        #     게이팅이 산다고 오독하게 된다 — 이 레포가 반복해 밟은 함정이다.)
        #
        #    ⚠️ 강제를 실제로 끄는 손잡이는 이 레인에 없다. 서비스 호스트의
        #    `DSPY_TOOL_CHOICE` 하나이고, 실린 값은 **응답**의 `tool_choice` 표식에 남는다.

        # (3-a) novelty 를 못 쟀다.
        CB.clear_novelty_detector!()
        _LAST_PAYLOAD[] = nothing
        local n0 = _N_DECIDE[]
        decide_all(TENV, _truth(); nl = "")
        @test _N_DECIDE[] == n0 + 1          # 전제: 요청이 실제로 나갔다
        @test _LAST_PAYLOAD[] !== nothing
        @test !haskey(_LAST_PAYLOAD[], :tool_choice)

        # (3-b) **익숙하다고 실제로 쟀다** — T-C 판이라면 여기서 `"required"` 가 실렸다.
        local desc = event_descriptors_of(TENV, _truth())
        CB.set_novelty_detector!(_detector(desc))
        try
            # 전제: 정말로 재서 익숙하다고 나왔는가. 아니면 아래 단언은 다른 것을 잰다.
            local rt = route(TENV, _truth())
            @test rt["novelty_measured"] === true
            @test rt["novel"] === false
            # 🔴 대조군: 유도 **함수** 는 여전히 `"required"` 를 낸다 = 아래 단언이
            #    "함수가 죽었다" 가 아니라 **"배선이 죽었다"** 를 잰다는 증거다.
            @test tool_choice_for(novelty_measured = true, novel = false) == "required"
            _LAST_PAYLOAD[] = nothing
            decide_all(TENV, _truth(); nl = "")
            @test _LAST_PAYLOAD[] !== nothing
            @test !haskey(_LAST_PAYLOAD[], :tool_choice)
        finally
            CB.clear_novelty_detector!()
        end

        # (3-c) **낯설다고 실제로 쟀다** — 세 분기가 같은 값으로 붕괴하는 것을 여기서 닫는다.
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
    @testset "(4) service_decide 는 tool_choice 를 **받지도 싣지도 않는다**" begin
        # 🔴 T6 이 그 키워드를 지웠다. 옛 (4)절은 `service_decide(...; tool_choice="required")`
        #    가 payload 에 실리는 것을 쟀는데, 그 인터페이스가 이제 없다.
        #    여기서 재는 것 둘:
        #      ① 기본 호출이 그 키를 안 싣는다(= 서비스 기본값 `"required"` 가 선다).
        #      ② 🔴 **키워드가 실제로 사라졌다.** `MethodError` 를 못박지 않으면, 누가
        #         `tool_choice=` 를 다시 넘기는 코드를 써도 Julia 가 조용히 받아 주는 판
        #         (예: `; kwargs...` 를 나중에 더하는 변경)이 안 잡힌다.
        _LAST_PAYLOAD[] = nothing
        service_decide(TENV, _truth())
        @test _LAST_PAYLOAD[] !== nothing
        @test !haskey(_LAST_PAYLOAD[], :tool_choice)

        @test_throws MethodError service_decide(TENV, _truth(); tool_choice = "required")

        # 나머지 채널은 그대로다 — 이 삭제가 기존 payload 를 건드리지 않는다.
        _LAST_PAYLOAD[] = nothing
        service_decide(TENV, _truth())
        @test haskey(_LAST_PAYLOAD[], :nl_mode)
    end

    # -----------------------------------------------------------------------------------------
    @testset "(5) 단일 채널 키 — T6" begin
        # 🔴 `text_rescue` 는 사라졌다 — 그 동작(2차 호출)이 이 설계에 없다.
        @test !("text_rescue" in TOOL_LANE_KEYS)
        # 🔴 세대 표식이자 실패 사건의 이름.
        @test "decision_source" in TOOL_LANE_KEYS
        @test "tool_arg_error" in TOOL_LANE_KEYS

        # 폴백 dict 도 같은 키 집합을 낸다 — 키가 사라지면 "레인이 안 돌았다" 와 "값이 없다" 를
        # 못 가른다.
        # 🔴 계획서 Step 1 의 `Set(String.(keys(blank)))` 는 **이 harness 에서 틀리다**:
        #    `tool_lane_fields` 는 `Vector{Pair{String,Any}}` 를 내므로 `keys(...)` 가
        #    이름이 아니라 **색인**(`Base.OneTo`)을 낸다 → `String(1)` 이 MethodError.
        #    이름을 얻는 것은 `first.(...)` 다.
        local blank = tool_lane_fields(nothing)
        @test Set(first.(blank)) == Set(TOOL_LANE_KEYS)

        # 실측 응답 모양이 그대로 통과한다.
        local b = (chosen = "SwapBattery", ranking = ["SwapBattery"], margin = nothing,
                   rationale = "clearly better than Replace", decision_source = "tool",
                   tool_called = "deliver_battery", tool_args = Dict("agent" => "r1"),
                   tool_calls_n = 1, tools_offered = 3, expressible = true,
                   native_fc = true, tool_lane_error = nothing, macro_tool_agree = true,
                   tool_choice = "required", tool_arg_error = nothing)
        local e = policy_entry(b, "dspy")
        @test e["available"] === true
        @test e["chosen"] == "SwapBattery"
        @test e["margin"] === nothing          # 🔴 margin 이 없어도 경계가 안 깨진다
        @test e["decision_source"] == "tool"
    end

    # ---- (7) 🔴 교차 게이트: 두 kind 유도가 알려진 셋에서 일치한다 (2026-08-29, T11) --------
    # 이게 없으면 `FaultTruth` 개명 한 번에 `routing_kind` 가 조용히 `"unknown:..."` 을 내고
    # **모든 사건이 dspy 로 간다** — 에러 없이, 비용만 몇 배로. 이름 기반 유도(라우팅)와
    # `isa` 기반 유도(surrogate 피처)는 **일부러 다른 함수**이므로(§0-C 충돌 ①), 둘이 갈리지
    # 않는다는 것을 여기서 못박는 수밖에 없다.
    @testset "(7) routing_kind 와 ood_features 의 kind 가 알려진 셋에서 일치한다" begin
        # ⚠️ 구역이 **실재할 필요가 없다** — 이 절이 재는 것은 두 kind 유도의 일치뿐이고,
        #    둘 다 타입만 본다(`ood_features` 의 zone 분기는 truth.zone 을 안 읽는다).
        local cases = ((CB.BatteryTruth(CB.RobotID(1), 0.5), "battery"),
                       (CB.FaultTruth(CB.RobotID(1), [0.0, 0.0, 0.0]), "fault"),
                       (CB.ZoneTruth(:kind_gate_zone, [0.0, 0.0, 0.0], 1.0), "zone"))
        for (t, expect) in cases
            @test routing_kind(String(nameof(typeof(t)))) == expect
            @test ood_features(TENV, t)["kind"] == expect
        end
        # 🔴 그리고 **갈리는 자리**를 명시적으로 잰다: 모르는 타입에서 두 유도는 **일부러
        #    다르다.** `ood_features` 는 `"fault"`(피처로는 옳다), `routing_kind` 는
        #    `"unknown:..."`(라우팅으로는 그것만 옳다). 이 비대칭이 사라지면 가장 OOD 한
        #    사건이 가장 확신에 찬 레인으로 간다.
        @test routing_kind("MeteorTruth") == "unknown:MeteorTruth"
        @test !(routing_kind("MeteorTruth") in ("fault", "battery", "zone"))
    end

    end # testset
finally
    close(_SERVER)
    # ⚠️ 전역 복원. 이 파일이 설치한 합성 감지기를 남기면 뒤따르는 게이트가 다른 세계를 본다.
    _PREV_DET === nothing ? CB.clear_novelty_detector!() : CB.set_novelty_detector!(_PREV_DET)
end

end # module
