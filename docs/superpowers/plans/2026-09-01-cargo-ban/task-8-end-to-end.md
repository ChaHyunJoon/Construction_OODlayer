# Task 8 — 종단: body 가 집행되고 **세계가 움직이는지**

> **선행:** Task 2 ~ 7 전부.

## 재는 것

L2 가 주조할 도구의 body 는 이것이다:

```
1. release_pending_assignments(agent="…")
2. forbid_heavy_cargo(agent="…", n=1)
```

🔴 **반환 심볼은 증거가 아니다.** `:admit` 과 `handled=true` 는 장부일 뿐이다. 세계를 직접
양쪽에서 재라. 본보기가 이미 있다: `tools/probes/probe_minted_body_enacts.jl` 이
`release_pending_assignments` + `reprice_agent_by_payload` body 에 대해 정확히 그렇게 한다
(배정 간선 68 → 0, 훅 nothing → installed). **그 파일을 복사해서 고쳐라.**

## Files

- Create: `tools/probes/probe_cargo_ban_end_to_end.jl`
- Create: `test/cargo_ban_moves_work.jl` (G-2 를 게이트로)
- Modify: `test/runtests.jl`

## G-2 — 그 로봇이 **실제로** 화물을 잃는가

```julia
@testset "🔴 G-2 금지된 로봇이 그 화물을 실제로 잃는다" begin
    env = fixture(); a = busiest_pending_agent_string(env)

    before = deepcopy(CB.simstate_of(env).g.binding)

    # (대조) 금지 없이: release + 재풀이 → 그 로봇이 자기 화물을 회수한다
    # (처리) 금지 걸고: release + 재풀이 → 그 화물이 남에게 간다
    #
    # 🔴 대조를 반드시 함께 재라. 처리만 재면 "원래 안 가져갔다" 와 구별이 안 된다.
    #    실측 참고: 금지 없이 풀면 대상 로봇이 자기 슬롯을 **전부 회수했다**(5/5, 3/3).

    @test lost_by_agent_control   == 0        # 대조: 안 잃는다
    @test lost_by_agent_treatment >  0        # 🔴 처리: 실제로 잃는다
end
```

⚠️ **`makespan(env.sched)` 을 판정에 쓰지 마라.** `probe_can_a_be_displaced.jl` 에서 그 값이
10012 / 14.55 를 오가는 센티넬(시간이 안 박힌 노드)로 나왔다. 믿을 값은 **증명된 최적 목적값**과
**배정(`binding`)** 이다.

## G-8 — body 가 집행되고 세계가 움직인다

프로브가 찍어야 하는 것:

| 항목 | 기대 |
|---|---|
| `enact_minted!` 의 `verdict` | `:admit` |
| `steps` | 2개, 각각 읽을 수 있는 status |
| 배정 간선 수 (전/후) | 줄어든다 (release 가 실제로 뗐다) |
| `STANDING_CARGO_BANS[]` (전/후) | 비었다 → 항목 1개 |
| 재풀이 후 그 로봇이 잃은 작업 | **> 0** |
| 재풀이 종료 상태 | `OPTIMAL` (좁힌 release 라면 0.2초대여야 한다) |

🔴 **`n_reassigned` 만 보고 성공이라 하지 마라.** 그건 "뭔가 바뀌었다" 이지 "그 로봇이 그 화물을
잃었다" 가 아니다. 실측에서 `n_reassigned` 이 11 인데 대상 로봇이 잃은 작업은 **0** 인 판이
여러 번 나왔다.

## 두 판에서 돌린다

`tractor.mpd`(10대)와 `colored_8x8.ldr`(6대).

⚠️ **colored_8x8 은 화물 부담 고유값이 2개뿐**이다(2.2938×96 팀2, 15.7286×3 팀4). "상위 N" 이
거의 임의로 갈릴 수 있으니, 그 판에서 효과가 약해도 그것 자체는 결함이 아니다. tractor 는
고유값 15개(0.328 … 12.8)라 차등이 뚜렷하다. **두 판의 결과를 각각 기록하라.**

- [ ] **Step 1: 프로브를 쓴다** (`probe_minted_body_enacts.jl` 을 복사해 body 를 바꾼다)
- [ ] **Step 2: 두 판에서 돌리고 표를 채운다**
- [ ] **Step 3: G-2 게이트 시험을 쓰고 통과시킨다**
- [ ] **Step 4: 전체 시험** — 기준선 2279 / 0 fail / 1 error (+ 새 시험만큼 증가)
- [ ] **Step 5: 커밋**
- [ ] **Step 6: 결과를 이 파일 아래에 기록한다**

