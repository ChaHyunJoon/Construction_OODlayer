# 생성 원시 합성 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 원시 인벤토리를 없애고 agent-3 을 Julia 구현 작성자로 교체해, OOD 사건에서 LLM 이 본 적 없는 원시의 코드를 써서 등록하고 집행하게 한다.

**Architecture:** agent-1·agent-2 는 그대로. agent-3 은 인벤토리 대신 `world_interface.json`(타입 스키마 + `names(CB)` 시그니처)을 보고 `function NAME(env; kw…) … end` 하나를 낸다. Julia 가 규약 다섯을 검사하고 `Core.eval` 로 `ConstructionBots` 안에 정의한 뒤 **런-스코프 표**에 등록하면, 기존 `enact_minted!` 경로(`bind_primitive_args` · `calls` 인자 채널 · `args_from` 기록)가 손대지 않은 채 그대로 집행한다.

**Tech Stack:** Julia 1.10 (ConstructionBots) · Python 3.12 (dspy 3.3, FastAPI) · JSON3 · pytest

**Spec:** `docs/superpowers/specs/2026-09-03-generated-primitive-synthesis-design.md`

## Global Constraints

- **TDD 필수.** 모든 생산 코드는 먼저 빨간 시험을 보고 쓴다. 시험을 못 봤으면 코드를 지우고 다시 시작한다.
- **삼상 규약.** `nothing`("못 쟀다") · `false`/`[]`("재서 없다") · 값 — 셋을 절대 섞지 않는다.
- **예외가 아니라 거절.** 집행 경로에서 새는 예외는 `enact_minted!` 를 기록 대신 예외로 끝내고 호출자가 세계 상태를 잃는다. 모든 실패는 `:reject` 와 사유 문자열이다.
- **진실원 하나.** 같은 사실을 두 곳에 적지 않는다. 이 레포는 `train_kinds`·`require_vocab`·`handled` 에서 세 번 데였다.
- **커밋은 명시 경로로만.** 작업트리에 **다른 세션의 미커밋 삭제 218건**이 있다. `git add -A` 금지. 푸시 금지.
- **grep 주의.** 이 셸의 `grep` 은 gitignore 를 따르는 ugrep 래퍼다. 레포 전체 주장은 `/usr/bin/grep`.
- Julia 시험: `julia +lts --project=. -e 'include("test/<f>.jl")'` · 전체: `julia +lts --project=. -e 'using Pkg; Pkg.test()'` (약 20분, Gurobi 라이선스 에러 1건은 환경 문제로 기대값).
- Python: 레포 루트에서 `python3 -m pytest -q`.

---

### Task 1: 파이썬이 다시 import 되게 한다 (인벤토리·ψ·단일 레인 삭제)

`primitive_registry.py` 가 사라져 `synthesize.py` 가 **ImportError 로 죽는다**. 서비스 전체가 못 뜬다. 이 태스크가 출혈을 멈춘다.

**Files:**
- Create: `src/respec/llm_service/test_no_inventory.py`
- Modify: `src/respec/llm_service/synthesize.py`
- Modify: `src/respec/llm_service/dspy_service.py` (단일 레인 import 제거)

**Interfaces:**
- Produces: `synthesize` 모듈이 import 가능. `SYNTHESIS_ENV`·`synthesis_enabled()`·`synthesize_multi`·`run_synthesis`·`normalize_calls`·`calls_flatness`·`append_synthesis_record`·`SynthesisLedger` 는 **남는다**.

- [ ] **Step 1: 실패하는 시험을 쓴다**

```python
# src/respec/llm_service/test_no_inventory.py
"""원시 인벤토리·ψ·단일 agent 레인이 사라졌다는 계약. 유료 0건."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def test_synthesize_imports_without_the_registry():
    """🔴 `primitive_registry.py` 를 지운 순간 이 import 가 죽었다 — 서비스 전체가 못 뜬다."""
    import synthesize  # noqa: F401


def test_the_inventory_and_psi_surface_is_gone():
    import synthesize as SY
    for gone in ("build_inventory_block", "primitive_inventory_lines",
                 "predicate_inventory_lines", "redact_inventory_names", "_REDACTED_NAME",
                 "_inventory_names", "parse_body", "psi_stats", "_PSI_STATS_CACHE"):
        assert not hasattr(SY, gone), "%s 가 아직 있다" % gone


def test_the_single_agent_lane_is_gone():
    """사용자 결정 D8. 레지스트리가 없으므로 그 레인은 돌 수 없다 — 비교군을 포기했다."""
    import synthesize as SY
    for gone in ("SynthesizeTool", "maybe_synthesize", "MULTI_AGENT_ENV", "multi_agent_enabled"):
        assert not hasattr(SY, gone), "%s 가 아직 있다" % gone


def test_run_synthesis_has_no_lane_branch():
    """🔴 분기가 남아 있으면 플래그 없는 서비스가 조용히 죽은 레인으로 간다."""
    import inspect
    import synthesize as SY
    src = inspect.getsource(SY.run_synthesis)
    assert "maybe_synthesize" not in src and "multi_agent_enabled" not in src


def test_what_must_survive_survives():
    """빈-통과 방지: 위 단언들은 모듈이 비어도 참이다."""
    import synthesize as SY
    for kept in ("synthesize_multi", "run_synthesis", "normalize_calls", "calls_flatness",
                 "append_synthesis_record", "SynthesisLedger", "synthesis_enabled"):
        assert hasattr(SY, kept), "%s 가 사라졌다" % kept
```

- [ ] **Step 2: 빨간 것을 확인한다**

Run: `python3 -m pytest src/respec/llm_service/test_no_inventory.py -q`
Expected: 첫 시험이 `ModuleNotFoundError: No module named 'primitive_registry'` 로 실패(수집 단계에서 죽는다).

- [ ] **Step 3: `synthesize.py` 에서 지운다**

자리를 먼저 찍는다:

```bash
/usr/bin/grep -n "_prim\.\|_prim\b\|_fa\.\|psi\|PSI\|redact\|_REDACTED\|inventory\|parse_body\|SynthesizeTool\|maybe_synthesize\|MULTI_AGENT" src/respec/llm_service/synthesize.py
```

지울 것:
- `import primitive_registry as _prim`, `import features_agnostic as _fa`
- `SynthesizeTool` 클래스 · `maybe_synthesize` 함수 전체
- `MULTI_AGENT_ENV` · `multi_agent_enabled()` · `run_synthesis` 의 분기 → 본문을 `return synthesize_multi(state=state, tools=tools, kind=kind, ledger=ledger, programs=programs, blob=blob)` 한 줄로
- `primitive_inventory_lines` · `predicate_inventory_lines` · `build_inventory_block` · `_inventory_names` · `redact_inventory_names` · `_REDACTED_NAME`
- `parse_body` 와 그 호출부(`_finish_record` 의 `body_names`/`body_parse`/`reach_matches_body`)
- ψ 계열: `psi_stats` · `_PSI_STATS_CACHE` · `_finish_record` 의 `psi`·`psi_error`·`psi_provenance`·`psi_reference_n`·`psi_zero_variance_axes`
- F2 되먹임의 redaction 호출: `red, hits = redact_inventory_names(...)` → `red = rec["missing_primitive"]`, `rec["compose_feedback_redacted"] = None` 로 대체하고 그 이유를 주석으로 남긴다(계약 B 폐지)

