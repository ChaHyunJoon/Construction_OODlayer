# robot breakdown 의 OOD 를 무엇으로 정의할 것인가 — 조사 + 축 설계 (2026-08-12)

> 상태: **설계 제안서.** 코드 변경 없음. 측정치 없음(있는 숫자는 전부 기존 덤프/문서에서 인용).
> 배경 문서: `BATTERY_FAULT_REDESIGN_2026-08-05.md`(battery severity 재설계),
> `src/respec/docs/simulator_ood_1-1_robot_breakdown_design_2026-06-26.md`(1-1 고장 파이프라인).

---

## 0. 요약 — 세 문장

1. battery 는 severity 를 `soc` **하나의 연속 스칼라**로 쓸 수 있는데, fault 는 학습셋에서
   severity 가 **{0.0, 1.0} 두 점뿐**이고 featurizer 는 그 값을 **일부러 안 읽는다**(harm=1.0 고정).
   그래서 "고장 심각도로 OOD 정의"가 지금은 **원리적으로 불가능**하다.
2. 문헌상 로봇 고장은 심각도가 아니라 **(강도 × 양식 × 다중성 × 지속성 × 구조적 위치)** 의
   다차원이다. 따라서 fault 의 OOD 는 battery 처럼 축 하나가 아니라 **2계층**으로 정의하는 게 맞다:
   **Type-1 = 강도 외삽**(battery 와 동형, 스칼라 하나), **Type-2 = 양식 신규**(학습에 축 자체가 없음).
3. Type-1 을 만들 스칼라로 **잔존 능력 ρ(residual capability)** 를 제안한다 — battery 의 derate
   기계를 그대로 재사용할 수 있고, `harm = 1 − ρ` 로 descriptor 에 **부호 일관되게** 실린다.

---

## 1. 진단 — 지금 fault 에 severity 축이 없는 이유 (코드 근거)

### 1-a. 학습셋의 severity 분포 (`oracle/out/n44_plus78.jsonl`, 실측)

| kind | rows | severity 값 |
|---|---|---|
| battery | 179 | `0.02, 0.05, 0.12, 0.2, 0.3, 0.35, 0.5, 0.6` (**8칸, 연속축**) |
| zoneblk | 32 | `0.0, 0.5, 0.9` (3칸) |
| **fault** | **75** | **`0.0, 1.0`** (2칸 = 유해/무해 **이진 라벨**) |

fault 의 `1.0` 은 "얼마나 심하게 고장났나"가 아니라 **"일을 쥔 로봇을 때렸나(1.0) / 노는 로봇을
때렸나(0.0)"** 라는 실험자 라벨이다(`gen_oracle_dataset.jl` 의 `fault` vs `faultidle`).
즉 **강도 축이 아니라 표적 선정 축**이다.

### 1-b. featurizer 는 그 값을 읽지 않는다 (그리고 그게 옳다)

`features_agnostic.py :: descriptors_from_row`:

```python
if has_soc:      harm = 1.0 - soc      # battery: 연속
elif is_spatial: harm = zov            # zone: 연속
elif is_agent:   harm = 1.0            # fault: 상수 1.0  ← 여기
```

주석에 이유가 적혀 있다: 그 severity 는 **학습 덤프에서만 존재하는 정답표**이고 배포 경로
(`policy.jl`)에서는 **모든 고장에 1.0 인 상수**다. 그걸 읽는 표현은 평가에서만 좋아 보이고
현장에서 무너진다(실측 LOIO regret 0.067 → 0.167).

> **결론:** fault 의 OOD 를 severity 로 정의하려면 **먼저 severity 를 "실측 가능한 물리량"으로
> 만들어야 한다.** 지금 값을 그대로 쓰면 배포에서 사라지는 정보로 OOD 를 정의하는 셈이 된다.
> 이것이 battery 와의 진짜 차이다 — battery 의 `soc` 는 배포에서도 관측되는 실제 상태값이다.

### 1-c. 그리고 fault 사건은 지금 **공간 피해가 측정되지 않는다**

