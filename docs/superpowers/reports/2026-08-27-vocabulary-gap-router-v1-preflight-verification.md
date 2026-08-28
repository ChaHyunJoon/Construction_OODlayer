# PRE-FLIGHT VERIFICATION — Plan V1 (어휘 미달 라우터)

**Agent:** `vocab-router-validator` · **Date:** 2026-08-27 · **Truth = working tree** (HEAD `b6fa718c`, dirty)
**Verified nothing was modified in the repo.** All experiments ran in
`/tmp/claude-1035/-home-chahj578/3fe780b8-4525-4eeb-8890-279efd9a6e27/scratchpad/`.

**Tally:** CONFIRMED 19 · REFUTED 8 · UNVERIFIABLE 1

---

## 요약 판정표

| # | Verdict | 한 줄 |
|---|---|---|
| E1 | CONFIRMED | pytest 9.1.1 |
| E2 | CONFIRMED | Julia 1.10.11 |
| E3 | **REFUTED (부분)** | `sys.exit(1)` 은 **키가 없을 때만**. 키가 있으면 종료가 아니라 **호출**이 난다. 그리고 그 파일은 **Anthropic** 레인이라 확정 삭제 대상이다 |
| E4 | CONFIRMED | `import numpy, sklearn.ensemble` = line 44, `import dspy` = line 46 |
| T1a | **REFUTED (라인번호)** | 코드는 존재하나 **455/457**, 계획서·설계서의 `:446` 은 틀렸다 |
| T1b | CONFIRMED | `{0: [], 1: ['ReplaceAgent'], 2: ['SwapBattery']}` |
| T1c | CONFIRMED | `psi(0) == psi(99)` → True |
| T1d | CONFIRMED | `psi` 는 dict 반환, 세 값 전부 일치 |
| T1e | CONFIRMED (위험 없음) | 라벨셋 macro 고유값 = `{0,1,2}`, 어휘 밖 id **0건**. KeyError 주입 실험에서 회귀 0 |
| T2a | CONFIRMED | `(lane, reason)`, `axis` 없음 |
| T2b | CONFIRMED | `if novel`(36) 이 `if !supported`(43) 보다 앞 |
| T2c | CONFIRMED (실측) | 기존 24 단언 전부, 제안 문구로 교체한 구현에서 통과 |
| T2d | CONFIRMED | `runtests.jl` 에 `test_lane_select` 0회 = 고아 게이트 |
| T2e | **REFUTED** | Julia 1.10 에서 로컬 `const` 는 **문법 에러**. 파일 전체가 파싱 실패 |
| T2f | CONFIRMED (실측) | include 배선 정상, 충돌·world-age 없음 (24 pass) |
| T3a | CONFIRMED | `policy.jl:1064` |
| T3b | CONFIRMED | `"enabled" => drives`(:404 등), `drives`(:439) |
| T3c | CONFIRMED | `if get(rt,"enabled",false)` = `:1044`, 변수 5개 전부 스코프에 존재, **잃는 줄 없음** |
| T3d | CONFIRMED | `POLICY`(:18) · `router_enabled()`(:109) 같은 파일 스코프 |
| T3e | CONFIRMED | `escalation_target(pol, requested, allowed) -> (String, Vector{String})` |
| T3f | CONFIRMED (실측 4/4) | ✅ 계획서가 "이미 통과한다"고 적은 것이 옳다 |
| T3f' | **REFUTED (배선)** | 그 파일에는 `@testset` 도 `using Test` 도 **없다**. 그리고 파일 끝이 `exit()` 라 "마지막 뒤에" 붙이면 **죽은 코드** |
| T4a | CONFIRMED | `dspy_service.py:466` |
| T4b | CONFIRMED | `health()` 무인자 호출 가능, Dict 반환 |
| T4c | CONFIRMED | `kind` 만 필수. `valid`·`nl` 존재 |
| T4d | CONFIRMED | 시그니처·467줄 일치, 2-튜플 반환 |
| T4e | CONFIRMED | `e1_analyze.MACRO_NAME` 존재, 모듈 레벨에서 sys.path 배선됨 |
| T4f | CONFIRMED (조건부) + **RISK** | 지금은 네트워크를 **안 탄다**(LM 미설정 → ValueError). `dspy.configure` 한 번이면 유료 호출 |
| T4g | **REFUTED (치명)** | import 직후 `_state` 에 `surro_support` **키 자체가 없다**. `_state["surrogate"]` 도 `None` |
| T5a | CONFIRMED | support = `{0,1,2}` = 어휘 전체 |
| T5b | CONFIRMED | `MACRO_NAME == {0:'NOOP',1:'Replace',2:'SwapBattery'}` — MENU 와 정확히 일치. **항진명제 아님** |
| T5c | CONFIRMED (실측) | `support={0}` → `['Replace','SwapBattery']` 그 순서 |
| X1 | CONFIRMED (충돌 없음) | `scorable` 이 레지스트리 id 로만 만들어져 `psi` 가 미등록 id 를 절대 못 본다 |
| X2 | CONFIRMED (안전) | `select_lane` 소비처는 `policy.jl:1045` 와 테스트 둘뿐. 전부 이름 접근 |
| X3 | **REFUTED (부분)** | 스키마 검사는 없다. 그런데 `run_demo.jl:322-335` 가 **명시 화이트리스트**라 `router_axis` 는 결정 행에 **안 실린다** |
| — | UNVERIFIABLE | Task 5 Step 2 의 "1번 임시 개변 → 빨개진다" 중 `test_decide_...` 부분 (T4g 때문에 그 테스트가 애초에 통과하지 않으므로 음성 대조를 아직 못 만든다) |

---

## 상세

### 환경

#### E1 — pytest 9.1.1
```
$ .venv/bin/python -m pytest --version
pytest 9.1.1
```
**VERDICT: CONFIRMED**

#### E2 — julia +lts = 1.10.x
```
$ julia +lts --project=. -e 'println(VERSION)'
1.10.11
```
(juliaup 이 1.10.12 로 업데이트하라는 안내를 매 실행 stderr 에 찍는다 — 무해하지만 출력 파싱하는 게이트를 만들면 걸린다.)
**VERDICT: CONFIRMED**

#### E3 — `test_propose.py` 는 import 시점에 `sys.exit(1)` 하고 수집하면 유료 호출 위험
읽은 것 (`src/respec/llm_service/test_propose.py`, 48줄):

```
32: from fastapi.testclient import TestClient
33: import server
35: if not os.environ.get("ANTHROPIC_API_KEY"):
39:     sys.exit(1)
44: client = TestClient(server.app)
45: resp = client.post("/propose", json={...})
```

