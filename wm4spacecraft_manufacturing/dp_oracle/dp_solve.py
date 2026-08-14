#!/usr/bin/env python3
"""samples.jsonl -> value.json. **순수 파이썬, 시뮬 호출 0회, 결정적**(원 설계 §8.8).

이 솔버가 푸는 식
================
    Q(s̃, a) = mean_k [ cost_k ]           cost = 판 전체의 J (sample_grid.py 독스트링 참조)
    V(s̃)    = min_a Q(s̃, a)
    a*(s̃)   = argmin_a Q(s̃, a)

**원 설계 §7 의 backward induction 이 아니다.** 이유는 `sample_grid.py` 머리말에 적혀 있다 —
이 하니스가 J 를 내는 단위가 결정 epoch 이 아니라 **판**이라, epoch 단위 (c, s̃′) 분해가 없다.
분해를 지어내면 그 배분 규칙이 곧 결과가 되므로 분해하지 않고, 대신 **상수-팔 정책군 안의
최선**을 푼다. 그래서 dead-end 를 C_fail 로 무는 SSP tail 도 없다: 판이 미완주로 끝난 것은
이미 J 안에 `C_unclosed`/`C_fail` 로 들어가 있다(objective.J 가 그렇게 정의돼 있다).
같은 값을 여기서 또 물면 **이중계산**이다.

동점(원 설계 §7): |ΔQ| < 1.96·SE 이면 **단일 a* 를 뽑지 않고 tie 집합으로 보고**한다.
없는 확신을 만들지 않는 것이 채점에서 중요하다.
"""
import argparse
import collections
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))

Z = 1.96


def _bucket(cell):
    """prog_b 는 cell key 의 첫 성분이다 (derive_grid.cell_key 규약)."""
    try:
        return int(str(cell).split("|", 1)[0].split("=", 1)[-1])
    except Exception:
        return 0


def _mean(xs):
    return sum(xs) / len(xs) if xs else 0.0


def _se(xs):
    n = len(xs)
    if n < 2:
        return float("inf")
    m = _mean(xs)
    var = sum((x - m) ** 2 for x in xs) / (n - 1)
    return math.sqrt(var / n)


def solve(samples, grid=None, cfg=None):
    """samples: dict 목록. 반환: {cell: {V, Q, a_star, tie, se, n, ...}}

    `cost is None`(J 채점 불가) 표본은 **평균에 넣지 않고 센다.** 0 으로 채우면 그 팔이
    공짜로 보이고, 조용히 빼면 몇 개가 빠졌는지 아무도 모른다."""
    by = collections.defaultdict(list)
    unscorable = collections.Counter()
    boards = collections.defaultdict(set)
    for r in samples:
        key = (r["cell"], int(r["arm"]))
        if r.get("cost") is None:
            unscorable[key] += 1
            continue
        by[key].append(float(r["cost"]))
        boards[key].add(r.get("board_id"))

    cells = sorted({c for c, _ in by} | {c for c, _ in unscorable})
    if not cells:
        return {}

    out = {}
    for c in cells:
        qs = {a: v for (cc, a), v in by.items() if cc == c}
        uns = {a: n for (cc, a), n in unscorable.items() if cc == c}
        if not qs:
            # 이 칸은 표본이 있었지만 **하나도 채점되지 않았다.** 값을 지어내지 않는다.
            out[c] = {"V": None, "Q": {}, "a_star": None, "tie": [], "se": {}, "n": {},
                      "n_unscorable": uns, "n_boards": {},
                      "note": "all samples unscorable (J undefined)"}
            continue
        best_arm = min(qs, key=lambda a: _mean(qs[a]))
        best_q = _mean(qs[best_arm])
        best_vals = qs[best_arm]

        tie = []
        for a, vals in qs.items():
            if a == best_arm:
                tie.append(a)
                continue
            q = _mean(vals)
            # 표본이 짝지어져 있지 않으므로(판이 팔마다 따로 돈다) 합산 SE 로 비교한다.
            se_d = math.sqrt(_se(vals) ** 2 + _se(best_vals) ** 2) \
                if math.isfinite(_se(vals)) and math.isfinite(_se(best_vals)) else math.inf
            # `<=` 여야 한다. `<` 이면 **완전 동점(격차 0, 분산 0)** 이 tie 로 안 잡힌다:
            # 0 < 1.96*0 은 거짓이라, 두 팔이 글자 그대로 같은 값을 낸 칸에서 솔버가 임의로
            # 하나를 a* 로 뽑아 **없는 확신을 만든다**. 단위검사가 이 경계를 잡았다.
            if not math.isfinite(se_d) or abs(q - best_q) <= Z * se_d:
                tie.append(a)
        tie = sorted(tie)

        # ---- 팔이 하나뿐인 칸에서는 a* 를 **주장하지 않는다** -------------------------------
        # a* 는 정의상 팔들 사이의 argmin 이다. 그 칸에 팔이 하나만 착지했다면 비교가 없었던
        # 것이고, 그 하나를 a* 라고 부르는 순간 "DP 가 이걸 골랐다" 는 **없는 확신**이 된다.
        # (실측 2026-08-14: 43칸 중 26칸이 이 상태였고, 고치기 전에는 전부 a* 를 달고 있었다.
        #  팔을 고정해 굴리면 궤적이 갈려 서로 다른 칸에 착지하기 때문에 생기는 구조적 현상이다.)
        # tie 와 구분해 이유를 따로 남긴다 — "비교했는데 못 갈랐다" 와 "비교 자체가 없었다" 는
        # 전혀 다른 사건이고, 뭉뚱그리면 커버리지 부족이 알고리즘의 신중함으로 오독된다.
        single_arm = (len(qs) == 1)
        resolved = (len(tie) == 1) and not single_arm
        out[c] = {
            "V": best_q,
            "Q": {str(a): _mean(v) for a, v in sorted(qs.items())},
            "a_star": (best_arm if resolved else None),
            "unresolved_reason": (None if resolved else
                                  ("single_arm" if single_arm else "tie")),
            "tie": tie,
            "se": {str(a): (_se(v) if math.isfinite(_se(v)) else None) for a, v in sorted(qs.items())},
            "n": {str(a): len(v) for a, v in sorted(qs.items())},
            "n_boards": {str(a): len(boards[(c, a)]) for a in sorted(qs)},
            "n_unscorable": {str(a): n for a, n in sorted(uns.items())},
            "prog_bucket": _bucket(c),
        }
    return out


