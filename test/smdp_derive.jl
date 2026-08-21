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
import Logging
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

# -----------------------------------------------------------------------------
# 🔴🔴 **레인 격리용 임시 비계(scaffold)다. 병합 시 삭제된다.** 🔴🔴
#
#   `t7_simstate` 는 `sdd-lane-f` 가 `oracle-rebuild-night-2026-08-10` 에서 갈라진 시점에
#   그 브랜치의 `simstate_of` 가 아직 축소되지 않았기 때문에만 존재한다. **Task R2 는 이미
#   완료·병합됐다** — 권위는 언제나 병합된 `CB.simstate_of` 이고, 이 헬퍼도 계획서의 R2 초안
#   본문도 **한 번도 권위였던 적이 없다.**
#
#   ⛔ 병합 시 할 일(기계적이다 — `src/` 의 어떤 것도 이 이름에 의존하지 않는다):
#        `grep -n t7_simstate test/smdp_derive.jl` → 정의와 호출 전부를 지우고
#        `CB.simstate_of(env)` 로 바꾼다. 두 구현이 갈리면
#        `active_of == cache.active_set` 단언(260/260)이 먼저 빨개진다.
#
# 아래는 왜 이 비계가 필요했는지에 대한 기록이다:
# `simstate_of` 는 이 브랜치의 기반 커밋에서 **아직 7필드가 아니다.**
# Task R1(b578cd3c)이 `simstate.jl` 의 타입만 줄이고 `observe.jl` 은 손대지 않았다 —
# `simstate_of` 는 여전히 `RobotRec(pose=…, health=…, …)` 8필드를 만들어 `MethodError` 로
# 죽는다(Task R1 이 `simstate.jl` 의 타입만 줄이고 `observe.jl` 을 안 고쳤다).
# 폴백이 아니라 비계다 — `simstate_of` 를 try/catch 로 감싸지 않는다(조용한 폴백 금지).
#
# ℹ️ 이 본문은 계획서 R2 초안과 세 군데가 다르다: (1) `_responsible_robots` 를 try/catch 없이
#    바로 부른다, (2) `ball.center[1]`/`ball.radius` 대신 접근자 `get_center`/`get_radius` 를
#    쓴다, (3) `error()` 문구가 다르다. 어느 것도 T7 의 단언에 닿지 않는다. (1)은 결과적으로
#    **병합된 R2** 와 같다 — 그 try/catch 는 R2 리뷰에서 삭제됐다.
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

# =============================================================================
# 🔴 선언한 상한이 **합법적으로** 뒤집힐 수 있는 조건 — `rates.jl` 의 유도를 코드로 옮긴 것.
#
# 이동 모드에서
#     P_light − P_true = km·[ m_robot·(v_ref − speed) − (m_payload/team)·speed ]
# 이므로 `speed > v_ref·m_robot/(m_robot + m_payload/team)` 이면 부호가 뒤집힌다.
# `:manip` 은 `P_light − P_true = (manip_W − idle_W)·(1 − 1/team) >= 0` 이라 **절대 안 뒤집힌다**.
# 세 번째 경로: 한 로봇이 **비대기 노드 두 개 이상**에 걸리면 엔진은 할증을 **더하는데**
# `mode_of` 는 가장 무거운 하나만 고르므로 그것만으로 P_true 가 P_light 를 넘을 수 있다.
# =============================================================================
flip_threshold(p, m_payload::Float64, team::Int) =
    p.v_ref * p.m_robot / (p.m_robot + m_payload / team)

may_flip(p, ctxs) =
    length(ctxs) > 1 ||
    any(c -> c.mode !== :manip && c.speed > flip_threshold(p, c.m_payload, c.team), ctxs)

