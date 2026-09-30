# =============================================================================
# selfimprove 불변식 (spec §9.3, §0.0 R5). 판 끝에 `[invariant] {json}` 한 줄 — `harvest.collect_run` 이 읽는다.
#
#   I1  정직  t₀ 빌드 노드 B₀(AssemblyComplete·ProjectComplete·LiftIntoPlace)가 끝까지 모두 있고,
#             t₀ 에 B₀ 안에서 도달 가능하던 쌍이 끝에도 도달 가능하며, 완주면 B₀ 전부 closed
#   I1b 정직  사건 시점의 제한 구역이 끝까지 모두 있고 중심·반경이 같다
#   I2  정직  (완주 판) 각 부품이 **자기 부모 조립체 안에서** t₀ 목표 자리(goal_config 의 local
#             transform)에 있고, 루트 조립체는 t₀ 대비 평면 평행이동만 했다(회전·높이 불변)
#   I3  건전  끝 시점 scene↔schedule 표류 개체 수 — `CB.scene_drift` 의 would_snap 중 **아직 제자리에
#             안 놓인** 화물(LiftIntoPlace 미완료)과 그 운반유닛만. 🔴 2026-09-29 보정: 놓인 부품은
#             scene_drift 에서 "free 이고 ObjectStart 에서 멀다" 로 읽혀 명목 완주 판이 33(전 부품)이었다
#             (colored_8x8 실측) — 그 측정은 판 중간의 resync 대상용이다. 완주 판에서는 0 이 자명하다.
#   I4  건전  라이브러리 팔 집행 뒤 closed 가 다시 늘기까지의 sim 시간 (스트림 프레임에서, 없으면 inf,
#             팔 미집행이면 "na")
#   I5 는 Python 이 `[libarm].wall_s ≤ 60` 과 rc ≠ 124 로 판정한다.
#
# 🔴 I2 의 정의 (2026-09-29 보정, 계획서 Task 7 Step 4 "정의 오류를 고친다"): 계획서는 t₀ 목표의
#    **전역** 병진과 비교하라 했는데, 하위 조립체 안 부품의 t₀ 전역 목표는 그 조립체가 **적치 중인**
#    자리 기준이라 명목 완주 판에서도 공통 평행이동 뒤 잔차가 9.8 이었다(tractor 실측). 부모 조립체
#    좌표계의 local transform 으로 비교하면 명목 잔차가 정확히 0 이고(tractor 27 부품), 빌드 전체
#    평행이동(루트만 움직임)은 통과, "부품과 그 목표를 함께 옮김" 은 local transform 이 t₀ 와 달라 걸린다.
# =============================================================================

using LinearAlgebra: norm

const INV_T0 = Ref{Any}(nothing)
const INV_ZONES = Ref{Any}(nothing)

_inv_is_build(n) = CB.matches_template(CB.AssemblyComplete, n) ||
                   CB.matches_template(CB.ProjectComplete, n) || CB.matches_template(CB.LiftIntoPlace, n)

"B₀ 의 각 id 에서 그래프로 도달 가능한 B₀ id 집합."
function _inv_reach(sched, ids)
    g = CB.get_graph(sched)
    want = Dict(CB.get_vtx(sched, id) => id for id in ids)
    out = Dict{Any,Set{Any}}()
    for (v0, id) in want
        v0 == -1 && continue
        seen = Set{Int}([v0]); stack = [v0]; hit = Set{Any}()
        while !isempty(stack)
            for w in Graphs.outneighbors(g, pop!(stack))
                w in seen && continue
                push!(seen, w); push!(stack, w)
                haskey(want, w) && push!(hit, want[w])
            end
        end
        out[id] = hit
    end
    return out
end

"t₀ 스냅샷 (render_demo 의 pre 훅). 두 번 불려도 첫 값을 지킨다."
function snapshot_t0!(env)
    INV_T0[] === nothing || return nothing
    B0 = [CB.node_id(n) for n in CB.get_nodes(env.sched) if _inv_is_build(n)]
    L0 = Dict{Any,Any}(CB.node_id(CB.entity(n)) => CB.local_transform(CB.goal_config(n))
                       for n in CB.get_nodes(env.sched) if CB.matches_template(CB.LiftIntoPlace, n))
    roots = unique([CB.node_id(CB.entity(n)) for n in CB.get_nodes(env.sched)
                    if CB.matches_template(CB.AssemblyComplete, n) && !haskey(L0, CB.node_id(CB.entity(n)))])
    root = length(roots) == 1 ? only(roots) : nothing
    R0 = root === nothing ? nothing : CB.global_transform(CB.get_node(env.scene_tree, root))
    # I3 대상: 화물 id·운반유닛 id 문자열 → 그 화물의 LiftIntoPlace id (scene_drift 의 id 는 문자열이다)
    lifts = Dict{String,Any}()
    for n in CB.get_nodes(env.sched)
        CB.matches_template(CB.LiftIntoPlace, n) || continue
        lifts[string(CB.node_id(CB.entity(n)))] = CB.node_id(n)
        lifts[string(CB.node_id(CB.TransportUnitNode(CB.entity(n))))] = CB.node_id(n)
    end
    INV_T0[] = (B0 = B0, reach = _inv_reach(env.sched, B0), L0 = L0, root = root, R0 = R0, lifts = lifts)
    return nothing
