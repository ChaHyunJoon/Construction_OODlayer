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

        out[c] = {
            "V": best_q,
            "Q": {str(a): _mean(v) for a, v in sorted(qs.items())},
            # tie 가 둘 이상이면 단일 a* 를 뽑지 않는다 — 없는 확신을 만들지 않는다.
            "a_star": (best_arm if len(tie) == 1 else None),
            "tie": tie,
            "se": {str(a): (_se(v) if math.isfinite(_se(v)) else None) for a, v in sorted(qs.items())},
            "n": {str(a): len(v) for a, v in sorted(qs.items())},
            "n_boards": {str(a): len(boards[(c, a)]) for a in sorted(qs)},
            "n_unscorable": {str(a): n for a, n in sorted(uns.items())},
            "prog_bucket": _bucket(c),
        }
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", default=os.path.join(HERE, "samples.jsonl"))
    ap.add_argument("--grid", default=os.path.join(HERE, "grid_spec.json"))
    ap.add_argument("--out", default=os.path.join(HERE, "value.json"))
    a = ap.parse_args()

    import objective
    rows = [json.loads(l) for l in open(a.samples) if l.strip()]

    # 세대 단일성: 표본이 두 세대에서 왔으면 멈춘다. 섞인 값을 표에 각인시키지 않는다.
    hashes = {r.get("objective_hash") for r in rows if r.get("objective_hash")}
    if len(hashes) > 1:
        sys.exit("표본에 objective_hash 가 %d 종 섞여 있다: %s" % (len(hashes), hashes))
    cur = objective.objective_hash()
    if hashes and cur not in hashes:
        sys.exit("표본의 objective_hash 가 현행과 다르다(구세대 표본): %s" % hashes)

    val = solve(rows, grid=json.load(open(a.grid)), cfg=objective.load())
    n_tie = sum(1 for v in val.values() if v["a_star"] is None and v.get("V") is not None)
    n_dead = sum(1 for v in val.values() if v.get("V") is None)
    n_1arm = sum(1 for v in val.values() if len(v.get("Q") or {}) == 1)

    with open(a.out, "w") as f:
        json.dump({
            "cells": val,
            "generation": objective.load()["generation"],
            "objective_hash": cur,
            "n_cells": len(val),
            "n_tie_unresolved": n_tie,
            "n_cells_unscorable": n_dead,
            "n_cells_single_arm": n_1arm,
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
            ],
        }, f, indent=1, ensure_ascii=False)
    print("cells=%d  tie(a* 미확정)=%d  전부채점불가=%d  단일팔=%d  -> %s"
          % (len(val), n_tie, n_dead, n_1arm, a.out))


if __name__ == "__main__":
    main()
