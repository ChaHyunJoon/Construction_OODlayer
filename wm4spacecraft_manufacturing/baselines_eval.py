#!/usr/bin/env python
"""baselines_eval.py -- 정책 비교 하니스: 규칙표 baseline + 동점 제외 평가 + 짝지은 검정.

왜 필요한가
-----------
regret 숫자 하나만으로는 아무것도 말할 수 없다. 두 가지가 반드시 같이 있어야 한다.

1. **베이스라인** — regret 0 이 "모델이 잘한 것"인지 "과제가 쉬운 것"인지 구별하려면
   상한(oracle)과 하한(무작위), 그리고 **상태를 보지 않는 규칙표**가 필요하다.
   규칙표(`rule_table` = 사건 종류별 고정 대응)는 다중로봇 LLM 조율 연구에서 흔히 쓰는
   대조군 형태다(DEXTER-LLM 류의 "종류별 고정 규칙"). 상태 기반 정책이 이걸 못 이기면
   상태를 본 의미가 없다.

2. **동점 제외** — 모든 팔의 비용이 같은 instance 는 어떤 정책이든 regret 0 이다.
   섞어서 평균 내면 정책 간 차이가 0 쪽으로 희석되고, 게다가 argmin 이 동점을 첫 원소
   (= macro 0 = NOOP)로 깨기 때문에 "정답은 대개 NOOP" 이라는 가짜 사실까지 생긴다.
   그래서 **결정적(decisive) 부분집합**에서 따로 재고, 몇 개를 뺐는지 반드시 보고한다
   (조용한 절단 금지).

정책 목록
---------
  oracle            : 실제 최소비용 팔 (상한, regret=0)
  random_valid      : 유효 팔 중 무작위 (하한)
  noop_always       : 항상 개입하지 않음
  intervene_always  : 항상 개입 (유효한 비-NOOP 팔)
  state_independent : 훈련폴드 전체에서 평균이 가장 좋은 팔 하나 (상태 무시)
  rule_table        : **사건 종류별로** 훈련폴드 평균이 가장 좋은 팔 (상태 무시, 종류만 봄)
                      = `always_per_kind`. 종류 이름만으로 어디까지 가는지를 재는 자
  canonical         : 저장소에 하드코딩된 규칙 (fault->Replace, zone->ForbidZone,
                      battery deep->Replace / mild->Deprioritize)
  surrogate_1layer  : q_cost 를 직접 회귀 (현행)
  surrogate_2layer  : 완주확률 x makespan 2층 분해 (value_two_layer)

모든 학습형 정책은 **leave-one-instance-out** 으로 평가한다. rule_table/state_independent 도
훈련폴드에서 규칙을 **유도**하므로 같은 조건이다(정답을 보고 규칙을 고르면 부정행위다).

실행
    python baselines_eval.py --glob 'oracle/out/ep2_*.jsonl' --phi full
"""
import os, sys, json, math, argparse
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

import numpy as np

from value_two_layer import (decompose_rollouts, load_rows, tie_split,
                             build_features, TwoLayerValue)
from surrogate_model import build_model

HERE = os.path.dirname(os.path.abspath(__file__))
REPLACE_SOC_THRESHOLD = 0.2      # ood_mdp_shim.jl 의 CB.REPLACE_SOC_THRESHOLD 기본값과 같은 값


# ==========================================================================================
#  준비: instance -> 팔 목록
# ==========================================================================================
def group_by_instance(agg):
    by = defaultdict(list)
    for r in agg:
        by[r["instance"]].append(r)
    return {k: sorted(v, key=lambda r: int(r["macro"])) for k, v in by.items()
            if len(v) >= 2 and all(math.isfinite(float(x["q_cost"])) for x in v)}


def kind_of(g):
    return str(g[0].get("kind", "?"))


# ==========================================================================================
#  정책들 — 전부 (훈련 instance 들, 대상 instance 의 팔들) -> 고른 macro
# ==========================================================================================
def pol_oracle(train, g):
    return int(min(g, key=lambda r: float(r["q_cost"]))["macro"])


def pol_random(train, g, rng=None):
    rng = rng or np.random.default_rng(0)
    return int(g[int(rng.integers(len(g)))]["macro"])


