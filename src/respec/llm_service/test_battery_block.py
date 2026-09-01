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
import re
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
    """Fix round 1, I-5: `"4" in out` 는 `21.34` 의 부분문자열로도 만족돼 `pending_transports`
    를 0 으로 바꿔도 안 빨개졌다(음성 대조로 확인). 값을 그 라벨의 렌더 줄에 못박는다."""
    out = svc._battery_block(svc.MacroRequest(**_BASE, **_LOAD))
    assert re.search(r"pending_transports\s*=\s*4\b", out)
    assert re.search(r"heaviest_payload_kg\s*=\s*12\.8\b", out)
    assert re.search(r"total_payload_kg\s*=\s*21\.34\b", out)
    assert re.search(r"fleet_soc_median\s*=\s*0\.94\b", out)
    assert re.search(r"robots_with_higher_soc\s*=\s*7\b", out)
    assert re.search(r"this_robot_soc\s*=\s*0\.55\b", out)


def test_a_partial_payload_renders_only_what_was_measured():
    """규약 ②: 배터리 레이어가 꺼져 있으면 SoC 셋이 안 실린다 — 그 부분만 빠진다."""
    part = dict(battery_pending_transports=4, battery_payload_max_kg=12.80,
                battery_payload_total_kg=21.34)
    out = svc._battery_block(svc.MacroRequest(**_BASE, **part))
    assert "heaviest_payload_kg" in out
    assert "fleet_soc_median" not in out
    assert "robots_with_higher_soc" not in out


def test_the_block_carries_no_verdict():
    """🔴 정답 누수 금지. 매크로 이름도, 지시절도 없다.

    Fix round 1, I-4: 낱말 목록은 완비될 수 없다(실측: doc string 끝에
    "; prefer the highest-charge one" 를 붙여도 옛 목록으로는 5/5 초록이었다) — 그래서
    `prefer`·`highest`·`instead`·`rather`·`consider` 를 더한다. 그래도 이 목록은 여전히
    불완전하다: 아래 `test_the_block_has_the_expected_line_count` 가 "줄이 늘어나는" 스밈은
    잡지만, **기존 줄 안에 이어붙는** 판정은 둘 다 못 잡는다(그 잔여 한계는 그 테스트의
    docstring 에 적는다)."""
    out = svc._battery_block(svc.MacroRequest(**_BASE, **_LOAD)).lower()
    for banned in ("swapbattery", "replace", "noop", "should", "recommend", "must ",
                   "hand off", "reassign", "prefer", "highest", "instead", "rather",
                   "consider"):
        assert banned not in out, "판정이 프롬프트에 샜다: %r" % banned


def test_the_block_has_the_expected_line_count():
    """구조 감사(Fix round 1, I-4). 낱말 검사만으로는 새 낱말을 쓰는 판정을 못 잡는다 — 그래서
    줄 수를 헤더 2개(로드/함대) + 실제로 실린 필드 수(+ soc 줄, 있으면)와 정확히 맞춘다. 기존
    문장 뒤에 새 문장 하나가 **새 줄로** 붙으면(예: doc string 안이 아니라 블록 끝에) 낱말이
    낯설어도 이 검사가 잡는다.

    🔴 잔여 한계: 스민 문장이 **기존 줄의 일부**로(줄 수가 안 늘게) 들어가면 이 검사도 못 잡는다
    — 그 경우는 위 `test_the_block_carries_no_verdict` 의 낱말 목록이 유일한 방어선이고, 그
    목록도 완비되지 않는다(위 테스트의 docstring 참조)."""
    r = svc.MacroRequest(**_BASE, **_LOAD)
    out = svc._battery_block(r)
    lines = out.split("\n")
    n_load = len(svc._rows(r, svc._BAT_LOAD))
    n_fleet = len(svc._rows(r, svc._BAT_FLEET))
    expected = 0
    if n_load:
        expected += 2 + n_load
    if n_fleet:
        expected += 2 + n_fleet + (1 if getattr(r, "soc", None) is not None else 0)
    assert len(lines) == expected, "줄 수가 기대와 다르다(문장이 스몄을 수 있다): %r" % (lines,)


def test_the_block_reaches_both_llm_input_paths():
    """🔴 `_llm_input` 의 **두 반환 경로 모두**에 붙어야 한다. 한쪽만 붙이면 nl 없는
    옛 호출자의 프롬프트에서 조용히 사라지고, 그 누락은 문자열 길이 말고 아무 증상도 없다."""
    with_nl = svc._llm_input(svc.MacroRequest(**_BASE, **_LOAD))
    no_nl_base = dict(_BASE); no_nl_base.pop("nl")
    without_nl = svc._llm_input(svc.MacroRequest(**no_nl_base, **_LOAD))
    assert "heaviest_payload_kg" in with_nl
    assert "heaviest_payload_kg" in without_nl