---

## 결과 — 측정 후 여기에 적는다

> 측정: `tools/probes/probe_cargo_ban_end_to_end.jl` · 2026-09-02 · 브랜치
> `oracle-rebuild-night-2026-08-10`, HEAD `7074be8e`(작업 트리에 다른 레인의 미커밋 변경 있음).
> 🔴 삼상 규약: `nothing` = 못 쟀다(**0 이 아니다**). `closed` 는 **실제 도달값**이다.
> 🔴 판정은 `binding` 이 아니라 **`JuMP.value(Xa[u,v2]) > 0.5` + 음성 대조**다(S-4.4 가 계획서의
> G-2 스케치를 뒤집었다). 두 팔은 **같은 env·같은 그래프**를 보고 `commit_respec!` 을 **한 번도
> 안 부른다** — 다른 것은 `STANDING_CARGO_BANS[]` 하나뿐이다. fork 도 하지 않는다(S-4.7).
> 🔴 **절대 정점번호·행 수·목적값은 패키지 재컴파일마다 갈린다**(§"재현성" 참조). 인용은
> **대조 대비 처리**의 차이로만 하라.

### G-8 — body 가 집행되고 세계가 움직인다

| 판 | closed | verdict | 간선 전/후 | 금지 전/후 | 그 로봇이 잃은 작업 | 재풀이 종료/시간 |
|---|---|---|---|---|---|---|
| tractor.mpd (10대) | **60** | `:admit` | **43 → 38** (뗀 5) | 0 → **1** | **1** — 뗀 슬롯 5 중 회수 4, 잃은 것은 **표적 화물 하나** | `OPTIMAL` / **0.228s** |
| colored_8x8.ldr (6대) | **62** | `:admit` | **68 → 57** (뗀 11) | 0 → **1** | **1** — 뗀 슬롯 11 중 회수 10, 잃은 것은 **표적 화물 하나** | `OPTIMAL` / **0.224s** |

**대조(금지 없음)에서 그 로봇이 잃은 작업: 0 · 0** — tractor 5/5, colored_8x8 11/11 **전부 회수**.
대조도 `OPTIMAL`(0.939s / 0.230s). ⚠️ 이 `0` 은 **깨끗한 프로세스**의 값이다 —
`Pkg.test()` 안에서는 대조가 표적이 **아닌** 슬롯 하나를 잃었다(아래 "재현성").

**처리가 대조보다 추가로 잃은 슬롯** = tractor `[293]` · colored_8x8 `[278]` — **각각 정확히
표적 화물 하나**이고, `대조 잃음 ⊆ 처리 잃음` 이 두 판 모두 참이다. 이것이 이 태스크의 판정이다.

**steps (둘 다 2개, 읽을 수 있는 status):**

| 판 | step 1 | step 2 |
|---|---|---|
| tractor | `release_pending_assignments` `:released` `detail=released=5` | `forbid_heavy_cargo` `:banned` `detail=`(빈 문자열) |
| colored_8x8 | `release_pending_assignments` `:released` `detail=released=11` | `forbid_heavy_cargo` `:banned` `detail=`(빈 문자열) |

`applied=true` · `partial=false` · `world_maybe_dirty=true` · `resume=:issued`.
⚠️ `forbid_heavy_cargo` 의 `detail` 이 **빈 문자열**인 것은 결함이 아니다 — `_step_detail` 이
NamedTuple 에서 `(:moved,:failed,:removed,:residual,:delta)` 만 찍는데 이 원시 반환에는 그 필드가
없다. 이 원시의 관측량은 `status` 와 보관소 내용물이다.

**금지가 실제로 건 행 수**(같은 그래프에서 두 팔의 제약 행 수 차): tractor **4 행**
(49445 → 49449) · colored_8x8 **5 행** (62012 → 62017). 🔴 0 이면 공허했다.
후보 간선 수는 두 팔이 같다(tractor 82 · colored_8x8 180) — 대조가 성립한다는 구조 증거다.
표적 화물 `v2`: tractor **293** · colored_8x8 **278**. **대조는 그 표적을 집고(각 1 간선)
처리는 안 집는다(0 간선).**

목적값(🔴 **네 행 다 `OPTIMAL` 이라 인용 가능한 자리다** — S-4.5 의 금지는 `TIME_LIMIT` 행에 대한
것이다): tractor 12.5515 → 12.5529(**+0.012%**) · colored_8x8 36.9813 → 36.9829(**+0.0044%**).
⟹ **금지의 대가는 목적값 소수점 이하**다.

