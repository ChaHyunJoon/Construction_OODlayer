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

# --- 3) 세대 딱지를 찍는 산출 레인 3곳 -------------------------------------------------------
# [2026-08-13 최종 리뷰 C-1] 원래 이 항목은 gen_oracle_mc.jl 만 봤다. 그래서 **두 번째 라벨
# 생산기**인 gen_oracle_dataset.jl(= 배포 학습셋 n44_plus78.jsonl 을 만드는 파일, spec §5.1 이
# 이름으로 지목한 소비처)이 배선되지 않은 채 다른 플래너 목적함수로 라벨을 만들고 있는 것을
# 감사가 구조적으로 볼 수 없었다. 이제 세 레인(MC 라벨러 · 데이터셋 라벨러 · 4pol 데모)을
# 전부 본다 — 산출 레인이 하나 더 생기면 여기 추가할 것.
mc = read(HERE, "oracle", "gen_oracle_mc.jl")
bad = []
"objective.jl" in mc or bad.append("gen_oracle_mc.jl: objective.jl 을 include 하지 않는다")
re.search(r'get\(ENV,\s*"MC_COST_FAIL",\s*"10000', mc) and bad.append(
    "gen_oracle_mc.jl: COST_FAIL 을 아직 리터럴 기본값으로 파싱한다 (objective.json 이 출처여야 함)")
"objective_hash" in mc or bad.append("gen_oracle_mc.jl: 산출물에 objective_hash 를 기록하지 않는다 (spec §7)")
"Objective.J(" in mc or bad.append("gen_oracle_mc.jl: scalar_cost 가 Objective.J 로 위임하지 않는다 (spec §3)")

ds = read(HERE, "oracle", "gen_oracle_dataset.jl")
"objective.jl" in ds or bad.append("gen_oracle_dataset.jl: objective.jl 을 include 하지 않는다 (spec §5.1)")
"init_objective_weights!" in ds or bad.append(
    "gen_oracle_dataset.jl: init_objective_weights! 를 부르지 않는다 — 이 라벨러의 재풀이가 "
    "gen_oracle_mc.jl 과 **다른 플래너 목적함수**로 돈다 (spec §4/§6.3)")

# 3-b) **개수로** 센다, 부분문자열로 세지 않는다 (F-4).
#   부분문자열 검사("energy_J 가 한 번이라도 나오는가")는 C-1 을 다시 통과시킨다: emit 사이트가
#   네 번째로 하나 더 생기면서 옛 패턴만 복사해도 앞의 세 곳에 energy_J 가 있으니 초록이 된다.
#   그게 정확히 C-1 이 생긴 방식이다(복사된 emit 블록).
#   라벨 emit 사이트의 정의: 행 리터럴 안에서 `"total_energy_J" =>` 를 내는 자리. 이 파일에서
#   그 표기는 emit 사이트에서만 쓰인다(값 생산부는 named tuple 필드라 `=>` 가 없다). 그 개수를
#   기준선으로 삼아, 세대·에너지 키가 **같은 수만큼** 있는지 본다.
#   `"energy_J" =>` 는 앞의 큰따옴표 때문에 `"total_energy_J" =>` 에 절대 매칭되지 않는다.
_n = lambda pat, src: len(re.findall(pat, src))
n_emit = _n(r'"total_energy_J"\s*=>', ds)
if n_emit == 0:
    bad.append("gen_oracle_dataset.jl: 라벨 emit 사이트를 하나도 못 찾았다 "
               "(`\"total_energy_J\" =>` 기준) — 이 검사가 무력해졌다. 패턴을 갱신할 것")
else:
    for key, why in (("energy_J",
                      "objective.J_row 가 읽는 이름이다 (total_energy_J 만 내면 J 가 "
                      "'구세대 덤프'라는 틀린 진단으로 멈춘다)"),
                     ("energy_objective",
                      "ENERGY_OBJECTIVE 는 objective_hash 를 안 바꾸므로 이 필드가 없으면 "
                      "에너지 항을 끈 런이 신세대 행으로 위장한다 (F-1)")):
        got = _n(r'"%s"\s*=>' % key, ds)
        got == n_emit or bad.append(
            "gen_oracle_dataset.jl: 라벨 emit 사이트는 %d 곳인데 `\"%s\" =>` 는 %d 곳뿐이다 — "
            "%s" % (n_emit, key, got, why))
# objective_hash 는 라벨 행 + probe 행에도 붙으므로 emit 수 **이상**이면 된다.
_n(r'"objective_hash"\s*=>', ds) >= n_emit or bad.append(
    "gen_oracle_dataset.jl: 라벨 emit 사이트(%d)보다 objective_hash 각인이 적다 (spec §7)" % n_emit)

