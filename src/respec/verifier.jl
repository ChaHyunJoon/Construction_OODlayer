# =============================================================================
# verifier.jl  --  The admit/reject gate. Safety comes from HERE, not the LLM.
# =============================================================================
#
# An LLM proposal is admitted to the solver ONLY if it passes, in order:
#   (1) GRAMMAR   : every element is a known ConstraintSpec (guaranteed by the
#                   typed parse in llm_bridge.jl; re-checked here defensively).
#   (2) STATIC    : it never touches the objective (structurally impossible in
#                   the DSL) and never references already-closed nodes (the
#                   "completed work is invariant" rule for partial replanning).
#   (3) FEASIBLE  : the MILP with the proposal's constraints injected is solved
#                   to a feasible point that also satisfies the invariant safety
#                   spec. If infeasible -> REJECT -> caller engages fallback.
#
# Only (3) costs a solve. (1)/(2) are cheap and reject most bad proposals before
# we ever pay for a solve.
#
# ── 한국어 요약 ───────────────────────────────────────────────────────────────
#  이 파일이 하는 일: LLM 이 낸 재명세(respec) 제안을 "받아들일지(Admit)/거절할지(Reject)"
#  판정하는 관문(gate). 안전은 LLM 이 아니라 바로 이 검증기에서 나온다. 순서대로 통과해야 함:
#   (1) GRAMMAR   : 모든 원소가 아는 제약 타입(ConstraintSpec)인가(파싱에서 이미 보장, 여기서 방어적 재확인).
#   (2) STATIC    : 목적함수를 건드리지 않고(DSL 상 구조적으로 불가), 이미 끝난(closed) 노드를 참조하지 않음("과거 불변" 규칙).
#   (3) FEASIBLE  : 제안을 넣은 MILP 가 실제로 풀리고(feasible) 안전 불변식도 만족하는가. 안 되면 → 거절 → 호출자 폴백.
#  (3)만 실제 풀이 비용이 듦. (1)(2)는 싸서 나쁜 제안 대부분을 풀기 전에 걸러낸다.
#  ForbidZone/ReplaceAgent/DeprioritizeAgent/ReformTeam 은 스케줄 제약이 아니라 별도 경로라
#  가벼운 전용 게이트(verify_zone/verify_replace/…)로 검증한다.
#
#  Julia 문법 참고(처음 보는 사람용):
#   · struct : 값을 담는 새 타입(파이썬 class 비슷). `abstract type` = 하위 타입들을 묶는 상위 분류(직접 생성 불가).
#   · `<: T` : "T 의 하위 타입"(상속). `x::T` : 인자/필드가 타입 T 임(다중 디스패치의 핵심).
#   · `:심볼` : `:infeasible` 처럼 콜론으로 시작하면 Symbol(가벼운 상수 이름표). nothing = 파이썬 None.
#   · `조건 || return ...` : 조건이 거짓이면 곧장 반환(반대로 `조건 && ...` 는 참일 때만 실행).
#   · `value.(x)` 의 점(.) : 원소별 적용(broadcast) — 벡터 전체 값을 한 번에.
#   · `!` 로 끝나는 함수 = 인자를 직접 수정(in-place), 예: optimize!(milp).
# =============================================================================

"""
    InvariantSpec

The closed-world safety properties that re-specification must never violate.
Phrased so each is checkable on a candidate MILP solution. Extend per scenario.
"""
# struct : 새 데이터 타입(구조체) 정의 — 파이썬 class 와 비슷하나 "값을 담는 틀"에 가까움.
# 이 InvariantSpec 은 "재명세가 절대 어기면 안 되는 안전 불변식"을 담는 틀.
# 필드 `이름::타입` 은 그 칸의 타입 표기(파이썬의 변수: 타입 힌트와 같은 의미).
struct InvariantSpec
    closed_nodes::Set{AbstractID}     # completed tasks: their (t0,tF) must not move  # 이미 끝난 작업들의 ID 집합(이들의 시작/종료시각은 못 움직임)
    frozen_t0::Dict{AbstractID,Float64}   # 노드ID → 고정된 시작시각(실수). Dict 는 파이썬 dict.
    frozen_tF::Dict{AbstractID,Float64}   # 노드ID → 고정된 종료시각
    # room to grow: forbidden-region predicates, reachability certificate, etc.    # (앞으로 금지구역·도달가능성 같은 필드를 더 넣을 수 있음)
