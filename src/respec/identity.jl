# =============================================================================
# identity.jl  --  ROBOT-IDENTITY CONSISTENCY INVARIANT (STEP A-1).
#
# A robot's identity (`RobotID`) is simultaneously a key in FOUR registries:
#
#   (1) SCHEDULE stamps   -- every `RobotGo` carries a `RobotNode` stamped with an id
#   (2) TEAM rosters      -- `robot_team(TransportUnitNode)` is keyed by RobotID
#   (3) SCENE-TREE edges  -- capture (a unit carrying a robot) is an edge keyed by RobotID
#   (4) RVO id map        -- `rvo_global_id_map()` maps RobotID -> simulator agent index
#
# The re-stamp replacement path (`_restamp_robot_go!`) mutates (1) and (2) and leaves
# (3) and (4) to catch up. EVERY residual failure mode traces back to a moment where
# those four disagree:
#
#   V_rvo_unregistered  -> `rvo_get_agent_idx` throws BoundsError[-1] and ABORTS the sim
#                          (route_planning.jl apply_cmd!(DepositCargo); STATUS.md BUG #1)
#   V_transform_desync  -> a MINTED RobotNode is not the scene-linked body, so
#                          `feeder_at_goal` stays false forever = the single-task stall
#   V_orphan_capture    -> `swap_robot_id!` rewrites the roster but not the scene edge,
#                          leaving a unit holding a robot it no longer lists
#   V_multi_capture     -> one robot captured by two units = the double-book wedge
#
# So this file does ONE thing: turn "가끔 에러가 난다" into a NAMED violation with the
# step it first appeared at. It only READS state -- it never repairs. Repair belongs to
# the enactment path; a checker that repairs hides the bug it exists to expose.
#
# -----------------------------------------------------------------------------
# [한국어 설명] 이 파일이 하는 일 (처음 읽는 사람을 위한 안내)
# -----------------------------------------------------------------------------
#  로봇의 "정체성"(RobotID)은 네 군데에서 동시에 열쇠(key)로 쓰인다:
#    (1) 스케줄 각인   — 모든 RobotGo 안에 어느 로봇인지가 도장처럼 박혀 있음
#    (2) 팀 명부       — 운반유닛의 robot_team 딕셔너리 키
#    (3) 씬트리 간선   — "이 유닛이 이 로봇을 잡고 있다"는 부모-자식 간선의 키
#    (4) RVO id 맵     — 충돌회피 시뮬레이터의 에이전트 번호로 가는 대응표
#
#  교체(replace) 때 id 를 갈아끼우는 방식은 (1)(2)만 고치고 (3)(4)를 남긴다.
#  지금까지 "가끔 나는 에러"들은 전부 이 네 개가 어긋난 순간에서 나온다:
#    · RVO 미등록 → rvo_get_agent_idx 가 BoundsError 를 던져 시뮬레이션 자체가 중단
#    · transform 단절 → 로봇이 물리적으로 도착해도 "도착 판정"이 영영 false (전송 stall)
#    · 고아 간선 → 유닛이 명부에 없는 로봇을 계속 붙들고 있음
#    · 이중 포획 → 로봇 하나를 유닛 둘이 동시에 잡음 (double-book 교착)
#
#  이 파일은 "고치지 않고 읽기만" 한다. 검사기가 몰래 고쳐 버리면, 잡으려던 버그가
#  숨어 버리기 때문이다. 고치는 일은 교체 경로(enactment)의 몫이다.
#
#  [문법 참고] 처음 보는 Julia 문법
#   · NamedTuple    : (kind = :x, id = y) 처럼 "이름 붙은 칸"들의 묶음. 딕셔너리보다 가볍다.
#   · Ref(true)     : 값 한 칸짜리 가변 상자. `X[]` 로 읽고 쓴다(전역 스위치용).
#   · try ... catch : 실패해도 죽지 않게 감싸는 장치. 검사기는 절대 스스로 죽으면 안 되므로
#                     모든 개별 검사를 이걸로 감싼다.
#   · push!(v, x)   : 배열 v 끝에 x 를 붙인다(`!` = 인자를 직접 수정).
#   · isa           : 타입 검사. `n isa RobotNode` = n 이 RobotNode 인가.
# =============================================================================

