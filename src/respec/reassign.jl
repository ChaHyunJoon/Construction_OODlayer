# =============================================================================
# reassign.jl  --  Robot-fault -> verified reassignment (the "automate the OOD
#                  action" capability the whole agentic-LLM layer exists for).
# =============================================================================
#
# A pure constraint-add (ForbidAgent alone) CANNOT reassign work: the patched
# formulate_milp forces every EXISTING edge to Xa==1, so each robot's chain is
# pinned and the faulted robot's orphaned slots can't be threaded into another
# robot's timeline without a cycle. Reassignment therefore needs exactly ONE
# schedule-surgery primitive beyond the DSL:
#
#   release_pending_assignments!  --  drop the *future* (non-frozen) assignment
#       edges so the solver is free to re-decide them, while every closed /
#       in-progress edge stays pinned (the past is invariant).
#
# After the release, the verified pipeline does the rest, untouched:
#   build_invariant -> ForbidAgent(faulted) -> verify (trial solve) -> admit
#   -> formulate_milp(SparseAdjacencyMILP; freeze + ForbidAgent) -> re-solve
#   -> update_project_schedule! (re-stamps robot ids via propagate_valid_ids!)
#   -> reset_cache!.
#
# The MILP/solver is never modified; it optimally re-solves the future with one
# fewer robot, honouring the freeze. If that future is not re-solvable (e.g. a
# collaborative team can no longer be staffed) the feasibility gate REJECTS and
# the caller engages the safe fallback. "Reassign when possible, safe-stop when
# not" — safety is in the gate, not in the LLM.
#
# ── 한국어 요약 ───────────────────────────────────────────────────────────────
#  이 파일이 하는 일: 로봇이 고장 났을 때, 그 로봇이 맡던 미래 작업을 "검증된 재배정(reassign)"
#  으로 다른 로봇에게 넘긴다 — agentic-LLM 레이어가 자연어 고장 보고로부터 자동 수행할 바로 그 OOD 동작.
#  프로젝트 안에서의 역할: respec(재명세) 레이어의 로봇 고장 처리(ForbidAgent) 담당.
#  왜 제약 추가만으론 안 되나: 패치된 formulate_milp 이 기존 엣지를 전부 Xa==1 로 고정해
#  각 로봇 사슬이 못박히므로, 고장 로봇의 남은 작업을 다른 로봇 타임라인에 끼우려면 순환(cycle)이 생김.
#  그래서 DSL 밖의 스케줄 수술 프리미티브 딱 하나가 필요하다:
#    release_pending_assignments! — 미래(안 얼린)의 배정 엣지만 풀어 솔버가 다시 결정하게 함.
#    (완료·진행중 엣지는 못박은 채 = "과거는 불변".)
#  풀고 난 뒤엔 기존 검증 파이프라인(build_invariant → ForbidAgent → verify → 재풀이 → 반영)이 처리.
#  안전은 관문(gate)에 있음: 재풀이가 불가능하면 거절하고 호출자가 안전 정지(safe-stop) 폴백.
#
#  Julia 문법 참고(처음 보는 사람용):
#   · `!` 로 끝나는 함수 = 인자를 직접 수정(in-place), 예: release_pending_assignments!.
#   · `x::Int`, `agent::AbstractID` : 인자가 그 타입일 때만 이 메서드 적용(다중 디스패치).
#   · `isa` = 타입 검사(파이썬 isinstance). `:심볼` = 가벼운 상수 이름표. nothing = 파이썬 None.
#   · `조건 || return ...` : 조건이 거짓이면 곧장 반환(반대로 `조건 && ...` 는 참일 때만 실행).
#   · `Ref` 의 `[]` : RESPEC_FROZEN[] 처럼 참조상자를 역참조해 안의 값을 읽거나 씀.
#   · `(이름 = 값, ...)` : NamedTuple(점 . 으로 접근하는 가벼운 묶음). 함수 여러 결과를 담아 반환.
# =============================================================================

