# =============================================================================
# test/smdp_derive.jl — Task T7, `derive.jl`
#
# 이 시험이 지키는 것 하나: **경량 레인과 무거운 레인이 같은 로봇을 같은 모드로 굴린다.**
# 갈라져도 아무 에러가 안 난다 — λ 만 조용히 달라지고 롤아웃이 시뮬레이터와 다른 세계를 판다.
#
#   julia +lts --project=. test/smdp_derive.jl
#
# 🔴 씬 생성은 `SCENE-INCANTATION.md` 의 정본을 따른다(`return_env_before_sim = true`).
#    계획서 스니펫은 판을 끝까지 굴려 **퇴화한** 세계를 잰다.
#
# 🔴 **스텝 수는 120 이 아니라 260 이다.** SCENE-INCANTATION §2 의 실측표는 다른 픽스처의
#    것이다(`n_spare_per_pool` 없음 · 다른 rng). **이 픽스처를 5스텝 간격 400스텝으로 직접
#    실측**했더니 모드 도메인이 이렇게 나왔다:
#
#      step       distinct  modes                      max team
#      1–90       1         [:transit]                 1
#      95         2         [:carry, :manip]           4
#      100–170    1         [:carry]                   4      ← 🔴 120 은 퇴화 구간이다
#      175–220    2         [:carry, :transit]         2
#      225–240    1         [:transit]                 1
#      245–255    2         [:carry, :transit]         2
#      260        3         [:carry, :manip, :transit] 2      ← 여기서 잰다
#      265–315    1..2                                 2..3
#      330        3         [:carry, :manip, :transit] 2
#
#    그래서 모드가 걸린 단언은 **step 95**(팀 크기 4 — Ruling 1 을 제대로 때린다)와
#    **step 260**(세 모드가 동시에 산다)에서 잰다. 픽스처가 바뀌어 도메인이 다시 납작해지면
#    아래 "비퇴화" 단언이 **먼저** 빨개진다.
# =============================================================================
using ConstructionBots, Test
using LinearAlgebra: norm
import Random
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

# -----------------------------------------------------------------------------
# 🔴 임시 대역: `simstate_of` 는 이 브랜치에서 **아직 7필드가 아니다.**
# Task R1(b578cd3c)이 `simstate.jl` 의 타입만 줄이고 `observe.jl` 은 손대지 않았다 —
# `simstate_of` 는 여전히 `RobotRec(pose=…, health=…, …)` 8필드를 만들어 `MethodError` 로
# 죽는다. 그것을 고치는 것은 **Task R2** 이고 아직 어느 레인에도 커밋되지 않았다(실측:
# `git log --all`, 2026-08-21). 그래서 이 시험은 계획서 Task R2 Step 3 의 본문을 여기서
# 재현한다. ⚠️ R2 가 착지하면 이 헬퍼를 지우고 `CB.simstate_of(env)` 로 바꿀 것.
# 폴백이 아니라 대역이다 — `simstate_of` 를 try/catch 로 감싸지 않는다(조용한 폴백 금지).
# -----------------------------------------------------------------------------
function t7_simstate(env)
    sched, cache = env.sched, env.cache
    fleet_b = CB.BATTERY_FLEET[];  fleet_b === nothing && error("enable_battery! 먼저")
    st      = CB.HAZARD_STATE[];   st === nothing      && error("enable_hazard! 먼저")

    edges = Set{Tuple{Int,Int}}()
    for e in CB.Graphs.edges(sched)
        push!(edges, (CB.Graphs.src(e), CB.Graphs.dst(e)))
    end
    binding = Dict{Int,Int}()
    for v in CB.Graphs.vertices(sched)
        rs = CB._responsible_robots(CB.get_node(sched, v).node)
        isempty(rs) && continue
        binding[v] = CB._int_key(first(sort!(collect(rs); by = string)))
    end
    poses = Dict{Int,NTuple{3,Float64}}()
    for n in CB.get_nodes(env.scene_tree)
        CB.matches_template(CB.AssemblyNode, n) || continue
        tr = CB.global_transform(n).translation
        poses[CB._int_key(CB.node_id(n))] = (Float64(tr[1]), Float64(tr[2]), Float64(tr[3]))
    end
    zones = Dict{Symbol,NTuple{3,Float64}}()
    for (k, ball) in CB.RESTRICTION_ZONES[]
        c = CB.get_center(ball)
        zones[k] = (Float64(c[1]), Float64(c[2]), Float64(CB.get_radius(ball)))
    end
    excluded = CB._hz_excluded()
    fleet = Dict{Int,CB.RobotRec}()
    for rid in sort!(collect(keys(fleet_b.soc)); by = string)
        rid in excluded && continue
        haskey(st.usage_s, rid) || error("t7_simstate: $(rid) 가 hazard 상태에 없다")
        fleet[CB._int_key(rid)] = CB.RobotRec(soc     = Float64(fleet_b.soc[rid]),
                                              usage_s = Float64(st.usage_s[rid]))
    end
    return CB.SimState(g = CB.GraphBlock(edges = edges, binding = binding),
                       geo = CB.GeoBlock(poses = poses, zones = zones),
                       fleet = fleet,
                       prog = CB.ProgBlock(closed = Set{Int}(collect(cache.closed_set))))
