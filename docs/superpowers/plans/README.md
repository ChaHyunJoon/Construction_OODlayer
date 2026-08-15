# 실행 계획서 — 현행 1개 + 아카이브 14개

이 디렉터리에는 **아직 살아 있는 계획서만** 둔다. 실행이 끝난 계획서는 git 이력에 두고
아래 표로만 가리킨다 — 2026-08-17 정리에서 14개(약 880 KB)를 그렇게 내렸다.

| 살아 있는 계획서 | |
|---|---|
| `2026-08-17-dp-one-step-deviation.md` | 표집을 1-step deviation 으로 바꾸는 작업. **실행 완료**, 판정은 `.claude/CLAUDE.md` §★ 결과 세대 맨 위 절과 `md/RESULTS_ONE_STEP_DEVIATION_2026-08-17.md`. |

**설계 문서는 안 내렸다** — `docs/superpowers/specs/` 7개는 전부 살아 있다. 계획서는 "어떤
순서로 무엇을 쳤나"(과정)이고 설계 문서는 "왜 그렇게 정했나"(아직 유효한 결정)이기 때문이다.

---

## 아카이브 — 꺼내 읽는 법

```bash
git show <SHA>:<경로>            # 통째로 보기
git show <SHA>:<경로> > /tmp/x.md
```

경로는 전부 `docs/superpowers/plans/<파일명>` 이다.

| 파일명 | 무엇이 들어 있었나 | 왜 내렸나 | SHA |
|---|---|---|---|
| `2026-08-06-forbidzone-surrogate-retrain.md` | ForbidZone 발화 + surrogate 매크로 7·8 재학습 절차 | 실행 완료. 결과는 `md/SUMMARY_FORBIDZONE_RETRAIN_2026-08-07.md` · `md/RESULTS_LLM7H.md` | `878578ec` |
| `2026-08-11-oracle-canonical-lanes.md` | canonical·oracle 레인 70판 추가 절차 | 실행 완료. 그 레인은 이후 세대에서 4정책 표로 흡수됐다 | `a25fa95b` |
| `2026-08-11-seed20-verification.md` | 시드 20 확장 + 리포트 산문에서 표본수 하드코딩 제거 | 실행 완료. 회귀 게이트 `test_report_sample_size.py` 가 계약으로 남았다 | `a25fa95b` |
| `2026-08-11-threemetric-4lane-20seed.md` | 3지표 4레인 20시드 스윕 | 실행 완료. 30시드 세대로 대체됐다 | `a25fa95b` |
| `2026-08-12-depot-distance-20-full-regen.md` | 창고 거리 D=20 전면 재생성 | 실행 완료. 결과는 `md/RESULTS_D20_2026-08-12.md`(🔴 구세대) | `27cbad97` |
| `2026-08-12-far-depots-and-metric-matrix.md` | 원거리 창고 + 4지표 행렬 | 실행 완료. 설계는 `specs/2026-08-12-far-depots-and-metric-matrix-design.md` 에 살아 있다 | `4bfbeab5` |
| `2026-08-12-live-zone-run-token.md` | 대시보드 런 토큰 + 구역 확정 전 무기록 | 실행 완료. 설계는 `specs/2026-08-12-live-zone-run-token-design.md`, 흐름도는 `tools/monitor/README.md` | `ff23aa8d` |
| `2026-08-12-parallel-30seed-sweep.md` | 30시드 병렬 스윕 하니스 | 실행 완료. 하니스는 `run_4pol_parallel.sh` 로 살아 있고 설계는 `specs/2026-08-12-parallel-30seed-sweep-design.md` | `946d4bcb` |
| `2026-08-13-dp-oracle.md` | DP oracle 격자·φ̃·표집·솔버 구축 | 실행 완료. **설계 `specs/2026-08-13-dp-oracle-design.md` 는 살아 있다**(§2.1·§8.6·§8.7·§9 가 아직 인용된다) | `a25fa95b` |
| `2026-08-13-surrogate-rebuild.md` | surrogate 상수-정책 붕괴 대응 재구축 | 실행 완료. 결과는 `md/RESULTS_SURROGATE_REBUILD_2026-08-14.md`, 설계는 `specs/2026-08-13-surrogate-rebuild-design.md` | `390bbdf7` |
| `2026-08-13-unified-objective.md` | 목적함수 J 통일(`objective.json` 단일 진실원) | 실행 완료. **설계 `specs/2026-08-13-unified-objective-design.md` 와 기계 계약 `audit_objective.py`(9/9) 가 그 자리를 대신한다** | `a25fa95b` |
| `2026-08-14-router-ui-demo.md` | 라우터 3-way UI + 화면의 목적함수 + DP 레인 | 실행 완료. 결과는 `md/RESULTS_ROUTER3WAY_2026-08-14.md`, 설계는 `specs/2026-08-13-router-ui-demo-design.md` | `a25fa95b` |
| `2026-08-15-dp-backward-induction.md` | DP 를 진짜 backward induction 으로 | 실행 완료. 결과는 `md/RESULTS_DP_BACKWARD_2026-08-15.md`. 이 계획서의 Global Constraints 에 있던 함정은 `md/README.md` §8 로 옮겼다 | `2a3cc4a9` |
| `2026-08-16-action-set-closure.md` | 행동 어휘 소비처 셋을 `action_registry.json` 파생으로 통일 | 실행 완료. 결과는 `md/RESULTS_ACTION_SET_CLOSURE_2026-08-16.md` | `195aa7ae` |

---

## 계획서에만 적혀 있던 함정은 어디로 갔나

계획서의 `## Global Constraints` 절은 이 저장소에서 함정이 처음 적히는 자리였다. 내리기 전에
**`md/README.md` §8 로 옮긴 것**(각각 실측 근거가 있는 것들):

- 긴 런을 `| head`/`| grep -m` 으로 파이프하면 SIGPIPE 로 Julia 가 죽는다 (§8 함정 36)
- `git stash -u` 가 `.venv/`·`results_4pol/` 까지 쓸어간다 (§8 함정 37)
- DSPy 서비스가 꺼져 있으면 `policy.jl` 이 **에러 없이** canonical 로 폴백하는데 요약 행의
  `policy` 는 `"dspy"` 로 남는다 (§8 함정 38)
- `zonecore` 는 `DEMO_OOD_STREAM3=1` 에서 `zone` 으로 바뀐다 — 다른 case 가 아니다 (§8 함정 39)
- 요약 행 스키마의 이름들(`closed`/`ood_seed`/`geometry`) (§5)

나머지 Global Constraints(순차 실행·`julia +lts`·`.venv/bin/python`·리터럴 복붙 금지 등)는
이미 `md/README.md` §8 과 `.claude/CLAUDE.md` 에 같은 내용으로 있다.