`ComposeToolBody` 와 `synthesize_multi` 의 3단계는 **Task 8 에서** 교체한다. 이 태스크에서는 `inventory=build_inventory_block(blob)` 자리를 `inventory=""` 로 두어 import 만 살린다.

- [ ] **Step 4: 초록을 확인한다**

Run: `python3 -m pytest src/respec/llm_service/test_no_inventory.py -q`
Expected: 5 passed

- [ ] **Step 5: 커밋**

```bash
git add src/respec/llm_service/test_no_inventory.py src/respec/llm_service/synthesize.py src/respec/llm_service/dspy_service.py
git commit -m "합성 레인: 인벤토리·ψ·단일 agent 레인을 지운다 (D5·D7·D8)"
```

---

### Task 2: Julia 의 원시 표를 런-스코프로 바꾼다

`PRIMITIVE_TABLE()` 이 사라진 JSON 파일을 읽으려다 죽는다. 표는 남고 **출처만** 바뀐다.

**Files:**
- Create: `src/respec/minted_registration.jl`
- Create: `test/minted_registration.jl`
- Modify: `src/respec/respec.jl` (include 추가)
- Modify: `src/respec/minted_tool.jl:26-46` (`_primitive_registry_path`·`_PRIM_TABLE`·`PRIMITIVE_TABLE`·`_reset_primitive_table!` 제거, `minted_table()` 사용)

**Interfaces:**
- Produces: `minted_table() -> Dict{String,Any}` · `reset_minted_table!()`
- Consumes: 없음

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/minted_registration.jl
module MintedRegistration
using Test
using ConstructionBots
const CB = ConstructionBots

@testset "(1) 표는 런 스코프이고 빈 채로 시작한다" begin
    CB.reset_minted_table!()
    @test isempty(CB.minted_table())
    # 🔴 파일에서 씨를 받지 않는다 — 지운 레지스트리를 다시 읽으려 하면 여기서 죽는다.
    @test CB.resolve_primitive("release_pending_assignments") === nothing
    @test CB.resolve_primitive("anything_at_all") === nothing
end

@testset "(2) 표에 넣으면 해석된다" begin
    CB.reset_minted_table!()
    CB.minted_table()["reform_stuck_teams"] = Dict{String,Any}(
        "name" => "reform_stuck_teams", "impl" => "reform_stuck_teams!",
        "surface" => "sched", "harness_args" => ["env"],
        "params" => Dict{String,Any}(), "reversible" => false)
    r = CB.resolve_primitive("reform_stuck_teams")
    @test r !== nothing && r.name == "reform_stuck_teams"
    @test r.harness_args == ["env"]
end

@testset "(3) 리셋은 실제로 비운다" begin
    @test !isempty(CB.minted_table())
    CB.reset_minted_table!()
    @test isempty(CB.minted_table())
end
end # module
```

- [ ] **Step 2: 빨간 것을 확인한다**

Run: `julia +lts --project=. -e 'include("test/minted_registration.jl")'`
Expected: `UndefVarError: reset_minted_table! not defined`

- [ ] **Step 3: 구현한다**

```julia
# src/respec/minted_registration.jl
# =============================================================================
# 생성 원시의 표와 등록. (2026-09-03, 설계 §6)
#
# 🔴 왜 파일이 아니라 런-스코프인가. 어휘는 이제 **런타임에 생성된다**. 파일에 쓰면 런끼리
#    오염되고(앞 런이 만든 원시를 뒤 런이 물려받는다), 추적되는 파일을 LLM 이 쓰는 것이 된다.
# =============================================================================
const _MINTED_TABLE = Ref{Dict{String,Any}}(Dict{String,Any}())

"이 런에서 등록된 원시들. `resolve_primitive` 가 읽는 유일한 표다."
minted_table() = _MINTED_TABLE[]

"표를 비운다. 시험과 런 경계에서 부른다."
reset_minted_table!() = (_MINTED_TABLE[] = Dict{String,Any}(); nothing)
```

`src/respec/respec.jl` 의 `include("minted_tool.jl")` **앞에** 한 줄을 넣는다:

```julia
include("minted_registration.jl")   # 생성 원시의 런-스코프 표 (minted_tool.jl 이 읽는다)
```

`src/respec/minted_tool.jl` 에서 `_primitive_registry_path()`·`const _PRIM_TABLE`·`_reset_primitive_table!()`·`function PRIMITIVE_TABLE()` 네 정의를 지우고, `resolve_primitive` 첫 줄을 바꾼다:

```julia
    tbl = minted_table()
```

- [ ] **Step 4: 초록을 확인한다**

Run: `julia +lts --project=. -e 'include("test/minted_registration.jl")'`
Expected: 8 passed

- [ ] **Step 5: 커밋**

```bash
git add src/respec/minted_registration.jl test/minted_registration.jl src/respec/respec.jl src/respec/minted_tool.jl
git commit -m "원시 표를 파일에서 런-스코프로 옮긴다"
```

---

### Task 3: 규약 다섯을 검사하는 순수 함수

세계도 `eval` 도 건드리지 않는다. **거절 사유 문자열**만 낸다.

**Files:**
- Modify: `src/respec/minted_registration.jl`
- Modify: `test/minted_registration.jl`

**Interfaces:**
- Produces: `check_impl_conventions(name::AbstractString, code::AbstractString) -> Union{Nothing,String}` — `nothing` 이면 통과.

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/minted_registration.jl 에 추가
const OK_CODE = """
function adjust_thing!(env; factor = 1.0)
    return (status = :adjusted, factor = factor)
end
"""

@testset "(4) 규약 다섯" begin
    @test CB.check_impl_conventions("adjust_thing!", OK_CODE) === nothing

    # 규약 1: env 만 위치인자
    bad1 = "function f!(env, other; k = 1)\n    return :ok\nend\n"
    @test occursin("positional", something(CB.check_impl_conventions("f!", bad1), ""))

    # 규약 1: 키워드는 기본값이 있어야 한다
    bad2 = "function f!(env; k)\n    return :ok\nend\n"
    @test CB.check_impl_conventions("f!", bad2) !== nothing

    # 규약 4: 최상위 표현식이 둘
    bad3 = "const X = 1\nfunction f!(env; k = 1)\n    return :ok\nend\n"
    @test occursin("single_expression", something(CB.check_impl_conventions("f!", bad3), ""))

    # 규약 4: 함수가 아니다
    @test CB.check_impl_conventions("f!", "x = 1\n") !== nothing

    # 이름 불일치
    @test occursin("name_mismatch",
                   something(CB.check_impl_conventions("g!", OK_CODE), ""))

    # 규약 5: 🔴 기존 이름을 덮으면 시뮬레이터 코드를 런타임에 교체하는 것이다
    clash = "function reform_stuck_teams!(env; k = 1)\n    return :ok\nend\n"
    @test occursin("name_exists",
                   something(CB.check_impl_conventions("reform_stuck_teams!", clash), ""))

    # 파싱 불가
    @test CB.check_impl_conventions("f!", "function f!(env; k = 1)\n") !== nothing
end
```

- [ ] **Step 2: 빨간 것을 확인한다**

Run: `julia +lts --project=. -e 'include("test/minted_registration.jl")'`
Expected: `UndefVarError: check_impl_conventions not defined`

