# Postflight verification — Plan V1 (어휘 미달 라우터), `81e16b70..f4631fcd`

검증자: `vocab-router-validator` (독립 재유도). 2026-08-27.
**레포 파일은 이 보고서 한 개 외에 한 줄도 수정하지 않았다.** 모든 음성 대조는 `/tmp/vrv/`
사본 또는 pytest 플러그인 monkeypatch 로 했다. 시작 시 `git status --short | wc -l` = 263,
종료 시 263 (`diff` 로 **완전 동일** 확인; 이 보고서 파일만 추가).

구현자 보고서는 읽지 않고 판정했다 — 전부 코드/실행에서 재유도했다.

---

## 요약

| 항목 | 판정 |
|---|---|
| A1 A2 A3 A4 A5 | CONFIRMED (5/5) |
| B1 B2 B3 B4 B5 | CONFIRMED (5/5) |
| C1 | **REFUTED** — 사슬이 진술과 다르고, 끊긴 이음매가 하나 있다 |
| C2 | CONFIRMED (경로 서술 정정 포함) |
| C3 | CONFIRMED — 발화 가능하고, 발화하면 축 1 이 조용히 침묵한다 |
| D1 | **REFUTED** — 빨개질 수 없는 검사는 없지만, **막으려던 회귀 자체를 아무 검사도 못 잡는다** |
| D2 | 덮이지 않은 표면 8개 (알려진 1 + 새로 찾은 7) |
| E1~E6 | 전부 기대치와 일치 |
| F1 F2 | CONFIRMED |

부수 REFUTED 3건(문서/커밋 메시지 수준) — 맨 아래.

---

# A. 축 1 이 정말 발화하는가

명령(모두 `.venv/bin/python`, `src/respec/llm_service` 를 `sys.path` 에 얹고 직접 호출):

```
MACRO_NAME            = {0: 'NOOP', 1: 'Replace', 2: 'SwapBattery'}
name2id               = {'NOOP': 0, 'Replace': 1, 'SwapBattery': 2}
_load_surrogate() 후   surro_support = {0, 1, 2}
surro_data            = oracle_dataset.jsonl (33 rows / 12 instances, macro support [0, 1, 2],
                        rule deadband_Jbar, objective_hash 489268e6659e5ae9, vocab v4-3arms)
```

### A1 — 지원집합을 줄이면 `_unsupported_for` 가 그 팔을 미달로 잡는다
**VERDICT: CONFIRMED**
EVIDENCE (직접 재현, `svc._load_surrogate()` 후 `_state["surro_support"]` 를 바꿔서):
```
support={0,1,2} -> _unsupported_for = []
support={0,1}   -> _unsupported_for = ['SwapBattery']
support={0}     -> _unsupported_for = ['Replace', 'SwapBattery']
support=None    -> _unsupported_for = None          (빈 목록이 아니다)
```
REFUTING OBSERVATION: `support={0,1}` 에서 `[]` 또는 `None` 이 나오는 것.
NEGATIVE CONTROL: A3 참조 — 멤버십 검사를 무력화하니 실제로 `[]` 가 나왔다.

### A2 — 같은 조건에서 `surrogate_rank` 가 `(scored, "UNSUPPORTED:SwapBattery")`
**VERDICT: CONFIRMED**
```
support={0,1}: surrogate_rank(req, MENU)
  = ([('Replace', -18470.66972654864), ('NOOP', 0.0)], 'UNSUPPORTED:SwapBattery')
support=None:  = (None, 'surrogate macro support is unknown (model not loaded) -- refusing to answer ...')
```
REFUTING OBSERVATION: `err` 가 `None` 이거나 `UNSUPPORTED:` 접두를 안 쓰는 것.

### A3 🔴 — 음성 대조: 멤버십 검사를 무력화하면 Task 5 가 빨개지는가
**VERDICT: CONFIRMED**
NEGATIVE CONTROL (레포 미수정): `/tmp/vrv/plugin_kill_membership.py` 가 collection 시점에
`svc._unsupported_for` 를 `name2id[m] not in support` 판정이 **항상 거짓**인 버전으로 교체.
```
PYTHONPATH=/tmp/vrv .venv/bin/python -m pytest src/respec/llm_service/test_vocabulary_gap_fires.py \
    -q -p plugin_kill_membership
→ 3 failed, 3 passed
   FAILED test_removing_one_macro_makes_the_gap_fire
   FAILED test_the_gap_names_every_missing_arm_not_just_the_first
   FAILED test_the_gap_reaches_the_single_source_of_truth_decide_parses
```
남은 3 초록은 옳다: `test_baseline_full_support_is_silent`(`[]` 를 기대) ·
`test_unknown_support_is_none_not_empty`(None 경로는 안 건드렸다) ·
`test_health_reports_the_reduced_support`(`_state` 를 직접 읽어 `_unsupported_for` 를 안 탄다).
→ **6개 중 3개가 이 결함에 하중을 받는다. 항진명제가 아니다.**

