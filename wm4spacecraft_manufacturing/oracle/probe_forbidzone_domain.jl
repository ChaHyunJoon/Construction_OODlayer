# =============================================================================
# probe_forbidzone_domain.jl -- "ForbidZone(3) 이 도메인을 갖는 진행도가 존재하는가" 를 값싸게 판정한다.
#
# WHY THIS EXISTS
# ---------------
# zgrid_0805 의 24행이 전부 zone_restage_feasible=0 이다. 원인 후보가 둘인데 처방이 정반대다:
#   (a) 발화점 붕괴  — tractor 는 첫 배치에서 ~58 노드를 닫아 "early(10~16)" 슬롯이 전부 closed≈50~58
#                      에 due 된다(probe_fire_points.jl 헤더). restageable 집합은 closed≈46 부터 0
#                      (gen_oracle_dataset.jl:359) 이므로, early 가 실은 late 였을 뿐이다.
#                      -> 처방: 발화점을 앞당긴다. 주입기 기하는 그대로 둔다.
#   (b) 기하        — 어느 진행도에서도 "pristine 적치원을 덮으면서 항법 목표도 막는" 구역이 없다.
#                      -> 처방: ForbidZone 은 이 세계에서 죽은 팔이다. 어휘에서 그렇게 적는다.
# 두 주장은 서로 다른 문서의 주석이고 같은 판에서 확인된 적이 없다. 여기서 한 CSV 에 놓는다.
#
# 실행 (ConstructionBots.jl 저장소 루트에서):
#   julia +lts --project=. wm4spacecraft_manufacturing/oracle/probe_forbidzone_domain.jl
# ENV:
#   FZ_FROM/FZ_TO/FZ_EVERY  스캔 구간·간격(닫힌 노드 수). 기본 1 / 120 / 4
#                           -- 46 앞뒤를 촘촘히 봐야 하므로 기본이 probe_fire_points 보다 조밀하다
#   FZ_R      구역 반지름 배수. 기본 "0.5,0.8,1.5" (0.5=데모의 DEMO_ZONE_R, 0.8=라벨러의 rfrac,
#             1.5=더 큰 반지름도 확인해 둔다)
#   FZ_SPARE / FZ_SEED / FZ_OUT
# =============================================================================
import ConstructionBots as CB
import HiGHS, Logging, Random, Graphs
using LinearAlgebra: norm
using Printf

CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 60.0, "mip_rel_gap" => 0.05,
    "output_flag" => false, "presolve" => "on")

const MODE  = lowercase(get(ENV, "FZ_MODE", "presim"))   # presim | scan
const FROM  = parse(Int, get(ENV, "FZ_FROM",  "1"))
const TO    = parse(Int, get(ENV, "FZ_TO",    "120"))
const EVERY = parse(Int, get(ENV, "FZ_EVERY", "4"))
# 반지름 후보. 0.5 = 데모의 DEMO_ZONE_R, 0.8 = 라벨러 place_blocking_zone! 의 rfrac(적치원 반지름 배수),
# 1.5 = 더 큰 반지름. 세 스케일이 섞여 있는 것이 아니다 -- 여기서는 전부 **로봇 반지름 배수**로
# 통일해 잰다. 출력 CSV(16열, 아래 `println(io, "mode,closed,...")` 참고)에는 그 결과 반지름이
# `zone_r` 한 열로만 실린다 -- 적치원 반지름 기준 값을 담는 별도 `rstage` 열은 없다.
const RFRACS = [parse(Float64, strip(s)) for s in split(get(ENV, "FZ_R", "0.5,0.8,1.5"), ",")]
const SPARE = parse(Int, get(ENV, "FZ_SPARE", "3"))
const SEED  = parse(Int, get(ENV, "FZ_SEED",  "1"))
const OUT   = get(ENV, "FZ_OUT",
                  joinpath(@__DIR__, "out", MODE == "scan" ? "fz_scan.csv" : "fz_presim.csv"))
