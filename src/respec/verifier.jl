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

    # (2b) GROUNDING — L2-a 문법이 참조하는 결정변수가 실제로 해석되는가.
    # 🔴 MILP 를 세우기 **전에** 본다: 해석 불가는 예외가 아니라 Reject 여야 한다
    #     (아래 grammar_ground_check 의 주석 참조 — 예외는 전이가 아니다).
    let rej = grammar_ground_check(proposal, env.sched)
        rej === nothing || return rej
    end

    # (3) FEASIBILITY — build the model WITH the proposal and the freeze
    # constraints, solve, and confirm a feasible point exists.
    # 🔴 build 를 try 로 감싼다(백스톱). (2b) 가 잡지 못하는 컴파일 오류 — 대표적으로 `:xa` 가
    #    후보 배정 엣지가 아닌 경우(Xa 는 formulate_milp 안에서만 존재한다) — 도 **Reject** 가
    #    되어야 한다. 여기서 예외가 새면 maybe_respecify!(replan.jl:953, try 없음)를 지나
    #    route_planning.jl:271 까지 풀려 올라가 시뮬 루프를 무너뜨린다.
    milp = try
        formulate_milp(                                  # 제안 + 고정조건을 넣은 MILP(혼합정수계획) 모델을 실제로 구성
            SparseAdjacencyMILP(), env.sched, env.scene_tree;  # 모델 종류, 스케줄, 장면트리
            optimizer = optimizer,                       # 사용할 솔버
            t0_ = invariant.frozen_t0,    # pin completed/in-progress work  # 완료/진행중 작업의 시작시각 고정
            tF_ = invariant.frozen_tF,                   # 완료 작업의 종료시각 고정
            warm_start_soln = warm_start, # optional: pre-fault assignment, for fast feasibility
            extra_constraints = proposal, # <-- the injected re-specification
        )
    catch err
        # 🔴 **좁게 잡는다.** 넓은 catch 는 방금 고친 결함의 거울상이다 — 우리 자신의 시끄러운
        #    내부 고장을 조용한 오분류로 바꾼다.
        #   (a) 제어 흐름 예외는 절대 삼키지 않는다.
        (err isa InterruptException || err isa StackOverflowError) && rethrow()
        #   (b) 제안에 LLM 이 쓴 제약이 하나도 없으면 이 실패는 **우리 컴파일러의 버그**다.
        #       그대로 던진다 — stacktrace 를 살려야 고칠 수 있고, 명목/oracle 레인의 고장이
        #       :ungrammatical line-stop 으로 위장되면 안 된다.
        _carries_llm_grammar(proposal) || rethrow()
        # 여기까지 온 것만 전이로 바꾼다: LLM 이 쓴 제약이 섞인 제안의 컴파일 실패.
        return Reject(:ungrammatical,
                      "constraint compilation failed: $(sprint(showerror, err))")
    end
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
    ZONE_DOMAIN_GATE[] :: Bool   ·   set_zone_domain_gate!(on)

VISIBILITY gate for `ForbidZone` (default **off**).

`ForbidZone` enacts `restage_all_blocked!`, which can only move assemblies that are non-root
AND not yet started (`zone_blocked_assemblies`). When that set is empty the enactment returns
`:none` and the run is BYTE-IDENTICAL to `NOOP`. That is the degeneracy that made every
mid-build zone decision a tie (measured: zoneblk 36/36 tied) — a wrong choice was invisible
because it looked exactly like restraint.

When ON, a `ForbidZone` naming a zone with an empty relocatable domain is REJECTED
(`:empty_domain`) instead of silently no-opping, so "the policy picked an arm that could not
act" becomes a distinguishable outcome in the logs and the labels.

**Off by default on purpose**, for the same reason as [`RELOCATE_GATE`](@ref): existing
oracle dumps were generated with the silent-no-op semantics, and flipping this globally would
retroactively change what the `ForbidZone` arm means (`:noop` -> `:rejected` + fallback) and
corrupt those labels. Turn it on for NEW label generation and for the decision-quality
measurement; leave it off to reproduce old dumps. `ZONE_DOMAIN_GATE=1` in the environment
turns it on for a whole process.

