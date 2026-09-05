# =============================================================================
# zone_corridor.jl -- BLOCKAGE predicates: "막혔다"를 재는 층 (coverage 가 아니라).
# =============================================================================
#
# WHY THIS FILE EXISTS
# --------------------
# `zone_diagnosis.jl` measures COVERAGE: which scene-tree entities a no-go disc sits on top
# of. STEP 6 (2026-08-05) measured that coverage is NOT harm: a zone swallowing 8/8 of the
# root's delivery goals still let the build finish all 291 nodes -- it only doubled makespan
# (22.25 -> 47.08). Coverage said "doomed"; the simulator said "detour". This file computes
# the thing coverage was standing in for.
#
# THE MECHANISM (why a covered goal is still reachable) -- read this before trusting anything
# else here. A restriction zone is enforced in exactly ONE place: `enforce_restriction_zone_
# clearance!` (route_planning.jl), which snaps agents OUT of the disc. It iterates
# `get_vtx_ids(rvo_global_id_map())` -- i.e. ONLY robots and transport units. But the goals
# `root_deposit_goals` reports are `LiftIntoPlace` goals, and `apply_cmd!(::LiftIntoPlace, ...)`
# moves the CARGO by integrating a twist directly onto its transform. The cargo is not an RVO
# agent, so no zone can ever stop it. A zone over a `LiftIntoPlace` goal is therefore
# UNBLOCKABLE BY CONSTRUCTION -- it can only cost the carrier a detour on the way in.
#
# So the goals a zone can actually block are the ones whose MOVER is an RVO agent:
#
#   | node               | entity moved      | driven by | zone can block it? |
#   |--------------------|-------------------|-----------|--------------------|
#   | `RobotGo`          | RobotNode         | RVO       | YES                |
#   | `TransportUnitGo`  | TransportUnitNode | RVO       | YES                |
#   | `LiftIntoPlace`    | cargo (assembly)  | kinematic | no                 |
#   | `DepositCargo`     | cargo             | kinematic | no                 |
#   | `FormTransportUnit`| cargo             | kinematic | no (its ROBOTS are RobotGo) |
#
# Note `LiftIntoPlace <: EntityGo` too, so a type test on `EntityGo` does NOT separate these --
# the split has to be on the ENTITY type, which is what `_nav_goal_targets` does.
#
# TWO WAYS A ZONE ACTUALLY BLOCKS A NAV GOAL
# ------------------------------------------
#   1. ENGULFED  — the goal's capture ball (`capture_distance_tolerance()`) lies entirely inside
#      the enforced exclusion disc (zone radius + agent radius). The agent is snapped out every
#      step it tries; `is_goal` can never fire. This is a closed-form test.
#   2. DISCONNECTED — the goal is free, but every path to it from where the agent stands is
#      pinched off (a ring of zones, or a zone wedged against another). This is the CORRIDOR
#      case `_minimum_clear_translation` cannot see: Δ guarantees the goal DISC is clear, never
#      that a route to it survives. Computed by flood fill on a grid of the inflated free space
#      (honest and cheap; the discretization is a stated parameter, not a hidden one).
#
# Everything here is READ-ONLY and returns PRIMITIVES. There is deliberately no verdict: the
# minimal-repair rule lives in `zone_diagnosis.jl`, and whether these primitives should REPLACE
# coverage in that rule is an empirical question (STEP 10), not one this file may assume.
#
# [한국어] 이 파일은 "구역이 무엇을 **덮었나**(coverage)"가 아니라 "무엇을 **막았나**(blockage)"를 잰다.
#   STEP 6 실측: root 하역목표를 8/8 덮어도 빌드는 291 노드 전부 닫고 완주했다(시간만 2.1배).
#   왜인가 — 구역은 `enforce_restriction_zone_clearance!` 한 곳에서만 강제되는데, 그 함수는
#   **RVO 에이전트(로봇·운반유닛)만** 원 밖으로 밀어낸다. 그런데 root_deposit_goals 가 세는 목표는
#   `LiftIntoPlace` 의 목표이고, LiftIntoPlace 는 화물 변환을 **직접 적분해** 옮긴다(RVO 를 안 거침).
#   화물은 RVO 맵에 없으므로 구역이 원리적으로 못 막는다. 즉 커버리지는 **막을 수 없는 목표**를 세고 있었다.
#   막을 수 있는 목표 = 움직이는 주체가 RVO 에이전트인 노드(RobotGo · TransportUnitGo)의 목표뿐이다.
#   (주의: LiftIntoPlace 도 타입상 EntityGo 라서 타입 검사로는 안 갈린다 → **엔티티 종류**로 가른다.)
#   막히는 방식은 둘: ① 포획볼이 통째로 배제원 안(engulfed, 닫힌 식) ② 목표는 비었는데 가는 길이
#   끊김(disconnected, 격자 flood-fill). ②가 계획서가 말한 corridor 술어다 — Δ 는 목표 원만 보장하고
#   **경로는 보장하지 않기** 때문에 필요하다.
#   이 파일은 판정(verdict)을 내지 않는다. 원시값만 준다.
# =============================================================================

