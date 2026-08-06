#!/usr/bin/env python
"""value_two_layer.py -- 값(Q)을 **두 층으로 분해**해서 배우는 서로게이트.

왜 이 파일이 필요한가
--------------------
현재 라벨 `q_cost` 는 유한벌점 SSP 비용이라 **이봉(bimodal)** 이다:

    완주   -> makespan            (~20)
    미완주 -> 10000 + 100*unclosed + 1e-3*makespan   (~26000)

한 개의 회귀로 이걸 맞히면, 모델이 사실상 "완주하냐 마냐"를 맞히는 분류기로 붕괴하고
완주한 팔들 **사이의** makespan 차이(= 실제로 결정을 가르는 신호)는 잔차 잡음에 묻힌다.
TAMP 학습 문헌의 표준 처방도 같다 -- 실행가능성(분류)과 비용(회귀)을 **분리된 헤드**로 둔다
(neural feasibility checking / plan feasibility prediction 계열).

그래서 세 개의 헤드로 나눈다:

    p̂      = P(complete | φ, a)                 <- 분류 성격
    m̂_c    = E[makespan | 완주, φ, a]            <- 완주했을 때 얼마나 빠른가
    û_f    = E[unclosed | 미완주, φ, a]          <- 실패했을 때 얼마나 망했나
    (m̂_f  = E[makespan | 미완주] 는 1e-3 가중이라 상수 근사로 충분)

그리고 **비용 정의 그대로** 다시 합친다:

    Q̂ = p̂·m̂_c + (1-p̂)·(COST_FAIL + COST_UNCLOSED·û_f + COST_TIE_EPS·m̂_f)

핵심 규율 두 가지
----------------
1. **비용 상수를 여기서 다시 정의하지 않는다.** overnight_mdp 에서 import 한다.
   (gen_oracle_mc.jl:146 과 overnight_mdp.py:35 두 곳이 이미 같아야 하는 상태다.
    세 번째 사본을 만들면 언젠가 반드시 갈라진다.)
2. **모델을 태우기 전에 항등식부터 검사한다.** 위 재조합식은 조건부 평균을 쓰면
   rollout 평균 비용과 *수학적으로 정확히* 같다. 안 맞으면 그건 모델 문제가 아니라
   집계 배선이 틀린 것이므로, `check_identity()` 가 먼저 잡아준다.

문법 참고(초보자용)
  · dict.setdefault(k, []).append(x) -- 키가 없으면 빈 리스트를 만들고 거기에 붙인다.
  · np.isfinite(x) -- NaN/Inf 를 걸러내는 표준 관용구.
  · 조건부 평균에서 표본이 0개면 NaN 이 되는데, 그 항은 가중치(p 또는 1-p)가 0 이므로
    0.0 으로 치환해도 값이 바뀌지 않는다(0*NaN 를 피하려는 것).

실행
    python value_two_layer.py                      # 기본 글롭(ep2_*)으로 항등식+결정동일성 검사
    python value_two_layer.py --glob 'oracle/out/hz_v1/*.jsonl'
"""
import os, sys, json, glob, math, argparse
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    sys.stdout.reconfigure(encoding="utf-8")     # 함정 22: Windows cp949 로 나가면 리포트가 깨진다
except Exception:
    pass

import numpy as np

# 비용 정의는 **한 곳에서만** 가져온다 (사본 금지).
from overnight_mdp import scalar_cost, COST_FAIL, COST_UNCLOSED, COST_TIE_EPS
from surrogate_model import build_model, SURROGATE_PARAMS

HERE = os.path.dirname(os.path.abspath(__file__))


