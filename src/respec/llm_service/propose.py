"""
propose.py -- OOD event -> Claude (structured output) -> validated DSL dict.

The model's ONLY job: translate the open-world observation into the closed DSL.
It is forced to do so via Anthropic tool-use: tool_choice pins the single
`propose_respecification` tool whose input_schema IS the grammar (schema.py), so
the model physically cannot return free-form text to the solver.

Env:
    ANTHROPIC_API_KEY  (required)
    RESPEC_MODEL       (optional, default claude-opus-4-8)
"""
import os

import anthropic

from schema import RespecProposal, TOOL_SCHEMA

_MODEL = os.environ.get("RESPEC_MODEL", "claude-opus-4-8")
_client = None


def _get_client():
    """Lazily construct the Anthropic client so this module imports without
    ANTHROPIC_API_KEY set (e.g. for schema tests). The key is only required when
    a proposal is actually requested."""
    global _client
    if _client is None:
        _client = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY from env
    return _client


def _build_prompt(event: str, open_ids: list[str],
                  agents: list[dict] | None = None,
                  nodes: list[dict] | None = None) -> str:
    agents = agents or []
    nodes = nodes or []
    agent_lines = (
        "\n".join(f"  - {a.get('label') or a['id']}  ->  agent id: {a['id']}" for a in agents)
        or "  (no robots available to forbid)"
    )
    node_lines = (
        "\n".join(f"  - {n.get('label') or n['id']}  ->  node id: {n['id']}" for n in nodes)
        or "  (no labelled milestone nodes)"
    )
    return (
        "An open-world event occurred during execution of a multi-robot "
        "assembly plan.\n"
        f"EVENT: {event}\n\n"
        "You may ONLY add formal scheduling constraints (never change the "
        "objective).\n\n"
        "NAMED NODES. When the event refers to an assembly/part/milestone (e.g. "
        "for a Deadline or Precede), match the description in the event to one of "
        "these and use its EXACT node id — NOT the human label:\n"
        f"{node_lines}\n\n"
        "AGENTS (robots). If the event is a robot fault / a robot becoming "
        "unavailable, immobile, or removed from service, encode it as a single "
        "ForbidAgent whose `agent` is the EXACT agent id below — NOT a node id, "
        "and NOT the human label (e.g. use the agent id, not 'R3'):\n"
        f"{agent_lines}\n\n"
        "ALL still-open node ids (exhaustive reference; the NAMED NODES above are "
        "the labelled subset):\n"
        f"{', '.join(open_ids)}\n\n"
        "Call propose_respecification with the MINIMAL set of constraints that "
        "safely handles the event. For a robot fault, prefer one ForbidAgent on "
        "the matching agent id. For a due-date/expedite request, use one Deadline "
        "on the matching node id. Otherwise prefer Precede/ForbidWindow over "
        "Deadline (Deadline can make the problem infeasible). If unsure, fewer."
    )


def _extract_tool_input(message) -> dict:
    for block in message.content:
        if block.type == "tool_use" and block.name == "propose_respecification":
            return block.input
    raise ValueError("model did not emit the required propose_respecification tool call")


def propose(event: str, open_ids: list[str], agents: list[dict] | None = None,
            nodes: list[dict] | None = None) -> dict:
    """Return a validated proposal dict: {"constraints": [...], "rationale": str}.

    `agents` / `nodes` are optional {"id", "label"} descriptor lists so the model
    can ground a natural-language reference ("Robot R3 ...", "the final assembly")
    onto the exact RobotID / node id a constraint must reference.

    Raises on transport / no-tool-call / schema-validation failure. The Julia
    caller treats any raise exactly like a Reject (-> safe fallback), so failing
    loudly here is correct.
    """
    message = _get_client().messages.create(
        model=_MODEL,
        max_tokens=1024,
        tools=[TOOL_SCHEMA],
        tool_choice={"type": "tool", "name": "propose_respecification"},
        messages=[{"role": "user", "content": _build_prompt(event, open_ids, agents, nodes)}],
    )
    tool_input = _extract_tool_input(message)
    # Validate against the DSL before it ever leaves the service. Defense in
    # depth: Julia re-validates on parse, the verifier re-checks feasibility.
    proposal = RespecProposal.model_validate(tool_input)
    return proposal.model_dump()