### A4 🔴 — 항진명제 검사: `MENU` 의 이름 == `e1_analyze.MACRO_NAME` 의 값
**VERDICT: CONFIRMED (항진명제가 **아니다**)**
```
MENU              = ["NOOP", "Replace", "SwapBattery"]
MACRO_NAME.values = ('NOOP', 'Replace', 'SwapBattery')
m in name2id 결과  = [('NOOP', True), ('Replace', True), ('SwapBattery', True)]
```
셋 다 일치. `m in name2id` 가 언제나 참이므로 필터가 전부를 통과시킨다 = 측정이 성립한다.
추가 대조: `features_agnostic._reg.MACRO_NAME`(= `core/action_registry.py`)과
`e1_analyze.MACRO_NAME` 의 키 집합이 동일(`True`) — 두 파이썬 소비처가 같은 레지스트리를 본다.
REFUTING OBSERVATION: 셋 중 하나라도 `False` 였다면 A1~A3 전체가 항진명제였다.

### A5 — 배포 상태에서 지원집합이 `{0,1,2}` = 어휘 전체인가
**VERDICT: CONFIRMED**
`_load_surrogate()` 가 `oracle_dataset.jsonl` 33행에서 유도한 `surro_support = {0,1,2}`,
레지스트리 활성 id 도 `{0,1,2}`(`vocab v4-3arms`). 배포 `_unsupported_for(...) == []`.
→ **축 1 은 오늘 배포 상태에서 발화 영역이 비어 있는 것이 정상이다.** 축 1 의 초록은
"옳아서" 가 아니라 "사건이 없어서" 이고, 그 둘을 가르는 것은 A1~A3 의 강제 발화뿐이다.
설계서 §2-2 의 경고는 여전히 유효하다.

---

# B. Julia 측 라우터가 실제로 도는가

### B1 — `select_lane` 우선순위가 어휘 미달 > novelty 인가 (함수를 직접 호출)
**VERDICT: CONFIRMED**
`/tmp/vrv/b1.jl` 이 `tools/monitor/lane_select.jl` 만 include 하고 6케이스를 직접 호출:
```
supported=false novel=false UP      -> lane=dspy       axis=vocabulary_gap
supported=false novel=true  UP      -> lane=dspy       axis=vocabulary_gap   ← 두 축 동시참: 어휘가 이긴다
supported=true  novel=true  UP      -> lane=dspy       axis=novelty
supported=true  novel=false UP      -> lane=surrogate  axis=none
supported=false novel=true  noop    -> lane=noop       axis=control
supported=false novel=false NODSPY  -> lane=canonical  axis=vocabulary_gap
```
REFUTING OBSERVATION: 2행이 `axis=novelty` 로 나오는 것.
NEGATIVE CONTROL: `/tmp` 사본에서 축 1/축 2 블록을 맞바꾸니 2행이 `novelty` 가 되고
`test_lane_select.jl` 81행이 빨개졌다(11 passed / 1 failed).

### B2 🔴 — 교정 파일이 없는 지금 `router_drives()` true, `router_enabled()` false
**VERDICT: CONFIRMED**
```
wm4spacecraft_manufacturing/novelty/   : 존재하지 않음 (ls: No such file or directory)
NOVELTY_CALIB                          : unset
DEMO_ROUTER / DEMO_POLICY              : unset
ROUTER_MODE = "auto"   POLICY = "canonical"
router_drives()  = true
router_enabled() = false     (@warn "novelty calibration not found -> router disabled (fail-open)")
```
→ 커밋 `394779a2`/`c57f8640` 의 존재 이유가 실측으로 성립한다: 이 브랜치 이전에는 어휘 미달
격상이 **오늘 이 작업 트리에서 한 번도 열릴 수 없었다.**

### B3 🔴 — `DEMO_ROUTER=0` 에서 `router_drives()` false (비교 실행 보호)
**VERDICT: CONFIRMED** — `ROUTER_MODE` 가 `const` 이므로 **별도 프로세스**로 확인:
```
DEMO_ROUTER=0  → ROUTER_MODE="0"  router_drives()=false  router_enabled()=false
DEMO_POLICY=noop → POLICY="noop"  router_drives()=false
(env 없음)      → router_drives()=true
```
REFUTING OBSERVATION: `DEMO_ROUTER=0` 에서 `router_drives()=true`.

### B4 🔴 — T9/T9b 가 정말 **호출부**를 겨누는가 (재리뷰어 말고 내가 다시)
**VERDICT: CONFIRMED**
NEGATIVE CONTROL: `/tmp/vrv/tools/` 사본에서 `policy.jl:1080` 과 `:1112` 만
`router_enabled() && POLICY != "noop"` 로 되돌리고(= 실제로 났던 회귀), `--project` 은
레포를 그대로 씀:
```
julia +lts --project=<repo> /tmp/vrv/tools/test_policy_escalation.jl   → exit=1
  [PASS] T8    [PASS] T8b
  [FAIL] T9  -- n_drives=0
  [FAIL] T9b -- n_enabled=2
  2개 실패 / 16개 통과
```
T8/T8b 가 초록으로 남는 것까지 정확히 재리뷰 주석이 적은 대로다.

