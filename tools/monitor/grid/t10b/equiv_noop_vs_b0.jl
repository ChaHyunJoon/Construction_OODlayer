# equiv_noop_vs_b0.jl <t10b_root> <out.json> — 병렬 동등성: 이 런(8 병렬 부하)의 NOOP 기준 분기 trace 를 T10a v2 격자의 B0 부모
# trace(같은 CB 빌드 26f20ab7 이후 src 무변경)와 t0 이후 전 경계 대조(rng 열 제외) + terminal(outcome·closed·iter).
using JSON3
include(joinpath(pwd(), "src", "verification", "replay_compare.jl"))
const RC = ReplayCompare
root, out = ARGS[1], ARGS[2]
b0 = Dict(string(e["model"], "_", e["case"], "_s", e["seed"]) => e for e in
          JSON3.read(read("test/fixtures/repair_verification/b0/b0_episodes.json", String), Dict{String,Any})["episodes"])
res = Dict{String,Any}()
for key in sort(readdir(joinpath(root, "cohort")))
    nd = joinpath(root, "cohort", key, "supervision", "noop"); isfile(joinpath(nd, "trace.tsv")) || continue
    pd = joinpath(b0[key]["parent_dir"])
    c = RC.compare_traces(joinpath(pd, "trace.tsv"), joinpath(nd, "trace.tsv"); from_iter = 1, ignore = ("rng",))
    t = JSON3.read(read(joinpath(nd, "terminal.json"), String), Dict{String,Any})
    res[key] = Dict("trace" => Dict(String(k) => v for (k, v) in pairs(c)), "noop_closed" => t["closed"], "noop_iter" => t["iter"],
                    "b0_closed" => b0[key]["closed"], "b0_iter" => b0[key]["iter"])
    println(rpad(key, 18), " first_div=", c.first_divergent_iter, " cols=", c.divergent_columns, " common=", c.n_common,
            " closed ", t["closed"], "/", b0[key]["closed"], " iter ", t["iter"], "/", b0[key]["iter"])
end
open(io -> JSON3.pretty(io, JSON3.write(res)), out, "w")
