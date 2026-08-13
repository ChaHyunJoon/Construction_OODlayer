#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
STEP 6 재집계 — 옵션(macro) 제한의 대가  V^macro − V*  (설계 §4.4)

이전 판(K=2)의 결론이 쓸 수 없었던 이유:
  seed 2 의 "최선 확장 arm" 이 10(Replace@after=0)이었는데, 이는 macro 1 과
  **정의상 동일한 행동**이다. 즉 관측된 gap 0.66 은 실제 gap 이 아니라 몬테카를로 노이즈.

이번 판의 교정:
  1) K=4 로 올려 rollout 평균의 분산을 낮춘다.
  2) arm 10 을 **노이즈 대조군**으로 명시한다. 1 과 10 은 같은 정책이므로 그 둘 사이의
     차이는 **참 gap 이 0 인 쌍에서 측정된 노이즈**다. 확장 arm 의 gap 이 이 바닥을
     넘지 못하면 "gap 관측 안 됨" 이다.
  3) CRN(같은 rollout k = 같은 hazard seed)이므로 **짝지은 차이**로 검정한다.

측정된 gap 은 여전히 **진짜 gap 의 하한**이다 — 원시 배정공간 전체가 아니라 옵션의
연속 파라미터만 열었기 때문.
"""
import csv, glob, json, os, sys
import numpy as np

# 목적함수 상수/해시의 단일 진실원. 이 스크립트는 CSV 의 `cost` 열을 평균하는데, 그 열이 어느 J 로
# 계산됐는지는 `objective_hash` 열에만 적혀 있다 — 세대가 섞인 CSV 를 그냥 평균하면 gap 이
# 아무것도 뜻하지 않게 된다(spec §7).
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                "wm4spacecraft_manufacturing"))
import objective  # noqa: E402

MACRO = {0, 1, 2, 3, 4}
CONTROL_PAIR = (1, 10)          # 정의상 동일한 두 arm
NAME = {0: "NOOP", 1: "Replace(macro)", 10: "Replace@0 [대조군]", 11: "Replace@5",
        12: "Replace@15", 20: "Deprio x10", 21: "Deprio x50", 22: "Deprio x200"}

PAT = sys.argv[1] if len(sys.argv) > 1 else "oracle/out/oracle_mc_units_s*_s6b_*.csv"


def load(pattern):
    rows = []
    stale = {}          # 파일 -> 그 파일에서 본 (현행이 아닌) objective_hash 들
    cur = objective.objective_hash()
    for f in sorted(glob.glob(pattern)):
        base = os.path.basename(f)
        seed = base.split("_s")[1].split("_")[0]
        with open(f, encoding="utf-8") as fh:
            for r in csv.DictReader(fh):
                # 해시 수집은 아래 try 밖이다 — 안에 두면 `except Exception: pass` 가 가드를
                # 통째로 삼켜 조용히 넘어간다.
                h = (r.get("objective_hash") or "<none>").strip()
                if h != cur:
                    stale.setdefault(f, set()).add(h)
                try:
                    rows.append(dict(seed=seed, action=int(r["action"]), rollout=int(r["rollout"]),
                                     cost=float(r["cost"]), complete=r["complete"] == "true",
                                     closed=int(r["closed"]), total=int(r["total"]),
                                     hz_break=int(r["hz_break"]), hz_capped=r["hz_capped"] == "true"))
                except Exception:
                    pass
    if stale:
        lines = "\n".join("  %s : objective_hash=%s" % (f, ", ".join(sorted(hs)))
                           for f, hs in sorted(stale.items()))
        saw_none = any("<none>" in hs for hs in stale.values())
        raise objective.ObjectiveError(
            "[step6] 이 CSV 들은 현행 목적함수(objective_hash=%s)로 계산된 cost 가 아니다:\n%s\n%s"
            "조치: (1) 그 CSV 를 빼고 현행 J 로 유닛을 다시 돌린다, 또는 (2) 그 세대를 재현하려면\n"
            "      당시의 ENV(MC_COST_FAIL/MC_COST_UNCLOSED)와 objective.json 을 되돌린다.\n"
            "다른 J 로 계산된 cost 를 섞어 gap 을 재지 않는다 (spec §7)."
            % (cur, lines,
               "'<none>' = objective_hash 열이 생기기 전의 구세대 CSV.\n" if saw_none else ""))
    # (seed, action, rollout) 중복 제거 — 재실행분이 조용히 두 번 세어지면 Q̂ 가 틀어진다
    seen = {}
    for r in rows:
        seen[(r["seed"], r["action"], r["rollout"])] = r
    dropped = len(rows) - len(seen)
    if dropped:
        print(f"[주의] 중복 유닛 {dropped}개 제거")
    return list(seen.values())


def se(v):
    v = np.asarray(v, float)
    return float(np.std(v, ddof=1) / np.sqrt(len(v))) if len(v) > 1 else float("nan")


def main():
    rows = [r for r in load(PAT) if r["rollout"] > 0]
    print(f"읽은 행 {len(rows)}개  (패턴: {PAT})")
    if not rows:
        print("STEP 6 데이터 없음.")
        return
    seeds = sorted({r["seed"] for r in rows})
    K = max(r["rollout"] for r in rows)
    print(f"seed {seeds}, K(최대 rollout) = {K}")
    print(f"완주율 {np.mean([r['complete'] for r in rows]):.1%}, "
          f"hazard 상한 도달 {sum(r['hz_capped'] for r in rows)}건")

    out = {"seeds": {}, "noise_floor": [], "gaps": []}

    for seed in seeds:
        g = [r for r in rows if r["seed"] == seed]
        byk = {}
        for r in g:
            byk.setdefault(r["action"], {})[r["rollout"]] = r["cost"]
        Q = {a: float(np.mean(list(v.values()))) for a, v in byk.items()}
        if not Q:
            continue
        mac = {a: v for a, v in Q.items() if a in MACRO}
        if not mac:
            continue
        best_mac = min(mac, key=mac.get)
        v_mac, v_ext = min(mac.values()), min(Q.values())
        best_ext = min(Q, key=Q.get)
        gap = v_mac - v_ext

        # ---- 노이즈 바닥: 같은 정책(1 vs 10)의 짝지은 차이 ----
        a1, a2 = CONTROL_PAIR
        nf, nf_se = float("nan"), float("nan")
        if a1 in byk and a2 in byk:
            ks = sorted(set(byk[a1]) & set(byk[a2]))
            if ks:
                d = np.array([byk[a2][k] - byk[a1][k] for k in ks], float)
                nf, nf_se = float(np.mean(np.abs(d))), se(d)
                out["noise_floor"].append(dict(seed=seed, mean_abs_diff=nf,
                                               se_paired=nf_se, n=len(ks)))

        # ---- 최선 확장 arm 이 최선 macro arm 을 짝지어 이기는가 ----
        ks = sorted(set(byk.get(best_ext, {})) & set(byk.get(best_mac, {})))
        d = np.array([byk[best_ext][k] - byk[best_mac][k] for k in ks], float) if ks else np.array([])
        d_mean = float(np.mean(d)) if len(d) else float("nan")
        d_se = se(d) if len(d) > 1 else float("nan")
        sig = bool(len(d) > 1 and np.isfinite(d_se) and d_se > 0 and abs(d_mean) > 1.96 * d_se)
        dup = best_ext in CONTROL_PAIR and best_mac in CONTROL_PAIR

        print("\n" + "=" * 82)
        print(f"seed {seed}")
        print(f"  {'arm':>22} {'Q̂':>12} {'SE':>10} {'완주율':>8}")
        for a in sorted(Q):
            cs = [r["complete"] for r in g if r["action"] == a]
            print(f"  {NAME.get(a, 'arm'+str(a)):>22} {Q[a]:>12.2f} "
                  f"{se(list(byk[a].values())):>10.2f} {np.mean(cs):>8.0%}")
        print(f"  V^macro = {v_mac:.2f} (arm {best_mac})   V*(ext) = {v_ext:.2f} (arm {best_ext})"
              f"   gap = {gap:.2f}")
        print(f"  노이즈 바닥 |Q̂(1)−Q̂(10)| 짝지은 평균 = {nf:.2f} (SE {nf_se:.2f}, n={len(ks)})")
        if dup:
            print("  → 최선 확장 arm 이 대조군 쌍 안에 있다 = **동일 정책**. gap 은 정의상 0.")
        elif sig:
            print(f"  → 짝지은 차이 {d_mean:.2f} ± {d_se:.2f} : **유의** (|Δ| > 1.96·SE)")
        else:
            print(f"  → 짝지은 차이 {d_mean:.2f} ± {d_se:.2f} : 유의하지 않음 = gap 관측 안 됨")

        out["seeds"][seed] = dict(v_macro=v_mac, v_ext=v_ext, gap=gap, best_macro=best_mac,
                                  best_ext=best_ext, paired_diff=d_mean, paired_se=d_se,
                                  significant=sig, duplicate_policy=dup, noise_floor=nf)
        out["gaps"].append(0.0 if dup else max(0.0, gap))

    print("\n" + "=" * 82)
    print("STEP 6 결론")
    if out["gaps"]:
        nf_all = [x["mean_abs_diff"] for x in out["noise_floor"] if np.isfinite(x["mean_abs_diff"])]
        print(f"  평균 gap = {np.mean(out['gaps']):.2f}  (동일-정책 쌍은 0 으로 강제)")
        if nf_all:
            print(f"  노이즈 바닥 평균 = {np.mean(nf_all):.2f}")
            print(f"  → gap 이 노이즈 바닥보다 "
                  f"{'크다 = 옵션 제한의 대가가 관측됨' if np.mean(out['gaps']) > np.mean(nf_all) else '작다 = 이 파라미터 범위에서 옵션 제한의 대가 관측 안 됨'}")
        n_sig = sum(1 for v in out["seeds"].values() if v["significant"] and not v["duplicate_policy"])
        print(f"  유의한 gap 을 보인 seed = {n_sig}/{len(out['seeds'])}")
    print("  주의: A_ext 는 옵션의 연속 파라미터만 연 것이므로 이 gap 은 진짜 gap 의 **하한**이다.")
    json.dump(out, open("artifacts_mdp/step6b_gap.json", "w", encoding="utf-8"),
              indent=2, ensure_ascii=False)
    print("  -> artifacts_mdp/step6b_gap.json")


if __name__ == "__main__":
    main()
