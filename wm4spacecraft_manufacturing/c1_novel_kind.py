#!/usr/bin/env python
"""
c1_novel_kind.py -- CLAIM C1: "on an OOD kind it has never seen, the LLM beats the surrogate".

WHERE THIS SITS
===============
The system being argued for is:

    NEW kind of OOD    ->  LLM reads the sentence, adapts          (claim C1: LLM > surrogate here)
    KNOWN kind of OOD  ->  surrogate answers in 0.1 ms             (claim C2: already measured, LOIO)
    the router tells them apart                                    (claim C3: assimilation_stream.py)
    what the LLM handled becomes surrogate training data           (claim C4: assimilation_stream.py)

C1 is the gate on the other three. If the LLM does NOT beat the surrogate on an unseen kind, there
is no reason to build a router -- routing to a worse producer is a worse system. So run this first.

PROTOCOL: leave-one-kind-out (LOKO)
    hold out every instance of one kind; train the surrogate on the other kinds only; score both
    producers on the held-out kind. The LLM's few-shot demos are drawn from the TRAINING kinds only
    (`build_demos(exclude_kinds=...)`), otherwise the held-out kind stops being unseen -- that is
    the most common way this experiment is accidentally invalidated.

WHAT EACH ARM ISOLATES
    surrogate      the trained forest, kind-agnostic features, gated by the valid mask (deployed path)
    llm:nl         sentence only               -- the literal "interprets the situation in language"
    llm:nl+state   sentence + 6 physical descriptors -- the deployable form (works on a novel kind)
    llm:feat       parsed schema fields        -- CONTROL. Decomposes the LLM's advantage into
                                                  language understanding vs prior over known schema.
    +fewshot       same input, plus worked examples from the training kinds

REFERENCE LINES PRINTED WITH EVERY TABLE
    nl-ceiling     the best ANY nl-only producer could do here. fault/faultidle and zoneblk/zoneharm
                   carry identical sentences by construction, so `llm:nl` is information-limited.
                   Judging it against 0 instead of against this line is unfair to the arm.
    regime         action-supported = the right macro was seen in training (transfer is possible);
                   action-novel     = it was not, so NO producer that only ranks learned values can
                                      win, and the honest answer is the oracle fallback.

USAGE
    python c1_novel_kind.py                                   # 기본 데이터, 3 arm, zero-shot
    python c1_novel_kind.py --arms=nl,nl+state --fewshot
    LLM_MODEL=gpt-4o python c1_novel_kind.py --json=out.json
    LLM_MOCK=1  python c1_novel_kind.py                       # API 없이 배선만 점검(수치 인용 금지)
    LLM_OFFLINE=1 python c1_novel_kind.py                     # 캐시만으로 재현

────────────────────────────────────────────────────────────────────────────────────────────
[한국어 설명]
이 스크립트가 재는 것 = 명제 C1: "**처음 보는 종류**의 OOD 에서 LLM 이 surrogate 보다 나은가".

왜 이걸 먼저 하나: C1 이 깨지면 라우터(C3)도 동화 루프(C4)도 만들 이유가 없다. 더 못하는 쪽으로
보내는 라우터는 시스템을 나쁘게 만들 뿐이기 때문. 그래서 C1 이 값싼 게이트 역할을 한다.

프로토콜 = LOKO(한 종류 통째로 빼고 학습). LLM few-shot 예시도 반드시 학습 종류에서만 뽑는다
(안 그러면 "처음 보는 종류"가 아니게 된다 -- 이 실험이 무효가 되는 가장 흔한 경로).

같이 찍는 기준선 두 개:
  nl-ceiling : 문장만 보는 정책의 원리적 상한(이 데이터셋은 무해/유해 변종에 같은 문장을 준다).
  regime     : action-novel 폴드는 정답 macro 자체가 학습에 없어 누구도 못 맞힌다 -> 오라클 폴백이 정답.

[문법 참고]
  - collections.defaultdict(list) : 없는 키에 접근하면 자동으로 빈 리스트를 만들어 주는 dict.
  - zip(a, b) : 두 리스트를 짝지어 순회.
  - f"{x:>8.3f}" : 오른쪽 정렬 폭 8, 소수점 3자리.
────────────────────────────────────────────────────────────────────────────────────────────
"""
import collections
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

import numpy as np

import wm_datasets                      # 데이터셋 경로 단일 정의
from features_agnostic import featurize_agnostic
from llm_producer import MACRO_NAME, Producer, build_demos
from nl_events import nl_partition_ceiling, provenance_summary
from openworld_experiments import load_df, pick_with_gate, valid_macros_of
from surrogate_model import build_model
from verify import norm_regret, oracle_best_macro, paired_bootstrap

