# =============================================================================
# run_zone_demo.jl  --  Full-render visual check of OOD 1-2 (restriction zone).
#
# Builds the tractor demo with the FULL motion stack (rvo + tangent_bug +
# dispersion) and RENDER on, schedules a navigation no-go zone to be injected
# mid-sim, and opens a MeshCat animation in the browser so you can SEE the robots
# detour around the (red-disc) zone. RESPEC is NOT enabled, so this isolates the
# physical/navigation effect: the zone is a static obstacle the TangentBug layer
# routes around — no LLM, no schedule re-solve.
#
# Run:
#     julia +lts --project=. tools/run_zone_demo.jl
#
# Tuning (edit below): INJECT_STEP (when the zone appears) and the zone seed /
# placement. If the zone happens to sit on top of a goal and stalls the build,
# bump the seed or shrink the radius.
# =============================================================================
using ConstructionBots
const CB = ConstructionBots
import Logging

# ---- when to inject, and the zone to inject --------------------------------
const INJECT_STEP = 150          # sim step at which the no-go zone appears

CB.clear_ood_schedule!()
CB.clear_restriction_zones!()
CB.clear_zone_markers!()

CB.schedule_ood!(INJECT_STEP, function (env)
    # Place a random no-go zone within the current activity area (seeded =
    # reproducible). Swap for an explicit placement if you want a fixed spot:
    #     z = CB.add_restriction_zone!(:demo, [x, y], r)
    z, nl = CB.random_restriction_zone!(env; key = :demo, seed = 7)
    @info "[OOD] restriction zone injected" center=CB.get_center(z) radius=CB.get_radius(z)
    return nl     # enqueued for respec (a no-op here: RESPEC disabled). Detour is physical.
end)

# ---- build + simulate with full motion stack and render --------------------
pp = CB.get_project_params(4)    # tractor

CB.run_lego_demo(;
    ldraw_file   = pp[:file_name],
    project_name = pp[:project_name],
    model_scale  = pp[:model_scale],
    num_robots   = pp[:num_robots],
    assignment_mode      = :greedy,
    rvo_flag             = true,
    tangent_bug_flag     = true,
    dispersion_flag      = true,
    open_animation_at_end = true,    # opens the MeshCat animation in the browser
    save_animation        = true,
    write_results         = false,
    overwrite_results     = false,
    log_level             = Logging.Warn,
)

println(">>> done. The red disc is the injected no-go zone; watch robots route around it.")
