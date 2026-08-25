# 축 C — 어휘 축소 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 행동 어휘를 3팔(`NOOP` · `Replace` · `SwapBattery`)로 줄이고, zone 사건을 LLM 결정
레인에서 빼고, `DeprioritizeAgent` DSL 잔재를 제거해 fault · battery 두 사건이 모두 채점
가능한 새 baseline을 만든다.

**Architecture:** `action_registry.json`이 행동 어휘의 단일 진실원이다. 여기서 `RelocateBuild`
엔트리를 지우고 id를 0..2로 재번호한 뒤, 그 재번호가 **조용히** 구세대 산출물을 오독하지
않도록 어휘 도장(`vocab`)을 산출물에 쓰고 로더가 검사하게 만든다. 그 다음 zone 사건과
`DeprioritizeAgent`를 코드에서 걷어내고, 채점기(`emitted_key`/`truth_key`/`reference_policy`)를
남은 두 사건에 맞춘다.

**Tech Stack:** Julia 1.x (`julia +lts --project=.`), Python 3.12 (`pytest` 9.1.1),
pydantic, DSPy, FastAPI.

**Spec:** `docs/superpowers/specs/2026-08-24-unified-llm-respec-design.md` (§5.1 · §5.2 · §5.4
· §5.5 · §5.6, 작업 순서 §6 "축 C")

## Global Constraints

- 워크트리: `/home/chahj578/Construction_OODlayer`, 브랜치 `oracle-rebuild-night-2026-08-10`.
- 최종 어휘: `{0: NOOP, 1: Replace, 2: SwapBattery}`, 도장 `vocab = "v4-3arms"`.
- 비용은 이름-비용 쌍 불변: `NOOP=0.0` · `Replace=1.0` · `SwapBattery=0.2`.
- `wm4spacecraft_manufacturing/core/features_agnostic.py` 는 **건드리지 않는다**(spec §5.4).
- `ood_mdp_shim.jl` · `src/smdp/generative.jl` 의 `kind_valid` 사용은 **건드리지 않는다**
  (spec §5.1 — 오라클/SMDP 레인).
- Julia 테스트: `julia +lts --project=. test/runtests.jl`
- Python 테스트: `python3 -m pytest <경로> -v` (레포 루트에서)
- 커밋은 각 Task 끝에서 한 번. Task 5는 **반드시 단일 커밋**.

---

## File Structure

| 파일 | 이 계획에서의 책임 |
|---|---|
| `wm4spacecraft_manufacturing/core/action_registry.json` | 어휘 단일 진실원. 3팔 + `v4-3arms` 도장 |
| `wm4spacecraft_manufacturing/smdp/test_stamps.py` | 파이썬 쪽 도장 계약 (리터럴 어서션) |
| `test/smdp_stamp_smoke.jl` | 줄리아 쪽 도장·어휘 계약 |
| `wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl` | 라벨 행에 `vocab` 도장을 **쓴다** |
| `wm4spacecraft_manufacturing/surrogate/eval_surrogate_v2.py` | 라벨을 읽을 때 도장을 **검사한다** |
| `tools/monitor/run_demo.jl` | zone 케이스 제거 (`case_kinds`) |
| `tools/monitor/policy.jl` | zone 분기 · `Deprioritize` 분기 제거 |
| `wm4spacecraft_manufacturing/core/reference_policy.py` | `ZoneTruth` 분기 제거, SoC 임계값 0.2 |
| `wm4spacecraft_manufacturing/sweep/llm_ood_eval.py` | `--case zone` 거부 |
| `src/respec/spec_dsl.jl` · `src/respec/llm_service/schema.py` | `DeprioritizeAgent` 타입 제거 (lockstep) |
| `src/navigator/ood_truth.jl` | `emitted_key` · `truth_key` 재정의 |

---

## Task 1: 작업 트리 산출물 복원 (블로킹 확인)

**Files:**
- Modify: 없음 (git 작업 트리 상태만)

**Interfaces:**
- Consumes: 없음
- Produces: Task 8·9가 의존하는 `dspy_real_program_gpt4o.json` · `relabel_2026-08-16.jsonl`의
  존재 여부에 대한 확정된 답

**배경 (2026-08-24 측정):** 이 워크트리는 **추적 중인 파일 207개가 삭제된 상태**다.
그중에 다음이 포함된다 — 둘 다 git에는 있고 디스크에는 없다:

- `wm4spacecraft_manufacturing/sweep_lab/dspy_real_program_gpt4o.json` (컴파일된 MIPROv2 arm)
- `wm4spacecraft_manufacturing/oracle/out/relabel_2026-08-16.jsonl` (배포 surrogate 학습 라벨)

결과: `dspy_service._load_program()`의 `os.path.exists(PROGRAM)`이 false여서
**컴파일 demo·instruction 없이 `dspy.Predict(PickMacro)` 로 돈다.** `_load_surrogate()`도
라벨 파일이 없어 예외로 떨어져 surrogate 정책이 unavailable이 된다.

- [ ] **Step 1: 현재 상태를 눈으로 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer
git status --porcelain | awk '{print $1}' | sort | uniq -c
git ls-files -d | wc -l
ls -l wm4spacecraft_manufacturing/sweep_lab/dspy_real_program_gpt4o.json 2>&1
ls -l wm4spacecraft_manufacturing/oracle/out/relabel_2026-08-16.jsonl 2>&1
```

기대: `D` 207개, 두 `ls`는 "No such file or directory".

- [ ] **Step 2: 사람에게 묻는다 — 이 삭제가 의도된 것인가**

의도된 폐기라면 Task 8(재생성)이 유일한 경로다.
사고라면 복원한다:

```bash
git checkout -- wm4spacecraft_manufacturing/sweep_lab/dspy_real_program_gpt4o.json
git checkout -- wm4spacecraft_manufacturing/oracle/out/relabel_2026-08-16.jsonl
```

전체 복원이 필요하면:

```bash
git checkout -- .            # ⚠️ 25개 M(수정) 파일도 되돌린다. 먼저 git diff 로 확인할 것
```

- [ ] **Step 3: 결정을 기록한다**

`docs/superpowers/plans/2026-08-24-axis-c-vocabulary-reduction.md` 이 문단 아래에
결정과 근거를 한 줄로 적는다. 커밋하지 않아도 된다 — Task 2로 넘어간다.

> **결정 기록:** _(실행자가 채운다)_

---

## Task 2: 레지스트리를 3팔로 — 삭제 + 재번호 + 도장

**Files:**
- Modify: `wm4spacecraft_manufacturing/core/action_registry.json`
- Test: `wm4spacecraft_manufacturing/smdp/test_stamps.py:22`
- Test: `test/smdp_stamp_smoke.jl:100-121`

**Interfaces:**
- Consumes: 없음
- Produces: `ActionRegistry.NAME == Dict(0=>"NOOP", 1=>"Replace", 2=>"SwapBattery")`,
  `ActionRegistry.COST == Dict(0=>0.0, 1=>1.0, 2=>0.2)`,
  `ActionRegistry.VOCAB == "v4-3arms"`, `kind_valid(:zone)`은 빈 목록.
  파이썬 쪽 동일: `action_registry.MACRO_NAME`, `MACRO_COST`, `VOCAB`, `KIND_VALID`.

- [ ] **Step 1: 실패하는 테스트를 먼저 쓴다 (파이썬 도장)**

`wm4spacecraft_manufacturing/smdp/test_stamps.py:22` 의 리터럴을 갈아 끼운다.
이 리터럴이 **일부러** 하드코딩돼 있다는 것이 이 시험의 요점이다(세대가 갈리면 사람이
여기 와서 갱신하도록 강제한다) — 레지스트리에서 읽어 오게 바꾸지 말 것.

```python
    assert action_registry.VOCAB == "v4-3arms"
