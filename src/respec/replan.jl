# =============================================================================
# replan.jl  --  Orchestration at the execution seam (demo_utils.jl:96)
# =============================================================================
#
#   generate-as-formal-spec  ->  verify  ->  admit  ->  re-solve  ->  resume
#
# This is the single function the simulation loop calls each step (cheaply: it
# returns immediately unless an OOD event is pending). It NEVER lets an
# unverified proposal reach the solver-of-record, and on ANY failure path it
# engages the safe fallback, so the solver's guarantees are preserved end to end.
#
# [한국어 요약]
#   이 파일 = respec(재명세) 파이프라인의 "실행 이음새" 오케스트레이션. OOD 이벤트 하나를
#   다음 순서로 처리한다:  생성(NL→형식 spec) → 검증(verify) → 채택(admit) → 재풀이(re-solve) → 재개(resume).
#   프로젝트 역할: OOD "대응" 쪽(ood_injection.jl 이 만든 이벤트를 받아 계획을 고쳐 세움).
#   핵심 안전 원칙: 검증 안 된 제안(proposal)은 절대 실제 솔버에 못 닿게 하고, 어떤 실패 경로에서도
#   안전 폴백(engage_fallback!, line stop)으로 떨어져 솔버의 보장(guarantee)을 끝까지 지킴.
# 문법 참고:
#   · mutable struct : 필드 값을 바꿀 수 있는 구조체(기본 struct 는 불변).
#   · const NAME = Ref(값) : 상수 이름 + 안 내용물(Ref[])은 가변인 전역 상태 상자.
#   · f(p::RespecProposal) = ... : 인자 타입별 메서드(다중 디스패치). `::Type` 은 타입 표기.
#   · 이름 끝 `!` = in-place 수정 관례, `?` = 술어(true/false). `:이름` = Symbol(가벼운 라벨).
#   · `A || return B` / `A && B` : 단락 평가(파이썬 한 줄 if). `x -> ...` : 익명함수(람다).
# =============================================================================

"""
    OODQueue

Year-1 stub for the detection layer. For the MVP, scenario scripts push
structured event strings here; later this is replaced by the conformal-prediction
"abstain" trigger. `poll_ood!` pops at most one event per step.
"""
# `mutable struct` : 필드 값을 나중에 바꿀 수 있는 구조체(기본 struct 는 한 번 만들면 필드가 불변).
#                    파이썬 class 처럼 내부 상태가 변하는 객체가 필요할 때 씀.
# 이 구조체는 처리 대기 중인 OOD(이상상황) 이벤트 문자열들을 줄(큐)로 들고 있음.
mutable struct OODQueue
    pending::Vector{String}             # 대기 중인 이벤트 문자열들의 배열(Vector{String} = String 의 벡터)
end
# `OODQueue() = ...` : 한 줄짜리 함수 정의(=축약형). 여기선 인자 없이 부르면 "빈 큐"를 만들어 주는 생성자.
OODQueue() = OODQueue(String[])         # String[] = 빈 문자열 배열 → pending 이 비어 있는 큐 생성
# q::OODQueue : 인자 q 의 타입이 OODQueue 일 때만 이 메서드 사용(다중 디스패치). 끝의 `!` = q 를 직접 수정.
# 삼항: 큐가 비었으면 nothing(없음), 아니면 popfirst!(맨 앞 원소를 꺼내며 제거; 파이썬 list.pop(0)).
poll_ood!(q::OODQueue) = isempty(q.pending) ? nothing : popfirst!(q.pending)

# -----------------------------------------------------------------------------
# Control layer wiring the respec hook into the simulation loop WITHOUT touching
# the SimParameters struct. The seam in simulate! (demo_utils.jl) calls
# `respec_step!(env)` every step; it is a true no-op unless RESPEC_ENABLED[] is
# set, so existing demos are completely unaffected by the hook's presence.
# -----------------------------------------------------------------------------
# [한국어] SimParameters 구조체를 안 건드리고 respec 훅을 시뮬레이션 루프에 꽂는 제어 레이어.
#   simulate! 의 이음새가 매 스텝 respec_step!(env) 를 부르되, RESPEC_ENABLED[] 가 켜져야만 동작
#   (꺼져 있으면 진짜 no-op)이라 기존 데모엔 아무 영향 없음.

"Master on/off switch for the re-specification hook (default off)."
# Ref(값) : 값 하나를 담는 "참조 상자". const 로 묶인 상수라도 상자 안의 내용물은 바꿀 수 있게 해주는 기법.
# 내용물 접근은 `RESPEC_ENABLED[]`(대괄호)로 함. 즉 전역 on/off 플래그(처음엔 false=꺼짐).
const RESPEC_ENABLED = Ref(false)

"""
    RESPEC_DRIFT_REPAIR  ·  respec_drift_repair() -> Bool

"복구가 만든 기하 드리프트를 크래시 대신 스냅으로 완화할 것인가."

왜 `RESPEC_ENABLED` 와 따로 두는가 (2026-08-06)
------------------------------------------------
`RESPEC_ENABLED` 는 실제로 **네 가지**를 한꺼번에 켜고 끈다: (1) respec 큐 처리, (2) OOD 이벤트의
큐 적재, (3) `_enforce_serial_frontiers!`, (4) `close_node!(CloseBuildStep)` 의 포획 드리프트 복구.
그런데 (4)는 나머지 셋과 성질이 다르다 — "누가 복구를 모는가"가 아니라 "복구가 이미 일어난 뒤의
씬을 어떻게 다룰 것인가"이기 때문이다.

이 구분이 없어서 실제로 사고가 났다: `tools/monitor/run_demo.jl` 은 큐를 우회해 **자기가 직접**
복구를 집행하므로 `RESPEC_ENABLED[] = false` 로 둔다. 그러면 (4)도 같이 꺼진다. 그 상태에서
`RelocateBuild`(빌드 전체 평행이동)가 빌드 중반에 발화하면, 이미 배달됐지만 아직 포획되지 않은
부품이 조립체를 따라오지 못해 `@assert has_edge(...)` 로 **시뮬 전체가 죽는다**(실측 2026-08-06:
closed=151, Δ=2.4 m, object 9 ↔ assembly 4). 정작 그 상황을 위해 쓰인 복구 코드가 바로 위에 있는데
게이트 하나 때문에 도달하지 못했다.

기본값 `nothing` = **예전과 동일**(RESPEC_ENABLED 를 따라간다). 명시적으로 true/false 를 넣은
호출자만 동작이 달라지므로 기존 실행·덤프의 재현성은 그대로다.
"""
# 기본 nothing = RESPEC_ENABLED 를 따름(기존 동작 불변). true 로 두면 큐를 안 쓰는 수동 복구 루프에서도
# 포획 드리프트가 크래시 대신 스냅으로 완화된다.
const RESPEC_DRIFT_REPAIR = Ref{Union{Nothing,Bool}}(nothing)
respec_drift_repair() = RESPEC_DRIFT_REPAIR[] === nothing ? RESPEC_ENABLED[] : RESPEC_DRIFT_REPAIR[]

"""
κ for the (now-deleted) soft objective-bias re-solve: how much makespan magnitude the energy term
is allowed to
be worth (`w_eff = κ · speed_scale / efficiency_scale`, see AUTO_EFFICIENCY_KAPPA). κ→0 makes the
bias inert again; κ≈0.25 lets energy decide among equal- and near-equal-makespan assignments
without overturning a genuinely faster plan. Override with `RESPEC_DEPRIO_KAPPA`.
"""
# (한국어) Deprioritize 재풀이에서 에너지 항이 makespan 규모의 몇 배까지 값어치를 갖게 할지. 0 이면
#   예전처럼 무효과, 0.25 면 makespan 이 (거의) 같은 배정들 사이에서만 에너지가 결정권을 갖는다.
#
# ⚠️ 2026-08-13 (계획 태스크 6, spec §6.3): **프로덕션 경로는 더 이상 이 값을 읽지 않는다.**
#   κ 는 objective.json → `init_objective_weights!` 가 심는 전역 `AUTO_EFFICIENCY_KAPPA[]` 로
#   승격됐다(예전엔 아래 maybe_respecify! 의 soft-bias 분기 한 곳에서만 켰다가 즉시
#   원복했고, 그래서 다른 모든 매크로의 재풀이가 에너지를 버린 채 돌았다 — spec §2.2).
#
#   ☠️ 이건 **휴면 상태의 두 번째 진실원**이다. 아래 기본값 0.25 는 objective.json 의 kappa=0.01 과
#   **다르며**, 둘이 같아지도록 맞출 생각도 하지 말 것 — 같은 값을 두 곳에 두는 것이 바로 spec §5 가
#   금지하는 리터럴 복붙이다. 남은 참조는 `tools/tests.jl:1201` 하나뿐이고, 그 자리는 스스로 κ 를
#   세팅했다 `finally` 로 원복하는 자립형 진단이라 오염이 없다. **이 상수를 프로덕션 경로에 다시
#   끌어다 쓰지 말 것.** 그 진단이 사라지면 이 상수도 같이 지운다.
#   (`RESPEC_DEPRIO_KAPPA` 환경변수도 같이 죽은 손잡이다 — 돌려도 실제 재풀이의 κ 는 안 바뀐다.)
const DEPRIORITIZE_KAPPA = Ref(try
        parse(Float64, get(ENV, "RESPEC_DEPRIO_KAPPA", "0.25"))
    catch
        0.25
    end)

# -----------------------------------------------------------------------------
# PLUGGABLE PROPOSAL PRODUCER — the comparison seam.
# `maybe_respecify!` normally GENERATES the proposal via the LLM (`llm_to_proposal`).
# A non-nothing producer here REPLACES that generation step: it is a callable
# `(env, event::String) -> RespecProposal | Nothing` supplied by whatever DECISION
# method is under test — a MARL policy (DecPOMDP installs itself here), or a baseline
# (B1/B2/B3). EVERYTHING downstream (verify -> dispatch -> re-solve -> resume) is
# identical, so swapping the producer isolates the decision function as the only
# variable. Default `nothing` => the LLM path, so existing demos are unaffected.
# -----------------------------------------------------------------------------
# [한국어] 아래는 그 "제안 생성기 교체 지점(비교 이음새)"의 정의부. 생성 단계만 갈아끼우고 나머지 파이프라인은
#   동일하게 두어, LLM vs MARL vs baseline 을 공정하게 비교한다.
"Optional `(env, event) -> RespecProposal | Nothing`; when set, replaces the LLM generator."
# [한국어] "제안 생성기(producer)" 교체 지점 = 비교 실험의 이음새. 기본값 nothing 이면 LLM 경로를 씀.
#   여기에 (env, event)->제안 형태의 함수를 꽂으면(예: MARL 정책, baseline) 생성 단계만 그것으로 바뀌고,
#   그 뒤(검증→대응→재풀이→재개)는 완전히 동일 → "결정 방법"만 변수로 분리해 공정 비교 가능.
#   Ref{Any} : 어떤 타입이든 담는 상자(함수도 값). 기본 nothing 이라 기존 데모는 그대로 LLM 경로.
const RESPEC_PRODUCER = Ref{Any}(nothing)
# producer 를 설치(꽂기).
set_respec_producer!(f) = (RESPEC_PRODUCER[] = f; nothing)
# producer 를 떼어내 다시 기본 LLM 경로로 되돌리기.
clear_respec_producer!() = (RESPEC_PRODUCER[] = nothing; nothing)

"Process-global OOD event queue the simulation seam drains each step."
# 프로세스 전역에서 공유하는 단 하나의 OOD 이벤트 큐(시뮬레이션이 매 스텝 비워가며 처리).
const RESPEC_QUEUE = OODQueue()

"""
    push_ood!(event::AbstractString)

Enqueue an open-world event to be handled at the next simulation step. For the
MVP, scenario scripts call this to inject a fault/new-requirement; later the
Year-1 detection layer calls it. Returns the event for convenience.
"""
# event::AbstractString : 인자 타입이 "문자열 종류"(String 의 상위 추상 타입)면 받음 — 여러 문자열 타입을 두루 허용.
# 끝의 `!` : 전역 큐 RESPEC_QUEUE 를 직접 바꾸므로 관례대로 표시.
function push_ood!(event::AbstractString)
    push!(RESPEC_QUEUE.pending, String(event))  # 전역 큐의 pending 배열 끝에 이벤트 문자열을 추가(예약)
    return event                                 # 편의상 받은 이벤트를 그대로 돌려줌
end

"""
    respec_step!(env) -> Symbol

The single call the simulation loop makes each step. No-op (`:disabled`) unless
the hook is enabled; otherwise drives generate→verify→admit→re-solve via
`maybe_respecify!`. Kept tiny so the per-step cost is ~zero when idle.
"""
# 시뮬레이션 루프가 매 스텝 부르는 단 하나의 진입점. 훅이 꺼져 있으면 :disabled 로 즉시 반환(비용 ~0).
function respec_step!(env)
    # `RESPEC_ENABLED[]` : Ref 상자 안의 내용물 읽기. `A || return ...` 단락:
    # 플래그가 false(꺼짐)면 곧바로 `:disabled` 를 반환하고 끝냄. `:이름` 은 Symbol(가볍고 빠른 상수 라벨; 파이썬 enum 비슷).
    RESPEC_ENABLED[] || return :disabled
    return maybe_respecify!(env, RESPEC_QUEUE; producer = RESPEC_PRODUCER[])  # 켜져 있으면 재명세 처리에 위임(producer 주입)
end

"""
    _is_robot_fault(proposal) -> Bool

True iff the proposal is exactly one `ForbidAgent` — i.e. "a robot became
unavailable". Such a re-spec MUST NOT take the generic compile+verify path:
`ForbidAgent`'s compiler needs the frozen/pinned frontier context AND the pending
assignment edges released first (both set up by `fault_robot_and_reassign!`).
Through the generic path it silently compiles to ZERO constraints (the frontier
is never located because RESPEC_FROZEN/PINNED are empty) — a *hollow admit* that
removes the robot from nothing. So we dispatch these to the reassign machinery.
"""
# 한 줄짜리 함수: 인자 p 가 RespecProposal 타입일 때, "제약이 딱 1개이고 그게 ForbidAgent 인가"를 참/거짓으로 반환.
# `&&` 단락 결과가 그대로 반환값(앞이 참일 때만 뒤를 평가). p.constraints[1] : 첫 제약(인덱스 1부터 시작).
_is_robot_fault(p::RespecProposal) =
    length(p.constraints) == 1 && p.constraints[1] isa ForbidAgent

"""
    _is_zone_respec(proposal) -> Bool

True iff the proposal carries a `ForbidZone` — a SPATIAL "a no-go zone covers a
staging area" event. Like `_is_robot_fault`, this needs geometric surgery (relocate
the blocked staging) not a MILP re-solve, so it is dispatched specially to
`restage_all_blocked!` (which clears EVERY assembly the zone covers, not just the
one named in the spec — the zone is detected geometrically from `RESTRICTION_ZONES`).
"""
# 제안에 ForbidZone(공간형 "no-go 구역이 적치영역을 덮음")이 하나라도 있으면 true. any(조건함수, 컬렉션)=하나라도 참이면 true.
_is_zone_respec(p::RespecProposal) = any(c -> c isa ForbidZone, p.constraints)

"""
    _is_robot_replace(proposal) -> Bool

True iff the proposal carries a `ReplaceAgent` — a robot BREAKDOWN to be handled by
the SPARE 1:1 chain hand-off (replace_robot.jl), NOT the MILP reassignment that
`ForbidAgent` triggers. Like `_is_zone_respec`, this needs graph surgery (graft the
faulted robot's thread onto an idle spare) not a MILP re-solve, so it is dispatched
specially. The spare is chosen GEOMETRICALLY (`nearest_pool` to the faulted robot),
never by the LLM — the spec only names the faulted agent.
"""
# 제안에 ReplaceAgent(로봇 고장 → 예비 1:1 인계)가 하나라도 있으면 true. 예비 선택은 기하(nearest_pool)로, LLM 이 아님.
_is_robot_replace(p::RespecProposal) = any(c -> c isa ReplaceAgent, p.constraints)

