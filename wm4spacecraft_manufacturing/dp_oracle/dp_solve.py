#!/usr/bin/env python3
"""samples.jsonl -> value.json. **순수 파이썬, 시뮬 호출 0회, 결정적**(원 설계 §8.8).

이 파일에는 솔버가 **둘** 있다 (2026-08-15)
==========================================
    solve_backward()      ★ 현행. 진짜 Bellman backward induction.
    solve_constant_arm()  구세대(2026-08-14). 판 단위 J 의 상수-팔 반사실. **비교용으로 보존**한다.

두 판을 나란히 둘 수 있어야 이번 작업이 실제로 무엇을 바꿨는지 말할 수 있다. 지우지 말 것.

solve_backward 가 푸는 식
=========================
    V(goal)     = 0
    V(dead_end) = terminal_value            (표본이 실어 온 정산값 — sample_grid.decompose_board)
    Q(s̃, a)     = mean_k [ c_k + V(s̃′_k) ]
    V(s̃)        = min_a Q(s̃, a)
    a*(s̃)       = argmin_a Q(s̃, a)

`c_k` 는 구간 비용이고 `J` 의 **완주 분기 형태로 고정**돼 있다(에너지가 살아 있다). 미완주
분기와의 차액은 `terminal_value` 하나로 정산된다. 그 정의가 발명이 아님은 `sample_grid.py` 의
**분해 충실성 게이트** + `test_cost_decomposition.py` 가 못박는다. 그 게이트가 통과하지 않으면
이 파일이 내는 모든 숫자가 무효다.

dead-end 를 여기서 C_fail 로 또 물지 않는다 — `terminal_value` 안에 이미 들어 있다(이중계산).

풀이 순서 — 왜 이 순서가 되는가
==============================
`prog_b`(진행도 버킷)는 **단조 비감소**다. 닫힌 노드는 다시 열리지 않으므로 전이는 같은 버킷
안에 머물거나 더 높은 버킷으로만 간다. 즉 버킷 사이는 DAG 다.
  · **버킷 사이**: prog_b **역순**으로 푼다. 뒤 버킷의 V 가 확정된 뒤 앞 버킷을 푼다.
  · **버킷 내부**: 같은 진행도에서 결정이 여러 번 나 **자기순환**이 생긴다 → value iteration.
    비용이 전부 ≥ 0 인 SSP 이므로 V=0 에서 출발하면 단조 증가로 고정점에 수렴한다.
    수렴 실패 노드는 **조용히 넘기지 않고** `converged=false` 로 이름이 남는다.

다음 칸이 표에 없으면 — `dangling`
==================================
`V` 를 0 으로 두지 않는다. 0 으로 두면 **미지의 미래가 공짜**가 되어, 표 밖으로 나가는 팔이
언제나 이긴다. 그런 전이는 `dangling` 으로 세고 그 (칸,팔) 의 Q 를 **미정의**로 남긴다.
dangling 의 종류를 뭉뚱그리지 않는다 — `next_unstateable`(다음 결정을 칸으로 못 세움) ·
`next_missing`(그 칸에 표본이 없음) · `next_undefined`(그 칸의 V 가 미정의) ·
`terminal_value_missing`(J 채점 불가 판의 종단)는 전혀 다른 사건이다.

승계한 세 규칙 (2026-08-14 에 단위검사가 잡은 것들 — 반드시 유지)
==============================================================
  1. 완전 동점(격차 0·분산 0)은 tie 다 → 비교는 `<=` 여야 한다. `<` 이면 임의로 하나를 뽑아
     **없는 확신**을 만든다.
  2. **팔이 하나뿐인 칸은 a* 를 주장하지 않는다** — argmin 이 아니다(`unresolved_reason`).
  3. 값을 낼 수 없는 표본은 평균에 안 넣고 **센다**. 전부 불가면 `V=None`(0.0 이 아니다).

동점(원 설계 §7): |ΔQ| <= 1.96·SE 이면 단일 a* 를 뽑지 않고 tie 집합으로 보고한다.
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


def solve_constant_arm(samples, grid=None, cfg=None):
    """★ 구세대(2026-08-14) 솔버. **비교용으로 보존한다** — 현행은 `solve_backward()`.

    판 단위 J 를 그대로 Q 로 쓴다: Q(s,a) = mean_k[ J(판_k) ]. 즉 상수-팔 정책군 안의 최선이고
    backward induction 이 아니다. 이 열이 없으면 "backward induction 이 무엇을 바꿨는가" 를
    말할 수 없으므로 지우지 않는다(계획 Task 7).

    samples: dict 목록. 반환: {cell: {V, Q, a_star, tie, se, n, ...}}

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