`fault_robot!(env; obstacle=true, …)`(기본값)은 고장 로봇 자리에 **정적 장애물**을 등록한다
(`add_restriction_zone!(:fault_r, …)`). 그런데 덤프의 fault row 는 `zone_overlap = -1.0` 이다
(실측). 즉 **"고장 로봇이 통로를 얼마나 막았나"는 아무 열에도 안 들어간다.** 이건 §4-F 의 축이
그냥 놀고 있다는 뜻이기도 하고, descriptor 의 `is_agent` / `is_spatial` 분기가 **배타적**이라
혼합 사건을 표현할 자리가 없다는 뜻이기도 하다.

---

## 2. 조사 — 실제 제조/로봇 현장의 고장·사고는 어떻게 분류되나

### 2-a. 고장의 **시간 프로파일**: abrupt / incipient / intermittent

PHM(고장예지·건전성관리) 문헌의 표준 3분류다.

- **abrupt(급변, stepwise)** — 계단식으로 즉시 능력 상실. **지금 시뮬레이터의 유일한 모드.**
- **incipient(점진, drifting)** — 마모·마찰 증가처럼 서서히 악화. 로봇 매니퓰레이터에서는
  전동부 마찰 특성의 변화로 조기 진단한다. 산업용 로봇의 수명(10~15년)을 결정하는 것이
  드라이브·기어·베어링 마모라는 점에서 **현장에서 가장 흔한 모드**다.
- **intermittent(간헐)** — 떴다 사라졌다. 스웜 연구에서 "간헐적 액추에이터 dropout" 을
  별도 fault type 으로 주입한다.

→ **함의:** "고장 = 영구 정지"는 세 모드 중 하나만 구현한 것이다. 나머지 둘이 통째로 OOD 후보다.

### 2-b. 고장의 **관측 모델**: fail-stop / fail-stutter / Byzantine

분산시스템의 고전 스펙트럼이 그대로 적용된다.

- **fail-stop** — 멈추고, **다른 노드가 그 사실을 안다**. 단순해서 널리 쓰이지만 "지나치게
  단순하다"는 비판을 받는 모델. **지금 시뮬레이터가 이것**(고장 즉시 `faulted_robots()` 에 등록되고
  NL 이 발화된다 = 완벽한 관측).
- **fail-stutter** — fail-stop 과 Byzantine 사이의 중간 지대(성능은 무너졌는데 살아는 있음).
- **Byzantine** — 임의의 잘못된 상태를 **정상인 척** 보고.

→ **함의:** 지금의 OOD 는 전부 "정확히 관측되는 고장"이다. **관측이 틀린 고장**(로봇은 OK 를
보고하는데 실제로는 작업이 안 됨)은 축 자체가 없다.

### 2-c. **다중·상관 고장**: CCF(공통원인) vs CAF(연쇄)

- **CCF(common cause failure)** — 둘 이상이 **하나의 공유 원인**으로 동시에 고장. 특히
  **여분(redundancy)을 둔 시스템에서 위험**하다 — 예비들이 독립적으로 고장난다는 가정이 깨지기 때문.
- **CAF(cascading)** — 하나의 고장이 도미노처럼 번짐.

AMR/AGV 현장 문헌이 짚는 **실제 공통원인**이 구체적이다: **Wi-Fi/네트워크**가 함대 규모에서
병목이 되며, 이는 사람 중심 네트워크에는 없는 로봇 고유의 고장 양식이다. 그 밖에
fleet control ↔ 현장 PLC/WMS ↔ 안전 인터록 사이의 상호작용이 흔한 고장 지점으로 꼽힌다.

→ **함의:** 이 레포는 **spare pool 이라는 여분 시스템**을 갖고 있다. CCF 는 그 여분 가정을
정확히 겨냥하는 OOD 다(§4-C).

### 2-d. **갑작스러운 사고**: OSHA 중대재해 보고 분석 (2015–2022, 77건)

- 고정형 로봇 54건 / 66명 부상, 이동형 로봇 23건 / 27명 부상.
- 반복되는 주제가 **"sudden and unexpected actuation"(갑작스러운 예기치 못한 구동)** 과 끼임.
- 원인으로 예상 밖 움직임, 부품 오작동, **예상치 못한 프로그램 변경**이 꼽힌다.

