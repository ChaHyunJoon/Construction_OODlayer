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
module PayloadReleaseIsSafeTest
using Test
using ConstructionBots
import Random, Graphs
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
include(joinpath(pkgdir(CB), "tools", "monitor", "policy.jl"))

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
    # release_pending_assignments! (src/respec/reassign.jl:127-146) 이 계산하는
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

    # 한 팔을 풀고 (termination_status, primal_status, 경과초, 최종 gap) 을 함께 재는 헬퍼.
    # 🔴 relative_gap 은 INFEASIBLE/NO_SOLUTION 이면 정의되지 않을 수 있어 try 로 감싼다.
    function _solve_and_measure!(sched, tree; label::AbstractString)
        milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), sched, tree;
                                 optimizer = CB._respec_optimizer())
        CB.set_time_limit_sec(milp, time_limit_s)
        elapsed = @elapsed CB.optimize!(milp)
        ts = CB.termination_status(milp)
        ps = CB.primal_status(milp)
        gap = try CB.relative_gap(milp.model) catch; NaN end
        @info "$label 풀이 결과" termination_status = ts primal_status = ps solve_seconds = elapsed relative_gap = gap
        return (milp = milp, termination_status = ts, primal_status = ps,
                seconds = elapsed, gap = gap)
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
        agent = string(first(keys(fleet.soc)))
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
                rb.termination_status primal_a = ra.primal_status primal_b = rb.primal_status
            # 참고용 관측일 뿐이다(pass/fail 게이트가 아니다) — harder-to-solve 를 발견으로 기록.
            @test true
        end
    end

    # 🔴🔴 실측(2026-09-01, 이 시험 실행 도중 독립 확인): (a)/(b) 의 primal/dual bound 가
    # 비트단위로 같다(11.674999 / 7.825, 노드수·LP반복만 다름 — 별개의 두 번의 실제 B&B다).
    # 우연이 아니다. `essential_tg_coponents.jl:1495`
    # `w_eff == 0.0 && return speed_term` 이 원인이다: `PLANNING_OBJECTIVE_WEIGHTS[]` 기본값이
    # `(speed=1, efficiency=0)`이고 `AUTO_EFFICIENCY_KAPPA[]` 기본값이 `nothing` 이라(둘 다
    # `set_planning_objective_weights!`/`init_objective_weights!` 를 명시적으로 불러야만 바뀜 —
    # 이 시험도, `_respec_optimizer()`/`formulate_milp` 를 쓰는 다른 어떤 호출자도 안 부른다),
    # `get_objective_expr(::SumOfMakeSpans, ...)` 가 `edge_costs` 를 통째로 버리고 순수 makespan
    # 항만 돌려준다. `edge_costs` 는 `EDGE_PAYLOAD_MULTIPLIER`(이 파일이 켜는 payload 재가격)가
    # 유일하게 솔버에 닿는 통로다(payload_bias.jl 머리말) — 그 통로가 objective 조립 단계에서
    # 원천적으로 끊겨 있다. 독립 검증: 이 시험이 고른 agent(BotID{DeliveryBot}(8))는 release 후
    # 후보 2103개 중 200개를 소유하고 200개 전부 payload 질량을 잴 수 있다(diagnostic script,
    # 죽은 agent 를 고른 게 아니다) — 그런데도 (a)==(b) 다. 이 코드 블록 자체의 주석
    # ("THE BUG THIS FIXES" / AUTO_EFFICIENCY_KAPPA 절, essential_tg_coponents.jl:1279-1310)
    # 이 이미 이 한계를 문서화해 두었고, DeprioritizeAgent·배터리 SoC 축도 같은 이유로 예전에
    # 무동작이었다고 적혀 있다 — 이번이 세 번째 사례다.
    # ⟹ Task 7 의 (a)/(b) 가 같은 결과인 것은 "재가격이 안전하다"는 증거가 **아니다** — 이
    # 시험이 실행되는 조건(기본 가중치)에서는 재가격이 목적함수에 **전혀 도달하지 않기** 때문에
    # 같다. spec §9-3 의 위험(재가격이 재풀이를 infeasible 로 만들 수 있는가)은 efficiency
    # 가중치가 0 이 아닌 조건에서만 실제로 시험되는데, 이 계획(Task 1~7)의 어떤 인터페이스도
    # 그 가중치를 켜지 않는다. Task 7 의 권한(이 파일 하나만) 밖의 발견이라 여기서 가중치를
    # 켜서 "고치지" 않는다 — 계획 소유자에게 보고만 한다(기록, 미수정).
end
end # module