**VERDICT: REFUTED (부분) — 주장이 두 사건을 하나로 뭉갠다.**
그 파일은 **두 경우 중 하나만** 한다:
- 키가 **없으면** → `sys.exit(1)` (수집 시 collection error, 유료 호출 **없음**)
- 키가 **있으면** → `sys.exit` 에 도달조차 안 하고 **line 45 에서 실제 POST 가 나간다**

즉 "sys.exit 도 하고 유료 호출 위험도 있다" 가 아니라 **배타적**이다.
🔴 그리고 더 중요한 것: 그 경로는 **Anthropic 레인**이다 (`/propose` → `propose.py`).
사용자 결정 및 MEMORY(`llm-lane-is-dspy-only`)에 따르면 `propose.py` · `test_propose.py` 는
**선택지가 아니라 확정된 삭제 대상**이다. `--ignore` 로 매번 우회하는 것은 그 결정의 이행이 아니다.
**권고: 계획서의 `--ignore` 규약을 "이 파일을 지운다" 로 바꿀 것.** 지우면 규약 자체가 사라진다.
그 파일을 **수집시키지 않았다** (읽기만 했다).

#### E4 — numpy/sklearn 이 dspy 보다 앞
```
44: import numpy, sklearn.ensemble  # noqa: F401  -- 순서 고정: dspy 보다 먼저 ...
46: import dspy
```
**VERDICT: CONFIRMED.** 계획서의 line 44/46 인용도 작업 트리 기준으로 정확하다
(이 파일은 미커밋 변경이 있는데도 그 두 줄의 줄번호가 그대로다).

---

### Task 1

#### T1a — `psi()` 안의 `.get` + `if not names`
```
440: def psi(action):
455:         names = MACRO_SPECS.get(int(action), [])
457:     if not names:                                  # NOOP
```
**VERDICT: REFUTED (라인번호).** 코드는 있고 구조도 주장대로다. 그러나
**계획서 Task 1 "왜" 절과 설계서 §2-3 이 인용한 `features_agnostic.py:446` 은 틀렸다** — 실제는 455/457.
계획서 Files 절의 `:440-458` 범위는 우연히 맞다(`psi` 가 440 에서 시작).
👉 실행자는 `:446` 을 보고 "여기 없는데?" 로 시간을 버린다. 계획서를 고칠 것.

#### T1b — `MACRO_SPECS == {0: [], 1: ['ReplaceAgent'], 2: ['SwapBattery']}`
```
MACRO_SPECS = {0: [], 1: ['ReplaceAgent'], 2: ['SwapBattery']}
0 in keys: True   value: []
```
**VERDICT: CONFIRMED.** 0 은 키로 존재하고 값이 빈 리스트다 →
계획서의 "truthiness 가 아니라 멤버십" 논증이 옳다.

#### T1c — `psi(0) == psi(99)`
```
psi(0)  = {a_cost:0.0, a_intervenes:0.0, a_soft:0.0, a_restores_capacity:0.0,
           a_relocates_work:0.0, a_spatial:0.0, a_n_specs:0.0, a_consumes_spare:0.0,
           a_reversible:1.0, a_scope:0.0}
psi(99) = (동일)
psi(0)==psi(99): True
```
**VERDICT: CONFIRMED.**

#### T1d — 계획서 테스트가 단언하는 값들
```
type psi(0): <class 'dict'>          ← dict 를 돌려준다 (벡터 아님)
psi(['ReplaceAgent'])['a_intervenes'] = 1.0     ✓
psi(0)['a_intervenes']               = 0.0      ✓
psi(0)['a_reversible']               = 1.0      ✓
set(psi(0)) == set(PSI_AXES)         = True     ✓
PSI_AXES = ['a_cost','a_intervenes','a_soft','a_restores_capacity','a_relocates_work',
            'a_spatial','a_n_specs','a_consumes_spare','a_reversible','a_scope']
```
**VERDICT: CONFIRMED.** 네 단언 전부 성립하고 `PSI_AXES` 에 그 키들이 있다.

#### T1e — 🔴 Step 5 의 위험: 라벨셋에 어휘 밖 macro id 가 있나
현행 라벨셋 = `wm4spacecraft_manufacturing/oracle/out/oracle_dataset.jsonl`
(`wm_datasets.ORACLE_DATASET` = `oracle/out/oracle_dataset.jsonl`, `dspy_service.py:241`).
```
raw rows: 33
macro Counter: {0: 12, 1: 12, 2: 9}
fired: {True: 33}     vocab: {'v4-3arms': 33}
```
**어휘 밖 id 0건.**

**음성 대조 (직접 만들었다):** `/tmp` 에 pytest 플러그인을 만들어
`features_agnostic.psi` 를 **Task 1 이 하려는 그대로**(미등록 id → KeyError) 몽키패치한 뒤
전체 pytest 스위트를 돌렸다.
```
$ PYTHONPATH=<scratch> .venv/bin/python -m pytest src/respec/llm_service/ \
    wm4spacecraft_manufacturing/ -q -p psi_strict --ignore=.../test_propose.py
3 failed, 79 passed          ← 패치 전과 동일 (아래 B1)
```
**VERDICT: CONFIRMED — Task 1 의 KeyError 는 추가 회귀를 0건 만든다.**
⚠️ 단, 이 플러그인은 in-process 만 덮는다. 서브프로세스를 띄우는 테스트는 안 덮였다.

⚠️ **그런데 어휘 밖 팔이 다른 곳에 살아 있다** (아래 RISK-3): B1 의 실패 3건이
`arms_seen=[0, 1, 2, 3]` 을 찍는다 — **팔 id 3** 은 `v4-3arms` 어휘에 없다.
`psi` 경로가 아니라 `T_done` 경로라 Task 1 이 안 잡을 뿐이다.

---

### Task 2

#### T2a — 현재 시그니처와 본문 전문
`tools/monitor/lane_select.jl:17-59` (전문):

