# test/cargo_ban_store.jl
# ============================================================================
#  이 파일이 지키는 것: **지속 화물 금지 보관소** `STANDING_CARGO_BANS` 와, 그것을
#  **모든** `formulate_milp` 이 읽는다는 계약(cargo-ban 계획 Task 3).
#
#  왜 "모든" 인가(사용자 결정 2026-09-01): T13 재풀이만 읽게 하면 `verify` ·
#  `fault_robot_and_reassign!` · `rebalance_for_battery!` 가 금지를 무시한다. 그러면 고장
#  재배정 한 번에 무거운 짐이 그 로봇에게 **돌아간다** — 수명 계약과 정면으로 모순이다.
#  🔴 `rebalance_for_battery!` 는 `extra_constraints` 를 **안 준다**(`battery.jl` 참조).
#     그래서 훅이 `if extra_constraints !== nothing` 안에 있으면 그 경로는 조용히 샌다.
#     아래 G-5 는 `extra_constraints = nothing` 으로만 재서 그 자리를 직접 겨눈다.
#
#  🔴 runtests.jl 이 모든 시험 파일을 같은 `Main` 스코프에 include 하므로 자기 module 로 감싼다.
# ============================================================================
module CargoBanStoreTests

using Test
using ConstructionBots
using Graphs, Random, JuMP, SparseArrays
const CB = ConstructionBots

# 🔴 런타임 include 는 **module 최상위**에 있어야 한다(world-age). 순서도 load-bearing:
#    navigator 가 먼저, 그 다음 mdp(= simstate_of). 🔴 계획 README 의 픽스처는 이 두 줄이
#    빠져 있어 그대로 쓰면 `UndefVarError: enable_battery!` 로 죽는다(shared-rulings S-4.9).
const REPO = joinpath(@__DIR__, "..")
isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))
isdefined(CB, :simstate_of)  || CB.include(joinpath(REPO, "src", "smdp", "mdp.jl"))

# ============================================================================
#  1. 보관소 기본 계약 (계획서 Step 1 판 그대로 — 씬을 안 짓는다)
# ============================================================================
@testset "보관소 기본 계약" begin
    CB.clear_all_cargo_bans!()
    r3 = CB.RobotID(3); r7 = CB.RobotID(7)
    @test isempty(CB.STANDING_CARGO_BANS[])
    CB.set_cargo_ban!(r3, 2)
    @test CB.STANDING_CARGO_BANS[][r3] == 2
    CB.set_cargo_ban!(r7, 1)
    @test length(CB.STANDING_CARGO_BANS[]) == 2
    # 같은 로봇에 다시 걸면 덮어쓴다(중복 누적이 아니다)
    CB.set_cargo_ban!(r3, 3)
    @test CB.STANDING_CARGO_BANS[][r3] == 3
    @test length(CB.STANDING_CARGO_BANS[]) == 2
    @test CB.clear_cargo_ban!(r3) === true
    @test CB.clear_cargo_ban!(r3) === false      # 없는 것을 지우면 false — 조용한 성공 금지
    @test length(CB.STANDING_CARGO_BANS[]) == 1
    CB.clear_all_cargo_bans!()
    @test isempty(CB.STANDING_CARGO_BANS[])
    # 🔴 `n >= 1` 을 **보관소 경계에서** 강제한다 (2026-09-02 리뷰 Fix 1).
    #    `ForbidHeavyCargo` 생성자와 같은 계약인데, 보관소가 그것을 통과시키면 폭발이 한참 뒤
    #    `formulate_milp` **안**(훅이 생성자를 부르는 자리)으로 미뤄진다. 거기서는 `verifier.jl`
    #    이 LLM 문법 없는 제안의 컴파일 예외를 되던지고 `maybe_respecify!` 에 `try` 가 없어
    #    `route_planning.jl` 까지 풀려 올라가 **런이 죽는다** — 그것도 나쁜 값을 준 제안이
    #    아니라 그 다음 **아무 `verify`** 에서(훅은 무조건 도니까). 여기서 죽어야 한다.
    @test_throws ErrorException CB.set_cargo_ban!(r3, 0)     # 0 개 금지 = hollow admit
    @test_throws ErrorException CB.set_cargo_ban!(r3, -1)    # 음수는 말이 안 된다
    # 🔴 거절이 **부작용을 남기지 않는다** — 안 그러면 보관소에 쓰레기가 앉는다.
    @test !haskey(CB.STANDING_CARGO_BANS[], r3)
    @test isempty(CB.STANDING_CARGO_BANS[])
    # 🔴 경계값은 통과한다 — 위 둘이 "전부 거절" 이라서 초록인 것이 아님을 못 박는다.
    CB.set_cargo_ban!(r3, 1)
    @test CB.STANDING_CARGO_BANS[][r3] == 1
    CB.clear_all_cargo_bans!()
    # 🔴 반환 계약을 못 박는다: 세우기·전체지우기는 `nothing`(장부가 아니라 부작용).
    @test CB.set_cargo_ban!(r3, 1) === nothing
    @test CB.clear_all_cargo_bans!() === nothing
    @test isempty(CB.STANDING_CARGO_BANS[])
    # 🔴 T3-R6: Task 5 가 `Ref` 를 통째로 갈아끼웠다가 되돌린다. 두 방식이 공존해야 한다.
    CB.set_cargo_ban!(r3, 2)
    saved = CB.STANDING_CARGO_BANS[]
    CB.STANDING_CARGO_BANS[] = Dict{CB.AbstractID,Int}()      # Task 5 의 "끄기"
    @test isempty(CB.STANDING_CARGO_BANS[])
    CB.STANDING_CARGO_BANS[] = saved                          # Task 5 의 `finally` 복원
    @test CB.STANDING_CARGO_BANS[][r3] == 2
    CB.clear_all_cargo_bans!()
    @test isempty(CB.STANDING_CARGO_BANS[])
