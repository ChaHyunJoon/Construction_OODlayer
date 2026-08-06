@echo off
REM 야간 생성이 끝나면 러너(-ThenRun)가 이걸 실행한다.
REM 공백 있는 명령을 -ThenRun 으로 직접 넘기면 Start-Process 가 인자를 공백으로 이어붙여
REM 파라미터 바인딩이 깨진다(2026-08-03 실측) -- 그래서 한 토큰짜리 래퍼 파일로 둔다.
set PYTHONIOENCODING=utf-8
python night_analysis.py
