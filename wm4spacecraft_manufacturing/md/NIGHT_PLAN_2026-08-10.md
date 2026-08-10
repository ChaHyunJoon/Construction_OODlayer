# 야간 자동 실행 계획 — E → D → A → B → C (2026-08-10)

`ORACLE_REBUILD_2026-08-09.md` 의 STEP 을 **사용자 개입 없이** 하룻밤에 실행하기 위한 작업 계획서다.
각 STEP 은 코드 작업(Task N) 과 실행 구간(RUN-x) 으로 나뉘고, 실행 구간마다 **검증 서브에이전트**가
이 문서의 "합격 조건"과 산출물을 대조한다.

## 실행 순서 (사용자 지정)

```
STEP E (라우터 ON) → RENDER (case별 렌더링) → STEP D (오라클 복구)
  → STEP A (shadow 재채점) → STEP B (시드 6-10) → STEP C (case별 격자)
```

`RENDER` 를 E 직후에 두는 이유: 사용자 요구가 "**Router 를 on 함으로써** 만들어두었던 UI dashboard
에 각 failure case 별 rendering" 이므로 라우터 ON 설정이 곧 렌더링의 입력이다. 또한 렌더링은 하드
산출물이므로 시간이 모자랄 때 잘려나가면 안 된다.

## 측정된 사실 (2026-08-10 00:34 실측 — 추정 아님)

| 값 | 실측 | 근거 |
|---|---|---|
| 라벨러 STEP 0 스모크 | **PASS**, exit 0, 3 rows / 1 instance | `_night/logs/step0_smoke.log` |
| 스모크 wall | 6m58s (Julia env 빌드 ~210s 포함) | 같은 로그 |
| 라벨 1팔 한계비용 | **~70 s** (418s − 210s startup) / 3팔 | 위에서 유도 |
| dspy 서비스 | 8090 = 문서상 재현 포트 (gpt-4o, seed-only) | `md/RESULTS_LLM7H.md:153,170` |
| 가용 메모리 | 사용자가 앱 정리 후 확보 | 계획서 §5 함정 ② |

`LABELING_MANUAL.md:332` 의 **221 s/판** 은 다른 설정(TIER A 전체 라벨 패스)의 값이라 이 야간
실행에는 적용되지 않는다. 예산은 위 실측 70 s/팔 을 쓴다.

## Global Constraints — 모든 Task 에 구속력이 있다

1. **★ Julia 시뮬레이션은 절대 병렬 금지** (README 함정 30). 어떤 순간에도 `julia` 시뮬 프로세스는
   **하나**뿐이어야 한다. 병렬이면 HiGHS 가 다른 스케줄을 내 정책 비교 자체가 무효가 되고,
   판당 ~2.5 GB 라 OOM 도 난다. 구현자는 시뮬이 도는 동안 **어떤 julia 명령도 실행하지 말 것.**
2. **기존 측정 아티팩트를 덮어쓰지 말 것.** `results/llm_ood_eval.jsonl`,
   `artifacts_llm7h/final.json`, `results_table.md` 는 `_backup_2026-08-10/` 에 백업돼 있다.
   새 산출물은 **새 경로**로 쓴다. case별 스위프는 반드시 `--out` 을 분리한다(함정 ①).
3. **행동 어휘의 단일 진실원은 `action_registry.json`** — 매크로 id/이름 리터럴 복붙 금지.
   현행 지원 집합은 `[0,1,2,3,4,7,8]` (`test_surrogate_support.py` 7/7 이 그 계약).
4. Julia 는 언제나 `julia +lts --project=.`, Python 은
   `C:\Users\chahj\PythonCodes\venv\hjcrl\Scripts\python.exe`.
5. **모든 신규 스크립트는 재개 가능(resumable)해야 한다** — 이미 끝난 산출물이 있으면 건너뛰고,
   중단 후 재실행하면 이어서 돈다. 그리고 **머신리더블 상태줄**(`STATUS <step> <ok|fail> ...`)을
   stdout 마지막에 남긴다. 야간 무인 실행에서 이게 유일한 판정 근거다.
