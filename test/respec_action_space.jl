# =============================================================================
# test/respec_action_space.jl — Task C2 게이트: 행동공간 축소 (D-9)
#   julia +lts --project=. test/respec_action_space.jl
#   🔴 runtests.jl 에 싣지 않는다.
#
# 행동공간은 **LLM 이 emit 할 수 있는 것**이다. 타입이 존재하는 것과는 다르다.
# 이 시험은 네 가지를 잰다:
#   (1) 배타성 — emit 가능한 kind 집합이 기대집합과 **정확히 같다**(포함이 아니라 등식).
#       🔴 "기대한 5종이 다 있다" 만 보면 6종이어도 초록이다. 그 실패 모양을 컨트롤러가 잡았다.
#   (2) 두 표면의 일치 — Julia 파서(`llm_bridge.jl`) 와 Python 스키마(`schema.py`) 가 같은 집합인가.
#       한쪽에만 있는 kind 는 조용한 갈라짐이다.
#   (3) 뺀 kind 는 **죽는다**(조용히 무시하지 않는다).
#   (4) 타입·컴파일러·엔진 내부 생산자는 **살아 있다** — 지우면 LLM 없이도 명목 레인이 깨진다.
#   (5) 🔴 2026-08-24 (spec §5.4, Task 5): `DeprioritizeAgent` 만은 (4) 에서 **빠진다** — 그것은
#       어휘에서만이 아니라 **코드베이스에서 통째로 삭제됐다**. 그래서 이 파일은 두 종류의 "뺀
#       kind" 를 구분한다: `REMOVED`(타입은 산다) vs `DELETED`(타입도 죽었다).
#
# 실측 근거(2026-08-21): 내부 생산자는 `src/navigator/baselines.jl`(ForbidAgent, ForbidZone)
# 과 `src/respec/reassign.jl:382`(ForbidAgent) 다.
# 씬을 안 만든다 — id_resolver 를 스텁으로 주면 파서는 씬 없이 돈다(빠른 게이트).
# =============================================================================
using ConstructionBots, Test
import Random
import InteractiveUtils
import JSON3
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))

# 🔴 **개수를 명시적으로 박아 둔다 (컨트롤러 판정 2026-08-21).**
#   C2 끝 = 4종 (ReplaceAgent · SwapBattery · LinearConstraint · Disjunction).
#   **C3 끝 = 5종** (그 넷 + `TranslateBuild`) ← 지금이 그 시점이다 (Task C3 집행됨).
#   `.claude/CLAUDE.md` 의 "emit 가능 5종" 은 **C3 끝** 시점을 말한다.
#   산수: 출발점 8종 → **8 − 6 + 3 = 5**
#     −6 : ForbidZone · ReformTeam · ForbidAgent · ForbidWindow · DeprioritizeAgent · RelocateBuild
#          (그중 DeprioritizeAgent 는 2026-08-24 Task 5 에서 타입·클래스까지 삭제 → `DELETED`)
#     +3 : LinearConstraint · Disjunction (C2, L2-a) + TranslateBuild (C3, L2-b)
#   아래 `@test length(EMITTABLE) == 5` 는 다음에 이 수를 바꾸는 태스크가 그것을 **의도적으로**
#   고치게 만든다 — 느슨한 단언을 물려받으면 6종이 되어도 초록이 된다.
const EMITTABLE = Set(["ReplaceAgent", "SwapBattery", "LinearConstraint", "Disjunction",
                       "TranslateBuild"])
# 🔴 `REMOVED` = emit 표면에서만 빠진 kind — **Julia 타입과 schema.py 클래스는 살아 있다.**
const REMOVED   = Set(["ForbidZone", "ReformTeam", "ForbidAgent", "ForbidWindow",
                       "RelocateBuild"])
