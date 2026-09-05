# 런 6 (zone, 유료, multi-agent) — 사다리 L2b 가 처음 초록이다

2026-09-05. 산출물 `results/2026-09-05-zone-paid/run6-treatment.log`.
채점: `tools/monitor/ladder_report.py` (기계 판독). 사전등록 판정 기준은 A1~A5(사용자 정의).

## 0. 결과

```
[minted] lane=present tool=ZoneBypassTool verdict=admit applied=nothing partial=false
  world_maybe_dirty=true handled=true resume=issued resolve=not_needed_surface
  args_from=calls n_calls=1 dropped_args=none registered=true impl_rejected_why=n/a
  steps=[ZoneBypassTool!:success]
[minted] ran_milp=false n_candidate_edges=n/a(no re-solve) closed=54
[minted] world_delta_body=closed=0 active=0 n_edges=0 n_binding_changed=0
         n_weights_changed=0 n_staging_moved=0  body_scope=body_only(probed)
PROJECT INCOMPLETE!   step_num=5729  n_closed=270  n_total=305
```

| 기준 | 판정 | 증거 |
|---|---|---|
| **A1** multi-agent 가 만든다 | ✅ | `ORACLE BYPASS` 배너 **0건** · `expressible=False` · `stages=['observe','design','compose']` |
| **A2** 에러가 없다 | ✅ **여섯 런 만에 처음** | `registered=true` · `impl_rejected_why=n/a` · **`steps[1].status === :success`** · `partial=false` |
| **A3** 도구가 일한다 | ❌ | L3 ✅ `['restage_all_blocked!']` · **L4 MEASURED-ZERO** (여섯 축 전부 0) |
| **A4** 데모가 정확히 나온다 | ❌ | `PROJECT INCOMPLETE!` 270/305 — 대조와 동일 |
| **A5** 결과가 더 낫다 | ❌ | 대조 대비 개선 0 |

## 1. 모델이 쓴 body — 그리고 정확히 무엇이 틀렸나

```julia
function ZoneBypassTool!(env; zone_center=nothing, zone_radius=nothing, navigation_goals=nothing)
    if zone_center === nothing || zone_radius === nothing || navigation_goals === nothing
        return :failure
    end
    zone_keys = [(zone_center[1], zone_center[2], zone_radius)]   # 🔴 좌표 튜플
    restage_all_blocked!(env; zone_keys=zone_keys, resume=true, verbose=true)
    return :success                                               # 🔴 반환값을 안 읽는다
end
```
`calls.args`: `zone_center=[1.09,0.42]` · `zone_radius=0.07` ·
`navigation_goals=[{goal_id:"goal1",…},…]` (전부 자리채움).

**결함 셋:**
1. 🔴 **`zone_keys` 의 정체를 몰랐다.** 그것은 `RESTRICTION_ZONES` 의 **`Symbol` 키**이지
   좌표가 아니다. 어떤 zone 도 안 걸려 함수가 아무것도 안 했다.
2. 🔴 **반환 상태를 안 읽고 `:success` 를 냈다.** 오라클 실측으로 `restage_all_blocked!` 는
   이 시점(`closed=54`, build step 이 이미 열림)에서 **거절한다**(`restage_assembly!` → `:already_started`).
3. **2단 확대를 안 했다.** 오라클은 tier-1 거절을 보고 `translate_whole_build!` 로 떨어져서 살렸다.

## 2. 🔴 `:success` 는 측정이 아니라 **모델의 자기신고**다

`_step_status` 는 body 가 **반환한 심볼**을 읽는다. 그래서 L2b 초록은 "예외가 안 났다" 는 뜻이고
**"일이 됐다" 는 뜻이 아니다.** 진실을 말하는 것은 L4=0 과 `PROJECT INCOMPLETE` 다.

이것은 B1(`7596d0b1`)이 `applied` 에 대해 미리 판정해 둔 바로 그 채널이 **라이브에서 발화한 것**이다:
> 생성 원시의 status 어휘를 선언 가능하게 만들면 `applied` 가 모델의 자기신고가 된다 —
> body 가 `translate_whole_build!` 를 부르지 않고도 `(status=:translated,)` 를 리터럴로 반환할 수 있다.

⟹ **`applied` 를 `nothing` 으로 둔 판정이 옳았다.** 그리고 같은 이유로
**A2 를 "도구가 성공했다" 로 읽지 말 것** — "던지지 않았다" 로만 읽는다.

## 3. 여섯 런의 궤적 — 실패는 옮겨갔지만 이번엔 사다리가 올라갔다

| 런 | L1 | L2b | L3 | L4 | 죽은 자리 |
|---|---|---|---|---|---|
| 1 | ✅ | ❌ | ❌ `[]` | 0 | 필드명 환각 |
| 2 | ✅ | ❌ | ✅ | 0 | 키 타입 `"R1"` |
| 3 | ❌ | — | — | — | kwarg 기본값 누락 |
| 4 | ✅ | ❌ | ✅ | 0 | 맨 정수 `::Int64` |
| 5 | ✅ | ❌ | ✅ | 0 | 인자 채널 `"R1"`/`"R2"` |
| **6** | ✅ | ✅ **최초** | ✅ | 0 | **`zone_keys` 좌표 튜플** |

🔴 **여섯 번 다 키워드인자에서 죽었다.** 그리고 그 여섯 번 내내 광고에는 **키워드인자 타입이
하나도 없었다** — 위치인자에만 타입이 붙어 있었다. 모델이 알 방법이 없는 것을 알기를 기대해 왔다.
→ `ba11fa09` 가 기계 유도로 키워드 타입을 실었다(37/44 메서드, 블록 +2.9%).

## 4. 남은 구멍 — 다음 런 전에 닫아야 하는 것

1. 🔴 **`zone_keys` 는 아직 불투명하다.** 선언이 `Any` 라 타입이 안 붙는다. 시그니처를 좁히는 것은
   **공짜가 아님을 실측했다** — `Vector{String}`/`Vector{Any}` 가 `TypeError` 가 되고 그것은
   `partial=true → world_maybe_dirty=true → handled=true` 로 **기본 복구 사슬을 삼킨다**.
2. 🔴 **213개 메서드 전부에 `returns` 가 렌더되지 않는다.** 그 필드가 method 항목에 없고 ambient
   에만 있다. 그래서 `active_restriction_zones ()` 가 **인자도 반환도 없이** 렌더된다 —
   진짜 zone 키를 들고 있는 함수인데. 이것을 실으면 `zone_keys` 의 타입 연결과 2단 확대의
   상태 어휘가 **동시에** 유도 가능해진다.
3. `handled=true` 인데 세계가 안 바뀌었다 — 아무 일도 안 한 도구가 기본 복구 사슬을 건너뛰었다.
   `_step_touched_world` 가 생성 원시를 무조건 참으로 보기 때문이고, 그 판정에는 근거가 있다
   (`minted_tool.jl` 의 문단). 그러나 이 런은 그 대가를 라이브로 보여준다.

## 5. 대조

zone 대조(`60870ca4` 에서 측정): `PROJECT INCOMPLETE`, `t=5776`, `n_closed=270/305`.
🔴 **재실행하지 않았다.** 판정: zone 의 매크로 메뉴가 `["NOOP"]` 하나뿐이라 B2 의 프롬프트
변경이 대조의 선택을 바꿀 수 없다. 대가: 대조 기준선이 프롬프트 세대와 어긋난다(물리는 동일).
