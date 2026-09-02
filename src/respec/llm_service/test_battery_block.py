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

_LOAD = dict(battery_pending_transports=4, battery_payload_proxy_max=12.80,
             battery_payload_proxy_total=21.34, battery_fleet_soc_median=0.94,
             battery_higher_soc_robots=7)


def test_every_battery_key_julia_emits_has_a_python_field():
    """🔴 언어를 건너는 이름 계약. 반쪽 rename 은 **초록으로** 실패한다.

    `policy.jl` 이 `d["battery_*"]` 로 내는 키는 그대로 `MacroRequest` 의 필드명이어야
    한다. 한쪽만 바꾸면 pydantic 이 그 키를 조용히 버리고 필드는 `None` 으로 남는다 ->
    적재 절이 프롬프트에서 **통째로 사라지는데**, 이 파일의 다른 시험은 `MacroRequest` 를
    파이썬 이름으로 **직접** 만들기 때문에 전부 초록이다. 증상이 문자열 길이뿐이다.

    🔴 빈-통과 방지: 파일을 못 찾거나 정규식이 아무것도 못 잡으면 **실패한다.** 0 개를
    검사하고 초록을 내는 게이트가 이 레포에서 가장 나쁜 실패다.

    🔴 이 검사의 경계: 방향이 한쪽이다(줄리아 -> 파이썬). 파이썬에만 있고 줄리아가 안 내는
    필드는 잡지 않는다 -- 그건 "아직 안 배선됐다" 는 정당한 상태이기 때문이다
    (예: `s2_after_release_candidates`, 2026-09-01 현재 미배선).
    """
    repo = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
    pol = os.path.join(repo, "tools", "monitor", "policy.jl")
    assert os.path.exists(pol), "policy.jl 을 못 찾았다 -- 검사 대상이 0 개다: %s" % pol
    src = open(pol, encoding="utf-8").read()
    keys = sorted(set(re.findall(r'd\["(battery_[A-Za-z0-9_]+)"\]\s*=', src)))
    assert len(keys) >= 5, "줄리아 키를 %d 개만 찾았다 -- 정규식이 깨졌을 수 있다: %r" % (len(keys), keys)
    fields = set(svc.MacroRequest.model_fields)
    missing = [k for k in keys if k not in fields]
    assert not missing, (
        "줄리아가 내는데 파이썬이 안 받는 키가 있다(반쪽 rename): %r" % missing)


def test_the_block_is_empty_when_no_value_is_shipped():
    """규약 ①: 값이 하나도 없으면 빈 문자열 — 기존 호출자의 프롬프트가 바이트 동일."""
    assert svc._battery_block(svc.MacroRequest(**_BASE)) == ""


def test_the_block_renders_every_shipped_value():
    """Fix round 1, I-5: `"4" in out` 는 `21.34` 의 부분문자열로도 만족돼 `pending_transports`
    를 0 으로 바꿔도 안 빨개졌다(음성 대조로 확인). 값을 그 라벨의 렌더 줄에 못박는다."""
    out = svc._battery_block(svc.MacroRequest(**_BASE, **_LOAD))
    assert re.search(r"pending_transports\s*=\s*4\b", out)
    assert re.search(r"heaviest_payload_proxy\s*=\s*12\.8\b", out)
    assert re.search(r"total_payload_proxy\s*=\s*21\.34\b", out)
    assert re.search(r"fleet_soc_median\s*=\s*0\.94\b", out)
    assert re.search(r"robots_with_higher_soc\s*=\s*7\b", out)
    assert re.search(r"this_robot_soc\s*=\s*0\.55\b", out)


