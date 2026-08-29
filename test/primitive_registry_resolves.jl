# =============================================================================
# `primitive_registry.json` — T2(tool 합성)의 원시 연산 알파벳이 **실재하는 이름만** 담고
# 있는지 못박는다. (2026-08-29, Plan B / B0)
#
# 왜 이 파일이 필요한가
# ----------------------
# 이 레지스트리의 유일한 소비자는 아직 안 지어졌다(T2 = Plan B 의 B3). 그래서 이 파일이 없으면
# 레지스트리는 **아무도 안 읽는 JSON** 이고, 오타든 이름 변경이든 조용히 썩는다. 그리고 썩은
# 채로 B3 에 도착하면 증상이 "합성기가 이상한 tool 을 만든다"로 나타나 원인 추적이 몇 시간
# 걸린다 — 이 레포가 이미 겪은 실패 모양이다(리터럴 매크로 목록이 재번호에서 2/3 을 틀리게
# 찍은 사고, `wm4spacecraft_manufacturing/oracle/action_registry.jl` 머리말 참조).
#
# 그러므로 이 게이트가 재는 명제는 하나다: **레지스트리가 이름 짓는 모든 것이 오늘 CB 안에
# 실제로 존재한다.**
#
# 🔴 이 게이트가 재지 **않는** 것 (과장 금지)
# --------------------------------------------
#   · 그 함수가 무엇을 하는지. `mechanism` 산문의 정확성은 여기서 검증되지 않는다.
#   · `gate` 가 그 원시에 실제로 걸리는지. **오늘은 안 걸린다** — 레지스트리의 `gate_arity`
#     가 그 사실을 항목마다 들고 있고(전부 `"RespecProposal"`), 그것이 spec §8 이 말하는
#     "안전층 ③ 을 제안 단위에서 연산 단위로 내린다"(Plan B 의 C 단계)가 아직 안 됐다는 뜻이다.
#     여기서는 `gate` 이름이 **해석되는지만** 잰다.
#   · `preconditions` 산문이 실제 전제조건과 일치하는지.
#
# 변이시험 (이 게이트가 실패하는 것을 실제로 봤다)
# -------------------------------------------------
#   레지스트리의 `impl` 한 자리를 `hot_swap_robot!` → `hot_swap_robot_XX!` 로 바꾸면
#   (1) 이 빨개진다. `gate` 를 `verify_translate` → `verify_translateXX` 로 바꾸면 (2) 가
#   빨개진다. 원시 이름 하나를 `Replace` 로 바꾸면 (6) 이 빨개진다.
# =============================================================================
using Test
import JSON3
using ConstructionBots
const CB = ConstructionBots

# `ACTION_REGISTRY` 와 같은 규약으로 경로를 갈아 끼울 수 있게 둔다. 이유는 편의가 아니라
# **변이시험**이다: 이 게이트가 실제로 실패하는 것을 보려면 오염된 레지스트리 사본을 물려야
# 하는데, 배포되는 파일을 편집해서 재는 것은 그 자체가 사고 경로다.
const _PRIM_PATH = get(ENV, "PRIMITIVE_REGISTRY",
                       normpath(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing",
                                         "core", "primitive_registry.json")))
const _ACT_PATH = get(ENV, "ACTION_REGISTRY",
                      normpath(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing",
                                        "core", "action_registry.json")))

# 조용한 폴백을 두지 않는다 — `action_registry.jl` 과 같은 규칙. 파일이 없으면 큰 소리로 죽는다.
@test isfile(_PRIM_PATH)
const _REG = JSON3.read(read(_PRIM_PATH, String))

const _PRIMS = _REG["primitives"]
const _PREDS = _REG["predicates"]
const _SURFACES = Set(String.(_REG["surfaces"]))

@test !isempty(_PRIMS)
@test !isempty(_PREDS)

