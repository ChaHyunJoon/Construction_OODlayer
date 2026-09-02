# test/cargo_ban_fault_exception.jl
# ============================================================================
#  이 파일이 지키는 것: **고장 수습 중에는 화물 금지가 꺼지고, 끝나면 되살아난다**
#  (cargo-ban 계획 Task 5, 게이트 G-4).
#
#  왜 — 되돌릴 수 없는 실패에 대한 **보험**이다. `_enact_one!`(`replan.jl` 의 robot-fault
#  분기)은 `fault_robot_and_reassign!` 이 `:admitted` 가 아니면 `engage_fallback!` 을 부르고,
#  그 함수의 docstring 이 스스로 "first fallback = permanent end of the run, and that is the
#  design" 이라고 적는다(푸는 production 호출자 0개). 즉 화물 금지 때문에 고장 재배정이
#  실행 불가가 되면 **그 실행은 되살릴 수 없다.**
#  🔴 **관측된 결함에 대한 대응이 아니다** — 근거는 `fault_robot_and_reassign!` 본문 첫 주석.
#
# ----------------------------------------------------------------------------
#  🔴 이 시험이 반드시 피해야 하는 **공허한 초록** (Task 1 실측)
#
#  `release_pending_assignments!(env, inv; faulted = agent)` 는 고장 로봇의 id 를 지운다.
#  그래서 `released_faulted` 레짐(= `reassign.jl` 이 `ForbidAgent` 를 컴파일하는 유일한
#  production 경로)에서는 소유자 선택자가 후보 쌍을 **0개** 찾는다 — 네 판 전부 실측.
#  ⟹ **"재배정 중 금지행 = 0" 은 예외가 있든 없든 초록이다.** 그 단언만 두면 이 파일은 무가치다.
#
#  구별해야 하는 두 상태:
#      (i)  예외가 보관소를 **비웠다** → 컴파일할 것이 애초에 없었다
#      (ii) 보관소는 **가득 찬 채**였고 컴파일이 스스로 0 행을 냈다
#  🔴 **행 수로는 둘이 똑같이 0 이다.** 그래서 여기서는 행 수가 아니라
#  **그 formulate 시점의 보관소 내용물**을 잰다.
#
#  채널 = **솔버 팩토리 스파이**. `formulate_milp` 은 `Model(optimizer_with_attributes(
#  optimizer))` 로 모델을 만들면서 우리가 넘긴 팩토리를 **그 formulate 안에서** 부른다
#  (`essential_tg_coponents.jl`). 그래서 팩토리 자리에 "지금 보관소에 뭐가 들었는지 적고
#  진짜 HiGHS 를 돌려주는" 클로저를 넣으면, 재배정이 부르는 **모든** formulate 마다
#  보관소 스냅샷이 하나씩 쌓인다. 그 사이에 보관소를 바꾸는 코드는 없다
#  (`set_cargo_ban!`/`clear_cargo_ban!`/`empty!`/`Ref` 대입 — 넷 다 formulate 안에 없다).
#
#  🔴 **이 채널은 이 파일이 통째로 소유한다.** 남의 파일의 로그 문구·행 수·반환값에 기대지
#     않는다. (초판은 `_compile_standing_cargo_bans!` 의 `@warn` 을 셌는데, 같은 날 다른
#     세션이 그 경고를 `compiler.jl` 로 옮기면서 채널이 죽었다 — 양성 대조가 그것을 즉시
#     빨갛게 잡았다. 그래서 채널을 자기 소유로 옮겼다.)
#
#  🔴 그리고 채널이 (ii) 를 실제로 **잡는지**를 testset 1 이 직접 보인다: 배터리 계층이 없는
#     판에서 금지를 세우면 컴파일은 **정확히 0 행**(대조와 제약 수 동일)인데 스냅샷에는
#     그 로봇이 **들어 있다.** 그것이 상태 (ii) 의 정확한 모양이고, 채널이 그것을 (i) 과
#     가른다는 증거다.
#
#  🔴 runtests.jl 이 모든 시험 파일을 같은 `Main` 스코프에 include 하므로 자기 module 로 감싼다.
# ============================================================================
module CargoBanFaultExceptionTests

