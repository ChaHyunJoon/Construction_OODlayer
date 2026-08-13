# tools/test_policy_oracle.jl
# =============================================================================
# `policy.jl` 의 **oracle 실행 lane** 자기점검 (2026-08-12).
#
# 왜 이 파일이 필요한가
# ---------------------
# oracle lane 은 `wm4spacecraft_manufacturing/reference_policy.py` 의 기준 행동 a* 를 **결정
# 시점에** 다시 계산해 집행한다. 두 구현이 갈려도 **에러가 나지 않는다** — 표의 `oracle` 행이
# "a* 를 집행했다"는 이름을 달고 다른 것을 집행할 뿐이다. 실제로 2026-08-12 진단 전까지 이 lane 은
# 아예 없어서 `policy.jl` 의 `enacted = "canonical"` 폴백으로 조용히 떨어졌고, 그 판의 결정
# 적중률이 0/4 였다(a* 라면 정의상 4/4).
#
# 여기서는 서비스도 렌더도 없이 세 축의 분기 + `decide_all` 배선을 초 단위로 대조한다.
# 실판에서의 교차검사는 `llm_ood_eval.py` 산출물을 `reference_policy.score` 로 채점하는 쪽이 한다.
#
# 검사 대상:
#   (1) `oracle_macro` 의 battery/fault/zone/reform 분기가 reference_policy.py 와 같은가
#   (2) **폴백은 언제나 `canonical_macro` 다** (NOOP 이 아니다). a* 가 미정의인 자리 —
#       reform, 미검증 SoC 구간, 결측 상태, zone_diagnosis 실패 — 에서 NOOP 으로 떨어지면
#       reform 사건의 교착이 그대로 남고 그것이 곧 미완주다.
#   (3) 상수 `ORACLE_BATTERY_DEEP_SOC` 가 `reference_policy.py` 의 `BATTERY_DEEP_SOC` 와 같은가
#       (갈리면 SoC 중간 구간에서 두 구현이 다른 팔을 낸다 = oracle 적중률이 1.0 이 아니게 된다)
#   (4) `decide_all` 이 `pol["oracle"]` 을 채우되 **다른 정책의 화면/스트림에는 안 새는가**
#   (5) zone 가지의 상태 게이트가 **래치가 아니라 술어인가**(3b절) -- Replace 가 일어난 상태
#       (RECOVERY_SPARES 가 비어 있지 않다)에서 **예비가 도착했으면** NOOP 이 아니라 RelocateBuild
#       가 나와야 한다. 옛 술어 `!isempty(recovery_spares())` 는 도착해도 안 풀리는 단방향 래치라
#       이 검사에서 떨어진다.
#
# 실행:  julia +lts --project=. tools/test_policy_oracle.jl
# =============================================================================
using ConstructionBots
# Graphs 는 policy.jl 의 `_agent_pending` 이 쓴다(스크립트라 자기 의존성을 안 들고 온다).
import HiGHS, Logging, Graphs
const CB = ConstructionBots

npass = 0; nfail = 0
function check(name, ok, detail = "")
    global npass, nfail
    ok ? (npass += 1) : (nfail += 1)
    println("  [", ok ? "PASS" : "FAIL", "] ", name, isempty(detail) ? "" : "  -- " * detail)
end

# ood_truth.jl(ZoneTruth) 은 navigator.jl 안에 있고 런타임에 CB 스코프로 include 된다(world-age 회피).
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
# 라우터는 끈다: 이 파일이 보는 것은 기준행동이지 novelty 판정이 아니다.
ENV["DEMO_ROUTER"] = "0"
include(joinpath(@__DIR__, "monitor", "policy.jl"))

# 큰 스택 태스크(빌드 파이프라인이 깊은 재귀를 쓴다). tools/test_policy_zone.jl 의 것과 동일.
function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))
    return res[]
end

