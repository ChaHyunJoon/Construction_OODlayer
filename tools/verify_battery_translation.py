#!/usr/bin/env python
"""
verify_battery_translation.py -- LIVE verification that battery/degradation NL translates to
the NEW DeprioritizeAgent DSL kind (and that a HARD fault still does NOT).

It boots a FRESH uvicorn on a spare port loading the CURRENT src/respec/llm_service code (so the
new schema.py/propose.py are exercised), POSTs several battery paraphrases + contrast events, and
scores the returned `kind`. The Anthropic key is read from an EXISTING running service process's
environment (via psutil) so we don't need it in this shell; it is kept in memory only and never
printed. The user's existing service (port 8000) is left untouched; only our spare port is stopped.

Run:  C:/Users/chahj/PythonCodes/venv/hjcrl/Scripts/python.exe tools/verify_battery_translation.py [SRC_PID] [PORT]
"""
# =============================================================================
# [한국어 설명]
#  이 파일이 하는 일:
#   - "battery(배터리 저하)" 자연어가 새 DSL 종류인 DeprioritizeAgent(부드러운 우선순위
#     낮추기)로 제대로 번역되는지 실제로(LIVE) 확인하는 검증 스크립트.
#   - 동시에, 완전 고장(HARD fault)은 DeprioritizeAgent가 되면 안 된다는 것도 확인한다
#     (완전 고장은 Replace/ForbidAgent 쪽이어야 함 — contrast 케이스).
#
#  translate_eval.py와의 차이:
#   - translate_eval.py는 propose()를 프로세스 안에서 직접 부르는 "빠른" 방식.
#   - 이 파일은 진짜로 uvicorn 웹서버(FastAPI 서비스)를 새로 띄우고 HTTP로 /propose에
#     POST해서, 배포될 실제 코드 경로(schema.py/propose.py 최신본)를 그대로 시험한다.
#
#  API 키 취급(중요):
#   - ANTHROPIC_API_KEY를 이 셸에 두지 않고, 이미 실행 중인 서비스 프로세스의 환경에서
#     psutil로 읽어와 메모리에만 두고 절대 출력하지 않는다.
#   - 사용자의 기존 서비스(포트 8000)는 건드리지 않고, 여기서 띄운 예비 포트만 종료한다.
#
#  문법 참고 (파이썬 초보용):
#   · """ ... """  = docstring(설명문). 맨 위 #! 줄은 셸이 인터프리터를 고르는 shebang.
#   · subprocess.Popen(...) = 외부 프로그램(uvicorn 서버)을 자식 프로세스로 실행.
#   · urllib.request        = 표준 라이브러리로 HTTP 요청 보내기(외부 패키지 불필요).
#   · psutil                = 실행 중인 프로세스 목록/환경변수를 들여다보는 라이브러리.
#   · try/except/finally    = 예외 처리. finally는 성공/실패와 무관하게 반드시 실행(정리용).
#   · next((x for x in ...), None) = 조건 맞는 첫 항목, 없으면 None(제너레이터 + 기본값).
#   · dict(os.environ)      = 현재 환경변수 복사본(수정해도 원본 env 안 건드림).
# =============================================================================
import json
import os
import subprocess
import sys
import time
import urllib.request

import psutil

HERE = os.path.dirname(os.path.abspath(__file__))   # tools/ 폴더
ROOT = os.path.dirname(HERE)                         # 프로젝트 최상위
SVC = os.path.join(ROOT, "src", "respec", "llm_service")  # 새 서버를 띄울 코드 폴더
FIXTURE = os.path.join(HERE, "llm_fixture.json")     # 씬 고정 데이터(agents/nodes 등)
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8010  # 예비 포트(인자로 주면 그 값, 없으면 8010)


# 실행 중인 서비스 프로세스의 환경변수에서 ANTHROPIC_API_KEY를 읽어 (키, 그 PID)로 반환.
# src_pid를 주면 그 프로세스만, 없으면 python 프로세스들을 훑어 키가 있는 걸 찾는다. 절대 출력 안 함.
def _find_key(src_pid=None):
    """Read ANTHROPIC_API_KEY from a running service process's env (never printed)."""
    pids = [int(src_pid)] if src_pid else []
    if not pids:  # find any python process whose env has the key
        for p in psutil.process_iter(["name"]):
            if p.info["name"] and "python" in p.info["name"].lower():
                pids.append(p.pid)
    for pid in pids:
        try:
            env = psutil.Process(pid).environ()   # 해당 프로세스의 환경변수 읽기(권한 없으면 예외)
            if env.get("ANTHROPIC_API_KEY"):
                return env["ANTHROPIC_API_KEY"], pid
        except Exception:
            continue   # 접근 불가/종료된 프로세스는 조용히 건너뜀
    return None, None


# 자연어 event 하나를 로컬 서비스의 /propose에 POST하고, 응답 JSON(proposal)을 dict로 반환.
def _post(event, fx, port):
    body = {"event": event, "open_ids": fx["open_ids"], "agents": fx["agents"],
            "nodes": fx["nodes"], "zones": fx.get("zones", [])}   # 서버가 기대하는 요청 본문
    req = urllib.request.Request(f"http://127.0.0.1:{port}/propose",
                                 data=json.dumps(body).encode(),   # dict -> JSON 문자열 -> bytes
                                 headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=45) as r:
        return json.loads(r.read().decode())   # 응답 bytes -> 문자열 -> dict


