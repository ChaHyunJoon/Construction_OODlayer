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
    # 결정적 정렬 (Ruling R-SORT): Julia 의 method-table 순회 순서는 보장된 계약이
    # 아니다. testset (2) 가 새 서브프로세스 재생성물과 커밋된 사본을 바이트째 비교하므로,
    # 이 정렬이 없으면 그 비교가 실행마다 이유 없이 흔들릴 수 있다.
    sort!(out, by = e -> (e["name"], e["signature"]))
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
