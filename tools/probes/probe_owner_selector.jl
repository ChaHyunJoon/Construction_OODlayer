# tools/probes/probe_owner_selector.jl
#   julia +lts --project=. tools/probes/probe_owner_selector.jl [board] [nrobots] [cp1,cp2]
#
# Task 1 (ForbidHeavyCargo). **측정 전용 — production 코드를 한 줄도 안 바꾼다.**
# `ForbidHeavyCargo` 컴파일러가 "이 로봇 소유의 후보 배정"을 찾을 때 쓸 선택자를 측정으로 정한다.
#
#   후보 ①  is_agent_frontier(sched, v, node, agent)   — 기존 ForbidAgent 가 쓰는 것 (compiler.jl:224)
#   후보 ②  _edge_owner_id(sched, v) == agent          — (essential_tg_coponents.jl:1395)
#
# Q1 RESPEC_FROZEN[]/RESPEC_PINNED[] 를 production 과 같게 채우면 frontier 가 몇 개가 되나
# Q2 Xa 를 손에 들고 두 선택자가 각각 몇 개의 (u,v2) 쌍을 만드나 (ForbidAgent 와 글자 그대로 같은 조건)
# Q3 그 쌍들의 도착점 중 **1대당 부담**을 잴 수 있는 것은 몇 개인가
# Q4 그 쌍을 Xa ≤ 0 으로 눌러 풀면 A 가 실제로 그 화물을 잃는가 (모델의 답 + 세계의 답)
#
# 🔴 측정 규율 (이 레포가 각각에 한 번씩 데었다):
#   · 집계는 전부 **함수 안**. 최상위 for 카운터는 Julia soft scope 때문에 조용한 0 이 된다.
#   · 삼상 규약: 못 쟀으면 `nothing`. **0 이 아니다.**
#   · 누른 쌍이 0 이면 `:vacuous` — "A 가 0개 잃었다"를 결론으로 쓰지 않는다.
#   · 반환 심볼은 증거가 아니다. `commit_respec!` 뒤 `binding` 으로 **세계**를 직접 잰다.
#   · `termination_status` 를 항상 같이 찍는다.
#   · 전역(RESPEC_FROZEN/PINNED, INVALID_ID_COUNTERS)은 try/finally 로 복원한다.
#
# ⚠️ 브리프에 없던 두 가지 (보고서에 이유를 적었다):
#   (A) **release 레짐 둘**을 다 잰다. 브리프의 Q2 는 release 를 안 하는데, 그러면 후보 간선이
#       0 이라 두 선택자 모두 공허하게 0 이 될 수 있다(R13 이 예고한 :no_candidates). 그래서
#       `:norelease`(브리프 그대로)와 `:released`(release_pending_assignments! 뒤) 둘 다 잰다.
#   (B) **음성 대조 팔**(`:control`, 아무것도 안 누르고 풀어서 commit). 누르지 않아도 재풀이+commit
#       만으로 binding 이 바뀐다 — 대조 없이는 "A 가 잃었다"가 금지 때문인지 재풀이 잡음인지 못 가른다.
using ConstructionBots, Random, Graphs
using JuMP
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
CB.include(joinpath(pkgdir(CB), "src", "smdp", "mdp.jl"))

const TL = 60.0
const RESULTS_MD = joinpath(pkgdir(CB), ".superpowers", "sdd", "task-1-owner-selector", "results.md")

_s(x) = x === nothing ? "nothing" : string(x)
_r(x, d = 4) = x === nothing ? "nothing" : string(round(x, digits = d))
fork(e) = (x = deepcopy(e); CB.rvo_rebuild!(x); x)

# ── 픽스처 ──────────────────────────────────────────────────────────────────────
"배터리·hazard·에너지 가중치가 켜진 env. (브리프 Step 1 판 — README 판은 include 두 줄이 빠져 죽는다)"
function build_base(board, nr)
    env = CB.run_lego_demo(; ldraw_file = board, project_name = "ownersel", num_robots = nr,
                             assignment_mode = :greedy, n_spare_per_pool = 2,
                             open_animation_at_end = false, save_animation = false,
                             write_results = false, return_env_before_sim = true,
                             rng = Random.MersenneTwister(1))
    CB.enable_battery!(env); CB.enable_hazard!(env; seed = 7); CB.init_objective_weights!()
    return env
end

"""
closed 가 target 에 닿을 때까지 전진. 실제 도달값과 **누적** 스텝 수를 돌려준다(R4).
🔴 M-1 수정: `k` 를 체크포인트마다 0 으로 되돌리면 `set_sim_step!` 이 되감기고, 그러면
   두 번째 체크포인트가 **연속 실행과 다른 세계**(hazard/asset ledger 의 스텝 의존)를 잰다.
   `k0` 를 받아 이어 센다 — 한 보드 안에서 시뮬레이션 스텝은 단조 증가한다.
"""
function step_to!(env, target, k0::Int)
    k = k0
    while length(CB.simstate_of(env).prog.closed) < target && k < 6000
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0); k += 1; CB.set_sim_step!(k)
    end
    return (length(CB.simstate_of(env).prog.closed), k)
end

# ── 전역 ────────────────────────────────────────────────────────────────────────
"`reassign.jl:363-366` 을 글자 그대로. 🔴 새 Set 을 만든다(R12: invariant 를 앨리어싱하지 않는다)."
function set_globals_from!(env)
    sched = env.sched
    closed_ids = Set{CB.AbstractID}(CB.get_vtx_id(sched, v) for v in env.cache.closed_set)
    active_ids = Set{CB.AbstractID}(CB.get_vtx_id(sched, v) for v in env.cache.active_set)
    CB.RESPEC_FROZEN[] = closed_ids
    CB.RESPEC_PINNED[] = union(closed_ids, active_ids)
    return (nfrozen = length(closed_ids), npinned = length(CB.RESPEC_PINNED[]))
end

# ── A 를 고른다 ─────────────────────────────────────────────────────────────────
"떼어질 수 있는(=미래) 배정 간선을 소유한 에이전트별 개수."
function pending_tally(env)
    sched = env.sched; G = CB.get_graph(sched); inv = CB.build_invariant(env)
    act = Set{CB.AbstractID}(CB.get_vtx_id(sched, v) for v in env.cache.active_set)
    t = Dict{String,Int}()
    for e in Graphs.edges(G)
        v, v2 = e.src, e.dst
        CB.is_assignment_edge(sched, v, v2) || continue
        i1 = CB.get_vtx_id(sched, v); i2 = CB.get_vtx_id(sched, v2)
        (i1 in inv.closed_nodes || i2 in inv.closed_nodes || i1 in act || i2 in act) && continue
        o = CB._edge_owner_id(sched, v); o === nothing && continue
        t[string(o)] = get(t, string(o), 0) + 1
    end
    return t
end

"모듈 한정 문자열 → `AbstractID`. 🔴 R5: 못 찾으면 조용히 넘어가지 않고 에러."
function find_agent_id(env, agent_str)
    for v in Graphs.vertices(env.sched)
        o = CB._edge_owner_id(env.sched, v)
        (o !== nothing && string(o) == agent_str) && return o
    end
    error("agent_str 에 해당하는 AbstractID 를 못 찾았다: $(agent_str)")
end

# ── Q1 ──────────────────────────────────────────────────────────────────────────
"`is_agent_frontier` 가 참을 내는 정점 수 (production 호출 모양 그대로: compiler.jl:69-71)."
function count_frontier(env, agent_id)
    n = 0
    for v in Graphs.vertices(env.sched)
        node = CB.get_node_from_id(env.sched, CB.get_vtx_id(env.sched, v))
        CB.is_agent_frontier(env.sched, v, node, agent_id) && (n += 1)
    end
    return n
end

