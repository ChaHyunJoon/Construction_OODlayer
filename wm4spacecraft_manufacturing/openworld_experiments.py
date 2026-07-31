#!/usr/bin/env python
"""
openworld_experiments.py -- 미지 OOD 대응 실험 3종을 한 파일로.

(구 ood_generalization.py + repr_compare.py + gated_frontier.py 를 통합. 셋 다 같은 데이터·같은
 regret 정의·같은 모델을 쓰면서 파일만 나뉘어 있었다.)

실행법
------
    python openworld_experiments.py loio  <data.jsonl>   # 아는 종류에서의 결정품질
    python openworld_experiments.py loko  <data.jsonl>   # 처음 보는 종류에서의 결정품질
    python openworld_experiments.py gate  <data.jsonl>   # 언제 진짜 플래너를 부를지 고르는 신호 비교
    python openworld_experiments.py all   <data.jsonl>   # 셋 다 + 공식 검증하니스 + 교정 재수출

    옵션:  --lam=3       행동비용 가중치(기본 3.0)
           --json=경로   결과를 JSON 으로 저장

용어 (줄임말 쓰지 않기)
-----------------------
* **LOIO = leave-one-instance-out = "한 상황 빼고 학습"**
  60개 상황 중 1개를 빼고 나머지로 학습한 뒤, 뺀 그 상황에서 옳은 대응을 골랐는지 채점한다.
  60번 반복. 재는 것: **이미 아는 종류의 사고**를 얼마나 잘 처리하는가.

* **LOKO = leave-one-kind-out = "한 종류 통째로 빼고 학습"**
  예: 배터리 사고를 하나도 안 보여주고 로봇고장·구역차단만으로 학습시킨 뒤, 배터리 사고에서 채점한다.
  재는 것: **처음 보는 종류의 사고**를 얼마나 잘 처리하는가. 이게 "미지 OOD" 주장의 정직한 시험이다.

* **regret(후회)** = 0 이면 최선의 대응을 골랐다는 뜻, 1 이면 최악을 골랐다는 뜻. 상황마다 0~1 로 정규화.

* **covariate novelty(입력 낯섦도)** = "지금 들어온 상황의 숫자들이 학습 때 보던 범위에서 얼마나
  벗어났는가". 벗어날수록 모델을 믿기 어려우니 진짜 플래너를 부르자는 신호.

* **disagreement(모델 내부 이견)** = 학습된 모델은 결정트리 여러 개의 모임(forest)이다. 그 나무들이
  서로 다른 대응을 지지하면 = 모델 스스로 확신이 없다는 뜻이니 진짜 플래너를 부르자는 신호.

* **oracle(오라클)** = 후보 대응을 전부 실제로 시뮬레이션해서 정답을 확인하는 것. 항상 맞지만 비싸다
  (한 번에 수십 초~분). 이 실험들의 목표는 "오라클을 얼마나 덜 부르면서 얼마나 정답에 가까운가"다.
"""
import collections
import json
import sys

# Windows 터미널의 기본 코드페이지(cp949)로 출력하면 한글 설명이 깨진다. 파이썬이 UTF-8 로 쓰도록 고정.
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

import numpy as np
import pandas as pd
from sklearn.model_selection import LeaveOneGroupOut

from e1_analyze import MACROS, load, _valid_list
from e1_analyze import featurize as featurize_legacy
from features_agnostic import (STATE_DESCRIPTORS, descriptors_from_row,
                               featurize_agnostic)
from surrogate_model import build_model
from verify import norm_regret, oracle_best_macro, paired_bootstrap

CAP, P_FLOOR = 8.0, 1e-4

REPRESENTATIONS = {
    "legacy":     featurize_legacy,
    "agnostic":   lambda d: featurize_agnostic(d, action_repr="onehot"),
    "agnostic-d": lambda d: featurize_agnostic(d, action_repr="descriptor"),
}


