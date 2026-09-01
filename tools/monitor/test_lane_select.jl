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
    # 🔴 2026-08-30: zone 의 kind 는 이제 `"unknown:zone"` 이다(접두사 통일). 옛 `"zone"` 도
    #    같은 레인으로 가지만, 이 줄은 **오늘 라우터가 실제로 보는 값**으로 잰다 — 그러지
    #    않으면 `routing_kind` 가 바뀌어도 이 분기표가 초록인 채로 남는다.
    @test select_lane(kind="unknown:zone", known_kinds=KNOWN, policy="router").lane == "dspy"
    @test select_lane(kind="unknown:battery_mild", known_kinds=KNOWN, policy="router").lane == "dspy"
    # 🔴 §0-C 충돌 ① — 처음 보는 타입은 LLM 으로 간다. `routing_kind` 가 `"fault"` 로 접었다면
    #    이 줄이 `"surrogate"` 를 내고, 가장 OOD 한 사건이 가장 확신에 찬 레인으로 간다.
    @test select_lane(kind="unknown:MeteorTruth", known_kinds=KNOWN, policy="router").lane == "dspy"

    # 축이 데이터로 남는다 — 산문에서 역파싱하지 않는다.
    @test select_lane(kind="unknown:zone", known_kinds=KNOWN, policy="router").axis == "ood_kind"
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
    @test routing_kind("BatteryTruth", 0.05) == "battery"
    @test routing_kind("FaultTruth")   == "fault"
    @test routing_kind("ZoneTruth")    == "unknown:zone"
    # 🔴 이 단언 하나가 §0-C 충돌 ①의 전부를 진다. `"fault"` 가 나오면 빨갛다.
    @test routing_kind("MeteorTruth")  == "unknown:MeteorTruth"
    @test startswith(routing_kind("MeteorTruth"), "unknown:")
    # 전총: 무엇을 넣어도 던지지 않는다. (심각도 인자 유무 둘 다.)
    for n in ("", "X", "Truth", "battery")
        @test routing_kind(n) isa String
        @test routing_kind(n, 0.5) isa String
    end
end

# ---- 2026-08-30 (사용자 결정: LLM 레인 표식을 `"unknown:"` 하나로 통일) ----------------------
@testset "LLM 으로 가는 모든 kind 가 `unknown:` 접두사를 진다" begin
    # 🔴 이것이 그 결정의 전부다. 접두사가 곧 라우팅 표식이고, `dspy_service._unfamiliar_block`
    #    도 같은 접두사만 본다 — 그래서 이 단언이 깨지면 그 사건은 LLM 으로는 가면서
    #    프롬프트에는 "처음 보는 사건" 이라는 사실이 한 글자도 안 실린다(2026-08-30 이전의 zone).
    for k in (routing_kind("ZoneTruth"),
              routing_kind("BatteryTruth", 0.55),
              routing_kind("BatteryTruth", nothing),
              routing_kind("MeteorTruth"))
        @test startswith(k, "unknown:")
        @test select_lane(kind=k, known_kinds=KNOWN, policy="router").lane == "dspy"
    end
    # 음성 대조: known 레인으로 가는 둘은 접두사를 **안** 진다.
    for k in (routing_kind("FaultTruth"), routing_kind("BatteryTruth", 0.05))
        @test !startswith(k, "unknown:")
        @test select_lane(kind=k, known_kinds=KNOWN, policy="router").lane == "surrogate"
    end
end

@testset "battery 심각도 분할 (ROUTING_SEVERE_SOC)" begin
    @test ROUTING_SEVERE_SOC == 0.1          # 값이 바뀌면 아래 전부를 다시 판정해야 한다

    # 경계 자체. `<=` 다 — 경계값은 severe 쪽이다.
    @test routing_kind("BatteryTruth", ROUTING_SEVERE_SOC)        == "battery"
    @test routing_kind("BatteryTruth", ROUTING_SEVERE_SOC + 1e-9) == "unknown:battery_mild"
    @test routing_kind("BatteryTruth", 0.0)                       == "battery"

    # 🔴 **severe 데모가 known 쪽에 떨어지는가.** `inject_battery_fault!` 는
    #    `soc_after = max(floor_soc=0.0, soc_at_fire - soc_drop)` 이고, 2026-08-31 부터 이
    #    데모의 값은 `DEMO_BSOC=0.96` 이다(옛 0.9 는 정지 임계가 0.05 로 내려가면서 여유가
    #    6e-4 로 얇아져 "확실히 정지한다"는 논증이 깨졌었다 — task-3-report.md, `lane_select.jl`
    #    ROUTING_SEVERE_SOC 주석 참고).
    #    최악의 경우(만충 1.0)를 여기서 그대로 계산한다 — 손으로 "≈0.04" 라고 적어 두면
    #    부동소수점이 어느 쪽으로 떨어지는지 아무도 모른다(1.0-0.96 = 0.040000000000000036).
    for soc_at_fire in (1.0, 0.999, 0.95, 0.9)
        @test routing_kind("BatteryTruth", max(0.0, soc_at_fire - 0.96)) == "battery"
    end
    # mild 데모(DEMO_BSOC=0.45)는 반대쪽이다.
    for soc_at_fire in (1.0, 0.999, 0.95)
        @test routing_kind("BatteryTruth", max(0.0, soc_at_fire - 0.45)) == "unknown:battery_mild"
    end

    # ⚠️ **대가를 시험이 직접 진술한다** (2026-08-30). 오라클 학습셋의 battery SoC 사다리는
    #    `{0.02, 0.30, 0.50}` 이고, 이 경계에서 **뒤의 두 칸이 OOD 로 라우팅된다.**
    #    surrogate 가 그 구간에서 매크로 3종 라벨을 전부 가진 채로. 이것은 결함이 아니라
    #    사용자가 근거를 보고 고른 것이며, 여기 적어 두는 이유는 이 줄이 빨개지는 날이
    #    곧 "라벨셋을 severe 구간으로 다시 만들었다" 는 뜻이어야 하기 때문이다.
    @test routing_kind("BatteryTruth", 0.02) == "battery"
    @test routing_kind("BatteryTruth", 0.30) == "unknown:battery_mild"
    @test routing_kind("BatteryTruth", 0.50) == "unknown:battery_mild"

    # 🔴 "못 쟀다" 는 "완만하다" 와 **다른 값**이다 — 뭉개면 계측 실패가 완만함으로 집계된다.
    @test routing_kind("BatteryTruth", nothing) == "unknown:battery_unmeasured"
    @test routing_kind("BatteryTruth")          == "unknown:battery_unmeasured"
    @test routing_kind("BatteryTruth", NaN)     == "unknown:battery_unmeasured"
    @test routing_kind("BatteryTruth", Inf)     == "unknown:battery_unmeasured"
    @test routing_kind("BatteryTruth", "0.05")  == "unknown:battery_unmeasured"
    # 🔴 그리고 **절대 `"battery"` 로 떨어지지 않는다** — 못 쟀는데 아는 kind 라고 주장하면
    #    그 사건이 근거 없이 surrogate 로 간다.
    for bad in (nothing, NaN, Inf, "0.05", missing)
        @test routing_kind("BatteryTruth", bad) != "battery"
    end

    # 심각도는 battery 에만 걸린다 — 다른 타입은 그 인자를 무시한다.
    @test routing_kind("FaultTruth", 0.9)  == "fault"
    @test routing_kind("ZoneTruth",  0.02) == "unknown:zone"
end