end

# abstract type : "직접 객체를 만들 수는 없고, 하위 타입들을 묶는 상위 분류"만 만드는 선언(파이썬의 추상 베이스 클래스 비슷).
# 여기 Verdict(판정) 은 아래 Admit/Reject 두 결과를 한 종류로 묶는 상위 타입.
abstract type Verdict end
# `<: Verdict` : "이 타입은 Verdict 의 하위 타입"(상속). 한 줄 struct 안에서 `;` 로 필드를 구분해 적었음.
struct Admit  <: Verdict; proposal::RespecProposal; n_constraints::Int; end  # 통과 판정: 채택된 제안 + 제약 개수를 담음
struct Reject <: Verdict; reason::Symbol; detail::String; end               # 거절 판정: 사유(:심볼)와 설명문(String)을 담음

"""
    _respec_optimizer()

The MILP optimizer the gate/replan uses. Respects a globally-set optimizer
(`set_default_milp_optimizer!`) when present, else falls back to HiGHS. The
global is `nothing` when the demo ran with greedy assignment (never set), so the
fallback is what makes re-solving work regardless of how the env was built.
"""
# `f() = ...` : 한 줄짜리 함수 정의(축약형). 이 게이트/재계획이 쓸 MILP 솔버를 골라 반환.
# something(a, b) : a 가 nothing 이 아니면 a, nothing 이면 b 를 돌려줌(파이썬 a if a is not None else b).
_respec_optimizer() = something(default_milp_optimizer(), HiGHS.Optimizer)  # 전역 솔버가 설정돼 있으면 그걸, 없으면 HiGHS 를 사용

