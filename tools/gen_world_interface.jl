# 생성 agent 가 코드를 쓰기 위해 보는 세계 인터페이스. (2026-09-03, 설계 §4)
#
# 🔴 손으로 적지 않는다. `primitive_registry.json` 과 같은 패턴 — Julia 가 생성하고 두
#    언어가 읽는 한 파일이며, 게이트가 현행 코드와의 일치를 지킨다.
using ConstructionBots
using InteractiveUtils     # subtypes
import JSON3
import DataStructures      # OrderedDict — access 색인의 키 순서를 구조로 고정한다
const CB = ConstructionBots

# 🔴 navigator 층은 **런타임 include** 다(`src/navigator/navigator.jl`). 그것 없이는
#    `battery_report` 가 아예 정의되지 않아(실측: UndefVarError) 아래 method_entries 의
#    `isdefined` 검사에서 조용히 빠진다 — 산출물이 export 목록과 어긋난다.
#    집행 경로도 같은 include 를 한다(`tools/monitor/render_demo.jl:18`), 그러므로
#    생성기와 런타임이 **같은 모듈**을 본다. 비용은 1.9초(실측).
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))

"""
앰비언트 세계 상태 — `PlannerEnv` 에 없지만 세계인 것. **손으로 유지되는 유일한 목록**이고,
그래서 게이트 `(7)` 이 "접근자가 `names(CB)` 에 있다" 를 지킨다.
"""
const AMBIENT_ROOTS = [
    (name = "battery fleet", accessor = "battery_report()",
     returns = "(total_energy_J::Float64, min_soc::Float64, mean_soc::Float64, " *
               "soc_spread::Float64, n_depleted::Int, soc::Dict{Any,Float64})"),
]

_unwrap(T) = T isa UnionAll ? Base.unwrap_unionall(T) : T

# 🔴 `Union` 에는 `nameof` 가 없다 — `apply_cmd!(node::Union{TransportUnitGo,RobotGo}, …)`
#    의 렌더가 정확히 여기서 MethodError 로 죽는다(실측).
function _tname(T)
    S = _unwrap(T)
    S isa DataType ? string(nameof(S)) : string(T)
end

# F2 (Task 2 이후: 고정점 폐포 `world_type_closure()` 전체의 문지기다, 1단계 전개가 아니다).
# 폐포가 몇 단계를 따라가든 ConstructionBots(또는 그 하위 모듈)가 **정의한** 타입만 받는다.
# `Dict`/`Set` 같은 Base 컨테이너는 `isstructtype` 이 true 라 전개 후보에 걸리지만, 그
# 슬롯 레이아웃(`slots`·`keys`·`vals`·`ndel`·`count`·`age`·`idxfloor`·`maxprobe`, `dict`)은
# 모델이 다룰 세계가 아니다 — 모델이 필요한 것은 컨테이너의 **원소 타입**(필드의 `type`
# 문자열에 이미 `Dict{AbstractID,Ball2}` 로 실린다)이지 해시테이블 내부 구현이 아니다.
# 그 내부를 WORLD TYPES 로 얹으면 모델이 해시테이블을 직접 주무르라는 초대장이 된다.
# 🔴 이 필터를 풀면 폐포가 폭발한다(실측: 깊이 2 에서 1,302타입, 깊이 3 에서 25,160타입) —
# `world_type_closure` 의 while 루프가 CB 밖으로 한 걸음도 못 나가게 막는 것이 바로 이 함수다.
function _defined_in_cb(S)
    S isa DataType || return false
    m = parentmodule(S)
    while true
        m === CB && return true
        pm = parentmodule(m)
        pm === m && return false   # Base/Main 까지 올라갔는데 CB 가 없었다
        m = pm
    end
end

"""
    _type_candidates!(acc, T, d=0)

필드 타입 하나에서 "모델이 알아야 할 타입" 을 전부 뽑아 `acc` 에 넣는다.
`Dict{AbstractID,Ball2}` 는 자기 자신 + `AbstractID` + `Ball2` 를 낳는다.
`TypeVar` 는 상한(`ub`)으로 내려간다. `Union` 은 양쪽으로 갈라진다.
`d` 는 **타입 매개변수 중첩**의 상한이지 폐포의 깊이가 아니다 — 폐포는 고정점이다.
"""
function _type_candidates!(acc, T, d = 0)
    d > 4 && return acc
    T isa TypeVar && return _type_candidates!(acc, T.ub, d + 1)
    if T isa Union
        _type_candidates!(acc, T.a, d + 1); _type_candidates!(acc, T.b, d + 1); return acc
    end
    S = _unwrap(T)
    S isa DataType || return acc
    push!(acc, S)
    for p in S.parameters
        (p isa Type || p isa TypeVar) && _type_candidates!(acc, p, d + 1)
    end
    return acc