```

- [ ] **Step 2: 실패하는 테스트를 쓴다 (줄리아 어휘)**

`test/smdp_stamp_smoke.jl` 의 `@testset "4팔 확정 ..."` 블록을 3팔로 갱신한다.
testset 이름도 함께 고친다 — 이름이 낡으면 다음 사람이 오독한다.

```julia
@testset "3팔 확정 (2026-08-24 축소, id 재번호 0..2)" begin
    delete!(ENV, "DS_COMBO_ARMS")
    @test ActionRegistry.active_ids() == [0, 1, 2]
    ENV["DS_COMBO_ARMS"] = "1"
    @test ActionRegistry.active_ids() == [0, 1, 2]   # 지워진 조합 팔은 플래그로도 안 살아난다
    delete!(ENV, "DS_COMBO_ARMS")
    @test ActionRegistry.NAME == Dict(0 => "NOOP", 1 => "Replace", 2 => "SwapBattery")
    @test ActionRegistry.COST == Dict(0 => 0.0, 1 => 1.0, 2 => 0.2)
    # 은퇴 표식이 아니라 삭제 정책 — RETIRED 는 비어 있다
    @test isempty(ActionRegistry.RETIRED)
    # 지워진 팔은 registry 밖 id 이므로 is_active 가 false 여야 한다(KeyError 가 아니라)
    for gone in (3, 4, 5, 6, 7, 8, -1, 99)
        @test ActionRegistry.is_active(gone) == false
    end
    # reform 도 zone 도 더 이상 사건 종류가 아니다
    @test isempty(ActionRegistry.kind_valid(:reform))
    @test isempty(ActionRegistry.kind_valid(:zone))
    @test ActionRegistry.kind_valid(:fault)   == [0, 1]
    @test ActionRegistry.kind_valid(:battery) == [0, 1, 2]
end
```

`test_stamps.py` 에는 어휘를 리터럴로 박은 어서션이 **세 개 더** 있다(172-190).
전부 갱신한다 — `MACRO_COST` 를 놓치면 재번호가 조용히 통과한다:

```python
def test_active_macros_are_the_three_arms():
    assert action_registry.ACTIVE_MACROS == [0, 1, 2]


def test_the_three_arms_are_named_as_expected():
    """사건 종류당 개입 팔 하나 + NOOP. 이름-비용 쌍은 구 어휘에서 그대로 옮겼다."""
    assert action_registry.MACRO_NAME == {0: "NOOP", 1: "Replace", 2: "SwapBattery"}
    assert action_registry.MACRO_COST == {0: 0.0, 1: 1.0, 2: 0.2}


def test_removed_arms_are_gone_entirely():
    """Deprioritize / ReformTeam / ForbidZone / RelocateBuild / 조합 팔은 레지스트리에 없다.
    `is_active` 는 registry 밖 id 에 대해 False 여야 한다(KeyError 가 아니라)."""
    assert set(action_registry.MACROS) == {0, 1, 2}
    for gone_name in ("Deprioritize", "ReformTeam", "ForbidZone", "RelocateBuild"):
        assert gone_name not in action_registry.NAME2ID
    for gone in (3, 4, 5, 6, 7, 8, -1, 99):
        assert action_registry.is_active(gone) is False
```

(함수 이름의 `four` → `three` 도 함께 고친다. 이름이 낡으면 다음 사람이 오독한다.)

또한 같은 파일의 `require_vocab` 계약 테스트(`test/smdp_stamp_smoke.jl:20-22`)의
도장 문자열을 갱신한다:

```julia
    @test ActionRegistry.require_vocab(Dict("vocab" => "v4-3arms"), "ok") === nothing
    @test_throws ErrorException ActionRegistry.require_vocab(Dict{String,Any}(), "도장 없음")
    @test_throws ErrorException ActionRegistry.require_vocab(Dict("vocab" => "v3-4arms"), "구세대")
```

- [ ] **Step 3: 두 테스트가 실패하는지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer
python3 -m pytest wm4spacecraft_manufacturing/smdp/test_stamps.py -v
julia +lts --project=. test/smdp_stamp_smoke.jl
```

기대: 파이썬은 `AssertionError` (VOCAB이 아직 `"v3-4arms"`).
줄리아는 `NAME` 비교 실패, `kind_valid(:zone)`이 `[0, 2]`라 `isempty` 실패.

- [ ] **Step 4: 레지스트리를 고친다**

`wm4spacecraft_manufacturing/core/action_registry.json` 의 `vocab` 과 `macros` 를 통째로
아래로 바꾼다. `_doc` 에는 이번 축소의 이유와 재번호 사실을 남긴다 — 다음 사람이 구세대
파일을 만났을 때 무슨 일이 있었는지 알아야 한다.

```json
  "vocab": "v4-3arms",
  "macros": {
    "0": {
      "name": "NOOP",
      "cost": 0.0,
      "kinds": ["fault", "battery"],
      "doc": "do nothing / restraint. Free. Best when the disruption is absorbed by slack or spares and intervening would waste a scarce resource."
    },
    "1": {
      "name": "Replace",
      "cost": 1.0,
      "kinds": ["fault", "battery"],
      "doc": "swap the affected robot for a spare BODY from the depot pool. Consumes one spare robot. Best on a real fault, or on a depleted battery when no cheaper repair applies."
    },
    "2": {
      "name": "SwapBattery",
      "cost": 0.2,
      "kinds": ["battery"],
      "doc": "swap only the depleted battery in the field, keeping the same robot body and its identity. Does NOT consume a depot spare body, so it is far cheaper than Replace; it restores charge but not a broken robot."
    }
  }
```

`_doc` 배열 끝에 다음 두 줄을 추가한다:

```
"2026-08-24 축소: 4팔 -> 3팔. RelocateBuild(구 id 2) 삭제 — zone 사건을 LLM 결정 레인에서",
"뺐다(spec 2026-08-24 §5.1). SwapBattery 가 3 -> 2 로 재번호됐다. v3-4arms 세대 파일의",
"macro=2 행은 새 어휘에서 SwapBattery 로 **조용히** 읽히므로, 그 세대 산출물은 반드시",
"폐기하거나 도장 검사(require_vocab)를 통과시켜야 한다 — Task 3 이 그 배선이다."
```

- [ ] **Step 5: 두 테스트가 통과하는지 확인한다**

```bash
python3 -m pytest wm4spacecraft_manufacturing/smdp/test_stamps.py -v
julia +lts --project=. test/smdp_stamp_smoke.jl
```

기대: 둘 다 PASS. 특히 `assert_vocab_arm_count("v4-3arms", 3)` 이 import 시점에 통과해야
한다 — 실패하면 도장 숫자와 실제 팔 수가 어긋난 것이다.

- [ ] **Step 6: 커밋**

