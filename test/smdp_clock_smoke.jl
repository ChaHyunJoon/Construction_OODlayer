# test/smdp_clock_smoke.jl
# spec §3.3 Clock · §11-8 — 시계가 셋이었다(SIM_STEP · HazardState.t/.step ·
# run_demo._SIM_STEP). Courier.step_out/step_swap 이 **절대 스텝 인덱스**라 시계를
# 복원 안 하면 배송이 과거나 미래에 도착한다.
#
#   julia +lts --project=. test/smdp_clock_smoke.jl
using ConstructionBots
using Test
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
    CB._hz_sync_clock!(st)
    @test st.step == 7
end