end

"""
    world_type_closure() -> Vector{DataType}

`PlannerEnv` **와 `PlannerEnv` 를 인자로 받는 모든 메서드의 인자 타입**을 씨앗으로,
CB 소유 타입만 따라가는 고정점. 이름으로 정렬해 반환한다.

🔴 **씨앗에 메서드 인자를 넣는 이유**(설측). 필드만 따라가면 49타입이고
`PlannerEnv` 를 받는 23개 메서드 중 13개만 호출 가능해진다. 메서드 인자까지 넣으면
67타입이고 **23개 전부**가 열린다 — 새로 열리는 11개는 전부 `apply_cmd!`(7)·
`close_node!`(4) 로, 스케줄 노드를 실제로 여닫고 명령을 먹이는 유일한 공개 경로다.
(리뷰 라운드 1: 계획서의 "66"은 Task 1 이전 — `PlannerEnv`의 무타입 `Dict` 둘을 그냥
`Dict`로 되돌리고 재본 수다. Task 1 이 그 둘을 `Dict{AbstractID,VelocityController}`·
`Dict{AbstractID,Bool}`로 좁히며 `VelocityController` 하나가 폐포에 새로 들어와 67이 됐다.)

🔴 **CB-only 필터는 절대 풀지 않는다.** 실측: 풀면 깊이 2 에서 1,302타입,
깊이 3 에서 25,160타입이다.
"""
function world_type_closure()
    seeds = Any[CB.PlannerEnv]
    for n in sort(names(CB))
        isdefined(CB, n) || continue
        f = getfield(CB, n)
        f isa Function || continue
        for m in methods(f)
            Ts = collect(_unwrap(m.sig).parameters)[2:end]
            any(T -> _unwrap(T) === CB.PlannerEnv, Ts) || continue
            for T in Ts; _type_candidates!(seeds, T); end
        end
    end
    seen = Dict{String,DataType}()
    frontier = copy(seeds)
    while !isempty(frontier)
        S = _unwrap(popfirst!(frontier))
        S isa DataType || continue
        # 🔴 리뷰 라운드 1 픽스. `S` 는 발견된 자리에 따라 파라메트릭 타입의 **서로 다른
        #    구체 인스턴스**일 수 있다(예: `CachedElement{Ball2}` 대 `CachedElement{Transformation}`)
        #    — 같은 이름으로 `seen`에 접히므로, 정준화 없이는 "누가 먼저 팝됐나"가 산출물의
        #    필드 타입 문자열을 결정해 버린다(실측: `popfirst!`→`pop!` 하나로
        #    `CachedElement.element`가 `CoordinateTransformations.Transformation`→`G`로 뒤집힘).
        #    고정: 발견된 구체 인스턴스가 무엇이든 `.name.wrapper`를 다시 풀어 그 타입의
        #    **제네릭 바디**(타입변수 그대로인 선언형, 예: `CachedElement{E}`)로 정준화한다.
        #    이러면 같은 이름이 갖는 후보가 전부 같은 객체로 수렴해 프런티어 순서와 무관해진다
        #    — "누가 이기는가" 를 정하는 타이브레이크가 아니라 애초에 경합을 없앤다.
        #    대가: 필드가 자기 타입 매개변수를 그대로 쓰면(`element::E`) 렌더가 구체 타입 대신
        #    바로 그 타입변수를 보인다(`element :: E`) — 정보는 줄지만 결정적이고, 이미
        #    `LiftIntoPlace.entity :: C`가 오늘도 그 모양이다(비파라메트릭 타입은
        #    `S.name.wrapper`가 자기 자신이라 변화 없음).
        S = _unwrap(S.name.wrapper)
        n = _tname(S)
        (haskey(seen, n) || !_defined_in_cb(S)) && continue
        seen[n] = S
        nexts = Any[]
        if isabstracttype(S)
            append!(nexts, subtypes(S))
        else
            try
                for ft in fieldtypes(S); _type_candidates!(nexts, ft); end
            catch
                # 🔴 구상 타입인데 fieldtypes 가 던지는 모양은 오늘 없다. 던지면
                #    그 타입은 필드 없이 실린다 — 조용한 폴백이 아니라 아래 type_entry
                #    가 같은 판정을 다시 하고 정직하게 빈 fields 를 낸다.
            end
        end
        append!(frontier, nexts)
    end
    # 🔴 `subtypes` 의 순서는 계약이 아니다. 정렬해야 게이트 (2) 의 바이트 비교가 산다.
    return DataType[seen[k] for k in sort(collect(keys(seen)))]