6. **조용한 실패 금지.** 파일이 없거나 게이트가 안 켜졌으면 **에러로 죽어야** 한다.
   특히 라우터가 fail-open 으로 꺼지는 경로(`policy.jl:67-68`)와 zone 축이 n=0 으로 통과하는 경로
   (`test_llm7h.py:138-141`)는 이번 작업이 반드시 검출해야 하는 두 함정이다.
7. 주석은 저장소 스타일대로 **한글**로, 초보자가 읽을 수 있게. 코드 스타일은 주변 파일에 맞춘다.
8. "됐다/통과"라고 쓰려면 **실행한 명령과 그 출력**을 함께 적는다. 안 돌렸으면 안 돌렸다고 쓴다.

---

## Task 1 — `llm_ood_eval.py`: 라우터 옵트인 + case 인식 dedup

**파일**: `wm4spacecraft_manufacturing/llm_ood_eval.py` (이 파일만)

STEP E 와 STEP C 의 선행조건 두 개를 한 파일에서 고친다.

### 1-a. 라우터 옵트인 (STEP E 선행)

`run_one` 이 `DEMO_ROUTER="0"` 을 **하드코딩**한다(`llm_ood_eval.py:72`). 이걸 인자로 뺀다.

- `run` 서브커맨드에 `--router` 추가. 허용값 `0|1|auto`, **기본값 `0`** (기존 동작 보존).
- `run` 에 `--novelty-calib PATH` 추가. 주어지면 `NOVELTY_CALIB` 환경변수로 넘긴다.
  기본값은 빈 문자열(= 환경변수를 건드리지 않음).
- **`--router` 가 `0` 이 아닌데 `--novelty-calib` 가 비어 있으면 즉시 에러로 죽을 것.**
  이유: 교정 파일이 없으면 `policy.jl:67-68` 이 **경고만 찍고 라우터를 꺼버린다(fail-open)**.
  그러면 "라우터 ON" 이라고 이름 붙은 판이 실제로는 라우터 OFF 로 측정된다 — 이번 STEP 이
  막아야 할 가장 위험한 조용한 실패다.
- `--novelty-calib` 가 주어졌는데 그 경로에 파일이 없어도 즉시 에러.

### 1-b. 라우터가 실제로 켜졌는지 사후 검증 (조용한 실패 방지)

`--router != 0` 로 돈 판에 대해, 요약 행의 `decisions[]` 를 읽어 **라우터가 실제로 구동됐는지**
확인하고, 아니면 그 판을 `FAILED` 로 보고한다.

- 판정 근거: 결정 레코드의 `router_target` 이 채워져 있고(`run_demo.jl:284`), 그 값이
  base policy 와 다를 수 있어야 한다. 최소 판정은 **`router_target` 이 non-null 인 결정이 1개 이상**.
- `DEMO_POLICY` 는 `noop` 이면 안 된다(`policy.jl:332` 가 noop 에서 라우팅을 끈다).
  `--router != 0` 인데 `--policies` 에 `noop` 이 들어 있으면 **에러로 죽을 것.**

### 1-c. case 인식 dedup (STEP C 선행 · 함정 ①)

`load_rows` 의 dedup 키에 `case` 가 빠져 있어(`llm_ood_eval.py:130`), 기본 `--out` 으로 case별
스위프를 돌리면 battery 판이 fault 판을 **에러 없이** 덮어쓴다.

```python
dedup[(r.get("case"), r.get("ood_seed"), r.get("policy"))] = r
```

- `paired()` 도 같은 이유로 `(case, ood_seed, policy)` 로 색인해야 한다(`llm_ood_eval.py:199`).
  지금은 case 를 섞어 짝을 맞춘다.
- 하위호환: 기존 행에 `case` 열이 이미 있고 전부 `"all"` 이므로 기존 데이터는 그대로 읽힌다.
  **`_backup_2026-08-10/llm_ood_eval.jsonl` 로 읽어서 26행이 그대로 나오는지 확인할 것.**
- `report` 출력 머리말에 **어떤 case 가 섞여 있는지** 한 줄로 찍는다(사람이 눈으로 잡게).

### 1-d. escalation / risk–coverage 리포트 (STEP E 요구)

