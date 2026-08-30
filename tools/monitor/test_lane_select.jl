# tools/monitor/test_lane_select.jl
# kind 색인 분기표 전수 검사 (2026-08-29, T11). 순수 함수라 즉시 끝난다.
#
# 실행: julia +lts --project=. tools/monitor/test_lane_select.jl
using Test
include(joinpath(@__DIR__, "lane_select.jl"))

# 🔴 2026-08-29 (T11): 옛 3-way 분기(`novel`·`available`·`supported`) testset 여섯을
#    **지웠다** — `select_lane` 의 시그니처가 kind 색인으로 바뀌어 남기면 컴파일이 안 된다.
#    주석 처리하거나 `@test_skip` 으로 남기지 않는다(이 레포가 반복해 데인 자리다).
#    지워진 것: "3-way 분기" · "noop 은 라우팅 대상이 아니다" · "DP 는 절대 타깃이 아니다" ·
#    "reason 은 언제나 비지 않는다" · "어휘 미달이 novelty 보다 먼저다".
#    그중 살아남은 명제 셋(noop 은 통제 바닥선 · DP 는 타깃이 아니다 · reason 은 안 빈다)은
#    아래 새 분기표가 다시 잰다. 나머지 둘(축 1·축 2)은 **축 자체가 사라져** 소멸했다(§0-C ⑤).

const KNOWN = Set(["battery", "fault"])

@testset "kind 색인 분기표 (전수)" begin
    @test select_lane(kind="battery", known_kinds=KNOWN, policy="router").lane == "surrogate"
    @test select_lane(kind="fault",   known_kinds=KNOWN, policy="router").lane == "surrogate"
    @test select_lane(kind="zone",    known_kinds=KNOWN, policy="router").lane == "dspy"
    # 🔴 §0-C 충돌 ① — 처음 보는 타입은 LLM 으로 간다. `routing_kind` 가 `"fault"` 로 접었다면
    #    이 줄이 `"surrogate"` 를 내고, 가장 OOD 한 사건이 가장 확신에 찬 레인으로 간다.
    @test select_lane(kind="unknown:MeteorTruth", known_kinds=KNOWN, policy="router").lane == "dspy"

    # 축이 데이터로 남는다 — 산문에서 역파싱하지 않는다.
    @test select_lane(kind="zone",    known_kinds=KNOWN, policy="router").axis == "ood_kind"
    @test select_lane(kind="battery", known_kinds=KNOWN, policy="router").axis == "known_kind"

    # noop 은 통제 바닥선 — 라우팅 대상이 아니다(옛 분기표에서 그대로 살아남는 유일한 규칙).
    @test select_lane(kind="zone", known_kinds=KNOWN, policy="noop").lane == "noop"
    @test select_lane(kind="zone", known_kinds=KNOWN, policy="noop").axis == "control"

    # 🔴 **못 쟀으면 안 고른다.** `/health` 의 `surro_kinds` 가 null 이거나 서비스가 없을 때다.
    #    조용히 한쪽으로 떨어지면 "라우팅했다" 는 주장이 근거 없이 산출물에 남는다.
    @test_throws Exception select_lane(kind="battery", known_kinds=nothing, policy="router")
    # ⚠️ 통제 바닥선은 그 앞에서 되돌아가므로 못 쟀어도 안 죽는다 — 판정 자체를 안 하기 때문.
    @test select_lane(kind="battery", known_kinds=nothing, policy="noop").lane == "noop"

    # 쟀는데 비었다(`[]`)는 "못 쟀다" 와 **다른 사건**이다 — 전부 dspy 로 간다(죽지 않는다).
    @test select_lane(kind="battery", known_kinds=Set(String[]), policy="router").lane == "dspy"

    # DP 는 절대 타깃이 아니다 (Global Constraint 10).
    for k in ("battery", "fault", "zone", "unknown:X")
        local r = select_lane(kind=k, known_kinds=KNOWN, policy="router")
        @test r.lane != "dp"
        @test !isempty(r.reason)            # reason 은 언제나 비지 않는다
        @test r.axis in ("control", "known_kind", "ood_kind")
    end
end

# ---- 2026-08-29 (T8, kind 색인 라우터) ------------------------------------------------------
@testset "routing_kind 는 전총이고, 모르는 타입을 fault 로 접지 않는다" begin
    @test routing_kind("BatteryTruth") == "battery"
    @test routing_kind("FaultTruth")   == "fault"
    @test routing_kind("ZoneTruth")    == "zone"
    # 🔴 이 단언 하나가 §0-C 충돌 ①의 전부를 진다. `"fault"` 가 나오면 빨갛다.
    @test routing_kind("MeteorTruth")  == "unknown:MeteorTruth"
    @test startswith(routing_kind("MeteorTruth"), "unknown:")
    # 전총: 무엇을 넣어도 던지지 않는다.
    for n in ("", "X", "Truth", "battery")
        @test routing_kind(n) isa String
    end
end