### B5 🔴 — `test_lane_select.jl` 이 `test/runtests.jl` 배선으로 실제로 실행되는가
**VERDICT: CONFIRMED (정적 논증이 아니라 실측)**
`Pkg.test()` 를 안 굴리는 대신 `julia +lts --project=. test/runtests.jl` 을 백그라운드로
완주시켰다(4m14s). 실제 출력:
```
ConstructionBots Tests                             |  252      1    253  4m14.1s
  ...
  lane selection — vocabulary gap outranks novelty |   36            36     0.5s
  ...
  Demo                                             |           1      1  1m43.4s
      LoadError: Gurobi Error 10009: No Gurobi license found   ← 알려진 baseline error
```
→ 배선은 도달 가능하고 36 어서션이 진입점에서 실제로 돈다. 앞선 include 파일 7개에
`exit(` 는 하나도 없다(grep 0건)이므로 조기 종료 경로도 없다.

---

# C. 끊긴 데가 없는가 — 끝에서 끝까지

### C1 🔴 — 사슬 추적
**VERDICT: REFUTED** (두 가지 이유로)

#### (1) 과제문에 적힌 사슬의 한 링크가 **실제로 존재하지 않는다**

과제문: `… → rt["requested_unsupported"] → select_lane(supported=…) → …`

실제 (`policy.jl:1068-1082`, `:1122-1123`):
```julia
local _esc_probe, _esc_miss = escalation_target(pol, "surrogate", true)   # ← 별도 프로브
local supported = isempty(_esc_miss)                                      # ← supported 는 여기서 온다
...
if router_drives()
    local sel = select_lane(novel=…, available=avail, supported=supported, policy=POLICY)
...
local esc_tgt, esc_missing = escalation_target(pol, requested, escalation_allowed)  # ← 별개 호출
isempty(esc_missing) || (rt["requested_unsupported"] = esc_missing)                 # ← 여기서 rt 로
```
`supported` 는 `rt["requested_unsupported"]` **에서 오지 않는다.** 둘은
`pol["surrogate"]["unsupported"]` 라는 같은 뿌리에서 나오지만 **인자가 다르다**:
`supported` 는 언제나 `"surrogate"` 를 프로브하고, `requested_unsupported` 는 `requested`
(라우터가 켜져 있으면 `rt["target"]`, 아니면 `POLICY`)를 본다. 라우터가 이미 dspy 를 고른
사건에서 `requested == "dspy"` 면 `pol["dspy"]["unsupported"]`(보통 빈 목록)를 읽으므로
**두 값이 갈린다.** 이것은 결함이 아니라 의도된 설계(`:1066-1067` 주석이 명시)이지만,
과제문/보고서가 서술한 사슬은 틀렸다.

이음매별 확인(전부 코드로 확인, `file:line`):

| # | 이음매 | 상태 |
|---|---|---|
| 1 | `_load_surrogate` → `_state["surro_support"]` | ✅ `dspy_service.py:281,290` (실측 `{0,1,2}`) |
| 2 | `_state["surro_support"]` → `_unsupported_for` | ✅ `:456-459` (실측 A1) |
| 3 | `_unsupported_for` → `"UNSUPPORTED:…"` | ✅ `:513, :523-524` (실측 A2) |
| 4 | `surrogate_rank`의 `err` → `out["surrogate"]["unsupported"]` | ✅ 코드상 `:779-781`, `:789-790` (두 분기 모두). **테스트 없음** — 알려진 공백 |
| 5 | JSON → Julia `policy_entry` | ✅ `policy.jl:963`(available) / `:977`(폴백) 둘 다 `unsupported` 를 싣는다 |
| 6 | `policy_entry` → `escalation_target(pol,"surrogate",true)` → `supported` | ✅ `policy.jl:1068-1069` — **어떤 테스트도 이 두 줄을 관측하지 않는다** |
| 7 | `supported` → `select_lane` | ✅ `policy.jl:1081-1082` (게이트 `router_drives()`) |
| 8 | `sel.axis` → `rt["router_axis"]` | ✅ `policy.jl:1088` |
| 9 | `rt` → `decision.router` | ✅ `policy.jl:1325` (`router = rt`) |
| 10 | `decision.router` → 결정 행 | ✅ `run_demo.jl:332` 화이트리스트 |
| 11 | 결정 행 → 산출물 JSON | ✅ `run_demo.jl:352 push!(_DECISIONS,…)` → `:893-894 "decisions" => _DECISIONS` |
| — | `escalation_target(pol, requested, …)` → `rt["requested_unsupported"]` | ✅ `policy.jl:1122-1123` — 위 6번과 **다른 링크**다 |