"모든 로봇에 대한 frontier 히스토그램 — A 만 0인지, 전부 0인지를 가른다."
function frontier_by_agent(env)
    sched = env.sched
    ids = Dict{String,Any}()
    for v in Graphs.vertices(sched)
        o = CB._edge_owner_id(sched, v)
        (o !== nothing && o isa CB.BotID) && (ids[string(o)] = o)
    end
    h = Dict{String,Int}()
    for (s, o) in ids
        h[s] = count_frontier(env, o)
    end
    return h
end

"Q1: 전역을 production 과 같게 채우기 전/후의 frontier 크기."
function q1(env, agent_id)
    fb = length(CB.RESPEC_FROZEN[]); pb = length(CB.RESPEC_PINNED[])
    n_before = count_frontier(env, agent_id)
    g = set_globals_from!(env)
    n_after = count_frontier(env, agent_id)
    return (frozen_before = fb, pinned_before = pb, frozen_after = g.nfrozen,
            pinned_after = g.npinned, frontier_before = n_before, frontier_after = n_after,
            by_agent = frontier_by_agent(env))
end

# ── Q2 ──────────────────────────────────────────────────────────────────────────
"""
두 선택자의 (u,v2) 쌍. 조건은 `compile_constraint!(…, ::ForbidAgent)`(compiler.jl:66-83)와
**글자 그대로** 같다: `isassigned_edge(Xa,u,v2)` ∧ `!has_edge(sched,u,v2)`.
🔴 O(V²) 이중 루프를 일부러 그대로 둔다(R6) — 비교의 타당성이 거기서 나온다.
"""
function select_pairs(env, Xa, agent_id, agent_str)
    sched = env.sched
    pf = Tuple{Int,Int}[]; po = Tuple{Int,Int}[]
    fsrc = Dict{String,Int}(); osrc = Dict{String,Int}()   # 출발점 u 의 노드타입 (distinct u)
    fdst = Dict{String,Int}(); odst = Dict{String,Int}()   # 도착점 v2 의 노드타입 (distinct v2)
    fseen = Set{Int}(); oseen = Set{Int}()
    # 🔴 I-5: "쌍이 0" 을 **해석하지 말고 분해해서 측정**한다. 두 사유는 전혀 다르다.
    #    (a) u 가 애초에 후보 간선의 출발점이 아니다      → isassigned_edge 가 어디서도 참이 아님
    #    (b) u 는 후보 출발점인데 전부 확정 간선이라 걸러짐 → isassigned 참이지만 has_edge 도 참
    fz = Dict(:n_u => 0, :u_no_assigned => 0, :u_all_forced => 0, :u_yield => 0,
              :assigned_hits => 0, :forced_skips => 0)
    oz = Dict(:n_u => 0, :u_no_assigned => 0, :u_all_forced => 0, :u_yield => 0,
              :assigned_hits => 0, :forced_skips => 0)
    tname(v) = string(nameof(typeof(CB.get_node_from_id(sched, CB.get_vtx_id(sched, v)))))
    for u in Graphs.vertices(sched)
        node = CB.get_node_from_id(sched, CB.get_vtx_id(sched, u))
        isf = CB.is_agent_frontier(sched, u, node, agent_id)
        own = CB._edge_owner_id(sched, u)
        iso = own !== nothing && string(own) == agent_str
        (isf || iso) || continue
        isf && (fz[:n_u] += 1); iso && (oz[:n_u] += 1)
        n_assigned = 0; n_forced = 0
        hit_f = false; hit_o = false
        for v2 in Graphs.vertices(sched)
            CB.isassigned_edge(Xa, u, v2) || continue
            n_assigned += 1
            if Graphs.has_edge(sched, u, v2)     # 확정 간선은 절대 금지 안 함
                n_forced += 1
                continue
            end
            if isf
                push!(pf, (u, v2)); hit_f = true
                if !(v2 in fseen); push!(fseen, v2); fdst[tname(v2)] = get(fdst, tname(v2), 0) + 1; end
            end
            if iso
                push!(po, (u, v2)); hit_o = true
                if !(v2 in oseen); push!(oseen, v2); odst[tname(v2)] = get(odst, tname(v2), 0) + 1; end
            end
        end
        tn = string(nameof(typeof(node)))
        hit_f && (fsrc[tn] = get(fsrc, tn, 0) + 1)
        hit_o && (osrc[tn] = get(osrc, tn, 0) + 1)
        for (flag, z, hit) in ((isf, fz, hit_f), (iso, oz, hit_o))
            flag || continue
            z[:assigned_hits] += n_assigned; z[:forced_skips] += n_forced
            if hit
                z[:u_yield] += 1
            elseif n_assigned == 0
                z[:u_no_assigned] += 1      # (a) 후보 간선의 출발점이 아니다
            else
                z[:u_all_forced] += 1       # (b) 후보 칸은 있는데 전부 확정 간선이었다
            end
        end
    end
    return (frontier = pf, owner = po,
            f_src_types = fsrc, o_src_types = osrc,
            f_dst_types = fdst, o_dst_types = odst,
            f_ends = collect(fseen), o_ends = collect(oseen),
            f_zero = fz, o_zero = oz)
end

"""
`is_agent_frontier` 의 **관문 하나하나**를 센다(compiler.jl:226-234 의 순서 그대로).
🔴 frontier(A)=0 을 "해석"하지 않고 **어느 관문에서 죽는지**를 측정한다. 특히 `faulted=` release 는
`reassign.jl:217-228` 에서 A 에 묶인 non-closed RobotGo 중 **RobotStart 가 선행인 진짜 원점만 남기고**
전부 무효 id 로 되돌린다 — 그러면 `bound_to_agent` 관문에서 전멸한다.
"""
function frontier_gates(env, aid)
    sched = env.sched
    n_robotgo = 0; n_bound = 0; n_not_frozen = 0; n_pred_ok = 0
    frozen = CB.RESPEC_FROZEN[]; pinned = CB.RESPEC_PINNED[]
    for v in Graphs.vertices(sched)
        node = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        node isa CB.RobotGo || continue
        n_robotgo += 1
        CB.bound_to_agent(node, aid) || continue
        n_bound += 1
        (CB.get_vtx_id(sched, v) in frozen) && continue
        n_not_frozen += 1
        ok = false
        for vp in Graphs.inneighbors(sched, v)
            pnode = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vp))
            if pnode isa CB.RobotStart || (CB.get_vtx_id(sched, vp) in pinned)
                ok = true; break
            end
        end
        ok && (n_pred_ok += 1)
    end
    return (robotgo = n_robotgo, bound_to_A = n_bound,
            not_frozen = n_not_frozen, pred_ok = n_pred_ok)   # pred_ok == frontier(A)
end

"선택자가 집은 출발점 u 자체의 노드타입(쌍이 0개여도 보인다) — 두 답이 갈리는 이유가 여기 있다."
function selector_source_types(env, agent_id, agent_str)
    sched = env.sched
    fs = Dict{String,Int}(); os = Dict{String,Int}()
    for u in Graphs.vertices(sched)
        node = CB.get_node_from_id(sched, CB.get_vtx_id(sched, u))
        tn = string(nameof(typeof(node)))
        CB.is_agent_frontier(sched, u, node, agent_id) && (fs[tn] = get(fs, tn, 0) + 1)
        own = CB._edge_owner_id(sched, u)
        (own !== nothing && string(own) == agent_str) && (os[tn] = get(os, tn, 0) + 1)
    end
    return (frontier = fs, owner = os)
end

# ── Q3 ──────────────────────────────────────────────────────────────────────────
"""
슬롯 `v2` 한 홉 뒤 화물의 **1대당 부담** `m_payload / 팀크기`. 못 재면 `nothing`(0 이 아니다).
⚠️ R9: 브리프의 `inner = try node.node catch; node end` 는 항상 `inner === node` 다
(`get_node_from_id` 가 이미 언랩된 술어를 준다) — 래퍼가 있다는 증거로 읽지 말 것.
"""
function burden_at(env, v2, p)
    for v in Graphs.outneighbors(env.sched, v2)
        inner = CB.get_node_from_id(env.sched, CB.get_vtx_id(env.sched, v))
        m = try CB._payload_mass_measured(env, inner, p) catch; continue end
        t = try length(CB.robot_team(inner)) catch; continue end
        t > 0 && return (m / t, v)     # 부담, 그리고 그 부담을 잰 **화물 노드**의 정점번호
    end
    return (nothing, nothing)
