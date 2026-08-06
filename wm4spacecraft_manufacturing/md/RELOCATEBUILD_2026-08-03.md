# RelocateBuild (매크로 7) — 구현·검증 기록 (2026-08-03)

> ## ⚠ 2026-08-04 정정 — 이 문서의 **수치**는 무효, **구현**은 유효
>
> 이 문서의 모든 완주율·closed 수치는 `ood_mdp_shim.event_context` 의 버그가 있는 상태에서
> 생성됐다. 배경 팀교착 알람이 `last(log)` 로 오분류돼(`:zone` 등) 생성기의 `:reform` 분기를
> 못 타는 바람에 **자가복구가 한 번도 안 돌았다**(알람 499회 → ReformTeam 제안 0건).
>
> 같은 seed·같은 설정에서 **shim 수정만** 하고 재실행한 결과:
>
> | 팔 | 수정 전 | 수정 후 |
> |---|---|---|
> | NOOP | 245/313, 미완주 | **291/313, 완주** |
> | RelocateBuild | 123/313, 미완주 | 147/313, 미완주 |
>
> **따라서 무효인 것**: §3-b 의 동점/결정적 n, §3-c 의 사다리 표, §3-d 의 "완주셀 0/24",
> §3-g 의 core zone 수치. 전부 재생성 대상이다.
>
> **여전히 유효한 것**: RelocateBuild 의 구현·배선·테스트(§1, §2), 엔진이 실제로 채택하고
> 평행이동한다는 사실(§3-a), 그리고 "ForbidZone 은 빌드 중반에 도메인이 비어 조용한 no-op 이
> 된다"는 §0 의 진단(이건 완주와 무관한 기하 사실이다).
>
> **결론이 바뀐 것**: §3-g 의 "harm 축이 없다"는 **유지되지만 근거가 바뀐다**. NOOP 이 안 죽어서가
> 아니라, core zone(R=0.321)이 로봇 반지름(0.14) 대비 너무 작아 **목표 점을 덮어도 실제 배달을 막지
> 못하기** 때문이다. 그리고 이 설정에서 RelocateBuild 는 명확히 손해다(291 완주 vs 147 미완주) —
> 반면 데모 설정에서는 정반대다(RB 완주, NOOP 정지). **설정 의존성이 매우 크므로 단일 설정의
> 결과를 일반화하면 안 된다.**
>
> 상세: `md/README.md` §6·§7 + `md/STATUS.md`(구 `PLAN_COMPLETION.md`, 2026-08-06 통합),
> 메모리 `constructionbots-shim-reform-misclassification`.

## 0. 왜 이걸 만들었나

zoneblk 사건의 결정적 표본이 **0** 이었다. `ForbidZone`(매크로 3)이 NOOP 과 바이트 단위로 같은
결과를 냈기 때문이다 — 36/36 동점, `[RESTAGE-ALL]` 한 번도 안 찍힘.

원인은 타이밍이 아니라 **전제조건의 소멸**이다. `ForbidZone` 의 실행부
`restage_all_blocked!` → `restage_assembly!` 는 *아직 build step 이 하나도 안 열린* 조립체만
옮길 수 있다(그 외에는 `:already_started` 로 거절). 그 집합을 빌드를 걸어가며 세면:

| closed | staging(root 제외) | 주입기 자격 | 수리기 자격(RESTAGEABLE) |
|---|---|---|---|
| 0 | 7 | 7 | 7 |
| 46 | 7 | 7 | **0** |
| 55 · 60 · 90 | 7 | 7 | **0** |
| 120 | 7 | 5 | **0** |

첫 배치 경계에서 전멸하고 **다시 돌아오지 않는다**. 그래서 창(window)을 어디로 옮겨도 해결되지
않는다 — 빌드 진행 자체가 전제조건을 파괴하기 때문이다.

`translate_whole_build!` 은 그 전제조건이 없다. 읽는 것이 `_future_work_discs`(아직 닫히지 않은
물리 목표 + non-root 적치 공간)이고, 이건 `closed_set` 으로만 걸러지지 `_assembly_started`
게이트가 없다(restage_zone.jl:520). 그래서 빌드 내내 비지 않는다. 이미 구현·검증돼 있었지만
`:residual_blocked` 일 때만 호출돼 **도달 불가**였다. 이번 작업은 그것을 1급 행동으로 노출한다.

