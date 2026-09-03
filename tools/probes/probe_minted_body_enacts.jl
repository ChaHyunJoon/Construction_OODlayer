# tools/probes/probe_minted_body_enacts.jl
#   julia +lts --project=. tools/probes/probe_minted_body_enacts.jl [board]
#
# L2 enactment lane — does a two-primitive body ACTUALLY get enacted?
#
# Body under test:  ["release_pending_assignments", "reprice_agent_by_payload"]
#   `commit_respec` is deliberately ABSENT: the common MILP re-solve (T13,
#   `resolve_assignments!` in src/respec/common_resolve.jl) runs after every arm inside
#   `apply_action!` (src/smdp/generative.jl, which calls it), so the body must NOT carry
#   the write-back step.
#   🔴 2026-09-03: this line used to cite `src/smdp/generative.jl:238` as the DEFINITION.
#      That is not a stale line number, it is the WRONG FILE — 판정 1 moved `RESOLVE_CALLS`
#      and `resolve_assignments!` out of `generative.jl` into `common_resolve.jl` (that move
#      is the precondition this lane declares it stands on), and the comment left at the old
#      site says so. Cite path + function name here, never a line number.
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

"""
    _void_kind(r) -> Symbol

🔴 **정본은 `tools/probes/probe_cargo_ban_end_to_end.jl` 의 같은 이름 함수다** — 식도
라벨(`VOID_NOSTEP` · `VOID_UNAPPLIED`)도 거기서 그대로 가져왔고 근거 docstring 도 거기 있다.
두 프로브가 같은 이름의 판정을 다르게 정의하면 둘을 나란히 읽는 사람이 갈린다(2026-09-03 T9).
⚠️ 두 파일 다 최상위에서 `main()` 을 부르는 스크립트라 **서로** include 할 수 없다. 🔴 그러나
그것이 복사본을 불가피하게 만들지는 **않는다** — 이 파일이 스스로 반증한다: 바로 위에서
`include(... "tools", "monitor", "enact.jl")` 로 **제3의 공용 자리**를 불러 정본 `minted_handled`
를 쓰고 있다(T7 이 손베낀 4-연언지 복사본을 없앤 그 패턴이다). 이 복사본이 남은 진짜 이유는
**T9 의 편집 표면이 두 파일로 제한됐기 때문**이고, 옳은 해법은 `_void_kind` 를 같은 공용 자리
(`enact.jl`)로 올려 두 프로브가 함께 부르는 것이다 — **후속 작업으로 남아 있다.**
그때까지 이 문단이 정본을 가리킨다. 🔴 이것을 "설계상 어쩔 수 없는 것" 으로 읽고 방치하지 마라.

| 값 | 라벨 | 뜻 |
|---|---|---|
| `:nostep` | `VOID_NOSTEP` | 아무 단계도 안 불렸다 — 나머지 숫자를 인용하지 마라 |
| `:unapplied` | `VOID_UNAPPLIED` | 단계는 불렸는데 `applied=false` — 잴 수 있는 편집이 하나도 없다 |
| `:unmeasured` | `VOID_UNMEASURED` | 단계는 불렸는데 `applied=nothing` — **잴 수 있는지 자체가 선언 안 된 원시**(생성 원시) |
| `:ok` | (라벨 없음) | 공허는 아니다. 🔴 그 이상의 판정은 아니다 |

🔴 **옛 판정 `isempty(r.steps)` 하나로는 집행된 행에서 절대 안 켜진다**(T7 이 첫 프로브에서
실측했다). 잡아야 할 공허는 "단계 목록이 비었다" 가 아니라 **"세계를 바꿨다고 잴 수 있는 단계가
하나도 없다"** 다.

🔴 **`VOID_UNAPPLIED` 를 "세계가 깨끗하다" 로 읽지 마라** — `applied=false` 는 조용한 성공
(`SILENT_SUCCESS_STATUSES`)과 못 쟀다(`UNMEASURABLE_STATUSES`)를 둘 다 삼킨다. 다행히 이
프로브는 세계를 **직접** 잰다(배정 간선 · `EDGE_PAYLOAD_MULTIPLIER[]`) — 그 두 줄이 이 라벨
바로 위에 찍히므로, 라벨이 움직인 세계를 가리지 않는다.
"""
# 🔴 삼상이다(2026-09-03 C1). `applied` 는 이제 `nothing`("못 쟀다")을 낼 수 있고 —
#    생성 원시는 자기 status 어휘를 선언하지 않는다 — 예전 삼항 `r.applied ? … : …` 은
#    그 값에서 **TypeError 로 죽는다**(non-boolean in boolean context).
_void_kind(r) = isempty(r.steps) ? :nostep :
                r.applied === true    ? :ok :
                r.applied === nothing ? :unmeasured : :unapplied

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
    # 🔴 공허가 맨 **앞**이다(이 레인 T3+4 의 결론) — 그러나 *앞*이지 *대신*이 아니다.
    #    그래서 이 `if` 는 아래 GREEN/SILENT/RED 사슬과 **분리된 독립 if** 다. 첫 프로브
    #    (`probe_cargo_ban_end_to_end.jl`)가 이미 그 모양이고, 이유가 있다: 공허 라벨은
    #    "아래 숫자를 인용하지 마라" 라는 **경고**이지 판정의 **대체**가 아니다.
    #    🔴 T9 fix round 1 (2026-09-03): 이 둘을 한 배타 사슬로 묶었더니 `steps` 가 비지 않고
    #    `applied=false` 인 판에서 `🔴 SILENT SUCCESS`(최악의 경우)가 **영영 안 찍혔다** —
    #    ⚪ 공허가 그 자리를 먹었다. 옛 `:nostep` 은 사문이라 그 결함이 잠자고 있었지만
    #    `:unapplied` 는 실제로 켜지므로 활성 결함이 된다. 절대 다시 합치지 마라.
    #    갈래는 첫 프로브와 **같은 둘**이다(위 `_void_kind` 의 docstring 이 정본을 가리킨다).
    local void = _void_kind(r)
    if void === :nostep
        println("⚪ VOID_NOSTEP — 아무 단계도 안 불렸다(verdict=", r.verdict,
                "). 아래 숫자를 인용하지 마라.")
    elseif void === :unmeasured
        println("⚪ VOID_UNMEASURED — 단계는 ", length(r.steps),
                " 개 불렸는데 applied=nothing 이다(verdict=", r.verdict,
                "). 🔴 이것은 \"아무 일도 안 났다\" 가 **아니다** — 이 원시의 status 어휘가",
                " 선언돼 있지 않아 노린 적응이 일어났는지 **잴 수 없었다**는 뜻이다.",
                " 성공률의 분자에도 분모에도 넣지 마라.")
    elseif void === :unapplied
        println("⚪ VOID_UNAPPLIED — 단계는 ", length(r.steps),
                " 개 불렸는데 applied=false 다(verdict=", r.verdict,
                "). 잴 수 있는 편집이 하나도 없다 — 아래 숫자를 효과로 인용하지 마라.")
        println("   🔴 이것은 \"세계가 깨끗하다\" 가 아니다: `applied=false` 는 조용한 성공",
                "(SILENT_SUCCESS_STATUSES)과 못 쟀다(UNMEASURABLE_STATUSES)를 둘 다 삼킨다.",
                " 원인은 위 단계별 status 로 갈라라 (world_maybe_dirty = ",
                r.world_maybe_dirty, ").")
        println("   ⚠️ 바로 위 두 줄(release/reprice)이 true 면 이 라벨에도 불구하고 세계는",
                " 움직였다 — 이 프로브는 세계를 직접 잰다.")
    end

    # 판정 사슬은 공허와 **독립**으로 굴린다 — 공허인 판에서도 GREEN/SILENT/RED 가 찍힌다.
    # 🔴 세 팔 다 **리터럴 verdict 를 박지 않고 `r.verdict` 를 그대로 싣는다.** 술어는
    #    `CB.minted_handled_verdict_ok` 라 집행 계열 **둘**(`:admit`·`:admit_unsanctioned`)이
    #    걸리는데, 문구가 `:admit` 이라고 적으면 이 레인이 가르려고 존재한 그 둘을 판정 줄이
    #    다시 뭉갠다(2026-09-02 결정 2). `else` 팔도 마찬가지로 `:reject` 하나가 아니다 —
    #    `:deferred` 도 여기로 온다. 🔴 여기에 verdict 이름을 손으로 적지 마라.
    if CB.minted_handled_verdict_ok(r.verdict) && released_ok && reprice_ok
        println("🟢 GREEN — body enacted (verdict=", r.verdict,
                ") AND both halves are visible in the world.")
    elseif CB.minted_handled_verdict_ok(r.verdict)
        println("🔴 SILENT SUCCESS — verdict=", r.verdict,
                " (집행 계열) but the world did not move. This is the worst case.")
    else
        println("🔴 RED — verdict=", r.verdict,
                " (world untouched, as a non-enacted verdict promises)")
    end
end

main()
