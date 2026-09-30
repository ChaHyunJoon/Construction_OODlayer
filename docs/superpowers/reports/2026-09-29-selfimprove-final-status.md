# Surrogate 자가개선 — 실행 최종 상태와 **남은 문제** (다음 세션 인계용) — 2026-09-29

- 계획서: `docs/superpowers/plans/2026-09-29-surrogate-self-improvement.md` (r2)
- 설계: `docs/superpowers/specs/2026-09-29-surrogate-self-improvement-design.md` (§0.0 이 본문보다 우선)
- 브랜치 `oracle-rebuild-night-2026-08-10`, 커밋 범위 `4ecbbe03..085732cf` (22 커밋)
- 실행 원장(모든 판정·측정): `.superpowers/sdd/2026-09-29-surrogate-self-improvement/progress.md` (git-ignored — 지우지 말 것)
- **유료 LLM 호출: 0 건.** 모든 판은 canonical 레인(서비스 호출 0). 직접 띄운 서비스는 신원 확인용 1회(`billed=0`).

---

## 0. 한 줄 요약

Task 1–18 구현·커밋 완료, Python 시험 109/109. Task 19(무료 종단 시험)는 Step 3 에서 **게이트가 후보를 거부**해
Step 4–8(승격·재적합·D 게이트·배포·재현)은 **종단으로 검증되지 않았다**(사용자 결정으로 종료). 최종 리뷰의
Critical 1·Important 4 는 고쳤다. **`Pkg.test()` 는 아직 빨갛다 — `selfimprove_invariants` 8 건이 스위트 안에서만 실패한다(§2-1).**

---

## 1. 현재 시험 상태 (실측)

| 스위트 | 결과 | 비고 |
|---|---|---|
| `SYNTH_RECORD_LOG=0 .venv/bin/python -m pytest tools/selfimprove/ -q -p no:cacheprovider` | **109 passed** | 최종 리뷰 수정 시험 10 포함 |
| `src/respec/llm_service/` (레포 루트) | 614 passed / 5 skipped (Task 5 시점) | 라이브 유료 시험은 기본 skip |
| `julia +lts --project=. -e 'using Pkg; Pkg.test()'` (`085732cf` 직전 작업트리, 로그 `…/final-pkgtest2.log`) | **4280 pass / 8 fail / 1 error / 4289** | error 1 = 기존 Gurobi 라이선스(`runtests.jl:80`, 무관). **fail 8 = 전부 `selfimprove invariants`** |
| 단독 `julia +lts --project=. test/selfimprove_invariants.jl` | 17/17 | 스위트에서만 빨갛다 |
| 단독 `test/render_lane_uses_llm_agent.jl` | 48/48 | 최종 리뷰 중 발견한 회귀를 고쳤다 |

---

## 2. 🔴 다음 세션이 고칠 문제 (우선순위 순)

### 2-1. `test/selfimprove_invariants.jl` 가 `Pkg.test()` 안에서만 실패 (**현재 스위트 빨강의 유일한 원인**)

- 증상: `selfimprove_invariants.jl:36` `@test CB.project_complete(ENV_)` 가 거짓 → 나머지 7 건 연쇄 실패.
  이 시험은 `colored_8x8.ldr` 작은 판을 끝까지 돌리고(단독 3–8 초 완주) 그 위에서 음성 대조를 한다.
- 로그(`final-pkgtest2.log`): 실패 직전 `Warning: No progress for 10000 iterations. Terminating.` 와
  `[OOD] no no-go zone clear of all staging/goal regions found` 가 보인다(그 경고가 **이 판의 것인지 앞 시험의
  것인지는 줄 순서만으로 단정할 수 없다** — CLAUDE.md: 보드 로그의 줄 순서는 시간 순서가 아니다).
- 이미 한 것: 앞 시험이 남긴 **제한 구역**을 원인으로 보고, 시험이 구역을 비우고 끝에 되돌리게 했다
  (`085732cf`). 남은 구역 하나를 심은 단독 재현(`8 fail`)은 이것으로 초록이 됐지만 **실제 스위트는 여전히 8 fail** —
  구역 말고 다른 전역도 새고 있다.
- 가설(검증 안 함): 스위트에서 바로 앞에 도는 `cargo ban store / lifetime / fault exception / moves work`
  (`runtests.jl` 끝부분)가 **`STANDING_CARGO_BANS[]`** (`src/respec/spec_dsl.jl`) 등 전역을 남긴다;
  그 밖에 battery fleet · hazard · `CAPTURE_DISTANCE_TOLERANCE` · minted 표(`selfimprove_libarm.jl` 이
  `m100_x!`·`m101_x!` 를 남긴다) 후보.
