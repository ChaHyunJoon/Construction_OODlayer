# Plan V1 — 축 1: 어휘 미달 라우터를 진짜로 만들고 발화를 증명한다

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 라우팅의 1순위 판정을 **"이 사건의 팔들을 surrogate 가 학습한 적이 있는가"** 로 바꾸고, 그 판정이 **실제로 발화할 수 있음**을 음성 대조로 증명한다.

**Architecture:** 판정 규칙은 이미 순수 함수(`lane_select.jl`)에 있고 `unsupported` 왕복 배관도 완성돼 있다. 이 계획은 (1) 미등록 매크로가 조용히 NOOP 으로 무너지는 자리를 에러로 바꾸고(Task 1), (2) `select_lane` 의 우선순위를 뒤집어 어휘 미달을 1순위로 올리고 어느 축이 발화했는지 기록하게 하고(Task 2), (3) 그 격상을 novelty 교정 파일 유무에서 떼어내고(Task 3), (4) 지원집합을 산문이 아니라 **데이터**로 노출하고(Task 4), (5) 축 1 이 발화함을 양방향으로 못박는다(Task 5).

**Tech Stack:** Julia 1.x (`tools/monitor/lane_select.jl`, `tools/monitor/policy.jl`) · Python 3.12 + FastAPI/pydantic (`src/respec/llm_service/dspy_service.py`, `wm4spacecraft_manufacturing/core/features_agnostic.py`) · pytest · Julia `Test`

**Spec:** `docs/superpowers/specs/2026-08-27-vocabulary-indexed-router-design.md`

## Global Constraints

- **Julia 는 `julia +lts` (1.10), 항상 `--project=.`.** `Manifest.toml` 이 1.10.11 에 고정돼 있고 상위 Julia 로 `Pkg.add` 하면 빌드가 조용히 깨진다.
- **Python 은 `.venv/bin/python`** (pytest 9.1.1 있음). 🔴 **모든 pytest 호출에 `--ignore=src/respec/llm_service/test_propose.py` 를 붙인다** — 그 파일은 pytest 테스트가 아니라 import 시점에 `sys.exit(1)` 하는 스크립트이고, `ANTHROPIC_API_KEY` 가 설정돼 있으면 수집 중에 **유료 API 호출을 발화시킨다.** 막을 conftest 가 없다.
- `Pkg.test()` 기준선은 **11 pass / 1 error**(Gurobi 라이선스 없음). 그 1 error 는 회귀가 아니다.
- 🔴 **`dspy_service.py` 의 `import numpy, sklearn.ensemble`(line 44)은 `import dspy`(line 46) 보다 앞에 있어야 한다.** 깨면 surrogate 로드가 죽고 레인이 **에러 없이** canonical 로 내려앉는다.
- **새 Julia 테스트는 반드시 `test/runtests.jl` 에 배선한다.** 안 하면 고아 게이트다.
- 🔴 **`nothing`/"못 쟀다" 를 `false`/"재서 아니었다" 로 뭉개지 않는다.** 이 레포는 그 둘을 섞어 여러 번 데었다.
- 🔴 **어휘 단일 진실원은 `wm4spacecraft_manufacturing/core/action_registry.json` 이다** — 현행 `v4-3arms`, 매크로 `0 NOOP` / `1 Replace` / `2 SwapBattery`. **리터럴 복붙 금지.** ⚠️ `.claude/CLAUDE.md` 는 `v3-4arms` 라고 적는데 **JSON 이 맞고 CLAUDE.md 가 낡았다.**
- **이 계획은 라우터를 삭제하지 않는다.** `src/safety/novelty.jl` 과 novelty 절은 그대로 둔다(사용자 결정: 새 라우터를 먼저 짓고 나중에 삭제). `novel` 은 축 2 가 생길 때까지 임시 자리지킴으로 남는다.
- **이 계획은 conformal 을 안 짓는다.** 축 2 는 반사실 라벨이 선행조건이라 별도 계획서다.
- 파이썬 테스트는 소스 옆 `test_*.py`, `sys.path.insert(0, HERE)` 관용구를 따른다.
- 실행: `julia +lts --project=. test/<name>.jl` · `.venv/bin/python -m pytest <path> -v --ignore=src/respec/llm_service/test_propose.py`

---

## 이 계획의 범위 — 설계서를 셋으로 나눈 이유

| 계획 | 무엇을 만드나 | 완료 시 측정 가능한 것 |
|---|---|---|
| **V1 (이 문서)** | 축 1 — 어휘 미달 라우팅 + 발화 증명 | `vocabulary_gap` 발화율 · 축별 발화 집합 |
| V2 | 축 2 — conformal (`Ĵ` 잔차, α) | escalation률이 α 근처인가 · `coverage_holdout` |
| V3 | 폐루프 뒷절반 — 반사실 라벨 생산자 + 재학습 + `train_macros` 도장 | **경계가 실제로 움직이는가**(R2) |

V1 만으로 **작동하고 측정 가능한 소프트웨어**가 나온다 — 라우터가 어휘로 결정하고, 그 결정이 어느 축에서 나왔는지 기록된다.

🔴 **V1 완료가 "경계가 움직인다" 를 뜻하지 않는다.** 그것은 V3 이 준다. V1 이 주는 것은 *경계가 움직일 수 있는 자리*와 *그것을 잴 눈금*이다.

---

## File Structure

| 파일 | 책임 | 상태 |
|---|---|---|
| `wm4spacecraft_manufacturing/core/features_agnostic.py` | `psi()` 가 미등록 id 에 죽는다 | 수정 |
| `wm4spacecraft_manufacturing/core/test_psi_unknown_macro.py` | 그 계약을 못박는다 | **신규** |
| `tools/monitor/lane_select.jl` | 어휘 미달이 1순위 · 어느 축인지 반환 | 수정 |
| `tools/monitor/test_lane_select.jl` | 우선순위와 축 라벨 | 수정 |
| `test/runtests.jl` | `test_lane_select.jl` 배선 (지금 고아다) | 수정 |
| `tools/monitor/policy.jl` | 격상을 novelty 게이트에서 분리 · 축 기록 | 수정 |
| `src/respec/llm_service/dspy_service.py` | 지원집합을 데이터로 노출 | 수정 |
| `src/respec/llm_service/test_support_is_data.py` | 지원집합 노출 계약 | **신규** |
| `src/respec/llm_service/test_vocabulary_gap_fires.py` | R1 음성 대조 (양방향) | **신규** |

