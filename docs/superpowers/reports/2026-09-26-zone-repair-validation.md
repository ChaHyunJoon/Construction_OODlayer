# Zone-repair verifier — T10 무료 검증 기록 (2026-09-26)

같은 내용이 `results/2026-09-24-zone-repair-verification/validation/README.md`(gitignore, 원자료 옆)에 있다. 이 사본은 git 에 남는 판이다.
원자료(분기 디렉터리·trace·스트림)는 `results/` 아래 이 머신에만 있고, git 요약은 `test/fixtures/repair_verification/b0/`(T10a)·
`test/fixtures/repair_verification/validation/`(T10b)에 있다. 유료 모델 호출 0, 실제 LM 서비스 기동 0. 상세 판정·명령은 SDD 보고서
`.superpowers/sdd/2026-09-24-zone-repair-verification/task-10a-report.md`·`task-10b-report.md`.

## 1. 역사 코호트와 새 paired 결과를 나눈다

| | 역사 코호트(4/13/27, 9/23 canonical ⋈ A2) | 새 paired(동시대 B0 = pi0, 같은 checkpoint) |
|---|---|---|
| 세계 | canonical `REPAIR_ABLATION=none`(사람 존 사다리 on) 대 A2 `REPAIR_ABLATION=all`(off), 코드·설정 지문 다름 | 현행 코드, 모든 분기가 같은 부모 t0 checkpoint·pi0 |
| easy | 27 | **B0 COMPLETE 14**(= A2 easy-success 14) |
| "regression 13" | A2 incomplete 13 | 새 B0 도 13/13 FAIL → raw regression 아님(기준 FAIL). 사다리 1회로 완주(T10a) — drift |
| rescue 4(앵커) | A2 complete | L0 재생 3 COMPLETE 이지만 강화 계약 위반, 1 통제 재생 불가 + 계약 위반 |

역사 A2 body 를 원본 그대로 재생(L0)하면 A2 의 closed 가 16/16 판에서 정확히 다시 나온다 — 역사 수치는 body 가 아니라 세계(사다리) 차이에 주로 기인한다.

## 2. 검증된 것 (시험·실측 근거)

| 항목 | 결과 | 근거 |
|---|---|---|
| B0(pi0) 120판 | COMPLETE 14 / FAIL 106 / UNKNOWN 0, prefix·신원·예산 120/120, 존 사다리 발동 0 | T10a |
| 병렬 = 순차 | T10b NOOP 31분기 trace 가 T10a B0 와 전 경계·전 열(rng 제외) 같음 | `validation/t10b_equiv_noop_vs_b0.json` |
| 역사 body 를 일반 ToolProposal 경로로 재생(원문 바이트 불변, 기하 patch 번역 없음) | 31/31 등록·집행; body 안 step 은 trusted adapter 가 중재 | `replay_repair_cohort.jl` |
| 강화 계약이 역사적 성공을 거절 | tractor 앵커 3 = `historical_complete_but_contract_invalid`(goal=start 2 · 하역 닻 이동 1); 완주(COMPLETE 287)인데 선택기는 NOOP | `task-10b-report.md` §2 |
| easy 보존 | 동시대 B0 COMPLETE 14/14 에서 선택 NOOP(baseline_complete); raw regression 2/14(둘 다 `get_cmd` 제어기 상태 — 완주·계약 통과) | `summarize_t10b.py` 게이트(변이로 빨강 확인) |
| 감사 정확도 | 스케줄 정점 제거가 정책·씬 트리 변경으로 오인되지 않는다(감사 `@ref` 신원화, checkpoint 정준 행은 불변); 진짜 정책 변경·제어기 상태는 따로 잡힌다 | `test/repair_tool_execution.jl` [14] · `test/repair_checkpoint.jl` [5b] |
| 비기하 수용 | 배정 인계 · 런타임 배정 간선 해제(하니스 재풀이) · 배터리 배송 파견 · 기하+배정 혼합 — 4/4 일반 경로 수용, 비기하에는 resync 안 돔 | `test/repair_validation_fixtures.jl` |
| 고장 거절 | task 삭제·완료 위조·존 제거 후 복원·자원 위조·런타임 override(정적/동적)·host write(정적/동적)·등록 메서드 잔존·부분 적용 — 12/12 거절, 부모 t0·NOOP 궤적 불변 | 같음 |
| 존 해소 후 정지 후보 기각 | 자연 사례(0.5 m 이동 후보: `n_blocked=0` 인데 180 에서 정지 → FAIL → 선택 안 됨) | `natural_tractor_zone_s5.json` |
| **자연 TOOL 선택** | production shadow + fixture(빌드 1 m 이동)로 tractor zone s9(B0 FAIL 221)에서 supervisor 가 강제 없이 TOOL 선택 → SHADOW_NOT_COMMITTED → NOOP 재개 certified | `natural_tractor_zone_s9.json` |
| 게이트 원장 | T0–T10b 빠른 게이트 24 + 에피소드 게이트 8 + 전체 Pkg.test(4211/0/1 — Gurobi 라이선스 error 는 baseline), 검증기 수정 뒤 전부 다시 exit 0; T10b fixture 게이트 worker 부터 86/86 | `validation/gate_ledger.tsv` |

