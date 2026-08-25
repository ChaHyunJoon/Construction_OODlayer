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
    RelocateBuild(zone)

"A no-go zone covers work the build CANNOT relocate piecemeal, so shift the ENTIRE
build clear of it." The SECOND spatial spec, and the one that exists because
`ForbidZone` has an empty domain for most of a run.

WHY A SEPARATE KIND (measured 2026-08-03, oracle/out/zdiag*). `ForbidZone` enacts
`restage_all_blocked!`, which can only move an assembly whose build steps have not
started (`_assembly_started` ⇒ `restage_assembly!` refuses with `:already_started`).
Counting that predicate along a real build: 7 non-root staging circles are eligible at
`closed=0` and **zero** from `closed≈46` onward — the restageable set empties at the
first batch boundary and never returns. Every `ForbidZone` fired after that point is a
silent no-op (byte-identical to NOOP; `[RESTAGE-ALL]` never logs). No firing WINDOW
fixes this, because the precondition is destroyed by build progress itself, not by
timing.

`translate_whole_build!` (restage_zone.jl) has NO such precondition: it reads
`_future_work_discs` — goals the unfinished schedule still has to reach plus non-root
staging workspaces — which is gated on `closed_set` only, never on `_assembly_started`.
So it stays non-empty for essentially the whole build. The mechanism is a single rigid
Δ applied to every assembly's `start_config` (each subtree carries its staging AND its
components' deposit goals), so the schedule shifts with no internal desync and NO MILP
re-solve; the zone itself is left exactly where it is.

Tier: SPATIAL, like `ForbidZone` — not a MILP `@constraint` over (t0,tF,Xa). Dispatched
specially in `maybe_respecify!` (`_is_relocate_build`, checked BEFORE the ForbidZone
branch so a mixed proposal takes the stronger lever). Safety is in the gate
(`verify_relocate`): admitted only if the named zone exists AND the geometry can be
moved at all; enactment then fails closed on `:residual_blocked`/`:infeasible`.

`zone` is the key in `RESTRICTION_ZONES`, echoed exactly as `ForbidZone.zone` is.
Unlike `ForbidZone` it names NO assembly — the whole build moves, so there is no
per-assembly grounding for the LLM to get wrong.
"""
# 의미: "no-go 구역이 조각조각 옮길 수 없는 작업까지 덮었으니, 빌드 **전체**를 통째로 비켜 옮긴다."
#   왜 ForbidZone 과 별도 종류인가(2026-08-03 실측): ForbidZone→restage_all_blocked! 은 "아직 build step 이
#   하나도 안 열린 조립체"만 옮길 수 있는데, 그 집합이 closed≈46(첫 배치 경계)에서 전멸하고 다시 돌아오지
#   않는다 → 그 뒤의 ForbidZone 은 전부 조용한 no-op(=NOOP 과 바이트 동일). 창을 어디로 옮겨도 안 되는 이유는
#   전제조건을 시점이 아니라 "빌드 진행 자체"가 파괴하기 때문.
#   translate_whole_build! 은 그 전제조건이 없다: _future_work_discs 는 closed_set 만 보고
#   _assembly_started 게이트가 없어서 빌드 내내 비지 않는다. 구역은 그대로 두고 작업영역 전체가 Δ 만큼
#   평행이동한다(MILP 재풀이 없음). 안전은 verify_relocate 게이트 + 실행 결과(:residual_blocked/:infeasible)에서.
struct RelocateBuild <: ConstraintSpec
    zone::Symbol          # 비켜야 할 대상 제한구역의 키(RESTRICTION_ZONES 의 키). ForbidZone.zone 과 같은 규약.
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
    SwapBattery(agent)

"Robot `agent`'s battery is depleted; swap the battery IN THE FIELD." The SAME physical
body keeps working with a fresh pack — no depot spare is consumed, only time and cost.

WHY THIS IS A SEPARATE ACTION FROM `ReplaceAgent`
-------------------------------------------------
The two consume DIFFERENT resources, so preferring one over the other is a genuine
decision rather than a relabelling:

    ReplaceAgent — consumes a depot BODY (a scarce, counted spare), asset generation +1
    SwapBattery  — consumes a BATTERY (unmetered, cost only), asset generation unchanged

That difference is the whole point. A depleted robot can be revived cheaply; spending a
scarce chassis on a flat battery wastes the spare that a later MECHANICAL failure will
need. Conversely a battery swap does nothing for a broken drivetrain. So the right answer
depends on the failure's cause AND on how much of the build is left — which is exactly the
kind of within-kind decision structure the surrogate is supposed to learn.

Enacted by `swap_battery!` (replace_robot.jl): restore SoC, clear the stall/deplete gates,
record a `:battery_swap` row in the asset ledger. No schedule mutation and no scene-tree
surgery — the body never changes, so this is the least invasive recovery in the vocabulary.
"""
# 의미: "로봇 `agent` 의 배터리가 방전됐다 → 현장에서 배터리만 교체한다." 같은 본체가 새 팩으로 계속 일함.
#   창고 예비 "본체"를 안 먹고 시간·비용만 든다.
#
#   왜 ReplaceAgent 와 별개의 액션인가: 둘은 소모 자원이 다르다 —
#     ReplaceAgent = 창고 본체(희소·개수 셈) 소모, 자산 세대 +1
#     SwapBattery  = 배터리(무제한, 비용만) 소모, 세대 그대로
#   방전된 로봇은 싸게 살릴 수 있는데 거기에 귀한 본체를 쓰면, 나중에 진짜 기계고장이 났을 때 쓸
#   예비가 없어진다. 반대로 구동계가 망가진 로봇에 배터리를 갈아봐야 소용없다. 그래서 정답이
#   "원인 + 남은 빌드량"에 따라 갈리고, 이게 surrogate 가 배워야 할 kind 내부 결정 구조다.
#
#   실행: swap_battery!(replace_robot.jl) — SoC 복구 + stall 게이트 해제 + 장부에 :battery_swap 기록.
#   스케줄도 씬트리도 안 건드림(본체가 안 바뀌므로) = 어휘 중 가장 침습적이지 않은 복구.
struct SwapBattery <: ConstraintSpec
    agent::AbstractID   # 배터리를 갈아 끼울 로봇 ID
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

