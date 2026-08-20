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

# ---- 어휘 도장 (2026-08-19, spec §2.4·§8; 리뷰 라운드 1 판정 G 로 정정) ---------------------
# 왜 objective_hash 로 안 되는가: 해시는 목적함수의 스칼라를 도장한다. 어휘는 목적함수가
# 아니므로 어휘만 바뀌면 해시가 안 갈릴 수 있고, 실제로 dp value.json 에서 그 맹점이 발화했다.
# 도장은 그 축을 따로 잡는다. **소비처는 불일치 시 조용히 remap 하지 말고 죽는다** —
# remap 하면 구세대 macro 3(ForbidZone) 행이 4(ReformTeam) 로 에러 없이 재해석된다.
#
# 판정 G (리뷰 라운드 1): 이 값은 **오늘 참인 것**을 선언해야 한다 — dynamics_stamp() 가
# hazard_enabled() 에서 유도되는 것과 대칭이다. 오늘 registry 는 3/5/6 이 아직 은퇴하지 않은
# 9팔이므로 "v1-9arms" 다. "v2-6arms" 는 태스크 5(3/5/6 은퇴) 이후에나 참이 되는 END-STATE
# 값이라 지금 여기 두면 **오늘부터 계속 거짓말하는 도장**이 된다 — 그 자체로는 아무도
# 못 잡는다(리터럴이라 검증 불가). 그래서 완전한 유도 대신 **기계적 일관성 검사**를 둔다:
# 도장의 "<n>arms" 가 **은퇴 표식이 없는** registry 항목 수와 같은지 로드 시점에 어서션한다.
#
# 재리뷰 정정(라운드 2): 처음엔 "실제 registry 항목 수" 를 `len(MACROS)`(= 전체 JSON
# 엔트리 수)로 재고 커밋했는데 이건 **정반대로 작동한다.** 태스크 5 의 은퇴(`task-5-brief.md`
# Step 3)는 3/5/6 엔트리를 **지우지 않는다** — "retired" 표식만 달고 이름·비용은 그대로
# 둔다(Step 5 의 `test_retired_macros_keep_their_names()` 가 그걸 요구한다). 그래서
# `len(MACROS)` 는 은퇴 뒤에도 **영원히 9** 다: 은퇴를 집행하고 도장을 안 바꾼 실수는
# (선언 9, 실제 9)로 통과해 못 잡고, 반대로 은퇴를 집행하고 도장을 옳게 "v2-6arms" 로
# 바꾼 정상 변경은 (선언 6, 실제 9)로 **죽어서 막아버린다** — 재리뷰가 스크래치 registry
# 로 두 방향 다 실측했다. 옳은 `n_actual` 은 **"retired" 표식이 없는 엔트리 수**
# (`n_non_retired`) 다: 오늘은 은퇴 표식이 0개라 9 그대로고, 태스크 5 가 3/5/6 을
# 은퇴시키면 6 으로 실제로 줄어든다.
#
# **이 어서션은 태스크 5 에서 load-bearing 이다**: 3/5/6 을 은퇴(retired 표식 추가)시키고
# 문자열을 "v2-6arms" 로 갈아 끼우는 순간, `n_non_retired` 가 6 을 세어 (선언 6, 실제 6)로
# 통과하는 것이 곧 은퇴가 실제로 집행됐다는 증거다. 문자열만 바꾸고 registry 에서 은퇴
# 표식을 안 달면(또는 그 반대) 여기서 죽는다.
_VOCAB_ARMS_RE = re.compile(r"^v\d+-(\d+)arms$")


def n_non_retired(registry):
    """`registry`(= {id: {..., 선택적 "retired": bool}}) 에서 은퇴 표식이 없는 엔트리 수.
    은퇴는 엔트리를 지우지 않고 표식만 다는 영구적 성질이다(레지스트리 자체의 속성) —
    실험 팔 게이트(`experimental`/`is_active`)와는 다른 축이다: 그건 ENV 로 켜고 끄는
    **런타임** 성질이라 도장(정적 provenance)에 넣으면 `DS_COMBO_ARMS=1` 을 export 하는
    순간 도장의 유효성이 흔들린다 — 그래서 여기서는 쓰지 않는다."""
    return sum(1 for m in registry.values() if not m.get("retired"))