"""
    _agent_radius(node) -> Float64

Physical disc radius the zone enforcement uses for this agent (`get_cached_geom(..., Hyper-
sphereKey())`), falling back to `default_robot_radius()` exactly as
`enforce_restriction_zone_clearance!` does — so what we predict and what the simulator enforces
are the same number.
"""
# 구역 강제가 이 에이전트에게 쓰는 물리 원판 반지름. 실패 시 기본 로봇 반지름으로 폴백하는 것까지
#   enforce_restriction_zone_clearance! 과 **동일**하게 맞춘다(예측과 실제가 같은 수를 쓰게).
function _agent_radius(node)
    try
        return Float64(get_radius(get_cached_geom(node, HypersphereKey())))
    catch
        return default_robot_radius()
    end
end

"""
    _nav_goal_targets(env) -> Vector{NamedTuple}

Every UNFINISHED schedule node whose goal must be reached by an RVO-DRIVEN agent — the only
goals a no-go zone can physically block. One entry per node:

| field | meaning |
|---|---|
| `vtx` / `id` | schedule vertex / node id |
| `kind` | `:robot` (`RobotGo`) or `:transport` (`TransportUnitGo`) |
| `goal` | 2D goal position |
| `pos` | where the mover is now (its own transform; `start_config` for a unit not yet formed) |
| `radius` | the agent's enforced disc radius |
| `live` | the mover is registered in the RVO id map right now |

Cargo-kinematic nodes (`LiftIntoPlace`, `DepositCargo`, `FormTransportUnit`) are EXCLUDED —
see the mechanism note at the top of this file. `_kinematic_goal_targets` returns those, so a
caller can report the contrast instead of silently conflating them.
"""
# 아직 안 끝난 노드 중 **RVO 로 움직이는 주체**가 도달해야 하는 목표들(=구역이 물리적으로 막을 수 있는 유일한 목표).
#   RobotGo(로봇) / TransportUnitGo(운반유닛)만 해당. LiftIntoPlace·DepositCargo·FormTransportUnit 은
#   화물을 직접 옮기므로 제외한다(파일 상단 기구 설명 참조).
function _nav_goal_targets(env)
    out = NamedTuple[]
    for v in Graphs.vertices(get_graph(env.sched))
        v in env.cache.closed_set && continue          # 이미 닫힌 노드는 막을 것도 없다
        n = get_node(env.sched, v).node
        kind = matches_template(RobotGo, n)         ? :robot :
               matches_template(TransportUnitGo, n) ? :transport : :none
        kind === :none && continue                     # 화물 운동학 노드는 여기서 걸러진다
        ent = try entity(n) catch; continue end
        g = try
            Vector{Float64}(project_to_2d(global_transform(goal_config(n)).translation))
        catch
            continue
        end
        # 현재 위치. 살아 있는 에이전트(RVO 맵에 등록됨)는 **실제 위치**가 권위다 — 그게 스냅을 받는
        # 바로 그 몸이기 때문. 아직 결성되지 않은 운반유닛은 자기 변환이 의미 없으므로 계획상의
        # 출발 자세(start_config)로 대신한다.
        live = try has_vertex(rvo_global_id_map(), node_id(ent)) catch; false end
        p = nothing
        if live
            p = try Vector{Float64}(project_to_2d(global_transform(ent).translation)) catch; nothing end
        end
        if p === nothing
            p = try
                Vector{Float64}(project_to_2d(global_transform(start_config(n)).translation))
            catch
                try Vector{Float64}(project_to_2d(global_transform(ent).translation)) catch; nothing end
            end
        end
        p === nothing && continue
        push!(out, (vtx = v, id = node_id(ent), kind = kind,
                    goal = g[1:2], pos = p[1:2], radius = _agent_radius(ent), live = live))
    end
    return out
