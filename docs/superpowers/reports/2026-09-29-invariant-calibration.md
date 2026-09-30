# selfimprove 불변식 사전 보정 (계획서 Task 7 Step 4) — 2026-09-29

코드: 작업 트리 (HEAD `93a26df` + Task 7 미커밋 변경), `tools/monitor/invariants.jl`.
판: `campaign.py` canonical 레인(서비스 호출 0) + 오라클 fixture 직접 실행(`DSPY_URL` 을 죽은 포트로 고정 — 유료 호출 불가).

## 결과 — I1·I1b·I2 오탐 0 / 24판

| 묶음 | 판 | complete | I1 | I1b | I2 | I3 |
|---|---|---|---|---|---|---|
| tractor canonical fault s101–103 | 3 | 3/3 | ok | na | ok | 0 |
| tractor canonical battery s101–103 | 3 | 3/3 | ok | na | ok | 0 |
| tractor canonical zone s101–103 | 3 | 0/3 | ok | ok | na | 2, 2, 1 |
| xwing canonical fault s101–103 | 3 | 3/3 | ok | na | ok | 0 |
| xwing canonical battery s101–103 | 3 | 3/3 | ok | na | ok | 0 |
| xwing canonical zone s101–103 | 3 | 0/3 | ok | ok | na | 5, 11, 17 |
| tractor oracle fixture (`oracle_zone_clear.json`) zone s101–103 | 3 | 3/3 | ok | ok | ok | 0 |
| xwing oracle fixture zone s101–103 | 3 | 3/3 | ok | ok | ok | 0 |

- 오라클 fixture 여섯 판 전부 `steps=[OracleZoneClear!:translated]` — **실제 빌드 전체 평행이동이 일어난 완주 판**에서 I2 가 ok 다(아래 정의 수정의 양성 증거).
- I3 > 0 는 미완주 NOOP zone 판에서만 나온다. C2 는 I3 를 **완주 판에만** 요구하므로 판정에 안 들어간다(보고용).
- I4 는 라이브러리 팔을 집행한 판이 없어 전부 `na`.

## 정의 수정 (데이터를 보고 문턱을 흔든 것이 아니라 정의 오류를 고쳤다)

### I2 — 전역 목표 → 부모 조립체 좌표계
계획서 정의: t₀ 에 LiftIntoPlace 마다 `translation(global_transform(goal_config(n)))` 저장, 끝에 공통 평행이동을 빼고 잔차 ≤ 포획거리.
**tractor 명목 완주 판(zone 없음)에서 공통 평행이동 뒤 최대 잔차 9.78** (27 부품 중 하위 조립체 7개) — 하위 조립체 안 부품의 t₀ 전역 목표는 그 조립체가 **적치 중인 자리** 기준이기 때문이다. 이 정의로는 모든 완주 판이 C1 에서 떨어진다.
수정: t₀ 에 `local_transform(goal_config(n))`(부모 조립체 좌표계의 목표 자리)를 저장하고, 끝에 `local_transform(scene node)` 와 비교(병진 ≤ `capture_distance_tolerance`, 회전 ≤ `capture_rotation_tolerance`). 루트 조립체는 t₀ 전역 자세 대비 **평면 평행이동만**(z·회전 불변) 허용한다.
- 명목 tractor 27 부품: 잔차 **정확히 0**.
- 음성 대조(`test/selfimprove_invariants.jl`): 부품 하나를 조립체 안에서 옮김(= 부품과 그 목표를 함께 옮긴 편법의 결과) → fail, 루트 수직 이동 → fail, 루트 평면 평행이동 → ok.

### I3 — 전 후보 → 아직 안 놓인 화물
계획서 정의: 끝 시점 `scene_drift` 의 would_snap 수. **colored_8x8 명목 완주 판에서 33(전 부품)** — 놓인 부품이 "free 이고 ObjectStart 에서 멀다" 로 읽힌다(그 측정은 판 중간 resync 대상용).
수정: `LiftIntoPlace` 가 아직 closed 가 아닌 화물과 그 운반유닛만 센다. 완주 판에서 0 이 자명하고, 음성 대조(LiftIntoPlace 하나를 다시 열면 ≥ 1)가 시험에 있다.

### I4 — 스텝 훅 → 이 판의 스트림
`HARNESS_HOOK` 은 검증 하니스가 쓰는 자리라 덮지 않는다. 판 끝에 이 판의 스트림 프레임(`sim_t`, `n_closed`, 해상도 ≈ 1.25 s)에서 집행 시점 이후 첫 closed 증가까지를 잰다.

### 재현
판 로그: 세션 스크래치패드(비커밋). 명령:
`GRID_OUT=<d> DEMO_MODEL=tractor.mpd bash tools/monitor/grid/render_grid.sh canonical "fault battery zone" "101 102 103" 8`
fixture 판: `render_demo.jl` 을 canonical 레인 + `DEMO_SYNTH_FIXTURE=tools/fixtures/oracle_zone_clear.json` + `DSPY_URL=http://127.0.0.1:1` 로 직접.