- 권장 절차: ① `test/runtests.jl` 에서 invariants 앞의 시험들을 하나씩 켜 이분 탐색(또는 판 시작 전에
  전역 스냅샷을 찍어 단독 실행과 diff), ② 원인 전역을 시험이 `try/finally` 로 소유·복원(CLAUDE.md Gotchas:
  "Pkg.test() 안에서만 빨개지는 시험은 전역 오염을 의심하라"), ③ 그 재현을 음성 대조로 남긴다.
- ⚠️ `selfimprove_invariants` 는 `runtests.jl` 의 **새 testset** 이라 이 실패는 기존 스위트의 회귀가 아니라
  새 시험의 격리 결함이다. 그래도 스위트가 빨가므로 병합 전에 고칠 것.

### 2-2. Step 4–8 이 종단으로 한 번도 안 돌았다

- Task 19 회전 c0(오라클 fixture ×3)가 **S3_T 에서 `REJECTED(C2_sound)`** — 원인은 I5(도구 wall ≤ 60 s) 하나.
  xwing s104 zone/all3 79.5/82.6 s, s105 60.9/61.2 s. 동시 부하 없이 재측정해도 재현(같은 시드가 tractor 에서도
  최느림, 36 s) → **인스턴스 고유 비용**(평행이동 + MILP 재풀이). C1·C3(39/40, Wilson 하한 0.871)·C4(0/20)·C6 통과.
  상세: `docs/superpowers/reports/2026-09-29-selfimprove-e2e.md`.
- 그래서 promote → refit(build_version) → policy_gate(D, **유료**) → deploy → 재현 시험 → 음성 종단(변조 arm)은
  **fake Ops 단위 시험으로만** 검증됐다. 최종 리뷰의 Critical·Important 가 전부 이 구간에서 나왔다(§3) —
  이 구간은 실제로 한 번 돌기 전까지 신뢰하지 말 것.
- 열려면 결정 필요: I5 문턱(사전 등록 60 s)을 그대로 둘지 / 벽시계 대신 sim·solver 시간이나 warm-up 을 쓰는
  사전 등록 개정을 할지 / e2e 한정으로 I5 를 보고용으로 돌릴지. **데이터를 본 뒤 문턱 조정은 spec §9.3 과 충돌.**
- 유료 Step 4 예상(실측 근거: sol 캠페인 원장 120 판, zone 판당 평균 $0.176 · p90 $0.208 · LM 호출 3.1 회):
  D 게이트 부모 v0 = zone·all3 60 판 ≈ **$10.6**(≈190 호출), 새 v1 = DEFER 비율에 따라 $0–10.6. 합계 약 **$11–22**.
  fault·battery 판은 과거 router 판에서 전부 surrogate 로 갔다(0 호출). 실행은 `CONFIRM_PAID=1 tools/selfimprove/e2e_oracle.sh paid`
  이고 **사용자 승인 없이 돌리지 말 것**.
- 이어서 하려면(현 상태: c0 `REJECTED`, 결정 없음): 문턱 결정 뒤 `python -m tools.selfimprove cycle c0 --exp e2e-oracle --from S3_T --reopen`
  (재측정 그리드는 campaign 이 채점된 판을 건너뛰므로 다시 재려면 `cycles/c0/s3/candidate` 를 옮길 것).

### 2-3. 미룬 Minor (최종 리뷰, 수정 안 함)

1. **C2 의 I3 절이 항진**: Task 7 판정으로 I3 는 "아직 안 놓인 화물"만 세고 C2 는 완주 판에만 I3 를 보므로 언제나 0.
   리뷰어 의견: 사전 등록 절이 실패 불가능해졌다 → C2 에서 빼고 I2 가 대신함을 명시하거나 미완주 판에 적용.
2. 출처 검사 두 개가 생산 경로에서 안 불린다: `static_check.rename_is_only_change`, `library.verify_chain`
   → `refit.build_version` 이 `write_version` 전에 호출해야 한다.
3. `review` CLI 가 `--R1 yes --R2 none --R3 yes` 를 기본값으로 **대신 증언**한다 → 필수 인자로.
4. 검토 묶음 §7 "구조된 인스턴스" 가 실제 구조(NOOP✗·T✓)가 아니라 T 완주 첫 3개 — `s3_summary` 에 NOOP 결과가 없다.
5. `panel.run_arm` · `online._one` 이 campaign 반환코드를 무시(init exit 3 = 지문 불일치가 조용함),
   `cycles/<c>/s3/<role>` 그리드가 코드 신원으로 키잉되지 않아 C7·데이터셋이 다른 코드 판을 섞을 수 있다.
