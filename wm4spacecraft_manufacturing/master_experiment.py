#!/usr/bin/env python
"""
MASTER EXPERIMENT — consolidates the parameter study and answers the collaborator's open questions
with numbers, across all three datasets:

  Q1 "is 300/0.08 optimal?"        -> compare CURRENT vs tuned HP per dataset (regret + top1).
  Q2 "more than one right solution?"-> TIE-AWARE regret decomposition. An instance is a TIE when the
                                       top-2 oracle macros are within TIE_EPS of the reachable span; on
                                       ties the argmax is arbitrary so low regret is TRIVIAL, not skill.
                                       We split every metric into non-tie (the real decisions) vs tie.
  Q3 "how many OOD events / severity"-> handled by ladder.py (per-kind severity rungs).
  Q4 cost sensitivity               -> lambda sweep: how the decision mix + regret move with the
                                       adaptation-cost weight (NOOP restraint vs intervene).

Everything reuses e1_analyze's scoring VERBATIM (cost-aware feasibility-lexicographic), so numbers are
comparable to sweep_surrogate/ladder. Writes sweep_lab/master_report.txt.
"""
import os, sys, math
for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS"):
    os.environ[_v] = "1"
import numpy as np
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e1_analyze import (load, featurize, instance_admissible, oracle_best_row,
                        lex_key, cost_lex_key, MACRO_COST, MACRO_NAME)
from sklearn.ensemble import HistGradientBoostingRegressor, RandomForestRegressor, ExtraTreesRegressor
from sklearn.model_selection import LeaveOneGroupOut
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
TIE_EPS = 0.05

CONFIGS = [
    ("CURRENT-eval  HGB d4 lr.08", lambda: HistGradientBoostingRegressor(
        max_iter=300, max_depth=4, learning_rate=0.08, min_samples_leaf=3, l2_regularization=1.0, random_state=0)),
    ("tuned  HGB dNone lr.2",       lambda: HistGradientBoostingRegressor(
        max_iter=300, max_depth=None, learning_rate=0.2, min_samples_leaf=3, l2_regularization=1.0, random_state=0)),
    ("tuned  HGB dNone lr.08",      lambda: HistGradientBoostingRegressor(
        max_iter=300, max_depth=None, learning_rate=0.08, min_samples_leaf=3, l2_regularization=1.0, random_state=0)),
    ("ExtraTrees 200",              lambda: ExtraTreesRegressor(n_estimators=200, random_state=0, n_jobs=1)),
    ("CURRENT-deploy RF 60 d6",     lambda: RandomForestRegressor(n_estimators=60, max_depth=6, min_samples_leaf=2, random_state=0, n_jobs=1)),
]

DATASETS = [
    ("e1_dataset (default)",  os.path.join(HERE, "oracle/out/e1_dataset.jsonl"), False),
    ("graded_hs_all (c-aware)", os.path.join(HERE, "oracle/out/graded_hs_all.jsonl"), True),
    ("graded_all (c-aware)",  os.path.join(HERE, "sweep_lab/graded_all.jsonl"), True),
]


def prep(path, cost_aware, lam=3.0):
    df = load(path); df = df[df.fired == True].copy()
    if cost_aware:
        adm = [i for i, g in df.groupby("instance") if len(g) == 5]
    else:
        adm = [i for i in df.instance.unique() if instance_admissible(df[df.instance == i])]
    df = df[df.instance.isin(adm)].reset_index(drop=True)
    best, scores, is_tie = {}, {}, {}
    for iid in df.instance.unique():
        g = df[df.instance == iid]
        cbm = {int(m): float(c) - (lam * MACRO_COST[int(m)] if cost_aware else 0.0)
               for m, c in zip(g.macro.values, g.closed.values)}
        if cost_aware:
            b = max(g.itertuples(index=False), key=lambda r: cost_lex_key(r.complete, r.closed, r.makespan, r.macro, lam))
        else:
            b = oracle_best_row(g)
        best[iid] = int(b.macro); scores[iid] = cbm
        vals = sorted(cbm.values(), reverse=True)
        span = max(vals[0] - vals[-1], 1e-9)
        is_tie[iid] = (len(vals) >= 2 and (vals[0] - vals[1]) / span < TIE_EPS)
    X = featurize(df).values
    cost = np.array([MACRO_COST[int(m)] for m in df.macro])
    y = df.closed.astype(float).values - (lam * cost if cost_aware else 0.0)
    return df, X, y, df.instance.values, best, scores, is_tie