# 3-c) 4pol 레인도 세대 딱지를 찍는가 (최종 리뷰 I-1 이 배선한 자리).
rd = read(ROOT, "tools", "monitor", "run_demo.jl")
for key in ("objective_hash", "energy_objective"):
    re.search(r'"%s"\s*=>' % key, rd) or bad.append(
        "tools/monitor/run_demo.jl: DEMO_SUMMARY 레코드에 %s 를 안 찍는다 — 630판 스윕이 "
        "헤드라인 숫자를 내는 레인이다 (spec §7)" % key)
# MC 레인의 CSV 열도 같이 못 박는다(헤더 문자열이 곧 계약이다).
"energy_objective" in mc or bad.append(
    "gen_oracle_mc.jl: CSV 에 energy_objective 열이 없다 (F-1)")
check("세대 딱지 산출 레인 3곳 (gen_oracle_mc.jl / gen_oracle_dataset.jl / tools/monitor/run_demo.jl)",
      bad)

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

# --- 9) 문서에 박힌 해시 **와 계약 개수**가 안 곪았는가 (spec §7-2, 태스크7 리뷰 R-5 + 최종 I-2) --
# `generation` 필드가 바뀌면 objective_hash() 도 바뀐다. CLAUDE.md 와 🔴 배너는 그 해시값을
# 사람이 읽는 산문에 **문자열로** 박아 둔다(``59b1174118b874ed`` 같은 형태) — 이건 objective.json
# 을 다시 읽지 않으므로, 다음번 generation bump 가 조용히 이 문서들을 거짓으로 만들 수 있다.
# 기계 검사로 잡는다: 지금 사는 해시와 문서에 박힌 해시가 다르면 실패.
HASH_DOCS = (
    ("CLAUDE.md", os.path.join(ROOT, ".claude", "CLAUDE.md")),
    ("RESULTS_D20_2026-08-12.md", os.path.join(HERE, "md", "RESULTS_D20_2026-08-12.md")),
)
_HASH_RE = re.compile(r"`([0-9a-f]{16})`")
current_hash = objective.objective_hash()
bad = []
for label, path in HASH_DOCS:
    if not os.path.exists(path):
        bad.append("%s 를 못 찾았다(%s) — 검사가 무력해졌다" % (label, path))
        continue
    quoted = set(_HASH_RE.findall(read(path)))
    if not quoted:
        bad.append("%s 에 16자 hex objective_hash 인용이 하나도 없다 — "
                    "세대 판정 계약이 문서에서 빠졌다" % label)
        continue
    stale = quoted - {current_hash}
    if stale:
        bad.append("%s 가 옛 해시를 인용한다(%s, 현재=%s) — generation bump 후 문서 갱신 누락"
                   % (label, ", ".join(sorted(stale)), current_hash))

# 계약 **개수**도 같이 못 박는다 (2026-08-13 최종 I-2). 해시는 이미 검사되고 있었는데 실제로
# 곪은 것은 개수였다: 이 검사(9번)가 추가되면서 8/8 → 9/9 가 됐는데 CLAUDE.md 두 곳이 계속
# `audit_objective.py`(8/8) 이라고 광고했고, 아무도 그걸 보지 않았다. 개수는 검사를 하나
# 더할 때마다 반드시 낡으므로 정확히 이 검사가 지켜야 할 대상이다.
# n_checks: 지금까지 등록된 것 + **아직 등록 안 된 이 검사 자신** 1개.
n_checks = len(OK) + len(FAIL) + 1
_COUNT_RE = re.compile(r"audit_objective\.py`?\s*\(\s*(\d+)\s*/\s*(\d+)\s*\)")
_COUNT_REQUIRED = {"CLAUDE.md"}    # 여기엔 반드시 개수 문자열이 있어야 한다(없으면 검사가 무력)
for label, path in HASH_DOCS:
    if not os.path.exists(path):
        continue               # 위에서 이미 보고했다
    found = _COUNT_RE.findall(read(path))
    if not found and label in _COUNT_REQUIRED:
        bad.append("%s 에 `audit_objective.py`(N/N) 형태의 계약 개수 문자열이 없다 — "
                   "개수 검사가 무력해졌다 (현재 %d/%d)" % (label, n_checks, n_checks))
        continue
    for a, b in found:
        if (int(a), int(b)) != (n_checks, n_checks):
            bad.append("%s 가 audit_objective.py(%s/%s) 라고 적었는데 실제는 %d/%d 다 — "
                       "검사를 추가/삭제한 뒤 문서 갱신 누락" % (label, a, b, n_checks, n_checks))
check("문서의 objective_hash 인용 + audit 계약 개수(%d/%d)가 최신인가 (R-5, I-2)"
      % (n_checks, n_checks), bad)

