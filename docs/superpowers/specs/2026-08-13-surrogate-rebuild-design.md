# surrogate 재구축 설계 — 상수 정책 붕괴의 원인과 처방

**작성 2026-08-13.** 근거는 전부 이 날 실측(630판 신세대 스윕 `objective_hash=19819377a7f8ebb2`
+ 학습셋 `oracle/out/n44_plus78.jsonl` 직접 계산).

## 1. 관측된 증상

신세대 630판 스윕에서 배포 surrogate 는 **OOD 종류와 무관하게 언제나 같은 팔을 낸다.**

| case | 실제 발생한 사건(truth) | surrogate 가 낸 macro | dspy 가 낸 macro |
|---|---|---|---|
| battery | BatteryTruth ×120 | **Replace ×120** | SwapBattery ×120 |
| fault | FaultTruth ×120 | **Replace ×120** | Replace 112 · ReformTeam 68 · Deprioritize 8 |
| fault_battery | BatteryTruth ×60 + FaultTruth ×60 | **Replace ×120** | **SwapBattery ×60** · Replace 56 · ReformTeam 34 · Deprioritize 4 |

`fault_battery` 에서 dspy 의 SwapBattery 60회는 BatteryTruth 60회와 **정확히 일치**한다 —
즉 kind 판별이 가능한 문제인데 surrogate 만 못 하고 있다.

세 case 의 surrogate 런은 **시드별로 바이트 동일**하다(makespan·complete·closed 전부). 답이
같으니 스케줄도 같다. `battery` 에서 SwapBattery 는 `valid` 집합에 들어 있고 학습 support
(`[0,1,2,3,4,7,8]`)에도 있는데 **한 번도 선택되지 않는다.**

성능 차이도 실측됐다: battery case 에서 surrogate(Replace) 는 29/30 완주 · 중앙 J **23.26**,
dspy(SwapBattery) 는 30/30 · 중앙 J **19.79**.

## 2. 진단

### D1 — 절대값을 회귀하고 나서 순위를 매긴다 (구조적)

배포 타깃은 `y = closed − λ·MACRO_COST[macro]` (λ=3.0, `surrogate_data.load_training_frame:38`).
학습셋(68 instance / 286행)에서 이 타깃의 분산을 분해하면:

| | 값 |
|---|---|
| instance **사이** 분산 (상황 난이도) | **2130.2** |
| instance **안** 분산 (팔 선택 효과) | **611.7** |
| within / between | **0.287** |

**타깃 분산의 약 78% 가 "어느 instance 인가"다.** 제곱오차를 최소화하는 학습기는 용량의
대부분을 상황 난이도 예측에 쓰는데, 결정에 쓰이는 것은 같은 instance 안의 팔 간 차이뿐이다.
팔 간 예측차가 뭉개지면 argmax 는 상수로 붕괴한다 — §1 이 그 붕괴다.

**정보가 없어서가 아니다.** `e1_analyze.featurize` 는 `kind_*` one-hot 과 `macro_*` one-hot 을
둘 다 포함한다. 모델이 그 정보를 쓸 **이유**를 학습 신호가 주지 않았을 뿐이다.

### D2 — 비용 항이 식별되지 않는다

`closed` 의 표준편차는 **53.8** (범위 131~291). `λ·MACRO_COST` 의 전 범위는 **0~4.5** —
1σ 의 8% 다. SwapBattery(0.6)와 Replace(3.0)의 차이 2.4 는 `closed` 노이즈에 묻힌다.
저장소도 이미 측정해 뒀다(`export_surrogate.py`): λ 를 0.5→30 으로 60배 움직여도 정답이
바뀌는 instance 가 2.4~3.2% 뿐이다.

### D3 — 학습/배포 물리 불일치 (실질적으로 가장 큰 원인)

| | 라벨러 `_arm_battery!` | 배포 `run_demo.jl` (2026-08-13 수정 후) |
|---|---|---|
| 용량 | `DS_SHRINK=200` → 41,400 J (**최대부하 41초**) | 8.28e6 J (**2.30 시간**) |
| stall / derate | ON (0.15 / 0.5·0.35) | ON (0.15 / 0.5·0.35) |

