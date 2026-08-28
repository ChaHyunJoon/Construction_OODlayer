#!/usr/bin/env python3
"""축 2(conformal)의 **실현가능성**을 재는 도구 — 설계서 §7 의 R3·R4.

이 파일은 라우터가 아니다. 아무것도 격상시키지 않는다. `predict_J` 의 out-of-fold 잔차로
유한표본 분위수 q 를 만들고, 팔별 구간 `[Ĵ ± q]` 의 top-1/top-2 겹침을 세는 것이 전부다.

🔴 왜 out-of-fold 인가: 전량 적합 모델은 자기가 본 instance 를 암기한다. 배포 레인이 마주치는
것은 **처음 보는 사건**이므로 그 상황의 잔차를 재야 한다. 전량 적합 Ĵ 는 여기서 **계산하지도
내보내지도 않는다** — 이 도구가 내는 잔차·q·격상은 전부 out-of-fold 하나에서만 온다.

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
# 이름 붙인다. 0.01~0.03 구간을 촘촘히 두는 이유: n=33 에서 k=ceil(34(1-a)) 가 n=33 을 넘는
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
            # 🔴 미적합 헤드는 NaN 이 아니라 `_b_fallback`/`_c_fallback`(0.0 초기값, 결코 NaN
            # 아님)을 낸다 — 아래 NaN 가드는 이 경로를 못 잡는다. fold 의 훈련셋이 완주/미완주
            # 어느 한쪽을 하나도 못 보면 그 헤드는 한 번도 fit 되지 않았는데, predict_J 는 그걸
            # 감추고 그럴듯한 유한값을 낸다 — "학습된 예측"과 "초기화값"이 구분 안 된다.
            missing = [name for name, fitted in
                       (("head_b", model._fitted_b), ("head_c", model._fitted_c)) if not fitted]
            assert not missing, (
                "OOF 폴드에서 미적합 헤드 폴백이 감지됐다: %s 가 이 폴드에서 fit 되지 않았다 "
                "(held-out instance=%s). predict_J 가 그럴듯한 유한값을 냈겠지만 그것은 학습되지 "
                "않은 헤드의 초기값(_b_fallback/_c_fallback=0.0)이다."
                % (missing, sorted(set(rows[i]["instance"] for i in te))))
            oof[te] = model.predict_J([rows[i] for i in te])
    if np.isnan(oof).any():
        raise RuntimeError("OOF 예측에 NaN 이 남았다 — 폴드가 모든 행을 덮지 않았다.")
    return oof


def require_objective_stamp(rows, where):
    """라벨 행이 이고 다니는 목적함수 도장을 **현행 `objective.json`** 과 대조한다.

    🔴 왜 필요한가 (2026-08-28 검토): `load_rows` 가 집행하는 것은 **어휘** 도장뿐이고,
    목적함수 도장은 `meta` 에 실려 산출물에 **찍히기만 하고 아무도 읽지 않았다**. 그런데
    `true_J` 는 J 를 **현행 config 로 다시 계산**하고 `main()` 은 산출물에 **현행 해시**를
    찍는다. 그래서 `C_fail` 을 고치고 구세대 라벨을 그대로 먹이면, 세대 혼합인 측정이
    **제대로 프로비넌스된 것처럼** 새 해시를 달고 나온다 — 보고 §6 이 "이 보고 전체를
    무효로 만든다" 고 적은 바로 그 실패다. 찍기 전에 읽는다.

    `action_registry.require_vocab_stamps` 와 같은 계약: 행 도장의 **집합**이 현행 하나와
    정확히 같아야 한다(균일 + 일치). 열이 아예 없으면 그것도 실패다.
    """
    cur = objective.objective_hash()
    missing = sum(1 for r in rows if r.get("objective_hash") is None)
    if missing:
        raise ValueError(
            "%s: 목적함수 도장('objective_hash')이 없는 행이 %d 개다 -- 구세대 라벨이다. "
            "현행은 %r." % (where, missing, cur))
    got = sorted(set(str(r["objective_hash"]) for r in rows))
    if got != [cur]:
        raise ValueError(
            "%s: 목적함수 도장 불일치 -- 파일 %s vs 현행 %r. `true_J` 는 현행 objective.json "
            "으로 J 를 다시 계산하므로, 이대로 재면 세대 혼합을 현행 도장으로 감춘 산출물이 "
            "나온다. 라벨을 다시 만들거나 objective.json 을 되돌려라." % (where, got, cur))


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
        # 🔴 "못 잰다"와 "쟀는데 크다"를 여기서 갈라야 한다. n_oth 가 작은 alpha 격자 끝에서는
        # per-instance q_i 가 전부 +inf 가 되고, 그러면 hits 가 전부 True 라 coverage_holdout
        # 이 트리비얼하게 1.0 이 되어 R4 PASS 로 읽힌다 — 측정이 아니라 측정 불능이 PASS 로
        # 위장한 것이다. per_instance_q 를 그대로 내보내고 n_q_infinite 로 그 사실을 남긴다.
        n_q_infinite = sum(1 for v in cov["per_instance_q"].values() if math.isinf(v))
        unmeasurable = n_q_infinite > 0
        # 정직판 격상: instance 마다 자기를 뺀 q_i 를 쓴다.
        honest = {}
        for iid in by_inst:
            s = np.sort(oof[[i for i, r in enumerate(rows) if r["instance"] == iid]])
            qi = cov["per_instance_q"][iid]
            honest[iid] = bool(len(s) < 2 or (s[1] - s[0]) <= 2.0 * qi)
        need = 1.0 - a - 0.05
        if need <= 0.0:
            r4 = "VACUOUS"          # 문지방이 구조적으로 항상 통과라 측정할 게 없다.
        elif unmeasurable:
            r4 = "UNMEASURABLE"     # coverage 가 +inf 구간을 상대로 잰 값이라 무의미하다.
        else:
            r4 = "PASS" if cov["coverage"] >= need else "FAIL"
        out["alphas"].append({
            "alpha": a,
            "k": math.ceil((len(res) + 1) * (1.0 - a)), "n_residuals": len(res),
            "q_pooled": q_pooled,
            "two_q_pooled": (math.inf if math.isinf(q_pooled) else 2.0 * q_pooled),
            "escalation_rate_pooled": esc_pooled["rate"],
            "escalated_instances": sorted(i for i, v in esc_pooled["per_instance"].items()
                                          if v["escalate"]),
            # 🔴 unmeasurable 이면 honest 도 "전부 격상"이 아니라 "못 쟀다"다 — 같은 이유로
            # None 처리하고 플래그로 구분한다(1.000 이라는 그럴듯한 숫자를 내보내지 않는다).
            "escalation_rate_honest": (None if unmeasurable
                                        else float(np.mean(list(honest.values())))),
            "honest_unmeasurable": unmeasurable,
            "per_instance_q": dict(cov["per_instance_q"]),
            "n_q_infinite": n_q_infinite,
            "coverage_holdout": (None if unmeasurable else cov["coverage"]),
            "coverage_required": need,
            "R4": r4,
        })
    return out


def _jsonable(o):
    if isinstance(o, float) and math.isinf(o):
        # 🔴 부호를 보존한다. -inf 를 "Infinity" 로 접으면 소비처에서 부등호가 뒤집힌다
        # (`gap <= 2q` 가 전부 True 가 되어 모든 escalate 가 False -> True 로 넘어간다).
        # 오늘의 산출물에 -inf 는 없지만, "없으니 접어도 된다" 는 도장을 찍는 논리와 같다.
        return "Infinity" if o > 0 else "-Infinity"
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
    # 🔴 도장을 찍기 전에 읽는다 -- meta 의 objective_hash 는 **현행 config** 에서 오지
    # 라벨에서 오지 않는다. 대조 없이 찍으면 세대 혼합이 프로비넌스로 위장한다.
    require_objective_stamp(rows, args.labels)
    res = measure(rows)
    res["meta"] = {k: meta[k] for k in ("path", "rows_after_fired_filter", "instances",
                                        "vocab", "objective_hash")}
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        # 🔴 allow_nan=False: NaN 이 dict 에 조용히 섞여 있으면 시끄럽게 죽어야 한다 — 뭉개서
        # 산출물에 리터럴 NaN 을 박아 넣으면 그건 JSON 표준도 아니고 다음 소비처가 못 읽는다.
        # +inf/-inf 는 이미 `_jsonable` 에서 "Infinity"/"-Infinity" 문자열로 앞서
        # 바뀌므로(부호 보존) 여기 안 걸린다.
        json.dump(_jsonable(res), f, indent=2, ensure_ascii=False, sort_keys=True,
                  allow_nan=False)
    print("wrote %s" % args.out)
    for a in res["alphas"]:
        cov_s = "n/a" if a["coverage_holdout"] is None else "%.3f" % a["coverage_holdout"]
        print("  alpha=%-5s k=%2d/%d q=%12s escalate=%s coverage=%-5s R4=%s n_q_inf=%d"
              % (a["alpha"], a["k"], a["n_residuals"],
                 ("inf" if math.isinf(a["q_pooled"]) else "%.3f" % a["q_pooled"]),
                 "%.3f" % a["escalation_rate_pooled"], cov_s, a["R4"], a["n_q_infinite"]))


if __name__ == "__main__":
    main()
