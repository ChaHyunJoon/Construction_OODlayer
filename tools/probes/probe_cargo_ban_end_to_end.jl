# tools/probes/probe_cargo_ban_end_to_end.jl
#   julia +lts --project=. tools/probes/probe_cargo_ban_end_to_end.jl [board] [nrobots] [target_closed]
#   (인자 없이 돌리면 **두 판** tractor.mpd(10대) · colored_8x8.ldr(6대) 를 순서대로 잰다)
#
# cargo-ban Task 8 — 주조된 tool 의 **body 가 집행되고 세계가 실제로 움직이는가**.
#
# body:
#   1. release_pending_assignments(agent="…")     ← 좁힌 release (b20c01ab)
#   2. forbid_heavy_cargo(agent="…", n=1)
#
# `tools/probes/probe_minted_body_enacts.jl` 의 모양을 그대로 따르되(집행 전/후로 세계를 직접
# 잰다), body 를 바꾸고 **음성 대조를 더했다.**
#
# ─────────────────────────────────────────────────────────────────────────────
# 🔴 판정 규율 — Task 1(`5456124f`)이 실측으로 못박은 것들. 어기면 거짓 성공을 보고한다.
#
#  (1) 🔴 **`binding` 으로 판정하지 않는다.** 아무것도 안 누른 음성 대조에서도 A 가 이미 묶인
#      정점 2~11개를 잃고(재풀이 잡음), 게다가 `release_pending_assignments!` 는 표적 슬롯을
#      solve **전에** 음수 무효 id 로 되돌리므로 잃을 것이 애초에 남아 있지 않다.
#      ⟹ 판정은 `JuMP.value(Xa[u,v2]) > 0.5` **+ 음성 대조**로 한다. (계획서 G-2 의 `binding`
#      스케치는 shared-rulings S-4.4 가 뒤집었다.)
#  (2) 🔴 **음성 대조는 선택이 아니다.** 같은 픽스처·같은 solve 경로에서 "금지 있음"과
#      "금지 없음"을 둘 다 잰다. 대조 없이는 재풀이 잡음이 금지의 효과로 읽힌다.
#  (3) 🔴 **`n_reassigned` 는 증거가 아니다** — Task 1 은 `n_reassigned = 11` 인데 대상 로봇이
#      잃은 작업이 **0** 인 판을 여러 번 봤다. 이 프로브는 그 값을 판정에 쓰지 않는다
#      (애초에 commit 을 안 한다 — 아래 (6)).
#  (4) 🔴 **`TIME_LIMIT` 행의 목적값은 인용 금지**(제약을 더했는데 목적값이 내려가는 행이
#      실제로 나온다 = incumbent 대 incumbent). 좁힌 release 는 0.1~0.3s 에 `OPTIMAL` 이다.
#      종료 상태를 **항상 함께** 찍고, `OPTIMAL` 이 아니면 그렇게 표시한다.
#  (5) 🔴 **`makespan(env.sched)` 을 판정에 쓰지 않는다** — 앞선 프로브에서 10012 / 14.55 를
#      오가는 Big-M 센티넬이 나왔다. 이 파일은 그 값을 아예 안 읽는다.
#  (6) 🔴 **fork 하지 않는다.** `fork()` → `rvo_rebuild!` 는 프로세스 전역 RVO 심을 변형해서
#      그 뒤의 stepping 이 "앞서 몇 개의 팔을 돌렸는가"에 의존하게 만든다(Task 1 의 한 라운드가
#      그것 때문에 통째로 철회됐다). 대신 **두 팔이 같은 env·같은 그래프**를 공유하고
#      `commit_respec!` 을 **한 번도 안 부른다** — solve 는 env 를 안 바꾸므로 두 팔의 세계는
#      바이트 동일이고, 다른 것은 `STANDING_CARGO_BANS[]` 하나뿐이다. 이것이 가능한 가장
#      좁은 음성 대조다. (판마다 env 는 새로 세운다.)
#  (7) 🔴 **부담 동점**을 해석하지 말고 잰다. 계획서는 colored_8x8 이 고유값 2개, tractor 가
#      15개라 적지만 Task 1 의 실측은 각각 1개·최댓값 2동점이었다. **여기서 다시 잰다.**
#  (8) **`closed` 는 도달값을 적는다** — target 이 아니다.
#  (9) 🔴 집계는 전부 **함수 안**(Julia soft scope: 최상위 `for` 카운터는 조용한 0 이 된다).
# (10) 🔴 삼상 규약: 못 쟀으면 `nothing`. **0 이 아니다.**
# (11) ⚠️ `catch` 안의 `return` 은 이 레포에서 한 번 `Unreachable reached`(SIGILL, julia
#      1.10.11)를 냈다(`forbid_heavy_cargo!` 본문, 커밋 `7074be8e`). 🔴 **그것을 구문 규칙으로
#      일반화하지 말 것** — `src/` 에 같은 모양이 27~41 곳 있고 전부 멀쩡히 돈다
#      (`cargo_ban_primitive.jl::_try_resolve_schedule_agent` 의 docstring 이 실측을 적는다).
#      이 파일은 `catch` 를 두 곳에서만 쓰고 둘 다 값으로 끝난다.
# ─────────────────────────────────────────────────────────────────────────────
using ConstructionBots
using Random, Graphs, JuMP, SparseArrays
const CB = ConstructionBots