"뒤집힘 영역에 있으면 **크게** 알리고 `true` 를 돌려준다(호출자가 센다). 조용히 넘어가지 않는다."
function warn_if_flipped(p, id, mode, ctxs, a_light, a_true)
    may_flip(p, ctxs) || return false
    @warn "T7 🔴 선언한 상한이 이 로봇에서 합법적으로 뒤집힐 수 있는 영역이다 (버그 아님 — rates.jl 의 유도 참조)" robot = string(id) mode = mode a_light = a_light a_true = a_true n_nonidle_nodes = length(ctxs) speeds = string([c.speed for c in ctxs]) payloads = string([c.m_payload for c in ctxs]) teams = string([c.team for c in ctxs]) thresholds = string([flip_threshold(p, c.m_payload, c.team) for c in ctxs]) v_ref = p.v_ref
    return true
end

# step k 에서의 모드 관련 단언 전부. env 를 앞으로 못 되감으므로 루프 안에서 그 자리에 돈다.
function check_modes_at(env, k::Int)
    s     = t7_simstate(env)
    heavy = CB._hz_modes(env)
    ms    = sort!(unique(CB.mode_of(s, env, kk) for kk in keys(s.fleet)); by = string)
    sizes = active_team_sizes(env)
    # 🔴 **어느 population 위에서 잰 숫자인가**를 같이 찍는다. 앞선 세대의 실측표가
    # fixture-specific 인 데다 population 이 안 적혀 있어 다른 태스크가 잘못 인용했다.
    all_ids   = sort!(collect(keys(CB.BATTERY_FLEET[].soc)); by = string)
    parked    = union!(Set{Any}(CB.active_spares()), Set{Any}(CB.checked_out_spares()))
    ms_all    = sort!(unique(get(heavy, r, :idle) for r in all_ids); by = string)
    ms_unpark = sort!(unique(get(heavy, r, :idle) for r in all_ids if !(r in parked)); by = string)
    @info "T7 mode probe" step = k n_all = length(all_ids) n_parked = length(parked) n_fleet = length(s.fleet) modes_fleet = string(ms) modes_all = string(ms_all) modes_unparked = string(ms_unpark) teams = string(sort(sizes)) maxteam = (isempty(sizes) ? 0 : maximum(sizes))

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
    s260 = s                                      # active_set 은 이 스텝에 안 바뀐다(캐시 갱신 없음)
    # 스텝 중에 예비 풀이 바뀌었으면 위 스냅샷이 무효다 — 조용히 넘어가지 않는다.
    @test parked == union!(Set{Any}(CB.active_spares()), Set{Any}(CB.checked_out_spares()))
    @info "T7 Ruling2 fleet" n_fleet_soc = length(fleet_b.soc) n_parked = length(parked) dt = dt
    # 🔴 대기 기저도 `mode_power_W` 를 통과시킨다. `p.idle_W * dt` 를 그대로 쓰면 `:idle` 팔은
    # 필드를 자기 자신과 비교하는 꼴이라 그 팔의 버그를 이 장부가 못 잡는다.
    pred   = Dict{Any,Float64}(id => (id in parked ? 0.0 : CB.mode_power_W(p, :idle) * dt)
                               for id in keys(fleet_b.soc))
    nmulti, nmanip = 0, 0
    speeds, payloads = Float64[], Float64[]
    node_ctx = Dict{Any,Vector{Any}}()      # 로봇 -> 그 로봇이 걸린 비대기 노드들의 (mode,team,mp,speed)
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
        sym === :manip || (push!(speeds, spd); push!(payloads, mp))   # 이동 노드만 센다
        w    = CB.mode_power_W(p, sym; team = length(robots), m_payload = mp, speed = spd)
        # ⚠️ 여기서는 `sort!` 한 정점 순서로 할증을 더하는데 엔진은 `env.cache.active_set`
        # (Set) 순서로 더한다. 한 로봇이 **두 개 이상**의 할증을 받는 순간 부동소수 결합
        # 순서가 갈려 아래 `==` 가 1 ulp 로 깨질 수 있다 — 지금 이 스텝에서는 어떤 로봇도
        # 할증을 두 번 안 받아서 살아 있는 것이다. 깨지면 그건 `active_set` 순회 순서의
        # 알려진 비결정성이 비트 단위 단언으로 새어 든 것이지 식의 오류가 아니다.
        for id in robots
            haskey(pred, id) || continue
            pred[id] += (w - p.idle_W) * dt   # 할증은 대기 위 델타 (battery.jl:214-216)
            # 뒤집힘 판정에 필요한 재료를 로봇별로 모은다(아래 (B)에서 쓴다).
            push!(get!(node_ctx, id, Any[]),
                  (mode = sym, team = length(robots), m_payload = mp, speed = spd))
        end
    end
    @info "T7 Ruling2 ledger coverage" n_multi_robot_nodes = nmulti n_manip_nodes = nmanip n_motion_nodes = length(speeds) speed_min = (isempty(speeds) ? NaN : minimum(speeds)) speed_max = (isempty(speeds) ? NaN : maximum(speeds)) payload_min = (isempty(payloads) ? NaN : minimum(payloads)) payload_max = (isempty(payloads) ? NaN : maximum(payloads)) v_ref = p.v_ref
    @test nmulti >= 1                          # 팀 분할 분기(:transit/:carry)를 태웠는가
    @test nmanip >= 1                          # 🔴 :manip 분기도 태웠는가
    # 🔴 실현 속도가 전부 0 이면 이동 팔이 `0.0 == 0.0` 을 비교하는 꼴이 되어 "14/14 exact" 가
    # 조용히 "대기 기저만 잰 시험" 으로 퇴화한다. 하나라도 움직였는지 못박는다.
    @test maximum(speeds) > 0.0
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

    # -------------------------------------------------------------------------
    # 🔴 선언된 근사(`team=1, m_payload=0, speed=v_ref`)의 **순부호와 크기**.
    # 세 대입의 부호가 서로 다르다(speed 는 위로, m_payload 는 아래로) — 그래서 순부호는
    # 주장이 아니라 **단언**이어야 한다. 그리고 크기는 소비처마다 다르므로 **두 번** 잰다.
    # -------------------------------------------------------------------------
    ph  = CB.HazardParams()
    cap = p.capacity_J
    ks  = sort!(collect(keys(s260.fleet)))

    # (A) 에너지 — 게이트 N-G5 가 보는 크기. T12 의 ΔE 와 같은 population(s.fleet) 위에서.
    e_light  = sum(CB.mode_power_W(p, CB.mode_of(s260, env, k)) * dt for k in ks)
    e_engine = sum(e1[rid_of(k)] for k in ks)
    per_robot = [CB.mode_power_W(p, CB.mode_of(s260, env, k)) * dt / e1[rid_of(k)] for k in ks]
    @info "T7 잔차 (A) 에너지 — N-G5 가 보는 크기" e_light e_engine ratio = e_light / e_engine per_robot_min = minimum(per_robot) per_robot_max = maximum(per_robot)
    @test e_engine > 0.0
    @test e_light > e_engine        # 🔴 순부호가 양(+): 경량 레인이 과대평가한다
    # 🔴 "지수의 4~8% 로 N-G5 를 재면 안 된다"의 음성 대조. 실측 집계비 1.48배(= 48% 오차),
    # 로봇 하나로는 최대 4.6배까지 벌어진다 — 지수 오차(3.7%)와 자릿수가 다르다.
    @test e_light / e_engine > 1.2

    # (B) 지수 — 게이트 N-G1 이 보는 크기. `a` 안에서 이 대입이 건드리는 항은 β_s·P/C 하나다.
    worst_a, worst_soc_share, n_flipped = 0.0, 0.0, 0
    for k in ks
        m       = CB.mode_of(s260, env, k)
        a_light = last(CB.rate_params_one(ph, s260.fleet[k], m, p, cap))
        P_true  = e1[rid_of(k)] / dt                     # 엔진이 이 스텝에 실제로 쓴 평균 전력
        du      = (m === :idle) ? 0.0 : ph.beta_usage / ph.usage_scale_s
        a_true  = du + ph.beta_soc * P_true / cap
        ctxs    = get(node_ctx, rid_of(k), Any[])
        # 🔴 **불변식을 단언한다 — 픽스처를 단언하지 않는다.**
        # 앞 판은 맨 `@test a_light >= a_true` 였는데, 그건 `rates.jl` 이 **합법이라고 유도해 둔**
        # 상황에서도 빨개진다. 그러면 종료 코드만 보고는 "선언한 상한이 합법적으로 깨졌다" 와
        # "구현 버그" 를 구분할 수 없다 — 주석을 읽어야만 해석되는 빨간불은 증거가 아니다.
        # 그래서 진짜 불변인 것을 건다: **뒤집힘 조건이 성립하지 않는 한 순부호는 양(+)이다.**
        # 이 명제의 위반은 언제나 진짜 버그이므로 빨간불이 마땅하다.
        # ℹ️ 이 픽스처에서는 `n_flipped == 0` 이므로 이 논리합은 오늘 **맨 단언과 동치**다 —
        #    약해진 것이 없다. 뒤집힘이 실제로 생기는 날에만 갈라진다(그때는 @warn 이 이유를 댄다).
        flipped = warn_if_flipped(p, rid_of(k), m, ctxs, a_light, a_true)
        n_flipped += flipped
        @test a_light >= a_true || flipped
        worst_a = max(worst_a, (a_light - a_true) / a_true)
        worst_soc_share = max(worst_soc_share,
                              ph.beta_soc * CB.mode_power_W(p, m) / cap / a_light)
    end
    @info "T7 잔차 (B) 지수 — N-G1 이 보는 크기" worst_rel_error_in_a = worst_a soc_term_share_of_a = worst_soc_share n_robots_in_flipped_regime = n_flipped n_fleet = length(ks)
    # β_s·P/C 항이 `a` 의 몇 %인지가 이 오차의 **상한**이다. 실측: `:manip`(P=1000 W)에서
    # 8.0%, 이동 모드(P=500 W)에서 4.2%. ⚠️ "약 4%" 는 이동 모드만의 값이었다 — manip 은 그
    # 두 배다. 상한으로 쓸 값은 **8%** 다.
    # 경계는 이 픽스처가 실제로 지탱하는 값으로 좁힌다(실측 0.0800 / 0.0373) — 느슨한 경계를
    # 남겨 두면 아래 분리비 단언과 **동시에 참이면서 서로 모순인** 상태가 생긴다.
    @test worst_soc_share < 0.09
    @test worst_a < 0.05
    @test worst_a <= worst_soc_share + 1e-12   # 🔴 지수 오차는 그 항의 크기를 못 넘는다

    # (C) 두 오차의 **분리비** — 이것이 "N-G5 를 (B) 로 재지 말라"의 근거다.
    # 🔴 앞 판은 `(ratio−1) > 5·worst_a` 였는데 `5` 가 이 픽스처의 관측치(12.8)에 맞춘 숫자였고,
    # 게다가 `worst_a` 의 경계(0.10)와 곱하면 `5·worst_a` 가 관측된 `ratio−1 = 0.478` 을
    # **넘을 수** 있어 두 단언이 서로 모순인 상태를 허용했다. 이제 **비율을 직접 재서 찍고**
    # 바닥값을 건다.
    # 바닥값 3.0 의 출처: 이 문단의 주장은 "두 오차가 자릿수가 다르다" 이다. 분리비가 3 이하로
    # 내려가면 그 주장 자체가 성립하지 않고(하나의 tolerance 로 둘을 재도 큰 사고가 안 난다),
    # 그러면 고칠 것은 시험이 아니라 `rates.jl` 의 이 문단이다. 실측값은 아래 @info 가 매 실행
    # 찍으므로 드리프트가 보인다(현재 12.8).
    separation = (e_light / e_engine - 1.0) / worst_a
    @info "T7 잔차 (C) 두 오차의 분리비 — N-G5 를 N-G1 숫자로 재지 말 것" separation_observed = separation floor = 3.0 energy_rel_error = e_light / e_engine - 1.0 exponent_rel_error = worst_a
    @test separation > 3.0
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