The DIAGNOSTIC is unconditional: the domain size is logged and reported on every zone
verification regardless of the gate, so the degeneracy is observable without changing behaviour.
"""
# ForbidZone 의 "조용한 no-op" 을 눈에 보이게 만드는 게이트(기본 꺼짐). 도메인(=옮길 수 있는 조립체 집합)이
# 비면 실행부가 :none 을 돌려주고 결과가 NOOP 과 바이트 동일해진다 → 오답이 절제와 구별되지 않는다.
# 켜면 그 경우를 :empty_domain 으로 명시 거절한다. 기본 꺼짐인 이유는 RELOCATE_GATE 와 같다 —
# 기존 오라클 덤프가 옛 의미(조용한 no-op)로 생성됐으므로 전역으로 켜면 라벨이 오염된다.
# 진단 로그는 게이트와 무관하게 항상 남는다(동작 변화 없이 관측만 가능).
const ZONE_DOMAIN_GATE = Ref(get(ENV, "ZONE_DOMAIN_GATE", "0") == "1")
set_zone_domain_gate!(on::Bool) = (ZONE_DOMAIN_GATE[] = on; nothing)

"""
    zone_domain_size(env, zone::Symbol) -> Int

How many assemblies a `ForbidZone` on `zone` could actually relocate right now — the size of
`zone_blocked_assemblies` restricted to that one zone key. `0` means the arm is a no-op.
Returns `-1` if the geometry query throws (unknown zone, no staging circles), so a caller can
tell "genuinely empty" from "could not be computed".
"""
# 지금 이 순간 ForbidZone 이 실제로 옮길 수 있는 조립체 수(0 이면 그 팔은 no-op). 기하 질의가 실패하면 -1.
function zone_domain_size(env, zone::Symbol)
    try
        return length(zone_blocked_assemblies(env; zone_keys = [zone]))
    catch e
        @warn "[VERIFY] zone_domain_size failed for :$(zone)" exception = e
        return -1
    end
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
  (3) DOMAIN (diagnostic always, rejecting only under [`ZONE_DOMAIN_GATE`](@ref)) — how many
      assemblies this zone could actually relocate (`zone_domain_size`). `0` means the arm is a
      silent no-op; with the gate on that is `Reject(:empty_domain)` rather than an admit that
      quietly does nothing.
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
            # (3) 도메인 진단: 지금 이 팔이 실제로 옮길 수 있는 조립체가 몇 개인가. 0 이면 실행부가
            #     :none 을 돌려주고 결과가 NOOP 과 바이트 동일해진다(= 오답이 절제처럼 보인다).
            #     로그는 게이트와 무관하게 항상 남기고, 거절은 ZONE_DOMAIN_GATE 가 켜졌을 때만 한다
            #     (기본 꺼짐 — 옛 덤프의 라벨 의미를 소급해서 바꾸지 않기 위해. 위 게이트 주석 참조).
            local n_dom = zone_domain_size(env, cs.zone)
            if n_dom == 0
                @info "[VERIFY] ForbidZone :$(cs.zone) has an EMPTY relocatable domain " *
                      "-> enactment will be a silent no-op (byte-identical to NOOP)" *
                      (ZONE_DOMAIN_GATE[] ? " -> REJECTED (ZONE_DOMAIN_GATE on)" :
                                            " -> admitted anyway (ZONE_DOMAIN_GATE off)")
                ZONE_DOMAIN_GATE[] &&
                    return Reject(:empty_domain,
                        "ForbidZone for zone :$(cs.zone) can relocate 0 assemblies " *
                        "(none are both non-root and not-yet-started) — the arm cannot act; " *
                        "a whole-build RelocateBuild is the only spatial lever left, and it is " *
                        "worth its cost only if the zone swallows root deposit goals")
            else
                # 지목한 조립체가 실제 막힌 집합에 없어도 거절하지 않는다 — restage_all_blocked! 는
                # spec 이 지목한 하나가 아니라 기하로 탐지한 집합 전체를 옮기므로 그래도 동작한다.
                # 다만 grounding 오류는 기록해 둔다(LLM 품질 신호).
                @debug "[VERIFY] ForbidZone :$(cs.zone) domain = $(n_dom) relocatable assemblies"
            end
        end
    end
    return Admit(proposal, length(proposal.constraints))  # 통과 → 채택
end

"""
    RELOCATE_GATE[] :: Bool   ·   set_relocate_gate!(on)