end

"""
    type_entry(T) -> Dict

구상 타입이면 `fields`, 추상 타입이면 `subtypes`. **둘 다 실지 않는다** —
독자(시험 (2)·파이썬 렌더)가 어느 쪽인지로 분기한다.

🔴 `fieldnames(SceneTreeEdge)` 는 `ArgumentError: type does not have a definite
   number of fields` 를 **던진다**(실측). 추상 타입에 필드를 물으면 안 된다.
"""
function type_entry(T)
    S = _unwrap(T)
    isabstracttype(S) && return Dict(
        "name" => _tname(S),
        "subtypes" => sort(String[_tname(U) for U in subtypes(S)]))
    return Dict(
        "name" => _tname(S),
        "fields" => [Dict("name" => string(f), "type" => string(t))
                     for (f, t) in zip(fieldnames(S), fieldtypes(S))])
end

"""
    _sig_string(m) -> String

메서드 하나를 **모델이 호출을 쓸 수 있는 모양**으로 렌더한다: `(env::PlannerEnv; min_ready, snap_all)`.

🔴 **왜 `string(m.sig)` 이 아닌가** (2026-09-03 최종 리뷰 I3). 그 표현은 `Tuple{typeof(f), Any}`
   다 — 208개 메서드 **전부**가 그 모양이었다. 인자 **이름이 없고 키워드가 통째로 없다.**
   이 산출물의 존재 이유는 모델이 이 함수들을 **부르는 코드를 쓰는 것**인데, 부를 때 필요한
   두 가지가 정확히 그 둘이다. `Base.method_argnames` 와 `Base.kwarg_decl` 이 둘 다 준다.

🔴 **결정성**(게이트 (2) 가 새 서브프로세스 재생성물과 바이트 비교한다). 세 자리 다 안정적이다:
   `unwrap_unionall(m.sig).parameters` 는 선언 순서, `method_argnames` 도 선언 순서,
   `kwarg_decl` 도 선언 순서다. 정렬이나 집합 순회가 끼지 않는다.

⚠️ 이름이 없는 인자(`f(::Int)`)는 `method_argnames` 가 `#unused#` 같은 젠심을 준다 —
   그런 이름은 `_` 로 정규화한다. 젠심을 그대로 실으면 모델이 그것을 인자 이름으로 읽는다.
⚠️ `Any` 는 타입 주석을 **안 붙인다**. 208개 중 다수가 타입 없이 선언돼 있고, `x::Any` 는
   정보가 0인데 줄만 길게 만든다.
"""
function _sig_string(m::Method)
    sig = Base.unwrap_unionall(m.sig)
    Ts  = collect(sig.parameters)[2:end]        # 첫째는 typeof(f)
    nms = Base.method_argnames(m)               # 첫째는 #self#
    parts = String[]
    for (i, T) in enumerate(Ts)
        nm = length(nms) >= i + 1 ? String(nms[i + 1]) : ""
        (isempty(nm) || startswith(nm, "#")) && (nm = "_")
        ts = string(T)
        push!(parts, ts == "Any" ? nm : string(nm, "::", ts))
    end
    kws = Base.kwarg_decl(m)
    return "(" * join(parts, ", ") * (isempty(kws) ? "" : "; " * join(String.(kws), ", ")) * ")"
end