## 3. 검증되지 않은 것 (숨기지 않는다)

1. **enforce 는 이 호스트에서 닫혀 있다** — 능력표 `enforce_allowed=false`(같은 프로세스 override 는 원리상 못 막는다). commit/활성화 경로는 시험 전용 강제 선택(T7/T8)으로만
   확인됐고, **자연 선택 뒤 commit 은 돌리지 않았다**.
2. **모델의 자연 TOOL 선택은 미측정** — 위 자연 선택은 손으로 쓴 fixture 다. FAIL 기준 판에서 모델이 COMPLETE + 계약 통과 도구를 내는지는 T11.
3. **mid-episode t0**(지연 존·라이브 존)는 120 격자에 없다 — 전 판 t0 = presim iter 1. 운행 중 운반 유닛 snap(T6 우려 3)·원장 splice(T8 우려 3)·semantic-edge 확인(T10a §9)은 이 조건에서만 섰다.
4. **deferred 존**(t0 capture 없음)은 인증 불가로 기록될 뿐 검증 대상이 아니다.
5. **관측 불가 목록**(모든 판정에 `unobserved` 로 붙는다): 코드 구간 안의 변경·복원(`intra_segment_change_and_undo`) · engine step 안의 변화 · worker export 위조 · 감사 모듈 밖 메서드 ·
   캐시 전용 필드 · terminal 에서 선행 순서 공허 · 운반 닻 미검사 사슬. 🔴 **인터페이스의 `get_cmd` 는 상태를 쓴다**(→ `get_twist_cmd` 가 제어기 런타임 상태를 남긴다) —
   이를 부른 도구는 `unsupported_effect:controller_state_mutated_by_code:env.agent_policies` 로 거절된다(easy 2판: 완주·계약 통과 후보). 허용 여부는 T11 전 결정이고,
   세계 인터페이스 문서(`world_interface.json`)는 이 상태성을 아직 적지 않는다. (원 판의 "파생 계획 coverage 한계로 easy 3판 거절" 은 1건이 감사 직렬화기 오인이었다 — 고쳤다.)
6. **유효한 역사 앵커 0개** — 설계가 가정한 "유효한 4 기전 보존" 은 성립하지 않았다.
7. L1(resync 추가)은 16판에서 L0 와 물리 궤적이 같다 — resync 가설은 이 코호트(presim)에서 지지되지 않았고, "8판" 집합은 식별할 수 없었다.
8. 하니스 wall 비용: X-wing FAIL 분기 최대 2403 s(부하 하) — production 3600 s 안이지만 여유는 1.5× 이다.

## 4. 원장·파일

- 게이트: `results/…/validation/gates/{fast_ledger.tsv, episode_ledger.tsv, logs/}` → git `test/fixtures/repair_verification/validation/gate_ledger.tsv`
- 역사 재생: `results/…/validation/t10b/cohort/<key>/episode.json` → git `validation/t10b_summary.json`·`t10b_tables.md`·`t10b_l0_vs_l1.json`
- fixture/고장: `results/…/validation/t10b/fixtures/` → git `validation/t10b_fixtures.json`
- 자연 선택: `results/…/validation/t10b/natural/<key>/zr/` → git `validation/natural_<key>.json`
- B0: `results/…/validation/b0_v2/` → git `test/fixtures/repair_verification/b0/`

