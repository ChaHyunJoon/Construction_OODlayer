# zone 레인 50 시드 스윕 — 채점을 세 축으로 가르다

- **날짜** 2026-09-05
- **레인** 유료 3-agent 합성(포트 8077, `dspy:gpt-5.6-sol`), 세대 `00ca4e10a9b7afed`
- **코드** 커밋 `b8424635` (스윕 시작 전 커밋 완료)
- **명령** `DEMO_MODEL=tractor.mpd DEMO_OOD=none DEMO_ZONE=1 DEMO_POLICY=dspy DEMO_ZONE_SEED=1..50`
- **로그** `results/sweep50-z{1..50}.log` (gitignore 대상)
- **집계** `python3 tools/monitor/sweep50_tally.py` — 아래 수치는 **전부 그 출력을 붙인 것**이다(손으로 옮겨 적지 않았다)
- **비용** 3시간 29분, `/health` 의 `billed` 2 → 약 55

---

## 0. 이 스윕이 답한 것

직전 세션까지 zone 레인의 성적은 **완주율 하나**로 보고돼 왔다("존 랜덤화 8시드 6/8"). 이 스윕
직전에 오라클 픽스처 12판으로 그 지표가 **틀린 것을 재고 있었다**는 것이 밝혀졌다. 그래서 이번
스윕은 채점을 세 축으로 나누고, `render_demo.jl` 이 완주·미완주 **양쪽에서** 기계가 읽을 수 있는
`[score]` 한 줄을 찍도록 계측을 먼저 넣은 뒤에 돌렸다.

```
[score] complete=… closed=…  n_zones=…  n_blocked=…  n_engulfed=…
        n_agent_trapped=…  project_blocked=…
```

미완주 판은 `refusing to publish incomplete animation` 으로 죽으므로, 그 `error` **앞에** 찍히도록
위치를 잡았다. 안 그러면 실패 판의 점수가 통째로 사라진다.

## 1. 왜 완주율 하나로는 안 되는가 (선행 실측)

스윕 전에 오라클 픽스처로 z1 진리표를 닫았다. **공간수리 ⟺ 교착, 4/4 완전분리**(z3 재현):

| 판 | 공간수리(restage+translate) | 존 삭제 | 재풀이 | 결과 |
|---|---|---|---|---|
| z1-unw | ✅ | ❌ | ✅ | ❌ |
| z1-c1 | ✅ | ✅ | ✅ | ❌ |
| z1-c2 | ❌ | ✅ | ✅ | ✅ |
| z1-del | ❌ | ✅ | ❌ | ✅ |

재풀이 무죄(완주판에도 있다) · 존 잔존 무죄(지운 c1 도 언다). **남는 것은 수리뿐이다.**
그리고 얼어붙은 판에서 `zone_blockage` 는 매 발화마다 `n_blocked=0 project_blocked=false
blocked=[]` 였다 — **존은 이미 완전히 치워져 있었다.**

쐐기의 정체(`WEDGE_DEBUG=1`): 세 `FormTransportUnit`(v=24·31·56)이 전부 `DeliveryBot(6)`
한 대를 기다리고, 그 로봇의 `RobotGo v=220` 이 안 닫힌다. 한 대를 세 운반 자리에 동시에 못
놓으니 force-snap 이 매번 그 로봇을 자기 목표에서 떼어낸다(11대 ×8회).

어휘는 원인이 아니었다 — **여섯 칸 전부 소진**했다. 광고된 넷(`restage_all_blocked!` ·
`translate_whole_build!` · `reform_stuck_teams!` ×2)은 다 발화했고, 감춘 둘은 실패가 아니라
**부적용**이었다: `resolve_schedule_wedge!` = *"no serialization gates were ever recorded
(no spare Replace)"*, `force_advance_stuck_carrier!` = `:no_carrier`(활성 `TransportUnitGo`
0개). `CARRIER_RESCUE=1` 로 게이트를 풀어도 궤적이 **바이트 동일**했다. 설계 D6·S4·S5 의
은닉은 건드리지 않았다.

## 2. 50판 결과

**채점된 판 50**

| 축 | 결과 |
|---|---|
| ① 존이 치워졌나 | **44/50 (88%)** |
| ② 빌드가 완주했나 | **40/50 (80%)** |
| ③ tool 이 안 던졌나 | **30/50 (60%)** |

**예외 유형** {'eligible_successors(환각)': 11, '모델 자신의 단언': 7, 'NamedTuple 필드 없음': 2}
**재시도 결과** {'refused_world_changed': 11, 'retried': 9}
**무개입** [14, 31]   **존 남음(n_blocked>0)** [(14, '1', False), (30, '1', False), (31, '1', False), (33, '1', False), (45, '1', False), (48, '2', True)]   **갇힘** [(50, '1')]

