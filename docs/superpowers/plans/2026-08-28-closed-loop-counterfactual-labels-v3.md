# Plan V3 — 폐루프의 뒷절반: 반사실 라벨 생산자 · 재학습 · `train_macros` 도장

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 같은 OOD 사건이 **라벨 추가 + 재적재 전에는 `vocabulary_gap` 으로 dspy 로 가고, 후에는 surrogate 로 가는 것**을 end-to-end 로 보인다 (설계서 §7 R2). 그것이 "경계가 실제로 움직인다" 의 유일한 판정 기준이고, 그것 없이는 V1 이 지은 축 1 이 죽은 코드로 남는다.

**Architecture:** 반사실 라벨 생산자는 **맨땅에서 짓지 않는다** — `wm4spacecraft_manufacturing/dp_oracle/sample_grid.py`(1331줄, 자칭 "반사실 표집기")가 git HEAD 에 있고 작업 트리에서만 삭제돼 있다. V3 은 그것을 **되살려 모양을 바꾼다**: (1) 낡은 경로와 어휘 리터럴을 고쳐 판이 실제로 돌게 만들고(Task 1), (2) 반사실 지점을 crc32 해시가 아니라 **OOD 사건 index** 에서 몰고(Task 2), (3) 사건을 열거하고(Task 3), (4) 판을 라벨 행으로 접고(Task 4), (5) `train_macros` 도장을 **소비처와 같은 태스크에서** 넣고(Task 5), (6) 재적재 경로를 만들고(Task 6), (7) R2 를 측정하고(Task 7), (8) 그 라벨셋 위에서 축 2 의 실현가능성을 **다시 잰다**(Task 8 — 짓지는 않는다).

**Tech Stack:** Python 3.12 (`.venv/bin/python`) + pytest · Julia 1.10 (`julia +lts --project=.`) + `Test` · FastAPI/pydantic (`src/respec/llm_service/dspy_service.py`) · `subprocess` 로 굴리는 `tools/monitor/run_demo.jl` 판

**Spec:** `docs/superpowers/specs/2026-08-27-vocabulary-indexed-router-design.md` (§4 ④⑤ · §5 · §7 R2 · §8)

**딛는 실측 (이 계획의 모든 주장의 출처):**
- `docs/superpowers/reports/2026-08-28-v3-evidence.md` (개정 1 — 독립 검증 반영)
- `docs/superpowers/reports/2026-08-28-conformal-feasibility-measurement.md` (개정 1)
- `docs/superpowers/reports/2026-08-28-conformal-feasibility-validation.md` (독립 재유도)

**시작 커밋:** `36b92e0a` (작업 트리에 264건 미커밋 — 그중 **219건이 다른 작업의 삭제**)

## Global Constraints

- **Julia 는 `julia +lts` (1.10), 항상 `--project=.`.** `Manifest.toml` 이 1.10.11 에 고정돼 있고 상위 Julia 로 `Pkg.add` 하면 빌드가 조용히 깨진다.
- **Python 은 `.venv/bin/python`.** 🔴 **모든 pytest 호출에 `--ignore=src/respec/llm_service/test_propose.py` 를 붙인다** — 그 파일은 테스트가 아니라 import 시점에 `sys.exit(1)` 하는 스크립트이고, `ANTHROPIC_API_KEY` 가 설정돼 있으면 수집 중에 **유료 API 호출을 발화시킨다.** 막을 conftest 가 없다.
- 🔴 **`git add` 는 언제나 명시 경로만.** 작업 트리에 **219건의 미커밋 삭제가 있고 그것은 다른 작업의 것**이다. `git add -A` · `git add .` · `git commit -a` 는 이 계획서 전체에서 **금지**다. 각 태스크의 커밋 스텝에 적힌 경로만 넣는다.
- 🔴 **어휘 단일 진실원은 `wm4spacecraft_manufacturing/core/action_registry.json`** — 현행 `v4-3arms`, 매크로 `0 NOOP` / `1 Replace` / `2 SwapBattery`. **리터럴 복붙 금지.** ⚠️ `.claude/CLAUDE.md` 는 `v3-4arms` 라고 적는데 **JSON 이 맞고 CLAUDE.md 가 낡았다.**
- **새 Julia 테스트는 반드시 `test/runtests.jl` 에 배선한다.** 안 하면 고아 게이트다.
- 🔴 **"못 쟀다" 를 "재서 아니었다" 로 뭉개지 않는다.** `None`/`nothing` 과 `false`/`[]` 는 다른 사건이다. 이 레포는 그 둘을 섞어 여러 번 데었다.
- 🔴 **비교 런은 순차 실행이다** (CLAUDE.md 함정 30). 병렬이면 HiGHS 가 다른 스케줄을 내 **팔 비교 자체가 무효**가 되고 프로세스당 ~2.5GB 라 OOM 이다. 이 계획의 모든 판 실행은 **`--jobs 1`** 이다.
- 🔴 **라벨 레인은 `DS_HOTSWAP=1` 이어야 한다.** 실행 레인이 hot-swap ON 이고, 안 켜면 fault 대상 피커가 죽어 발화율이 100% → 23% 로 무너진다(실측). `sample_grid.run_board` 가 이미 그것을 넘긴다 — **지우지 말 것.**
- 🔴 **`zone` 은 test-only 다** (`.claude/CLAUDE.md` §OOD). 학습 라벨셋에 zone 을 넣으면 "낯선 사건을 알아보는가" 를 재려는 그 사건을 surrogate 가 이미 본 것이 된다. 이 계획의 모든 판 실행은 **`--cases battery,fault` 를 명시**한다.
- 🔴 **인용은 앵커 문자열로 한다.** `run_demo.jl` 의 결정 행 위치가 며칠 만에 `281→290`, `345→371` 로 밀렸다. 줄번호를 적을 때는 **"오늘 기준"** 이라고 같이 적는다.
- 실행: `.venv/bin/python -m pytest <path> -v --ignore=src/respec/llm_service/test_propose.py` · `julia +lts --project=. test/<name>.jl`
- `Pkg.test()` 기준선은 **11 pass / 1 error**(Gurobi 라이선스 없음). 그 1 error 는 회귀가 아니다.

---

## 1. 범위 선언 — V3 이 짓는 것과 안 짓는 것

| | 무엇 |
|---|---|
| **짓는다** | 설계서 §4 **④ 반사실 라벨 생산자** (Task 1~4) |
| **짓는다** | 설계서 §4 **⑤ 재학습**(라벨 → 적합 → 재적재) (Task 6) |
| **짓는다** | 설계서 §5 **`train_macros` 도장 + 그 소비처** (Task 5, 한 태스크) |
| **짓는다** | 설계서 §7 **R2 의 측정** (Task 7) |
| **안 짓는다** | **LLM → 새 매크로 id 경로** (설계서 §8). 매크로 주조는 6~7파일 수작업 + 라벨 전량 재생성이고, `vocab` 도장이 그때 등가성 벽을 세운다. V3 은 **어휘를 안 늘린다** — 경계는 `v4-3arms` **안에서** 움직인다(아래 §3) |
| **안 짓는다** | **축 2 (conformal)**. 2026-08-28 측정이 R3 FAIL · R4 "실패할 수 없는 검사" · 조건부 coverage 0.000 을 냈다. Task 8 은 새 라벨셋 위에서 **다시 재기만** 한다 |
| **안 짓는다** | 새 원시연산(L2). `_PRIMITIVE_TABLE` 에 없는 동작이면 파일 12개가 붙는다 |
| **안 짓는다** | `src/safety/novelty.jl` 삭제. 사용자 결정대로 새 라우터를 먼저 짓고 나중에 지운다(설계서 §6) |

### 🔴 `psi()` 호출 시점 방어는 **이미 있다 — 다시 짓지 않는다**

설계서 §2-3 은 `psi(99) == psi(0) → True` 를 지뢰로 적고 §8 이 *"주조 전에 반드시 필요하다"* 고 쓴다. **그 방어는 V1 Task 1 이 이미 넣었다.** 사실 시트 §"설계서와 어긋나는 것" 이 실측으로 확인했다:

```
psi(99) -> KeyError: 'psi: 매크로 id 99 가 action_registry 에 없다 ...'
```

근거: `wm4spacecraft_manufacturing/core/features_agnostic.py` 의 `if mid not in MACRO_SPECS:` 앵커(오늘 기준 `:464-467`)와 게이트 `wm4spacecraft_manufacturing/core/test_psi_unknown_macro.py`. **이 계획은 그 자리를 다시 건드리지 않는다.**

---

## 2. 🔴 측정 결과가 라벨셋에 요구하는 것 — 그리고 "행을 더 내면 된다" 가 왜 거짓인가

2026-08-28 의 축 2 측정(+독립 재유도)이 낸 판정을 **이 계획서 안에 명시한다.** 이것을 안 적으면 Task 4 가 "행 수" 를 목표로 삼게 되고, 그러면 아무것도 못 만든다.

### 2-1. R3 = FAIL. 손잡이가 없다 — 그리고 그것은 J 의 성질이다

- α ∈ (0,1) **전체**에서 격상률이 취하는 값은 `{1.000, 0.750, 0.667}` **셋뿐**이고, 측정 가능하고 공허하지 않은 것은 **0.750 하나**다(α 구간의 94.1%).
- 이유: gap 분포가 이봉이고 **빈 구간 `(30.963, 17304.157)`** 이 있는데, 유한한 2q 의 도달 범위 `[44.382, 15170.903]` 이 **그 빈 구간 안에 통째로 들어간다.**
- 🔴 **그 이봉성은 surrogate 의 성질이 아니라 `J` 자신의 성질이다.** 독립 재유도가 **진실 J** 의 gap 을 모델 없이 직접 재서 같은 빈 구간 `(109.5, 17778.6)` 을 얻었다. 원인은 `objective.json` 의 `C_fail = 10000` 완주 절벽이다.
- **귀결: `Ĵ` 가 더 정확해져도 축 2 는 안 산다.** 정확도의 병이 아니다.

### 2-2. R4 는 통과한 게 아니라 **아무것도 못 가리는 검사**였고, 잔차는 **반증됐다**

- 적대적 잔차 4000 배치에서 α=0.10 을 빼면 **FAIL 0건**. instance 별로 잔차를 8제곱으로 벌린 완전 비교환 배치에서도 `coverage ≈ 1−α`. 기전: LIO 의 calibration 이 evaluation 과 30~31/33 을 공유해 coverage 가 값과 무관하게 `k/n` 에 고정된다.
- 🔴 **조건부 coverage 는 `macro` 축과 `complete` 축에서 0.000 으로 무너진다** (α=0.2 에서 주변 0.818 PASS 인데 미완주 6행은 0.000, macro 0 은 0.500). 잔차는 **미반증이 아니라 반증됐고, 비교환적인 축이 하필 라우터가 조건 거는 그 축(팔)** 이다.
- 설계서 §7 R4 의 원문이 *"교환가능하지 않다는 뜻이고, 그 위의 escalation 은 근거가 없다 → 거기서 멈춘다"* 이므로 **설계서 자신의 정지 조건이 이미 걸려 있다.**

### 2-3. 그래서 라벨 생산자가 **내야 하는 것** — 행 수가 아니라 네 가지 형태

| # | 요구 | V3 의 어느 태스크가 다루나 | 정직한 한계 |
|---|---|---|---|
| 1 | **완주 봉우리 안에서 팔이 갈리는 사건**이 있어야 한다. 오늘 완주 팔이 2개 이상인 instance 는 battery 9개뿐이고 fault 3개는 완주 팔이 1개다 | Task 4 가 **사건별로 메뉴의 모든 팔**을 굴린다 → 완주 팔 수를 행에서 직접 셀 수 있다. Task 8 이 그 수를 기록한다 | 완주 팔이 늘어난다는 보장은 없다. **재봐야 아는 것**이고 Task 8 이 재는 것이 정확히 그것이다 |
| 2 | **잔차 중앙값 < gap 중앙값** (오늘 87.3 vs 2.782 = 31.4배 틀렸다) | Task 8 이 새 라벨셋에서 두 값을 다시 재고 비를 기록한다 | 🔴 **이것은 라벨 수를 늘려서 고치는 문제가 아닐 수 있다.** 이봉성이 J 의 성질이므로 봉우리 안 gap 은 구조적으로 작다 |
| 3 | **`kind` 가 팔 메뉴를 결정하지 않는 라벨셋** | 🔴 **V3 이 못 푼다.** 메뉴를 좁히는 것은 학습셋이 아니라 `action_registry.json` 의 `"2": {"kinds": ["battery"]}` 다 | 이것은 **레지스트리 변경**이고 V3 의 범위 밖이다. Task 8 이 교락(kind ≡ n_arms)이 새 라벨셋에서도 유지되는지만 기록한다 |
| 4 | **팔 부류별 calibration 표본** (Mondrian conformal, `psi(macro)` 서술자 구간 기준) | 🔴 **V3 이 안 짓는다.** 부류를 나누려면 라벨셋이 먼저 커져야 하고, R4 검사 자체도 **주변 coverage 가 아니라 조건부 coverage 의 최솟값**으로 재설계돼야 한다 | Task 8 이 조건부 coverage 최솟값을 **기록만** 한다 — 오늘 데이터에서 그 지표는 즉시 0.000 이다 |

🔴 **이 표의 정직한 요약: 축 2 는 "행을 더 내면" 살아나지 않는다.** 3번(레지스트리 `kinds`)과 4번(단일 q 규칙)이 라벨과 무관한 축에 있고, 2번은 `C_fail` 절벽 때문에 라벨로 못 고칠 가능성이 크다. **V3 이 약속하는 것은 축 2 의 부활이 아니라 축 2 의 실현가능성 질문을 다시 물을 수 있는 라벨셋**이고, Task 8 이 그 질문을 실제로 다시 묻는다. 이 문장을 약하게 고쳐 쓰지 말 것.

### 2-4. 🔴 **자유도는 행이 아니라 고유 시뮬레이션 수로 센다**

오늘의 33행은 지문 `(complete, closed, makespan, energy_J)` 로 세면 **18개의 고유 시뮬레이션**으로 접힌다 (macro=1 이 seed 당 4행 공유 · macro=2 가 seed 당 3행 공유 · macro=0 만 12행 전부 다름). 그래서:

> 🔴 **이 계획의 어떤 수락 기준도 "N 행을 만든다" 가 아니다.** 중복으로 채워진 N 행은 아무것도 만들지 않은 것이다. Task 4 의 게이트는 **사건당 서로 다른 결과 지문의 수**를 세고, 그 수가 0 인 런은 `exit 1` 이다.

### 2-5. 축 2 규칙의 절반은 한 번도 안 돌았다

설계서 §3 의 격상 조건 셋 중 `no_arms`(팔 0개)·`single_arm`(팔 1개)은 12 instance 전부 팔이 2~3개라 **한 번도 발화하지 않았다.** V3 은 축 2 를 안 지으므로 그 분기를 시험하지 않는다 — **미측정으로 남는다는 사실을 §9 의 미결 목록에 적는다.**

---

## 3. 🔴 `require_vocab*` 소비처 — 어휘가 자랄 때 무슨 일이 나고, V3 이 그것을 어떻게 다루나

사실 시트 §7 이 실측한 **생산 소비처는 정확히 3곳**이다(설계서 부록의 "6곳" 은 셈이 틀렸다 — 생산 3 + 테스트 4파일 = 7).

| # | 소비처 | 무엇을 검사 | 어휘가 자라면 | V3 의 처리 |
|---|---|---|---|---|
| 1 | `wm4spacecraft_manufacturing/smdp/gate_ng2.py:112` (오늘 기준) `AR.require_vocab(meta, ranks_path)` | 산출물 dict **하나** | 구세대 ranks 산출물이 거부된다 | **V3 은 어휘를 안 늘린다** → 영향 없음. V3 은 이 파일을 안 건드린다 |
| 2 | `wm4spacecraft_manufacturing/surrogate/eval_surrogate_v2.py:139` (배포 적재 경로) `require_vocab_stamps(df["vocab"], path)` | 라벨 파일의 **행별 도장 집합**, 정확한 문자열 동등 | 기존 라벨 전부가 배포 적재에서 거부된다 | Task 4 의 생산자가 **`action_registry.VOCAB` 을 그대로 찍는다**(리터럴 금지) → 통과. Task 5 가 같은 파일에 `train_macros` 검사를 **추가**한다 |
| 3 | `wm4spacecraft_manufacturing/surrogate/export_surrogate.py:143` (오늘 기준) `_load_labels` 안 | 같음 | 같음 | 같음. Task 5 가 export meta 에 `train_macros` 를 싣는다(설계서 §4 의 *"지원집합이 디스크에 없다"* 를 닫는다) |
| T1~T4 | `smdp/test_stamps.py` · `test/smdp_stamp_smoke.jl` · `surrogate/test_export_surrogate_vocab.py` · `surrogate/test_load_rows_vocab.py` | 테스트 | — | Task 5 가 T3·T4 의 픽스처에 `train_macros` 를 더하고, T2(Julia)에 새 도장의 음성 대조를 더한다 |

### 🔴 그리고 Julia 라벨 레인에는 행 집합 도장 검사가 **아예 없다**

```
$ grep -rn 'require_vocab_stamps' --include='*.jl' . | grep -v '\.venv'
(출력 없음)
```

`action_registry.jl` 에는 `require_vocab`(산출물 dict 하나)만 있다. **도장을 찍는 레인(Julia)이 자기 도장을 검사할 함수를 안 가지고 있다.** Task 5 는 그 비대칭을 물려받지 않기 위해 **Julia 판 `require_train_macros_stamps` 를 같이 만든다.**

### V3 이 `vocab` 등가성 벽을 **안 무너뜨리는** 이유 — 그리고 그래도 경계가 움직이는 이유

설계서 §5 의 표는 `vocab` 을 "동역학·목적함수 세대" 로, `train_macros` 를 "이 파일이 어떤 매크로를 가르치는가" 로 가른다. 그런데 🔴 **오늘의 `vocab` 문자열은 팔 수를 인코딩한다**(`v4-3arms`, 정규식 `^v\d+-(\d+)arms$` 를 `assert_vocab_arm_count` 가 import 시점에 강제한다). 즉 매크로를 하나 주조하면 `vocab` 이 **반드시** 올라가고 기존 라벨 전부가 무효가 된다 — `train_macros` 를 더해도 그 벽은 그대로다.

**V3 은 그 벽을 안 건드린다. 건드릴 필요가 없기 때문이다:**

> R2 는 *"같은 사건이 라벨 추가 전에는 `vocabulary_gap` 으로, 후에는 surrogate 로 가는가"* 이지 *"새 매크로를 주조하는가"* 가 아니다. **지원집합은 어휘의 부분집합**이고, 오늘 지원집합 = 어휘 전체 `{0,1,2}` 인 것은 라벨셋이 세 팔을 다 가르치기 때문이다. 지원집합을 `{0,1}` 로 줄인 라벨셋을 만들고 → 반사실 라벨로 macro 2 를 **추가**하면 → 지원집합이 `{0,1} → {0,1,2}` 로 자란다. **어휘는 `v4-3arms` 그대로다.**

즉 V3 은 **어휘 안에서 경계를 움직인다.** 어휘 자체를 늘리는 길(설계서 §8, `vocab` 벽)은 V3 다음이다.

---

## File Structure

| 파일 | 책임 | 상태 |
|---|---|---|
| `wm4spacecraft_manufacturing/dp_oracle/sample_grid.py` | 반사실 판 러너. 경로 고침 · 어휘 리터럴 제거 · `at` 인자 | **복원 + 수정** |
| `wm4spacecraft_manufacturing/dp_oracle/derive_grid.py` | `sample_grid` 가 모듈 최상위에서 import 한다 | **복원(무수정)** |
| `wm4spacecraft_manufacturing/dp_oracle/grid_spec.json` | `derive_grid.load_grid()` 의 기본 인자 | **복원(무수정)** |
| `wm4spacecraft_manufacturing/dp_oracle/test_sample_grid_wiring.py` | 경로·어휘·`at` 계약 | **신규** |
| `tools/monitor/run_demo.jl` | 결정 행에 `n_active` 를 싣는다 | 수정 |
| `wm4spacecraft_manufacturing/oracle/counterfactual_labels.py` | 사건 열거 · 판 → 라벨 행 접기 · CLI | **신규** |
| `wm4spacecraft_manufacturing/oracle/test_counterfactual_labels.py` | 접기 계약 · 스키마 무조건 강제 · 고유 시뮬 수 | **신규** |
| `wm4spacecraft_manufacturing/core/action_registry.py` | `train_macros_stamp` · `require_train_macros_stamps` | 수정 |
| `wm4spacecraft_manufacturing/oracle/action_registry.jl` | 같은 둘의 Julia 판 (🔴 오늘 없다) | 수정 |
| `wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl` | `train_macros` 도장 write site 4곳 | 수정 |
| `wm4spacecraft_manufacturing/surrogate/eval_surrogate_v2.py` | `load_rows` 가 도장을 검사하고 `meta` 에 싣는다 (**소비처 1**) | 수정 |
| `src/respec/llm_service/dspy_service.py` | 지원집합을 도장에서 받는다 (**소비처 2**) · `SURRO_DATA` env · `POST /reload` | 수정 |
| `wm4spacecraft_manufacturing/surrogate/export_surrogate.py` | 도장 검사 + export meta 에 기록 (**소비처 3**) | 수정 |
| `wm4spacecraft_manufacturing/core/test_train_macros_stamp.py` | 도장 계약 (Python) | **신규** |
| `test/train_macros_stamp_smoke.jl` | 도장 계약 (Julia) + `runtests.jl` 배선 | **신규** |
| `test/runtests.jl` | 위 파일 배선 | 수정 |
| `wm4spacecraft_manufacturing/surrogate/test_load_rows_vocab.py` | 픽스처에 `train_macros` 추가 | 수정 |
| `wm4spacecraft_manufacturing/surrogate/test_export_surrogate_vocab.py` | 같음 | 수정 |
| `wm4spacecraft_manufacturing/oracle/out/oracle_dataset.jsonl` | 기존 33행에 `train_macros` 백필(시뮬 없음) | 수정 |
| `src/respec/llm_service/test_reload_grows_support.py` | ⑤ 재적재 계약 | **신규** |
| `src/respec/llm_service/test_r2_boundary_moves.py` | 🔴 **R2 — V3 의 완료 판정** | **신규** |
| `wm4spacecraft_manufacturing/surrogate/out/conformal_feasibility_v3.json` | Task 8 재측정 산출물 | **신규(산출물)** |
| `docs/superpowers/reports/2026-08-28-v3-axis2-remeasure.md` | Task 8 재측정 보고 | **신규** |

---

### Task 1: 반사실 하니스를 되살리고 — **판이 실제로 돌았음을 증명한다**

**왜:** 설계서 §4 는 *"반사실 라벨 생산자가 없다"* 고 적지만 **틀렸다.** `wm4spacecraft_manufacturing/dp_oracle/sample_grid.py` 는 git 에 **추적되고 있고**(1331줄) 작업 트리에서만 삭제된 상태다. 첫 줄이 스스로를 **"반사실 표집기"** 라고 부르고, `run_board()` 가 `DS_DEVIATE_AT`/`DS_DEVIATE_ARM`/`DS_HOTSWAP=1` 로 정확히 V3 이 필요한 일을 한다.

🔴 **그런데 그대로 복원하면 모든 판이 조용히 죽는다.** `run_board` 안의 `cmd = [PY, os.path.join(WM, "llm_ood_eval.py"), ...]` 앵커(오늘 기준 `:381`)가 가리키는 파일은 **2026-08-18 폴더 분류에서 `sweep/` 으로 옮겨졌다**:

```
$ find . -name 'llm_ood_eval.py' -not -path './.venv/*'
./wm4spacecraft_manufacturing/sweep/llm_ood_eval.py
```

`WM/llm_ood_eval.py` 가 없으면 `subprocess.call` 이 rc≠0 을 내고 `run_board` 가 **예외가 아니라 `(None, k)` 를 반환한다** — 오류는 `board.log` 에만 남고 하니스는 계속 돈다. **판 손실률 100%, 에러 0건.** 이 레포가 반복해 데인 그 실패 양식이다.

🔴 **그리고 어휘 리터럴이 하나 더 있다.** `ENACTABLE_NAMES = {"NOOP", "Replace", "Deprioritize", "ForbidZone", "ReformTeam", "RelocateBuild", "SwapBattery"}` 앵커(오늘 기준 `:249-250`)의 일곱 이름 중 **넷이 현행 레지스트리에서 은퇴한 팔**이고, `arm_menu()` 가 이 집합으로 **교집합**을 잡으므로 **새로 주조된 매크로는 에러 없이 메뉴에서 탈락한다.** 설계서 §8 의 "매크로 하나 추가 = 6파일" 목록에 **빠진 7번째 파일**이고, 어휘 성장을 직접 막는 자리다.

⚠️ **복원하지 *않는* 파일 하나를 명시한다.** 사실 시트 §3-2(가)는 최소 4파일(+`boards.jsonl`)을 든다. `boards.jsonl` 은 **이전 세대 판 실행의 산출 매니페스트**이고 `wm4spacecraft_manufacturing/smdp/boards.py` 의 기본 경로일 뿐이다. **V3 의 라벨 경로는 그것을 한 줄도 안 읽는다**(Task 3·4 는 `run_board` 가 돌려주는 `rows.jsonl` 경로를 직접 쓴다). 낡은 산출물을 되살려 두면 다음 사람이 그것을 현행으로 읽는다. 되살릴 필요가 생기면 명령은 하나다: `git checkout HEAD -- wm4spacecraft_manufacturing/dp_oracle/boards.jsonl`.

**Files:**
- Restore: `wm4spacecraft_manufacturing/dp_oracle/sample_grid.py` · `wm4spacecraft_manufacturing/dp_oracle/derive_grid.py` · `wm4spacecraft_manufacturing/dp_oracle/grid_spec.json`
- Modify: `wm4spacecraft_manufacturing/dp_oracle/sample_grid.py` (`ENACTABLE_NAMES` · `arm_menu` · `_default_id_by_name` · `run_board` 의 `cmd`)
- Create: `wm4spacecraft_manufacturing/dp_oracle/test_sample_grid_wiring.py`

**Interfaces:**
- Produces: `sample_grid.enactable_names() -> set[str]` (레지스트리 파생) · `sample_grid.arm_menu() -> list[tuple[int, str]]` · `sample_grid.run_board(case, seed, arm_id, arm_name, outroot, world_seed=1, n_hint=DEFAULT_N_HINT) -> tuple[str | None, int]`. Task 2 가 `run_board` 를 고치고 Task 3·4 가 둘 다 쓴다.
- Consumes: 없음 (첫 태스크)

- [ ] **Step 1: 세 파일을 복원한다 (명시 경로만)**

```bash
cd /home/chahj578/Construction_OODlayer
git checkout HEAD -- wm4spacecraft_manufacturing/dp_oracle/sample_grid.py \
                     wm4spacecraft_manufacturing/dp_oracle/derive_grid.py \
                     wm4spacecraft_manufacturing/dp_oracle/grid_spec.json
git status --porcelain -- wm4spacecraft_manufacturing/dp_oracle/
```
Expected: 세 경로가 `A ` 또는 공백(= 인덱스·작업 트리 모두 HEAD 와 같음)으로 나오고, **다른 경로는 하나도 안 나온다.**

🔴 `git checkout HEAD -- <경로>` 는 그 **명시 경로만** 되돌린다. 다른 219건의 삭제는 건드리지 않는다. `git checkout HEAD .` 처럼 경로를 넓히지 말 것.

- [ ] **Step 2: 실패하는 테스트를 쓴다**

`wm4spacecraft_manufacturing/dp_oracle/test_sample_grid_wiring.py`:

```python
"""반사실 하니스의 배선 계약 — **조용히 실패하는 두 자리**를 못박는다.

🔴 (가) subprocess 목표 경로. `run_board` 는 rc != 0 에서 **예외가 아니라 (None, k) 를
반환한다**. 그래서 목표 파일 경로가 낡으면 판 손실률 100% 인데 에러가 0건이고, 오류는
board.log 에만 남는다. 2026-08-18 폴더 분류로 llm_ood_eval.py 는 `sweep/` 으로 갔다.

🔴 (나) 어휘 리터럴. `ENACTABLE_NAMES` 는 은퇴한 이름 넷을 든 하드코딩 사본이었고,
`arm_menu()` 가 그것으로 교집합을 잡으므로 **새로 주조된 매크로가 에러 없이 메뉴에서
탈락한다.** 어휘 단일 진실원은 action_registry.json 이다(CLAUDE.md: 리터럴 복붙 금지).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
WM = os.path.dirname(HERE)
for _d in (HERE, os.path.join(WM, "core")):
    if _d not in sys.path:
        sys.path.insert(0, _d)

import action_registry as reg  # noqa: E402
import sample_grid  # noqa: E402


def test_the_board_runner_points_at_a_file_that_exists():
    """🔴 이 단언이 이 파일의 존재 이유다. 틀리면 모든 판이 rc!=0 으로 조용히 죽는다."""
    target = os.path.join(sample_grid.WM, "sweep", "llm_ood_eval.py")
    assert os.path.exists(target), target


def test_the_runner_does_not_reference_the_old_pre_2026_08_18_path():
    """폴더 분류 전 경로(`WM/llm_ood_eval.py`)는 존재하지 않는다 — 음성 대조."""
    assert not os.path.exists(os.path.join(sample_grid.WM, "llm_ood_eval.py"))


def test_enactable_names_is_derived_from_the_registry():
    """리터럴 사본이 아니라 레지스트리에서 나와야 한다."""
    assert sample_grid.enactable_names() == {reg.MACRO_NAME[i] for i in reg.ACTIVE_MACROS}


def test_no_retired_name_survives_in_the_menu():
    """은퇴한 넷이 메뉴에 다시 나타나면 안 된다."""
    names = {n for _, n in sample_grid.arm_menu()}
    for retired in ("Deprioritize", "ForbidZone", "ReformTeam", "RelocateBuild"):
        assert retired not in names


def test_the_menu_carries_every_active_macro():
    """🔴 성장 방향의 단언: 활성 매크로가 하나라도 메뉴에서 빠지면 그 팔은 절대 표집되지 않는다."""
    assert {i for i, _ in sample_grid.arm_menu()} == set(reg.ACTIVE_MACROS)


def test_id_by_name_default_agrees_with_the_menu():
    """`rows_to_samples` 의 기본 사전과 `arm_menu()` 가 갈리면 라벨이 조용히 갈린다."""
    assert sample_grid._default_id_by_name() == {n: i for i, n in sample_grid.arm_menu()}
```

- [ ] **Step 3: 실패를 확인한다**

Run: `.venv/bin/python -m pytest wm4spacecraft_manufacturing/dp_oracle/test_sample_grid_wiring.py -v --ignore=src/respec/llm_service/test_propose.py`
Expected: FAIL — `test_enactable_names_is_derived_from_the_registry` 에서 `AttributeError: module 'sample_grid' has no attribute 'enactable_names'`, `test_the_menu_carries_every_active_macro` 는 통과(오늘의 3팔이 전부 리터럴 안에 있다 — 그래서 **이 단언 하나로는 결함을 못 잡는다**. 위 `enactable_names` 단언이 잡는다).

- [ ] **Step 4: 어휘 리터럴을 레지스트리 파생으로 바꾼다**

`wm4spacecraft_manufacturing/dp_oracle/sample_grid.py` — `ENACTABLE_NAMES = {"NOOP", "Replace", ...}` 앵커의 **두 줄을** 아래로 **교체**한다:

```python
def enactable_names():
    """실행 레인이 집행할 수 있는 매크로 이름들. **레지스트리에서 유도한다.**

    🔴 여기 있던 것은 하드코딩 집합이었다 (2026-08-28 수정):
        {"NOOP", "Replace", "Deprioritize", "ForbidZone",
         "ReformTeam", "RelocateBuild", "SwapBattery"}
    일곱 중 **넷이 현행 레지스트리(v4-3arms)에서 은퇴한 팔**이고, 더 나쁜 것은 반대
    방향이다 — `arm_menu()` 가 이 집합으로 **교집합**을 잡으므로 새로 주조된 매크로가
    **에러 없이 메뉴에서 탈락한다.** 이 하니스가 V3 의 라벨 생산자가 되는 순간
    그것은 어휘 성장을 직접 막는 자리가 된다.

    ⚠️ 이 함수가 "실행 레인이 집행할 수 있는가" 를 스스로 다시 판정하지 않는다.
    그 계약은 이미 Julia 쪽 게이트가 지킨다: `test/policy_macro_binding.jl` 의 (A)
    "enactable_macros() 는 action_registry.json 에서 유도된다" 와 (B) "메뉴의 모든
    이름이 실제로 집행된다(빈 제안으로 안 떨어진다)". 즉 **레지스트리 = 실행 레인의
    메뉴**가 이미 기계로 못박혀 있으므로, 여기서 레지스트리를 그대로 쓰는 것이 옳다.
    (구세대에는 실행 레인에 구현이 없는 조합 팔 5·6 이 레지스트리에 있어서 이 리터럴이
    필요했다. 그 팔들은 2026-08-20/08-24 축소에서 레지스트리에서 사라졌다.)
    """
    import action_registry as reg
    return {reg.MACRO_NAME[i] for i in reg.ACTIVE_MACROS}
```

같은 파일에서 `def arm_menu():` 본문의 두 줄

```python
    menu = [(i, n) for i, n in active if n in ENACTABLE_NAMES]
    dropped = [(i, n) for i, n in active if n not in ENACTABLE_NAMES]
```

를 이렇게 바꾼다:

```python
    _enactable = enactable_names()
    menu = [(i, n) for i, n in active if n in _enactable]
    dropped = [(i, n) for i, n in active if n not in _enactable]
```

그리고 `def _default_id_by_name():` 의 `return` 한 줄

```python
    return {reg.MACRO_NAME[i]: i for i in reg.ACTIVE_MACROS if reg.MACRO_NAME[i] in ENACTABLE_NAMES}
```

를 이렇게 바꾼다:

```python
    _enactable = enactable_names()
    return {reg.MACRO_NAME[i]: i for i in reg.ACTIVE_MACROS if reg.MACRO_NAME[i] in _enactable}
```

- [ ] **Step 5: 낡은 subprocess 경로를 고친다**

같은 파일에서 `cmd = [PY, os.path.join(WM, "llm_ood_eval.py"), "run",` 앵커의 그 한 줄을 아래로 **교체**한다:

```python
    # 🔴 `os.path.join(WM, "llm_ood_eval.py")` 였다 (2026-08-28 수정). 그 파일은 2026-08-18
    #    폴더 분류에서 `sweep/` 으로 옮겨졌고, 없는 경로를 주면 subprocess.call 이 rc!=0 을
    #    내는데 아래 `return None, k` 는 **예외가 아니라 반환값**이라 하니스가 계속 돈다.
    #    귀결: 판 손실률 100%, 에러 0건, 오류는 board.log 에만. 이 레포가 반복해 데인 모양이다.
    #    (`tools/regen_d20.sh:50` 은 이미 새 경로를 쓴다 — 이 파일만 뒤처져 있었다.)
    cmd = [PY, os.path.join(WM, "sweep", "llm_ood_eval.py"), "run",
```

- [ ] **Step 6: 테스트가 통과하는지 확인한다**

Run: `.venv/bin/python -m pytest wm4spacecraft_manufacturing/dp_oracle/test_sample_grid_wiring.py -v --ignore=src/respec/llm_service/test_propose.py`
Expected: PASS — 6 passed

- [ ] **Step 7: 🔴 판이 **실제로 돌았음**을 증명한다 (이 태스크의 존재 이유)**

🔴 **초록 유닛테스트는 판이 돈다는 증거가 아니다.** 위 단언들은 전부 파일 존재와 집합 동등일 뿐이다. 실제 판 하나를 굴려서 rc·산출물·결정 수를 **눈으로 본다.**

⚠️ **DSPy 서비스는 필요 없다.** `run_board` 는 `--policies canonical --router 0` 로 굴리고 `DEMO_ALL_POLICIES=0` 을 넘긴다. `policy.jl` 의 `j = (POLICY in ("canonical","noop","oracle") && !router_drives() && get(ENV,"DEMO_ALL_POLICIES","1") == "0") ? nothing : service_decide(...)` 앵커가 그 조합에서 서비스 호출을 통째로 건너뛴다.

```bash
cd /home/chahj578/Construction_OODlayer
.venv/bin/python - <<'PY'
import os, sys, json
HERE = os.path.abspath("wm4spacecraft_manufacturing/dp_oracle")
sys.path.insert(0, HERE); sys.path.insert(0, os.path.abspath("wm4spacecraft_manufacturing/core"))
import sample_grid
work = os.path.abspath("wm4spacecraft_manufacturing/dp_oracle/_v3_smoke")
p, k = sample_grid.run_board("battery", 1, 0, "NOOP", work, world_seed=1)
print("rows =", p, " k =", k)
assert p is not None, "🔴 판이 죽었다 — board.log 를 볼 것: %s" % os.path.join(work, "battery_s1_a0", "board.log")
row = json.loads(open(p).readline())
print("complete =", row["complete"], " closed =", row["closed"], "/", row["total"],
      " n_decisions =", row["n_decisions"], " vocab =", row["vocab"])
print("decision_index 들 =", [d.get("decision_index") for d in row["decisions"]])
print("deviate_at 들     =", [d.get("deviate_at") for d in row["decisions"]])
PY
```
Expected: `rows` 가 `None` 이 **아니고**, `n_decisions >= 1`, `vocab == "v4-3arms"`, `decision_index` 가 `1, 2, ...` 로 나온다.

🔴 **`rows = None` 이 나오면 여기서 멈춘다.** `_v3_smoke/battery_s1_a0/board.log` 를 열어 실제 오류를 보고서에 그대로 붙인다. "나중에 고친다" 로 넘어가면 Task 3·4 가 전부 빈 산출물 위에 서게 된다.

- [ ] **Step 8: 스모크 작업 디렉토리를 지운다**

```bash
rm -rf /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/dp_oracle/_v3_smoke
```

- [ ] **Step 9: 커밋 (명시 경로만)**

```bash
git add wm4spacecraft_manufacturing/dp_oracle/sample_grid.py \
        wm4spacecraft_manufacturing/dp_oracle/derive_grid.py \
        wm4spacecraft_manufacturing/dp_oracle/grid_spec.json \
        wm4spacecraft_manufacturing/dp_oracle/test_sample_grid_wiring.py
git commit -m "fix(counterfactual): 반사실 하니스를 되살리고 조용히 죽던 두 자리를 고친다

sample_grid.py 는 삭제된 게 아니라 작업 트리에서만 빠져 있었다(git HEAD 에 1331줄).
그대로 복원하면 llm_ood_eval.py 가 sweep/ 으로 옮겨진 탓에 모든 판이 rc!=0 -> (None,k) 로
조용히 죽는다(판 손실률 100%, 에러 0건). ENACTABLE_NAMES 는 은퇴한 이름 넷을 든 어휘
리터럴이라 새 매크로가 메뉴에서 에러 없이 탈락한다 — 레지스트리 파생으로 바꾼다."
```

---

### Task 2: `run_board` 가 반사실 지점을 **OOD 사건 index** 에서 받는다

**왜 (이 계획서에서 가장 하중 큰 설계 변경):** `pick_k` 는 반사실 지점을 **(case, seed) 의 crc32 해시**로 고른다:

```python
def pick_k(case, seed, arm_id, n_hint):
    del arm_id
    h = zlib.crc32(("%s|%d" % (case, int(seed))).encode())
    return 1 + (h % max(1, int(n_hint)))          # n_hint 기본 8
```

**DP 표집에는 그것이 옳다** — 목적이 깊이를 흩뿌려 칸을 덮는 것이고, 그 파일의 주석이 그렇게 적는다. 🔴 **surrogate 라벨에는 틀리다.** 라벨 행의 그룹키(`instance`)는 **OOD 사건**이어야 하고, 그 사건에서 각 팔이 무엇을 냈는지가 있어야 `SurrogateV2.fit` 이 팔을 비교할 수 있다. 유사난수로 고른 결정 하나는 "어느 사건인가" 와 아무 상관이 없다. **설계서도 사실 시트 초판도 이것을 빠뜨렸다** — 열을 더 낸다고 안 풀리는 유일한 항목이다.

⚠️ **판 디렉토리 이름이 같이 바뀌어야 한다.** 오늘 `outdir = "%s_s%d_a%d" % (case, seed, arm_id)` 인데, 사건마다 다른 `k` 로 같은 `(case, seed, arm_id)` 를 여러 번 굴리면 **두 번째 판이 첫 번째 판의 `rows.jsonl` 을 재개 캐시로 읽어 그대로 돌려준다**(`if os.path.exists(rows) and os.path.getsize(rows) > 0: return rows, k`). 사건 A 의 결과가 사건 B 의 라벨로 조용히 들어간다. 그래서 `at` 을 준 경로에만 `_k<at>` 접미사를 붙인다 — **구세대 DP 경로의 board_id 규약(`<case>_s<seed>_a<arm_id>`, `smdp/boards.py` 머리말이 계약으로 적는다)은 그대로 둔다.**

**Files:**
- Modify: `wm4spacecraft_manufacturing/dp_oracle/sample_grid.py` (`def run_board(` 앵커)
- Modify: `wm4spacecraft_manufacturing/dp_oracle/test_sample_grid_wiring.py`

**Interfaces:**
- Consumes: `sample_grid.run_board(...)` (Task 1)
- Produces: `sample_grid.run_board(case, seed, arm_id, arm_name, outroot, world_seed=1, n_hint=DEFAULT_N_HINT, at=None) -> tuple[str | None, int]`
  - `at is None` → 구세대 DP 경로. `pick_k(case, seed, arm_id, n_hint)`. 디렉토리 `"<case>_s<seed>_a<arm_id>"`.
  - `at == 0` → **프로브 판**. `DS_DEVIATE_AT`/`DS_DEVIATE_ARM` 을 **아예 안 넘긴다**(`arm_id`·`arm_name` 은 무시). 디렉토리 `"<case>_s<seed>_probe"`. 반환 `k` 는 `0`.
  - `at >= 1` → V3 경로. 그 결정 index 에서만 갈아 끼운다. 디렉토리 `"<case>_s<seed>_a<arm_id>_k<at>"`.
  - Task 3 이 `at=0` 을, Task 4 가 `at>=1` 을 쓴다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`wm4spacecraft_manufacturing/dp_oracle/test_sample_grid_wiring.py` 의 마지막 줄 뒤에 추가:

```python
def test_run_board_accepts_an_explicit_deviation_index(monkeypatch, tmp_path):
    """🔴 V3 의 핵심: 반사실 지점이 crc32 가 아니라 **사건 index** 에서 온다.

    `pick_k` 는 (case, seed) 의 crc32 해시로 k 를 고른다 — DP 표집에는 옳고 surrogate
    라벨에는 틀리다. 라벨 행의 그룹키는 OOD 사건이어야 하기 때문이다.
    """
    seen = {}

    def fake_call(cmd, stdout=None, stderr=None, cwd=None, env=None):
        seen["env"] = dict(env)
        seen["cmd"] = list(cmd)
        # rows.jsonl 을 만들어 줘야 run_board 가 (경로, k) 를 돌려준다.
        out = cmd[cmd.index("--out") + 1]
        with open(out, "w") as fh:
            fh.write('{"complete": true}\n')
        return 0

    monkeypatch.setattr(sample_grid.subprocess, "call", fake_call)

    p, k = sample_grid.run_board("battery", 1, 2, "SwapBattery", str(tmp_path), at=3)
    assert k == 3
    assert seen["env"]["DS_DEVIATE_AT"] == "3"
    assert seen["env"]["DS_DEVIATE_ARM"] == "SwapBattery"
    assert seen["env"]["DS_HOTSWAP"] == "1"          # 라벨 레인은 실행 레인과 같은 세계여야 한다
    assert p == str(tmp_path / "battery_s1_a2_k3" / "rows.jsonl")


def test_two_events_do_not_share_a_resume_cache(monkeypatch, tmp_path):
    """🔴 사건마다 다른 k 인데 디렉토리가 같으면 **사건 A 의 결과가 사건 B 의 라벨이 된다.**

    `run_board` 는 rows.jsonl 이 이미 있으면 다시 안 굴리고 그대로 돌려준다(재개 캐시).
    """
    def fake_call(cmd, stdout=None, stderr=None, cwd=None, env=None):
        out = cmd[cmd.index("--out") + 1]
        with open(out, "w") as fh:
            fh.write('{"k": %s}\n' % env["DS_DEVIATE_AT"])
        return 0

    monkeypatch.setattr(sample_grid.subprocess, "call", fake_call)
    p3, _ = sample_grid.run_board("battery", 1, 2, "SwapBattery", str(tmp_path), at=3)
    p5, _ = sample_grid.run_board("battery", 1, 2, "SwapBattery", str(tmp_path), at=5)
    assert p3 != p5
    assert open(p3).read().strip() == '{"k": 3}'
    assert open(p5).read().strip() == '{"k": 5}'


def test_at_zero_is_a_probe_board_with_no_deviation(monkeypatch, tmp_path):
    """프로브 판은 갈아 끼우지 않는다 — 그 판이 사건 목록의 진실원이다.

    🔴 `DS_DEVIATE_AT=0` 을 넘기면 policy.jl 이 `error()` 한다("정수로 파싱되지 않거나
    0 이하"). 그래서 **키를 아예 안 넣는 것**이지 0 을 넣는 것이 아니다.
    """
    def fake_call(cmd, stdout=None, stderr=None, cwd=None, env=None):
        assert "DS_DEVIATE_AT" not in env
        assert "DS_DEVIATE_ARM" not in env
        out = cmd[cmd.index("--out") + 1]
        with open(out, "w") as fh:
            fh.write('{"complete": true}\n')
        return 0

    monkeypatch.setattr(sample_grid.subprocess, "call", fake_call)
    p, k = sample_grid.run_board("battery", 1, 0, "NOOP", str(tmp_path), at=0)
    assert k == 0
    assert p == str(tmp_path / "battery_s1_probe" / "rows.jsonl")


def test_at_none_keeps_the_legacy_dp_path(monkeypatch, tmp_path):
    """🔴 회귀 방지: 구세대 DP 경로(board_id 규약 `<case>_s<seed>_a<arm_id>`)는 안 바뀐다.

    `smdp/boards.py` 머리말이 그 규약을 계약으로 적는다.
    """
    def fake_call(cmd, stdout=None, stderr=None, cwd=None, env=None):
        out = cmd[cmd.index("--out") + 1]
        with open(out, "w") as fh:
            fh.write('{"complete": true}\n')
        return 0

    monkeypatch.setattr(sample_grid.subprocess, "call", fake_call)
    p, k = sample_grid.run_board("battery", 1, 2, "SwapBattery", str(tmp_path))
    assert k == sample_grid.pick_k("battery", 1, 2, sample_grid.DEFAULT_N_HINT)
    assert p == str(tmp_path / "battery_s1_a2" / "rows.jsonl")
```

