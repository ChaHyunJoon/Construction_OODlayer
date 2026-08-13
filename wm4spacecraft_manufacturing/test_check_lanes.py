"""check_lanes.py 계약 테스트.

왜 필요한가: `tools/monitor/policy.jl`(~518행) 은 요청한 정책을 그 순간 쓸 수 없으면 조용히
`enacted = "canonical"` 로 떨어지면서 계속 돈다. 요약 행의 `policy` 는 그대로 `"surrogate"` 로
남는다 -- 그래서 보드가 surrogate 를 측정했다고 주장해도 실제 결정은 전부 canonical 이었을 수
있다. 2026-08-12 에 dspy 3.2.1→3.3.0 업그레이드가 서비스 쪽 surrogate 로드를 깨뜨렸을 때 바로
이 일이 일어났다: 갓 돈 보드가 `"policy":"surrogate"` 를 달고 `decisions[*].enacted` 는
`["canonical","canonical","canonical","canonical"]` 이었다. 시작 시점 게이트(P9)는 있지만
3시간짜리 630보드 스윕 도중 서비스가 죽는 건 못 잡는다 -- 결과 자체를 검사해야 한다.
"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable
CHECKER = os.path.join(HERE, "check_lanes.py")

FAILED = 0


def check(name, ok, detail=""):
    global FAILED
    print("  %s  %s   %s" % ("PASS" if ok else "FAIL", name, detail))
    if not ok:
        FAILED += 1


def run_checker(rows, policies=None, min_rows=None):
    """rows 를 임시 디렉토리의 case.jsonl 로 쓰고 검사기를 돌린다. 반환: (returncode, stdout)."""
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "case.jsonl"), "w", encoding="utf-8") as fh:
            for r in rows:
                fh.write(json.dumps(r) + "\n")
        cmd = [PY, CHECKER, "--results-dir", d]
        if policies is not None:
            cmd += ["--policies", policies]
        if min_rows is not None:
            cmd += ["--min-rows", str(min_rows)]
        p = subprocess.run(cmd, capture_output=True, text=True)
        return p.returncode, p.stdout + p.stderr


def dec(enacted):
    return {"enacted": enacted}


CONSISTENT_NOOP = {"ood_seed": 1, "policy": "noop",
                    "decisions": [dec("noop"), dec("noop")]}
CONSISTENT_SURROGATE = {"ood_seed": 2, "policy": "surrogate",
                         "decisions": [dec("surrogate"), dec("surrogate")]}
CONSISTENT_DSPY = {"ood_seed": 3, "policy": "dspy",
                    "decisions": [dec("dspy"), dec("dspy")]}
FALLEN_BACK = {"ood_seed": 42, "policy": "surrogate",
               "decisions": [dec("canonical"), dec("canonical"),
                             dec("canonical"), dec("canonical")]}
PARTIAL_FALLBACK = {"ood_seed": 7, "policy": "dspy",
                     "decisions": [dec("dspy"), dec("dspy"), dec("canonical")]}
NO_DECISIONS = {"ood_seed": 5, "policy": "noop", "decisions": []}
NO_DECISIONS_MISSING = {"ood_seed": 6, "policy": "noop"}
UNKNOWN_POLICY = {"ood_seed": 9, "policy": "heuristic",
                   "decisions": [dec("heuristic")]}

print("== check_lanes.py ==")

rc, out = run_checker([CONSISTENT_NOOP, CONSISTENT_SURROGATE, CONSISTENT_DSPY])
check("policy==enacted 인 행만 있으면 통과", rc == 0, "rc=%d" % rc)

rc, out = run_checker([CONSISTENT_NOOP, FALLEN_BACK])
check("surrogate 행이 전부 canonical 이면 실패", rc == 1, "rc=%d" % rc)
check("surrogate 를 찍는다", "surrogate" in out, out.strip()[-300:])
check("canonical 을 찍는다", "canonical" in out, out.strip()[-300:])
# `"42" in out` 로 느슨하게 두면 makespan 이든 행 번호든 어디에 42 가 있기만 해도 통과한다
# (거의 반증 불가능한 단언이었다). 검사기가 실제로 찍는 필드 형태를 그대로 못 박는다.
check("폴백한 행의 ood_seed 를 `ood_seed=42` 형태로 찍는다", "ood_seed=42" in out,
      out.strip()[-300:])

rc, out = run_checker([CONSISTENT_NOOP, PARTIAL_FALLBACK])
check("일부만 canonical 로 떨어진 혼합 행도 실패", rc == 1, "rc=%d" % rc)

rc, out = run_checker([CONSISTENT_NOOP, NO_DECISIONS])
check("decisions=[] 행은 그 자체로는 위반이 아니다", rc == 0, "rc=%d" % rc)
# `"1" in out` 은 거의 모든 출력에서 참이라 아무것도 재지 않았다. 검사기가 찍는 카운트 필드
# 문자열 자체를 확인한다(형식이 바뀌면 이 테스트가 깨져야 한다).
check("결정 없음 행 카운트를 `결정 없음 행 1개` 로 찍는다", "결정 없음 행 1개" in out,
      out.strip()[-300:])
check("그리고 그 행도 전체 행 수에는 들어간다(`행 2개`)", "행 2개," in out,
      out.strip()[-300:])

rc, out = run_checker([CONSISTENT_NOOP, NO_DECISIONS_MISSING])
check("decisions 필드 자체가 없어도 위반이 아니다", rc == 0, "rc=%d" % rc)

rc, out = run_checker([CONSISTENT_NOOP])
check("noop 행이 전부 noop 이면 통과", rc == 0, "rc=%d" % rc)

rc, out = run_checker([CONSISTENT_NOOP, UNKNOWN_POLICY])
check("--policies 목록 밖의 policy 값은 실패", rc == 1, "rc=%d" % rc)

rc, out = run_checker([])
check("빈 디렉토리는 통과", rc == 0, "rc=%d" % rc)

# ---- --min-rows: 공허한 통과 막기 (2026-08-13) -----------------------------------------
# 위반 0건이라는 이유로 0행짜리(혹은 경로가 틀린) 디렉토리가 PASS 를 내면, 630판을 인증하는
# 게이트가 아무것도 인증하지 않는다. 두 방향을 모두 못 박는다.
rc, out = run_checker([], min_rows=1)
check("--min-rows 아래면 빈 디렉토리도 실패", rc == 1, "rc=%d" % rc)
check("실제 행 수와 기대 하한을 함께 찍는다",
      "행이 0개뿐이다" in out and "최소 1개" in out, out.strip()[-300:])

rc, out = run_checker([CONSISTENT_NOOP, CONSISTENT_SURROGATE], min_rows=3)
check("행이 하한보다 적으면 위반이 없어도 실패", rc == 1, "rc=%d" % rc)
check("실제 행 수(2)를 찍는다", "행이 2개뿐이다" in out, out.strip()[-300:])

rc, out = run_checker([CONSISTENT_NOOP, CONSISTENT_SURROGATE], min_rows=2)
check("행이 하한과 같으면 영향 없음", rc == 0, "rc=%d" % rc)

rc, out = run_checker([CONSISTENT_NOOP, CONSISTENT_SURROGATE], min_rows=1)
check("행이 하한보다 많으면 영향 없음", rc == 0, "rc=%d" % rc)

rc, out = run_checker([CONSISTENT_NOOP, FALLEN_BACK], min_rows=2)
check("--min-rows 를 넘겨도 레인 폴백은 여전히 실패", rc == 1, "rc=%d" % rc)

sys.exit(1 if FAILED else 0)
