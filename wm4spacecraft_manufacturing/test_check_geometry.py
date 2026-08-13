"""check_geometry.py 계약 테스트.

왜 필요한가: 요약 행에는 창고 거리가 `geometry.depot_distance` 로만 남는다. 2026-08-12 이전
행에는 `geometry` 블록 자체가 없다. 그 두 세대를 한 파일에 섞으면 makespan 과 에너지가 서로
다른 세계에서 나온 값이 되는데, 표는 그걸 구분해 주지 않는다. 검사는 주장이 아니라 코드여야 한다.
"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable
CHECKER = os.path.join(HERE, "check_geometry.py")

FAILED = 0


def check(name, ok, detail=""):
    global FAILED
    print("  %s  %s   %s" % ("PASS" if ok else "FAIL", name, detail))
    if not ok:
        FAILED += 1


def run_checker(rows, expect="20.0", min_rows=None):
    """rows 를 임시 디렉토리의 case.jsonl 로 쓰고 검사기를 돌린다. 반환: (returncode, stdout)."""
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "battery.jsonl"), "w", encoding="utf-8") as fh:
            for r in rows:
                fh.write(json.dumps(r) + "\n")
        cmd = [PY, CHECKER, "--results-dir", d, "--expect-depot-distance", expect]
        if min_rows is not None:
            cmd += ["--min-rows", str(min_rows)]
        p = subprocess.run(cmd, capture_output=True, text=True)
        return p.returncode, p.stdout + p.stderr


GOOD = {"case": "battery", "ood_seed": 1, "policy": "noop",
        "geometry": {"depot_mode": "fixed", "depot_distance": 20.0,
                     "station_keeping": True}}
D40 = {"case": "battery", "ood_seed": 2, "policy": "noop",
       "geometry": {"depot_mode": "fixed", "depot_distance": 40.0,
                    "station_keeping": True}}
LEGACY = {"case": "battery", "ood_seed": 3, "policy": "noop"}   # geometry 블록 없음

print("== check_geometry.py ==")

rc, out = run_checker([GOOD, GOOD])
check("D=20 행만 있으면 통과", rc == 0, "rc=%d" % rc)

rc, out = run_checker([GOOD, D40])
check("D=40 행이 섞이면 실패", rc == 1, "rc=%d" % rc)
check("D=40 행의 ood_seed 를 찍는다", "ood_seed=2" in out, out.strip()[-200:])

rc, out = run_checker([GOOD, LEGACY])
check("geometry 블록이 없는 구세대 행은 실패", rc == 1, "rc=%d" % rc)
check("구세대 행임을 명시한다", "geometry" in out, out.strip()[-200:])

rc, out = run_checker([])
check("빈 파일은 통과", rc == 0, "rc=%d" % rc)

# ---- --min-rows: 공허한 통과 막기 (2026-08-13) -----------------------------------------
# 위반 0건이라는 이유로 0행짜리 디렉토리가 PASS 를 내면, 630판을 인증하는 게이트가 오타 하나로
# 아무것도 인증하지 않게 된다. 아래 두 방향을 모두 못 박는다.
rc, out = run_checker([], min_rows=1)
check("--min-rows 아래면 빈 디렉토리도 실패", rc == 1, "rc=%d" % rc)
check("실제 행 수와 기대 하한을 함께 찍는다",
      "행이 0개뿐이다" in out and "최소 1개" in out, out.strip()[-300:])

rc, out = run_checker([GOOD, GOOD], min_rows=3)
check("행이 하한보다 적으면 위반이 없어도 실패", rc == 1, "rc=%d" % rc)
check("실제 행 수(2)를 찍는다", "행이 2개뿐이다" in out, out.strip()[-300:])

rc, out = run_checker([GOOD, GOOD], min_rows=2)
check("행이 하한과 같으면 영향 없음", rc == 0, "rc=%d" % rc)

rc, out = run_checker([GOOD, GOOD], min_rows=1)
check("행이 하한보다 많으면 영향 없음", rc == 0, "rc=%d" % rc)

rc, out = run_checker([GOOD, D40], min_rows=2)
check("--min-rows 를 넘겨도 D=40 혼입은 여전히 실패", rc == 1, "rc=%d" % rc)

sys.exit(1 if FAILED else 0)
