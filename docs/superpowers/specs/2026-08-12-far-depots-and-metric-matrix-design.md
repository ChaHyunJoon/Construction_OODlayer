# 원거리 스페어 창고 + 4지표 결과 행렬 — 설계 (2026-08-12)

## 1. 배경: 두 개의 서로 다른 버그

UI(대시보드 FACTORY VIEW)에서 관찰된 증상은 두 가지였다.

1. 4방위 파란 창고(depot pad)가 원점에 너무 가깝게, 사실상 빌드 영역 **안쪽**에 놓여 있다.
2. 그 창고 안에 예비 로봇이 하나도 없고, 전부 화면 한쪽 구석에 모여 대기한다.

원인은 서로 다르며, 둘 다 코드와 실측으로 확인했다.

### 1-1. 창고가 원점 근처인 이유 — 생성 시점이 잘못됐다

`add_directional_spare_pools!`(`src/respec/ood_injection.jl:439`)는 창고 중심을
`pool_centers(_scene_robot_bbox(scene_tree); margin = 6·robot_radius)` 로 잡는다.
`_scene_robot_bbox`(`ood_injection.jl:412`)는 **씬트리에 이미 있는 로봇들**만 감싸는 상자다.

이 함수가 호출되는 지점은 `src/full_demo.jl:433` 인데, 빌드 배치가 결정되는

- `generate_staging_plan!` — `full_demo.jl:467`
- `select_initial_object_grid_locations!` — `full_demo.jl:506`

보다 **앞선다**. 즉 창고를 놓는 순간에는 빌드 footprint가 아직 세상에 존재하지 않고,
알 수 있는 것은 로봇 시작 격자뿐이다.

실측(tractor, `robot_radius = 25 × robot_scale = 0.35`, `num_robots = 10`):

| 값 | 계산 | 결과 |
|---|---|---|
| 로봇 시작 격자 한 변 | `ceil(√10) × 5r = 4 × 1.75` | 7.0 (→ xy ∈ [−3.5, 3.5]) |
| 창고 margin | `6r` | 2.1 |
| 창고 중심 | bbox + margin | ≈ (0, ±5.6), (±5.6, 0) |
| 실제 빌드/적치 영역 | 스트림 실측 | 반경 ≈ 13 |

창고가 빌드 반경의 절반도 안 되는 거리에 있다. **margin 값을 키우는 것으로는 못 고친다** —
기준 상자 자체가 틀렸기 때문이다.

### 1-2. 스페어가 창고에 없는 이유 — 분산 포텐셜장에 쓸려나간다

유휴 스페어도 평범한 RVO 에이전트이고, 그 `RobotGo` 노드는 매 스텝
`src/route_planning.jl:1028` 의 조건 `!(build_step_active && ready_for_pickup)` 에 항상 걸린다.
따라서 **분산(dispersion) 포텐셜장**의 반발력을 영구적으로 받는다.

`tools/monitor/streams/tractor__fault_battery.jsonl` 실측:

- t = 1.275 s: 스페어 8대가 이미 창고 중심에서 1~3 단위 밀려나 있음.
- 마지막 프레임(t = 35.2 s): 스페어 6대가 `(−13.75 … −10.25, −8.68)` 에
  **0.70 = 2 × robot_radius 간격으로 어깨를 맞대고 한 줄로 정체**.

0.70 이라는 등간격은 설계된 배치가 아니라 RVO 접촉 반경에서 나오는 정체(jam) 간격이다.
사용자가 본 "여분 로봇이 전부 한쪽 구석에 대기"가 이것이다.

### 1-3. 최근접 창고 선정은 이미 있다

- `hot_swap_robot!`(`src/respec/replace_robot.jl:1472`) → `nearest_pool(고장 좌표)`
- `replace_robot_distributed!`(`replace_robot.jl:1158`) → `nearest_pool(픽업 좌표)`
- `nearest_pool`(`ood_injection.jl:399`) — 직선거리, 빈 창고는 자동 제외(`nonempty=true`)

즉 요구사항 2번("발생 좌표에서 직선거리가 가장 가까운 창고에서 선정")은 **새로 만들 것이
아니라, 1-1·1-2 때문에 무의미해져 있던 것을 되살리는 일**이다. 창고 중심들이 서로 붙어 있고
실제 몸체는 딴 데 있으면 "가장 가까운"은 아무 의미가 없다.

## 2. 목표 / 비목표

**목표**

- G1. 4개 창고를 빌드에서 확실히 떨어진 절대 좌표에 고정한다.
- G2. 미파견 스페어가 자기 창고 슬롯에 머물게 한다.
- G3. 고장·심각 방전 시 발생 좌표에서 직선거리 최근접 창고가 응답하고, 그 사실이 UI에 보인다.
- G4. 데이터를 전면 재생성하면서, 결과 표에 평가지표 3종(성공률·빌드 시간·에너지)을
  케이스 7종 × 컨트롤러 4종 전 칸에 기록한다.