### 미완주 10판 — 원인은 셋이다

| 시드 | closed | project_blocked | staged | retry | 원인 | 예외 |
|---|---|---|---|---|---|---|
| z1 | 185 | False | 8 | `n/a` | 세계 교착(수리 성공 후) | — |
| z3 | 185 | False | 8 | `n/a` | 세계 교착(수리 성공 후) | — |
| z11 | 193 | False | 8 | `refused_world_changed` | 환각 예외(회복 불가) | `MethodError: no method matching eligible_successors<::ConstructionBots` |
| z20 | 266 | False | 8 | `refused_world_changed` | 환각 예외(회복 불가) | `MethodError: no method matching eligible_successors<::ConstructionBots` |
| z24 | 175 | False | 8 | `n/a` | 세계 교착(수리 성공 후) | — |
| z34 | 267 | False | 8 | `n/a` | 세계 교착(수리 성공 후) | — |
| z39 | 165 | False | 0 | `retried` | 자기 단언 실패 | `type NamedTuple has no field n_nav_blocked` |
| z42 | 172 | False | 8 | `n/a` | 세계 교착(수리 성공 후) | — |
| z48 | 223 | True | 0 | `retried` | 자기 단언 실패 | `restaging did not clear all confirmed navigation or gathering-location` |
| z50 | 185 | False | 8 | `n/a` | 세계 교착(수리 성공 후) | — |

**정지점이 판마다 다르다**: 165 · 172 · 175 · 185×3 · 193 · 223 · 266 · 267.
성공한 판은 예외 없이 `closed=287/305` 다.

⟹ **모델 탓으로 돌릴 수 있는 미완주는 10판 중 4판뿐이다.** 완주율 80%를 합성 레인 성적으로
읽으면 6판을 잘못 뒤집어씌운다.

## 3. 축③이 가장 낮고, 원인이 하나로 몰린다

예외 20판 중 **11판이 같은 없는 함수 하나**에서 죽는다:

```
MethodError: no method matching eligible_successors(
    ::ScheduleNode{TemplatedID{Tuple{AssemblyComplete, AssemblyID}}, AssemblyComplete})
```

`eligible_successors` 는 `wm4spacecraft_manufacturing/core/world_interface.json` 에 **0건**이다 —
광고된 적이 없다. 게다가 실제 메서드는 `ConstructionPredicate` 를 받는데
(`src/construction_schedule.jl:318`) 모델은 껍데기 타입 `ScheduleNode` 를 넘긴다.
tool 이름은 매번 다른데(37개) **같은 없는 함수를 지어낸다** — 노드의 후행을 열거할 방법이
광고돼 있지 않기 때문이다.

### 회복 가능성을 가르는 것은 body 안의 위치다

| | `staged` | 재시도 |
|---|---|---|
| `eligible_successors` 11판 | **8** (이미 옮긴 뒤에 부른다) | **전부 `refused_world_changed`** |
| 나머지 9판 | **0** (바꾸기 전에 걸린다) | 전부 `retried` |

같은 "예외 1건"인데 하나는 **원천 회복 불가**다. 세계를 더럽힌 뒤에 환각을 부르면 되돌릴
방법이 없어 `/rewrite` 로 갈 자격 자체가 사라진다.

부수 확인: **`/rewrite` 라이브 왕복 9회.** 기존 기록의 *"배선했다는 작동한다가 아니다 —
라이브 왕복 0회"* 는 이 스윕으로 갱신됐다.

## 4. 그 밖에 관측된 것

- **무개입 완주 2판**(z14·z31): `lane=impl_name_nothing tool=no_intervention verdict=deferred`,
  `steps=[]`. 모델이 tool 을 아예 안 냈는데 완주했다. 그 존들은 애초에 완주를 안 막았을 수
  있다 — **처치 런만으로는 못 가른다.** 주입기의 게이트는 `n_blocked >= 1`(목표를 덮었나)인데
  그것은 `project_blocked`(프로젝트를 막았나)와 다르다. 가르려면 시드별 tool-off 대조가 필요하다.
- **`project_blocked=true` 는 z48 단 1판.** 모델의 tool 이 자기 사후조건에서 정직하게 걸렸고
  (*"restaging did not clear all confirmed navigation or gathering-location losses"*),
  `/rewrite` 까지 갔는데도 `n_staging_moved=0` — 세계를 하나도 못 바꿨다.
- **에이전트 갇힘 z50 1판**(`n_agent_trapped=1`). 이 스윕에서 처음 나온 값이다.
- **뒷문 재발 0건.** 커밋 `243c9d04` 이 지운 "비항행 배달" 기전이 신선한 생성 50회에서 한 번도
  안 돌아왔다. tool 이름 37개가 전부 `relocate_*` / `resite_*` / `retire_*` 계열이다.
