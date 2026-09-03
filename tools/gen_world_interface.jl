# 생성 agent 가 코드를 쓰기 위해 보는 세계 인터페이스. (2026-09-03, 설계 §4)
#
# 🔴 손으로 적지 않는다. `primitive_registry.json` 과 같은 패턴 — Julia 가 생성하고 두
#    언어가 읽는 한 파일이며, 게이트가 현행 코드와의 일치를 지킨다.
using ConstructionBots
import JSON3
const CB = ConstructionBots

_tname(T) = string(nameof(T isa UnionAll ? Base.unwrap_unionall(T) : T))

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

function type_entry(T)
    Dict("name" => _tname(T),
         "fields" => [Dict("name" => string(f), "type" => string(t))
                      for (f, t) in zip(fieldnames(T), fieldtypes(T))])
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

# 타입은 PlannerEnv 에서 **1단계만** 전개한다 (무한 전개 금지).
roots = [CB.PlannerEnv]
seen  = Set{String}()
types = Dict{String,Any}[]
for T in roots
    push!(types, type_entry(T)); push!(seen, _tname(T))
    for ft in fieldtypes(T)
        S = ft isa UnionAll ? Base.unwrap_unionall(ft) : ft
        (S isa DataType && isstructtype(S) && _defined_in_cb(S) && !(_tname(S) in seen)) || continue
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
