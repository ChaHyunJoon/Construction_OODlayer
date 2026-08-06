# 계획: 행동공간이 자라는 폐루프 (LLM 이 새 대응을 발명 → surrogate 가 물려받음)

작성 2026-08-02. 선행 문서: `DESIGN_ASSIMILATION.md`(C1~C4), `MDP_DESIGN_FROM_SCRATCH.md`(§4 행동, §9 라우터),
`constructionbots-failure-vs-ood-terminology`(용어).

---

## 0. 목표 문장

> 미지의 OOD 가 오면 **LLM 이 새로운 대응을 만들어내고**, 그 대응이 **surrogate 의 행동집합에 편입**되어,
> 다음에 같은 OOD 가 오면 surrogate 가 LLM 없이 처리한다.

$$\mathcal{A}_0 \xrightarrow{\ \text{LLM}(n_1)\ } \mathcal{A}_1 \xrightarrow{\ \text{LLM}(n_2)\ } \mathcal{A}_2 \to \cdots$$

**행동집합이 시간에 따라 자란다.** 이게 기존 설계와의 유일하지만 결정적인 차이다.

---

## 1. 이미 있는 것 / 없는 것

`DESIGN_ASSIMILATION.md` 가 C1~C4 를 이미 정의·측정했다. 그런데 그 루프가 편입하는 것은
**새로운 상태(사건 종류)**이지 **새로운 행동**이 아니다.

| 구성요소 | 상태 | 위치 |
|---|---|---|
| 신규 사건 탐지 | ✅ conformal novelty gate | `src/safety/novelty.jl:270` `novelty_verdict` |
| 미지 종류의 입력 처리 | ✅ **LLM 이 kind 를 발명하지 않고 서술자 6개를 추정** | `novelty.jl` `event_descriptors` |
| NL 관측 채널 | ✅ | `src/navigator/ood_truth.jl` → `nl_events.py` |
| LLM producer | ✅ | `llm_producer.py` |
| 스트림 하니스 | ✅ C3/C4 측정됨 | `assimilation_stream.py` |
| 자동 라벨 → 재학습 | ✅ C4 성립 | 같은 파일 |
| **행동집합 확장** | ❌ **전혀 없음** | — |
| **행동의 서술자 인코딩** | ❌ (지금은 id one-hot) | `features_agnostic.py` |
| **신규 행동의 라벨 생성** | ❌ | — |
| **회귀 방지 게이트** | 설계만 (G1/G2/G3) | `md/DESIGN_STEP6_7.md` |

**즉 입력 쪽 개방성은 이미 있고, 출력 쪽 개방성이 통째로 없다.** 이 계획은 그 델타만 다룬다.

---

## 2. 핵심 장애물 세 가지

### H1. 행동이 id 로 인코딩되어 있어 새 행동을 넣을 수 없다

surrogate 는 $(\varphi, a) \mapsto Q$ 인데 $a$ 가 5개 매크로에 대한 one-hot 이다.
6번째를 추가하면 **모델 입력 차원이 바뀌어 재학습 없이는 아무것도 못 한다**. 이미 진단된 병목이다
(`featurize` one-hot 이 신규 kind 를 차단한다는 것과 정확히 같은 구조적 결함, 이번엔 행동 쪽).

**해법**: 행동을 **서술자**로 인코딩한다. $a \mapsto \psi(a) \in \mathbb{R}^d$ 로,
"이 행동이 **무엇을 하는가**"를 적는다. 그러면 새 행동은 $\psi$-공간의 새 점일 뿐이고 모델은 외삽할 수 있다.

주의: STEP 3 에서 `agnostic-d`(행동도 서술자) 를 시도했고 LOIO 0.097 → 0.230 으로 **악화**했다.
다만 그건 (i) 1-shot 라벨 위에서, (ii) 5매크로 중 2개만 오라클 정답인 데이터였다.
**MC 라벨 + 결정적 데이터 위에서 다시 해야 한다** — 기각된 게 아니라 답할 수 없는 조건이었다.

