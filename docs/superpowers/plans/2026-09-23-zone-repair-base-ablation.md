# 존 복구 base ablation 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `REPAIR_ABLATION=none|translate|all` 손잡이 하나로, 사람이 쓴 존 복구 해법·실행부를 LLM 과 자동 복구 경로 모두에서 빼고, 같은 코드 버전의 none·A1·A2 360판을 잰다.

**Architecture:** 차단 목록·상태·가드는 Julia 파일 하나(`src/respec/repair_ablation.jl`)에 둔다. 네 층이 그것을 읽는다: 광고 생성기(팔별 산출물), 등록 게이트(AST 스캔), 실행 가드(차단 함수 첫 줄), 자동 복구 사다리(건너뜀). 서비스는 팔별 산출물을 고르고 핸드셰이크로 Julia 와 레벨을 맞춘다. 센서는 새 `zone_facts` 로 분리해 모든 팔에 광고한다.

**Tech Stack:** Julia 1.x(`julia +lts`), ConstructionBots 모듈, Python 3(DSPy 서비스, pytest), bash 격자 드라이버(`tools/monitor/grid/`).

**Spec:** `docs/superpowers/specs/2026-09-23-zone-repair-base-ablation-design.md` (c2b629c2). 실행자는 계획서와 명세서를 함께 읽는다.

## Global Constraints

- 레벨 문자열은 정확히 `none` · `translate` · `all` 셋. 그 밖의 값(빈 문자열·대문자 포함)은 **두 언어 모두 크게 실패**한다. 조용히 `none` 으로 떨어지지 않는다.
- `REPAIR_ABLATION=none`(기본)에서 기존 동작은 바이트 동일하다. 단, 명세 §5 의 공통 변경(원칙 문장·관측 행)과 새 센서 `zone_facts` 광고는 **세 팔 모두**에 들어간다.
- 차단 목록(명세 §3):
  - `translate`: `translate_whole_build!`, `_apply_uniform_translation!`, `_find_min_translation`, `_find_clear_translation`, `_minimum_clear_translation`, `zone_relocatable`, `core_zone_for_severity`, `zone_diagnosis`, `zone_diagnoses`
  - `all`: `translate` 목록 + `find_clear_staging_center`, `restage_assembly!`, `restage_all_blocked!`
- 센서는 어느 팔에서도 차단하지 않는다: `zone_blockage`, `active_restriction_zones`, `zone_blocked_assemblies`, `root_deposit_goals`, `root_goal_coverage`, `zone_clears_root_goals`, `zone_team_coverage`, `zone_facts`, 좌표 접근자.
- 새 Julia 심볼 중 **`zone_facts` 만 export** 한다. 가드 기계장치(`REPAIR_ABLATION`, `ablation_exempt` …)를 export 하면 광고에 실려 모델이 보게 된다 — export 금지.
- 실행 가드는 **존 주입이 끝난 뒤** 무장한다. 주입이 `zone_relocatable`·`zone_diagnosis` 로 존을 고르므로, 먼저 무장하면 팔마다 존이 달라진다.
- 면제는 LLM 에 안 보이는 네 자리뿐이다: `:policy_payload`(policy.jl 관측 페이로드), `:reference_label`(policy.jl 참조 라벨), `:monitor_record`(policy.jl 사후 모니터 기록), `:dp_lane`(dp_lane.jl). 면제 호출도 센다.
- 판 끝에 `[ablation] …` 한 줄을 **항상** 찍는다(0 이어도).
- 유료 런: `gpt-5.6-sol`, `DSPY_MODEL_TYPE=responses DSPY_TEMPERATURE=none DSPY_MAX_TOKENS=16000 DSPY_CACHE=0 TOOL_SYNTHESIS=1 SYNTH_MULTI_AGENT=1`, W=8/모델, cost watchdog 상한 $150.
- 오라클 body 는 `tools/fixtures/` 에만 둔다. 프롬프트·예시·광고에 넣지 않는다.
- 이 레포 규칙:
  - pytest 는 **레포 루트에서** `.venv/bin/python -m pytest …` 로 돌린다. `llm_service/` 안에서 돌리면 유료 원장이 오염된다.
  - 커밋은 **자기 파일만 경로 지정**으로 한다(`git commit -- <paths>`). 다른 세션이 같은 작업트리를 쓴다.
  - `grep` 은 gitignore 를 따르는 래퍼다. 검색은 `/usr/bin/grep` 으로 한다.
  - 커밋 메시지 끝에 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` 를 붙인다.

## Review Focus

1. **Julia 와 서비스의 레벨 불일치**(서비스는 `all`, Julia 는 `none`): 첫 결정 **전에** 판이 죽어야 한다. 조용히 섞인 판이 나오면 안 된다. → Task 6(서비스 핸드셰이크 시험), Task 8(기동 단언 시험).
2. **오타·빈 레벨**(`ALL`, `a2`, `""`): 두 언어 모두 기동 시 에러. → Task 1, Task 6 시험.
3. **차단 함수를 우회해 부르는 body**(한정 호출 `CB.translate_whole_build!`, `getfield(CB, :x)`, `Symbol("x")`, 별칭 `f = translate_whole_build!; f(env)`, 키워드 기본값): 등록에서 거절돼야 한다. → Task 4 시험.
4. **면제 경로로 해법 정보가 LLM 에 새는 것**(`zone_restage_feasible`·`zone_relocatable`·`zone_relocate_norm` 페이로드): 렌더된 관측이 그 값과 무관해야 한다. → Task 7 시험.
5. **가드가 주입 전에 무장돼 존 배치가 바뀌는 것**: 무장 호출이 소스상 주입 뒤에 있어야 하고, 파일럿에서 세 팔의 `zone_place` 가 같아야 한다. → Task 8 소스 순서 시험, Task 12 대조.

---

## 파일 구조

| 파일 | 책임 | 신규/수정 |
|---|---|---|
| `src/respec/repair_ablation.jl` | 레벨·차단 목록·가드 상태·면제·카운터·AST 스캔·산출물 걸러내기 | 신규 |
| `src/respec/zone_facts.jl` | 센서 전용 `zone_facts` | 신규 |
| `src/respec/respec.jl` | 위 두 파일 include | 수정 |
| `src/ConstructionBots.jl` | `zone_facts` export | 수정 |
| `src/respec/restage_zone.jl`, `src/respec/zone_diagnosis.jl` | 차단 함수 첫 줄 가드 | 수정 |
| `src/respec/minted_registration.jl` | 등록 게이트 층, near-miss 제외, 산출물 경로 | 수정 |
| `src/respec/replace_robot.jl` | 사다리 존 분기 건너뜀·계수 | 수정 |
| `tools/gen_world_interface.jl` | 팔별 산출물 | 수정 |
| `tools/monitor/policy.jl` | 면제 3곳, 설정 지문 키, 서비스 레벨 단언 | 수정 |
| `tools/monitor/dp_lane.jl` | 면제 1곳 | 수정 |
| `tools/monitor/render_demo.jl` | 레벨 설정·run_ctx·무장·`[ablation]` 줄 | 수정 |
| `src/respec/llm_service/repair_ablation.py` | 레벨 검증·산출물 이름·핸드셰이크 | 신규 |
| `src/respec/llm_service/world_interface.py` | 레벨별 산출물 | 수정 |
| `src/respec/llm_service/dspy_service.py` | `/health` 키, 핸드셰이크, 관측 행 | 수정 |
| `src/respec/llm_service/synthesize.py` | 원칙 문장 | 수정 |
| `tools/monitor/grid/campaign.py` | `SERVICE_KEYS` | 수정 |
| `tools/monitor/build_sweep_dataset.py` | `[ablation]` 줄 파싱 | 수정 |
| `tools/fixtures/oracle_zone_clear_nobase.json` | A2 어휘 오라클 | 신규 |
| `results/2026-09-2x-repair-ablation/` | 오라클·파일럿·본 측정 산출물, `compare3.py` | 신규 |

---

### Task 0: G0 — 정리 커밋 확인과 앵커 재검증 (코드 수정 없음)

**Files:** 없음(읽기만).

- [ ] **Step 1: 다른 세션의 정리가 커밋됐는지 확인한다**

Run: `cd /home/chahj578/Construction_OODlayer && git status --short -- src tools test | /usr/bin/grep -v '^??' | wc -l && git log --since="2026-09-23 14:00" --format='%h %ad %s' --date=format:%H:%M`
Expected: 첫 숫자가 `0`이다(미커밋 수정 없음). 0 이 아니면 **멈추고 사용자에게 보고**한다. 남의 편집 위에서 구현하지 않는다.

- [ ] **Step 2: 이 계획이 기대는 앵커가 그대로인지 확인한다**

Run:
```bash
cd /home/chahj578/Construction_OODlayer
ls src/decision/core/world_interface.json
/usr/bin/grep -n '^function translate_whole_build!\|^function _apply_uniform_translation!\|^function _find_min_translation\|^function _find_clear_translation\|^function _minimum_clear_translation\|^function zone_relocatable\|^function core_zone_for_severity\|^function find_clear_staging_center\|^function restage_assembly!\|^function restage_all_blocked!' src/respec/restage_zone.jl
/usr/bin/grep -n '^function zone_diagnosis\|^zone_diagnoses' src/respec/zone_diagnosis.jl
/usr/bin/grep -n 'res = restage_all_blocked!(env)' src/respec/replace_robot.jl
/usr/bin/grep -n 'CB.zone_diagnosis(env, truth.zone' tools/monitor/policy.jl tools/monitor/dp_lane.jl
/usr/bin/grep -n 'const _CONFIG_ENV_PREFIXES\|^const CONFIG_ENV_RESULT\|^const CONFIG_ENV_PINNED_DEFAULTS' tools/monitor/policy.jl
/usr/bin/grep -n 'Moving staging areas or translating the whole build' src/respec/llm_service/synthesize.py
/usr/bin/grep -n '"zone_restage_feasible", "  of which movable"' src/respec/llm_service/dspy_service.py
/usr/bin/grep -n '^SERVICE_KEYS' tools/monitor/grid/campaign.py
/usr/bin/grep -n 'println("\[score\] complete="' tools/monitor/render_demo.jl
```
Expected: 줄마다 한 건 이상 나온다. 결과는 다음과 같아야 한다. restage_zone.jl 함수 10개, zone_diagnosis.jl 2개, replace_robot 1곳, policy/dp_lane 의 zone_diagnosis 호출 4곳(policy 3 + dp_lane 1), 설정 상수 3개, 문장·행·키·score 각 1곳. 빠진 앵커가 있으면 그 Task 의 삽입 지점을 새 위치로 고쳐 적은 뒤 진행한다.

- [ ] **Step 3: 빠른 시험 기준선을 기록한다**

Run: `cd /home/chahj578/Construction_OODlayer && .venv/bin/python -m pytest src/respec/llm_service -q -x 2>&1 | tail -3`
Expected: 통과 수를 적어 둔다. 실패가 있으면 이 계획 이전의 빨강이므로 목록을 기록하고 진행한다. 구분을 위해서다.

---

### Task 1: Julia ablation 핵심 — 레벨·목록·가드·면제·카운터

**Files:**
- Create: `src/respec/repair_ablation.jl`
- Modify: `src/respec/respec.jl`(`include("restage_zone.jl")` 바로 위에 한 줄)
- Test: `test/repair_ablation_core.jl`

**Interfaces:**
- Produces(모두 비공개, `CB.` 로 접근):
  - `REPAIR_ABLATION_LEVELS::NTuple{3,Symbol}`
  - `ablated_names(level::Symbol)::Vector{Symbol}` — 알 수 없는 레벨이면 에러
  - `parse_repair_ablation(s::AbstractString)::Symbol` — 에러 규칙은 Global Constraints
  - `repair_ablation_from_env(env = ENV)::Symbol` — 키가 없으면 `:none`
  - `REPAIR_ABLATION::Ref{Symbol}`
  - `set_repair_ablation!(level::Symbol)`
  - `arm_repair_ablation!()` — 카운터를 비우고 무장
  - `disarm_repair_ablation!()`
  - `repair_ablation_armed()::Bool`
  - `_ablation_gate(name::Symbol)` — 차단 함수 첫 줄
  - `ablation_exempt(f, site::Symbol)` — do-블록용
  - `_ablation_bump!(key::String)`
  - `ablation_counts()::Dict{String,Int}`
  - `ablation_summary_line()::String`
  - `ablation_blocks_zone_ladder()::Bool`
  - `AblatedPrimitiveError(name::Symbol, level::Symbol) <: Exception`
  - `ablated_symbols_in(ex, denied::Vector{Symbol})::Vector{Symbol}`
  - `ablate_interface_blob(blob::AbstractDict, level::Symbol)::Dict{String,Any}` — Task 5 가 쓴다

- [ ] **Step 1: 실패하는 시험을 쓴다**

`test/repair_ablation_core.jl`:
```julia
# test/repair_ablation_core.jl — 존 복구 base ablation 핵심(순수, env 없음)
#   julia +lts --project=. test/repair_ablation_core.jl
using ConstructionBots, Test
const CB = ConstructionBots

@testset "레벨 파싱은 셋만 받고 나머지는 크게 죽는다" begin
    @test CB.parse_repair_ablation("none") === :none
    @test CB.parse_repair_ablation("translate") === :translate
    @test CB.parse_repair_ablation("all") === :all
    for bad in ("", "ALL", "a2", "None", " all")
        @test_throws ErrorException CB.parse_repair_ablation(bad)
    end
    @test CB.repair_ablation_from_env(Dict{String,String}()) === :none
    @test CB.repair_ablation_from_env(Dict("REPAIR_ABLATION" => "all")) === :all
    @test_throws ErrorException CB.repair_ablation_from_env(Dict("REPAIR_ABLATION" => ""))
end

@testset "차단 목록은 명세 §3 과 같고 translate ⊂ all 이다" begin
    @test isempty(CB.ablated_names(:none))
    @test Set(CB.ablated_names(:translate)) == Set([:translate_whole_build!, :_apply_uniform_translation!,
        :_find_min_translation, :_find_clear_translation, :_minimum_clear_translation,
        :zone_relocatable, :core_zone_for_severity, :zone_diagnosis, :zone_diagnoses])
    @test Set(CB.ablated_names(:all)) == union(Set(CB.ablated_names(:translate)),
        Set([:find_clear_staging_center, :restage_assembly!, :restage_all_blocked!]))
    # 센서는 어느 목록에도 없다
    for s in (:zone_blockage, :active_restriction_zones, :zone_blocked_assemblies, :root_deposit_goals,
              :root_goal_coverage, :zone_clears_root_goals, :zone_team_coverage, :zone_facts)
        @test !(s in CB.ablated_names(:all))
    end
    @test_throws ErrorException CB.ablated_names(:bogus)
    # 목록의 이름은 전부 모듈에 실제로 있다(오타 방지)
    for s in CB.ablated_names(:all)
        @test isdefined(CB, s)
    end
