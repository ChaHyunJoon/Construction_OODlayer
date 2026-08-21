# =============================================================================
# test/smdp_sojourn.jl — Task T9, `src/smdp/sojourn.jl` (+ 이슈 C · D)
#
#   julia +lts --project=. test/smdp_sojourn.jl
#
# 이 시험이 지키는 것 하나: **경량 소저너가 엔진과 같은 세 위험을, 같은 λ 로, dt 루프 없이
# 표집한다.** 갈라져도 아무 에러가 안 난다 — τ 분포만 조용히 달라지고 트리가 다른 세계를 판다.
#
# 🔴 씬 생성은 `SCENE-INCANTATION.md` 의 정본을 따른다(`return_env_before_sim = true`).
# 🔴 SCENE-INCANTATION §2 의 규칙: **스텝 번호를 인용하지 않는다 — 발견한다.**
#    이 파일은 비퇴화 조건을 만족하는 첫 스텝을 훑어 찾고, 찾았다는 것 자체를 `@test` 로
#    못박고, 실제로 쓴 스텝을 `@info` 로 찍는다.
#
# 🔴 이 파일이 배제하는 구현들(음성 대조):
#      · 위험을 둘만 세는 구현        → 이슈 D testset 이 :cell · :zone 을 **둘 다** 요구
#      · cell 을 break 로 합친 구현   → cell_rate_from == _cell_rate 전수 대조
#      · robot_id_of 가 RobotID(k)    → 함대에 없는 키가 조용히 통과하는지 확인
#      · dt 루프 구현                 → 경계 횟수가 τ/dt 보다 **자릿수로** 작다
#      · rng 를 흘리는 구현           → 같은 시드 50개 전부 비트 동일
#      · rate boundary 를 넘는 전진   → advance_to 가 죽는다
# =============================================================================
using ConstructionBots, Test
import Random
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

# --- 씬 (SCENE-INCANTATION.md 정본) ------------------------------------------
env = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "t9sojourn",
                         num_robots = 6, assignment_mode = :greedy,
                         n_spare_per_pool = 2,
                         open_animation_at_end = false, save_animation = false,
                         write_results = false, return_env_before_sim = true,
                         rng = Random.MersenneTwister(1))
CB.enable_battery!(env)
CB.enable_hazard!(env; seed = 7)

const BP     = CB.BATTERY_FLEET[].params
const P      = CB.HazardParams()
const DT_SIM = env.dt * BP.seconds_per_step
const NV     = CB.Graphs.nv(env.sched)

# -----------------------------------------------------------------------------
# 🔴 프로브 스텝을 **발견**한다. 못 찾으면 초록이 아니라 빨강이다.
#   비퇴화 조건: 함대 ≥ 2 · 활성 ≠ ∅ · 모드가 둘 이상 · rate boundary 가 유한 양수.
#   (모드가 전부 :idle 이면 λ 가 로봇마다 같아져 "누가 먼저 터지나" 가 무의미해진다.)
# -----------------------------------------------------------------------------
function discover_probe(env, maxstep::Int)
    for k in 1:maxstep
        CB.step_environment!(env)
        CB.update_planning_cache!(env, 0.0)
        CB.set_sim_step!(k)
        s  = CB.simstate_of(env)
        ms = CB.modes_of(s, env)
        Δ  = CB.T_plan_next(s, env)
        if length(s.fleet) >= 2 && !isempty(CB.active_of(s)) &&
           length(unique(values(ms))) >= 2 && isfinite(Δ) && Δ > 0.0
            return (k, s)
        end
    end
    return (0, nothing)
end

const PROBE, S0 = discover_probe(env, 320)
@testset "🔴 비퇴화 프로브 스텝이 범위 안에 존재한다" begin
    @test PROBE > 0
end
PROBE > 0 || error("smdp_sojourn: 320 스텝 안에 비퇴화 스텝이 없다 — 픽스처가 죽었다")
@info "T9 발견한 프로브 스텝" step=PROBE n_fleet=length(S0.fleet) n_active=length(CB.active_of(S0)) modes=string(sort!(collect(pairs(CB.modes_of(S0, env))); by = first)) T_plan_next=CB.T_plan_next(S0, env) T_done=CB.T_done(S0, env) dt_sim=DT_SIM n_vertices=NV

