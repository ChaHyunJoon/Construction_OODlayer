# 오라클 하니스 결함 규명과 수정 (2026-08-12)

> 이 문서는 `md/RESULTS_D20_2026-08-12.md` 의 **ORACLE 열이 왜 틀렸는지**를 밝히고 고친 기록이다.
> 그 문서의 ORACLE 열 숫자는 이 문서 §5 로 대체된다. 나머지 세 열(CANONICAL/SURROGATE/LLM)은
> 이번 변경의 영향을 받지 않는다 — 수정은 전부 라벨러 경로에만 들어갔다.

## 0. 한 줄

오라클 격자는 평가 런과 **다른 시뮬레이터 설정**에서 돌고 있었다. 복구 손잡이 두 개가 꺼져 있어
로봇이 대열에서 빠지는 팔은 무엇이든 완주할 수 없었고, zone 사건은 설계상 아무것도 막지 않는
주입기를 쓰고 있어 사건이 아니었다. 둘 다 고쳤고, 각각 같은 세션 A/B 로 인과를 확인했다.

---

## 1. 증상

`results/matrix_d20.csv` 의 ORACLE 열:

| 케이스 | ORACLE |
|---|---|
| battery | 3/3 완주 |
| **fault** | **0/1 완주** |
| zone | 1/1 완주 |
| 조합 4종 | n=0 |

"모든 결정을 다 해본 오라클이 왜 완주를 못 하나"가 이 조사의 출발점이었다.

### 1-a. 먼저 정정 — 조합 4칸은 실패가 아니다

`results_matrix.py:44` 의 `ORACLE_KIND` 는 단일 사건 3종만 매핑하고, `:209` 가 `None` 셀을 CSV 에
`0,0` 으로 적는다(`.md` 는 `—`). 조합 케이스는 **격자가 없는 것**이지 실패한 것이 아니다. 실제로
측정된 오라클 칸은 셋뿐이고 그중 미완주는 fault 하나다.

---

## 2. 근본 원인 ① — 라벨러와 평가가 다른 세계를 돈다

### 증거

같은 seed 1, 같은 D=20 기하, **같은 매크로(Replace)** 인데 결과가 반대다.

| | complete | closed | makespan |
|---|---|---|---|
| 오라클 격자 | False | 243 | Inf |
| 평가 런 (canonical/surrogate/dspy 전부) | True | 291/313 | 22.75s |

결정이 아니라 세계가 다르다. `tools/regen_d20.sh` 의 오라클 레인은 `DS_KINDS/DS_SEEDS/DS_SPARES/
DS_VALID_ONLY/DS_RESUME` 만 주고 **복구 손잡이를 주지 않았다**:

| 손잡이 | 라벨러 기본값 | 평가 기본값 |
|---|---|---|
| hot-swap (정체성보존 교체) | `gen_oracle_dataset.jl:1352` → **OFF** | `run_demo.jl:404` `set_hot_swap!(enabled=true)` **무조건 ON** |
| carrier rescue | `replace_robot.jl:804` → **OFF** | `run_demo.jl:408` 기본 **ON** |
| 배경 reform | `gen_oracle_dataset.jl:1347` 120초 ON | `DEMO_REFORM` |

`replace_robot.jl:715-727` 이 이 실패를 이미 서술해 뒀다 — 낀 carrier 가 하역 목표에 못 닿고,
`reform_stuck_teams!` 는 *forming* 팀만 건드리므로 **원리적으로 이 유닛을 못 구한다**. 대기 팀들이
정지 장애물이 되어 악순환이 돌고 no-progress cap 에 걸린다. 같은 주석이 이어서 말한다:

> "DEFAULT OFF (`CARRIER_RESCUE=1` to enable) … **every oracle label measured without it
> (e.g. Replace = 172 closed on a mid-build fault) would have to be regenerated**"

즉 오라클은 **못 고치는 복구단(reform)만 켜고, 고치는 복구단(carrier rescue + hot-swap)은 끈 채**
라벨을 만들었다.

### 같은 세션 A/B (2026-08-12 21:25~21:37)

fault 인스턴스 하나. A = `regen_d20.sh` 와 동일 env, B = 거기에 두 줄만 추가. 순차 실행.

| 팔 | A (현행) | B (+DS_HOTSWAP=1 CARRIER_RESCUE=1) |
|---|---|---|
| NOOP | ✗ closed 184, Inf | ✗ closed 261, Inf |
| **Replace** | ✗ closed 243, Inf | **✓ closed 291, 22.75s** |

