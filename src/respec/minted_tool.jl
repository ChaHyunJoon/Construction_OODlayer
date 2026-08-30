# =============================================================================
# 합성된 tool 의 집행. (2026-08-30, T2·T3 / spec §3-1, §5)
#
# LLM 은 **코드를 생성하지 않는다.** 기존 원시의 호출 시퀀스만 조합한다. 이 파일은 그
# 시퀀스를 받아 `primitive_registry.json` 을 통해 실제 CB 함수로 해석하고 집행한다.
#
# 🔴 알파벳은 레지스트리이지 CB 의 심볼 표가 아니다. `isdefined(CB, Symbol(name))` 로
#    해석하면 합성기가 `run_lego_demo` 든 무엇이든 부를 수 있고, 그 순간 안전층이
#    검사할 대상 자체가 정의되지 않는다(spec §3-1 의 마지막 문단).
#
# 🔴 이 파일에 **undo 가 없다.** Plan B 의 C 단계가 그것이고 이 계획의 범위 밖이다.
#    body 중간에서 실패하면 세계는 절반만 고쳐진 채 남는다. 그 사실을 `enact_minted!` 가
#    결과에 `undo = :none` 으로 싣는다 — 없는 안전장치를 있는 척하지 않는다.
#
# 이 파일을 `respec.jl`(`restage_zone.jl` 옆)에서 include 하는 이유: Julia 는 자유 전역을
# 정의 시점이 아니라 **호출 시점**에 푼다 — 함수 본문이 `ZoneTruth` 를 이름으로 써도 정의는
# 문제없이 컴파일되고, 실제로 그 이름을 필요로 하는 것은 나중에 그 함수가 불릴 때다. 그리고
# `src/navigator/` 는 애초에 `src/ConstructionBots.jl` 의 include 목록에 없다 — navigator 계층은
# 호출자가 `CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))` 로 **런타임에**
# CB 모듈 안에 얹는다. 그러므로 "먼저 로드해야 UndefVarError 를 피한다" 는 전제 자체가
# 이 파일에는 적용되지 않는다 — `resolve_primitive` 는 navigator 타입을 이름으로 쓰지 않는다.
# =============================================================================

const _PRIM_TABLE = Ref{Union{Nothing,Dict{String,Any}}}(nothing)

_primitive_registry_path() = get(ENV, "PRIMITIVE_REGISTRY",
    normpath(joinpath(@__DIR__, "..", "..", "wm4spacecraft_manufacturing",
                      "core", "primitive_registry.json")))

"내부용. 테스트가 경로를 갈아 끼운 뒤 캐시를 비우는 자리."
_reset_primitive_table!() = (_PRIM_TABLE[] = nothing; nothing)

"""
    PRIMITIVE_TABLE() -> Dict{String,Any}

`name => 레지스트리 항목` 표. 첫 호출에 읽고 캐시한다.

🔴 파일이 없으면 **던진다.** 빈 표를 돌려주면 모든 body 가 "미지 원시"로 보이고 원인이
레지스트리 부재라는 사실이 기록에서 사라진다 — `action_registry.jl` 과 같은 규약.
"""
function PRIMITIVE_TABLE()
    _PRIM_TABLE[] === nothing || return _PRIM_TABLE[]
    path = _primitive_registry_path()
    isfile(path) || error("primitive_registry 를 못 찾았다: $(path). " *
                          "PRIMITIVE_REGISTRY 로 경로를 줄 수 있다.")
    reg = JSON3.read(read(path, String))
    tbl = Dict{String,Any}()
    for p in reg["primitives"]
        tbl[String(p["name"])] = p
    end
    _PRIM_TABLE[] = tbl
    return tbl
end

"""
    resolve_primitive(name) -> Union{Nothing,NamedTuple}

원시 이름 하나를 해석한다. 레지스트리에 **없으면 `nothing`** 이다 — 조용히 통과시키지
않는다. 있으면 `(name, impl, surface, harness_args, params, reversible)`.
"""
function resolve_primitive(name::AbstractString)
    tbl = PRIMITIVE_TABLE()
    haskey(tbl, String(name)) || return nothing
    p = tbl[String(name)]
    sym = Symbol(String(p["impl"]))
    isdefined(@__MODULE__, sym) || error(
        "레지스트리가 이름 짓는 impl 이 CB 에 없다: $(p["impl"]) (원시 $(name)). " *
        "test/primitive_registry_resolves.jl 이 이걸 잡았어야 한다.")
    f = getfield(@__MODULE__, sym)
    f isa Function || error("$(p["impl"]) 이 callable 이 아니다 (원시 $(name))")
    return (name         = String(name),
            impl         = f,
            surface      = String(p["surface"]),
            harness_args = String[String(a) for a in get(p, "harness_args", [])],
            params       = Dict{String,Any}(String(k) => v for (k, v) in pairs(get(p, "params", Dict()))),
            reversible   = Bool(get(p, "reversible", false)))
end
