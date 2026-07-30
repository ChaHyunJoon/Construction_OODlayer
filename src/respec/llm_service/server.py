"""
server.py -- The LLM re-specification microservice (fully separated from Julia).

Run:
    cd src/respec/llm_service
    export ANTHROPIC_API_KEY=sk-...
    uvicorn server:app --host 127.0.0.1 --port 8000

Julia (llm_bridge.jl) POSTs to /propose. The DSL JSON is the only thing that
crosses the process boundary -- the formal spec is the wire format, so the LLM
layer is fully swappable / language-agnostic behind this endpoint.

────────────────────────────────────────────────────────────────────────────
[한국어 설명]
이 파일은 LLM 재명세 마이크로서비스의 HTTP 엔드포인트(줄리아와 완전 분리된 파이썬 프로세스).
프로젝트 역할: 줄리아(llm_bridge.jl)가 /propose 로 사건을 POST 하면, propose() 를 불러
검증된 DSL JSON 을 돌려준다. 프로세스 경계를 넘는 건 DSL JSON 뿐이라, LLM 계층을
언어에 상관없이 통째로 갈아끼울 수 있다. 실행: uvicorn server:app 로 띄움.

[문법 참고]
  · FastAPI — 파이썬 웹 프레임워크. app = FastAPI() 로 앱을 만든다.
  · @app.get("/health") / @app.post("/propose") — 데코레이터. 바로 아래 함수를 그 HTTP
    경로의 핸들러로 "등록"한다(줄@함수 = 함수를 감싸 부가기능을 붙이는 장식자).
  · 요청 본문 타입을 ProposeRequest(BaseModel) 로 선언하면 FastAPI 가 들어온 JSON 을
    자동으로 검증·파싱해 그 객체로 준다(핸들러 인자 req: ProposeRequest).
  · HTTPException(status_code=..., detail=...) — 이 예외를 던지면 그 상태코드로 응답됨.
  · [a.model_dump() for a in req.agents] — Pydantic 객체 리스트를 순수 dict 리스트로 변환.
────────────────────────────────────────────────────────────────────────────
"""
from fastapi import FastAPI, HTTPException  # 웹 앱 + HTTP 에러 응답용 예외
from pydantic import BaseModel              # 요청 본문 검증 모델

from propose import propose  # run from this dir; or `from .propose import propose` as a package  # 실제 LLM 호출 함수
from schema import RespecProposal           # 응답 모델(schema.py 와 공유)

app = FastAPI(title="ConstructionBots Re-specification LLM service")  # 서비스 앱 객체(핸들러들을 여기 등록)


# AgentRef: 요청에 담겨 오는 로봇 참조 한 건({id, label}).
class AgentRef(BaseModel):
    id: str            # exact RobotID string the ForbidAgent.agent field must echo  # 그대로 echo 할 정확한 RobotID
    label: str = ""    # human alias ("Robot R3 / robot 3") for grounding  # grounding 용 사람 별칭(선택)


# NodeRef: 요청의 노드 참조 한 건({id, label}).
class NodeRef(BaseModel):
    id: str            # exact node id string a ForbidWindow must echo  # ForbidWindow 가 그대로 echo 할 노드 id
    label: str = ""    # structural alias ("the final assembly", "sub-assembly 2")  # 구조적 별칭(선택)


# ZoneRef: 요청의 활성 출입금지 구역 참조 한 건(키+대략 위치+덮는 조립체 등).
class ZoneRef(BaseModel):
    key: str                       # exact zone-key string the ForbidZone.zone field must echo  # 그대로 echo 할 zone 키
    center: list[float] = []       # advisory world-frame disc center (LLM never emits geometry)  # 참고용 중심(모델은 좌표를 안 만듦)
    radius: float = 0.0            # advisory radius  # 참고용 반지름
    covers: list[str] = []         # ids of sub-assemblies the zone overlaps (ground the `assembly`)  # 이 구역이 덮는 조립체 id 들
    covers_root: bool = False      # zone also traps the root's deposit goals (whole-build case)  # 루트까지 덮으면 빌드 전체 이동 사례


# ProposeRequest: /propose 로 들어오는 요청 본문 전체 스키마.
class ProposeRequest(BaseModel):
    event: str                     # OOD 사건 설명(자연어)
    open_ids: list[str]            # 아직 안 끝난 노드 id 전체 목록
    agents: list[AgentRef] = []    # 금지/교체 가능한 로봇 목록(선택)
    nodes: list[NodeRef] = []      # 시간창 금지 가능한 마일스톤 노드 목록(선택)
    zones: list[ZoneRef] = []      # 활성 출입금지 구역 목록(선택)


# /health: 서비스가 살아있는지 확인용(줄리아가 시뮬 시작 전에 한 번 ping).
@app.get("/health")
def health():
    return {"status": "ok"}


# /propose: 사건 + id 목록 → 검증된 DSL 제안. 실패는 모두 422 로 돌려 줄리아가 Reject 로 처리하게 함.
@app.post("/propose", response_model=RespecProposal)
def propose_endpoint(req: ProposeRequest):
    """OOD event + the still-mutable node ids -> validated DSL proposal.

    On ANY failure (no API key, model refusal, schema violation) we return 422.
    The Julia caller maps a non-200 to a Reject and engages the safe fallback,
    so the solver's guarantees hold even when this service misbehaves.
    """
    try:
        # Pydantic 객체 목록들을 순수 dict 목록으로 바꿔 propose()에 넘김.
        return propose(req.event, req.open_ids,
                       [a.model_dump() for a in req.agents],
                       [n.model_dump() for n in req.nodes],
                       [z.model_dump() for z in req.zones])
    except Exception as e:  # noqa: BLE001 -- surface everything as a 422 to Julia  # 어떤 예외든 잡아서
        # 422 로 응답 → 줄리아는 비200 을 Reject 로 매핑해 안전 fallback 을 쓴다(서비스가 오작동해도 solver 보장 유지).
        raise HTTPException(status_code=422, detail=f"{type(e).__name__}: {e}")
