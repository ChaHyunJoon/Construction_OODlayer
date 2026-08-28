# 어휘 색인 라우터 설계 — known/OOD 경계가 움직이게 만든다

**Status:** 설계. 구현 계획서 없음.
**대체하는 것:** `src/safety/novelty.jl` + `tools/monitor/policy.jl` 의 novelty 라우터 절.
**대체하지 않는 것:** `event_descriptors` (LLM 의 수치 입력 채널) · `rt` Dict 의 비-라우터 승객들.

---

## 0. 한 줄 요약

라우팅 질문을 바꾼다.

> ~~"이 사건이 fault 인가 battery 인가?"~~ → **"지금 이 사건의 팔들을 surrogate 가 감당하는가?"**

손잡이를 **사건 종류**가 아니라 **행동 어휘**에 건다. 그래야 LLM 이 대응 → 라벨이 쌓임 →
surrogate 가 학습 → **그 사건이 known 이 된다** 는 폐루프가 닫힌다.

---

## 1. 왜 — kind 색인은 경계를 얼린다

사용자 판정 (2026-08-26):

> conformal 같은 걸 fault/battery 로 룰베이스로 정의하면 안 돼. 이건 해당 failure event 가
> known 이냐 OOD 냐를 판정하는 기준이 되는데, 우리의 최종 목표는 LLM 이 점점 더 많은 OOD event 에
> adaptive 하게 대응하면서 surrogate model 을 training 하고, 나중에 가서는 그 surrogate model 이
> 다 known failure 로 인식하고 처리해야 해. 그런데 룰베이스로 처리하면 surrogate 가 학습이 되어도
> robot fault/battery depletion 만 known 으로 인식하고 OOD case 는 여전히 LLM 으로 처리하려고 할 거야.

이것은 취향이 아니라 **구조 논증**이다. known 집합이 `{fault, battery}` 라는 리터럴이면,
surrogate 가 무엇을 얼마나 학습하든 그 집합은 안 바뀐다. 라우터가 폐루프를 **정의상** 막는다.

🔴 그리고 그 리터럴이 실제로 코드에 적혀 있다 — `gen_oracle_dataset.jl:1129-1132` 가
*"zone 은 이 실험의 OOD 프로브다 … 학습 라벨셋에 zone 을 넣으면 '낯선 사건을 알아보는가' 를
재려는 그 사건을 surrogate 가 이미 본 것이 된다"* 로 **얼린 경계를 설계 약속으로 명문화**했다.
그 약속은 *한 번의 측정* 으로는 옳고 *성장하는 시스템* 으로는 틀리다.

어휘로 색인하면 경계가 스스로 움직인다. 새로 주조된 매크로는 **정의상** 지원집합 밖이고,
학습되는 순간 **정의상** 안이다. 아무도 목록을 손으로 안 고친다.

---

## 2. 이 설계가 딛는 실측 (2026-08-27 확인)

### 2-1. ✅ 토대는 이미 있고, 바로 이 목적으로 지어졌다

**surrogate 는 매크로를 id 로 보지 않는다.** `surrogate_features.py:96-97` 이 매크로를
`psi(macro)` — 10축 **행동 서술자** — 로만 넣는다. one-hot 열이 없다. 헤더(`:8-10`)가 이유를 적는다:

> 왜 kind one-hot 을 안 넣는가: 넣으면 처음 보는 OOD kind 에서 one-hot 이 전부 0 인
> 미지원 영역이 되어 무너진다. **이 시스템의 존재 이유가 처음 보는 사건 대응이다.**

귀결: **새로 주조된 매크로는 원시연산 번역이 붙는 순간 잘 정의된 특징 벡터를 얻는다.**
모델을 다시 짜지 않아도 외삽이 가능하다. 이 설계의 가장 강한 토대이고, 이미 이 이유로 지어졌다.

**씨앗 판정자도 이미 있다.** `escalation_target`(`policy.jl:882-908`)이 정확히
*"싼 정책이 이 팔을 표현조차 못 하면 LLM 으로 올린다"* 를 한다. docstring 이 그 논리를 적는다:

> 상태가 익숙한 것과 행동을 표현할 수 있는 것은 **다른 조건**이므로, 후자가 깨지면 novelty 와
> 무관하게 LLM 으로 올린다. 이게 "새 행동은 LLM, 익숙한 것은 surrogate" 분담의 정확한 형태다.