end

rid_of(k) = first(r for r in sort!(collect(keys(CB.BATTERY_FLEET[].soc)); by = string)
                  if CB._int_key(r) == k)

# 활성 노드들의 담당 팀 크기(모드가 IDLE 인 노드는 할증 대상이 아니라 제외).
function active_team_sizes(env)
    sizes = Int[]
    for v in sort!(collect(env.cache.active_set))
        node = CB.get_node(env.sched, v).node
        CB._node_mode(node) == CB.IDLE && continue
        r = CB._responsible_robots(node)
        isempty(r) || push!(sizes, length(r))
    end
    return sizes
end

# step k 에서의 모드 관련 단언 전부. env 를 앞으로 못 되감으므로 루프 안에서 그 자리에 돈다.
function check_modes_at(env, k::Int)
    s     = t7_simstate(env)
    heavy = CB._hz_modes(env)
    ms    = sort!(unique(CB.mode_of(s, env, kk) for kk in keys(s.fleet)); by = string)
    sizes = active_team_sizes(env)
    @info "T7 mode probe" step = k modes = ms n_fleet = length(s.fleet) teams = sort(sizes)

    @testset "step $k — 🔴 비퇴화: 모드 도메인이 납작하지 않다" begin
        @test length(ms) >= 2      # 상수를 돌려주는 구현이 초록이 되는 구간을 배제한다
    end
    @testset "step $k — 🔴 팀이 실제로 여럿이다 (Ruling 1 을 시험할 수 있는 픽스처인가)" begin
        @test !isempty(sizes)
        @test maximum(sizes) >= 2  # 전부 1이면 binding 기반 오분류가 드러나지 않는다
    end
    @testset "step $k — mode_of == _hz_modes (같은 분류기, 같은 팀 명부)" begin
        for kk in sort!(collect(keys(s.fleet)))
            @test CB.mode_of(s, env, kk) === get(heavy, rid_of(kk), :idle)
        end
    end
    @testset "step $k — 🔴 Ruling 1: mode_of 는 g.binding 에서 팀을 유도하지 않는다" begin
        # `binding` 은 팀 명부가 아니다: 팀 노드에서 `simstate_of` 는 **한 명만** 적는다
        # (`first(sort(rs; by = string))`). binding 을 통째로 비워도 모드는 하나도 안 변해야
        # 한다. 계획서의 구현(`get(s.g.binding, v, nothing) == k`)은 여기서 무너진다.
        s_nb = CB.SimState(g = CB.GraphBlock(edges = s.g.edges, binding = Dict{Int,Int}()),
                           geo = s.geo, fleet = s.fleet, prog = s.prog)
        for kk in sort!(collect(keys(s.fleet)))
            @test CB.mode_of(s_nb, env, kk) === get(heavy, rid_of(kk), :idle)
        end
    end
    @testset "step $k — 🔴 음성 대조: mode_of 가 상수가 아니다" begin
        s0 = CB.SimState(g = s.g, geo = s.geo, fleet = s.fleet,
                         prog = CB.ProgBlock(closed = Set(1:CB.Graphs.nv(env.sched))))
        @test all(kk -> CB.mode_of(s0, env, kk) === :idle, keys(s0.fleet))
        @test !all(kk -> CB.mode_of(s, env, kk) === :idle, keys(s.fleet))
    end
    @testset "step $k — 🔴 rate_params 가 mode_of 와 같은 모드를 쓴다" begin
        p, bp = CB.HazardParams(), CB.BATTERY_FLEET[].params
        rp = CB.rate_params(s, env, p, bp, bp.capacity_J)
        @test Set(keys(rp)) == Set(keys(s.fleet))          # 여기서 다시 거르지 않는다
        for kk in sort!(collect(keys(s.fleet)))
            want = CB.rate_params_one(p, s.fleet[kk], CB.mode_of(s, env, kk), bp, bp.capacity_J)
            @test rp[kk] == want                            # ≈ 가 아니라 == (구성상 같아야 한다)
        end
        @test length(unique(first.(values(rp)))) >= 2      # A 가 로봇마다 다르다(음성 대조)
    end
    return s
