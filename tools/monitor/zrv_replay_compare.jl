# zrv_replay_compare.jl <episode_dir> — T3 재생 게이트 판정(한 에피소드). CB 를 로드하지 않는다.
#   julia +lts --project=. tools/monitor/zrv_replay_compare.jl <root>/<model>__<case>__s<seed>
# 판정(`verdict`):
#   replay_ok      = resume 가 orig-a 와 t0 이후 **모든 공통 스텝**에서 trace 가 같고, 종료 스텝·결과가 같고,
#                    import 불일치 블록 0, dispatch 가드 통과, RVO 동률 0, t0 이후 전역 RNG 불변.
#   noise_floor    = orig-a vs orig-b(같은 설정 반복) — 레포 자체 잡음.
#   capture_inert  = orig-a vs capture — export 가 세계를 바꾸지 않았나.
using JSON3
include(joinpath(@__DIR__, "..", "..", "src", "verification", "replay_compare.jl"))
const RC = ReplayCompare

ep = ARGS[1]
tr(r) = joinpath(ep, r, "trace.tsv")
term(r) = (p = joinpath(ep, r, "terminal.json"); isfile(p) ? JSON3.read(read(p, String)) : nothing)
has(r) = isfile(tr(r))
out = Dict{String,Any}("episode" => basename(ep))
T = Dict(r => term(r) for r in ("orig-a", "orig-b", "capture", "resume"))
outcome(t) = t === nothing ? nothing :
    Dict("complete" => t.complete, "reason" => t.terminal_reason, "closed" => t.closed, "iter" => t.iter)
out["outcomes"] = Dict(r => outcome(t) for (r, t) in T)
# 설계상 다를 수 있는 종료 세계 필드(나머지는 전부 같아야 한다):
#   rng.default — 기본 RNG 는 프로세스마다 시드 없이 시작하고 런타임이 소비하지 않는다(trace `rng` 열 불변으로 확인)
#   원장 경계 — MONITOR_* 기록부·RUN_CTX·_RID_CTR(분기는 sink 를 떼어낸다)
#   출력 위치 — Main.anim_dir/out_root/stream_dir/stream_path(런마다 다른 DEMO_OUT_DIR)
const EXPECTED = [r"^rng\.default$", r"\.MONITOR_[A-Z_]+$", r"\.RUN_CTX$", r"\._RID_CTR$",
                  r"^globals\.Main\.(anim_dir|out_root|stream_dir|stream_path)$"]
function world_diff(a, b)
    (a === nothing || b === nothing) && return nothing
    fa, fb = a.world_field_sha256, b.world_field_sha256
    d = sort!([String(k) for k in union(keys(fa), keys(fb)) if get(fa, k, nothing) != get(fb, k, nothing)])
    return Dict("expected" => filter(f -> any(r -> occursin(r, f), EXPECTED), d),
                "unexpected" => filter(f -> !any(r -> occursin(r, f), EXPECTED), d))
end
# trace 비교는 `rng` 열을 뺀다 — 대신 각 런에서 그 열이 t0 이후 한 값뿐(= 전역 RNG 미소비)인지 따로 본다.
cmp(a, b; from = typemin(Int)) = (has(a) && has(b)) ? RC.compare_traces(tr(a), tr(b); from_iter = from, ignore = ("rng",)) : nothing
rng_const(r; from = typemin(Int)) = has(r) ? RC.n_distinct(tr(r), "rng"; from_iter = from) == 1 : nothing
t0 = T["capture"] === nothing ? nothing : get(T["capture"], :t0_iter, nothing)
out["t0_iter"] = t0
out["noise_floor"] = Dict("trace" => cmp("orig-a", "orig-b"), "terminal_world_fields_differ" => world_diff(T["orig-a"], T["orig-b"]))
out["capture_inert"] = Dict("trace" => cmp("orig-a", "capture"), "terminal_world_fields_differ" => world_diff(T["orig-a"], T["capture"]))
out["replay"] = Dict("trace" => t0 === nothing ? nothing : cmp("orig-a", "resume"; from = t0),
                     "vs_capture" => t0 === nothing ? nothing : cmp("capture", "resume"; from = t0),
                     "terminal_world_fields_differ" => world_diff(T["orig-a"], T["resume"]),
                     "resume" => T["resume"] === nothing ? nothing : get(T["resume"], :resume, nothing),
                     "rng_advanced_after_t0" => T["resume"] === nothing ? nothing : get(T["resume"], :rng_advanced_after_t0, nothing))
same_outcome(a, b) = a !== nothing && b !== nothing && outcome(a) == outcome(b)
out["rng_unconsumed"] = Dict(r => rng_const(r) for r in ("orig-a", "orig-b", "capture", "resume"))
clean(x) = x === nothing || isempty(x["unexpected"])
tr_eq(x) = x !== nothing && x.first_divergent_iter === nothing && x.only_a == 0 && x.only_b == 0
r = out["replay"]
tie_ok = r["resume"] !== nothing && all(w -> isempty(w.ties), r["resume"].rvo_tie_watch)
out["verdict"] = Dict(
    "noise_floor_equal" => tr_eq(out["noise_floor"]["trace"]) && same_outcome(T["orig-a"], T["orig-b"]) &&
                           clean(out["noise_floor"]["terminal_world_fields_differ"]),
    "capture_inert" => tr_eq(out["capture_inert"]["trace"]) && same_outcome(T["orig-a"], T["capture"]) &&
                       clean(out["capture_inert"]["terminal_world_fields_differ"]),
    "replay_ok" => tr_eq(r["trace"]) && same_outcome(T["orig-a"], T["resume"]) &&
                   clean(r["terminal_world_fields_differ"]) && r["resume"] !== nothing &&
                   isempty(r["resume"].mismatched_blocks) && isempty(r["resume"].dispatch_guard) &&
                   isempty(r["resume"].fingerprint_mismatches) && tie_ok &&
                   r["rng_advanced_after_t0"] === false && out["rng_unconsumed"]["orig-a"] === true)
open(io -> JSON3.pretty(io, JSON3.write(out)), joinpath(ep, "compare.json"), "w")
JSON3.pretty(stdout, JSON3.write(out)); println()