```julia
"""
    select_lane(; novel, available, supported, policy) -> (lane, reason)

- `novel`     : novelty 판정 (p < eps)
- `available` : 레인 가용성 Dict, 예 `Dict("surrogate"=>true, "dspy"=>false, "canonical"=>true)`
- `supported` : surrogate 가 이 사건에 필요한 팔을 학습셋에서 지원하는가
- `policy`    : DEMO_POLICY. `"noop"` 이면 라우팅하지 않는다(통제 바닥선)

`reason` 은 화면 ROUTER 줄에 그대로 나가므로 영어로 쓴다(이 저장소의 화면 문구 규약).
"""
function select_lane(; novel::Bool, available::AbstractDict, supported::Bool,
                     policy::AbstractString)
    up(k) = get(available, k, false) === true

    policy == "noop" && return (lane = "noop",
        reason = "no-adapt floor — routing disabled for this control lane")

    if novel
        up("dspy") && return (lane = "dspy",
            reason = "novelty p < eps — never seen this before → ask the LLM")
        return (lane = "canonical",
            reason = "novelty p < eps → LLM, but the LLM lane is unavailable → canonical rule")
    end

    if !supported
        up("dspy") && return (lane = "dspy",
            reason = "familiar, but the surrogate has no training support for this arm → escalate to LLM")
        return (lane = "canonical",
            reason = "familiar, but the surrogate has no training support for this arm " *
                     "and the LLM lane is unavailable → canonical rule")
    end

    up("surrogate") && return (lane = "surrogate",
        reason = "novelty p ≥ eps — familiar → surrogate")

    up("dspy") && return (lane = "dspy",
        reason = "familiar, but the surrogate lane is unavailable → LLM")

    return (lane = "canonical",
        reason = "familiar, but both the surrogate and LLM lanes are unavailable → canonical rule")
end
```
**VERDICT: CONFIRMED.** `(lane, reason)` NamedTuple, `axis` 필드 없음.

#### T2b — `novel` 을 `supported` 보다 먼저 본다
`if novel` = **line 36**, `if !supported` = **line 43**. **VERDICT: CONFIRMED.**

#### T2c — 기존 `reason` 단언이 새 문구에도 다 들어 있나
기존 파일의 `reason` 단언 **전수 인용** (`test_lane_select.jl`):

| 줄 | 입력 | 단언 | 새 문구 | 포함? |
|---|---|---|---|---|
| 14 | `novel=true, sup=true, ALL_UP` | `occursin("novel", …)` | `"novelty p < eps — never seen this before → ask the LLM"` | ✅ |
| 19 | `novel=false, sup=true, ALL_UP` | `occursin("familiar", …)` | `"arms are supported and the state is familiar → surrogate"` | ✅ |
| 24 | `novel=false, sup=false, ALL_UP` | `occursin("support", …)` | `"the surrogate has no training support for this arm → escalate to LLM"` | ✅ |
| 30 | `novel=false, sup=false, dspy↓` | `occursin("canonical", …)` | `"… → canonical rule"` | ✅ |
| 31 | 〃 | `occursin("unavailable", …)` | `"… the LLM lane is unavailable → …"` | ✅ |
| 64 | 전 조합 8개 | `!isempty(r.reason)` | 모든 분기가 비지 않음 | ✅ |

**실측 (읽기만 하지 않았다):** `/tmp` 에 계획서의 새 `select_lane` 을 그대로 놓고
**레포의 기존 테스트 파일을 그대로 복사**해 돌렸다:
```
3-way 분기                  | 11 pass
noop 은 라우팅 대상이 아니다  |  1 pass
DP 는 절대 타깃이 아니다      |  4 pass
reason 은 언제나 비지 않는다  |  8 pass       (합 24/24)
```
**음성 대조:** 같은 구현에서 surrogate 문구의 `"familiar"` 만 지우고 line 19 단언을 돌리면
```
Test Summary:    | Fail  Total
negative control |    1      1
```
→ 이 검사는 실패할 수 있다.

**VERDICT: CONFIRMED.** ⚠️ 사소한 정정: 계획서는 "reason 단언 **넷**" 이라 적는데
실제 `occursin` 호출은 **다섯**이다(30·31 이 같은 케이스라 넷으로 셌다면 그건 맞다).

#### T2d — `test_lane_select.jl` 이 고아 게이트인가
```
$ grep -n "lane_select" test/runtests.jl
(출력 없음)
```
`runtests.jl` 이 include 하는 15개 파일 목록에 없다. **VERDICT: CONFIRMED.**

#### T2e — 🔴 `@testset` 안의 `const UP = Dict(...)`
```julia
using Test
@testset "const in local scope" begin
    const UP = Dict("a" => true)
    @test UP["a"]
end
```
```
ERROR: LoadError: syntax: unsupported `const` declaration on local variable around …:3
```
**VERDICT: REFUTED.** Julia 1.10 에서 로컬 스코프의 `const` 는 **문법 에러**다.
그리고 이건 런타임 실패가 아니라 **파싱 실패**라 파일 전체가 죽는다 — 계획서대로 붙이면
**기존 testset 4개도 같이 안 돈다.** "실패를 확인한다"(Step 2) 에서 나올 것은
계획서가 예고한 `type NamedTuple has no field axis` 가 아니라 이 syntax error 다.

**올바른 형태 — `const` 를 그냥 빼고 로컬 변수로:**
```julia
@testset "어휘 미달이 novelty 보다 먼저다 (2026-08-27, 축 1)" begin
    UP = Dict("surrogate" => true, "dspy" => true, "canonical" => true)
    ...
end
```
(또는 파일 최상위로 올려 `const UP2 = …`. 다만 최상위 `const ALL_UP` 이 이미 있으므로
이름이 겹치지 않게 할 것.)

**교정본 실측:** `const` → 로컬로 바꾼 계획서의 새 testset 12 단언을 계획서의 새
`select_lane` 에 대해 돌리면 **12/12 pass**. 즉 축 판정 로직 자체는 옳다.

#### T2f — 로드 방식과 include 배선의 충돌
`test_lane_select.jl:6` = `include(joinpath(@__DIR__, "lane_select.jl"))` (모듈 없음, 최상위).
`policy.jl:27` 도 같은 파일을 include 한다. 그리고 `runtests.jl` 은
`policy_macro_binding.jl`(:94) 과 `route_descriptors_survive.jl`(:102) 을 통해 `policy.jl` 을
**이미 두 번** 로드한다.

**실측 실험:** `policy.jl` 을 먼저 로드한 뒤 계획서가 제안한 `@testset` + `include` 배선으로
`test_lane_select.jl` 을 넣어 돌렸다:
```
outer | 24 pass / 24
```
- `const ALL_UP`(파일 최상위) 은 `include` 가 **모듈 최상위에서 평가**하므로 `@testset` 블록
  안이어도 로컬이 되지 않는다 → T2e 의 함정에 안 걸린다.
- `select_lane` 재정의 경고 없음, world-age 에러 없음.
- 실제 `runtests.jl` 은 `policy.jl` 을 각각 **서브모듈**(`Main.RouteDescriptorsSurvive` 등)
  안으로 넣으므로 `Main.select_lane` 은 애초에 한 번만 정의된다 — 더 안전하다.