end
burden(env, v2, p) = burden_at(env, v2, p)[1]

"부담 내림차순, 동점이면 v2 오름차순. 🔴 I-4: 동점이 만연하므로 tie-break 를 **결정적으로** 못박는다."
_rank(vals) = sort(collect(vals), by = x -> (-x[2], x[1]))

"도착점 집합의 부담 측정 비율. 못 잰 것은 왜 못 쟀는지 표본을 남긴다."
function burden_ratio(env, ends, p; nsample = 3)
    ends = collect(ends)
    isempty(ends) && return (n = 0, nmeas = 0, ratio = nothing, samples = String[])
    nmeas = 0; vals = Tuple{Int,Float64,Int}[]
    fails = String[]
    for v2 in ends
        b, cv = burden_at(env, v2, p)
        if b === nothing
            if length(fails) < nsample
                push!(fails, burden_diag(env, v2, p))
            end
        else
            nmeas += 1; push!(vals, (v2, b, cv))
        end
    end
    # 🔴 I-4: "부담 상위 N" 이 well-defined 인지 **측정**한다. 최대값에 여럿이 묶여 있으면
    #    `sort(...)[1]` 은 Set 순회 순서가 고르는 것이고 "가장 무거운 것"이 아니다.
    bs = [b for (_, b, _) in vals]
    bmax = isempty(bs) ? nothing : maximum(bs)
    nties = bmax === nothing ? 0 : count(b -> isapprox(b, bmax; rtol = 1e-12), bs)
    rounded = [round(b, digits = 6) for b in bs]
    hist = Dict{Float64,Int}()
    for b in rounded; hist[b] = get(hist, b, 0) + 1; end
    top = sort(collect(hist), by = kv -> -kv[1])[1:min(5, length(hist))]
    return (n = length(ends), nmeas = nmeas, ratio = nmeas / length(ends),
            vals = vals, samples = fails,
            bmax = bmax, nties = nties, ndistinct = length(hist), top = top)
end

"burden 이 왜 실패했는지 — v2 자신과 한 홉 뒤 이웃들의 노드타입/실패 사유."
function burden_diag(env, v2, p)
    sched = env.sched
    own = string(nameof(typeof(CB.get_node_from_id(sched, CB.get_vtx_id(sched, v2)))))
    parts = String[]
    for v in Graphs.outneighbors(sched, v2)
        inner = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        tn = string(nameof(typeof(inner)))
        why = try
            CB._payload_mass_measured(env, inner, p)
            try
                t = length(CB.robot_team(inner))
                t > 0 ? "OK(team=$t)" : "team=0"
            catch e
                "robot_team:" * string(nameof(typeof(e)))
            end
        catch e
            "mass:" * string(nameof(typeof(e)))
        end
        push!(parts, "$tn/$why")
    end
    isempty(parts) && (parts = ["<outneighbors 0개>"])
    return "v2=$v2($own) → " * join(parts, ", ")
end

# ── Q4 ──────────────────────────────────────────────────────────────────────────
"""
한 팔. `selector ∈ (:control, :frontier, :owner)`.
`:control` 은 **아무것도 안 누르고** 풀어서 commit 한다 — 재풀이+commit 자체가 만드는 binding
변동(잡음 바닥)을 재기 위해서다. 이 대조가 없으면 "A 가 잃었다"가 금지 때문인지 잡음인지 못 가른다.
"""
function q4_arm!(env, agent_str, aid, selector::Symbol, p; target_v2 = nothing, watch = Tuple{Int,Int}[], label::Symbol = selector)
    # 🔴 `aid` 를 **밖에서 받는다**. `faulted=` release 는 A 의 노드 id 를 무효로 되돌릴 수 있어서
    #    release 뒤에 `find_agent_id` 를 부르면 조용히 못 찾거나 다른 답을 낸다.
    set_globals_from!(env)
    inv = CB.build_invariant(env)
    before = copy(CB.simstate_of(env).g.binding)
    akey = CB._int_key(aid)
    a_before = count(v -> get(before, v, -1) == akey, collect(keys(before)))

    sent = Dict{Tuple{Int,Int},Float64}(); CB.LAST_EDGE_COSTS[] = sent
    milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
                             optimizer = CB._respec_optimizer(),
                             t0_ = inv.frozen_t0, tF_ = inv.frozen_tF)
    CB.LAST_EDGE_COSTS[] === sent && return (status = :no_formulate, selector = label)
    ec = copy(CB.LAST_EDGE_COSTS[]); Xa = milp.Xa
    ncand = length(ec)

    npinned = 0; topv2 = nothing; topb = nothing; npairs = 0; nends = 0
    if selector !== :control
        sel = select_pairs(env, Xa, aid, agent_str)
        pairs = selector === :frontier ? sel.frontier : sel.owner
        ends = selector === :frontier ? sel.f_ends : sel.o_ends
        npairs = length(pairs); nends = length(ends)
        if npairs == 0
            return (status = :vacuous_zero_pairs, selector = label, ncand = ncand,
                    npairs = 0, nends = 0, npinned = 0)
        end
        br = burden_ratio(env, ends, p)
        if br.nmeas == 0
            return (status = :vacuous_no_burden_endpoint, selector = label, ncand = ncand,
                    npairs = npairs, nends = nends, npinned = 0, samples = br.samples)
        end
        vals = _rank(br.vals)   # 부담 상위 N = 1. 🔴 동점은 v2 오름차순으로 **결정적** tie-break
        if target_v2 === nothing
            topv2, topb, _cv = vals[1]
        else
            # 🔴 표적을 밖에서 못박는다 — 팔끼리 **같은 도착점**을 봐야 대조가 성립한다.
            topv2 = target_v2
            j = findfirst(x -> x[1] == target_v2, vals)
            topb = j === nothing ? nothing : vals[j][2]
        end
        for (u, v2) in pairs
            v2 == topv2 || continue
            JuMP.set_upper_bound(Xa[u, v2], 0.0)
            npinned += 1
        end
        if npinned == 0
            return (status = :vacuous_zero_pinned, selector = label, ncand = ncand,
                    npairs = npairs, nends = nends, npinned = 0)
        end
    end

    CB.set_time_limit_sec(milp, TL)
    wall = @elapsed CB.optimize!(milp)
    ts = CB.termination_status(milp); ps = CB.primal_status(milp)
    if ps != CB.MOI.FEASIBLE_POINT
        return (status = :no_incumbent, selector = label, ncand = ncand, npairs = npairs,
                nends = nends, npinned = npinned, tstat = ts, pstat = ps, wall = wall,
                topv2 = topv2, topb = topb)
    end
    obj = try JuMP.objective_value(milp.model) catch; nothing end

    # (a) 모델의 답 — commit 불필요. 후보 간선 중 해가 고른 것을 _edge_owner_id 로 귀속.
    #     🔴 `watch` 는 **모든 팔이 같은 도착점**을 보게 한다. 대조 팔도 같은 v2 를 본다 —
    #        "안 눌렀을 때 A 가 몇 개 집는가" 가 없으면 "눌렀더니 0" 은 정보가 0이다.
    a_sel = 0; at_top = 0; a_v2 = Int[]
    watch_a = Dict{Int,Int}(); watch_owner = Dict{Int,Vector{String}}()
    wset = Set{Int}()
    for (wv2, _cv) in watch
        watch_a[wv2] = 0; watch_owner[wv2] = String[]; push!(wset, wv2)
    end
    for (u, v2) in keys(ec)
        JuMP.value(Xa[u, v2]) > 0.5 || continue
        o = CB._edge_owner_id(env.sched, u)
        os = o === nothing ? nothing : string(o)
        if v2 in wset
            push!(watch_owner[v2], os === nothing ? "nothing" : os)
            (os !== nothing && os == agent_str) && (watch_a[v2] += 1)
        end
        (os !== nothing && os == agent_str) || continue
        a_sel += 1; push!(a_v2, v2)
        (topv2 !== nothing && v2 == topv2) && (at_top += 1)
    end

    # (b) 세계의 답 — commit 필요 (R1). optimize! 만으로는 env 가 안 바뀐다.
    ok = CB.commit_respec!(env, milp,
            CB.RespecProposal(CB.ConstraintSpec[], "owner-selector probe", "probe"); resume = true)
    if ok === false
        return (status = :commit_failed, selector = label, ncand = ncand, npairs = npairs,
                nends = nends, npinned = npinned, tstat = ts, pstat = ps, wall = wall,
                obj = obj, a_sel = a_sel, at_top = at_top, topv2 = topv2, topb = topb)
    end
    after = CB.simstate_of(env).g.binding
    lost = count(v -> get(before, v, -1) == akey && get(after, v, -1) != akey, collect(keys(before)))
    nreass = count(v -> get(before, v, -1) != get(after, v, -1),
                   collect(union(keys(before), keys(after))))
    # 🔴 "A 가 **그 화물**을 잃었는가" — binding 을 그 화물 노드에서 직접 읽는다.
    cargo_bind = Dict{Int,Tuple{Int,Int}}()
    for (wv2, cv) in watch
        cargo_bind[wv2] = (get(before, cv, -1), get(after, cv, -1))
    end
    mk = try CB.makespan(env.sched) catch; nothing end
    return (status = :ok, selector = label, ncand = ncand, npairs = npairs, nends = nends,
            npinned = npinned, tstat = ts, pstat = ps, wall = wall, obj = obj,
            a_sel = a_sel, at_top = at_top, topv2 = topv2, topb = topb, a_v2 = a_v2,
            watch_a = watch_a, watch_owner = watch_owner,
            cargo_bind = cargo_bind, akey = akey, target_v2 = target_v2,
            a_before = a_before, lost = lost, nreass = nreass, mk = mk)
