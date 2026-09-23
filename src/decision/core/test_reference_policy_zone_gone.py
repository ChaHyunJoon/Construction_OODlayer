"""zone 은 LLM 결정 레인에서 빠졌다 -- 채점기가 zone 에 정답을 주면 안 된다."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import reference_policy  # noqa: E402


def test_zone_is_unscored():
    ev = {"truth": "ZoneTruth", "valid": ["NOOP"],
          "zone_primitives": {"n_nav_blocked": 3, "root_covered": 0}}
    a_star, basis, note = reference_policy.reference_action(ev)
    assert a_star is None, "zone 은 채점 대상이 아니어야 한다"
    assert basis == "zone"
    assert "결정 레인" in note or "removed" in note.lower()


def test_zone_is_unscored_even_when_relocate_is_offered():
    """🔴 이 케이스가 이 파일의 **유일한 진짜 RED** 다(컨트롤러 C1).

    계획서가 쓴 `valid=["NOOP"]` 입력은 변경 **전에도** 이미 `(None, "zone", ...)` 이었다
    (2026-08-19 태스크 5 F3 이 ForbidZone 폴백을 unscored 로 바꿨기 때문). 그래서 위 테스트의
    빨강은 산문 부분문자열 하나뿐이고, 문장 한 줄만 고쳐도 초록이 된다 = 행동 변화를 증명하지
    못하는 게이트다. 아래 입력은 변경 전 측정에서 실제로 `'RelocateBuild'` 를 냈다:

        zone(valid=["NOOP","RelocateBuild"]) -> ('RelocateBuild', 'zone',
            'zone blocks 3 navigable goal(s) and no root delivery goal')
    """
    ev = {"truth": "ZoneTruth", "valid": ["NOOP", "RelocateBuild"],
          "zone_primitives": {"n_nav_blocked": 3, "root_covered": 0}}
    a_star, basis, note = reference_policy.reference_action(ev)
    assert a_star is None, "RelocateBuild 가 메뉴에 있어도 zone 은 채점 대상이 아니다"
    assert basis == "zone"


def test_zone_does_not_fall_through_to_the_reform_default():
    """분기를 **지우면** zone 이 함수 끝의 `return None, "reform", ...` 으로 떨어진다.
    a_star 는 그대로 None 이라 위 두 테스트는 그때도 통과한다 -- basis 가 그 차이를 잡는다."""
    for valid in (["NOOP"], ["NOOP", "RelocateBuild"], []):
        for zp in ({"n_nav_blocked": 3, "root_covered": 0},
                   {"n_nav_blocked": 0, "root_covered": 2},
                   {}):
            _, basis, _ = reference_policy.reference_action(
                {"truth": "ZoneTruth", "valid": valid, "zone_primitives": zp})
            assert basis == "zone", "zone 사건이 reform 폴백으로 샜다 (valid=%s zp=%s)" % (valid, zp)


def test_fault_and_battery_still_scored():
    fault = {"truth": "FaultTruth", "agent_pending": 2, "valid": ["NOOP", "Replace"]}
    assert reference_policy.reference_action(fault)[0] == "Replace"

    batt = {"truth": "BatteryTruth", "soc": 0.05,
            "valid": ["NOOP", "Replace", "SwapBattery"]}
    assert reference_policy.reference_action(batt)[0] == "SwapBattery"
