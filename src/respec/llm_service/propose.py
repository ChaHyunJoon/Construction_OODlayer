"""
propose.py -- OOD event -> Claude (structured output) -> validated DSL dict.

The model's ONLY job: translate the open-world observation into the closed DSL.
It is forced to do so via Anthropic tool-use: tool_choice pins the single
`propose_respecification` tool whose input_schema IS the grammar (schema.py), so
the model physically cannot return free-form text to the solver.

Env:
    ANTHROPIC_API_KEY  (required)
    RESPEC_MODEL       (optional, default claude-opus-4-8)

────────────────────────────────────────────────────────────────────────────
[한국어 설명]
이 파일은 "OOD 사건(자연어) → LLM(구조화 출력) → 검증된 DSL dict" 변환기.
프로젝트 역할: 시뮬레이터가 넘긴 사건 설명을 받아 프롬프트를 만들고, Claude 를
tool-use 로 호출해 schema.py 의 문법대로 된 제안을 받아 검증 후 dict 로 돌려준다.
핵심 안전장치: tool_choice 로 propose_respecification tool 하나만 쓰게 못박아,
모델이 solver 로 "자유 텍스트"를 되돌리는 것이 물리적으로 불가능하게 만든다.
환경변수: ANTHROPIC_API_KEY(필수), RESPEC_MODEL(선택, 기본 claude-opus-4-8).

[문법 참고]
  · os.environ.get("키", 기본값) — 환경변수 읽기(없으면 기본값). 줄리아의 get(ENV,...) 와 같음.
  · def f(x: str, ys: list[str]) -> dict: — 타입 힌트. `-> dict` 는 반환 타입(검사는 안 하고 문서용).
  · a or b — a 가 falsy(빈 리스트/None/"") 면 b 를 씀(줄리아의 `||` 유사). 기본값 채우기에 자주 씀.
  · "\n".join(...) — 문자열 리스트를 줄바꿈으로 이어붙임.
  · f"...{x}..." — f-string, {} 안 값을 문자열에 끼워 넣음(줄리아의 $(...) 보간).
  · global _client — 함수 안에서 모듈 전역 변수를 "쓰기"할 때 필요한 선언(안 쓰면 지역변수로 오해).
────────────────────────────────────────────────────────────────────────────
"""
import os  # 환경변수(API 키, 모델 이름) 읽기용

import anthropic  # Anthropic 공식 파이썬 SDK(Claude 호출)

from schema import RespecProposal, TOOL_SCHEMA  # 같은 폴더 schema.py 의 응답 모델 + tool 규격

_MODEL = os.environ.get("RESPEC_MODEL", "claude-opus-4-8")  # 사용할 모델 이름(환경변수 우선, 기본값 지정)
_client = None  # Anthropic 클라이언트는 처음 필요할 때 만든다(지연 생성) — 아래 _get_client 참고


# _get_client: Anthropic 클라이언트를 "처음 쓸 때" 딱 한 번 만든다(지연 생성).
# 이렇게 하면 API 키 없이도 이 모듈을 import 할 수 있어(예: schema 테스트) 편함.
def _get_client():
    """Lazily construct the Anthropic client so this module imports without
    ANTHROPIC_API_KEY set (e.g. for schema tests). The key is only required when
    a proposal is actually requested."""
    global _client                       # 모듈 전역 _client 를 수정하겠다는 선언
    if _client is None:                  # 아직 안 만들었으면
        _client = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY from env  # 환경변수에서 키를 읽어 생성
    return _client


