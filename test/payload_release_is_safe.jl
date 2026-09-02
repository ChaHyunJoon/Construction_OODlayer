# test/payload_release_is_safe.jl
#   julia +lts --project=. test/payload_release_is_safe.jl
#
# Task 7 (S2 payload reprice lane): pins G-1 (the release probe does not disturb the world),
# that release never touches finished/in-progress work, and that the re-solve after
# release(+reprice) stays FEASIBLE. Per task-7-addendum.md (controller Ruling 10):
#   - testset 3 must ACTUALLY reprice (not just clear the bias) to test the risk it is named for
#   - fresh_env() must enable the battery fleet, or reprice_agent_by_payload! silently no-ops
#   - testset 2 must assert `removed` is non-empty before the loop (else it is a vacuous pass)
#
# Controller ruling (mid-task, after a bare-HiGHS solve on the released board ran 27+ minutes at
# a 14% MIP gap without finishing): `_respec_optimizer()` is unbounded HiGHS with no time limit,
# so `optimize!` was chasing proven OPTIMALITY on a 2103-candidate-edge MILP. This gate asks about
# FEASIBILITY, not optimality (spec §9-3). Fix: give BOTH arms the SAME bounded time limit
# (symmetry — an asymmetric limit would make the arms incomparable), assert only
# `primal_status == FEASIBLE_POINT` (never `termination_status == OPTIMAL`), and treat the
# three-state distinction as load-bearing: `NO_SOLUTION` (time limit hit before any incumbent
# was found) is NOT the same as `INFEASIBLE` (proven no solution exists) — report which one
# happened, don't collapse them. Wall-clock solve time and final relative MIP gap are measured
# and reported for both arms side by side (a real operational-cost finding, not just plumbing).
#
# Second controller ruling (mid-task): `fresh_env()` now also calls `CB.init_objective_weights!()`
# (see its docstring-comment below testset 3) -- without it, the payload reprice this file
# installs never reaches the MILP objective at all, and testset 3's (a)==(b) result would prove
# nothing about safety.
module PayloadReleaseIsSafeTest
using Test
using ConstructionBots
import Random, Graphs
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
include(joinpath(pkgdir(CB), "tools", "monitor", "policy.jl"))

"후보 간선 (v,v2) 목록에서 가장 많이 등장하는 유효 owner id. `test/payload_reprice_changes_plan.jl`
의 `busiest_agent()` / `tools/probes/probe_reprice_moves_assignment.jl` 의 `busiest_agent()` 와
같은 관용구를 재사용한다 — 세 번째 구현을 만들지 않는다.
🔴 최종 리뷰 F2: 여기 있던 `agent = string(first(keys(fleet.soc)))` 는 `fleet.soc::Dict{Any,Float64}`
가 `RobotID`(`AbstractID`) 로 키가 되는데 이 브랜치엔 `bb1b88c4`(내용기반 `Base.hash`)가 없어
(`git branch --contains bb1b88c4` == `sdd-lane-c7` 뿐) `objectid` 해시로 순회 순서가 실행마다
갈린다 — 후보 간선을 0개 또는 소수만 가진 로봇이 뽑혀도 재풀이가 사실상 무동작인 채 testset
3(b) 가 `primal_status==FEASIBLE_POINT` 만 보고 그대로 통과했다(축 자체는 다르지만 방금 고친
κ 축과 같은 모양의 blind gate). 이제 후보 간선 소유량으로 대상을 유도한다.
"
function busiest_agent(env)
    sched, tree = deepcopy((env.sched, env.scene_tree))
    shim = (sched = sched, scene_tree = tree, cache = env.cache)
    CB.release_pending_assignments!(shim, CB.build_invariant(env))
    sentinel = Dict{Tuple{Int,Int},Float64}()
    CB.LAST_EDGE_COSTS[] = sentinel
    CB.formulate_milp(CB.SparseAdjacencyMILP(), sched, tree; optimizer = CB._respec_optimizer())
    ran = !(CB.LAST_EDGE_COSTS[] === sentinel)
    ran || error("busiest_agent: formulate_milp did not run (LAST_EDGE_COSTS untouched)")
    tally = Dict{String,Int}()
    for (v, _) in keys(CB.LAST_EDGE_COSTS[])
        id = CB._edge_owner_id(sched, v)
        id === nothing && continue
        tally[string(id)] = get(tally, string(id), 0) + 1
    end
    isempty(tally) && error("busiest_agent: no valid owner ids among candidate edges")
    ranked = sort(collect(tally), by = kv -> -kv[2])
    return (agent = ranked[1][1], n_edges = ranked[1][2], n_candidates = length(CB.LAST_EDGE_COSTS[]))
