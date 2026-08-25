# tools/test_policy_zone.jl
# =============================================================================
# 라이브 정책 레이어(tools/monitor/policy.jl)의 **구역 배선** 자기점검 (2026-08-05, STEP 3·7).
#
# 왜 이 파일이 필요한가
# ---------------------
# policy.jl 은 데모 엔진(run_demo / render_demo)이 함께 쓰는 결정 레이어인데, 그 두 엔진은
# LLM 서비스·MeshCat·전체 시뮬이 다 떠야 돌아간다. 그래서 여기 손을 대면 **아무도 안 돌려보고**
# 다음 데모까지 갔다. 실제로 그 방식으로 회귀가 두 번 났다(2026-08-04 :reform 오분류,
# 2026-08-05 zone 어휘). 이 파일은 서비스도 렌더도 없이 **결정 함수만** 초 단위로 대조한다.
#
# 검사 대상(둘 다 이번 변경분):
#   (1) `valid_macros` — 구역이 assembly 를 지목하지 않아도 **기하가 대상을 알고 있으면**
#       ForbidZone 이 메뉴에 있어야 한다(없으면 정책은 옳은 답을 고를 수조차 없다).
#   (2) `ood_features` — 구역 사건에 기하 **원시값**이 실려야 하고, **판정(verdict)은 없어야** 한다.
#       판정을 주면 정책이 추론이 아니라 답을 읽는다.
#
# 실행:  julia +lts --project=. tools/test_policy_zone.jl
# =============================================================================
using ConstructionBots
# Graphs 는 policy.jl 의 `_agent_pending` 이 쓴다(스크립트라 자기 의존성을 안 들고 온다).
# 데모 엔진(run_demo/render_demo)이 대신 import 해 주고 있었으므로, 여기서도 같이 올려야 한다.
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
# policy.jl 은 모듈이 아니라 스크립트다 -- 포함하는 쪽이 CB 를 정의해 두면 그대로 돈다.
# 라우터는 끈다: 이 파일이 보는 것은 어휘/특징이지 novelty 판정이 아니다.
ENV["DEMO_ROUTER"] = "0"
include(joinpath(@__DIR__, "monitor", "policy.jl"))

# 큰 스택 태스크(빌드 파이프라인이 깊은 재귀를 쓴다). tools/tests.jl 의 것과 동일한 구현.
function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))
    return res[]
end

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 60.0, "mip_rel_gap" => 0.05,
                                          "output_flag" => false, "presolve" => "on")

println(">>> building fast geometry env (tractor, rvo off)...")
pp = CB.get_project_params(4)
env = run_with_stack(2_000_000_000) do
    Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Error))  # 이 레인이 선언한 로그 레벨을 호출 **전에** 심는다 — run_lego_demo 이 반환 시 호출 시점의 로거를 복원하므로(전역 누수 수정), 반환 후 자기 시뮬 루프도 이 레벨로 조용히 돈다.
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Error,
        rvo_flag=false, tangent_bug_flag=false, dispersion_flag=false,
        open_animation_at_end=false, save_animation=false, write_results=false,
        overwrite_results=false, look_for_previous_milp_solution=false,
        save_milp_solution=false, return_env_before_sim=true)
end

gs = CB.root_deposit_goals(env)
zc = isempty(gs) ? [1.5, 0.96] : sum(gs) ./ length(gs)
CB.clear_restriction_zones!()
CB.add_restriction_zone!(:zone, zc, 2.5)          # 빌드 한복판 = 옮길 조립체가 실재하는 구역
CB.add_restriction_zone!(:faraway, [500.0, 500.0], 1.0)   # 아무것도 안 덮는 구역

println("\n== 1. valid_macros — zone 은 LLM 결정 레인에서 빠졌다 (2026-08-24, spec §5.1) ==")
# 🔴 이 절은 2026-08-24 에 **뒤집혔다.** 원래 검사는 "지목이 없어도 기하가 대상을 알면 ForbidZone
# 이 메뉴에 있어야 한다" 였다(2026-08-05, STEP 7). zone 이 결정 레인에서 빠지면서 그 규칙 자체가
# 없어졌으므로, 지금 재는 것은 그 반대다: **기하가 무엇을 알든 zone 메뉴는 비어 있다.**
# 절을 지우지 않고 뒤집는 이유는 지운 규칙이 조용히 되살아나는 것을 여기서 잡기 위해서다.
# ZoneTruth(zone, center, radius, assembly). assembly=nothing = 지목 없음(중앙 core zone 이 그렇다).
t_named   = CB.ZoneTruth(:zone, Vector{Float64}(zc), 2.5, first(CB.zone_blocked_assemblies(env)))
t_unnamed = CB.ZoneTruth(:zone, Vector{Float64}(zc), 2.5, nothing)
t_far     = CB.ZoneTruth(:faraway, [500.0, 500.0], 1.0, nothing)