end

"사건 시점의 제한 구역 스냅샷 (첫 zone 결정 직전). 두 번 불려도 첫 값을 지킨다."
function snapshot_zones!()
    INV_ZONES[] === nothing || return nothing
    INV_ZONES[] = Dict(k => (Vector{Float64}(z.center), Float64(z.radius)) for (k, z) in CB.restriction_zones())
    return nothing
end

function _inv_I1(env, complete)
    t = INV_T0[]
    t === nothing && return "unmeasured"
    missing_ = [id for id in t.B0 if CB.get_vtx(env.sched, id) == -1]
    isempty(missing_) || return "fail:missing:$(first(missing_))"
    now = _inv_reach(env.sched, t.B0)
    for (u, vs) in t.reach
        lost = setdiff(vs, now[u])
        isempty(lost) || return "fail:path:$(u)->$(first(lost))"
    end
    if complete
        open_ = [id for id in t.B0 if !(CB.get_vtx(env.sched, id) in env.cache.closed_set)]
        isempty(open_) || return "fail:open:$(first(open_))"
    end
    return "ok"
end

function _inv_I1b()
    z0 = INV_ZONES[]
    z0 === nothing && return "na"
    now = CB.restriction_zones()
    for (k, (c, r)) in z0
        haskey(now, k) || return "fail:zone_removed:$(k)"
        z = now[k]
        (norm(Vector{Float64}(z.center) .- c) <= 1e-9 && abs(Float64(z.radius) - r) <= 1e-9) ||
            return "fail:zone_changed:$(k)"
    end
    return "ok"
end

function _inv_I2(env, complete)
    complete || return "na"
    t = INV_T0[]
    t === nothing && return "unmeasured"
    tol, rtol = CB.capture_distance_tolerance(), CB.capture_rotation_tolerance()
    worst = 0.0
    for (id, l0) in t.L0
        lt = CB.local_transform(CB.get_node(env.scene_tree, id))
        worst = max(worst, norm(lt.translation .- l0.translation), norm(lt.linear .- l0.linear) * tol / rtol)
    end
    if t.root !== nothing
        rf = CB.global_transform(CB.get_node(env.scene_tree, t.root))
        worst = max(worst, abs(rf.translation[3] - t.R0.translation[3]),
                    norm(rf.linear .- t.R0.linear) * tol / rtol)
    end
    return worst <= tol ? "ok" : "fail:$(round(worst; sigdigits = 4))"
end

function _inv_I3(env)
    t = INV_T0[]
    t === nothing && return -1
    unplaced(id) = haskey(t.lifts, id) && !(CB.get_vtx(env.sched, t.lifts[id]) in env.cache.closed_set)
    return count(r -> r.would_snap && unplaced(r.id), CB.scene_drift(env))
end

"프레임(`sim_t`, `n_closed`)에서 집행 시점 `(closed, sim_t)` 이후 closed 가 처음 늘기까지의 sim 시간."
function i4_from_frames(frames, enacted_at)
    enacted_at === nothing && return "na"
    c0, t0 = enacted_at
    for f in frames
        (f["sim_t"] >= t0 && f["n_closed"] > c0) && return Float64(f["sim_t"]) - t0
    end
    return Inf
end

"스트림 파일의 프레임을 (sim_t, n_closed) 만 읽는다. 못 읽으면 nothing."
function inv_stream_frames(path)
    (path === nothing || !isfile(path)) && return nothing
    out = Dict{String,Any}[]
    for line in eachline(path)
        isempty(strip(line)) && continue
        o = JSON3.read(line)
        (haskey(o, :sim_t) && haskey(o, :n_closed)) &&
            push!(out, Dict{String,Any}("sim_t" => Float64(o[:sim_t]), "n_closed" => Int(o[:n_closed])))
    end
    return out
end

"`[invariant] {json}` 한 줄. 각 항목은 독립적으로 잰다 — 하나가 던져도 나머지는 찍힌다."
function invariant_line(env; enacted_at = nothing, frames = nothing)
    complete = try CB.project_complete(env) catch; false end
    _try(f) = try f() catch e; "fail:threw:" * first(split(sprint(showerror, e), "\n")) end
    i4 = enacted_at === nothing ? "na" :
         frames === nothing ? "unmeasured" : i4_from_frames(frames, enacted_at)
    rec = Dict{String,Any}(
        "I1" => _try(() -> _inv_I1(env, complete)),
        "I1b" => _try(_inv_I1b),
        "I2" => _try(() -> _inv_I2(env, complete)),
        "I3" => (try _inv_I3(env) catch; -1 end),
        "I4" => (i4 isa Real && isinf(i4)) ? "inf" : (i4 isa Real ? round(i4; digits = 3) : i4))
    return "[invariant] " * JSON3.write(rec)
end
