# SDD 세션 아카이브 — 2026-08-10 ~ 2026-08-14, 6개 세션

`.superpowers/sdd/` 아래 완료된 세션 6개(md 80개·diff 50개·약 16MB, 원본 md 합계 1.446MB)를
2026-08-18 에 이 한 파일로 압축하고 원본 디렉터리를 지웠다. `.superpowers/`는 git-ignore
대상이라 지운 원본은 **git으로 복구할 수 없다** — 남기는 것은 지금도 참인 사실과 그 결과가
지금 사는 곳뿐이다. 각 세션의 브리프·진행 로그·"에이전트 N 디스패치" 서술은 버렸다.

커밋 SHA는 전부 `git log -1 <SHA>`로 개별 검증했다(아래 각 절 하단 표). 계획서 원문은
전부 `docs/superpowers/plans/`에서 이미 내려가 있었다(2026-08-17 정리, `docs/superpowers/plans/README.md`
참조) — `git show <SHA>:docs/superpowers/plans/<파일명>`으로 복구한다.

세션은 실행 순서(날짜)대로 싣는다.

---

## 1. PLAN_4POLICY_5H_2026-08-10 — 4정책×8케이스 첫 비교표

**기간**: 2026-08-10 13:42 ~ 2026-08-11 00:25 (약 11시간). **원래 계획서**:
`wm4spacecraft_manufacturing/md/PLAN_4POLICY_5H_2026-08-10.md` (커밋 `97a0b979`에 추가,
`5960a25b`에 삭제 — `git show 97a0b979:wm4spacecraft_manufacturing/md/PLAN_4POLICY_5H_2026-08-10.md`).

**무엇을 했나**: `noop/surrogate/dspy/oracle` 4정책 × 7 OOD case(+중복 `zonecore`) × 5시드 =
120판을 처음으로 한 표에 모았다. 3개 태스크: (1) 결과 JSONL을 오프라인에서 모으는
`build_final_table.py`, (2) 그것을 Markdown 리포트로 렌더하는 `build_md_report.py` +
오라클 결과-천장(Part A), (3) fault/zone 축의 오라클 천장 라벨셋을 STEP D로 복구
(`firegrid_merged.jsonl` 40 fault instance, `zcausal_reform/` 4 arm) — 그 전엔 fault 축이
`FileNotFoundError`로, zone 축이 `n=0`으로 죽어 있었다.

**살아남은 교훈/함정**:
- **stdout 그렙은 영원히 실패할 수 없는 검사가 될 수 있다.** 이 세션이 처음 확인한 사실은
  아니지만(→ 2026-08-16 세션이 같은 패턴을 게이트에서 재발견), 여기서 `test_llm7h.py`가
  fault 축을 `15/16, exit 1`로 정확히 갈랐다: zone `n=2 FAIL`이 **진짜** 결함
  (`RelocateBuild(complete,279)` vs `NOOP(stalled,234)`)이지만 영향 범위는 0 —
  스윕의 193개 `ZoneTruth` 결정 전부가 `root_covered==0`(그 결함이 안 걸리는 레짐)이었다.
  이 zone 결함은 §2(parallel-30seed-sweep)에서 `RECOVERY_SPARES` 상태 게이트로 이어진다.
- **완주 판정 필드가 case에 따라 이름이 다르다.** `zcausal_reform/*.json`은 `status`(문자열)를
  쓰고, `complete`(bool)로 정규화하는 것은 그 위 레이어의 일이다. `build_md_report.py`가
  `status=="complete"`를 골라 `test_llm7h.py`와 동일 채점(`LAM*MACRO_COST[7]=1.5` 포함)이 되게
  맞췄다 — 결정 필드 자체를 바꾼 게 아니라 내부 API 정규화였다.
- `reference_policy.py`는 **의도적으로 손대지 않았다** — 그것이 a\*(정답)를 정의하므로,
  거기 손대면 "옳은 결정" 수치 전체가 재채점된다. 이 원칙은 이후 모든 세션에서 반복된다.

