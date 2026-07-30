# =============================================================================
# replace_robot.jl  --  ReplaceAgent enactment: spare 1:1 chain hand-off.
#
# OOD 1-1 (robot breakdown) recovery via a SPARE pool. When robot F breaks down,
# the nearest directional spare pool (ood_injection.jl) donates one IDLE robot S
# whose task chain is EMPTY. Instead of asking the MILP to redistribute F's work
# to the remaining robots (fault_robot_and_reassign! -- which carries the
# reassignment double-booking, docs/resume_fulloop_status_2026-06-24), we SPLICE
# F's remaining work thread onto S with NO solver call:
#
#   F (broken):  ...closed... -> fg(free,F) --asg--> slot1(F) -> Form -> Go -> Deposit -> free(F) -> slot2(F) ...
#   S (idle):    RobotStart(S) -> sg(free,S)
#
#   hand-off:    remove fg --asg--> slot1 ;  add sg --asg--> slot1 ;
#                re-stamp slot1.. (every non-closed RobotGo bound to F) F -> S ,
#                re-key every non-closed FormTransportUnit team F -> S .
#
# After the splice S has ONE thread (RobotStart(S) -> sg -> slot1 -> ...), F's
# thread dead-ends at fg (F is parked / becomes a static obstacle), and NO node is
# double-claimed -- the structural property that side-steps the double-booking.
# The assignment (which slots exist, their geometry) is UNCHANGED, so there is no
# MILP re-decision and therefore no geometry-miss orphan (the reassign failure
# mode). S physically drives from its pool into slot1's pickup; goals are absolute
# world configs, so the motion stack routes it there.
#
# Like ForbidZone/restage, this is NOT a MILP re-spec: it is graph surgery,
# dispatched specially in maybe_respecify! (`_is_robot_replace`), and finishes with
# reset_cache_resume! exactly like restage_assembly!.
# =============================================================================
#
# ─────────────────────────────────────────────────────────────────────────────
#  [한국어 설명] 이 파일이 하는 일 (처음 읽는 사람을 위한 안내)
# ─────────────────────────────────────────────────────────────────────────────
#  상황: 여러 로봇이 협력해 구조물을 조립하는 시뮬레이터에서, 로봇 하나(F)가
#        빌드 도중 고장 남 (OOD 1-1 = 학습분포 밖 상황 중 "로봇 고장" 유형).
#  기존 방식: MILP(정수최적화) 스케줄러를 다시 돌려 F 의 남은 일을 다른 로봇들에게
#             재분배 → 느리고, "이중배정(double-booking)" 버그를 일으킴.
#  이 파일의 방식: MILP 를 다시 부르지 않고, 예비(spare) 로봇 S 에게 F 의 "남은
#        작업 실(thread)"만 그래프 수술(graph surgery)로 갈아 끼운다(splice).
#        즉 스케줄 그래프의 엣지(edge)를 잘라내고 다시 이어 붙이는 방식.
#  이 파일의 프로젝트 내 역할: LLM/surrogate "re-spec(재명세)" 복구 레이어가
#        고장에 반응해 호출하는 "ReplaceAgent" 실행부(enactment). 위 영어 헤더가
#        splice 알고리즘의 정확한 그림(F 실 → S 로 인계)을 담고 있다.
#  두 가지 복구 경로가 있음:
#    (1) replace_robot!  : 스케줄 상에서 F 의 id 를 S 로 "재도장(re-stamp)"하는
#         원래 방식. 잔여 버그(전송 stall, 이중배정 등)의 근원.
#    (2) hot_swap_robot! : F 의 RobotID 를 "그대로 유지"하고 창고(depot)에서 몸체
#         (asset)만 갈아끼우는 정체성 보존(identity-preserving) 방식 = 더 견고한 길.
#         스케줄을 안 건드리므로 re-stamp 버그가 구조적으로 불가능.
#
#  [문법 참고] 비직관적인 Julia 문법 (처음 보는 사람용)
#   · f(x::T)         : x 가 타입 T 일 때만 쓰이는 메서드(다중 디스패치). 같은 이름
#                       함수를 타입만 바꿔 여러 개 정의 = "타입마다 다른 동작".
#   · ::AbstractID    : 인자 뒤 `::타입` = 그 인자의 타입 제한(타입 주석/annotation).
#   · :symbol (:foo)  : 콜론으로 시작하는 값 = Symbol(가벼운 문자열 같은 상수 라벨).
#                       상태 반환의 `status = :replaced` 등이 그 예.
#   · foo!            : `!` 로 끝나는 함수 = 인자를 직접(in-place) 수정한다는 관례.
#   · @info, @warn, @__MODULE__ : `@`로 시작 = 매크로(코드 실행 전에 코드를 변형).
#   · do ... end      : 함수에 "블록(익명함수)"을 넘기는 문법 (이 파일엔 드묾).
#   · Ref(x)          : 값 하나를 담는 가변 상자. `R[]` 로 읽고/쓴다(전역 가변상태용).
#   · try ... catch;  : 예외를 삼키는 안전장치. `catch; nothing end` = 실패하면 nothing.
#   · a && b          : 짧은 회로. `조건 && 실행` = 조건 참일 때만 실행(if 축약).
#   · scene tree edge : 씬 트리(scene tree)는 로봇·부품·운반유닛의 부모-자식 그래프.
#                       has_edge/add_edge!/rem_edge! = 그 간선(포함/부착 관계) 조작.
#   · 스케줄 그래프    : sched 는 "누가 무엇을 언제" 하는지의 유향그래프(DAG). 정점
#                       (vertex)=작업노드, 배정엣지(assignment edge)=로봇→작업 연결.
# ─────────────────────────────────────────────────────────────────────────────

"""
    _robot_go_nodes(sched, agent) -> Vector{Int}

Vertices of every `RobotGo` currently bound to `agent` (its id == agent). The
robot's whole presence in the schedule's free/slot nodes.
"""
# 스케줄에서 현재 로봇 agent 에 묶인 모든 RobotGo 정점을 모은다(자유노드 + 배정슬롯).
function _robot_go_nodes(sched, agent::AbstractID)
    out = Int[]
    for v in Graphs.vertices(sched)                            # 스케줄 그래프의 모든 정점 v 를 순회
        node = get_node_from_id(sched, get_vtx_id(sched, v))   # 정점 v -> 노드 id -> 실제 노드 객체
        # RobotGo(로봇 이동 작업)이면서 그 노드가 agent 에 묶여 있으면 결과에 추가
        node isa RobotGo && bound_to_agent(node, agent) && push!(out, v)
    end
    return out
end

"""
    _idle_free_node(sched, spare) -> Union{Int,Nothing}

The spare's idle free `RobotGo` vertex: a `RobotGo` bound to `spare` whose single
predecessor is its `RobotStart` AND which has **no outgoing assignment edge** (a
genuinely unassigned spare has exactly this one, work-free node). `nothing` if the
spare has no such node (already used / not a spare / already carries work).

The outgoing-edge check (B) is a hard guard against double-booking: if a "spare" was
actually given work by the initial assignment (a phantom spare), its free node already
feeds a task chain; splicing a second task onto it would over-subscribe one robot and
wedge both teams (permanent `all_missing`). We refuse such a node so the caller falls
back / reports insufficient spares instead of silently corrupting the schedule. The
upstream fix (A-1: exclude spares from initial assignment) keeps this from ever tripping;
this guard makes the corruption structurally impossible even if that invariant regresses.
"""
# 예비 로봇 S 의 "놀고 있는 자유 RobotGo" 정점 — 선행자가 RobotStart 이고 나가는 배정엣지가 없는 노드.
function _idle_free_node(sched, spare::AbstractID)
    for v in Graphs.vertices(sched)
        node = get_node_from_id(sched, get_vtx_id(sched, v))
        (node isa RobotGo && bound_to_agent(node, spare)) || continue  # spare 에 묶인 RobotGo 만 검사
        # B: 이미 나가는 배정엣지(RobotGo→RobotGo)가 있으면 = 실제 작업을 든 로봇 → 인계 대상 아님(double-book 차단)
        any(is_assignment_edge(sched, v, v2) for v2 in Graphs.outneighbors(sched, v)) && continue
        for vp in Graphs.inneighbors(sched, v)                 # v 의 선행자(들)를 확인
            # 선행자가 RobotStart 면 = 아직 아무 일도 안 한 "출발 직후 자유노드" -> 이게 인계 지점
            get_node_from_id(sched, get_vtx_id(sched, vp)) isa RobotStart && return v
        end
    end
    return nothing
end

"""
    _first_pending_assignment(env, faulted) -> Union{Tuple{Int,Int},Nothing}

F's frontier `(fg, slot1)`: the free->slot assignment edge where F enters its
re-solvable future. `fg` is a NON-closed `RobotGo` bound to F whose predecessor is
its `RobotStart` (t=0) or a frozen/closed node (mid-build), and whose outgoing
edge goes to another `RobotGo` (the assignment edge, is_assignment_edge). `nothing`
if F has no pending assignment (nothing left to hand off).
"""
# F 가 "재계획 가능한 미래"로 들어서는 frontier 자유노드 fg 와 그 첫 배정엣지 fg->slot1 을 찾는다.
function _first_pending_assignment(env, faulted::AbstractID)
    sched = env.sched
    for v in _robot_go_nodes(sched, faulted)
        v in env.cache.closed_set && continue                 # 이미 끝난 노드 제외
        node = get_node_from_id(sched, get_vtx_id(sched, v))
        is_frontier = false                                    # fg 는 과거(closed)/RobotStart 에서 emerge 해야 함
        for vp in Graphs.inneighbors(sched, v)
            pnode = get_node_from_id(sched, get_vtx_id(sched, vp))
            if pnode isa RobotStart || (get_vtx_id(sched, vp) in env.cache.closed_set)
                is_frontier = true; break
            end
        end
        is_frontier || continue
        for v2 in Graphs.outneighbors(sched, v)                # fg 의 나가는 엣지 중 배정엣지(RobotGo->RobotGo)
            is_assignment_edge(sched, v, v2) && return (v, v2)
        end
    end
    return nothing
end

"""
    _restamp_robot_go!(env, v, new_id) -> Bool

Re-stamp `RobotGo` vertex `v` to robot `new_id` (preserving its start/goal configs
and node id), and re-key every successor `FormTransportUnit` team that listed the
old id. Mirrors `reset_slot_to_invalid!` (reassign.jl) but stamps a CHOSEN valid id
(the spare) rather than a fresh invalid one. Returns false if `v` is not a RobotGo
or already carries `new_id`.
"""
# RobotGo 정점 v 의 로봇 id 를 new_id(예비)로 갈아끼우고, 그 뒤 운반팀(FormTransportUnit) 명부의 키도 함께 교체.
function _restamp_robot_go!(env, v::Int, new_id::AbstractID)
    sched = env.sched
    node = get_node_from_id(sched, get_vtx_id(sched, v))
    node isa RobotGo || return false                          # RobotGo 가 아니면 갈아끼울 게 없음
    old_id = entity(node).id                                  # 지금 이 노드에 박혀 있는(도장된) 로봇 id
    old_id == new_id && return false                          # 이미 new_id 면 할 일 없음
    # Pull the CANONICAL RobotNode for new_id (its OWN scene-linked transform), exactly as
    # reassign.jl `rethread_robot_ids!` does. Minting `RobotNode(new_id, entity(node))` from
    # the OLD robot's node makes a FRESH RobotNode whose transform is DISCONNECTED from the
    # scene_tree robot the controller/RVO actually drives. is_goal's `feeder_at_goal`
    # (route_planning.jl:459-463) reads `entity(node)`, so with a disconnected node the spare
    # physically reaches the unit (`in_capture` true) yet feeder_at_goal stays FALSE forever
    # -> the RobotGo -> FormTransportUnit transition never fires (the single-task stall).
    # new_id 의 "정식(canonical)" RobotNode 를 씬트리에서 가져온다(그 로봇 자신의 씬 연결 transform).
    # 주의: 옛 로봇 노드에서 RobotNode(new_id, ...) 를 새로 찍어내면 transform 이 씬트리와 끊겨,
    #       spare 가 물리적으로 도착해도 feeder_at_goal 이 영영 false → 전송 전환이 안 일어남(single-task stall).
    robot_start = get_node(sched, RobotStart(RobotNode(new_id, entity(node))))
    # 새 RobotGo: 로봇 id 만 new_id 로 바꾸고 start/goal 좌표와 node id 는 그대로 유지(정체성 보존).
    new_node = RobotGo(RobotNode(new_id, entity(robot_start)),
                       start_config(node), goal_config(node), node_id(node))
    replace_in_schedule!(sched, env.scene_tree, new_node, node_id(node))  # 같은 node id 자리에 새 노드로 교체
    for vf in Graphs.outneighbors(sched, v)                    # 후속 운반팀 명부 re-key
        fnode = get_node_from_id(sched, get_vtx_id(sched, vf))
        # 뒤따르는 운반팀(FormTransportUnit) 명부에 old_id 가 있으면 그 키를 new_id 로 교체
        if fnode isa FormTransportUnit && haskey(robot_team(entity(fnode)), old_id)
            swap_robot_id!(entity(fnode), old_id, new_id)
        end
    end
    return true
