# G3 — A2 어휘 실현 가능성 오라클 (2026-09-23)

무료, 서비스 없음. `REPAIR_ABLATION=all` 팔(A2)에서 **광고된 이름만** 쓰는 손 오라클
(`tools/fixtures/oracle_zone_clear_nobase.json`, `OracleZoneClearNoBase!`)을 canonical 정책·
`DEMO_ROUTER=0` 으로 2 모델 × {zone, all3} × 30 시드 = 120 판 돌렸다. 드라이버 `run_g3.sh`,
집계 `tally.py` → `tally.json`(120행). 로그·스트림은 디스크에만(`log/`, `streams/`, 커밋 안 함).

## 결과 — 106/120 완주, `denied>0` 0판, `armed=true level=all` 120/120

| 셀 | 완주 | 미완주 시드 | 완주 판 closed |
|---|---|---|---|
| tractor zone | **27/30** | 2, 7, 27 | 287 |
| tractor all3 | **27/30** | 2, 7, 27 | 287 |
| xwing zone | **26/30** | 10, 13, 24, 28 | 684 |
| xwing all3 | **26/30** | 10, 13, 24, 28 | 684 |

- `[ablation]` 줄 120/120, 전부 `level=all armed=true denied=0 exempt=4 ladder_zone_skipped=0
  ladder_zone_fired=0 detail=exempt:monitor_record=1,exempt:policy_payload=2,exempt:reference_label=1`.
  실행 가드가 한 번도 안 던졌다 = 오라클 body 는 차단 목록의 어떤 함수에도 (간접적으로도) 닿지 않았다.
- 120 판 전부 같은 픽스처(`sha256[1:16]=3c4260409ca94b03`)를 배너에 찍었다.
- 오라클 status: `translated` 112, `residual_blocked` 8(tractor s26·s27, xwing s12·s24 × 두 케이스).
  s26·s12 는 `residual_blocked` 인데도 완주했다(결정 시점의 막힘이 나중에 풀림).
- 미완주 시드는 zone·all3 에서 **똑같다**(존 세계가 시드로 같다) — 실패는 존 수리 쪽에 있다,
  battery·fault 쪽이 아니다.

### 미완주 7 시드의 한 줄 원인(로그에서)

| 시드 | 오라클 | 끝 `[score]` | 읽기 |
|---|---|---|---|
| tractor s27, xwing s24 | `residual_blocked`(12 걸음, 1.78 / 1.70 이동) | n_blocked=1, project_blocked | **방향 고정**(적치원 평균 − 존 중심)으로는 12 걸음 안에 못 비운다 |
| xwing s13, s28 | `translated` | n_blocked=2, project_blocked | 결정 시점 0 이었는데 끝에 2 — 여유 3 걸음이 **확인 없이** 먼 쪽 목표를 존 쪽으로 밀었을 가능성(미확정) |
| tractor s2, xwing s10 | `translated` | n_blocked=0, `n_agent_trapped=1`, 정지 | 존 안에 갇힌 주체(로봇·운반 유닛 위에 존이 생김) |
| tractor s7 | `translated`(1.48 이동) | n_blocked=0, 정지 closed=246 | 미분리 |

이 표는 오라클의 **한계**이지 A2 어휘가 못 푼다는 증거가 아니다(오라클은 탐색하지 않는 고정 방향
휴리스틱이다). Task 13 의 "오라클 완주 시드" 조건은 위 표의 완주 시드다.

## 오라클 개정 기록(4회, 상한 5)

어휘 시험(`test/oracle_nobase_uses_only_a2_vocabulary.jl`)은 매 개정 뒤 통과했다(v0 만 실패 — 그것이 개정 1 의 원인).

| # | 원인(관측) | 변경 | 결과 |
|---|---|---|---|
| 1 | v0 등록 거절 `reject:impl_unknown_call:Translation` — LazySets·CoordinateTransformations 둘 다 `Translation` 을 export 해 CB 안에서 모호 | `Translation(...)∘g` 대신 `typeof(g0)(g0.linear, g0.translation .+ dv)` | 어휘 시험 통과(6/6) |
| 2 | 파일럿 1(tractor·xwing zone s1): 집행 중 `MethodError: Ball2{Float64,SVector{2}}(::SizedVector…)` — 적치원 중심이 SVector | 적치원 기록을 `Ball2(Vector{Float64}(b.center[1:2]) .+ Δ, Float64(b.radius))` 로(엔진과 같은 꼴) | 파일럿 2: 둘 다 `translated`, 끝 n_blocked=0 인데 **정지** closed=63 / 131 |
| 3 | 진단(아래 D1 절): ① 한 걸음 여유는 목표 2 개를 TangentBug 팽창 띠(`r_zone+r+buffer`, buffer=0.14)에 남긴다 ② 씬 본체 표류 | 여유를 존 반지름 1 걸음 → **3 걸음** | 파일럿 3: 여전히 정지 closed=64 / 131 → 남은 원인은 표류 |
| 4 | D1 적용(`resync_scene_to_schedule!` 공개, 커밋 `4a385c63`) | 매 이동 뒤 `resync_scene_to_schedule!(env)` | 파일럿 4: **둘 다 완주** 287 / 684 (엔진 translate 오라클 G2 none 과 같은 287) |

