# STATUS — 현재 상태 · 재개 지점 (2026-08-06)

> 개념·확정결과·함정 목록은 `README.md`. 이 파일은 **지금 어디까지 왔고 다음에 뭘 하는가**만 적는다.
> 통합 2026-08-06: `NIGHT_2026-08-04.md` · `PLAN_COMPLETION.md` · `MORNING_2026-08-03.md` ·
> `PLAN_0804.md` · `NIGHT_2026-08-02.md` 의 상태 부분을 여기로 모았다.

---

## 0. 한 눈에

| 작업 흐름 | 상태 | 막힌 것 / 다음 한 수 |
|---|---|---|
| 구역(zone) 결정 | STEP 1~11 **구현·검증 완료** | 인과 규칙이 **1/2** — 개입의 파괴력을 규칙에 넣어야 함 |
| battery / fault 라벨 | 피커·심각도 사다리 **재설계 완료** | 조밀한 발화점 격자 라벨링, μ-키용 makespan 헤드 |
| λ → μ 전환 | **결정 완료, opt-in 구현 완료** | 배포 적용은 makespan 예측 헤드 대기 |
| 라우터 / novelty | battery FAMILIAR **PASS** | surrogate 재학습(N44_PLUS78, 2026-08-07) 완료 — zone 은 좋아졌다(옳은 결정 32%→68%, zone 7/7, RESULTS_LLM7H §5-f-이후), battery 는 그대로다(0/6, SwapBattery 는 점수는 나도 덜 선호됨); 라우터 **에스컬레이션 경로**의 실측은 여전히 미측정 |
| 무작위 OOD 스트림 평가 | **20판 측정 완료** (`md/RESULTS_LLM7H.md`) | zone 기준 라벨 n=2 확대 · Ch-E(자기일관성/기권) |
| 행동 어휘 (Ch-A) | **단일화 완료** — `action_registry.json` + `audit_action_vocab.py` 6/6 | **완료(우회)** — 기본 `MACROS` 는 그대로 두고 `DS_EP_MACROS="0,3,7"` 로 zone 표적 라벨(Task 5) + `battgrid`(Task 3)로 8 확보 → 배포 surrogate 재학습(`N44_PLUS78`) 완료 |
| 데이터 재생성 | `lad_*` 는 수정 후 데이터 | `hz_*`·`rb_*`·`openworld` 는 shim 버그 시기 |
| 덱 데모 영상 | V1·V2·V4 완료 | V3(RL) 미렌더 |

---

## 1. 구역(zone) 결정 — STEP 1~11

**완료.** 전문은 `ZONE_REDESIGN_STEP1_7_2026-08-05.md`(STEP 8~11 포함).

- STEP 1~3 배선(위반 술어 계산기 · 최소수복 규칙 · 원시값 관측 어휘)은 전부 작동하고 단위검사 GREEN
  (`zone_diagnosis` 42/42 · `zone_corridor` 25/25 · `test_policy_zone` 19/19 · `test_router` 8/8).
- STEP 6 이 그 배선으로 만든 첫 측정이 **STEP 2 규칙을 반증**했다 — `H(best|zone)=0`,
  8/8 전부 NOOP 최선. 원인은 **덮였다(coverage) ≠ 막혔다(blockage)**.
- STEP 8 이 그 인과를 코드로 특정했다: 구역은 `enforce_restriction_zone_clearance!` 에서
  **RVO 에이전트만** 밀어내는데, `root_deposit_goals` 가 세던 목표는 `LiftIntoPlace`(화물 변환을 직접
  적분, RVO 경유 없음)였다. 구역이 막을 수 있는 것은 `RobotGo`/`TransportUnitGo` 목표뿐이다.
