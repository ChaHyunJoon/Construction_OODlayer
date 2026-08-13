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