"""
    is_assignment_edge(sched, v, v2) -> Bool

An assignment edge is the only `RobotGo -> RobotGo` edge in the schedule: it
connects a robot's "free" node to a transport-task "slot" node. Every other
RobotGo edge is structural (`RobotStart -> RobotGo`, `RobotGo -> FormTransportUnit`,
`DepositCargo -> RobotGo`), so this single type test identifies assignments.
"""
# 두 정점(v→v2)을 잇는 엣지가 "작업 배정 엣지"인지 판별한다.
# 스케줄에서 RobotGo→RobotGo 엣지는 오직 배정 엣지뿐이라, 양끝이 RobotGo 인지만 보면 됨.
function is_assignment_edge(sched, v::Int, v2::Int)
    n1 = get_node_from_id(sched, get_vtx_id(sched, v))   # v 정점의 ID 로 노드 객체 가져오기
    n2 = get_node_from_id(sched, get_vtx_id(sched, v2))  # v2 정점의 노드 객체
    # `isa` = 타입 검사(파이썬 isinstance). 양쪽 모두 RobotGo 타입이면 배정 엣지로 간주.
    return (n1 isa RobotGo) && (n2 isa RobotGo)
end

"""
    reset_slot_to_invalid!(env, slot_v) -> Bool

Revert a transport-task "slot" RobotGo (the `dst` of a free->slot assignment
edge) to the *unassigned* state: stamp it with a fresh INVALID robot id and
re-key the successor FormTransportUnit team by that invalid id (geometry
preserved). This is required because `align_with_predecessor` for RobotGo uses
`first_valid`, which would otherwise keep the slot's STALE valid id instead of
adopting the new feeder's id during `propagate_valid_ids!`. After the reset,
the re-solve's id propagation flows the correct robot identity from the
RobotStart anchors forward through the new assignment. Returns false if the slot
already carries an invalid id (nothing to do).
"""
# 운반작업 "슬롯"(배정 엣지의 도착점 RobotGo)을 "미배정 상태"로 되돌린다.
# 새 INVALID(무효) 로봇 id 를 찍어, 나중에 재최적화가 실제로 배정한 로봇 id 가 흘러들어오게 함.
function reset_slot_to_invalid!(env, slot_v::Int)
    sched = env.sched                                          # 작업 스케줄
    slot = get_node_from_id(sched, get_vtx_id(sched, slot_v))  # 슬롯 정점의 노드
    slot isa RobotGo || return false                          # RobotGo 가 아니면 할 일 없음 → false
    old_id = entity(slot).id                                  # 슬롯에 현재 박힌 로봇 id. entity(노드).id 로 접근
    valid_id(old_id) || return false                         # 이미 무효 id 면 할 일 없음 → false
    new_id = get_unique_invalid_id(RobotID)                  # 새로운 고유 무효 id 발급
    # 같은 위치/목표를 유지하되 로봇 id 만 새 무효 id 로 바꾼 RobotGo 노드를 새로 만든다.
    new_node = RobotGo(RobotNode(new_id, entity(slot)),
                       start_config(slot), goal_config(slot), node_id(slot))
    replace_in_schedule!(sched, env.scene_tree, new_node, node_id(slot))  # 스케줄에서 기존 노드를 새 노드로 교체(in-place)
    # Re-key every successor FormTransportUnit team from old_id back to new_id.
    # 이 슬롯 뒤에 오는 운반팀(FormTransportUnit)의 팀 명부에서도 old_id 를 new_id 로 바꿔줌.
    for vf in Graphs.outneighbors(sched, slot_v)             # 슬롯에서 나가는 이웃들(후속 노드)을 순회
        fnode = get_node_from_id(sched, get_vtx_id(sched, vf))
        # 후속이 운반팀이고 + 그 팀 명부(robot_team)에 old_id 가 있으면
        if fnode isa FormTransportUnit && haskey(robot_team(entity(fnode)), old_id)
            swap_robot_id!(entity(fnode), old_id, new_id)   # 팀 명부의 키를 old_id → new_id 로 교체
        end
    end
    return true                                              # 성공적으로 무효화했음을 반환
end

