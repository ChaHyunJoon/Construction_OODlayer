using ConstructionBots

# Run f() on a task with a large C stack (avoids StackOverflow in deep transform recursion).
function run_with_stack(f, stacksize::Int)
    result = Ref{Any}(nothing)
    err = Ref{Any}(nothing)
    done = Threads.Atomic{Bool}(false)
    wrapper = function ()
        try
            result[] = f()
        catch e
            err[] = (e, catch_backtrace())
        finally
            done[] = true
        end
    end
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int), wrapper, nothing, stacksize)
    t.sticky = false
    schedule(t)
    while !done[]
        sleep(0.05)
    end
    if err[] !== nothing
        e, bt = err[]
        showerror(stderr, e, bt); println(stderr)
        rethrow(e)
    end
    return result[]
end

project_params = get_project_params(4)   # tractor (원래 목표 모델) — 1로 바꾸면 colored_8x8

# --- FAST settings: physics/collision-avoidance OFF -> agents move in straight lines,
#     simulation finishes quickly, assembly animation still produced. ---
open_animation_at_end = true
save_animation_at_end = true              # also save a standalone HTML
save_animation_along_the_way = false
anim_active_agents = true
anim_active_areas = true

update_anim_at_every_step = true   # record a frame every sim step -> smooth, plenty of keyframes
save_anim_interval = 100
process_updates_interval = 100
block_save_anim = false

tangent_bug_flag = false
rvo_flag = false
dispersion_flag = false
assignment_mode = :greedy
milp_optimizer = :highs
optimizer_time_limit = 60

env, stats = run_with_stack(2_000_000_000) do
    run_lego_demo(;
        ldraw_file=project_params[:file_name],
        project_name=project_params[:project_name],
        model_scale=project_params[:model_scale],
        num_robots=project_params[:num_robots],
        assignment_mode=assignment_mode,
        milp_optimizer=milp_optimizer,
        optimizer_time_limit=optimizer_time_limit,
        rvo_flag=rvo_flag,
        tangent_bug_flag=tangent_bug_flag,
        dispersion_flag=dispersion_flag,
        open_animation_at_end=open_animation_at_end,
        save_animation=save_animation_at_end,
        save_animation_along_the_way=save_animation_along_the_way,
        anim_active_agents=anim_active_agents,
        anim_active_areas=anim_active_areas,
        update_anim_at_every_step=update_anim_at_every_step,
        save_anim_interval=save_anim_interval,
        process_updates_interval=process_updates_interval,
        block_save_anim=block_save_anim,
        write_results=false,
        overwrite_results=false,
        look_for_previous_milp_solution=false,
        save_milp_solution=false,
        previous_found_optimizer_time=30,
        max_num_iters_no_progress=2500,
        stop_after_task_assignment=false,
    )
end

println("DEMO_DONE")

# Keep the process (and the MeshCat server) alive so the live visualizer stays
# reachable. The live server fully supports animation playback (play/slider),
# unlike the exported static HTML. View at http://127.0.0.1:8700, open the
# controls (top-right), expand "Animations", and press play.
println("\n=== Visualizer is LIVE at http://127.0.0.1:8700 ===")
println("Open Controls (top-right) -> Animations -> play to watch the assembly.")
println("Press Enter in THIS window to quit and shut down the visualizer.")
readline()
