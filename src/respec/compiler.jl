# =============================================================================
# compiler.jl  --  DSL ConstraintSpec  ->  JuMP @constraint over (t0, tF, Xa)
# =============================================================================
#
# Each `compile_constraint!` method is handed the live JuMP objects from
# formulate_milp (model, t0, tF, Xa) plus `sched` so it can map an AbstractID
# to its vertex via `get_vtx(sched, id)`. These mirror the variables declared at
# essential_tg_coponents.jl:946-950. Nothing here references the objective.
#
# CONTRACT: a compile method may ONLY call @constraint / @variable(binary).
# It must never call @objective, set_objective, or delete existing constraints.
# Adding a binary aux var for a disjunction is fine — it does not relax the set.
# =============================================================================

# proposal(LLM 재명세 제안) 안의 모든 제약을 실제 JuMP 최적화 모델에 적용하는 함수.
# 함수 이름 끝의 `!` = "인자(model)를 직접 수정한다"는 관례 표시.
# 인자: model=최적화 모델, t0=각 작업 시작시각 변수, tF=종료시각 변수, Xa=배정 엣지 변수,
#       sched=스케줄 그래프, proposal::RespecProposal=적용할 제안(타입 표기 `::`).
"""
    compile_proposal!(model, t0, tF, Xa, sched, proposal::RespecProposal)

Apply every constraint in `proposal` to `model`. Called from formulate_milp's
`extra_constraints` hook (see the patch in PATCHES.md) AFTER all native
constraints and BEFORE @objective. Returns the number of constraints added.
"""
function compile_proposal!(model, t0, tF, Xa, sched, proposal::RespecProposal)
    n = 0                                                  # 추가한 제약 개수를 세는 카운터(0에서 시작)
    for cs in proposal.constraints                        # 제안에 담긴 각 제약 cs 에 대해
        n += compile_constraint!(model, t0, tF, Xa, sched, cs)  # 제약 종류별 함수를 호출해 모델에 추가하고, 추가된 개수를 누적
    end
    return n                                              # 총 추가된 제약 개수 반환
end

# --- ForbidWindow: node finishes before t_lo OR starts after t_hi -------------
# compile_constraint! : 인자 cs 의 "타입에 따라 다른 메서드가 실행"되는 다중 디스패치 함수.
#   여기 버전은 cs::ForbidWindow(특정 작업이 [t_lo, t_hi] 시간창을 피하도록)일 때만 실행됨.
# 의미: 어떤 작업을 t_lo 이전에 끝내거나(OR) t_hi 이후에 시작하도록 강제 → 그 시간창을 통째로 비움.
function compile_constraint!(model, t0, tF, Xa, sched, cs::ForbidWindow)
    v = get_vtx(sched, cs.node)                           # 제약 대상 작업(cs.node)의 그래프 정점번호를 찾음
    Mm = 1e5                                              # Big-M 상수(아주 큰 수). "둘 중 하나만 켜기"식 제약에 쓰는 트릭값.
    # b == 1  -> finish before t_lo ; b == 0 -> start after t_hi
    b = @variable(model, binary = true)                  # 0 또는 1만 갖는 이진 보조변수 b 추가(@variable 은 JuMP 매크로). 두 경우 중 하나를 고르는 스위치.
    @constraint(model, tF[v] <= cs.t_lo + Mm * (1 - b))  # b=1이면 종료시각 tF ≤ t_lo (앞에서 끝냄). b=0이면 Mm 덕에 이 제약은 사실상 무효.
    @constraint(model, t0[v] >= cs.t_hi - Mm * b)        # b=0이면 시작시각 t0 ≥ t_hi (뒤로 미룸). b=1이면 이 제약이 무효. → 둘 중 하나만 활성
    return 2                                              # 이 메서드가 추가한 제약 개수(2개) 반환
end

