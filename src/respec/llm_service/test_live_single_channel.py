"""유료 게이트 — 기본 skip. `LIVE_LLM=1 .venv/bin/python -m pytest ... -q` 로 돈다.

🔴 왜 별도 파일인가. 이 레포의 다른 시험은 **라이브 LM 을 한 번도 안 부른다**(가짜 LM 으로
kwargs 를 단언한다). 그 규약을 깨지 않으려고 유료 시험을 격리한다. CI 에서 자동으로 돌면 안 된다.

🔴 **이 파일이 재는 것과 안 재는 것** (§0-B ④⑤⑦, 계획서 T7 머리말의 집계 규칙 넷).
  · 재는 것: **프로바이더의 행동**. `required` 하에서 호출이 실제로 오는가(F3),
    호출이 하나인가(F11), `tool_args` 가 접지 알파벳 안인가(F9), 인자가 접지되는가(F10/F12),
    그리고 어휘 밖 사건에서 `expressible` 이 실제로 `false` 로 오는가(F6).
  · **안 재는 것**: 우리 디코딩. native FC 의 `arguments` 는 JSON **문자열**로 오는데
    `_provider_tool_call_to_tool_call_dict`(`dspy/adapters/base.py:734-753`)가 `json_repair`
    로 먼저 푼다 — 같은 페이로드를 텍스트 파싱 경로와 native 경로로 태우면 `_first_tool_call`
    출력이 **동일**하다(§0-B ⑱ 에서 오프라인으로 이미 닫았다).

🔴 **초록을 이렇게 인용하지 말 것.**
  ① `tool_arg_error` 문자열로 실패 **종류**를 세지 말 것. `check_tool_args` 는 처음 걸린 사유
     하나만 내고 `agent_outside_enum`(F10)이 순서상 마지막이라, 두 축이 동시에 틀리면 F10 은
     보고되지 않는다 ⟹ **F10 은 항상 과소집계다.** 축마다 따로 셀 것.
  ② `tool_arg_error is None` 을 "접지 성공" 으로 세지 말 것. 규약대로 만들어진
     `no_intervention` 호출도 `None` 이다(접지할 것이 없다) — 줄리아는 같은 호출에
     `deferred:no_groundable_param` 을 낸다. NOOP 을 분자에 넣으면 두 레인이 같은 이름의
     비율을 **다른 분모**로 계산한다.
  ③ 소스를 읽는 게이트 셋(`test_the_new_keys_stay_above_the_tool_lane_marker` ·
     `test_synthesis_keys_sit_above_…` · `test/tool_lane_keys_survive.jl`)의 초록을 레인
     건강의 증거로 쓰지 말 것 — 그 셋은 `macro()` 가 매 호출 `NameError` 로 죽는 동안에도
     초록이었다(§0-B ⑦). 레인이 실제로 도는지를 재는 것은 **이 파일뿐이다.**
  ④ F6 확인을 `expressible == False` **비율만으로** 하지 말 것. 그 비율은 부분적으로 프롬프트
     준수를 재고, 메뉴가 하나뿐인 사건은 어휘 공백과 무관한 이유로 `False` 를 낸다.
     `tools_offered` 로 층화할 것 — 아래 두 시험이 그것을 단언으로 박아 둔다.
  ⑤ **`_IN_VOCAB` 의 초록을 "LLM 레인이 건강하다" 의 증거로 인용하지 말 것.** 이 파일은
     **서비스 함수의 계약**을 잰다 — `svc.macro()` 를 직접 부르므로, `decide_all` 이 그
     사건을 실제로 이 함수까지 보내는지는 이 파일이 재지 않는다. `_IN_VOCAB`(`fault`·
     `battery`)는 kind 색인 라우터(2026-08-29, T11 — `tools/monitor/lane_select.jl` 의
     `select_lane`, `tools/monitor/policy.jl` 의 `decide_all` 이 `routing_kind(...)` 로 부른다)에서
     **전부 surrogate 로 간다** — 그래서 이 초록은 **프로덕션 LLM 레인이 돈다는 증거가
     아니다.** 프로덕션 LLM 레인의 모양을 재려면 `_OUT_OF_VOCAB`(= zone / 새 `OODTruth`
     타입, 라우터가 아는 kind 를 벗어나는 쪽)로 재야 한다. §0-B ⑦ 과 같은 종류의 오독이다:
     함수가 도는 것을 함수가 **불리는** 것으로 읽는 것.
"""
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import dspy_service as svc  # noqa: E402  (numpy/sklearn-before-dspy 계약)

