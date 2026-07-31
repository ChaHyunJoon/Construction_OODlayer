# 설계: "처음 보는 OOD 는 LLM, 아는 OOD 는 surrogate"

작성 2026-07-28. 대상 = `nl_events.py`, `llm_producer.py`, `c1_novel_kind.py`,
`assimilation_stream.py`, 그리고 `oracle/gen_oracle_dataset.jl` 의 NL 저장 패치.

---

## 0. 검증하려는 주장

> 처음 LLM 이 OOD event 를 마주했을 때에는 LLM 이 자연어로 해당 상황을 해석해서 적합한 action 을
> 출력하게끔 한다. 이후 비슷한 OOD event 가 오면 LLM 대신에 surrogate model 이 빠르게 action 을
> 출력한다. 즉 완전 새로운 OOD 에는 LLM 이 adaptive 하게, 이미 봤던 OOD 에는 surrogate 가
> cost efficient 하게.

이 문장은 검증 가능한 명제 4개로 쪼개진다. 하나라도 빠지면 시스템이 성립하지 않는다.

| | 명제 | 어디서 재는가 | 상태 |
|---|---|---|---|
| **C1** | 처음 보는 종류의 OOD 에서 LLM 이 surrogate 보다 낫다 | `c1_novel_kind.py` | **1차 측정 완료 → 조건부 성립** (5절) |
| **C2** | 아는 종류에서 surrogate 가 품질 동등·비용 10⁴배 저렴 | `openworld_experiments.py loio` + `cost_eval.py` | **측정 완료** (LOIO n=60, 0.11 ms vs 81 s) |
| **C3** | 시스템이 "처음 보는 것"인지 스스로 판별해 라우팅한다 | `assimilation_stream.py` | **1차 측정 완료 → 미확립** (4-c) |
| **C4** | LLM 이 처리한 것을 surrogate 가 학습해 다음부터 싸게 처리 | `assimilation_stream.py` | **1차 측정 완료 → 성립** (4-c) |

의존 관계가 있다. **C1 을 먼저 돌린다.** C1 이 깨지면 라우터는 "더 나쁜 쪽으로 보내는 장치"가
되므로 C3·C4 는 만들 이유가 없다. C1 이 값싼 게이트 역할을 한다(약 $0.1, 몇 분).

---

## 1. 이번에 고친 두 가지 설계 오류

### 오류 1 — LLM 의 입력 모달리티가 틀려 있었다

기존 LLM 실험(`dspy_real_experiment.py`)은 `kind=battery, SoC=0.55, spares_left=8` 같은
**이미 정제된 스키마 필드**를 LLM 에 넣었다. 이건 순환 논리다 — 그 필드들이 존재한다는 것 자체가
"이 사건은 이미 아는 3종류 중 하나로 파싱되었다"는 뜻이고, 그게 바로 검증 대상 능력이다.
진짜 새로운 사건에는 `soc` 열도 `zone_overlap` 열도 없다.

문장은 **원래부터 있었다**. 주입기가 만들어 `OOD_TRUTH_LOG` 에 `(nl, truth)` 쌍으로 넣는다
(`ConstructionBots.jl/src/navigator/ood_truth.jl`). 다만 덤프에 안 실렸다.

- **라벨러 패치**: `gen_oracle_dataset.jl` 의 `capture_features` 가 `last_event_nl()` 로
  관찰 문장을 가져와 `nl` / `nl_source` 두 열로 기록한다. `truth` 쪽은 **절대 싣지 않는다**
  (채점기 전용 채널; 실으면 정답 누수).
- **기존 60인스턴스 덤프**는 `nl` 이 없다. 재생성은 라벨 1개당 약 81 초 × 300 = 수 시간.
  그래서 `nl_events.py` 가 주입기와 **같은 템플릿**으로 문장을 복원하고 `nl_source="synthesized"`
  로 표시한다. 모든 리포트가 첫 줄에 캡처/복원 비율을 찍는다.
  복원본으로는 파이프라인 개발과 1차 판독까지만 하고, **헤드라인 수치는 재생성 후에** 인용한다.

### 오류 1-b — **자연어 관찰에 정답이 산문으로 들어 있었다** (라이브 데모에서 발견, 2026-07-28)

문장을 LLM 에 주기 시작하자마자 드러난 것. 주입기의 네 템플릿이 전부 이렇게 끝난다:

| 사건 | 문장 끝부분 | = canonical 정답 |
|---|---|---|
| fault | "…; **dispatch the nearest backup robot** to take over its remaining work." | Replace |
| battery(깊음) | "… — **treat it as broken down and hand its work to a backup robot.**" | Replace |
| battery(약함) | "… **it should avoid** long-distance and heavy-payload hauls…" | Deprioritize |
| zone | "…; **restage the affected assembly** out of the restricted region." | ForbidZone |

