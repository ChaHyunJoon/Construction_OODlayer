# 라우터 3-way 데모 UI + 자연어 해석 + DP 천장 기록 — 설계

- 날짜: 2026-08-13
- 대상 저장소: `Construction_OODlayer`, 브랜치 `oracle-rebuild-night-2026-08-10`
- 기한: **2026-08-15** (2일). 이 제약이 §5 의 스코프 컷과 §8 의 순서를 정한다.
- 선행 작업: surrogate 재구축(계획서 `2026-08-13-surrogate-rebuild` — 실행 완료·아카이브,
  `docs/superpowers/plans/README.md`)이
  **2026-08-13 밤에 별 세션에서 진행 중**이다. 이 설계는 그것이 끝난 뒤의 세계를 가정한다.
- 개정 대상: `docs/superpowers/specs/2026-08-13-dp-oracle-design.md` (§5 가 그 문서의 §4·§6 을
  뒤집는다. 그 문서 머리에 개정 배너를 붙였다.)

---

## 0. 이 문서가 무엇을 정하는가

세 개의 요구가 있다:

1. UI 가 OOD/failure 사건을 **라우터로 적응적으로 배분**하는 시뮬레이션을 렌더링한다.
2. 각 control 의 결과를 비교하는 **표**가 있다.
3. 각 사건을 **자연어로 해석**하는 화면이 있다.

그리고 두 개의 명시적 제약이 있다(사용자 결정, 2026-08-13):

- **DP 는 라우터에 들어가지 않는다.** DP 는 최적해(천장)이므로 UI 와 라우터에서 빼고,
  시뮬레이션 결과만 기록한다. → 라우터는 **3-way**, DP 는 **스윕 레인 + 표의 천장 행**.
- **비교표는 UI 에 있을 필요가 없다.** md 파일로 충분하다. → 대시보드에 표를 만들지 않고
  `build_final_table.py` 의 기존 산출 경로를 쓴다.

---

## 1. 문제 — 지금 없는 것만 (있는 것은 §2 에 적었다)

| # | 없는 것 | 근거 |
|---|---|---|
| 1 | **라우터가 2-way 다.** `canonical` 은 라우팅 대상이 아니고 escalation 경로에서만 등장한다 | `tools/monitor/policy.jl:350` — `would = v.novel ? "dspy" : "surrogate"` |
| 2 | **failure case 의 자연어 해석이 없다.** 라우터 `reason` 과 레인별 `rationale` 은 "무엇을 고를까"를 설명하고, "그래서 무슨 일이 났는가"는 아무도 말하지 않는다 | `policy.jl:673-722` 가 채우는 필드 목록에 결과 서술이 없다 |
| 3 | **비교표가 산출되지 않는다.** `build_final_table.py` 가 `compute_ceilings(oracle_dir)` 에서 `kind=fault` 라벨 행의 `energy_J=None` 으로 exit 1 | `.claude/CLAUDE.md` "단계 7 은 `build_final_table.py` 를 지금 막고 있다" |
| 4 | **표에 canonical 열과 DP 열이 없다.** 스윕 정책이 3개다 | `wm4spacecraft_manufacturing/run_shard.sh:41` — `POLICIES="${4:-noop,surrogate,dspy}"` |
| 5 | **DP 가 코드에 없다.** `dp_oracle/` 에는 결정성 프로브와 그 결과만 있다 | `dp_solve.py`·`dp_oracle_policy.py`·`grid_spec.json`·`value.json` 부재 |
| 6 | **fault/zone kind 는 J 로 채점할 수 없다.** 배터리 레이어가 `kind===:battery` instance 의 pre_sim 훅에서만 켜지므로 그 kind 들의 `energy_J` 가 NaN 이고 `Objective.J` 가 설계대로 던진다 | `.claude/CLAUDE.md` 알려진 한계 (1) + `md/STAGE7_ENERGY_ONLY_FINDING_2026-08-13.md` |

## 2. 재사용하는 것 — 이 설계가 새로 만들지 않는 것

**이 절이 2일 안에 들어가는 근거다.** 아래는 전부 이미 동작한다.

