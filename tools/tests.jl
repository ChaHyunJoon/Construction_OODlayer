# =============================================================================
# tools/tests.jl -- consolidated ConstructionBots test/verification driver.
#
# Every standalone tools/test_*.jl script is now a FUNCTION in module `Tests`,
# sharing common boilerplate (MILP setup + run_with_stack + a @check macro) defined
# ONCE. A CLI/ENV dispatcher at the bottom lets any single test run individually.
#
# Test keys:
#   forbidzone_parse         -- LLM-free unit test of the ForbidZone bridge+verify path (Stage 1)
#   replace_parse            -- LLM-free unit test of the ReplaceAgent bridge+verify path (OOD 1-1 Part B)
#   deprioritize_integration -- TIER-2 DeprioritizeAgent integration on a REAL env (no LLM)
#   battery_smoke            -- OFFLINE smoke test of the energy-aware adaptive layer (no env, no LLM)
#   battery_safety           -- OFFLINE safety/verifiability test of the TIER-2 soft re-spec + bias registry
#   llm_classification       -- Stage 3 REAL-LLM check (needs the Python service up + ANTHROPIC_API_KEY)
#
# Run:
#   julia +lts --project=. tools/tests.jl <test_key>        (or  ENV TEST=<key>)
# e.g.
#   julia +lts --project=. tools/tests.jl forbidzone_parse
#   TEST=battery_smoke julia +lts --project=. tools/tests.jl
# Note: battery_smoke/battery_safety are offline; llm_classification needs a LIVE LLM service.
# =============================================================================
module Tests
using ConstructionBots
import Logging, HiGHS, JSON3, LinearAlgebra, Graphs, JuMP
using Random
const CB = ConstructionBots

# ---- runtime-loaded decoupled layer (loaded ONCE, at module load) -----------
# The navigator layer is NOT compiled into the ConstructionBots package -- the battery
# tests historically `CB.include`d metrics/ood_truth/battery/ood_stream at SCRIPT TOP LEVEL.
# Now that each test is a FUNCTION, doing those includes *inside* a test and then calling the
# freshly-defined methods in the SAME call frame raises a world-age error ("method too new to
# be called from this world context"). Loading it here at MODULE load puts it in an OLDER world
# than any test call, exactly reproducing the original top-level-include semantics. navigator.jl
# is the umbrella loader (it includes metrics/ood_truth/battery/ood_stream/... in dependency
# order -- see its header), so ONE call covers every navigator-using test.
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))

# ---- shared helpers (defined ONCE) ------------------------------------------
# The set_default_milp_optimizer! block that appears (nearly identically) across the tests.
# Tests differ only in time_limit (120.0) and mip_rel_gap (5.0 or 0.02) -- passed as kwargs.
function _setup_milp!(; time_limit = 300.0, mip_rel_gap = 5.0)
    CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
    CB.clear_default_milp_optimizer_attributes!()
    CB.set_default_milp_optimizer_attributes!(
        "time_limit" => time_limit, "presolve" => "on", "mip_rel_gap" => mip_rel_gap,
        CB.MOI.Silent() => true)
end

# The identical stack-growing task helper from the tests.
function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))
    return res[]
end

# Shared pass/fail accounting + @check macro (used identically by battery_smoke, battery_safety;
# also referenced by the nested `chk` closure in deprioritize_integration). A macro CANNOT be
# defined inside a function, so it lives here at module level; it is hygienic, so PASS[]/FAILN[]
# resolve to these module-level counters (one test runs per process via the dispatcher).
const PASS = Ref(0); const FAILN = Ref(0)
macro check(ex)
    quote
        if $(esc(ex)); PASS[] += 1
        else; FAILN[] += 1; println("  FAIL: ", $(string(ex))); end
    end
end

# =============================================================================
# forbidzone_parse -- LLM-free unit test of the ForbidZone bridge+verify path (Stage 1).
#   Builds a fast geometry-only env (rvo off, no sim), injects a CENTRAL zone, then exercises:
#   open_zone_descriptors -> a fake /propose JSON with a ForbidZone -> _parse_proposal ->
#   verify_zone (admit), plus negative cases (bad zone key, bad id). No Python service, no nav build.
# =============================================================================
function test_forbidzone_parse()
_setup_milp!(time_limit = 120.0)

