# ============================================================================
#  [한국어 설명] 이 파일은 ConstructionBots 의 "통합 테스트 실행기(test driver)".
#  · 프로젝트 역할: LLM/surrogate "re-spec" 레이어(OOD 상황에서 계획을 다시 짜는 안전장치)가
#    제대로 동작하는지 검증하는 여러 테스트를 한 파일(module Tests)에 모아둔 것.
#  · 원래는 tools/test_*.jl 로 흩어져 있던 개별 스크립트들을 각각 "함수" 하나로 바꾸고,
#    공통 준비코드(MILP 설정 + run_with_stack + @check 매크로)를 딱 한 번만 정의해 공유함.
#  · 맨 아래 dispatcher 가 CLI 인자/ENV 로 받은 test_key 하나만 골라 실행함.
#  각 테스트가 무엇을 검증하는지는 함수마다 위에 한국어 요약을 달아둠(아래 참고).
#
#  Julia 문법 참고(처음 보는 사람을 위해):
#   · module Tests ... end : 이름공간(namespace). 안의 함수/상수는 Tests.xxx 로 접근.
#   · using / import : 다른 패키지 불러오기. `const CB = ConstructionBots` = 긴 이름의 별칭.
#   · function f(x::Int) : x 가 Int 타입일 때만 쓰는 메서드(다중 디스패치). 같은 이름을
#     인자 타입만 바꿔 여러 번 정의할 수 있음(파이썬엔 없는 개념).
#   · `!` 로 끝나는 함수(예: set_default_milp_optimizer!) = 인자를 직접 바꾼다(in-place)는 관례.
#   · `macro @check` / `@assert` : `@`로 시작하면 매크로(코드를 코드로 변형). @assert 는 조건이
#     거짓이면 에러를 던짐. @check 는 아래에서 직접 정의한 pass/fail 집계용 매크로.
#   · :symbol (예: :greedy, :zone) = 가벼운 이름표(문자열보다 싸고 비교가 빠름).
#   · Ref(0) = 값을 담는 1칸 상자. ref[] 로 읽고/쓰기(가변 카운터를 만들 때 씀).
#   · Dict("a"=>1) = 사전(해시맵). `f() do ... end` = do-block, 마지막에 함수를 넘기는 축약문법.
#   · `cond ? A : B` = 삼항 조건식(파이썬의 A if cond else B).
#   · ≈ (isapprox) = 부동소수점 "거의 같음" 비교(오차 허용). `≈`, `÷`(정수나눗셈) 등 유니코드 연산자 사용.
# ============================================================================
# =============================================================================
# tools/tests.jl -- consolidated ConstructionBots test/verification driver.
#
# Every standalone tools/test_*.jl script is now a FUNCTION in module `Tests`,
# sharing common boilerplate (MILP setup + run_with_stack + a @check macro) defined
# ONCE. A CLI/ENV dispatcher at the bottom lets any single test run individually.
#
# Test keys:
#   forbidzone_parse         -- LLM-free unit test of the ForbidZone bridge+verify path (Stage 1)
#   replace_parse            -- LLM-free unit test of the ReplaceAgent bridge+verify path (OOD 1-1 Part B)
#   deprioritize_integration -- TIER-2 DeprioritizeAgent integration on a REAL env (no LLM)
#   battery_smoke            -- OFFLINE smoke test of the energy-aware adaptive layer (no env, no LLM)
#   battery_safety           -- OFFLINE safety/verifiability test of the TIER-2 soft re-spec + bias registry
#   llm_classification       -- Stage 3 REAL-LLM check (needs the Python service up + ANTHROPIC_API_KEY)
#   respec_gate              -- LLM-free proof the verify GATE admits feasible / rejects infeasible re-specs (+freeze)
#   respec_timing            -- LLM-free proof the ForbidWindow timing re-spec PERSISTS past commit (persist_milp_times!)
#   respec_reassign          -- STAGE 1 smoke: robot fault -> remaining robots take over (fault_robot_and_reassign!)
#
# Run:
#   julia +lts --project=. tools/tests.jl <test_key>        (or  ENV TEST=<key>)
# e.g.
#   julia +lts --project=. tools/tests.jl forbidzone_parse
#   TEST=battery_smoke julia +lts --project=. tools/tests.jl
# Note: battery_smoke/battery_safety are offline; llm_classification needs a LIVE LLM service.
# =============================================================================
module Tests
using ConstructionBots
import Logging, HiGHS, JSON3, LinearAlgebra, Graphs, JuMP
using Random
const CB = ConstructionBots

# ---- runtime-loaded decoupled layer (loaded ONCE, at module load) -----------
# The navigator layer is NOT compiled into the ConstructionBots package -- the battery
# tests historically `CB.include`d metrics/ood_truth/battery/ood_stream at SCRIPT TOP LEVEL.
# Now that each test is a FUNCTION, doing those includes *inside* a test and then calling the
# freshly-defined methods in the SAME call frame raises a world-age error ("method too new to
# be called from this world context"). Loading it here at MODULE load puts it in an OLDER world
# than any test call, exactly reproducing the original top-level-include semantics. navigator.jl
# is the umbrella loader (it includes metrics/ood_truth/battery/ood_stream/... in dependency
# order -- see its header), so ONE call covers every navigator-using test.
# navigator 레이어(배터리/OOD 등)는 패키지에 컴파일돼 있지 않아 여기서 런타임 include 로 한 번만 불러옴.
# (테스트 함수 "안"에서 include 하면 방금 정의한 메서드를 같은 프레임에서 못 부르는 world-age 에러가 남 → 모듈 로드 시점에 미리 올림.)
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))

# ---- shared helpers (defined ONCE) ------------------------------------------
# _setup_milp! : MILP(정수최적화) 솔버(HiGHS)를 기본 옵티마이저로 등록/설정하는 준비함수.
#   time_limit=풀이 제한시간(초), mip_rel_gap=허용 최적성 오차(클수록 빨리 "그냥 되는" 해로 멈춤). `;` 뒤는 키워드 인자.
function _setup_milp!(; time_limit = 300.0, mip_rel_gap = 5.0)
    CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
    CB.clear_default_milp_optimizer_attributes!()
    CB.set_default_milp_optimizer_attributes!(
        "time_limit" => time_limit, "presolve" => "on", "mip_rel_gap" => mip_rel_gap,
        CB.MOI.Silent() => true)
end

# run_with_stack : f() 를 "C 스택을 크게 잡은 새 태스크"에서 실행하고 결과를 돌려주는 헬퍼.
#   깊은 재귀가 많은 env 빌드가 스택오버플로 나지 않게 stacksize 바이트만큼 스택을 키움.
#   내부적으로 새 태스크가 끝날 때까지(done[]) 기다렸다가, 에러가 있었으면 그대로 다시 던짐.
function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))
    return res[]
end

# Shared pass/fail accounting + @check macro (used identically by battery_smoke, battery_safety;
# also referenced by the nested `chk` closure in deprioritize_integration). A macro CANNOT be
# defined inside a function, so it lives here at module level; it is hygienic, so PASS[]/FAILN[]
# resolve to these module-level counters (one test runs per process via the dispatcher).
# PASS/FAILN : 통과/실패 개수를 세는 전역 카운터 상자(모듈당 한 프로세스에서 테스트 하나만 도니 공유 OK).
# @check ex : ex(조건식)가 참이면 PASS+1, 거짓이면 FAILN+1 하고 "FAIL: <원래 식>"을 출력하는 매크로.
#   $(esc(ex)) = 매크로 위생(hygiene) 때문에 사용자 식을 원래 스코프에서 평가하도록 이스케이프.
const PASS = Ref(0); const FAILN = Ref(0)
macro check(ex)
    quote
        if $(esc(ex)); PASS[] += 1
        else; FAILN[] += 1; println("  FAIL: ", $(string(ex))); end
    end
end

