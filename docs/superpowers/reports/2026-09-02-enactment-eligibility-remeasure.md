# 재측정 — 집행 자격 게이트를 body 실측으로 바꾼 뒤 (T5)

- 레포/브랜치: `/home/chahj578/Construction_OODlayer` · `oracle-rebuild-night-2026-08-10`
- 측정 시점 HEAD: `9006bdcd` (T0.5·T1·T2·T3+4 가 이미 커밋된 상태)
- 날짜: 2026-09-03
- 🔴 이 태스크는 **재는** 태스크다. 소스도 시험도 편집하지 않았고, 커밋은 이 파일 하나뿐이다.
- 실행기: 이 머신의 기본 `julia` = **1.10.11** (`julia +lts` 와 같은 바이너리, `Manifest.toml` 핀과 일치).
  브리핑이 적은 `julia --project` 형태를 그대로 썼다 — 레포 규약인 `julia +lts --project=.` 은
  같은 인터프리터를 가리키지만, **어느 형태를 썼는지는 이 줄이 진실원이다.**

---

## S1 비퇴화 — 두 팔이 verdict 만 다른가

명령 (브리핑 그대로):

```bash
cd /home/chahj578/Construction_OODlayer
julia --project tools/probes/probe_cargo_ban_end_to_end.jl colored_8x8.ldr 6 60 2>&1 | tail -80
```

⚠️ **브리핑의 인자 설명이 틀렸다.** 브리핑은 세 번째 인자를 "시간제한" 이라고 적었지만
프로브의 실제 파싱은 `target_closed` 다(`probe_cargo_ban_end_to_end.jl:522-524`,
`[board] [nrobots] [target_closed]`). 즉 `60` 은 초가 아니라 **닫아야 할 노드 수**다.
프로브는 `closed 도달값 = 62 (target = 60, steps = 95)` 를 찍었다.
전체 프로브는 **한 번에 완주**했으므로 더 작은 판으로 재시도할 필요가 없었다(600000ms 안).

### 절 A 요약표 — 원문 그대로

```
============================================================================================
절 A 요약 — G-8: body 가 집행되고 하네스가 그것을 기록한다
🔴 `간선 전/후` 가 **같아지는 것이 정상**이다(재풀이). release 의 크기는 그 옆 칸이다.
============================================================================================
판               closed  verdict  applied  resume   resolve     release 보고 간선 전/후   금지 전/후  sanctioned  threw  판정
colored_8x8.ldr  62      admit    true     issued   resolved    11           68→68        0→1         true        0      OK
colored_8x8.ldr  62      admit_unsanctionedtrue     issued   resolved    11           68→68        0→1         false       0      OK
```

(표의 둘째 행은 `admit_unsanctioned` 가 열 폭을 넘겨 `true` 와 붙어 찍힌다 — 원문 그대로 옮겼다.
정렬 결함이지 값 결함이 아니다: 아래 세부 출력이 같은 값을 따로 찍는다.)

### 갈린 열

**verdict 와 sanctioned 둘뿐이다.**

| 열 | composed 팔 | needs_primitive 팔 | 갈렸나 |
|---|---|---|---|
| closed | 62 | 62 | 같다 |
| verdict | `admit` | `admit_unsanctioned` | 🔴 **갈렸다(설계)** |
| applied | true | true | 같다 |
| resume | issued | issued | 같다 |
| resolve | resolved | resolved | 같다 |
| release 보고 | 11 | 11 | 같다 |
| 간선 전/후 | 68→68 | 68→68 | 같다 |
| 금지 전/후 | 0→1 | 0→1 | 같다 |
| sanctioned | true | false | 🔴 **갈렸다(설계)** |
| threw | 0 | 0 | 같다 |
| 판정 | OK | OK | 같다 |

⟹ **비퇴화 조건 충족.** 자기신고 문자열 하나(`reach`)와 그것이 유도하는 두 열
(`verdict`·`sanctioned`, 그리고 `reason` 의 꼬리 문장) 말고는 아무것도 달라지지 않았다.

### 세부 출력 — 두 팔의 전문 (원문)

`reach = composed`:

```
closed 도달값 = 62  (target = 60, steps = 95)
BATTERY_FLEET[] = installed
target agent = ConstructionBots.BotID{ConstructionBots.DeliveryBot}(1)   (최댓값 동점 = 3)
집행 전: 배정 간선 = 68 · STANDING_CARGO_BANS[] = 비었다
verdict = admit   applied = true   partial = false   world_maybe_dirty = true
resume = issued   resolve = resolved
reason = body of 2 primitives [resume=issued: 자체 재개 안 하는 원시가 세계를 건드려 reset_cache_resume! 를 한 번 불렀다] [resolve=resolved: n_reassigned=47]
sanctioned = true   threw = 0
steps (2):
   · release_pending_assignments  status=released  detail=released=11
   · forbid_heavy_cargo  status=banned  detail=
release 자체보고(뗀 간선) = 11
배정 간선 전/후 = 68 / 68   🔴 되돌아오는 것이 **정상**이다 — 재풀이가 뜬 슬롯을 다시 붙인다(머리말 (12))
STANDING_CARGO_BANS[] 전/후 = 비었다 / ["ConstructionBots.BotID{ConstructionBots.DeliveryBot}(1)"]
금지 대상이 A 인가 = true
```

`reach = needs_primitive`:

```
closed 도달값 = 62  (target = 60, steps = 95)
BATTERY_FLEET[] = installed
target agent = ConstructionBots.BotID{ConstructionBots.DeliveryBot}(1)   (최댓값 동점 = 3)
집행 전: 배정 간선 = 68 · STANDING_CARGO_BANS[] = 비었다
verdict = admit_unsanctioned   applied = true   partial = false   world_maybe_dirty = true
resume = issued   resolve = resolved
reason = body of 2 primitives [resume=issued: 자체 재개 안 하는 원시가 세계를 건드려 reset_cache_resume! 를 한 번 불렀다] [resolve=resolved: n_reassigned=47] — 🔴 unsanctioned(reach=needs_primitive, missing=n/a): 모델은 부족하다고 했는데 body 는 조합돼 있어 굴렸다
sanctioned = false   threw = 0
steps (2):
   · release_pending_assignments  status=released  detail=released=11
   · forbid_heavy_cargo  status=banned  detail=
release 자체보고(뗀 간선) = 11
배정 간선 전/후 = 68 / 68   🔴 되돌아오는 것이 **정상**이다 — 재풀이가 뜬 슬롯을 다시 붙인다(머리말 (12))
STANDING_CARGO_BANS[] 전/후 = 비었다 / ["ConstructionBots.BotID{ConstructionBots.DeliveryBot}(1)"]
금지 대상이 A 인가 = true
```

`n_reassigned=47` 까지 두 팔이 바이트 동일이다 — 재풀이가 같은 argmin 을 통과했다는 뜻이다.

### 공허(VOID) 판정

**어느 행도 `steps` 가 비지 않았다** (두 행 모두 `steps (2)`, 둘 다 non-`:threw` status).
따라서 `⚪ VOID` 는 찍히지 않았고, 찍힐 조건 자체가 없었다 — "VOID 가 GREEN/RED 보다 먼저
찍혔는가" 는 이 실행에서 **적용되지 않는다**(공허가 아니었다). VOID 배선 자체의 정확성은
이 실행이 판정하지 못한다.

### 곁다리 — 절 B (인과)

이 태스크의 질문은 아니지만 같은 실행에서 나왔으므로 기록한다:

```
판               뗀슬롯  ncand  금지행  표적    대조 잃음 처리 잃음 차집합      판정
colored_8x8.ldr  11      174    6       278     0         1         [278]       GREEN
```

`금지행 = 6 ≠ 0` 이므로 공허가 아니고, 음성 대조(0)와 처리(1)가 갈렸다.

---

## S2 R1 숫자 — 인자를 잘못 채운 body 가 집행부에 닿을 때

브리핑의 스크립트를 **한 글자도 안 바꾸고** 파일로 저장해 돌렸다
(`-e '...'` 대신 스크립트 파일 — 인용부호 이스케이프를 피하려는 것뿐, 코드는 동일).

### 출력 전문 (여섯 행)