"""
    _is_relocate_build(proposal) -> Bool

True iff the proposal carries a `RelocateBuild` — "shift the WHOLE build clear of a no-go
zone". `restage_all_blocked!` can only move assemblies that have not started building, and
that set is empty from the first batch boundary onward (measured 2026-08-03), whereas the
whole-build translation has no such precondition — so when a proposal carries BOTH, the
stronger lever is the one that runs.

🔴 **2026-08-21 (C1, 순차 집행): 그 규칙이 이제 "검사 순서"가 아니라 명시적 흡수로 집행된다.**
예전에는 `if` 사슬의 순서 자체가 배타성을 보장했다(먼저 걸린 분기가 `return` 했으므로).
순차 집행은 모든 분기를 돌리므로 순서만으로는 배타성이 사라진다 — 그래서 `_subsumption` 이
**같은 zone** 을 가리키는 `ForbidZone` 단위를 `:subsumed_by_relocate` 로 기록하고 집행하지
않는다. 그렇게 하지 않으면 이미 비워진 구역에 재적치가 한 번 더 돌고, 그 결과가
`:partial`/`:infeasible`/`:residual_blocked` 면 `engage_fallback!` 로 가서 **성공적으로 옮긴
빌드를 잉여 단위가 영구 line-stop 시킨다**(옛 코드에 없던 실패 경로).
서로 **다른** zone 이면 흡수하지 않는다 — 그 구역에는 진짜 할 일이 있다.
"""
# 제안에 RelocateBuild(빌드 전체를 구역 밖으로 평행이동)가 하나라도 있으면 true. maybe_respecify! 에서
# ForbidZone 분기보다 **먼저** 검사한다 — 둘 다 들어있으면 전제조건이 없는 쪽(전체 이동)을 써야 하므로.
_is_relocate_build(p::RespecProposal) = any(c -> c isa RelocateBuild, p.constraints)

"""
    _is_translate_build(proposal) -> Bool

True iff the proposal carries a `TranslateBuild(dx, dy)` — "shift the WHOLE build by **this**
rigid Δ" (Task C3 · spec §5-5, L2-b).

🔴 **`RelocateBuild` 와 같은 지렛대가 아니다 — 같은 *기전*을 쓰는 다른 *행동*이다.**
둘 다 `_apply_uniform_translation!` 로 내려가지만 Δ 의 출처가 반대다: `RelocateBuild` 는
`_find_min_translation` 이 Δ 를 **찾아 주는 solver** 이고, `TranslateBuild` 는 제안자가 Δ 를
**직접 정한다**. 그래서 `TranslateBuild` 는 구역 이름을 안 받고, 어떤 구역을 비운다는 보장도
스스로 하지 못한다 — 그 판정은 결과 배치를 보는 `verify_translate`(Task C4)의 몫이다.

🔴 **그래서 `_subsumption` 에 넣지 않았다** (이 태스크의 판단, 보고서에 근거를 남긴다):
흡수는 "다른 제약이 이 단위의 일을 **이미 했다**" 는 증거가 있을 때만 정당하다.
`RelocateBuild(:z)` 는 zone 을 이름으로 지목하고 그 zone 을 비우도록 **구성적으로** 풀기 때문에
그 증거를 들고 있다. `TranslateBuild(dx, dy)` 는 zone 을 지목하지도, 비운다는 보장도 없다 —
그것으로 `ForbidZone` 단위를 흡수하면 **구역을 비울 유일한 단위를 조용히 버리는** 것이 된다.
반대 방향(`RelocateBuild` 가 `TranslateBuild` 를 흡수)도 안 한다: `translate_whole_build!` 는
**집행 시점의** 라이브 기하에서 Δ 를 다시 풀므로 앞선 `TranslateBuild` 의 이동을 이미 반영한
잔여 이동만 낸다(이중 계산이 아니다). 이동은 합성된다는 `_apply_uniform_translation!` 의
문서화된 성질이 그것을 보장한다.
"""
_is_translate_build(p::RespecProposal) = any(c -> c isa TranslateBuild, p.constraints)

# ReformTeam: multi-robot team deadlock -> geometric re-establishment (reform_stuck_teams!),
# dispatched specially like ReplaceAgent/ForbidZone (no MILP).
# 제안에 ReformTeam(다중로봇 팀 교착 → 기하적 재구성)이 하나라도 있으면 true. MILP 없이 특수 처리됨.
_is_reform(p::RespecProposal) = any(c -> c isa ReformTeam, p.constraints)

# SwapBattery 제안인가 — ReplaceAgent 와 마찬가지로 MILP 재풀이가 아니라 전용 실행부로 보낸다.
# (배터리만 갈면 스케줄도 기하도 안 바뀌므로 재풀이할 게 없음.)
_is_battery_swap(p::RespecProposal) = any(c -> c isa SwapBattery, p.constraints)

# 🔴 2026-08-24 (spec §5.4, Task 5): 여기 있던 `_is_deprioritize` 판정자를 지웠다 —
#   `DeprioritizeAgent` kind 삭제로 순수-soft 제안이라는 것이 존재하지 않는다.
#   그 판정자가 몰던 dispatch 분기(`verify_deprioritize` + `deprioritize_agent!` + 재풀이)와
#   `_subsumption` 의 `:subsumed_by_hard_spec` 사유도 같은 커밋에서 사라졌다.

"""
    _robot_position_2d(env, agent) -> Vector{Float64}

Best-effort 2D (x,y) world position of robot `agent` (its scene-tree body), used to
pick the NEAREST spare pool. Falls back to the origin if the body can't be read.
"""
# 로봇 agent 의 2D (x,y) 세계 위치를 최선의 방법으로 구함(가장 가까운 예비 풀 선택용). 못 읽으면 원점.
function _robot_position_2d(env, agent::AbstractID)
    # Prefer the recorded BREAKDOWN position: a faulted robot may have been towed off-grid
    # (_clear_faulted_robot!), so its live body no longer reflects where it broke down. The
    # nearest spare pool must be chosen relative to the breakdown site, not the graveyard.
    # [한국어] 기록된 "고장 당시 위치"를 우선 사용: 고장 로봇은 무덤으로 치워졌을 수 있어 현재 본체
    #          위치가 고장 지점과 다름 → 예비 풀은 고장 지점 기준으로 골라야 함.
    fr = faulted_robots()
    haskey(fr, agent) && return Float64[fr[agent][1], fr[agent][2]]  # 고장 기록이 있으면 그 위치 반환
    try
        t = global_transform(get_node(env.scene_tree, agent)).translation  # 아니면 씬트리 본체의 현재 위치
        return Float64[t[1], t[2]]
    catch
        return Float64[0.0, 0.0]                   # 못 읽으면 원점으로 폴백
    end
end

"""
    maybe_respecify!(env, ood_queue; id_resolver, optimizer, producer) -> Symbol

Called once per sim step from `simulate!` right after `step_environment!`.
Polls ONE OOD event off `ood_queue`, turns it into a typed `RespecProposal` (LLM or a
plugged `producer`), and **enacts every constraint the proposal carries** — see below.
The world state is mutated in place; the return value is the aggregated verdict.

SEQUENTIAL ENACTMENT (Task C1, 2026-08-21)
------------------------------------------
🔴 이 함수는 예전에 **first-match-wins** 였다: 일곱 개의 `if _is_*(proposal)` 분기가 각각
`return` 해서, `[RelocateBuild(:z), SwapBattery(r)]` 같은 제약 **벡터**가 첫 분기 하나로
무너지고 나머지는 **조용히** 버려졌다(측정: 조합 팔이 65/65 instance 에서 정보량 0).
지금은 제안의 `constraints` 를 **집행 단위**로 쪼개 `_enact_one!` 에 하나씩 넘긴다.
바뀐 것은 **제어 흐름 하나뿐**이고 분기 본문의 로직은 그대로다.

**집행 순서 규칙** (`_enact_kind` → `_ENACT_RANK`, 오름차순):

    1 relocate  RelocateBuild        기하: 빌드 전체 평행이동
    2 zone      ForbidZone           기하: 막힌 조립체 재적치
    3 replace   ReplaceAgent         그래프: 예비 1:1 인계(비파괴 — 실패 시 스스로 4로 강등)
    4 fault     ForbidAgent          그래프: MILP 재분배(파괴적 — 남은 일을 흩뿌린다)
    5 battery   SwapBattery          현장 배터리 교체(스케줄·기하 불변)
    6 reform    ReformTeam           기하: 교착 팀 재구성 — 위 수술의 **결과**를 봐야 한다
    8 generic   그 외                 MILP 제약 집합 + 재풀이 (`verify` 관문)
      (7 deprioritize 는 2026-08-24 Task 5 에서 kind 와 함께 삭제됐다 — 번호는 결번으로 둔다)

왜 이 순서인가: 기하 수술이 조립체 좌표를 옮기고, 그래프 수술은 **그 좌표 위에서** 인계
대상을 고른다(`nearest_pool` 이 위치를 읽는다). 반대로 하면 인계가 옛 좌표를 보고 정해진 뒤
그 아래에서 땅이 움직인다. `reform` 은 그래프 수술이 만든 교착을 고치는 것이므로 그 뒤여야
하고, 재풀이(8)는 최종 기하·그래프 위에서 한 번만 도는 게 맞다.

**결정성**: 정렬은 `alg = Base.Sort.DEFAULT_STABLE` 로 명시한 **안정 정렬**이라 동순위는
제안에 적힌 원래 순서를 지킨다. 입력은 `Vector` 이고 `Set`/`Dict` 순회가 한 군데도 없다 —
같은 제안은 언제나 같은 집행 순서를 낸다(Global Constraint: 시드 고정 = 완전 재현).

**단위 묶기**: 같은 종류의 제약은 그 분기가 **원래 벡터를 통째로 다루던 경우에만** 한 단위로
묶는다(`_enact_batched`). `ForbidZone`·`ReformTeam`·`RelocateBuild` 는 분기가 기하 전체를
한 번에 처리하고, 제네릭 경로는 **제약 집합**을 솔버에 넘긴다 — 이 셋을 쪼개면 둘째 풀이가
첫째 제약을 잃는다.
반대로 `ReplaceAgent`·`ForbidAgent`·`SwapBattery` 분기는 `first(...)` 로 **하나만** 읽으므로
단위를 낱개로 쪼개야 N 개가 N 번 집행된다(그게 이 태스크가 고치는 결함이다).

**흡수된 단위는 집계에 들어가지 않는다.** `_subsumption` 이 집행하지 않기로 한 단위는
`outcomes` 에 기여하지 않는다 — 그건 집행 **결과**가 아니라 "집행하지 않기로 한 결정"이기
때문이다. 덕분에 `[RelocateBuild(:z), ForbidZone(…, :z)]` 는 옛 코드처럼 `:admitted` 를 낸다
(잉여 단위를 `:noop` 으로 세면 `:partial` 로 새어 나간다).

**N 개의 결과 → Symbol 하나 (집계 규칙, `_aggregate_enact`)** — 우선순위대로 첫 일치:

    1. 하나라도 :fallback  → :fallback   (전역 line-stop 은 latch 된다. 가장 강한 사실)
    2. 전부      :admitted → :admitted
    3. 하나라도 :admitted  → :partial    (일부만 먹었다 — 새 값. 아래 주의)
    4. 하나라도 :rejected  → :rejected
    5. 그 외(전부 :noop)   → :noop

🔴 **N = 1 항등 정리 — 정확한 정의역** (2026-08-21 정정). 규칙 1~5 는 결과가 하나뿐일 때
언제나 그 하나를 그대로 돌려준다(특례가 아니라 정리다). 다만 그 정리가 `maybe_respecify!` 의
**반환값**으로 이어지는 정의역은 다음이다:

> **진입 시 `RESPEC_HOLD[] == false`**(= 라인이 돌고 있다)**인 경우에 한해**, 제약이 하나인
> 제안의 반환값은 순차 집행 이전과 동일하다.

라인이 이미 멈춰 있으면 LINE-STOP GATE 가 집계보다 먼저 `:fallback` 을 돌려주므로 항등이
아니다. **이 약화는 의도된 것이고 무해하다**: 멈춘 라인 위에서는 반환값이 가리킬 "집행"이라는
것이 존재하지 않으므로, 그 구간에서 옛 반환값을 재현하는 것은 재현이 아니라 **거짓말**이다.
반환값에 의미가 있는 유일한 구간이 곧 정리의 정의역이다.

정의역 안에서는 기존 호출부(`respec_step!` → `tools/demos.jl:1296` · `tools/e2e.jl` 의 두 루프 ·
`tools/tests.jl:379`)가 전부 그대로 동작한다.

⚠️ **완전한 바이트 동일은 아니다**: `invariant = build_invariant(env)` 가 producer/LLM 생성
**이전**에서 `_enact_one!` 안(생성 **이후**)으로 옮겨졌다. 기본 LLM 경로에서는 무해하지만,
`env` 를 **변경하는** `producer` 를 꽂으면 그 변경이 예전에는 invariant 에 안 잡히고 지금은
잡힌다. 지금 레포의 producer(baselines·정책)는 전부 읽기 전용이라 실측상 차이가 없다.

⚠️ `:partial` 은 **새로 생길 수 있는 값**이고 제약 2개 이상인 제안에서만 나온다.
판정 어휘의 단일 진실원은 `RESPEC_VERDICTS` 이고, 호출부는 그것을 **복제하지 말고**
`assert_respec_verdict` 를 지나가야 한다 — 어휘를 사본으로 들고 있던 두 곳
(`tools/e2e.jl` 의 `run_mock_loop`/`run_seam_loop`)이 실제로 `:partial` 을 말없이 버려
"respec 이 발동한 적 없다"로 기록하고 있었다(C1 감사, 2026-08-21). 둘 다 고쳤다.

🔴 **LINE-STOP GATE — 멈춘 라인에는 아무것도 집행하지 않는다.** 각 단위를 집행하기 **전에**
`RESPEC_HOLD[]` 를 본다. 서 있으면 그 단위와 남은 단위 전부를 `:skipped_line_stop` 으로
기록하고 `:fallback` 을 돌려준다. **latch 가 방금 걸렸든 몇 스텝 전에 걸렸든 똑같이.**

근거: line-stop 은 정의상 라인의 끝이다. 그 뒤에 집행되는 제약은 **영영 실행되지 않을 세계**를
편집하고, 그렇게 만들어진 `s` 는 일어나지 않는 전이를 가리킨다 — 이 계획의 전제(`s` 가 실제
전이를 색인한다) 자체가 깨진다. 지키는 불변식은 **현재 상태**의 성질이지 전이의 성질이 아니다.

⚠️ **왜 "전이 감지"로는 안 되는가 (2026-08-21 실측).** `RESPEC_HOLD[]` 는 **영구 latch** 이고
`release_fallback!` 만이 푸는데 **production 에서 아무도 부르지 않는다**(`respec_step!` 도
`RESPEC_ENABLED[]` 만 본다). 그래서 런 중 fallback 이 한 번 걸리면 그 뒤 **모든** 호출이 이미
멈춘 라인 위로 들어온다. 진입 전후를 비교하던 초판은 그 구간에서 **영영 발동하지 않았고**,
제약 N 개를 전부 죽은 세계에 집행했다 — first-match-wins 보다 N 배 나쁘다. 실측(시험 [6] RED):
멈춘 라인 위에서 `:admitted` 를 돌려주며 `soc 0.7→1.0`, `in_zone 66→0`.

⚠️ **의도된 동작 변화**: 한 번 latch 되면 `maybe_respecify!` 는 이후 매 호출 **즉시 `:fallback`**
이 된다(집행 0건). 정직한 보고다 — 라인이 실제로 멈춰 있다 — 지만 분명한 동작 변화다.
latch 여부는 판정 Symbol 이 아니라 `RESPEC_HOLD[]` 로 본다: 거부 분기의 다수는
`engage_fallback!` 을 부른 **뒤** `:rejected` 를 돌려주고(relocate·zone·replace·generic),
거꾸로 reform 은 latch **없이** `:rejected` 를 낸다. Symbol 로 키를 잡으면
앞은 놓치고 뒤는 거짓 발동한다.

건너뛴 단위는 `LAST_ENACT_REPORT[]` 에 `:skipped_line_stop` 으로 **명시 기록**되므로
`sum(r.n)` 불변식이 유지된다 — 조용한 건너뜀이 아니다.

🔴 **반환 Symbol 은 line-stop 여부의 신호가 아니다 — `RESPEC_HOLD[]` 가 유일한 진실원이다.**
이건 C1 이 만든 성질이 아니라 원래 그랬다: 예전에도 relocate/zone/replace/generic 의 거부
경로가 `engage_fallback!` 을 부른 **뒤** `:rejected` 를 돌려줬다. 순차 집행이 새로 여는 것은
`:partial`(= 한 단위는 먹었고 다른 단위는 거부되며 line-stop 을 걸었을 수 있다) 이라는 조합
이다 — 실측 예: `[RelocateBuild(:ghost), SwapBattery(r)]` → 보고서 `[(:relocate,:rejected),
(:battery,:admitted)]` → 반환 `:partial`, 그리고 `RESPEC_HOLD[] == true`
(test/respec_sequential_enact.jl [4]). line-stop 을 보려면 `RESPEC_HOLD[]` 를 읽어라.
first-match-wins 시절엔 분기가 하나만 돌아서 이 조합이 생길 수 없었다. 분기 본문을 안 고치는
것이 이 태스크의 제약이므로 그 동작 자체는 그대로 두었다.

집행 흔적은 두 전역에 남는다 — `ENACT_ORDER_LOG[]`(진입한 분기의 순서) 와
`LAST_ENACT_REPORT[]`(단위별 `(kind, status, n)`). 후자의 `sum(r.n)` 이 제안의 제약 개수와
같다는 것이 **조용히 버려진 제약이 없다는 기계적 증거**다(Global Constraint: 조용한 폴백 금지).
"""
# `;` 뒤 두 인자는 키워드 인자이며 "= 기본값"이 붙어 있어 생략 가능.
# `ref -> _default_id_resolver(env, ref)` : `->` 는 익명함수(파이썬 람다 `lambda ref: ...`). 즉 기본 id 변환 함수.
# optimizer 기본값은 _respec_optimizer() 호출 결과(쓸 최적화 솔버).
# Classify an OOD event's safety criticality, used ONLY when we cannot obtain a
# typed proposal (LLM network / parse failure). SOFT/advisory events — a battery
# degradation (the old soft-bias class) and the SPECULATIVE "team deadlocked"
# reform alarm — are feasibility-preserving: the pre-event plan was feasible and
# ignoring them changes nothing, so on failure we NO-OP and keep building. HARD
# events (no-go zone, robot breakdown) can make blindly continuing unsafe, so a
# failure there keeps the conservative line-stop. Unknown => HARD (fail safe).
# THE POINT: a transient network hiccup on a soft advisory must never freeze the
# whole build — the soft layer's failure mode is "ignore", not "halt".
# [한국어] 타입 있는 제안을 못 얻었을 때(LLM 실패 등)만 쓰는 안전도 분류기. 이벤트 문자열의 낱말로
#   :soft(무시해도 안전 — 배터리 저하/팀 교착 알람)와 :hard(맹목 진행이 위험 — no-go 구역/로봇 고장)를 가름.
#   모르면 :hard(안전 우선). 핵심: soft 이벤트의 일시적 네트워크 딸꾹질이 빌드 전체를 얼리면 안 됨 → 실패=무시.
function _event_criticality(event::AbstractString)
    e = lowercase(event)                         # 낱말 매칭을 위해 소문자화. occursin(부분, 전체)=포함 여부.
    if occursin("zone", e) || occursin("exclusion", e) || occursin("no-go", e) ||
       occursin("broken", e) || occursin("immobile", e) || occursin("cannot move", e) ||
       occursin("faulted", e) || occursin("broke down", e) || occursin("break down", e)
        return :hard                             # 구역/고장 관련 낱말 → 안전상 hard
    end
    if occursin("battery", e) || occursin("charge", e) || occursin("degraded", e) ||
       occursin("deadlock", e) || occursin("transport team", e) ||
       occursin("re-establish", e) || occursin("stuck", e)
        return :soft                             # 배터리/교착 관련 낱말 → 무시해도 안전한 soft
    end
    return :hard                                 # 어디에도 안 걸리면 fail-safe 로 hard