# 🔴 `DELETED` = 2026-08-24 (spec §5.4, Task 5) 에 **코드베이스에서 통째로 지운** kind.
#   REMOVED 와 달리 타입도 클래스도 없어야 한다. 파서는 여전히 죽어야 하고(아래 testset),
#   `isdefined` 와 schema 파생 우주가 **부재**를 단언한다.
const DELETED   = Set(["DeprioritizeAgent"])

# 스텁 id_resolver — 씬 없이 파서를 돌린다. 모르는 문자열은 죽는다(조용한 폴백 금지).
const _RID = CB.RobotID(1)
_resolver(s::AbstractString) = s == "GHOST" ? error("unknown id $s") : _RID

const _LC = Dict("kind" => "LinearConstraint",
                 "terms" => [Dict("coeff" => 1.0,
                                  "var" => Dict("kind" => "tF", "node" => "N1"))],
                 "rel" => "le", "rhs" => 42.0)

function _stub_json(kind::AbstractString)
    c = if kind == "LinearConstraint"
        _LC
    elseif kind == "Disjunction"
        Dict("kind" => "Disjunction", "left" => _LC,
             "right" => Dict("kind" => "LinearConstraint",
                             "terms" => [Dict("coeff" => 1.0,
                                              "var" => Dict("kind" => "t0", "node" => "N1"))],
                             "rel" => "ge", "rhs" => 99.0))
    elseif kind in ("ReplaceAgent", "ForbidAgent", "DeprioritizeAgent")
        Dict("kind" => kind, "agent" => "R1", "after" => 0.0)
    elseif kind == "SwapBattery"
        Dict("kind" => kind, "agent" => "R1")
    elseif kind == "ForbidWindow"
        Dict("kind" => kind, "node" => "N1", "t_lo" => 1.0, "t_hi" => 2.0)
    elseif kind == "ForbidZone"
        Dict("kind" => kind, "assembly" => "A1", "zone" => "z")
    elseif kind in ("RelocateBuild", "ReformTeam")
        Dict("kind" => kind, "zone" => "z")
    elseif kind == "TranslateBuild"
        Dict("kind" => kind, "dx" => 1.0, "dy" => 2.0)
    else
        Dict("kind" => kind)
    end
    return JSON3.read(JSON3.write(Dict("constraints" => [c], "rationale" => "stub")))
end

_parse(kind) = CB._parse_proposal(_stub_json(kind), "stub"; id_resolver = _resolver)

# 검사 우주 = spec_dsl 의 모든 구상 타입 이름 ∪ 뺀 이름들 ∪ 아직 없는/가짜 이름.
# 🔴 파생 우주라서 나중에 새 ConstraintSpec 타입이 생기면 **자동으로** 이 시험에 들어온다.
const UNIVERSE = sort!(collect(union(
    Set(string(nameof(T)) for T in InteractiveUtils.subtypes(CB.ConstraintSpec)),
    EMITTABLE, REMOVED, DELETED,
    Set(["TranslateBuild", "Sabotage", ""]))))   # TranslateBuild 는 이제 subtypes 로도 들어온다

@testset "🔴 파서가 받는 kind 집합이 기대집합과 **정확히 같다** (포함이 아니라 등식)" begin
    accepted = Set{String}()
    for k in UNIVERSE
        ok = try
            _parse(k) isa CB.RespecProposal
        catch
            false
        end
        ok && push!(accepted, k)
    end
    @test accepted == EMITTABLE
    # 🔴 C3 끝 = 5종. 다음에 이 수를 바꾸는 태스크는 이 줄부터 빨개진다(의도적 변경 강제).
    @test length(EMITTABLE) == 5
    @test length(accepted) == 5
    @test length(CB.EMITTABLE_KINDS) == 5
    @info "파서가 받는 kind = $(sort!(collect(accepted)))  (우주 $(length(UNIVERSE))종 중)"

    # 파서가 선언한 상수와 실제 동작이 같은가 (상수만 고치고 스위치를 안 고치는 실패를 막는다)
    @test Set(CB.EMITTABLE_KINDS) == EMITTABLE
