#!/usr/bin/env python
"""
"What happens when more than one action is optimal?"

Two different questions hide in that one sentence, and they need different evidence:

  (Q1) The WORLD is ambiguous: two macros score within TIE_EPS of each other, so both are correct.
       -> Measurable from the oracle labels alone. Does each producer land on ONE of the tied-optimal
          actions (regret ~0), or does it wander off to a third, worse action?
  (Q2) The PRODUCER is ambiguous: the LLM itself wants to name several actions.
       -> NOT measurable from what we have: the dspy signature forces exactly one `macro` string, so
          a tie in the model's own belief is silently collapsed to an argmax. Answering that needs a
          NEW run with a signature that can return a ranked list + confidence.

This script answers Q1 from the existing per-instance dumps (no new LLM calls) and prints exactly
what Q2 would need, so the "do we have to re-run DSPy?" decision is made on evidence.
(Q1은 기존 덤프로 답한다. Q2는 시그니처가 매크로 1개만 받게 되어 있어 새로 돌려야 답할 수 있다.)

Usage: EVAL_DATA=oracle/out/graded_hs_n44.jsonl EVAL_TAG=_n44 python tie_behavior.py
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
TIE_EPS = 0.05                                   # master_experiment 와 동일 정의(상위2개가 span의 5% 이내)
DATA = os.environ.get("EVAL_DATA", os.path.join(HERE, "oracle/out/graded_hs_n44.jsonl"))
TAG = os.environ.get("EVAL_TAG", "_n44")

FORESTS = [
    ("forest RF 60 d6 (deployed)", lambda: RandomForestRegressor(
        n_estimators=60, max_depth=6, min_samples_leaf=2, random_state=0, n_jobs=1)),
    ("forest HGB d4 lr.08 (eval)", lambda: HistGradientBoostingRegressor(
        max_iter=300, max_depth=4, learning_rate=0.08, min_samples_leaf=3,
        l2_regularization=1.0, random_state=0)),
]


def ground_truth():
    df = load(DATA)
    df = df[df.fired == True].copy()
    full = [i for i, g in df.groupby("instance") if len(g) == 5]
    df = df[df.instance.isin(full)].reset_index(drop=True)

    best, scores, tied, complete = {}, {}, {}, {}
    for iid in df.instance.unique():
        g = df[df.instance == iid]
        cbm = {int(m): float(c) - LAM * MACRO_COST[int(m)] for m, c in zip(g.macro.values, g.closed.values)}
        scores[iid] = cbm
        complete[iid] = {int(m): bool(c) for m, c in zip(g.macro.values, g.complete.values)}
        b = max(g.itertuples(index=False),
                key=lambda r: cost_lex_key(r.complete, r.closed, r.makespan, r.macro, LAM))
        best[iid] = int(b.macro)
        bc = cbm[best[iid]]
        span = max(bc - min(cbm.values()), 1e-9)
        # 정답과 span의 TIE_EPS 이내인 매크로 전부 = "이것도 정답" 집합
        tied[iid] = sorted(m for m, v in cbm.items() if (bc - v) / span < TIE_EPS)
    return df, best, scores, tied, complete


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
            picks[iid] = int(df.iloc[te].macro.values[np.argsort(-m.predict(X[te]))][0])
        out[name] = picks
    return out


def main():
    df, best, scores, tied, complete = ground_truth()
    iids = list(scores)
    multi = [i for i in iids if len(tied[i]) > 1]

    lines = []

    def emit(s=""):
        print(s); lines.append(s)

    emit("=" * 100)
    emit("TIE BEHAVIOUR  (n=%d instances, TIE_EPS=%.0f%% of span, lam=%.1f)" % (len(iids), TIE_EPS * 100, LAM))
    emit("=" * 100)
    emit("instances with MORE THAN ONE optimal action: %d/%d (%.0f%%)"
         % (len(multi), len(iids), 100 * len(multi) / len(iids)))
    if multi:
        emit("")
        emit("  %-34s %-28s %s" % ("instance", "tied-optimal set", "spread of tied outcomes"))
        for i in sorted(multi):
            names = ", ".join(MACRO_NAME[m] for m in tied[i])
            vals = [scores[i][m] for m in tied[i]]
            emit("  %-34s %-28s closed-cost %.1f..%.1f" % (i[:34], names, min(vals), max(vals)))

    # 각 producer가 tie 인스턴스에서 "정답 집합 안"을 골랐는지
    producers = {}
    for name, picks in forest_picks(df, best, scores).items():
        producers[name] = picks
    p = os.path.join(HERE, "sweep_lab", "dspy_real_perinst_gpt4o%s.json" % TAG)
    if os.path.exists(p):
        blob = json.load(open(p))
        for arm, picks in blob.get("per_instance_pick", {}).items():
            producers["gpt-4o | " + arm] = {k: int(v) for k, v in picks.items()}

    emit("")
    emit("On the %d ambiguous instances -- did the producer land INSIDE the tied-optimal set?" % len(multi))
    emit("  %-46s %10s %10s   %s" % ("producer", "in-set", "regret", "picks when it missed"))
    for name, picks in producers.items():
        if not multi:
            break
        hit, regs, misses = 0, [], []
        for i in multi:
            if i not in picks:
                continue
            m = picks[i]
            cbm = scores[i]; bc = cbm[best[i]]
            span = max(bc - min(cbm.values()), 1e-9)
            r = (bc - cbm[m]) / span
            regs.append(r)
            if m in tied[i]:
                hit += 1
            else:
                misses.append("%s@%s" % (MACRO_NAME[m], i.split("_")[0]))
        n = len(regs) or 1
        emit("  %-46s %9.0f%% %10.3f   %s" % (name, 100 * hit / n, float(np.mean(regs)),
                                              ", ".join(misses[:4]) if misses else "-"))

    emit("")
    emit("-" * 100)
    emit("Q2 (does the LLM itself want to name several actions?) is NOT answerable from these dumps:")
    emit("  the dspy signature has a single `macro: str` output, so any internal tie is collapsed to")
    emit("  one string before we ever see it. Answering it needs a new run with a signature that")
    emit("  returns a RANKED LIST + per-action confidence, then measuring how often the top-2 are")
    emit("  within a margin and whether those cases coincide with the oracle ties above.")
    open(os.path.join(HERE, "sweep_lab", "tie_behavior%s.txt" % TAG), "w",
         encoding="utf-8").write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