#### (2) 🔴 이음매 5→6 에 **실질적 파손**이 있다 — Task 4 가 파이썬에서 고친 붕괴가 언어 경계에서 그대로 재발한다

파이썬은 3값 신호를 낸다: `None`(못 쟀다) / `[]`(재서 미달 없음) / `[이름들]`.
그런데 `decide()` 의 응답 JSON 에서 `None` 과 `[]` 가 **둘 다 `unsupported: []`** 로 나가고
(`:779-780` 은 `err` 가 `UNSUPPORTED:` 로 시작할 때만 목록을 만든다), Julia `policy_entry`
는 `unsupported` 만 읽는다. 실측 (`/tmp/vrv/c1.jl`, 실제 `policy_entry`/`escalation_target`/
`select_lane` 을 호출):
```
support UNKNOWN (model failed to load)  unsupported=String[]  supported=true   available=false  -> axis=none
genuine vocabulary gap                  unsupported=[SwapBattery] supported=false available=true -> axis=vocabulary_gap
```
**즉 surrogate 모델 적재가 실패하면 라우터는 "모든 팔이 지원됨" 으로 읽고 축을 `"none"` 으로
찍는다.** 이것이 `bdb0bdda` 가 `or set(range(5))` 를 죽여서 막으려던 바로 그 실패
("모델이 없는데 '전부 배웠다' 고 답하는 셈") 이고, 파이썬 안에서는 고쳐졌지만 Julia 쪽에서
한 겹 위로 그대로 살아남았다. 정보는 응답에 남아 있다(`pol["surrogate"]["error"]` +
`available=false`) — `supported` 계산이 그것을 안 볼 뿐이다.

REFUTING OBSERVATION (이 판정을 뒤집을 관측): `policy_entry` 나 `decide_all` 이
`pol["surrogate"]["error"]` 를 보고 `supported` 를 세 번째 값으로 다루는 코드. 없다.

### C2 — `rt["router_axis"]` 가 결정 행 JSON 에 나타나는가
**VERDICT: CONFIRMED — 단, 과제문의 경로 서술은 틀렸다**
`record_decision!` 은 **결정 행이 아니라 모니터 스트림**을 쓴다
(`policy.jl:1356-1389`, `"router" => decision.router` 로 `rt` 전체를 통째로 싣는다 →
`router_axis` 는 여기로도 나간다). **결정 행**은 다른 경로다:
`run_demo.jl:281 this_decision = Dict(... "router_axis" => get(decision.router,"router_axis",nothing) ...)`
→ `:352 push!(_DECISIONS, this_decision)` → `:893-894 "decisions" => _DECISIONS`.
두 경로 모두 값을 나른다.

`nothing` vs `"none"`: 화이트리스트 기본값이 리터럴 `nothing` 이다(`run_demo.jl:332`).
JSON3 는 `nothing` 을 `null` 로 쓰므로 "레인 선택이 안 돌았다"(`null`)와 "돌았는데 축이 안
발화했다"(`"none"`)가 산출물에서 구분된다. ✅
REFUTING OBSERVATION: 기본값이 `"none"` 이거나 `get(..., "")` 인 것.

### C3 — Task 1 의 `KeyError` 가 `predict_J`/`decide` 경로에서 의도치 않게 발화할 수 있는가
**VERDICT: CONFIRMED (발화 가능. 오늘은 발화하지 않는다)**

`psi()` 는 `MACRO_SPECS`(레지스트리 파생, 오늘 `{0: [], 1: ['ReplaceAgent'], 2: ['SwapBattery']}`)
멤버십을 본다. 발화 경로 둘:

1. **학습**: `_load_surrogate` → `SurrogateV2().fit(rows)` → `surrogate_features.build_features`
   → `psi(int(r["macro"]))`. 학습셋에 어휘 밖 `macro` id 가 한 줄이라도 있으면 `KeyError`.
   오늘 데이터셋의 macro support 는 `{0,1,2}` 라 발화하지 않는다(실측).
2. **추론**: `_surro_row` 의 `macro` 는 `scorable`(= `name2id` ∩ `support`)에서만 나오므로
   레지스트리 밖 값이 도달할 수 없다.

**발화하면 무엇이 죽는가 — 그리고 이게 C1(2)와 같은 결함이다:**
`_load_surrogate` 의 `except Exception` 이 `KeyError` 를 삼킨다 → `surro_support` 키가
**아예 안 세팅된다** → `_state.get("surro_support") is None` → `surrogate_rank` 가
"support unknown" 으로 거부 → Julia 는 `unsupported=[]` → `supported=true` →
**축 1 이 침묵하고 `router_axis="none"` 으로 기록된다.**
추론 시점 발화도 같다 — `surrogate_rank` 의 `except Exception` 이 `"KeyError: …"` 문자열로
바꾸고, 그 문자열은 `UNSUPPORTED:` 로 시작하지 않으므로 같은 붕괴를 탄다.
즉 Task 1 은 라벨 오염(psi(99)==psi(0))은 막았지만, **그 예외가 실제로 나는 세계에서 라우터의
축 기록은 조용히 거짓이 된다.**
REFUTING OBSERVATION: `_load_surrogate` 가 실패 시 `surro_support` 를 명시적으로 `None` 이
아닌 값으로 세팅하거나, Julia 가 `error`/`available` 을 보고 `supported` 를 유보하는 코드.