**지금 어디 사는가**: 산출물 `wm4spacecraft_manufacturing/artifacts_4pol/REPORT.md`(501줄)는
현재 트리에 없다 — 이후 세션들이 `artifacts_4pol/`을 반복 재생성하며 덮어썼고, 지금은
`COMPARE.md`·`FINAL.md` 등 다른 이름으로 산다(§ 진입점은 `md/RESULTS.md`). 이 120판 수치
자체는 그 뒤 세대(배터리 물리 복구·목적함수 통일 등)에 전부 구세대로 재분류됐다 —
현재 성능으로 인용하지 말 것. STEP D가 복구한 라벨셋(`firegrid_merged.jsonl`,
`zcausal_reform/`)은 `.gitignore` 대상 산출물이라 저장소 상태는 재실행에 달려 있다.

**검증된 SHA (6개, 전부 `git log`로 확인됨)**: `10de478`·`2e1b8e9`·`97a0b97`(`97a0b979`)·
`4437fca`·`4c63641`·`e17e8b2`. review diff **4개**, 커밋 범위 `10de478..e17e8b2`.

---

## 2. 2026-08-11-seed20-verification — 통계 인프라 구축 + 비용모델 교정

**기간**: 2026-08-11 08:38 ~ 13:01 (약 4.5시간, 7개 태스크). **원래 계획서**:
`docs/superpowers/plans/2026-08-11-seed20-verification.md` (`git show a25fa95b:docs/superpowers/plans/2026-08-11-seed20-verification.md`).

**무엇을 했나**: 20시드 확장 스윕을 앞두고 통계 도구를 새로 놓았다 —
페어드 Wilcoxon·군집 부트스트랩 CI·Holm 보정(`stats_paired.py`), 판 단위 군집 키에서
`case`가 빠져 있던 결함 수정(`shadow_score.py`), 리포트 산문의 표본수 하드코딩 제거
(`build_final_table.py`/`build_md_report.py`), `run_4pol.sh`에 `--cases` 플래그와
DSPy provenance 기록 추가. 마지막에 비용모델을 **벽시계 실측**(`_night/status_4pol.jsonl`,
120보드 5.71h = 171.4s/보드)으로 재교정하고 데드라인을 24h로 올렸다.

**살아남은 교훈/함정**:
- 🔴 **비용모델을 잘못된 필드에서 유도하면 스윕 예산이 2.4배 어긋난다.** `results_4pol/*.jsonl`
  안의 `wall_seconds`는 Julia 프로세스 기동+JIT(~100s/보드)를 **빼고** 잰다 — 매 보드가 새
  `julia` 프로세스이므로 이 누락이 크다. 진짜 단가는 bash가 잰 `_night/status_4pol.jsonl`
  이어야 한다. 이 세션 중반에 잘못된 필드로 교정했다가 후반에 발견해 되돌렸다.
- Holm 보정 계열(21개 검정, `sign_test` 하한 `2*0.5^n`)에서 **n≥10 시드가 있어야 어떤 완주율
  결과도 Holm 유의성에 닿을 수 있다** — 5시드로는 원리적으로 유의해질 수 없다.
- E1(완주)·E3(에너지)·E4(빌드시간) 세 endpoint가 전부 동점이면 `p=1.000`이 "유의하지 않음"과
  "천장이라 검정 불가"를 구분 못 하고 섞인다 — 별도 문구("전부 동점 -- 검정 불가(ceiling)")로
  명시하게 고쳤다. 표본 0쌍(`n=0`)일 때도 마찬가지로 "정의 불가"를 명시한다.
- Julia `Set` 순회 순서가 정의돼 있지 않다는 점이 **이 세션에서는 범위 밖으로 남았다** — 뒤에
  `.claude/CLAUDE.md`의 "런 간 재현성 결함"(`_pick_active_robot`)으로 이어져 지금도 미해결이다.

