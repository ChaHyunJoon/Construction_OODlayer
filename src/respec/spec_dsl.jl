# =============================================================================
# spec_dsl.jl  --  The formal-specification DSL that is the LLM/solver interface
# =============================================================================
#
# DESIGN INVARIANT (the whole safety story lives here):
#   The LLM may ONLY emit values of the closed `ConstraintSpec` union below.
#   Every spec falls into exactly ONE of two safety tiers, and BOTH tiers are
#   safe for any safety property expressed as feasibility:
#
#   TIER 1 — HARD CONSTRAINT specs (ForbidWindow, ForbidAgent; plus the geometric
#     ForbidZone/ReplaceAgent/ReformTeam handled by surgery). They compile to JuMP
#     `@constraint`s over (t0,tF,Xa) and can only SHRINK the feasible set. Admitting
#     one is gated by the FEASIBILITY verifier (verify): if the shrunk problem is
#     infeasible the spec is REJECTED and the safe fallback (line-stop) is engaged.
#     Monotone safety: a smaller feasible set cannot violate a feasibility-expressed
#     safety property that the larger set satisfied.
#
#   TIER 2 — SOFT OBJECTIVE-BIAS specs (DeprioritizeAgent). They add NO hard
#     constraint; they only re-PRICE assignment edges in the objective (via the
#     bounded AGENT_COST_BIAS registry, essential_tg_coponents.jl). They PRESERVE
#     the feasible set EXACTLY, so they can NEVER make the build infeasible / stall
#     — feasibility-preserving BY CONSTRUCTION. They only re-order PREFERENCE among
#     already-feasible (already-safe) solutions, so choosing a different optimum is
#     safe. The gate (verify_deprioritize) therefore needs no feasibility solve —
#     only grounding (the agent exists, is not closed) and a BOUNDED factor (clamped
#     so the LLM cannot cause numerical blowup or incentivize a robot, factor>=1).
#
#   This file defines the grammar. compiler.jl turns Tier-1 specs into @constraints
#   (Tier-2 specs compile to a no-op there and act via the registry at dispatch).
#   verifier.jl decides which specs are admitted. llm_bridge.jl forces the LLM to
#   produce ONLY this grammar (JSON schema / structured output).
# =============================================================================

"""
    ConstraintSpec

Abstract supertype of every re-specification the LLM is allowed to propose.
Closed union: if it is not one of the concrete subtypes below, it is rejected
before it can reach the solver. Add a new subtype ONLY together with (a) a
`compile_constraint!` method, (b) a `semantic_predicate` entry in verifier.jl,
and (c) a JSON-schema branch in llm_bridge.jl. No exceptions.
"""
# abstract type ... end : "추상 타입" 정의 — 값을 직접 만들 수 없고, 다른 타입들을 묶는 "상위 분류"역할만 함.
#   (파이썬의 추상 베이스 클래스/인터페이스 비슷). 아래 struct 들이 `<: ConstraintSpec` 로 이걸 상속함.
# 의미: LLM 이 제안할 수 있는 "제약(constraint)"의 공통 부모. 이 부모의 자식이 아니면 솔버에 닿기 전에 거부됨(닫힌 합집합).
abstract type ConstraintSpec end

"""
    ForbidAgent(agent, after)

"Robot/agent `agent` is unavailable for any task starting at or after `after`."
Models a robot fault / removal from service. Compiles to forcing every
not-yet-started node bound to `agent` to be reassigned (Xa edges into that
agent's start node are disallowed) — i.e. the assignment must route around it.
"""
# struct ... end : 새 "데이터 타입(구조체)" 정의(파이썬 class 와 비슷하나 "값을 담는 틀"에 가까움).
# <: ConstraintSpec : "이 타입은 ConstraintSpec 의 하위 타입"(상속). 즉 LLM 이 낼 수 있는 제약 종류 중 하나.
# 의미: "로봇/에이전트 `agent` 가 `after` 시각 이후로 어떤 작업도 맡을 수 없다"(로봇 고장/투입중단 모델).
struct ForbidAgent <: ConstraintSpec
    agent::AbstractID   # 사용 불가가 될 로봇/에이전트의 ID (::타입 표기 = "이 필드의 타입은 AbstractID")
    after::Float64      # 이 시각(부동소수점 실수) 이후로 불가 — Float64 는 64비트 실수(파이썬 float)
end

"""
    ForbidWindow(node, t_lo, t_hi)

"Node `node` may not be ACTIVE during [t_lo, t_hi]" — encoded as the node either
finishing before t_lo or starting after t_hi (disjunction via an auxiliary
binary; see compiler.jl). Models a temporary no-go window (a zone closed for
maintenance, a shift boundary). Still constraint-only.
"""
# 의미: "노드 `node` 가 시간구간 [t_lo, t_hi] 동안에는 ACTIVE(작동 중)이면 안 된다"(일시적 통행/작업 금지 구간).
#   → 그 구간 전에 끝나거나, 구간 후에 시작하도록 강제(자세한 인코딩은 compiler.jl 참조).
struct ForbidWindow <: ConstraintSpec
    node::AbstractID    # 금지 대상이 되는 노드(작업/단계)의 ID
    t_lo::Float64       # 금지 구간의 시작 시각(lower)
    t_hi::Float64       # 금지 구간의 끝 시각(higher)
