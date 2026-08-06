"""
audit_action_vocab.py -- 행동 어휘(id<->이름<->비용)가 **모든 소비처에서 같은지** 검사한다.

왜 스크립트인가 (PLAN_LLM_INFERENCE_7H §P2):
    README §2 는 "매크로를 늘리면 세 곳을 같이 늘려야 한다"고 **주석으로** 경고해 왔다. 주석은
    지켜지지 않았다 -- 실측 2026-08-06 기준으로 여섯 곳이 서로 달랐고, 그중 두 불일치는 그냥
    스타일 문제가 아니라 **정답을 어휘 밖으로 밀어냈다**:
      · llm_producer / dspy_service 에 SwapBattery(8) 없음  -> battery 의 싼 정답을 발화 불가
      · steering_signature 에 7·8 둘 다 없음                -> 그 팔로는 방향조차 못 냄
    어휘 불일치는 조용히 성능 저하로만 나타나므로(에러가 안 난다) 테스트로 만들어야 한다.

무엇을 검사하나: 각 소비처의 (id -> 이름) 과 (id -> 비용) 이 action_registry.json 과 같은가.
    레지스트리에 없는 조합 팔(5·6)은 **무시**한다 -- 그건 DS_COMBO_ARMS=1 일 때만 생성되는
    별도 어휘이고, 옛 덤프를 읽는 하위호환 항목이라 있어도 정상이다.

실행:  python audit_action_vocab.py        (repo 의 wm4spacecraft_manufacturing 에서)
종료코드 0 = 전부 일치. 1 = 하나라도 어긋남.

[문법 참고]
  - re.search(pat, text, re.S) : 여러 줄에 걸친 패턴 찾기(.이 줄바꿈도 매칭).
  - importlib.import_module    : 모듈 이름 문자열로 import.
"""
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                       # <repo>/ConstructionBots.jl
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "src", "respec", "llm_service"))

import action_registry as REG                                       # noqa: E402

FAIL = []
OK = []


def check(where, names=None, costs=None):
    """이 소비처의 이름표/비용표가 레지스트리와 같은지. 레지스트리에 없는 id 는 건너뛴다."""
    bad = []
    for i, nm in (names or {}).items():
        if i in REG.MACRO_NAME and REG.MACRO_NAME[i] != nm:
            bad.append("id %d name %r != %r" % (i, nm, REG.MACRO_NAME[i]))
    missing = sorted(set(REG.MACRO_NAME) - set(names or REG.MACRO_NAME))
    if names is not None and missing:
        bad.append("missing ids %s" % missing)
    for i, c in (costs or {}).items():
        if i in REG.MACRO_COST and abs(float(c) - REG.MACRO_COST[i]) > 1e-9:
            bad.append("id %d cost %s != %s" % (i, c, REG.MACRO_COST[i]))
    (FAIL if bad else OK).append((where, bad))


# ---- 1. llm_producer (오프라인 LLM arm) --------------------------------------------------
import llm_producer                                                 # noqa: E402
check("llm_producer.MACRO_NAME", names=llm_producer.MACRO_NAME)

# ---- 2. e1_analyze (채점·서로게이트 학습) -------------------------------------------------
import e1_analyze                                                   # noqa: E402
check("e1_analyze.MACRO_NAME/COST", names=e1_analyze.MACRO_NAME, costs=e1_analyze.MACRO_COST)

# ---- 3. features_agnostic (서술자·비용) ---------------------------------------------------
import features_agnostic                                            # noqa: E402
check("features_agnostic.MACRO_COST", costs=features_agnostic.MACRO_COST)

# ---- 4. dspy_service (라이브 데모의 LLM producer) ------------------------------------------
# dspy 가 없는 환경에서도 어휘만은 검사할 수 있게, import 대신 소스에서 MACROS 계산식을 확인한다.
# (이 서비스는 hjcrl venv 에서만 import 되고 wm4 venv 에는 dspy 가 없다.)
_svc = io.open(os.path.join(ROOT, "src", "respec", "llm_service", "dspy_service.py"),
               encoding="utf-8").read()
if "from action_registry import" in _svc and re.search(r"^MACROS = \[_REG_NAME\[i\]", _svc, re.M):
    OK.append(("dspy_service.MACROS", []))
else:
    FAIL.append(("dspy_service.MACROS", ["does not derive MACROS from action_registry"]))

# ---- 5. steering_signature (방향 벡터 arm) ------------------------------------------------
import steering_signature                                           # noqa: E402
check("steering_signature.MACROS",
      names={REG.NAME2ID[n]: n for n in steering_signature.MACROS if n in REG.NAME2ID})

# ---- 6. oracle/gen_oracle_dataset.jl (라벨러 = 채점 기준) ----------------------------------
# Julia 는 import 할 수 없으므로 소스에서 ACTION_NAME 표를 파싱한다. 이 표가 어긋나면
# "정답을 채점조차 못 하는" Ch-D 가 된다(계획 §1).
_jl = io.open(os.path.join(HERE, "oracle", "gen_oracle_dataset.jl"), encoding="utf-8").read()
_m = re.search(r"const ACTION_NAME = Dict\((.*?)\)\s*#", _jl, re.S)
_jl_names = {int(a): b for a, b in re.findall(r"(\d+)\s*=>\s*\"([^\"]+)\"", _m.group(1))} if _m else {}
check("gen_oracle_dataset.ACTION_NAME", names=_jl_names)

# ---- 보고 -------------------------------------------------------------------------------
print("action registry: %s" % REG.REGISTRY_PATH)
print("  macros: %s" % ", ".join("%d=%s(%.1f)" % (i, REG.MACRO_NAME[i], REG.MACRO_COST[i])
                                 for i in REG.MACROS))
print()
for where, bad in OK + FAIL:
    print("  %-34s %s" % (where, "OK" if not bad else "MISMATCH: " + "; ".join(bad)))
print()
print("%d/%d consistent" % (len(OK), len(OK) + len(FAIL)))
sys.exit(1 if FAIL else 0)