def pol_noop(train, g):
    ms = [int(r["macro"]) for r in g]
    return 0 if 0 in ms else ms[0]


def pol_intervene(train, g):
    ms = [int(r["macro"]) for r in g]
    nz = [m for m in ms if m != 0]
    return nz[0] if nz else ms[0]


def _best_macro_by_normalized_cost(groups):
    """훈련폴드에서 '평균적으로 가장 좋은 팔'. instance 내부 정규화 후 평균낸다.

    정규화 없이 평균내면 미완주 instance(비용 ~26000) 하나가 전체를 지배한다.
    """
    score, cnt = defaultdict(float), Counter()
    for g in groups:
        qs = {int(r["macro"]): float(r["q_cost"]) for r in g}
        lo, hi = min(qs.values()), max(qs.values())
        span = hi - lo
        for m, q in qs.items():
            score[m] += 0.0 if span <= 0 else (q - lo) / span
            cnt[m] += 1
    if not cnt:
        return 0
    return min(score, key=lambda m: score[m] / cnt[m])


def pol_state_independent(train, g):
    best = _best_macro_by_normalized_cost(train)
    ms = [int(r["macro"]) for r in g]
    return best if best in ms else ms[0]


def pol_rule_table(train, g):
    """사건 종류별 고정 규칙을 **훈련폴드에서 유도**한다 (= always_per_kind)."""
    by_kind = defaultdict(list)
    for tg in train:
        by_kind[kind_of(tg)].append(tg)
    k = kind_of(g)
    ms = [int(r["macro"]) for r in g]
    if k in by_kind:
        best = _best_macro_by_normalized_cost(by_kind[k])
        if best in ms:
            return best
    return pol_state_independent(train, g)


def pol_canonical(train, g):
    """저장소에 하드코딩된 규칙(ood_mdp_shim.jl:canonical_action)의 파이썬 미러."""
    k, ms = kind_of(g), [int(r["macro"]) for r in g]
    if k == "fault":
        pick = 1
    elif k in ("zoneblk", "zone"):
        pick = 3
    elif k == "battery":
        soc = g[0].get("soc", g[0].get("severity", np.nan))
        try:
            soc = float(soc)
        except Exception:
            soc = float("nan")
        pick = 1 if (math.isfinite(soc) and soc <= REPLACE_SOC_THRESHOLD) else 2
    else:
        pick = 0
    return pick if pick in ms else (0 if 0 in ms else ms[0])


# ==========================================================================================
#  평가
# ==========================================================================================
def normalized_regret(inst_groups, chosen, subset=None):
    """instance 내부 정규화 regret. subset 을 주면 그 instance 들만."""
    vals, used = [], []
    for inst, m in chosen.items():
        if subset is not None and inst not in subset:
            continue
        g = inst_groups[inst]
        qs = {int(r["macro"]): float(r["q_cost"]) for r in g}
        lo, hi = min(qs.values()), max(qs.values())
        span = hi - lo
        vals.append(0.0 if span <= 0 else (qs[m] - lo) / span)
        used.append(inst)
    return np.array(vals, float), used


def sign_test(a, b):
    """짝지은 부호검정 (정확 이항). a,b 는 같은 instance 순서의 regret 배열.

    scipy 없이 계산한다 -- 이 저장소는 scipy 의존을 늘리지 않는다.
    반환: (a 가 이긴 횟수, b 가 이긴 횟수, 양측 p)
    """
    wins = int(np.sum(a < b))
    losses = int(np.sum(a > b))
    n = wins + losses
    if n == 0:
        return wins, losses, 1.0
    k = min(wins, losses)
    tail = sum(math.comb(n, i) for i in range(k + 1)) / (2 ** n)
    return wins, losses, min(1.0, 2 * tail)


