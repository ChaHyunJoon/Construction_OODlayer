#!/usr/bin/env python
"""
firegrid_report.py -- "발화 시점 그리드가 실제로 무엇을 바꿨나"를 한 장으로 보고한다.

WHY THIS EXISTS
===============
2026-08-04 진단: 라벨 덤프의 `closed_at_fire` 가 {50,58} 두 값뿐이라 `progress` 축의 sd 가 0.005 였고,
그래서 novelty 라우터가 "아는 종류인가"가 아니라 **"교정과 같은 순간에 터졌나"** 를 재고 있었다
(LABELING_MANUAL §6). 고침은 두 갈래다:

  (1) 교정(TIER A) -- 서술자만 다시 뽑아 progress 축에 분산을 넣는다.  → verify_router_calibration.py
  (2) 라벨(TIER B) -- **그 진행도에서 어느 매크로가 실제로 최선인지**를 다시 라벨링한다. ← 이 파일

(1)만 하면 라우터는 "익숙하다"며 surrogate 로 보내는데 정작 surrogate 는 그 진행도의 fault 를 한 번도
본 적이 없다 — 게이트가 막으려던 바로 그 상황이다. 그래서 (2)가 진짜 산출물이고, 이 스크립트는 그
산출물이 쓸모 있는지를 세 가지로 검사한다:

  · **커버리지** : kind × 발화점 격자에서 라벨이 실제로 존재하는 칸은 어디인가(빈 칸 = 그 진행도 미지원)
  · **정답 다양성** : 발화점마다 oracle-best 매크로가 갈리는가? 전부 같은 팔이면 그 축은 결정에
    무의미하고, 데이터는 늘었지만 과제는 그대로 trivial 이다(H(best|kind) 로 표시).
  · **자격(admissibility)** : NOOP 이 control 보다 실제로 나빠야 그 instance 가 의미 있는 문제다.
    늦게 터진 고장이 아무 피해도 안 주면 그 라벨은 "적응이 필요 없다"는 뜻이라 따로 세어 보여준다.

Usage:
    python firegrid_report.py [dataset.jsonl] [--kinds=fault,battery] [--calib-only]

    기본 데이터셋은 wm_datasets.FIREGRID(=oracle/out/firegrid_merged.jsonl).
    `--calib-only` 를 주지 않으면 `calib_only=true` 행(TIER A: 매크로 스윕 없이 서술자만 뽑은 행)은
    라벨 통계에서 **제외**한다 — 팔이 하나뿐인 행으로 "정답"을 말하면 거짓말이 된다.
"""
import io
import json
import math
import os
import sys
from collections import Counter, defaultdict

import wm_datasets
from e1_analyze import MACRO_NAME, lex_key, cost_lex_key   # 채점 규칙은 한 곳에서만 정의한다(EVALUATION.md)

HERE = os.path.dirname(os.path.abspath(__file__))

# 비용 인지 채점의 λ. export_surrogate.py 의 기본값과 같게 둔다(개입 1건 ≈ 노드 3개 값어치).
# 왜 두 채점을 같이 보여주나: 무해한 변종(faultidle)은 원래 **완전한 동점**이다 — 고장을 흡수해
# makespan 이 control 과 한 자리까지 같다. 원(raw) 척도만 보면 "정답 NOOP"이 동점 중 아무거나
# 고른 것처럼 보인다. 비용을 물리면 NOOP 이 **엄격히** 이긴다 = 이게 restraint 클래스의 정확한 형태다.
LAM = 3.0


def read(path):
    with io.open(path, encoding="utf-8") as fh:      # utf-8 명시(윈도우 기본 cp949 로 열면 덤프가 깨진다)
        return [json.loads(l) for l in fh if l.strip()]


def fnum(v):
    """JSON 의 "Inf"/"NaN" 문자열을 다시 실수로 되돌린다."""
    if v is None:
        return math.nan
    if isinstance(v, str):
        return math.inf if v == "Inf" else (math.nan if v == "NaN" else float(v))
    return float(v)


def instance_groups(rows, keep_calib_only=False):
    """행들을 instance 별로 묶는다. fired=False(=사건이 안 터진 판)는 라벨이 아니므로 버린다."""
    g = defaultdict(list)
    for r in rows:
        if r.get("fired") is not True:
            continue
        if (not keep_calib_only) and r.get("calib_only") is True:
            continue
        g[str(r.get("instance"))].append(r)
    return g


def best_rows(rs):
    """feasibility-lexicographic 최선 행 + 동점(같은 키를 갖는) 팔의 수."""
    keyed = [(lex_key(bool(r.get("complete")), int(r.get("closed", -1)), fnum(r.get("makespan"))), r)
             for r in rs]
    top = max(k for k, _ in keyed)
    ties = [r for k, r in keyed if k == top]
    return ties[0], len(ties)


def best_row_cost_aware(rs, lam=LAM):
    """비용 인지 채점(y = closed - λ·cost(macro))의 최선 행. 동점을 깨는 것이 이 채점의 요점이다."""
    return max(rs, key=lambda r: cost_lex_key(bool(r.get("complete")), int(r.get("closed", -1)),
                                              fnum(r.get("makespan")), int(r.get("macro", 0)), lam))