**라벨은 "배터리가 41초에 죽는 세계"의 정답이다.** 그 세계에서는 자연 방전만으로 로봇이
죽으므로 최적 대응이 다르다. 학습셋의 정답 분포가 그것을 보여준다:

| kind | instance | 정답 팔 분포 |
|---|---|---|
| battery | 43 | **NOOP 23 · Replace 14 · SwapBattery 6** |
| fault | 15 | Replace 9 · NOOP 6 |
| zoneblk | 10 | RelocateBuild 5 · NOOP 3 · ForbidZone 2 |

학습셋에서 battery 의 정답은 NOOP(53%)·Replace(33%) 이고 SwapBattery 는 14% 다. 그런데
배포 물리에서는 SwapBattery 가 이긴다(§1). **모델은 배운 대로 하고 있고, 배운 세계가 틀렸다.**

### D4 — 팔 커버리지 부족

battery instance 43개 중 **SwapBattery 팔이 존재하는 것은 18개뿐**이다. 나머지 25개에는
그 팔의 관측이 없으니 선호를 배울 근거 자체가 없다.
(`instance_arms_complete`(`e1_analyze.py:158`)가 `valid_mask ⊆ 관측된 macro` 를 요구하므로,
팔이 빠진 instance 는 학습에서 통째로 탈락하기도 한다.)

### D5 — `psi(8) == psi(0)`: SwapBattery 가 NOOP 과 구별 불가 (숨은 지뢰)

`features_agnostic.MACRO_SPECS` 의 키가 `[0,1,2,3,4,5,6,7]` 로 **8 이 없다.** `psi()` 는
`MACRO_SPECS.get(int(action), [])` 로 조회하므로 macro 8 은 빈 리스트 → **NOOP 의 ψ 벡터**를
돌려준다. 실측:

```
psi(8) == psi(0)  ->  True
```

`_PRIMITIVE_TABLE` 에는 `"SwapBattery": (0.2, 1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0)` 가
**이미 정의돼 있고**, 주석까지 "consumes_spare=0 — 이 한 칸이 두 팔을 가르는 축이다" 라고
적혀 있다. **매크로→primitive 매핑 한 줄만 빠졌다.**

지금 배포 경로는 legacy featurize 를 쓰므로 당장의 영향은 없다. 그러나 이 설계가 제안하는
agnostic 표현으로 재학습하는 순간 모델은 SwapBattery 를 "아무것도 안 하기"로 인식한다.
**재학습보다 먼저 고쳐야 한다.**

### D6 — 학습 타깃 ≠ 채점 기준 (기존 유예 항목)

학습은 `closed − λ·MACRO_COST`, 채점은 `−J`. `audit_objective.py` 항목 8 이 지키고 있는
알려진 불일치이며, 이 설계가 닫는다.

## 3. 설계 결정

### 3.1 모델 클래스는 원인이 아니다 — 형식을 바꾼다

D1~D4 는 전부 학습 형식과 데이터의 문제다. 저장소 자체 실측이 클래스 교체의 효과가 미미함을
보여준다: `surrogate_model.py` 의 HGB 0.089 vs RF 0.100, `export_surrogate.py` 의 "Ridge 가
동일 성능". **클래스를 바꿔 얻는 것은 0.01 수준인데 지금 결함은 "battery 에서 항상 틀린 팔".**

**신경망은 지금 쓰지 않는다.** 68 instance / 286행에서 파라미터 수천 개 모델은 instance
난이도를 암기할 뿐이다. 수천 instance 확보 후 재검토한다.

### 3.2 타깃: 절대값이 아니라 **NOOP 대비 우위(ΔJ)**

```
ΔĴ(s,a) = Ĵ(s,a) − Ĵ(s, NOOP)          # 낮을수록 좋음
결정      = argmin_{a ∈ valid} ΔĴ(s,a)
```

같은 instance 안에서 빼므로 D1 의 78% 성분이 **정의상 상수로 소거**된다.