- STEP 10 이 **같은 kind 안에서 정답이 뒤집히는 두 사건**을 처음 만들었다(복구 사다리 ON, 전 팔 동일):

  | 가족 | 진단 | NOOP | RelocateBuild | 최선 |
  |---|---|---|---|---|
  | blocking (nav 목표 위) | root 0/8 · **nav_blocked 3** | stalled 254 | **complete 279** | RelocateBuild |
  | core zone (root 목표) | root **8**/8 · nav_blocked 1 | stalled 232 | stalled 197 | NOOP |

  `H(best|zone) = 1.000 bits` · 동점률 0%.
- STEP 11 이 팀 슬롯 술어의 **인과**를 확인했다(런 내 반전: 구역 ON 1200스텝 미형성 → OFF 5스텝 만에 결합).

### 남은 문제 — 인과 규칙이 1/2 이다

| 사건 | 실측 최선 | 커버리지 규칙 | 인과 규칙 |
|---|---|---|---|
| blocking (root 0, 막힘 3) | RelocateBuild | `:noop` ✗ | `:relocate_build` ✓ |
| core zone (root 8/8, 막힘 1) | NOOP | `:relocate_build` ✗ | `:relocate_build` ✗ |

> **막힘 > 0 은 개입의 필요조건이지 충분조건이 아니다.** 수복 자체의 파괴력이 함께 들어가야 한다.

그래서 `ZONE_CAUSAL_RULE` 은 **계속 opt-in(기본 OFF)** 이다. 1/2 짜리 규칙을 기본으로 켜는 것은 정직하지 않다.

### 다음 (우선순위)

1. **개입의 비용을 규칙에 넣기.** 임계값 튜닝이 아니라 두 양의 비교다 —
   (a) 막힌 노드들이 잠그는 **하류 작업량**, (b) `translate_whole_build!` 가 흩뜨리는 **진행 중 작업량**
   ((b)는 이미 측정 가능: cov 가족 232 → 197 = −35).
2. **다중 구역 주입기.** `:disconnected`(통로 봉쇄)는 구역이 하나면 무한 평면에서 원리적으로 안 생긴다.
   고리형(≥3개) 주입을 만들어야 그 가지가 실측에서 처음 발화하고 `:line_stop` 게이트도 의미를 갖는다.
3. **표본 확대** — 지금 n=2 사건, seed 1, 발화점 1(closed=58).
4. **라벨·정책 경로에 blockage 원시값 싣기** (`gen_oracle_dataset.jl::capture_features` /
   `policy.jl::ood_features`) — STEP 3 과 같은 **opt-in 열**로.

### 데모 쪽 확정 사항

`DEMO_ZONE_MODE` 기본값 = **`blocking`**. 출하 기본값으로 **순차** 실행한 최종 검증:

| 케이스 | zone 결정 | 결과 |
|---|---|---|
| `zone` | rule `NOOP` / surrogate `NOOP` / **LLM `RelocateBuild`** | COMPLETE 275 |
| `fault_zone` | 〃 + `Replace` | COMPLETE 287 |
| `battery_zone` | 〃 + `Replace` | COMPLETE 271 |

**구역이 들어가는 모든 OOD 가 완주하고, 세 판 모두 규칙은 절제 / LLM 은 개입으로 갈린다.**

> ⚠ **컴파일된 DSPy 프로그램은 zone 을 못 읽는다.** `dspy_real_program_gpt4o.json` 은 MIPROv2 가
> **배터리 전용 데이터셋**에서 뽑은 것이라 zone·기하·RelocateBuild 어휘가 통째로 없고 demo 4개도 전부
> battery 다. 그 프로그램은 `SEED_DOC` 을 **대체**하므로 zone 데모는 **seed 프로그램으로 돌려야 한다**.

---

## 2. battery / fault — 표적·심각도 재설계

**완료.** 전문은 `BATTERY_FAULT_REDESIGN_2026-08-05.md`, 선행 작업은 `FIRE_TIME_RELABEL_2026-08-05.md`.

- **표적 피커 고침**: 옛 피커는 진행도 **0.51 부터 100% 주차된 예비**를 쐈다(측정). 새 피커는
  "안 닫힌 `FormTransportUnit` 팀의 멤버". → `FIRE_TIME_RELABEL` §3-a 의 "후반엔 흡수" 결론 **철회**.
  재라벨 결과 **NOOP 은 6개 발화점 전부에서 미완주**.
