"""
schema.py -- The formal-specification DSL, Python side.

This MIRRORS src/respec/spec_dsl.jl exactly. It is the single source of truth on
the Python side for (a) the Anthropic tool input_schema that FORCES the model to
emit only grammar-shaped JSON, and (b) Pydantic validation of what comes back.

The wire contract (what /propose returns) is:
    {"constraints": [ {<one of the kinds below>}, ... ], "rationale": str}

Safety note: the model can only ever produce one of these kinds. Anything
else fails validation here and again at the typed parse in Julia (llm_bridge.jl).
The verifier in Julia -- not this file, not the model -- is what admits a
proposal to the solver. Keep these kinds in lockstep with spec_dsl.jl.

────────────────────────────────────────────────────────────────────────────
[한국어 설명]
이 파일은 재명세(re-specification) DSL 의 "파이썬 쪽 단일 진실원본".
프로젝트 역할: 다로봇 조립 시뮬레이터가 예상 밖(OOD) 사건을 만나면, LLM 이
"자유 텍스트"가 아니라 여기 정의된 정해진 문법(DSL)의 JSON 만 내놓도록 강제한다.
이 파일이 하는 두 가지:
  (a) Anthropic tool 의 input_schema — 모델이 문법 모양의 JSON 만 만들도록 강제.
  (b) 돌아온 결과를 Pydantic 으로 검증(validation).
안전 원칙: 모델은 아래 kind 중 하나만 만들 수 있고, 그 밖의 것은 여기서, 그리고
줄리아(llm_bridge.jl)에서 또 한 번 검증에 걸려 걸러진다. 실제로 solver 에 넣을지
말지는 이 파일도 모델도 아닌 줄리아의 verifier 가 결정한다. spec_dsl.jl 과 항상 동기화.

[문법 참고] (파이썬의 덜 익숙한 기능들)
  · class Foo(BaseModel): ...  — Pydantic 모델. 필드 이름:타입 만 적으면 자동 검증/파싱.
  · kind: Literal["ForbidWindow"] = "..."  — 타입 힌트. Literal[x] = "값이 정확히 x 여야 함".
    `이름: 타입 = 기본값` 형태가 곧 필드 선언(자바처럼 별도 생성자 코드 필요 없음).
  · Annotated[Union[...], Field(discriminator="kind")] — 여러 타입 중 하나(Union)를 받되,
    "kind" 필드 값을 보고 어느 클래스인지 자동 판별(discriminated union).
  · Field(default_factory=list) — 기본값이 매번 새 빈 리스트가 되게 함(가변 기본값 함정 회피).
  · TOOL_SCHEMA = {...} — 파이썬 dict 로 손수 적은 JSON schema(Anthropic tool-use 규격).
────────────────────────────────────────────────────────────────────────────
"""
from typing import Annotated, List, Literal, Union  # 타입 힌트용 도구들(Literal=값 고정, Union=여러 타입 중 하나)

from pydantic import BaseModel, ConfigDict, Field  # Pydantic: 필드 선언만으로 검증/파싱 해주는 데이터 모델 라이브러리


# ForbidWindow: 특정 노드를 [t_lo, t_hi] 시간창 동안 활동 금지(순수 시간 제약).
class ForbidWindow(BaseModel):
    """Node `node` may not be active during [t_lo, t_hi]."""
    kind: Literal["ForbidWindow"] = "ForbidWindow"  # 종류 표시(항상 이 문자열). Union 판별의 기준이 됨.
    node: str      # 금지할 노드 id(줄리아가 실제 id 객체로 되돌릴 정확한 문자열)
    t_lo: float    # 금지 시작 시각(하한)
    t_hi: float    # 금지 끝 시각(상한)


