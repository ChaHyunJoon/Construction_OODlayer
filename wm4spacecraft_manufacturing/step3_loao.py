#!/usr/bin/env python
"""
step3_loao.py -- MDP STEP 3: LEAVE-ONE-ACTION-OUT (LOAO).
  (설계: MDP_DESIGN_FROM_SCRATCH.md §8.1 + §4.3, 구현로그 §14)

무엇을 재는가
=============
지금까지의 실험은 전부 **처음 보는 사건 종류(kind)** 를 다뤘다(LOKO). 이 파일은 그와 짝을 이루는,
아직 아무도 재지 않은 질문을 잰다:

    **학습 때 한 번도 본 적 없는 "대응(macro)"을 모델이 점수 매길 수 있는가?**

이게 왜 STEP 3 의 핵심인가: 설계 §4.3 에서 LLM 의 진짜 역할은 "기존 옵션 중 고르기"가 아니라
**새 옵션을 만들어 행동공간 A 를 넓히는 것**이다. 그런데 새로 생긴 옵션을 surrogate 가 점수
매길 수 없으면, 그 옵션은 영원히 LLM 전용으로 남고 §9 의 동화(assimilation) 루프가 닫히지 않는다.
"한 번 겪은 건 surrogate 가 싸게 처리한다"는 아이디어 자체가 성립하지 않는다.

그리고 이건 **표현(representation) 문제**다. 액션을 one-hot 으로 넣으면 처음 보는 액션은
"모든 열이 0" 인 벡터가 되어 학습 지지집합 밖으로 나간다 — 데이터를 아무리 모아도 안 된다.
액션을 서술자(비용/개입성/소프트함/능력복원/작업이동/공간성)로 넣으면, 처음 보는 액션도
기존 액션들 사이의 한 점으로 표현되어 회귀함수가 값을 낼 수 있다.

비교 대상 (openworld_experiments.REPRESENTATIONS 그대로 재사용)
    legacy       e1_analyze.featurize        (kind one-hot + 센티넬, 액션 one-hot)  <- 현재 배포본
    agnostic     kind-agnostic 상태 + 액션 one-hot
    agnostic-d   kind-agnostic 상태 + 액션 **서술자**                                <- 이 파일의 후보

프로토콜
========
macro m 마다:
  · 학습 = macro != m 인 모든 행 (m 은 학습에서 완전히 사라진다)
  · 평가 = 모든 instance 에서 **5개 macro 전부** 예측 -> valid 게이트 -> 하나 선택
           -> norm_regret (배포 경로와 동일한 채점)
  · 별도로, **정답이 m 인 instance 만** 따로 채점한다. 이게 결정적인 숫자다 —
    본 적 없는 액션이 정답인 상황에서 그걸 집어낼 수 있는가.
천장(ceiling) 기준선으로 LOIO(모든 액션을 본 경우)를 같이 낸다.

정직성 주의
===========
· 이 데이터셋의 라벨은 **STEP 2 이전의 1-shot certainty-equivalent 라벨**(`closed`)이다.
  표현을 바꾸는 일과 라벨을 바꾸는 일은 직교하므로 여기서는 표현만 비교한다. MC 라벨로
  재측정하는 것은 남은 일이다(§14 참조).
· 액션 서술자 표(`_ACTION_TABLE`)는 **사람이 손으로 적은 것**이다. 새 액션이 오면 그 서술자도
  누군가 채워야 한다 — 이 파일이 보이는 것은 "서술자가 주어지면 일반화가 되는가"이지
  "서술자가 자동으로 생긴다"가 아니다. LLM 이 새 옵션을 DSL 로 낼 때 서술자도 같이 내게 하는 것이
  자연스러운 연결이며, 그건 STEP 5(Router) 범위다.

실행:  python step3_loao.py [데이터.jsonl] [--lam=3]
"""
import sys, os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

import numpy as np
import pandas as pd
from sklearn.model_selection import LeaveOneGroupOut