## 5. 최종 리뷰 수정 파 (2026-09-26, 커밋 `44734343`..`9be7dfd7`) — T11 전 무엇이 바뀌었나

전부 무료(가짜 LM·fixture), 실제 서비스 기동 0. 상세·명령·변이는 `.superpowers/sdd/2026-09-24-zone-repair-verification/final-fix-report.md`.

| 항목 | 바뀐 것 | 확인 |
|---|---|---|
| C1 출력 상한 | 존 복구 레인의 호출당 출력 상한이 **필수** 예산 값(`ZONE_REPAIR_MAX_OUTPUT_TOKENS` / manifest `budget.model.max_output_tokens_per_call`) — 서비스 전역 `DSPY_MAX_TOKENS`(2000) 기본값을 쓰지 않는다. 모든 호출이 그 값을 싣고, 상한을 다 못 싣는 호출은 줄이지 않고 **거절**. 총 token 한도 < 호출 4 × 상한(+ 알려진 프롬프트 추정)이면 호출 0 으로 거절 | lane pytest 4 신규 · 가짜 LM 에피소드 `max_tokens_seen == ["16000"]` |
| I2 도장 | 후보 provenance(와 응답)에 model·model_type·temperature·cache·num_retries·max_retries(실제 부른 LM 사본에서)·max_output_tokens·prompt_digest(단계별)·world_interface_sha256. 레인은 chat 전송 고정(아니면 호출 0 거절). `decision_gaps` 가 cache off·chat·재시도 0·상한=예산·세계 인터페이스 digest=트리 파일을 요구 | wiring [15] · lane pytest · 에피소드 `decision_gaps == []` |
| I3 예산 | 부모 hold 한도·바깥 시한을 한 예산에서 유도(`RepairRuntime.episode_budget`; 기본 값으로 hold 31800 s·에피소드 39000 s — 옛 고정 6 h 보다 길다). observe·preflight worker 는 짧은 wall(`ZONE_REPAIR_PREFLIGHT_WALL_S`, 필수). `supervision.json` 은 예외 경로에서도 쓴다. campaign 은 러너 `--check` 의 `[budget]` 줄을 쓰고 `RUN_TIMEOUT` 이 그 값을 못 깎는다 | wiring [14][16] · selection [11] · campaign pytest · E1/T9 기록 |
| I4 dry commit | shadow 에서 도구가 선택되면 새 commit worker 가 같은 checkpoint·같은 source/params/calls 를 t1 까지 재집행 → `precommit_check` → `activate` 대신 `exit`. 결과는 `supervision.dry_commit` | E1b(강제 선택) `status=match`·명령 `["exit"]`·원래 세계 스트림 = off 바이트 동일 · selection [15] |
| I5 경계 | 분기 읽기 목록에서 `.git`·`~/.gitconfig`·`~/.config/git`·`~/.julia` 전체 제거(패키지·artifact·컴파일 캐시·julia 설치만). 코드 지문은 부모가 쓴 `code_identity.json` 을 분기가 **파일 digest 로 검증**해 얻는다(변조 = 신원 불일치) | rollout [1][5](샌드박스 julia: git 지문 unknown · 신원 파일 일치 · 변조 거절) · 에피소드 분기 복원 |
| 서술자 실패 | `observe_t0!` 가 삼키던 서술자 예외를 `descriptors_error` 로 기록·에피소드 기록에 | slot [12] |
| select! 배선 | 폐기(throw) 후보가 supervisor `select!` 경로에서 REJECTED(raw regression) | selection [14](변이로 빨강) |

**아직 아닌 것**: UDP·pathname unix socket·같은 프로세스 override 는 여전히 못 막는다(enforce 닫힘 그대로 — 읽을 수 있는 비밀이 줄었을 뿐). 프롬프트 token 추정은 3 문자/토큰 보수 근사다. dry commit 은 fixture 강제 선택 1판(E1b)에서만 쟀다 — mid-episode t0 에서는 미측정.
