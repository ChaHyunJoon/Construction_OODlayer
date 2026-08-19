"""G-S — semi-Markov 검사 (spec §7). 가장 싼 반증이라 가장 먼저 돈다.

묻는 것: **같은 s 에서 팔만 바꿨을 때 다음 epoch 까지의 τ 가 팔에 의존하는가.**
  의존한다 → F(τ|s,a) 가 진짜로 a 에 의존 → SMDP 구조가 결정에 정보를 나른다.
  의존 안 한다 → τ 는 외생. 형식적으로는 SMDP 지만 'τ 를 안 봐도 되는 SMDP' = 실질 MDP.
                그러면 spec §5 전체가 장식이므로 **여기서 멈추고 그렇게 쓴다.**

왜 블록 순열인가: 그룹(=case,seed)마다 τ 의 절대 수준이 크게 다르다. 그룹을 블록으로 잡고
**블록 안에서만** 팔 라벨을 섞으면 그룹 효과가 통제된 상태에서 팔 효과만 검정된다.
정규성·등분산을 가정하지 않는다.

  python gate_gs.py            # 기본 경로로 실측
"""
import random
import sys


def tau_at(board, k):
    """결정 k 에서 시작한 option 의 체류시간 τ 와 우측절단 여부.

    다음 결정이 있으면 τ = sim_t_at[k+1] - sim_t_at[k] (censored=False).
    없으면(=k 가 마지막 결정) τ = makespan - sim_t_at[k] (censored=True).
    k 결정 자체가 없으면 (None, False).
    """
    cur = nxt = None
    for d in board["decisions"]:
        if d.get("decision_index") == k:
            cur = d
        elif d.get("decision_index") == k + 1:
            nxt = d
    if cur is None or cur.get("sim_t_at") is None:
        return (None, False)
    if nxt is not None and nxt.get("sim_t_at") is not None:
        return (float(nxt["sim_t_at"]) - float(cur["sim_t_at"]), False)
    ms = board.get("makespan")
    if ms is None:
        return (None, False)
    return (float(ms) - float(cur["sim_t_at"]), True)


def _ss_arm(tau_by_group):
    """블록(그룹) 평균을 뺀 뒤의 팔별 평균 제곱합. 팔 효과의 크기."""
    centered = {}
    for gkey, per_arm in tau_by_group.items():
        if len(per_arm) < 2:
            continue
        mu = sum(per_arm.values()) / len(per_arm)
        for arm, t in per_arm.items():
            centered.setdefault(arm, []).append(t - mu)
    total = 0.0
    for vals in centered.values():
        if not vals:
            continue
        m = sum(vals) / len(vals)
        total += len(vals) * m * m
    return total


def block_permutation_p(tau_by_group, n_perm=2000, seed=0):
    """(p_value, 관측 SS_arm, 귀무분포 SS_arm 중앙값).

    귀무가설: τ 는 팔에 의존하지 않는다(그룹 안에서 팔 라벨이 교환가능).
    """
    rng = random.Random(seed)
    obs = _ss_arm(tau_by_group)
    null = []
    for _ in range(n_perm):
        shuffled = {}
        for gkey, per_arm in tau_by_group.items():
            arms = list(per_arm.keys())
            vals = list(per_arm.values())
            rng.shuffle(vals)
            shuffled[gkey] = dict(zip(arms, vals))
        null.append(_ss_arm(shuffled))
    null.sort()
    # +1/+1 보정: 순열검정의 표준(관측 자신을 귀무표본에 포함).
    ge = sum(1 for x in null if x >= obs)
    p = (ge + 1.0) / (n_perm + 1.0)
    return (p, obs, null[len(null) // 2])


def variance_ratio(tau_by_group):
    """(그룹 내 팔 간 분산의 평균) / (그룹 평균들의 분산). 효과크기 보고용."""
    within, means = [], []
    for per_arm in tau_by_group.values():
        if len(per_arm) < 2:
            continue
        vals = list(per_arm.values())
        mu = sum(vals) / len(vals)
        means.append(mu)
        within.append(sum((v - mu) ** 2 for v in vals) / (len(vals) - 1))
    if not within or len(means) < 2:
        return float("nan")
    gmu = sum(means) / len(means)
    between = sum((m - gmu) ** 2 for m in means) / (len(means) - 1)
    return (sum(within) / len(within)) / between if between > 0 else float("inf")


def collect(groups, drop_censored=True):
    """(tau_by_group, 진단 카운터). 뺀 것은 전부 센다 — 조용한 절단 금지."""
    tau_by_group, diag = {}, {"censored": 0, "missing": 0, "crashed": 0,
                              "groups_too_thin": 0, "boards_used": 0}
    for gkey, per_arm in groups.items():
        acc = {}
        for arm, board in per_arm.items():
            if board["crashed"]:
                diag["crashed"] += 1
                continue
            k = board.get("deviate_at")
            if k is None:
                diag["missing"] += 1
                continue
            t, censored = tau_at(board, k)
            if t is None:
                diag["missing"] += 1
                continue
            if censored:
                diag["censored"] += 1
                if drop_censored:
                    continue
            acc[arm] = t
            diag["boards_used"] += 1
        if len(acc) >= 2:
            tau_by_group[gkey] = acc
        else:
            diag["groups_too_thin"] += 1
    return tau_by_group, diag


def main(argv):
    import boards as _b
    groups = _b.load_groups()
    for drop in (True, False):
        tau, diag = collect(groups, drop_censored=drop)
        p, obs, null_med = block_permutation_p(tau, n_perm=2000, seed=0)
        ratio = variance_ratio(tau)
        label = "절단 제외" if drop else "절단 포함(makespan 까지)"
        print("=== G-S (%s) ===" % label)
        print("  그룹 %d개 / board %d개 사용" % (len(tau), diag["boards_used"]))
        print("  진단: %s" % diag)
        print("  분산비(팔 간 / 그룹 간) = %.4f" % ratio)
        print("  SS_arm 관측 %.4f · 귀무 중앙 %.4f · p = %.4f" % (obs, null_med, p))
        print("  판정: %s" % ("PASS — τ 가 팔에 의존한다 (SMDP)"
                              if p < 0.05 else
                              "FAIL — τ 가 외생이다. 여기서 멈추고 MDP 로 기술할 것"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