end

# ============================================================================
#  2. 🔴 G-6 — 롤아웃 경계에서 지워지도록 `:state` 로 등록돼 있다
# ============================================================================
@testset "🔴 G-6 롤아웃 경계에서 지워지도록 :state 로 등록돼 있다" begin
    # state_globals.jl 의 분류표에 이름이 있어야 한다. 없으면 이전 판의 금지가 다음 판을 오염시킨다.
    src = read(joinpath(@__DIR__, "..", "src", "smdp", "state_globals.jl"), String)
    @test occursin("STANDING_CARGO_BANS", src)
    @test occursin(r":STANDING_CARGO_BANS\s*=>\s*:state", src)
    # 🔴 어휘적 검사만으로는 공허하다 — 표가 실제로 그 처분을 내놓는지, 그리고 리셋 목록에
    #    실제로 들어가는지까지 잰다(등록이 문자열로만 있고 이름이 안 잡히면 여기서 빨개진다).
    @test CB.STATE_GLOBALS[:STANDING_CARGO_BANS] === :state
    @test :STANDING_CARGO_BANS in CB.resettable_state_globals()
    @test !(:STANDING_CARGO_BANS in CB.unresettable_state_globals())
    # 🔴 리셋이 실제로 금지를 지우는가 — 기준선을 빈 상태로 잡고 금지를 건 뒤 되돌린다.
    CB.clear_all_cargo_bans!()
    prev_baseline = CB._STATE_BASELINE[]
    try
        CB.capture_state_baseline!()
        CB.set_cargo_ban!(CB.RobotID(5), 2)
        @test !isempty(CB.STANDING_CARGO_BANS[])
        CB.reset_state_globals!()
        @test isempty(CB.STANDING_CARGO_BANS[])   # 이전 판의 금지가 다음 판으로 안 샌다
    finally
        CB._STATE_BASELINE[] = prev_baseline
        CB.clear_all_cargo_bans!()
    end
end