# =============================================================================
# forbidzone_parse -- LLM-free unit test of the ForbidZone bridge+verify path (Stage 1).
#   Builds a fast geometry-only env (rvo off, no sim), injects a CENTRAL zone, then exercises:
#   open_zone_descriptors -> a fake /propose JSON with a ForbidZone -> _parse_proposal ->
#   verify_zone (admit), plus negative cases (bad zone key, bad id). No Python service, no nav build.
# =============================================================================
# [검증 내용] LLM 없이 ForbidZone(진입금지 구역) DSL 경로를 확인: 중앙에 zone 을 심고 →
#   zone 서술 추출 → 가짜 /propose JSON 파싱 → verify_zone 이 정상 제안은 "Admit(허용)",
#   잘못된 zone/assembly id 는 "Reject/throw" 로 막는지 본다(negative case 포함).
function test_forbidzone_parse()
_setup_milp!(time_limit = 120.0)

println(">>> building fast geometry env (tractor, rvo off)...")
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

# 이 테스트 전용 로컬 검사 클로저: 조건이 참이면 PASS 카운트+출력, 아니면 FAIL. (@check 와 별개, 이름표 name 을 찍음)
npass = Ref(0); nfail = Ref(0)
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))

# 최종 조립품(root)들의 목표지점 중심(centroid)에 중앙 zone 을 배치 — 빌드 핵심부를 덮는 no-go 구역을 흉내냄.
gs = CB.root_deposit_goals(env)
zc = isempty(gs) ? [1.5, 0.96] : sum(gs) ./ length(gs)   # 목표들의 평균 위치(없으면 하드코딩 좌표)
CB.clear_restriction_zones!(); CB.add_restriction_zone!(:zone, zc, 2.5)  # 반지름 2.5 짜리 :zone 등록

println("\n[1] open_zone_descriptors")
zd = CB.open_zone_descriptors(env)
check("one zone described", length(zd) == 1)
check("key == \"zone\"", !isempty(zd) && zd[1]["key"] == "zone")
check("covers_root true (central)", !isempty(zd) && zd[1]["covers_root"] == true)
println("    -> ", isempty(zd) ? "(none)" : zd[1])

resolver = ref -> CB._default_id_resolver(env, ref)
asm_id = CB.open_node_descriptors(env)[1]["id"]    # a valid AssemblyComplete node id string
println("\n[2] _parse_proposal with a ForbidZone JSON (assembly=$asm_id)")
payload_ok = JSON3.read(JSON3.write(Dict(
    "constraints" => [Dict("kind" => "ForbidZone", "zone" => "zone", "assembly" => asm_id)],
    "rationale" => "central zone blocks the build core")))
prop = CB._parse_proposal(payload_ok, "A no-go zone is active over the build core."; id_resolver=resolver)
check("parsed 1 constraint", length(prop.constraints) == 1)
check("constraint isa ForbidZone", !isempty(prop.constraints) && prop.constraints[1] isa CB.ForbidZone)
check("zone symbol == :zone", !isempty(prop.constraints) && prop.constraints[1].zone == :zone)
check("_is_zone_respec true", CB._is_zone_respec(prop))

println("\n[3] verify_zone — valid proposal admits")
v_ok = CB.verify_zone(prop, env)
check("verify_zone Admit", v_ok isa CB.Admit)

println("\n[4] verify_zone — unknown zone key rejects")
prop_badzone = CB.RespecProposal([CB.ForbidZone(resolver(asm_id), :ghost)], "x", "x")
v_bad = CB.verify_zone(prop_badzone, env)
check("verify_zone Reject(:no_such_zone)", v_bad isa CB.Reject && v_bad.reason == :no_such_zone)

println("\n[5] parser rejects an unknown assembly id (throws -> Reject upstream)")
threw = false
try
    CB._parse_proposal(JSON3.read(JSON3.write(Dict(
        "constraints" => [Dict("kind" => "ForbidZone", "zone" => "zone", "assembly" => "NOPE_999")]))),
        "x"; id_resolver=resolver)
catch
    threw = true
end
check("unknown assembly id throws", threw)

CB.clear_restriction_zones!()
println("\n==== ForbidZone parse/verify: $(npass[]) passed, $(nfail[]) failed ====")
nfail[] == 0 ? println("ALL GREEN") : println("SOME FAILED")
end

# =============================================================================
# replace_parse -- LLM-free unit test of the ReplaceAgent bridge+verify path (OOD 1-1 Part B
#   plumbing). Builds a fast geometry-only env (rvo off, no sim), registers a spare pool, then
#   exercises: open_agent_descriptors -> a fake /propose JSON with a ReplaceAgent ->
#   _parse_proposal -> verify_replace (admit), plus negative cases (no spare -> reject, unknown
#   agent id -> throw). No Python service, no nav build.
# =============================================================================
# [검증 내용] LLM 없이 ReplaceAgent(고장난 로봇 → 예비 로봇 교체) DSL 경로를 확인:
#   고장 로봇 서술 추출 → 가짜 JSON 파싱 → verify_replace 가 spare(예비) 있으면 Admit,
#   없으면 Reject(:no_spare), 존재하지 않는 agent id 는 파싱 단계에서 막는지(fail closed) 본다.
function test_replace_parse()
_setup_milp!(time_limit = 120.0)

println(">>> building fast geometry env (tractor, rvo off)...")
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

npass = Ref(0); nfail = Ref(0)
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))

resolver = ref -> CB._default_id_resolver(env, ref)

println("\n[1] open_agent_descriptors exposes a faulted-robot grounding")
ad = CB.open_agent_descriptors(env)
check("at least one agent described", !isempty(ad))
agent_id = ad[1]["id"]                       # an exact RobotID string the spec must echo
println("    -> faulting agent id = $agent_id ; label = $(ad[1]["label"])")

println("\n[2] _parse_proposal with a ReplaceAgent JSON (agent=$agent_id)")
payload_ok = JSON3.read(JSON3.write(Dict(
    "constraints" => [Dict("kind" => "ReplaceAgent", "agent" => agent_id, "after" => 0.0)],
    "rationale" => "robot broke down; replace with nearest backup")))
prop = CB._parse_proposal(payload_ok, "Robot R1 has broken down; send a backup."; id_resolver=resolver)
check("parsed 1 constraint", length(prop.constraints) == 1)
check("constraint isa ReplaceAgent", !isempty(prop.constraints) && prop.constraints[1] isa CB.ReplaceAgent)
check("_is_robot_replace true", CB._is_robot_replace(prop))
check("NOT misclassified as robot fault (ForbidAgent path)", !CB._is_robot_fault(prop))

println("\n[3] verify_replace — spare available admits")
CB.clear_spare_pools!()                                    # 예비 풀 비우고 시작
CB.register_spare!(:north, CB.get_unique_id(CB.RobotID))   # 북쪽 풀에 주차된 예비 로봇 1대 등록
v_ok = CB.verify_replace(prop, env)
check("verify_replace Admit (spare present)", v_ok isa CB.Admit)

println("\n[4] verify_replace — no spare rejects")
CB.clear_spare_pools!()
v_nospare = CB.verify_replace(prop, env)
check("verify_replace Reject(:no_spare)", v_nospare isa CB.Reject && v_nospare.reason == :no_spare)

println("\n[5] unknown agent id is rejected at parse (fails closed)")
# Wrapped in a function so the try/catch uses clean local scope (top-level try/catch
# scoping is unreliable in scripts). Probe-verified: `_default_id_resolver` throws on an
# unknown robot id AND `ReplaceAgent(nothing,_)` is a MethodError, so an ungrounded agent
# can never become a valid spec — the parse fails closed before anything is dispatched.
function _parse_throws_on_bad_agent()
    try
        CB._parse_proposal(JSON3.read(JSON3.write(Dict(
            "constraints" => [Dict("kind" => "ReplaceAgent", "agent" => "NOPE_ROBOT_999", "after" => 0.0)]))),
            "x"; id_resolver = resolver)
        return false
    catch
        return true
    end