end

"""
    _adopted_task_deposit(env, slot_v) -> Union{Int,Nothing}

Walk a slot `RobotGo` forward (slot -> FormTransportUnit -> TransportUnitGo ->
DepositCargo) to the `DepositCargo` vertex where its cargo is delivered — i.e. the
moment the carrying robot becomes free again. The serialization anchor for the
NEXT adopted task.
"""
# 어떤 slot(운반 시작 RobotGo)에서 시작해, 그 화물이 "내려놓아지는" DepositCargo 정점까지
# 따라가서 반환 — 그 지점이 곧 운반 로봇이 다시 "자유"로워지는 시점(직렬화의 기준점).
function _adopted_task_deposit(env, slot_v::Int)
    sched = env.sched
    # Follow the slot's OWN transport chain by EXACT node type at each hop:
    #   slot(RobotGo) -> FormTransportUnit -> TransportUnitGo -> DepositCargo.
    # A plain BFS over all out-edges wanders into shared downstream build structure
    # (FTU/TUGo branch), returning a deposit on a DIFFERENT task — which mis-serializes
    # the spare. This linear type-walk returns THIS slot's deposit only.
    # slot 자신의 운반 사슬만 "노드 타입"을 정확히 짚어가며 한 칸씩 전진:
    #   slot(RobotGo) → FormTransportUnit → TransportUnitGo → DepositCargo.
    # 그냥 BFS 로 모든 나가는 엣지를 훑으면 공유되는 하류 구조로 새어 나가 "다른 작업"의
    # deposit 을 잘못 반환함 → 이 타입-따라가기(type-walk)는 이 slot 의 deposit 만 정확히 반환.
    _succ_of_type(v, T) = begin                               # v 의 후속 중 타입이 T 인 첫 정점을 반환하는 헬퍼
        r = nothing
        for w in Graphs.outneighbors(sched, v)
            get_node_from_id(sched, get_vtx_id(sched, w)) isa T && (r = w; break)  # 타입 맞으면 잡고 중단
        end
        r
    end
    ftu = _succ_of_type(slot_v, FormTransportUnit); ftu === nothing && return nothing  # slot → 팀형성
    tug = _succ_of_type(ftu, TransportUnitGo);       tug === nothing && return nothing  # 팀형성 → 운반이동
    return _succ_of_type(tug, DepositCargo)                                             # 운반이동 → 내려놓기
end

# The serialization edges (dep_i -> slot_{i+1}) that _serialize_spare_frontiers! /
# _enforce_serial_frontiers! ADD to force a single spare to do adopted tasks one-at-a-time. Recorded so
# the endgame-wedge recovery can find and dissolve exactly those (a `dep_i` that never closes -- because
# its multi-robot team never syncs on the spare's shifted timeline -- gates `slot_{i+1}` and everything
# behind it forever: the documented cyclic cargo-dependency residual). Vertex indices are stable across
# reset_cache_resume! (no renumbering); cleared per build via clear_wedge_edges!.
# [한] WEDGE_EDGES: 하나의 spare 가 여러 작업을 "한 번에 하나씩"만 하도록 강제하려고 추가한
#      직렬화 엣지(dep_i → slot_{i+1}) 목록. 끝판(endgame) 교착 복구가 정확히 이 엣지들을
#      찾아 풀 수 있게 기록해 둠. Ref(...) = 전역 가변 상자, WEDGE_EDGES[] 로 내용에 접근.
const WEDGE_EDGES = Ref(Vector{Tuple{Int,Int}}())
# Gates the endgame recovery has DISSOLVED — the per-step `_enforce_serial_frontiers!` must NOT
# re-add these (it would instantly re-wedge the slot the recovery just freed).
# [한] DISSOLVED_GATES: 복구가 "이미 풀어준" 게이트 집합. 매 스텝 도는 직렬화 함수가 이걸
#      다시 추가하면 방금 푼 slot 이 즉시 재교착되므로, 재추가 금지 목록으로 사용.
const DISSOLVED_GATES = Ref(Set{Tuple{Int,Int}}())
# [한] 위 두 전역 상태를 한꺼번에 비우는 함수(빌드 시작마다 호출). 반환값 없음(nothing).
clear_wedge_edges!() = (empty!(WEDGE_EDGES[]); empty!(DISSOLVED_GATES[]); nothing)

"""
    _serialize_spare_frontiers!(env, spare, sg, slot1) -> Int

Make the spare do its adopted tasks ONE AT A TIME. After re-stamping, several of
the faulted robot's pending slots can each have an already-CLOSED feeder, so
`reset_cache_resume!` would activate them ALL at once and the single spare would be
double-booked across concurrent transport teams (it can only be in one place, so the
others' `FormTransportUnit` never reaches "all members in position" -> deadlock; the
reassignment double-booking re-emerging on the spare). The faulted robot's tasks were
only TEMPORALLY serialized by the MILP (t0), not by graph edges, so we restore that
serialization explicitly: order the extra entry-frontiers by original t0 and chain
each behind the previous task's `DepositCargo` (the point the spare becomes free),
so exactly one is an active frontier at a time. t0 ordering keeps the added edges
acyclic. Returns the number of serialization edges added.
"""
# spare 가 넘겨받은 여러 작업을 "한 번에 하나씩" 하도록, 원래 스케줄 시간(t0) 순서대로 줄 세워
# 각 작업의 DepositCargo(로봇이 자유로워지는 지점) 뒤에 다음 작업 slot 을 엣지로 연결. 추가한 엣지 수 반환.
function _serialize_spare_frontiers!(env, spare::AbstractID, sg::Int, slot1::Int)
    sched = env.sched
    # ALL of the spare's adopted TRANSPORT-TASK slots = RobotGo bound to spare whose
    # successor is a FormTransportUnit (closed ones excluded — the past is fixed). The
    # MILP serialized these by time only; the closed feeders that expose them as
    # concurrent frontiers appear progressively during resume, so we chain EVERY
    # consecutive pair (not just the ones already frontier) to force strict order.
    slots = Int[]
    for v in _robot_go_nodes(sched, spare)                # spare 에 묶인 RobotGo 들 중에서
        v in env.cache.closed_set && continue             # 이미 끝난(closed) 과거 노드는 제외
        outs = Graphs.outneighbors(sched, v); isempty(outs) && continue
        # 바로 다음 노드가 FormTransportUnit(운반팀 형성)인 것만 = "운반 작업의 시작 slot"
        get_node_from_id(sched, get_vtx_id(sched, outs[1])) isa FormTransportUnit || continue
        push!(slots, v)
    end
    length(slots) <= 1 && return 0                        # 작업이 0~1개면 줄 세울 필요 없음
    sort!(slots, by = v -> Float64(get_t0(sched, v)))     # by original schedule time (원래 t0 시간순 정렬)
    G = get_graph(sched)
    dbg = get(ENV, "REPLACE_DEBUG", "0") == "1"
    dbg && println("[REPLACE-SER] spare FTU-slots (t0 order): $([(v, round(Float64(get_t0(sched,v));digits=1)) for v in slots])")
    n_chained = 0
    for i in 1:(length(slots) - 1)                        # 인접한 작업쌍 (i, i+1) 마다 연결
        dep = _adopted_task_deposit(env, slots[i])        # deposit of task i (spare becomes free)
        nxt = slots[i + 1]                                # slot of task i+1
        if dep === nothing
            dbg && println("[REPLACE-SER] slot $(slots[i]) -> $nxt SKIP: no deposit found")
            continue
        end
        if dep == nxt || Graphs.has_edge(G, dep, nxt)     # 같은 노드거나 이미 엣지가 있으면 건너뜀
            dbg && println("[REPLACE-SER] dep$(dep) -> $nxt SKIP: already edged")
            continue
        end
        # CYCLE GUARD: only add dep_i -> slot_{i+1} if slot_{i+1} can't already reach dep_i
        # (if it can, the two tasks are already ordered the other way -> adding would cycle
        # AND would fight the existing order). This also respects the real graph order over t0.
        # 사이클 방지: nxt 에서 dep 로 가는 경로가 이미 있으면(=반대 순서로 이미 정렬됨) 엣지를
        # 추가하면 순환(cycle)이 생기고 기존 순서와 충돌하므로 건너뜀. 실제 그래프 순서를 t0 보다 우선.
        if Graphs.has_path(G, nxt, dep)
            dbg && println("[REPLACE-SER] dep$(dep) -> $nxt SKIP: would cycle (nxt already reaches dep)")
            continue
        end
        add_edge!(sched, get_node(sched, dep), get_node(sched, nxt))  # task i deposit -> task i+1 slot (직렬화 엣지 추가)
        push!(WEDGE_EDGES[], (dep, nxt))                              # record for endgame-wedge recovery (복구용 기록)
        n_chained += 1
        dbg && println("[REPLACE-SER] added dep$(dep) -> slot$(nxt)")
    end
    return n_chained
end

"""
    _dedupe_spare_ftu_feeders!(env, spare, sg) -> Int

Repair the duplicate-feeder inconsistency the splice+re-stamp can leave: a
`FormTransportUnit` whose `robot_team` lists the spare ONCE but which has TWO (or
more) graph RobotGo feeders bound to the spare. A robot can't fill two slots of one
unit, so the extra feeders deadlock formation (the unit waits for the spare to be in
two places). The team dict is authoritative (it sets how many robots the unit needs),
so for each such FTU we KEEP the feeder reachable from the spare's idle node `sg`
(the one we deliberately spliced / its live thread) and DETACH each extra: drop its
edge into the FTU and PARK it (mark closed) so `reset_cache_resume!` never activates
it. Returns the number of extra feeders detached.
"""
# splice+re-stamp 후 생길 수 있는 "중복 feeder" 오류를 고침: 한 운반팀 명부엔 spare 가 1번만
# 있는데 그래프상 spare RobotGo feeder 가 2개 이상 붙은 경우(한 로봇이 한 팀의 두 자리를 못 채움 → 교착).
# 팀 명부가 기준이라, sg 에서 도달 가능한 feeder 만 남기고 나머지는 떼어내 park(닫음). 떼어낸 수 반환.
function _dedupe_spare_ftu_feeders!(env, spare::AbstractID, sg::Int)
    sched = env.sched; G = get_graph(sched)
    n_removed = 0
    for v in Graphs.vertices(sched)
        n = get_node_from_id(sched, get_vtx_id(sched, v))
        n isa FormTransportUnit || continue                       # 운반팀 형성 노드만 검사
        team = try robot_team(entity(n)) catch; nothing end       # 이 팀의 로봇 명부(딕셔너리)
        team === nothing && continue
        n_slots = max(1, count(==(spare), collect(keys(team))))   # spare slots this unit needs (팀이 필요로 하는 spare 자리 수)
        feeders = Int[]
        for vp in Graphs.inneighbors(sched, v)                    # 이 팀으로 들어오는 선행 RobotGo(feeder)들 수집
            pn = get_node_from_id(sched, get_vtx_id(sched, vp))
            (pn isa RobotGo && (try entity(pn).id == spare catch; false end)) && push!(feeders, vp)  # spare 소속 feeder만
        end
        length(feeders) <= n_slots && continue                    # 자리 수 이하면 중복 아님 → 통과
        # keep the feeder(s) reachable from sg; detach + park the surplus
        sortkey(vp) = Graphs.has_path(G, sg, vp) ? 0 : 1          # sg-reachable first (sg에서 닿는 feeder를 앞으로)
        sort!(feeders, by = sortkey)
        for vp in feeders[(n_slots + 1):end]                      # 필요한 자리 수를 넘는 잉여 feeder 들만 처리
            Graphs.rem_edge!(G, vp, v)                            # drop spurious slot -> FTU edge (가짜 엣지 제거)
            (vp in env.cache.closed_set) || push!(env.cache.closed_set, vp)  # park it (never activate) (닫아서 재활성 방지)
            n_removed += 1
        end
    end
    return n_removed