---

### Task 1: `psi()` 가 미등록 매크로 id 에 죽는다

**왜:** `features_agnostic.py:446` 이 `MACRO_SPECS.get(int(action), [])` 로 읽고 바로 아래 `if not names:` 가 NOOP 의 ψ 를 돌려준다. 그래서 **"원시연산이 0개인 진짜 NOOP"(레지스트리 0번)** 과 **"레지스트리에 없는 id"** 가 같은 분기로 무너진다. 실측(2026-08-27):

```
psi(0)  NOOP : [0,0,0,0,0,0,0,0,1,0]
psi(99) 미등록: [0,0,0,0,0,0,0,0,1,0]
같은가 -> True
```

즉 `predict_J([macro=99 행])` 이 예외 없이 NOOP 의 값을 그럴듯하게 돌려준다. 매크로를 주조하기 시작하면 낡은 id 가 돌아다니고, 그때 이 자리가 조용히 거짓을 만든다.

레지스트리 실측: `MACRO_SPECS == {0: [], 1: ['ReplaceAgent'], 2: ['SwapBattery']}` — **0 은 키로 존재하고 값이 빈 리스트다.** 그래서 고칠 것은 truthiness 검사를 **멤버십 검사**로 바꾸는 것 하나다.

**Files:**
- Modify: `wm4spacecraft_manufacturing/core/features_agnostic.py:440-458` (`psi`)
- Create: `wm4spacecraft_manufacturing/core/test_psi_unknown_macro.py`

**Interfaces:**
- Produces: `psi(action)` 은 미등록 int id 에 `KeyError` 를 던진다. 등록된 id(빈 spec 인 NOOP 포함)와 primitive 이름 리스트에는 지금과 **똑같이** 동작한다.
- Consumes: 없음 (첫 태스크)

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`wm4spacecraft_manufacturing/core/test_psi_unknown_macro.py`:

```python
"""미등록 매크로 id 는 **조용히 NOOP 이 되면 안 된다**.

🔴 왜 (2026-08-27 실측): `psi()` 가 `MACRO_SPECS.get(int(action), [])` 로 읽고 바로 아래
`if not names:` 가 NOOP 의 ψ 를 돌려줬다. 그래서 `psi(99) == psi(0)` 이 True 였고,
`predict_J([macro=99 행])` 이 **예외 없이** NOOP 의 값을 그럴듯하게 돌려줬다.
매크로를 주조하는 세계에서는 낡은 id 가 돌아다니므로 이 자리가 거짓 라벨을 만든다.

⚠️ NOOP(0)은 레지스트리에 **키로 존재하고 값이 빈 리스트다**(`MACRO_SPECS == {0: [],
1: ['ReplaceAgent'], 2: ['SwapBattery']}`). 그래서 판정 기준은 truthiness 가 아니라
**멤버십**이다 — 그걸 뒤집으면 NOOP 이 죽는다.
"""
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import features_agnostic  # noqa: E402


def test_unknown_macro_id_raises():
    with pytest.raises(KeyError):
        features_agnostic.psi(99)


def test_noop_still_works_it_is_registered_with_an_empty_spec():
    """🔴 회귀 방지: 멤버십이 아니라 truthiness 로 고치면 NOOP 이 여기서 죽는다."""
    v = features_agnostic.psi(0)
    assert isinstance(v, dict)
    assert v["a_intervenes"] == 0.0
    assert v["a_reversible"] == 1.0


def test_registered_macros_are_unchanged():
    for mid in features_agnostic.MACRO_SPECS:
        v = features_agnostic.psi(mid)
        assert set(v) == set(features_agnostic.PSI_AXES)


def test_primitive_name_lists_still_bypass_the_registry():
    """리스트 입력은 레지스트리를 안 거친다 — 그 경로는 안 건드린다."""
    v = features_agnostic.psi(["ReplaceAgent"])
    assert v["a_intervenes"] == 1.0


def test_the_error_names_the_id_and_the_registry():
    with pytest.raises(KeyError) as e:
        features_agnostic.psi(99)
    msg = str(e.value)
    assert "99" in msg
    assert "action_registry" in msg
```

- [ ] **Step 2: 실패를 확인한다**

Run: `.venv/bin/python -m pytest wm4spacecraft_manufacturing/core/test_psi_unknown_macro.py -v`
Expected: FAIL — `test_unknown_macro_id_raises` 에서 `DID NOT RAISE <class 'KeyError'>`

- [ ] **Step 3: 멤버십 검사로 바꾼다**

`wm4spacecraft_manufacturing/core/features_agnostic.py` — `psi()` 안의 아래 두 줄을

```python
    else:
        names = MACRO_SPECS.get(int(action), [])
```

이렇게 바꾼다:

```python
    else:
        mid = int(action)
        # 🔴 `.get(mid, [])` 였다 (2026-08-27 수정). 그러면 바로 아래 `if not names:` 가
        #    **"원시연산 0개인 진짜 NOOP"(레지스트리 0번)** 과 **"레지스트리에 없는 id"** 를
        #    같은 분기로 무너뜨려 둘 다 NOOP 의 ψ 를 받았다. 실측: psi(99) == psi(0) 이 True.
        #    귀결: predict_J 가 미등록 매크로에 **예외 없이** NOOP 의 값을 그럴듯하게 냈다.
        #    매크로를 주조하는 세계에서는 낡은 id 가 돌아다니므로 조용한 거짓이 된다.
        # ⚠️ 판정은 truthiness 가 아니라 **멤버십**이다 — MACRO_SPECS[0] 은 빈 리스트이므로
        #    `if not MACRO_SPECS.get(mid)` 로 고치면 NOOP 이 죽는다.
        if mid not in MACRO_SPECS:
            raise KeyError(
                "psi: 매크로 id %d 가 action_registry 에 없다 -- 조용히 NOOP 의 ψ 로 "
                "무너뜨리지 않는다. 현행 어휘의 id 는 %s 다. 구세대 라벨이거나 "
                "레지스트리에 등록되지 않은 주조 id 를 의심하라." % (mid, sorted(MACRO_SPECS)))
        names = MACRO_SPECS[mid]
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `.venv/bin/python -m pytest wm4spacecraft_manufacturing/core/test_psi_unknown_macro.py -v`
Expected: PASS — 5 passed

- [ ] **Step 5: 기존 소비처가 안 깨졌는지 확인한다**

Run: `.venv/bin/python -m pytest wm4spacecraft_manufacturing/ src/respec/llm_service/ -v --ignore=src/respec/llm_service/test_propose.py`
Expected: 전부 PASS. `psi` 는 `surrogate_features.build_features` 가 매 행마다 부르므로, 라벨 행에 어휘 밖 id 가 하나라도 있으면 **여기서 빨개진다** — 그건 이 변경이 잡아야 할 진짜 결함이지 회귀가 아니다. 빨개지면 그 행의 출처를 보고서에 적을 것.

- [ ] **Step 6: 커밋**

```bash
git add wm4spacecraft_manufacturing/core/features_agnostic.py \
        wm4spacecraft_manufacturing/core/test_psi_unknown_macro.py