# =====================================================================================
# 계층 백오프 — 정밀한 칸이 못 갈랐을 때 **한 단계 거친 칸**으로 물러난다
# =====================================================================================
# 왜 필요한가 (실측 2026-08-14): 팔을 고정해 굴리면 궤적이 갈려 서로 다른 칸에 착지한다.
# 그래서 6축 정밀 격자에서는 한 칸에 팔이 하나만 오는 경우가 다수이고(43칸 중 26칸),
# argmin 을 낼 수가 없다. 축을 덜어내면 팔이 같은 칸에 모인다 — 실측 co-occurrence:
#     6축 그대로            : 43칸 중 팔>=2 인 칸 17
#     -spares_b             : 22칸 중 19
#     -spares_b, -prog_b    :  8칸 중  8
#
# 대가는 **편향**이다: 거친 칸은 서로 다른 상태를 한 평균에 섞는다. 그래서
#   (1) 언제나 **가장 정밀한 레벨부터** 시도하고, 갈린 순간 멈춘다.
#   (2) 어느 레벨이 답했는지를 **칸마다 기록**한다(`dp_level`). 레벨을 안 남기면 정밀한 답과
#       거친 답이 표에서 구별되지 않아, 편향이 정확도로 위장된다.
#
# 왜 **평평한** 표로 내보내는가: 조회는 Julia(`dp_lane.jl`)가 한다. 계층 구조를 표에 담으면
# 투영 규칙이 두 언어에 각각 생겨 갈릴 수 있다(그게 test_cellkey_parity.py 가 막는 결함이다).
# 그래서 백오프는 **여기서 전부 풀어** 놓고, 표는 정밀 칸 키 하나로만 조회되게 만든다.
# Julia 쪽은 한 줄도 바뀌지 않는다.
BACKOFF_LEVELS = [
    (),                          # L0: 6축 그대로
    ("spares_b",),               # L1: 스페어 수를 덜어낸다 (개입으로 가장 잘 갈리는 축)
    ("spares_b", "prog_b"),      # L2: 진행도까지 덜어낸다
]


def _project(cell, drop):
    return "|".join(p for p in cell.split("|") if p.split("=", 1)[0] not in drop)


