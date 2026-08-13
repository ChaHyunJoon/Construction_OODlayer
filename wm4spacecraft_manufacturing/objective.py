#!/usr/bin/env python3
"""목적함수 J 의 단일 진실원 로더 (spec §3, §5).

    J(run) = complete ? makespan + w_E * energy_J
                      : C_fail + C_unclosed * (total - closed) + tie_eps * makespan
    w_E    = kappa * M_ref / E_ref

규칙(어겼을 때 조용히 새는 종류의 결함이므로 전부 에러로 만든다):
  - 스케일(M_ref/E_ref)이 null 인 채로 완주 런의 J 를 계산하면 ObjectiveError.
  - 완주 런인데 energy_J 가 없거나 유한하지 않으면 ObjectiveError.
  - 에너지 항은 완주 분기에만 들어간다 (spec §3.1).
  - λ·MACRO_COST 같은 개입비용은 J 에 들어가지 않는다 (spec §3.2).

ENV 우선순위: MC_COST_FAIL / MC_COST_UNCLOSED 가 설정돼 있으면 ENV 가 이기고,
그 사실이 objective_hash() 에 반영돼 산출물이 **다른 세대**로 갈린다 (spec §5, §7).
"""
import hashlib
import json
import math
import os

_HERE = os.path.dirname(os.path.abspath(__file__))
OBJECTIVE_PATH = os.path.join(_HERE, "objective.json")

# ENV 로 덮어쓸 수 있는 키와 그 ENV 이름. gen_oracle_mc.jl:142-143 의 현행 경로를 그대로 유지한다.
ENV_OVERRIDES = {"C_fail": "MC_COST_FAIL", "C_unclosed": "MC_COST_UNCLOSED"}

# 스케일 상수 — null 이면 J 의 완주 분기를 계산할 수 없다.
SCALE_KEYS = ("kappa", "M_ref", "E_ref")

# 미완주 분기가 쓰는 상수 — null 이면 그 분기를 계산할 수 없다 (M-5: TypeError 로 새지 않게).
INCOMPLETE_KEYS = ("C_fail", "C_unclosed", "tie_eps")

# objective_hash() 가 실제로 해싱하는 J-정의 스칼라 8개, 정렬된 순서.
# (컨트롤러 재정) _doc/calibrated_from 는 문서·출처일 뿐 J 의 파라미터가 아니므로 뺀다 —
# 그래야 오타 수정으로 이전 세대 산출물이 전부 무효화되는 일이 없다 (spec §7).
_HASH_SCALAR_KEYS = (
    "C_fail", "C_unclosed", "E_ref", "Eg_scale", "M_ref", "T_scale", "kappa", "tie_eps",
)

# 문자열로 해싱하는 키 (숫자 포맷을 거치지 않고 **원문 그대로**).
#
# 왜 필요한가 (2026-08-13 컨트롤러 재정): 스칼라만 해싱하면 **목적함수의 유효 의미가 바뀌었는데
# 스칼라는 그대로인 변경**을 해시가 표현하지 못한다. 실제로 그런 일이 났다 — 태스크 6 이 κ 를
# DeprioritizeAgent 국소 스코프에서 전역 기본값으로 승격하면서 오라클 fault 재풀이
# (release_pending_assignments! → verifier/커밋 풀이)가 이전 라벨과 **다른 목적함수**를
# 최적화하게 됐는데, objective.json 의 스칼라는 하나도 안 바뀌어 해시가 동일했다.
# spec §7 은 "해시가 다르면 다른 세대"라는 기계적 판정을 약속하는데, 그 판정이 이 단절을
# 볼 수 없었다. `generation` 은 그 판정을 사람이 선언하고 기계가 검사하는 형태로 만든다.
#
# 규칙: **목적함수의 유효 의미가 바뀌면 스칼라가 그대로여도 bump 한다.** 플래너 재배선 포함.
_HASH_STRING_KEYS = ("generation",)

# 실제 해싱 순서 = 스칼라 + 문자열 키를 합쳐 한 번 정렬한 것.
# ASCII 정렬이라 대문자 키가 먼저 온다: C_fail, C_unclosed, E_ref, Eg_scale, M_ref, T_scale,
# generation, kappa, tie_eps. Julia 쪽도 같은 코드포인트 정렬이라 순서가 일치한다.
_HASH_KEYS = tuple(sorted(_HASH_SCALAR_KEYS + _HASH_STRING_KEYS))


class ObjectiveError(RuntimeError):
    """목적함수 설정이 불완전하거나 입력이 J 를 정의하지 못할 때."""


_CACHE = None