"""
    release_pending_assignments!(env, invariant; faulted) -> Vector{Tuple{Int,Int}}

Remove the assignment edges (free -> slot) the re-solve is allowed to re-decide,
AND reset each freed slot to the unassigned (invalid-id) state so id propagation
re-stamps it with the robot the solver actually assigns. Release policy:

  * a HEALTHY robot's edge is kept (pinned) if either endpoint is closed or
    active — finished and in-progress work is never disturbed;
  * the FAULTED robot's edge is kept only if an endpoint is CLOSED — a faulted
    robot also drops its current (active) target, so that work gets reassigned.

Returns the removed (src,dst) vertex pairs. Does not re-solve — the caller's
`formulate_milp` + `update_project_schedule!` do that.
"""
# 재최적화가 다시 결정해도 되는 "미래의 배정 엣지(free→slot)"들을 제거하고, 풀린 슬롯을 미배정 상태로 되돌린다.
# 이미 끝났거나 진행 중인 작업(과거)은 절대 건드리지 않음. faulted 는 "고장난 로봇"(없으면 nothing).
function release_pending_assignments!(env, invariant::InvariantSpec; faulted = nothing)
    sched = env.sched
    G = get_graph(sched)                         # 스케줄의 실제 그래프 구조
    closed = invariant.closed_nodes              # 이미 완료된(닫힌) 노드 ID 집합 = "얼린 과거"
    # 현재 진행 중인 노드 ID 집합 — 컴프리헨션으로 만들어 Set 으로 감쌈.
    active_ids = Set{AbstractID}(get_vtx_id(sched, v) for v in env.cache.active_set)
    in_closed(id) = id in closed                 # 한 줄 헬퍼 함수: id 가 완료 집합에 있나?
    in_active(id) = id in active_ids             # id 가 진행중 집합에 있나?
    removed = Tuple{Int,Int}[]                   # 제거한 (src,dst) 정점쌍을 담을 빈 배열
    for e in collect(Graphs.edges(G))            # 모든 엣지를 순회(collect 로 미리 목록화 — 순회 중 그래프를 수정하므로)
        v, v2 = e.src, e.dst                      # 엣지의 시작/끝 정점
        is_assignment_edge(sched, v, v2) || continue  # 배정 엣지가 아니면 건너뜀
        id1 = get_vtx_id(sched, v); id2 = get_vtx_id(sched, v2)  # 양끝 노드의 ID
        src_node = get_node_from_id(sched, id1)  # 시작 노드 객체
        # 고장 로봇이 지정됐고(nothing 아님) + 시작 노드가 그 로봇에 묶여 있으면 = 고장 엣지
        is_faulted = faulted !== nothing && bound_to_agent(src_node, faulted)
        # `keep = if ... else ... end` : if 식 전체가 값을 돌려줌(파이썬 삼항보다 일반적). 어떤 엣지를 "유지"할지 결정.
        keep = if is_faulted
            in_closed(id1) || in_closed(id2)               # faulted: keep only completed  # 고장 로봇: 완료된 것만 유지(진행중도 떼어 재배정)
        else
            in_closed(id1) || in_closed(id2) || in_active(id1) || in_active(id2)  # 정상 로봇: 완료/진행중이면 유지
        end
        keep && continue                         # 유지 대상이면 제거하지 않고 다음으로
        Graphs.rem_edge!(G, v, v2)               # 그 외(미래 배정)는 엣지 제거 — 재최적화가 다시 결정하게 함
        push!(removed, (v, v2))                   # 제거 기록
    end
    # Reset freed slots (the dst of each removed edge) to unassigned identities.
    # 제거된 각 엣지의 도착점(슬롯)을 미배정(무효 id) 상태로 되돌림. `(_, v2)` 는 src 는 무시하고 dst 만 받음.
    for (_, v2) in removed
        reset_slot_to_invalid!(env, v2)
    end
    # Clear STALE ids on the FAULTED agent's downstream free nodes: post-DepositCargo
    # RobotGos that still carry the agent's id but are NOT its origin frontier and are
    # NOT slots of removed edges (so the loop above misses them). These live in build-
    # step subtrees, not in the agent's RobotStart chain, so they survive the release
    # carrying a stale id. Left un-reset, propagate_valid_ids' first_valid keeps that
    # stale id and the re-solve can thread a team member through such a node, making the
    # faulted agent RE-APPEAR on a transport team it was never re-assigned to. Resetting
    # them to invalid lets id propagation re-stamp them from the actual re-solve. The
    # true origin (predecessor is a RobotStart) is preserved so ForbidAgent still finds
    # the frontier; the frozen past (closed) is never touched.
    #
    # KNOWN-OPEN (see docs/resume_fulloop_status_2026-06-24.md): this faulted-only
    # clearing locates the faulted agent's frontier for ForbidAgent, but does NOT close
    # the double-booking once the sim RESUMES. Two fixes were investigated and ruled out
    # on 2026-06-24: (1) an authoritative re-thread (`rethread_robot_ids!`) cannot id a
    # cluster of geometry-miss orphan post-deposit RobotGos, which keep stale ids and
    # still double-book; (2) MILP temporal exclusion can't help — the MILP has no robot-
    # identity representation and already serializes each robot's Xa chain, while the
    # assertion `has_parent(robot,robot)` is identity-based, not temporal. The real cause
    # is upstream: those orphan nodes' identity is not derivable from the post-reassign
    # graph, AND the faulted robot is not cleanly removed from future active work
    # (stepping hits rvo_get_agent_idx on the faulted id). Both are the open next steps.
    # 고장 로봇이 지정된 경우: 위 루프가 놓친 "하류의 낡은 id 노드"들을 추가로 무효화.
    if faulted !== nothing
        for v in Graphs.vertices(G)              # 모든 정점 검사
            id = get_vtx_id(sched, v)
            in_closed(id) && continue            # 완료된(얼린) 노드는 건드리지 않음
            node = get_node_from_id(sched, id)
            # RobotGo 이면서 고장 로봇에 묶인 노드가 아니면 건너뜀
            (node isa RobotGo && bound_to_agent(node, faulted)) || continue
            # any(조건 for ...) : 하나라도 만족하면 true (파이썬 any). 들어오는 이웃 중 RobotStart 가 있으면
            # = 이 노드가 그 로봇의 "진짜 출발점(frontier)"이므로 보존하고 건너뜀(ForbidAgent 가 이걸 찾아야 함).
            any(vp -> get_node_from_id(sched, get_vtx_id(sched, vp)) isa RobotStart,
                Graphs.inneighbors(G, v)) && continue   # keep R's true origin frontier
            reset_slot_to_invalid!(env, v)       # 그 외 낡은 id 노드는 무효화 → 재최적화가 올바른 id 를 다시 찍게 함
        end
    end
    return removed                               # 제거한 엣지 목록 반환(재최적화는 호출자가 수행)
