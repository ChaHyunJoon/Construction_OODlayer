# 배터리 사건 재설계 + 두 가지 결정 (λ, Replace vs SwapBattery) — 2026-08-05

> ## 🔴 세대 표시 — 이 문서의 수치는 **매크로 7·8 이전**이다 (2026-08-09 부착)
>
> 여기 실린 측정치는 `action_registry.json` 이 **7(RelocateBuild)·8(SwapBattery)** 를 갖기 전
> (2026-08-06) 에 나온 것이다. 그 시절 zone 사건의 메뉴는 `[NOOP, RelocateBuild]` 인데 배포
> surrogate 가 지원하는 팔은 `{NOOP}` 뿐이어서 **언제나 NOOP** 이 나왔고, battery 는
> `SwapBattery` 를 한 줄도 못 봐서 적중 0/6 이었다(`wm_datasets.py` 의 N44_PLUS8/78 주석).
> 즉 **행동집합이 잘린 상태에서 잰 숫자**다. 현재 배포 성능으로 인용하면 안 된다.
>
> - **현행 측정** = `RESULTS_LLM7H.md` (학습셋 `oracle/out/n44_plus78.jsonl`, 2026-08-07 재적합)
> - 이 문서가 근거로 삼은 덤프는 **2026-08-09 정리에서 삭제**됐다. 재현하려면 복원하지 말고
>   `gen_oracle_dataset.jl` 로 **현재 어휘에서** 새로 생성할 것.


