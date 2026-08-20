"""G2 — coupling test (spec §7). 순차 결정 문제인가, contextual bandit 인가.

묻는 것: **같은 시드·같은 월드에서 결정 k 의 팔만 바꾸면 결정 k+1 의 선택이 바뀌는가.**
  유의하게 > 0 → 순차 결정 문제 성립.
  ≈ 0        → 정직하게 contextual bandit 이라고 쓴다.

⚠️ G2 와 G-S 는 다른 질문이다. G2 는 *순차인가*, G-S 는 *semi-Markov 인가*,
G-M 은 *Markov 인가* 를 잰다. 1차 개정이 이 셋을 하나로 뭉갰다.

🔴 **2026-08-19 리뷰 라운드 1 수정 (controller Ruling B)**: 원안의 자격 필터
(`len(valid) < 2` 면 제외)는 바로 아래 문단이 인용하는 규약을 **뒤집어** 적용했다.
`valid == []` 는 '제한 없음'(policy.jl:413) — 즉 **전체 메뉴**이지 메뉴가 없다는 뜻이
아니다. 그런데 원안 필터는 그것을 `len([]) < 2 == True` 로 계산해 자격에서 뺐다. 실측:
그렇게 빠지는 308 board(ReformTruth 272 + FaultTruth 36) 안에 **결합이 관측되는 그룹
13개 전부**가 들어 있었다 — 즉 원안 필터는 결합이 있는 관측 100% 를 분모에서 지운다.
`coupling_rate`(원안 그대로, 레거시 비교용)와 `coupling_rate_corrected`(수정 필터) 를
**둘 다** 계산해 나란히 보고한다 — 어느 쪽도 조용히 고르지 않는다.

분모 규약(spec §1.4, 수정됨): `valid` 리스트의 길이가 2 이상이거나 `valid == []`
('제한 없음'=전체 메뉴)인 결정만 센다. 진짜로 배제해야 하는 것은 `len(valid) in {0,1}`
**이면서 valid 가 빈 리스트가 아닌** 경우(= 실제로 메뉴가 하나뿐인 경우)뿐이다.

또한 macro@k+1 라벨 동일성은 결합의 **약한** 대리 지표다 — 매크로 *이름*은 같아도
`sim_t_at`·이후 궤적 전체가 팔에 따라 달라질 수 있다. `suffix_divergence_rate` 가
"편차 이후 전체 미래가 갈리는가"라는 더 강한 질문을 별도로 잰다.

  python gate_g2.py
"""
import sys


def _next_decision(board, k):
    for d in board["decisions"]:
        if d.get("decision_index") == k + 1:
            return d
    return None


def coupling_rate(groups):
    """{n_groups, n_eligible, n_coupled, rate, dropped_boards, dropped_groups, per_case}.

    ⚠️ **레거시 — 브리프 원안의 자격 필터 그대로다(2026-08-19 리뷰 라운드 1 참조).**
    `valid == []`('제한 없음'=전체 메뉴)를 '메뉴 없음'으로 오독해 자격에서 뺀다. 결합이
    있는 그룹 전부가 그렇게 지워지는 자리에 있으므로 이 함수의 `rate` 는 **결합의 부재를
    보여주지 않는다** — 원안과의 대조를 위해서만 남긴다. 실제 판정에는 `coupling_rate_corrected`
    를 쓸 것.
    """
    n_eligible = n_coupled = 0
    dropped_boards = {"crashed": 0, "no_next": 0, "single_option": 0}
    dropped_groups = {"thin": 0}
    per_case = {}
    for (case, _seed), per_arm in groups.items():
        macros, eligible = {}, False
        for arm, board in per_arm.items():
            if board["crashed"]:
                dropped_boards["crashed"] += 1
                continue
            k = board.get("deviate_at")
            nxt = _next_decision(board, k) if k is not None else None
            if nxt is None:
                dropped_boards["no_next"] += 1
                continue
            if len(nxt.get("valid") or []) < 2:
                dropped_boards["single_option"] += 1
                continue
            eligible = True
            macros[arm] = nxt.get("macro")
        if not eligible or len(macros) < 2:
            dropped_groups["thin"] += 1
            continue
        n_eligible += 1
        coupled = len(set(macros.values())) > 1
        n_coupled += int(coupled)
        c = per_case.setdefault(case, [0, 0])
        c[0] += 1
        c[1] += int(coupled)
    return {"n_groups": len(groups), "n_eligible": n_eligible, "n_coupled": n_coupled,
            "rate": (n_coupled / n_eligible) if n_eligible else float("nan"),
            "dropped_boards": dropped_boards, "dropped_groups": dropped_groups,
            "per_case": per_case}


def _eligible_valid(valid_list):
    """메뉴 ≥2 이거나 valid==[]('제한 없음'=전체 메뉴, policy.jl:413·CLAUDE.md 2026-08-17
    절). 원안 필터는 이 둘째 절을 빠뜨려 '제한 없음'을 '메뉴 없음'으로 오독했다."""
    v = valid_list or []
    return len(v) >= 2 or v == []


