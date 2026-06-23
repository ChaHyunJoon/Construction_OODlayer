# OOD → spec-translation evaluation: design & progress

Started 2026-06-19. Working/design doc for the **per-OOD-class reliability metric**
of the verified LLM re-specification layer. Long-running; this file is the source
of truth for the eval design and a dated progress log. Companion to `PATCHES.md`.

---

## 0. Why this exists

The respec layer turns a natural-language OOD event into a closed DSL spec, which
a verifier admits and the MILP re-solves. We have **live evidence** that it works
for two DSL kinds (ForbidAgent — robot fault; Deadline — ROUND 2). One passing run
is an *existence proof, not a metric*. This doc designs the metric that answers the
README's question: **"which OOD classes does the LLM translate reliably?"**

## 1. The structure (agreed 2026-06-19)

Per OOD case we predefine `(NL event(s), expected behavior)`; the LLM pipeline runs
and we score how close its result is to the predefined gold. Behavioral evaluation,
with these four refinements that make it valid:

### R1 — Gold = intended EFFECT predicates, NOT a specific schedule
Many distinct schedules are equally correct. So the gold is a set of **checkable
predicates** (the conditions a correct action must satisfy), e.g. for a robot fault:
`faulted robot on 0 pending transport teams` ∧ `every transport task still fully
staffed` ∧ `completed work stays frozen` ∧ `schedule valid`. (These are exactly the
asserts in `test_respec_reassign.jl`.)

### R2 — Gold comes from an LLM-FREE oracle (no circularity)
The reference must not involve the LLM, or we'd grade the model against itself. We
already have LLM-free verified reference paths:
- robot fault → `fault_robot_and_reassign!(env, RobotID)` called directly with the
  known agent id (the LLM-free core; test_respec_reassign.jl uses it).
- generic re-spec → a hand-written `RespecProposal` through `verify`/compile.

So: **gold = LLM-free path output; candidate = LLM-driven path output; compare.**

### R3 — Measure translation and behavior SEPARATELY (to localize failure)
- **(a) Translation correctness**: did the LLM emit the expected DSL *kind* and the
  expected *target* id? (spec-level; catches "wrong primitive" / bad grounding.)
- **(b) Behavioral correctness**: does executing the emitted spec satisfy the gold
  predicates? (effect-level.)
The "hollow admit" episode = (a) plausible, (b) fail. Measuring both attributes blame.

### R4 — Two axes: correctness (binary) vs quality (continuous); don't mix
- **Correctness** = predicate satisfaction → binary pass/fail per case. The core metric.
- **Quality** = e.g. makespan ratio vs the gold reference → continuous. Separate axis.
  (Note our optimizer runs `mip_rel_gap=5.0` = feasibility-first, so actions are
  feasible-not-optimal; quality numbers must be read in that light.)

### Stochasticity
The LLM is sampling-based, so score **case × N samples × paraphrases** and report a
**per-class pass rate** plus consistency (same event → same kind?) and paraphrase
robustness.

## 2. Case spec format (Julia)

```
OODEvalCase(
  id            :: String                    # "robot_fault_basic"
  klass         :: Symbol                    # :ForbidAgent | :Deadline | :ForbidWindow | :Precede
  events        :: Vector{String}            # NL paraphrases of the SAME underlying event
  pick_target   :: env -> AbstractID         # the ground-truth id the spec should reference
  expected_kind :: Symbol                    # DSL kind the LLM should produce
  gold_runner   :: (env, target) -> outcome  # LLM-FREE reference action (mutates a COPY)
  predicates    :: Vector{name => (env_after, target) -> Bool}  # behavioral gold
)
```
Each trial runs on a **`deepcopy` of a once-built base env** (rebuilding per trial is
minutes; deepcopy is cheap). Risk to verify: deepcopy of `PlannerEnv` (scene_tree,
MetaGraph sched, cache) — should be fine with `rvo_flag=false` (no PyCall RVO handle).

## 3. The 4 OOD classes (frequency + grounding difficulty)

| OOD case | DSL kind | freq | grounding | LLM-tested? |
|---|---|---|---|---|
| Robot fault / unavailable | `ForbidAgent` | ★★★ | solved (agent labels) | ✅ Phase 2 |
| Rush / expedite order | `Deadline` | ★★★ | low (named node) | partial (softball) |
| Zone closure (human/safety) | `ForbidWindow` | ★★★ | **high (needs node→location labels)** | ❌ |
| Defect → rework precedence | `Precede` | ★★☆ | medium (two nodes) | ❌ |

Grounding insight: ForbidAgent needed agent labels (done). Deadline/Precede need
node *semantic* labels; ForbidWindow additionally needs *spatial/zone* labels — the
same "inject context the model can ground onto" pattern, escalating in difficulty.

## 4. Plan

