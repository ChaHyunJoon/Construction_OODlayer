"""Standalone end-to-end check for /propose with a real API key.

Run (from any directory):
    PowerShell:  & "C:\\Users\\chahj\\PythonCodes\\venv\\hjcnlp\\Scripts\\python.exe" `
                   "C:\\Users\\chahj\\PythonCodes\\venv\\ConstructionBots.jl\\src\\respec\\llm_service\\test_propose.py"
    cmd:         "C:\\Users\\chahj\\PythonCodes\\venv\\hjcnlp\\Scripts\\python.exe" test_propose.py

Needs ANTHROPIC_API_KEY in the environment. Uses FastAPI TestClient so no server
needs to be running — it exercises the exact /propose path in-process.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from fastapi.testclient import TestClient  # noqa: E402
import server  # noqa: E402

if not os.environ.get("ANTHROPIC_API_KEY"):
    print("ERROR: ANTHROPIC_API_KEY is not set in this process's environment.")
    print("  PowerShell:  $env:ANTHROPIC_API_KEY = \"sk-ant-...\"")
    print("  cmd:         set ANTHROPIC_API_KEY=sk-ant-...")
    sys.exit(1)

event = "Robot R3 reports a motor fault and is immobile."
open_ids = ["RobotID(3)", "RobotGoID(7)", "FormTransportUnitID(2)"]

client = TestClient(server.app)
resp = client.post("/propose", json={"event": event, "open_ids": open_ids})

print("status:", resp.status_code)
print("body  :", resp.json())
