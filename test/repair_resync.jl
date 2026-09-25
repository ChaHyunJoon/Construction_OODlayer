# =============================================================================
# test/repair_resync.jl — T6 resync 측정·범위 게이트 (단독 실행, runtests.jl 미포함 — 브리프 요구 없음).
#
#   julia +lts --project=. test/repair_resync.jl
#
# `_resync_scene_drift!` 의 후보 열거를 `_drift_candidates` 로 떼어 `scene_drift`(측정)와 한 벌로 만들었다. 이 게이트:
#   [1] 떼어낸 뒤의 resync 가 떼기 전 구현(아래 `OLD_RESYNC` — 커밋 a4cced1c 의 본문 그대로)과 같은 세계를 낸다.
#   [2] `scene_drift` 가 resync 가 옮길 것(`would_snap`)을 정확히 가리키고, 허용 오차 안(0 < d ≤ tol)은 안 옮긴다.
#   [3] 잡힌 cargo(루트가 아닌 본체)와 로봇은 resync 가 옮기지 않는다 — 실제 주행 중 세계에서.
# =============================================================================
using ConstructionBots, Test, Random, JSON3
const CB = ConstructionBots
include(joinpath(@__DIR__, "..", "src", "verification", "tool_execution.jl"))   # (+ task_contract) — protected_moved
const TC = TaskContract

mkenv() = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "t6resync", num_robots = 6,
    assignment_mode = :greedy, n_spare_per_pool = 2, open_animation_at_end = false, save_animation = false,
    write_results = false, return_env_before_sim = true, rng = Random.MersenneTwister(1))

"빌드 전체 강체 이동(스케줄 쪽만 — 씬은 안 따라간다). `_apply_uniform_translation!` 에서 resync 를 뺀 것."
function shift!(env, dx, dy)
    T = CB.CoordinateTransformations.Translation(dx, dy, 0.0)
    ts = [CB.start_config(CB.get_node(env.sched, CB.AssemblyComplete(CB.get_node(env.scene_tree, a))))
          for a in keys(env.staging_circles)]
    top(t) = (c = t; while !CB.has_parent(c, c); c = CB.get_parent(c); any(x -> x === c, ts) && return false; end; true)
    for t in ts
        top(t) && CB.set_desired_global_transform!(t, T ∘ CB.global_transform(t))
    end
end

# 떼기 전 `_resync_scene_drift!` 본문(a4cced1c) — 대조 기준. CB 안에서 정의한다(같은 이름 해석).
Core.eval(CB, Meta.parse("""
function _t6_old_resync!(env; tol::Float64 = default_robot_radius())
    sched = env.sched
    function _resync_if_drifted!(scene_node)
        has_parent(scene_node, scene_node) || return false
        has_vertex(sched, get_start_node(scene_node)) || return false
        g = global_transform(start_config(get_start_node(scene_node, sched)))
        norm(Vector{Float64}(g.translation[1:2]) .-
             Vector{Float64}(global_transform(scene_node).translation[1:2])) > tol || return false
        set_desired_global_transform!(scene_node, g)
        return true
    end
    function _resync_tu!(ent)
        tid = node_id(TransportUnitNode(ent))
        has_vertex(env.scene_tree, tid) || return
        _resync_if_drifted!(get_node(env.scene_tree, tid))
    end
    for n in get_nodes(sched)
        if matches_template(ObjectStart, n) || matches_template(AssemblyComplete, n)
            ent = entity(n)
            _resync_if_drifted!(get_node(env.scene_tree, node_id(ent)))
            _resync_tu!(ent)
        end
    end
    return env
end"""))

st(env) = TC.task_state(env, CB)