PROPORTIONALITY gate for `RelocateBuild` (default **off**).

A whole-build rigid translation is global and irreversible: it moves every future goal and
staging circle at once, while carriers are mid-transit. Measured on the tractor twin
(2026-08-05, same seed, same zones, MACRO CROSSED — `tools/monitor/streams/tractor__zoneA2_forbid`
vs `…__zoneB_relocate` / `…__zoneBp_forced_relocate`):

| enacted macro | closed | assemblies done |
|---|---|---|
| ForbidZone (domain empty ⇒ effectively no-op) | **231** | **7/8** |
| RelocateBuild (Δ = 3.22 m) | **136** | **1/8** |

The two RelocateBuild runs differ only in WHICH POLICY emitted it (LLM vs a forced rule) and
came out byte-identical (same Δ to 15 digits), so the loss is the macro's, not the policy's.

When ON, a `RelocateBuild` is admitted only if the named zone actually swallows ROOT deposit
goals — the goals no per-assembly restage can rescue (`root_goal_coverage`). A zone that only
clips a sub-assembly's staging area is repairable locally (or absorbed by the motion stack),
so paying a global move for it is disproportionate and the gate rejects it. Rejection is a
NO-OP FOR THE GEOMETRY — nothing is moved — but it is NOT a no-op for the run: the reject path
calls `engage_fallback!`, which raises `RESPEC_HOLD` and `step_environment!` reads that flag
every step to zero every agent's preferred velocity, so the line stops until something calls
`release_fallback!`. (This docstring previously claimed the build keeps running, on the strength
of an opt-in `set_failclosed_stop!` that no caller ever set; the claim was wrong about which
mechanism carries the stop. Corrected 2026-08-18 alongside the removal of `safety/cbf.jl`.)

**Off by default on purpose.** The oracle/dataset path (`gen_oracle_dataset.jl`, arms `[0,7]`)
MEASURES the RelocateBuild arm on exactly these non-core zones and found it ~2x better than
NOOP in that setting (`md/RELOCATEBUILD_2026-08-03.md`). Turning the gate on globally would
silently convert that arm into a rejected no-op and corrupt the labels. The live demo turns it
on explicitly (`tools/monitor/render_demo.jl`), which is also where the harm above was measured.
`RELOCATE_GATE=1` in the environment turns it on for a whole process.
"""
const RELOCATE_GATE = Ref(get(ENV, "RELOCATE_GATE", "0") == "1")
set_relocate_gate!(on::Bool) = (RELOCATE_GATE[] = on; nothing)

"""
    verify_relocate(proposal, env) -> Verdict

