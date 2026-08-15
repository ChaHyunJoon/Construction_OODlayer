#!/usr/bin/env python3
"""dp_solve 단위검사. 손계산 가능한 합성 표본만 쓴다 — 시뮬도 실제 표본도 안 쓴다."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from dp_solve import solve_constant_arm as solve   # noqa: E402
from dp_solve import solve_backward                # noqa: E402

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
    # 채점 불가 팔이 **0.0 으로 이기지 않는다**: Q 에 없고, V 는 채점된 팔의 값이다.
    check("채점 불가 팔이 0.0 으로 이기지 않는다", abs(v["c4"]["V"] - 5.0) < 1e-9,
          str(v["c4"]["V"]))
    # 그러나 a* 도 주장하지 않는다 — 채점된 팔이 하나뿐이면 argmin 이 아니다.
    check("채점된 팔이 하나뿐이면 a* 를 주장하지 않는다", v["c4"]["a_star"] is None,
          str(v["c4"]["a_star"]))
    check("그 이유가 single_arm 으로 남는다",
          v["c4"]["unresolved_reason"] == "single_arm", str(v["c4"].get("unresolved_reason")))

    # (6b) 팔이 둘 이상이고 격차가 크면 a* 가 나온다 -- 위 규칙이 전부를 막지 않는다는 확인.
    s5b = ([row("c4b", 8, k, c) for k, c in enumerate([1.0, 1.01, 0.99])] +
           [row("c4b", 1, k, c) for k, c in enumerate([50.0, 50.1, 49.9])] +
           [row("c4b", 2, k, None) for k in range(2)])
    v = solve(s5b)
    check("채점 팔 2개 + 큰 격차면 a* 가 나온다", v["c4b"]["a_star"] == 8, str(v["c4b"]["a_star"]))
    check("채점 불가 팔은 그래도 세어진다", v["c4b"]["n_unscorable"].get("2") == 2,
          str(v["c4b"]["n_unscorable"]))

    # (7) 전부 채점 불가인 칸은 V 가 None 이다 (0.0 이 아니다).
    v = solve([row("c5", 8, k, None) for k in range(3)])
    check("전부 채점 불가면 V=None", v["c5"]["V"] is None, str(v["c5"]["V"]))
    check("전부 채점 불가면 a*=None", v["c5"]["a_star"] is None, str(v["c5"]["a_star"]))

    # (8) 표본 1개짜리 팔은 SE 가 무한 -> tie 로 흡수된다(없는 확신을 만들지 않는다).
    s6 = [row("c6", 8, 0, 1.0), row("c6", 1, 0, 99.0)]
    v = solve(s6)
    check("표본 1개면 tie 로 남는다(a* 미확정)", v["c6"]["a_star"] is None, str(v["c6"]["tie"]))
    check("표본 1개짜리 2팔은 single_arm 이 아니라 tie 다",
          v["c6"]["unresolved_reason"] == "tie", str(v["c6"].get("unresolved_reason")))

    backward()

    print("\n%s" % ("전부 통과" if not FAILS else "실패 %d개: %s" % (len(FAILS), FAILS)))
    return 1 if FAILS else 0


# =====================================================================================
# solve_backward — 진짜 Bellman. 손계산 가능한 판만 쓴다.
# =====================================================================================
def tr(cell, arm, c, nxt=None, terminal=None, tv=None, board="b", unstateable=False):
    return {"cell": cell, "arm": arm, "c": c, "next_cell": nxt, "terminal": terminal,
            "terminal_value": tv, "next_unstateable": unstateable, "board_id": board}


A = "prog_b=0|x"      # 버킷 0 (앞)
B = "prog_b=1|x"      # 버킷 1 (뒤)


def backward():
    print("\n== solve_backward (Bellman) ==")

    # ---- (B1) 2-버킷 사슬. V 가 **뒤에서 앞으로** 전파되는가 --------------------------------
    #   B --(팔8, c=2)--> goal        => V(B) = 2
    #   A --(팔8, c=5)--> B           => Q(A,8) = 5 + V(B) = 7
    #   A --(팔1, c=100)--> goal      => Q(A,1) = 100
    #   => V(A) = 7, a*(A) = 8.  **판 단위 J 로는 이 답이 안 나온다** — 그게 이 검사의 요점이다.
    s = ([tr(B, 8, 2.0, terminal="goal", tv=0.0, board="b%d" % k) for k in range(3)] +
         [tr(A, 8, 5.0, nxt=B, board="b%d" % k) for k in range(3)] +
         [tr(A, 1, 100.0, terminal="goal", tv=0.0, board="c%d" % k) for k in range(3)])
    v, st = solve_backward(s)
    check("B1 V(B) = 2 (종단 goal 은 0)", abs(v[B]["V"] - 2.0) < 1e-9, str(v[B]["V"]))
    check("B1 V(A) = 7 = c + V(B)  <- 뒤에서 앞으로 전파", abs(v[A]["V"] - 7.0) < 1e-9,
          str(v[A]["V"]))
    check("B1 a*(A) = 8", v[A]["a_star"] == 8, str(v[A]["a_star"]))
    check("B1 Q(A,1) = 100 (전파와 무관한 직행 팔)", abs(v[A]["Q"]["1"] - 100.0) < 1e-9,
          str(v[A]["Q"]))
    check("B1 dangling 0", st.get("dangling_transitions", 0) == 0, str(st))
    check("B1 버킷을 기록한다", v[A]["prog_bucket"] == 0 and v[B]["prog_bucket"] == 1,
          str((v[A]["prog_bucket"], v[B]["prog_bucket"])))

    # ---- (B2) dead_end 는 표본이 실어 온 정산값을 쓴다 -------------------------------------
    s2 = ([tr(B, 8, 1.0, terminal="dead_end", tv=9000.0, board="b%d" % k) for k in range(3)] +
          [tr(B, 1, 1.0, terminal="goal", tv=0.0, board="c%d" % k) for k in range(3)])
    v, _ = solve_backward(s2)
    check("B2 dead_end 팔의 Q = c + terminal_value", abs(v[B]["Q"]["8"] - 9001.0) < 1e-9,
          str(v[B]["Q"]))
    check("B2 goal 팔이 이긴다", v[B]["a_star"] == 1, str(v[B]["a_star"]))

    # ---- (B3) 자기순환 칸이 수렴하는가 (같은 버킷 안의 결정 반복) ----------------------------
    #   A --(팔8, c=1)--> A  (자기순환) 이고 A --(팔1, c=3)--> goal.
    #   순환만 있는 팔은 고정점에서 Q(A,8) = 1 + V(A) 이고 V(A) = min(3, 1+V(A)) = 3.
    s3 = ([tr(A, 8, 1.0, nxt=A, board="b%d" % k) for k in range(3)] +
          [tr(A, 1, 3.0, terminal="goal", tv=0.0, board="c%d" % k) for k in range(3)])
    v, st = solve_backward(s3)
    check("B3 자기순환 칸이 수렴한다", v[A]["converged"] is True, str(v[A].get("converged")))
    check("B3 V(A) = 3 (순환 팔은 1+V(A)=4 로 지고, 탈출 팔이 이긴다)",
          abs(v[A]["V"] - 3.0) < 1e-6, str(v[A]["V"]))
    check("B3 a*(A) = 1", v[A]["a_star"] == 1, str(v[A]["a_star"]))
    check("B3 value iteration 반복수를 남긴다", v[A]["vi_iters"] >= 1, str(v[A].get("vi_iters")))
    check("B3 수렴 실패 0", st.get("cells_not_converged", 0) == 0, str(st))

    # ---- (B4) dangling: 다음 칸이 표에 없으면 V=0 으로 두지 않는다 ---------------------------
    s4 = ([tr(A, 8, 1.0, nxt="prog_b=9|없는칸", board="b%d" % k) for k in range(3)] +
          [tr(A, 1, 50.0, terminal="goal", tv=0.0, board="c%d" % k) for k in range(3)])
    v, st = solve_backward(s4)
    check("B4 표 밖으로 나가는 팔은 Q 에 없다", set(v[A]["Q"]) == {"1"}, str(v[A]["Q"]))
    check("B4 V 는 남은 팔의 값 (0 이 아니다)", abs(v[A]["V"] - 50.0) < 1e-9, str(v[A]["V"]))
    check("B4 dangling 을 센다", st.get("dangling_transitions") == 3, str(st))
    check("B4 사유를 이름으로 남긴다", st.get("dangling:next_missing") == 3, str(st))
    check("B4 그 팔의 사유가 칸에도 남는다",
          v[A]["n_dangling"].get("8", {}).get("next_missing") == 3, str(v[A]["n_dangling"]))
    # 팔이 하나만 남았으므로 a* 를 주장하지 않는다 (승계 규칙 2).
    check("B4 남은 팔 하나로 a* 를 주장하지 않는다",
          v[A]["a_star"] is None and v[A]["unresolved_reason"] == "single_arm",
          str(v[A].get("unresolved_reason")))

    # dangling 을 0 으로 뒀다면 팔 8 의 Q 는 1.0 이라 **이겼을 것**이다. 그 반사실을 못박는다.
    check("B4 dangling 을 0 으로 뒀다면 이겼을 팔이 실제로 졌다",
          8 not in [int(k) for k in v[A]["Q"]], str(v[A]["Q"]))

    # ---- (B5) 다음 결정이 칸으로 라벨되지 않는 경우 -----------------------------------------
    s5 = ([tr(A, 8, 1.0, nxt=None, unstateable=True, board="b%d" % k) for k in range(3)] +
          [tr(A, 1, 50.0, terminal="goal", tv=0.0, board="c%d" % k) for k in range(3)])
    v, st = solve_backward(s5)
    check("B5 next_unstateable 을 따로 센다", st.get("dangling:next_unstateable") == 3, str(st))

    # ---- (B6) J 채점 불가 판의 종단은 값이 없다 ---------------------------------------------
    s6 = ([tr(B, 8, 1.0, terminal="dead_end", tv=None, board="b%d" % k) for k in range(3)] +
          [tr(B, 1, 5.0, terminal="goal", tv=0.0, board="c%d" % k) for k in range(3)])
    v, st = solve_backward(s6)
    check("B6 terminal_value 없음을 이름으로 센다",
          st.get("dangling:terminal_value_missing") == 3, str(st))
    check("B6 그래도 남은 팔로 V 를 낸다", abs(v[B]["V"] - 5.0) < 1e-9, str(v[B]["V"]))

    # ---- (B7) 전부 못 쓰면 V=None (0.0 이 아니다) -------------------------------------------
    v, _ = solve_backward([tr(A, 8, 1.0, nxt="없는칸", board="b%d" % k) for k in range(3)])
    check("B7 전부 dangling 이면 V=None", v[A]["V"] is None, str(v[A]["V"]))
    check("B7 이유가 no_scorable_arm", v[A]["unresolved_reason"] == "no_scorable_arm",
          str(v[A].get("unresolved_reason")))

    # ---- (B8) 완전 동점은 tie 다 (승계 규칙 1, `<=` 경계) -----------------------------------
    s8 = ([tr(A, 8, 2.0, terminal="goal", tv=0.0, board="b%d" % k) for k in range(3)] +
          [tr(A, 1, 2.0, terminal="goal", tv=0.0, board="c%d" % k) for k in range(3)])
    v, _ = solve_backward(s8)
    check("B8 완전 동점 -> tie 집합에 둘 다", set(map(int, v[A]["tie"])) == {1, 8}, str(v[A]["tie"]))
    check("B8 완전 동점 -> a* 는 None", v[A]["a_star"] is None, str(v[A]["a_star"]))

    # ---- (B9) 결정성 (원 설계 §8.8) ----------------------------------------------------------
    check("B9 결정적", solve_backward(s) == solve_backward(s))
    check("B9 표본 0 이면 빈 표", solve_backward([]) == ({}, {}), str(solve_backward([])))

    # ---- (B10) 3-버킷 사슬 — 전파가 두 단계 이상 이어지는가 ----------------------------------
    C = "prog_b=2|x"
    s10 = ([tr(C, 8, 4.0, terminal="goal", tv=0.0, board="b%d" % k) for k in range(3)] +
           [tr(B, 8, 3.0, nxt=C, board="b%d" % k) for k in range(3)] +
           [tr(A, 8, 2.0, nxt=B, board="b%d" % k) for k in range(3)])
    v, _ = solve_backward(s10)
    check("B10 V = 4 / 7 / 9 로 뒤에서 앞으로 누적된다",
          abs(v[C]["V"] - 4.0) < 1e-9 and abs(v[B]["V"] - 7.0) < 1e-9
          and abs(v[A]["V"] - 9.0) < 1e-9,
          str((v[C]["V"], v[B]["V"], v[A]["V"])))


if __name__ == "__main__":
    sys.exit(main())