**VERDICT: CONFIRMED (계획서 Step 5 의 배선은 작동한다).**

---

### Task 3

#### T3a — `escalation_allowed = get(rt, "enabled", false)`
```
tools/monitor/policy.jl:1064:    escalation_allowed = get(rt, "enabled", false)
```
**VERDICT: CONFIRMED** (계획서의 `:1064` 도 정확).

#### T3b — `rt["enabled"]` 의 출처
```
policy.jl:439:  drives = have_det && router_enabled() && POLICY != "noop"
policy.jl:~386/392/404:  "enabled" => false / false / drives     (route_verdict 의 세 분기)
policy.jl:431:  have_det = install_novelty!()
```
**VERDICT: CONFIRMED.** `have_det` 이 없으면 `enabled` 는 `false` 로 **하드코딩**되므로
(첫 두 분기) 교정 파일이 없으면 어휘 미달 격상은 열릴 수 없다 — 계획서의 진단이 옳다.

#### T3c — `select_lane` 호출 전체가 그 게이트 안에 있나 (전문)
`tools/monitor/policy.jl:1033-1052`:
```julia
    requested = get(rt, "enabled", false) ? String(rt["target"]) : POLICY
    local avail = Dict{String,Bool}(k => (haskey(pol, k) && pol[k]["available"] === true)
                                    for k in ("canonical", "surrogate", "dspy", "noop"))
    # surrogate 가 이 사건의 팔을 학습셋에서 지원하는가 = 기존 에스컬레이션 판정과 **같은 근거**
    # (`escalation_target` 의 `unsupported` 목록). 프로브 대상은 **언제나 surrogate** 다 —
    # `requested` 로 물으면 라우터가 이미 dspy 를 고른 사건에서 "지원됨" 이 나와 분기가 뒤집힌다.
    local _esc_probe, _esc_miss = escalation_target(pol, "surrogate", true)
    local supported = isempty(_esc_miss)

    enacted = requested
    fell_back = false
    if get(rt, "enabled", false)
        local sel = select_lane(novel = get(rt, "novel", false) === true, available = avail,
                                supported = supported, policy = POLICY)
        enacted = sel.lane
        # 기존 문구를 **덮어쓰지 않고 덧붙인다** — novelty 수치가 든 줄이 화면에서 사라지면 안 된다.
        rt["reason"] = get(rt, "reason", "") * " · LANE: " * sel.reason
        rt["lane_reason"] = sel.reason
        fell_back = (enacted != requested && enacted == "canonical")
    end
```
계획서는 `:1044` 라 적고 실제도 **1044**. 스코프 확인:
`requested`(1033) · `avail`(1034) · `supported`(1040) · `enacted`(1042) · `fell_back`(1043)
**전부 존재한다.**

**계획서 교체 코드가 잃는 줄: 없다.** 현재 블록의 5개 실행문(sel · enacted · rt["reason"] ·
rt["lane_reason"] · fell_back)이 전부 보존되고 `rt["router_axis"]` 한 줄만 추가된다.
**VERDICT: CONFIRMED.**

🔴 **다만 계획서가 안 적은 부작용이 있다 — `requested` 는 안 고친다.** 아래 RISK-1 참조.

#### T3d — `router_enabled()` · `POLICY` 접근 가능성
```
policy.jl:18:   const POLICY   = lowercase(get(ENV, "DEMO_POLICY", "canonical"))
policy.jl:109:  router_enabled() = ROUTER_MODE == "0" ? false : …
```
둘 다 `decide_all` 과 **같은 파일·같은 스코프**. **VERDICT: CONFIRMED.**

#### T3e — `escalation_target` 시그니처
```julia
"""
    escalation_target(pol, requested, allowed) -> (target::String, missing::Vector{String})
"""
function escalation_target(pol, requested, allowed)
    haskey(pol, requested) || return ("", String[])
    local missing = String.(collect(get(pol[requested], "unsupported", String[])))
    isempty(missing) && return ("", missing)   # ← 실제로는 return ("", String[])
    (allowed && requested != "dspy" &&
     haskey(pol, "dspy") && pol["dspy"]["available"]) || return ("", missing)
    return ("dspy", missing)
end
```
인자 3개, 2-튜플 반환. **VERDICT: CONFIRMED.**

#### T3f — "이 testset 은 이미 통과한다" 가 맞나
`escalation_target` 은 `get(pol[requested], "unsupported", String[])` 로 정확히 그 모양을 읽는다.
**실측** — 계획서의 testset 을 `/tmp` 에 그대로 옮겨 실제 `policy.jl` 에 대고 돌렸다:
```
어휘 미달 격상은 novelty 교정과 무관하다 (2026-08-27) | 4 pass / 4
```
**VERDICT: CONFIRMED — 계획서가 "실패를 봤다고 적지 말 것" 이라 정직하게 적은 것이 옳다.**

#### T3f′ — 🔴 그런데 **그 testset 을 그 파일에 넣을 수 없다** (계획서가 안 본 것)
`tools/test_policy_escalation.jl` 의 실제 구조:
```julia
module TestPolicyEscalation
import HTTP, JSON3
include(joinpath(@__DIR__, "monitor", "policy.jl"))
npass = 0; nfail = 0
function check(name, ok, detail = "") … end
…
println(nfail == 0 ? "전부 통과 ($(npass))" : "…")
exit(nfail == 0 ? 0 : 1)          # ← 파일의 마지막 실행문
end # module
```
```
$ grep -n "using Test\|@testset\|@test " tools/test_policy_escalation.jl
(출력 없음)
```
**VERDICT: REFUTED.**
1. 그 파일에는 `@testset` 이 **하나도 없다.** 계획서의 *"그 파일의 마지막 `@testset` 뒤에 추가"* 는
   존재하지 않는 앵커를 가리킨다.
2. `using Test` 가 없어 `@testset`/`@test` 매크로가 **정의되지 않았다.**
3. 파일 끝이 `exit(...)` 라 **그 뒤에 붙이면 절대 실행되지 않는다** — 정확히 이 레포가 반복해서
   데인 "실패할 수 없는 게이트" 다.

