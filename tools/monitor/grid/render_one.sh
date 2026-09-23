#!/usr/bin/env bash
# render_one.sh <lane> <case> <seed>   (GRID_OUT 필수 — campaign.py init 이 만든 격자 디렉터리)
# 격자 한 판을 **렌더 엔진**(render_demo.jl)으로 돌린다 — 도구 합성 집행은 이 엔진에만 있다.
# 🔴 2026-09-23 (Task 6b·6c·7): 판의 env·실행·기록은 campaign.py run-one 이 한다.
#   · 상속 변수(DEMO_ZONE·DEMO_SYNTH_FIXTURE·MONITOR_RUN_ID·복구 손잡이 …)를 전부 지우고
#     campaign.json 의 set_env + 셀 값(zone 포함 모든 셀에 DEMO_SEED·DEMO_ZONE_SEED)만 넣는다.
#   · 코드가 campaign 과 다르면 돌리지 않고 error:fingerprint_drift 를 남기고 exit 255(xargs 정지).
#   · rc·timeout·elapsed·실제 스트림 경로·지문을 runs.jsonl 에 한 줄로 남기고, 채점 안 된 판은
#     exit 1 이다(예전처럼 실패를 exit 0 으로 가리지 않는다).
exec python3 "$(dirname "$0")/campaign.py" run-one "${GRID_OUT:?GRID_OUT unset}" "$@"