# ==========================================================================================
#  공통 헬퍼
# ==========================================================================================
def featurize_kind_only(df):
    """비교용 상대: '사고 종류 이름'만 알려주고 상황 숫자는 하나도 안 주는 모델."""
    X = pd.DataFrame(index=df.index)
    for k in sorted(df.kind.astype(str).unique()):
        X[f"kind_{k}"] = (df.kind.astype(str) == k).astype(float).values
    for m in MACROS:
        X[f"macro_{m}"] = (df.macro.astype(int) == m).astype(float).values
    return X


def valid_macros_of(g):
    """이 상황에서 실제로 실행 가능한 대응 목록(예: 구역 사고에 '로봇 교체'는 말이 안 됨)."""
    for v in g.valid_mask:
        vl = _valid_list(v)
        if vl:
            return set(int(x) for x in vl)
    return set(MACROS)


def pick_with_gate(pred_by_macro, valid):
    """예측값이 가장 높은 대응을 고르되 **실행 가능한 것 중에서만** 고른다(배포 경로와 동일)."""
    c = {m: v for m, v in pred_by_macro.items() if m in valid}
    return max(c or pred_by_macro, key=(c or pred_by_macro).get)


def fit_novelty(X, cap=CAP):
    """입력 낯섦도 계산기를 학습 데이터로 맞춘다(평균·표준편차·정상범위 점수들)."""
    mu, sd = X.mean(axis=0), X.std(axis=0) + 1e-9
    z = np.clip((X - mu) / sd, -cap, cap)
    return mu, sd, np.sort(np.sqrt(np.mean(z * z, axis=1)))


def novelty_of(mu, sd, x, cap=CAP):
    z = np.clip((np.asarray(x, float) - mu) / sd, -cap, cap)
    return float(np.sqrt(np.mean(z * z)))


def conformal_p(cal, s):
    """낯섦도 점수를 0~1 확률로 환산. 낮을수록 '처음 보는 것'."""
    n = len(cal)
    gt, eq = int(np.sum(cal > s)), int(np.sum(cal == s))
    return float(min(max((gt + 0.5 * (eq + 1)) / (n + 1), P_FLOOR), 1.0))


def load_df(path):
    df = load(path)
    return df[df.fired == True].copy()


# ==========================================================================================
#  실험 1: LOIO -- "아는 종류"에서의 결정품질 + 표현 비교
# ==========================================================================================
def loio_one(df, featurizer, lam):
    Xall = featurizer(df)
    cols, X = list(Xall.columns), Xall.values
    y, groups = df.closed.astype(float).values, df.instance.values
    by_inst = {i: g for i, g in df.groupby("instance")}

    regs, yt, yp = [], [], []
    for tr, te in LeaveOneGroupOut().split(X, y, groups):
        g = by_inst[groups[te][0]]
        model = build_model().fit(X[tr], y[tr])
        pred = model.predict(X[te])
        pbm = {int(m): float(p) for m, p in zip(df.iloc[te].macro.astype(int).values, pred)}
        regs.append(norm_regret(g, pick_with_gate(pbm, valid_macros_of(g)), lam))
        yp.extend(pred)
        yt.extend(df.iloc[te].closed.astype(float).values)

    yt, yp = np.asarray(yt), np.asarray(yp)
    ss_tot = float(np.sum((yt - yt.mean()) ** 2))
    r2 = 1 - float(np.sum((yt - yp) ** 2)) / ss_tot if ss_tot > 0 else float("nan")
    return {"regret": float(np.mean(regs)), "per_instance": [float(r) for r in regs],
            "r2": r2, "mae": float(np.mean(np.abs(yt - yp))), "n_features": len(cols)}


