"""zone 사건의 **프롬프트 채널** 두 가지를 못박는다 (spec §1-4 · §9-1, Task T4a).

(A) **오라클의 답은 프롬프트에 없다.** `min_shift_to_clear_m`(= `MacroRequest.zone_relocate_norm`)
    은 `_find_min_translation`(`src/respec/restage_zone.jl`)이 **푼 답**이다. 그것을 렌더하면
    측정되는 것이 추론이 아니라 **프롬프트 준수**가 된다 — 이 레포에 실측 선례가 있다(서술자가
    `harm=0.02` 인데도 "restage 하라"는 문장을 따라간 결정, `dspy_service.py` 의 `_IMPERATIVE`
    주석). 🔴 **필드는 지우지 않는다**: `features_agnostic.py:595` 와
    `gen_oracle_dataset.jl:893` 이 대리모델 피처로 읽는다. 그래서 아래 두 단언은 **서로 다른
    것**을 잰다 — "행이 없다"와 "필드는 있다".

(B) **`zones` 는 선언돼야 존재한다.** pydantic 은 선언 안 된 키를 **조용히 버리므로**, 선언이
    없으면 Julia 가 실어 보내도 서비스는 못 보고 증상은 호출자 결함처럼 보인다. 그래서 이
    파일은 "렌더된다"가 아니라 **"경계를 넘어 값이 살아남는다"** 부터 잰다.
    그리고 구역이 없으면 렌더는 **빈 문자열**이어야 한다(비공간 사건 입력이 예전과 바이트 단위로
    같아야 한다). 마지막으로 그 렌더에 **판정(verdict) 어법이 새지 않는가**를 잰다 — (A)에서
    지운 누수를 `covers_root` 를 "그러니 빌드 전체를 옮겨라"로 번역해 다시 들이면 아무것도
    고친 것이 없다.

변이(mutation) 기록은 태스크 보고서
`.superpowers/sdd/2026-08-29-tool-enactment-lane-plan-b/task-T4a-report.md` 에 있다.
"""
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import dspy_service as svc  # noqa: E402

# `open_zone_descriptors(env)`(`src/respec/llm_bridge.jl:420`)가 실제로 내는 모양 그대로.
ZONES = [{"key": "block", "center": [12.5, 3.0], "radius": 2.5,
          "covers": ["AssemblyComplete7", "AssemblyComplete12"], "covers_root": True,
          "build_center": [0.0, 0.0], "build_radius": 6.4, "max_shift": 3.1,
          "work_reach": 4.2}]

# zone 사건 하나 — `policy.jl:230-240` 이 싣는 기하 술어를 전부 채운 최악의 경우.
ZONE_REQ = dict(
    kind="zone", severity=0.4, progress=0.44, n_active=8,
    nl="A restricted region was declared over the staging area.",
    descriptors=[0.02, 0.31, 0.0, 0.5, 0.44, 0.6],
    zone_blocked=2, zone_restage_feasible=1, zone_root_covered=8, zone_root_total=8,
    zone_work_overlap=3, zone_teams_forming=1, zone_teams_covered=1,
    zone_relocatable=True, zone_relocate_norm=2.38,
    zone_nav_goals=41, zone_nav_blocked=6, zone_nav_downstream=88,
    zone_agent_trapped=2, zone_unfinished_total=255)


def _req(**kw):
    d = dict(ZONE_REQ)
    d.update(kw)
    return svc.MacroRequest(**d)


# ---------------------------------------------------------------------------------------------
# (A) 답 누수 제거
# ---------------------------------------------------------------------------------------------
def test_the_rendered_prompt_does_not_carry_the_oracle_answer():
    """변이: `_GEOM_COVERAGE` 에 `min_shift_to_clear_m` 행을 되돌리면 빨개진다."""
    r = _req()
    for text in (svc._llm_input(r),                 # nl 있는 경로(라이브)
                 svc._llm_input(_req(nl=None)),     # nl 없는 폴백 경로(옛 호출자)
                 svc._geometry_block(r)):
        assert "min_shift_to_clear_m" not in text
        # 이름만 바꿔 같은 값을 싣는 우회도 막는다: 그 행의 설명 문구 자체를 금지한다.
        assert "smallest rigid translation" not in text
        assert "2.38" not in text                   # 값 자체가 어떤 이름으로도 안 나온다