- [ ] **Step 3: 구현한다**

```julia
"""
    check_impl_conventions(name, code) -> Union{Nothing,String}

설계 §5 의 규약 다섯. 통과하면 `nothing`, 아니면 **거절 사유**다. 순수 함수 —
`eval` 도 세계도 건드리지 않는다.

🔴 규약 1 이 존재 이유의 절반이다: `f(env; kw…)` 로 고정하면 `_enactability` 의
   arity·kwargs 연언지를 **구성상** 통과한다. 오늘 19개 중 9개를 막고 있는 그 결함
   (impl 이 params 를 위치인자로 받는다)이 새 원시에서는 원천적으로 안 생긴다.
🔴 규약 5 는 이 사슬에서 가장 나쁜 사고를 막는다 — `Core.eval` 이 기존 이름을 덮으면
   시뮬레이터 코드를 런타임에 교체한다.
"""
function check_impl_conventions(name::AbstractString, code::AbstractString)
    endswith(name, "!") || return "reject:impl_name_must_end_with_bang:$(name)"
    Base.isidentifier(chop(name)) || return "reject:impl_name_not_an_identifier:$(name)"
    isdefined(@__MODULE__, Symbol(name)) &&
        return "reject:impl_name_exists:$(name) — 기존 이름을 덮을 수 없다"

    local top
    try
        top = Meta.parseall(code)          # 🔴 parse 가 아니라 parseall — parse 는 첫 식만 읽는다
    catch e
        return "reject:impl_parse_failed:" * first(split(sprint(showerror, e), "\n"))
    end
    exprs = [x for x in top.args if !(x isa LineNumberNode)]
    length(exprs) == 1 ||
        return "reject:impl_not_single_expression:$(length(exprs))"
    f = exprs[1]
    (f isa Expr && f.head === :function) || return "reject:impl_not_a_function"

    sig = f.args[1]
    (sig isa Expr && sig.head === :call) || return "reject:impl_signature_unreadable"
    String(sig.args[1]) == String(name) ||
        return "reject:impl_name_mismatch:$(sig.args[1]) != $(name)"

    rest = sig.args[2:end]
    kwblock = findfirst(x -> x isa Expr && x.head === :parameters, rest)
    kws = kwblock === nothing ? Any[] : rest[kwblock].args
    pos = kwblock === nothing ? rest : rest[setdiff(eachindex(rest), kwblock)]
    (length(pos) == 1 && pos[1] === :env) ||
        return "reject:impl_positional_args_must_be_exactly_env:$(pos)"
    for k in kws
        (k isa Expr && k.head === :kw) ||
            return "reject:impl_keyword_needs_a_default:$(k)"
    end
    return nothing
end
```

🔴 **규약 3(읽을 수 있는 status 반환)은 여기서 검사하지 않는다** — 반환값은 정적으로 알 수
없다. 그것은 **런타임에** `_step_status` 가 강제하고, 못 읽으면 `:unreadable_return` 으로
기록된다("집행됐는데 효과를 못 쟀다"). 규약 문구는 프롬프트(Task 7 의 `_RULES`)가 나른다.
즉 규약 다섯 중 넷은 등록 전에, 하나는 집행 후 기록으로 지켜진다.

- [ ] **Step 4: 초록을 확인한다**

Run: `julia +lts --project=. -e 'include("test/minted_registration.jl")'`
Expected: 전부 통과

- [ ] **Step 5: 커밋**

```bash
git add src/respec/minted_registration.jl test/minted_registration.jl
git commit -m "생성 구현의 규약 다섯을 검사한다 (설계 §5)"
```

---

### Task 4: `register_minted_primitive!` — eval 과 등록

**Files:**
- Modify: `src/respec/minted_registration.jl`
- Modify: `test/minted_registration.jl`

**Interfaces:**
- Produces: `register_minted_primitive!(; name, code, params, surface, reversible) -> Union{Nothing,String}`
- Consumes: `check_impl_conventions` (Task 3) · `minted_table` (Task 2)

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
@testset "(5) 등록하면 해석되고 집행 가능하다" begin
    CB.reset_minted_table!()
    why = CB.register_minted_primitive!(
        name = "adjust_thing!", code = OK_CODE,
        params = Dict{String,Any}("factor" => Dict{String,Any}("type" => "number")),
        surface = "env_param", reversible = true)
    @test why === nothing
    r = CB.resolve_primitive("adjust_thing!")
    @test r !== nothing
    # 🔴 규약 1 의 값: 구성상 집행 가능해야 한다. 오늘 19개 중 9개를 막는 arity 결함이
    #    새 원시에서는 안 생긴다는 것이 이 한 줄로 측정된다.
    @test r.enactable === true
    @test r.harness_args == ["env"]
    @test haskey(r.params, "factor")
end

@testset "(6) 규약 위반은 거절이고 표를 안 건드린다" begin
    CB.reset_minted_table!()
    why = CB.register_minted_primitive!(
        name = "bad!", code = "function bad!(env, x; k = 1)\n    return :ok\nend\n",
        params = Dict{String,Any}(), surface = "sched", reversible = false)
    @test why !== nothing && occursin("positional", why)
    @test isempty(CB.minted_table())          # 부분 등록이 없다
end

@testset "(7) eval 실패는 예외가 아니라 거절이다" begin
    CB.reset_minted_table!()
    why = CB.register_minted_primitive!(
        name = "boom!", code = "function boom!(env; k = 1)\n    @no_such_macro\nend\n",
        params = Dict{String,Any}(), surface = "sched", reversible = false)
    @test why !== nothing && occursin("eval_failed", why)
    @test isempty(CB.minted_table())
end
```

- [ ] **Step 2: 빨간 것을 확인한다**

Run: `julia +lts --project=. -e 'include("test/minted_registration.jl")'`
Expected: `UndefVarError: register_minted_primitive! not defined`

- [ ] **Step 3: 구현한다**

```julia
"""
    register_minted_primitive!(; name, code, params, surface, reversible) -> Union{Nothing,String}

규약 검사 → `Core.eval` → 런-스코프 표에 등록. 통과하면 `nothing`, 아니면 거절 사유.

🔴 **던지지 않는다.** 여기서 예외가 새면 집행부가 기록 대신 예외로 끝나고 호출자는 세계
   상태를 알 방법을 잃는다 — 이 파일 전체가 지키는 규약이다.
🔴 **부분 등록이 없다.** eval 이 실패하면 표에 아무것도 안 남는다.
"""
function register_minted_primitive!(; name::AbstractString, code::AbstractString,
                                     params, surface::AbstractString = "unknown",
                                     reversible::Bool = false)
    why = check_impl_conventions(name, code)
    why === nothing || return why
    try
        Core.eval(@__MODULE__, Meta.parseall(code))
    catch e
        return "reject:impl_eval_failed:" * first(split(sprint(showerror, e), "\n"))
    end
    minted_table()[String(name)] = Dict{String,Any}(
        "name"         => String(name),
        "impl"         => String(name),   # 함수 자신이 원시다 — 이름이 둘일 이유가 없다
        "surface"      => String(surface),
        "harness_args" => ["env"],        # 규약 1
        "params"       => Dict{String,Any}(String(k) => v for (k, v) in pairs(params)),
        "reversible"   => reversible)
    return nothing