**지금 어디 사는가**: `stats_paired.py`·`shadow_score.py`·`run_4pol.sh`·`build_final_table.py`·
`build_md_report.py`·`test_report_sample_size.py`·`test_stats_paired.py` 전부 현재
`wm4spacecraft_manufacturing/`에 그대로 있다 — 이후 세션(§3)의 30시드 병렬 스윕이 이 위에서
돈다. 계약: `stats_paired.py`(9/9)·`test_report_sample_size.py`(10/10)·
`test_stats_paired.py`(11/11, `_board` 실배선 통합 테스트 포함).

**검증된 SHA (11개, 전부 확인됨)**: `8f7b854`·`a2ed2e7`·`5bf0d07`·`5d35a7b`·`7332c2d`·`d74fc8f`·
`68f9c24`·`016211e`·`45073bb`·`2d977f1`·`9e9a86b`. review diff **9개**, 커밋 범위
`a2ed2e7..9e9a86b`(기반 `8f7b854`).

---

## 3. 2026-08-12-parallel-30seed-sweep — 병렬 30시드 스윕 + oracle 레인 신설

**기간**: 2026-08-12 23:07 ~ 2026-08-13 08:40 (약 9.5시간). **원래 계획서**:
`docs/superpowers/plans/2026-08-12-parallel-30seed-sweep.md`
(`git show 946d4bcb:docs/superpowers/plans/2026-08-12-parallel-30seed-sweep.md`). 설계:
`docs/superpowers/specs/2026-08-12-parallel-30seed-sweep-design.md`(현존).

**무엇을 했나**: `check_geometry.py`(창고거리 D=20 provenance 검사) · `run_shard.sh`
((case,seed) 단위 격리 샤드 러너) · `merge_shards.py` · `gate_prereq.sh`(P1~P4+P8 LLM
동시성) · `run_4pol_parallel.sh`(K=16 오케스트레이터, xargs 기반) · `gate_load_distribution.py`
를 새로 짜서 210샤드(7 case × 30 seed) 630판을 K=16 병렬로 3정책(noop/surrogate/dspy) 스윕
했다. 계획 밖으로 사용자가 "oracle이 모든 case에서 완주하게 만들라"고 지시해 `policy.jl`에
oracle 레인을 신설하고, `fault_zone` 미완주를 실측으로 규명·수정했다.

**살아남은 교훈/함정**:
- 🔴 **`grep -c . f 2>/dev/null || echo 0`은 "0\n0"을 낼 수 있다.** `grep -c`는 0매치에도
  "0"을 찍고 종료코드 1을 내므로 `||` 분기가 함께 발동한다. 그러면 완주 판정
  `[ "$rows" -lt "$N" ]`이 "integer expression expected"로 조용히 거짓이 되어 **빈
  `rows.jsonl`을 가진 샤드가 `[shard] OK`로 보고된다.** 정수 하나만 내는 형태로 고쳤다 —
  밤새 도는 스윕에서 실패가 성공으로 둔갑하는 경로였다.
- 🔴 **dspy 3.2.1→3.3.0 업그레이드가 surrogate 레인을 조용히 canonical로 폴백시켰다.**
  `dspy/utils/lazy_import.py`가 `sys.modules["numpy"]`에 지연 프록시를 심어, 이후
  `_load_surrogate()`의 sklearn→joblib→numpy 경로가 반쯤 초기화된 numpy로 재진입해
  `TypeError`. 예외가 `surro_error`로 삼켜져 서비스는 정상 기동한 것처럼 보이고, 요약 행은
  `"policy":"surrogate"`인 채 실제 결정은 전부 canonical이었다(`enacted: canonical×4` 실측).
  수정은 numpy·sklearn을 dspy import **이전에** 먼저 import하는 것 — 이 교훈이
  `.claude/CLAUDE.md` Gotchas와 `dspy_service.py:44`의 주석으로 남았다. 이후 **레인 무결성
  검사기**(`check_lanes.py`, `policy`와 `enacted`가 어긋난 행을 잡는다)를 계획 밖으로 추가했다.