using Test
using ConstructionBots
using Graphs, Random, JuMP
const CB = ConstructionBots

# 🔴 런타임 include 는 **module 최상위**에 있어야 한다(world-age). 계획 README 의 공용
#    픽스처에는 이 줄이 빠져 있어 그대로 쓰면 죽는다(shared-rulings S-4.9).
const REPO = abspath(joinpath(@__DIR__, ".."))
isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))

# ============================================================================
#  관측 채널 — 솔버 팩토리 스파이 (이 파일이 소유한다)
# ============================================================================
"각 formulate 가 본 보관소 내용물(정렬된 키 문자열 목록)이 호출 순서대로 쌓인다."
const SNAPS = Vector{Vector{String}}()

"지금 보관소에 서 있는 금지의 키 목록 — 정렬해서(결정적) 돌려준다."
_store_keys() = sort(string.(collect(keys(CB.STANDING_CARGO_BANS[]))))

"""
`formulate_milp` 이 모델을 만들 때 부르는 팩토리. 부작용으로 그 순간의 보관소를 적는다.
🔴 이것이 "그 formulate 시점의 보관소 내용물" 의 정의다 — 행 수가 아니다.
"""
spy_optimizer() = (push!(SNAPS, _store_keys()); CB.HiGHS.Optimizer())

"같은 스파이인데 **던진다**. `finally` 계약을 예외 경로에서 재는 데 쓴다."
throwing_spy_optimizer() = (push!(SNAPS, _store_keys());
                            error("의도적으로 던지는 솔버 팩토리 (finally 계약 시험)"))

"`f()` 를 돌리며 그 동안 쌓인 스냅샷만 잘라 돌려준다."
function observe(f)
    empty!(SNAPS)
    val = f()
    return (value = val, n = length(SNAPS), snaps = copy(SNAPS))
end

_nconstr(m) = JuMP.num_constraints(m; count_variable_in_set_constraints = false)

# ============================================================================
#  픽스처
# ============================================================================
"""
`target_closed` 만큼 전진시킨 env. 고장 재배정을 **중반부**에서 건다(t=0 전면 재풀이는 후보
엣지 423 → 4187 로 늘어난 MIP 를 풀어 수렴이 안 붙는다 — `test/respec_grammar.jl` 의 실측).

🔴 배터리는 **켜지 않는다**. 이 계약은 배터리와 무관하고, 켜면 `cargo_burden_after` 가
패키지 스코프에서 `BATTERY_FLEET[]` 의 내용물을 deref 하는데 스위트 안에서는 그 자리가
`navigator.jl` 중복 include(= `const` 재정의) 때문에 실제로 **세그폴트**한 전례가 있다
(`test/cargo_ban_lifetime.jl` 머리말의 실측). 여기서는 그 자리에 갈 이유가 없다.
"""
function fixture(; board = "tractor.mpd", nr = 10, target_closed = 60, maxstep = 6000)
    env = CB.run_lego_demo(; ldraw_file = board, project_name = "cargobanfault", num_robots = nr,
                             assignment_mode = :greedy, n_spare_per_pool = 2,
                             open_animation_at_end = false, save_animation = false,
                             write_results = false, return_env_before_sim = true,
                             rng = Random.MersenneTwister(1))
    k = 0
    while length(env.cache.closed_set) < target_closed && k < maxstep
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0); k += 1; CB.set_sim_step!(k)
    end
    got = length(env.cache.closed_set)
    # 🔴 상한에 걸리면 씬은 요청한 시점이 **아니다**(삼상 규약: 못 만들었으면 만들었다고 안 한다).
    got < target_closed && error("fixture: 스텝 상한 $maxstep — closed = $got < $target_closed")
    return env
end

"스케줄 안의 모든 로봇 id — 정렬해서 돌려준다(순회 순서가 결과에 남지 않도록)."
function robot_ids(env)
    sched = env.sched
    return sort!([CB.entity(CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))).id
                  for v in Graphs.vertices(sched)
                  if CB.get_node_from_id(sched, CB.get_vtx_id(sched, v)) isa CB.RobotStart];
                 by = string)