end

# ── 레짐 하나(= release 여부) 를 통째로 측정 ─────────────────────────────────────
"""
레짐 하나의 env 를 만든다. 🔴 **C-1 수정**: 앞 판은 `:released`(전체 release) 하나만 쟀는데,
그 keep 규칙(`reassign.jl:175`)은 **active 인 v 의 out-edge 를 유지**하므로 그 v 는 포화 상태로
남고(`outdegree == n_eligible_successors`), 따라서 **후보 Big-M 간선의 출발점이 될 수 없다**
(`essential_tg_coponents.jl:1119`). `is_agent_frontier` 는 바로 그 active v 를 집으므로
**frontier 쌍 0 은 구조적으로 보장된 값**이었다 — 선택자의 성질이 아니라 release 범위의 성질이다.

`ForbidAgent` 를 실제로 컴파일하는 유일한 production 경로는 `reassign.jl:416`
`release_pending_assignments!(env, invariant; faulted = agent)` 다. 그 규칙(`reassign.jl:173`)은
A 에 묶인 간선에 대해 `in_closed` 만 유지 ⟹ **A 의 진행 중 간선(= frontier 노드의 out-edge)을 뗀다.**
그래서 `:released_faulted` 를 반드시 함께 잰다.

`:released_scoped` 는 `agent=` (b20c01ab 이 추가) — 좁은 release 라 수렴이 빠르다(I-3).
🔴 `faulted` 와 `agent` 는 **동시에 못 준다**(reassign.jl:154-158 가 던진다).
"""
function make_regime_env(base, regime::Symbol, agent_str, aid)
    regime === :norelease && return (base, 0)
    renv = fork(base)
    # production 은 전역을 **release 이전에** 채운다(reassign.jl:407-410 → :416). 그 순서를 지킨다.
    set_globals_from!(renv)
    inv = CB.build_invariant(renv)
    rem = if regime === :released
        CB.release_pending_assignments!(renv, inv)
    elseif regime === :released_faulted
        CB.release_pending_assignments!(renv, inv; faulted = aid)      # 🔴 production 경로
    elseif regime === :released_scoped
        CB.release_pending_assignments!(renv, inv; agent = agent_str)  # 좁힌 release (b20c01ab)
    else
        error("알 수 없는 regime: $regime")
    end
    return (renv, length(rem))
end

function measure_regime(base, regime::Symbol, agent_str, aid, p)
    renv, nreleased = make_regime_env(base, regime, agent_str, aid)
    set_globals_from!(renv)
    inv = CB.build_invariant(renv)

    sent = Dict{Tuple{Int,Int},Float64}(); CB.LAST_EDGE_COSTS[] = sent
    milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), renv.sched, renv.scene_tree;
                             optimizer = CB._respec_optimizer(),
                             t0_ = inv.frozen_t0, tF_ = inv.frozen_tF)
    CB.LAST_EDGE_COSTS[] === sent && error("formulate 가 안 돌았다 — 못 쟀다 ($regime)")
    ncand = length(CB.LAST_EDGE_COSTS[])
    sel = select_pairs(renv, milp.Xa, aid, agent_str)
    styp = selector_source_types(renv, aid, agent_str)
    gates = frontier_gates(renv, aid)
    bf = burden_ratio(renv, sel.f_ends, p)
    bo = burden_ratio(renv, sel.o_ends, p)
    # 각 선택자의 **부담 상위 1** 도착점 (v2, burden, cargo_v). 모든 팔이 이걸 같이 본다.
    topf = (haskey(bf, :vals) && !isempty(bf.vals)) ? _rank(bf.vals)[1] : nothing
    topo = (haskey(bo, :vals) && !isempty(bo.vals)) ? _rank(bo.vals)[1] : nothing
    return (regime = regime, env = renv, nreleased = nreleased, ncand = ncand,
            sel = sel, styp = styp, bf = bf, bo = bo, topf = topf, topo = topo, gates = gates)
end

function print_regime(m)
    println("  ── regime = ", m.regime, "  (release 된 간선 ", m.nreleased, "개)")
    println("     후보 간선(LAST_EDGE_COSTS) ncand = ", m.ncand,
            m.ncand == 0 ? "   🔴 :no_candidates — MILP 가 순수 makespan 으로 후퇴. 금지는 무동작이 정상(R13)" : "")
    println("     선택자가 집은 **출발점 u** 타입: frontier=", m.styp.frontier, "  owner=", m.styp.owner)
    println("     Q2 쌍 수:  frontier=", length(m.sel.frontier), "  owner=", length(m.sel.owner))
    println("        출발점 타입(쌍≥1): frontier=", m.sel.f_src_types, "  owner=", m.sel.o_src_types)
    println("        도착점 타입(distinct): frontier=", m.sel.f_dst_types, "  owner=", m.sel.o_dst_types)
    println("     Q3 부담 측정:  frontier=", m.bf.nmeas, "/", m.bf.n, " (", _r(m.bf.ratio, 3), ")",
            "   owner=", m.bo.nmeas, "/", m.bo.n, " (", _r(m.bo.ratio, 3), ")")
    # I-4: "상위 N" 이 well-defined 인가 — 최대값 동점 수와 분포
    for (nm, br) in (("frontier", m.bf), ("owner", m.bo))
        haskey(br, :bmax) && br.bmax !== nothing || continue
        println("        [", nm, " 부담 분포] max=", _r(br.bmax), "  **최대값 동점 ", br.nties, "/", br.nmeas,
                "개**  서로 다른 값 ", br.ndistinct, "개  상위=", br.top,
                br.nties > 1 ? "   🔴 상위1 은 Set 순회 순서가 고른다 — well-defined 아님" : "")
    end
    println("     [frontier 관문] RobotGo=", m.gates.robotgo, " → A 에 묶임=", m.gates.bound_to_A,
            " → 안 얼음=", m.gates.not_frozen, " → 선행 OK(=frontier(A))=", m.gates.pred_ok)
    # I-5: 쌍 0 을 해석하지 말고 분해해서 본다
    for (nm, z) in (("frontier", m.sel.f_zero), ("owner", m.sel.o_zero))
        println("        [", nm, " 영(0) 분해] 집은 u=", z[:n_u],
                "  · 후보칸 아예 없음=", z[:u_no_assigned],
                "  · 후보칸 있으나 전부 확정간선=", z[:u_all_forced],
                "  · 쌍 만듦=", z[:u_yield],
                "   (isassigned 히트 ", z[:assigned_hits], ", 그중 has_edge 로 스킵 ", z[:forced_skips], ")")
    end
    for s in m.bf.samples; println("        [frontier 못 잰 표본] ", s); end
    for s in m.bo.samples; println("        [owner 못 잰 표본]    ", s); end
