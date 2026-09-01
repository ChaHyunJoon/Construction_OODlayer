"""`_surro_row` 는 zone-nav-blockage 를 LLM 레인과 **같은 사건**에서 같이 봐야 한다.

(2026-08-31, S1, defect follow-up.) `MacroRequest` 는 `zone_nav_blocked`·`zone_nav_downstream`
을 선언하고 LLM 레인(`_llm_input`)은 호출자가 실어 보낸 `req.descriptors` 를 그대로 렌더한다 —
그 벡터는 줄리아 `CB.event_descriptors` 가 **이미 nav-blockage 공식으로** 계산해 보낸 것이다
(`test/zone_harm_is_blockage.jl`). 그런데 같은 `req` 에서 surrogate 레인이 스스로 서술자를
다시 계산하는 자리(`_surro_row` -> `features_agnostic.descriptors_from_row`)는 이 두 필드를
읽지 않았다 — `descriptors_from_row` 가 -1.0 센티널로 떨어져 `zone_terminal=False` 로 접히고,
같은 사건에 대해 surrogate 레인은 옛 area-ratio 공식(`harm ≈ zone_overlap`)을 본다.

🔴 2026-09-01 (review I-4). 이 파일은 예전에 "surrogate 레인과 LLM 레인이 같은 벡터를 낸다"는
cross-lane 시험을 자처했지만, 실제로는 `_reference_row`가 `_surro_row`의 몸통을 손으로 그대로
베낀 사본이어서 구현을 자기 자신의 스냅샷과 비교하고 있었다 — Julia↔Python 발산을, 즉 이 시험이
막으려던 바로 그 실패 유형을 원리적으로 볼 수 없었다("식을 베껴 쓴 시험"). 진짜 cross-lane
대조(프로덕션 경로 `MacroRequest` -> `_surro_row` -> `descriptors_from_row` 를 줄리아
`event_descriptors` 와 1e-12 로 비교)는 이제 `test/zone_harm_is_blockage.jl` 의 testset (6)에
있다 — 그 파일이 이미 (5)에서 같은 shell-out-to-venv-python 아이디엄으로 파이썬 twin 을 재는
자리였고, 줄리아가 "정답"(고쳐진 지 오래된 nav-blockage 공식)을 들고 있으므로 대조가 거기서
서는 것이 자연스럽다. 여기 파이썬 쪽에는 이제 그 골든카피 시험이 없다.

남은 둘은 애초에 cross-lane 을 주장한 적이 없는 `_surro_row` 자체의 순수 단위시험이라 그대로
둔다: 값이 없을 때 0 이 아니라 -1.0 센티널로 접는지(삼상 규약), 그리고 공간이 아닌 사건에서는
이 필드들이 전혀 안 건드려지는지.

음성 대조: `_surro_row` 를 되돌려 두 키를 빼면 `test/zone_harm_is_blockage.jl` testset (6)이
**반드시** 빨개지는 것을 이 태스크에서 실측으로 확인했다(4/29 assertion 실패, harm·work_at_risk
가 옛 area-ratio 값으로 되돌아간다) — 격리해서 다시 재현하려면 `_surro_row` 반환 dict 에서
`zone_nav_blocked`/`zone_nav_downstream` 두 줄을 지우고
`julia +lts --project=. test/zone_harm_is_blockage.jl` 을 돌릴 것.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import dspy_service as svc  # noqa: E402  (numpy/sklearn-before-dspy 계약, WM/core 경로 부트스트랩)

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


def test_measured_nav_fields_pass_through():
    """순수 `_surro_row` 단위시험(cross-lane 주장 없음): 측정된 nav 필드가 -1.0 센티널이 아니라
    원값 그대로 넘어가는지. 이 값이 줄리아의 답과 실제로 일치하는지의 cross-lane 대조는
    `test/zone_harm_is_blockage.jl` testset (6)의 것이다."""
    row = svc._surro_row(_req(), macro=1)
    assert row["zone_nav_blocked"] == 3.0
    assert row["zone_nav_downstream"] == 32.0


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
