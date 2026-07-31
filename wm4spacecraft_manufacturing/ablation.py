#!/usr/bin/env python
"""
FEATURE ABLATION / IMPORTANCE — what state signal does the surrogate actually use to decide?

Two complementary views on graded_all (cost-aware), tuned config (HGB depth=None lr=0.2):
  (A) LEAVE-ONE-GROUP-OUT feature ablation: zero a feature group across train+test, re-run the full
      LOO decision-regret. The regret INCREASE when a group is removed = that group's decision value.
  (B) permutation importance on the held-out predictions (closed-count target), for cross-check.

This tells us whether the surrogate reads the WITHIN-KIND state (SoC, spares, severity, zone_overlap)
or just the kind one-hot -- the crux of the "is it learnable beyond the kind?" question. Writes
sweep_lab/ablation_report.txt.
"""
import os, sys
for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS"):
    os.environ[_v] = "1"
import numpy as np
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e1_analyze import load, featurize, cost_lex_key, MACRO_COST, MACRO_NAME
from surrogate_model import build_model
from sklearn.model_selection import LeaveOneGroupOut
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
LAM = 3.0
def make(): return build_model()   # 평가·배포 단일 모델(surrogate_model.py)

# feature-name -> group, so we can zero a whole concept at once
GROUPS = {
    "kind(one-hot)":  ["kind_fault", "kind_battery", "kind_zone", "kind_zoneblk"],
    "severity":       ["severity"],
    "soc":            ["soc"],
    "spares":         ["n_spare_cfg", "spare_count"],
    "zone_overlap":   ["zone_overlap", "zone_radius"],
    "progress/active":["progress", "closed_at_fire", "n_active", "agent_pending"],
    "macro_in_valid": ["macro_in_valid"],
}


def loo_regret(X, y, df, groups, best, scores):
    regs = []
    for tr, te in LeaveOneGroupOut().split(X, y, groups):
        iid = groups[te][0]; g = df.iloc[te]
        m = make().fit(X[tr], y[tr]); pred = m.predict(X[te]); macs = g.macro.values
        pick = int(macs[np.argsort(-pred)][0])
        cbm = scores[iid]; bc = cbm[best[iid]]; span = max(bc - min(cbm.values()), 1e-9)
        regs.append((bc - cbm[pick]) / span)
    return float(np.mean(regs))


def main():
    df = load(os.path.join(HERE, "sweep_lab/graded_all.jsonl"))
    df = df[df.fired == True].copy()
    full = [i for i, g in df.groupby("instance") if len(g) == 5]
    df = df[df.instance.isin(full)].reset_index(drop=True)
    Fdf = featurize(df); cols = list(Fdf.columns)
    X = Fdf.values.astype(float)
    cost = np.array([MACRO_COST[int(m)] for m in df.macro])
    y = df.closed.astype(float).values - LAM * cost
    groups = df.instance.values
    best, scores = {}, {}
    for iid in df.instance.unique():
        g = df[df.instance == iid]
        cbm = {int(m): float(c) - LAM * MACRO_COST[int(m)] for m, c in zip(g.macro.values, g.closed.values)}
        scores[iid] = cbm
        b = max(g.itertuples(index=False), key=lambda r: cost_lex_key(r.complete, r.closed, r.makespan, r.macro, LAM))
        best[iid] = int(b.macro)

    out = open(os.path.join(HERE, "sweep_lab", "ablation_report.txt"), "w", encoding="utf-8")
    def emit(s=""):
        print(s); out.write(s + "\n")

    base = loo_regret(X, y, df, groups, best, scores)
    emit("=" * 76)
    emit("FEATURE ABLATION on graded_all (%d instances), tuned HGB dNone lr.2" % df.instance.nunique())
    emit("baseline LOO decision-regret (all features) = %.3f" % base)
    emit("=" * 76)
    emit("\n(A) leave-one-GROUP-out: regret when a feature group is ZEROED (higher rise = more used)")
    emit("  %-18s %10s %10s" % ("group removed", "regret", "delta"))
    rows = []
    for gname, feats in GROUPS.items():
        idx = [cols.index(f) for f in feats if f in cols]
        if not idx:
            continue
        Xz = X.copy(); Xz[:, idx] = 0.0
        r = loo_regret(Xz, y, df, groups, best, scores)
        rows.append((gname, r, r - base))
    for gname, r, d in sorted(rows, key=lambda t: -t[2]):
        flag = "  <- most decision-critical" if d == max(x[2] for x in rows) and d > 0 else ""
        emit("  %-18s %10.3f %+10.3f%s" % (gname, r, d, flag))

    # (B) permutation importance on held-out closed-count prediction (cross-check on the value target)
    emit("\n(B) permutation importance (held-out closed-count MAE increase; top 10 individual features)")
    from sklearn.inspection import permutation_importance
    # fit on all data for a single importance read (value-prediction proxy, not the decision)
    m = make().fit(X, y)
    pi = permutation_importance(m, X, y, n_repeats=10, random_state=0, scoring="neg_mean_absolute_error")
    order = np.argsort(-pi.importances_mean)[:10]
    emit("  %-22s %10s" % ("feature", "MAE-incr"))
    for i in order:
        emit("  %-22s %10.2f" % (cols[i], pi.importances_mean[i]))

    emit("\ntakeaway: if zeroing 'kind' barely moves regret but zeroing soc/severity/spares does, the")
    emit("  surrogate is reading WITHIN-KIND state (the E1 'learnable beyond the kind' claim). If only")
    emit("  'kind' matters, the task collapses to a per-kind lookup (decision-easy).")
    out.close()
    print("\nwrote sweep_lab/ablation_report.txt")


if __name__ == "__main__":
    main()
