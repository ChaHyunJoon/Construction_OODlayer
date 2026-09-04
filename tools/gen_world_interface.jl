# 생성 agent 가 코드를 쓰기 위해 보는 세계 인터페이스. (2026-09-03, 설계 §4)
#
# 🔴 손으로 적지 않는다. `primitive_registry.json` 과 같은 패턴 — Julia 가 생성하고 두
#    언어가 읽는 한 파일이며, 게이트가 현행 코드와의 일치를 지킨다.
using ConstructionBots
using InteractiveUtils     # subtypes
import JSON3
const CB = ConstructionBots

_unwrap(T) = T isa UnionAll ? Base.unwrap_unionall(T) : T

# 🔴 `Union` 에는 `nameof` 가 없다 — `apply_cmd!(node::Union{TransportUnitGo,RobotGo}, …)`
#    의 렌더가 정확히 여기서 MethodError 로 죽는다(실측).
function _tname(T)
    S = _unwrap(T)
    S isa DataType ? string(nameof(S)) : string(T)
end

# F2: 1단계 전개 후보는 ConstructionBots(또는 그 하위 모듈)가 **정의한** 타입만 받는다.
# `Dict`/`Set` 같은 Base 컨테이너는 `isstructtype` 이 true 라 전개 후보에 걸리지만, 그
# 슬롯 레이아웃(`slots`·`keys`·`vals`·`ndel`·`count`·`age`·`idxfloor`·`maxprobe`, `dict`)은
# 모델이 다룰 세계가 아니다 — 모델이 필요한 것은 컨테이너의 **원소 타입**(필드의 `type`
# 문자열에 이미 `Dict{AbstractID,Ball2}` 로 실린다)이지 해시테이블 내부 구현이 아니다.
# 그 내부를 WORLD TYPES 로 얹으면 모델이 해시테이블을 직접 주무르라는 초대장이 된다.
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
66타입이고 **23개 전부**가 열린다 — 새로 열리는 11개는 전부 `apply_cmd!`(7)·
`close_node!`(4) 로, 스케줄 노드를 실제로 여닫고 명령을 먹이는 유일한 공개 경로다.

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

function method_entries()
    out = Dict{String,Any}[]
    for n in sort(names(CB))
        isdefined(CB, n) || continue
        f = getfield(CB, n)
        f isa Function || continue
        for m in methods(f)
            push!(out, Dict("name" => string(n), "signature" => _sig_string(m)))
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

types = Dict{String,Any}[type_entry(T) for T in world_type_closure()]

dst = length(ARGS) >= 1 ? ARGS[1] :
      normpath(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "core",
                        "world_interface.json"))
open(dst, "w") do io
    JSON3.pretty(io, Dict("types" => types, "methods" => method_entries()))
end
println("wrote ", dst)
