# DESIGN_STEERING — DSPy as a vector-steering layer over the surrogate

Status: design 2026-07-30. Skeleton in `steering.py`; DSPy signature in
`ConstructionBots.jl/src/respec/llm_service/steering_signature.py`.

---

## 1. The problem this fixes

Today the LLM producer returns `chosen` — one macro name. The surrogate returns real numbers.
**Different output spaces**, so the only way to combine them is a switch: use one *or* the other.
That framing is why the DSPy-vs-forest experiment ended in a tie — it was never a contest one side
could win, it was two producers being asked to name the same label with the same information.

The classifier work makes this worse, not better: the router will now hand the LLM exactly the
events where the surrogate is *least* reliable, and a switch throws away everything the surrogate
still knows about that state.

## 2. The move: make the LLM speak the surrogate's coordinates

Do not ask the LLM for the answer. Ask it for a **direction in action space**, then let it push the
surrogate's score landscape.

```
score(a) = Q̂(s, a)  +  β(c) · ⟨w, φ(a)⟩
             ^              ^      ^
             |              |      └─ φ(a) = the 6 ACTION_DESCRIPTORS, already in features_agnostic.py
             |              └──────── w ∈ R⁶, the LLM's preference over those axes
             └─────────────────────── the surrogate, unchanged
```

`φ(a)` exists already: `a_cost, a_intervenes, a_soft, a_restores_capacity, a_relocates_work,
a_spatial`. So "this novel thing needs capacity restored, cost is acceptable, do not move work
spatially" is a *vector*, not a sentence — and it applies to macros the surrogate has never scored,
which is the entire point on an OOD event.

### Three levels

| | LLM output | combination | works on an unseen macro? |
|---|---|---|---|
| **L1** (today) | macro label | LLM overrides | no |
| **L2** (tonight) | utility `u ∈ R⁵` over macros + confidence `c` | `Q̂ + β(c)·u` | no |
| **L3** (target) | descriptor preference `w ∈ R⁶` + `c` | `Q̂ + β(c)·⟨w, φ(a)⟩` | **yes** |

Tonight implements the **L2 blend with the L3 schema**: the signature carries both `u` and `w`, only
`u` is consumed. That way switching to L3 is a one-line change in the blender, not a re-prompt.

## 3. β — the steering strength, and the thing most likely to go wrong

`β(c) = β_max · calib(c)` where `c` is the LLM's self-reported confidence.

**β must start at 0.** An uncalibrated confidence with a large β actively damages a surrogate that
is already good on known kinds. The evaluation is therefore a sweep, `β ∈ {0, 0.1, 0.25, 0.5, 1.0}`,
and `β = 0` (surrogate alone) is a legitimate winner. Reporting a tuned β without showing the sweep
would hide exactly the failure this design risks.

`calib(c)` is not the identity. LLM verbalised confidence is known to be poorly calibrated, so `c`
is binned and mapped to empirical accuracy on a held-out set — the same conformal machinery already
used for the novelty band, applied to the producer.

## 4. Normalisation — why the blend is not just an addition

`Q̂` is in units of closed nodes (tens); `⟨w, φ(a)⟩` is O(1). Adding them raw makes β meaningless
and instance-dependent. So the blender min–max normalises `Q̂` **within the instance's valid
macros** before adding. Then β = 0.5 means "the LLM can move a decision half the width of the
surrogate's own spread", which is interpretable and comparable across instances.

## 5. What DSPy is actually for here

Not for being smarter. For making a **structured output arrive intact**. The metrics are therefore
robustness metrics, not accuracy metrics:

| metric | why it matters |
|---|---|
| `schema_valid_rate` | did a well-formed `(u, w, c)` come back at all |
| `silent_noop_rate` | **currently unmeasured.** `dspy_service.VALID` drops an illegal macro to NOOP with no log; an LLM that names illegal actions looks obedient |
| `hallucinated_field_rate` | references to robots/zones that do not exist |
| `retry_count` | parses per successful decision |
| `confidence_ece` | expected calibration error of `c` — gates whether β may exceed 0 |
| `steering_gain` | Δ regret at best β vs β = 0 |

Comparison is **raw prompt vs DSPy-optimised**, on the same events. "DSPy improved schema validity
from X% to Y%" is a claim about robustness we can actually support; "DSPy picks better macros" was
not.

## 6. Where it sits in the pipeline

```
event → classifier (DESIGN_CLASSIFIER.md)
          ├─ known    → surrogate alone                       (β irrelevant)
          └─ OOD      → DSPy steering vector → blend with Q̂ → verifier → enact
                                                     ↓
                                        oracle label → pool → refit → refresh_gate
```

The steering vector is also the **seed for assimilation**: the LLM's `w` is a first estimate of
where the new disturbance sits in descriptor space, before the oracle label arrives.

## 7. Risks

1. **β > 0 with uncalibrated `c` degrades known-kind performance.** Mitigated by the sweep and by
   gating β on `confidence_ece`.
2. **`u` and `w` disagree.** Log both, consume `u` only, and report the disagreement rate — it is a
   free measurement of whether the LLM's action-space reasoning is internally consistent.
3. **The blend hides LLM failure.** If `β` is small, a broken producer looks harmless. So schema
   metrics are reported independently of the blend, never only through final regret.
