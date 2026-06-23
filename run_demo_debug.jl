# Debug runner: runs the demo DIRECTLY (no run_with_stack task wrapper) so that
# pressing Ctrl+C while it is stuck prints the backtrace of the *actual* runaway
# loop. Uses the lightest model (colored_8x8), visualizer OFF to keep it minimal.
#
# Usage:
#   julia +lts --project=. .\run_demo_debug.jl
# When it stalls (CPU pegged, no new output for a while), press Ctrl+C ONCE and
# copy the entire backtrace it prints.

using ConstructionBots

project_params = get_project_params(1)   # colored_8x8 (가장 가벼움)

env, stats = run_lego_demo(;
    ldraw_file=project_params[:file_name],
    project_name=project_params[:project_name],
    model_scale=project_params[:model_scale],
    num_robots=project_params[:num_robots],
    assignment_mode=:greedy,
    milp_optimizer=:highs,
    optimizer_time_limit=60,
    rvo_flag=false,
    tangent_bug_flag=false,
    dispersion_flag=false,
    open_animation_at_end=false,
    save_animation=false,
    save_animation_along_the_way=false,
    anim_active_agents=false,
    anim_active_areas=false,
    update_anim_at_every_step=false,
    save_anim_interval=100,
    process_updates_interval=100,
    block_save_anim=false,
    write_results=false,
    overwrite_results=false,
    look_for_previous_milp_solution=false,
    save_milp_solution=false,
    previous_found_optimizer_time=30,
    max_num_iters_no_progress=2500,
    stop_after_task_assignment=false,
)

println("DEMO_DONE")
