# Env-free smoke test for the battery->stall coupling (no sim, no MILP, no MeshCat).
# Verifies: package loads with the route_planning SOC_SPEED_HOOK edit; battery.jl includes;
# the new symbols exist; set_battery_stall!/soc_speed_factor gate + fire-once guard behave.
#   julia +lts --project=. tools/stall_gate_check.jl
using ConstructionBots
const CB = ConstructionBots
for f in ("metrics.jl", "ood_truth.jl", "battery.jl", "ood_stream.jl")
    CB.include(joinpath(pkgdir(CB), "src", "navigator", f))
end

pass = 0; fail = 0
check(name, cond) = (cond ? (global pass += 1; println("  PASS  $name")) :
                            (global fail += 1; println("  FAIL  $name")))

println("[1] symbols present")
check("SOC_SPEED_HOOK Ref",      isa(CB.SOC_SPEED_HOOK, Base.RefValue))
check("set_battery_stall! fn",   isa(CB.set_battery_stall!, Function))
check("soc_speed_factor fn",     isa(CB.soc_speed_factor, Function))
check("install_soc_speed_hook!", isa(CB.install_soc_speed_hook!, Function))
check("stalled_robots fn",       isa(CB.stalled_robots, Function))

println("[2] stall config toggling + guard reset")
CB.set_battery_stall!(enabled = true, threshold = 0.05)
check("enabled set true",   CB.BATTERY_STALL[].enabled == true)
check("threshold set",      CB.BATTERY_STALL[].threshold ≈ 0.05)
push!(CB.STALLED_ROBOTS[], :dummy)
CB.set_battery_stall!(enabled = false)              # must clear the fire-once guard
check("guard cleared on reconfigure", isempty(CB.stalled_robots()))

println("[3] soc_speed_factor is inert when stall disabled / no fleet")
CB.BATTERY_FLEET[] = nothing
CB.set_battery_stall!(enabled = false)
check("inert -> factor 1.0 (disabled)", CB.soc_speed_factor(nothing) == 1.0)
CB.set_battery_stall!(enabled = true, threshold = 0.1)
check("inert -> factor 1.0 (no fleet)", CB.soc_speed_factor(nothing) == 1.0)

println("[4] install hook wires the Ref, teardown clears it")
CB.install_soc_speed_hook!()
check("hook installed", CB.SOC_SPEED_HOOK[] === CB.soc_speed_factor)
CB.SOC_SPEED_HOOK[] = nothing
CB.set_battery_stall!(enabled = false); CB.clear_stalled_robots!()
check("hook cleared", CB.SOC_SPEED_HOOK[] === nothing)

println("\n$(fail == 0 ? "ALL GREEN" : "HAS FAILURES") — pass=$pass fail=$fail")
exit(fail == 0 ? 0 : 1)