또 AMR 운용 문헌은 **안전 인터록/E-stop 발화**를 일상적 정지 원인으로 다룬다. 즉 현장에서
"로봇이 멈췄다"의 상당수는 **영구 고장이 아니라 일시 정지**다.

### 2-e. 부분 고장이 **집단 성능**을 어떻게 망가뜨리나

다로봇 문헌: 개별 로봇의 **부분 고장(예: 액추에이터 결함)이 집단 운동을 극적으로 저하시키고
전역 임무 성능을 악화**시킨다. 그리고 다로봇 시스템은 **일시적 교란**(간헐 센서 두절, 통신 지연)과
**영구 고장**(액추에이터 결함, 에너지 고갈, 임무 중 로봇 완전 상실)을 **함께** 겪는다.

→ **함의:** "완전 상실"만 학습한 정책은 문헌이 말하는 고장 스펙트럼의 한쪽 끝만 본 것이다.

### 2-f. OOD 벤치마크 쪽의 관례

비전 쪽 관례는 **shift severity 를 점증**시키며 재는 것이고, 중간 강도에서 멀쩡하던 모델이
**강도를 조금 더 올리면 파국적으로 무너지는** 취약성이 반복 관찰된다. 그래서 "정도와 난이도가
다양한 넓은 스펙트럼"으로 평가하라는 것이 권고다.

→ **함의:** battery 에서 이미 하고 있는 것(severity 사다리)이 정석이고, fault 도 같은 형식이
되어야 두 종류를 **같은 자로 잴 수 있다.**

---

## 3. 설계 원칙 — battery 재설계에서 이미 값을 치른 교훈 두 개

이 레포가 battery 에서 배운 것을 fault 에 그대로 적용해야 한다. 안 그러면 같은 함정을 다시 밟는다.

> **원칙 P1 — 사다리 칸은 *거동 임계*를 걸쳐야 한다.**
> 옛 battery 사다리 `0.05 / 0.12` 는 둘 다 정지 임계(0.15) 아래라 **거동이 완전히 동일**했다.
> "같은 사건을 두 번 잰 것." severity 를 숫자로 나눠도 엔진에 그 숫자를 받는 **구간이 없으면**
> 칸은 존재하지 않는다. → **fault 에 사다리를 만들려면 엔진에 먼저 구간을 만들어야 한다.**

> **원칙 P2 — 칸마다 *정답을 가르는 기준*이 달라야 한다.**
> 새 battery 사다리는 `0.02` = **완주 가능성**(feasibility), `0.30` = **시간**(makespan),
> `0.50` = **무영향**(섭동 바닥 0.775 s 안)으로 세 칸이 서로 다른 기준으로 갈린다.
> 세 칸이 전부 같은 기준으로 갈리면 사다리가 아니라 반복이다.

> **원칙 P3(새로 추가) — severity 는 *배포에서도 관측되는 상태값*이어야 한다.**
> §1-b 의 실측이 이유다. 실험자만 아는 라벨로 정의한 OOD 는 벤치마크에서만 존재한다.

---

## 4. OOD 정의 축 후보 — 6개

각 축을 **(정의 / 문헌 근거 / 시뮬레이터 구현 / descriptor 매핑 / 왜 OOD 인가 / 예상 정답 팔)** 로 적는다.
`kinds` 는 `action_registry.json` 기준: 0=NOOP, 1=Replace, 2=Deprioritize, 4=ReformTeam, 8=SwapBattery.

---

### 축 A — **잔존 능력 ρ** (강도 축) · **1순위 추천**

