# -*- coding: utf-8 -*-
"""종단성 줄은 **삼상**이고, 안 쟀으면 아무 말도 안 한다. (2026-09-05, task B2)

왜 이 파일이 필요한가 (실측). 2026-09-05 의 두 라이브 zone 판에서 모델은 NOOP 을 고르며
*"the exclusion zone minimally impacts the build"* 라 적었다. 그 판의 정답은 완주 실패다
(tool-off 대조: PROJECT INCOMPLETE, 270/305, t=5776). 프롬프트가 준 가장 강한 막힘 신호는
`work frozen by those = 32` / `unfinished total = 251` — 비율로 13% 이고, **비율로서는 그
독해가 틀리지 않았다**. 빠져 있던 것은 비율이 아니라 술어였다: `project_complete(env)` 가
요구하는 ProjectComplete 정점이 막힌 노드의 후방 폐포 안에 있는가.

재는 명제 셋
  (1) `zone_project_blocked=True` 면 `build_can_still_finish = NO` 한 줄이 막힘 블록 끝에 붙고,
      그 문장은 **동사도 어휘도 개입 여부도 언급하지 않는다**(정답 누수 금지 규약).
  (2) `False` 면 같은 자리에 `yes` 가 붙는다 — 즉 이 줄은 "재 봤다" 의 보고다.
  (3) 🔴 삼상. 필드가 `None`(= 호출자가 못 재서 키를 안 실음)이면 **줄이 아예 없다.**
      0/no 로 접으면 "재 봤더니 완주는 안 막혔다"는, 재지도 않은 주장이 된다.

실행: .venv/bin/python -m pytest src/respec/llm_service/test_zone_terminality_line.py -q
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import dspy_service as svc  # noqa: E402

# 2026-09-05 라이브 판(results/2026-09-05-zone-oracle/zone_mild_control.jsonl)의 막힘 원시값.
_BASE = dict(
    kind="zone", routing_kind="unknown:zone",
    nl="A no-go exclusion zone has appeared at (1.09, 0.42) with radius 0.07. "
       "Robots that enter the disc are pushed back out of it.",
    severity=0.0023568436709734304, zone_overlap=0.0,
    spare_count=8, agent_pending=-1, progress=0.177, n_active=18,
    closed_at_fire=54, total_nodes=305,
    zone_nav_goals=131, zone_nav_blocked=3, zone_nav_engulfed=3,
    zone_nav_disconnected=0, zone_agent_trapped=0, zone_nav_downstream=32,
    zone_unfinished_total=251,
)

# 정답 누수 금지: 이 줄에 나타나면 안 되는 토큰(동사 이름 · 개입 지시 · 어휘 힌트).
_FORBIDDEN = ("restage", "translate", "relocate", "ForbidZone", "RelocateBuild",
              "NOOP", "should", "must", "recommend", "move the build")


def _render(**kw):
    req = svc.MacroRequest(**dict(_BASE, **kw))
    return svc._llm_input(req)


def test_blocked_renders_the_predicate_and_names_no_verb():
    out = _render(zone_project_blocked=True, zone_project_nodes_blocked=1,
                  zone_project_nodes_open=1)
    line = [l for l in out.split("\n") if "build_can_still_finish" in l]
    assert len(line) == 1, out
    assert "= NO (1 of 1)" in line[0]
    assert "ProjectComplete" in line[0]
    low = line[0].lower()
    for tok in _FORBIDDEN:
        assert tok.lower() not in low, "정답 누수: %r" % tok
    # 막힘 블록의 **끝**에 붙는다 = 카운트 목록에 섞여 또 하나의 숫자로 읽히지 않는다.
    assert out.index("the build has 251 unfinished nodes") < out.index("build_can_still_finish")


def test_not_blocked_renders_yes():
    out = _render(zone_project_blocked=False, zone_project_nodes_blocked=0,
                  zone_project_nodes_open=1)
    line = [l for l in out.split("\n") if "build_can_still_finish" in l]
    assert len(line) == 1
    assert "= yes (0 of 1)" in line[0]


def test_absent_never_becomes_measured_no():
    """🔴 삼상. 못 쟀으면 줄 자체가 없다 — 0/no 로 접지 않는다."""
    out = _render()                      # 세 필드 모두 기본값 None
    assert "build_can_still_finish" not in out
    # 나머지 프롬프트는 한 글자도 안 변한다(이 필드를 안 싣는 옛 호출자의 하위호환).
    assert "WHAT THIS ZONE CAN ACTUALLY BLOCK:" in out