def coupling_rate_corrected(groups):
    """coupling_rate 와 동일한 로직이되 자격 필터만 고쳤다(Ruling B):
    valid==[] 는 전체 메뉴이므로 자격에서 빼지 않는다. 실제로 단일 옵션인 경우
    (len(valid) in {1} — 명시적으로 비어있지 않은 1개짜리 메뉴)만 제외한다.
    {n_groups, n_eligible, n_coupled, rate, dropped_boards, dropped_groups, per_case}."""
    n_eligible = n_coupled = 0
    dropped_boards = {"crashed": 0, "no_next": 0, "menu_lt2": 0}
    dropped_groups = {"thin": 0}
    per_case = {}
    for (case, _seed), per_arm in groups.items():
        macros, eligible = {}, False
        for arm, board in per_arm.items():
            if board["crashed"]:
                dropped_boards["crashed"] += 1
                continue
            k = board.get("deviate_at")
            nxt = _next_decision(board, k) if k is not None else None
            if nxt is None:
                dropped_boards["no_next"] += 1
                continue
            if not _eligible_valid(nxt.get("valid")):
                dropped_boards["menu_lt2"] += 1
                continue
            eligible = True
            macros[arm] = nxt.get("macro")
        if not eligible or len(macros) < 2:
            dropped_groups["thin"] += 1
            continue
        n_eligible += 1
        coupled = len(set(macros.values())) > 1
        n_coupled += int(coupled)
        c = per_case.setdefault(case, [0, 0])
        c[0] += 1
        c[1] += int(coupled)
    return {"n_groups": len(groups), "n_eligible": n_eligible, "n_coupled": n_coupled,
            "rate": (n_coupled / n_eligible) if n_eligible else float("nan"),
            "dropped_boards": dropped_boards, "dropped_groups": dropped_groups,
            "per_case": per_case}


def _suffix(board, k):
    """결정 k(=deviate_at) 이후 전체 궤적을 (decision_index, sim_t_at, truth, macro) 튜플의
    튜플로 뽑는다. 비교 가능한(해시 가능한) 스냅샷이다."""
    return tuple((d.get("decision_index"), d.get("sim_t_at"), d.get("truth"), d.get("macro"))
                 for d in board["decisions"]
                 if d.get("decision_index") is not None and d.get("decision_index") > k)


def suffix_divergence_rate(groups):
    """편차 이후 전체 궤적이 팔에 따라 갈리는 그룹의 비율 — {n_groups, n_diverged, rate}.

    macro@k+1 라벨 동일성(coupling_rate)보다 훨씬 강한 결합 개념이다: 매크로 *이름*이
    같아도 그 뒤 sim_t·truth·macro 열 전체가 팔에 따라 달라지면 '미래가 달라졌다'로 센다.
    2026-08-19 리뷰 라운드 1, finding 2 의 둘째 지적("0 coupled 는 매크로 라벨 동일성일
    뿐 미래 독립성이 아니다")을 직접 재는 자리다.
    """
    n_groups = n_diverged = 0
    for per_arm in groups.values():
        if len(per_arm) < 2:
            continue
        suffixes = []
        for board in per_arm.values():
            k = board.get("deviate_at")
            if k is None:
                continue
            suffixes.append(_suffix(board, k))
        if len(suffixes) < 2:
            continue
        n_groups += 1
        if len(set(suffixes)) > 1:
            n_diverged += 1
    return {"n_groups": n_groups, "n_diverged": n_diverged,
            "rate": (n_diverged / n_groups) if n_groups else float("nan")}


def main(argv):
    import boards as _b
    groups = _b.load_groups()

    brief_out = coupling_rate(groups)
    corrected_out = coupling_rate_corrected(groups)
    suffix_out = suffix_divergence_rate(groups)

    print("=== G2 coupling — 자격 필터 두 가지를 나란히 보고한다 (2026-08-19 리뷰 라운드 1) ===")
    print("  브리프 필터 (valid==[] 제외, 레거시)   : 자격 %d · 결합 %d · 비율 %.3f"
          % (brief_out["n_eligible"], brief_out["n_coupled"], brief_out["rate"]))
    print("    제외(board 단위): %s · 제외(group 단위): %s"
          % (brief_out["dropped_boards"], brief_out["dropped_groups"]))
    print("  수정 필터 (valid==[]='제한 없음' 포함) : 자격 %d · 결합 %d · 비율 %.3f"
          % (corrected_out["n_eligible"], corrected_out["n_coupled"], corrected_out["rate"]))
    print("    제외(board 단위): %s · 제외(group 단위): %s"
          % (corrected_out["dropped_boards"], corrected_out["dropped_groups"]))
    print("  case 별 (수정 필터 기준):")
    for case, (n, c) in sorted(corrected_out["per_case"].items()):
        print("    %-14s %3d/%3d" % (case, c, n))
    print()
    print("  편차 이후 전체 궤적(suffix: sim_t·truth·macro 열)이 팔에 따라 갈리는 그룹 비율")
    print("  (macro@k+1 라벨 동일성보다 강한 결합 개념 — '미래가 달라지는가' 자체를 본다):")
    print("    %d/%d = %.3f" % (suffix_out["n_diverged"], suffix_out["n_groups"], suffix_out["rate"]))
    print()
    verdict = ("PASS — 순차 결정 문제 성립 (수정 필터 기준)"
               if corrected_out["n_eligible"] and corrected_out["rate"] > 0.0 else
               "FAIL — contextual bandit 으로 기술할 것")
    print("  판정 (수정 필터 기준): %s" % verdict)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