# _build_prompt: 사건 설명 + id 목록들(로봇/노드/구역)을 LLM 에 줄 하나의 프롬프트 문자열로 조립.
# agents/nodes/zones 는 "자연어 참조(예: 'R3', '최종 조립체')를 정확한 id 로 grounding"하기 위한 힌트 목록(선택).
def _build_prompt(event: str, open_ids: list[str],
                  agents: list[dict] | None = None,   # `X | None` = X 또는 None. `= None` 이라 생략 가능한 인자.
                  nodes: list[dict] | None = None,
                  zones: list[dict] | None = None) -> str:
    agents = agents or []                # None 이면 빈 리스트로(뒤 코드가 안전하게 순회하도록)
    nodes = nodes or []
    zones = zones or []
    # 각 로봇을 "사람이 읽을 label -> 정확한 agent id" 한 줄로 변환. `for a in agents` 는
    # 리스트 컴프리헨션(줄리아의 배열 comprehension) — 목록이 비면 뒤의 or 문구로 대체.
    agent_lines = (
        "\n".join(f"  - {a.get('label') or a['id']}  ->  agent id: {a['id']}" for a in agents)
        or "  (no robots available to forbid)"   # 로봇이 없으면 이 안내문
    )
    # 마일스톤 노드도 같은 방식으로 "label -> node id" 목록 만들기
    node_lines = (
        "\n".join(f"  - {n.get('label') or n['id']}  ->  node id: {n['id']}" for n in nodes)
        or "  (no labelled milestone nodes)"
    )
    # 활성 출입금지 구역: 구역 키 + 덮는 조립체 + 루트까지 덮는지 + 대략 위치를 한 줄로
    zone_lines = (
        "\n".join(
            f"  - zone key: {z['key']}  ->  covers assemblies: {z.get('covers') or '(none)'}; "
            f"covers_root: {z.get('covers_root')}  (near {z.get('center')}, r={z.get('radius')})"
            for z in zones
        )
        or "  (no active no-go zones)"
    )
    # 아래는 여러 문자열 리터럴을 나란히 둔 것 — 파이썬은 인접한 문자열을 자동으로 이어붙인다(하나의 긴 프롬프트).
    # 내용: 사건 설명 + 노드/로봇/구역 목록 + 어떤 kind 를 언제 쓸지에 대한 규칙을 모델에게 지시.
    return (
        "An open-world event occurred during execution of a multi-robot "
        "assembly plan.\n"
        f"EVENT: {event}\n\n"
        "You re-specify the problem with the closed DSL below. Most kinds ADD hard "
        "scheduling/spatial constraints; ONE kind (DeprioritizeAgent) is a SOFT preference "
        "for a degraded-but-usable robot. You never change the objective directly.\n\n"
        "NAMED NODES. When the event refers to an assembly/part/milestone, match the "
        "description in the event to one of these and use its EXACT node id — NOT the "
        "human label:\n"
        f"{node_lines}\n\n"
        "AGENTS (robots). If the event involves a robot, reference it by the EXACT "
        "agent id below — NOT a node id, and NOT the human label (e.g. use the agent "
        "id, not 'R3'). Choose among three robot specs by how SEVERE the event is:\n"
        "  * DeprioritizeAgent — the robot is DEGRADED BUT STILL USABLE (most importantly a "
        "BATTERY problem: 'R3's battery is low/degraded/running flat', 'R5 low on charge'). "
        "It should be AVOIDED for heavy/long work but NOT removed. This is the SAFEST choice: "
        "it never stalls the build (it only raises the robot's cost so the solver prefers "
        "healthier robots). Use it whenever the robot can still move/work.\n"
        "  * ReplaceAgent — the robot BROKE DOWN / is immobile and should be REPLACED by a "
        "BACKUP/SPARE robot that takes over its work ('robot R failed, send a "
        "replacement/backup'). The spare is chosen automatically; you only name the faulted agent.\n"
        "  * ForbidAgent — a robot must simply be REMOVED from service with NO backup "
        "(its work is redistributed among the remaining robots), or the event explicitly "
        "says to take it offline without replacement.\n"
        f"{agent_lines}\n\n"
        "ACTIVE NO-GO ZONES. If the event describes a SPATIAL exclusion / keep-out / "
        "no-go / blocked area (robots must not enter a region), encode it as a "
        "ForbidZone whose `zone` is the EXACT zone key below and whose `assembly` is "
        "the EXACT node id (from NAMED NODES) of an assembly that zone covers:\n"
        f"{zone_lines}\n\n"
        "ALL still-open node ids (exhaustive reference; the NAMED NODES above are "
        "the labelled subset):\n"
        f"{', '.join(open_ids)}\n\n"
        "Call propose_respecification with the MINIMAL set of constraints that safely "
        "handles the event. Choose the kind by the event's NATURE: a robot DEGRADED but usable "
        "(LOW/FADING BATTERY, slowed) -> DeprioritizeAgent; a robot BROKEN/immobile to be "
        "covered by a backup/spare -> ReplaceAgent; a robot removed with NO replacement -> "
        "ForbidAgent; a SPATIAL no-go region -> ForbidZone (name the zone key + a covered "
        "assembly node id); a purely TEMPORAL no-work interval on a node -> ForbidWindow; "
        "a multi-robot transport TEAM DEADLOCKED while forming / the build STALLED waiting for "
        "a team to complete -> ReformTeam (no fields). "
        "A LOW-BATTERY / degraded robot is DeprioritizeAgent, NOT ForbidAgent/ReplaceAgent "
        "(it can still work). Do NOT use ForbidWindow for a spatial zone. If unsure, fewer."
    )