# --- 9-b) **커밋된 라벨 파일**의 objective_hash — 경고만, 실패로 세지 않는다 -------------------
# 왜 항목 9 에 붙였나: 항목 9 는 "지금 사는 해시와 **기록에 박힌** 해시가 갈렸는가" 를 보는
# 검사다. 문서만 보고 라벨 파일을 안 보는 것은 같은 결함의 절반만 보는 것이다 — 라벨 행의
# `objective_hash` 는 그 행이 **어느 목적함수로 채점됐는지**를 말하는 세대 딱지이고, 현재
# objective.json 이 그 해시를 못 내면 그 라벨로 학습한 모델의 채점 기준이 현행과 다르다.
#
# 왜 **경고**인가 (2026-08-14 최종 리뷰, 정직하게 적는다): 지금 이 레포에서 이 검사는 실제로
# 갈려 있다. 커밋된 `objective.json` 은 `generation=2026-08-13-energy-activation` 이라
# `59b1174118b874ed` 를 내는데, 커밋된 라벨셋 365행은 전부 `19819377a7f8ebb2` 를 달고 있다.
# 그 해시를 내는 generation(`2026-08-13-global-kappa-precedence`)은 **다른 작업자의
# 커밋되지 않은 objective.json 편집에만** 존재한다. 두 세대는 J 스칼라 8개가 전부 같고
# `generation` 문자열만 다르므로 **수치적으로는 무해**하지만, 이 브랜치는 그 generation bump
# 와 **함께 또는 그 뒤에** 머지돼야 한다. 그 파일은 이 작업의 것이 아니라 고칠 수 없고,
# 여기서 하드 실패로 만들면 커밋된 트리에서 감사가 항상 빨개진다. 그래서 **보이게 하되
# 게이트하지는 않는다** — 핸드셰이크가 끝나면 이 블록을 실패로 승격할 것.
WARN = []
try:
    import wm_datasets  # noqa: E402
    _committed = subprocess.run(["git", "-C", ROOT, "show", "HEAD:wm4spacecraft_manufacturing/objective.json"],
                                capture_output=True, text=True, timeout=60)
    if _committed.returncode == 0:
        _cm_hash = objective.objective_hash(json.loads(_committed.stdout))
        if _cm_hash != current_hash:
            WARN.append("커밋된 objective.json 의 해시(%s, generation=%s)가 작업 트리의 해시(%s)와 "
                        "다르다 — 작업 트리 편집이 아직 커밋되지 않았다"
                        % (_cm_hash, json.loads(_committed.stdout).get("generation"), current_hash))
    for _name, _rel in sorted(wm_datasets.KNOWN.items()):
        _p = wm_datasets.abspath(_rel)
        if not os.path.exists(_p):
            continue
        if subprocess.run(["git", "-C", ROOT, "ls-files", "--error-unmatch", _p],
                          capture_output=True).returncode != 0:
            continue                                     # 커밋 안 된 파일은 머지 대상이 아니다
        _hashes = set()
        with open(_p, encoding="utf-8") as fh:
            for _line in fh:
                _line = _line.strip()
                if not _line.startswith("{") or '"objective_hash"' not in _line:
                    continue
                try:
                    _hashes.add(json.loads(_line).get("objective_hash"))
                except ValueError:
                    pass
        if _hashes and _hashes != {current_hash}:
            WARN.append("커밋된 라벨셋 %s 의 objective_hash %s 를 현재 objective.json(%s)이 "
                        "내지 못한다" % (_name, sorted(_hashes), current_hash))
except Exception as e:                                    # 경고 블록이 감사를 죽이면 안 된다
    WARN.append("라벨셋 objective_hash 확인 실패: %r" % (e,))

# --- 요약 --------------------------------------------------------------------------------
for where, bad in OK + FAIL:
    print(("OK        " if not bad else "MISMATCH  ") + where)
    for b in bad:
        print("            - " + b)
print("\n%d/%d consistent" % (len(OK), len(OK) + len(FAIL)))
print("objective_hash:", objective.objective_hash())
# 항목 9-b: 커밋된 라벨셋의 세대 딱지. **게이트가 아니다**(위 블록의 이유 참조).
print("WARN(9-b) %s" % ("커밋된 라벨셋의 objective_hash 가 현재 objective.json 과 일치한다"
                        if not WARN else "머지 핸드셰이크 필요:"))
for _w in WARN:
    print("            - " + _w)
print("NOTE  학습 타깃은 아직 `closed - λ·MACRO_COST`, 채점은 -J 다 (알려진 불일치, "
      "spec §8 단계 7 재학습으로 해소). 위 항목 8 이 그 유예 표식을 지킨다.")
if INVENTORY:
    print("NOTE  순위 밖에 남아 있는 λ·MACRO_COST 사용처 %d곳 (특징량·학습 타깃·진단축 — 실패 아님, "
          "가시성용):" % len(INVENTORY))
    for line in INVENTORY:
        print("        " + line)
sys.exit(1 if FAIL else 0)
