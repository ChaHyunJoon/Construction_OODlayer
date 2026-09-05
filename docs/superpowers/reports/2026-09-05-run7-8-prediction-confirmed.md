# 런 7·8 — 실패가 처음으로 **예측된 대로** 났다

2026-09-05. 산출물 `results/2026-09-05-zone-paid/run{7,8}-treatment.log`.
사건: zone (`DEMO_OOD=none DEMO_ZONE=1 DEMO_CASE_TAG=zone_mild`). 대조: INCOMPLETE 270/305, t=5776.

## 0. 왜 이 기록이 중요한가

앞의 일곱 런은 전부 **사후에** 원인을 찾았다. 런 8 은 **결과를 보기 전에 적어 둔 예측대로**
실패했다 — 그것이 두더지잡기와 수렴을 가르는 유일한 차이다.

D17b 구현자가 커밋 `94bd8132` 의 보고서에 이렇게 적었다:
> **실패 #8 예측: 지어내기가 던지기를 멈춘다.** `KeyError` 는 증상을 지목하지 원인을 지목하지
> 않는다. "이것 하나 고쳐라" 를 받은 모델의 가장 싼 수정은 조회를 `haskey`/`get(…)` 으로
> 감싸는 것이지 식별자 발명을 그만두는 것이 아니다. 다음 죽음은 **등록되고, 집행되고,
> 안 던지고, 아무것도 안 움직이는** body 다: `partial=false enact_retry=n/a` 에
> `world_delta_body` 여섯 축 전부 0.

**런 8 이 그것을 글자 그대로 재현했다.**

## 1. 런 7 — 되먹임 확장 **전**

```
steps=[ExclusionZoneBypass!:threw(KeyError: key "goal1" not found)]
partial=true   surface='physical'   PROJECT INCOMPLETE!
```
모델이 `restage_all_blocked!` 를 **버리고** `LiftIntoPlace`/`apply_cmd!` 직접 조작으로 갔고,
`affected_goals=["goal1","goal2","goal3"]` 자리채움을 env 에 조회하다 죽었다.
🔴 **런 6 보다 나빠졌다** — 그 직전 변경(`2a18fe44`, `returns` 광고, 프롬프트 +21.5%)의
부작용인지 잡음인지 n=1 로는 구별 못 했다. → 런 8 이 그 질문에 답한다(§2).

## 2. 런 8 — 되먹임 확장 **후**, 예측 적중

```
[minted] … verdict=admit applied=nothing partial=false … enact_retry=n/a
          registered=true impl_rejected_why=n/a steps=[ZoneBypassTool!:failure]
[minted] world_delta_body=closed=0 active=0 n_edges=0 n_binding_changed=0
         n_weights_changed=0 n_staging_moved=0  body_scope=body_only(probed)
PROJECT INCOMPLETE!
```

```julia
function ZoneBypassTool!(env; zone_center=nothing, zone_radius=0.0, alternate_paths=nothing)
    alternate_paths === nothing && return :failure
    zone_key = Symbol("zone_$(zone_center[1])_$(zone_center[2])_$(zone_radius)")  # 🔴 조립
    result = restage_all_blocked!(env; zone_keys=[zone_key], resume=true, verbose=true)
    if result.status == :success; return :success; else; return :failure; end     # ✅ 확인한다
end
```

**두 가지가 실제로 좋아졌다 — 그리고 둘 다 앞선 수정의 효과다:**
1. ✅ **모델이 반환 상태를 확인한다.** `returns` 광고(`2a18fe44`)가 작동했다.
   ⟹ 🔴 **런 7 의 퇴행은 `returns` 부작용이 아니라 잡음이었다. 되돌리지 않는다.**
2. ✅ **거짓 `:success` 가 사라졌다.** 런 6 의 자기신고 결함이 스스로 닫혔다 —
   `:failure` 를 정직하게 낸다.

**남은 하나**: zone 키를 **좌표에서 조립했다**(`Symbol("zone_1.09_0.42_0.07")`).
진짜 키는 `restriction_zones() -> Dict{Symbol, Ball2}` 에 있고 그것도 광고돼 있다.
🔴 모양이 또 바뀌었다(자리채움 토큰이 아니라 **구성된 Symbol**) ⟹ S6 필터 밖이다.

## 3. 🔴 모양 매칭은 여기서 끝났다

이 body 는 **문법적으로 완벽하고, 예외를 안 내고, 반환 상태를 제대로 확인한다.**
**어떤 정적 필터로도 못 잡는다.** 잡을 수 있는 것은 사후 측정 하나뿐이다 —
**"돌았는데 세계가 안 움직였다"**. 그 계측기는 오늘 여섯째 축(`n_staging_moved`, `7596d0b1`)까지
붙여 완성했고, 지금 없는 것은 그 **측정된 0** 을 agent-3 에게 돌려주는 배선뿐이다.

⚠️ 그리고 그 되먹임이 무엇을 말해도 되는지가 실험 유효성의 경계다: **관측만 말하고 처방은
말하지 않는다.** "도구가 에러 없이 돌았고 측정된 축들이 안 움직였다" 는 허용, 동사 이름이나
`restriction_zones` 를 대는 것은 금지.

## 4. 여덟 런 요약

| 런 | L1 | L2b | L3 | L4 | 죽은 자리 | 그 자리를 닫은 것 |
|---|---|---|---|---|---|---|
| 1 | ✅ | ❌ | ❌ `[]` | 0 | 필드명 환각 | 타입 폐포 확장 |
| 2 | ✅ | ❌ | ✅ | 0 | 키 타입 `"R1"` | `5bfebe29` 타입 좁힘 |
| 3 | ❌ | — | — | — | kwarg 기본값 누락 | `1743856d` 규칙 조화 |
| 4 | ✅ | ❌ | ✅ | 0 | 맨 정수 `::Int64` | `09204a2c` 사건 대상 채널 |
| 5 | ✅ | ❌ | ✅ | 0 | 인자 `"R1"`/`"R2"` | `bc1e9d5b` S5 필터 |
| 6 | ✅ | **✅ 최초** | ✅ | 0 | 좌표 튜플 · 거짓 `:success` | `2a18fe44` `returns` 광고 |
| 7 | ✅ | ❌ | — | 0 | `["goal1",…]` | `86b5be25` S6 필터 |
| **8** | ✅ | — | ✅ | 0 | **조립된 Symbol · 무동작** | (되먹임 확장 진행 중) |

🔴 **여덟 번 다 "세계에게 묻지 않고 식별자를 지어냈다" 다.** 모양만 여덟 번 바뀌었다.

## 5. 실험 유효성 — 지금까지 지킨 것

- 오라클 우회(`DEMO_SYNTH_FIXTURE`)는 유료 런에서 **한 번도 안 켜졌다**(배너 0건, 런 6·7·8 전부).
- 프롬프트에 **처방을 더한 적이 없다**. 더한 것은 전부 **기계 유도된 사실**이다
  (키워드 타입 · 반환 타입 · 종단성 술어). 유효성 게이트가 시험으로 집행된다:
  returns 문자열 197개에 `!` 문자 0개, exported Function 이름 150개 중 부분문자열 일치 0건.
