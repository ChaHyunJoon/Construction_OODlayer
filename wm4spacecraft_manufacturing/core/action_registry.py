"""
action_registry.py -- action_registry.json 을 읽는 **유일한** 로더.

왜 있는가:
    매크로 id-이름-비용 표가 여러 곳에 리터럴로 복사돼 있었고 서로 달랐다. 가장 아팠던 곳은
    llm_producer.MACRO_NAME 에 SwapBattery 가 없어서 **LLM 이 battery 의 싼 정답을 발화할
    방법이 없었던** 것이다 -- 정답이 어휘 밖이면 적중률은 원리적으로 100% 가 못 된다.
    이 모듈은 새 추상화가 아니라 **JSON 한 장을 읽어 dict 몇 개로 펴는 것**이 전부다.

조용한 폴백을 두지 않는다:
    파일이 없거나 깨졌으면 큰 소리로 죽는다. try/except 로 옛 리터럴로 되돌아가면
    "레지스트리를 배선했다고 믿고" 돌린 실험이 사실은 옛 어휘로 돈 것이 되고, 그 사고는
    로그 한 줄에 묻힌다. 어휘 불일치가 정확히 이 파일이 고치는 병이므로 여기서 감추지 않는다.

2026-08-20 축소 (9팔 -> 4팔, id 재번호 0..3):
    은퇴 표식(`retired`) 대신 **엔트리를 지웠다.** 구세대 산출물을 전부 폐기했으므로 이름표를
    남겨 KeyError 를 피할 이유가 없어졌다. 그 대가로 **id 재번호가 안전해졌지만 동시에
    도장(vocab)이 유일한 방어선이 됐다** -- 구세대 파일의 macro 2 행은 이제 KeyError 가 아니라
    RelocateBuild 로 **조용히** 읽힌다. `require_vocab` 을 소비처에 반드시 배선할 것.
    은퇴 기계(_is_retired / n_non_retired / RETIRED)는 API 호환과 도장 어서션을 위해 남긴다 --
    오늘 은퇴 엔트리는 0 개이므로 n_non_retired == len(MACROS) 다.
"""
import json
import os
import re

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

# ---- 어휘 도장 -------------------------------------------------------------------------------
# 왜 objective_hash 로 안 되는가: 해시는 목적함수의 스칼라를 도장한다. 어휘는 목적함수가
# 아니므로 어휘만 바뀌면 해시가 안 갈릴 수 있고, 실제로 dp value.json 에서 그 맹점이 발화했다.
# **소비처는 불일치 시 조용히 remap 하지 말고 죽는다.**
#
# 도장의 "<n>arms" 가 은퇴 표식이 없는 registry 항목 수와 같은지 로드 시점에 어서션한다.
# 문자열만 바꾸고 registry 를 안 고치면(또는 그 반대) 여기서 죽는다.
_VOCAB_ARMS_RE = re.compile(r"^v\d+-(\d+)arms$")


def _is_retired(i, m):
    """이 매크로가 은퇴했는가 -- **엄격** 판정.

    "retired" 는 **기계 술어**(반드시 JSON boolean)이고 사유 산문은 "retired_reason" 이다.
    쪼개 놓은 이유: 한 필드에 산문을 넣으면 Python 은 truthy 라 통과하는데 Julia 로더는
    `Bool("문자열")` 에서 MethodError 로 죽는다 -- 이 도장이 막으려는 바로 그 실패
    ("두 언어가 갈린다")가 도장 자신에게서 난다.

    규칙(양 언어 동일): 부재 -> False · boolean -> 그 값 · **그 밖의 무엇이든 -> 에러.**
    절대 강제변환하지 않고 절대 추측하지 않는다.

    2026-08-20 현재 은퇴 엔트리는 0 개다(은퇴 대신 삭제). 이 함수는 도장 어서션의 계약을
    유지하고 Julia 로더와 대칭을 맞추기 위해 남아 있다."""
    if "retired" not in m:
        return False
    v = m["retired"]
    if isinstance(v, bool):
        return v
    raise ValueError(
        "macro %r: 'retired' 값이 boolean 이 아니다(%r) -- remap 하지 않는다. "
        "명시적으로 true/false 로 고칠 것." % (i, v))


def n_non_retired(registry):
    """`registry` 에서 은퇴 표식이 없는 엔트리 수. 실험 팔 게이트(`experimental`)와는 다른
    축이다 -- 그건 ENV 로 켜고 끄는 **런타임** 성질이라 도장(정적 provenance)에 넣으면
    플래그를 export 하는 순간 도장의 유효성이 흔들린다."""
    return sum(1 for i, m in registry.items() if not _is_retired(i, m))