println("\n== 0. 상수 계약 -- ORACLE_BATTERY_DEEP_SOC == reference_policy.BATTERY_DEEP_SOC ==")
# 이 검사만 env 없이 즉시 돈다. 두 값이 갈리면 SoC 가 그 사이에 든 사건에서 Julia 와 Python 이
# 다른 팔을 내고, 그것이 곧 "oracle 인데 적중률이 1.0 이 아니다" 로 나타난다.
let refpy = joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "reference_policy.py")
    if !isfile(refpy)
        check("reference_policy.py 를 찾을 수 있다", false, "path=$(refpy)")
    else
        m = match(r"^BATTERY_DEEP_SOC\s*=\s*([0-9.]+)"m, read(refpy, String))
        if m === nothing
            check("reference_policy.py 에서 BATTERY_DEEP_SOC 를 읽는다", false)
        else
            local pyv = parse(Float64, m.captures[1])
            println("    python BATTERY_DEEP_SOC = $(pyv) / julia ORACLE_BATTERY_DEEP_SOC = $(ORACLE_BATTERY_DEEP_SOC)")
            check("두 상수가 같다", pyv == ORACLE_BATTERY_DEEP_SOC,
                  "python=$(pyv) julia=$(ORACLE_BATTERY_DEEP_SOC)")
        end
    end
end

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 60.0, "mip_rel_gap" => 0.05,
                                          "output_flag" => false, "presolve" => "on")

println("\n>>> building fast geometry env (tractor, rvo off)...")
pp = CB.get_project_params(4)
env = run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Error,
        rvo_flag=false, tangent_bug_flag=false, dispersion_flag=false,
        open_animation_at_end=false, save_animation=false, write_results=false,
        overwrite_results=false, look_for_previous_milp_solution=false,
        save_milp_solution=false, return_env_before_sim=true)
end

println("\n== 1. battery 축 -- SoC <= 0.5 는 충전을 되살리는 팔, 그 위는 근거가 없다 ==")
# 배터리 레이어가 없으면 valid_macros 가 SwapBattery 를 메뉴에서 빼므로 두 갈래를 다 확인한다
# (reference_policy.py:175 의 `"SwapBattery" if "SwapBattery" in valid else "Replace"` 와 같은 규칙).
have_fleet = (try CB.BATTERY_FLEET[] !== nothing catch; false end)
println("    BATTERY_FLEET 설치됨 = $(have_fleet)")
restore_arm = have_fleet ? "SwapBattery" : "Replace"
t_deep  = CB.BatteryTruth(CB.RobotID(1), 0.02)
t_edge  = CB.BatteryTruth(CB.RobotID(1), 0.5)     # 경계값: reference_policy 는 `soc <= 0.5`
t_mild  = CB.BatteryTruth(CB.RobotID(1), 0.80)    # 격자가 테스트한 사다리(최고 rung 0.50) 바깥
t_nan   = CB.BatteryTruth(CB.RobotID(1), NaN)     # 값이 있으나 유한하지 않다
check("깊은 방전(SoC=0.02) -> 충전을 되살리는 팔",
      oracle_macro(env, t_deep) == restore_arm, "got=$(oracle_macro(env, t_deep))")
check("경계값 SoC=0.5 는 '깊은 방전' 쪽(<=)",
      oracle_macro(env, t_edge) == restore_arm, "got=$(oracle_macro(env, t_edge))")
# ★ mild 는 NOOP 이 아니다. reference_policy.py:184 가 SoC>0.5 를 **unscored(None)** 로 돌려주므로
#   (근거 격자가 없는 구간) 실행 lane 은 기준선이 하는 일을 그대로 해야 두 구현이 정확히 겹친다.
check("미검증 구간(SoC=0.80) -> canonical 에 위임 (NOOP 을 지어내지 않는다)",
      oracle_macro(env, t_mild) == canonical_macro(env, t_mild),
      "oracle=$(oracle_macro(env, t_mild)) canonical=$(canonical_macro(env, t_mild))")
check("SoC 가 유한하지 않으면 canonical 에 위임",
      oracle_macro(env, t_nan) == canonical_macro(env, t_nan),
      "oracle=$(oracle_macro(env, t_nan)) canonical=$(canonical_macro(env, t_nan))")