# 옛 이름. 외부 소비처가 남아 있을 수 있어 유지하되, 새 코드는 이름을 골라 쓸 것.
solve = solve_constant_arm


# =====================================================================================
# ★ 진짜 Bellman backward induction (2026-08-15)
# =====================================================================================
VI_TOL = 1e-9        # value iteration 수렴 허용오차 (J 의 규모가 1e1~1e4 라 상대적으로 매우 타이트)
VI_MAX_ITER = 10_000


def _arm_values(trans, V, defined, home_bucket=None):
    """(칸,팔) 의 표본별 값 [c_k + V(s'_k)] 과 dangling 사유. Q 가 미정의면 vals=None.

    **dangling 이 하나라도 있으면 그 (칸,팔) 의 Q 는 미정의다.** 그 전이만 빼고 평균 내면
    "표 밖으로 나가는 팔" 이 남은 표본만으로 평가되어 조용히 유리해진다 — 미지의 미래를 0 으로
    두는 것과 같은 종류의 낙관 편향이다."""
    vals, why = [], collections.Counter()
    for (c, nxt, term, tv, unstateable) in trans:
        if term == "goal":
            vnext = 0.0
        elif term == "dead_end":
            if tv is None:                       # J 채점 불가 판의 종단 — 값이 없다
                why["terminal_value_missing"] += 1
                continue
            vnext = float(tv)
        elif unstateable:
            why["next_unstateable"] += 1         # 다음 결정은 있는데 칸으로 라벨할 수 없다
            continue
        elif nxt not in defined:
            why["next_missing"] += 1             # 그 칸에 표본이 하나도 없다
            continue
        elif home_bucket is not None and _bucket(nxt) < home_bucket:
            # prog_b 단조성이 깨졌다 = 이 솔버의 DAG 전제가 그 전이에서 틀렸다는 뜻이다.
            # 조용히 처리하지 않고 **따로 세어** 이름으로 남긴다.
            why["backward_edge"] += 1
            continue
        elif V.get(nxt) is None:
            why["next_undefined"] += 1           # 그 칸이 있지만 V 를 못 냈다
            continue
        else:
            vnext = float(V[nxt])
        vals.append(float(c) + vnext)
    if why:
        return None, why
    return vals, why


def _decide(qs, uns, dangling):
    """팔별 값 목록 -> {V, Q, a_star, tie, ...}. 세 승계 규칙(위 머리말)을 여기서 지킨다."""
    if not qs:
        return {"V": None, "Q": {}, "a_star": None, "unresolved_reason": "no_scorable_arm",
                "tie": [], "se": {}, "n": {}, "n_unscorable": uns,
                "n_dangling": dangling,
                "note": "no arm produced a defined Q (all samples unusable)"}
    best_arm = min(qs, key=lambda a: _mean(qs[a]))
    best_q, best_vals = _mean(qs[best_arm]), qs[best_arm]

    tie = []
    for a, vals in qs.items():
        if a == best_arm:
            tie.append(a)
            continue
        q = _mean(vals)
        se_d = math.sqrt(_se(vals) ** 2 + _se(best_vals) ** 2) \
            if math.isfinite(_se(vals)) and math.isfinite(_se(best_vals)) else math.inf
        # `<=` 여야 한다 — 완전 동점(격차 0·분산 0)이 `<` 에서는 tie 로 안 잡혀 임의로 하나를
        # a* 로 뽑는다. 2026-08-14 단위검사가 이 경계를 잡았다.
        if not math.isfinite(se_d) or abs(q - best_q) <= Z * se_d:
            tie.append(a)
    tie = sorted(tie)
    single_arm = (len(qs) == 1)
    resolved = (len(tie) == 1) and not single_arm
    return {
        "V": best_q,
        "Q": {str(a): _mean(v) for a, v in sorted(qs.items())},
        "a_star": (best_arm if resolved else None),
        "unresolved_reason": (None if resolved else ("single_arm" if single_arm else "tie")),
        "tie": tie,
        "se": {str(a): (_se(v) if math.isfinite(_se(v)) else None) for a, v in sorted(qs.items())},
        "n": {str(a): len(v) for a, v in sorted(qs.items())},
        "n_unscorable": uns,
        "n_dangling": dangling,
    }