```
composed        forbid_heavy_cargo, agent 없음         verdict=admit                threw=0 partial=false dirty=false handled=false steps=[("forbid_heavy_cargo", :missing_agent)]
composed        release_pending, faulted+agent 동시    verdict=admit                threw=0 partial=false dirty=false handled=false steps=[("release_pending_assignments", :both_scopes)]
composed        forbid_heavy_cargo, 틀린 agent         verdict=admit                threw=0 partial=false dirty=false handled=false steps=[("forbid_heavy_cargo", :unknown_agent)]
needs_primitive forbid_heavy_cargo, agent 없음         verdict=admit_unsanctioned   threw=0 partial=false dirty=false handled=false steps=[("forbid_heavy_cargo", :missing_agent)]
needs_primitive release_pending, faulted+agent 동시    verdict=admit_unsanctioned   threw=0 partial=false dirty=false handled=false steps=[("release_pending_assignments", :both_scopes)]
needs_primitive forbid_heavy_cargo, 틀린 agent         verdict=admit_unsanctioned   threw=0 partial=false dirty=false handled=false steps=[("forbid_heavy_cargo", :unknown_agent)]
```

### 합계

| 항목 | 값 |
|---|---|
| `threw` 합계 (여섯 행) | **0** |
| `handled == true` 행 수 (여섯 행) | **0** (여섯 행 전부 `handled=false`) |
| `needs_primitive` 팔의 verdict | 세 행 전부 `admit_unsanctioned` ✅ |

⟹ **R1 수선은 잰 만큼 성립한다.** 여섯 행 전부에서 예외가 하나도 안 났고(`threw=0`),
여섯 행 전부에서 `handled=false` 다.

🔴 **`handled=false` 를 무엇이 만드는지는 반드시 같이 읽어야 한다.** verdict 는 여섯 행 모두
`ENACTED_VERDICTS` 안에 있으므로 첫 연언지 `CB.minted_handled_verdict_ok(verdict)` 는 **참**이다.
`handled` 를 거짓으로 만드는 것은 **두 번째 연언지 `world_maybe_dirty` 뿐이다**(여섯 행 모두
`dirty=false`). 즉 이 여섯 행이 지키는 성질은 "세계를 안 건드린 판은 폴백을 삼키지 않는다" 이고,
그것을 나르는 값은 verdict 가 아니라 **`world_maybe_dirty`** 다. verdict 로 막힌 것이 아니다 —
게이트가 넓어졌으므로(T2) 이 자리를 지키는 것은 이제 status → `WORLD_UNCHANGED_STATUSES`
경로 하나뿐이다.

그 첫 연언지가 참이라는 것은 **추론이 아니라 실측**이다:

```
ENACTED_VERDICTS = (:admit, :admit_unsanctioned)
admit -> minted_handled_verdict_ok = true
admit_unsanctioned -> minted_handled_verdict_ok = true
```

세 status 는 전부 T0.5(`bab8d572`)가 예외에서 갈아 끼운 것들이다:
`:missing_agent` · `:both_scopes` · `:unknown_agent`.

---

## S3 전체 스위트

### 어떻게 쟀는가 — 🔴 한 번에 못 쟀다

먼저 브리핑 그대로:

```bash
cd /home/chahj578/Construction_OODlayer
julia --project -e 'include("test/runtests.jl")'
```

**Bash 타임아웃 600000ms(10분)를 넘겼다.** 10분 시점에 SIGTERM 을 받았고, 마지막으로 살아 있던
자리는 `test/cargo_ban_lifetime.jl:58` 이었다(44개 최상위 testset 중 41번째). 최상위 `@testset`
하나가 전부를 감싸고 있어서 **부분 요약이 하나도 안 찍혔다** — 이 실행에서 건진 수치는 0 이다.

그래서 브리핑의 대안대로 **파일 단위로 쪼개 돌렸다.** `test/runtests.jl` 의 본문은 들여쓰기 4의
최상위 `@testset` 44개가 **끊김 없이 이어진 것뿐**이고 그 사이에 공유 설정 코드가 없다(실측).
그래서 원본의 머리말(`using` 들 + `array_isapprox` + `global_logger`)에 44개 블록 중 일부를
붙여 다섯 조각을 만들고 각각 새 프로세스로 돌렸다.
🔴 **원본 파일은 편집하지 않았다** — 조각은 전부 스크래치패드에 있고, 안의 상대 `include("x.jl")`
와 `@__DIR__` 를 `/home/chahj578/Construction_OODlayer/test` 절대경로로 치환해 해석을 원본과
같게 맞췄다. 실행 순서도 원본 순서 그대로다.

| 조각 | 담은 최상위 testset | 벽시계 |
|---|---|---|
| A | 0–3 (IDs · Potential Fields · Twist · Demo) | 148s |
| B | 4–17 (OOD keys ~ lane selection) | 300s |
| C | 18–32 (SMDP ~ minted tool wiring) | 63s |
| D | 33–38 (policy oracle ~ ForbidHeavyCargo) | 316s |
| E | 39–43 (cargo ban store ~ abstractid content hash) | 305s |

