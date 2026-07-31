#!/usr/bin/env python
"""
SANITY LADDER HARNESS — the collaborator's "no OOD -> a little OOD -> more" check, made rigorous.

The question behind the ladder is: does OOD SEVERITY actually move the correct decision, and does the
surrogate track that move? A ladder is only MEANINGFUL if, as severity rises within one OOD kind:
  (1) the ORACLE-best macro FLIPS (harmless -> NOOP; moderate -> Deprioritize; severe -> Replace/ForbidZone).
      If the best macro is constant, the rungs test nothing (the "decision-easy" trap).
  (2) fixed-policy regret curves CROSS: always-NOOP regret RISES with severity while always-Replace
      regret FALLS — they must cross at the decision boundary. This is the litmus test that the ladder
      spans a real boundary rather than sitting on one side of it.
  (3) the SURROGATE stays low-regret across every rung, while the strong state-blind baseline
      (always_per_kind: the kind's majority macro) fails on the rungs whose best macro != the majority.

We run this PER KIND with a kind-appropriate severity axis (battery: SoC, lower=worse; zone: overlap
fraction; fault: harmless-idle vs active), because forcing one cross-kind axis would be dishonest.

Scoring is cost-aware feasibility-lexicographic (EVALUATION.md), identical to sweep_surrogate/e1_analyze,
so NOOP is a live option (restraint can be correct) — without that, harmless rungs are undefined.

Usage:
  python ladder.py [dataset.jsonl ...]   (default: all oracle/out/graded/*.jsonl)
  writes sweep_lab/ladder_report.txt
"""
import os, sys, glob, math
for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS"):
    os.environ[_v] = "1"
import numpy as np
try:
    sys.stdout.reconfigure(encoding="utf-8")   # Windows console defaults to cp949; force UTF-8
except Exception:
    pass
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e1_analyze import load, featurize, cost_lex_key, MACRO_COST, MACRO_NAME
from surrogate_model import build_model, MODEL_NAME
from sklearn.model_selection import LeaveOneGroupOut
import pandas as pd

LAM = 3.0
# the sweep winner (lr=0.2) is the surrogate we deploy on the ladder; current (0.08) shown for contrast
SURR = dict(max_iter=300, max_depth=4, learning_rate=0.2, min_samples_leaf=3, l2_regularization=1.0)


def adj_closed(row_closed, macro):
    """cost-aware value of a (macro) outcome: closed nodes minus the macro's adaptation cost."""
    return float(row_closed) - LAM * MACRO_COST[int(macro)]


def instance_scores(g):
    """dict macro-> cost-aware value, plus the oracle-best macro (feasibility-lexicographic)."""
    cbm = {int(m): adj_closed(c, m) for m, c in zip(g.macro.values, g.closed.values)}
    best = max(g.itertuples(index=False),
               key=lambda r: cost_lex_key(r.complete, r.closed, r.makespan, r.macro, LAM))
    return cbm, int(best.macro)


def rung_of(kind, row):
    """Map an instance to a ladder rung (0=harmless .. 2=severe) using a kind-appropriate axis."""
    if kind == "battery":
        soc = float(row.get("soc", 0.5))
        return 2 if soc <= 0.15 else (1 if soc <= 0.30 else 0)   # deep / mild / absorbed
    if kind in ("zone", "zoneblk"):
        ov = float(row.get("zone_overlap", 0.0) or 0.0)
        return 0 if ov <= 0.01 else (1 if ov <= 0.6 else 2)      # harmless / partial / heavy block
    if kind == "fault":
        # faultidle (fault on a robot with nothing pending) is harmless; active fault is severe,
        # and with 0 spares Replace wedges so the decision is genuinely contested.
        pend = float(row.get("agent_pending", 1))
        return 0 if pend <= 0 else 2
    return 1


RUNG_NAME = {0: "harmless", 1: "moderate", 2: "severe"}