end

"""
    _park_spare_dead_rests!(env, spare) -> Int

Park the spare's surplus TERMINAL dead-end `RobotGo`s (the "robot rests here" nodes
with no successor). The faulted robot's chain had one terminal rest PER finished
carry (each `DepositCargo` releases the robot to a `RobotGo`); re-stamping hands the
spare ALL of them. An intermediate terminal rest (`succs=[]`, t0 earlier than the
final one) competes with the spare's real pending task: the controller can drive the
spare to a NEAR dead-end rest (which `is_goal` never closes — route_planning.jl:469)
instead of to the `FormTransportUnit` slot where a co-carrier waits, deadlocking the
team. Terminal nodes have no successors so nothing depends on them; keep only the
LATEST-t0 terminal (the legitimate final rest) and force-close the earlier ones so
`reset_cache_resume!` never activates them. Returns the number parked.
"""
# re-stamp 로 spare 에게 "쉬는 종점(dead-end RobotGo)"이 여러 개 넘어옴(원래 로봇이 짐 하나 내릴 때마다 하나씩).
# 중간의 쉬는 종점은 진짜 남은 작업과 경쟁해 교착을 일으키므로, t0 가 가장 늦은 "진짜 최종 휴식"만 남기고 나머진 닫음.
function _park_spare_dead_rests!(env, spare::AbstractID)
    sched = env.sched
    terms = Int[]
    for v in _robot_go_nodes(sched, spare)
        v in env.cache.closed_set && continue
        isempty(Graphs.outneighbors(sched, v)) && push!(terms, v)   # terminal dead-end rest (나가는 엣지가 없는 종점)
    end
    length(terms) <= 1 && return 0                                  # 종점이 1개 이하면 정리할 것 없음
    sort!(terms, by = v -> Float64(get_t0(sched, v)))               # earliest .. latest(final rest) (이른→늦은 순)
    n = 0
    for v in terms[1:(end - 1)]                                      # keep the final rest, park the rest (마지막 하나만 남김)
        push!(env.cache.closed_set, v); n += 1                       # 나머지 종점은 닫아서 활성화 방지
    end
    return n
end

"""
    _enforce_serial_frontiers!(env) -> Int

DYNAMIC serialization (proposal E1). The replace-time `_serialize_spare_frontiers!`
chains a spare's adopted transport tasks ONCE, but some become concurrently-active only
LATER during resume (a gating feeder closes mid-run), so a single spare can still end up
DRIVEN toward two `FormTransportUnit` slots at once — it can only be in one place, so the
other team's co-carrier waits forever (the multi-team hand-off stall).

This runs EVERY resume step and re-imposes "one active transport task per robot": for any
robot with >1 active `RobotGo` whose successor is a `FormTransportUnit`, keep the
earliest-`t0` slot active and chain each later slot behind the earlier task's
`DepositCargo` (the point the robot becomes free), then rebuild the cache so the deferred
slots deactivate. Idempotent (cycle-guarded, skips existing edges) so once serialized it
is a cheap no-op. In a NOMINAL build the MILP already serializes every robot, so no robot
has >1 active transport frontier and this never fires — it only repairs the post-hand-off
spare. Returns the number of precedence edges added this call.
"""
# 매 resume 스텝마다 도는 "동적 직렬화": 어떤 로봇이 운반 slot 을 동시에 2개 이상 활성화하고 있으면,
# 가장 이른 t0 하나만 두고 나머지는 앞 작업의 DepositCargo 뒤로 미뤄(엣지 추가) "로봇당 활성 운반작업 1개"를 유지.
# 정상 빌드에선 MILP 가 이미 직렬화해 두므로 전혀 발동 안 함(교체된 spare 만 손봄). 이번에 추가한 엣지 수 반환.
function _enforce_serial_frontiers!(env)
    sched = env.sched; G = get_graph(sched)
    byrobot = Dict{AbstractID,Vector{Int}}()                 # 로봇 id -> 그 로봇의 활성 운반 slot 목록
    for v in env.cache.active_set                            # 현재 "활성(active)" 정점들만 훑음
        n = get_node_from_id(sched, get_vtx_id(sched, v))
        n isa RobotGo || continue
        outs = Graphs.outneighbors(sched, v); isempty(outs) && continue
        get_node_from_id(sched, get_vtx_id(sched, outs[1])) isa FormTransportUnit || continue  # 운반 slot 만
        rid = try entity(n).id catch; nothing end            # 이 RobotGo 를 든 로봇 id
        rid === nothing && continue
        push!(get!(byrobot, rid, Int[]), v)                  # 로봇별로 slot 을 모음(get! = 없으면 빈 배열 생성)
    end
    changed = 0
    for (_, slots) in byrobot
        length(slots) <= 1 && continue                       # no concurrent transport frontier (동시 작업 없음)
        sort!(slots, by = v -> Float64(get_t0(sched, v)))    # earliest .. latest (t0 이른→늦은 순)
        for i in 1:(length(slots) - 1)
            dep = _adopted_task_deposit(env, slots[i])       # task i frees the robot here (여기서 로봇이 자유로워짐)
            nxt = slots[i + 1]
            dep === nothing && continue
            (dep == nxt || Graphs.has_edge(G, dep, nxt)) && continue  # 이미 이어졌으면 통과
            Graphs.has_path(G, nxt, dep) && continue         # cycle guard (already ordered) (순환 방지)
            (dep, nxt) in DISSOLVED_GATES[] && continue      # never re-add a gate the recovery dissolved (푼 게이트 재추가 금지)
            add_edge!(sched, get_node(sched, dep), get_node(sched, nxt))  # dep → nxt 직렬화 엣지 추가
            push!(WEDGE_EDGES[], (dep, nxt))                 # record for endgame-wedge recovery
            changed += 1
        end
    end
    changed > 0 && reset_cache_resume!(env.cache, sched)      # deferred slots deactivate (미룬 slot 들 비활성화)
    return changed
end

"""
    reform_stuck_teams!(env; min_ready=1) -> Int

CLOSED-LOOP TEAM RE-FORMATION (the robust deadlock fix the LLM can trigger). A
`FormTransportUnit` needs ALL its team robots in position SIMULTANEOUSLY
(route_planning.jl:480-488). After a single-spare hand-off the spare arrives on a
different timeline, so a team can wedge: most members reach their slots and WAIT,
their bodies blocking the path of the last straggler, which then can never arrive →
the team never forms → the build stalls (the multi-robot frontier).

This RE-ESTABLISHES every mostly-formed but wedged team by snapping its straggler
members directly into their prescribed carrying slots
(`global_transform(tu) ∘ child_transform(tu, mid)`) — scene body AND RVO agent — so
the next `is_goal` check sees the whole team in position and the unit forms. It is
the orchestrator's deliberate intervention to clear a physical deadlock (an
alternative to nudging RVO priorities, which is only marginal). Only teams with
`>= min_ready` members already captured are reformed (so it never force-assembles a
team that has not even started gathering). Returns the number of robots repositioned.

Intended to fire on a STALL (no progress for K steps), exactly when the wedge is
real — see the `ReformTeam` dispatch / the resume-loop trigger.
"""
# 교착된 운반팀을 "다시 형성"시키는 폐루프(closed-loop) 복구: 팀원 로봇들을 정해진 운반 자리
# (global_transform(tu) ∘ child_transform)로 씬 몸체+RVO 를 직접 순간이동(snap)시켜 팀이 곧바로
# 형성되게 함. min_ready 이상 모인 팀만 대상, snap_all=true 면 모든 팀원을 강제로 붙임. 옮긴 로봇 수 반환.
function reform_stuck_teams!(env; min_ready::Int = 1, snap_all::Bool = false)
    sched = env.sched; st = env.scene_tree
    n_moved = 0
    seen = Set{AbstractID}()                                  # 운반유닛당 한 번만 처리하려는 방문표시
    for v in collect(env.cache.active_set)
        n = get_node_from_id(sched, get_vtx_id(sched, v))
        n isa RobotGo || continue
        outs = Graphs.outneighbors(sched, v); isempty(outs) && continue
        nxt = get_node_from_id(sched, get_vtx_id(sched, outs[1]))
        nxt isa FormTransportUnit || continue
        tu = entity(nxt)                         # 이 slot 이 형성하려는 운반유닛(TransportUnit)
        node_id(tu) in seen && continue          # one pass per transport unit
        push!(seen, node_id(tu))
        team = try robot_team(tu) catch; nothing end
        team === nothing && continue
        ready = 0; stragglers = AbstractID[]; members = AbstractID[]  # 도착한 수 / 낙오자 / 전체 팀원
        for (mid, _) in team
            rn = try get_node(st, mid) catch; nothing end
            rn === nothing && continue
            push!(members, mid)
            # 잡히는 거리(capture distance) 안에 있으면 ready, 아니면 낙오자(straggler)로 분류
            (is_within_capture_distance(tu, rn) ? (ready += 1) : push!(stragglers, mid))
        end
        # A team is WEDGED if it is mostly-formed (>= min_ready members already in place) but still
        # has members out of position. Snapping ONLY the stragglers left the already-"ready"
        # members free to DRIFT off their slots (RVO repulsion from cargo/neighbours) before the
        # all-at-once capture check could fire, so the unit never locked and everyone wandered
        # near the cargo until the next reform — the "robot circles for a while" symptom, in
        # windows aligned with the reform interval. FIX: snap EVERY member to its exact carrying
        # slot AND capture the unit immediately (add the scene-tree parent edges), so the formation
        # LOCKS and cannot drift back apart.
        # 교착 판정: snap_all 이면 팀원이 있기만 하면, 아니면 (min_ready 이상 모였고 낙오자가 남았을 때)
        wedged = snap_all ? !isempty(members) : (ready >= min_ready && !isempty(stragglers))
        wedged || continue
        for mid in members                                              # snap ALL members — decisive (모든 팀원을 붙임)
            rn = get_node(st, mid)
            has_component(tu, mid) || continue
            desired = global_transform(tu) ∘ child_transform(tu, mid)   # this member's carrying slot (이 팀원이 짐을 드는 정확한 자리, ∘=변환 합성)
            set_desired_global_transform!(rn, desired)                  # snap the scene body in (씬 몸체를 그 자리로 순간이동)
            if use_rvo() && has_vertex(rvo_global_id_map(), mid)
                try rvo_set_agent_position!(rn, project_to_2d(desired.translation)) catch end  # and the RVO agent (RVO 에이전트도 함께)
            end
            n_moved += 1
        end
        try capture_robots!(tu, st) catch end                           # LOCK the formation now (지금 바로 팀 형성을 확정=씬트리 부모엣지 부착)
    end
    # Register any just-completed transport unit(s) in the RVO map. Snapping the
    # stragglers into their carrying slots makes the unit is_in_formation, but the
    # callers (the respec dispatch in replan.jl AND the step_to harness in
    # tools/spare_replace_test.jl) drive the schedule via reset_cache_resume! /
    # step_environment! WITHOUT the nominal update_planning_cache!->update_rvo_sim!
    # refresh (route_planning.jl:420). Without this the new TransportUnit agent is
    # absent from rvo_global_id_map(), so its TransportUnitGo either crashes
    # (rvo_get_agent_idx -> BoundsError[-1]) or is skipped forever by the
    # step_environment! guard and the reformed team never drives to goal. Doing it
    # here keeps every caller correct. update_rvo_sim! rebuilds only when
    # rvo_sim_needs_update is true, so it is inert when nothing newly formed.
    n_moved > 0 && update_rvo_sim!(env)                       # 새로 형성된 유닛을 RVO 맵에 등록(안 하면 이후 크래시/무시)
    return n_moved
end