합 ≈ 1132s ≈ 19분(조각마다 로드·컴파일 비용을 다시 낸다).
⚠️ **한 프로세스가 아니므로 전역 상태가 조각 경계에서 초기화된다.** `Pkg.test()` 한 판과
바이트 동치가 아니다 — 아래 "전역 오염 대조" 가 그 위험을 부분적으로만 덮는다.

### 조각별 요약 (원문)

```
--- A ---
Test Summary:                    | Pass  Error  Total     Time
ConstructionBots Tests [chunk A] |   11      1     12  2m18.0s
--- B ---
Test Summary:                    | Pass  Total     Time
ConstructionBots Tests [chunk B] |  809    809  4m50.2s
--- C ---
Test Summary:                    | Pass  Total   Time
ConstructionBots Tests [chunk C] | 1618   1618  54.1s
--- D ---
Test Summary:                                              | Pass  Fail  Total     Time
ConstructionBots Tests [chunk D]                           |  138     2    140  5m03.2s
--- E ---
Test Summary:                    | Pass  Total     Time
ConstructionBots Tests [chunk E] |  302    302  4m56.0s
```

### 합계 — 이 작업 트리, 2026-09-03, HEAD `9006bdcd`

**2878 pass · 2 fail · 1 error · 2881 total.**

🔴 이 숫자를 다른 세션의 값과 비교해 "회귀" 라고 쓰지 마라. CLAUDE.md 의 기대 baseline
(2212 pass / 0 fail / 1 error, `013969da`)은 자릿수 감각용이고, 이 작업 트리는 미커밋 삭제
231건을 안고 있어 깨끗한 HEAD 와 통과 수가 갈린다(선행 세션 실측: 작업트리 2539/0fail 대
깨끗한 HEAD 2305/4fail/2err, 격차 미해명). **유효한 값은 위 표뿐이다.**

### 실패 셋 — 파일·testset 이름과 귀속

#### (1) `Demo` — Gurobi 라이선스 (error 1건) · **이 레인과 무관**

```
Demo: Error During Test at .../chunk_A.jl:83
  Got exception outside of a @test
  LoadError: Gurobi Error 10009: No Gurobi license found (user chahj578, host bethpage, hostid 1357fbd, cores 28)
```

귀속: **환경 결함, 이 레인 무관.** 근거는 추측이 아니다 — 예외가 `Gurobi.Env` 생성자
(`Gurobi/K2XSK/src/MOI_wrapper/MOI_wrapper.jl:176`)에서 나며 이 레인이 만진 여섯 파일 중
어느 것도 스택에 없다. CLAUDE.md 도 같은 error 를 "변경과 무관한 기대 baseline" 으로 적는다.

#### (2)(3) `test/scoped_release.jl` 2건 — 🔴 **이 레인 탓, T6 이 처리 예정**

testset 경로:
- `scoped release` → `faulted 와 agent 를 둘 다 주면 ArgumentError` (`scoped_release.jl:164`)
- `scoped release` → `agent 가 스케줄에 없는 이름일 때` → `🔴 해저드가 닫혔다 — 두 status 가 _step_touched_world 에서 갈린다` (`scoped_release.jl:222`)

원문:

```
faulted 와 agent 를 둘 다 주면 ArgumentError: Test Failed at /home/chahj578/Construction_OODlayer/test/scoped_release.jl:164
  Expression: CB.release_pending_assignments!(e, inv; faulted = CB.RobotID(1), agent = a)
    Expected: ArgumentError
      Thrown: MethodError
```

```
🔴 해저드가 닫혔다 — 두 status 가 _step_touched_world 에서 갈린다: Test Failed at /home/chahj578/Construction_OODlayer/test/scoped_release.jl:222
  Expression: CB.WORLD_UNCHANGED_STATUSES["release_pending_assignments"] == Set([:unknown_agent])
   Evaluated: Set([:unknown_agent, :both_scopes]) == Set([:unknown_agent])
```

귀속 근거(추측 아님):
- `:both_scopes` 심볼을 도입한 커밋은 `git log -S both_scopes -- src/ tools/` 로 **한 건**이고
  그것이 이 레인의 T0.5 = `bab8d572` "R1(B): 인자 오류는 예외가 아니라 status 다" 다.