def solve_hierarchical(samples, all_cells=None):
    """정밀 칸 키 -> 답. 갈리는 가장 정밀한 레벨을 골라 그 답을 **정밀 키에** 적는다."""
    tables = []
    for drop in BACKOFF_LEVELS:
        proj = [dict(r, cell=_project(r["cell"], set(drop))) for r in samples] if drop else samples
        tables.append(solve(proj))

    cells = set(all_cells or [])
    cells |= {r["cell"] for r in samples}

    out = {}
    for c in sorted(cells):
        entry = None
        for lvl, (drop, tab) in enumerate(zip(BACKOFF_LEVELS, tables)):
            key = _project(c, set(drop))
            d = tab.get(key)
            if d is None:
                continue
            if entry is None:                       # 가장 정밀한 "존재하는" 칸을 기본으로 둔다
                entry = dict(d, dp_level=lvl, dp_level_key=key)
            if d.get("a_star") is not None:         # 갈린 순간 멈춘다
                entry = dict(d, dp_level=lvl, dp_level_key=key)
                break
        if entry is not None:
            out[c] = entry
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", default=os.path.join(HERE, "samples.jsonl"),
                    help="쉼표로 여러 개 줄 수 있다(표집 라운드를 나눠 돌렸을 때)")
    ap.add_argument("--grid", default=os.path.join(HERE, "grid_spec.json"))
    ap.add_argument("--out", default=os.path.join(HERE, "value.json"))
    a = ap.parse_args()

    import objective
    rows = []
    for sp in a.samples.split(","):
        sp = sp.strip()
        if not sp:
            continue
        n0 = len(rows)
        rows += [json.loads(l) for l in open(sp) if l.strip()]
        print("  표본 %s: %d행" % (os.path.basename(sp), len(rows) - n0))

    # 세대 단일성: 표본이 두 세대에서 왔으면 멈춘다. 섞인 값을 표에 각인시키지 않는다.
    hashes = {r.get("objective_hash") for r in rows if r.get("objective_hash")}
    if len(hashes) > 1:
        sys.exit("표본에 objective_hash 가 %d 종 섞여 있다: %s" % (len(hashes), hashes))
    cur = objective.objective_hash()
    if hashes and cur not in hashes:
        sys.exit("표본의 objective_hash 가 현행과 다르다(구세대 표본): %s" % hashes)

    grid = json.load(open(a.grid))
    # 정밀 칸부터 시도하고 못 갈리면 한 단계 거친 칸으로 물러난다. 스윕이 실제로 지나는 칸
    # (grid_spec 의 observed_cells)도 열쇠 목록에 넣어, 표집이 못 닿은 칸도 거친 레벨로는
    # 답이 나오게 한다.
    val = solve_hierarchical(rows, all_cells=list(grid.get("observed_cells") or {}))
    n_tie = sum(1 for v in val.values() if v.get("unresolved_reason") == "tie")
    n_dead = sum(1 for v in val.values() if v.get("V") is None)
    n_1arm = sum(1 for v in val.values() if v.get("unresolved_reason") == "single_arm")
    n_resolved = sum(1 for v in val.values() if v.get("a_star") is not None)
    by_level = collections.Counter(v.get("dp_level") for v in val.values()
                                   if v.get("a_star") is not None)

    with open(a.out, "w") as f:
        json.dump({
            "cells": val,
            "generation": objective.load()["generation"],
            "objective_hash": cur,
            "n_cells": len(val),
            "n_tie_unresolved": n_tie,
            "n_cells_unscorable": n_dead,
            "n_cells_single_arm": n_1arm,
            "n_cells_resolved": n_resolved,
            "resolved_by_level": {str(k): v for k, v in sorted(by_level.items())},
            "backoff_levels": [{"level": i, "dropped_axes": list(d)}
                               for i, d in enumerate(BACKOFF_LEVELS)],
            # 이 표가 무엇인지 **표 안에** 적는다. 소비처가 문서를 안 읽어도 오해하지 않게.
            "method": "constant-arm counterfactual on the measured phi-tilde grid; "
                      "Q(s,a)=E[J(board) | board visited s, all its decisions forced to a]. "
                      "NOT Bellman backward induction — this harness scores J per board, not "
                      "per decision epoch, so no (cost, next_state) decomposition exists.",
            "known_limits": [
                "credit assignment: a board with n decisions contributes n cells that share one J",
                "the constant-arm policy class is NARROWER than the executing policies (which may "
                "switch arms per event), so V can be WORSE than a realized policy — if that happens "
                "the ceiling name must not be used (design §8.7)",
                "single-arm cells claim NO a*: forcing an arm changes the trajectory, so arms land "
                "in different cells and many cells see only one arm. One arm is not an argmin.",
                "hierarchical backoff: a cell answered at dp_level>0 was resolved on a COARSER "
                "projection (dropped axes listed in backoff_levels), which averages over "
                "heterogeneous states and is therefore MORE BIASED. dp_level is recorded per cell "
                "so a coarse answer is never mistaken for a precise one.",
            ],
        }, f, indent=1, ensure_ascii=False)
    print("cells=%d  a* 확정=%d  tie 미확정=%d  단일팔(비교없음)=%d  전부채점불가=%d  -> %s"
          % (len(val), n_resolved, n_tie, n_1arm, n_dead, a.out))
    print("  확정된 칸의 레벨 분포(0=6축 정밀, 클수록 거칠고 편향): %s"
          % {("L%s" % k): v for k, v in sorted(by_level.items())})


if __name__ == "__main__":
    main()
