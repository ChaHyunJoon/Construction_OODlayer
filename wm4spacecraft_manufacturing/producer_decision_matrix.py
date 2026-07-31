#!/usr/bin/env python
"""
"So which producer do we actually deploy?" -- regret alone does NOT separate the DSPy-optimized LLM
from the trained forest at n=20 (see compare_dspy_vs_forest.py: every optimized arm's CI spans 0).
This script asks the question on the axes a deployment decision actually turns on.
(정확도 축에서 안 갈리니, 배포 결정에 실제로 쓰이는 축들로 다시 비교한다.)

Axes
  1. mean regret                 -- the accuracy axis that did NOT separate
  2. COMPLETION rate of picks    -- did the chosen macro finish the build? (feasibility, lexicographic top)
  3. CATASTROPHIC picks          -- chose a macro that fails to complete WHEN a completing one existed.
                                    This is the axis a safety reviewer cares about, not mean regret.
  4. worst-case regret           -- tail behaviour, not the average
  5. fragility                   -- spread between two runs that differ ONLY in demo choice
  6. cost / latency / determinism -- measured elsewhere (cost_eval_metrics_v2.json), quoted here

Writes sweep_lab/producer_decision_matrix.txt
"""
import os, sys, json
for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS"):
    os.environ[_v] = "1"
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e1_analyze import load, featurize, cost_lex_key, MACRO_COST, MACRO_NAME
from sklearn.ensemble import RandomForestRegressor, HistGradientBoostingRegressor
from sklearn.model_selection import LeaveOneGroupOut

HERE = os.path.dirname(os.path.abspath(__file__))
LAM = 3.0
# 데이터셋은 EVAL_DATA 환경변수로 교체 가능(n을 늘린 새 셋으로 그대로 재실행하기 위함).
DATA = os.environ.get("EVAL_DATA", os.path.join(HERE, "oracle/out/graded_hs_all.jsonl"))

FORESTS = [
    ("forest RF 60 d6 (deployed)", lambda: RandomForestRegressor(
        n_estimators=60, max_depth=6, min_samples_leaf=2, random_state=0, n_jobs=1)),
    ("forest HGB d4 lr.08 (eval)", lambda: HistGradientBoostingRegressor(
        max_iter=300, max_depth=4, learning_rate=0.08, min_samples_leaf=3,
        l2_regularization=1.0, random_state=0)),
]


def ground_truth():
    """인스턴스별: 매크로->(complete, 점수), 오라클 정답, 그리고 '완주 가능한 매크로가 있었는가'."""
    df = load(DATA)
    df = df[df.fired == True].copy()
    full = [i for i, g in df.groupby("instance") if len(g) == 5]
    df = df[df.instance.isin(full)].reset_index(drop=True)

    best, scores, complete, rescuable = {}, {}, {}, {}
    for iid in df.instance.unique():
        g = df[df.instance == iid]
        scores[iid] = {int(m): float(c) - LAM * MACRO_COST[int(m)]
                       for m, c in zip(g.macro.values, g.closed.values)}
        complete[iid] = {int(m): bool(c) for m, c in zip(g.macro.values, g.complete.values)}
        rescuable[iid] = any(complete[iid].values())         # 완주시키는 선택지가 존재했는가
        b = max(g.itertuples(index=False),
                key=lambda r: cost_lex_key(r.complete, r.closed, r.makespan, r.macro, LAM))
        best[iid] = int(b.macro)
    return df, best, scores, complete, rescuable


def forest_picks(df, best, scores):
    X = featurize(df).values
    y = df.closed.astype(float).values - LAM * np.array([MACRO_COST[int(m)] for m in df.macro])
    groups = df.instance.values
    out = {}
    for name, make in FORESTS:
        picks = {}
        for tr, te in LeaveOneGroupOut().split(X, y, groups):
            iid = groups[te][0]
            m = make(); m.fit(X[tr], y[tr])
            pred = m.predict(X[te])
            picks[str(iid)] = int(df.iloc[te].macro.values[np.argsort(-pred)][0])
        out[name] = picks
    return out


def axes(picks, best, scores, complete, rescuable):
    """한 producer의 선택 딕셔너리를 받아 축별 지표를 계산."""
    regs, comp, cata = [], [], 0
    for iid, mid in picks.items():
        key = iid if iid in scores else int(iid)
        cbm = scores[key]; bc = cbm[best[key]]
        span = max(bc - min(cbm.values()), 1e-9)
        regs.append((bc - cbm[mid]) / span)
        ok = complete[key].get(mid, False)
        comp.append(1.0 if ok else 0.0)
        if (not ok) and rescuable[key]:                      # 완주 가능했는데 못 하는 걸 골랐다 = catastrophic
            cata += 1
    regs = np.array(regs)
    return dict(reg=regs.mean(), worst=regs.max(), p90=float(np.percentile(regs, 90)),
                completion=float(np.mean(comp)), catastrophic=cata, n=len(regs))


def main():
    df, best, scores, complete, rescuable = ground_truth()
    scores = {str(k): v for k, v in scores.items()}
    best = {str(k): v for k, v in best.items()}
    complete = {str(k): v for k, v in complete.items()}
    rescuable = {str(k): v for k, v in rescuable.items()}

    rows = []
    for name, picks in forest_picks(df, best, scores).items():
        rows.append((name, axes(picks, best, scores, complete, rescuable)))

    for tag in ("gpt4o", "gpt4omini"):
        p = os.path.join(HERE, "sweep_lab", "dspy_real_perinst_%s%s.json" % (tag, os.environ.get("EVAL_TAG","")))
        if not os.path.exists(p):
            continue
        blob = json.load(open(p))
        for arm, picks in blob.get("per_instance_pick", {}).items():
            rows.append(("%s | %s" % (blob["model"], arm),
                         axes({str(k): v for k, v in picks.items()},
                              best, scores, complete, rescuable)))

    lines = []

    def emit(s=""):
        print(s); lines.append(s)

    n_resc = sum(1 for v in rescuable.values() if v)
    emit("=" * 104)
    emit("PRODUCER DECISION MATRIX  (n=%d instances, %d of them rescuable, lam=%.1f)" %
         (len(rescuable), n_resc, LAM))
    emit("catastrophic = picked a macro that does NOT complete the build although a completing macro existed")
    emit("=" * 104)
    emit("  %-46s %7s %7s %7s %11s %13s" %
         ("producer", "reg", "p90", "worst", "completion", "catastrophic"))
    for name, a in rows:
        emit("  %-46s %7.3f %7.3f %7.3f %10.0f%% %13d" %
             (name, a["reg"], a["p90"], a["worst"], 100 * a["completion"], a["catastrophic"]))

    # cost axis는 이미 측정해 둔 값을 인용(cost_eval_metrics_v2.json).
    try:
        c = json.load(open(os.path.join(HERE, "cost_eval_metrics_v2.json")))
        emit("")
        emit("cost axis (measured, cost_eval_metrics_v2.json):")
        emit("  surrogate  %.4f ms/call        LLM  %.3f s/call  ($%.6f)   planner sim  %.1f s median"
             % (c["T_surr_s"] * 1000, c["T_llm_s"], c["llm_usd_per_call"], c["T_sim"]["median"]))
        emit("  ratio LLM/surrogate per call = %.0fx" % (c["T_llm_s"] / c["T_surr_s"]))
    except Exception as e:
        emit("(cost metrics unavailable: %s)" % e)

    open(os.path.join(HERE, "sweep_lab", "producer_decision_matrix.txt"), "w",
         encoding="utf-8").write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
