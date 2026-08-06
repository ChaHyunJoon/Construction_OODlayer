#!/usr/bin/env python
"""morning_report.py -- 밤새 생성된 데이터를 아침에 **한 명령**으로 판정한다.

핵심 질문 하나: **창 [55,130] 교정이 동점을 실제로 깼는가?**

2026-08-02 밤에 실측으로 확인된 기전:
    창 [8,60]   -> 완주 26% -> 동점 53%   (기존 ep_[abg])
    창 [70,230] -> 완주  5% -> 동점 85%   (기존 ep2, 현재 막힌 평가셋)
동점은 우연이 아니라 **모든 팔이 미완주로 같은 지점에서 죽어 unclosed 까지 같아지기** 때문에
생긴다. 따라서 동점률은 완주율의 함수이고, 창을 당기면 완주율이 올라가 동점이 깨져야 한다.
이 스크립트는 새 데이터에서 그 예측을 검정한다.

판정 트리 (md/README.md §STEP 8)
    동점률 < 40%  -> 성공. T1/Router/G1·G2 재측정 착수
    40~60%        -> 부분 성공. 유효 n 확인, 부족하면 seed 추가
    > 60%         -> 실패. 창이 아니라 과제 설계 문제 -> DS_SPARES 를 조여 팔을 가른다

실행
    PYTHONIOENCODING=utf-8 python morning_report.py
    PYTHONIOENCODING=utf-8 python morning_report.py --new 'oracle/out/hz_k1/ep_s*.jsonl'
"""
import os, sys, json, argparse, subprocess
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

import numpy as np

from value_two_layer import decompose_rollouts, load_rows, tie_split
from baselines_eval import group_by_instance, kind_of, pol_oracle

HERE = os.path.dirname(os.path.abspath(__file__))


def profile(pattern, label):
    """한 데이터셋의 요약. 없으면 None."""
    rows = load_rows(pattern)
    if not rows:
        print(f"  [{label}] 데이터 없음 ({pattern})")
        return None
    agg = decompose_rollouts(rows)
    groups = group_by_instance(agg)
    agg = [r for r in agg if r["instance"] in groups]
    if not agg:
        print(f"  [{label}] 유효 instance 없음")
        return None
    dec, tied = tie_split(agg)
    n = len(dec) + len(tied)
    pc = np.array([r["p_complete"] for r in agg], float)
    taus = [float(r.get("tau_to_next", -1)) for r in rows if r.get("tau_to_next") is not None]
    taus = [t for t in taus if t >= 0]
    ndec = [int(r.get("n_decisions", 0)) for r in rows]
    ls = np.array([float(r.get("label_seconds", np.nan)) for r in rows], float)
    ls = ls[np.isfinite(ls)]
    out = {
        "label": label, "pattern": pattern,
        "n_rollout_rows": len(rows), "n_cells": len(agg), "n_instances": n,
        "n_decisive": len(dec), "n_tied": len(tied),
        "tie_rate": len(tied) / max(1, n),
        "completion_cell_rate": float((pc > 0).mean()),
        "kinds": dict(Counter(kind_of(g) for g in groups.values())),
        "kinds_decisive": dict(Counter(kind_of(groups[i]) for i in dec)),
        "best_macro_decisive": dict(Counter(pol_oracle(None, groups[i]) for i in dec)),
        "tau_median": float(np.median(taus)) if taus else None,
        "tau_zero_frac": float(np.mean([t == 0 for t in taus])) if taus else None,
        "decisions_per_episode": dict(Counter(ndec)),
        "label_seconds_median": float(np.median(ls)) if ls.size else None,
    }
    print(f"\n  [{label}]  instance {n} · 결정적 {len(dec)} · 동점 {out['tie_rate']:.0%} · "
          f"완주셀 {out['completion_cell_rate']:.0%}")
    print(f"      종류 {out['kinds']}  |  결정적만 {out['kinds_decisive']}")
    print(f"      정답 macro(결정적) {out['best_macro_decisive']}")
    print(f"      τ 중앙 {out['tau_median']} · τ=0 비율 "
          f"{'-' if out['tau_zero_frac'] is None else format(out['tau_zero_frac'], '.0%')}"
          f" · 결정수 분포 {out['decisions_per_episode']}")
    return out