```bash
git add wm4spacecraft_manufacturing/core/action_registry.json \
        wm4spacecraft_manufacturing/smdp/test_stamps.py \
        test/smdp_stamp_smoke.jl
git commit -m "feat(registry): cut the vocabulary to three arms and renumber

RelocateBuild(구 id 2) 를 지우고 SwapBattery 를 3 -> 2 로 재번호했다. zone 사건을
LLM 결정 레인에서 빼기로 한 결정(spec 2026-08-24 §5.1)의 어휘 쪽 귀결이다.
도장을 v3-4arms -> v4-3arms 로 올렸다 -- assert_vocab_arm_count 가 import 시점에
팔 수를 대조하므로 함께 올리지 않으면 모듈이 뜨지 않는다."
```

---

## Task 3: 라벨 산출물에 도장을 쓰고, 로더가 검사하게 한다

**Files:**
- Modify: `wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl` (행 조립부)
- Modify: `wm4spacecraft_manufacturing/surrogate/eval_surrogate_v2.py:123-143` (`load_rows`)
- Test: `wm4spacecraft_manufacturing/surrogate/test_load_rows_vocab.py` (신규)

**Interfaces:**
- Consumes: Task 2의 `action_registry.VOCAB == "v4-3arms"`
- Produces: `load_rows(path) -> (rows, meta)` 가 `meta["vocab"]` 을 포함하고,
  행의 `vocab` 이 현행과 다르면 `ValueError` 를 던진다.

**배경 (2026-08-24 측정):** `require_vocab` 을 실제로 부르는 소비처는 `gate_ng2.py:112`
하나뿐이고, `macro` 열을 읽는 나머지 7곳은 도장을 보지 않는다. 더 근본적으로
**`gen_oracle_dataset.jl` 은 `vocab` 을 애초에 쓰지 않는다** — 행에 박히는 도장은
`objective_hash` 와 `hot_swap` 뿐이다. 그래서 "로더에 `require_vocab` 을 배선한다"는
생성기가 도장을 쓰게 만드는 일이 선행돼야 한다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`wm4spacecraft_manufacturing/surrogate/test_load_rows_vocab.py` 를 새로 만든다.

```python
"""load_rows 가 어휘 도장을 검사하는지 -- 구세대 라벨이 조용히 읽히면 안 된다."""
import json
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
WM = os.path.dirname(HERE)
for d in (HERE, os.path.join(WM, "core")):
    if d not in sys.path:
        sys.path.insert(0, d)

import action_registry  # noqa: E402
from eval_surrogate_v2 import load_rows  # noqa: E402


def _row(vocab):
    """load_rows 가 요구하는 최소 열만 채운 한 행."""
    return {"vocab": vocab, "fired": True, "macro": 2, "complete": True,
            "instance": "i1", "kind": "battery", "valid_mask": [1, 1, 1]}


def _write(tmp_path, vocab):
    p = tmp_path / "labels.jsonl"
    p.write_text(json.dumps(_row(vocab)) + "\n", encoding="utf-8")
    return str(p)


def test_current_stamp_loads(tmp_path):
    rows, meta = load_rows(_write(tmp_path, action_registry.VOCAB))
    assert len(rows) == 1
    assert meta["vocab"] == action_registry.VOCAB


def test_old_generation_is_rejected_loudly(tmp_path):
    with pytest.raises(ValueError, match="어휘 도장"):
        load_rows(_write(tmp_path, "v3-4arms"))


def test_missing_stamp_is_rejected_loudly(tmp_path):
    p = tmp_path / "labels.jsonl"
    r = _row("x"); del r["vocab"]
    p.write_text(json.dumps(r) + "\n", encoding="utf-8")
    with pytest.raises(ValueError, match="어휘 도장"):
        load_rows(str(p))
```

- [ ] **Step 2: 실패를 확인한다**

```bash
python3 -m pytest wm4spacecraft_manufacturing/surrogate/test_load_rows_vocab.py -v
```

기대: `test_old_generation_is_rejected_loudly` 와 `test_missing_stamp_is_rejected_loudly`
가 FAIL (`DID NOT RAISE ValueError`) — 지금은 검사를 안 하므로 그냥 읽힌다.

- [ ] **Step 3: `load_rows` 에 검사를 넣는다**

`wm4spacecraft_manufacturing/surrogate/eval_surrogate_v2.py` 의 `load_rows` 에서
`fired` 필터 **앞에** 도장을 본다. 순서가 중요하다 — 필터가 행을 다 걷어내면 검사할
행이 없어져 구세대 파일이 조용히 통과한다.

```python
def load_rows(path):
    """라벨 파일 -> 행 dict 목록. 위 docstring 의 로딩 계약 1·2 를 여기서 집행한다."""
    if not os.path.exists(path):
        raise SystemExit("라벨 파일이 없다: %s — 폴백하지 않는다(n44_plus78 금지)." % path)
    df = e1_analyze.load(path)                       # 계약 1: "Inf"/"NaN" 문자열 복원
    # 계약 0 (2026-08-24): 어휘 도장. 2026-08-24 의 4팔->3팔 재번호로 구세대 파일의
    # macro=2(RelocateBuild) 행이 새 어휘에서 SwapBattery 로 **조용히** 읽히게 됐다.
    # fired 필터보다 **앞에서** 본다 -- 필터가 행을 다 걷어내면 검사할 것이 없어진다.
    if "vocab" not in df.columns:
        raise ValueError("%s: 어휘 도장('vocab') 열이 없다 -- 구세대 라벨이다. 현행은 %r."
                         % (path, action_registry.VOCAB))
    stamps = set(df["vocab"].astype(str))
    if stamps != {action_registry.VOCAB}:
        raise ValueError("%s: 어휘 도장 불일치 -- 파일 %s vs 현행 %r."
                         % (path, sorted(stamps), action_registry.VOCAB))
    if "fired" not in df.columns:
        raise SystemExit("라벨에 `fired` 열이 없다 — stub 10행을 거를 수 없다. 조용히 넘어가지 않는다.")
```

같은 파일 상단 import 블록에 `action_registry` 를 추가하고, `meta` dict 에 도장을 싣는다:

```python
                  "vocab": action_registry.VOCAB,
                  "objective_hash": objective.objective_hash()}
```

- [ ] **Step 4: 생성기가 도장을 쓰게 한다**

`wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl` 에서 `OBJ_HASH` 를 행에 박는
바로 그 자리(파일 상단 `const OBJ_HASH = ...` 가 주석으로 "모든 행에 박는다"라고 적은 그
필드)에 나란히 `vocab` 을 추가한다.

```julia
const VOCAB = ActionRegistry.VOCAB    # 모든 행에 박는다 — 어휘 세대 판정(2026-08-24)
```

행 조립 Dict 에 다음 한 쌍을 넣는다 (`"objective_hash" => OBJ_HASH` 바로 옆):

```julia
    "vocab" => VOCAB,
```

- [ ] **Step 5: 테스트가 통과하는지 확인한다**

```bash
python3 -m pytest wm4spacecraft_manufacturing/surrogate/test_load_rows_vocab.py -v
python3 -m pytest wm4spacecraft_manufacturing/smdp/test_stamps.py -v
```

기대: 3개 모두 PASS.

- [ ] **Step 6: 생성기가 실제로 도장을 쓰는지 눈으로 본다**

```bash
grep -n '"vocab" =>' wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl
```

기대: 최소 1줄. 없으면 Step 4를 안 한 것이다.

- [ ] **Step 7: 커밋**