println("\n== 2. fault 축 -- 일을 지고 있었는가로 갈린다 ==")
# _agent_pending 은 env 의 스케줄을 읽는다. 시뮬 전 env 라 로봇 1은 아직 운반 투입 작업을 진다.
t_fault = CB.FaultTruth(CB.RobotID(1), [0.0, 0.0])
pend1 = _agent_pending(env, CB.RobotID(1))
println("    RobotID(1) agent_pending = $(pend1)")
check("사전조건: 시뮬 전 env 에서 로봇 1은 일감을 지고 있다", pend1 > 0, "pend=$(pend1)")
check("일감 있는 로봇 고장 -> Replace", oracle_macro(env, t_fault) == "Replace",
      "got=$(oracle_macro(env, t_fault))")
# robot 이 없는(=agent_pending 이 -1 로 기록되는) fault 는 reference_policy 가 unscored 로 뺀다.
t_fault_noagent = CB.FaultTruth(nothing, [0.0, 0.0])
check("대상 로봇이 없으면 canonical 에 위임",
      oracle_macro(env, t_fault_noagent) == canonical_macro(env, t_fault_noagent),
      "oracle=$(oracle_macro(env, t_fault_noagent)) canonical=$(canonical_macro(env, t_fault_noagent))")

println("\n== 3. zone 축 -- 막힘>0 '그리고' root 하역목표 0 일 때만 개입 ==")
gs = CB.root_deposit_goals(env)
zc = isempty(gs) ? [1.5, 0.96] : sum(gs) ./ length(gs)
CB.clear_restriction_zones!()
CB.add_restriction_zone!(:faraway, [500.0, 500.0], 1.0)   # 아무것도 안 덮는 구역
t_far = CB.ZoneTruth(:faraway, [500.0, 500.0], 1.0, nothing)
zdg_far = CB.zone_diagnosis(env, :faraway)
println("    :faraway -> nav_blocked=$(zdg_far.n_nav_blocked) root_covered=$(zdg_far.root_covered)")
check("사전조건: 먼 구역은 아무 항법 목표도 안 막는다", zdg_far.n_nav_blocked == 0)
check("아무것도 막지 않는 구역 -> NOOP", oracle_macro(env, t_far) == "NOOP",
      "got=$(oracle_macro(env, t_far))")
# 등록되지 않은 구역 = zone_diagnosis 가 exists=false 를 낸다. reference_policy 는 그 사건에
# zone_primitives 가 없어 unscored 로 빼므로, 실행 lane 은 canonical 에 위임해야 겹친다.
t_ghost = CB.ZoneTruth(:no_such_zone_xyz, [0.0, 0.0], 1.0, nothing)
check("등록 안 된 구역(진단 불가) -> canonical 에 위임",
      oracle_macro(env, t_ghost) == canonical_macro(env, t_ghost),
      "oracle=$(oracle_macro(env, t_ghost)) canonical=$(canonical_macro(env, t_ghost))")

