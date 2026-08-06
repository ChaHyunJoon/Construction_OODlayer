# wm4spacecraft_manufacturing — 단일 진입점

*통합 2026-08-02. 이전에 md/ 에 21개 문서가 흩어져 있던 것을 이 파일 하나로 합쳤다.
남긴 문서는 3개뿐이고, 나머지 18개의 내용은 여기 흡수했다(§8 에 목록·복구법).*

**읽는 순서**: §1 현재상태 → §2 용어 → §3 아키텍처 → §7 함정목록.
그 다음 필요할 때만 `PLAN_ACTION_GROWTH.md`(다음 계획) / `DESIGN_ASSIMILATION.md`(C1~C4) / `RESULTS.md`(E1~E4 원본).

---

## 1. 현재 상태 (2026-08-02)

### 확정된 것
- **E1~E4 완료** — surrogate 가 플래너 호출 0회로 오라클 품질 결정 (§4)
- **비용 평가 완료** — 0.10 ms vs 64 s = 1.9M× (§4)
- **STEP 1·2 완료** — 확률적 고장 프로세스 + K-rollout MC Q 라벨러
- **STEP 6 완료** — 옵션 제한의 대가는 **관측되지 않음** (gap 0.00 < 노이즈 바닥 2.05)

### 지금 막혀 있는 것 — **이것 하나가 다른 모든 측정을 막고 있다**
> **평가셋의 85% 가 동점이다.** 모든 팔의 비용이 완전히 같아 어떤 정책도 regret 0 을 받는다.
> 결정이 없는 데이터에서는 T1(φ 충분성)도, Router 우위도, 편입 게이트도 전부 측정 불가.

그 결과 현재 미확정:
| 항목 | 상태 |
|---|---|
| T1 (φ 가 충분한가) | **판정 불가** — 결정적 instance 5개, 검정력 부족 |
| Router 가 규칙을 이기는가 | **우위 없음** (짝지은 부호검정 p=0.82) |
| T2 (Markov 인가) | 반증 실패 (통과가 아님) |
| VoI 게이트 | 무작위와 구별 안 됨 |

### 다음 (비용순)
1. ~~값 2층 분해 (완주확률 × makespan)~~ — **완료 2026-08-02 밤** (`value_two_layer.py`, 항등식 66/66)
2. FQI 부트스트랩 (`next_*` 가 이미 덤프에 있음) — 시뮬 0
3. ~~`always_per_kind` baseline 추가~~ — **완료** (`baselines_eval.py` 의 `rule_table`)
4. φ 에 `usage_r` 추가 — 시뮬 0
5. **창 교정 재생성** — 2026-08-02 밤 가동 중. **K=3 이 아니라 K=1 대량**으로 바꿨다(판당 실측 14분
   → K=3 는 하룻밤에 instance 12개뿐). hazard 증거는 seed 1개만 K=3. → `NIGHT_2026-08-02.md` §2
6. 그 위에서 전부 재측정 — 아침 명령: `python morning_report.py`

> **2026-08-02 밤 핵심 발견**: 동점 85% 는 창 [70,230] 때문이고, **동점률은 완주율의 함수**다
> (완주 26%→동점 53% / 완주 5%→동점 85%, 실측). 게다가 기존 두 데이터셋은 각각 다른 이유로
> 못 쓴다 — [8,60] 은 **τ=0 이 99%**(결정이 배치경계에 몰림), [70,230] 은 **fault 사건 0건**.
> 창 [55,130] 이 둘 다 피하는 구간임을 스모크로 확인했다. 상세: `NIGHT_2026-08-02.md`

---

## 2. 용어 — 2026-08-02 교정 (이전 문서들은 이 구분이 없다)

| 용어 | 정의 | 구성 | surrogate 훈련 |
|---|---|---|---|
| 교란(disturbance) | 엔진의 사건 채널 | `push_ood!` 봉합선 | — |
| **알려진 고장모드 F** | 사전 열거된 닫힌 어휘 | battery, zoneblk, fault | **포함** |
| **OOD 사건 N** | F 밖 = 훈련분포 외부 | **미정의** | **구성상 배제** |

**battery/zoneblk/fault 는 OOD 가 아니다.** surrogate 훈련에 쓰이므로 정의상 in-distribution 이다.
지금까지 이 셋을 "OOD" 라 불러왔으므로, **엄밀한 의미의 OOD 실험은 아직 한 적이 없다.**
LOKO(한 종류 빼고 학습)는 OOD 의 **대리 실험**이지 OOD 자체가 아니다.