def admissible(rs):
    """NOOP 이 control 보다 실제로 나쁜가(= 개입이 의미 있는 상황인가). control 이 없으면 판정 불가."""
    noop = [r for r in rs if int(r.get("macro", -1)) == 0]
    if not noop:
        return None
    n = noop[0]
    if int(n.get("ctrl_closed", -1)) < 0:            # DS_NOCTRL 로 만든 행 = sentinel
        return None
    if bool(n.get("ctrl_complete")) and not bool(n.get("complete")):
        return True
    if int(n.get("closed", 0)) < int(n.get("ctrl_closed", 0)):
        return True
    mk, cmk = fnum(n.get("makespan")), fnum(n.get("ctrl_makespan"))
    if int(n.get("closed", 0)) == int(n.get("ctrl_closed", 0)) and math.isfinite(mk) and math.isfinite(cmk):
        return mk > cmk + 1e-9
    return False


def entropy(counter):
    """정답 분포의 섀넌 엔트로피(bit). 0 = 언제나 같은 팔 = 그 축은 결정에 무의미."""
    n = sum(counter.values())
    if n == 0:
        return 0.0
    return -sum((c / n) * math.log2(c / n) for c in counter.values() if c)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = [a for a in sys.argv[1:] if a.startswith("--")]
    path = wm_datasets.abspath(args[0]) if args else wm_datasets.abspath(wm_datasets.FIREGRID)
    keep_calib = any(f == "--calib-only" for f in flags)
    want_kinds = None
    for f in flags:
        if f.startswith("--kinds="):
            want_kinds = set(f.split("=", 1)[1].split(","))

    rows = read(path)
    groups = instance_groups(rows, keep_calib_only=keep_calib)
    print(f"[report] {os.path.relpath(path, HERE)}: {len(rows)} rows -> {len(groups)} labeled instances"
          + ("  (calib_only 포함)" if keep_calib else "  (calib_only 제외)"))

    # ---- kind × 발화점 격자 -------------------------------------------------------------------
    cells = defaultdict(list)
    for iid, rs in groups.items():
        kind = str(rs[0].get("kind"))
        if want_kinds and kind not in want_kinds:
            continue
        closed = int(rs[0].get("closed_at_fire", -1))
        cells[(kind, closed)].append((iid, rs))

    print("\n" + "=" * 96)
    print("커버리지 + 정답  (kind × 실제 발화점)")
    print("=" * 96)
    hdr = (f"{'kind':10s} {'closed':>7s} {'prog':>6s} {'n':>3s} {'arms':>5s}  {'admis':>7s}  "
           f"{'ties':>5s}  {'oracle-best (raw)':32s} oracle-best (cost-aware λ=%.1f)" % LAM)
    print(hdr); print("-" * len(hdr))
    per_kind_best = defaultdict(Counter)
    per_kind_best_ca = defaultdict(Counter)
    for (kind, closed) in sorted(cells, key=lambda k: (k[0], k[1])):
        items = cells[(kind, closed)]
        prog = sum(float(rs[0].get("progress", 0.0)) for _, rs in items) / len(items)
        bests, bests_ca, tie_n, adm_yes, adm_known, arms = Counter(), Counter(), 0, 0, 0, set()
        for _, rs in items:
            b, nties = best_rows(rs)
            bests[int(b.get("macro", -1))] += 1
            per_kind_best[kind][int(b.get("macro", -1))] += 1
            bca = int(best_row_cost_aware(rs).get("macro", -1))
            bests_ca[bca] += 1
            per_kind_best_ca[kind][bca] += 1
            tie_n += 1 if nties > 1 else 0
            arms.add(len(rs))
            a = admissible(rs)
            if a is not None:
                adm_known += 1
                adm_yes += 1 if a else 0
        best_str = ", ".join(f"{MACRO_NAME.get(m, m)}×{c}" for m, c in bests.most_common())
        best_ca_str = ", ".join(f"{MACRO_NAME.get(m, m)}×{c}" for m, c in bests_ca.most_common())
        adm_str = "-" if adm_known == 0 else f"{adm_yes}/{adm_known}"
        print(f"{kind:10s} {closed:7d} {prog:6.3f} {len(items):3d} "
              f"{min(arms):>2d}-{max(arms):<2d} {adm_str:>7s}  {tie_n:5d}  {best_str:32s} {best_ca_str}")

    # ---- kind 안에서 정답이 갈리는가 ------------------------------------------------------------
    print("\n" + "=" * 96)
    print("정답 다양성  H(best|kind) -- 0 bit = 그 kind 는 언제나 같은 팔 = 상태를 읽을 이유가 없다")
    print("=" * 96)
    for kind, c in sorted(per_kind_best.items()):
        dist = ", ".join(f"{MACRO_NAME.get(m, m)} {n}" for m, n in c.most_common())
        cca = per_kind_best_ca[kind]
        dist_ca = ", ".join(f"{MACRO_NAME.get(m, m)} {n}" for m, n in cca.most_common())
        print(f"  {kind:10s} n={sum(c.values()):3d}  H={entropy(c):.3f} bit   [{dist}]")
        print(f"  {'':10s} {'':6s}  H={entropy(cca):.3f} bit   [{dist_ca}]  (cost-aware)")

    # ---- progress 축 요약(교정에 직접 들어가는 숫자) ---------------------------------------------
    progs = sorted(float(rs[0].get("progress", 0.0)) for rs in groups.values())
    if progs:
        n = len(progs); mean = sum(progs) / n
        sd = (sum((p - mean) ** 2 for p in progs) / n) ** 0.5
        print(f"\n[progress] n={n} min={progs[0]:.4f} max={progs[-1]:.4f} mean={mean:.4f} sd={sd:.5f}")
        print("           (교정의 sd 가 작을수록 그 축이 초민감해진다. 0.005 였던 것이 이 작업의 출발점.)")


if __name__ == "__main__":
    main()
