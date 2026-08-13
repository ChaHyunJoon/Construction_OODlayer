#!/usr/bin/env python3
"""목적함수 상수의 단일 진실원 감사 (spec §5.1). audit_action_vocab.py 와 같은 형식.

    .venv/bin/python audit_objective.py    # exit 0 = 전부 일치

리터럴 복붙은 에러 없이 성능으로만 새는 종류의 결함이다 — 그래서 기계로 검사한다.
(함정 29: MACRO_COST 가 4곳에 복붙돼 조용히 갈렸던 것과 같은 실패 모양.)
"""
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


# --- 1) objective.py 가 objective.json 을 읽는가 + 상수를 리터럴로 안 박았는가 -------------
src = read(HERE, "objective.py")
bad = []
"objective.json" in src or bad.append("objective.json 을 안 읽는다")
for lit in ("10000.0", "100.0"):
    # 주석/독스트링 밖에서 리터럴이 대입되는지만 본다.
    for line in src.splitlines():
        s = line.split("#", 1)[0]
        if re.search(r"=\s*%s\b" % re.escape(lit), s):
            bad.append("리터럴 %s 대입: %s" % (lit, line.strip()))
check("objective.py", bad)

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

# --- 4) e1_analyze.py 의 정렬키가 J 로 위임하는가 + 소비처 5곳이 전부 옮겨갔는가 --------------
# 한 곳이라도 옛 λ·MACRO_COST 의미로 남으면 그것이 spec §7 의 세대 혼입이다.
e1 = read(HERE, "e1_analyze.py")
bad = []
("import objective" in e1 or "from objective" in e1) or bad.append("objective 모듈을 안 쓴다")
"def cost_lex_key_row(" in e1 or bad.append("cost_lex_key_row(row) 가 없다 (spec §5.1)")
for fn in ("cost_lex_key", "cost_lex_key_row"):
    "MACRO_COST[" in func_body(e1, fn) and bad.append(
        "%s 가 아직 λ·MACRO_COST 를 쓴다 (spec §3.2 위반)" % fn)
"MACRO_COST" in e1 or bad.append("MACRO_COST 표가 사라졌다 — 특징량으로 남겨야 한다 (spec §3.2)")
# 소비처: 옛 이름을 **호출**하는 곳이 남아 있으면 안 된다(정의·deprecation 문구는 예외).
for f in ("verify.py", "ladder.py", "firegrid_report.py", "dspy_real_experiment.py"):
    for i, line in enumerate(read(HERE, f).splitlines(), 1):
        s = line.split("#", 1)[0]
        if re.search(r"\bcost_lex_key\s*\(", s):
            bad.append("%s:%d 가 아직 옛 cost_lex_key(...) 를 부른다 (spec §7)" % (f, i))
check("e1_analyze.py + 소비처 5곳", bad)

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

# --- 요약 --------------------------------------------------------------------------------
for where, bad in OK + FAIL:
    print(("OK        " if not bad else "MISMATCH  ") + where)
    for b in bad:
        print("            - " + b)
print("\n%d/%d consistent" % (len(OK), len(OK) + len(FAIL)))
print("objective_hash:", objective.objective_hash())
sys.exit(1 if FAIL else 0)
