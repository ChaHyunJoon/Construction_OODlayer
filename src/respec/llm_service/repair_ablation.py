"""존 복구 base ablation — 서비스 쪽 (2026-09-23, 명세 docs/superpowers/specs/2026-09-23-zone-repair-base-ablation-design.md §6).

🔴 레벨은 정확히 셋. 그 밖의 값은 크게 죽는다 — 조용히 none 으로 떨어지면 팔이 섞인다.
🔴 산출물 이름 규칙은 Julia `tools/gen_world_interface.jl` 과 같다(한쪽만 바꾸지 말 것).
"""
import os
from typing import Any, Dict, Optional

LEVELS = ("none", "translate", "all")


def level(env=None) -> str:
    v = (os.environ if env is None else env).get("REPAIR_ABLATION", "none")
    if v not in LEVELS:
        raise ValueError("REPAIR_ABLATION=%r -- allowed exactly: %s" % (v, ", ".join(LEVELS)))
    return v


def artifact_name(lvl: str) -> str:
    level({"REPAIR_ABLATION": lvl})
    return "world_interface.json" if lvl == "none" else "world_interface.ablate_%s.json" % lvl


def check_handshake(run_ctx: Optional[Dict[str, Any]], service_level: str) -> Optional[str]:
    """None = 맞다. 문자열 = 거절 사유. run_ctx 에 키가 없으면 none 서비스에서만 통과한다."""
    theirs = (run_ctx or {}).get("repair_ablation")
    if theirs is None:
        return None if service_level == "none" else (
            "run_ctx has no repair_ablation but this service runs repair_ablation=%r" % service_level)
    return None if theirs == service_level else (
        "repair_ablation mismatch: julia=%r service=%r" % (theirs, service_level))