- :164 는 옛 계약(예외)을 단언하는데 T0.5 가 예외를 status 로 바꿨다. 지금 나오는 MethodError 는
  그 새 반환 경로 안의 `String(faulted)` 때문이다 — `faulted` 가 `RobotID` 라 `String` 메서드가
  없다. 위치는 **`src/respec/reassign.jl:204`** 다(브리핑은 `:203` 이라고 적었다 — 한 줄 어긋난다).
- :222 는 `WORLD_UNCHANGED_STATUSES["release_pending_assignments"]` 가 `{:unknown_agent}` 라고
  단언하는데, T0.5 가 `src/respec/minted_tool.jl:402` 에서 그 집합에 `:both_scopes` 를 더했다.

⟹ 둘 다 **이 레인이 만든 알려진 결함**이고, 컨트롤러의 지시대로 이 태스크는 고치지 않았다.
**T6 이 처리한다.**

#### 전역 오염 대조 (컨트롤러 지시)

`test/scoped_release.jl` 을 원본 머리말만 얹어 **단독 프로세스**로 다시 돌렸다:

```
Test Summary:                                          | Pass  Fail  Total     Time
scoped release (solo)                                  |   36     2     38  2m04.9s
```

같은 두 실패가 같은 줄(:164, :222)에서 같은 메시지로 재현된다.
⟹ **"스위트에서만 빨간" 종류가 아니다.** 전역 오염이 아니라 코드 계약 불일치다 — 위 귀속을 강화한다.

#### 그 밖의 실패

**없다.** 나머지 42개 최상위 testset 은 fail 0 · error 0 이다.

---

## 예상치 못한 것

1. 🔴 **브리핑의 프로브 인자 설명이 틀렸다.** 세 번째 인자는 시간제한이 아니라 `target_closed` 다.
   "60초" 로 읽고 시간 예산을 세우면 틀린다.
2. 🔴 **전체 스위트가 10분 안에 안 끝난다.** 브리핑은 그 가능성만 적었는데 실제로 넘겼고,
   최상위 `@testset` 하나가 전부를 감싸는 구조 때문에 **중단된 실행은 수치를 하나도 안 남긴다.**
   이 레포에서 전체 스위트를 재는 사람은 반드시 쪼개야 한다(또는 부분 요약이 찍히게 해야 한다).
3. **브리핑의 줄번호가 한 줄 어긋났다** — `String(faulted)` 는 `reassign.jl:203` 이 아니라 `:204` 다.
   (CLAUDE.md 가 이미 경고하는 실패 모드다: 이 레포에서 줄번호는 조용히 낡는다.)
4. **절 A 요약표의 정렬이 깨져 있다** — `admit_unsanctioned` 가 열 폭(rpad)을 넘어 다음 열
   `true` 와 붙어 찍힌다. 값은 맞지만 **표를 기계로 파싱하면 틀린다.** T2 가 verdict 를 길게
   만들면서 생긴 부수효과다.
5. **`handled=false` 를 만드는 것은 verdict 가 아니라 `world_maybe_dirty` 다**(S2 절 참조).
   R1 방어선이 실제로 어디에 서 있는지가 브리핑의 서술과 다르다 — 브리핑은 여섯 행의
   `handled=false` 를 "R1 수선의 전부" 라고 부르지만, 그 값을 내는 연언지는 하나뿐이다.
6. **작업 트리의 미커밋 삭제는 231건**이다(`git status --porcelain | wc -l`). 브리핑·메모리가
   적는 218/219 보다 늘었다.

---

## 우려

- **S3 를 한 프로세스로 재지 못했다.** 다섯 조각은 조각 경계에서 전역이 초기화되므로
  `Pkg.test()` 한 판과 동치가 아니다. 순서 의존·전역 누수로만 나는 실패는 이 방식으로
  **못 볼 수 있다**(CLAUDE.md 가 실측으로 적는 `SPARE_POOLS[:east]` 종류). 반대 방향의 위험은
  없다 — 이 방식으로 **본** 실패 2건은 단독 재현으로 확인했다.
- **VOID 배선은 이번에 시험되지 않았다.** 두 행 모두 `steps` 가 비지 않아 `⚪ VOID` 경로가
  한 번도 안 탔다. T3+4 가 넣은 그 판정의 정확성은 이 측정이 뒷받침하지 않는다.
- **S1 은 판 하나(colored_8x8.ldr / 6대 / closed 62)뿐이다.** 비퇴화는 이 한 판에서만 참으로
  측정됐다.
