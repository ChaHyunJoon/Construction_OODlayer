#!/usr/bin/env python
"""
Surrogate hyper-parameter sweep — answers the collaborator's note that the surrogate's
`300 trees / lr 0.08` (HistGBR) and `60 x depth6` (RF) are HAND-SET, never tuned.

WHAT THIS DOES (and does NOT):
  * Objective is DECISION quality, not R^2:  primary = mean leave-one-instance-out (LOO)
    decision-regret (feasibility-lexicographic, EVALUATION.md), tie-break by top-1 accuracy,
    then catastrophic-choice count. This is the metric EVALUATION.md says is the headline.
  * Reuses e1_analyze's load/featurize/admissibility/scoring VERBATIM, so a config's number
    here is directly comparable to `python e1_analyze.py`. Only the MODEL is swapped.
  * Runs on the DISCRIMINATIVE dataset (graded_hs_all --cost-aware): the default e1_dataset is
    decision-easy (always_per_kind already 0.000 regret) so every config ties there — useless
    for tuning. graded_hs_all leaves regret on the table, so HP choices actually move the number.
  * Reports the DATA-level tie-rate ("more than one right solution?"): fraction of instances
    where the top-2 oracle macros are within TIE_EPS of each other — there the argmax is
    arbitrary and low regret is trivial, not skill.

HONESTY CAVEAT (printed in the output too): with only ~20 instances, picking the best of
hundreds of configs is selection-biased. So we (a) re-run the top configs over 5 seeds and
(b) paired-bootstrap the best vs the CURRENT config — if the CI crosses 0 the "win" is noise.

Usage:
  python sweep_surrogate.py                       # graded_hs_all --cost-aware (default)
  python sweep_surrogate.py <dataset.jsonl> [--cost-aware] [--lam 3.0] [--top 12]
"""
import sys, os, math, argparse
# Pin all math-lib thread pools to 1 BEFORE importing sklearn/numpy. On tiny data (80 rows) the
# per-fit compute is microscopic, but sklearn's OpenMP/BLAS pools try to grab every core per fit;
# with many fits (and any concurrent process) the Windows scheduler thrashes -> minutes of wall
# clock at ~0 CPU. Single-threaded is both faster here and contention-proof.
for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS",
           "NUMEXPR_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
    os.environ[_v] = "1"
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e1_analyze import (load, featurize, instance_admissible, oracle_best_row,
                        lex_key, cost_lex_key, MACRO_COST, MACRO_NAME, closed_regret)
from sklearn.ensemble import (HistGradientBoostingRegressor, RandomForestRegressor,
                              ExtraTreesRegressor)
from sklearn.linear_model import Ridge
from sklearn.preprocessing import StandardScaler
from sklearn.pipeline import make_pipeline
from sklearn.model_selection import LeaveOneGroupOut

TIE_EPS = 0.05   # top-2 within 5% of the reachable span -> "tie" (argmax arbitrary)

# ---- CURRENT hand-set configs (the ones the collaborator flagged) -----------------------
CURRENT_HGB = ("hgb", 300, 4, 0.08, 3, 1.0)   # e1_analyze.py:303 (the EVAL model)
CURRENT_RF  = ("rf", 60, 6, 2)                 # export_surrogate.py:238 (the DEPLOYED model)


def make_model(spec, seed):
    """Build a fresh estimator from a spec tuple. seed varies RF/ET/HGB subsampling for robustness."""
    fam = spec[0]
    if fam == "hgb":
        _, mi, md, lr, msl, l2 = spec
        return HistGradientBoostingRegressor(max_iter=mi, max_depth=md, learning_rate=lr,
                                             min_samples_leaf=msl, l2_regularization=l2,
                                             random_state=seed)
    if fam == "rf":
        _, ne, md, msl = spec
        return RandomForestRegressor(n_estimators=ne, max_depth=md, min_samples_leaf=msl,
                                     random_state=seed, n_jobs=1)
    if fam == "et":
        _, ne, md, msl = spec
        return ExtraTreesRegressor(n_estimators=ne, max_depth=md, min_samples_leaf=msl,
                                   random_state=seed, n_jobs=1)
    if fam == "ridge":
        return make_pipeline(StandardScaler(), Ridge(alpha=spec[1]))
    raise ValueError(spec)


def spec_label(spec):
    fam = spec[0]
    if fam == "hgb":
        _, mi, md, lr, msl, l2 = spec
        return f"HGB  iter={mi:<3} depth={str(md):<4} lr={lr:<4} msl={msl} l2={l2}"
    if fam == "rf":
        return f"RF   n={spec[1]:<3} depth={str(spec[2]):<4} msl={spec[3]}"
    if fam == "et":
        return f"ET   n={spec[1]:<3} depth={str(spec[2]):<4} msl={spec[3]}"
    if fam == "ridge":
        return f"Ridge alpha={spec[1]}"
    return str(spec)