| | |
|---|---|
| **정의** | ρ ∈ [0,1] = 고장 후 남은 **속도/출력 배율**. ρ=0 완전 정지(현행), ρ=1 무영향. |
| **문헌** | §2-a abrupt vs incipient / §2-e "부분 고장이 집단 성능을 저하". fail-stutter(§2-b). |
| **구현** | **`BATTERY_DERATE` 기계를 그대로 재사용.** `soc_speed_factor` 가 이미 팀 구성원의 최소 배율을 계산한다. fault 용으로 `FAULT_DERATE`(로봇별 배율 override)를 붙이면 `fault_robot!(env; residual=ρ)` 한 줄. ρ=0 이면 현행과 **바이트 동일**. |
| **descriptor** | `harm = 1 − ρ`, `resource_loss = 1 − ρ`. **지금 하드코딩된 1.0 자리를 그대로 채운다** — 그리고 이 값은 배포에서도 관측 가능(P3 충족). battery 의 `harm = 1 − soc` 와 **같은 부호·같은 의미**. |
| **왜 OOD** | **현재 배포 surrogate 는 fault 를 ρ=0 한 점에서만 학습했다.** 따라서 ρ>0 인 모든 부분 고장은 **정의상 100% OOD** 다. 반대로 학습을 ρ∈{0.3,0.6} 로 하고 ρ=0 을 held-out 하면 battery 의 `soc=0.02` 와 **정확히 동형**인 강도 외삽 실험이 된다. |
| **정답 팔** | ρ=0 → Replace(1) / ρ 중간 → Deprioritize(2) 또는 NOOP / ρ→1 → NOOP(0). **P2 충족**: feasibility → 시간 → 무영향의 3계층이 그대로 재현될 것으로 기대. |
| **리스크** | P1 준수 여부를 **먼저 측정**해야 한다. `soc_speed_factor` 의 derate 구간은 `min_f=0.35 ~ 1.0` 이라, ρ 를 그 안에서만 흔들면 battery 중간 칸이 그랬듯 **얇을** 수 있다(6칸 중 1칸만 섭동 바닥 초과). ρ 를 0 근처까지 내리는 칸이 반드시 필요. |

**제안 사다리(초안):** `ρ = 0.0 / 0.15 / 0.4 / 0.8`
— 0.0 = 정지(현행, feasibility 로 갈림) · 0.15 = 거의 못 움직임(시간으로 갈림, 두꺼움) ·
0.4 = 절뚝(시간, 얇음) · 0.8 = 사실상 무영향(**경험적 귀무 칸** — battery 의 0.50 과 같은 역할).

---

### 축 B — **고장난 하위시스템 (양식 축)**

이 시뮬레이터의 로봇은 기능적으로 세 부분이다: **① 이동(RVO/TangentBug) · ② 운반 결합
(`FormTransportUnit` capture) · ③ 기하 정합(`feeder_at_goal` / `in_capture`)**. 실제 로봇도
그렇다 — 문헌이 "가장 신뢰성 낮은 부품"으로 꼽는 것이 본체가 아니라 **그리퍼·툴·센서·배선**이다.

| 모드 | 물리적 의미 | 시뮬레이터 구현 | 예상 정답 |
|---|---|---|---|
| **B1 이동 상실** | 구동계 고장. 못 가지만 잡고는 있음 | 현행 `fault_robot!`(속도 0) | Replace(1) |
| **B2 결합 상실** | 그리퍼/엔드이펙터 고장. **돌아다니지만 못 든다** | 그 로봇의 capture 판정을 영구 false | ReformTeam(4) 또는 Deprioritize(2) — 함대에 남되 운반에서 빼야 함 |
| **B3 기하 오차** | 로컬라이제이션 드리프트. **"도착했다"고 하는데 실제로 팀이 안 모임** | `in_capture=true` 인데 `feeder_at_goal=false` 상태를 강제 | 관측 자체가 어려움 → 오라클 fallback |

> **B3 는 이 레포가 이미 실제로 겪은 버그와 동형이다.** 2026-06-27 §(k) 의 transform-binding 버그가
> 정확히 "`in_capture=true` / `feeder_at_goal=false` 인 수학적 모순" 이었고, 그게 빌드를 무한 stall
> 시켰다. **버그였던 상태를 고장 모드로 승격**시키면 아주 현실적인 Byzantine 고장 주입기가 된다
> (§2-b: 정상인 척 보고하는 고장).

