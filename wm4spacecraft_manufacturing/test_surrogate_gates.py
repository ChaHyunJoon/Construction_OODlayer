#!/usr/bin/env python3
"""surrogate_gates 의 단위검사 — 게이트가 실제로 붕괴를 잡는지 합성 데이터로 증명한다."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from surrogate_gates import (constant_policy_baseline, gate_g3_beats_constant,
                             gate_g4_kind_discrimination, gate_g4b_menu_invariance)

FAILS = []


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + ("   " + detail if detail else ""))
    if not cond:
        FAILS.append(name)


# battery 에서는 8(SwapBattery)이, fault 에서는 1(Replace)이 정답인 합성 격자.
INSTANCES = (
    [{"instance": "b%d" % i, "kind": "battery",
      "truth": {0: 0.0, 1: 5.0, 8: 10.0}, "valid": [0, 1, 8]} for i in range(10)] +
    [{"instance": "f%d" % i, "kind": "fault",
      "truth": {0: 0.0, 1: 10.0, 8: 2.0}, "valid": [0, 1, 8]} for i in range(10)]
)

PERFECT  = {r["instance"]: (8 if r["kind"] == "battery" else 1) for r in INSTANCES}
ALWAYS_1 = {r["instance"]: 1 for r in INSTANCES}          # 2026-08-13 의 실제 결함 모양
ALWAYS_0 = {r["instance"]: 0 for r in INSTANCES}

# ---------------------------------------------------------------------------
# G4 knife-edge 회귀: 산술적으로 완벽한 동률이 아니어도(237/238 vs 238/238) 잡아야 한다.
# ---------------------------------------------------------------------------
NEAR_CONST_INSTANCES = (
    [{"instance": "nb%d" % i, "kind": "battery", "truth": {}} for i in range(238)] +
    [{"instance": "nf%d" % i, "kind": "fault", "truth": {}} for i in range(238)]
)
NEAR_CONST_CHOICES = {}
for _i in range(238):
    # battery: 237x Replace(1), 1x NOOP(0) -- 산술적으로 fault(238x Replace)와 "완전히 같지"는 않다.
    NEAR_CONST_CHOICES["nb%d" % _i] = 1 if _i < 237 else 0
    NEAR_CONST_CHOICES["nf%d" % _i] = 1

# ---------------------------------------------------------------------------
# G4 정규화 커버리지: kind 별 표본 수(n)가 달라도 "비율"이 같으면 잡아야 한다.
# (surrogate_gates.py:87-88 의 정규화 산술이 실제로 켜져 있는지를 검사 — INSTANCES 는
#  두 kind 가 우연히 n=10 으로 같아서 이 회귀를 못 잡는다.)
# ---------------------------------------------------------------------------
NORM_INSTANCES = (
    [{"instance": "small%d" % i, "kind": "small_n", "truth": {}} for i in range(5)] +
    [{"instance": "large%d" % i, "kind": "large_n", "truth": {}} for i in range(20)]
)
NORM_CHOICES = {r["instance"]: 1 for r in NORM_INSTANCES}  # 두 kind 모두 100% arm 1, 표본수만 5 vs 20

# ---------------------------------------------------------------------------
# G4b: legal menu 로만 묶었을 때 답이 menu 의 순수 함수인가.
# ---------------------------------------------------------------------------
# 상태를 실제로 쓰는 정책: 같은 menu {0,1,8} 안에서도 절반은 8(SwapBattery), 절반은 0(NOOP).
MENU_VARIED = (
    [{"instance": "v%d" % i, "menu": [0, 1, 8], "choice": (8 if i % 2 == 0 else 0)}
     for i in range(10)]
)
# 2026-08-13 배포 모델의 실제 모양: menu 안에서 항상 MACRO_COST 최댓값 팔만 고른다.
#   menu {0,1,8}: 최댓값은 1(Replace, cost 1.0) -- 매번 1 만 나온다.
#   menu {0,4}:   최댓값은 4(ReformTeam, cost 1.0) -- 매번 4 만 나온다.
#   menu {0,2}:   표본이 min_group(5) 미만이라 skip 대상이어야 한다.
MENU_COLLAPSED = (
    [{"instance": "c%d" % i, "menu": [0, 1, 8], "choice": 1} for i in range(10)] +
    [{"instance": "d%d" % i, "menu": [0, 4], "choice": 4} for i in range(10)] +
    [{"instance": "e%d" % i, "menu": [0, 2], "choice": 2} for i in range(2)]
)


def main():
    print("== surrogate_gates 단위검사 ==")

    base = constant_policy_baseline(INSTANCES)
    check("상수 baseline 이 세 팔 전부를 계산한다", set(base) == {0, 1, 8}, str(base))
    # 항상 1 = battery 에서 5 손해, fault 에서 0 손해 -> 평균 2.5
    check("항상-Replace 의 평균 regret = 2.5", abs(base[1] - 2.5) < 1e-9, str(base[1]))

    ok, info = gate_g3_beats_constant(INSTANCES, PERFECT)
    check("G3: 완벽한 정책은 통과", ok, str(info["model_regret"]))
    check("G3: observed_margin 이 숫자로 반환된다", isinstance(info["observed_margin"], float),
          str(info.get("observed_margin")))

    ok, info = gate_g3_beats_constant(INSTANCES, ALWAYS_1)
    check("G3: 상수 정책은 **실패**해야 한다", not ok,
          "model=%.2f best_const=%.2f" % (info["model_regret"], info["best_constant_regret"]))
    # ALWAYS_1 은 best_constant_arm(=1) 그 자체를 매번 고르므로 정확히 동률이다(margin=0, 음수 아님).
    check("G3: 최고 상수 정책과 동률이면 observed_margin == 0.0 (엄밀부등식이라 여전히 실패)",
          abs(info["observed_margin"]) < 1e-9, str(info["observed_margin"]))

    ok, info = gate_g3_beats_constant(INSTANCES, ALWAYS_0)
    check("G3: 다른 상수 정책도 실패", not ok)
    check("G3: 최고가 아닌 상수 정책은 observed_margin 이 음수(모델이 최고 상수보다 나쁘다)",
          info["observed_margin"] < 0, str(info["observed_margin"]))

    ok, info = gate_g4_kind_discrimination(INSTANCES, PERFECT)
    check("G4: kind 마다 다른 답이면 통과", ok, str(info["by_kind"]))
    check("G4: pairwise_tv_distance 가 반환된다 (perfect: tv=1.0)",
          info["pairwise_tv_distance"] and info["pairwise_tv_distance"][0]["tv_distance"] == 1.0,
          str(info["pairwise_tv_distance"]))

    ok, info = gate_g4_kind_discrimination(INSTANCES, ALWAYS_1)
    check("G4: 모든 kind 에 같은 답이면 **실패**", not ok,
          str(info["collapsed_kind_pairs"]))
    check("G4: 완전 동률일 때 tv_distance == 0.0",
          info["pairwise_tv_distance"][0]["tv_distance"] == 0.0,
          str(info["pairwise_tv_distance"]))

    ok, info = gate_g4_kind_discrimination(NEAR_CONST_INSTANCES, NEAR_CONST_CHOICES)
    check("G4 knife-edge: 237/238 vs 238/238(거의-상수) 도 tau 임계로 **실패**해야 한다",
          not ok, "tv=%s tau=%s" % (info["pairwise_tv_distance"], info["tau"]))

    # 2026-08-14 회귀: tau=0.0 에서 `tv < tau` 로 잘못 쓰면 tv=0.0(완전 동률)조차 못 잡는다
    # (`0.0 < 0.0` 은 항상 거짓이므로). `<=` 로 고정 -- 이 경계가 다시 깨지면 안 된다.
    ok, info = gate_g4_kind_discrimination(INSTANCES, ALWAYS_1, tau=0.0)
    check("G4 tau=0.0 회귀: 완전 동률(tv=0.0)은 tau=0 에서도 **실패**해야 한다(<=, < 아님)",
          not ok, "tv=%s tau=%s" % (info["pairwise_tv_distance"], info["tau"]))

    ok, info = gate_g4_kind_discrimination(NORM_INSTANCES, NORM_CHOICES)
    check("G4 정규화 커버리지: n=5 vs n=20 이라도 비율이 같으면 **실패**로 잡는다",
          not ok, str(info["by_kind"]))

    ok, info = gate_g4b_menu_invariance(MENU_VARIED, min_group=5)
    check("G4b: 같은 menu 안에서 답이 갈리면(state 사용) 통과", ok, str(info["per_menu"]))

    ok, info = gate_g4b_menu_invariance(MENU_COLLAPSED, min_group=5)
    check("G4b: 같은 menu 안에서 답이 퇴화(menu 의 순수 함수)면 **실패**", not ok,
          str(info["degenerate_menus"]))
    check("G4b: min_group 미만인 소그룹은 건너뛰고 명시적으로 기록한다(침묵 안 함)",
          len(info["skipped_small_menus"]) == 1 and info["skipped_small_menus"][0]["n"] == 2,
          str(info["skipped_small_menus"]))
    check("G4b: max_cost_rule_hit_rate 진단이 1.0 이다(둘 다 menu 최댓값 팔만 골랐다)",
          info["max_cost_rule_hit_rate"] == 1.0, str(info["max_cost_rule_hit_rate"]))

    print("\n%s" % ("전부 통과" if not FAILS else "실패 %d개: %s" % (len(FAILS), FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