end
```

- [ ] **Step 4: 초록을 확인한다**

Run: `julia +lts --project=. -e 'include("test/minted_registration.jl")'`
Expected: 전부 통과

- [ ] **Step 5: 커밋**

```bash
git add src/respec/minted_registration.jl test/minted_registration.jl
git commit -m "생성 구현을 eval 하고 런-스코프 표에 등록한다"
```

---

### Task 5: world age — `invokelatest` 로 부른다

**Files:**
- Modify: `src/respec/minted_tool.jl` (집행 루프의 호출 한 줄)
- Modify: `test/minted_registration.jl`

**Interfaces:**
- Consumes: `register_minted_primitive!` (Task 4)

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
@testset "(8) 🔴 방금 eval 한 함수를 같은 호출 스택에서 부를 수 있다 (world age)" begin
    # Julia 는 `Core.eval` 로 정의된 메서드를 **현재 world** 에서 직접 못 부른다.
    # `invokelatest` 없이는 여기서 MethodError 가 나고, 집행부의 try 가 그것을
    # `:threw`/`partial=true` 로 적어 "세계가 절반일 수 있다" 는 **거짓 기록**이 남는다.
    CB.reset_minted_table!()
    code = """
    function touch_nothing!(env; note = "x")
        return (status = :did_nothing, note = note)
    end
    """
    @test CB.register_minted_primitive!(name = "touch_nothing!", code = code,
                                        params = Dict{String,Any}("note" => Dict{String,Any}("type" => "string")),
                                        surface = "sched", reversible = true) === nothing
    fake = (staging_circles = Dict{Symbol,Any}(),)
    synth = Dict{String,Any}("reach" => "composed", "body_names" => ["touch_nothing!"],
                             "tool_name" => "t", "params" => Dict{String,Any}(),
                             "missing_primitive" => nothing,
                             "calls" => [Dict{String,Any}("primitive" => "touch_nothing!",
                                                          "args" => Dict{String,Any}("note" => "hi"))])
    r = CB.enact_minted!(fake, nothing, synth)
    @test r.verdict === :admit
    @test length(r.steps) == 1 && r.steps[1].status === :did_nothing
    @test r.partial === false                   # 🔴 world age 로 던지지 않았다
    @test r.args_from === :calls && r.n_calls == 1
end
```

- [ ] **Step 2: 빨간 것을 확인한다**

Run: `julia +lts --project=. -e 'include("test/minted_registration.jl")'`
Expected: `r.steps[1].status` 가 `:threw` 이고 `r.partial === true` — 즉 `MethodError` 가 world age 때문에 났다.

- [ ] **Step 3: 구현한다**

`src/respec/minted_tool.jl` 의 집행 루프에서 한 줄을 바꾼다:

```julia
            out = Base.invokelatest(r.prim.impl, r.args[1]...; r.args[2]...)
```

바로 위에 이유를 적는다:

```julia
            # 🔴 `invokelatest` 다. 생성 원시는 이 호출 **직전**에 `Core.eval` 로 정의되므로
            #    현재 world age 에서는 안 보인다. 맨 호출은 `MethodError` 가 되고 아래 `try`
            #    가 그것을 `:threw`/`partial=true` 로 적어 "세계가 절반일 수 있다" 는 **거짓
            #    기록**을 남긴다 — 세계는 손도 안 댄 상태인데.
```

- [ ] **Step 4: 초록을 확인한다**

Run: `julia +lts --project=. -e 'include("test/minted_registration.jl")'`
Expected: 전부 통과

Run: `julia +lts --project=. -e 'include("test/minted_tool_enacts.jl")'`
Expected: `invokelatest` 가 기존 원시 호출을 깨지 않는지 확인(레지스트리 종속 절은 Task 10 에서 정리한다 — 지금은 그 절들이 빨간 것이 정상이다).

- [ ] **Step 5: 커밋**

```bash
git add src/respec/minted_tool.jl test/minted_registration.jl
git commit -m "생성 원시를 invokelatest 로 부른다 (world age)"
```

---

### Task 6: `world_interface.json` 생성기와 게이트

**Files:**
- Create: `tools/gen_world_interface.jl`
- Create: `wm4spacecraft_manufacturing/core/world_interface.json` (생성물, 커밋한다)
- Create: `test/world_interface_current.jl`
- Modify: `test/runtests.jl` (게이트 등록)

**Interfaces:**
- Produces: `world_interface.json` — `{"types": [{"name","fields":[{"name","type"}]}], "methods": [{"name","signature"}]}`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/world_interface_current.jl
module WorldInterfaceCurrent
using Test
using ConstructionBots
import JSON3
const CB = ConstructionBots
const ART = normpath(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "core",
                              "world_interface.json"))

@testset "(1) 산출물이 있고 모양이 맞다" begin
    @test isfile(ART)
    j = JSON3.read(read(ART, String))
    @test haskey(j, :types) && haskey(j, :methods)
    @test !isempty(j.types) && !isempty(j.methods)
end

@testset "(2) 🔴 현행 코드와 일치한다 — 재생성해서 대조한다" begin
    # 손으로 유지되는 사본은 반드시 낡는다. `code_fingerprint` 와 같은 논거다.
    mktempdir() do dir
        out = joinpath(dir, "regen.json")
        run(`julia +lts --project=$(normpath(joinpath(@__DIR__, ".."))) $(normpath(joinpath(@__DIR__, "..", "tools", "gen_world_interface.jl"))) $(out)`)
        @test read(out, String) == read(ART, String)
    end
end

@testset "(3) PlannerEnv 의 필드가 전부 실려 있다" begin
    j = JSON3.read(read(ART, String))
    t = only(filter(x -> x.name == "PlannerEnv", collect(j.types)))
    @test Set(String.([f.name for f in t.fields])) ==
          Set(String.(collect(fieldnames(CB.PlannerEnv))))
end

@testset "(4) 🔴 비공개 impl 은 실리지 않는다 (설계 D6)" begin
    # 사용자 결정: 표면은 `names(CB)` 그대로. 모델은 `release_pending_assignments!` 를
    # 모른다 — 그 능력을 처음부터 다시 써야 하는 것이 이 설계의 첫 측정 대상이다.
    j = JSON3.read(read(ART, String))
    ms = Set(String.([m.name for m in j.methods]))
    @test !("release_pending_assignments!" in ms)
    @test "reform_stuck_teams!" in ms          # 빈-통과 방지: export 된 것은 실린다
end
end # module
```

- [ ] **Step 2: 빨간 것을 확인한다**

Run: `julia +lts --project=. -e 'include("test/world_interface_current.jl")'`
Expected: `(1)` 이 `isfile(ART)` 에서 실패.

- [ ] **Step 3: 생성기를 쓴다**

```julia
# tools/gen_world_interface.jl
# 생성 agent 가 코드를 쓰기 위해 보는 세계 인터페이스. (2026-09-03, 설계 §4)
#
# 🔴 손으로 적지 않는다. `primitive_registry.json` 과 같은 패턴 — Julia 가 생성하고 두
#    언어가 읽는 한 파일이며, 게이트가 현행 코드와의 일치를 지킨다.
using ConstructionBots
import JSON3
const CB = ConstructionBots

_tname(T) = string(nameof(T isa UnionAll ? Base.unwrap_unionall(T) : T))

