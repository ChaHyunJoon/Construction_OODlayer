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
TOOL_SYNTHESIS=1 SYNTH_MULTI_AGENT=1 \
  python -m uvicorn dspy_service:app --host 127.0.0.1 --port 8077
```

### The two synthesis flags — both default OFF, and both are read **once, at import**

| flag | what turns on | cost |
|---|---|---|
| `TOOL_SYNTHESIS=1` | the T2 tool-synthesis lane. Without it `maybe_synthesize`/`synthesize_multi` return `tool_minted="disabled"` and **open no socket at all** (R13). | one billable call per firing |
| `SYNTH_MULTI_AGENT=1` | `run_synthesis` picks the **3-agent** lane (`observe → design → compose`) instead of the single-agent one. | 3 per firing; **+1** if the groundability gate fires, **+2** if F2 does — measured 6 (zone) and 5 (mild) on 2026-09-03 |

🔴 **Both are compared against the literal string `"1"`.** `true`, `yes`, `TRUE` and `on` all
read as OFF, silently — the lane just reports that it did not fire.

🔴 **Why `SYNTH_MULTI_AGENT=1` belongs in the recipe now.** The firing verdict
(`expressible`) comes from a different place in each lane, and the two do not agree on the
measured OOD events: in the single-agent lane it is a *tool argument of the decision agent*
and it was measured `True` on both OOD lanes (2026-08-31 live, mild + zone → `chosen=NOOP`,
`synthesis_event=false`); in the 3-agent lane it is **agent-2's own output field** and it was
measured `False` on both (2026-09-02, `results/2026-09-02-f7-synth-multi.json`). So a service
started without this flag **cannot** produce a synthesis event on these two events, no matter
what else is fixed downstream.

### 🔴 Traps this recipe exists to close

1. **A stale process answers `/health` with 200.** On 2026-09-03 five uvicorns were found
   alive from 08-30/08-31 — two of them with a **deleted** worktree as their cwd — all
   serving `/health` 200 while `synthesize_multi` (added 09-02 16:45) did not exist in any of
   them. `/health` carries **no generation stamp** — no git rev, no flag echo — and file mtime
   is not one either (measured twice-false in the 2026-08-31 S1 lane). **Process start time vs.
   commit time, or a content hash, is the only honest check.** Before trusting a number, run
   `ps -p <pid> -o lstart` and compare it against `git log -1 --format=%ad -- src/respec/llm_service/`.
   ⚠️ The response *shape* did differ by accident on 2026-09-03 (the five stale ones had no
   `cache`/`billed` field, a current one does) — **do not lean on that.** It is a side effect of
   an unrelated edit, nothing keeps it true, and it tells you nothing about `synthesize.py`.
2. ~~**Nothing enforces any of this.**~~ **Closed 2026-09-03.** `/health` now carries a
   generation stamp and there is a gate that reads it — see the next section. What is still
   *not* covered: the `wm4spacecraft_manufacturing/sweep/` path (`run_4pol_parallel.sh` /
   `run_shard.sh` / `llm_ood_eval.py`) contains **no `/health` check of any kind** (measured),
   so a sweep started that way is still unguarded.
3. **`LEDGER` is process-global** (`synthesize.py`, `LEDGER = SynthesisLedger()`). Probes pass
   their own ledger per case; the service does not. So `tool_minted` ("new canon" vs. a
   repeat) and `K` accumulate across every decision and every board for the life of the
   process, and they do **not** mean what the same fields mean in a probe run.

### The gate — `generation.py`

`/health` carries a **generation stamp**, and `generation.py` is both the library that
computes it and the CLI that judges a running service against this tree.

```bash
# 이 트리를 서빙 중인가? 통과 0, 그 밖 1.
.venv/bin/python src/respec/llm_service/generation.py --url http://127.0.0.1:8077 \
    [--require-tool-synthesis] [--require-multi-agent]

# 셸 레시피용 (판정식은 위 CLI 한 벌뿐이다)
source tools/require_current_service.sh
require_current_service "$DSPY_URL" || exit 3
```

The verdict distinguishes five failures because **their prescriptions differ**:

| code | what it means | what to do |
|---|---|---|
| `unstamped` | no stamp at all — a pre-2026-09-03 process. **All five killed that day were this.** | restart |
| `blind` | `code_fingerprint` is `null` — the process cannot read its own source (deleted worktree) | restart |
| `stale` | it reads, and the bytes differ from this tree | restart |
| `flag_off` | right generation, lane switched off | restart with the env var |
| `unreachable` | nothing answered. 🔴 **not a pass** | start it |

🔴 The fingerprint is **frozen at import**, not recomputed per request. Recomputing would make
the stamp lie in the *opposite* direction: edit a file and the running process keeps serving the
old bytes while `/health` reads the new disk and reports "current" — the gate would wave through
exactly the case it exists to catch.

🔴 `test_*.py` and `conftest.py` are **excluded** from the fingerprint. They are not served, and
including them would make every test edit falsely age a live service — after which nobody trusts
the gate.

**Where it is wired** (all abort now; three of the four previously only printed a warning):
`tools/monitor/regen_case_policy_matrix.sh` · `tools/monitor/regen_router_cases.sh` ·
`tools/monitor/regen_all_cases.sh` · `tools/regen_d20.sh` · and `tools/monitor/render_demo.jl`
at the run entry (the path S1 actually used), which calls the same CLI rather than re-deriving
the verdict in Julia.

🔴 **`tools/monitor/policy.jl`'s `dspy_ready()` is deliberately NOT gated.** Six Julia tests
serve a fake `/health` from a loopback server to exercise the real lane
(`test/service_decide_ships_{agents,zones,routing_kind}.jl`, `test/tool_choice_gate.jl`,
`test/tool_lane_keys_survive.jl`, `test/tool_args_grounding.jl`); requiring a stamp there would
turn all six red for reasons unrelated to any service generation. The gate lives at the **run
entry point** instead, which no test goes through.

### 🔴 `DSPY_CACHE` — on by default, and a replay looks exactly like a live call

`/health` reports `cache` (measured `true` on a service started with the recipe above). With the
cache on, a repeated request returns a **disk replay** of an earlier answer while still looking
like a fresh response, and `/health`'s `calls` counter is **not** a billing counter — it counts
hits too (`billed` is the one that counts money). For any run whose numbers you intend to quote,
start the service with `DSPY_CACHE=0`, exactly as `tools/probes/probe_synth_multi_lane.py` does
(it sets the variable **before importing** `dspy_service` and then asserts `S.CACHE is False`,
because the value is frozen at import).

### Free channel: render the prompt without paying

`/decide` fills `llm_input`/`state`/`surrogate_input`/`valid` before it looks at the lane
list, and the billing counter sits inside the LM path. Calling it with `lanes: []` therefore
returns the fully rendered prompt for **0 billable calls** (measured 2026-08-31: `/health`
`calls` 0 → 0). Use it for every "did the prompt change the way I think it did" question.

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