`report` 에 2층 구조를 재는 축을 추가한다. 이게 없으면 STEP E 는 숫자를 못 낸다.

- **escalation rate** = `escalated == true` 인 결정 비율 (분모 = 채점된 결정 수).
- **novelty 발화율** = `router_novel == true` 비율.
- **risk–coverage**: `router_p` 를 신뢰도로 보고, 상위 커버리지 구간별 적중률.
  최소 형태는 커버리지 100/75/50/25% 네 점의 적중률 표.
- 세 축 모두 `--md` 출력에도 들어가야 한다.

**합격 조건**
- `python llm_ood_eval.py run --router auto --policies noop` → **에러로 죽는다**.
- `python llm_ood_eval.py run --router auto` (calib 없음) → **에러로 죽는다**.
- `python llm_ood_eval.py report --out _backup_2026-08-10/llm_ood_eval.jsonl` → 기존과 동일한
  26행/정책별 집계가 나온다(회귀 없음).
- 새 인자 없이 부른 기존 명령줄은 **동작이 바뀌지 않는다**.

---

## Task 2 — `shadow_score.py` 신규 (STEP A)

**파일**: `wm4spacecraft_manufacturing/shadow_score.py` (신규, ~120줄 이내)

새 시뮬 **0회**로 §3 의 회수분을 계산한다. 모든 결정 레코드가 `rule`/`surrogate`/`llm` 세 producer 의
선택을 이미 기록하고 있다(2026-08-10 실측: 209/209 결정 전부 non-null).

- 입력: `--in results/llm_ood_eval.jsonl` (기본), 여러 개 받을 수 있게 할 것(case별 파일 합산).
- 채점기는 `reference_policy.score` **재사용**(재구현 금지).
- 산출 1 — **동일 사건·동일 분모** 위의 producer 채점: `rule` / `surrogate` / `llm` / 실제 `macro`.
  §1 표의 분모 불일치(47/49/29/30)가 이걸로 해소된다.
- 산출 2 — **B1 kind→macro 룩업표**: `truth` 만 보고 최빈 정답을 고르는 3행짜리 표.
  구현은 `e1_analyze.py:377-379` 의 `always_per_kind` 와 **같은 방식**(훈련 폴드 최빈값)이어야 한다.
- 산출 3 — **B2 random-over-valid**: `valid` 위 균등추첨의 **해석적 기댓값**
  (= mean over decisions of `1/|valid|` when a* ∈ valid, else 0). 몬테카를로 말고 기댓값으로.
  zone 은 `valid=[NOOP, RelocateBuild]` 라 기댓값 50% 가 바닥선이다.
- 산출 4 — **novelty 게이트 사후 재생**: `router_novel` / `router_p` 분포와, "라우터가 켜졌다면
  LLM 으로 올라갔을 결정" 비율.
- 출력: `llm_ood_eval.py report --md` 와 **같은 형식**의 markdown 조각 (`--md PATH`).

**반드시 출력에 포함할 해석 한계 문단** (계획서 §3 에서 그대로 복사, 축약 금지):

> 실행된 정책이 이후 세계를 갈라놓으므로 shadow 채점은 "이 상태에서 정책 X 는 a\* 를 골랐겠는가"
> (상태 조건부 결정 충실도)이지 **결과 비교가 아니다.** 완주·시간·에너지를 shadow 로 말하면 안 된다.

**합격 조건**: `python shadow_score.py --in results/llm_ood_eval.jsonl --md artifacts_night/shadow.md`
가 exit 0 이고, 4개 producer + B1 + B2 가 **같은 분모**로 찍히며, 한계 문단이 출력에 있다.

---

## Task 3 — STEP D 파트 1: firegrid 레인 러너

**파일**: `wm4spacecraft_manufacturing/oracle/run_firegrid_fault.ps1` (수정, 최소),
`wm4spacecraft_manufacturing/oracle/run_step_d_firegrid.sh` (신규)

- ps1 에 **레인 필터**를 옵트인으로 추가: `FG_LANES="fault,faultidle"` 이면 그 레인만 돈다.
  기본값은 현행 3레인 유지(하위호환). `battB` 는 `battgrid_0805_s1.jsonl` 이 이미 덮으므로 야간에는
  건너뛴다(계획서 §II STEP 1).