println("\n== 3b. zone 축 -- 전역 이동은 '지금 돌아오는 중인 운반체' 가 없을 때만 legal ==")
# 왜 이 절이 있는가: 2026-08-13 실측에서 `fault_zone` seed 1 이 a* 를 그대로 집행하면 closed=186 에서
# 멎었다(2판 소수점까지 동일). 같은 구역·같은 Δ 인데 `battery_zone` seed 1 은 완주(291)한다. 두 판의
# zone_primitives 는 n_teams_forming 말고 전부 같다 -- 구역 기하로는 구분이 불가능하고, 구분하는 것은
# **closed=58 의 Replace 가 로봇을 depot 으로 빼돌렸는가**(RECOVERY_SPARES)라는 상태다.
# ⚠ 그래서 이 가지는 reference_policy.py 와 **의도적으로 갈린다**(그쪽은 이 상태를 볼 칸이 없다).
#
# ★ 2026-08-13(2차): 처음 배선한 술어 `!isempty(recovery_spares())` 는 **런 범위 단방향 래치**였다
#   (도착해도 원소를 빼는 경로가 없다). 그 아래에서 돈 210판(results_oracle/)에서 `fault_zone` 이
#   22/30 이었고, 8개 미완주 중 7개가 `Replace → zone→NOOP` 모양으로 closed=285 에 멎었다.
#   그래서 술어를 `_recovery_in_transit(env)` 로 바꿨다 -- "복구 임무 중인 로봇이 **지금** 남은
#   항법 목표들이 이루는 프레임 **밖**에 있는가".
#   ⇒ 이 절의 핵심 검사는 **래치와 갈리는 자리**다: RECOVERY_SPARES 가 비어 있지 **않은데도**
#     그 로봇이 이미 빌드 안에 있으면 답은 NOOP 이 아니라 RelocateBuild 여야 한다.
CB.clear_recovery_spares!()
navs = try CB._nav_goal_targets(env) catch; NamedTuple[] end
# ★ 이 탐색은 **함수 안**에 있어야 한다. 스크립트 최상위의 `for` 는 soft scope 라 루프 안에서
#   전역에 대입하면 새 지역변수가 만들어지고(비대화형에서는 경고만 나고 전역은 nothing 그대로),
#   "구역을 못 만들었다"는 거짓 실패가 난다 -- 실제로 처음 작성했을 때 그 함정에 빠졌다.
# 찾는 상태: 항법 목표를 실제로 막고(n_nav_blocked>0), root 하역목표는 안 걸리고(root_covered==0),
#   전역 이동이 가능하고(relocate_feasible), **국소 재적치 도메인은 비어 있는**(n_restage_feasible==0)
#   구역 -- 실판에서 관측된 zone 사건이 정확히 이 모양이다(fault_zone/battery_zone/zone 전부).
function _find_blocking_zone(env, navs)
    for t in navs, r in (0.07, 0.15, 0.3)
        CB.clear_restriction_zones!()
        CB.add_restriction_zone!(:blocker, [t.goal[1], t.goal[2]], r)
        zd = try CB.zone_diagnosis(env, :blocker) catch; nothing end
        zd === nothing && continue
        (zd.n_nav_blocked > 0 && zd.root_covered == 0 && zd.relocate_feasible &&
         zd.n_restage_feasible == 0) && return zd
    end
    return nothing
end
zd_blk = _find_blocking_zone(env, navs)
if zd_blk === nothing
    check("사전조건: 항법 목표를 실제로 막는 구역을 만들 수 있다", false,
          "nav_goal 후보 $(length(navs))개로 못 만들었다")
