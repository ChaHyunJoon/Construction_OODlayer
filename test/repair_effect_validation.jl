# =============================================================================
# test/repair_effect_validation.jl — T5 효과 분류·검사 게이트 (단독 실행, runtests.jl 미포함 — 브리프 요구 없음).
#
#   julia +lts --project=. test/repair_effect_validation.jl
#
# 실제 씬(colored_8x8)에서 **현행 레포의 실제 primitive** 로 도구를 흉내 낸다(Replace·WEDGE 해제·배터리 배송 파견·
# 제자리 배터리 교체·hot swap·빌드 강체 이동). 음성 사례는 전부 실제 세계에 심은 위반이다.
#
# 감사 입력은 T4 와 같은 방법으로 만든다(T7: T6 adapter 처럼 **코드 구간마다**): 필드 diff = `EpisodeCheckpointIO.world_lines` 의 필드 digest 차이(T4
# `audit_snapshot` 과 같은 함수; 대상 모듈만 [CB] — Main 을 넣으면 이 시험의 지역 변수가 필드로 잡힌다),
# 메서드 diff = T4 의 `RepairBranchWorker.method_digests` 그대로.
# `adapter_step!` 은 T6 trusted engine adapter 의 **시험 대역**이다: 런타임 루프와 같은 호출(step_environment! →
# update_planning_cache! → set_sim_step!) 앞뒤로 신뢰 스냅샷을 찍는다.
# =============================================================================
using ConstructionBots, Test, Random, JSON3
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
include(joinpath(@__DIR__, "..", "tools", "monitor", "repair_branch_worker.jl"))    # T4 감사 코드(훅은 env 없으면 안 깔린다)
include(joinpath(@__DIR__, "..", "src", "verification", "effect_validation.jl"))
const TC = TaskContract
const EV = EffectValidation
const E = EpisodeCheckpointIO
const W = RepairBranchWorker

mkenv() = (e = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "t5effects",
        num_robots = 6, assignment_mode = :greedy, n_spare_per_pool = 2,
        open_animation_at_end = false, save_animation = false, write_results = false,
        return_env_before_sim = true, rng = Random.MersenneTwister(1)); CB.enable_battery!(e); CB.set_sim_step!(0); e)
rt(x) = JSON3.read(JSON3.write(x), Dict{String,Any})
snap(env) = rt(TC.task_state(env, CB))
fields(env) = (w = E.world_lines(env; modules = [CB], refs = :identity); E.field_digests(w.lines, w.fields))   # 감사와 같은 @ref 신원 표기(T10b fix)
chg(a, b) = sort!([String(k) for k in union(keys(a), keys(b)) if get(a, k, nothing) != get(b, k, nothing)])
contract(env) = rt(TC.derive_task_contract(env, CB; checkpoint_id = "t0"))
# 필드 audit 은 T6 adapter 와 같이 **코드 구간마다**(T7: 검증기가 그 계약에 기댄다 — engine 구간 변경은 도구 탓이 아니다).
const SEG = Ref{Any}(nothing)            # (start = 현재 코드 구간 시작의 필드 digest, code = 코드 구간에서 바뀐 필드)
function run_tool(env, f)
    m0 = W.method_digests((CB,))
    SEG[] = (start = fields(env), code = Set{String}())
    s0 = snap(env)
    tr = Any[Dict{String,Any}("kind" => "action_start", "state" => s0)]
    f(env, tr)
    s1 = snap(env)
    tr[end]["kind"] == "preflight_stop" || push!(tr, Dict{String,Any}("kind" => "action_end", "state" => s1))
    union!(SEG[].code, chg(SEG[].start, fields(env)))
    audit = Dict{String,Any}("fields_changed_by_action" => sort!(collect(SEG[].code)),
                             "methods_changed_by_action" => chg(m0, W.method_digests((CB,))))
    return (; s0, s1, audit, tr)
end
function adapter_step!(env, tr; clock_skew = 0)
    push!(tr, Dict{String,Any}("kind" => "pre_step", "state" => snap(env)))
    union!(SEG[].code, chg(SEG[].start, fields(env)))           # 코드 구간 끝
    k = CB.SIM_STEP[] + 1 + clock_skew
    CB.step_environment!(env); CB.update_planning_cache!(env, 0.0); CB.set_sim_step!(k)
    SEG[] = (start = fields(env), code = SEG[].code)              # engine 구간은 감사 대상이 아니다 — 다음 코드 구간 시작
    push!(tr, Dict{String,Any}("kind" => "post_step", "state" => snap(env)))
