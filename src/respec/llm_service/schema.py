"""
schema.py -- The formal-specification DSL, Python side.

This MIRRORS src/respec/spec_dsl.jl exactly. It is the single source of truth on
the Python side for (a) the Anthropic tool input_schema that FORCES the model to
emit only grammar-shaped JSON, and (b) Pydantic validation of what comes back.

The wire contract (what /propose returns) is:
    {"constraints": [ {<one of the kinds below>}, ... ], "rationale": str}

Safety note: the model can only ever produce one of these four kinds. Anything
else fails validation here and again at the typed parse in Julia (llm_bridge.jl).
The verifier in Julia -- not this file, not the model -- is what admits a
proposal to the solver. Keep these four kinds in lockstep with spec_dsl.jl.
"""
from typing import Annotated, List, Literal, Union

from pydantic import BaseModel, Field


class Precede(BaseModel):
    """Node `a` must complete before node `b` starts: tF[a] <= t0[b]."""
    kind: Literal["Precede"] = "Precede"
    a: str
    b: str


class Deadline(BaseModel):
    """Node `node` must finish no later than `tF_max`. CAN make the problem
    infeasible -- that is intentional; the Julia verifier's feasibility gate
    catches it and routes to the safe fallback."""
    kind: Literal["Deadline"] = "Deadline"
    node: str
    tF_max: float


class ForbidWindow(BaseModel):
    """Node `node` may not be active during [t_lo, t_hi]."""
    kind: Literal["ForbidWindow"] = "ForbidWindow"
    node: str
    t_lo: float
    t_hi: float


class ForbidAgent(BaseModel):
    """Agent `agent` is unavailable for tasks starting at/after `after`."""
    kind: Literal["ForbidAgent"] = "ForbidAgent"
    agent: str
    after: float = 0.0


ConstraintSpec = Annotated[
    Union[Precede, Deadline, ForbidWindow, ForbidAgent],
    Field(discriminator="kind"),
]


class RespecProposal(BaseModel):
    constraints: List[ConstraintSpec] = Field(default_factory=list)
    rationale: str = ""


# --- Anthropic tool schema: the grammar the model is FORCED to fill ----------
# Hand-written (rather than derived from Pydantic) so the model sees a flat,
# unambiguous schema with the kind-enum up front. Validation of the result still
# goes through RespecProposal above.
TOOL_SCHEMA = {
    "name": "propose_respecification",
    "description": (
        "Propose additional formal scheduling constraints (NEVER objective "
        "changes) that re-specify the problem to handle the observed open-world "
        "event. Only ADD constraints. Reference nodes/agents by the exact ids "
        "given in the prompt. Prefer Precede/ForbidWindow over Deadline."
    ),
    "input_schema": {
        "type": "object",
        "required": ["constraints", "rationale"],
        "properties": {
            "rationale": {"type": "string"},
            "constraints": {
                "type": "array",
                "items": {
                    "type": "object",
                    "required": ["kind"],
                    "properties": {
                        "kind": {
                            "type": "string",
                            "enum": ["Precede", "Deadline", "ForbidWindow", "ForbidAgent"],
                        },
                        "a": {"type": "string"},
                        "b": {"type": "string"},
                        "node": {"type": "string"},
                        "agent": {"type": "string"},
                        "tF_max": {"type": "number"},
                        "t_lo": {"type": "number"},
                        "t_hi": {"type": "number"},
                        "after": {"type": "number"},
                    },
                },
            },
        },
    },
}
