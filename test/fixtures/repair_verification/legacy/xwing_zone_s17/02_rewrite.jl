function relocate_inaccessible_work_areas!(env;)
    zonepairs = collect(active_restriction_zones())
    isempty(zonepairs) && error("no active restriction zone is available")
    zonekeys = [first(p) for p in zonepairs]
    zoneballs = [last(p) for p in zonepairs]

    initial = zone_blockage(env; zone_keys = zonekeys, check_paths = true)
    blocked_entries = Any[initial.blocked...]

    if isempty(blocked_entries)
        for (v, sn) in enumerate(env.sched.nodes)
            v in env.cache.closed_set && continue

            cfg = try
                goal_config(sn)
            catch
                continue
            end
            cfg isa TransformNode || continue

            startcfg = try
                start_config(sn)
            catch
                continue
            end
            startcfg isa TransformNode || continue

            cmd = try
                get_cmd(sn.node, env)
            catch
                continue
            end
            cmd isa Twist || continue

            radius = try
                Float64(agent_disc_radius(entity(sn)))
            catch
                continue
            end

            starttf = global_transform(startcfg)
            goaltf = global_transform(cfg)
            hasproperty(starttf, :translation) || continue
            hasproperty(goaltf, :translation) || continue
            startpos = Vector{Float64}(getproperty(starttf, :translation))
            goalpos = Vector{Float64}(getproperty(goaltf, :translation))
            length(startpos) >= 2 || continue
            length(goalpos) >= 2 || continue

            clear_status = free_space_status(startpos[1:2], startpos[1:2],
                                             zoneballs, radius)
            goal_status = free_space_status(startpos[1:2], goalpos[1:2],
                                            zoneballs, radius)
            goal_status == clear_status && continue

            push!(blocked_entries,
                  (; id = sn.id, kind = :navigation,
                     status = goal_status, vtx = v))
        end
    end

    isempty(blocked_entries) &&
        error("no unreachable unfinished navigation goal was found")

    zoneinfo = NamedTuple[]
    for key in zonekeys
        facts = zone_facts(env, key; check_teams = false,
                           check_blockage = false, check_paths = false)
        facts.exists || continue
        push!(zoneinfo,
              (; center = Vector{Float64}(facts.center)[1:2],
                 radius = Float64(facts.radius)))
    end
    isempty(zoneinfo) &&
        error("active zones could not be resolved geometrically")

    jobs = NamedTuple[]
    seen_configs = Set{Any}()
    for blocked in blocked_entries
        v = blocked.vtx
        v in env.cache.closed_set && continue
        sn = env.sched.nodes[v]

        cfg = try
            goal_config(sn)
        catch
            continue
        end
        cfg isa TransformNode || continue
        cfg.id in seen_configs && continue

        startcfg = try
            start_config(sn)
        catch
            continue
        end
        startcfg isa TransformNode || continue

        cmd = try
            get_cmd(sn.node, env)
        catch
            continue
        end
        cmd isa Twist || continue

        radius = try
            Float64(agent_disc_radius(entity(sn)))
        catch
            continue
        end

        oldtf = global_transform(cfg)
        starttf = global_transform(startcfg)
        hasproperty(oldtf, :translation) ||
            error("goal transform does not expose a translatable affine position")
        hasproperty(starttf, :translation) ||
            error("start transform does not expose a translatable affine position")
        oldpos = Vector{Float64}(getproperty(oldtf, :translation))
        startpos = Vector{Float64}(getproperty(starttf, :translation))
        length(oldpos) >= 2 ||
            error("goal transform has fewer than two spatial dimensions")
        length(startpos) >= 2 ||
            error("start transform has fewer than two spatial dimensions")

        startxy = startpos[1:2]
        clear_status = free_space_status(startxy, startxy, zoneballs, radius)

        push!(seen_configs, cfg.id)
        push!(jobs,
              (; blocked_id = blocked.id, cfg, sn, cmd, radius, oldtf,
                 oldxy = oldpos[1:2], startxy, clear_status))
    end

    isempty(jobs) && error("no editable blocked navigation goal was found")

    applied = NamedTuple[]
    chosen = NamedTuple[]

    try
        for (job_index, job) in enumerate(jobs)
            placed = false
            buffer = Float64(get(env.staging_buffers, job.blocked_id, 0.0))

            for z in zoneinfo
                clearance = z.radius + job.radius +
                            max(buffer, job.radius, 0.1)
                base_angle = atan(job.oldxy[2] - z.center[2],
                                  job.oldxy[1] - z.center[1])

                for trial in 0:95
                    angle = base_angle +
                            2pi * (trial + job_index - 1) / 96
                    candidate = z.center .+
                                clearance .* [cos(angle), sin(angle)]

                    goal_engulfed(candidate, job.radius, zoneballs) && continue
                    free_space_status(job.startxy, candidate, zoneballs,
                                      job.radius) == job.clear_status || continue

                    separated = true
                    for prior in chosen
                        delta = candidate .- prior.xy
                        required = 2 * (job.radius + prior.radius)
                        if sum(delta .* delta) <= required * required
                            separated = false
                            break
                        end
                    end
                    separated || continue

                    dx = candidate[1] - job.oldxy[1]
                    dy = candidate[2] - job.oldxy[2]
                    velocity = typeof(job.cmd.vel)(dx, dy, 0.0)
                    shift_twist = typeof(job.cmd)(velocity, zero(job.cmd.ω))
                    shift = integrate_twist(shift_twist, 1.0)
                    candidate_tf = shift ∘ job.oldtf

                    set_desired_global_transform!(job.cfg, candidate_tf)
                    report = zone_blockage(env; zone_keys = zonekeys,
                                           check_paths = true)
                    remains_blocked =
                        any(x -> x.id == job.blocked_id, report.blocked)
                    candidate_status =
                        free_space_status(job.startxy, candidate, zoneballs,
                                          job.radius)

                    if remains_blocked ||
                       candidate_status != job.clear_status
                        set_desired_global_transform!(job.cfg, job.oldtf)
                        continue
                    end

                    push!(applied, (; cfg = job.cfg, oldtf = job.oldtf))
                    push!(chosen, (; xy = candidate, radius = job.radius))
                    placed = true
                    break
                end
                placed && break
            end

            placed ||
                error("no reachable legal replacement pose was found for a blocked goal")
        end

        final_report = zone_blockage(env; zone_keys = zonekeys,
                                     check_paths = true)
        target_ids = Set(job.blocked_id for job in jobs)
        any(x -> x.id in target_ids, final_report.blocked) &&
            error("one or more relocated goals remain blocked")

        for job in jobs
            finaltf = global_transform(job.cfg)
            finalpos = Vector{Float64}(getproperty(finaltf, :translation))
            free_space_status(job.startxy, finalpos[1:2], zoneballs,
                              job.radius) == job.clear_status ||
                error("one or more relocated goals remain unreachable")
        end

        validate_schedule_transform_tree(env.sched; post_staging = true) ||
            error("relocation invalidated the schedule transform tree")
    catch
        for edit in Iterators.reverse(applied)
            set_desired_global_transform!(edit.cfg, edit.oldtf)
        end
        rethrow()
    end

    return (; status = :success)
end