const ROWS  = Ref(NamedTuple[])
const KEY   = :fz_probe

"""
`zone_blocked_assemblies` 의 전제조건만 뽑은 것 — **구역 겹침 검사를 뺀** pristine 집합.

이 수가 0 이면 어떤 구역을 어디에 놓아도 ForbidZone 도메인은 빈다(원인 (a)/(b) 중 (a)).
0 이 아닌데 n_blocked 가 0 이면 겹침이 안 나는 것이다(원인 (b)). 두 원인을 이 한 열이 가른다.
"""
function pristine_assemblies(env)
    isempty(env.staging_circles) && return CB.AbstractID[]
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])),
                  collect(keys(env.staging_circles)))
    out = CB.AbstractID[]
    for (aid, _) in env.staging_circles
        aid == root && continue
        ac = try CB._assembly_complete_node(env, aid) catch; nothing end
        ac === nothing && continue
        v = try CB.get_vtx(env.sched, CB.node_id(ac)) catch; nothing end
        v === nothing && continue
        (v in env.cache.closed_set || v in env.cache.active_set ||
         (try CB._assembly_started(env, aid) catch; false end)) && continue
        push!(out, aid)
    end
    return out
end

"구역을 잠깐 심고 진단한 뒤 반드시 지운다(관찰이 궤적을 바꾸면 안 된다)."
function diag_at(env, center, r)
    CB.add_restriction_zone!(KEY, center, r)
    d = try CB.zone_diagnosis(env, KEY; check_restage = true)
        catch e; @warn "[fz] zone_diagnosis 실패" exception = e; nothing end
    try CB.remove_restriction_zone!(KEY) catch end
    return d
end

function push_row!(env, family, target, center, r, d)
    closed = length(env.cache.closed_set)
    total  = Graphs.nv(CB.get_graph(env.sched))
    push!(ROWS[], (mode = MODE, closed = closed, total = total,
        n_pristine = length(pristine_assemblies(env)), family = family, target = target,
        cx = center[1], cy = center[2], zone_r = r,
        n_blocked = d === nothing ? -1 : d.n_blocked,
        n_restage_feasible = d === nothing ? -1 : d.n_restage_feasible,
        n_nav_goals = d === nothing ? -1 : d.n_nav_goals,
        n_nav_blocked = d === nothing ? -1 : d.n_nav_blocked,
        root_covered = d === nothing ? -1 : d.root_covered,
        relocate_feasible = d === nothing ? false : d.relocate_feasible,
        verdict = d === nothing ? "ERR" : String(d.verdict)))
end

"""
한 스냅샷에서 두 가족의 후보 구역을 **전부** 진단한다.

  :stage — pristine 조립체의 **적치원 중심** 위 (ForbidZone 이 겨냥하는 자리)
  :nav   — run_demo.jl::inject_blocking_zone! 이 고르는 자리(아직 활성이 아닌 항법 목표)

두 가족을 같은 스냅샷에서 재야 "막히기는 하는데 옮길 수는 없다"(= 지금 스트림의 상태)와
"옮길 수도 있고 막기도 한다"(= 우리가 찾는 자리)가 구분된다.

presim 모드에서는 **후보를 자르지 않는다** — 이 표가 곧 사람이 고르는 카탈로그이므로,
"프로브가 안 본 자리라 못 골랐다"가 생기면 안 된다. scan 모드는 절벽만 보면 되므로 nav 후보를
앞의 3개로 자른다(주입기도 정렬 후 앞에서 고른다).
"""
function probe_zone_once(env)
    pris = pristine_assemblies(env)
    for r_frac in RFRACS, aid in pris
        ball = env.staging_circles[aid]
        c = Vector{Float64}(CB.get_center(ball)[1:2])
        r = r_frac * Float64(CB.default_robot_radius())
        push_row!(env, "stage", string(aid), c, r, diag_at(env, c, r))
    end
    isempty(pris) && push_row!(env, "stage", "none", [NaN, NaN], 0.0, nothing)

    navs = try CB._nav_goal_targets(env) catch; [] end
    cand = [t for t in navs if !(t.vtx in env.cache.active_set)]
    nav_take = MODE == "presim" ? cand : first(cand, 3)
    for r_frac in RFRACS, t in nav_take
        r = r_frac * Float64(CB.default_robot_radius())
        c = Vector{Float64}(t.goal)
        push_row!(env, "nav", "vtx$(t.vtx)", c, r, diag_at(env, c, r))
    end

    @printf("[fz] closed=%3d pristine=%2d nav_cand=%3d rows=%d\n",
            length(env.cache.closed_set), length(pris), length(cand), length(ROWS[]))
    return nothing      # nothing = respec 큐에 아무것도 안 들어간다(순수 관찰)
