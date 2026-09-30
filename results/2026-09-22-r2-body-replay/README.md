# R2 — 기존 생성 도구 재생 (2026-09-22, 유료 0원)

묻는 것: zone 스윕(2026-09-06, router 레인)의 미완주 15판에서, **같은 사건 직전 상태**에
**같은 생성 도구와 같은 집행 조건**을 다시 넣으면 엔진 수정(`b9a0f377`)이 결과를 바꾸는가.

## 조건 (한 하네스, `run_one.sh`)

| | 엔진 | 합성 레인 |
|---|---|---|
| A | 수정 이전 — 옛 `restage_zone.jl`(= 스윕 엔진 `d7199da3` 와 바이트 동일)을 `r2_entry.jl` 이 CB 안에 덮어 얹는다 | 스윕의 **첫 시도** 도구 |
| B | 수정 엔진(현 작업트리) | 스윕의 첫 시도 도구 |
| C | 수정 엔진 | 오라클 `tools/fixtures/oracle_zone_clear.json` |

- 재생 단위 = 합성 레인 키 15개 전부(`SYNTH_LANE_KEYS`: impl_code·calls·params·surface·reversible·body_names…),
  스트림 `respec.input.policies.dspy` 에서 추출(`extract_fixtures.py`, 스트림 sha256 은 픽스처의 `_provenance`).
- 스윕 env(`tools/monitor/grid/render_one.sh` router/zone)를 그대로 쓰고 **레인만** 바꿨다: `DEMO_ROUTER=1→0` + 픽스처.
  15판 전부 사건은 ZONE 하나이고 dspy 매크로 = canonical 매크로 = `NOOP` → 매크로 조건 동일.
- `DSPY_URL=127.0.0.1:9`(닫힘). body 가 던지면 `/rewrite` 가 `roundtrip_failed` 로 끝난다 = **재시도 없음**.
  (8077 에 서비스가 떠 있어 기본값이면 유료 재작성이 나갔다.)
- 🔴 스윕의 **두 번째(재시도) body 는 복구 불가**: 스트림은 첫 body 만 싣고, `/rewrite` 응답은 원장·로그에 없고,
  `~/.dspy_cache` 에 `gpt-5.6` 항목이 0건이다. 그래서 재시도 6판은 "첫 시도만" 재생했다.
- 병렬 W8. CLAUDE.md 는 비교 런 순차를 요구하지만, 아래 재현 검사가 병렬 잡음을 직접 잰다(스윕도 병렬이었다).

## 결과 (`tally.py` → `tally.json`)

| 시드 | 스윕 retry | 스윕 closed | A | A 재현(존/첫걸음/closed) | B | C |
|---|---|---|---|---|---|---|
| tractor z3  | — | 185 | ✘185 | ✔/✔/✔ | **✔287** | ✔287 |
| tractor z24 | refused | 175 | ✘175 | ✔/✔/✔ | **✔287** | ✔287 |
| xwing z3  | — | 472 | ✘472 | ✔/✔/✔ | **✔684** | ✔684 |
| xwing z4  | — | 251 | ✘251 | ✔/✔/✔ | **✔684** | ✔684 |
| xwing z6  | refused | 455 | ✘455 | ✔/✔/✔ | **✔684** | ✔684 |
| xwing z7  | — | 632 | ✘632 | ✔/✔/✔ | **✔684** | ✔684 |
| xwing z22 | — | 661 | ✘661 | ✔/✔/✔ | **✔684** | ✔684 |
| xwing z23 | — | 525 | ✘525 | ✔/✔/✔ | **✔684** | ✔684 |
| xwing z30 | — | 521 | ✘521 | ✔/✔/✔ | **✔684** | ✔684 |
| tractor z1  | retried | 185 | ✘147 | ✔/✔/· | ✘147 | ✔287 |
| tractor z11 | retried | 193 | ✘180 | ✔/✔/· | ✘180 | ✔287 |
| tractor z20 | retried | 266 | ✘266 | ✔/✔/· | ✘266 | ✔287 |
| xwing z2  | retried | 557 | ✘511 | ✔/✔/· | ✘511 | ✔684 |
| xwing z13 | retried | 366 | ✘348 | ✔/✔/· | ✘348 | ✔684 |
| xwing z26 | retried | 398 | ✘398 | ✔/✔/· | ✘398 | ✔684 |

