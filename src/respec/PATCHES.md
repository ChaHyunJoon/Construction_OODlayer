# Verified LLM Re-specification layer — wiring & patches

Backbone: **generate-as-formal-spec → verify → admit → re-solve → resume**, layered
on top of the untouched MILP/RVO stack. The LLM only translates open-world (OOD)
observations into a closed formal DSL; a verifier gate admits a proposal to the
solver only if it is grammatical, leaves the objective untouched, leaves completed
work invariant, and stays feasible against the safety invariant. Anything else →
safe fallback. The solver's existing guarantees are therefore never weakened.

```
[ Python service ]  OOD event ──▶ Claude (tool-use) ──▶ DSL JSON
src/respec/llm_service/                    │
                                       HTTP /propose
                                           │
[ Julia ] llm_bridge ──parse──▶ typed DSL proposal
          verifier ───────────▶ Admit / Reject     (Reject → engage_fallback!)
          compiler ───────────▶ @constraints injected into the MILP (before @objective)
          replan ─────────────▶ re-solve from frozen state, resume execution
```

The LLM layer is a **fully separated Python microservice**. Julia never imports
Python for it — it POSTs `{event, open_ids}` and gets validated DSL JSON back.
The formal spec is the wire format, so the service is swappable without touching
the solver. See `src/respec/llm_service/README.md`.

## New files (additive, zero risk to existing runs)
- `src/respec/spec_dsl.jl`  — the closed DSL (`ConstraintSpec` union). The grammar.
- `src/respec/compiler.jl`  — DSL → JuMP `@constraint` over (t0, tF, Xa).
- `src/respec/verifier.jl`  — admit/reject gate + feasibility trial solve + freeze.
- `src/respec/llm_bridge.jl`— thin HTTP client to the Python service + typed parse.
- `src/respec/replan.jl`    — orchestration called from the execution seam.
- `src/respec/respec.jl`    — aggregator include.
- `src/respec/llm_service/` — **separate Python process**: schema.py (DSL, mirrors
  spec_dsl.jl), propose.py (anthropic call), server.py (FastAPI), requirements.txt.

## Patch 1 & 2 — APPLIED to `src/essential_tg_coponents.jl`
`formulate_milp(::SparseAdjacencyMILP, ...)`:
1. added kwarg `extra_constraints=nothing`.
2. just before `milp = SparseAdjacencyMILP(...)` / `@objective` (was line ~1063):
   ```julia
   if extra_constraints !== nothing
       compile_proposal!(model, t0, tF, Xa, sched, extra_constraints)
   end
   ```
Default `nothing` ⇒ no-op ⇒ every existing call site behaves exactly as before.
Safe to leave applied even before the respec module is included (the name
`compile_proposal!` is only resolved when actually called, i.e. never under the
default).

## Patch 3 — TODO: add deps, then wire the include
1. `Project.toml` `[deps]`: add **HTTP** and **JSON3** (Julia side only — no
   anthropic dep in Julia; that lives in the Python service).
   ```
   julia> using Pkg; Pkg.add(["HTTP","JSON3"])
   ```
2. In `src/ConstructionBots.jl`, add after `include("full_demo.jl")` (line 54):
   ```julia
   using HTTP
   using JSON3
   include("respec/respec.jl")
   ```
   (respec uses `AbstractID`, `formulate_milp`, `SparseAdjacencyMILP`, `get_vtx`,
   `update_project_schedule!`, `reset_cache!`, `PlannerEnv` — all defined earlier,
   so it must be included LAST.)
3. Optionally export for scripts:
   ```julia
   export maybe_respecify!, OODQueue, RespecProposal, Precede, Deadline,
          ForbidWindow, ForbidAgent, verify, build_invariant
   ```

> Do NOT wire the include until HTTP/JSON3 are installed — a missing dep makes the
> whole module fail to load and would break the existing demo.

## Patch 4 — TODO: the execution seam in `src/demo_utils.jl`
Between the current lines 96 and 97 of `simulate!`:
```julia
        ConstructionBots.step_environment!(env)
        # === RESPEC HOOK: verified LLM re-specification on OOD ===============
        if hasproperty(sim_params, :ood_queue) && sim_params.ood_queue !== nothing
            ConstructionBots.maybe_respecify!(env, sim_params.ood_queue)
        end
        # ====================================================================
        newly_updated = ConstructionBots.update_planning_cache!(env, 0.0)
```
To carry `ood_queue` without touching the `SimParameters` struct yet, pass it via
a closure or a module-global for the MVP; promote it to a real field in week 6.

## Week-1/2 TODOs flagged in code (the only real engineering risk)
- [DONE] `verifier.jl build_invariant`: fills `frozen_t0/frozen_tF` from the
  schedule's realized times (closed → both ends, active → start) as >= lower
  bounds. Verified by the FREEZE TEST in `test_respec_gate.jl` (46 closed nodes
  pinned, re-solve respects all bounds → partial, not full, replan).
- `compiler.jl bound_to_agent`: implement against the real node types
  (RobotGo / FormTransportUnit / TransportUnitGo …) for `ForbidAgent`.
- `replan.jl engage_fallback!`: make `RESPEC_HOLD[]` actually zero RVO preferred
  velocities in `step_environment!` (route_planning.jl), then clear it.

## Regression baseline
`julia --project=. test_respec_gate.jl` builds a real env (tractor) and asserts:
GATE (admit feasible / reject infeasible) + FREEZE (completed work pinned). Run
it after any respec change.

## Smoke test (no LLM, hand-written proposal) — run this first, week 3
```julia
using ConstructionBots
# build an env via run_lego_demo up to the assignment stage, then:
prop = RespecProposal([Precede(idA, idB)])          # idA,idB from env.sched
inv  = build_invariant(env)
@assert verify(prop, env, inv) isa ConstructionBots.Admit
# negative control: an impossible deadline must be REJECTED, not crash:
bad  = RespecProposal([Deadline(idB, 0.0)])
@assert verify(bad, env, inv) isa ConstructionBots.Reject
```
This proves the gate works before any API key is involved — the LLM is the last
thing to wire, exactly because the verifier, not the LLM, is what makes it safe.

## End-to-end with the LLM service (week 6+)
1. Start the Python service (see `llm_service/README.md`):
   `uvicorn server:app --host 127.0.0.1 --port 8000`
2. In Julia, before the run: `@assert respec_service_ready()`.
3. Push an OOD event into the queue and let `maybe_respecify!` drive
   generate→verify→admit→re-solve. A down service ⇒ `llm_to_proposal` throws ⇒
   treated as Reject ⇒ safe fallback. The sim never crashes on LLM failure.
```