def build_grid():
    grid = []
    # HistGradientBoosting — the family E1-E4 use. FOCUSED on the collaborator's literal question:
    # is the hand-set (max_iter=300, lr=0.08, depth=4) optimal, or arbitrary? Sweep those 3 axes.
    for mi in (100, 300, 600):
        for lr in (0.03, 0.08, 0.2):
            for md in (3, 4, None):
                grid.append(("hgb", mi, md, lr, 3, 1.0))
    # RandomForest — the family the demo DEPLOYS. Include the current 60/6 plus a few neighbours.
    for ne in (60, 200):
        for md in (6, None):
            grid.append(("rf", ne, md, 2))
    # reference points
    grid.append(("et", 200, None, 1))
    for alpha in (1.0,):
        grid.append(("ridge", alpha))
    # make sure the two CURRENT configs are present so we can rank them
    for c in (CURRENT_HGB, CURRENT_RF):
        if c not in grid:
            grid.append(c)
    return grid


def evaluate(spec, X, y, df, groups, best, cost_aware, lam, seeds=(0,)):
    """LOO decision-regret / top-1 / catastrophic for one config, averaged over seeds.
    Mirrors e1_analyze.main's scoring exactly (only the estimator changes)."""
    logo = LeaveOneGroupOut()
    per_seed_reg, per_seed_top1, per_seed_cat = [], [], []
    for seed in seeds:
        regs, agree, cat = [], [], 0
        for tr, te in logo.split(X, y, groups):
            iid = groups[te][0]
            g = df.iloc[te]
            model = make_model(spec, seed)
            model.fit(X[tr], y[tr])
            pred = model.predict(X[te])
            macros = g.macro.values
            closed_by_macro = {int(m): float(c) - (lam * MACRO_COST[int(m)] if cost_aware else 0.0)
                               for m, c in zip(macros, g.closed.values)}
            best_macro = best[iid]
            best_closed = closed_by_macro[best_macro]
            worst = min(closed_by_macro.values())
            span = max(best_closed - worst, 1e-9)
            order = [int(m) for m in macros[np.argsort(-pred)]]
            pick = order[0]
            regs.append(closed_regret(closed_by_macro[pick], best_closed) / span)
            agree.append(1.0 if pick == best_macro else 0.0)
            if (best_closed - closed_by_macro[pick]) / max(best_closed, 1) > 0.15:
                cat += 1
        per_seed_reg.append(np.mean(regs))
        per_seed_top1.append(np.mean(agree))
        per_seed_cat.append(cat)
    return {"regret": float(np.mean(per_seed_reg)), "regret_sd": float(np.std(per_seed_reg)),
            "top1": float(np.mean(per_seed_top1)), "cat": float(np.mean(per_seed_cat)),
            "spec": spec}


def per_instance_regret(spec, X, y, df, groups, best, cost_aware, lam, seed=0):
    """Return the vector of per-instance regrets (for the paired bootstrap vs current)."""
    logo = LeaveOneGroupOut()
    out = []
    for tr, te in logo.split(X, y, groups):
        iid = groups[te][0]; g = df.iloc[te]
        model = make_model(spec, seed); model.fit(X[tr], y[tr])
        pred = model.predict(X[te]); macros = g.macro.values
        cbm = {int(m): float(c) - (lam * MACRO_COST[int(m)] if cost_aware else 0.0)
               for m, c in zip(macros, g.closed.values)}
        bc = cbm[best[iid]]; span = max(bc - min(cbm.values()), 1e-9)
        pick = [int(m) for m in macros[np.argsort(-pred)]][0]
        out.append(closed_regret(cbm[pick], bc) / span)
    return np.array(out)