"""
    verify(proposal, env, invariant; optimizer) -> Verdict

The gate. Returns `Admit` (caller may inject + commit the re-solve) or
`Reject` (caller MUST engage the safe fallback). This function does the trial
solve itself so that the admit decision and the committed solve use identical
constraints — no TOCTOU gap between "verified" and "executed".
"""
# 핵심 게이트 함수: 제안을 검증해 Admit(채택) 또는 Reject(거절) 판정을 돌려줌.
# 함수 인자에서 `;` 뒤는 키워드 인자 — optimizer=..., warm_start=... 처럼 이름을 붙여 호출하고 기본값을 가짐.
# nothing : 파이썬의 None(값 없음)에 해당.
function verify(proposal::RespecProposal, env, invariant::InvariantSpec;
                optimizer = _respec_optimizer(), warm_start = nothing)
    # (1) GRAMMAR — defensive; llm_bridge already parsed into the typed union.
    for cs in proposal.constraints                       # 제안의 각 제약 cs 에 대해
        # cs 가 알려진 제약 타입(ConstraintSpec)이 아니면 즉시 거절 반환(`|| return ...` = 아니면 곧장 반환).
        cs isa ConstraintSpec || return Reject(:ungrammatical, "non-ConstraintSpec element")
    end

    # (2) STATIC — no proposal may reference / re-time an already-closed node.
    for cs in proposal.constraints                       # 각 제약에 대해
        for id in referenced_ids(cs)                     # 그 제약이 건드리는 노드 ID 들을 하나씩
            if id in invariant.closed_nodes              # 그게 "이미 끝난 노드" 집합에 들어있으면
                # $(id) : 문자열 안에 변수 값을 끼워 넣는 보간(파이썬 f"...{id}...").
                return Reject(:touches_closed, "spec references closed node $(id)")  # 과거를 건드리는 제안이라 거절
            end
        end
    end

    # (3) FEASIBILITY — build the model WITH the proposal and the freeze
    # constraints, solve, and confirm a feasible point exists.
    milp = formulate_milp(                               # 제안 + 고정조건을 넣은 MILP(혼합정수계획) 모델을 실제로 구성
        SparseAdjacencyMILP(), env.sched, env.scene_tree;  # 모델 종류, 스케줄, 장면트리 (`;` 뒤부터 키워드 인자)
        optimizer = optimizer,                           # 사용할 솔버
        t0_ = invariant.frozen_t0,        # pin completed/in-progress work  # 완료/진행중 작업의 시작시각 고정
        tF_ = invariant.frozen_tF,                       # 완료 작업의 종료시각 고정
        warm_start_soln = warm_start,     # optional: pre-fault assignment, for fast feasibility  # (선택) 시작 추정해, 빠른 풀이용
        extra_constraints = proposal,     # <-- the injected re-specification  # 바로 이 제안을 추가 제약으로 주입
    )
    optimize!(milp)                                      # 모델을 실제로 풀어봄(`!` = milp 를 직접 수정)

    # Match the codebase's own success check (full_demo.jl:431, 462).
    if primal_status(milp) != MOI.FEASIBLE_POINT        # 풀이 결과가 "가능한 해(feasible)"가 아니면 (`!=` 는 다름 비교)
        return Reject(:infeasible, "MILP infeasible with proposal injected")  # 해가 없으므로 거절
    end
    # `!조건` : 부정(파이썬 not). 불변식(안전 규칙)을 만족 못 하면
    if !satisfies_invariant(milp, env, invariant)
        return Reject(:invariant_violated, "feasible but violates safety invariant")  # 안전 위반이라 거절
    end

    return Admit(proposal, length(proposal.constraints))  # 모든 관문 통과 → 채택(제안 + 제약 개수)
end

"""
    verify_zone(proposal, env) -> Verdict

The verify gate for a SPATIAL `ForbidZone` proposal, which bypasses the generic MILP
`verify` (a zone is not a scheduling constraint — it is handled by geometric surgery in
`restage_zone.jl`). Two cheap, authoritative checks before any geometric mutation:
  (1) STATIC — no constraint references an already-closed node (the "past is invariant"
      rule, same as `verify` stage 2; `referenced_ids(::ForbidZone)` makes this apply).
  (2) ZONE-EXISTS — every `ForbidZone.zone` Symbol is a key actually present in
      `RESTRICTION_ZONES`. The LLM names a zone; the live GEOMETRY is authoritative, so a
      proposal that invents a zone the world doesn't have is rejected (never trust the LLM).
Feasibility-of-recovery is NOT decided here: the dispatch (`restage_all_blocked!` →
`translate_whole_build!`) reports `:infeasible`/`:residual_blocked` and the caller engages
the safe fallback, so an admissible-but-unrecoverable zone still fails closed.
"""
# 공간 제약 ForbidZone 제안 전용 게이트(MILP 대신 restage_zone.jl 로 처리). 두 가지 싼 검사: (1)과거 노드 참조 금지, (2)이름댄 구역이 실제로 존재.
function verify_zone(proposal::RespecProposal, env)
    invariant = build_invariant(env)                     # 현재 얼린 과거(완료 노드 등)
    for cs in proposal.constraints                       # 제안의 각 제약에 대해
        for id in referenced_ids(cs)                     # 그 제약이 건드리는 노드 ID 들
            id in invariant.closed_nodes &&              # 이미 끝난 노드를 참조하면 거절
                return Reject(:touches_closed, "zone spec references closed node $(id)")
        end
        if cs isa ForbidZone                             # ForbidZone 이면
            haskey(RESTRICTION_ZONES[], cs.zone) ||      # 이름댄 구역이 실제 지오메트리에 없으면 거절(LLM 을 믿지 않음)
                return Reject(:no_such_zone, "ForbidZone names zone :$(cs.zone) absent from RESTRICTION_ZONES")
        end
    end
    return Admit(proposal, length(proposal.constraints))  # 통과 → 채택
