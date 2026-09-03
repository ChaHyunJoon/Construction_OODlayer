"""생성 agent 가 읽는 세계 인터페이스 블록. 유료 0건."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import world_interface as WI  # noqa: E402


def test_the_artifact_loads():
    b = WI.load_world_interface()
    assert b["types"] and b["methods"]


def test_the_block_carries_the_env_schema():
    s = WI.build_world_interface_block()
    assert "PlannerEnv" in s
    for f in ("sched", "scene_tree", "cache", "staging_circles"):
        assert f in s, f


def test_the_block_carries_method_signatures():
    s = WI.build_world_interface_block()
    assert "reform_stuck_teams!" in s


def test_the_block_hides_the_non_exported_impls():
    """🔴 설계 D6. 이것이 참이라서 첫 측정이 뜻을 갖는다."""
    s = WI.build_world_interface_block()
    assert "release_pending_assignments!" not in s


def test_the_block_says_the_signature_convention():
    """모델이 규약 1 을 안 읽으면 등록이 전부 거절된다."""
    s = WI.build_world_interface_block()
    assert "(env;" in s and "keyword" in s.lower()
