# =============================================================================
# 합성 레인 키의 경계 게이트. (2026-08-30, T1)
#
# 재는 명제 하나: **파이썬이 `# ---- 합성 레인` 표식 아래에 싣는 키 집합과 줄리아의
# `SYNTH_LANE_KEYS` 가 같다.**
#
# 🔴 왜 `tool_lane_keys_survive.jl` 에 안 얹는가. 그 파일 (6)절은 파이썬의
#    `# ---- tool 레인` 표식 **아래** 집합을 `TOOL_LANE_KEYS` 와 양방향 등호로 본다.
#    합성 키는 그 표식 **위**에 있다(`dspy_service.py` 의 `# ---- 합성 레인` 블록).
#    한 튜플에 섞으면 그 게이트가 정당하게 빨개진다.
#
# 🔴 **아홉이다, 여덟이 아니다** (2026-08-30 정정). 최초 계획서는 `params` 를 빠뜨렸다 —
#    그 값이 없으면 T3/T4 의 인터프리터가 신설 도구 원시연산에 넘길 키워드 인자를 못 받는다.
#    서비스는 성공 경로에서 `params` 를 이미 `synthesis` dict 안에 싣고 있다(실측).
#
# 🔴 이 파일은 `using ConstructionBots` 없이 `policy.jl` 을 **standalone** include 한다
#    (실측: `policy.jl` 의 load-time 작업은 `import HTTP, JSON3` · 세 sibling include ·
#    ENV 읽기뿐이라 패키지 로드가 필요 없다). 게이트가 `tool_lane_keys_survive.jl` 처럼
#    루프백 HTTP 서버를 띄우지 않는 것도 그 때문이다 — `policy_entry` 를 손으로 만든
#    JSON3 픽스처로 직접 부른다. 8077/8079 로 나가는 요청 0건 = 유료 호출 0건.
#
# 변이시험 (실패하는 것을 실제로 볼 것)
#   · `SYNTH_LANE_KEYS` 에서 "tool_minted" 를 지우면 (1) 이 빨개진다.
#   · `policy_entry` 의 성공 분기에서 합성 dict 조립을 지우면 (2) 가 빨개진다.
#   · `policy_entry` 의 실패 분기에서 지우면 (3) 이 빨개진다.
#   · `params` 를 `SYNTH_LANE_KEYS` 에서 지우면 (1)·(2) 가 함께 빨개진다.
# =============================================================================
module SynthLaneKeysSurvive

using Test
import JSON3
include(joinpath(@__DIR__, "..", "tools", "monitor", "policy.jl"))

@testset "SYNTH_LANE_KEYS 의 내용" begin
    # (1) 이 계획이 나르기로 한 아홉. 리터럴로 못박는다 — 이 목록이 계약이다.
    @test Set(SYNTH_LANE_KEYS) == Set(["tool_minted", "synthesis_event", "synthesis_ran",
                                       "synthesis_error", "tool_name", "body_names",
                                       "reach", "missing_primitive", "params"])
end