- **심각도 사다리 재설계**: `0.02 / 0.3 / 0.5` + 엔진에 **감속(derate) 구간** 신설 + 심각도를
  **결과 SoC 절대값**으로 정의(`DS_BSOC_MODE=abs`). 옛 `0.05/0.12` 는 둘 다 정지 임계(0.15) 아래라
  **거동이 동일**했다. 세 칸이 이제 각각 다른 기준으로 갈린다:

  | 칸 | 갈리는 기준 |
  |---|---|
  | 0.02 | **완주 여부**(feasibility) |
  | 0.30 | **시간**(완주는 하되 손해) — 단 섭동 바닥(0.775 s)을 확실히 넘는 건 6개 중 1개뿐 |
  | 0.50 | 사실상 무영향 = **경험적 귀무**(이 칸이 섭동 바닥을 측정해 준다) |

- **fault 발화점**: `pick_hotswap_fault_target` 신설로 후보가 진행도 전 구간에서 10개(옛 피커는 58 이후 0).
  6개 발화점 전부에서 `Replace(pending>0) / NOOP(pending=0)` 로 갈리고 **seed 2 로 재현**됐다.

### 다음

1. **조밀한 발화점 격자 라벨링** — fault/faultidle 11점, battery 10점(150·160·170 추가). battery 격자가
   140~180 에 몰린 이유는 정답이 뒤집히는 경계가 progress 0.45~0.58 사이인데 기존 6점 격자에 그 구간
   점이 **하나도 없기** 때문이다.
2. **남은 오차 22/108 의 성질 재측정** — 지금은 오답의 실제 손해가 전부 ≤3.0 노드(중앙값 0.9)이고
   108 중 61 개가 near-tie 다. 유력 가설은 **해상도 문제**(값 회귀의 잡음 > 결정 마진) →
   레버는 decision-focused 목적함수(SPO+ 계열). 조밀 격자가 쌓인 뒤 "해상도인가 데이터 공백이었나"가 갈린다.
3. **데모 세계 ≠ 라벨 세계 정렬** (의도적 보류). `tools/demos.jl:2793` 정지 임계 0.02 vs 라벨러 0.15,
   데모는 감속 미사용. 덱 영상을 다시 렌더링할 때 맞춘다 — **녹화 산출물을 조용히 바꾸지 않으려고** 뒀다.

---

## 3. λ → μ 전환

**결정 완료 · 비파괴 opt-in 구현 완료 · 배포 미적용.** 근거는 `README.md` §4.

`export_surrogate.py --cost-time --mu M` 이 μ-키를 켠다(기본 꺼짐, 기존 `--cost-aware --lam` 경로 불변).

**배포 선행조건**: μ-키는 랭킹에 `makespan` 이 필요한데 현재 배포 surrogate 는 **단일 출력**(`closed`)이다.
덤프에 `makespan` 열은 이미 있으므로 **두 번째 모델을 export** 하면 되지만 별도 작업이다.
그때까지 배포 경로는 λ-키(λ=3)를 쓰되 "비용을 학습 목표가 아니라 결정 규칙으로" 만 먼저 적용한다.

> μ 스칼라를 **회귀 목표로 그대로 쓰면 안 된다** — 비용/시간 항이 너무 작아 학습이 안 된다
> (실측 LOO subopt_norm: λ-키 목표 0.148 vs μ-키 스칼라 목표 0.350). 라벨로서의 μ-키와 회귀 목표로서의
> μ-키는 다른 문제다.

---

## 4. 라우터 / novelty

**합격 판정 PASS.** `battery must read FAMILIAR`: p 0.0116 → **0.321**.
축 감사에서 DEGENERATE 축 소멸(`progress` sd 0.00593 → **0.217**). Julia↔Python 파리티 33/33.

