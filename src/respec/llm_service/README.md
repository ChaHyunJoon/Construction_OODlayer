# LLM re-specification service (Python, fully separated)

The LLM layer runs as a standalone HTTP service. Julia never imports Python for
this — it only POSTs `{event, open_ids}` and receives a validated DSL proposal.
The formal spec (the DSL JSON) is the wire format, so this whole service is
swappable without touching the solver/verifier.

```
[ Julia ] llm_bridge.jl ──HTTP POST /propose──▶ [ Python ] server.py
                                                   └ propose.py ─▶ Claude (tool-use)
                                                   └ schema.py  ─▶ DSL grammar + validation
        ◀──── {"constraints":[...], "rationale": "..."} (validated DSL) ────┘
```

## Setup
Deps are installed into the existing **hjcnlp** venv
(`C:\Users\chahj\PythonCodes\venv\hjcnlp`, Python 3.10) — anthropic, fastapi,
uvicorn, pydantic. To (re)install: `hjcnlp\Scripts\python.exe -m pip install -r requirements.txt`.

Run with ABSOLUTE paths + `--app-dir` so it works from any directory (a relative
path gives "filename, directory name, or volume label syntax is incorrect"; in
PowerShell a quoted exe path also needs the `&` call operator):
```powershell
$env:ANTHROPIC_API_KEY = "sk-..."          # required
$env:RESPEC_MODEL = "claude-opus-4-8"      # optional
& "C:\Users\chahj\PythonCodes\venv\hjcnlp\Scripts\python.exe" -m uvicorn server:app `
    --host 127.0.0.1 --port 8000 `
    --app-dir "C:\Users\chahj\PythonCodes\venv\ConstructionBots.jl\src\respec\llm_service"
```
Verified working without a key: `import schema/propose/server`, app routes
`/health` + `/propose`, and DSL validation (good proposal validates, bad `kind`
is rejected). The key is only needed when `/propose` actually calls Claude.

## Contract
- `GET  /health` → `{"status":"ok"}` (Julia checks this before a run)
- `POST /propose` body `{"event": str, "open_ids": [str]}`
  → `200 {"constraints": [...], "rationale": str}` on success
  → `422 {"detail": "..."}` on any failure → Julia treats as Reject → fallback

## Test without Julia
```bash
curl -s localhost:8000/propose -H 'content-type: application/json' \
  -d '{"event":"Robot R3 reports a motor fault and is immobile.",
       "open_ids":["RobotID(3)","RobotGoID(7)","FormTransportUnitID(2)"]}' | jq
```

## Why a separate process (vs PyCall in-process)
- Official `anthropic` SDK + Python eval/observability tooling for the Year-3
  question "which OOD classes does the LLM translate reliably?"
- Crash isolation: a hung/erroring LLM call cannot take down the Julia sim.
- Language-agnostic boundary: swap model, add caching, or replace with a
  fine-tuned local model without recompiling ConstructionBots.

The grammar in `schema.py` MUST stay in lockstep with `../spec_dsl.jl`. Those two
files are the same DSL written twice; the verifier in Julia is the safety gate.
