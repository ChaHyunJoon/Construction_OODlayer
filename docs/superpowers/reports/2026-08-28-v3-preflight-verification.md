# V3 계획서 실행 전 검증 — 반증 보고

**대상:** `docs/superpowers/plans/2026-08-28-closed-loop-counterfactual-labels-v3.md` (커밋 `e54dd94a`, 8 태스크, 2698줄)
**날짜:** 2026-08-28
**방법:** 모든 `file:line`·앵커를 직접 열었고, 숫자는 원자료에서 다시 유도했고, 하중 큰 주장은 **실행해서** 쟀다.
**규약:** 레포 파일을 하나도 안 고쳤다. 작업 트리에 아무것도 복원하지 않았다(219건 삭제 그대로).
레지스트리 변형 실험은 `ACTION_REGISTRY` 로 스크래치패드 사본을 물렸다.

> 🔴 **한 줄 판정: 계획서의 사실 인용은 대부분 정확하지만, 완료 판정(Task 7 R2)이
> 존재하지 않는 응답 키를 단언한다. 지금 이대로 실행하면 V3 은 완료될 수 없다.**

---

## 0. 판정 표

| # | 주장 | 판정 | 근거 |
|---|---|---|---|
| P1-a | `vocab` 도장이 매크로 주조를 막고 기존 라벨 전량을 무효화한다 | **CONFIRMED** | §1 |
| P1-b | 재정의된 R2(어휘 안 지원집합 성장)가 설계서 §7 R2 의 정당한 사례다 | **부분 CONFIRMED — 더 약하다** | §2 |
| P1-c | 지원집합 축소 기전이 건전하고 surrogate 가 학습 가능하다 | **기전은 CONFIRMED · 게이트는 REFUTED** | §3 |
| R-1 | `out_after["surrogate"]["available"] is True` | 🔴 **REFUTED (측정)** | §3-1 |
| R-2 | `pytest wm4…/ src/respec/llm_service/` → "전부 PASS" | 🔴 **REFUTED (측정: 3 failed / 114 passed)** | §4-1 |
| R-3 | `label_seconds` 중앙값 판당 ~76 s → 순차 ~85분 | 🔴 **REFUTED (중앙값 9.009 s, 76.231 은 최댓값)** | §4-2 |
| R-4 | Task 4 Step 4 "13 passed" · Step 6 "23 passed" | 🔴 **REFUTED (18 / 28)** | §4-3 |
| R-5 | 두 픽스처 헬퍼 이름이 다르다 | 🔴 **REFUTED (둘 다 `_row(vocab, **kw)`)** | §4-4 |
| R-6 | 미완주 판의 makespan 은 Inf 다 | 🔴 **REFUTED (이 레인은 유한한 실현시간)** | §4-5 |
| R-7 | `Ĵ` 가 더 정확해져도 축 2 는 안 산다 (§2-1) | 🔴 **REFUTED (출처 보고와 충돌)** | §4-6 |
| R-8 | 유한한 2q 의 도달 범위 `[44.382, 15170.903]` | ⚠️ **한정어 누락** ( 전체는 `[26.353, …]` ) | §4-7 |
| R-9 | export dict 의 `"kinds"` 줄 뒤에 넣는다 | ⚠️ **그 줄이 2곳이다** (`:392`·`:442`) | §4-8 |
| C-1 | Task 4 ↔ Task 5: `REQUIRED_LABEL_COLUMNS` 충돌 | 🔴 **내부 모순 (테스트 2건 파손)** | §5-1 |
| C-2 | Task 6: 실패한 재적재 테스트 | 🔴 **내부 모순 (통과 불가)** | §5-2 |
| C-3 | `train_macros` 도장과 소비처가 같은 태스크(Task 5)인가 | ✅ **CONFIRMED — Python 쪽은 제대로 됐다** | §5-3 |
| C-4 | Julia `require_train_macros_stamps` 의 소비처 | 🔴 **0곳 — `train_kinds` 와 같은 모양** | §5-3 |
| C-5 | 프로브 판 ↔ 반사실 판의 **사건 동일성** 게이트 | ⚠️ **없다. "구성상 지켜진다" 는 논증이 틀렸다** | §5-4 |
| P4-1 | `boards.jsonl` 을 복원 목록에서 뺀다 | ✅ **CONFIRMED (옳다)** | §6-1 |
| P4-2 | "6파일이 아니라 7" · Task 1 이 목록에서 뺀다 | ✅ **7 CONFIRMED · 제거는 부분 성취** | §6-2 |
| P4-3 | Task 8 이 주변 coverage 대신 조건부 최솟값을 쓴다 | ✅ **건전하다 (단 퇴화 경우 미규정)** | §6-3 |
| P4-4 | 축 2 장애 넷 중 둘이 라벨 밖 · 하나는 `C_fail` 절벽 | ✅ **대체로 충실 (R-7 만 과장)** | §6-4 |
| P5 | §9 의 세 한계 고백이 완전한가 | ⚠️ **정직하지만 불완전 — 일곱 개가 더 있다** | §7 |