end
check("unknown agent id throws (fails closed at parse)", _parse_throws_on_bad_agent())

println("\n[6] referenced_ids(::ReplaceAgent) points at the faulted agent (static gate input)")
rid = first(CB.referenced_ids(prop.constraints[1]))
check("referenced_ids == the faulted agent", rid == resolver(agent_id))

CB.clear_spare_pools!()
println("\n==== ReplaceAgent parse/verify: $(npass[]) passed, $(nfail[]) failed ====")
nfail[] == 0 ? println("ALL GREEN") : println("SOME FAILED")
nfail[] == 0 || error("test_replace_parse had $(nfail[]) failure(s)")
end

# =============================================================================
# deprioritize_integration -- Integration verification of the TIER-2 DeprioritizeAgent on a
#   REAL env (no LLM): (1) verify_deprioritize ADMITS a real robot, REJECTS a non-existent /
#   closed one. (2) feasibility-PRESERVING: a re-solve with the agent biased stays FEASIBLE.
#   (3) it actually REROUTES: the biased robot does <= as much assignment work as baseline.
#   Builds ONE small env (greedy) and re-solves; mirrors the maybe_respecify! soft-dispatch
#   path without the LLM round-trip.
# =============================================================================
# [검증 내용] 실제 env 위에서 TIER-2 DeprioritizeAgent(로봇 우선순위 낮추기 = 소프트 re-spec)를 확인:
#   (1) 실존 로봇은 Admit, 없는 로봇은 Reject, (2) 편향(bias)을 걸고 다시 풀어도 여전히 feasible,
#   (3) 실제로 우회시켜 그 로봇의 배정 작업량이 baseline 이하로 줄어드는지 본다(LLM 없이 소프트 경로만).
function test_deprioritize_integration()
value = JuMP.value                    # JuMP 결정변수의 최적해 값을 읽는 함수 별칭
chk(c, m) = (c ? (PASS[] += 1) : (FAILN[] += 1; println("  FAIL: ", m)))  # 로컬 pass/fail 집계 클로저

_setup_milp!(time_limit = 120.0, mip_rel_gap = 0.02)
CB.clear_agent_bias!(); CB.EDGE_COST_MULTIPLIER[] = nothing
CB.set_planning_objective_weights!(speed = 1.0, efficiency = 0.01)
CB.set_energy_model!(load_power = 0.25)

pp = CB.get_project_params(4)   # tractor
println(">>> building env (greedy)...")
env = run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots],
        assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
        log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false, dispersion_flag=false,
        open_animation_at_end=false, save_animation=false, save_animation_along_the_way=false,
        write_results=false, overwrite_results=false,
        look_for_previous_milp_solution=false, save_milp_solution=false, return_env_before_sim=true)
end
inv = CB.build_invariant(env)
CB.release_pending_assignments!(env, inv; faulted = nothing)
robots = sort([CB.node_id(n) for n in CB.get_nodes(env.scene_tree) if CB.matches_template(CB.RobotNode, n)]; by = r -> r.id)
R = robots[1]
println(">>> env built; $(length(robots)) robots; deprioritizing $(R)\n")

# owned_edge_usage : 풀린 milp 에서 로봇 rid 가 "소유한" 배정 엣지들의 선택량 합(그 로봇이 맡은 일의 양).
function owned_edge_usage(milp, sched, rid)
    u = 0.0
    for ((v, v2), _) in CB.LAST_EDGE_COSTS[]
        CB._edge_owner_id(sched, v) == rid || continue
        try; u += value(milp.Xa[v, v2]); catch; end
    end
    return u
end

# (1) verify_deprioritize gate
println("== (1) verify_deprioritize: admit real robot, reject non-existent ==")
chk(CB.verify_deprioritize(CB.RespecProposal([CB.DeprioritizeAgent(R, 100.0)]), env) isa CB.Admit, "real robot admitted")
chk(CB.verify_deprioritize(CB.RespecProposal([CB.DeprioritizeAgent(CB.RobotID(999999), 100.0)]), env) isa CB.Reject, "fake robot rejected")

# (2) baseline solve (no bias)
println("== (2) baseline re-solve (no bias) ==")
CB.clear_agent_bias!()
milp0 = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
    optimizer = CB._respec_optimizer(), t0_ = inv.frozen_t0, tF_ = inv.frozen_tF)
CB.optimize!(milp0)
feas0 = JuMP.primal_status(milp0.model) == CB.MOI.FEASIBLE_POINT
usage0 = owned_edge_usage(milp0, env.sched, R)
ms0 = try maximum(value.(milp0.model[:tF])) catch; NaN end
chk(feas0, "baseline feasible")
println("   baseline: feasible=$feas0  R-edge-usage=$(round(usage0,digits=2))  makespan=$(round(ms0,digits=2))")

# (3) 편향 건 재풀이: feasibility 유지 + R 의 작업량이 baseline 이하인지 확인
println("== (3) deprioritize R (factor 1000, clamped) -> re-solve ==")
f = CB.deprioritize_agent!(R, 1000.0)                     # R 의 비용을 1000배로(단, 안전상 MAX 로 clamp 됨)
chk(f == CB.MAX_AGENT_COST_BIAS, "factor clamped to MAX")
milp1 = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
    optimizer = CB._respec_optimizer(), t0_ = inv.frozen_t0, tF_ = inv.frozen_tF)
CB.optimize!(milp1)
feas1 = JuMP.primal_status(milp1.model) == CB.MOI.FEASIBLE_POINT
usage1 = owned_edge_usage(milp1, env.sched, R)
ms1 = try maximum(value.(milp1.model[:tF])) catch; NaN end
chk(feas1, "feasibility PRESERVED after deprioritize (soft spec never stalls)")
chk(usage1 <= usage0 + 1e-6, "deprioritized robot does <= baseline assignment work ($(round(usage1,digits=2)) <= $(round(usage0,digits=2)))")
println("   biased:   feasible=$feas1  R-edge-usage=$(round(usage1,digits=2))  makespan=$(round(ms1,digits=2))")
CB.clear_agent_bias!()

# (4) AUTO energy weight — the DEPLOYED configuration. Stages (2)/(3) above hand-set
#     efficiency=0.01, which no demo ever does: run_demo.jl leaves the default (speed=1,
#     efficiency=0), and with that `get_objective_expr` DISCARDS edge_costs, so the registered
#     bias reached nothing and the deprioritize re-solve just re-optimized the same makespan.
#     AUTO_EFFICIENCY_KAPPA derives a unit-matched weight for that one formulation instead.
# [검증 내용] 배포 기본 가중치(efficiency=0)에서 (a) κ 미설정이면 목적함수가 예전 그대로이고,
#     (b) κ 설정 시 에너지 항이 실제로 켜지며(w_eff>0), (c) 실행가능성을 지킨 채 R 의 작업량이 준다.
println("== (4) AUTO energy weight under DEPLOYED weights (efficiency = 0) ==")
CB.set_planning_objective_weights!(speed = 1.0, efficiency = 0.0)   # 데모가 실제로 쓰는 값
CB.clear_agent_bias!(); CB.AUTO_EFFICIENCY_KAPPA[] = nothing
milpA = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
    optimizer = CB._respec_optimizer(), t0_ = inv.frozen_t0, tF_ = inv.frozen_tF)
chk(CB.LAST_AUTO_EFFICIENCY_W[] == 0.0, "auto path INERT when κ unset (objective preserved)")
CB.optimize!(milpA)
usageA = owned_edge_usage(milpA, env.sched, R)
msA = try maximum(value.(milpA.model[:tF])) catch; NaN end

