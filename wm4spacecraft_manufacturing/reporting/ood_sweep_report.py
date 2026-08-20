#!/usr/bin/env python3
"""
ood_sweep_report.py -- 무작위 OOD 스트림 스위프 결과 보고 (2026-08-05)

무엇을 읽나
-----------
tools/monitor/run_ood_sweep.ps1 이 쌓은 요약 JSONL. 한 줄 = 한 판 =
(world_seed 고정, ood_seed 하나, policy 하나).

무엇을 보고하나
---------------
 1) 정책별 완주율 / 진행도 -- "적응이 실제로 이득인가"의 headline
 2) **짝지은(paired) 비교** -- 같은 ood_seed 에서 두 정책을 맞대어 승/패/무.
    판마다 사건이 다르므로 정책끼리 평균만 비교하면 스트림 난이도 차가 섞인다.
    같은 시드끼리 짝지어야 그 차가 소거된다(공통난수, CRN).
 3) 결정 분포 -- 각 정책이 어떤 매크로를 얼마나 냈는가 + 규칙과의 불일치율
 4) 커버리지 -- 스트림이 실제로 어느 진행도에서 무엇을 터뜨렸는가.
    이게 이 실험의 존재 이유다: 라벨 격자가 아니라 뽑힌 시점에서 재는 것.

실행:  python wm4spacecraft_manufacturing/reporting/ood_sweep_report.py [요약.jsonl]
"""
import json
import math
import sys
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
WM = HERE.parent          # 2026-08-18 폴더 분류: 결과는 계속 wm4.../results 다
DEFAULT = WM / "results" / "ood_sweep.jsonl"

# 윈도우 콘솔 기본 코드페이지(cp949)는 em-dash 조차 못 찍고 UnicodeEncodeError 로 죽는다.
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass


def load(path):
    """JSONL 을 읽어 dict 리스트로. 깨진 줄은 건너뛰되 몇 줄이었는지 보고한다."""
    rows, bad = [], 0
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                bad += 1
    if bad:
        print(f"[warn] {bad} 줄이 JSON 으로 안 읽혀 건너뜀")
    # 같은 (ood_seed, policy, router) 가 여러 번 있으면 **마지막 것**만 쓴다(재실행 = 덮어쓰기).
    dedup = {}
    for r in rows:
        dedup[(r.get("ood_seed"), r.get("policy"), r.get("router"))] = r
    return list(dedup.values())


def policy_key(r):
    """라우터 ON 은 별도 정책으로 센다 -- 같은 DEMO_POLICY 라도 다른 시스템이다."""
    return "router" if str(r.get("router")) == "1" else r.get("policy", "?")


def wilson(k, n, z=1.96):
    """비율의 Wilson 신뢰구간. n 이 작을 때 정규근사보다 정직하다."""
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (max(0.0, c - h), min(1.0, c + h))


def sign_test(wins, losses):
    """부호검정 양측 p-value(무승부 제외). 짝지은 비교의 유의성."""
    n = wins + losses
    if n == 0:
        return 1.0
    k = min(wins, losses)
    tail = sum(math.comb(n, i) for i in range(0, k + 1)) / (2 ** n)
    return min(1.0, 2 * tail)