end

@testset "가드: 무장·레벨·면제" begin
    try
        CB.set_repair_ablation!(:all); CB.disarm_repair_ablation!()
        @test CB._ablation_gate(:translate_whole_build!) === nothing          # 무장 전 = 무동작
        CB.arm_repair_ablation!()
        @test_throws CB.AblatedPrimitiveError CB._ablation_gate(:translate_whole_build!)
        @test CB._ablation_gate(:zone_blockage) === nothing                  # 목록 밖
        @test CB.ablation_counts()["denied:translate_whole_build!"] == 1
        r = CB.ablation_exempt(:monitor_record) do
            CB._ablation_gate(:zone_diagnosis); :ran
        end
        @test r === :ran
        @test CB.ablation_counts()["exempt:monitor_record"] == 1
        @test_throws CB.AblatedPrimitiveError CB._ablation_gate(:zone_diagnosis)  # 면제 밖으로 나오면 다시 막힌다
        @test CB.ablation_blocks_zone_ladder()
        CB.set_repair_ablation!(:translate)
        @test CB._ablation_gate(:restage_all_blocked!) === nothing           # A1 에는 restage 가 남는다
        CB.set_repair_ablation!(:none); CB.arm_repair_ablation!()
        @test CB._ablation_gate(:translate_whole_build!) === nothing
        @test !CB.ablation_blocks_zone_ladder()
        line = CB.ablation_summary_line()
        @test occursin("level=none armed=true denied=0 exempt=0 ladder_zone_skipped=0 ladder_zone_fired=0", line)
    finally
        CB.set_repair_ablation!(:none); CB.disarm_repair_ablation!()
    end
end

@testset "오류 문구는 대안을 적지 않는다" begin
    msg = sprint(showerror, CB.AblatedPrimitiveError(:translate_whole_build!, :all))
    @test occursin("translate_whole_build!", msg)
    @test !occursin("restage", msg) && !occursin("instead", msg)
end
```

- [ ] **Step 2: 시험이 실패하는지 확인한다**

Run: `cd /home/chahj578/Construction_OODlayer && julia +lts --project=. test/repair_ablation_core.jl`
Expected: FAIL — `UndefVarError: parse_repair_ablation not defined` 류.

- [ ] **Step 3: 최소 구현을 쓴다**

`src/respec/repair_ablation.jl`:
```julia
# =============================================================================
# repair_ablation.jl — 존 복구 base ablation (2026-09-23, 명세 docs/superpowers/specs/
#   2026-09-23-zone-repair-base-ablation-design.md). 사람이 쓴 존 복구 해법·실행부를 LLM 과 자동 복구
#   경로 모두에서 뺀다. 네 층(광고·등록·실행 가드·사다리)이 이 파일 하나를 읽는다.
# 🔴 export 하지 않는다 — export 하면 세계 인터페이스에 실려 모델이 이 기계장치를 본다.
# =============================================================================

const REPAIR_ABLATION_LEVELS = (:none, :translate, :all)

const _ABLATE_TRANSLATE = Symbol[
    :translate_whole_build!, :_apply_uniform_translation!, :_find_min_translation,
    :_find_clear_translation, :_minimum_clear_translation, :zone_relocatable,
    :core_zone_for_severity, :zone_diagnosis, :zone_diagnoses]
const _ABLATE_ALL = Symbol[_ABLATE_TRANSLATE;
    :find_clear_staging_center, :restage_assembly!, :restage_all_blocked!]

"레벨의 차단 목록. 모르는 레벨은 에러다(조용히 `none` 으로 안 떨어진다)."
function ablated_names(level::Symbol)
    level === :none      && return Symbol[]
    level === :translate && return _ABLATE_TRANSLATE
    level === :all       && return _ABLATE_ALL
    error("repair_ablation: unknown level $(repr(level)); allowed: none, translate, all")
end

function parse_repair_ablation(s::AbstractString)
    s in ("none", "translate", "all") ||
        error("REPAIR_ABLATION=$(repr(s)) — allowed exactly: none, translate, all")
    return Symbol(s)
end

repair_ablation_from_env(env = ENV) =
    parse_repair_ablation(haskey(env, "REPAIR_ABLATION") ? env["REPAIR_ABLATION"] : "none")

const REPAIR_ABLATION = Ref{Symbol}(:none)
const _ABLATION_ARMED = Ref(false)
const _ABLATION_EXEMPT_DEPTH = Ref(0)
const _ABLATION_COUNTS = Ref(Dict{String,Int}())

set_repair_ablation!(level::Symbol) = (ablated_names(level); REPAIR_ABLATION[] = level; nothing)
arm_repair_ablation!() = (_ABLATION_COUNTS[] = Dict{String,Int}(); _ABLATION_ARMED[] = true; nothing)
disarm_repair_ablation!() = (_ABLATION_ARMED[] = false; nothing)
repair_ablation_armed() = _ABLATION_ARMED[]
_ablation_bump!(key::String) = (d = _ABLATION_COUNTS[]; d[key] = get(d, key, 0) + 1; nothing)
ablation_counts() = copy(_ABLATION_COUNTS[])
ablation_blocks_zone_ladder() = _ABLATION_ARMED[] && REPAIR_ABLATION[] !== :none

struct AblatedPrimitiveError <: Exception
    name::Symbol
    level::Symbol
end
Base.showerror(io::IO, e::AblatedPrimitiveError) =
    print(io, "AblatedPrimitiveError: `", e.name, "` is not available in this world (repair_ablation=",
          e.level, ")")

"차단 함수의 **첫 줄**. 무장 전·목록 밖·면제 안이면 무동작이다."
function _ablation_gate(name::Symbol)
    _ABLATION_ARMED[] || return nothing
    name in ablated_names(REPAIR_ABLATION[]) || return nothing
    _ABLATION_EXEMPT_DEPTH[] > 0 && return nothing
    _ablation_bump!("denied:$(name)")
    _ablation_bump!("denied_by:$(_ablation_caller())")
    throw(AblatedPrimitiveError(name, REPAIR_ABLATION[]))
end

"가드 바깥의 첫 프레임 — 누가 차단 함수를 불렀는가(주조 body 는 file 이 `none`/`string` 으로 나온다)."
function _ablation_caller()
    for fr in stacktrace()
        f = basename(String(fr.file))
        f in ("repair_ablation.jl", "restage_zone.jl", "zone_diagnosis.jl") && continue
        return string(fr.func, "@", f, ":", fr.line)
    end
    return "unknown"
end

"LLM 에 안 보이는 경로의 명시적 면제. 무장돼 있으면 레벨과 무관하게 센다."
function ablation_exempt(f, site::Symbol)
    _ABLATION_ARMED[] && _ablation_bump!("exempt:$(site)")
    _ABLATION_EXEMPT_DEPTH[] += 1
    try
        return f()
    finally
        _ABLATION_EXEMPT_DEPTH[] -= 1
    end
end

"판 끝의 한 줄. 0 이어도 항상 같은 키를 찍는다(조용한 0 방지)."
function ablation_summary_line()
    d = _ABLATION_COUNTS[]
    nd = sum((v for (k, v) in d if startswith(k, "denied:")); init = 0)
    ne = sum((v for (k, v) in d if startswith(k, "exempt:")); init = 0)
    detail = join(("$(k)=$(v)" for (k, v) in sort!(collect(d); by = first)), ",")
    return string("level=", REPAIR_ABLATION[], " armed=", _ABLATION_ARMED[], " denied=", nd,
                  " exempt=", ne, " ladder_zone_skipped=", get(d, "ladder_zone_skipped", 0),
                  " ladder_zone_fired=", get(d, "ladder_zone_fired", 0), " detail=", detail)
end
```

`src/respec/respec.jl` — `include("restage_zone.jl")` 줄 바로 위에:
```julia
include("repair_ablation.jl") # 존 복구 base ablation: 레벨·차단 목록·실행 가드(명세 2026-09-23). restage_zone.jl 이 첫 줄에서 부른다
```

- [ ] **Step 4: 시험이 통과하는지 확인한다**

Run: `julia +lts --project=. test/repair_ablation_core.jl`
Expected: PASS(testset 4개 전부). 단 `ablated_symbols_in`·`ablate_interface_blob` 은 Task 4·5 에서 더한다.

- [ ] **Step 5: 커밋**

```bash
git add src/respec/repair_ablation.jl test/repair_ablation_core.jl src/respec/respec.jl
git commit -m "repair_ablation: 레벨·차단 목록·실행 가드·면제·카운터 (명세 §3·§6)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- src/respec/repair_ablation.jl test/repair_ablation_core.jl src/respec/respec.jl
```

---

### Task 2: 실행 가드 — 차단 함수 11개의 첫 줄

**Files:**
- Modify: `src/respec/restage_zone.jl` — 10개 함수. `translate_whole_build!`, `_apply_uniform_translation!`, `_find_min_translation`, `_find_clear_translation`, `_minimum_clear_translation`, `zone_relocatable`, `core_zone_for_severity`, `find_clear_staging_center`, `restage_assembly!`, `restage_all_blocked!`
- Modify: `src/respec/zone_diagnosis.jl` — `zone_diagnosis` 1개. `zone_diagnoses` 는 `zone_diagnosis` 를 부르므로 따로 넣지 않는다.
- Test: `test/repair_ablation_core.jl`(testset 추가)

**Interfaces:**
- Consumes: `_ablation_gate(name::Symbol)` (Task 1)

- [ ] **Step 1: 실패하는 시험을 더한다**

`test/repair_ablation_core.jl` 끝에:
```julia
@testset "차단 함수 11개는 본문 첫 문장이 자기 이름의 가드다(소스 고정)" begin
    gated = Dict(
        "restage_zone.jl" => [:translate_whole_build!, :_apply_uniform_translation!, :_find_min_translation,
            :_find_clear_translation, :_minimum_clear_translation, :zone_relocatable, :core_zone_for_severity,
            :find_clear_staging_center, :restage_assembly!, :restage_all_blocked!],
        "zone_diagnosis.jl" => [:zone_diagnosis])
    for (file, fns) in gated
        top = Meta.parseall(read(joinpath(pkgdir(CB), "src", "respec", file), String))
        found = Dict{Symbol,Bool}()
        for a in top.args
            a isa Expr && a.head === :function || continue
            sig = a.args[1]
            sig isa Expr && sig.head === :where && (sig = sig.args[1])
            sig isa Expr && sig.head === :(::) && (sig = sig.args[1])   # 반환 타입 표기 `f(...)::T`
            sig isa Expr && sig.head === :call || continue
            nm = sig.args[1]
            nm in fns || continue
            first_stmt = first(x for x in a.args[2].args if !(x isa LineNumberNode))
            found[nm] = first_stmt == :(_ablation_gate($(QuoteNode(nm))))
        end
        for fn in fns
            @test get(found, fn, false)
        end
    end
end

@testset "무장된 :all 에서 차단 함수는 인자를 보기 전에 던진다" begin
    saved = copy(CB.RESTRICTION_ZONES[])
    try
        CB.set_repair_ablation!(:all); CB.arm_repair_ablation!()
        @test_throws CB.AblatedPrimitiveError CB.translate_whole_build!(nothing)
        @test_throws CB.AblatedPrimitiveError CB.restage_all_blocked!(nothing)
        @test_throws CB.AblatedPrimitiveError CB.zone_diagnosis(nothing, :z)
        @test_throws CB.AblatedPrimitiveError CB._find_min_translation(nothing)
        # zone_diagnoses 는 존마다 zone_diagnosis 를 부른다 — 존이 하나도 없으면 빈 목록이라 안 던진다.
        # 그래서 존 하나를 심고 잰다(도메인이 퇴화하면 항진명제다).
        CB.add_restriction_zone!(:abl_t, [1.0e4, 1.0e4], 1.0)
        @test_throws CB.AblatedPrimitiveError CB.zone_diagnoses(nothing)
        CB.disarm_repair_ablation!()
        # 무장 해제면 가드가 무동작 → 원래 함수가 nothing 을 받아 **다른** 예외를 낸다
        err = try CB.translate_whole_build!(nothing); nothing catch e; e end
        @test !(err isa CB.AblatedPrimitiveError)
    finally
        CB.set_repair_ablation!(:none); CB.disarm_repair_ablation!()
        CB.clear_restriction_zones!()
        for (k, z) in saved
            CB.add_restriction_zone!(k, Vector{Float64}(CB.get_center(z)[1:2]), Float64(CB.get_radius(z)))
        end
    end
end
```

- [ ] **Step 2: 실패 확인**

Run: `julia +lts --project=. test/repair_ablation_core.jl`
Expected: 소스 고정 testset 에서 11건 FAIL, 던짐 testset 에서 FAIL.

- [ ] **Step 3: 각 함수 본문 첫 줄에 가드를 넣는다**

11개 함수마다 `function NAME(...)` 시그니처 다음, 기존 첫 문장 **앞**에 한 줄을 넣는다. 예(`translate_whole_build!`):
```julia
function translate_whole_build!(env;
        zone_keys = collect(keys(RESTRICTION_ZONES[])),
        resume::Bool = true, verbose::Bool = true)
    _ablation_gate(:translate_whole_build!)   # 존 복구 base ablation(명세 §6 층 3) — 무장·차단 레벨에서만 던진다
    isempty(env.staging_circles) && return (status = :no_staging,)        # 적치원 없으면 옮길 게 없음