def loo_metrics(make, X, y, df, groups, best, scores, is_tie):
    """LOO regret + top1, decomposed into tie / non-tie instances."""
    reg = {"all": [], "notie": [], "tie": []}
    top1 = {"all": [], "notie": []}
    for tr, te in LeaveOneGroupOut().split(X, y, groups):
        iid = groups[te][0]; g = df.iloc[te]
        m = make(); m.fit(X[tr], y[tr]); pred = m.predict(X[te])
        macs = g.macro.values; pick = int(macs[np.argsort(-pred)][0])
        cbm = scores[iid]; bc = cbm[best[iid]]; span = max(bc - min(cbm.values()), 1e-9)
        r = (bc - cbm[pick]) / span
        bucket = "tie" if is_tie[iid] else "notie"
        reg["all"].append(r); reg[bucket].append(r)
        top1["all"].append(1.0 if pick == best[iid] else 0.0)
        if bucket == "notie":
            top1["notie"].append(1.0 if pick == best[iid] else 0.0)
    return {k: (float(np.mean(v)) if v else float("nan")) for k, v in reg.items()}, \
           {k: (float(np.mean(v)) if v else float("nan")) for k, v in top1.items()}, \
           {k: len(v) for k, v in reg.items()}


def main():
    out = open(os.path.join(HERE, "sweep_lab", "master_report.txt"), "w", encoding="utf-8")

    def emit(s=""):
        print(s); out.write(s + "\n")

    emit("=" * 92)
    emit("MASTER EXPERIMENT  (tie-aware, cost-aware lambda=3.0, TIE_EPS=%.0f%% of span)" % (TIE_EPS * 100))
    emit("=" * 92)

    for dname, path, ca in DATASETS:
        if not os.path.exists(path):
            emit("\n[skip] %s (missing)" % dname); continue
        df, X, y, groups, best, scores, is_tie = prep(path, ca)
        n = df.instance.nunique(); ntie = sum(is_tie.values())
        dist = pd.Series([best[i] for i in df.instance.unique()]).map(MACRO_NAME).value_counts().to_dict()
        emit("\n" + "-" * 92)
        emit("DATASET: %s   | %d instances, tie=%d (%.0f%%), non-tie=%d" %
             (dname, n, ntie, 100 * ntie / max(n, 1), n - ntie))
        emit("  oracle-best distribution: %s" % dist)
        emit("  %-28s %8s %8s %8s | %8s %8s" %
             ("config", "reg_all", "reg_NOTIE", "reg_tie", "top1_all", "top1_NT"))
        rows = {}
        for cname, make in CONFIGS:
            reg, top1, ns = loo_metrics(make, X, y, df, groups, best, scores, is_tie)
            rows[cname] = reg
            emit("  %-28s %8.3f %8.3f %8.3f | %8.2f %8.2f" %
                 (cname, reg["all"], reg["notie"], reg["tie"], top1["all"], top1["notie"]))
        emit("  (reg_NOTIE is the HONEST number: regret on decision-consequential instances only.")
        emit("   reg_tie ~0 for any sane policy -> a low reg_all can be inflated by ties.)")

    # ---- lambda sweep on graded_all (cost sensitivity of the decision mix) ----
    path = os.path.join(HERE, "sweep_lab/graded_all.jsonl")
    if os.path.exists(path):
        emit("\n" + "=" * 92)
        emit("LAMBDA SWEEP on graded_all (cost weight -> restraint vs intervene); tuned HGB dNone lr.2")
        emit("  %-6s %10s %10s %10s   %s" % ("lambda", "reg_all", "reg_NOTIE", "tie%", "oracle-best mix"))
        for lam in (0.0, 1.0, 3.0, 6.0, 10.0):
            df, X, y, groups, best, scores, is_tie = prep(path, True, lam=lam)
            make = lambda: HistGradientBoostingRegressor(max_iter=300, max_depth=None, learning_rate=0.2,
                                                         min_samples_leaf=3, l2_regularization=1.0, random_state=0)
            reg, top1, ns = loo_metrics(make, X, y, df, groups, best, scores, is_tie)
            n = df.instance.nunique(); ntie = sum(is_tie.values())
            mix = pd.Series([best[i] for i in df.instance.unique()]).map(MACRO_NAME).value_counts().to_dict()
            emit("  %-6.1f %10.3f %10.3f %9.0f%%   %s" %
                 (lam, reg["all"], reg["notie"], 100 * ntie / max(n, 1), mix))
        emit("  (as lambda rises, intervention must 'pay for itself' -> NOOP wins more -> mix shifts to restraint.)")

    out.close()
    print("\nwrote sweep_lab/master_report.txt")


if __name__ == "__main__":
    main()