dom  = CB.zone_diagnosis(env, :zone).n_restage_feasible
domf = CB.zone_diagnosis(env, :faraway).n_restage_feasible
println("    도메인: :zone -> $(dom) 개 옮길 수 있음 / :faraway -> $(domf) 개")
# 🔴 이 두 줄이 아래 "비었다" 를 항진명제에서 구해 준다: 기하는 여전히 옮길 대상을 알고 있는데도
# 메뉴가 비었다는 뜻이 되어야 하고, "구역이 죽어서 비었다" 가 아니어야 한다.
check("사전조건: 중앙 구역은 도메인이 비어 있지 않다", dom > 0)
check("사전조건: 먼 구역은 도메인이 비었다", domf == 0)

vm_named   = valid_macros(env, t_named)
vm_unnamed = valid_macros(env, t_unnamed)
vm_far     = valid_macros(env, t_far)
println("    named   -> $(vm_named)")
println("    unnamed -> $(vm_unnamed)")
println("    faraway -> $(vm_far)")
check("지목이 있어도 zone 메뉴는 비었다(도메인 $(dom) 개인데도)", isempty(vm_named))
check("지목이 없어도 zone 메뉴는 비었다", isempty(vm_unnamed))
check("아무것도 안 덮는 구역도 비었다", isempty(vm_far))
check("삭제된 두 이름은 어느 zone 메뉴에도 없다",
      all(v -> !("ForbidZone" in v) && !("RelocateBuild" in v), (vm_named, vm_unnamed, vm_far)))
# ★ 음성 대조. 위 셋은 `valid_macros(env, _) = String[]` 이라는 상수 구현으로도 통과한다.
# battery 는 여전히 상태를 보고 메뉴를 만들어야 한다 — 그것이 이 함수가 남아 있는 이유다.
vm_batt = valid_macros(env, CB.BatteryTruth(CB.RobotID(1), 0.02))
println("    battery -> $(vm_batt)")
check("음성 대조: battery 메뉴는 비지 않는다", !isempty(vm_batt), "got=$(vm_batt)")
check("음성 대조: battery 메뉴에 Replace 가 있다", "Replace" in vm_batt, "got=$(vm_batt)")

println("\n== 2. ood_features — 원시값은 싣고 판정은 싣지 않는다 ==")
f = ood_features(env, t_unnamed)
prims = ["zone_blocked", "zone_restage_feasible", "zone_root_covered", "zone_root_total",
         "zone_work_overlap", "zone_teams_forming", "zone_teams_covered",
         "zone_relocatable", "zone_relocate_norm"]
for k in prims
    check("원시값 $(k) 존재", haskey(f, k), "keys=$(sort(collect(keys(f))))")
end
println("    -> blocked=$(get(f,"zone_blocked",nothing)) feasible=$(get(f,"zone_restage_feasible",nothing)) " *
        "root=$(get(f,"zone_root_covered",nothing))/$(get(f,"zone_root_total",nothing)) " *
        "teams=$(get(f,"zone_teams_covered",nothing))/$(get(f,"zone_teams_forming",nothing)) " *
        "reloc=$(get(f,"zone_relocatable",nothing)) |Δ|=$(get(f,"zone_relocate_norm",nothing))")
# ★ 판정 누출 검사. 값이든 키든 최소수복 판정이 특징에 섞이면 안 된다.
leaked = [k for (k, v) in f if occursin("verdict", lowercase(String(k))) ||
                               (v isa Symbol && String(v) in ("forbid_zone", "relocate_build", "line_stop", "noop")) ||
                               (v isa AbstractString && String(v) in ("forbid_zone", "relocate_build", "line_stop"))]
check("판정(verdict)이 특징에 새지 않는다", isempty(leaked), "leaked=$(leaked)")
check("기존 열도 그대로", haskey(f, "zone_overlap") && haskey(f, "severity") && haskey(f, "kind"))

# 비공간 사건에는 원시값이 붙지 않아야 한다(기존 입력과 동일해야 하므로).
f_fault = ood_features(env, CB.FaultTruth(CB.RobotID(1), [0.0, 0.0]))
check("fault 사건에는 zone 원시값이 없다", !any(k -> haskey(f_fault, k), prims))

CB.clear_restriction_zones!()
println("\n==== policy zone wiring: $(npass) passed, $(nfail) failed ====")
println(nfail == 0 ? "ALL GREEN" : "SOME FAILED")