println(">>> building fast geometry env (tractor, rvo off)...")
pp = CB.get_project_params(4)
env = run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Error,
        rvo_flag=false, tangent_bug_flag=false, dispersion_flag=false,
        open_animation_at_end=false, save_animation=false, write_results=false,
        overwrite_results=false, look_for_previous_milp_solution=false,
        save_milp_solution=false, return_env_before_sim=true)
end

npass = Ref(0); nfail = Ref(0)
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))

# central zone over the root deposit-goal centroid
gs = CB.root_deposit_goals(env)
zc = isempty(gs) ? [1.5, 0.96] : sum(gs) ./ length(gs)
CB.clear_restriction_zones!(); CB.add_restriction_zone!(:zone, zc, 2.5)

println("\n[1] open_zone_descriptors")
zd = CB.open_zone_descriptors(env)
check("one zone described", length(zd) == 1)
check("key == \"zone\"", !isempty(zd) && zd[1]["key"] == "zone")
check("covers_root true (central)", !isempty(zd) && zd[1]["covers_root"] == true)
println("    -> ", isempty(zd) ? "(none)" : zd[1])

resolver = ref -> CB._default_id_resolver(env, ref)
asm_id = CB.open_node_descriptors(env)[1]["id"]    # a valid AssemblyComplete node id string
println("\n[2] _parse_proposal with a ForbidZone JSON (assembly=$asm_id)")
payload_ok = JSON3.read(JSON3.write(Dict(
    "constraints" => [Dict("kind" => "ForbidZone", "zone" => "zone", "assembly" => asm_id)],
    "rationale" => "central zone blocks the build core")))
prop = CB._parse_proposal(payload_ok, "A no-go zone is active over the build core."; id_resolver=resolver)
check("parsed 1 constraint", length(prop.constraints) == 1)
check("constraint isa ForbidZone", !isempty(prop.constraints) && prop.constraints[1] isa CB.ForbidZone)
check("zone symbol == :zone", !isempty(prop.constraints) && prop.constraints[1].zone == :zone)
check("_is_zone_respec true", CB._is_zone_respec(prop))

println("\n[3] verify_zone — valid proposal admits")
v_ok = CB.verify_zone(prop, env)
check("verify_zone Admit", v_ok isa CB.Admit)

println("\n[4] verify_zone — unknown zone key rejects")
prop_badzone = CB.RespecProposal([CB.ForbidZone(resolver(asm_id), :ghost)], "x", "x")
v_bad = CB.verify_zone(prop_badzone, env)
check("verify_zone Reject(:no_such_zone)", v_bad isa CB.Reject && v_bad.reason == :no_such_zone)

println("\n[5] parser rejects an unknown assembly id (throws -> Reject upstream)")
threw = false
try
    CB._parse_proposal(JSON3.read(JSON3.write(Dict(
        "constraints" => [Dict("kind" => "ForbidZone", "zone" => "zone", "assembly" => "NOPE_999")]))),
        "x"; id_resolver=resolver)
catch
    threw = true
end
check("unknown assembly id throws", threw)

CB.clear_restriction_zones!()
println("\n==== ForbidZone parse/verify: $(npass[]) passed, $(nfail[]) failed ====")
nfail[] == 0 ? println("ALL GREEN") : println("SOME FAILED")
end

# =============================================================================
# replace_parse -- LLM-free unit test of the ReplaceAgent bridge+verify path (OOD 1-1 Part B
#   plumbing). Builds a fast geometry-only env (rvo off, no sim), registers a spare pool, then
#   exercises: open_agent_descriptors -> a fake /propose JSON with a ReplaceAgent ->
#   _parse_proposal -> verify_replace (admit), plus negative cases (no spare -> reject, unknown
#   agent id -> throw). No Python service, no nav build.
# =============================================================================
function test_replace_parse()
_setup_milp!(time_limit = 120.0)

println(">>> building fast geometry env (tractor, rvo off)...")
pp = CB.get_project_params(4)
env = run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Error,
        rvo_flag=false, tangent_bug_flag=false, dispersion_flag=false,
        open_animation_at_end=false, save_animation=false, write_results=false,
        overwrite_results=false, look_for_previous_milp_solution=false,
        save_milp_solution=false, return_env_before_sim=true)
end

npass = Ref(0); nfail = Ref(0)
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))

resolver = ref -> CB._default_id_resolver(env, ref)