"""
    access_index(closure) -> AbstractDict{String,Vector{String}}

폐포의 각 타입에 대해 `env` 로부터 그 값을 얻는 **경로 문자열**들. 필드 그래프의 순수
순회이므로 결정적이다. 컨테이너는 원소를 꺼내는 모양으로 적는다 —
`Vector{T}` 는 `…[i]`, `Dict{K,V}` 는 `keys(…)`/`values(…)`.

🔴 이 색인이 §1.2 의 실패를 정면으로 겨냥한다: 모델이 지어낸 것은 전부 "그 값을 어디서
   얻는지 안 적힌" 타입이었다.

🔴 **결정성은 구조로 지킨다**(게이트 (2) 가 새 서브프로세스 재생성물과 바이트 비교한다).
   경로 목록은 `sort(unique(...))` 이고, **키 순서는 `OrderedDict` + 정렬 키**다 —
   맨 `Dict` 는 삽입 순서(= BFS 발견 순서)가 해시 레이아웃에 남으므로 결정적이긴 해도
   그 결정성이 우연에 가깝다. 여기서는 산출물의 키 순서가 **키 집합만의 함수**다.
"""
function access_index(closure)
    want = Set(String[_tname(S) for S in closure])
    out  = Dict{String,Vector{String}}()
    add!(n, p) = (n in want && push!(get!(out, n, String[]), p))
    # 너비 우선. 경로가 길어지면 모델에게 쓸모가 없으므로 3 홉에서 끊는다.
    frontier = Tuple{DataType,String,Int}[(CB.PlannerEnv, "env", 0)]
    seen = Set{String}(["PlannerEnv"])

    # 🔴 **중첩 컨테이너는 재귀로 푼다** (Task 4 실측 정정, 계획서의 1단계 분기를 대체한다).
    #    계획서 판은 `Vector{Dict{Int,SceneTreeEdge}}`(= `SceneTree.inedges` 의 실제 타입)의
    #    안쪽 `Dict` 를 **구조체로 착각해 필드로 내려갔고**, 그래서 산출물에
    #    `env.scene_tree.inedges[i].vals[i]` 라는 **해시테이블 내부 경로**가 실렸다(실측).
    #    그 경로는 이 파일이 `_defined_in_cb` 로 막기로 한 바로 그것이고, 게다가 `Dict.vals`
    #    는 빈 슬롯이 `#undef` 라 순회 자체가 안전하지 않다. 옳은 경로는
    #    `values(env.scene_tree.inedges[i])` 다.
    # 🔴 같은 이유로 **CB 밖 구조체의 필드로는 한 걸음도 내려가지 않는다** —
    #    `_defined_in_cb` 가 폐포에서 하는 역할을 여기서도 한다.
    function visit!(U, path, hop, d = 0)
        (U isa DataType && d <= 3) || return
        if U <: AbstractVector && length(U.parameters) >= 1
            visit!(_unwrap(U.parameters[1]), string(path, "[i]"), hop, d + 1)
        elseif U <: AbstractDict && length(U.parameters) >= 2
            K = _unwrap(U.parameters[1])
            K isa DataType && add!(_tname(K), string("keys(", path, ")"))
            visit!(_unwrap(U.parameters[2]), string("values(", path, ")"), hop, d + 1)
        elseif U <: AbstractSet && length(U.parameters) >= 1
            E = _unwrap(U.parameters[1])
            E isa DataType && add!(_tname(E), string("for x in ", path))
        else
            add!(_tname(U), path)
            (_defined_in_cb(U) && !(_tname(U) in seen)) &&
                (push!(seen, _tname(U)); push!(frontier, (U, path, hop + 1)))
        end
        return nothing
    end

    while !isempty(frontier)
        (S, path, hop) = popfirst!(frontier)
        hop >= 3 && continue
        isabstracttype(S) && continue
        for (f, ft) in zip(fieldnames(S), fieldtypes(S))
            visit!(_unwrap(ft), string(path, ".", f), hop)
        end
    end
    # 🔴 결정성: 경로 목록도 정렬하고, 키도 정렬된 순서로 싣는다.
    ord = DataStructures.OrderedDict{String,Vector{String}}()
    for k in sort(collect(keys(out))); ord[k] = sort(unique(out[k])); end
    return ord
end

const _SCALARISH = (Real, AbstractString, Symbol, Bool, Char)

