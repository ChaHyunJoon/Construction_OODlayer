#!/usr/bin/env python
"""classify3_report.py -- the paper's THREE-class table: nominal / known-disturbance / OOD.

WHAT THIS ADDS OVER classify_report.py
======================================
`classify_report.py` measures two classes, because until now the dataset had no undisturbed
runs and the nominal decision function could not be fitted.  With `kind="none"` rows present,
the paper's actual structure becomes available:

    D_nom = 1  <=>  s_nom > eta_nom     "does not look like an undisturbed build"
    D_dis = 1  <=>  s_dis > eta_dis     "does not look like a known disturbance"

    (0,1) nominal   (1,0) known disturbance   (1,1) OOD   (0,0) ambiguous

Each score is fitted TWICE -- once on the nominal pool, once on the known-disturbance pool --
so every instance gets a pair (s_nom, s_dis).  That pair, not either number alone, is what the
three classes are read from.  This is the part that was written but never executed.

WHAT `residual_contrast` FINALLY GETS TO BE
===========================================
Its `reference='nominal'` path existed but could never run: `classify_report.py` passes
nominal_df=None, so what was actually measured was a model-vs-CONSTANT contrast, not the
two-model contrast the design argued for.  Here it gets the real reference.  Any number this
script prints for `residual_contrast` is therefore NOT comparable to the 0.726 in the 2-class
report -- that was the stand-in.

────────────────────────────────────────────────────────────────────────────────────────────
[한국어 요약]
2-class 표(classify_report.py)는 nominal 런이 없어서 결정함수를 하나만 쓸 수 있었다. kind="none"
행이 생기면서 논문의 원래 구조(결정함수 2개 -> 3분류)를 처음으로 돌릴 수 있다.

각 스코어를 **두 번** 맞춘다 -- nominal 풀에서 한 번, 아는-교란 풀에서 한 번. 그래야 instance
마다 (s_nom, s_dis) 쌍이 나오고, 3분류는 그 쌍에서 읽는다.

residual_contrast 는 여기서 처음으로 '진짜 2-모델 대비'가 된다. 2-class 표의 0.726 은 참조가
상수였던 약식판이므로 **여기 숫자와 직접 비교하면 안 된다**.

USAGE
    python classify3_report.py                          # oracle/out/openworld_nominal.jsonl
    python classify3_report.py --repeats=40
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

import numpy as np
import pandas as pd

import wm_datasets
from calibrate import (AMBIGUOUS, KNOWN, NOMINAL, OOD, QUANTILES, ConformalBand,
                       ThreeWayClassifier)
from scores import ResidualContrast, all_scores, instance_ids

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DATA = os.path.join(HERE, "oracle", "out", "openworld_nominal.jsonl")
OUTDIR = os.path.join(HERE, "artifacts_classifier")

FIT_FRAC, CAL_FRAC = 0.40, 0.30
CLASSES = (NOMINAL, KNOWN, OOD, AMBIGUOUS)


def load_all(path):
    """load_df 와 달리 fired 필터를 걸지 않는다 -- nominal 행은 fired=False 이기 때문."""
    rows = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    df = pd.DataFrame(rows)
    df["instance"] = df["instance"].astype(str)
    df["kind"] = df["kind"].astype(str)
    return df


def fit_on(score_cls, pool_df, nominal_df=None):
    """스코어 하나를 주어진 풀에 맞춘다.

    row_scope="noop" 를 강제하는 이유 -- nominal instance 는 1행, 교란 instance 는 5행이다.
    행 단위 집계 스코어를 그대로 두면 "5번 중 최대"와 "1번 중 최대"를 비교하게 되어, novelty 가
    아니라 표본 수를 재게 된다(실측: tree_variance/decision_margin 의 nominal 값이 전부 동일해져
    밴드가 퇴화했다). 모든 instance 가 반드시 갖는 NOOP 행 하나만 보면 비교가 성립한다.
    """
    try:
        s = score_cls(row_scope="noop")
    except TypeError:
        s = score_cls()          # 상태 기반 스코어(z_rms/mahalanobis)는 애초에 instance 당 1행
    if isinstance(s, ResidualContrast):
        # 여기가 ⚠️A 의 해소 지점: 참조가 상수가 아니라 진짜 M_nominal 이다.
        if nominal_df is not None and len(nominal_df):
            s = ResidualContrast(reference="nominal", row_scope="noop")
            return s.fit(pool_df, nominal_df=nominal_df)
        return s.fit(pool_df, nominal_df=None)
    return s.fit(pool_df)


def usable(nov_map):
    """NaN 이 섞인 스코어는 그 설정에서 **정의되지 않은** 것이므로 제외 대상이다."""
    return all(np.isfinite(v) for v in nov_map.values())


def split3(ids, rng, fit_frac=FIT_FRAC, cal_frac=CAL_FRAC):
    """한 풀을 fit / calibration / test 로 나눈다(논문도 train 과 calibration 을 분리한다)."""
    p = list(ids)
    rng.shuffle(p)
    n_fit = max(2, int(len(p) * fit_frac))
    n_cal = max(2, int(len(p) * cal_frac))
    fit, cal, test = p[:n_fit], p[n_fit:n_fit + n_cal], p[n_fit + n_cal:]
    if not test:
        test = cal[-1:]
    return fit, cal, test


def one_fold(df, held_kind, score_cls, rng):
    """한 폴드: held_kind 를 OOD 로 두고 3분류 성능을 잰다. 반환 {q: {truth: {pred: count}}}"""
    kind_of = {i: str(g.kind.iloc[0]) for i, g in df.groupby("instance")}
    nom_ids = [i for i, k in kind_of.items() if k == "none"]
    known_ids = [i for i, k in kind_of.items() if k not in ("none", held_kind)]
    ood_ids = [i for i, k in kind_of.items() if k == held_kind]
    if len(nom_ids) < 6 or len(known_ids) < 6:
        raise ValueError("pools too small (nominal=%d, known=%d)" % (len(nom_ids), len(known_ids)))

    nfit, ncal, ntest = split3(nom_ids, rng)
    kfit, kcal, ktest = split3(known_ids, rng)

    nom_fit_df = df[df.instance.isin(nfit)]
    known_fit_df = df[df.instance.isin(kfit)]

    # 두 결정함수. 각각 자기 풀에서 맞춘다.
    s_nom = fit_on(score_cls, nom_fit_df)                                   # "nominal 처럼 보이나"
    s_dis = fit_on(score_cls, known_fit_df, nominal_df=nom_fit_df)          # "아는 교란처럼 보이나"

    everything = ncal + ntest + kcal + ktest + ood_ids
    nov_nom = s_nom.novelty(df, everything)
    nov_dis = s_dis.novelty(df, everything)
    # 정의되지 않는 스코어(예: 후보가 1개뿐인 instance 의 decision_margin)를 0 이나 상수로
    # 메우면, 그 상수가 밴드를 퇴화시키고 "정확도 0%" 가 측정처럼 보인다. 아예 제외한다.
    if not (usable(nov_nom) and usable(nov_dis)):
        raise ValueError("undefined for single-macro (nominal) instances -- excluded")

    band_nom = ConformalBand.fit("nominal", [nov_nom[i] for i in ncal])
    band_dis = ConformalBand.fit("disturb", [nov_dis[i] for i in kcal])
    clf = ThreeWayClassifier(band_nom, band_dis)

    truth = {}
    for i in ntest:
        truth[i] = NOMINAL
    for i in ktest:
        truth[i] = KNOWN
    for i in ood_ids:
        truth[i] = OOD

    out = {}
    for q in QUANTILES:
        cm = {t: {p: 0 for p in CLASSES} for t in (NOMINAL, KNOWN, OOD)}
        for i, t in truth.items():
            p = clf.classify(nov_nom[i], nov_dis[i], q)
            cm[t][p] += 1
        out[q] = cm
    return out


def acc_from(cm, cls):
    """그 진짜 클래스의 정확도 = 맞게 분류된 비율."""
    tot = sum(cm[cls].values())
    return cm[cls][cls] / tot if tot else float("nan")


def overall(cm):
    tot = sum(sum(v.values()) for v in cm.values())
    hit = sum(cm[c][c] for c in cm)
    return hit / tot if tot else float("nan")


def mean_se(vals):
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
    path = pos[0] if pos else DEFAULT_DATA
    repeats = int(opt("repeats", "20"))

    if not os.path.exists(path):
        print("dataset not found: %s" % path)
        print("run:  python merge_nominal.py     (after the nominal shards finish)")
        return 1

    df = load_all(path)
    kinds = sorted(k for k in df.kind.unique() if k != "none")
    n_nom = df[df.kind == "none"].instance.nunique()

    print("=" * 104)
    print("THREE-CLASS DETECTION   nominal / known-disturbance / OOD    -- paper Fig. 2 + Table II")
    print("=" * 104)
    print("  data     : %s" % path)
    print("  %d rows | %d nominal instances | disturbance kinds=%s" % (len(df), n_nom, kinds))
    print("  protocol : leave-one-kind-out; each score fitted TWICE (nominal pool, known pool)")
    print("  %d repeats; mean +/- standard error" % repeats)
    print("  NOTE: residual_contrast here uses reference='nominal' (the real two-model contrast),")
    print("        so it is NOT comparable to the value in the 2-class report.")
    print()

    order = [s.name for s in all_scores()]
    factories = {s.name: (lambda s=s: type(s)()) for s in all_scores()}
    meta = {s.name: s for s in all_scores()}

    results = {n: {q: {c: [] for c in ("nominal", "known", "ood", "overall")}
                   for q in QUANTILES} for n in order}
    confusions = {n: {q: {t: {p: 0 for p in CLASSES} for t in (NOMINAL, KNOWN, OOD)}
                      for q in QUANTILES} for n in order}

    for name in order:
        for rep in range(repeats):
            rng = np.random.default_rng(2000 + rep)
            for held in kinds:
                try:
                    per_q = one_fold(df, held, factories[name], rng)
                except Exception as e:
                    if rep == 0 and held == kinds[0]:
                        print("  [warn] %s: %s" % (name, e))
                    continue
                for q, cm in per_q.items():
                    results[name][q]["nominal"].append(acc_from(cm, NOMINAL))
                    results[name][q]["known"].append(acc_from(cm, KNOWN))
                    results[name][q]["ood"].append(acc_from(cm, OOD))
                    results[name][q]["overall"].append(overall(cm))
                    for t in (NOMINAL, KNOWN, OOD):
                        for p in CLASSES:
                            confusions[name][q][t][p] += cm[t][p]

    for q in QUANTILES:
        print("-" * 104)
        print("  quantile %.0f%%" % (q * 100))
        print("-" * 104)
        print("  %-20s %-20s %-20s %-20s %s"
              % ("score", "nominal-acc", "known-acc", "OOD-acc", "overall"))
        for name in order:
            r = results[name][q]
            cells = []
            for c in ("nominal", "known", "ood"):
                m, s = mean_se(r[c])
                cells.append("%6.1f%% +/-%4.1f" % (100 * m, 100 * s))
            om, os_ = mean_se(r["overall"])
            print("  %-20s %-20s %-20s %-20s %6.1f%% +/-%4.1f"
                  % (name, cells[0], cells[1], cells[2], 100 * om, 100 * os_))
        print()

    # 가장 좋은 지표의 혼동행렬을 펼쳐 본다 -- 어디로 새는지가 평균보다 많은 것을 말해준다.
    best = max(order, key=lambda n: mean_se(results[n][0.95]["overall"])[0]
               if np.isfinite(mean_se(results[n][0.95]["overall"])[0]) else -1)
    print("=" * 104)
    print("CONFUSION MATRIX  --  %s @ 95%% quantile  (rows = truth, columns = predicted)" % best)
    print("=" * 104)
    cm = confusions[best][0.95]
    print("  %-22s %s" % ("", "  ".join("%-18s" % c for c in CLASSES)))
    for t in (NOMINAL, KNOWN, OOD):
        tot = max(sum(cm[t].values()), 1)
        print("  %-22s %s" % (t, "  ".join("%-18s" % ("%5d (%4.1f%%)" % (cm[t][p], 100 * cm[t][p] / tot))
                                           for p in CLASSES)))
    print()
    print("  The 'ambiguous' column is the (0,0) cell -- looks like BOTH a healthy build and a")
    print("  known disturbance. The paper does not name it; ours can reach it, so it is reported")
    print("  rather than folded into a neighbour.")

    os.makedirs(OUTDIR, exist_ok=True)
    dump = {n: {str(q): {c: mean_se(results[n][q][c])[0] for c in results[n][q]}
                for q in QUANTILES} for n in order}
    with open(os.path.join(OUTDIR, "three_class_summary.json"), "w") as fh:
        json.dump(dump, fh, indent=2)
    print("\n  summary -> artifacts_classifier/three_class_summary.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
