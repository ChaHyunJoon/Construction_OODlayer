"""생성 agent 가 코드를 쓰기 위해 읽는 세계 인터페이스. (2026-09-03, 설계 §4)

🔴 리터럴을 여기 적지 않는다. `tools/gen_world_interface.jl` 이 만든 산출물 하나를 읽고,
   그 산출물이 현행 코드와 같은지는 `test/world_interface_current.jl` 이 지킨다.
"""
import json
import os
from typing import Any, Dict, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
WM = os.environ.get("WM_DIR") or os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(HERE))), "wm4spacecraft_manufacturing")
ARTIFACT = os.path.join(WM, "core", "world_interface.json")

_CACHE: Dict[str, Any] = {}


def load_world_interface(path: Optional[str] = None) -> Dict[str, Any]:
    """🔴 조용한 폴백을 두지 않는다 — 파일이 없으면 큰 소리로 죽는다. 빈 인터페이스로
    돌면 모델은 아무것도 못 부르는 코드를 쓰고, 그 실패가 모델 탓으로 기록된다."""
    p = path or ARTIFACT
    if p not in _CACHE:
        with open(p, encoding="utf-8") as fh:
            _CACHE[p] = json.load(fh)
    return _CACHE[p]


_RULES = (
    "HOW YOUR CODE IS CALLED -- these are hard requirements, not style:\n"
    "  1. Exactly one top-level definition: `function NAME!(env; k1=<default>, ...) ... end`.\n"
    "     `env` is the ONLY positional argument. Every other argument is a keyword and MUST\n"
    "     have a default. The harness builds `env` and passes your declared parameters as\n"
    "     keywords; any other shape cannot be called and is rejected before it runs.\n"
    "  2. The name must end with `!` and must NOT already exist in the module.\n"
    "  3. Return a value the harness can read a status from: either a Symbol, or a NamedTuple\n"
    "     with a `status::Symbol` field. That status is how the record says what happened.\n"
    "  4. No other definitions -- no `const`, no macros, no helper functions.\n"
)


def build_world_interface_block(blob=None) -> str:
    b = blob if blob is not None else load_world_interface()
    parts = [_RULES, "", "WORLD TYPES (fields you may read and write):"]
    for t in b["types"]:
        parts.append("- %s" % t["name"])
        for f in t["fields"]:
            parts.append("    %s :: %s" % (f["name"], f["type"]))
    parts += ["", "FUNCTIONS THE MODULE ALREADY HAS (call any of these from your body):"]
    for m in b["methods"]:
        parts.append("- %s %s" % (m["name"], m["signature"]))
    return "\n".join(parts)
