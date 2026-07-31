#!/usr/bin/env python
"""
DSPy-STYLE producer experiment  (implemented on the OpenAI SDK directly).

SUPERSEDED by `dspy_real_experiment.py`, which runs the ACTUAL dspy package. Keep this file only as
the hand-rolled cross-check: its P0 reproduces the real dspy.Predict zero-shot arm exactly
(reg=0.544 / top1=0.45 on gpt-4o-mini), which is what validates the hand implementation.

The claim below -- that dspy could not be installed -- was WRONG and is retained only so the
correction is legible: dspy 3.2.1 installs and runs fine on this env's numpy 1.23.5 / tensorflow 2.12.
Its declared `numpy>=1.26` floor is an unmet metadata marker, not a runtime blocker for Predict /
LabeledFewShot / BootstrapFewShot / MIPROv2. (설치 불가라던 위 근거는 사실이 아니었음.)

  [stale] "dspy 3.x requires numpy>=1.26, mutually exclusive with tensorflow 2.12 (numpy<1.24)."

We implement DSPy's THREE core ideas by hand:

  (P0) zero-shot        : task description + query state -> macro.            (== plain prompting)
  (P1) labeled few-shot : + K oracle (state -> best-macro) demonstrations.    (== dspy.Predict w/ demos)
  (P2) BootstrapFewShot : demos are FILTERED to the ones the model itself gets right (self-consistent),
                          the exact dspy.BootstrapFewShot semantics. This is the "programming not
                          prompting" step: demos are chosen by a METRIC, not hand-picked.

All three choose a macro for a held-out OOD instance; scored with the SAME cost-aware
feasibility-lexicographic LOO decision-regret as sweep_surrogate/ladder, so the LLM producer is
directly comparable to the forest surrogate (graded_hs_all: forest reg=0.150, top1=0.85).

Model: gpt-4o-mini (cheap, temperature 0). ~60 calls total (<$0.05). Results -> sweep_lab/dspy_report.txt
Usage: python dspy_experiment.py
"""
import os, sys, json, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e1_analyze import load, cost_lex_key, MACRO_COST, MACRO_NAME
import openai

HERE = os.path.dirname(os.path.abspath(__file__))
LAM = 3.0
MODEL = os.environ.get("DSPY_MODEL", "gpt-4o-mini")   # DSPY_MODEL=gpt-4o to test a stronger producer
import wm_datasets
# Pinned to HS_ALL: the published forest baseline in this file's docstring
# (reg=0.150, top1=0.85) was measured on it.  DSPY_DATA / WM_DATASET override.
DATA = wm_datasets.resolve(os.environ.get("DSPY_DATA"), default=wm_datasets.HS_ALL)
NAME2ID = {v: k for k, v in MACRO_NAME.items()}
client = openai.OpenAI()
_CACHE = {}
_CALLS = [0]

MACRO_DOC = """The 5 candidate recovery macros (a re-specification DSL action):
- NOOP: do nothing / restraint. Best when the disruption is absorbed by slack or spares and
  intervening would waste a scarce resource.
- Replace: swap the affected robot for a spare from the pool. Best on a real fault or a deeply
  depleted battery WHEN spares remain. Costs 1 schedule-unit.
- Deprioritize: lower the affected robot's task priority (mild, cheap=0.3). A middle option.
- ForbidZone: mark a no-go region and reroute the build around it. Best when a spatial zone is
  blocked. Costs 1.
- ReformTeam: re-form the multi-robot assembly team. Costs 1.
Adaptation cost matters: NOOP is free, Deprioritize=0.3, Replace/ForbidZone/ReformTeam=1.0. An
intervention must recover more than it costs, otherwise NOOP (restraint) is the right call."""


def state_line(row):
    """Render the public decision-time state the producer is allowed to read (no oracle leakage)."""
    def g(k, d=None):
        v = row.get(k, d)
        return d if v is None or (isinstance(v, float) and v != v) else v
    kind = g("kind"); soc = g("soc"); ov = g("zone_overlap")
    parts = [f"OOD kind={kind}", f"severity={g('severity')}",
             f"spares_left={int(g('spare_count', 0))}", f"agents_pending={int(g('agent_pending', -1))}",
             f"progress={float(g('progress', 0.0)):.2f}", f"n_active={int(g('n_active', 0))}"]
    if kind == "battery" and soc is not None:
        parts.insert(1, f"SoC={float(soc):.2f}")
    if kind in ("zone", "zoneblk") and ov not in (None, -1.0):
        parts.insert(1, f"zone_overlap={float(ov):.2f}")
    return ", ".join(str(p) for p in parts)


def ask(state_desc, demos):
    """One producer call: state (+optional demos) -> macro name. Cached, deterministic."""
    key = (state_desc, tuple(demos))
    if key in _CACHE:
        return _CACHE[key]
    demo_block = ""
    if demos:
        demo_block = "\nWorked examples (state -> correct macro):\n" + "\n".join(
            f"  {i+1}. {d[0]}  =>  {d[1]}" for i, d in enumerate(demos)) + "\n"
    prompt = (f"{MACRO_DOC}\n{demo_block}\nNow choose the single best macro for this new event.\n"
              f"STATE: {state_desc}\n"
              'Respond as strict JSON: {"reasoning": "<one sentence>", "macro": "<one of '
              'NOOP|Replace|Deprioritize|ForbidZone|ReformTeam>"}')
    for attempt in range(3):
        try:
            r = client.chat.completions.create(model=MODEL, temperature=0, max_tokens=120,
                messages=[{"role": "user", "content": prompt}])
            _CALLS[0] += 1
            txt = r.choices[0].message.content.strip()
            s = txt[txt.find("{"): txt.rfind("}") + 1]
            macro = json.loads(s)["macro"].strip()
            macro = macro if macro in NAME2ID else "NOOP"
            _CACHE[key] = macro
            return macro
        except Exception as e:
            if attempt == 2:
                _CACHE[key] = "NOOP"
                return "NOOP"
            time.sleep(1.5)


