# SMDP 6축 프롬프트 — router × zone 30시드 재스윕

2026-09-06. 베이스라인 `tools/monitor/sweep360.json`(같은 엔진·같은 격자·같은 채점기).
유료, 캐시 off, `gpt-5.6-sol`. 11분 6초, 30/30 결측 0.

## 무엇을 바꿨나

1. **관측**: LLM 페이로드의 `MEASURED STATE` 를 6개 agnostic 서술자 → SMDP 6축
   `{p,b,v,w,c,k}` = progress · broken_robots · spare_robots · active_nodes ·
   min_fleet_soc · event_kind 로 교체(`policy.jl` 의 `_smdp_state_features`,
   `dspy_service.py` 의 `_SMDP_AXES`). `d`(time to done)는 세계에 없어 뺐다.
2. **규약 8**(`world_interface.py`): 키워드는 이름만 렌더되고 Julia 가 기본값을 노출하지
   않으므로, 값을 모르는 키워드는 **생략**하라. 리터럴 `nothing` 은 "기본값 쓰라"가 아니라
   기본값을 **덮는다**.
3. **게이트 D18·D19**(`minted_registration.jl`): 자기-가림 대입(`x = x()`)과 인터페이스
   호출의 리터럴 `nothing` 키워드를 eval 전에 거절한다.

## 결과 — 결과 축은 안 움직였다

| 축 | BASE (6 서술자) | SMDP 6축 + 규약 8 |
|---|---|---|
| 완주 | 25/30 | **25/30** |
| 존 제거 | 28/30 | 27/30 |
| tool 주조 | 29/30 | 28/30 |
| 최종 throw | 6/30 | 5/30 |
| 진척 | 89.2% ± 11.8 | 89.4% ± 11.4 |
| makespan [sim s] | 34.7 ± 26.1 | 34.6 ± 29.7 |
| J/closed | 349 | 347 |

완주 flip **0/30**, `closed` 동일 **29/30**(s11 만 180→193).

## 🔴 3시드 예비 측정은 이 스윕이 기각한다

앞서 s2·s3·s11 로 잰 "throw 2/2 → 0/2" 는 **회귀-평균**이었다. 30판에서 throw 는 11판이
뒤집혔고 방향이 양쪽이다(6판 throw→성공, 5판 성공→throw). 뒤집힘 비율 **37%** 가 기존 재현
실측 3/8 = 37.5% 와 거의 같다 ⟹ 판별 throw 는 시드의 성질이 아니라 판마다 독립인
노이즈(p≈0.18)다. baseline-throw 시드만 골라 n=3 으로 재면 개입처럼 보인다.

## 개입은 정확히 작동했다 — 표적이 사인이 아니었다

백업 스트림 27개가 옛 세대라 body 수준 전후 대조가 됐다.

| | OLD (26 body) | NEW (28 body) |
|---|---|---|
| 리터럴 `nothing` 키워드 | **21 (81%)** | **0 (0%)** |
| 값 없는 키워드 생략 | **0** | **20 (71%)** |

규약 8 은 문장 그대로 지켜졌다. 그런데 옛 판의 그 패턴은 대부분
`zone_blockage(env; …, cell = nothing, …)` 로 **무해**했고, 치명적이었던 `zone_keys=nothing`
은 이 격자에 없었다. D18·D19 게이트도 30판 발화 **0건**(`impl_rejected_why=n/a` ×30).

## 남은 최종 throw 5판

| 사유 | 판 |
|---|---|
| `eligible_successors` MethodError — 광고 **0건** | s1 · s24 · s28 |
| `setfield!: immutable struct PlannerEnv` (규약 5 위반) | s19 |
| 자기 단언 실패 (`residual_blocked`) | s26 |

`eligible_successors` 는 모듈에 실재하고(`construction_schedule.jl:318`) 메서드가
`ConstructionPredicate` 를 받는데 모델이 `ScheduleNode{…}` 를 넘긴다 — 규약 8 이 고친 것과
**같은 결함 부류(광고 구멍)** 이고 남은 실패의 3/5 다. 다음 손잡이다.

🔴 `refused_world_changed` 4판은 전후 모두 **100% 최종 throw**(BASE 4/4, NEW 4/4). 세계를
건드린 뒤 던지면 재시도가 원천 차단된다. 반면 재시도는 수렴하기 시작했다(BASE 2/4 → NEW 4/5,
작은 n).

미완주 5판은 전부 `world_deadlock`(존은 치웠고 그 뒤 얼었다). `unresolved` 는 1 → **0**.

## 회귀

pytest 619 pass / 5 skip. `minted_tool_enacts` 126/126 · `tool_args_grounding` 145/145 ·
`world_interface_closure` 14/14. `minted_registration` 은 기존 실패 (34)
(`length(advexp) == 169` vs 172, 다른 세션이 export 표면을 3개 움직였다)가 파일을 중단시킨다 —
그 한 줄만 풀면 37 testset 전부 pass(새 (36) 8/8 · (37) 7/7 포함).

산출물: `results/2026-09-06-smdp-state-30seed/`,
베이스라인 스트림 `results/baseline_streams_router_zone_2026-09-06/`.
