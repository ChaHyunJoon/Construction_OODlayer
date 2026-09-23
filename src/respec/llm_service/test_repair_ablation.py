"""존 복구 base ablation — 서비스 쪽 레벨·산출물·핸드셰이크 (명세 §6).
레포 루트에서: .venv/bin/python -m pytest src/respec/llm_service/test_repair_ablation.py -q
"""
import os
import pytest
import repair_ablation as RA
import world_interface as WI


def test_level_accepts_exactly_three():
    assert RA.level({}) == "none"
    for v in ("none", "translate", "all"):
        assert RA.level({"REPAIR_ABLATION": v}) == v
    for bad in ("", "ALL", "a2", "None", " all"):
        with pytest.raises(ValueError):
            RA.level({"REPAIR_ABLATION": bad})


def test_artifact_name_matches_julia_rule():
    assert RA.artifact_name("none") == "world_interface.json"
    assert RA.artifact_name("translate") == "world_interface.ablate_translate.json"
    assert RA.artifact_name("all") == "world_interface.ablate_all.json"


def test_ablated_artifacts_exist_and_hide_the_base():
    core = os.path.dirname(WI.ARTIFACT)
    for lvl, gone in (("translate", "translate_whole_build!"), ("all", "restage_all_blocked!")):
        blob = WI.load_world_interface(os.path.join(core, RA.artifact_name(lvl)))
        text = WI.build_world_interface_block(blob)
        assert gone not in text
        assert "zone_facts" in text


def test_handshake():
    assert RA.check_handshake({"repair_ablation": "all"}, "all") is None
    assert "mismatch" in RA.check_handshake({"repair_ablation": "none"}, "all")
    assert RA.check_handshake(None, "none") is None              # 옛 호출자·시험은 none 에서만 통과
    assert RA.check_handshake({}, "none") is None
    assert "no repair_ablation" in RA.check_handshake({}, "all")