def load(path=None, refresh=False):
    """objective.json 을 읽고 ENV 덮어쓰기를 적용한 **유효 설정**을 돌려준다."""
    global _CACHE
    if _CACHE is not None and not refresh and path is None:
        return _CACHE
    p = path or OBJECTIVE_PATH
    if not os.path.exists(p):
        raise ObjectiveError("objective.json 이 없다: %s" % p)
    with open(p) as fh:
        cfg = json.load(fh)
    cfg.pop("_doc", None)
    # `generation` 은 해시에 **문자열 그대로** 들어간다. 문자열이 아니면 두 언어의 표기가
    # 갈릴 수 있다 — 특히 JSON 불리언은 Python 이 "True", Julia 가 "true" 를 내서 해시가
    # 조용히 달라진다(이미 닫은 -0.0 발산과 같은 부류). 타입을 여기서 못 박아 원천 봉쇄한다.
    if "generation" in cfg and not isinstance(cfg["generation"], str):
        raise ObjectiveError(
            "objective.json 의 generation 은 문자열이어야 한다 (해시에 원문 그대로 들어가므로 "
            "Python/Julia 표기가 갈릴 수 있다): %r" % (cfg["generation"],))
    cfg["_env_overrides"] = {}
    for key, env_name in ENV_OVERRIDES.items():
        raw = os.environ.get(env_name)
        if raw is None:
            continue
        cfg[key] = float(raw)
        cfg["_env_overrides"][env_name] = raw
    if path is None:
        _CACHE = cfg
    return cfg


def _fmt_hash_value(v):
    """해시용 값 포맷. null 은 문자 그대로 'null'.

    NaN/Inf 는 소문자 'nan'/'inf'/'-inf' 로 고정한다 — Python 의 "%.17g" 는 이미 소문자를
    내지만 Julia 의 @sprintf("%.17g", ...) 는 'NaN'/'Inf' (대문자)를 낸다. 맞추지 않으면
    (예: MC_COST_FAIL=inf) 두 언어의 해시가 갈린다.

    -0.0 은 0.0 으로 정규화한다 — JSON3(Julia) 는 정수값 float 를 Int64 로 낮춰 읽어 -0.0 을
    부호 없는 0 으로 지워버리지만 Python 의 json 모듈은 부호를 보존한다. 정규화하지 않으면
    objective.json 에 우연히 -0.0 이 들어가는 것만으로 두 언어의 해시가 갈린다.

    그 외에는 %.17g (C printf 의미, Python·Julia 모두 이 규약을 따르므로 바이트가 일치한다)."""
    if v is None:
        return "null"
    f = float(v)
    if math.isnan(f):
        return "nan"
    if math.isinf(f):
        return "inf" if f > 0 else "-inf"
    if f == 0.0:
        f = 0.0  # normalize -0.0 -> +0.0
    return "%.17g" % f


def _fmt_hash_entry(key, v):
    """키 하나의 해시 표기. 문자열 키는 원문 그대로, 그 외는 %.17g 숫자 규약."""
    if key in _HASH_STRING_KEYS:
        return "null" if v is None else str(v)
    return _fmt_hash_value(v)


def objective_hash(cfg=None):
    """유효 설정의 sha256(앞 16자).

    해시 대상: J 를 정의하는 8개 스칼라(C_fail, C_unclosed, E_ref, Eg_scale, M_ref,
    T_scale, kappa, tie_eps) **+ 세대 딱지 `generation`**(문자열, 원문 그대로) 를
    합쳐 한 번 정렬한 순서로, 그리고 실제로 적용된 ENV 덮어쓰기(ENV 변수명 정렬순,
    원본 문자열 그대로)를 "key=value" 줄로 나열해 "\\n" 로 join 하고 끝에 "\\n" 을
    붙인 뒤 UTF-8 로 sha256 한다.

    `_doc`/`calibrated_from` 은 문서·출처일 뿐 J 의 파라미터가 아니므로 제외한다 —
    두 파일이 파라미터는 같고 출처만 다르면 같은 목적함수이므로 같은 해시를 내야 한다
    (§7 의 "해시가 다르면 다른 세대" 규약이 문서 오타 수정으로 허투루 깨지지 않게).

    `generation` 은 그 반대쪽 구멍을 막는다: **스칼라가 그대로인데 유효 의미가 바뀐**
    변경(플래너 재배선 등)을 해시가 볼 수 있게 한다. 그런 변경을 했으면 반드시 bump 할 것.

    Python 과 Julia 는 이 텍스트 규약을 그대로 공유한다(JSON 직렬화 바이트 매칭에
    기대지 않는다) — 그래서 두 언어가 항상 같은 해시를 낸다.
    """
    cfg = cfg if cfg is not None else load()
    lines = []
    for key in _HASH_KEYS:
        lines.append("%s=%s" % (key, _fmt_hash_entry(key, cfg.get(key))))
    overrides = cfg.get("_env_overrides", {})
    for env_name in sorted(overrides):
        lines.append("ENV:%s=%s" % (env_name, overrides[env_name]))
    blob = ("\n".join(lines) + "\n").encode("utf-8")
    return hashlib.sha256(blob).hexdigest()[:16]