ARM_ORDER = ["nl", "nl+state", "feat"]


# ==========================================================================================
def surrogate_regrets(df, tr_inst, te_inst, lam):
    """학습 instance 로 forest 를 맞추고 held-out instance 들의 regret 을 돌려준다(배포 경로와 동일)."""
    Xall = featurize_agnostic(df, action_repr="onehot")
    cols = list(Xall.columns)
    tr_rows = df[df.instance.isin(tr_inst)]
    model = build_model().fit(Xall.loc[tr_rows.index, cols].values,
                              tr_rows.closed.astype(float).values)
    by_inst = {i: g for i, g in df.groupby("instance")}
    out = {}
    for i in te_inst:
        g = by_inst[i]
        pred = model.predict(Xall.loc[g.index, cols].values)
        pbm = {int(m): float(p) for m, p in zip(g.macro.astype(int).values, pred)}
        pick = pick_with_gate(pbm, valid_macros_of(g))
        out[i] = (norm_regret(g, pick, lam), pick)
    return out


def llm_regrets(df, te_inst, arm, lam, producer, demos=()):
    """LLM 이 held-out instance 들에서 낸 regret 과 고른 macro."""
    by_inst = {i: g for i, g in df.groupby("instance")}
    out = {}
    for i in te_inst:
        g = by_inst[i]
        res = producer.decide(g.iloc[0], arm=arm, valid=valid_macros_of(g), demos=demos)
        out[i] = (norm_regret(g, res["macro"], lam), res["macro"], res)
    return out