### 🔴 부담 동점 구조 — 계획서의 숫자와 **다르다.** 재서 적는다

**표적 로봇이 소유한 후보 도착점**(= `_heavy_cargo_targets` 가 실제로 정렬하는 집합) 위의 1대당 부담:

| 판 | 표적 로봇 | 후보 도착점 | 부담 잰 비율 | 고유값 | 최댓값 동점 | 범위 | 히스토그램 |
|---|---|---|---|---|---|---|---|
| tractor | `BotID{DeliveryBot}(2)` | 5 | **5/5 = 1.0** | **5** | **1** | [0.3277, 2.7884] | 2.788434, 1.05168, 0.9743, 0.49152, 0.32768 (각 ×1) |
| colored_8x8 | `BotID{DeliveryBot}(1)` | 11 | **11/11 = 1.0** | **1** | **11** | [1.1469, 1.1469] | 1.14688 × 11 |

🔴 **계획서의 "colored_8x8 은 고유값 2개(2.2938×96, 15.7286×3), tractor 는 15개(0.328…12.8)" 는
우리 실측과 맞지 않는다 — 인용하지 말 것.** colored_8x8 은 **전부 동점(고유값 1개)** 이다
(Task 1 의 S-4.6 실측과 같은 방향). 가장 그럴듯한 원인: 계획서 숫자는 **판 전체 화물**을, 이 표는
**그 로봇이 소유한 후보 도착점**만 센다(96/3 대 11 이라는 크기 차이가 그것을 보여 준다).
`_heavy_cargo_targets` 가 실제로 정렬하는 집합은 후자이므로 판정에 쓸 수 있는 것은 이 표다.
⟹ colored_8x8 에서 "상위 1" 은 **오로지 tie-break `(-부담, string(get_vtx_id(sched,v2)))`** 이
정한다(S-6). 그 규칙이 실제로 돌고 있다는 증거: 두 팔이 같은 표적(278)을 골랐다.

**표적 로봇 선택의 동점도 기록한다**(Task 1 의 알려진 한계 2 를 닫는다):
미래 배정 간선 소유 최댓값 동점 = tractor **2**(bot 2·bot 8 이 각 5) · colored_8x8 **3**(bot 1·4·5
가 각 11). 둘 다 정렬 2차 키(이름 오름차순)가 골랐다. 프로브가 히스토그램 전체를 찍는다.

### 🔴 재현성 — 절대값은 **패키지 재컴파일마다 갈린다**

같은 프로브를 같은 디렉토리에서 돌렸는데 **다른 세계**가 나왔다. 사이에 일어난 유일한 사건은
다른 레인의 `src/respec/cargo_ban_primitive.jl` **주석 수정 = 패키지 재컴파일**이다.

| | 재컴파일 전 | 재컴파일 후 |
|---|---|---|
| tractor 표적 v2 · 후보 간선 · 대조 행 | 300 · 77 · 49438 | **293 · 82 · 49445** |
| tractor 목적값(대조) | 14.5511 | **12.5515** |
| tractor 부담 고유값 | 4 (1.05168 ×2) | **5** (전부 단일) |
| colored_8x8 표적 로봇 · v2 · 행 | bot 3 · 286 · 62004 | **bot 1 · 278 · 62012** |

🔴 원인은 알려져 있다: 이 브랜치에는 `AbstractID` 의 **내용기반 `Base.hash`(`bb1b88c4`)가 없다**
(MEMORY `sim-runs-must-be-seed-reproducible`). Julia 기본 해시가 `objectid` 를 쓰고 프리컴파일이
바이트 재현되지 않아 **ID-키 `Dict`/`Set` 의 순회 순서가 빌드마다 갈린다.**
⟹ **절대 정점번호·행 수·목적값·부담 히스토그램을 이 파일에서 인용하지 말 것.**
빌드 안에서 **불변인 것**은 이것이다(두 빌드 · 두 판 · 스위트 안팎 전부에서 참):
`setdiff(처리 잃음, 대조 잃음) == [표적]` 이고 `대조 잃음 ⊆ 처리 잃음`.
그래서 G-2 게이트를 그 형태로 썼다.

### G-2 게이트와 변이 시험 — **양방향**

`test/cargo_ban_moves_work.jl`(자기 `module`, `test/runtests.jl` 에 등록). 단독 실행
**23 pass / 0 fail**(12 + 6 + 5). 변이 셋 전부 빨강(레포 미변경, 스크래치패드 사본):