```
나머지 10개도 같은 모양으로 하되 심볼만 자기 이름으로 바꾼다: `:_apply_uniform_translation!`, `:_find_min_translation`, `:_find_clear_translation`, `:_minimum_clear_translation`, `:zone_relocatable`, `:core_zone_for_severity`, `:find_clear_staging_center`, `:restage_assembly!`, `:restage_all_blocked!`, `:zone_diagnosis`.

- [ ] **Step 4: 통과 확인**

Run: `julia +lts --project=. test/repair_ablation_core.jl`
Expected: PASS 전부.

- [ ] **Step 5: 기존 동작 무변경 확인**

Run: `julia +lts --project=. test/translate_is_rigid.jl 2>&1 | tail -5`
Expected: PASS. 가드는 기본 비무장이라 무동작이다. 수동 실행 시험이며 수 분 걸린다.

- [ ] **Step 6: 커밋**

```bash
git commit -m "restage_zone·zone_diagnosis: 차단 함수 11개 첫 줄 실행 가드 (명세 §6 층 3)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- src/respec/restage_zone.jl src/respec/zone_diagnosis.jl test/repair_ablation_core.jl
```

---

### Task 3: 센서 `zone_facts` — 모든 팔에 광고

**Files:**
- Create: `src/respec/zone_facts.jl`
- Modify: `src/respec/respec.jl`(`include("zone_corridor.jl")` 바로 아래), `src/ConstructionBots.jl` export 블록(`zone_blockage, goal_engulfed, free_space_status` 줄에 `, zone_facts` 추가)
- Test: `test/zone_facts_is_sensor_only.jl`(수동 실행, env 빌드 포함)

**Interfaces:**
- Produces: `zone_facts(env, zone::Symbol; margin::Float64 = default_robot_radius(), check_teams::Bool = true, check_blockage::Bool = true, check_paths::Bool = get(ENV, "ZONE_CHECK_PATHS", "0") == "1") -> NamedTuple`. 필드는 `zone_diagnosis` 의 것에서 `feasible, n_restage_feasible, relocate_delta, relocate_norm, relocate_feasible, verdict` 를 뺀 전부이고, 이름과 뜻이 같다.

- [ ] **Step 1: 실패하는 시험을 쓴다**

`test/zone_facts_is_sensor_only.jl`:
```julia
# test/zone_facts_is_sensor_only.jl — zone_facts 는 zone_diagnosis 의 관측 필드와 같고 해법기를 안 부른다
#   julia +lts --project=. test/zone_facts_is_sensor_only.jl   (수동 — env 빌드가 수 분)
using ConstructionBots, Test
import Random
const CB = ConstructionBots

pp  = CB.get_project_params("tractor.mpd")
env = CB.run_lego_demo(; ldraw_file = "tractor.mpd", project_name = "zone_facts",
                         num_robots = pp[:num_robots], model_scale = pp[:model_scale],
                         assignment_mode = :greedy, n_spare_per_pool = 2,
                         open_animation_at_end = false, save_animation = false,
                         write_results = false, return_env_before_sim = true,
                         rng = Random.MersenneTwister(1))

saved = copy(CB.RESTRICTION_ZONES[])
try
    CB.clear_restriction_zones!()
    ks = sort!(collect(keys(env.staging_circles)); by = string)
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), ks)
    aid = first(k for k in ks if k != root)
    b = env.staging_circles[aid]
    CB.add_restriction_zone!(:zf, Vector{Float64}(CB.get_center(b)[1:2]), 0.5 * Float64(CB.get_radius(b)))

    @testset "관측 필드가 zone_diagnosis 와 같다" begin
        d = CB.zone_diagnosis(env, :zf)
        f = CB.zone_facts(env, :zf)
        solver = (:feasible, :n_restage_feasible, :relocate_delta, :relocate_norm, :relocate_feasible, :verdict)
        @test Set(keys(f)) == setdiff(Set(keys(d)), Set(solver))
        for k in keys(f)
            @test isequal(getfield(f, k), getfield(d, k))
        end
        @test f.n_blocked >= 1                     # 도메인: 존이 실제로 조립체 하나를 덮는다
    end

    @testset "무장된 :all 에서도 던지지 않는다 = 해법기 호출 0" begin
        try
            CB.set_repair_ablation!(:all); CB.arm_repair_ablation!()
            @test CB.zone_facts(env, :zf).exists
            @test !any(startswith(k, "denied:") for k in keys(CB.ablation_counts()))
        finally
            CB.set_repair_ablation!(:none); CB.disarm_repair_ablation!()
        end
    end

    @testset "없는 존은 exists=false 이고 삼상 필드는 nothing" begin
        f = CB.zone_facts(env, :no_such)
        @test f.exists === false
        @test f.project_blocked === nothing
    end
finally
    CB.clear_restriction_zones!()
    for (k, z) in saved
        CB.add_restriction_zone!(k, Vector{Float64}(CB.get_center(z)[1:2]), Float64(CB.get_radius(z)))
    end
end
```

- [ ] **Step 2: 실패 확인**

Run: `julia +lts --project=. test/zone_facts_is_sensor_only.jl`
Expected: FAIL — `UndefVarError: zone_facts`.

- [ ] **Step 3: 구현한다**

`src/respec/zone_facts.jl`. `zone_diagnosis` 의 0·1·2·3·3b·3c 절과 같은 계산을 **해법기 없이** 한다. 복사하는 이유는 `zone_diagnosis` 를 리팩터링하면 라벨·게이트가 기대는 바이트가 흔들릴 위험이 있어서다. 대신 필드 동등성을 시험으로 고정한다.
```julia
# =============================================================================
# zone_facts.jl — 존의 **관측 사실**만(2026-09-23, 존 복구 base ablation 명세 §4).
#   zone_diagnosis 의 센서 절(0·1·2·3·3b·3c)과 같은 계산이고, 해법 산출(feasible·relocate_*·verdict)은
#   없다. 해법기(find_clear_staging_center·_find_min_translation)를 **부르지 않는다** — 그래서 모든 ablation
#   팔에서 광고할 수 있다. 동등성은 test/zone_facts_is_sensor_only.jl 이 zone_diagnosis 와 필드째 고정한다.
# =============================================================================

"""
    zone_facts(env, zone; margin, check_teams=true, check_blockage=true, check_paths) -> NamedTuple

What an active no-go zone covers and blocks, as measured facts only (no repair suggestion).

| field | meaning |
|---|---|
| `center`, `radius` | the zone's geometry |
| `blocked` / `n_blocked` | assemblies that are not the root, have not started, and whose staging area the zone overlaps |
| `root_covered` / `root_total` / `root_frac` | root deposit goals inside the zone |
| `n_work_overlap` | unfinished work discs overlapping the zone |
| `teams` / `n_teams_forming` / `n_teams_covered` | forming transport teams and how many must gather inside the zone |
| `n_nav_goals`, `n_nav_engulfed`, `n_nav_disconnected`, `n_nav_blocked`, `n_nav_downstream`, `n_agent_trapped` | navigation blockage, as in `zone_blockage` (`-1` if not computed) |
| `n_completion_blocked` / `n_completion_open` / `project_blocked` | whether completion is blocked (`nothing` if not computed) |
"""
function zone_facts(env, zone::Symbol;
        margin::Float64 = default_robot_radius(),
        check_teams::Bool = true,
        check_blockage::Bool = true,
        check_paths::Bool = get(ENV, "ZONE_CHECK_PATHS", "0") == "1")
    if !haskey(RESTRICTION_ZONES[], zone)
        return (zone = zone, exists = false, center = nothing, radius = 0.0,
                blocked = AbstractID[], n_blocked = 0,
                root_covered = 0, root_total = 0, root_frac = 0.0,
                n_work_overlap = 0,
                teams = NamedTuple[], n_teams_forming = 0, n_teams_covered = 0,
                n_nav_goals = 0, n_nav_blocked = 0, n_nav_engulfed = 0,
                n_nav_disconnected = 0, n_agent_trapped = 0, n_nav_downstream = 0,
                n_completion_blocked = nothing, n_completion_open = nothing,
                project_blocked = nothing)
    end
    ball = RESTRICTION_ZONES[][zone]
    zc = Vector{Float64}(get_center(ball)[1:2])
    zr = Float64(get_radius(ball))
    blocked = try
        zone_blocked_assemblies(env; zone_keys = [zone], margin = margin)
    catch e
        @warn "[ZONE-FACTS] zone_blocked_assemblies failed for :$(zone)" exception = e
        AbstractID[]
    end
    rc = try
        root_goal_coverage(zc, zr, env)
    catch e
        @warn "[ZONE-FACTS] root_goal_coverage failed for :$(zone)" exception = e
        (covered = 0, total = 0, frac = 0.0)
    end
    n_overlap = try
        _count_future_work_overlaps(env; zone_keys = [zone])
    catch e
        @warn "[ZONE-FACTS] _count_future_work_overlaps failed for :$(zone)" exception = e
        0
    end
    teams = check_teams ? zone_team_coverage(env, zc, zr; margin = margin) : NamedTuple[]
    blk = check_blockage ?
        (try zone_blockage(env; zone_keys = [zone], check_paths = check_paths)
         catch e
            @warn "[ZONE-FACTS] zone_blockage failed for :$(zone)" exception = e
            nothing
         end) : nothing
    return (zone = zone, exists = true, center = zc, radius = zr,
            blocked = blocked, n_blocked = length(blocked),
            root_covered = rc.covered, root_total = rc.total, root_frac = rc.frac,
            n_work_overlap = n_overlap,
            teams = teams, n_teams_forming = length(teams),
            n_teams_covered = count(t -> t.covered, teams),
            n_nav_goals = blk === nothing ? -1 : blk.n_nav_goals,
            n_nav_blocked = blk === nothing ? -1 : blk.n_blocked,
            n_nav_engulfed = blk === nothing ? -1 : blk.n_engulfed,
            n_nav_disconnected = blk === nothing ? -1 : blk.n_disconnected,
            n_agent_trapped = blk === nothing ? -1 : blk.n_agent_trapped,
            n_nav_downstream = blk === nothing ? -1 : blk.n_downstream,
            n_completion_blocked = blk === nothing ? nothing : blk.n_completion_blocked,
            n_completion_open = blk === nothing ? nothing : blk.n_completion_open,
            project_blocked = blk === nothing ? nothing : blk.project_blocked)
end
```
⚠️ 구현 전에 `sed -n 193,360p src/respec/zone_diagnosis.jl` 로 반환 NamedTuple 의 **필드 순서와 `root_*` 계산**을 다시 대조한다. 동등성 시험이 필드 집합과 값을 고정하므로, 어긋나면 Step 4 가 빨개진다.

- [ ] **Step 4: 통과 확인**

Run: `julia +lts --project=. test/zone_facts_is_sensor_only.jl`
Expected: PASS 3 testset.

- [ ] **Step 5: 커밋**

```bash
git commit -m "zone_facts: 해법 없는 존 센서 — zone_diagnosis 관측 필드와 동등, 모든 팔에 광고 (명세 §4)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- src/respec/zone_facts.jl src/respec/respec.jl src/ConstructionBots.jl test/zone_facts_is_sensor_only.jl
```
(광고 산출물 재생성과 closure 전수 핀은 Task 5 에서 한 번에 한다.)

---

### Task 4: 등록 게이트 — 차단 이름이 나오는 body 를 거절한다

**Files:**
- Modify: `src/respec/repair_ablation.jl`(`ablated_symbols_in` 추가)
- Modify: `src/respec/minted_registration.jl` — `check_impl_conventions` 의 마지막 `return nothing` 바로 앞(D19 블록 뒤), 그리고 `_near_miss_names` 의 후보 루프
- Test: `test/repair_ablation_registration.jl`

**Interfaces:**
- Produces: `ablated_symbols_in(ex, denied::Vector{Symbol})::Vector{Symbol}` — `ex` 안의 Symbol·QuoteNode 값·문자열 리터럴 중 `denied` 에 든 것(등장 순서, 중복 제거).
- 거절 사유 형식: `reject:ablated_primitive:<name> — this function is not available in this world`.

- [ ] **Step 1: 실패하는 시험을 쓴다**

`test/repair_ablation_registration.jl`:
```julia
# test/repair_ablation_registration.jl — 등록 게이트(명세 §6 층 2)
#   julia +lts --project=. test/repair_ablation_registration.jl
using ConstructionBots, Test
const CB = ConstructionBots

const BODIES = Dict(
    :direct    => "function t1!(env)\n    translate_whole_build!(env)\n    return (; status = :ok)\nend",
    :qualified => "function t2!(env)\n    ConstructionBots.translate_whole_build!(env)\n    return (; status = :ok)\nend",
    :getfield  => "function t3!(env)\n    g = getfield(ConstructionBots, :translate_whole_build!)\n    g(env)\n    return (; status = :ok)\nend",
    :string    => "function t4!(env)\n    g = getfield(ConstructionBots, Symbol(\"translate_whole_build!\"))\n    g(env)\n    return (; status = :ok)\nend",
    :alias     => "function t5!(env)\n    f = translate_whole_build!\n    f(env)\n    return (; status = :ok)\nend",
    :kwdefault => "function t6!(env; f = translate_whole_build!)\n    f(env)\n    return (; status = :ok)\nend",
    :restage   => "function t7!(env)\n    restage_all_blocked!(env)\n    return (; status = :ok)\nend",
    :diag      => "function t8!(env)\n    d = zone_diagnoses(env)\n    return (; status = :ok)\nend",
    :setter    => "function t9!(env)\n    for (k, z) in active_restriction_zones()\n        nothing\n    end\n    return (; status = :ok)\nend",
)

"레벨을 세우고 body 하나를 등록 규약에 태운다. name 은 코드의 함수 이름과 같아야 한다."
function check(level::Symbol, key::Symbol)
    CB.set_repair_ablation!(level)
    code = BODIES[key]
    name = String(match(r"function (\w+!)", code)[1])
    return CB.check_impl_conventions(name, code)
end

@testset "ablated_symbols_in 는 여섯 모양을 다 본다" begin
    d = CB.ablated_names(:all)
    for k in (:direct, :qualified, :getfield, :string, :alias, :kwdefault)
        @test CB.ablated_symbols_in(Meta.parse(BODIES[k]), d) == [:translate_whole_build!]
    end
    @test CB.ablated_symbols_in(Meta.parse(BODIES[:setter]), d) == Symbol[]
end

@testset "레벨별 거절" begin
    try
        for lvl in (:translate, :all), k in (:direct, :qualified, :getfield, :string, :alias, :kwdefault)
            @test check(lvl, k) == "reject:ablated_primitive:translate_whole_build! — this function is not available in this world"
        end
        @test startswith(something(check(:translate, :diag), ""), "reject:ablated_primitive:zone_diagnoses")
        @test check(:translate, :restage) === nothing          # A1 에는 restage 가 남는다
        @test startswith(something(check(:all, :restage), ""), "reject:ablated_primitive:restage_all_blocked!")
        @test check(:all, :setter) === nothing
        for k in keys(BODIES)                                  # none 에서는 ablation 사유가 절대 안 나온다
            r = check(:none, k)
            @test r === nothing || !startswith(r, "reject:ablated_primitive")
        end
    finally
        CB.set_repair_ablation!(:none)
    end
end

@testset "가까운 이름 제안에 차단 이름이 안 나온다" begin
    try
        CB.set_repair_ablation!(:all)
        near = CB._near_miss_names(:translate_whole_building!)
        @test !any(n -> Symbol(n) in CB.ablated_names(:all), near)
        CB.set_repair_ablation!(:none)
        @test "translate_whole_build!" in CB._near_miss_names(:translate_whole_building!)   # 대조: none 에서는 나온다
    finally
        CB.set_repair_ablation!(:none)
    end
