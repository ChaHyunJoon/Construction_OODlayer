#!/usr/bin/env python
"""
primitive_registry.py -- `primitive_registry.json` 을 읽는 **유일한** 파이썬 로더.

왜 있는가 (2026-08-29, Plan B / T6a)
====================================
`features_agnostic.psi()` 의 리스트 경로가 `_PRIMITIVE_TABLE`(**DSL 원시 8종** --
ReplaceAgent · ForbidZone · SwapBattery …)만 알고 있었다. 그래서 이 레지스트리의
**운용 원시 19종**은 이름이 통째로 걸러지고 영벡터가 돌아왔다. 실측(spec
`2026-08-26-tool-synthesis-lane-design` §5-2-1 의 2026-08-29 정정):

    psi(['release_pending_assignments','deprioritize_agent'])  -> 10축 전부 0.0
    psi(['nonsense_operation_xyz'])                            -> 10축 전부 0.0
    psi(['release_pending_assignments']) == psi(['translate_whole_build'])  -> True

그 상태로 T2(tool 합성)를 켜면 spec §5-2-2 ②(ψ 근접 판정)가 **항진명제**가 된다 --
모든 합성 tool 이 서로 거리 0 이라 전부 "기존 것의 변형"으로 접힌다. 이 모듈은 그
알파벳에 ψ 축을 실어 주는 자리다.

조용한 폴백을 두지 않는다 (`action_registry.py` 와 같은 규약)
=============================================================
파일이 없거나, 축이 하나 빠졌거나, `a_reversible` 이 그 항목의 `reversible` 과 어긋나면
**import 시점에 큰 소리로 죽는다.** try/except 로 기본값을 채우면 "레지스트리를 배선했다고
믿고" 돌린 T2 측정이 사실은 반쪽 벡터로 돈 것이 되고, 그 사고는 정확히 이 파일이 고치려는
병(= 모르는 이름이 조용히 0 이 되는 것)의 재발이다.

경로 override 는 `PRIMITIVE_REGISTRY` 환경변수 -- `ACTION_REGISTRY` 와 같은 규약이고,
Julia 게이트 `test/primitive_registry_resolves.jl` 이 **이미 같은 이름을 쓴다.** 이유는
편의가 아니라 **변이시험**이다: 게이트가 실제로 빨개지는 것을 보려면 오염된 사본을
물려야 하는데, 배포되는 파일을 편집해서 재는 것 자체가 사고 경로다.

축 이름은 여기 리터럴로 적지 않는다
====================================
JSON 최상위의 `psi_axes` 가 순서까지 포함한 단일 진실원이고, 이 모듈은 그것을 읽어
**모든 항목이 정확히 그 축들만** 싣고 있는지 강제한다. `features_agnostic.PSI_AXES` 와의
일치는 그쪽에서 잰다(여기서 import 하면 순환한다 -- features_agnostic 이 이 모듈을 쓴다).

🔴 `a_n_specs` 는 여기 없다. 그것은 조합에서 `len(v)` 로 나오는 **파생축**이라 원시 하나의
표에 실으면 진실원이 둘이 된다.
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
REGISTRY_PATH = os.environ.get(
    "PRIMITIVE_REGISTRY", os.path.join(HERE, "primitive_registry.json"))


def load(path=None):
    """레지스트리 blob 을 그대로 돌려준다. 파일이 없거나 깨졌으면 죽는다."""
    p = path or REGISTRY_PATH
    with open(p, encoding="utf-8") as fh:
        return json.load(fh)


def _require(blob, key, path):
    if key not in blob:
        raise ValueError(
            "primitive_registry(%s): 최상위 키 %r 가 없다 -- 기본값으로 때우지 않는다. "
            "스키마가 갈렸거나 다른 파일을 물렸을 것이다." % (path, key))
    return blob[key]


def psi_axes(blob=None):
    """이 레지스트리가 싣는 ψ 축 이름 -- **순서까지** JSON 이 정한다."""
    b = blob if blob is not None else REGISTRY
    ax = _require(b, "psi_axes", REGISTRY_PATH)
    if not ax:
        raise ValueError("primitive_registry: psi_axes 가 비었다.")
    if len(set(ax)) != len(ax):
        raise ValueError("primitive_registry: psi_axes 에 중복 축이 있다: %r" % (ax,))
    if "a_n_specs" in ax:
        raise ValueError(
            "primitive_registry: psi_axes 에 'a_n_specs' 가 있다 -- 그것은 조합에서 len() 으로 "
            "나오는 파생축이다. 원시 표에 실으면 진실원이 둘이 된다.")
    return list(ax)


def psi_table(blob=None):
    """{원시 이름: {축: float}}. 축 집합이 어긋나는 항목이 하나라도 있으면 죽는다."""
    b = blob if blob is not None else REGISTRY
    ax = psi_axes(b)
    out = {}
    for p in _require(b, "primitives", REGISTRY_PATH):
        nm = p["name"]
        if nm in out:
            raise ValueError("primitive_registry: 원시 이름 %r 가 중복이다." % nm)
        if "psi" not in p:
            raise ValueError(
                "primitive_registry: 원시 %r 에 'psi' 블록이 없다 -- 조용히 0 으로 채우지 "
                "않는다. 0 으로 채우면 그 원시가 ψ 공간에서 NOOP 과 구분되지 않고, 그것이 "
                "이 파일이 고치려고 만들어진 바로 그 결함이다." % nm)
        got = list(p["psi"])
        if got != ax:
            raise ValueError(
                "primitive_registry: 원시 %r 의 psi 축이 psi_axes 와 다르다.\n"
                "  psi_axes : %r\n  이 항목  : %r\n"
                "빠진 축은 조용히 0 이 되므로 순서까지 정확히 일치해야 한다." % (nm, ax, got))
        out[nm] = {a: float(p["psi"][a]) for a in ax}
    if not out:
        raise ValueError("primitive_registry: 원시가 하나도 없다.")
    return out


def psi_tuples(order, blob=None):
    """{원시 이름: (값, ...)} -- `order` 가 지정한 축 순서로 편다.

    `features_agnostic` 의 `_PRIMITIVE_TABLE` 이 위치 튜플이라 그 열 순서에 맞춰야 하는데,
    그 순서를 여기 리터럴로 복붙하면 두 파일이 조용히 갈린다. 그래서 **호출자가 자기
    축 순서를 넘기고**, 이 함수가 집합이 같은지 먼저 확인한다.
    """
    tbl = psi_table(blob)
    order = list(order)
    ax = psi_axes(blob)
    if set(order) != set(ax):
        raise ValueError(
            "primitive_registry.psi_tuples: 요청한 축 집합이 레지스트리와 다르다.\n"
            "  요청: %r\n  레지스트리: %r" % (sorted(order), sorted(ax)))
    return {nm: tuple(v[a] for a in order) for nm, v in tbl.items()}


def predicate_names(blob=None):
    """순수 술어의 이름 집합. **ψ 가 없다** -- 아무것도 안 바꾸므로 효과 서술자가 없다.

    `psi()` 의 에러 메시지가 '오타' 와 '술어를 body 에 넣었다' 를 갈라 말하기 위해 쓴다.
    """
    b = blob if blob is not None else REGISTRY
    return {q["name"] for q in _require(b, "predicates", REGISTRY_PATH)}


def check_psi_consistency(blob=None):
    """ψ 축이 **같은 항목의 다른 필드**와 어긋나는 곳을 모아 돌려준다. 정상이면 빈 리스트.

    손으로 넣은 값의 오타를 잡는 자리다. 세 축만 기계로 유도 가능하다:

        a_reversible     == reversible                    (그 항목의 boolean 필드)
        a_consumes_spare == (consumes 가 비어 있지 않다)
        a_spatial        == (surface == "scene_tree")

    나머지 여섯 축(a_cost · a_intervenes · a_soft · a_restores_capacity ·
    a_relocates_work · a_scope)은 `mechanism` 산문에서 사람이 읽어 넣은 값이라 여기서
    검사할 짝이 없다 -- **이 함수가 초록이라고 표 전체가 옳은 것이 아니다.**

    반환: (원시 이름, 축, 레지스트리가 실은 값, 다른 필드에서 유도한 값) 목록.
    """
    b = blob if blob is not None else REGISTRY
    bad = []
    for p in _require(b, "primitives", REGISTRY_PATH):
        nm, psi = p["name"], p.get("psi")
        if not psi:
            bad.append((nm, "psi", None, "블록 자체가 없다"))
            continue
        rev = p["reversible"]
        if not isinstance(rev, bool):
            raise ValueError(
                "primitive_registry: 원시 %r 의 'reversible' 이 boolean 이 아니다(%r) -- "
                "강제변환하지 않는다." % (nm, rev))
        for axis, want in (("a_reversible", 1.0 if rev else 0.0),
                           ("a_consumes_spare", 1.0 if p["consumes"] else 0.0),
                           ("a_spatial", 1.0 if p["surface"] == "scene_tree" else 0.0)):
            if axis not in psi:
                bad.append((nm, axis, None, want))
            elif abs(float(psi[axis]) - want) > 1e-12:
                bad.append((nm, axis, float(psi[axis]), want))
    return bad


REGISTRY = load()
PSI_AXES = psi_axes(REGISTRY)
PSI_TABLE = psi_table(REGISTRY)
PRIMITIVE_NAMES = sorted(PSI_TABLE)
PREDICATE_NAMES = predicate_names(REGISTRY)

# 로드 시점에 집행한다 -- `features_agnostic` 의 `_psi_bad` 와 같은 규약. 이 줄이 있으면
# `a_reversible` 오타는 T2 를 돌리기 전에 `import primitive_registry` 에서 즉시 죽는다.
_bad = check_psi_consistency(REGISTRY)
if _bad:
    raise ValueError(
        "primitive_registry.json 의 psi 축이 같은 항목의 다른 필드와 어긋난다 -- "
        "조용히 넘기지 않는다.\n" +
        "\n".join("  %s.%s = %r 인데 %r 이어야 한다" % b for b in _bad))

# 술어 이름이 원시 이름과 겹치면 psi 의 에러 메시지가 거짓말을 한다("이건 술어다" vs 오타).
_clash = set(PRIMITIVE_NAMES) & PREDICATE_NAMES
if _clash:
    raise ValueError(
        "primitive_registry.json: 원시와 술어가 이름을 공유한다 %r -- "
        "어느 쪽인지가 조용한 결정이 된다." % sorted(_clash))
