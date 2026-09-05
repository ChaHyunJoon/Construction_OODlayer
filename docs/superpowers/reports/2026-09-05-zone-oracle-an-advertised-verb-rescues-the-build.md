# task-zone-oracle — Can any ADVERTISED verb rescue a zone-blocked build?

**Date:** 2026-09-05 · **Branch:** `oracle-rebuild-night-2026-08-10`

## Answer

# ✅ YES. `translate_whole_build!` turns the zone build from INCOMPLETE to **COMPLETE**.

This is the opposite of the `mild battery` result. There, no composition of the advertised
vocabulary could relieve the robot and we killed the line. Here **one advertised verb, reached by a
two-tier escalation inside a single hand-written body, fully rescues the build** — and it does so
while cutting fleet energy by 2.68×. **Zone is NOT blocked the way mild was.** The paid multi-agent
run is worth doing.

🔴 **But the metric this task family scores on reads the rescue as nothing.** `world_delta_body` is
**0 on all five axes** for the run that completed the project. See §4 — that is the most important
secondary finding here and it is a measurement defect, not a model result.

---

## 1. The two runs

Both runs used the **same service, same port, same lane**. The only difference is the fixture.

```
# RUN 1 — control (no fixture)
DEMO_MODEL=tractor.mpd DEMO_OOD=none DEMO_ZONE=1 DEMO_CASE_TAG=zone_mild DEMO_POLICY=dspy DEMO_ANIM=0 \
DSPY_URL=http://127.0.0.1:8078 \
  julia +lts --project=. tools/monitor/render_demo.jl

# RUN 2 — oracle
... identical ... DEMO_SYNTH_FIXTURE=tools/fixtures/oracle_zone_clear.json
```

🔴 **`DSPY_URL=8078` for BOTH runs** (`synth_tool_synthesis=false`, `synth_multi_agent=false`), and
that is deliberate. `synth_fixture_lane` (`tools/monitor/policy.jl`) **overwrites every
`SYNTH_LANE_KEYS` entry**, so a live synthesis lane would have been discarded byte-for-byte;
paying for a 3-agent synthesis to throw it away adds billed calls and minutes that this measurement
cannot observe. Holding the port fixed makes the fixture the **only** difference between the runs.
Both services passed the generation gate at run time
(`src/respec/llm_service/generation.py --url …` → `OK ok … fingerprint=188e07cfdd026a95`).

⚠️ **Neither run is free.** The router escalates zone to the LLM lane in both, so each billed one
gpt-4o `/macro` call.

The oracle run is **loudly** stamped: the banner printed
`🔴🔴🔴 [synth-fixture] ORACLE BYPASS ACTIVE … impl_name="OracleZoneClear!" surface="sched"`, and the
decision row carries `router.synth_fixture = {path: tools/fixtures/oracle_zone_clear.json,
sha256_16: 45595d76a969ba84, impl_name: OracleZoneClear!}`. Nothing was relaxed — the fixture went
through `register_minted_primitive!` → `check_impl_conventions` → `enact_minted!` on the same code
path as a model's output (`registered=true`, `impl_rejected_why=n/a`).

**The event is identical in both runs** (same seed, same world):
```
[zone] blocking zone on transport vtx=153 @[1.094, 0.416] r=0.07 -> nav_blocked=3/131
[zone] diag n_blocked=3 n_nav_blocked=3 root_covered=0/8 n_work_overlap=6
       n_teams_covered=0 n_nav_goals=131 n_nav_engulfed=3 n_agent_trapped=0
```

---

## 2. Results

| axis | RUN 1 control | RUN 2 oracle (`OracleZoneClear!`) |
|---|---|---|
| **project** | 🔴 **PROJECT INCOMPLETE!** | ✅ **PROJECT COMPLETE!** |
| `t` (final frame) | 5776 | **1022** |
| `n_closed` | 270 / 305 | **287 / 305** |
| `n_active` | 18 | 18 |
| `min_soc` | 0.9939292467277718 | 0.9987168142014836 |
| `mean_soc` | 0.9983721477563408 | 0.9993934112319197 |
| `total_energy_J` | 242615.09841481474 | **90405.98999815281** (0.373× — a 2.68× saving) |
| `soc_spread` | 0.006070753272228169 | 0.0012831857985163841 |
| routing | `[router] 'unknown:zone' is outside the surrogate's training kinds → escalate to LLM (kind=unknown:zone, axis=ood_kind)` | identical |
| escalated to LLM lane? | **yes** — `enacted=dspy`, `ROUTED→dspy (ood_kind) · ADMITTED · dspy:gpt-4o` | identical |
| LLM macro chosen | `NOOP nothing` (rationale: *"NOOP is clearly better … the exclusion zone minimally impacts the build"*) | same (`NOOP nothing`, `at=54`) |
| stream frames | 116 | 21 |

