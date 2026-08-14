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

# ---------------------------------------------------------------------------
# G4b 2026-08-14: oracle_choices 를 주면 두 절이 켜진다.
#   (1) 오라클이 스스로 퇴화하는 menu 는 판정에서 뺀다 (거짓 양성 제거)
#   (2) n>=min_group 인 모든 그룹에서 최빈답이 오라클과 달라도 실패 (거짓 음성 제거)
# 실제 Task 6 데이터의 모양을 그대로 축소한 격자를 쓴다.
#   menu {0,1,8}: 정답이 **상수 8** (비정보성)          <- 실측 15/15
#   menu {0,7}:   정답이 7 40 / 0 20 으로 갈린다 (정보성) <- 실측 그대로
# ---------------------------------------------------------------------------
ORACLE_MENUS = (
    [{"instance": "u%d" % i, "menu": [0, 1, 8]} for i in range(10)] +
    [{"instance": "w%d" % i, "menu": [0, 7]} for i in range(10)]
)
# 오라클: {0,1,8} 에서는 항상 8(정답이 상수), {0,7} 에서는 7 이 6개·0 이 4개.
ORACLE_TRUTH = {}
for _i in range(10):
    ORACLE_TRUTH["u%d" % _i] = 8
    ORACLE_TRUTH["w%d" % _i] = 7 if _i < 6 else 0

def _menu_choices(pick):
    """pick(instance_id) -> 팔.  ORACLE_MENUS 에 choice 를 채운 decisions 를 만든다."""
    return [dict(d, choice=pick(d["instance"])) for d in ORACLE_MENUS]

PERFECT_MENU = _menu_choices(lambda i: ORACLE_TRUTH[i])
# 오라클과 같은 상수(8)를 내지만 {0,7} 에서는 갈린다 = 비정보성 menu 의 퇴화만 남은 정책.
RIGHT_CONSTANT = _menu_choices(lambda i: ORACLE_TRUTH[i] if i.startswith("w") else 8)
# Task 6 실측 결함: {0,1,8} 에서 15/15 Replace(1) — 정답 8 을 100% 뒤집는다.
INVERTED_CONSTANT = _menu_choices(lambda i: ORACLE_TRUTH[i] if i.startswith("w") else 1)
# 배포 max-cost 정책: menu 안 MACRO_COST 최댓값. {0,1,8}->1(1.0), {0,7}->7(1.5).
MAXCOST_POLICY = _menu_choices(lambda i: 1 if i.startswith("u") else 7)