# --- graduated self-healing recovery ----------------------------------------
# Enumerate every transport team that is CURRENTLY forming (an active RobotGo
# feeding a FormTransportUnit), with its ready/missing counts and gather point.
# Read-only; mirrors verify_reform / diagnose_transport_stall traversal.
# [한] 지금 "형성 중"인 모든 운반팀을 (준비/부족 인원 수, 모이는 지점 gather 와 함께) 열거. 읽기 전용(그래프 미변경).
function _forming_teams(env)
    sched = env.sched; st = env.scene_tree
    out = NamedTuple[]
    seen = Set{AbstractID}()
    for v in collect(env.cache.active_set)
        n = get_node_from_id(sched, get_vtx_id(sched, v))
        n isa RobotGo || continue
        outs = Graphs.outneighbors(sched, v); isempty(outs) && continue
        nxt = get_node_from_id(sched, get_vtx_id(sched, outs[1]))
        nxt isa FormTransportUnit || continue
        tu = entity(nxt)
        node_id(tu) in seen && continue
        push!(seen, node_id(tu))
        team = try robot_team(tu) catch; nothing end
        team === nothing && continue
        ready = 0; missing = 0
        for (mid, _) in team
            rn = try get_node(st, mid) catch; nothing end
            rn === nothing && continue
            is_within_capture_distance(tu, rn) ? (ready += 1) : (missing += 1)
        end
        gather = Vector{Float64}(global_transform(tu).translation[1:2])
        push!(out, (tu = tu, ready = ready, missing = missing, gather = gather))
    end
    return out
end

# Is 2D point `p` inside (within `margin` of) ANY active restriction zone?
# [한] 2D 점 p 가 활성화된 no-go(제한) zone 중 하나라도 (margin 여유 포함) 안쪽이면 true. 안전 배치 판정에 사용.
function _point_in_any_zone(p; margin::Float64 = 0.0)
    for (_, z) in RESTRICTION_ZONES[]                          # 등록된 모든 제한 zone 순회
        # 점과 zone 중심 사이 거리가 (반지름 + margin) 보다 작으면 zone 안 → true
        norm(Vector{Float64}(p) .- Vector{Float64}(get_center(z)[1:2])) < get_radius(z) + margin && return true
    end
    return false
end

"""
    recover_stalled_teams!(env; verbose=true) -> NamedTuple

GRADUATED, SAFETY-GATED self-healing for a sustained transport-formation stall
(the action behind a declined `ReformTeam`). The blind no-progress OOD only tells
us the build is stuck; this classifies WHY and takes the matching SAFE action,
escalating only as far as needed. Status returned:

- `:snapped`      — a mostly-formed team's stragglers were snapped in (cheapest).
- `:restaged`     — an all-missing team's gather point sits in a NO-GO ZONE, so we
                    relocated staging clear of it (restage_all_blocked! / translate)
                    — we NEVER teleport a robot into a forbidden region.
- `:force_snapped`— a zone-clear wedge (all-ready-but-unformed, or physically stuck
                    all-missing) was force-established by exact-slot snapping.
- `:no_team`      — nothing is forming: the stall is a frontier gap elsewhere, not a
                    team wedge (caller keeps the honest no-op).
- `:stuck`        — teams exist but none was safely actionable this pass.

Only ever runs on the reform path (a real sustained stall), so nominal runs are
untouched. Each escalation logs what it did, so the recovery is verifiable.
"""
# 전송 형성이 오래 멈췄을 때의 "단계적·안전장치 있는(safety-gated)" 자가치유 사령탑. 왜 멈췄는지
# 분류해 필요한 만큼만 점점 강하게 대응: snap → (no-go zone이면)restage → force-snap → 스케줄 교착 해소.
# 반환 status(:snapped/:restaged/:force_snapped/:unwedged/:no_team/:stuck 등)로 무엇을 했는지 알림.
function recover_stalled_teams!(env; verbose::Bool = true)
    # 1) cheapest: mostly-formed stragglers (the original, unchanged primitive).
    # 1) 가장 값싼 대응: 거의 형성된 팀의 낙오자만 붙이기.
    n = reform_stuck_teams!(env; min_ready = 1)
    if n > 0
        verbose && @info "[RESPEC] recover: snapped $n straggler(s) of mostly-formed team(s)."
        return (status = :snapped, moved = n)
    end
    teams = _forming_teams(env)                              # 지금 형성 중인 팀 목록
    if isempty(teams)                                        # 형성 중인 팀이 아예 없음 = 다른 종류의 교착
        # NOTHING is forming. That is exactly the signature of the stuck-carrier wedge: every team is
        # waiting on one formed TransportUnitGo whose DepositCargo never closes, so no team can even
        # begin to form. Returning :no_team here (as the old code did) skipped the only recovery that
        # addresses it — the carrier rescue below was unreachable on this path.
        carrier = try force_advance_stuck_carrier!(env; verbose = verbose) catch e
            @warn "[RESPEC] force_advance_stuck_carrier! failed" exception = e
            (status = :error, moved = 0)
        end
        carrier.status in (:carrier_closed, :carrier_advanced) &&
            return (status = carrier.status, moved = carrier.moved)
        return (status = :no_team, moved = 0)
    end

    # 2) SAFETY gate: an all-missing team whose gather point is inside a no-go zone
    #    cannot be snapped (that would place robots IN the forbidden region). Move the
    #    staging out of the zone instead — the designed spatial recovery.
    # 2) 안전장치: 아무도 못 모인 팀의 모이는 지점이 no-go zone 안이면 snap 금지(로봇을 금지구역에 두는 꼴).
    #    대신 staging(집결지) 자체를 zone 밖으로 옮김.
    zone_blocked = !isempty(RESTRICTION_ZONES[]) &&
        any(t -> t.ready == 0 && _point_in_any_zone(t.gather; margin = default_robot_radius()), teams)
    if zone_blocked
        res = restage_all_blocked!(env)           # 막힌 팀들의 집결지를 zone 밖으로 재배치
        if res.status in (:none, :infeasible)
            res = translate_whole_build!(env)     # fallback: shift the whole build clear (빌드 전체를 평행이동)
        end
        verbose && @info "[RESPEC] recover: gather point in no-go zone -> restaged/translated ($(res.status))."
        return (status = :restaged, detail = res)
    end

    # 2b) REPEATED force-snapping means snapping is not the answer. Evidence (WEDGE_DEBUG dump, after a
    #     mid-build Replace): the team's robots are ALL in their exact carrying slots ("2 ready / 0
    #     missing") yet the FormTransportUnit stays OPEN, because one member's own earlier RobotGo is
    #     still OPEN — the Replace splice left that robot owing two chains that wait on each other. No
    #     amount of snapping can fix a SCHEDULE dependency, so the old code force-snapped the same team
    #     every reform interval (75x observed) and reported :force_snapped = success, which meant
    #     `resolve_schedule_wedge!` — the one recovery that CAN dissolve it — was never reached (it only
    #     ran on :no_team/:stuck). Escalate to it once snapping has visibly failed to make progress.
    # 2b) 같은 팀을 여러 번 force-snap 했는데도 진전이 없으면, 문제는 배치가 아니라 "스케줄 의존성" 교착.
    #     그럴 땐 스냅을 멈추고 스케줄 교착 해소로 격상(escalate)한다.
    if SNAP_COUNT[] >= SNAP_ESCALATE_AT
        wedge = try resolve_schedule_wedge!(env) catch e
            @warn "[RESPEC] resolve_schedule_wedge! failed" exception = e
            (status = :no_wedge,)
        end
        if wedge.status == :unwedged
            SNAP_COUNT[] = 0
            verbose && @info "[RESPEC] recover: $(SNAP_ESCALATE_AT) fruitless force-snaps -> dissolved the " *
                             "SCHEDULE wedge instead (the team was in place; its slot node was blocked)."
            return (status = :unwedged, moved = 0)
        end
        # No recorded serialization gate is the blocker. The measured cause is a FORMED carrier stuck
        # en route whose DepositCargo therefore never closes (see force_advance_stuck_carrier!).
        carrier = try force_advance_stuck_carrier!(env; verbose = verbose) catch e
            @warn "[RESPEC] force_advance_stuck_carrier! failed" exception = e
            (status = :error, moved = 0)
        end
        if carrier.status == :carrier_closed
            SNAP_COUNT[] = 0                 # a schedule node actually advanced -> genuine progress
            return (status = :carrier_closed, moved = carrier.moved)
        elseif carrier.status == :carrier_advanced
            # teleported but the close did not take (spatial/schedule block): do NOT reset the
            # escalation counter, so we keep climbing and the diag/decongest path is reached.
            return (status = :carrier_advanced, moved = carrier.moved)
        end
        verbose && SNAP_COUNT[] == SNAP_ESCALATE_AT &&
            @info "[RESPEC] carrier rescue not applied (status=$(carrier.status); " *
                  "CARRIER_RESCUE=$(get(ENV, "CARRIER_RESCUE", "0")))."
    end

    # 3) zone-clear wedge (all-ready-but-unformed, or physically stuck all-missing):
    #    last-resort force-establishment by exact-slot snapping. Legal region, so safe.
    # 3) zone 밖의 교착(다 모였는데 형성 안 됨/물리적으로 낀 경우): 최후 수단으로 모든 팀원을 정확한 자리에 강제 snap.
    n2 = reform_stuck_teams!(env; min_ready = 0, snap_all = true)
    if n2 > 0
        verbose && @info "[RESPEC] recover: force-snapped $n2 member(s) into exact carrying slots (zone-clear wedge)."
        SNAP_COUNT[] += 1
        # LIVELOCK signature: the same team is snapped into its exact carrying slots over and over
        # (observed after a mid-build Replace: 75 force-snaps, then the no-progress cap). Snapping
        # cannot be the problem — the robots ARE placed. Something upstream keeps the FormTransportUnit
        # from activating, so the RobotGo never reaches its goal, the robots idle in the slots, RVO and
        # dispersion push them back out, and the cycle repeats. Dump what the FTU is waiting for.
        if get(ENV, "WEDGE_DEBUG", "0") == "1" && SNAP_COUNT[] in (3, 10, 30)
            try _dump_forming_team_blockers(env) catch e; @warn "[WEDGE-DBG] dump failed" exception=e end
        end
        return (status = :force_snapped, moved = n2)
    end
    # :stuck — teams exist but none could be snapped (e.g. reform keeps declining with mostly_formed=0).
    # Last safety net: try the carrier rescue here too, so a stuck formed carrier is caught even when the
    # escalation counter never advanced (no snaps happened to count).
    carrier = try force_advance_stuck_carrier!(env; verbose = verbose) catch; (status = :error, moved = 0) end
    carrier.status == :carrier_closed && (SNAP_COUNT[] = 0)
    carrier.status in (:carrier_closed, :carrier_advanced) &&
        return (status = carrier.status, moved = carrier.moved)
    return (status = :stuck, moved = 0)
end

"How many fruitless force-snaps of the same stalled team before we stop snapping and go after the
SCHEDULE dependency that is actually holding the FormTransportUnit open (see `recover_stalled_teams!`)."
# [한] 같은 팀을 몇 번이나 헛되이 force-snap 하면 "스냅 문제 아님"으로 보고 스케줄 교착 해소로 넘어갈지의 임계값.
const SNAP_ESCALATE_AT = Ref(3)[]
# [한] 지금까지 force-snap 을 반복한 횟수(전역 카운터). Ref(0) = 정수 하나를 담은 가변 상자.
const SNAP_COUNT = Ref(0)
"Reset the force-snap escalation counter (call when a run starts)."
# [한] force-snap 카운터를 0 으로 리셋(빌드/런 시작마다 호출).
reset_snap_count!() = (SNAP_COUNT[] = 0; nothing)

"""
    force_advance_stuck_carrier!(env; verbose=true) -> NamedTuple

Last-resort recovery for the mid-build-Replace completion failure, diagnosed 2026-07-14 with
`WEDGE_DEBUG`. The evidence, at the moment the build freezes:

    DepositCargo v38 (TransportUnit 12)   OPEN
       <- TransportUnitGo v39             ACTIVE      # a FORMED unit, en route, that never arrives
    FTU v84  OPEN  (2 ready / 0 missing)  <- RobotGo(R10) <- DepositCargo v38
    FTU v109 OPEN  (2 ready / 0 missing)  <- AssemblyComplete <- CloseBuildStep <- LiftIntoPlace <- v38

Every waiting team traces back to ONE carrier that never reaches its deposit. And it is a vicious
cycle: `reform_stuck_teams!` snaps the waiting teams into their exact carrying slots, where they sit
motionless — becoming static obstacles in the carrier's path — so the carrier never arrives, so the
deposit never closes, so the teams never activate, so reform snaps them again (75x observed, then the
no-progress cap). Force-snapping only ever touches *forming* teams, so it can never help this unit.

This advances the stuck carrier (with its cargo and captured robots) to its deposit goal, which closes
`DepositCargo` and releases the whole downstream chain.

DEFAULT OFF (`CARRIER_RESCUE=1` to enable). It changes the twin's dynamics, so every oracle label
measured without it (e.g. Replace = 172 closed on a mid-build fault) would have to be regenerated
before the surrogate could be trained against a rescued world. Turn it on only together with a full
dataset regeneration.
"""
# Distance-to-goal of each carrier the last time we looked (to tell "stuck" from merely "slow").
# [한] 각 운반체(carrier)가 직전 점검 때 목표까지 남긴 거리. "진짜 낀 것"과 "그냥 느린 것"을 구분하려고 기록.
const CARRIER_LAST_D = Dict{Any,Float64}()
# [한] 위 진행상황 기록을 비움(런 시작마다 호출).
clear_carrier_progress!() = (empty!(CARRIER_LAST_D); nothing)

