# selfimprove 무료 종단 시험 (계획서 Task 19) — 2026-09-29 · **중간 보고: Step 3 에서 게이트 거부**

실험 `e2e-oracle`, 코드 `ae1786c9`(v0 manifest `5ed666f3…`). 전 단계 canonical 레인, 서비스·LLM 호출 **0**.
🔴 **시험용 입력이다:** 후보 body 는 LLM 이 쓴 것이 아니라 오라클 fixture(`tools/fixtures/oracle_zone_clear.json`)를
"실행된 원장 행" 모양으로 감싼 것이다(`origin="oracle_fixture"`, `llm_model=["oracle-fixture"]`). LLM 출처 주장에 쓰지 않는다.

## 단계별 결과

| 단계 | 결과 |
|---|---|
| Step 1 `init` | v0 = A₀ 레지스트리 + gen_oracle 33행, `verify_version == []`, 포인터 활성 |
| Step 1 A₀ render 재라벨 | 150 행 / 60 인스턴스 (fault {NOOP, Replace} · battery {NOOP, Replace, SwapBattery}, 게이트 풀 101–115 × tractor·xwing) |
| Step 2 fixture ×3 → watch | 트리거(완주 3) → 회전 c0, behavior_key `zone\|active_restriction_zones,restage_all_blocked!,translate_whole_build!`, track `add` |
| S0 | 통과 (하드 0, 소프트 0) |
| S1 | 통과 — tractor zone s1001 ×2: 둘 다 완주(287), `[score]`·`[invariant]` 바이트 동일, `execution_ok=true`(`translated`, resolve `resolved`), I4 = 1.225 s |
| S3_T (1차, A₀ 재라벨과 동시 실행) | **REJECTED(S3_T, C2_sound)** |
| S3_T (재측정, 동시 부하 없음 — 사용자 결정) | **REJECTED(S3_T, C2_sound)** — 재현됨 |

## S3_T 기준 (재측정)

| 기준 | 값 | 판정 |
|---|---|---|
| C1 정직 | I1·I1b·I2 위반 0 / 60 | 통과 |
| C2 건전 | I5 위반 4: xwing zone s104 79.5 s · all3 s104 82.6 s · zone s105 60.9 s · all3 s105 61.2 s (문턱 60 s). 60 판 전부 `execution_ok`, I3 위반 0 | **실패** |
| C3 구조율 | 39 / 40 (분모 = NOOP 미완주), Wilson 하한 0.871 ≥ 0.7, 보조 world_deadlock 1 | 통과 |
| C4 무해 | NOOP 완주 20 중 T 미완주 0 | 통과 |
| C6 층별 | tractor·all3 0.9 · 나머지 1.0 | 통과 |

도구 wall 분포: tractor 중앙 11.5 s(최대 35 s, 역시 s104), xwing 중앙 25.9 s. 느린 것은 **같은 시드(s104·s105)** 이고
두 측정(부하 有/無)이 거의 같다 → 부하가 아니라 그 배치의 평행이동 + MILP 재풀이 비용이다.
T_null 은 상태 기계대로 실행되지 않았다(S3_T 탈락).

## 막힌 것

Step 4–8(승격 → v1 빌드 → D 게이트(유료) → 배포 → 재현·음성 종단)은 이 회전이 통과해야 열린다. I5 문턱(사전 등록 60 s)에
대한 사용자 결정이 필요하다. 데이터를 본 뒤 문턱을 바꾸는 것은 spec §9.3 원칙과 충돌한다.

## 재현
`tools/selfimprove/e2e_oracle.sh init | inject | cycle | a0` (레포 루트, `DSPY_URL` 미설정).
재측정: `.venv/bin/python -m tools.selfimprove cycle c0 --exp e2e-oracle --from S3_T` (이전 그리드는 `s3/candidate.contended-a0relabel`).