# 🔴 런타임 include 는 **모듈 최상위**여야 한다(world-age). 계획 README 의 공용 픽스처는 이 두
#    줄이 빠져 있어 그대로 돌리면 `UndefVarError: enable_battery!` 로 죽는다(S-4.9).
#    순서도 load-bearing: navigator 먼저, 그 다음 mdp(simstate_of).
isdefined(CB, :BatteryTruth) ||
    CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
isdefined(CB, :simstate_of) ||
    CB.include(joinpath(pkgdir(CB), "src", "smdp", "mdp.jl"))

const TL = 60.0
_s(x) = x === nothing ? "nothing" : string(x)
_r(x, d = 4) = x === nothing ? "nothing" : string(round(x; digits = d))

# ── 픽스처 ───────────────────────────────────────────────────────────────────
"""
배터리·hazard·에너지 가중치가 켜진 env 를 `target_closed` 까지 전진시킨다.
셋 다 필요하다: `run_lego_demo` 는 배터리를 초기화하지 않고(→ 부담 계층 부재 → 금지 0행),
`init_objective_weights!` 없이는 목적함수가 `edge_costs` 를 통째로 버린다.

🔴 상한에 걸리면 **에러**다 — 조용히 돌려주면 아래 숫자가 전부 다른 세계에서 온 것이 된다.
"""
function fixture(; board, nr, target_closed, maxstep = 6000)
    # 🔴 판마다 프로세스 전역을 되감는다. `run_lego_demo` 는 `SIM_STEP` 도 `ASSET_LEDGER` 도
    #    리셋하지 않고(`reset_asset_ledger!()` 는 src/ 안에 호출자 0개), `step_to!` 가
    #    `step_environment!` 를 `set_sim_step!` 보다 먼저 부르므로 새 env 의 첫 스텝이 앞 판의
    #    `SIM_STEP` 으로 hazard 시계를 맞춘다(S-4.7 이 이 자리를 지목했다).
    CB.set_sim_step!(0)
    try
        CB.reset_asset_ledger!()
    catch e
        @warn "reset_asset_ledger! 실패 — 판 간 격리가 불완전하다" exception = e
    end
    env = CB.run_lego_demo(; ldraw_file = board, project_name = "cargobane2e", num_robots = nr,
                             assignment_mode = :greedy, n_spare_per_pool = 2,
                             open_animation_at_end = false, save_animation = false,
                             write_results = false, return_env_before_sim = true,
                             rng = Random.MersenneTwister(1))
    CB.enable_battery!(env); CB.enable_hazard!(env; seed = 7); CB.init_objective_weights!()
    k = 0
    while length(CB.simstate_of(env).prog.closed) < target_closed && k < maxstep
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0); k += 1; CB.set_sim_step!(k)
    end
    got = length(CB.simstate_of(env).prog.closed)
    got < target_closed && error("fixture: 스텝 상한 $maxstep — closed = $got < $target_closed")
    return (env = env, closed = got, steps = k)
end