end

"""
    _kinematic_goal_targets(env) -> Vector{Vector{Float64}}

2D goals of the UNFINISHED cargo-kinematic nodes (`LiftIntoPlace`) — the goals a zone can cover
but never block. Kept as a first-class list so the honest contrast ("this zone covers 8 goals it
cannot block and 0 it can") is one call away.
"""
# 아직 안 끝난 **운동학적** 목표들(LiftIntoPlace). 구역이 덮을 수는 있어도 못 막는 부류 —
#   "덮은 8개는 못 막는 것이고, 막을 수 있는 건 0개" 라는 대비를 한 번의 호출로 보이게 하려고 남긴다.
function _kinematic_goal_targets(env)
    out = Vector{Float64}[]
    for v in Graphs.vertices(get_graph(env.sched))
        v in env.cache.closed_set && continue
        n = get_node(env.sched, v).node
        matches_template(LiftIntoPlace, n) || continue
        g = try
            Vector{Float64}(project_to_2d(global_transform(goal_config(n)).translation))
        catch
            continue
        end
        push!(out, g[1:2])
    end
    return out
end

"""
    goal_engulfed(goal, agent_radius, zones; ttol, margin) -> Bool

True iff EVERY position from which `is_goal` could fire is inside an enforced exclusion disc —
i.e. the capture ball around `goal` (radius `ttol = capture_distance_tolerance()`) is swallowed
by `(zone_radius + agent_radius + margin)` for some zone. Then the agent is snapped out on every
step it approaches and the node can never close: a HARD, closed-form blockage.

`margin` mirrors `enforce_restriction_zone_clearance!`'s own (1e-4). Conservative by design: it
tests one zone at a time, so a goal engulfed only by the UNION of two overlapping zones reads
`false` here — that case is caught as `:disconnected` by the flood fill instead.
"""
# 목표의 "포획볼"(반지름=포획 허용오차)이 통째로 배제원(구역반지름+에이전트반지름) 안에 들어가면 true.
#   그러면 접근할 때마다 밖으로 스냅되어 is_goal 이 절대 못 켜진다 = 확정 막힘(닫힌 식).
#   보수적으로 **구역 하나씩** 본다 — 두 구역의 합집합으로만 삼켜지는 경우는 아래 flood-fill 이 잡는다.
function goal_engulfed(goal, agent_radius::Real, zones;
        ttol::Float64 = capture_distance_tolerance(), margin::Float64 = 1e-4)
    g = Vector{Float64}(goal)[1:2]
    for z in zones
        c = Vector{Float64}(get_center(z)[1:2])
        safe_r = Float64(get_radius(z)) + Float64(agent_radius) + margin
        norm(g .- c) + ttol < safe_r && return true    # 포획볼 전체가 배제원 안
    end
    return false
end

