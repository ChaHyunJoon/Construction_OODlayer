#!/usr/bin/env python3
"""축 2(conformal)의 **실현가능성**을 재는 도구 — 설계서 §7 의 R3·R4.

이 파일은 라우터가 아니다. 아무것도 격상시키지 않는다. `predict_J` 의 out-of-fold 잔차로
유한표본 분위수 q 를 만들고, 팔별 구간 `[Ĵ ± q]` 의 top-1/top-2 겹침을 세는 것이 전부다.

🔴 왜 out-of-fold 인가: 전량 적합 모델은 자기가 본 instance 를 암기한다. 배포 레인이 마주치는
것은 **처음 보는 사건**이므로 그 상황의 잔차를 재야 한다. 전량 적합 Ĵ 는 보조 진단이다.

🔴 `predict_delta_J` 를 쓰지 않는다 (설계서 §3): 같은 instance 안에서 빼는 값은 팔에 무관한
상수라 `argmin` 을 안 바꾸고, 구간 폭도 안 바꾼다. conformal 은 `predict_J` 를 직접 쓴다.

🔴 `surrogate_rank` 의 1순위를 top-1 으로 쓰지 않는다 (설계서 §3): `dspy_service.py:490-497`
이 `choose(rule=SURRO_RULE)` 의 `pick` 을 0번에 **고정**하므로 그 1순위는 `argmin Ĵ` 가
아니다. 여기서는 `Ĵ` 를 직접 정렬한다.
"""
import argparse
import json
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "core"))

import objective                                              # noqa: E402
from eval_surrogate_v2 import group_by_instance, load_rows    # noqa: E402
from surrogate_v2 import SurrogateV2                          # noqa: E402

from sklearn.model_selection import LeaveOneGroupOut
from threadpoolctl import threadpool_limits

# 손잡이의 **도달 범위**를 재는 격자다. 0.5 를 넘는 값은 운용값이 아니다 — 보고에서 그렇게
# 이름 붙인다. 0.01~0.03 구간을 촘촘히 두는 이유: n=33 에서 k=ceil(34(1-a)) 가 34 를 넘는
# 경계(alpha < 1/34 ≈ 0.0294)가 그 안에 있고, 그 경계에서 q 가 유한 -> 무한으로 튄다.
ALPHA_GRID = (0.01, 0.02, 0.03, 0.05, 0.1, 0.2, 0.3, 0.5, 0.7, 0.9, 0.95, 0.99)


def conformal_quantile(residuals, alpha):
    """유한표본 보정 분위수. k = ceil((n+1)(1-alpha)) 번째로 작은 잔차.

    🔴 `k > n` 이면 `+inf` 를 돌려준다 — **"q 가 크다"가 아니라 "표본이 모자라 q 를 못
    잰다"** 이고, 그 둘은 다른 사실이다. 큰 수로 뭉개면 보고가 거짓말한다.
    """
    s = np.sort(np.asarray(residuals, dtype=float))
    n = len(s)
    if n == 0:
        raise ValueError("잔차가 비었다 — q 를 정의할 수 없다. 0 으로 폴백하지 않는다.")
    k = math.ceil((n + 1) * (1.0 - float(alpha)))
    return math.inf if k > n else float(s[k - 1])


def oof_predictions(rows):
    """leave-one-INSTANCE-out out-of-fold `Ĵ`. 길이 == len(rows)."""
    groups = np.array([r["instance"] for r in rows])
    idx = np.arange(len(rows))
    oof = np.full(len(rows), np.nan)
    # 스레드를 1로 묶는다 (eval_surrogate_v2.run_folds 와 같은 이유, 227배 실측).
    with threadpool_limits(limits=1):
        for tr, te in LeaveOneGroupOut().split(idx, groups=groups):
            model = SurrogateV2().fit([rows[i] for i in tr])
            oof[te] = model.predict_J([rows[i] for i in te])
    if np.isnan(oof).any():
        raise RuntimeError("OOF 예측에 NaN 이 남았다 — 폴드가 모든 행을 덮지 않았다.")
    return oof


def true_J(rows):
    """진실 J. `objective.J_row` 하나에서만 온다 — 재구현 금지."""
    return np.array([float(objective.J_row(r)) for r in rows], dtype=float)


def escalation(oof, rows, q):
    """instance 마다 top-1/top-2 구간이 겹치는가. 반환 dict 는 JSON 직렬화 가능."""
    per = {}
    for iid, g in group_by_instance(rows).items():
        ii = [i for i, r in enumerate(rows) if r["instance"] == iid]
        s = np.sort(np.asarray(oof, dtype=float)[ii])
        n_arms = len(s)
        if n_arms == 0:
            per[iid] = dict(n_arms=0, gap=None, escalate=True, reason="no_arms")
        elif n_arms == 1:
            # 🔴 확신이 아니라 정보 부재다 (설계서 §3).
            per[iid] = dict(n_arms=1, gap=None, escalate=True, reason="single_arm")
        else:
            gap = float(s[1] - s[0])
            esc = bool(gap <= 2.0 * q)      # q=inf 이면 항상 True
            per[iid] = dict(n_arms=n_arms, gap=gap, escalate=esc,
                            reason="ambiguous" if esc else "confident")
    n = len(per)
    rate = float(sum(1 for v in per.values() if v["escalate"]) / n) if n else 0.0
    return {"per_instance": per, "rate": rate, "n": n}