6. `watch.run` 에 예외 처리가 없다(lock 점유 시 종료, TRIGGERED 회전이 고아로 남음). SIGKILL 뒤 `cycles/.lock` 수동 삭제 필요.
7. S0 금지 토큰에 `exit(`·`cd(`·`mv(`·`cp(`·`mkpath(`·`invokelatest`·`getfield(Main`·`download(` 누락(심층 방어).
8. 어휘 도장 `v<4+n>-<3+n>arms` 가 팔 **집합**을 식별하지 않는다({100} 과 {101} 동일) — arm id 다이제스트 추가.
9. 서비스가 manifest 의 `feature_schema_sha256` 을 대조하지 않는다(온라인 구동기 `launch_env` 만 대조).
10. `render_demo.jl` pre 훅의 `snapshot_t0!` 가 모든 render 판에서 보호 없이 돈다 — `try` 로 감쌀 것.
11. `surro_kinds=None`(surrogate 로드 실패) 이면 zone 프롬프트가 UNFAMILIAR 문단을 잃는다(판정됨, 효과 기록).
12. D 게이트 그리드가 중간에 죽으면 부분 `runs.json` 이 영구 캐시되어 재시도마다 `missing` → 수동 삭제 필요.
13. 유료 가드가 `e2e_oracle.sh` 에만 있다 — `cycle --from APPROVED`·`online` 은 무조건 과금 경로를 탄다(설정/플래그 가드 권장).

리뷰어의 추가 권고: `assert_selfimprove_version` 의 `/health` 분기(포인터 v1 vs 서비스 v0)에 Julia 시험이 없다(Review Focus 1 의 서비스 쪽).

---

## 3. 최종 리뷰에서 **고친** 것 (`085732cf`, 각 시험 RED→GREEN 확인)

| 등급 | 문제 | 수정 | 시험 |
|---|---|---|---|
| 회귀 | `render_lane_uses_llm_agent.jl` 샌드박스가 `libarm_for`·`enact_libarm!`·`snapshot_zones!` 를 못 찾음 | 샌드박스가 진짜 함수를 import | 48/48 |
| Critical | 두 회전이 동시에 열려 트리거 시점 부모에서 빌드 → 두 번째 배포가 먼저 배포된 팔을 조용히 버림 | watch 는 열린 회전이 있으면 새 회전 안 엶 · 빌드 부모 = 빌드 시점 현재 포인터 · deploy 는 `manifest.parent == 현재` 아니면 거부 | `test_final_fixes.py` 3 개 |
| Important | D 게이트가 서비스를 띄울 때 `services.json` 의 살아 있는 버전 항목을 덮어 온라인 판이 죽은 포트로 감 | `start(register=False)` | 1 |
| Important | part B 재개가 버전을 **새로** 빌드 / D_PASS 에서 막힘 | 상태에서 이어 감(빌드된 버전 재사용, D_PASS 면 배포만) | 2 |
| Important | REJECTED 회전을 기록 없이 재실행 가능 · 승인이 근거와 안 묶임 | `--reopen` 명시(history 에 이전 거부 기록) · 결정 뒤 part A 금지 · `decision.json` 에 `s3_summary`·`packet` sha, `--from APPROVED` 가 대조 | 3 |
| Important | 버전 서비스를 띄우고 배수할 방법이 deploy 뿐 | CLI `serve --version`, `drain --version` | 1 |

---

## 4. 내가 내린 판정 (원장 `Ruling:` 전부, 순서대로)