# ForbidAgent: 특정 로봇을 after 시각 이후 완전히 제거(대체 없음; 남은 로봇들에 일이 재분배됨).
class ForbidAgent(BaseModel):
    """Agent `agent` is unavailable for tasks starting at/after `after`."""
    kind: Literal["ForbidAgent"] = "ForbidAgent"
    agent: str          # 제거할 로봇 id(RobotID 문자열 그대로; 노드 id 나 'R3' 가 아님)
    after: float = 0.0  # 이 시각 이후로 금지(기본 0.0 = 처음부터). `= 0.0` 이 곧 선택적 필드 기본값.


# ForbidZone: 공간적 출입금지 구역이 한 조립체의 적치/작업 영역을 덮은 사건.
# MILP 재스케줄이 아니라 줄리아 쪽에서 기하 복구(막힌 작업을 옮김)로 처리 — 좌표를 지어내지 말 것.
class ForbidZone(BaseModel):
    """A spatial no-go zone blocks assembly `assembly`'s staging area.

    Emit this for a SPATIAL exclusion/keep-out region (not a time delay): the named
    `zone` (one of the active zone keys given in the prompt's ZONES section) covers the
    staging/build area of `assembly`. The Julia side handles it by GEOMETRIC relocation
    of the blocked work, not a schedule change -- so never invent coordinates; only echo
    a zone key the prompt listed and the assembly node id it covers.
    """
    kind: Literal["ForbidZone"] = "ForbidZone"
    zone: str      # 프롬프트의 ZONES 목록에 있던 활성 구역 키 하나(그대로 echo; 지어내지 말 것)
    assembly: str  # 그 구역이 덮은 조립체의 노드 id(grounding/교차검증용)


# RelocateBuild: 구역이 "국소 재적치로는 못 구하는" 작업(=root 하역 목표)까지 덮은 경우,
# 빌드 **전체**를 강체 평행이동 한 번으로 비켜 옮긴다. ForbidZone 과 달리 조립체를 지목하지 않는다.
# 왜 별도 kind 인가: ForbidZone 의 실행부(restage_all_blocked!)는 "아직 시작 안 한 조립체"만 옮길 수
# 있어서 빌드 중반 이후 도메인이 빈다. 그때도 유효한 유일한 공간형 팔이 이것.
class RelocateBuild(BaseModel):
    """A no-go zone covers work that CANNOT be relocated piecemeal -- shift the ENTIRE build clear.

    Emit this ONLY when the zone swallows work no per-assembly restage can rescue -- in
    practice when the zone's `covers_root` is true (it traps the ROOT assembly's own deposit
    goals, and the root is the build's reference frame and is never moved).

    Do NOT emit this merely because the zone covers some sub-assembly's staging area: that is
    repairable locally with ForbidZone, and a whole-build move is a GLOBAL, irreversible shift
    of every future goal while carriers are mid-transit. Measured on the same seed and zones
    with only the macro crossed: ForbidZone closed 231 nodes (7/8 assemblies), RelocateBuild
    closed 136 (1/8). The loss is the macro's, not the policy's.

    Prefer ForbidZone whenever `covers` is non-empty: if a per-assembly restage turns out to be
    insufficient, the Julia side AUTOMATICALLY escalates to the whole-build translation
    (`:residual_blocked` -> `translate_whole_build!`), so choosing ForbidZone never forfeits this
    option -- while choosing RelocateBuild wrongly cannot be undone.

    Echo a zone key the prompt listed; never invent coordinates. No `assembly` field -- the whole
    build moves, so there is nothing per-assembly to ground.
    """
    kind: Literal["RelocateBuild"] = "RelocateBuild"
    zone: str      # 비켜야 할 구역 키(ZONES 목록의 것 그대로). assembly 필드는 없음 — 빌드 전체가 움직임.