def coverage_leave_instance_out(res, rows, alpha):
    """정직한 coverage: instance 를 하나 빼고 만든 q 로 그 instance 를 덮는가.

    🔴 q 를 뽑은 표본으로 coverage 를 재면 정의상 1-alpha 라 순환논법이다.
    """
    res = np.asarray(res, dtype=float)
    hits, qs = [], {}
    for iid in group_by_instance(rows):
        own = [i for i, r in enumerate(rows) if r["instance"] == iid]
        oth = [i for i, r in enumerate(rows) if r["instance"] != iid]
        q = conformal_quantile(res[oth], alpha)
        qs[iid] = q
        hits.extend(bool(res[i] <= q) for i in own)
    return {"coverage": float(np.mean(hits)) if hits else 0.0, "per_instance_q": qs}


def measure(rows, alphas=ALPHA_GRID):
    """R3/R4 를 alpha 격자에 대해 잰다. JSON 직렬화 가능한 dict."""
    oof = oof_predictions(rows)
    jt = true_J(rows)
    res = np.abs(oof - jt)

    by_inst = group_by_instance(rows)
    gaps = {}
    for iid in by_inst:
        s = np.sort(oof[[i for i, r in enumerate(rows) if r["instance"] == iid]])
        gaps[iid] = float(s[1] - s[0]) if len(s) >= 2 else None

    out = {
        "n_rows": len(rows), "n_instances": len(by_inst),
        "residual_summary": {
            "min": float(res.min()), "max": float(res.max()),
            "median": float(np.median(res)),
            "quantiles": {str(p): float(np.quantile(res, p))
                          for p in (0.5, 0.7, 0.8, 0.9, 0.95)},
        },
        "gap_distribution": gaps,
        "gap_sorted": sorted(v for v in gaps.values() if v is not None),
        "per_instance_kind": {iid: g[0]["kind"] for iid, g in by_inst.items()},
        "per_instance_argmin_macro": {
            iid: int(rows[min((i for i, r in enumerate(rows) if r["instance"] == iid),
                              key=lambda i: oof[i])]["macro"])
            for iid in by_inst},
        "alphas": [],
    }
    for a in alphas:
        q_pooled = conformal_quantile(res, a)
        esc_pooled = escalation(oof, rows, q_pooled)
        cov = coverage_leave_instance_out(res, rows, a)
        # 정직판 격상: instance 마다 자기를 뺀 q_i 를 쓴다.
        honest = {}
        for iid in by_inst:
            s = np.sort(oof[[i for i, r in enumerate(rows) if r["instance"] == iid]])
            qi = cov["per_instance_q"][iid]
            honest[iid] = bool(len(s) < 2 or (s[1] - s[0]) <= 2.0 * qi)
        need = 1.0 - a - 0.05
        out["alphas"].append({
            "alpha": a,
            "k": math.ceil((len(res) + 1) * (1.0 - a)), "n_residuals": len(res),
            "q_pooled": q_pooled,
            "two_q_pooled": (math.inf if math.isinf(q_pooled) else 2.0 * q_pooled),
            "escalation_rate_pooled": esc_pooled["rate"],
            "escalated_instances": sorted(i for i, v in esc_pooled["per_instance"].items()
                                          if v["escalate"]),
            "escalation_rate_honest": float(np.mean(list(honest.values()))),
            "coverage_holdout": cov["coverage"],
            "coverage_required": need,
            "R4": "PASS" if cov["coverage"] >= need else "FAIL",
        })
    return out


def _jsonable(o):
    if isinstance(o, float) and math.isinf(o):
        return "Infinity"
    if isinstance(o, dict):
        return {k: _jsonable(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [_jsonable(v) for v in o]
    return o


def main():
    import wm_datasets
    ap = argparse.ArgumentParser()
    ap.add_argument("--labels", default=wm_datasets.abspath(wm_datasets.ORACLE_DATASET))
    ap.add_argument("--out", default=os.path.join(HERE, "out", "conformal_feasibility.json"))
    args = ap.parse_args()

    rows, meta = load_rows(args.labels)
    res = measure(rows)
    res["meta"] = {k: meta[k] for k in ("path", "rows_after_fired_filter", "instances",
                                        "vocab", "objective_hash")}
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(_jsonable(res), f, indent=2, ensure_ascii=False, sort_keys=True)
    print("wrote %s" % args.out)
    for a in res["alphas"]:
        print("  alpha=%-5s k=%2d/%d q=%12s escalate=%.3f coverage=%.3f R4=%s"
              % (a["alpha"], a["k"], a["n_residuals"],
                 ("inf" if math.isinf(a["q_pooled"]) else "%.3f" % a["q_pooled"]),
                 a["escalation_rate_pooled"], a["coverage_holdout"], a["R4"]))


if __name__ == "__main__":
    main()
