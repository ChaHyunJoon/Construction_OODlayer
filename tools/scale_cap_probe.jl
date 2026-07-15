# =============================================================================
# scale_cap_probe.jl -- per-project, per-scale measurement of the "root-clear cap"
# (max distance from any relocatable sub-assembly's staging center to the nearest
# UN-RELOCATABLE root deposit goal). This is the geometric quantity that decides
# whether a meaningful forbid zone can ever be restage-recovered.
#
# Pure geometry: rvo OFF, NO sim warmup (return_env_before_sim) -> fast. We only
# build the scene/schedule/staging plan, then read staging_circles + root goals.
#
# Run:  julia +lts --project=. tools/scale_cap_probe.jl
#   PROBE_PROJECTS="4,5,6"  PROBE_MULTS="1,2,3,4"   (defaults below)
# =============================================================================
using ConstructionBots
import Logging, HiGHS, LinearAlgebra
const CB = ConstructionBots
const norm = LinearAlgebra.norm

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!(
    "time_limit" => 300.0, "presolve" => "on", "mip_rel_gap" => 5.0, CB.MOI.Silent() => true)

function run_with_stack(f, stacksize::Int)
    result = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    wrapper = () -> (try result[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int), wrapper, nothing, stacksize)
    t.sticky = false; schedule(t)
    while !done[]; sleep(0.05); end
    err[] !== nothing && rethrow(err[][1])
    return result[]
end

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

const PROJECTS = parse.(Int, split(get(ENV, "PROBE_PROJECTS", "4,5,6"), ","))
const MULTS    = parse.(Float64, split(get(ENV, "PROBE_MULTS", "1,2,3,4"), ","))
const RR = Float64(CB.default_robot_radius())
const TARGET_CAP = 1.5   # want a zone of ~1 robot radius to fit with margin

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