**연구 목표**: 미지의 OOD 가 왔을 때 LLM 이 대응을 만들고, 그 대응이 surrogate 의 **행동집합에 편입**되어
다음부터는 surrogate 가 처리한다 → `PLAN_ACTION_GROWTH.md`

---

## 3. 아키텍처 — TAMP 안쪽 / MDP 바깥쪽

```
  바깥 루프 = SMDP  (확률적, 정책을 학습)
     상태 φ(s) ─→ [Router] ─→ surrogate | LLM | oracle
                      ↓
                   행동 a = ConstraintSpec 조합
                      ↓
  ────────────────────────────────────────────────
  안쪽 루프 = TAMP  (결정론적, plan 을 만듦)
     respec → MILP 재배정 → RVO2 항법 → 실행
```

**핵심**: MDP 가 TAMP 를 **대체**하는 게 아니라 **위에 얹혀** 있다.
행동은 로봇 제어가 아니라 **TAMP 문제에 제약을 추가하는 것**이고, 전이 1회 = 플래너 1회다.
그래서 라벨 하나에 20~300초가 들고, 그것이 surrogate 가 존재하는 이유 전부다.

**봉합선**: `src/respec/replan.jl:91` `RESPEC_PRODUCER` — 오라클/규칙/surrogate/LLM 이 전부 여기 꽂힌다.

### 상태가 정의된 곳 (3층)
| 층 | 정체 | 위치 |
|---|---|---|
| 물리 | 시뮬레이터 실제 상태 | `PlannerEnv` (`route_planning.jl:108`) |
| TAMP | 하이브리드(심볼릭+연속) | `scene_tree` + `sched`/`cache` |
| **MDP φ** | 위의 **고정폭 요약 40개** | `capture_raw` → `derive_state_descriptors` |

φ 는 상태의 **정의가 아니라 인코더**다. 그래서 T1(충분성 검정)이 필요하다 — 압축에서 무엇이 날아갔는지 물어야 하므로.

### 행동
`spec_dsl.jl` 의 primitive 5개: `ReplaceAgent` `DeprioritizeAgent` `ForbidAgent` `ForbidZone` `ReformTeam`.
매크로 0~4 는 각각 spec **하나**만 낸다. **`RespecProposal.constraints` 는 벡터이므로 조합 행동은
오늘 당장 실행 가능하며 한 번도 쓰인 적이 없다** — 이것이 남은 유일한 확장 축이다(파라미터 축은 STEP 6 에서 사망).

---

## 4. 확정된 측정 결과

### E1 — 플래너 amortization
| | |
|---|---|
| 결정 regret | **0 @ 플래너 호출 0회** (100% compute 절감, ~348 s/결정) |
| 완주노드 예측 | MAE 13.4 (범위 143~291), **R² = 0.829** |
| 상태무관 baseline | regret 0.281, 95% CI [+0.125, +0.438] |

**정직한 한계**: 이 과제는 OOD 종류가 매크로를 거의 결정해버려(fault→Replace, zone→ForbidZone)
top-1 이 항상 맞고, frontier 가 곡선이 아니라 **계단**이다. compute 절감은 진짜지만 랭킹 문제는 쉬웠다.

### E2~E4
- **E2**: LLM-over-surrogate 가 67% 적은 검증으로 동품질
- **E3**: frozen 모델은 drift 에서 붕괴, active 재학습은 1스텝 복구 (호출 54%↓)
- **E4**: FULL 이 Pareto front, LLM→solver 대비 45% 적은 호출

### 비용 평가 (v2, 오라클이 100% 완주하는 벤치마크)
> surrogate 는 완주율에서 오라클 천장과 동률이고, 거의 오라클급 결정(regret 0.100)을 **0.10 ms** 에 낸다.
> = LLM+solver(검증당 64 s) 대비 **1.9M×** 빠르고, 미검증 LLM 보다 정확하고 완주안전(100% vs 75%).

### STEP 6 — 옵션 제한의 대가
| seed | V^macro | V*(ext) | 최선 확장 arm | 노이즈 바닥 |
|---|---|---|---|---|
| 1 | 3573.57 | 3568.99 | 10 (**≡ macro 1**) | 4.57 |
| 2 | 22.12 | 22.12 | 1 | 0.00 |
| 3 | 3841.41 | 3841.41 | 1 | 1.58 |