# =============================================================================
@testset "τ > 0 이고 유한하다" begin
    kinds = Symbol[]
    for seed in 1:50
        τ, ev = CB.sample_sojourn(S0, env, P, BP, Random.MersenneTwister(seed))
        @test τ > 0.0
        @test isfinite(τ)
        @test ev[1] in (:failure, :terminal, :horizon)
        push!(kinds, CB.event_kind(ev))
    end
    @info "T9 기본 파라미터에서의 사건 분포" kinds=string(sort(unique(kinds); by = string)) n_failure=count(k -> k in (:break, :cell, :zone), kinds) n_terminal=count(==(:terminal), kinds)
end

@testset "같은 시드 = 같은 τ (재현성)" begin
    a = CB.sample_sojourn(S0, env, P, BP, Random.MersenneTwister(42))
    b = CB.sample_sojourn(S0, env, P, BP, Random.MersenneTwister(42))
    @test a[1] === b[1] && a[2] == b[2]
    # 🔴 한 시드로는 "rng 를 안 쓴다" 는 구현도 통과한다. 50 시드를 두 번 굴려 **벡터 전체**가
    #    비트 동일하면서 동시에 **상수가 아님**을 함께 단언한다.
    v1 = [CB.sample_sojourn(S0, env, P, BP, Random.MersenneTwister(k))[1] for k in 1:50]
    v2 = [CB.sample_sojourn(S0, env, P, BP, Random.MersenneTwister(k))[1] for k in 1:50]
    @test v1 == v2                       # === 비교(부동소수 비트 동일)
    @test length(unique(v1)) >= 2        # 음성 대조: 상수를 돌려주는 구현 배제
end

@testset "λ 를 키우면 τ 가 줄어든다 (단조성)" begin
    slow = CB.HazardParams(mode = 0.1)
    fast = CB.HazardParams(mode = 10.0)
    med(p) = (ts = [CB.sample_sojourn(S0, env, p, BP, Random.MersenneTwister(k))[1] for k in 1:200];
              sort!(ts)[100])
    ms, mf = med(slow), med(fast)
    @info "T9 단조성" median_slow=ms median_fast=mf
    @test mf < ms
end

@testset "delta_max 는 지평선이다" begin
    τ, ev = CB.sample_sojourn(S0, env, CB.HazardParams(mode = 1e-9), BP,
                              Random.MersenneTwister(1); delta_max = 5.0)
    @test τ ≈ 5.0
    @test ev[1] === :horizon
    @test CB.event_kind(ev) === :horizon
end

@testset "🔴 이슈 C — who 를 RobotID 로 되돌릴 수 있다" begin
    for k in sort!(collect(keys(S0.fleet)))
        rid = CB.robot_id_of(k)
        @test rid isa CB.RobotID
        @test CB._int_key(rid) == k
    end
    # 🔴 없는 키는 조용히 넘어가지 않는다 — `RobotID(k)` 를 그냥 만드는 구현을 배제한다.
    @test_throws ErrorException CB.robot_id_of(-999)
    @test_throws ErrorException CB.robot_id_of(10^7)
end

@testset "🔴 이슈 D — cell_rate_from 이 엔진의 _cell_rate 그 자체다" begin
    st = CB.HAZARD_STATE[]
    n = 0
    # `_cell_rate` 는 `st.params`·`st.usage_s` 만 읽는다 — 같은 인자를 손으로 넘겨 전수 대조한다.
    for id in sort!(collect(keys(st.usage_s)); by = string), m in (:idle, :transit, :carry, :manip)
        got  = CB.cell_rate_from(st.params, Float64(st.usage_s[id]), m)
        want = CB._cell_rate(st, id; mode = m)
        @test got == want          # ≈ 가 아니라 == (같은 식의 복사여야 한다)
        n += 1
    end
    @test n >= 8
    # 음성 대조: cell 은 break 와 **다른** 위험이다(mtbf 가 다르므로 값이 달라야 한다).
    @test CB.cell_rate_from(P, 0.0, :transit) != CB.hazard_rate_from(P, 0.0, 1.0, :transit)
    # 음성 대조: mode 배수를 무시하는 구현 배제
    @test CB.cell_rate_from(P, 0.0, :carry) > CB.cell_rate_from(P, 0.0, :idle)
    # 음성 대조: soc 를 쓰는 구현 배제 — cell 은 soc 인자가 아예 없다
    @test CB.cell_rate_from(P, 100.0, :transit) > CB.cell_rate_from(P, 0.0, :transit)
end