def test_zero_is_a_fact_and_none_is_absence():
    """🔴 삼상 규약이 **렌더 층에서** 지켜지는가. `0` 과 `None` 은 다른 사건이다.

    왜 이 필드인가. `battery_higher_soc_robots` 는 이 블록에서 **0 이 실제로 실리는 유일한
    필드**다 -- `policy.jl:168` 은 `count(>(mine), socs)` 를 조건 없이 넣으므로, 이 로봇이
    함대에서 가장 충전이 높으면 그 값이 0 이다. 그 0 은 "나보다 나은 로봇이 하나도 없다"는
    **강한 사실**이고, `None`("못 쟀다")과 뜻이 정반대다. 나머지 필드는 전부 "값 아니면
    키 없음" 이라 이 함정을 안 밟는다.

    🔴 이 시험이 잡는 변형 (셋 다 실측으로 RED 확인):
      ① `_rows` 의 `is not None` -> `if getattr(r, f)`(진리값). 0 이 조용히 사라진다.
      ② `_battery_block` 의 `if not load and not fleet` -> `if not any(...)` 류의 진리값
         판정. 0 하나뿐인 블록이 통째로 빈 문자열이 된다.
      ③ 렌더 값에 `or "-"` 같은 폴백을 끼우는 것. 0 이 다른 글자로 바뀐다.
    어느 변형도 다른 시험을 빨갛게 만들지 않는다 -- 증상이 **문자열 길이뿐**이기 때문이다.
    """
    # ① 0 은 렌더된다
    zero = dict(_LOAD); zero["battery_higher_soc_robots"] = 0
    out = svc._battery_block(svc.MacroRequest(**_BASE, **zero))
    assert re.search(r"robots_with_higher_soc\s*=\s*0\b", out), \
        "0 이 사라지거나 다른 글자가 됐다 -- 모델이 `아무도 안 낫다` 와 `못 쟀다` 를 못 가른다: %r" % out

    # ② `None`(못 쟀다) 은 **키째로** 빠진다 -- 없는 사실이 프롬프트에 생기면 안 된다
    absent = dict(_LOAD); absent.pop("battery_higher_soc_robots")
    out2 = svc._battery_block(svc.MacroRequest(**_BASE, **absent))
    assert "robots_with_higher_soc" not in out2, \
        "못 잰 값의 라벨이 렌더됐다 -- 프롬프트에 없는 사실이 생긴다"

    # ③ 빈-통과 방지: 0 **하나뿐**인 블록은 빈 문자열이 아니다.
    #    빈 문자열은 "이 사건엔 실을 값이 없다" 는 뜻이라(`_zones_block` 규약), 0 을 그리
    #    접으면 강한 사실이 "측정 자체가 없었다" 로 뒤집힌다.
    only_zero = svc._battery_block(
        svc.MacroRequest(**_BASE, battery_higher_soc_robots=0))
    assert only_zero != "", "0 하나뿐인 블록이 빈 문자열이 됐다 -- `값이 없다` 로 오독된다"
    assert re.search(r"robots_with_higher_soc\s*=\s*0\b", only_zero)


def test_a_partial_payload_renders_only_what_was_measured():
    """규약 ②: 배터리 레이어가 꺼져 있으면 SoC 셋이 안 실린다 — 그 부분만 빠진다."""
    part = dict(battery_pending_transports=4, battery_payload_proxy_max=12.80,
                battery_payload_proxy_total=21.34)
    out = svc._battery_block(svc.MacroRequest(**_BASE, **part))
    assert "heaviest_payload_proxy" in out
    assert "fleet_soc_median" not in out
    assert "robots_with_higher_soc" not in out


def test_no_rendered_label_claims_a_unit_it_does_not_have():
    """🔴 라벨이 `_kg` 로 끝나면 모델은 괄호 안 설명을 읽기 **전에** "12.8 킬로그램" 을 읽는다.

    산출식은 `battery.jl:211` `payload_density * 8.0 * prod(r)` = 밀도 x 경계상자 부피다.
    차원만 보면 kg 이 맞지만, `payload_density = 100.0` 이 `# TUNING KNOB`(`battery.jl:72`)
    이라 그 값을 200 으로 바꾸면 모든 "킬로그램" 이 두 배가 되는데 물리적으로는 아무것도
    안 변한다. ⟹ 절대값에는 뜻이 없고 화물 사이의 **비율에만** 뜻이 있다.

    🔴 이 시험이 잡는 변형: 라벨을 `heaviest_payload_kg` 로 되돌리는 것. 괄호 안 설명은
    그대로 남으므로 다른 어떤 시험도 안 빨개진다 -- 실제로 2026-09-01 에 설명만 고치고
    라벨을 안 고친 반쪽 수정이 전 시험 초록으로 통과했다.

    🔴 와이어 필드명(`battery_payload_proxy_max`)은 이 검사의 대상이 **아니다** -- 렌더된
    블록에 안 나오고 모델도 안 본다. 그 이름은 줄리아(`policy.jl:212`)와 맞물려 있다.
    """
    out = svc._battery_block(svc.MacroRequest(**_BASE, **_LOAD))
    for line in out.split("\n"):
        lbl = line.split("=")[0].strip()
        assert not lbl.endswith("_kg"), \
            "렌더 라벨이 갖지 않은 단위를 주장한다: %r" % lbl
    assert "ratio" in out, \
        "이 값이 비율로만 뜻을 갖는다는 사실이 사라졌다 -- 모델이 절대값을 읽게 된다"


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
    assert "heaviest_payload_proxy" in with_nl
    assert "heaviest_payload_proxy" in without_nl
