"""`export_surrogate.py` 의 라벨 적재 경로가 어휘 도장을 검사하는지.

왜 별도 파일인가 (2026-08-25, Task 8 / R-52): `test_load_rows_vocab.py` 는
`eval_surrogate_v2.load_rows` 를 잰다. **배포 모델을 만드는 경로는 그 함수를 안 지나간다** —
`export_surrogate.py` 는 `e1_analyze.load` 를 직접 부르고 거기엔 검사가 없었다. 그래서 구세대
라벨로 재적합해도 조용히 성공했고, 나온 `surrogate_linear.json` 에는 **현행** 도장이 찍혔다.
검사가 두 벌이면 한쪽만 고쳐진다 — 그래서 둘 다 `action_registry.require_vocab_stamps` 를
부르고, 이 파일이 그 배선을 잰다.
"""
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
import export_surrogate  # noqa: E402


def _row(vocab, **kw):
    r = {"vocab": vocab, "fired": True, "macro": 2, "complete": True,
         "instance": "i1", "kind": "battery", "closed": 1.0, "makespan": 1.0}
    r.update(kw)
    return r


def _write(tmp_path, *rows):
    p = tmp_path / "labels.jsonl"
    p.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
    return str(p)


def test_current_stamp_loads(tmp_path):
    df = export_surrogate._load_labels(_write(tmp_path, _row(action_registry.VOCAB)))
    assert len(df) == 1


def test_old_generation_is_rejected_loudly(tmp_path):
    with pytest.raises(ValueError, match="어휘 도장"):
        export_surrogate._load_labels(_write(tmp_path, _row("v3-4arms")))


def test_missing_stamp_is_rejected_loudly(tmp_path):
    r = _row("x")
    del r["vocab"]
    with pytest.raises(ValueError, match="어휘 도장"):
        export_surrogate._load_labels(_write(tmp_path, r))


def test_stamp_is_checked_before_the_fired_filter(tmp_path):
    """순서 게이트. 구세대 도장이 **미발화** 행에만 붙은 파일.

    검사가 `df[df.fired == True]` **뒤로** 밀리면 그 행이 먼저 걷혀 남는 도장은 현행 하나뿐이라
    조용히 통과한다 — 구세대 반 + 현행 반인 파일(`n44_plus78` 이 그 모양이었다)이 그대로
    학습에 들어간다. 앞의 세 테스트는 전부 `fired=True` 라 이 회귀를 못 잡는다.
    """
    p = _write(tmp_path,
               _row(action_registry.VOCAB, fired=True),
               _row("v3-4arms", fired=False, instance="i2"))
    with pytest.raises(ValueError, match="어휘 도장"):
        export_surrogate._load_labels(p)


def test_macro_name_map_comes_from_the_registry(tmp_path):
    """print 요약의 이름 맵이 리터럴로 되돌아가면 여기서 걸린다.

    되돌아갔을 때의 피해: 이 맵은 `spec` 에 안 들어가므로 배포 모델은 멀쩡한데 **사람이 읽는
    요약이 오늘의 macro id 를 옛 어휘의 이름으로 부른다**(구 9팔 리터럴의 값). 그 출력이
    보고서에 인용되면 거짓 문장이 발행된다.

    🔴 여기에 이름을 리터럴로 적지 않는다(2026-08-25, Task 8b / M1·M2). 8a 가 여기 적었던
    `MACRO_NAME[2] == "SwapBattery"` 는 **정당한 어휘 변경에서 RED 가 된다** — 어휘 단일
    진실원이 `action_registry.json` 이라는 이 계획의 명제를 테스트가 스스로 어긴 것이다.
    대신 **JSON 을 독립 경로로 다시 읽어** 대조한다: `action_registry` 모듈을 거치지 않으므로
    "모듈이 자기 자신과 같다" 는 항진명제가 되지 않고, 구 9팔 리터럴(id 3~8 에 이름이 있는
    맵)은 id 집합이 달라 여기서 죽는다.
    """
    with open(action_registry.REGISTRY_PATH, encoding="utf-8") as fh:
        from_disk = {int(k): m["name"] for k, m in json.load(fh)["macros"].items()}
    assert from_disk, "레지스트리가 비었다 — 대조가 항진명제가 된다"
    assert export_surrogate.MACRO_NAME == from_disk
    assert export_surrogate.MACRO_NAME == action_registry.MACRO_NAME