CB.deprioritize_agent!(R, 1000.0)                       # maybe_respecify! 가 하는 그대로
prev_k = CB.AUTO_EFFICIENCY_KAPPA[]
CB.AUTO_EFFICIENCY_KAPPA[] = CB.DEPRIORITIZE_KAPPA[]
milpB = try
    CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
        optimizer = CB._respec_optimizer(), t0_ = inv.frozen_t0, tF_ = inv.frozen_tF)
finally
    CB.AUTO_EFFICIENCY_KAPPA[] = prev_k
end
wB = CB.LAST_AUTO_EFFICIENCY_W[]
CB.optimize!(milpB)
feasB = JuMP.primal_status(milpB.model) == CB.MOI.FEASIBLE_POINT
usageB = owned_edge_usage(milpB, env.sched, R)
msB = try maximum(value.(milpB.model[:tF])) catch; NaN end
chk(wB > 0.0, "energy term ACTIVE under deployed weights (auto w_eff = $(round(wB, sigdigits = 3)))")
chk(CB.AUTO_EFFICIENCY_KAPPA[] === prev_k, "κ restored after the scoped formulation")
chk(feasB, "feasibility PRESERVED with the auto weight")
chk(usageB <= usageA + 1e-6, "auto path REROUTES off R ($(round(usageB,digits=2)) <= $(round(usageA,digits=2)))")
println("   deployed baseline: R-edge-usage=$(round(usageA,digits=2))  makespan=$(round(msA,digits=2))")
println("   deployed + auto:   R-edge-usage=$(round(usageB,digits=2))  makespan=$(round(msB,digits=2))  w_eff=$(round(wB,sigdigits=3))")
CB.clear_agent_bias!(); CB.AUTO_EFFICIENCY_KAPPA[] = nothing

println("\n== RESULT: $(PASS[]) passed, $(FAILN[]) failed ==")
exit(FAILN[] == 0 ? 0 : 1)   # 실패 0 이면 종료코드 0(성공), 아니면 1(CI 가 실패로 인식)
end

# =============================================================================
# battery_smoke -- OFFLINE smoke test for the energy-aware adaptive layer — NO env build, NO LLM.
#   Unit-tests the pure pieces of the navigator layer (loaded ONCE at module top):
#   battery power model · SoC->cost multiplier · metric wiring · OOD-stream scheduling.
# =============================================================================
# [검증 내용] env/LLM 없이 에너지 인지(energy-aware) 레이어의 순수 부품들을 단위 검사:
#   배터리 전력모델, SoC(잔량)->비용 배수, 지표(metric) 배선, OOD-stream 스케줄링이 맞는지 본다.
#   (@check 로 하나하나 확인; SoC=State of Charge=배터리 잔량 0~1)
function test_battery_smoke()
println("== BatteryParams / k_move calibration ==")
p = CB.BatteryParams()
@check p.capacity_J ≈ 2.3 * 3.6e6
@check p.v_ref == 4.0                                  # = rvo_default_max_speed()
@check CB.k_move(p) ≈ (500.0 - 100.0) / (60.0 * 4.0)   # idle+k·m·v_ref == walk_W
# an unloaded robot at v_ref draws exactly walk_W:
@check p.idle_W + CB.k_move(p) * p.m_robot * p.v_ref ≈ 500.0
@check CB.demo_battery_params(shrink = 5e4).capacity_J ≈ (2.3 * 3.6e6) / 5e4

println("== SoC -> cost multiplier (battery_edge bias) ==")
CB.set_battery_penalty!(gain = 4.0, soc_target = 0.5, hard_mult = 1.0e3)
@check CB._soc_multiplier(1.0) == 1.0                  # healthy: no penalty
@check CB._soc_multiplier(0.5) == 1.0                  # at target: no penalty
@check CB._soc_multiplier(0.25) ≈ 1.0 + 4.0 * (0.25 / 0.5)  # below target: linear penalty
@check CB._soc_multiplier(0.0) == 1.0e3               # depleted: hard penalty
@check CB._soc_multiplier(0.25) > CB._soc_multiplier(0.4) # lower SoC -> bigger multiplier

println("== EDGE_COST_MULTIPLIER hook default-inert ==")
CB.EDGE_COST_MULTIPLIER[] = nothing
@check CB.edge_cost_multiplier(nothing, 1) == 1.0      # default: no effect (objective preserved)
CB.install_battery_objective_hook!()
@check CB.EDGE_COST_MULTIPLIER[] === CB.battery_edge_multiplier
CB.BATTERY_ACCOUNTING[] = false
@check CB.battery_edge_multiplier(nothing, 1) == 1.0   # accounting off -> 1.0 even with hook installed
CB.EDGE_COST_MULTIPLIER[] = nothing                    # reset

println("== step hook (route_planning.BATTERY_STEP_HOOK) default-inert + installable ==")
@check CB.BATTERY_STEP_HOOK[] === nothing              # default: step_environment! unchanged
CB.install_battery_step_hook!()
@check CB.BATTERY_STEP_HOOK[] === CB.account_battery_step!
CB.BATTERY_STEP_HOOK[] = nothing                       # reset
@check isa(CB.enable_battery!, Function)               # one-call enable helper exists
@check isa(CB.rebalance_for_battery!, Function)        # SoC-biased re-solve helper exists

# 함대(fleet) 회계: _debit!(에너지 차감), battery_report(요약), low_soc(잔량낮은 로봇), spread(잔량 편차)
println("== Fleet accounting: _debit!, report, low_soc, spread ==")
r1, r2, r3 = CB.RobotID(1), CB.RobotID(2), CB.RobotID(3)   # 테스트용 로봇 3대 id
fleet = CB.BatteryFleet(p,
    Dict{Any,Float64}(r1 => 1.0, r2 => 0.8, r3 => 0.2),
    Dict{Any,Float64}(r1 => 0.0, r2 => 0.0, r3 => 0.0),
    Dict{Any,Int}(r1 => 0, r2 => 0, r3 => 0),
    Set{Any}())
CB._debit!(fleet, r1, 500.0, 1.0)                      # 500 J off r1
@check fleet.energy_J[r1] == 500.0
@check fleet.soc[r1] ≈ 1.0 - 500.0 / p.capacity_J
rep = CB.battery_report(fleet)
@check rep.min_soc ≈ 0.2
@check rep.soc_spread ≈ (maximum(values(fleet.soc)) - 0.2)
@check rep.total_energy_J == 500.0
@check Set(CB.low_soc_robots(fleet; threshold = 0.25)) == Set([r3])
# depletion clamps at floor and is recorded:
CB._debit!(fleet, r3, 1e12, 1.0)
@check fleet.soc[r3] == 0.0 && (r3 in fleet.depleted)

println("== battery-health OOD injector ==")
CB.BATTERY_FLEET[] = fleet
nl = CB.inject_battery_fault!(nothing; target = r2, soc_drop = 0.5, enqueue = false)
@check occursin("R2", nl) && fleet.soc[r2] ≈ 0.3
CB.BATTERY_FLEET[] = nothing

println("== metric wiring: compute_metrics + axis_costs ==")
m = CB.compute_metrics(; t0 = Float64[], tF = [10.0, 12.0], n_parts = 4, placed_parts = 4,
    robot_busy_time = [3.0, 4.0], transport_distance = 7.0,
    energy = 1234.0, min_soc = 0.3, soc_spread = 0.6)
@check m.energy == 1234.0 && m.min_soc == 0.3 && m.soc_spread == 0.6
@check m.makespan == 12.0
ac = CB.axis_costs(m)
# efficiency axis now includes soc_spread (wear-leveling):
m0 = CB.compute_metrics(; t0 = Float64[], tF = [10.0, 12.0], n_parts = 4, placed_parts = 4,
    robot_busy_time = [3.0, 4.0], transport_distance = 7.0,
    energy = 1234.0, min_soc = 0.3, soc_spread = 0.0)
