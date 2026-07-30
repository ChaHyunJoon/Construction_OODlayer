# Respec layer status vs. the research proposal / Y1 plan (2026-06-22)

A dual-check of the *implemented* verified-LLM-respec layer against the written
research docs (`year1_plan.md`, `research_proposal_1pager.md`, both in the venv
root). Companion to `PATCHES.md` (wiring), `ood_eval_design_*.md` (eval), and
`timing_respec_persistence_gap_*.md` (the now-closed commit gap).

## Headline: the implementation is AHEAD of the written Y1 plan

`year1_plan.md` scopes Y1 modestly: Q4's deliverable is a **verification-layer PoC
on FIXED plans (no LLM yet)** plus an **orchestrator interface design** (LLM
deferred to Y2). The proposal's timeline puts "오케스트레이터 *작동*" in **Y2**.

What actually exists already does Y2-level work: a live LLM orchestrator
(NL→DSL translation 4/4 kinds at 24/24 as of 2026-06-22) + verifier gate +
commit/persist + robot-fault reassignment. So **Y1 Q4's gate ("위반 계획을 넣으면
검증층이 잡아낸다") is met and exceeded** — done WITH the LLM, not just fixed plans.

⟹ "what's left to build the originally-envisioned system" must be read against the
**proposal (the 5-year thesis)**, not the Y1 doc.

## Proposal's 3 pillars → implemented status

| Pillar | Claim | Status |
|---|---|---|
| ① Orchestrate | LLM does allocation/sequencing, calls solver as a tool | 🟡 LLM proposes **constraint deltas (re-spec) only**; the MILP still does allocation. The safe subset. |
| ② **Verify (★ the heart, C2)** | formal spec blocks **precedence · collision · resource · deadlock** violations *before* execution | 🟡 **precedence (Precede) + timing verified; collision / capacity / deadlock-freedom are NOT formal predicates.** ← biggest thesis-level gap |
| ③ Scale & Recover (C3) | thousands of parts + runtime-fault replanning + **abstain/defer when uncertain** | 🔴 tractor (289) only, no Saturn-V scale; recover = robot-fault reassign only; **abstain = stub** |

## Full pipeline status (code-grounded)

| Stage | Status | Evidence |
|---|---|---|
| ① OOD detection / abstain | 🔴 **stub** | `OODQueue` = "Year-1 **stub** … replaced by the **conformal-prediction 'abstain' trigger**", replan.jl:14-18; events are manual `push_ood!` |
| ② NL→DSL translation | 🟢 done | 4 kinds 24/24 (2026-06-22); Precede a/b-ordering fix |
| ③ verify / admit gate | 🟢 done | GATE+FREEZE, test_respec_gate.jl |
| ④ compile → MILP | 🟢 / cleanup | timing kinds OK; ForbidAgent has `bound_to_agent` (compiler.jl:133) yet prod dispatches to reassign (replan.jl:107) → path duplication |
| ⑤ commit / persist | 🟢 done | `commit_respec!` (replan.jl:232); the former #1 gap, closed 2026-06-22 |
| ⑥ **resume (mid-sim)** | 🔴 **not implemented** | `reset_cache!` empties `closed_set` then re-seeds from ROOT (essential_tg_coponents.jl:1327-1337); *"ERASES execution progress … Fine here (we don't resume)"* reassign.jl:256-259 |
| ⑦ **enabled full-loop e2e** | 🔴 **never run** | seam wired at demo_utils.jl:99, but no script sets `RESPEC_ENABLED[]=true` + `push_ood!` inside `simulate!`; tests bypass via direct dispatch |
| ⑧ fallback | 🟡 placeholder | "hold all agents (line stop)" + warn, replan.jl:244-249; CBF/HJ is future |
| ⑨ OOD visualization | 🔴 **absent** | zero MeshCat/marker code in src/respec/ |
| ⑩ evaluation | 🟡 partial | translation P0-P3 done; **behavioral precede was 0/6 (persistence, now fixed → re-run needed)**; P4 aggregate pending |

## Safety-predicate coverage (the C2 gap, expanded)

Both docs name the absolute invariants as **precedence · collision · capacity ·
deadlock-freedom**. The DSL is exactly four kinds (Precede, Deadline, ForbidWindow,
ForbidAgent). So:
- **precedence** → Precede ✅
- **timing/availability** → Deadline / ForbidWindow / ForbidAgent ✅ (not in the
  original invariant list, but useful)
- **collision** → handled by RVO at *execution* time, NOT verified as a pre-execution
  formal invariant ❌
- **capacity** (transport-team size) / **deadlock-freedom** → no verified predicate ❌

To defend "verifiably safe" (C2), these need formalizing as invariants the gate
checks — currently only precedence is.

## Priority by goal

- **Thesis / publication** → expand safety predicates (collision/capacity/deadlock,
  pillar ②) + package the benchmark with a *violation-count* metric (C4).
- **Autonomous-system completion** → ① detection/abstain + ⑥⑦ resume full-loop
  (pillar ③). **← chosen goal; see `autonomy_impl_workflow_2026-06-22.md`.**
- **Demo / presentation** → ⑨ visualization + one full-loop run recorded.