## 1. 무엇을 바꿨나

| 파일 | 변경 |
|---|---|
| `src/respec/spec_dsl.jl` | `RelocateBuild(zone::Symbol)` — 2번째 공간형 spec. assembly 를 안 지목한다(전체가 움직이므로 grounding 자체가 없음) |
| `src/respec/verifier.jl` | `referenced_ids(::RelocateBuild) = ()` · `verify_relocate` (과거 노드 참조 금지 · zone 실존 · 옮길 적치원 존재) |
| `src/respec/replan.jl` | `_is_relocate_build` + dispatch 분기 → `translate_whole_build!`. **ForbidZone 분기보다 먼저** 검사(혼합 제안은 전제조건 없는 쪽을 써야 함) |
| `src/respec/compiler.jl` | `compile_constraint!(::RelocateBuild) = 0` (닫힌 합집합 계약 유지용 no-op) |
| `src/respec/llm_bridge.jl` | `"kind":"RelocateBuild"` JSON 분기 |
| `src/ConstructionBots.jl` | `RelocateBuild` export |
| `oracle/ood_mdp_shim.jl` | `_zone_arms()` 단일 출처. `valid_actions(:zone)` **[0,3] → [0,7]**, `canonical_action(:zone)=7`, `action_to_proposal(ctx,7)` |
| `oracle/gen_oracle_dataset.jl` | `ACTION_NAME[7]` · `MACRO_COST[7]=1.5` · `ep_macros(zoneblk)`→`_zone_arms()` · 주입기 자격 `DS_ZONE_ELIGIBLE` |
| `features_agnostic.py` | `MACRO_COST[7]` · `_ACTION_TABLE[7]` · `MACRO_SPECS[7]` · `_PRIMITIVE_TABLE["RelocateBuild"]` |
| `e1_analyze.py` / `export_surrogate.py` / `llm_producer.py` / `step3_loao.py` | `MACRO_COST[7]=1.5`, `MACRO_NAME[7]`, `MACROS`에 7 추가 |
| `verify.py` | `LLM_CANDIDATES["zone*"]` → `[0,7,3,1]`. 3 만 적어두면 **새 덤프에서 후보가 NOOP 하나로 쪼그라든다**(존재하는 팔만 걸러 쓰는 코드라서). 3·7 을 둘 다 남겨 옛/새 덤프 모두 동작 |
| `cost_eval.py` | `HEUR` 값을 단일 번호 → **선호 순서 리스트** (`zone*: [7,3]`). 단일 번호면 새 덤프에서 3 이 없어 `heuristic` 베이스라인이 조용히 `noop_always` 로 붕괴해 비교가 거짓말을 한다 |

### 1-a. 주입기 자격 필터를 arm 에 맞췄다 (`DS_ZONE_ELIGIBLE`)

주입기의 자격 검사는 **그 팔이 실제로 실행하는 것**과 일치해야 한다. 안 그러면 개입은 확정된
no-op 이고 그 instance 는 인위적으로 만들어낸 동점이다.

* `workdisc` (**기본**) — 매크로 7 에 맞춘 검사. 구역을 놓은 뒤 `_count_future_work_overlaps` 로
  **실제로** 미래 작업 원반을 덮는지 살아있는 기하로 확인하고, 안 덮으면 구역을 되돌리고 다음
  후보로 넘어간다.
* `restageable` — 매크로 3 에 맞춘 검사(`!_assembly_started`). 위 표대로 빌드 중반에는 자격자가
  0 이라 **사건이 아예 발화하지 않는다**. ForbidZone 시대 분석 재현용으로만 남긴다.
* `legacy` — 필터 없음(2026-08-03 이전 동작; `DS_ZONE_RESTAGEABLE=0` 이 여기로 매핑).

### 1-b. 비용