- **`fault_zone` 미완주의 진짜 판별자는 zone 기하가 아니라 이력이었다.** `zone`·`battery_zone`은
  `RelocateBuild`로 완주하는데 `fault_zone`만 186/313에서 멈췄다 — 두 판의 `zone_primitives`는
  사실상 동일. 갈리는 것은 `fault_zone`이 먼저 `Replace`(depot 왕복 hot-swap)를 실행해
  `RECOVERY_SPARES`가 차 있었다는 점 — 그 상태에서 빌드를 통째로 옮기면 이송 중인 운반체가
  교착한다. `oracle_macro`의 zone 가지에 "`RECOVERY_SPARES`가 비고 `relocate_feasible`일 때만
  RelocateBuild, 아니면 ForbidZone/NOOP" 게이트를 넣어 7 case × 3 seed 21판 전부 완주시켰다.
  **대가**: `reference_policy.py`(Python 채점기)는 이 상태를 볼 필드가 없어 **의도적으로
  갈린 채로 남겼다** — Julia oracle 레인은 완주에 대해, Python `decision_acc`는 공개 채점에
  대해 각각 권위를 갖는다는 원칙(Ruling 13)을 세웠다. 이 미해결 갈림은 `reference_policy.py`
  안에 "🔴 STALE PREMISE" 표식으로 아직 남아 있다(2026-08-16 갱신 확인).
  ⚠️ **원래 가설(래치 인과)은 반증됐다** — 상관(미완주 7/8)을 인과로 오독한 수정이었고, 210판
  재측정에서 완주율이 전혀 안 바뀌었다(201/210 → 201/210). 그 자체는 코드 정합성 개선이라 유지.
- `closed=285` 정지의 5/8은 **결함이 아니라 ReformTeam 예산(`--reform-max`, 기본 3) 고갈**이었다
  — 예산을 20으로 올리면 그 5판은 완주한다. 남은 3판은 진짜 livelock(별건).
  `run_demo.jl:574`의 예산 환불 1줄 수정(`6f5bc7b`)으로 oracle 완주율이 95.7% → **98.1%**.

**지금 어디 사는가**: 결과 문서 `wm4spacecraft_manufacturing/md/RESULTS_30SEED_D20_2026-08-13.md`
(현존, 339줄) — 단 `.claude/CLAUDE.md`상 그 뒤 목적함수 통일(§5)로 🔴 구세대 배너가 붙어
있으므로 **현재 성능으로 인용 금지**, 재현 절차·함정만 유효. 최종 수치: 630판(3정책) 완주
noop 16.2% · surrogate 91.0% · dspy 90.5%, oracle 210판 v3 98.1% [95,99]. 도구
(`check_geometry.py`·`run_shard.sh`·`merge_shards.py`·`gate_prereq.sh`·
`run_4pol_parallel.sh`·`check_lanes.py`)는 전부 `wm4spacecraft_manufacturing/`에 현존하며
이후 모든 스윕의 하니스로 쓰인다.

**검증된 SHA (26개, 전부 확인됨)**: `a3caada`·`df8cfec`·`4338fce`·`9bfa08a`·`e969d37`·`f43ad79`·
`3fcd9dd`·`632f16f`·`d318d1d`·`2b54668`·`a77575c`·`6b9ff07`·`df92c37`·`43261a5`·`1d92c80`·
`4684aeb`·`69b060c`·`da60187`·`4363cf4`·`d422ab1`·`2c33266`·`7899da4`·`bffaa52`·`d53aea2`·
`6f5bc7b`·`2245e90c`. review diff **3개**(태스크 1·3·5 배치 리뷰 + 코드전용 리뷰), 커밋 범위
`946d4bc..6b9ff07`; 세션 전체 커밋은 대시보드 배선(`2245e90c`)까지 그 뒤로 이어진다(개별 diff
파일 없이 위 SHA로 직접 검증).