end

function fresh_env()
    env = CB.run_lego_demo(; ldraw_file = "tractor.mpd", project_name = "s2safe",
                       num_robots = 10, assignment_mode = :greedy, n_spare_per_pool = 2,
                       open_animation_at_end = false, save_animation = false,
                       write_results = false, return_env_before_sim = true,
                       rng = Random.MersenneTwister(1))
    # 🔴 필수: run_lego_demo 는 함대를 켜지 않는다. 안 켜면 reprice_agent_by_payload! 가
    # BATTERY_FLEET[] === nothing 을 보고 (status=:no_fleet, installed=false) 로 조용히
    # 아무 훅도 안 심는다(측정된 사실, task-7-addendum.md 정정 1).
    CB.enable_battery!(env; params = CB.BatteryParams())
    # 🔴🔴 필수(2026-09-01, controller ruling — Task 0 의 halt-gate 전제가 이 태스크로
    # 전파되지 않았던 구멍): `AUTO_EFFICIENCY_KAPPA[]` 기본값은 `nothing` 이고, 그러면
    # `get_objective_expr` 이 `edge_costs` 를 통째로 버려 `EDGE_PAYLOAD_MULTIPLIER`(payload
    # 재가격)가 목적함수에 **전혀 도달하지 못한다**(essential_tg_coponents.jl:1495,
    # `w_eff == 0.0 && return speed_term`). `init_objective_weights!()` 가 그 Ref 를
    # objective.json 의 kappa(=0.01)로 채워 살린다 — 생산 경로(tools/monitor/run_demo.jl:531-532,
    # ENERGY_OBJECTIVE 기본 1)와 Task 0 의 probe(tools/probes/probe_kappa_alive.jl:14)가 이미
    # 하는 일과 동일하다. 이게 없으면 testset 3 은 절대 실패할 수 없는 시험이었다(아래 참고).
    CB.init_objective_weights!()
    return env
end

@testset "G-1 · release_then_candidates 는 세계를 안 건드린다" begin
    env = fresh_env()
    ne0  = Graphs.ne(env.sched)
    ids0 = copy(CB.INVALID_ID_COUNTERS)
    r1 = release_then_candidates(env)
    r2 = release_then_candidates(env)
    @test Graphs.ne(env.sched) == ne0                 # 🔴 스케줄 원본 불변
    @test copy(CB.INVALID_ID_COUNTERS) == ids0        # 🔴 무효 ID 카운터 불변(시드 재현성)
    @test r1 !== nothing && r2 !== nothing
    @test r1 == r2                                    # 멱등
end

@testset "release 는 완료·진행중 작업을 건드리지 않는다" begin
    env = fresh_env()
    inv = CB.build_invariant(env)
    sched, tree = deepcopy((env.sched, env.scene_tree))
    shim = (sched = sched, scene_tree = tree, cache = env.cache)
    active_before = Set(CB.get_vtx_id(env.sched, v) for v in env.cache.active_set)
    removed = CB.release_pending_assignments!(shim, inv)
    # task-7-addendum.md 정정 2: 빈 removed 면 아래 루프는 아무것도 단언하지 않는다(공허한 통과).
    @test !isempty(removed)
    # ⚠️ 기록만 하고 안 고친다(addendum 이 명시적으로 금지): 이 루프 안의 단언은
    # release_pending_assignments! (src/respec/reassign.jl:164-188) 이 계산하는
    # `keep = in_closed(id1)||in_closed(id2)||in_active(id1)||in_active(id2)` 를 그대로
    # 재유도한 것이라 그 불리언 자체가 바뀌지 않는 한 실패할 수 없다. 두 번째 구멍: 여기서
    # 읽는 id2 는 reset_slot_to_invalid! 가 그 슬롯을 재도장한 **뒤**의 값이라, 애초에
    # closed/active 에 있을 수 없는 갓 발급된 무효 id 를 보는 것이다. 생산 판정식과 독립적인
    # 오라클이 없으면 이 시험을 못 고친다 — 이 계획의 범위 밖.
    for (v, v2) in removed
        id1 = CB.get_vtx_id(sched, v); id2 = CB.get_vtx_id(sched, v2)
        @test !(id1 in inv.closed_nodes) && !(id2 in inv.closed_nodes)
        @test !(id1 in active_before)   && !(id2 in active_before)
    end