- [ ] **Step 2: 실패를 확인한다**

Run: `.venv/bin/python -m pytest wm4spacecraft_manufacturing/dp_oracle/test_sample_grid_wiring.py -v --ignore=src/respec/llm_service/test_propose.py`
Expected: FAIL — `test_run_board_accepts_an_explicit_deviation_index` 에서 `TypeError: run_board() got an unexpected keyword argument 'at'`

- [ ] **Step 3: `run_board` 를 고친다**

`wm4spacecraft_manufacturing/dp_oracle/sample_grid.py` — `def run_board(` 부터 `env = dict(os.environ)` 바로 앞줄까지를 아래로 **교체**한다:

```python
def run_board(case, seed, arm_id, arm_name, outroot, world_seed=1, n_hint=DEFAULT_N_HINT,
              at=None):
    """판 하나를 굴린다. 반환: (rows 경로 또는 None, k).

    `at` (2026-08-28, V3):
      · `None`  — **구세대 DP 표집 경로.** `pick_k(case, seed, arm_id, n_hint)` 로 지점을
                  고른다. 판 디렉토리는 `"<case>_s<seed>_a<arm_id>"` 그대로다
                  (`smdp/boards.py` 머리말이 그 board_id 규약을 계약으로 적는다).
      · `0`     — **프로브 판.** `DS_DEVIATE_AT`/`DS_DEVIATE_ARM` 을 **아예 안 넘긴다**
                  (`arm_id`·`arm_name` 은 안 쓴다). 이 판의 결정 목록이 "이 (case, seed) 에
                  어떤 OOD 사건이 몇 번째로 났는가" 의 진실원이다.
                  🔴 `DS_DEVIATE_AT=0` 을 **넘기면 안 된다** — `policy.jl` 의 파싱 게이트가
                  "정수로 파싱되지 않거나 0 이하" 로 `error()` 한다. 끄는 방법은 키 부재뿐이다.
      · `>= 1`  — **V3 라벨 경로.** 그 **OOD 사건 index** 에서만 팔을 갈아 끼운다.

    🔴 왜 `at` 이 필요한가 (V3 의 가장 하중 큰 변경): `pick_k` 는 `(case, seed)` 의 crc32
    해시로 지점을 고른다. DP 표집에는 옳다 — 목적이 깊이를 흩뿌려 칸을 덮는 것이다. 그러나
    surrogate 라벨 행의 그룹키(`instance`)는 **OOD 사건**이고, 그 사건에서 각 팔이 무엇을
    냈는지가 있어야 `SurrogateV2.fit` 이 팔을 비교한다. 해시로 고른 결정은 "어느 사건인가"
    와 아무 상관이 없다.

    ⚠️ 접미사를 붙이는 이유: 아래 재개 캐시가 `rows.jsonl` 존재만 보고 그대로 돌려주므로,
    같은 `(case, seed, arm_id)` 를 사건마다 다른 `k` 로 굴리면서 디렉토리를 공유하면
    **사건 A 의 결과가 사건 B 의 라벨이 된다.** 에러는 안 난다.
    """
    if at is None:
        k = pick_k(case, seed, arm_id, n_hint)
        outdir = os.path.join(outroot, "%s_s%d_a%d" % (case, seed, arm_id))
    elif int(at) == 0:
        k = 0
        outdir = os.path.join(outroot, "%s_s%d_probe" % (case, seed))
    else:
        k = int(at)
        outdir = os.path.join(outroot, "%s_s%d_a%d_k%d" % (case, seed, arm_id, k))
    rows = os.path.join(outdir, "rows.jsonl")
    if os.path.exists(rows) and os.path.getsize(rows) > 0:
        return rows, k                                 # 재개: 이미 끝난 판은 다시 굴리지 않는다
    os.makedirs(outdir, exist_ok=True)
```

같은 함수 안의 `env.update(` 블록에서 `DS_DEVIATE_AT=str(k),` 와 `DS_DEVIATE_ARM=arm_name,` **두 줄을 지우고**, `env.update(` 블록 **뒤**(즉 `env.pop("DEMO_FORCE_MACRO", None)` 줄 **앞**)에 아래를 넣는다:

```python
    # 프로브 판(k == 0)은 갈아 끼우지 않는다 — 두 키를 **아예 안 넣는다**(policy.jl 은
    # DS_DEVIATE_AT 가 0 이하이면 error() 하고, 빈 문자열/미설정만 OFF 로 읽는다).
    if k > 0:
        env["DS_DEVIATE_AT"] = str(k)
        env["DS_DEVIATE_ARM"] = arm_name
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `.venv/bin/python -m pytest wm4spacecraft_manufacturing/dp_oracle/test_sample_grid_wiring.py -v --ignore=src/respec/llm_service/test_propose.py`
Expected: PASS — 10 passed

- [ ] **Step 5: 커밋 (명시 경로만)**

```bash
git add wm4spacecraft_manufacturing/dp_oracle/sample_grid.py \
        wm4spacecraft_manufacturing/dp_oracle/test_sample_grid_wiring.py
git commit -m "feat(counterfactual): 반사실 지점을 crc32 가 아니라 OOD 사건 index 에서 몬다

