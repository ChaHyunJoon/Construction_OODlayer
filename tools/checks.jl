# =============================================================================
# tools/checks.jl -- consolidated ConstructionBots check/probe driver.
#
# Every standalone tools/*check*.jl / *probe*.jl script is now a FUNCTION in module
# `Checks`, sharing common boilerplate (MILP setup + run_with_stack) defined ONCE. A
# CLI/ENV dispatcher at the bottom lets any single check run individually.
#
# Check keys:
#   load          -- package loads; rethread_robot_ids! defined (smoke)
#   depot_render  -- draw_spare_depots! / draw_decommissioned_robots! run setobject! on headless MeshCat
#   stall_gate    -- battery->stall coupling symbols + set_battery_stall!/soc_speed_factor gating (env-free)
#   spare_pool    -- OOD 1-1 A1 directional spare-pool storage + geometry helpers (env-free)
#   hot_swap      -- identity-preserving spare-repository hot-swap bookkeeping + health reset (env-free)
#   scale_cap     -- per-project/per-scale "root-clear cap" geometry probe (no sim; rvo OFF)
#
# Run:
#   julia +lts --project=. tools/checks.jl <check_key>       (or  ENV CHECK=<key>)
# e.g.
#   julia +lts --project=. tools/checks.jl spare_pool
#   CHECK=stall_gate julia +lts --project=. tools/checks.jl
# Each check reads its own ENV knobs at call time (see the comment above each function).
# =============================================================================
module Checks
using ConstructionBots
import MeshCat, Logging, HiGHS, LinearAlgebra
const CB = ConstructionBots
const norm = LinearAlgebra.norm

# ---- runtime-loaded decoupled layers (loaded ONCE, at module load) ----------
# The navigator layer is NOT compiled into the ConstructionBots package -- the checks
# historically `CB.include`d its pieces (metrics/ood_truth/battery/ood_stream) at SCRIPT
# TOP LEVEL. Now that each check is a FUNCTION, doing those includes *inside* a check and
# then calling the freshly-defined methods in the SAME call frame raises a world-age error
# ("method too new to be called from this world context"). Loading it here at MODULE load
# puts it in an OLDER world than any check call, exactly reproducing the original top-level-
# include semantics. navigator.jl is the umbrella loader (it includes metrics/ood_truth/
# battery/ood_stream/... in dependency order -- see its header), so ONE call covers every
# navigator-using check (stall_gate + hot_swap).
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))

# ---- shared helpers (defined ONCE) ------------------------------------------
# The set_default_milp_optimizer! block that appears in the MILP-using probes. Default
# 300.0s / 5.0 gap matches scale_cap_probe; pass overrides for a different config.
function _setup_milp!(; time_limit = 300.0, mip_rel_gap = 5.0)
    CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
    CB.clear_default_milp_optimizer_attributes!()
    CB.set_default_milp_optimizer_attributes!(
        "time_limit" => time_limit, "presolve" => "on", "mip_rel_gap" => mip_rel_gap,
        CB.MOI.Silent() => true)
end

# The identical stack-growing task helper (grow the C stack so a deep MILP/nav build
# does not overflow). Shared by every probe that drives run_lego_demo.
function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))
    return res[]
end

# =============================================================================
# load -- trivial package-load smoke check: does ConstructionBots import, and is the
#   rethread_robot_ids! symbol defined? (originally tools/loadcheck.jl)
# =============================================================================
function check_load()
    println("LOAD OK; rethread_robot_ids! defined = ", isdefined(ConstructionBots, :rethread_robot_ids!))
end

# =============================================================================
# depot_render -- proves draw_spare_depots! / draw_decommissioned_robots! actually
#   execute their setobject! calls on a REAL (headless) MeshCat visualizer -- i.e. the
#   depot pads and fault pin land in the scene tree (not just no-op'd). The draw fns push
#   their key into a drawn-set AFTER the setobject! loop, so a populated drawn-set proves
#   the geometry was created without error. (originally tools/depot_render_check.jl)
# =============================================================================
function check_depot_render()
npass = Ref(0); nfail = Ref(0)
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))

