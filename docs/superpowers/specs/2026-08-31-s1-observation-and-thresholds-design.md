# S1 — 모델이 받는 값을 옳게 만든다 (zone 서술자 · battery 관측 · 임계 사다리)

- 날짜: 2026-08-31
- 워크트리: `Construction_OODlayer` (브랜치 `oracle-rebuild-night-2026-08-10`, HEAD `26723eb2`)
- 상태: 설계 확정. 구현 계획은 별도 문서.
- 이 문서는 자족적이다 — 다른 spec 을 인용하지 않는다.

> **근거 구분 규약.** *실측*은 2026-08-31 에 이 머신에서 명령을 돌려 얻은 것이거나 저장된
> 산출물을 직접 집계한 것이다. 코드를 읽고 추론한 것은 **추론이라고 표시**한다. 이 레포는
> 정적 추론이 뒤집힌 이력이 많다.
>
> **인용 규약.** 실행 파일은 **줄번호가 아니라 심볼로** 인용한다. 이 레포는 줄번호 인용이
> 조용히 썩는 것을 반복해 겪었다(2026-08-30 마감 보고서 §1-1).

---

## 0. 한 줄 요약

**두 OOD 레인에서 합성이 발화하지 않는 원인은 배선이 아니라 모델이 받는 값이다.**
zone 은 이미 있는 값이 틀렸고(면적비를 피해로 읽는다), battery_mild 는 판단에 필요한 값이
아예 없다(payload 가 프롬프트에 한 글자도 없다). S1 은 그 값만 고친다 — 합성도, 집행도,
루프도 건드리지 않는다.

```
오늘                                          이 설계
────────────────────────────────────         ──────────────────────────────────
zone:   harm = zone_overlap = 0.0024         zone:   nav_blocked≥1 → harm = 1.0
        (32/251 노드가 얼어붙은 판에서)                war = nav_downstream/pending
        ⟹ expressible = True (115/115)               = 0.127

mild:   payload 값이 프롬프트에 없다           mild:   THIS ROBOT'S REMAINING
        "55%면 충분" 이 반박 불가한 독해               TRANSPORT LOAD 블록 신설
        ⟹ expressible = True (6/6)                   (사실만, 판정 없음)

임계:   routing 0.1 / menu 0.2 / stall 0.15   임계:   deep = menu = routing = 0.1
        (0.1,0.2] 밴드가 조용히 죽어 있다              stall 0.05 (엄격히 아래)
                                                     학습 사다리 "0.02,0.09"
                                                     severe 프리셋 DEMO_BSOC 0.96
                                                     교차 게이트가 밴드를 막는다
```

---

## 1. 이 설계가 딛는 실측

전부 2026-08-31 에 이 머신에서 잰 것이다. 유료 호출 0건.

### 1-1. 두 레인 모두 라이브에서 `expressible=True` 였다

저장된 결정 스트림을 직접 집계했다.

| 스트림 | 결정행 | `expressible` | `chosen` | `tools_offered` | `routing_kind` |
|---|---|---|---|---|---|
| `tractor__zone_minted.jsonl` | 115 | **True × 115** | NOOP | 1 | `unknown:zone` |
| `tractor__battery_mild_before.jsonl` | 6 | **True × 6** | NOOP | 1 | `unknown:battery_mild` |
| `tractor__battery_mild.jsonl` | 6 | **True × 6** | NOOP | 1 | `unknown:battery_mild` |

🔴 **이것이 2026-08-30 마감 보고서를 정정한다.** 그 보고서는 `battery_mild` 의 라이브 발화가
T9 미집행으로 *"측정된 적 없다"* 고 적었다. 없는 것은 `battery_mild_minted` **보드**이고,
`expressible` 값 자체는 기준선 보드가 이미 디스크에 남겼다. ⟹ **발화 실패는 zone 만의
문제가 아니라 두 레인 공통이다.**

### 1-2. zone 프롬프트는 자기모순이다

같은 스트림의 `router.llm_input` 원문(모델이 실제로 읽은 문자열)에서:

```
of which blocked     = 3      (…the node can never close while the zone lives)
work frozen by those = 32
(the build has 251 unfinished nodes in total)
...
  harm               = 0.00
  work_at_risk       = 0.00
```

그리고 모델의 `tool_args.reason` 이 그 0 을 인용한다 —
*"The harm, work at risk, and resource loss are all measured at 0.00, indicating no immediate
threat to the assembly process."*

**기전.** `policy.jl :: _zone_overlap` 은 미완 staging 원들에 대한
`max(교집합 면적 / staging 원 면적)` 이다 — 면적비이고, 합이 아니라 최대값이다.
`novelty.jl :: event_descriptors` 의 공간 분기가 `harm = work_at_risk = zone_overlap` 이고,
파이썬 twin(`features_agnostic.descriptors_from_row`)의 주석이 의도를 그대로 적는다 —
*"공간류: 덮은 비율 자체가 곧 피해 정도"*.

그런데 이 판의 실제 피해 기전은 staging 덮임이 아니다. 같은 스트림의 진단값:
`n_blocked=0` (덮인 미개시 조립체 0개) · `n_nav_engulfed=3` · `n_nav_blocked=3` ·
`n_nav_downstream=32`. **두 기하가 다른데 하나만 숫자 채널에 실려 있다.**

### 1-3. 덮임은 종단적이지 않고, 막힘은 종단적이다