# ReplaceAgent: 로봇이 "고장" → 가장 가까운 예비(spare) 로봇이 남은 작업을 1:1 인계.
# ForbidAgent 와 필드는 같지만 처리 경로가 다른 별도 kind(예비 선택은 줄리아의 기하가 함).
class ReplaceAgent(BaseModel):
    """Robot `agent` BROKE DOWN and must be REPLACED by a backup (spare) robot.

    Emit this when the event is a robot FAULT/BREAKDOWN that should be handled by
    dispatching a BACKUP/SPARE robot to take over its remaining work (the common
    "robot R failed, send a replacement" case). Same shape as ForbidAgent -- echo the
    EXACT agent id (not a node id, not 'R3') -- but a DISTINCT kind: the Julia side
    enacts it by handing the faulted robot's remaining task chain to the nearest spare
    (a graph hand-off, no reschedule). You only name the faulted `agent`; the spare is
    chosen by geometry on the Julia side, never by you. Prefer this over ForbidAgent
    whenever the intent is "replace the broken robot with a backup".
    """
    kind: Literal["ReplaceAgent"] = "ReplaceAgent"
    agent: str          # 고장난 로봇 id 만 지정(예비는 안 지정 — 줄리아가 기하로 고름)
    after: float = 0.0  # 이 시각 이후 인계


# ReformTeam: 다로봇 운반팀이 형성 도중 교착(deadlock)돼 빌드가 멈춤 → 기하 재정립(필드 없음).
# 보통 예비 교체 후 예비가 늦게 도착해 팀이 끼는 2차 실패에서 발생.
class ReformTeam(BaseModel):
    """A multi-robot transport TEAM is DEADLOCKED while forming and the build STALLED.

    Emit this when the event says a multi-robot transport team cannot finish forming --
    some members reached their carrying positions and are WAITING but the team never
    completes (a deadlock), so progress has stalled. This is the typical second-order
    failure AFTER a spare replacement: the spare arrives off-schedule and a team wedges.
    No fields -- the Julia side geometrically re-establishes whichever teams are stuck
    (snaps the straggler members into their slots). Prefer this over ForbidZone/ForbidAgent
    when the intent is "the stuck transport team(s) need to be re-formed / re-established".
    """
    kind: Literal["ReformTeam"] = "ReformTeam"  # 필드가 kind 하나뿐 — 팀 재정립은 인자가 필요 없음


# DeprioritizeAgent: 로봇을 "제거"하지 않고 "가급적 피함"(소프트 선호). 가장 중요한 용도=배터리 저하.
# 유일한 soft kind — 하드 제약을 안 더하고 배정 비용만 올려 solver 가 건강한 로봇을 선호하게 함(빌드 안 멈춤).
class DeprioritizeAgent(BaseModel):
    """Robot `agent` should be AVOIDED for future work but NOT removed (a SOFT preference).

    Emit this for a DEGRADATION event -- most importantly a BATTERY problem ("robot R3's
    battery is low / degraded / running flat", "R5 is low on charge") -- where the robot can
    STILL work but should be spared heavy/long hauls so it does not run out. This is the SAFEST
    re-spec: unlike ForbidAgent/ReplaceAgent (which REMOVE the robot and can stall the build),
    DeprioritizeAgent adds NO hard constraint -- it only raises the robot's assignment COST so
    the energy-aware re-solve routes work onto healthier robots WHEN POSSIBLE, while keeping the
    robot available if it is the only option (so the build can never stall on it).

    Echo the EXACT agent id (the `id` from the AGENTS section, not 'R3', not a node id).
    `factor` (optional, default 50) expresses severity: higher = avoid harder; it is CLAMPED to
    a safe range [1, 1000] on the Julia side, so you cannot over- or under-drive it. Prefer this
    over ForbidAgent/ReplaceAgent whenever the robot is DEGRADED-BUT-USABLE rather than DEAD.
    """
    kind: Literal["DeprioritizeAgent"] = "DeprioritizeAgent"
    agent: str            # 저하됐지만 아직 쓸 수 있는 로봇 id
    factor: float = 50.0  # 심각도(클수록 더 피함). 줄리아 쪽에서 [1,1000] 로 클램프 → 과·소 조정 불가(안전).