end
```

- [ ] **Step 2: 실패 확인**

Run: `julia +lts --project=. test/repair_ablation_registration.jl`
Expected: FAIL — `ablated_symbols_in not defined`.

- [ ] **Step 3: 구현한다**

`src/respec/repair_ablation.jl` 끝에:
```julia
"`ex` 안에서 `denied` 에 든 이름 — Symbol, QuoteNode 값(`CB.x`·`getfield(_, :x)`), 문자열 리터럴(`Symbol(\"x\")`)."
function ablated_symbols_in(ex, denied::Vector{Symbol})
    hits = Symbol[]
    _collect_ablated!(hits, ex, denied)
    return unique!(hits)
end
function _collect_ablated!(hits, x, denied)
    if x isa Symbol
        x in denied && push!(hits, x)
    elseif x isa QuoteNode
        _collect_ablated!(hits, x.value, denied)
    elseif x isa AbstractString
        s = Symbol(x); s in denied && push!(hits, s)
    elseif x isa Expr
        for a in x.args; _collect_ablated!(hits, a, denied); end
    end
    return hits
end
```
`src/respec/minted_registration.jl` — `check_impl_conventions` 의 마지막 `return nothing`(D19 블록과 `if body !== nothing … end` 뒤) **바로 앞**에:
```julia
    # 🔴 존 복구 base ablation (2026-09-23, 명세 §6 층 2). 자리는 규약 **전부의 뒤**다 — 기존 사유를
    #    하나도 안 바꾼다(D18·D19 와 같은 근거). `none` 이면 목록이 비어 무동작(바이트 동일).
    #    D15 는 `isdefined` 만 보므로 미광고 내부 함수도 통과시킨다 — 그래서 이름 스캔이 따로 필요하다.
    #    사유는 대안을 적지 않는다: 무엇을 대신 쓰라는 문장이 곧 해법 힌트다.
    let denied = ablated_names(REPAIR_ABLATION[])
        if !isempty(denied)
            hits = ablated_symbols_in(f, denied)
            isempty(hits) ||
                return "reject:ablated_primitive:$(first(hits)) — this function is not available in this world"
        end
    end
```
`_near_miss_names` 의 `for n in names(@__MODULE__)` 루프 첫 줄 다음에:
```julia
        n in ablated_names(REPAIR_ABLATION[]) && continue   # 존 복구 base ablation: 차단 이름을 제안하지 않는다
```
⚠️ `f` 는 `check_impl_conventions` 안에서 파싱된 함수 Expr 의 지역 이름이다(D15 블록의 `f.args[2]`). 이름이 다르면 그 이름으로 바꾼다.

- [ ] **Step 4: 통과 확인 + 기존 등록 시험 무변경 확인**

Run: `julia +lts --project=. test/repair_ablation_registration.jl && julia +lts --project=. test/minted_registration.jl 2>&1 | tail -3`
Expected: 둘 다 PASS. 기존 시험은 레벨 `none` 에서 돌므로 바이트 고정 사유가 그대로다.

- [ ] **Step 5: 커밋**

```bash
git commit -m "등록 게이트: 차단 이름이 나오는 body 를 거절(한정·getfield·문자열·별칭·kw 기본값), near-miss 제외 (명세 §6 층 2)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- src/respec/repair_ablation.jl src/respec/minted_registration.jl test/repair_ablation_registration.jl
```

---

### Task 5: 광고 — 팔별 세계 인터페이스 산출물

**Files:**
- Modify: `src/respec/repair_ablation.jl`(`ablate_interface_blob`)
- Modify: `tools/gen_world_interface.jl` — 마지막 `open(dst, "w") … end` 블록
- Modify: `src/respec/minted_registration.jl` — `_world_interface_path()`. 레벨별 파일을 읽어야 `interface_calls` 기록이 그 팔의 광고와 맞는다.
- Modify: `test/world_interface_current.jl`(재생성 비교에 두 파일 추가), closure 전수 핀(`test/world_interface_closure.jl` 등 `zone_facts` 추가로 1 늘어나는 곳)
- Create(생성물): `src/decision/core/world_interface.ablate_translate.json`, `src/decision/core/world_interface.ablate_all.json`; 재생성: `src/decision/core/world_interface.json`
- Test: `test/repair_ablation_core.jl`(testset 추가)

**Interfaces:**
- Produces: `ablate_interface_blob(blob::AbstractDict, level::Symbol)::Dict{String,Any}` — `methods` 에서 차단 이름을 빼고, 남은 항목의 `status_meanings` 중 차단 이름을 언급하는 문장을 뺀다. 결과 JSON 문자열에 차단 이름이 하나라도 남으면 에러를 낸다.
- 산출물 이름 규칙(파이썬과 공유): `none` → `world_interface.json`, 그 외 → `world_interface.ablate_<level>.json`.

- [ ] **Step 1: 실패하는 시험을 더한다**

`test/repair_ablation_core.jl` 끝에:
```julia
import JSON3
@testset "팔별 산출물: 차단 이름 0회, 센서·setter 는 남는다" begin
    base = JSON3.read(read(joinpath(pkgdir(CB), "src", "decision", "core", "world_interface.json"), String), Dict{String,Any})
    for lvl in (:translate, :all)
        b = CB.ablate_interface_blob(base, lvl)
        s = JSON3.write(b)
        for n in CB.ablated_names(lvl)
            @test !occursin(String(n), s)
        end
        names = Set(m["name"] for m in b["methods"])
        for keep in ("zone_facts", "zone_blockage", "active_restriction_zones", "set_desired_global_transform!",
                     "global_transform", "reset_cache_resume!")
            @test keep in names
        end
        @test length(b["methods"]) < length(base["methods"])
    end
    b1 = CB.ablate_interface_blob(base, :translate)
    @test "restage_all_blocked!" in Set(m["name"] for m in b1["methods"])      # A1 에는 남는다
    rs = only(m for m in b1["methods"] if m["name"] == "restage_all_blocked!")
    @test !any(occursin("translate_whole_build!", x) for x in get(rs, "status_meanings", String[]))
    @test CB.ablate_interface_blob(base, :none) === base
    # (커밋된 팔별 산출물이 현행 코드와 같은지는 test/world_interface_current.jl 의 재생성 바이트 비교가
    #  지킨다 — Step 5. 여기서 Dict 동등으로 또 재면 진실원이 둘이 된다.)
end
```

- [ ] **Step 2: 실패 확인**

Run: `julia +lts --project=. test/repair_ablation_core.jl`
Expected: FAIL — `ablate_interface_blob not defined`. 또 `zone_facts` 가 base 산출물에 아직 없다.

- [ ] **Step 3: 구현한다**

`src/respec/repair_ablation.jl` 끝에:
```julia
"""
    ablate_interface_blob(blob, level) -> Dict{String,Any}

팔별 광고. `methods` 에서 차단 이름을 빼고, 남은 항목의 `status_meanings` 중 차단 이름을 언급하는 문장을
뺀다(없는 함수를 가리키는 문장이다). 결과에 차단 이름이 한 글자라도 남으면 **에러** — 새 누수 경로가
생긴 것이므로 조용히 내보내지 않는다.
"""
function ablate_interface_blob(blob::AbstractDict, level::Symbol)
    denied = ablated_names(level)
    isempty(denied) && return blob
    dn = Set(String.(denied))
    mentions(s) = any(n -> occursin(n, s), dn)
    out = Dict{String,Any}(String(k) => v for (k, v) in blob)
    ms = Any[]
    for m in blob["methods"]
        String(m["name"]) in dn && continue
        m2 = Dict{String,Any}(String(k) => v for (k, v) in m)
        if haskey(m2, "status_meanings")
            kept = [x for x in m2["status_meanings"] if !mentions(String(x))]
            isempty(kept) ? delete!(m2, "status_meanings") : (m2["status_meanings"] = kept)
        end
        push!(ms, m2)
    end
    out["methods"] = ms
    s = sprint(show, out)
    for n in dn
        occursin(n, s) && error("ablate_interface_blob($(level)): `$(n)` still appears in the artifact — new leak path")
    end
    return out
end
```
`tools/gen_world_interface.jl` — 끝의 `open(dst, "w") do io … end` 와 `println("wrote ", dst)` 를 다음으로 **교체**한다:
```julia
blob = Dict("types" => types,
            "access" => acc,
            "methods" => method_entries(reach, acc),
            "ambient" => [Dict("name" => a.name, "accessor" => a.accessor,
                               "returns" => a.returns,
                               "precondition" => a.precondition)
                          for a in AMBIENT_ROOTS])
open(dst, "w") do io
    JSON3.pretty(io, blob)
end
println("wrote ", dst)
# 존 복구 base ablation(2026-09-23, 명세 §6 층 1): 같은 폴더에 팔별 산출물. 이름 규칙은
# llm_service/repair_ablation.py::artifact_name 과 같다.
for lvl in (:translate, :all)
    p = replace(dst, r"\.json$" => ".ablate_$(lvl).json")
    ab = JSON3.read(JSON3.write(blob), Dict{String,Any})     # 문자열 키로 정규화한 뒤 거른다
    open(p, "w") do io
        JSON3.pretty(io, CB.ablate_interface_blob(ab, lvl))
    end
    println("wrote ", p)
end
```
`src/respec/minted_registration.jl` — `_world_interface_path()` 의 파일 이름 부분이 `"world_interface.json"` 인 곳을 레벨 규칙으로 바꾼다:
```julia
_world_interface_basename() = REPAIR_ABLATION[] === :none ? "world_interface.json" :
                              "world_interface.ablate_$(REPAIR_ABLATION[]).json"
```
그리고 `_world_interface_path()` 본문의 `"world_interface.json"` 리터럴을 `_world_interface_basename()` 으로 바꾼다.

- [ ] **Step 4: 산출물을 재생성한다(기본 경로)**

Run: `cd /home/chahj578/Construction_OODlayer && julia +lts --project=. tools/gen_world_interface.jl`
Expected: `wrote …/world_interface.json` 와 `wrote …/world_interface.ablate_translate.json`, `…ablate_all.json` 세 줄이 나오고 에러가 없다. ⚠️ 인자 없이 돌리면 커밋된 산출물을 덮어쓴다. 여기서는 그게 의도다.

- [ ] **Step 5: 재생성 비교 시험에 두 파일을 더한다**

`test/world_interface_current.jl` testset (2) 는 임시 경로로 재생성해 바이트를 비교한다. 같은 testset 안, 기존 `@test read(out, String) == read(ART, String)` 바로 아래에:
```julia
    for lvl in ("translate", "all")
        @test read(replace(out, r"\.json$" => ".ablate_$(lvl).json"), String) ==
              read(replace(ART, r"\.json$" => ".ablate_$(lvl).json"), String)
    end
```
Run: `julia +lts --project=. test/world_interface_current.jl 2>&1 | tail -5`
Expected: PASS. 실패하는 핀이 `zone_facts` 추가로 늘어난 전수(closure 개수 등)뿐이면 그 숫자를 +1 로 고치고, 주석에 `2026-09-23 zone_facts 추가(존 복구 base ablation)` 를 단다. 다른 이유의 실패는 멈추고 원인을 적는다.

- [ ] **Step 6: 파이썬 렌더 시험이 기본 산출물로 여전히 초록인지 확인**

Run: `.venv/bin/python -m pytest src/respec/llm_service/test_world_interface_render.py src/respec/llm_service/test_world_interface_block.py -q 2>&1 | tail -3`
Expected: PASS(Task 0 기준선과 같은 수 + 0 실패).

- [ ] **Step 7: 커밋**

```bash
git commit -m "광고: 팔별 세계 인터페이스 산출물(ablate_translate·ablate_all) + zone_facts 광고 (명세 §6 층 1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- src/respec/repair_ablation.jl tools/gen_world_interface.jl src/respec/minted_registration.jl test/repair_ablation_core.jl test/world_interface_current.jl src/decision/core/world_interface.json src/decision/core/world_interface.ablate_translate.json src/decision/core/world_interface.ablate_all.json
```
(Step 5 에서 핀을 고친 시험 파일이 있으면 경로 목록에 더한다.)

---

### Task 6: 서비스 — 레벨·산출물 선택·`/health`·핸드셰이크

**Files:**
- Create: `src/respec/llm_service/repair_ablation.py`
- Modify: `src/respec/llm_service/world_interface.py`(`ARTIFACT`)
- Modify: `src/respec/llm_service/dspy_service.py`(`/health` 반환 dict, `decide`·`rewrite` 첫 줄)
- Modify: `tools/monitor/grid/campaign.py`(`SERVICE_KEYS` 에 `"repair_ablation"`)
- Test: `src/respec/llm_service/test_repair_ablation.py`, `tools/monitor/grid/test_campaign.py`(한 줄)

**Interfaces:**
- Produces:
  - `repair_ablation.LEVELS`
  - `repair_ablation.level(env=None)->str`
  - `repair_ablation.artifact_name(lvl)->str`
  - `repair_ablation.check_handshake(run_ctx, service_level)->Optional[str]`
  - `/health` JSON 키 `"repair_ablation"`
- Consumes: 산출물 이름 규칙(Task 5)

- [ ] **Step 1: 실패하는 시험을 쓴다**

`src/respec/llm_service/test_repair_ablation.py`:
```python
"""존 복구 base ablation — 서비스 쪽 레벨·산출물·핸드셰이크 (명세 §6).
레포 루트에서: .venv/bin/python -m pytest src/respec/llm_service/test_repair_ablation.py -q
"""
import os
import pytest
import repair_ablation as RA
import world_interface as WI


def test_level_accepts_exactly_three():
    assert RA.level({}) == "none"
    for v in ("none", "translate", "all"):
        assert RA.level({"REPAIR_ABLATION": v}) == v
    for bad in ("", "ALL", "a2", "None", " all"):
        with pytest.raises(ValueError):
            RA.level({"REPAIR_ABLATION": bad})


def test_artifact_name_matches_julia_rule():
    assert RA.artifact_name("none") == "world_interface.json"
    assert RA.artifact_name("translate") == "world_interface.ablate_translate.json"
    assert RA.artifact_name("all") == "world_interface.ablate_all.json"


def test_ablated_artifacts_exist_and_hide_the_base():
    core = os.path.dirname(WI.ARTIFACT)
    for lvl, gone in (("translate", "translate_whole_build!"), ("all", "restage_all_blocked!")):
        blob = WI.load_world_interface(os.path.join(core, RA.artifact_name(lvl)))
        text = WI.build_world_interface_block(blob)
        assert gone not in text
        assert "zone_facts" in text


def test_handshake():
    assert RA.check_handshake({"repair_ablation": "all"}, "all") is None
    assert "mismatch" in RA.check_handshake({"repair_ablation": "none"}, "all")
    assert RA.check_handshake(None, "none") is None              # 옛 호출자·시험은 none 에서만 통과
    assert RA.check_handshake({}, "none") is None
    assert "no repair_ablation" in RA.check_handshake({}, "all")