def assert_vocab_arm_count(vocab, n_actual):
    """도장의 `<n>arms` 를 `n_actual` 과 대조한다. 형식이 아니거나 수가 다르면 ValueError."""
    m = _VOCAB_ARMS_RE.match(vocab)
    if not m:
        raise ValueError(
            "vocab 도장 형식이 아니다(v<버전>-<n>arms 꼴이어야 한다): %r" % vocab)
    declared = int(m.group(1))
    if declared != n_actual:
        raise ValueError(
            "vocab 도장이 거짓말한다 -- 선언 %d arms(%r) vs 실제(은퇴 제외) registry %d arms. "
            "어휘가 실제로 바뀌었으면 이 문자열도 같이 갈아 끼울 것; 안 바뀌었으면 registry 를 "
            "되돌릴 것." % (declared, vocab, n_actual))


VOCAB = json.load(open(REGISTRY_PATH, encoding="utf-8")).get("vocab")
if not VOCAB:
    raise ValueError("action_registry.json 에 'vocab' 도장이 없다: %s" % REGISTRY_PATH)
assert_vocab_arm_count(VOCAB, n_non_retired(REGISTRY))


def require_vocab(obj, where):
    """산출물 dict 의 어휘 도장을 대조한다. 없거나 다르면 ValueError.

    ⚠️ 2026-08-20 재번호 이후 이것이 **유일한** 방어선이다. 예전에는 구세대 macro id 가
    영구 결번이라 조회 실패로도 죽었지만, 이제 0..3 이 연속이라 구세대 행이 조용히 읽힌다."""
    got = obj.get("vocab") if hasattr(obj, "get") else None
    if got is None:
        raise ValueError(
            "%s: 어휘 도장('vocab')이 없다 -- 구세대 파일이다. 현행은 %r. "
            "remap 하지 않는다." % (where, VOCAB))
    if got != VOCAB:
        raise ValueError(
            "%s: 어휘 도장 불일치 -- 파일 %r vs 현행 %r." % (where, got, VOCAB))


def require_dynamics(obj, expected, where):
    """동역학 도장을 대조한다. hazard on/off 는 objective_hash 로 못 잡는 별도 축이다."""
    got = obj.get("dynamics") if hasattr(obj, "get") else None
    if got is None:
        raise ValueError("%s: 동역학 도장('dynamics')이 없다 -- 구세대 파일이다. 기대 %r."
                         % (where, expected))
    if got != expected:
        raise ValueError("%s: 동역학 도장 불일치 -- 파일 %r vs 기대 %r." % (where, got, expected))


# ---- 실험 팔 게이트 --------------------------------------------------------------------------
# 매크로에 `"experimental": "<ENV 이름>"` 이 있으면 그 환경변수가 "1" 일 때만 **제안 대상**이 된다.
# 2026-08-20 현재 실험 팔은 0 개다(조합 팔 5·6 이 삭제됐다).
EXPERIMENTAL = {i: m["experimental"] for i, m in REGISTRY.items() if m.get("experimental")}

# ---- 은퇴한 팔 -------------------------------------------------------------------------------
# 2026-08-20 현재 비어 있다. 은퇴 표식 대신 엔트리를 삭제하는 정책으로 바꿨다.
RETIRED = {i: m.get("retired_reason", "") for i, m in REGISTRY.items() if _is_retired(i, m)}


def is_active(i):
    """이 매크로를 지금 **제안해도 되는가**. registry 밖 id 는 무조건 아니고(-1·9·10 등 손으로
    넣을 수 있는 값), 은퇴한 팔도 무조건 아니고, 실험 팔은 자기 ENV 플래그가 켜졌을 때만."""
    if i not in REGISTRY:
        return False
    if i in RETIRED:
        return False
    flag = EXPERIMENTAL.get(i)
    return flag is None or os.environ.get(flag, "0") == "1"


ACTIVE_MACROS = [i for i in MACROS if is_active(i)]

# 사건 종류별로 전제조건상 말이 되는 팔. 상태를 아는 호출자(policy.jl)가 `valid` 를 실어 보내면
# 언제나 그쪽이 이긴다 -- 이 표는 상태를 모르는 호출자를 위한 폴백일 뿐이다.
# 사건 종류는 셋뿐이다: fault / battery / zone. 'reform' 은 더 이상 decision epoch 가 아니다.
KIND_VALID = {}
for _i, _m in REGISTRY.items():
    if not is_active(_i):
        continue
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