# ==========================================================================================
#  1. 분해 -- rollout 원시행 -> (instance, macro) 당 세 조건부 통계
# ==========================================================================================
def decompose_rollouts(rows):
    """rollout 행들을 (instance, macro) 로 묶어 조건부 통계를 뽑는다.

    반환하는 행은 aggregate() 가 주는 것과 **같은 키(q_cost/p_complete/...)** 를 갖고,
    거기에 2층 타깃 4개(mk_c / unc_f / mk_f / p_complete)를 더한 것이다.
    """
    rows = [r for r in rows if r.get("macro") is not None and r.get("fired")]
    groups = {}
    for r in rows:
        groups.setdefault((r["instance"], int(r["macro"])), []).append(r)

    out = []
    for (inst, m), g in sorted(groups.items()):
        costs = np.array([scalar_cost(r) for r in g], float)
        comp = np.array([bool(r.get("complete")) for r in g], bool)
        mk = np.array([float(r.get("makespan", np.nan)) for r in g], float)
        unc = np.array([float(r.get("total", 0)) - float(r.get("closed", 0)) for r in g], float)

        n = len(g)
        p = float(comp.mean())
        # 조건부 평균. 표본이 없으면 NaN 대신 0.0 -- 그 항의 가중치가 0 이라 값에 영향 없다.
        mk_c = float(np.nanmean(mk[comp])) if comp.any() else 0.0
        mk_f = float(np.nanmean(mk[~comp])) if (~comp).any() else 0.0
        unc_f = float(np.mean(unc[~comp])) if (~comp).any() else 0.0
        # makespan 이 NaN(무한루프 등)인 완주 판이 섞이면 nanmean 이 NaN 을 낼 수 있다 -> 벌점값으로
        if not math.isfinite(mk_c):
            mk_c = COST_FAIL
        if not math.isfinite(mk_f):
            mk_f = 0.0

        base = dict(g[0])                      # 결정시점 상태 스냅샷은 rollout 간 동일
        base.update({
            "instance": inst, "macro": m, "n_rollout": n,
            "q_cost": float(costs.mean()),
            "q_se": float(costs.std(ddof=1) / math.sqrt(n)) if n > 1 else float("nan"),
            "p_complete": p, "mk_c": mk_c, "mk_f": mk_f, "unc_f": unc_f,
            "closed": float(np.mean([float(r.get("closed", 0)) for r in g])),
        })
        base["q_recomposed"] = recompose(p, mk_c, unc_f, mk_f)
        out.append(base)
    return out


def recompose(p, mk_c, unc_f, mk_f):
    """세 조건부 통계를 SSP 비용 정의 그대로 다시 합친다. **정의를 여기 새로 쓰지 않는다.**"""
    fail_cost = COST_FAIL + COST_UNCLOSED * unc_f + COST_TIE_EPS * mk_f
    return p * mk_c + (1.0 - p) * fail_cost


def check_identity(agg, tol=1e-6):
    """재조합 값이 rollout 평균 비용과 같은지 -- 모델 이전에 배선을 검사한다.

    수학적으로 정확히 같아야 한다. 틀리면 집계/필드 해석이 잘못된 것이므로 여기서 멈춘다.
    """
    bad = []
    for r in agg:
        a, b = float(r["q_cost"]), float(r["q_recomposed"])
        if not (math.isfinite(a) and math.isfinite(b)):
            bad.append((r["instance"], r["macro"], a, b, "non-finite"))
            continue
        denom = max(1.0, abs(a))
        if abs(a - b) / denom > tol:
            bad.append((r["instance"], r["macro"], a, b, f"rel={abs(a-b)/denom:.2e}"))
    print(f"  항등식 검사: {len(agg) - len(bad)}/{len(agg)} 셀 일치 (tol={tol:g})")
    for x in bad[:10]:
        print(f"    !! {x[0]} macro={x[1]}  q={x[2]:.4f} vs recomposed={x[3]:.4f}  {x[4]}")
    if len(bad) > 10:
        print(f"    ... 외 {len(bad)-10}개")
    return len(bad) == 0


