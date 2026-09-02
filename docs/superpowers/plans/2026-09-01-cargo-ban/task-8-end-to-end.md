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

| 판 | closed | verdict | 간선 전/후 | 금지 전/후 | 그 로봇이 잃은 작업 | 재풀이 종료/시간 |
|---|---|---|---|---|---|---|
| tractor | | | | | | |
| colored_8x8 | | | | | | |

**대조(금지 없음)에서 그 로봇이 잃은 작업:** ___ (0 이어야 대조가 성립)

**⚠️ 못 쟀거나 예상과 달랐던 것:**