# ── 세계를 직접 재는 계량기들 ────────────────────────────────────────────────
"스케줄 그래프에 지금 서 있는 배정 간선(free → slot) 집합. release 가 떼는 것이 이것이다."
function assignment_edges(sched)
    out = Set{Tuple{Int,Int}}()
    for e in Graphs.edges(CB.get_graph(sched))
        CB.is_assignment_edge(sched, e.src, e.dst) && push!(out, (e.src, e.dst))
    end
    return out
end

"""
떼어질 수 있는(= 미래) 배정 간선을 가장 많이 소유한 로봇의 `(id, 문자열, 히스토그램)`.

🔴 `Dict` 는 세는 데만 쓰고 **순회로 고르지 않는다** — 정렬 키 `(-개수, 이름)` 이 순서를
지운다(S-6). Task 1 의 알려진 한계 2(A 선택에 tie-break 이 없었다)를 여기서 닫는다.
🔴 문자열은 **모듈 한정** 형태다 — 짧게 쓴 형태는 두 원시 모두 `:unknown_agent` 로 떨어진다.
"""
function busiest_pending_agent(env)
    sched = env.sched
    frozen = CB.build_invariant(env).closed_nodes
    running = Set{CB.AbstractID}(CB.get_vtx_id(sched, v) for v in env.cache.active_set)
    untouchable(id) = id in frozen || id in running
    tally = Dict{String,Int}(); owner_of = Dict{String,CB.AbstractID}()
    for e in Graphs.edges(CB.get_graph(sched))
        CB.is_assignment_edge(sched, e.src, e.dst) || continue
        untouchable(CB.get_vtx_id(sched, e.src)) && continue
        untouchable(CB.get_vtx_id(sched, e.dst)) && continue
        o = CB._edge_owner_id(sched, e.src); o === nothing && continue
        s = string(o); tally[s] = get(tally, s, 0) + 1; owner_of[s] = o
    end
    isempty(tally) && return (id = nothing, str = nothing, tally = tally, tied = nothing)
    ranked = sort(collect(tally), by = kv -> (-kv[2], kv[1]))
    best = ranked[1]
    tied = count(kv -> kv[2] == best[2], ranked)   # A 선택이 동점이었는지 **기록한다**
    return (id = owner_of[best[1]], str = best[1], tally = tally, tied = tied)
end

"""
`agent` 소유의 **후보** 도착점 v2 마다 1대당 부담. 조건은 `_heavy_cargo_targets` 와 글자 그대로
같다(`!has_edge` 인 구조적 비영 항목만). 🔴 못 잰 v2 는 **건너뛴다**(0 으로 접지 않는다).
"""
function owned_burdens(env, Xa, aid)
    sched = env.sched
    p = CB.BATTERY_FLEET[] === nothing ? nothing : CB.BATTERY_FLEET[].params
    p === nothing && return (vals = Tuple{Int,Float64}[], n_owned = 0, n_unmeasured = 0)
    rv = SparseArrays.rowvals(Xa)
    vals = Tuple{Int,Float64}[]; n_owned = 0; n_unmeas = 0
    for v2 in 1:size(Xa, 2)
        owned = false
        for k in SparseArrays.nzrange(Xa, v2)
            u = rv[k]
            Graphs.has_edge(sched, u, v2) && continue
            o = CB._edge_owner_id(sched, u)
            (o !== nothing && o == aid) || continue
            owned = true; break
        end
        owned || continue
        n_owned += 1
        b = CB.cargo_burden_after(env, sched, v2, p)
        b === nothing ? (n_unmeas += 1) : push!(vals, (v2, Float64(b)))
    end
    return (vals = vals, n_owned = n_owned, n_unmeasured = n_unmeas)
end

"""
부담 동점 구조 — 🔴 계획서의 숫자를 인용하지 말고 **여기서 잰다**(S-4.6).
`nothing` 은 "잰 도착점이 하나도 없다"(0 이 아니다).
"""
function tie_structure(vals)
    isempty(vals) && return (ndistinct = nothing, nties_at_max = nothing,
                             bmax = nothing, bmin = nothing, hist = Tuple{Float64,Int}[])
    bs = [b for (_, b) in vals]
    rounded = [round(b; digits = 6) for b in bs]
    hist = Dict{Float64,Int}()
    for b in rounded; hist[b] = get(hist, b, 0) + 1; end
    top = sort(collect(hist), by = kv -> -kv[1])
    bmax = maximum(bs)
    return (ndistinct = length(hist),
            nties_at_max = count(b -> isapprox(b, bmax; rtol = 1e-12), bs),
            bmax = bmax, bmin = minimum(bs), hist = top[1:min(6, length(top))])