🔴 **287/305 is the COMPLETE signature**, exactly as the recon predicted. `n_closed == n_total`
never happens; the verdict is `CB.project_complete`, printed by `run_lego_demo`'s
`PROJECT COMPLETE!`/`PROJECT INCOMPLETE!` branch in `src/demo_utils.jl`. Reading 287 as "still
17 short" would be the trap.

`min_soc` / `soc_spread` are **not** the story here (the zone case never drains anyone — SoC stays
above 0.99 in both). The energy figure is: the control burns 2.68× the joules because 18 robots
idle-discharge for 4754 extra steps against a wedge they never clear.

### Enactment record (RUN 2)

```
[minted] lane=present tool=OracleZoneClear verdict=admit applied=nothing partial=false
         world_maybe_dirty=true handled=true undo=none resume=issued resolve=resolved
         args_from=calls n_calls=1 dropped_args=none n_body_names=1 registered=true
         impl_rejected_why=n/a steps=[OracleZoneClear!:translated]
         [resume=issued: …] [resolve=resolved: n_reassigned=0]
[minted] ran_milp=true n_candidate_edges=0 cargo_ban_rows=0 closed=54
[minted] world_delta=closed=0 active=0 n_edges=0 n_binding_changed=0 n_weights_changed=0
         delta_scope=body+harness_resolve
         world_delta_body=closed=0 active=0 n_edges=0 n_binding_changed=0 n_weights_changed=0
         body_scope=body_only(probed)
```

- **step status:** `translated` (one step, one primitive)
- **`interface_calls` (L3):** `['active_restriction_zones', 'restage_all_blocked!', 'translate_whole_build!']` — three advertised verbs, zero withheld ones
- **`n_candidate_edges`:** **0** · `cargo_ban_rows`: 0 · `n_reassigned`: 0
- **`world_delta_body`:** `closed=0 active=0 n_edges=0 n_binding_changed=0 n_weights_changed=0` — **L4 = 0 on all five axes**
- **INCOMPLETE → COMPLETE:** **YES**

---

## 3. The tool, and which tier actually did the work

`tools/fixtures/oracle_zone_clear.json`, body (`surface="sched"`, `reversible=false`):

```julia
function OracleZoneClear!(env)
    zk = [k for (k, _) in active_restriction_zones()]
    isempty(zk) && return (; status = :no_zone)
    st = restage_all_blocked!(env; zone_keys = zk, resume = true, verbose = true)
    st.status === :restaged_all && return (; status = :restaged_all, stage = :restage, …)
    tw = translate_whole_build!(env; zone_keys = zk, resume = true, verbose = true)
    return (; status = tw.status, stage = :translate, restage_status = st.status, …)
end
```

This is the two-tier recovery the zone code documents for itself: Phase (a) per-assembly restage,
Phase B rigid whole-build translation. Only advertised verbs; the three withheld unwedging verbs
(`recover_stalled_teams!`, `resolve_schedule_wedge!`, `force_advance_stuck_carrier!`) and the
withheld `_apply_uniform_translation!` were **not** used.

🔴 **The first tier did not do it.** The returned status is `translated`, and by the body's own
control flow that value can only come from the second tier — so `restage_all_blocked!` returned
something other than `:restaged_all`. ⚠️ **I cannot report its exact status.** Its evidence is an
`@info "[RESTAGE-ALL] …"` line, and `run_lego_demo` installs `global_logger(…, Logging.Warn)`, so
that line was discarded process-wide. The plausible reason is structural rather than accidental:
the decision fires at `closed=54`, by which point several assemblies have opened build steps, and
`restage_assembly!` refuses those (`:already_started`, `:already_built`). **"Restaging is only
transform-safe before any build step opens"** is stated in `render_demo.jl`'s zone-arming block —
and `translate_whole_build!` is the verb that is *not* subject to that restriction, because it moves
every `start_config` by one rigid Δ. That is the whole reason the escalation exists, and it is why
a single-tier body would probably have failed.

