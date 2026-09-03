# test/cargo_ban_moves_work.jl
# ============================================================================
#  이 파일이 지키는 것: 주조된 tool 의 **body 가 돈 세계에서 그 로봇이 실제로 그 화물을 잃는다**
#  (cargo-ban 계획 Task 8, 게이트 G-2).
#
#  body 는 둘이다 — 이 파일은 그 둘을 **원시로 직접** 부른다(집행 진입점을 안 지난다, 아래 (I)):
#      1. release_pending_assignments!(env, invariant; agent="…")   ← 좁힌 release
#      2. forbid_heavy_cargo!(env; agent="…", n=1)
#
# ----------------------------------------------------------------------------
#  🔴 이 게이트가 반드시 피해야 하는 **거짓 초록** (전부 Task 1 이 실측했다, `5456124f`)
#
#  (A) 🔴 **`binding` 으로 판정하면 안 된다.** 아무것도 안 누른 음성 대조에서도 A 가 이미 묶인
#      정점 2~11개를 잃고(재풀이 잡음), `release_pending_assignments!` 는 표적 슬롯을 solve
#      **전에** 음수 무효 id 로 되돌리므로 `binding` 에는 잃을 것이 남아 있지 않다.
#      계획서 G-2 의 스케치가 `binding` 을 쓰지만 shared-rulings S-4.4 가 그것을 뒤집었다.
#      ⟹ 판정은 **`JuMP.value(Xa[u,v2]) > 0.5` + 음성 대조**다.
#  (B) 🔴 **음성 대조가 없으면 이 시험은 무가치하다.** "처리 팔에서 A 가 그 슬롯을 안 가져갔다"
#      만으로는 "원래 안 가져갔다"와 구별이 안 된다. 그래서 **같은 env·같은 그래프** 위에서
#      금지를 비운 팔을 함께 돈다(`STANDING_CARGO_BANS[]` 하나만 다르다).
#  (C) 🔴 **`n_reassigned` 는 증거가 아니다** — `n_reassigned = 11` 인데 대상 로봇이 잃은 작업이
#      0 인 판이 여러 번 나왔다. 이 파일은 그 값을 안 읽는다.
#  (D) 🔴 **`makespan(env.sched)` 도 목적값도 판정에 안 쓴다.** 전자는 Big-M 센티넬(10012 등)이
#      나왔고, 후자는 `TIME_LIMIT` 행에서 제약을 더했는데 내려가는 판이 실제로 나온다.
#  (E) 🔴 **`_edge_owner_id` 는 release **후에만** 쌍을 낸다**(S-4.2). release 전에 금지를 재면
#      후보가 0 이라 **어떤 금지도 0 행**이고 그 초록은 공허하다. 그래서 `measure()` 의 첫
#      원시가 release 이고, 이 파일은 "release 가 실제로 슬롯을 뗐다"를 먼저 단언한다.
#  (F) 🔴 **commit 하지 않는다.** 판정이 `value(Xa)` 이므로 필요 없고, 안 하면 두 팔이
#      바이트 동일한 그래프를 본다. `fork()`(→ `rvo_rebuild!` 가 프로세스 전역 RVO 를 변형)도
#      쓰지 않는다 — Task 1 의 한 라운드가 그 오염으로 통째로 철회됐다(S-4.7).
#
#  (G) 🔴 **계획서의 `lost_by_agent_control == 0` 은 단언하지 않는다 — 실측으로 그것이 환경
#      의존이기 때문이다.** 깨끗한 프로세스에서는 대조가 뗀 슬롯을 **전부 회수한다**(5/5).
#      그런데 `Pkg.test()` 안에서는 **같은 코드가 다른 세계를 짓고**(목적값 12.55 vs 14.55,
#      정점 번호도 다르다) 대조도 슬롯 하나를 잃는다. 2026-09-02 실측:
#          뗀 슬롯 [225,227,277,279,301] · 표적 301
#          대조 잃음 [277]        ← 🔴 재풀이 잡음. 표적이 **아니다**
#          처리 잃음 [277, 301]   ← 잡음 + **표적**
#      ⟹ 그 한 칸을 절대값으로 단언하면 게이트가 "금지가 도는가" 대신 "재풀이 잡음이 0인가" 를
#      재게 된다. 그래서 판정을 **차집합**으로 옮겼다. 잡음은 양쪽에 공통이라 저절로 지워지고,
#      남는 것은 **금지가 실제로 옮긴 화물**이다. 두 환경 모두에서 참이다.
#      (`SIM_STEP`·`ASSET_LEDGER`·`EDGE_PAYLOAD_MULTIPLIER`·`AGENT_COST_BIAS` 를 이 파일이
#      직접 소유해 되감아도 이 차이는 남는다 — 즉 원인은 그 넷이 아니다.)
#      🔴 **원인 설명 정정(2026-09-02).** 이 자리에 원래 "이 브랜치에는 `AbstractID` 의 내용기반
#      `Base.hash`(`bb1b88c4`)가 **없다**" 가 적혀 있었다. 그 커밋 자체는 지금도 없지만 **같은
#      수정이 `bb5e23f2` 로 들어와 있다.** 위 실측은 그 수정이 없던 세계의 것이고, 스위트 안팎의
#      차이가 오늘도 남아 있는지는 **다시 안 쟀다**(스위트 안에서는 `global_logger` 가
#      `Logging.Warn` 이라 이 파일의 `@info` 가 통째로 버려져 읽을 수 없다 — CLAUDE.md 의 그 함정).
#      ⟹ 판정을 차집합으로 옮긴 **결정은 그대로 유효하다**(그 형태는 어느 쪽 세계에서도 참이다).
#      근거 문장 하나가 약해졌을 뿐이다.
#
#  (H) 🔴 **차집합의 상등(`setdiff(…) == [표적]`)조차 너무 셌다 — 2026-09-02 에 완화했다.**
#      그 형태는 "표적 말고는 **아무것도** 안 움직였다" 까지 요구하는데, 금지 행을 더한 재풀이는
#      **같은 비용의 다른 최적해**로 갈 자유가 있어(해의 퇴화) 무관한 배정이 팔 사이에서 뒤섞인다.
#      실제로 `:310` 과 `:312` 가 함께 빨개졌다(`[225,300] == [300]`, 재실행에선 `[225,301]`).
#      부수적 이동은 게이트의 주장을 **반증하지 않는다**. ⟹ 판정은 **소속**이다:
#      `표적 ∈ setdiff(처리 잃음, 대조 잃음)` + 양성 대조(대조는 가져간다) + 음성(처리는 안 가져간다).
#      같은 이유로 단조성 `issubset` 과 개수 비교 `처리.lost > 대조.lost` 도 뺐다(둘 다 퇴화 민감).
#
#  (I) 🔴 **이 파일은 `enact_minted!` 를 지나지 않는다 — 2026-09-02 에 측정을 밖으로 뺐다.**
#      판정 1 이 집행부 끝에 **공통 재풀이**를 넣었다(`src/respec/minted_tool.jl` (9) 단계의
#      `_resolve_if_needed!`). 이 파일은 집행 **직후에** 간선을 읽는데, 그 시점이면 하네스가
#      뜬 슬롯을 이미 다시 붙여 놨다. 실측 대조(2026-09-02, 같은 픽스처):
#          간선 43→38 · 뗀 슬롯 5 · 표적 v2=237  · 금지가 건 행 4      ← 판정 1 **이전**
#          간선 43→43 · 뗀 슬롯 2 · 표적 nothing · 금지가 건 행 0      ← 판정 1 **이후**
#      🔴 마지막 칸이 곧 위 (E) 다. 재풀이는 MILP 관점에서 그래프를 **release 이전** 조건으로
#      되돌리므로 후보 간선이 0 이 되고, 그러면 **어떤 금지도 0 행**이라 초록이 공허해진다.
#      (뗀 슬롯 2 도 금지의 효과가 아니라 재풀이 잡음이다 — (G) 가 잰 그 잡음이다.)
#      ⟹ `measure()` 가 두 원시를 **직접** 부른다. 인자 결합은 집행부의 harness 바인딩과 같다
#      (`invariant` ← `build_invariant(env)`, `minted_tool.jl:727`). 거짓 초록 방어 (A)~(H) 는
#      **전부 그대로** 유지된다: 같은 env · commit 없음 · fork 없음 · 차집합 · 소속, 그리고
#      픽스처는 하나다.
#      🔴 **"커밋된 세계로 판정" 은 선택지가 아니다** — (A)(C)(D) 가 이미 그 길을 닫았고, 게다가
#      대조군을 만들려면 금지 없는 세계가 하나 더 필요해 `fixture()` 를 두 번 지어야 하는데
#      (= `run_lego_demo` + 6000 스텝 재실행) 두 보드가 바이트 동일하다는 보장이 없다. 차집합
#      트릭 전체가 "두 팔이 같은 세계를 본다"는 (F)의 전제 위에 서 있다.
#      대가는 하나뿐이다: 이 파일은 더 이상 "**집행 경로를 지나서**" 를 한 호흡에 주장하지 않는다.
#      **그 절반은 다른 곳이 진다**:
#        · `tools/monitor/test_minted_wiring.jl` (2c)/(2d) — sched·milp 표면 body 뒤에 재풀이가
#          실제로 불리고(실패하면 `handled=false`), 아닌 표면 뒤엔 안 불리며 그 사실이
#          `resolve=not_needed_surface` 로 기록된다.
#        · `test/minted_tool_enacts.jl` — body 집행 자체(단계·status·삼상).
#      여기가 지는 것은 **인과 한 줄**이다: 그 두 원시가 돈 세계에서 금지된 로봇이 그 화물을 잃는다.
#
#  🔴 **변이 시험을 다시 했다**(2026-09-02, 측정을 (I) 로 옮긴 **뒤**). 셋 다 빨개진다 —
#     그리고 셋 다 **자칭 성공을 무시하고 세계를 잰 줄**이 잡았다:
#       · m1 금지 원시를 **안 부르고** `(status=:banned,…)` 를 자칭한다
#         → `length(STANDING_CARGO_BANS[]) == 1` 과 소유자 이름 줄이 빨개진다(8 pass / 2 fail).
#       · m2 release 를 **안 하고** 간선 목록 `[(0,0)]` 을 자칭한다
#         → `M.e1 < M.e0` · `!isempty(M.slots)` 가 빨개진다(간선 43→43, 뗀슬롯 0 = 위 (E)의 세계).
#       · m3 처리 팔을 **금지 없이** 푼다 → `M.trt.nconstr > M.ctl.nconstr` 가 빨개진다(금지행 0).
#     ⟹ `M.rel`/`M.ban` 의 반환값 단언은 진단용이고, 게이트를 실제로 지는 것은 그 아래 세 줄이다.
#
#  🔴 runtests.jl 이 모든 시험 파일을 같은 `Main` 스코프에 include 하므로 자기 module 로 감싼다.
# ============================================================================
module CargoBanMovesWorkTests