end

# No spare available for a broken robot: instead of freezing the WHOLE build (which
# strands the other healthy robots' independent work), re-solve the faulted robot's
# remaining tasks onto the OTHER active robots — the same general reassign the
# ForbidAgent fault path uses. Feasibility is MILP-verified; we line-stop ONLY if that
# reassign genuinely fails. So a ReplaceAgent with no spare gracefully degrades to a
# ForbidAgent-style redistribution rather than a global halt.
# 예비가 없을 때의 우아한 강등: 빌드 전체를 얼리는 대신, 고장 로봇의 남은 일을 다른 활성 로봇들에게
# 재분배(MILP 검증)한다. 그 재분배마저 진짜 실패할 때만 line-stop.
function _replace_via_reassign!(env, faulted, optimizer, why)
    @info "[RESPEC] no spare for $(faulted) ($why) -> general reassign (re-solve remaining work onto active robots)"
    # fault_robot_and_reassign! : 고정→대기엣지 해제→ForbidAgent→검증→커밋. resume=true 로 진행상태 유지.
    res = fault_robot_and_reassign!(env, faulted; optimizer = optimizer, resume = true)
    if res.status == :admitted                    # 재분배가 채택되면
        @info "[RESPEC] ADMITTED replace-via-reassign: $(faulted)'s remaining work redistributed to active robots."
        return :admitted
    end
    # 재분배가 실패하면(진짜 실행 불가) 경고 후 안전 폴백(line stop).
    @warn "[RESPEC] general reassign $(res.status) -> fallback (line stop)" detail = get(res, :detail, "")
    engage_fallback!(env)
    return :fallback
end

# =============================================================================
# 순차 집행 (Task C1, 2026-08-21) — 제약 벡터의 **모든** 원소를 집행한다.
# 규칙 전문은 아래 `maybe_respecify!` 의 docstring 에 있다.
# =============================================================================

"""
`maybe_respecify!` / `respec_step!` 가 돌려줄 수 있는 Symbol **전부**. 판정 어휘의 단일 진실원.

    :disabled  RESPEC_ENABLED[] 가 꺼져 있다 (`respec_step!` 만 낸다)
    :noop      처리할 이벤트가 없거나, 빈 제안(절제)이거나, 집행 결과가 전부 no-op
    :admitted  모든 집행 단위가 채택됐다
    :partial   일부 단위만 채택됐다 (제약 2개 이상일 때만 나온다 — C1 에서 새로 생겼다)
    :rejected  채택된 단위가 하나도 없고 거부가 있었다
    :fallback  line-stop 에 걸렸다(집행 중 latch 되면 남은 단위는 집행하지 않는다)

🔴 **호출부가 이 어휘를 화이트리스트로 복제하면 안 된다.** `:partial` 이 그렇게 해서 생긴
사고의 실례다 — `tools/e2e.jl` 의 두 화이트리스트가 `:partial` 을 **말없이 버려**
"respec 이 발동한 적 없다"로 기록했다(C1 감사, 2026-08-21). 새 값을 더할 때는 여기만 고치고,
호출부는 `assert_respec_verdict` 를 지나가게 한다.
"""
const RESPEC_VERDICTS = (:disabled, :noop, :admitted, :partial, :rejected, :fallback)

"""
    assert_respec_verdict(verdict, where = "") -> Symbol

`verdict` 가 `RESPEC_VERDICTS` 에 있으면 그대로 돌려주고, 없으면 `error()` 한다.
Global Constraint **조용한 폴백 금지**의 집행 지점: 호출부의 분기표가 모르는 Symbol 을
말없이 "아무 일도 없었다" 로 뭉개는 것을 구조적으로 막는다. 비용은 튜플 멤버십 하나다.
"""
function assert_respec_verdict(verdict::Symbol, where::AbstractString = "")
    verdict in RESPEC_VERDICTS && return verdict
    error("[RESPEC] 알 수 없는 판정 :$(verdict)" * (isempty(where) ? "" : " @ $(where)") *
          " — 어휘는 $(RESPEC_VERDICTS) 다. maybe_respecify! 가 새 값을 내기 시작했다면 " *
          "RESPEC_VERDICTS 와 이 판정을 소비하는 모든 분기표를 함께 고쳐야 한다 " *
          "(조용히 버리면 부분 집행이 no-op 으로 기록된다).")
end

"""
직전 `maybe_respecify!` 호출에서 **실제로 진입한** dispatch 분기의 종류가 진입 순서대로.
호출마다 비워진다. 분류기(`_enact_kind`)가 아니라 **분기 본체가 직접** 찍는다 — 분류기와
술어(`_is_*`)가 어긋나면 시험이 그 자리에서 빨개지도록(가정이 아니라 측정).
"""
const ENACT_ORDER_LOG = Ref(Symbol[])

"""
직전 `maybe_respecify!` 호출의 **집행 단위별** 결과. 행 하나 = 집행 단위 하나:

    (kind::Symbol, status::Symbol, n::Int)

- `kind`   — `_enact_kind` 가 붙인 종류.
- `status` — 그 분기가 **원래 돌려주던 그대로의** Symbol(`:admitted·:rejected·:noop·:fallback`).
             분기 본문의 로직을 안 바꿨으므로 어휘도 그대로다.
- `n`      — 그 단위가 실어 나른 제약 개수. `sum(r.n for r in LAST_ENACT_REPORT[])` 는 언제나
             제안의 제약 개수와 같다 = **조용히 버려진 제약이 없다는 기계적 증거**.
"""
const LAST_ENACT_REPORT = Ref(NamedTuple[])

"""
    _enact_kind(c::ConstraintSpec) -> Symbol

제약 하나를 **어느 dispatch 분기가 집행하는가**로 분류한다. `maybe_respecify!` 안의
`_is_*(proposal)` 술어들과 1:1 로 대응한다(단위가 낱개일 때 `any(c -> c isa T, [c])` 는
`c isa T` 와 같으므로 정확히 일치한다). 어디에도 안 걸리면 `:generic` — 제네릭 MILP 관문
(`verify` + `formulate_milp` + `commit_respec!`)이 받는다. 거기서도 못 다루는 타입이면
`compile_constraint!` 가 `MethodError` 로 죽는다. **조용히 건너뛰는 경로는 없다.**

✅ Task C3 이 `TranslateBuild` 를 들여왔다. C1 의 이 자리 메모는 그것을 `:relocate` 로
분류하라고 적었지만 **그대로 하지 않았다**: `_enact_one!` 의 분기 본체가 스스로 찍는 Symbol 과
분류기가 어긋나면 `ENACT_ORDER_LOG[]`(분기 본체가 찍는다)와 `LAST_ENACT_REPORT[].kind`
(분류기가 찍는다)가 **같은 단위에 서로 다른 이름을 붙인다** — 이 두 전역의 존재 이유가 바로
"분류기와 술어가 어긋나면 시험이 그 자리에서 빨개지게" 하는 것이다. 그리고 둘은 실제로 다른
분기다(`verify_relocate` 대 Δ 검사, solver 대 원시연산). 그래서 `:translate` 로 **별도 종류**를
준다. 여전히 어디에도 안 걸리는 타입은 `:generic` 으로 떨어져 `compile_constraint!` 의
`MethodError` 로 죽는다 — 조용히 무시되는 경로는 없다.
"""
_enact_kind(c::ConstraintSpec) =
    c isa RelocateBuild     ? :relocate     :
    c isa TranslateBuild    ? :translate    :
    c isa ForbidZone        ? :zone         :
    c isa ReplaceAgent      ? :replace      :
    c isa ForbidAgent       ? :fault        :
    c isa SwapBattery       ? :battery      :
    c isa ReformTeam        ? :reform       :
                              :generic

# 집행 순서. 근거는 `maybe_respecify!` docstring 의 "집행 순서 규칙" 절.
# 기하(1·2) → 그래프(3·4) → 현장수리(5) → 교착복구(6) → 재풀이(7·8).
# `translate` 는 `relocate` 와 **같은 순위 1** 이다(둘 다 기하를 먼저 확정한다). 동순위는
# `_enact_units` 의 `alg = Base.Sort.DEFAULT_STABLE` 이 제안에 적힌 원래 순서로 고정하므로
# 결정적이다(Global Constraint: 시드 고정 = 완전 재현).
const _ENACT_RANK = (relocate = 1, translate = 1, zone = 2, replace = 3, fault = 4,
                     battery = 5, reform = 6, generic = 8)

_enact_rank(c::ConstraintSpec) = getfield(_ENACT_RANK, _enact_kind(c))


"""
    _enact_batched(kind) -> Bool

이 종류의 분기가 제약 **벡터를 통째로** 다루는가. `true` 면 같은 종류를 한 단위로 묶는다.

🔴 **왜 제네릭 경로를 묶는가 (계획서 스니펫에서 벗어난 결정 — 컨트롤러 승인 2026-08-21).**
브리프는 제약을 예외 없이 낱개로 쪼개라고 했다. 제네릭 경로에 그렇게 하면 **이 태스크가
고치는 바로 그 결함을 한 층 아래에서 다시 만든다**: 제네릭 관문은 MILP **제약 집합**을
`extra_constraints = verdict.proposal` 로 솔버에 통째로 넘긴다. `[ForbidWindow(a), ForbidWindow(b)]`
를 두 번의 풀이로 쪼개면 둘째 풀이의 모델에 첫째 제약이 **없다** — 즉 `a` 가 조용히 버려진다.
"제약 벡터가 하나로 무너진다"가 dispatch 층에서 솔버 층으로 옮겨갈 뿐이다. 그래서 묶는다.
`ForbidZone`/`RelocateBuild`/`ReformTeam` 분기는 기하 전체를
한 번에 처리한다(`restage_all_blocked!`·`translate_whole_build!`·`reform_stuck_teams!` 는
제약이 아니라 `env` 를 읽는다).

`false` 인 셋(`:replace`·`:fault`·`:battery`)의 분기 본문은 `first(c for c in ... if c isa T)`
로 **첫 하나만** 읽는다 — 그래서 낱개로 쪼개야 N 개가 N 번 집행된다. 이것이 이 태스크가
고치는 결함의 종류 내부 버전이다.
"""
# 🔴 `:translate` 는 **묶지 않는다.** 분기 본체가 Δ 하나를 읽으므로 묶으면 N 개 중 1 개만
# 집행되고 나머지가 조용히 사라진다 — C1 이 고친 결함의 종류 내부 버전이다. 낱개로 쪼개면
# N 개가 N 번 집행되고, `_apply_uniform_translation!` 의 문서화된 성질(이동은 합성된다)에 따라
# 순 이동이 ΣΔᵢ 가 된다.
_enact_batched(kind::Symbol) = kind in (:relocate, :zone, :reform, :generic)

"""
    _enact_units(constraints) -> Vector{Vector{ConstraintSpec}}

제약 벡터를 **집행 순서대로 늘어놓은 집행 단위들**로 쪼갠다.

정렬은 `alg = Base.Sort.DEFAULT_STABLE` 로 **명시**한다: 동순위(같은 종류)는 제안에 적힌
원래 순서를 지키고, 기본 알고리즘이 바뀌어도 순서가 안 흔들린다. 입력은 `Vector` 이고
`Set`/`Dict` 순회가 한 군데도 없으므로 같은 제안은 언제나 같은 단위열을 낸다
(Global Constraint: 시드 고정 = 완전 재현).
"""
function _enact_units(constraints::AbstractVector{<:ConstraintSpec})
    ordered = sort(collect(ConstraintSpec, constraints);
                   by = _enact_rank, alg = Base.Sort.DEFAULT_STABLE)
    units = Vector{ConstraintSpec}[]
    for c in ordered
        k = _enact_kind(c)
        # 정렬이 같은 종류를 이미 붙여 놓았으므로 직전 단위만 보면 된다.
        if _enact_batched(k) && !isempty(units) && _enact_kind(units[end][1]) === k
            push!(units[end], c)
        else
            push!(units, ConstraintSpec[c])
        end
    end
    return units
end