@testset "T6 resync measurement / scope" begin
    @testset "[1] 떼어낸 resync ≡ 떼기 전 구현 (같은 섭동, 같은 세계)" begin
        a, b = mkenv(), mkenv()
        @test TC.digest(st(a)) == TC.digest(st(b))                     # 대조 전제: 두 세계가 같다
        shift!(a, 0.7, -0.4); shift!(b, 0.7, -0.4)
        d = CB.scene_drift(a)
        @test any(x -> x.would_snap, d)                                 # 섭동이 실제로 드리프트를 만들었다(항진 아님)
        CB.resync_scene_to_schedule!(a)                                 # 공개 래퍼 → 새 `_resync_scene_drift!`
        Base.invokelatest(CB._t6_old_resync!, b)
        @test TC.digest(st(a)) == TC.digest(st(b))
        @test all(x -> !x.would_snap, CB.scene_drift(a))
        # 후보 열거가 같은 목록이다: 측정 표의 id 가 스케줄의 ObjectStart/AssemblyComplete 화물(+TU, 있으면) 중
        # 스케줄 start 노드가 있는 것과 순서까지 같다(resync 가 `has_vertex(sched, start)` 로 거르는 것과 같은 규칙)
        want = String[]
        for n in CB.get_nodes(a.sched)
            (CB.matches_template(CB.ObjectStart, n) || CB.matches_template(CB.AssemblyComplete, n)) || continue
            sn = CB.get_node(a.scene_tree, CB.node_id(CB.entity(n)))
            CB.has_vertex(a.sched, CB.get_start_node(sn)) && push!(want, string(CB.node_id(sn)))
            tid = CB.node_id(CB.TransportUnitNode(CB.entity(n)))
            CB.has_vertex(a.scene_tree, tid) && CB.has_vertex(a.sched, CB.get_start_node(CB.get_node(a.scene_tree, tid))) &&
                push!(want, string(tid))
        end
        @test [x.id for x in d] == want && length(want) > 10
    end

    @testset "[2] 측정이 resync 범위를 드러낸다: would_snap 만 옮기고, 허용 오차 안은 안 옮긴다" begin
        env = mkenv()
        tol = CB.default_robot_radius()
        shift!(env, 0.4 * tol, 0.0)                                      # 허용 오차 안의 이동
        d = CB.scene_drift(env)
        moved = [x for x in d if x.dist > 1e-9]
        @test !isempty(moved) && all(x -> x.dist <= tol && !x.would_snap, moved)
        s0 = st(env); CB.resync_scene_to_schedule!(env)
        @test st(env)["scene"] == s0["scene"] && st(env)["tus"] == s0["tus"]   # helper 는 sub-tolerance 를 안 맞춘다(한계)
        shift!(env, 2 * tol, 0.0)
        d = CB.scene_drift(env)
        snap = Set(x.id for x in d if x.would_snap)
        @test !isempty(snap)
        s0 = st(env); CB.resync_scene_to_schedule!(env); s1 = st(env)
        changed = Set(k for k in union(keys(s0["scene"]), keys(s0["tus"]))
                      if get(s0["scene"], k, get(s0["tus"], k, nothing)) != get(s1["scene"], k, get(s1["tus"], k, nothing)))
        @test changed == snap                                             # 정확히 would_snap 인 것만 옮겼다
        @test s1["robots"] == s0["robots"] && s1["rvo"] == s0["rvo"]      # 로봇은 후보가 아니다
    end

    @testset "[3] 주행 중 세계: resync 는 로봇을 직접 안 옮기지만, 운행 중 운반 유닛(루트)을 snap 하면 그 자식(로봇·화물)이 같이 옮겨진다" begin
        env = mkenv(); CB.set_sim_step!(0)
        k = 0; att = []
        while k < 3000
            k += 1
            CB.step_environment!(env); CB.update_planning_cache!(env, 0.0); CB.set_sim_step!(k)
            att = [x for x in CB.scene_drift(env) if !x.free]
            length(att) >= 1 && k > 50 && break
        end
        @test !isempty(att)                                               # 실제로 잡힌 화물이 있는 시점(항진 아님)
        shift!(env, 1.5, 1.0)
        d = CB.scene_drift(env)
        @test all(x -> !(x.would_snap && !x.free), d)                     # 측정: 루트가 아닌 것은 snap 대상이 아니다
        snapped_tus = [x.id for x in d if x.would_snap && x.kind === :tu]
        s0 = st(env); CB.resync_scene_to_schedule!(env); s1 = st(env)
        moved_robots = [r for r in keys(s1["robots"]) if s1["robots"][r] != s0["robots"][r]]
        moved_attached = [x.id for x in d if !x.free && get(s1[x.kind === :tu ? "tus" : "scene"], x.id, nothing) !=
                                                          get(s0[x.kind === :tu ? "tus" : "scene"], x.id, nothing)]
        println("[t6-resync] k=$(k) attached=$(length(att)) snapped_tus=$(length(snapped_tus)) moved_robots=$(length(moved_robots)) moved_attached=$(length(moved_attached))")
        # 범위 밖 이동은 오직 snap 된 운반 유닛을 통해서만 일어난다(로봇·화물을 직접 옮기는 코드는 없다)
        @test isempty(moved_robots) || !isempty(snapped_tus)
        @test isempty(moved_attached) || !isempty(snapped_tus)
        # T6 하니스의 검사(`protected_moved`)가 그 이동을 빠짐없이 잡는다
        mv = ToolExecution.protected_moved(s0, s1, d)
        @test length(filter(m -> startswith(m, "robot_moved"), mv)) == length(moved_robots)
        @test length(filter(m -> startswith(m, "attached_moved"), mv)) == length(moved_attached)
        @test !isempty(moved_robots)                                      # 이 세계에서 실제로 일어난다(실측 — 항진 아님)
    end
end
