# 구역(zone) 결정 재설계 — STEP 1~11 구현·검증 기록 (2026-08-05)

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


> 구성: **STEP 1~7**(본문) → **부록 A/B/C**(막힘을 결정 경로에 배선, MILP 비결정성) →
> **STEP 8~11**(맨 끝, 커버리지 → 막힘). 파일명은 코드 주석이 참조하므로 그대로 둔다.

계획 원문은 7단계였고 **STEP 0(어휘 구멍)과 STEP 5(게이트)는 이미 완료**된 상태에서 시작했다.
이 문서는 그 다음, 즉 **STEP 1 → 2 → 3 → 4 → 7** 의 코드 변경과 그 검증을 기록한다.
STEP 6(라벨 재생성 + 검정)은 계산 시간이 긴 데이터 작업이라 별도 절에 상태만 적는다.

전체 원칙 한 줄:

> 구역이 **씬트리의 무엇을 무효화하는가**를 한 곳에서 계산하고(STEP 1),
> 그 위에 **최소수복 규칙**을 세워 오라클 라벨과 게이트로만 쓰고(STEP 2),
> 정책에게는 **판정이 아니라 원시값**을 준다(STEP 3·4).

---

## 0. 선행 확인 — mock_replace 회귀 (중단됐던 것 재개)

`replace_robot.jl` 의 팀 탐지(`_form_unit_after`) 수정 뒤 확인이 중단돼 있던 e2e 를 다시 돌렸다.

```
julia +lts --project=. tools/e2e.jl mock_replace
```

```
==== RESULT (mock e2e ReplaceAgent seam) ====
closed 0 -> 287 (peak 287)/305  status=complete  respec_verdict=admitted
  PASS: respec seam fired with :admitted (NL->ReplaceAgent->dispatch->replace_robot!)
  PASS: no RVO/identity assert (faulted robot didn't crash the sim)
  PASS: hand-off made progress past the fault point
  PASS: a spare was consumed from a pool
==== mock e2e ReplaceAgent: 4 passed, 0 failed ====
```

`ProjectComplete` 노드까지 닫혔고 4/4 PASS. **팀 탐지 수정이 spare-Replace 경로를 깨지 않았다.**

---

## 1. STEP 1 — 위반 술어 계산기

### 바꾼 것

| 파일 | 내용 |
|---|---|
| `src/respec/zone_diagnosis.jl` | (기존 작성분) `zone_diagnosis` 를 모듈에 **배선**. `feasible` (옮길 수 있는 조립체 **id 목록**) 반환 추가 |
| `src/respec/zone_diagnosis.jl` | **신규 술어** `zone_team_coverage` — 형성 중인 운반팀의 집결지/운반슬롯을 구역이 덮는가 |
| `src/respec/respec.jl` | `include("zone_diagnosis.jl")` |
| `src/ConstructionBots.jl` | `zone_diagnosis, zone_diagnoses, zone_team_coverage` export |

계획이 "유일하게 새로 써야 하는 것"으로 지목했던 `slots_covered` 가 이 팀 술어다. 슬롯 좌표는
`reform_stuck_teams!` 이 실제로 snap 하는 그 변환(`global_transform(tu) ∘ child_transform(tu, mid)`)을
그대로 쓴다 — 즉 "덮였다"는 곧 "이 구역이 강요하는 snap 은 `recover_stalled_teams!` 이 거부하는 그 snap 이다".

### 왜 이 술어가 필요했나 (거짓 `:noop` 의 정체)

이미 **시작된** 조립체는 `blocked` 에 안 잡힌다. 그래서 그 집결지를 덮은 구역은
`n_blocked=0 · root_covered=0` 이 되어 옛 규칙이 `:noop`(절제)이라 답했다 — 빌드는 실제로 끼어 있는데도.
이것이 doc 2 에서 "corridor/clearance 사각지대"로 지목했던 바로 그 구멍이다.

### ★ 팀 술어는 `ReformTeam` 분기가 **아니다**

`ReformTeam` 은 슬롯으로 로봇을 순간이동시키는데, `recover_stalled_teams!` 2단계가
**"집결지가 no-go zone 안이면 snap 금지 → restage/translate"** 라고 이미 못박아 두었다
(`src/respec/replace_robot.jl:611-625`). 그러므로 덮인 팀의 수복은 **공간형 팔**이다.
계획서의 "팀 슬롯 위반 → ReformTeam" 은 이 지점에서 **정정**된다.

### 검증

```
julia +lts --project=. tools/tests.jl zone_diagnosis      # 신규 테스트
```

```
==== zone_diagnosis predicates: 42 passed, 0 failed ====   ALL GREEN
```

같은 파일의 기존 구역 테스트 2개도 함께 돌려 회귀가 없음을 확인했다:

```
tools/tests.jl forbidzone_parse     ==== 15 passed, 0 failed ====  ALL GREEN
tools/tests.jl relocatebuild_parse  ==== 11 passed, 0 failed ====  ALL GREEN
   (후자는 dispatch 까지 실행: 적치원 8/8 이동, 구역 안 남은 목표 0개)
```

검사 항목:

1. 등록 안 된 구역 → `:no_such_zone`, throw 없음
2. 아무것도 안 덮는 먼 구역 → `:noop` + 원시값 전부 0
3. 중앙 구역 → 원시값이 **기존 헬퍼들과 일치**
   (`zone_domain_size` / `root_goal_coverage` / `_count_future_work_overlaps` / `_find_min_translation`)
4. **기하 격자(반지름 4 × 거리 4)** 에서 모든 표본이 규칙과 일관 + 분기를 실제로 넘김

```
    r=2.5 @center: blocked=7/feasible=7 root=8/8 teams=0/0 |Δ|=5.849 -> forbid_zone
    d=5.0  @r=2.5: blocked=2/feasible=2 root=0/8 teams=0/0 |Δ|=1.951 -> forbid_zone
    d=10.0 @r=2.5: blocked=0/feasible=0 root=0/8 teams=0/0 |Δ|=1.403 -> noop
    d=100.0 @r=2.5: blocked=0/feasible=0 root=0/8 teams=0/0 |Δ|=0.0   -> noop
  PASS: 격자가 최소 2개의 서로 다른 분기를 지난다 (got forbid_zone, noop)
```

5. `check_restage=false` 는 정확값의 **상계**
6. 팀 술어가 팀이 없을 때 완전히 무해 + `check_teams=false` 면 옛 규칙과 라벨 동일
7. `RELOCATE_GATE` 가 진단과 같은 결론을 내는가(아래 STEP 2 참조)

### 팀 술어의 **결정적** 검증 — 진짜로 형성 중인 팀 위에서

시뮬 전 env 로는 "팀이 없을 때 무해하다"까지밖에 못 본다. 그건 검증이 아니라 희망이다.
그래서 시뮬을 실제로 굴려 팀이 형성되는 순간까지 간 다음, **그 집결지에 구역을 심고** 잰다.

```
julia +lts --project=. tools/tests.jl zone_team_predicate      # 신규 테스트
```

```
[1] 형성 중인 운반팀이 생길 때까지 진행
    -> 2 forming team(s) after 25 steps (closed 65/289)
    대상 팀: ready=1 missing=1 gather=[1.302, -3.178]

[2] zone_team_coverage — 집결지 위 / 멀리
    집결지 위: covered=1/2  슬롯 2/2        <- 운반 슬롯 2개가 전부 구역 안
  PASS: 집결지를 덮으면 그 팀이 covered
  PASS: 멀리 심으면 아무 팀도 covered 아님

[3] 같은 구역에서 옛 규칙 vs 새 규칙
    blocked=0/feasible=0 root=0/8 teams=1/2 reloc=true |Δ|=1.17
    옛 규칙 -> noop   /   새 규칙 -> relocate_build
  PASS: 옛 규칙은 :noop (거짓 절제)
  PASS: 새 규칙은 개입으로 뒤집힘

==== team-slot predicate: 8 passed, 0 failed ====   ALL GREEN
```

**이것이 이 술어의 존재 증명이다**: `blocked=0 · root=0/8` 이라 기존 세 술어는 전부 "위반 없음"이라
말하는데, 팀의 운반 슬롯 2개가 구역 안에 있어 그 팀은 제자리에서 절대 못 모인다.
옛 규칙은 그 상태를 `:noop`(절제) 이라 불렀다 — 그게 doc 2 가 지목한 **거짓 `:noop`** 이다.

### 정직한 한계

- 시뮬 전 env 에서는 도메인이 절대 비지 않아 `:relocate_build` / `:line_stop` 분기가
  구조상 도달 불가다(위 팀 테스트는 시뮬을 굴려 그 제약을 우회한다).
- `:line_stop` 은 여전히 어느 테스트에서도 안 밟힌다 — 이유는 STEP 7 절에 적었다(무한 작업공간).

---

## 2. STEP 2 — 최소수복 결정규칙 = 오라클 + 게이트

### 규칙 (비용 사전순)

```
n_restage_feasible > 0                          -> :forbid_zone     (국소, 비용 1.0)
root_covered > 0  ∨  n_teams_covered > 0        -> :relocate_build  (전역, 비용 1.5) | :line_stop
그 외                                            -> :noop            (비용 0)
```

`:forbid_zone` 이 root 를 덮은 경우에도 우선인 이유: `restage_all_blocked!` 이 `:residual_blocked` 를
돌려주면 `maybe_respecify!` 가 알아서 전역 이동으로 **자동 격상**한다. 반대로 도메인이 비면 그 격상이
도달 불가(`:none` 조기 반환)라 전역을 **직접** 골라야 한다.

### 바꾼 것 (라벨 쪽)

| 파일 | 내용 |
|---|---|
| `oracle/ood_mdp_shim.jl` | `event_context` 가 zone 사건에 **진단 스칼라**(`ctx.zdiag`)를 붙임 (`DS_ZONE_DIAG=0` 이면 옛 동작) |
| 〃 | `valid_actions(:zone)` 이 **결정 시점의 기하**로 정해짐: 옮길 수 있을 때만 3, 벗어날 Δ 가 있을 때만 7, 둘 다 불가면 `[0]` |
| 〃 | `canonical_action(:zone)` = 최소수복 verdict (옛 "무조건 RelocateBuild" 를 뒤집음) |
| 〃 | `action_to_proposal(·,3)` 이 `ZoneTruth` 에 assembly 가 없어도 **진단이 고른 대상**으로 grounding |
| `oracle/gen_oracle_dataset.jl` | 롤아웃 후보 목록과 per-decision valid 의 **역할 차이**를 주석으로 명시 |

`[0]` 만 남는 경우(= 닫힌 어휘에 수복이 없음)를 만든 이유: 행동할 수 없는 팔을 끼워 넣는 것은
결정을 재는 게 아니라 **동점을 제조**하는 것이다. (`zoneblk 36/36 동점` 의 원인이 정확히 그것이었다.)

### 바꾼 것 (게이트 쪽)

`src/respec/verifier.jl` 의 `RELOCATE_GATE`(비례성) 이 root 커버리지만 보던 것을
`zone_diagnosis` 로 교체 — **게이트와 라벨이 같은 계산기를 읽는다**. 이걸 안 하면 새 술어에서
"규칙은 옮기라는데 게이트가 막는" 조용한 불일치가 난다.

거절 조건: `root_covered == 0 ∧ n_teams_covered == 0` (기존보다 **좁아진** 조건 = 과잉 거절만 줄었다).

### 검증

```
julia +lts --project=. wm4spacecraft_manufacturing/oracle/test_relocate_build.jl
```