pytestmark = pytest.mark.skipif(os.environ.get("LIVE_LLM") != "1",
                                reason="유료 호출 — LIVE_LLM=1 일 때만 돈다")

_AGENTS = [{"id": "RobotID(DeliveryBot)(1)", "label": "DeliveryBot 1"}]
_MENU = ["Replace", "SwapBattery", "NOOP"]

_IN_VOCAB = {
    "fault": dict(kind="fault", severity=0.8, spare_count=2, progress=0.35, n_active=6,
                  nl="A transport robot suffered a hardware fault mid-delivery and stopped; "
                     "its payload is still attached and two spare bodies are staged.",
                  descriptors=[0.62, 0.41, 0.30, 0.55, 0.35, 0.22]),
    "battery": dict(kind="battery", severity=0.5, soc=0.12, spare_count=1, progress=0.55,
                    n_active=5,
                    nl="A delivery robot's battery fell to 12% while carrying a payload.",
                    descriptors=[0.30, 0.52, 0.18, 0.44, 0.55, 0.15]),
}
# zone 메뉴 — 레지스트리 실측: `svc._REG_KIND_VALID` 에 `"zone"` 키가 **없다**(3팔 축소가 zone 을
# 결정 레인에서 뺐다). 그래서 이 유도는 `KIND_VALID.get("zone", [])` = `[]` 로 접혀 `{0}`(NOOP)
# 하나만 남는다 — `ood_mdp_shim._zone_arms()` 의 `[0]` · 보고서 §A-2 의 `["NOOP"]` 과 같은 규약.
# 리터럴 `["NOOP"]` 을 안 쓰고 레지스트리에서 유도한다 — 나중에 zone 팔이 생기면 이 시험이
# 따라온다(Global Constraint 4).
_ZONE_MENU = [svc._REG_NAME[i]
              for i in sorted(set([0] + list(svc._REG_KIND_VALID.get("zone", []))))]

# zone 사건 하나 — `policy.jl:344-356` 이 오늘 실제로 내는 메뉴 모양(`_ZONE_MENU`)을 태운다.
_ZONE_EVENT = dict(
    kind="zone", severity=0.4, progress=0.44, n_active=8,
    nl="A restricted region was declared over the staging area; no known repair macro "
       "applies to a zone event.",
    descriptors=[0.02, 0.31, 0.0, 0.5, 0.44, 0.6])

_OUT_OF_VOCAB = {
    "beam-collapse": dict(kind="fault", severity=0.9, spare_count=2, progress=0.4, n_active=6,
        nl="A structural support beam collapsed across the staging area. No robot is damaged "
           "and no battery is low, but the build geometry underneath is now invalid and the "
           "affected assemblies must be re-specified before any transport can resume.",
        descriptors=[0.90, 0.75, 0.55, 0.20, 0.40, 0.05]),
    "comms-loss": dict(kind="fault", severity=0.85, spare_count=3, progress=0.3, n_active=7,
        nl="The fleet lost the shared localization signal. Every robot is healthy and charged, "
           "but none can determine its own pose, so no transport or assembly can proceed.",
        descriptors=[0.82, 0.80, 0.10, 0.15, 0.30, 0.08]),
}


def _decide(ev, menu=_MENU):
    svc._configure_dspy()
    svc._load_program()
    return svc.macro(svc.MacroRequest(valid=menu, agents=_AGENTS, **ev))