def run_loio(df, lam):
    print("\n" + "=" * 92)
    print("실험 1  LOIO = 한 상황씩 빼고 학습 -> 뺀 상황에서 채점  (아는 종류의 결정품질)")
    print("=" * 92)
    print(f"  {len(df)} rows, {df.instance.nunique()} instances, "
          f"kinds={sorted(df.kind.unique())}, lambda={lam}")
    print("  regret 0 = 매번 최선의 대응을 골랐다 / 1 = 매번 최악\n")

    res = {n: loio_one(df, f, lam) for n, f in REPRESENTATIONS.items()}
    res["kind-only"] = loio_one(df, featurize_kind_only, lam)

    print(f"  {'표현(feature 방식)':<22} {'#특징':>6} {'regret':>9} {'R2':>8} {'MAE':>8}")
    print("  " + "-" * 58)
    for n in ("legacy", "agnostic", "agnostic-d", "kind-only"):
        r = res[n]
        print(f"  {n:<22} {r['n_features']:>6} {r['regret']:>9.3f} {r['r2']:>8.3f} {r['mae']:>8.1f}")

    print("\n  -- 통계 비교 (양수 = 뒤에 적힌 쪽이 더 좋음, CI가 0을 포함하면 '차이 못 밝힘') --")
    for a, b in (("legacy", "agnostic"), ("legacy", "agnostic-d"), ("agnostic", "agnostic-d")):
        d, lo, hi = paired_bootstrap(res[a]["per_instance"], res[b]["per_instance"])
        sig = "유의함" if lo > 0 else ("반대로 유의" if hi < 0 else "차이 못 밝힘")
        print(f"    {a:<11} vs {b:<11} 차이={d:+.3f}  CI [{lo:+.3f},{hi:+.3f}]  -> {sig}")

    print("\n  -- 상황 숫자를 정말 읽고 있는가? (사고 '종류 이름'만 아는 모델과 비교) --")
    for n in ("legacy", "agnostic", "agnostic-d"):
        buys = res["kind-only"]["regret"] - res[n]["regret"]
        print(f"    [{'통과' if buys > 0 else '실패'}] {n:<11} 상태를 읽어서 얻은 이득 {buys:+.3f}")
    return res