end

"미래 운반 일감이 실제로 남은 로봇 하나 — 없으면 픽스처가 퇴화다(에러)."
function faultable_agent(env)
    for id in robot_ids(env)
        length(CB.transport_teams_with_agent(env, id; pending_only = true)) > 0 && return id
    end
    error("고장낼 로봇이 없다 — 미래 운반 일감이 0. 픽스처가 퇴화다")
end

# --- 판을 한 번만 짓는다 ------------------------------------------------------
CB.clear_all_cargo_bans!()                        # 🔴 앞 시험 파일의 잔재를 안 물려받는다
const ENV0    = fixture()
const FAULTED = faultable_agent(ENV0)
# 🔴 금지는 **고장 안 난 다른 로봇**에게 건다(계획서 Step 1 의 `some_other_robot`).
const BANNED  = first(filter(!=(FAULTED), robot_ids(ENV0)))

# 🔴 솔버 전역을 이 시험이 직접 소유한다(CLAUDE.md: 단독 실행은 초록, 스위트에서만 빨갛다 —
#    앞서 도는 `Demo` 가 default optimizer 를 Gurobi 로, attributes 에 Gurobi 전용 키를 남긴다).
#    재배정은 **최적해가 아니라 실행가능해만** 필요하므로 `mip_rel_gap` 을 크게 준다
#    (tools/tests.jl 의 `_setup_milp!` 와 같은 이유·같은 값).
#    🔴 그래서 이 파일은 **목적값을 하나도 인용하지 않는다**(S-4.5).
const _PREV_OPT   = CB.default_milp_optimizer()
const _PREV_ATTRS = copy(CB.default_milp_optimizer_attributes())
CB.set_default_milp_optimizer!(() -> CB.HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 120.0, "presolve" => "on",
                                          "mip_rel_gap" => 5.0, CB.MOI.Silent() => true)

# 🔴 부담 계층을 이 파일이 소유해서 **없는 상태**로 둔다(위 fixture docstring). 파일 끝에서 복원.
const _PREV_FLEET = CB.BATTERY_FLEET[]
CB.BATTERY_FLEET[] = nothing

"`rebalance_for_battery!` 의 호출 모양 — `extra_constraints` 를 아예 안 준다."
function plain_formulate(opt = spy_optimizer)
    inv = CB.build_invariant(ENV0)
    return CB.formulate_milp(CB.SparseAdjacencyMILP(), ENV0.sched, ENV0.scene_tree;
                             optimizer = opt, t0_ = inv.frozen_t0, tF_ = inv.frozen_tF)
end

try

# ============================================================================
#  1. 🔴 관측 채널이 살아 있고, **상태 (ii) 를 (i) 과 가른다**
#     (양성 대조 — 이게 없으면 아래의 "스냅샷이 전부 비었다" 는 공허하다)
# ============================================================================
@testset "🔴 관측 채널: formulate 시점의 보관소 내용물을 재고, (ii) 를 (i) 과 가른다" begin
    @test FAULTED != BANNED                          # 금지는 고장 로봇이 아닌 다른 로봇에게
    @test CB.BATTERY_FLEET[] === nothing             # 이 판은 부담 계층이 없다(의도)
    CB.clear_all_cargo_bans!()
    try
        # --- 대조: 빈 보관소 ------------------------------------------------
        c = observe(() -> plain_formulate())
        @test c.n == 1                               # 팩토리가 formulate 당 정확히 한 번 불린다
        @test c.snaps == [String[]]                  # 그 순간 보관소는 비어 있었다
        nrows_i = _nconstr(c.value.model)

        # --- 처치: 금지가 서 있다 = **상태 (ii)** 의 정확한 모양 --------------
        CB.set_cargo_ban!(BANNED, 2)
        t = observe(() -> plain_formulate())
        nrows_ii = _nconstr(t.value.model)
        @info "채널 대조: (i) 빈 보관소 행수 = $(nrows_i) · (ii) 가득 찬 보관소 행수 = $(nrows_ii) " *
              "· (ii) 스냅샷 = $(t.snaps)"
        # 🔴 행 수로는 (i) 과 (ii) 가 **구별되지 않는다** — 이 판이 계획서가 경고한 함정이다.
        @test nrows_ii == nrows_i
        # 🔴 그런데 채널은 구별한다. 이 두 줄이 이 파일 전체의 근거다.
        @test t.n == 1
        @test string(BANNED) in t.snaps[1]
    finally
        CB.clear_all_cargo_bans!()
    end
    # 지우면 다시 빈 스냅샷 — 채널이 항진(늘 non-empty)이 아니다.
    z = observe(() -> plain_formulate())
    @test z.snaps == [String[]]
