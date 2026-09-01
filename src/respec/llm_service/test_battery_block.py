"""battery 사건의 payload/SoC 사실 블록. (2026-08-31, S1/T2)

왜 이 파일이 필요한가
----------------------
2026-08-30 라이브 판에서 battery_mild 사건이 받은 것은 관찰문 한 줄과 서술자 6개뿐이었고
(harm=0.45 = 1-soc, work_at_risk=0.28 = 쥔 **작업 수**), **payload 질량은 어느 채널에도
없었다.** 모델의 답은 "55% charge, which is sufficient for continued operation" 이고
6/6 행이 expressible=True 였다. 그 입력에서 그것은 반박 불가한 독해다.

규약은 `_zones_block` 과 **정확히 같다**: 값이 하나도 없으면 **빈 문자열**을 낸다.
🔴 그리고 **사실만 적고 "그러니 무엇을 하라"는 절대 안 적는다** — 그것은 판정이고,
적는 순간 재는 것이 추론이 아니라 프롬프트 준수가 된다(spec §6-2 정답 누수).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import dspy_service as svc  # noqa: E402  (numpy/sklearn-before-dspy 계약)

_BASE = dict(kind="battery", severity=0.55, soc=0.55, spare_count=8, agent_pending=1,
             progress=0.80, n_active=17, nl="Robot R1's battery is degraded.")

_LOAD = dict(battery_pending_transports=4, battery_payload_max_kg=12.80,
             battery_payload_total_kg=21.34, battery_fleet_soc_median=0.94,
             battery_higher_soc_robots=7)


def test_the_block_is_empty_when_no_value_is_shipped():
    """규약 ①: 값이 하나도 없으면 빈 문자열 — 기존 호출자의 프롬프트가 바이트 동일."""
    assert svc._battery_block(svc.MacroRequest(**_BASE)) == ""


def test_the_block_renders_every_shipped_value():
    out = svc._battery_block(svc.MacroRequest(**_BASE, **_LOAD))
    assert "pending_transports" in out and "4" in out
    assert "heaviest_payload_kg" in out and "12.8" in out
    assert "fleet_soc_median" in out and "0.94" in out
    assert "robots_with_higher_soc" in out and "7" in out
    assert "this_robot_soc" in out and "0.55" in out


def test_a_partial_payload_renders_only_what_was_measured():
    """규약 ②: 배터리 레이어가 꺼져 있으면 SoC 셋이 안 실린다 — 그 부분만 빠진다."""
    part = dict(battery_pending_transports=4, battery_payload_max_kg=12.80,
                battery_payload_total_kg=21.34)
    out = svc._battery_block(svc.MacroRequest(**_BASE, **part))
    assert "heaviest_payload_kg" in out
    assert "fleet_soc_median" not in out
    assert "robots_with_higher_soc" not in out


def test_the_block_carries_no_verdict():
    """🔴 정답 누수 금지. 매크로 이름도, 지시절도 없다."""
    out = svc._battery_block(svc.MacroRequest(**_BASE, **_LOAD)).lower()
    for banned in ("swapbattery", "replace", "noop", "should", "recommend", "must ",
                   "hand off", "reassign"):
        assert banned not in out, "판정이 프롬프트에 샜다: %r" % banned


def test_the_block_reaches_both_llm_input_paths():
    """🔴 `_llm_input` 의 **두 반환 경로 모두**에 붙어야 한다. 한쪽만 붙이면 nl 없는
    옛 호출자의 프롬프트에서 조용히 사라지고, 그 누락은 문자열 길이 말고 아무 증상도 없다."""
    with_nl = svc._llm_input(svc.MacroRequest(**_BASE, **_LOAD))
    no_nl_base = dict(_BASE); no_nl_base.pop("nl")
    without_nl = svc._llm_input(svc.MacroRequest(**no_nl_base, **_LOAD))
    assert "heaviest_payload_kg" in with_nl
    assert "heaviest_payload_kg" in without_nl