`MACRO_COST[7] = 1.5`. ForbidZone(조립체 하나 이동, 1.0)보다 비싸다 — 빌드 전체를 옮기는 전역
개입이기 때문. `a_scope=3`(전역), `a_reversible=0`(옮겨간 자리에서 빌드가 계속됨).
**네 곳**(`gen_oracle_dataset.jl` · `features_agnostic.py` · `e1_analyze.py` ·
`export_surrogate.py`)이 같은 값이어야 한다(README 함정 29). `test_relocate_build.jl` 이 대조한다.

## 2. 검증

### 2-a. 배선 단위검사 (시뮬레이션 없음, 수 초)

```
julia +lts --project=. wm4spacecraft_manufacturing/oracle/test_relocate_build.jl
```

DSL/dispatch/게이트/shim/비용표 5곳을 초 단위로 대조한다. **27/27 PASS.**
회귀 검사도 포함: fault `[0,1]`, battery mild `[0,2]` / deep `[0,1]`, reform `[0,4]` 불변.
`DS_ZONE_ARMS="0,3"` 으로 옛 동작 복원 가능.

### 2-b. 실행 경로 검사 (기하 env, 시뮬 없음)

```
julia +lts --project=. tools/tests.jl relocatebuild_parse
```

파싱만 보는 테스트는 ForbidZone 도 통과했었다(그게 조용한 no-op 이었던 이유). 그래서 이 테스트는
**실제 dispatch 를 타고**(`maybe_respecify!`) `:admitted` 를 받은 뒤 **기하가 진짜 움직였는지**
(모든 적치원 이동 + 구역 안 미래 목표 0개) 확인한다.

**11/11 PASS.** 구역이 미래 목표 26개를 덮은 상태 → dispatch `:admitted` → 적치원 8/8 이동 →
구역 안 남은 목표 **0개**.

### 2-c. 데이터 검증 — 동점이 깨지는가

```
powershell -File oracle\run_night_k1.ps1 -Seeds 301-320 -Lanes 2 `
    -Out oracle\out\rb_zone -RowsDone 2 -Episodes 1 -Kinds zoneblk