**올바른 형태:** ① 상단에 `using Test` 를 더하고, ② `println`/`exit` **앞에** testset 을 넣거나,
③ 더 정직하게는 이 파일의 기존 `check(...)` 관용구를 그대로 따른다:
```julia
polV = Dict("surrogate" => Dict("chosen"=>"NOOP", "available"=>true,
                                "unsupported"=>["SwapBattery"]),
            "dspy"      => Dict("chosen"=>"SwapBattery", "available"=>true))
tv, mv = escalation_target(polV, "surrogate", true)
check("V1 어휘 미달은 교정과 무관하게 격상한다", tv == "dspy" && mv == ["SwapBattery"],
      "target=$(tv) missing=$(mv)")
tv2, mv2 = escalation_target(polV, "surrogate", false)
check("V1b 손잡이를 끄면 레인은 안 바뀌지만 진단은 남는다",
      tv2 == "" && mv2 == ["SwapBattery"], "target=$(tv2) missing=$(mv2)")
```
(이러면 `exit(nfail == 0 ? 0 : 1)` 의 카운트에 실제로 실린다.)

---

### Task 4

#### T4a — `set(range(5))` 폴백
```
dspy_service.py:466:        support = _state.get("surro_support") or set(range(5))
```
**VERDICT: CONFIRMED** (계획서의 `:466` 정확).
🔴 추가: `or` 이므로 `set()`(빈 집합) 도 `{0,1,2,3,4}` 로 무너뜨린다 —
"아무 팔도 지원 안 한다" 가 "전부 지원한다" 가 된다. 계획서가 짚은 `None` 사례보다 더 나쁘다.

#### T4b — `health()`
```
dspy_service.py:670: @app.get("/health")
dspy_service.py:671: def health():
```
```
health sig: ()
health callable directly: True
health() = {'status':'ok', 'policy':'dspy:gpt-4o', 'program':'(seed only)',
            'demos':0, 'calls':0, 'surrogate':'ERROR: None', 'policies':['dspy','surrogate']}
```
FastAPI 의 `@app.get(...)` 은 **원함수를 그대로 반환**하므로 직접 호출 가능.
**VERDICT: CONFIRMED.**
⚠️ 부수 관찰: import 직후 `surrogate` 필드가 `'ERROR: None'` 이다 —
`_state["surro_data"] or ("ERROR: " + str(_state["surro_error"]))` 가 "안 재봤다"(None) 를
"에러였다" 로 렌더한다. 이 레포가 반복해서 데인 `nothing`/`false` 혼동의 살아 있는 사례.

#### T4c — `MacroRequest(kind="battery", soc=0.1)`
필수 필드는 **`kind: str` 하나뿐**(나머지 전부 기본값). `valid: Optional[List[str]]` 과
`nl: Optional[str]` 둘 다 선언돼 있다.
```
MacroRequest(kind='battery', soc=0.1)      → ok, valid=None, nl=None
MacroRequest(kind='battery', soc=0.1, valid=['NOOP','Replace','SwapBattery'], nl='x')
                                            → valid=['NOOP','Replace','SwapBattery']
_valid_for(req)  = ['NOOP','Replace','SwapBattery']     (valid 없어도 kind 폴백이 같은 메뉴)
MACROS           = ['NOOP','Replace','SwapBattery']
```
**VERDICT: CONFIRMED.**

#### T4d — `surrogate_rank` 시그니처와 `name2id`
```python
446: def surrogate_rank(req: "MacroRequest", valid: List[str]):
461:     model = _state["surrogate"]
462:     if model is None:
463:         return None, _state["surro_error"] or "surrogate not loaded"
464:     try:
465:         from e1_analyze import MACRO_NAME as MN
465:         name2id = {v: k for k, v in MN.items()}
466:         support = _state.get("surro_support") or set(range(5))
467:         unsupported = [m for m in valid if m in name2id and name2id[m] not in support]
```
(실제 465줄이 `name2id = …`, `from e1_analyze …` 는 464줄 바로 뒤. 위 표기는 근사)
모든 return 경로가 **2-튜플**이다 (`(None, err)` 또는 `(scored, err_or_None)`).
**VERDICT: CONFIRMED.**

🔴 **그러나 계획서가 못 본 순서 문제:** `model is None` 검사가 **`support` 검사보다 앞**이다.
Task 4 Step 3 이 넣으려는 `if support is None: return None, "… support is unknown …"` 은
`model` 이 None 인 상황에서는 **도달 불가**다. → T4g 와 합쳐 아래 REFUTED 로.

#### T4e — `from e1_analyze import MACRO_NAME as MN`
```
파일: wm4spacecraft_manufacturing/core/e1_analyze.py:96
       MACRO_NAME = dict(_reg.MACRO_NAME)
```
`dspy_service.py:63-65` 가 **모듈 레벨에서** `WM_CODE_DIRS`(= `core/`, `surrogate/`) 를
`sys.path` 에 append 한다. 따라서 `import dspy_service` 만으로도 그 import 는 성공한다:
```
from e1_analyze import MACRO_NAME as MN
MACRO_NAME = {0: 'NOOP', 1: 'Replace', 2: 'SwapBattery'}
```
`surrogate_rank` 안의 기존 `name2id` 도 **같은 출처**다(같은 import 문).
**VERDICT: CONFIRMED.**
⚠️ 단 계획서의 `_unsupported_for` 는 그 import 를 **try/except 밖**에 둔다.
기존 `surrogate_rank` 는 `try:` 안에 있어서 실패해도 `(None, "ImportError: …")` 로 삼켰다.
도우미로 옮기면 **예외가 호출부로 그대로 튄다** — 지금은 성공하므로 무해하지만
계약이 바뀐다는 사실은 계획서에 없다.

#### T4f — `svc.decide(_req())` 가 네트워크를 타나
읽은 경로: `decide(req)` → `macro(req)` → `prog = _state["program"] or _load_program()` →
`prog(state=line, valid_actions=…)`.
- `dspy.configure(lm=…)` 는 **`@app.on_event("startup")` 의 `_startup()` 안에만** 있다(`:332`).
- 순수 import 세션에서는 `dspy.settings.lm is None`.
- 확인 실험(서비스와 무관한 최소 dspy 프로그램, API 키 제거):
  ```
  lm: None
  raised: ValueError  No LM is loaded. Please configure the LM using `dspy.configure(...)`
  ```
- `macro()` 의 `except Exception` 이 그것을 잡아 `err` 로 만들고 `chosen=""` 로 진행한다.

**VERDICT: CONFIRMED — 현재 상태에서 `decide()` 는 인자 하나로 호출 가능하고 네트워크를 안 탄다.**

