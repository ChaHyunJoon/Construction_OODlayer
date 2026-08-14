#!/usr/bin/env python3
"""dp_solve 단위검사. 손계산 가능한 합성 표본만 쓴다 — 시뮬도 실제 표본도 안 쓴다."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from dp_solve import solve   # noqa: E402

FAILS = []


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + ("   " + detail if detail else ""))
    if not cond:
        FAILS.append(name)


def row(cell, arm, k, cost, terminal="goal", board=None):
    return {"cell": cell, "arm": arm, "k": k, "cost": cost, "terminal": terminal,
            "next_cell": None, "capped": False,
            "board_id": board if board is not None else "%s_%s_%s" % (cell, arm, k)}


def main():
    print("== dp_solve ==")

    # (1) 한 칸, 두 팔. 팔 8 = 평균 2.0, 팔 1 = 평균 5.0  ->  a* = 8, V = 2.0
    s1 = ([row("prog_b=0|x", 8, k, c) for k, c in enumerate([1.0, 2.0, 3.0])] +
          [row("prog_b=0|x", 1, k, c) for k, c in enumerate([4.0, 5.0, 6.0])])
    v = solve(s1)
    c0 = v["prog_b=0|x"]
    check("V = 최소 Q", abs(c0["V"] - 2.0) < 1e-9, str(c0["V"]))
    check("a* = 8", c0["a_star"] == 8, str(c0["a_star"]))
    check("Q 를 팔마다 낸다", set(c0["Q"]) == {"8", "1"}, str(c0["Q"]))
    check("표본수를 기록한다", c0["n"]["8"] == 3, str(c0["n"]))
    check("판 수를 따로 센다", c0["n_boards"]["8"] == 3, str(c0["n_boards"]))

    # (2) 완전 동점이면 단일 a* 를 뽑지 않고 tie 집합으로 낸다 (원 설계 §7).
    s3 = ([row("c2", 8, k, 2.0) for k in range(3)] +
          [row("c2", 1, k, 2.0) for k in range(3)])
    v = solve(s3)
    check("완전 동점이면 tie 집합이 둘 다 담는다", set(map(int, v["c2"]["tie"])) == {1, 8},
          str(v["c2"]["tie"]))
    check("동점이면 a* 는 None", v["c2"]["a_star"] is None, str(v["c2"]["a_star"]))

    # (3) 격차가 노이즈보다 훨씬 크면 tie 가 아니다.
    s4 = ([row("c3", 8, k, c) for k, c in enumerate([1.0, 1.01, 0.99])] +
          [row("c3", 1, k, c) for k, c in enumerate([50.0, 50.1, 49.9])])
    v = solve(s4)
    check("큰 격차는 tie 가 아니다", v["c3"]["a_star"] == 8, str(v["c3"]["tie"]))

    # (4) 결정성 — 같은 입력 같은 출력 (원 설계 §8.8)
    check("결정적", solve(s1) == solve(s1))

    # (5) 표본 0 이면 값을 지어내지 않는다.
    check("표본이 없으면 빈 표", solve([]) == {}, str(solve([])))

    # (6) J 채점 불가 표본은 **평균에 안 들어가고 세어진다** (0 으로 채우면 그 팔이 공짜로 보인다).
    s5 = ([row("c4", 8, k, 5.0) for k in range(3)] +
          [row("c4", 1, k, None) for k in range(3)])
    v = solve(s5)
    check("채점 불가 팔은 Q 에 없다", set(v["c4"]["Q"]) == {"8"}, str(v["c4"]["Q"]))
    check("채점 불가 개수를 센다", v["c4"]["n_unscorable"].get("1") == 3,
          str(v["c4"]["n_unscorable"]))
    check("채점 불가 팔이 0.0 으로 이기지 않는다", v["c4"]["a_star"] == 8, str(v["c4"]["a_star"]))

    # (7) 전부 채점 불가인 칸은 V 가 None 이다 (0.0 이 아니다).
    v = solve([row("c5", 8, k, None) for k in range(3)])
    check("전부 채점 불가면 V=None", v["c5"]["V"] is None, str(v["c5"]["V"]))
    check("전부 채점 불가면 a*=None", v["c5"]["a_star"] is None, str(v["c5"]["a_star"]))

    # (8) 표본 1개짜리 팔은 SE 가 무한 -> tie 로 흡수된다(없는 확신을 만들지 않는다).
    s6 = [row("c6", 8, 0, 1.0), row("c6", 1, 0, 99.0)]
    v = solve(s6)
    check("표본 1개면 tie 로 남는다(a* 미확정)", v["c6"]["a_star"] is None, str(v["c6"]["tie"]))

    print("\n%s" % ("전부 통과" if not FAILS else "실패 %d개: %s" % (len(FAILS), FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