### 3.3 J 의 분기 구조를 그대로 모사하는 2-헤드

`J` 는 완주 여부에서 `C_fail = 10000` 짜리 절벽이 있다. 이봉분포를 하나의 제곱오차 회귀로
넘으면 안 된다. `objective.json` 의 정의를 그대로 따라 나눈다:

| 헤드 | 예측 대상 | 손실 |
|---|---|---|
| **A** | `P(complete \| s,a)` | log loss |
| **B** | `E[makespan + w_E·energy_J \| s,a, complete]` | absolute_error |
| **C** | `E[total − closed \| s,a, ¬complete]` | absolute_error |

```
Ĵ = P·B + (1−P)·(C_fail + C_unclosed·C + tie_eps·B)
```

절벽이 분류기로 흡수되고, **"이 개입이 빌드를 완주시키는가"가 독립된 학습 문제**가 된다 —
지금 surrogate 가 정확히 실패하고 있는 지점이다.

상수(`C_fail`, `C_unclosed`, `tie_eps`, `w_E`)는 **반드시 `objective.py` 에서 읽는다.**
리터럴 복붙은 `audit_objective.py` 항목 1 이 잡는다.

### 3.4 입력: 21 차원 (286행에 맞춘 예산)

**(a) 상태 서술자 6개** — `features_agnostic.STATE_DESCRIPTORS` 그대로:
`harm · work_at_risk · resource_loss · recovery_capacity · progress · slack`

legacy `featurize` 를 쓰지 않는 이유: `severity` 의 물리적 의미가 kind 마다 **부호가 뒤집힌다**
(fault 는 高=위험, battery 는 低=위험). fault 행에서 "severity 높으면 개입"을 배운 모델은
battery 행에서 정확히 반대로 행동한다. 데이터를 더 모아도 안 고쳐진다.

**(b) 행동 서술자 10개** — `features_agnostic.PSI_AXES` (D5 수정 후):
`a_cost · a_intervenes · a_soft · a_restores_capacity · a_relocates_work · a_spatial ·
a_n_specs · a_consumes_spare · a_reversible · a_scope`

SwapBattery 와 Replace 를 가르는 축은 **`a_consumes_spare`(0 vs 1)와 `a_reversible`(1 vs 0)** 이다.

**(c) 교차항 5개** — 물리적 의미가 있는 것만:

| 교차항 | 근거 |
|---|---|
| **`resource_loss × a_restores_capacity`** | **핵심.** "잃은 능력 × 능력을 되돌리는 행동". SwapBattery 가 battery 에서 옳은 이유를 `kind==battery` 없이 표현한다 |
| `harm × a_intervenes` | 무해한 사건에 개입하면 손해 |
| `recovery_capacity × a_consumes_spare` | 예비가 없으면 Replace 를 못 쓴다 |
| `work_at_risk × a_scope` | 큰 일이 걸렸을 때만 전역 개입이 값을 한다 |
| `slack × a_soft` | 병렬성이 남아 있을 때만 soft 개입이 통한다 |

**합계 21 feature / 286행 ≈ 행당 13.6.**

**`kind` one-hot 은 넣지 않는다.** 넣으면 in-distribution 성능은 조금 오르지만 처음 보는
OOD kind 에서 무너진다(one-hot 전부 0 인 미지원 영역). 이 시스템의 존재 이유가 "처음 보는
사건 대응"이다. `features_agnostic.py` 가 측정해 둔 LOKO regret: legacy 0.120 → agnostic 0.100.

### 3.5 출력

| | 출력 | 단위 | 용도 |
|---|---|---|---|
| 1차 | `ΔĴ(s,a)` | **J 단위(≈초)** | `argmin` = 결정 |
| 2차 | `P̂(complete\|s,a)` | 확률 | 안전 게이트·설명 |
| 3차 | `σ̂(s,a)` (트리 분산) | J 단위 | 라우터 novelty 게이트 + 기권 |

