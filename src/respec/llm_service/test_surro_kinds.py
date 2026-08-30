"""`/health` 가 **학습행에서 유도한** kind 집합을 싣는가 (2026-08-29, T9).

🔴 왜 유도인가. 손으로 쓴 kind 목록은 두 번째 진실원이 되고, 이 파일이 지키는 대상
(`dspy_service.py`)은 그 사고를 이미 한 번 밟았다 — `surrogate_rank` 의
`or set(range(5))`(`:664-668`)가 구세대 리터럴로 지원집합을 조용히 대체해, 축 1 이 자기가
존재하는 이유인 바로 그 실패 모드에서 침묵했다. 그래서 kind 집합은 `surro_support` 와
**완전히 같은 모양**으로 학습행에서 유도한다.

삼상 규약은 `surro_support` 와 같다:
    `None` = **못 쟀다** · `[]` = 쟀는데 비었다 · `[이름…]` = 쟀다.
🔴 `None` 이 하중을 진다 — T11 의 `select_lane` 이 `known_kinds === nothing` 에서 **에러를
   던진다**(조용히 한쪽으로 안 떨어진다). 즉 이 파일이 지키는 것은 라우터의 정지 조건이다.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import dspy_service as svc  # noqa: E402  (numpy/sklearn-before-dspy 계약)
import pytest  # noqa: E402


def test_health_carries_the_kind_set_derived_from_the_training_rows():
    """🔴 실측 기준값(2026-08-29): `oracle_dataset.jsonl` 33행의 kind 는 {battery, fault} 이고
    도장 `train_kinds` 는 전행 `"battery,fault"` — 둘이 일치하므로 측정이 성립한다."""
    svc._load_surrogate()
    assert svc._state["surro_kinds"] == {"battery", "fault"}
    assert svc.health()["surro_kinds"] == ["battery", "fault"]


def test_a_stamp_that_disagrees_with_the_rows_is_reported_not_swallowed(monkeypatch):
    """🔴 음성 대조. 도장과 관측된 kind 가 갈리면 **못 쟀다**(`None`)로 떨어지고 사유가
    `surro_error` 에 남는다. 한쪽을 골라 믿으면 안 된다 — 갈렸다는 것은 데이터셋 세대가
    섞였다는 뜻이고, 그 상태에서 낸 kind 집합은 라우터를 조용히 틀린 쪽으로 민다."""
    import eval_surrogate_v2

    real = eval_surrogate_v2.load_rows

    def fake(path, *a, **kw):
        rows, meta = real(path, *a, **kw)
        rows = [dict(r, train_kinds="battery") for r in rows]   # 도장만 어긋낸다
        return rows, meta

    monkeypatch.setattr(eval_surrogate_v2, "load_rows", fake)
    svc._load_surrogate()
    try:
        assert svc._state["surro_kinds"] is None
        assert "train_kinds" in (svc._state["surro_error"] or "")
        assert svc.health()["surro_kinds"] is None
        # 🔴 모델 자체는 살아 있어야 한다 — kind 를 못 쟀다고 surrogate 를 못 쓰게 만들면
        #    이 태스크가 라우팅과 무관한 회귀를 낸다.
        assert svc._state["surrogate"] is not None
    finally:
        svc._load_surrogate()          # 전역 복원 (이 레포가 반복해 데인 자리)


def test_the_service_still_boots_when_the_kind_set_cannot_be_measured(monkeypatch):
    """🔴 R-25 규약: `_load_surrogate` 실패는 startup 을 죽이지 않는다. `/health` 로 알린다.
    (`load_rows` 는 로딩 계약 위반을 `SystemExit` 으로 내므로 그것으로 재현한다.)"""
    import eval_surrogate_v2

    def boom(*a, **kw):
        raise SystemExit("no such labels file")

    monkeypatch.setattr(eval_surrogate_v2, "load_rows", boom)
    svc._state["surro_kinds"] = "sentinel"
    svc._load_surrogate()                       # 예외가 나오면 이 줄에서 죽는다
    try:
        assert svc._state["surro_kinds"] is None, "못 쟀으면 None 이지 낡은 값이 아니다"
        assert svc.health()["surro_kinds"] is None
        assert "SystemExit" in (svc._state["surro_error"] or "")
    finally:
        svc._load_surrogate()


def test_the_kind_set_is_not_a_hand_written_literal():
    """🔴 이 파일의 머리말이 말하는 실패 모드의 그물. kind 목록이 소스에 리터럴로 박히면
    학습셋이 바뀌어도 안 따라간다 — `surro_support` 와 같은 모양(행에서 유도)이어야 한다."""
    src = open(os.path.join(HERE, "dspy_service.py"), encoding="utf-8").read()
    body = src[src.index("def _load_surrogate"):src.index("def _load_program")]
    for literal in ('"battery"', "'battery'", '"fault"', "'fault'"):
        assert literal not in body, \
            "_load_surrogate 안에 kind 리터럴 %s 가 있다 — 두 번째 진실원이다" % literal