end

"""
    verify_replace(proposal, env) -> Verdict

The verify gate for a `ReplaceAgent` proposal (robot breakdown → spare hand-off),
which bypasses the generic MILP `verify` (the hand-off is graph surgery, not a
scheduling constraint — replace_robot.jl). Cheap, authoritative checks before any
mutation:
  (1) STATIC — no constraint references an already-closed node (`referenced_ids`
      makes this apply; the faulted robot's frontier must lie in the future).
  (2) SPARE-EXISTS — at least one spare is still parked in `SPARE_POOLS`. The
      faulted robot can only be REPLACED if a backup is available; otherwise the
      dispatch falls back to the safe stop (`nearest_pool` would return nothing).
Recovery feasibility (does the chosen spare's hand-off actually complete) is NOT
decided here: `replace_robot!` reports `:no_frontier`/`:no_spare` and the caller
engages the safe fallback, so an admissible-but-unrecoverable replace still fails closed.
"""
# 로봇 고장 → spare(예비 로봇) 인계인 ReplaceAgent 제안 전용 게이트(그래프 수술이라 MILP 우회). 검사: (1)과거 노드 참조 금지, (2)쓸 수 있는 spare 존재.
function verify_replace(proposal::RespecProposal, env)
    invariant = build_invariant(env)                     # 현재 얼린 과거
    for cs in proposal.constraints                       # 각 제약에 대해
        for id in referenced_ids(cs)                     # 건드리는 노드 ID 들
            id in invariant.closed_nodes &&              # 과거 노드 참조면 거절
                return Reject(:touches_closed, "replace spec references closed node $(id)")
        end
        if cs isa ReplaceAgent                           # ReplaceAgent 이면
            isempty(active_spares()) &&                  # SPARE_POOLS 에 남은 spare 가 없으면 거절(교체 불가)
                return Reject(:no_spare, "ReplaceAgent($(cs.agent)) but no spare robot is available")
        end
    end
    return Admit(proposal, length(proposal.constraints))  # 통과 → 채택
end

# --- which schedule ids does a spec touch (for the closed-node check) ---------
# 제약이 어떤 노드 ID 들을 건드리는지 돌려주는 함수. cs 의 "타입에 따라" 다른 메서드 실행(다중 디스패치).
# `(x,)` : 원소 1개짜리 튜플(파이썬과 동일하게 쉼표 필요). 결과를 항상 순회 가능한 묶음으로 통일.
referenced_ids(cs::ForbidWindow) = (cs.node,)    # 시간창 제약은 그 대상 작업 노드 하나를 건드림
referenced_ids(cs::ForbidAgent)  = (cs.agent,)   # 로봇금지 제약은 그 로봇(agent) 하나를 건드림
referenced_ids(cs::ForbidZone)   = (cs.assembly,)  # 구역 제약은 (grounding 한) 그 막힌 조립체 하나를 건드림
referenced_ids(cs::ReplaceAgent) = (cs.agent,)   # 교체 제약은 고장난 그 로봇(agent) 하나를 건드림
referenced_ids(cs::ReformTeam)   = ()            # 팀 재정립은 특정 노드를 안 지목(기하가 막힌 팀을 찾음)
referenced_ids(cs::DeprioritizeAgent) = (cs.agent,)  # 소프트 회피 제약은 그 로봇(agent) 하나를 건드림

