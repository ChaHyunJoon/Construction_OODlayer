# test/smdp_global_inventory.jl
# spec §3.6 — 스냅샷 대상 전역의 전수 목록을 **기계로** 지킨다.
#
# 왜 테스트여야 하는가: 표로만 두면 새 전역이 생겼을 때 아무것도 안 잡는다. snapshot/restore!
# 가 그 전역을 모르면 롤아웃마다 조용히 오염된다 — 에러가 아니라 **결과의 미세한 차이**로만
# 새는 실패 모양이라 사후에 못 찾는다(spec §3.5 규칙 3).
#
# 범위 결정(controller-addendum.md 태스크 7, I12): `scan_globals` 는 디렉터리를 재귀로 훑는다.
# `src/` 만으로는 `tools/monitor/run_demo.jl` 이 갖고 있는 실제 에피소드 상태
# (`_REFORM_CT` 가 ReformTruth 발화를 게이팅한다 등)가 안 보인다. 그래서 이 파일은 **의도적으로**
# `tools/monitor/run_demo.jl` 한 파일을 `extra_files` 로 얹어 검사한다. `tools/` 의 나머지 파일과
# `wm4spacecraft_manufacturing/*.jl` 은 **의도적으로 범위 밖**이다(둘러본 결과 테스트 픽스처·
# 무관 도구 상수 Ref 가 섞여 있어, 그걸 다 인벤토리에 넣는 것은 이 태스크의 범위를 벗어난다).
# 아래 테스트셋 이름에 그 범위를 그대로 박아 둔다 — "전역이 없다"가 아니라
# "src/ + run_demo.jl 안에 분류 안 된 전역이 없다".
#
#   julia +lts --project=. test/smdp_global_inventory.jl
using ConstructionBots
using Test
const CB = ConstructionBots

CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

const SRC = normpath(joinpath(@__DIR__, "..", "src"))
const RUN_DEMO_JL = normpath(joinpath(@__DIR__, "..", "tools", "monitor", "run_demo.jl"))

@testset "스캐너가 알려진 전역을 찾는다 (src/)" begin
    found = CB.scan_globals(SRC)
    for name in (:BATTERY_FLEET, :HAZARD_STATE, :SNAP_COUNT, :WEDGE_EDGES,
                 :RESTRICTION_ZONES, :SIM_STEP, :STALLED_ROBOTS, :BATTERY_DELIVERIES)
        @test name in found
    end
    @test length(found) >= 70      # 2026-08-20 실측 78 (계획서 산문의 79 는 오기 — M1)
end

@testset "스캐너가 run_demo.jl 의 전역도 찾는다 (범위 확장, I12)" begin
    found = CB.scan_globals(SRC; extra_files=[RUN_DEMO_JL])
    for name in (:_REFORM_CT, :_SIM_STEP, :_ZONE_CT, :ZONE_DECIDE_DEFERRED)
        @test name in found
    end
    # extra_files 없이 SRC 만 훑으면 이 넷은 안 보여야 한다 — 확장이 실제로 파일을 더 보는지,
    # 이미 src/ 안에 있는 이름이 우연히 겹친 게 아닌지 구분하는 음성 대조.
    without_extra = CB.scan_globals(SRC)
    for name in (:_REFORM_CT, :_SIM_STEP, :_ZONE_CT, :ZONE_DECIDE_DEFERRED)
        @test !(name in without_extra)
    end
end

@testset "분류되지 않은 전역이 없다 (src/ + run_demo.jl, 그 밖은 범위 밖)" begin
    missing = CB.unclassified_globals(SRC; extra_files=[RUN_DEMO_JL])
    isempty(missing) || @info "분류 안 된 전역" missing
    @test isempty(missing)
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
                 :SIM_STEP, :LAST_EDGE_COSTS)
        @test name in st
    end
    @test CB.STATE_GLOBALS[:HAZARD_STATE] === :split     # 셋으로 쪼개진다
    @test CB.STATE_GLOBALS[:NOVELTY_DETECTOR] === :meta  # spec §6.1 — s 에 넣지 않는다
end
