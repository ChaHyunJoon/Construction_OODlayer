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

from pydantic import BaseModel, Field  # Pydantic: 필드 선언만으로 검증/파싱 해주는 데이터 모델 라이브러리


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


# ConstraintSpec: 위 6가지 제약 중 하나를 담는 타입. discriminator="kind" 로 "kind" 값을 보고
# 어느 클래스로 파싱할지 자동 판별(discriminated union). = 이 한 줄이 문법 전체의 합집합 타입.
ConstraintSpec = Annotated[
    Union[ForbidWindow, ForbidAgent, ForbidZone, ReplaceAgent, ReformTeam, DeprioritizeAgent],
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
TOOL_SCHEMA = {
    "name": "propose_respecification",
    "description": (
        "Propose a re-specification that handles the observed open-world event. Most kinds "
        "ADD formal scheduling constraints (hard); DeprioritizeAgent is the ONE soft kind -- "
        "it only re-prices a degraded (e.g. low-battery) robot so the solver avoids it without "
        "removing it. Never change the objective directly. Reference nodes/agents by the exact "
        "ids given in the prompt."
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
                            # enum = 허용된 kind 6종만. 그 밖의 값은 여기서 걸림.
                            "enum": ["ForbidWindow", "ForbidAgent", "ForbidZone", "ReplaceAgent", "ReformTeam", "DeprioritizeAgent"],
                        },
                        # 아래는 kind 별로 쓰이는 필드들을 한데 나열(모델이 해당 kind 에 맞는 것만 채움).
                        "node": {"type": "string"},
                        "agent": {"type": "string"},
                        "t_lo": {"type": "number"},
                        "t_hi": {"type": "number"},
                        "after": {"type": "number"},
                        "zone": {"type": "string"},
                        "assembly": {"type": "string"},
                        "factor": {"type": "number"},
                    },
                },
            },
        },
    },
}