- 신규 `.sh` 는 야간 실행용 얇은 래퍼: 레인 필터를 걸고, 로그를 `_night/logs/` 로 남기고,
  끝에 `STATUS stepD_firegrid ok|fail rows=<n> lanes=<...>` 를 찍는다.
- **산출물 이름은 반드시 `oracle/out/firegrid_s<lane>.jsonl`** — `merge_firegrid.py` 의 glob 이
  `firegrid_s*.jsonl` 이라 규칙을 벗어나면 **에러 없이 병합에서 빠진다**(함정 ⑤).
- `DS_RESUME=1` 이므로 중단 후 재실행하면 이어서 돈다. 이 성질을 깨지 말 것.
- 그 다음 `python merge_firegrid.py` 로 `firegrid_merged.jsonl` 생성. dedup 키는
  `(instance, macro, rollout)`, **나중 파일이 이긴다**. CANONICAL 은 덮어쓰지 않는다.

**합격 조건**: `oracle/out/firegrid_s{fault,faultidle}.jsonl` 이 생기고,
`merge_firegrid.py` 후 `firegrid_merged.jsonl` 이 존재하며 fault instance 수가 **18 초과**
(= CANONICAL 18 + firegrid 신규분). 18 이면 firegrid 가 조용히 빠진 것이다.

---

## Task 4 — STEP D 파트 2: zcausal 4팔 순차 러너

**파일**: `wm4spacecraft_manufacturing/oracle/run_step_d_zcausal.sh` (신규)

게이트가 읽는 것은 **`blk_noop`, `blk_reloc`, `cov_noop`, `cov_reloc`** 넷뿐이다.

- `run_zcausal_all.sh` 를 **쓰지 말 것** — 34행이 팔을 2개씩 **병렬**로 띄운다(Global Constraint 1 위반).
- 순차 루프 + `[ -s "$OUT/$arm.json" ]` 스킵 가드. **이 가드를 빼지 말 것**:
  `ZC_OUT` 은 append 모드(`tools/restage.jl:1091`)라 같은 파일에 두 번 쓰면 JSON 객체가 이어붙어
  `json.load()` 가 깨진다. 깨졌으면 그 `.json` 만 지우고 그 팔만 다시 돈다.
- 모든 팔에 **같은 사다리** `ZC_REFORM=400 ZC_REFORM_MAX=3` 을 건다. 복구가 없으면 네 팔이 전부
  루트 엔드게임 교착에 갇혀 구역의 효과가 가려진다.
- 끝에 `STATUS stepD_zcausal ok|fail arms=<n>/4` 를 찍는다.

**합격 조건**: 네 `.json` 이 전부 존재하고 각각 `json.load()` 로 **파싱된다**(append 중복 없음).

---

## Task 5 — RENDER: 라우터 ON case별 렌더링

**파일**: `tools/monitor/regen_router_cases.sh` (신규)

사용자 요구의 하드 산출물. `tools/monitor/{streams,anim}/` 는 2026-08-09 정리로 지워졌고
**git-ignored 이므로 재생성이 정상 경로**다(복원이 아니라 현재 어휘로 새로 만든다).

- 실패 case 3종 `battery` / `fault` / `zone` 각각 1판씩, **`DEMO_ROUTER=auto`** 로 렌더한다.
- `render_demo.jl` 을 쓴다(`run_demo.jl` 은 애니메이션을 안 만든다). `DEMO_ANIM=1` 필요.
- 산출물 규칙(대시보드가 그 이름으로 찾는다):
  `tools/monitor/streams/tractor__<case>__<policy>.jsonl`,
  `tools/monitor/anim/tractor__<case>__<policy>.html`
  — `regen_case_policy_matrix.sh:66-91` 과 **같은 명명 규칙**을 따를 것.
