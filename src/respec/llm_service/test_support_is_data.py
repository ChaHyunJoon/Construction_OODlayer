"""지원집합은 **기계가 읽을 수 있어야** 한다.

🔴 왜: 축 1(어휘 미달)이 라우팅의 주축인데, 그 입력인 지원집합은 `_state` RAM 에만 있고
디스크의 어떤 산출물도 그것을 적지 않는다. `/health` 의 `surrogate` 필드는 산문 문자열이라
기계가 못 읽는다. 조회할 수 없는 손잡이는 감사할 수 없다.

🔴 그리고 `surrogate_rank` 의 폴백이 `set(range(5))` — 구세대 리터럴(매크로 5개)이다.
surrogate 로드가 실패하면 지원집합이 조용히 {0,1,2,3,4} 가 되어 현행 어휘의 모든 팔이
'지원됨' 으로 읽히고, **축 1 이 정확히 그 상황에서 영원히 침묵한다.**
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import dspy_service as svc  # noqa: E402

# 🔴 2026-08-27 controller 정정 1: `import dspy_service` 만으로는 `_state["surrogate"]` 가
# `None` 이고 `_state` 에 `"surro_support"` 키가 아예 없다 — `_load_surrogate()` 는
# `@app.on_event("startup")` 에서만 돈다(FastAPI 를 안 띄우면 안 불린다). 이걸 안 부르면
# `test_no_stale_literal_fallback_when_support_is_missing` 은 `surrogate_rank` 가
# `model is None` 분기("surrogate not loaded")로 먼저 빠져서 이 테스트가 재려는 경로
# (모델은 있는데 지원집합만 None)에 절대 도달하지 못한 채로 "우연히" 통과/실패한다.
# 네트워크를 타지 않고 355행 적합이라 1초 미만이다(dspy_service.py:283 주석 · 실측 확인).
# 지우면 이 테스트가 조용히 무의미해진다 — 지우지 말 것.
svc._load_surrogate()


def test_health_exposes_support_as_a_list_of_ints():
    h = svc.health()
    assert "surro_support" in h
    v = h["surro_support"]
    assert v is None or (isinstance(v, list) and all(isinstance(i, int) for i in v))


def test_health_support_is_none_not_empty_when_the_model_failed_to_load():
    """None('못 쟀다') 과 []('아무 팔도 지원 안 한다') 는 다른 사건이다."""
    saved = svc._state.get("surro_support")
    try:
        svc._state["surro_support"] = None
        assert svc.health()["surro_support"] is None
    finally:
        svc._state["surro_support"] = saved


def test_no_stale_literal_fallback_when_support_is_missing():
    """🔴 지원집합을 못 읽으면 '전부 지원' 으로 넘어가지 않는다 — 축 1 이 침묵하게 된다."""
    saved = svc._state.get("surro_support")
    try:
        svc._state["surro_support"] = None
        scored, err = svc.surrogate_rank(
            svc.MacroRequest(kind="battery", soc=0.1),
            ["NOOP", "Replace", "SwapBattery"])
        assert scored is None
        assert "support" in (err or "").lower()
    finally:
        svc._state["surro_support"] = saved