🔴 **그러나 이건 한 줄 차이로 뒤집힌다 (RISK-2).** 이 셸에 `OPENAI_API_KEY` 가 **설정돼 있다**.
같은 pytest 프로세스에서 누군가 `dspy.configure` 를 부르거나(FastAPI `TestClient`,
`_startup()` 직접 호출) `DSPY_PROGRAM` 이 실제 파일을 가리키면, `test_decide_carries_the_gap_to_julia`
가 **매 실행마다 gpt-4o 유료 호출**을 낸다.
**권고 대안 (둘 다 하는 것이 낫다):**
1. 그 테스트에서 dspy 레인을 못 타게 못박는다 — `monkeypatch.setattr(svc, "macro",
   lambda req: {"chosen":"", "ranking":[], "margin":0.0, "reasoning":"", "coerced":False,
   "error":"stubbed"})`. 그러면 검사 대상(`out["surrogate"]["unsupported"]`)만 남는다.
2. 또는 `decide` 를 아예 부르지 않고 `surrogate_rank(req, MENU)` 가 돌려주는
   `"UNSUPPORTED:SwapBattery"` 문자열을 직접 단언한다 — `decide` 의 파싱은
   `str(err).split(":",1)[1].split(",")` 한 줄이라 그것이 진짜 계약이다.

#### T4g — 🔴 import 직후 `_state["surro_support"]` 가 채워져 있나
```
--- state right after `import dspy_service` ---
   program = None
   instructions = None
   demos = 0
   calls = 0
   surrogate = None
   surro_feats = None
   surro_data = None
   surro_error = None
surro_support key present: False        ← 🔴 키 자체가 없다
_state.get("surro_support"): None
```
`_state` 초기값(`dspy_service.py:192-193`)에 `surro_support` 가 **없고**,
`_load_surrogate()` 는 `@app.on_event("startup")` 안에서만 불린다(`:336`).

**VERDICT: REFUTED — 계획서·테스트가 전제한 상태가 import 시점에 존재하지 않는다.**

**귀결 (전부 실측):**
```
# import 직후, _load_surrogate() 를 안 부른 상태
surrogate_rank(req, MENU) == (None, 'surrogate not loaded')
```
1. **Task 4 `test_no_stale_literal_fallback_when_support_is_missing` 은 Step 3 을 구현해도 실패한다.**
   `model is None` 이 먼저 걸려 `err = "surrogate not loaded"` 가 나오고,
   `assert "support" in err.lower()` 는 **거짓**이다 (`"surrogate not loaded"` 에 `support` 없음).
2. **Task 5 `test_decide_carries_the_gap_to_julia` 도 실패한다.**
   `surrogate_rank` 가 `(None, "surrogate not loaded")` → `decide` 의 else 분기 →
   `"unsupported"` 는 `err.startswith("UNSUPPORTED:")` 가 거짓이라 **`[]`** 가 된다.
   단언은 `== ["SwapBattery"]`.
3. **Task 5 `test_health_reports_the_reduced_support` 는 Step 3 구현 후 통과한다**
   (`health()` 는 `_state` 만 읽으므로).
4. **fixture 의 `saved = None` 복원**: `_state["surro_support"] = None` 은 복원이 아니라
   **없던 키를 None 으로 새로 만든다.** 그 뒤 Task 4 의 새 폴백이 살아 있으면
   `surrogate_rank` 는 (모델이 적재된 세션에서) "support unknown" 으로 거부하게 된다.
   지금은 `_state["surrogate"]` 도 None 이라 증상이 안 나지만, **서비스를 띄운 뒤 같은
   프로세스에서 이 테스트를 돌리면 뒤 테스트가 줄줄이 깨진다.**

**어떻게 해야 하나 — 권고:**
- 두 테스트 파일 모두 모듈 최상위(또는 세션 fixture)에서 **`svc._load_surrogate()` 를 명시적으로 부른다.**
  네트워크를 안 타고 33행 적합이라 1초 미만이다. 실측:
  ```
  svc._load_surrogate()
  surro_support = {0, 1, 2}
  surro_error   = None
  surro_data    = oracle_dataset.jsonl (33 rows / 12 instances, macro support [0, 1, 2],
                  rule deadband_Jbar, objective_hash 489268e6659e5ae9, vocab v4-3arms)
  ```
  적재 후에는 계획서가 기대한 대로 동작한다:
  ```
  _state['surro_support'] = {0,1}  →  surrogate_rank(req, MENU) = (scored, 'UNSUPPORTED:SwapBattery')
  ```
  → `decide` 의 `unsupported` 도 `["SwapBattery"]` 가 된다.
- fixture 는 `saved` 대신 **키의 존재 여부**를 저장하고 없었으면 `_state.pop("surro_support", None)`
  로 되돌린다. `None` 을 써 넣으면 "못 쟀다" 를 영구화한다.
- `_state` 초기값에 `"surro_support": None` 을 넣는 편이 정직하다 — 그러면
  "키 없음"(정의 안 됨) 과 "None"(못 쟀다) 을 안 뭉갠다. 계획서에 그 한 줄이 빠져 있다.
- `surrogate_rank` 의 새 `support is None` 검사는 **`model is None` 검사보다 앞으로** 올려야
  계획서가 의도한 대로 발화한다. 지금 위치로는 모델 없는 세션에서 도달 불가다.

---

### Task 5

#### T5a — 지원집합이 정말 `{0,1,2}` = 어휘 전체인가
```
support == [0, 1, 2]      vocabulary(MACRO_NAME) == [0, 1, 2]
labelset macro Counter    == {0: 12, 1: 12, 2: 9}   (33행)
```
**VERDICT: CONFIRMED.** 설계서 §2-2 의 실측이 오늘도 그대로다 —
축 1 은 **발화 영역이 빈 죽은 코드**이고, Task 5 의 음성 대조는 실제로 필수다.

#### T5b — 🔴 `MENU` 의 이름이 `MACRO_NAME` 과 일치하나 (항진명제 여부)
```
action_registry.json  : "0"→NOOP, "1"→Replace, "2"→SwapBattery   (vocab v4-3arms)
e1_analyze.MACRO_NAME : {0: 'NOOP', 1: 'Replace', 2: 'SwapBattery'}   (= dict(_reg.MACRO_NAME))
dspy_service.MACROS   : ['NOOP', 'Replace', 'SwapBattery']
MENU                  : ['NOOP', 'Replace', 'SwapBattery']
```
**세 출처가 전부 같다.** `'ReplaceAgent'` 는 `features_agnostic._MACRO_NAME_SPECS` 의 **값**,
즉 **DSL primitive 이름**이지 매크로 이름이 아니다(그 dict 의 **키**는 `"Replace"` 다).
매크로 이름 축과 primitive 이름 축은 다른 축이고, `psi` 만 후자를 쓴다.

**VERDICT: CONFIRMED — Task 5 는 항진명제가 아니다.** `m in name2id` 는 세 이름 모두 True.

