# LLM services (Python)

## 🔴 2026-08-29 — the Anthropic `/propose` service was REMOVED

This directory used to host a standalone FastAPI service on **:8000** that
translated a natural-language OOD event into a validated DSL proposal by calling
Claude:

```
[ Julia ] llm_bridge.jl ──HTTP POST /propose──▶ [ Python ] server.py
                                                   └ propose.py ─▶ Claude (tool-use)
```

`server.py`, `propose.py` and `test_propose.py` are **gone**, along with the
Julia client that spoke to them (`llm_to_proposal`, `respec_service_ready` in
`../llm_bridge.jl`). The lane was measured dead before removal: nothing was
listening on :8000, `ANTHROPIC_API_KEY` was not in the environment, no launcher
for it existed anywhere in the repo, and `propose.py`'s default model id was not
a real dated Anthropic model. `test_propose.py` had to be `--ignore`d in every
pytest run because it `sys.exit(1)`s at import and could fire a **paid** API
call during collection — that landmine is what the removal was for. There is no
`anthropic` dependency left in this repo.

## What runs now

**`dspy_service.py` is the only LLM service.** It is a different seam and never
used the one above: it serves `/macro` (plus its own `/health`) on **:8077**, and
Julia reaches it from `tools/monitor/policy.jl` (`service_decide`), not from
`llm_bridge.jl`. `DSPY_URL` selects the address — several ports appear across the
repo, so match the uvicorn you actually started, not a number in a doc.

```bash
python -m uvicorn dspy_service:app --host 127.0.0.1 --port 8077
```

Deps: `requirements.txt` here lists the subset needed to run the service alone
(fastapi / uvicorn / pydantic); the root `requirements.txt` is the full analysis
environment and pins `dspy==3.3.0` — read the comment above that pin before
bumping it, it is load-bearing.

## What survived, and why

`schema.py` stays. It is the **shared proposal schema**, not part of the deleted
lane: the DSPy lane and the verifier both use it, and its constraint-kind union
must stay **set-equal** to `EMITTABLE_KINDS` in `../llm_bridge.jl`. Those two
files are the same DSL written twice.

The safety boundary is unchanged and still on the solver side: whoever proposes,
Julia does the typed parse (`_parse_proposal` in `../llm_bridge.jl`) and then
`verify()` decides what is admitted. `schema.py` MUST stay in lockstep with
`../spec_dsl.jl`.