# =============================================================================
# 🔴 뒤집힘 판정기 자체의 단위 시험. 이 픽스처에는 뒤집힌 로봇이 **없으므로**(실측
# `n_robots_in_flipped_regime = 0`) 경고 경로가 한 번도 안 돌면 그 경로가 살아 있는지 알 수
# 없다. 그래서 임계 위/아래 값을 **합성해서** 판정기와 경고를 직접 태운다. 씬이 필요 없다.
# =============================================================================
@testset "🔴 flip 조건과 @warn 경로 (합성 입력 — 씬에 없다)" begin
    p   = CB.BATTERY_FLEET[].params
    mp  = 2.2937600000000002              # 이 픽스처에서 실측된 최대 짐 질량 [kg]
    thr = flip_threshold(p, mp, 1)
    @test thr ≈ p.v_ref * p.m_robot / (p.m_robot + mp)
    @test thr < p.v_ref                   # 짐이 있으면 임계는 v_ref 아래에 있다
    @test flip_threshold(p, 0.0, 1) == p.v_ref   # 짐이 없으면 절대 안 뒤집힌다

    below = Any[(mode = :carry, team = 1, m_payload = mp, speed = thr - 1e-6)]
    above = Any[(mode = :carry, team = 1, m_payload = mp, speed = thr + 1e-6)]
    @test !may_flip(p, below)
    @test  may_flip(p, above)

    # 유도의 음성 대조: 임계 아래에서는 P_light 가 크고, 위에서는 작다.
    P_light = CB.mode_power_W(p, :carry)                       # 기준 조건
    @test CB.mode_power_W(p, :carry; team = 1, m_payload = mp, speed = thr - 1e-6) < P_light
    @test CB.mode_power_W(p, :carry; team = 1, m_payload = mp, speed = thr + 1e-6) > P_light

    # `:manip` 은 어떤 속도·팀에서도 안 뒤집힌다 (P_light − P_true = (manip_W−idle_W)(1−1/team) ≥ 0)
    @test !may_flip(p, Any[(mode = :manip, team = 4, m_payload = 0.0, speed = p.v_ref)])
    @test CB.mode_power_W(p, :manip) >= CB.mode_power_W(p, :manip; team = 4)

    # 세 번째 경로: 비대기 노드 두 개 이상이면 엔진은 할증을 더하므로 뒤집힐 수 있다.
    @test may_flip(p, Any[below[1], (mode = :transit, team = 1, m_payload = 0.0, speed = 0.0)])

    # --- 경고 경로가 실제로 도는가 -------------------------------------------
    # 먼저 **눈에 보이게** 한 번 태운다(캡처하지 않는다). 이 시험 출력에 실제 경고 문구가
    # 찍혀 있어야 "경로가 살아 있다"를 사람이 확인할 수 있다.
    @info "↓↓↓ 아래 @warn 은 합성 입력으로 **의도적으로** 태운 시연이다 (실제 로봇 아님) ↓↓↓"
    warn_if_flipped(p, "SYNTH-DEMO", :carry, above, 1.0, 2.0)

    res = @test_logs (:warn,) match_mode = :any warn_if_flipped(p, "SYNTH-ABOVE", :carry, above, 1.0, 2.0)
    @test res === true                                     # 셌다
    # 그리고 뒤집히지 않았으면 **조용하다**(경고 남발도 정보가 아니다).
    quiet = @test_logs min_level = Logging.Warn warn_if_flipped(p, "SYNTH-BELOW", :carry, below, 2.0, 1.0)
    @test quiet === false
end
