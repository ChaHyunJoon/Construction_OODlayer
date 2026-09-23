"""이 디렉터리 **안에서** pytest 를 돌릴 때의 설정. 🔴 시험은 생산 기록 파일에 쓰지 않는다.

루트 `conftest.py` 와 같은 한 줄이다(근거 전문은 그쪽 docstring: 2026-09-03 pytest 가 기본
경로 `results/synth_lane_records.jsonl` 에 시험 행 39줄을 썼다). 왜 여기에도 두나: 이 디렉터리
에서 `python -m pytest ...` 를 돌리면 ini 파일이 없어 rootdir 이 여기가 되고 **루트 conftest 가
안 읽힌다** — 그러면 기본 경로의 유료 원장에 시험 행이 append 된다(memory
`pytest-from-llm-service-dir-contaminates-the-paid-ledger`). 두 파일이 다 읽혀도 `setdefault`
라 해가 없다.

🔴 `generation.py` `_served_files` 가 `conftest.py` 를 제외하므로 서비스 세대 지문
(`code_fingerprint`)은 이 파일로 안 바뀐다.
"""
import os

os.environ.setdefault("SYNTH_RECORD_LOG", "0")