A 가 원본 덤프를 정확히 재현했으므로(184/243) 세션 비결정성이 아니다. B 의 `291 / 22.75s` 는
평가 런의 fault 결과와 **일치**한다.

### 왜 battery 만 3/3 이었나 — 같은 원인의 뒷면

| instance | 팔 | 완주 | closed |
|---|---|---|---|
| (무사고 대조군) | — | ✓ | 291 / 22.425s |
| fault | NOOP / Replace | ✗ / ✗ | **184 / 243** |
| battery sev0.02 | NOOP / Replace | ✗ / ✗ | **184 / 243** |
| battery sev0.02 | SwapBattery | ✓ | 291 / 22.425s |
| battery sev0.3·0.5 | NOOP / Deprioritize | ✓ | 291 |

fault 와 deep battery 의 closed 가 **같다**. SoC 0.02 는 모션 정지라 고장과 같은 사건이기 때문이다.
규칙은 하나였다 — **로봇을 대열에서 빼는 팔은 전부 미완주, 안 빼는 팔만 완주.** SwapBattery 는
로봇을 안 빼므로(배터리만 교체) 대조군과 수치가 같고, 얕은 battery 는 로봇이 안 죽어 교착이 없다.

### 수정

`tools/regen_d20.sh` 오라클 레인에 `DS_HOTSWAP=1 CARRIER_RESCUE=1`.

---

## 3. 근본 원인 ② — 오라클의 zone 은 사건이 아니었다

### 증거

`n44_plus78_d20.jsonl` 의 zone 인스턴스:

```
zone_blocked 0 · zone_overlap 0.0 · zone_work_overlap 0
zone_root_cover 0.0 · zone_teams_covered 0/7 · radius 0.28 · center (-6.36, -13.82)
```

NOOP 과 RelocateBuild 가 **완전히 동일**하고(291 / 22.425s) 무사고 대조군과도 동일했다. 아무 일도
일어나지 않았다. 그 1/1 완주는 "오라클이 zone 을 풀었다"가 아니라 "zone 이 사건이 아니었다"다.

원인은 주입기 선택이다. `gen_oracle_dataset.jl:1275` 의 `:zone` 가지가 `CB.zone_action(:zone_ds)`
= `random_restriction_zone!` 을 썼는데, 그 함수는 설계상 아무것도 막지 않는다:

- `max_radius = 2 × default_robot_radius()` = 0.28 — **상한에 정확히 걸렸는데도 0 을 막았다**
- `rmax = min(frac, 1-frac)·seglen − margin` — "both endpoints stay outside"
- `seed === nothing → Random.GLOBAL_RNG` — **시드 없음, 재현 불가**

그리고 같은 파일 `:325` 가 스스로 적어 뒀다: *"random_restriction_zone! deliberately caps the radius
so the zone is a harmless LOCAL detour → **inadmissible for the oracle**"*. 오라클에 쓰면 안 된다고
명시된 주입기를 오라클 격자가 쓰고 있었다.

더 큰 문제는 평가 쪽 `:zone` 이 **다른 주입기를 다른 시점에** 쓴다는 것이었다
(`run_demo.jl:484` `inject_blocking_zone!`, 스텝 전 1회). 두 열이 다른 사건을 겪으면 "오라클이
최적인가"라는 질문 자체가 성립하지 않는다.

### 수정

`gen_oracle_dataset.jl` 에 `place_eval_matched_zone!` 신규 — `run_demo.jl:192` 의 절차를 그대로
옮겼다(항법 목표 위 blocking zone, 결정적 정렬, 심은 뒤 `n_blocked ≥ 1` 확인). 배선:

- 구역은 **pre_sim 훅**에서 심는다 = 평가와 같은 단계(`full_demo.jl:836` 이 env 완성 직후·sim 루프
  직전에 훅을 부른다).
- 결정은 종전대로 발화점에서 낸다 — 평가도 `ZONE_DECIDE_DEFERRED` 로 첫 배치가 닫힌 뒤
  (closed≈58) 결정하고, `FIRE_POINTS[:zone]` 도 첫 배치에서 같은 지점으로 모인다.
- 훅은 control 판에도 돌므로 `build_injection(...; inject)` 로 막았다. **대조군 = 같은 세계 minus
  이 사건**이어야 하는데, zone 의 훅은 계측 설정이 아니라 사건 그 자체다.
