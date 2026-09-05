# =============================================================================
# `monitor_emit!` 의 `frame["battery"]` 에 데모 지표(task-5)가 실리는지 못박는다.
# (2026-09-04, `.superpowers/sdd/2026-09-04-l4-reachable-and-necessity/task-5-metric-research.md`)
#
# 재는 것: `"total_energy_J"` · `"soc_spread"`(둘 다 `battery_report()` 재사용) · 로봇별
# `"energy_J"`(문자열 키). **삼상 규약**: 함대가 없으면(`BATTERY_FLEET[] === nothing`) 이 셋은
# 부재이거나 `nothing` 이어야 한다 — `0` 이면 "안 쟀다"와 "쟀는데 0"이 섞인다.
#
# 실 env 를 짓는 비용이 이 파일에서 가장 크다. `return_env_before_sim=true`(다른 게이트들도
# 쓰는 관용구, 예: `service_decide_ships_agents.jl`)로 시뮬레이션은 한 스텝도 안 돌리고
# 스케줄만 완성된 env 를 받는다 — `cache.active_set`/`closed_set` 은 빈 채로 있다(주석:
# "cache empty since nothing has executed yet", `full_demo.jl`).
#
# 실행: julia +lts --project=. test/monitor_battery_fields.jl
# =============================================================================
module MonitorBatteryFields

using ConstructionBots
using Test
using Random
using JSON3
const CB = ConstructionBots
const REPO = normpath(joinpath(@__DIR__, ".."))
isdefined(CB, :BatteryFleet) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))

const TENV = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr",
                                project_name = "monitor_battery_fields",
                                num_robots = 4, assignment_mode = :greedy,
                                n_spare_per_pool = 2,
                                open_animation_at_end = false, save_animation = false,
                                write_results = false, return_env_before_sim = true,
                                rng = Random.MersenneTwister(1))

@testset "monitor_emit! battery 프레임 — total_energy_J·soc_spread·energy_J" begin
    saved_fleet = CB.BATTERY_FLEET[]
    tmp = tempname() * ".jsonl"
    try
        # (1) 함대 없음 → 새 키 셋은 부재이거나 nothing. "battery" 자체가 통째로 빠지는
        #     기존 동작(가드: `fleet !== nothing && !isempty(fleet.soc)`)이 그대로면 자동으로
        #     만족되지만, 우연이 아니라 계약임을 여기서 못박는다.
        CB.BATTERY_FLEET[] = nothing
        CB.monitor_enable!(tmp)
        CB.monitor_emit!(TENV, 1)
        CB.monitor_disable!()
        frame0 = JSON3.read(readlines(tmp)[end])
        b0 = get(frame0, :battery, nothing)
        @test b0 === nothing ||
              (get(b0, :total_energy_J, nothing) === nothing &&
               get(b0, :soc_spread, nothing) === nothing &&
               get(b0, :energy_J, nothing) === nothing)

        # (2) 함대 있음 → 세 키가 실제로 실리고, battery_report() 재사용이라 값이 일치한다.
        fleet = CB.enable_battery!(TENV; params = CB.BatteryParams())
        ids = collect(keys(fleet.soc))
        @test length(ids) >= 2
        fleet.energy_J[ids[1]] = 12.5           # 0 이 아닌 값으로 "쟀는데 0"과 구분되게 한다
        fleet.soc[ids[1]] = 0.4
        fleet.soc[ids[2]] = 0.9                  # soc_spread > 0 을 보장

        CB.monitor_enable!(tmp)
        CB.monitor_emit!(TENV, 2)
        CB.monitor_disable!()
        frame1 = JSON3.read(readlines(tmp)[end])
        b1 = frame1.battery

        rep = CB.battery_report(fleet)           # 재계산 없이 재사용했는지 대조하는 정본
        @test b1.total_energy_J == rep.total_energy_J
        @test b1.soc_spread == rep.soc_spread
        @test b1.soc_spread > 0

        eJ = b1.energy_J
        @test length(eJ) == length(ids)
        for id in ids
            @test haskey(eJ, Symbol(string(id)))   # 키가 문자열화돼 JSON 을 통과했다
            @test eJ[Symbol(string(id))] == fleet.energy_J[id]
        end
    finally
        CB.monitor_disable!()
        isfile(tmp) && rm(tmp; force = true)
        CB.BATTERY_FLEET[] = saved_fleet
        CB.EDGE_COST_MULTIPLIER[] = nothing
        CB.BATTERY_STEP_HOOK[] = nothing
        CB.SOC_SPEED_HOOK[] = nothing
    end
end

end # module