---

# D. 실패할 수 없는 게이트

### D1 — 새 검사마다 "무엇이 바뀌면 빨개지나"
**VERDICT: REFUTED** — *빨개질 수 없는 개별 검사는 없다.* 그러나
**이 브랜치가 막으려던 회귀 자체를 18개 검사 전부가 못 잡는다**(아래 🔴 참조).

전부 음성 대조를 실제로 돌렸다. 레포는 건드리지 않았다.

| 검사 | 무엇이 바뀌면 빨개지나 | 실측 음성 대조 |
|---|---|---|
| `test_psi_unknown_macro.py` (5) | | |
| ├ `test_unknown_macro_id_raises` | `psi` 가 `.get(mid, [])` 로 되돌아감 | ✅ `-p nc_psi` → **2 failed / 3 passed** |
| ├ `test_the_error_names_the_id_and_the_registry` | 위와 같음 / 메시지에서 id·`action_registry` 제거 | ✅ 같은 실행에서 red |
| ├ `test_noop_still_works…` | 멤버십을 **truthiness** 로 바꾸는 "잘못된 수정" | ✅ `-p nc_psi_truthy` → **2 failed / 3 passed** |
| ├ `test_registered_macros_are_unchanged` | 위와 같음 / `PSI_AXES` 축 개수 변경 | ✅ 같은 실행에서 red |
| └ `test_primitive_name_lists_still_bypass_the_registry` | 리스트 입력 경로에 레지스트리 검사를 얹음 | (구성 안 함 — 어서션이 `psi(["ReplaceAgent"])["a_intervenes"]==1.0` 인 실값 대조라 항진명제 아님) |
| `test_lane_select.jl` 새 testset (12) | | |
| ├ (B) 두 축 동시참 → `vocabulary_gap` | 축 순서 뒤집기 | ✅ 축 블록 swap → **11 passed / 1 failed** (line 81) |
| ├ (A)(F) + (B)의 axis | 축 1 블록 삭제 | ✅ 삭제 후 직접 호출: A `surrogate/none`, B `dspy/novelty`, F `surrogate/none` → **12 중 5 어서션 red** |
| └ (C)(D)(E) | novelty 축 제거 · 기본 axis 문자열 변경 · noop 분기 제거 | 각각 실값 대조라 falsifiable |
| `test_policy_escalation.jl` T7~T9b | | |
| ├ T7 / T7b | `escalation_target` 의 `allowed`/`unsupported` 계약 파손 | ⚠️ **이름이 주장하는 것을 안 잰다** — 아래 참조 |
| ├ T8 | `router_drives()` **정의**가 `install_novelty!` 를 되찾음 | 정적 lowered-IR 검사, falsifiable |
| ├ T8b | (양성 대조) `router_enabled()` 가 `install_novelty!` 를 잃음 | 검사 방법의 자기 검증 — 유효 |
| └ T9 / T9b | `decide_all` 의 **호출부**가 `router_enabled()` 로 되돌아감 | ✅ B4: **T9 n_drives=0 / T9b n_enabled=2 로 red** |
| `test_support_is_data.py` (3) | | |
| ├ `test_health_exposes_support_as_a_list_of_ints` | `/health` 에서 `surro_support` 키 제거 | ✅ `-p nc_support` → **3 failed** |
| ├ `test_health_support_is_none_not_empty…` | `None` 을 `[]` 로 뭉갬 | ✅ 같은 실행 |
| └ `test_no_stale_literal_fallback…` | `or set(range(5))` 복원 | ✅ 같은 실행 (`scored is None` 이 실제 점수 리스트를 받아 red) |
| `test_vocabulary_gap_fires.py` (6) | 멤버십 검사 무력화 | ✅ A3: **3 failed / 3 passed** |

#### 🔴 D1 의 진짜 결론 — 막으려던 회귀를 아무도 못 잡는다

T9 는 `decide_all` 의 lowered 코드에서 `router_drives` **문자열이 정확히 2회** 나오는지를
센다. 그래서 **have_det 결합을 다시 얹어도 셈이 안 바뀐다.** 실측:

```
/tmp/vrv/tools/monitor/policy.jl:1112 을
    escalation_allowed = router_drives() && install_novelty!()
로 바꾸고 tools/test_policy_escalation.jl 실행
→ exit=0,  T7 PASS  T7b PASS  T8 PASS  T8b PASS  T9 PASS(n_drives=2)  T9b PASS(n_enabled=0)
→ **전부 통과 (18)**
```
즉 `394779a2`/`c57f8640` 가 **뗀 바로 그 결합을 한 줄로 되돌려도** 이 브랜치의 Julia 게이트가
하나도 안 빨개진다. `router_enabled()` 를 안 쓰고 `install_novelty!()` 를 직접 부르면 되기
때문이다. 같은 구멍이 `:1080`(select_lane 진입 게이트)에도 있다.
T8/T9 는 **함수 이름을 세는 검사**이지 **의존을 재는 검사**가 아니다.

T7/T7b 도 이름이 과장이다: `escalation_target(pol7, "surrogate", true)` 를 부르는 것은
`allowed=true` 를 손으로 넣는 것이므로 "have_det 와 무관하다" 를 **전혀 재지 않는다**
— T1/T3 과 같은 종류의 순수함수 계약 검사일 뿐이다.

#### 부수: T9 의 "미측정" 분기가 사실은 FAIL 이다
`m9 === nothing` 분기가 `check(…, false, …)` 를 부른다 → `nfail += 1` → `exit(1)`.
라벨은 "빨강 아님, 미측정" 이라고 적혀 있는데 **실제로는 빨강이 된다.** (fail-loud 라
안전한 방향이지만 라벨이 코드와 다르다.)

### D2 🔴 — 덮이지 않은 표면

알려진 것 1개 + **새로 찾은 7개**:

1. **(알려진)** `decide()` 의 파싱 단계 — `surrogate_rank` 의 `err` 문자열을 응답 JSON 의
   `surrogate.unsupported` 로 바꾸는 `dspy_service.py:779-781`·`:789-790`.
   controller 가 유료 호출 위험으로 금지. 그대로 남아 있다.
2. 🔴 **`policy.jl:1068-1069` — 축 1 이 생산에서 입력을 받는 바로 그 두 줄.**
   `escalation_target(pol,"surrogate",true)` → `supported = isempty(_esc_miss)`.
   `grep -rn supported test/ tools/test_policy_escalation.jl` 결과 이 계산을 관측하는
   어서션이 **0개**다. 여기서 `"surrogate"` 를 `requested` 로 되돌리면(주석이 경고하는
   바로 그 회귀) 축 1 이 라우터가 이미 dspy 를 고른 사건에서 조용히 뒤집히는데,
   `test_lane_select.jl` 은 `supported` 를 **인자로 받으므로** 못 본다.
3. 🔴 **`policy.jl:1080`·`:1112` 게이트의 have_det 비의존** — D1 참조. 18/18 초록으로
   되돌릴 수 있다.
4. 🔴 **`rt["router_axis"] = sel.axis`(`policy.jl:1088`) 와 `run_demo.jl:332` 화이트리스트** —
   이 줄들을 지워도 빨개지는 검사가 없다. `test_lane_select.jl` 은 `select_lane` 만 부르고
   `decide_all` 을 안 부른다.
5. 🔴 **`router_axis` 에 소비처가 여전히 0개다.** `grep -rn router_axis` 결과는
   `policy.jl:1088`(쓰기) · `run_demo.jl:332`(쓰기) 뿐 — 파이썬/JS/분석 코드 어디도 이 키를
   읽지 않는다. 커밋 `394779a2` 는 "소비처 없는 도장을 만들지 않기 위해서" 화이트리스트에
   넣었다고 적었지만, 넣은 결과는 "산출물에 존재하는, 아무도 안 읽는 도장" 이다.
   설계서 R5(축별 발화 집합)를 계산하는 코드는 아직 없다.
6. 🔴 **Julia 쪽 3값 붕괴**(C1(2)) — `supported=true` 가 "재서 전부 지원" 인지 "못 쟀다"
   인지 구분하는 검사가 없다. `test_policy_escalation.jl` 의 `unavail()` 픽스처는
   `unsupported=[]` + `error=nothing` 만 만들고 "error 가 있는 available=false" 케이스를
   한 번도 안 만든다.
7. **`fell_back` 의미** — `fell_back = (enacted != requested && enacted == "canonical")`
   (`policy.jl:1090`)가 라우터가 몰 때 어떻게 되는지 재는 검사가 없다.
8. **`rt["reason"]` 덧붙임 / `rt["lane_reason"]`**(`:1085-1087`) — "기존 문구를 덮어쓰지
   않는다" 는 계약을 재는 검사가 없다.
9. **`_load_surrogate` 자신의 실패 경로** — `surro_support` 키가 안 세팅되는 것을 재는
   검사가 없다. `test_support_is_data.py` 는 `_state["surro_support"] = None` 을 **주입**해서
   잰다(진짜 실패 경로가 정말 `None` 을 남기는지는 안 잰다).

---

# E. 회귀 — 실측 대조