즉 "관찰"이 아니라 **관찰 + 지시**였다. 이 문장을 그대로 주면 우리가 재는 것은 "LLM 이 상황을
해석하는 능력"이 아니라 **"문장에 적힌 지시를 따르는가"**다. `verify.py` 의 V0 는 *정답 라벨*이
LLM 산이 아님을 보장하지만, 같은 원칙이 **입력 채널**에는 적용되지 않고 있었다.

**실측 A/B** — 라이브 데모에서 실제로 나온 zone 사건(겹침 0.02 = 사실상 무해 → NOOP 이 정답),
동일 모델(gpt-4o)·동일 서술자, 문장의 지시 절만 제거:

| 입력 | LLM 이 읽은 문장 | LLM 선택 | LLM 근거 |
|---|---|---|---|
| `raw` | "…blocking a staging area; **restage the affected assembly**…" | **ForbidZone** ✗ | "harm and work at risk are minimal, **but** … requires action" |
| `observation` | "…blocking a staging area." | **NOOP** ✓ | "harm and work at risk are minimal, and there is high slack … no immediate action is necessary" |

`raw` 쪽 근거를 보면 LLM 은 서술자를 **정확히 읽고도**(harm 최소임을 인정) 문장의 지시를 따랐다.
지시를 떼자 같은 서술자로 옳은 판단을 했다. C1 에서 `llm:nl` 이 zoneblk 에서 regret 1.000 이었던
것도 이걸로 설명된다 — 모든 zone 문장이 restage 를 지시한다.

**조치**: producer 입력 경계에서 지시 절을 제거하는 `observation_only()` 를 넣었다
(`nl_events.py`, `dspy_service._nl_for_producer`). 주입기 자체는 안 건드린다(다른 데모·애니가 그
문장을 쓴다). 스위치 `LLM_NL_MODE=raw|observation`, **기본은 raw** — 모드를 바꾸면 프롬프트가
바뀌어 캐시가 전부 미스가 되고 발표된 수치가 조용히 달라지기 때문. 정직한 설정은 `observation`.

**재측정 결과 (2026-07-28, gpt-4o-mini, `c1_compare_nlmode.py`)** — 예상과 달랐고, 더 중요한 것이
나왔다.

| arm | raw | observation | Δ | 판정 |
|---|---|---|---|---|
| `llm:nl` (문장만) | 0.430 | **0.430** | +0.000 | 지시에 **전혀** 기대지 않았음 |
| `llm:nl+state` (문장+서술자6) | 0.330 | 0.540 | **+0.210** | 지시에 기대고 있었음 CI[+0.057,+0.360] |
| `llm:feat` (대조군) | 0.572 | 0.572 | +0.000 | 문장을 안 보므로 당연히 불변 |

`llm:nl` 이 **완전히 동일**했다(60개 인스턴스 전부 같은 선택). 즉 문장만 줄 때 LLM 은 지시 절이
아니라 진단 내용("critically flat at 5%", "has broken down", "no-go exclusion zone")으로 판단하고
있었다. 처음 세운 가설("지시를 따르기만 한다")은 **문장만 주는 경우에는 틀렸다.**

### 진짜 문제는 지시가 아니라 **서술자 6개가 battery 를 오도한다**는 것

폴드별로 쪼개면 Δ +0.210 은 정반대 두 효과의 합이다:

| 종류 | raw → obs | 무슨 일이 있었나 |
|---|---|---|
| battery | 0.08 → **0.81** | **Replace ×18 → NOOP ×18 전부 뒤집힘** |
| fault | 0.00 → 0.06 | 거의 그대로(Replace 12→11) |
| zoneblk | 1.00 → **0.67** | ForbidZone ×6 → NOOP (라이브 A/B 와 같은 개선) |

battery 붕괴의 원인은 서술자 값에 있다. SoC 5% 로 죽은 로봇의 서술자는:

```
harm = 0.95        (맞다)
work_at_risk = 0.02      <- agent_pending/pending_total = 4/255
resource_loss = 0.04     <- (1-soc)/n_active = 0.95/22
```

**죽은 로봇이 "위험 2%, 자원손실 4%" 로 보인다.** LLM 의 obs 근거가 그대로 말한다:
*"Lowering the task priority … minimizing the impact on overall work at risk"*.
`raw` 에서는 문장의 지시("treat it as broken down and hand its work to a backup")가 이 잘못된
숫자를 **덮어써서** 정답이 나왔던 것이다. 지시를 떼자 숫자가 이겼고, 틀렸다.

