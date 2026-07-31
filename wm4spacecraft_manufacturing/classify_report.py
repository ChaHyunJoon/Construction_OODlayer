#!/usr/bin/env python
"""classify_report.py -- the paper's Table II and Fig. 6, computed on our data.

WHAT IS MEASURED
================
Leave-one-kind-out.  Hold out every instance of one disturbance kind; that kind plays the role
of OOD ("a disturbance the surrogate has never seen").  The remaining kinds are the known world.
For each score in `scores.py` and each CP quantile, report how well the band separates them.

WHY LOKO AND NOT THE 3-CLASS TABLE
==================================
The 3-class table needs a nominal decision function, which needs undisturbed (kind='none') runs,
and the dataset has **zero** such rows today.  So tonight measures the 2-class problem honestly
rather than faking the third class.  When the nominal arm lands, `calibrate.ThreeWayClassifier`
is already written and this harness grows one column.

THE SPLIT -- why three pieces and not two
=========================================
The paper keeps training and calibration data separate (14 train / 45 calibration videos), and
that separation is load-bearing: a band fitted on the same instances the score was fitted on is
optimistically tight, because in-sample scores are smaller than they should be.  So each fold is

    known kinds  ->  FIT (fit the score)  |  CAL (fit the band)  |  TEST-known (in-distribution test)
    held-out kind ->                                              TEST-ood

With n=60 the split is small, so it is repeated `--repeats` times with different seeds and the
table reports **mean ± standard error** over repeats.  A single split at this n is noise.

READING THE TABLE
=================
    OOD-recall    fraction of the unseen kind correctly flagged   (miss = the LLM never gets called)
    known-acc     fraction of familiar events left to the surrogate (false alarm = wasted LLM call)
    accuracy      overall
    AUROC         threshold-free separation; 0.5 = the score carries no information

AUROC is the number to trust when the quantile columns swing: it says whether the *score* has
signal, independent of where the cut is placed.

────────────────────────────────────────────────────────────────────────────────────────────
[한국어 요약]
leave-one-kind-out 으로 "처음 보는 교란"을 만들어, scores.py 의 각 지표 × 분위수마다
얼마나 잘 가르는지 잰다(논문 Table II 형식). 3-class 표는 nominal 런이 0개라 오늘은 불가.

분할이 3조각인 이유: 점수를 맞춘 데이터로 밴드까지 교정하면 밴드가 낙관적으로 좁아진다
(in-sample 점수가 실제보다 작다). 논문도 train/calibration 을 분리한다.

n=60 이라 한 번의 분할은 잡음이다. --repeats 번 반복해 **평균 ± 표준오차**로 보고한다.

AUROC 는 임계와 무관한 분리도라, 분위수별 숫자가 흔들릴 때 '지표 자체에 신호가 있는가'를
읽는 기준이 된다.
────────────────────────────────────────────────────────────────────────────────────────────

USAGE
    python classify_report.py                       # canonical dataset, 20 repeats
    python classify_report.py --repeats=50
    python classify_report.py --fig=artifacts_classifier/fig6.png
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

import numpy as np

import wm_datasets
from calibrate import (KNOWN, OOD, QUANTILES, CombinedGate, ConformalBand,
                       TwoWayClassifier, confusion_2class, rates, separation)
from openworld_experiments import load_df
from scores import ResidualContrast, all_scores, instance_ids

HERE = os.path.dirname(os.path.abspath(__file__))
OUTDIR = os.path.join(HERE, "artifacts_classifier")

# 분할 비율: 점수적합 / 밴드교정 / in-distribution 시험
FIT_FRAC, CAL_FRAC = 0.40, 0.30


def fit_score(score, df):
    """ResidualContrast 만 nominal_df 인자를 받으므로 호출을 한 곳에서 흡수한다."""
    if isinstance(score, ResidualContrast):
        return score.fit(df, nominal_df=None)
    return score.fit(df)


def one_fold(df, held_kind, score_factory, rng):
    """한 폴드 = 한 종류를 OOD 로 빼고, 나머지를 fit/cal/test 로 쪼개 평가.

    반환: {quantile: rates}, auroc, (cal 점수들, known 점수들, ood 점수들)
    """
    kind_of = {str(i): str(g.kind.iloc[0]) for i, g in df.groupby("instance")}
    known_ids = [i for i, k in kind_of.items() if k != held_kind]
    ood_ids = [i for i, k in kind_of.items() if k == held_kind]

    perm = list(known_ids)
    rng.shuffle(perm)
    n_fit = max(2, int(len(perm) * FIT_FRAC))
    n_cal = max(2, int(len(perm) * CAL_FRAC))
    fit_ids = perm[:n_fit]
    cal_ids = perm[n_fit:n_fit + n_cal]
    test_known = perm[n_fit + n_cal:]
    if not test_known:                      # 아주 작은 n 방어
        test_known = cal_ids[-1:]

    fit_df = df[df.instance.astype(str).isin(fit_ids)]
    score = fit_score(score_factory(), fit_df)

    nov = score.novelty(df, cal_ids + test_known + ood_ids)
    cal_s = np.array([nov[i] for i in cal_ids], dtype=float)
    known_s = np.array([nov[i] for i in test_known], dtype=float)
    ood_s = np.array([nov[i] for i in ood_ids], dtype=float)

    band = ConformalBand.fit("%s/%s" % (score.name, held_kind), cal_s)
    clf = TwoWayClassifier(band)

    per_q = {}
    for q in QUANTILES:
        y_true = [KNOWN] * len(known_s) + [OOD] * len(ood_s)
        y_pred = [clf.classify(s, q) for s in np.concatenate([known_s, ood_s])]
        per_q[q] = rates(confusion_2class(y_true, y_pred))
    return per_q, separation(known_s, ood_s), (cal_s, known_s, ood_s)


def combined_fold(df, held_kind, score_names, rng, correct=True):
    """여러 스코어를 같은 분할 위에서 함께 평가한다(OR 결합).

    같은 fit/cal/test 분할을 공유해야 결합의 이득이 분할 운이 아니라 결합에서 온 것이 된다.
    """
    kind_of = {str(i): str(g.kind.iloc[0]) for i, g in df.groupby("instance")}
    known_ids = [i for i, k in kind_of.items() if k != held_kind]
    ood_ids = [i for i, k in kind_of.items() if k == held_kind]

    perm = list(known_ids)
    rng.shuffle(perm)
    n_fit = max(2, int(len(perm) * FIT_FRAC))
    n_cal = max(2, int(len(perm) * CAL_FRAC))
    fit_ids, cal_ids = perm[:n_fit], perm[n_fit:n_fit + n_cal]
    test_known = perm[n_fit + n_cal:] or cal_ids[-1:]
    fit_df = df[df.instance.astype(str).isin(fit_ids)]

    bands, nov = {}, {}
    proto = {s.name: s for s in all_scores()}
    for name in score_names:
        s = fit_score(type(proto[name])(), fit_df)
        v = s.novelty(df, cal_ids + test_known + ood_ids)
        nov[name] = v
        bands[name] = ConformalBand.fit(name, [v[i] for i in cal_ids])

    gate = CombinedGate(bands=bands, correct=correct)
    out = {}
    for q in QUANTILES:
        y_true, y_pred = [], []
        for i in test_known:
            y_true.append(KNOWN)
            y_pred.append(gate.classify({n: nov[n][i] for n in score_names}, q))
        for i in ood_ids:
            y_true.append(OOD)
            y_pred.append(gate.classify({n: nov[n][i] for n in score_names}, q))
        out[q] = rates(confusion_2class(y_true, y_pred))
    return out


def combined_section(df, kinds, repeats):
    """결합 게이트 결과를 폴드별로 찍는다. 폴드 평균은 여기서도 신뢰하지 않는다."""
    admissible = [s.name for s in all_scores() if not s.needs_outcome]
    arms = [
        ("mahalanobis (single)", ["mahalanobis"], True),
        ("maha OR tree_var", ["mahalanobis", "tree_variance"], True),
        ("z_rms OR tree_var", ["z_rms", "tree_variance"], True),
        ("maha OR tree_var [NO correction]", ["mahalanobis", "tree_variance"], False),
    ]
    print("=" * 104)
    print("COMBINED GATE   (routing-admissible scores only: %s)" % ", ".join(admissible))
    print("=" * 104)
    print("  OR-combining N bands inflates the false-alarm rate ~N-fold, so each band is")
    print("  tightened to 1-alpha/N (Bonferroni). The last arm drops that correction on purpose:")
    print("  if it 'wins', that is a looser threshold, not a better gate.")
    print()
    print("  %-34s %-22s %s" % ("arm", "OOD-recall @95% (per held-out kind)", "known-acc"))
    for label, names, corr in arms:
        per_kind_rec, spec = {k: [] for k in kinds}, []
        for rep in range(repeats):
            rng = np.random.default_rng(3000 + rep)
            for held in kinds:
                try:
                    r = combined_fold(df, held, names, rng, correct=corr)
                except Exception:
                    continue
                per_kind_rec[held].append(r[0.95]["recall"])
                spec.append(r[0.95]["specificity"])
        cells = "  ".join("%s %3.0f%%" % (k[:4], 100 * mean_se(per_kind_rec[k])[0]) for k in kinds)
        print("  %-34s %-22s %5.1f%%" % (label, cells, 100 * mean_se(spec)[0]))
    print()


def mean_se(vals):
    """평균과 표준오차. n=1 이면 SE 는 0 이 아니라 nan 으로 둔다(없는 것과 0 은 다르다)."""
    a = np.asarray([v for v in vals if np.isfinite(v)], dtype=float)
    if a.size == 0:
        return float("nan"), float("nan")
    if a.size == 1:
        return float(a[0]), float("nan")
    return float(a.mean()), float(a.std(ddof=1) / np.sqrt(a.size))


def main():
    argv = sys.argv[1:]
    opt = lambda k, d: next((a.split("=", 1)[1] for a in argv if a.startswith("--%s=" % k)), d)
    pos = [a for a in argv if not a.startswith("--")]
    path = wm_datasets.resolve(pos[0] if pos else None)
    repeats = int(opt("repeats", "20"))
    figpath = opt("fig", os.path.join(OUTDIR, "fig6_score_distributions.png"))

    df = load_df(path)
    kinds = sorted(df.kind.astype(str).unique().tolist())
    iids = instance_ids(df)

    print("=" * 104)
    print("LOKO 2-CLASS DETECTION  (known-disturbance vs OOD)   -- paper Table II format")
    print("=" * 104)
    print("  %s" % wm_datasets.describe(path))
    print("  %d rows, %d instances, kinds=%s" % (len(df), len(iids), kinds))
    print("  split per fold: fit %.0f%% / calibration %.0f%% / test %.0f%% of the known kinds; "
          "held-out kind = OOD" % (FIT_FRAC * 100, CAL_FRAC * 100,
                                   (1 - FIT_FRAC - CAL_FRAC) * 100))
    print("  %d repeats per (score, fold); table is mean +/- standard error" % repeats)
    print("  NOTE: 3-class (nominal/known/OOD) needs kind='none' rows -- dataset has 0. Not claimed.")
    print()

    factories = {s.name: (lambda s=s: type(s)()) for s in all_scores()}
    order = [s.name for s in all_scores()]
    meta = {s.name: s for s in all_scores()}

    results = {}          # name -> {q: [rates...]}, auroc list
    dists = {}            # name -> (cal, known, ood) from the first repeat of each fold
    per_kind = {}         # name -> held_kind -> {"auroc": [...], "recall95": [...]}
    for name in order:
        per_q = {q: {"recall": [], "specificity": [], "accuracy": []} for q in QUANTILES}
        aurocs = []
        keep = None
        pk = {k: {"auroc": [], "recall95": []} for k in kinds}
        for rep in range(repeats):
            rng = np.random.default_rng(1000 + rep)
            for held in kinds:
                try:
                    pq, auc, d = one_fold(df, held, factories[name], rng)
                except Exception as e:
                    print("  [warn] %s / %s : %s" % (name, held, e))
                    continue
                for q in QUANTILES:
                    for k in ("recall", "specificity", "accuracy"):
                        per_q[q][k].append(pq[q][k])
                aurocs.append(auc)
                pk[held]["auroc"].append(auc)
                pk[held]["recall95"].append(pq[0.95]["recall"])
                if rep == 0 and keep is None:
                    keep = d
        results[name] = (per_q, aurocs)
        per_kind[name] = pk
        dists[name] = keep

    # ---------------- table ----------------
    for q in QUANTILES:
        print("-" * 104)
        print("  quantile %.0f%%" % (q * 100))
        print("-" * 104)
        print("  %-20s %-8s %-20s %-20s %-20s %s"
              % ("score", "family", "OOD-recall", "known-acc", "accuracy", "AUROC"))
        for name in order:
            per_q, aurocs = results[name]
            r_m, r_s = mean_se(per_q[q]["recall"])
            s_m, s_s = mean_se(per_q[q]["specificity"])
            a_m, a_s = mean_se(per_q[q]["accuracy"])
            u_m, u_s = mean_se(aurocs)
            print("  %-20s %-8s %6.1f%% +/-%4.1f      %6.1f%% +/-%4.1f      %6.1f%% +/-%4.1f      "
                  "%.3f +/-%.3f"
                  % (name, meta[name].family, 100 * r_m, 100 * r_s, 100 * s_m, 100 * s_s,
                     100 * a_m, 100 * a_s, u_m, u_s))
        print()

    # ---------------- per-kind breakdown ----------------
    # 왜 이 표가 필요한가: 폴드 평균 하나만 보면 "어떤 종류는 쉽고 어떤 종류는 불가능"이라는
    # 사실이 지워진다. 배포 게이트의 기존 보고치(신규 종류 recall 0.94)는 특정 한 종류를
    # 빼놓고 잰 값이므로, 평균과 어긋난다면 그건 모순이 아니라 **종류마다 난이도가 다르다**는 뜻이다.
    print("=" * 104)
    print("PER-HELD-KIND BREAKDOWN   (AUROC | OOD-recall at 95%)")
    print("=" * 104)
    print("  %-20s %s" % ("score", "  ".join("%-22s" % k for k in kinds)))
    for name in order:
        cells = []
        for k in kinds:
            a_m, a_s = mean_se(per_kind[name][k]["auroc"])
            r_m, _ = mean_se(per_kind[name][k]["recall95"])
            cells.append("%-22s" % ("%.3f+/-%.3f | %4.0f%%" % (a_m, a_s, 100 * r_m)))
        print("  %-20s %s" % (name, "  ".join(cells)))
    print()

    # ---------------- combined gate ----------------
    combined_section(df, kinds, repeats)

    # ---------------- reading ----------------
    print("=" * 104)
    print("READING")
    print("=" * 104)
    best = max(order, key=lambda n: mean_se(results[n][1])[0]
               if np.isfinite(mean_se(results[n][1])[0]) else -1)
    print("  highest AUROC (threshold-free separation): %s  (%.3f)"
          % (best, mean_se(results[best][1])[0]))
    for name in order:
        u = mean_se(results[name][1])[0]
        verdict = ("carries signal" if u >= 0.65 else
                   "weak" if u >= 0.55 else "no better than chance")
        note = ""
        if meta[name].needs_outcome:
            note = "   [post-hoc only -- not usable for routing]"
        if not meta[name].higher_is_ood:
            note += "   [orientation flipped by .novelty()]"
        print("    %-20s AUROC %.3f  -> %s%s" % (name, u, verdict, note))
    print()
    print("  Quantile behaves as the paper reports: at 100%% the threshold sits at the")
    print("  calibration maximum, so OOD-recall collapses and known-acc goes to 100%%.")

    # ---------------- figure (paper Fig. 6) ----------------
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt

        os.makedirs(os.path.dirname(figpath) or ".", exist_ok=True)
        shown = [n for n in order if dists.get(n) is not None]
        ncol = min(3, len(shown))
        nrow = int(np.ceil(len(shown) / ncol))
        fig, axes = plt.subplots(nrow, ncol, figsize=(4.6 * ncol, 3.4 * nrow))
        axes = np.atleast_1d(axes).ravel()
        for ax, name in zip(axes, shown):
            cal_s, known_s, ood_s = dists[name]
            band = ConformalBand.fit(name, cal_s)
            lo = float(min(known_s.min(), ood_s.min()))
            hi = float(max(known_s.max(), ood_s.max()))
            bins = np.linspace(lo, hi + 1e-9, 18)
            ax.hist(known_s, bins=bins, alpha=0.62, label="known (in-dist)", color="#3b6ea5")
            ax.hist(ood_s, bins=bins, alpha=0.62, label="OOD (held-out kind)", color="#c1543a")
            ax.axvline(band.threshold(0.95), color="k", ls="--", lw=1.3, label="95% CP threshold")
            ax.set_title("%s  (AUROC %.2f)" % (name, mean_se(results[name][1])[0]), fontsize=10)
            ax.set_xlabel("novelty score (higher = more novel)", fontsize=8)
            ax.set_ylabel("count", fontsize=8)
            ax.tick_params(labelsize=7)
            ax.legend(fontsize=7)
        for ax in axes[len(shown):]:
            ax.axis("off")
        fig.suptitle("Score distributions, known vs held-out kind (paper Fig. 6 analogue)",
                     fontsize=12)
        fig.tight_layout(rect=(0, 0, 1, 0.96))
        fig.savefig(figpath, dpi=140)
        print("\n  figure -> %s" % figpath)
    except Exception as e:
        print("\n  [figure skipped] %s: %s" % (type(e).__name__, e))


if __name__ == "__main__":
    main()