# ============================================================================
#  3. 🔴 G-5 — `extra_constraints` **없는** formulate 도 금지를 읽는가, 그리고 그것이
#     세계를 실제로 움직이는가.
#
#  🔴 T3-R1 / S-4.2: `_edge_owner_id` 는 **release 후에만** 쌍을 낸다. release 전에는
#     `ncand = 0` 이라 **어떤 금지도 0 행**을 내고 그 초록은 공허하다. 그래서 먼저 뗀다.
#     범위는 `agent =` 로 좁힌다(S-4.5/S-7: 전체 release 는 60초 안에 최적성을 증명 못 하고,
#     좁히면 0.2s 에 `OPTIMAL` 이다 — Task 6 이 그 인자를 이미 집행했다).
#  🔴 양성 대조 필수: 금지 **전에는** 그 로봇이 그 화물을 실제로 **가져갔다**는 것을 같은
#     픽스처에서 먼저 보인다. 안 그러면 "원래 안 가져갔다" 와 구별이 안 된다.
# ============================================================================

"배터리·hazard·에너지 가중치가 켜진 env 를 만들어 `target_closed` 작업이 끝난 시점까지 전진."
function fixture(; board = "tractor.mpd", nr = 10, target_closed = 60, maxstep = 6000)
    env = CB.run_lego_demo(; ldraw_file = board, project_name = "cargoban", num_robots = nr,
                             assignment_mode = :greedy, n_spare_per_pool = 2,
                             open_animation_at_end = false, save_animation = false,
                             write_results = false, return_env_before_sim = true,
                             rng = Random.MersenneTwister(1))
    # 🔴 셋 다 필요하다. run_lego_demo 는 배터리를 초기화하지 않고(→ :no_fleet),
    #    init_objective_weights! 없이는 목적함수가 edge_costs 를 통째로 버린다.
    CB.enable_battery!(env); CB.enable_hazard!(env; seed = 7); CB.init_objective_weights!()
    k = 0
    while length(CB.simstate_of(env).prog.closed) < target_closed && k < maxstep
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0); k += 1; CB.set_sim_step!(k)
    end
    # 🔴 상한에 걸리면 씬은 요청한 시점이 **아니다**(삼상 규약: 못 만들었으면 만들었다고 안 한다).
    got = length(CB.simstate_of(env).prog.closed)
    got < target_closed && error("fixture: 스텝 상한 $maxstep — closed = $got < $target_closed")
    return env
end

"해제 가능한 미래 배정 간선을 가장 많이 가진 로봇의 **ID**. 문자열이 아니라 ID 를 돌려준다."
function busiest_pending_agent(env)
    sched = env.sched
    frozen = CB.build_invariant(env).closed_nodes
    running = Set{CB.AbstractID}(CB.get_vtx_id(sched, v) for v in env.cache.active_set)
    untouchable(id) = id in frozen || id in running
    # 🔴 Dict 는 세는 데만 쓰고 **순회로 고르지 않는다** — 정렬 키가 순서를 지운다.
    t = Dict{String,Int}(); owner_of = Dict{String,CB.AbstractID}()
    for e in Graphs.edges(CB.get_graph(sched))
        CB.is_assignment_edge(sched, e.src, e.dst) || continue
        untouchable(CB.get_vtx_id(sched, e.src)) && continue
        untouchable(CB.get_vtx_id(sched, e.dst)) && continue
        o = CB._edge_owner_id(sched, e.src); o === nothing && continue
        s = string(o); t[s] = get(t, s, 0) + 1; owner_of[s] = o
    end
    isempty(t) && error("미래 배정 간선이 0 — 재분배 창이 닫혔다. target_closed 를 줄여라")
    best = sort(collect(t), by = kv -> (-kv[2], kv[1]))[1][1]   # 동점은 이름순 — 결정적
    return owner_of[best]
end

_nconstr(m) = JuMP.num_constraints(m; count_variable_in_set_constraints = false)