### H2. "새로운 행동"이 무엇인지 정해야 한다 — 코드 생성은 답이 아니다

LLM 이 엔진이 실행할 수 없는 spec 을 발명하면 아무 의미가 없다. 세 가지 범위가 있다:

| 범위 | 예 | 실행가능성 | 검증가능성 |
|---|---|---|---|
| (a) 기존 spec 의 새 파라미터 | `ReplaceAgent(r, after=7.5)` | 즉시 | 쉬움 |
| (b) **기존 primitive 의 새 조합** | `[ForbidAgent(r), ReformTeam()]` | **즉시** | 쉬움 |
| (c) 새 spec 타입 (코드 생성) | `RestrictCapability(r, :manip)` | 엔진 수정 필요 | 어려움(샌드박싱) |

**(b) 를 채택한다.** 다만 아래의 원래 근거는 **2026-08-02 에 실측으로 반증됐다** (취소선 부분).

> ~~결정적 근거 — 엔진이 이미 다중 spec 을 받는다: `RespecProposal.constraints` 는 Vector 이고
> `replan.jl:669` 가 `for c in proposal.constraints` 로 순회한다. 즉 조합 행동은 오늘 당장
> 실행 가능하다.~~

### ⚠️ 정정 (2026-08-02): **혼합 종류 조합은 지금 실행되지 않는다**

구조체가 Vector 인 것은 맞지만, **디스패처가 단일 종류를 전제한다.** `maybe_respecify!`
(`replan.jl:273`)는 **첫 매치 승리** 체인이고, 각 분기가 `any(...)`/`all(...)`/`length==1` 로 걸린다:

| 순서 | 술어 | 정의 | 혼합 조합에서 |
|---|---|---|---|
| 355 | `_is_robot_fault` | `length(constraints)==1 && ForbidAgent` | **length>1 이면 영원히 false** |
| 376 | `_is_zone_respec` | `any(ForbidZone)` | 먼저 잡히면 return |
| 465 | `_is_robot_replace` | `any(ReplaceAgent)` | 먼저 잡히면 return |
| 563 | `_is_reform` | `any(ReformTeam)` | 먼저 잡히면 return |
| 663 | `_is_deprioritize` | `all(DeprioritizeAgent)` | 섞이면 false |

그래서 `[ForbidAgent, ReformTeam]` 을 넣으면 `_is_reform` 이 먼저 잡아 **ReformTeam 만 실행**되고
ForbidAgent 는 **조용히 버려진다**. `_is_deprioritize` 의 docstring 도 이미 이 사실을 적고 있다 —
"혼합 제안은 여기서 안 잡히고 hard 분기로 떨어져 DeprioritizeAgent 는 무해한 no-op 이 된다".

**실측 증거** (같은 seed 301, 같은 fault 사건, `DS_COMBO_ARMS=1`):

| 팔 | 결과 |
|---|---|
| 5 = `[ForbidAgent, ReformTeam]` | closed 201/313, complete=False, label_seconds **372.08** |
| 4 = `[ReformTeam]` 단독 | closed 201/313, complete=False, label_seconds **372.08** |

완전히 동일하다. 조합이 단독과 구별되지 않는다 = **조합축은 현재 허구다.**

**따라서 선행 과제가 하나 늘었다** (A1 이 A0 을 낳았다):

> **A0. 다중 spec 디스패처** — `maybe_respecify!` 가 제약을 **종류별로 묶어 각 핸들러를 순서대로
> 적용**하고 마지막에 한 번만 재풀이하도록 바꾼다. 순서는 기하수술(zone/reform) → 그래프수술
> (replace) → 배정(ForbidAgent MILP) → soft(Deprioritize) 가 자연스럽다(뒤로 갈수록 앞의 결과를 본다).
> 그 전까지 **혼합 조합은 큰 소리로 거부**한다 — `safety_filter.py` 의 L2 규칙 `allow_mixed_kinds=False`
> 가 이미 막고 있다. 조용한 무시는 "조합을 실행했다"는 가짜 기록을 남기므로 최악이다.

