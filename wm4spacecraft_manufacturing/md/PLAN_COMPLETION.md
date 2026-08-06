# 완주 문제 조사 — 단계별 계획 (2026-08-04 시작)

## 질문

무OOD는 100% 완주하고 fault/battery(3사건)는 38% 완주하는데, **zone 사건이 끼면 0%** 다.
캡(`DS_NOPROG`)은 A 실험에서 범인이 아님이 확정됐다(8000/30000 결과가 바이트 단위로 동일).
그러면 **무엇이 빌드를 죽이는가?**

이게 풀리면 같이 풀리는 것들: 성공률 지표의 분모, 2층 분해(P(complete)∈(0,1)), harm 축,
그리고 "개입이 빌드를 구해내는" 데모.

## 가설

| | 가설 | 반증 방법 |
|---|---|---|
| H1 | TangentBug 가 구역 경계에서 영구 대기 | 멈춘 로봇이 rim 근처에 몰리는가 |
| H2 | 가야 할 목표가 구역 안이라 도달 불가 | 멈춘 로봇의 목표가 구역 내부인가 |
| H3 | 구역과 무관한 운반팀 형성 교착 | NOOP 판도 똑같이 멈추는가 |
| H4 | **빌드 전체 평행이동이 이송 중 화물을 desync** | NOOP 판은 안 멈추는가 |

## S0 — 죽는 방식 특징짓기 (완료, 새 시뮬 0)

도구: `diag_stall.py` (모니터 스트림의 프레임별 로봇 mode/pos/action 사용).

**결과 (zonecore + RelocateBuild, 정지 @ closed=266/305)**

```
로봇 18대 · 움직임 0 · 움직이다 멈춤 18 · 처음부터 정지 0
mode: CARRY 3, TRANSIT 15
구역 기준: RIM 근접 0 (0%) · 구역 안 0 · 구역 밖 18
   가장 가까운 정지 로봇도 구역 경계에서 +0.283 (로봇 반지름 0.14 의 2배)
   적재 운반체 3대는 구역에서 1.9 / 3.2 / 4.6 떨어진 곳에서 정지
```

**대조군 (완주한 판, zone + NOOP)**: 움직임 10 · 멈춤 8(전부 멀리 있는 TRANSIT).

**판정**
- **H1 반증** — 멈춘 로봇 중 구역 경계 근처가 **0%**. 구역이 물리적으로 막고 있지 않다.
- **H2 반증** — 구역 안에 있는 로봇 0.
- 남은 것은 H3 vs H4. 특징이 "**전 함대가 동시에 정지**, 짐 실은 운반체까지"라서
  단일 로봇이 막힌 그림이 아니다.

> **도구 함정(대조군이 잡아냈다).** 첫 판에서는 "얼어붙음 18"과 완주 판의 "얼어붙음 8"이
> 구분되지 않았다. 주차된 예비 로봇은 처음부터 안 움직이므로 정지로 잡힌다. 그래서
> 스트림 **전체** 이동량을 같이 재서 "움직이다 멈춤"과 "처음부터 정지"를 갈랐다.
> 대조군을 안 돌렸으면 이 confound 를 못 봤을 것이다.

## S1 — H3 vs H4 가르기 (진행 중)

**같은 사건, 다른 행동.** `DEMO_OOD=zonecore CORE_FRAC=1.0` 를 고정하고 행동만 바꾼다:

| 판 | 정책 | 스트림 |
|---|---|---|
| 개입 | `DEMO_POLICY=dspy` (→ RelocateBuild) | `tractor__zonecore_gpt41.jsonl` (정지 @266) |
| 대조 | `DEMO_POLICY=canonical DEMO_ROUTER=0` (→ NOOP) | `tractor__zonecore_noop.jsonl` |

판정:
- NOOP 판이 **완주하거나 훨씬 멀리 가면 → H4**(평행이동이 원인). 그러면 문제는 zone 이 아니라
  **`translate_whole_build!` 의 in-flight 처리**이고, 고칠 지점이 아주 좁아진다.
