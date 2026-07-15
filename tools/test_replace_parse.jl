# =============================================================================
# test_replace_parse.jl -- LLM-free unit test of the ReplaceAgent bridge+verify path
# (OOD 1-1 Part B plumbing). Builds a fast geometry-only env (rvo off, no sim),
# registers a spare pool, then exercises: open_agent_descriptors -> a fake /propose
# JSON with a ReplaceAgent -> _parse_proposal -> verify_replace (admit), plus
# negative cases (no spare -> reject, unknown agent id -> throw). No Python service,
# no nav build. Run: julia +lts --project=. tools/test_replace_parse.jl
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