| 자산 | 위치 | 이 설계에서의 역할 |
|---|---|---|
| 라우터 판정 + 근거 기록 | `policy.jl:317` `route()` | 3-way 로 확장. `enabled`/`advisory`/`would_route_to`/`p`/`eps`/`descriptors`/`reason` 구조는 그대로 |
| **레인별 결정과 근거를 한 레코드에 동시 기록** | `policy.jl:673-722` — `canonical`·`noop`·`oracle`·`surrogate`·`dspy` 의 `chosen`·`ranking`·`margin`·`rationale`·`available` | 사건별 비교와 자연어 해석의 **데이터가 이미 스트림 안에 있다** |
| **LLM 의 선택 근거** | `dspy_service.py:157` `reasoning: OutputField(desc="one sentence")` → `:553` `rationale` → `policy.jl:712` | 요구 3 의 세 번째 항목은 **생성이 아니라 노출** |
| 대시보드 | `dashboard.html` — Fleet States · Factory View · OOD Event Feed · Controller Recovery · Assembly Tree · Robot Schedule · Re-Specification · OOD Decision(decision history / candidates / verify) | 해석 카드 1개와 라우터 문구만 손댄다 |
| 서버 | `server.jl` — `/run` `/inject/zone` `/layout` `/runinfo` `/abort` `/artifact` | 손대지 않는다 |
| 라우터 ON 렌더 경로 | `regen_router_cases.sh` (`DEMO_ROUTER=auto`, `DEMO_POLICY=router`) | 데모 판 렌더에 그대로 쓴다 |
| 현행 세대 스윕 하니스 | `run_4pol.sh` → `run_shard.sh`, `results_4pol/` (2026-08-13 22:43, 210샤드 ok/62분/630행) | 정책 목록만 늘려 재스윕 |
| 표 조립기 | `build_final_table.py` → `artifacts_4pol/FINAL.md` | 게이트만 열고 재사용. **지표 수학을 재구현하지 않는다** |
| 결정성 프로브 결과 | `dp_oracle/PROBE_RESULT.md` — `sampling_mode: replay` | DP 표집 경로를 정한다(§5) |

## 3. 라우터 — 3-way

### 3.1 규칙

```
낯설다 (p < eps)                  → LLM        기존 규칙 그대로
익숙하다 (p ≥ eps)                → surrogate  기존 규칙 그대로
surrogate 가 그 팔을 지원하지 않음 → canonical  (신규: 지금은 dspy 로만 escalate 한다)
DEMO_POLICY=noop                   라우팅하지 않음 (통제 바닥선, policy.jl:333 규칙 유지)
```