같은 종류 안에서의 조합(예: `ForbidAgent` 두 개, `Deprioritize` 여러 개)은 지금도 동작한다 —
`_is_deprioritize` 분기가 `for c in proposal.constraints` 로 전부 처리하기 때문이다.
**즉 오늘 열려 있는 조합은 "동종 다중"이고, 계획이 원하는 "이종 조합"은 A0 이 필요하다.**

primitive 는 5개(`spec_dsl.jl`): `ReplaceAgent`, `DeprioritizeAgent`, `ForbidAgent`,
`ForbidZone`, `ReformTeam`. 이 중 **`ForbidAgent` 는 매크로로 노출조차 안 되어 있다** — 이미 놀고 있는 primitive.

(a) 는 STEP 6 에서 **이득 0** 으로 측정됐다(gap 0.00 < 노이즈 바닥 2.05). 파라미터 축은 열어도 소용없다.
따라서 **조합 축이 유일하게 남은 확장 방향**이며, 이건 STEP 6 이 측정하지 않은 영역이다.

### H3. 새 행동의 라벨이 한 개뿐이다

LLM 이 한 번 행동하면 표본이 1개다. 학습에 못 쓴다.
**해법**: 편입 가치가 있다고 판정된 상태에 한해 **라벨링 예산을 쓴다** — 그 상태에서
기존 팔 + 새 팔을 모두 $K$ rollout 돌려 완전한 라벨 집합을 만든다.
비용 $= |\mathcal{A}| \times K$ 시뮬. 이게 "post-training" 의 실제 비용이다.

---

## 3. 폐루프 정의

```
        ┌─────────────────────────────────────────────────────────┐
        │                                                          │
   [1] 사건 도착                                                    │
        ↓                                                          │
   [2] novelty_verdict(φ)  ── :trust ──→ surrogate 가 처리 ─────────┤
        │ :escalate                                                │
        ↓                                                          │
   [3] LLM: 서술자 6개 추정 + **조합 행동 제안** ψ(a_new)             │
        ↓                                                          │
   [4] 안전 필터 (실행가능성·불변식 검사) ── 거부 ──→ 폴백(canonical) │
        ↓ 승인                                                     │
   [5] enact → 결과 관측                                            │
        ↓                                                          │
   [6] 편입 판정: 이 (상태클러스터, 행동) 을 배울 가치가 있는가?       │
        ↓ 예                                                       │
   [7] 라벨링 예산 지출: |A∪{a_new}| × K rollout                     │
        ↓                                                          │
   [8] 재학습 + 배포 게이트 G1/G2/G3 ── 실패 ──→ 롤백               │
        └──────────────────────────────────────────────────────────┘
```

**성공의 정의**: 같은 사건 클러스터가 다시 왔을 때 [2] 가 `:trust` 로 바뀌고,
surrogate 가 LLM 과 동등한 결정을 낸다. 즉 **kind 별 LLM 호출률이 시간에 따라 감쇠**한다.

---

## 4. 각 단계의 설계 결정

### [3] 행동 서술자 ψ(a)

행동을 id 가 아니라 **효과**로 적는다. 최소 후보:

| 축 | 의미 | 값 |
|---|---|---|
| `n_specs` | 조합의 크기 | 1, 2, 3 |
| `touches_agent` | 특정 로봇을 건드리는가 | 0/1 |
| `consumes_spare` | 스페어를 소모하는가 | 0/1 ← **전환비용의 핵심** |
| `is_spatial` | 공간 제약인가 | 0/1 |
| `is_schedule` | 스케줄 가중치만 바꾸는가 | 0/1 |
| `reversible` | 되돌릴 수 있는가 | 0/1 |
| `scope` | 영향 범위 (1대 / 팀 / 전역) | 1, k, N |
| `magnitude` | 파라미터 크기 정규화 | [0,1] |