"""
    _carrier_goal_diag(env, node) -> String

Explain WHY `is_goal(node::TransportUnitGo)` is false for a stuck carrier, replicating the exact
conditions of `route_planning.jl::is_goal` (position reached, next node's predecessors all
active/closed, next FormTransportUnit's robots all in place). Read-only; used only under WEDGE_DEBUG
to decide gate ①: a spatial block (`within_goal=false`) needs decongestion, a schedule block
(`next_OPEN_preds=[...]`) needs a frontier/reassign lever.
"""
# 낀 carrier 의 is_goal(TransportUnitGo)가 왜 false 인지 사람이 읽을 문자열로 설명(위치 도달?/다음 노드
# 선행자들이 다 준비됐나?/다음 팀 로봇이 다 모였나?). 읽기 전용, WEDGE_DEBUG 진단용.
function _carrier_goal_diag(env, node)
    sched, scene_tree, cache = env.sched, env.scene_tree, env.cache
    parts = String[]
    try
        within = is_within_capture_distance(global_transform(entity(node)), global_transform(goal_config(node)))
        push!(parts, "within_goal=$within")
        if is_terminal_node(sched, node)
            push!(parts, "TERMINAL→is_goal=false"); return join(parts, "  ")
        end
        nxt_v = outneighbors(sched, node)[1]
        nxt   = get_node_from_id(sched, get_vtx_id(sched, nxt_v))
        push!(parts, "next=v$nxt_v:$(nameof(typeof(nxt)))")
        _nm(u) = "v$u:$(nameof(typeof(get_node_from_id(sched, get_vtx_id(sched, u)))))"
        opens = Int[]
        for u in inneighbors(sched, get_node(sched, nxt_v))
            (u in cache.active_set || u in cache.closed_set) && continue
            push!(opens, u)
        end
        if isempty(opens)
            push!(parts, "next_preds=ALL_OK")
        else
            push!(parts, "next_OPEN_preds=[$(join(_nm.(opens), ", "))]")
            # Climb the OPEN ancestor chain to the frontier: is it waiting on ACTIVE nodes (progressing,
            # just needs time / a nudge) or is it a pure OPEN loop among the reformed bots (deadlock that
            # needs reassignment)? This distinguishes a schedule-ordering wait from a genuine cycle wedge.
            seen = Set{Int}(opens); frontier = copy(opens); active_leaves = String[]; cyc = false; depth = 0
            while depth < 14 && !isempty(frontier)
                depth += 1; nxts = Int[]
                for f in frontier, q in inneighbors(sched, get_node(sched, f))
                    if q in cache.active_set
                        push!(active_leaves, _nm(q))
                    elseif q in cache.closed_set
                        # closed predecessor is satisfied — ignore
                    elseif q in seen
                        cyc = true
                    else
                        push!(seen, q); push!(nxts, q)
                    end
                end
                frontier = nxts
            end
            push!(parts, "waits_on_ACTIVE=[$(join(unique(active_leaves), ", "))]" * (cyc ? "  OPEN-CYCLE!" : ""))
        end
        if matches_template(FormTransportUnit, get_node(sched, nxt_v))
            tu = entity(nxt)
            miss = [string(id) for (id, _) in robot_team(tu)
                    if !is_within_capture_distance(tu, get_node(scene_tree, id))]
            push!(parts, isempty(miss) ? "nextFTU_robots=ALL_IN" : "nextFTU_missing=[$(join(miss, ", "))]")
        end
    catch e
        push!(parts, "diag_error=$(e)")
    end
    return join(parts, "  ")
end

# 최후 수단: 목표 근처까지 갔는데 끼어버린 운반체(형성된 유닛)를 그 deposit 목표로 강제 순간이동시켜
# DepositCargo 를 닫고 하류 사슬 전체를 풀어줌. 기본 OFF(CARRIER_RESCUE=1 로만 켬 — twin 동역학을 바꾸므로).
function force_advance_stuck_carrier!(env; verbose::Bool = true, tol::Float64 = 0.05)
    get(ENV, "CARRIER_RESCUE", "0") == "1" || return (status = :disabled, moved = 0)  # 환경변수로 켜야만 동작
    sched = env.sched; st = env.scene_tree; cache = env.cache
    dbg = get(ENV, "WEDGE_DEBUG", "0") == "1"
    teleported = Tuple{Int,Any,Float64}[]   # (vtx, unit, dist) of every carrier we snap to its goal (순간이동시킨 목록)
    for v in collect(cache.active_set)
        node = get_node_from_id(sched, get_vtx_id(sched, v))
        node isa TransportUnitGo || continue  # 운반 이동 노드만
        tu   = entity(node)
        goal = global_transform(goal_config(node))   # 목표 자세
        cur  = global_transform(tu)                  # 현재 자세
        d = norm(Vector{Float64}(cur.translation[1:2]) .- Vector{Float64}(goal.translation[1:2]))  # 목표까지 거리
        d <= 1e-3 && continue                         # 이미 도착했으면 건너뜀
        # Only rescue a carrier that is genuinely STUCK, never one that is merely slow: it must have
        # failed to get closer to its goal since the previous reform cycle. Teleporting a moving unit
        # would change the twin's dynamics for healthy runs too, and these labels train the surrogate.
        prev = get(CARRIER_LAST_D, node_id(tu), Inf)     # 직전 점검 때 남았던 거리
        CARRIER_LAST_D[node_id(tu)] = d
        (isfinite(prev) && prev - d > tol) && continue      # still closing the distance -> leave it alone (아직 가까워지는 중이면 그냥 둠)
        set_desired_global_transform!(tu, goal)          # unit + captured cargo/robots move together (유닛+화물+로봇이 함께 이동)
        if use_rvo()
            try
                has_vertex(rvo_global_id_map(), node_id(tu)) || update_rvo_sim!(env)  # RVO 맵에 없으면 먼저 등록
                if has_vertex(rvo_global_id_map(), node_id(tu))
                    rvo_set_agent_position!(tu, project_to_2d(goal.translation))
                    rvo_set_agent_max_speed!(tu, 0.0)     # PIN: RVO must not push it back out before the close (닫히기 전 밀려나지 않게 속도 0 고정)
                end
            catch e; dbg && @warn "[carrier-rescue] rvo pin failed" exception = e end
            for (mid, _) in (try robot_team(tu) catch; () end)
                rn = try get_node(st, mid) catch; nothing end
                rn === nothing && continue
                try
                    has_vertex(rvo_global_id_map(), mid) &&
                        rvo_set_agent_position!(rn, project_to_2d(global_transform(rn).translation))
                catch end
            end
        end
        push!(teleported, (v, tu, d))
    end

    if isempty(teleported)
        # Nothing to advance. Say WHY — otherwise "carrier rescue" logs many times with no effect and
        # looks like a no-op. Count the active TransportUnitGos and how far each is from goal.
        if dbg
            cs = Tuple{Any,Float64}[]
            for v in collect(cache.active_set)
                n = get_node_from_id(sched, get_vtx_id(sched, v)); n isa TransportUnitGo || continue
                dd = try norm(Vector{Float64}(global_transform(entity(n)).translation[1:2]) .-
                              Vector{Float64}(global_transform(goal_config(n)).translation[1:2])) catch; NaN end
                push!(cs, (node_id(entity(n)), dd))
            end
            @info "[RESPEC][carrier-dbg] active TransportUnitGo count=$(length(cs)); dists=$(cs)"
        end
        return (status = :no_carrier, moved = 0)
    end

    # FORCE-CLOSE now, while the units are still pinned at their goals: run the SAME nominal cache
    # update the main loop runs (update_planning_cache!(env, 0.0)), but HERE — before RVO integrates
    # again — so is_goal sees each unit AT its goal and closes the TransportUnitGo, activating its
    # DepositCargo. This is exactly what the previous version missed: it teleported and RETURNED, and
    # RVO pushed the unit back out before the next is_goal check, so the deposit never closed
    # (64 carrier_advanced, 0 unwedged observed). update_planning_cache! also cascades + resyncs RVO.
    # 순간이동으로 목표에 고정된 지금, 메인 루프와 같은 캐시 업데이트를 여기서(=RVO 재적분 전에) 돌린다.
    # 그래야 is_goal 이 유닛을 "목표에 있음"으로 보고 TransportUnitGo 를 닫아 DepositCargo 를 활성화함.
    newly = try update_planning_cache!(env, 0.0) catch e
        @warn "[RESPEC] force-close update_planning_cache! failed" exception = e
        Set{Int}()
    end
    n_closed = 0
    for (v, tu, d) in teleported
        if (v in newly) || (v in cache.closed_set)        # 이번에 닫혔거나 이미 닫힘 = 성공
            n_closed += 1
            verbose && @info "[RESPEC] recover: force-CLOSED stuck carrier $(node_id(tu)) at its deposit " *
                             "goal (was $(round(d; digits = 2))m away) → DepositCargo chain released."
        else
            # The close did not take. Do not leave a live unit frozen at speed 0; restore its speed and
            # (under WEDGE_DEBUG) report which is_goal condition still fails so we know if this is a
            # spatial block (needs decongest) or a schedule block (needs a frontier/reassign lever).
            if use_rvo()
                try has_vertex(rvo_global_id_map(), node_id(tu)) &&
                        rvo_set_agent_max_speed!(tu, get_rvo_max_speed(tu)) catch end
            end
            dbg && @info "[carrier-rescue] $(node_id(tu)) teleported+pinned but did NOT close → " *
                         _carrier_goal_diag(env, get_node_from_id(sched, get_vtx_id(sched, v)))
        end
    end
    n_closed > 0 && return (status = :carrier_closed, moved = n_closed)
    return (status = :carrier_advanced, moved = length(teleported))
end

