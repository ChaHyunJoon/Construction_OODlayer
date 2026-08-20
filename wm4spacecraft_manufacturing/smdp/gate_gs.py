"""G-S — semi-Markov 검사 (spec §7). 가장 싼 반증이라 가장 먼저 돈다.

묻는 것: **같은 s 에서 팔만 바꿨을 때 다음 epoch 까지의 τ 가 팔에 의존하는가.**
  의존한다 → F(τ|s,a) 가 진짜로 a 에 의존 → SMDP 구조가 결정에 정보를 나른다.
  의존 안 한다 → τ 는 외생. 형식적으로는 SMDP 지만 'τ 를 안 봐도 되는 SMDP' = 실질 MDP.
                그러면 spec §5 전체가 장식이므로 **여기서 멈추고 그렇게 쓴다.**

🔴 **2026-08-19 리뷰 라운드 1 수정 (controller Ruling A)**: 원안의 `block_permutation_p`
(그룹 내 순열 + `_ss_arm`)은 **그룹 안에서** 팔 라벨을 섞으므로 그 그룹의 τ 다중집합
자체를 바꾸지 않는다 — 그래서 이 통계량은 "팔 순위가 그룹을 가로질러 **일관된** 가법
주효과인가" 만 볼 수 있고, 그룹 **내부**의 τ 산포에는 원리적으로 눈이 멀어 있다. 실제로
τ 가 100% 팔로 결정돼도 어느 팔이 느린지 그룹마다 회전하면 이 통계량은 "외생"이라고
잘못 선언한다(회귀 락: `test_spread_test_detects_rotating_arm_effect_that_old_stat_misses`).
**`block_permutation_p` 는 지우지 않는다** — 레거시 비교용으로 남긴다(아래 legacy 절 표시).
**판정은 이제 `spread_test` + `fisher_exact_greater`(블록 내 동일성 정확검정, 편차 이전
결정으로 교정)로 한다.**

왜 블록 순열만으로는 부족한가: 그룹(=case,seed)마다 τ 의 절대 수준이 크게 다르다. 그룹을
블록으로 잡는 발상 자체는 옳다 — 문제는 순열 대신 **동일성**을 검정해야 한다는 것이다.
한 그룹의 board 들은 결정 k 하나만 다르고 그 앞은 바이트 동일(2026-08-17 결정성 게이트,
84그룹 전부)하므로, 결정적 시뮬 하에서 귀무 "τ ⊥ a" 는 "그룹 내 τ 값이 전부 같다"를
예측한다 — 교환가능성이 아니라 **동일성**이다. 편차 **이전** 결정(k-1, k-2)은 팔이 아직
아무 일도 안 했으므로 이 예측이 실측으로 확인 가능한 음성 대조가 된다(스프레드가 0 이어야
한다). 그 경험적 귀무를 Fisher exact 로 결정 k 와 비교한다.

  python gate_gs.py            # 기본 경로로 실측
"""
import math
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

    ⚠️ **레거시 비교용 — 판정에 쓰지 않는다(2026-08-19 리뷰 라운드 1, Ruling A).**
    이 통계량은 그룹 안에서 라벨만 섞으므로 그룹의 τ 다중집합을 바꾸지 않는다. 그래서
    "그룹 내부에 산포가 있는가"를 원리적으로 볼 수 없고 오직 "팔 순위가 그룹을 가로질러
    일관된 가법 주효과인가" 만 검정한다. 판정은 `spread_test`+`fisher_exact_greater` 로 한다.
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
    """(그룹 내 팔 간 분산의 평균) / (그룹 평균들의 분산). **서술 통계량일 뿐 유효성
    기준이 아니다**(2026-08-19 리뷰 라운드 1, finding 4) — 절대 게이팅에 쓰지 말 것.

    분자는 팔 효과, 분모는 case×seed 이질성이다. 이 블록 설계(7 case × 서로 다른 seed,
    makespan 이 19s~100s+ 로 흩어짐)에서는 분모가 구조적으로 크므로, 팔이 τ 를 100% 지배해도
    그룹 간 이질성이 크면 이 비는 1 미만으로 나온다(실측 음성 대조: 팔 100% 결정 + 그룹수준만
    큰 분산 합성자료에서 ratio=0.0010). "ratio<1 ⇒ 효과 작음"은 성립하지 않는다 — 작은 것은
    그룹 간 이질성 대비 상대 크기이지 팔 효과의 절대 크기가 아니다.
    """
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


