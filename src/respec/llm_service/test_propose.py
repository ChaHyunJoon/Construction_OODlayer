"""Standalone end-to-end check for /propose with a real API key.

Run (from any directory):
    PowerShell:  & "C:\\Users\\chahj\\PythonCodes\\venv\\hjcnlp\\Scripts\\python.exe" `
                   "C:\\Users\\chahj\\PythonCodes\\venv\\ConstructionBots.jl\\src\\respec\\llm_service\\test_propose.py"
    cmd:         "C:\\Users\\chahj\\PythonCodes\\venv\\hjcnlp\\Scripts\\python.exe" test_propose.py

Needs ANTHROPIC_API_KEY in the environment. Uses FastAPI TestClient so no server
needs to be running — it exercises the exact /propose path in-process.

────────────────────────────────────────────────────────────────────────────
[한국어 설명]
이 파일은 /propose 를 진짜 API 키로 끝까지(end-to-end) 돌려보는 간단한 확인 스크립트.
프로젝트 역할: 서버를 따로 띄우지 않고 FastAPI 의 TestClient 로 프로세스 안에서
바로 /propose 경로를 호출해 본다(실제 배선이 되는지 눈으로 확인).
ANTHROPIC_API_KEY 가 환경에 있어야 하며, 없으면 안내 후 종료.

[문법 참고]
  · os.path.dirname(os.path.abspath(__file__)) — 이 스크립트가 있는 폴더의 절대경로.
  · sys.path.insert(0, HERE) — import 경로 맨 앞에 이 폴더 추가(같은 폴더의 server 를 import 하려고).
  · # noqa: E402 — 린터에게 "import 가 파일 위쪽이 아니어도 봐줘"라고 알리는 주석(경로 세팅 뒤 import 라서).
  · TestClient(app) — 서버 없이 앱을 직접 호출하는 테스트용 클라이언트.
  · sys.exit(1) — 0 이 아닌 코드로 종료(실패 표시).
────────────────────────────────────────────────────────────────────────────
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))  # 이 파일이 있는 폴더의 절대경로
sys.path.insert(0, HERE)                            # 그 폴더를 import 검색경로 맨 앞에 추가

from fastapi.testclient import TestClient  # noqa: E402  # 서버 없이 앱을 호출하는 테스트 클라이언트
import server  # noqa: E402                            # 같은 폴더의 server.py(앱 정의)

if not os.environ.get("ANTHROPIC_API_KEY"):   # 키가 없으면 실행 불가 → 안내 후 종료
    print("ERROR: ANTHROPIC_API_KEY is not set in this process's environment.")
    print("  PowerShell:  $env:ANTHROPIC_API_KEY = \"sk-ant-...\"")
    print("  cmd:         set ANTHROPIC_API_KEY=sk-ant-...")
    sys.exit(1)                                # 0 이 아닌 코드로 종료(실패)

event = "Robot R3 reports a motor fault and is immobile."          # 테스트할 OOD 사건(로봇 R3 모터 고장)
open_ids = ["RobotID(3)", "RobotGoID(7)", "FormTransportUnitID(2)"]  # 아직 안 끝난 노드 id 예시 목록

client = TestClient(server.app)                # server.py 의 app 을 감싸는 테스트 클라이언트 생성
resp = client.post("/propose", json={"event": event, "open_ids": open_ids})  # /propose 로 POST(프로세스 안에서 직접)

print("status:", resp.status_code)             # HTTP 상태코드 출력(200 이면 성공)
print("body  :", resp.json())                  # 응답 본문(제안 JSON) 출력