(`·` = 스윕의 최종 결과가 두 번째 body 의 것이라 closed 는 비교 대상이 아니다.)

## 판정

**① 재생 충실도.** A 가 15/15 에서 존 배치 줄과 첫 시도 걸음(이름:status, 예외 문구까지)을, 재시도 없던
9/9 에서 closed 까지 스윕과 정확히 일치시켰다. ⟹ 이 하네스는 스윕의 사건 직전 상태와 집행 조건을 재현한다.

**② 9판(재시도 없음) — 엔진 수정이 인과다.** 같은 도구·같은 상태에서 A 실패 → B 완주, 9/9.
이 9판의 미완주는 생성 도구 탓이 아니다. 단 tractor z24 는 body 가 수리를 **끝낸 뒤** 마지막 검증에서
던졌고(아래 ④), B 의 완주는 이미 적용된 편집 덕이다 — "body 가 성공했다" 가 아니다.

**③ 6판(재시도 판) — 첫 시도 도구가 불충분하다.** A 와 B 가 closed 까지 **동일**하다 = 엔진 수정이 첫 시도
결과를 못 바꾼다. C 는 6/6 완주 = 같은 상태·같은 엔진·같은 집행 경로에서 광고 어휘만으로 해가 있다.
⟹ 생성된 첫 시도 도구와 오라클 사이의 **성능 차이는 입증됐다.** 공통 기전: `restage_all_blocked!` 가
`:none`(존이 적치원이 아니라 주행 목표만 막음)을 내면 body 가 translate 로 올라가지 않는다
(z1 은 `:partial/:residual_blocked/:infeasible` 에서만 translate; z11·z2 는 예외 문구에 "restaging status was none").
오라클은 `:none` 에서 translate 한다. `world_interface.json` 은 `status_symbols` 에 `none` 을 **뜻 없이** 나열한다
— 그러므로 이 차이를 순수 모델 능력으로 귀속하는 것은 아직 이르다(계약·프롬프트 산문 미점검).
스윕의 최종(재시도) body 가 수정 엔진에서 어땠을지는 **측정 불가**다.

**④ 부수 발견 — 광고된 검증기가 엔진 안에서 던진다.** `validate_schedule_transform_tree` 는
`world_interface.json` 에 `callable: true, returns Bool` 로 광고되는데, 첫 줄 `validate_graph` 가
`AssemblyComplete` 노드에 없는 `eligible_successors` 메서드를 찾아 `MethodError` 를 내고, 함수는
`AssertionError` 만 `false` 로 바꾸고 나머지는 다시 던진다. 이 재생에서 그 줄에 도달한 body 2/2(tractor z24,
xwing z26)가 여기서 던졌다. 120판 스윕 스트림 전체에서 `eligible_successors` 예외 17건 중 **17건이 body 에
그 이름이 없고 이 검증기를 부른다**(직접 호출 0건). ⟹ 그 예외는 모델의 환각이 아니다.

## 사후 한정 (2026-09-22 저녁, R3 이후)

- **25판**(zone 9 + all3 16, R2b)은 같은 도구를 유지한 채 엔진만 바꿔 완주했다 — 엔진 인과의 근거가 강하다.
- **6판**은 첫 시도 도구가 `:none` 에서 translate 로 올라가지 않았음을 확인했고, 그 누락을 보완한 재생(R3 `cf`)이
  6/6 완주했다. 이것은 **첫 시도에 대한** 인과 증거다. 스윕의 최종 결과를 낸 **재시도 body 는 어디에도 기록되지
  않았으므로**(원장은 첫 시도만 append, `/rewrite` 응답은 무기록, 스트림은 집행 전 사본) 그 body 의 수정 엔진상
  결과는 **알 수 없다**. "6판의 최종 미완주 원인이 확정됐다" 고 쓰지 않는다.
- "주된 실패 기전 = translate 누락" 과 "그 누락이 모델 능력 탓" 은 다른 주장이다. 후자는 아직 안 쟀다 —
  status 의미가 광고에 없었고 엔진 docstring 도 틀렸다(R3 §2).
