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

#: 경로 -> (파일 도장, blob). 🔴 **키가 경로만이면 안 된다.** DSPy 서비스는 오래 살고,
#: 산출물의 최신성을 지키는 것은 줄리아 시험(`test/world_interface_current.jl`) 하나인데
#: **돌고 있는 서비스는 그것을 절대 안 본다.** 이 레포는 이미 그 모양으로 데었다 — 나흘 묵은
#: uvicorn 이 며칠 전에 들어온 코드를 안 가진 채 `/health` 200 을 내고 있었고, `/health` 의
#: 세대 도장 기계는 그 사고 때문에 생겼다. 낡은 스키마를 받은 모델이 쓴 코드는 기록에서
#: **모델의 실패**로 남는다. 그래서 도장으로 (mtime_ns, size) 를 같이 본다.
_CACHE: Dict[str, Any] = {}


def load_world_interface(path: Optional[str] = None) -> Dict[str, Any]:
    """🔴 조용한 폴백을 두지 않는다 — 파일이 없으면 큰 소리로 죽는다. 빈 인터페이스로
    돌면 모델은 아무것도 못 부르는 코드를 쓰고, 그 실패가 모델 탓으로 기록된다.

    🔴 `os.stat` 이 **캐시 히트에서도** 먼저 돈다. 그래야 (1) 다시 생성된 산출물을
    프로세스를 안 죽이고 읽고, (2) 지워진 산출물이 캐시에서 조용히 계속 나오지 않는다 —
    없는 파일은 히트에서도 큰 소리로 죽는 쪽이 이 파일의 규약과 같다.
    """
    p = path or ARTIFACT
    st = os.stat(p)                      # 🔴 없으면 여기서 죽는다(조용한 폴백 없음)
    stamp = (st.st_mtime_ns, st.st_size)
    hit = _CACHE.get(p)
    if hit is None or hit[0] != stamp:
        with open(p, encoding="utf-8") as fh:
            hit = (stamp, json.load(fh))
        _CACHE[p] = hit
    return hit[1]


_RULES = (
    "HOW YOUR CODE IS CALLED -- these are hard requirements, not style:\n"
    "  1. Exactly one top-level definition: `function NAME!(env; k1=<default>, ...) ... end`.\n"
    "     `env` is the ONLY positional argument. Every other argument is a keyword and MUST\n"
    "     have a default. The harness builds `env` and passes your declared parameters as\n"
    "     keywords; any other shape cannot be called and is rejected before it runs.\n"
    "  2. The name must end with `!` and must NOT already exist in the module.\n"
    "  3. Return a value the harness can read a status from: either a Symbol, or a NamedTuple\n"
    "     with a `status::Symbol` field. That status is how the record says what happened.\n"
    "  4. Exactly one TOP-LEVEL definition -- no other top-level `const`, macros, or\n"
    "     helper functions. Helper closures defined INSIDE your function body are fine.\n"
)


def build_world_interface_block(blob=None) -> str:
    b = blob if blob is not None else load_world_interface()
    parts = [_RULES, "", "WORLD TYPES (fields you may read and write):"]
    for t in b["types"]:
        parts.append("- %s" % t["name"])
        for f in t.get("fields") or []:
            parts.append("    %s :: %s" % (f["name"], f["type"]))
        if t.get("subtypes"):
            parts.append("    (abstract; one of: %s)" % ", ".join(t["subtypes"]))
    amb = b.get("ambient") or []
    if amb:
        parts += ["", "AMBIENT WORLD STATE (not on env; read it with the accessor shown):"]
        for a in amb:
            parts.append("- %s" % a["name"])
            parts.append("    %s  ->  %s" % (a["accessor"], a["returns"]))
    # 🔴 D11. 평평한 한 목록은 "선택자가 없다" 로 읽혔다(설계 §1.2) — 모델이 placeholder 를
    #    썼다. 가르는 것은 **렌더**이지 모집단이 아니다: 두 표제 다 같은 `b["methods"]` 에서
    #    나오고, D6 이 감춘 다섯은 애초에 산출물에 없다.
    now = [m for m in b["methods"] if m.get("callable")]
    later = [m for m in b["methods"] if not m.get("callable")]
    parts += ["", "FUNCTIONS YOU CAN CALL NOW (every argument is obtainable from env):"]
    for m in now:
        parts.append("- %s %s" % (m["name"], m["signature"]))
        for p in m.get("argpaths") or []:
            parts.append("      %s" % p)
    parts += ["", "FUNCTIONS THAT NEED SOMETHING YOU CANNOT OBTAIN YET:"]
    for m in later:
        parts.append("- %s %s" % (m["name"], m["signature"]))
    return "\n".join(parts)