| # | 명령 | 기대 | **실측** |
|---|---|---|---|
| E1 | `pytest src/respec/llm_service/ wm4spacecraft_manufacturing/ -q --ignore=src/respec/llm_service/test_propose.py` | 3 failed / 93 passed | ✅ **3 failed, 93 passed** (58.65s) |
| E2 | `julia +lts --project=. tools/monitor/test_lane_select.jl` | 36 | ✅ **36** (11+1+4+8+12) |
| E3 | `julia +lts --project=. tools/test_policy_escalation.jl` | 18/18 | ✅ **전부 통과 (18)**, exit=0 |
| E4 | `julia +lts --project=. test/policy_macro_binding.jl` | 40 | ✅ **40/40** |
| E5 | `julia +lts --project=. test/route_descriptors_survive.jl` | 17 | ✅ **17/17** |
| E6 | `julia +lts --project=. test/battery_menu_lanes_agree.jl` | 12 | ✅ **12** (6+3+3) |

(Julia 출력은 전부 파일 리다이렉트로 받았다 — `head`/`grep -m` 파이프 없음.)

**E1 의 3 failed 가 정말 선존 결함인가 — CONFIRMED.**
셋 다 `wm4spacecraft_manufacturing/smdp/test_gate_ng2.py` 이고, 실패 사유가 자기 픽스처다:
```
def _ev(light, heavy, arms=(0, 1, 2, 3)):        ← 팔 id 3
FAIL: 사건 0 의 팔 id 3 가 현행 어휘(v4-3arms)의 활성 팔이 아니다   (×8)
🔴 분해 불가 — 이 게이트는 지금 아무것도 못 본다.
```
2026-08-24 의 4팔→3팔 재번호 때 픽스처가 안 따라온 드리프트다. `gate_ng2.py` 는
`action_registry` 만 import 하고 `features_agnostic`/`psi` 를 안 쓴다. 이 브랜치의 7커밋은
`wm4spacecraft_manufacturing/smdp/` 아래를 **한 파일도 안 건드렸다**(F1 참조).
→ **이 브랜치와 무관한 선존 실패.**

**추가 실측 (요구 밖):** `julia +lts --project=. test/runtests.jl` 완주 —
`252 passed / 0 failed / 1 errored` (4m14s), 그 1 error 는 `Demo` 의
`Gurobi Error 10009: No Gurobi license found` = 알려진 baseline.

---

# F. 커밋 위생

### F1 — 플랜 밖 변경을 쓸어 담았는가
**VERDICT: CONFIRMED (담지 않았다)**
`git diff --name-only 81e16b70..f4631fcd` = 11파일, 전부 플랜 관련.
커밋별로도 전부 좁다:
```
b703a987 features_agnostic.py, test_psi_unknown_macro.py
b3e9c7b0 runtests.jl, lane_select.jl, test_lane_select.jl
394779a2 policy.jl, run_demo.jl, test_policy_escalation.jl
c57f8640 policy.jl, test_policy_escalation.jl
e43df0f0 policy.jl, test_policy_escalation.jl
bdb0bdda dspy_service.py, test_support_is_data.py
f4631fcd test_vocabulary_gap_fires.py
```
**`394779a2` 의 `run_demo.jl`: `7 insertions(+), 0 deletions`** — 코드 1줄 + 주석 6줄.
선존 dirty hunk 는 하나도 안 딸려 들어갔고, 작업 트리에는 지금도 `run_demo.jl` 의
미커밋 hunk 9개가 그대로 남아 있다(`git diff -U0 | grep -c '^@@'` = 9, 전부 committed hunk
와 다른 위치).

### F2 — 검증 후 작업 트리가 시작할 때와 같은가
**VERDICT: CONFIRMED**
```
시작: git status --short | wc -l  = 263
종료: git status --short | wc -l  = 263
diff <시작> <종료>                 = (차이 없음)
```
(이 보고서 파일 하나만 추가로 생기며, 그것은 지정된 산출물이다.)

---

# 부수 REFUTED — 문서·커밋 메시지 수준

**R-a. `lane_select.jl:18` 의 docstring 이 반환 순서를 틀리게 적는다.**
```
docstring: select_lane(; novel, available, supported, policy) -> (lane, reason, axis)
실제:      keys(select_lane(...)) == (:lane, :axis, :reason)
```
전 소비처가 이름 접근(`sel.lane`/`sel.axis`/`sel.reason`)이라 오늘은 무해하지만, 누가
`lane, reason, axis = select_lane(...)` 로 위치 분해하면 `reason` 에 축이, `axis` 에 산문이
들어간다 — 그리고 **에러 없이** 그렇게 된다. 과제문 B 항목도 같은 순서를 반복했다.

**R-b. 커밋 `bdb0bdda` 메시지의 "`/health` 와 `/decide` 가 목록을 싣는다" 는 절반만 참이다.**
`grep -n surro_support src/respec/llm_service/dspy_service.py` → `:290`(세팅) `:456` `:487`(읽기)
`:702-703`(**`/health` 만**). `/decide` 는 `surro_support` 를 싣지 않는다 — 파생값인
`surrogate.unsupported` 만 나간다. 지원집합 자체는 `/health` 로만 감사할 수 있다.

