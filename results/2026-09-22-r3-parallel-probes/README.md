# R3 — 검증기 수정안 · `:none` 수정안 · translate 반사실 (2026-09-22, 유료 0원)

모든 런은 수정 엔진(현 작업트리) + 픽스처 + `DSPY_URL` 닫힘. 공유 소스는 안 바꾸고 `r3_entry.jl` 이
`R3_OVERLAYS` 를 ConstructionBots 안에 include 한다. 탐침(`probe.jl`)은 집행 직전·직후 검증기를 부른다.

## 1. 검증기 `validate_schedule_transform_tree`
원인: 빌드 때 검증하는 그래프는 `NGraph{DiGraph,ConstructionPredicate,AbstractID}`(CustomNode), 실행 중
`env.sched` 는 `OperatingSchedule`(ScheduleNode). 검증기는 후자에서 **한 번도 돈 적이 없다**(사건 직전에도 던진다).
| 안 | 사건 직전 / body 직후 | 변이(리프트 목표 +0.5 m) → 원복 | 옛 비강체 평행이동 직후 |
|---|---|---|---|
| 현행 | MethodError / MethodError | — | — |
| (a) 4함수 위임 | ErrorException(no field val) | — | — |
| (a2) (a)+`node_val` | true / true | **false → true** | true (4/4) |
| (b′) 변환 후 검증(full_demo.jl:666 경로) | true / true | **false → true** | true (4/4) |
예외 전수(로그·스트림): 검증기에서 나온 비-Assertion 예외는 이 MethodError 하나(26 로그), false 반환 0건.
⟹ 고친 검증기는 장부 불일치를 잡지만 **존과의 여유(기하)는 못 본다**.

## 2. `:none` — 반사실(`cf`, body 에 "`:none` 이면 translate_whole_build!" 한 줄) · 엔진 수정(`vn`)
- cf: 재시도 6판 **6/6 완주**(검증기 수정 없이도; (b′)를 얹으면 z1·z26 body 도 success).
- vn(`restage_all_blocked!` 가 막힌 적치원이 없어도 잔여 막힘을 재서 `:residual_blocked` 보고 +
  `recover_stalled_teams!` 호출자 정렬): 원래 완주 9판 **회귀 0**, 실패 6판 중 **1판(z1)** 구제.

## 사후 한정 (2026-09-22 저녁) — 채택과 해석

- 채택: (b′) → `src/construction_schedule.jl` 의 `OperatingSchedule` 메서드. (vn) → `restage_all_blocked!` +
  `recover_stalled_teams!` 호출자 + docstring 정정. 회귀 시험 `test/validator_and_restage_status.jl`.
- vn 의 **1/6 구제는 "설명 문제의 기여가 작다" 의 근거가 아니다.** 그것은 **이미 쓰여 고정된 옛 body** 에 상태만
  바꿔 준 효과다. 올바른 status 의미를 읽고 **새로 생성한** 도구의 성능은 측정하지 않았다.
- vn 은 로그 변경이 아니다: `maybe_respecify!`(replan.jl, ForbidZone 경로)는 `:residual_blocked` 를 받으면 전체
  이동을 실행한다. 예전에 "빈 도메인 + 막힘" 이 `:none`→`:noop`(우회만)이던 자리가 이제 전체 이동이 된다 —
  비교군(canonical/surrogate)의 동작도 바뀐다. 이 판정은 `zone_diagnosis` 의 인과 규칙(`n_nav_blocked`, 같은
  `zone_blockage` 함수)과 일치한다: 아무것도 안 막는 존은 여전히 `:none` 이다.
  ⟹ R6 에서 정책을 비교하려면 **수정된 같은 엔진**으로 비교군도 다시 잰다.