```
== 4b. STEP 2: 최소수복 규칙이 zone 의 팔/기준정책을 정하는가 ==
  PASS  noop: 팔 == [0,7] (옮길 게 없으니 3 은 빠진다)
  PASS  noop: canonical == 0 (옛 '무조건 개입' 을 뒤집음)
  PASS  forbid_zone: 팔 == [0,3,7]
  PASS  forbid_zone: canonical == 3
  PASS  assembly=nothing 이어도 3 이 제안을 만든다(진단이 대상을 준다)
  PASS  그 제안이 ForbidZone(대상=진단이 고른 조립체)
  PASS  relocate_build: 팔 == [0,7] / canonical == 7
  PASS  팀 갇힘: canonical == 7 (ReformTeam 아님)
  PASS  line_stop: 팔 == [0] / canonical == 0
  PASS  DS_ZONE_ARMS 가 진단을 이긴다
...
ALL PASS — RelocateBuild 배선 정상
```

덤으로, 같은 파일에서 **낡아서 계속 실패하던 기대값 2개**를 고쳤다(코드가 아니라 기대값이 낡음):
`battery` 팔은 SwapBattery(8) 도입 후 `[0,1,8]`/`[0,2,8]` 이다.

### 정직한 한계

- `canonical_action(:zone)` 이 바뀌었으므로 **새로 생성되는 라벨의 배경 정책이 달라진다**.
  옛 덤프 재현은 `DS_ZONE_DIAG=0` 또는 `DS_ZONE_ARMS` 로 한다.
- 롤아웃 후보(`ep_macros`)는 판을 돌리기 전에 정해지므로 여전히 `[0,7]` 이다.
  3(ForbidZone) 라벨을 얻으려면 STEP 6 에서 `DS_EP_MACROS="0,3,7"` 로 넓혀야 한다.

---

## 3. STEP 3 — 관측 어휘: 판정이 아니라 원시값

### 바꾼 것

- `oracle/gen_oracle_dataset.jl::capture_features` 가 진단 원시값 7열을 행에 싣는다:
  `zone_blocked · zone_restage_feasible · zone_work_overlap · zone_teams_forming ·
   zone_teams_covered · zone_relocatable · zone_relocate_norm`
  (zone 사건이 아니면 전부 `-1` — 기존 `zone_overlap` 의 sentinel 관례와 동일)
- `features_agnostic.py` 에 `ZONE_PRIMITIVES` / `zone_primitives_from_row` /
  `featurize_agnostic(..., include_zone_primitives=False)` 추가.

**`verdict` 는 싣지 않는다.** 그건 정답이므로 오라클·게이트의 것이고, 행에 실으면 정책이
추론이 아니라 답을 베끼게 된다.

기본이 **꺼짐**인 이유: 열을 넣으면 특징 차원이 바뀌어 이미 export 된 서로게이트·novelty 교정과
호환되지 않는다. 옛 덤프에는 열 자체가 없어 `-1`(=모름)로 채워진다.

### 검증

```
python -c "... featurize_agnostic(df) vs featurize_agnostic(df, include_zone_primitives=True) ..."
```

```
default cols : ['harm','work_at_risk','resource_loss','recovery_capacity','progress','slack',
                'macro_0','macro_1','macro_2','macro_3','macro_4','macro_7','macro_8','macro_in_valid']
opt-in adds  : ['zone_blocked','zone_restage_feasible','zone_work_overlap',
                'zone_teams_forming','zone_teams_covered','zone_relocatable','zone_relocate_norm']
default unchanged: True
missing-col row -> -1 sentinel OK: True
```

기본 특징행렬이 **열 목록까지 동일** = 배포 모델 호환. 옛 행(열 없음)도 안전하게 읽힌다.

### 라이브 경로에도 같은 원시값을 준다

오프라인 덤프만 고치면 데모는 여전히 `zone_overlap` 하나만 보고 답한다. 그래서 세 곳을 함께 배선했다:

| 파일 | 내용 |
|---|---|
| `tools/monitor/policy.jl::ood_features` | zone 사건에 원시값 9개를 실음(진단기와 같은 계산) |
| `src/respec/llm_service/dspy_service.py::MacroRequest` | 그 필드를 받는 **선택적** 스키마 항목 |
| 〃 `_geometry_block` | `MEASURED GEOMETRY` 블록으로 렌더링. 필드가 하나도 없으면 **빈 문자열** = 기존 입력과 동일 |

렌더링 검증:

```
MEASURED GEOMETRY (what this zone actually covers, measured directly; no interpretation applied):
  zone_blocked           = 2      (sub-assemblies whose staging area the zone covers AND that have not started building)
    of which movable     = 1      (of those, how many have a zone-clear spot to be restaged into)
  root_goals_trapped     = 8      (delivery goals of the ROOT assembly inside the zone; the root cannot be restaged)
  work_discs_overlapped  = 35     (unfinished work areas the zone intersects)
  teams_forming          = 1      (transport teams currently gathering)
    of which trapped     = 1      (of those, how many must gather inside the zone ...)
  min_shift_to_clear_m   = 5.85   (smallest rigid translation ... -1 means no such shift exists)
OK: 필드 없으면 기존 입력과 동일 / 판정·액션이름 누출 없음
```

설명문은 **사실만** 적고 "그러니 무엇을 하라"는 한 줄도 없다 — 그게 STEP 4 가 지운 결정표다.

### 남은 것 / 정직한 한계

- 계획이 말한 "도구 호출로 노출"(can_restage / min_translation / clear_center)은 하지 않았다.
  왕복 지연이 surrogate(0.11 ms) 대비 크고, 지금은 필드로 주되 **그 사실을 실험 조건으로 명시**하는
  타협을 택했다(계획서가 열어둔 선택지 중 후자).
- 긴장 하나를 정직하게 적어 둔다: 이 파일(`dspy_service._llm_input`)의 원래 논지는 "파싱된 필드를
  주는 것 자체가 이미 분류를 전제한다"였다. 기하 원시값도 **공간 사건에만 존재**하므로 그 긴장을
  완전히 벗어나지 못한다. 진짜 미지 사건에는 이 블록이 통째로 없고, 그 경계가 곧 STEP 7 의
  에스컬레이션 지점이다.

---

## 4. STEP 4 — 프롬프트는 결정표가 아니라 원리로

### 바꾼 것

`src/respec/llm_service/dspy_service.py` 의 `SEED_DOC` 마지막 두 문장(= 결정 규칙 그 자체)을 삭제하고
**원리 한 줄**로 교체:

```
THE PRINCIPLE: choose the CHEAPEST action that resolves every constraint the event actually
violates. If the event violates nothing the schedule still needs, NOOP is not a cop-out -- it is
the correct answer, and intervening spends a resource for nothing. Decide which constraints are
violated from the state you are given; do not assume an event of a given type always violates
something.
```

지운 문장: *"On a zone event the real question is whether moving the whole build buys back more than
the disruption it causes — a zone that only clips the edge of a staging area usually does not."*

근거는 같은 파일에 이미 있던 실측이다(`_IMPERATIVE` 주석): 서술자가 `harm=0.02` 인데도
"restage 하라"는 **지시문을 따라** ForbidZone 을 골랐다. 규칙을 산문으로 주면 측정되는 것은
추론이 아니라 **프롬프트 준수**다.

### 검증

```
python -c "ast.parse(dspy_service.py) ; print SEED_DOC tail"
```

파싱 OK + 새 원리 문단이 실제로 프롬프트에 들어갔음을 출력으로 확인.
각 액션이 "무엇을 해소하는가"(전제조건 포함)는 그대로 남겨 두었다 — 그건 어휘 설명이지 결정표가 아니다.

### 계획서와 달라진 판단 — `VALID["zone"]` 은 넓히지 않았다

계획서 STEP 0 은 `dspy_service.py` 의 정적 표를 `[NOOP, ForbidZone, RelocateBuild, ReformTeam]` 로
넓히라고 했다. 그렇게 하지 않았고, 이유는 그 표의 **역할**이다:

- 그 표는 **상태를 모르는 호출자를 위한 폴백**이다(같은 파일 주석). ForbidZone 은 전제조건이 있는
  팔이라 상태 없이 "언제나 합법"이라고 두면 그 자체가 틀린 말이 된다.
- 상태를 아는 호출자(`policy.jl::valid_macros`)는 이미 `valid` 를 실어 보내고 **그게 우선**한다.
  STEP 7 에서 그 계산을 진단기 기반으로 고쳤으므로, 실제 라이브 경로의 zone 어휘는
  `[NOOP, ForbidZone, RelocateBuild]` 가 된다 — 표를 안 건드려도 목적은 달성된다.
- `ReformTeam` 은 zone 메뉴에 넣지 않는다. STEP 1 에서 확인했듯 집결지가 금지구역이면 snap 은
  `recover_stalled_teams!` 이 거부하므로, 그 팔은 zone 사건에서 **실행될 수 없는 선택지**다.

`schema.py` 의 union/enum 에는 `RelocateBuild` 가 이미 들어가 있다(STEP 0 완료분, L101/191/234) —
확인만 하고 그대로 두었다.

---

## 5. STEP 7 — 라우터: 표현력 에스컬레이션

### 바꾼 것 (`tools/monitor/policy.jl`)

1. **`valid_macros`**: 구역이 assembly 를 지목하지 않아도 **기하가 대상을 알고 있으면**
   (`n_restage_feasible > 0`) ForbidZone 을 메뉴에 넣는다.
   옛 판정("지목 없으면 grounding 할 대상이 없다")은 틀렸다 — `proposal_for_macro` 가 이미
   `zone_blocked_assemblies` 에서 대상을 채운다. 대상이 실재하는데 메뉴에서 빠지면 정책은
   **고를 수조차 없다**. (도메인이 비었다고 팔을 *지우지는* 않는다 — 그건 실측으로 접은 결정.)
2. **`decide_all` 에 3번째 에스컬레이션 조건 추가**: 진단이 `:line_stop` 이면
   (= 위반은 실재하는데 ForbidZone 도 RelocateBuild 도 못 치움) novelty 와 무관하게 LLM 으로 올린다.
   기존 두 조건은 (a) 상태가 낯설다(novelty), (b) 그 매크로를 학습한 적이 없다(액션 지원).
   세 번째는 **어휘 자체에 수복이 없다**이다.

### ★ 정직한 한계 — 이 게이트는 지금 **거의 잠들어 있다**

작업공간이 무한하고 구역이 유한한 원판이므로 `_minimum_clear_translation` 은 사실상 **항상**
벗어날 Δ 를 찾는다(실측: 위 격자 8표본 전부 `relocate_feasible=true`). 따라서 `:line_stop` 은
현재 기하로는 거의 도달 불가이고, 이 조건은 **설치됐지만 발화 조건이 드물다**.

지금 실제로 도달 가능한 "수복 없음" 은 **통로 봉쇄**다: `Δ` 는 목표 디스크가 구역 밖인 것만 보장하고
**경로**는 보장하지 않는다(doc 2 에서 로봇이 rim 에서 livelock 한 그 케이스). 그걸 잡으려면
corridor/clearance 술어가 새로 필요하고, 그건 새 기하라 이번 범위 밖이다. → **후속 작업으로 명시**.

### 검증

- **신규** `tools/test_policy_zone.jl` — **19/19 ALL GREEN**. 서비스도 렌더도 없이 policy.jl 의 결정 함수만 대조한다.

```
    도메인: :zone -> 7 개 옮길 수 있음 / :faraway -> 0 개
    named   -> ["NOOP", "ForbidZone", "RelocateBuild"]
    unnamed -> ["NOOP", "ForbidZone", "RelocateBuild"]   <- 이번 수정(지목 없어도 legal)
    faraway -> ["NOOP", "RelocateBuild"]
    -> blocked=7 feasible=7 root=8/8 teams=0/0 reloc=true |Δ|=5.849
  [PASS] 판정(verdict)이 특징에 새지 않는다  -- leaked=String[]
  [PASS] fault 사건에는 zone 원시값이 없다
```

  이 레이어는 "데모를 띄워야 도는" 코드라 지금까지 손대고도 아무도 안 돌려봤고, 그 방식으로
  회귀가 두 번 났다(2026-08-04 `:reform` 오분류, 2026-08-05 zone 어휘). 검사 내용:
  (a) 지목 없어도 도메인이 있으면 `ForbidZone` 이 메뉴에 있는가,
  (b) `ood_features` 가 원시값을 싣고 **판정은 안 싣는가**(누출 검사),
  (c) 비공간 사건에는 원시값이 안 붙는가.