# (1) 모든 `impl` 이 CB 에서 해석된다. 이것이 이 파일의 본체다.
@testset "every impl resolves in CB" begin
    for p in _PRIMS
        @test isdefined(CB, Symbol(p["impl"]))
    end
    for q in _PREDS
        @test isdefined(CB, Symbol(q["impl"]))
    end
end

# (2) `gate` 가 null 이 아니면 그 이름도 CB 에서 해석된다.
#     spec §7-1: `gate: null` 인 원시는 조합은 되지만 ③층에서 `deferred` 로 떨어진다 —
#     즉 null 은 결함이 아니라 **기록된 상태**다. 그래서 null 을 강제하지 않는다.
@testset "named gates resolve in CB" begin
    for p in _PRIMS
        g = p["gate"]
        g === nothing && continue
        @test isdefined(CB, Symbol(g))
    end
end

# (3) 스키마: 모든 항목이 필수 필드를 갖고, `surface` 는 선언된 집합 안이다.
@testset "schema fields present" begin
    required = ["name", "surface", "params", "mechanism", "when_to_use",
                "reversible", "consumes", "preconditions", "gate", "gate_arity",
                "impl", "harness_args", "source"]
    for p in _PRIMS
        for k in required
            @test haskey(p, k)
        end
        @test String(p["surface"]) in _SURFACES
        @test p["reversible"] isa Bool
    end
end

# (4) `mechanism` 은 비어 있으면 안 된다 — 그것이 **모델이 읽는 유일한 설명**이다(spec §6-1).
#     짧은 한 줄짜리 설명은 이 레인의 상시 원칙("docstring 은 최대한 상세하게")을 어긴다.
#     문턱 120자는 임의값이지만, 노리는 것은 "한 줄로 때운 항목"을 잡는 것이다.
@testset "mechanism is present and substantive" begin
    for p in _PRIMS
        @test length(String(p["mechanism"])) >= 120
    end
    for q in _PREDS
        @test length(String(q["mechanism"])) >= 60
    end
end

# (5) `when_to_use` 는 존재하고 비어 있지 않다.
#     🔴 이 검사가 공허해지는 경로가 실재한다: `when_to_use` 가 전부 "" 이면 §6-2 의 누출
#     검사(=이 문자열이 프롬프트에 새지 않았는가)가 **비교할 것이 없어서** 조용히 통과한다.
#     `core/test_registry_doc_split.py` 가 action_registry 쪽에서 정확히 이 함정을 밟았고
#     (Q3), 같은 함정이 여기에도 있으므로 같은 핀을 박는다.
@testset "when_to_use is non-empty (keeps the future leak test honest)" begin
    for p in _PRIMS
        @test !isempty(strip(String(p["when_to_use"])))
    end
end

# (6) 🔴 spec §7-2 — `action_registry.json` 과 **섞지 않는다**.
#     저 레지스트리의 `emitted_key` 는 (:fault,·)/(:battery,·) 로 **사건 클래스를 인코딩**한다.
#     이름이 겹치면 원시 연산이 채점 어휘로 밀반입돼, 존재하지 않는 사건 클래스가 채점기에
#     들어간다. 이름 공간이 서로소인지 직접 잰다.
@testset "disjoint from the scoring vocabulary" begin
    @test isfile(_ACT_PATH)
    act = JSON3.read(read(_ACT_PATH, String))
    macro_names = Set(String(m["name"]) for m in values(act["macros"]))
    @test !isempty(macro_names)                     # 빈 집합에 대한 서로소는 공허하다
    prim_names = Set(String(p["name"]) for p in _PRIMS)
    @test isempty(intersect(macro_names, prim_names))
end

# (7) 이름은 레지스트리 안에서 유일하다 — 중복이 있으면 T2 의 알파벳이 모호해진다.
@testset "names are unique" begin
    ns = [String(p["name"]) for p in _PRIMS]
    @test length(unique(ns)) == length(ns)
    qs = [String(q["name"]) for q in _PREDS]
    @test length(unique(qs)) == length(qs)
end
