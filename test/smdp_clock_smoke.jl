# test/smdp_clock_smoke.jl
# spec §3.3 Clock · §11-8 — 시계가 셋이었다(SIM_STEP · HazardState.t/.step ·
# run_demo._SIM_STEP). `battery_courier.jl` 의 `BatteryDelivery.step_out`/`step_swap` 이
# **절대 스텝 인덱스**라 시계를 복원 안 하면 배송이 과거나 미래에 도착한다.
# (2026-08-20 후속: `src/smdp/simstate.jl` 의 `CB.SimState` 쪽 `CourierRec` 는 이제
# `ProgBlock.t` 가 절대 sim 초 시계를 직접 실어 날라 `t_out`/`t_swap`(Float64)으로 개명됐다 —
# 이 파일이 재는 SIM_STEP 시계 자체는 그와 별개로 여전히 필요하다.)
#
#   julia +lts --project=. test/smdp_clock_smoke.jl
using ConstructionBots
using Test
import JSON3
const CB = ConstructionBots

CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

@testset "sim_time 은 SIM_STEP 에서 유도된다" begin
    CB.set_sim_step!(0)
    @test CB.sim_time(0.025) == 0.0
    CB.set_sim_step!(120)
    @test CB.sim_time(0.025) ≈ 3.0
    @test CB._current_sim_step() == 120
end

@testset "hazard 시계가 SIM_STEP 과 어긋나지 않는다" begin
    CB.set_sim_step!(0)
    st = CB._new_hazard_state(CB.HazardParams(), 0)
    @test st.step == 0
    CB.set_sim_step!(7)
    CB._hz_sync_clock!(st, 0.025)
    @test st.step == 7
end

# 리뷰 라운드 1(중요 3) — 1차 구현은 `.step` 만 전역 시계에 동기화하고 `.t` 는 그대로
# 자기 누적이었다. 그러면 `hazard_step!` 호출이 스킵될 때마다(비활성화 구간, max_events
# 상한 등) `.t` 와 `.step` 이 영구히 어긋난다 — 수정 전에는 둘이 항상 같이 전진해서 이
# 갈림이 구조적으로 불가능했으므로, 절반짜리 수정이 오히려 새 퇴행이었다. 아래는 `.t` 를
# `.step` 에서 유도하는 최종 수정이 스킵 뒤에도 드리프트 없이 정확한 절대시각으로
# 복귀함을 보인다 — 자기 누적이었다면(옛 절반짜리 수정) 마지막 @test 가 실패했을 것이다
# (스킵된 3스텝의 dt 를 영영 잃어 dt*11 에 갇힘, dt*13 이 아니라).
@testset "hazard 의 .t 는 .step 에서 유도되어 스킵돼도 드리프트가 없다 (리뷰 R1 중요3)" begin
    dt = 0.025
    CB.set_sim_step!(0)
    st = CB._new_hazard_state(CB.HazardParams(), 0)

    # 셋업 전(SIM_STEP[]==0): 자기 카운터 경로 — 단위검사가 기대하는 옛 동작 그대로.
    CB._hz_sync_clock!(st, dt)
    @test st.step == 1
    @test st.t ≈ dt

    # 전역 시계가 붙은 뒤: step 은 SIM_STEP[] 에서, t 는 dt*step 에서 유도된다.
    CB.set_sim_step!(10)
    CB._hz_sync_clock!(st, dt)
    @test st.step == 10
    @test st.t ≈ dt * 10

    # 스킵 재현: hazard_step! 이 SIM_STEP 10 -> 13 사이 세 번 안 불렸다고 하자. 다음 호출에서
    # st.t 는 즉시 정확한 절대시각(dt*13)으로 복귀해야 한다 — 자기 누적이었다면 누락된 3*dt 를
    # 영영 되찾지 못하고 dt*11 에 머물렀을 것이다.
    CB.set_sim_step!(13)
    CB._hz_sync_clock!(st, dt)
    @test st.step == 13
    @test st.t ≈ dt * 13
end

# 리뷰 라운드 1(중요 4) — 위 두 testset 은 CB.sim_time/_hz_sync_clock! 자체는 검증하지만,
# 실제 버그가 살던 자리(run_demo.jl 의 handle_ood! 안, "sim_t_at" 을 찍는 그 줄)는 여전히
# 아무 것도 안 덮는다. 수정 전 코드는 그 자리에서 **사설** `_SIM_STEP[]`(그 반복에서 아직
# `CB.set_sim_step!(k)` 로 안 갱신된, 이전 반복의 값)를 읽었는데, 같은 반복 맨 위에서
# `CB.ood_inject_step!(env,k)` 가 이미 **전역** `CB.SIM_STEP[]`(courier 가 읽는 값)를 k 로
# 올려놓은 뒤였다 — 그래서 sim_t_at 이 courier 의 절대 스텝 인덱스보다 정확히 dt 만큼(한
# 스텝) 뒤진 값을 찍었다(실측: 1.075s vs 올바른 1.1s. 리뷰가 588판 4655/4731행에서 확인,
# 매번 정확히 -0.025s).
#
# 이 회귀를 실제 하니스로 잡기 위해 run_demo.jl 에 진단 필드 "sim_step_at" 을 "sim_t_at" 과
# **같은 줄에서** CB._current_sim_step() 을 읽도록 추가했다(:294 부근). 아래는 배터리
# 케이스를 고정 시드로 한 판 실제로 돌려, 산출물의 두 필드가 항상 같은 순간을 가리키는지
# (= dt * sim_step_at) 를 검사한다. `_SIM_STEP` 류의 사설 카운터가 되살아나거나 두 필드가
# 서로 다른 시점에 읽히도록 순서가 바뀌면 이 등식이 깨진다.
#
# ⚠️ 느리다(run_demo.jl 전체 한 판, 약 1분) — 그래서 이 파일은 Pkg.test() 의 runtests.jl 에
# 안 실려 있다(다른 test/smdp_*.jl 과 같은 관례, README 참조).
@testset "run_demo 의 sim_t_at 스탬핑이 SIM_STEP 과 같은 순간을 읽는다 (회귀, 리뷰 R1 중요4)" begin
    repo_root = normpath(joinpath(@__DIR__, ".."))
    tmp = tempname() * ".jsonl"
    env = copy(ENV)
    env["DEMO_HAZARD"]    = "0"
    env["DEMO_SUMMARY"]   = tmp
    env["DEMO_OOD"]       = "battery"
    env["DEMO_OOD_SEED"]  = "1"
    env["DEMO_SEED"]      = "1"
    cmd = setenv(`julia +lts --project=$repo_root $(joinpath(repo_root, "tools", "monitor", "run_demo.jl"))`, env)
    cmd = Cmd(cmd; dir = repo_root)
    run(pipeline(cmd; stdout = devnull, stderr = devnull))

    @test isfile(tmp)
    rec = JSON3.read(readline(tmp))
    dt = Float64(rec.dt)
    @test !isempty(rec.decisions)
    n_checked = 0
    for d in rec.decisions
        (d.sim_t_at === nothing || d.sim_step_at === nothing) && continue
        n_checked += 1
        @test d.sim_t_at ≈ dt * d.sim_step_at
    end
    @test n_checked >= 1   # 이 케이스는 배터리 이벤트 1건 = 결정 1건이 나야 한다 (실측)
end
