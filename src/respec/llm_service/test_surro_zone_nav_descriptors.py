"""`_surro_row` 는 zone-nav-blockage 를 LLM 레인과 **같은 사건**에서 같이 봐야 한다.

(2026-08-31, S1, defect follow-up.) `MacroRequest` 는 `zone_nav_blocked`·`zone_nav_downstream`
을 선언하고 LLM 레인(`_llm_input`)은 호출자가 실어 보낸 `req.descriptors` 를 그대로 렌더한다 —
그 벡터는 줄리아 `CB.event_descriptors` 가 **이미 nav-blockage 공식으로** 계산해 보낸 것이다
(`test/zone_harm_is_blockage.jl`). 그런데 같은 `req` 에서 surrogate 레인이 스스로 서술자를
다시 계산하는 자리(`_surro_row` -> `features_agnostic.descriptors_from_row`)는 이 두 필드를
읽지 않았다 — `descriptors_from_row` 가 -1.0 센티널로 떨어져 `zone_terminal=False` 로 접히고,
같은 사건에 대해 surrogate 레인은 옛 area-ratio 공식(`harm ≈ zone_overlap`)을 본다.

이 파일은 **같은 `req` 하나**에 대해 surrogate 레인이 실제로 계산하는 서술자 벡터가, `req`가
실어온 원시값으로 (LLM 레인이 실제로 프롬프트에 놓는 값과 동치인) `descriptors_from_row` 를
직접 부른 결과와 **일치하는가**를 잰다. 두 계산은 같은 파이썬 함수(`descriptors_from_row`)를
쓰지만 **입력 딕셔너리를 만드는 경로가 다르다** — `_surro_row`(수복 대상)와, 요청의 원시
필드를 그대로 읽는 참조 딕셔너리. 결함이 있으면(=`_surro_row`가 두 키를 안 채우면) 전자는
"안 쟀다"로, 후자는 "쟀다"로 갈려 두 벡터가 갈린다.

음성 대조: `_surro_row` 를 되돌려 두 키를 빼면 이 파일의 첫 시험이 **반드시** 빨개지는 것을
`.superpowers/sdd/2026-08-31-s1-observation-and-thresholds/task-surro-report.md` 에 실측으로
남겼다 — 격리해서 다시 재현하려면 `_surro_row` 반환 dict 에서 `zone_nav_blocked`/
`zone_nav_downstream` 두 줄을 지우고 이 파일만 돌릴 것.
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import dspy_service as svc  # noqa: E402  (numpy/sklearn-before-dspy 계약, WM/core 경로 부트스트랩)
import features_agnostic as fa  # noqa: E402  (dspy_service import 가 wm4/core 를 sys.path 에 얹는다)

# 2026-08-30 라이브 판과 같은 자릿수의 zone-nav 사건. `zone_nav_blocked >= 1` 이므로
# `descriptors_from_row` 의 `zone_terminal` 이 참이어야 한다(고쳐졌다면).
ZONE_NAV_REQ = dict(
    kind="zone", severity=0.4, progress=0.177, n_active=18, spare_count=8,
    closed_at_fire=54, total_nodes=305,
    zone_overlap=0.002356843670973429,
    zone_nav_blocked=3, zone_nav_downstream=32,
)


def _req(**kw):
    d = dict(ZONE_NAV_REQ)
    d.update(kw)
    return svc.MacroRequest(**d)


def _reference_row(req):
    """LLM 레인이 프롬프트에 놓는 값과 동치인 참조 딕셔너리 -- 요청의 원시 필드를 그대로 읽는다
    (Julia `CB.event_descriptors` 호출자가 채우는 것과 같은 필드들, `_surro_row` 를 거치지 않는다).
    """
    return dict(
        severity=float(req.severity),
        soc=(math.nan if req.soc is None else float(req.soc)),
        zone_overlap=(-1.0 if req.zone_overlap is None else float(req.zone_overlap)),
        agent_pending=float(req.agent_pending),
        n_active=float(req.n_active),
        spare_count=float(req.spare_count),
        closed_at_fire=float(req.closed_at_fire),
        total_nodes=svc._total_nodes(req),
        progress=float(req.progress),
        zone_nav_blocked=(-1.0 if req.zone_nav_blocked is None else float(req.zone_nav_blocked)),
        zone_nav_downstream=(-1.0 if req.zone_nav_downstream is None else float(req.zone_nav_downstream)))


def test_surrogate_lane_and_llm_lane_compute_the_identical_descriptor_vector_for_a_nav_blocked_zone_event():
    """핵심 게이트. `zone_nav_blocked=3 >= 1` 인 사건 하나에서, surrogate 레인이 실제로 쓰는
    경로(`_surro_row` -> `descriptors_from_row`)와 LLM 레인이 보는 값과 동치인 참조 경로가
    **바이트 단위로 같은 6값 벡터**를 내야 한다. 고치기 전에는 surrogate 쪽이 zone_terminal
    판정을 놓쳐 harm≈zone_overlap(≈0.0024)를 내고, 참조 쪽은 harm=1.0(종단)을 낸다 — 갈린다.
    """
    req = _req()
    surro_row = svc._surro_row(req, macro=1)
    surro_desc = fa.descriptors_from_row(surro_row)

    ref_row = _reference_row(req)
    ref_desc = fa.descriptors_from_row(ref_row)

    # 참조 쪽이 실제로 종단 판정(harm=1.0)을 내는지 먼저 못박는다 -- 이게 안 되면 아래
    # 비교가 "둘 다 옛 공식으로 우연히 같다"는 거짓양성이 될 수 있다.
    assert ref_desc["harm"] == 1.0, "reference row failed to hit zone_terminal -- fixture is broken"

    for name in fa.STATE_DESCRIPTORS:
        a, b = surro_desc[name], ref_desc[name]
        assert math.isclose(a, b, rel_tol=0, abs_tol=1e-12), (
            f"surrogate lane and LLM-lane descriptor '{name}' diverge for the same event: "
            f"surrogate={a!r} reference={b!r}")


def test_negative_control_a_non_zone_event_is_untouched():
    """음성 대조: battery 사건(nav 필드 없음)에서는 이 fix 가 아무것도 바꾸지 않는다 --
    `_surro_row` 가 항상 -1.0 을 채우던 자리에 여전히 -1.0 을 채운다."""
    req = svc.MacroRequest(kind="battery", severity=0.3, soc=0.18, spare_count=2,
                            n_active=8, progress=0.44, agent_pending=-1)
    row = svc._surro_row(req, macro=2)
    assert row["zone_nav_blocked"] == -1.0
    assert row["zone_nav_downstream"] == -1.0


def test_absent_never_becomes_measured_zero():
    """🔴 삼상 규약: 필드가 없으면(`None`) `_surro_row` 는 0 이 아니라 -1.0(안 쟀다) 센티널로
    접어야 한다. 0 은 "쟀는데 안 막혔다"는 서로 다른 사실이다."""
    req = svc.MacroRequest(kind="zone", zone_overlap=0.1)
    row = svc._surro_row(req, macro=0)
    assert row["zone_nav_blocked"] == -1.0
    assert row["zone_nav_downstream"] == -1.0