---

## 4. 2026-08-13-dp-oracle — DP 설계 착수 직후 중단 (다음 세션에 흡수)

**기간**: 2026-08-13 10:13 (단일 커밋, 태스크 1만 완료 후 중단). **원래 계획서**:
`docs/superpowers/plans/2026-08-13-dp-oracle.md`(`git show a25fa95b:docs/superpowers/plans/2026-08-13-dp-oracle.md`).
설계: `docs/superpowers/specs/2026-08-13-dp-oracle-design.md`(현존, §2.1·§8.6·§8.7·§9가
2026-08-15 DP backward-induction 작업에서 계속 인용된다).

**무엇을 했나**: 12태스크 DP 오라클 계획의 사전 스캔에서 계획-스펙 간 불일치 15건을 잡아
정정(격자 경계, tie-band를 paired SE로, 비용함수를 사후 선택 가능한 순수함수로 등)한 뒤,
태스크 1 하나만 실행했다 — prefix 결정성 프로브. **사용자가 세션 중간에 우선순위를 바꿔
계획을 중단시켰다**: DP를 계속 짓기 전에 네 레인(MILP·오라클·surrogate·LLM)이 공유하는
목적함수부터 통일하라는 지시 → 다음 세션(§5)으로 직행했다.

**살아남은 교훈/함정**:
- **표집 방식은 `replay`로 확정됐다** — 태스크 1 프로브(`AT_CLOSED=30`, closed=58 지점)에서
  `identical=true`. 단, **이 확정은 좁다**: 네 주입점(closed∈{55,141,204,274}) 중 세 개는
  테스트되지 않았다. `fork`(주입 시점 env를 deepcopy해 팔별 분기)는 애초에 구조적으로 막혀
  있다 — RVO2 C++ 인스턴스·`BATTERY_FLEET`·`HAZARD_STATE`·`OOD_SCHEDULE`이 전부 프로세스
  전역 싱글턴이라, `deepcopy(env)`로 구조체를 복제해도 두 가지가 같은 물리 계산기를 공유한다.
- **rollout 비용은 실행 방식과 짝지어야 한다** — 콜드(새 프로세스, JIT 포함) 88~91초 vs
  웜(같은 프로세스 반복) rollout당 ~8초. 이 구분을 놓치면 CPU-시간 예산이 최대 10배 어긋난다.
- 🔴 **이 세션이 발견한 사실이 다음 세션 전체를 촉발했다**: `run_4pol_parallel.sh:8` 및
  `run_demo.jl:389`/`full_demo.jl:596`가 `assignment_mode=:greedy`를 쓴다 — 즉 **모든
  4정책 스윕 발행 수치는 MILP 목적함수를 한 번도 통과하지 않았다.** 에너지 항은
  `essential_tg_coponents.jl`에서 지워진 적이 없지만 세 층(모듈 기본값 `efficiency=0.0`,
  `wm4spacecraft_manufacturing/`가 `set_planning_objective_weights!`를 호출한 적이 없음,
  스윕이 MILP를 아예 안 씀)에서 꺼져 있었다.

**지금 어디 사는가**: 프로브 산출물 `wm4spacecraft_manufacturing/dp_oracle/PROBE_RESULT.md` +
`probe_result_raw.json`은 현존한다(커밋 `f0f6e99`). DP 오라클 본체는 이 세션이 아니라
2026-08-15 `dp-backward-induction`(실행 완료, `docs/superpowers/plans/README.md` 아카이브
목록)에서 완성됐고, 그 결과는 `.claude/CLAUDE.md`가 최신 세대까지 계속 갱신한다.

**검증된 SHA (1개, 확인됨)**: `f0f6e99`. diff **0개**(리뷰 없이 단일 프로브 커밋).