# ==========================================================================================
#  2. 2층 모델
# ==========================================================================================
class TwoLayerValue:
    """p(complete) / makespan|완주 / unclosed|미완주 세 헤드를 따로 배우고 비용식으로 합친다.

    모델 클래스는 배포되는 것과 같은 RandomForest 로 고정한다(surrogate_model.build_model).
    평가와 배포가 다른 추정기를 쓰면 발표 숫자가 실제 시스템을 설명하지 못한다.
    """

    def __init__(self, **overrides):
        self.h_p = build_model(**overrides)      # p̂ : [0,1] 로 클립해서 쓰는 회귀 헤드
        self.h_mk_c = build_model(**overrides)   # m̂_c
        self.h_unc_f = build_model(**overrides)  # û_f
        self.mk_f_const = 0.0                    # 1e-3 가중이라 상수로 충분(과적합 방지)
        self._p_const = None                     # 학습표본이 한쪽으로 쏠렸을 때의 폴백
        self._mk_c_const = None
        self._unc_f_const = None

    def fit(self, X, agg):
        y_p = np.array([r["p_complete"] for r in agg], float)
        y_mkc = np.array([r["mk_c"] for r in agg], float)
        y_uncf = np.array([r["unc_f"] for r in agg], float)
        Xv = np.asarray(X, float)

        self.h_p.fit(Xv, y_p)

        # 조건부 헤드는 **그 조건이 실제로 관측된 행에서만** 학습한다.
        # (완주가 한 번도 없었던 셀의 mk_c=0.0 은 데이터가 아니라 자리표시자다. 넣으면 오염된다.)
        m_c = np.array([r["p_complete"] > 0 for r in agg], bool)
        m_f = np.array([r["p_complete"] < 1 for r in agg], bool)
        if m_c.sum() >= 3:
            self.h_mk_c.fit(Xv[m_c], y_mkc[m_c])
        else:
            self._mk_c_const = float(y_mkc[m_c].mean()) if m_c.any() else COST_FAIL
        if m_f.sum() >= 3:
            self.h_unc_f.fit(Xv[m_f], y_uncf[m_f])
        else:
            self._unc_f_const = float(y_uncf[m_f].mean()) if m_f.any() else 0.0
        mkf = np.array([r["mk_f"] for r in agg], float)[m_f]
        self.mk_f_const = float(mkf.mean()) if mkf.size else 0.0
        return self

    def predict_parts(self, X):
        Xv = np.asarray(X, float)
        p = np.clip(self.h_p.predict(Xv), 0.0, 1.0)
        mk_c = (np.full(len(Xv), self._mk_c_const) if self._mk_c_const is not None
                else self.h_mk_c.predict(Xv))
        unc_f = (np.full(len(Xv), self._unc_f_const) if self._unc_f_const is not None
                 else self.h_unc_f.predict(Xv))
        return p, mk_c, np.maximum(unc_f, 0.0)

    def predict(self, X):
        p, mk_c, unc_f = self.predict_parts(X)
        return np.array([recompose(pi, mi, ui, self.mk_f_const)
                         for pi, mi, ui in zip(p, mk_c, unc_f)], float)


# ==========================================================================================
#  3. 결정 동일성 평가 -- LOIO(leave-one-instance-out)
# ==========================================================================================
def loio_decisions(agg, X, model_factory, target="q_cost"):
    """instance 하나를 빼고 학습 -> 그 instance 의 팔들을 예측 -> argmin 을 고른다.

    반환: {instance: 고른 macro}. 1층/2층 모두 같은 함수를 쓰므로 비교가 공정하다.
    """
    insts = [r["instance"] for r in agg]
    uniq = sorted(set(insts))
    Xv = np.asarray(X, float)
    y = np.array([r[target] for r in agg], float) if target else None
    chosen = {}
    for held in uniq:
        te = np.array([i == held for i in insts], bool)
        tr = ~te
        if tr.sum() < 5 or te.sum() < 2:
            continue
        m = model_factory()
        if isinstance(m, TwoLayerValue):
            m.fit(Xv[tr], [a for a, k in zip(agg, tr) if k])
            pred = m.predict(Xv[te])
        else:
            m.fit(Xv[tr], y[tr])
            pred = m.predict(Xv[te])
        arms = [a for a, k in zip(agg, te) if k]
        chosen[held] = int(arms[int(np.argmin(pred))]["macro"])
    return chosen


def regret_of(chosen, agg, decisive_only=None):
    """고른 팔의 실제 q_cost - 그 instance 의 최소 q_cost. instance 내부에서 정규화한다.

    정규화 이유: instance 마다 비용 스케일이 3자릿수 다르다(완주 ~20 vs 미완주 ~26000).
    정규화 없이 평균 내면 미완주 instance 하나가 전체 평균을 지배한다.
    """
    by_inst = {}
    for r in agg:
        by_inst.setdefault(r["instance"], []).append(r)
    vals = []
    for inst, m in chosen.items():
        if decisive_only is not None and inst not in decisive_only:
            continue
        g = by_inst[inst]
        qs = {int(r["macro"]): float(r["q_cost"]) for r in g}
        lo, hi = min(qs.values()), max(qs.values())
        span = hi - lo
        if span <= 0:
            vals.append(0.0)                       # 동점 instance: 어떤 팔이든 regret 0
            continue
        vals.append((qs[m] - lo) / span)
    return (float(np.mean(vals)) if vals else float("nan")), len(vals)


