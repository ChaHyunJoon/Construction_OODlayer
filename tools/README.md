# Fast iteration workflow (respec layer)

The slow part of testing the respec layer is paid in three layers, and most edits
touch only ONE of them. These tools let you pay only for the layer you changed.

| layer you edited | what was slow | fast loop to use |
|---|---|---|
| Julia commit/verify/schedule (`replan.jl`, `verifier.jl`) | 85s precompile + minutes env build, **every** one-shot `julia` run | **persistent Revise REPL** — `dev_session.jl` |
| LLM prompt / schema | full env build **and** real LLM round-trips | 🔴 **gone with the Anthropic lane** — see §2 |
| the env build / stepping itself | unavoidable | rebuild the fixture / `rebuild()` |

The serialize-ban (timing-persistence gap doc) is about the **PlannerEnv** only.

## 1. `tools/llm_fixture.json` — an ORPHANED committed artifact

It is the exact `/propose` request body (`open_ids`, `agents`, `nodes`) that the
production `llm_to_proposal` used to send, plus a sub-assembly-id → node-id map of
gold targets.

> 🔴 **2026-08-29: nothing reads it any more.** Its only two consumers
> (`translate_eval.py`, `verify_battery_translation.py`) were removed with the
> Anthropic lane, and its generator (`tools/diagnostics.jl dump_fixture`) had already
> been removed on 2026-08-23 as dead code. It was left in the tree deliberately rather
> than deleted: it cannot be regenerated, and the descriptor shapes it records are the
> same ones `llm_bridge.jl` still produces. **Delete it if you don't want the orphan.**

## 2. Iterating on the LLM translation — 🔴 REMOVED 2026-08-29

`translate_eval.py` and `verify_battery_translation.py` are **gone**. Both needed
`ANTHROPIC_API_KEY`, and both drove the deleted `/propose` service
(`llm_service/{server,propose}.py`), which was the repo's only Anthropic caller.
The lane was measured dead before removal: nothing listening on :8000, no key in
the environment, no launcher anywhere, and a default model id that was not a real
dated Anthropic model.

⚠️ The "Auto-run (configured)" note that used to sit here described a PostToolUse
hook in `.claude/settings.json` that re-ran `translate_eval.py --quick` after edits
to `propose.py`/`schema.py`. **That hook did not exist** — `.claude/settings.json`
contains only a `worktree` key. The prose was stale, not a live paid-call trigger.

The surviving LLM lane is DSPy (`llm_service/dspy_service.py`, `/macro` on :8077),
and it has its own pytest suite in `src/respec/llm_service/test_*.py` that runs
offline — no API key, no network. Just run `pytest`.

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

Only to **confirm** a change, not to iterate: `test_respec_timing_persist.jl`
(LLM-free, one-shot). (`eval_respec_ood.jl`, the full behavioral metric, needed the
deleted uvicorn `/propose` service.) Use the fast loops above for everything in between.