# SwapBattery: 방전된 로봇의 배터리만 현장에서 교체. 같은 본체가 계속 일하고, 창고 예비 "본체"를 안 먹음.
# ReplaceAgent 와 소모 자원이 다르다는 것이 이 kind 를 따로 두는 이유(귀한 예비를 방전에 낭비하지 않음).
class SwapBattery(BaseModel):
    """Robot `agent`'s BATTERY is depleted -- swap the battery IN THE FIELD.

    Emit this when the event says a robot has run out of charge / is flat / stalled because
    of its battery, and the fix is simply to give it a fresh pack. The SAME physical robot
    keeps working; NO depot spare body is consumed -- only time.

    Prefer this over ReplaceAgent for a pure BATTERY problem: a depot spare is a scarce
    chassis that a later MECHANICAL breakdown will need, and spending one on a flat battery
    wastes it. Conversely, do NOT emit this for a mechanical fault ("cannot move", "broken
    down", "motor failure") -- a fresh battery does nothing for a broken drivetrain; use
    ReplaceAgent there.

    Relation to DeprioritizeAgent: use DeprioritizeAgent when the robot is DEGRADED-BUT-USABLE
    and you only want future work routed away from it; use SwapBattery when you want its
    charge actually RESTORED now.

    Echo the EXACT agent id (the `id` from the AGENTS section, not 'R3', not a node id).
    """
    kind: Literal["SwapBattery"] = "SwapBattery"
    agent: str   # 배터리를 갈아 끼울 로봇 id


# =============================================================================
# 2026-08-21 (Task C2 · spec §5-4) — L2-a: MILP 결정변수 위의 제약 문법
# -----------------------------------------------------------------------------
# 위의 kind 들은 전부 "누군가 미리 짜 둔 매크로"다. 아래 둘은 다르다: 모델이
# (t0, tF, Xa) 위의 선형 제약을 **직접 쓴다**. ForbidWindow/ForbidAgent 는 이
# 문법의 인스턴스이지 별개 종류가 아니다.
# 이것이 안전한 이유는 줄리아의 verify() 가 kind 를 보지 않기 때문이다
# (verifier.jl:83-125 — 문법 · 과거불가침 · MILP feasibility · invariant).
# =============================================================================


class VarRef(BaseModel):
    """One MILP decision variable.

    `kind` is one of exactly two:
      * "t0" -- the START time of SCHEDULE NODE `node`
      * "tF" -- the FINISH time of SCHEDULE NODE `node`

    🔴 `node` must be a SCHEDULE-NODE id -- one echoed from the prompt's NAMED NODES
    section or its "ALL still-open node ids" list. It must NEVER be an AGENTS (robot)
    id: a robot is not a schedule vertex, and such a reference is REJECTED.
    Never invent an id, and never use a vertex number: graph surgery renumbers
    vertices, so a number means a different node afterwards.

    (The Julia `VarRef` type also has an "xa" kind for assignment edges `Xa[u,v]`,
    used internally by `ForbidAgent`. It is deliberately NOT emittable: the prompt
    ships no list of which (u,v) pairs are actual decision variables, so the model
    has no way to instantiate it correctly. See llm_bridge.jl EMITTABLE_VARREF_KINDS.)
    """
    # 🔴 `extra="forbid"` — 줄리아 생성자가 거부하는 것을 스키마도 거부하게 만든다.
    #    Pydantic 기본값은 모르는 키를 **조용히 버리는 것**이라, `node2` 같은 필드를 실어 보내도
    #    검증을 통과해 놓고 줄리아 파서에서 죽는다. 그게 정확히 "싼 표면에서 안 거르는" 실패다.
    model_config = ConfigDict(extra="forbid")

    kind: Literal["t0", "tF"]   # 둘뿐. `xa` 는 타입에는 있지만 emit 대상이 아니다(위 설명).
    node: str                   # 프롬프트가 준 정확한 **스케줄 노드** id (로봇 id 가 아니다)

    # `node2` 필드는 **의도적으로 없다.** `:xa` 가 emit 불가이므로 node2 는 어떤 경우에도
    # 유효하지 않고, 필드를 아예 없애는 것이 `model_validator` 로 XOR 을 검사하는 것보다
    # 강하게 강제한다(모델이 애초에 보낼 수 없다). 줄리아 `VarRef` 생성자도 같은 규칙이다:
    # `:t0`/`:tF` 에 node2 를 주면 error.