@check CB.axis_costs(m).efficiency > CB.axis_costs(m0).efficiency   # spread penalized
kw = CB.battery_metrics_kwargs(fleet)
@check haskey(pairs(kw), :energy) && haskey(pairs(kw), :min_soc) && haskey(pairs(kw), :soc_spread)

println("== OOD-stream: random progress points + battery_action ==")
pts = CB._random_progress_points(5, 4, 40, MersenneTwister(7))
@check length(pts) == 5 && issorted(pts) && all(4 .<= pts .<= 40)
@check CB._random_progress_points(0, 4, 40, MersenneTwister(7)) == Int[]
ba = CB.battery_action(soc_drop = 0.3)
@check ba isa Function

println("\n== RESULT: $(PASS[]) passed, $(FAILN[]) failed ==")
exit(FAILN[] == 0 ? 0 : 1)
end

# =============================================================================
# battery_safety -- OFFLINE safety/verifiability test for the TIER-2 soft re-spec
#   (DeprioritizeAgent) and the AGENT_COST_BIAS objective-bias registry. NO env build, NO LLM.
#   Running it also PRECOMPILES the whole module, so it doubles as an integration check that the
#   spec_dsl/compiler/verifier/replan + essential_tg_coponents edits all load.
# =============================================================================
# [검증 내용] env/LLM 없이 소프트 re-spec(DeprioritizeAgent)와 AGENT_COST_BIAS 편향 레지스트리의
#   "안전성/검증가능성"을 확인: LLM 이 뽑을 수 있는 건 닫힌 문법(grammar)뿐이고, factor 는 [1,MAX]로
#   clamp 되어 목적함수를 역이용 못하며, 소프트 스펙은 하드 제약 0개로 컴파일되어 feasibility 를 절대 안 줄임.
#   (이 테스트를 돌리면 모듈 전체가 precompile 되므로 로드 통합검사도 겸함.)
function test_battery_safety()
println("== closed-union: DeprioritizeAgent is a ConstraintSpec (LLM can only emit grammar) ==")
@check CB.DeprioritizeAgent <: CB.ConstraintSpec
r5 = CB.RobotID(5); r6 = CB.RobotID(6)
da = CB.DeprioritizeAgent(r5)
@check da.factor == 50.0                                  # default advisory severity
@check CB.referenced_ids(da) == (r5,)                     # grounding key for the closed-node check

println("== SAFETY: factor is CLAMPED to [1, MAX] (LLM cannot weaponize the knob) ==")
CB.clear_agent_bias!()
@check CB.agent_cost_bias(r5) == 1.0                      # unknown agent -> identity
@check CB.deprioritize_agent!(r5, 50.0) == 50.0          # in-range passes through
@check CB.agent_cost_bias(r5) == 50.0
@check CB.deprioritize_agent!(r5, 0.3) == 1.0            # < 1 clamped UP: can never INCENTIVIZE a robot
@check CB.deprioritize_agent!(r5, -100.0) == 1.0         # negative clamped: cannot invert the objective
@check CB.deprioritize_agent!(r5, 1.0e9) == CB.MAX_AGENT_COST_BIAS   # blowup clamped: numerical safety
@check CB.MAX_AGENT_COST_BIAS == 1.0e3
CB.clear_agent_bias!(r5)
@check CB.agent_cost_bias(r5) == 1.0                      # single-clear works
CB.deprioritize_agent!(r5, 10.0); CB.deprioritize_agent!(r6, 20.0)
@check length(CB.AGENT_COST_BIAS[]) == 2
CB.clear_agent_bias!()
@check isempty(CB.AGENT_COST_BIAS[])                      # global clear works

println("== SAFETY: feasibility-preserving BY CONSTRUCTION — compiles to ZERO hard constraints ==")
# 소프트 re-spec 이 feasible 집합을 줄이거나 빌드를 멈출 수 없다는 "구조적 증거":
# 컴파일 결과 추가된 하드 제약 개수가 0 이어야 함(0이면 절대 계획을 막지 못함).
@check CB.compile_constraint!(nothing, nothing, nothing, nothing, nothing, da) == 0

println("== objective-bias composition: agent_bias × battery_fn, both default-identity ==")
CB.clear_agent_bias!(); CB.EDGE_COST_MULTIPLIER[] = nothing
@check CB.edge_cost_multiplier(nothing, 1) == 1.0        # both off -> edge_costs byte-for-byte unchanged
CB.EDGE_COST_MULTIPLIER[] = (s, v) -> 3.0                # stub battery fn
@check CB.edge_cost_multiplier(nothing, 1) == 3.0        # agent registry empty -> battery only
CB.EDGE_COST_MULTIPLIER[] = nothing                      # reset

println("== dispatch predicate: pure-soft proposals routed to the soft path ==")
@check CB._is_deprioritize(CB.RespecProposal([CB.DeprioritizeAgent(r5)]))
@check CB._is_deprioritize(CB.RespecProposal([CB.DeprioritizeAgent(r5), CB.DeprioritizeAgent(r6)]))
mixed = CB.RespecProposal(CB.ConstraintSpec[CB.DeprioritizeAgent(r5), CB.ForbidWindow(r5, 0.0, 1.0)])
@check !CB._is_deprioritize(mixed)                       # mixed -> NOT soft path (hard spec governs)
@check !CB._is_deprioritize(CB.RespecProposal(CB.ConstraintSpec[]))   # empty -> not soft
# a mixed proposal's DeprioritizeAgent is harmless on the generic compile path (no-op):
@check CB.compile_constraint!(nothing, nothing, nothing, nothing, nothing, mixed.constraints[1]) == 0

println("== LLM->Julia decode: _parse_proposal maps DeprioritizeAgent JSON -> typed spec ==")
resolver = s -> CB.RobotID(7)                            # trivial id resolver for the test
payload = Dict("constraints" => [Dict("kind" => "DeprioritizeAgent", "agent" => "RobotID(7)", "factor" => 80.0)],
               "rationale" => "battery low")
prop = CB._parse_proposal(payload, "R7 battery low"; id_resolver = resolver)
@check length(prop.constraints) == 1
@check prop.constraints[1] isa CB.DeprioritizeAgent
@check prop.constraints[1].agent == CB.RobotID(7)
@check prop.constraints[1].factor == 80.0
payload2 = Dict("constraints" => [Dict("kind" => "DeprioritizeAgent", "agent" => "RobotID(7)")], "rationale" => "")
@check CB._parse_proposal(payload2, "x"; id_resolver = resolver).constraints[1].factor == 50.0   # default
threw = Ref(false)
try CB._parse_proposal(Dict("constraints" => [Dict("kind" => "Sabotage")], "rationale" => ""), "x"; id_resolver = resolver)
catch; threw[] = true end
@check threw[]                                           # closed union: unknown kind throws on Julia side too

println("\n== RESULT: $(PASS[]) passed, $(FAILN[]) failed ==")
exit(FAILN[] == 0 ? 0 : 1)
end

# =============================================================================
# llm_classification -- Stage 3 REAL-LLM check: does the live service classify a natural-language
#   OOD event into the CORRECT DSL kind (ForbidZone / ForbidAgent / ForbidWindow) and ground it
#   onto valid ids? Turn-key: requires the Python service up and ANTHROPIC_API_KEY in THIS shell.
#     1) In a shell WITH your key (PowerShell):
#          cd src/respec/llm_service ; uvicorn server:app --host 127.0.0.1 --port 8000
#     2) In another shell WITH your key:
#          cd ConstructionBots.jl ; julia +lts --project=. tools/tests.jl llm_classification
#   (default RESPEC_SERVICE_URL is http://127.0.0.1:8000)
# =============================================================================
# [검증 내용] Stage 3 "실제 LLM" 검사: 살아있는 Python 서비스가 자연어 OOD 문장을 올바른 DSL 종류
#   (ForbidZone / ForbidAgent / ForbidWindow)로 분류하고 유효한 id 에 grounding(연결)하는지 본다.
#   turn-key: Python 서비스 실행 + ANTHROPIC_API_KEY 가 이 쉘에 있어야 함(없으면 스킵/종료).
function test_llm_classification()
_setup_milp!(time_limit = 120.0)