문장만 주는 `llm:nl` 이 battery 에서 0.075 로 멀쩡한 것이 결정적 증거다 — 서술자를 **추가하는 순간**
나빠진다. 즉 `nl+state` 가 `nl` 보다 나쁜 것은 LLM 탓이 아니라 **서술자 설계 결함**이다.

이건 `features_agnostic.descriptors_from_row` 가 고쳐야 할 실제 버그다: `work_at_risk` 와
`resource_loss` 가 둘 다 큰 분모(남은 작업 총량 / 활성 함대 크기)로 나눠서 "에이전트 한 대를 잃는
사건"의 심각도를 지워버린다. 빌드가 멈추는 것은 그 로봇이 함대의 4% 라서가 아니다.

> **발표 시 주의**: 4-b 표는 `raw`(지시 포함) 수치다. `nl+state` 의 0.330 은 문장에 들어 있던
> 지시가 서술자의 결함을 가려준 값이므로, 그 숫자를 "LLM 이 새 종류를 잘 읽는다"의 근거로 쓰면 안 된다.
> 정직한 짝은 `observation` 열이고, 거기서의 최고 arm 은 **`llm:nl` (0.430, 문장만)** 이다.

### 오류 2 — 정적 시험으로는 C3·C4 를 볼 수 없다