def energy_weight(cfg=None):
    """w_E = kappa * M_ref / E_ref. 스케일이 없으면 에러 — 0 으로 폴백하지 않는다."""
    cfg = cfg if cfg is not None else load()
    missing = [k for k in SCALE_KEYS if cfg.get(k) is None]
    if missing:
        raise ObjectiveError(
            "objective.json 의 %s 가 null 이다 — 파일럿 측정(measure_objective_scales.py) 없이는 "
            "완주 런의 J 를 계산할 수 없다. 0 이나 1 로 폴백하지 않는다 (spec §5)." % ", ".join(missing))
    e_ref = float(cfg["E_ref"])
    if not (math.isfinite(e_ref) and e_ref > 0):
        raise ObjectiveError("E_ref 가 양의 유한값이 아니다: %r" % cfg["E_ref"])
    return float(cfg["kappa"]) * float(cfg["M_ref"]) / e_ref


def J(*, complete, closed, total, makespan, energy_J=None, cfg=None):
    """실현된 런 하나의 목적함수 값 (작을수록 좋다)."""
    cfg = cfg if cfg is not None else load()
    ms = float(makespan) if makespan is not None else float("nan")

    if not complete:
        # 미완주 분기: gen_oracle_mc.jl:146 의 scalar_cost 를 그대로 물려받는다.
        # **에너지는 들어가지 않는다** — 일찍 죽는 것이 이득이 되면 안 된다 (spec §3.1).
        missing = [k for k in INCOMPLETE_KEYS if cfg.get(k) is None]
        if missing:
            raise ObjectiveError(
                "objective.json 의 %s 가 null 이다 — 미완주 분기의 J 를 계산할 수 없다. "
                "0/1 로 조용히 폴백하지 않는다 (spec §5)." % ", ".join(missing))
        # (total - closed) 를 0 밑으로 클램프한다 (I-1). 이 하니스에서 complete==true 인데도
        # closed < total 인 장부 노드가 있을 수 있다는 건 CLAUDE.md(§6 완주 ≠ closed==total)에
        # 이미 문서화돼 있고, 그 역(記帳 드리프트로 closed > total)도 배제할 근거가 없다.
        # 클램프가 없으면 (total-closed) 가 음수가 돼 미완주 J 가 0 이하로 떨어질 수 있고,
        # 그러면 "기록 오류로 닫힌 노드 수가 total 을 넘은 미완주 런"이 세상에서 가장 좋은
        # 결과로 둔갑한다 — 실패가 전역 최적이 되는 것은 spec §3.1 이 막으려는 바로 그 결함이다.
        return (float(cfg["C_fail"])
                + float(cfg["C_unclosed"]) * max(0, int(total) - int(closed))
                + float(cfg["tie_eps"]) * (ms if math.isfinite(ms) else 0.0))

    if not math.isfinite(ms):
        raise ObjectiveError("완주 런인데 makespan 이 유한하지 않다: %r" % makespan)
    if energy_J is None or not math.isfinite(float(energy_J)):
        raise ObjectiveError(
            "완주 런인데 energy_J 가 없다/유한하지 않다: %r — 구세대 덤프이거나 배터리 레이어가 "
            "꺼진 런이다. J 는 이를 조용히 0 으로 두지 않는다 (spec §5)." % (energy_J,))
    return ms + energy_weight(cfg) * float(energy_J)


def J_row(row, cfg=None):
    """JSONL 행 하나에서 J 를 뽑는다. 4pol 레인(battery 하위)과 MC 레인(최상위) 둘 다 읽는다.

    complete/closed/total 은 J 를 정의하는 필수 필드라 행에 없으면(스키마 드리프트)
    ObjectiveError — 예전처럼 (False/0/0) 으로 조용히 채우면, 스키마가 깨진 덤프를 배치
    채점할 때 "그럴듯한 10000.x" 값이 나와 진짜 실패와 구분이 안 된다(I-2). 이 모듈 전체의
    전제가 "조용한 폴백 금지"(spec §5)인데 그 전제를 배신하는 구멍이었다.
    makespan/energy_J 는 4pol/MC 두 레인의 키 이름이 달라 폴백이 필요하므로(스키마 드리프트가
    아니라 알려진 두 스키마 사이의 정상적인 차이) 그대로 둔다."""
    missing = [k for k in ("complete", "closed", "total") if k not in row]
    if missing:
        raise ObjectiveError(
            "JSONL 행에 %s 가 없다 — 스키마 드리프트다. False/0/0 으로 조용히 채우지 않는다 "
            "(spec §5)." % ", ".join(missing))
    energy = row.get("energy_J")
    if energy is None:
        energy = (row.get("battery") or {}).get("total_energy_J")
    makespan = row.get("makespan")
    if makespan is None:
        makespan = row.get("sim_seconds")
    return J(complete=bool(row["complete"]), closed=int(row["closed"]), total=int(row["total"]),
             makespan=makespan, energy_J=energy, cfg=cfg)


if __name__ == "__main__":
    c = load()
    print(json.dumps({k: v for k, v in c.items() if not k.startswith("_")},
                     ensure_ascii=False, indent=2))
    print("env_overrides:", c.get("_env_overrides"))
    print("objective_hash:", objective_hash(c))
    try:
        print("w_E:", energy_weight(c))
    except ObjectiveError as e:
        print("w_E: <unavailable>", e)