end

"""
    rethread_robot_ids!(sched, scene_tree) -> Bool

PARKED BUILDING BLOCK — verified INSUFFICIENT on its own to close the
reassignment double-booking (see docs/resume_fulloop_status_2026-06-24.md). It is
NOT wired into `fault_robot_and_reassign!`. Kept because a correct, consistent
re-thread is still likely part of the eventual fix.

Why it does not suffice: a cluster of deep-future post-deposit `RobotGo`s
(geometry-miss orphans) hit the `DepositCargo` branch below with
`get_matching_child_id` returning `nothing`, so this pass SKIPs them and they
keep their stale ids — exactly the nodes that double-book. Forcing them invalid
instead reproduces the rvo `BoundsError` the doc warned about. The real cause is
upstream (those nodes' identity is not derivable from the post-reassign graph at
all), and the assertion that fires is identity-based (`has_parent(robot,robot)`),
which no amount of id re-stamping over an unthreadable node can satisfy.

Authoritative re-stamp of every `RobotGo`'s robot id strictly along graph edges,
rooted at the `RobotStart` anchors (the doc's Option 1).

`propagate_valid_ids!` aligns each `RobotGo` with `first_valid`, which KEEPS a
node's pre-existing (possibly stale) valid id. After a reassignment re-solve that
is wrong: a free `RobotGo` whose graph predecessor now belongs to a different
robot's thread keeps its old id, so one robot ends up on two un-serialized
branches (the double-booking that makes mid-resume `preprocess_env!` assert
`has_parent(robot,robot)`). Clearing stale ids to invalid instead is insufficient
— id propagation then can't re-derive some of them and leaves `RobotGo`s invalid.

The fix re-derives identity deterministically. In topological order, each
`RobotGo` is OVERRIDDEN with the robot flowing in from its single graph
predecessor:

  * pred `RobotStart`   -> that start's robot,
  * pred `RobotGo`      -> the predecessor's (already re-threaded) robot — this is
                           the free->slot assignment edge, so the slot adopts the
                           assigned robot,
  * pred `DepositCargo` -> the team member released at this node's geometric slot.
                           The `TransportUnitNode` entity is shared with the
                           `FormTransportUnit`, which sits earlier in topological
                           order, so its team was already re-keyed by its feeder
                           slot below — the released id is therefore valid.

After stamping, each successor `FormTransportUnit`'s team slot is re-keyed to the
freshly stamped id (mirrors `align_with_predecessor(::FormTransportUnit,::RobotGo)`);
because the transport-unit entity is shared, that also fixes the `DepositCargo`
team the post-deposit `RobotGo` reads. Every thread is rooted at a `RobotStart`
(always valid) and each transport team is keyed before its deposit's successor is
processed, so no `RobotGo` is ever left invalid. Only `RobotGo` ids and
transport-team keys change; graph structure, configs and times are untouched.
"""
# (보류된 빌딩블록 — 현재 fault_robot_and_reassign! 에 연결되어 있지 않음.)
# 그래프 엣지를 따라 모든 RobotGo 의 로봇 id 를 RobotStart 를 뿌리로 삼아 결정론적으로 다시 찍는 함수.
# `::OperatingSchedule` : 첫 인자 타입을 명시(이 타입일 때만 이 메서드 적용).
function rethread_robot_ids!(sched::OperatingSchedule, scene_tree)
    for v in topological_sort_by_dfs(sched)      # 위상정렬 순서(앞→뒤)로 모든 정점 순회 — 선행자가 먼저 처리되도록
        node = get_node_from_vtx(sched, v)       # 정점 v 의 노드(정점번호로 직접)
        node isa RobotGo || continue             # RobotGo 가 아니면 건너뜀
        ins = Graphs.inneighbors(sched, v)       # 들어오는 이웃(선행자)들
        isempty(ins) && continue                      # detached RobotGo: leave as-is  # 선행자가 없으면(떨어진 노드) 그대로 둠
        pred = get_node_from_vtx(sched, first(ins))   # 첫 선행자 노드(RobotGo 는 선행자가 1개)
        # 선행자 종류에 따라 새 id 를 결정 (if 식 전체가 값을 반환).
        new_id = if pred isa RobotStart || pred isa RobotGo
            entity(pred).id                           # 출발노드/직전 RobotGo → 그 로봇 id 를 그대로 물려받음
        elseif pred isa DepositCargo
            mid = get_matching_child_id(pred, node)   # 하역(DepositCargo)에서 이 슬롯에 풀려나는 팀원 id
            (mid === nothing || !valid_id(mid)) ? nothing : mid  # 없거나 무효면 nothing, 아니면 그 id
        else
            nothing                                   # 그 외 선행자는 처리 안 함
        end
        new_id === nothing && continue                # 정할 id 가 없으면 건너뜀
        if entity(node).id != new_id                  # 현재 id 와 새 id 가 다를 때만 교체
            # Pull the canonical RobotNode for new_id (its own geometry) the same
            # way align_with_predecessor(::RobotGo,::DepositCargo) does.
            robot_start = get_node(sched, RobotStart(RobotNode(new_id, entity(node))))  # new_id 의 정식 로봇노드(고유 형상) 조회
            node = RobotGo(RobotNode(new_id, entity(robot_start)),  # 그 로봇으로 id 만 바꾼 새 RobotGo 생성
                           start_config(node), goal_config(node), node_id(node))
            replace_in_schedule!(sched, scene_tree, node, node_id(node))  # 스케줄에서 교체
        end
        # Re-key every successor FormTransportUnit team slot to this robot.
        # 후속 운반팀(FormTransportUnit)의 팀 슬롯도 이 로봇 id 로 다시 맞춤.
        for vf in Graphs.outneighbors(sched, v)       # 나가는 이웃(후속)들
            fnode = get_node_from_vtx(sched, vf)
            fnode isa FormTransportUnit || continue   # 운반팀이 아니면 건너뜀
            matching_id = get_matching_child_id(fnode, node)  # 이 노드에 대응하는 팀 슬롯의 현재 id
            if matching_id !== nothing && matching_id != new_id  # 있고 + 다르면
                swap_robot_id!(entity(fnode), matching_id, new_id)  # 팀 명부 키를 새 id 로 교체
            end
        end
    end
    return true