---

## 5. 2026-08-13-surrogate-rebuild — surrogate 재구축, **국소화된 음의 결과**

**기간**: 2026-08-13 17:15 ~ 2026-08-14 08:43 (약 15.5시간, 7개 태스크 + 최종 수정 라운드).
**원래 계획서**: `docs/superpowers/plans/2026-08-13-surrogate-rebuild.md`
(`git show 390bbdf7:docs/superpowers/plans/2026-08-13-surrogate-rebuild.md`). 설계:
`docs/superpowers/specs/2026-08-13-surrogate-rebuild-design.md`(현존).

**무엇을 했나**: 배포 surrogate가 OOD 종류와 무관하게 같은 팔만 고르는 문제(battery·fault·
fault_battery가 결정 분포까지 바이트 동일)를 고치려고, hot-swap 정렬된 세계에서 라벨을
다시 뽑고(`relabel_2026-08-14.jsonl`, 365행/155 instance) 21차원 kind-무관 특징 조립기 +
22번째 상호작용항(`resource_loss × a_cost`, 매크로 8을 유일하게 분리하는 축)을 추가하고,
2-헤드 ΔĴ 예측기(`SurrogateV2`)와 `deadband_Jbar` 결정규칙으로 재학습했다. G1~G4b 게이트
(LOIO/LOKO regret·kind 판별·메뉴 불변성)로 채점했다.

**살아남은 교훈/함정**:
- 🔴 **평균 LOIO regret에서 학습을 하나도 안 한 바닥선(legal 메뉴 안 `MACRO_COST` 최댓값을
  그냥 고르는 규칙)이 새 모델을 이겼다**: 바닥선 169.48 vs 배포규칙 223.33(+53.85, 155
  instance). G2(LOKO)에서는 격차가 더 크다 — 배포규칙 924.96 vs 바닥선/선형 바닥선 둘 다
  ~169. **이 결과는 나중에 반박되지 않았다** — 2026-08-16 CLAUDE.md가 그대로 인용한다.
- **exact-match만 보면 반대로 보인다** — 배포규칙이 exact match 0.819로 최선이라, 2차 지표만
  보고 "개선됐다"고 결론 내릴 뻔했다. 진짜 판별자는 J 단위 regret이었다.
- 🔴 **평균 격차의 절반은 라벨 하나(`fault_s3_sev1.0_sp0_f58`)가 만들었다** — 같은 레짐의
  형제 19개 중 1개만 그 라벨을 지지한다. "모델이 일반적으로 열등하다"는 이 데이터로는
  **말할 수 없다**(라벨러 쪽 조사가 우선순위 1로 남았다).
- **ΔJ 헤드 설계는 spec이 의도한 효과를 못 냈다**: `argmin(J − const) ≡ argmin(J)`이므로
  인스턴스 난이도 분산을 상쇄한다는 spec §3.2의 핵심 근거가 구현에서 실현되지 않았다 —
  구현이 아니라 **spec이 처방한 수식 자체의 결함**.
  53/155(34%) instance는 완주하는 팔이 하나도 없어(`J = C_fail + 100·unclosed` 전 팔 동일)
  헤드 A(완주확률)가 아무 정보도 못 주는데, 평균 regret이 이 부분집합에 지배당한다.
- **정직성 발견**: `n_completion_decided_losses`(정의: `regret > C_fail/2`)라는 이름과 달리
  outlier 8건 전부 **완주하는 팔이 없다** — "모델이 완주를 못 시켰다"는 서술은 거짓이었다.
  `audit_objective.py`의 12파일 리터럴 스캔이 새로 추가된 3개 파일을 **하나도 커버하지
  않는다**는 것도 이 라운드에서 발견·수정했다(`test_surrogate_support.py` §B 추가).