**배관도 완성돼 있다.** `dspy_service.py:467,489,499` → HTTP `unsupported` →
`policy_entry`(`policy.jl:936-953`) → `escalation_target` → `rt["requested_unsupported"]` → 스트림.
`tools/test_policy_escalation.jl` 이 검사한다.

**`select_lane`**(`lane_select.jl:27-59`)은 의존성 0 인 순수 함수이고 이미 `supported` 를
1급 입력으로 받는다. 이 설계는 대체로 **이 함수 하나의 우선순위 재작성**이다.

### 2-2. 🔴 그런데 그 씨앗은 오늘 한 번도 발화한 적이 없다

지원집합은 학습행의 `macro` 열에서만 나온다 — `dspy_service.py:280-281`:

```python
rows, meta = load_rows(SURRO_DATA)
support = sorted({int(r["macro"]) for r in rows})
```

오늘의 라벨셋을 직접 읽어 세어 봤다:

```
rows 33   macro Counter({0: 12, 1: 12, 2: 9})
vocab v4-3arms   train_kinds battery,fault
```

**지원집합 = `{0,1,2}` = 어휘 전체.** 그래서 `unsupported` 는 **언제나 빈 목록**이고,
`policy.jl:1066-1086` 의 표현력 에스컬레이션은 **발화 영역이 빈 죽은 코드**다.

⚠️ 이것은 "지금 잘 돌고 있다" 가 아니라 **"한 번도 시험된 적 없다"** 는 뜻이다. 이 설계는
그 코드를 주축으로 승격시키므로, **먼저 그것이 발화할 수 있음을 음성 대조로 보여야 한다.**

### 2-3. 🔴 미등록 id 는 조용히 NOOP 이 된다 — 주조하는 세계의 지뢰

`features_agnostic.py:446`:

```python
names = MACRO_SPECS.get(int(action), [])
if not names:                       # ← 주석은 "NOOP"
    return dict(zip(PSI_AXES, (0.0,...,1.0, 0.0)))
```

`.get(..., [])` 가 **"원시연산이 0개인 진짜 NOOP"** 과 **"모르는 id"** 를 한 분기로 뭉갠다.
실행 확인:

```
psi(0)  NOOP : [0,0,0,0,0,0,0,0,1,0]
psi(99) 미등록: [0,0,0,0,0,0,0,0,1,0]
같은가 -> True
```

즉 `predict_J([macro=99 행])` 은 **예외를 던지지 않고 NOOP 의 값을 그럴듯하게 돌려준다.**
id 를 주조하기 시작하면 낡은 id 가 돌아다니게 되고, 그때 이 자리가 조용히 거짓을 만든다.
(레지스트리 적재 시점 방어는 있다 — `_macro_specs_from_registry`(`:418-433`)가 ψ 번역 없는
매크로에 대해 import 에서 죽는다. 없는 것은 **호출 시점** 방어다.)

### 2-4. 지원집합의 세 경우를 가른다 — 이 구분이 설계의 중심이다

| 후보 팔 | 오늘 무슨 일이 나나 |
|---|---|
| 레지스트리 **안**, 지원 **안** | 정상 채점 |
| 레지스트리 **안**, 지원 **밖** | ψ 는 **옳다**(레지스트리에서 유도). 모델은 22차원 서술자 공간에서 **외삽할 수 있다.** 그런데 `dspy_service.py:468` 이 `predict_J` 가 보기 **전에** 걸러낸다 |
| 레지스트리 **밖** | ψ = NOOP 벡터 → **조용히 틀린 수** (§2-3) |

🔴 **두 번째 줄이 핵심이다: 지원 필터는 모델의 능력 경계가 아니라 서비스 계층의 정책이다.**
모델은 지원 밖·레지스트리 안 팔을 채점할 *수* 있다. 그 외삽을 믿을지는 코드가 일부러 답하지
않는다(`dspy_service.py:286-288`: *"여기 없는 값을 예측하는 것은 근거 없는 외삽"*).

**이 설계는 그 정책을 유지한다** — 외삽을 믿지 않고 LLM 으로 올린다. 다만 그것을
*조용한 탈락* 이 아니라 **명시적 라우팅 판정**으로 만든다.

---

## 3. 라우팅 판정

사건마다 메뉴 `valid`(매크로 이름들)와 지원집합 `support` 가 주어진다.

```
unsupported = valid \ support
```

### 축 1 — 어휘 미달 (임계값 없음, 집합 포함 판정)

```
unsupported ≠ ∅  ⟹  escalate,  reason = "vocabulary_gap: <이름들>"
```