end

# ── 한 팔 = formulate + solve. commit 하지 않는다 ────────────────────────────
"""
`resolve_assignments!`(`src/smdp/generative.jl`, 모든 팔 뒤에 도는 공통 재풀이)와 **같은
정식화**를 세워 푼다: `build_invariant` 로 과거를 얼리고 `extra_constraints` 없이
`formulate_milp` → `optimize!`. 금지는 그 안의 훅(`_compile_standing_cargo_bans!`)으로만 들어온다.

🔴 **`commit_respec!` 은 일부러 안 부른다.** 판정이 `value(Xa)` 이므로 필요 없고(S-4.4),
안 부르면 두 팔이 **바이트 동일한 그래프** 위에서 돌아 대조가 성립한다. 대가는 `binding`
기반 관측(`n_reassigned`·makespan)을 못 낸다는 것인데, 그 셋은 판정에 쓰면 안 되는 값들이다.

`released_slots` 는 집행 **전후 배정 간선 집합의 차**에서 얻은 도착점들이다 — 즉 "release 가
A 에게서 실제로 떼어낸 슬롯". 재풀이가 그 슬롯을 A 에게 **돌려주는가**를 센다.
"""
function solve_arm(env, aid, astr, released_slots, label::Symbol)
    sched = env.sched
    inv = CB.build_invariant(env)
    sent = Dict{Tuple{Int,Int},Float64}(); CB.LAST_EDGE_COSTS[] = sent
    milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), sched, env.scene_tree;
                             optimizer = CB._respec_optimizer(),
                             t0_ = inv.frozen_t0, tF_ = inv.frozen_tF)
    # 🔴 formulate 가 실제로 돌았는지 — 안 돌았으면 아래 전부가 공허하다.
    CB.LAST_EDGE_COSTS[] === sent &&
        return (arm = label, status = :no_formulate)
    ncand = length(CB.LAST_EDGE_COSTS[])
    Xa = milp.Xa
    nconstr = JuMP.num_constraints(milp.model; count_variable_in_set_constraints = false)

    # 표적과 부담 구조 — 구조적 비영 항목만 보므로 **팔에 무관**해야 한다(밖에서 대조한다).
    ob = owned_burdens(env, Xa, aid)
    tie = tie_structure(ob.vals)
    old_st = CB.RESPEC_SCENE_TREE[]
    CB.RESPEC_SCENE_TREE[] = env.scene_tree
    targets = try
        CB._heavy_cargo_targets(sched, Xa, aid, 1)
    finally
        CB.RESPEC_SCENE_TREE[] = old_st
    end
    tv2 = isempty(targets) ? nothing : targets[1]

    CB.set_time_limit_sec(milp, TL)
    wall = @elapsed CB.optimize!(milp)
    ts = CB.termination_status(milp); ps = CB.primal_status(milp)
    if ps != CB.MOI.FEASIBLE_POINT
        return (arm = label, status = :no_incumbent, ncand = ncand, nconstr = nconstr,
                tstat = ts, pstat = ps, wall = wall, target_v2 = tv2, tie = tie,
                n_owned = ob.n_owned, n_unmeasured = ob.n_unmeasured)
    end

    # ── 세계의 답 — 재풀이가 A 에게 그 슬롯을 돌려줬는가 ────────────────────
    rv = SparseArrays.rowvals(Xa)
    recovered = 0; judgeable = 0; not_a_column = 0; no_owned_var = 0
    recovered_slots = Int[]; lost_slots = Int[]
    for v2 in released_slots
        if v2 > size(Xa, 2)
            not_a_column += 1; continue
        end
        has_var = false; takes = false
        for k in SparseArrays.nzrange(Xa, v2)
            u = rv[k]
            CB.isassigned_edge(Xa, u, v2) || continue
            o = CB._edge_owner_id(sched, u)
            (o !== nothing && o == aid) || continue
            has_var = true
            JuMP.value(Xa[u, v2]) > 0.5 && (takes = true)
        end
        if !has_var
            no_owned_var += 1
        else
            judgeable += 1
        end
        # 🔴 "A 가 이 슬롯을 다시 안 가져갔다" = 잃었다. 결정변수가 아예 없는 슬롯도
        #    A 가 못 가져간 것이 사실이므로 여기 포함하되, 그 개수를 따로 찍어 둔다.
        takes ? (recovered += 1; push!(recovered_slots, v2)) : push!(lost_slots, v2)
    end
    # 표적 화물을 A 가 집는가 (`nothing` = 표적이 없다 / 열이 아니다)
    at_target = nothing
    if tv2 !== nothing && tv2 <= size(Xa, 2)
        n = 0
        for k in SparseArrays.nzrange(Xa, tv2)
            u = rv[k]
            CB.isassigned_edge(Xa, u, tv2) || continue
            o = CB._edge_owner_id(sched, u)
            (o !== nothing && o == aid) || continue
            JuMP.value(Xa[u, tv2]) > 0.5 && (n += 1)
        end
        at_target = n
    end
    obj = try JuMP.objective_value(milp.model) catch; nothing end
    return (arm = label, status = :ok, ncand = ncand, nconstr = nconstr,
            tstat = ts, pstat = ps, wall = wall, obj = obj,
            target_v2 = tv2, tie = tie, n_owned = ob.n_owned, n_unmeasured = ob.n_unmeasured,
            n_released_slots = length(released_slots), recovered = recovered,
            lost = length(released_slots) - recovered, judgeable = judgeable,
            not_a_column = not_a_column, no_owned_var = no_owned_var,
            at_target = at_target, recovered_slots = recovered_slots, lost_slots = lost_slots)