class Term(BaseModel):
    """One `coeff * var` term of a linear constraint."""
    # 🔴 `extra="forbid"` — 줄리아 생성자가 거부하는 것을 스키마도 거부하게 만든다.
    #    Pydantic 기본값은 모르는 키를 **조용히 버리는 것**이라, `node2` 같은 필드를 실어 보내도
    #    검증을 통과해 놓고 줄리아 파서에서 죽는다. 그게 정확히 "싼 표면에서 안 거르는" 실패다.
    model_config = ConfigDict(extra="forbid")

    coeff: float   # 계수
    var: VarRef    # 그 계수가 곱해지는 결정변수


# LinearConstraint: 아무도 하드코딩하지 않은 제약을 모델이 직접 쓰는 자리(행동 신설 L2-a).
class LinearConstraint(BaseModel):
    """Sum(coeff * var) `rel` rhs -- a NEW scheduling constraint you write yourself.

    This is the one kind that is NOT a pre-written macro: it lets you express a
    requirement nobody hardcoded, directly over the scheduler's decision variables.
    Examples of what it can say that no other kind can:
      * "node N must not finish before 30"        -> [1*tF(N)] ge 30
      * "node A must finish before node B starts" -> [1*tF(A), -1*t0(B)] le 0
      * "these two nodes must start together"     -> [1*t0(A), -1*t0(B)] eq 0

    `rel` is exactly one of "le" (<=), "ge" (>=), "eq" (==). `terms` must be
    NON-EMPTY -- a zero-term constraint constrains nothing and is rejected.

    Every `var.node` must be an EXACT id echoed from the prompt's NODES / AGENTS
    listing. An id that is not in the schedule is REJECTED (never silently skipped).

    Safety: this is gated by the SAME general verifier as every other kind -- the
    proposal is trial-solved with your constraint injected, and rejected if the
    problem becomes infeasible or if it re-times already-completed work.
    """
    # 🔴 `extra="forbid"` — 줄리아 생성자가 거부하는 것을 스키마도 거부하게 만든다.
    #    Pydantic 기본값은 모르는 키를 **조용히 버리는 것**이라, `node2` 같은 필드를 실어 보내도
    #    검증을 통과해 놓고 줄리아 파서에서 죽는다. 그게 정확히 "싼 표면에서 안 거르는" 실패다.
    model_config = ConfigDict(extra="forbid")

    kind: Literal["LinearConstraint"] = "LinearConstraint"
    # 🔴 `min_length=1` — docstring 이 "NON-EMPTY" 라고만 적고 강제는 안 하던 자리였다.
    #    0개 항은 hollow admit 이라 줄리아 `LinearConstraint` 생성자가 error 한다.
    #    같은 규칙을 **가장 싼 표면**(스키마 검증)에서 먼저 건다.
    terms: List[Term] = Field(..., min_length=1)
    rel: Literal["le", "ge", "eq"]
    rhs: float


# Disjunction: "둘 중 하나는 성립" (Big-M + 이진변수로 컴파일). ForbidWindow 가 정확히 이것이다.
class Disjunction(BaseModel):
    """`left` OR `right` -- at least one of the two linear constraints must hold.

    Use this for an EITHER/OR requirement that a single linear constraint cannot
    express. The canonical example is a forbidden time window on node N: "N is not
    active during [lo, hi]" is exactly

        left  = [1*tF(N)] le lo      (finish before the window)
        right = [1*t0(N)] ge hi      (start after the window)

    Both halves must be LinearConstraints over the SAME schedule. It compiles to a
    Big-M encoding with one auxiliary binary, so it only shrinks the feasible set.
    """
    # 🔴 `extra="forbid"` — 줄리아 생성자가 거부하는 것을 스키마도 거부하게 만든다.
    #    Pydantic 기본값은 모르는 키를 **조용히 버리는 것**이라, `node2` 같은 필드를 실어 보내도
    #    검증을 통과해 놓고 줄리아 파서에서 죽는다. 그게 정확히 "싼 표면에서 안 거르는" 실패다.
    model_config = ConfigDict(extra="forbid")

    kind: Literal["Disjunction"] = "Disjunction"
    left: LinearConstraint
    right: LinearConstraint


