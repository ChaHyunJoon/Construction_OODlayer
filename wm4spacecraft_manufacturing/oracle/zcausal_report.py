#!/usr/bin/env python3
# =============================================================================
# zcausal_report.py -- STEP 10 채점기: "막힘 술어가 고른 구역은 정말 결정을 만드는가".
#
# 무엇을 재는가
# -------------
# tools/restage.jl causal 이 팔(arm)마다 한 줄씩 남긴 JSON 을 모아, 구역 **가족**별로
# 최선 팔을 뽑고 그 분포의 엔트로피 H(best|zone) 를 계산한다. STEP 6 의 합격 기준을 그대로 쓴다:
#
#   (1) H(best|zone) > 0        — kind 안에서 정답이 갈릴 것(갈리지 않으면 결정 문제가 아니다)
#   (2) 동점률 < 30%
#   (3) 격차가 regret 으로 드러날 것 (완주 여부 → closed → makespan 의 사전순)
#
# 최선 판정은 **feasibility 우선 사전순**이다: 완주(complete) > 더 많이 닫음(closed) >
# 더 짧은 makespan. 완주하지 못한 팔은 makespan 이 유한해도 절대 이기지 못한다 —
# 이 순서를 뒤집으면 "빨리 실패하는 팔"이 우승하는 고전적 함정에 빠진다.
#
# 사용:
#   python oracle/zcausal_report.py [out_dir]        (기본 oracle/out/zcausal)
# =============================================================================
import json
import math
import os
import sys
from collections import defaultdict

FAMILY = {
    "blk": "blocking(zone on a NAV goal)",          # 막힘>0  — 인과 규칙만 개입이라 답한다
    "cov": "core zone(root goals)",                 # 커버리지 8/8, 막힘은 작다
    "harmless": "harmless(covers, blocks nothing)",  # 커버리지>0, 막힘=0 — 두 규칙이 반대로 답한다
}
ARM_LABEL = {"noop": "NOOP", "reloc": "RelocateBuild", "forbid": "ForbidZone"}


def load(d):
    rows = []
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".json"):
            continue
        with open(os.path.join(d, fn)) as f:
            for line in f:
                line = line.strip()
                if line:
                    rows.append(json.loads(line))
    return rows


def key(r):
    """정렬 키: 완주 여부 > 닫은 노드 수 > (짧은) makespan. 클수록 좋다."""
    complete = 1 if r["status"] == "complete" else 0
    return (complete, r["closed"], -r["makespan"])


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "out", "zcausal")
    rows = load(d)
    if not rows:
        print(f"[zcausal] {d} 에 결과가 없다")
        return
    fams = defaultdict(dict)
    control = None
    for r in rows:
        arm = r["arm"]
        if arm == "control":
            control = r
            continue
        fam, _, sub = arm.partition("_")
        fams[fam][sub] = r

    print(f"[data] {len(rows)} row(s) from {d}")
    if control:
        print(f"[control] OOD 없음: status={control['status']} closed={control['closed']}/{control['total']} "
              f"makespan={control['makespan']}")
    print()
    bests, ties = [], 0
    for fam, arms in sorted(fams.items()):
        print(f"=== {FAMILY.get(fam, fam)} ===")
        any_row = next(iter(arms.values()))
        print(f"    진단: root_covered={any_row['root_covered']} "
              f"nav_blocked={any_row['nav_blocked']} "
              f"(engulf={any_row['nav_engulfed']} disc={any_row['nav_disconnected']}) "
              f"verdict={any_row['verdict']}  fired_at={any_row['fired_at']}")
        for sub, r in sorted(arms.items()):
            print(f"    {ARM_LABEL.get(sub, sub):<14} status={r['status']:<9} "
                  f"closed={r['closed']}/{r['total']:<4} makespan={r['makespan']:<9} enacted={r['enacted']}")
        best_k = max(key(r) for r in arms.values())
        winners = [s for s, r in arms.items() if key(r) == best_k]
        if len(winners) > 1:
            ties += 1
        bests.append(winners[0])
        print(f"    -> best = {', '.join(ARM_LABEL.get(w, w) for w in winners)}"
              f"{'  (TIE)' if len(winners) > 1 else ''}\n")

    # H(best | zone): 최선 팔 분포의 섀넌 엔트로피. 0 이면 어느 구역이든 답이 하나 = 결정이 없다.
    n = len(bests)
    if n:
        counts = defaultdict(int)
        for b in bests:
            counts[b] += 1
        H = -sum((c / n) * math.log2(c / n) for c in counts.values())
        print(f"기준 (1) H(best|zone) = {H:.3f} bits  {'PASS' if H > 0 else 'FAIL'}   "
              f"(분포: { {ARM_LABEL.get(k, k): v for k, v in counts.items()} })")
        print(f"기준 (2) 동점률 = {ties}/{n} = {100*ties/n:.1f}%  {'PASS' if ties/n < 0.3 else 'FAIL'}")
    # 기준 (3): 가족 안에서 잘못 고른 팔이 얼마나 손해인지(닫은 노드 차이)를 그대로 보고한다.
    print("\n기준 (3) 잘못 고른 팔의 손해(closed 기준 regret):")
    for fam, arms in sorted(fams.items()):
        best_k = max(key(r) for r in arms.values())
        for sub, r in sorted(arms.items()):
            reg = best_k[1] - r["closed"]
            flag = "" if key(r) == best_k else "   <- 오답"
            print(f"    {FAMILY.get(fam, fam)[:28]:<30} {ARM_LABEL.get(sub, sub):<14} regret={reg}{flag}")


if __name__ == "__main__":
    main()