The verify gate for a `RelocateBuild` proposal (whole-build rigid translation clear of a
no-go zone), which bypasses the generic MILP `verify` exactly as `verify_zone` does — a
uniform shift of every `start_config` is geometry, not a scheduling constraint. Cheap,
authoritative checks before any mutation:
  (1) STATIC — no constraint references an already-closed node. `RelocateBuild` names no
      node at all (`referenced_ids` is empty), so this only bites on a MIXED proposal.
  (2) ZONE-EXISTS — the named `zone` Symbol is a live key of `RESTRICTION_ZONES`. The LLM
      names a zone; the GEOMETRY is authoritative (never trust the LLM's key).
  (3) MOVABLE — `env.staging_circles` is non-empty. With no staging circles on record
      `translate_whole_build!` has nothing to shift (`:no_staging`), so admitting would
      guarantee a wasted mutation-free fallback.
Recovery feasibility is deliberately NOT decided here: `translate_whole_build!` reports
`:residual_blocked` / `:infeasible` and the caller engages the safe fallback, so an
admissible-but-unrecoverable relocation still fails closed. Same division of labour as
`verify_zone` — the gate is cheap and static, feasibility is the enactment's answer.
"""
# RelocateBuild(빌드 전체 평행이동) 전용 게이트. MILP 대신 기하로 처리하므로 verify_zone 과 같은 구조의 싼 검사만
# 한다: (1) 과거 노드 참조 금지(RelocateBuild 자체는 노드를 안 지목하므로 혼합 제안에서만 작동),
# (2) 이름댄 구역이 RESTRICTION_ZONES 에 실제로 존재, (3) 옮길 적치원이 하나라도 있음.
# 복구가 실제로 성공하는지는 여기서 판단하지 않는다 — translate_whole_build! 가 :residual_blocked/:infeasible
# 을 돌려주면 호출자가 안전 폴백을 건다(= 허용됐지만 복구 불가한 경우도 결국 닫히는 쪽으로 실패).
function verify_relocate(proposal::RespecProposal, env)
    invariant = build_invariant(env)                     # 현재 얼린 과거(완료 노드 등)
    for cs in proposal.constraints                       # 제안의 각 제약에 대해
        for id in referenced_ids(cs)                     # 그 제약이 건드리는 노드 ID 들
            id in invariant.closed_nodes &&              # 이미 끝난 노드를 참조하면 거절
                return Reject(:touches_closed, "relocate spec references closed node $(id)")
        end
        if cs isa RelocateBuild                          # RelocateBuild 이면
            haskey(RESTRICTION_ZONES[], cs.zone) ||      # 이름댄 구역이 실제 지오메트리에 없으면 거절
                return Reject(:no_such_zone, "RelocateBuild names zone :$(cs.zone) absent from RESTRICTION_ZONES")
            # (4) 비례성(opt-in, RELOCATE_GATE 주석 참조): 전역 이동은 **국소 복구로 못 구하는 것**이
            #     실제로 위협받을 때만 값을 한다. 그 판정은 기하로 한다.
            #     2026-08-05: 그 "국소로 못 구하는 것"은 root 하역 목표만이 아니다 — 형성 중인 운반팀의
            #     집결지/운반 슬롯이 구역에 잠기면 그 팀도 제자리에서는 절대 못 모인다(그 경우 snap 은
            #     recover_stalled_teams! 이 거부하므로 남는 수복은 공간 이동뿐이다). 그래서 두 술어를
            #     **같은 계산기**(zone_diagnosis)에서 읽는다 — 게이트와 라벨이 서로 다른 기하를 보면
            #     "규칙은 옮기라는데 게이트가 막는" 조용한 불일치가 난다.
            #
            #     2026-08-05(막힘 술어 배선): 여기에 **세 번째 술어**를 더한다 — `n_nav_blocked`.
            #     위 두 개는 전부 COVERAGE(무엇을 덮었나)이고, 그것만 보는 게이트는 zone_corridor.jl 이
            #     규명한 케이스를 구조적으로 못 본다: root 를 하나도 안 덮고(root_covered=0) 형성 중인
            #     팀도 없는데(n_teams_covered=0) **RVO 로 움직이는 주체의 목표를 실제로 막는** 구역이다.
            #     그 구역에서 유일한 수복이 RelocateBuild 인데 옛 조건은 그걸 :disproportionate 로
            #     거절했다 = 고칠 수 있는 사건을 게이트가 죽인다. 조건에 ∧ 을 하나 더 붙이는 것이므로
            #     방향은 **좁아지는 쪽**(과잉 거절만 줄어듦)이고 기존 admit 경로는 그대로다.
            #     (blockage 계산이 실패하면 -1 이라 이 항은 거짓 → 거절 안 함 = fail-open.)
            if RELOCATE_GATE[]
                local zd = try
                    zone_diagnosis(env, cs.zone; check_restage = false)   # 비싼 스캔은 여기서 불필요
                catch e
                    @warn "[VERIFY] zone_diagnosis failed -> proportionality gate skipped" exception = e
                    nothing
                end
                (zd !== nothing && zd.root_covered == 0 && zd.n_teams_covered == 0 &&
                 zd.n_nav_blocked == 0) &&
                    return Reject(:disproportionate,
                        "RelocateBuild for zone :$(cs.zone) swallows 0/$(zd.root_total) root deposit goals, " *
                        "traps 0/$(zd.n_teams_forming) forming team(s) and blocks 0/$(zd.n_nav_goals) " *
                        "navigable goals — nothing un-relocatable is threatened, so a whole-build move " *
                        "costs more than it saves")
            end
        end
    end
    isempty(env.staging_circles) &&                      # 옮길 대상 자체가 없으면 거절(translate 는 :no_staging 반환)
        return Reject(:no_staging, "RelocateBuild but env.staging_circles is empty — nothing to translate")
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

# =============================================================================
# 2026-08-21 (Task C2 · 수정 라운드 2) — 참조 접지 검사: **예외가 아니라 Reject**
# -----------------------------------------------------------------------------
# 🔴 왜 이게 있어야 하는가. `(t0, tF, Xa)` 를 LLM 에게 연 순간, **파싱은 되는데 컴파일에서
#    죽는** 입력이 도달 가능해졌다. 대표 사례: `VarRef(:t0, <agent id>)` —
#    `_default_id_resolver`(replan.jl:1146-1157)가 AGENTS 목록의 문자열을 `RobotID` 로
#    정상 해석해 주지만, `get_vtx(sched, ::RobotID)` 는 **-1** 이다(RobotID 는 정점 id 가 아니다).
#    그러면 `_var_of` 의 `error()` 가 `formulate_milp` → `verify()` → `maybe_respecify!`
#    (replan.jl:953, **try 없음**) → `respec_step!` → `route_planning.jl:271` 까지 그대로
#    풀려 올라가 **시뮬 루프를 무너뜨린다.**
#
# 🔴 그것은 이 태스크가 딛고 선 계약과 정면으로 어긋난다 —
#    "`verify()` 는 전이함수의 문이고 거부는 NOOP 과 같은 전이"(llm_bridge.jl:62).
#    예외는 전이가 아니라 **전이의 부재**다. 모든 행동이 전이로 사상돼야 하는 SMDP 에서
#    파싱되는 행동이 전이를 못 내면 그건 안전장치가 아니라 모형의 구멍이다.
#
# 🔴 remap 하지 않는다(조용한 폴백 금지). 그 규칙이 금지하는 것은 **성공한 척하기**이지
#    **실패를 분류하기**가 아니다. `Reject(:unresolvable_reference, …)` 는 시끄럽고,
#    로그에 남고, 감사 가능하며, 전이함수가 정의된 결과다.
# =============================================================================

"formulate_milp 의 시간변수 Big-M 기본값(essential_tg_coponents.jl:1059 `Mm=10000`).
 시간변수의 실효 상한으로 쓴다 — Disjunction 의 Big-M 이 실제로 완화 역할을 하는지 볼 때."
const _MILP_VAR_BOUND = 1.0e4

# VarRef 하나가 이 스케줄에서 해석 가능한가.
# 반환: `nothing`(문제 없음) 또는 `(reason::Symbol, detail::String)`.
# 🔴 사유 심볼을 문제 **종류별로** 나눈다 — 감사에서 reason 으로 묶을 때 서로 다른 실패가
#    한 통에 섞이면 안 된다(참조 미해석 vs 계수 크기는 원인도 대응도 다르다).
function _varref_problem(sched, r::VarRef)
    get_vtx(sched, r.node) > 0 ||
        return (:unresolvable_reference,
                "VarRef($(r.kind)) references $(r.node), which is not a schedule vertex " *
                "(get_vtx -> $(get_vtx(sched, r.node))). Agent ids are NOT vertex ids.")
    if r.node2 !== nothing
        get_vtx(sched, r.node2) > 0 ||
            return (:unresolvable_reference,
                    "VarRef(:xa) references $(r.node2), which is not a schedule vertex " *
                    "(get_vtx -> $(get_vtx(sched, r.node2))).")
    end
    return nothing
end

# LinearConstraint 하나의 접지 + 크기 검사. `bigm` 이 주어지면 Big-M 완화가 실제로
# 완화인지도 본다(아래 Disjunction 참조).
function _linear_problem(sched, cs::LinearConstraint; bigm = nothing)
    for (_, r) in cs.terms                    # Vector 순회 = 결정적
        p = _varref_problem(sched, r)
        p === nothing || return p
    end
    if bigm !== nothing
        # 🔴 Big-M 이 계수에 대해 충분히 큰가. `_DISJ_BIGM` 은 `ForbidWindow` 와 같아야 해서
        #    고정이다(문법 왕복이 그 위에 선다). 그래서 상수를 키우는 대신 **계수를 거부**한다.
        #    보수적 상계: |Σ c·var − rhs| ≤ Σ|c|·VAR_BOUND + |rhs|.
        #    이걸 안 하면 큰 계수에서 "완화된" 쪽이 완화가 아니게 되어 ∨ 가 조용히 ∧ 로 조인다.
        span = sum(abs(c) for (c, _) in cs.terms) * _MILP_VAR_BOUND + abs(cs.rhs)
        span <= bigm ||
            return (:bigm_overflow,      # 🔴 참조 문제가 아니라 **계수 크기** 문제다. 사유를 분리한다.
                    "Disjunction half is too large for the Big-M relaxation: " *
                    "Σ|c|·$(_MILP_VAR_BOUND) + |rhs| = $(span) > M = $(bigm). " *
                    "Use smaller coefficients — widening M would break ForbidWindow equivalence.")
    end
    return nothing
end

"""
    grammar_ground_check(proposal, sched) -> Union{Nothing,Reject}

L2-a 문법(`LinearConstraint`·`Disjunction`)이 참조하는 결정변수를 **MILP 를 세우기 전에**
전부 해석해 본다. 통과하면 `nothing`, 아니면 `Reject` 를 돌려준다 — **예외가 아니다.**

다른 kind 들은 이 검사에 해당 없음(`nothing`)이다: 그들의 접지는 이미 각자의
`verify_*` 와 `verify()` 2단계(과거불가침)가 본다.

⚠️ `:xa` 후보 엣지 여부는 여기서 못 본다 — `Xa` 는 `formulate_milp` 안에서만 존재한다.
   그래서 (a) `:xa` 는 **LLM emit 대상에서 뺐고**(llm_bridge.jl `EMITTABLE_VARREF_KINDS`),
   (b) `verify()` 3단계의 build 를 `try` 로 감싸 어떤 컴파일 오류도 `Reject` 가 되게 했다.
"""
function grammar_ground_check(proposal::RespecProposal, sched)
    for cs in proposal.constraints                    # Vector 순회 = 결정적
        p = if cs isa LinearConstraint
            _linear_problem(sched, cs)
        elseif cs isa Disjunction
            something(_linear_problem(sched, cs.left;  bigm = _DISJ_BIGM),
                      _linear_problem(sched, cs.right; bigm = _DISJ_BIGM),
                      Some(nothing))
        else
            nothing
        end
        p === nothing || return Reject(p[1], p[2])     # p = (reason, detail)
    end
    return nothing
end

"""
    _carries_llm_grammar(proposal) -> Bool

제안이 **LLM 이 직접 쓴 제약**(`LinearConstraint`/`Disjunction`)을 하나라도 담고 있는가.

🔴 `verify()` 3단계의 build 백스톱이 이 술어로 갈린다. 그 술어가 정확히 두 세계를 가른다:
  * 참이면 — 컴파일 실패의 원인이 **LLM 이 쓴 제약**일 수 있다 → `Reject` 가 옳다(전이).
  * 거짓이면 — 하드코딩된 kind 만 들어 있다 → 컴파일 실패는 **우리 컴파일러의 버그**다.
    그걸 `Reject` 로 재분류하면 명목/oracle 레인의 진짜 고장이 엉뚱한 사유의 line-stop 으로
    **위장**된다(예: `reassign.jl:387` 의 내부 `ForbidAgent` 경로). 거기서는 시끄럽게 죽는 게 맞다.
"""
_carries_llm_grammar(p::RespecProposal) =
    any(c -> c isa LinearConstraint || c isa Disjunction, p.constraints)

# --- which schedule ids does a spec touch (for the closed-node check) ---------
# 제약이 어떤 노드 ID 들을 건드리는지 돌려주는 함수. cs 의 "타입에 따라" 다른 메서드 실행(다중 디스패치).
# `(x,)` : 원소 1개짜리 튜플(파이썬과 동일하게 쉼표 필요). 결과를 항상 순회 가능한 묶음으로 통일.
referenced_ids(cs::ForbidWindow) = (cs.node,)    # 시간창 제약은 그 대상 작업 노드 하나를 건드림
referenced_ids(cs::ForbidAgent)  = (cs.agent,)   # 로봇금지 제약은 그 로봇(agent) 하나를 건드림
referenced_ids(cs::ForbidZone)   = (cs.assembly,)  # 구역 제약은 (grounding 한) 그 막힌 조립체 하나를 건드림
referenced_ids(cs::ReplaceAgent) = (cs.agent,)   # 교체 제약은 고장난 그 로봇(agent) 하나를 건드림
referenced_ids(cs::ReformTeam)   = ()            # 팀 재정립은 특정 노드를 안 지목(기하가 막힌 팀을 찾음)
referenced_ids(cs::RelocateBuild) = ()           # 빌드 전체 평행이동은 특정 노드를 안 지목(구역 키만 지목)
referenced_ids(cs::DeprioritizeAgent) = (cs.agent,)  # 소프트 회피 제약은 그 로봇(agent) 하나를 건드림
referenced_ids(cs::SwapBattery)  = (cs.agent,)   # 배터리 교체는 그 로봇(agent) 하나를 건드림

# 2026-08-21 (Task C2 · L2-a 문법). LLM 이 직접 쓴 선형 제약이 건드리는 노드들.
# 🔴 `verify()` 2단계(과거불가침)가 이걸 그대로 쓴다 — 여기서 id 를 빠뜨리면 LLM 이
#    이미 끝난 노드를 재시간화하는 제약을 조용히 통과시킬 수 있다. `node2`(:xa 의 두 번째
#    끝점)까지 반드시 센다. 순회 대상이 Vector 뿐이라 순서가 결정적이다(Set/Dict 없음).
referenced_ids(cs::LinearConstraint) =
    Tuple(unique(vcat([r.node for (_, r) in cs.terms],
                      [r.node2 for (_, r) in cs.terms if r.node2 !== nothing])))
referenced_ids(cs::Disjunction) =
    Tuple(unique(vcat(collect(referenced_ids(cs.left)), collect(referenced_ids(cs.right)))))

"""
    verify_swap_battery(proposal, env) -> Verdict

Gate for a `SwapBattery` proposal. Cheaper than [`verify_replace`](@ref) because a battery
swap consumes NO scarce resource: there is no spare-exists check to make. Two checks:
  (1) STATIC — the named agent is not an already-closed node ("the past is invariant").
  (2) GROUNDING — the agent exists as a physical robot in the scene. Never trust the LLM's id.

Note what is deliberately NOT checked: whether the robot is actually low on charge. Swapping
a healthy robot's battery is WASTEFUL, not UNSAFE — it costs time and changes nothing else.
Waste belongs in the objective (via the macro cost), not in a safety gate; rejecting it here
would hide the decision the surrogate is supposed to learn to make.
"""
# SwapBattery 전용 게이트. 희소자원을 안 쓰므로 verify_replace 보다 검사가 적다(spare 존재 검사 없음).
#   (1) 과거(닫힌) 노드 참조 금지  (2) 그 로봇이 실제로 씬에 존재하는지(LLM id 맹신 금지).
# 일부러 안 보는 것: "정말 방전됐는가". 멀쩡한 로봇의 배터리를 가는 건 낭비지 위험이 아니다 —
#   낭비는 목적함수(매크로 비용)에서 다뤄야 하고, 여기서 거부하면 surrogate 가 배워야 할 결정을 숨기게 된다.
function verify_swap_battery(proposal::RespecProposal, env)
    invariant = build_invariant(env)                     # 현재 얼린 과거
    for cs in proposal.constraints
        for id in referenced_ids(cs)
            id in invariant.closed_nodes &&
                return Reject(:touches_closed, "swap-battery spec references closed node $(id)")
        end
        if cs isa SwapBattery
            has_vertex(env.scene_tree, cs.agent) ||      # 씬에 없는 로봇 = grounding 실패
                return Reject(:no_such_agent, "SwapBattery($(cs.agent)) but no such robot in the scene")
        end
    end
    return Admit(proposal, length(proposal.constraints))
end

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
"""
    _form_unit_after(sched, v; max_hops=8) -> FormTransportUnit | nothing

The `FormTransportUnit` a `RobotGo` at vertex `v` is ultimately heading into, following a
CHAIN of consecutive `RobotGo` nodes — not just the immediate successor.

WHY THIS EXISTS (measured 2026-08-05, `tools/e2e.jl mock_respec`). All three team-detection
sites in the respec layer (`verify_reform`, `reform_stuck_teams!`,
`diagnose_transport_stall`) iterated `cache.active_set` and tested `outs[1] isa
FormTransportUnit` — ONE hop, FIRST successor only. At the root endgame the only ACTIVE
`RobotGo` was `v246`, whose successor is another `RobotGo` (`v267`), and it is *that* node
that feeds the `FormTransportUnit`. So all three reported "NO team forming", `ReformTeam` was
rejected with `:no_wedged_team`, and the build stalled at 270/289 with the one recovery that
could have fixed it structurally unable to see the team.

The navigation layer already does this correctly: `swap_first_paralyzed_transport_unit!`
(route_planning.jl) walks `while outdegree >= 1 && matches_template(RobotGo, next_node)`.
This helper is that traversal, made shared so the three respec sites cannot drift apart again.

Also scans ALL out-neighbours rather than `outs[1]`: a node can have several successors
(e.g. `DepositCargo -> [LiftIntoPlace, RobotGo]`), so indexing the first is fragile even
without the chain. `max_hops` bounds the walk so a malformed graph cannot loop forever.
"""
# 어떤 RobotGo 가 (연속된 RobotGo 들을 거쳐) 최종적으로 들어가는 FormTransportUnit 을 찾아준다.
# 왜 필요한가(2026-08-05 실측): respec 층의 팀 탐지 3곳이 전부 "후행 **하나**만" 보고 판단해서,
# 활성 RobotGo 의 후행이 또 RobotGo 인 루트 엔드게임에서 팀을 못 찾았다 → ReformTeam 이 거절되고
# 270/289 에서 정체. 항법층(swap_first_paralyzed_transport_unit!)은 원래 체인을 걸어간다 — 그 순회를
# 공용 헬퍼로 뽑아 세 곳이 다시 어긋나지 않게 한다. 후행이 여러 개일 수 있으므로 outs[1] 대신 전부 훑고,
# max_hops 로 걸음 수를 묶어 잘못된 그래프에서도 무한루프가 안 나게 한다.
function _form_unit_after(sched, v; max_hops::Int = 8)
    outs = Graphs.outneighbors(sched, v)
    for _ in 1:max_hops
        isempty(outs) && return nothing
        nxt_robotgo = nothing
        for u in outs
            nu = get_node_from_id(sched, get_vtx_id(sched, u))
            nu isa FormTransportUnit && return nu          # 찾았다
            (nxt_robotgo === nothing && nu isa RobotGo) && (nxt_robotgo = u)  # 이어갈 RobotGo 후보
        end
        nxt_robotgo === nothing && return nothing          # RobotGo 체인이 끊겼다 → 이 갈래엔 팀이 없음
        outs = Graphs.outneighbors(sched, nxt_robotgo)     # 한 칸 더 걸어간다
    end
    return nothing
end

function verify_reform(proposal::RespecProposal, env)
    # 제안에 ReformTeam 이 하나도 없으면 검사할 것 없이 통과.
    any(c -> c isa ReformTeam, proposal.constraints) || return Admit(proposal, length(proposal.constraints))
    sched = env.sched; st = env.scene_tree               # 스케줄·씬트리를 짧은 이름으로
    wedged = false                                       # "막힌 팀을 찾았나" 플래그
    for v in env.cache.active_set                        # 진행중 정점들을 순회
        n = get_node_from_id(sched, get_vtx_id(sched, v))
        n isa RobotGo || continue                        # RobotGo 가 아니면 건너뜀
        # 후행 "하나"가 아니라 RobotGo 체인을 걸어가 FormTransportUnit 을 찾는다(_form_unit_after 주석 참조).
        nxt = _form_unit_after(sched, v)
        nxt === nothing && continue                      # 이 갈래 끝에 운반팀 형성이 없으면 건너뜀
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
        nxt = _form_unit_after(sched, v)                 # RobotGo 체인을 걸어가 팀 형성 노드를 찾음
        nxt === nothing && continue
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