- `tools/tests.jl zone_diagnosis` 의 `[7]` 절이 `RELOCATE_GATE`↔진단 일치를 확인한다(4/4 PASS).
- 변경한 Julia 파일 8개 전부 **파스 클린**(`Meta.parseall` 로 `:error`/`:incomplete` 노드 검사):
  `zone_diagnosis.jl · verifier.jl · respec.jl · ConstructionBots.jl · policy.jl · tests.jl ·
   ood_mdp_shim.jl · gen_oracle_dataset.jl · test_relocate_build.jl`
- `policy.jl` 은 시뮬레이터·LLM 서비스가 함께 떠야 도는 경로라, 여기까지가 코드 수준 검증이다.
  라이브 데모(`tools/monitor/render_demo.jl`)에서의 실행 확인은 **아직 안 했다**.

---

## 6. STEP 6 — 라벨 재생성 + 검정 (상태: **완료, 8/8 job · 66.6 분**)

### 러너

`oracle/run_step6_zonegrid.ps1` (신규). 기존 `run_rb_validate.ps1` 과 **같은 세계 설정**을 쓰되
두 가지를 바꿨다:

| 축 | 값 | 왜 |
|---|---|---|
| 팔 | `DS_EP_MACROS="0,3,7"` | 3(ForbidZone)까지 굴려야 그 가지의 라벨이 생긴다. 기존 러너는 `[0,7]` 이라 그 가지가 **표집 자체가 안 됐다** |
| 발화 시점 | early `closed∈[10,16]` / late `[55,60]` | 국소 재적치 도메인은 첫 배치 경계 이후 비므로, 시점이 가지를 가른다 |
| 구역 위치 | `DS_EP_ZFRAC ∈ {0.0, 1.3}` | 적치 중심 위 / 가장자리만 스침 |
| seed | 301, 302 | |

= 8 job × 3 팔 = 24 판. `DS_ZONE_DIAG=1`(진단 배선 ON), 2 lane, 재개 안전.

```
powershell -File oracle\run_step6_zonegrid.ps1 -Lanes 2 -MaxMinutes 145
-> oracle\out\zgrid_0805\ep_<tag>.jsonl
```

### 채점기

`step6_zonegrid_report.py` (신규). 계획서의 세 기준을 그대로 잰다.

**L1 valid 게이트를 채점 전에 건다.** 첫 데이터가 바로 그 필요성을 보여줬다: 도메인이 빈 시점에
굴린 ForbidZone(3) 행은 `closed=291` 로 NOOP 과 **완전히 동일**하다(실행부가 접어 NOOP 팔이 됨).
그걸 후보로 세면 동점률이 0% → 100% 로 튄다. 그래서 `macro ∈ valid_mask` 행만 채점하고,
**몇 행을 걸렀는지 반드시 출력**한다(조용히 버리면 그것도 같은 종류의 거짓말이다).

**가지는 예측하지 않고 사후 분류한다.** 행에 STEP 3 원시값이 실리므로, 각 instance 가 실제로 어느
가지였는지 데이터가 말해 준다 — 격자 설계가 빗나가도 결론은 정직하게 남는다.

기존 덤프(`out/rb_zf00/*.jsonl`)로 채점기 자체를 먼저 검증했다:

```
[data] 8 file(s), 184 rows, 4 instance(s), macros=[0, 7]
[schema] STEP3 원시값 열 0/5 존재: []        <- 옛 덤프에는 없다(정상)
H(best|zone) = 1.000 bits  PASS   동점률 0.0%  PASS
always NOOP          mean subopt_norm= 5.50 (max 16)
always RelocateBuild mean subopt_norm=28.50 (max 100)
```

즉 **옛 데이터에서도 "항상 개입" 이 평균 28.5 노드를 잃는다**. STEP 2 가 canonical 을
"무조건 RelocateBuild" 에서 최소수복 규칙으로 바꾼 근거가 이 숫자다.

### 첫 행이 나온 시점의 확인 (18:30, `ep_early_zf00_s301` 1행)

```
zone_overlap=0.64  zone_root_cover=1.0  zone_radius=0.565
zone_blocked=0     zone_restage_feasible=0        <- 도메인 비었음
zone_work_overlap=16
zone_teams_forming=7  zone_teams_covered=0        <- 팀 술어가 실제로 돌고 있다(7팀 형성 중)
zone_relocatable=1    zone_relocate_norm=4.141
macro=0  valid_mask=[0,7]  closed_at_fire=58  complete=true  closed=291
```

여기서 **네 가지가 한꺼번에 확인**된다:

1. STEP 3 의 원시값 7열이 덤프에 실제로 실린다(값도 정상).
2. **팀 술어가 시뮬 중반에 살아 있다** — 시뮬 전 테스트에서는 0/0 이던 것이 여기서는 7팀 형성 중으로
   측정된다. (이 구역은 그중 어느 팀도 안 덮어 `covered=0`.)
3. `valid_mask=[0,7]` — 기하로 정해진 팔. 도메인이 비었으므로 3 이 **정확히** 빠졌다.
4. `closed_at_fire=58` — 예고했던 **발화점 붕괴가 실제로 일어났다**. `closed∈[10,16]` 을 요청했는데
   58 에서 터졌다. 그러므로 `:forbid_zone` 가지는 이 세계의 라벨 시점에 **원리적으로 도달 불가**이고,
   라벨 시점의 정직한 zone 어휘는 `{NOOP, RelocateBuild}` 다. STEP 2 의 값어치는 팔을 되살린 데 있지
   않고 **NOOP 을 정답으로 인정한 데** 있다.

### 합격 기준 (계획서 그대로)

1. `H(best | zone) > 0` — kind 내부에서 정답이 갈릴 것
2. 동점률 < 30%
3. 완주/진행 격차가 **subopt_norm 으로** 드러날 것 ← 이 설계가 쓸모 있다는 유일한 직접 증거

### ★ 결과 — 규칙이 **반증**됐다 (8/8 job 확정, `oracle/out/zgrid_0805/REPORT.txt`)

8 instance 전부 동일한 형태다. `closed_noop = closed_best = 291`, 즉 **아무것도 안 하는 쪽이
언제나 최선**이고, 그때도 빌드는 완주한다.

| 축 | 값 | 결과 |
|---|---|---|
| 발화 시점 | early 요청 `[10,16]` / late 요청 `[55,60]` | 실제 `closed_at_fire ∈ {58, 60}` — **두 축이 붕괴** |
| 구역 위치 | zf 0.0 (overlap 0.64 · root 1.00) / zf 1.3 (overlap 0.25 · root 0.62) | 둘 다 NOOP 최선 |
| 도메인 | `zone_blocked = 0`, `zone_restage_feasible = 0` (전 instance) | `:forbid_zone` 가지 **표집 불가** 확인 |
| 팀 | `zone_teams_covered = 0` (전 instance) | 이 배치들은 팀을 안 덮는다 |

```
[gate] valid_mask 밖 팔 8/24 행 제외 (ForbidZone -- NOOP 과 바이트 동일)
기준 (1) H(best|zone) = 0.000 bits            FAIL   (정답이 NOOP 하나뿐)
기준 (2) 동점률       = 0/8 = 0.0%             PASS
기준 (3-a) closed    always NOOP          mean subopt_norm =  0.00
                     always RelocateBuild mean subopt_norm = 77.62  (max 146)
기준 (3-b) makespan  always NOOP          subopt_norm = 0.00   미완주 0/8
                     always RelocateBuild subopt_norm = 1.65   **미완주 7/8**
최소수복 규칙 vs 실측 최선: 일치 0/8 = 0.0%
```

### 이 사건은 **유해하다** — 단, 피해가 `closed` 가 아니라 `makespan` 에 있다

처음에 "이 zone 은 애초에 무해하니 규칙을 고칠 근거가 없다"고 적었는데, **그건 틀렸다**.
에피소드 모드에 대조군이 없어서 확인을 못 했던 것이라, 단일사건 모드(대조군 실행됨)로 따로 쟀다:

```
oracle/out/zgrid_ctrl2/ep_ctrl2.jsonl  (단일사건 모드, seed 301, zoneblk)

control       (OOD 없음)      complete=True   closed=291  makespan=22.25
NOOP          (구역 있음)     complete=True   closed=291  makespan=47.08   <- 2.1 배
RelocateBuild (구역 있음)     complete=False  closed=173  makespan=Inf     <- 개입이 더 나쁘다
```

세 값이 한 줄에 다 있다: **구역은 해롭고(22→47), 절제는 그래도 완주하며(291), 개입은 판을 깬다(173·미완주).**

노드 수도 완주 여부도 **똑같고 시간만 두 배**가 된다. `instance_admissible` 의 세 번째 조건
(closed 같고 makespan 이 더 나쁨)에 정확히 걸리므로 이 instance 는 **admissible** 이다.
즉 구역은 진짜로 해롭고, 그 피해를 `closed` 하나로만 재면 통째로 안 보인다.
(채점기에 `기준 (3-b) makespan` 채널을 추가한 이유다.)

**해석(그리고 이 작업의 가장 중요한 발견)**: 구역이 root 하역 목표를 **8/8 전부 삼켰는데도**
아무것도 안 하는 쪽이 291 노드를 닫고 완주한다. 즉 이 시뮬레이터에서

> **덮였다(coverage) ≠ 막혔다(blockage)**

이다. 구역은 항법 정책에 주는 제약이고, 반응형 회피층이 그 위에서 결국 목표에 도달한다.
그러므로 `root_covered > 0 → 개입` 이라는 STEP 2 규칙의 조건은 **기하는 맞지만 인과가 틀렸다**.

같은 비판이 **내 새 팀 술어에도 그대로 적용된다**: `zone_team_predicate` 는 슬롯이 구역 안에
있음을 증명했지만, 그 팀이 **실제로 형성에 실패하는지**는 증명하지 않았다. 커버리지 술어 전부가
같은 종류의 대리지표다.

**따라서 STEP 6 은 "규칙 검증"이 아니라 "규칙 반증"으로 결론난다.** 이건 실패가 아니라 이 단계가
존재하는 이유다 — 계획서 3번 기준("완주 격차가 subopt_norm 으로 드러날 것")이 정확히 이걸 잡아냈다.

**그런데도 개입은 답이 아니다.** 구역이 시간을 두 배로 늘리는 것은 사실이지만, 그 대응으로
빌드를 통째로 옮기면 **8판 중 7판이 완주에 실패한다**(makespan 채널). 즉 이 결정의 구조는

> 피해는 실재한다 → 하지만 지금 어휘에 있는 개입은 피해보다 더 큰 손해를 낸다 → 절제가 최선.

이고, 그래서 `root_covered > 0 → RelocateBuild` 라는 STEP 2 규칙의 조건은 **기하는 맞고 인과가
틀렸다**. 커버리지는 "덮였다"만 말할 뿐 "그래서 막혔다"를 말하지 않는다.

**그럼에도 규칙을 지금 코드에서 바꾸지 않는 이유**: 표본이 구역배치 2종·seed 2개뿐이고,
발화점이 58/60 으로 사실상 한 점이다. 이 조건에서 규칙을 "root 를 봐도 개입하지 마라"로 바꾸면
zone 의 정답이 **항상 NOOP** 이 되어(H=0) 결정 자체가 사라진다 — 데이터에 맞춰 문제를 없애는 셈이다.
필요한 것은 규칙 튜닝이 아니라 **실제로 막는 zone 사건**이다.

고칠 방향은 분명하다 — 개입 조건을 **커버리지**가 아니라 **도달 가능성/교착**으로:
목표 디스크가 덮였는가가 아니라 그 목표까지 통로가 남아 있는가, 팀이 K 스텝 안에 실제로
형성되는가. 그게 STEP 1 에서 corridor 술어를 후속 과제로 남긴 이유와 같은 지점이다.

