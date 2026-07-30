# Fast iteration workflow (respec layer)

The slow part of testing the respec layer is paid in three layers, and most edits
touch only ONE of them. These tools let you pay only for the layer you changed.

| layer you edited | what was slow | fast loop to use |
|---|---|---|
| Julia commit/verify/schedule (`replan.jl`, `verifier.jl`) | 85s precompile + minutes env build, **every** one-shot `julia` run | **persistent Revise REPL** — `dev_session.jl` |
| LLM prompt / schema (`llm_service/propose.py`, `schema.py`) | full env build **and** real LLM round-trips | **env-free Python harness** — `translate_eval.py` over a cached fixture |
| the env build / stepping itself | unavoidable | rebuild the fixture / `rebuild()` |

The serialize-ban (timing-persistence gap doc) is about the **PlannerEnv** only.
`llm_fixture.json` is plain strings/dicts → safe to cache across processes.

## 1. Build the fixture once (only when the env build or descriptors change)

```
julia +lts --project=. tools/dump_llm_fixture.jl
```

Builds the tractor env, steps to mid-build (closed≥8), and writes
`tools/llm_fixture.json` = the exact `/propose` request body (`open_ids`,
`agents`, `nodes`) the production `llm_to_proposal` would send, plus a
sub-assembly-id → node-id map so the Python cases know the gold targets.

## 2. Iterate on the LLM translation (prompt/schema) — seconds, no Julia

```
HJC="C:/Users/chahj/PythonCodes/venv/hjcnlp/Scripts/python.exe"   # has anthropic
export ANTHROPIC_API_KEY=sk-ant-...
"$HJC" tools/translate_eval.py --quick          # zone_closure only, 1 sample/paraphrase
"$HJC" tools/translate_eval.py                  # all cases x2 samples
"$HJC" tools/translate_eval.py --case zone_closure --samples 3
```

Calls `propose()` in-process (fresh import), so edits to `propose.py`/`schema.py`
apply on the next run — **no uvicorn restart**. Scores translation only (DSL kind
+ target id). Exit 0 iff all targets hit.
Model = `RESPEC_MODEL` (propose.py default `claude-opus-4-8`, the production model
— don't swap to a weaker one or you're testing the wrong thing).

### Auto-run (configured)
`.claude/settings.json` has a PostToolUse hook: whenever **Claude** edits
`propose.py` or `schema.py`, `translate_eval.py --quick` runs automatically and the
result is fed back into Claude's context. Needs `ANTHROPIC_API_KEY` in Claude
Code's environment (start Claude Code from a shell that exported it) and the
fixture to exist; otherwise it emits a clear skip message. No-op for other files.

## 3. Iterate on Julia commit/verify logic — hot reload, no rebuild

```
julia +lts --project=. -i tools/dev_session.jl
```

Builds `BASE_ENV` once, then at the REPL after each Julia edit (Revise reloads):

```
t()        # re-run the LLM-FREE timing-persistence check on a fresh deepcopy
rebuild()  # only if you changed the env build / stepping
```

## When to run the full thing

Only to **confirm** a change, not to iterate: `eval_respec_ood.jl` (full behavioral
metric, needs the uvicorn service up) and `test_respec_timing_persist.jl` (LLM-free,
one-shot). Use the fast loops above for everything in between.
