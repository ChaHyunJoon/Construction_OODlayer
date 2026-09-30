"""S0 정적 검사 · arm.json 빌더 · T_null (spec §8, §9.1, §0.0 R3·R7).

S0 는 **하드 거부**(금지 토큰, calls 인자가 JSON 리터럴이 아님)와 **소프트 플래그**(검토 묶음 표시)만
낸다. 행동 키 중복은 하드 거부가 아니다(R7 — 같은 키는 교체 후보). 규약 검사(최상위 함수 하나,
위치 인자 env 뿐, 키워드 기본값)는 S1 등록에서 Julia `check_impl_conventions` 가 그대로 한다."""
import copy, hashlib, re
from . import harvest, library

NULL_NAME = "selfimprove_null_arm!"

_ID = r"(?<![\w!])"
FORBIDDEN = {"eval(": _ID + r"eval\(", "@eval": r"@eval\b", "Core.eval": r"Core\.eval\b",
             "include(": _ID + r"include\(", "ENV[": _ID + r"ENV\[", "ccall": _ID + r"ccall\b",
             "run(": _ID + r"run\(", "open(": _ID + r"open\(", "rm(": _ID + r"rm\(",
             "write(": _ID + r"write\(", "global ": r"(?<![\w!])global\s"}


def _literal(v):
    return v is None or isinstance(v, (bool, int, float, str))


def s0(row, names):
    code = row["impl_code"]
    hard = ["forbidden_token:" + t for t, rx in FORBIDDEN.items() if re.search(rx, code)]
    for i, c in enumerate(row.get("calls") or []):
        for k, v in (c.get("args") or {}).items():
            if not _literal(v):
                hard.append("non_literal_arg:%d:%s" % (i, k))
    soft = []
    if re.search(r"\bcatch\b", code) and "rethrow" not in code:
        soft.append("catch_without_rethrow")
    if re.search(r"\bwhile\s+true\b", code):
        soft.append("while_true")
    nums = [float(x) for x in re.findall(r"(?<![\w.])(\d+\.\d*|\d*\.\d+|\d+)(?:[eE][+-]?\d+)?(?![\w])", code)]
    if any(abs(x) >= 1 for x in nums):
        soft.append("numeric_literal_ge_1")
    return {"ok": not hard, "hard": hard, "soft": soft,
            "behavior_key": harvest.behavior_key(code, "zone", names)}


def _rename_def(code, old, new):
    pat = re.compile(r"function\s+" + re.escape(old) + r"\(")
    m = pat.search(code)
    if m is None:
        raise ValueError("no `function %s(` in impl_code" % old)
    return code[:m.start()] + "function " + new + "(" + code[m.end():]


def rename(row, new_name):
    """정의 이름 · impl_name · body_names · calls[i].primitive 를 **함께** 바꾼다. 그 밖의 바이트는 그대로."""
    a = harvest.arm_like(row)
    old = a["impl_name"]
    out = copy.deepcopy(a)
    out["impl_code"] = _rename_def(a["impl_code"], old, new_name)
    out["impl_name"] = new_name
    out["body_names"] = [new_name if n == old else n for n in a["body_names"]]
    out["calls"] = [dict(c, primitive=new_name if c.get("primitive") == old else c.get("primitive"))
                    for c in a["calls"]]
    return out


def arm_json(row, arm_id, role, reg_name):
    a = rename(row, reg_name)
    a.update(arm_id=int(arm_id), role=role, source_impl_name=row["impl_name"],
             source_impl_code_sha256=hashlib.sha256(row["impl_code"].encode()).hexdigest(),
             source_record_id=row.get("record_id"))
    a["artifact_sha256"] = library.artifact_hash(a)
    return a


def rename_is_only_change(arm):
    back = _rename_def(arm["impl_code"], arm["impl_name"], arm["source_impl_name"])
    return hashlib.sha256(back.encode()).hexdigest() == arm["source_impl_code_sha256"]


def kw_signature(impl_code, name):
    """`function <name>(env; …)` 의 `;` 뒤부터 짝 맞는 `)` 앞까지 (괄호 깊이·문자열 리터럴 추적)."""
    m = re.search(r"function\s+" + re.escape(name) + r"\(", impl_code)
    if m is None:
        raise ValueError("no `function %s(`" % name)
    i, depth, semi, s = m.end(), 1, None, impl_code
    while i < len(s):
        ch = s[i]
        if ch in "\"'":
            j = i + 1
            while j < len(s) and s[j] != ch:
                j += 2 if s[j] == "\\" else 1
            i = j + 1
            continue
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                return "" if semi is None else s[semi + 1:i].strip()
        elif ch == ";" and depth == 1 and semi is None:
            semi = i
        i += 1
    raise ValueError("unbalanced signature for %s" % name)


def null_arm(arm):
    """T 와 같은 집행 경로·surface·키워드(기본값 포함)를 쓰되 아무것도 안 하는 대조 팔 (R3)."""
    kw = kw_signature(arm["impl_code"], arm["impl_name"])
    sig = "env; %s" % kw if kw.strip() else "env"
    code = "function %s(%s)\n    return nothing\nend\n" % (NULL_NAME, sig)
    out = dict(arm, role="null", impl_code=code, impl_name=NULL_NAME,
               body_names=[NULL_NAME for _ in arm["body_names"]],
               calls=[dict(c, primitive=NULL_NAME) for c in arm["calls"]])
    out["artifact_sha256"] = library.artifact_hash(out)
    return out