println(">>> depot / fault-marker render check (headless MeshCat)")
vis = MeshCat.Visualizer()          # headless (no browser); starts an in-proc server

CB.clear_spare_pools!()
CB.clear_depot_markers!()
CB.clear_decommissioned_markers!()

# populate a depot the way add_directional_spare_pools! does
CB.SPARE_POOL_CENTERS[][:north] = [0.0, 6.0]
CB.SPARE_POOL_CENTERS[][:east]  = [6.0, 0.0]
CB.DEPOT_INFO[][:north] = (capacity = 2, halfw = 1.0, halfd = 0.5)
CB.DEPOT_INFO[][:east]  = (capacity = 2, halfw = 1.0, halfd = 0.5)

CB.draw_spare_depots!(vis)          # must run setobject! for each side without error
check("draw_spare_depots! drew :north pad+posts", :north in CB._DRAWN_DEPOT_MARKERS[])
check("draw_spare_depots! drew :east pad+posts",  :east  in CB._DRAWN_DEPOT_MARKERS[])

# idempotency: a second call adds nothing new (already drawn)
before = length(CB._DRAWN_DEPOT_MARKERS[])
CB.draw_spare_depots!(vis)
check("draw_spare_depots! idempotent", length(CB._DRAWN_DEPOT_MARKERS[]) == before)

# fault pin at a break spot
rid = CB.get_unique_id(CB.RobotID)
CB.decommissioned_bodies()[rid] = [1.4, 0.7]
CB.draw_decommissioned_robots!(vis)
check("draw_decommissioned_robots! drew the red fault pin", rid in CB._DRAWN_DECOMMISSIONED[])

println("\ndepot render check: $(npass[]) PASS / $(nfail[]) FAIL")
nfail[] == 0 || error("depot render check had $(nfail[]) failure(s)")
end

# =============================================================================
# stall_gate -- env-free smoke test for the battery->stall coupling (no sim, no MILP, no
#   MeshCat). Verifies: package loads with the route_planning SOC_SPEED_HOOK edit; battery.jl
#   symbols exist; set_battery_stall!/soc_speed_factor gate + fire-once guard behave.
#   (originally tools/stall_gate_check.jl; its per-file navigator includes are now hoisted.)
# =============================================================================
function check_stall_gate()
pass = 0; fail = 0
check(name, cond) = (cond ? (pass += 1; println("  PASS  $name")) :
                            (fail += 1; println("  FAIL  $name")))

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
end

# =============================================================================
# spare_pool -- LLM-free, env-free unit check of OOD 1-1 Part A1: the directional
#   spare-pool storage + geometry helpers (ood_injection.jl). No nav build, no MILP, no
#   Python service -- pure storage/geometry assertions. (originally tools/spare_pool_check.jl)
# =============================================================================
function check_spare_pool()
npass = Ref(0); nfail = Ref(0)
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))

println(">>> A1 spare-pool storage + geometry (env-free)")

CB.clear_spare_pools!()

# --- pool_centers: 4 cardinal centers placed `margin` outside a unit bbox -------
# bbox = (xmin,xmax,ymin,ymax) = (-1,1,-1,1); margin=2 -> centers at distance 2 outside.
centers = CB.pool_centers((-1.0, 1.0, -1.0, 1.0); margin = 2.0)
check("pool_centers has 4 cardinal keys",
    Set(keys(centers)) == Set([:north, :south, :east, :west]))
check("north center is +y outside bbox", centers[:north] == [0.0, 3.0])
check("south center is -y outside bbox", centers[:south] == [0.0, -3.0])
check("east center is +x outside bbox",  centers[:east]  == [3.0, 0.0])
check("west center is -x outside bbox",  centers[:west]  == [-3.0, 0.0])

# --- register_spare! / pop_spare! / active_spares round-trip --------------------
# Fabricate spare RobotIDs (env-free) via the global id counter.
rids = Dict(k => [CB.get_unique_id(CB.RobotID) for _ in 1:3] for k in keys(centers))
for (k, v) in rids, rid in v
    CB.register_spare!(k, rid)