"""
    verify_deprioritize(proposal, env) -> Verdict

The verify gate for a TIER-2 `DeprioritizeAgent` (soft, objective-only) proposal. Unlike the
hard-constraint `verify`, this needs NO feasibility solve: a soft cost bias PRESERVES the
feasible set exactly, so it can never make the build infeasible — the safety property holds
BY CONSTRUCTION (see spec_dsl.jl design invariant, Tier 2). Two cheap, authoritative checks:
  (1) STATIC — no referenced agent is an already-closed node (the "past is invariant" rule).
  (2) GROUNDING — the named `agent` actually exists as a physical robot in the scene; the LLM
      cannot deprioritize a robot the world does not have (never trust the LLM's id).
The `factor` is NOT trusted either: it is CLAMPED to [1, MAX_AGENT_COST_BIAS] at enactment
(`deprioritize_agent!`), so an out-of-range or adversarial value cannot blow up or invert the
objective. Admitted ⇒ caller registers the bias and re-solves; the re-solve is always feasible.
"""
# TIER-2 소프트 제약 DeprioritizeAgent(목적함수만 살짝 바꿈) 전용 게이트. 소프트라 feasible 집합을 그대로 보존 → 풀이 재검증 불필요. 검사: (1)과거 노드 참조 금지, (2)그 로봇이 실제로 존재.
function verify_deprioritize(proposal::RespecProposal, env)
    invariant = build_invariant(env)                     # 현재 얼린 과거
    # 씬에 실제 존재하는 로봇들의 ID 집합(grounding 확인용). 컴프리헨션으로 만들어 Set 으로 감쌈.
    robot_ids = Set(node_id(n) for n in get_nodes(env.scene_tree) if matches_template(RobotNode, n))
    for cs in proposal.constraints                       # 각 제약에 대해
        for id in referenced_ids(cs)                     # 건드리는 노드 ID 들
            id in invariant.closed_nodes &&              # 과거 노드 참조면 거절
                return Reject(:touches_closed, "deprioritize spec references closed node $(id)")
        end
        if cs isa DeprioritizeAgent                      # DeprioritizeAgent 이면
            cs.agent in robot_ids ||                     # 이름댄 로봇이 실제 로봇이 아니면 거절(LLM id 를 믿지 않음)
                return Reject(:no_such_agent, "DeprioritizeAgent names $(cs.agent) which is not a physical robot")
        end
    end
    return Admit(proposal, length(proposal.constraints))  # 통과 → 채택
end

"""
    verify_reform(proposal, env) -> Verdict

The verify gate for a `ReformTeam` proposal (multi-robot team deadlock → geometric
re-establishment, bypasses the MILP `verify` like ForbidZone/ReplaceAgent). A single
authoritative check: a wedged team must ACTUALLY exist (an active `RobotGo` feeding a
`FormTransportUnit` whose team is mostly — but not fully — in capture position).
Otherwise there is nothing to reform → Reject (caller engages the safe fallback), so
the LLM cannot trigger a spurious snap. The actual snap is `reform_stuck_teams!`.
"""
# 운반팀 교착 → 기하학적 재정립인 ReformTeam 제안 전용 게이트(MILP 우회). 검사: "거의 다 모였는데 막힌(wedged)" 팀이 실제로 있어야 통과.
function verify_reform(proposal::RespecProposal, env)
    # 제안에 ReformTeam 이 하나도 없으면 검사할 것 없이 통과.
    any(c -> c isa ReformTeam, proposal.constraints) || return Admit(proposal, length(proposal.constraints))
    sched = env.sched; st = env.scene_tree               # 스케줄·씬트리를 짧은 이름으로
    wedged = false                                       # "막힌 팀을 찾았나" 플래그
    for v in env.cache.active_set                        # 진행중 정점들을 순회
        n = get_node_from_id(sched, get_vtx_id(sched, v))
        n isa RobotGo || continue                        # RobotGo 가 아니면 건너뜀
        outs = Graphs.outneighbors(sched, v); isempty(outs) && continue  # 나가는 이웃(후속)이 없으면 건너뜀
        nxt = get_node_from_id(sched, get_vtx_id(sched, outs[1]))
        nxt isa FormTransportUnit || continue            # 후속이 운반팀 형성이 아니면 건너뜀
        tu = entity(nxt); team = try robot_team(tu) catch; nothing end  # 운반유닛과 그 팀 명부(없으면 nothing)
        team === nothing && continue
        ready = 0; missing = 0                           # 자리 잡은 팀원 / 아직 안 온 팀원 수
        for (mid, _) in team                             # 팀원들을 순회
            rn = try get_node(st, mid) catch; nothing end  # 그 팀원의 씬 노드
            rn === nothing && continue
            is_within_capture_distance(tu, rn) ? (ready += 1) : (missing += 1)  # 잡을 거리 안이면 ready, 아니면 missing
        end
        if ready >= 1 && missing >= 1            # mostly-formed but wedged  # 일부는 도착·일부는 못 옴 = 막힌 팀
            wedged = true; break
        end
    end
    wedged || return Reject(:no_wedged_team, "ReformTeam but no mostly-formed-but-wedged transport team exists")  # 그런 팀 없으면 거절
    return Admit(proposal, length(proposal.constraints))  # 있으면 채택