### 미리 적어 두는 위험

- **에피소드 모드에는 대조군 자체가 없다.** 처음엔 `DS_NOCTRL=1` 탓이라 적었는데, 코드를 보니
  그게 아니었다 — `gen_oracle_dataset.jl:1554` 가 에피소드 행의 `ctrl_*` 를 **상수 sentinel**
  (`false / -1 / Inf`)로 박아 넣는다("control 은 에피소드 모드에서 정의되지 않는다").
  `DS_NOCTRL` 을 꺼도 값이 그대로인 것을 실행으로 확인했다. 그러므로 이 덤프의 `admissible`
  열은 **구조적으로 무의미**하고, admissibility 로 거르는 분석에는 쓸 수 없다.
  → "이 zone 사건이 애초에 유해한가"는 단일사건 모드(대조군 실행됨)로 따로 잰다.
- tractor 는 첫 시뮬 배치에서 ~58 노드를 한꺼번에 닫으므로, `closed∈[10,16]` 예약이
  실제로는 closed≈58 에서 발화할 수 있다(기존 실측: `closed_at_fire ∈ {50,58}`).
  그러면 early/late 두 축이 같은 시점으로 붕괴하고 `:forbid_zone` 가지는 여전히 안 잡힌다.
  → 채점기가 `closed_at_fire` 와 가지 분포를 함께 출력하므로 **결과를 보고 판정**한다.
  붕괴가 확인되면 그건 실패가 아니라 "발화 시점으로는 이 가지를 못 만든다"는 **구조적 사실**이고,
  그때는 구역 배치(zfrac)나 조립 순서 쪽으로 축을 바꿔야 한다.

주의: 새 규칙이 배경 정책을 바꾸므로 **옛 덤프와 섞으면 안 된다**. 새 출력 경로(`zgrid_0805/`)에 따로 쓴다.

---

### STEP 6 최종 판정

| 기준 | 결과 | 뜻 |
|---|---|---|
| (1) `H(best\|zone) > 0` | **FAIL** (0.000 bits) | 이 격자 안에서는 정답이 항상 NOOP → 상태를 읽는 모델이 배울 게 없다 |
| (2) 동점률 < 30% | **PASS** (0%) | valid 게이트를 걸면 동점은 사라진다(게이트 없으면 100%) |
| (3) 격차가 subopt_norm 으로 | **PASS** | closed 77.6 · makespan 채널에서 개입 7/8 미완주 |

**결론**: 배선(STEP 1~3)은 전부 작동하고, 그 배선이 만들어낸 첫 측정이 **STEP 2 규칙을 반증**했다.
계획서가 STEP 6 을 "이 설계가 쓸모 있다는 유일한 직접 증거"라고 한 그 자리에서, 증거는
"규칙의 개입 조건이 틀렸다"를 가리킨다. 이건 실패가 아니라 이 단계가 정확히 제 일을 한 것이다.

---

## 7. 이번 작업에서 새로 만든 검증 도구

| 파일 | 무엇을 재는가 | 시뮬 필요 |
|---|---|---|
| `tools/tests.jl zone_diagnosis` | 술어 ↔ 기존 헬퍼 일치, 기하 격자에서 규칙 일관성, 게이트 일치 (42 검사) | env 빌드만 |
| `tools/tests.jl zone_team_predicate` | **살아 있는 형성 팀** 위에서 팀 술어가 거짓 `:noop` 을 뒤집는가 (8 검사) | 짧은 시뮬 |
| `tools/test_policy_zone.jl` | 라이브 정책 레이어의 zone 어휘·원시값·**판정 누출** | env 빌드만 |
| `oracle/test_relocate_build.jl` `== 4b` | 최소수복 규칙 → 팔/기준정책 번역 (13 검사) | 없음(초 단위) |
| `step6_zonegrid_report.py` | STEP 6 세 기준 + 가지별 사후분류 + 규칙 vs 실측 | 없음 |

---

## 8. 다음에 할 일 (우선순위 순)

1. **통로(corridor) 술어** — 이번 측정이 가리키는 단 하나의 다음 단계.
   `_minimum_clear_translation` 의 Δ 는 목표 디스크만 보장하고 **경로는 보장하지 않는다**
   (doc 2 의 rim livelock, 이번 makespan 2.1 배가 같은 증상일 가능성이 높다).
   "덮였다"가 아니라 "막혔다"를 재는 술어가 생기면 STEP 2 규칙의 개입 조건을 인과에 맞게 고칠 수 있고,
   STEP 7 의 `:line_stop` 게이트도 그때 비로소 발화한다.
2. **실제로 막는 zone 사건 만들기** — 지금 격자의 zone 은 시간만 늘린다. 완주를 막는 배치가 있어야
   `H(best|zone) > 0` 가 성립하고 결정 문제가 된다.
3. **팀 술어의 인과 검증** — 슬롯이 덮였음은 증명했지만 그 팀이 **실제로 형성에 실패하는지**는
   아직 아니다. `zone_team_predicate` 를 K 스텝 더 굴려 형성 여부까지 보면 된다.
4. 라이브 데모(`render_demo.jl`)에서 STEP 3 원시값 + STEP 7 게이트 실행 확인(LLM 비용 발생).

---

## 부록 — 되돌리는 법 (모든 변경의 off 스위치)

| 스위치 | 효과 |
|---|---|
| `DS_ZONE_DIAG=0` | shim 이 진단을 안 붙임 → `valid_actions`/`canonical_action` 이 옛 고정 동작 |
| `DS_ZONE_ARMS="0,7"` | 팔 목록을 명시 고정(진단보다 우선) |
| `zone_diagnosis(...; check_teams=false)` | 팀 술어 이전의 규칙을 정확히 재현 |
| `RELOCATE_GATE=0` (기본) | 비례성 게이트 자체가 꺼짐 |
| `featurize_agnostic(...)` 기본값 | 원시값 열 미포함 = 기존 특징행렬과 동일 |

---
---

# 부록 B — 막힘(blockage)을 결정 경로에 배선하다 (2026-08-05, 같은 날 후속)

위 본문이 **STEP 6 의 부정 결과**로 끝났다: 배선은 다 되는데 이 격자의 zone 사건에는
`H(best|zone)=0` — 정답이 언제나 NOOP 이라 결정이 존재하지 않았다. 그 원인은 `zone_corridor.jl`
가 규명했다(커버리지는 **막을 수 없는 목표**를 세고 있었다). 이 부록은 그 진단을 **결정 경로 전체**
(게이트 → 라우터 → LLM 입력 → 데모 사건 생성)에 배선하고 라이브로 검증한 기록이다.

작업 순서는 의도적으로 **C → A → B** 였다: 게이트를 먼저 고쳐 놔야 B 에서 처음 만든 "막는 구역"이
거절로 죽지 않고, A 가 있어야 LLM 이 그 구역을 볼 수 있다.

## B-1. 게이트 (`src/respec/verifier.jl`)

`RELOCATE_GATE` 의 거절 조건에 `∧ n_nav_blocked == 0` 을 더했다.

옛 조건(`root_covered == 0 ∧ n_teams_covered == 0`)은 **둘 다 커버리지**라, 이번에 만든 가족을
구조적으로 못 본다: root 를 하나도 안 덮고 형성 중인 팀도 없는데 **RVO 구동 목표를 실제로 막는**
구역이다. 그 구역의 유일한 수복이 RelocateBuild 인데 옛 게이트는 그걸 `:disproportionate` 로
거절했다 = **고칠 수 있는 사건을 게이트가 죽인다**. ∧ 을 하나 더 붙였으므로 방향은 좁아지는
쪽(과잉 거절만 감소)이고 기존 admit 경로는 그대로다. blockage 계산 실패 시 `-1` 이라 항이 거짓 →
거절 안 함(fail-open).

## B-2. 라우터 (`tools/monitor/policy.jl`)

**관측 표현력** 에스컬레이션을 추가했다: `n_nav_blocked > 0` 이면 novelty 와 무관하게 LLM 으로 올린다.

- 기존 2번째 조건(액션 표현력) = "싼 정책이 그 **매크로**를 학습한 적이 없다".
- 새 조건(관측 표현력) = "서로게이트의 특징 벡터에 이 위반을 담을 **열 자체가 없다**".
  배포 서로게이트는 `graded_hs_n44` 로 적합되고 그 열 목록에 blockage 가 없다 → 이 사건에서
  서로게이트는 **원리적으로** 옳을 수 없는데 novelty 는 그걸 "익숙함"이라 부른다.
- 기존 3번째(`:line_stop`)보다 실효적이다 — 그쪽은 작업공간이 무한이라 Δ 가 늘 존재해 거의 잠들어 있다.

**첫 라이브 런에서 잡은 버그**: 예전 코드는 `enacted != "dspy"` 를 블록 **전체**에 걸어서, 라우터가
이미 LLM 으로 보낸 사건에서는 `zone_primitives` 가 스트림에 한 줄도 안 남았다. 그런데 그 값이
"이 구역이 실제로 무엇을 막았나"라는 사후 감사의 유일한 증거다. → **기록은 언제나, 격상만 조건부로**.

## B-3. LLM 입력 (`policy.jl` + `dspy_service.py`)

`zone_blockage` 가 계산해 놓고 아무도 안 쓰던 값을 실어 보내고, `MEASURED GEOMETRY` 한 덩어리를
**둘로 갈랐다**:

```
WHAT THIS ZONE COVERS (geometry only):
  ...
  root_goals_trapped     = 8   (... These are placed by a lift that moves the cargo directly,
                                not by a navigating agent)      <- 기구 사실 한 줄
WHAT THIS ZONE CAN ACTUALLY BLOCK:
  nav_goals              = 127
    of which blocked     = 3
      work frozen by those = 32
  agents_parked_inside   = 0
  (the build has 246 unfinished nodes in total)
```

한 덩어리로 주면 "8/8 갇힘"이라는 큰 숫자가 모델을 계속 개입 쪽으로 끈다. `root_goals_trapped` 에
붙인 기구 한 줄은 판정이 아니라 `route_planning.jl` 에서 코드로 확인되는 **사실**이므로 STEP 4 의
원칙(결정표 금지)을 위반하지 않는다.

`zone_nav_disconnected` 는 **일부러 프롬프트에 안 싣는다**: 결정 경로에서는 통로 flood-fill 을 끄고
부르므로(nav 목표 127개마다 격자를 도는 비용) 늘 0 이고, 0 을 보이면 "재 봤더니 0"으로 읽힌다.
재지 않은 것을 0 으로 보고하지 않는다 — 대신 `of which blocked` 설명에 하한임을 명시했다.

### ★ `work frozen by those` — 이 부록에서 새로 만든 유일한 측정

첫 라이브 시도에서 LLM 은 blockage 블록을 **읽고도** NOOP 을 골랐고, 근거를 이렇게 적었다:

> "The no-go zone only blocks one navigation goal ... minimal impact."

숫자를 오해한 게 아니라 **1/120 을 1/120 의 피해로 읽은 것**이고, 그 읽기는 우리가 준 숫자만
보면 옳다. 빠진 것은 크기다 — 스케줄은 선후행 DAG 라 절대 못 닫는 노드 하나는 그 뒤의 모든 노드를
영영 못 열게 한다. 그래서 `_downstream_unfinished`(zone_corridor.jl)를 새로 만들어 **막힌 노드 자신
+ 이행적으로 그걸 기다리는 미완 노드 수**를 세어 함께 준다. 이건 그래프 사실이지 판정이 아니다.

민감도 실측(같은 프롬프트, 값만 교차):

| 프로그램 | downstream=173 | downstream=3 |
|---|---|---|
| seed(SEED_DOC) | **RelocateBuild** ("freezing 173 nodes, a significant portion") | NOOP ("impact is minimal") |
| MIPROv2 컴파일 gpt-4o | NOOP | NOOP |