git commit -m "fix(psi): 미등록 매크로 id 를 조용히 NOOP 으로 무너뜨리지 않는다

MACRO_SPECS.get(id, []) + `if not names` 가 '원시연산 0개인 NOOP' 과 '모르는 id' 를
한 분기로 뭉갰다. 실측 psi(99) == psi(0) -> True. 주조하는 세계의 지뢰라 멤버십 검사로 바꾼다."
```

---

### Task 2: `select_lane` — 어휘 미달이 1순위가 되고, 어느 축이 발화했는지 반환한다

**왜:** 오늘 `select_lane`(`lane_select.jl:27-59`)은 `novel` 을 먼저 보고 `supported` 를 나중에 본다. 그런데 novelty 는 **상태**가 낯선지를 보고 어휘 미달은 **행동을 표현할 수 있는지**를 본다. 설계서 §3 의 판정 우선순위는 어휘 미달이 1순위다 — 그것이 경계를 움직이는 축이기 때문이다.

그리고 지금은 반환값에 **어느 조건이 발화했는지가 없다.** `reason` 산문에서 역파싱해야 한다. 설계서 R5(*"두 축의 발화 집합이 겹치는 비율"*)를 재려면 축 라벨이 데이터로 있어야 한다.

⚠️ `tools/monitor/test_lane_select.jl` 은 **`test/runtests.jl` 에 배선돼 있지 않다** — 고아 게이트다. 이 태스크가 같이 배선한다.

**Files:**
- Modify: `tools/monitor/lane_select.jl:18-59` (`select_lane`)
- Modify: `tools/monitor/test_lane_select.jl`
- Modify: `test/runtests.jl`

**Interfaces:**
- Produces: `select_lane(; novel::Bool, available::AbstractDict, supported::Bool, policy::AbstractString) -> (lane::String, reason::String, axis::String)` — `axis` ∈ `"control"` · `"vocabulary_gap"` · `"novelty"` · `"none"`. Task 3 이 소비한다.
- Consumes: 없음

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`tools/monitor/test_lane_select.jl` 의 기존 `@testset` **바로 뒤**(파일의 마지막 `end` 앞)에 추가:

```julia
@testset "어휘 미달이 novelty 보다 먼저다 (2026-08-27, 축 1)" begin
    const UP = Dict("surrogate" => true, "dspy" => true, "canonical" => true)

    # (A) 지원 밖 팔이 있으면, 상태가 익숙해도 LLM 으로 간다.
    r = select_lane(novel = false, available = UP, supported = false, policy = "dspy")
    @test r.lane == "dspy"
    @test r.axis == "vocabulary_gap"

    # (B) 🔴 두 축이 동시에 참이면 **어휘 미달이 이긴다.** 순서가 뒤집히면 기록이
    #     "낯설어서 올렸다" 가 되는데 사실은 "그 팔을 배운 적이 없어서" 다 — 다른 사건이고,
    #     전자는 교정 파일에 의존하지만 후자는 안 한다.
    r2 = select_lane(novel = true, available = UP, supported = false, policy = "dspy")
    @test r2.lane == "dspy"
    @test r2.axis == "vocabulary_gap"

    # (C) 어휘는 되는데 상태가 낯설면 novelty 축이다 (축 2 가 생기기 전 임시 자리).
    r3 = select_lane(novel = true, available = UP, supported = true, policy = "dspy")
    @test r3.lane == "dspy"
    @test r3.axis == "novelty"

    # (D) 둘 다 아니면 surrogate 이고, 발화한 축이 없다.
    r4 = select_lane(novel = false, available = UP, supported = true, policy = "dspy")
    @test r4.lane == "surrogate"
    @test r4.axis == "none"

    # (E) 통제 바닥선은 축 판정 자체를 안 한다.
    r5 = select_lane(novel = true, available = UP, supported = false, policy = "noop")
    @test r5.lane == "noop"
    @test r5.axis == "control"

    # (F) 어휘 미달인데 LLM 이 없으면 canonical 로 떨어지되 **축은 그대로 기록된다** —
    #     "못 올렸다" 와 "올릴 일이 없었다" 는 다른 사건이다.
    r6 = select_lane(novel = false,
                     available = Dict("surrogate" => true, "dspy" => false, "canonical" => true),
                     supported = false, policy = "dspy")
    @test r6.lane == "canonical"
    @test r6.axis == "vocabulary_gap"
end
```

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. tools/monitor/test_lane_select.jl`
Expected: FAIL — `type NamedTuple has no field axis`

- [ ] **Step 3: `select_lane` 을 고친다**

`tools/monitor/lane_select.jl` — docstring 과 본문을 아래로 **교체**한다:

```julia
"""
    select_lane(; novel, available, supported, policy) -> (lane, reason, axis)

- `novel`     : novelty 판정 (p < eps). ⚠️ **축 2 의 임시 자리지킴**이다 — 설계서
                `2026-08-27-vocabulary-indexed-router-design.md` §3 의 축 2 는 conformal
                구간 겹침이고, 그것이 생기면 이 인자가 교체된다.
- `available` : 레인 가용성 Dict, 예 `Dict("surrogate"=>true, "dspy"=>false, "canonical"=>true)`
- `supported` : surrogate 가 이 사건의 팔을 **학습셋에서 지원하는가** (= 축 1)
- `policy`    : DEMO_POLICY. `"noop"` 이면 라우팅하지 않는다(통제 바닥선)

`axis` 는 **어느 조건이 이 판정을 냈는가**를 데이터로 남긴다:
`"control"` · `"vocabulary_gap"` · `"novelty"` · `"none"`.

🔴 왜 축을 반환하나 (2026-08-27): 예전에는 발화 조건이 `reason` 산문 안에만 있어서, 두 축의
발화 집합이 얼마나 겹치는지 재려면 문자열을 역파싱해야 했다. 그 숫자가 설계서 R5 다 —
완전히 겹치면 축 하나는 잉여다.

🔴 왜 어휘 미달이 1순위인가: novelty 는 **상태**가 낯선지를 보고 어휘 미달은 **행동을 표현할
수 있는지**를 본다. 후자는 novelty 교정 파일과 무관한 사실이고, 무엇보다 **경계를 움직이는
축**이다 — 새 매크로는 정의상 지원 밖이고 학습되면 정의상 안이다. 순서가 뒤집히면 같은
사건이 "낯설어서 올렸다" 로 기록되는데 사실은 "그 팔을 배운 적이 없어서" 다.

`reason` 은 화면 ROUTER 줄에 그대로 나가므로 영어로 쓴다(이 저장소의 화면 문구 규약).
"""
function select_lane(; novel::Bool, available::AbstractDict, supported::Bool,
                     policy::AbstractString)
    up(k) = get(available, k, false) === true

    # noop 은 후보가 아니라 통제 실험의 바닥선이다. 개입이 실제로 이득인지 재려면 아무도
    # 이 레인을 대신 판단해 주면 안 된다.
    policy == "noop" && return (lane = "noop", axis = "control",
        reason = "no-adapt floor — routing disabled for this control lane")

    # ---- 축 1: 어휘 미달 -----------------------------------------------------------------
    if !supported
        up("dspy") && return (lane = "dspy", axis = "vocabulary_gap",
            reason = "the surrogate has no training support for this arm → escalate to LLM")
        return (lane = "canonical", axis = "vocabulary_gap",
            reason = "the surrogate has no training support for this arm " *
                     "and the LLM lane is unavailable → canonical rule")
    end

    # ---- 축 2 (임시: novelty) ------------------------------------------------------------
    if novel
        up("dspy") && return (lane = "dspy", axis = "novelty",
            reason = "novelty p < eps — never seen this before → ask the LLM")
        return (lane = "canonical", axis = "novelty",
            reason = "novelty p < eps → LLM, but the LLM lane is unavailable → canonical rule")
    end

    up("surrogate") && return (lane = "surrogate", axis = "none",
        reason = "arms are supported and the state is familiar → surrogate")

    up("dspy") && return (lane = "dspy", axis = "none",
        reason = "familiar, but the surrogate lane is unavailable → LLM")

    return (lane = "canonical", axis = "none",
        reason = "familiar, but both the surrogate and LLM lanes are unavailable → canonical rule")
end
```

⚠️ 문구가 두 곳 바뀐다: surrogate 경로가 `"novelty p ≥ eps — familiar → surrogate"` → `"arms are supported and the state is familiar → surrogate"`, 어휘 미달 문구에서 `"familiar, but "` 접두사 제거(이제 familiar 여부와 무관하게 발화하므로). **기존 테스트는 그대로 통과한다** — 실측 확인: `test_lane_select.jl` 의 `reason` 단언 넷은 전부 `occursin` 이고 찾는 부분문자열이 `"novel"`·`"familiar"`·`"support"`·`"canonical"`/`"unavailable"` 이라 새 문구에도 다 들어 있다. 그래도 **실제로 돌려서 확인할 것** — 안 통과하면 새 문구를 옛것으로 되돌리지 말고 단언을 고칠 것. 옛 문구는 이제 거짓이다.

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `julia +lts --project=. tools/monitor/test_lane_select.jl`
Expected: PASS — 새 testset 12 assertions + 기존 testset 전부

- [ ] **Step 5: 고아 게이트를 `runtests.jl` 에 배선한다**

`test/runtests.jl` 의 `@testset "router descriptors survive a missing calibration"` 블록 **바로 뒤**에 추가:

```julia
    # 2026-08-27: lane_select.jl 은 의존성 0 인 순수 함수인데 게이트가 배선돼 있지 않았다.
    # 축 1(어휘 미달)이 이 함수의 우선순위에 얹히므로 이제 하중을 받는다.
    @testset "lane selection — vocabulary gap outranks novelty" begin
        include(normpath(joinpath(@__DIR__, "..", "tools", "monitor", "test_lane_select.jl")))
    end
```

- [ ] **Step 6: 배선을 확인한다**

Run: `julia +lts --project=. -e 'run(`grep -n test_lane_select test/runtests.jl`)'`
Expected: 한 줄 출력

- [ ] **Step 7: 커밋**

```bash
git add tools/monitor/lane_select.jl tools/monitor/test_lane_select.jl test/runtests.jl
git commit -m "feat(router): 어휘 미달을 1순위 축으로 올리고 발화한 축을 반환한다

novelty 는 상태가 낯선지를, 어휘 미달은 행동을 표현할 수 있는지를 본다. 후자가 경계를
움직이는 축이므로 먼저 본다. axis 필드가 두 축의 발화 집합을 재게 한다(설계서 R5).
test_lane_select.jl 은 고아 게이트였다 — 같이 배선한다."
```

---

### Task 3: 어휘 미달 격상을 novelty 교정 게이트에서 분리한다

**왜:** `policy.jl:1064` 가 `escalation_allowed = get(rt, "enabled", false)` 이고, `rt["enabled"]` 는 `drives = have_det && router_enabled() && POLICY != "noop"`(`policy.jl:439`)에서 온다. 즉 **어휘 미달 격상이 novelty 교정 파일 유무에 묶여 있다.** 어휘 미달은 교정과 무관한 사실이므로 그 게이트 뒤에 두면 안 된다.

