# tools/test_battery_smoke.jl
# OFFLINE smoke test for the energy-aware adaptive layer — NO env build, NO LLM.
# Loads the navigator files into the ConstructionBots module scope (the established
# manual-include pattern) and unit-tests the pure pieces:
#   battery power model · SoC->cost multiplier · metric wiring · OOD-stream scheduling.
# Run:  julia +lts --project=. tools/test_battery_smoke.jl
using ConstructionBots
const CB = ConstructionBots
using Random

_nav(f) = joinpath(pkgdir(CB), "src", "navigator", f)
CB.include(_nav("metrics.jl"))
CB.include(_nav("ood_truth.jl"))
CB.include(_nav("battery.jl"))
CB.include(_nav("ood_stream.jl"))

const PASS = Ref(0); const FAILN = Ref(0)
macro check(ex)
    quote
        if $(esc(ex)); PASS[] += 1
        else; FAILN[] += 1; println("  FAIL: ", $(string(ex))); end
    end
end

println("== BatteryParams / k_move calibration ==")
p = CB.BatteryParams()
@check p.capacity_J ≈ 2.3 * 3.6e6
@check p.v_ref == 4.0                                  # = rvo_default_max_speed()
@check CB.k_move(p) ≈ (500.0 - 100.0) / (60.0 * 4.0)   # idle+k·m·v_ref == walk_W
# an unloaded robot at v_ref draws exactly walk_W:
@check p.idle_W + CB.k_move(p) * p.m_robot * p.v_ref ≈ 500.0
@check CB.demo_battery_params(shrink = 5e4).capacity_J ≈ (2.3 * 3.6e6) / 5e4

println("== SoC -> cost multiplier (battery_edge bias) ==")
CB.set_battery_penalty!(gain = 4.0, soc_target = 0.5, hard_mult = 1.0e3)
@check CB._soc_multiplier(1.0) == 1.0                  # healthy: no penalty
@check CB._soc_multiplier(0.5) == 1.0                  # at target: no penalty
@check CB._soc_multiplier(0.25) ≈ 1.0 + 4.0 * (0.25 / 0.5)  # below target: linear penalty
@check CB._soc_multiplier(0.0) == 1.0e3               # depleted: hard penalty
@check CB._soc_multiplier(0.25) > CB._soc_multiplier(0.4) # lower SoC -> bigger multiplier

println("== EDGE_COST_MULTIPLIER hook default-inert ==")
CB.EDGE_COST_MULTIPLIER[] = nothing
@check CB.edge_cost_multiplier(nothing, 1) == 1.0      # default: no effect (objective preserved)
CB.install_battery_objective_hook!()
@check CB.EDGE_COST_MULTIPLIER[] === CB.battery_edge_multiplier
CB.BATTERY_ACCOUNTING[] = false
@check CB.battery_edge_multiplier(nothing, 1) == 1.0   # accounting off -> 1.0 even with hook installed
CB.EDGE_COST_MULTIPLIER[] = nothing                    # reset

println("== step hook (route_planning.BATTERY_STEP_HOOK) default-inert + installable ==")
@check CB.BATTERY_STEP_HOOK[] === nothing              # default: step_environment! unchanged
CB.install_battery_step_hook!()
@check CB.BATTERY_STEP_HOOK[] === CB.account_battery_step!
CB.BATTERY_STEP_HOOK[] = nothing                       # reset
@check isa(CB.enable_battery!, Function)               # one-call enable helper exists
@check isa(CB.rebalance_for_battery!, Function)        # SoC-biased re-solve helper exists

println("== Fleet accounting: _debit!, report, low_soc, spread ==")
r1, r2, r3 = CB.RobotID(1), CB.RobotID(2), CB.RobotID(3)
fleet = CB.BatteryFleet(p,
    Dict{Any,Float64}(r1 => 1.0, r2 => 0.8, r3 => 0.2),
    Dict{Any,Float64}(r1 => 0.0, r2 => 0.0, r3 => 0.0),
    Dict{Any,Int}(r1 => 0, r2 => 0, r3 => 0),
    Set{Any}())
CB._debit!(fleet, r1, 500.0, 1.0)                      # 500 J off r1
@check fleet.energy_J[r1] == 500.0
@check fleet.soc[r1] ≈ 1.0 - 500.0 / p.capacity_J
rep = CB.battery_report(fleet)
@check rep.min_soc ≈ 0.2
@check rep.soc_spread ≈ (maximum(values(fleet.soc)) - 0.2)
@check rep.total_energy_J == 500.0
@check Set(CB.low_soc_robots(fleet; threshold = 0.25)) == Set([r3])
# depletion clamps at floor and is recorded:
CB._debit!(fleet, r3, 1e12, 1.0)
@check fleet.soc[r3] == 0.0 && (r3 in fleet.depleted)

println("== battery-health OOD injector ==")
CB.BATTERY_FLEET[] = fleet
nl = CB.inject_battery_fault!(nothing; target = r2, soc_drop = 0.5, enqueue = false)
@check occursin("R2", nl) && fleet.soc[r2] ≈ 0.3
CB.BATTERY_FLEET[] = nothing

println("== metric wiring: compute_metrics + axis_costs ==")
m = CB.compute_metrics(; t0 = Float64[], tF = [10.0, 12.0], n_parts = 4, placed_parts = 4,
    robot_busy_time = [3.0, 4.0], transport_distance = 7.0,
    energy = 1234.0, min_soc = 0.3, soc_spread = 0.6)
@check m.energy == 1234.0 && m.min_soc == 0.3 && m.soc_spread == 0.6
@check m.makespan == 12.0
ac = CB.axis_costs(m)
# efficiency axis now includes soc_spread (wear-leveling):
m0 = CB.compute_metrics(; t0 = Float64[], tF = [10.0, 12.0], n_parts = 4, placed_parts = 4,
    robot_busy_time = [3.0, 4.0], transport_distance = 7.0,
    energy = 1234.0, min_soc = 0.3, soc_spread = 0.0)
@check CB.axis_costs(m).efficiency > CB.axis_costs(m0).efficiency   # spread penalized
kw = CB.battery_metrics_kwargs(fleet)
@check haskey(pairs(kw), :energy) && haskey(pairs(kw), :min_soc) && haskey(pairs(kw), :soc_spread)

println("== OOD-stream: random progress points + battery_action ==")
pts = CB._random_progress_points(5, 4, 40, MersenneTwister(7))
@check length(pts) == 5 && issorted(pts) && all(4 .<= pts .<= 40)
@check CB._random_progress_points(0, 4, 40, MersenneTwister(7)) == Int[]
ba = CB.battery_action(soc_drop = 0.3)
@check ba isa Function

println("\n== RESULT: $(PASS[]) passed, $(FAILN[]) failed ==")
exit(FAILN[] == 0 ? 0 : 1)