| | |
|---|---|
| **왜 OOD** | 팔(macro)은 이미 어휘 안에 있지만(2, 4) **상태 분포 밖**이다. B2/B3 는 `harm` 이 1.0 인데 `Replace` 가 정답이 아닌 첫 사례가 된다 → 지금 학습된 "harm 높으면 Replace" 지름길을 정면으로 깬다. |
| **리스크** | descriptor 6개가 B1/B2/B3 를 **구분할 수 없다**(전부 harm=1, resource_loss=1). 즉 이 축을 쓰려면 **descriptor 추가가 필요**하다. 후보: `capability_kind` 또는 `coupling`(축 E 참조). descriptor 추가는 novelty calibration 재수출·Julia 대조(`tools/test_novelty.jl` 1e-9)까지 딸려온다. |

---

### 축 C — **다중성·상관 (CCF 축)** · **2순위 추천**

| | |
|---|---|
| **정의** | 시간창 Δt 안에 동시 고장난 로봇 수 k (또는 k / 함대크기). 현행은 **항상 k=1**. |
| **문헌** | §2-c CCF/CAF. 특히 *"여분을 둔 시스템에서 위험 — 예비들이 독립 고장한다는 가정이 깨진다"*. AMR 현장의 실제 공통원인 = **네트워크/Wi-Fi**, 안전 인터록. |
| **구현** | `schedule_random_ood!` 에 `n_simultaneous=k` 추가, 같은 step 에 `fault_action` 을 k 번. **가장 구현이 싼 축**(엔진 변경 0). 상관 구조를 넣고 싶으면 "같은 사분면 로봇 k대"(= 지역 Wi-Fi AP 장애) 처럼 공간 상관을 준다. |
| **descriptor** | 이미 실린다 — `work_at_risk` ↑(pending 합), `recovery_capacity` ↓(spare 소모). **새 열 불필요.** |
| **왜 OOD** | **spare pool 의 여분 가정을 정면으로 깬다.** k > 남은 spare 수가 되는 순간 `verify_replace` 게이트가 `:no_spare` 로 떨어지고, **Replace 가 물리적으로 불가능해진다**. 즉 이 축은 `recovery_capacity` 를 **임계 너머로** 밀어내는 유일한 축이다 — battery 의 `soc=0.02` 가 feasibility 를 뒤집었던 것과 같은 종류의 질적 전환. |
| **정답 팔** | k 작음 → Replace / k 가 spare 를 초과 → **어느 몇 대를 살릴지 선택**해야 함. 여기서 NOOP·Deprioritize·ReformTeam 의 조합이 처음으로 의미를 갖는다. |
| **리스크** | 정답 계산 비용이 k 에 따라 폭발한다(팔 조합). MVP 는 "k대 고장 → 팔은 여전히 단일 매크로"로 좁힐 것. 그리고 **다로봇 팀 deadlock**(§(i)(j)(l) 미해결 연구 잔여)에 부딪힐 확률이 k 와 함께 올라간다. |

---

### 축 D — **지속시간 / 회복 가능성 (transient 축)** · **3순위 추천**

| | |
|---|---|
| **정의** | 고장 지속시간 T ∈ [0, ∞). T=∞ 가 현행(영구). T 유한 = **일시 정지 후 자동 복귀**. |
| **문헌** | §2-a intermittent(간헐 고장) · §2-d 안전 인터록/E-stop 발화 · §2-e "일시적 교란 vs 영구 고장". 현장에서 "멈춤"의 다수는 영구 고장이 아니다. |
| **구현** | `faulted_robots()` 에서 T 스텝 뒤 제거 + 속도 복원. `schedule_ood!` 재사용으로 "복구 이벤트"를 예약하면 끝. 엔진 변경 최소. |
| **descriptor** | **현재 담을 자리가 없다.** T 는 새 열이 필요하거나, `harm` 을 "지속시간으로 할인한 피해"로 재정의해야 한다(= `harm = (1−ρ)·min(1, T/T_ref)`). 후자가 열 추가 없이 되는 방법. |
| **왜 OOD** | **NOOP 이 정답인 구간을 처음으로 물리적으로 만든다.** 지금 fault 사건에서 NOOP 이 정답인 경우는 `faultidle`(노는 로봇을 때린 경우)뿐이고, 그건 표적 선정 아티팩트다. T 가 작으면 "개입하면 자원 낭비, 안 하면 스스로 돌아온다"가 **진짜로** 성립한다. battery 의 `0.50` 무영향 칸에 대응. |
| **정답 팔** | T 작음 → NOOP(0) / T 중간 → Deprioritize(2) / T=∞ → Replace(1). **깨끗한 3계층.** |
| **리스크** | NL 관찰이 T 를 알려주면 안 된다(그건 §4-d 가 지적한 "처방절"과 같은 종류의 누설). 관찰은 "R7 이 멈췄다"까지고, **얼마나 오래 멈출지는 정책이 추정해야** 한다 → 이 축은 자연스럽게 **불확실성 하 결정** 문제가 된다. 이건 리스크이자 이 축의 가장 큰 가치다. |