end

@testset "남긴 kind 는 전부 왕복한다" begin
    for k in sort!(collect(EMITTABLE))
        p = _parse(k)
        @test p isa CB.RespecProposal
        @test length(p.constraints) == 1
        @test string(nameof(typeof(p.constraints[1]))) == k
    end
    # 값까지 왕복하는가
    lc = _parse("LinearConstraint").constraints[1]
    @test lc.rel === :le && lc.rhs == 42.0 && length(lc.terms) == 1
    @test lc.terms[1][1] == 1.0 && lc.terms[1][2].kind === :tF
    dj = _parse("Disjunction").constraints[1]
    @test dj.left.rel === :le && dj.right.rel === :ge && dj.right.rhs == 99.0
end

@testset "🔴 뺀 kind 를 내면 **죽는다** (조용히 무시하지 않는다)" begin
    for k in sort!(collect(union(REMOVED, DELETED)))
        @test_throws Exception _parse(k)
    end
    @test_throws Exception _parse("Sabotage")
end

@testset "🔴 문법 안의 오류도 죽는다 (조용한 폴백 금지)" begin
    bad_rel = Dict("kind" => "LinearConstraint", "rel" => "lt", "rhs" => 1.0,
                   "terms" => [Dict("coeff" => 1.0, "var" => Dict("kind" => "tF", "node" => "N1"))])
    @test_throws Exception CB._parse_proposal(
        JSON3.read(JSON3.write(Dict("constraints" => [bad_rel]))), "s"; id_resolver = _resolver)
    # 🔴 :xa 는 타입에는 있지만 **emit 불가**다 — 파서가 죽인다(조용히 무시하지 않는다)
    xa_var = Dict("kind" => "LinearConstraint", "rel" => "le", "rhs" => 1.0,
                  "terms" => [Dict("coeff" => 1.0,
                                   "var" => Dict("kind" => "xa", "node" => "N1", "node2" => "N2"))])
    @test_throws Exception CB._parse_proposal(
        JSON3.read(JSON3.write(Dict("constraints" => [xa_var]))), "s"; id_resolver = _resolver)
    # t0/tF 에 node2 를 실어 보내도 죽는다
    n2_var = Dict("kind" => "LinearConstraint", "rel" => "le", "rhs" => 1.0,
                  "terms" => [Dict("coeff" => 1.0,
                                   "var" => Dict("kind" => "tF", "node" => "N1", "node2" => "N2"))])
    @test_throws Exception CB._parse_proposal(
        JSON3.read(JSON3.write(Dict("constraints" => [n2_var]))), "s"; id_resolver = _resolver)
    bad_var = Dict("kind" => "LinearConstraint", "rel" => "le", "rhs" => 1.0,
                   "terms" => [Dict("coeff" => 1.0, "var" => Dict("kind" => "zz", "node" => "N1"))])
    @test_throws Exception CB._parse_proposal(
        JSON3.read(JSON3.write(Dict("constraints" => [bad_var]))), "s"; id_resolver = _resolver)
    empty_terms = Dict("kind" => "LinearConstraint", "rel" => "le", "rhs" => 1.0, "terms" => [])
    @test_throws Exception CB._parse_proposal(
        JSON3.read(JSON3.write(Dict("constraints" => [empty_terms]))), "s"; id_resolver = _resolver)
    ghost = Dict("kind" => "LinearConstraint", "rel" => "le", "rhs" => 1.0,
                 "terms" => [Dict("coeff" => 1.0, "var" => Dict("kind" => "tF", "node" => "GHOST"))])
    @test_throws Exception CB._parse_proposal(
        JSON3.read(JSON3.write(Dict("constraints" => [ghost]))), "s"; id_resolver = _resolver)
end