- 작업 방식: worktree 없이 이 브랜치에서 명시 경로 커밋(사용자 지시).
- 사전 점검: T6→T7 I4 기준점은 `libarm.jl` 의 Ref · T9 run 모양을 T10 이 따름 · T16 은 기준만 시험.
- T1 시험 teardown 이 불변 디렉터리 권한 복원 / T3 `cli.load_config` 추가.
- T4 조건 ②(`DEFER:no_arm`)도 `SURRO_TAU>0` 일 때만(τ=0 = v0 동작, {NOOP} 메뉴 → NOOP 규약 유지) · 없는 시험 파일 대신 llm_service 디렉터리 전체로 회귀 · 신원 검사를 함수로 분리.
- T5 (**사용자 결정**) U1 부작용: `_unfamiliar_block` 을 접두사 **또는** `kind ∉ surro_kinds` 로 판정(v0 프롬프트 바이트 동일) · `tool_choice_gate.jl` (7-b) 도 갱신 · `SELFIMPROVE_*` 5개를 config ENV result 클래스로 · DEFER 격상 Julia 시험 추가 및 새 시험 `runtests.jl` 등록.
- T6 `enact_libarm!` 가 `rec` 도 반환 · 시험은 재풀이 없는 surface 로(재풀이 경로는 e2e 에서 실측됨: `resolve=resolved`).
- T7 **I2 재정의**(부모 조립체 좌표계 local transform 비교 — 원안은 명목 tractor 잔차 9.78) · **I3 재정의**(안 놓인 화물만 — 원안은 명목 완주 판 33) · `restage_zone.jl` 리팩터 불필요(`CB.scene_drift` 존재) · I4 는 스트림 프레임에서 · 스냅샷 위치.
- T8 빈 호출 집합 ψ 기본값의 나머지 네 축.
- T9 결정 기록에 `valid_menu` 추가 · A₀ 재라벨은 NOOP 판 메뉴를 쓰고 메뉴 밖 강제 판 폐기 · run 모양 고정 · 모델 파일 매핑.
- T10 "decide body 가 굴렀다" = 결정 기록 steps 비지 않음 · 설치 거절 픽스처는 실데이터 변형 · rewrite 행 body_names 는 calls 에서 유도.
- T11 재계수는 모든 종료 회전 뒤 · 큐 위치로(타임스탬프 아님).
- T12 arm.json 은 Julia 경로가 쓰는 필드 + 출처만 · 금지 토큰은 식별자 경계.
- T13 C1 에서 I1b `na` 허용 · `panel.unmeasured` 추가.
- T14 검토 묶음 §7 은 재렌더 목록만 · 승인 시 ψ 행 실존 확인.
- T15 `assemble_rows`(순수) + `build_version(panels)` 분리 · 라이브러리 artifact 신원 = 원본 body 해시.
- T16 D 게이트는 인스턴스 집합이 같아야 통과 · 서비스 모듈 지연 import.
- T17 서비스 env `DSPY_CACHE=0` 고정 · deploy 는 D 게이트 기록의 manifest sha 일치 요구.
- T18 온라인 구동은 (code_rev, dirty digest) 둘 다 대조 · ARTIFACT_RECORDED/VERSION_BUILT 분리 · `--from APPROVED` 가 part A 산출물 sha 전부 대조 · 검토 묶음은 `arms/candidate.json` 에서 arm 읽음.
- T19 (**사용자 결정**) 무부하 재측정(문턱 불변), 재발 시 거부 수용 → 재발 → 종료.
- 최종: `init` 은 v0 서비스를 띄우지 않고 `serve` 명령으로 대신.

---

## 5. 재현·산출물 위치

- 실험 상태: `results/selfimprove/e2e-oracle/` (git-ignored) — `queue.jsonl`, `bodies/`, `cycles/c0/`(s0·s1·s3_t·
  `s3/candidate`·`s3/candidate.contended-a0relabel`), `cache/noop/…`, `cache/a0/…`.
- 불변 데이터: `data/selfimprove/e2e-oracle/`(v0 버전 디렉터리, `labels/a0_render.jsonl` 150 행, `psi/`) — **미커밋**(시험 실험).
- 보고서: `docs/superpowers/reports/2026-09-29-invariant-calibration.md`(불변식 보정 24 판 오탐 0),
  `…-render-label-contract.md`(라벨 계약·변환 동등성 24/24), `…-selfimprove-e2e.md`(e2e 거부 상세).
- e2e 구동: `tools/selfimprove/e2e_oracle.sh init|a0|inject|cycle|approve|status` (무료) · `CONFIRM_PAID=1 … paid` (유료).
- ⚠️ 이 레포 작업트리에는 **다른 사람의 미커밋 변경**이 있다(`tools/gen_world_interface.jl` 등). `git add -A` 금지.
- ⚠️ 포트 :8077 에 이 작업과 무관한 uvicorn(2026-09-23 기동)이 떠 있다. canonical 그리드에 `DSPY_URL` 을 주지 말 것
  (campaign 이 서비스 신원을 대조해 `service_drift` 로 멈춘다); fixture 직접 실행은 `DSPY_URL=http://127.0.0.1:1`.