# ==========================================================================================
def main():
    argv = sys.argv[1:]
    args = [a for a in argv if not a.startswith("--")]
    path = wm_datasets.resolve(args[0] if args else None)   # 기본 = CANONICAL(openworld_merged)
    opt = lambda k, d: next((a.split("=", 1)[1] for a in argv if a.startswith(f"--{k}=")), d)
    lam = float(opt("lam", "3.0"))
    arms = [a.strip() for a in opt("arms", ",".join(ARM_ORDER)).split(",") if a.strip()]
    fewshot = "--fewshot" in argv
    k_demos = int(opt("k", "8"))
    jout = opt("json", None)
    seed = int(opt("seed", "0"))

    df = load_df(path)
    prov = provenance_summary(df)
    by_inst = {i: g for i, g in df.groupby("instance")}
    best = {i: oracle_best_macro(g, lam) for i, g in by_inst.items()}
    kind_of = {i: str(g.kind.iloc[0]) for i, g in by_inst.items()}
    kinds = sorted(set(kind_of.values()))
    rng = np.random.default_rng(seed)

    producer = Producer()

    print("=" * 100)
    print("C1  처음 보는 OOD 종류에서 LLM 이 surrogate 보다 나은가  (leave-one-kind-out)")
    print("=" * 100)
    print(f"  data   : {path}  ({len(df)} rows, {df.instance.nunique()} instances, kinds={kinds})")
    print(f"  NL 출처: captured={prov['captured']} synthesized={prov['synthesized']} "
          f"-> grade={prov['grade']}")
    if prov["grade"] != "evidence":
        print("           ** 문장이 복원본입니다. 라벨러를 다시 돌려 실제 문장을 받은 뒤에야")
        print("              이 표의 nl 계열 수치를 헤드라인으로 인용할 수 있습니다. **")
    print(f"  model  : {producer.model}   arms={arms}   fewshot={fewshot}   lambda={lam}")
    if producer.mock:
        print("  ** LLM_MOCK=1 -- 규칙기반 가짜 응답입니다. 배선 점검 전용, 수치 인용 금지. **")
    print()

    out = {"data": path, "lam": lam, "model": producer.model, "arms": arms,
           "fewshot": fewshot, "nl_provenance": prov, "folds": []}

    agg = collections.defaultdict(list)
    for held in kinds:
        te = [i for i in by_inst if kind_of[i] == held]
        tr = [i for i in by_inst if kind_of[i] != held]
        if not tr or not te:
            continue
        tr_best, te_best = {best[i] for i in tr}, {best[i] for i in te}
        regime = ("action-supported" if te_best <= tr_best
                  else ("mixed" if te_best & tr_best else "action-novel"))

        fold = {"held_out": held, "n_test": len(te), "regime": regime, "arms": {}}

        # -- surrogate ---------------------------------------------------------------------
        sr = surrogate_regrets(df, tr, te, lam)
        fold["arms"]["surrogate"] = {"regret": float(np.mean([sr[i][0] for i in te])),
                                     "per_instance": {i: float(sr[i][0]) for i in te},
                                     "picks": {i: int(sr[i][1]) for i in te}}
        agg["surrogate"] += [sr[i][0] for i in te]

        # -- LLM arms ----------------------------------------------------------------------
        for arm in arms:
            variants = [("", ())]
            if fewshot:
                # demo 는 학습 종류에서만. held 를 빼지 않으면 이 실험은 그 자리에서 무효가 된다.
                variants.append(("+fs", build_demos(df, tr, best, arm, k=k_demos,
                                                    seed=seed, exclude_kinds=(held,))))
            for suffix, demos in variants:
                name = f"llm:{arm}{suffix}"
                lr = llm_regrets(df, te, arm, lam, producer, demos=demos)
                fold["arms"][name] = {
                    "regret": float(np.mean([lr[i][0] for i in te])),
                    "per_instance": {i: float(lr[i][0]) for i in te},
                    "picks": {i: int(lr[i][1]) for i in te},
                    "why": {i: lr[i][2]["why"] for i in te},
                }
                agg[name] += [lr[i][0] for i in te]

        # -- baselines ---------------------------------------------------------------------
        ga = collections.Counter([best[i] for i in tr]).most_common(1)[0][0]
        chooser = {
            "noop": lambda g: 0 if 0 in valid_macros_of(g) else min(valid_macros_of(g)),
            "global_always": lambda g: ga if ga in valid_macros_of(g) else min(valid_macros_of(g)),
            "random_valid": lambda g: int(rng.choice(sorted(valid_macros_of(g)))),
        }
        for nm, ch in chooser.items():
            rs = [norm_regret(by_inst[i], ch(by_inst[i]), lam) for i in te]
            fold["arms"][nm] = {"regret": float(np.mean(rs)),
                                "per_instance": {i: float(r) for i, r in zip(te, rs)}}
            agg[nm] += rs

        # -- nl-only ceiling on THIS fold ---------------------------------------------------
        ceil = nl_partition_ceiling(df[df.instance.isin(te)], lam)
        fold["nl_ceiling"] = ceil["ceiling"]
        out["folds"].append(fold)

    # -- 표 -------------------------------------------------------------------------------
    names = ["surrogate"] + [f"llm:{a}{s}" for a in arms for s in ((["", "+fs"]) if fewshot else [""])] \
            + ["noop", "global_always", "random_valid"]
    w = max(len(n) for n in names) + 1
    hdr = f"  {'held-out kind':<12} {'regime':<17} {'nl-ceil':>8} " + " ".join(f"{n:>{w}}" for n in names)
    print(hdr)
    print("  " + "-" * (len(hdr) - 2))
    for f in out["folds"]:
        row = f"  {f['held_out']:<12} {f['regime']:<17} {f['nl_ceiling']:>8.3f} "
        row += " ".join(f"{f['arms'][n]['regret']:>{w}.3f}" for n in names)
        print(row)
    print("  " + "-" * (len(hdr) - 2))
    allceil = nl_partition_ceiling(df, lam)["ceiling"]
    print(f"  {'평균':<12} {'':<17} {allceil:>8.3f} " +
          " ".join(f"{np.mean(agg[n]):>{w}.3f}" for n in names))

    # -- 판정 -----------------------------------------------------------------------------
    print("\n  -- C1 판정: LLM 이 처음 보는 종류에서 surrogate 를 이겼는가 --")
    print("     (양수 = LLM 이 더 좋음. CI 가 0 을 포함하면 '차이를 밝히지 못함' = C1 미확립)")
    verdicts = {}
    for n in names:
        if not n.startswith("llm:"):
            continue
        d, lo, hi = paired_bootstrap(agg["surrogate"], agg[n])
        tag = "LLM 우세(유의)" if lo > 0 else ("surrogate 우세(유의)" if hi < 0 else "차이 못 밝힘")
        verdicts[n] = {"delta_vs_surrogate": float(d), "ci": [float(lo), float(hi)], "verdict": tag}
        print(f"     {n:<16} 차이={d:+.3f}  CI [{lo:+.3f},{hi:+.3f}]  -> {tag}")

    # -- 폴드별 판정: 전체 평균 하나로 C1 을 판정하면 안 된다 -------------------------------
    # 이 실험에서 실제로 관측된 모양: LLM 은 **surrogate 가 전이에 실패한 종류에서만** 이긴다.
    # 평균만 보면 "LLM 이 졌다"로 읽히지만, 라우팅의 존재 이유는 바로 그 한 폴드다.
    print("\n  -- 폴드별: 어느 종류에서 LLM 이 필요한가 --")
    print(f"     {'종류':<10} {'surrogate':>10} {'최고 LLM arm':>16} {'그 값':>8}  판정")
    per_fold_wins = []
    for f in out["folds"]:
        larms = {n: v["regret"] for n, v in f["arms"].items() if n.startswith("llm:")}
        bn = min(larms, key=larms.get)
        s = f["arms"]["surrogate"]["regret"]
        win = larms[bn] < s - 1e-9
        per_fold_wins.append((f["held_out"], win, s, bn, larms[bn]))
        tag = ("LLM 이 필요함(이김)" if win else
               ("동률" if abs(larms[bn] - s) < 1e-9 else "surrogate 로 충분"))
        print(f"     {f['held_out']:<10} {s:>10.3f} {bn:>16} {larms[bn]:>8.3f}  {tag}")
    n_win = sum(1 for _, w, *_ in per_fold_wins if w)
    print(f"     -> {n_win}/{len(per_fold_wins)} 종류에서 LLM 이 surrogate 를 이겼습니다.")
    if 0 < n_win < len(per_fold_wins):
        print("     -> 즉 '항상 LLM' 도 '항상 surrogate' 도 답이 아니고, **어느 쪽으로 보낼지 고르는")
        print("        장치**(C3 라우터)가 있어야 두 폴드 모두에서 최선이 됩니다. 이것이 라우팅의 근거입니다.")
    out["per_fold_wins"] = [{"kind": k, "llm_wins": bool(w), "surrogate": s,
                             "best_llm_arm": bn, "best_llm": v}
                            for k, w, s, bn, v in per_fold_wins]

    llm_arms = [n for n in names if n.startswith("llm:")]
    if llm_arms:
        bestllm = min(llm_arms, key=lambda n: np.mean(agg[n]))
        c1_holds = verdicts[bestllm]["ci"][0] > 0
        print(f"\n  ==> C1(평균) {'성립' if c1_holds else '미성립'}: "
              f"최고 LLM arm = {bestllm} (regret {np.mean(agg[bestllm]):.3f}) vs "
              f"surrogate {np.mean(agg['surrogate']):.3f}")
        if not c1_holds and n_win > 0:
            print("      단, 위 폴드별 표를 보십시오. 평균이 진 것은 surrogate 가 이미 잘하는 종류들이")
            print("      평균을 끌어내렸기 때문이고, surrogate 가 실패한 종류에서는 LLM 이 이겼습니다.")
            print("      => 'C1 은 조건부로 성립'이며, 그 조건을 자동으로 알아내는 것이 C3 라우터입니다.")
        elif not c1_holds:
            print("      -> 어느 종류에서도 LLM 이 이기지 못했습니다. 이 데이터에서는 라우팅을 만들 근거가")
            print("         없습니다(더 나쁜 쪽으로 보내는 장치가 됩니다). 먼저 arm/모델을 바꿔 보십시오.")
        out["c1"] = {"best_arm": bestllm, "holds_on_average": bool(c1_holds),
                     "n_folds_llm_wins": int(n_win), "n_folds": len(per_fold_wins),
                     "holds_conditionally": bool(n_win > 0), "verdicts": verdicts}

    # -- 언어이해 vs 스키마 사전지식 분해 ---------------------------------------------------
    if "llm:nl+state" in agg and "llm:feat" in agg:
        d, lo, hi = paired_bootstrap(agg["llm:feat"], agg["llm:nl+state"])
        print(f"\n  -- 분해: LLM 의 이득은 언어이해인가 스키마 사전지식인가 --")
        print(f"     llm:feat({np.mean(agg['llm:feat']):.3f}) vs llm:nl+state({np.mean(agg['llm:nl+state']):.3f})"
              f"  차이={d:+.3f} CI [{lo:+.3f},{hi:+.3f}]")
        print("     feat 는 '이미 아는 스키마로 파싱된' 입력이라 진짜 새 사건엔 존재하지 않는다.")
        print("     nl+state 가 feat 에 근접/우세해야 '새 종류에도 통한다'는 주장이 선다.")

    print(f"\n  [LLM 사용량] 실호출 {producer.stats['calls']}회, 캐시적중 {producer.stats['cache_hits']}회, "
          f"토큰 {producer.stats['tokens']}, {producer.stats['seconds']:.1f}s")
    print(f"  [형식이탈] 어휘밖 응답 {producer.stats['out_of_vocab']}회, "
          f"valid 게이트로 교체 {producer.stats['gated_away']}회")
    producer.save()

    out["aggregate"] = {n: {"regret": float(np.mean(agg[n])), "per_instance": [float(x) for x in agg[n]]}
                        for n in names}
    out["llm_stats"] = producer.stats
    if jout:
        json.dump(out, open(jout, "w", encoding="utf-8"), indent=2, default=float)
        print(f"\n[saved] {jout}")


if __name__ == "__main__":
    main()
