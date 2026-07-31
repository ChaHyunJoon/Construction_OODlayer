# Oracle eval-set generator

Ground-truth for the surrogate world model (see `../EVALUATION.md`). For each OOD
decision point it tries **every** candidate DSL macro, rolls each to completion
through the **production** re-spec dispatch, and records the true outcome +
feasibility-lexicographic ranking. That ranking is what the surrogate's
decision-regret / NDCG@k is scored against.

## Slice 1 — robot-fault class (`gen_oracle_faults.jl`)

- Model: `tractor` (`get_project_params(4)`), RVO **off** (so `deepcopy(env)` is a
  complete checkpoint), `n_spare_per_pool=1` (so `ReplaceAgent` does a real 1:1
  hand-off instead of degrading to reassign).
- One decision point (fault after `CLOSED_AT_DECISION=8` closed nodes), deterministic
  solo fault target (`pick_solo_fault_target`, avoids the `has_edge` crash).
- Candidates: `{ReplaceAgent, ForbidAgent, DeprioritizeAgent, no-op}`.
- Each candidate applied via the **production seam**
  (`set_respec_producer!` + `push_ood!` + `respec_step!`) → identical machinery to the
  future surrogate/LLM pipeline (fairness invariant).
- **Global contamination firewall**: all mutable module globals
  (`SPARE_POOLS`, `FAULTED_ROBOTS`, `AGENT_COST_BIAS`, `RESTRICTION_ZONES`,
  `RESPEC_HOLD`, …) are snapshot once and restored before every candidate.
- Metrics (reduced for slice 1): `{feasible, completion_rate, makespan}` →
  feasibility-lexicographic rank. Energy/SoC (battery) and the 4-axis `RunMetrics`
  come in a later slice.

### Run
From the `ConstructionBots.jl` repo root (needs Julia 1.10 LTS + HiGHS; **no** LLM
service required — the oracle is LLM-free):

```bash
julia +lts --project=. /c/Users/chahj/PythonCodes/venv/wm4spacecraft_manufacturing/oracle/gen_oracle_faults.jl --smoke
```

`--smoke` uses a small roll cap (3k steps) to shake out interfaces fast; drop it for
a full run (80k cap). Output: `out/oracle_faults[_smoke].json`.

## Next slices (planned)
- Battery + zone OOD classes; SoC globals (`BATTERY_FLEET`) in the firewall.
- Full `RunMetrics` (wire `placed_parts` / `robot_busy_time` / `transport_distance`).
- Many decision points × assembly models → the held-out oracle eval **set**.
- Python loader (`out/*.json` → the surrogate's scoring harness).
