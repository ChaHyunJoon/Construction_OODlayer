# Autonomy completion — implementation workflow (2026-06-22)

Goal: complete the **autonomous** loop of the respec layer — the parts of the
backbone `detect → translate → verify → admit → re-solve → resume` that are still
manual or missing. Scope = three pieces, in build order:

1. **Resume full-loop** (⑥⑦) — make a committed re-spec STICK while the sim keeps
   running to a finished build, and run the enabled seam live end-to-end.
2. **OOD detection / abstain** (①) — replace the manual `push_ood!` stub with an
   autonomous detector (rule-based MVP → conformal-abstain).
3. **OOD visualization** (⑨) — MeshCat markers for fault / hold / reassign / active
   constraint.

This doc mirrors the **fast-iteration philosophy** of `tools/README.md`: every
piece gets a *fast inner loop* so you never pay the 85s precompile + minutes env
build + LLM round-trips just to test one layer. Pay only for the layer you changed.

> Build order rationale: **Resume first** — its full-loop driver is the test
> harness the other two plug into. Detection feeds events into that loop;
> visualization renders what the loop does.

---

## Piece 1 — Resume full-loop (⑥⑦)

### The blocker (code-grounded)
`commit_respec!` (replan.jl:232) and `fault_robot_and_reassign!` (reassign.jl:260)
end by calling **`reset_cache!`** (essential_tg_coponents.jl:1327-1337), which:
```
process_schedule!(sched)
empty!(cache.closed_set); empty!(cache.active_set); empty!(cache.node_queue)
for v in vertices: if is_root_node(v) -> active_set/node_queue seeded from ROOT
```
It re-seeds the planning frontier **from the project roots**, discarding which
nodes are already built. Correct for a from-scratch plan, fatal for resumption —
the sim would re-execute completed work. reassign.jl:256-259 says so explicitly:
*"ERASES execution progress … Fine here (we don't resume)."*

### What to build
1. **`reset_cache_resume!(cache, sched)`** — a resume-preserving sibling of
   `reset_cache!` (new fn in replan.jl, or beside reset_cache!):
   - `process_schedule!(sched)` (keep — it's a fixed point on the persisted MILP
     times, see the timing-persistence gap doc);
   - **do NOT** `empty!(closed_set)`;
   - recompute `active_set` = the **frontier**: vertices not in `closed_set` whose
     predecessors are all in `closed_set`; rebuild `node_queue` from that frontier
     (reuse `isps_queue_cost` / the readiness test `update_planning_cache!` uses).
2. **`commit_respec!(env, milp, proposal; resume::Bool=false)`** — when `resume`,
   call `reset_cache_resume!` instead of `reset_cache!`. Default `false` keeps every
   current caller (tests, eval) byte-identical.
3. **Production paths run with `resume=true`**: `maybe_respecify!` (replan.jl:141)
   and the reassign commit (reassign.jl:260) run *inside a live sim*, so they resume.
4. **Full-loop driver** (`tools/run_full_loop.jl` or a test): build → enable
   `RESPEC_ENABLED[]` → run `simulate!` → inject an OOD at iter K (manual `push_ood!`
   for now; the detector replaces this in Piece 2) → assert the sim reaches
   `project_complete(env)` with the constraint satisfied and `closed_set` never
   shrinking.

### Fast loop (LLM-free, Julia hot-reload)
Resume is pure Julia → use the persistent **Revise** session `tools/dev_session.jl`.
Add a `resume_test()` there:
```
env = deepcopy(BASE_ENV)            # already mid-build (closed≈46)
commit a hand-written binding Precede via commit_respec!(...; resume=true)
n0 = length(env.cache.closed_set)
loop: step_environment!(env); update_planning_cache!(env,0.0)  until project_complete or cap
assert: closed_set monotonic (never < n0), makespan finite, tF[a] <= t0[b] at the end
```
Edit `reset_cache_resume!` → Revise reloads → call `resume_test()` again. Seconds
per iteration, no rebuild, no LLM. Only the FINAL enabled-seam run (Piece-1 step 4
with the real `simulate!`) is a one-shot confirmation.

### Done-gate
From a mid-build env, a committed binding re-spec persists AND the sim continues to
a complete, valid build with `closed_set` never regressing. Then the same via the
live `respec_step!` seam in `simulate!` (one recorded run).

### Risks
- The frontier recompute must match the schedule's real readiness semantics (look at
  how `update_planning_cache!`, route_planning.jl:312, decides a node is ready) or
  the sim stalls/double-executes. Verify `closed_set` monotonicity as the guard.
- `reset_cache!` is also used by the from-scratch path — do NOT change it; add a
  sibling.

---

## Piece 2 — OOD detection / abstain (①)

> **2026-06-23 교정 — injection vs detection.** 이 Piece는 OOD가 어떻게 *주어지는가*를
> 수동 `push_ood!` 문자열로 두고 *detection*에 집중했다. 그러나 사용자 목표는 시뮬레이터가
> 두 종류의 OOD(로봇 고장, 출입금지 구역)를 **물리 상태로 실제 생성**하는 것이다. 그
> "물리적 OOD 생성기"는 별도 설계로 분리했다 →
> **`simulator_ood_generation_design_2026-06-23.md`** (1-2=항법 no-go zone,
> 1-1=방위별 spare pool; 둘 다 신규 시뮬레이터 코드 + zone은 신규 DSL `ForbidZone`).
> 빌드 순서상 **생성기(그 문서 §4의 1·2·3)가 먼저**이고, 여기의 detection은 그 위에서
> 수동 트리거를 자동 트리거로 바꾸는 다음 단계다.

