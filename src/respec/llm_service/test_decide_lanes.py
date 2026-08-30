"""`/decide` 가 **요청된 레인만** 계산하는가 — 🔴 이 파일은 **비용 게이트**다 (2026-08-29, T10).

🔴 왜 이 파일이 존재하나 (§0-C 충돌 ⑦). surrogate 는 DSPy 서비스 **안**에 살고, 유일한 통로가
`/decide` 이며, 그 함수는 맨 앞에서 `d = macro(req)` 로 LLM 을 부른다. 즉 줄리아 쪽
`select_lane` 만 kind 색인으로 바꾸면 **비용이 1원도 안 준다** — surrogate 로 라우팅된 사건도
LLM 을 한 번씩 부른다. "라우터가 비용을 자른다" 는 주장은 이 파일이 초록일 때만 참이다.

🔴 어떻게 유료 호출 없이 비용을 재나. `_state["calls"] += 1` 이 `_ask()` **안**에 있으므로
(`dspy_service.py`, `/health` 로 노출된다) 가짜 LM 으로도 **정확히** 센다. 이 파일은 라이브 LM 을
한 번도 안 부른다.

🔴 안 요청한 레인은 **키 자체를 안 싣는다** — 빈 dict 으로 싣지 않는다. 소비자(줄리아
`policy_entry`)가 *"안 물었다"* 와 *"물었는데 실패했다"* 를 갈라야 하고, 후자만
`policy_entry(nothing, …)` 의 뜻이다.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import dspy_service as svc  # noqa: E402  (numpy/sklearn-before-dspy 계약)
import dspy  # noqa: E402
import pytest  # noqa: E402
from dspy.utils.dummies import DummyLM  # noqa: E402

AGENTS = [{"id": "ConstructionBots.BotID{ConstructionBots.DeliveryBot}(5)", "label": "Robot R5 / robot 5"}]


def _req(**kw):
    base = dict(kind="battery", soc=0.1, agents=AGENTS,
                valid=["NOOP", "Replace", "SwapBattery"],
                nl="Robot R5 has run its battery down and stopped.")
    base.update(kw)
    return svc.MacroRequest(**base)


@pytest.fixture
def fake_lm():
    """LM 을 가짜로 갈아 끼운다. 이 파일은 라이브 호출을 한 건도 내지 않는다."""
    answers = [{"reasoning": "r", "expressible": "True", "action": {"tool_calls": []},
                "macro": "NOOP", "ranking": "NOOP, Replace, SwapBattery",
                "margin": "0.0"}] * 8
    dspy.configure(lm=DummyLM(list(answers)), adapter=svc.build_adapter())
    svc._state["program"] = None
    svc._load_program()
    svc._load_surrogate()
    return None


def test_the_surrogate_lane_costs_zero_lm_calls(fake_lm):
    """🔴 **이 파일 전체의 존재 이유.** surrogate 로 라우팅된 사건에서 LM 호출 델타가 0 이다."""
    before = svc._state["calls"]
    out = svc.decide(_req(lanes=["surrogate"]))
    assert svc._state["calls"] == before, "surrogate 레인이 LLM 을 불렀다 — 비용이 안 준다"
    assert "surrogate" in out
    assert "dspy" not in out, "안 물은 레인은 **키 자체가 없다**(빈 dict 아님)"


def test_the_dspy_lane_alone_does_not_score_the_surrogate(fake_lm):
    """음성 대조의 반대쪽. 비용 축은 아니지만 같은 규약(키 부재)을 반대 방향으로 잰다."""
    out = svc.decide(_req(lanes=["dspy"]))
    assert "dspy" in out
    assert "surrogate" not in out


def test_omitting_lanes_still_calls_both(fake_lm):
    """🔴 음성 대조. 이게 없으면 위 시험은 '서비스가 아무것도 안 한다' 로도 초록이다."""
    before = svc._state["calls"]
    out = svc.decide(_req())                       # lanes 없음 = 하위호환
    assert svc._state["calls"] == before + 1
    assert "dspy" in out and "surrogate" in out


def test_the_request_record_survives_every_lane_choice(fake_lm):
    """🔴 `valid`·`state`·`llm_input`·`surrogate_input` 은 **레인과 무관하게** 나온다 —
    둘 다 요청 자체의 기록이고, 빼면 결정 행의 `valid` 열이 사라진다(채점기가 읽는다)."""
    for lanes in (None, ["surrogate"], ["dspy"], ["dspy", "surrogate"]):
        out = svc.decide(_req(lanes=lanes))
        for k in ("valid", "state", "llm_input", "surrogate_input", "llm_input_mode"):
            assert k in out, "lanes=%r 에서 %s 가 사라졌다" % (lanes, k)


def test_an_unknown_lane_name_dies_loudly():
    """F1 선례와 같은 모양 — 오설정은 조용한 폴백이 아니라 예외다. 오타 하나가 레인을 통째로
    사라지게 하면 줄리아는 그것을 '서비스 장애' 로 읽는다."""
    with pytest.raises(ValueError):
        svc.decide(_req(lanes=["surrogate", "surrogat"]))


def test_an_empty_lane_list_is_not_the_same_as_omitting_it(fake_lm):
    """🔴 삼상 규약. `None` = 둘 다(하위호환) · `[]` = 아무 레인도 안 청구했다.
    `[]` 를 falsy 로 접어 `None` 처럼 다루면 '아무것도 안 물었다' 가 조용히 '둘 다' 가 된다 —
    그것이 이 태스크가 없애려는 바로 그 비용이다."""
    before = svc._state["calls"]
    out = svc.decide(_req(lanes=[]))
    assert svc._state["calls"] == before
    assert "dspy" not in out and "surrogate" not in out
    assert "valid" in out


def test_lanes_survives_the_pydantic_boundary():
    """★ 선언 안 된 키를 pydantic 이 **조용히 버린다**. 이 레포가 `total_nodes`·`zones` 에서
    두 번 밟은 함정 — 그러면 호출자가 실어 보내도 모든 사건이 '둘 다' 로 굳는다."""
    assert svc.MacroRequest(kind="battery", lanes=["surrogate"]).lanes == ["surrogate"]
    assert svc.MacroRequest(kind="battery").lanes is None
