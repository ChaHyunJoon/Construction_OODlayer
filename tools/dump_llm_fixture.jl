# =============================================================================
# dump_llm_fixture.jl  --  Build the tractor env ONCE, step to mid-build, and dump
# the EXACT /propose request body (open_ids, agents, nodes) + a sub-assembly id map
# to JSON, so the Python prompt harness (tools/translate_eval.py) can iterate on the
# LLM translation WITHOUT rebuilding the env or touching Julia.
#
#   julia +lts --project=. tools/dump_llm_fixture.jl
#
# Output: tools/llm_fixture.json  (PLAIN JSON — safe to cache across processes, unlike
# the PlannerEnv itself, whose serialize round-trip corrupts cached transforms; see
# docs/timing_respec_persistence_gap_2026-06-19.md). Re-run only when the env build,
# the stepping, or the descriptor functions (llm_bridge.jl) change.
# =============================================================================
using ConstructionBots
import Graphs
import Logging
import JSON3
const CB = ConstructionBots

# 2GB-stack task: the deep transform-tree recursion overflows the default stack.
function run_with_stack(f, stacksize::Int)
    result = Ref{Any}(nothing); err = Ref{Any}(nothing)
    done = Threads.Atomic{Bool}(false)
    wrapper = function ()
        try result[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end
    end
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int), wrapper, nothing, stacksize)
    t.sticky = false; schedule(t)
    while !done[]; sleep(0.05); end
    if err[] !== nothing
        e, bt = err[]; showerror(stderr, e, bt); println(stderr); rethrow(e)
    end
    return result[]
end

println(">>> building tractor env (assignment only)...")
pp = CB.get_project_params(4)
env = run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots],
        assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
        log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false,
        dispersion_flag=false, open_animation_at_end=false, save_animation=false,
        save_animation_along_the_way=false, write_results=false,
        overwrite_results=false, look_for_previous_milp_solution=false,
        save_milp_solution=false, return_env_before_sim=true)
end
println(">>> env: $(Graphs.nv(env.sched)) nodes")

# Step into a mid-build state (mirror eval_respec_ood.jl main): closed>=8 so the
# precede/zone milestones are partially realized — the state translation runs in.
for _ in 1:4000
    CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
    length(env.cache.closed_set) >= 8 && break
end
println(">>> stepped: closed=$(length(env.cache.closed_set))")

# The EXACT /propose request body the production llm_to_proposal would send.
open_ids = CB.open_node_id_strings(env)
agents   = CB.open_agent_descriptors(env)
nodes    = CB.open_node_descriptors(env)

# sub-assembly AssemblyID.id -> exact node id string, so the Python eval cases can
# say "sub-assembly 2" and know the gold target id with NO Julia at eval time.
asm_map = Dict{String,String}()
for v in Graphs.vertices(env.sched)
    v in env.cache.closed_set && continue
    node = CB.get_node(env.sched, v).node
    node isa CB.AssemblyComplete || continue
    aid = try CB.entity(node).id catch; nothing end
    aid === nothing && continue
    asm_map[string(aid.id)] = string(CB.get_vtx_id(env.sched, v))
end

fixture = Dict(
    "open_ids" => open_ids,
    "agents"   => agents,
    "nodes"    => nodes,
    "sub_assembly_id_to_node_id" => asm_map,
    "closed_count" => length(env.cache.closed_set),
    "n_sched_nodes" => Graphs.nv(env.sched),
)
out = joinpath(@__DIR__, "llm_fixture.json")
open(out, "w") do io; JSON3.pretty(io, fixture); end
println(">>> wrote $out")
println("    open_ids=$(length(open_ids)) agents=$(length(agents)) nodes=$(length(nodes)) sub_asm=$(length(asm_map))")