```
`tools/monitor/grid/test_campaign.py` 에 한 줄:
```python
def test_service_keys_include_repair_ablation():
    import campaign
    assert "repair_ablation" in campaign.SERVICE_KEYS
```

- [ ] **Step 2: 실패 확인**

Run: `.venv/bin/python -m pytest src/respec/llm_service/test_repair_ablation.py tools/monitor/grid/test_campaign.py -q 2>&1 | tail -5`
Expected: FAIL — `ModuleNotFoundError: repair_ablation`, SERVICE_KEYS 단언 실패.

- [ ] **Step 3: 구현한다**

`src/respec/llm_service/repair_ablation.py`:
```python
"""존 복구 base ablation — 서비스 쪽 (2026-09-23, 명세 docs/superpowers/specs/2026-09-23-zone-repair-base-ablation-design.md §6).

🔴 레벨은 정확히 셋. 그 밖의 값은 크게 죽는다 — 조용히 none 으로 떨어지면 팔이 섞인다.
🔴 산출물 이름 규칙은 Julia `tools/gen_world_interface.jl` 과 같다(한쪽만 바꾸지 말 것).
"""
import os
from typing import Any, Dict, Optional

LEVELS = ("none", "translate", "all")


def level(env=None) -> str:
    v = (os.environ if env is None else env).get("REPAIR_ABLATION", "none")
    if v not in LEVELS:
        raise ValueError("REPAIR_ABLATION=%r -- allowed exactly: %s" % (v, ", ".join(LEVELS)))
    return v


def artifact_name(lvl: str) -> str:
    level({"REPAIR_ABLATION": lvl})
    return "world_interface.json" if lvl == "none" else "world_interface.ablate_%s.json" % lvl


def check_handshake(run_ctx: Optional[Dict[str, Any]], service_level: str) -> Optional[str]:
    """None = 맞다. 문자열 = 거절 사유. run_ctx 에 키가 없으면 none 서비스에서만 통과한다."""
    theirs = (run_ctx or {}).get("repair_ablation")
    if theirs is None:
        return None if service_level == "none" else (
            "run_ctx has no repair_ablation but this service runs repair_ablation=%r" % service_level)
    return None if theirs == service_level else (
        "repair_ablation mismatch: julia=%r service=%r" % (theirs, service_level))
```
`world_interface.py` — `ARTIFACT = os.path.join(WM, "core", "world_interface.json")` 를 다음으로 바꾸고, 파일 위쪽 import 에 `import repair_ablation as RA` 를 더한다:
```python
#: 🔴 존 복구 base ablation(2026-09-23): 서비스 기동 레벨의 산출물. 기동 때 한 번 정해진다 — 레벨이
#:    틀리면 import 에서 죽는다(조용히 기본 산출물로 돌지 않는다).
ARTIFACT = os.path.join(WM, "core", RA.artifact_name(RA.level()))
```
`dspy_service.py`:
- import 부에 `import repair_ablation as RA` 를 넣고, 모듈 상단 설정부(`MODEL = …` 근처)에 `REPAIR_ABLATION = RA.level()` 를 넣는다.
- `/health` 반환 dict(`"status": "ok", "policy": …` 로 시작하는 것)에 `"repair_ablation": REPAIR_ABLATION,` 를 더한다.
- `def decide(req: MacroRequest):` 와 `def rewrite(req: RewriteRequest):` 의 docstring 바로 다음 첫 줄에:
```python
    _why = RA.check_handshake(req.run_ctx, REPAIR_ABLATION)
    if _why:
        # 🔴 존 복구 base ablation: 레벨이 다른 판이 이 서비스로 오면 **결정을 내지 않는다**.
        #    Julia 는 기동 때 /health 로 먼저 막는다(policy.jl assert_service_repair_ablation) — 이것은 둘째 층이다.
        raise ValueError(_why)
```
`campaign.py` — `SERVICE_KEYS = (…)` 튜플 끝에 `"repair_ablation",` 를 더한다.

- [ ] **Step 4: 통과 확인 + 기준선 대조**

Run: `.venv/bin/python -m pytest src/respec/llm_service tools/monitor/grid -q 2>&1 | tail -3`
Expected: 새 시험 PASS. 나머지는 Task 0 기준선과 같다.

- [ ] **Step 5: 커밋**

```bash
git commit -m "서비스: REPAIR_ABLATION 레벨·팔별 산출물·/health 키·decide/rewrite 핸드셰이크, campaign SERVICE_KEYS (명세 §6)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- src/respec/llm_service/repair_ablation.py src/respec/llm_service/world_interface.py src/respec/llm_service/dspy_service.py src/respec/llm_service/test_repair_ablation.py tools/monitor/grid/campaign.py tools/monitor/grid/test_campaign.py
```

---

### Task 7: 세 팔 공통 — 원칙 문장 중립화와 해법 관측 행 제거

**Files:**
- Modify: `src/respec/llm_service/synthesize.py`(`PHYSICAL_PRINCIPLES` §2 한 문장)
- Modify: `src/respec/llm_service/dspy_service.py`(`_GEOM_COVERAGE` 두 항목)
- Modify: 이 문장·행을 고정한 기존 시험(`test_physical_principles_are_true.py`, `test_zone_channel.py` 등 — Step 2 에서 찾는다)
- Test: `src/respec/llm_service/test_repair_ablation.py`(추가)

- [ ] **Step 1: 실패하는 시험을 더한다**

`test_repair_ablation.py` 끝에:
```python
import synthesize as S
import dspy_service as D


def test_principles_do_not_name_a_repair_mechanism():
    p = S.PHYSICAL_PRINCIPLES
    assert "translating the whole build" not in p
    assert "Moving staging areas" not in p
    assert "Geometric edits (staging poses, deposit goals, build placement) edit THIS tree" in p


def test_observation_is_invariant_to_solver_fields():
    """면제된 페이로드(policy.jl :policy_payload)가 해법 값을 실어도 렌더된 관측은 같다."""
    base = dict(kind="zone", zone_blocked=2, zone_root_covered=1, zone_root_total=8,
                zone_work_overlap=3, zone_teams_forming=1, zone_teams_covered=0,
                zone_nav_goals=40, zone_nav_blocked=2)
    a = D.MacroRequest(**base, zone_restage_feasible=0, zone_relocatable=False, zone_relocate_norm=-1.0)
    b = D.MacroRequest(**base, zone_restage_feasible=2, zone_relocatable=True, zone_relocate_norm=3.25)
    assert D._llm_input(a) == D._llm_input(b)
    t = D._llm_input(b)
    assert "movable" not in t and "cannot be restaged" not in t and "3.25" not in t
```
⚠️ `MacroRequest` 의 필수 필드가 더 있으면 `test_zone_channel.py` 가 요청을 만드는 방식을 그대로 가져와 `base` 를 채운다(Step 2 에서 확인).

- [ ] **Step 2: 실패 확인 + 기존 고정 찾기**

Run: `.venv/bin/python -m pytest src/respec/llm_service/test_repair_ablation.py -q 2>&1 | tail -5; /usr/bin/grep -rn "of which movable\|zone_restage_feasible\|cannot be restaged\|translating the whole build" src/respec/llm_service/test_*.py`
Expected: 새 두 시험 FAIL. grep 결과가 이 변경으로 갱신할 고정 목록이다.

- [ ] **Step 3: 구현한다**

`synthesize.py` §2:
```
   Moving staging areas or translating the whole build edits THIS tree, not the schedule.
```
를 다음으로 바꾼다:
```
   Geometric edits (staging poses, deposit goals, build placement) edit THIS tree, not the schedule.
```
`dspy_service.py` `_GEOM_COVERAGE`:
- `("zone_restage_feasible", "  of which movable", "of those, how many have a zone-clear spot to be restaged into"),` 항목을 지우고, 그 자리에 주석을 남긴다:
```python
    # 🔴 2026-09-23 (존 복구 base ablation 명세 §5, 세 팔 공통): "of which movable" 행을 지웠다 —
    #    그 값은 find_clear_staging_center 가 **푼 답**(해법 정보)이다. 필드는 MacroRequest 에 남는다.
```
- `zone_root_covered` 설명의 `"the root cannot be restaged. These "` 를 `"These "` 로 바꾼다. 결과 문장: `"delivery goals of the ROOT assembly inside the zone. These are placed by a lift that moves the cargo directly, not by a navigating agent"`.

Step 2 에서 찾은 기존 고정은 새 문구로 고친다. 필드가 남는다는 게이트(`test_the_field_survives_even_though_the_row_is_gone` 류)는 그대로 둔다.

- [ ] **Step 4: 통과 확인**

Run: `.venv/bin/python -m pytest src/respec/llm_service -q 2>&1 | tail -3`
Expected: 새 시험 PASS, 전체는 기준선 + 새 시험 수.

- [ ] **Step 5: 커밋**

```bash
git commit -m "세 팔 공통: 원칙 문장에서 수리 기전 이름을 빼고 해법 관측 행(of which movable)을 지운다 (명세 §5)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- src/respec/llm_service/synthesize.py src/respec/llm_service/dspy_service.py src/respec/llm_service/test_repair_ablation.py <Step 2 에서 고친 시험 파일들>
```

---

### Task 8: 엔진 배선 — 레벨 설정·무장·면제·사다리·요약 줄·설정 지문

**Files:**
- Modify: `tools/monitor/render_demo.jl` — 레벨 설정, `set_run_ctx!` 에 `repair_ablation`, 서비스 단언, 무장 두 자리, `[ablation]` 줄
- Modify: `tools/monitor/policy.jl` — 면제 3곳, `CONFIG_ENV_RESULT`·`CONFIG_ENV_PINNED_DEFAULTS`, `SERVICE_REPAIR_ABLATION` 캐시와 `assert_service_repair_ablation()`
- Modify: `tools/monitor/dp_lane.jl` — 면제 1곳
- Modify: `src/respec/replace_robot.jl` — 사다리 존 분기
- Test: `test/repair_ablation_wiring.jl`(소스 고정), `test/config_digest_inventory.jl`(핀 갱신)

**Interfaces:**
- Consumes: Task 1 전부. `/health` 의 `repair_ablation`(Task 6).
- Produces:
  - 로그 줄 `[ablation] level=… armed=… denied=… exempt=… ladder_zone_skipped=… ladder_zone_fired=… detail=…`
  - `[run-ctx]` JSON 의 `repair_ablation` 키
  - `recover_stalled_teams!` 새 반환 `(status = :zone_repair_ablated, moved = 0)`

- [ ] **Step 1: 실패하는 소스 고정 시험을 쓴다**

`test/repair_ablation_wiring.jl`:
```julia
# test/repair_ablation_wiring.jl — 렌더 경로 배선의 소스 고정(명세 §6·§7)
#   julia +lts --project=. test/repair_ablation_wiring.jl
using Test
const ROOT = normpath(joinpath(@__DIR__, ".."))
src(p) = read(joinpath(ROOT, p), String)

@testset "render_demo: 레벨 설정 → run_ctx → 주입 → 무장 → score → ablation 순서" begin
    s = src("tools/monitor/render_demo.jl")
    i_set   = findfirst("CB.set_repair_ablation!(CB.repair_ablation_from_env())", s)
    i_ctx   = findfirst("repair_ablation = String(CB.REPAIR_ABLATION[])", s)
    i_inj   = findfirst("injected pre-sim\")", s)
    i_arm   = findfirst("CB.arm_repair_ablation!()   # presim", s)
    i_score = findfirst("println(\"[score] complete=\"", s)
    i_abl   = findfirst("println(\"[ablation] \", CB.ablation_summary_line())", s)
    @test all(!isnothing, (i_set, i_ctx, i_inj, i_arm, i_score, i_abl))
    @test first(i_set) < first(i_ctx)
    @test first(i_inj) < first(i_arm)          # 🔴 주입이 끝난 뒤에 무장한다(Review Focus 5)
    @test first(i_score) < first(i_abl)
    # 지연 주입 경로도 콜백 안에서 주입 뒤에 무장한다
    @test occursin(r"nl = inject_blocking_zone!\(e\)[\s\S]{0,400}CB\.arm_repair_ablation!\(\)   # deferred", s)
end

@testset "policy.jl·dp_lane.jl: 존 진단 4곳이 전부 이름 붙은 면제 안에 있다" begin
    p = src("tools/monitor/policy.jl"); d = src("tools/monitor/dp_lane.jl")
    for site in (":policy_payload", ":reference_label", ":monitor_record")
        @test occursin("CB.ablation_exempt($(site))", p)
    end
    @test occursin("CB.ablation_exempt(:dp_lane)", d)
    # 면제 밖의 맨 zone_diagnosis 호출이 남지 않았다
    for (name, txt) in (("policy.jl", p), ("dp_lane.jl", d))
        for m in eachmatch(r"CB\.zone_diagnosis\(env", txt)
            ctx = txt[max(1, m.offset - 120):m.offset]
            @test occursin("ablation_exempt", ctx)
        end
    end
    @test occursin("\"REPAIR_ABLATION\"", p)
    @test occursin("\"REPAIR_ABLATION\" => \"none\"", p)
end

@testset "replace_robot: 사다리 존 분기는 ablation 에서 건너뛰고 센다" begin
    r = src("src/respec/replace_robot.jl")
    i_skip = findfirst("if zone_blocked && ablation_blocks_zone_ladder()", r)
    i_fire = findfirst("_ablation_bump!(\"ladder_zone_fired\")", r)
    i_call = findfirst("res = restage_all_blocked!(env)", r)
    @test all(!isnothing, (i_skip, i_fire, i_call))
    @test first(i_skip) < first(i_fire) < first(i_call)
end
```

- [ ] **Step 2: 실패 확인**

Run: `julia +lts --project=. test/repair_ablation_wiring.jl`
Expected: FAIL 전부.

- [ ] **Step 3: `replace_robot.jl` 사다리**

`if zone_blocked` 블록(`res = restage_all_blocked!(env)` 가 든 것)을 다음으로 교체한다:
```julia
    # 🔴 존 복구 base ablation (2026-09-23, 명세 §6 층 4). 이 분기는 LLM 없이 사람이 쓴 restage→translate 를
    #    부른다. ablation 팔에서는 건너뛰고 센다; none 에서는 그대로 돌되 **발동을 센다**(전에는 잴 수단이 없었다).
    #    반환 상태는 호출자 셋(ood_injection·replan·render_demo)이 전부 "성공 목록 밖 = 실패" 로 읽는다.
    if zone_blocked && ablation_blocks_zone_ladder()
        _ablation_bump!("ladder_zone_skipped")
        verbose && @info "[RESPEC] recover: gather point in no-go zone -> zone repair ladder skipped (repair_ablation=$(REPAIR_ABLATION[]))"
        return (status = :zone_repair_ablated, moved = 0)
    end
    if zone_blocked
        _ablation_bump!("ladder_zone_fired")
        res = restage_all_blocked!(env)           # 막힌 팀들의 집결지를 zone 밖으로 재배치