LOKO 는 "종류별 정답률" 표를 준다. 그러나 주장은 **시간에 따른 전환**("처음엔 LLM, 이후엔
surrogate")이다. 이건 스트림 위에서만 관찰된다. → `assimilation_stream.py`.

---

## 2. LLM 입력 arm 3종 (`llm_producer.py`)

| arm | 입력 | 무엇을 분리하는가 |
|---|---|---|
| `nl` | 자연어 문장만 | 선생님 설계의 문자 그대로. **단 상한 주의(3절)** |
| `nl+state` | 문장 + 물리 서술자 6개 | **배포 가능한 형태**. 서술자는 종류 이름 없이 계산되므로 새 종류에도 존재한다 |
| `feat` | 파싱된 스키마 필드 | **대조군**. 이 필드는 새 종류엔 없다. `nl*` vs `feat` = "언어이해인가 스키마 사전지식인가" 분해 |

LLM 에 **주지 않는 것**: 종류별 valid mask(종류 이름에서 나온 것 = 누수). 5개 매크로 전체를
항상 보여주고, 고른 뒤 valid mask 로 거른다 — surrogate 의 `pick_with_gate` 와 **같은 위치의**
후처리라서 비교가 공정하다.

모든 응답은 `llm_cache/` 에 저장된다. 재실행은 공짜·재현 가능하고, `LLM_OFFLINE=1` 이면 새 호출을
금지해 API 없이 결과를 재도출할 수 있다. `LLM_MOCK=1` 은 규칙기반 가짜 응답(배선 점검 전용).

---

## 3. 반드시 같이 봐야 하는 상한: NL-only ceiling

이 데이터셋은 **일부러** 두 쌍에 같은 문장을 준다 (`gen_oracle_dataset.jl` 주석에 명시):

| 유해 | 무해 | 정답 |
|---|---|---|
| `fault` (agent_pending > 0) | `faultidle` (agent_pending = 0) | Replace / NOOP |
| `zoneblk` (pending staging 를 덮음) | `zoneharm` (빈 바닥) | ForbidZone / NOOP |

모델이 "사건 이름"을 지름길로 쓰지 못하게 하려는 설계였다. 결과적으로 **문장만 받은 producer 는
두 변종을 원리적으로 구분할 수 없다** — LLM 이 나빠서가 아니라 정보가 없어서다.

`nl_events.nl_partition_ceiling()` 이 그 한계를 숫자로 준다. 현 데이터에서:

```
6 distinct sentences over 60 instances
best achievable mean regret with NL alone = 0.100
  그 중 fault/faultidle 그룹(18 instances) 만으로 regret 0.333
```

즉 `llm:nl` arm 은 0 이 아니라 **0.100 과 비교**해야 공정하다. 참고로 surrogate 의 LOKO regret 도
0.100 이다 — 문장만으로는 원리적으로 surrogate 를 못 이긴다는 뜻이고, 그래서 `nl+state` arm 이
제안의 핵심이 된다.

식별자 마스킹 주의: 로봇 번호·좌표는 정답을 안 바꾸므로 `nl_semantic_key()` 가 가린 뒤 묶는다.
안 가리면 "모든 문장이 유일 → 상한 0" 이라는 가짜 결론이 나온다(첫 구현이 실제로 그랬다).

---

## 4. 스트림 하네스 (`assimilation_stream.py`)

```
스트림:  [fault, zoneblk, fault, ... | BATTERY 최초 등장, 그 뒤 반복 등장]
          surrogate 가 아는 종류      ^ onset
```

매 사건마다: ① 게이트가 낯섦 판정 → ② 낯설면 LLM, 익숙하면 surrogate → ③ LLM 이 처리한 사건만
오라클로 라벨링(후보 5개 전부 rollout) → 학습풀 추가 → surrogate 재학습.

③ 을 "LLM 이 처리한 것만" 으로 제한하는 이유: surrogate 가 자신있게 답한 것까지 라벨링하면 그건
그냥 매번 오라클을 부르는 것과 같아져 비용 절감이 사라진다.

### 정책 6개 (같은 스트림 위에서)

| 정책 | 역할 |
|---|---|
| `oracle` | 매 사건 5개 rollout. regret 0, 최대 비용. 품질 상한 |
| `frozen` | surrogate 만, 재학습 없음. **새 종류에서 무너지는가** = C1 의 스트림판 |
| `always_llm` | 매 사건 LLM. 품질 참조 + 비용 상한 |
| `gated+assim` | **제안 방식** |
| `gated_no_assim` | 같은 게이트·같은 LLM, 재학습만 끔. **C4 의 대조군** |
| `random_router` | 게이트가 쓴 것과 **같은 예산**을 무작위로 씀. **C3 의 진짜 시험** |
| `gated_oracle` | 낯설면 그 자리에서 플래너로 확인(E3 의 ACTIVE). **LLM 이 대체하려는 바로 그것** |

### 게이트 — 어떤 신호를 쓸지는 취향이 아니라 측정 결과다

`--gate=novelty`(**기본**) = conformal covariate novelty. `--gate=disagreement` = forest 안
나무들의 합의율. 임계값은 **아는 종류 데이터에서** 오경보율 `--target-rate`(기본 15%)가 되도록
보정한다(합의율은 학습에 쓴 instance 에서 재면 과대평가되므로 부트스트랩 풀 안에서 leave-one-out).

이 하니스로 측정한 값 (novel=zoneblk):

| 게이트 | 새 종류를 LLM 으로 보낸 비율(recall) | 보낸 것 중 새 종류였던 비율(precision) |
|---|---|---|
| `disagreement` | **0.00** | 0.00 |
| `novelty` | **0.94** | 0.75 |

**왜 disagreement 가 실패하는가**: 처음 보는 종류에서 forest 는 *자신있게 틀린다*. 모든 나무가
그 입력 영역에 대한 근거가 없으므로 **똑같이** 엉뚱한 답을 지지한다 → 합의율이 높다 → "확신함"으로
읽힌다. 반면 covariate novelty 는 "학습 입력 분포에서 얼마나 멀리 있는가"를 재므로, '새 종류'의
정의와 직접 맞닿아 있다.

5절 게이트 비교(`openworld_experiments.py gate`)에서 disagreement 가 최우수였던 것과 모순되지
않는다. 그건 **고정 예산에서 "언제 플래너로 확인할까"** 문제였고, 여기는 **"이건 새로운 종류인가"**
문제다. 다른 질문이라 다른 신호가 이긴다.

### 게이트 갱신 — 이게 없으면 C4 는 원리적으로 불가능

동화가 일어나면 novelty 보정값(`mu/sd/cal`)도 **커진 학습풀로 다시 맞춰야** 한다(`refresh_gate`).
처음 구현이 이걸 빼먹었고, 그 결과 게이트가 새 종류를 잘 잡아내고도(recall 0.94) 호출률이 영원히
0.94 에 머물렀다 — 그 종류를 다 배운 뒤에도 "낯섦" 기준이 부트스트랩 시점 분포에 고정돼 있어서,
시스템이 **"이제 이건 익숙하다"고 말할 방법 자체가 없었다.** 고친 뒤:

```
policy             앞쪽 절반   뒤쪽 절반    감소
gated+assim          0.35      0.09     +0.26     <- 인계가 일어난다
gated_no_assim       0.94      0.94     +0.00     <- 재학습을 끄면 영원히 LLM
```

`test_assimilation.py` 의 T8 이 이 전제(동화 후 낯섦 점수 하락)를 상시 감시한다.

### C4 곡선의 x축은 스트림 위치가 아니다

**이 함정에 한 번 빠졌다.** 스트림 위치를 x축으로 그리면, 새 종류가 섞여 들어오는 것만으로
호출률이 올라가서 "학습에 의한 감소"와 "등장빈도 변화"가 뒤섞인다(첫 구현에서 감소가 아니라 증가로
나왔다). x축을 **"이 새 종류의 k 번째 사건"** 으로 바꾸면 축 자체가 노출량이 되어, 곡선의 하강이
곧 학습의 효과다. `novel_ordinal_curve()` 가 그걸 그린다.

### 비용은 측정값이고, **두 축으로 나눠 센다**

- 플래너 초 = 그 instance 의 `label_seconds`(덤프에 기록된 실제 벽시계). 오라클 라벨 = 5 rollout.
- LLM 초 = 이번 실행에서 측정한 평균(약 1.5 s).
- surrogate = 0.11 ms (`cost_eval.py` 측정값).

**대기초(decision_seconds)** = 로봇이 답을 기다리며 멈춰 있는 시간 = 임계 경로.
**배치초(background_seconds)** = 결정을 내린 **뒤** 오프라인으로 정답 라벨을 만드는 시간.

이 구분이 없으면 제안이 자기모순이 된다. 처음 구현은 둘을 더해 "gated+assim = 211 초/사건"으로
찍었는데, 그 숫자대로면 어차피 오라클을 돌려 정답을 아는 셈이라 **LLM 에게 물어볼 이유가 사라진다.**
설계 의도는 "결정은 LLM 이 즉시, 라벨은 나중에 배치로"이므로 축을 나누는 것이 옳다.

그래서 임계 경로에서 오라클을 부르는 경쟁자 `gated_oracle`(= E3 의 ACTIVE)을 같은 표에 넣었다.
novel=zoneblk, 6시드 실측:

| policy | regret | novel-kind regret | 대기초/사건 | 배치초/사건 |
|---|---|---|---|---|
| `frozen` | 0.248 | 0.500 | 0.00 | 0 |
| `gated+assim` | 0.203 | 0.426 | **0.21** | 224 |
| `gated_oracle` | **0.126** | **0.204** | **223.65** | 0 |
| `oracle` | 0.000 | 0.000 | 1630 | 0 |

**이것이 LLM 의 실제 값어치다**: 결정 품질은 `gated_oracle` 이 더 좋지만(+0.077 regret 차이),
`gated+assim` 은 그 결정을 **1000배 빠른 임계 경로**로 낸다. 발표에서 주장해야 할 문장은
"LLM 이 더 잘 결정한다"가 아니라 "**LLM 이 플래너를 임계 경로에서 몰아낸다**"이다.

---

## 4-b. C1 1차 측정 결과 (gpt-4o-mini, 2026-07-28, 문장은 복원본)

```
held-out kind  regime            nl-ceil  surrogate   llm:nl  llm:nl+state  llm:feat   noop  random
battery        action-supported    0.000     0.000     0.075      0.075       0.683    0.733   0.243
fault          action-supported    0.333     0.333     0.333      0.000       0.329    0.655   0.278
zoneblk        action-supported    0.000     0.000     1.000      1.000       0.667    0.000   0.611
평균                                0.100     0.100     0.430      0.330       0.572    0.490   0.364
```

읽는 법 — **평균만 보면 결론을 놓친다**:

- 평균으로는 surrogate(0.100)가 최고 LLM arm(0.330)을 유의하게 이긴다 → "C1 평균 미성립".
- 그러나 **surrogate 가 실패하는 유일한 종류인 `fault` 에서, `llm:nl+state` 는 regret 0.000** 이다.
  surrogate 는 0.333, 그리고 그 0.333 은 NL-only 상한과 정확히 같다 — 즉 문장만으로는 못 풀고,
  문장+물리서술자를 함께 준 arm 만 풀었다. (`work_at_risk` 가 fault↔faultidle 을 가른다.)
- 반대로 `zoneblk` 에서는 정답이 언제나 NOOP 인데 LLM 은 계속 개입해서 1.000 으로 최악이다.

**따라서 C1 은 "조건부 성립"이다**: LLM 은 *surrogate 가 전이에 실패한 종류에서만* 이긴다.
이건 라우팅을 무너뜨리는 결과가 아니라 **라우팅이 필요한 이유**다 — '항상 LLM' 도 '항상 surrogate'
도 두 폴드 모두에서 최선이 될 수 없고, 어디로 보낼지 고르는 장치가 있어야 한다.

부수적으로 얻은 분해: `llm:feat`(0.572) < `llm:nl+state`(0.330), 차이 +0.242 CI [+0.082,+0.394].
정제된 스키마 필드를 주는 쪽이 **더 나빴다**. LLM 의 이득은 스키마 사전지식이 아니라 사건 서술을
읽는 데서 온다는 뜻이고, 이는 새 종류로 옮겨갈 때 유리한 방향이다.

비용: 실호출 115회 / 49k 토큰 / 140초. 캐시되어 재실행은 무료.

---

## 4-c. C3·C4 1차 측정 결과 (gpt-4o-mini, 12시드, 게이트=novelty, 문장은 복원본)

```
[서술자 수정 전]                        [서술자 수정 후 = 현재]
novel kind  frozen여유    C3         C4        frozen여유    C3         C4
battery       +0.050   미확립(+0.031) 미확립     +0.067   미확립(+0.007) 미확립   <- 전이됨. 무대 부적합
fault         +0.306   미확립(-0.052) 성립+0.21  +0.333   미확립(+0.003) 성립+0.18
zoneblk       +0.528   미확립(-0.030) 성립+0.26  +0.694   미확립(+0.056) 성립+0.23
```

수정 후 달라진 점: C3 의 차이값이 **전부 양수로 바뀌었다**(이전에는 fault/zoneblk 에서 무작위
라우터가 오히려 유의하게 좋았다). 여전히 통계적으로 유의하진 않지만, "게이트가 무작위보다 나쁘다"는
상태에서 "나쁘지는 않다"로 올라왔다. zoneblk 에서 gated+assim 0.281 vs random 0.336 vs frozen 0.338.

### C4 는 성립했다

`artifacts_assimilation/curve_zoneblk.png` 가 선생님이 그린 그림 그대로다.
새 종류의 k번째 사건을 LLM 으로 보낸 비율:

```
그 종류의 k 번째 사건:   1     2     3     4     5     6     7     8     9    10
gated+assim           1.00  0.50  0.42  0.25  0.17  0.25  0.08  0.17  0.00  0.17
gated_no_assim        1.00  1.00  1.00  1.00  1.00  1.00  1.00  1.00  1.00  1.00
random_router         0.08  0.08  0.17  0.08  0.25  0.08  0.25  0.08  0.25  0.08
```

처음 만난 순간에는 **100% LLM 으로**, 아홉 번째쯤에는 거의 0. 재학습만 끄면 **영원히 100%**.
같은 게이트·같은 LLM 이므로 이 차이를 만드는 것은 학습뿐이다. 무작위 라우터는 애초에 새 종류를
못 짚어서 평평하다(게이트가 실제로 종류를 골라내고 있다는 방증).

동일한 게이트·동일한 LLM 인데 **재학습 유무만으로** 갈린다 → 감소의 원인이 학습임이 분리된다.
그동안 누적 regret 은 `frozen` 보다 **낮게** 유지된다(오른쪽 패널).

### C3 는 성립하지 않았다 — 그리고 그게 중요한 정보다

같은 LLM 예산을 쓰는 무작위 라우터가 게이트와 동등하거나 **약간 더 좋았다**(fault 폴드는
CI [-0.102,-0.004] 로 무작위 우세가 유의). 게이트가 새 종류를 잘 짚는데도(recall 0.94까지) 그렇다.

원인은 명확하다. **이 루프에서 이득을 만드는 것은 라우팅이 아니라 동화(오라클 라벨링 + 재학습)다.**
무작위 라우터도 똑같이 라벨을 사서 재학습하므로, 라벨을 *어디에* 쓰느냐보다 *얼마나* 사느냐가
지배적이다. 게다가 LLM 은 `zoneblk` 에서 regret 1.000(항상 개입, 정답은 항상 NOOP)이라, 그 종류로
결정을 보내는 것 자체가 손해다.

따라서 지금 정직하게 말할 수 있는 것은:

> "새 종류를 만나면 그 사건들에 오라클 라벨을 사서 재학습하라"는 확실히 이득이다(C4).
> "게이트로 골라 LLM 에게 결정을 맡기는 것"은 아직 무작위 대비 우위를 보이지 못했다(C3 미확립).

C3 를 세우려면 (a) LLM 이 실제로 이기는 종류에서만 라우팅하거나(C1 의 폴드별 결과와 연결),
(b) 라벨 예산을 고정한 채 **라우팅만** 비교하는 설계가 필요하다. 후자가 다음 실험이다.

### LLM 의 진짜 값어치는 품질이 아니라 임계 경로다

novel=zoneblk, 12시드:

(서술자 수정 후, novel=zoneblk, 12시드)

| policy | regret | novel-kind regret | 대기초/사건 | 배치초/사건 |
|---|---|---|---|---|
| `frozen` | 0.338 | 0.694 | 0.00 | 0 |
| `always_llm` | 0.459 | 1.000 | 1.50 | 0 |
| `random_router` | 0.336 | 0.736 | 0.18 | 188 |
| **`gated+assim`** | **0.281** | 0.597 | **0.18** | 121 |
| `gated_oracle` | **0.209** | **0.398** | **120.96** | 0 |
| `oracle` | 0.000 | 0.000 | 1609 | 0 |

`gated_oracle`(낯설면 그 자리에서 플래너 확인)이 결정은 더 잘한다. 그러나 그 답을 받으려면
빌드가 **사건당 211초** 멈춘다. `gated+assim` 은 **0.21초**에 답을 낸다 — 1000배.
발표에서 주장할 문장은 "LLM 이 더 잘 결정한다"가 아니라
**"LLM 이 진짜 플래너를 임계 경로에서 몰아낸다"** 이다.

---

## 4-d. 서술자 계산식 수정과 그 효과 (2026-07-28 저녁)

4-b/4-c 에서 드러난 "LLM 이 배터리 사건 18건 전부를 교체→방치로 뒤집는" 문제의 원인은 LLM 이
아니라 **서술자 계산식**이었다. 죽은 로봇 하나가 이렇게 보이고 있었다:

```
work_at_risk  = 4 / 255      = 0.016     남은 일 '전체'로 나눔
resource_loss = 0.95 / 22    = 0.043     함대 크기로 또 나눔
harm          = severity                  ← 고장에서는 실험자가 붙인 정답표
```

세 곳을 고쳤다(`features_agnostic.py` + Julia 쌍둥이 `src/safety/novelty.jl`):

| | 이전 | 이후 | 이유 |
|---|---|---|---|
| `work_at_risk` | `쥔작업 / 남은일전체` | `쥔작업 / 로봇 한 대 평균 몫` | 빌드는 함대 비율에 비례해 멈추지 않는다. 0.016 → 0.345 |
| `resource_loss` | `(1-잔량) / 함대크기` | `(1-잔량)` | 같은 병. 0.043 → 0.950 |
| `harm` (고장) | `severity` | `1.0` 고정 | severity 는 덤프에선 정답표, 실전에선 상수 1.0 → 학습에서만 통하는 지름길 |

### 효과 ①: 결정 품질 (`descriptor_ablation.py`, 60 instances)

| | 정답표 있음 | 정답표 없음(실전) |
|---|---|---|
| 이전 정의 | 0.082 | 0.072 |
| harm 만 남기고 축소(4개) | 0.067 | **0.167** ← 정답표에 기대고 있었음 |
| **수정 정의** | **0.033** | **0.033** ← 정답표 유무와 무관 |

### 효과 ②: LLM 이 이제 지시 없이도 옳게 판단한다 (`c1_compare_nlmode.py`)

`llm:nl+state` 의 raw(지시 포함) vs observation(지시 제거):

| | 이전 서술자 | 수정 후 |
|---|---|---|
| raw | 0.330 | 0.430 |
| observation | 0.540 | **0.330** |
| Δ | **+0.210** 지시에 기대고 있었음 | **−0.100** 지시가 오히려 방해 (CI[−0.183,−0.033]) |
| battery 폴드 | 0.08 → **0.81** (18건 전부 뒤집힘) | 0.08 → **0.08** (안정) |
| fault 폴드 | 0.00 → 0.06 | 0.33 → **0.00** |

부호가 뒤집혔다는 것이 핵심이다. 이전에는 문장의 지시가 잘못된 숫자를 덮어줘야 정답이 나왔고,
이제는 숫자가 옳으니 지시가 오히려 개입을 부추기는 방해물이 되었다. **정직한 설정(observation)이
동시에 가장 좋은 설정이 되었다** — 더 이상 "정직함의 대가"를 치르지 않는다.

### 효과 ③: 새 종류 탐지율 (라우터)

각 종류를 교정에서 빼고 그 종류가 낯설다고 판정되는 비율:

| 정의 | battery | fault | zoneblk |
|---|---|---|---|
| 이전 6개 | 0.00 | 0.67 | 0.67 |
| 수정 5개 (resource_loss 제거) | 0.00 | 0.33 | 0.33 |
| **수정 6개 (되살림)** | 0.00 | 0.33 | **1.00** |

### 지운 걸 되살린 이유 — 기록해 둘 교훈

`resource_loss` 는 분모를 없애고 나면 로봇 사건에서 `harm` 과 **같은 값**이다. 결정 품질로는
빼도 손해가 없었다(LOIO 0.033 동일). 그런데 빼자 **새 종류 탐지율이 반토막**(zoneblk 0.67→0.33)
났다. 이유: 그 값은 공간 사건에서 0 이므로 **"이 사건이 로봇에 붙었나 공간에 붙었나"를 담는
유일한 축**이고, 로봇 사고만 보던 판별기에게 구역 사고가 낯설어 보이게 하는 근거가 바로 그것이다.

> **결정에 불필요한 특징이 판별에는 필수일 수 있다.** 같은 표현을 두 소비자(고르는 쪽 / 알아채는
> 쪽)가 쓰는 시스템에서는, 한쪽 기준만으로 특징을 지우면 다른 쪽이 조용히 망가진다.

남은 약점: `zoneblk` 에서 LLM 은 여전히 1.00(항상 개입, 정답은 대체로 NOOP)이다. 구역 사건에
대한 LLM 의 과잉개입 성향은 서술자 수정으로 고쳐지지 않았다.

---

## 5. 실행 순서

```bash
cd wm4spacecraft_manufacturing

# 0) 자기점검 8문항 (API 호출 0회, 몇 초)
python test_assimilation.py

# 0-b) 배선 점검 (API 호출 0회, mock 응답)
LLM_MOCK=1 python c1_novel_kind.py
LLM_MOCK=1 python assimilation_stream.py --novel=zoneblk --seeds=3

# 1) NL 채널 점검 + 상한 확인
python nl_events.py oracle/out/openworld_merged.jsonl

# 2) C1 -- 이게 게이트다. 여기서 LLM 이 지면 C3/C4 는 보류.
LLM_MODEL=gpt-4o-mini python c1_novel_kind.py --json=artifacts_assimilation/c1.json
LLM_MODEL=gpt-4o-mini python c1_novel_kind.py --fewshot          # demo 는 학습 종류에서만

# 3) C3+C4 -- 종류 3개 각각을 '새 종류'로 두고 (게이트 기본값 = novelty)
python assimilation_stream.py --novel=all --seeds=16 \
       --json=artifacts_assimilation/stream.json \
       --plot=artifacts_assimilation/curve.png
python assimilation_stream.py --novel=zoneblk --gate=disagreement   # 게이트 신호 비교용

# 4) 확정본: 라벨러를 다시 돌려 진짜 문장을 받은 뒤 2·3 반복
cd oracle && DS_OUT=out/nl_v1.jsonl julia +lts --project=.. gen_oracle_dataset.jl
```

---

## 6. 정직한 한계 (인용 전에 반드시 읽을 것)

1. **문장이 복원본이다.** 라벨러 패치 이전 덤프에는 `nl` 이 없다. 복원본은 주입기의 문구와 severity
   분기까지 같지만 로봇 번호·좌표는 익명화된다. `nl` 계열 헤드라인 수치는 재생성 후에 인용한다.
2. **스트림은 replay 다.** 60개 오라클 라벨을 재생하는 것이지 실시간 시뮬레이션이 아니다. 한 스트림
   안에서 같은 instance 는 반복되지 않으므로, "그 종류를 배웠다"는 **같은 종류의 다른 instance 로의
   일반화**를 뜻한다. 옳은 시험이지만 표본이 작다(종류당 18~24).
3. **onset 이 스크립트다.** 자발적 drift 탐지는 이 하니스가 아니라 `e3_drift.py` 의 역할이다.
4. **전이가 되는 종류에서는 라우팅이 원리적으로 불필요하다.** 현 데이터의 LOKO regret 은 battery
   0.000 / zoneblk 0.000 / fault 0.333 이다. 즉 battery·zoneblk 는 "처음 봐도" 기존 지식으로
   풀린다. 그런 종류를 무대로 C3/C4 를 보여주면 이득이 없는 게 정상이다. 스크립트가 각 종류마다
   `frozen 여유`(= always-surrogate 가 오라클보다 얼마나 나쁜가)를 먼저 찍고, 0.02 미만이면
   "이 종류는 라우팅 무대로 부적합"이라고 명시한다.
5. **C1 이 안 서면 C3/C4 는 배포 근거가 아니다.** 잘 도는 라우터라도 더 나쁜 producer 로 보내는
   것이면 시스템을 나쁘게 만든다.

---

## 7. 기존 자산과의 관계 (아무것도 삭제·변경하지 않았다)

| 기존 | 상태 |
|---|---|
| `openworld_experiments.py` (loio/loko/gate) | 그대로. 새 스크립트가 `load_df`/`pick_with_gate`/`valid_macros_of` 를 **가져다 쓴다** |
| `verify.py` (norm_regret, oracle_best_macro, paired_bootstrap) | 그대로. 채점 정의를 공유하므로 숫자가 비교 가능 |
| `surrogate_model.py` | 그대로. 평가·배포 단일 정의를 계속 유지 |
| `features_agnostic.py` | 그대로. `nl+state` arm 이 이 서술자를 그대로 쓴다 |
| `e3_drift.py`, `e4_ablation.py` | 그대로. drift **탐지** 실험은 별건 |
| `dspy_real_experiment.py` | 그대로. `feat` arm 의 선행 연구로 남는다 |
| `gen_oracle_dataset.jl` | **가산적 패치만**: `nl`/`nl_source` 두 열 추가. 기존 열·라벨 로직 무변경 |