# --- ForbidAgent: disallow the faulted agent from starting any FUTURE task -----
# A robot enters the re-solvable future through its "frontier" free node(s): a
# RobotGo bound to the agent whose predecessor is either its RobotStart (the
# t=0 case — nothing executed yet) or an already-frozen node (the mid-build
# case — the boundary where the robot emerges from its completed past). Blocking
# the frontier's outgoing assignment edges removes the agent from all future
# work, because every deeper free moment exists only *after* it does a frontier
# task. We deliberately do NOT touch the fluid, assignment-derived identities of
# post-frontier nodes (a re-solve re-stamps those).
#
# IMPORTANT: this only forbids CANDIDATE (Big-M) edges, never an existing forced
# edge (those are structural `slot -> FormTransportUnit` links). For the re-solve
# to actually be able to route around the agent, the caller must FIRST release
# the pending assignment edges (see reassign.jl `release_pending_assignments!`);
# otherwise every other robot's chain is force-fixed and the model is infeasible
# -> verifier feasibility gate fires -> safe fallback. That is the honest
# behaviour: "reassign when the future is re-solvable, safe-stop when it isn't".
# 이 버전은 cs::ForbidAgent(고장난 로봇 1대를 앞으로의 모든 작업에서 제외)일 때 실행됨.
function compile_constraint!(model, t0, tF, Xa, sched, cs::ForbidAgent)
    n = 0                                                      # 추가한 제약 개수 카운터
    for v in Graphs.vertices(sched)                           # 스케줄 그래프의 모든 정점 v 를 훑음
        node = get_node_from_id(sched, get_vtx_id(sched, v))  # 정점번호 v → 그 정점의 ID → 실제 노드 객체
        # `A || continue` : "A 가 참이면 통과, 거짓이면 이번 반복 건너뛰기"라는 줄임 표현(파이썬의 if not A: continue).
        is_agent_frontier(sched, v, node, cs.agent) || continue  # 이 노드가 해당 로봇의 "미래 진입점(frontier)"이 아니면 건너뜀
        for v2 in Graphs.vertices(sched)                      # 그 진입점에서 나갈 수 있는 모든 도착 정점 v2 에 대해
            # Xa[v, v2] is a structural nonzero only where an edge is a decision
            # variable; skip the implicit zeros so we don't densify the matrix.
            isassigned_edge(Xa, v, v2) || continue            # Xa[v,v2]가 실제 결정변수인 칸일 때만(빈 0 자리는 건너뜀)
            # `A && continue` : "A 가 참이면 이번 반복 건너뛰기"(파이썬 if A: continue).
            Graphs.has_edge(sched, v, v2) && continue  # never forbid a forced edge  # 이미 확정된(구조적) 엣지는 절대 금지하지 않음
            @constraint(model, Xa[v, v2] == 0)                # 이 후보 배정 엣지를 0(=배정 안 함)으로 못박음 → 그 로봇에게 일 안 줌
            n += 1                                            # 추가한 제약 1개 누적
        end
    end
    return n                                                  # 총 추가 제약 개수 반환
end

# --- DeprioritizeAgent: TIER-2 soft bias — compiles to NOTHING here ------------
# It adds NO hard constraint (that is the whole point: it must not shrink the feasible
# set). The biasing happens in the OBJECTIVE via the AGENT_COST_BIAS registry, set at
# dispatch time (replan.jl `_is_deprioritize`) before the re-solve. This no-op method
# exists so the closed-union contract holds and a MIXED proposal that happens to carry a
# DeprioritizeAgent through the generic compile path is harmless (contributes 0 constraints).
# 이 버전은 cs::DeprioritizeAgent(TIER-2 소프트 편향)일 때 실행됨 — 하드 제약을 하나도 안 더하고 그냥 0을 반환.
#   (실제 편향은 여기가 아니라 목적함수/AGENT_COST_BIAS 레지스트리에서 일어남. 이 메서드는 닫힌 합집합 계약 유지용.)
compile_constraint!(model, t0, tF, Xa, sched, cs::DeprioritizeAgent) = 0

# --- helpers ------------------------------------------------------------------

