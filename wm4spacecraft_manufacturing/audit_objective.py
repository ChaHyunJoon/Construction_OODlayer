#!/usr/bin/env python3
"""목적함수 상수의 단일 진실원 감사 (spec §5.1). audit_action_vocab.py 와 같은 형식.

    .venv/bin/python audit_objective.py    # exit 0 = 전부 일치

리터럴 복붙은 에러 없이 성능으로만 새는 종류의 결함이다 — 그래서 기계로 검사한다.
(함정 29: MACRO_COST 가 4곳에 복붙돼 조용히 갈렸던 것과 같은 실패 모양.)
"""
import glob
import io
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import objective  # noqa: E402

CFG = objective.load()
OK, FAIL = [], []


def check(where, bad):
    (FAIL if bad else OK).append((where, bad))


def read(*parts):
    with open(os.path.join(*parts), encoding="utf-8") as fh:
        return fh.read()


def func_body(src, name):
    """`def <name>(` 부터 다음 빈 줄까지 — 그 함수가 무엇을 쓰는지만 보면 되므로 이 정도면 충분."""
    m = re.search(r"def %s\(.*?\n(?:.*?\n)*?\n" % re.escape(name), src)
    return m.group(0) if m else ""


def code_lines(path):
    """문자열 리터럴과 주석을 지운 소스 줄. 독스트링에 옛 규칙을 **설명**해 둔 것까지 결함으로
    세면 감사가 자기 문서를 물어뜯는다 — 실제 코드만 본다."""
    import tokenize
    with open(path, "rb") as fh:
        src = fh.read().decode("utf-8")
    out = src.splitlines()
    try:
        toks = list(tokenize.generate_tokens(io.StringIO(src).readline))
    except (tokenize.TokenError, IndentationError, SyntaxError):
        return out
    for t in toks:
        if t.type not in (tokenize.STRING, tokenize.COMMENT):
            continue
        (r0, c0), (r1, c1) = t.start, t.end
        for r in range(r0, r1 + 1):
            line = out[r - 1]
            a = c0 if r == r0 else 0
            b = c1 if r == r1 else len(line)
            out[r - 1] = line[:a] + " " * (b - a) + line[b:]
    return out


# --- 1) 목적함수 상수를 리터럴로 대입하는 파일이 있는가 ---------------------------------------
# objective.py 만 보면 부족하다: 2026-08-13 리뷰에서 verify.py 가 같은 세 상수를
# (SSP_STALL_BASE/SSP_PER_UNCLOSED/SSP_MAKESPAN_W) 리터럴로 들고 있는 **네 번째 복사본**으로
# 발견됐다. 감사가 "consistent" 를 찍으면서 살아 있는 복제를 놓치면 없는 것만 못하다.
LITERAL_SCAN = ("objective.py", "verify.py", "e1_analyze.py", "ladder.py",
                "firegrid_report.py", "dspy_real_experiment.py", "build_md_report.py",
                "figures.py", "test_llm7h.py", "overnight_mdp.py", "export_surrogate.py",
                "cost_eval.py")
# C_fail / C_unclosed / tie_eps 를 적어 넣는 여러 표기. `=` 오른쪽의 **한 항 전체**가 이 중
# 하나면 대입으로 본다 — 그래서 `X = 100.0 * y` 같은 정상 산술은 걸리지 않고,
# **튜플 대입** `A, B, C = 10000.0, 100.0, 1.0e-3` 은 걸린다(2026-08-13 리뷰: 이 형태가
# 정규식의 사각지대였고 overnight_mdp.py 가 실제로 그 형태였다).
OBJ_LITERALS = {"10000.0", "100.0", "1e-3", "1.0e-3", "0.001", "1e-03"}
_ASSIGN_TAIL = ("=", "!", "<", ">", "+", "-", "*", "/", "%", "|", "&", "^")
# 이름이 목적함수 상수를 자처하면 값 하나만으로도 복사본이다. (100.0 같은 흔한 수가 다른 뜻으로
# 쓰이는 경우 — 예: export_surrogate.TIME_SCALE — 를 오검출하지 않으려면 이름을 봐야 한다.)
_OBJNAME = re.compile(r"(COST_FAIL|COST_UNCLOSED|COST_TIE|TIE_EPS|C_fail|C_unclosed|"
                      r"SSP_STALL|STALL_BASE|PER_UNCLOSED|SSP_MAKESPAN|UNCLOSED|PENALTY)", re.I)
bad = []
"objective.json" in read(HERE, "objective.py") or bad.append("objective.py 가 objective.json 을 안 읽는다")
for fname in LITERAL_SCAN:
    for i, line in enumerate(code_lines(os.path.join(HERE, fname)), 1):
        if line.lstrip().startswith(("def ", "class ")):
            continue          # 키워드 기본값(n=10000)은 모듈 상수가 아니다
        lhs, sep, rhs = line.partition("=")
        if not sep or lhs.rstrip().endswith(_ASSIGN_TAIL) or rhs.startswith("="):
            continue          # ==, <=, +=, ... 는 대입이 아니다
        hits = [p.strip() for p in rhs.split(",") if p.strip() in OBJ_LITERALS]
        # 하나라도 + 이름이 목적함수 상수를 자처하면 복사본. 두 개 이상이면 이름과 무관하게
        # **튜플 대입으로 세 상수를 한 줄에 박은 것**이므로 그 자체가 증거다.
        if hits and (len(hits) >= 2 or _OBJNAME.search(lhs)):
            bad.append("%s:%d 목적함수 상수를 리터럴로 대입: %s" % (fname, i, line.strip()[:88]))