### The stub (code-grounded)
`OODQueue` (replan.jl:14-24) is a manual string queue; `respec_step!`
(replan.jl:58-61) just drains it. The proposal's pillar ③ wants the **detector** to
decide *when* an OOD has occurred and, when uncertain, **abstain/defer** (human or
solver) — a conformal-prediction trigger. Nothing detects today.

### What to build (two layers, ship the first, then the second)
1. **Rule-based detector (MVP, deterministic, testable without LLM)** — `detect(env)
   -> Union{Nothing,String}` run inside `respec_step!` before the manual poll:
   - *robot-stuck*: an agent with a pending task whose position/preferred-velocity is
     ~0 for ≥N steps → emit e.g. `"Robot R<k> has not moved for N steps and appears
     stuck"`.
   - *schedule-slip*: projected makespan exceeds the committed plan by a margin → emit
     a deadline/expedite event.
   - Emitting an NL string keeps the LLM translation layer (already 24/24) as the
     NL→DSL step — the detector only decides *that* + *a description*, not the DSL.
2. **Conformal abstain layer (the C3 research contribution)**:
   - *Calibration (offline, cached)*: run K nominal sims, record a nonconformity
     score per step (e.g. residual between predicted and realized progress). Store the
     `(1-α)` empirical quantile `τ`. Scores are plain floats → cache to JSON (safe,
     like `tools/llm_fixture.json`; the serialize-ban is PlannerEnv-only).
   - *Runtime*: score the current step; `score > τ` ⟹ flagged OOD with guaranteed
     `(1-α)` coverage ⟹ trigger respec; if the chosen action's verify REJECTS or
     confidence is low ⟹ **abstain** = `engage_fallback!` + human/solver handoff
     (this is where pillar-③ "위임" lives).

### Fast loop
The detector is a **pure function of env state** → no LLM, no full sim:
- In `dev_session.jl` add `detect_test()`: take `deepcopy(BASE_ENV)`, **inject a
  fault** (zero a robot's velocity / pin its position), step a few, assert
  `detect(env)` fires the right event; on an un-perturbed copy assert it does NOT
  fire (false-positive guard). Sub-second via deepcopy + Revise.
- **Detector → translation seam**: feed the detector's emitted string into the
  env-free `tools/translate_eval.py` path (add a one-off case, or pipe the string)
  to confirm it translates to the expected DSL kind/target against the cached
  fixture. Closes detector→LLM without a sim.
- Conformal: calibration runs once (cache the scores); the threshold check is pure
  math → unit-test against the cached score file. Tune α offline, no sim re-runs.

### Done-gate
On a perturbed deepcopy the detector fires the correct event and its string
translates to the expected DSL; on nominal runs the false-positive rate is within
the conformal α; a low-confidence case routes to abstain (fallback), not a guess.

---

## Piece 3 — OOD visualization (⑨)

### Integration point (code-grounded)
Rendering is in `render_tools.jl` (`FactoryVisualizer`, `AnimationWrapper`, MeshCat);
the per-step render call is `visualizer_update_function!(factory_vis, env,
newly_updated)` at demo_utils.jl:104, right after `respec_step!`. Add a respec
overlay updated alongside it.

### What to build
1. **Expose respec state for the viz**: a tiny module-global record `RESPEC_LAST =
   Ref{...}` set by `maybe_respecify!` / `engage_fallback!` (kind, target ids, t,
   :hold/:reassign/:admit). `maybe_respecify!` currently only returns a status symbol;
   the viz needs the structured last-action.
2. **`respec_vis_update!(factory_vis, env)`** drawing/updating markers from that state:
   - faulted robot → red halo/sphere at its position;
   - hold / line-stop (`RESPEC_HOLD[]`) → global tint or a "HOLD" banner;
   - `ForbidWindow` zone → translucent red disc over the staging circle
     (`env.staging_circles[aid]`, the same source the spatial labels use);
   - `Precede(a,b)` → an arrow/line between the two assemblies' positions.
3. Call it from `simulate!` next to `visualizer_update_function!` (guard on
   `factory_vis.vis !== nothing`, like the existing block at demo_utils.jl:102).

### Fast loop
Marker creation is a **pure state→MeshCat-objects** function — isolate it from the
animated sim:
- A scratch script opens a MeshCat visualizer, calls `respec_vis_update!` with a
  **synthetic state** (hand-set faulted robot / hold / zone), and you eyeball or
  assert the object paths exist — no full sim, no LLM. Iterate on marker geometry in
  seconds.
- Only the final "fault → marker shows in a real animated run" is a one-shot
  full-render confirmation (needs `rvo_flag`/animation on).

### Done-gate
In a short animated run with an injected fault: the faulted robot is visibly marked,
the hold state shows, a timing re-spec draws its constraint/zone, and markers clear
when the situation resolves.

---

## Cross-cutting: new/extended fast-loop assets

- `tools/dev_session.jl` (exists) → add `resume_test()` and `detect_test()` helpers
  (Julia hot-loop for Pieces 1 & 2).
- `tools/translate_eval.py` (exists) → reuse to verify detector-emitted strings
  translate (Piece 2 seam).
- `tools/llm_fixture.json` (exists) → unchanged; rebuild only if the env build/stepping
  changes (it does NOT for these pieces).
- New: `tools/run_full_loop.jl` (Piece 1 step 4, the enabled-seam e2e driver) and,
  for Piece 2 conformal, `tools/dump_calibration.jl` + `tools/calibration.json`.

## Order of work
1. Resume cache + `commit_respec!(...; resume=true)` → `resume_test()` green.
2. `run_full_loop.jl` enabled-seam e2e (manual `push_ood!`) → build completes.
3. Rule-based detector → `detect_test()` + translate-seam green; swap the manual
   `push_ood!` in the loop for the detector.
4. Conformal calibration + abstain routing.
5. Visualization overlay on top of the now-working loop.