"""
    _subsumption(unit, all_constraints) -> Union{Nothing,Symbol}

이 집행 단위가 **다른 제약에 의해 이미 처리되므로 집행하지 않아야 하는가**. 집행하지 않으면
그 사유 Symbol 을, 정상 집행이면 `nothing` 을 낸다.

🔴 **왜 이게 필요한가 — 우선순위와 배타성은 다르다.** dispatch 사슬의 두 자리는 단순한 검사
순서가 아니라 **실측으로 정해진 도메인 규칙**이었고, 순차 집행 초판은 우선순위만 지키고
배타성을 없애 버렸다:

1. `RelocateBuild(:z)` + `ForbidZone(…, :z)` — `_is_relocate_build` docstring 의 2026-08-03 실측:
   조립체별 재적치(`restage_all_blocked!`)는 "아직 시작 안 한 조립체"만 옮길 수 있고 그 집합은
   첫 배치 경계에서 비어 다시 안 찬다. 그래서 둘 다 실린 제안은 **강한 지렛대 하나만** 쓴다.
   둘 다 집행하면 이미 비워진 구역에 재적치를 한 번 더 돌리는데, 그게
   `:partial`/`:infeasible`/`:residual_blocked` 를 내면 `engage_fallback!` 로 간다 —
   **성공적으로 옮긴 빌드가 잉여 둘째 단위 때문에 영구 line-stop 된다.** 옛 코드에는 없던
   실패 경로다.
2. (삭제됨) `DeprioritizeAgent` + 하드 스펙 — 그 kind 가 2026-08-24 Task 5 에서 DSL 에서
   사라지면서 `:subsumed_by_hard_spec` 사유도 함께 지웠다. 남은 흡수 사유는 1 하나뿐이다.

**흡수는 조용한 드롭이 아니다.** C1 의 명령은 "어떤 제약도 **조용히** 버려지지 않는다" 이지
"모든 제약이 반드시 무언가를 집행한다" 가 아니다. 흡수된 단위는 `LAST_ENACT_REPORT[]` 에
사유가 적힌 행으로 남고 `sum(r.n) == length(proposal.constraints)` 불변식도 유지된다 —
감사 가능한 명명된 결과다. 잉여 단위를 집행하는 쪽은 옛 동작보다도, 목표보다도 **엄격히 나쁘다.**

사유:
- `:subsumed_by_relocate`  — 단위의 **모든** `ForbidZone` 이 같은 제안의 어떤 `RelocateBuild` 와
  **같은 zone** 을 가리킨다. 일부만 겹치면 흡수하지 않는다(나머지 구역은 진짜 할 일이 있다).

🔴 **`TranslateBuild`(Task C3)는 여기에 들어오지 않는다 — 흡수하지도, 흡수되지도 않는다.**
근거는 `_is_translate_build` 의 docstring 에 적었다. 요약: 흡수는 "다른 제약이 이 단위의 일을
이미 했다" 는 **증거**를 요구하는데, `TranslateBuild(dx, dy)` 는 zone 을 지목하지 않으므로
어떤 구역을 비웠다는 증거를 들고 있지 않다. 그것으로 `ForbidZone` 을 흡수하면 구역을 비울
유일한 단위를 조용히 버리게 된다. 반대로 `RelocateBuild` 는 집행 시점의 라이브 기하에서 Δ 를
다시 풀므로 앞선 `TranslateBuild` 를 이미 반영한 잔여 이동만 낸다(이중 계산이 아니다).

🔴 **도달가능성 — 이 판단이 안전한 이유는 오늘의 우연이다 (fix round 1, 컨트롤러 minor 3).**
위는 **건전성** 논증이다(흡수하면 틀린다). 그와 별개로, 흡수하지 **않아서** 생길 수 있는 해
(`TranslateBuild` 가 구역을 비운 뒤 `ForbidZone` 단위가 한 번 더 돌아 `engage_fallback!` 로 가
성공한 이동을 영구 line-stop 시키는 것 — `:subsumed_by_relocate` 가 존재하는 바로 그 이유)는
**오늘 도달 불가능할 뿐이다**: (a) `ForbidZone` 이 D-9 로 emit 표면에서 빠져 LLM 이 둘을 한
제안에 실을 수 없고, (b) 둘을 섞어 만드는 내부 생산자가 하나도 없다(`baselines.jl:173·192·201` ·
`reassign.jl:382` · `ood_mdp_shim.jl:306` 확인). ⚠️ **둘 중 하나가 바뀌는 날 이 경로가 다시 열리고,
그것을 지키는 시험은 없다.** `ForbidZone` 을 emit 표면에 되돌리거나 혼합 생산자를 만드는 태스크는
여기부터 다시 읽을 것.

정렬된 `Vector` 로만 판정한다 — `Set`/`Dict` 순회 없음(Global Constraint).
"""
function _subsumption(unit::AbstractVector{<:ConstraintSpec},
                      all_constraints::AbstractVector{<:ConstraintSpec})
    kind = _enact_kind(first(unit))
    if kind === :zone
        rb_zones = sort!(unique(Symbol[c.zone for c in all_constraints if c isa RelocateBuild]);
                         by = string)
        isempty(rb_zones) && return nothing
        all(c -> c isa ForbidZone && c.zone in rb_zones, unit) && return :subsumed_by_relocate
    end
    return nothing
end

"""
    _aggregate_enact(outcomes) -> Symbol

집행 단위별 결과 N 개를 반환용 Symbol 하나로 접는다. 우선순위대로 첫 일치:

    1. 하나라도 :fallback  → :fallback   (전역 line-stop 은 latch 된다 — 가장 강한 사실)
    2. 전부      :admitted → :admitted
    3. 하나라도 :admitted  → :partial    (일부만 먹었다)
    4. 하나라도 :rejected  → :rejected
    5. 그 외(전부 :noop)   → :noop

🔴 **N = 1 에서 항등**이다 — 특례가 아니라 정리다. 결과가 s 하나뿐일 때 위 다섯을 순서대로
따라가면 언제나 s 가 나온다(:admitted 는 2, :fallback 은 1, :rejected 는 4, :noop 는 5).
그래서 제약 하나짜리 제안의 반환값 계약이 순차 집행 전과 **바이트 동일**하고, 기존 호출부가
전부 그대로 동작한다. 새로 나올 수 있는 값은 `:partial` 하나뿐이고 제약 2개 이상일 때만이다.
"""
function _aggregate_enact(outcomes::AbstractVector{Symbol})
    isempty(outcomes)                   && return :noop
    any(s -> s === :fallback, outcomes) && return :fallback
    all(s -> s === :admitted, outcomes) && return :admitted
    any(s -> s === :admitted, outcomes) && return :partial
    any(s -> s === :rejected, outcomes) && return :rejected
    return :noop
end


# respec 파이프라인 본체: 큐에서 OOD 이벤트 하나를 꺼내 생성→검증→(종류별 특수)대응→재풀이→재개까지 처리.
# 반환값(:noop/:admitted/:rejected/:fallback)은 로깅용이며, :admitted 시 세계 상태를 실제로 바꿈.
function maybe_respecify!(env, ood_queue;
                          id_resolver = ref -> _default_id_resolver(env, ref),  # 기본 id 변환기(익명함수)
                          optimizer   = _respec_optimizer(),                    # 쓸 최적화 솔버
                          producer    = nothing)                                # 제안 생성기(없으면 LLM 경로)
    event = poll_ood!(ood_queue)                  # 큐에서 이벤트 하나 꺼냄(없으면 nothing)
    event === nothing && return :noop             # 처리할 이벤트가 없으면 아무것도 안 함(:noop) 반환

    @info "[RESPEC] OOD event: $event"            # @info : 정보 로그 출력 매크로. $event 로 값 보간.

    # --- generate: OOD event -> typed DSL proposal -----------------------------
    # The PRODUCER is pluggable (the comparison seam, see RESPEC_PRODUCER). Default is
    # the LLM path (`llm_to_proposal`) with transient-failure retry; a supplied
    # `producer` (MARL policy / baseline) is asked directly. EITHER way the resulting
    # proposal flows through the SAME verify/dispatch/re-solve below.
    local proposal                               # local : 이 이름을 함수 스코프 변수로 선언(if/else 두 갈래 모두에서 씀)
    if producer === nothing                       # producer 안 꽂혔으면 → 기본 LLM 경로
        # llm_to_proposal can throw on a TRANSIENT network hiccup (HTTP.RequestError:
        # POST /propose dropped) — not just on a bad LLM answer. Retry a few times; on
        # FINAL failure route by criticality (soft advisory -> no-op so a network blip
        # can never freeze the build; only a critical event keeps the line-stop).
        # [한국어] LLM 호출은 일시적 네트워크 오류로도 예외를 던질 수 있음 → 최대 3회 재시도.
        #          끝내 실패하면 안전도로 분기(soft=무시 no-op, hard=line-stop).
        proposal = nothing
        gen_err  = nothing                        # 마지막으로 잡힌 예외(성공 시 nothing 으로 리셋)
        for attempt in 1:3                        # 최대 3번 시도
            try
                proposal = llm_to_proposal(event, env; id_resolver = id_resolver)  # NL→타입 있는 DSL 제안
                gen_err = nothing
                break                             # 성공하면 루프 탈출
            catch err
                gen_err = err
                if attempt < 3
                    @warn "[RESPEC] llm_to_proposal attempt $attempt/3 failed; retrying" exception = err
                    sleep(0.4)                    # 잠깐 쉬고 재시도
                end
            end
        end
        if gen_err !== nothing                    # 3번 다 실패했으면
            if _event_criticality(event) === :soft
                @warn "[RESPEC] LLM/parse failure on a SOFT advisory event after 3 tries -> IGNORED (no-op, build continues)" exception = gen_err
                return :noop                     # soft layer fails to IGNORE, never to a global halt  # soft 는 무시하고 계속
            end
            @warn "[RESPEC] LLM/parse failure on a CRITICAL event after 3 tries -> fallback (line stop)" exception = gen_err
            engage_fallback!(env)                # only a safety-critical event line-stops  # hard 만 line-stop
            return :fallback
        end
    else                                          # producer 가 꽂혀 있으면 → MARL/baseline 경로
        # Pluggable producer (MARL / baseline). It returns a RespecProposal or nothing.
        # DISTINGUISH two "nothing"s:
        #   * producer THREW  -> a real failure; route by criticality like an LLM failure
        #     (soft advisory -> ignore; critical -> safe line-stop). Safety preserved.
        #   * producer returned `nothing` -> a DELIBERATE no-op (the policy chose NOOP, or a
        #     baseline like B0 never acts). This is the analog of the LLM emitting an empty
        #     proposal: no planning-level action, the build CONTINUES on the motion stack.
        #     Treating a deliberate NOOP as a fallback would (a) mis-punish the learned policy
        #     during exploration and (b) break the LLM-vs-MARL symmetry.
        proposal = nothing
        producer_failed = false                   # producer 가 "던졌는지(진짜 실패)" 표시 플래그
        try
            proposal = producer(env, event)       # 정책/베이스라인에게 직접 제안을 물어봄
        catch err
            @warn "[RESPEC] custom producer threw; routing by event criticality" exception = err
            producer_failed = true                # 예외=진짜 실패 → 안전도로 분기
        end
        if producer_failed
            _event_criticality(event) === :soft && return :noop  # soft 면 무시
            engage_fallback!(env)                 # hard 면 안전 line-stop
            return :fallback
        end
        proposal === nothing && return :noop      # deliberate no-op -> build continues  # nothing=의도적 NOOP(정책이 선택) → 계속 진행
    end
    # LLM 이 자연어를 무슨 DSL 로 번역했는지 명시 로깅(실 LLM·mock 공통으로 NL→DSL 이 한눈에 보이게).
    # join(...) : 컬렉션을 구분자로 이어붙임. typeof(c).name.name = 제약의 타입 이름(예: ForbidZone).
    @info "[RESPEC] LLM proposal: [$(join([string(typeof(c).name.name) for c in proposal.constraints], ", "))]" *
          (isempty(proposal.rationale) ? "" : "  rationale: $(proposal.rationale)")

    # --- empty proposal = RESTRAINT, and it must be sayable ---------------------
    # An LLM that judges the event absorbable (a zone that blocks no goal, a degradation
    # with enough slack) has exactly one way to say so in this grammar: `constraints: []`.
    # Without this guard that fell through every `_is_*` dispatch into the generic MILP
    # path and paid a full re-solve to add ZERO constraints — i.e. the cheapest correct
    # answer was the most expensive one to execute, and it was recorded as a re-solve
    # rather than as restraint. Treat it like `proposal === nothing` above.
    # [한국어] 빈 제안 = "개입하지 않는다"(절제). 이 문법에서 LLM 이 절제를 표현할 수 있는 유일한 방법이다.
    #   가드가 없으면 모든 dispatch 를 그냥 통과해 제네릭 MILP 경로로 떨어져서, 제약 0개를 추가하려고
    #   전체 재풀이 비용을 낸다(가장 싼 정답이 가장 비싸게 실행되고, 기록도 "재풀이"로 남는다).
    if isempty(proposal.constraints)
        @info "[RESPEC] empty proposal = deliberate restraint (no constraint) -> noop"
        return :noop
    end

    # --- 순차 집행 (Task C1) ----------------------------------------------------
    # 🔴 여기가 이 태스크가 바꾼 **유일한 제어 흐름**이다. 예전엔 아래 `_enact_one!` 의 본문이
    #    이 자리에 통째로 있었고, 일곱 분기가 각각 `return` 해서 첫 일치 하나만 집행됐다.
    #    지금은 제약을 집행 단위로 쪼개(`_enact_units`) 같은 `env` 위에서 **차례로** 집행한다.
    #    각 단위는 `_enact_one!` 안에서 자기 `verify_*` 를 라이브 `env` 로 다시 통과해야 하므로,
    #    앞 단위가 전제조건을 무효화했으면 **거기서 걸러지고 그 사실이 보고서에 남는다.**
    ENACT_ORDER_LOG[]   = Symbol[]
    LAST_ENACT_REPORT[] = NamedTuple[]
    outcomes = Symbol[]
    units           = _enact_units(proposal.constraints)
    short_circuited = false
    for (i, unit) in enumerate(units)
        # --- line-stop gate (Ruling 1, 정정판) ----------------------------------
        # 🔴 **상태를 본다. 전이가 아니다.** `engage_fallback!` 은 `RESPEC_HOLD[]` 를 latch 하고
        #    `release_fallback!`(이 파일 하단) 만이 푸는데 **production 에서 아무도 안 부른다**
        #    (`respec_step!` 도 `RESPEC_ENABLED[]` 만 본다). 그래서 런 중 fallback 이 한 번이라도
        #    걸리면 그 뒤 **모든** 호출이 "이미 멈춘 라인" 위로 들어온다. 초판은 latch 의 **순간**만
        #    감지해서(hold_before 비교) 그 구간에서 영영 발동하지 않았고, N 개 제약을 전부 죽은
        #    세계에 집행했다 — first-match-wins 보다 N 배 나쁘다(실측: 시험 [6] 의 RED 는
        #    `:admitted` 를 돌려주면서 soc 0.7→1.0, in_zone 66→0 을 만들었다. 멈춘 라인 위에서).
        #    지금 지키는 불변식은 하나다: **멈춘 라인에는 어떤 제약도 집행하지 않는다.**
        #    latch 여부는 판정 Symbol 이 아니라 `RESPEC_HOLD[]` 로 본다 — 거부 분기의 다수가
        #    `engage_fallback!` 을 부른 **뒤** `:rejected` 를 돌려주고(relocate/zone/replace/generic),
        #    거꾸로 reform(`:1207`)은 latch 없이 `:rejected` 를 낸다.
        #    Symbol 로 키를 잡으면 앞은 놓치고 뒤는 거짓 발동한다.
        if RESPEC_HOLD[]
            # 건너뛴 단위도 **명시적 status 로 보고**한다 — 조용한 건너뜀이면 이 태스크가 고친
            # 결함이 그대로 되살아난다. `sum(r.n)` 불변식도 그대로 유지된다.
            for skipped in units[i:end]
                push!(LAST_ENACT_REPORT[],
                      (kind = _enact_kind(skipped[1]), status = :skipped_line_stop,
                       n = length(skipped)))
            end
            short_circuited = true
            @warn "[RESPEC] line is STOPPED (RESPEC_HOLD) -> " *
                  "$(length(units) - i + 1) unit(s) NOT enacted " *
                  "(a stopped line never executes them; see LAST_ENACT_REPORT[])"
            break
        end
        # --- 흡수(subsumption): 집행하지 않되 **기록한다** (Ruling 2) --------------
        sub = _subsumption(unit, proposal.constraints)
        if sub !== nothing
            push!(LAST_ENACT_REPORT[], (kind = _enact_kind(unit[1]), status = sub,
                                        n = length(unit)))
            @info "[RESPEC] unit $(_enact_kind(unit[1])) subsumed ($(sub)) -> not enacted (recorded)"
            continue        # outcomes 에는 안 넣는다 — 집행 결과가 아니라 "집행하지 않기로 한 결정"
        end
        one = RespecProposal(unit, proposal.rationale, proposal.source_event)
        st  = _enact_one!(env, one; id_resolver = id_resolver, optimizer = optimizer)
        push!(LAST_ENACT_REPORT[],
              (kind = _enact_kind(unit[1]), status = st, n = length(unit)))
        push!(outcomes, st)
    end
    @info "[RESPEC] enacted $(length(outcomes)) unit(s) over " *
          "$(length(proposal.constraints)) constraint(s) -> " *
          string([(r.kind, r.status) for r in LAST_ENACT_REPORT[]])
    # 라인이 멈춰 있어서 집행을 건너뛰었다면 반환은 `:fallback` 이다(집계보다 우선).
    # 라인이 도는 동안에는 이 분기가 도달 불가능하므로 아래 집계의 N=1 항등은 그 정의역에서
    # 그대로 성립한다(정확한 정의역 서술은 이 함수 docstring 의 "N = 1 항등" 절 참조).
    short_circuited && return :fallback
    return _aggregate_enact(outcomes)