**평균 gap 0.00, 노이즈 바닥 2.05, 유의 seed 0/3.** 세 seed 모두 최선 arm 이 대조군 쌍 안에 있다.
`Replace@{0,5,15}` 구별 불가, `Deprio×{10,50,200}` 셋 다 NOOP 값으로 붕괴.
→ **파라미터 축을 열어도 얻을 것이 없다.** (원시 배정공간은 안 열었으므로 이 gap 은 **하한**)

### Assimilation (C1~C4) — `DESIGN_ASSIMILATION.md` 전문
| | 명제 | 상태 |
|---|---|---|
| C1 | 처음 보는 종류에서 LLM > surrogate | **조건부 성립** (fault 폴드만) |
| C2 | 아는 종류에서 surrogate 동등품질·10⁴배 저렴 | **성립** |
| C3 | 시스템이 스스로 "처음 보는 것"을 판별 | **미확립** |
| C4 | LLM 처리분을 학습해 다음부터 싸게 | **성립** |

C1 이 조건부라는 게 가장 큰 위험 — 이게 깨지면 라우터는 "더 나쁜 쪽으로 보내는 장치"가 된다.

---

## 5. 확정된 설계 결정

**비용 = 유한벌점 SSP** (`gen_oracle_mc.jl:146`, `overnight_mdp.py:35` — **두 곳이 반드시 같아야 함**)
```
complete → makespan
else     → 10000 + 100×unclosed + 1e-3×makespan
```
사전식 순서(완주 ≫ 닫힌 노드 수 ≫ makespan)를 스칼라로 옮긴 것. 완주끼리는 **closed 를 보지 않는다**
(`better_ssp`) — 완주해도 closed<total 이라 legacy 규칙은 더 느린 실행을 낫다고 판정할 수 있었다.

**라벨 = K-rollout MC + CRN.** 같은 rollout k = 같은 hazard seed → 짝지은 비교가 유효.
1-shot 라벨은 NOOP 비용을 **375배 과소평가**한다(실측).

**결정 중심 타깃** — raw q_cost 는 이봉(완주 ~20 / 미완주 ~26000)이라 회귀가 완주여부에 지배된다.
현재는 instance 내부 정규화로 우회 중이나, **완주확률 × makespan 2층 분해가 올바른 해법**(다음 작업 1번).

**배포 게이트 G1/G2/G3** — 모델을 바꿀 때마다:
G1 기존 F 에서 regret 이 유의하게 나빠지지 않았는가 / G2 새 클러스터에서 좋아졌는가 /
G3 novelty 교정이 여전히 유효한가. 하나라도 실패면 **롤백**.

**3분류(success / known-disturbance / OOD)** 는 결정함수가 **두 개** 필요하다 —
"아는 교란처럼 보이는가"와 "교란 없는 빌드처럼 보이는가". 두 번째를 위해 nominal arm(`DS_NOMINAL=1`)이 있다.

**LLM 은 새 DSL kind 를 발명하지 않는다** — 미지 사건에서는 서술자 6개
`[harm, work_at_risk, resource_loss, recovery_capacity, progress, slack]` 를 **추정**하고 하류는 그대로 돈다
(`src/safety/novelty.jl` `event_descriptors`). 입력 쪽 개방성은 이렇게 이미 확보돼 있고,
**출력 쪽(행동 확장)만 없다** → `PLAN_ACTION_GROWTH.md`

---

## 6. 데이터 스키마 (2026-08-02 갱신 — 구 `DUMP_SCHEMA.md` 는 이제 틀림)

`gen_oracle_dataset.jl` 이 `(instance, macro)` 당 한 줄. **원자료만 덤프, 서술자는 파이썬에서 계산**
— 정의를 바꿔도 재시뮬이 아니라 재계산이면 된다.

**2026-08-02 추가**: `raw_robot_x/y`, `raw_robot_mode`(IDLE/TRANSIT/CARRY/MANIPULATE),
`raw_robot_goal_x/y`, `raw_n_carry|transit|manip`, `raw_cargo_id/x/y/placed`,
`target_id`(raw 벡터 조인 키), 에피소드 행에 `hist_*` 8개(T2 용).

**파이썬 파생**: `xc_*`(커밋먼트) `xt_*`(사건 당사자) `xg_*`(SoC 분포) `xa_*`(부품 배치) — 총 φ 40개.

---

## 7. 함정 목록 — **재현하기 전에 반드시 읽을 것**

과거에 실제로 밟았고, 밟으면 결과가 조용히 틀리는 것들.