def solve_backward(samples):
    """전이 표본 -> {cell: {V, Q, a_star, ...}}. **진짜 backward induction.**

    samples 의 각 행은 `sample_grid.rows_to_samples` 가 낸 전이다:
        cell · arm · c · next_cell · terminal · terminal_value · next_unstateable

    반환: (table, stats). stats 에 dangling 전이 수·사유별 내역·수렴 실패 칸 수가 들어간다.
    """
    by = collections.defaultdict(list)          # (cell, arm) -> [(c, next, term, tv, unstateable)]
    boards = collections.defaultdict(set)
    n_bad_c = collections.Counter()             # c 자체가 없는 전이(구세대 표본 등)
    for r in samples:
        cell, arm = r["cell"], int(r["arm"])
        c = r.get("c")
        if c is None or not math.isfinite(float(c)):
            n_bad_c[(cell, arm)] += 1
            continue
        by[(cell, arm)].append((float(c), r.get("next_cell"), r.get("terminal"),
                                r.get("terminal_value"), bool(r.get("next_unstateable"))))
        boards[(cell, arm)].add(r.get("board_id"))

    cells = sorted({c for c, _ in by} | {c for c, _ in n_bad_c})
    if not cells:
        return {}, {}
    defined = set(cells)
    arms_of = collections.defaultdict(set)
    for (c, a) in list(by) + list(n_bad_c):
        arms_of[c].add(a)

    V, out = {}, {}
    stats = collections.Counter()

    # 버킷 **역순**. prog_b 단조성이 버킷 사이 DAG 를 보장하므로 뒤에서 앞으로 확정된다.
    buckets = sorted({_bucket(c) for c in cells}, reverse=True)
    for b in buckets:
        cells_b = [c for c in cells if _bucket(c) == b]
        # 같은 버킷 안의 자기순환 때문에 한 번의 대입으로는 안 끝난다 -> value iteration.
        # 비용이 전부 >= 0 인 SSP 이므로 V=0 출발이 아래에서 고정점으로 단조 수렴한다.
        for c in cells_b:
            V[c] = 0.0
        converged, iters = False, 0
        for it in range(1, VI_MAX_ITER + 1):
            iters, delta, flipped = it, 0.0, False
            for c in cells_b:
                qs = {}
                for a in sorted(arms_of[c]):
                    if (c, a) not in by:
                        continue
                    vals, _why = _arm_values(by[(c, a)], V, defined, home_bucket=b)
                    if vals:
                        qs[a] = vals
                newV = min(_mean(v) for v in qs.values()) if qs else None
                old = V.get(c)
                if newV is None:
                    # 이 칸은 어느 팔도 값을 못 낸다. 0 으로 두지 않고 미정의로 내린다.
                    flipped = flipped or (old is not None)
                    V[c] = None
                elif old is None:
                    flipped, V[c] = True, newV
                else:
                    delta = max(delta, abs(newV - old))
                    V[c] = newV
            if not flipped and delta <= VI_TOL:
                converged = True
                break
        stats["vi_iters_max"] = max(stats["vi_iters_max"], iters)
        if not converged:
            # **조용히 넘기지 않는다.** 수렴 실패는 칸마다 converged=false 로 남고 여기서 세어진다.
            stats["cells_not_converged"] += len(cells_b)

        # 버킷이 확정됐으니 이 버킷 칸들의 최종 표를 만든다.
        for c in cells_b:
            qs, uns, dang = {}, {}, {}
            for a in sorted(arms_of[c]):
                if (c, a) in n_bad_c:
                    uns[str(a)] = n_bad_c[(c, a)]
                if (c, a) not in by:
                    continue
                vals, why = _arm_values(by[(c, a)], V, defined, home_bucket=b)
                if vals:
                    qs[a] = vals
                else:
                    dang[str(a)] = dict(why)
                    stats["dangling_transitions"] += sum(why.values())
                    for k, n in why.items():
                        stats["dangling:" + k] += n
            e = _decide(qs, uns, dang)
            e["prog_bucket"] = b
            e["converged"] = converged
            e["vi_iters"] = iters
            e["n_boards"] = {str(a): len(boards[(c, a)]) for a in sorted(qs)}
            e["dp_level"] = 0                    # 계층 백오프는 꺼져 있다(계획 Task 4 마지막 항목)
            e["dp_level_key"] = c
            out[c] = e
            V[c] = e["V"]

    stats["cells"] = len(out)
    return out, dict(stats)


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
        tables.append(solve_constant_arm(proj))

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
    # 계획 Task 4 마지막 항목: **백오프는 일단 끈다.** 진짜 전이가 생기면 (칸,팔) 표본이 훨씬
    # 촘촘해질 수 있으므로 먼저 L0 로만 풀어 커버리지를 재고, 부족하면 그때 켠다. 끈 채로 잰
    # 수치를 report 에 남겨야 하므로 기본값이 off 다.
    ap.add_argument("--backoff", action="store_true",
                    help="계층 백오프를 켠다(기본 off). 켜면 거친 칸의 편향이 섞인다.")
    ap.add_argument("--method", choices=("backward", "constant_arm"), default="backward",
                    help="backward = 진짜 Bellman(현행). constant_arm = 2026-08-14 구세대(비교용).")
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
    stats = {}
    if a.method == "backward":
        n_tr = sum(1 for r in rows if r.get("c") is not None)
        if not n_tr:
            sys.exit("표본에 구간 비용 `c` 가 하나도 없다 — 구세대(판 단위 J) 표본이다. "
                     "sample_grid.py 를 다시 돌리거나 --method constant_arm 을 쓸 것.")
        if a.backoff:
            sys.exit("backward 는 아직 계층 백오프를 지원하지 않는다. 거친 칸으로 투영하면 "
                     "next_cell 도 같이 투영해야 하는데 그 규칙을 지어내지 않는다.")
        val, stats = solve_backward(rows)
        method_note = (
            "TRUE Bellman backward induction on the measured phi-tilde grid. "
            "V(goal)=0; V(dead_end)=terminal_value (the settlement carried by the sample); "
            "Q(s,a)=mean_k[c_k + V(s'_k)]; V(s)=min_a Q(s,a). Running cost c_k is FIXED to J's "
            "complete branch (energy included) and the two branches are reconciled by one terminal "
            "settlement. That decomposition is machine-checked per board by sample_grid.py's "
            "fidelity gate (c_prefix + sum(c) + terminal == objective.J_row) and by "
            "test_cost_decomposition.py. Buckets are solved in DESCENDING prog_b (progress is "
            "monotone, so buckets form a DAG); within a bucket, value iteration handles self-loops.")
        limits = [
            "phi-tilde abstraction loss remains: two physically different states that map to the "
            "same cell share one V. backward induction does NOT remove this (design 2.1).",
            "single-arm cells claim NO a*: forcing an arm changes the trajectory, so arms land in "
            "different cells and some cells see only one arm. One arm is not an argmin.",
            "dangling transitions make a (cell,arm) Q UNDEFINED rather than assuming V=0 for the "
            "unknown successor — assuming 0 would make an unknown future free. Counts and reasons "
            "are in dangling_by_reason.",
            "c_prefix (the interval BEFORE the first decision) is excluded from the DP by "
            "construction: no policy can change it. It is measured and included in the fidelity "
            "identity, not silently dropped.",
            "hierarchical backoff is OFF in this table (dp_level==0 everywhere). Coverage was "
            "measured with it off; see resolved_by_level.",
        ]
    else:
        # 구세대 재현 경로. 계층 백오프는 이쪽에만 있다.
        val = (solve_hierarchical(rows, all_cells=list(grid.get("observed_cells") or {}))
               if a.backoff else solve_constant_arm(rows))
        method_note = (
            "constant-arm counterfactual (2026-08-14 generation, kept for side-by-side "
            "comparison); Q(s,a)=E[J(board) | board visited s, all its decisions forced to a]. "
            "NOT Bellman backward induction.")
        limits = [
            "credit assignment: a board with n decisions contributes n cells that share one J",
            "the constant-arm policy class is NARROWER than the executing policies (which may "
            "switch arms per event), so V can be WORSE than a realized policy — if that happens "
            "the ceiling name must not be used (design §8.7)",
            "single-arm cells claim NO a*: one arm is not an argmin.",
        ]

    n_tie = sum(1 for v in val.values() if v.get("unresolved_reason") == "tie")
    n_dead = sum(1 for v in val.values() if v.get("V") is None)
    n_1arm = sum(1 for v in val.values() if v.get("unresolved_reason") == "single_arm")
    n_resolved = sum(1 for v in val.values() if v.get("a_star") is not None)
    n_noarm = sum(1 for v in val.values() if v.get("unresolved_reason") == "no_scorable_arm")
    n_unconv = sum(1 for v in val.values() if v.get("converged") is False)
    by_level = collections.Counter(v.get("dp_level") for v in val.values()
                                   if v.get("a_star") is not None)
    dang_by_reason = {k[len("dangling:"):]: v for k, v in stats.items()
                      if k.startswith("dangling:")}

    with open(a.out, "w") as f:
        json.dump({
            "cells": val,
            "generation": objective.load()["generation"],
            "objective_hash": cur,
            "solver": a.method,
            "n_cells": len(val),
            "n_tie_unresolved": n_tie,
            "n_cells_unscorable": n_dead,
            "n_cells_single_arm": n_1arm,
            "n_cells_no_scorable_arm": n_noarm,
            "n_cells_resolved": n_resolved,
            "n_cells_not_converged": n_unconv,
            "n_dangling_transitions": stats.get("dangling_transitions", 0),
            "dangling_by_reason": dang_by_reason,
            "vi_max_iterations_used": stats.get("vi_iters_max", 0),
            "vi_tol": VI_TOL, "vi_max_iter": VI_MAX_ITER,
            "backoff_enabled": bool(a.backoff),
            "resolved_by_level": {str(k): v for k, v in sorted(by_level.items())},
            "backoff_levels": [{"level": i, "dropped_axes": list(d)}
                               for i, d in enumerate(BACKOFF_LEVELS)],
            # 이 표가 무엇인지 **표 안에** 적는다. 소비처가 문서를 안 읽어도 오해하지 않게.
            "method": method_note,
            "known_limits": limits,
        }, f, indent=1, ensure_ascii=False)

    n_obs = grid.get("n_observed_cells") or 0
    print("[%s] cells=%d  a* 확정=%d  tie 미확정=%d  단일팔(비교없음)=%d  "
          "값없음=%d  팔없음=%d" % (a.method, len(val), n_resolved, n_tie, n_1arm, n_dead, n_noarm))
    print("  결정 기준 커버리지: a* 확정 %d / 관측격자 %d = %.1f%%  (표에 오른 칸 %d)"
          % (n_resolved, n_obs, 100.0 * n_resolved / max(n_obs, 1), len(val)))
    print("  dangling 전이 %d  사유별 %s" % (stats.get("dangling_transitions", 0),
                                             dang_by_reason or "{}"))
    print("  수렴 실패 칸 %d  (value iteration 최대 반복 %d / 상한 %d, tol %.0e)"
          % (n_unconv, stats.get("vi_iters_max", 0), VI_MAX_ITER, VI_TOL))
    print("  계층 백오프: %s   확정 칸의 레벨 분포: %s"
          % ("ON" if a.backoff else "OFF (계획 Task 4)",
             {("L%s" % k): v for k, v in sorted(by_level.items())}))
    print("  -> %s" % a.out)


if __name__ == "__main__":
    main()