"""
`ForbidHeavyCargo(agent, n)` 이 **눌러야 하는** (u, v2) 쌍을 계약에서 **다시 유도한다**.
생산 코드의 `_heavy_cargo_targets` 를 부르지 않는다 — 그것과 대조하는 것이 목적이다.
"""
function oracle_forbidden_pairs(env, sched, Xa, agent, n)
    p = CB.BATTERY_FLEET[].params
    rv = SparseArrays.rowvals(Xa)
    owners(v2) = [rv[k] for k in SparseArrays.nzrange(Xa, v2)
                  if !Graphs.has_edge(sched, rv[k], v2) &&
                     (o = CB._edge_owner_id(sched, rv[k]); o !== nothing && o == agent)]
    meas = Tuple{Int,Float64,String}[]
    for v2 in 1:size(Xa, 2)
        isempty(owners(v2)) && continue
        b = CB.cargo_burden_after(env, sched, v2, p)
        b === nothing && continue                      # 못 쟀다 → 건너뛴다 (0 이 아니다)
        push!(meas, (v2, Float64(b), string(CB.get_vtx_id(sched, v2))))
    end
    sort!(meas; by = c -> (-c[2], c[3]))                # 부담 내림차순, 동점은 내용파생 문자열
    tgt = [c[1] for c in meas[1:min(n, length(meas))]]
    return [(u, v2) for v2 in tgt for u in owners(v2)], meas
end

# --- 판을 한 번만 짓는다 ------------------------------------------------------
CB.clear_all_cargo_bans!()                              # 🔴 앞 testset 의 잔재를 안 물려받는다
const ENV0  = fixture()
const AGENT = busiest_pending_agent(ENV0)
# 🔴 release 없이는 후보 간선이 0 이라 어떤 금지도 0행이다(S-4.2). 범위는 좁힌다(S-4.5).
const RELEASED = CB.release_pending_assignments!(ENV0, CB.build_invariant(ENV0);
                                                 agent = string(AGENT))
const SCHED = ENV0.sched
const INV   = CB.build_invariant(ENV0)                  # release **후**의 얼린 과거

# 🔴 솔버 전역 둘을 이 시험이 직접 소유한다(CLAUDE.md: 단독 실행은 초록, 스위트에서만 빨갛다).
#    앞서 도는 `Demo` 가 default optimizer 를 Gurobi 로, attributes 에 Gurobi 전용 `MIPFocus` 를
#    남긴다 → `Gurobi Error 10009` / `UnsupportedAttribute`. 여기서는 **실제로 푼다**.
const _PREV_OPT   = CB.default_milp_optimizer()
const _PREV_ATTRS = copy(CB.default_milp_optimizer_attributes())
CB.set_default_milp_optimizer!(CB.HiGHS.Optimizer)
CB.clear_default_milp_optimizer_attributes!()

"""
🔴 `rebalance_for_battery!`(`battery.jl`)의 **호출 모양 그대로** — `extra_constraints` 를
아예 안 준다. 훅이 `if extra_constraints !== nothing` 안에 있으면 이 경로는 금지를 못 본다.
"""
_rebalance_shape() = CB.formulate_milp(CB.SparseAdjacencyMILP(), SCHED, ENV0.scene_tree;
                                       optimizer = CB.HiGHS.Optimizer,
                                       t0_ = INV.frozen_t0, tF_ = INV.frozen_tF)

@testset "🔴 픽스처가 비퇴화다 (이걸 먼저 단언한다)" begin
    @test length(RELEASED) > 0                          # 좁힌 release 가 실제로 간선을 뗐다
    @test CB.BATTERY_FLEET[] !== nothing                # 부담을 잴 파라미터가 있다
    @test isempty(CB.STANDING_CARGO_BANS[])             # 대조군은 진짜 대조군이다
    m = _rebalance_shape()
    @test SparseArrays.nnz(m.Xa) > 0                    # 후보 결정변수가 존재한다
    @test _nconstr(m.model) > 1000
    pairs, meas = oracle_forbidden_pairs(ENV0, SCHED, m.Xa, AGENT, 1)
    @test !isempty(meas)                                # 🔴 잰 도착점이 0 이면 아래가 전부 공허하다
    @test !isempty(pairs)                               # 🔴 누를 쌍이 0 이면 G-5 는 공허하다
    @info "픽스처: released=$(length(RELEASED)) agent=$(string(AGENT)) " *
          "nnz(Xa)=$(SparseArrays.nnz(m.Xa)) 잰도착점=$(length(meas)) " *
          "n=1 이 누를 쌍=$(length(pairs)) 부담범위=$(extrema(c[2] for c in meas))"
end