end
check(C, r; trace = true) = EV.validate_effects(C, r.s0, r.s1; audit = r.audit, trace = trace ? r.tr : nothing, proposal_id = "p")
has(vs, p) = any(v -> occursin(p, v), vs)
robots(env) = sort!([n for n in CB.get_nodes(env.scene_tree) if CB.matches_template(CB.RobotNode, n)]; by = n -> string(CB.node_id(n)))
workers(env) = (sp = Set(vcat(values(CB.SPARE_POOLS[])...)); [CB.node_id(n) for n in robots(env) if !(CB.node_id(n) in sp)])
firstpool() = first(sort!(collect(keys(CB.SPARE_POOLS[]))))
nodes_of(env, T) = [n for n in CB.get_nodes(env.sched) if CB.matches_template(T, n)]
vtx(env, n) = CB.get_vtx(env.sched, CB.node_id(n))

@testset "T5 effect validation" begin
    @testset "[A1] 가용 로봇 재배정(Replace: 스페어 인계) — 배정+자원으로 수용" begin
        env = mkenv(); C = contract(env); f = workers(env)[1]
        r = run_tool(env, (e, tr) -> CB.replace_robot!(e, f, CB.pop_spare!(firstpool()); verbose = false))
        v = check(C, r)
        @test v.report.verdict === :accept
        @test :assignment in v.classes && :resource in v.classes && !(:geometry in v.classes)
        @test v.report.stage === :effects && isempty(v.report.adapter_calls)
        # accept 여도 관측 경계가 기계 판독으로 붙는다(T5 fix 3)
        @test any(u -> startswith(u, "intra_segment_change_and_undo"), v.report.unobserved)
    end

    @testset "[A2] 원본 선행을 보존하는 임시 간선 제거(WEDGE 해제) — 수용" begin
        env = mkenv()
        CB.replace_robot!(env, workers(env)[1], CB.pop_spare!(firstpool()); verbose = false)   # t0 이전의 fault 처리
        C = contract(env)
        w = unique(CB.WEDGE_EDGES[]); @test !isempty(w)
        r = run_tool(env, (e, tr) -> foreach(((a, b),) -> CB.Graphs.rem_edge!(e.sched, a, b), w))
        v = check(C, r)
        @test v.report.verdict === :accept && !isempty(v.classes) && !(:geometry in v.classes)
        # 같은 종류의 변경으로 의미 선행을 끊으면 거절(그래프 수정 자체를 막는 게 아니다)
        env = mkenv(); C = contract(env)
        tug = first(nodes_of(env, CB.TransportUnitGo)); dep = CB.get_node(env.sched, CB.DepositCargo(CB.entity(tug)))
        r = run_tool(env, (e, tr) -> CB.Graphs.rem_edge!(e.sched, vtx(e, tug), vtx(e, dep)))
        @test check(C, r).report.verdict === :reject && has(check(C, r).report.reasons, "semantic_precedence_broken")
    end

    @testset "[A3] 실제 자원 작업 요청(배터리 배송 파견) — 자원으로 수용, no-op 아님" begin
        CB.set_battery_courier!(enabled = true)
        try
            env = mkenv(); C = contract(env); t = workers(env)[1]
            r = run_tool(env, (e, tr) -> @test CB.dispatch_battery_courier!(e, t) !== nothing)
            v = check(C, r)
            @test v.report.verdict === :accept && v.classes == [:resource]
            @test r.audit["fields_changed_by_action"] == ["globals.ConstructionBots.BATTERY_DELIVERIES"]
        finally
            CB.set_battery_courier!(enabled = false); CB.clear_battery_deliveries!()
        end
    end

    @testset "[A4] 혼합: 빌드 강체 이동 + 재배정 — 기하+배정+자원" begin
        env = mkenv(); C = contract(env); f = workers(env)[1]
        r = run_tool(env, (e, tr) -> (CB._apply_uniform_translation!(e, [0.3, -0.2]);
                                       CB.replace_robot!(e, f, CB.pop_spare!(firstpool()); verbose = false)))
        v = check(C, r)
        @test v.report.verdict === :accept
        @test issubset([:geometry, :assignment, :resource], v.classes)
    end

    @testset "[A5] 정상 engine 진행은 adapter 로 — 수용; trace 없이 보면 teleport/시계 조작으로 보인다" begin
        env = mkenv(); C = contract(env)
        r = run_tool(env, (e, tr) -> for _ in 1:3; adapter_step!(e, tr); end)
        @test r.s0["robots"] != r.s1["robots"]                         # 로봇이 실제로 움직였다(항진 아님)
        v = check(C, r)
        @test v.report.verdict === :accept && v.report.adapter_calls == [:step_environment!]
        @test v.findings["engine_steps"] == 3
        # 코드 구간 감사: engine 이 바꾼 주행 정책·배터리는 도구 탓이 아니다(T7 — 전 구간 diff 시절의 면제·표시 대신)
        @test !("env.agent_policies" in r.audit["fields_changed_by_action"])
        v0 = check(C, r; trace = false)
        @test v0.report.verdict === :reject && has(v0.report.reasons, "clock_manipulation")
    end

    @testset "[A6] no-op: 센서만 읽고 계산한 도구 — 상태·예약·engine 없음" begin
        env = mkenv(); C = contract(env)
        r = run_tool(env, (e, tr) -> (zb = CB.zone_blockage(e; check_paths = false); length(e.cache.active_set) + zb.n_blocked))
        v = check(C, r)
        @test v.report.verdict === :noop_equivalent && isempty(v.classes)
    end

    @testset "[A7] 가격이 매겨진 배터리 교체 primitive 는 수용, SoC 직접 위조는 거절" begin
        env = mkenv(); t = workers(env)[1]
        CB.BATTERY_FLEET[].soc[t] = 0.3                                # t0 이전 세계: 방전
        C = contract(env)
        r = run_tool(env, (e, tr) -> CB._apply_battery_swap!(e, t; verbose = false))
        v = check(C, r)
        @test v.report.verdict === :accept && v.classes == [:resource]
        env = mkenv(); CB.BATTERY_FLEET[].soc[t] = 0.3; C = contract(env)
        r = run_tool(env, (e, tr) -> (CB.BATTERY_FLEET[].soc[t] = 1.0))
        v = check(C, r)
        @test v.report.verdict === :reject && has(v.report.reasons, "resource_forgery:battery_soc")
    end

    @testset "[A8] hot swap(원장+스페어 소모)의 재배치는 수용, 근거 없는 teleport 는 거절" begin
        env = mkenv(); C = contract(env); t = workers(env)[2]
        r = run_tool(env, (e, tr) -> @test CB.hot_swap_robot!(e, t; verbose = false).status === :swapped)
        @test r.s0["robots"] != r.s1["robots"]
        v = check(C, r)
        @test v.report.verdict === :accept && :resource in v.classes
        env = mkenv(); C = contract(env)
        n = CB.get_node(env.scene_tree, t)
        r = run_tool(env, (e, tr) -> CB.set_desired_global_transform!(n,
            CB.CoordinateTransformations.Translation(1.0, 1.0, 0.0) ∘ CB.global_transform(n)))
        v = check(C, r)
        @test v.report.verdict === :reject && has(v.report.reasons, "robot_teleport:$(string(t))")
    end

    @testset "[N1] 필수 작업 삭제 · [N2] 완료 위조 · [N16] 작업을 막는 배정 노드 닫기" begin
        env = mkenv(); C = contract(env)
        lift = last(nodes_of(env, CB.LiftIntoPlace))
        r = run_tool(env, (e, tr) -> CB.rem_node!(e.sched, CB.node_id(lift)))
        @test has(check(C, r).report.reasons, "required_task_deleted")
        env = mkenv(); C = contract(env)
        os = first(n for n in nodes_of(env, CB.LiftIntoPlace) if !(vtx(env, n) in env.cache.closed_set))
        r = run_tool(env, (e, tr) -> push!(e.cache.closed_set, vtx(e, os)))
        v = check(C, r)
        @test v.report.verdict === :reject && has(v.report.reasons, "status_forgery:closed:")
        env = mkenv(); C = contract(env)
        s = snap(env)
        gating = first(e[1] for e in s["edges"] if s["nodes"][e[1]] == "RobotGo" && s["nodes"][e[2]] == "FormTransportUnit")
        gv = first(v for v in CB.Graphs.vertices(env.sched) if string(CB.node_id(CB.get_node(env.sched, v))) == gating)
        r = run_tool(env, (e, tr) -> push!(e.cache.closed_set, gv))
        @test has(check(C, r).report.reasons, "assignment_closed_while_gating")
    end

    @testset "[N3] 존을 지우고 한 스텝 굴린 뒤 복원 — trace 로만 보인다" begin
        env = mkenv()
        CB.add_restriction_zone!(:t5_zone, [0.5, 0.5], 0.3)
        try
            C = contract(env)
            r = run_tool(env, function (e, tr)
                z = pop!(CB.RESTRICTION_ZONES[], :t5_zone)
                adapter_step!(e, tr)
                CB.RESTRICTION_ZONES[][:t5_zone] = z
            end)
            @test r.s0["zones"] == r.s1["zones"]                                          # 끝 상태는 같다
            @test isempty(TC.evaluate_task_contract(C, r.s1).violations)                  # diff 만으로는 못 본다
            v = check(C, r)
            @test v.report.verdict === :reject
            @test has(v.report.reasons, "transient_protected_violation:zone_removed:t5_zone")
        finally
            empty!(CB.RESTRICTION_ZONES[])
        end
    end

    @testset "[N4] 공짜 자원: 스페어 생성 · [N7] 시계 조작 · [N9] 보호 전역 · [N8] hook · [N10] 모르는 필드" begin
        env = mkenv(); C = contract(env); key = firstpool(); w1 = workers(env)[1]
        r = run_tool(env, (e, tr) -> push!(CB.SPARE_POOLS[][key], w1))
        @test has(check(C, r).report.reasons, "resource_forgery:spare_created:$(string(w1))")
        pop!(CB.SPARE_POOLS[][key])
        r = run_tool(env, (e, tr) -> CB.set_sim_step!(CB.SIM_STEP[] + 5))
        @test has(check(C, r).report.reasons, "clock_manipulation:sim_step")
        CB.set_sim_step!(0)
        old = CB.REPAIR_ABLATION[]
        r = run_tool(env, (e, tr) -> (CB.REPAIR_ABLATION[] = :translate))
        CB.REPAIR_ABLATION[] = old
        v = check(C, r)
        @test v.report.verdict === :reject && has(v.report.reasons, "protected_global_changed:globals.ConstructionBots.REPAIR_ABLATION")
        oldh = CB.BATTERY_STEP_HOOK[]
        r = run_tool(env, (e, tr) -> (CB.BATTERY_STEP_HOOK[] = (x...) -> nothing))
        CB.BATTERY_STEP_HOOK[] = oldh
        v = check(C, r)
        @test v.report.verdict === :unsupported && has(v.report.reasons, "persistent_callback:globals.ConstructionBots.BATTERY_STEP_HOOK")
        oldc = CB.CAMERA_FOLLOW[]
        r = run_tool(env, (e, tr) -> (CB.CAMERA_FOLLOW[] = !oldc))
        CB.CAMERA_FOLLOW[] = oldc
        v = check(C, r)
        @test v.report.verdict === :unsupported && has(v.report.reasons, "unsupported_effect:field:globals.ConstructionBots.CAMERA_FOLLOW")
    end

    @testset "[N11] 대응 없는 새 건설 노드 → unsupported · [N12] goal=start → 거절" begin
        env = mkenv(); C = contract(env)
        n = CB.ProjectComplete()
        r = run_tool(env, (e, tr) -> CB.add_node!(e.sched, CB.ScheduleNode(CB.node_id(n), n)))
        v = check(C, r)
        @test v.report.verdict === :unsupported && has(v.report.reasons, "task_refinement_without_correspondence")
        env = mkenv(); C = contract(env)
        tug = first(nodes_of(env, CB.TransportUnitGo))
        r = run_tool(env, (e, tr) -> CB.set_desired_global_transform!(CB.goal_config(tug), CB.global_transform(CB.start_config(tug))))
        v = check(C, r)
        @test v.report.verdict === :reject && has(v.report.reasons, "transport_skipped")
        @test :geometry in v.classes                           # 분류는 기하 — 판정은 계약이 한다
    end

    @testset "[N13] 깨진 export 와 검증기 자신의 오류는 다른 사유 · [N14] preflight · [N15] adapter 시계" begin
        env = mkenv(); C = contract(env)
        r = run_tool(env, (e, tr) -> nothing)
        bad = deepcopy(r.s1); delete!(bad, "zones")
        v = EV.validate_effects(C, r.s0, bad; audit = r.audit)
        @test v.report.verdict === :certification_unavailable && startswith(only(v.report.reasons), "malformed_export:")
        badC = deepcopy(C); delete!(badC, "atol")
        v = EV.validate_effects(badC, r.s0, r.s1; audit = r.audit)
        @test v.report.verdict === :certification_unavailable && startswith(only(v.report.reasons), "validator_error:")
        # preflight: 도구가 engine 진행을 요청한 자리에서 멈춘다 → 거절이 아니라 requires_runtime
        r = run_tool(env, (e, tr) -> push!(tr, Dict{String,Any}("kind" => "preflight_stop", "state" => snap(e))))
        v = check(C, r)
        @test v.report.verdict === :requires_runtime
        # adapter 가 시계를 한 칸 넘게 움직이면 거절
        env = mkenv(); C = contract(env)
        r = run_tool(env, (e, tr) -> adapter_step!(e, tr; clock_skew = 2))
        @test has(check(C, r).report.reasons, "engine_step_clock_mismatch")
    end

    @testset "[N17] 비용 회피: 에너지 누계 감소" begin
        env = mkenv()
        for k in 1:60; CB.step_environment!(env); CB.update_planning_cache!(env, 0.0); CB.set_sim_step!(k); end
        C = contract(env)
        r0 = [k for (k, x) in CB.BATTERY_FLEET[].energy_J if x > 0]
        @test !isempty(r0)
        rid = first(r0)
        r = run_tool(env, (e, tr) -> (CB.BATTERY_FLEET[].energy_J[rid] = 0.0))
        @test has(check(C, r).report.reasons, "cost_evasion:energy_J")
    end

    @testset "[N18] 존 제거 → 주행 정책 재계산 → 복원: 끝 상태는 같지만 accept 로 접지 않는다" begin
        env = mkenv()
        for k in 1:40; CB.step_environment!(env); CB.update_planning_cache!(env, 0.0); CB.set_sim_step!(k); end
        CB.add_restriction_zone!(:t5_zone, [0.5, 0.5], 0.3)
        try
            C = contract(env)
            navs = [CB.get_node(env.sched, v).node for v in env.cache.active_set
                    if CB.get_node(env.sched, v).node isa Union{CB.RobotGo,CB.TransportUnitGo}]
            @test !isempty(navs)
            r = run_tool(env, function (e, tr)
                z = pop!(CB.RESTRICTION_ZONES[], :t5_zone)
                foreach(n -> CB.get_twist_cmd(n, e), navs)             # 존 없는 세계에서 정책 갱신
                CB.RESTRICTION_ZONES[][:t5_zone] = z
            end)
            @test r.s0["zones"] == r.s1["zones"] && "env.agent_policies" in r.audit["fields_changed_by_action"]
            v = check(C, r)
            @test v.report.verdict === :unsupported
            @test "unverifiable:derived_plan_changed_by_code:env.agent_policies" in v.report.reasons
            @test any(u -> startswith(u, "intra_segment_change_and_undo"), v.report.unobserved)
        finally
            empty!(CB.RESTRICTION_ZONES[])
        end
    end

    @testset "[N19] 코드 구간의 export 밖 의미 변경 + engine step 한 번 → accept 로 접지 않는다(T7: n_engine 면제 제거)" begin
        env = mkenv(); C = contract(env); w = workers(env)[1]
        r = run_tool(env, function (e, tr)
            push!(CB.BATTERY_FLEET[].depleted, w)                    # 정지 후보 표시 — task_state 의 어느 절에도 안 실린다
            adapter_step!(e, tr)                                      # engine 구간은 resources(soc·energy)를 바꾼다
        end)
        @test "globals.ConstructionBots.BATTERY_FLEET" in r.audit["fields_changed_by_action"]
        @test r.s0["resources"] != r.s1["resources"]                  # 전 구간 diff 로는 resources 절이 "설명" 해 버린다(항진 아님)
        v = check(C, r)
        @test v.report.verdict !== :accept
        @test "unsupported_effect:unexported_change:globals.ConstructionBots.BATTERY_FLEET" in v.report.reasons
        delete!(CB.BATTERY_FLEET[].depleted, w)
        # 같은 변경을 engine 구간이 했다면(코드 구간 감사에 안 잡힘) 도구 탓이 아니다 — 음성 대조
        r = run_tool(env, (e, tr) -> adapter_step!(e, tr))
        @test !("globals.ConstructionBots.BATTERY_FLEET" in r.audit["fields_changed_by_action"]) && check(C, r).report.verdict === :accept
    end

    # 🔴 마지막: 메서드 재정의는 프로세스를 오염시킨다(되돌릴 수 없다 — 설계 §7.3).
    @testset "[N5] 채점기/센서/기존 메서드 override" begin
        env = mkenv(); C = contract(env)
        r = run_tool(env, (e, tr) -> Core.eval(CB, :(project_complete(env::PlannerEnv) = true)))
        v = check(C, r)
        @test v.report.verdict === :reject && has(v.report.reasons, "runtime_override:ConstructionBots.project_complete")
    end
end