println("\n[1] open_agent_descriptors exposes a faulted-robot grounding")
ad = CB.open_agent_descriptors(env)
check("at least one agent described", !isempty(ad))
agent_id = ad[1]["id"]                       # an exact RobotID string the spec must echo
println("    -> faulting agent id = $agent_id ; label = $(ad[1]["label"])")

println("\n[2] _parse_proposal with a ReplaceAgent JSON (agent=$agent_id)")
payload_ok = JSON3.read(JSON3.write(Dict(
    "constraints" => [Dict("kind" => "ReplaceAgent", "agent" => agent_id, "after" => 0.0)],
    "rationale" => "robot broke down; replace with nearest backup")))
prop = CB._parse_proposal(payload_ok, "Robot R1 has broken down; send a backup."; id_resolver=resolver)
check("parsed 1 constraint", length(prop.constraints) == 1)
check("constraint isa ReplaceAgent", !isempty(prop.constraints) && prop.constraints[1] isa CB.ReplaceAgent)
check("_is_robot_replace true", CB._is_robot_replace(prop))
check("NOT misclassified as robot fault (ForbidAgent path)", !CB._is_robot_fault(prop))

println("\n[3] verify_replace — spare available admits")
CB.clear_spare_pools!()
CB.register_spare!(:north, CB.get_unique_id(CB.RobotID))   # at least one parked spare
v_ok = CB.verify_replace(prop, env)
check("verify_replace Admit (spare present)", v_ok isa CB.Admit)

println("\n[4] verify_replace — no spare rejects")
CB.clear_spare_pools!()
v_nospare = CB.verify_replace(prop, env)
check("verify_replace Reject(:no_spare)", v_nospare isa CB.Reject && v_nospare.reason == :no_spare)

println("\n[5] unknown agent id is rejected at parse (fails closed)")
# Wrapped in a function so the try/catch uses clean local scope (top-level try/catch
# scoping is unreliable in scripts). Probe-verified: `_default_id_resolver` throws on an
# unknown robot id AND `ReplaceAgent(nothing,_)` is a MethodError, so an ungrounded agent
# can never become a valid spec — the parse fails closed before anything is dispatched.
function _parse_throws_on_bad_agent()
    try
        CB._parse_proposal(JSON3.read(JSON3.write(Dict(
            "constraints" => [Dict("kind" => "ReplaceAgent", "agent" => "NOPE_ROBOT_999", "after" => 0.0)]))),
            "x"; id_resolver = resolver)
        return false
    catch
        return true
    end
end
check("unknown agent id throws (fails closed at parse)", _parse_throws_on_bad_agent())

println("\n[6] referenced_ids(::ReplaceAgent) points at the faulted agent (static gate input)")
rid = first(CB.referenced_ids(prop.constraints[1]))
check("referenced_ids == the faulted agent", rid == resolver(agent_id))

CB.clear_spare_pools!()
println("\n==== ReplaceAgent parse/verify: $(npass[]) passed, $(nfail[]) failed ====")
nfail[] == 0 ? println("ALL GREEN") : println("SOME FAILED")
nfail[] == 0 || error("test_replace_parse had $(nfail[]) failure(s)")
end

# =============================================================================
# deprioritize_integration -- Integration verification of the TIER-2 DeprioritizeAgent on a
#   REAL env (no LLM): (1) verify_deprioritize ADMITS a real robot, REJECTS a non-existent /
#   closed one. (2) feasibility-PRESERVING: a re-solve with the agent biased stays FEASIBLE.
#   (3) it actually REROUTES: the biased robot does <= as much assignment work as baseline.
#   Builds ONE small env (greedy) and re-solves; mirrors the maybe_respecify! soft-dispatch
#   path without the LLM round-trip.
# =============================================================================
function test_deprioritize_integration()
value = JuMP.value
chk(c, m) = (c ? (PASS[] += 1) : (FAILN[] += 1; println("  FAIL: ", m)))

_setup_milp!(time_limit = 120.0, mip_rel_gap = 0.02)
CB.clear_agent_bias!(); CB.EDGE_COST_MULTIPLIER[] = nothing
CB.set_planning_objective_weights!(speed = 1.0, efficiency = 0.01)
CB.set_energy_model!(load_power = 0.25)