import wm_datasets
from e1_analyze import MACROS
from features_agnostic import kind_leakage_report
from features_agnostic import featurize_agnostic
from openworld_experiments import (REPRESENTATIONS as _BASE_REPS, load_df, pick_with_gate,
                                   valid_macros_of, featurize_kind_only)
from surrogate_model import build_model
from verify import norm_regret, oracle_best_macro, paired_bootstrap

# 하이브리드 후보: 액션을 one-hot **과** 서술자로 동시에 넣는다.
#   · 학습에서 본 액션 -> one-hot 열이 깔끔한 분리를 주므로 in-distribution 성능을 지킨다.
#   · 처음 보는 액션   -> one-hot 은 전부 0(지지집합 밖)이지만 서술자 열은 여전히 값을 가지므로
#                        회귀함수가 기존 액션들 사이의 한 점으로 보고 값을 낼 수 있다.
# 이걸 넣는 이유: 순수 서술자(agnostic-d)가 미지 액션에서는 도움이 되지만 in-distribution 을
# 크게 해치는 것이 1차 측정에서 드러났기 때문이다(LOIO 0.230 vs 0.087).
REPRESENTATIONS = dict(_BASE_REPS)
REPRESENTATIONS["agnostic-b"] = lambda d: featurize_agnostic(d, action_repr="both")

# --- 누출을 실제로 막은 변형 -------------------------------------------------------------
# 진단 결과: `harm` 과 `resource_loss` 는 **각각 단독으로** kind 를 100% 맞힌다. 값 구간이
# 완전히 분리되어 있기 때문이다(1-feature 결정트리 acc=1.000):
#     harm           battery [0.650,0.950] | fault {1.000} | zoneblk [0.000,0.571]
#     resource_loss  battery [0.650,0.950] | fault {1.000} | zoneblk {0.000}
# 이유는 물리가 아니라 정의다 — fault 의 harm 은 배포 시 항상 상수 1.0 이고(정답표가 아니라
# 그냥 상수), zone 은 로봇이 안 걸려 resource_loss 가 구조적으로 정확히 0 이다.
# 즉 kind one-hot 을 빼도 이 둘이 남아 있으면 종류 지름길은 그대로 있다. 센티넬을 연속값으로
# 갈아입힌 것뿐이다.
#
# `noleak-4` 는 그 둘을 빼고 남은 4개 서술자만 쓴다. 이 표현이
#   · 누출 정확도를 무작위 수준으로 떨어뜨리면서 regret 을 지키면 -> 진짜 kind-agnostic 이 가능
#   · regret 이 무너지면 -> 모델이 여태 종류 지름길을 타고 있었다는 직접 증거
# 어느 쪽이든 결론이 나온다.
_NOLEAK_DROP = ["harm", "resource_loss"]


def _featurize_noleak(d):
    X = featurize_agnostic(d, action_repr="onehot")
    return X.drop(columns=[c for c in _NOLEAK_DROP if c in X.columns])


REPRESENTATIONS["noleak-4"] = _featurize_noleak

MACRO_NAME = {0: "NOOP", 1: "Replace", 2: "Deprioritize", 3: "ForbidZone", 4: "ReformTeam",
              5: "ForbidAgent+ReformTeam", 6: "Deprioritize+ForbidWindow", 7: "RelocateBuild"}


# ==========================================================================================
#  LOIO -- 천장 기준선(모든 액션을 학습에서 봤을 때)
# ==========================================================================================
def loio_regrets(df, featurizer, lam):
    """instance 하나씩 빼고 학습 -> 뺀 instance 의 regret 목록. (openworld_experiments.loio_one 과 동일 절차)"""
    Xall = featurizer(df)
    X = Xall.values
    y, groups = df.closed.astype(float).values, df.instance.values
    by_inst = {i: g for i, g in df.groupby("instance")}
    out = {}
    for tr, te in LeaveOneGroupOut().split(X, y, groups):
        inst = groups[te][0]
        g = by_inst[inst]
        model = build_model().fit(X[tr], y[tr])
        pred = model.predict(X[te])
        pbm = {int(m): float(p) for m, p in zip(df.iloc[te].macro.astype(int).values, pred)}
        out[inst] = float(norm_regret(g, pick_with_gate(pbm, valid_macros_of(g)), lam))
    return out