- **배포 지원 매크로 집합이 `{0,1,2,7,8}`로 좁다** — 3(ForbidZone)·4(ReformTeam) 없음. 630판
  스윕의 ReformTruth 511건은 전부 이 라벨셋 밖이라 surrogate가 그 사건에서 선택권이 없다.
  (2026-08-16 세션이 이 좁은 지원집합을 `action_registry.json` 파생으로 닫는다.)

**지금 어디 사는가**: `wm4spacecraft_manufacturing/md/RESULTS_SURROGATE_REBUILD_2026-08-14.md`
(현존) — G1 표·G4b 실패·615판 스윕 보류 판정을 그대로 담고 있다. 이 세션의 부정적 결론은
`.claude/CLAUDE.md`의 이후 세대(2026-08-16 action-set-closure, 2026-08-17 배포 surrogate가
"낡았다") 서술의 직접 전제다. `test_surrogate_support.py`(13/13)·`audit_objective.py`(9/9,
9-b 핸드셰이크 경고 포함)가 이 세션이 남긴 기계 계약이다.

**검증된 SHA (19개, 전부 확인됨)**: `5d35bcfb`·`7059bde9`·`cff6a1c6`·`d9e30e62`·`7954ae83`·
`1c82bee6`·`8b74810a`·`1cd1fcf7`·`2f41228a`·`28bff3d6`·`19a8fb3b`·`74b18310`·`37f4bc9b`·
`75a710fa`·`390bbdf7`·`b15ce679`·`aad22074`·`0cb07810`·`c49b5ae4`. review diff **14개**,
커밋 범위 `5d35bcfb..390bbdf7`(최종 수정 라운드 `b15ce679..c49b5ae4`는 같은 세션의 후속
커밋으로 개별 SHA 검증됨).

---

## 6. 2026-08-13-unified-objective — 목적함수 J를 단일 진실원으로 통일

**기간**: 2026-08-13 10:46 ~ 16:54 (약 6시간, 7개 태스크 + 2회 전-브랜치 수정 라운드).
**원래 계획서**: `docs/superpowers/plans/2026-08-13-unified-objective.md`
(`git show a25fa95b:docs/superpowers/plans/2026-08-13-unified-objective.md`). 설계:
`docs/superpowers/specs/2026-08-13-unified-objective-design.md`(현존, 아직 유효한 설계
결정 — `.claude/CLAUDE.md` §2026-08-13이 이 세션의 결과를 상세히 승계·갱신하고 있다).

**무엇을 했나**: `wm4spacecraft_manufacturing/objective.json`을 목적함수 J의 단일 진실원으로
만들고 `objective_hash()`(당시 `19819377a7f8ebb2`)를 도입해, greedy 비용(`GreedyEnergyAwareCost`)·
MILP 전역 κ·오라클 라벨(`gen_oracle_mc.scalar_cost`)·Python 분석(`e1_analyze.cost_lex_key`)이
전부 같은 J를 보게 배선했다. `objective.jl`/`objective.py`를 두 언어 동일 구현으로 새로
만들고, `audit_objective.py`(기계 감사, 9/9)·`test_objective.py`(29/29)로 게이팅했다.
`ENERGY_OBJECTIVE`(0|1)를 두 번째 세대 축으로 각인해 목적함수 세대와 별개로 추적하게 했다.

