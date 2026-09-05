# 호출 가능한 세계 인터페이스 — 유료 라이브 런 결과 (2026-09-04)

> 계획서 `docs/superpowers/plans/2026-09-03-callable-world-interface.md` Task 10 Step 4.
> 🔴 **판정의 정본은 `docs/superpowers/reports/2026-09-03-task11-measurement-preregistration.md`
> 의 결정 1~19 다.** 그 문서는 **결과를 보기 전에** 쓰였고, 이 보고서는 그 규칙을 결과를 본 뒤에
> 바꾸지 않았다. 상세 실측·체크리스트 전문은
> `.superpowers/sdd/2026-09-03-callable-world-interface/task-10-run-report.md`.
>
> 트리 HEAD `f04a1299` · 사건 1건 · **과금 5회**(상한 8).

---

## 사다리 (설계 §0)

| 칸 | 명제 | 결과 | 증거 필드 |
|---|---|---|---|
| **L0** | 모델이 코드를 썼다 | ✅ **true** | 기록 `wrote=true` |
| **L1** | 우리 규약을 통과해 등록됐다 | ✅ **true** | `registered=true impl_rejected_why=n/a` |
| **L2** | 인자 채널이 값을 날랐다 | ✅ **true** | `args_from=calls n_calls=1` |
| **L2** | 호출이 **예외 없이** 끝났다 | ❌ **false** | `steps=[AdjustR1Operation!:threw]` |
| **L3** | 기존 함수를 최소 하나 불렀다 | ❌ **false** (`interface_calls=[]`, 재서 없다) | 결정 행 |
| **L4** | 세계가 실제로 바뀌었다 | ⚫ **`nothing`** (못 쟀다) | `delta_scope=body+harness_resolve` |

🔴 **L1 이 처음 초록이다.** 설계 §0 의 표가 적은 이전 유료 런 셋은 `L1 0/3` 이었다.
🔴 **L2 의 인자 채널(B1 배선)도 라이브에서 처음 증명됐다** — 값이 `calls` 채널로 실제로 Julia
경계를 넘었다(`calls_match_body=true`).

⚠️ **L2 를 한 칸으로 접으면 안 된다.** 사전등록의 술어는 `steps[1].status !== nothing` 인데
`:threw !== nothing` 이라 **술어는 초록**이고 설계 §0 의 명제("예외 없이")는 **거짓**이다.
술어는 고치지 않았다 — 그 결함은 아래 우려 1 이다.

---

## 모델이 낸 것

`tool_name=AdjustR1Operation` · `impl_name=AdjustR1Operation!` · `surface="sched"` ·
`expressible=false`(agent-2 가 발화를 결정) · `stages=["observe","design","design","compose"]`.

```julia
function AdjustR1Operation!(env; reduced_speed_factor=1.0, battery_drain_rate=0.0)
    sched = env.sched
    nodes = sched.nodes
    weights = sched.weights
    for node in nodes
        if node.id isa ConstructionBots.BotID && node.id.id == 1  # Assuming R1 has BotID 1
            task_id = node.id.id
            if haskey(weights, task_id)
                weights[task_id] *= reduced_speed_factor
            end
        end
    end
    return NamedTuple{(:status,)}(:success)
end
```

인자는 `calls` 채널로 도착했다: `{"reduced_speed_factor":0.8,"battery_drain_rate":0.1}`.

---

## 이 런이 실제로 말해 주는 것

**1. 설계 §1.5 의 실패 모드가 재발하지 않았다.** body 가 만진 필드 넷(`env.sched` ·
`sched.nodes` · `sched.weights` · `node.id`)은 **전부 실재하고 산출물이 광고하는 필드**다
(대조 완료). 이전 런들이 지어냈던 `node.assigned_robot` · `robot.charge` 류가 하나도 없다.
**깊이 1 타입 폐포 확장이 일했다.**

**2. 🔴 그런데 그래서 L3 이 비었다.** 인터페이스가 타입 폐포를 잘 광고하자 모델이 **함수를
부르는 대신 필드를 직접 만졌다.** body 가 실제로 부른 것은 `haskey`(Base)와
`NamedTuple{…}`(Core)뿐이고, `ConstructionBots.BotID` 는 `isa` 자리의 맨 참조라 설계대로 점수를
못 받는다. ⟹ **`interface_calls=[]` 는 "모델이 인터페이스를 못 읽었다" 가 아니라 "읽고 나서
호출이 아니라 필드 경로를 골랐다" 이다.** L3 이 재는 명제와 "모델이 세계에 도달했는가" 가
이 판에서 **갈린다** — 다음 라운드의 입력이다.

**3. body 는 `return` 식에서 죽었다.** 격리 프로브(세계·서비스 미접촉, 짝지은 대조):

```
NamedTuple{(:status,)}(:success)    -> MethodError: no method matching length(::Symbol)
NamedTuple{(:status,)}((:success,)) -> (status = :success,)          ← 대조
haskey(Dict{Int64,Float64}, 1)      -> true                          ← 대조
```

튜플 괄호 하나다. 던진 자리가 **수정 루프 뒤**라 `partial=true` · `world_maybe_dirty=true` 가 옳다.
🔴 **귀속의 강도**: 그 식이 던진다는 것과 다른 후보들이 안 던진다는 것은 **측정**이지만, 런이 예외
메시지를 어디에도 안 남기므로(우려 2) "이 런이 거기서 죽었다" 는 **강한 추론이지 직접 관측이 아니다.**

**4. 접지 되먹임이 라이브에서 수렴했다.** `stages` 의 `design` 이 둘인 이유는
`redesigned=true` · `ungrounded_params=["new_assignment_strategy"]` →
`ungrounded_params_after=[]` · `ungrounded_after_redesign=false`. **한 번에 수렴했다.**