기존 5매크로가 이 공간의 5개 점이 되고, 조합은 새 점이 된다.
**중요**: `consumes_spare` 가 있어야 "지금 쓰면 다음에 없다"를 모델이 표현할 수 있다 —
myopia 문제와 여기서 만난다.

### [4] 안전 필터

LLM 이 낸 조합을 그대로 실행하면 안 된다. 3층:

1. **문법**: 모든 spec 이 유효한 타입이고 인자가 도메인 안에 있는가
2. **의미**: 모순 조합 거부 (예: 같은 로봇에 `ReplaceAgent` + `DeprioritizeAgent` — 교체된 로봇을 미루는 건 무의미)
3. **불변식**: 스페어 잔량 ≥ 요구량, 금지구역이 필수 경로를 전부 막지 않는가

거부되면 canonical 로 폴백하고 **거부 사유를 로그에 남긴다**(LLM 개선의 재료).

### [6] 편입 판정 — 아무거나 배우면 안 된다

편입 조건 3개를 **모두** 만족할 때만 라벨링 예산을 쓴다:

- **재발 가능성**: 같은 클러스터가 $m \ge 2$ 회 관측됐다 (일회성 사건에 예산 낭비 금지)
- **결정 관련성**: 그 상태에서 팔 사이 결과가 실제로 갈린다 (= 동점이 아니다)
- **신규성**: $\psi(a_{new})$ 가 기존 행동집합에서 충분히 멀다 (중복 편입 방지)

두 번째가 지금 F-축에서 겪고 있는 **동점 85%** 문제와 같은 기준이다.

### [8] 배포 게이트 (회귀 방지)

행동을 추가하면 기존 성능이 나빠질 수 있다(치명적 망각 / 차원 증가로 인한 과적합).
`README.md` §5 의 배포 게이트 G1/G2/G3 를 여기 적용
(원 설계 `DESIGN_STEP6_7.md` 는 2026-08-02 에 README 로 통합됨):

- **G1**: 기존 $\mathcal{F}$ 에서 subopt_norm 이 유의하게 나빠지지 않았는가 (짝지은 검정)
- **G2**: 새 클러스터에서 subopt_norm 이 유의하게 좋아졌는가
- **G3**: novelty 게이트 교정이 여전히 유효한가 (호출률이 폭주하지 않는가)

하나라도 실패하면 **롤백**하고 그 행동은 후보 목록에 남긴다(삭제하지 않음).

---

## 5. 평가 프로토콜 — 배치가 아니라 **스트림**이다

정적 train/test 분할로는 이 시스템을 평가할 수 없다. 사건이 순차적으로 도착하고
시스템이 그때그때 변하기 때문이다.

**스트림 구성**: $\mathcal{F}$ 사건과 $\mathcal{N}$ 사건을 섞어 $T$ 개 흘린다.
$\mathcal{N}$ 은 여러 번 재발해야 한다(안 그러면 편입을 측정할 수 없다).

| 지표 | 무엇을 말하는가 | 성공 형태 |
|---|---|---|
| 누적 subopt_norm | 전체 결정 품질 | LLM-only / surrogate-only / 규칙표 baseline 보다 낮음 |
| **kind 별 LLM 호출률의 시간 추이** | **편입이 실제로 일어났는가** | $\mathcal{N}$ 첫 등장 후 감쇠, $\mathcal{F}$ 는 계속 0 |
| $\mathcal{F}$ subopt_norm 추이 | 망각 여부 | 평탄 (G1) |
| time-to-assimilate | 몇 번 겪어야 넘겨받는가 | 작을수록 좋음 |
| 총 비용 (LLM 호출 + 라벨링 시뮬) | 실제 운영비 | baseline 대비 |