---

### 축 E — **구조적 임계도 (structural criticality)**

| | |
|---|---|
| **정의** | 고장난 로봇이 **협동 구조에서 차지한 위치**. 단독 운반체 / 2-로봇 팀 멤버 / 이미 형성된 팀의 멤버 / 임계경로 상 여부. |
| **근거** | **이 레포의 자체 실측이 최강 근거다.** `simulator_ood_1-1_..._2026-06-26.md` §(i)~(l): 고장 로봇이 **2-로봇 운반팀의 멤버**였을 때 단일 spare 인계로는 타이밍을 못 맞춰 **함대 전체가 gridlock** 됐고(healthy 9대 동반 정체), 이것이 다섯 블로커 중 **유일하게 "연구성"으로 남은** 문제다. 문헌 쪽 대응은 §2-c CAF(연쇄). |
| **구현** | `pick_solo_fault_target` vs `pick_hotswap_fault_target`(안 닫힌 FTU 멤버) — **두 피커가 이미 존재한다.** severity = 그 로봇이 속한 미형성 팀 수, 또는 팀 크기. |
| **descriptor** | **없다 → 새 축 `coupling` 제안.** 정의: `(그 로봇이 멤버인 안 닫힌 FormTransportUnit 의 팀 크기 합) / (그 로봇의 pending 작업 수)`. 0 = 완전 단독, 큼 = 다른 로봇들이 이 로봇을 기다림. |
| **왜 OOD** | battery severity 가 **물리적 심각도**라면 이건 **구조적 심각도**다. 같은 "완전 고장"(ρ=0)이라도 solo 냐 팀 멤버냐에 따라 결과가 질적으로 다르다는 것이 **이 레포에서 이미 측정됐다**. 그리고 `work_at_risk` 는 그 차이를 못 담는다(작업 수는 같을 수 있으므로). |
| **정답 팔** | solo → Replace(1) / 팀 멤버 → **ReformTeam(4)** — `action_registry.json` 에서 macro 4 의 `kinds` 에 `fault` 가 이미 들어 있는데, **fault 학습 데이터에서 4가 정답인 사례가 사실상 없다.** 이 축이 그 팔에 학습 근거를 준다. |
| **리스크** | **미해결 deadlock 위에 직접 올라탄다.** 라벨링이 stall 로 끝날 확률이 높다(= 라벨 없음). 축 A/C/D 를 먼저 세운 뒤에 손대는 게 맞다. |

---

### 축 F — **공간적 부수효과 (collateral footprint)** · 개방세계(open-world) 전용

| | |
|---|---|
| **정의** | 고장 로봇 본체가 **통로를 얼마나 막았나**. 병목(좁은 통로/게이트)에서 죽었나. |
| **근거** | §2-d "이동형 로봇 23건" 및 AMR 현장의 국소 차단. 그리고 `fault_robot!(obstacle=true)` 가 **이미 정적 장애물을 등록하고 있다** — 다만 측정을 안 할 뿐. |
| **구현** | `zone_overlap_frac` 를 고장 장애물에도 계산해 fault row 의 `zone_overlap` 을 채운다. severity = 그 값. 그리고 고장 지점을 **병목 근처로 유도**하는 표적 피커. |
| **descriptor** | **여기가 진짜 핵심.** `descriptors_from_row` 는 `has_soc → elif is_spatial → elif is_agent` 로 **배타 분기**한다. 고장+장애물 혼합 사건은 `agent_pending` 과 `zone_overlap` 이 **둘 다 유한**해서 현재 코드로는 `harm=zov` 로 읽히고 `is_agent` 분기를 **영영 안 탄다**. |
| **왜 OOD** | **표현이 구조적으로 담을 수 없는 사건** = 강도 외삽이 아니라 **양식 신규**의 가장 순수한 형태. novelty 라우터가 이걸 잡아내는지가 그 라우터의 진짜 시험이다. `openworld_experiments.py` 의 LOKO 실험과 직결. |
| **리스크** | descriptor 분기 수정은 기존 모든 교정치(novelty calibration)를 무효화한다. **별도 트랙**으로 다뤄야 한다. |