function type_entry(T)
    Dict("name" => _tname(T),
         "fields" => [Dict("name" => string(f), "type" => string(t))
                      for (f, t) in zip(fieldnames(T), fieldtypes(T))])
end

function method_entries()
    out = Dict{String,Any}[]
    for n in sort(names(CB))
        isdefined(CB, n) || continue
        f = getfield(CB, n)
        f isa Function || continue
        for m in methods(f)
            push!(out, Dict("name" => string(n), "signature" => string(m.sig)))
        end
    end
    return out
end

# 타입은 PlannerEnv 에서 **1단계만** 전개한다 (무한 전개 금지).
roots = [CB.PlannerEnv]
seen  = Set{String}()
types = Dict{String,Any}[]
for T in roots
    push!(types, type_entry(T)); push!(seen, _tname(T))
    for ft in fieldtypes(T)
        S = ft isa UnionAll ? Base.unwrap_unionall(ft) : ft
        (S isa DataType && isstructtype(S) && !(_tname(S) in seen)) || continue
        push!(types, type_entry(S)); push!(seen, _tname(S))
    end
end

dst = length(ARGS) >= 1 ? ARGS[1] :
      normpath(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "core",
                        "world_interface.json"))
open(dst, "w") do io
    JSON3.pretty(io, Dict("types" => types, "methods" => method_entries()))
end
println("wrote ", dst)
```

생성한다: `julia +lts --project=. tools/gen_world_interface.jl`

`test/runtests.jl` 에 게이트를 등록한다 (`minted tool enacts` 앞):

```julia
    # 🔴 생성 agent 가 보는 세계 인터페이스가 현행 코드와 같은가. 손 사본은 반드시 낡는다.
    @testset "world interface is current" begin
        include("world_interface_current.jl")
    end
```

- [ ] **Step 4: 초록을 확인한다**

Run: `julia +lts --project=. -e 'include("test/world_interface_current.jl")'`
Expected: 전부 통과

- [ ] **Step 5: 커밋**

```bash
git add tools/gen_world_interface.jl wm4spacecraft_manufacturing/core/world_interface.json test/world_interface_current.jl test/runtests.jl
git commit -m "세계 인터페이스 산출물과 최신성 게이트"
```

---

### Task 7: 파이썬이 세계 인터페이스를 프롬프트 블록으로 만든다

**Files:**
- Create: `src/respec/llm_service/world_interface.py`
- Create: `src/respec/llm_service/test_world_interface_block.py`

**Interfaces:**
- Produces: `load_world_interface(path=None) -> dict` · `build_world_interface_block(blob=None) -> str`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```python
# src/respec/llm_service/test_world_interface_block.py
"""생성 agent 가 읽는 세계 인터페이스 블록. 유료 0건."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import world_interface as WI  # noqa: E402


def test_the_artifact_loads():
    b = WI.load_world_interface()
    assert b["types"] and b["methods"]


def test_the_block_carries_the_env_schema():
    s = WI.build_world_interface_block()
    assert "PlannerEnv" in s
    for f in ("sched", "scene_tree", "cache", "staging_circles"):
        assert f in s, f


def test_the_block_carries_method_signatures():
    s = WI.build_world_interface_block()
    assert "reform_stuck_teams!" in s


def test_the_block_hides_the_non_exported_impls():
    """🔴 설계 D6. 이것이 참이라서 첫 측정이 뜻을 갖는다."""
    s = WI.build_world_interface_block()
    assert "release_pending_assignments!" not in s


def test_the_block_says_the_signature_convention():
    """모델이 규약 1 을 안 읽으면 등록이 전부 거절된다."""
    s = WI.build_world_interface_block()
    assert "(env;" in s and "keyword" in s.lower()
```

- [ ] **Step 2: 빨간 것을 확인한다**

Run: `python3 -m pytest src/respec/llm_service/test_world_interface_block.py -q`
Expected: `ModuleNotFoundError: No module named 'world_interface'`

- [ ] **Step 3: 구현한다**

```python
# src/respec/llm_service/world_interface.py
"""생성 agent 가 코드를 쓰기 위해 읽는 세계 인터페이스. (2026-09-03, 설계 §4)

🔴 리터럴을 여기 적지 않는다. `tools/gen_world_interface.jl` 이 만든 산출물 하나를 읽고,
   그 산출물이 현행 코드와 같은지는 `test/world_interface_current.jl` 이 지킨다.
"""
import json
import os
from typing import Any, Dict, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
WM = os.environ.get("WM_DIR") or os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(HERE))), "wm4spacecraft_manufacturing")
ARTIFACT = os.path.join(WM, "core", "world_interface.json")

_CACHE: Dict[str, Any] = {}


def load_world_interface(path: Optional[str] = None) -> Dict[str, Any]:
    """🔴 조용한 폴백을 두지 않는다 — 파일이 없으면 큰 소리로 죽는다. 빈 인터페이스로
    돌면 모델은 아무것도 못 부르는 코드를 쓰고, 그 실패가 모델 탓으로 기록된다."""
    p = path or ARTIFACT
    if p not in _CACHE:
        with open(p, encoding="utf-8") as fh:
            _CACHE[p] = json.load(fh)
    return _CACHE[p]


_RULES = (
    "HOW YOUR CODE IS CALLED -- these are hard requirements, not style:\n"
    "  1. Exactly one top-level definition: `function NAME!(env; k1=<default>, ...) ... end`.\n"
    "     `env` is the ONLY positional argument. Every other argument is a keyword and MUST\n"
    "     have a default. The harness builds `env` and passes your declared parameters as\n"
    "     keywords; any other shape cannot be called and is rejected before it runs.\n"
    "  2. The name must end with `!` and must NOT already exist in the module.\n"
    "  3. Return a value the harness can read a status from: either a Symbol, or a NamedTuple\n"
    "     with a `status::Symbol` field. That status is how the record says what happened.\n"
    "  4. No other definitions -- no `const`, no macros, no helper functions.\n"
)


def build_world_interface_block(blob=None) -> str:
    b = blob if blob is not None else load_world_interface()
    parts = [_RULES, "", "WORLD TYPES (fields you may read and write):"]
    for t in b["types"]:
        parts.append("- %s" % t["name"])
        for f in t["fields"]:
            parts.append("    %s :: %s" % (f["name"], f["type"]))
    parts += ["", "FUNCTIONS THE MODULE ALREADY HAS (call any of these from your body):"]
    for m in b["methods"]:
        parts.append("- %s %s" % (m["name"], m["signature"]))
    return "\n".join(parts)
```

- [ ] **Step 4: 초록을 확인한다**

Run: `python3 -m pytest src/respec/llm_service/test_world_interface_block.py -q`
Expected: 5 passed

- [ ] **Step 5: 커밋**

```bash
git add src/respec/llm_service/world_interface.py src/respec/llm_service/test_world_interface_block.py
git commit -m "세계 인터페이스를 프롬프트 블록으로 만든다"
```

---

### Task 8: agent-3 을 `WriteToolImpl` 로 교체

**Files:**
- Modify: `src/respec/llm_service/synthesize.py` (`ComposeToolBody` → `WriteToolImpl`, `synthesize_multi` 3단계, `_finish_record`)
- Create: `src/respec/llm_service/test_write_tool_impl.py`

**Interfaces:**
- Consumes: `build_world_interface_block` (Task 7)
- Produces: 기록 필드 `impl_name` · `impl_code` · `wrote` · `body_names`(= `[impl_name]`) · `calls`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```python
# src/respec/llm_service/test_write_tool_impl.py
"""agent-3 은 조합기가 아니라 **작성자**다. 유료 0건 — 프로그램을 가짜로 물린다."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import synthesize as SY  # noqa: E402


