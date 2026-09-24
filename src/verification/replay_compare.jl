# =============================================================================
# replay_compare.jl — 재생 궤적 비교(T3). 의존성 없는 순수 함수(드라이버가 CB 없이 부른다).
#
# trace 파일 한 줄 = `iter \t loop \t cache \t sched \t scene \t rvo \t globals \t rng`(각 열은 그 필드의
# 정준 행 sha256 앞 16자). 줄의 iter 는 그 스텝을 **시작하기 전** 경계다(`HARNESS_HOOK(:step)`).
# =============================================================================
module ReplayCompare

const TRACE_COLUMNS = ("loop", "cache", "sched", "scene", "rvo", "globals", "rng")

read_trace(path) = Dict(parse(Int, first(split(l, '\t'))) => split(l, '\t')[2:end]
                        for l in eachline(path) if !isempty(l) && !startswith(l, "#"))

"""
    compare_traces(a, b; from_iter = typemin(Int)) -> NamedTuple

두 trace 를 **공통 iter** 에서 비교한다(`from_iter` 이상). 반환: `n_common`, `only_a`/`only_b`(한쪽에만 있는
iter 수 — 종료 시점이 다르면 0 이 아니다), `first_divergent_iter`(없으면 `nothing`)와 그 iter 에서 갈린
열 이름들, `last_common_iter`.
"""
function compare_traces(a::AbstractString, b::AbstractString; from_iter::Int = typemin(Int),
                        ignore = ())
    keep = [i for (i, c) in enumerate(TRACE_COLUMNS) if !(c in ignore)]
    proj(d) = Dict(k => v[keep] for (k, v) in d)
    A, B = proj(read_trace(a)), proj(read_trace(b))
    ka = sort!([k for k in keys(A) if k >= from_iter]); kb = Set(k for k in keys(B) if k >= from_iter)
    common = [k for k in ka if k in kb]
    first_div = nothing; cols = String[]
    for k in common
        A[k] == B[k] && continue
        first_div = k
        cols = [TRACE_COLUMNS[keep[i]] for i in eachindex(keep) if A[k][i] != B[k][i]]
        break
    end
    return (n_common = length(common), only_a = length(ka) - length(common),
            only_b = length(kb) - length(common), first_divergent_iter = first_div,
            divergent_columns = cols, last_common_iter = isempty(common) ? nothing : last(common))
end

"한 trace 에서 `from_iter` 이후 `col` 열의 서로 다른 값 수(1 이면 그 구간 동안 그 필드가 안 바뀌었다)."
n_distinct(path, col; from_iter = typemin(Int)) =
    length(Set(v[findfirst(==(col), TRACE_COLUMNS)] for (k, v) in read_trace(path) if k >= from_iter))

end # module ReplayCompare