**반드시 넣어야 할 baseline** (DEXTER-LLM 대응):
- `always_LLM` — 매번 LLM (그들의 baseline 방식)
- `rule_table` — 사건 종류별 고정 규칙 (**DEXTER-LLM 의 Fig.5 그 자체**)
- `no_growth` — 편입 없이 기존 5매크로만 (행동 확장의 순효과를 분리)

세 번째가 이 계획의 **순효과를 재는 대조군**이다. 이게 없으면 "편입이 도움됐다"를 주장할 수 없다.

---

## 6. 단계별 계획

| 단계 | 작업 | 시뮬 비용 | 선행조건 |
|---|---|---|---|
| **A1** | 조합 행동을 실제로 실행 가능한지 스모크 (예: `[ForbidAgent(r), ReformTeam()]`) | 낮음 (몇 판) | 없음 |
| **A2** | 행동 서술자 ψ(a) 정의 + featurizer 를 id→ψ 로 전환 | 0 | 없음 |
| **A3** | ψ 표현에서 기존 결과 재현 확인 (회귀 없음) | 0 | A2, **결정적 데이터** |
| **B1** | $\mathcal{N}$ 고장모드 1종 구현 (능력 상실 권장) | 낮음 | 없음 |
| **B2** | `DS_NOVEL_KINDS` 분리 + 훈련 오염 가드 | 0 | B1 |
| **C1** | 안전 필터 3층 | 0 | A1 |
| **C2** | 편입 판정기 (재발/결정관련성/신규성) | 0 | A2 |
| **C3** | 라벨링 예산 실행기 ( $|A|\times K$ ) | **높음** | C2 |
| **D1** | 배포 게이트 G1/G2/G3 | 0 | C3 |
| **D2** | 스트림 하니스 확장 (`assimilation_stream.py` 에 행동성장 추가) | 0 | D1 |
| **D3** | 전체 측정 + baseline 3종 | **높음** | 전부 |

**A1·A2·B1·B2·C1·C2 는 시뮬레이션이 거의 필요 없다.** 먼저 다 만들어둘 수 있다.

---

## 7. 정직한 위험

**R1 — 결정적 데이터가 없으면 아무것도 측정 못 한다.** 현재 $\mathcal{F}$ 데이터의 85% 가 동점이다.
편입 판정의 두 번째 조건("결정 관련성")도, 게이트 G1/G2 도 전부 동점이면 무의미하다.
**이 계획은 hazard-ON 데이터 위에서만 의미가 있다.**

**R2 — 조합 폭발.** primitive 5개 × 대상 × 파라미터면 조합이 금방 커진다.
편입 판정의 "신규성" 조건이 이걸 막는 유일한 장치다. 느슨하면 행동집합이 쓰레기로 채워진다.

**R3 — (b) 범위의 한계.** 조합만 허용하면 "정말 open-world 인가"라는 비판을 받는다.
정직한 답: **행동 어휘는 닫혀 있고 조합공간은 열려 있다.** 이걸 숨기지 말고 명시해야 한다.
(c) 코드생성까지 가려면 별도의 샌드박싱·검증 연구가 필요하고, 이 계획의 범위가 아니다.

**R4 — LLM 이 조합을 낼 수 있는가는 미검증.** 지금 `llm_producer.py` 는 매크로 id 를 고르게 되어 있다.
조합을 내려면 출력 스키마부터 바꿔야 하고, LLM 이 유효한 조합을 낼 확률은 측정된 바 없다.
**C1(안전필터)의 거부율이 그 자체로 측정값**이 된다.

**R5 — C1 가설이 아직 조건부.** `DESIGN_ASSIMILATION.md` 기준 C1 은 fault 폴드에서만 LLM 이 이겼다.
LLM 이 $\mathcal{N}$ 에서 surrogate 를 못 이기면 이 루프 전체의 전제가 무너진다.
**B1 직후에 C1 을 새 $\mathcal{N}$ 으로 다시 재는 것이 가장 싼 게이트다.**