즉 이 한 값이 **결정을 뒤집는다**. 그리고 작은 값에서는 절제가 유지되므로 개입 쏠림이 아니다.

### ★ 컴파일된 프로그램은 zone 을 못 읽는다 (배포상 함정)

`sweep_lab/dspy_real_program_gpt4o.json` 의 최적화된 instruction 전문:

> "Given the state of a **robot**, including ... (e.g., OOD kind=**battery**), **state of charge**,
> ... such as **replacing a battery** ..."

MIPROv2 가 **배터리 전용 데이터셋**에서 뽑은 문장이라 zone·기하·RelocateBuild 어휘가 통째로 없고,
demo 4개도 전부 battery 다. 그 프로그램은 `SEED_DOC`(6개 매크로 + 원리)을 **대체**하므로 zone 사건에서
기하를 못 쓴다. → **zone 데모는 seed 프로그램으로 돌려야 한다**(`DSPY_PROGRAM` 을 없는 경로로).
컴파일 프로그램을 계속 쓰려면 zone 사건을 포함해 재컴파일해야 한다.

### 지시절 제거

주입기 문장의 뒷절("...; restage the affected assembly out of the restricted region")이 곧 canonical
정답이라, 그대로 주면 재는 것이 추론이 아니라 **프롬프트 준수**가 된다. 서비스의 정규식(`_IMPERATIVE`)에
기대는 대신 **애초에 안 붙이도록** 데모 주입기 3곳의 문장을 관찰문으로 바꿨다. `LLM_NL_MODE` 는
백스톱으로 남기되, 서비스가 별도 프로세스라 환경변수가 안 닿으므로 요청 필드 `nl_mode` 를 추가하고
데모 기본값을 `observation` 으로 했다(서비스 기본값 `raw` 는 그대로 = 옛 호출자 무영향).

## B-4. 데모의 두 구역 가족 (`tools/monitor/render_demo.jl`)

`inject_staging_zone!` 을 읽어 보면 **무해하도록 설계돼 있다**: `zone_clears_root_goals` 로 root 를
일부러 피하고, 미완 작업 디스크와 겹침이 최소인 후보를 고르고, sim 전에 심는다. 완주는 늘 확인됐지만
그건 결정이 옳아서가 아니라 애초에 아무것도 안 막았기 때문이다.

`DEMO_ZONE_MODE` 로 두 가족을 가른다(**기본 `blocking`**):

| 값 | 주입기 | 심는 곳 | 정답 |
|---|---|---|---|
| `blocking` | `inject_blocking_zone!`(신규) | RVO 구동 주체의 **미래** 목표 위 | 개입 |
| `harmless` | `inject_staging_zone!`(기존) | 적치원 가장자리 | NOOP |

`inject_blocking_zone!` 은 `tools/restage.jl::place_blocking_zone_on_nav_goal!` 의 검증된 절차를 그대로
옮겼다: ① 아직 **활성이 아닌** 목표만(이미 날아가는 중인 로봇을 밀어내면 결정이 아니라 사고다)
② 운반유닛 우선·빌드 중심 근접 순의 **결정적** 정렬 ③ `zone_relocatable` 통과분만(복구 가능한 것만)
④ 심은 뒤 `n_blocked >= 1` 확인, 아니면 지우고 다음 후보. 후보를 하나도 못 찾으면 무해 가족으로
폴백해 **사건이 통째로 사라지는 일**은 없게 했다.

**sim 전이 아니라 발화 시점(`closed=58`, restage.jl 의 `ZC_FIRE` 와 동일)에 심는다**: `_nav_goal_targets`
는 살아 있는 env 에서 평가해야 뜻이 있고, 어차피 ForbidZone 의 "미시작 조립체" 전제는 respec 처리
시점(closed≈54)이면 이미 깨져 있다.

## B-5. 완주 보장 — 복구 사다리의 ③번 칸

결정 레이어가 절제를 골라도 그 결과가 **영구 정체**여서는 안 된다(완주는 데모의 전제 조건이다).
그래서 `enact_reform!` 에 공간 수복 칸을 더했다: 살아 있는 구역이 미완 항법 목표를 실제로 막고
있으면 `translate_whole_build!` 를 건다. 판정이 아니라 carrier-rescue 와 같은 급의 **복구**이므로
recovery 타임라인에 따로 남아 "정책이 뭘 골랐나"와 섞이지 않는다(`ZONE_RESCUE=0` 으로 끔).

조건에 `attempt >= 2` 를 함께 둔 이유: `recover_stalled_teams!` 은 `:force_snapped` 를 돌려줄 때
**항상** ok=true 라 `!ok` 만 보면 이 칸이 영영 도달 불가가 된다.

## B-6. 라이브 검증 (tractor, seed-only gpt-4o, router auto)

```
DEMO_ZONE_MODE=<mode> DEMO_OOD=<case> DEMO_POLICY=surrogate DSPY_URL=<seed-only service>
NOVELTY_CALIB=wm4spacecraft_manufacturing/novelty_calibration_no_zoneblk.json
```

| 케이스 | 가족 | 결정 시점 원시값 | rule | surrogate | **LLM** | 실행 | 결과 |
|---|---|---|---|---|---|---|---|
| `zone` | blocking | nav 3/127 막힘, downstream 32 | NOOP | NOOP | **RelocateBuild** | translated \|Δ\|=**2.382**, residual 0 | **COMPLETE** (276) |
| `fault_zone` | blocking | 〃 | NOOP | NOOP | **RelocateBuild** | 〃 + Replace(R3) hot-swap | **COMPLETE** (275) |
| `battery_zone` | blocking | 〃 | NOOP | NOOP | **RelocateBuild** | 〃 + Replace(R5) hot-swap | **INCOMPLETE** (255) — B-7 |
| `zone` | harmless | nav **0**/131 막힘, downstream 0 | ForbidZone | NOOP | **NOOP** | 개입 없음 | **COMPLETE** (283) |

읽는 법:

- **가족이 답을 가른다.** 같은 프롬프트·같은 정책인데 blocking 에서는 RelocateBuild, harmless 에서는
  NOOP 이다. 개입 쏠림이 생기지 않았다는 반대 방향 검사가 마지막 줄이다.
- **규칙 0/2 · LLM 2/2.** blocking 가족에서 canonical 은 커버리지만 보므로 `:noop` 을 답한다.
  `ZONE_CAUSAL_RULE` 은 **켜지 않았다** — 규칙까지 같이 고치면 LLM 이 무엇을 더 했는지가 화면에서 사라진다.
- 라우터는 이 사건을 **novelty 로 이미** LLM 에 보냈다(p=0.005). 새 에스컬레이션은 그 위의 백스톱이다.
- 실행부가 `delta=[0,0]` 이던 옛 스트림과 달리 실제로 **2.382 m** 옮겼다.

단위 테스트 회귀: `tools/tests.jl zone_corridor` 25/25 · `zone_diagnosis` 42/42 ·
`tools/test_policy_zone.jl` 19/19 · `tools/test_router.jl` 8/8 — 전부 GREEN.

주의: 이 트윈에서 **완주 ≠ closed == total** 이다(`PROJECT COMPLETE` 는 `project_complete(env)` 판정).
계획서가 적은 "287" 은 다른 설정의 수치이므로 그대로 기대하면 안 된다.

## B-7. `battery_zone` 미완주 — 원인은 구역이 아니다

> **⚠ 이 절의 결론은 부록 C 에서 뒤집혔다.** 여기서 '중반에 떨어진 배터리 + 루트 엔드게임'으로
> 지목한 것은 증상이었고, 진짜 원인은 **두 시뮬을 동시에 돌려 MILP 스케줄이 달라진 것**이다.
> 단독 실행하면 같은 케이스가 3/3 완주한다. 아래는 그 규명에 이르는 과정으로 남긴다.

증거(같은 런의 로그):

```
[zone] blocking zone on transport vtx=148 -> nav_blocked=3/127
[policy] ZoneTruth → RelocateBuild            <- 구역은 여기서 해소됨(residual 0)
[ood] battery fired at step≈604 closed=122
[policy] BatteryTruth → Replace
[reform] attempt 1/3 ... (10회) ... attempt 3/3
[reform] zone-rescue: no live zone blocks a navigable goal (0/30)   <- 구역은 무죄
PROJECT INCOMPLETE!
```

정체 시점에 **살아 있는 구역이 막는 목표는 0개**다(공간 수복 칸이 그렇게 보고한다). 즉 이것은
`md/` 에 이미 여러 번 기록된 **루트 엔드게임 교착**이고, 배터리 hot-swap 뒤에 그 교착이 평소보다
많은 복구 시도를 요구해 `DEMO_REFORM_MAX=3` 예산을 소진한 것이다(같은 판에서 reform 10회,
다른 두 케이스는 1~2회). 대조는 B-8 에 적는다.

## B-8. `battery_zone` 대조군 — 무엇이 원인이고 무엇이 아닌가

| 런 | 구역 가족 | 배터리가 터진 지점 | 결과 |
|---|---|---|---|
| `battery_zone` | **blocking** | step≈604 → **closed 122** (중반) | INCOMPLETE 255 · reform 10회 |
| `battery_zone` | harmless | step≈604 → **closed 254** (후반) | **COMPLETE** 271 · reform 0회 |
| `battery_zone` | blocking + `DEMO_REFORM_MAX=6` | 〃 closed 122 | INCOMPLETE **255** (동일) · reform 13회 |
| `fault` (구역 없음) | — | — | **COMPLETE** 283 |
| `battery` (구역 없음) | — | step≈604 → closed 254 | **COMPLETE** 254 |

읽는 법 — **가족이 결과를 가른 것이 아니라, 가족이 사건의 시점을 옮겼다**:

두 런은 **같은 seed·같은 step 창**에서 배터리를 뽑는다(step≈604). 그런데 blocking 런은 구역을 만나
전체를 2.38 m 옮기느라 느려져, 같은 **step** 이 전혀 다른 **build progress** 에 대응한다 —
closed 122 vs 254. 즉 blocking 가족은 배터리 사건을 빌드 **중반**으로 밀어 넣는다.

그리고 정체 시점의 계측은 구역을 명시적으로 배제한다:

```
[reform] zone-rescue: no live zone blocks a navigable goal (0/30)
```

복구 예산을 3→6 으로 늘려도 **closed 가 255 로 한 노드도 안 변한다**. 예산은 원인이 아니다
(2026-07 의 `NOPROG 캡` 대조와 같은 형태의 결론이다). 남는 후보는 **중반 Replace 뒤의 루트
엔드게임**이고, 로그의 마지막 네 시도는 전부 `carrier_advanced` = "운반체를 목표로 순간이동시켜
고정했는데 `is_goal` 이 여전히 안 켜진다" = 위치가 아니라 **스케줄 선행조건**이 막고 있다는 뜻이다
(`force_advance_stuck_carrier!` 의 else 분기). 같은 판의 `resolve_schedule_wedge!` 는
`:not_applicable`(hot-swap 경로라 직렬화 게이트가 기록된 적이 없음)이라 손댈 곳이 없다.

### 이 부록이 **하지 않은** 것

`carrier_advanced` 가 반복되는 이유(어느 선행자가 OPEN 인가)는 `WEDGE_DEBUG=1` 의
`_carrier_goal_diag` 가 답한다. 그 런은 Info 로깅이 LDraw 파싱까지 전부 찍어 실행 시간이
비현실적으로 길어져 **중단했다**. 그러므로 "중반 Replace + 전역 이동" 조합의 정확한 교착 지점은
아직 규명되지 않았고, 이 부록은 그 위치를 **좁혀 놓았을 뿐**이다.

### 귀속 실험 하나 더 — "중반 Replace" 자체는 무죄

