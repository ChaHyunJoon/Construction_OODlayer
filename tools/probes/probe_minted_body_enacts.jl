# tools/probes/probe_minted_body_enacts.jl
#   julia +lts --project=. tools/probes/probe_minted_body_enacts.jl [board]
#
# L2 enactment lane — does a two-primitive body ACTUALLY get enacted?
#
# Body under test:  ["release_pending_assignments", "reprice_agent_by_payload"]
#   `commit_respec` is deliberately ABSENT: the common MILP re-solve (T13,
#   `resolve_assignments!`, src/smdp/generative.jl:238) runs after every arm inside
#   `apply_action!`, so the body must NOT carry the write-back step.
#
# 🔴 RETURN SYMBOLS ARE NOT EVIDENCE. `:admit`/`applied` are bookkeeping; this probe
#    reports them AND independently measures the world on both sides of the call:
#      · number of ASSIGNMENT EDGES in the schedule graph  (release must DROP it)
#      · `EDGE_PAYLOAD_MULTIPLIER[]` installed?            (reprice must INSTALL it)
#    A green verdict with an unchanged world is the failure this lane exists to catch.
#
# 🔴 삼상 규약: "못 쟀다" is printed as `nothing`, never as 0.
#
# 🔴 JULIA SOFT SCOPE: every count happens INSIDE a function (top-level `for` counters
#    report a silent 0 — see MEMORY.md julia-probe-toplevel-counters-are-silent-zeros).
#
# PRECONDITION measured in the S2 lane: `run_lego_demo` never initialises the battery
# fleet, so without `enable_battery!` the reprice step returns `:no_fleet` and installs
# NOTHING (task-5-addendum Ruling 7).
using ConstructionBots
import Random, Graphs
const CB = ConstructionBots
isdefined(CB, :BatteryTruth) ||
    CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
# T4 진입점(`enact_minted_decision!`). `handled` 를 식으로 베끼지 않고 **파이프라인이 쓰는
# 그 함수**에서 받는다 — 이 레포에서 "코드를 읽어 추론한 값"은 여러 번 뒤집혔다.
include(joinpath(pkgdir(CB), "tools", "monitor", "enact.jl"))

"Assignment edges (free -> slot) currently in the schedule graph. This is what release removes."
function n_assignment_edges(sched)
    G = CB.get_graph(sched)
    n = 0
    for e in Graphs.edges(G)
        CB.is_assignment_edge(sched, e.src, e.dst) && (n += 1)
    end
    return n
end

"Most common valid owner id among the schedule's assignment-edge sources, module-qualified.
🔴 The module-qualified string is required — a hand-written short form yields `:unknown_agent`."
function busiest_owner(sched)
    tally = Dict{String,Int}()
    G = CB.get_graph(sched)
    for e in Graphs.edges(G)
        CB.is_assignment_edge(sched, e.src, e.dst) || continue
        id = CB._edge_owner_id(sched, e.src)
        id === nothing && continue
        tally[string(id)] = get(tally, string(id), 0) + 1
    end
    isempty(tally) && return nothing
    return sort(collect(tally), by = kv -> -kv[2])[1][1]
end

_synth(names, params) = Dict{String,Any}(
    "reach" => "composed", "body_names" => names, "tool_name" => "payload_wear_level",
    "params" => params, "missing_primitive" => nothing)