# ==========================================================================================
#  실험 2: LOKO -- "처음 보는 종류"에서의 결정품질
# ==========================================================================================
def run_loko(df, lam, seed=0, quiet=False):
    by_inst = {i: g for i, g in df.groupby("instance")}
    best = {i: oracle_best_macro(g, lam) for i, g in by_inst.items()}
    kind_of = {i: str(g.kind.iloc[0]) for i, g in by_inst.items()}
    kinds = sorted(set(kind_of.values()))
    rng = np.random.default_rng(seed)
    out = {"kinds": kinds, "n_instances": len(by_inst), "lam": lam, "folds": []}

    for held in kinds:
        te = [i for i in by_inst if kind_of[i] == held]
        tr = [i for i in by_inst if kind_of[i] != held]
        if not tr or not te:
            continue
        tr_best, te_best = {best[i] for i in tr}, {best[i] for i in te}
        regime = ("action-supported" if te_best <= tr_best
                  else ("mixed" if te_best & tr_best else "action-novel"))
        tr_rows = df[df.instance.isin(tr)]
        fold = {"held_out": held, "n_test_inst": len(te), "n_train_inst": len(tr),
                "regime": regime, "models": {}, "baselines": {}}

        for name, featurizer in REPRESENTATIONS.items():
            Xall = featurizer(df)
            cols = list(Xall.columns)
            model = build_model().fit(Xall.loc[tr_rows.index, cols].values,
                                      tr_rows.closed.astype(float).values)
            regs = []
            for i in te:
                g = by_inst[i]
                pred = model.predict(Xall.loc[g.index, cols].values)
                pbm = {int(m): float(p) for m, p in zip(g.macro.astype(int).values, pred)}
                regs.append(norm_regret(g, pick_with_gate(pbm, valid_macros_of(g)), lam))
            fold["models"][name] = {"regret": float(np.mean(regs)),
                                    "per_instance": [float(r) for r in regs]}

        ga = collections.Counter([best[i] for i in tr]).most_common(1)[0][0]

        def score(ch):
            rs = [norm_regret(by_inst[i], ch(by_inst[i]), lam) for i in te]
            return float(np.mean(rs)), [float(x) for x in rs]

        for nm, ch in (("global_always", lambda g: ga if ga in valid_macros_of(g) else min(valid_macros_of(g))),
                       ("noop", lambda g: 0 if 0 in valid_macros_of(g) else min(valid_macros_of(g))),
                       ("random_valid", lambda g: int(rng.choice(sorted(valid_macros_of(g)))))):
            m, l = score(ch)
            fold["baselines"][nm] = {"regret": m, "per_instance": l}
        fold["baselines"]["oracle_fallback"] = {"regret": 0.0, "note": "후보 전부 시뮬 = 항상 정답, 대신 비쌈"}
        out["folds"].append(fold)

    if not quiet:
        print("\n" + "=" * 92)
        print("실험 2  LOKO = 한 종류 통째로 빼고 학습 -> 그 종류에서 채점  (처음 보는 종류)")
        print("=" * 92)
        print("  '미지 OOD 대응' 주장의 정직한 시험. 예: 배터리 사고를 한 번도 안 보여주고 채점.\n")
        hdr = (f"  {'뺀 종류':<11} {'전이가능성':<18} {'legacy':>8} {'agnostic':>9} {'agnos-d':>8} "
               f"{'고정대응':>9} {'무대응':>7} {'무작위':>7}")
        print(hdr); print("  " + "-" * (len(hdr) - 2))
        agg = collections.defaultdict(list)
        for f in out["folds"]:
            m, b = f["models"], f["baselines"]
            print(f"  {f['held_out']:<11} {f['regime']:<18} {m['legacy']['regret']:>8.3f} "
                  f"{m['agnostic']['regret']:>9.3f} {m['agnostic-d']['regret']:>8.3f} "
                  f"{b['global_always']['regret']:>9.3f} {b['noop']['regret']:>7.3f} "
                  f"{b['random_valid']['regret']:>7.3f}")
            for k in ("legacy", "agnostic", "agnostic-d"):
                agg[k] += m[k]["per_instance"]
            for k in ("global_always", "noop", "random_valid"):
                agg[k] += b[k]["per_instance"]
        print("  " + "-" * (len(hdr) - 2))
        print(f"  {'평균':<11} {'':<18} {np.mean(agg['legacy']):>8.3f} "
              f"{np.mean(agg['agnostic']):>9.3f} {np.mean(agg['agnostic-d']):>8.3f} "
              f"{np.mean(agg['global_always']):>9.3f} {np.mean(agg['noop']):>7.3f} "
              f"{np.mean(agg['random_valid']):>7.3f}")
        print("\n  -- 통계 비교 (양수 = agnostic 이 더 좋음) --")
        for rep in ("agnostic", "agnostic-d"):
            d, lo, hi = paired_bootstrap(agg["legacy"], agg[rep])
            sig = "유의함" if lo > 0 else ("반대로 유의" if hi < 0 else "차이 못 밝힘")
            print(f"    legacy vs {rep:<11} 차이={d:+.3f} CI [{lo:+.3f},{hi:+.3f}] -> {sig}")
        print("\n  * '전이가능성' 열: action-supported = 정답 대응을 학습셋에서도 본 적 있음(전이 가능).")
        print("    action-novel = 정답 대응 자체를 한 번도 못 봄 -> 어떤 방법으로도 불가, 오라클만이 답.")
        out["_agg"] = {k: [float(x) for x in v] for k, v in agg.items()}
    return out