python rb_analyze.py "oracle/out/rb_zone/ep_s*.jsonl" --baseline "oracle/out/hz_k1/ep_s*.jsonl"
```

재는 것은 정확도가 아니라 **동점률**이다. 기준선(ForbidZone 시대, hz_k1): zoneblk 36 instance
전부 동점, 결정적 n = 0. 결과는 §3.

## 3. 결과 (2026-08-03 18:13–19:05, 트랙터 트윈, RVO+TangentBug ON, spare 3, 1사건/에피소드)

### 3-a. 엔진이 정말 채택했는가 — 그렇다

`DS_LOG=info` 로 돌린 진단 실행(`oracle/out/rb_diag/`, seed 301)의 원문:

```
[RESPEC] OOD event: A no-go exclusion zone has appeared at (0.39, 0.43) near a staging area
[RESPEC] LLM proposal: [RelocateBuild]  rationale: oracle macro 7
[RESPEC] whole-build relocation verified -> translate the entire build clear of the zone
[WHOLE-BUILD] translated Δ=[-1.615, -2.798] |Δ|=3.23 footprint(R=9.64); residual=0 -> translated
[RESPEC] whole-build translated Δ=[-1.615, -2.798] -> admitted
```

검증 통과 → 실제 평행이동 → **residual 0** → `:admitted`. 폴백(line-stop)이 아니다.
`[RESTAGE-ALL]` 은 한 번도 안 찍혔다(= 옛 경로를 안 탄다). 같은 seed·같은 팔이 `DS_LOG` 만
달라도 closed 132 로 동일 → 결정론 유지.

### 3-b. 동점이 깨졌는가 — **0% (8/8 결정적)**

| 데이터 | 팔 | instance | 동점 | 결정적 n |
|---|---|---|---|---|
| 기준선 `hz_k1` (ForbidZone 시대) | NOOP vs ForbidZone(3) | 36 | **36 (100%)** | **0** |
| 신규 (전 심각도 합, seed 301–304) | NOOP vs RelocateBuild(7) | 12 | **0 (0%)** | **12** |

`zone_overlap = 0.3123` 로 두 데이터의 구역 기하가 같고 `closed_at_fire` 도 58–62 로 같은
구간이다 — 세계를 바꾼 게 아니라 **팔을 바꾼 것**이 동점을 깼다.

### 3-c. 종류만 봐서는 못 푸는가 — **그렇다. 단, 심각도의 단조 함수는 아니다**

`offset` = 구역이 적치 중심에서 얼마나 비켜났나(0 = 정통으로 덮음, 클수록 가장자리).
표의 숫자는 `closed/313`, 굵은 쪽이 그 instance 의 정답.

| seed | offset 0.0 | offset 0.9 | offset 1.3 |
|---|---|---|---|
| 301 | 213 vs **229** → RelocateBuild | **213** vs 132 → NOOP | **213** vs 128 → NOOP |
| 302 | 240 vs **246** → RelocateBuild | **240** vs 111 → NOOP | **240** vs 111 → NOOP |
| 303 | **245** vs 145 → NOOP | **245** vs 140 → NOOP | **245** vs 140 → NOOP |
| 304 | **246** vs 232 → NOOP | 246 vs **282** → RelocateBuild | 246 vs **282** → RelocateBuild |

12/12 결정적, 정답 팔 RelocateBuild 4 : NOOP 8.

**읽는 법 — n=2 였을 때의 해석은 틀렸다.** seed 301·302 만 보면 "정통으로 덮으면 옮기는 게 이득,
비켜나면 손해"라는 깔끔한 이야기가 되지만, **seed 304 는 정확히 반대 방향으로 뒤집히고**
(0.0 에서 NOOP, 0.9·1.3 에서 RelocateBuild) **seed 303 은 아예 안 뒤집힌다**. 즉 정답은
offset 만의 단조 함수가 아니라 **(심각도, 그 판의 상태) 양쪽에 달려 있다**.

주장할 수 있는 것은 여기까지다: 정답이 zone 이라는 **종류 이름으로 결정되지 않는다**
(규칙표 "zone→항상 개입"과 "zone→항상 NOOP" 둘 다 12개 중 최소 4개를 틀린다).
주장할 수 없는 것: "심각도가 올라가면 개입이 유리해진다" 같은 방향성 — 데이터가 반증한다.

**offset 0.9 와 1.3 은 사실상 같은 조건이다.** NOOP 은 네 seed 모두 두 offset 에서 값이 동일하고
(213/240/245/246), RelocateBuild 도 302·303·304 는 완전히 동일(111/140/282), 301 만 132↔128 로
다르다. 구역이 이미 적치 중심을 벗어난 뒤로는 손잡이가 포화한다. 그래서 **독립적인 심각도
조건은 2개(0.0, ≥0.9)이고 독립 instance 는 8개**로 보는 것이 맞다 — 12 는 과대 계상이다.

### 3-d. 정직하게 남기는 한계

* **NOOP 의 결과가 심각도에 무반응이다.** seed 301 은 offset 0.0/0.9/1.3 어디서나 NOOP 이
  213/313 으로 **완전히 같다**(302 는 240). 즉 지금의 zone 은 *가만히 있는 쪽을 해치지 않는다*.
  그래서 이 종류가 재는 것은 "반응해야만 하는가(harm)"가 아니라 **"옮기는 것이 값을 하는가"**
  뿐이다. harm 축을 살리려면 구역이 NOOP 을 실제로 실패시켜야 하는데, 지금 생성 가드
  (`zone_clears_root_goals`)가 root 목표를 덮는 배치를 금지하고 있어 그럴 수 없다. 다음 수는
  이 가드를 심각도 손잡이로 바꾸는 것(root 목표를 덮되 RelocateBuild 로는 복구 가능한 구역).
* **완주셀 0/24.** 어떤 팔도 빌드를 끝내지 못한다 — 비교가 전부 "누가 더 늦게 죽나"다.
  §3-c 의 뒤집힘은 그 안에서도 유효하지만, 2층 분해(완주확률)는 여전히 퇴화 상태다.
* **n 이 작다.** 독립 instance 8개(seed 4 × 심각도 2). 부호검정 같은 통계는 아직 불가하고,
  여기서 주장하는 것은 통계가 아니라 **구조적 사실**(동점 100% → 0%, 정답이 종류로 안 정해짐)이다.
* **창이 [55,60] 이었다.** 의도한 [55,130] 대신 생성기 기본값 상한(60)으로 돌았다
  (`run_night_k1.ps1` 에 `-EpHi 130` 을 줬는데 자식 환경에 전달되지 않음 — 원인 미규명).
  결과적으로 기준선 `hz_k1` 의 zoneblk 발화 지점(58–62)과 더 정확히 겹쳐 비교에는 유리했다.
  재현 시에는 `DS_EP_HI` 를 직접 확인할 것.

### 3-e. 데이터 위치 · 재분석

| 폴더 | 설정 |
|---|---|
| `oracle/out/rb_zone/` | offset 0.9, seed 301–304, 팔 [0,7] |
| `oracle/out/rb_zf00/` | offset 0.0 |
| `oracle/out/rb_zf13/` | offset 1.3 |
| `oracle/out/rb_diag/` | offset 0.9, 팔 7 만, `DS_LOG=info`(엔진 로그 증거) |

```bash
python rb_analyze.py "oracle/out/rb_zf00/ep_s*.jsonl"     # 심각도별로 따로 본다
python rb_analyze.py "oracle/out/rb_zone/ep_s*.jsonl" --baseline "oracle/out/hz_k1/ep_s*.jsonl"
python rb_analyze.py "oracle/out/rb_diag/ep_s*.jsonl"      # 엔진 로그 카운트
```

폴더를 합치면 안 된다 — instance 이름(`ep_s301_M1_t1`)이 심각도와 무관해 충돌한다.
`run_rb_validate.ps1` 은 이미 행이 있는 job 을 건너뛰므로 **다시 돌리면 새 job 만** 돈다
(seed 303·304 의 offset 0.0/1.3 top-up 이 이 방식으로 추가됐다).

## 3-f. 후속: harm 축을 살리는 core zone (`:zonecore`, 같은 날 저녁)

§3-d 의 첫 번째 한계 — "NOOP 이 심각도에 무반응" — 를 직접 겨냥한 후속 작업.

### 무엇이 문제였나

옛 생성 가드 `zone_clears_root_goals` 는 **이진**이었다: root 의 하역 목표를 하나라도 덮는 구역은
금지. 그럴 수밖에 없었다 — 그때의 유일한 공간 복구가 `restage_all_blocked!` 였고 그건 root 를 못
옮기므로, 그런 구역은 복구 불가였다. 대가는 §3-d 의 그 숫자다: seed 301 이 offset 0.0/0.9/1.3
**전부에서 정확히 213/313**. 가만히 있는 쪽이 한 번도 벌을 안 받았다.

RelocateBuild 는 root 도 옮긴다. 그러므로 "root 목표를 덮는다"와 "복구 불가"가 더 이상 같은 말이
아니고, 가드를 **연속 손잡이**로 바꿀 수 있다.

    심각도 = 구역이 삼킨 root 하역 목표의 비율            (harm)
    가드   = 그걸 벗어나는 강체이동이 존재하는가          (recoverable)

### 구현 (`src/respec/restage_zone.jl`, 전부 신규 · 기존 함수는 그대로)

| 함수 | 역할 |
|---|---|
| `root_goal_coverage(center, r, env)` | 구역이 삼킨 root 목표 비율 = harm 심각도. **margin 기본 0(엄격)** — `_count_future_goals_in_zone` 과 같은 규칙(맨 반지름 안 = 도달 불가) |
| `zone_relocatable(center, r, env)` | **아직 등록하지 않은** 가상 구역에 대해 "빌드 전체 이동으로 벗어날 수 있나". 실행부와 **같은 솔버**(`_minimum_clear_translation`)를 쓰므로 통과한 구역은 구성적으로 복구 가능 |
| `core_zone_for_severity(env, frac)` | 중심=root 목표 무게중심, 반지름=k번째 목표를 막 품는 값(k=ceil(frac·N)). 복구 불가면 k 를 내림. 반환 `frac` 은 **실제** 커버리지 |

측정된 사다리(tractor, root 목표 8개, `tools/tests.jl corezone_guard` **8/8 PASS**):

```
frac 0.0 -> 1/8 삼킴 R=0.08      frac 0.6 -> 5/8 R=0.18
frac 0.2 -> 3/8      R=0.16      frac 0.8 -> 8/8 R=0.32
frac 0.4 -> 5/8      R=0.18      frac 1.0 -> 8/8 R=0.32
```

만드는 중 **두 번 틀렸고 둘 다 테스트가 잡았다**(둘 다 기록해 둘 가치가 있다):

1. **여유 중복 적용** — 반지름을 `d[k] + robot_radius` 로 잡고 커버리지도 `< r + robot_radius` 로
   판정해서, 사다리 모든 칸이 8/8 로 붕괴했다. `root_goal_coverage` 의 기본 margin 을 0 으로
   내리고 반지름 pad 를 1e-3 으로 바꿔 해결. **구현 결함**이었다.
2. **칸이 1,3,5,8 로 뭉침** — 이건 결함이 아니다. 트랙터가 좌우대칭이라 목표 거리에 동률이 있고
   (`[0.08, 0.16, 0.16, 0.179, 0.179, 0.24, 0.32, 0.32]`), 동률인 두 목표는 원 하나로 못 가른다.
   **테스트 기대값 쪽을 고쳤고** docstring 에 명시했다. 구현을 억지로 맞췄다면 기하를 거짓말하는
   코드가 됐을 것이다.

### 생성기 (`:zonecore`)

`:zoneblk` 는 비교 가능성을 위해 **그대로 두고** 별도 kind 로 추가했다. 핵심은
**`row_kind(:zonecore) == "zoneblk"`** — 저장소의 GRADED severity 원칙(해로운 변종과 무해한 변종은
컨트롤러가 보는 라벨이 같아야 kind one-hot 이 정답을 못 정한다)을 그대로 따른다. 대신 차이를
상태로 실어 나르는 새 열 **`zone_root_cover`** 를 덤프와 `e1_analyze.featurize` 에 추가했다
(`zone_overlap` 은 staging 원 겹침이라 중앙 코어 구역에서는 0 으로 보일 수 있다 — 이 열이 없으면
두 변종이 상태로 구별되지 않아 과제가 trivial 이 아니라 **학습 불가**가 된다).
심각도 환경변수는 `DS_EP_CFRAC`.

### 데모

`julia tools/demos.jl respec_relocatebuild` (신규). `respec_forbidzone` 과 두 가지가 다르다:
mock LLM 이 `RelocateBuild` 를 직접 내므로 **2단계 폴백 없이 한 번에** 복구하고, 구역 반지름을 상수로
박지 않고 `CORE_FRAC` 심각도로 고른다(`core_zone_for_severity`, 복구 불가로 판정되면 아무것도 주입하지
않는다 — 데모가 못 고치는 사건을 보여주면 안 되므로). ENV: `CORE_FRAC`, `OOD_STEP`, `USE_MOCK`, ...

### 검증 상태

* `tools/tests.jl corezone_guard` **8/8 PASS** (사다리 단조 · 동률 고려 기대값 일치 · 전부
  relocatable · 꼭대기가 옛 이진 가드를 실제로 위반)
* `tools/tests.jl relocatebuild_parse` **11/11 PASS** (기하 변경 후 회귀 없음)
* `oracle/test_relocate_build.jl` **36/36 PASS**
* **harm 실측은 진행 중** — `oracle/out/rb_core/`, seed 301·302, `DS_EP_CFRAC=1.0`(root 목표 8/8
  삼킴), 팔 [0,7], `DS_LOG=info`. 주입은 확인됨(`covering 8 of the 8 final-assembly delivery
  points`). 중간 관측: seed 301 의 NOOP 팔이 closed 82 부근 — 옛 무해 구역에서의 213 보다 크게
  낮다. **확정 수치는 아래 §3-g 에 채운다.**

## 3-g. core zone harm 실측 — **harm 축은 생기지 않았다(부정 결과)**

`oracle/out/rb_core/`, seed 301·302, `DS_EP_CFRAC=1.0`, 팔 [0,7], 창 [55,60].
주입은 의도대로 됐다: 로그에 `covering 8 of the 8 final-assembly delivery points`,
덤프에 `zone_root_cover = 1.0`, `kind = "zoneblk"`(설계대로 라벨 공유).

| seed | NOOP | RelocateBuild | 정답 | 참고: 옛 무해 구역의 NOOP |
|---|---|---|---|---|
| 301 | **245**/313 | 123/313 | NOOP | 213 |
| 302 | 240/313 | **270**/313 | RelocateBuild | 240 |

**root 하역 목표를 8/8 전부 삼켰는데도 NOOP 이 벌을 안 받았다.** seed 302 는 240 으로 옛 무해
구역과 **완전히 동일**하고, seed 301 은 오히려 213 → 245 로 **올라갔다**.

**진단.** 이 창에서는 do-nothing 런이 root 의 최종 하역 근처에 **애초에 도달하지 못한다**.
NOOP 은 구역과 무관하게 240~246/313 부근에서 운반팀 형성 교착으로 죽는다(§3-c 의 옛 데이터에서도
NOOP 은 213/240/245/246 이었다). root 의 `LiftIntoPlace` 노드들은 그보다 한참 하류라 한 번도
시도되지 않고, 따라서 그걸 막아도 관측 가능한 비용이 0 이다. 즉 **엔드게임을 막는 harm 은
엔드게임에 도달하는 런에서만 보인다.**

**정정.** 실행 중간에 seed 301 의 NOOP 이 closed 82 인 것을 보고 "harm 신호가 나타나고 있다"고
적었는데, 그건 진행 중 샘플이었고 최종값은 245 다. 그 관찰은 증거가 아니었다.

**그래서 무엇이 잘못됐나 — 가드가 아니라 표적이다.** `core_zone_for_severity` 는 설계대로 동작한다
(사다리 8/8 PASS, 복구 가능성 구성적 보장, 옛 이진 가드가 막던 영역을 실제로 연다). 틀린 것은
"root 하역 목표 = harm 의 자리"라는 **가정**이다. root 목표는 이 실험 구간에서 죽은 코드나 마찬가지다.

**다음 수(설계만, 미구현).** 심각도를 *root* 목표 커버리지가 아니라 **임박한 작업 목표**
커버리지로 바꾼다 — `_future_goal_discs` 중 지금 frontier/active 에 걸린 것들. 그것들은 NOOP 런이
곧 실제로 가려는 자리라 막으면 즉시 비용이 난다. `zone_relocatable` 가드와 사다리 구성 방식은 그대로
재사용할 수 있고, 바뀌는 것은 거리 정렬의 기준점(무게중심 → 임박 목표 집합)뿐이다.
단, 그렇게 하면 §3-d 의 두 번째 한계(완주셀 0)와 정면으로 만난다: 완주하는 세계를 먼저 만들지
못하면 harm 은 "완주 실패"가 아니라 "조금 더 일찍 죽음"으로만 나타난다.

## 4. 남겨둔 것 (의도적으로 안 건드림)

* **`src/navigator/baselines.jl` 의 `canonical_respec(::ZoneTruth)` 는 여전히 `ForbidZone` 을 낸다.**
  이건 데모용 규칙 producer이자 **LLM grounding 채점의 정답 기준**(`llm_eval.jl` 이 `:ForbidZone`
  과 대조)이다. 지금 바꾸면 별개 실험(LLM 접지 평가)의 숫자가 조용히 바뀐다. 오라클 쪽
  `canonical_action(:zone)=7` 과 어긋나 있다는 것을 알고 남긴다 — 배포 정책을 7 로 옮길 때
  `llm_eval` 기준도 같이 옮겨야 한다.
* **`export_surrogate.add_interactions` 의 `for m in range(5)`** — 선형 export 의 교차항이
  매크로 0~4 만 만든다. 매크로 7 은 교차항 없이 주효과만 갖는다. 배포 모델은 forest 가 기본이라
  당장 영향은 없지만, 선형 export 를 zone 사건에 쓰려면 이 범위를 넓혀야 한다(이름 규칙이
  Julia 데모의 feature 조립기와 맞물려 있어 양쪽 동시 변경 필요).
* **`e1_analyze.MACROS` 에 7 을 넣어 `macro_7` one-hot 열이 하나 늘었다.** 옛 덤프에서는 전부 0 인
  비활성 열이라 결정에는 영향이 없지만, φ 차원이 41 → 42 로 바뀌므로 옛 리포트의 열 수와는
  다르다.