end

"""
    _enact_one!(env, proposal; id_resolver, optimizer) -> Symbol

**하나의 집행 단위**(같은 종류의 제약 1개 이상)를 집행한다. 본문은 순차 집행 이전
`maybe_respecify!` 의 dispatch 꼬리를 **그대로** 옮긴 것이다 — 술어(`_is_*`)도, 분기 본문의
로직도, 반환 어휘(`:admitted·:rejected·:noop·:fallback`)도 바꾸지 않았다. 더한 것은 분기마다
한 줄씩의 `push!(ENACT_ORDER_LOG[], …)` 뿐이다.

분기 표(파일 안 등장 순서 = 검사 순서):

    _is_robot_fault     ForbidAgent          → fault_robot_and_reassign!
    _is_relocate_build  RelocateBuild        → translate_whole_build!   (Δ 를 solver 가 찾는다)
    _is_translate_build TranslateBuild       → _apply_uniform_translation!(env, Δ)  (Δ 를 제안자가 준다)
    _is_zone_respec     ForbidZone           → restage_all_blocked! (+ Phase B 전체이동)
    _is_battery_swap    SwapBattery          → swap_battery!
    _is_robot_replace   ReplaceAgent         → hot_swap_robot! / replace_robot(_distributed)!
    _is_reform          ReformTeam           → reform_stuck_teams! / recover_stalled_teams!
    (fall-through)      그 외                 → verify + formulate_milp + commit_respec!

⚠️ 검사 **순서**는 예전 그대로 두었지만, 단위가 한 종류뿐이라 이제 순서가 결과를 가르지
않는다. 집행 순서를 정하는 것은 `_enact_units`(= `_enact_rank`)다.
"""