⚠️ 그 게이트가 원래 막으려던 것은 실재한다 — `policy.jl:1058-1063` 이 적는다: *"`DEMO_ROUTER=0` 으로 정책을 고정한 비교 실행에서도 사건에 따라 조용히 dspy 로 넘어가고, 'surrogate 를 쟀다'고 적은 판이 사실은 LLM 판이 된다."* **그 보호를 잃으면 안 된다.** 그래서 `have_det`(교정 유무)이 아니라 `router_enabled() && POLICY != "noop"`(사람이 켠 손잡이)에만 묶는다.

**Files:**
- Modify: `tools/monitor/policy.jl:1036-1086` (`decide_all` 의 레인 선택 + 표현력 격상)

**Interfaces:**
- Consumes: `select_lane(...) -> (lane, reason, axis)` (Task 2)
- Produces: `rt["router_axis"]::String` — 결정 행과 스트림에 남는다. Task 5 가 읽는다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`tools/test_policy_escalation.jl` 은 이미 `escalation_target` 을 Dict 만으로 검사한다. 그 파일의 마지막 `@testset` 뒤에 추가:

```julia
@testset "어휘 미달 격상은 novelty 교정과 무관하다 (2026-08-27)" begin
    # `pol` 은 서비스 응답을 정규화한 Dict 다. surrogate 가 SwapBattery 를 학습한 적이 없다.
    pol = Dict(
        "surrogate" => Dict("chosen" => "NOOP", "available" => true,
                            "unsupported" => ["SwapBattery"]),
        "dspy"      => Dict("chosen" => "SwapBattery", "available" => true))

    # 🔴 이것이 이 태스크의 전부다: 교정 파일이 없어도(=have_det false) 어휘 미달은 격상한다.
    #    `allowed` 는 이제 have_det 이 아니라 사람이 켠 손잡이만 나른다.
    tgt, missing = escalation_target(pol, "surrogate", true)
    @test tgt == "dspy"
    @test missing == ["SwapBattery"]

    # 손잡이를 끈 비교 실행에서는 레인이 안 바뀐다 — 그런데 **진단은 남는다.**
    tgt2, missing2 = escalation_target(pol, "surrogate", false)
    @test tgt2 == ""
    @test missing2 == ["SwapBattery"]
end
```

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. tools/test_policy_escalation.jl`
Expected: PASS — ⚠️ **이 testset 은 이미 통과한다.** `escalation_target` 자체는 순수 함수라 이미 옳다. 결함은 그 함수가 아니라 **호출부가 `allowed` 에 무엇을 넘기는가**에 있다. 이 testset 은 계약을 못박아 두는 것이고, 실제 회귀 방지는 Step 3 의 호출부 변경과 Task 5 의 통합 테스트가 한다. **이 사실을 보고서에 그대로 적을 것 — "실패를 봤다" 고 적지 말 것.**

- [ ] **Step 3: 손잡이를 가른다**

`tools/monitor/policy.jl` — `escalation_allowed = get(rt, "enabled", false)` (line 1064 부근) 을 아래로 **교체**한다:

```julia
    # ---- 격상 손잡이 (2026-08-27, 설계서 §3) -------------------------------------------------
    # 🔴 예전에는 `get(rt, "enabled", false)` 였다. 그 값은 `have_det && router_enabled() &&
    #    POLICY != "noop"` 이라 **novelty 교정 파일이 있어야만** 어휘 미달 격상이 열렸다.
    #    그런데 "이 팔을 학습한 적이 있는가" 는 교정과 아무 상관이 없는 사실이다. 교정 디렉토리가
    #    없는 동안(= 지금) 어휘 미달은 한 번도 격상할 수 없었다.
    # ⚠️ 원래 그 게이트가 막으려던 것은 실재한다: DEMO_ROUTER=0 으로 정책을 고정한 비교 실행에서
    #    사건에 따라 조용히 dspy 로 넘어가면 "surrogate 를 쟀다"고 적은 판이 LLM 판이 된다.
    #    그래서 그 보호는 **사람이 켠 손잡이**로 보존하고, 교정 유무(have_det)만 뗀다.
    escalation_allowed = router_enabled() && POLICY != "noop"
```

🔴 **같은 결함이 한 겹 더 있다 — 그리고 이게 더 크다.** `select_lane` 호출 **전체**가 같은 게이트 안에 있다 (`policy.jl:1044`):

```julia
    if get(rt, "enabled", false)
        local sel = select_lane(novel = get(rt, "novel", false) === true, available = avail,
                                supported = supported, policy = POLICY)
```

즉 교정 파일이 없으면 **레인 선택 자체가 안 돈다.** `escalation_allowed` 만 고치면 축 1 은 `select_lane` 에 도달조차 못 한다. 그 `if` 를 같은 손잡이로 바꾼다:

```julia
    # 🔴 `get(rt, "enabled", false)` 였다 (2026-08-27). 그 값은 have_det 을 포함하므로 교정 파일이
    #    없으면 **레인 선택 자체가 안 돌았다** — 축 1 이 select_lane 에 도달조차 못 한다.
    #    레인 선택은 novelty 수치가 없어도 성립한다: 축 1 은 지원집합만 보고, 축 2(임시 novelty)는
    #    `rt["novel"]` 이 없으면 false 로 읽혀 그냥 발화하지 않는다.
    if router_enabled() && POLICY != "noop"
        local sel = select_lane(novel = get(rt, "novel", false) === true, available = avail,
                                supported = supported, policy = POLICY)
        enacted = sel.lane
        # 기존 문구를 **덮어쓰지 않고 덧붙인다** — novelty 수치가 든 줄이 화면에서 사라지면 안 된다.
        rt["reason"] = get(rt, "reason", "") * " · LANE: " * sel.reason
        rt["lane_reason"] = sel.reason
        # 어느 축이 이 판정을 냈는가. 산문에서 역파싱하지 않는다 — 설계서 R5 가 이 값을 센다.
        rt["router_axis"] = sel.axis
        fell_back = (enacted != requested && enacted == "canonical")
    end