배포 파일: `novelty_calibration.json`(126 instance), `novelty_calibration_no_zoneblk.json`(97).
직전 버전은 `*.bak_2026-08-04` 로 보존. CANONICAL(`openworld_merged.jsonl`)은 **손대지 않았다**
(발표된 subopt_norm/frontier 숫자의 근거).

에스컬레이션 조건은 현재 4개: (a) 상태가 낯설다(novelty) (b) 그 매크로를 학습한 적이 없다(**행동 표현력**)
(c) 어휘 자체에 수복이 없다(`:line_stop` — 작업공간이 무한이라 거의 잠들어 있음)
(d) 서로게이트 특징 벡터에 이 위반을 담을 **열 자체가 없다**(**관측 표현력**, `n_nav_blocked > 0`).

**미측정**: surrogate 재학습을 안 했으므로 "라우터가 surrogate 로 보낸 뒤 실제 결정이 좋아지는가"는 아직 모른다.
재학습 = 데이터셋을 가리키고 재시작(`EVAL_DATA=oracle/out/firegrid_merged.jsonl` → 108 instance).
기본값은 벤치마크 일치를 위해 `HS_N44` 로 **핀 고정**되어 있다.

---

## 5. 무작위 OOD 스트림 평가 — **닫혔다 (2026-08-06)**

> 전문: **`md/RESULTS_LLM7H.md`**. 아래 원문은 이 공백이 무엇이었는지의 기록으로 남긴다.

**결과 요약 (5 시드 × 4 정책 = 20판, 사건 4개/판, fault·battery·zone 한 추첨).**

| 정책 | 완주율 | 기준행동 적중 | 완주판 sim s | J/closed |
|---|---|---|---|---|
| `noop` 바닥선 | **0/5** | 0/17 | — | 856 |
| `canonical` 규칙 | 4/5 | 6/19 | 66.3 | 971 |
| `surrogate` RF | 4/5 | 6/19 | 66.3 | 971 |
| **`dspy` LLM** | **5/5** | **18/20** | **41.0** | **538** |

세 가지가 새로 밝혀졌다:
1. **바닥선이 실제로 바닥선이다** — 개입 없으면 5판 전부 미완주(진행도 0.66). 아래 버그를 고치기
   전에는 noop lane 이 사실 canonical 이었으므로 이 대조가 성립한 적이 없었다.
2. **배포 서로게이트는 이 스트림에서 규칙과 구별 불가능하다** — 49개 결정 전부 `enacted=surrogate`
   인데 매번 규칙과 같은 팔. 두 정책을 가르는 팔(7 `RelocateBuild`, 8 `SwapBattery`)이 전부
   학습 지원(`[0,1,2,3,4]`) 밖이라 **나을 여지 자체가 없다**.
3. **어휘 한 줄이 적중률을 만들었다** — `SwapBattery` 를 LLM 어휘에 넣자 battery 축이 0/6 → 6/6.
   넣기 전에는 맞히는 것이 원리적으로 불가능했다.

시드 5개로는 짝지은 부호검정의 최소 p 가 **0.062** 라 유의성은 주장하지 않는다(함정 18).

### 고친 버그 2개

- **`DEMO_POLICY=noop` 이 안 먹던 원인 규명·수정.** 환경변수 전달이 아니라 `policy.jl::decide_all`
  의 `requested = rt["enabled"] ? rt["target"] : POLICY` 였다. `DEMO_ROUTER` 기본값이 `auto` 라
  라우터가 켜지고, 라우터 target 은 surrogate/dspy 뿐이므로 noop 은 **구조적으로 실행 불가**였다.
  이제 `POLICY=="noop"` 이면 라우팅을 끈다. 겸해서 **표현력 에스컬레이션 두 곳도 라우터가 켜졌을
  때만** 발화하게 했다 — 예전엔 `DEMO_ROUTER=0` 인 고정 정책 비교에서도 조용히 dspy 로 넘어갔다.