**이 축이 경계를 움직인다.** 새 매크로는 정의상 여기 걸리고, 학습되는 순간 정의상 안 걸린다.
임계값이 없으므로 손잡이도 없다.

### 축 2 — 판단 불가 (conformal, 손잡이 α 하나)

축 1 을 통과했을 때만 도달한다. spec `2026-08-20-reduced-state-ood-smdp-design.md` §6-3 을
그대로 쓰되 **kind 가 아니라 팔에 건다**:

1. known 라벨셋의 held-out 조각으로 `Ĵ(a)` 잔차의 `(1−α)` 분위수 `q` 를 잰다
   (유한표본 보정 `k = ceil((n+1)(1−α))`)
2. 각 팔에 예측구간 `[Ĵ(a) − q, Ĵ(a) + q]`
3. **top-1 과 top-2 의 구간이 겹치면 escalate**, `reason = "ambiguous: gap=… ≤ 2q=…"`

퇴화 경우도 escalate: 팔이 0개(`no_arms`), 팔이 1개(`single_arm` — *확신이 아니라 정보 부재다*).

⚠️ **`predict_delta_J` 를 쓰지 말 것.** `surrogate_v2.py:129-136` 이 스스로 적듯 그 뺄셈은
같은 instance 안에서 **팔에 무관한 상수**라 결정에 영향이 없다 — 표시·margin 용이다.
conformal 은 `predict_J` 의 잔차를 쓴다.

⚠️ **`surrogate_rank` 의 1순위를 top-1 으로 쓰지 말 것.** `dspy_service.py:490-497` 은
`choose(rule=SURRO_RULE)` 의 `pick` 을 0번에 **고정**한 뒤 나머지를 정렬한다. 즉 1순위가
`argmin Ĵ` 가 아니다. conformal 은 `Ĵ` 순서를 직접 써야 한다.

### 두 축의 관계

같은 질문의 두 해상도다. 축 1 은 *"이 팔이 학습 근거 안에 있기는 한가"*(이진, 집합),
축 2 는 *"근거가 있는데 그중 고를 만큼 있는가"*(연속, conformal). 축 1 을
**구간이 무한대인 퇴화 경우**로 읽으면 하나의 규칙이 된다 — 그래서 *"손잡이는 α 하나"* 라는
spec §6-3 의 원칙이 유지된다.

### 판정 우선순위 (`select_lane` 재작성)

```
1. unsupported ≠ ∅            → dspy   (vocabulary_gap)
2. dspy 레인이 없다            → canonical (사유를 남긴다)
3. 구간 겹침                   → dspy   (ambiguous)
4. 그 외                       → surrogate
```

🔴 **`escalation_allowed = get(rt,"enabled",false)` 결합을 끊는다.** 오늘은 표현력 에스컬레이션이
novelty 교정 파일 유무에 묶여 있다(`policy.jl:1064`). 어휘 미달은 novelty 와 **무관한 사실**이므로
그 게이트 뒤에 두면 안 된다. 대신 원래 그 게이트가 막으려던 것 — *"정책 비교 실행에서 조용히
레인이 바뀌는 것"* — 은 별도 손잡이(`ROUTER_DRIVES`)로 보존한다. **진단은 언제나 기록한다.**

---

## 4. 경계가 움직이는 기전 — 그리고 오늘 없는 절반

```
① 지원 밖 팔이 있는 사건 도착  → 축 1 이 LLM 으로 올린다
② LLM 이 대응한다 (Plan A/B: tool 호출, 필요하면 새 매크로 주조)
③ 결정과 결과가 기록된다
④ 안 고른 팔들의 반사실 rollout → 라벨 행                    ← 🔴 없다
⑤ 재학습 → 지원집합이 자란다                                  ← 🔴 없다
⑥ 같은 사건이 이제 surrogate 로 간다
```

**④⑤ 는 약한 게 아니라 아예 없다.** 실측:

- **재학습 자동화가 하나도 없다.** `_load_surrogate()` 는 FastAPI startup(`dspy_service.py:336`)에서
  **한 번** 적합하고 `SURRO_DATA` 를 다시 읽지 않는다. 생성→적합→재적재를 잇는 스크립트가
  레포에 없다(`regen_d20.sh` 는 라벨 생성에서 멈춘다). "재학습" = 라벨 재생성 + uvicorn 재시작.