def tie_split(agg):
    """동점 instance 와 결정적 instance 를 가른다 (함정 13).

    동점을 섞어두면 argmin 이 첫 원소(=NOOP)로 깨져 정답분포가 왜곡되고,
    모든 정책의 regret 이 0 쪽으로 희석돼 정책 간 차이가 사라진다.
    """
    by_inst = {}
    for r in agg:
        by_inst.setdefault(r["instance"], []).append(r)
    decisive, tied = set(), set()
    for inst, g in by_inst.items():
        if len(g) < 2:
            continue
        c = [float(r["q_cost"]) for r in g]
        (tied if (max(c) - min(c)) <= max(1e-9, 1e-9 * abs(min(c))) else decisive).add(inst)
    return decisive, tied


# ==========================================================================================
#  4. main
# ==========================================================================================
# 2층 분해가 새로 만든 **라벨**들. φ 에 절대 들어가면 안 된다(정답 누출).
TWO_LAYER_LABELS = ("mk_c", "mk_f", "unc_f", "q_recomposed")


def build_features(agg, phi="agnostic"):
    """φ 를 만든다. 이 저장소에는 서로 다른 φ 정의가 **두 개** 있어서 선택해야 한다.

    "agnostic" : features_agnostic.featurize_agnostic — 상태 서술자 6개(kind-agnostic 설계용)
                 + macro one-hot 5 + valid 1 = 12 열.
    "full"     : overnight_mdp.phi_columns — 행에 있는 수치열 전부의 **합집합**(README §6 의 φ 40개
                 계열, xc_*/xt_*/xg_*/xa_* 포함) + macro 1 열.

    둘은 같은 이름("φ")으로 불려왔지만 서로 다른 것이다. T1(φ 충분성)을 재려면 어느 쪽인지
    반드시 고정해야 하므로, 여기서는 선택을 **명시적 인자**로 만든다.
    """
    if phi in ("agnostic", "psi"):
        import pandas as pd
        from features_agnostic import featurize_agnostic
        # "psi" = 액션을 id one-hot 이 아니라 조합 가능한 서술자로 인코딩(A2/A3).
        # 두 표현의 결정이 같아야 "표현을 바꿔도 회귀가 없다"고 말할 수 있다.
        X = featurize_agnostic(pd.DataFrame(agg),
                               action_repr=("onehot" if phi == "agnostic" else "psi"),
                               include_valid=True)
        return X.values, list(X.columns)

    from overnight_mdp import phi_columns, design_matrix, derive_state_descriptors
    rows = []
    for r in agg:
        d = dict(r)
        d.update(derive_state_descriptors(d))    # raw_* 평행벡터 -> xc_*/xt_*/xg_*/xa_*
        rows.append(d)
    # extra_ban 이 없으면 mk_c/unc_f 가 φ 로 들어간다 = 정답을 특징으로 주는 것.
    cols, _ = phi_columns(rows, extra_ban=TWO_LAYER_LABELS)
    X = design_matrix(rows, cols)
    return X, cols + ["macro"]


