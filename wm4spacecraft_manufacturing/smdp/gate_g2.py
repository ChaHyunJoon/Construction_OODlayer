"""G2 — coupling test (spec §7). 순차 결정 문제인가, contextual bandit 인가.

묻는 것: **같은 시드·같은 월드에서 결정 k 의 팔만 바꾸면 결정 k+1 의 선택이 바뀌는가.**
  유의하게 > 0 → 순차 결정 문제 성립.
  ≈ 0        → 정직하게 contextual bandit 이라고 쓴다.

⚠️ G2 와 G-S 는 다른 질문이다. G2 는 *순차인가*, G-S 는 *semi-Markov 인가*,
G-M 은 *Markov 인가* 를 잰다. 1차 개정이 이 셋을 하나로 뭉갰다.

분모 규약(spec §1.4): `valid` 리스트의 길이가 2 이상인 결정만 센다. `valid == []` 는
'제한 없음' 규약(policy.jl:413)이지 메뉴가 아니다 — 1438 로 나누면 957건의 단일-팔
결정이 자동으로 '결합 없음' 에 들어가 비율이 인위적으로 낮아진다.

  python gate_g2.py
"""
import sys


def _next_decision(board, k):
    for d in board["decisions"]:
        if d.get("decision_index") == k + 1:
            return d
    return None


def coupling_rate(groups):
    """{n_groups, n_eligible, n_coupled, rate, dropped}."""
    n_eligible = n_coupled = 0
    dropped = {"crashed": 0, "no_next": 0, "single_option": 0, "thin": 0}
    per_case = {}
    for (case, _seed), per_arm in groups.items():
        macros, eligible = {}, False
        for arm, board in per_arm.items():
            if board["crashed"]:
                dropped["crashed"] += 1
                continue
            k = board.get("deviate_at")
            nxt = _next_decision(board, k) if k is not None else None
            if nxt is None:
                dropped["no_next"] += 1
                continue
            if len(nxt.get("valid") or []) < 2:
                dropped["single_option"] += 1
                continue
            eligible = True
            macros[arm] = nxt.get("macro")
        if not eligible or len(macros) < 2:
            dropped["thin"] += 1
            continue
        n_eligible += 1
        coupled = len(set(macros.values())) > 1
        n_coupled += int(coupled)
        c = per_case.setdefault(case, [0, 0])
        c[0] += 1
        c[1] += int(coupled)
    return {"n_groups": len(groups), "n_eligible": n_eligible, "n_coupled": n_coupled,
            "rate": (n_coupled / n_eligible) if n_eligible else float("nan"),
            "dropped": dropped, "per_case": per_case}


def main(argv):
    import boards as _b
    out = coupling_rate(_b.load_groups())
    print("=== G2 coupling (분모 = 선택지 2개 이상인 결정) ===")
    print("  그룹 %d · 자격 %d · 결합 %d · 비율 %.3f"
          % (out["n_groups"], out["n_eligible"], out["n_coupled"], out["rate"]))
    print("  제외: %s" % out["dropped"])
    for case, (n, c) in sorted(out["per_case"].items()):
        print("    %-14s %3d/%3d" % (case, c, n))
    print("  판정: %s" % ("PASS — 순차 결정 문제 성립"
                          if out["n_eligible"] and out["rate"] > 0.0 else
                          "FAIL — contextual bandit 으로 기술할 것"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
