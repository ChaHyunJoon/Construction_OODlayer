# =============================================================================
# test_forbidzone_injector.jl -- 선언적 pre-sim 구역 주입기 단위검사. 시뮬 없음.
#
# 왜 이 검사가 필요한가: 주입기가 조용히 실패하면(좌표가 빗나가 아무것도 안 막으면) 팔 게이트가
# ForbidZone 을 안 내주고, 그러면 "LLM 이 ForbidZone 을 안 골랐다"가 아니라 "고를 수 없었다"가
# 되는데 요약만 봐서는 구분이 안 된다. 그 구분을 여기서 강제한다.
#
#   FZ_AT="cx,cy,r"  검사할 좌표(기본 "3.6406,-1.2783,0.21" = fz_presim.csv 에서 고른 행)
#   julia +lts --project=. wm4spacecraft_manufacturing/oracle/test_forbidzone_injector.jl
# =============================================================================
import ConstructionBots as CB
import HiGHS, Logging, Random

# ood_truth.jl(ZoneTruth/record_ood_truth! 등)은 navigator.jl 안에 있고 **런타임에 CB 스코프로**
# include 된다(world-age 회피). 생성기가 하는 것과 같은 방식으로 여기서도 올려야 CB.ZoneTruth 가 보인다.
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 60.0, "mip_rel_gap" => 0.05,
    "output_flag" => false, "presolve" => "on")

include(joinpath(@__DIR__, "..", "..", "tools", "monitor", "zone_inject.jl"))
include(joinpath(@__DIR__, "ood_mdp_shim.jl"))   # _zone_arms_for 등

const FZ_AT = get(ENV, "FZ_AT", "3.6406,-1.2783,0.21")
const AT = let parts = split(FZ_AT, ",")
    (cx = parse(Float64, strip(parts[1])),
     cy = parse(Float64, strip(parts[2])),
     r  = parse(Float64, strip(parts[3])))
end

const FAILED = Ref(0)
function check(name, cond, detail = "")
    if cond
        println("  PASS  $name")
    else
        FAILED[] += 1
        println("  FAIL  $name   $detail")
    end
end

# ---- 씬 준비: run_lego_demo(..., return_env_before_sim=true) 로 env 만 받는다(시뮬 없음) ----
# 큰 스택 Task(ccall(:jl_new_task, ...)) 가 필요하다 -- 없으면 스택 오버플로
# (probe_forbidzone_domain.jl 과 같은 패턴).
println("[test] env 준비 중 (시뮬 없음, 수 분) ...")
res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
    () -> (try
               res[] = CB.run_lego_demo(; ldraw_file = "tractor.mpd", num_robots = 10,
                   assignment_mode = :greedy, milp_optimizer = :highs,
                   optimizer_time_limit = 60, log_level = Logging.Warn,
                   max_num_iters_no_progress = parse(Int, get(ENV, "DS_NOPROG", "8000")),
                   rvo_flag = true, tangent_bug_flag = true, dispersion_flag = true,
                   n_spare_per_pool = 3, save_animation = false,
                   open_animation_at_end = false, write_results = false,
                   overwrite_results = true, return_env_before_sim = true,
                   rng = Random.MersenneTwister(1))
           catch e; err[] = (e, catch_backtrace())
           finally done[] = true end), nothing, parse(Int, get(ENV, "DS_STACK", "2000000000")))
t.sticky = false; schedule(t); while !done[]; sleep(0.05); end
err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); error("env 준비 실패"))
env = res[]
env === nothing && error("presim: run_lego_demo 가 env 를 돌려주지 않았다")
println("[test] env 준비 완료")

println("== 선언적 주입기: ($(AT.cx), $(AT.cy)) r=$(AT.r) ==")

CB.clear_restriction_zones!()
CB.clear_ood_truth_log!()

nl = inject_declared_zone!(env; cx = AT.cx, cy = AT.cy, r = AT.r, key = :zone_declared)

check("1. inject_declared_zone! 이 nl 문자열을 돌려준다", nl isa AbstractString, "got $(typeof(nl))")

d = try CB.zone_diagnosis(env, :zone_declared; check_restage = true) catch e; nothing end
check("2. n_restage_feasible >= 1", d !== nothing && d.n_restage_feasible >= 1,
      "got $(d === nothing ? "d=nothing" : d.n_restage_feasible)")
check("3. n_nav_blocked >= 1", d !== nothing && d.n_nav_blocked >= 1,
      "got $(d === nothing ? "d=nothing" : d.n_nav_blocked)")

ctx_zone = (type = :zone, agent = nothing, zone = :zone_declared, assembly = nothing,
            soc = NaN, after = 0.0, source = "declared zone test")
ctx_zone = _attach_zdiag(env, ctx_zone)
arms = _zone_arms_for(ctx_zone)
check("4. _zone_arms_for 가 3 을 포함한다 (이 태스크의 진짜 산출물)", 3 in arms, "got $arms")

log = CB.ood_truth_log()
truth_ok = !isempty(log) && (try log[end].truth.zone === :zone_declared catch; false end)
check("5. 기록된 ZoneTruth 의 zone 키가 방금 심은 키와 같다", truth_ok,
      "got $(isempty(log) ? "log empty" : log[end].truth)")

println("== 6. 좌표가 빗나갔을 때 조용히 성공하지 않는다 ==")
CB.clear_restriction_zones!()
CB.clear_ood_truth_log!()
nl_far = inject_declared_zone!(env; cx = 99.0, cy = 99.0, r = 0.21, key = :zone_far)
check("6a. 먼 좌표는 nothing 을 돌려준다", nl_far === nothing, "got $(typeof(nl_far))")
check("6b. 그 키가 RESTRICTION_ZONES[] 에 남아 있지 않다",
      !haskey(CB.RESTRICTION_ZONES[], :zone_far))

println()
if FAILED[] == 0
    println("6/6 PASS — 선언적 ForbidZone 주입기 정상")
else
    println("$(FAILED[]) CHECK(S) FAILED")
    exit(1)
end