@testset "🔴 이슈 D — 경쟁위험이 셋이다 (break · cell · zone)" begin
    # 엔진(hazard_step!)이 셋을 **독립적으로** 검사하므로 경량 레인도 셋이다.
    kinds = Set{Symbol}()
    robots_seen = Set{Int}()
    for seed in 1:400
        _, ev = CB.sample_sojourn(S0, env, CB.HazardParams(mode = 50.0), BP,
                                  Random.MersenneTwister(seed))
        ev[1] === :failure || continue
        push!(kinds, CB.event_kind(ev))
        r = CB.event_robot_key(ev)
        r === nothing || push!(robots_seen, r)
    end
    @info "T9 이슈 D 사건 종류" kinds=string(sort!(collect(kinds); by = string)) n_robots_seen=length(robots_seen)
    @test :break in kinds
    @test :zone in kinds
    @test :cell in kinds        # 없으면 경량 레인이 2위험, 엔진이 3위험이다
    # 🔴 cell 사건도 **어느 로봇인지** 를 나른다 — 그게 없으면 T13 이 전이를 집행할 수 없다.
    @test length(robots_seen) >= 2
end

@testset "🔴 dt 루프가 없다 — 비용이 τ/dt 가 아니라 경계 횟수에 붙는다" begin
    CB.sample_sojourn(S0, env, P, BP, Random.MersenneTwister(0))     # 컴파일 소진
    nb, steps_if_dt_loop = 0, 0.0
    for k in 1:200
        τ, _, b = CB.sample_sojourn_traced(S0, env, P, BP, Random.MersenneTwister(k))
        nb += b
        steps_if_dt_loop += τ / DT_SIM
    end
    t = @elapsed for k in 1:200
        CB.sample_sojourn(S0, env, P, BP, Random.MersenneTwister(k))
    end
    @info "T9 dt 루프 부재" n_boundaries_total=nb dt_loop_steps_total=steps_if_dt_loop ratio=(steps_if_dt_loop / max(nb, 1)) elapsed_s=t n_samples=200
    # 🔴 **구조 단언**(벽시계가 아니다): dt 루프였다면 τ/dt 번 돌았을 것이다. 경계 횟수가
    #    그보다 자릿수로 작아야 "닫힌 형태로 건너뛰었다" 가 참이다. 10배는 유도된 값이 아니라
    #    "자릿수" 의 정의다 — 이 픽스처의 실측비는 위 @info 가 매 실행 찍는다.
    @test nb > 0
    @test steps_if_dt_loop > 10.0 * nb
end

@testset "advance_to 는 rate boundary 를 넘으면 죽는다" begin
    Δ = CB.T_plan_next(S0, env)
    @test isfinite(Δ) && Δ > 0.0                       # 프로브가 보장한다
    @test_throws ErrorException CB.advance_to(S0, env, Δ * 2.0, BP)
    @test_throws ErrorException CB.advance_to(S0, env, -1.0, BP)
    s2 = CB.advance_to(S0, env, Δ, BP)                 # 경계까지는 간다
    @test s2.prog.closed == S0.prog.closed             # 노드를 닫지 않는다
    @test keys(s2.fleet) == keys(S0.fleet)
    @test all(k -> s2.fleet[k].usage_s >= S0.fleet[k].usage_s, keys(S0.fleet))
    @test all(k -> s2.fleet[k].soc <= S0.fleet[k].soc, keys(S0.fleet))
    @test any(k -> s2.fleet[k].usage_s > S0.fleet[k].usage_s, keys(S0.fleet))  # 비퇴화
end

@testset "advance_to_rate_boundary 는 노드를 닫는다" begin
    Δ = CB.T_plan_next(S0, env)
    act  = sort!(collect(CB.active_of(S0)))
    durs = [CB.node_duration(env, v) for v in act]
    # 🔴 트립와이어의 전제: 프론티어에 dur>0 이 있으면 T_plan_next 는 **주 경로**다.
    @test any(>(0.0), durs)
    @test Δ ≈ CB.RHO[] * minimum(d for d in durs if d > 0.0)
    n_zero = count(==(0.0), durs)
    @info "T9 프로브의 프론티어 소요시간 분포" n_active=length(act) n_zero=n_zero n_pos=(length(act) - n_zero) dur_min_pos=minimum(d for d in durs if d > 0.0) T_plan_next=Δ

    s2 = CB.advance_to_rate_boundary(S0, env, Δ, BP)
    @test length(s2.prog.closed) > length(S0.prog.closed)
    @test issubset(S0.prog.closed, s2.prog.closed)      # 닫힌 노드를 되열지 않는다
    @test CB.active_of(s2) != CB.active_of(S0)          # 프론티어가 실제로 움직였다
    # 🔴 계획서의 `d > 0.0 &&` 가드가 만드는 사고: dur==0 정점이 안 닫히면 후행이 영원히 막힌다.
    #    경계를 넘으면 **그 정점들도** 닫혀 있어야 한다.
    for (i, v) in enumerate(act)
        durs[i] == 0.0 && @test v in s2.prog.closed
    end
    # 🔴 전진하지 못하는 Δ 는 조용히 통과하지 않는다 (dur==0 만 닫히는 것은 전진이 아니다)
    @test_throws ErrorException CB.advance_to_rate_boundary(S0, env, Δ / 1000, BP)
    @test_throws ErrorException CB.advance_to_rate_boundary(S0, env, Inf, BP)
    @test_throws ErrorException CB.advance_to_rate_boundary(S0, env, 0.0, BP)