end

"금지를 비운 채 한 팔을 돈다(음성 대조). `Ref` 를 통째로 갈아끼웠다가 `finally` 로 되돌린다."
function solve_control(env, aid, astr, released_slots)
    saved = CB.STANDING_CARGO_BANS[]
    CB.STANDING_CARGO_BANS[] = Dict{CB.AbstractID,Int}()
    try
        return solve_arm(env, aid, astr, released_slots, :control)
    finally
        CB.STANDING_CARGO_BANS[] = saved
    end
end

# ── 한 판 ────────────────────────────────────────────────────────────────────
_synth(agent) = Dict{String,Any}(
    "reach" => "composed",
    "body_names" => ["release_pending_assignments", "forbid_heavy_cargo"],
    "tool_name" => "cargo_ban_wear_level",
    "params" => Dict{String,Any}("agent" => agent, "n" => 1),
    "missing_primitive" => nothing)

_ban_keys() = sort(string.(collect(keys(CB.STANDING_CARGO_BANS[]))))

function run_board(board, nr, target_closed)
    println("\n", "="^92)
    println("BOARD = ", board, "   robots = ", nr, "   target_closed = ", target_closed)
    println("="^92)
    CB.clear_all_cargo_bans!()                     # 판 사이 격리
    fx = fixture(board = board, nr = nr, target_closed = target_closed)
    env = fx.env
    println("closed 도달값 = ", fx.closed, "  (target = ", target_closed, ", steps = ", fx.steps, ")")
    println("BATTERY_FLEET[] = ", CB.BATTERY_FLEET[] === nothing ? "nothing" : "installed")

    ag = busiest_pending_agent(env)
    ag.id === nothing && error("미래 배정 간선이 0 — 재분배 창이 닫혔다. target_closed 를 줄여라")
    println("target agent = ", ag.str)
    println("  (미래 간선 소유 히스토그램 = ", sort(collect(ag.tally), by = kv -> (-kv[2], kv[1])),
            " · 최댓값 동점 = ", ag.tied, ")")

    # ---- 세계 (전) -----------------------------------------------------------
    E0 = assignment_edges(env.sched)
    bans_before = _ban_keys()
    println("\n---- 세계 (집행 전) ----")
    println("배정 간선 = ", length(E0))
    println("STANDING_CARGO_BANS[] = ", isempty(bans_before) ? "비었다" : bans_before)

    # ---- body 집행 -----------------------------------------------------------
    r = CB.enact_minted!(env, nothing, _synth(ag.str))
    println("\n---- enact_minted! ----")
    println("verdict           = ", r.verdict)
    println("reason            = ", r.reason)
    println("applied           = ", r.applied, "   partial = ", r.partial,
            "   world_maybe_dirty = ", r.world_maybe_dirty, "   resume = ", r.resume)
    println("steps (", length(r.steps), "):")
    for s in r.steps
        println("   · ", s.name, "  status=", s.status, "  detail=", s.detail)
    end

    # ---- 세계 (후) -----------------------------------------------------------
    E1 = assignment_edges(env.sched)
    bans_after = _ban_keys()
    removed = collect(setdiff(E0, E1))
    released_slots = sort!(unique!([v2 for (_, v2) in removed]))
    println("\n---- 세계 (집행 후) — 🔴 반환 심볼이 아니라 이것이 증거다 ----")
    println("배정 간선 전/후        = ", length(E0), " / ", length(E1),
            "   (뗀 간선 = ", length(removed), ")")
    println("STANDING_CARGO_BANS[] 전/후 = ",
            (isempty(bans_before) ? "비었다" : string(bans_before)), " / ", bans_after)
    println("release 가 뗀 슬롯 수  = ", length(released_slots))
    println("금지 대상이 A 인가      = ", ag.str in bans_after)

    if isempty(released_slots)
        println("\n🔴 VACUOUS — release 가 아무 슬롯도 안 뗐다. 아래 판정은 공허하므로 중단한다.")
        return (board = board, closed = fx.closed, agent = ag.str, verdict = r.verdict,
                steps = r.steps, edges = (length(E0), length(E1)),
                bans = (bans_before, bans_after), control = nothing, treatment = nothing,
                vacuous = true, tied_agents = ag.tied)
    end

    # ---- 두 팔 ---------------------------------------------------------------
    # 🔴 대조를 **먼저** 돈다. 두 팔은 같은 env·같은 그래프를 보고 commit 을 안 하므로
    #    순서가 결과를 바꿀 수 없어야 한다 — 그 사실을 프로브가 직접 확인한다(구조 대조 아래).
    ctl = solve_control(env, ag.id, ag.str, released_slots)
    trt = solve_arm(env, ag.id, ag.str, released_slots, :treatment)
    for a in (ctl, trt)
        println("\n---- 팔: ", a.arm, " ----")
        if a.status !== :ok
            println("status = ", a.status, "   (판정 불가)")
            continue
        end
        println("후보 간선 ncand   = ", a.ncand, "   제약 행 수 = ", a.nconstr)
        println("종료/1차 상태      = ", a.tstat, " / ", a.pstat, "   wall = ", _r(a.wall, 3), "s")
        println("표적 v2           = ", _s(a.target_v2), "   A 가 표적을 집은 간선 수 = ", _s(a.at_target))
        println("뗀 슬롯 ", a.n_released_slots, " 중 A 가 회수 = ", a.recovered,
                "   🔴 잃은 작업 = ", a.lost)
        println("  (판정 가능 슬롯 = ", a.judgeable, ", A 소유 결정변수 없음 = ", a.no_owned_var,
                ", Xa 열 아님 = ", a.not_a_column, ")")
        println("  잃은 슬롯 = ", a.lost_slots)
        println("부담 구조: A 소유 후보 도착점 = ", a.n_owned, " (못 잰 것 ", a.n_unmeasured, ")",
                " · 고유값 = ", _s(a.tie.ndistinct), " · 최댓값 동점 = ", _s(a.tie.nties_at_max),
                " · 범위 = [", _r(a.tie.bmin), ", ", _r(a.tie.bmax), "]")
        println("  부담 히스토그램(상위) = ", a.tie.hist)
        # 🔴 목적값은 `OPTIMAL` 행에서만 뜻이 있다 — 아니면 인용 금지라고 **찍어서** 남긴다.
        println("목적값 = ", _r(a.obj), a.tstat == CB.MOI.OPTIMAL ? "" : "   ⚠️ 종료가 OPTIMAL 이 아니다 — 인용 금지")
    end

    # ---- 구조 대조: 두 팔이 같은 판을 봤는가 --------------------------------
    if ctl.status === :ok && trt.status === :ok
        println("\n---- 구조 대조 (두 팔이 같은 판을 봤는지) ----")
        println("표적 v2 일치     = ", ctl.target_v2 == trt.target_v2,
                "   (", _s(ctl.target_v2), " vs ", _s(trt.target_v2), ")")
        println("후보 간선 수 일치 = ", ctl.ncand == trt.ncand, "   (", ctl.ncand, " vs ", trt.ncand, ")")
        println("제약 행 수 차이   = ", trt.nconstr - ctl.nconstr,
                "   🔴 0 이면 금지가 한 행도 안 걸린 것이다(공허)")
        println("\n---- G-2 판정 ----")
        println("대조(금지 없음) 잃은 작업 = ", ctl.lost, "  ", ctl.lost_slots)
        println("처리(금지 있음) 잃은 작업 = ", trt.lost, "  ", trt.lost_slots)
        # 🔴 판정은 **차집합**이다 — 절대값이 아니다. 대조도 슬롯을 잃을 수 있고(재풀이 잡음),
        #    그 잡음은 양쪽에 공통이라 차집합에서 저절로 지워진다. 남는 것이 금지의 효과다.
        #    (실측: `Pkg.test()` 안에서는 대조가 표적이 **아닌** 슬롯 하나를 잃었다.)
        extra = setdiff(trt.lost_slots, ctl.lost_slots)
        println("처리가 **추가로** 잃은 슬롯 = ", extra, "   (표적 = ", _s(ctl.target_v2), ")")
        println("대조 잃음 ⊆ 처리 잃음 = ", issubset(ctl.lost_slots, trt.lost_slots))
        if ctl.at_target == 0
            println("🔴 VACUOUS — 대조에서도 A 가 표적을 안 집는다. 금지의 효과를 잴 수 없다.")
        elseif extra == [ctl.target_v2] && trt.at_target == 0
            println("🟢 GREEN — 금지가 **정확히 그 화물 하나**를 A 에게서 뗐다 ",
                    "(대조 회수 ", ctl.recovered, "/", ctl.n_released_slots,
                    ", 처리 회수 ", trt.recovered, "/", trt.n_released_slots, ").")
        else
            println("🔴 RED — 차집합이 표적 하나가 아니다. 금지가 노린 것을 못 옮겼거나 ",
                    "다른 것까지 옮겼다.")
        end
    end
    return (board = board, closed = fx.closed, agent = ag.str, verdict = r.verdict,
            steps = r.steps, edges = (length(E0), length(E1)),
            bans = (bans_before, bans_after), control = ctl, treatment = trt,
            vacuous = false, tied_agents = ag.tied)