end

"""
    robot_frontier_vtxs(sched, agent) -> Vector{Int}

The vertices where `agent` enters the re-solvable future (see
`is_agent_frontier`). Reads the current `RESPEC_FROZEN` boundary, so set that
first if calling outside `fault_robot_and_reassign!`.
"""
# 주어진 로봇(agent)이 "재최적화 가능한 미래"로 진입하는 경계(frontier) 정점들을 모은다.
function robot_frontier_vtxs(sched, agent::AbstractID)
    out = Int[]                                  # 결과 정점번호 배열
    for v in Graphs.vertices(sched)              # 모든 정점 순회
        node = get_node_from_id(sched, get_vtx_id(sched, v))
        is_agent_frontier(sched, v, node, agent) && push!(out, v)  # 경계 노드면 추가
    end
    return out
end

"""
    transport_teams_with_agent(env, agent; pending_only=true) -> Vector{AbstractID}

The FormTransportUnit node ids whose team currently includes a RobotGo bound to
`agent`. Used to verify the agent was actually freed from transport work. With
`pending_only`, frozen (closed/active) tasks are excluded — the agent may still
legitimately appear in already-finished work (the immutable past).
"""
# 현재 팀에 agent(로봇)에 묶인 RobotGo 가 들어있는 FormTransportUnit 노드들의 id 를 모은다.
# pending_only=true 면 이미 얼린(완료/진행중) 작업은 제외 — 로봇이 정당하게 과거 작업에 남아있을 수 있으므로.
function transport_teams_with_agent(env, agent::AbstractID; pending_only=true)
    sched = env.sched
    frozen = build_invariant(env)                # 현재 얼린 과거(완료 노드 등) 정보
    # 핀(고정)된 ID 집합 = 완료 노드 ∪ 진행중 노드. union 은 합집합.
    pinned_ids = union(frozen.closed_nodes,
        Set{AbstractID}(get_vtx_id(sched, v) for v in env.cache.active_set))
    out = AbstractID[]                           # 결과 id 배열
    for v in Graphs.vertices(sched)              # 모든 정점 순회
        node = get_node_from_id(sched, get_vtx_id(sched, v))
        matches_template(FormTransportUnit, get_node(sched, v)) || continue  # 운반팀 노드가 아니면 건너뜀
        fid = get_vtx_id(sched, v)               # 이 운반팀 노드의 id
        pending_only && (fid in pinned_ids) && continue  # pending 만 볼 때, 고정된 팀이면 건너뜀
        for vp in Graphs.inneighbors(sched, v)   # 이 팀으로 들어오는 선행 노드(팀원 후보)들
            pnode = get_node_from_id(sched, get_vtx_id(sched, vp))
            if pnode isa RobotGo && bound_to_agent(pnode, agent)  # 그게 agent 에 묶인 RobotGo 면
                push!(out, fid)                  # 이 팀을 결과에 추가
                break                            # 하나 찾으면 이 팀은 끝(다음 팀으로)
            end
        end
    end
    return out