def assert_vocab_arm_count(vocab, n_actual):
    """도장의 `<n>arms` 를 `n_actual`(호출자가 `n_non_retired(REGISTRY)` 로 넘긴다)과
    대조한다. 형식이 아니거나 수가 다르면 ValueError — 오늘은 (선언 9, 실제 9)로 통과하고,
    태스크 5 가 은퇴를 집행하며 문자열을 갈아 끼우는 순간의 (선언 6, 실제 6) 통과가 그
    은퇴가 실제로 됐다는 기계적 증거가 된다."""
    m = _VOCAB_ARMS_RE.match(vocab)
    if not m:
        raise ValueError(
            "vocab 도장 형식이 아니다(v<버전>-<n>arms 꼴이어야 한다): %r" % vocab)
    declared = int(m.group(1))
    if declared != n_actual:
        raise ValueError(
            "vocab 도장이 거짓말한다 — 선언 %d arms(%r) vs 실제(은퇴 제외) registry %d arms. "
            "어휘가 실제로 바뀌었으면 이 문자열도 같이 갈아 끼울 것; 안 바뀌었으면 registry 를 "
            "되돌릴 것." % (declared, vocab, n_actual))


VOCAB = json.load(open(REGISTRY_PATH, encoding="utf-8")).get("vocab")
if not VOCAB:
    raise ValueError("action_registry.json 에 'vocab' 도장이 없다: %s" % REGISTRY_PATH)
assert_vocab_arm_count(VOCAB, n_non_retired(REGISTRY))


def require_vocab(obj, where):
    """산출물 dict 의 어휘 도장을 대조한다. 없거나 다르면 ValueError."""
    got = obj.get("vocab") if hasattr(obj, "get") else None
    if got is None:
        raise ValueError(
            "%s: 어휘 도장('vocab')이 없다 — 구세대 파일이다. 현행은 %r. "
            "remap 하지 않는다(구 macro 3/5/6 은 영구 결번)." % (where, VOCAB))
    if got != VOCAB:
        raise ValueError(
            "%s: 어휘 도장 불일치 — 파일 %r vs 현행 %r." % (where, got, VOCAB))


def require_dynamics(obj, expected, where):
    """동역학 도장을 대조한다. hazard on/off 는 objective_hash 로 못 잡는 별도 축이다."""
    got = obj.get("dynamics") if hasattr(obj, "get") else None
    if got is None:
        raise ValueError("%s: 동역학 도장('dynamics')이 없다 — 구세대 파일이다. 기대 %r."
                         % (where, expected))
    if got != expected:
        raise ValueError("%s: 동역학 도장 불일치 — 파일 %r vs 기대 %r." % (where, got, expected))

# ---- 실험 팔 게이트 (2026-08-15) ------------------------------------------------------------
# 매크로에 `"experimental": "<ENV 이름>"` 이 있으면 그 환경변수가 "1" 일 때만 **제안 대상**이 된다.
# 왜 이 구조인가: 조합 팔 5·6 은 `oracle/ood_mdp_shim.jl` 의 `DS_COMBO_ARMS` 뒤에 실재하는데
# 레지스트리에는 없어서, 이름·비용만 소비처 네 곳에 유령으로 복사돼 있었다(2026-08-15 감사가 적발).
# 그렇다고 그냥 등록만 하면 **끄고도 메뉴에 뜬다** — shim 이 명시한 "OFF BY DEFAULT 면 기존 덤프
# 경로와 byte-identical" 계약이 깨진다. 그래서 어휘(이름·비용)에는 **언제나 있고**, 제안 메뉴에는
# **플래그가 켜졌을 때만** 오르게 나눈다. 이름표가 항상 있어야 하는 이유는 따로 있다: 그 행을
# 쓰는 순간 KeyError 로 죽는 사고가 2026-08-02 에 실제로 났다(gen_oracle_dataset.jl:118).
EXPERIMENTAL = {i: m["experimental"] for i, m in REGISTRY.items() if m.get("experimental")}


def is_active(i):
    """이 매크로를 지금 **제안해도 되는가**. 실험 팔은 자기 ENV 플래그가 켜졌을 때만."""
    flag = EXPERIMENTAL.get(i)
    return flag is None or os.environ.get(flag, "0") == "1"


ACTIVE_MACROS = [i for i in MACROS if is_active(i)]

# 사건 종류별로 전제조건상 말이 되는 팔. 상태를 아는 호출자(policy.jl)가 `valid` 를 실어 보내면
# 언제나 그쪽이 이긴다 -- 이 표는 상태를 모르는 호출자를 위한 폴백일 뿐이다.
# 실험 팔은 위 게이트가 꺼져 있으면 여기 안 오른다(= 폴백 메뉴가 예전과 같다).
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