- **반사실 라벨 생산자가 없다.** 결정 행(`run_demo.jl:281-345`)은 **집행된 한 팔**만 적는데,
  `SurrogateV2.fit`(`surrogate_v2.py:86-105`)은 **같은 instance 의 팔별** 결과를 요구한다.
  즉 *"LLM 이 OOD 를 처리하면 라벨이 쌓인다"* 는 현재 스키마에서 **따라 나오지 않는다.**
  가장 가까운 기전은 `DS_DEVIATE_AT`/`DS_DEVIATE_ARM`(`policy.jl:815-848`)인데 그 가드가
  스스로 *DP 표집용이지 surrogate 라벨용이 아니다* 라고 적는다.
- **지원집합이 어디에도 저장되지 않는다.** `_state["surro_support"]`(RAM)로만 존재하고,
  33행을 startup 에 훑어 매번 다시 만든다. 디스크의 어떤 산출물도 *"이 모델이 어떤 매크로를
  지원하는가"* 를 적지 않는다. `/health` 의 산문 문자열이 유일한 창구다.

🔴 **그러므로 이 설계의 라우터는 지어도, 그것만으로는 경계가 안 움직인다.** 라우터는
④⑤ 가 생겼을 때 **자동으로** 따라 움직이도록 만드는 것이고, ④⑤ 는 별도 작업이다.
그 사실을 숨기지 않는다.

---

## 5. 🔴 어휘 성장이 부딪히는 벽 — `vocab` 도장이 동등성 검사다

이 설계와 기존 불변식의 **가장 하중 큰 충돌**이다.

`require_vocab_stamps`(`action_registry.py:138`)는 **정확한 문자열 동등**을 요구한다.
매크로를 하나 주조하면 `v4-3arms` → `v5-4arms` 로 올라가고, 그러면 **기존 라벨 파일 전부가
한꺼번에 무효가 된다** — 매크로 0/1/2 를 이미 가르치고 있는 33행까지 포함해서.

즉 현재 도장은 **성장을 구조적으로 처벌한다.** 증분 추가 경로가 없다.

**필요한 변경:** 어휘 도장을 *세대 동등성* 과 *매크로 집합* 두 축으로 가른다.

| 도장 | 무엇을 주장하나 | 검사 |
|---|---|---|
| `vocab` (유지) | 동역학·목적함수 세대 | 동등 (지금 그대로) |
| **`train_macros`** (신설) | 이 파일이 **어떤 매크로를 가르치는가** | 부분집합: 모든 id 가 현행 레지스트리에 있는가 |

`train_kinds`(`gen_oracle_dataset.jl:1156`, write site 4곳)의 **매크로 판**이다. 그리고
`train_kinds` 의 교훈을 그대로 물려받아야 한다: 🔴 **그것은 찍히기만 하고 아무도 안 읽는다**
(`load_rows` 의 `meta` 에 없다; 생성기가 `게이트는 일부러 안 만들었다`(`:1138`)고 적는다).
**도장만 찍고 소비처를 안 만드는 것이 kind 경계가 얼어붙은 채 아무도 모르게 만든 그 실패다.**
`train_macros` 는 소비처와 **같은 커밋**에서 들어와야 한다 — 그 소비처가 바로 축 1 이다.

---

## 6. 기존 novelty 라우터와의 관계 — 분리 수술의 순서

사용자 결정: **새 라우터를 먼저 짓고, 나중에 삭제한다.**

🔴 `route()` 의 `rt` Dict 에는 라우터가 아닌 것들이 얹혀 있다. 통째로 들어내면 같이 죽는다:

| `rt` 의 키 | 실제로 무엇인가 | 처분 |
|---|---|---|
| `enabled`·`novel`·`p`·`eps`·`target` | 진짜 novelty 라우터 | **교체 대상** |
| `descriptors` | **LLM 의 수치 입력 채널** (2026-08-26 `d91b510d` 가 살린 것) | **반드시 존치** |
| `decision_index`·`deviate_*` | 1-step deviation 표집 레인의 유일한 통로 | 존치 (다른 통로로 옮기는 편이 낫다) |
| `zone_primitives` | zone 채점의 유일한 근거 (사후 재구성 불가) | 존치 |
| `llm_input`·`surrogate_input`·`energy_*` | 대시보드 데이터원 | 존치 |

⚠️ `policy.jl:1245` 는 `rt["novel"]` 을 `get` 이 아니라 **raw index** 로 읽는다 →
슬림한 Dict 를 내면 `KeyError`.

**순서:**

1. `event_descriptors`(`novelty.jl:310-372`)를 novelty 에서 떼어낸다. 라우터 코드가 아니라
   **LLM 입력 채널**이다. `test/route_descriptors_survive.jl` 이 이미 그 계약을 지킨다.
