# =============================================================================
# test_forbidzone_parse.jl -- LLM-free unit test of the ForbidZone bridge+verify path
# (Stage 1). Builds a fast geometry-only env (rvo off, no sim), injects a CENTRAL zone,
# then exercises: open_zone_descriptors -> a fake /propose JSON with a ForbidZone ->
# _parse_proposal -> verify_zone (admit), plus negative cases (bad zone key, bad id).
# No Python service, no nav build. Run: julia +lts --project=. tools/test_forbidzone_parse.jl
# =============================================================================
using ConstructionBots
import Logging, HiGHS, JSON3, LinearAlgebra
const CB = ConstructionBots
const norm = LinearAlgebra.norm

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 120.0, "presolve" => "on",
    "mip_rel_gap" => 5.0, CB.MOI.Silent() => true)

function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))
    return res[]
end

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