# =============================================================================
# 2026-08-21 (Task C3 · spec §5-5) — L2-b: 파라미터가 자유로운 공간 원시연산
# -----------------------------------------------------------------------------
# 위의 L2-a 문법이 시간/배정 축을 열었다면 이것은 기하 축이다. RelocateBuild(zone) 은
# action 이 아니라 solver 였다(_find_min_translation 이 Δ 를 스스로 찾는다) — 그래서
# 은퇴시키고, 그 밑에 있던 진짜 원시연산 _apply_uniform_translation!(env, Δ) 를
# 자유 파라미터로 노출한다.
# =============================================================================


class TranslateBuild(BaseModel):
    """Shift the ENTIRE build rigidly by the displacement (dx, dy) YOU choose.

    This is the only kind that moves GEOMETRY. Emit it when the event is a SPATIAL
    keep-out region that traps work the build must still reach: the zone stays where it
    is and the whole build (every assembly's staging area and every remaining deposit
    goal) slides by (dx, dy) so its work region no longer overlaps the zone.

    🔴 DERIVE (dx, dy) FROM THE ZONES SECTION -- NEVER INVENT COORDINATES, and never
    copy a number from the event text. The prompt's ZONES section gives each active
    zone's `center` and `radius`. `dx`/`dy` are a DISPLACEMENT (a delta), NOT a
    destination: (0, 0) is refused, because "translate by nothing" claims an
    intervention and performs none. If you judge that no move is warranted, emit an
    EMPTY constraints list instead -- that is how restraint is said in this grammar,
    and it is a different (and cheaper) answer.

    Reason about MAGNITUDE from the zone's own geometry: the build's remaining work sits
    around the zone, so a displacement must carry it past the far edge -- a move shorter
    than the zone's radius cannot clear a zone the build is standing in. Pick a direction
    that takes the build AWAY from the zone centre, and a magnitude of several zone radii.
    A displacement that is too small leaves work inside the keep-out region and the robots
    park at its edge forever; there is no partial credit.

    Cost is real: every remaining goal moves, so every robot drives further. Do not
    propose a translation for an event that is not spatial.
    """
    # 🔴 `extra="forbid"` — 줄리아 생성자가 거부하는 것을 스키마도 거부하게 만든다.
    model_config = ConfigDict(extra="forbid")

    kind: Literal["TranslateBuild"] = "TranslateBuild"
    # 🔴 기본값이 **없다.** `dx: float = 0.0` 으로 두면 빠진 필드가 조용히 Δ=0 이 되고,
    #    그것은 "옮기겠다"고 말해 놓고 아무것도 안 하는 hollow admit 이다(줄리아 쪽에서 :rejected).
    dx: float   # x 축 변위(목적지가 아니라 **변위**)
    dy: float   # y 축 변위. z 는 없다 — 평면 강체이동이다.