**5. `/rewrite` 는 라우팅됐지만 안 탔다.** 낡은 서비스에 없던 그 라우트가 이번 세대에는 있다.
등록이 성공해서 되먹일 거절이 없었으므로 `[minted] rewrite:` 줄이 **0건**이다 ⟹ 결정 5 의
셋째 모양, **`nothing`**("시도조차 안 됐다")이지 실패가 아니다.

**6. D6 는 발화하지 않았다.** 감춘 다섯(결정 2) 중 어느 이름과도 충돌하지 않았고 로그에
`withheld` 가 **0건**이다. 그 다섯은 산출물의 148 이름 안에 **하나도 없다**(재확인).

---

## L4 가 `nothing` 인 이유 — 미리 정해 둔 규칙 그대로

`surface="sched"` ∈ `RESOLVE_SURFACES` ⟹ 하네스의 공통 MILP 재풀이가 돌았고
(`resolve=resolved` · `ran_milp=true`), 로그가 스스로 `delta_scope=body+harness_resolve` 라 적는다.
**결정 8**: 그 판의 차분은 집행 봉투 전체의 것이므로 body 단독의 공로로 못 읽는다 ⟹ `nothing`.
관측값 자체는 `closed=0 active=0 n_edges=0 n_binding_changed=0` 이었다.

`nothing` 으로 떨어뜨리는 다른 둘은 해당 없다: `zone_keys` 경고 **0건**(결정 15) ·
`hot_swap_robot!` **미호출**(결정 19).
결정 7 의 표는 **런 시점에 갱신됐다** — F3 이 착륙해 네 성분 **전부** 비-0 양성 대조를 가졌으므로
(`test/minted_end_to_end.jl:966-968`) 성분별 `nothing` 강등은 없었다. L4 를 떨어뜨린 것은 결정 8 뿐이다.

⚠️ 그리고 **계측기가 이 body 를 못 본다**: 네 성분 어디에도 `OperatingSchedule.weights` 가 없다.
이 body 가 던지지 않고 `:not_needed_surface` 였더라도 의도한 효과는 L4 에 안 보였을 것이다(우려 3).

---

## 런의 정직성 — 라이브였고 재생이 아니었다

`/health` 가 `cache: False` 를 말했고, 캐시 DB 를 `immutable=1` 로 런 **전후 같은 방법**으로 읽어
`count(store_time > T) = 0` · `count(access_time > T) = 0` · `max(store_time)` 불변을 얻었다
(T=`1788570217`, 16 shards / 5152 rows). **결정 17 표의 첫 행 = 기대값** ⟹ 공유 캐시를 읽지도
쓰지도 않았다 ⟹ **재생이 아님이 확정된다.** 🔴 그 0/0 은 **과금 장부가 아니다**(캐시가 꺼지면
라이브 호출도 행을 안 남긴다).

**지출 = 5회**: 결정 agent 1(`/health` 의 `calls=1`) + 합성 레인 4(`stages`) + rewrite 0.

**서비스**: 낡은 09-03 세대(PID 2243217, `code_fingerprint b59ec536`, `/rewrite` 없음)를 정본
판정기가 `FAIL stale` 로 갈랐고, 원장 U2 에 따라 죽이고 현행으로 재기동했다 —
PID 3161910 · `fingerprint 1697b61c53f3d2a2` · `cache=False` ·
`synth_tool_synthesis=True` · 라우트 `['/decide','/health','/macro','/rewrite']`.
판정은 `generation.py` 의 `check_health`(셸: `tools/require_current_service.sh`)로만 했다.

**산출물 핀(결정 16)**: `sha256 f5258900e04498…` — 런 **전후 동일** ⟹ L3 의 이름 우주가 확정된다.
프롬프트 **606줄 / 29,660자** — 결정 18 의 대조값과 일치.

**스위트**: `2910 passed / 0 failed / 1 errored / 0 broken`, 유일한 error 는 `runtests.jl:80` 의
Gurobi 라이선스(환경 문제, 기대값).

---

## 우려 — 고치지 않고 넘긴다

1. 🔴 **사전등록의 L2 술어가 `:threw` 를 초록으로 받는다.** `steps[1].status !== nothing` 인데
   집행부의 실패 표식이 비-`nothing` 심볼이다. 다음 사전등록은
   `steps[1].status ∉ (nothing, :threw)` 로 좁혀야 한다.
2. 🔴 **`:threw` 가 예외 메시지를 아무 산출물에도 안 남긴다.** "모델의 코드가 왜 죽었는가" 가
   유료 런에서 유실된다 — 다음 라운드가 무엇을 고칠지 정하는 바로 그 정보다.
3. 🔴 **`world_delta` 가 `sched.weights` 편집을 못 본다.** L4 의 `0` 을 "안 바꿨다" 로 읽으면
   안 되는 이유가 결정 8 말고 하나 더 있다.
4. ⚠️ **결정 18 의 아홉 argpath 축은 이 런이 못 쟀다** — body 가 `AbstractID` 인자를 안 받았다.
5. ⚠️ **의미 결함(사후 관찰)**: `weights` 는 정점 인덱스로 키가 잡히는데 모델은 로봇 id 로
   조회한다. 던지지 않았더라도 그 `haskey` 는 대체로 빗나갔을 것이다.
6. ⚠️ **집행 노트**: §V10 레시피에 `DEMO_BATTERY_STEPS` 가 없어 결정 4 의 처방
   (`DEMO_BATTERY_STEPS=40,120`)을 얹었다 — 그것이 없으면 surrogate 로 새서 $0 을 쓰고 아무것도
   안 재는 판이 될 수 있었다. 로그가 그 선택을 정당화한다(`unknown:battery_mild` → dspy).
