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

# objective_hash() 가 실제로 해싱하는 J-정의 스칼라 8개, 정렬된 순서.
# (컨트롤러 재정) _doc/calibrated_from 는 문서·출처일 뿐 J 의 파라미터가 아니므로 뺀다 —
# 그래야 오타 수정으로 이전 세대 산출물이 전부 무효화되는 일이 없다 (spec §7).
_HASH_SCALAR_KEYS = (
    "C_fail", "C_unclosed", "E_ref", "Eg_scale", "M_ref", "T_scale", "kappa", "tie_eps",
)


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
    """해시용 값 포맷. null 은 문자 그대로 'null', 그 외에는 %.17g (C printf, Julia 와 동일)."""
    if v is None:
        return "null"
    return "%.17g" % float(v)


def objective_hash(cfg=None):
    """유효 설정의 sha256(앞 16자).

    해시 대상: J 를 정의하는 8개 스칼라(C_fail, C_unclosed, E_ref, Eg_scale, M_ref,
    T_scale, kappa, tie_eps, 정렬된 순서)와 실제로 적용된 ENV 덮어쓰기(ENV 변수명
    정렬순, 원본 문자열 그대로)만 "key=value" 줄로 나열해 "\\n" 로 join 하고 끝에
    "\\n" 을 붙인 뒤 UTF-8 로 sha256 한다. `_doc`/`calibrated_from` 은 문서·출처일 뿐
    J 의 파라미터가 아니므로 제외한다 — 두 파일이 파라미터는 같고 출처만 다르면 같은
    목적함수이므로 같은 해시를 내야 한다 (§7 의 "해시가 다르면 다른 세대" 규약이
    문서 오타 수정으로 허투루 깨지지 않게).

    Python 과 Julia 는 이 텍스트 규약을 그대로 공유한다(JSON 직렬화 바이트 매칭에
    기대지 않는다) — 그래서 두 언어가 항상 같은 해시를 낸다.
    """
    cfg = cfg if cfg is not None else load()
    lines = []
    for key in sorted(_HASH_SCALAR_KEYS):
        lines.append("%s=%s" % (key, _fmt_hash_value(cfg.get(key))))
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
        return (float(cfg["C_fail"])
                + float(cfg["C_unclosed"]) * (int(total) - int(closed))
                + float(cfg["tie_eps"]) * (ms if math.isfinite(ms) else 0.0))

    if not math.isfinite(ms):
        raise ObjectiveError("완주 런인데 makespan 이 유한하지 않다: %r" % makespan)
    if energy_J is None or not math.isfinite(float(energy_J)):
        raise ObjectiveError(
            "완주 런인데 energy_J 가 없다/유한하지 않다: %r — 구세대 덤프이거나 배터리 레이어가 "
            "꺼진 런이다. J 는 이를 조용히 0 으로 두지 않는다 (spec §5)." % (energy_J,))
    return ms + energy_weight(cfg) * float(energy_J)


def J_row(row, cfg=None):
    """JSONL 행 하나에서 J 를 뽑는다. 4pol 레인(battery 하위)과 MC 레인(최상위) 둘 다 읽는다."""
    energy = row.get("energy_J")
    if energy is None:
        energy = (row.get("battery") or {}).get("total_energy_J")
    makespan = row.get("makespan")
    if makespan is None:
        makespan = row.get("sim_seconds")
    return J(complete=bool(row.get("complete")), closed=int(row.get("closed") or 0),
             total=int(row.get("total") or 0), makespan=makespan, energy_J=energy, cfg=cfg)


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
