"""SoC 임계값은 한 곳에서만 정의된다 -- 두 채점기가 같은 severity class 를 내야 한다."""
import os
import re
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import action_registry  # noqa: E402
import reference_policy  # noqa: E402

# 🔴 2026-08-25 (최종 브랜치 리뷰 C3): 여기 있던 `JULIA_REPLACE_SOC_THRESHOLD = 0.2` 는
# **Julia 를 한 줄도 읽지 않는 파이썬 리터럴**이었다. 그래서 `test_threshold_matches_julia`
# 는 파이썬 상수를 파이썬 상수와 비교했고, `src/navigator/ood_truth.jl` 의 값을 0.2 -> 0.35
# 로 바꿔도 **2 passed** 였다(실측). 이름이 주장하는 것을 재지 못하는, 실패할 수 없는 게이트다.
# 이제 Julia 파일을 실제로 읽는다. 못 읽으면(파일 이동·심볼 개명·형태 변경) 그 **이유로 실패**한다
# -- 조용히 건너뛰면 게이트가 다시 없어진다.
JULIA_OOD_TRUTH = os.path.join(HERE, "..", "..", "src", "navigator", "ood_truth.jl")

# `const REPLACE_SOC_THRESHOLD = Ref(0.2)` — 줄번호가 아니라 **심볼**로 찾는다(이 레포에서
# 줄번호는 상시로 밀린다). `Ref(...)` 안이 리터럴 수가 아니면(계산식으로 바뀌면) 매치되지
# 않고 아래에서 실패한다 -- 그때는 파싱이 아니라 Julia 를 띄워 평가해야 한다는 신호다.
_THRESHOLD_RE = re.compile(
    r"^\s*const\s+REPLACE_SOC_THRESHOLD\s*=\s*Ref\(\s*([0-9]*\.?[0-9]+)\s*\)\s*$", re.M)


def julia_replace_soc_threshold():
    """`src/navigator/ood_truth.jl` 에서 REPLACE_SOC_THRESHOLD 의 기본값을 읽는다."""
    path = os.path.normpath(JULIA_OOD_TRUTH)
    if not os.path.exists(path):
        pytest.fail("Julia 쪽 임계값 정의 파일이 없다: %s -- 파일이 옮겨졌으면 이 경로를 "
                    "같이 옮길 것. 못 읽는 것을 통과로 삼지 않는다." % path)
    src = open(path, encoding="utf-8").read()
    hits = _THRESHOLD_RE.findall(src)
    if len(hits) != 1:
        pytest.fail("%s 에서 `const REPLACE_SOC_THRESHOLD = Ref(<수>)` 를 정확히 하나 찾지 "
                    "못했다(찾은 것: %r). 정의 형태가 바뀌었으면 이 파서를 같이 고칠 것 -- "
                    "못 읽는 것을 통과로 삼지 않는다." % (path, hits))
    return float(hits[0])


def test_threshold_matches_julia():
    assert reference_policy.BATTERY_DEEP_SOC == julia_replace_soc_threshold()


def test_reference_policy_arms_are_in_the_vocabulary():
    """채점기가 이름으로 부르는 팔이 실제로 어휘 안에 있는가.

    `reference_action` 은 `"SwapBattery" if "SwapBattery" in valid else "Replace"` 로 답한다.
    레지스트리가 그 이름을 바꾸면 그 분기는 **에러 없이** 언제나 Replace 로 무너지고, 깊은
    방전의 기준 행동이 조용히 갈린다. 이름 리터럴 자체는 policy.jl 의 oracle 레인과 짝을
    맞추려고 일부러 두는 것이므로(policy.jl `oracle_macro` 위 주석), 지우는 대신 어휘에
    실제로 있는지를 여기서 대조한다.
    """
    names = set(action_registry.MACRO_NAME[i] for i in action_registry.ACTIVE_MACROS)
    for arm in ("NOOP", "Replace", "SwapBattery"):
        assert arm in names, (
            "reference_policy 가 이름으로 부르는 팔 %r 가 action_registry.json 의 활성 어휘 "
            "%r 에 없다 -- 채점기가 존재하지 않는 팔을 정답으로 낸다." % (arm, sorted(names)))


def test_scoring_grid():
    """SoC 격자에서 정답/채점제외가 임계값과 정확히 일치하는지."""
    valid = ["NOOP", "Replace", "SwapBattery"]
    for soc, expected in ((0.02, "SwapBattery"), (0.15, "SwapBattery"),
                          (0.20, "SwapBattery"), (0.25, None), (0.45, None), (0.60, None)):
        ev = {"truth": "BatteryTruth", "soc": soc, "valid": valid}
        a_star, basis, _ = reference_policy.reference_action(ev)
        assert basis == "battery"
        assert a_star == expected, "SoC %.2f -> %r (기대 %r)" % (soc, a_star, expected)