- NOOP 판도 **비슷하게 정지하면 → H3**(구역이 있으면 행동과 무관하게 죽는다). 그러면 표적은
  운반팀 형성/스케줄 전이 쪽이고, RelocateBuild 는 무죄다.

### S1 결과 — **H4 반증**

| 행동 | 정지 지점 | 정지 양상 |
|---|---|---|
| NOOP | **234**/305 | 18/18 움직이다 멈춤 · RIM 0% · CARRY 5 / TRANSIT 13 |
| RelocateBuild | **266**/305 | 18/18 움직이다 멈춤 · RIM 0% · CARRY 3 / TRANSIT 15 |

둘 다 멈추고 **양상이 같다**(전 함대 동시 정지, 구역 경계 근처 0%). 평행이동은 정지의 원인이
아니다 — 오히려 **RelocateBuild 가 32 노드 더 갔다**.

**여기서 하나가 뒤집혔다.** 이 데모 설정에서는 RelocateBuild 가 NOOP 보다 **낫다**(266 > 234).
어제 오라클(seed 301, core frac 1.0)에서는 반대였다(NOOP 245 > RB 123). 설정이 다르다 —
데모는 로봇 18대·`n_spare_per_pool=2`·hot-swap ON·발화 closed≈54, 오라클은 22대·spare 3·
발화 closed 56. **즉 "RelocateBuild 가 손해"는 설정 의존적이며 보편 사실이 아니다.** n=1 이므로
주장이 아니라 관찰로만 기록한다.

### S1 이 남긴 새 질문 (S2 로)

NOOP 이 멈추는 건 설명된다 — 구역이 root 하역 목표 8/8 을 덮었으니 그 `LiftIntoPlace` 는 영원히
못 닫힌다. **이게 의도한 harm 이고, 실제로 작동했다**(234 < 266).
설명이 안 되는 쪽은 RelocateBuild 다: `residual_work_discs=0` 으로 구역을 완전히 벗어났는데도
266 에서 멈춘다. 구역이 원인이 아니라면 **무엇이** 멈추게 하는가?

## S2 결과 — **실패는 언제나 루트에서만** (새 시뮬 0)

스트림의 `assemblies`(build_steps_closed/total, status)를 실패 판들에서 대조:

| 판 | closed | 루트 | 하위 7개 |
|---|---|---|---|
| 완주 판 다수 | 287 | **4/4 done** | 7/7 done |
| `battery_mild_rule` (**zone 없음**) | 256 | **1/4 open** | 7/7 done |
| `fault_battery_canon` (**zone 없음**) | 256 | **1/4 open** | 7/7 done |
| `zonecore_noop` | 234 | **0/4 eligible** | 7/7 done |
| `zonecore_gpt41` | 266 | **2/4 open** | 7/7 done |

**루트 정지는 zone 고유가 아니다** — zone 없는 battery·fault 판도 똑같이 루트에서 죽는다.
스케줄 실행기록 diff 로 빠진 항목도 확인했다: `LiftIntoPlace·ObjectID(1~4)`(루트 직속 부품)와
그에 딸린 `FormTransportUnit → TransportUnitGo → DepositCargo`. 운반체가 출발은 하는데
도착·하역을 못 한다.

그리고 core zone 의 **harm 은 실재한다**: NOOP 은 루트를 **시작조차 못 하고**(0/4),
RelocateBuild 는 0/4 → 2/4 로 부분 구제한다(closed 234 → 266).

## S3 결과 — **완주 달성**. 원인은 데모에 복구 경로가 없던 것

`run_demo.jl` 에 교착 복구 장치가 **하나도 없었다**(오라클 생성기는 `set_reform_interval!(120)`).
그래서 한 번 끼면 그대로 죽었다. 추가한 것:

* `DEMO_REFORM` — 무진전 N스텝마다 "팀 교착" 사건을 **결정 레이어로** 올린다(직접 복구가 아니라).
* `DEMO_REFORM_MAX` — 발화 상한. 없으면 `handle_ood!` 뒤의 `stall = 0` 리셋 때문에 정지 판정이
  영영 안 나고 무한 반복한다(실측: reform 20회+, closed 266 고정).
* `ReformTeam` 실행 분기 — `recover_stalled_teams!` → 실패 시 `resolve_schedule_wedge!`.

같이 잡은 버그: `policy.jl` 의 truth→kind 매핑에 **ReformTruth 분기가 없어** `else` 로 떨어져
`"fault"` 로 전달됐다 → valid 가 `[NOOP,Replace,Deprioritize]` 가 되어 **ReformTeam 을 고를 수조차
없었고**, 실측에서 Deprioritize 를 골라 아무 복구도 안 됐다.

```
DEMO_OOD=zonecore CORE_FRAC=1.0 DEMO_POLICY=dspy DEMO_REFORM=600
  zone      → ESCALATED→LLM → RelocateBuild (Δ 이동, residual 0)
  팀 교착   → ROUTED→LLM (novel) → ReformTeam (recover=snapped)
  → PROJECT COMPLETE @ step 1698, closed=287, 루트 4/4, 8/8 done
```

**이게 "개입이 빌드를 구해내는" 최초의 렌더 판이다.** 스트림:
`tools/monitor/streams/tractor__zonecore_gpt41_reform.jsonl`

### 대조군까지 포함한 2x2 — 둘 다 필요, 서로 대체 불가

| | reform 없음 | reform 있음 |
|---|---|---|
| NOOP | 234 정지 | **234 정지** (force_snap 까지 시도해도) |
| RelocateBuild | 266 정지 | **287 완주** |

reform 만으로는 못 구한다(NOOP 행). RelocateBuild 만으로도 못 구한다(reform 없음 열).
NOOP 은 루트 하역 목표가 구역 안이라 팀을 재정립해도 **놓을 곳이 없고**(루트 0/4),
RelocateBuild 는 목표를 빼내지만 **팀 교착이 남는다**(루트 2/4). **서로 다른 두 실패**다.

### 완주 정의 주의 (모든 수치 재해석 필요)

무OOD 30-seed 기준선: **완주 시 `closed=291/313`**. 즉 **완주 ≠ closed==total**.
데모 설정에서는 완주가 `closed=287`. 그러니 달성 가능치 대비로 읽어야 한다 —
NOOP 234 = **82%**, RelocateBuild 266 = **93%**.

## S4 — 남은 것 (미실행)

1. **오라클도 같은 처방으로 완주하는가.** 오라클 생성기는 이미 `set_reform_interval!(120)` 을
   켜는데도 zone 판은 0% 다. 데모는 같은 처방으로 완주했으므로 **둘의 reform 경로가 다르다**
   (오라클=전역 respec 큐 + CASCADE 규칙으로 NOOP 응답, 데모=truth 로그 직접). 여기가 맞으면
   어제의 zone 라벨 전체가 재생성 대상이 된다 — 파급이 가장 큰 항목.
2. **n 을 늘린다.** 지금 2x2 는 seed 1개다. 최소 4~5 seed 로 반복해 우연이 아님을 보인다.
3. **`DEMO_REFORM` 기본값**을 켤지 결정. 지금은 0(기존 데모 재현 보존). 켜면 기존 스트림들의
   결과가 달라지므로, 새 케이스에만 적용할지 전면 적용할지는 별도 판단.

## 실행 순서 원칙

- **한 번에 하나만 바꾼다.** S1 은 사건·seed·설정을 전부 고정하고 **행동만** 바꾼다.
- **대조군을 반드시 같이 돌린다.** S0 에서 도구 결함을 잡아낸 것이 대조군이었다.
- **가설을 먼저 적고 반증 기준을 숫자로 정한다.** "rim 근처가 절반 이상이면 H1" 처럼.