function _enact_one!(env, proposal::RespecProposal;
                     id_resolver = ref -> _default_id_resolver(env, ref),
                     optimizer   = _respec_optimizer())
    # 🔴 **집행 단위마다 얼린 과거를 다시 만든다.** 앞 단위의 집행이 스케줄을 바꿨을 수 있으므로,
    #    호출 진입 때 한 번 만든 invariant 를 재사용하면 둘째 단위가 **낡은 과거** 위에서 검증된다.
    #    (순차 집행 전에는 `maybe_respecify!` 가 LLM 호출 직전에 한 번만 만들었다.)
    invariant = build_invariant(env)


    # --- robot fault: dispatch to the reassign machinery ----------------------
    # A ForbidAgent re-spec needs schedule surgery (release pending edges) + the
    # frozen/pinned context that the generic verify path does not establish.
    # fault_robot_and_reassign! does freeze -> release -> ForbidAgent -> verify ->
    # commit, and rejects to the safe fallback if the future is not re-solvable.
    if _is_robot_fault(proposal)                 # 제안이 "로봇 한 대 고장(ForbidAgent 1개)"인 경우
        push!(ENACT_ORDER_LOG[], :fault)   # C1: 실제로 진입한 분기를 진입 순서대로 기록
        agent = proposal.constraints[1].agent    # 그 제약에서 고장난 로봇 id 를 꺼냄(.agent 필드)
        @info "[RESPEC] robot-fault re-spec -> reassign $(agent)"  # 어떤 로봇을 재배정하는지 로그
        # fault_robot_and_reassign! : 고정→대기엣지 해제→ForbidAgent→검증→커밋 까지 수행. resume=true 면 진행 상태 유지.
        res = fault_robot_and_reassign!(env, agent; optimizer = optimizer, resume = true)
        if res.status != :admitted               # `!=` : 같지 않음. 결과 상태가 ":admitted(채택)"이 아니면(=재배정 실패)
            # get(res, :detail, "") : res 에 :detail 필드가 있으면 그 값, 없으면 빈 문자열(기본값).
            @warn "[RESPEC] reassign $(res.status) -> fallback" detail = get(res, :detail, "")
            engage_fallback!(env)                # 안전 폴백 작동
        end
        return res.status                        # 재배정 결과 상태를 그대로 반환(:admitted / :rejected 등)
    end

    # --- restriction zone (WHOLE-BUILD): dispatch straight to the rigid translation --
    # A RelocateBuild skips the per-assembly restage entirely and shifts the WHOLE build by
    # one Δ. It exists because the per-assembly path (`ForbidZone` -> restage_all_blocked!)
    # has an EMPTY DOMAIN for most of a run: `restage_assembly!` refuses any assembly whose
    # build steps have started, and the un-started set drains to zero at the first batch
    # boundary (closed≈46 on the tractor twin) and never refills. Measured 2026-08-03
    # (oracle/out/zdiag*): every zone event fired after that point made the ForbidZone arm
    # byte-identical to NOOP. `translate_whole_build!` reads `_future_work_discs`, which is
    # gated on `closed_set` only — no `_assembly_started` precondition — so it stays live.
    # Checked BEFORE the ForbidZone branch: a mixed proposal takes the stronger lever.
    # [한국어] RelocateBuild = 조립체별 재적치를 건너뛰고 빌드 전체를 Δ 하나로 옮긴다. 조립체별 경로는
    #   "아직 시작 안 한 조립체"만 옮길 수 있는데 그 집합이 첫 배치 경계에서 비어 영영 안 돌아온다(실측).
    #   전체 이동은 그 전제조건이 없으므로 빌드 내내 유효하다. ForbidZone 분기보다 먼저 검사한다.
    if _is_relocate_build(proposal)
        push!(ENACT_ORDER_LOG[], :relocate)   # C1: 실제로 진입한 분기를 진입 순서대로 기록
        # verify gate (static + zone-exists + movable) BEFORE any geometric mutation.
        # 기하 변경 전에 먼저 검증(정적 + 구역 실존 + 옮길 대상 존재).
        vverdict = verify_relocate(proposal, env)
        if vverdict isa Reject
            monitor_record_verification!(status="rejected", checks=Any[
                Dict("name"=>"past_is_invariant", "passed"=>vverdict.reason != :touches_closed,
                     "detail"=>vverdict.detail),
                Dict("name"=>"zone_exists", "passed"=>vverdict.reason != :no_such_zone,
                     "detail"=>vverdict.detail),
                Dict("name"=>"build_movable", "passed"=>vverdict.reason != :no_staging,
                     "detail"=>vverdict.detail),
                # 비례성: 전역 이동이 이 구역에 값하는가(RELOCATE_GATE, 기본 꺼짐).
                Dict("name"=>"proportionate", "passed"=>vverdict.reason != :disproportionate,
                     "detail"=>vverdict.detail),
            ], execution=Dict("action"=>"safe_fallback"),
               verdict="REJECTED · $(vverdict.reason)")
            @warn "[RESPEC] relocate proposal REJECTED ($(vverdict.reason)): $(vverdict.detail) -> fallback"
            engage_fallback!(env)
            return :rejected
        end
        @info "[RESPEC] whole-build relocation verified -> translate the entire build clear of the zone"
        rb_checks = Any[
            Dict("name"=>"typed_proposal", "passed"=>true,
                 "detail"=>"RespecProposal contains RelocateBuild"),
            Dict("name"=>"past_is_invariant", "passed"=>true,
                 "detail"=>"proposal does not modify a closed schedule node"),
            Dict("name"=>"zone_exists", "passed"=>true,
                 "detail"=>"named zone exists in live RESTRICTION_ZONES"),
        ]
        wb = translate_whole_build!(env; resume = true)   # 빌드 전체를 구역 밖으로 평행이동
        # :already_clear = Δ0 (구역이 미완 목표를 하나도 안 덮어 옮길 필요가 없었음). 실행가능성 측면에서는
        # :translated 와 같은 "안전" 상태지만 **한 일이 다르므로** 판정문에 그대로 드러낸다.
        if wb.status in (:translated, :already_clear)
            noop = wb.status === :already_clear
            push!(rb_checks, Dict("name"=>"recovery_feasible", "passed"=>true,
                "detail"=>(noop ?
                    "no move required: every unfinished goal was already clear of the zone; residual=$(get(wb,:residual,0))" :
                    "whole-build translation cleared all future goals; residual=$(get(wb,:residual,0))")))
            monitor_record_verification!(status="passed", checks=rb_checks,
                execution=Dict("action"=>(noop ? "no_move_required" : "translate_whole_build"),
                               "status"=>string(wb.status),
                               "delta"=>get(wb,:delta,nothing),
                               "distance"=>norm(get(wb,:delta,[0.0,0.0])),
                               "geometry_solver"=>string(get(wb,:solver,:legacy)),
                               "goal_discs"=>get(wb,:n_goal_discs,0),
                               "work_discs"=>get(wb,:n_work_discs,0),
                               "residual"=>get(wb,:residual,0)),
                verdict=(noop ?
                    "ADMITTED · verified · NO MOVE REQUIRED (build already clear of the zone)" :
                    "ADMITTED · verified · whole-build translated"))
            @info(noop ?
                "[RESPEC] whole-build relocation not required (build already clear of the zone) -> admitted" :
                "[RESPEC] whole-build translated Δ=$(get(wb,:delta,nothing)) -> admitted")
            return :admitted
        end
        # :no_staging can only appear if the geometry changed between gate and enactment.
        # :residual_blocked / :infeasible = the zone cannot be cleared by ANY rigid shift.
        # [한국어] :residual_blocked/:infeasible = 어떤 강체이동으로도 구역을 벗어날 수 없음 → 안전 정지.
        @warn "[RESPEC] whole-build $(wb.status) (residual $(get(wb,:residual,-1))) -> fallback"
        push!(rb_checks, Dict("name"=>"recovery_feasible", "passed"=>false,
            "detail"=>"whole-build recovery $(wb.status); residual=$(get(wb,:residual,-1))"))
        monitor_record_verification!(status="rejected", checks=rb_checks,
            execution=Dict("action"=>"safe_fallback", "status"=>string(wb.status)),
            verdict="REJECTED · recovery infeasible")
        engage_fallback!(env)
        return :fallback
    end

    # --- TranslateBuild (L2-b, Task C3): the PRIMITIVE under RelocateBuild -----------
    # 🔴 `RelocateBuild` 와 같은 기전(`_apply_uniform_translation!`)을 쓰지만 Δ 의 출처가 반대다:
    #    거기서는 `_find_min_translation` 이 Δ 를 찾아 주고(= solver, 매크로 선택), 여기서는
    #    **제안자가 Δ 를 준다**(= 원시연산, 행동 신설). 그래서 zone 이름도, kind 별 전제조건도 없다.
    #
    # 🔴 **조용한 폴백 금지 (Global Constraint).** 판정은 전부 `verify_translate`(verifier.jl,
    #    Task C4)가 한다 — 이 분기는 그 판정을 집행하고 기록할 뿐이다. 그것이 죽이는 네 가지:
    #    (a) 관측 불가능한 Δ — `|Δ| < _TB_MIN_DELTA` 는 `state_hash` 가 흡수해 NOOP 과 바이트
    #        동일하다. "옮기겠다" 고 말해 놓고 안 옮기는 hollow admit 이므로 `:noop`(= 빈 제약 =
    #        절제)과 **구분되어야** 한다. 절제는 개입하지 않기로 한 것이고 이것은 개입하겠다고 한
    #        뒤 아무 일도 안 일어난 것이다. 그래서 `:rejected` 다.
    #    (b) 옮길 대상 없음 — `_apply_uniform_translation!` 은 `env.staging_circles` 를 순회하므로
    #        그것이 비면 **에러 없이 아무것도 안 한다**(= 조용한 no-op). `translate_whole_build!` 이
    #        같은 상황을 `:no_staging` 으로 먼저 걸러 내는 것과 같은 자리다.
    #    (c) 구역을 못 비우는 Δ — 모자란 크기 · 틀린 방향.
    #    (d) 작업영역(고정 창고 링)을 벗어나는 Δ — 구역을 비우는 것은 **충분조건이 아니다.**
    #    넷 다 **클램프하지 않는다** — "안전한" Δ 로 대체하지도, 기본값을 넣지도 않는다.
    #    비유한 Δ 는 여기 도달할 수 없다: `TranslateBuild` 의 내부 생성자가 이미 `error()` 다.
    #
    # ⚠️ `engage_fallback!` 을 부르지 않는다(= 라인을 영구 정지시키지 않는다). `RESPEC_HOLD[]` 는
    #    latch 되고 production 에서 아무도 안 푼다(이 파일의 line-stop 게이트 주석). 잘못 쓴 Δ 하나로
    #    남은 런 전체의 respec 을 죽이는 것은 비례하지 않는다 — `_is_reform` 분기가
    #    이미 latch 없이 `:rejected` 를 내는 것과 같은 처리다. 🔴 **아직 안 닫힌 것**: "어떤 Δ 도
    #    구역을 링 안에서 비울 수 없다"(= 진짜 기하적 infeasible)는 판정은 아직 이 경로에 없다 —
    #    `verify_translate` 는 **주어진** Δ 만 본다. 그 자리는 `RelocateBuild` 경로의
    #    `:infeasible` → `engage_fallback!` 이 여전히 담당한다.
    if _is_translate_build(proposal)
        push!(ENACT_ORDER_LOG[], :translate)   # C1: 실제로 진입한 분기를 진입 순서대로 기록
        # `:translate` 는 배치되지 않는다(`_enact_batched`) → 단위는 언제나 낱개다. 아니면 **죽는다**
        # (조용히 `first` 를 집어 나머지를 버리면 C1 이 고친 결함이 이 분기에서 되살아난다).
        tbs = TranslateBuild[c for c in proposal.constraints if c isa TranslateBuild]
        length(tbs) == 1 ||
            error("_enact_one!(:translate): 집행 단위에 TranslateBuild 가 $(length(tbs))개다. " *
                  "`_enact_batched(:translate) == false` 이므로 낱개여야 한다 — " *
                  "묶으면 나머지가 조용히 버려진다.")
        c = tbs[1]
        Δ = (c.dx, c.dy)
        # --- 🔴 Task C4: 기하 티어의 **일반 검증기**가 이 분기의 유일한 관문이다 ---------------
        # C3 는 여기서 세 전제조건(유한 · 관측가능 · 옮길 대상)을 직접 재고, 옮긴 **뒤** 잔여를
        # 세고, `.-Δ` 로 되돌리는 **잠정** 경계를 붙였다. 그 잠정 경계를 `verify_translate` 가
        # 대체한다(둘 다 두면 같은 검사가 두 번 돈다). 세 가지가 달라졌다:
        #   · **적용 전에 판정한다.** 되돌리기가 없으므로 되돌리기가 부정확할 위험도 없다.
        #     (부정확한 되돌리기는 세계를 영구히 어긋나게 하므로 fail-open 보다 나쁘다.)
        #   · **활성 구역이 없을 때도 경계가 있다** — 고정 창고 링(`_within_workspace_bounds`).
        #     C3 는 그 경우 모든 Δ 를 통과시켰다.
        #   · **구역을 넘치게 비우는 Δ 도 거부된다** — 잔여 0 은 필요조건이지 충분조건이 아니다
        #     (`TranslateBuild(1e6, 1e6)` 이 C3 의 경계를 통과했다).
        # 유한성 재검사는 뺐다: `TranslateBuild` 의 내부 생성자(spec_dsl.jl:385)가 비유한 Δ 에서
        # 이미 `error()` 로 죽으므로 여기 도달할 수 있는 비유한 Δ 는 **존재하지 않는다**
        # (도달 불가능한 분기를 "통과했다" 고 기록하는 것은 이 계획서가 금지한 초록불이다).
        tverdict = verify_translate(RespecProposal(ConstraintSpec[c]), env)
        # 🔴 **평가되지 않은 검사를 "passed" 로 적지 않는다** (fix 1, 컨트롤러 minor 3).
        #    `verify_translate` 는 단락 평가라 `:zero_displacement` 로 거부되면 구역 검사도
        #    작업영역 검사도 **한 적이 없다.** 그것을 초록으로 기록하면 모니터에 "증거가 아닌
        #    초록불" 이 생긴다 — 열두 줄 위에서 `isfinite` 재검사를 지운 것과 같은 이유다.
        #    그래서 `verify_translate` 의 검사 **순서 그대로** 잘라서, 실제로 평가된 것까지만
        #    적는다(거부 사유가 그 순서의 어디에서 멈췄는지를 말해 준다).
        _TB_CHECK_ORDER = (:zero_displacement, :no_staging, :residual_blocked, :out_of_bounds)
        # ⚠️ `Dict{String,Any}` 를 **명시한다**: 리터럴만 두면 `Dict{String,String}` 으로 추론돼
        #    아래에서 `d["passed"] = Bool` 이 MethodError 로 죽는다(실측으로 잡았다).
        _tb_check_all() = Any[
            Dict{String,Any}("name" => "observable_delta",
                 "detail" => "Δ = ($(c.dx), $(c.dy)); |Δ| = $(norm([c.dx, c.dy])) " *
                             "(하한 $(_TB_MIN_DELTA) = simstate `_c` 의 관측 양자)"),
            Dict{String,Any}("name" => "translatable_target",
                 "detail" => "staging_circles = $(length(env.staging_circles))"),
            Dict{String,Any}("name" => "clears_active_zones",
                 "detail" => "zones = $(sort!(collect(keys(RESTRICTION_ZONES[])); by = string))"),
            Dict{String,Any}("name" => "within_workspace",
                 "detail" => "depot ring D = $(spare_depot_distance())"),
        ]
        function _tb_checks(rej)
            all_ = _tb_check_all()
            i = rej === nothing ? length(all_) : findfirst(==(rej), _TB_CHECK_ORDER)
            # 순서에 없는 사유(:not_translate/:ambiguous — 이 분기는 그 전에 error() 로 죽는다)면
            # 아무 검사도 평가되지 않은 것이므로 하나도 적지 않는다.
            i === nothing && return Any[]
            out = all_[1:i]
            for (j, d) in enumerate(out)
                d["passed"] = (rej === nothing) || (j < i)
            end
            return out
        end
        if tverdict isa Reject
            monitor_record_verification!(status = "rejected",
                checks = _tb_checks(tverdict.reason),
                execution = Dict("action" => "none", "status" => string(tverdict.reason),
                                 "delta" => [c.dx, c.dy]),
                verdict = "REJECTED · $(tverdict.reason)")
            # ⚠️ `engage_fallback!` 을 부르지 않는다(= 라인을 영구 정지시키지 않는다). `RESPEC_HOLD[]`
            #    는 latch 되고 production 에서 아무도 안 푼다 — 잘못 쓴 Δ 하나로 남은 런 전체의
            #    respec 을 죽이는 것은 비례하지 않는다. 세계는 **안 바뀐 채로** 남는다(읽기 전용 판정).
            @warn "[RESPEC] TranslateBuild Δ=($(c.dx), $(c.dy)) REJECTED " *
                  "($(tverdict.reason)): $(tverdict.detail) -> no mutation (clamp 하지 않는다)"
            return :rejected
        end
        _apply_uniform_translation!(env, Δ)                  # 실제로 빌드 전체를 Δ 만큼 옮긴다
        reset_cache_resume!(env.cache, env.sched)            # 그래프/기하가 바뀌었으니 프론티어 재빌드
        monitor_record_verification!(status = "passed",
            checks = _tb_checks(nothing),
            execution = Dict("action" => "translate_build", "status" => "translated",
                             "delta" => [c.dx, c.dy], "distance" => norm([c.dx, c.dy]),
                             "geometry_solver" => "proposer_supplied_delta"),
            verdict = "ADMITTED · whole build translated by the PROPOSED Δ")
        @info "[RESPEC] TranslateBuild: whole build translated by Δ=($(c.dx), $(c.dy)) " *
              "|Δ|=$(round(norm([c.dx, c.dy]); digits = 3)) -> admitted"
        return :admitted
    end

    # --- restriction zone: dispatch to the geometric multi-assembly relocation --
    # A ForbidZone is SPATIAL (no MILP re-solve): the active zone(s) cover one or
    # more assemblies' staging areas. restage_all_blocked! relocates EVERY blocked
    # assembly clear of the zone (Phase a — not just the one named in the spec; the
    # set is detected geometrically). Like the robot-fault path, this is dispatched
    # specially because the generic verify/MILP gate can't express "move off a circle."
    # [한국어] ForbidZone(공간형) 대응: no-go 구역이 덮은 적치영역을 기하적으로 옮김(MILP 재풀이 아님).
    #   restage_all_blocked! 이 "구역이 덮은 모든 조립체"의 적치를 구역 밖으로 옮김(spec 이 지목한 하나만이 아님).
    if _is_zone_respec(proposal)
        push!(ENACT_ORDER_LOG[], :zone)   # C1: 실제로 진입한 분기를 진입 순서대로 기록
        # verify gate (static + zone-exists) BEFORE any geometric mutation — never trust the LLM.
        # 기하 변경 전에 먼저 검증(정적 검사 + 구역 실존) — LLM 을 절대 맹신하지 않음.
        zverdict = verify_zone(proposal, env)
        if zverdict isa Reject                    # 검증 거부면 안전 폴백
            monitor_record_verification!(status="rejected", checks=Any[
                Dict("name"=>"past_is_invariant", "passed"=>zverdict.reason != :touches_closed,
                     "detail"=>zverdict.detail),
                Dict("name"=>"zone_exists", "passed"=>zverdict.reason != :no_such_zone,
                     "detail"=>zverdict.detail),
                # 도메인 공백(:empty_domain)은 ZONE_DOMAIN_GATE 가 켜졌을 때만 거절 사유가 된다
                # (verifier.jl 게이트 주석 참조). 꺼져 있으면 이 항목은 항상 통과로 남는다.
                Dict("name"=>"zone_domain_nonempty", "passed"=>zverdict.reason != :empty_domain,
                     "detail"=>zverdict.detail),
            ], execution=Dict("action"=>"safe_fallback"),
               verdict="REJECTED · $(zverdict.reason)")
            @warn "[RESPEC] zone proposal REJECTED ($(zverdict.reason)): $(zverdict.detail) -> fallback"
            engage_fallback!(env)
            return :rejected
        end
        @info "[RESPEC] zone re-spec verified -> restage all blocked assemblies"
        # 실행 **전에** 도메인 크기를 찍어둔다 — restage 가 끝난 뒤에 재면 이미 옮겨져서 0 이 된다.
        local zone_syms = [c.zone for c in proposal.constraints if c isa ForbidZone]
        local n_domain = isempty(zone_syms) ? -1 : sum(z -> max(zone_domain_size(env, z), 0), zone_syms)
        res = restage_all_blocked!(env; resume = true)   # 막힌 조립체들의 적치를 전부 이동
        base_checks = Any[
            Dict("name"=>"typed_proposal", "passed"=>true,
                 "detail"=>"RespecProposal contains ForbidZone"),
            Dict("name"=>"past_is_invariant", "passed"=>true,
                 "detail"=>"proposal does not modify a closed schedule node"),
            Dict("name"=>"zone_exists", "passed"=>true,
                 "detail"=>"named zone exists in live RESTRICTION_ZONES"),
            # 이 팔이 실제로 무언가를 할 수 있었는지의 기록. 0 이면 아래 결과는 NOOP 과 바이트 동일하다
            # — 결정 품질 채점에서 "행동했다"로 세면 안 되는 행이라는 표식(verifier.jl ZONE_DOMAIN_GATE).
            Dict("name"=>"zone_domain_nonempty", "passed"=>n_domain != 0,
                 "detail"=>n_domain == 0 ?
                    "relocatable domain was EMPTY before enactment — this ForbidZone is a silent no-op" :
                    "relocatable domain = $(n_domain) assemblies before enactment"),
        ]
        # :residual_blocked = zone also covers the root's OWN (un-relocatable) deposit goals
        # — per-assembly moves can't clear the dense central core. Phase B: translate the
        # WHOLE build clear of the zone before giving up.
        # [한국어] :residual_blocked = 구역이 못 옮기는 중앙 core 목표까지 덮음 → Phase B: 빌드 전체를 통째로 평행이동.
        if res.status == :residual_blocked
            @info "[RESPEC] restage_all residual_blocked (residual $(get(res,:residual,0))) -> whole-build translate"
            wb = translate_whole_build!(env; resume = true)  # 빌드 전체를 구역 밖으로 평행이동
            # :already_clear(Δ0)도 안전 상태다 — 여기까지 왔다면 사실상 나올 수 없지만, 나온다고 해서
            # 전역 line-stop 을 걸 이유는 없으므로 성공으로 받는다.
            if wb.status in (:translated, :already_clear)
                push!(base_checks, Dict("name"=>"recovery_feasible", "passed"=>true,
                    "detail"=>"whole-build translation cleared residual goals; residual=$(get(wb,:residual,0))"))
                monitor_record_verification!(status="passed", checks=base_checks,
                    execution=Dict("action"=>"translate_whole_build", "status"=>string(wb.status),
                                   "delta"=>get(wb,:delta,nothing),
                                   "distance"=>norm(get(wb,:delta,[0.0,0.0])),
                                   "geometry_solver"=>string(get(wb,:solver,:legacy)),
                                   "goal_discs"=>get(wb,:n_goal_discs,0),
                                   "work_discs"=>get(wb,:n_work_discs,0),
                                   "residual"=>get(wb,:residual,0)),
                    verdict="ADMITTED · verified · whole-build translated")
                @info "[RESPEC] whole-build translated Δ=$(get(wb,:delta,nothing)) -> admitted"
                return :admitted
            end
            @warn "[RESPEC] whole-build $(wb.status) (residual $(get(wb,:residual,-1))) -> fallback"
            push!(base_checks, Dict("name"=>"recovery_feasible", "passed"=>false,
                "detail"=>"whole-build recovery $(wb.status); residual=$(get(wb,:residual,-1))"))
            monitor_record_verification!(status="rejected", checks=base_checks,
                execution=Dict("action"=>"safe_fallback", "status"=>string(wb.status)),
                verdict="REJECTED · recovery infeasible")
            engage_fallback!(env)                 # 평행이동도 실패하면 안전 폴백
            return :fallback
        end
        # :partial / :infeasible = couldn't place all relocatable assemblies -> safe stop.
        # [한국어] :partial/:infeasible = 옮길 수 있는 조립체를 다 못 놓음 → 안전 정지.
        if res.status in (:infeasible, :partial)
            push!(base_checks, Dict("name"=>"recovery_feasible", "passed"=>false,
                "detail"=>"restage $(res.status); moved=$(length(res.moved)), failed=$(length(res.failed))"))
            monitor_record_verification!(status="rejected", checks=base_checks,
                execution=Dict("action"=>"safe_fallback", "status"=>string(res.status)),
                verdict="REJECTED · recovery $(res.status)")
            @warn "[RESPEC] restage_all $(res.status) (moved $(length(res.moved)), failed $(length(res.failed))) -> fallback"
            engage_fallback!(env)
            return :fallback
        end
        push!(base_checks, Dict("name"=>"recovery_feasible", "passed"=>true,
            "detail"=>res.status == :none ? "detour-only zone; no staging goal blocked" :
                      "all blocked assemblies restaged; moved=$(length(res.moved)), residual=$(get(res,:residual,0))"))
        monitor_record_verification!(status="passed", checks=base_checks,
            execution=Dict("action"=>res.status == :none ? "navigation_detour" : "restage_all_blocked",
                           "status"=>string(res.status), "moved"=>length(res.moved),
                           "domain"=>n_domain,   # 실행 전 도메인 크기(0 = 이 팔은 애초에 no-op 이었다)
                           "residual"=>get(res,:residual,0)),
            verdict=res.status == :none ? "ADMITTED · verified · navigation detour" :
                                          "ADMITTED · verified · assemblies restaged")
        return res.status == :none ? :noop : :admitted   # :none = zone covers no goal (detour-only)  # :none=목표 안 덮음(우회만) → noop
    end

    # --- battery depletion: swap the pack in the field -------------------------
    # Dispatched specially (like ReplaceAgent/ForbidZone) because it is not a MILP
    # constraint: the body, the schedule and the teams are all untouched, so there is
    # nothing to re-solve. It consumes NO depot spare — that scarcity belongs to
    # ReplaceAgent, and keeping the two accounts apart is what makes choosing between
    # them a real decision (see SwapBattery in spec_dsl.jl).
    # [한국어] 배터리 방전 → 현장 배터리 교체. MILP 제약이 아니라 전용 dispatch(본체·스케줄·팀이
    #   그대로라 재풀이할 게 없음). 창고 예비 본체를 안 먹는다 — 그 희소성은 ReplaceAgent 의 몫이고,
    #   두 장부를 분리해야 둘 중 고르는 게 진짜 결정이 된다.
    if _is_battery_swap(proposal)
        push!(ENACT_ORDER_LOG[], :battery)   # C1: 실제로 진입한 분기를 진입 순서대로 기록
        role = first(c for c in proposal.constraints if c isa SwapBattery).agent
        bverdict = verify_swap_battery(proposal, env)      # 변경 전 검증(정적 + grounding)
        if bverdict isa Reject
            @warn "[RESPEC] swap-battery proposal REJECTED ($(bverdict.reason)): $(bverdict.detail) -> no-op"
            return :rejected
        end
        n_id_before = check_identity!(env, "before SwapBattery($(role))")
        res = swap_battery!(env, role)
        # :battery_courier_dispatched = 배송 경로(battery_courier.jl). 교체는 예비 로봇이 현장에
        # 도착하는 스텝에 적용된다 — 제안 자체는 그 순간 이미 ADMIT 된 것이므로 여기서 성공으로 센다.
        if !(res.status in (:battery_swapped, :battery_courier_dispatched))
            @warn "[RESPEC] swap-battery $(res.status) -> no-op" detail = get(res, :detail, "")
            return :noop
        end
        deferred = res.status === :battery_courier_dispatched
        try
            monitor_record_verification!(status="passed", checks=Any[
                Dict("name"=>"typed_proposal", "passed"=>true, "detail"=>"SwapBattery target $(role) is valid"),
                Dict("name"=>"past_is_invariant", "passed"=>true, "detail"=>"completed schedule nodes are not rewritten"),
                Dict("name"=>"identity_preserved", "passed"=>true, "detail"=>"same physical asset; only the battery changed"),
            ], execution=Dict("action"=>"swap_battery", "role"=>string(role),
                              "soc_before"=>res.soc_before === nothing ? "unknown" : res.soc_before,
                              "delivery"=>deferred ? "depot courier en route" : "in place",
                              "courier"=>deferred ? string(res.courier) : ""),
            verdict="ADMITTED · verified battery swap")
        catch
        end
        @info deferred ?
            "[RESPEC] ADMITTED battery swap: role $(role) — courier $(res.courier) is driving out from the :$(res.depot) depot (no depot body consumed)." :
            "[RESPEC] ADMITTED battery swap: role $(role) recharged in the field (no depot body consumed)."
        # 본체가 안 바뀌므로 위반이 생길 수가 없다 — 그래도 측정한다(그 주장 자체를 검증하려고).
        report_identity_delta(env, n_id_before, "swap-battery($(role))")
        return :admitted
    end

    # --- robot breakdown: dispatch to the spare 1:1 chain hand-off -------------
    # A ReplaceAgent is identity/graph surgery (no MILP re-solve): the nearest
    # directional spare pool donates an idle robot whose empty chain ADOPTS the
    # faulted robot's remaining work (replace_robot.jl). Dispatched specially, like
    # ForbidZone/ForbidAgent, because the generic verify/MILP gate cannot express
    # "graft one robot's thread onto another." The spare is chosen by GEOMETRY.
    # [한국어] ReplaceAgent(로봇 고장) 대응: 가장 가까운 방위 예비 풀이 idle 로봇 1대를 내주고, 그 빈 작업사슬이
    #   고장 로봇의 남은 일을 통째로 넘겨받음(1:1 인계, MILP 재풀이 아님). 예비 선택은 기하(nearest_pool)로.
    if _is_robot_replace(proposal)
        push!(ENACT_ORDER_LOG[], :replace)   # C1: 실제로 진입한 분기를 진입 순서대로 기록
        # the faulted agent the LLM named; the SPARE is geometry's call, not the LLM's.
        # 고장 로봇은 LLM 이 지목, 예비(spare)는 기하가 결정. first(...) = 조건 맞는 첫 제약의 .agent 를 꺼냄.
        faulted = first(c for c in proposal.constraints if c isa ReplaceAgent).agent
        # STEP A-1: BASELINE identity scan taken BEFORE any mutation. Paired with the
        # post-enactment scan below, it separates "this enactment broke identity" from
        # "identity was already broken when we got here" — without the pair, a violation
        # found after a Replace is unattributable. (identity.jl)
        # [한국어] 변경 "전" 기준선 검사. 아래의 변경 "후" 검사와 짝을 이뤄야, 발견된 위반이
        #   이번 교체 때문인지 원래 깨져 있던 것인지 구분된다. 짝이 없으면 원인 특정 불가.
        n_id_before = check_identity!(env, "before ReplaceAgent($(faulted))")
        # verify gate (static + spare-exists) BEFORE any mutation — never trust the LLM.
        # 변경 전 검증(정적 + 예비 존재). LLM 맹신 금지.
        rverdict = verify_replace(proposal, env)
        if rverdict isa Reject
            try
                monitor_record_verification!(status="rejected", checks=Any[
                    Dict("name"=>"typed_proposal", "passed"=>true, "detail"=>"ReplaceAgent is grounded to $(faulted)"),
                    Dict("name"=>"spare_available", "passed"=>false, "detail"=>rverdict.detail),
                ], execution=Dict("action"=>"none", "reason"=>string(rverdict.reason)),
                verdict="REJECTED · $(rverdict.reason)")
            catch
            end
            # NO SPARE is not a safety violation — it just means the 1:1 hand-off can't be
            # used. Degrade to the general reassign (keep the build going) instead of a global
            # freeze. Any OTHER reject (bad grounding) is a genuine stop.
            # [한국어] "예비 없음"은 안전 위반이 아님 → 얼리지 말고 일반 재분배로 강등(빌드 계속). 그 외 거부는 진짜 정지.
            rverdict.reason == :no_spare && return _replace_via_reassign!(env, faulted, optimizer, "verify:no_spare")
            @warn "[RESPEC] replace proposal REJECTED ($(rverdict.reason)): $(rverdict.detail) -> fallback"
            engage_fallback!(env)
            return :rejected
        end
        # IDENTITY-PRESERVING SCENE-TREE HOT-SWAP (preferred, when enabled): keep the
        # faulted RobotID and swap its physical asset from the repository. No schedule
        # re-stamp, so the re-stamp double-booking / team-rekey / transform-binding
        # failure modes are structurally impossible. On no-spare/failure, degrade to the
        # general reassign (keep the build going) rather than a global freeze.
        # [한국어] (선호, 켜졌을 때) 정체성 보존 씬트리 hot-swap: 고장 RobotID 는 유지하고 물리 본체만
        #   창고에서 교체 → 재각인(re-stamp)의 double-book/team-rekey 실패모드가 구조적으로 불가능.
        if hot_swap_enabled()
            hs = hot_swap_robot!(env, faulted; mode = HOT_SWAP_MODE[])
            if hs.status == :swapped              # 교체 성공
                try
                    monitor_record_verification!(status="passed", checks=Any[
                        Dict("name"=>"typed_proposal", "passed"=>true, "detail"=>"ReplaceAgent target $(faulted) is valid"),
                        Dict("name"=>"past_is_invariant", "passed"=>true, "detail"=>"completed schedule nodes are not rewritten"),
                        Dict("name"=>"spare_available", "passed"=>true, "detail"=>"nearest idle spare selected from $(hs.depot) depot"),
                        Dict("name"=>"identity_handoff", "passed"=>true, "detail"=>"logical schedule identity preserved while physical asset changed"),
                    ], execution=Dict("action"=>"hot_swap", "failed"=>string(faulted),
                                      "spare"=>string(hs.spare), "depot"=>string(hs.depot)),
                    verdict="ADMITTED · verified hot-swap")
                catch
                end
                @info "[RESPEC] ADMITTED hot-swap: robot $(faulted) replaced from :$(hs.depot) depot (mode $(hs.mode))."
                # STEP A-1: post-enactment scan. hot-swap changes NO id, so this must stay at
                # the baseline count — any increase means hot-swap is not identity-preserving
                # after all, which would be a finding, not a nuisance.
                # [한국어] 변경 후 검사. hot-swap 은 id 를 안 바꾸므로 기준선과 같아야 한다.
                #   늘었다면 hot-swap 도 정체성 보존이 아니라는 뜻 — 그건 잡음이 아니라 발견이다.
                report_identity_delta(env, n_id_before, "hot-swap($(faulted))")
                return :admitted
            end
            # 실패/예비없음이면 얼리지 말고 일반 재분배로 강등.
            @warn "[RESPEC] hot-swap $(hs.status) -> general reassign" detail = get(hs, :detail, "")
            return _replace_via_reassign!(env, faulted, optimizer, "hotswap_$(hs.status)")
        end
        # (A1) COMPLETION-SAFE multi-task distribution: if the faulted robot has SEVERAL pending
        # transport tasks, hand EACH to its OWN nearest spare (1 task per spare) instead of piling
        # them all on one spare. This removes the single-spare over-subscription that leaves the build
        # INCOMPLETE (cyclic OpenBuildStep wedge). Proximity: each task -> nearest_pool(pickup). Falls
        # through to the single-spare splice when ≤1 task or too few spares.
        # [한국어] (A1) 완주 안전한 다중작업 분산: 고장 로봇에 남은 운반이 여럿이면 각 작업을 "자기 나름의
        #   가장 가까운 예비"에게 1개씩 넘김(한 예비에 몰아주지 않음) → 단일 예비 과다구독으로 인한 미완주 제거.
        distres = replace_robot_distributed!(env, faulted; resume = true)
        if distres.status === :distributed
            @info "[RESPEC] ADMITTED distributed replace: robot $(faulted)'s $(distres.n_tasks) task(s) spread across $(distres.n_tasks) nearest spare(s) (no over-subscription)."
            # STEP A-1: post-enactment scan on the RE-STAMP path. This is the measurement that
            # decides whether the re-stamp path is deleted: it re-keys ids across registries, so
            # any violation appearing here (and not in `before`) is CAUSED by the re-stamp.
            # [한국어] 재각인 경로의 변경 후 검사. 여기서 새로 생긴 위반이 곧 "재각인이 원인"이라는 증거다.
            report_identity_delta(env, n_id_before, "distributed-replace($(faulted))")
            return :admitted
        end
        # 분산이 안 되면(작업 ≤1 또는 예비 부족) 단일 예비 접합으로 진행.
        pool = nearest_pool(_robot_position_2d(env, faulted))          # 고장 지점에서 가장 가까운 풀
        pool === nothing && return _replace_via_reassign!(env, faulted, optimizer, "no_pool")   # 쓸 풀 없으면 재분배로 강등
        spare = pop_spare!(pool)                                       # 그 풀에서 예비 하나 꺼냄
        spare === nothing && return _replace_via_reassign!(env, faulted, optimizer, "empty_pool")  # 비었으면 재분배로 강등
        @info "[RESPEC] robot-fault re-spec -> replace $(faulted) with nearest spare $(spare) (:$(pool) pool)"
        res = replace_robot!(env, faulted, spare; resume = true)       # 고장 로봇 사슬을 예비에 접합
        if res.status != :replaced
            if res.status === :no_frontier || res.status === :already_done
                # The faulted robot has NO pending work to hand off (it already finished its chain).
                # Replacing it is unnecessary, and degrading to a general reassign MILP-REJECTS
                # (nothing to reassign) and LINE-STOPS the whole build (observed 2026-07-07). Return
                # the untouched spare to its pool and NO-OP -- the build keeps running on the rest.
                # [한국어] 고장 로봇에 넘길 일이 없음(이미 사슬 완료) → 교체 불필요. 재분배로 강등하면 오히려
                #   "재분배할 게 없음"으로 MILP 가 거부해 빌드 전체가 멈춤 → 꺼낸 예비를 풀에 되돌리고 no-op.
                try; register_spare!(pool, spare); catch; end   # 안 쓴 예비를 풀에 반납
                @info "[RESPEC] replace $(faulted): $(res.status) (robot already done) -> no-op (build continues)."
                return :noop
            end
            # spare hand-off failed for another reason -> try general reassign before stopping.
            # 다른 이유로 인계 실패 → 멈추기 전에 일반 재분배 시도.
            @warn "[RESPEC] spare replace $(res.status); degrading to general reassign" detail = get(res, :detail, "")
            return _replace_via_reassign!(env, faulted, optimizer, "replace_$(res.status)")
        end
        @info "[RESPEC] ADMITTED replace: spare $(spare) took over robot $(faulted)'s $(res.slots) downstream task(s)."
        # STEP A-1: post-enactment scan on the single-spare RE-STAMP splice (see above).
        # [한국어] 단일 예비 접합(재각인)의 변경 후 검사 — 위 분산 경로와 같은 목적.
        report_identity_delta(env, n_id_before, "splice-replace($(faulted)->$(spare))")
        return :admitted
    end

    # --- multi-robot team deadlock: dispatch to geometric team re-establishment --
    # A ReformTeam is geometric surgery (no MILP): wedged teams get their straggler
    # members snapped into their carrying slots so the unit forms. The verify gate
    # admits ONLY if a mostly-formed-but-wedged team actually exists.
    # [한국어] ReformTeam(다중로봇 팀 교착) 대응: 교착된 팀의 낙오 멤버를 운반 슬롯에 끼워 팀을 재구성(MILP 없음).
    if _is_reform(proposal)
        push!(ENACT_ORDER_LOG[], :reform)   # C1: 실제로 진입한 분기를 진입 순서대로 기록
        # A ReformTeam request is SPECULATIVE: the "team deadlocked" OOD is auto-emitted on a
        # no-progress heuristic (demo_utils.jl), so "no actually-reformable wedge" is a FALSE
        # ALARM, not a hard-constraint violation. reform is purely additive geometric surgery,
        # so when there is nothing to safely do we DECLINE (no-op) and let the build keep
        # running -- we must NOT engage_fallback!, which sets the permanent global line-stop
        # (RESPEC_HOLD, never reset) and would freeze every other still-working team. Only a
        # genuine safety reject (the verify() gate below) line-stops.
        # [한국어] 이 요청은 추측성(진전 없음 heuristic 으로 자동 발생) → "재구성할 교착 없음"은 위반이 아니라
        #   오경보. 안전히 할 게 없으면 거절(no-op)하고 빌드 계속. 여기서 engage_fallback! 을 부르면
        #   영구 전역 정지(RESPEC_HOLD)라 아직 잘 돌던 다른 팀까지 얼어붙으므로 절대 부르지 않음.
        fverdict = verify_reform(proposal, env)
        if fverdict isa Reject
            # NOT the narrow mostly-formed wedge verify_reform admits. The "team
            # deadlocked" OOD is a blind no-progress alarm, so instead of a dead-end
            # no-op we DIAGNOSE the real pattern and take the matching SAFE action
            # (graduated recovery): snap / restage-out-of-zone / force-snap, escalating
            # only as far as needed. This is what makes the stall self-heal.
            # [한국어] 오경보라도 막다른 no-op 대신 진짜 정체 패턴을 진단하고, 필요한 만큼만 단계적으로 안전 복구
            #   (끼우기 → 구역 밖 재적치 → 강제 끼우기). 이게 정체를 스스로 낫게(self-heal) 만드는 부분.
            try
                diagnose_transport_stall(env)   # READ-ONLY: dump the REAL stall pattern  # 읽기 전용: 실제 정체 패턴 로그
            catch e
                @warn "[RESPEC][DIAG] diagnose_transport_stall failed" exception = e
            end
            rec = try
                recover_stalled_teams!(env)     # 단계적 안전 복구 시도
            catch e
                @warn "[RESPEC] recover_stalled_teams! failed -> no-op" exception = e
                (status = :error, moved = 0)
            end
            if rec.status in (:snapped, :force_snapped)      # 낙오 멤버를 슬롯에 끼워 팀 재구성 성공
                reset_cache_resume!(env.cache, env.sched)   # re-derive frontier after the snap  # 끼운 뒤 frontier 재유도
                @info "[RESPEC] ADMITTED reform recovery ($(rec.status)): re-established stalled team(s)."
                return :admitted
            elseif rec.status == :restaged                   # 정체 원인이 no-go 구역 → 적치를 구역 밖으로 옮겨 해소
                # restage_all_blocked!/translate_whole_build! already resumed the cache.
                @info "[RESPEC] ADMITTED reform recovery (restaged): staging moved clear of no-go zone."
                return :admitted
            elseif rec.status in (:carrier_closed, :carrier_advanced)
                # A stuck FORMED carrier was advanced to its deposit goal and its TransportUnitGo
                # force-closed (:carrier_closed) — re-derive the frontier so the freshly-activated
                # DepositCargo and its downstream chain can drive. Endgame completion lever for the
                # mid-build-Replace wedge (see force_advance_stuck_carrier!).
                # [한국어] 멈춘 "이미 형성된" 운반체를 하역 목표까지 전진시켜 강제 종료 → 활성화된 DepositCargo
                #   사슬이 움직일 수 있게 frontier 재유도. mid-build Replace 교착의 마무리(endgame) 지렛대.
                reset_cache_resume!(env.cache, env.sched)
                @info "[RESPEC] ADMITTED reform recovery ($(rec.status)): advanced $(rec.moved) stuck " *
                      "carrier(s) to deposit -> DepositCargo chain released."
                return :admitted
            end
            # ENDGAME scheduling wedge (:no_team / :stuck — nothing is forming): the single-spare
            # multi-task Replace left a serialization gate (dep_i -> slot_{i+1}) whose team-deposit
            # never closes, freezing the frontier near completion. Dissolve one such gate so the
            # remaining work re-activates and the build can finish (the completion-forcing recovery).
            # [한국어] :no_team/:stuck = 아무것도 형성 중이 아닌 endgame 스케줄 교착(직렬화 관문이 안 닫힘).
            #   그 관문 하나를 풀어(dissolve) 남은 일이 재활성화되고 빌드가 끝나게 함(완주 강제 복구).
            if rec.status in (:no_team, :stuck)
                wedge = try
                    resolve_schedule_wedge!(env)          # 막힌 직렬화 관문 하나 해소 시도
                catch e
                    @warn "[RESPEC] resolve_schedule_wedge! failed -> no-op" exception = e
                    (status = :no_wedge,)
                end
                if wedge.status == :unwedged               # 관문이 풀렸으면 frontier 전진
                    @info "[RESPEC] ADMITTED reform recovery (schedule-wedge): dissolved a stuck serialization gate -> frontier advances."
                    return :admitted
                end
            end
            # NAV_DEBUG: one-shot detailed dump of the endgame NAVIGATION stall (the :no_team +
            # :no_wedge fall-through). Characterizes the jam so a navigation-recovery scaffold can be
            # designed against evidence rather than assumption. Gated -> zero cost on normal runs.
            # NAV_DEBUG 환경변수가 "1"일 때만 endgame 항법 정체를 한 번 상세 덤프(평소엔 비용 0).
            if get(ENV, "NAV_DEBUG", "0") == "1"
                try _dump_nav_stall(env) catch e; @warn "[NAV-DBG] dump failed" exception=e end
            end
            @warn "[RESPEC] reform: no safe recovery applicable ($(rec.status)) -> no-op (build continues)"
            return :rejected                          # 안전히 할 수 있는 복구가 없음 → 거절(빌드는 계속)
        end
        # verify_reform 이 통과한 경우(진짜 "거의 형성됐는데 낀" 교착): 낙오 멤버들을 슬롯으로 재배치.
        n_moved = reform_stuck_teams!(env)
        if n_moved == 0
            @warn "[RESPEC] reform: no straggler repositioned -> no-op (build continues)"
            return :fallback
        end
        reset_cache_resume!(env.cache, env.sched)   # re-derive the frontier after the snap  # 재배치 뒤 frontier 재유도
        # NB: reform_stuck_teams! already refreshes the RVO sim (update_rvo_sim!) for any
        # newly-formed unit, so the reset frontier's TransportUnitGo can drive immediately.
        @info "[RESPEC] ADMITTED reform: re-established wedged team(s) by repositioning $(n_moved) straggler(s)."
        return :admitted
    end

    # 🔴 2026-08-24 (spec §5.4, Task 5): 여기 있던 soft `deprioritize` dispatch 분기를 지웠다.
    #   `_is_deprioritize` → `verify_deprioritize` → `deprioritize_agent!` → 에너지 인식 재풀이
    #   사슬 전체가 `DeprioritizeAgent` kind 하나에만 달려 있었고 그 kind 가 삭제됐다.
    #   ⚠️ `AGENT_COST_BIAS` 레지스트리와 `deprioritize_agent!` 자체는 남아 있지만, 이 커밋 뒤로
    #   **프로덕션 경로에서 그것을 쓰는 곳이 없다**(유일한 소비처는 tools/tests.jl 의 진단이다).

    # --- verify (the gate; does the trial solve itself) -----------------------
    # verify(...) : 제안을 실제로 "시험 풀이(trial solve)"해 통과/거부를 판정하는 관문. 통과 못 하면 Reject 객체 반환.
    push!(ENACT_ORDER_LOG[], :generic)   # C1: 특수 분기 어디에도 안 걸린 제약 = 제네릭 MILP 관문
    verdict = verify(proposal, env, invariant; optimizer = optimizer)
    if verdict isa Reject                        # 판정 결과가 Reject 타입이면(=거부)
        @warn "[RESPEC] proposal REJECTED ($(verdict.reason)): $(verdict.detail) -> fallback"  # 거부 사유 로그
        engage_fallback!(env)                    # 안전 폴백 작동
        return :rejected                         # 거부됨을 반환
    end

    # --- admit: commit the verified re-solve to the schedule of record --------
    # formulate_milp(...) : 혼합정수선형계획(MILP) 모델을 세움. 고정된 시작/끝 시각(frozen_t0/tF)과
    # 검증을 통과한 제약(verdict.proposal)을 넣어 "재명세된 일정 문제"를 구성.
    milp = formulate_milp(
        SparseAdjacencyMILP(), env.sched, env.scene_tree;  # 모델 종류 + 스케줄 + 장면 트리
        optimizer   = optimizer,                            # 사용할 솔버
        t0_ = invariant.frozen_t0, tF_ = invariant.frozen_tF,  # 이미 확정된 시간들을 고정값으로 주입
        extra_constraints = verdict.proposal,               # 검증 통과한 추가 제약
    )
    optimize!(milp)                              # MILP 를 실제로 풀기(끝의 `!` = milp 안에 해를 채워 넣음)
    # primal_status(milp) : 푼 결과 상태. MOI.FEASIBLE_POINT 가 아니면 "실행가능 해를 못 찾음".
    if primal_status(milp) != MOI.FEASIBLE_POINT
        # 일어나면 안 되는 상황(verify 가 같은 모델을 이미 풀어봤음) — 그래도 절대 맹신하지 않고 방어적으로 폴백.
        @warn "[RESPEC] committed solve disagreed with verifier -> fallback"
        engage_fallback!(env)
        return :fallback
    end

    # `!commit_respec!(...)` : 앞의 `!` 는 논리 부정(파이썬 not). 커밋이 실패(false 반환)하면 if 안으로 들어감.
    # commit_respec! : 푼 MILP 로 스케줄을 다시 새겨 재명세를 "확정·지속"시킴. resume=true 면 진행상태 유지하며 재개.
    if !commit_respec!(env, milp, verdict.proposal; resume = true)
        @warn "[RESPEC] commit re-stamp failed -> fallback"  # 커밋 실패 시 경고
        engage_fallback!(env)
        return :fallback
    end
    @info "[RESPEC] ADMITTED $(verdict.n_constraints) constraint(s); schedule re-solved & persisted."  # 채택 성공 로그
    return :admitted                             # 최종적으로 "채택됨" 반환