2. `rt` Dict 에서 라우터 키와 승객을 가른다. 승객에게 자기 통로를 준다.
3. `escalation_allowed` 를 `rt["enabled"]` 에서 떼어낸다 (§3).
4. 축 1 을 배선하고 **발화시킨다** — §2-2 때문에 음성 대조가 필수다.
5. 축 2(conformal)를 얹는다.
6. `novelty.jl` 과 라우터 절을 지운다. 그때 같이 지울 것:
   `src/ConstructionBots.jl` 의 export 12개 · `tools/test_novelty.jl` · `tools/test_router.jl` ·
   `regen_router_cases.sh` · `dashboard.html` 의 ROUTER 패널 · `llm_ood_eval.py` 의
   `--router`/`--novelty-calib` 축 · `shadow_score.py` 의 novelty 게이트 재생 절 ·
   `state_globals.jl:347,429,433`.

---

## 7. 반증 가능한 예측 — 이 설계의 시험지

| # | 예측 | 반증 관측 |
|---|---|---|
| **R1** | 축 1 은 **발화할 수 있다** | 지원집합에서 매크로 하나를 뺀 라벨셋으로 서비스를 띄우면 그 팔이 있는 사건이 `vocabulary_gap` 으로 격상되는가. **오늘은 support = 어휘 전체라 절대 발화 안 한다** — 이 음성 대조 없이는 축 1 이 §2-2 의 죽은 코드와 구별되지 않는다 |
| **R2** | 경계가 실제로 움직인다 | 같은 사건이, 라벨 추가 + 재적재 **전에는** `vocabulary_gap` 으로 dspy 로 가고 **후에는** surrogate 로 가는가. 이것이 이 설계 전체의 주장이다 |
| **R3** | 축 2 가 교정돼 있다 | known 사건의 escalation률이 α 근처인가 (spec §8-1). **0 이면 구간이 너무 넓어 축 2 가 아무것도 안 하는 것**이고, 그 사실을 짓기 전에 알아야 한다 |
| **R4** | 잔차가 교환가능하다 | `coverage_holdout < 1 − α − 0.05` 면 **거기서 멈춘다** (spec §6-3). surrogate 잔차가 교환가능하지 않다는 뜻이고, 그 위의 escalation 은 근거가 없다 |
| **R5** | 두 축이 서로 다른 것을 잡는다 | `vocabulary_gap` 과 `ambiguous` 의 발화 집합이 겹치는 비율. 완전히 겹치면 축 하나는 잉여다 |

---

## 8. 이 설계가 안 하는 것 (범위 선언)

- **반사실 라벨 생산자를 안 짓는다** (§4 ④). 별도 작업이고, 그것 없이는 경계가 자동으로
  안 움직인다.
- **재학습 자동화를 안 짓는다** (§4 ⑤). 오늘 "재학습" = 라벨 재생성 + uvicorn 재시작이다.
- **LLM 출력 → 새 매크로 id 경로를 안 짓는다.** 오늘 매크로 추가는 6파일 수작업이고,
  그중 `macro_to_proposal`(`policy.jl:1286-1305`)은 **빠뜨리면 조용히 빈 제안**이 된다.
  `PROPOSE_NEW` 는 심볼이 아니라 주석이다(`policy.jl:1092`).
- **`psi()` 의 호출 시점 방어를 이 문서가 정하지 않는다** (§2-3). 주조를 시작하기 전에
  반드시 필요하다 — 미등록 id 가 NOOP 으로 무너지는 것을 **에러로** 바꿔야 한다.

---

## 부록 — CLAUDE.md 정정 (2026-08-27 실측)

| CLAUDE.md 주장 | 실제 |
|---|---|
| `배포 surrogate 의 매크로 지원 집합은 학습셋이 정한다(wm_datasets.N44_PLUS78)` | `N44_PLUS78` 은 **죽은 상수**다 — 코드 소비처 0, 파일도 없다. 현행은 `ORACLE_DATASET`(`dspy_service.py:241`) |
| `require_vocab 은 여전히 소비처가 0개다` | **거짓.** 6곳이 쓴다: `gate_ng2.py:112`, `eval_surrogate_v2.py:139`(배포 적재 경로), `export_surrogate.py:143`, 테스트 셋 |
| `v3-4arms` (2026-08-20 절 전반) | 레지스트리는 `v4-3arms`, 매크로 셋(0 NOOP / 1 Replace / 2 SwapBattery) |