# ==========================================================================================
#  LOAO -- 액션 하나를 통째로 빼고 학습
# ==========================================================================================
def loao_one(df, featurizer, lam, held_macro):
    """`held_macro` 를 학습에서 완전히 제거하고, 평가에서는 5개 전부 예측해 고르게 한다.

    반환: {instance: regret} 과 예측 진단.
    """
    Xall = featurizer(df)
    X = Xall.values
    y = df.closed.astype(float).values
    macros = df.macro.astype(int).values
    insts = df.instance.values

    tr = np.where(macros != held_macro)[0]          # 학습: 그 액션이 존재하지 않는 세계
    model = build_model().fit(X[tr], y[tr])

    by_inst = {i: g for i, g in df.groupby("instance")}
    regs, held_pred_rank = {}, []
    for inst, g in by_inst.items():
        idx = np.where(insts == inst)[0]
        pred = model.predict(X[idx])
        pbm = {int(m): float(p) for m, p in zip(macros[idx], pred)}
        valid = valid_macros_of(g)
        regs[inst] = float(norm_regret(g, pick_with_gate(pbm, valid), lam))
        # 진단: 본 적 없는 액션에 매긴 점수가 다른 액션들 사이에서 몇 등인가(1 = 최고점)
        order = sorted(pbm, key=pbm.get, reverse=True)
        if held_macro in order:
            held_pred_rank.append(order.index(held_macro) + 1)
    return regs, held_pred_rank


def run_loao(df, lam):
    by_inst = {i: g for i, g in df.groupby("instance")}
    best_of = {i: int(oracle_best_macro(g, lam)) for i, g in by_inst.items()}

    print("\n" + "=" * 100)
    print("STEP 3 / LOAO = 대응(macro) 하나를 학습에서 통째로 빼고, 그걸 포함해 고르게 한다")
    print("=" * 100)
    print(f"  {len(df)} rows, {df.instance.nunique()} instances, kinds={sorted(df.kind.unique())}, lambda={lam}")
    print("  regret 0 = 매번 최선 / 1 = 매번 최악.  '정답이 뺀 액션' = 그 액션이 오라클 정답인 instance 만 채점\n")

    # --- 천장 기준선 ---------------------------------------------------------------------
    ceil = {n: loio_regrets(df, f, lam) for n, f in REPRESENTATIONS.items()}
    print(f"  천장(LOIO, 모든 액션 학습됨): " +
          "  ".join(f"{n}={np.mean(list(v.values())):.3f}" for n, v in ceil.items()))

    rows = []
    for m in sorted(set(df.macro.astype(int))):
        tgt = [i for i, b in best_of.items() if b == m]      # 정답이 m 인 instance 들
        print("\n  " + "-" * 96)
        print(f"  빼는 액션: {m}:{MACRO_NAME.get(m, '?')}    (이 액션이 정답인 instance: {len(tgt)}개)")
        print(f"    {'표현':<14} {'전체 regret':>12} {'정답이 뺀 액션':>16} {'뺀 액션 예측순위(중앙값)':>24}")
        rec = {"held": m, "n_target": len(tgt)}
        for n, f in REPRESENTATIONS.items():
            regs, ranks = loao_one(df, f, lam, m)
            all_r = float(np.mean(list(regs.values())))
            tgt_r = float(np.mean([regs[i] for i in tgt])) if tgt else float("nan")
            med_rank = float(np.median(ranks)) if ranks else float("nan")
            print(f"    {n:<14} {all_r:>12.3f} {tgt_r:>16.3f} {med_rank:>24.1f}")
            rec[n] = {"all": all_r, "target": tgt_r, "target_regrets": [regs[i] for i in tgt],
                      "all_regrets": [regs[i] for i in sorted(regs)], "median_rank": med_rank}
        rows.append(rec)
    return rows, ceil, best_of


