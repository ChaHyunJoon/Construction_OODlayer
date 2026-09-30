# R2b — all3(fault+battery+zone) 재생 (2026-09-22, 유료 0원)

`DEMO_SYNTH_FIXTURE_KINDS=zone`(tools/monitor/policy.jl, 기본값이면 바이트 동일)로 픽스처를 **zone 결정에만**
꽂고 battery·fault 는 canonical(스윕 surrogate 와 120/120 같은 매크로·대상, HTTP 0).
🔴 X-wing all3 스윕은 로봇 OOD 추첨이 **30판 전부 seed=1 고정**이었다(로그 `stochastic seed=1`) — 재생도 맞췄다.
첫 X-wing 시도(DEMO_SEED=시드)는 `superseded_xwing_seedN/` 에 보존.

| | A 옛 엔진+스윕 도구 | B 수정 엔진+같은 도구 | C 수정 엔진+오라클 |
|---|---|---|---|
| tractor 6 · X-wing 10 | 16판 모두 스윕을 **존 배치·첫 걸음·결정 열·closed 전부** 재현 | **16/16 완주** | 16/16 |
ZONE 결정에서 재시도된 판 0 → 첫 시도 = 유일 시도, 재생이 완전하다. 16 body 전부 translate 를 부른다.
⟹ all3 미완주 16판은 **전부 엔진(기하 결함)이 인과**.

## 사후 한정 (2026-09-22 저녁) — seed

- 원인(조사): X-wing all3 router 셀은 2026-09-06 SMDP 120판에서 왔고, 그 드라이버는 `DEMO_OOD_SEED` 를 넘겼다.
  그 이름은 헤드리스 엔진(`run_demo.jl`)의 축이고 `render_demo.jl` 은 `DEMO_SEED`(기본 1)만 읽는다.
  같은 120판의 **tractor router all3 도 30판 전부 seed=1** 이다. `sweep360.json` 의 tractor all3 는
  `results/2026-09-07-tractor-seedfix`(`DEMO_SEED=$seed`)에서 와서 영향이 없다.
- 해석: 이 X-wing 16판은 **fault·battery 추첨을 고정하고 zone 조건만 바꾼** 결과로 보존한다. 엔진 결함을
  재현한 증거로는 유효하지만, 서로 다른 fault·battery 조합에 대한 일반화 근거로는 쓰지 않는다.
- 사용 seed 검증 줄: `>>> OOD armed: … [stochastic seed=N, step-window draw]` 와 사건별 `· fault drawn at step=K`.
  스트림 JSONL 에는 seed 필드가 없다. 파일명의 `_s<N>` 은 seed 1 에서 생략되어 "미설정" 과 구별이 안 된다.