`closed − λ·MACRO_COST` 는 더 이상 출력하지 않는다 — D2·D6 의 근원이다. J 단위로 내면
λ 라는 식별 불가능한 손잡이가 사라지고, 채점 기준과 학습 타깃이 일치하며(감사 항목 8 유예 해소),
출력이 해석 가능해진다("이 개입은 빌드를 3.2초 개선한다").

### 3.6 모델 클래스와 하이퍼파라미터

트리 앙상블 유지. **깊이를 줄이는 것이 핵심** — 현행 `max_depth=6` 은 286행에서 instance 를
암기한다.

```python
# 헤드 A
HistGradientBoostingClassifier(max_depth=3, max_iter=300, learning_rate=0.05,
                               min_samples_leaf=5, l2_regularization=1.0, early_stopping=True)
# 헤드 B, C
HistGradientBoostingRegressor(loss="absolute_error", max_depth=3, max_iter=300,
                              learning_rate=0.05, min_samples_leaf=5,
                              l2_regularization=1.0, early_stopping=True)
```

불확실성이 필요하면 RF 대안: `n_estimators=300, max_depth=4, min_samples_leaf=3, max_features=0.5`.

**Ridge 베이스라인을 반드시 함께 보고한다.** 21차원/286행에서 선형이 이기면 트리를 쓸 이유가 없다.

## 4. 평가 게이트

| 게이트 | 내용 | 통과 기준 |
|---|---|---|
| **G1** | Leave-one-instance-out decision regret | 현행 배포 모델 대비 개선 |
| **G2** | **Leave-one-KIND-out** regret | 일반화 주장의 유일한 근거 |
| **G3** | **상수 정책 대비** ("항상 Replace" / "항상 NOOP") | **반드시 이겨야 한다** |
| **G4** | **kind 별 답 분포가 실제로 갈리는가** | battery 의 답 분포 ≠ fault 의 답 분포 |
| **G5** | `test_surrogate_support.py` | 7/7 유지 |

**G3·G4 가 이 설계의 핵심 산출물이다.** 결함이 여기까지 온 이유는 "상수 정책과 구별되는가"를
아무도 기계적으로 검사하지 않았기 때문이다. regret 평균 같은 지표는 상수 붕괴를 숨긴다.

## 5. 데이터 요구사항

1. **라벨러 물리를 배포와 일치**시킨다 (`DS_SHRINK` → 축소 없음). **D3, 가장 큰 실질 원인.**
2. **팔 커버리지 완전화** — 각 instance 의 `valid` 팔을 전수 실행 (D4).
3. **라벨에 J 성분을 저장** — `complete` / `makespan` / `energy_J` / `closed` / `total`.
   `closed` 만 저장하면 §3.3 의 2-헤드를 학습할 수 없다.
4. instance 수 목표: kind 별 최소 30 (현재 battery 43 / fault 15 / zoneblk 10).

## 6. 순서와 게이트

| # | 단계 | 게이트 |
|---|---|---|
| 1 | `MACRO_SPECS[8]` 수정 | `psi(8) != psi(0)` |
| 2 | G3·G4 게이트 구축 — **현행 모델에 대해 실패하는 것을 먼저 확인** | 현행 모델이 G3·G4 를 **실패**해야 게이트가 유효 |
| 3 | 라벨러 물리 정렬 | 배포와 같은 `capacity_J` |
| 4 | 재라벨 (팔 전수 + J 성분 저장) | 커버리지 100% |
| 5 | featurizer + 2-헤드 모델 | G1·G2 |
| 6 | 배포 + 재스윕 | G3·G4·G5 |

**1·2 는 데이터 없이 지금 할 수 있고 위험이 없다. 3·4 가 없으면 5 는 여전히 틀린 세계를
더 잘 맞추는 것에 불과하다.**

## 7. 범위 밖

- 신경망 (데이터 부족, §3.1)
- λ 재튜닝 (식별되지 않음, D2 — J 단위 전환으로 λ 자체를 없앤다)
- DP/오라클 계획(`2026-08-13-dp-oracle` — 실행 완료·아카이브, `docs/superpowers/plans/README.md`)
