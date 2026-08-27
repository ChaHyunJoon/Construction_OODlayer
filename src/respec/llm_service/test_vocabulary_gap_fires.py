"""🔴 축 1(어휘 미달)이 **실제로 발화할 수 있는가** — 양방향 음성 대조.

왜 이 파일이 있나 (2026-08-27 실측): 배포 라벨셋은 33행이고 macro 는 {0:12, 1:12, 2:9} 다.
즉 지원집합 = {0,1,2} = **어휘 전체**이므로 `unsupported` 는 언제나 빈 목록이고, 표현력
격상 코드는 지금까지 **발화 영역이 빈 죽은 코드**였다.

그 상태에서는 축 1 의 모든 테스트가 초록인데, 그 초록이 "옳아서"인지 "발화할 사건이
없어서"인지 구분되지 않는다. 이 저장소에는 stdout 에 절대 안 찍히는 문자열을 grep 하던
게이트가 90/90 으로 영원히 PASS 한 전례가 있다.

그래서 여기서는 지원집합을 **줄여서** 축 1 을 강제로 발화시키고(RED 방향), 되돌려
침묵하는지 본다(GREEN 방향). 둘 다 있어야 측정이다.
"""
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import dspy_service as svc  # noqa: E402

# 🔴 2026-08-27 controller 정정 1: `import dspy_service` 만으로는 `_state` 에
# `"surro_support"` 키가 아예 없다 — `_load_surrogate()` 는 `@app.on_event("startup")` 에서만
# 돈다(FastAPI 를 안 띄우면 안 불린다). 이걸 안 부르면 아래 `support` fixture 의 `saved` 가
# 언제나 없는 키를 읽어 `None` 이 되고, `test_baseline_full_support_is_silent` 같은 GREEN
# 방향 단언이 "지원집합이 실제로 {0,1,2} 라서" 통과하는 게 아니라 "애초에 아무것도 안 재서"
# 우연히 통과하게 된다. `_load_surrogate()` 는 네트워크를 안 타고 로컬 파일 I/O + sklearn fit
# 뿐이라 1초 미만이다(Task 4 의 test_support_is_data.py 가 이미 실측하고 쓰는 관용구).
# 지우면 이 파일 전체가 조용히 무의미해진다 — 지우지 말 것.
svc._load_surrogate()

MENU = ["NOOP", "Replace", "SwapBattery"]


@pytest.fixture
def support():
    """지원집합을 갈아끼우고 반드시 되돌린다."""
    saved = svc._state.get("surro_support")
    yield lambda s: svc._state.__setitem__("surro_support", s)
    svc._state["surro_support"] = saved


def _req():
    return svc.MacroRequest(kind="battery", soc=0.1, valid=MENU,
                            nl="Robot R5 has run its battery down and stopped.")


def test_baseline_full_support_is_silent(support):
    """GREEN 방향: 어휘 전체를 지원하면 축 1 은 아무것도 안 한다."""
    support({0, 1, 2})
    assert svc._unsupported_for(_req(), MENU) == []


def test_removing_one_macro_makes_the_gap_fire(support):
    """🔴 RED 방향: SwapBattery 를 지원집합에서 빼면 그 팔이 미달로 잡힌다.

    이것이 이 계획서 전체의 존재 증명이다 — 이 단언이 통과하지 못하면 축 1 은
    '발화 영역이 빈 죽은 코드' 그대로다."""
    support({0, 1})
    assert svc._unsupported_for(_req(), MENU) == ["SwapBattery"]


def test_the_gap_names_every_missing_arm_not_just_the_first(support):
    support({0})
    assert svc._unsupported_for(_req(), MENU) == ["Replace", "SwapBattery"]


def test_unknown_support_is_none_not_empty(support):
    """'못 쟀다'(None) 와 '재서 미달이 없었다'([]) 를 뭉개지 않는다."""
    support(None)
    assert svc._unsupported_for(_req(), MENU) is None


def test_the_gap_reaches_the_single_source_of_truth_decide_parses(support):
    """축 1 을 실제로 소비하는 것은 Julia 다 — `decide()` 는 이 문자열을 그대로 파싱해
    Julia 로 실어 보낸다(dspy_service.py 의 `decide` 구현이 `surrogate_rank` 의 `err` 를
    그대로 응답의 `surrogate.unsupported` 로 꽂는다).

    🔴 2026-08-27 controller 정정 2: 이 테스트는 **`svc.decide()` 를 부르지 않는다.**
    이 환경에는 `OPENAI_API_KEY` 가 설정돼 있고, `decide()` 가 오늘 유료 호출을 내지 않는
    것은 "아무도 `dspy.configure` 를 안 불렀다"는 **우연**(LM 미설정 시
    `ValueError: No LM is loaded`)일 뿐이다. 누군가 LM 을 설정하는 순간 이 테스트가 매 실행
    gpt-4o 유료 호출을 내게 된다.

    그래서 여기서는 `decide()` 가 파싱하는 **바로 그 단일 진실원**을 직접 단언한다:
    `surrogate_rank` 가 돌려주는 `err` 문자열이 `"UNSUPPORTED:<이름,...>"` 규약을 지키는가.

    **무엇을 재고 무엇은 안 재는가:** 이 테스트는 `surrogate_rank` 까지만 잰다.
    `decide()` 자신의 파싱 단계(`err` 문자열을 받아 응답 JSON 의 `surrogate.unsupported` 로
    바꾸는 부분)는 이 테스트가 **덮지 않는 알려진 공백**이다 — 그걸 재려면 `decide()` 를
    불러야 하고, 그러면 위에서 말한 유료 호출 위험을 그대로 지게 된다."""
    support({0, 1})
    scored, err = svc.surrogate_rank(_req(), MENU)
    assert err == "UNSUPPORTED:SwapBattery"


def test_health_reports_the_reduced_support(support):
    """감사 창구가 산문이 아니라 목록이어야 한다."""
    support({0, 1})
    assert svc.health()["surro_support"] == [0, 1]