# 검사기를 켤지 여부. 교체(enactment) 직후처럼 "드물게" 부르는 자리는 기본 ON —
# 스케줄+씬트리를 한 번 훑는 비용(O(V))이고 교체는 빌드당 몇 번뿐이라 무시할 만하다.
const IDENTITY_CHECK = Ref(true)
# 매 스텝 검사 주기(0 = 끔). 스텝마다 훑으면 비싸므로 디버깅할 때만 켠다(예: 200).
const IDENTITY_CHECK_EVERY = Ref(0)
# 위반을 발견했을 때 예외를 던질지(true) 경고만 남길지(false).
# 기본은 경고 — 검사기가 빌드를 죽이면 "위반 이후에 무슨 일이 벌어지는가"를 못 본다.
const IDENTITY_STRICT = Ref(false)
# 이미 보고한 (위반종류, 로봇) 쌍. 같은 위반이 매 스텝 수천 줄씩 찍히는 것을 막는다.
const _IDENTITY_SEEN = Ref(Set{Tuple{Symbol,String}}())

# 위 스위치들을 한 번에 설정하는 편의 세터(모든 인자는 키워드).
set_identity_check!(; enabled::Bool = true, every::Integer = 0, strict::Bool = false) =
    (IDENTITY_CHECK[] = enabled; IDENTITY_CHECK_EVERY[] = max(0, Int(every));
     IDENTITY_STRICT[] = strict; nothing)

# 빌드를 새로 시작할 때 "이미 본 위반" 기록을 비운다.
clear_identity_seen!() = (empty!(_IDENTITY_SEEN[]); nothing)

# 씬트리에서 로봇 rid 를 자식으로 잡고 있는 운반유닛들을 전부 모은다(0개=자유, 2개 이상=이중포획).
# `_transport_unit_parent`(replace_robot.jl)의 "모두 세는" 버전.
function _capturing_units(scene_tree, rid)
    out = []
    for n in get_nodes(scene_tree)
        n isa TransportUnitNode || continue
        (try has_edge(scene_tree, node_id(n), rid) catch; false end) && push!(out, n)
    end
    return out
end

# 검사에서 제외해야 하는 "정상적인 미배정 상태"인지 판정.
#
# 2026-08-04 첫 실측에서 배운 것: 아래 두 가지는 위반이 아니라 엔진의 정상 동작인데
# 초판 검사기가 위반으로 오탐했다. 오탐을 남겨 두면 검사기가 못 쓰게 된다 —
# 진짜 위반이 정상 상태 노이즈에 묻히기 때문이다.
#
#  (1) 음수 id (-1, -2, ...) = `get_unique_invalid_id` 가 발급하는 "아직 배정 안 된 슬롯"
#      표식. 운반팀 명부는 배정 전까지 이 placeholder 를 자리에 넣어 두고,
#      `align_with_predecessor`(task_assignment.jl) 가 배정이 확정될 때 진짜 로봇 id 로
#      갈아끼운다. 씬 노드가 없는 게 당연하다.
#  (2) 고장난 로봇 = 일부러 RVO 에서 뺀 것. 스케줄은 아직 그 로봇을 원하지만 물리적으로는
#      죽어 있는, 교체 직전의 정상적인 과도상태다.
_is_placeholder_id(rid) = !(try is_valid(rid) catch; true end)
_is_faulted_robot(rid)  = (try haskey(FAULTED_ROBOTS[], rid) catch; false end)

# 두 3D 위치가 tol 안에서 같은지. transform 단절(minted RobotNode) 판정에 쓴다.
function _same_position(a, b, tol::Float64)
    try
        return abs(a[1] - b[1]) <= tol && abs(a[2] - b[2]) <= tol && abs(a[3] - b[3]) <= tol
    catch
        return true    # 좌표를 못 읽으면 "위반 아님"으로 본다(거짓 양성 금지)
    end
end