end

@testset "energy_between 이 양수이고 Δ 에 선형이다" begin
    e1 = CB.energy_between(S0, env, 1.0, BP)
    e2 = CB.energy_between(S0, env, 2.0, BP)
    @test e1 > 0.0
    @test e2 ≈ 2.0 * e1 rtol = 1e-9
    @test CB.energy_between(S0, env, 0.0, BP) == 0.0
    # 🔴 음성 대조: **로봇 하나만 세는 구현 배제.**
    #    앞 판은 `e1 >= n_fleet · idle_W` 였는데 그건 통과했다 — 실측(변이 M10): 이 프로브에서
    #    로봇 1이 `:manip`(1000 W)이라 한 대만 세도 `6 · idle_W = 600 W` 를 넘는다. 초록불이
    #    증거가 아니었던 자리다. 이제 **가장 센 로봇 하나보다도 커야 한다**로 좁힌다.
    ms = CB.modes_of(S0, env)
    per = [CB.mode_power_W(BP, ms[k]) for k in sort!(collect(keys(S0.fleet)))]
    @info "T9 energy_between 집계" n_fleet=length(per) per_robot_W=string(per) max_single_W=maximum(per) sum_W=sum(per) e1=e1
    # 🔴 이 픽스처에는 고장 로봇이 없으므로 population 항이 0 이다 — **그 사실을 단언한다**,
    #    안 그러면 아래 등식이 population 항을 우연히 안 태우고 통과한다.
    @test CB._n_charged_outside_fleet(S0) == 0
    @test e1 ≈ sum(per) * 1.0
    @test e1 > maximum(per) * 1.0 + 1e-9      # 한 대만 세는 구현은 여기서 죽는다
    @test length(S0.fleet) >= 2               # 위 단언이 항진명제가 아닌가
    @test_throws ErrorException CB.energy_between(S0, env, -1.0, BP)
end

# =============================================================================
# 🔴 T14/N-G5 Step 0 — population 불일치 (T12 리뷰 Important 1)
#
# `energy_between` 은 `s.fleet` 만 합산했는데, 엔진은 `keys(fleet.soc) \ parked` 전원에게
# 대기전력을 부과한다(`battery.jl:242-246`). `s.fleet` 는 거기서 **고장 로봇까지** 더 빼므로
# (`_hz_excluded() = parked ∪ faulted`), 고장 발생 ~ Replace 사이의 모든 전이가
# `idle_W × |고장| × Δ` 만큼 **과소계상**한다.
#
# 여기서는 진짜 고장을 주입하지 않고 **기전을 직접 겨냥한다**: `s.fleet` 에서 로봇을 하나 빼면
# (= 엔진은 과금하는데 s 는 모르는 상태) 에너지가 정확히 `idle_W` 만큼 **늘어야** 한다.
# =============================================================================
@testset "🔴 N-G5 Step 0 — 엔진이 과금하는데 s.fleet 에 없는 로봇이 계상된다" begin
    ks = sort!(collect(keys(S0.fleet)))
    @test length(ks) >= 2                       # 하나 빼도 남는 게 있어야 한다(항진 방지)

    dropped = first(ks)
    fleet2  = Dict(k => S0.fleet[k] for k in ks if k != dropped)
    S_drop  = CB.SimState(g = S0.g, geo = S0.geo, fleet = fleet2, prog = S0.prog)

    # s 가 로봇 하나를 잃으면 "엔진이 과금하는데 s 밖" 인구가 정확히 1 늘어야 한다
    @test CB._n_charged_outside_fleet(S_drop) == CB._n_charged_outside_fleet(S0) + 1

    e_full = CB.energy_between(S0,     env, 1.0, BP)
    e_drop = CB.energy_between(S_drop, env, 1.0, BP)

    # 빠진 로봇의 원래 모드 전력은 빠지고, 대신 idle_W 가 들어온다
    ms   = CB.modes_of(S0, env)
    lost = CB.mode_power_W(BP, ms[dropped])
    @info "N-G5 Step 0 population 항" dropped_mode=ms[dropped] lost_W=lost idle_W=BP.idle_W e_full=e_full e_drop=e_drop
    @test e_drop ≈ (e_full - lost + BP.idle_W) rtol = 1e-12

    # 🔴 음성 대조: 수정 전 구현(= population 항 없음)이면 e_drop == e_full - lost 다.
    #    그 값과 **다른가**. 다르지 않으면 이 시험은 아무것도 안 지킨다.
    @test !isapprox(e_drop, e_full - lost; rtol = 1e-12)
    @test BP.idle_W > 0.0                       # 위 비교가 공허하지 않은가

    # 🔴 음수 방향(= 두 정의가 예상 밖으로 어긋남)은 조용히 0 으로 접지 않는다.
    #    s.fleet 에 유령 로봇을 넣어 엔진 과금 집합보다 크게 만들면 죽어야 한다.
    ghost = Dict(S0.fleet)
    ghost[maximum(ks) + 12345] = first(values(S0.fleet))
    S_ghost = CB.SimState(g = S0.g, geo = S0.geo, fleet = ghost, prog = S0.prog)
    @test_throws ErrorException CB._n_charged_outside_fleet(S_ghost)