# 🔴 emit 표면은 **셋**이다 (컨트롤러 판정 2026-08-21, Ruling 1):
#   (1) `llm_bridge.jl` 의 파서 스위치 + `EMITTABLE_KINDS`
#   (2) `schema.py` 의 discriminated union + `TOOL_SCHEMA` enum   ← 모델이 물리적으로 못 벗어나는 벽
#   (3) `propose.py` 의 SYSTEM 프롬프트                            ← 모델이 **뭘 고르라고 듣는지**
# 셋 중 하나만 낡으면 모델은 낼 수 없는 팔을 고르라고 지시받는다. 이 레포는 같은 모양
# ("한 계약의 사본을 든 두 번째 표면")에 이미 세 번 데였다 — 이게 네 번째가 되면 안 된다.
# 아래는 **집합 등식**이다(포함이 아니다). 프롬프트는 선언 상수 + 산문 두 겹으로 훑는다.
@testset "🔴 세 emit 표면(파서 · schema.py · propose.py 프롬프트)이 같은 집합이다" begin
    py = joinpath(pkgdir(CB), ".venv", "bin", "python")
    isfile(py) || error("세 표면을 대조하려면 레포 루트의 .venv 파이썬이 필요하다: $(py)")
    # 🔴 검사 우주를 **`schema.py` 의 BaseModel 들에서 파생**시킨다 (수정 라운드 2).
    #    이전 판은 `ADVERTISED_KINDS ∪ RETIRED_KINDS` 를 썼는데, 둘 다 **검사 대상 파일 안에서**
    #    선언된다 — 두 튜플 어디에도 없는 kind 가 산문에 나타나면 안 보인다. 줄리아 쪽은 이미
    #    `subtypes(CB.ConstraintSpec)` 로 파생 우주를 쓴다. 파이썬도 같은 규율로 맞춘다.
    code = """
import sys, json, typing, inspect, pydantic
sys.path.insert(0, r"$(joinpath(pkgdir(CB), "src", "respec", "llm_service"))")
import schema, propose
union = typing.get_args(typing.get_args(schema.ConstraintSpec)[0])

def _kind_default(c):
    f = c.model_fields.get("kind")
    if f is None:
        return None
    d = f.default
    return d if isinstance(d, str) else None

# 파생 우주: schema.py 가 **정의한** 모든 BaseModel 의 kind 리터럴 (은퇴한 여섯 클래스 포함)
universe = sorted({k for _, c in inspect.getmembers(schema, inspect.isclass)
                   if issubclass(c, pydantic.BaseModel)
                   for k in [_kind_default(c)] if k})

prompt = propose._build_prompt(
    "stub event", ["N1", "N2"],
    agents=[{"id": "RobotID(1)", "label": "R1"}],
    nodes=[{"id": "NodeA", "label": "final assembly"}],
    zones=[{"key": "z", "covers": [], "covers_root": False, "center": [0, 0], "radius": 1.0}])
print(json.dumps({
  "union": sorted(c.model_fields["kind"].default for c in union),
  "tool_enum": sorted(schema.TOOL_SCHEMA["input_schema"]["properties"]["constraints"]
                            ["items"]["properties"]["kind"]["enum"]),
  "advertised": sorted(propose.ADVERTISED_KINDS),
  "retired": sorted(propose.RETIRED_KINDS),
  "universe": universe,
  "in_prose": sorted(k for k in universe if k in prompt),
  "var_literal": sorted(typing.get_args(schema.VarRef.model_fields["kind"].annotation)),
  "var_tool_enum": sorted(schema._VARREF_SCHEMA["properties"]["kind"]["enum"]),
  "var_advertised": sorted(propose.ADVERTISED_VAR_KINDS),
  "var_in_prose": sorted(k for k in ("t0", "tF", "xa") if '\"' + k + '\"' in prompt),
  "prompt_len": len(prompt),
}))
"""
    out = read(`$(py) -c $(code)`, String)
    got = JSON3.read(out)

    # (2) schema.py 의 두 표면
    @test Set(String.(got["union"])) == EMITTABLE
    @test Set(String.(got["tool_enum"])) == EMITTABLE
    # (3) propose.py 의 선언 상수
    @test Set(String.(got["advertised"])) == EMITTABLE
    # (3') 🔴 프롬프트 **산문** 자체 — 선언만 고치고 지시문을 안 고치는 실패를 막는다.
    #      산문에 나타나는 kind 이름이 정확히 emittable 넷이어야 한다.
    #      우주는 schema.py 의 BaseModel 들에서 파생된다(두 튜플이 아니라).
    @test Set(String.(got["universe"])) ⊇ union(EMITTABLE, REMOVED)   # 파생 우주가 실제로 넓다
    # 🔴 2026-08-24 (Task 5): DELETED 는 schema.py 에 **클래스조차 없어야 한다** — 파생 우주에서
    #    부재를 단언한다. (Task 5 전에는 이 줄이 빨갛다: DeprioritizeAgent 클래스가 있었다.)
    @test isempty(intersect(Set(String.(got["universe"])), DELETED))
    @test Set(String.(got["in_prose"])) == EMITTABLE

    # 🔴 **결정변수 종류**도 네 표면이 같아야 한다 (t0/tF; :xa 는 emit 대상이 아니다)
    varkinds = Set(["t0", "tF"])
    @test Set(String.(got["var_literal"])) == varkinds
    @test Set(String.(got["var_tool_enum"])) == varkinds
    @test Set(String.(got["var_advertised"])) == varkinds
    @test Set(String.(got["var_in_prose"])) == varkinds
    @test Set(String.(CB.EMITTABLE_VARREF_KINDS)) == varkinds
    # 은퇴 목록과 emittable 은 서로소여야 한다(같은 이름이 양쪽에 있으면 선언이 자가당착)
    @test isempty(intersect(Set(String.(got["retired"])), EMITTABLE))
    @test got["prompt_len"] > 500          # 비퇴화: 프롬프트가 실제로 만들어졌다
    @info "파생 우주=$(got["universe"])\n  schema union=$(got["union"])\n  " *
          "propose.ADVERTISED_KINDS=$(got["advertised"])\n  산문 kind=$(got["in_prose"])\n  " *
          "변수종류 literal/tool/advertised/산문=$(got["var_literal"])/$(got["var_tool_enum"])/" *
          "$(got["var_advertised"])/$(got["var_in_prose"]) (prompt_len=$(got["prompt_len"]))"