def summarize(rows, ceil, df, lam):
    print("\n" + "=" * 100)
    print("요약")
    print("=" * 100)

    # 표현별로 모든 폴드의 instance-level regret 을 이어붙여 짝지은 비교를 한다.
    pooled_all = {n: sum((r[n]["all_regrets"] for r in rows), []) for n in REPRESENTATIONS}
    pooled_tgt = {n: sum((r[n]["target_regrets"] for r in rows), []) for n in REPRESENTATIONS}

    print(f"  {'표현':<14} {'LOIO(천장)':>12} {'LOAO 전체':>12} {'LOAO 정답이 뺀 액션':>22}")
    print("  " + "-" * 64)
    for n in REPRESENTATIONS:
        print(f"  {n:<14} {np.mean(list(ceil[n].values())):>12.3f} "
              f"{np.mean(pooled_all[n]):>12.3f} {np.mean(pooled_tgt[n]):>22.3f}")

    print("\n  -- 짝지은 비교 (양수 = 뒤쪽이 더 좋음; CI 가 0 을 포함하면 '차이 못 밝힘') --")
    print("     * 결정적인 줄은 '정답이 뺀 액션' 쪽이다. 전체 regret 은 대부분의 instance 에서")
    print("       뺀 액션이 정답이 아니라서 차이가 희석된다.")
    for a, b in (("legacy", "agnostic-d"), ("agnostic", "agnostic-d"), ("legacy", "agnostic")):
        for label, pool in (("전체       ", pooled_all), ("정답이 뺀 액션", pooled_tgt)):
            if not pool[a] or len(pool[a]) != len(pool[b]):
                continue
            d, lo, hi = paired_bootstrap(pool[a], pool[b])
            sig = "유의함" if lo > 0 else ("반대로 유의" if hi < 0 else "차이 못 밝힘")
            print(f"    [{label}] {a:<11} vs {b:<11} 차이={d:+.3f}  CI [{lo:+.3f},{hi:+.3f}]  -> {sig}")

    # 본 적 없는 액션에 매긴 점수의 순위 — one-hot 이 원리적으로 못 하는 부분이 실제로 보이는지
    print("\n  -- 본 적 없는 액션의 예측 순위(중앙값, 1등이면 그 액션을 고른 것) --")
    print(f"    {'뺀 액션':<18} " + " ".join(f"{n:>12}" for n in REPRESENTATIONS))
    for r in rows:
        print(f"    {str(r['held']) + ':' + MACRO_NAME.get(r['held'], '?'):<18} " +
              " ".join(f"{r[n]['median_rank']:>12.1f}" for n in REPRESENTATIONS))


def leakage(df):
    print("\n" + "=" * 100)
    print("kind 누출 감사 — 특징행렬만으로 사건 '종류 이름'을 얼마나 복원할 수 있는가")
    print("=" * 100)
    print("  1.000 이면 그 표현은 종류를 완벽히 복원한다(= kind-agnostic 이 아니다).")
    print("  물리적으로 종류가 다르면 서술자도 다른 게 정상이므로 0 이 목표는 아니다 —")
    print("  one-hot/센티넬 같은 '공짜 지름길'이 남아있는지를 잡는 용도.\n")
    for n, f in REPRESENTATIONS.items():
        r = kind_leakage_report(df, f, n)
        print(f"    {n:<14} 복원 정확도 {r['acc']:.3f}   (무작위 추측 {r['chance']:.3f})")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    lam = next((float(a.split("=")[1]) for a in sys.argv[1:] if a.startswith("--lam=")), 3.0)
    path = wm_datasets.abspath(args[0]) if args else wm_datasets.abspath(wm_datasets.CANONICAL)
    print(f"[step3] dataset = {path}")
    df = load_df(path)

    leakage(df)
    rows, ceil, _ = run_loao(df, lam)
    summarize(rows, ceil, df, lam)

    import json
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "artifacts_openworld", "step3_loao.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump({"lam": lam, "dataset": path,
                   "ceiling": {n: float(np.mean(list(v.values()))) for n, v in ceil.items()},
                   "folds": rows}, fh, indent=2)
    print(f"\nwrote {out}")


if __name__ == "__main__":
    main()