else
    t_blk = CB.ZoneTruth(:blocker, Vector{Float64}(zd_blk.center), zd_blk.radius, nothing)
    println("    :blocker -> nav_blocked=$(zd_blk.n_nav_blocked) root_covered=$(zd_blk.root_covered) " *
            "restage_feasible=$(zd_blk.n_restage_feasible) relocate_feasible=$(zd_blk.relocate_feasible)")
    check("사전조건: 막힘>0 & root 0 (개입할 이유가 있는 상태)",
          zd_blk.n_nav_blocked > 0 && zd_blk.root_covered == 0)
    CB.clear_recovery_spares!()
    check("돌아올 로봇이 없으면 전역 이동(= reference_policy 와 같은 답)",
          oracle_macro(env, t_blk) == "RelocateBuild", "got=$(oracle_macro(env, t_blk))")

    # 두 종류의 로봇을 **env 를 건드리지 않고** 고른다(기하 조작은 start_config 가 goal_config 를
    # 함께 끌고 가서 상대거리가 안 바뀐다 -- 2026-08-13 실측으로 접었다):
    #   arrived : 남은 목표 중 가장 가까운 것이 제 몸 반경 안 = 도착
    #   enroute : 가장 가까운 목표도 제 몸 반경 밖   = 아직 오는 중
    # 술어(`_recovery_in_transit`)와 **같은 계산**을 여기서 독립적으로 다시 한다.
    # (루프가 함수 안에 있어야 하는 이유는 위 _find_blocking_zone 주석과 같다 -- soft scope.)
    function _dmin_by_robot(env)
        acc = Dict{Any,Vector{Float64}}()
        for t in CB._nav_goal_targets(env)
            t.kind === :robot || continue
            local d = hypot(t.pos[1] - t.goal[1], t.pos[2] - t.goal[2])
            local tol = max(Float64(t.radius), CB.capture_distance_tolerance())
            if haskey(acc, t.id)
                acc[t.id] = [min(acc[t.id][1], d), max(acc[t.id][2], tol)]
            else
                acc[t.id] = [d, tol]
            end
        end
        arrived = nothing; enroute = nothing; best = 0.0
        for (rid, v) in acc
            if v[1] <= v[2]
                arrived === nothing && (arrived = rid)
            elseif v[1] - v[2] > best
                best = v[1] - v[2]; enroute = rid
            end
        end
        return (arrived = arrived, enroute = enroute, acc = acc)
    end
    pick = _dmin_by_robot(env)
    println("    이동체 로봇 $(length(pick.acc))대 · arrived=$(pick.arrived === nothing ? "없음" : "R" * string(pick.arrived.id)) " *
            "· enroute=$(pick.enroute === nothing ? "없음" : "R" * string(pick.enroute.id))")
    # 시뮬 전 env 라 로봇들은 아직 출발하지 않았다 = 전부 "도착"(dmin≈0)으로 읽힌다.
    # "오는 중" 상태는 실판과 **같은 경로**로 만든다: 그 로봇을 RVO id 맵에 등록하면
    # `_nav_goal_targets` 가 live=true 로 보고 **씬트리 몸체의 실제 위치**를 읽는다
    # (zone_corridor.jl:120-126 -- 실판은 rvo 가 켜져 있어 언제나 이 경로다). 그 상태에서 몸체를
    # 멀리 옮기면 "목표에서 먼 로봇" 이 된다.
    if pick.arrived === nothing
        check("사전조건: 이동체 로봇을 하나 찾는다", false, "acc=$(length(pick.acc))")
    else
        rid = pick.arrived
        CB.mark_recovery_spare!(rid)                # 이 판에서 Replace 가 일어났다
        # 그 Replace 가 **창고 왕복(:via_depot)** 이었다는 표식. 실판에서는 replace_robot.jl:1499 가
        # mark_recovery_spare! 와 같은 자리에서 이걸 남긴다(현장 예비 접합 Replace 는 안 남긴다).
        CB.decommissioned_bodies()[rid] = [0.0, 0.0]
        check("사전조건: Replace 가 일어난 상태다(RECOVERY_SPARES 가 비어 있지 않다)",
              !isempty(CB.recovery_spares()), "n=$(length(CB.recovery_spares()))")

        # (i) 그 예비를 목표에서 멀리 떨어뜨린다 = "아직 오는 중".
        body = CB.get_node(env.scene_tree, rid)
        body_tf = CB.global_transform(body)
        CB.rvo_reset_agent_map!()                   # 이 판은 rvo 를 안 쓰므로 맵은 비어 있다
        CB.set_rvo_id_map!(rid, 0)                  # -> live=true 경로를 켠다(실판과 같은 읽기)
        CB.set_local_transform!(body, CB.CoordinateTransformations.Translation(500.0, 500.0, 0.0), true)
        local zd_now = try CB.zone_diagnosis(env, :blocker) catch; nothing end
        check("사전조건: 구역은 여전히 항법 목표를 막는다(개입 이유는 그대로)",
              zd_now !== nothing && zd_now.n_nav_blocked > 0 && zd_now.root_covered == 0,
              "nav_blocked=$(zd_now === nothing ? "?" : zd_now.n_nav_blocked)")
        check("사전조건: 오는 중으로 읽힌다", _recovery_in_transit(env) == true)
        check("돌아오는 중인 운반체가 있으면 전역 이동은 legal 이 아니다 -> NOOP",
              oracle_macro(env, t_blk) == "NOOP", "got=$(oracle_macro(env, t_blk))")
        check("그리고 그 답은 여전히 메뉴 안이다",
              oracle_macro(env, t_blk) in valid_macros(env, t_blk),
              "menu=$(valid_macros(env, t_blk))")

        # (ii) ★★ 래치 vs 술어를 가르는 검사 ★★
        # 몸체를 **자기 목표 위**에 세운다 = 그 예비가 **도착**했다. RECOVERY_SPARES 는
        # **그대로 비어 있지 않다**(= Replace 는 여전히 일어난 상태). 바뀐 것은 도착 여부뿐이다.
        # 래치라면 여기서도 NOOP 이고, 진짜 술어라면 RelocateBuild 다.
        function _one_goal_of(env, rid)
            for t in CB._nav_goal_targets(env)
                (t.kind === :robot && t.id == rid) && return t.goal
            end
            return nothing
        end
        gpt = _one_goal_of(env, rid)
        check("사전조건: 그 예비의 목표 지점을 하나 읽는다", gpt !== nothing)
        gpt !== nothing && CB.set_local_transform!(body,
            CB.CoordinateTransformations.Translation(gpt[1], gpt[2], body_tf.translation[3]), true)
        check("사전조건: 도착으로 읽힌다", _recovery_in_transit(env) == false)
        check("★ Replace 는 있었지만 예비가 도착했다 -> NOOP 이 아니라 RelocateBuild (래치가 아니다)",
              oracle_macro(env, t_blk) == "RelocateBuild" && !isempty(CB.recovery_spares()),
              "got=$(oracle_macro(env, t_blk)) n_spares=$(length(CB.recovery_spares()))")
        # (iii) 같은 상태에서 **창고 왕복 표식만** 지운다 = 현장 예비 접합 Replace(replace_robot.jl:
        #       1182/1271). 돌아올 길이 없었으므로 게이트는 걸리지 않아야 한다.
        gpt !== nothing && CB.set_local_transform!(body,
            CB.CoordinateTransformations.Translation(500.0, 500.0, body_tf.translation[3]), true)
        check("사전조건: 다시 멀리 세웠다(창고 표식이 있으면 잠긴다)",
              oracle_macro(env, t_blk) == "NOOP", "got=$(oracle_macro(env, t_blk))")
        delete!(CB.decommissioned_bodies(), rid)
        check("창고 왕복이 없던 Replace(현장 예비 접합)는 게이트를 걸지 않는다",
              _recovery_in_transit(env) == false && oracle_macro(env, t_blk) == "RelocateBuild",
              "in_transit=$(_recovery_in_transit(env)) got=$(oracle_macro(env, t_blk))")

        CB.set_local_transform!(body, CB.CoordinateTransformations.Translation(  # 몸체 원복
            body_tf.translation[1], body_tf.translation[2], body_tf.translation[3]), true)
        CB.rvo_reset_agent_map!()                   # 전역 RVO 맵 원복(다른 절에 새지 않게)
        empty!(CB.decommissioned_bodies())
    end
    CB.clear_recovery_spares!()
    check("복귀 상태를 지우면 원래 답으로 돌아온다(상태 의존이지 영구 변경이 아니다)",
          oracle_macro(env, t_blk) == "RelocateBuild", "got=$(oracle_macro(env, t_blk))")