end

"""
    ForbidZone(assembly, zone)

"Assembly `assembly`'s STAGING AREA is blocked by restriction zone `zone`, so the
assembly must be relocated to a clear staging location." UNLIKE every other spec,
ForbidZone does NOT compile to a MILP `@constraint` over (t0,tF,Xa): a no-go zone
is a SPATIAL fact, not a timing/assignment one. It triggers GEOMETRIC surgery —
`restage_assembly!` rigidly translates the assembly's staging subtree clear of the
zone (no MILP re-solve; assignment/timing structure is unchanged) — and is
dispatched in `maybe_respecify!` exactly like `ForbidAgent` dispatches to
reassignment. Safety is in the gate: the verifier admits it only if a zone-clear,
non-overlapping staging location exists (`find_clear_staging_center`); otherwise
the safe fallback (line-stop) is engaged. `zone` is the key in `RESTRICTION_ZONES`.
"""
# 의미: "조립체 `assembly` 의 적치공간(staging area)이 제한구역 `zone` 에 막혀서, 빈 곳으로 옮겨야 한다."
#   다른 제약과 달리 이건 MILP 제약을 추가하는 게 아니라 "기하학적 수술"을 일으킴(조립체를 통째로 평행이동).
#   안전장치는 검증기에 있음 — 겹치지 않는 빈 적치 위치가 있을 때만 허용, 없으면 안전 폴백(라인 정지).
struct ForbidZone <: ConstraintSpec
    assembly::AbstractID  # 옮겨야 할 조립체의 ID
    zone::Symbol          # 막고 있는 제한구역의 키. Symbol 은 :이름 형태의 "고정 라벨"(파이썬 문자열 상수 비슷, RESTRICTION_ZONES 의 키)
end

"""
    ReplaceAgent(agent, after)

"Robot/agent `agent` has BROKEN DOWN and must be REPLACED by a backup (spare)
robot that takes over its remaining work." Same shape and grounding as
`ForbidAgent` (an agent id + an `after` time) but a DISTINCT spec kind, because
the two enactments differ fundamentally:

  * `ForbidAgent` → MILP REASSIGNMENT: the agent is forbidden and the solver
    redistributes its work to the REMAINING robots (load-balancing; carries the
    reassignment double-booking issue, docs/resume_fulloop_status_2026-06-24).
  * `ReplaceAgent` → SPARE 1:1 HAND-OFF: the nearest directional spare pool donates
    one IDLE robot whose empty task chain ADOPTS the faulted robot's remaining
    chain (no MILP re-solve; structurally side-steps the double-booking).

Like `ForbidZone`, this is NOT a MILP `@constraint` over (t0,tF,Xa): it triggers a
graph relabel/splice (`replace_robot!`, replace_robot.jl) dispatched specially in
`maybe_respecify!` (`_is_robot_replace`), so it never reaches `compile_constraint!`.
The SPARE is chosen by GEOMETRY (`nearest_pool`), not by the LLM — this spec only
names the faulted `agent`. Safety is in the gate (`verify_replace`): admitted only
if the agent exists (not closed) AND a spare is available; else safe fallback.
"""
# 의미: "로봇 `agent` 가 고장났으니 예비(backup) 로봇으로 교체해 잔여 작업을 인계한다."
#   ForbidAgent 와 필드·grounding 은 같지만(로봇 id + after 시각), 처리 경로가 전혀 다른 별도 종류:
#   ForbidAgent=남은 로봇으로 MILP 재배정(버그 보유), ReplaceAgent=가장 가까운 예비로 1:1 인계(MILP 없음).
#   ForbidZone 처럼 MILP 제약이 아니라 그래프 relabel/splice(replace_robot.jl)로 전용 dispatch 됨.
#   예비 선택은 LLM 이 아니라 기하(nearest_pool)가 — 이 spec 은 고장 로봇 id 만 지목.
struct ReplaceAgent <: ConstraintSpec
    agent::AbstractID   # 고장나서 교체될 로봇/에이전트의 ID
    after::Float64      # 이 시각 이후로 불가(보통 0.0) — ForbidAgent 와 동일 필드
end