"이 인자 타입을 모델이 손에 넣을 수 있는가."
function _arg_obtainable(T, reach)
    T isa Union && return _arg_obtainable(T.a, reach) && _arg_obtainable(T.b, reach)
    S = _unwrap(T)
    S === Any && return true
    S === CB.PlannerEnv && return true
    S isa DataType || return false
    S === Nothing && return true
    any(P -> S <: P, _SCALARISH) && return true
    return _tname(S) in reach
end

"""
    method_entries(reach, acc) -> Vector{Dict}

각 메서드에 **호출 가능성**(`callable`)과 **인자마다의 도달 경로**(`argpaths`)를 붙인다.
`callable` 은 "모든 인자를 `env` 에서(또는 스칼라로) 손에 넣을 수 있다" 는 뜻이고,
`argpaths` 는 그 손에 넣는 방법을 `이름 <- 경로` 로 적은 줄들이다.

⚠️ **둘은 같은 강도의 주장이 아니다.** `callable` 이 보는 것은 `reach`(= 폐포 **멤버십**)이고
   `argpaths` 가 보는 것은 `acc`(= 실제 **경로**)다. 폐포에는 있는데 `env` 로부터의 경로가
   아직 없는 타입이 있으므로 — 오늘 `callable` 인 것의 다수가 `argpaths` 가 비어 있다 —
   `callable=true` 를 "이 줄만 보고 바로 부를 수 있다" 로 읽으면 안 된다. 그 강한 주장을
   나르는 것은 **`argpaths` 가 비어 있지 않은 항목**뿐이다.
"""
function method_entries(reach, acc)
    out = Dict{String,Any}[]
    for n in sort(names(CB))
        isdefined(CB, n) || continue
        f = getfield(CB, n)
        f isa Function || continue
        for m in methods(f)
            Ts = collect(Base.unwrap_unionall(m.sig).parameters)[2:end]
            callable = all(T -> _arg_obtainable(T, reach), Ts)
            paths = String[]
            if callable
                nms = Base.method_argnames(m)
                for (i, T) in enumerate(Ts)
                    S = _unwrap(T)
                    (S === CB.PlannerEnv || S === Any) && continue
                    ps = get(acc, _tname(S), String[])
                    isempty(ps) && continue
                    nm = length(nms) >= i + 1 ? String(nms[i + 1]) : "_"
                    startswith(nm, "#") && (nm = "_")
                    push!(paths, string(nm, " <- ", first(ps)))
                end
            end
            push!(out, Dict("name" => string(n), "signature" => _sig_string(m),
                            "callable" => callable, "argpaths" => paths))
        end
    end
    # 결정적 정렬 (Ruling R-SORT): Julia 의 method-table 순회 순서는 보장된 계약이
    # 아니다. testset (2) 가 새 서브프로세스 재생성물과 커밋된 사본을 바이트째 비교하므로,
    # 이 정렬이 없으면 그 비교가 실행마다 이유 없이 흔들릴 수 있다.
    # F6: `alg=MergeSort` 로 명시 — 기본 정렬은 안정 정렬이 아니다. 오늘의 208개 항목은
    # (name, signature) 쌍이 우연히 전부 유일해서 불안정 정렬로도 바이트가 재현됐을 뿐이고,
    # 그 유일성은 계약이 아니다(같은 이름·같은 시그니처 문자열을 내는 두 메서드가 생기면
    # 불안정 정렬은 둘의 순서를 실행마다 바꿀 수 있다) — 안정 정렬이면 그 경우에도 항상
    # `methods()` 가 준 순서를 보존해 재현성이 구조로 유지된다.
    sort!(out, by = e -> (e["name"], e["signature"]), alg = MergeSort)
    return out
end

closure = world_type_closure()
types   = Dict{String,Any}[type_entry(T) for T in closure]
acc     = access_index(closure)
reach   = Set(String[_tname(S) for S in closure])

dst = length(ARGS) >= 1 ? ARGS[1] :
      normpath(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "core",
                        "world_interface.json"))
open(dst, "w") do io
    JSON3.pretty(io, Dict("types" => types,
                          "access" => acc,
                          "methods" => method_entries(reach, acc),
                          "ambient" => [Dict("name" => a.name, "accessor" => a.accessor,
                                             "returns" => a.returns)
                                        for a in AMBIENT_ROOTS]))
end
println("wrote ", dst)