pp = CB.get_project_params(4)   # tractor
println(">>> building env (greedy)...")
env = run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots],
        assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
        log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false, dispersion_flag=false,
        open_animation_at_end=false, save_animation=false, save_animation_along_the_way=false,
        write_results=false, overwrite_results=false,
        look_for_previous_milp_solution=false, save_milp_solution=false, return_env_before_sim=true)
end
inv = CB.build_invariant(env)
CB.release_pending_assignments!(env, inv; faulted = nothing)
robots = sort([CB.node_id(n) for n in CB.get_nodes(env.scene_tree) if CB.matches_template(CB.RobotNode, n)]; by = r -> r.id)
R = robots[1]
println(">>> env built; $(length(robots)) robots; deprioritizing $(R)\n")

# count selected assignment edges OWNED by robot `rid` in a solved milp
function owned_edge_usage(milp, sched, rid)
    u = 0.0
    for ((v, v2), _) in CB.LAST_EDGE_COSTS[]
        CB._edge_owner_id(sched, v) == rid || continue
        try; u += value(milp.Xa[v, v2]); catch; end
    end
    return u
end

# (1) verify_deprioritize gate
println("== (1) verify_deprioritize: admit real robot, reject non-existent ==")
chk(CB.verify_deprioritize(CB.RespecProposal([CB.DeprioritizeAgent(R, 100.0)]), env) isa CB.Admit, "real robot admitted")
chk(CB.verify_deprioritize(CB.RespecProposal([CB.DeprioritizeAgent(CB.RobotID(999999), 100.0)]), env) isa CB.Reject, "fake robot rejected")

# (2) baseline solve (no bias)
println("== (2) baseline re-solve (no bias) ==")
CB.clear_agent_bias!()
milp0 = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
    optimizer = CB._respec_optimizer(), t0_ = inv.frozen_t0, tF_ = inv.frozen_tF)
CB.optimize!(milp0)
feas0 = JuMP.primal_status(milp0.model) == CB.MOI.FEASIBLE_POINT
usage0 = owned_edge_usage(milp0, env.sched, R)
ms0 = try maximum(value.(milp0.model[:tF])) catch; NaN end
chk(feas0, "baseline feasible")
println("   baseline: feasible=$feas0  R-edge-usage=$(round(usage0,digits=2))  makespan=$(round(ms0,digits=2))")

# (3) biased solve: feasibility preserved + R does <= work
println("== (3) deprioritize R (factor 1000, clamped) -> re-solve ==")
f = CB.deprioritize_agent!(R, 1000.0)
chk(f == CB.MAX_AGENT_COST_BIAS, "factor clamped to MAX")
milp1 = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
    optimizer = CB._respec_optimizer(), t0_ = inv.frozen_t0, tF_ = inv.frozen_tF)
CB.optimize!(milp1)
feas1 = JuMP.primal_status(milp1.model) == CB.MOI.FEASIBLE_POINT
usage1 = owned_edge_usage(milp1, env.sched, R)
ms1 = try maximum(value.(milp1.model[:tF])) catch; NaN end
chk(feas1, "feasibility PRESERVED after deprioritize (soft spec never stalls)")
chk(usage1 <= usage0 + 1e-6, "deprioritized robot does <= baseline assignment work ($(round(usage1,digits=2)) <= $(round(usage0,digits=2)))")
println("   biased:   feasible=$feas1  R-edge-usage=$(round(usage1,digits=2))  makespan=$(round(ms1,digits=2))")
CB.clear_agent_bias!()

println("\n== RESULT: $(PASS[]) passed, $(FAILN[]) failed ==")
exit(FAILN[] == 0 ? 0 : 1)
end

# =============================================================================
# battery_smoke -- OFFLINE smoke test for the energy-aware adaptive layer — NO env build, NO LLM.
#   Unit-tests the pure pieces of the navigator layer (loaded ONCE at module top):
#   battery power model · SoC->cost multiplier · metric wiring · OOD-stream scheduling.
# =============================================================================
function test_battery_smoke()
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
end

# =============================================================================
# battery_safety -- OFFLINE safety/verifiability test for the TIER-2 soft re-spec
#   (DeprioritizeAgent) and the AGENT_COST_BIAS objective-bias registry. NO env build, NO LLM.
#   Running it also PRECOMPILES the whole module, so it doubles as an integration check that the
#   spec_dsl/compiler/verifier/replan + essential_tg_coponents edits all load.
# =============================================================================
function test_battery_safety()
println("== closed-union: DeprioritizeAgent is a ConstraintSpec (LLM can only emit grammar) ==")
@check CB.DeprioritizeAgent <: CB.ConstraintSpec
r5 = CB.RobotID(5); r6 = CB.RobotID(6)
da = CB.DeprioritizeAgent(r5)
@check da.factor == 50.0                                  # default advisory severity
@check CB.referenced_ids(da) == (r5,)                     # grounding key for the closed-node check