def test_no_render_spec_row_reads_the_answer_field():
    """구조적 단언 — 값이 우연히 None 이라 안 보인 것이 아니라 **행이 없다**."""
    fields = [f for f, _, _ in svc._GEOM_COVERAGE + svc._GEOM_BLOCKAGE]
    assert "zone_relocate_norm" not in fields
    # 음성 대조: 같은 표의 다른 행들은 그대로 살아 있다(표를 통째로 비워서 통과하는 것 방지).
    assert "zone_blocked" in fields and "zone_nav_blocked" in fields


def test_the_field_survives_even_though_the_row_is_gone():
    """🔴 R8: 지운 것은 렌더 행 하나뿐이다. 필드를 지우면 대리모델 피처 레인이 깨진다."""
    assert "zone_relocate_norm" in svc.MacroRequest.model_fields
    assert _req().zone_relocate_norm == 2.38
    # 그 필드는 여전히 surrogate 쪽으로 흐르는 요청에 실린다(대리모델 피처의 출처).
    assert svc.MacroRequest(kind="zone", zone_relocate_norm=-1.0).zone_relocate_norm == -1.0


# ---------------------------------------------------------------------------------------------
# (B) zones 선언 · 렌더
# ---------------------------------------------------------------------------------------------
def test_zones_survives_the_pydantic_boundary():
    """변이: `MacroRequest` 에서 `zones: Optional[List[Dict[str, Any]]]` 선언을 지우면
    pydantic 이 키를 **조용히 버려** `r.zones` 가 AttributeError 로 사라진다."""
    r = _req(zones=ZONES)
    assert "zones" in svc.MacroRequest.model_fields
    assert r.zones == ZONES
    assert r.zones[0]["key"] == "block"


def test_no_active_zone_renders_the_empty_string():
    """비공간 사건의 입력은 **바이트 단위로 예전과 같아야 한다.**

    `open_zone_descriptors` 는 활성 구역이 없으면 **빈 목록**을 내므로, 이 시험의 `[]` 가
    라이브에서 실제로 오는 값이다(`None` 은 아직 안 싣는 옛 호출자).
    """
    assert svc._zones_block(svc.MacroRequest(kind="battery")) == ""
    assert svc._zones_block(svc.MacroRequest(kind="zone", zones=[])) == ""
    battery = dict(kind="battery", severity=0.3, soc=0.18, spare_count=2, n_active=8,
                   progress=0.44, nl="Robot 4's battery is nearly empty.",
                   descriptors=[0.4, 0.2, 0.1, 0.5, 0.44, 0.6])
    base = svc._llm_input(svc.MacroRequest(**battery))
    assert svc._llm_input(svc.MacroRequest(zones=[], **battery)) == base
    assert svc._llm_input(svc.MacroRequest(zones=None, **battery)) == base
    assert svc._ZONE_HEADER not in base


def test_live_zones_are_rendered_into_the_prompt():
    """변이: `_llm_input` 의 `+ _zones_block(r)` 를 지우면 값은 살아남지만 프롬프트에 안 뜬다
    (= 선언만 하고 렌더를 안 한 상태). 두 반환 경로를 모두 잰다."""
    for text in (svc._llm_input(_req(zones=ZONES)),
                 svc._llm_input(_req(zones=ZONES, nl=None))):
        assert svc._ZONE_HEADER in text
        assert 'zone "block"' in text
        assert "[12.5, 3.0]" in text and "2.5" in text
        assert "AssemblyComplete7" in text and "AssemblyComplete12" in text
        assert "root_goals_inside = yes" in text


