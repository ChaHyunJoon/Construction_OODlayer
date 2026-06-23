using ConstructionBots

# --- Run a function on a task with an explicit, large C stack. ---
# The transform-tree propagation in ConstructionBots recurses very deeply
# (deeper than the ~256 MB default task stack on Windows), so we give it room.
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
        showerror(stderr, e, bt)
        println(stderr)
        rethrow(e)
    end
    return result[]
end

project_params = get_project_params(9)   # x_wing (309 parts x 28 assemblies) — README large example, ~minutes

open_animation_at_end = true
save_animation_along_the_way = false
save_animation_at_end = false
anim_active_agents = true
anim_active_areas = true

update_anim_at_every_step = false   # fast: record only at node completions (big models). true = smooth motion/RVO but very slow
save_anim_interval = 100
process_updates_interval = 100
block_save_anim = false

tangent_bug_flag = true
rvo_flag = true
dispersion_flag = true
assignment_mode = :milp_w_greedy_warm_start   # at_te_walker(N=9) needs MILP warm-start; pure :greedy deadlocks
milp_optimizer = :highs
optimizer_time_limit = 60

env, stats = run_with_stack(4_000_000_000) do
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