**살아남은 교훈/함정**: 이 세션이 확정한 사실·함정은 `.claude/CLAUDE.md`의
"2026-08-13 — 목적함수 통일" 절이 이미 상세히(세대 판정 계약, 4곳의 숨은 κ 활성화 지점,
`makespan`의 `-1.0` 센티넬 등) 보존하고 있으므로 여기서는 **이 세션 고유의 것만** 남긴다:
- 🔴 **해시를 ENV 손잡이(`ENERGY_OBJECTIVE`)에 접지 않기로 한 결정은 재검토 끝에 유지됐다.**
  처음엔 "ENV를 해시에 넣으면 기존 코퍼스 전체가 회전한다"는 이유로 거부했는데, 그 근거
  자체가 **틀렸음**이 재검토에서 드러났다(값이 1이 아닐 때만 조건부로 접으면 기본 해시는
  바이트 동일했을 것). 그럼에도 최종 결정은 그대로 "해시에 안 접고 필드로 각인"인데, **이번엔
  올바른 이유**로: 해시는 `verify.py` 등 소비처가 읽는 값이라 생산자 손잡이를 접으면
  `ENERGY_OBJECTIVE=0 python verify.py` 한 줄이 기존 덤프 전체를 조용히 구세대로 재분류한다.
  **결론은 안 바뀌었지만 그 근거가 재검토로 갈렸다는 것 자체가 함정이다** — 우연히 옳았던
  결정을 틀린 이유로 방어하고 있었다.
- `gen_oracle_dataset.jl`은 **아무도 배선하지 않은 세 번째 라벨 생산기**였다 — 감사 스캔에
  안 걸려 `energy_J` 필드 누락이 세션 막바지까지 발견되지 않았다(C-1). 소비처가 셋(Julia
  greedy/MILP, Python 분석, 그리고 이 라벨 생산기)이라고 여기고 감사를 짰는데 실제론
  넷이었다 — **"소비처를 다 알고 있다"는 전제 자체를 감사가 검증할 수 없다.**
- 감사 항목 3(리터럴 복붙 스캔)이 **부분문자열 매치**라 4번째 emit 자리가 옛 패턴을
  그대로 복사해 들어와도 통과했다(F-4) — C-1이 생긴 방식 그 자체. 카운트 기반 비교로 교체.

**지금 어디 사는가**: `.claude/CLAUDE.md` §"2026-08-13 — 목적함수 통일로 또 한 번 세대가
갈렸다"가 이 세션의 상세 승계 문서다(읽기 전용, 이 정리 작업은 그 파일을 건드리지 않는다).
설계는 `docs/superpowers/specs/2026-08-13-unified-objective-design.md`. 기계 계약
`audit_objective.py`(9/9)·`test_objective.py`(29/29)·`test_surrogate_support.py`(7/7)가
현재도 그대로 게이트로 산다.

**검증된 SHA (20개, 전부 확인됨)**: `dcdea7c`·`4900206`·`995d9df`·`51a85e5`·`59809ae`·
`86ef175`·`23166b4`·`8dcb259`·`a06d932`·`c42227b`·`48e93ae`·`304e552`·`8560b34`·`02c7fd8`·
`1aadba1`·`29fc5e7`·`a05ff4c`·`f9469e9`·`b7c3061`·`c412c86`. review diff **20개**, 커밋 범위
`dcdea7c..c412c86`.

---

## 부록 — 세대 계보 요약 (이 6개 세션이 오늘의 CLAUDE.md에 어떻게 이어지는가)

```
§1 PLAN_4POLICY_5H (08-10)  4정책×8케이스 첫 표, oracle 미배선
        │
§2 seed20-verification (08-11)  통계 인프라 + 비용모델 교정
        │
§3 parallel-30seed-sweep (08-12~13)  30시드 병렬화, oracle 레인 신설,
        │                             surrogate 회귀 발견·수정, RECOVERY_SPARES 게이트
        │
        ├─→ §4 dp-oracle (08-13, 태스크1만) ──┐ 사용자가 목적함수 통일을 먼저 지시
        │                                      │
        └─→ §6 unified-objective (08-13) ←────┘  objective.json 단일 진실원, objective_hash
                        │
              §5 surrogate-rebuild (08-13~14)  재라벨·재학습 — 음의 결과(바닥선이 이김)
                        │
              (이후 세대는 .claude/CLAUDE.md §★ 결과 세대가 승계:
               2026-08-16 action-set-closure → 08-15 dp-backward-induction →
               08-16 SwapBattery courier → 08-17 one-step-deviation)
```