**비목표**

- 배정(MILP/greedy) 알고리즘 변경. 건드리지 않는다.
- 행동 어휘(`action_registry.json`) 변경. 매크로를 추가·수정하지 않는다.
- 조합 케이스(fault+battery 등)용 오라클 격자 신규 생성. 비용이 크고, 지금도 "no grid"로
  정직하게 비어 있다(§6-3).

## 3. 확정된 결정

| # | 질문 | 결정 |
|---|---|---|
| D1 | 창고 거리 기준 | **절대 좌표 고정** (bbox 기반 아님) |
| D2 | 드리프트 방지 | **정박(station-keeping)** — 분산 제외 + 슬롯 유지 |
| D3 | 배터리 방전 | **심각도 분기 유지** — SoC ≤ 0.2 실물 교체, 초과는 현장 배터리 교체 |
| D4 | 적용 범위 | **전면 적용 + 라벨 재생성** |

## 4. 설계

기존 구조를 바꾸지 않는다. 이음새 3개만 손댄다.

| 이음새 | 현재 | 변경 후 |
|---|---|---|
| 창고 좌표 | `pool_centers(로봇격자 bbox; margin=6r)` | `depot_centers_fixed(D)` — 절대 (0,±D), (±D,0) |
| 유휴 로봇 구동 | 분산 포텐셜장 무조건 적용 | 미파견 스페어는 분산 제외 + 슬롯 정박 |
| 스페어 선정 | `nearest_pool` (존재하나 무의미) | 코드 그대로, 의미만 복원 |

### 4-1. 창고 = 절대 좌표 고정 (D1)

`src/respec/ood_injection.jl`:

- `SPARE_DEPOT_DISTANCE::Ref{Float64}` 신설, 접근자 `set_spare_depot_distance!(d)` /
  `spare_depot_distance()`, env 이름 `SPARE_DEPOT_DIST`.
- `depot_centers_fixed(d)` 신설 → `Dict(:north=>[0,d], :south=>[0,-d], :east=>[d,0], :west=>[-d,0])`.
- `add_directional_spare_pools!` 는 bbox/margin 대신 이 중심을 쓴다. 창고 **내부** 배치
  (한 줄, `spacing` 간격, 중앙 정렬)와 `DEPOT_INFO` 패드 크기 계산은 그대로.

**기존 API 보존.** `pool_centers(bbox; margin)` 와 `set_spare_pool_margin!` 는 삭제하지 않는다
— `tools/checks.jl:236-243` 이 단위검사로 쓰고 있다. 절대 모드에서 margin 은 무시되며,
`set_spare_pool_margin!` 는 1회 `@warn` 을 남긴다. 이 함수를 "창고를 멀리 두려고" 부르던
`tools/demos.jl:1576`, `tools/demos.jl:2754` 는 새 knob으로 교체해 의도를 보존한다.

**기본값 D = 25.0** 로 시작한다(빌드 반경 ≈ 13의 약 2배). 확정은 실측으로 한다: D ∈ {15, 25, 40}
에서 makespan·완주율을 재고 그 결과로 기본값을 정한다. 창고가 멀수록 파견 스페어의 주행
시간이 그대로 makespan에 붙고 완주 실패 위험이 커지므로, 이 스윕은 선택이 아니라 필수다.

**클리어런스 경고.** 절대 좌표라 모델이 커지면 창고가 다시 빌드 안으로 들어온다. 시뮬 시작
직전 1회, `D < 빌드 footprint 반경 × 1.2` 이면 `@warn` 만 남긴다. 자동 조정은 하지 않는다
(D1의 "고정" 선택을 침범하지 않기 위해). 여기서 **빌드 footprint 반경**은 원점에서
`env.staging_circles` 각 원의 `center + radius`, 그리고 로봇·부품 노드의 전역 위치까지의
거리 중 최댓값으로 정의한다.

### 4-2. 정박 (D2)

- `add_directional_spare_pools!` 가 각 스페어를 배치할 때 이미 계산하는 좌표를
  `SPARE_SLOTS::Ref{Dict{AbstractID,Vector{Float64}}}` 에 함께 기록한다.
- `src/route_planning.jl:1025` 의 분산 정책 블록 진입부에 조기 탈출을 추가한다:

  > 이 에이전트가 **아직 미파견 스페어**(`is_spare(rid) == true`)이면 → 포텐셜장을 건너뛰고
  > 목표를 `SPARE_SLOTS[rid]` 로 잡는다. 이미 슬롯에 있으면(허용오차 이내) 속도 0.