# ==========================================================================================
#  실험 3: 게이트 -- "언제 비싼 진짜 플래너를 부를 것인가"
# ==========================================================================================
def collect_gate(df, lam):
    by_inst = {i: g for i, g in df.groupby("instance")}
    kind_of = {i: str(g.kind.iloc[0]) for i, g in by_inst.items()}
    Xall = featurize_agnostic(df, action_repr="onehot")
    cols = list(Xall.columns)
    recs = []
    for held in sorted(set(kind_of.values())):
        te = [i for i in by_inst if kind_of[i] == held]
        tr = [i for i in by_inst if kind_of[i] != held]
        if not tr or not te:
            continue
        tr_rows = df[df.instance.isin(tr)]
        model = build_model().fit(Xall.loc[tr_rows.index, cols].values,
                                  tr_rows.closed.astype(float).values)
        # 낯섦도 계산기는 **학습 종류로만** 맞춘다(뺀 종류의 통계가 새어들면 부정행위).
        D = np.asarray([[descriptors_from_row(by_inst[i].iloc[0])[k] for k in STATE_DESCRIPTORS]
                        for i in tr], float)
        mu, sd, cal = fit_novelty(D)

        for i in te:
            g = by_inst[i]
            pred = model.predict(Xall.loc[g.index, cols].values)
            pbm = {int(m): float(p) for m, p in zip(g.macro.astype(int).values, pred)}
            valid = valid_macros_of(g)
            r_sur = norm_regret(g, pick_with_gate(pbm, valid), lam)

            d = descriptors_from_row(g.iloc[0])
            p = conformal_p(cal, novelty_of(mu, sd, [d[k] for k in STATE_DESCRIPTORS]))

            vv = sorted((pbm[m] for m in valid if m in pbm), reverse=True)
            spread = (vv[0] - vv[-1]) if len(vv) >= 2 else 0.0
            margin = ((vv[0] - vv[1]) / spread if spread > 1e-9 else 0.0) if len(vv) >= 2 else 1.0

            try:
                Xg, mg = Xall.loc[g.index, cols].values, g.macro.astype(int).values
                votes = collections.Counter()
                for est in model.estimators_:
                    pe = est.predict(Xg)
                    cand = {int(m): float(v) for m, v in zip(mg, pe) if int(m) in valid}
                    if cand:
                        votes[max(cand, key=cand.get)] += 1
                agree = votes.most_common(1)[0][1] / sum(votes.values()) if votes else 1.0
            except Exception:
                agree = 1.0

            recs.append({"inst": str(i), "held_out": held, "regret_surrogate": float(r_sur),
                         "p": p, "margin": float(margin), "agree": float(agree),
                         "n_valid": len(valid)})
    return recs