**Surface choice.** I picked `sched` (in `RESOLVE_SURFACES`) on the argument that a whole-build
translation changes every transport edge's *weight*, which is the scope that constant's docstring
claims. The re-solve did run (`ran_milp=true`) and it changed **nothing** (`n_candidate_edges=0`,
`n_reassigned=0`) — the same no-op T13 has shown everywhere without a preceding release. So the
choice was, in the event, cost without benefit; `scene_tree`/`physical` would have been just as
correct and cheaper. 🔴 **But it buys the strongest form of the result**: nobody can attribute this
rescue to the harness MILP, because the harness MILP demonstrably did zero work. **The geometry edit
alone completed the build.**

---

## 4. 🔴 The metric is blind to this rescue

`world_delta_body` is **0 on every one of its five axes** for the run that completed the project.

That is not a bug in the body and it is not a small result. The five axes
(`closed`·`active`·`n_edges`·`n_binding_changed`·`n_weights_changed`) all live on the **assignment
graph**. `translate_whole_build!` edits neither: it moves `start_config` transforms and
`staging_circles`. A perfect spatial repair is therefore **structurally invisible** to the L4 probe.

Consequences, stated plainly:

1. **For the zone family, `L4 = 0` does NOT mean "the body did nothing."** Anyone scoring the
   upcoming paid multi-agent zone run on `world_delta_body` will record a total success as a total
   failure. The mild-battery family did not expose this because every verb there (`release_pending_assignments!`,
   `forbid_heavy_cargo!`) acts on exactly those axes.
2. **`applied=nothing`, too.** The enactment line says
   *"적응이 일어났는지 **못 쟀다**: 생성 원시의 status 어휘가 선언돼 있지 않다(status: translated)"* —
   a generated primitive has no declared status vocabulary, so `_step_applied` returns "unmeasured"
   for `:translated`. The build completed anyway. Both of the two machine-readable "did it work"
   signals on this decision are silent, and only `CB.project_complete` says what happened.
3. If the zone lane is going to be scored, it needs a geometric delta axis (staging-circle centers,
   `start_config` transforms, or `_count_future_goals_in_zone`) alongside the five graph axes. That
   is not built and I did not build it — flagging it, not fixing it.

---

## 5. Verdict

> **Can any advertised verb actually rescue a zone-blocked build? — YES.**
> `translate_whole_build!`, reached after `restage_all_blocked!` declines, takes this build from
> `INCOMPLETE @ 270/305, t=5776, 242615 J` to `COMPLETE @ 287/305, t=1022, 90406 J`, using nothing
> but the advertised vocabulary. **Zone is not blocked the way mild was**, and the paid multi-agent
> run is justified: the target the model has to find provably exists inside the vocabulary it is shown.

Two caveats that belong to the verdict, not to a footnote:

- 🔴 **The oracle proves the *capability* exists, not that the model can find it.** The gap the model
  must close here is a **two-tier escalation**: the obvious first verb (`restage_all_blocked!`) is
  the one that does not work, and the model must fall through to `translate_whole_build!` when it
  returns something other than `:restaged_all`. A single-verb body picking the obvious verb probably
  fails. That is a genuinely harder composition than mild ever required.
- 🔴 **The live LLM lane, in both runs, chose `NOOP`**, reasoning that *"the exclusion zone minimally
  impacts the build and does not justify resource expenditure"* — against a zone that in fact costs
  the project its completion and 152 kJ. The descriptor that should have carried that
  (`zone_overlap`/severity ≈ 0.002 for `r=0.07`) reads as negligible. **Severity is measured as
  geometric overlap and this event's harm is not geometric — it is terminal.** That is the same
  "ratios cannot carry terminality" failure `CLAUDE.md` records for `work_at_risk`, now reproduced on
  the zone axis. Expect it to be the blocker in the paid run.

## 6. Artifacts

- fixture: `tools/fixtures/oracle_zone_clear.json` (sha256[1:16] `45595d76a969ba84`) — **committed**
- control stream: `results/2026-09-05-zone-oracle/zone_mild_control.jsonl` (116 frames) · log `run1-control.log`
- oracle stream: `results/2026-09-05-zone-oracle/zone_mild_oracle.jsonl` (21 frames) · log `run2-oracle.log`
  (`results/` is gitignored; the streams are on disk only)
