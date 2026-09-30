# render 엔진 라벨 계약 (selfimprove, 계획서 Task 9 · spec §11.4 · §0.0 R10) — 2026-09-29

**v1 이상 데이터셋은 이 계약의 행만 쓴다.** v0 은 gen_oracle 33행 그대로(기준선). 두 엔진의 라벨을 한
데이터셋에 섞지 않는다 — 헤드 B·C 가 절대 타깃을 학습하므로 엔진 상수 차이가 ΔĴ 에서 상쇄되지 않는다.

모든 kind · 모든 팔 공통. 구현: `tools/selfimprove/rows.py`.

| 행 필드 | 원천 | 정의 |
|---|---|---|
| `complete` | `[score] complete` | `project_complete(env)` |
| `closed` | `[score] closed` | 판 끝 closed 수 |
| `total` | 로그 `n_total` | t₀ 스케줄 노드 수 |
| `makespan` | 스트림 마지막 프레임 `sim_t` | 판 끝 sim 시간 — 완주·미완주 공통 (미완주는 J 의 `tie_eps` 항에만 들어가고 헤드 B 는 완주 행만 본다) |
| `energy_J`, `total_energy_J` | 스트림 마지막 프레임 `battery.total_energy_J` | 판 전체 누적 |
| 결정 피처 11개 | 그 판 **첫** 해당 kind 결정의 `input.router.ood_features` | `dspy_service._surro_row` 와 같은 필드·같은 None 규약(`soc`→NaN, `zone_overlap`·`zone_nav_*`→−1.0) |
| `valid_mask` | 같은 결정의 `input.router.valid_menu` | `[]` = 전용 메뉴 없음 = 레지스트리 kind 기본표(policy.jl 규약). A₀ 재라벨은 NOOP 판의 메뉴를 인스턴스 메뉴로 쓰고 메뉴 밖 강제 팔 판은 버린다 |
| `macro`, `macro_name` | 팔 id, 그 버전 레지스트리 이름 | NOOP=0 |
| `vocab`, `train_kinds`, `objective_hash` | 새 버전 도장 | 전 행 재도장 |
| `label_engine` | 상수 `"render"` | |

## 새로 싣는 결정 기록 (Julia `decide_all`)
- `rt["ood_features"]` (Task 5) — 결정 시점 피처 원본.
- `rt["valid_menu"]` (Task 9) — `valid_macros(env, truth)`. 이전 스트림에는 메뉴가 없었다(`candidates` 는 고른 팔 하나뿐).

## 변환 동등성 (실측)
`rows.parity_ok`: 학습 행으로 계산한 `descriptors_from_row` 6-벡터 == 그 결정의 스트림 `descriptors`(1e-9).
2026-09-29 보정 판 24개의 결정 24개(fault·battery·zone)에서 **불일치 0**.

## DEMO_FORCE_MACRO 확인 (실측)
tractor fault s101, canonical + `DEMO_FORCE_MACRO=NOOP`: 결정 verdict `FORCED→NOOP (control run; policy chose Replace)`,
`complete=false closed=193` (같은 판 canonical 은 Replace 로 `complete=true closed=287`). render 엔진 `decide_all`
경로에서 집행이 실제로 바뀐다. ⚠️ 강제는 **메뉴와 무관하게** 모든 결정에 걸린다 — 그래서 메뉴는 기록에서 읽는다.