## D1 판정 — **노출함**(`resync_scene_to_schedule!(env) = _resync_scene_drift!(env)`, 세 팔 전부 광고)

증거(모두 `diag/` 아래, 진단 전용 픽스처 — 미광고 이름을 쓰므로 어휘 시험을 **통과 못 한다**:
음성 대조로 돌리면 `_resync_scene_drift!`·`has_parent`·`get_start_node`·`node_id`·`get_node`·
`TransportUnitNode`·`matches_template` 등 11 개 이름이 광고 밖으로 잡힌다):

1. 표류는 실재한다: 오라클 이동 직후 free 씬 노드 중 스케줄 start 위치에서 로봇 반지름(0.14) 넘게
   벌어진 것 — tractor **55**, xwing **145** 개. `_resync_scene_drift!` 한 번에 0.
2. 반사실(같은 시드·같은 이동 크기 0.516 / 0.443, 3 걸음 여유):
   - 동기화 **없음**(오라클 v3, 광고 어휘만): 정지 closed=64 / 131.
   - 동기화 **있음**(진단 x3 = v3 + `_resync_scene_drift!` 한 줄): **완주** 287 / 684.
   유일한 차이가 그 한 줄이다.
3. 1 걸음 여유 + 동기화(진단 x1): 정지 147 / 516, `navband=2` — 여유와 표류는 **둘 다** 필요했다.
4. A2 광고에 대응물이 없다: 씬 본체를 옮기는 광고 동사는 범용 `set_desired_global_transform!` 와
   `set_scene_tree_to_initial_condition!`(씬 **전체**를 초기 조건으로 되돌린다 — 로봇·이미 놓인 부품까지)
   뿐이고, "어느 본체가 아직 free 인가"·"그 운반 유닛 씬 노드"를 가리키는 광고 이름이 없다.

적용(커밋 `4a385c63`, 따로): `src/respec/zone_facts.jl` 에 래퍼+독스트링, export, 산출물 3 개 재생성
(메서드 +1: 228 / 223 / 220), 핀 갱신(closure 227→228·198→199, minted_registration advexp 174→175).
`test/world_interface_current.jl`·`world_interface_closure.jl`·`minted_registration.jl`·
`repair_ablation_core.jl` 전부 EXIT=0.

## 🔴 브리프 드라이버의 결함 — `DEMO_SYNTH_FIXTURE_KINDS=zone` 이 빠져 있었다

첫 120 판 스윕(`aborted_nogate/`, 58 판에서 중단)은 이 변수 없이 돌았다. 그러면 픽스처가 **모든**
결정에 꽂혀, all3 의 battery·fault 결정에서도 존 오라클이 등록·집행되고 `handled=true` 가
그 결정의 SwapBattery / Replace 를 건너뛴다(`render_demo.jl` 의 `_m.handled && return nothing`;
`policy.jl` `SYNTH_FIXTURE_KINDS` 독스트링이 2026-09-22 R2b 에서 이미 적은 기전). 실측: tractor
all3 **0/28**, zone 27/30. 드라이버에 `DEMO_SYNTH_FIXTURE_KINDS=zone` 을 더하고 120 판을 **처음부터
다시** 돌렸다(위 표). 새 스윕의 all3 로그에 `gated OFF — routing_kind=battery` 60 · `fault` 60 줄,
zone 로그엔 0 줄(zone 판의 결정은 zone 하나뿐 — 게이트가 무동작).
⟹ Task 12–13 의 격자·재생에서 픽스처를 쓸 때도 이 변수가 필요하다.

## PIN 확인

스크래치 GRID_OUT 에 `REPAIR_ABLATION=all campaign.py init --lanes canonical --cases zone`(HEAD 654ec60b,
런 없음) → `set_env` = 브리프 PIN + `REPAIR_ABLATION=all` 정확히 일치. 드라이버는 `REPAIR_ABLATION=all` 을
명시한다. 부모 셸과 tmux 전역 환경에 분류된 설정 변수가 없음을 확인했다(`run_env` 처럼 지우지 않으므로).

## 파일

- `run_g3.sh`, `tally.py`, `tally.json`, `README.md` — 커밋됨
- `log/`, `streams/`, `anim/`, `drive.log`, `drive.out` — 본 스윕(디스크만)
- `pilot_v1/`…`pilot_v4/` — 파일럿 로그, `diag/` — D1 진단 픽스처·드라이버·로그, `aborted_nogate/` — 게이트 없는 첫 스윕(디스크만)
