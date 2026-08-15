# md/ 아카이브 — 내린 문서와 꺼내는 법

이 디렉터리에서 내린 문서의 목록이다. **전부 커밋돼 있으므로 잃은 것은 없다.**

```bash
git show <SHA>:wm4spacecraft_manufacturing/md/<파일명>            # 통째로 보기
git show <SHA>:wm4spacecraft_manufacturing/md/<파일명> > /tmp/x.md
```

지금 무엇을 읽어야 하는지는 **`md/README.md` §9 문서 지도**가 답한다. 이 파일은 "예전에 있던
그 문서 어디 갔나" 에만 답한다.

---

## 1. 2026-08-17 정리에서 내린 것 (3개)

| 파일명 | 무엇이 들어 있었나 | 왜 내렸나 | SHA |
|---|---|---|---|
| `SESSION_2026-08-12_ORACLE_FIX.md` | 오라클 격자가 평가 런과 **다른 시뮬 설정**에서 돌던 것을 규명·수정한 세션 기록. 격자 v2(13행) 표, 라이브 런 토큰 구현 기록, 런당 비용 모델 | 세션 로그이고 아무도 참조하지 않았다. **측정된 함정 넷은 `README.md` §8 로 옮겼다**(아래 §3) | `fd225836` |
| `OOD_FAULT_SEVERITY_DESIGN_2026-08-12.md` | robot breakdown 의 OOD 를 무엇으로 정의할지 조사 + 잔존능력 ρ 축 설계 제안 | **제안서이고 실행되지 않았다**(코드 변경 0, 측정 0). 아무도 참조하지 않았다. 진단부(§1)의 함정은 `README.md` §8 로 옮겼다. ρ 축을 다시 하려면 이 SHA 에서 꺼내 읽을 것 | `a25fa95b` |
| `PLAN_4POLICY_5H_2026-08-10.md` | 4정책 비교표 5시간 무인 실행 계획(티어 구성·선행조건 P1~P6·판당 비용 실측) | 실행이 끝났고 그 표는 세 세대 뒤로 대체됐다. 아무도 참조하지 않았다. **선행조건 P1/P2 의 함정은 `README.md` §8 로 옮겼다** | `97a0b979` |

## 2. 그 이전 정리에서 내린 것

**2026-08-06 통합에서 흡수·삭제한 7개** — 마지막 SHA `4d723935`
(`git show 4d723935:wm4spacecraft_manufacturing/md/<파일명>`):

| 파일명 | 흡수된 곳 |
|---|---|
| `NIGHT_2026-08-02.md` · `MORNING_2026-08-03.md` · `NIGHT_2026-08-04.md` · `PLAN_0804.md` | 확정 결과 → `README.md` §3 / 정정 → §7 / 함정 → §8 |
| `PLAN_COMPLETION.md` | 완주 조사 S0~S4 → `README.md` §6 + `STATUS.md` |
| `DUMP_SCHEMA.md` | `README.md` §5 (2026-08-02 이후 스키마가 바뀌어 원문은 이미 틀렸다) |
| `ZONE_BLOCKAGE_STEP8_11_2026-08-05.md` | `ZONE_REDESIGN_STEP1_7_2026-08-05.md` 의 STEP 8~11 절 (원래 연속된 문서) |

**옛 `RESULTS.md`(E1~E4 측정 원본)** — `RESULTS.md` 는 2026-08-17 에 현행 3레인 × 7 case 결과의
단일 진입점으로 **새로 쓰였다.** E1~E4 원문이 필요하면 `git show 2bde2dd1:wm4spacecraft_manufacturing/md/RESULTS.md`.
요약은 `README.md` §3 에 그대로 있다.

**레포 밖으로 나간 상위 문서 2개** — `README.md` §9 가 예전에 가리키던 경로다.
`artifacts_mdp/OVERNIGHT_REPORT.md` 와 `artifacts_openworld/README.md` 는 2026-08-09 의
"매크로 7·8 이전 세대 산출물 일괄 삭제"(`c91b2a55`)에서 디렉터리째 사라졌다.
**복원하지 말 것** — 행동 어휘가 잘린 세대의 산출물이다(`.claude/CLAUDE.md` 참조).
`MDP_DESIGN_FROM_SCRATCH.md` 와 `LABELING_MANUAL.md` 는 **살아 있다**(`md/` 가 아니라
`wm4spacecraft_manufacturing/` 바로 아래).

## 3. 계획서 아카이브

`docs/superpowers/plans/` 의 실행 완료 계획서 14개는 **`docs/superpowers/plans/README.md`** 가
같은 형식으로 목록·SHA 를 갖고 있다. `docs/superpowers/specs/` 의 설계 문서 7개는 안 내렸다.

---

## 4. 내린 문서에서 건져 올린 함정 (전부 `README.md` §8 에 있다)

| 함정 | 출처 |
|---|---|
| 40 — 라벨 레인과 평가 레인은 **복구 손잡이**까지 같아야 한다(`DS_HOTSWAP`·`CARRIER_RESCUE`) | `SESSION_2026-08-12_ORACLE_FIX.md` §2 |
| 41 — `random_restriction_zone!` 은 오라클에 쓰면 안 된다(설계상 아무것도 안 막는다) | `SESSION_2026-08-12_ORACLE_FIX.md` §3 |
| 42 — 평가는 구역을 4개, 오라클 격자는 1개 뿌린다(`--events`) | `SESSION_2026-08-12_ORACLE_FIX.md` §4 |
| 43 — fault 의 `severity` 는 강도 축이 아니라 **표적 선정 축**이다 | `OOD_FAULT_SEVERITY_DESIGN_2026-08-12.md` §1 |
| 38 — DSPy 서비스가 꺼지면 `dspy` 이름으로 canonical 이 기록된다 | `PLAN_4POLICY_5H_2026-08-10.md` §6 + 계획서 아카이브 |