end

"""
    diagnose_transport_stall(env)

READ-ONLY diagnostic dump, emitted when a `ReformTeam` proposal is declined
(`no_wedged_team`). The "team deadlocked" OOD is a BLIND no-progress alarm
(demo_utils.jl), so a decline means the real stall is NOT the one wedge pattern
reform can fix. This tells us WHICH pattern it actually is:

  - `mostly_formed` (ready>=1 AND missing>=1) : the reformable wedge — reform WOULD
    fire; if we still see a decline with these >0 something else is off.
  - `all_ready`  (missing==0, unit still not formed) : every member is in capture
    range but the unit won't form -> a tolerance / is_in_formation mismatch.
  - `all_missing`(ready==0) : NO member reached its slot -> members can't get there
    (path blocked by a forbid zone, or a deprioritized/removed team member isn't
    driving). reform (min_ready>=1) structurally cannot help this.

Per member it prints the translation error to its prescribed carrying slot
(`Δpos`) vs the capture tolerance, so "far (not moving)" vs "close (just outside
tol)" is visible at a glance. If NO transport team is forming at all, the stall is
elsewhere and it dumps the active-frontier node-type histogram instead. Never
mutates env.
"""
# ReformTeam 이 거절될 때만 찍는 읽기전용 진단 덤프. 어떤 교착 패턴인지(mostly_formed/all_ready/all_missing)와 팀원별 오차를 로그로 보여줌. env 를 절대 수정 안 함.
function diagnose_transport_stall(env)
    sched = env.sched; st = env.scene_tree               # 스케줄·씬트리
    ttol = capture_distance_tolerance()                  # "잡았다"고 인정하는 허용 거리
    n_teams = 0                                          # 형성 중인 팀 개수
    buckets = Dict(:mostly_formed => 0, :all_ready => 0, :all_missing => 0)  # 패턴별 팀 수 집계
    lines = String[]                                     # 출력할 로그 줄들
    seen = Set{AbstractID}()                             # 이미 본 운반유닛(중복 집계 방지)
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
        n_teams += 1
        ready = 0; missing = 0
        mlines = String[]
        for (mid, _) in team
            rn = try get_node(st, mid) catch; nothing end
            if rn === nothing
                push!(mlines, "      $(mid): <no scene node>")
                continue
            end
            within = is_within_capture_distance(tu, rn)
            et = try
                t = relative_transform(global_transform(tu), global_transform(rn))
                t_des = child_transform(tu, node_id(rn))
                norm(t.translation - t_des.translation)
            catch; NaN end
            within ? (ready += 1) : (missing += 1)       # 잡을 거리 안이면 ready, 아니면 missing
            push!(mlines, "      $(mid): $(within ? "READY  " : "MISSING") Δpos=$(round(et, digits=3))m (tol=$(round(ttol, digits=3)))")
        end
        # 팀 상태 분류: 일부 도착+일부 미도착=mostly_formed(reform 이 고칠 수 있는 유일한 패턴), 다 도착했는데 안 형성=all_ready, 아무도 못 옴=all_missing.
        cls = (ready >= 1 && missing >= 1) ? :mostly_formed : (missing == 0 ? :all_ready : :all_missing)
        buckets[cls] += 1                                # 해당 패턴 카운트 +1
        push!(lines, "    TransportUnit $(node_id(tu)): $(ready) ready / $(missing) missing  -> $(cls)")
        append!(lines, mlines)
    end
    if n_teams == 0
        # No team forming: the stall is elsewhere. Distinguish a NAVIGATION stall
        # (robots stuck EN-ROUTE, far from their goals — congestion / zone-blocked
        # paths) from a SCHEDULING deadlock (robots AT their goals but is_goal is
        # false because a downstream task's predecessors never become ready). The
        # goal-distance split tells the two apart, which decides the right recovery.
        types = Dict{String,Int}()                       # 진행중 노드 종류별 개수(히스토그램)
        at_goal = 0; en_route = 0; dists = Float64[]     # 목표 도착 수 / 이동중 수 / 목표까지 거리들
        ttol = capture_distance_tolerance()
        for v in collect(env.cache.active_set)           # 진행중 정점들
            node = get_node_from_id(sched, get_vtx_id(sched, v))
            nm = string(nameof(typeof(node)))            # 노드 타입 이름을 문자열로
            types[nm] = get(types, nm, 0) + 1            # 그 타입 카운트 +1 (get(d,k,기본값) = 없으면 기본값)
            if node isa RobotGo || node isa TransportUnitGo  # 이동하는 노드만 목표까지 거리 측정
                d = try
                    s = global_transform(entity(node))   # 현재 위치
                    g = global_transform(goal_config(node))  # 목표 위치
                    norm(Vector{Float64}(s.translation[1:2]) .- Vector{Float64}(g.translation[1:2]))  # 둘 사이 거리
                catch; NaN end
                isnan(d) || (push!(dists, d); d <= ttol ? (at_goal += 1) : (en_route += 1))  # 허용거리 안이면 도착, 아니면 이동중
            end
        end
        dsum = isempty(dists) ? "n/a" :
            "min=$(round(minimum(dists),digits=2)) max=$(round(maximum(dists),digits=2)) mean=$(round(sum(dists)/length(dists),digits=2))"
        @warn "[RESPEC][DIAG] reform declined, NO team forming (stall is NOT a team wedge). " *
            "types=$(types) | Go-nodes: AT-goal/waiting=$(at_goal) EN-ROUTE=$(en_route) dist[$dsum] | " *
            "active_zones=$(length(RESTRICTION_ZONES[])) " *
            "=> $(en_route > at_goal ? "NAVIGATION stall (blocked/congested)" : "SCHEDULING wait (downstream not ready)")"
        return
    end
    @warn "[RESPEC][DIAG] reform declined: $(n_teams) forming team(s) — " *
        "mostly_formed=$(buckets[:mostly_formed]) all_ready=$(buckets[:all_ready]) all_missing=$(buckets[:all_missing]) " *
        "(reform only fixes mostly_formed).\n" * join(lines, "\n")
    return