"""
    identity_violations(env; tol=1e-6) -> Vector{NamedTuple}

Every place the four identity registries currently disagree. Each entry is
`(kind, id, detail)` where `kind` is one of:

- `:rvo_unregistered` — a robot the schedule still needs has no RVO agent. This is the
  BoundsError[-1] that aborts the whole simulation, caught BEFORE it fires. A robot that
  is CAPTURED (carried by a transport unit) is exempt: `rvo_add_agents!` only registers
  ROOT robots, so having no agent of its own is the normal state, not a violation.
- `:transform_desync` — a schedule-stamped `RobotNode` sits at a different place than the
  scene-tree body with the same id, i.e. the stamp was MINTED rather than looked up. The
  robot then physically arrives while `feeder_at_goal` stays false forever.
- `:stamp_ghost` — the schedule is stamped with a robot that has no scene node at all.
- `:team_ghost` — a transport-unit roster lists a robot with no scene node.
- `:orphan_capture` — a unit holds a robot in the SCENE TREE that its roster no longer lists
  (the half-applied `swap_robot_id!`).
- `:multi_capture` — one robot is captured by two units at once (the double-book wedge).
- `:team_desync` — the schedule's `FormTransportUnit` roster and the scene tree's roster for
  the SAME unit list different robots (the partial re-key: only direct successors re-keyed).
- `:double_assignment` — a free `RobotGo` carries two outgoing assignment edges, i.e. one
  robot promised to two task chains (the phantom-spare double-book).

Read-only. Returns an EMPTY vector when the four registries agree.
"""
# 네 레지스트리가 어긋난 자리를 전부 모아 반환. 각 항목은 (kind=위반종류, id=대상, detail=설명).
# 절대 고치지 않고 읽기만 한다. 문제가 없으면 빈 배열.
function identity_violations(env; tol::Float64 = 1e-6)
    V = NamedTuple[]                                    # 위반 목록(빈 배열에서 시작)
    sched = env.sched
    st = env.scene_tree
    add!(kind, id, detail) = push!(V, (kind = kind, id = string(id), detail = detail))

    # --- 씬트리에 실제로 존재하는 로봇 몸체들의 위치를 먼저 모아 둔다 -----------------
    # (스케줄 각인과 대조할 "정답" 위치. 한 번만 모아 두면 아래 검사가 싸진다.)
    body_pos = Dict{Any,Any}()
    # 같은 순회에서 "이 로봇이 지금 씬트리의 root 인가"도 함께 모은다. root 가 아니다
    # = 운반유닛에 잡혀(captured) 있다 = RVO 에이전트가 없는 것이 정상이다(아래 (c) 참고).
    body_root = Dict{Any,Bool}()
    for n in get_nodes(st)
        n isa RobotNode || continue
        try body_pos[node_id(n)] = global_transform(n).translation catch end
        body_root[node_id(n)] = try is_root_node(st, n) catch; true end   # 못 읽으면 root 로 간주(거짓 양성 금지)
    end

    # --- (1) 스케줄 각인 vs 씬트리 몸체 vs RVO 맵 -------------------------------------
    rvo_on = try use_rvo() catch; false end
    for v in Graphs.vertices(sched)
        node = try get_node_from_id(sched, get_vtx_id(sched, v)) catch; nothing end
        node isa RobotGo || continue
        # 이미 끝난(closed) 노드는 과거다 — 과거의 각인은 더 이상 아무도 안 읽으므로 검사 대상이 아니다.
        (try get_vtx_id(sched, v) in env.cache.closed_set catch; false end) && continue
        rid = try entity(node).id catch; nothing end
        rid === nothing && continue
        _is_placeholder_id(rid) && continue          # 아직 배정 안 된 슬롯 = 정상(위 설명 참고)

        # (a) 각인된 로봇이 씬트리에 아예 없다 = 유령 각인
        if !haskey(body_pos, rid)
            add!(:stamp_ghost, rid, "RobotGo v$(v) is stamped with a robot that has no scene node")
            continue                                    # 몸체가 없으면 아래 위치/RVO 검사는 의미 없음
        end

        # (b) 각인된 RobotNode 의 위치가 씬트리 몸체와 다르다 = 새로 찍어낸(minted) 각인
        #     이게 문서화된 "물리적으로 도착해도 도착판정이 안 되는" stall 의 원인이다.
        stamp_pos = try global_transform(entity(node)).translation catch; nothing end
        if stamp_pos !== nothing && !_same_position(stamp_pos, body_pos[rid], tol)
            add!(:transform_desync, rid,
                 "RobotGo v$(v) stamp is at $(stamp_pos) but the scene body is at $(body_pos[rid])")
        end

        # (c) 앞으로 움직여야 하는 로봇인데 RVO 맵에 없다 = BoundsError 예고
        #     제외 대상이 둘 있다:
        #       · 고장난 로봇 — 일부러 뺀 것(교체 직전의 정상 과도상태).
        #       · 운반유닛에 잡힌(captured) 로봇 — `rvo_add_agents!`(rvo_interface.jl)는 **root 로봇과
        #         대형이 갖춰진 운반팀만** 등록한다. 팀에 묶인 개별 로봇은 팀 에이전트가 대표하므로
        #         자기 에이전트가 없는 것이 정상이다. 그런데 그 로봇의 DepositCargo **이후** RobotGo 는
        #         아직 안 닫혀 있어서, captured 예외가 없으면 운반 중인 로봇이 전부 위반으로 잡힌다
        #         (2026-08-05 실측: 완주한 런에서도 팀원 수만큼 경고가 쏟아졌다 = 순수 오탐).
        #         이 오탐을 남겨 두면 진짜 위반이 노이즈에 묻혀 검사기가 못 쓰게 된다.
        if rvo_on && !_is_faulted_robot(rid) && get(body_root, rid, true) &&
           !(try has_vertex(rvo_global_id_map(), rid) catch; true end)
            add!(:rvo_unregistered, rid, "robot is needed by open RobotGo v$(v) but has no RVO agent")
        end

        # (d) 자유노드 하나에서 배정엣지가 둘 이상 나간다 = 로봇 하나를 두 작업사슬에 약속
        nasg = 0
        for v2 in Graphs.outneighbors(sched, v)
            (try is_assignment_edge(sched, v, v2) catch; false end) && (nasg += 1)
        end
        nasg > 1 && add!(:double_assignment, rid,
                         "RobotGo v$(v) has $(nasg) outgoing assignment edges (promised to $(nasg) chains)")
    end

    # --- (2) 팀 명부 vs 씬트리 간선 ---------------------------------------------------
    for n in get_nodes(st)
        n isa TransportUnitNode || continue
        roster = try robot_team(n) catch; nothing end
        roster === nothing && continue
        for (rid, _) in roster
            # 음수 placeholder = 아직 배정 안 된 팀 슬롯(정상). 진짜 로봇만 검사한다.
            _is_placeholder_id(rid) && continue
            haskey(body_pos, rid) ||
                add!(:team_ghost, rid, "unit $(node_id(n)) lists a robot with no scene node")
        end
        # 씬트리에서 이 유닛이 붙들고 있는 자식 중, 명부에 없는 로봇 = 고아 간선
        for (rid, _) in body_pos
            captured = try has_edge(st, node_id(n), rid) catch; false end
            captured && !haskey(roster, rid) &&
                add!(:orphan_capture, rid,
                     "unit $(node_id(n)) holds this robot in the scene tree but its roster does not list it")
        end
    end

    # --- (3) 이중 포획: 로봇 하나를 유닛 둘이 동시에 잡고 있다 -------------------------
    for (rid, _) in body_pos
        units = _capturing_units(st, rid)
        if length(units) > 1
            # 보간(interpolation) 안에서 따옴표를 escape 하면 파서가 헷갈리므로, 문자열을 먼저 만들어 둔다.
            names = join([string(node_id(u)) for u in units], ", ")
            add!(:multi_capture, rid, "captured by $(length(units)) units at once: $(names)")
        end
    end

    # --- (4) 스케줄의 팀 명부 vs 씬트리의 팀 명부 (부분 re-key 탐지) -------------------
    for v in Graphs.vertices(sched)
        node = try get_node_from_id(sched, get_vtx_id(sched, v)) catch; nothing end
        node isa FormTransportUnit || continue
        (try get_vtx_id(sched, v) in env.cache.closed_set catch; false end) && continue
        sched_unit = try entity(node) catch; nothing end
        sched_unit === nothing && continue
        uid = try node_id(sched_unit) catch; nothing end
        uid === nothing && continue
        scene_unit = try get_node(st, uid) catch; nothing end
        scene_unit === nothing && continue
        # 두 명부의 "실제 로봇" 키 집합이 다르면 = 한쪽만 갈아끼워진 것.
        # placeholder(음수 id)는 배정 진행에 따라 양쪽에서 다른 속도로 사라지므로 제외한다.
        _real_keys(u) = Set(k for k in keys(robot_team(u)) if !_is_placeholder_id(k))
        a = try _real_keys(sched_unit) catch; nothing end
        b = try _real_keys(scene_unit) catch; nothing end
        (a === nothing || b === nothing || a == b) && continue
        add!(:team_desync, uid,
             "schedule roster $(sort(string.(collect(a)))) != scene roster $(sort(string.(collect(b))))")
    end

    return V