> 이 문서는 **한글 전문**과 **English full mirror** 두 벌로 되어 있다. 같은 내용이며 번역본이 아니라
> 각각 독립적으로 읽히도록 썼다. 숫자·파일명·명령은 양쪽이 동일하다.
> English version starts at **[PART II](#part-ii--english)**.
>
> 근거 데이터: `oracle/out/battgrid_0805_s1.jsonl` (18 instance / 54 row, seed 1, 라벨링 0.49 h),
> `oracle/out/fire_probe_batt.csv`, `oracle/out/firegrid_merged.jsonl`(기존).

---

# PART I — 한글

## 0. 결정 요약

| # | 항목 | 결정 | 근거 한 줄 |
|---|---|---|---|
| (1) | 배터리 표적 선정 | **고침.** 표적 = "아직 안 닫힌 운반팀(`FormTransportUnit`)의 멤버" | 옛 피커는 진행도 **0.51 이상에서 100% 주차된 예비**를 골랐다(측정). 그 탓에 기존 후반 deep-battery 라벨 7건이 전부 무의미했다 |
| (2) | 심각도 구간 | **재설계.** `0.02 / 0.3 / 0.5` + 엔진에 **감속(derate) 구간** 신설 + 심각도를 **결과 SoC 절대값**으로 정의 | 옛 `0.05 / 0.12` 는 둘 다 정지 임계(0.15) 아래 = **거동이 동일**. 감속 구간이 없으면 `0.3`·`0.5` 도 반대쪽에서 겹친다 |
| (3-a) | λ (개입비용) | **비용 항은 유지. 단 (i) λ 를 학습 목표에서 빼 결정 규칙으로 옮기고, (ii) λ-키를 시간가격 μ-키로 교체.** "튜닝된 λ=15" 주장은 철회 | λ 는 데이터로 **식별 불가**(0.5→30 에서 답 2.4~3.2%만 변화)이면서, λ≥13 은 측정된 12노드 이득을 지우고, **λ>0 은 makespan 계층을 원천 무효화**해 새 사다리의 중간 칸을 통째로 못 읽는다 |
| (3-b) | battery 사건의 행동 | **`SwapBattery`(8) 기본**, `Replace`(1)는 본체 자체가 못 쓰게 됐을 때만 | 두 팔의 완주·closed 가 **동일(291)** 한데 SwapBattery 는 창고 본체를 안 먹고, **후반일수록 더 빠르다**(f222 에서 24.88 → 19.62 s). 덤으로 사건 문장의 **처방절** 제거 |

(1)(2)는 구현·검증 완료. (3)은 결정 + 근거 + **비파괴 opt-in 구현**까지. 배포 산출물
(`surrogate_hotswap.json`, CANONICAL 데이터셋, 녹화 영상)은 **건드리지 않았다**.

---

## 1. 수정 (1) — "후반에 놀고 있는 로봇"을 표적으로 삼던 문제

### 1-a. 진단

`_pick_battery_target`(`src/navigator/battery.jl`)의 옛 우선순위:

```
(1) pick_solo_fault_target        ─┐
(2) pick_solo_frontier_target      ├─ 셋 다 `_first_pending_assignment` 를 통과해야 한다
(3) `_first_pending_assignment` 통과하는 비-예비 중 SoC 최고 ─┘
(4) _pick_low_margin_robot = "SoC 가 가장 높은 로봇"          ← 폴백
```

`_first_pending_assignment` 는 **"남은 일이 있는가"를 묻는 함수가 아니다.** "지금 **깨끗한 작업
경계**(선행 노드가 `RobotStart` 이거나 이미 closed)에 서 있는가"를 묻는다. 이 저장소는 같은 함정을
이미 두 번 밟았다(`md/FIRE_TIME_RELABEL_2026-08-05.md` §1 = fault 피커, §4 = `_pick_idle_victim`).
빌드가 굴러가면 로봇은 운반 사슬 안에 있으므로 (1)~(3)이 **전부 실패**하고 (4)로 떨어진다.

(4)는 **주차된 예비**를 고른다. 예비는 창고에서 전원이 꺼져 있어 SoC 가 안 닳으므로 "SoC 최고"는
언제나 예비다. 예비는 남은 일이 없으니 **NOOP / Replace / SwapBattery 결과가 전부 같아지고**, 그
instance 는 라벨로서 정보가 0 이다.

> 이 위험은 `FIRE_TIME_RELABEL_2026-08-05.md` §7 에 권고로 적혀 있었지만 **"관측된 피해는 없다"**
> 고 되어 있었다. §1-c 가 그 판단을 뒤집는다 — 피해는 이미 데이터 안에 있었다.

### 1-b. 측정 — 옛 피커 vs 새 피커 (같은 판, 같은 순간)

`oracle/probe_fire_points.jl` 이 이제 두 피커를 **나란히 호출**한다(`batt_old` / `batt_new`, 각각
"예비인가 / 남은 일이 있는가"). 물리 상태는 안 건드리고 관찰만 한다.

```bash
PF_EVERY=20 PF_FROM=40 PF_TO=280 PF_SEED=1 \
  PF_OUT=wm4spacecraft_manufacturing/oracle/out/fire_probe_batt.csv \
  julia --project=. wm4spacecraft_manufacturing/oracle/probe_fire_points.jl
```

tractor · 로봇 10대 · spare 3 · seed 1 (원자료 `oracle/out/fire_probe_batt.csv`)

| closed | 58 | 60 | 80 | 100 | 120 | 142 | **160** | 180 | 200 | 222 | 240 | 260 | 280 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| progress | .19 | .19 | .26 | .32 | .38 | .45 | **.51** | .58 | .64 | .71 | .77 | .83 | .90 |
| **OLD 표적** | R1 | R1 | R10 | R7 | R7 | R7 | **R14** | R14 | R14 | R14 | R14 | R14 | R14 |
| OLD = 예비? | – | – | – | – | – | – | **Y** | Y | Y | Y | Y | Y | Y |
| OLD 남은일? | Y | Y | Y | Y | Y | Y | **–** | – | – | – | – | – | – |
| **NEW 표적** | R1 | R1 | R4 | R1 | R1 | R1 | **R4** | R1 | R1 | R1 | R1 | R4 | R5 |
| NEW = 예비? | – | – | – | – | – | – | – | – | – | – | – | – | – |
| NEW 남은일? | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | –¹ |

¹ closed=280 의 "–" 는 술어 실패가 아니라 사실이다 — 그 시점엔 **남은 운반 일이 아예 없다**
(`n_hotswap = 0`). 그래서 라벨 그리드는 260 에서 끝낸다.

**진행도 0.51 부터 옛 피커는 100% 주차된 예비를 쐈다.** 새 피커는 남은 운반 일이 있는 한 항상 일하는
로봇을 고른다.

### 1-c. 기존 라벨이 어떻게 망가져 있었나 — 그리고 철회해야 할 결론

기존 `oracle/out/firegrid_merged.jsonl` 의 **깊은 방전(soc ≤ 0.2)** battery instance 를 진행도 순으로
늘어놓으면 §1-b 와 **같은 경계**가 그대로 나온다.

| 발화점 | progress | `agent_pending` | 팔들을 가른 것 | 오라클 최선(λ=0) |
|---|---|---|---|---|
| f58 | 0.185 | 3–4 | feasibility | Replace |
| f100 | 0.319 | 3–5 | feasibility | Replace |
| f140 (seed 1) | 0.447 | 3 | feasibility | Replace |
| **f140 (seed 2)** | 0.450 | **0** | **전부 정확히 동점** | (동점) |
| **f180** | 0.575 / 0.578 | **0** | **전부 정확히 동점** | (동점) |
| **f220** | 0.703 / 0.709 | **0** | **전부 정확히 동점** | (동점) |
| **f260** | 0.831 | **0** | **전부 정확히 동점** | (동점) |

`agent_pending = 0` = "희생자에게 남은 일이 없다" = **예비를 쐈다는 증거**다.

**따라서 다음 결론을 철회한다.**

> `FIRE_TIME_RELABEL_2026-08-05.md` §3-a: *"깊은 방전이라도 빌드 후반(≥0.58)에는 개입이 필요 없다 —
> 그 로봇에게 남은 일이 적어 함대가 흡수한다 … 이건 모델이 배워야 할 새 구조다."* (당시 "이번 작업의
> 가장 큰 발견"으로 기록됨)

그것은 "함대가 흡수한다"가 아니라 **"애초에 일이 없던 로봇을 때렸다"** 였다. 진행도가 정답을 뒤집은
게 아니라, 진행도가 올라가면 **표적 선정이 고장 나 있었다.**

### 1-d. 재라벨링 결과 — 뒤집힘은 일어나지 않는다

```bash
DS_KINDS=battery DS_SEEDS=1 DS_BSOC=0.02,0.3,0.5 DS_FIRE_GRID=58,100,140,180,220,260 \
  DS_HOTSWAP=1 DS_VALID_ONLY=1 DS_REFORM=120 DS_RESUME=1 \
  DS_OUT=wm4spacecraft_manufacturing/oracle/out/battgrid_0805_s1.jsonl \
  julia --project=. wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl
```

18 instance / 54 row / 라벨링 총 0.49 h. **대조군(control): 완주, closed 291, makespan 19.625 s.**

**깊은 방전 (severity = 0.02, 정지):**

| 발화점 | progress | `agent_pending` | NOOP | Replace | SwapBattery |
|---|---|---|---|---|---|
| f58 | 0.19 | 4 | **미완주 151** | 완주 291 / 19.28 s | 완주 291 / 19.62 s |
| f100 | 0.32 | 3 | **미완주 213** | 완주 291 / 19.25 s | 완주 291 / 19.62 s |
| f142 | 0.45 | 2 | **미완주 213** | 완주 291 / 19.62 s | 완주 291 / 19.62 s |
| f180 | 0.58 | 2 | **미완주 246** | 완주 291 / 20.33 s | 완주 291 / 19.62 s |
| f222 | 0.71 | 2 | **미완주 246** | 완주 291 / 24.88 s | 완주 291 / 19.62 s |
| f260 | 0.83 | 1 | **미완주 274** | 완주 291 / 22.85 s | 완주 291 / 19.62 s |

**NOOP 은 6개 발화점 전부에서 완주하지 못한다.** 진행도 0.58·0.71·0.83 — 옛 데이터가 "전부 동점"
이라고 말하던 바로 그 지점들 — 에서도 그렇다. §1-c 의 철회가 데이터로 확인된다.

### 1-e. 코드 변경

| 파일 | 무엇 |
|---|---|
| `src/navigator/battery.jl` | `_pick_battery_target` 2순위를 `pick_hotswap_fault_target`(안 닫힌 FTU 멤버십)으로 교체, 최종 폴백에서 **예비/복구예비 제외** |
| `wm4.../oracle/probe_fire_points.jl` | 옛 피커 사본(`pick_battery_target_OLD`) + `owns_carry_work` + CSV 6열 → §1-b 표의 근거 |

앞 두 순위(`pick_solo_*`)는 손대지 않았다. 초반 발화는 예전과 **바이트 동일**하고, 예전에 폴백으로
새던 순간만 채운다.

---

## 2. 수정 (2) — 심각도 구간을 정지 경계에 걸치게

### 2-a. 진단: 옛 사다리는 같은 사건을 두 번 잰 것

- 라벨러 정지 임계 `DS_STALL = 0.15`.
- 옛 기본 사다리 `0.05, 0.12, 0.2, 0.3, 0.45, 0.6` 중 배포/덱에서 실제로 쓴 두 칸은 **0.05 와 0.12**.
- 둘 다 0.15 **아래** → 둘 다 즉시 정지. `soc_speed_factor` 가 계단 함수(≤thr → 0.0, 아니면 1.0)라
  **거동이 완전히 같다.**

값만 올려서는 안 고쳐진다: 계단 함수 아래에서 `0.3` 과 `0.5` 는 **둘 다 배율 1.0** 이라 반대쪽에서
겹친다. 엔진에 중간 구간이 필요하다.

### 2-b. 엔진 고침 — 감속(derate) 구간

`BATTERY_DERATE` / `set_battery_derate!` 신설. `soc_speed_factor` 는 이제 팀 구성원의 **최소 배율**:

```
SoC ≤ thr(0.15)       -> 0.0                 죽음: 그 자리에 멈춤
thr < SoC < hi(0.5)   -> min_f(0.35) ~ 1.0   성능 저하: 느리지만 계속 일함(선형)
SoC ≥ hi(0.5)         -> 1.0                 사실상 무영향
```

물리적 근거: 저 SoC 에서 셀 전압이 떨어져 최대 출력이 제한되는 **power derating** 은 실제 배터리
시스템의 표준 거동이다. 중간 칸은 인위적 손잡이가 아니라 자연스러운 상태다.

기본은 **꺼짐** → 켜기 전에는 예전 계단 함수와 바이트 동일(기존 덤프 재현성 보존). 라벨러가
`DS_DERATE=1`(기본 ON)로 켠다. `DS_DERATE=0` 이면 옛 거동.

측정된 배율(`tools/checks.jl stall_gate` 가 표를 직접 찍는다):

| 목표 SoC | 0.02 | 0.16 | 0.20 | **0.30** | 0.40 | **0.50** |
|---|---|---|---|---|---|---|
| 속도 배율 | **0.0000** | 0.3686 | 0.4429 | **0.6286** | 0.8143 | **1.0000** |
| 거동 | 즉시 정지 | | | 약 63% 속도로 계속 일함 | | 무영향 |

### 2-c. 정의 고침 — 심각도는 "떨어뜨릴 양"이 아니라 "떨어진 뒤의 잔량"

옛 주입은 뺄셈(`soc_drop`)이라 사건 시점까지의 소모분만큼 칸이 아래로 밀린다. **실측**: 목표 0.02 인데
기록된 `soc` 가 `0.0`(바닥에 눌림). 감속/정지 경계가 **결과 SoC** 로 정의되므로 그냥 설계 이탈이다.

`inject_battery_fault!` / `battery_action` 에 `soc_target`(절대값) 추가, 라벨러 기본
`DS_BSOC_MODE=abs`. 검증: 새 덤프의 `soc` 가 정확히 `0.020` / `0.300` / `0.500`. 옛 뺄셈은
`DS_BSOC_MODE=drop`.

### 2-d. 새 사다리가 실제로 만들어낸 거동 (측정)

**중간 칸 (severity 0.30, 감속 0.629)** — 모든 팔이 완주하므로 차이는 **오직 시간**이다:

| 발화점 | progress | NOOP | Deprioritize | SwapBattery | NOOP 의 시간 손해(대조군 19.625 대비) |
|---|---|---|---|---|---|
| f58 | 0.19 | 21.73 s | 21.73 s | 19.62 s | **+2.100 s (+10.7%)** |
| f100 | 0.32 | 19.98 s | 19.98 s | 19.62 s | +0.350 s |
| f142 | 0.45 | 19.75 s | 19.75 s | 19.62 s | +0.125 s |
| f180 | 0.58 | 19.83 s | 19.83 s | 19.62 s | +0.200 s |
| f222 | 0.71 | 19.43 s | 19.43 s | 19.62 s | −0.200 s |
| f260 | 0.83 | 20.10 s | 20.10 s | 19.62 s | +0.475 s |

**윗 칸 (severity 0.50)** 은 감속 배율이 **정확히 1.0** 이므로 물리적 효과가 없어야 한다. 그래서 이
칸이 **경험적 귀무(null)** 역할을 한다 — 사건을 꽂았을 뿐인데 makespan 이 얼마나 흔들리는가:

| 발화점 | f58 | f100 | f142 | f180 | f222 | f260 |
|---|---|---|---|---|---|---|
| NOOP − 대조군 | −0.775 | −0.125 | +0.375 | −0.275 | +0.275 | +0.025 |

→ **사건 섭동 바닥(perturbation floor) = 최대 0.775 s (빌드의 3.9%), 평균 0.308 s.**

이 두 표를 합치면 새 사다리가 실제로 만든 구조가 보인다:

- **0.02** : 개입 없으면 **완주 불가** (feasibility 로 갈림)
- **0.30** : 완주는 하되 **시간 손해**. 그 손해가 섭동 바닥을 넘는 것은 **f58 한 곳(+2.10 s)** 뿐
- **0.50** : 손해가 전부 섭동 바닥 안 = **사실상 무영향**

즉 세 칸이 각각 *다른 판정 기준*(feasibility / 시간 / 무영향)으로 갈린다. 옛 사다리(0.05·0.12)는
세 칸 모두 첫 번째 기준 하나로만 갈렸다.

> **정직하게**: 중간 칸에서 섭동 바닥을 확실히 넘는 것은 6개 중 1개뿐이다. "감속 칸이 시간으로
> 갈린다"는 것은 **참이지만 얇다**. 더 두껍게 하려면 `DS_DERATE_MIN` 을 낮추거나(더 강한 감속)
> 남은 일이 많은 초반 발화점을 더 촘촘히 잡아야 한다.

### 2-e. 검증

`julia --project=. tools/checks.jl stall_gate` → **23 PASS / 0 FAIL**
(신규 [5] 블록: 세 칸이 서로 다른가 / SoC 에 대해 단조인가 / 임계 바로 위가 `min_factor` 인가 /
`hi ≤ thr` 같은 잘못된 설정은 무동작인가 / 꺼 두면 옛 계단 함수 그대로인가 + 배율 표 출력)

부수적으로 `tools/checks.jl hot_swap` 의 낡은 단정문을 고쳤다("hot-swap OFF by default" → 기본값은
2026-08-04 에 의도적으로 ON 이 되었고 `LEGACY_RESTAMP=1` 로만 꺼진다). **21 PASS / 0 FAIL.**

### 2-f. 코드 변경

| 파일 | 무엇 |
|---|---|
| `src/navigator/battery.jl` | `BATTERY_DERATE` / `set_battery_derate!` / `_soc_speed_of` 신설, `soc_speed_factor` 를 최소-배율로, `inject_battery_fault!(soc_target=)` |
| `src/navigator/ood_stream.jl` | `battery_action(soc_target=)` 전달 |
| `wm4.../oracle/gen_oracle_dataset.jl` | `_arm_battery!`(회계+정지+감속 한 곳에서 무장) / 기본 `DS_BSOC=0.02,0.3,0.5` / `DS_BSOC_MODE=abs` / 판 사이 derate 초기화 |
| `tools/checks.jl` | stall_gate [5] 감속 단위검사 + 배율 표 |

### 2-g. 아직 정렬 안 한 것 (의도적)

**데모 세계 ≠ 라벨 세계.** `tools/demos.jl:2793` 은 정지 임계 `0.02`, 라벨러는 `0.15` 이고, 데모는
감속을 켜지 않는다. 이 저장소가 반복해서 배운 교훈이 "라벨은 데모가 도는 그 세계에서 재야 한다"이므로
덱 영상을 다시 렌더링할 때 맞춰야 한다. **녹화된 산출물을 밤사이 조용히 바꾸지 않으려고 일부러
손대지 않았다.**

---

## 3. 결정 (3-a) — λ 를 없앨 것인가

### 3-a-1. λ 가 지금 하는 일

```
학습 목표 : y   = closed − λ·cost(macro)                       (export_surrogate.py --cost-aware)
오라클 정렬: key = (complete,  closed − λ·cost(macro),  −makespan)
cost = {NOOP 0, SwapBattery 0.2, Deprioritize 0.3, Replace/ForbidZone/Reform 1.0, RelocateBuild 1.5}
```

배포 모델 `surrogate_hotswap.json` 은 **"λ=15 로 튜닝됨"** 으로 기록되어 있다.

### 3-a-2. 측정 1 — λ 는 데이터로 **식별되지 않는다**

`firegrid_merged.jsonl` (126 instance) 에서 λ 만 바꿔 오라클 정답 재계산:

| λ | 0 | 0.5 | 1 | 3 | 5 | 10 | 15 | 30 |
|---|---|---|---|---|---|---|---|---|
| λ=0 대비 답이 바뀐 instance | – | 3 | 3 | 3 | 3 | 3 | 4 | 4 |
| 비율 | – | 2.4% | 2.4% | 2.4% | 2.4% | 2.4% | 3.2% | 3.2% |

**60배를 움직여도 라벨은 사실상 그대로다.** "λ=15 로 튜닝했다"는 서술은 데이터가 뒷받침하지 않는다.

### 3-a-3. 측정 2 — λ 가 실제로 하는 일은 동점 처리다 (그래서 없앨 수 없다)

| λ | feasibility | closed | makespan | **정확히 동점** | cost 가 갈랐음 |
|---|---|---|---|---|---|
| 0 | 40 | 7 | 3 | **58** | – |
| ≥0.5 | 40 | 7 | 0 | 0 | **61** |

λ=0 이면 126 중 **58건(46%)이 완전 동점**이다(완주·closed·makespan 전부 동일). 시뮬레이터는 완전히
결정론적이므로(대조군 makespan 이 seed 당 값 하나) 이건 잡음이 아니라 **진짜 구별 불가**다.

→ λ 를 완전히 없애면 그 46%(= 자제 부류)가 **임의**가 되고, 학습된 정책은 아무 대가 없이 예비를 계속
태워도 subopt_norm 0 을 받는다. **"비용 항 제거"는 기각.**

### 3-a-4. 측정 3 — 그런데 지금의 λ 는 측정된 물리를 **덮어쓴다** (두 가지 방식)

**(a) `closed` 이득을 지운다.** λ 가 `closed` 슬롯 **안에** 있기 때문이다.

```
battery_s3_sev0.2_sp3   NOOP: 미완주 248   Replace: 미완주 260   (+12 노드)
   λ=0  → Replace   (측정된 12 노드 이득)
   λ=15 → NOOP      (15 > 12 이라 이득이 지워짐)
```

이 데이터에서 손상이 시작되는 지점은 **λ ≈ 13**.

**(b) makespan 계층을 원천 무효화한다.** 두 팔이 같은 closed 로 완주하면 `closed − λ·cost` 가 이미
달라서 튜플의 3번째 성분(makespan)은 **영원히 비교되지 않는다.**

그리고 이것은 §2-d 의 새 사다리에서 치명적이다. **중간 칸(0.30)의 6개 instance 는 전부 완주하고 전부
closed = 291 이라, 차이가 makespan 에만 존재한다.** 따라서 λ-키는 λ 값과 무관하게 그 6건 전부를
`NOOP` 으로 라벨링한다 — 개입이 **빌드 시간의 10.7% 를 실제로 회복하는 f58 조차** 그렇다.

| severity 0.30 | f58 | f100 | f142 | f180 | f222 | f260 |
|---|---|---|---|---|---|---|
| SwapBattery 가 아끼는 시간 | **2.100 s** | 0.350 s | 0.125 s | 0.200 s | −0.200 s | 0.475 s |
| λ-키 라벨 (λ=1·3·15 모두) | NOOP | NOOP | NOOP | NOOP | NOOP | NOOP |

즉 **λ 형식은 재설계한 심각도 사다리가 만들어낸 구조를 원리적으로 표현할 수 없다.**

### 3-a-5. 측정 4 — λ 는 학습 목표가 아니라 **결정 규칙**에 있어야 한다

같은 오라클 채점(`score = closed − λ·cost`) 아래 두 배치를 비교
(LOO by instance, 108 instance / 396 row, 배포와 같은 RandomForest):

| 배치 | 학습 목표 | 결정 |
|---|---|---|
| **A (현행)** | `y = closed − λ·cost` | `argmax ŷ` |
| **B (제안)** | `y = closed` (물리만) | `argmax (ŷ − λ·cost)` — 비용은 **정확히 아는 상수**라 해석적으로 적용 |

| λ | A LOO subopt_norm | B LOO subopt_norm | 세부 |
|---|---|---|---|
| 1 | 0.156 | 0.166 | zoneblk: A 0.089 / **B 0.000** |
| 3 | 0.042 | 0.051 | zoneblk: A 0.033 / **B 0.000** |
| 15 | 0.011 | **0.002** | battery: A 0.025(96%) / **B 0.004(98%)** |

> **정직한 단서**: subopt_norm 은 `span = score(best) − min(score)` 로 정규화되므로 λ 가 커지면 분모가
> 커져 subopt_norm 이 작아 보인다. **λ 를 가로질러 비교하면 안 된다.** 유효한 비교는 각 행 안의 A vs B
> 뿐이고, 거기서 B 는 **한 번도 의미 있게 나쁘지 않으며** λ=15 에서 명확히 낫다.

구조적 이유는 단순하다. `cost(macro)` 는 추정할 대상이 아니라 **이미 아는 상수**다. 학습 목표에 섞으면
모델이 "물리 + 가격"을 함께 근사해야 하고, 가격을 바꾸려면 **재학습**해야 한다. 분리하면 모델은 물리만
배우고 가격은 배포 시점 정책이 된다.

### 3-a-6. 대안 키 — 비용을 **makespan 초**로 매긴다 (μ)

```
key = (complete,  closed,  −(makespan + μ·cost))
```

- 비용이 완주·진행도를 **원리적으로 못 뒤집는다** → §3-a-4(a) 손상 불가능.
- makespan 계층이 살아난다 → §3-a-4(b) 해결.
- μ 는 **해석 가능한 교환비**다: "개입 비용 1단위 = 빌드 시간 몇 초".
- λ 와 달리 **식별된다.** 새 그리드에서 정답이 바뀌는 지점(break-even)을 직접 계산할 수 있다:

| instance | 전환 | μ 임계 |
|---|---|---|
| deep f58 | Replace → SwapBattery | μ > 0.438 |
| deep f100 | Replace → SwapBattery | μ > 0.469 |
| mild f142 | SwapBattery → NOOP | μ > 0.625 |
| mild f180 | SwapBattery → NOOP | μ > 1.001 |
| mild f100 | SwapBattery → NOOP | μ > 1.75 |
| mild f58 | SwapBattery → NOOP | μ > 10.5 |

**μ 를 데이터로 고를 수 있다.** §2-d 가 사건 섭동 바닥을 **0.775 s** 로 측정했다. 그 아래 차이로는
개입을 사면 안 된다. SwapBattery 와 NOOP 의 비용 차는 0.2 이므로 `μ·0.2 ≳ 0.775` → **μ ≳ 3.9**.
그리고 deep 칸에서 Replace 대신 SwapBattery 를 고르려면 μ > 0.47. 두 조건을 모두 만족하고 가장 가까운
break-even(1.75, 10.5)에서 멀리 떨어진 값으로 **μ = 4** 를 기본값으로 제안한다.

의미: *"창고 본체(비용 1.0)는 빌드 시간을 4초 이상 아낄 때만 쓴다. 배터리 교체(비용 0.2)는 0.8초
이상 아낄 때만 쓴다."* — 0.8초는 우리가 **측정한** 섭동 바닥이다.

μ=4 와 λ=3 의 라벨 차이(18 instance):

| | deep ×6 | mild ×6 | near-nominal ×6 |
|---|---|---|---|
| λ=3 | SwapBattery ×6 | NOOP ×6 | NOOP ×6 |
| **μ=4** | SwapBattery ×6 | **SwapBattery ×1 (f58)**, NOOP ×5 | NOOP ×6 |

**차이는 18건 중 1건이다.** 작다 — 그러나 그 1건이 정확히 재설계가 만들려던 사례이고, λ 는 **어떤
값에서도** 그것을 만들 수 없다. μ 를 지지하는 근거는 "정확도가 크게 오른다"가 아니라 **표현력과
비손상성**이다. 그 점을 과장하지 않는다.

### 3-a-7. 결정

1. **비용 항을 없애지 않는다** — 없애면 46% 의 자제 부류가 임의가 된다(§3-a-3).
2. **λ 를 학습 목표에서 뺀다.** `y = closed`(물리)로 학습하고 랭킹에서 비용을 해석적으로 적용한다
   (§3-a-5). 그러면 비용은 **재학습 없이 바꿀 수 있는 배포 정책**이 된다.
3. **λ-키를 μ-키로 교체한다** (`key = (complete, closed, −(makespan + μ·cost))`), **기본 μ = 4**,
   측정된 섭동 바닥 0.775 s 에서 유도(§3-a-6).
4. **"λ=15 로 튜닝했다"는 문구를 폐기**하고 감도만 보고한다: *"λ-키의 답은 λ∈[0.5,12] 에서 불변이고,
   λ≥13 부터 측정된 12노드 이득을 지우기 시작한다."*
5. **선행 조건(솔직히 밝힘).** μ-키는 랭킹에 `makespan` 이 필요한데 현재 배포 surrogate 는
   **단일 출력**(`closed` 하나)이다. 그래서 μ-키를 배포에 쓰려면 **makespan 예측 헤드가 하나 더**
   있어야 한다. 이건 한 줄 변경이 아니다 — 덤프에 `makespan` 열은 이미 있으므로 두 번째 모델을
   export 하면 되지만, 별도 작업이다(§6-2). 그때까지 배포 경로는 λ-키(λ=3)를 쓰되 §3-a-7.2(비용을
   결정 규칙으로)만 먼저 적용하는 것을 권한다.
   · 참고로 μ 스칼라를 **그대로 회귀 목표**로 쓰면 비용/시간 항이 너무 작아 학습이 안 된다. 실측
   (`export_surrogate.py`, 같은 새 그리드 18 instance): λ-키 목표 → LOO subopt_norm **0.148** (top1 78%),
   μ-키 스칼라 목표 → **0.350** (top1 44%). 옛 데이터에서도 같은 방향(0.36–0.39)이었다.
   그래서 3번은 **2번(+ makespan 헤드)과 함께여야만** 의미가 있다. 라벨(오라클 정답)로서의 μ-키와
   회귀 목표로서의 μ-키는 다른 문제다 — 지금 나쁜 것은 후자뿐이다.

### 3-a-8. 이 결정으로 실제로 바꾼 코드 (전부 비파괴)

| 파일 | 무엇 | 기본값 |
|---|---|---|
| `export_surrogate.py` | `--cost-time --mu M` (μ-키 + 일관된 스칼라 목표), meta 에 `cost_mode`/`mu_seconds` 기록 | **꺼짐**(기존 `--cost-aware --lam` 경로 불변) |
| `export_surrogate.py` | **버그 수정**: instance 필터 `len(g)==5` → `instance_arms_complete(g)` | 즉시 |
| `export_surrogate.py` | **버그 수정**: 교차항 범위 `range(5)` → 데이터에 실제로 있는 macro (7·8 누락이었음) | 즉시(옛 덤프에선 열 이름·순서까지 동일) |
| `export_surrogate.py`, `e1_analyze.py` | **버그 수정**: macro 8(SwapBattery) 이름표 누락 → `KeyError` 크래시 | 즉시 |

두 번째 항목은 작지 않다. `DS_VALID_ONLY` 라벨은 그 사건에서 유효한 팔만 만들므로(deep battery =
NOOP/Replace/SwapBattery = 3팔) 5를 영영 못 채운다 → **배포 export 가 그런 instance 를 통째로 버리고
있었다.** `e1_analyze.py`·`dspy_service.py` 는 2026-08-05 에 이미 고쳐졌는데 이 경로만 남아 있었다.
같은 데이터에서 **60 → 108 instance** 회복.

네 번째 항목이 없으면 **SwapBattery 가 정답이 되는 데이터셋을 아예 분석할 수 없다** — 학습은 끝나고
요약을 찍다가 `KeyError: 8` 로 죽는다(실측). 즉 이 결정을 내리기 전에는 그 경로가 한 번도 실행된 적이
없다는 뜻이다.

---

## 4. 결정 (3-b) — battery 사건의 행동: Replace 인가 SwapBattery 인가

### 4-a. 두 팔은 무엇이 다른가

| | ReplaceAgent (1) | SwapBattery (8) |
|---|---|---|
| 소모 자원 | **창고의 예비 본체**(희소·유한) | 배터리(무제한, 비용만) |
| 검증 게이트 | `verify_replace` — 예비 존재 검사 필요 | `verify_swap_battery` — 예비 검사 **없음** |
| 실행 | `hot_swap_robot!` — 창고에서 본체 교체 | `swap_battery!` — 현장에서 `_reset_robot_health!` |
| 스케줄/씬트리 | 씬트리 수술(정체성은 보존) | **전혀 안 건드림** |
| 회복 범위 | SoC 완충 + stall/deplete/fault 게이트 해제 | **동일**(같은 `_reset_robot_health!`) |
| MACRO_COST | 1.0 | 0.2 |

즉 SwapBattery 는 구조적으로 **"Replace 에서 본체 소모와 씬트리 수술만 뺀 것"** 이다.

### 4-b. 측정 — 같은 사건, 세 팔 (deep 칸, 6개 발화점)

| 발화점 | progress | NOOP | Replace | SwapBattery | Replace − Swap (시간) |
|---|---|---|---|---|---|
| f58 | 0.19 | 미완주 151 | **완주 291 / 19.28 s** | 완주 291 / 19.62 s | −0.34 s (Replace 가 근소 우위) |
| f100 | 0.32 | 미완주 213 | 완주 291 / 19.25 s | 완주 291 / 19.62 s | −0.37 s |
| f142 | 0.45 | 미완주 213 | 완주 291 / 19.62 s | 완주 291 / 19.62 s | 0.00 s |
| f180 | 0.58 | 미완주 246 | 완주 291 / 20.33 s | **완주 291 / 19.62 s** | +0.71 s |
| f222 | 0.71 | 미완주 246 | 완주 291 / 24.88 s | **완주 291 / 19.62 s** | **+5.26 s (+27%)** |
| f260 | 0.83 | 미완주 274 | 완주 291 / 22.85 s | **완주 291 / 19.62 s** | +3.23 s |

읽는 법:

1. **완주·closed 는 두 팔이 항상 동일하다**(291). 회복 효과는 같다.
2. **SwapBattery 의 makespan 은 6개 발화점 전부에서 정확히 19.62 s = 대조군과 동일**하다. 현장에서
   충전 상태만 되돌리므로 사건이 **시간적으로 완전히 흡수**된다.
3. **Replace 의 makespan 은 사건이 늦을수록 나빠진다**(19.28 → 24.88 s). 창고 본체가 빌드 현장까지
   나와야 하고, 늦게 터질수록 그 왕복이 임계 경로에 얹힌다. 앞선 두 발화점에서 Replace 가 근소하게
   빠른 것(−0.34 / −0.37 s)은 §2-d 가 측정한 섭동 바닥(0.775 s) **안**이므로 실제 우위로 볼 수 없다.
4. 그리고 Replace 는 **창고 본체 하나를 영구히 소모한다.**

### 4-c. 결정

**battery 사건의 기본 개입은 `SwapBattery`(8)** 로 한다. `ReplaceAgent`(1)는 배터리가 아닌 원인으로
**본체 자체가 못 쓰게 된 경우**(breakdown/fault OOD)에만 쓴다.

근거:

1. **회복 결과가 같다** — 두 팔 모두 완주 291, 같은 `_reset_robot_health!`.
2. **시간이 같거나 SwapBattery 가 낫다** — 후반 발화에서는 최대 **+5.26 s (+27%)** 차이. 앞쪽의
   Replace 우위는 섭동 바닥 안이라 무효.
3. **자원이 다르다** — Replace 는 유한한 창고 본체를 먹는다. 단일 사건 라벨에서는 대가가 안 보이지만
   (예비가 마르지 않으므로) 다중 OOD 스트림에서는 즉시 드러난다. 이것이 `MACRO_COST` 가 존재하는
   이유이고 §3-a 의 "비용 항 유지" 결론과 맞물린다.
4. **모델이 맞다** — 배터리 사건은 **에너지원 고장**이다. 에너지원을 교체하는 것이 정합적 수리이고,
   본체를 통째로 바꾸는 것은 과잉이다.
5. **위험이 적다** — SwapBattery 는 스케줄·씬트리를 안 건드리므로 정체성 위반이 **원리적으로 불가능**.

### 4-d. 함께 고친 것 — 사건 문장의 **처방절** 제거

깊은 방전의 자연어는 이랬다.

> "Robot Rn's battery is critically flat at about X% charge; it can no longer drive or carry —
> **treat it as broken down and hand its work to a backup robot.**"

관찰이 아니라 **정답 지시**다. 두 가지가 어긋난다.

1. LLM 대조군이 부당하게 유리해진다 — 프롬프트가 답을 알려주면 "LLM vs surrogate" 비교는 해석 능력이
   아니라 지시 이행 능력을 재는 것이 된다. (문제 자체는 `md/DESIGN_ASSIMILATION.md` **오류 1-b** 에
   이미 기록되어 있다.)
2. **그 지시가 틀렸다.** §4-c 의 결론은 backup robot 이 아니라 배터리 교체다.

문구를 **증상 서술**로 바꿨다(`battery.jl` 와 `nl_events.py` 가 문자 단위로 같아야 한다).

| | 새 문구 |
|---|---|
| 깊음 | "…critically flat at about X% charge; **it has stopped where it stands and cannot drive or carry until its charge is restored.**" |
| 열화 | "…degraded and now at about X% charge; **it is moving below its normal speed and will keep draining while it works.**" |

- 옛 문구 재현: `OOD_NL_LEGACY=1`(Julia·Python 같은 이름).
- 하위 소비자 확인: `demos.jl` 의 `occursin("critically flat", …)`, `llm_producer.py` 의
  `"critically flat" in p` 는 그대로 동작한다(그 어구를 유지했다).
- **아직 안 고침(의도적):** `fault`·`zone` 템플릿에는 처방절이 남아 있다("dispatch the nearest backup
  robot…", "restage the affected assembly…"). 배터리만 중립화하면 종류 간 비교가 비대칭이 되므로,
  **LLM vs surrogate 숫자를 인용하기 전에** 네 템플릿을 한 번에 중립화해야 한다.

---

## 5. 덤으로 발견한 것 (오늘 안 고침, 근거만 기록)

### 5-a. `Deprioritize`(macro 2)는 battery 사건에서 **NOOP 과 바이트 동일**하다

새 그리드의 mild·near-nominal 12 instance **전부**에서 `Deprioritize` 의 (complete, closed, makespan)이
`NOOP` 과 **완전히 같다**. 엔진이 이유를 스스로 로그에 찍는다:

```
[RESPEC] deprioritize re-solve: energy term NOT active -- the bias cannot steer this solve
```

(`src/respec/replan.jl:842`) — SoC 편향은 MILP 의 **에너지 항**을 통해서만 작동하는데, 이 구성에서는
그 항의 가중치가 0 이라 곱할 대상이 없다. 즉 **개입 팔이 아니라 NOOP 의 사본**이다. 이는
`ForbidZone` 이 closed≈46 이후 NOOP 과 바이트 동일해져 `RelocateBuild`(macro 7)로 대체됐던 것과 정확히
같은 부류의 문제다. 처방은 둘 중 하나: (i) `RESPEC_DEPRIO_KAPPA` / 효율 가중치가 실제로 걸리도록 고치거나,
(ii) battery 의 유효 행동집합에서 2를 빼고 `NOOP` vs `SwapBattery` 로 정리한다.

### 5-a-2. 배포된 `surrogate_hotswap.json` 은 **지금 코드로 재현되지 않는다** (오늘 이전부터)

같은 데이터(`oracle/out/graded_hs_all.jsonl`, 20 instance)로 다시 export 하면 feature 가 **60 → 63** 개가
되고 LOO subopt_norm 도 0.100 → 0.250 이 된다. 늘어난 3개는 `macro_7`, `macro_8`, `zone_root_cover` — 전부
`e1_analyze.featurize` 가 그 산출물을 만든 **뒤에** 추가된 열이다. 오늘 바꾼 교차항 범위 때문이 아니다:
그 데이터셋에는 macro 0~4 밖에 없어 `sorted(set(macro)) == range(5)` 로 **완전히 동일**하다(확인함).
즉 배포 아티팩트와 featurizer 사이의 **기존 드리프트**이고, 배포 모델을 다시 만들려면 그 시점 featurizer
가 필요하다. 어차피 §3-a-7 대로 재학습할 예정이라면 그때 같이 정리하면 된다.

### 5-b. `verify.py` 의 V0 게이트는 `DS_VALID_ONLY` 덤프와 구조적으로 맞지 않는다

V0 는 "모든 instance 가 **7개 macro 팔 전부** 롤아웃되었는가"를 요구한다. VALID_ONLY 라벨은 정의상 그
사건에서 유효한 팔만 만든다(2~3개). 그래서 **핀 고정된 벤치마크에서도 V0 는 FAIL** 이다
(`python verify.py oracle/out/graded_hs_n44.jsonl` → **7/8**). §3-a-8 의 `len(g)==5` 와 같은 부류.

### 5-c. `firegrid_merged.jsonl` 에서는 surrogate 가 state-blind 상대를 못 이긴다

`python verify.py oracle/out/firegrid_merged.jsonl` → **6/8** (V0 + **S1 FAIL**: subopt_norm 0.362 vs
`always_per_kind` 0.322, CI 가 0 을 포함). 같은 검사가 `graded_hs_n44` 에서는 S1 **PASS** 다. 그리고
`firegrid_merged` 는 §1-c 의 **무의미한 후반 battery instance 를 담고 있는 바로 그 덤프**다. 인과를
단정하지는 않지만, 재라벨링 뒤 다시 재보는 것이 순서다.

---

## 6. 바뀐 파일 / 다음에 할 일

### 6-1. 바뀐 파일

| 파일 | 종류 | 요약 |
|---|---|---|
| `src/navigator/battery.jl` | 엔진 | 표적 피커 수정 / 감속 구간 / `soc_target` / NL 처방절 제거 |
| `src/navigator/ood_stream.jl` | 엔진 | `battery_action(soc_target=)` |
| `tools/checks.jl` | 검사 | stall_gate [5] 감속 단위검사 + 배율 표 / 낡은 hot-swap 단정문 수정 |
| `wm4.../oracle/gen_oracle_dataset.jl` | 라벨러 | `_arm_battery!` / 새 기본 사다리 / `DS_BSOC_MODE` / derate 초기화 |
| `wm4.../oracle/probe_fire_points.jl` | 진단 | 옛/새 표적 피커 나란히 측정 |
| `wm4.../export_surrogate.py` | 파이프라인 | instance 필터·교차항 범위·macro 8 이름 **버그 3건** / `--cost-time --mu` |
| `wm4.../e1_analyze.py` | 파이프라인 | macro 8 이름 버그 |
| `wm4.../nl_events.py` | 파이프라인 | NL 템플릿 동기화(+ `OOD_NL_LEGACY`) |

**건드리지 않은 것:** `openworld_merged.jsonl`(CANONICAL), `surrogate_hotswap.json`(배포 모델),
`novelty_calibration*.json`, `firegrid_merged.jsonl`, 녹화된 덱 영상/스트림.

### 6-2. 다음에 할 일 (우선순위)

1. **fault 재라벨링을 새 세계에서.** §1-c 가 보여주듯 진행도 축의 결론이 표적 선정에 의존한다.
   `fault`/`faultidle` 는 이미 FTU 술어로 고쳐져 있으니 재실행만 하면 된다
   (`oracle/run_firegrid_fault.ps1`).
2. **비용을 결정 규칙으로**(§3-a-7.2) 배포 경로에 반영 + **makespan 예측 헤드 추가**(§3-a-7.5).
   이 둘이 있어야 μ-키를 실제로 배포할 수 있다.
3. **네 NL 템플릿 일괄 중립화** 후 LLM baseline 재측정(§4-d).
4. **Deprioritize 를 살리거나 빼기**(§5-a). 지금은 팔 하나가 NOOP 의 사본이다.
5. **데모 세계와 라벨 세계 정렬**(§2-g) 후 덱 재렌더.
6. **seed 2 재현.** 새 측정은 seed 1(배포 world) 한 판이다. 저장소 축 정책상 world 는 seed 1 고정이
   맞지만, §1-c 의 철회는 두 번째 world 에서 확인해 두는 편이 안전하다.

---
---

# PART II — English

## 0. Decisions at a glance

| # | Item | Decision | Evidence in one line |
|---|---|---|---|
| (1) | Battery target selection | **Fixed.** Target = a robot that is a member of a **non-closed `FormTransportUnit` team** | The old picker chose a **parked spare 100% of the time from progress 0.51 on** (measured), which made 7 existing late-progress deep-battery instances vacuous |
| (2) | Severity rungs | **Redesigned** to `0.02 / 0.3 / 0.5`, plus a new **derate band** in the engine, plus severity defined as an **absolute post-drop SoC** | The old `0.05 / 0.12` are both below the stall threshold (0.15) = behaviourally identical. Without a derate band, `0.3` and `0.5` collapse from the other side |
| (3-a) | λ (adaptation cost) | **Keep the cost term. But (i) move λ out of the training target into the decision rule, and (ii) replace the λ-key with a time-priced μ-key.** Retract "tuned λ=15" | λ is **not identified** (60× change → 2.4–3.2% of answers move), λ≥13 erases a measured 12-node gain, and **λ>0 structurally disables the makespan tier**, which is where the redesigned middle rung lives |
| (3-b) | Action for battery events | **`SwapBattery` (8)** by default; `Replace` (1) only when the body itself is unusable | Both arms give the **same** completion and closed count (291), but SwapBattery consumes no depot body and is **faster the later the event fires** (24.88 → 19.62 s at f222). Also removed the **prescriptive clause** from the event sentence |

(1) and (2) are implemented and verified. (3) is delivered as decision + evidence + a **non-destructive
opt-in implementation**. Deployment artifacts (`surrogate_hotswap.json`, CANONICAL dumps, recorded
videos) were **not** touched.

---

## 1. Fix (1) — the battery event was hitting an idle robot late in the build

### 1-a. Diagnosis

Old priority order in `_pick_battery_target` (`src/navigator/battery.jl`):

```
(1) pick_solo_fault_target        ─┐
(2) pick_solo_frontier_target      ├─ all three require `_first_pending_assignment`
(3) highest-SoC non-spare passing `_first_pending_assignment` ─┘
(4) _pick_low_margin_robot = "highest-SoC robot"               ← fallback
```

`_first_pending_assignment` does **not** answer "does this robot still have work?". It answers "is it
standing at a **clean task boundary** right now?" (predecessor is a `RobotStart` or already closed).
The repo has been bitten by this exact predicate twice already
(`md/FIRE_TIME_RELABEL_2026-08-05.md` §1 = the fault picker, §4 = `_pick_idle_victim`). Once the
build is rolling, robots live inside their transport chains, so (1)–(3) **all fail** and control falls
through to (4).

And (4) picks a **parked spare**: a backup sitting in its depot is powered down, so its SoC never
drains, so "highest SoC" is always a spare. A spare owns no work, so NOOP / Replace / SwapBattery all
land on the same outcome and the instance carries zero label information.

> This risk was written down as a recommendation in `FIRE_TIME_RELABEL_2026-08-05.md` §7, but that
> note said **"no observed damage"**. §1-c overturns it — the damage was already in the data.

### 1-b. Measurement — old picker vs new picker, same run, same instant

`oracle/probe_fire_points.jl` now calls **both pickers side by side** (`batt_old` / `batt_new`, each
with "is it a spare?" and "does it own carry work?"). Observation only; no state is mutated.

```bash
PF_EVERY=20 PF_FROM=40 PF_TO=280 PF_SEED=1 \
  PF_OUT=wm4spacecraft_manufacturing/oracle/out/fire_probe_batt.csv \
  julia --project=. wm4spacecraft_manufacturing/oracle/probe_fire_points.jl
```

tractor · 10 robots · spare 3 · seed 1 (raw: `oracle/out/fire_probe_batt.csv`)

| closed | 58 | 60 | 80 | 100 | 120 | 142 | **160** | 180 | 200 | 222 | 240 | 260 | 280 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| progress | .19 | .19 | .26 | .32 | .38 | .45 | **.51** | .58 | .64 | .71 | .77 | .83 | .90 |
| **OLD target** | R1 | R1 | R10 | R7 | R7 | R7 | **R14** | R14 | R14 | R14 | R14 | R14 | R14 |
| OLD is a spare? | – | – | – | – | – | – | **Y** | Y | Y | Y | Y | Y | Y |
| OLD owns work? | Y | Y | Y | Y | Y | Y | **–** | – | – | – | – | – | – |
| **NEW target** | R1 | R1 | R4 | R1 | R1 | R1 | **R4** | R1 | R1 | R1 | R1 | R4 | R5 |
| NEW is a spare? | – | – | – | – | – | – | – | – | – | – | – | – | – |
| NEW owns work? | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | –¹ |

¹ The "–" at closed=280 is a fact, not a predicate failure: **no carry work remains at all**
(`n_hotswap = 0`). Hence the label grid stops at 260.

**From progress 0.51 the old picker hit a parked spare 100% of the time.** The new picker keeps
choosing a working robot for as long as carry work exists.

### 1-c. What this did to the existing labels — and what must be retracted

Listing the **deep-discharge (soc ≤ 0.2)** battery instances of `oracle/out/firegrid_merged.jsonl` by
build progress reproduces **exactly the boundary** from §1-b:

| fire point | progress | `agent_pending` | what separated the arms | oracle-best (λ=0) |
|---|---|---|---|---|
| f58 | 0.185 | 3–4 | feasibility | Replace |
| f100 | 0.319 | 3–5 | feasibility | Replace |
| f140 (seed 1) | 0.447 | 3 | feasibility | Replace |
| **f140 (seed 2)** | 0.450 | **0** | **all arms tie exactly** | (tie) |
| **f180** | 0.575 / 0.578 | **0** | **all arms tie exactly** | (tie) |
| **f220** | 0.703 / 0.709 | **0** | **all arms tie exactly** | (tie) |
| **f260** | 0.831 | **0** | **all arms tie exactly** | (tie) |

`agent_pending = 0` means the victim owns no remaining work — the signature of hitting a spare.

**Therefore the following conclusion is retracted:**

> `FIRE_TIME_RELABEL_2026-08-05.md` §3-a: *"even a deep discharge needs no intervention late in the
> build (≥0.58) — that robot has little work left and the fleet absorbs it … this is new structure the
> model must learn."* (recorded at the time as "the biggest finding of that session")

It was not "the fleet absorbs it". It was **"the event hit a robot that had no work in the first
place"**. Build progress did not flip the answer; **target selection broke as progress rose**.

### 1-d. Re-labelled results — the flip does not occur

```bash
DS_KINDS=battery DS_SEEDS=1 DS_BSOC=0.02,0.3,0.5 DS_FIRE_GRID=58,100,140,180,220,260 \
  DS_HOTSWAP=1 DS_VALID_ONLY=1 DS_REFORM=120 DS_RESUME=1 \
  DS_OUT=wm4spacecraft_manufacturing/oracle/out/battgrid_0805_s1.jsonl \
  julia --project=. wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl
```

18 instances / 54 rows / 0.49 h of labelling. **Control: complete, 291 closed, makespan 19.625 s.**

**Deep discharge (severity = 0.02, stalls):**

| fire point | progress | `agent_pending` | NOOP | Replace | SwapBattery |
|---|---|---|---|---|---|
| f58 | 0.19 | 4 | **incomplete 151** | complete 291 / 19.28 s | complete 291 / 19.62 s |
| f100 | 0.32 | 3 | **incomplete 213** | complete 291 / 19.25 s | complete 291 / 19.62 s |
| f142 | 0.45 | 2 | **incomplete 213** | complete 291 / 19.62 s | complete 291 / 19.62 s |
| f180 | 0.58 | 2 | **incomplete 246** | complete 291 / 20.33 s | complete 291 / 19.62 s |
| f222 | 0.71 | 2 | **incomplete 246** | complete 291 / 24.88 s | complete 291 / 19.62 s |
| f260 | 0.83 | 1 | **incomplete 274** | complete 291 / 22.85 s | complete 291 / 19.62 s |

**NOOP fails to complete at all six fire points**, including 0.58 / 0.71 / 0.83 — precisely the points
the old data reported as "all arms tie". The retraction in §1-c is confirmed by measurement.

### 1-e. Code changes

| File | What |
|---|---|
| `src/navigator/battery.jl` | `_pick_battery_target` priority (2) is now `pick_hotswap_fault_target` (non-closed FTU membership); the final fallback **excludes spares and recovery spares** |
| `wm4.../oracle/probe_fire_points.jl` | copy of the old picker (`pick_battery_target_OLD`), `owns_carry_work`, 6 new CSV columns — the evidence behind §1-b |

The first two priorities (`pick_solo_*`) are untouched, so early-build firing is **byte-identical**;
only the moments that previously fell through to the bad fallback are filled in.

---

## 2. Fix (2) — severity rungs must straddle the stall boundary

### 2-a. Diagnosis: the old ladder measured the same event twice

- Labeler stall threshold: `DS_STALL = 0.15`.
- Old default ladder `0.05, 0.12, 0.2, 0.3, 0.45, 0.6`; the two rungs used in the deployed/deck story
  were **0.05 and 0.12**.
- Both are **below** 0.15 → both stall immediately, and `soc_speed_factor` was a step function
  (≤thr → 0.0, else 1.0), so they are **behaviourally identical**.

Raising the values alone does not fix it: under a step function `0.3` and `0.5` both give factor 1.0.
The engine needs a middle band.

### 2-b. Engine fix — a graded derate band

New `BATTERY_DERATE` / `set_battery_derate!`. `soc_speed_factor` is now the **minimum factor over the
responsible robots**:

```
SoC ≤ thr(0.15)       -> 0.0                 dead: stops where it stands
thr < SoC < hi(0.5)   -> min_f(0.35) … 1.0   degraded: slower, still working (linear)
SoC ≥ hi(0.5)         -> 1.0                 effectively nominal
```

Physical justification: **power derating** at low state of charge — sagging cell voltage limits peak
power and therefore peak speed — is standard behaviour of real battery systems. The middle rung is a
natural state, not an invented knob.

Default is **off**, so the gate is byte-identical to the old step function until armed (existing dumps
stay reproducible). The labeler arms it with `DS_DERATE=1` (default on); `DS_DERATE=0` restores the
old behaviour.

Measured factors (`tools/checks.jl stall_gate` prints this table):

| target SoC | 0.02 | 0.16 | 0.20 | **0.30** | 0.40 | **0.50** |
|---|---|---|---|---|---|---|
| speed factor | **0.0000** | 0.3686 | 0.4429 | **0.6286** | 0.8143 | **1.0000** |
| behaviour | stops immediately | | | keeps working at ~63% speed | | no effect |

### 2-c. Definition fix — severity is the SoC *after* the drop, not the size of the drop

The old injection was subtractive (`soc_drop`), which shifts the rung down by whatever the victim had
already spent. **Measured**: a target of 0.02 was recorded as `soc = 0.0` (clamped at the floor).
Since the derate/stall boundaries are defined on the *resulting* SoC, that is a departure from design.

`inject_battery_fault!` / `battery_action` now take `soc_target` (absolute); the labeler defaults to
`DS_BSOC_MODE=abs`. Verified: the new dump records `soc` as exactly `0.020` / `0.300` / `0.500`. The
old path remains as `DS_BSOC_MODE=drop`.

### 2-d. What the new ladder actually produces (measured)

**Middle rung (severity 0.30, derate 0.629)** — every arm completes, so the only difference is **time**:

| fire point | progress | NOOP | Deprioritize | SwapBattery | NOOP's time penalty vs control 19.625 |
|---|---|---|---|---|---|
| f58 | 0.19 | 21.73 s | 21.73 s | 19.62 s | **+2.100 s (+10.7%)** |
| f100 | 0.32 | 19.98 s | 19.98 s | 19.62 s | +0.350 s |
| f142 | 0.45 | 19.75 s | 19.75 s | 19.62 s | +0.125 s |
| f180 | 0.58 | 19.83 s | 19.83 s | 19.62 s | +0.200 s |
| f222 | 0.71 | 19.43 s | 19.43 s | 19.62 s | −0.200 s |
| f260 | 0.83 | 20.10 s | 20.10 s | 19.62 s | +0.475 s |

**Top rung (severity 0.50)** has a derate factor of **exactly 1.0**, so it should have no physical
effect at all — which makes it an **empirical null**: how much does makespan move just from injecting
the event?

| fire point | f58 | f100 | f142 | f180 | f222 | f260 |
|---|---|---|---|---|---|---|
| NOOP − control | −0.775 | −0.125 | +0.375 | −0.275 | +0.275 | +0.025 |

→ **event-perturbation floor = 0.775 s max (3.9% of the build), 0.308 s mean.**

Together the two tables show the structure the new ladder creates:

- **0.02** — without intervention the build **cannot complete** (separated by feasibility)
- **0.30** — completes, but **costs time**; only **one** of six exceeds the perturbation floor (+2.10 s)
- **0.50** — every difference sits inside the floor = **effectively no effect**

So the three rungs are separated by *different criteria* (feasibility / time / nothing). The old
ladder (0.05, 0.12) separated all its rungs by the first criterion only.

> **Honestly**: only 1 of 6 middle-rung instances clears the perturbation floor. "The derate rung is
> decided by time" is **true but thin**. To thicken it, lower `DS_DERATE_MIN` (a harsher derate) or
> sample more early fire points, where the slowed robot still has a lot of work left.

### 2-e. Verification

`julia --project=. tools/checks.jl stall_gate` → **23 PASS / 0 FAIL**
(new block [5]: are the three rungs distinct / monotone in SoC / is just-above-threshold equal to
`min_factor` / is a degenerate `hi ≤ thr` inert / is the gate the old step function when off — plus it
prints the factor table).

Incidentally fixed a stale assertion in `tools/checks.jl hot_swap` ("hot-swap OFF by default" — the
default was deliberately flipped ON on 2026-08-04 and is now disabled only by `LEGACY_RESTAMP=1`).
**21 PASS / 0 FAIL.**

### 2-f. Code changes

| File | What |
|---|---|
| `src/navigator/battery.jl` | new `BATTERY_DERATE` / `set_battery_derate!` / `_soc_speed_of`; `soc_speed_factor` returns the min factor; `inject_battery_fault!(soc_target=)` |
| `src/navigator/ood_stream.jl` | `battery_action(soc_target=)` pass-through |
| `wm4.../oracle/gen_oracle_dataset.jl` | `_arm_battery!` (accounting + stall + derate armed in one place); default `DS_BSOC=0.02,0.3,0.5`; `DS_BSOC_MODE=abs`; derate reset between runs |
| `tools/checks.jl` | stall_gate block [5] + factor table |

### 2-g. Deliberately NOT aligned yet

**The demo world ≠ the label world.** `tools/demos.jl:2793` uses a stall threshold of `0.02` while the
labeler uses `0.15`, and the demo does not arm the derate band. The lesson this repo keeps re-learning
is "labels must be measured in the world the demo runs in", so these must be aligned when the deck
videos are re-rendered. **Left alone rather than silently changing recorded artifacts overnight.**

---

## 3. Decision (3-a) — should λ be removed?

### 3-a-1. What λ does today

```
training target : y   = closed − λ·cost(macro)                  (export_surrogate.py --cost-aware)
oracle ranking  : key = (complete,  closed − λ·cost(macro),  −makespan)
cost = {NOOP 0, SwapBattery 0.2, Deprioritize 0.3, Replace/ForbidZone/Reform 1.0, RelocateBuild 1.5}
```

The deployed model `surrogate_hotswap.json` is recorded as **"tuned at λ = 15"**.

### 3-a-2. Measurement 1 — λ is **not identified** by the data

Recomputing oracle-best on `firegrid_merged.jsonl` (126 instances) while varying only λ:

| λ | 0 | 0.5 | 1 | 3 | 5 | 10 | 15 | 30 |
|---|---|---|---|---|---|---|---|---|
| instances whose answer differs from λ=0 | – | 3 | 3 | 3 | 3 | 3 | 4 | 4 |
| fraction | – | 2.4% | 2.4% | 2.4% | 2.4% | 2.4% | 3.2% | 3.2% |

**A 60× change leaves the labels essentially unchanged.** "We tuned λ to 15" is not supported by data.

### 3-a-3. Measurement 2 — what λ does is break exact ties (so it cannot simply be deleted)

| λ | feasibility | closed | makespan | **exact tie** | decided by cost |
|---|---|---|---|---|---|
| 0 | 40 | 7 | 3 | **58** | – |
| ≥0.5 | 40 | 7 | 0 | 0 | **61** |

At λ=0, **58 of 126 (46%) tie exactly** — same completion, closed and makespan. The simulator is fully
deterministic (control makespan has one distinct value per seed), so this is not noise: the arms are
genuinely indistinguishable.

→ Deleting the cost term makes that 46% (the restraint class) **arbitrary**, and a learned policy could
burn spares forever at zero subopt_norm. **"Remove the cost term" is rejected.**

### 3-a-4. Measurement 3 — but λ as placed today **overwrites measured physics**, two ways

**(a) It erases `closed` gains**, because λ sits *inside* the `closed` slot:

```
battery_s3_sev0.2_sp3   NOOP: incomplete 248   Replace: incomplete 260   (+12 nodes)
   λ=0  → Replace   (the measured 12-node gain)
   λ=15 → NOOP      (15 > 12, gain erased)
```

On this dataset the corruption starts at **λ ≈ 13**.

**(b) It disables the makespan tier outright.** When two arms complete with the same closed count,
`closed − λ·cost` already differs, so the tuple's third component is **never consulted**.

That is fatal for the redesigned ladder of §2-d. **All six middle-rung (0.30) instances complete with
closed = 291, so their only difference is makespan.** The λ-key therefore labels all six `NOOP` at any
λ — including f58, where intervening actually recovers **10.7% of the build time**:

| severity 0.30 | f58 | f100 | f142 | f180 | f222 | f260 |
|---|---|---|---|---|---|---|
| time SwapBattery saves | **2.100 s** | 0.350 s | 0.125 s | 0.200 s | −0.200 s | 0.475 s |
| λ-key label (λ = 1, 3, 15 alike) | NOOP | NOOP | NOOP | NOOP | NOOP | NOOP |

**The λ form cannot represent the structure the redesigned severity ladder creates.**

### 3-a-5. Measurement 4 — λ belongs in the **decision rule**, not the learning target

Under the same oracle scoring (`score = closed − λ·cost`), leave-one-instance-out, 108 instances /
396 rows, the deployed RandomForest:

| Placement | training target | decision |
|---|---|---|
| **A (today)** | `y = closed − λ·cost` | `argmax ŷ` |
| **B (proposed)** | `y = closed` (physics only) | `argmax (ŷ − λ·cost)` — the cost is a **known constant**, applied analytically |

| λ | A LOO subopt_norm | B LOO subopt_norm | detail |
|---|---|---|---|
| 1 | 0.156 | 0.166 | zoneblk: A 0.089 / **B 0.000** |
| 3 | 0.042 | 0.051 | zoneblk: A 0.033 / **B 0.000** |
| 15 | 0.011 | **0.002** | battery: A 0.025 (96%) / **B 0.004 (98%)** |

> **Honest caveat**: subopt_norm is normalized by `span = score(best) − min(score)`, which grows with λ, so
> subopt_norm *looks* smaller at large λ. **Do not compare across λ.** The valid comparison is A vs B within
> a row; there B is never materially worse and at λ=15 is clearly better.

The structural reason is simple: `cost(macro)` is not something to estimate — it is a known constant.
Folding it into the target forces the model to approximate "physics + price" jointly, and changing the
price then requires **retraining**. Separated, the model learns physics and the price is a
deployment-time policy.

### 3-a-6. The alternative key — price the cost in **makespan seconds** (μ)

```
key = (complete,  closed,  −(makespan + μ·cost))
```

- Cost can **structurally never** override completion or progress → §3-a-4(a) is impossible.
- The makespan tier comes back → §3-a-4(b) is solved.
- μ is an **interpretable exchange rate**: "how many seconds of build time is one unit of intervention
  worth".
- Unlike λ it is **identified** — the break-even points are computable from the new grid:

| instance | switch | μ threshold |
|---|---|---|
| deep f58 | Replace → SwapBattery | μ > 0.438 |
| deep f100 | Replace → SwapBattery | μ > 0.469 |
| mild f142 | SwapBattery → NOOP | μ > 0.625 |
| mild f180 | SwapBattery → NOOP | μ > 1.001 |
| mild f100 | SwapBattery → NOOP | μ > 1.75 |
| mild f58 | SwapBattery → NOOP | μ > 10.5 |

**μ can be chosen from data.** §2-d measured an event-perturbation floor of **0.775 s**; differences
below that must not buy an intervention. SwapBattery vs NOOP differ by 0.2 in cost, so
`μ·0.2 ≳ 0.775` → **μ ≳ 3.9**; and preferring SwapBattery over Replace on the deep rung needs
μ > 0.47. **μ = 4** satisfies both and sits far from the nearest break-even (1.75, 10.5).

Meaning: *"spend a depot body (cost 1.0) only if it saves ≥ 4 s of build time; spend a battery swap
(cost 0.2) only if it saves ≥ 0.8 s"* — and 0.8 s is the floor we **measured**.

λ=3 vs μ=4 over the 18 instances:

| | deep ×6 | mild ×6 | near-nominal ×6 |
|---|---|---|---|
| λ=3 | SwapBattery ×6 | NOOP ×6 | NOOP ×6 |
| **μ=4** | SwapBattery ×6 | **SwapBattery ×1 (f58)**, NOOP ×5 | NOOP ×6 |

**They differ on 1 of 18.** That is small — but that one instance is exactly the case the redesign was
built to create, and λ cannot produce it **at any value**. The case for μ is **expressiveness and
non-corruption**, not a large accuracy gain, and I will not overstate it.

### 3-a-7. Decision

1. **Do not remove the cost term** — removing it makes 46% of the dataset arbitrary (§3-a-3).
2. **Take λ out of the learning target.** Train on `y = closed` (physics); apply the cost analytically
   when ranking (§3-a-5). The price then becomes a **deployment knob that needs no retraining**.
3. **Replace the λ-key with the μ-key** (`key = (complete, closed, −(makespan + μ·cost))`), default
   **μ = 4**, derived from the measured 0.775 s perturbation floor (§3-a-6).
4. **Retire "tuned λ=15"** and report the sensitivity instead: *"under the λ-key the answers are
   invariant for λ ∈ [0.5, 12]; from λ ≥ 13 the cost term starts erasing a measured 12-node gain."*
5. **Prerequisite, stated plainly.** The μ-key needs `makespan` at ranking time, and the deployed
   surrogate is **single-output** (`closed` only). Deploying the μ-key therefore requires **a second
   prediction head for makespan**. That is not a one-line change — the dump already has the column, so
   it is "export a second model", but it is separate work (§6-2). Until then the deployment path should
   keep the λ-key (λ=3) and adopt only item 2.
   · For the record: using the μ scalar **directly as a regression target** does not work — the
   cost/time term is too small to learn. Measured (`export_surrogate.py`, the same 18-instance grid):
   λ-key target → LOO subopt_norm **0.148** (top-1 78%); μ-key scalar target → **0.350** (top-1 44%). The
   old data pointed the same way (0.36–0.39). Item 3 is therefore only meaningful **together with**
   item 2 (+ a makespan head). Note these are two different questions: the μ-key as a *label* (oracle
   ranking) versus the μ-key as a *regression target*. Only the latter is bad.

### 3-a-8. What this decision changed in code (all non-destructive)

| File | What | Default |
|---|---|---|
| `export_surrogate.py` | `--cost-time --mu M` (μ-key + a consistent scalar target); `cost_mode` / `mu_seconds` in the exported meta | **off** (the `--cost-aware --lam` path is unchanged) |
| `export_surrogate.py` | **bug fix**: instance filter `len(g)==5` → `instance_arms_complete(g)` | applied |
| `export_surrogate.py` | **bug fix**: interaction range `range(5)` → the macros actually present (7 and 8 were missing) | applied (byte-identical columns on old dumps) |
| `export_surrogate.py`, `e1_analyze.py` | **bug fix**: macro 8 (SwapBattery) missing from the name table → `KeyError` crash | applied |

The second item is not cosmetic. `DS_VALID_ONLY` only labels the arms that are legal for an event
(deep battery = NOOP / Replace / SwapBattery = 3 arms), so such instances can never reach 5 and **the
deployment export was silently discarding all of them**. `e1_analyze.py` and `dspy_service.py` were
fixed for this on 2026-08-05; this path was missed. Measured on the same data: **60 → 108 instances**.

Without the fourth item **no dataset in which SwapBattery wins can be analysed at all** — training
finishes and the run then dies with `KeyError: 8` while printing the summary (measured). In other
words, that code path had never been executed before this decision.

---

## 4. Decision (3-b) — Replace or SwapBattery for a battery event?

### 4-a. How the two arms differ

| | ReplaceAgent (1) | SwapBattery (8) |
|---|---|---|
| Resource consumed | **a spare BODY from a depot** (scarce, finite) | a battery (unmetered, cost only) |
| Verification gate | `verify_replace` — needs an available spare | `verify_swap_battery` — **no spare check** |
| Enactment | `hot_swap_robot!` — body exchanged from the depot | `swap_battery!` — in the field via `_reset_robot_health!` |
| Schedule / scene tree | scene-tree surgery (identity preserved) | **untouched** |
| Recovery scope | SoC restored + stall/deplete/fault gates cleared | **identical** (same `_reset_robot_health!`) |
| MACRO_COST | 1.0 | 0.2 |

SwapBattery is structurally **"Replace minus the body consumption and minus the scene-tree surgery"**.

### 4-b. Measurement — same event, three arms (deep rung, six fire points)

| fire point | progress | NOOP | Replace | SwapBattery | Replace − Swap (time) |
|---|---|---|---|---|---|
| f58 | 0.19 | incomplete 151 | **complete 291 / 19.28 s** | complete 291 / 19.62 s | −0.34 s (Replace marginally ahead) |
| f100 | 0.32 | incomplete 213 | complete 291 / 19.25 s | complete 291 / 19.62 s | −0.37 s |
| f142 | 0.45 | incomplete 213 | complete 291 / 19.62 s | complete 291 / 19.62 s | 0.00 s |
| f180 | 0.58 | incomplete 246 | complete 291 / 20.33 s | **complete 291 / 19.62 s** | +0.71 s |
| f222 | 0.71 | incomplete 246 | complete 291 / 24.88 s | **complete 291 / 19.62 s** | **+5.26 s (+27%)** |
| f260 | 0.83 | incomplete 274 | complete 291 / 22.85 s | **complete 291 / 19.62 s** | +3.23 s |

How to read it:

1. **Completion and closed count are always identical** (291). The recovery is the same.
2. **SwapBattery's makespan is exactly 19.62 s at all six fire points = the control.** Restoring charge
   in the field absorbs the event **completely in time**.
3. **Replace's makespan degrades the later the event fires** (19.28 → 24.88 s): the depot body has to
   drive out to the build, and the later it fires the more that round trip sits on the critical path.
   Replace's marginal lead at the first two points (−0.34 / −0.37 s) is **inside** the 0.775 s
   perturbation floor measured in §2-d, so it is not a real advantage.
4. And Replace **permanently consumes one depot body**.

### 4-c. Decision

**`SwapBattery` (8) is the default intervention for battery events.** `ReplaceAgent` (1) is reserved
for cases where the *body itself* is unusable (the breakdown / fault OOD).

Reasons:

1. **Same recovery outcome** — both complete at 291, both via `_reset_robot_health!`.
2. **Equal or better in time** — up to **+5.26 s (+27%)** in SwapBattery's favour at late fire points;
   Replace's early lead is inside the perturbation floor and therefore void.
3. **Different resource** — Replace consumes a finite depot body. A single-event label cannot show that
   cost (the pool never drains), but a multi-OOD stream does immediately. This is why `MACRO_COST`
   exists, and it dovetails with §3-a's "keep the cost term".
4. **Correct model** — a battery event is an **energy-source failure**. Replacing the energy source is
   the matched repair; replacing the whole body is overkill.
5. **Lower risk** — SwapBattery touches neither schedule nor scene tree, so an identity violation is
   structurally impossible.

### 4-d. Fixed alongside — the prescriptive clause in the event sentence

The deep-discharge sentence read:

> "Robot Rn's battery is critically flat at about X% charge; it can no longer drive or carry —
> **treat it as broken down and hand its work to a backup robot.**"

That is not an observation, it is **the answer**. Two things go wrong:

1. It unfairly favours the LLM arm — if the prompt states the answer, an "LLM vs surrogate" comparison
   measures instruction-following, not interpretation. (Already on record as **error 1-b** in
   `md/DESIGN_ASSIMILATION.md`.)
2. **The instruction is wrong.** Per §4-c the correct action is a battery swap, not a backup robot.

The wording is now symptom-only (`battery.jl` and `nl_events.py` must stay character-identical):

| | new wording |
|---|---|
| deep | "…critically flat at about X% charge; **it has stopped where it stands and cannot drive or carry until its charge is restored.**" |
| degraded | "…degraded and now at about X% charge; **it is moving below its normal speed and will keep draining while it works.**" |

- Old wording: `OOD_NL_LEGACY=1` (same variable on the Julia and Python sides).
- Downstream consumers checked: `demos.jl`'s `occursin("critically flat", …)` and `llm_producer.py`'s
  `"critically flat" in p` still match (the phrase was preserved).
- **Deliberately not done:** the `fault` and `zone` templates still carry their prescriptive clauses
  ("dispatch the nearest backup robot…", "restage the affected assembly…"). Neutralizing only battery
  makes cross-kind comparison asymmetric, so all four should be neutralized in one pass **before
  quoting any LLM-vs-surrogate number**.

---

## 5. Found along the way (not fixed today; recorded with evidence)

### 5-a. `Deprioritize` (macro 2) is **byte-identical to NOOP** on battery events

In **all 12** mild and near-nominal instances of the new grid, `Deprioritize`'s
(complete, closed, makespan) equals `NOOP`'s exactly. The engine logs why:

```
[RESPEC] deprioritize re-solve: energy term NOT active -- the bias cannot steer this solve
```

(`src/respec/replan.jl:842`) — the SoC bias acts only through the MILP's **energy term**, and in this
configuration that term's weight is zero, so there is nothing for the bias to multiply. It is not an
intervention arm; it is **a copy of NOOP**. This is the same class of problem as `ForbidZone` becoming
byte-identical to NOOP after closed≈46, which is why `RelocateBuild` (macro 7) replaced it. Either
(i) make `RESPEC_DEPRIO_KAPPA` / the efficiency weight actually take effect, or (ii) drop macro 2 from
battery's valid set and let the arms be `NOOP` vs `SwapBattery`.

### 5-a-2. The deployed `surrogate_hotswap.json` **cannot be reproduced by current code** (pre-dating today)

Re-exporting from the same data (`oracle/out/graded_hs_all.jsonl`, 20 instances) yields **60 → 63**
features and LOO subopt_norm 0.100 → 0.250. The three extra columns are `macro_7`, `macro_8` and
`zone_root_cover` — all added to `e1_analyze.featurize` **after** that artifact was produced. This is
not today's interaction-range change: that dataset contains only macros 0–4, so
`sorted(set(macro)) == range(5)` and the columns are identical (verified). It is **pre-existing drift**
between the deployed artifact and the featurizer; reproducing the deployed model would need the
featurizer of that date. If it is going to be retrained per §3-a-7 anyway, fold this in then.

### 5-b. `verify.py`'s V0 gate is structurally incompatible with `DS_VALID_ONLY` dumps

V0 requires that every instance have **all 7 macro arms** rolled out. VALID_ONLY labels only the legal
arms (2–3). So **V0 fails even on the pinned benchmark**:
`python verify.py oracle/out/graded_hs_n44.jsonl` → **7/8**. Same class as the `len(g)==5` filter in
§3-a-8.

### 5-c. On `firegrid_merged.jsonl` the surrogate does not beat the state-blind baseline

`python verify.py oracle/out/firegrid_merged.jsonl` → **6/8** (V0 + **S1 FAIL**: subopt_norm 0.362 vs
`always_per_kind` 0.322, CI includes 0). The same check **passes** on `graded_hs_n44`. And
`firegrid_merged` is exactly the dump that contains the vacuous late-progress battery instances of
§1-c. I am not asserting causation — but re-measuring after re-labelling is the right order.

---

## 6. Changed files / next steps

### 6-1. Changed files

| File | Kind | Summary |
|---|---|---|
| `src/navigator/battery.jl` | engine | target picker fix; derate band; `soc_target`; prescriptive clause removed |
| `src/navigator/ood_stream.jl` | engine | `battery_action(soc_target=)` |
| `tools/checks.jl` | tests | stall_gate block [5] + factor table; stale hot-swap assertion fixed |
| `wm4.../oracle/gen_oracle_dataset.jl` | labeler | `_arm_battery!`; new default ladder; `DS_BSOC_MODE`; derate reset |
| `wm4.../oracle/probe_fire_points.jl` | diagnostics | old vs new target picker measured side by side |
| `wm4.../export_surrogate.py` | pipeline | **3 bug fixes** (instance filter, interaction range, macro-8 name) + `--cost-time --mu` |
| `wm4.../e1_analyze.py` | pipeline | macro-8 name bug |
| `wm4.../nl_events.py` | pipeline | NL templates kept in sync (+ `OOD_NL_LEGACY`) |

**Not touched:** `openworld_merged.jsonl` (CANONICAL), `surrogate_hotswap.json` (deployed model),
`novelty_calibration*.json`, `firegrid_merged.jsonl`, recorded deck videos / streams.

### 6-2. Next steps, in priority order

1. **Re-label `fault` in the new world.** §1-c shows conclusions about the progress axis depend on
   target selection; `fault`/`faultidle` already use the FTU predicate, so this is a re-run
   (`oracle/run_firegrid_fault.ps1`).
2. **Move the cost into the decision rule** on the deployment path (§3-a-7.2) **and add a makespan
   prediction head** (§3-a-7.5). Both are needed before the μ-key can actually be deployed.
3. **Neutralize all four NL templates in one pass**, then re-measure the LLM baselines (§4-d).
4. **Repair or remove `Deprioritize`** (§5-a) — right now one arm is a copy of NOOP.
5. **Align the demo world with the label world** (§2-g), then re-render the deck.
6. **Replicate on seed 2.** These measurements are one world (seed 1, the deployment world). The repo's
   axis policy pins world at seed 1, but the retraction in §1-c is worth confirming on a second world.