end
CB.clear_restriction_zones!()
CB.add_restriction_zone!(:faraway, [500.0, 500.0], 1.0)   # 5절이 t_far 를 다시 쓰므로 복원

println("\n== 4. reform 축 -- 실측 격자가 없으므로 canonical 에 위임 ==")
# ★ 이 lane 의 핵심. NOOP 으로 떨어지면 재형성이 필요한 교착을 그대로 두게 되고, 그것이 곧
#   미완주다(README §6: 복구를 되살린 처방이 DEMO_REFORM). reference_policy.py:208 은 이 사건을
#   unscored 로 빼므로 canonical 위임은 채점에도 영향을 주지 않는다.
t_reform = CB.ReformTruth()
check("reform -> canonical 과 같은 답",
      oracle_macro(env, t_reform) == canonical_macro(env, t_reform),
      "oracle=$(oracle_macro(env, t_reform)) canonical=$(canonical_macro(env, t_reform))")
check("reform 폴백이 NOOP 이 아니다(교착을 그대로 두면 안 된다)",
      oracle_macro(env, t_reform) != "NOOP", "got=$(oracle_macro(env, t_reform))")

println("\n== 5. 고른 팔은 언제나 그 사건의 메뉴 안에 있다 ==")
for (nm, t) in (("battery-deep", t_deep), ("battery-edge", t_edge), ("battery-mild", t_mild),
                ("fault", t_fault), ("zone-far", t_far), ("reform", t_reform))
    local vm = valid_macros(env, t)
    local m = oracle_macro(env, t)
    check("$(nm): 고른 팔이 메뉴 안", isempty(vm) || m in vm, "chose=$(m) menu=$(vm)")