end

# --- 씬 (SCENE-INCANTATION.md 정본) ------------------------------------------
env = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "t7derive",
                         num_robots = 6, assignment_mode = :greedy,
                         n_spare_per_pool = 2,
                         open_animation_at_end = false, save_animation = false,
                         write_results = false, return_env_before_sim = true,
                         rng = Random.MersenneTwister(1))
CB.enable_battery!(env)
CB.enable_hazard!(env; seed = 5)

const MODE_PROBE_STEPS = (95, 260)
maxteam_seen = 0

@testset "active_of == 엔진의 active_set (260 스텝 내내)" begin
    for k in 1:260
        CB.step_environment!(env)
        CB.update_planning_cache!(env, 0.0)
        CB.set_sim_step!(k)
        s = t7_simstate(env)
        @test CB.active_of(s) == Set(env.cache.active_set)
        sz = active_team_sizes(env)
        isempty(sz) || (global maxteam_seen = max(maxteam_seen, maximum(sz)))
        k in MODE_PROBE_STEPS && check_modes_at(env, k)
    end
end
@info "T7 max active team size over 260 steps" maxteam_seen

s = t7_simstate(env)     # step 260 의 세계

@testset "🔴 조용한 폴백 금지" begin
    @test_throws ErrorException CB.mode_of(s, env, -12345)            # fleet 에 없는 로봇
    s_bad = CB.SimState(g = CB.GraphBlock(edges = Set([(1, 10^7)]), binding = Dict{Int,Int}()),
                        geo = s.geo, fleet = s.fleet,
                        prog = CB.ProgBlock(closed = Set([1])))
    @test_throws ErrorException CB.mode_of(s_bad, env, first(keys(s.fleet)))  # 스케줄에 없는 정점
end