# =============================================================================
# 🔴 2026-08-21 D-9 (Task C2, spec §5-8): 행동공간을 emit 가능한 것만 남기고 줄였다.
# -----------------------------------------------------------------------------
# 아래 여섯 클래스는 **정의는 그대로 남기되 union 과 TOOL_SCHEMA enum 에서 뺐다.**
#   ForbidZone        도메인 공집합 (closed≈46 이후 n_restage_feasible == 0)
#   ReformTeam        은퇴 — 복구가 maybe_unwedge_nominal! 로 명목 레인에 이관
#   ForbidAgent       D-7 아래 ReplaceAgent 에 약우월로 지배
#   ForbidWindow      대응 사건 없음 (도착 시점이 확률변수다). 필요하면 Disjunction 으로 쓴다
#   DeprioritizeAgent 선택 0회. cell 위험은 battery kind 로 도착하므로 SwapBattery 가 답이다
#                     (_hz_fire_cell! -> battery_action, hazard.jl:583)
#   RelocateBuild     행동이 아니라 solver 다(_find_min_translation 이 Δ 를 스스로 찾는다,
#                     restage_zone.jl:768-779). 진짜 원시연산 _apply_uniform_translation!(env, Δ)
#                     를 Task C3 의 TranslateBuild(dx, dy) 가 자유 파라미터로 노출한다(**집행됨**).
#                     안 빼면 emit 가능 수가 5 가 아니라 6 이 된다(컨트롤러 판정 2026-08-21).
#
# 🔴 개수(이 파일 기준): C2 끝 = 4종. **C3 끝 = 5종** — 위 넷 + TranslateBuild.
#    산수: 8 - 6 + 3 = 5 (원래 8종 - 은퇴 6종 + L2-a 둘(LinearConstraint·Disjunction)
#    + L2-b 하나(TranslateBuild)). 지금 이 파일이 C3 끝 시점이다.
#
# 🔴 **줄리아 타입과 컴파일러는 살아 있다** — 엔진 내부 생산자가 그 타입들을 직접 만든다
#    (navigator/baselines.jl:173·192·201 · respec/reassign.jl:382 · oracle/ood_mdp_shim.jl:306).
#    여기서 빠지는 것은 "LLM 이 낼 수 있는 것"의 목록뿐이다.
#
# 이 목록은 llm_bridge.jl 의 `EMITTABLE_KINDS` 와 **집합으로 같아야 한다** —
# test/respec_action_space.jl 이 두 표면의 등식을 직접 단언한다.
#
# 클래스 정의를 지우지 않고 남긴 이유: Task C3 가 TranslateBuild 를 넣고 나면 이 파일이
# 행동공간의 역사를 그대로 들고 있는 유일한 자리이고, 되살릴 때 diff 가 한 줄이면 된다.
# =============================================================================
ConstraintSpec = Annotated[
    Union[LinearConstraint, Disjunction, ReplaceAgent, SwapBattery, TranslateBuild],
    Field(discriminator="kind"),
]


# RespecProposal: /propose 가 돌려주는 최상위 응답 = 제약 목록 + 근거(rationale) 문자열.
class RespecProposal(BaseModel):
    constraints: List[ConstraintSpec] = Field(default_factory=list)  # 제약들의 리스트(기본=빈 리스트)
    rationale: str = ""  # 모델이 왜 이렇게 정했는지 사람이 읽을 근거(선택)


# --- Anthropic tool schema: the grammar the model is FORCED to fill ----------
# Hand-written (rather than derived from Pydantic) so the model sees a flat,
# unambiguous schema with the kind-enum up front. Validation of the result still
# goes through RespecProposal above.
# TOOL_SCHEMA: Anthropic tool-use 규격의 JSON schema(파이썬 dict). 모델은 이 tool 을
# 강제로 호출해야 하므로, 여기 정의된 모양의 JSON 외에는 물리적으로 못 내놓는다.
# Pydantic 에서 자동 생성하지 않고 손으로 적은 이유: 모델에 kind-enum 이 앞에 오는
# 평평하고 명확한 schema 를 보여주기 위함. 결과 검증은 여전히 위 RespecProposal 이 담당.
# 손으로 적은 하위 schema 둘(TOOL_SCHEMA 안에서 두 번 쓰이므로 이름을 붙여 둔다).
_VARREF_SCHEMA = {
    "type": "object",
    "required": ["kind", "node"],
    "properties": {
        # 🔴 emit 가능한 결정변수는 둘뿐. `xa` 는 타입에는 있지만 여기 없다
        #    (프롬프트가 후보 엣지 목록을 안 실어서 유효한 인스턴스가 없다).
        "kind": {"type": "string", "enum": ["t0", "tF"]},
        "node": {"type": "string"},   # 스케줄 **노드** id (로봇 id 가 아니다)
    },
}
_LINEAR_SCHEMA = {
    "type": "object",
    "required": ["terms", "rel", "rhs"],
    "properties": {
        "terms": {
            "type": "array",
            "minItems": 1,               # 🔴 0개 항 = hollow admit. 스키마에서 먼저 막는다.
            "items": {
                "type": "object",
                "required": ["coeff", "var"],
                "properties": {"coeff": {"type": "number"}, "var": _VARREF_SCHEMA},
            },
        },
        "rel": {"type": "string", "enum": ["le", "ge", "eq"]},
        "rhs": {"type": "number"},
    },
}