**DP 는 타깃이 아니다.** 이유는 성능이 아니라 정의다 — DP 의 a\* 는 시뮬레이터를 생성모델로
써서 오프라인 표집·backward induction 으로 얻은 값이므로, 온라인 결정 시점에 "그 표가 이미
있다"는 것은 그 사건을 미리 다 굴려봤다는 뜻이다. 그것을 실행 정책과 같은 줄에 세우면
비교가 무의미해진다(`build_final_table.py` 머리말: "그렇게 명시하지 않으면 'oracle 1등'이라는
공허한 주장이 나온다 — 정의상 항상 참이라 정보가 없다").

### 3.2 canonical escalation 이 신규인 이유

지금은 surrogate 가 지원하지 않는 팔이 필요할 때 **`dspy` 로만** 올라간다
(`policy.jl:749-758`, `escalation_reason = "no training support for ..."`). DSPy 서비스가
내려가 있으면 `available=false` 가 되어 조용히 canonical 폴백으로 떨어진다
(`policy.jl:730` — `enacted = "canonical"; fell_back = ...`). 즉 **canonical 은 이미
사실상 세 번째 주자이지만 라우터의 판정에는 그 사실이 안 적힌다.** 요구가 "canonical rule
based 를 포함한 적응적 대응"이므로, 그 경로를 판정에 명시적으로 넣는다.

### 3.3 fail-open 을 fail-visible 로

`NOVELTY_CALIB` 이 없으면 `install_novelty!()` 이 실패하고 라우터가 **꺼진 채로**
`target = POLICY` 가 된다(`policy.jl:335-339`). `regen_router_cases.sh` 는 이 조용한 실패를
사전에 죽이지만, 대시보드에는 "라우터가 꺼져 있었다"가 눈에 보여야 한다. `enabled=false` ·
`advisory=true` 를 화면 배지로 노출한다(신규, 표시 전용).

## 4. 자연어 해석 레이어 — 3항목

요구를 사용자가 셋으로 확정했다(2026-08-13): **failure case 해석 · 라우터 reason · LLM 이 왜
그 action 을 골랐는지.** 그 이상은 만들지 않는다.

| 항목 | 상태 | 작업 |
|---|---|---|
| LLM 근거 | `pol["dspy"]["rationale"]` 에 이미 있다 | 화면에 노출. **`available=false` 와 `rationale==""` 를 구분해 표시한다** — 서비스 다운을 "근거 없음"으로 읽으면 LLM 레인을 오독한다 |
| 라우터 reason | `rt["reason"]` · `rt["escalation_reason"]` 이 이미 있고 ROUTER 줄에 뜬다 | 3-way 문구 추가(canonical escalation 분기), `enabled=false` 배지 |
| **failure case 해석** | 없음 | 신규. §4.1 |

### 4.1 failure 해석기 — 결정적 템플릿, LLM 호출 없음

**어디에 사는가**: `tools/monitor/narrate.jl` (신규, 순수 함수 모듈). `policy.jl` 과 렌더 경로가
이것을 불러 스트림 레코드에 `narrative` 문자열을 **찍어 넣는다.** 대시보드는 그 문자열을 그대로
표시한다.

**왜 Julia 이고 왜 스트림에 찍는가**: 라우터와 스트림 생산자가 Julia 이고, 대시보드는 스트림을
그대로 재생하기 때문이다. 화면(JS)에서 문장을 조립하면 라이브와 재생에서 같은 코드가 돌긴
하지만 단위검사 대상이 되지 않고, 파이썬 후처리로 만들면 라이브 화면에 안 뜬다.

**두 시점에서 만든다** — 결과는 결정 시점에 알 수 없기 때문이다:

- `narrate_event(rec)` — OOD 결정마다. 무엇이 주입됐고, 누가 정했고, 왜 그 팔인가.
- `narrate_outcome(summary)` — 런 종료 시. 완주/미완주·정지·closed/total.

**재생 호환**: 재스윕 이전에 녹화된 스트림에는 `narrative` 가 없다. 화면은 그 자리를
**비운다 — 지어내지 않는다.** (`anglicize_streams.py` 머리말이 같은 문제를 다룬다: 녹화 시점의
코드가 만든 문자열은 코드를 고쳐도 이미 만든 녹화에 그대로 남는다.)

**LLM 을 쓰지 않는 이유**: 해석의 입력이 이미 구조화된 수치이고(아래), 그 수치를 문장으로
바꾸는 데 모델이 필요하지 않다. 더 중요한 이유는 검증이다 — 이 하니스는 프로세스 간
재현성이 없어서(§7) 시뮬 결과로는 아무것도 검증할 수 없는데, 순수 함수는 단위검사로 고정할
수 있다. 그리고 이 레인의 LLM 은 **정책 후보**이므로, 해석까지 LLM 이 하면 화면의 서술과
피고가 같은 모델이 된다.

입력은 스트림에 이미 있는 필드만 쓴다:

- `n_stalled` — **정지의 유일한 기계적 증거.** `run_demo.jl:472` 가 `global_logger` 를
  `Logging.Warn` 으로 심어 `battery.jl:297` 의 `[STALL]`(`@info`)이 통째로 버려진다.
  **"로그에 STALL 이 없다"를 "정지가 없었다"로 읽으면 안 된다**(CLAUDE.md).
- `complete` · `closed` / `total` — **완주 ≠ `closed==total`**. 이 하니스는 완주해도
  `closed < total` 이다(실측 291/313, `md/README.md` §6). 해석 문장이 이 둘을 혼동하면 안 된다.
- 주입된 사건: kind · severity · `soc` · `spare_count` · `agent_pending` · `progress` ·
  `zone_overlap`
- 실행된 팔과 그 출처: `enacted` · `fell_back` · `forced_from`

출력은 사건당 문장 2~3개: (a) 무엇이 주입됐는가 (b) 시스템이 무엇을 했고 누가 정했는가
(c) 결과가 어떻게 됐는가. 값이 없는 필드는 문장에서 **빠지고, 0 으로 채우지 않는다.**

**계약 (단위검사로 고정한다):**

1. 순수 함수다 — 같은 레코드에 같은 문장. 파일·네트워크·시각을 읽지 않는다.
2. 없는 필드를 지어내지 않는다. `n_stalled` 가 없으면 정지를 언급하지 않는다.
3. `complete==true ∧ closed<total` 을 미완주로 서술하지 않는다.
4. `fell_back==true` 이면 문장이 **반드시** 폴백을 말한다(조용한 폴백 금지).
5. 정지 0 을 "문제 없음"으로 서술하지 않는다 — 미완주는 정지 없이도 일어난다.

## 5. DP — 천장 기록 전용. `dp-oracle-design.md` 의 개정 델타

DP 의 설계 본문은 `2026-08-13-dp-oracle-design.md` 에 있다. 그 문서는 **같은 날 오전** 것이고,
그 뒤 세 사건(결정성 프로브 → 목적함수 통일 → 배터리 물리 복구)으로 다섯 곳이 뒤집혔다.
아래가 이 설계가 적용하는 개정이며, 원문에는 개정 배너를 붙였다.

### 5.1 개정 D1 — 표집은 `replay` 다 (§4 전체 반전)

원문 §4.1 은 "replay 기반이면 안 된다"고 하고 §4.2 로 `prefix-once, fork-per-arm`(deepcopy)을
채택했다. `dp_oracle/PROBE_RESULT.md` 의 실측이 그것을 뒤집었다:

- **주입 순간의 상태는 재현된다.** `AT_CLOSED=30`, `ORACLE_SEED=1` 로 10회 반복한 지문이
  **10/10 완전히 동일**했다. 원문 §4.1 이 인용한 발산(`n_closed 149→123`)은 **런 전체** 숫자라
  이 질문에 답하지 않는다.
- **fork 는 구조적으로 불가능하다.** 물리 상태의 상당 부분이 `PlannerEnv` 필드가 아니라
  프로세스 전역 `Ref`/싱글턴이다: `rvo_global_sim()`(PyCall 너머 RVO2 C++ 인스턴스 **하나**) ·
  `BATTERY_FLEET` · `HAZARD_STATE` · `OOD_SCHEDULE` · `SIM_STEP`. `deepcopy(env)` 가 구조체를
  복제해도 두 가지가 같은 C++ 인스턴스로 물리를 밟아 서로 간섭한다.

귀결:

- §4.2 의 루프를 `replay-per-arm` 으로 바꾼다. **팔마다 build seed 를 고정해 처음부터
  다시 굴린다.**
- §4.4(deepcopy 위험)와 **§8.1 STEP 0 차단 게이트**를 삭제한다 — 고를 경로가 하나뿐이다.
- §4.3 비용모델을 재작성한다. 실측: **콜드 88.0s / 91.0s** (프로세스당 1회 JIT·패키지 로드가
  거의 전부), **웜 8.1s/rollout**. 따라서 비용은 **워커당 착수 ~90s + 8s × rollout 수**이고,
  `MC_BATCH` 처럼 한 프로세스에서 여러 rollout 을 연속 실행해 착수비를 상각해야 한다.
- §4.2 의 "요청 ≠ 라벨"은 **유지한다.** 주입 후 실제 상태에서 φ̃ 를 다시 계산해 착지한 칸으로
  라벨한다(§5 원문). replay 라도 요청 칸에 정확히 착지한다는 보장은 없다.

### 5.2 개정 D2 — 비용은 `objective.json` 이다 (§6 재작성)

원문 §6 은 `gen_oracle_mc.jl` 의 `MC_COST_FAIL`·비용함수를 물려받고 `e1_analyze.MACRO_COST` 의
값을 리터럴로 인용한다. 그 뒤 목적함수가 통일됐다:

- `wm4spacecraft_manufacturing/objective.json` 이 J 의 **단일 진실원**이고 **energy 가 J 의
  축**이다. 현행 `objective_hash` 와 `generation` 은 그 파일에서 읽는다 —
  **이 문서에 해시를 문자열로 적지 않는다**(`audit_objective.py` 항목 9 가 문서에 박힌 옛
  해시를 스테일로 판정한다).
- 목적함수 상수(`C_fail`·`C_unclosed`·`tie_eps`·`kappa`·`M_ref`·`E_ref`)를 리터럴로 복붙하지
  않는다. 반드시 `objective.load()` / `objective.J()` 로 읽는다. 항목 1 이 12개 파일을 스캔한다.
- **`dp_solve.py` 는 감사가 이름으로 지목한 소비처다** (`audit_objective.py` 가 보는 목록에
  들어 있고, CLAUDE.md 는 "아직 레포에 존재하지 않는다"고 적어 둔 상태다). 만드는 순간
  감사 대상이 되므로 처음부터 `objective` 경유로 쓴다.
- §7 의 Bellman 식에서 `V(dead-end) = C_fail` 은 유지하되 그 값을 `objective.load()` 로 읽는다.
- MDP_DESIGN §13.2 의 legacy 버그 교정(둘 다 완주면 `closed` 로 비교하지 않는다, `better_ssp`)은
  **그대로 승계한다.** 그 근거는 목적함수 통일과 무관하게 유효하다.

> 부기: `MDP_DESIGN_FROM_SCRATCH.md` 에는 energy 도 `objective.json` 도 **한 번도 언급되지
> 않는다**(grep 확인). 그 문서는 목적함수 통일 이전의 이론 근거이므로, 인용할 때 비용함수
> 부분만은 D2 로 갈아 읽어야 한다.

### 5.3 개정 D3 — fault/zone 은 energy-only 배터리 모드가 선행조건

J 는 완주행에 유한 `energy_J` 를 요구하는데 배터리 레이어가 `kind===:battery` 에서만 켜져
fault/zone kind 의 `energy_J` 가 NaN 이다. DP 격자의 `evt` 축은 {Battery, Fault, Zone, Reform}
이므로 **fault/zone 칸의 비용이 정의되지 않는다.**

`md/STAGE7_ENERGY_ONLY_FINDING_2026-08-13.md` 가 이미 경로를 규명해 놨다: `battery.jl:486` 이
말하는 **energy-only 모드**(`enable_battery!` 만, stall/derate 는 끔)로 켜면 동역학을 바꾸지
않고 J 채점이 가능해진다. `run_demo.jl` 이 이미 그 모드로 돈다. → 이것을 DP 표집 하니스와
라벨러 양쪽의 선행 태스크로 둔다.

**이것은 동역학 변경이 아니라는 점이 핵심이다.** stall/derate 를 켜면 로봇이 실제로 멈추므로
그건 다른 세계가 된다. energy-only 는 소비만 적산한다.

### 5.4 개정 D4 — 격자 축을 현행 세대에서 재유도

원문 §3 은 축 구간을 실측 지지집합으로 깔았다(`soc` 0~0.0999, `spares` 8~12, zone 결정 812건
**전부** `blk`). 그 실측은 **구세대 스윕**이다. 2026-08-13 저녁 배터리 물리 복구(용량 축소
제거 + stall/derate 켬)로 세계가 갈렸다 — `noop` 의 battery 완주가 **30/30 → 0/30**(정지 43회)로
뒤집혔고, 자연 방전이 무시할 수준이 되어 **SoC 를 떨어뜨리는 것은 주입된 OOD 뿐**이다.

→ 축과 구간을 현행 세대 `results_4pol/`(2026-08-13 22:43, 630행)에서 다시 유도한다.
`grid_spec.json` 이 축·구간·가지치기의 단일 진실원이라는 원문 §3.2 규약은 유지한다.

### 5.5 개정 D5 — §3.1 을 새 surrogate φ 기준으로 재서술

원문 §3.1 은 `e1_analyze.featurize()`(kind one-hot + macro one-hot)와 비교한다. 재구축 중인
surrogate 의 φ 는 다르다: 상태 6축 `["harm","work_at_risk","resource_loss",
"recovery_capacity","progress","slack"]`(`features_agnostic.py:307`) + ψ 10축 + 교차 5.

**결론은 살아 있다**: 새 6축에도 `pend_f`(미해결 고장 수)와 `zone_s`(zone 활성 계열) 축이
**따로 없다.** 그래서 "zone 이 떠 있는 중에 battery 가 터진 상태"가 단일 battery 상태와
구별되지 않는다 — DP 가 φ̃ 를 따로 두는 이유가 그대로 유효하다. 비교 대상만 갱신한다.

원문 §9("surrogate 재학습은 범위 밖")도 **유지한다.** 진행 중인 재구축과 충돌하지 않기 위해,
`samples.jsonl` 을 surrogate 학습에 먹이지 않는다.

### 5.6 스코프 컷 — 2일에 맞춘다 (전부 명시적으로 기록)

원문의 예산은 700노드 × 28 CPU-h 다. 들어가지 않는다. 잘라낸 것과 이유:

| 컷 | 원문 | 이 설계 | 왜 안전한가 |
|---|---|---|---|
| **§8.6 전면 대체 보류** | `reference_policy.py` → `legacy_` 로 동결, 3818 결정 DISAGREEMENT 의무 산출, 발행 게이트 | `reference_policy.py` 를 **건드리지 않는다.** DP 는 새 레인(`dp`)으로만 들어간다 | 원문 §8.6 이 막으려던 위험이 "발행 숫자가 조용히 재채점된다"였다. 채점기를 안 바꾸면 그 위험이 **애초에 없다** |
| **격자 축소** | 700 노드 × 3팔 × K=5 | **예산 상한 = rollout 220판**(웜 8.1s 기준 ≈ 30분 + 워커 착수 ~90s). 칸 수는 D4 의 축 재유도 결과가 정하며, 상한을 넘으면 칸을 줄이지 K 를 줄이지 않는다 | 미커버 칸을 값으로 채우지 않고 `UNREACHABLE`/미수록으로 남긴다(원문 §5 규약). 상한을 칸 수가 아니라 rollout 수로 잡아야 D4 결과에 따라 계획이 안 무너진다 |
| **K=3** | K=5 (권고는 K≥10) | K=3 | §7 의 tie 규칙 유지 — `\|ΔQ\| < 1.96·SE` 면 단일 a\* 를 뽑지 않고 **tie 집합으로 보고**한다. K 가 작으면 tie 가 늘어날 뿐, 없는 확신을 만들지 않는다 |
| **7 case 전수라도 칸이 7배가 아니다** | — | 격자는 case 가 아니라 **상태** 위에 깔린다 | 7 case 는 같은 4 사건종의 조합이므로 같은 격자를 채운다. 다만 원문 §10(2) 대로 `zone_s=cov` 는 주입으로만 생기고, 안 차면 `UNREACHABLE` 로 남는다 |

### 5.7 DP 의 산출물과 표에서의 자리

산출물은 원문 §8.0 표를 따르되 `dp_oracle_policy.py` 의 역할이 바뀐다:

| 경로 | 내용 | 원문과의 차이 |
|---|---|---|
| `dp_oracle/grid_spec.json` | 축·구간·가지치기의 단일 진실원 | 축을 현행 세대에서 유도(D4) |
| `dp_oracle/samples.jsonl` | (칸, 팔, k) 당 1행. **측정된** φ̃ · 비용 성분 · s̃′ · capped · `sampling_mode` · 시드 · `objective_hash` | `sampling_mode` 는 항상 `replay`(D1). J 성분과 해시를 행에 담는다(D2) |
| `dp_oracle/value.json` | 칸당 V · Q · a\* · SE · tie 집합 · 표본수 · 수렴 여부 | 같음 |
| `dp_oracle_policy.py` | φ̃ → 표 조회 → a\*. 미수록·`INFEASIBLE`·`UNREACHABLE` 은 `None` | **`reference_policy.py` 를 대체하지 않는다.** 스윕의 `dp` 레인만 이것을 읽는다 |

표에서의 자리: `FINAL.md` 의 **천장 행**. `build_final_table.py` 가 `oracle` 행에 이미 쓰는
관례를 그대로 적용한다 — "실행 가능한 온라인 정책이 아니다 … 네 번째 주자가 아니라
천장(ceiling)/원점(origin-of-scale)".

**§8.7 게이트는 유지한다**: 실행 정책의 실현 결과가 DP 의 V 를 넘는 경우를 측정해 보고하고,
넘으면 **"천장"이라는 이름을 쓰지 않는다.** φ̃ 의 정보손실이 ceiling 을 참값 아래로 끌어내린
것이므로, 이름을 유지하면 그 자체가 거짓 주장이 된다.

## 6. 비교표 — md

- 산출물: `wm4spacecraft_manufacturing/artifacts_4pol/FINAL.md`
- 선행: §1(3) 의 exit 1 을 연다. 원인은 `compute_ceilings(oracle_dir)` 에서 `kind=fault` 라벨
  행의 `energy_J=None` 이며, 근본 해결은 D3(energy-only 모드)로 라벨을 다시 낼 때 닫힌다.
  **라벨 재생성 전에 표를 내야 하면 그 칸은 `미측정` 으로 남긴다** — `build_final_table.py` 의
  기존 규약이다("결측은 절대 0 도 빈칸도 아니다").
- 행: `noop`(바닥선) · `canonical` · `surrogate` · `dspy` · **`dp`(천장)** · `oracle`(기존 천장)
- 재스윕: 7 case × 30 seed × **5 policy = 1050 판**. 현행 630판/62분에서 **선형 외삽하면
  약 1.7시간**이다(외삽이며 측정값이 아니다 — 실제 값은 스윕 로그로 기록한다).
- **순차 실행**(함정 30). 병렬이면 HiGHS 가 다른 스케줄을 내 비교가 무효가 되고, 판당 ~2.5GB 라
  OOM 도 난다.
- 지표 수학을 재구현하지 않는다. `llm_ood_eval.py report` / `shadow_score.py` 가 계산한 것을
  그대로 읽는다(중복 구현은 문서와 아티팩트가 조용히 갈라지는 원인).

## 7. 검증 전략 — 시뮬 결과는 산출물이지 검증 수단이 아니다

**이 저장소는 프로세스 간 재현성이 없다.** 5회 반복 통제 실험에서 바이트 동일한 소스가 무관한
편집 후 재컴파일을 거쳐 다른 배정 지문을 냈다(단, 한 번 컴파일된 상태 안에서는 결정적이다).
따라서 프로세스 간 golden-hash 비교는 코드 변경 검증 게이트가 될 수 없다 — 차이가 코드 때문인지
재컴파일 때문인지 구분이 안 된다.

귀결: **아래 게이트는 전부 순수 파이썬 단위검사이거나 인프로세스 검사다.** 스윕과 데모 렌더의
숫자는 산출물로 기록하되, "이 변경이 옳다"의 근거로 쓰지 않는다.

| 게이트 | 기대값 | 무엇을 지키는가 |
|---|---|---|
| `audit_objective.py` | exit 0 (9/9) | 목적함수 상수 리터럴 복붙 금지 · Julia/Python 해시 일치 · 문서 해시 스테일 |
| `audit_action_vocab.py` | exit 0 (6/6) | 행동 어휘 단일 진실원 |
| `test_surrogate_support.py` | 7/7 | 배포 학습셋의 매크로 지원 집합 |
| `julia +lts --project=. -e 'using Pkg; Pkg.test()'` | **11 pass / 1 error**(Gurobi 라이선스 없음) | 회귀 baseline. 그보다 나빠지면 회귀다 |
| 신규 `tools/monitor/test_narrate.jl` | 전부 통과 | §4.1 의 계약 5개. **인프로세스**, 합성 레코드, 시뮬 0회 (`tools/monitor/test_live_gate.jl` 이 형식 원본) |
| 신규 `tools/monitor/test_router_3way.jl` | 전부 통과 | §3.1 의 분기표를 합성 입력으로 전수. 라우터가 Julia(`policy.jl:317`)이므로 테스트도 Julia 다 |
| 신규 `test_dp_solve.py` | 전부 통과 | 합성 격자에서 backward induction 이 손계산 값과 일치 · 같은 입력 같은 출력(원문 §8.8) |
| DP 단조성 위생검사 (원문 §8.4) | 위반은 **조사 대상**으로 표시 | 표집 버그를 싸게 잡는다. 자동 실패는 아니다(표본 노이즈일 수 있으므로 SE 와 함께 본다) |
| DP 순서동치 (원문 §8.3) | 위반은 로그로 낸다 | SSP 스칼라의 argmin 이 lexicographic 순위를 재현하는가 |
| DP §8.7 gap | 넘으면 "천장" 이라는 이름을 쓰지 않는다 | §5.7 |
| `n_capped` 집계 (원문 §8.5) | 경고와 함께 보고 | 미래가 잘리면 라벨이 낙관 편향된다 |

## 8. 순서와 의존성

- **2026-08-13 밤**: surrogate 재라벨 캠페인(별 세션). 이 설계는 **문서만** 만든다. 코드 변경 0.
- **Day 1 (08-14) — 시뮬 0회. surrogate 캠페인과 병행 가능**
  1. D3 energy-only 모드 (§5.3) — DP 와 표의 공통 선행조건
  2. `build_final_table.py` 게이트 해제 (§6)
  3. 라우터 3-way + fail-visible 배지 (§3)
  4. failure 해석기 + 단위검사 (§4.1)
- **Day 1 밤 — 시뮬. 순차**
  5. 격자 축 재유도(D4) → `grid_spec.json`
  6. replay 표집(D1) → `samples.jsonl`
  7. `dp_solve.py`(순수 파이썬·결정적, D2) → `value.json` → `dp_oracle_policy.py`
- **Day 2 (08-15)**
  8. 재스윕 5 policy (§6)
  9. `FINAL.md` 생성 + 데모 판 렌더(`DEMO_ROUTER=auto`, `DEMO_POLICY=router`) → 대시보드 재생
  10. §7 게이트 전수

의존성 중 놓치면 되돌려야 하는 것: **1 → 6**(energy-only 없이 표집하면 fault/zone 칸의 비용이
정의되지 않아 표본을 버려야 한다), **surrogate 완료 → 8**(구 모델로 스윕하면 surrogate 열이
kind 를 구분 못 하는 그 모델의 숫자가 된다).

## 9. 범위 밖 (의도적)

- **DP 를 라우터/UI 에 넣기.** 사용자 결정(§0). 정의상의 이유는 §3.1.
- UI 안의 비교표. 사용자 결정 — md 로 충분하다.
- `reference_policy.py` 대체와 DISAGREEMENT 리포트(원문 §8.6). §5.6.
- surrogate 를 φ̃ 위에서 재학습(원문 §9).
- 비결정성의 원인 규명. §7 이 그것에 의존하지 않도록 검증 전략을 짰다.
- `reform` 축의 a\*. 실측 격자가 없다. unscored 유지.
- 네 번째 κ(`set_planning_objective_weights!` 5개 레인)를 전역 κ 아래로 넣기.
  CLAUDE.md 알려진 한계 (2). 이 작업과 무관하다.
- `makespan` 의 `-1.0` 센티넬(CLAUDE.md 알려진 한계 4). CSV 재채점을 도입하지 않으므로 이
  작업에서 되살아나지 않는다. **단, `dp_solve.py` 가 `read_units()` 의 `makespan` 을 J 로
  넘기지 않는지 확인해야 한다** — 넘기면 그 버그가 살아난다.
- LLM 으로 해석 문장을 생성하기. §4.1 의 이유.

## 10. 알려진 구멍과 리스크

1. **DP 격자가 대부분 안 찰 수 있다.** 축소 격자 + K=3 이면 tie 집합이 커지고 `UNREACHABLE`
   칸이 남는다. 그러면 `dp` 행은 "천장"이 아니라 **부분 천장**이다. 커버리지 비율을
   `FINAL.md` 에 같이 적고, 낮으면 그 이름을 쓰지 않는다(§5.7 과 같은 규칙).
2. **`zone_s=cov` 표본이 안 찰 가능성이 높다.** 630판 스윕의 zone 결정 812건이 전부
   `root_covered==0`(=blk)이었다(원문 §10(2)). cov 는 주입으로만 만들어야 한다.
3. **재스윕 1.7시간은 외삽이다.** 630판/62분에서 선형으로 늘린 값이고, `dp` 레인은
   `value.json` 조회라 사실상 무료지만 `canonical` 레인은 새로 도는 판이다. 실측이 크게
   벗어나면 seed 수를 줄이는 것이 아니라 **case 를 줄인다**(seed 를 줄이면 기존 발행 표와
   비교 가능성이 깨진다).
4. **energy-only 모드가 라벨을 무효화하는 범위를 아직 안 셌다.** D3 는 채점 가능성을 열지만,
   그 모드로 다시 낸 라벨은 이전 라벨과 다른 세대다. 어느 산출물이 재생성 대상인지 Day 1 에
   먼저 세고 기록한다.
5. **surrogate 재구축이 밤에 안 끝나면** Day 2 의 8 이 밀린다. 사용자는 끝날 것으로 판단했고
   (2026-08-13), 이 설계는 그 판단을 전제한다. 안 끝나면 `surrogate` 행에 "이 모델은 kind 별
   상수 붕괴 상태(G3/G4 실패)"를 명시해 숫자를 살리되 오독을 막는다.
6. **`pol["oracle"]` 과 `pol["dp"]` 가 둘 다 천장이라 화면과 표에서 혼동될 수 있다.**
   전자는 `reference_policy.py`(측정 격자), 후자는 DP 표다. 이름과 근거 문구를 분리해 적는다.