- 상태 플래그를 새로 만들지 않는다. `pop_spare!` 가 스페어를 풀에서 빼는 순간
  `is_spare` 가 false 가 되므로 **파견된 로봇은 자동으로 정상 주행으로 복귀**한다.
- hot-swap `:via_depot` 경로(창고 몸체는 `_retire_spare_body!` 로 은퇴, 안정 id 로봇이
  `_rehome_robot!` 로 창고에서 등장)는 영향 없음 — 등장한 로봇은 스페어가 아니다.
- 비용: `is_spare` 는 풀 4개 × n 원소 선형 검사. 스텝당 에이전트 수만큼 호출되지만
  규모가 작아 무시할 수 있다.

### 4-3. 최근접 선정과 배터리 분기 (D3)

새 로직 없음. `nearest_pool` 이 직선거리로 이미 동작하고, 빈 창고는 건너뛴다.
4-1·4-2 이후 처음으로 이 계산이 의미를 갖는다.

배터리는 심각도 분기를 유지한다: `REPLACE_SOC_THRESHOLD`(기본 0.2) 이하면 최근접 창고에서
실물 교체(`hot_swap_robot!`), 초과면 현장 배터리 교체(`swap_battery!`, 창고 미소모).

**미확인 사항 — 첫 작업으로 검증한다.** 배터리 OOD가 실제로 이 분기를 타고
`hot_swap_robot!` 까지 도달하는지는 코드 읽기만으로 확정하지 못했다. 심각 방전 1건을 주입해
로그에서 `[HOTSWAP] ... via :<방위> depot` 이 찍히는지 확인한다. 안 찍히면 그 배선이
작업 항목으로 추가된다.

### 4-4. UI 반영

- 파란 패드: `draw_spare_depots!`(`ood_injection.jl:616`)가 `SPARE_POOL_CENTERS` 를 그대로
  읽으므로 좌표 변경만으로 따라온다. 코드 변경 없음.
- **스트림에 창고 정보 신설.** 현재 프레임 레코드 키는
  `now/recovery/robots/sim_t/battery/n_active/assemblies/handoffs/schedule/n_closed/t/respec_history/respec/ood`
  로, 창고에 대한 정보가 **전혀 없다**. `depots` 를 추가한다:

  ```json
  "depots": [{"side":"east","center":[25.0,0.0],"available":2,"capacity":3}, ...]
  ```

  그리고 교체 사건 레코드에 `depot`(응답한 방위) 키를 추가한다. 이게 없으면 대시보드가
  "가까운 창고가 응답했다"를 보여줄 방법이 없다.
- `tools/monitor/dashboard.html`: 4방위 재고 표시 + 응답한 창고 하이라이트(작게).
- 렌더 카메라: 창고가 ±D 로 나가면 기본 프레이밍 밖일 수 있어 줌 확인이 필요하다.

### 4-5. 결과 행렬 — 4지표 × 7케이스 × 4컨트롤러 (G4)

현재 발표용 표는 칸마다 숫자 2개(완주 k/5, 결정 적중률)만 담고 있다. 재생성 때 지표 3종을
전부 기록한다. 지표 정의는 `wm4spacecraft_manufacturing/llm_ood_eval.py` 헤더의 4종을 그대로
쓴다(이미 구현되어 있다).

| 지표 | 필드 | 집계 규칙 |
|---|---|---|
| ① 성공률 | `complete` | k/n + Wilson 95% CI |
| ② 결정 적중률 | `decisions[].macro` vs `reference_policy` a* | 결정 단위 비율 |
| ③ 빌드 시간 | `sim_seconds` | **완주한 판만** 평균 + n_complete 병기 |
| ④ 에너지 | `battery.energy_per_closed` (주), `battery.min_soc` (마모) | 완주 판 평균 |

**③·④의 함정을 표에 명시한다.** 빌드 시간을 완주 판만으로 평균내면 완주율이 낮은 정책이
유리해 보인다(censoring). 그래서 ③은 항상 `n_complete/n` 과 같은 칸에 적는다. 총 에너지
(`total_energy_J`)를 주지표로 쓰면 일을 덜 한 미완주가 유리해지므로, 주지표는 닫힌 노드당
에너지(`energy_per_closed`)로 한다 — 이 논거는 `llm_ood_eval.py` 헤더 ④에 이미 적혀 있다.

**기록 측 변경 (실제 작업은 여기 하나뿐):**

- 런 요약(`results/llm_ood_eval.jsonl`)은 이미 4종을 전부 담고 있다. 지표 필드는 변경 없음
  (아래 provenance 필드만 추가된다).
- 오라클 라벨(`oracle/out/*.jsonl`)은 `complete`·`makespan`·`min_soc` 만 있고 **에너지가 없다**.
  `wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl` 의 덤프에
  `battery_report()`(`src/navigator/battery.jl:318`) 블록을 추가한다 — 런 요약이
  `tools/monitor/run_demo.jl:652` 에서 쓰는 바로 그 함수라 새 계측이 아니라 재사용이다.