println("== SAFETY: factor is CLAMPED to [1, MAX] (LLM cannot weaponize the knob) ==")
CB.clear_agent_bias!()
@check CB.agent_cost_bias(r5) == 1.0                      # unknown agent -> identity
@check CB.deprioritize_agent!(r5, 50.0) == 50.0          # in-range passes through
@check CB.agent_cost_bias(r5) == 50.0
@check CB.deprioritize_agent!(r5, 0.3) == 1.0            # < 1 clamped UP: can never INCENTIVIZE a robot
@check CB.deprioritize_agent!(r5, -100.0) == 1.0         # negative clamped: cannot invert the objective
@check CB.deprioritize_agent!(r5, 1.0e9) == CB.MAX_AGENT_COST_BIAS   # blowup clamped: numerical safety
@check CB.MAX_AGENT_COST_BIAS == 1.0e3
CB.clear_agent_bias!(r5)
@check CB.agent_cost_bias(r5) == 1.0                      # single-clear works
CB.deprioritize_agent!(r5, 10.0); CB.deprioritize_agent!(r6, 20.0)
@check length(CB.AGENT_COST_BIAS[]) == 2
CB.clear_agent_bias!()
@check isempty(CB.AGENT_COST_BIAS[])                      # global clear works

println("== SAFETY: feasibility-preserving BY CONSTRUCTION — compiles to ZERO hard constraints ==")
# The structural proof that a soft re-spec cannot shrink the feasible set / stall the build:
@check CB.compile_constraint!(nothing, nothing, nothing, nothing, nothing, da) == 0

println("== objective-bias composition: agent_bias × battery_fn, both default-identity ==")
CB.clear_agent_bias!(); CB.EDGE_COST_MULTIPLIER[] = nothing
@check CB.edge_cost_multiplier(nothing, 1) == 1.0        # both off -> edge_costs byte-for-byte unchanged
CB.EDGE_COST_MULTIPLIER[] = (s, v) -> 3.0                # stub battery fn
@check CB.edge_cost_multiplier(nothing, 1) == 3.0        # agent registry empty -> battery only
CB.EDGE_COST_MULTIPLIER[] = nothing                      # reset

println("== dispatch predicate: pure-soft proposals routed to the soft path ==")
@check CB._is_deprioritize(CB.RespecProposal([CB.DeprioritizeAgent(r5)]))
@check CB._is_deprioritize(CB.RespecProposal([CB.DeprioritizeAgent(r5), CB.DeprioritizeAgent(r6)]))
mixed = CB.RespecProposal(CB.ConstraintSpec[CB.DeprioritizeAgent(r5), CB.ForbidWindow(r5, 0.0, 1.0)])
@check !CB._is_deprioritize(mixed)                       # mixed -> NOT soft path (hard spec governs)
@check !CB._is_deprioritize(CB.RespecProposal(CB.ConstraintSpec[]))   # empty -> not soft
# a mixed proposal's DeprioritizeAgent is harmless on the generic compile path (no-op):
@check CB.compile_constraint!(nothing, nothing, nothing, nothing, nothing, mixed.constraints[1]) == 0

println("== LLM->Julia decode: _parse_proposal maps DeprioritizeAgent JSON -> typed spec ==")
resolver = s -> CB.RobotID(7)                            # trivial id resolver for the test
payload = Dict("constraints" => [Dict("kind" => "DeprioritizeAgent", "agent" => "RobotID(7)", "factor" => 80.0)],
               "rationale" => "battery low")
prop = CB._parse_proposal(payload, "R7 battery low"; id_resolver = resolver)
@check length(prop.constraints) == 1
@check prop.constraints[1] isa CB.DeprioritizeAgent
@check prop.constraints[1].agent == CB.RobotID(7)
@check prop.constraints[1].factor == 80.0
payload2 = Dict("constraints" => [Dict("kind" => "DeprioritizeAgent", "agent" => "RobotID(7)")], "rationale" => "")
@check CB._parse_proposal(payload2, "x"; id_resolver = resolver).constraints[1].factor == 50.0   # default
threw = Ref(false)
try CB._parse_proposal(Dict("constraints" => [Dict("kind" => "Sabotage")], "rationale" => ""), "x"; id_resolver = resolver)
catch; threw[] = true end
@check threw[]                                           # closed union: unknown kind throws on Julia side too