end

# ============================================================================
#  2. 🔴 G-4 — 고장 수습 중에는 꺼지고(관측), 끝나면 되살아난다(복원)
# ============================================================================
@testset "🔴 G-4 고장 수습 중에는 금지가 꺼지고, 끝나면 되살아난다" begin
    CB.clear_all_cargo_bans!()
    try
        CB.set_cargo_ban!(BANNED, 2)
        # 🔴 양성 대조 — 재배정 **전에** 실제로 걸려 있다(지울 것이 없어서 초록이 아니다).
        @test CB.STANDING_CARGO_BANS[][BANNED] == 2
        @test length(CB.STANDING_CARGO_BANS[]) == 1

        o = observe(() -> CB.fault_robot_and_reassign!(ENV0, FAULTED; verbose = false,
                                                       resume = true, optimizer = spy_optimizer))
        res = o.value
        @info "G-4: status=$(res.status) removed=$(res.removed) formulate 횟수=$(o.n) " *
              "스냅샷=$(o.snaps)"

        # 🔴 비퇴화: 재배정이 실제로 끝까지 돌았다. `:admitted` 는 `verify` 의 trial solve 와
        #    커밋 재풀이가 **둘 다** 돌았다는 뜻이다 — 아래 "스냅샷이 전부 비었다" 가
        #    "formulate 가 아예 안 돌아서 비었다" 일 수가 없다.
        @test res.status === :admitted
        @test res.removed >= 1                       # 수술이 실제로 간선을 뗐다
        @test res.teams_after == 0                   # 고장 로봇이 미래 운반팀에서 빠졌다
        @test o.n >= 2                               # formulate 가 최소 두 번 돌았다(장부가 아니라 관측)

        # (b) 🔴 그 안의 **모든** formulate 가 빈 보관소를 봤다 = 상태 (i).
        #     상태 (ii) 였다면 testset 1 이 보인 대로 스냅샷에 그 로봇이 들어 있다.
        @test all(isempty, o.snaps)

        # (a) 🔴 끝나면 되살아난다.
        @test CB.STANDING_CARGO_BANS[][BANNED] == 2
        @test length(CB.STANDING_CARGO_BANS[]) == 1
        # 🔴 복원이 진짜인지 세계로 한 번 더 — 다음 formulate 는 다시 금지를 본다.
        a = observe(() -> plain_formulate())
        @test string(BANNED) in a.snaps[1]
    finally
        CB.clear_all_cargo_bans!()
    end
end

