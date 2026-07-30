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

# ReformTeam: multi-robot team deadlock -> geometric re-establishment (reform_stuck_teams!),
# dispatched specially like ReplaceAgent/ForbidZone (no MILP).
# 제안에 ReformTeam(다중로봇 팀 교착 → 기하적 재구성)이 하나라도 있으면 true. MILP 없이 특수 처리됨.
_is_reform(p::RespecProposal) = any(c -> c isa ReformTeam, p.constraints)

"""
    _is_deprioritize(proposal) -> Bool

True iff the proposal is composed ONLY of `DeprioritizeAgent`s (a TIER-2 soft re-spec, e.g. a
battery-degradation OOD). Pure-soft proposals are dispatched specially: we register the bounded
cost bias and energy-aware re-solve, with NO feasibility risk. A proposal that MIXES a
DeprioritizeAgent with a hard spec is NOT caught here — it falls through to the relevant hard
dispatch / generic verify, where the DeprioritizeAgent compiles to a harmless no-op.
"""
# 제안이 "오직 DeprioritizeAgent 들"로만 이뤄졌으면 true(예: 배터리 저하 = TIER-2 soft 재명세). all=전부 참이어야 true.
_is_deprioritize(p::RespecProposal) =
    !isempty(p.constraints) && all(c -> c isa DeprioritizeAgent, p.constraints)

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
    maybe_respecify!(env, ood_queue; id_resolver, optimizer) -> Symbol