# 🔴 2026-08-24 (spec §5.4, Task 5): `DeprioritizeAgent` (TIER-2 soft objective-bias) 는 여기서
#   **완전히 삭제됐다** — 타입·컴파일 메서드·verify 게이트·dispatch 분기 전부. 레지스트리에서는
#   2026-08-20 에 이미 빠졌다(제안 338회 대비 선택 0회; 이 하니스의 배터리 사건은 저하가 아니라
#   정지(SoC 0)라 degraded-but-alive 상태가 없다). 그래서 TIER 2 는 지금 **비어 있다** — 위
#   DESIGN INVARIANT 의 2-tier 서술은 역사로 읽을 것.
#   ⚠️ 소프트 비용편향 **기전** 자체(`deprioritize_agent!` / `AGENT_COST_BIAS`,
#   essential_tg_coponents.jl)는 살아 있다 — 없어진 것은 그것을 LLM/DSL 이 부르는 문법이다.

# =============================================================================
# 2026-08-21 (Task C2 · spec §5-4) — L2-a: MILP 결정변수 위의 **제약 문법**
# -----------------------------------------------------------------------------
# 여기까지의 kind 들은 전부 "누군가 미리 짜 둔 매크로"다. 아래 셋은 다르다: LLM 이
# `(t0, tF, Xa)` 위의 **선형 제약 하나를 직접 쓴다**. `ForbidWindow`·`ForbidAgent` 는
# 이 문법의 인스턴스이지 별개의 종류가 아니다 —
#   ForbidWindow(v, lo, hi)  ==  Disjunction(tF[v] ≤ lo, t0[v] ≥ hi)
#   ForbidAgent(a)           ==  Xa[u,v] = 0 들의 모음
# 이것을 안전하게 만드는 것은 **kind 를 안 보는 일반 `verify()`**(verifier.jl:83-125)다:
# 문법 · 과거불가침 · MILP feasibility · invariant 넷을 통과해야 solver 에 닿는다.
# 새 kind 를 위한 `verify_*` 는 필요 없고, 만들면 안 된다.
# =============================================================================