- 새 기전 하나: z30 의 `retire_unreachable_nongating_navigation_goal` — 옮기는 대신 **가로막지
  않는 목표를 은퇴시킨다**. 실행은 실패했지만 설계 방향이 다른 첫 사례다.

## 5. 정정 (이 세션에서 내가 틀렸던 것)

1. **"존 랜덤화 6/8 완주"** — tool 성능이 아니었다. tool 은 8/8 존을 치웠고, 2판은 그 뒤 수리가
   만든 다른 교착으로 죽었다.
2. **"z14 는 수리가 불완전했는데도 완주했다"** — 수리가 **아예 없었다**(`no_intervention`).
3. **커밋 `b9111ca9`(완전성 플래그)이 `n_nav_blocked` 예외를 없앴다** — z1 한 시드에서 없어진
   것을 보고 부류가 없어졌다고 읽었다. 50판에서 **2판이 다시 그 예외로 죽는다.**
4. **"감춘 동사가 광고 구멍이다"** — `test/world_interface_current.jl` 의 testset (4)가 설계
   D6·S4·S5 로 **일부러** 감춘 것이다. 게다가 이 쐐기에는 **부적용**이라 광고해도 안 풀린다.

## 6. 열려 있는 것

- **`translate_whole_build!` 가 왜 얼리는가** — 운반유닛 겹침이 원래 있었나 평행이동이 만들었나.
  완주 판에서는 force-snap 이 안 나 `WEDGE_DEBUG` 덤프가 없다. 런 없이 계측 조건만 바꾸면 갈린다.
- **`eligible_successors` 광고 구멍** — 노드의 후행을 열거하는 콜러블이 없다. 다만 이 레포의
  기록(`prompt-asserts-consequences-the-world-lacks`)대로, **읽기만 넣으면 실패가 옮겨간다.**
  처방 동사가 있는지 먼저 재야 한다.
- **무개입 완주 2판이 진짜 사건이었는지** — 시드별 tool-off 대조가 있어야 갈린다(스윕 2배).

## 부록 — 전체 50판