"""
    _dump_forming_team_blockers(env)

For every FormTransportUnit that is trying to form, print the node's own status and the status of each
of its schedule PREDECESSORS. A RobotGo only counts as at-goal once every predecessor of the next node
is active-or-closed (`route_planning.jl` `is_goal`), so an FTU with an OPEN predecessor can never form
no matter how precisely its robots are placed. Read-only; gated by WEDGE_DEBUG.
"""
# 형성 시도 중인 각 FormTransportUnit 이 "무엇을 기다리는지" 로그로 출력(그 노드와 선행자들의 상태).
# OPEN 인 선행자가 하나라도 있으면 로봇을 아무리 정확히 놔도 형성 불가. 읽기 전용, WEDGE_DEBUG 로만 동작.
function _dump_forming_team_blockers(env)
    sched = env.sched; cache = env.cache
    stat(v) = v in cache.closed_set ? "CLOSED" : v in cache.active_set ? "ACTIVE" : "OPEN"
    lines = String["[WEDGE-DBG] force-snap #$(SNAP_COUNT[]) — what are the forming teams waiting for?"]
    for v in Graphs.vertices(sched)
        node = get_node_from_id(sched, get_vtx_id(sched, v))
        node isa FormTransportUnit || continue
        v in cache.closed_set && continue
        tu = entity(node)
        ready = 0; missing_ = 0
        for (mid, _) in (try robot_team(tu) catch; () end)
            rn = try get_node(env.scene_tree, mid) catch; nothing end
            rn === nothing && continue
            is_within_capture_distance(tu, rn) ? (ready += 1) : (missing_ += 1)
        end
        (ready == 0 && missing_ == 0) && continue
        members = join([string(m) for (m, _) in (try robot_team(tu) catch; () end)], ", ")
        push!(lines, "  FTU v=$v $(stat(v))  team: $(ready) ready / $(missing_) missing  members=[$members]")
        for p in Graphs.inneighbors(sched, v)
            pn = get_node_from_id(sched, get_vtx_id(sched, p))
            aid = try node_id(entity(pn)) catch; nothing end
            tag = aid === nothing ? "" : " agent=$(aid)" *
                  ((try is_faulted(aid) catch; false end) ? " [FAULTED]" : "") *
                  ((try is_spare(aid) catch; false end) ? " [spare]" : "")
            push!(lines, "     <- pred v=$p  $(nameof(typeof(pn)))  $(stat(p))$tag")
            # An OPEN predecessor is the real blocker. Walk its OPEN ancestors up to the first node that
            # is ACTIVE/CLOSED (or a cycle) — that terminal node is what the whole team is waiting on.
            (stat(p) == "OPEN") || continue
            seen = Set{Int}([p]); frontier = [p]; depth = 0
            while depth < 8 && !isempty(frontier)
                depth += 1; nxt = Int[]
                for f in frontier, q in Graphs.inneighbors(sched, f)
                    q in seen && (push!(lines, "          " * "  "^depth * "<- v=$q  *** CYCLE ***"); continue)
                    push!(seen, q)
                    qn = get_node_from_id(sched, get_vtx_id(sched, q))
                    qid = try node_id(entity(qn)) catch; nothing end
                    push!(lines, "          " * "  "^depth * "<- $(nameof(typeof(qn))) v=$q $(stat(q))" *
                                 (qid === nothing ? "" : " agent=$(qid)") *
                                 ((qid !== nothing && (try is_faulted(qid) catch; false end)) ? " [FAULTED]" : ""))
                    stat(q) == "OPEN" && push!(nxt, q)     # keep climbing only through OPEN nodes
                end
                frontier = nxt
            end
        end
    end
    @info join(lines, "\n")
end

"""
    resolve_schedule_wedge!(env; verbose=true) -> NamedTuple

ENDGAME completion-forcing recovery for the documented single-spare multi-task cyclic
cargo-dependency residual. A Replace hands a spare several time-serialized tasks;
`_serialize_spare_frontiers!` chains them with `dep_i -> slot_{i+1}` edges (recorded in
`WEDGE_EDGES`). If task-i is a multi-robot carry whose co-carriers never sync on the spare's shifted
timeline, `dep_i` (a `DepositCargo`) never closes, so `slot_{i+1}` and everything behind it never
activate — the build stalls near completion with NO active forming team (so `recover_stalled_teams!`
returns `:no_team` and the reform path no-ops). This DISSOLVES that wedge: drop every recorded
serialization gate whose deposit is still open (reverting those slots to their real graph
predecessors), re-derive the frontier, and force-form any team that becomes active. Removing the
gates one reform-cycle at a time (earliest-`t0` first) avoids re-creating the single-spare
double-booking: each freed task completes and closes its own deposit before the next gate is dropped.

Returns `(:unwedged, …)` if a gate was dropped, else `(:no_wedge, …)`. Runs ONLY after `:no_team` on
the reform path (a genuine endgame scheduling wedge), so nominal builds are untouched.
"""
# 끝판(endgame)의 "단일 spare 다중작업 순환 의존" 교착을 완주시키는 복구. _serialize_spare_frontiers! 가
# 걸어둔 직렬화 게이트(dep→slot) 중 deposit 이 아직 안 닫힌 것을 t0 이른 순으로 "하나씩" 풀어(엣지 제거)
# 막힌 slot 을 다시 frontier 로 살리고 형성시킴. 하나 풀었으면 (:unwedged), 없으면 (:no_wedge) 반환.
function resolve_schedule_wedge!(env; verbose::Bool = true)
    sched = env.sched; G = get_graph(sched)
    # candidate gates: recorded edges still present whose gating DEPOSIT has not closed.
    # 후보 게이트: 아직 그래프에 남아 있고, 그 gating DEPOSIT 이 아직 안 닫힌 기록된 엣지들.
    open_gates = Tuple{Int,Int}[]
    for (dep, nxt) in WEDGE_EDGES[]
        dep in env.cache.closed_set && continue          # gate satisfied -> not a wedge (deposit 닫혔으면 교착 아님)
        Graphs.has_edge(G, dep, nxt) || continue         # edge already gone (엣지가 이미 없으면 건너뜀)
        push!(open_gates, (dep, nxt))
    end
    if isempty(open_gates)
        # DIAGNOSTIC: no recorded serialization gate is the blocker. Dump the real structure — every
        # active TransportUnitGo (a formed unit stuck EN-ROUTE / at-goal) and the un-ready predecessors
        # of its successor that keep is_goal false (route_planning.jl:552-556 "downstream not ready").
        if get(ENV, "WEDGE_DEBUG", "0") == "1"
            for v in collect(env.cache.active_set)
                node = get_node_from_id(sched, get_vtx_id(sched, v))
                node isa TransportUnitGo || continue
                outs = Graphs.outneighbors(sched, v)
                nxt = isempty(outs) ? nothing : outs[1]
                if nxt === nothing
                    @info "[WEDGE-DBG] active TransportUnitGo v$v has NO successor (terminal)"
                    continue
                end
                unready = Tuple{Int,String,Bool,Bool}[]
                for p in Graphs.inneighbors(sched, nxt)
                    pn = get_node_from_id(sched, get_vtx_id(sched, p))
                    push!(unready, (p, string(typeof(pn).name.name),
                                    p in env.cache.closed_set, p in env.cache.active_set))
                end
                nxn = get_node_from_id(sched, get_vtx_id(sched, nxt))
                @info "[WEDGE-DBG] TUGo v$v -> next v$nxt ($(typeof(nxn).name.name)); preds(vtx,type,closed,active): $unready"
            end
        end
        return (status = :no_wedge, removed = 0, moved = 0)
    end
    # Drop the EARLIEST-t0 gate only (progressive de-serialization): free one task at a time so the
    # single spare is never re-double-booked. Later reform cycles drop the next once this one closes.
    # t0 가 가장 이른 게이트 "하나만" 제거(점진적 역직렬화): 한 번에 한 작업씩 풀어 spare 이중배정 재발 방지.
    sort!(open_gates, by = e -> Float64(get_t0(sched, e[2])))
    (dep, nxt) = open_gates[1]                           # 가장 이른 게이트 선택
    Graphs.rem_edge!(G, dep, nxt)                        # 직렬화 엣지 제거 → slot 이 원래 선행자에 다시 매임
    filter!(e -> e != (dep, nxt), WEDGE_EDGES[])         # 기록 목록에서도 제거
    push!(DISSOLVED_GATES[], (dep, nxt))                 # block _enforce_serial_frontiers! from re-adding it (재추가 금지)
    reset_cache_resume!(env.cache, sched)                # the freed slot becomes an active frontier (풀린 slot 이 활성화)
    moved = reform_stuck_teams!(env; min_ready = 0, snap_all = true)   # force-form the freed team (풀린 팀 강제 형성)
    moved > 0 && reset_cache_resume!(env.cache, sched)
    verbose && @info "[RESPEC] schedule-wedge recovery: dropped un-closable gate dep$(dep)->slot$(nxt) " *
                     "($(length(open_gates)-1) more pending), force-formed $moved robot(s)."
    return (status = :unwedged, removed = 1, remaining = length(open_gates) - 1, moved = moved)
end

"""
    _dump_nav_stall(env)

Evidence dump for the endgame NAVIGATION stall (reform `:no_team` + wedge `:no_wedge` fall-through).
For every active `RobotGo`/`TransportUnitGo` mover: its agent id, whether it is a (recovery) spare,
distance to its goal, and — when its next node is a `FormTransportUnit` — that team's ready/missing
split. Reveals whether the jam is (a) a far spare crossing a congested core, (b) a specific team whose
members can't converge, or (c) a broad gridlock — which decides the recovery design. Read-only.
"""
# 끝판 "항법(navigation) 정체" 증거 덤프: 활성 이동체(RobotGo/TransportUnitGo)마다 agent id, spare 여부,
# 목표까지 거리, 다음이 팀형성이면 준비/부족 인원을 로그로 출력. 정체 원인 진단용, 읽기 전용.
function _dump_nav_stall(env)
    sched = env.sched; st = env.scene_tree
    rows = String[]
    n_spare_mv = 0; n_far = 0; dists = Float64[]
    for v in collect(env.cache.active_set)
        node = get_node_from_id(sched, get_vtx_id(sched, v))
        (node isa RobotGo || node isa TransportUnitGo) || continue
        aid = try node_id(entity(node)) catch; nothing end
        d = try
            s = global_transform(entity(node)); g = global_transform(goal_config(node))
            norm(Vector{Float64}(s.translation[1:2]) .- Vector{Float64}(g.translation[1:2]))
        catch; NaN end
        isnan(d) || push!(dists, d)
        sp = (aid isa RobotID) && (try is_spare(aid) catch; false end)
        rsp = try is_recovery_spare(aid) catch; false end
        sp && (n_spare_mv += 1); (!isnan(d) && d > 5) && (n_far += 1)
        # team readiness if the next node is a FormTransportUnit
        teaminfo = ""
        outs = Graphs.outneighbors(sched, v)
        if !isempty(outs)
            nxt = get_node_from_id(sched, get_vtx_id(sched, outs[1]))
            if nxt isa FormTransportUnit
                tu = entity(nxt); rdy = 0; mis = 0
                for (mid, _) in (try robot_team(tu) catch; () end)
                    rn = try get_node(st, mid) catch; nothing end
                    rn === nothing && continue
                    is_within_capture_distance(tu, rn) ? (rdy += 1) : (mis += 1)
                end
                teaminfo = " -> FTU $(node_id(tu)) [$(rdy)rdy/$(mis)mis]"
            else
                teaminfo = " -> $(nameof(typeof(nxt)))"
            end
        end
        push!(rows, "    $(nameof(typeof(node))) $(aid)$(rsp ? "[recov-spare]" : sp ? "[spare]" : "") " *
                    "dist=$(round(d, digits=2))$(teaminfo)")
    end
    dsum = isempty(dists) ? "n/a" :
        "min=$(round(minimum(dists),digits=2)) max=$(round(maximum(dists),digits=2)) mean=$(round(sum(dists)/length(dists),digits=2))"
    @warn "[NAV-DBG] navigation stall: $(length(rows)) mover(s), $(n_spare_mv) are spares, " *
          "$(n_far) are >5u from goal. dist[$dsum]\n" * join(rows, "\n")
    return nothing
end