---

## 1. PRIORITY 1 — `vocab` 벽은 실재한다 (CONFIRMED)

**반증 관측이 되었을 것:** 매크로를 하나 더해도 `vocab` 문자열을 안 바꾼 채 import 가 통과하거나,
`vocab` 을 올린 뒤에도 기존 라벨이 배포 적재를 통과하는 것.

**측정 (2단계 음성 대조, 스크래치패드 레지스트리 사본):**

```
(a) 4팔 + vocab 그대로:
ValueError: vocab 도장이 거짓말한다 -- 선언 3 arms('v4-3arms') vs 실제(은퇴 제외) registry 4 arms.
(b) vocab 을 v5-4arms 로 올린 뒤:
require_vocab_stamps -> oracle_dataset.jsonl: 어휘 도장 불일치 -- 파일 ['v4-3arms'] vs 현행 'v5-4arms'.
```

`assert_vocab_arm_count` 는 `action_registry.py:102` 에서 **import 시점**에 돈다(`:85` 정의).
`n_non_retired` 는 `experimental` 게이트를 안 보므로 **실험 팔로 추가해도 같은 벽**이다.
`"retired": true` 로 넣으면 카운트는 피하지만 `is_active` 가 false 라 팔이 아니다. **우회로가 없다.**
`train_macros` 는 검사가 **추가**되는 것이지 `require_vocab_stamps` 를 대체하지 않으므로 벽은 그대로다.

→ **계획서 §3 의 논증은 참이다.**

---

## 2. PRIORITY 1 — 재정의된 R2 는 정당하지만 **엄밀히 더 약하다**

**설계서 §7 R2 원문은 "라벨 추가 + 재적재 전/후" 이고 매크로 주조를 요구하지 않는다.**
그리고 §4 의 폐루프 ④ 는 문자 그대로 *"안 고른 팔들의 반사실 rollout → 라벨 행"* 이다.
그러므로 **어휘 안에서 지원집합을 키우는 것은 R2 의 문언에 부합한다.** 여기까지는 계획서가 옳다.

**그런데 세 가지가 약해진다 — 계획서가 §9 에 안 적은 것 둘이 여기 있다.**

1. 🔴 **'전' 상태가 관측이 아니라 뺄셈이다.** `--drop-macro 2` 는 **같은 실행이 이미 만든**
   macro 2 행을 지워서 만든다. 시스템 안에 ①(격상)→②(LLM)→③(기록)→④(반사실) 의 방아쇠가
   없다 — 라벨은 전부 한 번에 생산되고 그다음 일부를 뺀다. 즉 관측되는 것은 **⑤→⑥ 뿐**이고,
   라벨 델타는 손으로 만든다. 설계서 R1 이 정확히 *"지원집합에서 매크로 하나를 뺀 라벨셋으로
   서비스를 띄우면"* 이므로, 계획서 R2 = **R1 + 같은 프로세스 재적재 + 도장이 진실원**이다.
   R1 보다는 크고 폐루프보다는 작다. **§9 에 이 사실이 없다.**