#### T5c — `_unsupported_for(req, MENU)` 의 순서
```
support {0,1,2} -> []
support {0,1}   -> ['SwapBattery']
support {0}     -> ['Replace', 'SwapBattery']      ← 계획서가 단언한 순서 그대로
support None    -> None
```
순서는 `valid`(= MENU) 의 리스트 컴프리헨션 순서에서 나온다 — `support` 가 `set` 이라도
순회 대상이 `valid` 이므로 **결정적**이다.
**VERDICT: CONFIRMED.**

---

### 교차 태스크 충돌

#### X1 — Task 1 의 KeyError 가 `predict_J` 경로에서 발화하나
`surrogate_rank` 의 행 생성은
```python
scorable = [name2id[m] for m in valid if m in name2id and name2id[m] in support]
rows = [_surro_row(req, m) for m in scorable]
```
즉 `rows[i]["macro"]` 는 **언제나 `e1_analyze.MACRO_NAME` 의 키**이고, 그것은
`action_registry.json` 파생이며 `MACRO_SPECS` 도 같은 레지스트리 파생이다.
따라서 `build_features → psi(int(r["macro"]))` 는 **미등록 id 를 볼 수 없다.**
학습 경로(`_load_surrogate → load_rows → SurrogateV2.fit`)도 T1e 에서 라벨셋에 어휘 밖 id 가
0건임을 확인했다.
**VERDICT: CONFIRMED (충돌 없음). Task 5 의 `decide` 테스트는 Task 1 때문에 죽지 않는다.**

#### X2 — `axis` 추가가 다른 소비처를 깨나
```
$ grep -rn "select_lane" src tools test
tools/monitor/lane_select.jl:18,27        (정의)
tools/monitor/test_lane_select.jl:12,17,22,28,34,39,45,52,61   (테스트 9곳)
tools/monitor/policy.jl:1032 (주석), 1045 (유일한 생산 소비처)
```
`policy.jl:1045-1050` 은 `sel.lane` · `sel.reason` 만 **이름으로** 읽는다. NamedTuple 에
필드를 더해도 이름 접근은 안 깨진다(위치 분해 `a, b = sel` 를 하는 곳이 없다).
**VERDICT: CONFIRMED (안전).**

#### X3 — `rt["router_axis"]` 가 스키마 검사에 걸리나
스키마 검사기는 **없다** — `rt` 는 `Dict{String,Any}` 이고 키를 거부하는 검증자를 못 찾았다.
`record_decision!`(`policy.jl:1330`)은 `"router" => decision.router` 로 **Dict 전체**를 싣는다
→ 모니터/렌더 스트림에는 `router_axis` 가 그대로 나간다. ✅

🔴 **그런데 결정 행에는 안 실린다.** `tools/monitor/run_demo.jl:322-335` 는 **명시 화이트리스트**다:
```julia
"router_novel"  => get(decision.router, "novel", nothing),
"router_p"      => get(decision.router, "p", nothing),
"router_target" => get(decision.router, "target", nothing),
"escalated"     => haskey(decision.router, "escalated_from"),
"decision_index"=> …, "deviate_at" => …, …
```
`router_axis` 를 위한 줄이 없고 계획서도 안 더한다.
그리고 같은 파일 `:255-256` 이 **정확히 이 사고**를 기록한다:
> *"policy.jl 에 필드를 하나 추가해도 render_demo.jl 스트림에는 실리고 run_demo.jl 스트림에는
> 안 실리는 조용한 어긋남이 생겼다 — 실제로 라우터 첫 실측에서 이 사고가 났다."*

**VERDICT: REFUTED (부분).** 계획서 Task 3 Interfaces 의
*"`rt["router_axis"]::String` — **결정 행과** 스트림에 남는다"* 중 **결정 행 쪽이 거짓**이다.
`run_demo.jl:326` 부근에 `"router_axis" => (try get(decision.router, "router_axis", nothing) catch; nothing end),`
한 줄을 **같은 커밋에서** 더해야 한다. 안 더하면 설계서 R5(축별 발화 집합)를 **잴 수 없다** —
그리고 그 숫자가 이 계획서의 유일한 산출 지표다.

---

## 기준선 (B1~B6)

| # | 명령 | 결과 |
|---|---|---|
| **B1** | `.venv/bin/python -m pytest src/respec/llm_service/ wm4spacecraft_manufacturing/ -q --ignore=src/respec/llm_service/test_propose.py` | 🔴 **3 failed, 79 passed** (54s) |
| **B2** | `julia +lts --project=. tools/monitor/test_lane_select.jl` | ✅ **24 pass / 24** (11+1+4+8), exit 0 |
| **B3** | `julia +lts --project=. tools/test_policy_escalation.jl` | ✅ **12/12 "전부 통과"**, exit 0 |
| **B4** | `julia +lts --project=. test/policy_macro_binding.jl` | ✅ **40 pass / 40** (28.8s), exit 0 |
| **B5** | `julia +lts --project=. test/route_descriptors_survive.jl` | ✅ **17 pass / 17**, exit 0 |
| **B6** | `julia +lts --project=. test/battery_menu_lanes_agree.jl` | ✅ **6 + 3 + 3 = 12 pass**, exit 0 |

### 🔴 B1 은 기준선부터 빨갛다 — 계획서의 "전부 PASS" 는 이미 거짓
실패 3건 전부 `wm4spacecraft_manufacturing/smdp/test_gate_ng2.py`:
```
FAILED test_gate_ng2.py::test_healthy_agreement_passes
FAILED test_gate_ng2.py::test_healthy_disagreement_fails
FAILED test_gate_ng2.py::test_spread_over_3_is_reported_but_is_not_the_verdict
```
게이트 자신의 출력:
```
RESOLUTION arms_seen=[0, 1, 2, 3] …
FAIL: 사건 0 의 팔 id 3 가 현행 어휘(v4-3arms)의 활성 팔이 아니다   (사건 0~5 전부)
SPREAD ratio_p90/ratio_p10=3.520 limit=3.0 -> 🔴 스칼라 ρ 하나로 부족하다
🔴 분해 불가 — 이 게이트는 지금 아무것도 못 본다. 초록도 빨강도 증거가 아니다.
```
Plan V1 의 **Task 1 Step 5 / Task 4 Step 5 / Task 5 Step 3 이 전부 "Expected: 전부 PASS" 라 적는다.**
그대로 따르면 실행자는 이 기준선 빨강을 자기가 낸 회귀로 오진한다.
👉 계획서를 **"3 failed / 79 passed 를 유지한다(test_gate_ng2 3건은 기존 결함)"** 으로 고칠 것.