```bash
git add wm4spacecraft_manufacturing/surrogate/eval_surrogate_v2.py \
        wm4spacecraft_manufacturing/surrogate/test_load_rows_vocab.py \
        wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl
git commit -m "feat(stamp): write the vocabulary stamp into labels and check it on load

재번호의 위험은 재해석 자체가 아니라 그것이 조용하다는 것이다. require_vocab 의 실제
소비처는 gate_ng2.py 하나뿐이었고, 더 근본적으로 gen_oracle_dataset.jl 이 vocab 을
애초에 쓰지 않았다(objective_hash 와 hot_swap 만 박았다). 생성기가 도장을 쓰게 하고,
load_rows 가 fired 필터 **앞에서** 대조하게 했다 -- 필터가 먼저 돌면 행이 다 걷혀
구세대 파일이 조용히 통과한다."
```

---

## Task 4: zone 사건을 LLM 결정 레인에서 제거

**Files:**
- Modify: `tools/monitor/run_demo.jl:92-106` (`case_kinds`)
- Modify: `tools/monitor/policy.jl:263-293` (`valid_macros` zone 분기)
- Modify: `tools/monitor/policy.jl:1144-1162` (`macro_to_proposal` zone 분기)
- Modify: `wm4spacecraft_manufacturing/core/reference_policy.py:220-244` (`ZoneTruth` 분기)
- Modify: `wm4spacecraft_manufacturing/sweep/llm_ood_eval.py:499` (`--case`)
- Test: `wm4spacecraft_manufacturing/core/test_reference_policy_zone_gone.py` (신규)

**Interfaces:**
- Consumes: Task 2의 3팔 어휘
- Produces: `reference_action({"truth": "ZoneTruth", ...})` 가
  `(None, "zone", "<사유>")` 를 돌려준다(= 채점 제외). `valid_macros` 는 zone 을 모른다.

**주의:** spec §5.1 대로 `ood_mdp_shim.jl` · `src/smdp/generative.jl` 의 zone 처리는
**건드리지 않는다**. 이 Task는 LLM 결정 레인만 다룬다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`wm4spacecraft_manufacturing/core/test_reference_policy_zone_gone.py`:

```python
"""zone 은 LLM 결정 레인에서 빠졌다 -- 채점기가 zone 에 정답을 주면 안 된다."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import reference_policy  # noqa: E402


def test_zone_is_unscored():
    ev = {"truth": "ZoneTruth", "valid": ["NOOP"],
          "zone_primitives": {"n_nav_blocked": 3, "root_covered": 0}}
    a_star, basis, note = reference_policy.reference_action(ev)
    assert a_star is None, "zone 은 채점 대상이 아니어야 한다"
    assert basis == "zone"
    assert "결정 레인" in note or "removed" in note.lower()


def test_fault_and_battery_still_scored():
    fault = {"truth": "FaultTruth", "agent_pending": 2, "valid": ["NOOP", "Replace"]}
    assert reference_policy.reference_action(fault)[0] == "Replace"

    batt = {"truth": "BatteryTruth", "soc": 0.05,
            "valid": ["NOOP", "Replace", "SwapBattery"]}
    assert reference_policy.reference_action(batt)[0] == "SwapBattery"
```

- [ ] **Step 2: 실패를 확인한다**

```bash
python3 -m pytest wm4spacecraft_manufacturing/core/test_reference_policy_zone_gone.py -v
```

기대: `test_zone_is_unscored` FAIL — 현재 `ZoneTruth` 분기가 `"RelocateBuild"` 를 돌려준다.

- [ ] **Step 3: `reference_policy` 의 zone 분기를 채점 제외로 바꾼다**

`wm4spacecraft_manufacturing/core/reference_policy.py` 의 `if truth == "ZoneTruth":`
블록 전체를 아래로 대체한다. **삭제하지 말고 명시적 unscored로 남긴다** — 그래야 옛
요약 행에 섞여 있는 zone 결정이 조용히 `reform` 폴백(`return None, "reform", ...`)으로
떨어지지 않고 사유가 정확히 찍힌다.

```python
    if truth == "ZoneTruth":
        # 2026-08-24 (spec §5.1): zone 은 LLM 결정 레인에서 빠졌다 -- surrogate 학습 증거로만
        # 쓴다. 닫힌 어휘(NOOP/Replace/SwapBattery)에 zone 의 수복이 없으므로 정답이 없다.
        # battery 의 untested regime 과 같은 관례로 **채점하지 않는다**.
        return None, "zone", "zone 은 LLM 결정 레인에서 제거됐다(spec 2026-08-24 §5.1); unscored"
```

- [ ] **Step 4: 테스트 통과를 확인한다**

```bash
python3 -m pytest wm4spacecraft_manufacturing/core/test_reference_policy_zone_gone.py -v
```

기대: 2개 PASS.

- [ ] **Step 5: `run_demo.jl` 의 케이스 목록에서 zone 을 뺀다**

`tools/monitor/run_demo.jl:92-106` 의 `case_kinds` 를 아래로 바꾼다.
**조용한 폴백을 만들지 않는다** — 없앤 케이스를 요청하면 큰 소리로 죽어야 한다.
현재의 `return [:fault]` 폴백이 그대로 남으면 `DEMO_OOD=zone` 이 fault 판으로 돌아가고,
그 결과가 "zone 을 돌렸다"로 기록된다.

```julia
function case_kinds(c)
    c == "none"          && return Symbol[]
    c == "battery"       && return [:battery]
    c == "fault"         && return [:fault]
    c == "fault_battery" && return [:fault, :battery]
    # 2026-08-06: 두 종류가 **한 스트림 안에서** 섞이는 케이스. DEMO_OOD_STREAM3=1 과 함께 쓴다.
    c == "all"           && return [:fault, :battery]
    # 2026-08-24 (spec §5.1): zone 계열(zone/zonecore/fault_zone/battery_zone)은 제거됐다.
    # 폴백하지 않는다 — 조용히 fault 판으로 돌면 그 결과가 "zone 을 돌렸다"로 기록된다.
    error("DEMO_OOD=$(c) 는 없는 케이스다. zone 계열은 2026-08-24 에 LLM 결정 레인에서 " *
          "제거됐다(spec §5.1). 가능한 값: none|fault|battery|fault_battery|all")
end
```

- [ ] **Step 6: `policy.jl` 의 zone 분기를 제거한다**

`tools/monitor/policy.jl` 의 `valid_macros`(263-293) 에서 `truth isa CB.ZoneTruth` 이후의
전부(`named` / `domain` / `zone_diagnosis` 호출 / zone return)를 지운다. 함수 본문은
battery 분기와 기본 반환만 남는다:

```julia
function valid_macros(env, truth)
    # battery: SwapBattery 를 메뉴에 올린다 (2026-08-06, Ch-A). 전제조건은 배터리 레이어가
    # 켜져 있어야 SoC 복구가 의미를 갖는다는 것 — 없으면 메뉴에서 뺀다.
    if truth isa CB.BatteryTruth
        local have_fleet = (try CB.BATTERY_FLEET[] !== nothing catch; false end)
        return have_fleet ? ["NOOP", "Replace", "SwapBattery"] : ["NOOP", "Replace"]
    end
    return String[]          # 그 외 종류는 서비스 기본표 그대로
end
```

함수 위의 긴 docstring 은 전부 zone 어휘 논쟁 기록이다. **지우지 말고** 맨 앞에 한 줄을
붙여 역사로 남긴다:

```
> 2026-08-24: 아래 zone 논의는 **역사 기록**이다. zone 은 LLM 결정 레인에서 제거됐고
> (spec §5.1) 이 함수에 zone 분기는 더 이상 없다.
```

`macro_to_proposal`(1144-1162)에서 `ForbidZone` · `RelocateBuild` 두 분기를 지운다.
남는 분기는 `Replace` · `SwapBattery` · `ReformTeam` 과 기본 빈 제안이다.

`oracle_macro`(655) 의 `"ForbidZone" in vm` 줄과 그 주변 zone 경로는 `vm` 에 zone 팔이
없으므로 자동으로 무동작이 된다 — **이 Task 에서는 건드리지 않는다**(spec §5.1 주의).

- [ ] **Step 7: `llm_ood_eval.py` 가 `--case zone` 을 거부하게 한다**

`wm4spacecraft_manufacturing/sweep/llm_ood_eval.py:499` 를 바꾼다.

```python
    r.add_argument("--case", default="all",
                   choices=["none", "fault", "battery", "fault_battery", "all"],
                   help="zone 계열은 2026-08-24 에 제거됐다(spec §5.1)")
```

- [ ] **Step 8: 전체 테스트를 돌린다**

```bash
julia +lts --project=. test/runtests.jl
python3 -m pytest wm4spacecraft_manufacturing/ -v -x
```

기대: 통과. zone 을 기대하던 테스트가 깨지면 그 테스트도 이 Task 의 일부다 — 지우지 말고
"zone 은 제거됐다"를 검증하도록 뒤집는다.

- [ ] **Step 9: 커밋**

```bash
git add tools/monitor/run_demo.jl tools/monitor/policy.jl \
        wm4spacecraft_manufacturing/core/reference_policy.py \
        wm4spacecraft_manufacturing/core/test_reference_policy_zone_gone.py \
        wm4spacecraft_manufacturing/sweep/llm_ood_eval.py
git commit -m "feat(ood): drop zone from the LLM decision lane

zone 은 앞으로 OOD 시뮬레이션에서 surrogate 가 잘 학습됐다는 증거로만 쓴다(spec §5.1).
결정 epoch 를 만드는 사건 종류는 fault · battery 둘이다.

없앤 케이스를 요청하면 큰 소리로 죽는다 -- case_kinds 의 `return [:fault]` 폴백을
error 로 바꿨다. 그 폴백이 남으면 DEMO_OOD=zone 이 fault 판으로 돌고 그 결과가
'zone 을 돌렸다'로 기록된다. reference_policy 의 zone 분기는 지우지 않고 명시적
unscored 로 남겼다 -- 옛 요약 행의 zone 결정이 reform 폴백으로 조용히 떨어지지 않게."
```

---

## Task 5: `DeprioritizeAgent` DSL 잔재 제거 (단일 커밋)

**Files:** spec §5.4 의 표 그대로. 코드 수정이 필요한 13개 파일.
- Modify: `src/respec/spec_dsl.jl` (타입 정의) · `src/respec/llm_service/schema.py` (lockstep)
- Modify: `src/respec/replan.jl` · `src/respec/verifier.jl` · `src/respec/compiler.jl`
- Modify: `src/essential_tg_coponents.jl` · `src/navigator/baselines.jl`
- Modify: `tools/monitor/policy.jl` · `tools/monitor/smoke_ood_run.jl`
- Modify: `tools/tests.jl` · `tools/demos.jl`
- Test: `test/respec_action_space.jl` · `test/respec_sequential_enact.jl`
  · `test/navigator_comparison_smoke.jl`
- **제외**: `wm4spacecraft_manufacturing/core/features_agnostic.py` (Global Constraints 참조)
- `src/navigator/ood_truth.jl` 은 Task 6에서 다룬다.

**Interfaces:**
- Consumes: 없음
- Produces: `DeprioritizeAgent` 라는 이름이 `features_agnostic.py` 와 주석을 빼면
  코드베이스에 남지 않는다.

**왜 단일 커밋인가:** `spec_dsl.jl` 의 타입과 `schema.py` 의 pydantic 모델은 lockstep
계약이다. 한쪽만 커밋된 상태가 존재하면 그 커밋에서 서비스와 솔버가 서로 다른 문법을
말한다.

- [ ] **Step 1: 현재 상태를 인벤토리로 고정한다**

```bash
cd /home/chahj578/Construction_OODlayer
for f in $(grep -rln "DeprioritizeAgent" --include="*.jl" --include="*.py" . \
           | grep -v features_agnostic.py); do
  n=$(grep -c "DeprioritizeAgent" "$f")
  c=$(grep "DeprioritizeAgent" "$f" | grep -cE "^\s*(#|//)")
  echo "$((n-c)) code / $c comment  $f"
done | sort -rn > /tmp/deprio_inventory.txt
cat /tmp/deprio_inventory.txt
```

이 목록이 이 Task 의 작업 범위다. `0 code / N comment` 인 파일은 손대지 않는다.

- [ ] **Step 2: 실패하는 테스트를 쓴다 — 어휘에서 사라졌는지**

`test/respec_action_space.jl` 에 다음 testset 을 추가한다(파일 끝).

```julia
@testset "DeprioritizeAgent 는 어휘에서 사라졌다 (2026-08-24, spec §5.4)" begin
    # 타입이 존재하지 않아야 한다 — 이름으로 조회해서 없음을 확인한다.
    @test !isdefined(ConstructionBots, :DeprioritizeAgent)
end
```

- [ ] **Step 3: 실패를 확인한다**

```bash
julia +lts --project=. test/respec_action_space.jl
```

기대: FAIL — `isdefined` 가 아직 true 다.

- [ ] **Step 4: 타입 정의를 지운다 (양쪽 동시에)**

`src/respec/spec_dsl.jl` 에서 `struct DeprioritizeAgent <: ConstraintSpec` 블록과 그
docstring 을 지운다. `src/ConstructionBots.jl` 의 export 목록에서도 뺀다.

`src/respec/llm_service/schema.py` 에서 `class DeprioritizeAgent(BaseModel)` 블록을
지우고, 아래쪽 discriminated union(`Annotated[Union[...], Field(discriminator="kind")]`)
목록에서도 뺀다. **union 에서 빼지 않으면 pydantic 이 없는 클래스를 참조해 import 시점에
죽는다** — 그 실패는 좋은 실패지만, 같은 커밋 안에서 함께 고쳐야 한다.

- [ ] **Step 5: 소비처를 지운다 — 인벤토리 순서대로**

`/tmp/deprio_inventory.txt` 를 위에서부터 따라간다. 각 파일의 성격:

| 파일 | 무엇을 지우나 |
|---|---|
| `src/respec/replan.jl` | 가장 큼. 실제 식별자: `_is_deprioritize(p)` (순수 soft 제안 판정, ~283) · `:deprioritize` 심볼을 내는 spec-kind 분기 (~564) · `:subsumed_by_hard_spec` 판정의 `any(c -> !(c isa DeprioritizeAgent), ...)` (~688) · `deprioritize_agent!` 집행 호출 (~892 표) |
| `src/respec/verifier.jl` | verify 경로의 kind 분기 |
| `src/respec/compiler.jl` | MILP 컴파일 분기 |
| `src/essential_tg_coponents.jl` | 우선순위 강등 실행부 |
| `src/navigator/baselines.jl` | 기준정책이 내던 제약 |
| `tools/monitor/policy.jl` | `_macro_label` 매핑, `macro_to_proposal` 분기 |
| `tools/monitor/smoke_ood_run.jl` · `tools/tests.jl` · `tools/demos.jl` | 데모/스모크 참조 |
| `test/*.jl` 3개 | 기대값 갱신 |