end

function print_arm(r)
    if r.status !== :ok
        println("     [Q4 ", r.selector, "] ", r.status,
                "  npairs=", get(r, :npairs, "?"), " nends=", get(r, :nends, "?"),
                " npinned=", get(r, :npinned, "?"), " ncand=", get(r, :ncand, "?"),
                " term=", _s(get(r, :tstat, nothing)))
        for s in get(r, :samples, String[]); println("        [못 잰 표본] ", s); end
        return
    end
    println("     [Q4 ", r.selector, "] npinned=", r.npinned, " (쌍=", r.npairs, ", 도착점=", r.nends, ")",
            "  top v2=", _s(r.topv2), " burden=", _r(r.topb),
            "  term=", r.tstat, " primal=", r.pstat, " wall=", _r(r.wall, 2), "s")
    println("               모델측: A 소유 후보간선 선택 ", r.a_sel, "개 (top v2 로 가는 것 ", r.at_top, "개)",
            "  obj=", _r(r.obj, 6))
    println("               세계측(commit 후): A 가 잃은 작업 ", r.lost, " / A 가 갖고 있던 ", r.a_before,
            "   전체 재배정 ", r.nreass, "   makespan=", _r(r.mk))
    for nm in sort(collect(keys(r.watch_a)))
        bb, ba = r.cargo_bind[nm]
        println("               표적 v2=", nm, ": 해가 그 v2 로 준 A 간선=", r.watch_a[nm],
                " (그 v2 를 가져간 소유자=", isempty(r.watch_owner[nm]) ? "없음" : join(r.watch_owner[nm], ","), ")",
                "  화물노드 binding ", bb, "→", ba, "  (A=", r.akey, ")",
                (bb == r.akey && ba != r.akey) ? "  🔴 A 가 그 화물을 잃었다" :
                (bb == r.akey && ba == r.akey) ? "  A 가 그 화물을 지켰다" : "  (그 화물은 애초에 A 것이 아니었다)")
    end
end

# ── 한 체크포인트 ────────────────────────────────────────────────────────────────
"""
`INVALID_ID_COUNTERS` 를 한 팔 동안만 빌려 쓰고 **정확히** 되돌린다.
🔴 M-2 수정: 앞 판은 (a) release **이전**의 스냅샷으로 되돌렸고 (b) `merge!` 만 써서 팔이
   **새로 추가한 키를 지우지 않았다**. 그러면 다음 팔의 commit 이 같은 음수 id 를 다시 발급해
   충돌한다. `empty!` + `merge!` 로 스냅샷과 **동일한 상태**로 복원한다.
"""
function with_restored_counters(f)
    snap = copy(CB.INVALID_ID_COUNTERS)
    try
        return f()
    finally
        empty!(CB.INVALID_ID_COUNTERS); merge!(CB.INVALID_ID_COUNTERS, snap)
    end
end

const HH_MAX = 3   # 머리맞대기 표적 상한(대조에서 A 가 가져간 도착점 중 부담 상위 HH_MAX)


"""
한 레짐의 Q4. 🔴 **N-1 수정**: 앞 판은 표적 두 개만 잡고 그 위에서 기전을 주장했는데, 내
`results.md` 안의 다른 행들이 그 주장을 반박했다(전체 release 에서는 frontier 핀 1개로도 A 가
표적을 잃었다). 그래서 이제 **표적 × 선택자 전수 머리맞대기**를 돌리고, **전체 표가 지지하는
주장만** 쓴다. 팔마다 obj·makespan 을 함께 들고 나온다(N-2).

절차:
1. 대조 팔을 **모든 공통 도착점**(두 선택자가 다 잡고 부담을 잰 v2)을 보며 푼다.
2. 표적 = (대조에서 A 가 가져간 공통 도착점, 부담 상위 HH_MAX) ∪ (공통 도착점 중 부담 최대).
3. 표적마다 frontier·owner 를 **같은 표적·같은 상한**으로 눌러 각각 푼다.
"""
function q4_regime!(m, agent_str, aid, p)
    nf = length(m.sel.frontier); no = length(m.sel.owner)
    bmap = Dict{Int,Tuple{Float64,Int}}()
    # 🔴 `burden_ratio` 는 도착점이 0개면 `vals` 키 자체가 없다(빈-통과 방지). haskey 로 막는다.
    for br in (m.bf, m.bo)
        haskey(br, :vals) || continue
        for (v2, b, cv) in br.vals; bmap[v2] = (b, cv); end
    end
    fset = Set(m.sel.f_ends); oset = Set(m.sel.o_ends)
    # 🔴 N-1 수정: 표적을 **합집합**에서 뽑는다. 교집합에서만 뽑으면 frontier 가 못 닿는 표적이
    #    표에서 통째로 사라지고, 그러면 "덮지 못한다"는 주장이 **증거 없이** 남는다. 합집합으로
    #    뽑고 각 칸마다 `:no_pair_into_target` 을 명시하면 커버리지 자체가 측정값이 된다.
    allends = sort([v2 for v2 in union(fset, oset) if haskey(bmap, v2)])
    common = sort([v2 for v2 in intersect(fset, oset) if haskey(bmap, v2)])
    # 선택자별로 "이 표적으로 들어가는 쌍" 을 미리 센다
    fin = Dict{Int,Int}(); oin = Dict{Int,Int}()
    for (_, v2) in m.sel.frontier; fin[v2] = get(fin, v2, 0) + 1; end
    for (_, v2) in m.sel.owner;    oin[v2] = get(oin, v2, 0) + 1; end
    println("  ── Q4 [", m.regime, "]  (TL=", TL, "s, 팔마다 새 fork + 새 formulate)")
    println("     도착점: frontier=", length(fset), " owner=", length(oset),
            " 합집합(부담 잼)=", length(allends), " 교집합=", length(common))

    watch0 = [(v2, bmap[v2][2]) for v2 in allends]
    ctrl = with_restored_counters() do
        q4_arm!(fork(m.env), agent_str, aid, :control, p; watch = watch0)
    end
    print_arm(ctrl)
    arms = Any[ctrl]; hh = Any[]

    if ctrl.status !== :ok
        println("     🔴 대조 팔이 ", ctrl.status, " — 머리맞대기 불가(표적을 정할 수 없다).")
        return (arms = arms, hh = hh, hh_skip = :control_failed, ncommon = length(common))
    end
    if isempty(allends)
        println("     🔴 표적 0 — 두 선택자 모두 부담을 잰 도착점이 없다.")
        return (arms = arms, hh = hh, hh_skip = :no_endpoint_with_burden, ncommon = 0)
    end

    took = Set(ctrl.a_v2)
    ranked_took = _rank([(v2, bmap[v2][1], bmap[v2][2]) for v2 in allends if v2 in took])
    ranked_all  = _rank([(v2, bmap[v2][1], bmap[v2][2]) for v2 in allends])
    targets = Tuple{Int,Float64,Int}[]
    for t in ranked_took[1:min(HH_MAX, length(ranked_took))]; push!(targets, t); end
    isempty(ranked_all) || (ranked_all[1][1] in (x[1] for x in targets)) ||
        push!(targets, ranked_all[1])
    if isempty(ranked_took)
        println("     ⚠️ 대조 해에서 A 가 가져간 공통 도착점 0개 — 표적은 부담 최대 하나뿐이고, ",
                "그 위의 \"A→0\" 은 **항진**이다(금지의 효과가 아니다).")
    end
    println("     표적 ", length(targets), "개: ",
            join(["v2=$(t[1])(b=$(_r(t[2])),대조에서 A가 " * (t[1] in took ? "가져감" : "안가져감") * ")"
                  for t in targets], ", "))

    for (v2, b, cv) in targets
        for selector in (:frontier, :owner)
            nin = selector === :frontier ? get(fin, v2, 0) : get(oin, v2, 0)
            if nin == 0
                # 🔴 이 칸의 사유는 "쌍 0" 이 아니라 **"이 표적으로 들어가는 쌍이 0"** 이다(N-3).
                why = (selector === :frontier ? nf : no) == 0 ? :selector_has_no_pair_at_all :
                      :no_pair_into_target
                println("     [Q4 ", selector, " @v2=", v2, "] ", why, " — 이 표적을 못 막는다.")
                push!(hh, (regime = m.regime, target = v2, burden = b, selector = selector,
                           status = why, ctrl_took = (v2 in took),
                           ctrl_a = get(ctrl.watch_a, v2, nothing),
                           ctrl_win = join(get(ctrl.watch_owner, v2, String[]), "/"),
                           ctrl_obj = ctrl.obj, ctrl_mk = ctrl.mk))
                continue
            end
            r = with_restored_counters() do
                q4_arm!(fork(m.env), agent_str, aid, selector, p;
                        target_v2 = v2, watch = [(v2, cv)], label = selector)
            end
            print_arm(r)
            push!(arms, r)
            push!(hh, (regime = m.regime, target = v2, burden = b, selector = selector,
                       status = r.status, ctrl_took = (v2 in took),
                       ctrl_a = get(ctrl.watch_a, v2, nothing),
                       ctrl_win = join(get(ctrl.watch_owner, v2, String[]), "/"),
                       ctrl_obj = ctrl.obj, ctrl_mk = ctrl.mk,
                       npinned = get(r, :npinned, nothing), tstat = get(r, :tstat, nothing),
                       a_at = r.status === :ok ? get(r.watch_a, v2, nothing) : nothing,
                       winner = r.status === :ok ? join(get(r.watch_owner, v2, String[]), "/") : "",
                       obj = get(r, :obj, nothing), mk = get(r, :mk, nothing),
                       lost = get(r, :lost, nothing), wall = get(r, :wall, nothing)))
        end
    end
    return (arms = arms, hh = hh, hh_skip = nothing, ncommon = length(common))
