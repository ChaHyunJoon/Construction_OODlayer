# =============================================================================
# test/ood_truth_keys.jl — Task 6 게이트: grounding 키가 **남은 두 사건**에 맞는가
#   julia +lts --project=. test/ood_truth_keys.jl
#
# 축 C(3팔 축소) 이후 채점 가능한 사건은 fault·battery 둘뿐이다. 그런데 `emitted_key` 에는
# `SwapBattery` 분기가 없었다 — Task 5 가 `DeprioritizeAgent` 를 지우고 나면 battery 가 낼 수
# 있는 유일한 팔이 키를 못 만들어 **battery grounding 이 구조적으로 0** 이 된다(에러 없이).
#
# 🔴 `CB.include` 한 줄이 필수다. `emitted_key`·`truth_key`·`BatteryTruth`·`canonical_respec`
# 는 `src/navigator/` 에 살고 `src/ConstructionBots.jl` 은 navigator 를 **한 번도 include 하지
# 않는다** — 그냥 `using ConstructionBots` 만 하면 이 파일은 UndefVarError 로 죽는다.
# 관례는 `test/respec_action_space.jl:24` · `test/navigator_comparison_smoke.jl:37` ·
# `test/smdp_stamp_smoke.jl:10` 이 이미 쓰고 있는 그 한 줄이다.
# =============================================================================
using Test
using ConstructionBots
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))

# 삭제된 `DeprioritizeAgent` 자리를 재는 목(mock). 필드 이름은 옛 타입과 같게 둔다.
struct DeprioritizeAgent
    agent
end

@testset "grounding 키 — fault·battery 둘 다 정의된다 (spec §5.5)" begin
    rid = CB.RobotID(3)

    # 하드 고장 취급
    @test CB.emitted_key(CB.ReplaceAgent(rid, 0.0)) == (:fault, rid)

    # 배터리: SwapBattery 가 키를 만들어야 한다 — 이 분기가 없으면 battery recall 이 항상 0
    @test CB.emitted_key(CB.SwapBattery(rid)) == (:battery, rid)

    # truth 쪽: severity 와 무관하게 같은 키 (canonical_respec 의 통합과 일치)
    @test CB.truth_key(CB.BatteryTruth(rid, 0.02)) == (:battery, rid)
    @test CB.truth_key(CB.BatteryTruth(rid, 0.45)) == (:battery, rid)
    @test CB.truth_key(CB.FaultTruth(rid, [1.0, 2.0], 0.0)) == (:fault, rid)

    # canonical 대응이 실제로 그 키를 낸다 (채점기 ↔ 기준정책 일치)
    @test CB.emitted_key(first(CB.canonical_respec(CB.BatteryTruth(rid, 0.02)).constraints)) ==
          (:battery, rid)
end

@testset "빠진 사건 종류는 키를 만들지 않는다 (spec §5.1·§5.4)" begin
    rid = CB.RobotID(3)

    # zone: `ForbidZone` 분기가 곧 "구역 사건의 정답은 ForbidZone 이다" 라는 채점 규칙이었다.
    # zone 은 Task 4 로 결정 레인에서 빠졌으므로 그 규칙도 없어야 한다.
    @test CB.emitted_key(CB.ForbidZone(CB.AssemblyID(1), :zone_a)) === nothing

    # `emitted_key` 는 타입 **이름**으로 덕타이핑한다. 그래서 삭제된 `DeprioritizeAgent` 는
    # 타입이 없어졌어도 같은 이름의 목(mock)으로 분기 잔존 여부를 잴 수 있다.
    @test CB.emitted_key(DeprioritizeAgent(rid)) === nothing

    # truth 쪽 zone 키는 **남긴다** — 옛 요약 행을 다시 읽을 때 키가 없으면 그 행이 조용히
    # 사라진다. emit 쪽이 없으므로 채점에서는 자동으로 missed 로 잡힌다.
    @test CB.truth_key(CB.ZoneTruth(:zone_a, [0.0, 0.0], 1.0)) == (:zone, :zone_a)
end