### 오라클/라벨
1. **RVO 를 끄면 정답이 뒤집힌다.** 싼 world 로 라벨을 만들 수 없다.
2. **control(무사건) 판이 없으면** 그 instance 가 유익한지 알 수 없다.
3. **후보는 연구 대상 사건에 대한 대응만 바꿔야 한다.** 다른 사건까지 바꾸면 다른 정책을 재게 된다.
4. **후보 집합은 엔진이 실제로 할 수 있는 것과 일치해야 한다.**
5. **손으로 만든 하니스는 프로덕션 sim 과 갈라진다.** `run_one` 을 재사용할 것.
6. **속도 지표는 "실현된 makespan"이어야 한다** — 계획상 시간이 아니라.
7. `pick_solo_fault_target` 은 빌드 후반에 `nothing` 을 돌려준다(solo 타깃 부재).

### φ / 학습
8. **`decision_idx` 를 φ 에 넣지 말 것** — 이력 요약이다. 이거 하나로 "surrogate 가 baseline 을 이긴다"는 결론이 뒤집혔다.
9. **feature 목록을 첫 행에서 뽑지 말 것** — 첫 instance 가 zoneblk 이면 SoC 블록 **전체가 사라진다**(실측 38/66행 상실). 합집합을 쓸 것.
10. **결측을 0.0 으로 채우지 말 것** — `soc=0.0` 은 "방전"이라는 유효한 값이다. `-1.0`(N/A 규약)을 쓸 것.
11. **글롭 오염** — `ep*.jsonl` 은 구 데이터까지 빨아들이고, 없는 열이 0 으로 채워져 **가짜 신호**가 된다. 좁혀 쓸 것.
12. **value-residual 은 drift 신호가 아니다**(CUSUM spurious 남발). **covariate-novelty** 가 맞는 신호.

### 평가
13. **동점을 빼고 재라.** `argmin` 이 동점을 첫 원소(=NOOP)로 깨서 정답분포가 왜곡되고, 모든 정책의 regret 이 0 쪽으로 희석된다.
14. **표본이 작으면 판정하지 말 것.** 결정적 instance 5개에서 순위적중 1.00 이 나와 "φ 충분" 이 찍힌 적이 있다.
15. **베이스라인 없이 regret 을 해석하지 말 것.** regret 0 이 과제가 쉬운 건지 모델이 잘한 건지 구별 불가.
16. **MC 노이즈에는 대조군을 둘 것.** STEP 6 에서 SE ≈ Q̂ 였다. 중복 arm(정의상 같은 정책)이 노이즈 바닥을 준다.

### 시뮬 설정
17. **배치 경계 58** — 이 빌드는 첫 배치에서 closed 0→58 로 점프한다. `DS_EP_LO/HI` 를 60 이하로 두면
    **모든 사건이 같은 스텝에 몰려** τ=0 이 된다(에피소드가 아니라 동시사건).
18. **너무 늦추면 fault 가 안 터지고 동점률이 95% 로 치솟는다.** 실측 권장구간 **[55,130]**.
19. **MTBF 는 빌드 길이에 맞출 것** (이 하니스 빌드 ≈ 20 시뮬초). 60/45 는 함대 전멸, 500/500 이 적정.

### 생성 설정 (2026-08-02 밤 추가)
24. **`DS_EP_LO/HI` 는 에피소드 모드(`DS_EPISODE_N>0`)에서만 동작한다.** `run_parallel.ps1` 은
    단일사건 유닛 모드라 이 창을 무시한다 — 창 실험에는 `run_night_k1.ps1` 을 쓸 것.
25. **`DS_NOPROG` 를 유닛 모드 값(30000)에서 에피소드 모드로 복사하지 말 것.** 실패 팔이 판당
    30분을 넘겨 예산이 3배가 된다(실측). 에피소드 모드는 8000.
26. **동점률은 완주율의 함수다.** 개입이 완주를 되살릴 수 있는 시점에 사건이 터져야 팔이 갈린다.
27. **`ep_[abg]`(창[8,60])는 τ=0 이 99% 라 순차 데이터가 아니다.** T2/커플링 논의에 쓰지 말 것.
28. **PowerShell `Tee-Object` 로그는 UTF-16** — bash `tail` 로 읽으면 깨진다. `Get-Content` 를 쓸 것.
29. **새 팔(매크로 id)을 추가하면 `ACTION_NAME`/`MACRO_COST` 를 같이 늘려야 한다.** 둘 다 0~4 키만
    가진 Dict 라, 시뮬과 enact 는 멀쩡히 통과하고 **행을 쓰는 순간** `KeyError` 로 죽는다
    (2026-08-02 A1 에서 실제 발생). 두 Dict 는 `features_agnostic.MACRO_COST` 와도 값이 같아야 한다.