end

# =============================================================================
# Timing-persistent commit. The single commit used by the production replan path,
# the eval-harness gold runners, and the e2e test, so all enact a re-spec
# identically.
#
# WHY THIS EXISTS: the structural time pass `update_schedule_times!` recomputes
# every node's t0/tF from the graph (precedence edges + min-durations) by a
# monotone forward max. A timing-only re-spec (ForbidWindow) lives ONLY in the
# MILP and adds no edge, so a plain update_project_schedule! re-derives
# earliest-start times and the constraint's effect would be silently dropped at
# commit (see docs/timing_respec_persistence_gap). We close that gap with
# `persist_milp_times!`: write the MILP's solved t0/tF into the PathSpecs. The
# forward pass is monotone-up (starts from the stored value, only raises), so
# writing the FULL feasible MILP schedule makes the subsequent process_schedule!
# a fixed point -> the timing persists. (update_project_schedule! rebuilds edges
# from the assignment matrix but does NOT reset times, so the written times survive.)
#
# [한국어] 시간 지속형 커밋. 프로덕션 replan 경로/평가 harness/e2e 테스트가 공유하는 단 하나의 커밋이라
#   모두 재명세를 똑같이 실행한다. 존재 이유: 구조적 시간 재계산(update_schedule_times!)은 그래프에서
#   각 노드 t0/tF 를 단조 증가 전방 max 로 다시 구함. 그런데 "시간만 바꾸는 재명세(ForbidWindow)"는
#   엣지를 안 더하고 MILP 안에만 있어, 순진하게 재계산하면 커밋 때 그 효과가 조용히 사라짐.
#   해결: persist_milp_times! 로 MILP 가 푼 t0/tF 를 스케줄에 직접 써넣으면, 이후 전방 pass 가
#   그 값에서 고정점(fixed point)이 되어 시간이 보존됨.
# =============================================================================

