# =============================================================================
# **방전 정지는 결정 epoch 를 만들지 않는다** — 계약을 못박는다.
#
# 무엇이 있었나 (2026-08-25 실측)
# --------------------------------
# `account_battery_step!` 의 (3) STALL 블록이 임계값을 넘은 로봇마다 `_fire_battery_stall!` 을
# 불렀고, 그 함수는 `fault_robot!`(물리 고장 등록 + 견인) + `push_ood!(nl)` 을 했다. 그런데
# **`record_ood_truth!` 은 부르지 않는다** — 그래서:
#   · `run_demo.jl` 은 truth 로그를 폴링하므로 이 사건을 **아예 못 본다**.
#   · 그 NL 은 respec 큐로만 갔는데 `run_demo.jl` 은 `RESPEC_ENABLED[]=false` 라 큐를 안 돈다.
#   · `render_demo.jl` 은 큐를 돌지만 `truth_for_event(event) === nothing` 이라 조용히 버린다.
# 즉 **어느 엔진에서도 결정이 되지 않으면서** 로봇만 고장 등록·견인되는 경로였다.
#
# 왜 지우나 (사용자 판정 2026-08-25 · 실측 근거)
# ---------------------------------------------
# 제조 한 판에서 SoC 는 거의 안 떨어진다 — 287 노드를 다 지은 판의 `min_soc = 0.9988`,
# `n_depleted = 0`(stall 임계값은 0.15). 즉 자연 방전으로는 이 경로가 **발화조차 하지 않고**,
# 발화하는 유일한 경우는 주입된 battery 사건인데 그건 이미 `BatteryTruth` 결정 epoch 를 만든다.
# 없는 두 번째 처방을 조용히 얹던 자리다.
#
# 🔴 정지 **기록**은 지우지 않는다. `n_stalled` 가 정지의 유일한 기계적 증거이고
# (`[STALL]` @info 는 `Logging.Warn` 에 삼켜진다 — CLAUDE.md ★7), 스케줄 DAG 교착을 사후에
# 설명할 수 있는 신호가 그것 하나다.
#
# 실행: julia +lts --project=. test/battery_stall_no_ood.jl
# =============================================================================
module BatteryStallNoOOD

using Test
using ConstructionBots
const CB = ConstructionBots
const REPO = normpath(joinpath(@__DIR__, ".."))
isdefined(CB, :BatteryFleet) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))

"임계값 아래 로봇 하나 + 임계값 위 로봇 하나를 가진 함대."
function _fleet(; flat_soc = 0.01, ok_soc = 0.9)
    f = CB.BatteryFleet(CB.BatteryParams(), Dict{Any,Float64}(), Dict{Any,Float64}(),
                        Dict{Any,Int}(), Set{Any}())
    f.soc[CB.RobotID(1)] = flat_soc
    f.soc[CB.RobotID(2)] = ok_soc
    return f
end

@testset "방전 정지: 기록은 남고 OOD 는 안 난다" begin
    saved_stall = CB.BATTERY_STALL[]
    CB.clear_stalled_robots!()
    empty!(CB.RESPEC_QUEUE.pending)
    local faults_before = length(CB.faulted_robots())
    try
        CB.set_battery_stall!(enabled = true, threshold = 0.15)
        CB.clear_stalled_robots!()          # set_battery_stall! 이 비우지만 명시적으로 한 번 더
        empty!(CB.RESPEC_QUEUE.pending)

        local f = _fleet()
        local ids = Any[CB.RobotID(1), CB.RobotID(2)]
        local newly = CB._mark_newly_stalled!(f, ids)

        # (1) 임계값 아래 로봇만 정지로 기록된다 = n_stalled 증거가 보존된다.
        @test CB.RobotID(1) in newly
        @test !(CB.RobotID(2) in newly)
        @test CB.RobotID(1) in CB.stalled_robots()

        # (2) 🔴 결정 레이어에 아무것도 안 올라간다. 이것이 이 파일의 존재 이유다.
        @test isempty(CB.RESPEC_QUEUE.pending)
        # (3) 🔴 고장으로도 등록되지 않는다 — 결정 없는 고장은 없어야 한다.
        @test length(CB.faulted_robots()) == faults_before

        # (4) 한 번만 기록된다(재호출해도 다시 안 뜬다).
        @test isempty(CB._mark_newly_stalled!(f, ids))

        # (5) 꺼져 있으면 아무 일도 안 한다.
        CB.set_battery_stall!(enabled = false, threshold = 0.15)
        CB.clear_stalled_robots!()
        @test isempty(CB._mark_newly_stalled!(f, ids))
    finally
        CB.BATTERY_STALL[] = saved_stall
        CB.clear_stalled_robots!()
        empty!(CB.RESPEC_QUEUE.pending)
    end
end

end # module