"""
    free_space_status(start, goal, zones, agent_radius; cell, margin) -> Symbol

Connectivity of the agent's free space, by flood fill on a grid of the plane with every zone
INFLATED by `agent_radius` (the configuration-space obstacle the snap actually enforces):

  * `:clear`        — a grid path exists from `start` to `goal`.
  * `:engulfed`     — the goal cell itself is inside an inflated zone.
  * `:agent_trapped`— the agent's own cell is inside one (it was parked when the zone appeared).
  * `:disconnected` — both cells are free but no path joins them: THE CORRIDOR CASE.

The grid spans the union of {start, goal, every inflated zone} padded by 3 cells, so the outer
band of the box is always free and always connected. A path that would have to leave the box
therefore cannot exist without one already inside it — the box cannot manufacture a false
`:disconnected`. `cell` defaults to half an agent radius: fine enough that a gap a robot can
pass (≥ 2·agent_radius wide in C-space terms, i.e. > 0 after inflation) is not closed by
rounding, coarse enough to stay ~ms.

Honest limit: this is a DISCRETIZATION. A gap narrower than `cell` may read as connected. Pass a
smaller `cell` when the answer matters; the parameter is returned by `zone_blockage` so any
result carries the resolution it was measured at.
"""
# 구역을 **에이전트 반지름만큼 부풀린**(=실제 스냅이 강제하는 형상공간 장애물) 평면 격자에서 flood-fill 로
#   현재 위치 → 목표의 연결성을 판정한다.
#     :clear = 길이 있음 / :engulfed = 목표 칸이 막힘 / :agent_trapped = 내가 선 칸이 막힘(구역이 내 위에 생김)
#     :disconnected = 둘 다 비었는데 길이 없음  ← **이것이 corridor(통로 봉쇄) 케이스**
#   격자 범위는 {시작, 목표, 부풀린 구역 전부}를 3칸 여유로 감싸므로 상자 가장자리 띠는 항상 비어 있고
#   서로 연결돼 있다 → 상자 때문에 "길 없음"이 거짓으로 나오지 않는다.
#   정직한 한계: 격자 해상도(cell)보다 좁은 틈은 열린 것으로 읽힐 수 있다. 그래서 cell 을 결과에 함께 싣는다.
function free_space_status(start, goal, zones, agent_radius::Real;
        cell::Float64 = max(0.5 * Float64(agent_radius), 1e-3), margin::Float64 = 1e-4)
    isempty(zones) && return :clear
    s = Vector{Float64}(start)[1:2]; g = Vector{Float64}(goal)[1:2]
    ar = Float64(agent_radius)
    zc = [Vector{Float64}(get_center(z)[1:2]) for z in zones]
    zr = [Float64(get_radius(z)) + ar + margin for z in zones]     # 부풀린(형상공간) 반지름

    blocked(p) = any(i -> norm(p .- zc[i]) < zr[i], eachindex(zc))
    blocked(g) && return :engulfed
    blocked(s) && return :agent_trapped

    # ---- 격자 상자: 시작·목표·모든 부풀린 구역을 3칸 여유로 감싼다 --------------------
    xs = Float64[s[1], g[1]]; ys = Float64[s[2], g[2]]
    for i in eachindex(zc)
        push!(xs, zc[i][1] - zr[i]); push!(xs, zc[i][1] + zr[i])
        push!(ys, zc[i][2] - zr[i]); push!(ys, zc[i][2] + zr[i])
    end
    pad = 3 * cell
    x0, x1 = minimum(xs) - pad, maximum(xs) + pad
    y0, y1 = minimum(ys) - pad, maximum(ys) + pad
    nx = max(3, ceil(Int, (x1 - x0) / cell) + 1)
    ny = max(3, ceil(Int, (y1 - y0) / cell) + 1)
    # 격자가 터무니없이 커지면(작은 cell + 넓은 상자) 계산을 포기하는 대신 해상도를 낮춘다 —
    # 조용히 틀린 답을 내는 것보다 낫고, 쓴 해상도는 호출자에게 돌려준다.
    maxcells = 4_000_000
    if nx * ny > maxcells
        scale = sqrt((nx * ny) / maxcells)
        cell *= scale
        nx = max(3, ceil(Int, (x1 - x0) / cell) + 1)
        ny = max(3, ceil(Int, (y1 - y0) / cell) + 1)
    end
    cellpt(i, j) = [x0 + (i - 1) * cell, y0 + (j - 1) * cell]
    idx(p) = (clamp(round(Int, (p[1] - x0) / cell) + 1, 1, nx),
              clamp(round(Int, (p[2] - y0) / cell) + 1, 1, ny))

    free = trues(nx, ny)
    for i in 1:nx, j in 1:ny
        free[i, j] = !blocked(cellpt(i, j))
    end
    si, sj = idx(s); gi, gj = idx(g)
    # 시작/목표 칸이 반올림 때문에 막힘으로 찍혔으면 강제로 열어 준다(위에서 실제 좌표는 비었음을 이미 확인).
    free[si, sj] = true; free[gi, gj] = true

    seen = falses(nx, ny); seen[si, sj] = true
    stack = [(si, sj)]
    while !isempty(stack)
        (i, j) = pop!(stack)
        (i == gi && j == gj) && return :clear
        for (di, dj) in ((1, 0), (-1, 0), (0, 1), (0, -1))
            a, b = i + di, j + dj
            (1 <= a <= nx && 1 <= b <= ny) || continue
            (seen[a, b] || !free[a, b]) && continue
            seen[a, b] = true
            push!(stack, (a, b))
        end
    end
    return :disconnected