TOOL_SCHEMA = {
    "name": "propose_respecification",
    "description": (
        "Propose a re-specification that handles the observed open-world event. Two kinds are "
        "pre-written recoveries (ReplaceAgent for a broken robot, SwapBattery for a flat one); "
        "two are a GRAMMAR you write yourself over the scheduler's decision variables "
        "(LinearConstraint, and Disjunction for an either/or); one is a spatial primitive "
        "(TranslateBuild, which slides the whole build by a displacement you choose, for a "
        "keep-out zone that traps work). Prefer a pre-written recovery when one fits the event; "
        "reach for the grammar when nothing pre-written expresses the requirement. Never change "
        "the objective directly. Reference nodes/agents by the exact ids given in the prompt."
    ),
    "input_schema": {                       # 모델 출력의 형태를 규정하는 JSON schema 본체
        "type": "object",
        "required": ["constraints", "rationale"],  # 이 두 키는 반드시 있어야 함
        "properties": {
            "rationale": {"type": "string"},
            "constraints": {
                "type": "array",             # 제약들의 배열
                "items": {                   # 배열 각 원소(제약 하나)의 모양
                    "type": "object",
                    "required": ["kind"],    # 제약마다 kind 는 필수
                    "properties": {
                        "kind": {
                            "type": "string",
                            # 🔴 D-9: emit 가능한 kind 만. llm_bridge.jl 의 EMITTABLE_KINDS 와
                            # 집합으로 같아야 한다(test/respec_action_space.jl 이 단언한다).
                            "enum": ["LinearConstraint", "Disjunction",
                                     "ReplaceAgent", "SwapBattery", "TranslateBuild"],
                        },
                        # 아래는 kind 별로 쓰이는 필드들을 한데 나열(모델이 해당 kind 에 맞는 것만 채움).
                        "agent": {"type": "string"},   # ReplaceAgent / SwapBattery
                        "after": {"type": "number"},   # ReplaceAgent
                        # --- L2-b 공간 원시연산 (TranslateBuild) ---
                        # 🔴 변위(delta)다. 목적지 좌표가 아니다. (0,0) 은 줄리아가 거부한다.
                        "dx": {"type": "number"},      # TranslateBuild
                        "dy": {"type": "number"},      # TranslateBuild
                        # --- L2-a 문법 (LinearConstraint / Disjunction) ---
                        "terms": {                     # LinearConstraint: Σ coeff·var
                            "type": "array",
                            "minItems": 1,             # 🔴 0개 항 = hollow admit
                            "items": {
                                "type": "object",
                                "required": ["coeff", "var"],
                                "properties": {
                                    "coeff": {"type": "number"},
                                    "var": _VARREF_SCHEMA,
                                },
                            },
                        },
                        "rel": {"type": "string", "enum": ["le", "ge", "eq"]},
                        "rhs": {"type": "number"},
                        "left": _LINEAR_SCHEMA,        # Disjunction 의 왼쪽 항
                        "right": _LINEAR_SCHEMA,       # Disjunction 의 오른쪽 항
                    },
                },
            },
        },
    },
}
