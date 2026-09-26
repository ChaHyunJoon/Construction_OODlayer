# compare_l0_l1.jl <t10b_root> <out.json> — T10b: 같은 판의 L0·L1 분기 trace 를 t0 이후 전 경계 대조(rng 열 제외).
using JSON3
include(joinpath(pwd(), "src", "verification", "replay_compare.jl"))
root = ARGS[1]; out = Dict{String,Any}()
for key in sort(readdir(joinpath(root, "cohort")))
    a, b = joinpath(root, "cohort", key, "branches", "L0", "trace.tsv"), joinpath(root, "cohort", key, "branches", "L1", "trace.tsv")
    (isfile(a) && isfile(b)) || continue
    c = ReplayCompare.compare_traces(a, b; from_iter = 1, ignore = ("rng",))
    out[key] = Dict(String(k) => v for (k, v) in pairs(c))
    println(rpad(key, 18), " first_div=", c.first_divergent_iter, " cols=", c.divergent_columns, " common=", c.n_common, " only=", c.only_a, "/", c.only_b)
end
open(io -> JSON3.pretty(io, JSON3.write(out)), ARGS[2], "w")