### 부수 관찰
`src/respec/llm_service/` 에는 **pytest 가 수집할 파일이 하나도 없다**
(`test_propose.py` 는 `--ignore` 대상). 즉 B1 의 79 pass 는 전부 `wm4spacecraft_manufacturing/` 것이고,
계획서 명령의 첫 경로는 오늘 **0개를 수집한다.** Task 4·5 가 그 첫 파일들을 만든다.

---

## RISKS (아무도 안 물어본 것)

**RISK-1 — Task 3 의 게이트 교체가 `requested` 는 안 고쳐서 비교 실행의 의미가 갈린다.**
`policy.jl:1033` 은 그대로 남는다:
```julia
requested = get(rt, "enabled", false) ? String(rt["target"]) : POLICY
```
교정 파일이 없는 지금(`have_det=false` → `enabled=false`)은 `requested = POLICY`("canonical" 기본).
그런데 새 게이트(`router_enabled() && POLICY != "noop"`)는 **참이 되므로** `select_lane` 이 돌고
`enacted = sel.lane` 이 된다. supported=true·novel=false 면 `sel.lane == "surrogate"`.
→ **`DEMO_POLICY=canonical` 로 고정한 판이 조용히 surrogate 판이 된다.**
계획서는 *"DEMO_ROUTER=0 인 비교 실행에서는 여전히 안 돈다 — 보호는 유지된다"* 라고만 적고
`DEMO_ROUTER` 가 기본 `auto` 라는 사실은 안 적는다. `router_enabled()` 는 `"0"` 일 때만 false 다.
즉 **손잡이를 명시적으로 끄지 않은 모든 실행의 레인이 바뀐다.**
그리고 `fell_back = (enacted != requested && enacted == "canonical")` 은 이 경우 false 라
**기록에 "레인이 바뀌었다" 는 흔적이 안 남는다.**
👉 최소한 계획서에 이 귀결을 명문화하고, 가능하면 `requested` 도 같은 손잡이로 유도할 것.

**RISK-2 — `OPENAI_API_KEY` 가 이 환경에 설정돼 있다.**
`test_decide_carries_the_gap_to_julia` 는 오늘은 LM 미설정 덕에 무료지만,
그 안전은 *"아무도 `dspy.configure` 를 안 불렀다"* 라는 **우연**에 걸려 있다.
`--ignore` 를 잊는 것과 같은 종류의 사고다. T4f 의 대안 둘 중 하나를 반드시 넣을 것.

**RISK-3 — `test_gate_ng2` 의 팔 id 3 은 Task 1 이 못 잡는 어휘 밖 id 다.**
`arms_seen=[0,1,2,3]` 인데 `v4-3arms` 에는 3 이 없다. 이건 정확히 계획서 Task 1 이 막으려는
사고("낡은 id 가 돌아다닌다")의 **살아 있는 실례**인데, `psi` 가 아니라 `T_done` 경로라
Task 1 의 KeyError 가 안 닿는다. Plan V1 을 다 해도 이 자리는 그대로 남는다.
👉 계획서 "알려진 미결" 에 적을 것.

**RISK-4 — 계획서 Task 2 Step 3 의 문구 변경이 `test_router.jl` / `regen_router_cases.sh` /
`dashboard.html` 의 녹화와 갈릴 수 있다.** `reason` 은 화면 ROUTER 줄에 그대로 나가고
`run_demo.jl:273` 이 그것을 println 한다. 문자열 비교로 회귀를 판정하는 녹화가 있으면 깨진다.
(이번 검증 범위 밖이라 확인하지 않았다 — `tools/test_router.jl` 을 돌려 볼 것.)

**RISK-5 — `escalation_allowed` 만 고치고 `select_lane` 게이트를 안 고치면 아무 일도 안 난다.**
계획서가 이미 이 점을 적었지만, 두 변경이 **한 커밋 안에 같이** 들어가야 한다는 것을
Step 순서가 흐리게 만든다. `escalation_allowed` 만 바뀐 중간 상태는 축 1 이 여전히 침묵한다.

**RISK-6 — 계획서 Task 5 Step 2 의 음성 대조 ②(`if False` 로 바꾸기)는 지금 상태에서
`test_decide_carries_the_gap_to_julia` 를 빨갛게 만들지 못한다.** T4g 때문에 그 테스트가
애초에 빨갛기 때문이다. `_load_surrogate()` 를 부르도록 고친 **뒤에만** 유효한 음성 대조다.
→ 그 항목이 이 검증의 **유일한 UNVERIFIABLE** 이다.

**RISK-7 — `health()` 의 `surro_data or ("ERROR: " + str(surro_error))` 가
"안 쟀다"(None) 를 `'ERROR: None'` 으로 렌더한다.** Task 4 가 `surro_support` 에 대해
`None`/`[]` 를 정확히 가르려는 바로 그 파일에 같은 결함이 한 줄 위에 있다. 같이 고치는 편이 낫다.

---

## 실행 전 반드시 고칠 것 (요약)

1. **T2e** — 새 testset 의 `const UP` → `UP` (Julia 1.10 문법 에러, 파일 전체가 죽는다)
2. **T3f′** — `tools/test_policy_escalation.jl` 에 `@testset` 앵커가 없고 `using Test` 도 없으며
   파일 끝이 `exit()` 다. 그 파일의 `check(...)` 관용구를 쓰거나 `exit` 앞에 넣을 것
3. **T4g** — 두 새 테스트 파일이 `svc._load_surrogate()` 를 먼저 부르지 않으면
   Task 4 의 세 번째 테스트와 Task 5 의 `decide` 테스트가 **구현 후에도 실패한다**
4. **T4d/T4g** — `surrogate_rank` 의 새 `support is None` 검사를 `model is None` 검사 **앞**으로
5. **X3** — `run_demo.jl:322-335` 에 `router_axis` 한 줄을 **같은 커밋에서** 더할 것
   (안 더하면 R5 를 못 잰다)
6. **B1** — "Expected: 전부 PASS" → "3 failed / 79 passed 유지"
7. **T1a** — `features_agnostic.py:446` → `:455/457` (계획서·설계서 둘 다)
8. **E3** — `--ignore` 규약 대신 `test_propose.py`(Anthropic 레인) 삭제
9. **RISK-1** — `requested` 가 안 바뀌어 `DEMO_ROUTER=auto` 인 모든 실행의 레인이 바뀐다는 사실 명문화
10. **RISK-2** — `decide` 테스트에서 dspy 레인을 stub 하거나 `surrogate_rank` 를 직접 단언