### 운영
20. **병렬 2개 상한** (프로세스당 ~2.5 GB), `DS_STACK=1000000000`.
21. **스크립트명으로 프로세스를 죽이는 감시기 금지** — 나중에 띄운 같은 스크립트까지 죽인다(전례 있음).
22. **인라인 python 은 `PYTHONIOENCODING=utf-8`** — 없으면 Windows 에서 cp949 로 나가 리포트가 깨진다.
23. **패치는 heredoc `assert` 말고 Edit 도구로** — 백그라운드에서 assert 실패가 묻힌다.

---

## 8. 남긴 문서 / 지운 문서

**남긴 것 (이 파일 포함 4개)**
| 파일 | 왜 남겼나 |
|---|---|
| `README.md` | 이 파일. 단일 진입점 |
| `PLAN_ACTION_GROWTH.md` | 다음 계획 (행동공간 성장 폐루프) |
| `DESIGN_ASSIMILATION.md` | C1~C4 정의 + LLM 실측 원본. `policy.jl` 이 참조 |
| `RESULTS.md` | E1~E4 측정 원본 |

**그 뒤에 추가된 것**
| 파일 | 무엇 |
|---|---|
| `FIRE_TIME_RELABEL_2026-08-05.md` | 발화 시점을 instance 차원으로 (fault 피커 수정). **§3-a 의 "후반엔 개입 불필요" 결론은 아래 문서가 철회했다** |
| **`BATTERY_FAULT_REDESIGN_2026-08-05.md`** | **배터리 표적 피커 수정 + 심각도 사다리 재설계(감속 구간) + 두 결정(λ → μ 시간가격 키 / battery 행동 = SwapBattery). 한글·영문 병기** |
| **`ZONE_REDESIGN_STEP1_7_2026-08-05.md`** | **구역 결정 재설계 STEP 1~7: 위반 술어 계산기(`zone_diagnosis`, 팀 슬롯 술어 신규) → 최소수복 규칙을 오라클·게이트로 → 원시값 관측 어휘 → 원리 프롬프트 → 라우터 표현력 게이트. 각 단계 검증 로그 포함** |

**지운 것 (18개)** — 내용은 위에 흡수했다. 전부 git 에 있으므로
`git checkout HEAD -- wm4spacecraft_manufacturing/md/<파일>` 로 언제든 복구.

`2026-07-21_monitor_and_OOD_adaptive_control.md` `BRIEF_2026-07-30.md` `COST_EVAL_RESULTS.md`
`COST_METRICS_DESIGN.md` `DEMO.md` `DESIGN.md` `DESIGN_CLASSIFIER.md` `DESIGN_STEERING.md`
`DESIGN_STEP6_7.md` `DUMP_SCHEMA.md` `EVALUATION.md` `FINDINGS_ADWIN.md` `ORACLE_FINDINGS.md`
`PROPOSAL.md` `REVIEWER_RESPONSE_PLAN.md` `STATUS.md` `SURROGATE_NECESSITY_EVAL.md` `TALK_QA_PREP.md`

지운 이유 분류:
- **낡은 스냅샷**: BRIEF, STATUS(07-15 기준), 2026-07-21, DEMO, TALK_QA_PREP
- **중복**: EVALUATION ⊂ SURROGATE_NECESSITY_EVAL, COST_METRICS_DESIGN(결과는 §4)
- **틀려진 것**: DUMP_SCHEMA (오늘 스키마가 바뀜 → §6)
- **핵심만 흡수**: ORACLE_FINDINGS·FINDINGS_ADWIN → §7 함정목록, DESIGN_STEP6_7 → §5 게이트,
  DESIGN_CLASSIFIER → §5 3분류, RESULTS 일부 → §4

---

## 9. 상위 문서

- **MDP 정식화 원문**: `../MDP_DESIGN_FROM_SCRATCH.md` (§2 상태, §4 행동, §9 라우터, §15~16 구현로그)
- **야간 파이프라인 기록**: `../artifacts_mdp/OVERNIGHT_REPORT.md`
- **open-world 현황**: `../artifacts_openworld/README.md`
