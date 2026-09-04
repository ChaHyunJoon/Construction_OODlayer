"""🔴 Task 2 fix round 1. `build_world_interface_block` 은 `t["fields"]` 를 무조건
읽었다 — Task 2 가 고정점 폐포를 넣으면서 추상 타입 항목(`subtypes` 만 있고 `fields`
가 없는)이 산출물에 실리기 시작했고, 그 항목을 만나면 `KeyError: 'fields'` 로 죽는다.
`synthesize.py:626` 이 이 함수로 agent-3 프롬프트를 만드니 이건 라이브 경로다.

이 파일은 그 회귀를 이 항목만으로 고정한다: 추상 타입(`subtypes`, `fields` 없음)이
섞인 blob 을 줘도 예외 없이 렌더되고, subtypes 이름이 블록에 실제로 나타난다.
유료 0건 — `world_interface.py` 는 blob 을 직접 받는다.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import world_interface as WI  # noqa: E402


def _blob(types):
    return {"types": types, "methods": []}


def test_an_abstract_type_entry_renders_without_raising():
    blob = _blob([
        {"name": "SceneTreeEdge", "subtypes": ["PermanentEdge", "TemporaryEdge"]},
        {"name": "ScheduleNode", "fields": [{"name": "id", "type": "ActionID"}]},
    ])
    s = WI.build_world_interface_block(blob)   # 고치기 전엔 KeyError('fields') 로 죽는다
    assert "SceneTreeEdge" in s


def test_the_subtype_names_reach_the_block():
    blob = _blob([
        {"name": "SceneTreeEdge", "subtypes": ["PermanentEdge", "TemporaryEdge"]},
    ])
    s = WI.build_world_interface_block(blob)
    assert "PermanentEdge" in s and "TemporaryEdge" in s


def test_a_concrete_type_entry_is_unaffected():
    """빈-통과 방지: 구상 타입 렌더는 이번 수정으로 안 바뀌었다."""
    blob = _blob([
        {"name": "ScheduleNode", "fields": [{"name": "id", "type": "ActionID"},
                                             {"name": "spec", "type": "PathSpec"}]},
    ])
    s = WI.build_world_interface_block(blob)
    assert "id :: ActionID" in s
    assert "spec :: PathSpec" in s
    assert "abstract" not in s.lower()