2. 🔴 **주조 경로의 기계를 하나도 안 태운다.** 계획서 R2 의 `SwapBattery` 는 `KIND_VALID` ·
   `enactable_macros()` · `MACRO_SPECS` · `psi()` · `macro_to_proposal` · `run_demo.jl` 집행 사슬 ·
   `ood_mdp_shim.action_to_proposal` · `reference_policy` **전부에 이미 있다.** 진짜 새 팔이
   지나야 하는 6~7 자리 중 **0개**를 지난다. 설계서 §1 의 논거(*"새로 주조된 매크로는 정의상
   지원집합 밖이고 학습되는 순간 정의상 안"*)는 이 시험으로 검증되지 않는다.
   (계획서 §9 의 *"어휘 자체는 안 자란다"* 가 이것을 절반 적는다.)
3. ⚠️ 마지막 합성(`unsupported` 뒤집힘 × `select_lane`)이 논증이라는 것 — 이것만은 §9 가 정직하게 적는다.

**결론:** 정당한 R2 의 *부분집합*이다. "경계가 어휘 안에서 움직인다" 는 보인다.
"새 행동이 known 이 된다" 는 **안 보인다.** 완료 판정으로 쓰되 그 차이를 보고서에 적어야 한다.

---

## 3. PRIORITY 1 — 축소 기전은 건전, **게이트는 통과 불가**

### 3-1. 🔴 REFUTED (측정): `decide()` 응답에 `available` 키가 없다

계획서 Task 7 Step 2 의 R2 테스트:

```python
assert out_after["surrogate"]["available"] is True
```

`dspy_service.decide()` 가 만드는 `out["surrogate"]` 는 두 분기 모두 리터럴 dict 이고
`available` 이 없다. `available` 은 **Julia 쪽**(`policy.jl:1039`·`:1054`)이 붙이는 키다.
`grep -n 'available' src/respec/llm_service/dspy_service.py` → 매치는 `:709` **주석 한 줄뿐**.

실행 측정(`.venv/bin/python`, 서비스 미기동, LLM 호출 0회):

```
out['surrogate'] KEYS: ['chosen', 'error', 'margin', 'policy', 'ranking', 'scores', 'unsupported']
has 'available'? -> False
unsupported(before): ['SwapBattery']
unsupported(after): []  chosen: SwapBattery
KeyError on ['available'] -> KeyError('available')
health surro_support: [0, 1, 2]
llm calls made: 0
```

**음성 대조:** 같은 스크립트에서 `_state["surro_support"]` 를 `{0,1}` → `{0,1,2}` 로 바꾸니
`unsupported` 가 `["SwapBattery"] → []` 로 실제로 뒤집혔다. 즉 **R2 의 핵심 기전은 작동하고,
오직 `available` 단언만 틀렸다.** 이 한 줄이 계획서 자신이 *"이 하나가 빨간 채로 V3 을 끝내면
안 된다"* 고 못박은 그 테스트다.

**고칠 방향(구현자에게):** 이 값은 응답의 **구조**에서 유도해야 한다 — `policy.jl:997` 이
이미 그 규약을 적는다(*"`available == true` ⟹ 점수를 냈다"*). 파이썬 쪽 등가물은
`out_after["surrogate"]["ranking"] != []` 또는 `["scores"] != {}` 다.

### 3-2. 지원집합 `{0,1}` 축소는 학습 가능하다 (CONFIRMED)

```
macro!=2 subset: 24 rows  complete: 18
fit on {0,1} OK; _fitted_b True _fitted_c True
```

### 3-3. 🔴 그러나 **모든 판이 완주하면 surrogate 가 상수가 된다** — 계획서가 오독한 자리

계획서 Task 4 Step 8 은 *"`_fitted_c == False` 가 나오면 … 그 자체가 실패는 아니지만"* 이라고
적고, §2-3 은 1-step deviation 의 완주율이 높다고 **스스로 예고한다.** 실제로 재 보면:

```
all-complete subset: 27 rows
fit OK; _fitted_b True _fitted_c False
head_a.classes_ = [1]
predict_proba shape = (27, 2)   first row = [1.0, 2.22e-15]
predict_complete_proba[:5] = [2.22e-15 …]          ← P(완주) ≈ 0
predict_J: min 10000.020  max 10000.028  (27행에 걸친 폭 0.008)
```

기전: `HistGradientBoostingClassifier` 는 단일 클래스에서 **(n,2)** proba 를 내므로
`surrogate_v2.py` 의 `p.shape[1] == 2 ? p[:,1] : …` 가드가 퇴화 경우를 **못 잡는다.**
귀결: 완주 데이터로만 적합한 모델이 모든 행에 P(완주)≈0 을 주고 `predict_J ≈ C_fail` 로 붕괴한다.
**팔 순위가 사라진다.** Task 7 의 `chosen in MENU` 는 그래도 통과하고(=아무것도 못 가리는 단언),
Task 8 의 잔차·gap 진단은 그 위에서 계산된다.

→ **"그 자체가 실패는 아니다" 는 틀렸다.** `_fitted_c == False` 는 **정지 조건**이어야 한다.

---

## 4. PRIORITY 2 — 개별 사실 주장

먼저, **확인된 것**(전부 직접 열거나 실행함): `sample_grid.py` 1331줄·자칭 "반사실 표집기" ·
`ENACTABLE_NAMES` `:249-250` 의 은퇴 이름 4개 · `:381` 의 낡은 `WM/llm_ood_eval.py` 경로 ·
`run_board` 의 `return None, k` · `pick_k` crc32 · `DEFAULT_N_HINT=8` · `CASES` 7종 ·
`regen_d20.sh:50` 이 이미 `sweep/` 을 씀 · `run_demo.jl:290` `local this_decision = Dict(` ·
`:320` `"spare_count"` · 결정 행에 `n_active` **없음** · `"soc"` 는 있고 fault 에서 `nothing` ·
`policy.jl:895` `DS_DEVIATE_AT=0 → error()` · `:1320` `didx` 는 deviation OFF 에서도 센다 ·
`:1352` `deviate_valid = isempty(_vm) || …` · `:1125` `DEMO_ALL_POLICIES` 분기(원문 일치) ·
`features_agnostic` `n_active` 기본 1.0 · psi KeyError 가드 + `test_psi_unknown_macro.py` ·
`surrogate_v2.py:93`/`:99` 조건부 분기 · `_c_fallback = 0.0` · `load_rows` meta **7키** ·
`require_vocab` 생산 소비처 **3곳** · Julia `require_vocab_stamps` **무매치** ·
`train_kinds` write 4곳(`:1949`·`:1989`·`:2164`·`:2228`, 들여쓰기 17/41/17/21 — "1989·2228 이
더 깊다" 도 맞다) · read 0곳 · `gen_oracle_dataset.jl:126` `MACROS = active_ids()` ·
`runtests.jl` 의 `@testset "SMDP stamps"` 블록 · `dspy_service` 의 `:241`·`:266`·`:281`·`:331`·
`:694`·`:717`·`:750` 전부 정확 · `boards.py` board_id 규약 · `valid_mask` = **매크로 id 목록**
(fault `[0,1]`, battery `[0,1,2]` — `KIND_VALID` 와 일치) · `objective_hash 489268e6659e5ae9` ·
`conformal_feasibility.py --labels/--out` · `--events` 기본 4 · 판 66개 산수(6+36+24).

**축 2 숫자도 전부 재유도했다:** 33행 → **18 고유 시뮬**(macro0 12/12 · macro1 12→3 ·
macro2 9→3, 정확히 계획서 §2-4 의 분해) · 완주 팔 ≥2 인 instance = **battery 9 / fault 0** ·
gap 중앙 2.782 vs 완주 잔차 중앙 87.3 = **31.4배** · 빈 구간 `(30.963, 17304.157)` ·
94.1% · 격상률 `{1.000, 0.750, 0.667}` · 적대적 4000 배치에서 α=0.10 만 FAIL ·
α=0.2 에서 주변 0.818 PASS / 미완주 0.000 / macro0 0.500. **그리고 R4 를 "실패할 수 없는 검사"
로만 인용하고 "교환가능성 통과" 로 쓴 자리가 계획서에 하나도 없다 — 표본수도 33행이 아니라
18 고유 시뮬로 말한다.** 이 두 가지는 계획서가 잘한 것이다.

### 4-1. 🔴 "전부 PASS" 는 오늘 거짓이다

```
$ .venv/bin/python -m pytest wm4spacecraft_manufacturing/ src/respec/llm_service/ -q \
      --ignore=src/respec/llm_service/test_propose.py
3 failed, 114 passed, 2 warnings in 56.07s
FAILED wm4spacecraft_manufacturing/smdp/test_gate_ng2.py::test_healthy_agreement_passes
FAILED …::test_healthy_disagreement_fails
FAILED …::test_spread_over_3_is_reported_but_is_not_the_verdict
E   FAIL: 사건 0 의 팔 id 3 가 현행 어휘(v4-3arms)의 활성 팔이 아니다
```

기존 결함이고 V3 과 무관하다(픽스처가 은퇴한 macro id 3 을 쓴다). 그런데 계획서는
**Task 5 Step 11 · Task 6 Step 7 · Task 7 Step 5 세 곳에서 "전부 PASS"** 를 수락 기준으로 적는다.
`Pkg.test()` 의 "11 pass / 1 error 는 회귀가 아니다" 처럼 **이 3건도 기준선으로 명시해야 한다.**
안 그러면 구현자가 유령 회귀를 쫓거나, 더 나쁘게는 무관한 코드를 "고친다".

### 4-2. 🔴 `label_seconds` 중앙값은 9.009 s 다

```
label_seconds  sum 756.3  median 9.009  min 7.535  max 76.231  n=33
```

**76.231 은 최댓값이다.** 계획서 Task 4 Step 7 의 *"중앙값이 판당 ~76 s 이므로 순차 ~85분"* 은
최댓값을 중앙값으로 읽은 것이다. 게다가 **단위가 다르다** — `label_seconds` 는
`gen_oracle_dataset.jl` 레인의 **라벨 행당** 시간이고, V3 의 판은 `llm_ood_eval.py` →
`run_demo.jl` 레인이다. 방향은 보수적(과대추정)이라 위험하진 않지만 **인용은 거짓이다.**

### 4-3. 🔴 테스트 개수 둘이 틀렸다

`@pytest.mark.parametrize("col", [… 6개])` 는 pytest 에서 **6 항목**으로 센다.
Task 4 가 더하는 것은 함수 8개 = **항목 13개**, 파일 누계 **18** (계획서 "13 passed").
Task 4 Step 6 의 두 파일 합은 **28** (계획서 "23 passed"). 다른 카운트(6·10·5·8·4·4)는 맞다.

### 4-4. 🔴 "두 파일의 픽스처 헬퍼 이름이 다르다" 는 거짓

`test_load_rows_vocab.py:20` 과 `test_export_surrogate_vocab.py:26` 은 **둘 다** `def _row(vocab, **kw):` 다.
다른 것은 **내용**이다 (전자는 `valid_mask` 를 갖고 `closed`/`makespan` 이 없다, 후자는 반대).

### 4-5. 🔴 "미완주 판의 makespan 은 Inf 다" — 이 레인에서는 아니다

`tools/monitor/run_demo.jl` 요약은 `"makespan" => (try CB.sim_time(env.dt) catch; nothing end)` 다.
**미완주 판에서도 유한한 실현 시간**이다(`Inf` 가 아니다). `"Inf"` 문자열은
`gen_oracle_dataset.jl` 레인의 관용구이고 오늘의 33행이 그 세대다.

귀결 둘: (1) `test_infinite_makespan_survives_the_json_round_trip` 은 이 생산자가 **절대 못 내는
경우**를 시험한다(무해하지만 근거 문장이 거짓). (2) 🔴 **V3 라벨셋의 미완주 행 makespan 은
기준선 33행과 의미가 다르다.** Task 8 이 두 세대를 나란히 비교하므로 이 사실을 보고에 적어야 한다.
(`makespan` 이 `nothing` → `null` 로 나올 수 있고 그때는 `assert_label_schema` 가 죽는다 — 그건 설계대로다.)

### 4-6. 🔴 "`Ĵ` 가 더 정확해져도 축 2 는 안 산다. 정확도의 병이 아니다" 는 출처와 충돌한다

측정 보고 §7 의 장애 2번 원문: *"`Ĵ` 가 지금보다 **최소 한 자릿수 정확해지지 않으면** 어떤 α 도
봉우리 안을 가르지 못한다."* 그리고 §4-2: *"봉우리 안 간격 ≈ 1.4~31 — 어떤 α 로도 못 넓힌다
(**최소 2q = 26.4**)."* 그 26.4 는 **잔차 분포의 하한**(최소 잔차 13.176)에서 나온다 —
즉 잔차가 한 자릿수 줄면 2q 하한이 2.841 아래로 내려가 봉우리 안 gap 을 실제로 가른다.
보고서가 *"정확도의 병이 아니다"* 라고 쓴 것은 **장애 4번(조건부 coverage)** 에 대해서다.
계획서는 그 문장을 이봉성 논증 뒤에 붙여 R3 전체로 확장했다. **과장이다.**
(§2-3 표의 2번 항목은 *"…아닐 수 있다"* 로 정직하게 완화돼 있다 — §2-1 의 단정만 고치면 된다.)

### 4-7. ⚠️ `[44.382, 15170.903]` 에 한정어가 빠졌다

측정 보고 `:128-129` 는 **"α 격자 전체에서 유한한 2q"** 를 `[26.353, 15170.903]` 으로,
**"측정 가능하고 공허하지 않은"** 것을 `[44.382, 15170.903]` 으로 구분한다.
26.353 < 30.963 이므로 **전자는 빈 구간 안에 안 들어간다.** 계획서 §2-1 은 후자의 숫자를 쓰면서
전자의 이름("유한한 2q 의 도달 범위")을 붙였다. 숫자는 맞고 라벨이 틀렸다.

### 4-8. ⚠️ export dict 의 `"kinds"` 줄은 **2곳**이다

```
export_surrogate.py:392   "kinds": …   ← meta_common (USE_FOREST 경로)
export_surrogate.py:442   "kinds": …   ← spec["meta"] (선형 경로)
```

Task 5 Step 7 은 *"`main()` 의 export dict 안 … 줄 **바로 뒤**"* 라고 단수로 적는다.
한쪽만 넣으면 나머지 export 가 **조용히 도장 없이** 나간다 — 이 파일이 이미 한 번 당한 실패다
(`:255` 주석). 계획서의 완료 표는 `surrogate_linear.json` 을 가리키므로 `:442` 를 뜻하는 듯하지만
**둘 다 넣어야 한다.**

---

## 5. PRIORITY 3 — 태스크 간 모순

### 5-1. 🔴 Task 4 ↔ Task 5: `REQUIRED_LABEL_COLUMNS` 가 갈린다 (테스트 2건 파손)

Task 5 Step 8 은 `_LOAD_COLUMNS` 에 `"train_macros"` 를 넣어 `REQUIRED_LABEL_COLUMNS` 를 키우고,
`fold_board_to_label_row` 는 `skip=("train_macros",)` 로 그것을 피한다. **그런데 Task 4 의 테스트
둘이 `skip` 을 안 쓰고 같은 상수를 직접 읽는다:**

```python
# Task 4 테스트 ①
def test_the_label_row_has_every_column_fit_needs():
    row = cf.fold_board_to_label_row(...)
    for col in cf.REQUIRED_LABEL_COLUMNS:
        assert col in row, col            # ← "train_macros" 가 row 에 없다 → FAIL

# Task 4 테스트 ②
def test_the_schema_gate_does_not_depend_on_whether_the_board_completed():
    row = cf.fold_board_to_label_row(...)
    cf.assert_label_schema(row, "ok")     # ← skip=() 기본값 → ValueError → FAIL
```

계획서의 Task 5 Interfaces 는 *"Task 4 의 `fold_board_to_label_row` 가 **유일한 호출자**이고
같은 스텝에서 같이 고친다"* 라고 적는데 **거짓이다** — 테스트도 호출자다.
두 건 모두 Task 5 Step 11 의 "전부 PASS" 에서 빨개진다.

### 5-2. 🔴 Task 6: `test_a_failed_reload_does_not_silently_keep_the_old_model` 은 통과할 수 없다

두 가지가 겹친다.

**(가) 실패 경로가 `surro_data` 를 안 지운다.** 계획서 Step 4 는 `except` 에
`_state["surrogate"] = None` · `_state["surro_support"] = None` 만 더한다. 그런데 `reload()` 가
돌려주는 `"surrogate"` 는 `_state["surro_data"] or ("ERROR: " + …)` 다. 측정:

```
after good load, surro_data = oracle_dataset.jsonl (33 rows / 12 instances, macro support [0, 1, 2], …
after BAD load,  surro_error = SystemExit: 라벨 파일이 없다: /tmp/nope_does_not_exist.jsonl …
after BAD load,  surro_data  = oracle_dataset.jsonl (33 rows / …    ← 그대로다
>>> contains '/tmp/nope_does_not_exist.jsonl'? -> False
```

**(나) 그 상태가 pytest 수집 시점에 이미 만들어진다.** `test_support_is_data.py:28` 과
`test_vocabulary_gap_fires.py:33` 이 **모듈 최상위에서** `svc._load_surrogate()` 를 부른다
(둘 다 "지우지 말 것" 이라고 적혀 있다). pytest 는 실행 전에 모든 테스트 모듈을 import 하므로
`_state["surro_data"]` 는 첫 테스트가 돌기 전에 이미 채워져 있다. 계획서의 `restore_state`
픽스처는 그 값을 **보존**한다. 그러므로 디렉터리 단위로 돌리면(= Task 6 Step 7 · Task 7 Step 5 가
지시하는 그 명령) 마지막 단언이 실패한다.

부수 결함: 실패 후에도 `/health` 는 이미 적재 안 된 데이터셋 이름을 산문으로 계속 보고한다 —
그 테스트가 막으려던 바로 그 반쪽 상태다. `_state["surro_data"] = None` 도 같이 지워야 한다.
또 `_load_surrogate` 는 `try` **앞에서** `SURRO_DATA = path` 를 갱신하므로, 실패한 `/reload`
뒤에 서비스의 `SURRO_DATA` 가 없는 파일을 가리킨 채 남는다(인자 없는 다음 `/reload` 가 그것을 재시도).

### 5-3. ✅ 도장과 소비처는 같은 태스크다 (Python) — 🔴 Julia 는 아니다

**Python 쪽은 제대로 됐다.** Task 5 안에 write(`gen_oracle_dataset.jl` ×4 · 생산자 · 백필)와
read(`load_rows` → `meta` → `dspy_service._load_surrogate` 의 `support` · `export_surrogate` meta)가
전부 들어 있고, **Step 16 이 세 파일 grep + `meta["train_macros"]` 실측으로 소비를 확인한다.**
`train_kinds` 재발 방지 장치로 유효하다.

🔴 **그런데 Julia 판은 `train_kinds` 와 정확히 같은 모양이 된다.** Task 5 가 만드는
`ActionRegistry.require_train_macros_stamps` 의 **생산 소비처가 0곳**이다 —
`gen_oracle_dataset.jl` 은 `train_macros_stamp` 로 **찍기만** 하고, `require_…` 를 부르는 것은
`test/train_macros_stamp_smoke.jl` 뿐이다. 계획서 §3 은 *"도장을 찍는 레인이 자기 도장을
검사할 함수를 안 가지고 있다"* 를 결함으로 들고 그것을 고친다고 하는데, **함수만 생기고
호출은 안 생긴다.** (테스트가 붙은 만큼 `train_kinds` 보다는 낫다. 그러나 §9 의 미결 목록에
*"Julia 소비처는 테스트뿐"* 이라고 적어야 한다.)

부수: `test/runtests.jl` 이 `action_registry.jl` 을 **두 번** include 하게 된다
(`smdp_stamp_smoke.jl` → 새 파일). 측정 결과 `WARNING: replacing module ActionRegistry.` 가
뜨고 동작은 한다. 그리고 새 파일의 python 경로 첫 후보 `dirname(dirname(@__DIR__))` 는
`/home/chahj578` 로 **한 단계 틀렸다** — 폴백 덕에 돌 뿐이다.
(Julia `string([0,1,2])` == Python `print([0,1,2])` == `"[0, 1, 2]"` 는 실측 확인. 교차검사 자체는 건전하다.)

### 5-4. ⚠️ 프로브 판과 반사실 판이 **같은 사건**인지 아무도 안 잰다

`fold_board_to_label_row` 는 서술자를 **프로브 판의 사건**에서, 결과를 **반사실 판**에서 가져오고,
docstring 이 *"팔마다 자기 판에서 읽으면 그 계약이 **가정**이 된다. 사건에서 한 번 읽어 모두에게
같이 넣으면 **구성상** 지켜진다"* 라고 적는다. 🔴 **이 논증은 틀렸다.** 그렇게 하면 열이
**팔들 사이에서 일관**해질 뿐, 그 값이 **그 판에서 참**이라는 보장은 하나도 안 생긴다.
프로브 판의 결정 k 와 반사실 판의 결정 k 가 다른 사건이면 라벨은 조용히 거짓이 되고,
게이트가 없으므로 영영 안 보인다. **가정을 검증 불가로 바꾼 것이다.**

게다가 이 레포는 그 자리에서 이미 데었다: `.claude/CLAUDE.md` §"아직 살아 있는 결함" 1번이
`_pick_active_robot` 의 `Set` 순회로 **같은 시드에서도 고장 대상 로봇이 갈릴 수 있다**고 적는다
(사용자 메모리는 `bb1b88c4` 로 고쳐졌다고 하지만 계획서는 그 사실도, 측정도 인용하지 않는다).

**싼 게이트가 이미 있다:** 반사실 판의 `decisions[k-1]` 이 `truth`·`closed_at`·`soc`·`deviate_from`
을 그대로 싣는다. 프로브의 사건과 대조하면 한 줄로 못박힌다. 계획서는 안 한다.

### 5-5. ⚠️ 프로브 판이 부모 환경의 `DS_DEVIATE_AT` 을 안 지운다

Task 2 Step 3 은 `if k > 0:` 일 때만 두 키를 **넣는다.** 지우지 않는다.
같은 함수가 바로 아래에서 `env.pop("DEMO_FORCE_MACRO", None)` 을 하는 이유가 정확히
*"부모 환경에 남아 있으면 policy.jl 이 죽는다"* 인데, 형제 변수에 같은 방어를 안 한다.
그리고 `test_at_zero_is_a_probe_board_with_no_deviation` 은 `"DS_DEVIATE_AT" not in env` 를
단언하지만 pytest 가 깨끗한 환경에서 돌기 때문에 **결함이 있어도 초록이다** — 이 레포가
반복해 데인 "실패할 수 없는 검사" 모양이다.

---

## 6. PRIORITY 4 — 의도적 이탈에 대한 판정

### 6-1. `boards.jsonl` 제외 — ✅ **옳다**

```
$ grep -rn 'import boards\|from boards' --include='*.py' . | grep -v .venv
wm4spacecraft_manufacturing/smdp/gate_g2.py:166  ·  gate_gs.py:247  ·  test_smdp_gates.py:9
```

V3 의 라벨 경로(`counterfactual_labels` → `sample_grid` → `derive_grid`/`objective`)는
`smdp/boards.py` 를 **한 번도 import 하지 않는다.** `boards.jsonl` 은 그 모듈의 `DEFAULT_MANIFEST`
(`boards.py:16-17`)일 뿐이다. 사실 시트 §3-2(가)가 그것을 "최소 4파일" 에 넣은 것이 과다였고,
계획서의 정정이 맞다. 낡은 매니페스트를 안 되살리는 판단도 옳다.

### 6-2. "6파일이 아니라 7" · Task 1 이 목록에서 뺀다 — ✅ 7은 맞다 · **제거는 부분 성취**

`ENACTABLE_NAMES` 는 `sample_grid.py:249-250` 의 7이름 리터럴이고 넷(`Deprioritize`·`ForbidZone`·
`ReformTeam`·`RelocateBuild`)이 현행 `v4-3arms` 에 없다. `arm_menu()`(`:256`)와
`_default_id_by_name()`(`:273`)이 그것으로 교집합을 잡으므로 새 팔은 **에러 없이 탈락**한다. 확인.

Task 1 Step 4 는 그것을 `enactable_names()`(레지스트리 파생)으로 바꾸므로 **매크로 주조 때
이 파일을 손으로 고칠 필요가 없어진다 — 목적은 달성된다.** 다만:

- 새 docstring 이 *"그 계약은 이미 `test/policy_macro_binding.jl` (A)(B)가 지킨다"* 에 기댄다.
  사실 시트 §8(d)가 **4팔 레지스트리에서 (B)가 RED** 임을 실측했으므로 그 보장은 *"그 테스트를
  돌렸고 초록일 때"* 만 유효하다. Task 1 의 스텝 목록에는 그 테스트가 **없다**(Task 3 Step 7 에 있다).
- 같은 파일의 다른 어휘성 리터럴 `CASES`(`:214`, 7종 중 넷이 zone 을 태운다)는 **그대로 남는다.**
  계획서는 CLI 기본값(`--cases battery,fault`)과 `main()` 의 화이트리스트로 막는데, 그것은
  `counterfactual_labels.py` 쪽 방어이고 `sample_grid.CASES` 자체는 여전히 함정이다.

### 6-3. Task 8 — ✅ 건전하다 (한 구멍)

주변 coverage 대신 **조건부 coverage 최솟값**을 R4 자리에 놓는 것은 측정 결과에 정확히 대응한다
(적대적 4000 배치 · 30~31/33 중첩 · α=0.2 에서 0.818 PASS vs 미완주 0.000). 그리고 계획서는
`R4: PASS` 를 인용하지 말라고 세 곳에서 못박는다. **좋다.**

구멍: Step 2 의 스크립트가 조건부 축을 `("macro", "complete")` 로 잡는데, **모든 판이 완주하면
`complete` 축이 단일값으로 퇴화해 그 항목이 조용히 주변 coverage 가 된다.** 그리고 `q_i` 는
여전히 LIO(leave-instance-out)라 §5-1 이 반증한 그 추정기다 — 조건부 분할이 그 인공물을
**일부만** 걷어낸다는 사실을 보고 골격에 적어야 한다. 또 `SurrogateV2` 를 폴드마다 새로 적합하므로
§3-3 의 상수 붕괴가 폴드 단위로 재현될 수 있다.

### 6-4. §2 의 장애 매핑 — ✅ 대체로 충실

3번(레지스트리 `"kinds": ["battery"]`)과 4번(단일 α·단일 q)이 라벨 밖 축이라는 것은 측정 보고
§7-3·§7-4 원문과 일치한다. 2번을 `C_fail` 절벽으로 돌린 것은 §2-3 표에서는
*"…아닐 수 있다"* 로 정직하게 완화돼 있다. **고칠 것은 §2-1 의 단정 하나뿐**(§4-6).

---

## 7. PRIORITY 5 — §9 는 정직하지만 불완전하다

§9 의 세 고백(축 2 는 라벨 밖 축이 있다 · `no_arms`/`single_arm` 미측정 · R2 의 마지막 합성은
논증이다)은 **전부 정확하고 원자료와 맞는다.** 그러나 **하중이 실린 것 일곱이 빠져 있다:**

1. 🔴 반사실 판이 전부 완주하면 `predict_J` 가 상수(~10000)로 붕괴한다 — §3-3 (측정).
2. 🔴 R2 의 '전' 라벨셋은 **관측이 아니라 뺄셈**이다 — §2.
3. 🔴 Julia `require_train_macros_stamps` 의 **생산 소비처가 0곳**이다 — §5-3.
4. 🔴 프로브/반사실 판의 **사건 동일성이 미검증**이고 게이트가 없다 — §5-4.
5. ⚠️ 미완주 `makespan` 의 의미가 두 라벨 레인에서 다르다 — §4-5. Task 8 의 세대 간 비교가 그 위에 선다.
6. ⚠️ `test_gate_ng2.py` 3건이 이미 빨갛다 — §4-1. "전부 PASS" 게이트가 오늘 실행 불가다.
7. ⚠️ 실패한 재적재 뒤 `_state["surro_data"]`/`SURRO_DATA` 가 낡은 채 남는다 — §5-2.

---

## 8. 구현자가 부딪힐 것 (실행 순서대로)

| 언제 | 무엇 | 왜 |
|---|---|---|
| Task 4 Step 4·6 | 테스트 개수 18/28 (계획서 13/23) | parametrize 6항목 |
| Task 4 Step 7 | 벽시계가 예상(~85분)보다 짧을 것 | 중앙값 오독 (§4-2) |
| Task 4 Step 8 | `_fitted_c == False` 가 나오면 **거기서 멈춰야 한다** | §3-3 상수 붕괴 |
| Task 5 Step 7 | `"kinds":` 줄이 2곳 | §4-8 |
| Task 5 Step 11 | 테스트 2건 파손 + 기존 3건 빨강 | §5-1 · §4-1 |
| Task 6 Step 6 | `test_a_failed_reload…` 실패 | §5-2 |
| Task 6 Step 7 | "전부 PASS" 불가 | §4-1 |
| **Task 7 Step 3** | 🔴 **`KeyError: 'available'` — V3 의 완료 판정이 안 돈다** | §3-1 |
| Task 7 Step 5 | "전부 PASS" 불가 | §4-1 |
| Task 8 Step 2 | 진단 2·3 이 상수 Ĵ 위에서 계산될 수 있다 | §3-3 · §6-3 |

---

## 9. 안 한 것 · 못 잰 것

- 라벨을 생성하지 않았다. FastAPI 를 띄우지 않았다(모듈 import 로만 `decide`/`health` 를 불렀고
  **LLM 호출 0회** — `dspy.configure` 는 startup 훅에서만 돌기 때문이다. 이건 확인한 사실이다).
- 작업 트리에 아무것도 복원하지 않았으므로 `sample_grid.py` 를 **실제로 import 해 보지 못했다.**
  `derive_grid` 를 모듈 최상위에서 import 하고 `load_grid()` 는 `main()` 안(`:1114`)에서만
  불린다는 것은 `git show` 로 읽어 확인했다 — 세 파일 복원으로 충분해 **보인다**. UNVERIFIED.
- `--jobs 24` 가 판을 갈리게 하는지는 여전히 UNVERIFIED (계획서도 그렇게 적는다).
- ⚠️ 이 검증은 `objective_hash = 489268e6659e5ae9` · `vocab = v4-3arms` · 커밋 `e54dd94a` 위에서
  이뤄졌다. 셋 중 하나라도 갈리면 위 숫자는 무효다.