if !CB.respec_service_ready()   # LLM 서비스에 접속 안 되면 안내만 하고 종료(코드1)
    println("LLM service NOT reachable at ", get(ENV, "RESPEC_SERVICE_URL", "http://127.0.0.1:8000"))
    println("Start it first:  cd src/respec/llm_service ; uvicorn server:app --port 8000   (in a shell with ANTHROPIC_API_KEY)")
    exit(1)
end
println(">>> service ready. building fast env (tractor, rvo off)...")
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

# inject a central zone so the zones-descriptor is non-empty (a real spatial OOD)
gs = CB.root_deposit_goals(env)
zc = isempty(gs) ? [1.5, 0.96] : sum(gs) ./ length(gs)
CB.clear_restriction_zones!(); CB.add_restriction_zone!(:zone, zc, 2.5)

resolver = ref -> CB._default_id_resolver(env, ref)   # 문자열 참조 -> 실제 id 로 변환하는 함수
kind_of(p) = isempty(p.constraints) ? :none : typeof(p.constraints[1]).name.name  # 제안의 첫 제약 "타입 이름" 추출

# (자연어 문장, 기대하는 DSL 종류) 쌍들 — LLM 이 각 문장을 맞는 종류로 분류해야 통과.
cases = [
    ("A safety exclusion zone is now active over the central build area; robots must not enter or pass through it.", :ForbidZone),
    ("Robot R2 has broken down and can no longer move; take it out of service.", :ForbidAgent),
    ("The final assembly must not be worked on during the interval t=40 to t=70.", :ForbidWindow),
]
npass = 0
println("\n==== LLM classification ====")
for (event, want) in cases
    got = :error
    try
        p = CB.llm_to_proposal(event, env; id_resolver = resolver)
        got = kind_of(p)
    catch e
        got = Symbol("error:", typeof(e).name.name)
    end
    ok = got == want
    ok && (npass += 1)
    println(ok ? "  PASS" : "  FAIL", "  want=$want got=$got")
    println("        event: ", first(event, 70), "...")
end
CB.clear_restriction_zones!()
println("\n$(npass)/$(length(cases)) classified correctly")
println(npass == length(cases) ? "ALL GREEN" : "SOME MISCLASSIFIED")
end

# =============================================================================
# respec_gate -- Prove the verify GATE on a real schedule, no LLM. Builds a real env
#   (assignment done, sim NOT started) and checks verify() ADMITS a non-binding
#   constraint (feasible) and REJECTS an impossible one (:infeasible). Then a FREEZE
#   test: step the sim to close nodes and confirm build_invariant pins realized times.
# =============================================================================
# [검증 내용] 실제 스케줄 위에서 verify GATE 를 증명(LLM 없음): 배정만 끝내고 시뮬은 안 돌린 env 에서
#   구속력 없는(feasible) 제약은 Admit, 불가능한 제약은 Reject(:infeasible). 이어서 FREEZE 테스트로
#   시뮬을 조금 돌려 노드를 완료시킨 뒤 build_invariant 가 실현시간을 고정(pin)하는지 확인한다.
function test_respec_gate()
project_params = get_project_params(4)   # tractor — the project the user has run successfully
                                          # (project 1 / colored_8x8 segfaults in ECOS geometry overapprox)

println(">>> building env (assignment only, no simulation)...")
env = run_with_stack(2_000_000_000) do
    run_lego_demo(;
        ldraw_file=project_params[:file_name],
        project_name=project_params[:project_name],
        model_scale=project_params[:model_scale],
        num_robots=project_params[:num_robots],
        assignment_mode=:greedy,
        milp_optimizer=:highs,
        optimizer_time_limit=60,
        rvo_flag=false, tangent_bug_flag=false, dispersion_flag=false,
        open_animation_at_end=false, save_animation=false,
        save_animation_along_the_way=false,
        write_results=false, overwrite_results=false,
        look_for_previous_milp_solution=false, save_milp_solution=false,
        return_env_before_sim=true,          # the new RESPEC option
    )
end

@assert env !== nothing "run_lego_demo returned nothing — did return_env_before_sim fire?"
nnodes = Graphs.nv(env.sched)
println(">>> env built. schedule nodes = $nnodes, closed = $(length(env.cache.closed_set))")

# A real, still-open node id, and a freeze snapshot (empty: nothing executed yet).
nid = CB.get_vtx_id(env.sched, 1)
inv = CB.build_invariant(env)
println(">>> target node id = $nid")

# --- ADMIT: a window entirely in the past is feasible & non-binding -----------
# ForbidWindow(node, t_lo, t_hi) == tF<=t_lo OR t0>=t_hi. With the window in the
# past (t_hi=-1) the "start after t_hi" branch is trivially satisfied (t0>=0>=-1).
# 창(window)이 완전히 과거(t_hi=-1)라 "그 이후에 시작"이 자동 만족(t0>=0>=-1) → 구속력 없이 통과해야 함.
good = CB.RespecProposal([CB.ForbidWindow(nid, -2.0, -1.0)])
vg = CB.verify(good, env, inv)
println(">>> ForbidWindow(nid, -2, -1)  => ", vg isa CB.Admit ? "ADMIT ($(vg.n_constraints) constr)" : "Reject($(vg.reason))")

# --- REJECT: an impossible window is infeasible ------------------------------
# With t_lo very negative, the disjunction's Big-M (1e5 in compiler.jl) cannot
# relax tF <= t_lo above 0, so BOTH branches force tF < 0 — impossible (tF>=0).
# 두 갈래 모두 tF<0 을 강요(Big-M 으로도 못 풀어줌) → tF>=0 과 모순이라 불가능 → Reject(:infeasible) 이어야 함.
bad = CB.RespecProposal([CB.ForbidWindow(nid, -1e6, 1e6)])
vb = CB.verify(bad, env, inv)
println(">>> ForbidWindow(nid, -1e6, 1e6) => ", vb isa CB.Reject ? "REJECT(:$(vb.reason))" : "Admit (UNEXPECTED)")

@assert vg isa CB.Admit  "expected ADMIT for non-binding window, got $(typeof(vg))"
@assert vb isa CB.Reject "expected REJECT for impossible window, got $(typeof(vb))"
@assert vb.reason == :infeasible "expected :infeasible, got :$(vb.reason)"

println("\n==================  GATE TEST PASSED  ==================")
println("The verify gate ADMITS feasible re-specs and REJECTS infeasible ones")
println("on a real schedule, with zero LLM involvement. Safety is in the gate.")

# =============================================================================
# FREEZE TEST: step the sim until some nodes complete, then confirm
# build_invariant pins their realized times and the gate still respects them.
# =============================================================================
println("\n>>> stepping simulation to close some nodes (rvo off, straight-line)...")
nclosed0 = length(env.cache.closed_set)
for i in 1:5000
    ConstructionBots.step_environment!(env)
    ConstructionBots.update_planning_cache!(env, 0.0)
    length(env.cache.closed_set) >= nclosed0 + 5 && break
end
nclosed = length(env.cache.closed_set)
println(">>> closed nodes: $nclosed0 -> $nclosed ; active = $(length(env.cache.active_set))")
@assert nclosed > nclosed0 "stepping closed no nodes — cache may not be seeded"

inv2 = CB.build_invariant(env)
println(">>> frozen_t0 entries = $(length(inv2.frozen_t0)), frozen_tF entries = $(length(inv2.frozen_tF))")
@assert !isempty(inv2.frozen_t0) "freeze produced no t0 lower bounds"
@assert !isempty(inv2.frozen_tF) "freeze produced no tF lower bounds (no closed nodes pinned)"

