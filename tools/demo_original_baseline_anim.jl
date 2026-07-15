# =============================================================================
# demo_original_baseline_anim.jl -- the ORIGINAL SISL ConstructionBots demo, unchanged.
#
# This is a faithful copy of `scripts/demos.jl` (the upstream SISL example driver): a PLAIN
# run_lego_demo build of the tractor with the full nav stack (RVO + TangentBug + dispersion),
# greedy assignment, and NOTHING ELSE -- no OOD, no forbid/restriction zone, no respec, no
# fault, no spare pools. It just builds the model start to finish, exactly like the original
# repo. The only deviations from scripts/demos.jl are operational, not behavioural:
#   * save_animation=true, open_animation_at_end=false  (so we get a saved HTML for the deck
#     instead of only auto-opening a browser)
#   * project_name pinned to "tractor" (avoid the results/tractor.mpd/ wrong-file trap)
# So the resulting clip is the vanilla ConstructionBots simulation, the "before" in the
# evolution story (V1), with the LLM-respec / zone-recovery machinery entirely absent.
#
# Run (PowerShell):
#   cd C:\Users\chahj\PythonCodes\venv\ConstructionBots.jl
#   julia +lts --project=. tools/demo_original_baseline_anim.jl
# =============================================================================
using ConstructionBots
import HiGHS
const CB = ConstructionBots

const OPEN_ANIM = get(ENV, "OPEN_ANIM", "1") == "1"   # set OPEN_ANIM=0 to only save the HTML

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!(
    "time_limit" => 300.0, "presolve" => "on", "mip_rel_gap" => 5.0, CB.MOI.Silent() => true)

# hygiene: make sure no OOD/zone/respec state leaks in from a shared session (fresh process anyway)
CB.clear_ood_schedule!(); CB.clear_restriction_zones!()

project_params = CB.get_project_params(4)   # 4 = tractor (same as scripts/demos.jl)

println(">>> ORIGINAL SISL ConstructionBots demo: project=$(project_params[:project_name]) " *
        "(plain build, NO OOD / NO respec)")
println(">>> building + simulating with FULL NAV + ANIMATION (slow; HTML saved at end)...")

env, stats = CB.run_lego_demo(;
    ldraw_file=project_params[:file_name],
    project_name=project_params[:project_name],
    model_scale=project_params[:model_scale],
    num_robots=project_params[:num_robots],
    assignment_mode=:greedy,
    milp_optimizer=:highs,
    optimizer_time_limit=60,
    rvo_flag=true,
    tangent_bug_flag=true,
    dispersion_flag=true,
    # --- animation ON (save; do not auto-open unless OPEN_ANIM=1) ---
    open_animation_at_end=OPEN_ANIM,
    save_animation=true,
    save_animation_along_the_way=false,
    anim_active_agents=true,
    anim_active_areas=true,
    update_anim_at_every_step=true,
    save_anim_interval=100,
    process_updates_interval=100,
    block_save_anim=false,
    # --- housekeeping ---
    write_results=false,
    overwrite_results=true,
    look_for_previous_milp_solution=false,
    save_milp_solution=false,
    previous_found_optimizer_time=30,
    max_num_iters_no_progress=2500,
    stop_after_task_assignment=false,
);

htmlpath = joinpath("results", project_params[:project_name], "greedy_RVO_Dispersion_TangentBug", "visualization.html")
println(">>> done. Animation saved: $htmlpath")