def main():
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT
    if not path.exists():
        print(f"요약 파일이 없다: {path}\n  먼저: pwsh -File tools/monitor/run_ood_sweep.ps1")
        return 1
    rows = load(path)
    if not rows:
        print("행이 없다")
        return 1

    worlds = sorted({r.get("world_seed") for r in rows})
    print(f"\n=== OOD 스트림 스위프 — {len(rows)} 판, {path.name} ===")
    print(f"world seed(로봇 초기 배치) = {worlds}   ← 고정 축")
    print(f"ood seed(언제/무엇/얼마나) = {len(sorted({r.get('ood_seed') for r in rows}))} 개   ← 스위프 축")

    by_pol = defaultdict(list)
    for r in rows:
        by_pol[policy_key(r)].append(r)

    # ---- 1) 정책별 완주율 ------------------------------------------------------------
    print("\n[1] 정책별 결과")
    print(f"  {'policy':<12} {'n':>3} {'완주':>6} {'완주율':>7} {'95% CI':>14} {'평균 진행도':>11} {'평균 스텝':>9}")
    for pol in sorted(by_pol):
        rs = by_pol[pol]
        n = len(rs)
        k = sum(1 for r in rs if r.get("complete"))
        lo, hi = wilson(k, n)
        prog = sum(r.get("progress", 0.0) for r in rs) / n
        steps = sum(r.get("steps", 0) for r in rs) / n
        print(f"  {pol:<12} {n:>3} {k:>6} {k / n:>7.2f} "
              f"{'[%.2f, %.2f]' % (lo, hi):>14} {prog:>11.3f} {steps:>9.0f}")

    # ---- 2) 짝지은 비교 --------------------------------------------------------------
    print("\n[2] 같은 스트림에서의 짝지은 비교 (완주 여부 → 진행도로 tie-break)")
    pols = sorted(by_pol)
    idx = {(policy_key(r), r.get("ood_seed")): r for r in rows}
    for i, a in enumerate(pols):
        for b in pols[i + 1:]:
            seeds = sorted({s for (p, s) in idx if p == a} & {s for (p, s) in idx if p == b})
            if not seeds:
                continue
            wins = losses = ties = 0
            for s in seeds:
                ra, rb = idx[(a, s)], idx[(b, s)]
                ca, cb = bool(ra.get("complete")), bool(rb.get("complete"))
                if ca != cb:
                    wins += ca
                    losses += cb
                else:
                    # 둘 다 같은 완주 상태면 더 멀리 간 쪽(미완주) / 더 빨리 끝난 쪽(완주)
                    ka = ra.get("steps", 0) if ca else -ra.get("progress", 0.0)
                    kb = rb.get("steps", 0) if cb else -rb.get("progress", 0.0)
                    if abs(ka - kb) < 1e-9:
                        ties += 1
                    elif ka < kb:
                        wins += 1
                    else:
                        losses += 1
            p = sign_test(wins, losses)
            star = " *" if p < 0.05 else ""
            print(f"  {a:>10} vs {b:<10}  n={len(seeds):<3} "
                  f"{a}승 {wins} / {b}승 {losses} / 무 {ties}   부호검정 p={p:.3f}{star}")

    # ---- 3) 결정 분포 ----------------------------------------------------------------
    print("\n[3] 결정 분포 (사건 종류별 → 고른 매크로)")
    for pol in sorted(by_pol):
        cnt = defaultdict(Counter)
        disagree = total = 0
        escal = 0
        for r in by_pol[pol]:
            for d in r.get("decisions", []):
                cnt[d.get("truth", "?")][d.get("macro", "?")] += 1
                total += 1
                if d.get("rule") and d.get("macro") != d.get("rule"):
                    disagree += 1
                if d.get("escalated"):
                    escal += 1
        if not total:
            continue
        print(f"  {pol}: 사건 {total} 건, 규칙과 불일치 {disagree} ({disagree / total:.0%})"
              + (f", 표현력 에스컬레이션 {escal}" if escal else ""))
        for truth in sorted(cnt):
            inner = ", ".join(f"{m}×{c}" for m, c in cnt[truth].most_common())
            print(f"      {truth:<14} {inner}")

    # ---- 4) 커버리지 ----------------------------------------------------------------
    print("\n[4] 스트림이 실제로 무엇을 어디서 터뜨렸나 (라벨 격자가 아니라 뽑힌 시점)")
    fires = []
    for r in rows:
        tot = r.get("total") or 1
        for d in r.get("decisions", []):
            at = d.get("at")
            if isinstance(at, (int, float)):
                fires.append((d.get("truth", "?"), at / tot))
    if fires:
        kinds = Counter(k for k, _ in fires)
        prog = [p for _, p in fires]
        prog_sorted = sorted(prog)
        q = lambda f: prog_sorted[min(len(prog_sorted) - 1, int(f * len(prog_sorted)))]
        mean = sum(prog) / len(prog)
        sd = (sum((p - mean) ** 2 for p in prog) / max(1, len(prog) - 1)) ** 0.5
        print(f"  발화 {len(fires)} 건: " + ", ".join(f"{k}×{v}" for k, v in kinds.most_common()))
        print(f"  진행도 min={min(prog):.3f}  p25={q(0.25):.3f}  중앙={q(0.5):.3f} "
              f" p75={q(0.75):.3f}  max={max(prog):.3f}  sd={sd:.3f}")
        # 히스토그램: 진행도 10분위 -- 격자가 아니라 분포로 덮였는지 눈으로 확인
        bins = Counter(min(9, int(p * 10)) for p in prog)
        print("  진행도 분포:")
        for b in range(10):
            bar = "#" * bins.get(b, 0)
            print(f"    {b / 10:.1f}-{(b + 1) / 10:.1f} {bins.get(b, 0):>3} {bar}")
    else:
        print("  발화 기록 없음 (decisions 가 비었다 — DEMO_SUMMARY 를 쓴 런인지 확인)")

    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