- `record_ood_truth!` 은 발화 시점에 한 번만 — shim 의 `event_context` 가 NL 문자열로 truth 를 찾는다.

### 결정 상태가 평가와 일치함을 확인

평가 `dec0` 의 `zone_primitives` vs 오라클 v2:

| | 평가 dec0 (closed=58) | 오라클 v2 |
|---|---|---|
| n_nav_blocked / n_nav_goals | 3 / 135 | 3 / 135 |
| n_restage_feasible | 0 | 0 |
| relocate_feasible | True | 1 |
| n_teams_forming | 7 | 7 |
| root_covered | 0 | 0.0 |
| valid | `[NOOP, RelocateBuild]` | `[0, 7]` |
| NL | `zone at (1.09, 0.42) r=0.07` | 동일 |

---

## 4. 남은 비교 불가 — 사건 **수**

평가의 zone 케이스는 `llm_ood_eval.py:494` 의 `--events` 기본값이 4 라 **구역을 4개** 뿌린다
(closed 58 / 100 / 150 / 184, 매번 새 좌표). 오라클 격자는 **1개**다. 첫 결정은 위 표대로 동일하지만
그 뒤 3개가 더 온다.

따라서 ORACLE 의 makespan 을 같은 행의 컨트롤러 열과 나란히 놓으면 안 된다 — 오라클이 더 쉬운
문제를 풀고 있다. 최적성을 확인하려면 **사건 수를 맞춘 런**(`--events 1`)이 필요하다.

이것은 이번 수정 이전부터 있던 어긋남이다(그때는 사건 종류까지 달라 가려져 있었다).

---

## 5. 오라클 격자 v2 (`oracle/out/n44_plus78_d20_v2.jsonl`, 13행, 10분 19초)

| instance | 팔 | v1 | v2 |
|---|---|---|---|
| fault | NOOP | ✗ 184 / Inf | ✗ 261 / Inf |
| fault | **Replace** | ✗ 243 / Inf | **✓ 291 / 22.750** |
| battery sev0.02 | NOOP | ✗ 184 / Inf | ✗ 261 / Inf |
| battery sev0.02 | **Replace** | ✗ 243 / Inf | **✓ 291 / 22.750** |
| battery sev0.02 | SwapBattery | ✓ 291 / 22.425 | ✓ 291 / 22.425 |
| battery sev0.3 | NOOP / Deprioritize / SwapBattery | ✓ 22.725 / 22.725 / 22.425 | 동일 |
| battery sev0.5 | NOOP / Deprioritize / SwapBattery | ✓ 22.875 / 22.875 / 22.425 | 동일 |
| zone | NOOP | ✓ 291 / 22.425 | ✓ 291 / **39.025** |
| zone | **RelocateBuild** | ✓ 291 / 22.425 | ✓ 291 / **24.575** |

읽는 법:

- **fault ORACLE 이 0/1 → 1/1** 이 된다. `RESULTS_D20` 의 "Task 4 가 fault 규칙을 재유도하지 못하고
  재검증 안 됨" 도 이걸로 풀린다 — 이기는 팔이 존재할 수 없는 격자였다.
- **battery sev0.3/0.5 는 한 자리도 안 변했다.** 진단이 옳았다는 확인이다 — 로봇이 대열에서 안
  빠지므로 애초에 교착이 없었다.
- **zone 의 동점이 깨졌다.** 이전에는 두 팔이 바이트 동일이었고, 지금은 RelocateBuild 가 14.5초
  앞선다. NOOP 은 대조군 대비 +16.6초 손해.
- 팔 집합(valid_mask)은 v1/v2 가 동일하다 — `_zone_arms_for` 등 유효성 논리는 안 건드렸다.

---

## 6. 라이브 세션 런 토큰 (계획서 Task 1~4)

`docs/superpowers/plans/2026-08-12-live-zone-run-token.md` 를 구현했다. 이 작업은 **대화형 대시보드
경로만** 바꾸며 행렬·오라클 숫자에 영향이 없다(계획서 스스로 자동 주입기를 비목표로 못박았다).

신규 `tools/monitor/run_header.jl` · `zone_command.jl` · `test_live_gate.jl`,
수정 `server.jl`(run_id 발급·평면도 이전 주입 409·`GET /runinfo`·html no-store·serve 가드) ·
`render_demo.jl`(게이트 통과 후에야 스트림을 열고 사이드카 기록) · `dashboard.html`(자기 run_id 의
프레임만 화면에 올림) · `README.md`(흐름도).