**R-c. `tools/test_policy_escalation.jl` T7/T7b 의 이름이 재는 것을 넘어선다** (D1 참조):
"have_det 와 무관" 을 재지 않는다. `allowed` 를 리터럴로 넣는 순수함수 계약 검사다.

---

# RISKS — 아무도 안 물었지만 내가 본 것

1. 🔴 **이 브랜치의 핵심 수정이 되돌려져도 게이트가 전부 초록이다.**
   `escalation_allowed = router_drives() && install_novelty!()` 한 줄로 have_det 결합이
   복원되고 `tools/test_policy_escalation.jl` 은 **18/18 초록**. 이 레포의 시그니처 실패가
   한 번 더 자란 자리다. 필요한 것은 이름 세기가 아니라 **의존 재기**다 — 예: `decide_all`
   의 kwarg 바디 lowered 코드에서 `install_novelty` 문자열이 0회임을 세는 T9c 한 줄.
   (같은 관용구가 이미 T8 에 있다. 대상만 `router_drives()` 에서 `decide_all` 본문으로
   바꾸면 된다.)

2. 🔴 **`supported` 가 "못 쟀다" 를 "전부 지원" 으로 읽는다** (C1(2), C3).
   Task 4 가 파이썬 안에서 죽인 `set(range(5))` 붕괴가 언어 경계에서 그대로 살아 있다.
   surrogate 적재 실패 · 추론 예외 · 서비스 다운 — 세 경우 모두 축 1 이 침묵하고
   `router_axis="none"` 이라는 **거짓 도장**이 결정 행에 박힌다. `null` 을 찍는 것과 다르다.
   설계서 R5 를 이 상태에서 재면 "축 1 은 한 번도 발화 안 했다" 가 나오는데, 그것이
   "발화할 사건이 없었다" 인지 "재지 못했다" 인지 산출물만으로 구분할 수 없다.

3. 🔴 **`router_axis` 는 여전히 소비처가 0개다.** 커밋 메시지가 인용한 설계서 §5
   ("도장만 찍고 소비처를 안 만드는 것이 … 그 실패다")를 이 커밋 자신이 반복한다.
   R5 를 계산하는 코드가 없으므로, 이 필드가 산출물에 실린 것과 R5 를 잴 수 있는 것은
   아직 다른 이야기다.

4. **오늘 배포 상태에서 축 1 은 구조적으로 침묵한다** (A5). `surro_support == {0,1,2} ==
   어휘 전체`. 이 브랜치가 고친 것은 "발화했을 때 제대로 흐르는가" 이지 "발화한다" 가
   아니다. 발화시키려면 학습셋에서 팔을 빼거나(= 다른 세계) 어휘에 팔을 더해야 한다.
   **축 1 로 무언가를 측정했다고 보고하기 전에 이 사실을 먼저 적을 것.**

5. **`test_gate_ng2.py` 의 3 failed 는 이 브랜치와 무관하지만 방치된 지 3일째다.**
   그 게이트 자신의 출력이 "🔴 분해 불가 — 이 게이트는 지금 아무것도 못 본다. 초록도
   빨강도 증거가 아니다" 라고 적는다. 픽스처의 `arms=(0,1,2,3)` 를 `(0,1,2)` 로 고치면
   끝나는 일이고, 그전까지 N-G2 는 **어떤 판정도 못 낸다.**

6. **`test_vocabulary_gap_fires.py` 와 `test_support_is_data.py` 는 둘 다 import 시점에
   `svc._load_surrogate()` 를 부른다** — pytest 한 번에 sklearn fit 이 두 번 돈다(E1 총
   58.65s 중 상당분). 파일 간 `_state` 공유이므로 실행 순서에 따라 한쪽의 fixture 누수가
   다른 쪽을 오염시킬 여지가 있다(현재는 둘 다 `try/finally` 로 복원하므로 안전).
   session fixture 로 묶는 편이 낫다.

7. **`select_lane` 반환의 위치 순서 함정** (R-a) — 미래의 위치 분해가 축과 산문을 조용히
   맞바꾼다.

8. **`policy.jl` 의 `route()` 안 `drives = have_det && router_enabled() && POLICY != "noop"`
   (`:468`)는 그대로다.** 그래서 `rt["enabled"]` 는 여전히 교정 파일에 묶여 있고,
   `run_demo.jl:273` 의 화면 출력(`get(rt,"enabled",false) && println("[router] …")`)은
   **어휘 미달로 레인이 바뀐 사건에서 한 줄도 안 찍힌다.** 화면만 보면 라우터가 안 돈 것처럼
   보인다 — 이 레포가 "로그에 안 떴다 ≠ 안 일어났다" 로 이미 두 번 데인 모양이다.