def build():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    files = args or sorted(glob.glob(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                   "oracle", "out", "graded", "*.jsonl")))
    frames = [load(f) for f in files]
    df = pd.concat(frames, ignore_index=True)
    df = df[df.fired == True].copy()
    # keep only well-posed instances (all 5 macros present) so a ranking is defined
    full = [i for i, gg in df.groupby("instance") if len(gg) == 5]
    df = df[df.instance.isin(full)].reset_index(drop=True)
    return df, files


def main():
    df, files = build()
    out = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "sweep_lab", "ladder_report.txt"), "w", encoding="utf-8")

    def emit(s=""):
        print(s); out.write(s + "\n")

    emit("=" * 78)
    emit("SANITY LADDER REPORT  (cost-aware, lambda=%.1f)" % LAM)
    emit("built from %d dump files, %d full instances" % (len(files), df.instance.nunique()))
    emit("surrogate under test: %s (unified eval+deploy model)" % MODEL_NAME)
    emit("=" * 78)

    # ---------- per-instance oracle-best + one representative row ----------
    inst_rows = {i: g.iloc[0] for i, g in df.groupby("instance")}
    inst_kind = {i: str(g.kind.iloc[0]) for i, g in df.groupby("instance")}
    best_macro, scores = {}, {}
    for i, g in df.groupby("instance"):
        cbm, bm = instance_scores(g)
        scores[i] = cbm; best_macro[i] = bm

    # ---------- surrogate LOO predictions (trained across ALL kinds, judged per rung) ----------
    X = featurize(df).values
    cost = np.array([MACRO_COST[int(m)] for m in df.macro])
    y = df.closed.astype(float).values - LAM * cost
    groups = df.instance.values
    kind_of_inst = {i: inst_kind[i] for i in df.instance.unique()}
    surro_pick, perkind_pick = {}, {}
    for tr, te in LeaveOneGroupOut().split(X, y, groups):
        iid = groups[te][0]; g = df.iloc[te]
        m = build_model().fit(X[tr], y[tr])
        pred = m.predict(X[te]); macs = g.macro.values
        surro_pick[iid] = int(macs[np.argsort(-pred)][0])
        # strong state-blind opponent: majority best-macro of the SAME kind among training instances
        tr_best = [best_macro[j] for j in set(groups[tr]) if kind_of_inst[j] == kind_of_inst[iid]]
        perkind_pick[iid] = int(pd.Series(tr_best).mode().iloc[0]) if tr_best else best_macro[iid]

    def regret(iid, macro):
        cbm = scores[iid]; bc = cbm[best_macro[iid]]
        span = max(bc - min(cbm.values()), 1e-9)
        m = macro if macro in cbm else best_macro[iid]
        return (bc - cbm[m]) / span

    # ---------- per-kind ladder ----------
    overall = {}
    for kind in ("battery", "zoneblk", "fault"):
        iids = [i for i in df.instance.unique() if inst_kind[i] == kind]
        if not iids:
            continue
        by_rung = {}
        for i in iids:
            r = rung_of(kind, inst_rows[i])
            by_rung.setdefault(r, []).append(i)
        emit("\n" + "-" * 78)
        emit("LADDER - kind=%s   (%d instances)" % (kind, len(iids)))
        axis = {"battery": "SoC at event (LOW = more depleted = more severe)",
                "zoneblk": "zone_overlap fraction (HIGH = more of build blocked)",
                "fault":   "agent_pending at fault (idle=harmless vs active=severe)"}[kind]
        emit("severity axis: " + axis)
        emit("%-9s %3s  %-22s %8s %8s %8s %8s %9s" %
             ("rung", "n", "oracle-best (spread)", "NOOP", "Replace", "Depri", "surrog", "perkind"))
        rung_noop, rung_repl, rung_surro, rung_perkind, rung_flip = {}, {}, {}, {}, {}
        for r in sorted(by_rung):
            iis = by_rung[r]
            spread = pd.Series([best_macro[i] for i in iis]).value_counts()
            spread_s = ", ".join("%s x%d" % (MACRO_NAME[int(m)], c) for m, c in spread.items())
            noop = np.mean([regret(i, 0) for i in iis])
            repl = np.mean([regret(i, 1) for i in iis])
            depr = np.mean([regret(i, 2) for i in iis])
            sur = np.mean([regret(i, surro_pick[i]) for i in iis])
            pk = np.mean([regret(i, perkind_pick[i]) for i in iis])
            rung_noop[r], rung_repl[r], rung_surro[r], rung_perkind[r] = noop, repl, sur, pk
            rung_flip[r] = spread.index[0]
            emit("%-9s %3d  %-22s %8.2f %8.2f %8.2f %8.2f %9.2f" %
                 (RUNG_NAME[r], len(iis), spread_s, noop, repl, depr, sur, pk))
        # ---- verdict for this kind ----
        best_by_rung = [rung_flip[r] for r in sorted(rung_flip)]
        flips = len(set(best_by_rung)) > 1
        rungs = sorted(rung_noop)
        noop_rises = len(rungs) >= 2 and rung_noop[rungs[-1]] > rung_noop[rungs[0]] + 1e-9
        repl_falls = len(rungs) >= 2 and rung_repl[rungs[-1]] < rung_repl[rungs[0]] - 1e-9
        crosses = any(rung_noop[a] <= rung_repl[a] and rung_noop[b] >= rung_repl[b]
                      for a, b in zip(rungs, rungs[1:])) or (noop_rises and repl_falls and
                      rung_noop[rungs[0]] < rung_repl[rungs[0]] and rung_noop[rungs[-1]] > rung_repl[rungs[-1]])
        surro_mean = np.mean([rung_surro[r] for r in rungs])
        perkind_mean = np.mean([rung_perkind[r] for r in rungs])
        emit("VERDICT(%s): best-macro flips across rungs = %s (%s)" %
             (kind, "YES" if flips else "NO", " -> ".join(MACRO_NAME[int(m)] for m in best_by_rung)))
        emit("  NOOP-regret rises with severity = %s (%.2f -> %.2f) ; Replace-regret falls = %s (%.2f -> %.2f)"
             % ("YES" if noop_rises else "no", rung_noop[rungs[0]], rung_noop[rungs[-1]],
                "YES" if repl_falls else "no", rung_repl[rungs[0]], rung_repl[rungs[-1]]))
        emit("  curves cross (real decision boundary) = %s" % ("YES" if crosses else "no"))
        emit("  surrogate mean-regret=%.2f  vs  always_per_kind=%.2f  (surrogate better by %+.2f)"
             % (surro_mean, perkind_mean, perkind_mean - surro_mean))
        meaningful = flips and crosses
        emit("  => LADDER IS %s for kind=%s" %
             ("MEANINGFUL" if meaningful else "WEAK (kind stays on one side of the boundary)", kind))
        overall[kind] = dict(flips=flips, crosses=crosses, meaningful=meaningful,
                             surro=surro_mean, perkind=perkind_mean)

    # ---------- overall summary ----------
    emit("\n" + "=" * 78)
    emit("OVERALL LADDER VERDICT")
    n_mean = sum(1 for k in overall if overall[k]["meaningful"])
    for k, v in overall.items():
        emit("  %-9s meaningful=%s  flips=%s  crosses=%s  surro=%.2f perkind=%.2f"
             % (k, v["meaningful"], v["flips"], v["crosses"], v["surro"], v["perkind"]))
    emit("  %d/%d kinds exercise a real decision boundary." % (n_mean, len(overall)))
    emit("  A ladder is JUSTIFIED where meaningful=YES: severity flips the answer AND the surrogate")
    emit("  tracks the flip better than a per-kind lookup. Where meaningful=NO, add severities that")
    emit("  straddle the boundary (that rung is missing) before drawing conclusions.")
    out.close()


if __name__ == "__main__":
    main()