def main():
    df = load(os.path.join(HERE, DATA) if not os.path.isabs(DATA) else DATA)
    df = df[df.fired == True].copy()
    full = [i for i, g in df.groupby("instance") if len(g) == 5]
    df = df[df.instance.isin(full)].reset_index(drop=True)

    iids = list(df.instance.unique())
    state, scores, best = {}, {}, {}
    for i in iids:
        g = df[df.instance == i]
        state[i] = state_line(g[g.macro == 0].iloc[0].to_dict())
        cbm = {int(m): float(c) - LAM * MACRO_COST[int(m)] for m, c in zip(g.macro.values, g.closed.values)}
        scores[i] = cbm
        b = max(g.itertuples(index=False), key=lambda r: cost_lex_key(r.complete, r.closed, r.makespan, r.macro, LAM))
        best[i] = int(b.macro)

    def regret(i, macro_id):
        cbm = scores[i]; bc = cbm[best[i]]; span = max(bc - min(cbm.values()), 1e-9)
        mid = macro_id if macro_id in cbm else best[i]
        return (bc - cbm[mid]) / span

    def score(picks):
        regs = [regret(i, picks[i]) for i in iids]
        top1 = [1.0 if picks[i] == best[i] else 0.0 for i in iids]
        return sum(regs) / len(regs), sum(top1) / len(top1)

    tag = MODEL.replace(".", "").replace("-", "")
    out = open(os.path.join(HERE, "sweep_lab", "dspy_report_%s.txt" % tag), "w", encoding="utf-8")

    def emit(s=""):
        print(s); out.write(s + "\n")

    emit("=" * 84)
    emit("DSPy-STYLE PRODUCER EXPERIMENT (OpenAI %s, LOO on graded_hs_all, %d instances)" % (MODEL, len(iids)))
    emit("baseline to beat: forest surrogate  reg=0.150  top1=0.85  (from sweep)")
    emit("=" * 84)

    # ---- P0: zero-shot (also used to bootstrap) ----
    zpick = {i: NAME2ID[ask(state[i], [])] for i in iids}
    z_reg, z_top1 = score(zpick)
    emit("\nP0 zero-shot        : reg=%.3f  top1=%.2f" % (z_reg, z_top1))

    # ---- P1: labeled few-shot (LOO: demos = all OTHER instances' oracle labels) ----
    p1pick = {}
    for i in iids:
        demos = [(state[j], MACRO_NAME[best[j]]) for j in iids if j != i][:8]
        p1pick[i] = NAME2ID[ask(state[i], demos)]
    p1_reg, p1_top1 = score(p1pick)
    emit("P1 labeled few-shot : reg=%.3f  top1=%.2f  (%+.3f vs zero-shot)" % (p1_reg, p1_top1, z_reg - p1_reg))

    # ---- P2: BootstrapFewShot -- keep only demos the model got right zero-shot (self-consistent) ----
    good = [j for j in iids if zpick[j] == best[j]]
    emit("\nBootstrap: %d/%d instances are self-consistent demos (model's zero-shot == oracle)" % (len(good), len(iids)))
    p2pick = {}
    for i in iids:
        demos = [(state[j], MACRO_NAME[best[j]]) for j in good if j != i][:8]
        p2pick[i] = NAME2ID[ask(state[i], demos)]
    p2_reg, p2_top1 = score(p2pick)
    emit("P2 BootstrapFewShot : reg=%.3f  top1=%.2f  (%+.3f vs zero-shot)" % (p2_reg, p2_top1, z_reg - p2_reg))

    # ---- summary vs surrogate ----
    emit("\n" + "-" * 84)
    emit("SUMMARY (lower reg = better; forest surrogate = 0.150 / 0.85)")
    emit("  %-22s %8s %8s" % ("producer", "reg", "top1"))
    for nm, rg, tp in (("forest surrogate", 0.150, 0.85), ("P0 zero-shot", z_reg, z_top1),
                       ("P1 labeled few-shot", p1_reg, p1_top1), ("P2 BootstrapFewShot", p2_reg, p2_top1)):
        emit("  %-22s %8.3f %8.2f" % (nm, rg, tp))
    emit("\ntotal LLM calls: %d  (model=%s)" % (_CALLS[0], MODEL))
    emit("takeaway: DSPy's optimization = P2-P0 delta of %+.3f regret from FILTERING demos by a metric," % (z_reg - p2_reg))
    emit("  not from writing a better prompt. Whether the LLM producer beats the cheap forest surrogate")
    emit("  is the cost-of-adaptation question: even if equal quality, the forest is ~1e6x cheaper/call.")
    out.close()
    print("\nwrote sweep_lab/dspy_report.txt")


if __name__ == "__main__":
    main()