def run_gate(df, lam, seed=0):
    recs = collect_gate(df, lam)
    n = len(recs)
    rs = np.array([r["regret_surrogate"] for r in recs])
    rng = np.random.default_rng(seed)

    print("\n" + "=" * 92)
    print("실험 3  게이트 = '언제 비싼 진짜 플래너를 불러 확인할 것인가'")
    print("=" * 92)
    print("  학습된 모델은 공짜지만 처음 보는 상황에선 틀릴 수 있고, 진짜 플래너는 항상 맞지만 비싸다.")
    print("  그래서 '의심스러울 때만' 플래너를 부르고 싶다. 무엇을 보고 의심할 것인가?\n")
    print("    입력낯섦도  = 지금 상황의 숫자들이 학습 때 보던 범위를 벗어났는가")
    print("    결정마진    = 1등 대응과 2등 대응의 점수 차이가 아슬아슬한가")
    print("    모델내부이견 = forest 안의 나무들이 서로 다른 대응을 지지하는가")
    print("    무작위      = 대조군. 같은 개수를 아무렇게나 골라 플래너로 넘김\n")
    print("  ** 핵심: 많이 부르면 regret 은 당연히 내려간다. 그래서 '부르는 횟수를 똑같이 맞춰'")
    print("     비교해야 신호가 진짜 정보를 담고 있는지 알 수 있다. --\n")

    sig = {"입력낯섦도": np.array([r["p"] for r in recs]),
           "결정마진":   np.array([r["margin"] for r in recs]),
           "모델내부이견": np.array([r["agree"] for r in recs])}

    print(f"  {'플래너호출':>10} {'무작위':>9} {'입력낯섦도':>12} {'결정마진':>10} {'모델내부이견':>13}   {'최선':>12}")
    print("  " + "-" * 76)
    rows = []
    for frac in (0.1, 0.2, 0.3, 0.4, 0.5):
        k = int(round(frac * n))
        rr = []
        for _ in range(200):
            idx = set(rng.choice(n, size=k, replace=False).tolist()) if k else set()
            rr.append(np.mean([0.0 if j in idx else rs[j] for j in range(n)]))
        row = {"budget": frac, "k": k, "무작위": float(np.mean(rr))}
        for nm, s in sig.items():
            idx = set(np.argsort(s)[:k].tolist())
            row[nm] = float(np.mean([0.0 if j in idx else rs[j] for j in range(n)]))
        win = min(row, key=lambda x: row[x] if x in ("무작위", *sig) else 9e9)
        rows.append(row)
        print(f"  {100*frac:>9.0f}% {row['무작위']:>9.3f} {row['입력낯섦도']:>12.3f} "
              f"{row['결정마진']:>10.3f} {row['모델내부이견']:>13.3f}   {win:>12}")

    print("\n  -- 판정 (무작위 대조군을 이겼는가) --")
    for nm in sig:
        b = sum(1 for r in rows if r[nm] < r["무작위"] - 1e-9)
        print(f"    {nm:<12} {b}/{len(rows)} 예산에서 무작위보다 좋음")

    ps, corr = np.array([r["p"] for r in recs]), float("nan")
    if ps.std() > 1e-12 and rs.std() > 1e-12:
        corr = float(np.corrcoef(ps, rs)[0, 1])
    hi, lo_ = rs[ps < np.median(ps)], rs[ps >= np.median(ps)]
    print(f"\n  -- 입력낯섦도가 정말 '틀릴 상황'을 짚는가 --")
    print(f"    상관계수 = {corr:+.3f}  (음수여야 유용: 낯설수록 모델이 틀린다는 뜻)")
    if len(hi) and len(lo_):
        print(f"    더 낯선 절반의 regret = {hi.mean():.3f} / 덜 낯선 절반 = {lo_.mean():.3f}"
              f"  -> 분리도 {hi.mean()-lo_.mean():+.3f} (양수라야 올바른 방향)")
    return {"n": n, "corr_p_regret": corr, "rows": rows, "records": recs}


# ==========================================================================================
def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    cmd = args[0] if args else "all"
    path = args[1] if len(args) > 1 else "oracle/out/openworld_merged.jsonl"
    lam = next((float(a.split("=")[1]) for a in sys.argv[1:] if a.startswith("--lam=")), 3.0)
    jout = next((a.split("=")[1] for a in sys.argv[1:] if a.startswith("--json=")), None)

    if cmd not in ("loio", "loko", "gate", "all"):
        print(__doc__)
        sys.exit(1)

    df = load_df(path)
    print(f"[data] {path}: {len(df)} rows, {df.instance.nunique()} instances, "
          f"kinds={sorted(df.kind.unique())}")
    out = {"data": path, "n_instances": int(df.instance.nunique()), "lam": lam}

    if cmd in ("loio", "all"):
        out["loio"] = run_loio(df, lam)
    if cmd in ("loko", "all"):
        out["loko"] = run_loko(df, lam)
    if cmd in ("gate", "all"):
        out["gate"] = run_gate(df, lam)

    if jout:
        json.dump(out, open(jout, "w"), indent=2, default=float)
        print(f"\n[saved] {jout}")


if __name__ == "__main__":
    main()