end

@testset "🔴 조용한 폴백 금지" begin
    # 함대에 없는 로봇 키를 든 상태 — 모드 분류가 조용히 :idle 로 떨어지지 않는다
    bad = CB.SimState(g = CB.GraphBlock(edges = Set([(-1, NV + 10^6)]), binding = Dict{Int,Int}()),
                      geo = S0.geo, fleet = S0.fleet,
                      prog = CB.ProgBlock(closed = Set{Int}([-1])))
    @test_throws ErrorException CB.sample_sojourn(bad, env, P, BP, Random.MersenneTwister(1))
    # 비유한 rate 파라미터는 죽는다
    @test_throws ErrorException CB.sample_sojourn(S0, env, CB.HazardParams(mode = NaN), BP,
                                                  Random.MersenneTwister(1))
    @test_throws ErrorException CB.sample_sojourn(S0, env, P, BP, Random.MersenneTwister(1);
                                                  delta_max = -1.0)
end

@testset "🔴 T_plan_next 가 Inf 인 상태 — 적분 상한으로 Inf 를 쓰지 않는다" begin
    # T8 이 복원한 계약: `Inf` ⟺ 남은 계획 작업의 소요시간이 전부 0 ⟺ `T_done == 0`.
    # 그 상태에서 소저너는 **유한**하게 끝나야 한다(τ = 0 의 흡수 종료).
    s_abs = CB.SimState(g = S0.g, geo = S0.geo, fleet = S0.fleet,
                        prog = CB.ProgBlock(closed = Set{Int}(1:NV)))
    @test CB.T_plan_next(s_abs, env) == Inf
    @test CB.T_done(s_abs, env) == 0.0
    τ, ev = CB.sample_sojourn(s_abs, env, P, BP, Random.MersenneTwister(1))
    @test isfinite(τ)
    @test ev[1] === :terminal
    # 지평선을 주면 그 지평선까지는 위험이 살아 있다(흡수여도 λ 는 0 이 아니다).
    τ2, ev2 = CB.sample_sojourn(s_abs, env, CB.HazardParams(mode = 500.0), BP,
                                Random.MersenneTwister(3); delta_max = 10.0)
    @test isfinite(τ2)
    @info "T9 흡수상태" tau_no_horizon=τ ev=string(ev) tau_with_horizon=τ2 ev2=string(ev2)

    # 🔴 프론티어가 **전부 dur == 0** 인 상태(T8 의 폴백 픽스처와 같은 자리)에서도 유한하다.
    zero_v = [v for v in 1:NV if CB.node_duration(env, v) == 0.0]
    @test !isempty(zero_v)
    s_z = CB.SimState(g = S0.g, geo = S0.geo, fleet = S0.fleet,
                      prog = CB.ProgBlock(closed = setdiff(Set{Int}(1:NV), Set([first(zero_v)]))))
    @test CB.T_plan_next(s_z, env) == Inf
    τ3, ev3 = CB.sample_sojourn(s_z, env, P, BP, Random.MersenneTwister(1))
    @test isfinite(τ3)
    @test ev3[1] === :terminal
end