| 런 | 구역 | 배터리 지점 | 결과 |
|---|---|---|---|
| `battery` (구역 없음, `DEMO_BATTERY_STEPS=300,300`) | 없음 | closed **173** (중반) | **COMPLETE** 283 · reform 1회 |

즉 "빌드 중반의 배터리 Replace"는 그 자체로 완주를 막지 않는다. 남는 후보는 **전역 이동을 겪은
빌드에서의 중반 Replace**(또는 하필 closed≈122 라는 지점)이고, 이 둘을 가르려면 blocking 런에서
배터리 발화 지점만 옮겨 재보면 된다. **아직 안 했다** — 다음 작업이다.

## B-9. 기본값 결정 — ~~`DEMO_ZONE_MODE` 는 아직 `harmless`~~ (부록 C 에서 `blocking` 으로 확정)

> **⚠ 이 절은 폐기되었다.** 미완주가 실행 방식의 아티팩트로 밝혀져(부록 C) 기본값은 `blocking` 이다.
> 아래 원문은 '완주가 전제 조건'이라는 판단 기준을 남기기 위해 보존한다.

blocking 가족은 `zone`·`fault_zone` 에서 완주하지만 `battery_zone` 에서 미완주하고, 그 원인이
아직 열려 있다(B-7·B-8). **완주는 이 데모의 전제 조건**이므로 그 조합이 완주할 때까지 기본값은
안전한 쪽에 둔다. blocking 은 `DEMO_ZONE_MODE=blocking` 한 줄로 켠다.

이 결정으로 잃는 것을 정직하게 적어 둔다: 기본 데모의 zone 사건은 **여전히 아무것도 막지 않는
사건**이고, 따라서 기본 녹화만 보면 "구역 결정"은 여전히 NOOP 이 정답인 문제다. 이 부록이 만든
결정 문제는 기본값 뒤가 아니라 **옵트인 뒤**에 있다.

## B-10. 완주 검증 요약 (전부 tractor · seed-only gpt-4o · router auto)

| 케이스 | 가족 | 결과 | 비고 |
|---|---|---|---|
| `zone` | harmless(기본) | **COMPLETE** 283 | LLM=NOOP, rule=ForbidZone |
| `battery_zone` | harmless(기본) | **COMPLETE** 271 | 배터리 closed 254 |
| `fault_zone` | harmless(기본) | **COMPLETE** 281 | Replace hot-swap |
| `zone` | blocking | **COMPLETE** 276 | LLM=RelocateBuild, \|Δ\|=2.382 |
| `fault_zone` | blocking | **COMPLETE** 275 | 〃 + Replace |
| `battery_zone` | blocking | **INCOMPLETE** 255 | B-7·B-8 |
| `fault` (구역 없음) | — | **COMPLETE** 283 | 회귀 |
| `battery` (구역 없음) | — | **COMPLETE** 254 | 회귀 |
| `battery` 중반(구역 없음) | — | **COMPLETE** 283 | 귀속 |

단위 테스트: `zone_corridor` 25/25 · `zone_diagnosis` 42/42 · `test_policy_zone` 19/19 ·
`test_router` 8/8.

## B-11. 계획서 D절 — core zone 가족은 완주 지표에서 분리한다

계획서가 지적한 대로 `zcausal_reform` 원본 기준 control 279 / NOOP 232 / RelocateBuild 197 이면
**어휘 안에 완주하는 팔이 없다**. 그런 가족에 완주를 요구하면 그건 지표가 아니라 불가능 조건이다.
→ core zone(root 하역목표를 삼키는 중앙 구역) 가족은 **"손실 최소화" 사건**으로 규정하고 완주
지표에서 뺀다(그 데이터에서 NOOP=232 가 최선이다). "완주로 증명되는 zone 결정"은 B-4 의
blocking 가족에서 얻는다.

`zonecore_gpt41_reform`(287 완주)을 zone 결정의 성과로 쓰지 않는다 — 그건 zone 결정이 아니라
뒤따른 reform 사건이 살린 것이므로, 쓰려면 "zone→(정체)→reform 알람→ReformTeam→완주"라는
**2사건 서사**로 보고해야 한다.

---

# 부록 C — B-7 의 진짜 원인: **동시 실행이 스케줄을 바꾼다** (2026-08-05 심야)

B-7/B-8 은 `battery_zone`+blocking 미완주의 원인을 "전역 이동이 빌드를 늦춰 배터리가 중반에 떨어진다"로
좁혀 놓고, 그 뒤(루트 엔드게임)를 `WEDGE_DEBUG` 로 열어 보려다 로그 폭주로 중단했다. 그 진단을
**로그 범위만 좁혀** 다시 돌린 결과, 원인이 한 단계 더 위에 있었다.

## C-1. 진단 도구 — `CARRIER_DIAG`

`force_advance_stuck_carrier!` 의 "순간이동시켰는데 안 닫혔다" 한 줄(`_carrier_goal_diag`)이
`WEDGE_DEBUG` 에 묶여 있었고, 그 플래그는 `render_demo.jl` 에서 **로그 레벨 전체를 Info 로** 내린다
→ LDraw 파싱의 "incorporating geometry ..." 수만 줄까지 찍혀 런이 비현실적으로 느려진다.
필요한 것은 실패 지점의 한 줄뿐이므로 `CARRIER_DIAG=1` 로 분리하고 **`@warn`** 으로 낸다
(데모 기본 로그 레벨 Warn 을 그대로 통과 → 로그 레벨을 안 건드려도 보인다).

## C-2. 그런데 그 런은 **완주했다**

같은 케이스·같은 설정으로 `CARRIER_DIAG=1` 만 붙여 돌리자 `PROJECT COMPLETE`(277) 로 끝났고,
carrier 진단은 **한 줄도 안 찍혔다**(= force-close 가 실패한 적이 없다). 로그를 대조하니 갈린 지점이
정체 구간이 아니라 **맨 처음**이었다:

| 런 | 동시 실행 | 구역이 고른 목표 | 배터리 낙하 지점 | 결과 |
|---|---|---|---|---|
| `zblk_battery_zone` | 다른 sim 과 **동시** | `transport vtx=148` | closed **122** | INCOMPLETE 255 |
| `zblk_battery_zone_r6` | 다른 sim 과 **동시** | `transport vtx=148` | closed **122** | INCOMPLETE 255 |
| `zblk_bz_cdiag` | **단독** | `transport vtx=143` | closed **200** | **COMPLETE** 277 |
| `zblk_bz_rep1` | **단독** | `transport vtx=143` | closed **200** | **COMPLETE** 277 |

**목표 좌표는 네 런 모두 `@[1.094, 0.416]` 로 같은데 vtx 번호만 다르다** — 즉 갈린 것은 시뮬레이션이
아니라 **스케줄 그래프 자체**다.

## C-3. 왜 스케줄이 갈리는가

`run_lego_demo` 는 **HiGHS MILP** 로 스케줄을 푼다(`milp_optimizer=:highs`, `optimizer_time_limit`).
HiGHS 는 멀티스레드이고 시간 제한이 걸린 탐색이라, **CPU 경합이 다르면 다른 최적해/incumbent** 를
돌려줄 수 있다. Julia 자체는 `nthreads=1` 이므로 줄리아 스레딩은 원인이 아니다.

그래서 두 판은 애초에 **다른 스케줄**이었고, 같은 step 창에서 뽑힌 배터리가 한쪽에서는 closed 122,
다른 쪽에서는 200 에 떨어졌다. B-8 이 "가족이 사건의 시점을 옮겼다"고 적은 것은 절반만 맞았다 —
시점을 옮긴 것은 **전역 이동 + 서로 다른 MILP 스케줄** 둘 다이고, 완주를 가른 것은 후자다.

## C-4. 방법론적 귀결 (이 저장소 전체에 해당)

> **이 트윈의 런들을 동시에 돌려 비교하면 안 된다.** 스케줄이 달라져 "정책 비교"가 아니라
> "서로 다른 두 세계 비교"가 된다.

`regen_case_policy_matrix.sh`(24 런) 처럼 순차 실행하는 하니스는 안전하고, 시간을 아끼려고 병렬로
돌리면 그 실험은 무효다. 부록 B 의 blocking 3 케이스 중 `zone`·`fault_zone` 은 동시 실행이었는데도
완주했으므로 결과 자체는 유효하지만, **미완주 1건은 그 아티팩트였다**.

## C-5. 단독 실행 재현성 확인 + 기본값 확정

같은 케이스(`battery_zone`·blocking)를 **단독으로** 세 번 돌린 결과:

| 런 | 구역 목표 | 배터리 낙하 | reform | 결과 |
|---|---|---|---|---|
| `zblk_bz_cdiag` | vtx=143 | closed 200 | 0회 | **COMPLETE** 277 |
| `zblk_bz_rep1` | vtx=143 | closed 200 | 0회 | **COMPLETE** 277 |
| `zblk_bz_rep2` | vtx=143 | closed 200 | 0회 | **COMPLETE** 275 |

세 판 모두 동일한 스케줄(vtx=143)·동일한 사건 시점(closed 200)이고 **복구 사다리를 한 번도 안 탔다**.
즉 blocking 가족은 원래 완주하는 케이스였고, B-7 의 미완주는 병렬 실행 아티팩트였다.

→ **`DEMO_ZONE_MODE` 기본값을 `blocking` 으로 확정**한다(render_demo.jl · README).
이제 기본 데모의 zone 사건은 **실제로 무언가를 막는 사건**이고, 그 결정에서
규칙(canonical)은 `:noop`, LLM 은 `RelocateBuild` 로 갈린다.

## C-6. 정직한 한계

- MILP 비결정성 자체를 **고치지는 않았다**(시드 고정/스레드 1 강제/해 캐싱 중 어느 것도 안 함).
  지금 있는 것은 "병렬로 돌리지 말라"는 운영 규칙과 그 근거뿐이다. 하니스에 강제하려면
  `run_lego_demo` 에 `milp_optimizer_attribute_dict` 로 스레드 수를 1 로 고정하는 것이 첫 후보다.
- 따라서 "zone OOD 는 절대 실패하지 않는다"는 **순차 실행 조건에서** 성립하는 주장이다.
  경합이 다른 머신에서 다른 스케줄이 나오면 그 스케줄에서의 완주는 다시 확인해야 한다.
- `CARRIER_DIAG` 로 열려던 "carrier 가 순간이동 후에도 안 닫히는 이유"는 **끝내 관측되지 않았다**
  (그 경로를 타는 런이 더 이상 안 나왔다). 그 진단 도구는 설치돼 있고, 다시 그 증상이 나오면 그때 쓴다.

## C-7. 최종 검증 — 출하 기본값으로, **순차** 실행

`DEMO_ZONE_MODE` 를 지정하지 않고(= 기본 `blocking`) 세 zone 케이스를 한 프로세스씩 순차로 돌렸다.

| 케이스 | 심은 구역 | zone 결정 | 로봇 사건 | 결과 |
|---|---|---|---|---|
| `zone` | nav_blocked **3/127** | rule `NOOP` / surro `NOOP` / **LLM `RelocateBuild`** | — | **COMPLETE 275** |
| `fault_zone` | 〃 | 〃 | `Replace`(3정책 일치) | **COMPLETE 287** |
| `battery_zone` | 〃 | 〃 | `Replace`(3정책 일치) | **COMPLETE 271** |

**구역이 들어가는 모든 OOD 가 완주한다.** 그리고 세 판 모두 zone 결정에서
**규칙은 절제(`:noop`), LLM 은 개입(`RelocateBuild`)** 으로 갈린다 — 이 부록이 만들려던 대비가
기본 데모에 그대로 있다. (`fault_zone` 이 287 로 끝난 것은 계획서 수용기준 3번이 지목했던 그 숫자다.)

전체 회귀(부록 B-10 과 합산): 구역 없는 `fault` 283 · `battery` 254 완주,
단위 테스트 `zone_corridor` 25/25 · `zone_diagnosis` 42/42 · `test_policy_zone` 19/19 · `test_router` 8/8.