class _Pred:
    def __init__(self, **kw):
        self.__dict__.update(kw)


OK_CODE = 'function adjust_thing!(env; factor = 1.0)\n    return (status = :adjusted,)\nend\n'


def _programs(code=OK_CODE, name="adjust_thing!"):
    def observe(**kw):
        return _Pred(reasoning_log="the robot is degraded")

    def design(**kw):
        return _Pred(expressible=False, tool_name="T",
                     params='{"factor": {"type": "number"}}', mechanism="m")

    def write(**kw):
        return _Pred(impl_name=name, impl_code=code,
                     params='{"factor": {"type": "number"}}',
                     calls=[{"primitive": name, "args": {"factor": 1.5}}],
                     surface="env_param", reversible=True, wrote=True)

    return {"observe": observe, "design": design, "compose": write}


def test_the_write_stage_receives_the_world_interface(monkeypatch):
    monkeypatch.setenv(SY.SYNTHESIS_ENV, "1")
    seen = {}

    progs = _programs()
    inner = progs["compose"]

    def spy(**kw):
        seen.update(kw)
        return inner(**kw)

    progs["compose"] = spy
    SY.synthesize_multi(state="s", tools=[], ledger=SY.SynthesisLedger(), programs=progs)
    assert "PlannerEnv" in seen["world_interface"]
    assert "reform_stuck_teams!" in seen["world_interface"]


def test_the_record_carries_the_generated_code(monkeypatch):
    monkeypatch.setenv(SY.SYNTHESIS_ENV, "1")
    rec = SY.synthesize_multi(state="s", tools=[], ledger=SY.SynthesisLedger(),
                              programs=_programs())
    assert rec["impl_name"] == "adjust_thing!"
    assert "function adjust_thing!" in rec["impl_code"]
    assert rec["wrote"] is True


def test_body_names_is_the_generated_name(monkeypatch):
    """🔴 집행부는 `body_names` 를 읽는다. 그 자리에 생성 이름이 와야 경로가 이어진다."""
    monkeypatch.setenv(SY.SYNTHESIS_ENV, "1")
    rec = SY.synthesize_multi(state="s", tools=[], ledger=SY.SynthesisLedger(),
                              programs=_programs())
    assert rec["body_names"] == ["adjust_thing!"]
    assert rec["calls"] == [{"primitive": "adjust_thing!", "args": {"factor": 1.5}}]
    assert rec["calls_match_body"] is True


def test_a_stage_that_refuses_records_it(monkeypatch):
    """못 쓰겠다는 자기신고는 빈 값과 다른 사건이다."""
    monkeypatch.setenv(SY.SYNTHESIS_ENV, "1")
    progs = _programs()
    progs["compose"] = lambda **kw: _Pred(impl_name="", impl_code="", params="",
                                          calls=[], surface="", reversible=False, wrote=False)
    rec = SY.synthesize_multi(state="s", tools=[], ledger=SY.SynthesisLedger(), programs=progs)
    assert rec["wrote"] is False and rec["body_names"] == []
```

- [ ] **Step 2: 빨간 것을 확인한다**

Run: `python3 -m pytest src/respec/llm_service/test_write_tool_impl.py -q`
Expected: `KeyError: 'world_interface'` / `impl_name` 없음.

- [ ] **Step 3: 구현한다**

`ComposeToolBody` 를 지우고 그 자리에 넣는다:

```python
class WriteToolImpl(dspy.Signature):
    """You are given a tool specification and the schema and function signatures of a
    running multi-robot construction simulator. WRITE THE JULIA IMPLEMENTATION of the
    specified tool as a single function. You are not given a catalogue of ready-made
    operations -- there is none. Read the world's types and the functions the module
    already has, and write the code that produces the specified effect."""
    spec: str = dspy.InputField(desc=
        "physical principles of this build, the final goal, what the event broke, and the "
        "tool to build: name, parameter schema, mechanism")
    world_interface: str = dspy.InputField(desc=
        "the world's types and fields, the functions the module already has, and the hard "
        "requirements your function must satisfy to be callable")

    impl_name: str = dspy.OutputField(desc="the Julia function name; must end with `!`")
    impl_code: str = dspy.OutputField(desc=
        "exactly one `function <impl_name>(env; k=<default>, ...) ... end` and nothing else")
    params: str = dspy.OutputField(desc="JSON schema of the keyword arguments")
    calls: List[Dict[str, Any]] = dspy.OutputField(desc=
        'the arguments to use for THIS event: [{"primitive": "<impl_name>", '
        '"args": {<keyword>: <value>}}]')
    surface: str = dspy.OutputField(desc="which world surface this edits")
    reversible: bool = dspy.OutputField(desc="can this be undone")
    wrote: bool = dspy.OutputField(desc="false if you could not write an implementation")
```

`synthesize_multi` 의 3단계를 바꾼다:

```python
    p3 = compose(spec=build_compose_context(spec, rec["reasoning_log"], blob),
                 world_interface=build_world_interface_block())
    ...
    rec["impl_name"] = (getattr(p3, "impl_name", "") or "")
    rec["impl_code"] = (getattr(p3, "impl_code", "") or "")
    rec["surface"]   = (getattr(p3, "surface", "") or "")
    rec["reversible"] = getattr(p3, "reversible", None)
    w = getattr(p3, "wrote", None)
    rec["wrote"] = w if isinstance(w, bool) else None
    rec["calls"] = getattr(p3, "calls", None)
    # 🔴 집행부는 `body_names` 를 읽는다. 생성 원시는 하나이므로 그 이름 하나가 body 다.
    rec["body_names"] = [rec["impl_name"]] if rec["impl_name"] else []