# =============================================================================
# 🔴🔴 Task T10 — `DRAIN_DT` 프로브. **ρ 와 독립인 두 번째 손잡이가 실제로 두 번째인가.**
#
# 왜 이 testset 이 존재하는가: T9 은 N-G1 의 격차를 만드는 기전이 최소 둘("ρ 가 흡수하는
# rate boundary 편향" · "`dur == 0` 프론티어를 시간 0 으로 닫는 드레인")인데 **부호가 같아서
# ρ 스윕으로는 안 갈린다**고 실측으로 남겼다. 그 교착을 깨는 유일한 방법이 드레인의 시간
# 비용을 ρ 와 **따로** 흔드는 것이고, 이 testset 이 그 손잡이가 (a) 기본값에서 무해하고
# (b) 켜면 실제로 무언가를 움직이며 (c) ρ 와 **분리 가능**하다는 것을 못박는다.
#
# 🔴 여기서 가장 중요한 단언은 **`n_drain >= 1`** 이다. 드레인이 한 번도 안 일어나면 이
#    프로브는 아무것도 재지 않고, 그러면 아래의 모든 초록불이 항진명제다.
# =============================================================================
@testset "🔴 T10 — DRAIN_DT 기본값은 무해하다(T9 동작 보존)" begin
    @test CB.DRAIN_DT isa Ref{Float64}
    @test CB.DRAIN_DT[] == 0.0                       # 커밋된 기본값 = T9 의 동작
    for seed in 1:12
        τ1, ev1, nb1 = CB.sample_sojourn_traced(S0, env, P, BP, Random.MersenneTwister(seed))
        τ2, ev2, nb2, nd2, td2 =
            CB.sample_sojourn_probe(S0, env, P, BP, Random.MersenneTwister(seed))
        @test τ1 === τ2 && ev1 == ev2 && nb1 == nb2   # 비트 동일
        @test td2 == 0.0                              # 기본값에서 드레인은 시간을 안 쓴다
        @test nd2 >= 0
    end
end

const _T10_SEEDS = 1:60
"주어진 (ρ, drain) 에서 (중앙값 τ, 드레인 총횟수, 드레인 총시간, τ 벡터)."
function t10_cell(rho::Float64, drain::Float64)
    old_r, old_d = CB.RHO[], CB.DRAIN_DT[]
    try
        CB.RHO[] = rho
        CB.DRAIN_DT[] = drain
        τs, nd, td = Float64[], 0, 0.0
        for seed in _T10_SEEDS
            τ, _, _, d, t = CB.sample_sojourn_probe(S0, env, P, BP,
                                                    Random.MersenneTwister(seed))
            push!(τs, τ); nd += d; td += t
        end
        return (median = sort(τs)[div(length(τs), 2)], n_drain = nd, t_drain = td, tau = τs)
    finally
        CB.RHO[] = old_r
        CB.DRAIN_DT[] = old_d
    end
end

const _T10_C00 = t10_cell(1.0, 0.0)                 # (ρ=1, drain=0)  = 커밋된 기본값
const _T10_C01 = t10_cell(1.0, DT_SIM)              # (ρ=1, drain=dt)
const _T10_C10 = t10_cell(2.0, 0.0)                 # (ρ=2, drain=0)
const _T10_C11 = t10_cell(2.0, DT_SIM)              # (ρ=2, drain=dt)
@info "🔴 T10 2×2 격자(시험 픽스처, n=$(length(_T10_SEEDS)))" med_r1d0=_T10_C00.median med_r1dt=_T10_C01.median med_r2d0=_T10_C10.median med_r2dt=_T10_C11.median n_drain_r1d0=_T10_C00.n_drain n_drain_r1dt=_T10_C01.n_drain n_drain_r2d0=_T10_C10.n_drain n_drain_r2dt=_T10_C11.n_drain t_drain_r1dt=_T10_C01.t_drain t_drain_r2dt=_T10_C11.t_drain drain_per_sample_r1=(_T10_C01.n_drain / length(_T10_SEEDS)) t_drain_per_sample_r1=(_T10_C01.t_drain / length(_T10_SEEDS)) dt_sim=DT_SIM

@testset "🔴 T10 — 프로브가 항진명제가 아니다 (드레인이 실제로 일어난다)" begin
    # 🔴 이 단언이 이 파일에서 가장 중요하다. 드레인이 0 번이면 아래 전부가 무의미하다.
    @test _T10_C00.n_drain >= 1
    @test _T10_C01.n_drain >= 1
    # 시간 비용은 켠 쪽에서만 든다
    @test _T10_C00.t_drain == 0.0
    @test _T10_C01.t_drain > 0.0
    @test _T10_C01.t_drain ≈ _T10_C01.n_drain * DT_SIM rtol = 1e-12