"""
    VarRef(kind, node, node2 = nothing)

MILP 결정변수 하나에 대한 참조. `kind` 는 셋뿐이다:
  `:t0` → `t0[v]`   (그 노드의 시작시각)
  `:tF` → `tF[v]`   (그 노드의 종료시각)
  `:xa` → `Xa[u,v]` (배정 후보 엣지. `node2` 필수)

🔴 **정점 인덱스가 아니라 `AbstractID` 로 참조한다.** 그래프 수술이 정점 번호를 재부여하므로
인덱스로 적은 제약은 수술 뒤에 엉뚱한 노드를 가리킨다. 기존 `ForbidWindow.node` 와 같은 규약이다.
"""
struct VarRef
    kind::Symbol                        # :t0 | :tF | :xa 뿐 (생성자가 강제)
    node::AbstractID                    # 대상 노드/로봇의 ID (정점 번호가 아니다)
    node2::Union{Nothing,AbstractID}    # :xa 일 때의 두 번째 끝점. 나머지 kind 에서는 nothing
    function VarRef(kind::Symbol, node::AbstractID, node2 = nothing)
        kind in (:t0, :tF, :xa) ||
            error("VarRef: kind 는 :t0 | :tF | :xa 뿐이다 (받은 값: $(kind))")
        kind === :xa && node2 === nothing &&
            error("VarRef: :xa 는 노드 둘을 요구한다 (Xa[u,v])")
        kind !== :xa && node2 !== nothing &&
            error("VarRef: $(kind) 는 노드 하나만 받는다")
        return new(kind, node, node2)
    end
end

"""
    LinearConstraint(terms, rel, rhs)

`Σ cᵢ·varᵢ  ⋛  rhs`. `rel ∈ {:le, :ge, :eq}`.

이것이 **L2-a 의 전부**다(spec §5-4). `ForbidAgent` 는 `Xa[u,v] = 0` 들의 모음이고
`ForbidWindow` 는 아래 `Disjunction` 이다 — 둘은 별개의 kind 가 아니라 이 문법의 인스턴스다.
LLM 이 여기서 **아무도 안 짠 제약**을 만들 수 있고, 그것을 안전하게 만드는 것은
`verifier.jl:83` 의 일반 `verify()` 다(kind 를 안 본다).
"""
struct LinearConstraint <: ConstraintSpec
    terms::Vector{Tuple{Float64,VarRef}}  # (계수, 변수참조) 쌍들. **순서 있는 Vector** = 직렬화/컴파일이 결정적
    rel::Symbol                           # :le | :ge | :eq
    rhs::Float64                          # 우변 상수
    function LinearConstraint(terms, rel::Symbol, rhs::Real)
        rel in (:le, :ge, :eq) ||
            error("LinearConstraint: rel 은 :le | :ge | :eq 뿐이다 (받은 값: $(rel))")
        isempty(terms) && error("LinearConstraint: 항이 없다 — 0개 제약은 hollow admit 이다")
        return new(collect(Tuple{Float64,VarRef}, terms), rel, Float64(rhs))
    end
end

"""
    Disjunction(left, right)

`left ∨ right`. Big-M + 이진변수로 컴파일된다. `ForbidWindow(v, t_lo, t_hi)` 가 정확히
`Disjunction(tF[v] ≤ t_lo, t0[v] ≥ t_hi)` 다(test/respec_grammar.jl 이 두 해가 같음을 실측한다).
"""
struct Disjunction <: ConstraintSpec
    left::LinearConstraint    # 두 항 모두 LinearConstraint 로 **타입 고정** — 이질적인 두 모델을
    right::LinearConstraint   # 섞을 표현 자체가 없다(컴파일은 언제나 같은 `model` 인자에 대고 한다)
end