```

⚠️ `rt["router_axis"]` 는 `select_lane` 을 부르지 **않는** 경로에서는 안 실린다. 그건 옳다 — 키가 없으면 "이 결정에는 레인 선택이 없었다" 이고, `"none"` ("선택했는데 축이 안 발화했다")과 **다른 사건**이다. 뭉개지 말 것.

⚠️ 이 변경은 **행동을 바꾼다**: 교정 파일이 없는 지금도 `DEMO_ROUTER` 가 켜져 있으면 레인 선택이 돈다. 그게 이 계획의 목적이다. 다만 `DEMO_ROUTER=0` 인 비교 실행에서는 여전히 안 돈다 — 보호는 유지된다.

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `julia +lts --project=. tools/test_policy_escalation.jl`
Expected: PASS

Run: `julia +lts --project=. test/policy_macro_binding.jl`
Expected: PASS — `policy.jl` 을 include 하는 소비처가 안 깨졌는지

Run: `julia +lts --project=. test/route_descriptors_survive.jl`
Expected: PASS — 같은 파일의 라우터 절이 안 깨졌는지

- [ ] **Step 5: 커밋**

```bash
git add tools/monitor/policy.jl tools/test_policy_escalation.jl
git commit -m "fix(router): 어휘 미달 격상을 novelty 교정 게이트에서 뗀다

escalation_allowed 가 rt[enabled] = have_det && ... 이라, 교정 파일이 없는 동안 어휘 미달은
한 번도 격상할 수 없었다. 비교 실행 보호는 사람이 켠 손잡이로 보존하고 have_det 만 뗀다.
router_axis 로 어느 축이 발화했는지 데이터로 남긴다."
```

---

### Task 4: 지원집합을 산문이 아니라 데이터로 노출한다

**왜:** 지원집합은 `_state["surro_support"]`(RAM)에만 있고, 디스크의 어떤 산출물도 *"이 모델이 어떤 매크로를 지원하는가"* 를 적지 않는다. `/health` 의 `surrogate` 필드가 유일한 창구인데 그건 **산문 문자열**이라 기계가 못 읽는다. 축 1 이 라우팅의 주축이 되는 이상 그 입력은 조회 가능해야 한다.

🔴 그리고 같은 자리에 폴백 결함이 있다 — `dspy_service.py:466`:

```python
support = _state.get("surro_support") or set(range(5))
```

`set(range(5))` 는 **구세대 리터럴**(매크로 5개)이다. surrogate 로드가 실패하면 지원집합이 조용히 `{0,1,2,3,4}` 가 되어, 현행 어휘(`{0,1,2}`)의 모든 팔이 "지원됨" 으로 읽힌다 — **축 1 이 정확히 그 상황에서 영원히 침묵한다.**

**Files:**
- Modify: `src/respec/llm_service/dspy_service.py` (`surrogate_rank` 의 폴백 · `/health` · `decide`)
- Create: `src/respec/llm_service/test_support_is_data.py`

**Interfaces:**
- Consumes: `_state["surro_support"]` (기존)
- Produces: `/health` 응답의 `"surro_support": list[int] | None` · `/decide` 응답의 `out["surrogate"]["unsupported"]: list[str]`. Task 5 가 읽는다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`src/respec/llm_service/test_support_is_data.py`:

```python
"""지원집합은 **기계가 읽을 수 있어야** 한다.

🔴 왜: 축 1(어휘 미달)이 라우팅의 주축인데, 그 입력인 지원집합은 `_state` RAM 에만 있고
디스크의 어떤 산출물도 그것을 적지 않는다. `/health` 의 `surrogate` 필드는 산문 문자열이라
기계가 못 읽는다. 조회할 수 없는 손잡이는 감사할 수 없다.

🔴 그리고 `surrogate_rank` 의 폴백이 `set(range(5))` — 구세대 리터럴(매크로 5개)이다.
surrogate 로드가 실패하면 지원집합이 조용히 {0,1,2,3,4} 가 되어 현행 어휘의 모든 팔이
'지원됨' 으로 읽히고, **축 1 이 정확히 그 상황에서 영원히 침묵한다.**
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import dspy_service as svc  # noqa: E402


def test_health_exposes_support_as_a_list_of_ints():
    h = svc.health()
    assert "surro_support" in h
    v = h["surro_support"]
    assert v is None or (isinstance(v, list) and all(isinstance(i, int) for i in v))


def test_health_support_is_none_not_empty_when_the_model_failed_to_load():
    """None('못 쟀다') 과 []('아무 팔도 지원 안 한다') 는 다른 사건이다."""
    saved = svc._state.get("surro_support")
    try:
        svc._state["surro_support"] = None
        assert svc.health()["surro_support"] is None
    finally:
        svc._state["surro_support"] = saved


def test_no_stale_literal_fallback_when_support_is_missing():
    """🔴 지원집합을 못 읽으면 '전부 지원' 으로 넘어가지 않는다 — 축 1 이 침묵하게 된다."""
    saved = svc._state.get("surro_support")
    try:
        svc._state["surro_support"] = None
        scored, err = svc.surrogate_rank(
            svc.MacroRequest(kind="battery", soc=0.1),
            ["NOOP", "Replace", "SwapBattery"])
        assert scored is None
        assert "support" in (err or "").lower()
    finally:
        svc._state["surro_support"] = saved
```

- [ ] **Step 2: 실패를 확인한다**

Run: `.venv/bin/python -m pytest src/respec/llm_service/test_support_is_data.py -v --ignore=src/respec/llm_service/test_propose.py`
Expected: FAIL — `test_health_exposes_support_as_a_list_of_ints` 에서 `assert 'surro_support' in h`

- [ ] **Step 3: 폴백을 죽이고 `/health` 에 싣는다**

`src/respec/llm_service/dspy_service.py` — `surrogate_rank` 안의

```python
        support = _state.get("surro_support") or set(range(5))
```

를 이렇게 바꾼다:

```python
        # 🔴 `or set(range(5))` 였다 (2026-08-27 수정). 그건 구세대 리터럴(매크로 5개)이고,
        #    surrogate 로드가 실패하면 지원집합이 조용히 {0,1,2,3,4} 가 되어 현행 어휘
        #    ({0,1,2})의 모든 팔이 '지원됨' 으로 읽혔다. 그러면 어휘 미달 축이 **정확히 그
        #    상황에서** 영원히 침묵한다 — 모델이 없는데 "전부 배웠다" 고 답하는 셈이다.
        #    못 읽으면 답하지 않는다.
        support = _state.get("surro_support")
        if support is None:
            return None, ("surrogate macro support is unknown (model not loaded) -- "
                          "refusing to answer rather than assuming every arm is supported")
```

`health()` 의 반환 Dict 에 한 줄 더한다:

```python
            # 축 1(어휘 미달)의 입력. 산문(`surrogate` 필드)이 아니라 **기계가 읽는 목록**이다.
            # None 은 "못 쟀다"(모델 미적재)이고 [] 는 "아무 팔도 지원 안 한다" — 다른 사건이다.
            "surro_support": (None if _state.get("surro_support") is None
                              else sorted(_state["surro_support"])),
```

🔴 **`decide()` 는 건드리지 않는다.** `out["surrogate"]["unsupported"]` 는 **이미 두 분기 모두에 실려 있다** — `surrogate_rank` 가 돌려준 `"UNSUPPORTED:a,b"` 문자열을 파싱해서 만든다. 거기에 새 계산을 얹으면 **두 번째 진실원**이 생겨 조용히 갈린다. 이 파일의 주석이 그 사고를 이미 두 번 기록하고 있다.

대신 `surrogate_rank` **자신이** 도우미를 쓰게 해서 유도가 한 곳에만 있게 한다. `surrogate_rank` 바로 위에 더한다:

```python
def _unsupported_for(req, valid):
    """이 메뉴에서 surrogate 가 학습 근거를 못 가진 팔들. **못 쟀으면 빈 목록이 아니라 None.**

    🔴 유도는 여기 한 곳에만 둔다. `surrogate_rank` 도 `decide` 도 이 함수(또는 그것이 만든
    `UNSUPPORTED:` 문자열)에서만 값을 얻는다 — 두 벌 두면 조용히 갈린다.
    ⚠️ `req` 는 지금 안 쓰지만 시그니처에 남긴다: 앞으로 지원 여부가 사건 의존이 되면
    (예: SoC 로 갈린 메뉴) 여기서 읽어야 하고, 그때 호출부를 다시 고치지 않는다.
    """
    from e1_analyze import MACRO_NAME as MN
    name2id = {v: k for k, v in MN.items()}
    support = _state.get("surro_support")
    if support is None:
        return None
    return [m for m in valid if m in name2id and name2id[m] not in support]
```

그리고 `surrogate_rank` 안의

```python
        unsupported = [m for m in valid if m in name2id and name2id[m] not in support]
```

을 이렇게 바꾼다:

```python
        unsupported = _unsupported_for(req, valid)      # 유도는 한 곳에만 (위 도우미)
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `.venv/bin/python -m pytest src/respec/llm_service/test_support_is_data.py -v --ignore=src/respec/llm_service/test_propose.py`
Expected: PASS — 3 passed

- [ ] **Step 5: 기존 서비스 테스트가 안 깨졌는지 확인한다**

Run: `.venv/bin/python -m pytest src/respec/llm_service/ wm4spacecraft_manufacturing/ -v --ignore=src/respec/llm_service/test_propose.py`
Expected: 전부 PASS

- [ ] **Step 6: 커밋**

```bash
git add src/respec/llm_service/dspy_service.py \
        src/respec/llm_service/test_support_is_data.py
git commit -m "feat(service): 지원집합을 데이터로 노출하고 구세대 폴백을 죽인다

surrogate_rank 의 `or set(range(5))` 는 매크로 5개 시절 리터럴이라, 모델 적재 실패 시
현행 어휘의 모든 팔이 '지원됨' 으로 읽혀 어휘 미달 축이 그 상황에서 침묵했다.
못 읽으면 답하지 않는다. /health 와 /decide 가 목록을 싣는다."
```

---

### Task 5: R1 음성 대조 — 축 1 이 실제로 발화함을 양방향으로 못박는다

**왜 (이 계획서에서 가장 중요한 태스크):** 오늘 지원집합은 `{0,1,2}` = **어휘 전체**다(실측: 라벨셋 33행, `macro Counter({0:12, 1:12, 2:9})`). 그래서 `unsupported` 는 **언제나 빈 목록**이고, 표현력 격상 코드는 지금까지 **발화 영역이 빈 죽은 코드**였다.

🔴 즉 Task 2~4 를 다 해도 *"축 1 이 잘 돌고 있다"* 는 관측이 **원리적으로 불가능하다** — 모든 테스트가 초록인 이유가 "옳아서"인지 "발화할 사건이 없어서"인지 구분이 안 된다. 이 레포가 반복해서 데인 *"실패할 수 없는 게이트"* 그 자체다.

이 태스크는 **지원집합을 줄여 축 1 을 강제로 발화시키고**, 그 다음 되돌려 침묵하는지 본다. 양방향이 다 있어야 측정이다.

**Files:**
- Create: `src/respec/llm_service/test_vocabulary_gap_fires.py`

**Interfaces:**
- Consumes: `_unsupported_for`, `health`, `surrogate_rank`, `decide` (Task 4) · `psi` 의 KeyError (Task 1)
- Produces: 없음 (게이트)

- [ ] **Step 1: 테스트를 쓴다**

`src/respec/llm_service/test_vocabulary_gap_fires.py`:

```python
"""🔴 축 1(어휘 미달)이 **실제로 발화할 수 있는가** — 양방향 음성 대조.