end

function main()
    for f in (:clear_ood_schedule!, :clear_restriction_zones!, :clear_spare_pools!,
              :clear_faulted_robots!, :clear_recovery_spares!, :clear_ood_truth_log!,
              :clear_wedge_edges!, :clear_stalled_robots!)
        try getproperty(CB, f)() catch end
    end
    try CB.set_reform_interval!(parse(Int, get(ENV, "DS_REFORM", "300"))) catch end

    if MODE == "scan"
        for c in FROM:EVERY:TO; CB.schedule_ood_at_closed!(c, probe_zone_once); end
        CB.RESPEC_ENABLED[] = true
    end
    println("[fz] mode=$(MODE) seed=$(SEED) spare=$(SPARE) radii=$(RFRACS)" *
            (MODE == "scan" ? " scan=$(FROM):$(EVERY):$(TO)" : " (시뮬 없음)"))

    # run_lego_demo 호출은 probe_fire_points.jl:288-303 과 **같다**. 단 하나가 다르다:
    #   return_env_before_sim = (MODE == "presim")
    # true 면 sim 루프 전에 완성된 env 를 그대로 돌려준다(full_demo.jl:830) -> 우리가 직접 진단한다.
    # 큰 스택 Task(ccall(:jl_new_task, ...)) 는 두 모드 모두 유지한다 -- 없으면 스택 오버플로.
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try
                   res[] = CB.run_lego_demo(; ldraw_file = "tractor.mpd", num_robots = 10,
                       assignment_mode = :greedy, milp_optimizer = :highs,
                       optimizer_time_limit = 60, log_level = Logging.Warn,
                       max_num_iters_no_progress = parse(Int, get(ENV, "DS_NOPROG", "8000")),
                       rvo_flag = true, tangent_bug_flag = true, dispersion_flag = true,
                       n_spare_per_pool = SPARE, save_animation = false,
                       open_animation_at_end = false, write_results = false,
                       overwrite_results = true, return_env_before_sim = (MODE == "presim"),
                       rng = Random.MersenneTwister(SEED))
               catch e; err[] = (e, catch_backtrace())
               finally done[] = true end), nothing, parse(Int, get(ENV, "DS_STACK", "2000000000")))
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr))

    if MODE == "presim"
        env = res[]
        env === nothing && error("presim: run_lego_demo 가 env 를 돌려주지 않았다")
        probe_zone_once(env)
    end

    mkpath(dirname(OUT))
    open(OUT, "w") do io
        println(io, "mode,closed,total,n_pristine,family,target,cx,cy,zone_r," *
                    "n_blocked,n_restage_feasible,n_nav_goals,n_nav_blocked," *
                    "root_covered,relocate_feasible,verdict")
        for r in ROWS[]
            println(io, join((r.mode, r.closed, r.total, r.n_pristine, r.family, r.target,
                              round(r.cx; digits = 4), round(r.cy; digits = 4),
                              round(r.zone_r; digits = 4),
                              r.n_blocked, r.n_restage_feasible, r.n_nav_goals, r.n_nav_blocked,
                              r.root_covered, Int(r.relocate_feasible), r.verdict), ","))
        end
    end
    println("[fz] wrote $(length(ROWS[])) rows -> $(OUT)")
end

main()
