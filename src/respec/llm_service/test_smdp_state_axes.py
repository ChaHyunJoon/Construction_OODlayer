"""SMDP `MEASURED STATE` 블록의 축 집합을 못박는다.

무엇을 재는가
-------------
2026-09-06 (`d7199da3`) 이 LLM 프롬프트의 `MEASURED STATE` 를 6개 kind-agnostic
서술자에서 SMDP `{p,b,v,w,c,k}` 로 교체했다. 2026-09-07 사용자 결정으로 **`k`(event_kind)
를 뺀다** — 논문의 상태 정의도 다섯으로 고친다.

왜 뺐는가 (측정, 2026-09-07)
----------------------------
  ① `k` 가 나른다고 볼 수 있는 두 질문은 **둘 다 이미 다른 데서 답해진다**:
     · "처음 보는 사건인가" → `_unfamiliar_block` 이 별도 문단으로 싣는다.
     · "어떤 종류인가"       → `_geometry_block`/`_zones_block`/`_battery_block` 은
       자기 kind 일 때만 비어 있지 않다. **블록의 존재 자체가 kind 를 말한다.**
  ② LLM 레인은 `routing_kind` 가 `"unknown:"` 일 때만 도달하므로, 모델이 `k` 를 보는
     모든 순간 P(OOD)=1 이다. 유료 원장 497행에서 `k` 는 2값뿐이었다(zone 455/battery 42).
  ③ 🔴 그리고 `k` 가 유일하게 일할 자리 — 어휘 밖의 새 타입 — 에서 정확히 틀린다.
     `policy.jl:ood_features` 의 `else` 분기가 리터럴 `("fault", nothing)` 이라
     `event_kind = fault` 가 찍히고, 바로 아래 `_unfamiliar_block` 이 "어떤 학습된
     범주에도 못 놓았다" 고 말한다. **한 프롬프트 안의 자기모순이다.**
  ④ 같은 레포의 surrogate 22차원은 정확히 이 이유로 kind one-hot 을 거부한다
     (`surrogate_features.py` 헤더: "처음 보는 OOD kind 에서 미지원 영역이 되어 무너진다").

🔴 이 파일은 `_SMDP_AXES` 에서 **유도하지 않는다.** 축 이름을 리터럴로 들고 있어야
   축을 도로 넣었을 때 빨개진다 — 코드에서 유도하면 항진명제가 된다(이 레포가 이미 밟은
   "닻이 어긋난 대조 시험" 실패 모드).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import dspy_service as svc  # noqa: E402

# 다섯 축의 프롬프트 라벨 — 리터럴이다(위 🔴).
EXPECTED_LABELS = ["progress", "broken_robots", "spare_robots",
                   "active_nodes", "min_fleet_soc"]

BASE = dict(
    kind="fault", severity=0.0, progress=0.31, n_active=6,
    spare_count=2, agent_pending=1, closed_at_fire=79, total_nodes=255,
    smdp_n_broken=1, smdp_fleet_soc_min=0.42,
    nl="A structural beam collapsed across the north staging lane.",
    descriptors=[0.41, 0.22, 0.0, 0.5, 0.31, 0.7])


def _req(**kw):
    d = dict(BASE)
    d.update(kw)
    return svc.MacroRequest(**d)


def _state_block(text):
    """`MEASURED STATE` 머리말 아래의 축 행들만. 블록 밖의 산문은 이 시험의 대상이 아니다."""
    if "MEASURED STATE" not in text:
        return ""
    body = text.split("MEASURED STATE", 1)[1]
    out = []
    for line in body.splitlines()[1:]:          # 머리말 둘째 줄부터
        if line.startswith("  ") and "=" in line:
            out.append(line)
        elif out:                                # 축 행이 끝나면 블록도 끝이다
            break
    return "\n".join(out)


# ---------------------------------------------------------------------------------------------
# (1) 축 집합이 정확히 다섯이다
# ---------------------------------------------------------------------------------------------
def test_smdp_axes_are_exactly_the_five():
    syms = [sym for sym, *_ in svc._SMDP_AXES]
    labels = [label for _sym, _field, label, _doc in svc._SMDP_AXES]
    assert syms == ["p", "b", "v", "w", "c"], syms
    assert labels == EXPECTED_LABELS, labels


# ---------------------------------------------------------------------------------------------
# (2) `event_kind` 가 모델이 읽는 바이트에 없다 — 세 kind 전부
# ---------------------------------------------------------------------------------------------
def test_event_kind_is_absent_from_the_prompt_for_every_kind():
    for kw in (dict(kind="fault"),
               dict(kind="battery", soc=0.12, severity=0.12),
               dict(kind="zone", zone_overlap=0.4, severity=0.4)):
        text = svc._llm_input(_req(**kw))
        assert "event_kind" not in text, (kw, text)


def test_the_nl_none_fallback_renders_no_smdp_block_at_all():
    """🔴 폴백 경로에서 `event_kind` 를 재면 **항진명제**다 — 그 경로는 SMDP 블록을 아예 안 만든다.

    그래서 재는 것을 바꾼다: 폴백이 `MEASURED STATE` 를 안 낸다는 **사실** 자체를 못박는다.
    누가 나중에 폴백에도 SMDP 블록을 붙이면 이 시험이 빨개지고, 그때 `k` 를 같이 붙였는지
    다시 판정해야 한다.

    ⚠️ 그리고 남은 구멍을 여기에 기록한다: 폴백의 `_state_line` 은 여전히
    `"OOD kind=fault"` 를 찍는다 — 어휘 밖 타입에서 `_unfamiliar_block` 과 모순되는,
    `k` 와 **같은 자기모순**이다. 이 삭제의 범위 밖(별도 결정)이라 고치지 않았고,
    아래 단언이 그 사실을 현재 동작으로 못박는다.
    """
    text = svc._llm_input(_req(nl=None, routing_kind="unknown:MeteorTruth"))
    assert "MEASURED STATE" not in text, text
    assert "event_kind" not in text, text
    # 남은 구멍의 특성화 — 고쳐지면 여기가 빨개지고, 그때 이 문단을 지우면 된다.
    assert "OOD kind=fault" in text, text


# ---------------------------------------------------------------------------------------------
# (3) 🔴 자기모순 회귀: 어휘 밖 타입에서 상태가 `fault` 라고 주장하지 않는다
# ---------------------------------------------------------------------------------------------
def test_unknown_type_state_block_does_not_claim_a_trained_category():
    """`ood_features` 의 `else` 분기가 내는 페이로드 그대로: kind="fault" + unknown routing.

    이 판에서 옛 코드는 `event_kind = fault` 를 찍었고, 바로 아래 `_unfamiliar_block` 은
    "어떤 학습된 범주에도 못 놓았다" 고 말했다. 두 문장이 같은 프롬프트에 있었다.
    """
    text = svc._llm_input(_req(kind="fault", routing_kind="unknown:MeteorTruth"))
    block = _state_block(text)
    assert block, text                      # 블록이 사라진 것이 아니라 축 하나만 빠졌다
    assert "fault" not in block, block
    # 낯섦 판정은 그대로 실린다 — 이 삭제가 그 채널을 건드리지 않았다는 음성 대조.
    assert "MeteorTruth" in text, text


# ---------------------------------------------------------------------------------------------
# (4) 음성 대조: 나머지 다섯 축은 여전히 렌더된다
# ---------------------------------------------------------------------------------------------
def test_the_other_five_axes_still_render():
    block = _state_block(svc._llm_input(_req()))
    for label in EXPECTED_LABELS:
        assert label in block, (label, block)