# ---------------------------------------------------------------------------
# G4b 2026-08-14 (최종 리뷰 #2): **부분 커버리지 oracle_choices 가 게이트를 무장해제한다.**
#
# 실측한 결함: 지도에 없는 instance 는 oracle_groups 에 아무것도 더하지 않는다. 그래서 오라클
# 항목이 하나도 없는 menu 그룹은 `ocounts = Counter()` -> `len(ocounts) > 1` 이 거짓 ->
# `informative = False` -> 절(1)의 판정에서 **빠지고**, `if ocounts:` 가드가 절(2)의 최빈답
# 비교도 건너뛴다. 두 절이 동시에 사라져, **완전히 퇴화하고 완전히 틀린 정책이 통과**했다.
#
# 아래 격자가 그 시연이다: 20개 결정 전부 menu {0,1,8}, 모델은 언제나 1(Replace), 오라클은
# 8 과 0 으로 10/10 갈린다(= 명백히 정보성 menu). 커버리지 20/20 · 1/20 · 0/20 세 지점에서
# 전부 실패해야 한다 — 지도를 잘라내는 것으로 판정이 약해지면 안 된다.
# ---------------------------------------------------------------------------
COVERAGE_DECISIONS = [{"instance": "p%d" % i, "menu": [0, 1, 8], "choice": 1} for i in range(20)]
COVERAGE_ORACLE_FULL = {"p%d" % i: (8 if i < 10 else 0) for i in range(20)}   # 10/10 로 갈린다
COVERAGE_ORACLE_ONE = {"p0": 8}                                              # 1/20 만 덮는다
COVERAGE_ORACLE_NONE = {"zz": 8}                                             # 0/20 (키가 안 맞는다)


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

    # -- 2026-08-14: oracle_choices 를 안 주면 판정이 **이전과 동일**해야 한다(하위호환) ----
    ok_old, i_old = gate_g4b_menu_invariance(MENU_COLLAPSED, min_group=5)
    ok_none, i_none = gate_g4b_menu_invariance(MENU_COLLAPSED, min_group=5, oracle_choices=None)
    check("G4b 하위호환: oracle_choices=None 은 인자를 안 준 것과 판정·degenerate_menus 가 같다",
          (ok_old == ok_none) and (i_old["degenerate_menus"] == i_none["degenerate_menus"]),
          "ok=%s/%s" % (ok_old, ok_none))
    check("G4b 하위호환: oracle 없이 부르면 oracle_aware=False 로 표시된다",
          i_old["oracle_aware"] is False, str(i_old["oracle_aware"]))

    # -- 절 (1) 정보성 조건: 오라클이 퇴화하는 menu 의 퇴화는 증거가 아니다 ------------------
    ok, info = gate_g4b_menu_invariance(PERFECT_MENU, min_group=5, oracle_choices=ORACLE_TRUTH)
    check("G4b(1): 완벽한 오라클 정책은 **통과**한다 (거짓 양성 제거)", ok,
          "uninformative=%s modal_mismatch=%s"
          % (info["uninformative_menus"], info["modal_mismatch_menus"]))
    check("G4b(1): 정답이 상수인 menu 는 uninformative 로 기록되고 판정에서 빠진다",
          info["uninformative_menus"] == ["{0, 1, 8}"], str(info["uninformative_menus"]))
    check("G4b(1): 그 menu 는 degenerate_menus 에는 여전히 남는다(진단은 잃지 않는다)",
          "{0, 1, 8}" in info["degenerate_menus"], str(info["degenerate_menus"]))

    ok, info = gate_g4b_menu_invariance(RIGHT_CONSTANT, min_group=5, oracle_choices=ORACLE_TRUTH)
    check("G4b(1): 비정보성 menu 에서만 퇴화한(정답과 같은) 정책도 통과한다", ok,
          str(info["degenerate_informative_menus"]))

    # -- 절 (2) 최빈답 일치: 15/15 뒤집기는 (1) 이 안 보는 자리라 (2) 가 잡아야 한다 ---------
    ok, info = gate_g4b_menu_invariance(INVERTED_CONSTANT, min_group=5, oracle_choices=ORACLE_TRUTH)
    check("G4b(2): 비정보성 menu 에서 정답을 100% 뒤집으면 **실패**한다 (거짓 음성 제거)",
          not ok, "modal_mismatch=%s" % info["modal_mismatch_menus"])
    check("G4b(2): 그 실패는 최빈답 불일치로 잡힌 것이지 퇴화로 잡힌 것이 아니다",
          info["modal_mismatch_menus"] == ["{0, 1, 8}"]
          and info["degenerate_informative_menus"] == [],
          "mismatch=%s deg_inf=%s"
          % (info["modal_mismatch_menus"], info["degenerate_informative_menus"]))
    check("G4b(2): 절(1) 단독이면 이 정책을 통과시킨다는 것 자체를 고정한다(회귀 방지)",
          gate_g4b_menu_invariance(INVERTED_CONSTANT, min_group=5)[0] is False
          and not info["degenerate_informative_menus"],
          "구 게이트는 퇴화로 잡지만 정보성 조건만 켜면 못 잡는다")

    # -- 게이트가 약해지지 않았는가: 배포 max-cost 정책은 여전히 실패해야 한다 ---------------
    ok, info = gate_g4b_menu_invariance(MAXCOST_POLICY, min_group=5, oracle_choices=ORACLE_TRUTH)
    check("G4b: 배포 max-cost 정책은 오라클을 줘도 **여전히 실패**한다 (게이트 약화 없음)",
          not ok, "deg_inf=%s mismatch=%s"
          % (info["degenerate_informative_menus"], info["modal_mismatch_menus"]))
    check("G4b: max-cost 는 정보성 menu {0, 7} 에서 퇴화로 잡힌다",
          info["degenerate_informative_menus"] == ["{0, 7}"],
          str(info["degenerate_informative_menus"]))

    # -- 부분 커버리지: 잘린 oracle_choices 가 판정을 **약화시키면 안 된다** (2026-08-14) ------
    ok_full, i_full = gate_g4b_menu_invariance(COVERAGE_DECISIONS, min_group=5,
                                               oracle_choices=COVERAGE_ORACLE_FULL)
    check("G4b 커버리지 20/20: 퇴화 + 최빈답 불일치로 실패한다(기준점)", not ok_full,
          "deg_inf=%s mismatch=%s cov=%s" % (i_full["degenerate_informative_menus"],
                                             i_full["modal_mismatch_menus"],
                                             i_full["oracle_coverage"]))
    check("G4b 커버리지 20/20: oracle_coverage == 1.0 으로 보고된다",
          i_full["oracle_coverage"] == 1.0, str(i_full["oracle_coverage"]))

    ok_one, i_one = gate_g4b_menu_invariance(COVERAGE_DECISIONS, min_group=5,
                                             oracle_choices=COVERAGE_ORACLE_ONE)
    check("G4b 커버리지 1/20: 지도를 잘라도 **여전히 실패**한다", not ok_one,
          "deg_inf=%s mismatch=%s cov=%s" % (i_one["degenerate_informative_menus"],
                                             i_one["modal_mismatch_menus"],
                                             i_one["oracle_coverage"]))
    check("G4b 커버리지 1/20: 없는 데이터로 uninformative 를 선언하지 않는다",
          i_one["uninformative_menus"] == [], str(i_one["uninformative_menus"]))
    check("G4b 커버리지 1/20: 부분 커버리지가 명시적으로 기록된다(침묵 안 함)",
          i_one["partial_coverage_menus"] == [{"menu": "{0, 1, 8}", "covered": 1, "n": 20}],
          str(i_one["partial_coverage_menus"]))

    ok_zero, i_zero = gate_g4b_menu_invariance(COVERAGE_DECISIONS, min_group=5,
                                               oracle_choices=COVERAGE_ORACLE_NONE)
    check("G4b 커버리지 0/20 (**시연된 결함**): 오라클 항목이 0 개여도 실패해야 한다", not ok_zero,
          "deg_inf=%s mismatch=%s cov=%s" % (i_zero["degenerate_informative_menus"],
                                             i_zero["modal_mismatch_menus"],
                                             i_zero["oracle_coverage"]))
    check("G4b 커버리지 0/20: oracle_coverage == 0.0 으로 보고된다",
          i_zero["oracle_coverage"] == 0.0, str(i_zero["oracle_coverage"]))
    # 불변식: 커버리지가 완전하지 않으면 오라클 인지 판정이 오라클 없는 판정보다 **느슨할 수 없다**.
    ok_blind, _ = gate_g4b_menu_invariance(COVERAGE_DECISIONS, min_group=5)
    check("G4b 커버리지 불변식: 불완전한 지도의 판정 <= 오라클 없는 판정",
          (ok_zero <= ok_blind) and (ok_one <= ok_blind),
          "blind=%s one=%s zero=%s" % (ok_blind, ok_one, ok_zero))

    print("\n%s" % ("전부 통과" if not FAILS else "실패 %d개: %s" % (len(FAILS), FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