@testset "🔴 G-5 verify 와 rebalance 경로도 금지를 읽는다 (extra_constraints = nothing)" begin
    try
        # --- 대조(금지 없음) ------------------------------------------------
        CB.clear_all_cargo_bans!()
        milp_c = _rebalance_shape()
        nc_c   = _nconstr(milp_c.model)
        pairs, meas = oracle_forbidden_pairs(ENV0, SCHED, milp_c.Xa, AGENT, 1)

        # --- 처치(금지 있음). `extra_constraints` 는 여전히 **안 준다** -------
        CB.set_cargo_ban!(AGENT, 1)
        milp_t = _rebalance_shape()
        nc_t   = _nconstr(milp_t.model)
        ban_rows = nc_t - nc_c

        # 🔴 계획서가 직접 요구한 두 숫자. 0 이면 이 시험은 공허하다.
        @info "G-5 행 수: 대조(금지없음) = $(nc_c) · 처치(금지) = $(nc_t) · 금지행 = $(ban_rows)"
        @test ban_rows > 0                              # 🔴 이 한 줄이 hollow admit 을 막는다
        @test ban_rows == length(pairs)                 # 독립 기대값과 일치
        # 훅이 부른 헬퍼의 반환값도 같은 수여야 한다(장부가 세계와 어긋나지 않는다).
        old = CB.RESPEC_SCENE_TREE[]; CB.RESPEC_SCENE_TREE[] = ENV0.scene_tree
        try
            probe = _rebalance_shape()   # 위 훅과 무관한 새 모델 — 여기 직접 걸어 본다
            before = _nconstr(probe.model)
            r = CB._compile_standing_cargo_bans!(probe.model, probe.model[:t0],
                                                 probe.model[:tF], probe.Xa, SCHED)
            @test r == _nconstr(probe.model) - before   # 반환값이 거짓말하지 않는다
            @test r == ban_rows
        finally
            CB.RESPEC_SCENE_TREE[] = old
        end

        # --- 🔴 양성 대조: 금지 **전에는** 그 로봇이 그 화물을 가져간다 -------
        CB.set_time_limit_sec(milp_c, 60.0); CB.optimize!(milp_c)
        @test CB.primal_status(milp_c) == CB.MOI.FEASIBLE_POINT
        taken_c = count(uv -> JuMP.value(milp_c.Xa[uv[1], uv[2]]) > 0.5, pairs)
        # --- 처치: 같은 픽스처에서 그 배정이 사라진다 -------------------------
        CB.set_time_limit_sec(milp_t, 60.0); CB.optimize!(milp_t)
        taken_t = count(uv -> JuMP.value(milp_t.Xa[uv[1], uv[2]]) > 0.5, pairs)
        @info "G-5 세계: 양성대조(금지없음) 그 로봇이 잡은 금지대상 간선 = $(taken_c) · " *
              "처치 = $(taken_t) · term 대조=$(CB.termination_status(milp_c)) " *
              "처치=$(CB.termination_status(milp_t))"
        # 🔴 이 줄이 없으면 "원래 안 가져갔다" 와 구별이 안 된다 — 공허한 초록의 정확한 모양.
        @test taken_c > 0
        @test taken_t == 0
        # 🔴 금지가 라인을 죽이지 않는다 — 화물은 **다른 로봇**이 맡는다(퇴역이 아니라 선별).
        @test CB.primal_status(milp_t) == CB.MOI.FEASIBLE_POINT

        # --- 제안이 함께 있어도 둘 다 컴파일된다(verify 경로: extra_constraints ≠ nothing) --
        # ⚠️ 여기서 `ForbidAgent(AGENT, 0.0)` 을 쓰면 안 된다 — 이 픽스처(좁힌 release 후)에서
        #    그 컴파일러는 **0 행**을 낸다(실측). 0 행짜리 제안으로는 "훅이 제안을 대체하지
        #    않는다" 를 못 가른다. 행을 실제로 내는 제약을 쓴다.
        cs = CB.ForbidHeavyCargo(AGENT, 1)
        CB.clear_all_cargo_bans!()
        n_prop = _nconstr(CB.formulate_milp(CB.SparseAdjacencyMILP(), SCHED, ENV0.scene_tree;
                    optimizer = CB.HiGHS.Optimizer, t0_ = INV.frozen_t0, tF_ = INV.frozen_tF,
                    extra_constraints = CB.RespecProposal(CB.ConstraintSpec[cs])).model) - nc_c
        CB.set_cargo_ban!(AGENT, 1)
        n_both = _nconstr(CB.formulate_milp(CB.SparseAdjacencyMILP(), SCHED, ENV0.scene_tree;
                    optimizer = CB.HiGHS.Optimizer, t0_ = INV.frozen_t0, tF_ = INV.frozen_tF,
                    extra_constraints = CB.RespecProposal(CB.ConstraintSpec[cs])).model) - nc_c
        @info "G-5 verify 경로: 제안만 = $(n_prop) 행 · 제안+금지 = $(n_both) 행"
        @test n_prop > 0                                 # 제안이 공허하지 않다
        @test n_both == n_prop + ban_rows                # 훅이 제안을 **대체하지 않고 더한다**
    finally
        CB.clear_all_cargo_bans!()   # 🔴 다음 시험 파일의 formulate 를 오염시키지 않는다
    end