check("목적함수 상수 리터럴 복붙 (%d 파일 스캔, 튜플 대입 포함)" % len(LITERAL_SCAN), bad)

# --- 2) objective.jl 도 같은 파일을 읽는가 -----------------------------------------------
jsrc = read(HERE, "objective.jl")
bad = []
"objective.json" in jsrc or bad.append("objective.json 을 안 읽는다")
check("objective.jl", bad)

# --- 3) gen_oracle_mc.jl 이 objective.jl 을 include 하고 리터럴을 안 쓰는가 -----------------
mc = read(HERE, "oracle", "gen_oracle_mc.jl")
bad = []
"objective.jl" in mc or bad.append("objective.jl 을 include 하지 않는다")
re.search(r'get\(ENV,\s*"MC_COST_FAIL",\s*"10000', mc) and bad.append(
    "COST_FAIL 을 아직 리터럴 기본값으로 파싱한다 (objective.json 이 출처여야 함)")
"objective_hash" in mc or bad.append("산출물에 objective_hash 를 기록하지 않는다 (spec §7)")
"Objective.J(" in mc or bad.append("scalar_cost 가 Objective.J 로 위임하지 않는다 (spec §3)")
check("oracle/gen_oracle_mc.jl", bad)

# --- 4) 채점 규칙이 한 곳에서만 정의되는가 (이름으로도, 형태로도) ------------------------------
# [2026-08-13 리뷰] "cost_lex_key 를 부르는 곳" 만 세면 부족하다 — 옛 **규칙**이 이름 없이
# 인라인 복붙돼 있던 곳이 5군데 더 있었다(build_md_report x2, test_llm7h x2, figures x1).
# 그중 build_md_report 는 발행 결과표를 만든다. 그래서 이제 이름이 아니라 **형태**를 찾는다:
# `lex_key(...)` 인자 안이나 스칼라 값 계산에 `MACRO_COST[...]` / `MACRO_COST.get(...)` 가
# λ 와 함께 나타나면 그것이 옛 규칙이다.
e1 = read(HERE, "e1_analyze.py")
bad = []
("import objective" in e1 or "from objective" in e1) or bad.append("objective 모듈을 안 쓴다")
"def cost_lex_key_row(" in e1 or bad.append("cost_lex_key_row(row) 가 없다 (spec §5.1)")
for fn in ("cost_lex_key", "cost_lex_key_row"):
    "MACRO_COST[" in func_body(e1, fn) and bad.append(
        "%s 가 아직 λ·MACRO_COST 를 쓴다 (spec §3.2 위반)" % fn)
"MACRO_COST" in e1 or bad.append("MACRO_COST 표가 사라졌다 — 특징량으로 남겨야 한다 (spec §3.2)")

_OLD_RULE = re.compile(r"MACRO_COST\s*[\[.]")            # MACRO_COST[..] / MACRO_COST.get(..)
_LAMBDA = re.compile(r"\b(LAM|lam|mu)\b\s*\*")           # λ 가 곱해진다
# 순위/선택을 만드는 형태. 이 안에 MACRO_COST 가 있으면 그것이 옛 채점 규칙의 복사본이다.
_RANKING = re.compile(r"\b(lex_key|cost_key|_key)\s*\(|\bkey\s*=|\bmax\s*\(|\bmin\s*\(|"
                      r"\bargmax\b|\bargsort\b|\bsorted\s*\(")
# 학습 타깃(`y = ...closed...`)은 **의도적 예외**다 — spec §8 단계 7 이 재학습으로 해소하고,
# 아래 항목 8 이 그 유예 표식을 따로 지킨다.
_TRAIN_TARGET = re.compile(r"^\s*y\s*=\s*.*closed")

INVENTORY = []   # 남아 있는 λ·MACRO_COST 스칼라 사용처 (실패가 아니라 가시성용 목록)


PY_FILES = sorted(os.path.basename(p) for p in glob.glob(os.path.join(HERE, "*.py")))
for fname in PY_FILES:
    if fname in ("audit_objective.py", "audit_action_vocab.py"):
        continue
    for i, line in enumerate(code_lines(os.path.join(HERE, fname)), 1):
        if re.search(r"(?<!def )\bcost_lex_key\s*\(", line) and "def cost_lex_key(" not in line:
            bad.append("%s:%d 가 아직 옛 cost_lex_key(...) 를 부른다 (spec §7)" % (fname, i))
        if re.search(r"def cost_key\s*\(", line):
            bad.append("%s:%d 에 `cost_key` — 옛 채점 규칙의 **두 번째 이름**이 다시 생겼다 (spec §7)"
                       % (fname, i))
        if not _OLD_RULE.search(line):
            continue
        if _TRAIN_TARGET.match(line):
            continue
        if _RANKING.search(line):
            bad.append("%s:%d 에서 순위/선택 식이 MACRO_COST 를 쓴다 = 옛 채점 규칙 복사본 "
                       "(spec §3.2/§7): %s" % (fname, i, line.strip()[:90]))
        elif _LAMBDA.search(line):
            INVENTORY.append("%s:%d  %s" % (fname, i, line.strip()[:88]))