# =============================================================================
# 2026-08-21 (Task C3 · spec §5-5) — L2-b: 파라미터가 자유로운 **공간 원시연산**
# -----------------------------------------------------------------------------
# L2-a(위 셋)가 시간/배정 축에서 "아무도 안 짠 제약"을 열었다면, 여기는 **기하 축**이다.
# 🔴 `RelocateBuild(zone)` 은 action 이 아니라 **solver** 다: `translate_whole_build!` 이
#    `_find_min_translation` 으로 Δ 를 스스로 찾는다(restage_zone.jl:768-779). 그것을 LLM 에
#    주는 것은 신설이 아니라 **감춰 둔 매크로를 도로 고르는 것**이다. 진짜 원시연산은
#    `_apply_uniform_translation!(env, Δ)` 이고, 아래가 그것을 자유 파라미터로 노출한다.
# =============================================================================

"""
    TranslateBuild(dx, dy)

빌드 전체를 **주어진** 강체 변위 `(dx, dy)` 만큼 옮긴다. 집행부는
`_apply_uniform_translation!(env, (dx, dy))`(restage_zone.jl:610) — 모든 조립체의
`start_config` 를 Δ 만큼 합성 이동하고 적치원 기록을 갱신한 뒤 드리프트한 씬 노드를 스냅한다.
**이동은 합성된다**: 같은 제안에 둘을 실으면 순 이동은 Δ₁+Δ₂ 다.

🔴 `RelocateBuild(zone)` 와의 차이가 이 계획의 요점이다(spec §5-5):

    RelocateBuild(zone)   Δ 를 **알고리즘이 찾는다**(`_find_min_translation`). 제안자는 구역
                          이름만 고른다 — 매크로 선택이다.
    TranslateBuild(dx,dy) Δ 를 **제안자가 정한다.** 그래서 제안자가 ZONES 기하를 보고 "빌드가
                          비켜야 하고 이만큼이면 된다" 를 스스로 유도해야 한다. 그것이 L2 신설이다.

**Tier: SPATIAL** — `ForbidZone`·`RelocateBuild` 와 같은 티어다. MILP `@constraint` 가
아니라 기하 수술이므로 `compile_constraint!` 는 0 행을 더하고(닫힌 합집합 계약 유지),
실제 동작은 `replan.jl` 의 `:translate` 분기가 한다.

**조용한 폴백 금지 (Global Constraint) — 이 타입이 지키는 몫:**
  · 비유한 Δ(`NaN`/`Inf`)는 **가장 싼 표면인 이 생성자에서 죽는다.** 클램프하지 않고, 0 으로
    대체하지 않는다. 비유한 Δ 를 `_apply_uniform_translation!` 에 흘리면 모든 조립체의
    `start_config` 가 `NaN` 이 되고, 그 뒤 어떤 기하 판정도 조용히 `false` 가 된다.
  · `Δ = 0` 은 **생성자가 아니라 집행부가** 거부한다(`:rejected`). 이유: 0 은 문법 오류가 아니라
    **정책 오류**(= "옮기겠다" 고 말해 놓고 안 옮김)이고, 이 레포는 그 둘을 다르게 다룬다 —
    문법 오류는 제안 전체를 파서에서 죽이고, 정책 오류는 집행 단위별 판정으로 `LAST_ENACT_REPORT[]`
    에 남는다. 생성자에서 막으면 그 판정 경로가 **도달 불가능한 죽은 가드**가 된다.
  · 옮길 대상이 없는 경우(`env.staging_circles` 가 빔)도 집행부가 `:rejected` 로 죽인다 —
    `_apply_uniform_translation!` 은 그 상황에서 **조용한 no-op** 이기 때문이다.
  · 기하적 타당성(결과 배치가 조건을 만족하는가)은 **Task C4 의 `verify_translate`** 가 맡는다.
    zone 이름을 안 받으므로 kind 별 전제조건이 없고, 결과 배치만 본다.
"""
struct TranslateBuild <: ConstraintSpec
    dx::Float64           # x 축 변위 (제안자가 정한다 — 알고리즘이 찾아 주는 게 아니다)
    dy::Float64           # y 축 변위. z 는 안 건드린다(평면 강체이동)
    function TranslateBuild(dx::Real, dy::Real)
        (isfinite(dx) && isfinite(dy)) ||
            error("TranslateBuild: Δ 는 유한해야 한다 (받은 값: ($(dx), $(dy))). " *
                  "클램프하지 않고 기본값으로 대체하지도 않는다 — 조용한 폴백 금지.")
        return new(Float64(dx), Float64(dy))
    end
end

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
