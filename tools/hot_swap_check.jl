# =============================================================================
# hot_swap_check.jl -- LLM-free, env-free unit check of the identity-preserving
# spare-repository HOT-SWAP machinery (ood_injection.jl + replace_robot.jl).
# No nav build, no MILP, no Python service -- pure storage/flag/reset assertions.
# The full scene-tree swap (hot_swap_robot!) needs a built env and is exercised by
# the demo / spare_replace_test; this gates the new bookkeeping + health reset.
# Run: julia +lts --project=. tools/hot_swap_check.jl
# =============================================================================
using ConstructionBots
const CB = ConstructionBots

# The battery layer lives in navigator/*.jl, which demos CB.include at runtime (it is
# not part of the compiled package). Load it so the health-reset assertions can run.
for f in ("metrics.jl", "ood_truth.jl", "battery.jl")
    CB.include(joinpath(pkgdir(CB), "src", "navigator", f))
end

npass = Ref(0); nfail = Ref(0)
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))

println(">>> hot-swap repository machinery (env-free)")

CB.clear_spare_pools!()
CB.clear_faulted_robots!()

# --- hot-swap flag toggle -------------------------------------------------------
check("hot-swap OFF by default", CB.hot_swap_enabled() == false)
CB.set_hot_swap!(enabled = true, mode = :via_depot)
check("set_hot_swap! turns it on", CB.hot_swap_enabled() == true)
check("mode recorded", CB.HOT_SWAP_MODE[] == :via_depot)
CB.set_hot_swap!(enabled = false)
check("set_hot_swap!(false) turns it off", CB.hot_swap_enabled() == false)

# --- depot inventory (depot_available) reflects pool + pop ----------------------
# Populate a depot the way add_directional_spare_pools! would (storage-only).
rids = [CB.get_unique_id(CB.RobotID) for _ in 1:3]
for r in rids
    CB.register_spare!(:east, r)
end
CB.SPARE_POOL_CENTERS[][:east] = [5.0, 0.0]
CB.DEPOT_INFO[][:east] = (capacity = 3, halfw = 1.2, halfd = 0.5)
check("depot_available counts registered spares", CB.depot_available(:east) == 3)
CB.pop_spare!(:east)
check("depot_available drops after checkout", CB.depot_available(:east) == 2)
check("depot_available on unknown side is 0", CB.depot_available(:north) == 0)
check("depot_info records capacity", CB.depot_info()[:east].capacity == 3)

# --- decommissioned-body bookkeeping -------------------------------------------
retired = CB.get_unique_id(CB.RobotID)
CB.decommissioned_bodies()[retired] = [3.0, 4.0]
check("decommissioned body recorded", haskey(CB.decommissioned_bodies(), retired))

# --- checked-out spare bookkeeping ---------------------------------------------
co = CB.get_unique_id(CB.RobotID)
push!(CB.checked_out_spares(), co)
check("checked-out spare recorded", co in CB.checked_out_spares())

# --- _reset_robot_health!: full battery + clears stall/deplete/fault + obstacle -
rid = CB.get_unique_id(CB.RobotID)
fleet = CB.BatteryFleet(CB.BatteryParams(),
    Dict{Any,Float64}(rid => 0.0),      # flat
    Dict{Any,Float64}(rid => 5.0),
    Dict{Any,Int}(rid => 3),
    Set{Any}([rid]))                    # depleted
CB.BATTERY_FLEET[] = fleet
push!(CB.STALLED_ROBOTS[], rid)
CB.faulted_robots()[rid] = [1.0, 2.0]
zone_key = Symbol("fault_$(CB.get_id(rid))")
CB.add_restriction_zone!(zone_key, [1.0, 2.0], 0.5)
check("fault obstacle zone registered pre-reset", haskey(CB.restriction_zones(), zone_key))

CB._reset_robot_health!(nothing, rid)
check("reset -> SoC restored to 1.0", fleet.soc[rid] == 1.0)
check("reset -> cleared from depleted", !(rid in fleet.depleted))
check("reset -> cleared from stalled", !(rid in CB.stalled_robots()))
check("reset -> cleared from faulted", !haskey(CB.faulted_robots(), rid))
check("reset -> fault obstacle zone removed", !haskey(CB.restriction_zones(), zone_key))

# --- visualization draws are safe no-ops when headless (vis === nothing) --------
check("draw_spare_depots!(nothing) is a no-op", CB.draw_spare_depots!(nothing) === nothing)
check("draw_decommissioned_robots!(nothing) is a no-op", CB.draw_decommissioned_robots!(nothing) === nothing)

# --- clear_spare_pools! wipes the new repository stores too ---------------------
CB.clear_spare_pools!()
check("clear_spare_pools! empties depot_info", isempty(CB.depot_info()))
check("clear_spare_pools! empties decommissioned", isempty(CB.decommissioned_bodies()))
check("clear_spare_pools! empties checked-out", isempty(CB.checked_out_spares()))

println("\nhot-swap check: $(npass[]) PASS / $(nfail[]) FAIL")
nfail[] == 0 || error("hot-swap check had $(nfail[]) failure(s)")