def spread_test(tau_by_group, tol=1e-9):
    """그룹별로 τ 값들이 서로 다른지(스프레드 = max-min > tol) 판정.
    반환: (스프레드 있는 그룹 수, 팔 2개 이상인 전체 그룹 수).

    **이것이 새 판정 통계량의 핵심이다(2026-08-19 리뷰 라운드 1, Ruling A).**
    `block_permutation_p`(그룹 간 일관된 주효과)와 달리 이 통계량은 그룹 **내부**의 τ
    산포를 직접 본다. 결정적 시뮬 + 그룹 내 동일 prefix 하에서, 귀무 "τ ⊥ a" 는 "그룹 내
    τ 값이 전부 같다"를 예측한다(교환가능성이 아니라 동일성) — 그래서 이 통계량은 그 예측을
    직접 검정할 수 있다.
    """
    n_spread = n_total = 0
    for per_arm in tau_by_group.values():
        vals = list(per_arm.values())
        if len(vals) < 2:
            continue
        n_total += 1
        if max(vals) - min(vals) > tol:
            n_spread += 1
    return n_spread, n_total


def relative_spread_stats(tau_by_group, tol=1e-9):
    """효과크기 보고용: (스프레드 있는 그룹들의 '스프레드/그룹평균' 중앙값,
    최대 스프레드(초), 그 그룹 key). 스프레드가 없는(tol 이하) 그룹은 제외한다."""
    rels = []
    max_sec, max_group = 0.0, None
    for gkey, per_arm in tau_by_group.items():
        vals = list(per_arm.values())
        if len(vals) < 2:
            continue
        spread = max(vals) - min(vals)
        if spread <= tol:
            continue
        mu = sum(vals) / len(vals)
        if mu:
            rels.append(spread / mu)
        if spread > max_sec:
            max_sec, max_group = spread, gkey
    rels.sort()
    med = rels[len(rels) // 2] if rels else float("nan")
    return med, max_sec, max_group


def fisher_exact_greater(a, b, c, d):
    """Fisher exact, 단측(row1 의 '성공'(=spread) 비율이 row2 보다 큰가).

    2x2 표:
        a  b   | n1 = a+b   (예: 결정 k 에서 스프레드 있음/없음)
        c  d   | n2 = c+d   (예: 결정 k-1 에서 스프레드 있음/없음)
    귀무: 행(=결정 k vs k-1)과 열(=스프레드 유무)이 독립 — 초기하분포로 정확검정.
    scipy/numpy 의존 없이 `math.comb` 로 직접 구현한다(2026-08-19 리뷰 라운드 1, finding 1).
    """
    n1, n2 = a + b, c + d
    total_success = a + c
    n_total = n1 + n2
    lo = max(0, total_success - n2)
    hi = min(n1, total_success)
    denom = math.comb(n_total, total_success)
    p = 0.0
    for x in range(a, hi + 1):
        p += math.comb(n1, x) * math.comb(n2, total_success - x) / denom
    return p


def collect(groups, drop_terminal=True, k_offset=0):
    """(tau_by_group, 진단 카운터). 뺀 것은 전부 센다 — 조용한 절단 금지.

    k_offset: `deviate_at` 에서 몇 칸 앞의 결정을 볼지(0=게이트 본체 k, 1=k-1, 2=k-2).
    k-1·k-2 는 편차 **이전**이라 한 그룹의 board 들이 바이트 동일한 prefix 를 공유한다 —
    거기서 스프레드가 나오면 팔 효과가 아니라 **하네스 비결정성**이라는 뜻이다(음성 대조,
    `gate_gs.py` 모듈 독스트링·`main()` 참조).

    🔴 **이름 정정(2026-08-19 리뷰 라운드 1, finding 5)**: 이 17건은 절단(censored)이
    아니다 — 전부 `complete=True` 인 완전관측 종단(terminal) sojourn 이다(makespan 까지
    관측이 "잘린" 게 아니라 그 option 이 실제로 에피소드 끝까지 갔다는 정확한 관측).
    `drop_terminal=True` 는 **유효한 관측 17건을 버리는 것**이고 `drop_terminal=False` 가
    옳은 처리다. (측정된 사실: 이 17건이 걸린 9개 그룹을 두 처리 양쪽에서 빼면
    n=55, SS_arm=83.313, p=0.0005 로 **완전히 일치**한다 — 즉 원래 두 처리 간 p-value
    불일치는 447개 관측 중 이 17개(3.8%)가 만든 것이었다. 이 사실은 새 판정 통계량이
    `drop_terminal=False`(=모든 유효 관측 포함)를 기본으로 쓰는 근거다.)
    """
    tau_by_group, diag = {}, {"terminal": 0, "missing": 0, "crashed": 0,
                              "groups_too_thin": 0, "boards_used": 0}
    for gkey, per_arm in groups.items():
        acc = {}
        for arm, board in per_arm.items():
            if board["crashed"]:
                # 구조적으로 항상 0 이다: 588개 중 유일한 crashed board(battery_zone_s2 의
                # ReformTeam)는 deviation_fired=False 라 load_groups(require_fired=True)
                # 에서 먼저 걸러진다. "crashed: 0" 을 크래시 부재의 증거로 인용하지 말 것 —
                # 이 카운터는 셀 수 있는 사건이 애초에 여기 도달하지 않는다(2026-08-19 리뷰,
                # finding 6 — 2026-08-16 "영원히 실패할 수 없는 검사" 와 같은 모양).
                diag["crashed"] += 1
                continue
            dk = board.get("deviate_at")
            if dk is None:
                diag["missing"] += 1
                continue
            k = dk - k_offset
            if k < 1:
                diag["missing"] += 1
                continue
            t, terminal = tau_at(board, k)
            if t is None:
                diag["missing"] += 1
                continue
            if terminal:
                diag["terminal"] += 1
                if drop_terminal:
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

    # ---- 음성 대조부터: 편차 이전(k-1, k-2)은 반드시 스프레드가 0 이어야 한다 ----
    # (2026-08-19 리뷰 라운드 1, finding 1 — "이 검사가 없으면 게이트가 실패할 수 있는지
    # 알 수 없다"는 전체 계획의 원칙을 G-S 의 새 통계량에도 그대로 적용한다.)
    print("=== G-S 음성 대조: 편차 이전 (k-1, k-2) — 반드시 먼저 확인 ===")
    print("  결정적 시뮬 + 그룹 내 바이트 동일 prefix 하에서 편차 이전 구간은 팔이 아직")
    print("  아무 일도 하지 않았다 — 스프레드가 0 이 아니면 하네스 비결정성 의심, 아래 판정 무효.")
    calib = {}
    for label, offset in (("k-1", 1), ("k-2", 2)):
        tau_off, _diag_off = collect(groups, drop_terminal=False, k_offset=offset)
        n_spread, n_grp = spread_test(tau_off)
        calib[label] = (n_spread, n_grp)
        print("  %-4s: 스프레드 있는 그룹 %d/%d  (기대: 0/%d)" % (label, n_spread, n_grp, n_grp))
    calibration_clean = all(n == 0 for n, _ in calib.values())
    print("  음성 대조 판정: %s" % ("통과 — 잡음 아님, 아래 판정 유효"
                                    if calibration_clean else
                                    "실패 — 편차 이전에도 스프레드가 있다. 하네스 비결정성 의심."))
    print()

    # ---- 레거시 통계량 (참고용, 판정에 쓰지 않음 — Ruling A) ----
    for drop in (True, False):
        tau, diag = collect(groups, drop_terminal=drop)
        p_legacy, ss_obs, ss_null = block_permutation_p(tau, n_perm=2000, seed=0)
        ratio = variance_ratio(tau)
        label = "종단 제외 (구 표현 '절단 제외' — 17건은 절단이 아니다, finding 5)" if drop \
            else "종단 포함 (makespan 까지 — 옳은 처리, finding 5)"
        print("=== G-S 레거시 (%s) — 판정에 쓰지 않음, 참고/비교용 ===" % label)
        print("  그룹 %d개 / board %d개 사용" % (len(tau), diag["boards_used"]))
        print("  진단: %s" % diag)
        print("  분산비(팔 간/그룹 간) = %.4f  ※ 유효성 기준 아님(finding 4) — 참고용" % ratio)
        print("  SS_arm(팔 주효과, 그룹 내 순열) 관측 %.4f · 귀무 중앙 %.4f · p = %.4f"
              " ※ 그룹 내 산포에 원리적으로 눈이 멀어 있다(Ruling A) — 판정에 안 씀"
              % (ss_obs, ss_null, p_legacy))
    print()

    # ---- 신규 통계량: 블록 내 동일성 정확검정 — 판정은 이것으로 한다 ----
    tau_k, diag_k = collect(groups, drop_terminal=False, k_offset=0)
    n_spread_k, n_grp_k = spread_test(tau_k)
    n_spread_km1, n_grp_km1 = calib["k-1"]
    p_fisher = fisher_exact_greater(n_spread_k, n_grp_k - n_spread_k,
                                    n_spread_km1, n_grp_km1 - n_spread_km1)
    med_rel, max_sec, max_group = relative_spread_stats(tau_k)

    print("=== G-S 본체: 블록 내 동일성 정확검정 (판정은 이것) ===")
    print("  결정 k 에서 그룹 내 스프레드 있는 그룹 %d/%d" % (n_spread_k, n_grp_k))
    print("  k-1 대비 Fisher exact one-sided p = %.6e" % p_fisher)
    print("  효과크기: 스프레드 중앙값(그룹 평균 대비) = %.1f%% · 최대 스프레드 = %.3fs (그룹 %s)"
          % (med_rel * 100.0 if med_rel == med_rel else float("nan"), max_sec, max_group))
    print("  참고(퇴역, finding 4): 위 레거시 절의 분산비는 판정에 안 쓴다.")

    if not calibration_clean:
        verdict = "FAIL — 편차 이전 음성 대조가 깨졌다(하네스 비결정성 의심). PASS 선언 불가."
    elif n_spread_k > 0 and p_fisher < 0.05:
        verdict = "PASS — τ 가 팔에 의존한다 (SMDP)"
    else:
        verdict = "FAIL — τ 가 외생이다. 여기서 멈추고 MDP 로 기술할 것"
    print("  판정: %s" % verdict)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