using Test
using ConstructionBots
using Graphs, Random, JuMP, SparseArrays
const CB = ConstructionBots

# 🔴 런타임 include 는 **모듈 최상위**에 있어야 한다(world-age). 순서도 load-bearing:
#    navigator 먼저(부담 계층), 그 다음 mdp(`simstate_of`). 계획 README 의 공용 픽스처는 이 두
#    줄이 빠져 있어 그대로 쓰면 `UndefVarError: enable_battery!` 로 죽는다(S-4.9).
const REPO = abspath(joinpath(@__DIR__, ".."))
isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))
isdefined(CB, :simstate_of)  || CB.include(joinpath(REPO, "src", "smdp", "mdp.jl"))

const TL = 60.0

"""
배터리·hazard·에너지 가중치가 켜진 env 를 `target_closed` 까지 전진시킨다. 셋 다 필요하다:
`run_lego_demo` 는 배터리를 초기화하지 않고(→ 부담 계층 부재 → 금지 0행),
`init_objective_weights!` 없이는 목적함수가 `edge_costs` 를 통째로 버린다.
🔴 상한에 걸리면 **에러**다(삼상 규약: 못 만든 씬을 만들었다고 하지 않는다).
"""
function fixture(; board = "tractor.mpd", nr = 10, target_closed = 60, maxstep = 6000)
    # 🔴 프로세스 전역을 되감는다. `run_lego_demo` 는 `SIM_STEP` 도 `ASSET_LEDGER` 도 리셋하지
    #    않고(`reset_asset_ledger!()` 는 src/ 안에 호출자 0개), 아래 루프가 `step_environment!` 를
    #    `set_sim_step!` 보다 먼저 부르므로 **첫 스텝이 앞 시험의 시계로 hazard 를 맞춘다**
    #    (S-4.7 이 지목한 경계 누수). 단독 실행은 0 에서 시작하므로 이 줄이 없으면
    #    `Pkg.test()` 안에서만 다른 세계를 잰다 = CLAUDE.md 의 단골 사고.
    CB.set_sim_step!(0)
    CB.reset_asset_ledger!()
    env = CB.run_lego_demo(; ldraw_file = board, project_name = "cargobanmoves", num_robots = nr,
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
    return env
end

"스케줄 그래프에 지금 서 있는 배정 간선(free → slot) 집합."
function assignment_edges(sched)
    out = Set{Tuple{Int,Int}}()
    for e in Graphs.edges(CB.get_graph(sched))
        CB.is_assignment_edge(sched, e.src, e.dst) && push!(out, (e.src, e.dst))
    end
    return out
end

"""
떼어질 수 있는(= 미래) 배정 간선을 가장 많이 소유한 로봇의 `(id, 모듈한정 문자열)`.
🔴 `Dict` 는 세는 데만 쓰고 순회로 고르지 않는다 — 정렬 키 `(-개수, 이름)` 이 순서를 지운다(S-6).
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
    isempty(tally) && error("미래 배정 간선이 0 — 재분배 창이 닫혔다. target_closed 를 줄여라")
    best = sort(collect(tally), by = kv -> (-kv[2], kv[1]))[1][1]
    return (id = owner_of[best], str = best)
end

"""
`resolve_assignments!`(`src/smdp/generative.jl` — 모든 팔 뒤에 도는 공통 재풀이)와 **같은 정식화**
를 세워 푼다: 과거를 얼리고 `extra_constraints` 없이 formulate → optimize. 금지는 오직
`formulate_milp` 안의 훅(`_compile_standing_cargo_bans!`)으로만 들어온다.
🔴 commit 하지 않는다(위 머리말 (F)). 판정은 `value(Xa)` 다.

`released_slots` 중 A 가 다시 가져간 슬롯 수(`recovered`)와 못 가져간 수(`lost`)를 돌려준다.
"""
function solve_arm(env, aid, released_slots)
    sched = env.sched
    inv = CB.build_invariant(env)
    sent = Dict{Tuple{Int,Int},Float64}(); CB.LAST_EDGE_COSTS[] = sent
    milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), sched, env.scene_tree;
                             optimizer = CB.HiGHS.Optimizer,
                             t0_ = inv.frozen_t0, tF_ = inv.frozen_tF)
    # 🔴 formulate 가 실제로 돌았는지 — 안 돌았으면 아래 전부가 공허하다.
    ran = CB.LAST_EDGE_COSTS[] !== sent
    ncand = ran ? length(CB.LAST_EDGE_COSTS[]) : 0
    Xa = milp.Xa
    nconstr = JuMP.num_constraints(milp.model; count_variable_in_set_constraints = false)
    old_st = CB.RESPEC_SCENE_TREE[]
    CB.RESPEC_SCENE_TREE[] = env.scene_tree
    targets = try
        CB._heavy_cargo_targets(sched, Xa, aid, 1)
    finally
        CB.RESPEC_SCENE_TREE[] = old_st
    end
    CB.set_time_limit_sec(milp, TL)
    wall = @elapsed CB.optimize!(milp)
    ts = CB.termination_status(milp); ps = CB.primal_status(milp)
    feasible = ps == CB.MOI.FEASIBLE_POINT
    rv = SparseArrays.rowvals(Xa)
    # A 가 슬롯 v2 로 가는 후보 간선을 실제로 골랐는가 (해가 없으면 `nothing`).
    function takes(v2)
        feasible || return nothing
        v2 <= size(Xa, 2) || return false
        for k in SparseArrays.nzrange(Xa, v2)
            u = rv[k]
            CB.isassigned_edge(Xa, u, v2) || continue
            o = CB._edge_owner_id(sched, u)
            (o !== nothing && o == aid) || continue
            JuMP.value(Xa[u, v2]) > 0.5 && return true
        end
        return false
    end
    rec = feasible ? count(v2 -> takes(v2) === true, released_slots) : nothing
    lost_slots = feasible ? [v2 for v2 in released_slots if takes(v2) !== true] : Int[]
    tv2 = isempty(targets) ? nothing : targets[1]
    obj = feasible ? (try JuMP.objective_value(milp.model) catch; nothing end) : nothing
    return (ran = ran, ncand = ncand, nconstr = nconstr, tstat = ts, pstat = ps,
            wall = wall, feasible = feasible, target_v2 = tv2, obj = obj,
            recovered = rec, lost = rec === nothing ? nothing : length(released_slots) - rec,
            lost_slots = lost_slots,
            takes_target = tv2 === nothing ? nothing : takes(tv2))
end

"금지를 비운 채 한 팔을 돈다(음성 대조). `Ref` 를 갈아끼웠다 `finally` 로 되돌린다."
function solve_control(env, aid, released_slots)
    saved = CB.STANDING_CARGO_BANS[]
    CB.STANDING_CARGO_BANS[] = Dict{CB.AbstractID,Int}()
    try
        return solve_arm(env, aid, released_slots)
    finally
        CB.STANDING_CARGO_BANS[] = saved
    end
end

# ============================================================================
#  🔴 **솔버 전역 둘을 이 시험이 직접 소유한다**(CLAUDE.md: "전역을 읽는 시험은 try/finally 로
#  직접 소유·복원할 것 — 단독 실행은 초록, 스위트에서만 빨갛다"). 이 파일은 실제로 **푼다**:
#   (1) `_respec_optimizer()` 는 `default_milp_optimizer()` 를 먼저 보는데 앞서 도는 `Demo`
#       시험이 그 전역을 Gurobi 로 덮어쓴다 → `Gurobi Error 10009: No Gurobi license found`.
#   (2) 솔버만 HiGHS 로 바꿔도 `formulate_milp` 이 `default_milp_optimizer_attributes()` 를
#       무조건 적용하는데 거기 Gurobi 전용 `MIPFocus` 가 남아 있다 → `UnsupportedAttribute`.
# ============================================================================
const _PREV_OPT   = CB.default_milp_optimizer()
const _PREV_ATTRS = copy(CB.default_milp_optimizer_attributes())
const _PREV_BANS  = copy(CB.STANDING_CARGO_BANS[])
# 🔴 **간선 비용에 손대는 전역 둘도 빌린다.** 둘 다 `formulate_milp` 이 만드는 목적함수를 바꾸므로
#    (`essential_tg_coponents.jl` 의 `EDGE_PAYLOAD_MULTIPLIER[]` 곱셈 · `agent_cost_bias`),
#    앞선 시험이 하나라도 남기면 이 파일은 **다른 목적함수 위에서** 대조를 재게 된다.
const _PREV_MULT  = CB.EDGE_PAYLOAD_MULTIPLIER[]
const _PREV_BIAS  = copy(CB.AGENT_COST_BIAS[])
CB.set_default_milp_optimizer!(CB.HiGHS.Optimizer)
CB.clear_default_milp_optimizer_attributes!()
CB.EDGE_PAYLOAD_MULTIPLIER[] = nothing
CB.clear_agent_bias!()

function _restore_globals!()
    CB.set_default_milp_optimizer!(_PREV_OPT)
    CB.clear_default_milp_optimizer_attributes!()
    CB.set_default_milp_optimizer_attributes!(_PREV_ATTRS)
    CB.clear_all_cargo_bans!()
    for (k, v) in _PREV_BANS; CB.set_cargo_ban!(k, v); end
    CB.EDGE_PAYLOAD_MULTIPLIER[] = _PREV_MULT
    CB.clear_agent_bias!()
    for (k, v) in _PREV_BIAS; CB.AGENT_COST_BIAS[][k] = v; end
    return nothing
end

"""
한 번의 측정 전체 — 픽스처 · **두 원시 직접 호출** · 두 팔. 🔴 **집계는 전부 함수 안**이다
(Julia soft scope: 최상위 `for` 의 카운터는 조용한 0 이 된다). 반환값 하나를 아래 testset 들이
나눠 읽는다.

🔴 **여기를 `enact_minted!` 한 줄로 "복원" 하지 마라 — 머리말 (I) 가 그 자리다.** 집행부 (9)
단계의 공통 재풀이가 아래 `e1` 을 읽기 **전에** 뜬 슬롯을 다시 붙여, 금지가 0 행이 되고 초록이
공허해진다(= (E)). 두 원시의 인자 결합은 집행부의 harness 바인딩과 같다
(`invariant` ← `build_invariant(env)`, `minted_tool.jl:727`; `n=1` — 레지스트리가 `"integer"`).
"""
function measure()
    CB.clear_all_cargo_bans!()
    env  = fixture()
    ag   = busiest_pending_agent(env)
    e0   = assignment_edges(env.sched)
    b0   = length(CB.STANDING_CARGO_BANS[])
    rel  = CB.release_pending_assignments!(env, CB.build_invariant(env); agent = ag.str)
    ban  = CB.forbid_heavy_cargo!(env; agent = ag.str, n = 1)
    e1   = assignment_edges(env.sched)
    slots = sort!(unique!([v2 for (_, v2) in setdiff(e0, e1)]))
    # 🔴 대조를 먼저 돈다. 두 팔은 같은 env·같은 그래프를 보고 commit 을 안 하므로 순서가
    #    결과를 바꿀 수 없다 — 그 전제를 두 번째 testset 이 구조 대조로 직접 확인한다.
    ctl = solve_control(env, ag.id, slots)
    trt = solve_arm(env, ag.id, slots)
    return (env = env, agent = ag, e0 = length(e0), e1 = length(e1), bans0 = b0,
            rel = rel, ban = ban, slots = slots, ctl = ctl, trt = trt)
end

# 🔴 여기서 던지면 빌린 전역이 스위트 나머지로 샌다 — 되돌리고 다시 던진다.
M = try
    measure()
catch
    _restore_globals!()
    rethrow()
end

# 🔴 아래 testset 중 하나라도 실패하면 그 자리에서 던져 파일이 중단된다 — 그러면 맨 끝의
#    복원 줄에 영영 못 닿아 HiGHS + 비워진 속성이 스위트 나머지로 샌다. `finally` 로 막는다.
#    (이 구간에는 `const` 선언이 없다 — `const` 는 지역 스코프에 들어갈 수 없다.)
try

@testset "🔴 픽스처가 비퇴화다 (이걸 먼저 단언한다)" begin
    @test CB.BATTERY_FLEET[] !== nothing              # 부담을 잴 계층이 있다
    @test M.bans0 == 0                                # 금지가 없는 데서 출발했다
    # 🔴 두 원시가 각각 **읽을 수 있는 성공**을 냈다. release 는 간선 목록을 돌려준다
    #    (`EDGELIST_RETURN_PRIMITIVES`) — NamedTuple 이면 집행부가 `:unknown_agent` 로 읽을
    #    모양이고, 빈 목록이면 `:released_none` 이다. 둘 다 그 뒤가 통째로 공허하다.
    @test M.rel isa Vector{Tuple{Int,Int}}            # 🔴 :unknown_agent 면 여기서 죽는다
    @test !isempty(M.rel)                             # 🔴 :released_none 이면 공허
    @test M.ban.status === :banned                    # 🔴 :invalid_n/:no_schedule/:unknown_agent 면 공허
    @test M.ban.n == 1
    # 🔴 반환값은 증거가 아니다 — 세계를 직접 잰다.
    @test M.e1 < M.e0                                 # release 가 실제로 간선을 뗐다
    @test !isempty(M.slots)                           # 🔴 뗀 슬롯이 0 이면 아래 전부 공허하다
    @test length(CB.STANDING_CARGO_BANS[]) == 1       # 보관소에 항목이 정확히 하나 생겼다
    @test M.agent.str in string.(collect(keys(CB.STANDING_CARGO_BANS[])))
    @info "픽스처: closed=$(length(CB.simstate_of(M.env).prog.closed)) agent=$(M.agent.str) " *
          "간선 $(M.e0)→$(M.e1) 뗀슬롯=$(length(M.slots))"
end

@testset "🔴 두 팔이 같은 판을 봤다 (대조의 전제)" begin
    @test M.ctl.ran && M.trt.ran                      # 두 formulate 가 다 돌았다
    @test M.ctl.ncand == M.trt.ncand                  # 후보 간선 구조가 같다
    @test M.ctl.target_v2 !== nothing                 # 금지 대상이 실재한다
    @test M.ctl.target_v2 == M.trt.target_v2          # 같은 화물을 본다
    # 🔴 금지가 **행을 실제로 걸었는가** — 0 이면 처리 팔은 대조와 같은 모델이고 이 게이트는 공허.
    @test M.trt.nconstr > M.ctl.nconstr
    @test M.ctl.feasible && M.trt.feasible            # 해가 없으면 판정 불가(0 이 아니다)
    @info "팔: 대조 $(M.ctl.tstat)/$(round(M.ctl.wall; digits=3))s 행=$(M.ctl.nconstr) · " *
          "처리 $(M.trt.tstat)/$(round(M.trt.wall; digits=3))s 행=$(M.trt.nconstr) " *
          "(금지행 = $(M.trt.nconstr - M.ctl.nconstr)) 표적 v2=$(M.ctl.target_v2)"
end

@testset "🔴 G-2 금지된 로봇이 그 화물을 실제로 잃는다" begin
    # 🔴 **양성 대조**: 금지가 없으면 A 가 그 화물을 **가져간다**. 이것이 없으면 "처리에서 A 가
    #    안 가져갔다" 는 "원래 안 가져갔다" 와 구별되지 않는다.
    @test M.ctl.takes_target === true
    # 🔴 처리: 금지를 걸면 **그 화물을 안 가져간다.**
    @test M.trt.takes_target === false
    # 🔴 **이 파일의 핵심 단언.** 표적은 **처리가 잃고 대조는 안 잃은** 슬롯 안에 있다.
    #    잡음(양쪽이 똑같이 잃는 슬롯)은 차집합에서 저절로 지워진다.
    #
    #    🔴 **여기를 `== [표적]` 같은 집합 상등으로 "복원"하지 마라.** 두 번 빨개진 자리다
    #    (`[225,300] == [300]` · 단독 재실행에서는 `[225,301] == [301]`). 이유는 금지가
    #    새는 것이 **아니라 MILP 해의 퇴화(degeneracy)** 다: 금지 행을 더하면 재풀이는
    #    **같은 비용의 다른 최적해**로 갈 자유가 있고, 그때 표적과 무관한 배정들이 팔 사이에서
    #    통째로 뒤섞인다. 그 부수적인 이동은 "금지된 화물이 금지 때문에 옮겨갔다" 를
    #    **반증하지 않는다**. 그리고 절대 정점 번호 자체가 측정 사이에 갈린다 — 실측:
    #    같은 표적이 `293`(2026-09-02 첫 측정) → `237`(같은 날 재측정)이었고, 그 사이에
    #    `bb5e23f2`(`AbstractID` 의 내용기반 `Base.hash`)가 들어왔다. ⚠️ 위 (G) 의 정정을
    #    함께 읽을 것 — 옛 주석의 "이 브랜치엔 그 hash 가 없다" 는 더 이상 참이 아니다.
    #    어느 쪽이든 **슬롯 집합의 상등도, 절대 정점 id 도** 단언 대상이 아니다. 단언해야 할 것은 인과뿐이고, 그것은 아래 한 줄과 위 양성/음성 대조가 진다.
    #    (같은 이유로 옛 `issubset(대조 잃음, 처리 잃음)` 단조성과 `처리.lost > 대조.lost`
    #     개수 비교도 뺐다 — 둘 다 표적 아닌 슬롯의 뒤섞임에 걸려 넘어진다. 실제로 `:312` 가
    #     `:310` 과 함께 빨개졌다. 표적에 한정한 형태는 아래 한 줄이 이미 담고 있다.)
    @test M.ctl.target_v2 ∈ setdiff(M.trt.lost_slots, M.ctl.lost_slots)
    @info "G-2: 대조 잃음=$(M.ctl.lost)$(M.ctl.lost_slots) · 처리 잃음=$(M.trt.lost)$(M.trt.lost_slots) · " *
          "표적=$(M.ctl.target_v2) · 뗀슬롯=$(M.slots) · 목적값 $(M.ctl.obj) → $(M.trt.obj)"
end

finally
    _restore_globals!()
end

end # module