```
(이하 기존 줄은 그대로.)

- [ ] **Step 4: `policy.jl` 면제 3곳 + 설정 지문 + 서비스 단언**

(a) 관측 페이로드(`local zdg = try CB.zone_diagnosis(env, truth.zone) catch e` — `@warn "[policy] zone_diagnosis failed` 가 있는 곳):
```julia
        local zdg = try CB.ablation_exempt(:policy_payload) do
                CB.zone_diagnosis(env, truth.zone)
            end catch e
            @warn "[policy] zone_diagnosis failed -> 원시값 없이 진행" exception = e; nothing
        end
```
(b) 참조 라벨(`local zdg = try CB.zone_diagnosis(env, truth.zone) catch; nothing end`):
```julia
        local zdg = try CB.ablation_exempt(:reference_label) do
                CB.zone_diagnosis(env, truth.zone)
            end catch; nothing end
```
(c) 모니터 기록(`CB.zone_diagnosis(env, truth.zone; check_restage = true)`): 그 식을 다음으로 감싼다.
```julia
            CB.ablation_exempt(:monitor_record) do
                CB.zone_diagnosis(env, truth.zone; check_restage = true)
            end
```
(d) `CONFIG_ENV_RESULT` 의 복구 손잡이 줄 끝에 `"REPAIR_ABLATION",` 를 더하고, `CONFIG_ENV_PINNED_DEFAULTS` 에 `"REPAIR_ABLATION" => "none",` 를 더한다.
(e) `dspy_ready()` 에서 `SURRO_KINDS[] = try … end` 바로 다음에 넣는다:
```julia
            SERVICE_REPAIR_ABLATION[] = try
                local ra = get(JSON3.read(String(r.body)), :repair_ablation, nothing)
                ra === nothing ? nothing : String(ra)
            catch; nothing end
```
`SURRO_KINDS` 정의 옆에 넣는다:
```julia
"서비스 `/health` 의 `repair_ablation`(존 복구 base ablation). `nothing` = 못 읽었다."
const SERVICE_REPAIR_ABLATION = Ref{Union{Nothing,String}}(nothing)

"🔴 기동 단언: 서비스 레벨이 이 판의 레벨과 다르거나 못 읽으면 **첫 결정 전에** 죽는다."
function assert_service_repair_ablation()
    dspy_ready() || error("[ablation] DSPy service not ready at $(DSPY_URL) — cannot verify repair_ablation")
    got = SERVICE_REPAIR_ABLATION[]
    want = String(CB.REPAIR_ABLATION[])
    got == want || error("[ablation] service repair_ablation=$(repr(got)) != julia $(repr(want)) at $(DSPY_URL)")
    return nothing
end
```

- [ ] **Step 5: `dp_lane.jl` 면제**

`zdg = try CB.zone_diagnosis(env, truth.zone) catch; nothing end` 를 다음으로 바꾼다:
```julia
        zdg = try CB.ablation_exempt(:dp_lane) do
                CB.zone_diagnosis(env, truth.zone)
            end catch; nothing end
```

- [ ] **Step 6: `render_demo.jl`**

(a) `haskey(ENV, "CARRIER_RESCUE") || (ENV["CARRIER_RESCUE"] = "1")` 바로 아래에:
```julia
    # 존 복구 base ablation(2026-09-23, 명세 §6). 레벨이 틀리면 여기서 죽는다.
    CB.set_repair_ablation!(CB.repair_ablation_from_env())
```
(b) `set_run_ctx!(; …` 인자 목록의 `synth_fixture = …,` 다음 줄에:
```julia
             repair_ablation = String(CB.REPAIR_ABLATION[]),
```
(c) `println("[run-ctx] ", JSON3.write(RUN_CTX[]))` 바로 아래에:
```julia
router_drives() && assert_service_repair_ablation()   # 🔴 레벨 불일치면 첫 결정 전에 죽는다(Review Focus 1)
```
(d) 주입 블록: presim 분기의 `println("    · zone($(DEMO_ZONE_MODE)) injected pre-sim")` 바로 아래에:
```julia
            CB.arm_repair_ablation!()   # presim: 주입이 끝난 뒤에 무장한다(주입은 zone_relocatable 로 존을 고른다)
```
지연 분기 콜백은 다음으로 바꾼다:
```julia
            CB.schedule_ood_at_closed!(zone_at, function (e)
                nl = inject_blocking_zone!(e)
                nl === nothing && (println("[zone] blocking placement failed → falling back to the harmless injector");
                                   nl = inject_staging_zone!(e))
                CB.arm_repair_ablation!()   # deferred: 주입 직후 무장
                return nl
            end)
```
harmless 분기(`println("    · zone(harmless) injected pre-sim")`) 아래와, `has_zone` 이 거짓인 판(battery·fault 단독)에도 무장이 필요하다. `if has_zone && INTERACTIVE … end` 블록 **바로 뒤**에 넣는다:
```julia
    (has_zone && !DEMO_ZONE_PRESIM && DEMO_ZONE_MODE == "blocking") || CB.repair_ablation_armed() ||
        CB.arm_repair_ablation!()   # 존이 없거나 harmless 판: 시뮬 시작 전에 무장
```
(e) `[score]` 를 찍는 `let e = render_env … end` 블록 바로 뒤에:
```julia
println("[ablation] ", CB.ablation_summary_line())
```

- [ ] **Step 7: 시험 통과 + 지문 핀 갱신**

Run: `julia +lts --project=. test/repair_ablation_wiring.jl && julia +lts --project=. test/config_digest_inventory.jl 2>&1 | tail -5`
Expected: wiring PASS. config_digest_inventory 가 `CONFIG_ENV_RESULT` 목록이나 개수를 고정하고 있으면 `REPAIR_ABLATION` 을 더해 고치고 다시 돌려 PASS 를 확인한다.

- [ ] **Step 8: 무료 스모크 한 판(none, 서비스 없음)**

Run:
```bash
cd /home/chahj578/Construction_OODlayer && mkdir -p /tmp/claude-1035/abl-smoke && \
PIN="CARRIER_RESCUE=1 DEMO_ANIM=0 ENERGY_OBJECTIVE=1 RESPEC_DEPRIO_KAPPA=0.25 RESPEC_TRANSLATE_ON_INFEASIBLE=0 RESTAGE_NAV_BUFFER=0 RESTAGE_RING_STEP_FRAC=0.34 RESTAGE_ZONE_MARGIN_FRAC=0.5 SPARE_PRIORITY=1 TEAM_PRIORITY=1 ZONE_CAUSAL_RULE=0 ZONE_CHECK_PATHS=0 ZONE_DOMAIN_GATE=0 ZONE_RESCUE=1"; \
timeout 1800 env $PIN DEMO_MODEL=tractor.mpd DEMO_OOD=none DEMO_ZONE=1 DEMO_ZONE_SEED=1 DEMO_SEED=1 \
  DEMO_ROUTER=0 DEMO_POLICY=canonical DEMO_CASE_TAG=abl_smoke \
  DEMO_OUT_DIR=/tmp/claude-1035/abl-smoke REPAIR_ABLATION=none \
  julia +lts --project=. tools/monitor/render_demo.jl </dev/null > /tmp/claude-1035/abl-smoke/none.log 2>&1; \
/usr/bin/grep -E '^\[score\]|^\[ablation\]|^\[run-ctx\]' /tmp/claude-1035/abl-smoke/none.log | cut -c1-300
```
Expected: `[run-ctx]` 에 `"repair_ablation":"none"` 가 있고, `[score]` 한 줄, `[ablation] level=none armed=true denied=0 …` 한 줄이 나온다. `exempt:` 는 0 이상이다. 이 판의 `[score]` 는 9/23 기준선 free tractor zone s1 과 같아야 한다(`results/2026-09-23-baseline-free-tractor/log/` 의 해당 판과 비교). 다르면 멈추고 원인부터 찾는다.

- [ ] **Step 9: 커밋**

```bash
git commit -m "렌더 배선: 레벨 설정·run_ctx·서비스 단언·주입 후 무장·면제 4곳·사다리 건너뜀·[ablation] 줄·설정 지문 (명세 §6·§7)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- tools/monitor/render_demo.jl tools/monitor/policy.jl tools/monitor/dp_lane.jl src/respec/replace_robot.jl test/repair_ablation_wiring.jl test/config_digest_inventory.jl
```

---

### Task 9: 집계기 — `[ablation]` 줄을 판 레코드로

**Files:**
- Modify: `tools/monitor/build_sweep_dataset.py`(`parse_log`)
- Test: `tools/monitor/test_build_sweep_dataset.py`

- [ ] **Step 1: 실패하는 시험을 더한다**

`test_build_sweep_dataset.py` 끝에:
```python
def test_parse_log_reads_ablation_line():
    import build_sweep_dataset as B
    txt = ("[score] complete=true closed=287 n_zones=1 n_blocked=0 n_nav_goals=40 n_engulfed=0 "
           "n_agent_trapped=0 project_blocked=false\n"
           "[ablation] level=all armed=true denied=2 exempt=5 ladder_zone_skipped=1 ladder_zone_fired=0 "
           "detail=denied:translate_whole_build!=2,exempt:policy_payload=5,ladder_zone_skipped=1\n")
    r = B.parse_log(txt, "router", "zone", 1)
    assert r["ablation"] == {"level": "all", "armed": True, "denied": 2, "exempt": 5,
                             "ladder_zone_skipped": 1, "ladder_zone_fired": 0,
                             "detail": "denied:translate_whole_build!=2,exempt:policy_payload=5,ladder_zone_skipped=1"}


def test_parse_log_without_ablation_line_is_none_not_zero():
    import build_sweep_dataset as B
    r = B.parse_log("[score] complete=false closed=10 n_zones=1 zone_blockage=unavailable\n", "router", "zone", 1)
    assert r["ablation"] is None
```

- [ ] **Step 2: 실패 확인**

Run: `.venv/bin/python -m pytest tools/monitor/test_build_sweep_dataset.py -q -k ablation 2>&1 | tail -3`
Expected: FAIL — `KeyError: 'ablation'`.

- [ ] **Step 3: 구현한다**

`build_sweep_dataset.py` 의 `parse_log` 위에:
```python
def ablation_of(txt):
    """`[ablation]` 줄 → dict. 줄이 없으면 None(0 으로 접지 않는다 — 옛 판은 이 줄을 안 찍었다)."""
    m = re.search(r"^\[ablation\] level=(\w+) armed=(true|false) denied=(\d+) exempt=(\d+) "
                  r"ladder_zone_skipped=(\d+) ladder_zone_fired=(\d+) detail=(\S*)", txt, re.M)
    if not m:
        return None
    return {"level": m[1], "armed": m[2] == "true", "denied": int(m[3]), "exempt": int(m[4]),
            "ladder_zone_skipped": int(m[5]), "ladder_zone_fired": int(m[6]), "detail": m[7]}
```
`parse_log` 의 반환 `dict(…)` 에 `ablation=ablation_of(txt),` 를 더한다. `re` 가 import 돼 있지 않으면 import 한다.

- [ ] **Step 4: 통과 확인**

Run: `.venv/bin/python -m pytest tools/monitor/test_build_sweep_dataset.py -q 2>&1 | tail -3`
Expected: PASS 전부.

- [ ] **Step 5: 커밋**

```bash
git commit -m "집계기: [ablation] 줄을 판 레코드 ablation 으로 (없으면 None)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- tools/monitor/build_sweep_dataset.py tools/monitor/test_build_sweep_dataset.py
```

---

### Task 10: G2 — 음성 대조(무료)

**Files:**
- Create: `results/2026-09-2x-repair-ablation/g2/run_g2.sh`, `…/g2/README.md`(결과)

- [ ] **Step 1: 드라이버를 쓴다**

`results/<날짜>-repair-ablation/g2/run_g2.sh`(날짜는 실행일):
```bash
#!/usr/bin/env bash
# G2 음성 대조: translate 를 부르는 기존 오라클 픽스처가 ablation 팔에서 막히는가(무료, 서비스 없음).
set -u
ROOT=/home/chahj578/Construction_OODlayer; OUT=$(cd "$(dirname "$0")" && pwd); mkdir -p "$OUT/log"
# campaign 의 고정 env(9/23 sol campaign.json set_env 에서 DSPY_URL 만 뺀 것) — 격자와 같은 세계여야 한다
PIN="CARRIER_RESCUE=1 DEMO_ANIM=0 ENERGY_OBJECTIVE=1 RESPEC_DEPRIO_KAPPA=0.25 RESPEC_TRANSLATE_ON_INFEASIBLE=0 RESTAGE_NAV_BUFFER=0 RESTAGE_RING_STEP_FRAC=0.34 RESTAGE_ZONE_MARGIN_FRAC=0.5 SPARE_PRIORITY=1 TEAM_PRIORITY=1 ZONE_CAUSAL_RULE=0 ZONE_CHECK_PATHS=0 ZONE_DOMAIN_GATE=0 ZONE_RESCUE=1"
for lvl in none translate all; do
  timeout 3600 env $PIN DEMO_MODEL=tractor.mpd DEMO_OOD=none DEMO_ZONE=1 DEMO_ZONE_SEED=1 DEMO_SEED=1 \
    DEMO_ROUTER=0 DEMO_POLICY=canonical DEMO_OUT_DIR="$OUT" DEMO_CASE_TAG="g2_$lvl" \
    DEMO_SYNTH_FIXTURE="$ROOT/tools/fixtures/oracle_zone_clear.json" REPAIR_ABLATION=$lvl \
    MONITOR_RUN_ID="g2_$lvl" julia +lts --project="$ROOT" "$ROOT/tools/monitor/render_demo.jl" </dev/null \
    > "$OUT/log/$lvl.log" 2>&1
  echo "$lvl rc=$? $(/usr/bin/grep -ho '^\[score\].*' "$OUT/log/$lvl.log" | tail -1)"
  /usr/bin/grep -hoE 'reject:ablated_primitive:[^ ]+|AblatedPrimitiveError[^\n]{0,80}|^\[ablation\].*' "$OUT/log/$lvl.log" | head -5
done
```

- [ ] **Step 2: 돌린다**

Run: `bash results/<날짜>-repair-ablation/g2/run_g2.sh`
⚠️ `PIN` 은 실행 시점의 캠페인 `set_env` 와 대조한다. Task 8 이 `REPAIR_ABLATION` 을 pinned default 에 넣었으므로 `campaign.py init` 산출물의 `set_env` 를 한 번 찍어 보고 PIN 을 맞춘다.
Expected:
- `none`: 픽스처가 집행되고 `[ablation] … denied=0`. 완주 여부는 9/22 S1 오라클과 같은 방향이어야 한다.
- `translate`·`all`: `reject:ablated_primitive:translate_whole_build!`(등록 층) 또는 `AblatedPrimitiveError`(실행 층) 중 하나가 나온다. 어느 층에서 막혔는지 README 에 적는다. 픽스처 경로가 등록 검사를 안 거치면 실행 층에서 막혀야 한다.
- 🔴 ablation 팔에서 둘 다 안 나오면 **멈춘다**. 차단이 안 된 것이다.