| 변이 | 무엇을 뺐나 | 결과 |
|---|---|---|
| 없음 | — | 🟢 **23 pass / 0 fail** |
| M1 | body 에서 `forbid_heavy_cargo` 를 빼고 `release` 만 | 🔴 **7 pass / 3 fail / 2 error** |
| M2 | body 는 그대로, **처리 팔을 금지 없이** 푼다 | 🔴 **5 pass / 1 fail** (금지행 `49445 > 49445`) |
| M3 | M2 + 금지행 가드 제거 (G-2 단언 노출) | 🔴 **2 pass / 3 fail** — `takes_target === false` 가 `true === false` · `setdiff(…) == [293]` 이 `Int64[] == [293]` · `trt.lost > ctl.lost` 가 `0 > 0` |

### 전체 시험 — 같은 트리에서 앞뒤로 직접 쟀다 (S-1)

| 실행 | 결과 | 시간 |
|---|---|---|
| **착수 직후(변경 전)** | **2509 pass / 0 fail / 1 error / 2510 total** | 9m01.9s |
| **최종(이 게이트 포함)** | **2539 pass / 0 fail / 1 error / 2540 total** | 9m03.8s |

유일한 error 는 `Gurobi Error 10009: No Gurobi license found` 이고 **양쪽에 동일하게** 있다.
🔴 **델타를 전부 내 것으로 주장하지 않는다**: 내가 더한 것은 `cargo ban moves work` 의 **23**
이고(스위트 안에서 `23 · 6.1s` 로 초록), 나머지 +7 은 같은 트리에서 동시에 작업 중인 다른
레인의 변경이다. 중간 두 판(2537 pass / **2 fail**)은 위 §"못 쟀거나 예상과 달랐던 것" 2번이
가리키는 판이고, 명령·출력·트리 상태는 보고서
`.superpowers/sdd/2026-09-01-cargo-ban/task-8-report.md` §7 에 있다.

## ⚠️ 못 쟀거나 예상과 달랐던 것

1. 🔴 **계획서 G-2 스케치의 `binding` 판정을 안 썼다**(S-4.4). 그래서
   `n_reassigned`·`makespan(env.sched)`·`binding` 은 이 측정에서 **`nothing`** 이다 — 못 잰 것이
   아니라 **일부러 안 잰** 것이고, 셋 다 판정에 쓰면 안 되는 값이라는 근거가 S-4.3~4.5 에 있다.
2. 🔴 **계획서의 `lost_by_agent_control == 0` 을 게이트로 단언하지 않는다.** 깨끗한 프로세스에서는
   참이지만(5/5, 11/11) `Pkg.test()` 안에서는 대조도 슬롯 하나를 잃었다(표적이 **아닌** 277;
   처리는 277+표적 301). 절대값을 단언하면 게이트가 "금지가 도는가" 대신 "재풀이 잡음이 0인가" 를
   재게 된다. 판정을 **차집합**으로 옮겼다 — 잡음은 양쪽에 공통이라 저절로 지워진다.
3. **`commit_respec!` 을 안 부른다.** 대가: 재풀이가 세계에 실제로 쓰이는 마지막 걸음을 안 태운다.
   얻는 것: 두 팔이 바이트 동일한 그래프를 본다.
4. **`closed ≈ 150` 체크포인트는 안 쟀다.** 두 판 모두 `closed ≈ 60` 이다. Task 1 이 기록한
   tractor 152 · colored_8x8 151 은 여기서 **재확인하지 않았다** — 이 파일 숫자로 인용 금지.
5. `forbid_heavy_cargo` 의 `steps[].detail` 이 **빈 문자열**(위 각주). status 는 읽을 수 있으므로
   G-8 의 "각각 읽을 수 있는 status" 요구는 충족된다. 결함 아님, 기록만 한다.
6. 프로브·게이트 둘 다 판마다 새 env + `set_sim_step!(0)` + `reset_asset_ledger!()` 를 부르고,
   게이트는 `EDGE_PAYLOAD_MULTIPLIER`·`AGENT_COST_BIAS`·솔버 전역 둘·`STANDING_CARGO_BANS` 를
   직접 소유해 `finally` 로 되돌린다. **그래도 스위트 안팎의 세계 차이는 남는다** — 원인은 그
   전역들이 아니라 위 "재현성" 절의 프리컴파일 해시 문제다.
7. **release 는 `agent=` 로 좁혀졌다** — `params["agent"]` 가 `bind_primitive_args` 를 통해 두
   원시 모두에 실린다. 그래서 전체 release 의 60초 절벽(S-4.5)을 안 만난다: 네 solve 전부
   `OPTIMAL`, 0.22~0.94s.