end

"""
    _project_completion_vtxs(env) -> Vector{Int}

The schedule vertices that `project_complete(env)` reads — every `ProjectComplete` node.

This is the DEFINITION of "the build finishes": `project_complete` returns true iff every one of
these is in `closed_set`. So asking whether one of them sits behind a blocked node is asking
whether the project can still finish at all, not how much of it is slowed.
"""
# `project_complete(env)` 가 읽는 바로 그 노드들(ProjectComplete). 이 집합이 전부 닫혀야 완주다.
function _project_completion_vtxs(env)
    sched = env.sched
    out = Int[]
    for n in get_nodes(sched)
        matches_template(ProjectComplete, n) || continue
        push!(out, get_vtx(sched, n))
    end
    return out
end

"""
    _downstream_closure(env, vtxs) -> (seen, n_unfinished, n_completion_blocked, n_completion_open)

One forward traversal of the precedence DAG from `vtxs`, reported three ways:

  * `n_unfinished` — unfinished nodes in the closure (what `_downstream_unfinished` returns),
  * `n_completion_blocked` — `ProjectComplete` vertices INSIDE the closure that are still open,
  * `n_completion_open` — `ProjectComplete` vertices still open anywhere in the schedule.

The middle number is the one a ratio cannot express. `n_unfinished / pending` says how much of the
build freezes; `n_completion_blocked >= 1` says the build cannot be declared finished at all while
those nodes stay blocked, because `project_complete` requires exactly those vertices to close.
"""
# 선후행 DAG 를 vtxs 에서 한 번 전방 순회하고 셋으로 보고한다.
#   n_unfinished        = 폐포 안의 미완 노드 수(= 옛 `_downstream_unfinished`)
#   n_completion_blocked= 폐포 안에 있는 **아직 안 닫힌 ProjectComplete 정점** 수
#   n_completion_open   = 스케줄 전체에서 아직 안 닫힌 ProjectComplete 정점 수(분모)
# 가운데 값이 비율로는 표현이 안 되는 것이다: 앞의 값은 "얼마나 얼어붙나"이고,
# 가운데 값 >= 1 은 "그 노드들이 막힌 한 완주 판정 자체가 불가능하다"이다.
function _downstream_closure(env, vtxs)
    g = get_graph(env.sched)
    seen = Set{Int}()
    stack = Int[]
    for v in vtxs
        v in seen && continue
        push!(seen, v); push!(stack, v)
    end
    while !isempty(stack)
        v = pop!(stack)
        for w in Graphs.outneighbors(g, v)
            w in seen && continue
            push!(seen, w); push!(stack, w)
        end
    end
    closed = env.cache.closed_set
    n_unfinished = count(v -> !(v in closed), seen)
    pcs = _project_completion_vtxs(env)
    open_pcs = [v for v in pcs if !(v in closed)]
    return (seen = seen, n_unfinished = n_unfinished,
            n_completion_blocked = count(v -> v in seen, open_pcs),
            n_completion_open = length(open_pcs))
end

"""
    _downstream_unfinished(env, vtxs) -> Int

How many UNFINISHED schedule nodes are `vtxs` themselves or wait on them, transitively.

Why this exists (2026-08-05): `n_blocked` alone understates the harm by construction. The schedule
is a precedence DAG — a node that can never close never releases its successors — so "1 of 120
goals is blocked" is not one-hundred-twentieth of the damage; it is however much of the remaining
build sits behind that one node. Reporting the count without its closure invites exactly the
reading measured on the live twin: two different LLM programs called a hard stop "minimal impact,
only one navigation goal". This is a graph fact, not a judgement — it says how much work freezes,
not what to do about it.
"""
# 막힌 노드 자신 + 그 노드를 (이행적으로) 기다리는 미완 노드의 수.
#   스케줄은 선후행 DAG 라 절대 못 닫는 노드 하나는 그 뒤의 모든 노드를 영영 못 열게 한다.
#   그래서 "120개 중 1개 막힘"은 1/120 의 피해가 아니다 — 그 하나 뒤에 걸린 일 전부가 피해다.
_downstream_unfinished(env, vtxs) = _downstream_closure(env, vtxs).n_unfinished

