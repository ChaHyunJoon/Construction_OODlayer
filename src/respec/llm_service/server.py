"""
server.py -- The LLM re-specification microservice (fully separated from Julia).

Run:
    cd src/respec/llm_service
    export ANTHROPIC_API_KEY=sk-...
    uvicorn server:app --host 127.0.0.1 --port 8000

Julia (llm_bridge.jl) POSTs to /propose. The DSL JSON is the only thing that
crosses the process boundary -- the formal spec is the wire format, so the LLM
layer is fully swappable / language-agnostic behind this endpoint.
"""
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from propose import propose  # run from this dir; or `from .propose import propose` as a package
from schema import RespecProposal

app = FastAPI(title="ConstructionBots Re-specification LLM service")


class AgentRef(BaseModel):
    id: str            # exact RobotID string the ForbidAgent.agent field must echo
    label: str = ""    # human alias ("Robot R3 / robot 3") for grounding


class NodeRef(BaseModel):
    id: str            # exact node id string a Precede/Deadline/ForbidWindow must echo
    label: str = ""    # structural alias ("the final assembly", "sub-assembly 2")


class ProposeRequest(BaseModel):
    event: str
    open_ids: list[str]
    agents: list[AgentRef] = []
    nodes: list[NodeRef] = []


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/propose", response_model=RespecProposal)
def propose_endpoint(req: ProposeRequest):
    """OOD event + the still-mutable node ids -> validated DSL proposal.

    On ANY failure (no API key, model refusal, schema violation) we return 422.
    The Julia caller maps a non-200 to a Reject and engages the safe fallback,
    so the solver's guarantees hold even when this service misbehaves.
    """
    try:
        return propose(req.event, req.open_ids,
                       [a.model_dump() for a in req.agents],
                       [n.model_dump() for n in req.nodes])
    except Exception as e:  # noqa: BLE001 -- surface everything as a 422 to Julia
        raise HTTPException(status_code=422, detail=f"{type(e).__name__}: {e}")