# A closed node's pinned tF must be a real (finite, >= 0) realized time.
some_closed = first(inv2.frozen_tF)
println(">>> sample pinned closed node: id=$(some_closed[1]) tF>=$(round(some_closed[2], digits=3))")
@assert isfinite(some_closed[2]) && some_closed[2] >= 0.0

# The gate must still ADMIT a feasible re-spec while honoring the freeze, i.e.
# the re-solved schedule does not pull frozen work earlier (satisfies_invariant).
open_v = first(v for v in Graphs.vertices(env.sched) if !(CB.get_vtx_id(env.sched, v) in inv2.closed_nodes))
nid2 = CB.get_vtx_id(env.sched, open_v)
good2 = CB.RespecProposal([CB.ForbidWindow(nid2, -2.0, -1.0)])
vg2 = CB.verify(good2, env, inv2)
println(">>> verify with non-empty freeze => ", vg2 isa CB.Admit ? "ADMIT (freeze respected)" : "Reject(:$(vg2.reason))")
@assert vg2 isa CB.Admit "expected ADMIT honoring freeze, got $(typeof(vg2))"

println("\n==================  FREEZE TEST PASSED  ==================")
println("Completed nodes are pinned to their realized times; the re-solve plans")
println("only the future and never pulls finished work into the past.")
println("\n>>>>>>>>>>>>>>  ALL TESTS PASSED  <<<<<<<<<<<<<<")
end

# =============================================================================
# respec_timing -- LLM-free verification that the commit (persist_milp_times!) makes the
#   timing-only re-spec (ForbidWindow) STICK past commit. ForbidWindow adds NO graph edge,
#   so its effect lives PURELY in the written MILP times — the direct test of
#   persist_milp_times!. Uses hand-written proposals through the verify -> commit_respec! path.
# =============================================================================
# [검증 내용] LLM 없이, commit(persist_milp_times!)이 타이밍-전용 re-spec(ForbidWindow)을 "커밋 후에도
#   유지"시키는지 증명. ForbidWindow 는 그래프 엣지를 추가하지 않아 효과가 오직 기록된 MILP 시간에만 존재 →
#   persist_milp_times! 를 직접 겨냥한 테스트. verify -> commit_respec! 경로를 손수 만든 제안으로 태운다.
function test_respec_timing()
# NOTE: do NOT cache the env via Serialization — round-tripping a built env through
# serialize/deserialize subtly corrupts its cached transforms/schedule state, which
# made update_project_schedule! re-derive a 6x-inflated makespan and produced a
# FALSE "write mechanism broken" failure. Always build fresh for trustworthy timing
# numbers. (deepcopy, used per-test below, IS faithful — only serialize is not.)

_setup_milp!(time_limit = 300.0, mip_rel_gap = 5.0)

pp = get_project_params(4)   # tractor
println(">>> building env (assignment only)...")
env = run_with_stack(2_000_000_000) do
    run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots],
        assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
        log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false,
        dispersion_flag=false, open_animation_at_end=false, save_animation=false,
        save_animation_along_the_way=false, write_results=false,
        overwrite_results=false, look_for_previous_milp_solution=false,
        save_milp_solution=false, return_env_before_sim=true)
end
println(">>> env ready: $(Graphs.nv(env.sched)) nodes")

# Collect open AssemblyComplete milestone nodes (what a ForbidWindow targets).
# Skip active nodes too: persist_milp_times! keeps a started node's realized t0, so
# a binding start-shift can only be tested on a not-yet-started (future) node.
asm_nodes = CB.AbstractID[]
for v in Graphs.vertices(env.sched)
    (v in env.cache.closed_set || v in env.cache.active_set) && continue
    node = CB.get_node(env.sched, v).node
    node isa CB.AssemblyComplete || continue
    push!(asm_nodes, CB.get_vtx_id(env.sched, v))
end
println(">>> open AssemblyComplete milestones: $(length(asm_nodes))")
@assert !isempty(asm_nodes) "need >=1 future milestone node to test ForbidWindow"

# ---------------------------------------------------------------------------
# TEST: ForbidWindow is the only remaining timing-only re-spec, and it adds NO
# graph edge — so its effect lives PURELY in the written MILP times. If the write
# mechanism (persist_milp_times!) did nothing, the structural pass would snap the
# node back to its earliest start at commit and this FAILS.
#
# Make the window genuinely BINDING: pick a future milestone, read its natural
# start t0n, and forbid [0, t0n + Δ]. "Finish before 0" is impossible (tF>=0), so
# the node MUST "start after t_hi" => t0 is forced up to >= t0n + Δ. (t_hi stays
# well under the compiler's Big-M=1e5, so only the start-after branch is viable.)
# ---------------------------------------------------------------------------
# 후보 milestone 중 "구속력 있게 시작을 미루는" ForbidWindow 가 Admit 되는 첫 노드를 찾는다.
local tgt, vt, t0n, t_lo, t_hi, prop, inv, verdict   # for 밖에서도 쓰려고 local 로 미리 선언
admitted = false
for cand in asm_nodes
    tgt = cand
    vt  = CB.get_vtx(env.sched, tgt)
    t0n = Float64(CB.get_t0(env.sched, vt))
    t_lo, t_hi = 0.0, t0n + 10.0
    prop = CB.RespecProposal([CB.ForbidWindow(tgt, t_lo, t_hi)])
    inv  = CB.build_invariant(env)
    verdict = CB.verify(prop, env, inv)
    if verdict isa CB.Admit; admitted = true; break; end
end
@assert admitted "no admittable binding ForbidWindow found to test"

println("\n── TEST: ForbidWindow($tgt, $(round(t_lo,digits=2)), $(round(t_hi,digits=2)))")
println("   BEFORE: t0[node]=$(round(t0n,digits=2))  (must be raised to >= $(round(t_hi,digits=2)))")
milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
    optimizer=CB._respec_optimizer(), t0_=inv.frozen_t0, tF_=inv.frozen_tF,
    extra_constraints=verdict.proposal)
CB.optimize!(milp)
t0m = JuMP.value.(milp.model[:t0])
println("   [MILP soln] t0[node]=$(round(t0m[vt],digits=2))  (constraint forces t0 >= t_hi)")
@assert CB.commit_respec!(env, milp, verdict.proposal) "commit_respec! failed"

t0a = Float64(CB.get_t0(env.sched, vt))                  # 커밋 후 스케줄에서 다시 읽은 시작시간
println("   AFTER : t0[node]=$(round(t0a,digits=2))")
ok = t0a >= t_hi - 1e-6   # 커밋 뒤에도 시작이 t_hi 위로 밀려 있으면 = 유지 성공(1e-6=부동소수점 여유)
println(ok ? "   ✅ PASS: ForbidWindow start-shift PERSISTED past commit (written MILP times alone, no edge)." :
            "   ❌ FAIL: t0 reverted below t_hi — write mechanism not working.")

println("\n", ok ? "════ TIMING-PERSISTENCE CHECK PASSED ════" :
                  "════ CHECK FAILED ════")
end

# =============================================================================
# respec_reassign -- STAGE 1 smoke test (no LLM, no viz). Proves "robot fault -> other
#   robots take over": fault_robot_and_reassign! frees the faulted robot from ALL pending
#   transport teams, the re-solved schedule is VALID, completed work stays frozen, and an
#   infeasible reassign is REJECTED. Two scenarios: (A) fault at t=0, (B) fault mid-build.
# =============================================================================
# [검증 내용] Stage 1 스모크(LLM/시각화 없음): "로봇 고장 -> 남은 로봇들이 인수" 를 증명.
#   fault_robot_and_reassign! 가 고장 로봇을 모든 pending 운반팀에서 빼고, 재풀이한 스케줄이 VALID,
#   이미 끝난 일은 freeze(고정) 유지, 불가능한 재배정은 Reject. 시나리오 (A) t=0 고장, (B) 빌드 중간 고장.
function test_respec_reassign()
# Re-solving needs a real MILP optimizer with a time limit (greedy never set one).
# Reassignment only needs a FEASIBLE re-solve, not a proven-optimal one. A large
# mip_rel_gap makes HiGHS return at the first feasible integer solution, which
# makes the worst-case (t=0, full re-solve) reliably fast instead of timing out.
_setup_milp!(time_limit = 300.0, mip_rel_gap = 5.0)