end

"""
    fault_robot_and_reassign!(env, agent; optimizer, verbose) -> NamedTuple

Top-level Stage-1 core logic, LLM-free. Models the OOD action that the agentic
layer will later drive from a natural-language fault report:

  1. freeze completed/in-progress work,
  2. release the pending assignment edges (schedule surgery),
  3. build the `ForbidAgent(agent)` formal spec,
  4. VERIFY it (trial solve against the freeze + the spec),
  5. on Admit: re-solve and commit (`update_project_schedule!` + `reset_cache!`),
     on Reject: leave the schedule released-but-unsolved and report (caller
     engages the safe fallback).

Returns a NamedTuple with `:status` in (:admitted, :rejected, :fallback) plus
diagnostics. NEVER lets an unverified schedule become the schedule-of-record.
"""
# 로봇 고장 → 검증된 재배정의 최상위 함수(Stage-1 핵심 로직, LLM 없이도 동작).
# 키워드 인자: optimizer(솔버), verbose(로그 출력 여부), resume(중간 재개 모드 여부).
function fault_robot_and_reassign!(env, agent::AbstractID;
                                   optimizer = _respec_optimizer(), verbose::Bool = true,
                                   resume::Bool = false)
    sched = env.sched
    teams_before = transport_teams_with_agent(env, agent; pending_only = true)  # 재배정 전, agent 가 속한 운반팀 수(검증용)
    ms0 = makespan(sched)                        # 재배정 전 전체 완료시간(makespan)

    invariant = build_invariant(env)             # 얼린 과거(완료/진행중) + 시간 경계 등 불변식 구성
    # Tell the ForbidAgent compiler which nodes are the frozen past, so it can
    # locate the faulted agent's emergence frontier (== origin at t=0).
    closed_ids = Set{AbstractID}(get_vtx_id(sched, v) for v in env.cache.closed_set)  # 완료 노드 ID 집합
    active_ids = Set{AbstractID}(get_vtx_id(sched, v) for v in env.cache.active_set)  # 진행중 노드 ID 집합
    RESPEC_FROZEN[] = closed_ids                 # completed: not a frontier  # 전역 상자에 완료집합 저장(=경계가 아님)
    RESPEC_PINNED[] = union(closed_ids, active_ids)  # pinned: a frontier's predecessor  # 핀된 집합(경계의 선행자)
    # Snapshot the (feasible) pre-fault assignment BEFORE surgery; it warm-starts
    # the re-solve so the solver only has to *repair* the faulted robot's share
    # instead of re-deriving the whole assignment from scratch (much faster and,
    # for the worst-case t=0 full re-solve, the difference between reliably
    # finding a feasible point and timing out).
    # 수술(엣지 제거) 전에 현재 배정을 스냅샷 → 재최적화의 "워밍스타트"(따뜻한 출발점)로 사용해 속도/안정성 향상.
    warm = SparseMatrixCSC{Float64,Int}(adjacency_matrix(sched))  # 인접행렬을 희소행렬로 저장
    removed = release_pending_assignments!(env, invariant; faulted = agent)  # 미래 배정 엣지 제거(스케줄 수술)
    # `verbose && @info ...` : verbose 가 참일 때만 정보 로그 출력. `*` 로 여러 문자열을 이어붙임.
    verbose && @info "[REASSIGN] released $(length(removed)) pending assignment edge(s); " *
                     "frozen: $(length(invariant.frozen_t0)) t0 / $(length(invariant.frozen_tF)) tF; " *
                     "agent $(agent) was on $(length(teams_before)) pending transport team(s)."

    # 형식 제약(ForbidAgent: 이 로봇 사용 금지)을 담은 재명세 제안 생성.
    # ConstraintSpec[ ... ] : ConstraintSpec 타입 원소를 담는 배열 리터럴. 0.0 은 적용 시점(t=0).
    proposal = RespecProposal(ConstraintSpec[ForbidAgent(agent, 0.0)],
                              "robot $(agent) reported a fault and is removed from service",  # 사람이 읽을 설명
                              "robot_fault")                                                   # 이벤트 종류 태그

    # 제안을 검증(얼린 과거 + 제약을 두고 시험 풀이). 반환은 Reject 또는 통과한 verdict.
    verdict = verify(proposal, env, invariant; optimizer = optimizer, warm_start = warm)
    if verdict isa Reject                        # 검증 거부(재배정 불가능)면
        verbose && @warn "[REASSIGN] REJECTED ($(verdict.reason)): $(verdict.detail) -> fallback"  # 경고 로그
        # NamedTuple 반환: `(이름 = 값, ...)` 형태. 파이썬의 딕셔너리 비슷하지만 점(.)으로 접근하는 가벼운 묶음.
        return (status = :rejected, reason = verdict.reason, detail = verdict.detail,
                removed = length(removed), teams_before = length(teams_before))
    end

    # --- commit the verified re-solve ----------------------------------------
    # 검증을 통과했으니 실제로 재최적화(MILP 풀이)를 수행해 새 스케줄을 확정.
    # t0_/tF_ 는 얼린 시간 경계, warm_start_soln 은 따뜻한 출발점, extra_constraints 는 검증된 제약.
    milp = formulate_milp(SparseAdjacencyMILP(), sched, env.scene_tree;
        optimizer = optimizer, t0_ = invariant.frozen_t0, tF_ = invariant.frozen_tF,
        warm_start_soln = warm, extra_constraints = verdict.proposal)
    optimize!(milp)                              # 최적화 실행
    if primal_status(milp) != MOI.FEASIBLE_POINT  # 해를 못 찾으면(검증과 불일치하는 드문 경우)
        verbose && @warn "[REASSIGN] committed solve disagreed with verifier -> fallback"
        return (status = :fallback, reason = :committed_infeasible,  # 안전 폴백으로 처리
                removed = length(removed), teams_before = length(teams_before))
    end

    ok = update_project_schedule!(nothing, milp, sched, env.scene_tree)  # 풀이 결과를 실제 스케줄에 반영(로봇 id 재기록 포함)
    # NOTE: an authoritative id re-thread (`rethread_robot_ids!`) was tried here as
    # the doc's Option 1 and shown INSUFFICIENT — geometry-miss orphan RobotGos keep
    # stale ids and still double-book (see docs/resume_fulloop_status_2026-06-24.md).
    # Left unwired so the production path matches the recorded known state.
    # Measure the agent's remaining pending teams BEFORE reset_cache! (which
    # empties closed_set and would make completed teams look "pending").
    teams_after = transport_teams_with_agent(env, agent; pending_only = true)  # 재배정 후 agent 의 남은 팀 수(0 이어야 정상)
    ms1 = makespan(sched)                        # 재배정 후 makespan
    # reset_cache! re-seeds the cache from ROOT nodes and clears closed_set: correct
    # for a from-scratch plan, but it ERASES execution progress. For true mid-sim
    # resumption (resume=true, the live-sim / maybe_respecify! path) we keep the
    # already-closed nodes and re-seed only the remaining frontier so the build
    # continues to completion instead of restarting. Default false preserves the
    # original from-scratch behaviour for the standalone reassign tests.
    # 삼항식: resume 참이면 진행상태를 보존한 채 재개(중간 재개), 거짓이면 처음부터 다시(기본 — 단독 테스트용).
    resume ? reset_cache_resume!(env.cache, sched) : reset_cache!(env.cache, sched)
    verbose && @info "[REASSIGN] ADMITTED $(verdict.n_constraints) forbid-constraint(s); " *
                     "valid=$(ok); agent now on $(length(teams_after)) pending team(s); " *
                     "makespan $(round(ms0, digits=2)) -> $(round(ms1, digits=2))"
    # 성공 결과를 NamedTuple 로 반환(상태, 유효성, 제약 수, 제거 엣지 수, 전/후 팀 수와 makespan).
    return (status = :admitted, valid = ok, n_constraints = verdict.n_constraints,
            removed = length(removed), teams_before = length(teams_before),
            teams_after = length(teams_after), makespan_before = ms0, makespan_after = ms1)
end