"""
    replace_robot_distributed!(env, faulted; resume=true, verbose=true) -> NamedTuple

(A1) COMPLETION-SAFE replace: distribute the faulted robot F's several pending transport tasks across
MULTIPLE nearest spares — ONE task per spare — instead of piling them all on a single spare.

Why: handing all of F's tasks to one spare over-subscribes it (the spare can only be in one place, so
the other transport units stall and a downstream `OpenBuildStep` never activates → the cyclic
cargo-dependency wedge that leaves the build INCOMPLETE). Giving each task its OWN spare removes the
over-subscription entirely (each spare has ≤1 active transport task, so no serialization is needed and
nothing double-books), and the freed tasks run concurrently just like the original multi-robot build.

PROXIMITY / immediate response: each task is assigned to the spare pool NEAREST that task's pickup
(gather) point via `nearest_pool(pickup)`, so a close, idle spare reacts at once rather than a far
parked robot arriving late.

Status: `:distributed` (n tasks placed on n spares), `:no_frontier` (F has no pending transport task),
`:insufficient_spares` (fewer spares than tasks — caller should fall back to the single-spare splice).
"""
# (A1) 완주-안전 교체: 고장난 F 의 여러 남은 운반작업을 "작업 1개당 spare 1개"로 여러 예비에 분산 배정
# (한 spare 에 몰아주면 과다구독→교착). 각 작업은 그 pickup 지점에 가장 가까운 spare pool 에 배정. 상태 반환.
function replace_robot_distributed!(env, faulted::AbstractID; resume::Bool = true, verbose::Bool = true)
    sched = env.sched; G = get_graph(sched)
    # F's pending TASKS = its non-closed FTU-feeding RobotGo slots (each starts one transport carry).
    # F 의 남은 작업들 = 아직 안 닫혔고 다음이 FormTransportUnit 인 RobotGo slot(각각이 운반 하나의 시작).
    task_slots = Int[]
    for v in _robot_go_nodes(sched, faulted)
        v in env.cache.closed_set && continue
        outs = Graphs.outneighbors(sched, v); isempty(outs) && continue
        get_node_from_id(sched, get_vtx_id(sched, outs[1])) isa FormTransportUnit || continue
        push!(task_slots, v)
    end
    isempty(task_slots) && return (status = :no_frontier, n_tasks = 0)  # 남은 운반작업 없음
    # A single pending task cannot over-subscribe one spare — let the caller use its normal
    # single-spare (or hot-swap) path unchanged; distribution only matters for >1 task.
    length(task_slots) == 1 && return (status = :single_task, n_tasks = 1)  # 작업 1개면 분산 불필요(단일 spare 경로로)
    # ATOMICITY: only proceed if there are at least as many spares as tasks — a PARTIAL distribution
    # would re-create over-subscription on the leftover tasks. Check BEFORE any mutation so the caller
    # can cleanly fall back to the single-spare splice on a half-empty pool.
    # 원자성(atomicity): 작업 수만큼 spare 가 있을 때만 진행. 부분 분산은 남은 작업에 과다구독을 다시 만듦.
    n_spare = try length(active_spares()) catch; 0 end
    if n_spare < length(task_slots)
        verbose && @info "[REPLACE-DIST] $(length(task_slots)) task(s) but only $(n_spare) spare(s) -> caller falls back to single-spare splice."
        return (status = :insufficient_spares, n_tasks = length(task_slots), placed = 0)
    end
    # order by original schedule time (deterministic, and lets the earliest task grab its nearest pool first)
    sort!(task_slots, by = v -> Float64(get_t0(sched, v)))    # 원래 t0 시간순(결정적; 이른 작업이 가까운 pool 먼저 차지)

    # ---- PHASE 1 (RESERVE, no schedule mutation) ------------------------------------------------
    # Pop one nearest spare per task and stage the (slot, spare, sg) plan. If ANY task can't be
    # served, ROLL BACK every popped spare to its pool and return :insufficient_spares — the schedule
    # is untouched, so the caller's single-spare fallback runs on a clean graph.
    plan = NamedTuple[]                                       # (slot, slot_node, spare, sg, key) — 확정 전 계획만 담음
    popped = Tuple{Symbol,AbstractID}[]                       # (pool_key, spare) for rollback (되돌리기용 꺼낸 spare 기록)
    rollback! = () -> for (k, s) in popped; try register_spare!(k, s) catch end end  # 꺼낸 spare 를 pool 로 반납
    ok = true
    for slot in task_slots
        slot_node = get_node_from_id(sched, get_vtx_id(sched, slot))
        pos = try Vector{Float64}(global_transform(goal_config(slot_node)).translation[1:2]) catch; nothing end  # 이 작업 pickup 위치
        key = pos === nothing ? nearest_pool(_ood_robot_pos2d(env, faulted); nonempty = true) :
                                nearest_pool(pos; nonempty = true)  # 그 위치에 가장 가까운 비어있지 않은 pool
        if key === nothing; ok = false; break; end            # no non-empty pool left (남은 pool 없음 → 중단)
        spare = pop_spare!(key)                                # pool 에서 spare 하나 꺼냄
        if spare === nothing; ok = false; break; end
        push!(popped, (key, spare))
        sg = _idle_free_node(sched, spare)                    # 그 spare 의 놀고 있는 자유노드
        if sg === nothing; ok = false; break; end             # spare unusable -> abort (it's in `popped`, rolled back)
        push!(plan, (slot = slot, slot_node = slot_node, spare = spare, sg = sg, key = key))
    end
    if !ok || length(plan) < length(task_slots)               # 모든 작업에 spare 를 못 잡았으면
        rollback!()                                           # 꺼낸 spare 전부 반납(스케줄은 아직 안 건드림)
        verbose && @info "[REPLACE-DIST] could not reserve a spare for every task ($(length(plan))/$(length(task_slots))) -> rolled back, caller falls back to single-spare splice."
        return (status = :insufficient_spares, n_tasks = length(task_slots), placed = 0)
    end

    # ---- PHASE 2 (COMMIT, mutate) ---------------------------------------------------------------
    # ---- 2단계 (확정, 그래프 변경) : 계획대로 실제 splice 수행 ----
    for p in plan
        for vp in collect(Graphs.inneighbors(sched, p.slot))  # detach this task's incoming assignment edge (F→slot 배정엣지 떼기)
            is_assignment_edge(sched, vp, p.slot) && Graphs.rem_edge!(G, vp, p.slot)
        end
        add_edge!(sched, get_node_from_id(sched, get_vtx_id(sched, p.sg)), p.slot_node)  # spare's idle node -> slot (spare 자유노드→slot 새 엣지)
        _restamp_robot_go!(env, p.slot, p.spare)              # bind slot + re-key its FTU team to the spare (slot 을 spare 로 도장 + 팀 명부 교체)
        mark_recovery_spare!(p.spare)                         # high RVO priority so it reaches its slot fast (RVO 우선순위↑ 빠른 도착)
    end
    # NEUTRALIZE F: force-close its remaining (now dead-end) RobotGo — fg + rests — so the sim never
    # drives the faulted (RVO-absent) body. Safe: they are terminal once the tasks are re-routed.
    # F 무력화: 남은(이제 막다른) RobotGo 들을 강제로 닫아 시뮬레이터가 고장난(RVO 없는) 몸체를 몰지 않게 함.
    n_parked = 0
    for v in _robot_go_nodes(sched, faulted)
        v in env.cache.closed_set && continue
        push!(env.cache.closed_set, v); n_parked += 1
    end
    verbose && @info "[REPLACE-DIST] robot $(faulted): distributed $(length(plan)) task(s) across $(length(plan)) nearest spare(s) (1 task each); parked-faulted $(n_parked). No over-subscription."
    resume && reset_cache_resume!(env.cache, sched)          # 캐시 재빌드로 새 배치를 반영
    return (status = :distributed, n_tasks = length(plan), spares = [p.spare for p in plan])
end

"""
    replace_robot!(env, faulted, spare; resume=true, verbose=true) -> NamedTuple

Hand F's remaining work thread to idle spare S by a graph splice (no MILP). Status:
- `:replaced`     — spliced; `slots` re-stamped count included. Cache rebuilt if `resume`.
- `:no_spare`     — `spare` has no idle free node (not an unused spare).
- `:no_frontier`  — F has no pending assignment to hand off (already done / not faulted mid-work).
- `:already_done` — F has no non-closed RobotGo at all.

SAFETY/SCOPE (MVP): only the future is moved — closed (realized) nodes are never
touched, so F keeps credit for work it finished. F's dead frontier `fg` is left
bound to F (the caller registers F's body as a static obstacle); pruning F from
active RVO driving is the caller's `fault_robot!` step (R3).
"""
# F 의 잔여 작업 thread 를 놀고 있는 예비 S 에 그래프 splice 로 인계(MILP 없음). 상태 NamedTuple 반환.
function replace_robot!(env, faulted::AbstractID, spare::AbstractID;
                        resume::Bool = true, verbose::Bool = true,
                        park_rests::Bool = true)
    sched = env.sched
    f_gos = _robot_go_nodes(sched, faulted)                   # F 에 묶인 모든 RobotGo
    all(v -> v in env.cache.closed_set, f_gos) &&             # 전부 닫혔으면 = 넘길 미래 작업 없음
        return (status = :already_done, detail = "robot $(faulted) has no future RobotGo")

    sg = _idle_free_node(sched, spare)                        # 예비 S 의 놀고 있는 자유노드(인계 시작점)
    sg === nothing &&
        return (status = :no_spare, detail = "spare $(spare) has no idle free node")

    pend = _first_pending_assignment(env, faulted)            # F 의 frontier (fg, slot1) = 넘길 첫 배정
    pend === nothing &&
        return (status = :no_frontier, detail = "robot $(faulted) has no pending assignment edge")
    (fg, slot1) = pend                                        # fg=F의 자유노드, slot1=넘길 첫 작업 slot

    # --- splice: detach F's frontier from slot1, attach S's idle node instead ----
    G = get_graph(sched)
    Graphs.rem_edge!(G, fg, slot1)                            # F 의 frontier -> slot1 배정엣지 제거
    sg_node    = get_node_from_id(sched, get_vtx_id(sched, sg))
    slot1_node = get_node_from_id(sched, get_vtx_id(sched, slot1))
    add_edge!(sched, sg_node, slot1_node)                    # S 의 idle 자유노드 -> slot1 새 배정엣지

    # --- re-stamp every non-closed F-bound RobotGo (EXCEPT the dead frontier fg)
    #     to the spare, and re-key its transport teams. sg is already S. ---------
    n_restamped = 0
    for v in _robot_go_nodes(sched, faulted)
        (v == fg || v in env.cache.closed_set) && continue   # fg 는 F 의 dead-end 로 남김; 과거는 불변
        _restamp_robot_go!(env, v, spare) && (n_restamped += 1)  # F→S 로 도장 갈아끼움(성공하면 카운트)
    end

    # --- dedupe: remove any spurious duplicate spare-feeder on a transport unit
    #     (a robot can't fill two slots of one unit -> formation deadlock). ---------
    n_deduped = _dedupe_spare_ftu_feeders!(env, spare, sg)   # 중복 feeder 정리(한 팀에 spare 가 두 자리 차지 방지)

    # --- serialize: the faulted robot's pending tasks were only TIME-ordered by the
    #     MILP, so several can present as concurrent frontiers. Chain them so the
    #     single spare does them one at a time (else it double-books across teams). ---
    n_serialized = _serialize_spare_frontiers!(env, spare, sg, slot1)  # spare 가 여러 작업을 한 번에 하나씩 하도록 줄 세움

    # --- park surplus terminal dead-end rests on the spare: re-stamping hands the spare a
    #     terminal "rest here" RobotGo from EACH of the faulted robot's finished carries.
    #     An intermediate one competes with a real pending task (the controller can drive the
    #     spare to a near dead-end rest instead of the FormTransportUnit slot where a co-carrier
    #     waits). Keep only the final rest; close the earlier ones. ----------------------------
    n_rests = park_rests ? _park_spare_dead_rests!(env, spare) : 0  # 중간의 "쉬는 종점" 정리(진짜 최종 휴식만 남김)

    # --- R3: NEUTRALIZE the faulted robot. After re-stamping, its only remaining nodes
    #     are dead-ends (the frontier fg + any orphan). Left active, the sim would try to
    #     drive a robot whose RVO agent is gone -> rvo_get_agent_idx BoundsError. Force-
    #     close them so the faulted robot is removed from driving (its body stays as the
    #     static obstacle fault_robot! registered). They are dead-ends, so closing is safe.
    n_parked = 0
    for v in _robot_go_nodes(sched, faulted)                 # F 의 남은 막다른 노드들(fg 등)을
        v in env.cache.closed_set && continue
        push!(env.cache.closed_set, v); n_parked += 1        # 강제로 닫아 시뮬이 사라진 RVO 몸체를 몰지 않게 함
    end

    mark_recovery_spare!(spare)   # V5: give the recovery spare high RVO priority (교체 spare 에 높은 RVO 우선순위 부여)
    verbose && @info "[REPLACE] robot $(faulted) -> spare $(spare): spliced frontier to slot, " *
                     "re-stamped $(n_restamped), deduped $(n_deduped), serialized $(n_serialized), " *
                     "parked-rests $(n_rests), parked-faulted $(n_parked)."
    resume && reset_cache_resume!(env.cache, sched)          # 스케줄 변경을 캐시에 반영(F 없이 재개)
    return (status = :replaced, faulted = faulted, spare = spare, slots = n_restamped,
            deduped = n_deduped, serialized = n_serialized, rests = n_rests, fg = fg, slot1 = slot1)
end