end
# Record the centers too so nearest_pool can score them.
for (k, c) in centers
    CB.SPARE_POOL_CENTERS[][k] = Vector{Float64}(c)
end
check("active_spares counts all registered (4 pools x 3)", length(CB.active_spares()) == 12)
check("each pool holds 3 spares",
    all(length(CB.spare_pools()[k]) == 3 for k in keys(centers)))

popped = CB.pop_spare!(:north)
check("pop_spare! returns a registered north id", popped in rids[:north])
check("pop_spare! shrinks the north pool to 2", length(CB.spare_pools()[:north]) == 2)
check("active_spares now 11 after one pop", length(CB.active_spares()) == 11)

# --- nearest_pool: closest center wins; skips empty pools when nonempty ---------
check("nearest_pool near +y -> :north", CB.nearest_pool([0.0, 10.0]) == :north)
check("nearest_pool near -y -> :south", CB.nearest_pool([0.0, -10.0]) == :south)
check("nearest_pool near +x -> :east",  CB.nearest_pool([10.0, 0.0]) == :east)
check("nearest_pool near -x -> :west",  CB.nearest_pool([-10.0, 0.0]) == :west)

# Drain the north pool; with nonempty=true it must no longer be selected even for
# a position right on top of it (the next-nearest non-empty pool wins instead).
CB.pop_spare!(:north); CB.pop_spare!(:north)
check("drained north pool is empty", isempty(CB.spare_pools()[:north]))
np = CB.nearest_pool([0.0, 10.0]; nonempty = true)
check("nearest_pool(nonempty) skips drained :north", np !== :north && np !== nothing)
check("nearest_pool(nonempty=false) still returns :north",
    CB.nearest_pool([0.0, 10.0]; nonempty = false) == :north)

# --- clear_spare_pools! wipes both stores --------------------------------------
CB.clear_spare_pools!()
check("clear_spare_pools! empties pools", isempty(CB.spare_pools()))
check("clear_spare_pools! empties centers", isempty(CB.spare_pool_centers()))
check("nearest_pool on empty stores -> nothing", CB.nearest_pool([0.0, 0.0]) === nothing)

println("\nA1 spare-pool check: $(npass[]) PASS / $(nfail[]) FAIL")
nfail[] == 0 || error("A1 spare-pool check had $(nfail[]) failure(s)")
end

# =============================================================================
# hot_swap -- LLM-free, env-free unit check of the identity-preserving spare-repository
#   HOT-SWAP machinery (ood_injection.jl + replace_robot.jl). No nav build, no MILP, no
#   Python service -- pure storage/flag/reset assertions. The full scene-tree swap
#   (hot_swap_robot!) needs a built env and is exercised by the demo / spare_replace_test;
#   this gates the new bookkeeping + health reset. (originally tools/hot_swap_check.jl; its
#   per-file navigator includes are now hoisted.)
# =============================================================================
function check_hot_swap()
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
end

# =============================================================================
# scale_cap -- per-project, per-scale measurement of the "root-clear cap" (max distance
#   from any relocatable sub-assembly's staging center to the nearest UN-RELOCATABLE root
#   deposit goal). This is the geometric quantity that decides whether a meaningful forbid
#   zone can ever be restage-recovered. Pure geometry: rvo OFF, NO sim warmup
#   (return_env_before_sim) -> fast. We only build the scene/schedule/staging plan, then read
#   staging_circles + root goals. ENV: PROBE_PROJECTS, PROBE_MULTS. (originally
#   tools/scale_cap_probe.jl; its inline MILP + local run_with_stack are now shared.)
# =============================================================================
function check_scale_cap()
_setup_milp!()