end

"""
    satisfies_invariant(milp, env, invariant) -> Bool

Confirm the solved MILP did not move any frozen node and meets every additional
safety property. The freeze is enforced as a constraint already; this re-checks
the realized solution as defense-in-depth. Extend with reachability / no-go
region checks as Year-2 certified safe-set lands.
"""
# 풀린 MILP 해가 고정 노드들을 실제로 안 움직였는지 다시 검사해 참/거짓 반환(방어적 이중확인).
function satisfies_invariant(milp, env, invariant::InvariantSpec)
    sched = env.sched                          # 스케줄 그래프 꺼내기
    # value.(...) : 최적화 변수의 "구해진 값"을 읽음. `.` 은 원소별 적용(브로드캐스트) — 벡터 전체 값을 한 번에.
    # milp.model[:t0] : 모델 안에 :t0 라는 심볼 이름으로 등록된 시작시각 변수들.
    t0v = value.(milp.model[:t0])              # 풀린 해의 모든 작업 시작시각 값
    tFv = value.(milp.model[:tF])              # 풀린 해의 모든 작업 종료시각 값
    tol = 1e-3                                 # 허용 오차(부동소수 비교용 작은 여유값)
    # Frozen times are LOWER BOUNDS: completed/in-progress work cannot be pulled
    # earlier than it actually happened ("the past is invariant"). Confirm the
    # realized solution respects them. (The makespan objective gives the solver
    # no incentive to push frozen work later, so in practice they stay pinned.)
    for (id, t) in invariant.frozen_t0         # 고정된 (노드ID id → 시작시각 t) 쌍을 순회 (딕셔너리 순회 = (키,값) 쌍)
        # 해의 시작시각이 고정값 t 보다 (오차 빼고) 작지 않은지 확인. 작으면(과거를 앞당김) 즉시 거짓 반환.
        t0v[get_vtx(sched, id)] >= t - tol || return false
    end
    for (id, t) in invariant.frozen_tF         # 고정된 (노드ID → 종료시각) 쌍에 대해서도 똑같이
        tFv[get_vtx(sched, id)] >= t - tol || return false  # 종료시각이 고정값보다 당겨졌으면 거짓
    end
    return true                                # 모든 고정값을 지켰으면 참(불변식 만족)
