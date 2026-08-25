"""load_rows 가 어휘 도장을 검사하는지 -- 구세대 라벨이 조용히 읽히면 안 된다."""
import json
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
WM = os.path.dirname(HERE)
for d in (HERE, os.path.join(WM, "core")):
    if d not in sys.path:
        sys.path.insert(0, d)

import action_registry  # noqa: E402
from eval_surrogate_v2 import load_rows  # noqa: E402


def _row(vocab, **kw):
    """load_rows 가 요구하는 최소 열만 채운 한 행."""
    r = {"vocab": vocab, "fired": True, "macro": 2, "complete": True,
         "instance": "i1", "kind": "battery", "valid_mask": [1, 1, 1]}
    r.update(kw)
    return r


def _write(tmp_path, *rows):
    p = tmp_path / "labels.jsonl"
    p.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
    return str(p)


def test_current_stamp_loads(tmp_path):
    rows, meta = load_rows(_write(tmp_path, _row(action_registry.VOCAB)))
    assert len(rows) == 1
    assert meta["vocab"] == action_registry.VOCAB


def test_old_generation_is_rejected_loudly(tmp_path):
    with pytest.raises(ValueError, match="어휘 도장"):
        load_rows(_write(tmp_path, _row("v3-4arms")))


def test_missing_stamp_is_rejected_loudly(tmp_path):
    r = _row("x")
    del r["vocab"]
    with pytest.raises(ValueError, match="어휘 도장"):
        load_rows(_write(tmp_path, r))


def test_stamp_is_checked_before_the_fired_filter(tmp_path):
    """순서 게이트. 이 테스트만이 "fired 필터 **앞에서**" 를 실제로 잰다.

    앞의 세 테스트는 전부 `fired=True` 라 필터를 그냥 통과한다 — 검사를 필터 **뒤로**
    옮겨도 셋 다 초록이다(실측: 아래 파일 하나만 빨개진다). 여기 파일은 현행 도장의
    발화 행 하나 + 구세대 도장의 **미발화** 행 하나다. 검사가 필터 뒤에 있으면 구세대
    행이 먼저 걷혀 남는 도장은 {현행} 하나뿐이라 **조용히 통과한다** — 즉 구세대와
    현행을 concat 한 파일(n44_plus78 이 정확히 그 모양이었다)이 통과한다.
    """
    p = _write(tmp_path,
               _row(action_registry.VOCAB, fired=True),
               _row("v3-4arms", fired=False, instance="i2"))
    with pytest.raises(ValueError, match="어휘 도장"):
        load_rows(p)


def test_meta_carries_the_stamp_for_downstream_reports(tmp_path):
    _, meta = load_rows(_write(tmp_path, _row(action_registry.VOCAB)))
    assert meta["vocab"] == "v4-3arms"          # 오늘의 값. 세대가 갈리면 여기서 걸린다.
    assert meta["rows_in_file"] == 1