end

@testset "🔴 T10 — 드레인 비용은 ρ 와 분리된다 (두 손잡이가 서로 다른 것을 움직인다)" begin
    # (a) ρ 를 고정하고 드레인만 흔들면 분포가 움직인다 → 드레인은 **ρ 가 아닌** 자유도다
    @test _T10_C01.tau != _T10_C00.tau
    # (b) 드레인을 고정하고 ρ 만 흔들어도 분포가 움직인다 → ρ 도 여전히 살아 있는 자유도다
    @test _T10_C10.tau != _T10_C00.tau
    # (c) 🔴 상호작용이 0 이 아니다 = 두 손잡이가 같은 것을 두 번 만지는 것이 아니다.
    #     드레인의 효과가 ρ 에 따라 달라지면 "ρ 하나로 흡수된다"는 서술이 거짓이다.
    d_at_rho1 = _T10_C01.median - _T10_C00.median
    d_at_rho2 = _T10_C11.median - _T10_C10.median
    @info "T10 상호작용" drain_effect_at_rho1=d_at_rho1 drain_effect_at_rho2=d_at_rho2 t_drain_per_sample=(_T10_C01.t_drain / length(_T10_SEEDS))
    @test isfinite(d_at_rho1) && isfinite(d_at_rho2)
    # 🔴 **방향을 단언하지 않는다 — 잰다.** 초판은 "드레인에 시간을 물리면 경량이 더 느리게
    #    전진하므로 τ 가 줄어든다" 를 단언했고 **실측이 그것을 반박했다**(중앙값이 +0.023 s
    #    로 늘었다). 이유는 두 항이 반대로 걸리기 때문이다:
    #      · (+) 드레인이 쓴 시간이 τ 에 **그대로 더해진다**(τ 는 경과시간이다)
    #      · (−) 스케줄이 늦게 전진해 로봇이 더 오래 non-idle → 위험 노출 증가 → 사건이 빨라짐
    #    이 픽스처에서는 (+) 가 이긴다. 그러므로 부호는 **실측 대상**이지 단언 대상이 아니다.
    #    (T9 보고서 §5-1 3번이 "드레인은 ρ 와 같은 방향" 이라고 추측한 대목이 여기서 정정된다.)
    @test abs(d_at_rho1) > 0.0
end

@testset "🔴 T10 — 드레인 비용이 커지면 드레인 시간이 단조로 는다" begin
    lo = t10_cell(1.0, 0.5 * DT_SIM)
    hi = t10_cell(1.0, 2.0 * DT_SIM)
    @info "T10 드레인 사다리" t_drain_half=lo.t_drain t_drain_1x=_T10_C01.t_drain t_drain_2x=hi.t_drain med_half=lo.median med_1x=_T10_C01.median med_2x=hi.median
    @test lo.t_drain < _T10_C01.t_drain < hi.t_drain
    # 🔴 중앙값의 **부호**를 단언하지 않는다(위 testset 의 정정 참조). 대신 손잡이가 실제로
    #    분포를 움직인다는 것 — 즉 아무것도 안 하는 구현이 배제된다는 것 — 을 단언한다.
    @test lo.tau != _T10_C00.tau
    @test hi.tau != lo.tau
end

@testset "🔴 T10 — 조용한 폴백 금지 + 전역 복원" begin
    old = CB.DRAIN_DT[]
    try
        CB.DRAIN_DT[] = -1.0
        @test_throws ErrorException CB.sample_sojourn(S0, env, P, BP,
                                                      Random.MersenneTwister(1))
        CB.DRAIN_DT[] = NaN
        @test_throws ErrorException CB.sample_sojourn(S0, env, P, BP,
                                                      Random.MersenneTwister(1))
    finally
        CB.DRAIN_DT[] = old
    end
    @test CB.DRAIN_DT[] == 0.0                 # 위의 모든 픽스처가 전역을 복원했다
    @test CB.RHO[] == 1.0
end