"""
    ReformTeam()

"One or more multi-robot transport TEAMS are DEADLOCKED forming — members reached
their carrying slots and now block the path of the last straggler, so the unit never
forms and the build stalls." This is the SECOND-ORDER OOD of a single-spare hand-off:
after `ReplaceAgent`, the spare arrives on a different timeline and a transport team
can wedge. Like `ForbidZone`/`ReplaceAgent`, this is NOT a MILP `@constraint` — it
triggers GEOMETRIC re-establishment (`reform_stuck_teams!`, replace_robot.jl): every
mostly-formed-but-wedged team has its straggler members snapped into their prescribed
carrying slots so the unit can form. No fields — the geometry decides WHICH teams are
stuck (the LLM only recognises "a team is deadlocked" and emits this). Safety is in
the gate (`verify_reform`): admitted only when a wedged team actually exists.
"""
# 의미: "다로봇 운반팀이 형성 교착에 빠졌다(먼저 온 멤버가 마지막 straggler의 길을 막음) → 팀을 재정립한다."
#   ReplaceAgent 후 단일 스페어의 타이밍 어긋남으로 생기는 2차 OOD. MILP 제약이 아니라 기하 재정립
#   (reform_stuck_teams!: 막힌 팀의 straggler를 슬롯으로 snap)으로 전용 dispatch. 필드 없음(어느 팀이
#   막혔는지는 기하가 판단). LLM은 "팀이 교착됐다"만 인식해 이 spec을 emit. 안전은 verify_reform 게이트.
struct ReformTeam <: ConstraintSpec
end

"""
    DeprioritizeAgent(agent, factor=50.0)

TIER-2 (soft, objective-only) spec: "robot `agent` should be AVOIDED for future work
where possible — e.g. its battery is degraded — but it remains usable if no one else can
do a task." Unlike `ForbidAgent` (a HARD removal that can make the build infeasible), this
adds NO constraint: it multiplies the assignment-edge ENERGY cost of `agent`'s frontier by
`factor` in the objective (via `deprioritize_agent!` → `AGENT_COST_BIAS`), so the energy-aware
re-solve routes work onto healthier robots ONLY when that does not break feasibility.

SAFETY (why this is the safest re-spec kind): it preserves the feasible set EXACTLY — it can
never stall the build or violate a feasibility-expressed safety property; it only re-orders
preference among already-feasible (already-safe) plans. `factor` is ADVISORY and CLAMPED to
[1, 1e3] at enactment (`deprioritize_agent!`): the LLM cannot drive it < 1 (which would
*incentivize* the robot) nor to a blowup value. This is the LLM-facing path for a battery /
soft-degradation OOD; the local `rebalance_for_battery!` is the LLM-free equivalent.
"""
# 의미(TIER-2, soft): "로봇 `agent` 를 가급적 피하되(예: 배터리 저하), 다른 로봇이 못 하면 써도 됨."
#   ForbidAgent(하드 제거)와 달리 제약을 안 더하고 목적함수에서 그 로봇의 배정엣지 에너지비용에 factor 를 곱함
#   → feasible set 불변 → 빌드 절대 멈추지 않음(구조적 안전). factor 는 enactment 에서 [1,1e3] 로 클램프.
struct DeprioritizeAgent <: ConstraintSpec
    agent::AbstractID   # 가급적 피할 로봇/에이전트 ID
    factor::Float64     # 그 로봇 배정엣지의 비용 배수(>1=회피). enactment 에서 [1,1e3] 로 클램프됨(안전).
end
DeprioritizeAgent(agent::AbstractID) = DeprioritizeAgent(agent, 50.0)  # 기본 심각도(클램프 전 advisory 값)

# -----------------------------------------------------------------------------
# A re-specification proposal is an ordered bundle of ConstraintSpecs plus the
# provenance needed for auditing/verification. The LLM returns exactly this.
# -----------------------------------------------------------------------------
"""
    RespecProposal

What the LLM produces and what the verifier consumes. `rationale` is for the
audit log only — it has NO effect on the solver. `source_event` ties the
proposal back to the OOD observation that triggered it.
"""
# 의미: LLM 이 만들어내고 검증기가 받아 처리하는 "재명세 제안" 한 묶음.
#   여러 제약(constraints) + 감사(audit)용 부가정보(rationale, source_event)를 담는 데이터 묶음.
struct RespecProposal
    constraints::Vector{ConstraintSpec}  # 제약들의 배열. Vector{T} = "T 타입 원소들의 1차원 배열"(파이썬 list[T] 비슷)
    rationale::String                    # LLM 이 댄 이유(설명) — 감사 로그용일 뿐, 솔버 동작엔 영향 없음
    source_event::String                 # 이 제안을 촉발한 OOD(이상상황) 관측을 가리키는 식별 문자열
end

# 아래는 "외부 생성자" — struct 밖에서 정의한, 이 타입을 만드는 또 다른 편의 함수.
# `f(x) = ...` 는 한 줄짜리 함수 정의(축약형). 제약 배열 하나만 받아 나머지 두 필드는 빈 문자열로 채워줌.
# cs::Vector{<:ConstraintSpec} : "ConstraintSpec 의 하위타입 원소들의 배열"이면 무엇이든 받음(<: = subtype of).
# collect(ConstraintSpec, cs) : cs 의 원소들을 모아 "원소타입이 ConstraintSpec 인 배열"로 변환(타입을 넓혀 통일).
RespecProposal(cs::Vector{<:ConstraintSpec}) = RespecProposal(collect(ConstraintSpec, cs), "", "")