println("\n== RESULT: $(PASS[]) passed, $(FAILN[]) failed ==")
exit(FAILN[] == 0 ? 0 : 1)
end

# =============================================================================
# llm_classification -- Stage 3 REAL-LLM check: does the live service classify a natural-language
#   OOD event into the CORRECT DSL kind (ForbidZone / ForbidAgent / ForbidWindow) and ground it
#   onto valid ids? Turn-key: requires the Python service up and ANTHROPIC_API_KEY in THIS shell.
#     1) In a shell WITH your key (PowerShell):
#          cd src/respec/llm_service ; uvicorn server:app --host 127.0.0.1 --port 8000
#     2) In another shell WITH your key:
#          cd ConstructionBots.jl ; julia +lts --project=. tools/tests.jl llm_classification
#   (default RESPEC_SERVICE_URL is http://127.0.0.1:8000)
# =============================================================================
function test_llm_classification()
_setup_milp!(time_limit = 120.0)

if !CB.respec_service_ready()
    println("LLM service NOT reachable at ", get(ENV, "RESPEC_SERVICE_URL", "http://127.0.0.1:8000"))
    println("Start it first:  cd src/respec/llm_service ; uvicorn server:app --port 8000   (in a shell with ANTHROPIC_API_KEY)")
    exit(1)
end
println(">>> service ready. building fast env (tractor, rvo off)...")
pp = CB.get_project_params(4)
env = run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Error,
        rvo_flag=false, tangent_bug_flag=false, dispersion_flag=false,
        open_animation_at_end=false, save_animation=false, write_results=false,
        overwrite_results=false, look_for_previous_milp_solution=false,
        save_milp_solution=false, return_env_before_sim=true)
end

# inject a central zone so the zones-descriptor is non-empty (a real spatial OOD)
gs = CB.root_deposit_goals(env)
zc = isempty(gs) ? [1.5, 0.96] : sum(gs) ./ length(gs)
CB.clear_restriction_zones!(); CB.add_restriction_zone!(:zone, zc, 2.5)

resolver = ref -> CB._default_id_resolver(env, ref)
kind_of(p) = isempty(p.constraints) ? :none : typeof(p.constraints[1]).name.name

cases = [
    ("A safety exclusion zone is now active over the central build area; robots must not enter or pass through it.", :ForbidZone),
    ("Robot R2 has broken down and can no longer move; take it out of service.", :ForbidAgent),
    ("The final assembly must not be worked on during the interval t=40 to t=70.", :ForbidWindow),
]
npass = 0
println("\n==== LLM classification ====")
for (event, want) in cases
    got = :error
    try
        p = CB.llm_to_proposal(event, env; id_resolver = resolver)
        got = kind_of(p)
    catch e
        got = Symbol("error:", typeof(e).name.name)
    end
    ok = got == want
    ok && (npass += 1)
    println(ok ? "  PASS" : "  FAIL", "  want=$want got=$got")
    println("        event: ", first(event, 70), "...")
end
CB.clear_restriction_zones!()
println("\n$(npass)/$(length(cases)) classified correctly")
println(npass == length(cases) ? "ALL GREEN" : "SOME MISCLASSIFIED")
end

# ---- dispatcher -------------------------------------------------------------
const TESTS = Dict(
    "forbidzone_parse"         => test_forbidzone_parse,
    "replace_parse"            => test_replace_parse,
    "deprioritize_integration" => test_deprioritize_integration,
    "battery_smoke"            => test_battery_smoke,
    "battery_safety"           => test_battery_safety,
    "llm_classification"       => test_llm_classification,
)
end # module Tests

if abspath(PROGRAM_FILE) == @__FILE__
    key = get(ENV, "TEST", isempty(ARGS) ? "forbidzone_parse" : ARGS[1])
    haskey(Tests.TESTS, key) || error("unknown test '$key'. Available: $(join(sort(collect(keys(Tests.TESTS))), ", "))")
    println(">>> running test: $key")
    Tests.TESTS[key]()
end