> ⚠️ **판단이 필요한 지점 하나**: `replan.jl:88` 의 `AUTO_EFFICIENCY_KAPPA` 는 docstring 이
> "κ for the DeprioritizeAgent re-solve" 라고 적지만, `run_demo.jl` 이 `LAST_AUTO_EFFICIENCY_W`
> 로 **다른 매크로의 재풀이에서도** 그 값이 실렸는지 검사한다. 고아가 되는지 먼저 확인하고
> 판단할 것 — 자동으로 지우지 말 것:
>
> ```bash
> grep -rn "AUTO_EFFICIENCY_KAPPA\|LAST_AUTO_EFFICIENCY_W" --include="*.jl" . | grep -v replan.jl
> ```
>
> 다른 소비처가 있으면 **남긴다**. docstring 의 "DeprioritizeAgent" 언급만 고친다.

각 파일을 고친 뒤 즉시:

```bash
julia +lts --project=. -e 'using Pkg; Pkg.precompile()'
```

precompile 이 깨지면 그 파일에서 멈춘다. 다음 파일로 넘어가지 않는다.

- [ ] **Step 6: 인벤토리가 비었는지 확인한다**

```bash
grep -rn "DeprioritizeAgent" --include="*.jl" --include="*.py" . \
  | grep -v features_agnostic.py \
  | grep -vE ":\s*(#|//)"
```

기대: **출력 없음**. 주석에 남은 역사 서술은 그대로 둔다(위 `grep -vE` 가 걸러낸다).

- [ ] **Step 7: 전체 테스트**

```bash
julia +lts --project=. test/runtests.jl
python3 -m pytest wm4spacecraft_manufacturing/ src/respec/llm_service/ -v
```

기대: 전부 PASS.

- [ ] **Step 8: 커밋 (단일)**

```bash
git add -A
git commit -m "refactor(dsl): remove the DeprioritizeAgent kind

레지스트리에서는 2026-08-20 에 이미 빠졌다(action_registry.json _doc: '어떤 사건에도
고유하게 안 붙었고 제안 338회 대비 선택 0회. 이 하니스의 배터리 사건은 저하가 아니라
정지(SoC 0)라 degraded-but-alive 상태가 없다'). 남아 있던 것은 compile/verify/dispatch
까지 배선된 DSL kind 쪽 잔재이고, 코드 수정이 필요한 파일이 13개였다.

spec_dsl.jl 과 schema.py 는 lockstep 이라 한 커밋으로 묶는다 -- 한쪽만 커밋된 상태에서는
서비스와 솔버가 서로 다른 문법을 말한다. features_agnostic.py 는 제외했다(spec §5.4):
psi 표는 메뉴가 아니라 서술자 공간이고, psi_regression_check 가 '행동 하나가 사라져도
나머지의 psi 는 안 바뀐다'를 계약으로 강제한다."
```

---

## Task 6: `emitted_key` / `truth_key` 를 남은 두 사건에 맞춘다

**Files:**
- Modify: `src/navigator/ood_truth.jl:134-165`
- Test: `test/ood_truth_keys.jl` (신규)

**Interfaces:**
- Consumes: Task 5 (`DeprioritizeAgent` 부재)
- Produces:
  - `emitted_key(ReplaceAgent(rid, 0.0)) == (:fault, rid)`
  - `emitted_key(SwapBattery(rid)) == (:battery, rid)`
  - `truth_key(BatteryTruth(rid, soc)) == (:battery, rid)` — **SoC 와 무관**
  - `truth_key(FaultTruth(rid, pos, t)) == (:fault, rid)`

**배경 (2026-08-24 측정):** `emitted_key` 에는 `SwapBattery` 분기가 **없다**(정의는
`ood_truth.jl:152` 하나뿐). Task 5로 `DeprioritizeAgent` 가 사라지면 battery 가 낼 수 있는
유일한 팔이 키를 못 만들어 **battery grounding 이 항상 0** 이 된다. 한편
`canonical_respec(BatteryTruth)` 는 이미 deep/mild 를 합쳐 `SwapBattery(t.robot)` 하나만
낸다(`baselines.jl:96`) — 채점기만 그 통합을 못 따라간 상태다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`test/ood_truth_keys.jl`:

```julia
using Test
using ConstructionBots
const CB = ConstructionBots

@testset "grounding 키 — fault·battery 둘 다 정의된다 (spec §5.5)" begin
    rid = CB.RobotID(3)

    # 하드 고장 취급
    @test CB.emitted_key(CB.ReplaceAgent(rid, 0.0)) == (:fault, rid)

    # 배터리: SwapBattery 가 키를 만들어야 한다 — 이 분기가 없으면 battery recall 이 항상 0
    @test CB.emitted_key(CB.SwapBattery(rid)) == (:battery, rid)

    # truth 쪽: severity 와 무관하게 같은 키 (canonical_respec 의 통합과 일치)
    @test CB.truth_key(CB.BatteryTruth(rid, 0.02)) == (:battery, rid)
    @test CB.truth_key(CB.BatteryTruth(rid, 0.45)) == (:battery, rid)
    @test CB.truth_key(CB.FaultTruth(rid, [1.0, 2.0], 0.0)) == (:fault, rid)

    # canonical 대응이 실제로 그 키를 낸다 (채점기 ↔ 기준정책 일치)
    @test CB.emitted_key(first(CB.canonical_respec(CB.BatteryTruth(rid, 0.02)).constraints)) ==
          (:battery, rid)
end
```

- [ ] **Step 2: 실패를 확인한다**

```bash
julia +lts --project=. test/ood_truth_keys.jl
```

기대: `emitted_key(SwapBattery(...))` 가 `nothing` 을 돌려줘 FAIL.
`truth_key(BatteryTruth(rid, 0.02))` 도 `(:fault, rid)` 라 FAIL.

- [ ] **Step 3: `emitted_key` 와 `truth_key` 를 고친다**

`src/navigator/ood_truth.jl` 의 `emitted_key` 를 아래로 바꾼다.
`ForbidZone` 분기는 지운다 — zone 은 결정 레인에서 빠졌고(Task 4) 그 분기는
"구역 사건의 정답은 ForbidZone 이다" 라는 채점 규칙 그 자체였다.

```julia
function emitted_key(c)
    tn = nameof(typeof(c))                       # c 의 타입 "이름"(심볼)만 뽑아 비교
    if tn === :ReplaceAgent || tn === :ForbidAgent
        return (:fault, c.agent)                 # 교체/재배정 = "하드 고장 취급" 전략
    elseif tn === :SwapBattery
        # 2026-08-24 (spec §5.5): 이 분기가 없어서 battery grounding 이 구조적으로 0 이었다.
        # canonical_respec(BatteryTruth) 는 이미 deep/mild 를 SwapBattery 하나로 합쳤는데
        # (baselines.jl:96) 채점기만 그 통합을 못 따라가고 있었다.
        return (:battery, c.agent)               # SwapBattery.agent (spec_dsl.jl)
    elseif tn === :ReformTeam
        return (:reform, :team)
    else
        return nothing                           # 채점 대상 엔티티가 없는 지시(예: ForbidWindow)
    end
end
```

`truth_key(::BatteryTruth)` 의 severity 삼항연산을 없앤다:

```julia
# 2026-08-24 (spec §5.5): severity 분기를 없앴다. soft 대응(Deprioritize)이 어휘에서
# 사라졌으므로 deep/mild 를 가르는 키가 더 이상 서로 다른 팔을 가리키지 않는다.
# SoC 임계값의 남은 소비처는 reference_policy 의 "정답 vs unscored" 하나뿐이다.
truth_key(t::BatteryTruth) = (:battery, t.robot)
```

`truth_key(::ZoneTruth)` 는 남긴다 — 옛 요약 행을 다시 읽을 때 키가 없으면 조용히
사라진다. zone 을 emit 하는 쪽이 없으므로 채점에서는 자동으로 missed 로 잡힌다.

- [ ] **Step 4: 테스트 통과를 확인한다**

```bash
julia +lts --project=. test/ood_truth_keys.jl
julia +lts --project=. test/runtests.jl
```

기대: 전부 PASS. `test/navigator_comparison_smoke.jl` 이 옛 키를 기대하면 함께 갱신한다.

- [ ] **Step 5: 새 테스트를 러너에 등록한다**

`test/runtests.jl` 에 한 줄 추가한다(기존 `include` 관례를 그대로 따른다):

```julia
include("ood_truth_keys.jl")
```

- [ ] **Step 6: 커밋**

```bash
git add src/navigator/ood_truth.jl test/ood_truth_keys.jl test/runtests.jl
git commit -m "fix(grounding): give SwapBattery a key, collapse the battery severity split

emitted_key 에 SwapBattery 분기가 없어서, Deprioritize 를 지우면 battery 가 낼 수 있는
유일한 팔이 키를 못 만들고 battery grounding 이 구조적으로 0 이 될 참이었다. 방향은 이미
레포가 잡아 뒀다 -- canonical_respec(BatteryTruth) 는 deep/mild 를 SwapBattery 하나로
합쳤고(baselines.jl:96) 채점기만 그 통합을 못 따라가고 있었다.

ForbidZone 분기는 지웠다 -- 그 분기가 곧 '구역 사건의 정답은 ForbidZone 이다' 라는 채점
규칙이었고, zone 은 결정 레인에서 빠졌다."
```

---

## Task 7: SoC 임계값을 0.2로 통일

**Files:**
- Modify: `wm4spacecraft_manufacturing/core/reference_policy.py:69`
- Test: `wm4spacecraft_manufacturing/core/test_soc_threshold_agrees.py` (신규)

**Interfaces:**
- Consumes: Task 6 (`truth_key` 가 임계값을 안 씀)
- Produces: `reference_policy.BATTERY_DEEP_SOC == 0.2`

**공개된 대가 (spec §5.6):** 0.5 → 0.2 로 내리면 `n44_plus78_d20` 사다리에서 SwapBattery 가
이긴 세 rung 중 **0.30 · 0.50 의 실측 근거가 채점에서 버려진다**(그 구간이 unscored 가
된다). 지금 데이터로는 아무 채점도 바뀌지 않는다 — BatteryTruth 56건의 SoC 최댓값이
0.09999 라 전부 0.2 아래다. mild battery 를 굴리는 실행에서만 차이가 난다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`wm4spacecraft_manufacturing/core/test_soc_threshold_agrees.py`:

```python
"""SoC 임계값은 한 곳에서만 정의된다 -- 두 채점기가 같은 severity class 를 내야 한다."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import reference_policy  # noqa: E402

# Julia 쪽 ood_truth.jl:129 의 REPLACE_SOC_THRESHOLD 와 같은 값이어야 한다.
JULIA_REPLACE_SOC_THRESHOLD = 0.2


def test_threshold_matches_julia():
    assert reference_policy.BATTERY_DEEP_SOC == JULIA_REPLACE_SOC_THRESHOLD


def test_scoring_grid():
    """SoC 격자에서 정답/채점제외가 임계값과 정확히 일치하는지."""
    valid = ["NOOP", "Replace", "SwapBattery"]
    for soc, expected in ((0.02, "SwapBattery"), (0.15, "SwapBattery"),
                          (0.20, "SwapBattery"), (0.25, None), (0.45, None), (0.60, None)):
        ev = {"truth": "BatteryTruth", "soc": soc, "valid": valid}
        a_star, basis, _ = reference_policy.reference_action(ev)
        assert basis == "battery"
        assert a_star == expected, "SoC %.2f -> %r (기대 %r)" % (soc, a_star, expected)
```

- [ ] **Step 2: 실패를 확인한다**

```bash
python3 -m pytest wm4spacecraft_manufacturing/core/test_soc_threshold_agrees.py -v
```

기대: 둘 다 FAIL — 현재 `BATTERY_DEEP_SOC == 0.5` 라 0.25·0.45 가 `"SwapBattery"` 로 나온다.

- [ ] **Step 3: 임계값을 내린다**

`wm4spacecraft_manufacturing/core/reference_policy.py:69`:

```python
BATTERY_DEEP_SOC = 0.2      # Julia ood_truth.jl:129 REPLACE_SOC_THRESHOLD 와 통일(2026-08-24)
# ⚠️ 공개된 대가: 0.5 였을 때는 n44_plus78_d20 사다리의 0.30 · 0.50 rung 이 이 가지 안에
# 있어 채점 근거가 있었다(세 rung 전부에서 SwapBattery 가 이겼다). 0.2 로 내리면 그 두
# rung 이 unscored 로 빠진다 -- 측정된 근거를 버리는 것이다. 지금 데이터로는 무영향
# (BatteryTruth 56건의 soc 최댓값 0.09999). mild battery 를 굴리면 차이가 난다.
```

- [ ] **Step 4: 테스트 통과를 확인한다**

```bash
python3 -m pytest wm4spacecraft_manufacturing/core/test_soc_threshold_agrees.py -v
python3 -m pytest wm4spacecraft_manufacturing/ -v
```

기대: 전부 PASS.

- [ ] **Step 5: 커밋**

```bash
git add wm4spacecraft_manufacturing/core/reference_policy.py \
        wm4spacecraft_manufacturing/core/test_soc_threshold_agrees.py
git commit -m "fix(scoring): unify the SoC threshold at 0.2

Julia(ood_truth.jl:129) 는 0.2, Python(reference_policy.py:69) 은 0.5 였다. 그 사이
구간에서 두 채점기가 반대의 severity class 를 말한다. set_replace_soc_threshold! 를
부르는 코드는 레포에 없다(확인함).

대가를 공개해 둔다: 0.30 · 0.50 rung 의 실측 근거가 채점에서 빠진다. 지금 데이터로는
무영향(soc 최댓값 0.09999)이고 mild battery 를 굴리는 실행에서만 차이가 난다."
```

---

## Task 8: 산출물 재생성 + 구세대 파일 제거

**Files:**
- Create: 새 오라클 라벨셋 (`wm4spacecraft_manufacturing/oracle/out/`)
- Create: 새 surrogate 모델
- Delete: `v3-4arms` 세대 라벨/모델 파일

**Interfaces:**
- Consumes: Task 2 (`v4-3arms`), Task 3 (생성기가 도장을 쓴다), Task 4–7
- Produces: Task 9의 측정이 쓸 라벨·모델

- [ ] **Step 1: 실행 레인의 물리 설정을 먼저 읽는다 (짐작하지 않는다)**