def test_covers_root_false_is_rendered_as_a_measured_fact_not_a_silence():
    """`covers_root=False` 를 **안 적으면** "재봤더니 아니다"와 "안 쟀다"가 구별되지 않는다."""
    zs = [dict(ZONES[0], covers_root=False, covers=[])]
    block = svc._zones_block(svc.MacroRequest(kind="zone", zones=zs))
    assert "root_goals_inside = no" in block
    assert "covers            = 0 sub-assemblies" in block


# 판정(verdict) 어법의 잣대.
# 🔴 이 서비스가 이미 가진 `_IMPERATIVE` 를 그대로 쓰려다 **실측으로 기각했다**(2026-08-29):
#    그 정규식은 주입 문장의 지시절(`dispatch`/`restage`/`avoid` ...)에 맞춰져 있어서
#    `"the root cannot be restaged, so relocate the whole build"` — 이 태스크가 막으려는 바로
#    그 문장 — 을 **못 잡는다**(`restage\b` 가 "restaged" 에서 경계에 걸리고 `relocate` 는
#    어휘에 아예 없다). 그래서 잣대를 따로 둔다. `_IMPERATIVE` 도 함께 대지만 그건 보조다.
_VERDICT_WORDS = ["relocate", "restag", "re-stage", "should", "must ", "cannot",
                  "recommend", "instead", "whole build", "the answer", "correct action",
                  "you need to", "therefore"]
_LEAK = "the root cannot be restaged, so relocate the whole build"


def _verdict_hits(text):
    low = text.lower()
    return [w for w in _VERDICT_WORDS if w in low]


def test_no_verdict_phrasing_leaks_into_the_zone_render():
    """🔴 (A)와 같은 규약이다: 사실만 적고 무엇을 하라는 적지 않는다.

    특히 `covers_root` 를 *"루트는 재적치할 수 없으니 빌드 전체를 옮겨라"* 로 번역하지 않는다 —
    그건 오라클의 판정이지 증거가 아니다. 단언 범위를 **이 태스크가 쓴 산문**(zones 블록)으로
    한정한다: 기존 `_GEOM_COVERAGE` 문구는 이 태스크가 소유하지 않는다.
    """
    block = svc._zones_block(_req(zones=ZONES))
    assert block                                   # 빈 문자열이라 통과하는 것이 아님을 먼저 못박는다
    assert _verdict_hits(block) == []
    # 음성 대조: 그 잣대가 실제로 무언가를 잡긴 하는가(항상 통과하는 시험이 아님을 보인다).
    assert _verdict_hits(_LEAK)
    # 보조 잣대. 🔴 위 주석대로 이것 **하나로는 부족하다** — 같은 `_LEAK` 문장을 못 잡는다.
    assert svc._IMPERATIVE.search(block) is None
    assert svc._IMPERATIVE.search(_LEAK) is None   # 실측 기록: 그래서 `_VERDICT_WORDS` 가 있다


def test_zones_are_rejected_at_the_pydantic_boundary_when_malformed():
    """형태가 틀린 항목은 렌더러가 아니라 **경계**에서 걸린다 — 그래서 렌더러에 도달 불가능한
    `isinstance` 가드를 두지 않는다(그런 가드는 "막고 있다"는 거짓 안심을 만든다).

    ⚠️ 대가는 보고서에 적었다: 호출자가 이상한 `zones` 를 실으면 그 요청은 422 로 **떨어진다**
    (조용히 무시되지 않는다). 시끄러운 쪽이 옳지만, 그 사실이 여기 기록돼 있어야 한다.
    """
    import pydantic
    with pytest.raises(pydantic.ValidationError):
        svc.MacroRequest(kind="zone", zones=["junk"])
    # 빈 dict 는 유효한 항목이다(키가 없을 뿐) — 그 경우 렌더는 key 를 "?" 로 적고 살아남는다.
    assert 'zone "?"' in svc._zones_block(svc.MacroRequest(kind="zone", zones=[{}]))
