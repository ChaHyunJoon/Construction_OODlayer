"""
action_registry.py -- action_registry.json 을 읽는 **유일한** 로더.

왜 있는가 (PLAN_LLM_INFERENCE_7H §P2 / Ch-A):
    매크로 id-이름-비용 표가 6곳에 리터럴로 복사돼 있었고 서로 달랐다. 가장 아픈 두 곳:
      llm_producer.MACRO_NAME 에 8(SwapBattery) 이 없어서 **LLM 은 battery 의 기본 정답을
      발화할 방법이 없었다** -- 정답이 어휘 밖이면 적중률은 원리적으로 100% 가 못 된다.
      steering_signature.MACROS 는 5개뿐이라 7·8 이 둘 다 빠져 있었다.
    이 모듈은 새 추상화가 아니라 **JSON 한 장을 읽어 dict 세 개로 펴는 것**이 전부다.

조용한 폴백을 두지 않는다(계획 §P2 "롤백" 절):
    파일이 없거나 깨졌으면 큰 소리로 죽는다. try/except 로 옛 리터럴로 되돌아가면
    "레지스트리를 배선했다고 믿고" 돌린 실험이 사실은 옛 어휘로 돈 것이 되고, 그 사고는
    로그 한 줄에 묻힌다. 어휘 불일치가 정확히 이 파일이 고치는 병이므로 여기서 감추지 않는다.

[문법 참고]
  - json.load(open(p, encoding="utf-8")) : JSON 파일을 dict 로 읽기.
  - {int(k): v for k, v in d.items()}    : 키를 문자열 -> 정수로 바꾸는 dict comprehension
                                          (JSON 은 객체 키가 언제나 문자열이라 필요하다).
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
REGISTRY_PATH = os.environ.get("ACTION_REGISTRY", os.path.join(HERE, "action_registry.json"))


def load(path=None):
    """레지스트리를 {id(int): {name, cost, kinds, doc}} 로 돌려준다."""
    p = path or REGISTRY_PATH
    with open(p, encoding="utf-8") as fh:
        blob = json.load(fh)
    return {int(k): v for k, v in blob["macros"].items()}


REGISTRY = load()
MACRO_NAME = {i: m["name"] for i, m in REGISTRY.items()}
MACRO_COST = {i: float(m["cost"]) for i, m in REGISTRY.items()}
NAME2ID = {m["name"]: i for i, m in REGISTRY.items()}
MACROS = sorted(REGISTRY)
# 사건 종류별로 전제조건상 말이 되는 팔. 상태를 아는 호출자(policy.jl)가 `valid` 를 실어 보내면
# 언제나 그쪽이 이긴다 -- 이 표는 상태를 모르는 호출자를 위한 폴백일 뿐이다.
KIND_VALID = {}
for _i, _m in REGISTRY.items():
    for _k in _m.get("kinds", []):
        KIND_VALID.setdefault(_k, []).append(_i)
for _k in KIND_VALID:
    KIND_VALID[_k] = sorted(KIND_VALID[_k])


def doc_lines(ids=None):
    """프롬프트에 넣을 '- 이름 : 설명 Costs X.' 줄들. ids 를 주면 그 팔만."""
    ids = sorted(ids if ids is not None else MACROS)
    out = []
    for i in ids:
        m = REGISTRY[i]
        out.append("- %s (cost %.1f): %s" % (m["name"], float(m["cost"]), m["doc"]))
    return out


def names(ids=None):
    return [MACRO_NAME[i] for i in sorted(ids if ids is not None else MACROS)]