왜 이 파일이 있나 (2026-08-27 실측): 배포 라벨셋은 33행이고 macro 는 {0:12, 1:12, 2:9} 다.
즉 지원집합 = {0,1,2} = **어휘 전체**이므로 `unsupported` 는 언제나 빈 목록이고, 표현력
격상 코드는 지금까지 **발화 영역이 빈 죽은 코드**였다.

그 상태에서는 축 1 의 모든 테스트가 초록인데, 그 초록이 "옳아서"인지 "발화할 사건이
없어서"인지 구분되지 않는다. 이 저장소에는 stdout 에 절대 안 찍히는 문자열을 grep 하던
게이트가 90/90 으로 영원히 PASS 한 전례가 있다.

그래서 여기서는 지원집합을 **줄여서** 축 1 을 강제로 발화시키고(RED 방향), 되돌려
침묵하는지 본다(GREEN 방향). 둘 다 있어야 측정이다.
"""
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import dspy_service as svc  # noqa: E402

MENU = ["NOOP", "Replace", "SwapBattery"]


@pytest.fixture
def support():
    """지원집합을 갈아끼우고 반드시 되돌린다."""
    saved = svc._state.get("surro_support")
    yield lambda s: svc._state.__setitem__("surro_support", s)
    svc._state["surro_support"] = saved


def _req():
    return svc.MacroRequest(kind="battery", soc=0.1, valid=MENU,
                            nl="Robot R5 has run its battery down and stopped.")


def test_baseline_full_support_is_silent(support):
    """GREEN 방향: 어휘 전체를 지원하면 축 1 은 아무것도 안 한다."""
    support({0, 1, 2})
    assert svc._unsupported_for(_req(), MENU) == []


def test_removing_one_macro_makes_the_gap_fire(support):
    """🔴 RED 방향: SwapBattery 를 지원집합에서 빼면 그 팔이 미달로 잡힌다.

    이것이 이 계획서 전체의 존재 증명이다 — 이 단언이 통과하지 못하면 축 1 은
    '발화 영역이 빈 죽은 코드' 그대로다."""
    support({0, 1})
    assert svc._unsupported_for(_req(), MENU) == ["SwapBattery"]


def test_the_gap_names_every_missing_arm_not_just_the_first(support):
    support({0})
    assert svc._unsupported_for(_req(), MENU) == ["Replace", "SwapBattery"]


def test_unknown_support_is_none_not_empty(support):
    """'못 쟀다'(None) 와 '재서 미달이 없었다'([]) 를 뭉개지 않는다."""
    support(None)
    assert svc._unsupported_for(_req(), MENU) is None


def test_decide_carries_the_gap_to_julia(support):
    """축 1 을 실제로 소비하는 것은 Julia 다 — 그 경로에 실려 가는지 본다."""
    support({0, 1})
    out = svc.decide(_req())
    assert "surrogate" in out
    assert out["surrogate"].get("unsupported") == ["SwapBattery"]


def test_health_reports_the_reduced_support(support):
    """감사 창구가 산문이 아니라 목록이어야 한다."""
    support({0, 1})
    assert svc.health()["surro_support"] == [0, 1]
```

- [ ] **Step 2: 실행하고 양방향을 확인한다**

Run: `.venv/bin/python -m pytest src/respec/llm_service/test_vocabulary_gap_fires.py -v --ignore=src/respec/llm_service/test_propose.py`
Expected: PASS — 6 passed

🔴 **초록만 보고 끝내지 말 것.** 다음을 실제로 실행하고 출력을 보고서에 붙인다:

1. `test_removing_one_macro_makes_the_gap_fire` 의 `support({0, 1})` 을 `support({0, 1, 2})` 로 임시로 바꾸고 돌린다 → **빨개져야 한다.** 안 빨개지면 그 단언은 지원집합을 안 재고 있는 것이다. 되돌린다.
2. Task 4 의 `_unsupported_for` 에서 `if name2id[m] not in support` 를 `if False` 로 임시로 바꾸고 돌린다 → **`test_removing_one_macro_makes_the_gap_fire` 와 `test_decide_carries_the_gap_to_julia` 가 빨개져야 한다.** 되돌린다.

- [ ] **Step 3: Plan V1 전체 게이트를 돌린다**

```bash
.venv/bin/python -m pytest src/respec/llm_service/ wm4spacecraft_manufacturing/ -v \
    --ignore=src/respec/llm_service/test_propose.py
julia +lts --project=. tools/monitor/test_lane_select.jl
julia +lts --project=. tools/test_policy_escalation.jl
julia +lts --project=. test/policy_macro_binding.jl
julia +lts --project=. test/route_descriptors_survive.jl
julia +lts --project=. test/battery_menu_lanes_agree.jl
grep -n test_lane_select test/runtests.jl
```
Expected: 전부 PASS, grep 이 한 줄

- [ ] **Step 4: 커밋**

```bash
git add src/respec/llm_service/test_vocabulary_gap_fires.py
git commit -m "test(router): 축 1 이 실제로 발화함을 양방향으로 못박는다

배포 라벨셋의 지원집합이 어휘 전체({0,1,2})라 어휘 미달은 지금까지 한 번도 발화할 수 없었다.
그 상태에서는 초록이 '옳아서'인지 '발화할 사건이 없어서'인지 구분되지 않는다.
지원집합을 줄여 강제 발화시키고 되돌려 침묵하는지 본다."
```

---

## Plan V1 완료 시 측정 가능한 것

| 신호 | 어디서 | 무엇을 말하나 |
|---|---|---|
| `router_axis` 분포 | 결정 행 · 스트림 | 두 축의 발화 집합. **완전히 겹치면 축 하나는 잉여다**(설계서 R5) |
| `unsupported` 비율 | `/decide` 응답 | 어휘가 얼마나 자주 모자라는가 → V3 의 재학습 발화 빈도 |
| `/health` 의 `surro_support` | 서비스 | 지금 이 모델이 무엇을 배웠는가 — **감사 가능한 형태로** |
| `vocabulary_gap` 이 0 인가 | 결정 행 | 🔴 0 이면 축 1 이 침묵 중이다. 오늘은 **설계상 0 이 정상**이고(지원 = 어휘 전체), V3 이 어휘를 키우면 0 이 아니게 되어야 한다 |

## 알려진 미결 — Plan V1 이 안 푸는 것

- 🔴 **경계는 아직 안 움직인다.** 반사실 라벨 생산자도 재학습 자동화도 없다(설계서 §4 ④⑤). V1 은 *경계가 움직일 자리*와 *그것을 잴 눈금*을 만든다. 움직이는 것은 V3 이다.
- **축 2 는 여전히 novelty 다.** conformal 은 `Ĵ` 잔차가 필요하고 그건 반사실 라벨이 선행이라 V2 로 간다. `select_lane` 의 `novel` 인자가 그 자리지킴이다.
- **`train_macros` 도장을 안 만든다.** V3 이 만들되, 🔴 **소비처와 같은 커밋에서** 넣어야 한다 — `train_kinds` 가 4곳에서 찍히고 아무도 안 읽는 채로 kind 경계를 얼려 둔 것이 그 교훈이다.
- **`vocab` 도장의 동등성 의미를 안 바꾼다.** 매크로를 주조하면 기존 라벨 전부가 한꺼번에 무효가 되는 구조는 V3 이 푼다(설계서 §5).
- **`src/safety/novelty.jl` 을 안 지운다.** 사용자 결정: 새 라우터를 먼저 짓고 나중에 삭제. 삭제 순서는 설계서 §6.
