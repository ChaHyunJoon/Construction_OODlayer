# =============================================================================
# test_llm_classification.jl -- Stage 3 REAL-LLM check: does the live service classify a
# natural-language OOD event into the CORRECT DSL kind (ForbidZone / ForbidAgent /
# ForbidWindow) and ground it onto valid ids? Turn-key: requires the Python service up and
# ANTHROPIC_API_KEY in THIS shell.
#
# 1) In a shell WITH your key (PowerShell):
#      cd src/respec/llm_service ; uvicorn server:app --host 127.0.0.1 --port 8000
# 2) In another shell WITH your key:
#      cd ConstructionBots.jl ; julia +lts --project=. tools/test_llm_classification.jl
# (default RESPEC_SERVICE_URL is http://127.0.0.1:8000)
# =============================================================================
using ConstructionBots
import Logging, HiGHS, LinearAlgebra
const CB = ConstructionBots

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