```

`_finish_record` 에서 `body_names` 를 `parse_body` 대신 위 값으로 두고, `calls_match_body` 는 그대로 둔다.

F2 되먹임은 `wrote is False` 에서만 발화하도록 조건을 바꾼다(`reach == "needs_primitive"` 자리).

- [ ] **Step 4: 초록을 확인한다**

Run: `python3 -m pytest src/respec/llm_service/test_write_tool_impl.py -q`
Expected: 4 passed

- [ ] **Step 5: 커밋**

```bash
git add src/respec/llm_service/synthesize.py src/respec/llm_service/test_write_tool_impl.py
git commit -m "agent-3 을 조합기에서 Julia 구현 작성자로 교체한다"
```

---

### Task 9: 경계 — 생성 코드가 Julia 까지 간다

**Files:**
- Modify: `tools/monitor/policy.jl` (`SYNTH_LANE_KEYS`)
- Modify: `tools/monitor/enact.jl` (등록 호출)
- Modify: `test/synth_lane_keys_survive.jl`
- Create: `test/minted_end_to_end.jl`

**Interfaces:**
- Consumes: `register_minted_primitive!` (Task 4) · 기록 필드 (Task 8)
- Produces: 결정 행이 `impl_name`·`impl_code`·`surface`·`reversible` 을 나른다

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/minted_end_to_end.jl
module MintedEndToEnd
using Test
using ConstructionBots
import JSON3
const CB = ConstructionBots
include(joinpath(@__DIR__, "..", "tools", "monitor", "enact.jl"))

# 🔴 서비스 응답과 **같은 타입**으로 왕복시킨다. 손으로 지은 Dict{String,Any} 픽스처는
#    JSON3.Object 가 아니라서, 라이브에서만 나는 실패를 못 잡는다.
const RESP = JSON3.read(JSON3.write(Dict{String,Any}(
    "chosen" => "NOOP", "ranking" => ["NOOP"], "margin" => nothing, "rationale" => "r",
    "policy" => "dspy", "coerced" => false, "error" => nothing, "tool_minted" => true,
    "synthesis" => Dict{String,Any}(
        "synthesis_event" => true, "ran" => true, "error" => nothing,
        "tool_name" => "T", "impl_name" => "e2e_touch!",
        "impl_code" => "function e2e_touch!(env; note = \"x\")\n    return (status = :e2e_ok, note = note)\nend\n",
        "surface" => "sched", "reversible" => true,
        "params" => Dict{String,Any}("note" => Dict{String,Any}("type" => "string")),
        "body_names" => ["e2e_touch!"], "wrote" => true,
        "calls" => [Dict{String,Any}("primitive" => "e2e_touch!",
                                     "args" => Dict{String,Any}("note" => "hi"))]))))

@testset "생성 코드가 응답에서 집행까지 간다" begin
    CB.reset_minted_table!()
    e = policy_entry(RESP, "dspy")
    for k in ("impl_name", "impl_code", "surface", "reversible")
        @test haskey(e, k)
    end
    dec = (macro_name = "NOOP", synth_lane = e)
    r = enact_minted_decision!((staging_circles = Dict{Symbol,Any}(),), nothing, dec)
    @test r.verdict === :admit
    @test r.args_from === :calls && r.n_calls == 1
    @test length(r.steps) == 1 && r.steps[1].status === :e2e_ok
end
end # module
```

- [ ] **Step 2: 빨간 것을 확인한다**

Run: `julia +lts --project=. -e 'include("test/minted_end_to_end.jl")'`
Expected: `haskey(e,"impl_name")` 가 false — 경계 키에 없다.

- [ ] **Step 3: 구현한다**

`tools/monitor/policy.jl` 의 `SYNTH_LANE_KEYS` 를 바꾼다 — `reach`·`missing_primitive` 를 빼고 넷을 더한다:

```julia
const SYNTH_LANE_KEYS = ("tool_minted", "synthesis_event", "synthesis_ran", "synthesis_error",
                         "tool_name", "body_names", "params", "calls",
                         "impl_name", "impl_code", "surface", "reversible", "wrote")
```

`tools/monitor/enact.jl` 의 `enact_minted_decision!` 에서, `CB.enact_minted!` 를 부르기 **전에** 등록한다:

```julia
        # 🔴 등록이 먼저다. 생성 원시는 이 순간까지 존재하지 않는다 — 등록에 실패하면
        #    집행을 시도하지 않고 그 사유를 그대로 나른다(예외가 아니라 거절).
        local nm = _synth_lane_field(sl, "impl_name")
        local cd = _synth_lane_field(sl, "impl_code")
        if nm !== nothing && cd !== nothing && !isempty(String(nm))
            local why = CB.register_minted_primitive!(
                name = String(nm), code = String(cd),
                params = something(_synth_lane_field(sl, "params"), Dict{String,Any}()),
                surface = String(something(_synth_lane_field(sl, "surface"), "unknown")),
                reversible = something(_synth_lane_field(sl, "reversible"), false) === true)
            if why !== nothing
                println("[minted] lane=present tool=", something(_synth_lane_field(sl, "tool_name"), "?"),
                        " verdict=reject registered=false reason=", why)
                return (handled = false, verdict = :reject, reason = why,
                        applied = false, partial = false, world_maybe_dirty = false,
                        steps = NamedTuple[], undo = :none, resume = :none, resolve = :none,
                        args_from = nothing, n_calls = nothing)
            end
        end
```

🔴 **`reach` 게이트는 하나가 아니라 둘이다 — 둘 다 바꿔야 한다.**
⚠️ 2026-09-03 실행 중 정정(독립 검증): 아래 문단은 원래 `minted_tool.jl` step (1) 하나만
가리켰는데 **틀렸다**. `tools/monitor/enact.jl` 이 `enact_minted!` 를 부르기 전에 **자기
`reach` 게이트를 따로** 갖고 있고 **그것이 먼저 발화한다** — `minted_tool.jl` step (1) 은
그 경로에서 도달조차 되지 않는다. 그래서 계획서 문장대로 `minted_tool.jl` 만 고치면
**모든 집행이 여전히 deferred 인데 로그는 방금 고친 자리를 지목한다.**
`reach` 를 경계 키에서 빼면 두 게이트 다 `impl_name` 으로 옮긴다:

```julia
    nm = _synth_get(synth, "impl_name", nothing)
    nm === nothing && return _r(:deferred, "impl_name missing — 합성 레인이 값을 안 실었다")
    # 🔴 `sanctioned`/`admit_unsanctioned` 는 사라진다. 그것은 "모델이 조합에 실패했다고
    #    신고했는데 body 는 있다" 를 재던 구분인데, 조합 단계 자체가 없어졌다.
    admit_verdict = :admit
```
`unsanctioned_note` 와 `missing_primitive` 인용도 같이 지운다. `test/minted_tool_enacts.jl`
명제 (1) 이 그 구분을 재므로 Task 10 에서 함께 갱신한다.

🔴 **등록 결과를 기록에 남긴다**(설계 §8). `enact_minted_decision!` 의 반환과 `[minted]`
줄에 `registered` 와 `impl_rejected_why::Union{Nothing,String}` 을 싣는다 — 없으면
"모델이 코드를 안 냈다" 와 "냈는데 규약 위반으로 거절됐다" 가 같은 관측이 된다.
⚠️ 2026-09-03 정정(Ruling R7): 원래 여기 `registered::Bool` 이라고 적혀 있었고 **그 타입이
틀렸다.** `catch` 스코프는 `try` 안에서 선언된 `local registered` 를 못 본다 — `Core.eval` 이
성공한 **뒤에** 던지면 표에는 원시가 있는데 기록은 `registered=false` 라고 **거짓말한다.**
정직한 타입은 `Union{Nothing,Bool}` 이고, 선언은 `try` **앞**이다.
🔴 그리고 이 두 필드는 **반환 경로 전부**에 실어야 한다(계획서의 거절-경로 코드 조각은 그 둘을
빠뜨린다). 한 경로에만 없으면 소비자가 키 부재로 두 사건을 못 가른다.

`test/synth_lane_keys_survive.jl` 의 (1)절 리터럴과 픽스처를 새 키 집합으로 갱신한다.

- [ ] **Step 4: 초록을 확인한다**

Run: `julia +lts --project=. -e 'include("test/minted_end_to_end.jl")'`
Expected: 전부 통과
Run: `julia +lts --project=. -e 'include("test/synth_lane_keys_survive.jl")'`
Expected: 전부 통과