# 배터리 저하 상황을 다르게 표현한 문장들(전부 DeprioritizeAgent로 번역되어야 정답).
BATTERY = [
    "Robot R3's battery is degraded and now at about 39% charge; it should avoid long-distance and heavy-payload hauls so it does not run flat.",
    "Heads up: robot 3 is low on charge. Prefer other robots for the heavy transport jobs, but it can still work if needed.",
    "R3's battery health has dropped a lot. Spare it from big/long hauls so it lasts, without taking it offline.",
]
# contrast: a HARD breakdown must NOT become DeprioritizeAgent (should be Replace/ForbidAgent)
# 대조군: 완전 고장은 부드러운 DeprioritizeAgent가 되면 "안 됨"(Replace/ForbidAgent여야 함).
CONTRAST = [
    "Robot R3 has broken down and is completely immobile; it cannot move at all.",
]


# 메인: 키 확보 -> 새 서비스 기동 -> 배터리/대조 문장 채점 -> 정리(finally에서 서버 종료).
def main():
    src_pid = sys.argv[1] if len(sys.argv) > 1 else None   # 첫 인자로 키를 읽어올 서비스 PID(선택)
    key, kpid = _find_key(src_pid)
    if not key:
        sys.exit("ERROR: could not read ANTHROPIC_API_KEY from any running service process. "
                 "Start the service (tools/run_real_llm_demo.ps1 style) or pass a PID.")
    print(f">>> key sourced from PID {kpid} (len={len(key)}, masked)")   # 키 자체는 안 찍고 길이만
    fx = json.load(open(FIXTURE, encoding="utf-8"))   # fixture(JSON) 로드

    env = dict(os.environ)                 # 현재 환경 복사(자식 프로세스에 넘길 것)
    env["ANTHROPIC_API_KEY"] = key         # 읽어온 키를 자식 env에만 주입
    env.setdefault("RESPEC_MODEL", "claude-opus-4-8")   # 모델 미지정 시 기본값 설정(있으면 유지)
    print(f">>> booting FRESH service (new code) on port {PORT} ...")
    proc = subprocess.Popen([sys.executable, "-m", "uvicorn", "server:app",   # uvicorn으로 FastAPI 서버 기동
                             "--host", "127.0.0.1", "--port", str(PORT)],
                            cwd=SVC, env=env,                                  # 서비스 폴더에서, 위 env로
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)  # 서버 로그는 버림
    try:
        up = False
        for _ in range(40):   # 최대 40번, 서버 /health가 살아날 때까지 재시도
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=2) as r:
                    if r.status == 200:   # 200이면 서버 준비 완료
                        up = True; break
            except Exception:
                time.sleep(0.75)   # 아직 안 떴으면 잠깐 쉬고 재시도
        if not up:
            sys.exit("ERROR: fresh service /health never came up")
        print(">>> fresh service healthy. verifying battery -> DeprioritizeAgent\n")

        # fixture agents 중 라벨이 R3/robot 3인 로봇 id를 찾음(없으면 None, 그땐 agent 일치 검사 생략).
        r3 = next((a["id"] for a in fx["agents"] if "R3" in (a.get("label") or "") or "robot 3" in (a.get("label") or "")), None)
        ok = tot = 0   # 정답 수 / 시도 수
        for ev in BATTERY:
            tot += 1
            try:
                p = _post(ev, fx, PORT)   # 서버에 문장 보내고 proposal 받기
                kinds = [c.get("kind") for c in p.get("constraints", [])]   # 나온 제약들의 kind 목록
                depr = [c for c in p.get("constraints", []) if c.get("kind") == "DeprioritizeAgent"]  # 그중 Deprioritize만
                hit = bool(depr) and (r3 is None or depr[0].get("agent") == r3)   # Deprioritize 있고 대상이 R3면 정답
                ok += hit
                mark = "OK " if hit else "X  "
                extra = f" agent={depr[0].get('agent')} factor={depr[0].get('factor')}" if depr else ""
                print(f"  [{mark}] {kinds}{extra}   <- {ev[:70]}")   # ev[:70] = 문장 앞 70글자만 표시
            except Exception as e:
                print(f"  [ERR] {type(e).__name__}: {e}")
        print()
        for ev in CONTRAST:   # 대조군: 완전 고장은 DeprioritizeAgent가 아니어야 정답
            try:
                p = _post(ev, fx, PORT)
                kinds = [c.get("kind") for c in p.get("constraints", [])]
                good = "DeprioritizeAgent" not in kinds  # a hard fault should NOT be soft
                print(f"  [{'OK ' if good else 'X  '}] contrast(hard fault) -> {kinds}  (want NOT DeprioritizeAgent)")
            except Exception as e:
                print(f"  [ERR] {type(e).__name__}: {e}")

        print(f"\n==== battery->DeprioritizeAgent: {ok}/{tot} ====")
        sys.exit(0 if ok == tot else 1)   # 배터리 문장 전부 정답이어야 성공(0)
    finally:
        # 성공/실패/예외와 무관하게 반드시 실행: 우리가 띄운 예비 서버만 종료(포트 8000은 안 건드림).
        print(">>> stopping fresh service (user's port 8000 untouched)")
        proc.terminate()          # 정중히 종료 요청(SIGTERM)
        try:
            proc.wait(timeout=5)  # 5초 기다림
        except Exception:
            proc.kill()           # 안 죽으면 강제 종료


if __name__ == "__main__":   # 직접 실행할 때만 main() 호출
    main()