end

@testset "🔴 금지가 없으면 formulate 는 오늘과 바이트 동일이다 (음성 대조)" begin
    @test isempty(CB.STANDING_CARGO_BANS[])
    m1 = _rebalance_shape(); m2 = _rebalance_shape()
    @test _nconstr(m1.model) == _nconstr(m2.model)
    # 빈 보관소에서 훅은 0 행이다 — 이 값이 0 이 **아니면** 어딘가에서 금지가 새고 있다.
    old = CB.RESPEC_SCENE_TREE[]; CB.RESPEC_SCENE_TREE[] = ENV0.scene_tree
    try
        @test CB._compile_standing_cargo_bans!(m1.model, m1.model[:t0], m1.model[:tF],
                                               m1.Xa, SCHED) == 0
    finally
        CB.RESPEC_SCENE_TREE[] = old
    end
    # 🔴 훅은 씬트리를 되돌린다 — 전역 오염 금지(Task 2 의 `finally` 가 이제 `if` 밖에 있다).
    @test CB.RESPEC_SCENE_TREE[] === nothing
end

@testset "🔴 부담 계층이 없으면 훅은 런을 죽이지 않고 크게 알린 뒤 0 행을 낸다" begin
    # 컨트롤러 판정 2026-09-02: 배터리는 opt-in 이고 `run_lego_demo` 는 안 켠다. 훅이 **모든**
    # formulate 에서 도는 이상 "금지가 서 있다 × 배터리 없는 판" 은 도달 가능한 조합이고,
    # Task 2 의 `error` 를 그대로 타면 `verifier.jl` 이 LLM 문법 없는 제안에서 예외를 되던져
    # `route_planning.jl` 까지 풀려 올라가 **런이 죽는다**. 그 처신을 여기서 못 박는다.
    saved_fleet = CB.BATTERY_FLEET[]
    try
        CB.clear_all_cargo_bans!()
        base = _nconstr(_rebalance_shape().model)
        CB.set_cargo_ban!(AGENT, 1)
        CB.BATTERY_FLEET[] = nothing                       # 부담을 잴 파라미터를 뺀다
        m = @test_logs (:warn,) match_mode = :any _rebalance_shape()   # 🔴 조용한 0 이 아니다
        @test _nconstr(m.model) == base                    # 0 행 — 집행되지 않는다(대가는 실재)
        # 🔴 음성 대조: 같은 금지가 배터리가 있을 때는 행을 낸다. 없으면 위 0 은 공허하다.
        CB.BATTERY_FLEET[] = saved_fleet
        @test _nconstr(_rebalance_shape().model) > base
    finally
        CB.BATTERY_FLEET[] = saved_fleet
        CB.clear_all_cargo_bans!()
    end
end

# 🔴 빌린 전역을 돌려준다.
CB.set_default_milp_optimizer!(_PREV_OPT)
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!(_PREV_ATTRS)
CB.clear_all_cargo_bans!()

end # module