end

println("\n== 6. decide_all 배선 -- pol[\"oracle\"] 이 채워지되 이 판(canonical)에는 안 샌다 ==")
# 이 프로세스의 POLICY 는 const 라 include 시점에 굳는다(= 기본값 canonical). 그래서 이 절이 재현하는
# 것은 정확히 **다른 정책의 판**이다: oracle 의 답은 pol 에 계산돼 있지만 화면·스트림에는 안 보여야
# 한다. `DEMO_POLICY=oracle` 로 실제 집행되는지(enacted=="oracle")는 실판 계약이 검사한다
# (llm_ood_eval.py 산출물의 decisions[*].enacted).
withenv("DEMO_ALL_POLICIES" => "0") do
    local d = decide_all(env, t_deep; nl = "")
    check("policies 에 oracle 키가 있다", haskey(d.policies, "oracle"))
    check("oracle 은 언제나 available",
          get(get(d.policies, "oracle", Dict()), "available", false))
    check("oracle 의 chosen == oracle_macro",
          get(get(d.policies, "oracle", Dict()), "chosen", "") == oracle_macro(env, t_deep),
          "chosen=$(get(get(d.policies, "oracle", Dict()), "chosen", ""))")
    # 정답 누출 검사: 후보표/verdict 어디에도 oracle 이라는 출처가 찍히면 안 된다.
    check("후보표 by 필드에 oracle 이 없다",
          all(c -> !occursin("oracle", String(get(c, "by", ""))), d.candidates),
          "cands=$(d.candidates)")
    check("verdict 에 oracle 이 없다", !occursin("oracle", lowercase(d.verdict)),
          "verdict=$(d.verdict)")
end

println("\n== 7. 소스 계약 -- 서비스 게이트엔 oracle 이 있고, 표시 튜플엔 없다 ==")
# 이 둘은 런타임으로 잡을 수 없다(POLICY 가 const 라 한 프로세스에 한 정책뿐이다). 그런데 둘 다
# 깨져도 조용하다: 게이트에서 빠지면 oracle 판이 DSPy 서비스에 의존하게 되고(서비스가 없으면
# 매 사건 경고 + 지연), 표시 튜플에 들어가면 다른 정책의 판마다 정답이 화면에 상시 노출된다.
let src = read(joinpath(@__DIR__, "monitor", "policy.jl"), String)
    check("서비스 생략 게이트가 oracle 을 포함한다",
          occursin(r"POLICY\s+in\s+\(\"canonical\",\s*\"noop\",\s*\"oracle\"\)", src))
    local disp = collect(eachmatch(r"\(\"canonical\",\s*\"surrogate\",\s*\"dspy\"\)", src))
    check("표시 튜플 3곳이 그대로다(oracle 미포함)", length(disp) == 3, "found=$(length(disp))")
    # "surrogate 가 든 튜플" = 표시/비교용 정책 목록. 그 안에 oracle 이 들어가면 누출이다.
    # (서비스 생략 게이트 `("canonical","noop","oracle")` 에는 surrogate 가 없으므로 안 걸린다.)
    local leaky = [m.match for m in eachmatch(r"\([^()]*\"surrogate\"[^()]*\)", src)
                   if occursin("oracle", m.match)]
    check("surrogate 가 든 정책 튜플에 oracle 이 섞이지 않았다", isempty(leaky), "leaked=$(leaky)")
end

CB.clear_restriction_zones!()
println("\n==== policy oracle lane: $(npass) passed, $(nfail) failed ====")
println(nfail == 0 ? "ALL GREEN" : "SOME FAILED")
exit(nfail == 0 ? 0 : 1)