# =============================================================================
# 🔴 T10 변이 스윕 2라운드에서 **살아남은 변이 두 개**를 잡으려고 추가한 testset 둘.
#
#   1라운드 실측: `T10MD2`(드레인이 문턱을 안 소진한다)와 `T10MD4`(드레인 구간 안에서 온
#   실패를 삼킨다)가 **초록으로 통과했다.** 이유는 분포 단언만으로는 두 변이가 만드는 차이가
#   표본 잡음 아래이기 때문이다(드레인 시간이 τ 의 ~0.1%). 그래서 분포가 아니라 **해석적
#   항등식**과 **결정적 픽스처**로 잡는다. T9 이 M10 에서 한 것과 같은 수리다.
# =============================================================================
@testset "🔴 T10 — 드레인 구간에서도 위험이 누적된다 (zone-only 해석적 항등식)" begin
    # 위험을 zone 하나로 줄이면 τ 가 닫힌 형태다: τ = Ez / λz (zone 은 상수율).
    # 드레인이 시간을 쓰든 안 쓰든 이 값은 **정확히 같아야** 한다 — 드레인 구간에서도
    # 문턱이 λz·Δ 만큼 소진되기 때문이다. 소진을 빠뜨리면 τ 가 드레인 시간만큼 길어진다.
    Pz = CB.HazardParams(mtbf_break_s = Inf, mtbf_cell_s = Inf, mode = 50.0)
    λz = CB._rate(Pz.mtbf_zone_s) * Pz.mode
    @test λz > 0.0
    old = CB.DRAIN_DT[]
    try
        CB.DRAIN_DT[] = DT_SIM
        # ⚠️ zone 만 남기면 Ez 가 큰 뽑기에서는 **스케줄이 먼저 소진**돼 `:terminal` 로 끝난다
        #    (실측: 12 시드 중 1개). 그건 항등식이 성립하는 자리가 아니므로 세고 건너뛴다 —
        #    대신 항등식을 검사한 표본 수와 그중 드레인이 일어난 수를 **둘 다 단언**해서
        #    "검사할 게 없어서 초록" 을 막는다.
        n_zone, nd_zone, ks = 0, 0, sort!(collect(keys(S0.fleet)))
        for seed in 1:16
            rng = Random.MersenneTwister(seed)          # 소저너와 **같은 뽑기 순서**를 재현
            for _ in ks; CB._exp1(rng); end             # Eb (로봇별 break)
            for _ in ks; CB._exp1(rng); end             # Ec (로봇별 cell)
            Ez = CB._exp1(rng)                          # zone
            τ, ev, _, nd, _ = CB.sample_sojourn_probe(S0, env, Pz, BP,
                                                      Random.MersenneTwister(seed))
            CB.event_kind(ev) === :zone || continue     # 스케줄 소진(:terminal) 은 건너뛴다
            n_zone += 1; nd_zone += nd
            @test τ ≈ Ez / λz rtol = 1e-9               # 🔴 드레인이 있어도 **정확히** 같다
        end
        @test n_zone >= 8        # 🔴 항진명제 방지 1: 항등식을 검사한 표본이 실제로 있다
        @test nd_zone >= 1       # 🔴 항진명제 방지 2: 그중 드레인이 일어난 표본이 있다
        @info "T10 zone-only 항등식" n_zone_checked=n_zone n_drain_in_checked=nd_zone lambda_z=λz drain_dt=CB.DRAIN_DT[]
    finally
        CB.DRAIN_DT[] = old
    end
    @test CB.DRAIN_DT[] == 0.0
end

@testset "🔴 T10 — 드레인이 그 구간 안에서 온 실패를 삼키지 않는다" begin
    # 프론티어가 **전부 dur == 0** 인 상태를 만든다 → 루프의 첫 반복이 드레인 분기다.
    zero_v = [v for v in 1:NV if CB.node_duration(env, v) == 0.0]
    @test !isempty(zero_v)
    s_z = CB.SimState(g = S0.g, geo = S0.geo, fleet = S0.fleet,
                      prog = CB.ProgBlock(closed = setdiff(Set{Int}(1:NV), Set([first(zero_v)]))))
    @test CB.T_plan_next(s_z, env) == Inf          # 드레인 분기의 전제
    Pbig = CB.HazardParams(mode = 1.0e6)           # 0.025 s 안에서 반드시 터진다
    old = CB.DRAIN_DT[]
    try
        CB.DRAIN_DT[] = DT_SIM
        for seed in 1:8
            τ, ev, _, nd, td = CB.sample_sojourn_probe(s_z, env, Pbig, BP,
                                                       Random.MersenneTwister(seed))
            @test ev[1] === :failure               # 삼키면 :terminal 이 된다
            @test 0.0 < τ <= DT_SIM + 1e-12        # 첫 드레인 구간 안에서 끝났다
            @test nd == 1                          # 드레인은 한 번 셌고
            @test td == 0.0                        # 그 시간을 쓰기 **전에** 나왔다
        end
    finally
        CB.DRAIN_DT[] = old
    end
    @test CB.DRAIN_DT[] == 0.0
end