"""
    zone_blockage(env; zone_keys, cell, check_paths=true) -> NamedTuple

What the active zones actually BLOCK — the causal counterpart of `zone_diagnosis`'s coverage.

| field | meaning |
|---|---|
| `n_nav_goals` | unfinished goals an RVO-driven agent must reach (the blockable population) |
| `n_engulfed` | of those, goals whose capture ball is inside an exclusion disc (hard block) |
| `n_disconnected` | of those, goals still free but with no path from where the mover stands |
| `n_agent_trapped` | movers standing inside a zone right now (parked when it appeared) |
| `n_blocked` | `n_engulfed + n_disconnected` — **nodes that cannot close while the zone lives** |
| `n_downstream` | unfinished nodes that are blocked or wait on one — how much work freezes |
| `n_completion_blocked` | of the schedule's still-open `ProjectComplete` vertices, how many sit in that closure — `project_complete(env)` cannot become true while they do |
| `n_completion_open` | still-open `ProjectComplete` vertices in the whole schedule (the denominator) |
| `project_blocked` | `n_completion_blocked >= 1`, or `nothing` when the closure could not be computed. **Never `0`/`false` for "not measured"** |
| `blocked` | per-goal detail `(vtx, id, kind, status)` for the blocked ones |
| `n_kinematic_goals` / `n_kinematic_covered` | cargo-kinematic goals, and how many the zone COVERS — the population coverage metrics were counting, which no zone can block |
| `cell` | the flood-fill resolution the answer was measured at |

`check_paths=false` skips the flood fill (engulfment only) — an exact LOWER bound on `n_blocked`,
useful when this is called every decision step.

!!! note "primitives only"
    No verdict. Whether `n_blocked` should replace `root_covered` in the minimal-repair rule is
    an empirical question — see `zone_diagnosis`'s `ZONE_CAUSAL_RULE` switch and STEP 10.
"""
# 활성 구역이 **실제로 막는 것**을 센다(zone_diagnosis 의 커버리지에 대응하는 인과 버전).
#   n_nav_goals      = 막힐 수 있는 목표(=RVO 로 움직이는 주체가 가야 하는 미완 목표)의 모수
#   n_engulfed       = 그중 포획볼이 배제원 안 → 확정 막힘
#   n_disconnected   = 목표는 비었는데 가는 길이 끊김 → corridor 막힘
#   n_blocked        = 둘의 합 = **구역이 살아 있는 한 절대 못 닫는 노드 수**
#   n_kinematic_*    = 커버리지가 세던 그 부류(화물 운동학 목표) — 덮여도 못 막는다는 대비를 위해 함께 보고
function zone_blockage(env;
        zone_keys = collect(keys(RESTRICTION_ZONES[])),
        cell::Union{Nothing,Float64} = nothing,
        check_paths::Bool = true,
        margin::Float64 = 1e-4)
    zones = [RESTRICTION_ZONES[][k] for k in zone_keys if haskey(RESTRICTION_ZONES[], k)]
    navs = _nav_goal_targets(env)
    kin = _kinematic_goal_targets(env)
    used_cell = cell === nothing ? max(0.5 * default_robot_radius(), 1e-3) : cell

    if isempty(zones)
        # 구역이 없으면 막힌 노드도 없다 = **쟀고 0 이다**(못 쟀다가 아니다). 완주 정점 개수는
        # 그래도 센다 — 분모가 있어야 아래 blocked 판이 견줄 대상을 갖는다.
        local _pc0 = try count(v -> !(v in env.cache.closed_set), _project_completion_vtxs(env))
                     catch e
                        @warn "[ZONE-BLK] completion vertices failed" exception = e; nothing
                     end
        return (n_nav_goals = length(navs), n_engulfed = 0, n_disconnected = 0,
                n_agent_trapped = 0, n_blocked = 0, n_downstream = 0, blocked = NamedTuple[],
                n_completion_blocked = _pc0 === nothing ? nothing : 0,
                n_completion_open = _pc0,
                project_blocked = _pc0 === nothing ? nothing : false,
                n_kinematic_goals = length(kin), n_kinematic_covered = 0,
                cell = used_cell, checked_paths = false)
    end

    n_eng = 0; n_dis = 0; n_trap = 0
    blocked = NamedTuple[]
    for t in navs
        if goal_engulfed(t.goal, t.radius, zones; margin = margin)
            n_eng += 1
            push!(blocked, (vtx = t.vtx, id = t.id, kind = t.kind, status = :engulfed))
            continue
        end
        check_paths || continue
        st = free_space_status(t.pos, t.goal, zones, t.radius; cell = used_cell, margin = margin)
        if st === :engulfed                    # 격자가 잡은 합집합 삼킴(닫힌 식이 놓친 경우)
            n_eng += 1
            push!(blocked, (vtx = t.vtx, id = t.id, kind = t.kind, status = :engulfed))
        elseif st === :disconnected
            n_dis += 1
            push!(blocked, (vtx = t.vtx, id = t.id, kind = t.kind, status = :disconnected))
        elseif st === :agent_trapped
            # 갇힌 것은 **주체**이지 목표가 아니다. 스냅이 밖으로 밀어내므로 곧 풀릴 수 있어
            # 막힘으로 세지 않고 따로 보고한다(과대보고 방지).
            n_trap += 1
        end
    end

    # 커버리지가 세던 부류: 운동학 목표를 몇 개나 덮었나(맨 반지름 기준 = root_goal_coverage 와 같은 규칙).
    n_kin_cov = count(kin) do g
        any(z -> norm(g .- Vector{Float64}(get_center(z)[1:2])) < Float64(get_radius(z)), zones)
    end

    # 막힌 노드 뒤에 걸려 함께 얼어붙는 미완 작업의 양(선후행 DAG 사실). 막힌 게 없으면 0.
    # 🔴 **종단성(terminality)은 비율이 아니다.** `n_downstream / pending` 은 "얼마나 얼어붙나"
    #    를 말하고, 그 비율은 작아 보일 수 있다(실측 2026-09-05: 32/251 = 13% 인데 그 판은
    #    끝내 완주하지 못했다 — 270/305 에서 정지). 완주 판정은 `project_complete(env)` 이고
    #    그것은 **ProjectComplete 정점이 전부 닫혔는가**만 본다. 그래서 그 정점이 막힌 노드의
    #    후방 폐포 안에 있으면, 구역이 사는 한 완주는 원리적으로 불가능하다 — 이것이 세계가
    #    결정 시점에 정직하게 말할 수 있는 사실이고, 겹침 비율이 절대 못 나르는 사실이다.
    # 🔴 삼상: 폐포를 못 구했으면 `nothing` 이다. 0/false 로 접지 않는다.
    local _cl = isempty(blocked) ? :none :
                (try _downstream_closure(env, (b.vtx for b in blocked)) catch e
                    @warn "[ZONE-BLK] downstream closure failed" exception = e; nothing
                 end)
    local _pc_open = try count(v -> !(v in env.cache.closed_set), _project_completion_vtxs(env))
                     catch e
                        @warn "[ZONE-BLK] completion vertices failed" exception = e; nothing
                     end
    n_down = _cl === :none ? 0 : (_cl === nothing ? -1 : _cl.n_unfinished)
    n_pc_blocked = _cl === :none ? (_pc_open === nothing ? nothing : 0) :
                   (_cl === nothing ? nothing : _cl.n_completion_blocked)
    proj_blocked = n_pc_blocked === nothing ? nothing : n_pc_blocked >= 1

    return (n_nav_goals = length(navs), n_engulfed = n_eng, n_disconnected = n_dis,
            n_agent_trapped = n_trap, n_blocked = n_eng + n_dis, n_downstream = n_down,
            n_completion_blocked = n_pc_blocked, n_completion_open = _pc_open,
            project_blocked = proj_blocked,
            blocked = blocked,
            n_kinematic_goals = length(kin), n_kinematic_covered = n_kin_cov,
            cell = used_cell, checked_paths = check_paths)
end