- **빌드 중반 `RelocateBuild` 가 시뮬을 죽이던 버그.** `@assert has_edge(scene_tree, assembly, id)`
  (실측 closed=151, Δ=2.4 m). `close_node!` 에 이미 있던 완화 코드가 `RESPEC_ENABLED` 로 게이트돼
  있었는데, `run_demo.jl` 은 respec **큐**를 우회하려고 그 플래그를 끈다. `RESPEC_DRIFT_REPAIR`
  (기본값 = `RESPEC_ENABLED` 를 따라감)로 분리해 기존 경로는 그대로 두고 데모만 켰다.

### 원래 기록 (공백이 무엇이었나)

> 지금까지 저장소의 **모든** 평가는 사건 시점이 고정이었다(오라클=격자, 데모=슬롯 `[0.10,0.32,0.55]`).
> 즉 "적응적"이라는 주장의 근거가 사실상 한두 개의 대본이고,
> **무작위 스트림 위에서 정책을 비교한 적은 한 번도 없다.**

하니스는 완성됐다: `run_demo.jl` 의 `DEMO_OOD_SEED`(>0 이면 `schedule_random_ood!` 로 시점·종류·심각도 추첨,
0=기본은 옛 고정 슬롯 그대로) + `policy.jl` 의 `noop` 바닥선 정책 + `tools/monitor/run_ood_sweep.ps1` +
`ood_sweep_report.py`(완주율 Wilson CI · **같은 ood_seed 끼리 짝지은** 부호검정 · 결정 분포 · 발화 진행도).

**작동 확인됨**: `DEMO_OOD_SEED=1` 이 fault/battery 3건을 progress 0.15 / 0.39 / 0.60 에 뽑았고 그 판은 완주했다.

**미해결 버그 — `DEMO_POLICY=noop` 이 안 먹는다.** noop lane 이 3건 모두 `Replace` 를 실행했고
요약 행의 `policy` 도 `canonical` 로 찍혔다(= Julia 안에서 기본값). 환경변수 전달은 범인이 아니다
(같은 경로의 `DEMO_N`·`DEMO_OOD`·`DEMO_OOD_SEED` 는 전부 반영됨) → `policy.jl` 의 `noop` 분기,
또는 그것을 읽기 전에 죽는 무언가를 봐야 한다. exit code 1 의 원인도 같이. 로그가 **UTF-16LE** 라
grep 이 안 걸리므로 스위프 스크립트에서 인코딩을 UTF-8 로 고정할 것.

**재개 순서**: 버그 수정 → 4판 스모크로 바닥선(noop)과 상한선(canonical)이 실제로 갈리는지 확인 →
20 시드. canonical 이 이 스트림에서 완주했으므로, 바닥선이 고쳐진 뒤에도 둘 다 완주하면 난이도
(스페어 3 / `SWEEP_N` / `severe_frac`)를 올려야 측정이 된다.
정책 비교 시 라우터는 **끈다**(`DEMO_ROUTER=0`) — 켜두면 "surrogate 를 쟀다"는 판이 사실은 LLM 판이 된다.

---

## 6. 데이터 자산 — 무엇을 믿을 수 있나

| 폴더 | 상태 |
|---|---|
| `oracle/out/lad_*` (seed 401~404) | **수정된 shim.** 1사건 사다리 8칸, 32 instance 전부 결정적. 핵심 주장의 근거 |
| `oracle/out/nom30/` | 무OOD 30 seed (완주 **97%±3**, makespan 21.1±0.3) |
| `oracle/out/fix_core/` | shim 수정 효과 증명용 |
| `oracle/out/zcausal_reform/` | zone STEP 10 2차(복구 사다리 ON, 전 팔 동일) |
| `oracle/out/battgrid_0805_s1.jsonl` | 새 심각도 사다리 18 instance / 54 row |
| `oracle/out/firegrid_merged.jsonl` | 발화점 재라벨 병합(414행 / 108 instance) |
| `openworld_merged.jsonl` (CANONICAL) | 발표 숫자의 근거 — **건드리지 않는다** |
| `oracle/out/hz_k1`, `hz_fb`, `rb_*` | **shim 버그 시기** — 완주율 신뢰 불가, 재생성 대상 |
| `oracle/out/zgrid_0805/` | zone STEP 6 격자. `admissible` 열은 에피소드 모드라 **구조적으로 무의미** |