"""
The past/future boundary the ForbidAgent compiler uses to locate the faulted
agent's emergence frontier, set by `fault_robot_and_reassign!` before each solve
(so the invariant need not thread through `formulate_milp`). Two sets:
`RESPEC_FROZEN` = completed (closed) nodes — a frontier node must not be one;
`RESPEC_PINNED` = closed ∪ active nodes — a frontier node's predecessor must be
one (or a RobotStart). Both empty at t=0, where origin == frontier.
"""
# const : "상수(전역으로 한 번만 정해지는 값)" 선언. 파이썬 전역 상수와 비슷.
# Ref{...} : "값을 담는 1칸짜리 상자" — 안의 내용을 나중에 바꿀 수 있게 감싸는 도구(가변 참조).
#            상자 안 내용은 RESPEC_FROZEN[] 처럼 `[]` 를 붙여 꺼내거나 새로 넣음.
# RESPEC_FROZEN = 이미 끝난(완료된) 노드들의 ID 집합. RESPEC_PINNED = 완료+진행중 노드 ID 집합.
# (각 solve 직전에 fault_robot_and_reassign! 이 내용을 채워, frontier 계산의 "과거/미래 경계"로 씀.)
const RESPEC_FROZEN = Ref{Set{AbstractID}}(Set{AbstractID}())  # 빈 집합으로 초기화한 상자
const RESPEC_PINNED = Ref{Set{AbstractID}}(Set{AbstractID}())  # 빈 집합으로 초기화한 상자

# Xa[v,v2] 자리가 "실제 변수(후보 배정 엣지)"인지 검사하는 헬퍼. Xa 는 희소행렬(SparseMatrixCSC)이라 대부분 칸이 비어있음.
"True if `Xa[v, v2]` holds a real VariableRef (a candidate assignment edge)."
function isassigned_edge(Xa::SparseMatrixCSC, v::Int, v2::Int)
    for k in nzrange(Xa, v2)            # v2 열(column)에서 값이 채워진(0이 아닌) 항목들의 위치 k 만 순회
        rowvals(Xa)[k] == v && return true  # 그중 행(row) 번호가 v 와 같은 게 있으면 = 그 칸이 채워짐 → 참 반환
    end
    return false                       # 끝까지 못 찾으면 = 빈 칸 → 거짓 반환
end

"""
    is_agent_frontier(sched, v, node, agent) -> Bool

True iff vertex `v` is an identity-stable point where `agent` enters the
re-solvable future: a non-frozen `RobotGo` bound to `agent` whose predecessor is
its `RobotStart` (t=0) or an already-frozen node (mid-build). Blocking the
out-edges of every such node removes the agent from all future assignments.
"""
# 정점 v 가 해당 로봇(agent)이 "재계획 가능한 미래로 들어서는 진입점"인지 판정해 참/거짓 반환.
# `-> Bool`(docstring 안 표기)은 "이 함수가 Bool 을 돌려준다"는 뜻.
function is_agent_frontier(sched, v::Int, node, agent::AbstractID)
    # `x isa T` : x 의 타입이 T 인지 검사(파이썬 isinstance). 아니면 즉시 거짓 반환.
    node isa RobotGo || return false                            # 이 노드가 로봇 이동(RobotGo)이 아니면 진입점 아님
    bound_to_agent(node, agent) || return false                 # 그 RobotGo 가 바로 이 로봇에게 묶인 게 아니면 아님
    # `id in 집합` : 집합 포함 검사(파이썬 in 과 동일).
    (get_vtx_id(sched, v) in RESPEC_FROZEN[]) && return false   # already completed  # 이미 완료된 노드면 진입점 아님
    pinned = RESPEC_PINNED[]                                    # 완료+진행중 노드 ID 집합을 상자에서 꺼냄
    for vp in Graphs.inneighbors(sched, v)                     # v 로 들어오는(이전 단계) 이웃 정점 vp 들을 살핌
        pnode = get_node_from_id(sched, get_vtx_id(sched, vp)) # 그 이전 노드 객체를 가져옴
        pnode isa RobotStart && return true                    # 이전이 로봇 출발점(RobotStart)이면 = t=0 진입점 → 참
        (get_vtx_id(sched, vp) in pinned) && return true       # 이전이 이미 고정된(과거) 노드면 = 과거/미래 경계 → 참
    end
    return false                                               # 위 조건 다 아니면 진입점 아님
end

# node 가 로봇 동작이고, 거기 배정된 로봇 ID 가 agent 와 같은지 검사.
"True if `node` is a robot action whose assigned robot id equals `agent`."
function bound_to_agent(node, agent::AbstractID)
    # try/catch : 파이썬의 try/except. 안에서 에러가 나면 catch 블록으로 넘어감.
    try
        return entity(node).id == agent   # 노드의 주체(entity)의 id 가 agent 와 같은지(= 비교) → 참/거짓
    catch
        return false                      # entity(node) 가 없는 노드 등에서 에러나면 그냥 거짓 처리(안전하게)
    end
end