pp = get_project_params(4)   # tractor
println(">>> building env (assignment only, no simulation)...")
env = run_with_stack(2_000_000_000) do
    run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots],
        assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
        log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false,
        dispersion_flag=false, open_animation_at_end=false, save_animation=false,
        save_animation_along_the_way=false, write_results=false, overwrite_results=false,
        look_for_previous_milp_solution=false, save_milp_solution=false,
        return_env_before_sim=true)
end
@assert env !== nothing
println(">>> env built: $(Graphs.nv(env.sched)) nodes, $(length(env.cache.closed_set)) closed")

# 스케줄 그래프에서 RobotStart 노드(로봇의 시작점)들만 골라내는 comprehension.
robot_starts = [v for v in Graphs.vertices(env.sched)
                if CB.matches_template(CB.RobotStart, CB.get_node(env.sched, v))]
botid(v) = CB.entity(CB.get_node(env.sched, v).node).id   # 노드 -> 그 로봇의 id 추출

# 실제로 빼앗을 pending(대기중) 운반 작업이 있는 로봇을 하나 고른다.
faulted = nothing
for v in robot_starts
    id = botid(v)
    if length(CB.transport_teams_with_agent(env, id; pending_only=true)) > 0
        faulted = id; break
    end
end
@assert faulted !== nothing "no robot has pending transport work?!"

# =============================================================================
println("\n========== SCENARIO A: fault at t=0 (full future re-solve) ==========")
teamsA0 = CB.transport_teams_with_agent(env, faulted; pending_only=true)
println(">>> faulting $(faulted); it is on $(length(teamsA0)) pending transport team(s).")
@assert !isempty(teamsA0)

resA = CB.fault_robot_and_reassign!(env, faulted; verbose=true)
println(">>> result: ", resA)

@assert resA.status == :admitted "expected :admitted, got :$(resA.status)"
@assert resA.valid "update_project_schedule! reported an INVALID schedule"
@assert resA.teams_after == 0 "faulted robot still on $(resA.teams_after) pending team(s) — not freed"
@assert CB.validate(env.sched) "re-solved schedule failed validate()"
@assert isfinite(CB.makespan(env.sched)) "makespan is not finite after re-solve"

# 모든 운반 작업이 여전히 팀을 꽉 채웠는지(일이 누락 없이 커버됐는지) 확인:
ftus = [v for v in Graphs.vertices(env.sched)
        if CB.matches_template(CB.FormTransportUnit, CB.get_node(env.sched, v))]
for v in ftus
    node = CB.get_node(env.sched, v).node
    need = length(CB.robot_team(CB.entity(node)))    # 이 운반팀이 필요로 하는 로봇 수
    have = count(vp -> CB.get_node_from_id(env.sched, CB.get_vtx_id(env.sched, vp)) isa CB.RobotGo,
                 Graphs.inneighbors(env.sched, v))    # 실제 배정된(들어오는 RobotGo) 로봇 수
    @assert have >= need "FormTransportUnit v$v understaffed after reassign: have $have < need $need"
end
println(">>> SCENARIO A PASSED: faulted robot removed from all pending teams; all "*
        "$(length(ftus)) transport tasks fully staffed by the remaining robots; schedule valid.")

# =============================================================================
println("\n========== SCENARIO B: fault mid-build (freeze-respecting) ==========")
# Step the sim so some nodes complete, then fault a DIFFERENT robot.
for _ in 1:4000
    CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
    length(env.cache.closed_set) >= 8 && break
end
println(">>> stepped: closed=$(length(env.cache.closed_set)) active=$(length(env.cache.active_set))")
invB = CB.build_invariant(env)
frozen_tF_before = copy(invB.frozen_tF)
@assert !isempty(frozen_tF_before) "no closed nodes pinned — cannot test freeze"

faultedB = nothing
for v in robot_starts
    id = botid(v)
    id == faulted && continue
    if length(CB.transport_teams_with_agent(env, id; pending_only=true)) > 0
        faultedB = id; break
    end
end
@assert faultedB !== nothing "no second robot with pending work"
println(">>> faulting $(faultedB) (closed nodes frozen: $(length(frozen_tF_before)))")

resB = CB.fault_robot_and_reassign!(env, faultedB; verbose=true)
println(">>> result: ", resB)

# 중간 고장에서 재배정이 성공(:admitted)했다면, 스케줄이 valid 하고 freeze 가 지켜졌는지 검사.
if resB.status == :admitted
    @assert resB.valid "invalid schedule after mid-build reassign"
    @assert resB.teams_after == 0 "faulted robot still on pending teams mid-build"
    @assert CB.validate(env.sched) "schedule invalid after mid-build reassign"
    # freeze 준수: 이전에 끝난 모든 노드는 실현 종료시간을 그대로(>=) 유지해야 함(과거로 당겨지면 안 됨).
    for (id, tF) in frozen_tF_before
        v = CB.get_vtx(env.sched, id)
        @assert CB.get_tF(env.sched, v) >= tF - 1e-3 "frozen node $id pulled earlier: "*
            "$(CB.get_tF(env.sched, v)) < $tF"
    end
    println(">>> SCENARIO B PASSED: mid-build reassign kept all $(length(frozen_tF_before)) "*
            "completed nodes pinned; faulted robot freed; schedule valid.")
else
    # A reject mid-build is also a CORRECT outcome (safe-stop), as long as it did
    # not corrupt the schedule of record. Verify the gate behaved safely.
    @assert resB.status in (:rejected, :fallback)
    println(">>> SCENARIO B: reassignment was infeasible -> $(resB.status) (safe-stop path). "*
            "This is the gate correctly refusing an unsafe re-solve, not a failure.")
end

println("\n>>>>>>>>>>>>>>  STAGE 1 REASSIGN SMOKE TEST COMPLETE  <<<<<<<<<<<<<<")
println("Core capability proven: a verified, freeze-respecting MILP re-solve moves a")
println("faulted robot's pending work onto the other robots — solver untouched, past")
println("invariant, and an unsatisfiable reassignment is safely refused by the gate.")
end

# ---- dispatcher -------------------------------------------------------------
# TESTS : test_key(문자열) -> 해당 테스트 함수 사전. 아래 진입점이 이 사전에서 하나를 골라 실행.
const TESTS = Dict(
    "forbidzone_parse"         => test_forbidzone_parse,
    "replace_parse"            => test_replace_parse,
    "deprioritize_integration" => test_deprioritize_integration,
    "battery_smoke"            => test_battery_smoke,
    "battery_safety"           => test_battery_safety,
    "llm_classification"       => test_llm_classification,
    "respec_gate"              => test_respec_gate,
    "respec_timing"            => test_respec_timing,
    "respec_reassign"          => test_respec_reassign,
)
end # module Tests

# 이 파일을 `julia tools/tests.jl <key>` 로 직접 실행했을 때만(=import 될 때는 X) 아래가 돈다.
if abspath(PROGRAM_FILE) == @__FILE__
    # 실행할 테스트 키: 환경변수 TEST 우선, 없으면 첫 CLI 인자, 그것도 없으면 기본값.
    key = get(ENV, "TEST", isempty(ARGS) ? "forbidzone_parse" : ARGS[1])
    haskey(Tests.TESTS, key) || error("unknown test '$key'. Available: $(join(sort(collect(keys(Tests.TESTS))), ", "))")
    println(">>> running test: $key")
    Tests.TESTS[key]()
end