def loio_model_policy(agg, X, factory, two_layer=False, held_out_kinds=()):
    """학습형 정책을 leave-one-instance-out 으로 돌려 {instance: macro} 를 만든다.

    held_out_kinds : 이 종류의 행은 **훈련폴드에서 통째로 제거**한다 (B2 오염 가드).
        "미지의 사건 N" 실험은 그 종류가 훈련에 한 톨도 들어가지 않아야 성립한다.
        instance 하나만 빼는 LOIO 로는 같은 종류의 다른 instance 가 훈련에 남아
        "처음 보는 종류"가 아니게 된다 -- 이 구분이 없으면 LOKO 를 OOD 실험이라
        부르는 것과 같은 종류의 착오가 된다.
    """
    insts = [r["instance"] for r in agg]
    kinds = [str(r.get("kind")) for r in agg]
    held = set(held_out_kinds or ())
    uniq = sorted(set(insts))
    Xv = np.asarray(X, float)
    y = np.array([float(r["q_cost"]) for r in agg], float)
    # 미완주 비용(~26000)이 스케일을 지배하므로, 1층 회귀는 instance 내부 정규화 타깃으로 배운다
    # (2층은 물리량 자체를 배우므로 정규화하지 않는다 -- 이 비대칭이 곧 2층의 논지다).
    y_norm = np.array(y, float)
    for inst in uniq:
        sel = np.array([i == inst for i in insts], bool)
        lo, hi = y[sel].min(), y[sel].max()
        y_norm[sel] = 0.0 if hi <= lo else (y[sel] - lo) / (hi - lo)

    chosen = {}
    for held_inst in uniq:
        te = np.array([i == held_inst for i in insts], bool)
        tr = ~te
        if held:
            # 훈련폴드에서 held-out 종류를 제거. 평가 대상(te)은 그대로 둔다.
            tr = tr & np.array([k not in held for k in kinds], bool)
            contaminated = [k for k, m in zip(kinds, tr) if m and k in held]
            assert not contaminated, f"오염: 훈련폴드에 held-out 종류가 남았다 {set(contaminated)}"
        if tr.sum() < 5 or te.sum() < 2:
            continue
        m = factory()
        if two_layer:
            m.fit(Xv[tr], [a for a, k in zip(agg, tr) if k])
        else:
            m.fit(Xv[tr], y_norm[tr])
        pred = m.predict(Xv[te])
        arms = [a for a, k in zip(agg, te) if k]
        chosen[held_inst] = int(arms[int(np.argmin(pred))]["macro"])
    return chosen


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--glob", default="oracle/out/ep2_*.jsonl")
    ap.add_argument("--phi", default="full", choices=["agnostic", "psi", "full"])
    ap.add_argument("--out", default="artifacts_mdp/baselines.json")
    ap.add_argument("--held-out-kind", default="",
                    help="쉼표구분. 이 종류는 훈련폴드에서 통째로 제외한다(B2 오염 가드). "
                         "'처음 보는 종류' 실험의 전제조건.")
    args = ap.parse_args()

    print("=" * 78)
    print("STEP 2 — 베이스라인 + 동점 제외 평가")
    print("=" * 78)

    rows = load_rows(args.glob)
    if not rows:
        print("!! 데이터 없음"); return 1
    agg = decompose_rollouts(rows)
    groups = group_by_instance(agg)
    agg = [r for r in agg if r["instance"] in groups]       # 팔 1개짜리 제외
    decisive, tied = tie_split(agg)
    n_all = len(groups)
    print(f"\n  instance {n_all}개 · 결정적 {len(decisive)} · 동점 {len(tied)} "
          f"({len(tied)/max(1,n_all):.0%})")
    print(f"  kind 분포: {dict(Counter(kind_of(g) for g in groups.values()))}")
    print(f"  결정적만: {dict(Counter(kind_of(groups[i]) for i in decisive))}")

    X, cols = build_features(agg, phi=args.phi)
    print(f"  φ={args.phi} · 특징행렬 {np.asarray(X).shape}")

    # ---- 규칙형 정책들: 각 instance 를 뺀 나머지에서 규칙을 유도 --------------------------
    rng = np.random.default_rng(0)
    rule_policies = {
        "oracle": pol_oracle,
        "random_valid": lambda tr, g: pol_random(tr, g, rng),
        "noop_always": pol_noop,
        "intervene_always": pol_intervene,
        "state_independent": pol_state_independent,
        "rule_table": pol_rule_table,
        "canonical": pol_canonical,
    }
    chosen = {name: {} for name in rule_policies}
    for inst, g in groups.items():
        train = [gg for i, gg in groups.items() if i != inst]
        for name, fn in rule_policies.items():
            chosen[name][inst] = fn(train, g)

    # ---- 학습형 정책 ---------------------------------------------------------------------
    held = tuple(k for k in (args.held_out_kind or "").split(",") if k)
    if held:
        print(f"  B2 오염 가드: 훈련폴드에서 종류 {list(held)} 를 통째로 제거한다 "
              f"(= 그 종류는 '처음 보는 것')")
    chosen["surrogate_1layer"] = loio_model_policy(agg, X, lambda: build_model(),
                                                   held_out_kinds=held)
    chosen["surrogate_2layer"] = loio_model_policy(agg, X, lambda: TwoLayerValue(),
                                                   two_layer=True, held_out_kinds=held)

    # ---- 보고 ----------------------------------------------------------------------------
    print(f"\n  {'정책':<20}{'regret(전체)':>14}{'regret(결정적)':>16}{'top-1 적중':>12}")
    print("  " + "-" * 62)
    table, per_policy_vec = {}, {}
    for name in ["oracle", "surrogate_2layer", "surrogate_1layer", "canonical", "rule_table",
                 "state_independent", "intervene_always", "noop_always", "random_valid"]:
        ch = chosen[name]
        r_all, _ = normalized_regret(groups, ch)
        r_dec, used_dec = normalized_regret(groups, ch, subset=decisive)
        hit = np.mean([1.0 if ch[i] == pol_oracle(None, groups[i]) else 0.0
                       for i in used_dec]) if used_dec else float("nan")
        per_policy_vec[name] = (r_dec, used_dec)
        table[name] = {"regret_all": float(r_all.mean()) if r_all.size else None,
                       "regret_decisive": float(r_dec.mean()) if r_dec.size else None,
                       "top1_decisive": float(hit) if used_dec else None,
                       "n_all": int(r_all.size), "n_decisive": int(r_dec.size)}
        print(f"  {name:<20}{table[name]['regret_all']:>14.4f}"
              f"{table[name]['regret_decisive']:>16.4f}{hit:>12.2f}")
    print(f"\n  전체 n={n_all} 중 동점 {len(tied)}개를 결정적 열에서 제외했다"
          f" (결정적 n={len(decisive)}). 조용한 절단이 아니라 명시적 보고다.")

    # ---- 짝지은 부호검정: 학습형이 규칙표를 이기는가 ---------------------------------------
    print("\n  짝지은 부호검정 (결정적 instance, 정렬된 공통 부분집합)")
    pairs = [("surrogate_2layer", "rule_table"), ("surrogate_1layer", "rule_table"),
             ("surrogate_2layer", "surrogate_1layer"), ("rule_table", "state_independent"),
             ("canonical", "rule_table")]
    tests = {}
    for a, b in pairs:
        (ra, ua), (rb, ub) = per_policy_vec[a], per_policy_vec[b]
        common = sorted(set(ua) & set(ub))
        if not common:
            continue
        va = np.array([ra[ua.index(i)] for i in common])
        vb = np.array([rb[ub.index(i)] for i in common])
        w, l, p = sign_test(va, vb)
        verdict = "우열 미확립" if p > 0.05 else ("A 우위" if w > l else "B 우위")
        tests[f"{a}_vs_{b}"] = {"wins": w, "losses": l, "p": p, "n": len(common)}
        print(f"    {a:<18} vs {b:<18} n={len(common):>3}  {w}승 {l}패  p={p:.3f}  {verdict}")
    if len(decisive) < 30:
        print(f"\n  !! 결정적 instance {len(decisive)}개 < 30 — 검정력이 없다. "
              f"어떤 우열도 **판정하지 말 것**(함정 14). 이 표는 배선 확인용이다.")

    res = {"glob": args.glob, "phi": args.phi, "n_instances": n_all,
           "n_decisive": len(decisive), "n_tied": len(tied),
           "policies": table, "sign_tests": tests,
           "choice_distribution": {k: dict(Counter(v.values())) for k, v in chosen.items()}}
    outp = os.path.join(HERE, args.out)
    os.makedirs(os.path.dirname(outp), exist_ok=True)
    json.dump(res, open(outp, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
    print(f"\nwrote {outp}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