function main()
    board = length(ARGS) >= 1 ? ARGS[1] : "colored_8x8.ldr"
    nrobots = board == "tractor.mpd" ? 10 : 6
    println("="^78); println("BOARD = ", board, "  robots = ", nrobots); println("="^78)

    env = CB.run_lego_demo(; ldraw_file = board, project_name = "l2enact",
                             num_robots = nrobots, assignment_mode = :greedy,
                             n_spare_per_pool = 2, open_animation_at_end = false,
                             save_animation = false, write_results = false,
                             return_env_before_sim = true, rng = Random.MersenneTwister(1))
    CB.enable_battery!(env; params = CB.BatteryParams())
    CB.clear_payload_bias!()
    println("BATTERY_FLEET[]            = ", CB.BATTERY_FLEET[] === nothing ? "nothing" : "installed")

    target = busiest_owner(env.sched)
    target === nothing && error("no valid owner id among assignment edges — probe is vacuous")
    println("target agent               = ", target)

    # ---- WORLD BEFORE ------------------------------------------------------------------
    edges_before = n_assignment_edges(env.sched)
    mult_before  = CB.EDGE_PAYLOAD_MULTIPLIER[] === nothing ? "nothing" : "installed"
    println("assignment edges BEFORE    = ", edges_before)
    println("EDGE_PAYLOAD_MULTIPLIER[]  BEFORE = ", mult_before)

    # ---- THE CALL ----------------------------------------------------------------------
    synth = _synth(["release_pending_assignments", "reprice_agent_by_payload"],
                   Dict{String,Any}("agent" => target, "light_bias" => 0.5))
    r = CB.enact_minted!(env, nothing, synth)

    println("\n---- enact_minted! ----")
    println("verdict            = ", r.verdict)
    println("reason             = ", r.reason)
    println("applied            = ", r.applied)
    println("partial            = ", r.partial)
    println("world_maybe_dirty  = ", r.world_maybe_dirty)
    println("resume             = ", r.resume)
    println("steps (", length(r.steps), "):")
    for s in r.steps
        println("   · ", s.name, "  status=", s.status, "  detail=", s.detail)
    end

    # ---- WORLD AFTER -------------------------------------------------------------------
    edges_after = n_assignment_edges(env.sched)
    mult_after  = CB.EDGE_PAYLOAD_MULTIPLIER[] === nothing ? "nothing" : "installed"
    println("\n---- WORLD (return symbols are NOT this) ----")
    println("assignment edges  BEFORE/AFTER    = ", edges_before, " / ", edges_after,
            "   released = ", edges_before - edges_after)
    println("EDGE_PAYLOAD_MULTIPLIER[] B/A     = ", mult_before, " / ", mult_after)

    # ---- T4 진입점: `handled` 는 파이프라인이 실제로 읽는 값이다 -----------------------
    # 🔴 여기서 세계는 이미 위 호출로 바뀌었다. 그래서 이 두 번째 호출은 **같은 body 를 이미
    #    풀린 판 위에서** 다시 집행한다 — 두 번째 release 는 뗄 간선이 없어 `:released_none`
    #    이 되는 것이 정상이다. 재는 것은 `handled` 배선이지 세계 변화가 아니다(그건 위에서
    #    이미 쟀다). 두 관측을 섞지 않으려고 이 문단을 따로 둔다.
    dec = (macro_name = "MintedTool",
           synth_lane = Dict{String,Any}(
               "reach" => "composed",
               "body_names" => ["release_pending_assignments", "reprice_agent_by_payload"],
               "tool_name" => "payload_wear_level",
               "params" => Dict{String,Any}("agent" => target, "light_bias" => 0.5),
               "missing_primitive" => nothing))
    h = enact_minted_decision!(env, nothing, dec)
    println("\n---- T4 (enact_minted_decision!) — 이미 풀린 판 위의 두 번째 집행 ----")
    # 🔴 `sanctioned` 은 아직 측정값이 아니다 — 이 프로브는 두 팔 구조가 아니라 `dec.synth_lane`
    #    이 `"reach" => "composed"` 를 리터럴로 들고 있으므로 이 열은 오늘 늘 `true` 를 찍는다.
    println("handled = ", h.handled, "   verdict = ", h.verdict,
            "   applied = ", h.applied, "   world_maybe_dirty = ", h.world_maybe_dirty,
            "   sanctioned = ", dec.synth_lane["reach"] == "composed",
            "   threw = ", count(s -> s.status === :threw, h.steps))
    # 🔴 식을 베끼지 않는다 — `enact.jl` 의 정본 `minted_handled` 를 **부른다**(위에서 include
    #    했다). 손베낀 복사본이 프로덕션과 갈렸던 것이 이 레인의 T0 실측이다.
    println("(참고) 첫 집행의 판정으로 계산하면 handled = ", minted_handled(r))

    released_ok = edges_after < edges_before
    reprice_ok  = CB.EDGE_PAYLOAD_MULTIPLIER[] !== nothing
    println("\n---- VERDICT ----")
    println("release changed the world?  ", released_ok)
    println("reprice installed the hook? ", reprice_ok)
    if isempty(r.steps)
        println("⚪ VOID — 아무 단계도 안 불렸다(verdict=", r.verdict,
                "). 아래 숫자를 인용하지 마라.")
    elseif CB.minted_handled_verdict_ok(r.verdict) && released_ok && reprice_ok
        println("🟢 GREEN — body enacted AND both halves are visible in the world.")
    elseif CB.minted_handled_verdict_ok(r.verdict)
        println("🔴 SILENT SUCCESS — :admit but the world did not move. This is the worst case.")
    else
        println("🔴 RED — verdict=", r.verdict, " (world untouched, as :reject promises)")
    end
end

main()