end

# ── main ─────────────────────────────────────────────────────────────────────
function main()
    boards = if length(ARGS) >= 1
        [(ARGS[1], length(ARGS) >= 2 ? parse(Int, ARGS[2]) : (ARGS[1] == "tractor.mpd" ? 10 : 6),
          length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 60)]
    else
        [("tractor.mpd", 10, 60), ("colored_8x8.ldr", 6, 60)]
    end
    results = Any[]
    for (b, nr, tc) in boards
        push!(results, run_board(b, nr, tc))
    end
    println("\n", "="^92)
    println("G-8 요약표  (🔴 `nothing` = 못 쟀다, 0 이 아니다)")
    println("="^92)
    println(rpad("판", 17), rpad("closed", 8), rpad("verdict", 9), rpad("간선 전/후", 13),
            rpad("금지 전/후", 12), rpad("대조 잃음", 10), rpad("처리 잃음", 10), "재풀이 종료/시간")
    for x in results
        c = x.control; t = x.treatment
        lo_c = (c === nothing || c.status !== :ok) ? nothing : c.lost
        lo_t = (t === nothing || t.status !== :ok) ? nothing : t.lost
        term = (t === nothing || t.status !== :ok) ? "nothing" :
               string(t.tstat, " / ", _r(t.wall, 3), "s")
        println(rpad(x.board, 17), rpad(string(x.closed), 8), rpad(string(x.verdict), 9),
                rpad(string(x.edges[1], "→", x.edges[2]), 13),
                rpad(string(length(x.bans[1]), "→", length(x.bans[2])), 12),
                rpad(_s(lo_c), 10), rpad(_s(lo_t), 10), term)
    end
    CB.clear_all_cargo_bans!()
    return results
end

main()
