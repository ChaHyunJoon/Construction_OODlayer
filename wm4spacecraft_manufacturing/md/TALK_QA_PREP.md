# Q&A Prep — "ConstructionBots, Extended" talk

Anticipated questions from a 4th-year PhD in **automation under uncertainty**, with answers and the
code that backs each answer. Grouped into 8 clusters. Deck = `ConstructionBots_evolution_short (2).pptx`.

Legend for evidence paths (repo root `C:\Users\chahj\PythonCodes\venv`):
- `CB/...` = `ConstructionBots.jl/...`
- `wm/...` = `wm4spacecraft_manufacturing/...`
- `dp/...` = `decpomdp/...`

---

## Cluster A — Problem framing & the pivot

**Q1. Your whole pivot rests on "the expensive thing is the planner, not the world." Quantify that.**
One true-planner evaluation of a candidate repair = **69.5 s** (MILP assignment + full RVO sim); a
5-candidate decision ≈ **348 s**. The surrogate makes the same decision at **0** planner calls.
*Evidence:* `wm/E1_RESULTS.md:93,99`; the per-label wall-clock is timed at
`wm/oracle/gen_oracle_dataset.jl:382` (`label_seconds = time() - t_start`) and stored per row (`:396`).

**Q2. Why is this not just sim-to-real in disguise?**
The claim is deliberately *not* perception sim-to-real. The surrogate never imitates simulator
dynamics; it maps `(state, disruption, candidate repair) → outcome metric`. It's a value-equivalent
*decision* surrogate over a known-but-expensive twin (MuZero's move, not a dynamics model).
*Evidence:* the feature row fed to the model is exactly `(kind, severity, spare, progress, macro one-hot)`
→ predict `closed`, see `wm/e1_analyze.py:79` (`featurize`) and the target `y = df.closed` at
`wm/e1_frontier.py:48`. No state-transition target anywhere.

**Q3. Why these three OOD classes specifically?**
They hit three different parts of the stack — an **agent** (breakdown), the **space** (keep-out zone),
a **resource** (battery) — which forces a repair vocabulary broader than one trick.
*Evidence:* the three injectors: `fault_action` / `battery_action` `CB/src/navigator/ood_stream.jl`;
zone via `place_blocking_zone!` `wm/oracle/gen_oracle_dataset.jl` and the demo
`CB/tools/demo_surrogate_stream_anim.jl:218`.

**Q4. "Real spacecraft assembly plans over a digital twin" — is that assumption defended or asserted?**
Asserted as the premise, and flagged honestly as a proxy. The deliverable is the *method* (DSL + OOD
taxonomy + retraining procedure), re-fittable onto a facility's own twin — not the trained weights.
*Evidence:* `wm/PROPOSAL.md` "Honest scope boundary"; deck slide 13 "Digital twin is a proxy."

---

## Cluster B — Reproducibility & experimental hygiene (the reviewer's favorite attack surface)

**Q5. How do you get paired A/B comparisons if the sim has stochastic motion?**
Disruptions fire at **build-progress thresholds** (number of closed nodes), not wall-clock steps, so
the same seed reaches the same state at injection and A/B differ only in the decision.
*Evidence:* `CB.schedule_ood_at_closed!(c, act)` — fires when `closed_set` crosses `c`; used in
`wm/oracle/gen_oracle_dataset.jl:280-326` and `CB/tools/demo_surrogate_stream_anim.jl:287`.
Definition in `CB/src/navigator/ood_truth.jl`.

**Q6. How do you score a *decision* rather than just an outcome? You need the counterfactual best.**
A ground-truth log records the correct answer at injection time, visible only to the evaluator; and the
oracle dataset stores *every* macro's true outcome, so the oracle-best is known per instance.
*Evidence:* `record_ood_truth! → OOD_TRUTH_LOG` `CB/src/navigator/ood_truth.jl:66-71` ("the EVALUATOR
sees it (LLM never does)"); oracle-best computed by `oracle_best_row` `wm/e1_analyze.py:45`.

**Q7. Prove the controller can't cheat by reading the ground-truth log.**
The controller's view (`event_context`) is built only from the event NL + *public* env registries,
never `OOD_TRUTH_LOG`. This is explicit and identical for LLM and RL.
*Evidence:* `dp/examples/ood_env_mdp.jl:5` header ("never the evaluator-only OOD_TRUTH_LOG"); the
context builder `event_context` reads `RESTRICTION_ZONES`, `BATTERY_FLEET`, sched — not the truth log.

**Q8. Leave-one-out on 32 instances is small. Why should I trust the gain?**
Reported with a **paired bootstrap 95% CI** on per-instance regret differences (paired stats because
the same instance is scored under both policies): gain **+0.281 [+0.13, +0.44]**, excludes zero.
*Evidence:* `wm/e1_analyze.py:290-297` (paired bootstrap); leave-one-*instance*-out grouping at
`wm/e1_frontier.py:50` (`LeaveOneGroupOut`, groups = instance).

**Q9. What's an "admissible" instance and isn't filtering instances p-hacking?**
Admissible = the disruption is *consequential*: NOOP is strictly worse than the healthy control in the
same feasibility-lexicographic order. It removes cases where no decision matters (not cases where a
particular method loses). Crucially, this filter was later found to *cause* the "task-is-easy" artifact
— see Q26.
*Evidence:* `instance_admissible` `wm/e1_analyze.py:54-69` (compares NOOP vs `ctrl_*` columns).

---

## Cluster C — The scoring metric

**Q10. Define your objective precisely. What does "better repair" mean?**
Feasibility-lexicographic: `(complete, closed, −makespan)` compared as a tuple. Completion dominates;
tie-break on closed nodes (progress); final tie-break on makespan (time).
*Evidence:* `lex_key` `wm/e1_analyze.py:39-42`.

**Q11. Why lexicographic instead of a weighted sum of completion/progress/time?**
So a high `closed` can never buy back a failed `complete`. A weighted sum lets progress outvote
completion — unacceptable when "finish the build" is the hard requirement.
*Evidence:* tuple comparison at `wm/e1_analyze.py:42`; makespan is neutralized (`-1e18`) when not
complete, so incomplete builds are compared on `closed` only.

**Q12. What is `closed`, mechanically?**
`length(env.cache.closed_set)` — the count of schedule-DAG nodes whose work has actually finished
(topological completion), i.e. how much of the build got built.
*Evidence:* written to the dataset at `wm/oracle/gen_oracle_dataset.jl:393`; `closed_set` defined
`CB/src/essential_tg_coponents.jl:1566`, populated (`push!`) at `:1653`.

**Q13. Regret — exact formula?**
`regret = (best_closed − picked_closed) / span`, span = best−worst closed on that instance;
normalized to [0,1] per scenario. Zero = chose what the 348 s brute-force sweep would have chosen.
*Evidence:* `wm/e1_frontier.py:86`; catastrophic pick = losing >15% of reachable closed vs oracle,
`wm/e1_analyze.py:255-257`.

---

## Cluster D — The surrogate model

**Q14. Why gradient-boosted trees and not a neural net?**
(a) Low-data regime (~32 labeled instances) where trees are strong; (b) the decision lives at
**thresholds** (replace below ~15% SoC, else do nothing) and a tree split *is* a threshold, so
predicted-outcome lines for different repairs can **cross** — a linear model gives every repair the
same slope, so its lines never cross and it can't flip its answer.
*Evidence:* `build_model()` = `HistGradientBoostingRegressor(max_iter=300, max_depth=4,
learning_rate=0.08, ...)` `wm/e3_drift.py:33-35` (identical in e1/e2/frontier); deck slide 14.

**Q15. Is `learning_rate=0.08` a training LR? (trap question)**
No — it's boosting **shrinkage**, meaningful only inside one `fit()`. Each tree removes ~8% of the
residual it sees. It is not an RL/gradient-descent step size across updates.
*Evidence:* `wm/e1_analyze.py` / `wm/e3_drift.py:34`; deck slide 9 notes.

**Q16. R²=0.83 with ~13-node error, yet zero decision regret. Reconcile.**
That's the value-equivalence point: the model predicts *values* imperfectly but *ranks* the five
macros correctly, and only the ranking drives the decision. Wrong numbers, right choice.
*Evidence:* the pipeline ranks by predicted `closed` then picks (`np.argsort(-pred)`)
`wm/e1_frontier.py:75`; regret computed on the pick, not the predicted value, `:86`.

**Q17. The demo runs a *linear* surrogate but you claim trees. Which is deployed?**
Both, deliberately. Training/eval (E1-E4) use the forest. The MeshCat demo evaluates a Ridge linear
export **natively in Julia** so no Python is needed at decision time (PyCall's env carries rvo2 only).
Their leave-one-out decision regret is identical — again value equivalence.
*Evidence:* `export_surrogate.py` emits `surrogate_linear.json`; demo loads & evaluates it at
`CB/tools/demo_surrogate_stream_anim.jl:92` (`surrogate_predict`); the superseded single-OOD demo even
*errors loudly* if handed a forest export, `CB/tools/demo_surrogate_anim.jl:64-68`.

**Q18. Feature list — and how do you guarantee train/inference parity?**
19 features: kind one-hot(4), severity, spare cfg/count, progress, agent_pending, closed_at_fire,
n_active, soc, zone_radius, macro_in_valid, macro one-hot(5). The Julia demo rebuilds the **exact same
column order** as the Python `featurize`.
*Evidence:* `featurize` `wm/e1_analyze.py:79`; the demo's `features()` returns `[d[f] for f in
FEATNAMES]` in training order, `CB/tools/demo_surrogate_stream_anim.jl` (see comment "exact training
column order").

---

## Cluster E — Producer, LLM, and the RL alternative

**Q19. Is the LLM necessary? Ablate it.**
Not for **quality**, yes for **compute**: the LLM narrows the 5-macro repertoire to a small candidate
set, which is where planner calls are saved. Quality is the surrogate's job.
*Evidence:* E2 candidate sets are the "LLM" proposal `wm/e2_llm_surrogate.py:31-36`; the self-check
warns if candidate sets collapse to singletons (→ E2 degenerates to E1) `:114-115`; deck slide 12 Q&A.

**Q20. How is the LLM prevented from proposing an unsafe/invalid action?**
Schema-locked tool call: the Anthropic call + prompt + tool schema live in Python; Julia only validates
the returned DSL JSON into a typed `RespecProposal`. It structurally cannot emit outside the 5-macro DSL.
*Evidence:* `CB/src/respec/llm_bridge.jl:7-9,42-45,284`; service in `CB/src/respec/llm_service/`
(`propose.py`, `schema.py`, `server.py`).

**Q21. Why not learn the repair policy directly with RL (model-free)?**
Every RL training signal still costs a 70 s planner run, and the deliverable is a cheap model *of the
planner* any proposer can reuse. Learning the decision's *outcome* is a smaller, better-posed target
than a policy or full dynamics (value equivalence). A REINFORCE policy exists as the model-free foil
but is not the contribution.
*Evidence:* the RL foil = 70-param linear softmax, REINFORCE, `dp/examples/ood_reinforce.jl`; trained
by `dp/examples/ood_train.jl` (50 episodes, lr 0.02, γ 0.5). Deck slide 12 Q&A ammunition.

**Q22. Are the LLM, RL, and surrogate actually comparable, or apples-to-oranges?**
All three are interchangeable *producers* on one seam `(env, event) → RespecProposal`, same decision
points, same 5-macro action space, same information (event NL + public registries).
*Evidence:* the seam `set_respec_producer!` / `maybe_respecify!` `CB/src/respec/replan.jl`; the RL and
surrogate both plug into it; `dp/examples/ood_env.jl` header ("RL and LLM do the identical job").

**Q23. In the deck the "Producer" box says LLM but the live demo's producer is the surrogate itself. Which is it?**
In the headline demo the surrogate is both proposer-and-ranker (scores all 5, enacts argmax) — that's
the k=0 ceiling with no LLM. The LLM is a separate producer for the compute-saving story (E2).
*Evidence:* `surrogate_producer` scores all `MACROS` and enacts argmax,
`CB/tools/demo_surrogate_stream_anim.jl:199-212`; registered at `:319`.

---

## Cluster F — The self-evolving loop (drift)

**Q24. What exactly "self-evolves," and how is drift detected?**
The surrogate. The residual on the one candidate it *did* verify is a free error signal; a CUSUM
(Page-Hinkley-style) monitor accumulates it; on a threshold crossing it escalates verification
(relabel via true planner), refits the forest, resets the monitor, with a cooldown to prevent thrash.
*Evidence:* residual `wm/e3_drift.py:90`; CUSUM `:129-130` (`C_THRESH=60, SLACK=8`); escalate/relabel
`:123-128`; refit `:136-137`; cooldown `:121,138`.

**Q25. "Retrain" a boosted forest — you can't fine-tune it, so what happens?**
Refit from scratch, not fine-tune: a tree ensemble has no continuous dial (splits are discrete, and
every tree was fit to the prior trees' residual on the *old* data). Refitting a few hundred labels is
milliseconds; the cost is the 70 s/label planner calls — so the loop pays the planner only when the
world actually moved.
*Evidence:* `fit(m, buf)` rebuilds the model on the buffer `wm/e3_drift.py:76-79,137`; deck slide 14.
Caveat: this loop lives in Python E3 only; the Julia demo's exported model is **not yet** re-exported
back into the loop (an integration gap, not a claim).

---

## Cluster G — Results, baselines, honesty

**Q26. Your first result was "too good" (zero residual entropy). What was wrong?**
Three fixes, stated on the deck as future/limits: (1) battery events were hitting an *idle spare* —
"battery is harmless" was a **bug**; (2) the NOOP arm was being silently repaired by a background
policy — the studied decision now owns its consequences; (3) the admissibility filter had deleted
every case where restraint (NOOP) was correct. Cost-aware labels restore a real threshold: SoC 0.05 →
Replace, 0.20 → NOOP; small zone → NOOP, large → ForbidZone.
*Evidence:* cost-aware target `y = closed − λ·adaptation_cost(macro)` `wm/export_surrogate.py:126`,
rationale `:29`; the severity ladder is encoded in the demo stream
`CB/tools/demo_surrogate_stream_anim.jl:273-281`; memory `constructionbots-graded-ood-breakthrough`.

**Q27. What are your baselines and which one is the honest floor?**
State-blind "always-X" and "random-order verify"; the always-Replace policy makes catastrophic picks
on zone events (Replace leaves the build incomplete) 9/32. The oracle (verify-all) is the ceiling.
*Evidence:* baselines `model`/`always`/`random` `wm/e1_analyze.py:215` and the gain check
`gain = always − model → LEARNABLE if >0.02`; frontier's `random` baseline `wm/e1_frontier.py:76`.

**Q28. The efficiency claim (67% fewer calls) and drift recovery (1.00→0.11) — where computed?**
E2 headline: surrogate top-k matches verify-all quality at 67% fewer planner calls. E3 headline:
frozen surrogate regret 1.00 post-drift, active loop recovers to 0.11 at 54% fewer calls than oracle.
*Evidence:* E2 `wm/e2_llm_surrogate.py:106-113`; E3 `wm/e3_drift.py:158-165` (area between frozen/active
curves, time-to-recover, planner-call ratio).

**Q29. The ablation grid doubles as your related-work table. Justify that.**
Each cell {surrogate × LLM × retrain} is one prior-art regime (e.g. LLM→exact-solver = 2506.18178;
frozen surrogate = static regressor). Only the full cell is on the quality-compute Pareto front.
*Evidence:* `wm/e4_ablation.py`; the four E's map to the four novelty-gap rows in `wm/PROPOSAL.md`.

---

## Cluster H — Limitations you should raise before they do

**Q30. The mid-build replacement that never completes — decision bug or dynamics bug?**
Dynamics bug, not a decision bug. By the metric the decision is correct (Replace closes 172 vs 151 for
NOOP), but one formed carrier never reaches its deposit because waiting teams become obstacles in its
path. The fix is behind a flag because enabling it changes the twin and would invalidate every oracle
label.
*Evidence:* memory `constructionbots-replace-completion-limit` and `constructionbots-phantom-spare-doublebook`;
the flagged path is the whole-build translate / restage fallback in `CB/tools/restage_*.jl`.

**Q31 (bonus). Next model step?**
A GNN over the scene tree + schedule DAG replaces the feature model *once there's more data and the
task is graded*; on the current easy task it also scores regret 0, so it's deferred, not a blocker.
*Evidence:* `wm/DESIGN_NEXT.md` §1 (drop-in for `build_model()`, dump-seam is the only new Julia work).

---

### Quick-reference evidence map

| Claim | File:line |
|---|---|
| 69.5 s/label, 348 s/decision | `wm/E1_RESULTS.md:93`; `wm/oracle/gen_oracle_dataset.jl:382` |
| build-progress-threshold injection (reproducibility) | `CB/src/navigator/ood_truth.jl` `schedule_ood_at_closed!` |
| ground-truth log hidden from controller | `CB/src/navigator/ood_truth.jl:66`; `dp/examples/ood_env_mdp.jl:5` |
| lex_key scoring | `wm/e1_analyze.py:39-42` |
| `closed` = closed_set size | `wm/oracle/gen_oracle_dataset.jl:393`; `CB/src/essential_tg_coponents.jl:1566,1653` |
| regret formula | `wm/e1_frontier.py:86` |
| surrogate model hyperparams | `wm/e3_drift.py:33-35` |
| paired bootstrap CI | `wm/e1_analyze.py:290-297` |
| admissibility | `wm/e1_analyze.py:54-69` |
| CUSUM drift → relabel → refit | `wm/e3_drift.py:90,129,123-128,136-137` |
| producer seam | `CB/src/respec/replan.jl` `set_respec_producer!`/`maybe_respecify!` |
| LLM schema-lock | `CB/src/respec/llm_bridge.jl`; `CB/src/respec/llm_service/` |
| verifier 3 gates (grammar/static/feasible) | `CB/src/respec/verifier.jl:1-17,65` |
| cost-aware restraint labels | `wm/export_surrogate.py:126` |
| RL foil (REINFORCE) | `dp/examples/ood_reinforce.jl`, `dp/examples/ood_train.jl` |