end

const REGIMES = (:norelease, :released, :released_faulted, :released_scoped)

function measure_checkpoint(base, board, nr, target, p, rows, k0::Int)
    closed, k = step_to!(base, target, k0)
    nv = Graphs.nv(base.sched)
    println("\n", "="^92)
    println("BOARD=", board, "  robots=", nr, "  target_closed=", target,
            "  🔴 실제 도달 closed=", closed, " / nv=", nv, "  (누적 sim step=", k, ")")

    tally = pending_tally(base)
    if isempty(tally)
        println("  🔴 미래 배정 간선 0 — 재분배 창이 닫혔다. 이 판은 :window_closed.")
        push!(rows, (board = board, nr = nr, target = target, closed = closed, nv = nv,
                     status = :window_closed, agent = nothing))
        return k
    end
    ranked = sort(collect(tally), by = kv -> -kv[2])
    agent_str = ranked[1][1]
    aid = find_agent_id(base, agent_str)     # 🔴 release 이전에 확정한다 (faulted 가 id 를 지운다)
    println("  A = ", agent_str, "  (해제가능 간선 ", ranked[1][2], "개, 전체 소유자 ", length(tally), "명)")

    # ── Q1 ──
    r1 = q1(base, aid)
    println("  Q1  전역 채우기 전: FROZEN=", r1.frozen_before, " PINNED=", r1.pinned_before,
            "  → frontier(A) = ", r1.frontier_before)
    println("      전역 채운 후:   FROZEN=", r1.frozen_after, " PINNED=", r1.pinned_after,
            "  → frontier(A) = ", r1.frontier_after)
    println("      전 로봇 frontier 히스토그램: ", sort(collect(r1.by_agent), by = kv -> -kv[2]))

    with_restored_counters() do
        for regime in REGIMES
            m = measure_regime(base, regime, agent_str, aid, p)
            print_regime(m)
            nf = length(m.sel.frontier); no = length(m.sel.owner)
            q = if nf == 0 && no == 0
                println("  ── Q4 [", m.regime, "] :vacuous — 두 선택자 모두 쌍 0개. 풀지 않는다.")
                (arms = Any[], hh = Any[], hh_skip = :both_selectors_zero_pairs, ncommon = 0)
            else
                q4_regime!(m, agent_str, aid, p)
            end
            push!(rows, (board = board, nr = nr, target = target, closed = closed, nv = nv,
                         status = (nf == 0 && no == 0) ? :vacuous : :measured,
                         agent = agent_str, regime = m.regime, q1 = r1,
                         ncand = m.ncand, nreleased = m.nreleased,
                         nf = nf, no = no, bf = m.bf, bo = m.bo, styp = m.styp, sel = m.sel,
                         gates = m.gates, arms = q.arms, hh = q.hh,
                         hh_skip = q.hh_skip, ncommon = q.ncommon))
        end
    end
    return k
end

# ── results.md ──────────────────────────────────────────────────────────────────
# (arm_cell 삭제: N-3 — 없는 팔을 전부 "쌍 0" 으로 오귀속했다. 표 3/3b 가 사유를 직접 찍는다.)