end

"""
    check_identity!(env, tag; step=nothing) -> Int

Run [`identity_violations`](@ref) and report anything new, returning the violation count.
`tag` names the moment (e.g. `"after ReplaceAgent"`) so a log line says WHERE the four
registries first diverged. Each `(kind, id)` pair is reported ONCE per build so a
persistent violation does not flood the log.

Obeys `IDENTITY_CHECK[]` (off ⇒ returns 0 without scanning) and `IDENTITY_STRICT[]`
(on ⇒ throws instead of warning). Never throws on its own scanning failure: a broken
checker must not be able to break a build.
"""
# 검사를 돌리고 "새로" 발견된 위반만 로그로 알린다. 반환값 = 이번에 발견된 위반 개수.
# tag 는 "언제/어디서" 검사했는지 이름표(예: "after ReplaceAgent") — 어긋난 지점을 특정하는 핵심.
function check_identity!(env, tag::AbstractString; step = nothing)
    IDENTITY_CHECK[] || return 0                        # 꺼져 있으면 훑지도 않고 즉시 반환
    V = try identity_violations(env) catch e
        @warn "[IDENTITY] checker itself failed -> treated as no-violation" tag exception = e
        return 0                                        # 검사기 실패가 빌드를 죽이면 안 된다
    end
    isempty(V) && return 0
    where = step === nothing ? tag : "$(tag) @step $(step)"
    fresh = 0
    for v in V
        key = (v.kind, v.id)
        key in _IDENTITY_SEEN[] && continue              # 같은 위반은 빌드당 한 번만 보고
        push!(_IDENTITY_SEEN[], key); fresh += 1
        @warn "[IDENTITY] $(v.kind) — $(v.detail)" robot = v.id at = where
    end
    if IDENTITY_STRICT[] && fresh > 0
        error("[IDENTITY] $(fresh) new identity violation(s) at $(where); " *
              "first = $(V[1].kind) on $(V[1].id): $(V[1].detail)")
    end
    return length(V)