def verdict(new, olds):
    print("\n" + "=" * 78)
    print("판정")
    print("=" * 78)
    if new is None:
        print("  새 데이터가 없다. 야간 잡 로그를 먼저 볼 것: oracle/out/hz_k1/run_night_k1.log")
        return "NO_DATA"

    print(f"  {'데이터셋':<22}{'창':>12}{'완주셀':>9}{'동점':>8}{'결정적 n':>10}")
    for o in olds + [new]:
        if o:
            print(f"  {o['label']:<22}{o.get('window','?'):>12}"
                  f"{o['completion_cell_rate']:>9.0%}{o['tie_rate']:>8.0%}{o['n_decisive']:>10}")

    tr, nd = new["tie_rate"], new["n_decisive"]
    print()
    if tr < 0.40:
        v = "SUCCESS"
        print(f"  ✔ 동점 {tr:.0%} < 40% — 창 교정이 동점을 깼다.")
        print("    다음: T1(φ 충분성) · Router · G1/G2 를 이 데이터에서 재측정.")
    elif tr <= 0.60:
        v = "PARTIAL"
        print(f"  △ 동점 {tr:.0%} (40~60%) — 부분 성공. 결정적 n={nd}.")
        print("    다음: n<30 이면 seed 를 더 돌린다(같은 스크립트 재실행 = 이어서 생성).")
    else:
        v = "FAIL"
        print(f"  ✘ 동점 {tr:.0%} > 60% — 창 교정만으로는 부족하다.")
        print("    다음: 창이 아니라 과제 설계를 건드린다. DS_SPARES 를 3->1 로 조여")
        print("          '스페어를 지금 쓸 것인가'가 팔을 가르게 만든다.")

    # ---- 두 번째 기준: 완주율 --------------------------------------------------------
    # 동점률만 보면 놓치는 것이 있다. 모든 팔이 미완주여도 unclosed 가 다르면 동점은 깨진다.
    # 그러면 평가셋은 "누가 완주하나"가 아니라 "누가 더 늦게 죽나"를 재게 되고,
    #   · 2층 분해가 p≡0 으로 퇴화하며(완주확률 헤드가 상수)
    #   · SSP 비용의 사전식 1순위(완주)가 한 번도 행사되지 않는다.
    # 즉 동점이 깨져도 **문제가 바뀌어 있다**. 그래서 완주율을 따로 건다.
    cr = new["completion_cell_rate"]
    if cr <= 0.0:
        print(f"\n  ✘ 완주셀 0% — 동점이 깨졌더라도 이 평가셋은 '누가 더 늦게 죽나'만 잰다.")
        print("    2층 분해는 p≡0 으로 퇴화하고 완주 기준(SSP 1순위)이 행사되지 않는다.")
        print("    조치: 창을 더 당기거나(EP_HI 100 이하) 사건 수를 3→2 로 줄여 회복 여지를 준다.")
        v = "TIES_BROKEN_BUT_NO_COMPLETION" if v == "SUCCESS" else v
    elif cr < 0.20:
        print(f"\n  △ 완주셀 {cr:.0%} (<20%) — 완주 사례가 희박하다. 완주 기준을 재려면 표본이 더 필요하다.")

    if nd < 30:
        print(f"\n  !! 결정적 n={nd} < 30 — 어떤 우열도 **판정하지 말 것**(함정 14).")
    if new.get("tau_zero_frac") not in (None,) and new["tau_zero_frac"] > 0.5:
        print(f"  !! τ=0 비율 {new['tau_zero_frac']:.0%} — 결정이 한 스텝에 몰렸다. SMDP sojourn 무의미.")
    if "fault" not in new["kinds"]:
        print("  !! fault 사건이 하나도 없다 — 창이 너무 늦어 solo 타깃이 사라졌을 수 있다(함정 7).")
    return v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--new", default="oracle/out/hz_k1/ep_s*.jsonl")
    ap.add_argument("--hazard", default="oracle/out/hz_v1/smoke_s*.jsonl")
    ap.add_argument("--run-baselines", action="store_true",
                    help="새 데이터에서 baselines_eval 까지 돌린다(수 분 소요).")
    ap.add_argument("--out", default="artifacts_mdp/morning_report.json")
    args = ap.parse_args()

    print("=" * 78)
    print("아침 리포트 — 창 [55,130] 교정 검정")
    print("=" * 78)

    olds = []
    for pat, lab, win in [("oracle/out/ep_[abg]*.jsonl", "기존 ep (K=1)", "[8,60]"),
                          ("oracle/out/ep2_*.jsonl", "기존 ep2 (K=1)", "[70,230]")]:
        o = profile(pat, lab)
        if o:
            o["window"] = win
            olds.append(o)

    new = profile(args.new, "신규 hz_k1 (K=1)")
    if new:
        new["window"] = "[55,130]"
    hz = profile(args.hazard, "신규 hazard (K=3)")
    if hz:
        hz["window"] = "[55,130]"
        pc = hz["completion_cell_rate"]
        print(f"      hazard 팔: 확률적 라벨이 실제로 생겼는가 -> "
              f"P(complete)∈(0,1) 셀이 있어야 2층 분해의 전제가 산다")

    v = verdict(new, olds)

    res = {"verdict": v, "new": new, "hazard": hz, "olds": olds}
    outp = os.path.join(HERE, args.out)
    os.makedirs(os.path.dirname(outp), exist_ok=True)
    json.dump(res, open(outp, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
    print(f"\nwrote {outp}")

    if args.run_baselines and new:
        print("\n" + "=" * 78)
        print("베이스라인 (새 데이터)")
        print("=" * 78)
        env = dict(os.environ, PYTHONIOENCODING="utf-8")
        subprocess.run([sys.executable, os.path.join(HERE, "baselines_eval.py"),
                        "--glob", args.new, "--phi", "full",
                        "--out", "artifacts_mdp/baselines_hz_k1.json"], env=env, cwd=HERE)
    return 0


if __name__ == "__main__":
    sys.exit(main())
