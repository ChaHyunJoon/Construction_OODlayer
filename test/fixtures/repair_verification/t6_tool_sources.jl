# =============================================================================
# T6 fixture 도구 source — **손으로 쓴 시험 fixture**(생성 코드가 아니다). `test/repair_tool_execution.jl`(in-process)과
# `test/repair_tool_execution_branch.jl`(별도 프로세스 worker)이 같은 source 를 쓴다. 등록 규약: 최상위 함수 하나,
# `f(env; kw...)`. 이름은 `t6_<key>!` 이고 시험이 사례마다 새 이름으로 바꿔 등록한다(`Core.eval` 은 안 지워진다).
# =============================================================================
const T6_TOOL_SOURCES = Dict(
    # 비기하·자원: 가격 매겨진 제자리 배터리 교체(현행 primitive). 기하·배정 없음.
    "swap" => """
function t6_swap_battery!(env)
    r = first(sort!([node_id(n) for n in get_nodes(env.scene_tree) if matches_template(RobotNode, n) &&
                     !(node_id(n) in Set(vcat(values(SPARE_POOLS[])...)))]; by = string))
    return _apply_battery_swap!(env, r; verbose = false)
end""",
    # 비기하·배정: 가용 스페어로 한 로봇을 인계(현행 replace_robot!).
    "replace" => """
function t6_replace_one!(env)
    pool = first(sort!(collect(keys(SPARE_POOLS[]))))
    ws = sort!([node_id(n) for n in get_nodes(env.scene_tree) if matches_template(RobotNode, n) &&
                !(node_id(n) in Set(vcat(values(SPARE_POOLS[])...)))]; by = string)
    replace_robot!(env, first(ws), pop_spare!(pool); verbose = false)
    return :replaced
end""",
    # 기하: 빌드 전체 강체 이동 — **resync 를 안 부른다**(body 가 잊었다). 최상위 조립체 start_config 만 옮긴다.
    "shift" => """
function t6_shift_build!(env; dx::Float64 = 0.3, dy::Float64 = -0.2)
    T = CoordinateTransformations.Translation(dx, dy, 0.0)
    ts = Any[]
    for aid in sort!(collect(keys(env.staging_circles)); by = string)
        push!(ts, start_config(get_node(env.sched, AssemblyComplete(get_node(env.scene_tree, aid)))))
    end
    top(t) = (c = t; while !has_parent(c, c); c = get_parent(c); any(x -> x === c, ts) && return false; end; true)
    for t in ts
        top(t) && set_desired_global_transform!(t, T ∘ global_transform(t))
    end
    for aid in collect(keys(env.staging_circles))
        b = env.staging_circles[aid]
        env.staging_circles[aid] = LazySets.Ball2(Vector{Float64}(get_center(b)[1:2]) .+ [dx, dy], Float64(get_radius(b)))
    end
    return :shifted
end""",
    # 배정 해제(현행 release_pending_assignments!, 로봇 하나로 범위를 좁혀): 팀이 모자라진다 → 하니스 재풀이가 필요하다.
    "release" => """
function t6_release_one!(env)
    ws = sort!([node_id(n) for n in get_nodes(env.scene_tree) if matches_template(RobotNode, n) &&
                !(node_id(n) in Set(vcat(values(SPARE_POOLS[])...)))]; by = string)
    for w in ws
        r = release_pending_assignments!(env, build_invariant(env); agent = string(w))
        n = r isa AbstractVector ? length(r) : 0
        n > 0 && return (status = :released, n = n)
    end
    return :none
end""",
    "step3" => """
function t6_step3!(env)
    for _ in 1:3
        step_environment!(env)
    end
    return :stepped
end""",
    "clock" => """
function t6_clock!(env)
    set_sim_step!(SIM_STEP[] + 5)
    return :skewed
end""",
    "bypass" => """
function t6_bypass!(env)
    ENGINE_STEP_ADAPTER[] = nothing
    step_environment!(env)
    return :bypassed
end""",
    "throw_after" => """
function t6_throw_after!(env)
    r = first(sort!(collect(keys(BATTERY_FLEET[].soc)); by = string))
    _apply_battery_swap!(env, r; verbose = false)
    error("t6 boom after the first state change")
end""",
    "throw_before" => """
function t6_throw_before!(env)
    error("t6 boom before any change")
end""",
    "api_then_fail" => """
function t6_api_then_fail!(env)
    pool = first(sort!(collect(keys(SPARE_POOLS[]))))
    ws = sort!([node_id(n) for n in get_nodes(env.scene_tree) if matches_template(RobotNode, n) &&
                !(node_id(n) in Set(vcat(values(SPARE_POOLS[])...)))]; by = string)
    replace_robot!(env, first(ws), pop_spare!(pool); verbose = false)
    return get_node(env.sched, RobotID(987654))
end""",
    "soc_forge_then_step" => """
function t6_forge_then_step!(env)
    r = first(sort!(collect(keys(BATTERY_FLEET[].soc)); by = string))
    BATTERY_FLEET[].soc[r] = 1.0
    step_environment!(env)
    return :forged
end""",
    # 첫 상태 변경(빌드 강체 이동) 뒤 throw — 에피소드 worker 에서 폐기 경로를 탄다(배터리 유무와 무관).
    "shift_throw" => """
function t6_shift_throw!(env; dx::Float64 = 0.3, dy::Float64 = -0.2)
    T = CoordinateTransformations.Translation(dx, dy, 0.0)
    ts = Any[]
    for aid in sort!(collect(keys(env.staging_circles)); by = string)
        push!(ts, start_config(get_node(env.sched, AssemblyComplete(get_node(env.scene_tree, aid)))))
    end
    top(t) = (c = t; while !has_parent(c, c); c = get_parent(c); any(x -> x === c, ts) && return false; end; true)
    for t in ts
        top(t) && set_desired_global_transform!(t, T ∘ global_transform(t))
    end
    for aid in collect(keys(env.staging_circles))
        b = env.staging_circles[aid]
        env.staging_circles[aid] = LazySets.Ball2(Vector{Float64}(get_center(b)[1:2]) .+ [dx, dy], Float64(get_radius(b)))
    end
    error("t6 boom after moving the build")
end""",
    # 혼합: 빌드 강체 이동(resync 없음) + 스페어 인계(배정·자원).
    "mixed" => """
function t6_mixed!(env; dx::Float64 = 0.3, dy::Float64 = -0.2)
    T = CoordinateTransformations.Translation(dx, dy, 0.0)
    ts = Any[]
    for aid in sort!(collect(keys(env.staging_circles)); by = string)
        push!(ts, start_config(get_node(env.sched, AssemblyComplete(get_node(env.scene_tree, aid)))))
    end
    top(t) = (c = t; while !has_parent(c, c); c = get_parent(c); any(x -> x === c, ts) && return false; end; true)
    for t in ts
        top(t) && set_desired_global_transform!(t, T ∘ global_transform(t))
    end
    for aid in collect(keys(env.staging_circles))
        b = env.staging_circles[aid]
        env.staging_circles[aid] = LazySets.Ball2(Vector{Float64}(get_center(b)[1:2]) .+ [dx, dy], Float64(get_radius(b)))
    end
    pool = first(sort!(collect(keys(SPARE_POOLS[]))))
    ws = sort!([node_id(n) for n in get_nodes(env.scene_tree) if matches_template(RobotNode, n) &&
                !(node_id(n) in Set(vcat(values(SPARE_POOLS[])...)))]; by = string)
    replace_robot!(env, first(ws), pop_spare!(pool); verbose = false)
    return :mixed
end""",
)