- **P0 — harness skeleton + robot-fault case** ✅ DONE 2026-06-19. File:
  `eval_respec_ood.jl`. First live result: **robot_fault_basic = 6/6 on all three
  axes** (translation kind, translation target, behavior) over 3 paraphrases × 2
  samples; gold predicates all pass. Paraphrase robustness CONFIRMED: "we just lost
  robot 3...", "R3 has broken down..." both ground to ForbidAgent(RobotID(3)) and
  reassign correctly — not just the literal ROUND-1 phrasing.
- **P1 — Deadline case (NL rush order)** — node labels chosen = STRUCTURAL (Path B;
  user picked "구조 라벨부터" since env carries no LDraw model). `open_node_descriptors(env)`
  in llm_bridge.jl labels AssemblyComplete milestones ("the final assembly (root; N
  components)", "sub-assembly K (M components)"); sent as `nodes` in the POST body;
  server.py/propose.py render a NAMED NODES prompt section. Resolver UNCHANGED (exact
  node-id match already covers these — safety preserved). Labels self-verified on the
  real tractor env (8 AssemblyComplete, root=AssemblyID(1) correctly flagged). Deadline
  eval case added (3 paraphrases, target=root assembly, generous T=100). LIMITATION:
  a non-binding deadline makes BEHAVIOR predicates non-discriminative for grounding →
  for Deadline the grounding signal is the translation-TARGET score (behavior only
  confirms feasible execution). Status: code done + pre-verified; awaiting live run.
- **P2 — Precede case** (rework precedence). Reuses node labels.
- **P3 — ForbidWindow case** (zone closure). Needs node→location/zone labels (new
  spatial grounding context).
- **P4 — aggregate reporting**: per-class pass rate, consistency, paraphrase robustness.

## 5. Progress log

- **2026-06-19** — Design agreed (R1–R4). Created this doc. Starting P0: harness
  skeleton + robot-fault eval case (`eval_respec_ood.jl`).