검증: `julia +lts --project=. tools/monitor/test_live_gate.jl` → **27 PASS / 0 FAIL** (exit 0).

### 계획서에서 고친 두 가지

1. **기대값 오류.** 계획서는 `basename(run_info_path("tractor.mpd__zone"))` 을
   `"tractor_mpd__zone.run.json"` 으로 기대했으나, `safe_base` 는 `splitext` 로 확장자를 떼므로 실제는
   `"tractor.run.json"` 이다(디스크의 `commands/tractor.jsonl` 이 증거). 코드가 아니라 기대값을 고쳤다.
   계획서가 "가장 중요한 한 줄"이라 부른 엔진↔서버 경로 일치 검사는 통과한다.
2. **검사가 추적 파일을 삭제.** Task 3 의 뒷정리 블록이 실제 `commands/tractor.jsonl` ·
   `tractor.layout.json` 을 지웠다(한 번 실제로 지워져 `git checkout` 으로 복구). 원본을 떠 두었다
   되돌리도록 고치고 그 사실을 검사 한 줄로 못박았다.

### 미완

Task 5(실제 런 e2e + 비대화형 회귀 + 사람의 브라우저 확인)는 **단일 런 슬롯**을 행렬과 다투므로
아직 하지 않았다. Step 5 는 사람이 브라우저에서 확인하는 단계다.

---

## 7. 비용 모델 (실측)

런당 = **고정 오버헤드 188초**(Julia 기동+컴파일+env 빌드 MILP; 4판에서 186/187/189/192로 일정)
+ 시뮬 시간. zone 4케이스 평균 시뮬 87초 → 런당 275초.

| 단위 | 계산 | 소요 |
|---|---|---|
| 한 시드 (4케이스 × 3정책 = 12런) | 12 × 275s | **55분** |
| 시드 10 (120런) | | **9.2 h** |
| 시드 20 (240런) | | **18.3 h** |
| 시드 30 (360런) | | **27.5 h** |
| 오라클 격자 | 축이 다름(world seed) — 곱해지지 않음 | **1회 10분 19초** |

**병렬 불가(이 머신).** 16코어지만 가용 RAM 3.8 GB 에 시뮬 프로세스당 ~2.5 GB. 그리고 CPU 경합 시
HiGHS 가 다른 스케줄을 내 비교가 무효가 된다(저장소의 반복 확인된 함정).

**유일한 지렛대**: 275초 중 188초(68%)가 준비이고, world seed 가 1 고정이라 **모든 런이 똑같은
env 를 새로 짓는다**. 한 프로세스에서 env 를 한 번 짓고 정책 3개를 돌리면 시드 30 이 27.5h → 약 14h.
런 격리가 깨지므로 순차 기준선 확보 후 별건으로 검증할 것.

---

## 8. 재현

```bash
# 오라클 격자 v2 (10분)
bash tools/regen_d20.sh oracle out/n44_plus78_d20_v2.jsonl

# 행렬 — zone 축만 (55분/시드). DSPy 서비스가 127.0.0.1:8077 에 떠 있어야 한다
REGEN_CASES="zone fault_zone battery_zone all" \
  bash tools/regen_d20.sh matrix 1 results/matrix_d20_v2.jsonl

# 라이브 게이트 검사 (초 단위)
julia +lts --project=. tools/monitor/test_live_gate.jl
```

`REGEN_CASES` 는 이번에 추가한 손잡이다(기본은 종전대로 7케이스 전부).

---

## 9. 이 문서가 만든 부채

- `md/RESULTS_D20_2026-08-12.md` 의 ORACLE 열은 **이제 틀렸다**. §5 로 갱신하거나 배너를 붙일 것.
- `--events` 불일치(§4)는 아직 안 고쳤다. `--events 1` zone 런을 떠서 1:1 로 대면 된다(3판, ~14분).
- `inject_blocking_zone!` 의 절차가 이제 **세 곳**에 있다(`run_demo.jl`, `render_demo.jl`,
  `gen_oracle_dataset.jl::place_eval_matched_zone!`). 셋이 갈리면 세 엔진이 다른 세계를 만든다.
  공유 모듈로 빼는 것이 옳지만, render 경로는 발표에 쓴 산출물의 재현성이 걸려 있어 미뤘다.