end

@testset "🔴 타입과 컴파일러는 살아 있다 (엔진이 쓴다)" begin
    # 행동공간에서 뺐다고 타입을 지우면 baselines.jl 과 reassign.jl 이 깨진다.
    for T in (:ForbidAgent, :ForbidWindow, :ForbidZone, :ReformTeam, :RelocateBuild)
        @test isdefined(CB, T)
    end
    @test hasmethod(CB.compile_constraint!, Tuple{Any,Any,Any,Any,Any,CB.ForbidAgent})
    @test hasmethod(CB.compile_constraint!, Tuple{Any,Any,Any,Any,Any,CB.ForbidWindow})
    @test hasmethod(CB.compile_constraint!, Tuple{Any,Any,Any,Any,Any,CB.RelocateBuild})
    @test hasmethod(CB.compile_constraint!, Tuple{Any,Any,Any,Any,Any,CB.LinearConstraint})
    @test hasmethod(CB.compile_constraint!, Tuple{Any,Any,Any,Any,Any,CB.Disjunction})
    # C3: 새 emittable kind 도 닫힌 합집합 계약을 지킨다(no-op 메서드 + referenced_ids)
    @test hasmethod(CB.compile_constraint!, Tuple{Any,Any,Any,Any,Any,CB.TranslateBuild})
    @test hasmethod(CB.referenced_ids, Tuple{CB.TranslateBuild})
    for T in (CB.ForbidAgent, CB.ForbidWindow, CB.ForbidZone, CB.ReformTeam,
              CB.RelocateBuild, CB.LinearConstraint, CB.Disjunction)
        @test hasmethod(CB.referenced_ids, Tuple{T})
    end
