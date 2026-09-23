# =============================================================================
# zone_facts.jl — 존의 **관측 사실**만(2026-09-23, 존 복구 base ablation 명세 §4).
#   zone_diagnosis 의 센서 절(0·1·2·3·3b·3c)과 같은 계산이고, 해법 산출(feasible·relocate_*·verdict)은
#   없다. 해법기(find_clear_staging_center·_find_min_translation)를 **부르지 않는다** — 그래서 모든 ablation
#   팔에서 광고할 수 있다. 동등성은 test/zone_facts_is_sensor_only.jl 이 zone_diagnosis 와 필드째 고정한다.
# =============================================================================

"""
    zone_facts(env, zone; margin, check_teams=true, check_blockage=true, check_paths) -> NamedTuple

What an active no-go zone covers and blocks, as measured facts only (no repair suggestion).

| field | meaning |
|---|---|
| `center`, `radius` | the zone's geometry |
| `blocked` / `n_blocked` | assemblies that are not the root, have not started, and whose staging area the zone overlaps |
| `root_covered` / `root_total` / `root_frac` | root deposit goals inside the zone |
| `n_work_overlap` | unfinished work discs overlapping the zone |
| `teams` / `n_teams_forming` / `n_teams_covered` | forming transport teams and how many must gather inside the zone |
| `n_nav_goals`, `n_nav_engulfed`, `n_nav_disconnected`, `n_nav_blocked`, `n_nav_downstream`, `n_agent_trapped` | navigation blockage, as in `zone_blockage` (`-1` if not computed) |
| `n_completion_blocked` / `n_completion_open` / `project_blocked` | whether completion is blocked (`nothing` if not computed) |
"""
function zone_facts(env, zone::Symbol;
        margin::Float64 = default_robot_radius(),
        check_teams::Bool = true,
        check_blockage::Bool = true,
        check_paths::Bool = get(ENV, "ZONE_CHECK_PATHS", "0") == "1")
    if !haskey(RESTRICTION_ZONES[], zone)
        return (zone = zone, exists = false, center = nothing, radius = 0.0,
                blocked = AbstractID[], n_blocked = 0,
                root_covered = 0, root_total = 0, root_frac = 0.0,
                n_work_overlap = 0,
                teams = NamedTuple[], n_teams_forming = 0, n_teams_covered = 0,
                n_nav_goals = 0, n_nav_blocked = 0, n_nav_engulfed = 0,
                n_nav_disconnected = 0, n_agent_trapped = 0, n_nav_downstream = 0,
                n_completion_blocked = nothing, n_completion_open = nothing,
                project_blocked = nothing)
    end
    ball = RESTRICTION_ZONES[][zone]
    zc = Vector{Float64}(get_center(ball)[1:2])
    zr = Float64(get_radius(ball))
    blocked = try
        zone_blocked_assemblies(env; zone_keys = [zone], margin = margin)
    catch e
        @warn "[ZONE-FACTS] zone_blocked_assemblies failed for :$(zone)" exception = e
        AbstractID[]
    end
    rc = try
        root_goal_coverage(zc, zr, env)
    catch e
        @warn "[ZONE-FACTS] root_goal_coverage failed for :$(zone)" exception = e
        (covered = 0, total = 0, frac = 0.0)
    end
    n_overlap = try
        _count_future_work_overlaps(env; zone_keys = [zone])
    catch e
        @warn "[ZONE-FACTS] _count_future_work_overlaps failed for :$(zone)" exception = e
        0
    end
    teams = check_teams ? zone_team_coverage(env, zc, zr; margin = margin) : NamedTuple[]
    blk = check_blockage ?
        (try zone_blockage(env; zone_keys = [zone], check_paths = check_paths)
         catch e
            @warn "[ZONE-FACTS] zone_blockage failed for :$(zone)" exception = e
            nothing
         end) : nothing
    return (zone = zone, exists = true, center = zc, radius = zr,
            blocked = blocked, n_blocked = length(blocked),
            root_covered = rc.covered, root_total = rc.total, root_frac = rc.frac,
            n_work_overlap = n_overlap,
            teams = teams, n_teams_forming = length(teams),
            n_teams_covered = count(t -> t.covered, teams),
            n_nav_goals = blk === nothing ? -1 : blk.n_nav_goals,
            n_nav_blocked = blk === nothing ? -1 : blk.n_blocked,
            n_nav_engulfed = blk === nothing ? -1 : blk.n_engulfed,
            n_nav_disconnected = blk === nothing ? -1 : blk.n_disconnected,
            n_agent_trapped = blk === nothing ? -1 : blk.n_agent_trapped,
            n_nav_downstream = blk === nothing ? -1 : blk.n_downstream,
            n_completion_blocked = blk === nothing ? nothing : blk.n_completion_blocked,
            n_completion_open = blk === nothing ? nothing : blk.n_completion_open,
            project_blocked = blk === nothing ? nothing : blk.project_blocked)
end
