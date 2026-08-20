# test/smdp_global_inventory.jl
# spec §3.6 — 스냅샷 대상 전역의 전수 목록을 **기계로** 지킨다.
#
# 왜 테스트여야 하는가: 표로만 두면 새 전역이 생겼을 때 아무것도 안 잡는다. snapshot/restore!
# 가 그 전역을 모르면 롤아웃마다 조용히 오염된다 — 에러가 아니라 **결과의 미세한 차이**로만
# 새는 실패 모양이라 사후에 못 찾는다(spec §3.5 규칙 3).
#
# 범위(controller-addendum.md 태스크 7, I12 + 2026-08-20 fix round 1): `scan_globals` 는
# `src/` 를 재귀로 훑고, 거기에 `tools/monitor/run_demo.jl` · `policy.jl` · `zone_inject.jl` 을
# `extra_files` 로 **의도적으로** 얹는다 — run_demo.jl 이 policy.jl 을 직접 include 하므로
# (`:240`) 셋 다 같은 실행 레인이다. `tools/` 의 나머지·`wm4spacecraft_manufacturing/*.jl`·
# `test/*.jl` 은 **의도적으로 범위 밖**이다(state_globals.jl 헤더에 근거를 적어 뒀다).
#
#   julia +lts --project=. test/smdp_global_inventory.jl
using ConstructionBots
using Test
const CB = ConstructionBots

CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

const SRC = normpath(joinpath(@__DIR__, "..", "src"))
const RUN_DEMO_JL   = normpath(joinpath(@__DIR__, "..", "tools", "monitor", "run_demo.jl"))
const POLICY_JL     = normpath(joinpath(@__DIR__, "..", "tools", "monitor", "policy.jl"))
const ZONE_INJECT_JL = normpath(joinpath(@__DIR__, "..", "tools", "monitor", "zone_inject.jl"))
const EXTRA_FILES = [RUN_DEMO_JL, POLICY_JL, ZONE_INJECT_JL]

@testset "스캐너가 알려진 전역을 찾는다 (src/)" begin
    found = CB.scan_globals(SRC)
    for name in (:BATTERY_FLEET, :HAZARD_STATE, :SNAP_COUNT, :WEDGE_EDGES,
                 :RESTRICTION_ZONES, :SIM_STEP, :STALLED_ROBOTS, :BATTERY_DELIVERIES,
                 :CARRIER_LAST_D, :RESPEC_QUEUE)   # fix round 1: 구조적 사각지대 #3 (non-Ref 컨테이너)
        @test name in found
    end
    @test length(found) >= 70      # 2026-08-20 실측 89 (src/ 만, 확장 정규식 기준)
end

@testset "스캐너가 run_demo.jl/policy.jl 의 전역도 찾는다 (범위 확장, I12 + fix round 1)" begin
    found = CB.scan_globals(SRC; extra_files=EXTRA_FILES)
    for name in (:_REFORM_CT, :_ZONE_CT, :ZONE_DECIDE_DEFERRED, :_DECISION_N, :DSPY_HEALTHY, :_DECISIONS)
        @test name in found
    end
    # _SIM_STEP 은 태스크 8(시계 단일 진실원 통일)이 run_demo.jl 에서 지웠다 — 여기 있으면 안 된다.
    # 이 음성 대조가 바로 2026-08-20 fix round 1 이 잡은 살아있는 레드(유령 엔트리)의 반대쪽 증거다.
    @test !(:_SIM_STEP in found)
    # extra_files 없이 SRC 만 훑으면 이 여섯은 안 보여야 한다 — 확장이 실제로 그 파일들을 보는지,
    # 이미 src/ 안에 있는 이름과 우연히 겹친 게 아닌지 구분하는 음성 대조.
    without_extra = CB.scan_globals(SRC)
    for name in (:_REFORM_CT, :_ZONE_CT, :ZONE_DECIDE_DEFERRED, :_DECISION_N, :DSPY_HEALTHY, :_DECISIONS)
        @test !(name in without_extra)
    end
end

@testset "분류되지 않은 전역이 없다 (src/ + run_demo.jl/policy.jl/zone_inject.jl, 그 밖은 범위 밖)" begin
    missing = CB.unclassified_globals(SRC; extra_files=EXTRA_FILES)
    isempty(missing) || @info "분류 안 된 전역" missing
    @test isempty(missing)
end

@testset "표에 있는데 스캔에는 없는 유령 전역이 없다 (fix round 1, [Important] #4 — 반대 방향)" begin
    # unclassified_globals 는 "새 전역이 생겼는데 표가 모른다" 만 잡는다. _SIM_STEP 이 정확히
    # 보여준 실패는 반대 방향이다 — "표가 아는 전역이 이제 코드에 없다". 둘 다 지켜야 인벤토리가
    # 닫힌다.
    stale = CB.stale_globals(SRC; extra_files=EXTRA_FILES)
    isempty(stale) || @info "유령 전역(표에는 있는데 스캔에는 없다)" stale
    @test isempty(stale)
    # `>= 70` 같은 느슨한 하한은 진짜 계약을 지키지 못한다(78개짜리 표에서 8개를 지워도 통과한다).
    # 진짜 계약은 등호다: 표의 키 집합이 스캔 결과와 정확히 같아야 한다.
    found = Set(CB.scan_globals(SRC; extra_files=EXTRA_FILES))
    @test Set(keys(CB.STATE_GLOBALS)) == found
end

@testset "처분 어휘가 닫혀 있다" begin
    ok = Set([:state, :replay, :split, :log, :setup, :render, :meta])
    @test all(v -> v in ok, values(CB.STATE_GLOBALS))
end

@testset "s 로 가는 전역이 spec §3.6 을 덮는다" begin
    st = Set(k for (k, v) in CB.STATE_GLOBALS if v === :state)
    for name in (:BATTERY_FLEET, :STALLED_ROBOTS, :BATTERY_DELIVERIES, :AGENT_COST_BIAS,
                 :RESTRICTION_ZONES, :SPARE_POOLS, :SPARE_SLOTS, :FAULTED_ROBOTS,
                 :RECOVERY_SPARES, :CHECKED_OUT_SPARES, :DECOMMISSIONED_BODIES,
                 :HOT_SWAP_ASSETS, :WEDGE_EDGES, :DISSOLVED_GATES, :SNAP_COUNT,
                 :SIM_STEP, :LAST_EDGE_COSTS, :RESPEC_FROZEN, :RESPEC_PINNED,
                 :_IDENTITY_SEEN, :CARRIER_LAST_D, :RESPEC_QUEUE, :_DECISION_N)
        @test name in st
    end
    @test CB.STATE_GLOBALS[:HAZARD_STATE] === :split     # 셋으로 쪼개진다
    @test CB.STATE_GLOBALS[:OOD_SCHEDULE] === :split     # fired 만 상태, 나머지는 setup (fix round 1)
    @test CB.STATE_GLOBALS[:ASSET_LEDGER] === :replay    # 결정에 안 쓰인다, 바이트 동일 재현용 (fix round 1)
    @test CB.STATE_GLOBALS[:NOVELTY_DETECTOR] === :meta  # spec §6.1 — s 에 넣지 않는다
    @test CB.STATE_GLOBALS[:NOVELTY_FLEET_REF] === :setup  # never-written 상수 (fix round 1)
end