# =============================================================================
# Ruling 2 — `mode_power_W` 가 **엔진이 실제로 빼는 에너지**와 같은가.
#
# 대조군은 공식의 복사본이 아니라 **엔진의 장부**다: `fleet.energy_J` 는 `_debit!` 만이 쓴다
# (battery.jl:157). 한 스텝의 장부 증분을 `mode_power_W` 로 예측해서 맞춘다.
# `rates.jl` 은 씬을 못 보므로 이 대조는 여기(derive 시험)에 산다.
# =============================================================================
@testset "🔴 Ruling 2 — mode_power_W == battery.jl 의 실제 소모 (한 스텝 장부 대조)" begin
    fleet_b = CB.BATTERY_FLEET[]
    p  = fleet_b.params
    dt = env.dt * p.seconds_per_step
    st = CB.HAZARD_STATE[]
    # ε_r ≡ 1 (D-5). 아니면 아래 예측에 로봇별 배수가 빠진다 — 조용히 틀리지 않게 못박는다.
    @test all(==(1.0), values(st.eff))
    @test st.params.drain_step_cv == 0.0

    # 🔴 장부를 0 으로 놓고 잰다. 차분(e1 − e0)으로 읽으면 e0 ≈ 650 J 위에서 ~2.5 J 을 빼는
    # 것이라 **읽는 행위 자체가** 상대오차 ~1e-14 를 만든다(실측: 5.77e-14). 그건 식의 차이가
    # 아니다. 0 에서 재면 `energy_J` 가 이번 스텝 부과분의 합 그 자체가 되어 `==` 로 볼 수 있다.
    # (`energy_J` 는 계측용 누적값이고 동역학에 안 들어간다 — 이 시험 뒤엔 아무도 안 읽는다.)
    for id in keys(fleet_b.energy_J); fleet_b.energy_J[id] = 0.0; end
    # 🔴 `parked` 는 **스텝 전에** 잡는다. `battery_courier_step!` 이 `account_battery_step!`
    # **뒤에** 돌면서 예비를 뽑거나 돌려놓을 수 있어서, 스텝 뒤에 재면 엔진이 쓴 집합과 다른
    # 집합을 쓰게 된다(그러면 대조가 조용히 어긋난다 — 실측으로 한 번 데였다).
    parked = union!(Set{Any}(CB.active_spares()), Set{Any}(CB.checked_out_spares()))
    prev = CB.get_active_pos(env)                 # step_environment! 가 잡는 것과 같은 스냅샷
    CB.step_environment!(env)                     # 훅이 이 안에서 장부를 쓴다
    e1   = fleet_b.energy_J
    # 스텝 중에 예비 풀이 바뀌었으면 위 스냅샷이 무효다 — 조용히 넘어가지 않는다.
    @test parked == union!(Set{Any}(CB.active_spares()), Set{Any}(CB.checked_out_spares()))
    @info "T7 Ruling2 fleet" n_fleet_soc = length(fleet_b.soc) n_parked = length(parked) dt = dt
    pred   = Dict{Any,Float64}(id => (id in parked ? 0.0 : p.idle_W * dt) for id in keys(fleet_b.soc))
    nmulti, nmanip = 0, 0
    for v in sort!(collect(env.cache.active_set))
        node = CB.get_node(env.sched, v).node
        m = CB._node_mode(node)
        m == CB.IDLE && continue
        robots = CB._responsible_robots(node)
        isempty(robots) && continue
        length(robots) > 1 && (nmulti += 1)
        m == CB.MANIPULATE && (nmanip += 1)
        sym  = m == CB.TRANSIT ? :transit : (m == CB.CARRY ? :carry : :manip)
        newp = CB.global_transform(CB.entity(node)).translation
        oldp = get(prev, v, newp)
        spd  = dt > 0 ? norm((newp - oldp)[1:2]) / dt : 0.0
        mp   = CB._payload_mass(env, node, p)
        w    = CB.mode_power_W(p, sym; team = length(robots), m_payload = mp, speed = spd)
        for id in robots
            haskey(pred, id) || continue
            pred[id] += (w - p.idle_W) * dt   # 할증은 대기 위 델타 (battery.jl:214-216)
        end
    end
    @info "T7 Ruling2 ledger coverage" n_multi_robot_nodes = nmulti n_manip_nodes = nmanip
    @test nmulti >= 1                          # 팀 분할 분기를 실제로 태웠는가
    worst, nexact = 0.0, 0
    for id in sort!(collect(keys(fleet_b.soc)); by = string)
        got, want = e1[id], pred[id]
        got == want && (nexact += 1)
        worst = max(worst, abs(got - want) / max(abs(want), 1e-12))
        @test got == want            # 🔴 ≈ 가 아니라 == — T6 이 λ 에 세운 기준 그대로
    end
    @info "T7 Ruling2 vs engine ledger" worst nexact n_total = length(fleet_b.soc)
    # 음성 대조: 계획서의 식(팀 분할 없음)은 이 장부를 못 맞춘다.
    @test CB.mode_power_W(p, :manip; team = 2) != p.manip_W
end

@testset "mode_power_W 의 기준 조건 값" begin
    p = CB.BATTERY_FLEET[].params
    @test CB.mode_power_W(p, :idle)    == p.idle_W
    @test CB.mode_power_W(p, :transit) == p.walk_W       # km 의 교정식 그 자체(battery.jl:93-96)
    @test CB.mode_power_W(p, :manip)   == p.manip_W
    @test CB.mode_power_W(p, :carry)   == p.walk_W       # payload 0 · team 1 의 기준값
    @test CB.mode_power_W(p, :carry; m_payload = 30.0) > p.walk_W
    @test CB.mode_power_W(p, :transit; speed = 0.0) == p.idle_W   # 멈춰 있으면 대기 전력뿐
    @test_throws ErrorException CB.mode_power_W(p, :sprint)
    @test_throws ErrorException CB.mode_power_W(p, :carry; team = 0)
end
