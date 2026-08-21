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
#
# 실측 근거(2026-08-21): 내부 생산자는 `src/navigator/baselines.jl:173·192·201`(ForbidAgent,
# DeprioritizeAgent, ForbidZone) 과 `src/respec/reassign.jl:382`(ForbidAgent) 다.
# 씬을 안 만든다 — id_resolver 를 스텁으로 주면 파서는 씬 없이 돈다(빠른 게이트).
# =============================================================================
using ConstructionBots, Test
import Random
import InteractiveUtils
import JSON3
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))

const EMITTABLE = Set(["ReplaceAgent", "SwapBattery", "LinearConstraint", "Disjunction"])
const REMOVED   = Set(["ForbidZone", "ReformTeam", "ForbidAgent", "ForbidWindow",
                       "DeprioritizeAgent", "RelocateBuild"])

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
    EMITTABLE, REMOVED,
    Set(["TranslateBuild", "Sabotage", ""]))))

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
    for k in sort!(collect(REMOVED))
        @test_throws Exception _parse(k)
    end
    @test_throws Exception _parse("Sabotage")
end

@testset "🔴 문법 안의 오류도 죽는다 (조용한 폴백 금지)" begin
    bad_rel = Dict("kind" => "LinearConstraint", "rel" => "lt", "rhs" => 1.0,
                   "terms" => [Dict("coeff" => 1.0, "var" => Dict("kind" => "tF", "node" => "N1"))])
    @test_throws Exception CB._parse_proposal(
        JSON3.read(JSON3.write(Dict("constraints" => [bad_rel]))), "s"; id_resolver = _resolver)
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

@testset "🔴 Julia 파서와 Python schema.py 가 같은 집합을 선언한다" begin
    py = joinpath(pkgdir(CB), ".venv", "bin", "python")
    isfile(py) || error("두 표면을 대조하려면 레포 루트의 .venv 파이썬이 필요하다: $(py)")
    code = """
import sys, json, typing
sys.path.insert(0, r"$(joinpath(pkgdir(CB), "src", "respec", "llm_service"))")
import schema
union = typing.get_args(typing.get_args(schema.ConstraintSpec)[0])
print(json.dumps({
  "union": sorted(c.model_fields["kind"].default for c in union),
  "tool_enum": sorted(schema.TOOL_SCHEMA["input_schema"]["properties"]["constraints"]
                            ["items"]["properties"]["kind"]["enum"]),
}))
"""
    out = read(`$(py) -c $(code)`, String)
    got = JSON3.read(out)
    @test Set(String.(got["union"])) == EMITTABLE
    @test Set(String.(got["tool_enum"])) == EMITTABLE
    @info "schema.py union = $(got["union"])"
end

@testset "🔴 타입과 컴파일러는 살아 있다 (엔진이 쓴다)" begin
    # 행동공간에서 뺐다고 타입을 지우면 baselines.jl 과 reassign.jl 이 깨진다.
    for T in (:ForbidAgent, :ForbidWindow, :ForbidZone, :ReformTeam, :DeprioritizeAgent,
              :RelocateBuild)
        @test isdefined(CB, T)
    end
    @test hasmethod(CB.compile_constraint!, Tuple{Any,Any,Any,Any,Any,CB.ForbidAgent})
    @test hasmethod(CB.compile_constraint!, Tuple{Any,Any,Any,Any,Any,CB.ForbidWindow})
    @test hasmethod(CB.compile_constraint!, Tuple{Any,Any,Any,Any,Any,CB.DeprioritizeAgent})
    @test hasmethod(CB.compile_constraint!, Tuple{Any,Any,Any,Any,Any,CB.RelocateBuild})
    @test hasmethod(CB.compile_constraint!, Tuple{Any,Any,Any,Any,Any,CB.LinearConstraint})
    @test hasmethod(CB.compile_constraint!, Tuple{Any,Any,Any,Any,Any,CB.Disjunction})
    for T in (CB.ForbidAgent, CB.ForbidWindow, CB.ForbidZone, CB.ReformTeam,
              CB.DeprioritizeAgent, CB.RelocateBuild, CB.LinearConstraint, CB.Disjunction)
        @test hasmethod(CB.referenced_ids, Tuple{T})
    end
end

@testset "🔴 엔진 내부 생산자가 여전히 뺀 타입을 만든다 (baselines.jl:173·192·201)" begin
    ft = CB.FaultTruth(_RID, [0.0, 0.0, 0.0], 0.0)
    p = CB.oracle_respec(ft)                                   # baselines.jl:173
    @test p isa CB.RespecProposal
    @test p.constraints[1] isa CB.ForbidAgent

    kinds_f = Set{Symbol}()
    kinds_b = Set{Symbol}()
    for k in 1:40                                              # baselines.jl:192 · 201
        push!(kinds_f, nameof(typeof(CB.random_macro_respec(ft;
                    rng = Random.MersenneTwister(k)).constraints[1])))
        push!(kinds_b, nameof(typeof(CB.random_macro_respec(CB.BatteryTruth(_RID, 0.05, 0.0);
                    rng = Random.MersenneTwister(k)).constraints[1])))
    end
    @test :ForbidAgent in kinds_f
    @test :DeprioritizeAgent in kinds_f
    @test :ForbidAgent in kinds_b
    @test :DeprioritizeAgent in kinds_b

    zt = CB.ZoneTruth(:z, [0.0, 0.0, 0.0], 1.0, CB.AssemblyID(1))
    zk = Set{Symbol}()
    for k in 1:40
        r = CB.random_macro_respec(zt; rng = Random.MersenneTwister(k))
        r === nothing || push!(zk, nameof(typeof(r.constraints[1])))
    end
    @test :ForbidZone in zk
end