end

@testset "release + 재가격 뒤의 재풀이가 feasible 하다" begin
    # 🔴 시간제한 없는 HiGHS 는 이 판(release 후보 2103개)에서 **최적성 증명**을 쫓는다 —
    # 이 게이트는 최적성이 아니라 실행가능성을 묻는다(spec §9-3). 두 팔에 **같은** 시간제한을
    # 준다(비대칭이면 두 팔이 비교 불가가 된다). `formulate_milp` 뒤에 모델에 붙이는 방식을
    # 쓴다(tools/tests.jl:78 이 이미 쓰는 패턴과 동형; optimizer factory 를 새로 만들 필요가 없다).
    time_limit_s = 180.0

    # 한 팔을 풀고 (termination_status, primal_status, 경과초, 최종 gap, objective, bound) 을
    # 함께 재는 헬퍼.
    # 🔴 relative_gap/objective_value 는 INFEASIBLE/NO_SOLUTION 이면 정의되지 않을 수 있어
    # try 로 감싼다.
    function _solve_and_measure!(sched, tree; label::AbstractString)
        milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), sched, tree;
                                 optimizer = CB._respec_optimizer())
        CB.set_time_limit_sec(milp, time_limit_s)
        elapsed = @elapsed CB.optimize!(milp)
        ts = CB.termination_status(milp)
        ps = CB.primal_status(milp)
        gap = try CB.relative_gap(milp.model) catch; NaN end
        obj = try CB.objective_value(milp.model) catch; NaN end
        bound = try CB.objective_bound(milp) catch; NaN end
        @info "$label 풀이 결과" termination_status = ts primal_status = ps solve_seconds = elapsed relative_gap = gap objective_value = obj objective_bound = bound
        return (milp = milp, termination_status = ts, primal_status = ps,
                seconds = elapsed, gap = gap, objective = obj, bound = bound)
    end

    result_a = Ref{Any}(nothing)
    result_b = Ref{Any}(nothing)

    @testset "(a) 대조군: release 만, bias 없음" begin
        env = fresh_env()
        sched, tree = deepcopy((env.sched, env.scene_tree))
        shim = (sched = sched, scene_tree = tree, cache = env.cache)
        CB.release_pending_assignments!(shim, CB.build_invariant(env))
        CB.clear_payload_bias!()
        result_a[] = _solve_and_measure!(sched, tree; label = "(a) release-only")
        # 🔴 삼상: NO_SOLUTION(시간 내 못 찾음) 은 INFEASIBLE(불가능 증명됨) 이 아니다.
        # primal_status 만 본다 — termination_status==OPTIMAL 은 이 게이트의 주장이 아니다.
        @test result_a[].primal_status == CB.MOI.FEASIBLE_POINT
    end

    @testset "(b) release + 재가격(light_bias=2.0) 도 feasible 하다" begin
        env = fresh_env()
        sched, tree = deepcopy((env.sched, env.scene_tree))
        shim = (sched = sched, scene_tree = tree, cache = env.cache)
        CB.release_pending_assignments!(shim, CB.build_invariant(env))
        fleet = CB.BATTERY_FLEET[]
        @test fleet !== nothing   # enable_battery! 가 실제로 켰는지 사전조건으로 확인
        # 🔴 최종 리뷰 F2: `string(first(keys(fleet.soc)))` 대신 후보 간선 소유량으로 대상을
        # 유도한다 — Dict 순회 순서가 아니라 실제로 재가격이 건드릴 간선을 가진 로봇을 고른다.
        ba = busiest_agent(env)
        agent = ba.agent
        @test ba.n_edges > 0   # 대상이 실제로 소유한 후보 간선이 있다(0-간선 로봇을 뽑지 않았다)
        r = CB.reprice_agent_by_payload!(env; agent = agent, light_bias = 2.0)
        # 🔴 이 단언은 사전조건일 뿐이다 — :repriced 는 이 함수가 리턴하는 순간까지 Ref 둘을
        # 썼을 뿐 세계가 바뀌었다는 증거가 아니다(그 증거는 아래의 실제 재풀이 결과다).
        @test r.status === :repriced
        result_b[] = _solve_and_measure!(sched, tree; label = "(b) release+reprice")
        @test result_b[].primal_status == CB.MOI.FEASIBLE_POINT
        CB.clear_payload_bias!()
    end

    @testset "(a) vs (b) 비교 보고" begin
        ra, rb = result_a[], result_b[]
        if ra !== nothing && rb !== nothing
            @info "==== (a) vs (b) 시간제한 $(time_limit_s)s 나란히 ====" ta = ra.seconds tb =
                rb.seconds gap_a = ra.gap gap_b = rb.gap termination_a = ra.termination_status termination_b =
                rb.termination_status primal_a = ra.primal_status primal_b = rb.primal_status obj_a =
                ra.objective obj_b = rb.objective bound_a = ra.bound bound_b = rb.bound
            same_objective = isfinite(ra.objective) && isfinite(rb.objective) && ra.objective == rb.objective
            same_bound = isfinite(ra.bound) && isfinite(rb.bound) && ra.bound == rb.bound
            if same_objective && same_bound
                @warn "κ 가 살아 있는데도 (a)/(b) objective·bound 가 비트단위로 같다 — 재가격이 이 판에서 목적함수를 전혀 못 움직였다는 뜻(발견, 통과가 아니다)." objective = ra.objective bound = ra.bound
            end
            # 참고용 관측일 뿐이다(pass/fail 게이트가 아니다) — harder-to-solve 를 발견으로 기록.
            @test true
        end
    end

    # 🔴🔴 이 파일은 `fresh_env()` 에서 `CB.init_objective_weights!()` 를 부른다(2026-09-01,
    # controller ruling). 그전에는 `AUTO_EFFICIENCY_KAPPA[]` 기본값이 `nothing` 이라
    # `get_objective_expr(::SumOfMakeSpans,...)` 의 `w_eff == 0.0 && return speed_term`
    # (essential_tg_coponents.jl:1495) 이 `edge_costs` 를 통째로 버렸다 — `EDGE_PAYLOAD_MULTIPLIER`
    # (payload 재가격)가 솔버에 닿는 유일한 통로가 조립 단계에서 끊겨 있었고, 그때는 (a)==(b) 가
    # "재가격이 안전하다"는 증거가 아니라 "재가격이 목적함수에 전혀 안 닿았다"는 증거였다
    # (독립 검증: 그때 고른 agent 는 release 후 후보 2103개 중 200개를 소유하고 200개 전부 질량을
    # 잴 수 있었다 — 죽은 agent 를 고른 게 아니었는데도 bound 가 비트단위로 같았다).
    #
    # `init_objective_weights!()` 는 `objective.json` 의 kappa=0.01 로 `AUTO_EFFICIENCY_KAPPA[]`
    # 를 채워 살린다(production 경로 tools/monitor/run_demo.jl:531-532 이 ENERGY_OBJECTIVE=1 기본값
    # 아래서 하는 일, Task 0 의 halt-gate probe tools/probes/probe_kappa_alive.jl:14 가 하는 일과
    # 동일) — 이제 `w_eff` 가 0 이 아니라 `AUTO_EFFICIENCY_KAPPA[] · speed_scale/eff_scale` 이고
    # `eff_term = Σ edge_costs[e]·Xa[e]` 가 목적식에 실제로 들어간다.
    #
    # 실측(κ 살아있는 상태, 180s 시간제한 두 팔 재실행): (a) release-only 는
    # objective=12.45098811768997 / bound=8.02862999819935 / gap=35.52%; (b) release+reprice
    # (light_bias=2.0) 는 objective=12.951084938587051 / bound=8.045273379154887 / gap=37.88% —
    # 둘 다 `FEASIBLE_POINT`·`TIME_LIMIT` 이고 이번엔 objective·bound 가 **다르다**(재가격이
    # 목적함수에 실제로 도달했다는 뜻). 게이트가 살아 있고, 살아 있는 상태로 통과했다: 이 판에서
    # release+재가격은 재풀이를 infeasible 로 만들지 않았다(spec §9-3 의 질문에 대한 실제 답).
    # `(a) vs (b) 비교 보고` 위 `_solve_and_measure!` 의 `@warn` 은 이 조건(objective·bound 가
    # 비트단위로 같음)이 다시 나타나면 — 예: 다른 agent/시드/보드에서 κ 가 살아 있어도 재가격이
    # 목적함수를 못 움직이면(Task 0 이 잰 w=2.8e-5 처럼 항이 너무 작을 때) — 그것도 통과가 아니라
    # 발견으로 소리 내어 알리기 위한 것이다.
end
end # module
