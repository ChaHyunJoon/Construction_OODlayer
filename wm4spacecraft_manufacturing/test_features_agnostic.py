#!/usr/bin/env python3
"""features_agnostic 의 행동 서술자 회귀 검사.

핵심 계약: **SwapBattery(8) 는 NOOP(0) 과 구별되어야 한다.**
2026-08-13 실측 결함: MACRO_SPECS 에 키 8 이 없어 psi(8) 이 빈 리스트로 조회되고
NOOP 의 ψ 벡터를 그대로 돌려줬다(psi(8) == psi(0) -> True). _PRIMITIVE_TABLE 에는
"SwapBattery" 가 이미 정의돼 있었으므로 빠진 것은 매크로->primitive 매핑 한 줄뿐이다.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from features_agnostic import psi, PSI_AXES, MACRO_SPECS, MACRO_COST

FAILS = []


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + ("   " + detail if detail else ""))
    if not cond:
        FAILS.append(name)


def main():
    print("== features_agnostic 행동 서술자 ==")

    check("MACRO_SPECS 에 8(SwapBattery) 가 있다", 8 in MACRO_SPECS,
          "keys=%s" % sorted(MACRO_SPECS))

    p8, p0, p1 = psi(8), psi(0), psi(1)

    check("psi(8) != psi(0)  — SwapBattery 가 NOOP 과 구별된다", p8 != p0)
    check("psi(8) != psi(1)  — SwapBattery 가 Replace 와 구별된다", p8 != p1)

    # 두 팔을 가르는 축(설계 주석이 지목한 것): 스페어 소모 여부와 가역성.
    check("a_consumes_spare: Swap 0 vs Replace 1",
          p8["a_consumes_spare"] == 0.0 and p1["a_consumes_spare"] == 1.0,
          "swap=%s replace=%s" % (p8["a_consumes_spare"], p1["a_consumes_spare"]))
    check("a_reversible: Swap 1 vs Replace 0",
          p8["a_reversible"] == 1.0 and p1["a_reversible"] == 0.0,
          "swap=%s replace=%s" % (p8["a_reversible"], p1["a_reversible"]))
    check("a_restores_capacity: 둘 다 1 (능력을 되돌린다)",
          p8["a_restores_capacity"] == 1.0 and p1["a_restores_capacity"] == 1.0)
    check("a_intervenes: Swap 은 개입이다(1)", p8["a_intervenes"] == 1.0)

    # a_cost 는 MACRO_COST 와 같은 값이어야 한다(함정 29: 표가 복붙되면 조용히 갈린다).
    check("a_cost == MACRO_COST[8]", p8["a_cost"] == MACRO_COST[8],
          "psi=%s table=%s" % (p8["a_cost"], MACRO_COST[8]))

    check("ψ 축 개수가 PSI_AXES 와 같다", set(p8) == set(PSI_AXES))

    print("\n%s" % ("전부 통과" if not FAILS else "실패 %d개: %s" % (len(FAILS), FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
