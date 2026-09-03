"""스위트 전역 설정. 🔴 시험은 **생산 기록 파일에 쓰지 않는다.**

2026-09-03 실측 사고: 합성 기록 sink(`synthesize.append_synthesis_record`)를 붙인 직후 돌린
pytest 가 기본 경로(`results/synth_lane_records.jsonl`)에 39줄을 썼고, 나는 그것을 라이브
렌더가 남긴 기록으로 착각해 읽었다(전부 `enabled=False` 인 시험 판이었다). 진단 파일이
시험 판을 섞어 담으면 그 파일을 믿을 수 없다.

🔴 `code_fingerprint` 는 `conftest.py` 를 제외하므로(`generation.py` 의 제외 목록) 이 파일을
   더해도 서비스 세대 지문은 안 바뀐다 — 게이트가 이 파일 때문에 빨개지지 않는다.
"""
import os

os.environ.setdefault("SYNTH_RECORD_LOG", "0")