| 시드 | 완주 | closed | n_blocked | engulfed | 예외 | 존 kind | r | nav_blocked | tool |
|---|---|---|---|---|---|---|---|---|---|
| z1 | ❌ | 185 | 0 | 0 | — | robot | 0.074 | 2 | `resite_unreachable_work` |
| z2 | ✅ | 287 | 0 | 0 | ⚠️ | transport | 0.088 | 2 | `relocate_blocked_navigation_goals` |
| z3 | ❌ | 185 | 0 | 0 | — | robot | 0.134 | 2 | `relocate_zone_blocked_destinations` |
| z4 | ✅ | 287 | 0 | 0 | ⚠️ | robot | 0.12 | 3 | `relocate_blocked_navigation_destinations` |
| z5 | ✅ | 287 | 0 | 0 | — | transport | 0.105 | 1 | `relocate_blocked_work_area` |
| z6 | ✅ | 287 | 0 | 0 | — | robot | 0.103 | 2 | `relocate_zone_blocked_destinations` |
| z7 | ✅ | 287 | 0 | 0 | ⚠️ | robot | 0.134 | 4 | `relocate_zone_blocked_geometry` |
| z8 | ✅ | 287 | 0 | 0 | — | robot | 0.05 | 2 | `relocate_blocked_navigation_goals` |
| z9 | ✅ | 287 | 0 | 0 | — | transport | 0.123 | 5 | `relocate_zone_blocked_work_areas` |
| z10 | ✅ | 287 | 0 | 0 | ⚠️ | transport | 0.061 | 1 | `relocate_blocked_work_area` |
| z11 | ❌ | 193 | 0 | 0 | ⚠️ | robot | 0.092 | 2 | `relocate_exclusion_blocked_work` |
| z12 | ✅ | 287 | 0 | 0 | ⚠️ | robot | 0.076 | 2 | `relocate_unreachable_work_geometry` |
| z13 | ✅ | 287 | 0 | 0 | — | robot | 0.147 | 3 | `relocate_unreachable_navigation_goals` |
| z14 | ✅ | 287 | 1 | 1 | — | robot | 0.088 | 1 | `no_intervention` |
| z15 | ✅ | 287 | 0 | 0 | ⚠️ | robot | 0.097 | 3 | `resite_unreachable_build_goals` |
| z16 | ✅ | 287 | 0 | 0 | — | transport | 0.11 | 1 | `restore_required_goal_reachability` |
| z17 | ✅ | 287 | 0 | 0 | — | robot | 0.058 | 2 | `relocate_unreachable_build_geometry` |
| z18 | ✅ | 287 | 0 | 0 | ⚠️ | robot | 0.143 | 3 | `relocate_blocked_navigation_geometry` |
| z19 | ✅ | 287 | 0 | 0 | — | robot | 0.131 | 3 | `relocate_blocked_goal_geometry` |
| z20 | ❌ | 266 | 0 | 0 | ⚠️ | robot | 0.092 | 2 | `relocate_unreachable_work_geometry` |
| z21 | ✅ | 287 | 0 | 0 | — | robot | 0.071 | 2 | `relocate_inaccessible_task_geometry` |
| z22 | ✅ | 287 | 0 | 0 | — | robot | 0.101 | 3 | `relocate_blocked_navigation_targets` |
| z23 | ✅ | 287 | 0 | 0 | — | robot | 0.074 | 2 | `relocate_blocked_work_geometry` |
| z24 | ❌ | 175 | 0 | 0 | — | robot | 0.142 | 2 | `relocate_blocked_scene_geometry` |
| z25 | ✅ | 287 | 0 | 0 | — | robot | 0.13 | 2 | `relocate_unreachable_goal_geometry` |
| z26 | ✅ | 287 | 0 | 0 | ⚠️ | robot | 0.149 | 1 | `relocate_blocked_navigation_goal` |
| z27 | ✅ | 287 | 0 | 0 | — | robot | 0.149 | 4 | `relocate_build_geometry_for_reachability` |
| z28 | ✅ | 287 | 0 | 0 | — | robot | 0.063 | 2 | `relocate_exclusion_blocked_work` |
| z29 | ✅ | 287 | 0 | 0 | — | transport | 0.146 | 5 | `resite_unreachable_build_geometry` |
| z30 | ✅ | 287 | 1 | 1 | ⚠️ | robot | 0.055 | 1 | `retire_unreachable_nongating_navigation_goal` |
| z31 | ✅ | 287 | 1 | 1 | — | robot | 0.05 | 1 | `no_intervention` |
| z32 | ✅ | 287 | 0 | 0 | — | transport | 0.148 | 1 | `relocate_zone_blocked_goal_geometry` |
| z33 | ✅ | 287 | 1 | 1 | ⚠️ | robot | 0.136 | 1 | `relocate_blocked_work_area` |
| z34 | ❌ | 267 | 0 | 0 | — | robot | 0.13 | 2 | `restore_required_goal_reachability` |
| z35 | ✅ | 287 | 0 | 0 | ⚠️ | robot | 0.11 | 3 | `relocate_blocked_build_geometry` |
| z36 | ✅ | 287 | 0 | 0 | ⚠️ | robot | 0.068 | 1 | `relocate_blocked_unfinished_work_area` |
| z37 | ✅ | 287 | 0 | 0 | — | robot | 0.12 | 4 | `relocate_zone_blocked_work_geometry` |
| z38 | ✅ | 287 | 0 | 0 | — | transport | 0.146 | 1 | `relocate_exclusion_blocked_work_geometry` |
| z39 | ❌ | 165 | 0 | 0 | ⚠️ | robot | 0.096 | 2 | `relocate_blocked_transport_formation` |
| z40 | ✅ | 287 | 0 | 0 | — | robot | 0.082 | 2 | `relocate_zone_blocked_work_geometry` |
| z41 | ✅ | 287 | 0 | 0 | — | robot | 0.114 | 2 | `relocate_zone_blocked_work_geometry` |
| z42 | ❌ | 172 | 0 | 0 | — | robot | 0.105 | 2 | `relocate_unreachable_scene_goals` |
| z43 | ✅ | 287 | 0 | 0 | ⚠️ | transport | 0.068 | 1 | `relocate_blocked_navigation_goal` |
| z44 | ✅ | 287 | 0 | 0 | ⚠️ | robot | 0.124 | 3 | `relocate_blocked_goal_geometry` |
| z45 | ✅ | 287 | 1 | 1 | ⚠️ | robot | 0.079 | 1 | `retire_stranded_navigation_leaf` |
| z46 | ✅ | 287 | 0 | 0 | — | robot | 0.116 | 2 | `relocate_blocked_unfinished_geometry` |
| z47 | ✅ | 287 | 0 | 0 | — | robot | 0.106 | 2 | `restore_blocked_navigation_geometry` |
| z48 | ❌ | 223 | 2 | 2 | ⚠️ | robot | 0.12 | 2 | `relocate_unreachable_worksites` |
| z49 | ✅ | 287 | 0 | 0 | ⚠️ | robot | 0.073 | 2 | `restore_exclusion_blocked_goal_reachability` |
| z50 | ❌ | 185 | 0 | 0 | — | robot | 0.152 | 2 | `relocate_zone_blocked_destinations` |