check("채점 규칙 단일 정의 (wm4spacecraft_manufacturing/*.py 전수, 문자열/주석 제외)", bad)

# --- 5) Julia 플래너의 전역 κ 기본값이 objective.json 에서 오는가 (태스크 6 이 배선) ---------
etg = read(ROOT, "src", "essential_tg_coponents.jl")
bad = []
if "AUTO_EFFICIENCY_KAPPA" in etg:
    if "objective.json" not in etg and "objective_kappa" not in etg:
        bad.append("전역 κ 기본값이 objective.json 과 연결돼 있지 않다 (태스크 6 미완이면 예상됨)")
check("src/essential_tg_coponents.jl (전역 κ)", bad)

# --- 6) Julia 와 Python 의 해시가 일치하는가 ----------------------------------------------
probe = os.path.join(HERE, "_audit_objective_probe.jl")
bad = []
try:
    with open(probe, "w") as fh:
        fh.write('include(joinpath(@__DIR__, "objective.jl"))\nusing .Objective\n'
                 'println("HASH=", Objective.objective_hash())\n')
    out = subprocess.run(["julia", "+lts", "--project=" + ROOT, probe],
                         capture_output=True, text=True, timeout=600)
    jl_hash = next((l.split("=", 1)[1].strip() for l in out.stdout.splitlines()
                    if l.startswith("HASH=")), None)
    py_hash = objective.objective_hash()
    jl_hash == py_hash or bad.append("해시 불일치 julia=%s python=%s (stderr: %s)"
                                     % (jl_hash, py_hash, out.stderr[-300:]))
except Exception as e:
    bad.append("julia probe 실패: %r" % (e,))
finally:
    os.path.exists(probe) and os.remove(probe)
check("Julia/Python objective_hash", bad)

# --- 7) 스케일이 채워져 있는가 -------------------------------------------------------------
bad = [k for k in ("kappa", "M_ref", "E_ref", "T_scale", "Eg_scale") if CFG.get(k) is None]
check("objective.json 스케일 채움", ["null: %s" % ", ".join(bad)] if bad else [])

# --- 8) 학습 타깃 != 채점 목적함수 (spec §8 단계 7 로 유예) ------------------------------------
# 컨트롤러 재정: 재학습은 이 계획의 범위 밖이므로 **고치지 않는다**. 대신 조용히 잊히지 않도록
# 기계로 붙잡아 둔다 — 학습 타깃 줄이 유예 표식을 달고 있어야 통과한다. 코드가 옮겨가거나
# 표식이 지워지면 이 항목이 MISMATCH 로 바뀌어 다시 눈에 띈다(함정 29 의 실패 모양).
DEFER_MARK = "단계 7"
bad = []
for fname, pat in (("e1_analyze.py", r"y\s*=\s*df\.closed\.astype"),
                   ("ladder.py", r"y\s*=\s*df\.closed\.astype")):
    lines = read(HERE, fname).splitlines()
    hits = [i for i, l in enumerate(lines) if re.search(pat, l)]
    if not hits:
        bad.append("%s 에서 학습 타깃 줄을 못 찾았다 — 검사가 무력해졌다 (패턴을 갱신할 것)" % fname)
        continue
    for i in hits:
        window = "\n".join(lines[max(0, i - 8):i + 1])
        DEFER_MARK in window or bad.append(
            "%s:%d 학습 타깃에 '%s' 유예 표식이 없다 — 학습(closed-λ·MACRO_COST)과 "
            "채점(-J)의 불일치가 문서화되지 않은 채 남는다" % (fname, i + 1, DEFER_MARK))
check("학습 타깃 != 채점 J, 단계 7 로 유예 표시됨 (I-3, 고치지 않고 기록)", bad)

# --- 요약 --------------------------------------------------------------------------------
for where, bad in OK + FAIL:
    print(("OK        " if not bad else "MISMATCH  ") + where)
    for b in bad:
        print("            - " + b)
print("\n%d/%d consistent" % (len(OK), len(OK) + len(FAIL)))
print("objective_hash:", objective.objective_hash())
print("NOTE  학습 타깃은 아직 `closed - λ·MACRO_COST`, 채점은 -J 다 (알려진 불일치, "
      "spec §8 단계 7 재학습으로 해소). 위 항목 8 이 그 유예 표식을 지킨다.")
if INVENTORY:
    print("NOTE  순위 밖에 남아 있는 λ·MACRO_COST 사용처 %d곳 (특징량·학습 타깃·진단축 — 실패 아님, "
          "가시성용):" % len(INVENTORY))
    for line in INVENTORY:
        print("        " + line)
sys.exit(1 if FAIL else 0)