재생성 우선순위: `hz_k1`/`hz_fb` 는 비용이 크고 지금 `lad_*` 32 instance 로 핵심 주장이 서므로 **급하지 않다**.

---

## 7. 덱 데모 영상

V1(baseline) · V2(LLM zone respec) · V4(surrogate stream, 헤드라인) **렌더 완료** → `results/deck/`.
**V3(RL on the same fault) 미렌더** — `tools/demo_rl_replace_anim.jl`.

네 클립 모두 같은 경로(`results/tractor/.../visualization.html`)에 쓰므로
`tools/render_deck_videos.sh` 가 각각을 `results/deck/V<n>_<name>.html` 로 복사한다.
브라우저 화면녹화 → mp4 → 덱 삽입만 수동이다.

---

## 8. 압축된 이력 — 어떻게 여기까지 왔나

| 시점 | 사건 |
|---|---|
| ~2026-07-14 | mid-build Replace 가 완주 못 함. 엔진 버그 2개 수정(RVO 등록 크래시 / 오라클 reform 400→120). 원인을 fault 타깃·분산 replace 로 추적했으나 **엔드게임 팀 재형성 교착**이 진짜 벽이었다 |
| 2026-07-15 | **정체성보존 hot-swap** enact 로 우회 — 스케줄 재각인이 없으므로 cyclic OpenBuildStep 교착이 **구조적으로 불가능**. 6/6 완주. "구조적 한계" 결론 뒤집힘 |
| 2026-07-30~31 | E1~E4 · 비용평가 정리, verify.py 8/8 |
| 2026-08-02 | md/ 1차 통합(21→4). 동점 85% 의 기전이 **완주율**임을 규명. STEP 6 부정 결과 |
| 2026-08-03 | 매크로 7 `RelocateBuild` 신설 → zoneblk 동점 100%→0%. 야간 분석: 상태는 정보를 담음(p=0.005), 규칙표는 미돌파(p=0.360) |
| 2026-08-04 | **shim 버그 발견** — 오라클 자가복구가 통째로 꺼져 있었다. 수정 후 사다리 재생성 → `H(best|zoneblk)=1.00 bits`. "개입이 빌드를 구해내는" 최초의 렌더 판 |
| 2026-08-05 | 구역 재설계 STEP 1~11(커버리지 → 막힘), 배터리/fault 표적·사다리 재설계, λ→μ 결정, MILP 비결정성 규명 |

---

## 9. 다음 한 수 (사람이 결정할 것)

1. **`DEMO_POLICY=noop` 버그 → 무작위 스트림 스위프** (§5). "적응적"이라는 주장의 유일한 직접 증거가 여기 있다.
2. **개입의 파괴력을 zone 규칙에 넣기** (§1). 지금 1/2 인 것을 2/2 로.
3. **makespan 예측 헤드** (§3). μ-키 배포의 유일한 선행조건.
4. **surrogate 재학습 + 라우터 사후 효과 측정** (§4).
5. **B1 능력상실 (진짜 미지 사건 만들기)** — 엔진에 "로봇이 특정 능력만 잃는다"는 개념 자체가 없다.
   훈련 어휘 밖의 사건을 만들려면 여기서 시작해야 하고, 그때라야 §1 용어의 **OOD 실험**이 처음 성립한다.
6. **A0 다중 spec 디스패처** — 서로 다른 종류의 제약을 묶어 내면 지금은 하나만 실행되고 나머지는 조용히
   버려진다. 행동공간을 조합으로 넓히는 계획 전체가 여기 막혀 있다(`PLAN_ACTION_GROWTH.md` §2 정정).