# =============================================================================
# hot_swap_robot!  --  IDENTITY-PRESERVING scene-tree hot-swap (the robust path).
#
# The re-stamp `replace_robot!` above smears the faulted robot F's identity onto a
# spare S across the SCHEDULE (every RobotGo re-stamped F->S, every transport team
# re-keyed). Because the SCENE TREE keys robots by RobotID and binds them into
# transport units BY id, that identity smear is what every residual failure mode
# (transform-binding stall, double-booking, dead-rests, multi-team deadlock) traces
# back to.
#
# hot_swap_robot! INVERTS the swap: keep F's RobotID everywhere and swap the
# physical ASSET underneath it from the repository. The schedule and every team
# still reference F, so ZERO re-stamping happens — the entire re-stamp bug class is
# structurally impossible. The "spare" is treated as what it physically is: a body +
# fresh battery in a depot. Steps:
#   1. detect if F is captured (mid-carry) — if so, HEAL IN PLACE (never disband a
#      formed transport unit); otherwise use the requested `mode`.
#   2. check out a spare body from the nearest depot (pop_spare!) and RETIRE that
#      body off-grid so depot inventory visibly drops by one.
#   3. (:via_depot) re-home F's OWN scene node + RVO agent to the depot dispatch
#      point so the stable-id robot "emerges" from the repository and drives back to
#      its goal (goals are absolute world configs); leave a greyed decommission
#      marker where F broke down. (:in_place) heal F where it stands.
#   4. restore F's health: full battery, clear stall/deplete/fault + its obstacle.
# No schedule mutation, so NO reset_cache_resume! — F's intact chain resumes as-is.
# =============================================================================
#
# [한국어 요약] hot_swap_robot! = 정체성 보존(identity-preserving) 씬트리 hot-swap = 더 견고한 길.
#   위 replace_robot! 은 스케줄 곳곳에 박힌 F 의 id 를 S 로 "재도장"해서 퍼뜨림 → 잔여 버그의 근원.
#   hot_swap 은 반대로 함: F 의 RobotID 를 어디서나 "그대로" 두고, 그 아래 물리적 몸체(asset)만
#   창고(depot)에서 갈아끼운다. 스케줄과 팀이 여전히 F 를 가리키므로 re-stamp 가 0번 → 재도장 버그
#   전체가 구조적으로 불가능. "spare" 는 사실 그대로 "창고 속 몸체+새 배터리"로 취급.
#   순서: 1) F 가 운반 중(captured)이면 제자리 치유(:in_place, 형성된 팀은 절대 해체 안 함)
#         2) 가장 가까운 depot 에서 spare 몸체를 꺼내고, 그 몸체는 화면 밖으로 은퇴(재고 1 감소)
#         3) (:via_depot) F 자신의 씬 노드+RVO 를 depot 지점으로 재배치해 "안정 id 로봇"이 창고에서
#            나타나 목표로 복귀(목표는 절대 world 좌표라 모션 스택이 알아서 경로 안내), 고장 지점엔 회색 표식
#         4) F 건강 회복: 배터리 완충, stall/deplete/fault 상태·장애물 해제
#   스케줄을 안 건드리므로 reset_cache_resume! 없이 F 의 온전한 사슬이 그대로 재개됨.
# =============================================================================

# The TransportUnitNode that currently has `rid` captured (rid is its scene-tree
# child), or nothing if rid is a free root robot. has_edge on the scene tree keys on
# the RobotID (the scene-tree node key), so this is an exact capture test.
# [한] 지금 로봇 rid 를 "잡고 있는"(씬트리 자식으로 둔) 운반유닛 노드를 반환. 자유 루트 로봇이면 nothing.
#      씬트리의 has_edge 는 RobotID 를 키로 쓰므로 정확한 capture(운반 중) 판정이 됨.
function _transport_unit_parent(scene_tree, rid::AbstractID)
    has_vertex(scene_tree, rid) || return nothing            # 씬트리에 없는 로봇이면 부모 없음
    for n in get_nodes(scene_tree)
        n isa TransportUnitNode || continue                  # 운반유닛 노드만 후보
        # 씬트리에서 그 유닛 → rid 로 가는 간선이 있으면 = rid 를 자식으로 잡고 있음
        (try has_edge(scene_tree, node_id(n), rid) catch; false end) && return n
    end
    return nothing
end

# 2D world position of a robot's scene body (origin on failure).
# [한] 로봇 씬 몸체의 2D world 위치를 반환(실패하면 원점 [0,0]). 고장 지점 기록 등에 사용.
function _robot_scene_pos2d(env, rid::AbstractID)
    try
        t = global_transform(get_node(env.scene_tree, rid)).translation
        return Float64[t[1], t[2]]
    catch
        return Float64[0.0, 0.0]
    end
end

# Retire a checked-out spare's visible body off-grid (inventory visibly drops by one).
# Distinct graveyard per spare so retired bodies do not z-fight into a single blob.
# [한] 창고에서 꺼낸 spare 의 "몸체"를 화면 밖 먼 곳으로 은퇴시킴(재고가 눈에 띄게 1 줄어듦).
#      id 마다 다른 좌표로 보내 은퇴한 몸체들이 한 덩어리로 겹치지 않게 함.
function _retire_spare_body!(env, spare::AbstractID)
    node = try get_node(env.scene_tree, spare) catch; nothing end
    node === nothing && return false
    # Far off any reasonable build/depot extent AND off-camera, so the retired body is not
    # mistaken for the emerging replacement. Distinct per id so retired bodies don't overlap.
    gx = 1000.0 + 3.0 * (abs(get_id(spare)) % 50)           # id 별로 살짝 다른 x (겹침 방지), 빌드 영역에서 멀리
    gv = (gx, 1000.0)                                        # 목적지: 화면 밖 (gx, 1000)
    if use_rvo() && has_vertex(rvo_global_id_map(), spare)   # move RVO first (else next sync snaps it back) (RVO 먼저 옮겨야 안 되돌아옴)
        try rvo_set_agent_position!(node, gv) catch end
    end
    try set_desired_global_transform!(node,                 # 씬 몸체도 그 좌표로 이동
        CoordinateTransformations.Translation(gv[1], gv[2], 0.0) ∘ identity_linear_map()) catch end
    return true
end

# Re-home a robot (STABLE id) to a 2D world point: scene body AND RVO agent.
# [한] 안정 id 로봇을 2D world 점으로 재배치(씬 몸체 + RVO 에이전트 둘 다). depot 에서 "나타나게" 할 때 사용.
function _rehome_robot!(env, rid::AbstractID, pt2d)
    node = try get_node(env.scene_tree, rid) catch; nothing end
    node === nothing && return false
    if use_rvo() && has_vertex(rvo_global_id_map(), rid)
        try rvo_set_agent_position!(node, (Float64(pt2d[1]), Float64(pt2d[2]))) catch end
    end
    try set_desired_global_transform!(node,
        CoordinateTransformations.Translation(Float64(pt2d[1]), Float64(pt2d[2]), 0.0) ∘ identity_linear_map()) catch end
    return true
end

# Restore a swapped robot to health: full battery, clear stall/deplete/fault state +
# drop its fault obstacle zone. The battery layer (BATTERY_FLEET / STALLED_ROBOTS)
# lives in navigator/battery.jl, which demos CB.include at runtime — so it may be
# ABSENT (pure-fault runs with no battery). `isdefined` guards keep hot-swap usable
# with or without the battery layer loaded.
# [한] 교체된 로봇을 건강 상태로 복구: 배터리 완충, stall/deplete/fault 상태와 fault 장애물 zone 을 해제.
#      배터리 레이어는 런타임에만 include 될 수 있어 없을 수도 있으므로 isdefined 로 안전하게 가드.
function _reset_robot_health!(env, rid::AbstractID)
    if isdefined(@__MODULE__, :BATTERY_FLEET)               # 배터리 레이어가 로드돼 있을 때만
        fleet = BATTERY_FLEET[]
        if fleet !== nothing && haskey(fleet.soc, rid)
            fleet.soc[rid] = 1.0                            # SoC(충전상태)를 100%로
            delete!(fleet.depleted, rid)                    # 방전 표시 제거
        end
    end
    isdefined(@__MODULE__, :STALLED_ROBOTS) && delete!(STALLED_ROBOTS[], rid)  # reopen motion gate (정지 해제=다시 움직임)
    delete!(FAULTED_ROBOTS[], rid)          # no longer faulted (drops the red marker) (고장 해제=빨간 표식 제거)
    try remove_restriction_zone!(Symbol("fault_$(get_id(rid))")) catch end     # 고장 지점 장애물 zone 제거
    return nothing
end

"""
    hot_swap_robot!(env, faulted; mode=:via_depot, verbose=true) -> NamedTuple

Identity-preserving scene-tree replacement of a faulted/degraded robot from the spare
repository. Keeps `faulted`'s RobotID (so the schedule and every transport team are
untouched — no re-stamp) and swaps its physical asset from the nearest depot. Status:
- `:swapped`  — done: a depot spare body was retired, `faulted` re-homed (`:via_depot`)
                or healed in place, battery/fault state reset. `depot`/`spare`/`mode` echoed.
- `:no_robot` — `faulted` has no scene node.
- `:no_spare` — no depot with an available spare near the fault.

A robot faulted MID-CARRY (captured by a transport unit) is always healed IN PLACE,
never disbanded, regardless of `mode`. No schedule mutation and no `reset_cache_resume!`:
`faulted`'s intact task chain resumes as-is next step.
"""
# 고장/열화 로봇을 창고에서 "정체성 보존"으로 교체하는 최상위 진입점. F 의 RobotID 는 유지(스케줄·팀 그대로,
# re-stamp 없음)하고 몸체만 가장 가까운 depot 에서 교체. 운반 중이면 항상 제자리 치유. 상태 NamedTuple 반환.
function hot_swap_robot!(env, faulted::AbstractID;
                         mode::Symbol = :via_depot, verbose::Bool = true)
    st = env.scene_tree
    failed_soc = try
        fleet = BATTERY_FLEET[]
        fleet === nothing ? nothing : get(fleet.soc, faulted, nothing)
    catch
        nothing
    end
    has_vertex(st, faulted) ||
        return (status = :no_robot, detail = "no scene node for $(faulted)")  # 씬 노드 없는 로봇이면 불가
    # break position: prefer the recorded fault spot; fall back to the live body.
    pos = get(FAULTED_ROBOTS[], faulted, _robot_scene_pos2d(env, faulted))  # 고장 위치(기록 우선, 없으면 현재 몸체)
    captured = _transport_unit_parent(st, faulted) !== nothing  # 지금 운반유닛에 잡혀 있나(운반 중)?
    use_mode = captured ? :in_place : mode          # never disband a mid-carry unit (운반 중이면 절대 팀 해체 안 함=제자리 치유)

    key = nearest_pool(pos)                          # 고장 위치에서 가장 가까운 depot(pool) 선택
    key === nothing &&
        return (status = :no_spare, detail = "no depot with an available spare near $(pos)")
    spare = pop_spare!(key)                          # 그 depot 에서 spare 몸체 하나 꺼냄
    spare === nothing &&
        return (status = :no_spare, detail = "depot :$(key) empty")

    dispatch_pt = _robot_scene_pos2d(env, spare)    # where the spare was parked = F's emergence point (spare가 있던 자리 = F가 나타날 지점)
    _retire_spare_body!(env, spare)                 # inventory visibly drops by one body (그 몸체는 화면 밖 은퇴)
    push!(CHECKED_OUT_SPARES[], spare)              # 체크아웃된 spare 기록
    threshold = isdefined(@__MODULE__, :REPLACE_SOC_THRESHOLD) ? REPLACE_SOC_THRESHOLD[] : 0.2
    cause = failed_soc isa Real && failed_soc <= threshold ? :battery : :fault
    HOT_SWAP_ASSETS[][faulted] = (spare=spare, failed_soc=failed_soc,
                                  position=Vector{Float64}(pos), cause=cause)

    if use_mode == :via_depot
        _rehome_robot!(env, faulted, dispatch_pt)   # the stable-id robot emerges from the repository (안정 id 로봇이 창고서 등장)
        DECOMMISSIONED_BODIES[][faulted] = Vector{Float64}(pos)   # red pin where it broke down (고장 지점에 빨간 표식)
        # It must drive the whole way back from the (far) depot through a congested late build;
        # give it recovery RVO priority (V5) so other robots yield and it reaches its task, else
        # its unfinished task wedges the downstream build.
        mark_recovery_spare!(faulted)               # 먼 depot 서 혼잡한 빌드까지 복귀하도록 RVO 우선순위↑
    end
    _reset_robot_health!(env, faulted)              # 배터리·고장 상태 리셋(건강 회복)

    verbose && @info "[HOTSWAP] robot $(faulted) hot-swapped via :$(key) depot " *
                     "(spare body $(spare) retired; mode=$(use_mode); captured=$(captured))."
    return (status = :swapped, faulted = faulted, depot = key, spare = spare,
            mode = use_mode, captured = captured)
end