---

## 5. 권고 — 무엇을 어떤 순서로

### 5-a. OOD 를 **2계층**으로 정의하자 (이게 이 문서의 핵심 제안)

battery 의 "severity 로 OOD 정의"를 fault 에 **한 축으로** 옮기려는 시도는 실패한다 — 로봇 고장은
본질적으로 다차원이기 때문이다(§2). 대신:

| 계층 | 정의 | battery | fault |
|---|---|---|---|
| **Type-1 · 강도 외삽** | 학습 범위 **밖의 값**, 축은 동일 | `soc` 사다리에서 held-out 칸 | **축 A(ρ)** 사다리에서 held-out 칸 |
| **Type-2 · 양식 신규** | 학습에 **축 자체가 없음** | (해당 없음) | **축 C(다중), D(일시), F(혼합)** |

이러면 두 kind 를 **같은 자로** 잴 수 있고("held-out severity 칸에서 regret"), 동시에 fault 에만
있는 Type-2 가 **novelty 라우터의 시험대**가 된다. 그리고 논문 서사가 깔끔해진다:
*"강도 외삽은 surrogate 가 외삽으로 처리하고, 양식 신규는 라우터가 잡아 오라클로 넘긴다."*

### 5-b. 구현 순서 (비용 오름차순 × 가치 내림차순)

| 순위 | 축 | 엔진 변경 | descriptor 변경 | 얻는 것 |
|---|---|---|---|---|
| **1** | **A (ρ)** | 작음 (derate 재사용) | **없음** (하드코딩 1.0 → 1−ρ) | battery 와 동형인 Type-1 축. **오늘 없는 것이 생긴다** |
| **2** | **C (다중 k)** | **없음** (스케줄러만) | **없음** | spare 고갈 = feasibility 전환. 가장 싼 Type-2 |
| **3** | **D (지속 T)** | 작음 | harm 재정의 1줄 | **NOOP 이 정답인 물리적 구간**. 불확실성 하 결정 |
| 4 | E (coupling) | 없음(피커 존재) | **새 열 1개** | ReformTeam(4) 에 학습 근거. 단 deadlock 위험 |
| 5 | B (하위시스템) | 중간 | 새 열 필요 | "harm 높음 → Replace" 지름길 파괴 |
| 6 | F (혼합) | 작음 | **분기 구조 수정** | 순수 양식 신규. 별도 트랙 |

### 5-c. 축 A 를 세울 때 반드시 지켜야 할 검증 게이트 (P1/P2 위반 조기 발견)

battery 재설계가 `tools/checks.jl stall_gate [5]` 로 한 것과 같은 것을 fault 에도 만든다.

1. **거동 분리 검사(P1):** 사다리 4칸이 **서로 다른** `(complete, closed, makespan)` 을 내는가.
   같으면 그 칸은 존재하지 않는 것 — 값을 바꾸지 말고 **엔진 구간을 고칠 것**.
2. **단조성:** ρ 에 대해 closed/makespan 이 단조인가.
3. **섭동 바닥 대비(P2):** ρ=0.8 칸(귀무)의 makespan 편차가 battery 에서 측정된 **0.775 s** 급인가.
   그 안이면 "무영향 칸"으로 정당하고, 넘으면 사다리가 아니라 잡음이다.