# _extract_tool_input: 모델 응답에서 우리가 강제한 tool 호출의 입력(=제안 JSON)만 뽑아냄.
# 응답은 여러 content block 으로 오는데, 그중 tool_use 타입이면서 이름이 맞는 것을 찾는다.
def _extract_tool_input(message) -> dict:
    for block in message.content:        # 응답의 각 content block 을 순회
        if block.type == "tool_use" and block.name == "propose_respecification":
            return block.input           # 찾으면 그 tool 입력(dict)을 반환
    # 여기까지 왔다 = tool 호출이 없었다 → 예외. 줄리아 호출부는 이 예외를 Reject 로 처리(안전 fallback).
    raise ValueError("model did not emit the required propose_respecification tool call")


# propose: 이 서비스의 핵심 함수. 사건+id 목록을 받아 검증된 제안 dict({"constraints":[...], "rationale":str})를 반환.
def propose(event: str, open_ids: list[str], agents: list[dict] | None = None,
            nodes: list[dict] | None = None, zones: list[dict] | None = None) -> dict:
    """Return a validated proposal dict: {"constraints": [...], "rationale": str}.

    `agents` / `nodes` / `zones` are optional descriptor lists so the model can ground a
    natural-language reference ("Robot R3 ...", "the final assembly", "the central no-go
    zone") onto the exact RobotID / node id / zone key a constraint must reference.

    Raises on transport / no-tool-call / schema-validation failure. The Julia
    caller treats any raise exactly like a Reject (-> safe fallback), so failing
    loudly here is correct.
    """
    # Claude 호출: messages.create 가 Messages API 요청. tool_choice 로 우리 tool 을 반드시 쓰게 강제.
    message = _get_client().messages.create(
        model=_MODEL,                    # 사용할 모델
        max_tokens=1024,                 # 응답 최대 토큰 수
        tools=[TOOL_SCHEMA],             # 모델에게 보여줄 tool(=DSL 문법)
        tool_choice={"type": "tool", "name": "propose_respecification"},  # 이 tool 만 쓰도록 못박음(자유 텍스트 차단)
        messages=[{"role": "user", "content": _build_prompt(event, open_ids, agents, nodes, zones)}],  # 위에서 만든 프롬프트
    )
    tool_input = _extract_tool_input(message)  # 응답에서 tool 입력(제안 JSON)만 추출
    # Validate against the DSL before it ever leaves the service. Defense in
    # depth: Julia re-validates on parse, the verifier re-checks feasibility.
    # 서비스를 떠나기 전에 DSL 로 검증(다층 방어: 줄리아가 파싱 때 재검증, verifier 가 실행가능성 재확인).
    proposal = RespecProposal.model_validate(tool_input)  # dict → 검증된 Pydantic 객체(틀리면 예외)
    return proposal.model_dump()         # 다시 순수 dict 로 바꿔 반환(JSON 직렬화 용이)