end

@testset "🔴 엔진 내부 생산자가 여전히 뺀 타입을 만든다 (baselines.jl oracle_respec/random_macro_respec)" begin
    ft = CB.FaultTruth(_RID, [0.0, 0.0, 0.0], 0.0)
    p = CB.oracle_respec(ft)                                   # baselines.jl:173
    @test p isa CB.RespecProposal
    @test p.constraints[1] isa CB.ForbidAgent

    kinds_f = Set{Symbol}()
    kinds_b = Set{Symbol}()
    for k in 1:40                                              # baselines.jl random_macro_respec
        push!(kinds_f, nameof(typeof(CB.random_macro_respec(ft;
                    rng = Random.MersenneTwister(k)).constraints[1])))
        push!(kinds_b, nameof(typeof(CB.random_macro_respec(CB.BatteryTruth(_RID, 0.05, 0.0);
                    rng = Random.MersenneTwister(k)).constraints[1])))
    end
    @test :ForbidAgent in kinds_f
    @test :ReplaceAgent in kinds_f
    @test :ForbidAgent in kinds_b
    @test :ReplaceAgent in kinds_b
    # 🔴 2026-08-24 (Task 5): B5 후보에서 DeprioritizeAgent 를 뺐다 — 두 메뉴 어디에도 없어야 한다.
    @test !(:DeprioritizeAgent in kinds_f)
    @test !(:DeprioritizeAgent in kinds_b)
    # 후보 메뉴가 **정확히** 둘이다(느슨한 `in` 만 두면 셋째가 다시 들어와도 초록이다).
    @test kinds_f == Set([:ReplaceAgent, :ForbidAgent])
    @test kinds_b == Set([:ReplaceAgent, :ForbidAgent])

    zt = CB.ZoneTruth(:z, [0.0, 0.0, 0.0], 1.0, CB.AssemblyID(1))
    zk = Set{Symbol}()
    for k in 1:40
        r = CB.random_macro_respec(zt; rng = Random.MersenneTwister(k))
        r === nothing || push!(zk, nameof(typeof(r.constraints[1])))
    end
    @test :ForbidZone in zk
end

# =============================================================================
@testset "🔴 DeprioritizeAgent 는 코드베이스에서 사라졌다 (2026-08-24, spec §5.4, Task 5)" begin
    # (1) Julia 쪽: 타입도, 전용 게이트도, dispatch 판정자도 없다.
    @test !isdefined(CB, :DeprioritizeAgent)
    @test !isdefined(CB, :verify_deprioritize)
    @test !isdefined(CB, :_is_deprioritize)
    # (2) ConstraintSpec 의 구상 타입 목록에도 그 이름이 없다(파생 검사 — 이름 문자열로만 조회).
    @test !(:DeprioritizeAgent in Set(nameof(T) for T in InteractiveUtils.subtypes(CB.ConstraintSpec)))
    # (3) 소프트 비용편향 **기전**은 남아 있다 — 없어진 것은 그것을 부르는 DSL 문법뿐이다.
    #     (이 줄이 빨개지면 Task 5 가 기전까지 지웠다는 뜻이고, state_globals 의
    #      `:AGENT_COST_BIAS` 항목이 가리킬 곳을 잃는다.)
    @test isdefined(CB, :deprioritize_agent!)
    @test isdefined(CB, :AGENT_COST_BIAS)
    # (4) 파서는 그 이름을 조용히 무시하지 않고 **죽는다**(위 REMOVED 루프와 같은 계약).
    @test_throws Exception _parse("DeprioritizeAgent")
end