function write_results(rows, cmd)
    io = IOBuffer()
    println(io, "# Task 1 — owner-selector 측정 결과 (raw)")
    println(io)
    println(io, "생성: `", cmd, "`  ·  ", string(Dates_now()))
    println(io)
    println(io, "**근거 커밋: `", git_head(), "`** (프로브 프로세스가 로드한 소스).")
    println(io)
    println(io, "🔴 삼상 규약: `nothing` = 못 쟀다(0 이 아니다). `:vacuous*` = 누른 쌍이 0 이라 판정 불가.")
    println(io, "🔴 `closed` 는 **실제 도달값**이다(target 이 아니다, R4).")
    println(io, "🔴 `regime` 넷:")
    println(io, "- `norelease` — 브리프 그대로(release 없음). 네 판 모두 `ncand=0` → `:no_candidates`(R13).")
    println(io, "- `released` — 전체 release. **`is_agent_frontier` 의 쌍 0 이 구조적으로 보장되는 레짐**")
    println(io, "  (active 인 v 의 out-edge 를 유지 ⇒ v 가 포화 ⇒ 후보 Big-M 간선의 출발점이 될 수 없음).")
    println(io, "- **`released_faulted` — `faulted=A`. `ForbidAgent` 를 컴파일하는 유일한 production 경로**")
    println(io, "  (`reassign.jl:416`). ⚠️ **측정 결과 이 레짐은 두 선택자 모두 쌍 0 이라 아무것도 판정할 수 없다**")
    println(io, "  (표 4c: `안 얼음 = 0`). 그러므로 **선택자 판정은 여기서 못 한다** — 이 레짐 자체가 결과다.")
    println(io, "- 🔴 **선택자 판정은 `released` · `released_scoped` 의 표 3(머리맞대기)에서 한다.**")
    println(io, "  그 둘이 두 선택자가 동시에 비어 있지 않은 유일한 레짐이다.")
    println(io, "- `released_scoped` — `agent=A`(커밋 `b20c01ab` 이 추가한 좁힌 release). 수렴이 빠르다.")
    println(io, "🔴 `control` 팔은 **아무것도 안 누르고** 풀어 commit 한 음성 대조다 — 재풀이 잡음의 바닥.")
    println(io)
    println(io, "## 표 1 — Q1 / Q2 / Q3")
    println(io)
    println(io, "| 판 | robots | target | **실제 closed** | nv | A | regime | released | ncand | Q1 frontier 전/후 (체크포인트 단위, `base` 1회 측정 — regime 별 값은 표 4c) | **Q2 frontier 쌍** | **Q2 owner 쌍** | Q3 frontier 부담 | Q3 owner 부담 |")
    println(io, "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in rows
        if r.status === :window_closed
            println(io, "| ", r.board, " | ", r.nr, " | ", r.target, " | **", r.closed, "** | ", r.nv,
                    " | — | — | — | — | — | — | — | — | — |")
            continue
        end
        println(io, "| ", r.board, " | ", r.nr, " | ", r.target, " | **", r.closed, "** | ", r.nv,
                " | `", r.agent, "` | ", r.regime, " | ", r.nreleased, " | ", r.ncand,
                " | ", r.q1.frontier_before, " / ", r.q1.frontier_after,
                " | ", r.nf, " | ", r.no,
                " | ", r.bf.nmeas, "/", r.bf.n, " (", _r(r.bf.ratio, 3), ")",
                " | ", r.bo.nmeas, "/", r.bo.n, " (", _r(r.bo.ratio, 3), ") |")
    end
    println(io)
    println(io, "## 표 2 — 노드타입 히스토그램 (R11)")
    println(io)
    println(io, "| 판 | closed | regime | frontier 가 집은 u 타입 | owner 가 집은 u 타입 | frontier 쌍의 도착점 타입 | owner 쌍의 도착점 타입 |")
    println(io, "|---|---|---|---|---|---|---|")
    for r in rows
        r.status === :window_closed && continue
        println(io, "| ", r.board, " | ", r.closed, " | ", r.regime,
                " | `", r.styp.frontier, "` | `", r.styp.owner, "`",
                " | `", r.sel.f_dst_types, "` | `", r.sel.o_dst_types, "` |")
    end
    println(io)
    println(io, "## 표 3 — Q4 **전수 머리맞대기** (표적 × 선택자, 같은 표적·같은 상한)")
    println(io)
    println(io, "표적 = (대조 해에서 A 가 가져간 도착점 중 부담 상위 ", HH_MAX, ") ∪ (도착점 중 부담 최대).")
    println(io, "도착점 풀은 **두 선택자의 합집합**이다 — 교집합만 쓰면 frontier 가 못 닿는 표적이 표에서")
    println(io, "통째로 사라져 \"덮지 못한다\"가 증거 없이 남는다. 못 닿으면 그 칸에 사유를 찍는다:")
    println(io, "`selector_has_no_pair_at_all`(그 레짐에서 쌍이 0) / `no_pair_into_target`(쌍은 있으나 이 v2 로는 0).")
    println(io)
    println(io, "🔴 `대조 A→v2` 가 0 이면 그 표적의 \"금지 후 A→0\" 은 **항진**이다 — 금지의 효과가 아니다.")
    println(io, "판정에 쓸 수 있는 행은 **`대조 A→v2 ≥ 1`** 인 행뿐이다.")
    println(io)
    println(io, "| 판 | closed | regime | 표적 v2 | burden | **대조 A→v2** | 대조가 준 쪽 | 선택자 | npinned | term | **금지 후 A→v2** | 대신 가져간 쪽 | obj (대조→금지) | makespan (대조→금지) | lost |")
    println(io, "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    any_hh = false
    for r in rows
        r.status === :window_closed && continue
        for h in get(r, :hh, Any[])
            any_hh = true
            if h.status !== :ok
                println(io, "| ", r.board, " | ", r.closed, " | ", h.regime, " | ", h.target,
                        " | ", _r(h.burden), " | ", _s(h.ctrl_a), " | `", h.ctrl_win, "`",
                        " | ", h.selector, " | — | — | — | — | — | — | `", h.status, "` |")
                continue
            end
            println(io, "| ", r.board, " | ", r.closed, " | ", h.regime, " | ", h.target,
                    " | ", _r(h.burden),
                    " | ", h.ctrl_took ? "**" * _s(h.ctrl_a) * "**" : _s(h.ctrl_a),
                    " | `", h.ctrl_win, "`",
                    " | ", h.selector, " | ", _s(h.npinned), " | ", _s(h.tstat),
                    " | ", (h.a_at == 0 && h.ctrl_took) ? "**0 (뺏김)**" :
                           (h.a_at !== nothing && h.a_at > 0 && h.ctrl_took) ? "**" * _s(h.a_at) * " (그대로)** 🔴" : _s(h.a_at),
                    " | `", h.winner, "`",
                    " | ", _r(h.ctrl_obj, 6), " → ", _r(h.obj, 6),
                    " | ", _r(h.ctrl_mk), " → ", _r(h.mk),
                    " | ", _s(h.lost), " |")
        end
    end
    any_hh || println(io, "| — | — | — | — | — | — | — | — | — | — | — | — | — | — | 머리맞대기 행 없음 |")
    println(io)
    println(io, "### 표 3b — 머리맞대기를 **못 한** 레짐과 그 사유 (N-3: 사유를 지어내지 않는다)")
    println(io)
    println(io, "| 판 | closed | regime | 공통 도착점 | 사유 |")
    println(io, "|---|---|---|---|---|")
    for r in rows
        r.status === :window_closed && continue
        sk = get(r, :hh_skip, nothing)
        sk === nothing && continue
        println(io, "| ", r.board, " | ", r.closed, " | ", r.regime,
                " | ", get(r, :ncommon, 0), " | `", sk, "` |")
    end
    println(io)
    println(io, "### 표 3c — 대조 팔(아무것도 안 누름) 단독 수치")
    println(io)
    println(io, "| 판 | closed | regime | term | obj | makespan | A 가 잃은 작업 | 전체 재배정 | wall(s) |")
    println(io, "|---|---|---|---|---|---|---|---|---|")
    for r in rows
        r.status === :window_closed && continue
        for a in get(r, :arms, Any[])
            a.selector === :control || continue
            if a.status !== :ok
                println(io, "| ", r.board, " | ", r.closed, " | ", r.regime, " | `", a.status, "` | — | — | — | — | — |")
                continue
            end
            println(io, "| ", r.board, " | ", r.closed, " | ", r.regime, " | ", a.tstat,
                    " | ", _r(a.obj, 6), " | ", _r(a.mk), " | ", a.lost, "/", a.a_before,
                    " | ", a.nreass, " | ", _r(a.wall, 1), " |")
        end
    end
    println(io)
    println(io, "## 표 4a — 부담 분포 / 동점 (I-4: \"상위 N\" 이 well-defined 인가)")
    println(io)
    println(io, "| 판 | closed | regime | 선택자 | 잰 도착점 | max burden | **최대값 동점** | 서로 다른 값 | 상위 (값=>개수) |")
    println(io, "|---|---|---|---|---|---|---|---|---|")
    for r in rows
        r.status === :window_closed && continue
        for (nm, br) in (("frontier", r.bf), ("owner", r.bo))
            (haskey(br, :bmax) && br.bmax !== nothing) || continue
            println(io, "| ", r.board, " | ", r.closed, " | ", r.regime, " | ", nm,
                    " | ", br.nmeas, " | ", _r(br.bmax),
                    " | **", br.nties, "**", br.nties > 1 ? " 🔴" : "",
                    " | ", br.ndistinct, " | `", br.top, "` |")
        end
    end
    println(io)
    println(io, "## 표 4c — `is_agent_frontier` 관문별 생존 수 (frontier(A)=0 이 어디서 죽나)")
    println(io)
    println(io, "| 판 | closed | regime | RobotGo | A 에 묶임 | 안 얼음 | **선행 OK = frontier(A)** |")
    println(io, "|---|---|---|---|---|---|---|")
    for r in rows
        r.status === :window_closed && continue
        haskey(r, :gates) || continue
        println(io, "| ", r.board, " | ", r.closed, " | ", r.regime,
                " | ", r.gates.robotgo, " | ", r.gates.bound_to_A,
                " | ", r.gates.not_frozen, " | **", r.gates.pred_ok, "** |")
    end
    println(io)
    println(io, "## 표 4b — 쌍 0 의 분해 (I-5: 해석이 아니라 측정)")
    println(io)
    println(io, "`u_no_assigned` = `isassigned_edge` 가 어떤 `v2` 에도 참이 아님(= u 가 후보 간선의 출발점이 아니다).")
    println(io, "`u_all_forced` = 후보 칸은 있는데 전부 `has_edge`(확정 간선)라 걸러짐.")
    println(io)
    println(io, "| 판 | closed | regime | 선택자 | 집은 u | u_no_assigned | u_all_forced | 쌍 만든 u | isassigned 히트 | has_edge 스킵 |")
    println(io, "|---|---|---|---|---|---|---|---|---|---|")
    for r in rows
        r.status === :window_closed && continue
        for (nm, z) in (("frontier", r.sel.f_zero), ("owner", r.sel.o_zero))
            println(io, "| ", r.board, " | ", r.closed, " | ", r.regime, " | ", nm,
                    " | ", z[:n_u], " | ", z[:u_no_assigned], " | ", z[:u_all_forced],
                    " | ", z[:u_yield], " | ", z[:assigned_hits], " | ", z[:forced_skips], " |")
        end
    end
    println(io)
    println(io, "## 표 4 — Q1 전 로봇 frontier 히스토그램")
    println(io)
    for r in rows
        r.status === :window_closed && continue
        r.regime === :released && continue
        println(io, "- **", r.board, " closed=", r.closed, "**: ",
                sort(collect(r.q1.by_agent), by = kv -> -kv[2]))
    end
    println(io)
    open(RESULTS_MD, "w") do f; write(f, String(take!(io))); end
    println("\n📝 wrote ", RESULTS_MD)
end

Dates_now() = read(`date -Iseconds`, String) |> strip
git_head() = try strip(read(`git -C $(pkgdir(CB)) rev-parse HEAD`, String))[1:12] catch; "unknown" end

"""
M-1 전용 측정: `closed` 도달값이 **왜** 판마다 다른가.
컨트롤러 정찰은 tractor target=150 에서 **152** 를 쟀고 내 프로브는 **150** 을 쟀다. 후보 원인 셋을
분리해서 잰다 — 해석이 아니라 측정이다.
  (a) 연속·포크 없음 : 60 에서 멈췄다가 150 까지, 사이에 아무 측정도 안 함
  (b) 신선·직행      : 새 env 로 처음부터 곧장 150
  (c) 연속·포크 있음 : 60 에서 멈춘 뒤 `fork`(=deepcopy + rvo_rebuild!) 를 한 번 하고 150 까지
🔴 (c) 가 (a)와 다르면 원인은 `fork` 의 **전역 RVO 재구축**이다(프로브가 세계를 건드린 것).
"""
function closed_only()
    println("M-1 재현: closed 도달값의 원인 분리  (a)연속·포크없음 (b)신선·직행 (c)연속·포크있음")
    for (board, nr) in (("tractor.mpd", 10), ("colored_8x8.ldr", 6))
        ea = build_base(board, nr); k = 0
        a60, k = step_to!(ea, 60, k); a150, _ = step_to!(ea, 150, k)
        eb = build_base(board, nr)
        b150, _ = step_to!(eb, 150, 0)
        ec = build_base(board, nr); k2 = 0
        c60, k2 = step_to!(ec, 60, k2)
        _throwaway = fork(ec)                       # 포크 한 번 — 전역 RVO 를 다시 만든다
        c150, _ = step_to!(ec, 150, k2)
        println(rpad(board, 18),
                " (a) 60→", a60, ", 150→", a150,
                "   (b) 직행 150→", b150,
                "   (c) 포크 뒤 150→", c150,
                "   ", a150 == b150 == c150 ? "세 경로 일치" : "🔴 경로마다 다르다")
    end
end

# ── main ────────────────────────────────────────────────────────────────────────
function main()
    if length(ARGS) >= 1 && ARGS[1] == "--closed-only"
        return closed_only()
    end
    configs = if length(ARGS) >= 2
        [(ARGS[1], parse(Int, ARGS[2]),
          length(ARGS) >= 3 ? parse.(Int, split(ARGS[3], ",")) : [60, 150])]
    else
        [("tractor.mpd", 10, [60, 150]), ("colored_8x8.ldr", 6, [60, 150])]
    end
    cmd = "julia +lts --project=. tools/probes/probe_owner_selector.jl " * join(ARGS, " ")
    println("probe_owner_selector — TL=", TL, "s  configs=", configs)

    f0 = CB.RESPEC_FROZEN[]; p0 = CB.RESPEC_PINNED[]; ctr0 = copy(CB.INVALID_ID_COUNTERS)
    rows = Any[]
    try
        for (board, nr, cps) in configs
            # 🔴 **체크포인트마다 env 를 새로 짓는다.** 앞 판은 하나를 60→150 으로 이어 썼는데,
            #    사이에 낀 `fork`(deepcopy + `rvo_rebuild!`)가 **전역 RVO 시뮬레이터**를 갈아끼운다.
            #    그 부작용으로 두 번째 체크포인트의 stepping 이 달라져 `closed` 가 실행마다
            #    150 ↔ 152 로 흔들렸고 A·frontier 수까지 바뀌었다(같은 코드 두 실행이 frontier 20 vs 0).
            #    체크포인트를 독립적으로 지으면 그 오염 경로가 끊긴다.
            for target in cps
                base = build_base(board, nr)
                p = CB.BATTERY_FLEET[].params        # R7 (build_base 뒤라야 fleet 이 있다)
                measure_checkpoint(base, board, nr, target, p, rows, 0)
            end
        end
    finally
        CB.RESPEC_FROZEN[] = f0; CB.RESPEC_PINNED[] = p0
        empty!(CB.INVALID_ID_COUNTERS); merge!(CB.INVALID_ID_COUNTERS, ctr0)
        println("\n(전역 복원: RESPEC_FROZEN/PINNED, INVALID_ID_COUNTERS)")
    end

    println("\n", "="^92)
    println("SUMMARY (machine-readable-ish)")
    println("="^92)
    println(rpad("board", 16), rpad("closed", 8), rpad("regime", 18), rpad("ncand", 7),
            rpad("Q1 f前/後", 12), rpad("Q2f", 6), rpad("Q2o", 6),
            rpad("Q3f", 10), rpad("Q3o", 10), "Q4")
    for r in rows
        if r.status === :window_closed
            println(rpad(r.board, 16), rpad(string(r.closed), 8), rpad("-", 18), "window_closed")
            continue
        end
        arms = get(r, :arms, Any[])
        hh = get(r, :hh, Any[])
        q4 = isempty(hh) ? string("hh_skip=", _s(get(r, :hh_skip, nothing))) :
             join([string("v2=", h.target, ":", h.selector, "→",
                          h.status === :ok ? "pin$(get(h,:npinned,"?"))/A$(_s(get(h,:a_at,nothing)))/$(get(h,:tstat,"?"))"
                                           : string(h.status))
                   for h in hh], " ")
        println(rpad(r.board, 16), rpad(string(r.closed), 8), rpad(string(r.regime), 18), rpad(string(r.ncand), 7),
                rpad(string(r.q1.frontier_before, "/", r.q1.frontier_after), 12),
                rpad(string(r.nf), 6), rpad(string(r.no), 6),
                rpad(string(r.bf.nmeas, "/", r.bf.n), 10),
                rpad(string(r.bo.nmeas, "/", r.bo.n), 10), q4)
    end
    write_results(rows, cmd)
end
main()