end

"""
    build_invariant(env) -> InvariantSpec

Snapshot the current execution state into the freeze set: every closed node and
every active (in-progress) node has its realized timing pinned so re-solving can
only re-plan the FUTURE. This is the operational meaning of
"constraint-only, completed-work-invariant" for partial replanning.
"""
# 현재 실행 상태를 스냅샷 떠서 InvariantSpec(고정 집합)을 만든다 — 미래만 재계획되도록 과거를 못박는 함수.
function build_invariant(env)
    sched = env.sched                          # 스케줄 그래프
    closed = Set{AbstractID}()                 # 완료 노드 ID 를 담을 빈 집합(Set{타입}() = 빈 집합 생성)
    ft0 = Dict{AbstractID,Float64}()           # 노드ID → 고정 시작시각 을 담을 빈 딕셔너리
    ftF = Dict{AbstractID,Float64}()           # 노드ID → 고정 종료시각 을 담을 빈 딕셔너리
    # Completed nodes: pin BOTH ends to their realized schedule times. These
    # become >= lower bounds in the re-solve, so finished work cannot be pulled
    # into the past, and is also flagged closed so no spec may reference it.
    for v in env.cache.closed_set              # 이미 끝난(closed) 작업 정점들에 대해
        id = get_vtx_id(sched, v)              # 정점번호 → 노드 ID
        push!(closed, id)                      # 완료 집합에 추가(push! = 집합/배열에 원소 넣기)
        # Float64(...) : 값을 64비트 실수로 변환(타입 맞추기). get_t0/get_tF = 실제 진행된 시작/종료시각.
        ft0[id] = Float64(get_t0(sched, v))    # 시작시각 고정 등록
        ftF[id] = Float64(get_tF(sched, v))    # 종료시각 고정 등록 (완료작업은 양끝 다 고정)
    end
    # In-progress nodes: they have already STARTED, so lower-bound their start;
    # leave the finish free for the re-plan to determine. (Not added to `closed`
    # — a re-spec may still legitimately constrain how an active task finishes.)
    for v in env.cache.active_set              # 지금 진행중(active)인 작업 정점들에 대해
        id = get_vtx_id(sched, v)
        ft0[id] = Float64(get_t0(sched, v))    # 시작시각만 고정(이미 시작했으니), 종료시각은 재계획이 정하도록 자유로 둠
    end
    return InvariantSpec(closed, ft0, ftF)     # 세 모음으로 불변식 객체를 만들어 반환
end