- **2026-06-19** — P0 harness WRITTEN (`eval_respec_ood.jl`): `OODEvalCase` format,
  `build_eval_env` (deepcopy-per-trial), `llm_candidate!` (translate + production
  dispatch), `score_translation`/`score_behavior`, gold-sanity check, and the
  robot-fault case (3 paraphrases, 4 gold predicates from test_respec_reassign).
  Definitions load+precompile clean under `julia +lts` (main guarded by
  PROGRAM_FILE so include() doesn't run it). NOT yet run live (needs the service) —
  next: user runs `julia +lts --project=. eval_respec_ood.jl` to get the first
  per-class pass rates. Open risks to watch on first run: (1) `deepcopy(PlannerEnv)`
  fidelity, (2) does paraphrase #2/#3 still translate (only #1 proven live).
- **2026-06-19** — P0 RAN LIVE. **robot_fault_basic = 6/6/6** (kind/target/behavior),
  gold all-pass. Both open risks cleared: deepcopy(PlannerEnv) works (gold + 6 trials
  on independent copies, no cross-contamination), and paraphrases #2/#3 translate
  correctly. One bug: summary used `count(pred)` without the collection → fixed to
  `count(pred, rows)` (the 6 trial lines printed fine; only the final summary string
  crashed). Re-run optional — result already conclusive. NEXT: P1 Deadline case,
  which first needs node SEMANTIC labels in the prompt (mirror the agent-label work).
- **2026-06-19** — P1 CODE DONE (structural node labels, Path B). Added
  `open_node_descriptors` (llm_bridge.jl) + `nodes` POST field + NAMED NODES prompt
  section (server.py/propose.py) + Deadline eval case (eval_respec_ood.jl), and
  refactored a shared `commit_proposal!`. Pre-verified WITHOUT the LLM: labels render
  correctly on the real env (root assembly flagged, sub-assemblies discriminative by
  id+component-count); Python prompt renders the NAMED NODES section; harness loads
  both cases. ⚠️ server.py/propose.py changed → user MUST RESTART the uvicorn service
  before the run (unlike P2-Julia-only changes). Run: `julia +lts --project=.
  eval_respec_ood.jl`. Awaiting live per-class pass rates for Deadline.
- **2026-06-19** — P1 RAN LIVE. **deadline_final_assembly = 6/6/6**; robot_fault_basic
  still 6/6/6. Translation-target 6/6 = all 3 assembly paraphrases ("the final
  assembly", "the whole build (root assembly)", "the final assembly is due") grounded
  to the exact root AssemblyComplete id → structural labels + NAMED NODES prompt work;
  flexible-but-safe binding confirmed for nodes. 2 of 4 DSL kinds now at 100%
  (ForbidAgent, Deadline). NEXT: P2 Precede — generalize scoring to TWO targets:
  pick_target returns (a,b), `_spec_targets(Precede)=(c.a,c.b)`, predicate tF[a]<=t0[b].
- **2026-06-19** — P2 CODE DONE (Precede). Generalized scoring to tuple targets
  (`_spec_targets`/`_astuple`); added `precede_case` (defect→rework: "sub-assembly 2
  failed QC, finish rework before sub-assembly 4 starts", 3 paraphrases, target=(asm2,
  asm4), predicate tF[asm2]<=t0[asm4]). Pre-verified WITHOUT LLM via a pair-scan on a
  real mid-build env: all 8 AssemblyComplete stay open; pair (2→4) gold ADMITS and the
  predicate holds (chosen); (2→3) also feasible; (3→5),(4→6),(2→8),(5→7) infeasible
  (structural). get_t0/get_tF API confirmed. NO Python/prompt change (Precede reuses
  P1's NAMED NODES labels) → user need NOT restart the service, just re-run
  `eval_respec_ood.jl` (now 3 cases). Awaiting live Precede pass rate.
- **2026-06-19** — P2 RAN LIVE. **precede_rework = 6/6/6**; all 3 cases now 6/6/6.
  Order-robustness CONFIRMED: paraphrase "Hold sub-assembly 4 until sub-assembly 2 is
  complete" (surface order 4-then-2) still produced Precede(2,4) — model didn't map
  surface order to a/b, and since Precede is binding the behavior predicate (tF[2]<=
  t0[4]) would have failed if reversed. 3 of 4 DSL kinds at 100% (ForbidAgent, Deadline,
  Precede). REMAINING: P3 ForbidWindow. Two sub-options: P3a per-node blackout window
  ("sub-assembly 2 can't be worked on during t=20..50", reuses P1 node labels, fast,
  completes 4/4 DSL coverage) vs P3b true zone closure (tests NEW spatial grounding;
  env.staging_circles has node positions to derive zone labels). Decision pending.
- **2026-06-19** — P3 = P3b ZONE CLOSURE chosen (user picked spatial grounding). CODE
  DONE. Layout probe: staging_circles keyed by AssemblyID, `LazySets.center` gives
  (x,y). Assemblies cluster at x≈0 (some duplicate centers) + root(asm1) outlier at
  (1.5,0.96); clean split by y: south(y<-0.2)={asm3,5,6}, north(y>0.2)={1,2,7,8},
  central={4}. `open_node_descriptors` now appends "; located in the {north/central/
  south} staging area" (Julia-only → NO service restart; Python just forwards labels).
  Added SET-valued scoring (target isa Set → kind=all-ForbidWindow, target=forbidden-set
  == gold zone set) and `zone_closure_case` (south zone, window [20,50], 3 paraphrases).
  Pre-verified WITHOUT LLM: labels carry direction; gold (3 ForbidWindow on south)
  ADMITS + predicates pass; set-scoring discriminative (exact set→target✓, missing-one
  →target✗). NOTE: ForbidWindow on instantaneous AssemblyComplete milestones → window
  often non-binding → BEHAVIOR non-discriminative; grounding signal = translation-TARGET
  set-match. Run: `julia +lts --project=. eval_respec_ood.jl` (4 cases now, no restart).
- **2026-06-19** — P3 RAN LIVE (twice, reproducible). zone_closure_south = **6/6/6** →
  SPATIAL grounding WORKS ("the southern area" → exactly {asm3,5,6}, target 6/6).
  robot_fault & deadline still 6/6/6. BUT precede_rework: **GOLD FAILED** ("A finishes
  before B" ✗), target 3/6, behavior 0/6. **CRITICAL FINDING** (diagnosed at source):
  the respec COMMIT does NOT persist timing-only constraints. `update_project_schedule!`
  and `reset_cache!` both call `process_schedule!`, which recomputes t0/tF structurally
  (critical-path) and DISCARDS the MILP's solved t0/tF. Diag Precede(asm2,asm4): BEFORE
  tF[2]=8.88,t0[4]=6.28 (natural violation); MILP soln t0[4]=8.88 (honored, Admit);
  AFTER update_project_schedule! t0[4]=6.28 (REVERTED). ⟹ ForbidAgent persists (changes
  STRUCTURE→reassignment) but Precede/Deadline/ForbidWindow are translated+admitted yet
  their TIMING effect is dropped at commit. deadline/zone "passed" behavior only because
  non-binding. Note P2's earlier precede 6/6 behavior was a FALSE POSITIVE — that env
  build happened to have asm2 naturally before asm4, so the (unenforced) constraint
  coincided; this env build doesn't. Real respec-LAYER limitation, surfaced by behavioral
  eval (like hollow-admit, at commit-timing level). Secondary: precede target 6/6→3/6 —
  likely spatial labels on ALL nodes added noise / a-b flips. DECISIONS PENDING: (1) fix
  layer so timing re-specs persist (Precede→add real precedence EDGE so process_schedule!
  honors it; Deadline/ForbidWindow harder) vs document gap + scope eval behavior to the
  MILP solution; (2) re-check precede target.
- **2026-06-19** — DECISION: document the gap and stop here. Written up in
  `src/respec/timing_respec_persistence_gap_2026-06-19.md` (standalone). Eval effort
  paused at: 4/4 DSL kinds translation-verified (ForbidAgent/Deadline/ForbidWindow
  target 6/6, Precede 3/6); behavioral persistence confirmed only for ForbidAgent;
  timing re-specs (Precede/Deadline/ForbidWindow) translated+admitted but not enacted
  at commit. P4 (aggregate reporting) and any layer fix left as future work.