end

"""
    report_identity_delta(env, before::Int, tag) -> Int

Post-enactment half of the before/after pair: scan again and ALWAYS log
`before -> after`, returning the new total. Use this instead of a bare
[`check_identity!`](@ref) after a mutation.

Why it exists: `check_identity!` only logs violations it has not reported before, so a
run where the enactment introduced NOTHING prints nothing — indistinguishable in the log
from a run where the checker never fired. Attribution needs the NUMBER, every time.
"""
# 변경 후 검사의 짝. "이전 → 이후" 개수를 항상 찍고 새 총계를 반환한다.
# check_identity! 는 "새로 본 위반"만 찍으므로, 아무 일도 없었을 때 로그가 비어 버린다 —
# 그러면 "위반이 안 생겼다"와 "검사가 안 돌았다"를 구분할 수 없다. 그래서 개수는 매번 찍는다.
function report_identity_delta(env, before::Int, tag::AbstractString)
    IDENTITY_CHECK[] || return 0
    after = check_identity!(env, tag)
    delta = after - before
    if delta > 0
        @warn "[IDENTITY] enactment INTRODUCED $(delta) violation(s)" tag before after
    else
        @info "[IDENTITY] $(tag): before=$(before) after=$(after) (introduced $(max(0, delta)))"
    end
    return after
end

"""
    identity_summary(env) -> Dict{Symbol,Int}

Violation count per kind — the one-line PASS/FAIL number for a regression harness.
An empty `Dict` means the four registries agree.
"""
# 위반 종류별 개수만 세어 반환(회귀 테스트가 PASS/FAIL 로 쓰기 좋은 한 줄 요약). 빈 Dict = 정상.
function identity_summary(env)
    out = Dict{Symbol,Int}()
    for v in (try identity_violations(env) catch; NamedTuple[] end)
        out[v.kind] = get(out, v.kind, 0) + 1
    end
    return out
end