---
---

# STEP 8~11 — 커버리지를 **막힘**으로 바꾸다 (2026-08-05, 통합 2026-08-06)

> 원래 별도 문서 `ZONE_BLOCKAGE_STEP8_11_2026-08-05.md` 였다. 위 본문(STEP 1~7)의
> "다음에 할 일" 1~4 를 그대로 이어받는 연속 기록이라 2026-08-06 통합에서 여기 합쳤다.
> 아래 절 번호(0~6)는 원문 그대로다.


앞 문서(`ZONE_REDESIGN_STEP1_7_2026-08-05.md`)의 "다음에 할 일" 1~4 를 그대로 이어받는다.

> 1. 통로(corridor) 술어 — Δ 는 목표 디스크만 보장하고 경로는 보장하지 않는다
> 2. 실제로 막는 zone 사건 만들기
> 3. 팀 술어의 인과 검증
> 4. 라이브 데모 확인

STEP 6 의 결론은 "규칙의 개입 조건이 **기하는 맞고 인과가 틀렸다**" 였다. 이 문서는 그 인과를
코드 수준에서 **특정**하고, 그것을 재는 술어를 만들고, 그 술어가 고른 사건이 정말로 막는지
시뮬레이터로 확인한 기록이다.

---

## 0. 왜 덮여도 완주했나 — 기구를 특정했다

STEP 6 은 "root 하역목표를 8/8 삼켰는데도 291 노드를 전부 닫고 완주했다"를 관측했지만
**왜**인지는 열어 두었다. 코드 경로로 답이 나온다.

| 사실 | 위치 |
|---|---|
| 구역은 오직 한 곳에서 강제된다 — `enforce_restriction_zone_clearance!` 가 에이전트를 원 밖으로 **스냅** | `src/route_planning.jl:318-353` |
| 그 함수가 순회하는 것은 `get_vtx_ids(rvo_global_id_map())` = **RVO 에이전트(로봇·운반유닛)뿐** | 〃 `:322` |
| 그런데 `root_deposit_goals` 가 세는 목표는 **`LiftIntoPlace` 의 goal_config** | `src/respec/restage_zone.jl:348` |
| `apply_cmd!(::LiftIntoPlace, ...)` 는 **화물의 변환을 직접 적분**해 옮긴다 (RVO 경유 없음) | `src/route_planning.jl:1205-1210` |

즉 커버리지가 세던 목표는 **구역이 원리적으로 막을 수 없는 부류**였다. `root_goal_coverage` 의
독스트링이 주장하던 "frac≈1 이면 carrier 가 rim 에 영원히 선다"는 이 시뮬레이터에서 성립하지 않는다.
구역이 실제로 막을 수 있는 것은 **움직이는 주체가 RVO 에이전트인 목표**(`RobotGo` · `TransportUnitGo`)뿐이다.

주의: `LiftIntoPlace <: EntityGo` 이므로 **타입 검사로는 안 갈린다**(`_future_goal_discs` 가
`matches_template(EntityGo, n)` 로 이 셋을 한데 섞는 이유). 가르는 축은 타입이 아니라 **엔티티 종류**다.

### 측정으로 확인한 대비 (tractor, 시뮬 전 env)

```
nav(RobotGo/TransportUnitGo) = 123개, kinematic(LiftIntoPlace) = 27개, root deposit = 8개
  root 하역목표 8개는 전부 운동학(LiftIntoPlace) 목표    <- 좌표 일치로 확인
  그중 nav 목표와 좌표가 정확히 겹치는 것은 1개뿐
  root[i] -> 가장 가까운 nav(운반유닛) 목표까지 거리 = 0.0, 0.16, 0.24, 0.32, 0.32, 0.33, 0.33, 0.40
```

마지막 줄이 핵심이다. 운반유닛은 하역 지점 **근처**에 서고, 마지막 0.16~0.40 은 `LiftIntoPlace` 가
운동학적으로 처리한다. 그래서 하역 지점을 정확히 덮는 구역은 배송을 못 막고 **접근 경로만 늘린다**
— STEP 6 이 본 makespan 2.1 배가 정확히 그 값이다.

같은 구역(중심 core, r=0.5)에 대해:

```
root_covered = 8/8   nav_blocked = 1     <- 커버리지는 막힘의 상계일 뿐 같지 않다
```

---

## 1. STEP 8 — 막힘(blockage) 술어 `src/respec/zone_corridor.jl` (신규)

| 함수 | 무엇을 답하는가 |
|---|---|
| `_nav_goal_targets(env)` | 구역이 **막을 수 있는** 목표의 모수: 미완 `RobotGo`/`TransportUnitGo` 의 목표 + 그 주체의 반지름 |
| `_kinematic_goal_targets(env)` | 커버리지가 세던 부류(`LiftIntoPlace`) — 대비를 위해 1급으로 남김 |
| `goal_engulfed(goal, r_agent, zones)` | 포획볼(반지름 = `capture_distance_tolerance()`)이 통째로 배제원(`r_zone + r_agent`) 안인가 = **확정 막힘**(닫힌 식) |
| `free_space_status(start, goal, zones, r_agent)` | 부풀린 자유공간 격자 flood-fill: `:clear` / `:engulfed` / `:agent_trapped` / **`:disconnected`** |
| `zone_blockage(env)` | 위를 모아 `n_nav_goals · n_engulfed · n_disconnected · n_blocked · n_agent_trapped` + 운동학 대비 |

`:disconnected` 가 계획서가 요구한 **corridor 술어**다. `_minimum_clear_translation` 의 Δ 는
목표 디스크가 구역 밖임만 보장하고 **경로는 보장하지 않는다** — 목표가 완전히 비어 있어도 고리형
배치면 못 간다. 격자 상자는 {시작·목표·부풀린 구역 전부}를 3칸 여유로 감싸므로 바깥 띠가 항상
자유·연결이고, 따라서 **상자 때문에 거짓 `:disconnected` 가 나오지 않는다**.

정직한 한계 두 가지를 코드 주석과 독스트링에 명시했다:
- flood-fill 은 **이산화**다. `cell`(기본 = 로봇 반지름의 절반)보다 좁은 틈은 열린 것으로 읽힐 수 있어
  결과에 쓴 해상도를 함께 반환한다.
- `goal_engulfed` 는 구역을 하나씩 본다(보수적). 두 구역의 **합집합**으로만 삼켜지는 경우는
  flood-fill 쪽이 잡는다.

---

## 2. STEP 9 — 배선: 원시값은 싣고, 규칙은 opt-in

`zone_diagnosis` 에 원시값 5열을 추가했다: `n_nav_goals · n_nav_blocked · n_nav_engulfed ·
n_nav_disconnected · n_agent_trapped`. **판정(verdict)은 기본적으로 그대로**다.

인과 규칙은 `ZONE_CAUSAL_RULE=1` 로만 켜진다:

```
막을 수 있는 목표를 하나도 안 막았으면(n_nav_blocked == 0) -> :noop   (덮였든 말든)
그 외에는 기존 최소수복 순서(forbid_zone > relocate_build > line_stop)
```

기본이 꺼짐인 이유는 두 가지다. (a) 옛 라벨·게이트 재현성, (b) **아직 근거가 부족하다** —
규칙을 바꿀 자격은 STEP 10 이 "막는 사건에서 NOOP 이 실제로 실패한다"를 보인 뒤에 생긴다.
비용 이유로 `zone_diagnosis` 안에서는 engulf 만 계산하고(정확한 하한), 통로 검사는
`ZONE_CHECK_PATHS=1` 또는 `check_paths=true` 로 켠다.

### 검증 — `tools/tests.jl zone_corridor` (신규, **25/25 ALL GREEN**)

```
[1] root 하역목표는 전부 운동학 목표다 / 전부가 nav 목표인 것은 아니다        PASS
[2] 운동학 목표 위 구역: covered=1  blocked=0     <- 덮였다 ≠ 막혔다          PASS
    nav 목표 위 구역:    blocked=2 (engulf=2)                                  PASS
[3] 촘촘한 고리 -> :disconnected (목표 자체는 engulf 아님)                     PASS
    성긴 고리   -> :clear / 단일 원판 -> :clear (돌아가면 된다)                PASS
[4] root_covered=8 > nav_blocked=1  (커버리지가 막힘을 과대평가)               PASS
    덮기만 하는 구역: 커버리지 규칙 -> forbid_zone / 인과 규칙 -> noop         PASS
```

회귀: `tools/tests.jl zone_diagnosis` **42/42 ALL GREEN** (기본 OFF 가 옛 판정을 그대로 재현).

---

## 3. STEP 10 — 실제로 막는 zone 사건 (`tools/restage.jl causal`)

### 하니스 (그리고 그 하니스가 **아닌** 것)

`tools/restage.jl causal` 은 팔(arm)마다 **프로세스를 새로 띄운다**. RVO 시뮬레이터와 그 id 맵이
전역이라, 한 프로세스에서 두 팔을 돌리면 두 번째 팔이 첫 팔이 남긴 모션 상태 위에서 시작한다 —
`deepcopy` 대조군은 그래서 허구가 된다. 각 팔은 같은 세계를 다시 지어 같은 발화점(closed=58)에서 주입한다.

**정직한 차이**: 이 하니스에는 STEP 6 의 라벨 하니스가 켜 두었던 **자가치유 경로가 없다**.
`maybe_emit_reform_ood!` 는 `RESPEC_ENABLED[]` 를 요구하고(ood_injection.jl:579), `CARRIER_RESCUE` 는
기본 OFF 다(replace_robot.jl:804). 그러므로 여기서 재는 것은

> **순수 물리에서 이 구역이 완주를 막는가**

이고, STEP 6 이 잰 것은 "복구 장치를 켠 채로 막는가"다. **두 수치를 섞어 쓰면 안 된다.**

### 결과 — 두 절제 팔 (fired at closed=58/289, seed 고정)

| 팔 | 구역 | 진단 | 커버리지 규칙 | 인과 규칙 | 결과 |
|---|---|---|---|---|---|
| `blk_noop` | nav 목표(운반유닛) 위, r=0.07 | root **0**/8 · domain 0 · **nav_blocked 3**(engulf 3) · &#124;Δ&#124;=2.38 | `:noop` | `:noop`* | **stalled 254/289** (makespan 116.9) |
| `cov_noop` | core zone, r=0.321 | root **8**/8 · domain 0 · **nav_blocked 1** · trapped 2 · &#124;Δ&#124;=3.58 | `:relocate_build` | `:relocate_build` | **stalled 227/289** (makespan 113.4) |

**\* 이 줄이 이번 실험의 가장 중요한 산출이다.** `blk_noop` 의 구역은 root 하역목표를 **하나도**
안 덮고(`root_covered=0`) 재적치 도메인도 비어 있어(`domain=0`), 커버리지 기반 규칙은 그것을
**볼 수단 자체가 없다** — 무조건 `:noop` 이다. 그런데 그 구역은 실제로 완주를 막는다.

그리고 최초 구현의 인과 규칙도 똑같이 `:noop` 이라 답했다. 이유는 규칙을 **억제 조건으로만** 썼기
때문이다(`nav_blocked==0 → :noop`, 그 외에는 옛 커버리지 분기로 폴백). 막힘이 **발화 조건**이 아니면
커버리지가 0 인 사건에서는 여전히 눈이 없다. 그래서 규칙을 다음과 같이 고쳤다 — 커버리지를
**완전히 무시**한다:

```
ZONE_CAUSAL_RULE=1:
    n_nav_blocked == 0                 -> :noop
    n_nav_blocked > 0 ∧ 국소 도메인 有  -> :forbid_zone
    n_nav_blocked > 0 ∧ Δ 有            -> :relocate_build
    그 외                               -> :line_stop
```

### 1차 전체 (복구 사다리 OFF) — 그리고 대조군이 정정해 준 것