Called once per sim step from `simulate!` right after `step_environment!`.
Returns one of: `:noop`, `:admitted`, `:rejected`, `:fallback`. The return value
is purely for logging; the world state is mutated in place on `:admitted`.
"""
# `;` 뒤 두 인자는 키워드 인자이며 "= 기본값"이 붙어 있어 생략 가능.
# `ref -> _default_id_resolver(env, ref)` : `->` 는 익명함수(파이썬 람다 `lambda ref: ...`). 즉 기본 id 변환 함수.
# optimizer 기본값은 _respec_optimizer() 호출 결과(쓸 최적화 솔버).
# Classify an OOD event's safety criticality, used ONLY when we cannot obtain a
# typed proposal (LLM network / parse failure). SOFT/advisory events — a battery
# degradation (DeprioritizeAgent class) and the SPECULATIVE "team deadlocked"
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

# respec 파이프라인 본체: 큐에서 OOD 이벤트 하나를 꺼내 생성→검증→(종류별 특수)대응→재풀이→재개까지 처리.
# 반환값(:noop/:admitted/:rejected/:fallback)은 로깅용이며, :admitted 시 세계 상태를 실제로 바꿈.
function maybe_respecify!(env, ood_queue;
                          id_resolver = ref -> _default_id_resolver(env, ref),  # 기본 id 변환기(익명함수)
                          optimizer   = _respec_optimizer(),                    # 쓸 최적화 솔버
                          producer    = nothing)                                # 제안 생성기(없으면 LLM 경로)
    event = poll_ood!(ood_queue)                  # 큐에서 이벤트 하나 꺼냄(없으면 nothing)
    event === nothing && return :noop             # 처리할 이벤트가 없으면 아무것도 안 함(:noop) 반환

    @info "[RESPEC] OOD event: $event"            # @info : 정보 로그 출력 매크로. $event 로 값 보간.
    invariant = build_invariant(env)              # 이미 끝났거나 진행 중인 작업을 "고정(freeze)"한 불변식 구성

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

    # --- robot fault: dispatch to the reassign machinery ----------------------
    # A ForbidAgent re-spec needs schedule surgery (release pending edges) + the
    # frozen/pinned context that the generic verify path does not establish.
    # fault_robot_and_reassign! does freeze -> release -> ForbidAgent -> verify ->
    # commit, and rejects to the safe fallback if the future is not re-solvable.
    if _is_robot_fault(proposal)                 # 제안이 "로봇 한 대 고장(ForbidAgent 1개)"인 경우
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

    # --- restriction zone: dispatch to the geometric multi-assembly relocation --
    # A ForbidZone is SPATIAL (no MILP re-solve): the active zone(s) cover one or
    # more assemblies' staging areas. restage_all_blocked! relocates EVERY blocked
    # assembly clear of the zone (Phase a — not just the one named in the spec; the
    # set is detected geometrically). Like the robot-fault path, this is dispatched
    # specially because the generic verify/MILP gate can't express "move off a circle."
    # [한국어] ForbidZone(공간형) 대응: no-go 구역이 덮은 적치영역을 기하적으로 옮김(MILP 재풀이 아님).
    #   restage_all_blocked! 이 "구역이 덮은 모든 조립체"의 적치를 구역 밖으로 옮김(spec 이 지목한 하나만이 아님).
    if _is_zone_respec(proposal)
        # verify gate (static + zone-exists) BEFORE any geometric mutation — never trust the LLM.
        # 기하 변경 전에 먼저 검증(정적 검사 + 구역 실존) — LLM 을 절대 맹신하지 않음.
        zverdict = verify_zone(proposal, env)
        if zverdict isa Reject                    # 검증 거부면 안전 폴백
            monitor_record_verification!(status="rejected", checks=Any[
                Dict("name"=>"past_is_invariant", "passed"=>zverdict.reason != :touches_closed,
                     "detail"=>zverdict.detail),
                Dict("name"=>"zone_exists", "passed"=>zverdict.reason != :no_such_zone,
                     "detail"=>zverdict.detail),
            ], execution=Dict("action"=>"safe_fallback"),
               verdict="REJECTED · $(zverdict.reason)")
            @warn "[RESPEC] zone proposal REJECTED ($(zverdict.reason)): $(zverdict.detail) -> fallback"
            engage_fallback!(env)
            return :rejected
        end
        @info "[RESPEC] zone re-spec verified -> restage all blocked assemblies"
        res = restage_all_blocked!(env; resume = true)   # 막힌 조립체들의 적치를 전부 이동
        base_checks = Any[
            Dict("name"=>"typed_proposal", "passed"=>true,
                 "detail"=>"RespecProposal contains ForbidZone"),
            Dict("name"=>"past_is_invariant", "passed"=>true,
                 "detail"=>"proposal does not modify a closed schedule node"),
            Dict("name"=>"zone_exists", "passed"=>true,
                 "detail"=>"named zone exists in live RESTRICTION_ZONES"),
        ]
        # :residual_blocked = zone also covers the root's OWN (un-relocatable) deposit goals
        # — per-assembly moves can't clear the dense central core. Phase B: translate the
        # WHOLE build clear of the zone before giving up.
        # [한국어] :residual_blocked = 구역이 못 옮기는 중앙 core 목표까지 덮음 → Phase B: 빌드 전체를 통째로 평행이동.
        if res.status == :residual_blocked
            @info "[RESPEC] restage_all residual_blocked (residual $(get(res,:residual,0))) -> whole-build translate"
            wb = translate_whole_build!(env; resume = true)  # 빌드 전체를 구역 밖으로 평행이동
            if wb.status == :translated
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
                           "residual"=>get(res,:residual,0)),
            verdict=res.status == :none ? "ADMITTED · verified · navigation detour" :
                                          "ADMITTED · verified · assemblies restaged")
        return res.status == :none ? :noop : :admitted   # :none = zone covers no goal (detour-only)  # :none=목표 안 덮음(우회만) → noop
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
        # the faulted agent the LLM named; the SPARE is geometry's call, not the LLM's.
        # 고장 로봇은 LLM 이 지목, 예비(spare)는 기하가 결정. first(...) = 조건 맞는 첫 제약의 .agent 를 꺼냄.
        faulted = first(c for c in proposal.constraints if c isa ReplaceAgent).agent
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
        return :admitted
    end

    # --- multi-robot team deadlock: dispatch to geometric team re-establishment --
    # A ReformTeam is geometric surgery (no MILP): wedged teams get their straggler
    # members snapped into their carrying slots so the unit forms. The verify gate
    # admits ONLY if a mostly-formed-but-wedged team actually exists.
    # [한국어] ReformTeam(다중로봇 팀 교착) 대응: 교착된 팀의 낙오 멤버를 운반 슬롯에 끼워 팀을 재구성(MILP 없음).
    if _is_reform(proposal)
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

    # --- soft deprioritize (TIER-2): bounded objective bias, NO feasibility risk -
    # A DeprioritizeAgent (e.g. battery degraded) is feasibility-PRESERVING by construction:
    # it only re-prices the agent's edges, so it can never stall the build. We verify grounding
    # (agent exists, not closed; cheap, no solve), register the CLAMPED bias, and energy-aware
    # re-solve. If the re-solve (which the bias cannot make infeasible) still fails for an
    # unrelated reason, we fail closed to the safe fallback — defense in depth.
    # [한국어] DeprioritizeAgent(TIER-2 soft) 대응: 해당 로봇의 엣지 비용만 다시 매기므로 실행가능성을
    #   해칠 수 없음(빌드를 멈추게 못 함). grounding 만 검증 → 클램프된 bias 등록 → 에너지 인식 재풀이.
    if _is_deprioritize(proposal)
        dverdict = verify_deprioritize(proposal, env)
        if dverdict isa Reject
            @warn "[RESPEC] deprioritize proposal REJECTED ($(dverdict.reason)): $(dverdict.detail) -> no-op (build continues)"
            return :rejected            # soft spec: a bad one is just ignored; no line-stop needed  # soft 는 나빠도 그냥 무시
        end
        for c in proposal.constraints                    # 각 soft 제약에 대해
            f = deprioritize_agent!(c.agent, c.factor)   # CLAMPED to [1, MAX_AGENT_COST_BIAS]  # 비용 배수를 [1,상한]으로 클램프해 등록
            @info "[RESPEC] deprioritize $(c.agent): edge-cost ×$(round(f, digits=2)) (soft, feasibility-preserving)"
        end
        # bias 를 반영해 MILP 재구성(고정 시각 t0/tF 주입) 후 재풀이.
        milp = formulate_milp(
            SparseAdjacencyMILP(), env.sched, env.scene_tree;
            optimizer = optimizer, t0_ = invariant.frozen_t0, tF_ = invariant.frozen_tF)
        optimize!(milp)
        if primal_status(milp) != MOI.FEASIBLE_POINT     # bias 는 실행가능성을 보존하는데도 불가능하면(무관한 이유) 방어적 폴백
            @warn "[RESPEC] deprioritize re-solve infeasible (unexpected; bias preserves feasibility) -> fallback"
            engage_fallback!(env)
            return :fallback
        end
        if !commit_respec!(env, milp, proposal; resume = true)   # 재각인 커밋 실패 시 폴백
            @warn "[RESPEC] deprioritize commit re-stamp failed -> fallback"
            engage_fallback!(env)
            return :fallback
        end
        @info "[RESPEC] ADMITTED deprioritize: re-solved with $(length(proposal.constraints)) soft bias(es)."
        return :admitted
    end

    # --- verify (the gate; does the trial solve itself) -----------------------
    # verify(...) : 제안을 실제로 "시험 풀이(trial solve)"해 통과/거부를 판정하는 관문. 통과 못 하면 Reject 객체 반환.
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

Year-2 stub for the certified safe-set / containment layer. For the MVP this is
the trivial recoverable action: hold all agents (line stop). When CBF/HJ
reachability lands, replace the body with "drive to the nearest point in the
forward-invariant safe set"; the call site does not change.
"""
function engage_fallback!(env)
    @warn "[RESPEC] FALLBACK engaged: holding all agents (line stop)."  # 모든 로봇을 멈춘다는 경고 로그
    RESPEC_HOLD[] = true                         # Ref 상자의 내용물을 true 로 설정 → "정지" 플래그 켜기

    # L0 BACKUP CONTROLLER (safety/cbf.jl). Until now this function only set a flag that NOTHING
    # in the simulation loop ever read -- the fail-closed guarantee was nominal (see
    # docs/PATCHES.md:95, "make RESPEC_HOLD[] actually zero RVO preferred"). Routing through
    # `cbf_hold!` gives it real physical teeth: the L1 filter then commands zero velocity to
    # every agent, which is PROVABLY feasible (v=0 satisfies every CBF constraint while h>=0),
    # i.e. stopping is the always-available safe action a backup controller requires.
    #
    # OPT-IN ON PURPOSE. `engage_fallback!` is called from 14 sites, several of which currently
    # continue the build afterwards. Making the stop unconditional would silently change
    # fail-closed semantics repo-wide and halt demos/tests that presently run past a fallback.
    # So the teeth are gated on an explicit flag; turn it on with `set_failclosed_stop!(true)`.
    # (요약) 지금까지 이 함수는 아무도 안 읽는 플래그만 켰다 = 명목상 fail-closed. 이제 CBF 필터를
    #        통해 실제로 전 로봇을 정지시킬 수 있다(v=0 은 안전할 때 항상 실행가능하므로 원리적 보장).
    #        단 호출처가 14곳이라 무조건 켜면 기존 데모/테스트가 멈춘다 → 명시적 플래그로 opt-in.
    if FAILCLOSED_STOP[]
        cbf_hold!(true)
    end
    return nothing                               # 반환값 없음(파이썬에서 return None 과 같음)
end

"""
Opt-in switch that gives `engage_fallback!` real physical effect (L0 line-stop via the CBF
filter). Default `false` preserves the historical behaviour exactly.
"""
const FAILCLOSED_STOP = Ref(false)
set_failclosed_stop!(on::Bool = true) = (FAILCLOSED_STOP[] = on; nothing)

"Release both the nominal hold flag and the physical L0 stop (used by tests / resume paths)."
function release_fallback!()
    RESPEC_HOLD[] = false
    cbf_hold!(false)
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