@testset "성공 분기가 아홉을 전부 나른다" begin
    # 서비스 응답을 흉내낸 dict. `policy_entry` 는 `b` 를 **Symbol 키**로 읽는다
    # (`get(b, :error, nothing)` 등) — 실제 응답은 JSON3.Object 이지 Dict{String,Any} 가
    # 아니다. Dict{String,Any} 픽스처를 그대로 넘기면 모든 Symbol 조회가 미스해
    # available=false·chosen="" 인 **실패 분기**를 조용히 태우게 된다(브리프의 결함).
    # 그래서 JSON3.write → JSON3.read 왕복으로 실제와 같은 타입을 만든다.
    fake = JSON3.read(JSON3.write(Dict{String,Any}(
        "chosen" => "NOOP", "ranking" => ["NOOP"], "margin" => nothing,
        "rationale" => "r", "policy" => "dspy:gpt-4o", "coerced" => false, "error" => nothing,
        "tool_minted" => true,
        "synthesis" => Dict{String,Any}(
            "synthesis_event" => true, "ran" => true, "error" => nothing,
            "tool_name" => "clear_zone_and_resume",
            "body_names" => ["restage_all_blocked", "translate_whole_build"],
            "reach" => "composed", "missing_primitive" => nothing,
            "params" => Dict{String,Any}("threshold" => 0.3, "zone" => "A")))))
    e = policy_entry(fake, "dspy")
    # 성공 분기가 실제로 태워졌는지 먼저 확인한다 — 그렇지 않으면 아래 아홉 키 단언은
    # "실패 분기가 우연히 값을 갖는다" 는 것을 재는 것일 수 있다.
    @test e["available"] === true
    @test e["chosen"] == "NOOP"
    # 아홉 키가 전부 있고, 값이 응답에서 온 그대로다.
    @test e["tool_minted"] === true
    @test e["synthesis_event"] === true
    @test e["synthesis_ran"] === true
    @test e["synthesis_error"] === nothing
    @test e["tool_name"] == "clear_zone_and_resume"
    @test e["body_names"] == ["restage_all_blocked", "translate_whole_build"]
    @test e["reach"] == "composed"
    @test e["missing_primitive"] === nothing
    @test e["params"]["threshold"] == 0.3
    @test e["params"]["zone"] == "A"
end

@testset "실패 분기도 아홉을 나른다 — 값은 nothing 이다" begin
    # 🔴 키를 빼지 않는다. 키가 사라지면 소비자가 "레인이 안 돌았다" 와 "값이 없다" 를
    #     못 가른다 — `margin` 에서 이미 세운 규약이다.
    e = policy_entry(nothing, "dspy")
    @test e["available"] === false
    for k in SYNTH_LANE_KEYS
        @test haskey(e, k)
        @test e[k] === nothing
    end
end

@testset "합성 dict 이 없어도 죽지 않는다" begin
    # 낡은 서비스(합성 레인 이전 세대)가 응답할 수 있다. 그 사실을 nothing 으로 적는다.
    fake = JSON3.read(JSON3.write(Dict{String,Any}(
        "chosen" => "NOOP", "ranking" => ["NOOP"], "margin" => nothing,
        "rationale" => "r", "policy" => "p", "coerced" => false, "error" => nothing)))
    e = policy_entry(fake, "dspy")
    @test e["available"] === true
    @test e["tool_minted"] === nothing
    @test e["reach"] === nothing
    @test e["params"] === nothing
end

@testset "합성 dict 은 있는데 상세 여덟이 없다 — 흔한 실행 경로" begin
    # `maybe_synthesize` 의 다섯 탈출 경로 중 성공("minted") 경로만 상세를 전부 채운다.
    # 이것은 예외가 아니라 **흔한** 모양이다 — `synthesis_event`/`synthesis_ran`/
    # `synthesis_error` 만 있고 나머지는 없는 사건.
    fake = JSON3.read(JSON3.write(Dict{String,Any}(
        "chosen" => "NOOP", "ranking" => ["NOOP"], "margin" => nothing,
        "rationale" => "r", "policy" => "dspy", "coerced" => false, "error" => nothing,
        "tool_minted" => false,
        "synthesis" => Dict{String,Any}(
            "synthesis_event" => true, "ran" => false, "error" => "no_missing_primitive"))))
    e = policy_entry(fake, "dspy")
    @test e["available"] === true
    @test e["tool_minted"] === false
    @test e["synthesis_event"] === true
    @test e["synthesis_ran"] === false
    @test e["synthesis_error"] == "no_missing_primitive"
    @test e["tool_name"] === nothing
    @test e["body_names"] === nothing
    @test e["reach"] === nothing
    @test e["missing_primitive"] === nothing
    @test e["params"] === nothing
end

end # module
