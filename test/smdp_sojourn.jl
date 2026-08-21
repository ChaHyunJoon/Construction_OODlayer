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
    @test e1 ≈ sum(per) * 1.0
    @test e1 > maximum(per) * 1.0 + 1e-9      # 한 대만 세는 구현은 여기서 죽는다
    @test length(S0.fleet) >= 2               # 위 단언이 항진명제가 아닌가
    @test_throws ErrorException CB.energy_between(S0, env, -1.0, BP)
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