```bash
grep -n "set_hot_swap!\|DS_SHRINK\|DS_HOTSWAP" tools/monitor/run_demo.jl | head
```

`run_demo.jl` 은 `set_hot_swap!(enabled = true, mode = :via_depot)` 로 항상 켜고 돈다.
라벨 런이 이 설정과 어긋나면 **에러가 안 난다 — 발화율로만 샌다**(2026-08-15 실측:
`DS_HOTSWAP` 미설정 시 fault 발화율 100% → 23%).

- [ ] **Step 2: 라벨을 재생성한다**

```bash
DS_HOTSWAP=1 HOT_SWAP_MODE=via_depot \
  julia +lts --project=. wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl
```

- [ ] **Step 3: 생성된 파일의 도장을 검사한다**

```bash
NEW=$(ls -t wm4spacecraft_manufacturing/oracle/out/*.jsonl | head -1)
python3 -c "
import json,sys,collections
rows=[json.loads(l) for l in open('$NEW') if l.strip()]
print('rows:', len(rows))
print('vocab:', collections.Counter(r.get('vocab') for r in rows))
print('hot_swap:', collections.Counter(json.dumps(r.get('hot_swap')) for r in rows))
fired=collections.Counter((r.get('kind'), bool(r.get('fired'))) for r in rows)
print('kind별 발화:', dict(fired))
"
```

기대: `vocab` 이 전부 `v4-3arms`, `hot_swap` 이 전부 `{\"enabled\": true, \"mode\": \"via_depot\"}`,
kind 는 `fault` 와 `battery` 만(zone 없음). **kind별 발화율을 반드시 본다** — 총 행 수만
보면 "좀 적네" 로 지나간다.

- [ ] **Step 4: surrogate 를 재적합한다**

```bash
python3 wm4spacecraft_manufacturing/surrogate/export_surrogate.py --data "$NEW"
```

Task 3의 도장 검사가 여기서 걸리면 라벨이 구세대다 — Step 2로 돌아간다.

- [ ] **Step 5: 구세대 파일을 옮긴다**

```bash
mkdir -p wm4spacecraft_manufacturing/_gen_v3-4arms
git mv wm4spacecraft_manufacturing/oracle/out/relabel_2026-08-1{4,6,9}.jsonl \
       wm4spacecraft_manufacturing/_gen_v3-4arms/ 2>/dev/null || true
```

지우지 않고 옮기는 이유: 도장이 이제 걸리므로 조용히 읽힐 수 없고, 세대 비교를 나중에
하고 싶을 수 있다. 다만 **로더가 자동으로 찾는 경로 밖으로** 뺀다.

- [ ] **Step 6: 커밋**

```bash
git add -A wm4spacecraft_manufacturing/oracle/out wm4spacecraft_manufacturing/_gen_v3-4arms
git commit -m "chore(labels): regenerate the label set under v4-3arms

DS_HOTSWAP=1 / mode=via_depot 로 생성했다 -- 실행 레인(run_demo.jl)이 항상 그 설정으로
돌기 때문이다. 어긋나면 에러 없이 fault 발화율로만 샌다(2026-08-15 실측 100% -> 23%).
구세대 v3-4arms 라벨은 지우지 않고 _gen_v3-4arms/ 로 옮겼다 -- 도장이 이제 걸리므로
조용히 읽힐 수 없고, 로더의 자동 탐색 경로 밖이면 충분하다."
```

---

## Task 9: 축 C baseline 측정

**Files:**
- Create: `wm4spacecraft_manufacturing/results/axis_c_baseline.jsonl`
- Create: `docs/superpowers/reports/2026-08-24-axis-c-baseline.md`

**Interfaces:**
- Consumes: Task 1–8 전부
- Produces: 축 B·A 가 비교할 기준 수치 (`decision_rate`, `per_kind`, 발화율, 도장)

- [ ] **Step 1: DSPy 서비스를 띄운다**

```bash
export OPENAI_API_KEY=...    # 사용자가 제공
cd src/respec/llm_service
python3 -m uvicorn dspy_service:app --host 127.0.0.1 --port 8077 &
sleep 5 && curl -s localhost:8077/health
```

기대: `{"status":"ok"}` 또는 그에 준하는 응답.

- [ ] **Step 2: 서비스가 어떤 arm 으로 떴는지 확인한다 (Task 1과 직결)**

```bash
curl -s localhost:8077/health | python3 -m json.tool
ls -l wm4spacecraft_manufacturing/sweep_lab/dspy_real_program_gpt4o.json 2>&1
```

파일이 없으면 컴파일된 MIPROv2 instruction·demo 없이 `dspy.Predict(PickMacro)` 로 도는
것이다. **그 사실을 보고서에 명시한다** — 없는 arm 을 벤치마크한 것처럼 적으면 안 된다.

- [ ] **Step 3: 측정 런을 돌린다 (순차, 병렬 금지)**

```bash
python3 wm4spacecraft_manufacturing/sweep/llm_ood_eval.py run \
  --seeds 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15 \
  --policies noop,canonical,dspy \
  --case all --dspy-url http://127.0.0.1:8077 \
  --out wm4spacecraft_manufacturing/results/axis_c_baseline.jsonl
```

병렬로 돌리지 않는다 — `run_lego_demo` 가 HiGHS MILP 로 스케줄을 푸는데 CPU 경합이
다르면 다른 해가 나온다. 그러면 정책 비교가 아니라 서로 다른 두 세계의 비교가 된다.

- [ ] **Step 4: 리포트를 뽑는다**

```bash
python3 wm4spacecraft_manufacturing/sweep/llm_ood_eval.py report \
  --out wm4spacecraft_manufacturing/results/axis_c_baseline.jsonl \
  --md docs/superpowers/reports/2026-08-24-axis-c-baseline.md
```

- [ ] **Step 5: 보고서에 반드시 적을 것**

`docs/superpowers/reports/2026-08-24-axis-c-baseline.md` 상단에 다음을 손으로 적는다:

1. 어휘 도장 (`v4-3arms`) 과 라벨 파일 경로
2. `hot_swap` 설정과 **kind별 발화율** (fault / battery)
3. DSPy 가 컴파일된 arm 으로 돌았는지 (Step 2의 답)
4. `decision_rate` + Wilson CI, `per_kind` (FaultTruth / BatteryTruth)
5. `chosen` 분포 — 특히 battery 에서 `SwapBattery` vs `Replace` 비율

이 다섯이 축 B(메뉴 개방)와 축 A(번역 추가)의 비교 기준이다.

- [ ] **Step 6: 커밋**

```bash
git add wm4spacecraft_manufacturing/results/axis_c_baseline.jsonl \
        docs/superpowers/reports/2026-08-24-axis-c-baseline.md
git commit -m "measure(axis-c): the new three-arm baseline

어휘 v4-3arms, 사건 종류 fault/battery 둘, 15 seed. 축 B(메뉴 개방)와 축 A(번역 추가)는
이 수치와 비교한다. v3-4arms 세대 수치와는 같은 표에 섞지 않는다 -- 세계가 다르다."
```

---

## 다음 단계

축 C가 끝나면 spec §6의 축 B(메뉴 개방 — `valid_macros` 를 활성 레지스트리 전체로,
`_valid_for` 의 kind 폴백 제거)로 넘어간다. 그 계획은 이 baseline 수치가 나온 뒤에 쓴다 —
축 B의 성공 기준이 여기 나온 `per_kind` 값에 걸려 있기 때문이다.