- [ ] **Step 5: 커밋**

```bash
git add tools/monitor/policy.jl tools/monitor/enact.jl test/synth_lane_keys_survive.jl test/minted_end_to_end.jl
git commit -m "생성 코드를 경계 너머로 나르고 집행 직전에 등록한다"
```

---

### Task 10: 남은 레지스트리 종속 시험을 정리하고 두 스위트를 초록으로

**Files:**
- Modify: `test/minted_tool_enacts.jl` (명제 (9)·(9b)·(12) 삭제, `_synth` 헬퍼에서 `reach` 제거)
- Modify: `tools/monitor/test_minted_wiring.jl` (`_sl` 헬퍼, `_reset_primitive_table!` 사용처)
- Modify: `src/respec/llm_service/test_synthesize_multi.py` (계약 (B) 누수 가드·redaction 절 삭제)
- Modify: `src/respec/llm_service/test_synthesize.py` (단일 레인 시험 삭제)
- Modify: `test/payload_reprice_install.jl` · `test/runtests.jl` (주석의 죽은 참조 정리)

- [ ] **Step 1: 무엇이 빨간지 먼저 잰다**

Run: `python3 -m pytest -q 2>&1 | tail -20`
Run: `julia +lts --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -30`
실패 목록을 그대로 적어 둔다. 🔴 "지우면 초록이 되겠지" 로 지우지 말 것 — 각 실패가 (a) 삭제된 어휘 때문인지 (b) 이 계획이 만든 회귀인지 구분한다. (b) 는 고치고, (a) 만 지운다.

- [ ] **Step 2: (a) 항목만 삭제한다**

명제 (9)(알파벳 19 중 8), (9b)(레지스트리 도장 대조), (12)(이름→impl 짝)는 **재던 대상이 없어졌다**. 삭제하고 `test/runtests.jl` 의 해당 주석 문단도 같이 지운다.

- [ ] **Step 3: 두 스위트를 돌린다**

Run: `python3 -m pytest -q`
Expected: 0 failed
Run: `julia +lts --project=. -e 'using Pkg; Pkg.test()'`
Expected: Gurobi 라이선스 에러 1건 외 0 failed

- [ ] **Step 4: 변이시험**

각 새 게이트가 하중을 지는지 확인한다(사본 위에서, 생산 소스는 되돌린다):
- `check_impl_conventions` 의 `pos[1] === :env` 검사를 지운다 → Task 3 (4)절이 빨개진다
- `register_minted_primitive!` 의 `why === nothing || return why` 를 지운다 → (6)절
- `invokelatest` 를 맨 호출로 되돌린다 → Task 5 (8)절
- `enact.jl` 의 등록 블록을 지운다 → Task 9 e2e

- [ ] **Step 5: 커밋**

```bash
git add test/minted_tool_enacts.jl tools/monitor/test_minted_wiring.jl test/runtests.jl test/payload_reprice_install.jl src/respec/llm_service/test_synthesize_multi.py src/respec/llm_service/test_synthesize.py
git commit -m "삭제된 어휘를 재던 시험을 정리한다"
```

---

### Task 11: 첫 유료 측정 — D6 이 성립하는가

**Files:** 없음(측정만). 결과는 `results/` (gitignore).

- [ ] **Step 1: 서비스를 현행 코드로 띄운다**

```bash
cd src/respec/llm_service
TOOL_SYNTHESIS=1 DSPY_CACHE=0 ../../../.venv/bin/python -m uvicorn dspy_service:app --host 127.0.0.1 --port 8077
```
확인: `python3 src/respec/llm_service/generation.py --url http://127.0.0.1:8077` 가 `OK`.
⚠️ 2026-09-03 정정(독립 검증, C11.1): 원래 여기 "🔴 `SYNTH_MULTI_AGENT` 은 없어졌다(D8)" 라고
적혀 있었고 **거짓이다.** 없어진 것은 `synthesize.py` 의 **레인 분기**뿐이고, 그 환경변수는
`dspy_service.py` 와 `generation.py` 가 **아직 읽는다**. 즉 올바른 서비스도 세대 도장에
`synth_multi_agent: false` 를 실을 수 있다 — 그 값을 "레인이 안 돈다" 로 읽지 말 것.
🔴 그리고 `render_demo.jl` 은 세대 게이트를 **추가 요구 없이** 부르므로 `TOOL_SYNTHESIS=1` 이
없는 서비스도 게이트를 통과한다 → **조용히 비어 있는 유료 런**이 된다. `REQUIRE_TOOL_SYNTHESIS=1`
을 export 할 것.

- [ ] **Step 2: mild 보드를 돌린다 (유료)**

```bash
env DEMO_MODEL=tractor.mpd DEMO_OOD=battery DEMO_BSOC=0.45 DEMO_CASE_TAG=battery_mild \
    DEMO_POLICY=dspy DEMO_ANIM=0 DSPY_URL=http://127.0.0.1:8077 \
    julia +lts --project=. tools/monitor/render_demo.jl
```

- [ ] **Step 3: 네 가지를 읽는다**

```bash
/usr/bin/grep -aE "\[router\]|\[minted\]" <로그>
# ⚠️ 2026-09-03 정정(C11.3): 원래 `readline()` 이었고 **틀렸다** — 이 파일은 append 이고
#    첫 줄은 Task 8 **이전**의 낡은 행이다. 마지막 줄을 읽는다.
python3 -c "import json; r=json.loads(open('results/synth_lane_records.jsonl').readlines()[-1]); \
print(r['impl_name']); print(r['impl_code']); print(r['wrote'])"
```

판정:
1. `wrote` 가 true 인가 — 모델이 코드를 쓰려고 했는가
2. 등록이 통과했는가(`registered` / `[minted] … registered=false reason=…`)
3. `args_from=calls` 가 찍혔는가 — 🔴 B1 배선이 라이브에서 처음 증명되는 자리
4. `steps[1].status` 가 무엇인가 — 모델이 **무슨 심볼을 반환했나**
   ⚠️ 2026-09-03 정정: 원래 "세계가 실제로 바뀌었는가" 라고 적혀 있었고 **거짓이다.**
   `steps[i].status` 는 모델의 **자기신고**이지 세계 변화의 증거가 아니다. 정본은 계획서가
   아니라 사전등록 문서다 — `docs/superpowers/reports/2026-09-03-task11-measurement-preregistration.md`
   결정 1: **Task 11 은 세계가 바뀌었는지 못 잰다**(`handled` 는 구성상 ~100%, `applied` 는 항상
   `nothing`, `world_maybe_dirty` 는 무조건 true). 계획서 텍스트로 런을 읽으면 과대주장하게 된다.

- [ ] **Step 4: 🔴 D6 판정을 기록한다**

모델이 `release_pending_assignments!` 없이 "배정 간선을 뗀다" 를 써냈는가. 실패했다면 그것은
**설계의 결과**이지 버그가 아니다 — D6 을 뒤집을지(비공개 impl 10개를 export) 다시 결정한다.

- [ ] **Step 5: 기록을 남긴다**

`results/2026-09-03-generated-primitive-first-run.md` 에 위 넷과 생성된 코드 전문을 적는다.
메모리 `minted-body-args-never-reach-julia.md` 의 "🔴 라이브로는 아직 안 쟀다" 를 갱신한다.
