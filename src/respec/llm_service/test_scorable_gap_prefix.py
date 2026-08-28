"""🔴 `surrogate_rank` 의 `if not scorable` 분기가 `UNSUPPORTED:` 규약을 지키는가.

배경 (2026-08-28): 이 분기는 `support is None` 가드를 이미 지난 자리라 지원집합을
**읽었다**. `tools/monitor/policy.jl:997-1005` 의 구조 계약은 `missing ≠ ∅` ⟹
`UNSUPPORTED:` 규약이 나왔다 ⟹ 그 사건은 "쟀다"로 기록되어야 한다는 것이다. 고치기
전에는 이 분기가 산문 메시지를 돌려줘 "못 쟀다"로 잘못 기록됐다(안전한 방향이지만
부정확). policy.jl 이 그 자리를 정확히 지목했으므로 여기서 그 방향을 못박는다.

두 갈래를 모두 잰다:
  1. `unsupported` 가 비지 않았으면 `"UNSUPPORTED:" + ",".join(unsupported)` (RED->GREEN)
  2. `unsupported` 도 비었으면(= `valid` 의 어떤 이름도 레지스트리에 없음) 그것은
     "지원 안 됨"이 아니라 "애초에 모르는 매크로"이므로 `UNSUPPORTED:` 규약 밖 메시지를
     유지한다 — 빈 이름 목록으로 그 규약을 쓰면 "쟀는데 뺄 게 없다"는 새 거짓말이 된다.
"""
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import dspy_service as svc  # noqa: E402

# 🔴 test_vocabulary_gap_fires.py 와 같은 이유로 필요: `_load_surrogate()` 를 안 부르면
# `_state["surro_support"]` 키가 아예 없어 아래 fixture 의 `saved` 가 늘 None 이 되고,
# "지원집합을 읽었다"는 이 테스트의 전제 자체가 우연히 참이 되어 버린다.
svc._load_surrogate()

MENU = ["NOOP", "Replace", "SwapBattery"]


@pytest.fixture
def support():
    saved = svc._state.get("surro_support")
    yield lambda s: svc._state.__setitem__("surro_support", s)
    svc._state["surro_support"] = saved


def _req(valid):
    return svc.MacroRequest(kind="battery", soc=0.1, valid=valid,
                            nl="Robot R5 has run its battery down and stopped.")


def test_scorable_empty_but_unsupported_nonempty_uses_UNSUPPORTED_prefix(support):
    """지원집합이 비어 있으면 legal 매크로 전부가 미달 -> scorable도 unsupported도
    비지 않은 상태가 아니라, scorable 은 비고 unsupported 는 valid 전체가 된다.
    이 경우가 바로 policy.jl 이 지목한 '읽었는데 UNSUPPORTED: 를 안 붙인' 자리다."""
    support(set())
    scored, err = svc.surrogate_rank(_req(MENU), MENU)
    assert scored is None
    assert err == "UNSUPPORTED:" + ",".join(MENU)


def test_scorable_and_unsupported_both_empty_stays_out_of_band(support):
    """`valid` 의 이름이 레지스트리(`name2id`)에 아예 없으면 scorable 도 unsupported 도
    비어 새 분기(2번째 return)로 간다 -- 여기서 UNSUPPORTED: 를 쓰면 빈 이름 목록으로
    '쟀는데 뺄 게 없다'는 거짓말이 되므로 규약 밖 메시지를 유지해야 한다."""
    support({0, 1, 2})
    valid = ["TotallyUnknownMacro"]
    scored, err = svc.surrogate_rank(_req(valid), valid)
    assert scored is None
    assert not str(err).startswith("UNSUPPORTED:")
    assert "unknown to registry" in err


def test_race_where_support_vanishes_between_the_two_reads_stays_unmeasured(support, monkeypatch):
    """🔴 리뷰 라운드 1, item 3. `surrogate_rank` 는 `support = _state.get("surro_support")`
    를 한 번 읽고 나서 `_unsupported_for` 가 **독립적으로 다시** 같은 키를 읽는다. 스레드
    서버에서 그 사이 모델이 리로드되면 후자가 `None`("못 쟀다")을 돌려줄 수 있는데,
    `if unsupported:` 만 보면 `None` 과 `[]` 가 똑같이 falsy라 "다 모른다"(규약 밖, 하지만
    틀린) 메시지로 떨어진다. 이 파일이 일부러 세 값(None/[]/[이름])을 구분하는 자리이므로
    여기서도 구분해야 한다 -- `unsupported is None` 이면 `support is None` 가드와 같은
    "못 쟀다" 메시지로 되돌아가야 한다."""
    support(set())                                        # scorable 이 반드시 비게 만든다
    monkeypatch.setattr(svc, "_unsupported_for", lambda req, valid: None)
    scored, err = svc.surrogate_rank(_req(MENU), MENU)
    assert scored is None
    assert not str(err).startswith("UNSUPPORTED:")
    assert "unknown (model not loaded)" in err
    assert "unknown to registry" not in err               # 다른 메시지와 안 섞였는지 확인


def test_valid_empty_is_a_known_vacuous_edge_unreachable_via_the_service(support):
    """리뷰의 표현 지적: '둘 다 비면 전부 미등록' 이라는 증명은 `valid` 자체가 비어 있으면
    공허하게 참이 되고, 그러면 "all unknown to registry" 메시지가 실제로는 거짓이 된다
    (뺄 이름이 없는 게 아니라 애초에 아무 것도 안 물어본 것). 서비스 경로로는 도달 불가능
    하다 -- `_valid_for` (`dspy_service.py:150-153`) 는 모든 사건 종류에서 `MACROS` 로
    폴백해 `valid` 가 절대 비지 않는다 -- 그래서 여기서는 경계 자체만 못박고, 고치지는
    않는다(범위 밖으로 남겨둔 리뷰의 판단을 따른다)."""
    support({0, 1, 2})
    scored, err = svc.surrogate_rank(_req([]), [])
    assert scored is None
    assert not str(err).startswith("UNSUPPORTED:")        # 빈 이름 목록으로 규약을 안 쓴다


def test_existing_UNSUPPORTED_contract_unaffected(support):
    """회귀 방지: 기존 프로듀서(2건, dspy_service.py 원래 :513·:524 자리)의 계약은
    이 수정으로 안 바뀐다 -- test_vocabulary_gap_fires.py 가 이미 못박고 있지만
    여기서도 한 번 더 확인한다(같은 파일에서 두 분기를 나란히 보기 위해)."""
    support({0, 1})
    scored, err = svc.surrogate_rank(_req(MENU), MENU)
    assert err == "UNSUPPORTED:SwapBattery"