**표 생성기 신설**: `wm4spacecraft_manufacturing/results_matrix.py`

- 입력: 케이스별 런 요약 jsonl + 오라클 라벨 덤프.
- 출력: 7행 × 4열 행렬을 CSV·Markdown·HTML 로. 칸마다 4지표.
- 오라클 열은 라벨 격자에서 유도한 상한이며 온라인 정책이 아니다. 조합 케이스는 격자가
  없으므로 `—` 로 남기고 각주로 이유를 밝힌다(비목표에 따라 신규 격자는 만들지 않는다).
- Canonical 열이 `noop` 레인이라는 사실도 각주로 유지한다(현재 표의 캡션과 동일).

**출처(provenance) 기록 — 필수.** 이 저장소는 과거에 세대가 섞인 산출물을 잘못 인용한 적이
있다(`.claude/CLAUDE.md` §결과 세대). 새 기하로 전부 다시 만드는 이번 재생성에서는 모든 런
요약과 라벨 레코드에 다음을 남긴다:

```
geometry = {depot_mode: "fixed", depot_distance: D, station_keeping: true}
```

`results_matrix.py` 는 입력 레코드의 `geometry` 가 섞여 있으면 표를 만들지 않고 에러를 낸다.

## 5. 검증

- `tools/checks.jl` 단위검사 추가: 절대 창고 중심 4개 좌표, 스페어별 슬롯 기록,
  각 방위 근처 점 → 해당 방위 선정.
- **드리프트 회귀 테스트**(이번 버그의 본체): 짧은 헤드리스 런 후 "미파견 스페어 전원이
  자기 슬롯에서 ε 이내"(ε = `default_robot_radius()`). 현행 코드에서는 이 테스트가 반드시
  실패해야 한다(실패 확인 후 수정).
- 기준선 유지: `julia +lts --project=. -e 'using Pkg; Pkg.test()'` = 11 pass / 1 error
  (Gurobi 라이선스 없음, 이 변경과 무관).
- 어휘 무변경 확인: `python wm4spacecraft_manufacturing/audit_action_vocab.py` (exit 0).
- 학습셋 계약: `python test_surrogate_support.py` → `support=[0,1,2,3,4,7,8]` (7/7).
- D 스윕 3점(15/25/40) 실측 후 기본값 확정.

## 6. 데이터 재생성 (D4)

구현·검증이 **끝난 뒤에** 순차로 실행한다.

1. 데모 스트림 재생성 — `tools/monitor/regen_router_cases.sh`
2. 오라클 라벨 재생성 — `oracle/gen_oracle_dataset.jl` (에너지 필드 추가된 버전)
3. `test_surrogate_support.py` 7/7 재확인 → surrogate 재학습
4. 7케이스 × 4컨트롤러 런 → `results_matrix.py` 로 표 생성

**제약 3개:**

1. **런은 절대 병렬로 돌리지 않는다.** `run_lego_demo` 는 HiGHS MILP 로 스케줄을 푸는데 CPU
   경합이 다르면 다른 해가 나온다. 병렬 실행은 정책 비교가 아니라 서로 다른 두 세계의
   비교가 된다. 프로세스당 ~2.5 GB라 OOM 위험도 있다.
2. 재생성이 끝나기 전까지 **기존 수치를 현재 성능으로 인용하지 않는다.**
3. `md/RESULTS_*.md` 중 이번 재생성으로 낡게 되는 문서에는 세대 배너를 단다.

## 7. 리스크

| # | 리스크 | 대응 |
|---|---|---|
| R1 | 먼 창고 → 복귀 주행이 후반 혼잡과 겹쳐 mid-build Replace 교착 | `mark_recovery_spare!`(RVO 우선권)가 이미 있음. D 스윕이 이걸 잡는 장치 |
| R2 | RelocateBuild 로 빌드가 평행이동해도 창고는 고정 | 절대 좌표 선택의 당연한 귀결. 의도된 동작으로 문서화 |
| R3 | 저장된 애니메이션 프레이밍 변화 | 렌더 줌 확인을 검증 항목에 포함 |
| R4 | 재생성 비용(수 시간) | 별도 단계로 분리, 순차 실행, 중간 산출물 보존 |
| R5 | 배터리 심각도 분기가 창고까지 도달 안 할 가능성 | 4-3의 검증을 첫 작업으로 배치 |

## 8. 열린 항목

- **D 기본값**: 25.0 으로 시작하되 §5 스윕 결과로 확정한다. 스윕 전에는 잠정값이다.
- **조합 케이스 오라클**: 이번 범위 밖. 표에서 `—` 로 남고 각주로 이유를 밝힌다.