def tie_rate(df, best, cost_aware, lam):
    """DATA property: fraction of instances where top-2 oracle macros are within TIE_EPS of span."""
    n_tie = 0; iids = list(df.instance.unique())
    for iid in iids:
        g = df[df.instance == iid]
        cbm = {int(m): float(c) - (lam * MACRO_COST[int(m)] if cost_aware else 0.0)
               for m, c in zip(g.macro.values, g.closed.values)}
        vals = sorted(cbm.values(), reverse=True)
        if len(vals) < 2:
            continue
        span = max(vals[0] - vals[-1], 1e-9)
        if (vals[0] - vals[1]) / span < TIE_EPS:
            n_tie += 1
    return n_tie, len(iids)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("data", nargs="?",
                    default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                         "oracle", "out", "graded_hs_all.jsonl"))
    ap.add_argument("--cost-aware", action="store_true", default=None)
    ap.add_argument("--lam", type=float, default=3.0)
    ap.add_argument("--top", type=int, default=12)
    a = ap.parse_args()
    # graded_hs_all is only well-posed in cost-aware mode; default to it unless told otherwise
    cost_aware = True if a.cost_aware is None else a.cost_aware

    df = load(a.data)
    df = df[df.fired == True].copy()
    if cost_aware:
        adm = [i for i, g in df.groupby("instance") if len(g) == 5]
    else:
        adm = [i for i in df.instance.unique() if instance_admissible(df[df.instance == i])]
    df = df[df.instance.isin(adm)].reset_index(drop=True)

    best = {}
    for iid in df.instance.unique():
        g = df[df.instance == iid]
        if cost_aware:
            b = max(g.itertuples(index=False),
                    key=lambda r: cost_lex_key(r.complete, r.closed, r.makespan, r.macro, a.lam))
        else:
            b = oracle_best_row(g)
        best[iid] = int(b.macro)

    X = featurize(df).values
    cost = np.array([MACRO_COST[int(m)] for m in df.macro])
    y = df.closed.astype(float).values - (a.lam * cost if cost_aware else 0.0)
    groups = df.instance.values

    n_tie, n_all = tie_rate(df, best, cost_aware, a.lam)
    print(f"dataset: {os.path.basename(a.data)}  cost_aware={cost_aware} lam={a.lam}")
    print(f"admissible instances: {len(adm)}   distinct best-macros: {len(set(best.values()))}")
    print(f"tie-rate (top-2 within {TIE_EPS:.0%} of span): {n_tie}/{n_all} = {n_tie/max(n_all,1):.0%}"
          "   <- on these, low regret is trivial (argmax arbitrary)")

    grid = build_grid()
    print(f"\nsweeping {len(grid)} configs, LOO x {len(adm)} instances (single seed) ...", flush=True)
    import time as _t
    results = []
    _t0 = _t.time()
    for _j, s in enumerate(grid):
        results.append(evaluate(s, X, y, df, groups, best, cost_aware, a.lam, seeds=(0,)))
        if (_j + 1) % 20 == 0 or _j == len(grid) - 1:
            print(f"  ...{_j+1}/{len(grid)} configs done ({_t.time()-_t0:.0f}s)", flush=True)
    # rank: regret asc, top1 desc, catastrophic asc
    results.sort(key=lambda r: (r["regret"], -r["top1"], r["cat"]))

    def rank_of(spec):
        for i, r in enumerate(results):
            if r["spec"] == spec:
                return i + 1
        return None

    print(f"\n=== TOP {a.top} by LOO decision-regret (single seed) ===")
    print(f"{'#':>3} {'config':<38}{'regret':>8}{'top1':>7}{'catas':>7}")
    for i, r in enumerate(results[:a.top]):
        print(f"{i+1:>3} {spec_label(r['spec']):<38}{r['regret']:>8.3f}{r['top1']:>7.2f}{r['cat']:>7.1f}")

    print("\n=== CURRENT hand-set configs, for comparison ===")
    for c, name in ((CURRENT_HGB, "EVAL model  (e1_analyze)"), (CURRENT_RF, "DEPLOY model (demo)")):
        r = next(x for x in results if x["spec"] == c)
        print(f"  rank {rank_of(c):>3}/{len(results)}  {name:<26} {spec_label(c):<38}"
              f" regret={r['regret']:.3f} top1={r['top1']:.2f}")

    # ---- robustness: re-run the top configs + the two current ones over 5 seeds ----
    print("\n=== robustness: top configs re-scored over 5 seeds (mean +/- sd of LOO regret) ===")
    seeds = (0, 1, 2, 3, 4)
    to_check = [r["spec"] for r in results[:4]] + [CURRENT_HGB, CURRENT_RF]
    seen = set(); rob = []
    for s in to_check:
        if s in seen:
            continue
        seen.add(s)
        rob.append(evaluate(s, X, y, df, groups, best, cost_aware, a.lam, seeds=seeds))
    rob.sort(key=lambda r: (r["regret"], -r["top1"]))
    for r in rob:
        tag = "  <- CURRENT eval" if r["spec"] == CURRENT_HGB else ("  <- CURRENT deploy" if r["spec"] == CURRENT_RF else "")
        print(f"  {spec_label(r['spec']):<38} regret={r['regret']:.3f} +/-{r['regret_sd']:.3f}"
              f"  top1={r['top1']:.2f}{tag}")

    # ---- is the best REALLY better than current? paired bootstrap on per-instance regret ----
    best_spec = rob[0]["spec"]
    if best_spec != CURRENT_HGB:
        rb = per_instance_regret(best_spec, X, y, df, groups, best, cost_aware, a.lam)
        rc = per_instance_regret(CURRENT_HGB, X, y, df, groups, best, cost_aware, a.lam)
        diff = rc - rb   # positive => best config has LOWER regret than current
        rng = np.random.default_rng(1)
        boots = [float(np.mean(diff[rng.integers(0, len(diff), len(diff))])) for _ in range(3000)]
        lo, hi = np.percentile(boots, [2.5, 97.5])
        sig = "SIGNIFICANT" if lo > 0 else "NOT significant (could be noise)"
        print(f"\n=== best ({spec_label(best_spec)}) vs CURRENT eval, paired bootstrap ===")
        print(f"  mean regret reduction = {np.mean(diff):+.3f}  95% CI [{lo:+.3f}, {hi:+.3f}]  -> {sig}")
    else:
        print("\n=== the CURRENT eval config is already the best on 5-seed mean. No tuning gain. ===")


if __name__ == "__main__":
    main()