- [ ] **Step 3: 결과를 README 에 적고 커밋**

```bash
git add results/<날짜>-repair-ablation/g2
git commit -m "G2 음성 대조: translate 오라클이 ablation 팔에서 <층> 에서 막힌다

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- results/<날짜>-repair-ablation/g2
```

---

### Task 11: G3 — A2 어휘 실현 가능성 오라클(무료, 120 시드)

**Files:**
- Create: `tools/fixtures/oracle_zone_clear_nobase.json`
- Create: `test/oracle_nobase_uses_only_a2_vocabulary.jl`
- Create: `results/<날짜>-repair-ablation/g3/run_g3.sh`, `…/g3/tally.py`, `…/g3/README.md`

**Interfaces:**
- Consumes: `ablate_all` 산출물(Task 5), 등록 게이트(Task 4).

- [ ] **Step 1: 어휘 준수 시험을 먼저 쓴다**

`test/oracle_nobase_uses_only_a2_vocabulary.jl`:
```julia
# 오라클 body 는 A2 에서 광고된 이름만 쓴다 — 그래야 오라클 완주가 "A2 어휘로 풀 수 있다" 의 증거가 된다
#   julia +lts --project=. test/oracle_nobase_uses_only_a2_vocabulary.jl
using ConstructionBots, Test
import JSON3
const CB = ConstructionBots
fx = JSON3.read(read(joinpath(pkgdir(CB), "tools", "fixtures", "oracle_zone_clear_nobase.json"), String))
code = String(fx.impl_code); name = String(fx.impl_name)
art = JSON3.read(read(joinpath(pkgdir(CB), "src", "decision", "core", "world_interface.ablate_all.json"), String))
advertised = Set(String(m.name) for m in art.methods)

@testset "A2 등록 게이트를 통과한다" begin
    try
        CB.set_repair_ablation!(:all)
        @test CB.check_impl_conventions(name, code) === nothing
    finally
        CB.set_repair_ablation!(:none)
    end
end

@testset "CB 의 이름을 부른다면 그것은 A2 에 광고된 이름이다" begin
    f = Meta.parse(code)
    cs, fs, ls = Symbol[], Tuple{Any,Symbol}[], Symbol[]
    CB._walk_body!(cs, fs, ls, f.args[2])
    for c in unique(cs)
        c in ls && continue
        isdefined(Base, c) && continue
        Base.binding_module(CB, c) === CB || continue      # CB 밖(CoordinateTransformations 등)의 이름은 제외
        @test String(c) in advertised
    end
end
```

- [ ] **Step 2: 오라클 v0 를 쓴다**

`tools/fixtures/oracle_zone_clear_nobase.json`(키 모양은 `oracle_zone_clear.json` 과 같다):
```json
{
  "tool_name": "OracleZoneClearNoBase",
  "mechanism": "feasibility oracle for the zone-repair base ablation (spec 2026-09-23 §8). Uses ONLY names advertised in world_interface.ablate_all.json: read the live zone from active_restriction_zones(), measure with zone_blockage, and rigidly shift the whole build away from the zone centre by hand -- set_desired_global_transform! on every AssemblyComplete start_config to T∘(its global transform captured before any edit), repeated until every node sits at its target (a parent set after its child moves the child again), plus the staging-circle records -- in steps of the zone radius until zone_blockage reports n_blocked == 0, then one extra step as navigation margin. No restage/translate primitive, no solver. NEVER shown to any agent.",
  "impl_name": "OracleZoneClearNoBase!",
  "impl_code": "function OracleZoneClearNoBase!(env)\n    zs = collect(active_restriction_zones())\n    isempty(zs) && return (; status = :no_zone)\n    zk = [first(p) for p in zs]\n    blk = zone_blockage(env; zone_keys = zk, check_paths = true)\n    blk.n_blocked == 0 && return (; status = :already_clear, moved = 0.0)\n    z = last(first(zs))\n    zc = Vector{Float64}(z.center[1:2]); zr = Float64(z.radius)\n    cs = [Vector{Float64}(b.center[1:2]) for b in values(env.staging_circles)]\n    bc = sum(cs) ./ length(cs)\n    d = bc .- zc; nd = sqrt(sum(abs2, d))\n    u = nd < 1e-9 ? [1.0, 0.0] : d ./ nd\n    tnodes = Any[start_config(sn.node) for sn in env.sched.nodes if sn.node isa AssemblyComplete]\n    function shift!(delta)\n        T = Translation(delta[1], delta[2], 0.0)\n        targets = [(t, T ∘ global_transform(t)) for t in tnodes]\n        for _ in 1:16\n            moved_any = false\n            for (t, g) in targets\n                if maximum(abs.(global_transform(t).translation .- g.translation)) > 1e-9\n                    set_desired_global_transform!(t, g)\n                    moved_any = true\n                end\n            end\n            moved_any || break\n        end\n        for aid in collect(keys(env.staging_circles))\n            b = env.staging_circles[aid]\n            env.staging_circles[aid] = typeof(b)(b.center .+ delta[1:length(b.center)], b.radius)\n        end\n        return nothing\n    end\n    total = 0.0\n    for k in 1:12\n        shift!(u .* zr)\n        total += zr\n        reset_cache_resume!(env.cache, env.sched)\n        blk = zone_blockage(env; zone_keys = zk, check_paths = true)\n        if blk.n_blocked == 0\n            shift!(u .* zr)\n            total += zr\n            reset_cache_resume!(env.cache, env.sched)\n            return (; status = :translated, moved = total, steps = k + 1)\n        end\n    end\n    return (; status = :residual_blocked, moved = total, residual = blk.n_blocked)\nend\n",
  "params": {},
  "calls": [{"primitive": "OracleZoneClearNoBase!", "args": {}}],
  "body_names": ["OracleZoneClearNoBase!"],
  "surface": "sched",
  "reversible": false,
  "wrote": true,
  "refused": false,
  "synthesis_event": true,
  "synthesis_ran": true,
  "synthesis_error": null,
  "tool_minted": true
}
```

- [ ] **Step 3: 어휘 시험을 돌린다**

Run: `julia +lts --project=. test/oracle_nobase_uses_only_a2_vocabulary.jl`
Expected: PASS. 실패하면 광고 밖 이름을 A2 광고 안의 이름으로 바꾼다. 광고에 대응물이 없으면 그 사실 자체를 README 에 적는다(D1 근거).

- [ ] **Step 4: 두 판으로 먼저 돌려 본다**

`results/<날짜>-repair-ablation/g3/run_g3.sh`(stdin 한 줄 = `<tag> <case> <seed>`, tag ∈ tractor·xwing, case ∈ zone·all3):
```bash
#!/usr/bin/env bash
# G3 실현 가능성 오라클(A2 어휘). 무료, 서비스 없음. 격자와 같은 세계(고정 env·사건)로 돈다.
set -u
ROOT=/home/chahj578/Construction_OODlayer; OUT=$(cd "$(dirname "$0")" && pwd); mkdir -p "$OUT/log"
PIN="CARRIER_RESCUE=1 DEMO_ANIM=0 ENERGY_OBJECTIVE=1 RESPEC_DEPRIO_KAPPA=0.25 RESPEC_TRANSLATE_ON_INFEASIBLE=0 RESTAGE_NAV_BUFFER=0 RESTAGE_RING_STEP_FRAC=0.34 RESTAGE_ZONE_MARGIN_FRAC=0.5 SPARE_PRIORITY=1 TEAM_PRIORITY=1 ZONE_CAUSAL_RULE=0 ZONE_CHECK_PATHS=0 ZONE_DOMAIN_GATE=0 ZONE_RESCUE=1"
while read -r tag case seed; do
  case $tag in tractor) model="tractor.mpd" ;; xwing) model="30051-1 - X-wing Fighter - Mini.mpd" ;; *) echo "bad tag $tag"; exit 2 ;; esac
  case $case in zone) ood=none ;; all3) ood=fault_battery ;; *) echo "bad case $case"; exit 2 ;; esac
  log="$OUT/log/${tag}__${case}__s${seed}.log"
  timeout 3600 env $PIN DEMO_MODEL="$model" DEMO_OOD=$ood DEMO_ZONE=1 DEMO_ZONE_SEED="$seed" DEMO_SEED="$seed" \
    DEMO_ROUTER=0 DEMO_POLICY=canonical DEMO_OUT_DIR="$OUT" DEMO_CASE_TAG="g3_${tag}_${case}_s${seed}" \
    DEMO_SYNTH_FIXTURE="$ROOT/tools/fixtures/oracle_zone_clear_nobase.json" REPAIR_ABLATION=all \
    MONITOR_RUN_ID="g3_${tag}_${case}_s${seed}" julia +lts --project="$ROOT" "$ROOT/tools/monitor/render_demo.jl" </dev/null \
    > "$log" 2>&1
  echo "$tag $case s$seed rc=$? $(/usr/bin/grep -ho '^\[score\].*' "$log" | tail -1) | $(/usr/bin/grep -ho '^\[ablation\].*' "$log" | tail -1 | cut -c1-80)" | tee -a "$OUT/drive.log"
done
```
⚠️ `DEMO_OOD=fault_battery` 가 all3 셀의 사건이라는 것은 `campaign.py` 의 case 표(`"all3": ("fault_battery", True)`)에서 왔다. 실행 전 그 표를 다시 본다.
Run: `printf 'tractor zone 1\nxwing zone 1\n' | bash results/<날짜>-repair-ablation/g3/run_g3.sh`
Expected: 두 판 모두 `[ablation] level=all … denied=0`. `[score]` 에서 완주 여부를 읽는다.

- [ ] **Step 5: 오라클 개정은 최대 5회**

미완주면 로그에서 원인을 한 줄로 적는다(예: 씬 본체 표류, 이동 방향이 다른 목표를 존에 넣음, 여유 부족). 그다음 **A2 광고 어휘 안에서만** 고치고 Step 3·4 를 다시 돈다. 개정마다 README 에 원인·변경·결과를 한 줄씩 남긴다. 5회 안에 두 판 완주에 실패하면 멈추고 D1 로 간다.

- [ ] **Step 6: D1 판정**

- 오라클이 동기화 없이 완주하면 → D1 = **노출 안 함**.
- 실패 원인이 "이동 후 씬 본체가 표류한다"로 확인되면 → 공개 래퍼 `resync_scene_to_schedule!(env) = _resync_scene_drift!(env)` 를 `src/respec/zone_facts.jl` 에 더하고 export 한다. 이 래퍼는 **세 팔 모두에** 광고된다(팔 간 상수). 광고를 재생성(Task 5 Step 4)하고 오라클에 호출을 넣어 Step 3·4 를 다시 돈다. 이 변경은 사용자 확인 후에 한다(명세 §11 D1).

- [ ] **Step 7: 120 판 전부(2 모델 × zone·all3 × 30 시드)**

`tally.py`:
```python
#!/usr/bin/env python3
"""G3 집계: 판별 완주·존 해소·ablation 줄 → tally.json (셀·시드별 실현 가능성 표)."""
import glob, json, os, re, sys
sys.path.insert(0, "/home/chahj578/Construction_OODlayer/tools/monitor")
import build_sweep_dataset as B
here = os.path.dirname(os.path.abspath(__file__))
rows = []
for p in sorted(glob.glob(os.path.join(here, "log", "*.log"))):
    m = re.match(r"(tractor|xwing)__(zone|all3)__s(\d+)\.log$", os.path.basename(p))
    if not m:
        continue
    txt = open(p, errors="replace").read()
    r = B.parse_log(txt, "oracle", m[2], int(m[3])) or {"closed": None, "complete": False}
    rows.append({"model": m[1], "case": m[2], "seed": int(m[3]), "complete": bool(r.get("complete")),
                 "closed": r.get("closed"), "n_blocked": r.get("n_blocked"),
                 "zone_place": r.get("zone_place"), "ablation": r.get("ablation")})
json.dump(rows, open(os.path.join(here, "tally.json"), "w"), indent=1)
for key in sorted({(r["model"], r["case"]) for r in rows}):
    rs = [r for r in rows if (r["model"], r["case"]) == key]
    print(key, "complete %d/%d" % (sum(r["complete"] for r in rs), len(rs)),
          "denied>0:", sum(1 for r in rs if (r["ablation"] or {}).get("denied", 0) > 0))
```
Run(W=8 병렬 — CLAUDE.md: 프로세스당 ~2.5GB, W=8 은 9/23 스윕과 같은 폭):
```bash
cd results/<날짜>-repair-ablation/g3
for t in tractor xwing; do for c in zone all3; do for s in $(seq 1 30); do echo "$t $c $s"; done; done; done | \
  xargs -P 8 -L 1 sh -c 'echo "$0 $1 $2" | bash ./run_g3.sh'
python3 tally.py
```
Expected: `tally.json` 120행, `denied>0: 0`. 셀별 완주 수를 README 에 적는다. 이 표가 Task 13 의 "오라클 완주 시드" 조건이다.

- [ ] **Step 8: 커밋**

```bash
git add tools/fixtures/oracle_zone_clear_nobase.json test/oracle_nobase_uses_only_a2_vocabulary.jl results/<날짜>-repair-ablation/g3
git commit -m "G3 실현 가능성 오라클(A2 어휘): <완주 수>/120 판, D1=<판정>

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- tools/fixtures/oracle_zone_clear_nobase.json test/oracle_nobase_uses_only_a2_vocabulary.jl results/<날짜>-repair-ablation/g3
```

---

### Task 12: G4 — 서비스 셋 기동과 파일럿(유료, 팔당 4판)

**Files:**
- Create: `results/<날짜>-repair-ablation/README.md`(설정 줄), `…/svc_<lvl>.log`

- [ ] **Step 1: 세대 확인 — 미커밋 편집이 없어야 한다**

Run: `cd /home/chahj578/Construction_OODlayer && git status --short -- src tools | /usr/bin/grep -v '^??' | wc -l`
Expected: `0`. 0 이 아니면 서비스 세대 게이트가 모든 판을 stale 로 막는다. 원인(남의 편집 포함)을 사용자에게 보고한다.

- [ ] **Step 2: 팔별 서비스 셋을 띄운다(포트 8111/8112/8113)**