| 판 | overlap | nav_blocked | 결과 |
|---|---|---|---|
| `zone_before.log` | 0.0024 | 3/131 | `PROJECT INCOMPLETE!` |
| `zone_minted/render.log` | 0.0024 | 3/131 | `PROJECT INCOMPLETE!` |
| `battery_mild_before.log` | — | — | `PROJECT COMPLETE!` |
| (레포 기록) root 하역목표 8/8 덮임 | 미기록 | 0 *(추론)* | 완주, 시간만 2.1배 |

마지막 행은 `policy.jl :: valid_macros` 의 docstring 이 기록한 옛 실측이고, 레포는 바로 그
이유로 프롬프트 기하 블록을 `_GEOM_COVERAGE` / `_GEOM_BLOCKAGE` 둘로 갈라 두었다
(*"덮임은 해로움이 아니다"*).

⚠️ **그 행의 두 칸은 원문에 없다.** docstring 이 적은 것은 `root_covered = 8/8` 과 "완주,
2.1배"뿐이다. `zone_overlap`(staging 원 면적비)은 **기록되지 않았고**, `nav_blocked = 0` 은
같은 docstring 의 기전 논증(*"구역이 강제되는 곳은 `enforce_restriction_zone_clearance!`
하나뿐이고 그 함수는 RVO 에이전트만 밀어내므로, 화물을 직접 옮기는 LiftIntoPlace 목표는
원리적으로 못 막힌다"*)에서 온 **추론**이다. 재측정한 적 없다.

⟹ **`overlap > 0 → harm = 1.0` 은 반증된다. `n_nav_blocked ≥ 1 → harm = 1.0` 은 방어된다.**
후자는 그 필드의 계약 문구 자체가 종단성을 주장한다 — *"도착 허용반경이 배제원 안에 통째로
들어가서, 존이 사는 한 그 노드는 절대 안 닫힌다"*.

⚠️ **표본 주의.** 위 네 행은 각각 n=1 이다. 인과의 증거가 아니라 "면적비가 0 에 가까운데
프로젝트가 안 끝난 판이 실재한다" 는 존재 증명이다. 그것만으로 손잡이를 바꿀 근거는 되지만,
비율로 인용하면 안 된다.

### 1-4. battery_mild 프롬프트에는 payload 가 없다

같은 스트림의 `llm_input` 전문에서 battery 사건이 받는 것은 관찰문 한 줄과 서술자 6개뿐이다:
`harm=0.45`(= 1−soc) · `work_at_risk=0.28`(= 쥔 **작업 수** ÷ 로봇당 평균 몫) ·
`resource_loss=0.45` · `recovery_capacity=0.32` · `progress=0.80` · `slack=0.57`.
모델의 답: *"55% charge, which is sufficient for continued operation"*.

**payload 질량은 어느 채널에도 없다.** 그러므로 "낮은 SoC 로봇이 무거운 짐을 맡으면 SoC 가
더 빨리 떨어지고, 결국 교체에 추가 에너지가 든다" 는 추론은 오늘 **원리적으로 불가능**하다.
zone 이 *틀린 값* 문제라면 mild 는 *없는 값* 문제다.

### 1-5. 서술자를 고치는 비용은 싸다

6개 서술자의 소비처를 전수했다.

| 소비처 | 상태 |
|---|---|
| LLM 프롬프트(`descriptors` → MEASURED STATE 블록) | **유일한 live 소비처** |
| `export_novelty_calibration.py` | `NOVELTY_DETECTOR`·`novelty_verdict` 의 **생산 호출자 0개** (2026-08-29 §B-1 에서 축 삭제, 시험에만 남음) |
| `features_agnostic` 리포팅 | 분석용 |

🟢 **surrogate 는 이 6개를 안 쓴다.** `surrogate/surrogate_linear.json` 의 `feature_names`
43개를 직접 읽었고, 전부 원시 피처(`severity`·`zone_overlap`·`soc`·`agent_pending`…)이며
`harm`/`work_at_risk` 가 **없다**. ⟹ **재학습도 재라벨도 필요 없다.**

🔴 그러므로 `severity` 는 **한 글자도 안 건드린다.** zone 에서 `severity = zone_overlap` 이고
그 값은 surrogate 피처다. 서술자만 고친다.

⚠️ **조용한 함정(고치지 않고 기록만 한다).** `export_novelty_calibration.py` 의 DESCRIPTOR
지문은 `_sha16("|".join(STATE_DESCRIPTORS))` — **이름만** 해싱한다. 공식을 바꿔도 지문이
안 바뀌므로 옛 교정이 조용히 로드된다. 그 축이 죽어 있어 오늘은 무해하지만, 되살릴 때 터진다.

### 1-6. 임계 셋이 갈라져 죽은 밴드가 있다

`lane_select.jl` 을 직접 include 해 SoC 사다리를 표로 냈다(`REPLACE_SOC_THRESHOLD` 기본 0.2).

```
soc_after  routing_kind            menu
0.10       battery                 ["NOOP", "Replace", "SwapBattery"]
0.1000001  unknown:battery_mild    ["NOOP", "Replace", "SwapBattery"]   ← LLM 레인인데 3팔
0.15       unknown:battery_mild    ["NOOP", "Replace", "SwapBattery"]
0.20       unknown:battery_mild    ["NOOP", "Replace", "SwapBattery"]
0.2000001  unknown:battery_mild    ["NOOP"]
```

**(0.1, 0.2] 구간은 LLM 레인으로 가면서 개입 팔을 다 갖는다** — 그 구간에서 합성 레인은
구조적으로 절대 발화하지 않는다. 두 임계를 함께 보는 게이트는 레포에 **0개**였다(이 설계
당시 실측): `test_lane_select.jl` 은 `REPLACE_SOC_THRESHOLD`/`battery_arms` 를 0회 언급하고,
그 시절의 `test/mild_menu_is_noop_only.jl` 은 `ROUTING_SEVERE_SOC`/`routing_kind` 를 0회
언급했다. (그 격차가 `test/soc_ladder_is_coherent.jl` 을 낳았다. 🔴 `mild_menu_is_noop_only.jl`
자체는 2026-08-31 뒤이은 정리로 지워졌다 — mild 가 NOOP-only 라는 전제를 사용자가 의도적으로
뒤집을 예정이었기 때문이다. 🔴 **정정 (2026-09-01, S1 final wave / F-3)**: 아래 표현
"그 파일이 지키던 명제 중 미기록 soc 를 다루던 것만 옮겨졌다"는 **거짓이었다** — 실제로는
그 파일이 지키던 명제 (1)(2)("mild 구간의 메뉴가 정확히 `["NOOP"]`")는 `ae7e935c` 이후
바뀐 적 없는 `test/battery_menu_lanes_agree.jl` 의 "mild 는 닫힌 어휘에 수복이 없다" testset이
**계속 지키고 있었다**(삭제와 무관하게 살아 있었다 — 옮겨진 게 아니라 애초에 거기 있었다).
미기록 soc 를 다루던 명제 (4) 도 같은 파일로 옮겨졌다. 🔴 **재정정 (2026-09-01, correction
pass C-2)**: 바로 위 "실제로 잃은 것은 명제 (3)(`DS_BATTERY_SOC_SPLIT` 손잡이 기본값)뿐"은
이 삭제에 대해 이 문서에 실린 **세 번째 잘못된 서술**이었다 — 틀렸다. **실측**:
`action_registry.jl :: soc_split_enabled` 의 기본값을 `"1"` → `"0"` 으로 뒤집으면
`soc_ladder_is_coherent.jl` (1)이 아니라 `battery_menu_lanes_agree.jl` 의 **첫**
testset("battery 메뉴: 실행 레인 == 어휘 단일 진실원")이 곧바로 빨개진다(실측 3 passed /
3 failed) — `live_menu`(→`valid_macros`→`soc_split_enabled()`)와 `registry_menu`(`split=true`
리터럴)가 그 기본값에서 갈리기 때문이다. 즉 (3) 도 이미 게이트돼 있었다 —
**`mild_menu_is_noop_only.jl` 삭제로 게이트를 잃은 명제는 하나도 없다.** 사용자가 S2 에서
mild 를 뒤집으면 `battery_menu_lanes_agree.jl` 의 두 testset 모두 **그때** 빨개진다 — 이
게이트는 아직 살아 있고, 삭제로 치웠다고 생각한 장애물이 아니다.)

세 번째 임계도 갈라져 있다: `DEMO_STALL_SOC` 기본값이 **0.15**(`run_demo.jl`·`render_demo.jl`
두 곳의 리터럴)이다. 오늘은 stall(≤0.15) ⊂ deep(≤0.2) 이라 정합적이다.

### 1-7. 임계를 내리면 **학습 사다리와 정지 임계가 같이 끌려온다**

🔴 **초판 정정 (2026-08-31).** 이 절은 처음에 *"저장된 데이터셋의 사다리
`{0.02:9, 0.30:9, 0.50:9}` 는 어느 임계에서도 안 뒤집힌다 ⟹ 재라벨 불필요"* 라고만 적었다.
그것은 **저장된 파일**에 대해서는 참이지만 **생성기**에 대해서는 거짓이다.

**손잡이가 둘이고 레인도 둘이다.** `battery_arms` 는 그 둘이 공유한다(의도된 설계 —
`test/battery_menu_lanes_agree.jl` 이 그 합의를 못박는다. 옛날에 두 레인이 갈려 "라벨을 만든
세계와 실제로 굴린 세계의 행동공간이 달랐던" 사고를 고친 자리다).

| 레인 | 손잡이 | 기본값 | `["NOOP"]` 의 뜻 |
|---|---|---|---|
| 실행(라이브 데모) | `DEMO_BSOC` | `0.45` (battery_mild 프리셋) | **원하는 것** — 닫힌 어휘에 수복이 없다는 신고 = 합성 발화 조건 |
| 라벨(오라클 생성) | `DS_BSOC` | `"0.02,0.18"` (실측, `gen_oracle_dataset.jl`) | **쓸모없는 학습 행** — 팔이 하나면 굴려도 비교 대상이 없다 |

⚠️ `gen_oracle_dataset.jl` 의 주석 블록은 *"DS_BSOC 기본 = 0.02 / 0.3 / 0.5"* 라고 적지만
**그 주석은 낡았다.** 코드의 실제 기본값은 `"0.02,0.18"` 이다.

**메뉴 경계를 0.1 로 내리면 학습 칸 `0.18` 이 `["NOOP"]` 쪽으로 넘어간다** →
`test/battery_ladder_is_deep_only.jl` 단언 1(*"모든 칸이 deep = 팔 2개 이상"*)이 빨개지고,
라벨 레인이 **아무것도 안 가르치는 행**을 만든다.

```
                    0.02        0.09   0.10   0.18        0.45
학습 사다리(DS_BSOC)  ●───────────────────────●
데모(DEMO_BSOC)                                             ●

오늘 경계 0.2 :  ├──────── deep(3팔) ────────────────┤├─ mild(NOOP) ─
                   0.02 ✅        0.18 ✅                    0.45 → NOOP ✅

새 경계 0.1  :  ├─ deep(3팔) ─┤├──────── mild(NOOP) ────────────────
                   0.02 ✅        🔴 0.18 → NOOP    ← 학습 행인데 비교가 0
```

**그리고 같은 게이트의 단언 2** 는 사다리가 **정지 임계를 걸칠 것**을 요구한다(즉시 정지하는
칸과 감속만 하는 칸이 둘 다 있을 것 — 2026-08-05 *"심각도 축이 점 하나"* 회귀 방지).
⟹ `stall == deep` 이면 deep 구간 전체가 "정지"라 감속 칸이 **원리적으로 존재할 수 없다.**
**stall 은 deep 보다 엄격히 낮아야 한다.**

**저장된 데이터셋은 이미 다른 세대다.** `battery_physics` 도장을 직접 읽었다:
`{"stall": false, "derate": false, "stall_soc": 0.001}` — 즉 그 라벨은 stall·derate 를 **끈 채**
생성됐고, 사다리도 생성기의 현재 기본값과 다르다(`{0.02, 0.30, 0.50}` vs `"0.02,0.18"`).
⟹ **지금 기본값을 고치는 것이 살아 있는 산출물을 깨는 것은 아니다.** 그러나 그 세대 격차 자체는
문서로 못박아야 한다 — 이 데이터셋으로 거동을 주장하면 안 된다.

### 1-8. 후보 간선 여지는 비개입으로 셀 수 있다 (추론 + 부분 실측)

`essential_tg_coponents.jl :: preprocess_project_schedule(sched)` 는 **`sched` 만의 순수
함수**다(실측: 솔버 호출 없음, env 인자 없음). 그 출력의 `n_eligible_successors` 와
`outdegree` 만으로 Big-M 후보 루프의 **외곽 게이트**를 셀 수 있다.

🔴 이것이 2026-08-30 마감 보고서 §6-4 물음 ①(*"집행이 한 번은 일어나야 답이 나온다 — 닭과
달걀"*)을 **부분적으로 반증한다.** 상계는 solve 없이 읽힌다.

⚠️ **추론이다.** 이 프로브를 실제 결정 시점에 돌려 본 적은 없다 — T4 가 그것을 잰다.

---

## 2. 승인 기준

이 레인이 답하는 물음 하나: **두 OOD 사건에서 모델이 `expressible=false` 를 내는가.**

- **(a)** 프로브 격리 측정에서 zone 의 `expressible` 이 `False` 로 뒤집힌다 — 서술자 변경 **단독**의 효과
- **(b)** 보드 1판씩에서 zone·mild 둘 다 같은 값이 나온다 — 레인이 실제로 돈다
- **(c)** 줄리아 스위트 `fail == 0 && error == 1`(Gurobi 라이선스, 기존), 파이썬 `194 passed`
  유지, pass 델타가 **새 게이트의 단언 수로 설명된다**

🔴 **(a) 와 (b) 를 한 숫자로 요약하지 않는다.** (a) 가 뒤집혀도 (b) 가 안 뒤집힐 수 있다 —
§5 의 임계 변경이 물리를 같이 바꾸기 때문이다. 두 관측은 다른 것을 잰다.

🔴 **`expressible == False` 비율은 부분적으로 프롬프트 준수를 잰다.** 그 필드의 description
(`tool_registry.py :: _EXPRESSIBLE_DESC`)이 모델에게 *언제* false 라고 말할지를 가르친다.
이 레인의 어떤 초록도 "모델이 추론했다" 의 증거로 인용하면 안 된다.

---

## 3. zone 서술자 재정의

`event_descriptors` 의 공간 분기를 **덮임에서 막힘으로** 옮긴다. 손잡이는 `n_nav_blocked` 다.

```
harm = nav_blocked ≥ 1 ? 1.0                            : zone_overlap
war  = nav_blocked ≥ 1 ? nav_downstream / pending_total : zone_overlap
```

- 오늘 판이면 `harm 0.00 → 1.00`, `work_at_risk 0.00 → 0.127`(32/251).
- `pending_total = total_nodes − closed_at_fire` 는 두 구현에 **이미 있는 값**이다.
- 두 서술자의 원래 의미 분담을 지킨다: `harm` = *"얼마나 나쁜 사건인가"*(종단성),
  `work_at_risk` = *"얼마나 많은 일이 위협받나"*(크기).

**삼상 규약.** `nav_blocked` 를 **못 쟀으면**(`-1`) 오늘 동작 그대로 `zone_overlap` 이다.
`zone_overlap` 이 이미 쓰는 규약(`-1` = 해당 없음/못 쟀다)을 그대로 따른다. 0 으로 접지
않는다 — "재 봤더니 0" 과 "안 쟀다" 는 다른 사건이다.

**새 계산이 없다.** `ood_features` 가 이미 `zone_nav_blocked`·`zone_nav_downstream` 를
싣는다(`zone_diagnosis` 가 계산해 둔 값이라 추가 비용 0).

**파이썬 twin 을 같은 커밋에서 같은 규칙으로 고친다.** 두 벌이 갈리면 교정이 무의미해진다는
것이 `descriptors_from_row` 의 계약이다. 행 키는 `zone_nav_blocked`·`zone_nav_downstream`
로 줄리아와 같다.

🔴 `severity` 는 안 건드린다(§1-5).

---

## 4. battery 기하 블록 신설

`_zones_block` 과 **정확히 같은 관용구**다: 값이 하나도 없으면 **빈 문자열** → 비-battery
사건의 프롬프트는 바이트 동일.

### 4-1. 줄리아가 싣는 값

`ood_features` 의 `truth isa CB.BatteryTruth` 분기에 다섯을 더한다. 전부 **기존 함수 조합**이다.

| 키 | 유도 |
|---|---|
| `battery_pending_transports` | `_agent_pending(env, agent)` — 이미 있다 |
| `battery_payload_max_kg` | 위 순회의 각 미완 `RobotGo` 의 후속 `FormTransportUnit` 에 `_payload_mass(env, node, p)` 를 걸어 최대 |
| `battery_payload_total_kg` | 같은 순회의 합 |
| `battery_fleet_soc_median` | `BATTERY_FLEET[].soc` 의 중앙값 |
| `battery_higher_soc_robots` | `BATTERY_FLEET[].soc` 에서 이 로봇보다 높은 활성 로봇 수 |

`_payload_mass` 는 `FormTransportUnit` 을 받는 세 노드 종류 중 하나다(실측: 그 함수의 가드).
`_agent_pending` 은 이미 그 로봇의 미완 `RobotGo` 중 후속이 `FormTransportUnit` 인 것만
세므로, 같은 순회를 재사용한다.

⚠️ **전제조건.** 배터리 레이어가 꺼져 있으면(`BATTERY_FLEET[] === nothing`) 세 SoC 키는
안 싣는다 → 블록이 부분 렌더된다. `_zones_block` 이 키마다 `is not None` 으로 거르는 규약과
같다.

### 4-2. 파이썬이 렌더하는 것

`_battery_block(r)` 을 `_zones_block` 옆에 신설하고 `_llm_input` 의 **두 반환 경로 모두**에
붙인다(한쪽만 붙이면 옛 호출자의 프롬프트에서 조용히 사라진다 — `_llm_input` docstring 의 경고).

```
THIS ROBOT'S REMAINING TRANSPORT LOAD (measured):
  pending_transports     = 4      (unfinished transport jobs this robot is committed to)
  heaviest_payload_kg    = 12.80  (mass of the heaviest cargo among them)
  total_payload_kg       = 21.34  (sum over those jobs)

FLEET STATE OF CHARGE (measured):
  this_robot_soc         = 0.55
  fleet_soc_median       = 0.94
  robots_with_higher_soc = 7      (active robots whose charge is above this robot's)
```

🔴 **사실만 적고 "그러니 무엇을 하라"는 절대 안 적는다.** `_GEOM_COVERAGE` 의 규약 그대로다.
특히 *"더 높은 SoC 로봇에게 넘겨라"* 로 번역하지 않는다 — 그것은 판정이고, 적는 순간 재는
것이 추론이 아니라 프롬프트 준수가 된다(정답 누수).

---

## 5. 임계 사다리 단일 진실원화

| 대상 | 오늘 | 이 설계 |
|---|---|---|
| `REPLACE_SOC_THRESHOLD` (`ood_truth.jl`) | `Ref(0.2)` | `Ref(0.1)` |
| `DEMO_STALL_SOC` 기본값 (`run_demo.jl`·`render_demo.jl`) | 리터럴 `"0.15"` × 2곳 | **`0.05`**, 단일 함수에서 유도 |
| `DS_STALL` 기본값 (`gen_oracle_dataset.jl`) | `"0.15"` | **`"0.05"`** |
| `DS_BSOC` 기본 사다리 (`gen_oracle_dataset.jl`) | `"0.02,0.18"` | **`"0.02,0.09"`** |
| `reference_policy.py :: BATTERY_DEEP_SOC` | `0.2` | `0.1` |
| `ROUTING_SEVERE_SOC` (`lane_select.jl`) | `0.1` | **리터럴 0.1 유지** + 교차 게이트 신설 |

새 사다리가 게이트 둘을 동시에 만족하는지 손으로 확인해 둔다(T3 이 값으로 재단언한다):
`0.02 ≤ 0.1` ✅ · `0.09 ≤ 0.1` ✅ (단언 1, 두 칸 다 3팔) · `0.02 ≤ 0.05` 정지 ✅ ·
`0.09 > 0.05` 감속 ✅ (단언 2, 두 거동을 걸친다).

🔴 **`stall = deep` 은 폐기됐다(D-6 정정).** 그렇게 묶으면 deep 구간 안에 감속 칸이 원리적으로
없어 단언 2 를 만족하는 사다리가 존재하지 않는다(§1-7). **stall 은 deep 보다 엄격히 낮다.**
D-6 이 노린 성질(*mild 로봇은 아직 굴러간다*)은 `stall(0.05) < deep(0.1)` 로 그대로 지켜진다 —
`> 0.1` 인 로봇은 정지 임계보다 한참 위다.

**왜 `ROUTING_SEVERE_SOC` 를 유도하지 않는가.** `lane_select.jl` 은 **의존성-0 계약** 위에
있고(그래서 전수 단위검사가 된다), `CB.REPLACE_SOC_THRESHOLD` 를 import 하면 그 계약이
깨진다. 대신 두 값이 갈리는 것을 **게이트가 값으로 막는다** — `test_soc_threshold_agrees.py`
가 줄리아·파이썬 사이에서 하는 것과 같은 자세다.

**왜 stall 을 내리는가.** 그러면 mild(`> 0.1`)가 *"감속했지만 아직 굴러가는"* 구간이 되어
payload 재배정 이야기가 물리적으로 성립한다. `action_registry.json` 의 `_doc` 이 스스로
*"이 하니스의 배터리 사건은 '저하'가 아니라 '정지'라 degraded-but-alive 상태가 없다"* 고 적어
둔 것이 정확히 그 부재이고, 이 변경이 그것을 만든다.

**왜 두 stall 손잡이를 같이 내리는가.** `DEMO_STALL_SOC`(실행 레인)와 `DS_STALL`(라벨 레인)이
갈리면 두 세계의 물리가 갈린다 — 이 레포가 2026-08-13 에 정확히 그 자리에서 데였고,
`run_demo.jl` 의 주석이 *"기본값은 render_demo.jl 과 같아야 한다"* 고 적어 둔 이유다.

`test_soc_threshold_agrees.py` 는 소스를 파싱하므로 **저절로 따라온다**(수정 불필요).

🔴 **대가.** stall 임계가 0.15 → 0.05 로 내려가므로 **데모 물리가 바뀐다.** 저장된 판·스트림은
다른 세계의 것이 된다. ENV 기본값이라 재컴파일은 없다. 그래서 §2 의 (a)와 (b)를 갈라 두었다.

### 5-1. 🔴 severe 프리셋도 같이 움직여야 한다

`run_demo.jl` 의 주석이 *"threshold 0.15 — 주입 OOD 의 결과 SoC 는 `DEMO_BSOC=0.9` → ≈0.10
이므로 확실히 정지한다"* 고 적는다. **정지 임계를 0.05 로 내리면 그 논증이 깨진다.**

실측(저장된 severe 보드 `tractor__battery.jsonl`): `soc_after = 0.09940100931992335`.
라우팅 경계 0.1 바로 아래이고 여유가 **6e-4** 다(`lane_select.jl` 이 스스로 *"여유가 얇다"* 고
적어 둔 그 자리). 0.0994 > 0.05 이므로 **정지하지 않는다** — 그런데 NL 은 여전히
*"it has stopped where it stands"* 라고 말한다(NL 은 `REPLACE_SOC_THRESHOLD` 로 갈리지 실제
정지 여부로 갈리지 않는다). 그것이 `render_demo.jl` 주석이 경고한 모양 그대로다:
*"대시보드가 '로봇이 그 자리에 멈췄다'는 NL 을 띄우면서 화면에서는 멀쩡히 계속 움직인다."*

**제약 다섯이 동시에 성립하는 조합은 하나뿐이다:**

| | 제약 | 출처 |
|---|---|---|
| C1 | 라우팅 severe 경계 = 0.1 | 2026-08-30 사용자 결정 ("SoC 90% 감소") |
| C2 | 메뉴 경계 = 0.1 | 이 설계 (#4 통일) |
| C3 | 학습 사다리 전 칸 ≤ 0.1 **이면서** stall 을 걸친다 ⟹ `stall < 0.1` | `battery_ladder_is_deep_only.jl` 단언 1·2 |
| C4 | severe 데모 로봇이 실제로 정지한다 ⟹ `soc_after ≤ stall` | `render_demo.jl` 의 NL/화면 일치 요구 |
| C5 | severe `soc_after = 1 − DEMO_BSOC − 소모` | `inject_battery_fault!` |

C3+C4 는 `soc_after ≤ stall < 0.1` 을 요구하는데 오늘 `soc_after = 0.0994` 다 ⟹ **모순.**
C5 를 움직여 푼다:

**`DEMO_BSOC` 기본값 `"0.9"` → `"0.96"`** (`run_demo.jl` · `render_demo.jl` 두 곳).
그러면 `soc_after ≈ 0.039` 로 `stall(0.05)` 아래에 확실히 들어가고, 라우팅 경계 0.1 에 대한
마진도 6e-4 에서 ~0.06 으로 실질화된다.

⚠️ 이것은 `ROUTING_SEVERE_SOC = 0.1` 의 **근거를 바꾸지 않는다.** 그 상수의 뜻은 여전히
*"무엇을 심각하다고 부를 것인가"* 이고, 데모 프리셋이 그 경계보다 더 깊어질 뿐이다.
`lane_select.jl` 의 주석에서 `DEMO_BSOC=0.9` 를 인용하는 두 줄은 같이 갱신한다.

🔴 T3 은 `DEMO_POLICY=noop` 판(**유료 0건**)으로 severe 로봇이 실제로 정지하는지 확인하기
전에는 닫지 않는다.

🟢 라벨은 재생성하지 않는다(§1-7).

---

## 6. 후보 간선 상계 프로브

**재는 것:** 결정 시점(`closed≈245`)에 `edge_costs` 가 채워질 여지가 있는가. 이 답이 **S2 의
재가격 경로가 성립하는지**를 가른다.

**방법:** 결정 시점에 `preprocess_project_schedule(env.sched)` 를 읽고
`outdegree(sched,v) < n_eligible_successors[v]` 인 정점 수를 센다. 이것은 후보 `(v,v2)` 쌍의
**상계**다.

- **0 이면** 후보 간선이 증명 가능하게 0 → S2 의 "재가격 단독" 경로는 죽고, 슬롯을 여는
  한 걸음이 같은 tool 안에 들어가야 한다. **답이 여기서 끝난다.**
- **\>0 이면** 결론을 못 낸다(상계이므로). 정확한 카운트는 S2 로 넘긴다.

🔴 **상계만 재는 이유는 두 벌 방지다.** 정확히 세려면 Big-M 루프의 3중 조건을 복제해야 하고,
안 갈리게 하려면 hot loop 를 수술해야 한다 — S1 범위 밖이다. 한쪽 방향으로만 결론을 주는
값을 정직하게 그렇게 쓴다.

🔴 **삼상을 안 뭉갠다.** `slots=<n> measured_at_closed=<c>` 로 찍고, 못 쟀으면 `0` 이 아니라
`n/a` 다. 이 값은 **"MILP 가 돌았는가" 를 주장하지 않는다** — 그건 `enact.jl` 의 센티넬
(`ran_milp = !(LAST_EDGE_COSTS[] === _sent)`)의 몫이고 다른 관측이다.

**비개입 증명:** 프로브 전후 `env` 지문(`nv`·`ne`·`length(closed_set)`)이 같다고 게이트가
단언한다.

---

## 7. 게이트와 음성 대조

각 변경마다 **정상 코드를 상대로 빨개지는 변이**를 명시한다. 이 레포는 "식을 베껴 쓴 시험"이
24/24 초록을 받은 전례가 있다.

| 대상 | 단언 | 🔴 음성 대조 |
|---|---|---|
| zone 서술자 | `nav_blocked=1, zov=0.001` → `harm === 1.0` · `war === 32/251` | 옛 공식(`harm = zov`)을 이 fixture 에 대고 단언하면 `1.0 === 0.001` 로 빨개진다 |
| zone 서술자 | `nav_blocked=0, zov=0.8` → `harm === 0.8` | **덮임만으로 1.0 을 만들면 빨개진다** — §1-3 의 "root 8/8 덮여도 완주" 를 보존하는 자리 |
| zone 서술자 | `nav_blocked=-1` → 오늘 값 그대로 | 삼상 규약(못 쟀다 ≠ 0) |
| twin 일치 | 같은 행에 줄리아·파이썬이 6값을 소수점까지 같게 낸다 | 한쪽만 고치면 빨개진다 |
| battery 블록 | 값이 하나도 없으면 프롬프트가 **바이트 동일** | 치환 불변성(`_zones_block` 게이트와 같은 관용구) |
| battery 블록 | 블록 문자열에 매크로 이름도 `should`/`recommend` 도 없다 | 판정 누수 방지 |
| battery 블록 | `heaviest_payload_kg` 가 실제 화물에서 나온다 | `_payload_mass` 를 상수 0 으로 변이시키면 빨개진다 |
| 임계 | `stall_soc_default() === REPLACE_SOC_THRESHOLD[]` | 리터럴 `0.15` 를 되살리면 빨개진다 |
| 임계 교차 | SoC 사다리 전 구간에서 `routing_kind=="battery"` ⟺ `battery_arms` 가 3팔 | **오늘 코드에 대고 돌리면 실제로 빨갛다** — (0.1,0.2] 밴드를 값으로 못박는 자리 |
| 프로브 | 전후 env 지문 동일 | 개입이 섞이면 빨개진다 |

(이 설계 당시 살아 있던 `test/mild_menu_is_noop_only.jl` (1) 은 `DEMO_BSOC=0.45` 리터럴을
쓰므로 **그대로 초록이어야 한다** — 0.45 는 양쪽 임계에서 mild 다. 이 파일이 빨개지면 변경이
의도 밖으로 샌 것이다. 🔴 그 파일은 2026-08-31 뒤이은 정리로 지워졌다 — mild 가 NOOP-only 라는
(1)(2)(3) 을 사용자가 의도적으로 뒤집을 예정이라 그 게이트가 앞길을 막았기 때문이다.
🔴 **정정 (2026-09-01, S1 final wave / F-3)**: "남는 회귀 대상은 (4) 뿐이다"는 **거짓이었다**.
(1)(2)("mild 는 NOOP-only")는 `test/battery_menu_lanes_agree.jl` 의 "mild 는 닫힌 어휘에
수복이 없다" testset이 `ae7e935c` 이후 손 안 대고 계속 지키고 있다 — 파일 삭제로 없어진
적이 없다. (4)(미기록 soc)도 같은 파일로 옮겨갔다. 🔴 **재정정 (2026-09-01, correction pass
C-2)**: "실제로 남는 게이트 없는 규정은 (3) 뿐이다" 도 **거짓이었다** — 세 번째로 틀린
서술. **실측**: `action_registry.jl :: soc_split_enabled` 기본값을 `"1"` → `"0"` 으로 뒤집으면
`battery_menu_lanes_agree.jl` 의 첫 testset("실행 레인 == 어휘 단일 진실원")이 빨개진다
(3 passed / 3 failed) — `live_menu` 가 그 기본값을 읽는 `soc_split_enabled()` 를 거치고
`registry_menu` 는 `split=true` 를 그대로 넘기기 때문이다. **`mild_menu_is_noop_only.jl`
삭제로 게이트가 사라진 명제는 없다** — (1)(2)는 위 문단대로, (3)은 방금 잰 이 testset이,
(4)는 같은 파일로 옮겨간 F-1c testset이 지킨다.)

---

## 8. 유료 검증 절차

🔴 **모든 유료 호출 전에 서비스 세대를 확인한다:**
`ps -eo pid,lstart,cmd | grep "port <PORT>"` 로 기동 시각을 마지막 관련 커밋 시각과 대조.
`/health` 200 은 세대 증거가 **아니다** — 이 머신에서 나흘 묵은 프로세스가 살아 200 을 낸
전례가 있다(2026-08-29 실측). 애매하면 남의 프로세스를 건드리지 말고 **빈 포트에 새로 띄워
`DSPY_URL` 로 가리킨다**.

**🔴 프로브 격리는 두 레인에 대칭이 아니다.**

- **zone 은 완전히 격리된다.** 필요한 값이 전부 저장된 스트림에 있다
  (`descriptors` · `zone_primitives.n_nav_blocked=3` · `n_nav_downstream=32` ·
  `unfinished_total=251`). 그 값들로 `/macro` **요청 본문**을 재구성하고 서술자만 새 공식으로
  갈아끼우면 **물리를 안 건드리고** 서술자 효과 단독을 잰다.
  ⚠️ 이 문서에서 "payload" 는 **화물 질량**을 뜻한다 — HTTP 요청 본문은 "요청 본문"이라 쓴다.
- **battery 는 원리적으로 격리가 안 된다.** payload 블록의 값은 **새로 재는 값**이라 저장된
  스트림에 없다. 보드를 돌려야 나온다. 이 비대칭을 보고서에 적고, mild 의 결과를 zone 과
  같은 종류의 증거로 인용하지 않는다.

| Step | 내용 | 유료 |
|---|---|---|
| A | zone 프로브 — 새 서술자 단독 효과 (대조군은 디스크에 있음) | 1 |
| B | 보드 1판 (zone), 임계 사다리 포함 | 1 |
| C | 보드 1판 (battery_mild), payload 블록 포함 | 1 |
| D | (조건부) C 에서 `expressible` 이 안 뒤집히면, 그 보드가 **실제로 실은** payload 값으로 프로브 1건 — 값 문제인지 판단 문제인지 가른다 | 0–1 |

**예산 4건, 상한 6건.** 초과하면 멈추고 사용자에게 올린다.

---

## 9. 이 설계가 하지 않는 것 (범위 선언)

- **합성 발화 이후 전부** — 합성이 실제로 tool 을 주조하는지, 그것이 집행되는지는 S2/S3
- **바인더 위치인자 · ID 접지 · battery 원시 활성화 · payload 재가격 원시** — S2
- **LLM 의 줄리아 코드 생성 · 그림자 실행 관문 · undo · 합성 tool 의 메뉴 동적 등재** — S3
- **`edge_energy` 에 payload 배선** — S2. 오늘 `edge_costs[(v,v2)] = edge_energy(dt_min) *
  edge_cost_multiplier(sched, v)` 가 `payload_mass` 를 안 넘긴다(기본 1.0)는 것은 실측했으나,
  고치는 것은 이 레인이 아니다.
- **라벨 재생성** — 기본값(`DS_BSOC`·`DS_STALL`)만 바꾸고 **재생성은 안 한다**. 저장된
  데이터셋은 이미 다른 세대이므로(§1-7 의 `battery_physics` 도장) 이 변경이 그것을 깨지 않는다.
  🔴 그 세대 격차 자체를 T6 보고서가 못박는다 — **이 데이터셋으로 거동을 주장하면 안 된다.**
- **novelty 교정 되살리기** — §1-5 의 지문 결함은 주석과 보고서에 **기록만** 한다
- **`sdd-lane-c7` 재현성 수정 병합** — S1 은 n=1 판만 쓰므로 불필요.
  🔴 **그 대가로 S1 의 어떤 숫자도 비율로 인용하면 안 된다.**

---

## 10. 태스크와 예산

| # | 태스크 | h |
|---|---|---|
| T0 | 미커밋 라우팅 레인 커밋 + 삭제 정리 — 안 하면 이 레인의 변경이 남의 미커밋 작업과 섞인다 | 0.5 |
| T1 | zone 서술자 재정의 (줄리아 + 파이썬 twin) + 게이트 4종 | 2.0 |
| T2 | battery 기하 블록 (줄리아 피처 · 파이썬 렌더 · 게이트 3종) | 2.5 |
| T3 | 임계 사다리 단일 진실원화(6개 상수) + 교차 게이트 + severe 정지 확인 | 2.5 |
| T4 | 후보 간선 상계 프로브 | 1.0 |
| T5 | 유료 검증 (프로브 + 보드 2판) | 1.5 |
| T6 | 보고서 — 무엇의 증거가 **아닌가** | 1.0 |
| | | **11.0** |

T1 · T2 · T3 은 서로 독립이라 순서를 바꿔도 된다. T5 는 T1~T3 전부 뒤다.

---

## 11. 사용자 결정 기록 (2026-08-31)

| | 결정 | 근거 |
|---|---|---|
| **D-1** | 작업을 **S1 → S2 → S3** 세 하위 프로젝트로 분해한다 | 한 spec 으로는 통제 불가. S1 없이는 S2/S3 가 영원히 발화하지 않는다(§1-1) |
| **D-2** | payload×SoC 결합은 **OOD 결정 시점 재가격**으로 다룬다 | S2 의 방향. 그 전제조건인 후보 간선 실측을 S1 이 §6 으로 떠맡는다 |
| **D-3** | zone 은 `harm=1.0` + `work_at_risk=비율` | 두 서술자의 원래 의미 분담에 맞다 |
| **D-4** | 알파벳에 없는 원시는 **LLM 이 줄리아 코드까지 생성**한다 | S3 의 방향. 샌드박스·그림자 관문이 그 레인의 필수 구성요소가 된다 |
| **D-5** | battery 위험은 **기하 블록 신설**로 관측한다 | 서술자·라벨 열을 안 건드려 가장 싸다 |
| **D-6** | ~~stall 임계를 deep 에서 유도한다~~ → **정정(D-8)**. stall 은 deep 보다 **엄격히 낮다**(0.05 < 0.1) | 원안은 `battery_ladder_is_deep_only.jl` 단언 2 와 구조적으로 양립 불가능하다(§1-7). D-6 이 노린 성질은 `stall < deep` 으로 그대로 지켜진다 |
| **D-7** | 라이브 검증은 **프로브 격리 후 보드 2판** | 서술자 효과를 물리 변화와 안 섞는다. 예산 4건 |
| **D-8** | 학습 사다리를 새 경계 아래로 내린다 — `DS_BSOC "0.02,0.09"` · `DS_STALL`/`DEMO_STALL_SOC` `0.05` · `DEMO_BSOC` `0.96`. **재라벨은 하지 않는다** | 경계를 0.1 로 내리면 학습 칸 0.18 이 단일 팔이 되어 아무것도 못 가르친다(§1-7). 그 연쇄가 stall 과 severe 프리셋까지 끌고 간다(§5-1) |