pick_k 는 (case,seed) 의 crc32 로 결정 하나를 고른다 — DP 표집에는 옳고 surrogate 라벨에는
틀리다(라벨의 그룹키는 사건이다). run_board 에 at 을 더한다: None=구세대 DP · 0=프로브(키를
아예 안 넘긴다, policy.jl 은 0 이하를 error 로 본다) · >=1=사건 index. 판 디렉토리에 _k<at>
을 붙인다 — 안 붙이면 재개 캐시가 사건 A 의 결과를 사건 B 의 라벨로 돌려준다."
```

---

### Task 3: 사건 열거기 — 프로브 판 하나에서 (사건 index · kind · 서술자 입력) 을 뽑는다

**왜:** Task 2 가 `at` 을 받게 만들었지만 **무엇을 넣을지가 없다.** 한 `(case, seed)` 에서 OOD 사건이 몇 번, 어떤 종류로 나는지는 판을 굴려 봐야 안다. `policy.jl` 의 `didx = _next_decision_index!()` 앵커가 **deviation 이 꺼져 있어도** 결정마다 1-기반 index 를 센다(주석이 그렇게 적는다). 그리고 `run_demo.jl` 의 `handle_ood!` 는 **OOD 사건 하나마다 한 번** 불리고 결정 행을 하나 push 한다. 즉 **결정 index = OOD 사건 index** 다.

🔴 **그런데 결정 행에 `n_active` 가 없다.** `descriptors_from_row`(`features_agnostic.py` 의 `def descriptors_from_row(` 앵커)가 읽는 값 중 `n_active` 는 세 서술자를 동시에 만든다:

```python
per_robot_share = max(1e-9, pending_total / n_active)   # work_at_risk 의 분모
recovery_capacity = float(spare / max(1.0, spare + n_active))
slack = float(np.clip(n_active / FLEET_REF, 0.0, 1.0))
```

그리고 `n_active = max(1.0, _f(row.get("n_active"), 1.0))` 이라 **없으면 예외 없이 1.0 이 된다** — `work_at_risk` 가 폭발하고 `recovery_capacity`·`slack` 이 무너진다. **조용한 종류다.** 라벨 레인(`gen_oracle_dataset.jl`)은 `n_active = length(env.cache.active_set)` 로 이 값을 낸다 — 실행 레인의 결정 행에만 없다.

⚠️ 나머지 서술자 입력은 결정 행/판 행에서 이미 나온다: `soc`·`agent_pending`·`progress`·`spare_count` 는 결정 행에, `closed_at_fire` 는 결정 행의 `closed_at` 에, `total_nodes` 는 판 행의 `total` 에. `zone_overlap` 은 이 계획이 `--cases battery,fault` 로 못박으므로 센티넬 `-1.0`(= "공간 사건 아님")이 옳다. `severity` 는 fault(`is_agent` → `harm = 1.0`)와 battery(`has_soc` → `harm = 1-soc`)에서 **읽히지 않는다** — 그래서 이 계획은 그 값을 지어내지 않고 `0.0` 을 명시적으로 적는다.

**Files:**
- Modify: `tools/monitor/run_demo.jl` (`local this_decision = Dict(` 앵커 안, `"spare_count" =>` 줄 바로 뒤)
- Create: `wm4spacecraft_manufacturing/oracle/counterfactual_labels.py` (열거 부분만)
- Create: `wm4spacecraft_manufacturing/oracle/test_counterfactual_labels.py` (열거 부분만)

**Interfaces:**
- Consumes: `sample_grid.run_board(..., at=0)` (Task 2)
- Produces:
  - `counterfactual_labels.TRUTH_TO_KIND: dict[str, str]`
  - `counterfactual_labels.events_from_board(board_row) -> list[dict]` — 각 dict 의 키는 `EVENT_KEYS`
  - `counterfactual_labels.EVENT_KEYS = ("decision_index", "kind", "soc", "agent_pending", "progress", "spare_count", "closed_at_fire", "n_active", "total_nodes")`
  - `counterfactual_labels.probe_events(case, seed, work, world_seed=1) -> list[dict]`
  - Task 4 가 넷 다 쓴다.

- [ ] **Step 1: 결정 행에 `n_active` 를 싣는 실패 테스트를 쓴다 (Julia)**

`tools/monitor/test_decision_row_has_n_active.jl` **를 만들지 않는다** — 그 값은 판을 굴려야 나오므로 순수 함수 테스트가 불가능하다. 대신 **Python 쪽 접기 게이트**가 잡게 한다. `wm4spacecraft_manufacturing/oracle/test_counterfactual_labels.py`:

```python
"""반사실 라벨 생산자 — 사건 열거와 접기의 계약.

🔴 왜 이 파일이 있나: `descriptors_from_row` 가 읽는 값은 전부 `.get(..., 기본값)` 이라
**없으면 예외 없이 0/1 로 무너진다.** 특히 `n_active` 가 없으면 `work_at_risk` 의 분모가
1.0 이 되어 값이 폭발하고 `recovery_capacity`·`slack` 이 같이 무너진다. 조용한 종류라
게이트가 없으면 영영 안 보인다.
"""
import json
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
WM = os.path.dirname(HERE)
for _d in (HERE, os.path.join(WM, "core"), os.path.join(WM, "dp_oracle")):
    if _d not in sys.path:
        sys.path.insert(0, _d)

import counterfactual_labels as cf  # noqa: E402


def _decision(idx, truth="BatteryTruth", **kw):
    """프로브 판의 결정 행 하나 — `run_demo.jl` 의 `local this_decision = Dict(` 앵커가
    실제로 적는 키만 쓴다."""
    d = {"decision_index": idx, "truth": truth, "macro": "NOOP",
         "soc": 0.12, "agent_pending": 4, "progress": 0.18, "spare_count": 12,
         "closed_at": 58, "n_active": 22, "valid": ["NOOP", "Replace", "SwapBattery"]}
    d.update(kw)
    return d


def _board(*decisions, **kw):
    b = {"complete": True, "closed": 291, "total": 313, "makespan": 22.85,
         "battery": {"total_energy_J": 96206.58221499549},
         "n_decisions": len(decisions), "decisions": list(decisions),
         "objective_hash": "489268e6659e5ae9", "vocab": "v4-3arms"}
    b.update(kw)
    return b


def test_every_decision_is_an_event():
    """OOD 사건 하나마다 `handle_ood!` 가 한 번 불리고 결정 행을 하나 push 한다."""
    evs = cf.events_from_board(_board(_decision(1), _decision(2, truth="FaultTruth")))
    assert [e["decision_index"] for e in evs] == [1, 2]
    assert [e["kind"] for e in evs] == ["battery", "fault"]


def test_event_carries_every_descriptor_input():
    evs = cf.events_from_board(_board(_decision(1)))
    assert set(evs[0]) == set(cf.EVENT_KEYS)
    assert evs[0]["closed_at_fire"] == 58        # 결정 행의 closed_at 이 라벨의 closed_at_fire 다
    assert evs[0]["total_nodes"] == 313          # 판 행의 total 이 라벨의 total_nodes 다
    assert evs[0]["n_active"] == 22


def test_a_missing_n_active_is_a_hard_stop_not_a_silent_one():
    """🔴 이 단언이 이 파일의 존재 이유다.

    `descriptors_from_row` 는 `n_active` 가 없으면 1.0 으로 읽어 세 서술자를 한꺼번에
    무너뜨리는데 **예외를 안 던진다.** 여기서 멈추지 않으면 그 라벨이 조용히 학습된다.
    (`run_demo.jl` 의 결정 행에 이 필드를 더한 것이 2026-08-28 의 변경이다 — 구세대 판
    원자료를 다시 접으면 정확히 이 자리에서 걸린다.)
    """
    d = _decision(1)
    del d["n_active"]
    with pytest.raises(ValueError, match="n_active"):
        cf.events_from_board(_board(d))


def test_an_unknown_truth_type_is_named_not_guessed():
    with pytest.raises(ValueError, match="ZoneTruth"):
        cf.events_from_board(_board(_decision(1, truth="ZoneTruth")))


def test_a_missing_decision_index_is_a_hard_stop():
    """index 를 열거 순서로 지어내면 프로브 판과 반사실 판이 조용히 어긋난다."""
    d = _decision(1)
    del d["decision_index"]
    with pytest.raises(ValueError, match="decision_index"):
        cf.events_from_board(_board(d))
```

- [ ] **Step 2: 실패를 확인한다**

Run: `.venv/bin/python -m pytest wm4spacecraft_manufacturing/oracle/test_counterfactual_labels.py -v --ignore=src/respec/llm_service/test_propose.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'counterfactual_labels'`

- [ ] **Step 3: 생산자 모듈의 열거 부분을 쓴다**

`wm4spacecraft_manufacturing/oracle/counterfactual_labels.py` (새 파일):

```python
#!/usr/bin/env python3
"""반사실 라벨 생산자 — 설계서 §4 ④.

한 OOD **사건**에서 메뉴의 모든 팔을 각각 1-step deviation 으로 굴려 **(사건, 팔) 마다 한
행**을 낸다. 그것이 `SurrogateV2.fit` 이 요구하는 모양이다 — 그 함수는 같은 instance 의
팔별 종단 결과를 비교해서 학습한다.

🔴 이 모듈이 `dp_oracle/sample_grid.py` 를 **다시 쓰지 않고 재사용하는** 이유: 판을 굴리는
환경 조립(`DS_HOTSWAP=1` · `DEMO_ALL_POLICIES=0` · 스레드 1개 · `DEMO_FORCE_MACRO` 제거)이
거기 한 곳에만 있어야 한다. 두 벌 두면 라벨 레인과 표집 레인의 세계가 조용히 갈린다 —
`DS_HOTSWAP` 하나 빠뜨리면 fault 발화율이 100% -> 23% 로 새는 것이 실측이다.

🔴 반대로 이 모듈이 `sample_grid.rows_to_samples` 를 **안 쓰는** 이유: 그 함수는 DP 격자의
칸(cell) 으로 행을 거른다(`if cells[i] is None: continue`). 칸은 `grid_spec.json` 의 이산화
사양이고 **라벨과 무관한 축인데 어느 팔이 살아남는지를 편향시킨다.** 라벨 행에는 칸이
필요 없다. 그래서 접기는 여기서 새로 한다.
"""
import argparse
import collections
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
WM = os.path.dirname(HERE)
for _d in (os.path.join(WM, "core"), os.path.join(WM, "dp_oracle"), HERE):
    if _d not in sys.path:
        sys.path.insert(0, _d)

import action_registry as reg                                   # noqa: E402
import sample_grid                                              # noqa: E402

# `run_demo.jl` 의 결정 행이 적는 `truth` 는 Julia 타입 이름이다
# (`tag = string(typeof(truth).name.name)`, `src/navigator/ood_truth.jl` 의 세 struct).
# 🔴 `.get(name, "unknown")` 으로 폴백하지 않는다 — 모르는 종류를 조용히 라벨하면 그 행이
# 무엇에 대한 것인지 아무도 모르게 된다.
TRUTH_TO_KIND = {"FaultTruth": "fault", "BatteryTruth": "battery", "ZoneTruth": "zone"}

# 라벨 레인이 이 계획에서 학습을 허용하는 사건 종류. 🔴 `zone` 은 test-only 다
# (`.claude/CLAUDE.md` §OOD): 학습 라벨셋에 넣으면 "낯선 사건을 알아보는가" 를 재려는
# 그 사건을 surrogate 가 이미 본 것이 된다.
TRAIN_KINDS = ("battery", "fault")

# 한 사건이 나르는 것 — 전부 `features_agnostic.descriptors_from_row` 의 입력이거나 그룹키다.
EVENT_KEYS = ("decision_index", "kind", "soc", "agent_pending", "progress",
              "spare_count", "closed_at_fire", "n_active", "total_nodes")


def _require(d, key, where):
    """🔴 `.get(key, 기본값)` 을 쓰지 않는다.

    `descriptors_from_row` 는 이 값들을 전부 `.get(..., 기본값)` 으로 읽어 **없으면 예외
    없이 0/1 로 무너진다.** 특히 `n_active` 가 없으면 `work_at_risk` 의 분모가 1.0 이 되어
    값이 폭발하고 `recovery_capacity`·`slack` 이 같이 무너진다. 그 조용함을 여기서 끝낸다.
    """
    if key not in d or d[key] is None:
        raise ValueError(
            "%s: 결정/판 행에 %r 가 없다 -- 기본값으로 채우지 않는다. "
            "descriptors_from_row 는 이 값을 .get(기본값) 으로 읽어 조용히 무너진다. "
            "구세대 판 원자료이거나 run_demo.jl 이 그 필드를 아직 안 싣는다." % (where, key))
    return d[key]


def events_from_board(board_row):
    """프로브 판 한 줄에서 OOD **사건** 목록을 뽑는다.

    `run_demo.jl` 의 `handle_ood!` 는 OOD 사건 하나마다 한 번 불리고 결정 행을 하나
    push 하므로, **결정 = 사건**이다. index 는 `policy.jl` 의 `didx = _next_decision_index!()`
    앵커가 1-기반으로 세고 **deviation 이 꺼져 있어도 센다**(그 자리 주석이 그렇게 적는다).
    """
    total_nodes = _require(board_row, "total", "판 행")
    out = []
    for d in (board_row.get("decisions") or []):
        where = "결정 행(decision_index=%r)" % d.get("decision_index")
        truth = _require(d, "truth", where)
        kind = TRUTH_TO_KIND.get(truth)
        if kind is None:
            raise ValueError("%s: 모르는 truth 타입 %r -- 지어내지 않는다. 아는 것: %s"
                             % (where, truth, sorted(TRUTH_TO_KIND)))
        if kind not in TRAIN_KINDS:
            raise ValueError(
                "%s: kind=%r 은 학습 라벨셋에 넣지 않는다(zone 은 test-only, "
                ".claude/CLAUDE.md §OOD). --cases 를 %s 로 좁혀서 굴릴 것."
                % (where, kind, ",".join(TRAIN_KINDS)))
        out.append({
            "decision_index": int(_require(d, "decision_index", where)),
            "kind": kind,
            # battery 사건에만 유한하다. fault 는 `run_demo.jl` 이 `nothing` 을 적고,
            # `descriptors_from_row` 는 유한하지 않은 soc 를 "배터리류 아님" 으로 읽는다.
            "soc": d.get("soc"),
            "agent_pending": _require(d, "agent_pending", where),
            "progress": _require(d, "progress", where),
            "spare_count": _require(d, "spare_count", where),
            # 이름이 바뀐다: 결정 행의 `closed_at` 이 라벨 행의 `closed_at_fire` 다.
            "closed_at_fire": _require(d, "closed_at", where),
            # 🔴 2026-08-28 에 `run_demo.jl` 결정 행에 더한 필드. 없으면 여기서 멈춘다.
            "n_active": _require(d, "n_active", where),
            "total_nodes": total_nodes,
        })
    return out


def probe_events(case, seed, work, world_seed=1):
    """이 (case, seed) 의 사건 목록. **갈아 끼우지 않은 판**(`at=0`)에서 읽는다.

    프로브 판이 사건 목록의 진실원이어야 하는 이유: 반사실 판은 결정 k 에서 세계가 갈리므로
    k 이후의 결정 목록이 판마다 다르다. 사건 열거를 반사실 판에서 하면 어느 판을 골랐느냐가
    사건 집합을 바꾼다.
    """
    rows, _ = sample_grid.run_board(case, seed, 0, "", work, world_seed=world_seed, at=0)
    if rows is None:
        raise RuntimeError(
            "프로브 판이 죽었다: case=%s seed=%s -- %s/board.log 를 볼 것. "
            "run_board 는 rc!=0 에서 예외가 아니라 None 을 돌려주므로 여기서 멈춘다."
            % (case, seed, os.path.join(work, "%s_s%d_probe" % (case, seed))))
    with open(rows) as fh:
        board_row = json.loads(fh.readline())
    return events_from_board(board_row)
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `.venv/bin/python -m pytest wm4spacecraft_manufacturing/oracle/test_counterfactual_labels.py -v --ignore=src/respec/llm_service/test_propose.py`
Expected: PASS — 5 passed

- [ ] **Step 5: `run_demo.jl` 의 결정 행에 `n_active` 를 싣는다**

`tools/monitor/run_demo.jl` — `local this_decision = Dict(` 앵커 안에서 `"spare_count" => (try length(CB.active_spares()) catch; -1 end),` 줄 **바로 뒤**에 아래를 넣는다:

```julia
        # 🔴 2026-08-28 (V3 Task 3). `features_agnostic.descriptors_from_row` 가 이 값 하나로
        # 서술자 **셋**을 만든다 — work_at_risk 의 분모(`pending_total / n_active`),
        # recovery_capacity(`spare / (spare + n_active)`), slack(`n_active / FLEET_REF`).
        # 그런데 그 함수는 `_f(row.get("n_active"), 1.0)` 로 읽어 **없으면 예외 없이 1.0** 이
        # 된다: work_at_risk 가 폭발하고 나머지 둘이 무너지는데 에러가 안 난다.
        # 라벨 레인은 이 값을 이미 낸다(`gen_oracle_dataset.jl` 의
        # `n_active = length(env.cache.active_set)`) — 실행 레인의 결정 행에만 없었다.
        # 반사실 라벨은 이 행에서 접히므로 여기 없으면 그 라벨이 조용히 거짓이 된다.
        "n_active" => (try length(env.cache.active_set) catch; -1 end),
```

- [ ] **Step 6: 필드가 실제로 실리는지 판을 굴려 확인한다**

🔴 **코드 읽기로 넘어가지 말 것.** 이 레포는 "로그에 없다" 를 "안 났다" 로 읽어 세 번 데었다.

```bash
cd /home/chahj578/Construction_OODlayer
.venv/bin/python - <<'PY'
import os, sys, json
sys.path.insert(0, os.path.abspath("wm4spacecraft_manufacturing/oracle"))
import counterfactual_labels as cf
work = os.path.abspath("wm4spacecraft_manufacturing/dp_oracle/_v3_smoke")
evs = cf.probe_events("battery", 1, work)
print("사건 %d개" % len(evs))
for e in evs:
    print(" ", {k: e[k] for k in ("decision_index", "kind", "n_active", "closed_at_fire",
                                  "total_nodes", "spare_count")})
assert all(e["n_active"] != -1 for e in evs), "🔴 n_active 가 -1 이다 — active_set 접근이 던졌다"
PY
```
Expected: 사건이 1개 이상, `n_active` 가 **-1 도 1 도 아닌 실제 로봇 수**(오늘의 라벨셋 기준 22 근방), `kind == "battery"`.

⚠️ `n_active == -1` 이면 `try` 가 던진 것이다. 그때 `env.cache.active_set` 대신 무엇을 읽어야 하는지 다시 확인하고, **그 사실을 보고서에 적는다.** `-1` 을 그대로 라벨로 내보내지 말 것 — Step 3 의 `_require` 는 `None` 만 막고 `-1` 은 통과시킨다(그 값이 "못 쟀다" 를 뜻하는 이 레포의 관용구이므로, 사건 열거 단계에서 사람이 봐야 하는 자리다).

- [ ] **Step 7: 스모크 디렉토리를 지우고 기존 Julia 게이트가 안 깨졌는지 본다**

```bash
rm -rf /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/dp_oracle/_v3_smoke
julia +lts --project=. test/policy_macro_binding.jl
julia +lts --project=. test/route_descriptors_survive.jl
```
Expected: 둘 다 PASS

- [ ] **Step 8: 커밋 (명시 경로만)**

```bash
git add tools/monitor/run_demo.jl \
        wm4spacecraft_manufacturing/oracle/counterfactual_labels.py \
        wm4spacecraft_manufacturing/oracle/test_counterfactual_labels.py
git commit -m "feat(counterfactual): OOD 사건을 프로브 판에서 열거하고 결정 행에 n_active 를 싣는다

결정 = 사건이다(handle_ood! 가 사건마다 한 번 불린다). 사건 목록은 갈아 끼우지 않은
프로브 판에서 읽는다 — 반사실 판은 k 이후가 판마다 달라 사건 집합이 판에 의존한다.
n_active 는 descriptors_from_row 가 서술자 셋을 만드는 값인데 결정 행에 없었고, 그 함수는
없으면 1.0 으로 읽어 예외 없이 무너진다. _require 로 그 조용함을 끝낸다."
```

---

### Task 4: 판을 라벨 행으로 접는다 — 스키마 **무조건** 강제 · 서술자 동일성 게이트 · **고유 시뮬레이션 수**

**왜:** Task 1~3 이 판을 굴리고 사건을 열거했다. 이제 `(사건, 팔)` 마다 한 행을 만들어야 `SurrogateV2.fit` 이 팔을 비교할 수 있다.

🔴 **"KeyError 다섯 개가 스키마를 지켜 준다" 는 잘못된 안전감이다.** 실측(사실 시트 §2): `build_features` 가 `psi(int(r["macro"]))` 를 **어떤 분기보다 앞에서** 부르므로 **무조건 강제되는 열은 `macro` 하나뿐**이다. 나머지 넷은 조건부다 — `makespan`/`energy_J` 는 `if comp.any():` 앵커(오늘 기준 `surrogate_v2.py:93`) 안에, `total`/`closed` 는 `if (~comp).any():` 앵커(`:99`) 안에 있다.

```
🔴 전부 완주 + total/closed 없음        -> fit OK (KeyError 안 남)
🔴 전부 미완주 + makespan/energy_J 없음 -> fit OK (대칭 구멍)
```

**V3 이 정확히 그 자리를 밟는다.** 1-step deviation 은 판을 canonical 로 계속 굴리므로 완주율이 높다(구세대 `DEMO_FORCE_MACRO` 의 완주율 16.9% 를 고치려고 만든 것이 그것이다). 반사실 판이 **전부 완주하면 `total`/`closed` 누락이 에러 없이 통과하고**, `predict_J` 는 `_fitted_c=False` 일 때 `self._c_fallback`(=0.0)을 쓰므로 미완주 분기가 통째로 0 인 모델이 나온다.

그리고 `complete` 는 `r.get("complete")` 라 **없으면 예외 없이 전부 미완주로 읽힌다**(실측 `max|ΔJ| = 12104.9`). 그래서 이 태스크는 **생산자가 스스로 여섯 열을 무조건 검사한다.**

⚠️ **열 이름 하나만 바꾸면 된다 — 번역 계층이 아니다.** `sample_grid` 의 산출 행은 이미 `"arm": macro_id` 를 **레지스트리 파생 정수**로 낸다. V3 의 라벨 행은 그것을 `macro` 로 부른다. `int(...)` 캐스팅만 있고 매핑 표가 없다.

🔴 **수락 기준은 행 수가 아니라 고유 시뮬레이션 수다** (§2-4). 오늘의 33행은 지문 `(complete, closed, makespan, energy_J)` 로 세면 18개로 접힌다. 이 태스크의 게이트는 **사건당 서로 다른 결과 지문의 수**를 세고, 그 수가 2 이상인 사건이 하나도 없으면 `exit 1` 이다 — 팔이 전부 같은 결과를 내는 라벨셋은 순위를 하나도 안 가르친다.

**Files:**
- Modify: `wm4spacecraft_manufacturing/oracle/counterfactual_labels.py`
- Modify: `wm4spacecraft_manufacturing/oracle/test_counterfactual_labels.py`

**Interfaces:**
- Consumes: `events_from_board` · `probe_events` · `EVENT_KEYS` · `TRUTH_TO_KIND` (Task 3) · `sample_grid.run_board(..., at=k)` · `sample_grid.arm_menu()` (Task 1·2)
- Produces:
  - `counterfactual_labels.REQUIRED_LABEL_COLUMNS: tuple[str, ...]`
  - `counterfactual_labels.assert_label_schema(row, where) -> None`
  - `counterfactual_labels.instance_id(case, seed, event_index) -> str`
  - `counterfactual_labels.fold_board_to_label_row(board_row, event, case, seed, arm_id, arm_name) -> dict`
  - `counterfactual_labels.outcome_fingerprint(row) -> tuple`
  - `counterfactual_labels.build_labels(cases, seeds, work, world_seed=1) -> tuple[list[dict], dict]`
  - `counterfactual_labels.main() -> None` (CLI)
  - Task 5 가 `REQUIRED_LABEL_COLUMNS` 에 `train_macros` 를 더하고, Task 7 이 CLI 를 쓴다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`wm4spacecraft_manufacturing/oracle/test_counterfactual_labels.py` 의 마지막 줄 뒤에 추가:

```python
# ==========================================================================================
#  접기 (Task 4)
# ==========================================================================================
def _event(idx=1, kind="battery"):
    return cf.events_from_board(_board(_decision(idx, truth={
        "battery": "BatteryTruth", "fault": "FaultTruth"}[kind])))[0]


def test_the_label_row_has_every_column_fit_needs():
    row = cf.fold_board_to_label_row(_board(_decision(1)), _event(), "battery", 1, 2,
                                     "SwapBattery")
    for col in cf.REQUIRED_LABEL_COLUMNS:
        assert col in row, col
    assert row["macro"] == 2                  # 🔴 열 이름만 바뀐다 — arm 은 이미 레지스트리 정수다
    assert row["macro_name"] == "SwapBattery"
    assert row["instance"] == "battery_s1_ev1"
    assert row["kind"] == "battery"
    assert row["fired"] is True
    assert row["vocab"] == "v4-3arms"


def test_energy_comes_from_the_battery_block_when_the_top_level_is_absent():
    """4pol 레인은 에너지를 최상위가 아니라 `battery` 하위에 낸다. 최상위만 보면 조용히 None."""
    row = cf.fold_board_to_label_row(_board(_decision(1)), _event(), "battery", 1, 0, "NOOP")
    assert row["energy_J"] == pytest.approx(96206.58221499549)


@pytest.mark.parametrize("col", ["complete", "closed", "total", "makespan", "energy_J", "macro"])
def test_a_missing_column_is_a_hard_stop_in_both_branches(col):
    """🔴 이 파라미터화가 이 파일의 두 번째 존재 이유다.

    `SurrogateV2.fit` 이 무조건 강제하는 열은 `macro` **하나뿐**이다(실측):
      · makespan/energy_J 는 `if comp.any():` 분기 안
      · total/closed 는   `if (~comp).any():` 분기 안
      · complete 는       `r.get("complete")` 라 없으면 조용히 전부 미완주 (max|ΔJ| = 12104.9)
    반사실 판이 전부 완주하면 total/closed 누락이 **에러 없이** 통과한다. 그래서 생산자가
    스스로 검사한다.
    """
    row = cf.fold_board_to_label_row(_board(_decision(1)), _event(), "battery", 1, 0, "NOOP")
    del row[col]
    with pytest.raises(ValueError, match=col):
        cf.assert_label_schema(row, "테스트")


def test_the_schema_gate_does_not_depend_on_whether_the_board_completed():
    """🔴 음성 대조: 완주 판에서도 미완주 판에서도 **여섯 열 전부**를 요구한다."""
    for complete, closed in ((True, 313), (False, 163)):
        b = _board(_decision(1), complete=complete, closed=closed)
        row = cf.fold_board_to_label_row(b, _event(), "battery", 1, 1, "Replace")
        cf.assert_label_schema(row, "ok")
        for col in ("makespan", "energy_J", "total", "closed", "complete", "macro"):
            bad = dict(row)
            del bad[col]
            with pytest.raises(ValueError, match=col):
                cf.assert_label_schema(bad, "%s/%s" % (complete, col))


def test_infinite_makespan_survives_the_json_round_trip():
    """미완주 판의 makespan 은 Inf 다. `e1_analyze.load` 가 "Inf" 문자열을 되돌린다."""
    b = _board(_decision(1), complete=False, closed=163, makespan=float("inf"))
    row = cf.fold_board_to_label_row(b, _event(), "battery", 1, 0, "NOOP")
    assert json.loads(json.dumps(row))["makespan"] == "Inf"


def test_valid_mask_comes_from_the_registry_not_a_literal():
    import action_registry as reg
    row = cf.fold_board_to_label_row(_board(_decision(1)), _event(), "battery", 1, 0, "NOOP")
    assert row["valid_mask"] == reg.KIND_VALID["battery"]
    frow = cf.fold_board_to_label_row(_board(_decision(1, truth="FaultTruth")),
                                      _event(kind="fault"), "fault", 1, 0, "NOOP")
    assert frow["valid_mask"] == reg.KIND_VALID["fault"]


def test_outcome_fingerprint_counts_simulations_not_rows():
    """🔴 오늘의 33행은 이 지문으로 세면 **18개 시뮬레이션**으로 접힌다.

    "N 행을 만들었다" 로 만족하는 수락 기준은 중복으로 채워질 수 있다.
    """
    a = cf.fold_board_to_label_row(_board(_decision(1)), _event(), "battery", 1, 0, "NOOP")
    b = cf.fold_board_to_label_row(_board(_decision(1)), _event(), "battery", 1, 1, "Replace")
    assert cf.outcome_fingerprint(a) == cf.outcome_fingerprint(b)   # 같은 판 = 같은 시뮬
    c = cf.fold_board_to_label_row(_board(_decision(1), closed=200, complete=False),
                                   _event(), "battery", 1, 2, "SwapBattery")
    assert cf.outcome_fingerprint(a) != cf.outcome_fingerprint(c)


def test_the_descriptor_columns_are_taken_from_the_event_not_the_arm_board():
    """같은 사건의 팔들은 결정 k 까지 바이트 동일하므로 서술자가 같아야 한다.

    사건에서 한 번 읽어 모든 팔에 같이 넣으면 그 계약이 **구성상** 지켜진다.
    """
    ev = _event()
    rows = [cf.fold_board_to_label_row(_board(_decision(1), closed=c), ev, "battery", 1, i, n)
            for i, n, c in ((0, "NOOP", 100), (1, "Replace", 200), (2, "SwapBattery", 300))]
    for col in ("soc", "agent_pending", "progress", "spare_count", "closed_at_fire",
                "n_active", "total_nodes"):
        assert len({r[col] for r in rows}) == 1, col
```

- [ ] **Step 2: 실패를 확인한다**

Run: `.venv/bin/python -m pytest wm4spacecraft_manufacturing/oracle/test_counterfactual_labels.py -v --ignore=src/respec/llm_service/test_propose.py`
Expected: FAIL — `AttributeError: module 'counterfactual_labels' has no attribute 'fold_board_to_label_row'`

- [ ] **Step 3: 접기와 스키마 게이트를 쓴다**

`wm4spacecraft_manufacturing/oracle/counterfactual_labels.py` 의 `def probe_events(` 함수 **뒤**에 추가:

```python
# ==========================================================================================
#  판 -> 라벨 행
# ==========================================================================================
# 🔴 `SurrogateV2.fit` 이 **무조건** 강제하는 열은 `macro` 하나뿐이다(2026-08-28 실측).
#    · makespan/energy_J -> `if comp.any():` 분기 안에서만 KeyError
#    · total/closed      -> `if (~comp).any():` 분기 안에서만 KeyError
#    · complete          -> `r.get("complete")` 라 **없으면 예외 없이 전부 미완주**로 읽힌다
#                           (실측 max|ΔJ| = 12104.9, 헤드 B 가 아예 적합되지 않는다)
#    1-step deviation 은 판을 canonical 로 계속 굴려 완주율이 높으므로, 반사실 판이 전부
#    완주하면 `total`/`closed` 누락이 **에러 없이** 통과하고 predict_J 의 미완주 분기가
#    통째로 0(_c_fallback)이 된다. 그래서 생산자가 스스로 여섯을 다 본다.
_FIT_COLUMNS = ("macro", "complete", "makespan", "energy_J", "total", "closed")
# `eval_surrogate_v2.load_rows` 의 로딩 계약이 요구하는 열 (도장·필터·그룹키).
_LOAD_COLUMNS = ("vocab", "fired", "instance", "kind", "valid_mask")
# `features_agnostic.descriptors_from_row` 가 읽는 열. 전부 `.get(기본값)` 이라 없으면 조용하다.
_DESCRIPTOR_COLUMNS = ("soc", "zone_overlap", "agent_pending", "severity", "n_active",
                       "spare_count", "closed_at_fire", "total_nodes", "progress")
REQUIRED_LABEL_COLUMNS = _FIT_COLUMNS + _LOAD_COLUMNS + _DESCRIPTOR_COLUMNS


def assert_label_schema(row, where):
    """행 하나가 세 소비처의 요구를 **분기와 무관하게** 다 갖췄는가.

    🔴 `hasattr`/`.get` 이 아니라 키 존재로 본다. `None` 도 거부한다 — 이 레포에서 `None`
    은 "못 쟀다" 이고, 못 잰 값을 라벨로 내보내면 그 사실이 학습에 흡수된다.
    ⚠️ 예외: `soc` 는 fault 사건에서 정당하게 `None` 이다(`descriptors_from_row` 가 유한하지
    않은 soc 를 "배터리류 아님" 으로 읽는 것이 그 함수의 계약이다). 그래서 키 존재만 본다.
    """
    missing = [c for c in REQUIRED_LABEL_COLUMNS if c not in row]
    if missing:
        raise ValueError("%s: 라벨 행에 %s 가 없다 -- 조용히 채우지 않는다. "
                         "SurrogateV2.fit 이 무조건 강제하는 것은 macro 하나뿐이라 "
                         "나머지는 여기서 안 보면 아무도 안 본다." % (where, ", ".join(missing)))
    nulls = [c for c in REQUIRED_LABEL_COLUMNS if c != "soc" and row.get(c) is None]
    if nulls:
        raise ValueError("%s: 라벨 행의 %s 가 None 이다 -- '못 쟀다' 를 라벨로 내보내지 않는다."
                         % (where, ", ".join(nulls)))


def instance_id(case, seed, event_index):
    """라벨 행의 그룹키 = **OOD 사건 하나**.

    🔴 이것이 V3 의 요점이다. 오늘의 라벨셋은 instance 가 `<kind>_s<seed>_sev<x>_sp<n>` 이라
    "설정" 단위인데, 폐루프가 요구하는 것은 **사건** 단위다 — LLM 이 대응한 그 사건에서
    안 고른 팔들이 무엇을 냈는지가 라벨이어야 하기 때문이다.
    """
    return "%s_s%d_ev%d" % (case, int(seed), int(event_index))


def _terminal_energy(board_row):
    """4pol 레인은 에너지를 최상위가 아니라 `battery` 하위에 낸다 (`objective.J_row` 가 두
    스키마를 다 읽는 이유가 그것이다). 최상위만 보면 조용히 None 이 되고, 그건 "에너지를
    안 썼다" 가 아니라 "잘못된 키를 봤다" 다."""
    e = board_row.get("energy_J")
    if e is None:
        e = (board_row.get("battery") or {}).get("total_energy_J")
    return e


def _jsonable(x):
    """JSON 은 Inf/NaN 을 리터럴로 못 쓴다. 이 레포의 규약은 `"Inf"`/`"NaN"` 문자열이고
    `e1_analyze.load` 가 읽을 때 되돌린다(`makespan`·`soc`·`zone_radius` 열)."""
    import math
    if isinstance(x, float):
        if math.isinf(x):
            return "Inf" if x > 0 else "-Inf"
        if math.isnan(x):
            return "NaN"
    return x


def fold_board_to_label_row(board_row, event, case, seed, arm_id, arm_name):
    """반사실 판 한 줄 + 그 사건 = 라벨 행 하나.

    **서술자 열은 `event` 에서 온다** (판이 아니라). 같은 사건의 팔들은 결정 k 까지 바이트
    동일하므로 서술자가 같아야 하는데, 팔마다 자기 판에서 읽으면 그 계약이 **가정**이 된다.
    사건에서 한 번 읽어 모두에게 같이 넣으면 **구성상** 지켜진다.
    **결과 열은 판에서 온다** — 그것이 이 팔이 만든 미래다.
    """
    row = {
        # ---- fit 이 요구하는 여섯 ----------------------------------------------------------
        # 🔴 `arm` -> `macro` 는 **이름 바꾸기**다. sample_grid 의 macro_id 는
        #    `{reg.MACRO_NAME[i]: i for i in reg.ACTIVE_MACROS}` 에서 온 레지스트리 파생
        #    정수이지 번역 표의 산물이 아니다.
        "macro": int(arm_id),
        "macro_name": str(arm_name),
        "complete": bool(board_row["complete"]),
        "makespan": _jsonable(board_row["makespan"]),
        "energy_J": _terminal_energy(board_row),
        "total": board_row["total"],
        "closed": board_row["closed"],
        # ---- load_rows 의 로딩 계약 --------------------------------------------------------
        # 🔴 리터럴 금지: 도장은 레지스트리에서 받는다.
        "vocab": reg.VOCAB,
        "fired": True,                 # 이 행은 실제로 발화한 사건의 결과다(stub 이 아니다)
        "instance": instance_id(case, seed, event["decision_index"]),
        "kind": event["kind"],
        "valid_mask": list(reg.KIND_VALID[event["kind"]]),
        # ---- descriptors_from_row 의 입력 --------------------------------------------------
        "soc": _jsonable(event["soc"]),
        # `--cases battery,fault` 에는 공간 사건이 없다. -1.0 은 이 레포의 "해당 없음" 센티넬이고
        # `descriptors_from_row` 가 `zov >= 0.0` 으로 공간 사건을 가른다.
        "zone_overlap": -1.0,
        "agent_pending": event["agent_pending"],
        # 🔴 지어내지 않는다. fault(`is_agent`)는 harm=1.0 이고 battery(`has_soc`)는 1-soc 라
        #    이 값을 **읽지 않는다**(`descriptors_from_row` 의 else 분기에서만 쓰인다).
        #    실행 레인의 결정 행에는 severity 가 없으므로 0.0 을 명시적으로 적는다.
        "severity": 0.0,
        "n_active": event["n_active"],
        "spare_count": event["spare_count"],
        "closed_at_fire": event["closed_at_fire"],
        "total_nodes": event["total_nodes"],
        "progress": event["progress"],
        # ---- 세대 도장(provenance) -----------------------------------------------------------
        "objective_hash": board_row.get("objective_hash"),
        "energy_objective": board_row.get("energy_objective"),
        "dynamics": board_row.get("dynamics"),
        "hot_swap": {"enabled": True, "mode": "via_depot"},   # run_board 가 DS_HOTSWAP=1 을 넘긴다
        # ---- 진단 전용 (fit 도 load_rows 도 안 읽는다) ----------------------------------------
        "case": case, "seed": int(seed),
        "decision_index": int(event["decision_index"]),
        "sampling_mode": "counterfactual_event",
        "n_decisions": board_row.get("n_decisions"),
    }
    assert_label_schema(row, "fold(%s, s%s, ev%s, arm %s)"
                        % (case, seed, event["decision_index"], arm_name))
    return row


def outcome_fingerprint(row):
    """🔴 **행이 아니라 시뮬레이션을 센다.**

    2026-08-28 실측: 오늘의 33행은 이 지문으로 세면 **18개 고유 시뮬레이션**으로 접힌다
    (macro=1 이 seed 당 4행 공유 · macro=2 가 seed 당 3행 공유). 모든 coverage·분위수의
    실효 자유도가 그만큼 과대평가돼 있었다. "N 행 만들었다" 를 수락 기준으로 삼으면
    중복으로 만족된다.
    """
    return (row["complete"], row["closed"], row["makespan"], row["energy_J"])
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `.venv/bin/python -m pytest wm4spacecraft_manufacturing/oracle/test_counterfactual_labels.py -v --ignore=src/respec/llm_service/test_propose.py`
Expected: PASS — 13 passed

- [ ] **Step 5: 오케스트레이터와 CLI 를 쓴다**

같은 파일의 끝에 추가:

```python
# ==========================================================================================
#  오케스트레이션
# ==========================================================================================
def build_labels(cases, seeds, work, world_seed=1):
    """(case, seed) 마다 프로브 판 하나 + 사건 x 팔 만큼의 반사실 판. 반환: (rows, report).

    판 수 = sum over (case, seed) of [1 + sum over 사건 of |그 사건의 메뉴|].
    🔴 **순차 실행이다** (CLAUDE.md 함정 30): 병렬이면 HiGHS 가 다른 스케줄을 내
    **팔 비교 자체가 무효**가 되고 프로세스당 ~2.5GB 라 OOM 이다.
    """
    menu = dict(sample_grid.arm_menu())                     # id -> name (레지스트리 파생)
    rows = []
    rep = {"boards_planned": 0, "boards_dead": 0, "events": 0, "rows": 0,
           "dead_boards": [], "events_with_ge2_distinct": 0,
           "distinct_by_event": {}, "arms_by_event": {}}
    for case in cases:
        for seed in seeds:
            events = probe_events(case, seed, work, world_seed=world_seed)
            rep["events"] += len(events)
            for ev in events:
                # 이 사건의 메뉴 = 레지스트리가 그 kind 에 허용하는 활성 팔.
                # 🔴 결정 행의 `valid` 를 쓰지 않는다: `valid_macros` 는 FaultTruth 에서
                #    `String[]` 을 돌려주고 그것은 "아무것도 유효하지 않다" 가 아니라
                #    "전용 메뉴가 없다(서비스의 kind 기본표를 쓰라)" 는 뜻이다
                #    (`policy.jl` 의 `rt["deviate_valid"] = isempty(_vm) || dev in _vm` 앵커).
                #    빈 배열을 메뉴로 읽으면 fault 사건의 팔이 0개가 된다.
                arms = [(i, menu[i]) for i in reg.KIND_VALID[ev["kind"]] if i in menu]
                rep["arms_by_event"][instance_id(case, seed, ev["decision_index"])] = len(arms)
                got = []
                for arm_id, arm_name in arms:
                    rep["boards_planned"] += 1
                    p, _ = sample_grid.run_board(case, seed, arm_id, arm_name, work,
                                                 world_seed=world_seed,
                                                 at=ev["decision_index"])
                    if p is None:
                        bid = "%s_s%d_a%d_k%d" % (case, seed, arm_id, ev["decision_index"])
                        rep["boards_dead"] += 1
                        rep["dead_boards"].append(bid)
                        print("[반사실] 🔴 판이 죽었다: %s -- %s/board.log"
                              % (bid, os.path.join(work, bid)), flush=True)
                        continue
                    with open(p) as fh:
                        board_row = json.loads(fh.readline())
                    got.append(fold_board_to_label_row(board_row, ev, case, seed,
                                                       arm_id, arm_name))
                iid = instance_id(case, seed, ev["decision_index"])
                n_distinct = len({outcome_fingerprint(r) for r in got})
                rep["distinct_by_event"][iid] = n_distinct
                if n_distinct >= 2:
                    rep["events_with_ge2_distinct"] += 1
                rows.extend(got)
    rep["rows"] = len(rows)
    rep["distinct_sims"] = len({outcome_fingerprint(r) for r in rows})
    return rows, rep


def _print_report(rep):
    print("\n[반사실] 계획 %d판 · 죽은 판 %d · 사건 %d개 · 행 %d개"
          % (rep["boards_planned"], rep["boards_dead"], rep["events"], rep["rows"]))
    # 🔴 헤드라인 숫자는 행이 아니라 **고유 시뮬레이션**이다 (2026-08-28: 오늘의 33행이
    #    18개 시뮬로 접힌다). 행 수만 보면 중복으로 채워진 라벨셋이 좋아 보인다.
    print("[반사실] 🔴 고유 시뮬레이션 %d개 / 행 %d개  (지문: complete·closed·makespan·energy_J)"
          % (rep["distinct_sims"], rep["rows"]))
    print("[반사실] 팔이 서로 다른 결과를 낸 사건 %d / %d"
          % (rep["events_with_ge2_distinct"], rep["events"]))
    for iid in sorted(rep["distinct_by_event"]):
        print("[반사실]   %-28s 팔 %d개 -> 고유 결과 %d개"
              % (iid, rep["arms_by_event"][iid], rep["distinct_by_event"][iid]))
    for bid in rep["dead_boards"]:
        print("[반사실]   죽은 판: %s" % bid)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    # 🔴 기본값이 zone 계열을 안 태운다. `sample_grid.CASES` 기본값은 7 케이스인데 그중 넷
    #    (`all`·`fault_zone`·`battery_zone`·`zone`)이 zone 을 태우고, 그 산출을 라벨로 쓰면
    #    `gen_oracle_dataset.jl` 이 명문화한 설계 약속(zone 은 OOD 프로브다)을 정확히 어긴다.
    ap.add_argument("--cases", default=",".join(TRAIN_KINDS))
    ap.add_argument("--seeds", default="1,2,3")
    ap.add_argument("--world-seed", type=int, default=1)
    ap.add_argument("--work", default=os.path.join(HERE, "out", "_cf_work"))
    ap.add_argument("--out", default=os.path.join(HERE, "out", "counterfactual_labels.jsonl"))
    ap.add_argument("--drop-macro", default="",
                    help="이 매크로 id 들의 행을 **일부러 뺀다**(콤마 구분). R2 의 '전' 라벨셋을 "
                         "만드는 손잡이다 — 지원집합을 줄여 축 1 을 발화시킨다.")
    a = ap.parse_args()

    cases = [c for c in a.cases.split(",") if c.strip()]
    seeds = [int(s) for s in a.seeds.split(",") if s.strip()]
    bad = [c for c in cases if c not in TRAIN_KINDS]
    if bad:
        sys.exit("🔴 --cases 에 학습 금지 케이스가 있다: %s (zone 은 test-only, "
                 ".claude/CLAUDE.md §OOD). 허용: %s" % (bad, list(TRAIN_KINDS)))

    os.makedirs(a.work, exist_ok=True)
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    rows, rep = build_labels(cases, seeds, a.work, world_seed=a.world_seed)

    drop = {int(x) for x in a.drop_macro.split(",") if x.strip()}
    if drop:
        before = len(rows)
        rows = [r for r in rows if r["macro"] not in drop]
        print("[반사실] --drop-macro %s: %d행 -> %d행 (지원집합을 일부러 좁힌다)"
              % (sorted(drop), before, len(rows)))

    _print_report(rep)

    # 🔴 게이트: 팔이 전부 같은 결과를 내는 라벨셋은 순위를 하나도 안 가르친다.
    #    "N 행 만들었다" 로 만족하는 기준은 중복으로 채워질 수 있다(2026-08-28: 33행 -> 18 시뮬).
    if rep["events_with_ge2_distinct"] == 0:
        sys.exit("🔴 어떤 사건에서도 팔이 서로 다른 결과를 내지 않았다 -- 이 라벨셋은 순위를 "
                 "하나도 안 가르친다. 행을 쓰지 않는다(exit 1).")
    if rep["boards_dead"]:
        sys.exit("🔴 죽은 판 %d개 -- 부분 라벨셋을 쓰지 않는다. 위 board.log 를 볼 것(exit 1)."
                 % rep["boards_dead"])

    with open(a.out, "w") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    macros = collections.Counter(r["macro"] for r in rows)
    print("[반사실] -> %s  (행 %d · instance %d · macro %s)"
          % (a.out, len(rows), len({r["instance"] for r in rows}), dict(sorted(macros.items()))))


if __name__ == "__main__":
    main()
```

- [ ] **Step 6: 전체 유닛 게이트를 다시 돌린다**

Run: `.venv/bin/python -m pytest wm4spacecraft_manufacturing/oracle/test_counterfactual_labels.py wm4spacecraft_manufacturing/dp_oracle/test_sample_grid_wiring.py -v --ignore=src/respec/llm_service/test_propose.py`
Expected: PASS — 23 passed

- [ ] **Step 7: 🔴 진짜 라벨을 만든다 (실행 시간이 드는 유일한 스텝)**

```bash
cd /home/chahj578/Construction_OODlayer
time .venv/bin/python wm4spacecraft_manufacturing/oracle/counterfactual_labels.py \
    --cases battery,fault --seeds 1,2,3 \
    --work wm4spacecraft_manufacturing/oracle/out/_cf_work \
    --out wm4spacecraft_manufacturing/oracle/out/counterfactual_labels.jsonl \
    2>&1 | tee wm4spacecraft_manufacturing/oracle/out/counterfactual_labels.log
```

Expected: `exit 0`. 규모 예상: `(case 2 × seed 3)` 프로브 6판 + 사건당 팔 수만큼. `DEMO_N` 기본값이 4 이므로 battery 사건 ~4개 × 3팔 × 3 seed = 36판, fault 사건 ~4개 × 2팔 × 3 seed = 24판 → **총 ~66판**. 오늘의 라벨셋 `label_seconds` 중앙값이 판당 ~76 s 이므로 **순차 ~85분**.

🔴 **`--jobs` 를 만들지 않았다. 병렬로 굴리지 말 것** — HiGHS 가 다른 스케줄을 내면 팔 비교 자체가 무효다(CLAUDE.md 함정 30).

🔴 **`exit 1` 이 나면 그 자리에서 멈춘다.** 두 종료 조건은 서로 다른 사건이다:
- `팔이 서로 다른 결과를 내지 않았다` → 라벨셋이 순위를 안 가르친다. **행을 안 쓴다.** 사건 index 가 실제로 갈아 끼워졌는지(`deviated`)를 `_cf_work/*/rows.jsonl` 에서 확인하고 보고서에 적는다.
- `죽은 판 N개` → `board.log` 를 열어 원인을 보고서에 그대로 붙인다.

- [ ] **Step 8: 만들어진 라벨을 실제 소비처로 태워 본다**

```bash
.venv/bin/python - <<'PY'
import sys, os
sys.path.insert(0, os.path.abspath("wm4spacecraft_manufacturing/surrogate"))
sys.path.insert(0, os.path.abspath("wm4spacecraft_manufacturing/core"))
from eval_surrogate_v2 import load_rows
from surrogate_v2 import SurrogateV2
import collections
rows, meta = load_rows("wm4spacecraft_manufacturing/oracle/out/counterfactual_labels.jsonl")
print("meta =", meta)
print("macro =", collections.Counter(r["macro"] for r in rows))
print("instance =", len({r["instance"] for r in rows}))
print("완주 행 =", sum(1 for r in rows if r["complete"]), "/", len(rows))
m = SurrogateV2().fit(rows)
print("fit OK  _fitted_b =", m._fitted_b, " _fitted_c =", m._fitted_c)
PY
```
Expected: `load_rows` 가 `SystemExit`/`ValueError` 없이 통과하고 `fit OK`.

🔴 **`_fitted_c == False` 가 나오면 그 사실을 보고서에 적는다** — 반사실 판이 전부 완주했다는 뜻이고, `predict_J` 의 미완주 분기가 통째로 `_c_fallback`(=0.0)이 된다. 이 계획서 §2-3 이 예고한 자리다. 그 자체가 실패는 아니지만 **Task 8 의 재측정이 그 위에서 이뤄진다는 것을 알고 읽어야 한다.**

- [ ] **Step 9: 커밋 (명시 경로만 — `_cf_work` 는 넣지 않는다)**

```bash
git add wm4spacecraft_manufacturing/oracle/counterfactual_labels.py \
        wm4spacecraft_manufacturing/oracle/test_counterfactual_labels.py \
        wm4spacecraft_manufacturing/oracle/out/counterfactual_labels.jsonl \
        wm4spacecraft_manufacturing/oracle/out/counterfactual_labels.log
git commit -m "feat(counterfactual): 사건 x 팔 반사실 판을 라벨 행으로 접는다

instance = OOD 사건이다. 서술자는 사건에서 한 번 읽어 모든 팔에 같이 넣는다 -- 팔마다 자기
판에서 읽으면 '결정 k 까지 바이트 동일' 이 가정이 되고, 이렇게 하면 구성상 지켜진다.
스키마는 생산자가 무조건 검사한다: SurrogateV2.fit 이 무조건 강제하는 열은 macro 하나뿐이고
makespan/energy_J 와 total/closed 는 완주/미완주 분기 안에만 있어, 반사실 판이 전부 완주하면
total/closed 누락이 에러 없이 통과한다. 수락 기준은 행 수가 아니라 고유 시뮬레이션 수다."
```

⚠️ **`_cf_work/` 를 커밋하지 않는다** — 판 원자료는 수 GB 다. 필요하면 `.gitignore` 확인 후 별도 판단.

---

### Task 5: 🔴 `train_macros` 도장 — **소비처와 같은 태스크에서** 들어온다

**왜 하나의 태스크인가 (이 계획서에서 가장 쉽게 잘못 쪼개지는 자리):** `train_kinds` 는 `gen_oracle_dataset.jl` 에서 **4곳에 찍히고 읽는 곳이 0곳**이다(실측: `:1949`·`:1989`·`:2164`·`:2228`, `read site` 전수 조사 0건). `load_rows` 의 `meta` 7키에도 없다. 그래서 **kind 경계가 얼어붙은 채 아무도 모르게 있었다** — 생성기 스스로 *"게이트는 일부러 안 만들었다"* 라고 적는다. 설계서 §5 가 *"도장만 찍고 소비처를 안 만드는 것이 그 실패다"* 라고 쓴 것이 이것이고, V1 에서 `router_axis` 가 정확히 같은 실수를 반복할 뻔했다.

> 🔴 **이 태스크를 "도장 태스크" 와 "소비처 태스크" 로 나누면 리뷰가 통과시킨다. 나누지 말 것.**

**무엇을 주장하는 도장인가:**

| 도장 | 주장 | 검사 |
|---|---|---|
| `vocab` (유지) | 동역학·목적함수·**팔 수** 세대 | 정확한 문자열 동등 (지금 그대로) |
| **`train_macros`** (신설) | 이 파일이 **어떤 매크로를 가르치는가** | **부분집합**: 모든 id 가 현행 레지스트리의 활성 매크로인가 |

**소비처는 축 1 이다.** 오늘 지원집합은 `dspy_service.py` 의 `support = sorted({int(r["macro"]) for r in rows})` 앵커에서 나온다 — **`fired` 필터를 통과한 행에서 사후 유도한 값**이다. 그것을 **파일의 선언**으로 바꾼다. 차이가 실재한다:
- 유도값은 필터가 행을 걷어내면 조용히 줄어든다. 선언은 안 줄어든다.
- 두 파일을 concat 하면 유도값은 그냥 합집합이 되지만, 선언은 **서로 다른 도장이 섞였다**고 죽는다.
- 은퇴한/재번호된 id 가 들어오면 유도값은 그냥 통과하지만 선언은 부분집합 검사에서 죽는다.

🔴 **그리고 Julia 판을 같이 만든다.** `grep -rn 'require_vocab_stamps' --include='*.jl'` 이 무매치다 — **행 집합 도장을 Julia 가 찍고 Python 만 읽는다.** 소비처를 Python 에만 만들면 생성 레인은 자기 도장이 현행 어휘와 맞는지 **끝까지 모른다.**

**Files:**
- Modify: `wm4spacecraft_manufacturing/core/action_registry.py`
- Modify: `wm4spacecraft_manufacturing/oracle/action_registry.jl`
- Modify: `wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl` (`"train_kinds"=>TRAIN_KINDS,` 앵커 4곳 + 상수 정의부)
- Modify: `wm4spacecraft_manufacturing/oracle/counterfactual_labels.py` (생산자가 도장을 찍는다)
- Modify: `wm4spacecraft_manufacturing/surrogate/eval_surrogate_v2.py` (`load_rows` — **소비처 1**)
- Modify: `src/respec/llm_service/dspy_service.py` (`_load_surrogate` — **소비처 2**)
- Modify: `wm4spacecraft_manufacturing/surrogate/export_surrogate.py` (`_load_labels` + meta — **소비처 3**)
- Modify: `wm4spacecraft_manufacturing/surrogate/test_load_rows_vocab.py` · `test_export_surrogate_vocab.py` (픽스처)
- Modify: `wm4spacecraft_manufacturing/oracle/out/oracle_dataset.jsonl` · `out/counterfactual_labels.jsonl` (백필, **시뮬레이션 없음**)
- Create: `wm4spacecraft_manufacturing/core/test_train_macros_stamp.py`
- Create: `wm4spacecraft_manufacturing/oracle/backfill_train_macros.py`
- Create: `test/train_macros_stamp_smoke.jl`
- Modify: `test/runtests.jl`

**Interfaces:**
- Consumes: `counterfactual_labels.REQUIRED_LABEL_COLUMNS` (Task 4) · `action_registry.ACTIVE_MACROS`
- Produces:
  - `action_registry.train_macros_stamp(macros) -> list[int]`
  - `action_registry.require_train_macros_stamps(stamps, where) -> list[int]`
  - `ActionRegistry.train_macros_stamp(macros)::Vector{Int}` · `ActionRegistry.require_train_macros_stamps(stamps, where::AbstractString)::Vector{Int}`
  - `eval_surrogate_v2.load_rows(path)` 의 `meta` 에 `"train_macros": list[int]` 추가 (기존 7키 → 8키)
  - 🔴 **시그니처 변경:** `counterfactual_labels.assert_label_schema(row, where, skip=())` — Task 4 판의 `(row, where)` 에 `skip` 이 붙는다. Task 4 의 `fold_board_to_label_row` 가 유일한 호출자이고 같은 스텝에서 같이 고친다.
  - `counterfactual_labels.REQUIRED_LABEL_COLUMNS` 에 `"train_macros"` 가 들어간다.
  - Task 6·7 이 `meta["train_macros"]` 를 쓴다.

- [ ] **Step 1: 실패하는 테스트를 쓴다 (Python)**

`wm4spacecraft_manufacturing/core/test_train_macros_stamp.py`:

```python
"""`train_macros` 도장 — **부분집합**이지 동등이 아니다.

🔴 왜 새 도장인가 (설계서 §5): `vocab` 은 정확한 문자열 동등이라 성장을 구조적으로 처벌한다.
그런데 "이 파일이 어떤 매크로를 가르치는가" 는 세대와 다른 축이고, 지원집합이 어휘의
**부분집합**으로 자라는 것이 폐루프의 기전 그 자체다.

🔴 그리고 이 파일이 존재하는 두 번째 이유: `train_kinds` 는 4곳에서 찍히고 **읽는 곳이
0곳**이라 kind 경계가 얼어붙은 채 아무도 몰랐다. 도장은 소비처와 같이 들어와야 한다.
"""
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import action_registry as reg  # noqa: E402


def test_stamp_is_sorted_and_deduplicated():
    assert reg.train_macros_stamp([2, 0, 1, 0]) == [0, 1, 2]


def test_stamp_rejects_an_id_the_registry_does_not_have():
    with pytest.raises(ValueError, match="99"):
        reg.train_macros_stamp([0, 99])


def test_stamp_rejects_an_empty_set():
    """'아무 매크로도 안 가르친다' 는 라벨 파일은 라벨 파일이 아니다."""
    with pytest.raises(ValueError, match="비어"):
        reg.train_macros_stamp([])


def test_a_proper_subset_is_allowed_this_is_the_whole_point():
    """🔴 이 단언이 설계서 §5 의 요점이다 — 지원집합이 어휘보다 작아도 유효하다."""
    assert reg.train_macros_stamp([0, 1]) == [0, 1]


def test_require_reads_row_stamps_and_returns_the_set():
    stamps = [[0, 1, 2], [0, 1, 2], [0, 1, 2]]
    assert reg.require_train_macros_stamps(stamps, "ok") == [0, 1, 2]


def test_require_rejects_a_file_whose_rows_disagree():
    """🔴 두 라벨 파일을 concat 한 것이 정확히 이 모양이다. 유도값(행의 macro 합집합)은
    조용히 통과하지만 선언은 안 통과한다."""
    with pytest.raises(ValueError, match="행마다 다르다"):
        reg.require_train_macros_stamps([[0, 1], [0, 1, 2]], "섞인 파일")


def test_require_rejects_a_missing_column_loudly():
    with pytest.raises(ValueError, match="train_macros"):
        reg.require_train_macros_stamps(None, "구세대 라벨")


def test_require_rejects_an_id_outside_the_current_registry():
    with pytest.raises(ValueError, match="99"):
        reg.require_train_macros_stamps([[0, 99]], "구세대 라벨")
```

- [ ] **Step 2: 실패를 확인한다**

Run: `.venv/bin/python -m pytest wm4spacecraft_manufacturing/core/test_train_macros_stamp.py -v --ignore=src/respec/llm_service/test_propose.py`
Expected: FAIL — `AttributeError: module 'action_registry' has no attribute 'train_macros_stamp'`

- [ ] **Step 3: Python 도장을 만든다**

`wm4spacecraft_manufacturing/core/action_registry.py` — `def require_dynamics(obj, expected, where):` **바로 앞**에 추가:

```python
def train_macros_stamp(macros):
    """`train_macros` 도장의 정규형. 정렬·중복 제거된 int 리스트를 돌려준다.

    🔴 `vocab` 과 **다른 종류의 주장**이다 (설계서 §5):
      · `vocab`        — 동역학·목적함수·팔 수 **세대**.       검사는 정확한 문자열 동등.
      · `train_macros` — 이 파일이 **어떤 매크로를 가르치는가**. 검사는 **부분집합**.
    지원집합이 어휘의 진부분집합으로 자라는 것이 폐루프의 기전 그 자체이므로, 이 축까지
    동등으로 검사하면 성장이 다시 처벌된다.
    """
    ids = sorted({int(m) for m in macros})
    if not ids:
        raise ValueError("train_macros 도장이 비어 있다 -- 어떤 매크로도 안 가르치는 라벨 "
                         "파일은 라벨 파일이 아니다.")
    unknown = [i for i in ids if i not in ACTIVE_MACROS]
    if unknown:
        raise ValueError(
            "train_macros 도장에 현행 레지스트리의 활성 매크로가 아닌 id 가 있다: %s. "
            "현행 활성 = %s (vocab %r). 구세대 라벨이거나 은퇴한 팔이다 -- remap 하지 않는다."
            % (unknown, sorted(ACTIVE_MACROS), VOCAB))
    return ids


def require_train_macros_stamps(stamps, where):
    """라벨 **파일**의 행별 `train_macros` 도장을 대조하고 그 집합을 돌려준다.

    `require_vocab_stamps` 와 짝이지만 검사가 다르다 — 저쪽은 동등, 이쪽은 부분집합이다.
    행마다 **같은 값**이어야 한다: 두 라벨 파일을 concat 하면 행별 선언이 갈리는데, 오늘의
    지원집합 유도(`{int(r["macro"]) for r in rows}`)는 그것을 그냥 합집합으로 삼켜서
    "이 모델이 무엇을 배웠는가" 가 조용히 바뀐다.

    🔴 `fired` 같은 행 필터 **앞에서** 부를 것 — `require_vocab_stamps` 와 같은 이유다.
    """
    if stamps is None:
        raise ValueError(
            "%s: `train_macros` 열이 없다 -- 이 파일은 자기가 어떤 매크로를 가르치는지 "
            "선언하지 않는다. 행의 macro 열에서 사후 유도하지 않는다(필터가 행을 걷어내면 "
            "그 값이 조용히 줄어든다). backfill_train_macros.py 로 도장을 찍을 것." % where)
    seen = {tuple(sorted({int(m) for m in s})) for s in stamps}
    if len(seen) != 1:
        raise ValueError(
            "%s: `train_macros` 도장이 행마다 다르다: %s. 서로 다른 세대의 라벨을 concat 한 "
            "파일이다 -- 합집합으로 뭉개지 않는다." % (where, sorted(seen)))
    return train_macros_stamp(seen.pop())
```

- [ ] **Step 4: Python 도장 테스트가 통과하는지 확인한다**

Run: `.venv/bin/python -m pytest wm4spacecraft_manufacturing/core/test_train_macros_stamp.py -v --ignore=src/respec/llm_service/test_propose.py`
Expected: PASS — 8 passed

- [ ] **Step 5: 🔴 소비처 1 — `load_rows` 가 도장을 검사하고 `meta` 에 싣는다**

`wm4spacecraft_manufacturing/surrogate/eval_surrogate_v2.py` — `action_registry.require_vocab_stamps(` 호출 **바로 뒤**(즉 `if "fired" not in df.columns:` 줄 앞)에 추가:

```python
    # 계약 0-b (2026-08-28, V3): `train_macros` 도장. `vocab` 과 **다른 축**이다 -- 저쪽은
    # 세대(동등), 이쪽은 이 파일이 가르치는 매크로 집합(부분집합)이다.
    # 🔴 `require_vocab_stamps` 와 같은 이유로 `fired` 필터 **앞에서** 본다.
    # 🔴 그리고 이 값이 배포 지원집합의 진실원이 된다(dspy_service._load_surrogate).
    #    예전에는 필터 뒤 행에서 `{int(r["macro"]) for r in rows}` 로 사후 유도했는데,
    #    그러면 (a) 필터가 행을 걷어내면 지원집합이 조용히 줄고, (b) 두 세대를 concat 한
    #    파일에서 합집합이 되어 "이 모델이 무엇을 배웠는가" 가 거짓이 된다.
    train_macros = action_registry.require_train_macros_stamps(
        df["train_macros"] if "train_macros" in df.columns else None, path)
```

같은 함수의 `return rows, {...}` dict 에 한 줄 더한다 (기존 7키 → 8키):

```python
                  "train_macros": train_macros,
```

- [ ] **Step 6: 🔴 소비처 2 — `_load_surrogate` 가 지원집합을 도장에서 받는다**

`src/respec/llm_service/dspy_service.py` — `support = sorted({int(r["macro"]) for r in rows})` 앵커의 그 한 줄을 아래로 **교체**한다:

```python
        # 🔴 `sorted({int(r["macro"]) for r in rows})` 였다 (2026-08-28, V3 Task 5).
        #    그것은 **`fired` 필터를 통과한 행에서 사후 유도한 값**이라 파일이 무엇을
        #    가르치는지에 대한 선언이 아니었다. 이제 라벨 파일이 `train_macros` 도장으로
        #    직접 선언하고 `load_rows` 가 그것을 검사해서 meta 로 올린다.
        #    ⚠️ 설계서 §5 가 요구한 "도장과 소비처는 같은 커밋" 이 바로 이 두 줄의 관계다 —
        #    `train_kinds` 는 4곳에서 찍히고 **읽는 곳이 0곳**이라 kind 경계가 얼어붙은 채
        #    아무도 몰랐다. 그 실패를 반복하지 않는다.
        support = list(meta["train_macros"])
```

- [ ] **Step 7: 🔴 소비처 3 — export 가 도장을 검사하고 **디스크에 기록**한다**

`wm4spacecraft_manufacturing/surrogate/export_surrogate.py` — `_load_labels` 안의 `_reg.require_vocab_stamps(...)` 줄 **바로 뒤**에 추가:

```python
    # 2026-08-28 (V3 Task 5): 같은 자리에서 `train_macros` 도 본다. 검사가 두 벌로 갈리면
    # 한쪽만 고쳐지고 나머지가 조용히 구세대를 먹는다 -- 이 함수의 docstring 이 적는 그 사고다.
    _reg.require_train_macros_stamps(
        df["train_macros"] if "train_macros" in df.columns else None, path)
```

그리고 `main()` 의 export dict 안 `"kinds": sorted(set(str(k) for k in df.kind)),` 줄 **바로 뒤**에 추가:

```python
            # 🔴 설계서 §4: "디스크의 어떤 산출물도 이 모델이 어떤 매크로를 지원하는가를
            #    적지 않는다" -- 그 자리를 닫는다. `kinds` 는 적으면서 매크로 지원집합은
            #    안 적던 것이 이 파일의 구멍이었다(2026-08-28 실측: 배포 artifact 의 meta
            #    8키에 macro 축이 없다).
            "train_macros": _reg.require_train_macros_stamps(df["train_macros"], "export meta"),
```

- [ ] **Step 8: 생산자가 도장을 찍게 한다**

`wm4spacecraft_manufacturing/oracle/counterfactual_labels.py` — `_LOAD_COLUMNS` 정의를 아래로 **교체**한다:

```python
# `eval_surrogate_v2.load_rows` 의 로딩 계약이 요구하는 열 (도장·필터·그룹키).
_LOAD_COLUMNS = ("vocab", "train_macros", "fired", "instance", "kind", "valid_mask")
```

같은 파일의 `build_labels` 에서 `rep["rows"] = len(rows)` 줄 **앞**에 추가:

```python
    # 🔴 `train_macros` 도장은 **파일 전체의 선언**이라 모든 행을 모은 뒤에 찍는다.
    #    행마다 자기 macro 를 적는 것이 아니다 — 그러면 오늘의 사후 유도와 똑같아진다.
    stamp = reg.train_macros_stamp({r["macro"] for r in rows}) if rows else []
    for r in rows:
        r["train_macros"] = list(stamp)
```

⚠️ `fold_board_to_label_row` 안의 `assert_label_schema` 는 그 시점에 `train_macros` 가 아직 없으므로 실패한다. **`fold_board_to_label_row` 의 마지막 두 줄**

```python
    assert_label_schema(row, "fold(%s, s%s, ev%s, arm %s)"
                        % (case, seed, event["decision_index"], arm_name))
    return row
```

를 이렇게 바꾼다:

```python
    # `train_macros` 는 파일 전체의 선언이라 `build_labels` 가 마지막에 찍는다. 여기서는
    # 그 하나만 빼고 본다 -- "아직 안 찍혔다" 와 "안 찍는다" 를 뭉개지 않기 위해, 빼는
    # 열을 이름으로 명시한다.
    assert_label_schema(row, "fold(%s, s%s, ev%s, arm %s)"
                        % (case, seed, event["decision_index"], arm_name),
                        skip=("train_macros",))
    return row
```

그리고 `assert_label_schema` **함수 전체를** 아래로 **교체**한다 (Task 4 판에서 바뀌는 것은 `skip` 인자 하나와 그것을 반영한 `required` 목록이다):

```python
def assert_label_schema(row, where, skip=()):
    """행 하나가 세 소비처의 요구를 **분기와 무관하게** 다 갖췄는가.

    🔴 `hasattr`/`.get` 이 아니라 키 존재로 본다. `None` 도 거부한다 -- 이 레포에서 `None`
    은 "못 쟀다" 이고, 못 잰 값을 라벨로 내보내면 그 사실이 학습에 흡수된다.
    ⚠️ 예외: `soc` 는 fault 사건에서 정당하게 `None` 이다(`descriptors_from_row` 가 유한하지
    않은 soc 를 "배터리류 아님" 으로 읽는 것이 그 함수의 계약이다). 그래서 키 존재만 본다.

    `skip` (2026-08-28, Task 5): 이 시점에 **아직 안 찍힌** 열의 이름. 오늘 유일한 값은
    `("train_macros",)` 이고, 그 도장은 파일 전체의 선언이라 `build_labels` 가 모든 행을
    모은 뒤에 찍는다. 🔴 기본값을 `()` 로 두는 것이 요점이다 -- 빼는 열을 **호출자가 이름으로
    말하게** 해서 "아직 안 찍혔다" 와 "안 찍는다" 가 뭉개지지 않게 한다.
    """
    required = [c for c in REQUIRED_LABEL_COLUMNS if c not in skip]
    missing = [c for c in required if c not in row]
    if missing:
        raise ValueError("%s: 라벨 행에 %s 가 없다 -- 조용히 채우지 않는다. "
                         "SurrogateV2.fit 이 무조건 강제하는 것은 macro 하나뿐이라 "
                         "나머지는 여기서 안 보면 아무도 안 본다." % (where, ", ".join(missing)))
    nulls = [c for c in required if c != "soc" and row.get(c) is None]
    if nulls:
        raise ValueError("%s: 라벨 행의 %s 가 None 이다 -- '못 쟀다' 를 라벨로 내보내지 않는다."
                         % (where, ", ".join(nulls)))
```

`main()` 의 `--drop-macro` 처리 **뒤**, `_print_report(rep)` **앞**에 추가:

```python
    if drop:
        # 🔴 행을 뺐으면 도장을 **다시 찍는다.** 안 그러면 파일이 "가르친다" 고 선언한
        #    매크로의 행이 실제로는 없어서, 지원집합이 거짓이 된다 -- R2 의 '전' 라벨셋이
        #    정확히 그 상태가 된다.
        stamp = reg.train_macros_stamp({r["macro"] for r in rows})
        for r in rows:
            r["train_macros"] = list(stamp)
        print("[반사실] train_macros 도장을 다시 찍었다: %s" % stamp)
```

- [ ] **Step 9: 기존 라벨 파일에 도장을 백필한다 (🔴 시뮬레이션 없음)**

⚠️ Step 5 는 `train_macros` 를 **필수**로 만들었다. 그러면 오늘의 `oracle_dataset.jsonl` 33행과 Task 4 가 만든 `counterfactual_labels.jsonl` 이 배포 적재 경로에서 죽는다. 재생성은 답이 아니다 — 그 33행을 만든 **손잡이 조합이 레포의 어떤 스크립트에도 없고**(커밋 `ef7559ab` 의 메시지에만 있다) 45판 재시뮬 756.3 s 가 든다. **도장은 파일 자신의 `macro` 열에서 결정론적으로 유도되므로 백필이 옳다.**

`wm4spacecraft_manufacturing/oracle/backfill_train_macros.py` (새 파일):

```python
#!/usr/bin/env python3
"""기존 라벨 파일에 `train_macros` 도장을 찍는다. **시뮬레이션을 하지 않는다.**

🔴 왜 재생성이 아닌가: 오늘의 `oracle_dataset.jsonl` 33행을 만든 손잡이 **조합**
(`DS_KINDS=fault,battery` + `DS_VALID_ONLY=1` + `DS_BATTERY_SOC_SPLIT=0` + `DS_HOTSWAP=1`
+ 기본 `DS_OUT`)을 그대로 재실행하는 스크립트가 레포에 없다 -- 커밋 `ef7559ab` 의 메시지에만
있다. 그리고 45판 재시뮬은 순수 시뮬 시간만 756.3 s 다.

🔴 왜 백필이 정직한가: 도장은 "이 파일이 어떤 매크로를 가르치는가" 이고, 그것은 파일의
`macro` 열에서 **결정론적으로** 유도된다. 새로운 세계를 만들지 않는다 -- 이미 참인 것을
파일이 스스로 말하게 만들 뿐이다.

⚠️ 이 스크립트는 **`fired` 필터를 안 탄다.** 도장은 파일 전체의 선언이므로 미발화 stub 의
macro 도 포함한다 -- 필터 뒤에서 유도하면 그것이 오늘의 사후 유도와 똑같아진다.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "core"))

import action_registry as reg  # noqa: E402


def backfill(path, dry_run=False):
    with open(path, encoding="utf-8") as fh:
        rows = [json.loads(l) for l in fh if l.strip()]
    if not rows:
        raise SystemExit("%s: 빈 파일이다." % path)
    already = {tuple(sorted(r["train_macros"])) for r in rows if "train_macros" in r}
    if already and len(already) == 1 and all("train_macros" in r for r in rows):
        print("%s: 이미 도장이 있다 %s -- 건드리지 않는다." % (path, sorted(already)[0]))
        return
    if already:
        raise SystemExit("%s: 도장이 일부 행에만 있거나 행마다 다르다 %s -- 손으로 볼 것."
                         % (path, sorted(already)))
    stamp = reg.train_macros_stamp({int(r["macro"]) for r in rows})
    print("%s: %d행 -> train_macros = %s (vocab %s)" % (path, len(rows), stamp, reg.VOCAB))
    if dry_run:
        return
    for r in rows:
        r["train_macros"] = list(stamp)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    for p in a.paths:
        backfill(p, dry_run=a.dry_run)


if __name__ == "__main__":
    main()
```

먼저 dry-run 으로 무엇이 찍히는지 본다:

```bash
cd /home/chahj578/Construction_OODlayer
.venv/bin/python wm4spacecraft_manufacturing/oracle/backfill_train_macros.py --dry-run \
    wm4spacecraft_manufacturing/oracle/out/oracle_dataset.jsonl \
    wm4spacecraft_manufacturing/oracle/out/counterfactual_labels.jsonl
```
Expected: `oracle_dataset.jsonl: 33행 -> train_macros = [0, 1, 2] (vocab v4-3arms)` 과 반사실 파일의 같은 모양

그 다음 실제로 찍는다 (`--dry-run` 제거):

```bash
.venv/bin/python wm4spacecraft_manufacturing/oracle/backfill_train_macros.py \
    wm4spacecraft_manufacturing/oracle/out/oracle_dataset.jsonl \
    wm4spacecraft_manufacturing/oracle/out/counterfactual_labels.jsonl
```

- [ ] **Step 10: 테스트 픽스처 둘을 고친다**

`wm4spacecraft_manufacturing/surrogate/test_load_rows_vocab.py` — `def _row(vocab, **kw):` 안의 dict 리터럴에 한 항목을 더한다:

```python
    r = {"vocab": vocab, "train_macros": [0, 1, 2], "fired": True, "macro": 2,
         "complete": True, "instance": "i1", "kind": "battery", "valid_mask": [1, 1, 1]}
```

같은 파일의 마지막에 새 계약의 게이트를 더한다:

```python
def test_train_macros_lands_in_meta_where_the_consumer_can_see_it(tmp_path):
    """🔴 `train_kinds` 는 4곳에서 찍히고 **읽는 곳이 0곳**이었고, `load_rows` 의 meta 에도
    없어서 배포 적재 경로가 그것을 볼 수조차 없었다. 이 단언이 그 재발을 막는다."""
    rows, meta = load_rows(_write(tmp_path, _row(action_registry.VOCAB)))
    assert meta["train_macros"] == [0, 1, 2]


def test_a_label_file_without_the_new_stamp_is_rejected_loudly(tmp_path):
    r = _row(action_registry.VOCAB)
    del r["train_macros"]
    with pytest.raises(ValueError, match="train_macros"):
        load_rows(_write(tmp_path, r))


def test_two_generations_concatenated_are_rejected(tmp_path):
    """유도값(행의 macro 합집합)은 조용히 통과하지만 선언은 안 통과한다."""
    with pytest.raises(ValueError, match="행마다 다르다"):
        load_rows(_write(tmp_path,
                         _row(action_registry.VOCAB, train_macros=[0, 1]),
                         _row(action_registry.VOCAB, train_macros=[0, 1, 2])))
```

`wm4spacecraft_manufacturing/surrogate/test_export_surrogate_vocab.py` — 그 파일이 만드는 라벨 행 픽스처에 같은 `"train_macros"` 항목을 더한다.

🔴 **파일을 열어 픽스처의 실제 모양을 보고 고칠 것.** 두 파일의 픽스처 헬퍼 이름이 다르다. 고친 뒤 `git diff` 로 **`train_macros` 한 항목만** 늘었는지 확인한다.

- [ ] **Step 11: Python 소비처 전체를 돌린다**

Run:
```bash
.venv/bin/python -m pytest wm4spacecraft_manufacturing/ src/respec/llm_service/ -v \
    --ignore=src/respec/llm_service/test_propose.py
```
Expected: 전부 PASS.

🔴 여기서 빨개지는 것 중 **진짜 결함**과 **픽스처 누락**을 구분해서 보고서에 적는다. `require_train_macros_stamps` 가 던진 것은 대개 픽스처 누락이고, `train_macros_stamp` 가 던진 것은 **그 라벨 파일이 현행 레지스트리 밖 id 를 가르친다**는 진짜 발견이다.

- [ ] **Step 12: Julia 판 도장을 만든다**

`wm4spacecraft_manufacturing/oracle/action_registry.jl` — `require_vocab` 함수의 `end` **바로 뒤**에 추가:

```julia
"""
    train_macros_stamp(macros) -> Vector{Int}

`train_macros` 도장의 정규형. 정렬·중복 제거된 id 벡터.

🔴 `vocab` 과 **다른 종류의 주장**이다: `vocab` 은 세대(정확한 동등), 이것은 이 파일이
가르치는 매크로 집합(**부분집합**)이다. 지원집합이 어휘의 진부분집합으로 자라는 것이
폐루프의 기전이므로, 이 축까지 동등으로 검사하면 성장이 다시 처벌된다.
"""
function train_macros_stamp(macros)::Vector{Int}
    ids = sort(unique(Int[Int(m) for m in macros]))
    isempty(ids) && error("train_macros 도장이 비어 있다 — 어떤 매크로도 안 가르치는 라벨 " *
                          "파일은 라벨 파일이 아니다.")
    act = Set(active_ids())
    unknown = [i for i in ids if !(i in act)]
    isempty(unknown) || error(
        "train_macros 도장에 현행 레지스트리의 활성 매크로가 아닌 id 가 있다: $(unknown). " *
        "현행 활성 = $(sort(collect(act))) (vocab $(VOCAB)). remap 하지 않는다.")
    return ids
end

"""
    require_train_macros_stamps(stamps, where) -> Vector{Int}

라벨 **파일**의 행별 `train_macros` 도장을 대조하고 그 집합을 돌려준다.

🔴 2026-08-28 실측: 이 레인에는 **행 집합 도장 검사가 아예 없었다** —
`grep -rn 'require_vocab_stamps' --include='*.jl'` 이 무매치다. 즉 도장을 **찍는 쪽이
Julia 인데 검사할 함수는 Python 에만** 있었고, 생성 레인은 자기 도장이 현행 어휘와 맞는지
끝까지 몰랐다. `train_macros` 가 그 비대칭을 물려받지 않게 여기 같이 둔다.
"""
function require_train_macros_stamps(stamps, where::AbstractString)::Vector{Int}
    stamps === nothing && error("$(where): `train_macros` 열이 없다 — 이 파일은 자기가 어떤 " *
                                "매크로를 가르치는지 선언하지 않는다.")
    seen = Set{Vector{Int}}()
    for s in stamps
        push!(seen, sort(unique(Int[Int(m) for m in s])))
    end
    length(seen) == 1 || error(
        "$(where): `train_macros` 도장이 행마다 다르다: $(sort(collect(seen))). " *
        "서로 다른 세대의 라벨을 concat 한 파일이다 — 합집합으로 뭉개지 않는다.")
    return train_macros_stamp(first(seen))
end
```

- [ ] **Step 13: `gen_oracle_dataset.jl` 이 도장을 찍게 한다 (write site 4곳)**

`wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl` — `const TRAIN_KINDS = join(...)` 줄 **바로 뒤**에 상수를 더한다:

```julia
# ---- train_macros 도장 (2026-08-28, V3 Task 5) --------------------------------------------
# 🔴 `train_kinds` 의 매크로 판이다. 그리고 `train_kinds` 의 교훈을 물려받는다 — 그것은
# 4곳에서 찍히고 **읽는 곳이 0곳**이라 kind 경계가 얼어붙은 채 아무도 몰랐다.
# 이 도장의 소비처는 **같은 커밋**에 있다: eval_surrogate_v2.load_rows 가 meta 로 올리고
# dspy_service._load_surrogate 가 그것을 지원집합으로 쓴다(설계서 §5 의 축 1).
# 값은 이 생성기가 실제로 굴리는 팔 집합(MACROS = ActionRegistry.active_ids())이다.
const TRAIN_MACROS = ActionRegistry.train_macros_stamp(MACROS)
println(">>> train_macros: $(TRAIN_MACROS)  (vocab=$(VOCAB))")
```

그 다음 `"train_kinds"=>TRAIN_KINDS,` 앵커 **네 곳 전부**(오늘 기준 `:1949`·`:1989`·`:2164`·`:2228`) 바로 뒤에 같은 줄을 넣는다:

```julia
                "train_macros"=>TRAIN_MACROS,   # 세대의 여섯 번째 축 (어떤 팔을 가르치나 — V3 §5)
```

🔴 **들여쓰기는 각 자리의 `"train_kinds"` 줄과 정확히 맞춘다** — 네 자리의 들여쓰기가 서로 다르다(`:1989` 와 `:2228` 은 더 깊다). 넣은 뒤 확인:

```bash
grep -n 'train_macros' wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl
```
Expected: 상수 정의 1줄 + println 1줄 + write site **4줄** = 6줄

- [ ] **Step 14: Julia 게이트를 쓰고 `runtests.jl` 에 배선한다**

`test/train_macros_stamp_smoke.jl` (새 파일):

```julia
# test/train_macros_stamp_smoke.jl
# `train_macros` 도장의 Julia 쪽. 🔴 이 레인에는 행 집합 도장 검사가 **아예 없었다**
# (`grep -rn require_vocab_stamps --include='*.jl'` 무매치) — 도장을 찍는 쪽이 자기 도장을
# 검사할 수 없는 비대칭이었다. 이 파일이 그것을 닫는다.
#   julia +lts --project=. test/train_macros_stamp_smoke.jl
using Test
include(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "oracle", "action_registry.jl"))

@testset "train_macros 도장" begin
    # 정규형
    @test ActionRegistry.train_macros_stamp([2, 0, 1, 0]) == [0, 1, 2]

    # 🔴 부분집합이 유효하다 — 이것이 설계서 §5 의 요점이다(지원집합이 어휘보다 작아도 된다).
    @test ActionRegistry.train_macros_stamp([0, 1]) == [0, 1]

    # 음성 대조 셋
    @test_throws ErrorException ActionRegistry.train_macros_stamp(Int[])
    @test_throws ErrorException ActionRegistry.train_macros_stamp([0, 99])
    @test_throws ErrorException ActionRegistry.require_train_macros_stamps(nothing, "도장 없음")

    # 행 집합 검사: 같으면 통과, 갈리면 죽는다(= 두 세대를 concat 한 파일)
    @test ActionRegistry.require_train_macros_stamps([[0, 1, 2], [0, 1, 2]], "ok") == [0, 1, 2]
    @test_throws ErrorException ActionRegistry.require_train_macros_stamps(
        [[0, 1], [0, 1, 2]], "섞인 파일")

    # 🔴 Python 과 **같은 값**을 내는가. 두 레인이 다른 도장을 찍으면 라벨 파일 하나가
    #    레인에 따라 다른 것을 주장하게 된다.
    py = joinpath(dirname(dirname(@__DIR__)), ".venv", "bin", "python")
    py = isfile(py) ? py : joinpath(@__DIR__, "..", ".venv", "bin", "python")
    core = joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "core")
    got = readchomp(`$(py) -c "import sys; sys.path.insert(0, $(repr(core))); import action_registry as r; print(r.train_macros_stamp(r.ACTIVE_MACROS))"`)
    @test got == string(ActionRegistry.train_macros_stamp(ActionRegistry.active_ids()))
end
```

`test/runtests.jl` — `@testset "SMDP stamps" begin` 블록 **바로 뒤**에 추가:

```julia
    # 2026-08-28 (V3 Task 5): 행 집합 도장 검사의 Julia 판. 이 레인에는 그것이 **아예
    # 없었다** — 도장을 찍는 쪽이 자기 도장을 검사할 수 없는 비대칭이었다.
    @testset "train_macros stamp" begin
        include("train_macros_stamp_smoke.jl")
    end
```

- [ ] **Step 15: Julia 게이트를 돌린다**

```bash
julia +lts --project=. test/train_macros_stamp_smoke.jl
julia +lts --project=. test/smdp_stamp_smoke.jl
grep -n train_macros_stamp_smoke test/runtests.jl
```
Expected: 앞 둘 PASS, grep 이 한 줄

- [ ] **Step 16: 🔴 소비처가 실제로 값을 쓰는지 확인한다 (도장만 찍고 끝나지 않았음의 증거)**

```bash
cd /home/chahj578/Construction_OODlayer
.venv/bin/python - <<'PY'
import sys, os
for d in ("wm4spacecraft_manufacturing/surrogate", "wm4spacecraft_manufacturing/core"):
    sys.path.insert(0, os.path.abspath(d))
from eval_surrogate_v2 import load_rows
rows, meta = load_rows("wm4spacecraft_manufacturing/oracle/out/oracle_dataset.jsonl")
print("meta keys =", sorted(meta))
print("train_macros =", meta["train_macros"])
derived = sorted({int(r["macro"]) for r in rows})
print("사후 유도값 =", derived, " 같은가 ->", derived == meta["train_macros"])
PY
grep -rn 'train_macros' src/respec/llm_service/dspy_service.py \
    wm4spacecraft_manufacturing/surrogate/eval_surrogate_v2.py \
    wm4spacecraft_manufacturing/surrogate/export_surrogate.py
```
Expected: `meta` 가 8키, `train_macros == [0, 1, 2]`, grep 이 **세 파일 전부에서** 매치. 🔴 매치가 한 파일이라도 없으면 `train_kinds` 의 실패를 반복한 것이다 — 거기서 멈춘다.

- [ ] **Step 17: 커밋 (명시 경로만 — 한 커밋에 도장과 소비처가 같이 들어간다)**

```bash
git add wm4spacecraft_manufacturing/core/action_registry.py \
        wm4spacecraft_manufacturing/core/test_train_macros_stamp.py \
        wm4spacecraft_manufacturing/oracle/action_registry.jl \
        wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl \
        wm4spacecraft_manufacturing/oracle/counterfactual_labels.py \
        wm4spacecraft_manufacturing/oracle/backfill_train_macros.py \
        wm4spacecraft_manufacturing/oracle/out/oracle_dataset.jsonl \
        wm4spacecraft_manufacturing/oracle/out/counterfactual_labels.jsonl \
        wm4spacecraft_manufacturing/surrogate/eval_surrogate_v2.py \
        wm4spacecraft_manufacturing/surrogate/export_surrogate.py \
        wm4spacecraft_manufacturing/surrogate/test_load_rows_vocab.py \
        wm4spacecraft_manufacturing/surrogate/test_export_surrogate_vocab.py \
        src/respec/llm_service/dspy_service.py \
        test/train_macros_stamp_smoke.jl test/runtests.jl
git commit -m "feat(stamp): train_macros 도장과 그 소비처를 같은 커밋에 넣는다

train_kinds 는 4곳에서 찍히고 읽는 곳이 0곳이라 kind 경계가 얼어붙은 채 아무도 몰랐다
(load_rows 의 meta 에도 없어서 배포 적재 경로가 볼 수조차 없었다). 그 실패를 반복하지 않는다:
load_rows 가 meta 로 올리고 dspy_service 가 그것을 지원집합으로 쓴다 — 예전의 사후 유도
({int(r[macro]) for r in rows})는 fired 필터 뒤 값이라 파일의 선언이 아니었다.
검사는 vocab(동등)과 달리 **부분집합**이다 — 지원집합이 어휘보다 작게 자라는 것이 폐루프다.
Julia 판도 같이 만든다: 이 레인에는 행 집합 도장 검사가 아예 없었다."
```

---

### Task 6: ⑤ 재학습 — 라벨 파일을 갈아 끼우고 **재적재**한다

**왜:** 설계서 §4 ⑤ 는 *"재학습 → 지원집합이 자란다"* 인데 **자동화가 하나도 없다.** 실측:

```
$ grep -rn '_load_surrogate' src/ tools/ wm4spacecraft_manufacturing/
src/respec/llm_service/dspy_service.py:336:    _load_surrogate()   # ← 생산: 유일
(나머지 둘은 테스트가 startup 훅을 우회하려고 직접 부르는 것)
$ grep -n '@app\.' src/respec/llm_service/dspy_service.py
331:@app.on_event("startup")   694:@app.get("/health")   717:@app.post("/macro")   750:@app.post("/decide")
```

**재적재 엔드포인트가 없고**, `SURRO_DATA` 는 `wm_datasets.abspath(wm_datasets.ORACLE_DATASET)` 로 **모듈 로드 시점 상수**로 굳는다. 즉 오늘 "재학습" = 라벨 재생성 + uvicorn 재시작이다.

🔴 **그러면 R2 를 잴 수 없다.** R2 는 *"**같은** 사건이 라벨 추가 **전에는** dspy 로, **후에는** surrogate 로 가는가"* 인데, 프로세스를 재시작하면 "같은 서비스" 라는 전제가 관측으로 뒷받침되지 않는다(다른 프로세스가 다르게 뜬 것과 구분이 안 된다). 그래서 이 태스크가 **한 프로세스 안에서 라벨을 갈아 끼우고 다시 적합하는 경로**를 만든다.

**Files:**
- Modify: `src/respec/llm_service/dspy_service.py`
- Create: `src/respec/llm_service/test_reload_grows_support.py`

**Interfaces:**
- Consumes: `eval_surrogate_v2.load_rows(path)` 의 `meta["train_macros"]` (Task 5)
- Produces:
  - `dspy_service.SURRO_DATA` — 이제 `os.environ.get("SURRO_DATA")` 를 먼저 본다
  - `dspy_service._load_surrogate(path=None) -> None` — `path` 를 주면 그 파일로 적합하고 `SURRO_DATA` 를 그 값으로 갱신한다
  - `POST /reload` → `{"ok": bool, "surro_support": list[int] | None, "surrogate": str, "path": str}`
  - Task 7 이 셋 다 쓴다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`src/respec/llm_service/test_reload_grows_support.py`:

```python
"""⑤ 재학습 — 라벨 파일을 갈아 끼우면 지원집합이 **실제로** 자라는가.

🔴 왜 (설계서 §4 ⑤ 실측): `_load_surrogate()` 의 생산 호출부는 FastAPI startup 하나뿐이고
HTTP 라우트 넷 중 재적재가 없다. `SURRO_DATA` 는 모듈 로드 시점 상수다. 즉 오늘 "재학습" 은
uvicorn 재시작이고, 그러면 "같은 서비스에서 경계가 움직였다" 를 관측할 방법이 없다 —
다른 프로세스가 다르게 뜬 것과 구분되지 않는다.
"""
import json
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import dspy_service as svc  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
LABELS = os.path.join(REPO, "wm4spacecraft_manufacturing", "oracle", "out",
                      "counterfactual_labels.jsonl")


def _subset(dst, drop_macro):
    """반사실 라벨에서 매크로 하나를 빼고 도장을 다시 찍은 파일을 만든다."""
    sys.path.insert(0, os.path.join(REPO, "wm4spacecraft_manufacturing", "core"))
    import action_registry as reg
    with open(LABELS, encoding="utf-8") as fh:
        rows = [json.loads(l) for l in fh if l.strip()]
    rows = [r for r in rows if int(r["macro"]) != drop_macro]
    stamp = reg.train_macros_stamp({int(r["macro"]) for r in rows})
    for r in rows:
        r["train_macros"] = list(stamp)
    with open(dst, "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    return stamp


@pytest.fixture
def restore_state():
    """적재 상태를 반드시 되돌린다 — 이 파일이 다른 테스트 파일의 세계를 바꾸면 안 된다."""
    saved = (svc.SURRO_DATA, svc._state.get("surro_support"),
             svc._state.get("surrogate"), svc._state.get("surro_data"))
    yield
    svc.SURRO_DATA = saved[0]
    svc._state["surro_support"] = saved[1]
    svc._state["surrogate"] = saved[2]
    svc._state["surro_data"] = saved[3]


def test_load_surrogate_takes_an_explicit_path(tmp_path, restore_state):
    p = str(tmp_path / "reduced.jsonl")
    stamp = _subset(p, drop_macro=2)
    svc._load_surrogate(p)
    assert svc._state["surro_support"] == set(stamp)
    assert 2 not in svc._state["surro_support"]


def test_reload_route_grows_the_support_set(tmp_path, restore_state):
    """🔴 ⑤ 의 판정: 같은 프로세스에서 라벨을 갈아 끼우면 지원집합이 자란다."""
    reduced = str(tmp_path / "reduced.jsonl")
    _subset(reduced, drop_macro=2)

    before = svc.reload(svc.ReloadRequest(path=reduced))
    assert before["ok"] is True
    assert 2 not in before["surro_support"]

    after = svc.reload(svc.ReloadRequest(path=LABELS))
    assert after["ok"] is True
    assert 2 in after["surro_support"]
    assert set(before["surro_support"]) < set(after["surro_support"])   # 진부분집합


def test_a_failed_reload_does_not_silently_keep_the_old_model(tmp_path, restore_state):
    """🔴 못 읽었으면 '못 읽었다' 고 답한다 — 낡은 모델로 계속 답하면서 ok 를 내면 안 된다."""
    bad = str(tmp_path / "nope.jsonl")
    out = svc.reload(svc.ReloadRequest(path=bad))
    assert out["ok"] is False
    assert svc._state["surro_support"] is None
    assert bad in out["surrogate"] or "nope" in out["surrogate"]


def test_the_env_override_is_read_at_module_scope(tmp_path):
    """`SURRO_DATA` 환경변수가 기본 라벨 파일을 이긴다 — 재시작 없이 세계를 고를 수 있어야
    R2 의 '전' 상태를 재현할 수 있다.

    🔴 **별도 프로세스로 확인한다.** `importlib.reload(dspy_service)` 로 재면 sys.modules
    안의 **같은 모듈 객체**가 갈아엎여 `_state` 가 초기화되고, 그러면 이 파일이 같은 세션의
    다른 테스트 파일의 세계를 바꾼다. 모듈 로드 시점 상수를 재는 유일하게 안전한 방법은
    새 프로세스다.
    """
    import subprocess
    env = dict(os.environ, SURRO_DATA=str(tmp_path / "chosen.jsonl"))
    out = subprocess.run(
        [sys.executable, "-c",
         "import sys; sys.path.insert(0, %r); import dspy_service as s; print(s.SURRO_DATA)"
         % HERE],
        capture_output=True, text=True, env=env, cwd=REPO)
    assert out.returncode == 0, out.stderr
    assert out.stdout.strip() == str(tmp_path / "chosen.jsonl"), out.stdout


```

- [ ] **Step 2: 실패를 확인한다**

Run: `.venv/bin/python -m pytest src/respec/llm_service/test_reload_grows_support.py -v --ignore=src/respec/llm_service/test_propose.py`
Expected: FAIL — `TypeError: _load_surrogate() takes 0 positional arguments but 1 was given`

- [ ] **Step 3: `SURRO_DATA` 를 env 로 덮을 수 있게 한다**

`src/respec/llm_service/dspy_service.py` — `SURRO_DATA = wm_datasets.abspath(wm_datasets.ORACLE_DATASET)` 한 줄을 아래로 **교체**한다:

```python
# 🔴 2026-08-28 (V3 Task 6): 환경변수로 덮을 수 있게 했다. 예전에는 모듈 로드 시점 상수라
#    다른 라벨셋으로 이 서비스를 띄우려면 코드를 고치는 수밖에 없었다. R2(설계서 §7)는
#    "같은 사건이 라벨 추가 전에는 dspy 로, 후에는 surrogate 로 가는가" 이므로 **두 라벨셋을
#    같은 배선으로 띄울 수 있어야** 잴 수 있다.
#    ⚠️ 이것은 상수가 아니라 **현재 적재된 파일**이다 — `_load_surrogate(path)` 가 갱신한다.
SURRO_DATA = os.environ.get("SURRO_DATA") or wm_datasets.abspath(wm_datasets.ORACLE_DATASET)
```

- [ ] **Step 4: `_load_surrogate` 를 재진입 가능하게 만든다**

같은 파일 — `def _load_surrogate():` 한 줄을 아래로 **교체**한다:

```python
def _load_surrogate(path=None):
    """라벨 파일을 읽어 배포 SurrogateV2 를 적합하고 `_state` 를 갱신한다.

    `path` (2026-08-28, V3 Task 6): 주면 **그 파일로** 적합하고 모듈 전역 `SURRO_DATA` 를
    그 값으로 갱신한다. 안 주면 현재 `SURRO_DATA`. 예전에는 인자가 없어서 startup 이후에
    다른 라벨셋으로 갈아 끼울 방법이 uvicorn 재시작뿐이었다 — 그러면 "같은 서비스에서
    경계가 움직였다" 를 관측할 수 없다(다른 프로세스가 다르게 뜬 것과 구분이 안 된다).
    """
    global SURRO_DATA
    if path is not None:
        SURRO_DATA = path
```

그리고 같은 함수의 `except` 절에서 실패 시 상태를 **명시적으로 지운다.** `_state.update(surrogate=model, ...)` 를 하는 `try` 블록의 `except` 안, 기존 오류 기록 줄들 **뒤**에 추가:

```python
        # 🔴 못 읽었으면 낡은 모델로 계속 답하지 않는다. `surro_support = None` 은
        #    "못 쟀다" 이고 `[]` 는 "아무 팔도 지원 안 한다" — 다른 사건이다(V1 Task 4).
        #    이 줄이 없으면 실패한 재적재 뒤에도 이전 라벨셋의 지원집합이 살아남아,
        #    "재적재했다" 는 주장이 조용히 거짓이 된다.
        _state["surrogate"] = None
        _state["surro_support"] = None
```

- [ ] **Step 5: `POST /reload` 를 만든다**

같은 파일 — `@app.get("/health")` 정의 **바로 앞**에 추가:

```python
class ReloadRequest(BaseModel):
    """재적재 요청. `path` 를 안 주면 현재 `SURRO_DATA` 를 다시 읽는다(라벨 파일이 갱신된 경우)."""
    path: Optional[str] = None


@app.post("/reload")
def reload(req: ReloadRequest):
    """⑤ 재학습 — 라벨 파일을 (다시) 읽어 적합하고 지원집합을 돌려준다.

    🔴 왜 라우트가 필요한가 (설계서 §4 ⑤ 실측): `_load_surrogate()` 의 생산 호출부는
    startup 하나뿐이었고 재적재 엔드포인트가 없었다. 그래서 "재학습" = uvicorn 재시작이고,
    그러면 설계서 §7 R2(*"**같은** 사건이 라벨 추가 전에는 dspy 로, 후에는 surrogate 로
    가는가"*)를 관측할 수 없다 — 프로세스가 바뀌면 "같은 서비스" 가 전제로만 남는다.

    ⚠️ 이 라우트는 **모델을 다시 적합한다**(33~수백 행이라 1초 미만). 스윕 중에 부르면
    그 스윕의 세계가 도중에 갈린다 — 비교 실행 중에는 부르지 말 것.
    """
    _load_surrogate(req.path)
    ok = _state.get("surrogate") is not None
    return {"ok": ok,
            # None 은 "못 쟀다", [] 는 "아무 팔도 지원 안 한다" — 뭉개지 않는다.
            "surro_support": (None if _state.get("surro_support") is None
                              else sorted(_state["surro_support"])),
            "surrogate": _state["surro_data"] or ("ERROR: " + str(_state["surro_error"])),
            "path": SURRO_DATA}
```

- [ ] **Step 6: 테스트가 통과하는지 확인한다**

Run: `.venv/bin/python -m pytest src/respec/llm_service/test_reload_grows_support.py -v --ignore=src/respec/llm_service/test_propose.py`
Expected: PASS — 4 passed

- [ ] **Step 7: 서비스 테스트 전체가 안 깨졌는지 확인한다**

Run: `.venv/bin/python -m pytest src/respec/llm_service/ wm4spacecraft_manufacturing/ -v --ignore=src/respec/llm_service/test_propose.py`
Expected: 전부 PASS

⚠️ `import numpy, sklearn.ensemble` 이 `import dspy` **앞에** 있어야 한다(오늘 기준 `:44` vs `:46`). 이 태스크가 파일 위쪽을 건드리므로 **순서가 유지됐는지 `head -50` 으로 눈으로 확인한다** — 깨면 surrogate 로드가 죽고 레인이 에러 없이 canonical 로 내려앉는다(커밋 `f43ad79` 가 고친 회귀).

- [ ] **Step 8: 커밋 (명시 경로만)**

```bash
git add src/respec/llm_service/dspy_service.py \
        src/respec/llm_service/test_reload_grows_support.py
git commit -m "feat(service): 재적재 경로를 만든다 — 오늘 '재학습' 은 uvicorn 재시작이었다

_load_surrogate 의 생산 호출부는 startup 하나뿐이고 라우트 넷 중 재적재가 없었으며
SURRO_DATA 는 모듈 로드 시점 상수였다. 그러면 R2('같은 사건이 라벨 추가 전에는 dspy 로,
후에는 surrogate 로') 를 관측할 수 없다 — 프로세스가 바뀌면 '같은 서비스' 가 전제로만 남는다.
SURRO_DATA env 오버라이드 + _load_surrogate(path) + POST /reload. 실패한 재적재는 낡은
모델을 남기지 않는다(surro_support=None = '못 쟀다')."
```

---

### Task 7: 🔴 R2 — 같은 사건이 라벨 추가 **전에는 `vocabulary_gap`**, **후에는 surrogate** 로 간다

**왜 (V3 의 완료 판정):** 설계서 §7 R2 가 이 설계 전체의 주장이다:

> *"같은 사건이, 라벨 추가 + 재적재 **전에는** `vocabulary_gap` 으로 dspy 로 가고 **후에는** surrogate 로 가는가. 이것이 이 설계 전체의 주장이다."*

V1 은 축 1 이 **발화할 수 있음**(R1)을 보였지만, 그 음성 대조는 `_state["surro_support"]` 를 **손으로 갈아 끼웠다**. R2 는 다르다 — 지원집합이 **라벨 파일에서, 라벨을 추가해서** 자라야 한다. 그 경로가 `라벨 파일 → load_rows → train_macros 도장 → fit → surro_support → /decide 의 unsupported → policy.jl 의 select_lane` 전부를 지나간다.

🔴 **이 태스크가 초록이 아니면 V3 은 완료가 아니다.** 다른 모든 태스크가 초록이어도 그렇다.

⚠️ **Julia 레인까지 태우지 않는다.** `select_lane` 의 우선순위와 `axis == "vocabulary_gap"` 은 V1 Task 2 의 `tools/monitor/test_lane_select.jl` 이 이미 게이트한다. 이 태스크는 **그 함수의 입력이 라벨 추가로 실제로 뒤집히는가**를 잰다 — 즉 `/decide` 응답의 `unsupported` 가 `["SwapBattery"] → []` 로 바뀌는 것. 두 조각을 합치면 R2 다. 🔴 **그 합성이 관측이 아니라 논증이라는 사실을 §9 에 적는다.**

**Files:**
- Create: `src/respec/llm_service/test_r2_boundary_moves.py`

**Interfaces:**
- Consumes: `dspy_service.reload` · `ReloadRequest` · `_load_surrogate(path)` · `SURRO_DATA` (Task 6) · `dspy_service.decide` · `_unsupported_for` · `health` (V1 Task 4) · `counterfactual_labels.py` 의 `--drop-macro`/`--work` 재개 (Task 4) · `action_registry.train_macros_stamp` (Task 5)
- Produces: 없음 (게이트)

- [ ] **Step 1: R2 의 '전' 라벨셋을 만든다 (🔴 시뮬레이션 없음 — Task 4 의 판을 재개해서 쓴다)**

Task 4 의 `--drop-macro` 손잡이가 이것을 위해 있다. `--work` 를 Task 4 와 **같은 디렉토리**로 주면 `run_board` 의 재개 캐시(`if os.path.exists(rows) and os.path.getsize(rows) > 0: return rows, k`)가 모든 판을 그대로 돌려주므로 **판이 한 개도 다시 안 돈다.**

```bash
cd /home/chahj578/Construction_OODlayer
time .venv/bin/python wm4spacecraft_manufacturing/oracle/counterfactual_labels.py \
    --cases battery,fault --seeds 1,2,3 \
    --work wm4spacecraft_manufacturing/oracle/out/_cf_work \
    --drop-macro 2 \
    --out wm4spacecraft_manufacturing/oracle/out/counterfactual_labels_no_swap.jsonl
```
Expected: `--drop-macro [2]: N행 -> M행`, `train_macros 도장을 다시 찍었다: [0, 1]`, 그리고 **벽시계가 1분 미만**(전부 재개 캐시 히트).

🔴 **벽시계가 수십 분이면 재개가 안 걸린 것이다.** `--work` 경로가 Task 4 와 같은지 확인한다 — 다시 굴리면 HiGHS 재컴파일 잡음 때문에 '전' 과 '후' 가 **다른 세계**가 되고, 그러면 R2 가 재는 것이 "라벨이 늘었다" 가 아니라 "판이 달라졌다" 가 된다.

🔴 **도장이 `[0, 1]` 이 아니면 멈춘다.** `[0]` 이 나오면 반사실 라벨셋에 `Replace` 행이 없다는 뜻이고, 그러면 Task 4 의 판이 제대로 안 돈 것이다.

⚠️ `_cf_work` 를 이미 지웠다면 Task 4 Step 7 을 같은 `--work` 로 다시 돌린 뒤 이 스텝으로 온다. **'전' 과 '후' 는 반드시 같은 판 원자료에서 나와야 한다.**

- [ ] **Step 2: R2 테스트를 쓴다**

`src/respec/llm_service/test_r2_boundary_moves.py`:

```python
"""🔴 R2 — 경계가 **실제로** 움직이는가. 이것이 V3 의 완료 판정이다.

설계서 §7 R2: "같은 사건이, 라벨 추가 + 재적재 **전에는** `vocabulary_gap` 으로 dspy 로 가고
**후에는** surrogate 로 가는가. 이것이 이 설계 전체의 주장이다."

🔴 V1 의 R1 과 무엇이 다른가: V1 은 `_state["surro_support"]` 를 **손으로** 갈아 끼워
축 1 이 발화할 수 있음을 보였다. R2 는 지원집합이 **라벨 파일에서, 라벨을 추가해서** 자란다.
그 경로가 `라벨 파일 -> load_rows -> train_macros 도장 -> fit -> surro_support ->
/decide 의 unsupported` 전부를 지나간다.

⚠️ 이 파일이 재는 것과 안 재는 것:
  · 잰다  — 같은 요청의 `/decide` 응답이 `unsupported: ["SwapBattery"] -> []` 로 뒤집히는 것.
  · 안 잰다 — Julia 의 `select_lane` 이 그 입력으로 레인을 고르는 것. 그것은 V1 Task 2 의
    `tools/monitor/test_lane_select.jl` 이 이미 게이트한다(어휘 미달이 1순위, axis 라벨).
  두 조각을 합쳐야 R2 이고, **그 합성은 관측이 아니라 논증이다.** 계획서 §9 에 적혀 있다.
"""
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import dspy_service as svc  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
OUT = os.path.join(REPO, "wm4spacecraft_manufacturing", "oracle", "out")
BEFORE = os.path.join(OUT, "counterfactual_labels_no_swap.jsonl")   # 지원집합 {0,1}
AFTER = os.path.join(OUT, "counterfactual_labels.jsonl")            # 지원집합 {0,1,2}

MENU = ["NOOP", "Replace", "SwapBattery"]


def _the_same_event():
    """🔴 **같은** 사건이다. 이 함수가 두 번 불리고 그 사이에 라벨만 바뀐다."""
    return svc.MacroRequest(kind="battery", soc=0.08, valid=MENU,
                            nl="Robot R5 has run its battery down and stopped.")


@pytest.fixture
def restore_state():
    saved = (svc.SURRO_DATA, svc._state.get("surro_support"),
             svc._state.get("surrogate"), svc._state.get("surro_data"))
    yield
    svc.SURRO_DATA = saved[0]
    svc._state["surro_support"] = saved[1]
    svc._state["surrogate"] = saved[2]
    svc._state["surro_data"] = saved[3]


def test_both_label_files_exist():
    """이 게이트의 전제. 없으면 Task 4 / Task 7 Step 1 이 안 돈 것이다."""
    assert os.path.exists(BEFORE), BEFORE
    assert os.path.exists(AFTER), AFTER


def test_r2_the_same_event_changes_lanes_after_labels_are_added(restore_state):
    """🔴 **V3 의 완료 판정.** 이 하나가 빨간 채로 V3 을 끝내면 안 된다."""
    req = _the_same_event()

    # ---- 전: SwapBattery 를 가르치는 행이 없다 -> 어휘 미달 -> dspy ---------------------
    before = svc.reload(svc.ReloadRequest(path=BEFORE))
    assert before["ok"] is True
    assert before["surro_support"] == [0, 1], before["surro_support"]
    assert svc._unsupported_for(req, MENU) == ["SwapBattery"]
    out_before = svc.decide(req)
    assert out_before["surrogate"]["unsupported"] == ["SwapBattery"]

    # ---- 라벨 추가 + 재적재 --------------------------------------------------------------
    after = svc.reload(svc.ReloadRequest(path=AFTER))
    assert after["ok"] is True
    assert after["surro_support"] == [0, 1, 2], after["surro_support"]

    # ---- 후: 같은 사건, 같은 메뉴, 이제 어휘 미달이 없다 -> surrogate ---------------------
    assert svc._unsupported_for(req, MENU) == []
    out_after = svc.decide(req)
    assert out_after["surrogate"]["unsupported"] == []
    # 그리고 surrogate 가 실제로 그 팔을 **채점한다** — "미달이 없다" 와 "점수를 낸다" 는
    # 다른 사건이고, 후자가 없으면 surrogate 레인이 빈손으로 이긴 것이 된다.
    assert out_after["surrogate"]["available"] is True
    assert out_after["surrogate"]["chosen"] in MENU

    # ---- 🔴 방향까지 못박는다: 지원집합이 **자랐다**(줄지도, 그대로도 아니다) -------------
    assert set(before["surro_support"]) < set(after["surro_support"])


def test_the_growth_is_carried_by_the_stamp_not_by_a_row_scan(restore_state):
    """🔴 지원집합이 파일의 **선언**에서 온다는 것 — `train_kinds` 의 실패를 반복하지 않는다.

    도장을 손으로 좁히면(행은 그대로 두고) 지원집합이 따라 좁아져야 한다. 사후 유도라면
    행이 그대로이므로 아무 변화가 없다.
    """
    import json
    import tempfile
    with open(AFTER, encoding="utf-8") as fh:
        rows = [json.loads(l) for l in fh if l.strip()]
    for r in rows:
        r["train_macros"] = [0, 1]                    # 행은 macro 2 를 그대로 들고 있다
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False,
                                     encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
        p = fh.name
    try:
        out = svc.reload(svc.ReloadRequest(path=p))
        assert out["ok"] is True
        assert out["surro_support"] == [0, 1]         # 행이 아니라 도장이 답한다
    finally:
        os.unlink(p)


def test_health_reports_the_grown_support(restore_state):
    """감사 창구가 산문이 아니라 목록이어야 한다 — 사람이 경계를 확인할 유일한 자리다."""
    svc.reload(svc.ReloadRequest(path=BEFORE))
    assert svc.health()["surro_support"] == [0, 1]
    svc.reload(svc.ReloadRequest(path=AFTER))
    assert svc.health()["surro_support"] == [0, 1, 2]
```

- [ ] **Step 3: R2 를 돌린다**

Run: `.venv/bin/python -m pytest src/respec/llm_service/test_r2_boundary_moves.py -v --ignore=src/respec/llm_service/test_propose.py`
Expected: PASS — 4 passed

🔴 **`test_r2_the_same_event_changes_lanes_after_labels_are_added` 가 빨간 채로 V3 을 끝내지 않는다.** 실패 모양별 진단:
- `before["surro_support"] != [0, 1]` → Step 1 의 '전' 파일 도장이 잘못 찍혔다.
- `_unsupported_for(...) != ["SwapBattery"]` → V1 Task 4 의 `_unsupported_for` 가 `e1_analyze.MACRO_NAME` 을 통해 이름 → id 를 만든다. 그 사전이 레지스트리와 갈렸는지 본다.
- `out_after["surrogate"]["available"] is not True` → 라벨이 늘었는데 `SurrogateV2.fit` 이 그 팔을 채점 못 한다. `psi(2)` 와 `MACRO_SPECS` 를 확인한다.

- [ ] **Step 4: 🔴 게이트가 **실패할 수 있는지** 확인한다 (음성 대조)**

초록만 보고 끝내지 않는다. 이 레포에는 stdout 에 절대 안 찍히는 문자열을 grep 하던 게이트가 90/90 으로 영원히 PASS 한 전례가 있다. 아래를 **실제로 실행하고 출력을 보고서에 붙인다.**

1. `test_r2_...` 안의 `BEFORE` 를 `AFTER` 로 임시로 바꾸고 돌린다 → **`assert before["surro_support"] == [0, 1]` 에서 빨개져야 한다.** 되돌린다.
2. Task 5 Step 6 의 `support = list(meta["train_macros"])` 를 `support = sorted({int(r["macro"]) for r in rows})` 로 임시로 되돌리고 돌린다 → **`test_the_growth_is_carried_by_the_stamp_not_by_a_row_scan` 이 빨개져야 한다**(다른 셋은 통과한다 — 그게 이 단언이 따로 있는 이유다). 되돌린다.

- [ ] **Step 5: V3 전체 게이트를 돌린다**

```bash
cd /home/chahj578/Construction_OODlayer
.venv/bin/python -m pytest src/respec/llm_service/ wm4spacecraft_manufacturing/ -v \
    --ignore=src/respec/llm_service/test_propose.py
julia +lts --project=. test/train_macros_stamp_smoke.jl
julia +lts --project=. test/smdp_stamp_smoke.jl
julia +lts --project=. tools/monitor/test_lane_select.jl
julia +lts --project=. tools/test_policy_escalation.jl
julia +lts --project=. test/policy_macro_binding.jl
julia +lts --project=. test/route_descriptors_survive.jl
```
Expected: 전부 PASS

- [ ] **Step 6: 커밋 (명시 경로만)**

```bash
git add src/respec/llm_service/test_r2_boundary_moves.py \
        wm4spacecraft_manufacturing/oracle/out/counterfactual_labels_no_swap.jsonl
git commit -m "test(r2): 경계가 실제로 움직이는 것을 end-to-end 로 못박는다

설계서 §7 R2 가 이 설계 전체의 주장이다. V1 의 R1 은 _state[surro_support] 를 손으로
갈아 끼운 음성 대조였고, 여기서는 지원집합이 **라벨 파일에서 라벨을 추가해서** 자란다 —
라벨 파일 -> load_rows -> train_macros 도장 -> fit -> surro_support -> /decide 의 unsupported.
같은 사건, 같은 메뉴, unsupported 가 [SwapBattery] -> [] 로 뒤집힌다.
도장을 손으로 좁히면 행이 그대로여도 지원집합이 좁아진다 — 사후 유도가 아니라는 증거다."
```

---

### Task 8: 축 2 를 **다시 잰다** — 짓지 않는다

**왜:** 2026-08-28 측정은 **오늘의 33행 위에서** R3 FAIL 을 냈고, 그 보고 §7-3 이 재측정 트리거를 명시했다: *"(a) `objective.json` 의 `C_fail`/`generation`, (b) `SurrogateV2` 의 구조, (c) `oracle_dataset.jsonl` 의 행 집합 — 셋 중 하나라도 바뀌면 무효다."* **V3 은 (c) 를 바꾼다.** 그러므로 그 판정을 새 라벨셋 위에서 다시 재야 하고, 도구가 이미 있으므로 비용은 CLI 한 줄(3.5 초)이다.

🔴 **이 태스크는 축 2 를 짓지 않는다.** 계획서 §2 가 적었듯 축 2 의 장애 넷 중 **둘(레지스트리의 `kinds` 필드 · 단일 q 규칙)은 라벨과 무관한 축에 있고**, 하나(잔차 < gap)는 `C_fail` 절벽 때문에 라벨로 못 고칠 가능성이 크다. 이 태스크가 하는 일은 **세 진단을 숫자로 남기는 것**이고, 그래야 다음 사람이 "V3 이 축 2 를 살렸다/못 살렸다" 를 근거로 말할 수 있다.

⚠️ 🔴 **`R4: PASS` 를 인용하지 말 것.** 그 검사는 이 추정기 위에서 **실패할 수 없다**(적대적 잔차 4000 배치 중 α=0.10 외 FAIL 0건). 이 태스크가 기록하는 R4 자리의 숫자는 **주변 coverage 가 아니라 조건부 coverage 의 최솟값**이다.

**Files:**
- Create: `docs/superpowers/reports/2026-08-28-v3-axis2-remeasure.md`
- Create: `wm4spacecraft_manufacturing/surrogate/out/conformal_feasibility_v3.json` (산출물)

**Interfaces:**
- Consumes: `wm4spacecraft_manufacturing/surrogate/conformal_feasibility.py` 의 `--labels`/`--out` (기존) · Task 4 의 `counterfactual_labels.jsonl`
- Produces: 없음 (보고)

- [ ] **Step 1: 도구를 새 라벨셋 위에서 돌린다**

```bash
cd /home/chahj578/Construction_OODlayer
time .venv/bin/python wm4spacecraft_manufacturing/surrogate/conformal_feasibility.py \
    --labels wm4spacecraft_manufacturing/oracle/out/counterfactual_labels.jsonl \
    --out wm4spacecraft_manufacturing/surrogate/out/conformal_feasibility_v3.json
```
Expected: JSON 이 나온다. 🔴 **`n_q_infinite != 0` 인 α 행은 "PASS" 로도 "FAIL" 로도 읽지 않는다** — 그 α 에서는 coverage 를 아예 못 잰 것이다.

- [ ] **Step 2: 세 진단을 직접 계산한다**

```bash
.venv/bin/python - <<'PY'
import collections, json, os, sys
for d in ("wm4spacecraft_manufacturing/surrogate", "wm4spacecraft_manufacturing/core"):
    sys.path.insert(0, os.path.abspath(d))
import numpy as np
from sklearn.model_selection import LeaveOneGroupOut
from eval_surrogate_v2 import load_rows
from surrogate_v2 import SurrogateV2
import objective

P = "wm4spacecraft_manufacturing/oracle/out/counterfactual_labels.jsonl"
rows, meta = load_rows(P)
print("meta =", meta)

# ---- 진단 0: 자유도. 행이 아니라 고유 시뮬레이션 --------------------------------------
fp = lambda r: (r["complete"], r["closed"], r["makespan"], r["energy_J"])
print("행 %d · 고유 시뮬 %d · instance %d"
      % (len(rows), len({fp(r) for r in rows}), len({r["instance"] for r in rows})))

# ---- OOF Ĵ (LeaveOneGroupOut on instance) ----------------------------------------------
groups = np.array([r["instance"] for r in rows])
X = np.zeros((len(rows), 1))          # split() 은 2차원 X 를 기대한다(값은 안 쓴다)
jhat = np.zeros(len(rows))
for tr, te in LeaveOneGroupOut().split(X, groups=groups):
    m = SurrogateV2().fit([rows[i] for i in tr])
    jhat[te] = m.predict_J([rows[i] for i in te])
J = np.array([objective.J_row(r) for r in rows])
res = np.abs(jhat - J)

# ---- 진단 1: 완주 팔이 2개 이상인 사건이 kind 마다 몇 개인가 -----------------------------
by_i = collections.defaultdict(list)
for r in rows:
    by_i[r["instance"]].append(r)
n_comp = {i: sum(1 for r in g if r["complete"]) for i, g in by_i.items()}
kind = {i: g[0]["kind"] for i, g in by_i.items()}
c = collections.Counter((kind[i], n_comp[i] >= 2) for i in by_i)
print("진단1  kind x (완주팔>=2):", dict(c))

# ---- 진단 2: 완주 팔들끼리의 gap 중앙값 vs 완주 행 잔차 중앙값 --------------------------
gaps = []
for i, g in by_i.items():
    v = sorted(jhat[k] for k, r in enumerate(rows) if r["instance"] == i and r["complete"])
    if len(v) >= 2:
        gaps.append(v[1] - v[0])
rc = res[[k for k, r in enumerate(rows) if r["complete"]]]
print("진단2  완주 gap 중앙 %.3f  vs  완주 잔차 중앙 %.3f  -> 비 %.1f배 (오늘 기준선 31.4배)"
      % (np.median(gaps) if gaps else float("nan"), np.median(rc),
         (np.median(rc) / np.median(gaps)) if gaps else float("nan")))

# ---- 진단 3: 🔴 조건부 coverage 의 최솟값 (R4 자리에 들어갈 유일한 정직한 숫자) ---------
#      주변 coverage 를 쓰지 않는다 — 그 검사는 적대적 잔차 4000 배치에서도 FAIL 이 안 났다.
for alpha in (0.05, 0.1, 0.2, 0.3):
    qs = {}
    for i in by_i:
        oth = np.array([res[k] for k, r in enumerate(rows) if r["instance"] != i])
        kk = int(np.ceil((len(oth) + 1) * (1 - alpha)))
        qs[i] = np.sort(oth)[kk - 1] if kk <= len(oth) else float("inf")
    if any(np.isinf(v) for v in qs.values()):
        print("alpha=%.2f  🚫 UNMEASURABLE (q_i = inf 인 instance 있음)" % alpha)
        continue
    cov = {}
    for key in ("macro", "complete"):
        for val in sorted({r[key] for r in rows}):
            idx = [k for k, r in enumerate(rows) if r[key] == val]
            cov["%s=%s" % (key, val)] = float(np.mean(
                [res[k] <= qs[rows[k]["instance"]] for k in idx]))
    worst = min(cov, key=cov.get)
    print("alpha=%.2f  조건부 coverage 최솟값 %.3f (%s)  필요 %.3f   전체: %s"
          % (alpha, cov[worst], worst, 1 - alpha - 0.05,
             {k: round(v, 3) for k, v in sorted(cov.items())}))
PY
```

Expected: 숫자 넷. **어떤 값이 나와도 이 태스크는 성공이다** — 재는 것이 목적이다. 🔴 **다만 그 숫자를 근거로 축 2 를 짓기 시작하지 않는다.** §2-3 의 조건 3·4 가 여전히 라벨 밖에 있다.

- [ ] **Step 3: 재측정 보고를 쓴다**

`docs/superpowers/reports/2026-08-28-v3-axis2-remeasure.md` — 아래 골격을 채운다. **숫자를 비워 두지 않는다.**

```markdown
# V3 라벨셋 위에서 축 2 를 다시 잰다

**날짜:** (실행일)
**대상 라벨셋:** `wm4spacecraft_manufacturing/oracle/out/counterfactual_labels.jsonl`
**대비 기준선:** `docs/superpowers/reports/2026-08-28-conformal-feasibility-measurement.md` (33행 / 18 시뮬)
**재측정한 이유:** 그 보고 §7-3 의 트리거 (c) — 라벨 행 집합이 바뀌었다.
**산출물:** `wm4spacecraft_manufacturing/surrogate/out/conformal_feasibility_v3.json`

## 0. 한 줄 판정
(R3 이 여전히 FAIL 인가 · 격상률이 α 에 따라 움직이는가)

## 1. 자유도 — 행이 아니라 고유 시뮬레이션
| | 기준선 | V3 |
|---|---|---|
| 행 | 33 | |
| 고유 시뮬레이션 | 18 | |
| instance | 12 | |

## 2. 진단 1 — 완주 팔이 2개 이상인 사건 (kind 별)
(기준선: battery 9 / fault 0. **fault 가 0 인 한 격상 집합은 kind 와 정렬된다.**)

## 3. 진단 2 — 완주 gap 중앙 vs 완주 잔차 중앙
(기준선: 2.782 vs 87.3 = **31.4배 틀림**. 1.0 미만이어야 축 2 가 봉우리 안을 가른다.)

## 4. 진단 3 — 🔴 조건부 coverage 의 최솟값
(기준선: `macro` 축·`complete` 축에서 **0.000**. 🔴 주변 coverage 는 적지 않는다 — 그 검사는
적대적 잔차 4000 배치에서도 FAIL 이 0건이라 아무것도 못 가린다.)

## 5. 🔴 이 재측정이 못 말하는 것
- 축 2 의 장애 넷 중 **둘은 라벨 밖에 있다**: 레지스트리의 `"kinds": ["battery"]` 가 팔 메뉴를
  kind 로 결정하는 것, 그리고 단일 α·단일 q 가 팔에 무관한 구간 폭을 강제하는 것.
  이 라벨셋이 아무리 커져도 그 둘은 안 움직인다.
- `no_arms`/`single_arm` 퇴화 분기는 **여전히 미시험**이다 (사건마다 팔이 2~3개).
- 이 측정은 `objective.json` `generation` / `SurrogateV2` 구조 / 이 라벨 파일에 매인다.

## 6. 그래서 다음은
(축 2 를 지을 근거가 생겼는가 / 안 생겼다면 무엇이 먼저인가)
```

- [ ] **Step 4: 커밋 (명시 경로만)**

```bash
git add docs/superpowers/reports/2026-08-28-v3-axis2-remeasure.md \
        wm4spacecraft_manufacturing/surrogate/out/conformal_feasibility_v3.json
git commit -m "measure(axis2): V3 라벨셋 위에서 축 2 실현가능성을 다시 잰다 (짓지 않는다)

기준선 보고 §7-3 의 재측정 트리거 (c)(라벨 행 집합 변경)가 걸렸다. R4 자리에 주변 coverage 를
안 적는다 — 그 검사는 적대적 잔차 4000 배치에서 FAIL 0건이라 아무것도 못 가린다. 대신
조건부 coverage 의 최솟값을 적는다(기준선 0.000). 축 2 의 장애 넷 중 둘(레지스트리 kinds ·
단일 q)은 라벨 밖에 있으므로 이 숫자가 좋아져도 그것만으로 축 2 를 짓지 않는다."
```

---

## Plan V3 완료 시 측정 가능한 것

| 신호 | 어디서 | 무엇을 말하나 |
|---|---|---|
| 🔴 **R2** | `test_r2_boundary_moves.py` | **경계가 실제로 움직인다.** 같은 사건의 `unsupported` 가 `["SwapBattery"] → []` 로 뒤집힌다. V3 의 완료 판정 |
| `/health` · `POST /reload` 의 `surro_support` | 서비스 | 지금 이 모델이 무엇을 배웠는가 — **감사 가능한 목록으로**, 그리고 재적재 후에도 |
| `meta["train_macros"]` | `load_rows` | 라벨 파일의 **선언**. 사후 유도값과 갈리면 파일이 거짓말하는 것 |
| export artifact 의 `meta.train_macros` | `surrogate_linear.json` | 🔴 설계서 §4 의 *"디스크의 어떤 산출물도 지원 매크로를 안 적는다"* 가 닫혔다 |
| `events_with_ge2_distinct / events` | 생산자 로그 | 🔴 **정보가 실제로 늘었는가.** 행 수가 아니라 이 비율이 헤드라인이다 |
| `distinct_sims / rows` | 생산자 로그 | 자유도의 과대평가 정도 (기준선: 18/33) |
| 진단 1·2·3 | Task 8 보고 | 축 2 를 지을 근거가 생겼는가 — **세 숫자 전부** |
| `_fitted_c` | Task 4 Step 8 | 반사실 판이 전부 완주하면 `predict_J` 의 미완주 분기가 통째로 0 이 된다 |

## 🔴 알려진 미결 — Plan V3 이 **안** 푸는 것

- 🔴 **축 2 는 여전히 안 산다 — 그리고 라벨로 못 고치는 부분이 있다.** 장애 넷 중 (3) 레지스트리의 `"kinds": ["battery"]` 가 팔 메뉴를 kind 로 결정하는 것과 (4) 단일 α·단일 q 가 팔에 무관한 구간 폭을 강제하는 것은 **라벨셋 밖의 축**이다. Task 8 이 그 사실을 숫자와 함께 남긴다.
- 🔴 **`no_arms` / `single_arm` 퇴화 분기는 미측정으로 남는다.** 축 2 규칙의 절반이 한 번도 발화한 적이 없다.
- 🔴 **R2 의 마지막 한 칸은 논증이다.** 이 계획은 `/decide` 의 `unsupported` 가 뒤집히는 것을 관측하고, `select_lane` 이 그 입력으로 레인을 고르는 것은 V1 의 `test_lane_select.jl` 이 게이트한다. **두 조각의 합성을 한 프로세스에서 관측하지는 않았다.** 그것을 재려면 라벨 두 벌로 판을 각각 굴려 결정 행의 `router_axis` 분포를 비교해야 하고, 판 실행이 필요해 이 계획에서 뺐다. **"R2 를 end-to-end 로 관측했다" 고 적지 말 것** — 적을 수 있는 것은 *"라벨 추가가 라우팅 입력을 뒤집는 것을 관측했고, 그 입력에서 레인이 나오는 것은 별도 게이트가 지킨다"* 다.
- **어휘 자체는 안 자란다.** 매크로 주조(`vocab` 등가성 벽 · 6~7파일 수작업 · `macro_to_proposal` 을 빠뜨리면 조용히 빈 제안)는 다음 계획이다. V3 은 **어휘 안에서** 경계를 움직인다.
- **`train_kinds` 는 여전히 읽는 곳이 0곳이다.** 이 계획은 `train_macros` 에만 소비처를 만들었다. `train_kinds` 를 같이 배선하면 zone 을 뺀 라벨셋과 안 뺀 라벨셋을 기계가 구분하게 되지만, 그 게이트의 의미(어떤 kind 를 거부할 것인가)가 정해지지 않았다.
- **`sample_grid.py` 의 DP 소비 측을 안 되살렸다.** `dp_solve.py` · `boards.jsonl` · `_sample_work` 는 그대로 삭제 상태다. `rows_to_samples` 의 격자 경로(`load_grid` 에 `objective_hash` 대조가 **없다**)도 그대로다 — V3 의 라벨 경로는 그 함수를 우회한다.
- **`--jobs 24` 가 판을 갈리게 하는지는 여전히 UNVERIFIED 다.** 이 계획은 순차만 쓰므로 재지 않았다. 재려면 같은 `(case, seed, arm)` 을 `--jobs 1`/`--jobs 24` 로 굴려 `rows.jsonl` 을 바이트 대조해야 한다.
- **`run_demo.jl` 집행 사슬 누락을 잡는 게이트가 없다.** `grep -rn enact_applied test/` 가 0건이다. 새 팔을 더할 때 그 자리를 빠뜨리면 잡히지 않는다 — 매크로 주조 계획이 다뤄야 한다.
- **`src/safety/novelty.jl` 을 안 지운다.** 삭제 순서는 설계서 §6.

---

## 부록 — 이 계획서가 설계서를 정정하는 자리

| 설계서 | 실측 | 이 계획서의 처리 |
|---|---|---|
| §4 *"반사실 라벨 생산자가 없다"* | **`dp_oracle/sample_grid.py`(1331줄, 자칭 "반사실 표집기")가 git HEAD 에 있다.** 작업 트리에서만 삭제 | Task 1 이 **복원하고 모양을 바꾼다.** 맨땅에서 안 짓는다 |
| §4 는 ④ 를 "라벨 행을 만드는 일" 로만 본다 | `pick_k` 가 반사실 지점을 **crc32 해시**로 고른다 — OOD 사건과 무관 | Task 2 가 `at`(사건 index)을 만든다. 열을 더 낸다고 안 풀리는 유일한 항목 |
| §8 의 "매크로 하나 추가 = 6파일" | `sample_grid.py` 의 `ENACTABLE_NAMES` 가 **7번째**다(은퇴 이름 4개를 리터럴로, 새 팔은 조용히 탈락) | Task 1 이 레지스트리 파생으로 바꿔 그 파일을 목록에서 **뺀다** |
| §5 는 도장 검사를 언어 중립처럼 다룬다 | 🔴 `require_vocab_stamps` 의 **Julia 판이 없다** | Task 5 가 `require_train_macros_stamps` 를 **양쪽에** 만든다 |
| §5 의 두 도장 표 | `vocab` 은 팔 수를 인코딩하므로(`v4-3arms` + `assert_vocab_arm_count`) **동등을 유지하는 한 성장은 여전히 처벌된다** | §3 이 그 사실을 적고, V3 은 **어휘 안에서** 경계를 움직여 그 벽을 우회한다 |
| §2-3 *"미등록 id 는 조용히 NOOP"* · §8 *"주조 전에 반드시 필요하다"* | **이미 고쳐졌다**(V1 Task 1, `psi(99) → KeyError`) | §1 이 그 사실을 적고 **다시 안 짓는다** |
| 부록 *"`require_vocab` 은 6곳이 쓴다"* | 생산 **3곳** + 테스트 **4파일** | §3 의 표가 3곳 각각을 다룬다 |
| §7 R3/R4 | R3 **FAIL**(격상률이 α 에 대해 상수) · R4 는 **실패할 수 없는 검사**이고 조건부 coverage 는 **0.000**(= 반증됨) | §2 가 라벨셋에 대한 요구로 번역하고, Task 8 이 다시 잰다 |
| §4 결정 행 = `run_demo.jl:281-345` | 오늘 기준 `:290`~`:371` (+`:492`·`:496`). **앵커는 `local this_decision = Dict(`** | Global Constraints 가 앵커 인용을 규약으로 못박는다 |