```bash
cd /home/chahj578/Construction_OODlayer/src/respec/llm_service
R=/home/chahj578/Construction_OODlayer/results/<날짜>-repair-ablation; mkdir -p $R
for pair in none:8111 translate:8112 all:8113; do lvl=${pair%%:*}; port=${pair##*:}
  REPAIR_ABLATION=$lvl DSPY_MODEL=gpt-5.6-sol DSPY_MODEL_TYPE=responses DSPY_TEMPERATURE=none \
  DSPY_MAX_TOKENS=16000 DSPY_CACHE=0 TOOL_SYNTHESIS=1 SYNTH_MULTI_AGENT=1 \
  SYNTH_RECORD_LOG=$R/ledger_$lvl.jsonl \
  nohup /home/chahj578/Construction_OODlayer/.venv/bin/python -m uvicorn dspy_service:app \
    --host 127.0.0.1 --port $port > $R/svc_$lvl.log 2>&1 &
done
sleep 20
for port in 8111 8112 8113; do curl -s 127.0.0.1:$port/health | python3 -c 'import json,sys; h=json.load(sys.stdin); print(h["repair_ablation"], h["policy"], h.get("cache"), h.get("code_fingerprint"))'; done
```
Expected: 세 줄의 레벨이 `none`/`translate`/`all` 이고, 모델·캐시가 같고, `code_fingerprint` 가 셋 다 같다.

- [ ] **Step 3: 핸드셰이크 음성 대조(무료, 결정 전에 죽는다)**

Run(`all` 서비스에 `none` Julia 를 붙인다):
```bash
cd /home/chahj578/Construction_OODlayer && timeout 600 env DEMO_MODEL=tractor.mpd DEMO_OOD=none DEMO_ZONE=1 \
  DEMO_ZONE_SEED=1 DEMO_SEED=1 DEMO_ROUTER=1 DEMO_ANIM=0 DEMO_CASE_TAG=hs_neg DSPY_URL=http://127.0.0.1:8113 \
  REPAIR_ABLATION=none julia +lts --project=. tools/monitor/render_demo.jl </dev/null 2>&1 | /usr/bin/grep -m1 '\[ablation\] service repair_ablation'
```
Expected: `[ablation] service repair_ablation="all" != julia "none"` 로 죽는다. `svc_all.log` 에 `/decide` 호출이 0건이어야 한다.

- [ ] **Step 4: 파일럿 — 팔마다 tractor zone s1–4**

```bash
cd /home/chahj578/Construction_OODlayer
for pair in none:8111 translate:8112 all:8113; do lvl=${pair%%:*}; port=${pair##*:}
  GRID_OUT=results/<날짜>-repair-ablation/$lvl-tractor DEMO_MODEL=tractor.mpd CAMPAIGN_ID=abl-$lvl-tractor-<날짜> \
  DSPY_URL=http://127.0.0.1:$port REPAIR_ABLATION=$lvl \
  bash tools/monitor/grid/render_grid.sh "router" "zone" "1 2 3 4" 4 > results/<날짜>-repair-ablation/pilot_$lvl.out 2>&1 &
done; wait
```
⚠️ `campaign.py init` 이 `REPAIR_ABLATION` 을 `set_env` 에 넣는지 `campaign.json` 에서 확인한다(Task 8 의 CONFIG_ENV_RESULT). 없으면 run-one 이 상속 변수를 지워 레벨이 사라진다 → 멈춘다.

Expected(전부 참이어야 G5 로 간다):
1. 12판 모두 `[ablation]` 줄이 있고, 레벨이 팔과 같고, `armed=true`, **`denied=0`**.
2. 같은 시드의 `zone_place` 문자열이 세 팔에서 같다.
3. `[run-ctx]` 의 `repair_ablation` 이 팔과 같고, `config_digest` 가 팔마다 다르다.
4. ablation 팔 원장(`ledger_translate/all.jsonl`)의 body 에 차단 이름이 나오면, 그 행은 등록 거절(`reject:ablated_primitive`)로 끝나야 한다.
5. none 팔 4판의 결과가 9/23 sol 스윕의 같은 시드와 크게 다르지 않다(참고용 — 공통 변경 §5 가 들어가 있어 같을 필요는 없다).

`denied>0` 이 나오면 `detail` 의 `denied_by:` 로 호출자를 분류한다. 그 경로를 면제할지 막을지 사용자에게 보고한 뒤에만 진행한다(명세 §12).

- [ ] **Step 5: 파일럿 결과를 README 에 적는다(커밋은 Task 13 과 함께).**

---

### Task 13: G5 — 360판, 검증, 비교

**Files:**
- Create: `results/<날짜>-repair-ablation/compare3.py`, `…/cost_watchdog.sh`(9/23 sol 폴더 것을 상한 $150 으로 복사), `…/README.md`

- [ ] **Step 1: cost watchdog 을 켠다**

`results/2026-09-23-router-sol/cost_watchdog.sh` 를 복사하고 상한을 `150` 으로, 원장 경로를 세 `ledger_<lvl>.jsonl` 의 합으로 고친다. 백그라운드로 띄운다.

- [ ] **Step 2: 본 측정 — 팔 3 × 모델 2 × {zone, all3} × 30 시드**

팔은 **순차**로 돈다. 한 팔 안에서는 두 모델을 동시에, W=8 씩 돈다(= 9/23 sol 스윕과 같은 동시 16판). CLAUDE.md 기준으로 프로세스당 ~2.5GB 라 세 팔을 동시에 돌리면 48판 × 2.5GB 가 된다. 팔 순서는 none → translate → all 이다. 시간대 효과(API 지연)가 한 팔에 몰리는 것은 README 에 적는다.
```bash
cd /home/chahj578/Construction_OODlayer
for pair in none:8111 translate:8112 all:8113; do lvl=${pair%%:*}; port=${pair##*:}
  for m in tractor xwing; do
    model=$([ $m = tractor ] && echo tractor.mpd || echo "30051-1 - X-wing Fighter - Mini.mpd")
    GRID_OUT=results/<날짜>-repair-ablation/$lvl-$m DEMO_MODEL="$model" CAMPAIGN_ID=abl-$lvl-$m-<날짜> \
    DSPY_URL=http://127.0.0.1:$port REPAIR_ABLATION=$lvl \
    bash tools/monitor/grid/render_grid.sh "router" "zone all3" "$(seq -s ' ' 1 30)" 8 \
      > results/<날짜>-repair-ablation/full_${lvl}_$m.out 2>&1 &
  done
  wait        # 🔴 팔 하나가 끝나야 다음 팔
done
```
⚠️ 파일럿(Task 12 Step 4)이 같은 `GRID_OUT` 에 계획 판을 이미 올렸다. `campaign.py init` 은 지문이 같을 때만 계획을 합친다(파일럿 → 전체). 지문이 다르다고 거절되면 파일럿과 본 측정 사이에 코드나 설정이 바뀐 것이다 → 멈춘다.
Expected: 각 `full_*.out` 의 `campaign.py summarize` 가 계획 판 전부 채점, exit 0.

- [ ] **Step 3: 재시도 사슬 검증**

9/23 README 의 방식 그대로 각 격자에 `verify_retry_chain.py --require-decisions 1` 를 돌린다.
Expected: 6 격자 전부 exit 0.

- [ ] **Step 4: 비교 스크립트**

`compare3.py`:
```python
#!/usr/bin/env python3
"""none·A1·A2 같은 시드 비교 + 오라클 조건부 A2 + body 기전 분류 + 비용."""
import json, math, os, re
from collections import Counter
R = os.path.dirname(os.path.abspath(__file__))
ARMS = ("none", "translate", "all")
DENIED_ALL = ("translate_whole_build!", "_apply_uniform_translation!", "_find_min_translation",
              "_find_clear_translation", "_minimum_clear_translation", "zone_relocatable",
              "core_zone_for_severity", "zone_diagnosis", "zone_diagnoses",
              "find_clear_staging_center", "restage_assembly!", "restage_all_blocked!")

def runs(arm, m):
    d = json.load(open(os.path.join(R, "%s-%s" % (arm, m), "sweep.json")))
    return {(r["case"], r["seed"]): r for r in d["runs"] if r["lane"] == "router"}

def mcnemar(b, c):
    """정확 이항(양측). b = none 만 완주, c = 비교 팔만 완주."""
    n = b + c
    if n == 0:
        return 1.0
    k = min(b, c)
    p = sum(math.comb(n, i) for i in range(0, k + 1)) / 2 ** n
    return min(1.0, 2 * p)

def mechanism(code):
    if not code:
        return "empty"
    if any(n + "(" in code for n in DENIED_ALL):
        return "calls_base"
    if "set_desired_global_transform!" in code and "staging_circles" in code:
        return "hand_translate"
    if "set_desired_global_transform!" in code:
        return "hand_geometry"
    if re.search(r"rem_vertex!|add_edge!|rem_edge!", code):
        return "graph_surgery"
    return "other"

# G3 tally 의 키는 (tractor|xwing, zone|all3, seed) — 격자 이름과 같다(run_g3.sh 가 같은 태그를 쓴다)
orc = {(r["model"], r["case"], r["seed"]): bool(r["complete"])
       for r in json.load(open(os.path.join(R, "g3", "tally.json")))}
rep = {}
for m in ("tractor", "xwing"):
    S = {a: runs(a, m) for a in ARMS}
    for case in ("zone", "all3"):
        keys = sorted(k for k in S["none"] if k[0] == case)
        row = {"n": len(keys)}
        for a in ARMS:
            row[a + "_complete"] = sum(bool(S[a][k]["complete"]) for k in keys if k in S[a])
            row[a + "_denied_runs"] = sum(1 for k in keys if k in S[a] and ((S[a][k].get("ablation") or {}).get("denied", 0) > 0))
            row[a + "_ladder_skipped"] = sum((S[a][k].get("ablation") or {}).get("ladder_zone_skipped", 0) for k in keys if k in S[a])
            row[a + "_ladder_fired"] = sum((S[a][k].get("ablation") or {}).get("ladder_zone_fired", 0) for k in keys if k in S[a])
        for a in ("translate", "all"):
            b = sum(1 for k in keys if S["none"][k]["complete"] and not S[a][k]["complete"])
            c = sum(1 for k in keys if S[a][k]["complete"] and not S["none"][k]["complete"])
            row["none_vs_%s" % a] = {"none_only": b, "%s_only" % a: c, "p_mcnemar": mcnemar(b, c)}
            row["zone_place_mismatch_%s" % a] = sum(1 for k in keys if S[a][k].get("zone_place") != S["none"][k].get("zone_place"))
        feas = [k for k in keys if orc.get((m, case, k[1]))]
        row["oracle_feasible_seeds"] = len(feas)
        row["all_complete_on_feasible"] = sum(bool(S["all"][k]["complete"]) for k in feas)
        rep["%s|%s" % (m, case)] = row
mech = {}
for a in ARMS:
    p = os.path.join(R, "ledger_%s.jsonl" % a)
    rows = [json.loads(l) for l in open(p)] if os.path.exists(p) else []
    mech[a] = dict(Counter(mechanism(r.get("impl_code") or "") for r in rows if r.get("row_type") != "rewrite"))
rep["mechanism"] = mech
print(json.dumps(rep, indent=1, ensure_ascii=False))
json.dump(rep, open(os.path.join(R, "compare3.json"), "w"), indent=1, ensure_ascii=False)
```
⚠️ `oracle_feasible_seeds` 가 한 셀이라도 0 이면 G3 이 그 셀을 실제로 0 판 완주했는지(`tally.py` 출력)부터 확인한다. tally 는 0 이 아닌데 여기만 0 이면 키가 어긋난 것이다 → 멈춘다.

Run: `python3 results/<날짜>-repair-ablation/compare3.py`
Expected: 4 셀 × 3 팔 표, `zone_place_mismatch_* == 0`, `*_denied_runs == 0`. 어긋나는 셀은 README 에 그대로 적는다(버리지 않는다).

- [ ] **Step 5: 비용**

9/23 의 `cost.py` 를 팔별 원장 셋에 돌려 단계별 비용을 README 에 적는다.

- [ ] **Step 6: README — 명세 §9 의 판정 표로 결론을 쓴다**

README 에 다음을 적는다.
- 설정: 서비스 기동 줄 셋, code_fingerprint, campaign·config_digest.
- G2·G3·G4 요약.
- `compare3.json` 표와 기전 분류, 비용.
- **허용되는 주장 한 줄**(명세 §9 표의 어느 행인지).
- 범위 문장: "존 복구 base 제거; CARRIER_RESCUE·스냅·reform 은 세 팔 공통".
- 오늘(9/23 오전) 117판 대비 새 none 의 차이를 **부수 보고**로 적는다(공통 변경 §5 + 코드 정리의 합산).

- [ ] **Step 7: 서비스 셋을 끈다**

Run: `for port in 8111 8112 8113; do pid=$(ss -ltnp | /usr/bin/grep ":$port " | sed -E 's/.*pid=([0-9]+).*/\1/'); [ -n "$pid" ] && kill $pid; done`
(`pkill -f` 는 자기 셸을 죽일 수 있어 쓰지 않는다.)

- [ ] **Step 8: 커밋**

```bash
git add results/<날짜>-repair-ablation
git commit -m "존 복구 base ablation 360판: none <a>/120 · A1 <b>/120 · A2 <c>/120 (오라클 가능 시드 조건 <d>)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- results/<날짜>-repair-ablation
```

---

## 자체 점검 기록

- **명세 대응**:
  - §0 목적·범위 → Task 13 README.
  - §2 팔 → Task 12·13.
  - §3 분류 → Global Constraints, Task 1 시험.
  - §4 zone_facts → Task 3.
  - §5 공통 변경 → Task 7. 팔 고유 문장 삭제는 Task 5.
  - §6 네 층 → 광고 Task 5, 등록 Task 4, 실행 Task 2·8, 사다리 Task 8. 핸드셰이크는 Task 6·8.
  - §7 동등성 → Task 12 Step 4, Task 13 `zone_place_mismatch`.
  - §8 오라클·음성 대조 → Task 10·11.
  - §9 판정 → Task 13.
  - §10 게이트 → Task 0·10·11·12·13.
  - §11 D1 → Task 11 Step 6. D2 는 Task 1 의 목록(A1 에서 zone_diagnosis 차단)으로 고정.
  - §12 위험 → Task 12 Step 4 의 denied 분류.
- **알려진 불확실성**(실행자가 첫 단계에서 확인):
  - `f` 지역 이름(Task 4)
  - `MacroRequest` 필수 필드(Task 7)
  - 픽스처가 등록 검사를 거치는지(Task 10)
  - all3 셀의 사건 env(Task 11 — `campaign.py` case 표)
  - 오라클·음성 대조 드라이버의 고정 env 가 캠페인 `set_env` 와 같은지(Task 10·11)

  모두 해당 Step 에 확인 방법과 멈춤 조건을 적었다.