# ============================================================================
#  3. 🔴 이른 `return` 경로(`:rejected`)에서도 되살아난다
#
#  계획서가 `finally` 를 쓰라고 한 이유가 이것이다 — 본문에 이른 `return` 이 여럿 있고
#  (`:rejected` · `:fallback`), 하나라도 빠뜨리면 금지가 **영영** 사라진다.
#  솔버 시간제한을 없애다시피 해서 trial solve 가 실행가능해를 못 내게 한다
#  → `verify` 가 `Reject(:infeasible)` → 본문의 **첫 번째 이른 return**.
#  ⚠️ 이 testset 은 스케줄을 "풀어놓고 안 푼" 상태로 남긴다(설계상 — 그게 `:rejected` 다).
#     그래서 파일의 끝쪽에 둔다.
# ============================================================================
@testset "🔴 이른 return(:rejected) 경로에서도 금지가 되살아난다" begin
    CB.clear_all_cargo_bans!()
    saved = copy(CB.default_milp_optimizer_attributes())
    try
        CB.set_cargo_ban!(BANNED, 2)
        CB.clear_default_milp_optimizer_attributes!()
        CB.set_default_milp_optimizer_attributes!("time_limit" => 1.0e-4, "presolve" => "off",
                                                  CB.MOI.Silent() => true)
        o = observe(() -> CB.fault_robot_and_reassign!(ENV0, FAULTED; verbose = false,
                                                       resume = true, optimizer = spy_optimizer))
        res = o.value
        @info "이른 return: status=$(res.status) formulate 횟수=$(o.n) 스냅샷=$(o.snaps)"
        # 🔴 정말로 이른 return 을 탔는지 단언한다 — `:admitted` 로 새면 이 testset 은 공허하다.
        @test res.status === :rejected
        @test o.n >= 1                               # 그 경로도 formulate 를 한 번은 돌았다
        @test all(isempty, o.snaps)                  # 그때도 보관소는 비어 있었다
        @test CB.STANDING_CARGO_BANS[][BANNED] == 2  # 🔴 이른 return 뒤에도 살아 있다
    finally
        CB.clear_default_milp_optimizer_attributes!()
        CB.set_default_milp_optimizer_attributes!(saved)
        CB.clear_all_cargo_bans!()
    end
end

# ============================================================================
#  4. 🔴 예외가 던져도 되살아난다 (`finally` 계약)
#
#  계획서 Step 1 (c) 는 `RobotID(99999)`(없는 로봇)로 이것을 재라고 적는다. 실측하면 그 인자는
#  **던지지도 거절하지도 않는다** — `is_agent_frontier` 가 후보를 0개 찾아 `ForbidAgent` 가
#  0 행을 내고, 그 hollow 한 제안이 `:admitted` 로 통과하면서 재풀이를 더 돈다. 그래서 그
#  인자로는 예외 경로가 안 열린다(보고서 §편차).
#  ⟹ 던지는 것이 확실한 자리를 쓴다: 솔버 팩토리가 던지면 `verify` 안의 `formulate_milp` 이
#     터지고, 제안에 LLM 문법이 없으므로 `verifier.jl` 이 `rethrow()` 한다(그 자리의 주석이
#     그렇게 적는다) → 예외가 `fault_robot_and_reassign!` **밖으로** 나온다.
# ============================================================================
@testset "🔴 예외가 던져도 금지가 되살아난다 (finally 계약)" begin
    CB.clear_all_cargo_bans!()
    try
        CB.set_cargo_ban!(BANNED, 2)
        empty!(SNAPS)
        threw = false
        try
            CB.fault_robot_and_reassign!(ENV0, FAULTED; verbose = false, resume = true,
                                         optimizer = throwing_spy_optimizer)
        catch
            threw = true
        end
        # 🔴 예외가 **실제로** 났다는 것을 단언한다 — 안 던졌으면 다른 경로를 잰 것이다.
        @test threw
        @test length(SNAPS) >= 1                      # 던지기 직전에 보관소를 한 번 읽었다
        @test all(isempty, SNAPS)                     # 그때도 비어 있었다
        @test CB.STANDING_CARGO_BANS[][BANNED] == 2   # 🔴 예외 경로에서도 되살아났다
        @test length(CB.STANDING_CARGO_BANS[]) == 1
    finally
        CB.clear_all_cargo_bans!()
    end
end

finally
    # 🔴 빌린 전역을 전부 돌려준다. 안 돌려주면 뒤에 오는 시험 파일의 formulate 가 조용히 달라진다.
    CB.BATTERY_FLEET[] = _PREV_FLEET
    CB.set_default_milp_optimizer!(_PREV_OPT)
    CB.clear_default_milp_optimizer_attributes!()
    CB.set_default_milp_optimizer_attributes!(_PREV_ATTRS)
    CB.clear_all_cargo_bans!()
    CB.RESPEC_FROZEN[] = Set{CB.AbstractID}()
    CB.RESPEC_PINNED[] = Set{CB.AbstractID}()
    empty!(SNAPS)
end

end # module