@pytest.mark.parametrize("name", sorted(_IN_VOCAB))
def test_a_tool_is_called_and_the_channels_cannot_diverge(name):
    """🔴 F3 · F5. 강제 하에서 호출이 오고, 집행과 채점이 같은 값에서 나온다."""
    out = _decide(_IN_VOCAB[name])
    assert out["decision_source"] == "tool"
    assert out["tool_called"] in svc.TOOL_TO_MACRO
    assert out["chosen"] == svc.TOOL_TO_MACRO[out["tool_called"]]
    assert out["tool_calls_n"] == 1, "F11 — parallel_tool_calls=False"
    assert set(out["tool_args"]) <= {"agent", "reason"}, "F9"
    assert out["tool_arg_error"] is None, "F10/F12"
    assert out["expressible"] is True
    assert out["reasoning"], "margin 을 대신하는 산문이 비면 안 된다"
    # ④ 층화. 메뉴가 하나뿐이면 `expressible` 이 어휘 공백과 무관한 이유로 갈릴 수 있다 —
    #    그 사건이 아니라는 것을 대조군 쪽에서도 못박는다(아래 시험의 같은 단언과 짝이다).
    assert out["tools_offered"] > 1, "메뉴가 하나뿐이면 이 시험은 F6 을 안 잰다"


@pytest.mark.parametrize("name", sorted(_OUT_OF_VOCAB))
def test_out_of_vocabulary_events_report_expressible_false(name):
    """🔴 F6. 옛 문구로는 이 사건들이 `True` 를 냈다(1/3). 개정 문구가 3/3 을 만들었다 —
    T2 합성의 유일한 방아쇠이므로 여기가 조용히 퇴화하면 합성 레인이 영원히 안 돈다."""
    out = _decide(_OUT_OF_VOCAB[name])
    # ④ 층화 먼저. 메뉴가 좁아서 `False` 가 나온 것이면 F6 을 잰 것이 아니다.
    assert out["tools_offered"] > 1, "메뉴가 하나뿐이면 이 시험은 F6 을 안 잰다"
    assert out["expressible"] is False
    assert out["tool_called"] is None, "R26 — 강제된 호출은 집행의 근거가 아니다"
    assert out["tool_called_forced"] is not None, "기록은 남는다"
    assert out["tool_calls_n"] > 0, "F8 — 메뉴 거절과 가르는 판별키"
    assert out["chosen"], "F7 — 결정은 살아 있다"


def test_zone_menu_events_report_expressible_false_under_the_production_menu():
    """🔴 F6, 그러나 위 두 시험과는 다른 메뉴 모양. 위 `_OUT_OF_VOCAB` 은 `_MENU`(3팔 전체)를
    태우고 `tools_offered > 1` 로 걸러 좁은 메뉴 혼입을 막는다 — 그런데 오늘 프로덕션이 zone
    사건에 **실제로** 주는 메뉴는 정확히 그 좁은 모양(`["NOOP"]` 하나)이고, 그 모양은 이
    파일이 지금까지 한 번도 안 쟀다. `_ZONE_MENU` 가 그 값을 레지스트리에서 유도한다.

    재는 것: `required` 강제 하에서도 호출은 오고(`decision_source == "tool"`),
    `tools_offered` 가 이 좁은 메뉴 크기와 같으며, `expressible is False` 다 — "내 어휘에 이
    사건의 수복이 없다" 를 신고하는가. 머리말 ④ 의 층화 규약은 여기서도 지켜진다: `> 1`
    대신 **정확히 이 메뉴 크기**를 단언해서, 메뉴가 좁아진 것이 우연이 아니라 이 시험의
    전제임을 못박는다.

    ⚠️ **이 시험은 `LIVE_LLM=1` 없이 skip 된 채로 짜였다** — 이 태스크는 이 케이스가
    **라이브에서** 실제로 초록일지 재지 않았다. `--collect-only` 초록은 파싱·파라미터화가
    성립한다(= 이 시험이 존재하고 수집된다)는 증거일 뿐, 라이브 호출이 아래 단언을 통과한다는
    증거가 **아니다**. 다음에 `LIVE_LLM=1` 로 이 파일을 돌리는 사람이 이 시험의 첫 실제
    성패를 잰다.
    """
    out = _decide(_ZONE_EVENT, menu=_ZONE_MENU)
    assert out["decision_source"] == "tool"
    assert out["tools_offered"] == len(_ZONE_MENU), "프로덕션 zone 메뉴 크기와 달라졌다"
    assert out["expressible"] is False