def load_rows(pattern):
    # 함정 11: 글롭은 **좁게**. probes 파일은 상태 궤적이지 라벨이 아니므로 제외한다.
    files = [f for f in sorted(glob.glob(os.path.join(HERE, pattern)))
             if not f.endswith(".probes.jsonl")]
    rows = []
    for f in files:
        for line in open(f, encoding="utf-8"):
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except Exception:
                    pass
    print(f"  읽은 파일 {len(files)}개, 원시 rollout 행 {len(rows)}개")
    for f in files:
        print(f"    · {os.path.relpath(f, HERE)}")
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--glob", default="oracle/out/ep2_*.jsonl")
    ap.add_argument("--out", default="artifacts_mdp/two_layer.json")
    ap.add_argument("--phi", default="agnostic", choices=["agnostic", "psi", "full"],
                    help="어느 φ 정의를 쓸지. 이 저장소에는 두 개가 공존한다(build_features 참조).")
    args = ap.parse_args()

    print("=" * 78)
    print("STEP 1 — 값 2층 분해 (완주확률 x makespan)")
    print("=" * 78)

    rows = load_rows(args.glob)
    if not rows:
        print("!! 데이터 없음"); return 1

    print("\n[1] 분해")
    agg = decompose_rollouts(rows)
    n_inst = len({r["instance"] for r in agg})
    print(f"  (instance, macro) 셀 {len(agg)}개, instance {n_inst}개, "
          f"rollout/셀 중앙값 {int(np.median([r['n_rollout'] for r in agg]))}")
    pc = np.array([r["p_complete"] for r in agg])
    print(f"  P(complete) 분포: 0인 셀 {int((pc == 0).sum())}, 1인 셀 {int((pc == 1).sum())}, "
          f"중간 {int(((pc > 0) & (pc < 1)).sum())}  <- 중간이 0이면 K=1(결정론) 데이터다")

    print("\n[2] 항등식 검사 (모델 이전 배선 검증)")
    ok = check_identity(agg)
    if not ok:
        print("  !! 항등식 불일치 -> 집계 배선 문제. 모델 학습으로 넘어가지 않는다.")
        return 2

    print("\n[3] 동점 진단")
    decisive, tied = tie_split(agg)
    tot = len(decisive) + len(tied)
    print(f"  동점 {len(tied)}/{tot} ({len(tied)/max(1,tot):.0%}) · 결정적 {len(decisive)}개")

    print(f"\n[4] 결정 동일성 (1층 회귀 vs 2층 분해), LOIO · φ={args.phi}")
    try:
        X, cols = build_features(agg, phi=args.phi)
        X = np.asarray(X, float)
        print(f"  특징행렬 {X.shape}  (열 {len(cols)}개)")
        leak = [c for c in cols if c in TWO_LAYER_LABELS or c in ("q_cost", "p_complete")]
        if leak:
            print(f"  !! 라벨이 φ 에 섞였다: {leak} — 중단")
            return 4
    except Exception as e:
        print(f"  !! featurize 실패: {e}")
        return 3

    one = loio_decisions(agg, X, lambda: build_model(), target="q_cost")
    two = loio_decisions(agg, X, lambda: TwoLayerValue(), target=None)
    common = sorted(set(one) & set(two))
    same = sum(1 for i in common if one[i] == two[i])
    print(f"  평가된 instance {len(common)}개 · 결정 일치 {same}/{len(common)} "
          f"({same/max(1,len(common)):.0%})")
    disagree = [i for i in common if one[i] != two[i]]
    for i in disagree[:8]:
        print(f"    다름: {i}  1층->macro {one[i]}  2층->macro {two[i]}")

    r1_all, n1 = regret_of(one, agg)
    r2_all, n2 = regret_of(two, agg)
    r1_d, n1d = regret_of(one, agg, decisive_only=decisive)
    r2_d, n2d = regret_of(two, agg, decisive_only=decisive)
    print(f"\n  정규화 regret  전체(n={n1}):   1층 {r1_all:.4f} · 2층 {r2_all:.4f}")
    print(f"  정규화 regret  결정적(n={n1d}): 1층 {r1_d:.4f} · 2층 {r2_d:.4f}"
          f"   <- **판정은 이 줄로 한다** (함정 13/14)")
    if n1d < 30:
        print(f"  !! 결정적 표본 {n1d}개 < 30 — 이 숫자로 우열을 **판정하지 말 것**(함정 14). "
              f"오늘 밤 기준은 '회귀 없음' 뿐이다.")

    res = {
        "n_cells": len(agg), "n_instances": n_inst,
        "identity_ok": ok, "n_tied": len(tied), "n_decisive": len(decisive),
        "decision_agreement": (same / len(common)) if common else None,
        "regret_all": {"one_layer": r1_all, "two_layer": r2_all, "n": n1},
        "regret_decisive": {"one_layer": r1_d, "two_layer": r2_d, "n": n1d},
        "disagreements": [{"instance": i, "one": one[i], "two": two[i],
                           "tied": i in tied} for i in disagree],
        "glob": args.glob, "phi": args.phi, "n_phi_cols": len(cols),
    }
    # 불일치가 전부 동점 instance 라면 "결정에는 아무 차이가 없다" = 회귀 없음.
    n_dis_tied = sum(1 for i in disagree if i in tied)
    print(f"  불일치 {len(disagree)}개 중 동점 instance {n_dis_tied}개"
          f" -> 결정적 instance 에서의 불일치는 {len(disagree) - n_dis_tied}개")
    res["disagree_decisive"] = len(disagree) - n_dis_tied
    outp = os.path.join(HERE, args.out)
    os.makedirs(os.path.dirname(outp), exist_ok=True)
    json.dump(res, open(outp, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
    print(f"\nwrote {outp}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
