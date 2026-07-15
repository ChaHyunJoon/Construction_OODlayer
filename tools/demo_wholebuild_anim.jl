# =============================================================================
# demo_wholebuild_anim.jl -- VISUAL (MeshCat browser) demo of whole-build translation.
#
# Runs the REAL run_lego_demo with the full nav stack + animation ON. Via the OOD seam
# (schedule_ood!), at step OOD_STEP it: drops a CENTRAL forbid zone over the root core,
# tries per-assembly restage_all (-> residual_blocked, can't clear root goals), then
# translate_whole_build! to shift the ENTIRE build clear of the zone. The animation
# records the whole thing: build proceeds -> red zone appears -> build teleports to
# empty space -> robots finish there, never re-entering the zone.
#
# The OOD action returns `nothing` so it does NOT enter the (incomplete) LLM respec
# path -- it drives the geometric recovery directly.
#
# Run (PowerShell):
#   cd C:\Users\chahj\PythonCodes\venv\ConstructionBots.jl
#   $env:OOD_STEP="200"; $env:NAVON_ZONE_R="2.5"; julia +lts --project=. tools/demo_wholebuild_anim.jl
# A browser tab opens at the end with the playable animation.
# =============================================================================
using ConstructionBots
import Logging, HiGHS, LinearAlgebra
const CB = ConstructionBots
const norm = LinearAlgebra.norm

const PROJECT  = parse(Int, get(ENV, "NAVON_PROJECT", "4"))      # 4 = tractor
# Inject EARLY (default 5): translate_whole_build! is an MVP that only relocates a build
# whose parts are not yet IN TRANSPORT. step_1_closed≈45 trivial nodes close at iter 1, so
# iter~5 ≈ the headless-validated closed=46 state (nothing carried yet). Larger OOD_STEP
# injects mid-transport and the moved deposit slots desync in-flight cargo -> capture assert.
const OOD_STEP = parse(Int, get(ENV, "OOD_STEP", "5"))           # sim step to drop the zone + recover
const ZONE_R   = parse(Float64, get(ENV, "NAVON_ZONE_R", "2.5")) # central zone radius (covers root core)
const OPEN_ANIM = get(ENV, "OPEN_ANIM", "1") == "1"             # open browser at end (set OPEN_ANIM=0 to only save HTML)
const GRID_SCALE = parse(Float64, get(ENV, "GRID_SCALE", "4.0")) # widen MeshCat default floor grid (cosmetic) so the relocated build stays on-grid

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
    if err[] !== nothing
        e, bt = err[]; showerror(stderr, e, bt); println(stderr); throw(e)
    end
    return result[]
end

# The OOD action: drop the central zone, then geometric recovery. Returns `nothing`
# (skip the LLM respec path -- we drive restage/whole-build directly).
function ood_recover!(env)
    gs = CB.root_deposit_goals(env)
    rootc = Vector{Float64}(CB.get_center(
        env.staging_circles[argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))])[1:2])
    zc = isempty(gs) ? rootc : sum(gs) ./ length(gs)
    CB.add_restriction_zone!(:block, zc, ZONE_R)
    @info "[DEMO] OOD @ step $OOD_STEP: central zone@$(round.(zc;digits=2)) R=$ZONE_R (root@$(round.(rootc;digits=2)))"
    ra = CB.restage_all_blocked!(env; resume=true, verbose=true)
    @info "[DEMO] restage_all -> $(ra.status) (residual $(get(ra,:residual,-1)))"
    if ra.status == :residual_blocked
        wb = CB.translate_whole_build!(env; resume=true, verbose=true)
        @info "[DEMO] translate_whole_build! -> $(wb.status) Δ=$(get(wb,:delta,nothing)) residual=$(get(wb,:residual,-1))"
    elseif ra.status in (:restaged_all, :none)
        @info "[DEMO] zone cleared by per-assembly restage alone ($(ra.status)) -- no whole-build needed"
    end
    return nothing
end

CB.clear_ood_schedule!(); CB.clear_restriction_zones!()   # hygiene (fresh process anyway)
CB.schedule_ood!(OOD_STEP, ood_recover!)

pp = CB.get_project_params(PROJECT)
println(">>> VISUAL whole-build demo: project=$(pp[:project_name]) OOD_STEP=$OOD_STEP zone_R=$ZONE_R")
println(">>> building + simulating with FULL NAV + ANIMATION (slow; browser opens at end)...")

run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots],
        assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
        log_level=Logging.Info, rvo_flag=true, tangent_bug_flag=true, dispersion_flag=true,
        # --- animation ON ---
        save_animation=true, open_animation_at_end=OPEN_ANIM, update_anim_at_every_step=true,
        anim_active_agents=true, anim_active_areas=true, grid_scale=GRID_SCALE,
        # --- housekeeping ---
        save_animation_along_the_way=false, write_results=false, overwrite_results=true,
        look_for_previous_milp_solution=false, save_milp_solution=false,
        return_env_before_sim=false)
end
println(">>> done. The browser tab shows the animation (press the play arrow, bottom-right).")