"""
    persist_milp_times!(env, milp)

Write the solved MILP `t0`/`tF` into the schedule PathSpecs so the monotone
structural pass preserves them. Realized history is never overwritten: CLOSED
nodes keep both ends (they already happened), ACTIVE nodes keep their started `t0`
(only their finish is re-planned). Every other (future) node takes the MILP times.
"""
function persist_milp_times!(env, milp)
    sched = env.sched                            # 스케줄 그래프
    # `value.(...)` : 끝의 점(`.`)은 "브로드캐스트" — 함수를 배열의 각 원소에 일제히 적용(파이썬 넘파이의 벡터화와 비슷).
    # milp.model[:t0] 은 t0 변수들의 배열이고, value.(...) 로 각 변수의 풀린 값을 한꺼번에 뽑아 배열로 만듦.
    t0v = value.(milp.model[:t0])               # 각 노드의 시작시각(t0) 해 값 배열
    tFv = value.(milp.model[:tF])               # 각 노드의 종료시각(tF) 해 값 배열
    closed = env.cache.closed_set               # 이미 끝난 노드 집합
    active = env.cache.active_set                # 지금 진행 중인 노드 집합
    for v in Graphs.vertices(sched)
        v in closed && continue                 # 이미 실행돼 끝난 노드: 실제 기록(ground truth)을 유지(건드리지 않음)
        # `A || B` 단락: v 가 active 에 "있으면" 좌변이 참이라 set_t0! 를 건너뜀(진행 중 노드의 시작시각은 실제값 유지),
        # active 에 "없으면"(미래 노드) set_t0! 로 MILP 가 푼 시작시각을 써넣음.
        v in active || set_t0!(sched, v, t0v[v])
        set_tF!(sched, v, tFv[v])               # 종료시각은 (끝난 노드 제외) 모두 MILP 가 푼 값으로 갱신
    end
    return sched                                # 시간이 갱신된 스케줄 반환
end

"""
    reset_cache_resume!(cache, sched) -> cache

Resume-preserving sibling of `reset_cache!` (essential_tg_coponents.jl). Identical
intent — make the schedule re-solvable by rebuilding the planning frontier — EXCEPT
it does **not** discard execution progress. `reset_cache!` empties `closed_set` and
re-seeds the frontier from the project ROOTS, which restarts the build from scratch
(correct for a from-scratch plan, fatal mid-sim: completed work would re-execute).

Here `closed_set` is kept and the new `active_set` is the **frontier** of the
remaining work: every not-yet-closed vertex all of whose predecessors are already
closed (root nodes qualify vacuously, exactly as in `reset_cache!`). This is the
same readiness test `update_planning_cache!` uses to activate a successor (all
inneighbors closed), so the resumed frontier matches the live sim's own semantics.
`node_queue` is rebuilt from that frontier with `isps_queue_cost` (same as
`reset_cache!`). `process_schedule!` is kept — on the persisted MILP times it is a
fixed point (see docs/timing_respec_persistence_gap), so times are not reverted.
"""
# 인자에 `::PlanningCache`, `::OperatingSchedule` 타입을 명시 — 이 타입 조합일 때만 이 메서드가 호출됨(다중 디스패치).
function reset_cache_resume!(cache::PlanningCache, sched::OperatingSchedule)
    process_schedule!(sched)                     # 스케줄을 한 번 정리/전파(시간 등 파생값 재계산)
    G = get_graph(sched)                          # 스케줄에서 순수 그래프 구조를 꺼냄
    closed = cache.closed_set                     # 이미 끝난 노드 집합(그대로 보존 — 재개의 핵심)
    empty!(cache.active_set)                      # 진행중 집합 비우기(끝의 `!` = 그 집합을 직접 비움)
    empty!(cache.node_queue)                      # 처리 대기 큐 비우기
    for v in Graphs.vertices(G)
        v in closed && continue                  # 이미 끝난 노드는 다시 활성화하지 않음
        # all(조건함수, 컬렉션) : 컬렉션의 모든 원소가 조건을 만족하면 true(파이썬 all()).
        # `vp -> vp in closed` 는 람다. inneighbors = 선행 노드들. 즉 "선행 노드가 전부 끝났는가?"를 검사.
        # || continue: 하나라도 안 끝났으면 건너뜀 → 남은 그 "frontier(선행 다 끝난 노드)"만 활성화.
        all(vp -> vp in closed, Graphs.inneighbors(G, v)) || continue
        push!(cache.active_set, v)               # 이 노드를 새 진행중(active) 집합에 추가
        # enqueue!(큐, 키 => 우선순위) : 우선순위 큐에 넣기. isps_queue_cost 로 계산한 비용을 우선순위로 사용.
        enqueue!(cache.node_queue, v => isps_queue_cost(sched, v))
    end
    return cache                                  # 재구성된 캐시 반환
end

"""
    commit_respec!(env, milp, proposal; resume=false) -> Bool

Re-stamp the schedule from the solved `milp` and make the re-spec STICK:
re-derive the schedule (`update_project_schedule!`), write the MILP times
(`persist_milp_times!`), then rebuild the planning cache. Returns `false` iff the
re-stamp failed (e.g. the new assignment edges form a cycle) so the caller can
route to the safe fallback.

`resume`: when `true` (the live-sim path), rebuild the cache with
`reset_cache_resume!` so already-built nodes stay closed and the sim continues from
the current frontier instead of restarting. Default `false` keeps every existing
caller (tests, eval, from-scratch re-plan) byte-identical via `reset_cache!`.
"""
# proposal::RespecProposal : 그 타입의 제안일 때만. `resume::Bool = false` : 불리언 키워드 인자, 기본값 false.
function commit_respec!(env, milp, proposal::RespecProposal; resume::Bool = false)
    # update_project_schedule! : 푼 MILP 의 배정 결과로 스케줄(엣지 등)을 다시 만듦. 첫 인자 nothing = 추가 콜백 없음.
    # `=== false`(정확히 false 인가) 이고 `&& return false`: 재구성이 실패하면 곧바로 false 반환(예: 사이클 발생).
    update_project_schedule!(nothing, milp, env.sched, env.scene_tree) === false && return false
    persist_milp_times!(env, milp)              # MILP 가 푼 시각을 스케줄에 써넣어 재명세(특히 ForbidWindow 시간)가 사라지지 않게 함
    # 삼항: resume 가 참이면 진행상태 보존 재구성(reset_cache_resume!), 거짓이면 처음부터(reset_cache!) 캐시 재구성.
    resume ? reset_cache_resume!(env.cache, env.sched) : reset_cache!(env.cache, env.sched)
    return true                                 # 모두 성공하면 true 반환
end

"""
    engage_fallback!(env)

The **TERMINAL** fallback action: hold all agents (line stop). 🔴 **Not recoverable.**

This is NOT a nominal flag. `step_environment!` (route_planning.jl) reads `RESPEC_HOLD[]` every
step and zeroes every RVO agent's preferred velocity while it is up, so raising it physically
stops the line. Stopping is also the always-available safe action: zero velocity can never
carry an agent into a no-go zone, so no feasibility argument is needed to justify it.

🔴 **The effective semantics are "first fallback = permanent end of the run", and that is the
design** (user decision D-13, 2026-08-21). `RESPEC_HOLD[]` is a permanent process-global latch;
only `release_fallback!` clears it and **no production caller pairs with it — zero, by design**
(`release_fallback!`'s own docstring says "used by tests / resume paths"). Do NOT write, here or
anywhere, that the build keeps running past a fallback.

⚠️ **This docstring previously claimed "recoverable" and told callers to pair with
`release_fallback!`.** That was the SECOND instance of this exact failure shape in this
codebase — `verifier.jl` (RELOCATE_GATE) carried the same claim, resting on an opt-in
(`set_failclosed_stop!`) that no caller ever set, and was corrected 2026-08-18. Twenty lines
apart, twice. `test/respec_fallback_terminal.jl` now asserts the production-caller count is
zero, so this cannot rot back silently.

🔴 **Consequence for the SMDP / MCTS.** The latch is process-global and nothing resets it at a
rollout boundary (`src/smdp/state_globals.jl` classifies `:RESPEC_HOLD => :state` but there is
no reset function). One rollout that engages fallback poisons every later rollout in the same
process — silently, as a world where nothing moves. Measured 2026-08-21: running the SMDP/respec
test files in a single process leaves `RESPEC_HOLD = true` after `respec_grammar.jl` and the
next two files throw, while `smdp_tplan.jl`'s non-degeneracy assertion collapses to a single
distinct active set. A rollout-boundary reset of the `:state` globals is required before the
tree runs (report §8-4).

(요약) 실제로 라인을 **영구히** 멈춘다 — 복구 가능하지 않다. step_environment! 가 매 스텝
       RESPEC_HOLD 를 읽어 전 에이전트의 선호속도를 0 으로 만들고, 그것을 푸는 production
       호출자는 **0 개이며 그것이 설계다**. 트리를 굴리려면 롤아웃 경계 리셋이 따로 필요하다.
"""
function engage_fallback!(env)
    @warn "[RESPEC] FALLBACK engaged: holding all agents (line stop)."  # 모든 로봇을 멈춘다는 경고 로그
    RESPEC_HOLD[] = true                         # Ref 상자의 내용물을 true 로 설정 → "정지" 플래그 켜기
    return nothing                               # 반환값 없음(파이썬에서 return None 과 같음)
end

"Release the line-stop so the simulation resumes (used by tests / resume paths)."
function release_fallback!()
    RESPEC_HOLD[] = false
    return nothing
end

"Module-level fallback flag (stub for the Year-2 containment layer)."
# 모듈 수준 "정지" 플래그. true 면 시뮬레이션 루프가 모든 로봇을 멈춰야 한다는 신호.
const RESPEC_HOLD = Ref(false)

# Map a string node ref from the LLM back to a real schedule id. Built to MIRROR
# exactly how ids were stringified into the prompt (_build_prompt). Throwing here
# (unknown ref) is intentional -> treated as a reject.
# ref::AbstractString : LLM 이 준 문자열 id 한 개. 이 함수는 그 문자열을 실제 줄리아 id 객체로 되돌림(역변환).
function _default_id_resolver(env, ref::AbstractString)
    sched = env.sched                            # 스케줄 그래프
    for v in Graphs.vertices(sched)              # 모든 정점을 훑으며
        # 정점 id 를 문자열로 바꾼 게 ref 와 정확히 같으면(`==`) 그 정점의 id 객체를 반환.
        if string(get_vtx_id(sched, v)) == ref
            return get_vtx_id(sched, v)          # 찾은 노드 id 반환
        end
    end
    # Agent (robot) ids are NOT schedule vertex ids: a ForbidAgent needs a RobotID,
    # which lives on the entity of each RobotGo node, not in the vertex-id space.
    # Resolve those too, matching the exact string form open_agent_descriptors
    # exposed to the model (string(rid)), so a correctly-grounded ForbidAgent parses.
    # 위 루프에서 못 찾았다면(노드 id 가 아니라면) 로봇(RobotID)일 수 있으므로 다시 한 번 훑음.
    for v in Graphs.vertices(sched)
        node = get_node_from_id(sched, get_vtx_id(sched, v))  # 정점의 실제 노드 객체
        node isa RobotGo || continue                          # RobotGo 노드가 아니면 건너뜀
        rid = try entity(node).id catch; nothing end          # 그 노드의 로봇 id(실패 시 nothing)
        rid isa RobotID || continue                           # 진짜 RobotID 가 아니면 건너뜀
        # `A && return rid`: 로봇 id 의 문자열형이 ref 와 같으면 곧바로 그 RobotID 를 반환.
        string(rid) == ref && return rid
    end
    # 노드에서도 로봇에서도 못 찾으면 예외를 던짐 — 호출부(maybe_respecify!)는 이 예외를 "거부"로 취급(의도된 동작).
    error("LLM referenced unknown node/agent id: $ref")
end