- `NOVELTY_CALIB` 을 반드시 넘긴다(없으면 라우터가 fail-open 으로 꺼진 채 렌더된다).
- `publish_anim!` 은 **미완주 빌드의 애니메이션 발행을 거부**한다(`render_demo.jl:1037-1038`).
  거부당하면 그 case 를 실패로 기록하되 **다른 case 는 계속 진행**하고, 마지막에 어떤 case 가
  왜 빠졌는지 STATUS 줄에 남긴다. 조용히 넘어가지 말 것.
- **순차 실행** (Global Constraint 1).

**합격 조건**: 3 case 각각 `streams/*.jsonl` 이 non-empty 이고 `anim/*.html` 이 존재.
스트림 첫 줄이 `json.loads` 되고 `sim_t`/`n_closed`/`ood` 키를 갖는다.

---

## Task 6 — `verify_night.py`: 산출물 기계 검증

**파일**: `wm4spacecraft_manufacturing/verify_night.py` (신규)

검증 서브에이전트와 최종 판정이 함께 쓰는 **단일 판정기**. STEP 별로 합격 조건을 코드로 박는다.

- `--step E|RENDER|D|A|B|C|all`, 각 STEP 의 합격 조건을 위 Task 들의 "합격 조건" 그대로 검사.
- **zone 축 n=0 조용한 통과를 반드시 잡을 것**: `test_llm7h.py` 는 파일이 없으면 예외를 삼키고
  표본 0으로 통과한다(`test_llm7h.py:138-141`). `verify_night.py` 는 n 을 **직접 세서**
  battery n=18 / fault n>18 / zone n=2 를 확인하고, 하나라도 0이면 **FAIL** 로 판정한다.
- 라우터 ON 판정: 결정 레코드에 `router_target` non-null 이 1개 이상.
- 출력은 사람이 읽는 표 + 마지막 줄 `VERIFY <step> PASS|FAIL <n_checks>`. exit code 로도 구분.

**합격 조건**: 아직 안 만든 STEP 에 대해서는 `SKIP`(파일 없음)으로 찍고 FAIL 로 세지 않는다.
이미 있는 battery 축(`battgrid_0805_s1.jsonl`)에 대해서는 지금 당장 PASS 가 나와야 한다.

---

## Task 7 — 야간 오케스트레이터

**파일**: `wm4spacecraft_manufacturing/run_night.sh` (신규)

세션이 죽어도 밤새 이어 돌 수 있는 무인 실행기.

- 순서: `E → RENDER → D → A → B → C`. **전 구간 순차**, 동시에 도는 julia 는 언제나 하나.
- 각 STEP 시작/종료를 `_night/status.jsonl` 에 한 줄씩 append (`step`, `state`, `t`, `detail`).
  검증 에이전트가 이 파일을 읽는다.
- `--from <STEP>` 으로 중간부터 재개. 이미 산출물이 있는 STEP 은 건너뛴다.
- **데드라인 인자** `--deadline HH:MM`: 남은 시간이 다음 STEP 의 추정치보다 적으면 그 STEP 을
  **축소**한다. 축소 규칙은 사용자 결정에 따라 **STEP C 의 시드 수만** 줄인다(10→5→3).
  D 의 발화점 격자는 **줄이지 않는다**(사용자가 오라클 우선을 선택).
- 축소하거나 건너뛴 것이 있으면 **STATUS 와 최종 요약에 반드시 명시**한다. 조용한 절삭 금지.

**합격 조건**: `--dry-run` 이 각 STEP 의 명령줄과 추정시간을 찍고 아무것도 실행하지 않는다.

---

## 검증 서브에이전트의 임무 (매 STEP)

각 RUN 구간이 끝나면 별도 서브에이전트가 다음을 대조한다:

1. 이 문서의 해당 Task "합격 조건"을 **하나씩** 확인 (통과/실패/미확인).
2. `verify_night.py --step <X>` 의 출력.
3. **Global Constraints 위반 여부** — 특히 (a) 병렬 julia 가 돌지 않았는지,
   (b) 기존 아티팩트를 덮어쓰지 않았는지, (c) 조용한 실패(n=0, 라우터 fail-open)가 없는지.
4. 계획 대비 **이탈**이 있으면 무엇을·왜 이탈했는지.

검증자는 고치지 않는다. 발견만 보고한다.