| 팔 | 개입 | 결과 |
|---|---|---|
| `control` | 구역 없음 | **complete** · closed 279/289 · makespan **19.73** |
| `blk_noop` | — | stalled **254** |
| `blk_reloc` | `translate_whole_build! -> :translated` | stalled **258** |
| `cov_noop` | — | stalled **227** |
| `cov_reloc` | `translate_whole_build! -> :translated` | stalled **258** |

두 개입 팔이 **정확히 같은 258** 에서 멈춘 것을 보고 처음에는 "하니스에 복구 사다리가 없어
모든 팔이 루트 엔드게임 교착에 걸린 것"이라고 적었다. **대조군이 그 진단을 뒤집었다**:
구역이 없으면 이 하니스는 767 스텝 만에 **완주**한다(makespan 19.73). 그러므로 네 정체는
하니스의 취약함이 아니라 **구역이 만든 것**이다.

남는 사실은 더 흥미롭다: **RelocateBuild 는 두 가족 모두에서 완주를 되찾지 못했다**
(227→258, 254→258). 그리고 STEP 6 의 라벨 하니스에서는 같은 core zone 이 NOOP 으로 **완주**했다
(closed 291, makespan 47) — 그 하니스에는 `RESPEC_ENABLED` 기반 reform 과 `CARRIER_RESCUE` 가
켜져 있었다. 즉 **복구 장치가 있느냐가 이 사건의 결론을 바꾼다.**

그래서 2차를 돈다: 데모와 같은 사다리(`recover_stalled_teams!` → `resolve_schedule_wedge!`)를
간격·예산·순서까지 **모든 팔에 동일하게** 걸고(`ZC_REFORM=400`, `ZC_REFORM_MAX=3`, 진전 시 예산 복구)
7팔 전부(3가족 × 2 + control)를 다시 돌린다 —
`oracle/run_zcausal_all.sh` → `out/zcausal_reform/`. 1차는 `out/zcausal/` 에 그대로 둔다.
2차가 답할 질문은 정확히 하나다:

> **복구 사다리로도 못 푸는 구역과, 사다리가 풀어 주는 구역이 갈리는가?**
> 갈린다면 그 경계가 곧 결정이고, `n_nav_blocked` 가 그 경계를 사전에 말해 주는지가 이 층의 값어치다.

### ★ 2차 (복구 사다리 ON, 모든 팔 동일) — **세 기준 전부 PASS**

`out/zcausal_reform/`, 채점 = `oracle/zcausal_report.py`.

| 가족 | 진단 | NOOP | RelocateBuild | 최선 |
|---|---|---|---|---|
| **blocking** (nav 목표 위) | root 0/8 · **nav_blocked 3** | stalled **254** (mk 117.3) | **complete 279** (mk 35.4) | **RelocateBuild** |
| **core zone** (root 목표) | root **8**/8 · nav_blocked 1 | stalled **232** (mk 132.8) | stalled **197** (mk 141.2) | **NOOP** |
| (control, 구역 없음) | — | complete 279 · mk **19.7** · reform 0 | | |

```
기준 (1) H(best|zone) = 1.000 bits   PASS      (분포: RelocateBuild 1, NOOP 1)
기준 (2) 동점률        = 0/2 = 0.0%  PASS
기준 (3) subopt_norm(closed): blocking·NOOP = 25 오답 / core·RelocateBuild = 35 오답
```

**STEP 6 이 실패했던 기준 (1)이 성립한다** — 같은 kind 안에서 정답이 뒤집히는 두 사건을 처음으로 만들었다.

### 정체의 귀속 — 상관이 아니라 인과

```
blk_noop:  reform 3회 전부 recover=no_team  wedge=not_applicable
           정체 시점 활성 EntityGo 6개 중 **이 구역이 막는 것 3개** (구역이 막는 노드 총 3개)
cov_noop:  reform 5회, 활성 8개 중 막는 것 1개
control:   reform 0회, 완주
```

멈춘 프론티어가 **곧 그 구역이 막는 집합**이다. 그리고 복구 사다리는 3회 모두 "손댈 팀이 없다"고
답했다 — 이건 팀 교착이 아니라 **기하적 봉쇄**라서 팀 복구로는 원리적으로 못 푼다. 그 구역을
치우는 유일한 수단이 공간형 팔이고, 실제로 `RelocateBuild` 가 완주를 되찾았다(254 → **279**).

### 두 규칙의 성적표 — 인과 규칙이 고친 것과 **아직 못 고친 것**

| 사건 | 실측 최선 | 커버리지 규칙 | 인과 규칙 |
|---|---|---|---|
| blocking (root 0, 막힘 3) | RelocateBuild | `:noop` ✗ (subopt_norm 25) | `:relocate_build` ✓ |
| core zone (root 8/8, 막힘 1) | NOOP | `:relocate_build` ✗ (subopt_norm 35) | `:relocate_build` ✗ |
| | | **0/2** | **1/2** |

인과 규칙은 **커버리지가 원리적으로 볼 수 없는 사건**(root_covered=0인데 실제로 막는 구역)을 고쳤다.
그러나 두 번째 줄에서 여전히 틀린다: core zone 은 nav 목표를 1개 막지만, 그걸 고치자고 빌드를
통째로 옮기면 **더 나빠진다**(232 → 197). 즉

> **막힘 > 0 은 개입의 필요조건이지 충분조건이 아니다.** 수복 자체의 파괴력이 함께 들어가야 한다.

이건 튜닝으로 덮을 문제가 아니라 다음 단계의 설계 문제다(막힌 노드 수 · 그 노드들이 잠그는 하류
작업량 vs 이동이 흩뜨리는 진행 중 작업량). 그래서 규칙은 **여전히 opt-in 으로 둔다** —
1/2 짜리 규칙을 기본으로 켜는 것은 정직하지 않다.

### `harmless` 가족은 만들지 못했다 (정직한 실패)

"커버리지 > 0, 막힘 = 0" 인 구역을 발화점(closed=58)에서 심으려 했으나 `status=no_target` —
그 시점의 **모든** 운동학 목표가 어떤 nav 목표의 배제원 안에 있었다(시뮬 전 env 에서는 여유 0.01 로
간신히 하나 있었다). 그러므로 그 가족은 이 세계·이 시점에서 구성되지 않는다.
이것도 결과다: **빌드가 진행될수록 커버리지와 막힘은 기하적으로 얽힌다.**

### 남은 한계 (다음 사람이 속지 않도록)

- **n = 2 사건, seed 1개, 발화점 1개(closed=58).** H=1.000 bits 는 "이 두 사건에서 답이 갈렸다"는
  뜻이지 분포에 대한 주장이 아니다. 통계를 붙이려면 seed·발화점·구역위치를 훑어야 한다.
- **`:disconnected` 는 아직 한 번도 실측에서 발화하지 않았다.** 두 사건 모두 `engulf` 로 잡혔다.
  통로 봉쇄 자체는 유닛테스트(고리 배치)에서만 확인됐다 — 실제 OOD 가족으로 만들려면 구역 **여러 개**를
  동시에 심어야 하고, 현재 주입기는 하나만 심는다.
- **인과 규칙은 2/2 가 아니라 1/2** (위 성적표). 기본은 계속 OFF.
- 라벨 파이프라인(`gen_oracle_dataset.jl` 의 행, `policy.jl::ood_features`)에는 아직 이 원시값을
  싣지 않았다. 특징 차원이 바뀌면 이미 export 된 서로게이트·novelty 교정과 호환이 깨지므로,
  STEP 3 이 zone 원시값을 다룬 것과 같은 방식(opt-in 열)으로 따로 붙여야 한다.

---

## 4. STEP 11 — 팀 술어의 인과 검증 (`tools/tests.jl zone_team_causal`) — **6/6 ALL GREEN**

계획서 3번: "슬롯이 덮였음은 증명했지만 그 팀이 **실제로 형성에 실패하는지**는 아직 아니다."

**설계**: 병렬 대조군이 아니라 **런 내 반전**(reversal). RVO 시뮬레이터와 id 맵이 전역이라
`deepcopy` 대조군은 모션 상태를 몰래 공유하고, 세계를 다시 지으면 이 런의 좌표를 재현하지 못한다.
그래서 같은 팀에 대해 `구역 ON → K 스텝` 과 `구역 OFF → 같은 K 스텝` 을 이어서 잰다.
제거가 형성을 복구시키면 바뀐 것은 구역뿐이므로 오히려 더 강한 증거다.
**nav 는 반드시 ON** — 구역 강제는 RVO 에이전트만 밀어내므로 `rvo_flag=false` 면 검사가 공허해진다.

```
대상 팀: ready=0 missing=2  gather=[1.302,-3.178]  slot_gap=2.119
진단:   teams_covered=1/5  nav_blocked=4(engulf=4)  trapped=1  verdict=relocate_build

[2] 구역 ON  1200 스텝 -> formed=false   slot_gap 2.119 -> 0.406   (빌드 자체는 진행: closed 51->151)
[3] 구역 OFF 같은 예산 -> formed=true    5 스텝 만에      gap -> 0.0
```

멤버들은 슬롯 **0.41 앞**(≈ 배제 반경 = 구역반지름 + 로봇반지름)에서 고정돼 있었고, 구역을 치우자
**5 스텝**만에 결합했다. 즉 이 팀은 "느렸던" 것이 아니라 **못 모였다**. 덤으로 특이성도 보인다:
같은 1200 스텝 동안 빌드 전체는 100 노드를 더 닫았다 — 이 구역은 빌드가 아니라 **그 팀**을 막았다.

이로써 커버리지 술어 중 **팀 슬롯 술어만은** 인과까지 확인됐다. 나머지(root 커버리지)는
0 장에서 본 대로 반대 방향의 답이 나왔다 — 같은 종류의 술어라도 결론이 갈린다는 뜻이고,
그래서 각각을 따로 재야 한다.

---

## 5. 다음에 할 일 (우선순위 순)

1. **개입의 비용을 규칙에 넣기.** 지금 인과 규칙은 1/2 다. 필요한 것은 임계값 튜닝이 아니라
   두 양의 비교다 — (a) 막힌 노드들이 잠그는 **하류 작업량**, (b) `translate_whole_build!` 가
   흩뜨리는 **진행 중 작업량**. (b) 는 이미 측정 가능하다(cov 가족: 232 → 197 = −35).
2. **다중 구역 주입기.** `:disconnected`(통로 봉쇄)는 구역이 하나면 무한 평면에서 원리적으로
   안 생긴다. 고리형(≥3개) 주입을 만들어야 그 가지가 실측에서 처음 발화하고, STEP 7 의
   `:line_stop` 게이트도 그때 비로소 의미를 갖는다.
3. **표본 확대.** seed × 발화점 × 구역위치 격자로 위 두 사건이 우연이 아님을 보이기
   (지금은 n=2, seed 1, 발화점 1).
4. **라벨·정책 경로에 원시값 싣기.** `gen_oracle_dataset.jl::capture_features` 와
   `policy.jl::ood_features` 에 `zone_nav_blocked` 계열을 STEP 3 과 같은 **opt-in 열**로.
   (특징 차원이 바뀌면 배포된 서로게이트·novelty 교정과 호환이 깨지므로 기본은 꺼짐.)
5. 라이브 데모(`render_demo.jl`)에서 새 원시값 + 게이트 실행 확인 — LLM 비용이 드는 유일한 항목.

## 6. 되돌리는 법

| 스위치 | 효과 |
|---|---|
| (기본) | 원시값만 실림. 판정·라벨·게이트는 STEP 1~7 과 **동일** |
| `ZONE_CAUSAL_RULE=1` | 개입 조건이 커버리지 → 막힘으로 바뀜 |
| `ZONE_CHECK_PATHS=1` | 통로(flood-fill) 검사까지 켬(기본은 engulf 만) |
| `zone_diagnosis(...; check_blockage=false)` | 막힘 계산 자체를 끔 → 새 열은 `-1` 센티넬 |
