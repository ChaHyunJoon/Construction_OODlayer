#!/usr/bin/env python
"""
Is the trained forest ACTUALLY better than the DSPy-optimized LLM producer, or just numerically lower?

The report tables put forest reg=0.150 next to MIPROv2 reg=0.197/0.223, but a mean gap on n=20 is not
evidence. This script pairs the two producers INSTANCE BY INSTANCE (same 20 OOD events, same
cost-aware feasibility-lexicographic regret, lam=3.0) and bootstraps the paired difference.
(같은 인스턴스끼리 짝지어 차이를 부트스트랩 -> 평균 차이가 우연인지 아닌지 판정.)

Inputs
  sweep_lab/dspy_real_perinst_<model>.json   <- written by dspy_real_experiment.py
  forest LOO recomputed here from the same dump, so nothing is copied by hand.

Usage: python compare_dspy_vs_forest.py
"""
import os, sys, json
for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS"):
    os.environ[_v] = "1"                                  # tiny data에서 스레드 과구독 방지(스윕 때 겪은 함정)
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e1_analyze import load, featurize, cost_lex_key, MACRO_COST
from sklearn.ensemble import RandomForestRegressor, HistGradientBoostingRegressor
from sklearn.model_selection import LeaveOneGroupOut

HERE = os.path.dirname(os.path.abspath(__file__))
LAM = 3.0
# 데이터셋은 EVAL_DATA(또는 WM_DATASET) 환경변수로 교체 가능. 기본은 HS_ALL 고정 —
# 이 비교표의 기존 숫자가 그 파일에서 나왔기 때문(wm_datasets.py 참고).
import wm_datasets
DATA = wm_datasets.resolve(os.environ.get("EVAL_DATA"), default=wm_datasets.HS_ALL)
B = 10000                                                 # 부트스트랩 반복수
RNG = np.random.default_rng(0)

FORESTS = [
    ("forest RF 60 d6 (deployed)", lambda: RandomForestRegressor(
        n_estimators=60, max_depth=6, min_samples_leaf=2, random_state=0, n_jobs=1)),
    ("forest HGB d4 lr.08 (eval)", lambda: HistGradientBoostingRegressor(
        max_iter=300, max_depth=4, learning_rate=0.08, min_samples_leaf=3,
        l2_regularization=1.0, random_state=0)),
]


def forest_per_instance():
    """LOO로 forest를 돌려 인스턴스별 regret을 낸다(LLM arm과 동일한 채점식)."""
    df = load(DATA)
    df = df[df.fired == True].copy()
    full = [i for i, g in df.groupby("instance") if len(g) == 5]
    df = df[df.instance.isin(full)].reset_index(drop=True)

    best, scores = {}, {}
    for iid in df.instance.unique():
        g = df[df.instance == iid]
        scores[iid] = {int(m): float(c) - LAM * MACRO_COST[int(m)]
                       for m, c in zip(g.macro.values, g.closed.values)}
        b = max(g.itertuples(index=False),
                key=lambda r: cost_lex_key(r.complete, r.closed, r.makespan, r.macro, LAM))
        best[iid] = int(b.macro)

    X = featurize(df).values
    y = df.closed.astype(float).values - LAM * np.array([MACRO_COST[int(m)] for m in df.macro])
    groups = df.instance.values

    out = {}
    for name, make in FORESTS:
        per = {}
        for tr, te in LeaveOneGroupOut().split(X, y, groups):
            iid = groups[te][0]
            m = make(); m.fit(X[tr], y[tr])
            pred = m.predict(X[te])
            pick = int(df.iloc[te].macro.values[np.argsort(-pred)][0])
            cbm = scores[iid]; bc = cbm[best[iid]]
            span = max(bc - min(cbm.values()), 1e-9)
            per[str(iid)] = (bc - cbm[pick]) / span
        out[name] = per
    return out


def paired_bootstrap(a, b, iids):
    """a, b = {iid: regret}. 반환: 평균차(b-a)와 95% CI. 양수면 a(=forest)가 더 좋다는 뜻."""
    d = np.array([b[i] - a[i] for i in iids])
    boot = np.array([d[RNG.integers(0, len(d), len(d))].mean() for _ in range(B)])
    return d.mean(), np.percentile(boot, 2.5), np.percentile(boot, 97.5)


def main():
    forests = forest_per_instance()
    lines = []

    def emit(s=""):
        print(s)
        lines.append(s)

    emit("=" * 96)
    n_inst = len(next(iter(forests.values())))
    emit("PAIRED COMPARISON: trained forest vs REAL-DSPy LLM producer (n=%d, lam=%.1f, %d bootstraps)"
         % (n_inst, LAM, B))
    emit("positive delta = forest has LOWER regret = forest better;  CI excluding 0 = significant")
    emit("=" * 96)

    for model_tag in ("gpt4omini", "gpt4o"):
        p = os.path.join(HERE, "sweep_lab", "dspy_real_perinst_%s%s.json" % (model_tag, os.environ.get("EVAL_TAG", "")))
        if not os.path.exists(p):
            emit("\n(%s: no per-instance dump, skipped)" % model_tag)
            continue
        blob = json.load(open(p))
        emit("\n" + "-" * 96)
        emit("LLM = %s" % blob["model"])
        emit("  %-34s %8s | %-28s %9s %-22s" % ("arm", "reg", "vs forest", "delta", "95% CI"))
        for arm, per in blob["per_instance_regret"].items():
            iids = sorted(set(per) & set(next(iter(forests.values()))))
            arm_mean = float(np.mean([per[i] for i in iids]))
            row = "  %-34s %8.3f |" % (arm, arm_mean)
            for fname, fper in forests.items():
                d, lo, hi = paired_bootstrap(fper, per, iids)
                sig = "SIGNIFICANT" if lo > 0 else ("(n.s.)" if hi > 0 else "LLM BETTER")
                row += " %-28s %+9.3f [%+.3f, %+.3f] %s" % (fname, d, lo, hi, sig)
                emit(row)
                row = "  %-34s %8s |" % ("", "")
    emit("")
    emit("Reading: an arm whose CI includes 0 is NOT shown to be worse than the forest on this set --")
    emit("say 'not established', not 'the forest wins'. Small n is the usual cause -- report n explicitly.")
    open(os.path.join(HERE, "sweep_lab", "dspy_vs_forest_report%s.txt" % os.environ.get("EVAL_TAG", "")), "w",
         encoding="utf-8").write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