4. **하위호환:** ρ=0 이 현행 `fault_robot!` 과 **바이트 동일**인가(기존 덤프 재현성).
5. **NL 중립성:** 새 severity 가 관찰 문장에 **처방절로 새지 않는가**. battery 에서 이미 한 번
   고친 실수(§4-d) — fault 템플릿은 **아직 `"dispatch the nearest backup robot"` 이 남아 있다.**
   축 A 를 넣는 김에 같이 중립화해야, ρ 별로 다른 정답을 재는 실험이 성립한다.

### 5-d. 학습/평가 분할 (배터리와 같은 형식)

- **학습:** ρ ∈ {0.15, 0.4, 0.8} (부분 고장만)
- **held-out OOD:** ρ = 0.0 (완전 정지) ← **강도 외삽**
- 대칭 실험으로 **반대 방향**도: 학습 ρ=0 만 / held-out ρ>0 ← **현재 배포 모델이 처한 상황**
- `openworld_experiments.py` 에 **LOSO(leave-one-severity-out)** 를 LOKO 옆에 추가.
  LOKO 가 "종류 하나 빼기"라면 LOSO 는 "칸 하나 빼기"다.

---

## 6. 열린 질문 (사용자 결정 필요)

1. **ρ 의 물리적 의미를 속도 배율로 볼 것인가, 적재 능력으로 볼 것인가.** 속도 배율은
   derate 기계 재사용으로 거의 공짜지만 battery 와 **같은 경로를 공유**해서 두 kind 가
   구분 안 될 위험이 있다(둘 다 `harm` 을 통해 속도로 나타남). 적재 능력(운반 가능 무게/팀 참여
   가능 여부)은 fault 고유지만 구현이 비싸다.
2. **Type-2 를 몇 개까지 열 것인가.** C·D 두 개면 "양식 신규"라는 범주가 성립하고, 여섯 개를
   다 열면 각각의 라벨 수가 얇아진다. 라벨링 비용(battery 18 instance = 0.49 h)을 기준으로 예산을 정할 것.
3. **§5-c-5 의 NL 중립화를 이번에 같이 할 것인가.** 안 하면 축 A 실험의 LLM 대조군이 무효다
   (관찰이 정답을 알려주므로). 하면 기존 LLM 측정치와의 비교 가능성이 끊긴다.

---

## 참고 문헌 (조사 근거)

- Fault Detection and Diagnosis in Multi-Robot Systems: A Survey — https://doi.org/10.3390/s19184019
- Failure-Aware Multi-Robot Coordination for Resilient and Adaptive Target Tracking — https://arxiv.org/pdf/2508.02529
- Robot-related injuries in the workplace: An analysis of OSHA Severe Injury Reports — https://pubmed.ncbi.nlm.nih.gov/39018706/
- The Review of Reliability Factors Related to Industrial Robots — https://juniperpublishers.com/raej/pdf/RAEJ.MS.ID.555624.pdf
- Harmonic Drive Gear Failures in Industrial Robots (PHM Society) — https://papers.phmsociety.org/index.php/phme/article/download/2849/1801
- Incipient fault diagnosis for robot manipulators (Robotica) — https://www.cambridge.org/core/journals/robotica/article/abs/incipient-fault-diagnosis-for-robot-manipulators-based-on-evolution-of-friction-characteristics-in-transmission-components/CD4267721DA981C622AFF64667A352A1
- Common cause failures and cascading failures in technical systems — https://www.researchgate.net/publication/329689686
- Minimizing correlated failures in distributed systems (AWS Builders' Library) — https://aws.amazon.com/builders-library/minimizing-correlated-failures-in-distributed-systems/
- Why Warehouse Networks Fail Robots (AMR 현장 고장 양식) — https://www.performancenetworks.co.uk/blog/amr-robot-wifi/
- AMR troubleshooting 2025: controls and safety problems — https://www.smartloadinghub.com/insights/agv-amr/amr-troubleshooting-2025-practical-controls-safety/
- A System-Level View on Out-of-Distribution Data in Robotics — https://stanfordasl.github.io/wp-content/papercite-data/pdf/Sinha.Sharma.ea.ISRR22.pdf
- Characterizing Generalization under Out-Of-Distribution Shifts (ooDML) — https://arxiv.org/abs/2107.09562
- Robot Accident Investigation: a case study in Responsible Robotics — https://arxiv.org/pdf/2005.07474