# build env up through staging/place_objects ONLY (no sim). scale_mult multiplies model_scale.
function build_geom(project::Int, scale_mult::Float64)
    pp = CB.get_project_params(project)
    run_with_stack(2_000_000_000) do
        CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
            model_scale=pp[:model_scale]*scale_mult, num_robots=pp[:num_robots],
            assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
            log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false,
            dispersion_flag=false, open_animation_at_end=false, save_animation=false,
            save_animation_along_the_way=false, write_results=false,
            overwrite_results=false, look_for_previous_milp_solution=false,
            save_milp_solution=false, return_env_before_sim=true)
    end
end

# max root-clear cap over all non-root assemblies (nothing has run yet -> all are "future").
function max_cap(env)
    isempty(env.staging_circles) && return (nothing, -1.0, 0)
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))
    rootgoals = CB.root_deposit_goals(env)
    isempty(rootgoals) && return (root, -1.0, 0)
    best = -Inf; n = 0
    for k in keys(env.staging_circles)
        k == root && continue
        n += 1
        c = Vector{Float64}(CB.get_center(env.staging_circles[k])[1:2])
        d = minimum(norm(c .- g) for g in rootgoals)
        d > best && (best = d)
    end
    return (root, best, n)
end

PROJECTS = parse.(Int, split(get(ENV, "PROBE_PROJECTS", "4,5,6"), ","))
MULTS    = parse.(Float64, split(get(ENV, "PROBE_MULTS", "1,2,3,4"), ","))
RR = Float64(CB.default_robot_radius())
TARGET_CAP = 1.5   # want a zone of ~1 robot radius to fit with margin

println("robot_radius=$RR   target_cap=$TARGET_CAP")
println("proj  name                scaleMult  model_scale   maxCap   #subasm   cap/RR   zone_fits?")
for p in PROJECTS
    pp = CB.get_project_params(p)
    base = pp[:model_scale]
    caps = Tuple{Float64,Float64}[]   # (mult, cap)
    for m in MULTS
        local cap, n
        try
            env = build_geom(p, m)
            _, cap, n = max_cap(env)
        catch e
            println("  proj $p x$m -> BUILD FAILED: $(typeof(e))")
            continue
        end
        push!(caps, (m, cap))
        fits = cap > RR + 0.25*RR
        println(rpad(p,5), " ", rpad(string(pp[:project_name]),18), " ",
                rpad("x"*string(m),9), " ", rpad(round(base*m;digits=5),12), " ",
                rpad(round(cap;digits=3),8), " ", rpad(n,8), " ",
                rpad(round(cap/RR;digits=2),7), " ", fits ? "YES" : "no")
    end
    # linear fit cap ≈ a*mult + b through measured points -> recommend mult for TARGET_CAP
    if length(caps) >= 2
        xs = [c[1] for c in caps]; ys = [c[2] for c in caps]
        x̄ = sum(xs)/length(xs); ȳ = sum(ys)/length(ys)
        a = sum((xs .- x̄).*(ys .- ȳ)) / sum((xs .- x̄).^2)
        b = ȳ - a*x̄
        mult_needed = (TARGET_CAP - b)/a
        println("  -> $(pp[:project_name]): cap ≈ $(round(a;digits=3))*mult + $(round(b;digits=3))" *
                "  => for cap=$TARGET_CAP need mult≈$(round(mult_needed;digits=2)) " *
                "(model_scale≈$(round(base*mult_needed;digits=5)))")
    end
end
println("DONE")
end

# ---- dispatcher -------------------------------------------------------------
const CHECKS = Dict(
    "load"         => check_load,
    "depot_render" => check_depot_render,
    "stall_gate"   => check_stall_gate,
    "spare_pool"   => check_spare_pool,
    "hot_swap"     => check_hot_swap,
    "scale_cap"    => check_scale_cap,
)
end # module Checks

if abspath(PROGRAM_FILE) == @__FILE__
    key = get(ENV, "CHECK", isempty(ARGS) ? "load" : ARGS[1])
    haskey(Checks.CHECKS, key) || error("unknown check '$key'. Available: $(join(sort(collect(keys(Checks.CHECKS))), ", "))")
    println(">>> running check: $key")
    Checks.CHECKS[key]()
end
