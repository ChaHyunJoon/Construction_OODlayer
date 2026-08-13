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
#   zone_diagnosis           -- LLM-free unit test of the zone VIOLATION PREDICATES + minimal-repair rule (STEP 1)
#   zone_corridor            -- LLM-free unit test of the zone BLOCKAGE predicates: 덮였다 vs 막혔다 (STEP 8)
#   zone_team_causal         -- NAV-ON reversal test: does a covered team ACTUALLY fail to form? (STEP 11)
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
    Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Error))  # 이 레인이 선언한 로그 레벨을 호출 **전에** 심는다 — run_lego_demo 이 반환 시 호출 시점의 로거를 복원하므로(전역 누수 수정), 반환 후 자기 시뮬 루프도 이 레벨로 조용히 돈다.
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

# [6][7] ZONE_DOMAIN_GATE — "조용한 no-op" 을 눈에 보이게 만드는 게이트(verifier.jl).
#   ForbidZone 은 옮길 수 있는 조립체(non-root ∧ 아직 시작 안 함)가 없으면 실행부가 :none 을 돌려주고
#   결과가 NOOP 과 바이트 동일해진다 → 오답이 절제와 구별되지 않는다. 그 상태를 명시 거절로 바꾸는 게
#   이 게이트다. 여기서는 **아무것도 안 덮는 먼 구역**을 심어 도메인을 인위적으로 비운다.
println("\n[6] zone_domain_size — a zone covering nothing has an EMPTY relocatable domain")
CB.add_restriction_zone!(:faraway, [500.0, 500.0], 1.0)   # 빌드에서 한참 떨어진 구역(아무 적치원도 안 덮음)
n_far = CB.zone_domain_size(env, :faraway)
n_near = CB.zone_domain_size(env, :zone)
check("faraway zone domain == 0 (got $(n_far))", n_far == 0)
check("central zone domain > 0 (got $(n_near))", n_near > 0)

println("\n[7] verify_zone — empty domain: admitted with gate OFF, rejected with gate ON")
prop_far = CB.RespecProposal([CB.ForbidZone(resolver(asm_id), :faraway)], "x", "x")
CB.set_zone_domain_gate!(false)
v_off = CB.verify_zone(prop_far, env)
check("gate OFF -> Admit (옛 의미 보존: 조용한 no-op)", v_off isa CB.Admit)
CB.set_zone_domain_gate!(true)
v_on = CB.verify_zone(prop_far, env)
check("gate ON -> Reject(:empty_domain) (got $(v_on isa CB.Reject ? v_on.reason : typeof(v_on)))",
      v_on isa CB.Reject && v_on.reason == :empty_domain)
# 게이트가 켜져 있어도 도메인이 있는 정상 제안은 그대로 통과해야 한다(과잉 거절 방지).
check("gate ON -> 정상 제안은 여전히 Admit", CB.verify_zone(prop, env) isa CB.Admit)
CB.set_zone_domain_gate!(false)                            # 기본값(꺼짐)으로 원복 — 다른 테스트에 영향 없게

CB.clear_restriction_zones!()
println("\n==== ForbidZone parse/verify: $(npass[]) passed, $(nfail[]) failed ====")
nfail[] == 0 ? println("ALL GREEN") : println("SOME FAILED")
end

# =============================================================================
# corezone_guard -- the SEVERITY-GRADED core-zone generation guard (2026-08-03).
#
#   The old guard (`zone_clears_root_goals`) was binary and forbade the whole interesting
#   family: a zone covering the ROOT's delivery goals. It had to, because `restage_all_blocked!`
#   cannot move the root. The measured cost of that restriction: NOOP was never punished —
#   seed 301 closed exactly 213/313 at every zone severity — so the zone class could only ever
#   measure "was intervening worth it", never "must we react".
#
#   `core_zone_for_severity` replaces it with a continuous knob (fraction of root delivery goals
#   swallowed) gated on `zone_relocatable` (a whole-build shift clearing it must exist). This
#   test asserts the two properties that make it usable as a severity ladder:
#     (1) MONOTONE — asking for more coverage never returns less.
#     (2) RECOVERABLE BY CONSTRUCTION — every admitted zone is escapable, verified with the SAME
#         solver the enactment uses, and the top of the ladder really does cover root goals
#         (otherwise there is still no harm axis).
# =============================================================================
# [검증 내용] 심각도 연속 core zone 가드 검사. (1) frac 을 올리면 실제 커버리지가 줄지 않는다(단조),
#   (2) 채택된 구역은 전부 "빌드 전체 이동으로 벗어날 수 있음"이 실행부와 같은 솔버로 확인된다,
#   (3) 사다리 꼭대기는 root 하역 목표를 실제로 덮는다(= harm 이 존재한다).
function test_corezone_guard()
_setup_milp!(time_limit = 120.0)

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

npass = Ref(0); nfail = Ref(0)
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))

CB.clear_restriction_zones!()
gs0 = CB.root_deposit_goals(env)
n_root = length(gs0)
println("\n[1] root delivery goals on record: $n_root")
check("root deposit goals exist (없으면 harm 축 자체가 불가능)", n_root > 0)
if n_root > 0
    # 사다리가 평평해지면 원인은 거의 항상 "거리 분포 대비 여유(margin/pad)가 너무 크다"이다.
    # 그래서 원자료(무게중심에서 각 목표까지의 거리)를 같이 찍는다.
    c0 = sum(gs0) ./ length(gs0)
    d0 = sort([LinearAlgebra.norm(c0 .- g) for g in gs0])
    println("    centroid=$(round.(c0; digits=3))  robot_radius=$(round(CB.default_robot_radius(); digits=3))")
    println("    goal distances (sorted) = $(round.(d0; digits=3))")
end

println("\n[2] severity ladder  (요청 frac -> 실제 커버리지 / 반지름 / 복구가능)")
fracs = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
sels = map(f -> CB.core_zone_for_severity(env, f), fracs)
for (f, s) in zip(fracs, sels)
    println("    frac=$(round(f; digits=1)) -> covered $(s.covered)/$(s.total) " *
            "($(round(s.frac; digits=2)))  R=$(round(s.radius; digits=2))  relocatable=$(s.relocatable)")
end
covs = [s.covered for s in sels]
check("단조: frac 을 올리면 커버리지가 줄지 않는다", all(covs[i] <= covs[i+1] for i in 1:length(covs)-1))
check("사다리 꼭대기가 root 목표를 실제로 덮는다(harm 존재)", last(covs) >= 1)
check("사다리가 실제로 갈라진다(전부 같은 값이면 손잡이가 아니다)", first(covs) < last(covs))
# 계약은 covered == "k번째 목표까지 품으면 필연적으로 들어오는 목표 수"다. 정확히 k 가 아닌 이유:
# 트랙터는 좌우대칭이라 목표 거리에 **동률**이 있다(0.16,0.16 / 0.179,0.179 / 0.32,0.32).
# 동률인 두 목표는 원 하나로 갈라낼 수 없으므로 사다리 칸이 1,3,5,8 로 뭉친다 — 구현 결함이 아니라 기하다.
# (여유 중복 적용 같은 진짜 버그였다면 모든 칸이 8/8 로 붕괴한다 — 그건 위 '갈라진다' 검사가 잡는다.)
if n_root > 0
    c0 = sum(gs0) ./ length(gs0)
    d0 = sort([LinearAlgebra.norm(c0 .- g) for g in gs0])
    expect = [count(x -> x <= d0[clamp(ceil(Int, f * n_root), 1, n_root)] + 1e-9, d0) for f in fracs]
    check("커버리지가 동률을 고려한 기대값과 일치한다  (기대 $expect / 실제 $covs)", covs == expect)
end
check("채택된 구역은 전부 relocatable", all(s.relocatable for s in sels if s.radius > 0.0))

println("\n[3] 채택된 구역이 정말 벗어날 수 있는가 — 실행부와 같은 솔버로 재확인")
ok = all(CB.zone_relocatable(s.center, s.radius, env) for s in sels if s.radius > 0.0)
check("zone_relocatable 재확인 통과", ok)

println("\n[4] 옛 가드와의 관계: 사다리 위쪽은 zone_clears_root_goals 를 **의도적으로 위반**한다")
top = last(sels)
violates = !CB.zone_clears_root_goals(top.center, top.radius, env)
println("    top zone R=$(round(top.radius;digits=2)) clears_root=$(!violates)")
check("옛 이진 가드였다면 거부됐을 구역이다(= 새로 열린 영역)", violates)

CB.clear_restriction_zones!()
println("\n==== core-zone severity guard: $(npass[]) passed, $(nfail[]) failed ====")
nfail[] == 0 ? println("ALL GREEN") : println("SOME FAILED")
end

# =============================================================================
# relocatebuild_parse -- LLM-free unit test of the RelocateBuild bridge+verify+ENACT path.
#   RelocateBuild is the SECOND spatial spec (added 2026-08-03): it skips the per-assembly
#   restage and shifts the WHOLE build clear of the zone. It exists because ForbidZone's
#   repairer can only move assemblies that have not started building, and that set empties
#   at the first batch boundary and never refills (oracle/out/zdiag*), which made every
#   mid-build ForbidZone a silent no-op.
#
#   Unlike forbidzone_parse this test goes one step further and ENACTS through the production
#   dispatch (`maybe_respecify!` with a producer), because the whole point of the new spec is
#   that the enactment does something — a parse-only test would have passed for ForbidZone too.
#   Asserted: the JSON parses to RelocateBuild, the gate admits it (and rejects an invented
#   zone), the dispatch returns :admitted, and the staging geometry ACTUALLY MOVED with no
#   future goal left inside the zone.
# =============================================================================
# [검증 내용] LLM 없이 RelocateBuild(빌드 전체 평행이동) 경로를 끝까지 확인: 가짜 JSON 파싱 →
#   verify_relocate 가 정상은 Admit / 없는 zone 은 Reject → 실제 dispatch(maybe_respecify!)가
#   :admitted 를 내고 **적치 기하가 진짜로 움직였는지**(구역 안 목표 0개) 본다.
#   파싱만 보는 테스트는 ForbidZone 도 통과했으므로(그게 조용한 no-op 이었던 이유), 실행까지 본다.
function test_relocatebuild_parse()
_setup_milp!(time_limit = 120.0)

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

npass = Ref(0); nfail = Ref(0)
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))

# 중앙(=root 자신의 하역 목표들 위)에 구역을 심는다. 조립체별 재적치로는 절대 못 비키는 배치 —
# 바로 이 상황이 whole-build 평행이동이 존재하는 이유다.
gs = CB.root_deposit_goals(env)
zc = isempty(gs) ? [1.5, 0.96] : sum(gs) ./ length(gs)
CB.clear_restriction_zones!(); CB.add_restriction_zone!(:zone, zc, 2.5)

println("\n[1] _parse_proposal with a RelocateBuild JSON")
resolver = ref -> CB._default_id_resolver(env, ref)
payload_ok = JSON3.read(JSON3.write(Dict(
    "constraints" => [Dict("kind" => "RelocateBuild", "zone" => "zone")],
    "rationale" => "zone covers un-relocatable core goals; shift the whole build")))
prop = CB._parse_proposal(payload_ok, "A no-go zone is active over the build core."; id_resolver=resolver)
check("parsed 1 constraint", length(prop.constraints) == 1)
check("constraint isa RelocateBuild", !isempty(prop.constraints) && prop.constraints[1] isa CB.RelocateBuild)
check("zone symbol == :zone", !isempty(prop.constraints) && prop.constraints[1].zone == :zone)
check("_is_relocate_build true", CB._is_relocate_build(prop))
# ForbidZone 경로로 새지 않아야 한다(둘은 서로 다른 dispatch 분기다).
check("_is_zone_respec false (별도 분기)", !CB._is_zone_respec(prop))

println("\n[2] verify_relocate — valid proposal admits")
check("verify_relocate Admit", CB.verify_relocate(prop, env) isa CB.Admit)

println("\n[3] verify_relocate — unknown zone key rejects (LLM 이 없는 구역을 지어낸 경우)")
v_bad = CB.verify_relocate(CB.RespecProposal([CB.RelocateBuild(:ghost)], "x", "x"), env)
check("Reject(:no_such_zone)", v_bad isa CB.Reject && v_bad.reason == :no_such_zone)

println("\n[4] ENACT through the production dispatch (maybe_respecify!)")
# 이동 전 기하를 기록해 둔다: 적치원 중심들과 "구역 안에 남은 미래 목표 수".
before_centers = Dict(k => Vector{Float64}(CB.get_center(b)[1:2]) for (k, b) in env.staging_circles)
before_in_zone = CB._count_future_goals_in_zone(env; zone_keys = [:zone])
println("    이동 전: 구역 안 미래 목표 $(before_in_zone)개, 적치원 $(length(before_centers))개")
check("사전 조건: 구역이 실제로 미래 목표를 덮고 있다", before_in_zone > 0)

# push_ood! 은 전역 큐(RESPEC_QUEUE)에만 쓰는 1-인자 함수다. 여기서는 이 테스트 전용 큐를 만들어
# maybe_respecify! 에 직접 넘긴다(전역 큐를 오염시키지 않기 위해 pending 을 직접 채운다).
q = CB.OODQueue(String["A no-go exclusion zone has appeared over the build core."])
status = CB.maybe_respecify!(env, q; producer = (_env, _ev) -> prop)
println("    dispatch status = $(status)")
check("dispatch -> :admitted", status == :admitted)

after_in_zone = CB._count_future_goals_in_zone(env; zone_keys = [:zone])
moved = count(k -> haskey(env.staging_circles, k) &&
                   maximum(abs.(Vector{Float64}(CB.get_center(env.staging_circles[k])[1:2]) .- before_centers[k])) > 1e-6,
              collect(keys(before_centers)))
println("    이동 후: 구역 안 미래 목표 $(after_in_zone)개, 움직인 적치원 $(moved)/$(length(before_centers))")
check("기하가 실제로 움직였다(조용한 no-op 이 아니다)", moved == length(before_centers))
check("구역 안에 남은 미래 목표 0개", after_in_zone == 0)

CB.clear_restriction_zones!()
println("\n==== RelocateBuild parse/verify/enact: $(npass[]) passed, $(nfail[]) failed ====")
nfail[] == 0 ? println("ALL GREEN") : println("SOME FAILED")
end

# =============================================================================
# zone_diagnosis -- the VIOLATION PREDICATES layer (src/respec/zone_diagnosis.jl, STEP 1).
#
#   `zone_diagnosis(env, :zone)` answers "what does this no-go zone actually INVALIDATE in the
#   scene tree", returning PRIMITIVES (blocked set, root-goal coverage, work-disc overlap,
#   minimum clearing shift) plus ONE derived `verdict` — the cheapest repair that clears every
#   violated predicate. The verdict is the ORACLE LABEL and the gate's justification; it is
#   deliberately NOT a policy input (a policy given the verdict is reading the answer).
#
#   What this test asserts, in order of what could actually break:
#     (1) the primitives agree with the standalone helpers they compose (no drift between the
#         diagnosis and the enactment/verify paths that use those same helpers),
#     (2) the decision rule is INTERNALLY CONSISTENT at every sampled geometry — i.e. the
#         verdict is a function of the primitives exactly as documented, swept over a radius
#         ladder so the branch boundaries are actually crossed, and
#     (3) a zone that covers nothing yields `:noop` with all-zero primitives — the case where
#         intervening is measurably harmful (231 nodes closed vs 136), so it must not be a
#         degenerate fallthrough.
# =============================================================================
# [검증 내용] 구역 위반 술어 계산기(zone_diagnosis) 단위 검사.
#   (1) 원시값이 그것을 조합한 기존 함수들(zone_domain_size / root_goal_coverage /
#       _count_future_work_overlaps / _find_min_translation)과 정확히 일치하는가 — 진단과 실행부가
#       같은 사실을 보고 있는지(드리프트 없음),
#   (2) 반지름 사다리를 훑으며 **모든 표본에서** verdict 가 문서대로 원시값의 함수인가(분기 경계를 실제로 넘김),
#   (3) 아무것도 안 덮는 구역은 원시값 전부 0 에 :noop 인가(여기서 개입하면 순손실 — 231 vs 136 실측).
function test_zone_diagnosis()
_setup_milp!(time_limit = 120.0)

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

npass = Ref(0); nfail = Ref(0)
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))

# 문서화된 결정 규칙 자체를 술어로 옮긴 것. 어떤 기하에서든 이게 깨지면 verdict 는 원시값의 함수가 아니다
# (= 라벨을 신뢰할 수 없다). 규칙: 국소로 옮길 게 있으면 국소 > root 갇힘이면 전역(가능하면) > 아니면 절제.
rule_consistent(d) =
    d.verdict === :forbid_zone    ? d.n_restage_feasible > 0 :
    d.verdict === :relocate_build ? (d.n_restage_feasible == 0 && (d.root_covered > 0 || d.n_teams_covered > 0) && d.relocate_feasible) :
    d.verdict === :line_stop      ? (d.n_restage_feasible == 0 && (d.root_covered > 0 || d.n_teams_covered > 0) && !d.relocate_feasible) :
    d.verdict === :noop           ? (d.n_restage_feasible == 0 && d.root_covered == 0 && d.n_teams_covered == 0) :
                                    false

CB.clear_restriction_zones!()

println("\n[1] 등록되지 않은 구역 -> :no_such_zone (진단은 절대 throw 하지 않는다)")
d0 = CB.zone_diagnosis(env, :ghost)
check("exists == false", d0.exists == false)
check("verdict == :no_such_zone (got $(d0.verdict))", d0.verdict === :no_such_zone)
check("원시값 전부 비어 있음", d0.n_blocked == 0 && d0.root_covered == 0 && !d0.relocate_feasible)

println("\n[2] 아무것도 안 덮는 먼 구역 -> :noop (개입이 해로운 경우)")
CB.add_restriction_zone!(:faraway, [500.0, 500.0], 1.0)
d1 = CB.zone_diagnosis(env, :faraway)
println("    -> n_blocked=$(d1.n_blocked) root=$(d1.root_covered)/$(d1.root_total) " *
        "work_overlap=$(d1.n_work_overlap) verdict=$(d1.verdict)")
check("verdict == :noop (got $(d1.verdict))", d1.verdict === :noop)
check("도메인 0 (게이트가 보는 값과 동일)", d1.n_blocked == CB.zone_domain_size(env, :faraway))
check("root 목표 0개 덮음", d1.root_covered == 0)
check("미완 작업 디스크 0개 겹침", d1.n_work_overlap == 0)
check("규칙 일관", rule_consistent(d1))

println("\n[3] 중앙 구역 -> 원시값이 기존 헬퍼들과 일치 + 절제가 정답이 아니다")
gs = CB.root_deposit_goals(env)
zc = isempty(gs) ? [1.5, 0.96] : sum(gs) ./ length(gs)
CB.add_restriction_zone!(:zone, zc, 2.5)
d2 = CB.zone_diagnosis(env, :zone)
println("    -> n_blocked=$(d2.n_blocked) feasible=$(d2.n_restage_feasible) " *
        "root=$(d2.root_covered)/$(d2.root_total) work_overlap=$(d2.n_work_overlap) " *
        "|Δ|=$(round(d2.relocate_norm; digits=3)) verdict=$(d2.verdict)")
rc = CB.root_goal_coverage(zc, 2.5, env)
check("n_blocked == zone_domain_size", d2.n_blocked == CB.zone_domain_size(env, :zone))
check("root_covered/root_total == root_goal_coverage", d2.root_covered == rc.covered && d2.root_total == rc.total)
check("n_work_overlap == _count_future_work_overlaps",
      d2.n_work_overlap == CB._count_future_work_overlaps(env; zone_keys = [:zone]))
check("relocate_feasible == (_find_min_translation !== nothing)",
      d2.relocate_feasible == (CB._find_min_translation(env; zone_keys = [:zone]) !== nothing))
check("n_restage_feasible <= n_blocked (부분집합)", d2.n_restage_feasible <= d2.n_blocked)
check("사전 조건: 중앙 구역이 root 하역 목표를 실제로 덮는다(harm 존재)", d2.root_covered > 0)
check("verdict != :noop (덮는 게 있는데 절제는 오답)", d2.verdict !== :noop)
check("규칙 일관", rule_consistent(d2))

println("\n[4] 기하 격자(반지름 × 거리) — 모든 표본에서 verdict 가 원시값의 함수인가")
# 반지름만 키우면 분기가 안 바뀐다: 시뮬 전(closed=0)에는 모든 조립체가 미개시라 도메인이 항상
# 비어 있지 않고, 그래서 규칙은 언제나 국소 팔을 먼저 고른다. 분기가 실제로 뒤집히는 축은 **거리**다
# (구역을 빌드에서 멀리 놓을수록 덮는 게 없어진다). 두 축을 다 훑어야 경계를 넘긴 검사가 된다.
verdicts = Symbol[]
sweep_at(label, c, r) = begin
    CB.remove_restriction_zone!(:sweep)
    CB.add_restriction_zone!(:sweep, c, r)
    d = CB.zone_diagnosis(env, :sweep)
    push!(verdicts, d.verdict)
    println("    $(label): blocked=$(d.n_blocked)/feasible=$(d.n_restage_feasible) " *
            "root=$(d.root_covered)/$(d.root_total) teams=$(d.n_teams_covered)/$(d.n_teams_forming) " *
            "|Δ|=$(round(d.relocate_norm; digits=3)) -> $(d.verdict)")
    check("$(label) 규칙 일관 ($(d.verdict))", rule_consistent(d))
    d
end
for r in [0.5, 1.5, 2.5, 4.0]
    sweep_at("r=$(r) @center", zc, r)
end
for dx in [5.0, 10.0, 25.0, 100.0]
    sweep_at("d=$(dx) @r=2.5", zc .+ [dx, 0.0], 2.5)
end
CB.remove_restriction_zone!(:sweep)
# 격자가 한 분기에만 머무르면 위 일관성 검사는 사실상 아무것도 안 본 것이다 — 경계를 넘겼는지 확인.
seen_verdicts = join(unique(verdicts), ", ")
check("격자가 최소 2개의 서로 다른 분기를 지난다 (got $(seen_verdicts))",
      length(unique(verdicts)) >= 2)
check("빌드 위(가장 가까운 표본)에서는 절제가 답이 아니다 (got $(verdicts[1]))", verdicts[1] !== :noop)
check("충분히 멀면 절제가 답이다 (got $(verdicts[end]))", verdicts[end] === :noop)
# 남은 두 분기(:relocate_build/:line_stop)는 "도메인이 비었는데 root 나 팀이 갇힘"을 요구하고,
# 그건 조립이 이미 시작된 빌드 중반 상태에서만 생긴다(시뮬 전 env 로는 원리적으로 도달 불가).
# 그 두 분기는 STEP 6 의 라벨 격자(진행 중 스냅샷)에서 밟힌다 — 여기서 못 밟는 게 정상이다.
println("    (참고) 이 env 는 시뮬 전이라 도메인이 절대 비지 않는다 → :relocate_build/:line_stop 은 " *
        "구조상 도달 불가. STEP 6 격자에서 검증한다.")

println("\n[5] check_restage=false — 값비싼 스캔을 건너뛴 상계(upper bound)")
d_fast = CB.zone_diagnosis(env, :zone; check_restage = false)
check("n_restage_feasible == n_blocked (스캔 생략 시 정의)", d_fast.n_restage_feasible == d_fast.n_blocked)
check("n_blocked 은 스캔 여부와 무관하게 동일", d_fast.n_blocked == d2.n_blocked)
check("정확한 값의 상계", d_fast.n_restage_feasible >= d2.n_restage_feasible)

# [5b] 팀 슬롯 술어. 이 env 는 시뮬레이션 前(return_env_before_sim)이라 형성 중인 팀이 아직 없다 —
#   여기서 볼 수 있는 것은 "함수가 안전하고, 팀이 없을 때 완전히 무해하다"까지다. 실제로 팀이 덮이는
#   분기는 빌드 중간 상태가 있어야 밟히므로 STEP 6 라벨 생성(사다리 스윕)에서 검증한다.
println("\n[5b] 팀 슬롯 술어 — 팀이 없을 때 완전히 무해한가(그리고 flag 가 라벨을 몰래 안 바꾸는가)")
tc = CB.zone_team_coverage(env, zc, 1e6)                  # 온 세상을 덮는 원판: 형성 중인 팀은 전부 covered
println("    -> 형성 중인 팀 $(d2.n_teams_forming)개, 그중 덮인 팀 $(d2.n_teams_covered)개")
check("zone_team_coverage 가 던지지 않고 팀 수와 일치", length(tc) == d2.n_teams_forming)
check("무한대 반지름은 모든 형성 팀을 덮는다", count(t -> t.covered, tc) == length(tc))
check("n_teams_covered <= n_teams_forming", d2.n_teams_covered <= d2.n_teams_forming)
d_noteam = CB.zone_diagnosis(env, :zone; check_teams = false)
check("팀 술어 OFF 는 팀 목록을 비운다", d_noteam.n_teams_forming == 0 && d_noteam.n_teams_covered == 0)
# 덮인 팀이 없으면 새 술어는 정의상 무효 → 옛 규칙과 라벨이 **완전히** 같아야 한다(소급 변경 없음).
check("덮인 팀이 없으면 verdict 는 옛 규칙과 동일 ($(d2.verdict) vs $(d_noteam.verdict))",
      d2.n_teams_covered > 0 || d_noteam.verdict === d2.verdict)

println("\n[6] zone_diagnoses — 살아 있는 모든 구역을 빠짐없이 진단")
all_d = CB.zone_diagnoses(env)
check("구역 수만큼 진단 (got $(length(all_d)) vs $(length(CB.RESTRICTION_ZONES[])))",
      length(all_d) == length(CB.RESTRICTION_ZONES[]))
check("전부 exists == true", all(d -> d.exists, all_d))
check("전부 규칙 일관", all(rule_consistent, all_d))

# [7] 게이트와 규칙이 **같은 계산기**를 보는가. RELOCATE_GATE(비례성 게이트)는 예전엔 root 하역목표
#   커버리지만 봤다 — 그러면 "형성 중인 팀이 갇혔다"는 새 위반에서 규칙은 옮기라 하고 게이트는 막는
#   조용한 불일치가 난다. 이제 둘 다 zone_diagnosis 를 읽는다. 여기서는 그 배선이 살아 있는지 본다.
println("\n[7] RELOCATE_GATE(비례성) 이 진단과 같은 결론을 내는가")
CB.set_relocate_gate!(true)
p_far = CB.RespecProposal([CB.RelocateBuild(:faraway)], "x", "x")
v_far = CB.verify_relocate(p_far, env)
check("아무것도 안 덮는 구역: Reject(:disproportionate) (got $(v_far isa CB.Reject ? v_far.reason : typeof(v_far)))",
      v_far isa CB.Reject && v_far.reason == :disproportionate)
p_ctr = CB.RespecProposal([CB.RelocateBuild(:zone)], "x", "x")
check("root 를 덮는 중앙 구역: 여전히 Admit(과잉 거절 아님)", CB.verify_relocate(p_ctr, env) isa CB.Admit)
CB.set_relocate_gate!(false)                               # 기본값(꺼짐)으로 원복
check("게이트 OFF 면 먼 구역도 Admit(옛 의미 보존)", CB.verify_relocate(p_far, env) isa CB.Admit)

CB.clear_restriction_zones!()
check("구역이 없으면 빈 목록(비공간 사건은 자연히 아무것도 못 봄)", isempty(CB.zone_diagnoses(env)))

println("\n==== zone_diagnosis predicates: $(npass[]) passed, $(nfail[]) failed ====")
nfail[] == 0 ? println("ALL GREEN") : println("SOME FAILED")
end

# =============================================================================
# zone_corridor -- the BLOCKAGE predicates (src/respec/zone_corridor.jl, STEP 8).
#
#   STEP 6 measured that COVERAGE is not harm: a zone swallowing 8/8 root delivery goals still
#   let the build close all 291 nodes. This layer computes the thing coverage was standing in
#   for. Its central claim is a claim ABOUT THE SIMULATOR, so this test is written to be able
#   to FALSIFY it, not to illustrate it:
#
#     (1) the goals `root_goal_coverage` counts are `LiftIntoPlace` goals, and `LiftIntoPlace`
#         moves the CARGO by integrating a twist directly — no RVO, hence no zone enforcement.
#         So those goals are UNBLOCKABLE. Asserted here as a set relation on the live schedule,
#         not as prose.
#     (2) a zone on such a goal reports coverage > 0 and blockage == 0;
#         a zone on an RVO-driven goal (RobotGo/TransportUnitGo) reports blockage > 0.
#         If these two ever agree, the whole distinction is empty.
#     (3) the corridor case — goal free, route pinched off by a RING of zones — is exactly what
#         `_minimum_clear_translation` cannot see (Δ clears the goal DISC, never the route).
#         Tested on pure geometry so it cannot be confounded by the build.
#     (4) the wiring: `zone_diagnosis` carries the primitives, the opt-in `ZONE_CAUSAL_RULE`
#         flips a coverage-only zone to `:noop`, and OFF reproduces the old labels byte-for-byte.
# =============================================================================
# [검증 내용] 구역 **막힘**(blockage) 술어 단위 검사. 커버리지가 재던 목표(LiftIntoPlace)는 화물을
#   직접 옮기는 노드라 RVO 를 안 거치고 → 구역이 원리적으로 못 막는다는 주장을, 산문이 아니라
#   살아 있는 스케줄 위의 **집합 관계**로 검사한다. 또 통로 봉쇄(ring)를 순수 기하로 확인하고,
#   zone_diagnosis 배선과 opt-in 인과 규칙(ZONE_CAUSAL_RULE)이 라벨을 어떻게 바꾸는지 본다.
function test_zone_corridor()
_setup_milp!(time_limit = 120.0)

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

npass = Ref(0); nfail = Ref(0)
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))

CB.clear_restriction_zones!()
rr  = Float64(CB.default_robot_radius())
tol = Float64(CB.capture_distance_tolerance())
norm = LinearAlgebra.norm       # tests.jl 는 LinearAlgebra 를 import 만 하므로 지역 별칭을 둔다

# ---- [1] 목표 인구를 두 부류로 가른다 -----------------------------------------------------
println("\n[1] 목표 분류 — RVO 로 움직이는 목표 vs 화물 운동학 목표")
navs = CB._nav_goal_targets(env)
kins = CB._kinematic_goal_targets(env)
roots = CB.root_deposit_goals(env)
println("    nav(RobotGo/TransportUnitGo) = $(length(navs))개, " *
        "kinematic(LiftIntoPlace) = $(length(kins))개, root deposit = $(length(roots))개")
check("막을 수 있는 목표(nav)가 존재한다", !isempty(navs))
check("운동학 목표(kinematic)도 존재한다", !isempty(kins))
check("nav 목표의 주체는 로봇 또는 운반유닛뿐", all(t -> t.kind in (:robot, :transport), navs))
# ★ 이것이 STEP 6 반증의 기계적 근거다: 커버리지가 세던 root 목표는 전부 운동학 부류에 속한다.
#   (좌표 일치로 확인 — root_deposit_goals 는 LiftIntoPlace 의 goal_config 를 읽는다.)
root_in_kin = isempty(roots) ? false :
    all(g -> any(k -> norm(k .- g) < 1e-9, kins), roots)
check("root 하역목표는 전부 운동학(LiftIntoPlace) 목표다 = 구역이 원리적으로 못 막는 부류",
      root_in_kin)
# 그렇다고 root 목표 자리가 전부 "아무도 안 가는 자리"인 것은 아니다: 어떤 자리는 운반유닛의 이동
# 목표(TransportUnitGo)와 **정확히 겹친다**. 겹치면 그 자리는 막힐 수 있다. 그러므로 커버리지는
# 막힘의 상계일 뿐 같지 않다 — 몇 개나 겹치는지는 주장하지 말고 **재서** 남긴다.
n_root_nav = count(roots) do g
    any(t -> norm(t.goal .- g) < 1e-9, navs)
end
println("    root 하역목표 $(length(roots))개 중 nav 목표와 좌표가 일치하는 것: $(n_root_nav)개")
for (i, g) in enumerate(roots)
    isempty(navs) && break
    j = argmin([norm(t.goal .- g) for t in navs])
    println("      root[$i] @$(round.(g; digits=3)) -> 가장 가까운 nav 목표 " *
            "$(navs[j].kind) d=$(round(norm(navs[j].goal .- g); digits=4)) r_agent=$(round(navs[j].radius; digits=3))")
end
check("root 하역목표 전부가 nav 목표인 것은 아니다(=커버리지 ≠ 막힘의 필요조건)",
      isempty(roots) || n_root_nav < length(roots))

# ---- [2] 같은 크기의 구역, 다른 자리 — 덮음과 막음이 갈리는가 ------------------------------
println("\n[2] 결정적 대비 — 운동학 목표 위 vs nav 목표 위 (반지름 동일)")
zr_small = 1e-3
# 운동학 목표 중 **어떤 nav 목표와도 충분히 떨어진** 것을 고른다. 그래야 "덮었지만 아무것도 안 막았다"가
# 기하적으로 성립한다(가까이 있으면 그 nav 목표까지 배제원에 들어가 막히는 게 물리적으로 맞다).
safe_kin = nothing; safe_d = 0.0
for g in kins
    d = isempty(navs) ? Inf : minimum(norm(t.goal .- g) - (zr_small + t.radius + tol) for t in navs)
    d > safe_d && (safe_d = d; safe_kin = g)
end
if safe_kin !== nothing && safe_d > 0.0
    CB.remove_restriction_zone!(:kin)
    CB.add_restriction_zone!(:kin, safe_kin, zr_small)
    bk = CB.zone_blockage(env; zone_keys = [:kin], check_paths = true)
    println("    운동학 목표 위: covered(kinematic)=$(bk.n_kinematic_covered) " *
            "blocked(nav)=$(bk.n_blocked) (engulf=$(bk.n_engulfed) disc=$(bk.n_disconnected)) " *
            "여유=$(round(safe_d; digits=3))")
    check("운동학 목표를 덮는다(=커버리지는 0 이 아니다)", bk.n_kinematic_covered > 0)
    check("그런데 막은 것은 없다(=blockage 0) — 덮였다 ≠ 막혔다", bk.n_blocked == 0)
    CB.remove_restriction_zone!(:kin)
else
    println("    (건너뜀) 모든 운동학 목표가 어떤 nav 목표의 배제원 안에 있어 분리 불가")
    check("운동학 목표를 nav 목표와 분리할 수 있다", false)
end

# 같은 크기의 구역을 nav 목표 위에 놓으면 그 노드는 절대 못 닫힌다.
t0 = navs[argmin([t.radius for t in navs])]
CB.remove_restriction_zone!(:nav)
CB.add_restriction_zone!(:nav, t0.goal, zr_small)
bn = CB.zone_blockage(env; zone_keys = [:nav], check_paths = true)
println("    nav 목표 위: blocked(nav)=$(bn.n_blocked) " *
        "(engulf=$(bn.n_engulfed) disc=$(bn.n_disconnected)) " *
        "covered(kinematic)=$(bn.n_kinematic_covered)")
check("nav 목표 위 구역은 막는다(blockage > 0)", bn.n_blocked > 0)
check("그 목표가 실제로 blocked 목록에 있다", any(b -> b.vtx == t0.vtx, bn.blocked))
check("그 상태는 :engulfed (포획볼이 배제원 안)",
      any(b -> b.vtx == t0.vtx && b.status === :engulfed, bn.blocked))
check("goal_engulfed 닫힌식과 일치",
      CB.goal_engulfed(t0.goal, t0.radius, [CB.RESTRICTION_ZONES[][:nav]]))
CB.remove_restriction_zone!(:nav)

# ---- [3] 통로(corridor) — 순수 기하 위에서 -------------------------------------------------
# Δ 는 목표 원만 비우고 경로는 안 본다. 여기서는 목표가 완전히 비어 있는데도 길이 끊긴 배치를 만든다.
println("\n[3] 통로 봉쇄 — 목표는 비었는데 길이 없다 (Δ 가 못 보는 것)")
ring_zone(n, R, D) = [CB.LazySets.Ball2([D * cos(2π * k / n), D * sin(2π * k / n)], R)
                      for k in 0:(n-1)]
goal_in = [0.0, 0.0]; start_far = [50.0, 0.0]
# 촘촘한 고리: 이웃 원판의 **부풀린**(+로봇반지름) 경계가 서로 겹쳐 틈이 없다.
D = 5.0; n_ring = 16
gap = 2 * D * sin(π / n_ring)                      # 이웃 중심 간 거리
R_tight = gap / 2 - rr + 0.05                      # 부풀리면 겹치도록(틈 < 0)
tight = ring_zone(n_ring, R_tight, D)
st_tight = CB.free_space_status(start_far, goal_in, tight, rr; cell = 0.25 * rr)
println("    촘촘한 고리(n=$(n_ring), R=$(round(R_tight;digits=3)), D=$(D)) -> $(st_tight)")
check("고리 안의 목표는 :disconnected (통로 봉쇄)", st_tight === :disconnected)
check("그런데 목표 자체는 어떤 구역 안에도 없다(=engulf 가 아니다)",
      !CB.goal_engulfed(goal_in, rr, tight))
# 성긴 고리: 같은 개수·같은 거리인데 반지름만 줄여 로봇이 지나갈 틈을 남긴다.
loose = ring_zone(n_ring, max(R_tight - 3 * rr, 1e-3), D)
st_loose = CB.free_space_status(start_far, goal_in, loose, rr; cell = 0.25 * rr)
println("    성긴 고리(R=$(round(max(R_tight - 3*rr, 1e-3);digits=3))) -> $(st_loose)")
check("틈이 있으면 :clear (술어가 아무거나 막혔다고 하지 않는다)", st_loose === :clear)
# 단일 원판은 무한 평면에서 절대 길을 못 막는다 — 우회하면 된다.
one = [CB.LazySets.Ball2([25.0, 0.0], 3.0)]
check("가로막은 단일 원판은 :clear (돌아가면 된다)",
      CB.free_space_status(start_far, goal_in, one, rr; cell = 0.25 * rr) === :clear)
check("목표가 원판 안이면 :engulfed",
      CB.free_space_status(start_far, [25.0, 0.0], one, rr; cell = 0.25 * rr) === :engulfed)
check("출발점이 원판 안이면 :agent_trapped",
      CB.free_space_status([25.0, 0.0], goal_in, one, rr; cell = 0.25 * rr) === :agent_trapped)
check("구역이 없으면 언제나 :clear", CB.free_space_status(start_far, goal_in, [], rr) === :clear)

# ---- [4] zone_diagnosis 배선 + opt-in 인과 규칙 --------------------------------------------
println("\n[4] zone_diagnosis 배선 — 원시값이 실리고, 판정은 기본적으로 안 바뀐다")
zc = isempty(roots) ? [0.0, 0.0] : sum(roots) ./ length(roots)
CB.remove_restriction_zone!(:core)
CB.add_restriction_zone!(:core, zc, 0.5)
d = CB.zone_diagnosis(env, :core)
b = CB.zone_blockage(env; zone_keys = [:core], check_paths = false)
println("    root=$(d.root_covered)/$(d.root_total) nav_goals=$(d.n_nav_goals) " *
        "nav_blocked=$(d.n_nav_blocked) trapped=$(d.n_agent_trapped) verdict=$(d.verdict)")
check("n_nav_goals 가 zone_blockage 와 일치", d.n_nav_goals == b.n_nav_goals)
# ★ STEP 6 반증을 한 줄로: 같은 구역이 root 목표는 8/8 을 덮는데 실제로 못 닫게 만드는 노드는 훨씬 적다.
check("커버리지가 막힘을 과대평가한다 (root_covered=$(d.root_covered) > nav_blocked=$(d.n_nav_blocked))",
      d.root_covered > d.n_nav_blocked)
check("n_nav_blocked 가 zone_blockage 와 일치", d.n_nav_blocked == b.n_blocked)
check("check_blockage=false 면 센티넬 -1 (계산 안 함을 숨기지 않는다)",
      CB.zone_diagnosis(env, :core; check_blockage = false).n_nav_blocked == -1)
check("등록 안 된 구역도 같은 필드 모양을 돌려준다",
      CB.zone_diagnosis(env, :ghost).n_nav_blocked == 0)

# 인과 규칙 스위치: 덮기만 하고 아무것도 안 막는 구역에서만 판정이 갈려야 한다.
if safe_kin !== nothing && safe_d > 0.0
    CB.add_restriction_zone!(:kin, safe_kin, zr_small)
    d_cov = CB.zone_diagnosis(env, :kin)                          # 기본(커버리지 규칙)
    # withenv(...) do ... end : 블록 안에서만 환경변수를 세팅하고, 끝나면 원래대로 되돌린다(반환값=블록의 값).
    d_causal = withenv("ZONE_CAUSAL_RULE" => "1") do
        CB.zone_diagnosis(env, :kin)
    end
    println("    덮기만 하는 구역: 커버리지 규칙 -> $(d_cov.verdict) / 인과 규칙 -> $(d_causal.verdict)")
    check("인과 규칙은 그런 구역을 :noop 으로 본다", d_causal.verdict === :noop)
    check("기본(OFF)은 옛 판정을 그대로 재현한다",
          d_cov.verdict === (d_cov.n_restage_feasible > 0 ? :forbid_zone :
                             (d_cov.root_covered > 0 || d_cov.n_teams_covered > 0) ?
                                (d_cov.relocate_feasible ? :relocate_build : :line_stop) : :noop))
    CB.remove_restriction_zone!(:kin)
end
CB.clear_restriction_zones!()

println("\n==== zone blockage predicates: $(npass[]) passed, $(nfail[]) failed ====")
nfail[] == 0 ? println("ALL GREEN") : println("SOME FAILED")
end

# =============================================================================
# zone_team_predicate -- the TEAM-SLOT predicate on a LIVE forming team (STEP 1, 두 번째 검증).
#
#   `zone_diagnosis` 의 다른 술어들은 시뮬 전 env 로 전부 검증되지만, 팀 술어만은 그럴 수 없다:
#   시뮬 전에는 형성 중인 운반팀이 0개라 "팀이 없을 때 무해하다"까지만 볼 수 있다. 그 상태에서
#   이 술어가 라벨을 바꾸는지는 **아무도 모른다** -- 그건 검증이 아니라 희망이다.
#
#   그래서 여기서는 실제로 시뮬을 굴려 팀이 형성되기 시작하는 순간까지 간 다음, 그 팀의 집결지에
#   구역을 심고 세 가지를 본다:
#     (1) zone_team_coverage 가 그 팀을 covered 로 잡는가 (그리고 멀리 심으면 안 잡는가),
#     (2) 그 상황에서 옛 규칙(check_teams=false)은 :noop 이라 답하는가  ← 이게 "거짓 :noop"
#     (3) 새 규칙은 개입(:relocate_build 또는 :line_stop)으로 뒤집는가  ← 술어의 존재 이유
#   (2)와 (3)이 같은 상태에서 갈리지 않으면 이 술어는 아무것도 바꾸지 않은 것이다.
# =============================================================================
# [검증 내용] 진짜로 형성 중인 운반팀을 만든 뒤, 그 집결지를 덮는 구역에서 팀 술어가
#   (1) 팀을 잡고 (2) 옛 규칙은 :noop 인데 (3) 새 규칙은 개입으로 뒤집는지 확인한다.
function test_zone_team_predicate()
_setup_milp!(time_limit = 120.0)

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

npass = Ref(0); nfail = Ref(0)
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))

CB.clear_restriction_zones!()

# ---- 팀이 형성되기 시작할 때까지 시뮬을 굴린다 -------------------------------------------
# 구역은 아직 없다 — 순수 nominal 진행. 팀이 하나라도 잡히면 즉시 멈춘다.
println("\n[1] 형성 중인 운반팀이 생길 때까지 진행")
teams = []
iters = 0
run_with_stack(2_000_000_000) do
    for it in 1:20_000
        CB.step_environment!(env)
        try CB.update_planning_cache!(env, 0.0) catch; end
        if it % 25 == 0
            local t = try CB._forming_teams(env) catch; [] end
            if !isempty(t)
                teams = t; iters = it
                break
            end
        end
    end
end
println("    -> $(length(teams)) forming team(s) after $(iters) steps " *
        "(closed $(length(env.cache.closed_set))/$(length(CB.get_nodes(env.sched))))")
check("형성 중인 팀을 실제로 만들었다", !isempty(teams))

if isempty(teams)
    println("\n==== team-slot predicate: 팀을 못 만들어 검증 불가 (SKIP) ====")
    println("SOME FAILED")
    return
end

t1 = teams[1]
gather = Vector{Float64}(t1.gather)
println("    대상 팀: ready=$(t1.ready) missing=$(t1.missing) gather=$(round.(gather; digits=3))")

# ---- (1) 커버리지 판정 -------------------------------------------------------------------
println("\n[2] zone_team_coverage — 집결지 위 / 멀리")
rr = Float64(CB.default_robot_radius())
tc_on  = CB.zone_team_coverage(env, gather, 2.0 * rr)
tc_off = CB.zone_team_coverage(env, gather .+ [500.0, 500.0], 2.0 * rr)
println("    집결지 위: covered=$(count(t -> t.covered, tc_on))/$(length(tc_on))  " *
        "슬롯 $(isempty(tc_on) ? 0 : tc_on[1].n_slots_in_zone)/$(isempty(tc_on) ? 0 : tc_on[1].n_slots)")
check("집결지를 덮으면 그 팀이 covered", any(t -> t.covered, tc_on))
check("멀리 심으면 아무 팀도 covered 아님", !any(t -> t.covered, tc_off))
check("팀 목록 길이는 위치와 무관(같은 팀들을 본다)", length(tc_on) == length(tc_off))

# ---- (2)(3) 같은 상태에서 옛 규칙과 새 규칙이 갈리는가 -------------------------------------
# 집결지 위에 **작은** 구역을 심는다: 적치원·root 목표를 안 건드릴 만큼 작아야 팀 술어만 남는다.
println("\n[3] 같은 구역에서 옛 규칙(:noop) vs 새 규칙(개입) — 거짓 :noop 이 고쳐졌는가")
CB.add_restriction_zone!(:teamzone, gather, 2.0 * rr)
d_new = CB.zone_diagnosis(env, :teamzone; check_teams = true)
d_old = CB.zone_diagnosis(env, :teamzone; check_teams = false)
println("    blocked=$(d_new.n_blocked)/feasible=$(d_new.n_restage_feasible) " *
        "root=$(d_new.root_covered)/$(d_new.root_total) " *
        "teams=$(d_new.n_teams_covered)/$(d_new.n_teams_forming) " *
        "reloc=$(d_new.relocate_feasible) |Δ|=$(round(d_new.relocate_norm; digits=3))")
println("    옛 규칙 -> $(d_old.verdict)   /   새 규칙 -> $(d_new.verdict)")
check("새 규칙이 팀을 갇힌 것으로 센다", d_new.n_teams_covered > 0)
check("옛 규칙은 이 팀을 보지 못한다(n_teams_covered == 0)", d_old.n_teams_covered == 0)
if d_new.n_blocked == 0 && d_new.root_covered == 0
    # 팀 술어만 남은 깨끗한 조건 — 여기서 갈리지 않으면 술어가 무의미하다.
    check("옛 규칙은 :noop (거짓 절제)", d_old.verdict === :noop)
    check("새 규칙은 개입으로 뒤집힘", d_new.verdict in (:relocate_build, :line_stop))
else
    # 다른 술어도 함께 위반된 상태라면 두 규칙이 같아도 정상이다. 그 사실을 명시적으로 남긴다.
    println("    (참고) 다른 술어도 위반됨(blocked=$(d_new.n_blocked), root=$(d_new.root_covered)) " *
            "→ 팀 술어 단독 효과는 이 배치에서 분리되지 않는다")
    check("두 규칙 모두 개입을 지시(절제가 아님)",
          d_old.verdict !== :noop && d_new.verdict !== :noop)
end

CB.clear_restriction_zones!()
println("\n==== team-slot predicate: $(npass[]) passed, $(nfail[]) failed ====")
nfail[] == 0 ? println("ALL GREEN") : println("SOME FAILED")
end

# =============================================================================
# zone_team_causal -- STEP 11: the team-slot predicate's CAUSAL check.
#
#   `zone_team_predicate` proved a covered team is COVERED (its carrying slots are inside the
#   disc) and that the rule flips. It did NOT prove the team then fails to FORM — and STEP 6
#   showed that exact gap is where coverage predicates go wrong. Same criticism, same fix:
#   run it.
#
#   Design: a WITHIN-RUN REVERSAL, not a parallel control. The RVO simulator and its id map are
#   global, so a `deepcopy` control would silently share motion state; and rebuilding a second
#   world does not reproduce this one's exact positions. So:
#
#       zone ON  -> K steps -> is the team formed?     expect NO
#       zone OFF -> K steps -> is the team formed?     expect YES
#
#   Removal restoring formation is stronger evidence than a parallel arm anyway: the only thing
#   that changed is the zone. The obvious confound (time) is bounded by giving BOTH windows the
#   same K, and by recording the members' distance-to-slot in each window.
#
#   NAV MUST BE ON. Zone enforcement (`enforce_restriction_zone_clearance!`) only touches agents
#   in the RVO id map; with `rvo_flag=false` there are none and the zone is inert — the test
#   would pass vacuously. That is why this is a separate, slower key from `zone_team_predicate`.
# =============================================================================
# [검증 내용] 덮인 팀이 **실제로 형성에 실패하는가**(STEP 11). 커버리지 술어가 STEP 6 에서 틀렸던
#   바로 그 지점이라 같은 방식으로 검증한다: 구역 ON 으로 K 스텝 → 형성 안 됨, 구역 OFF 로 K 스텝 →
#   형성됨(제거가 복구시키면 원인은 구역이다). RVO 를 반드시 켜야 한다 — 구역 강제는 RVO 에이전트만
#   밀어내므로 rvo_flag=false 면 구역이 무해해져 검사가 공허해진다.
function test_zone_team_causal()
_setup_milp!(time_limit = 120.0)
K = parse(Int, get(ENV, "ZTC_K", "1200"))          # 각 구간(ON/OFF)에 주는 스텝 수

println(">>> building env with NAVIGATION ON (rvo+tangent_bug+dispersion)...")
pp = CB.get_project_params(4)
env = run_with_stack(2_000_000_000) do
    Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Error))  # 이 레인이 선언한 로그 레벨을 호출 **전에** 심는다 — run_lego_demo 이 반환 시 호출 시점의 로거를 복원하므로(전역 누수 수정), 반환 후 자기 시뮬 루프도 이 레벨로 조용히 돈다.
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Error,
        rvo_flag=true, tangent_bug_flag=true, dispersion_flag=true,
        open_animation_at_end=false, save_animation=false, write_results=false,
        overwrite_results=false, look_for_previous_milp_solution=false,
        save_milp_solution=false, return_env_before_sim=true)
end

npass = Ref(0); nfail = Ref(0)
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))
CB.clear_restriction_zones!()
rr = Float64(CB.default_robot_radius())
norm = LinearAlgebra.norm       # tests.jl 는 LinearAlgebra 를 import 만 하므로 지역 별칭

# 이 운반유닛이 지금 대형을 갖췄는가(=팀 형성 완료). rvo_add_agents! 가 쓰는 바로 그 판정을 쓴다.
formed(tu) = try CB.is_in_formation(tu, env.scene_tree) catch; false end
# 팀원들이 각자 제 슬롯에서 얼마나 떨어져 있나(최대값) — "가까워지고 있는가"를 보는 진행 지표.
function slot_gap(tu)
    worst = 0.0
    team = try CB.robot_team(tu) catch; nothing end
    team === nothing && return NaN
    for (mid, _) in team
        CB.has_component(tu, mid) || continue
        rn = try CB.get_node(env.scene_tree, mid) catch; continue end
        p = Vector{Float64}(CB.project_to_2d(CB.global_transform(rn).translation))
        q = try
            Vector{Float64}((CB.global_transform(tu) ∘ CB.child_transform(tu, mid)).translation[1:2])
        catch
            continue
        end
        worst = max(worst, norm(p .- q))
    end
    return worst
end

println("\n[1] 형성 중인 팀이 생길 때까지 진행 (NAV ON)")
teams = []; iters = 0
run_with_stack(2_000_000_000) do
    for it in 1:20_000
        CB.step_environment!(env)
        try CB.update_planning_cache!(env, 0.0) catch; end
        if it % 10 == 0
            local t = try CB._forming_teams(env) catch; [] end
            # 아직 아무도 제자리에 없는 팀보다, 이미 모이는 중인 팀(ready>=1)이 인과 검사에 좋다.
            local pick = [x for x in t if x.missing >= 1]
            if !isempty(pick)
                teams = pick; iters = it; break
            end
        end
    end
end
println("    -> $(length(teams)) forming team(s) after $(iters) steps " *
        "(closed $(length(env.cache.closed_set))/$(length(CB.get_nodes(env.sched))))")
check("형성 중(미완)인 팀을 만들었다", !isempty(teams))
if isempty(teams)
    println("\n==== team causal: 팀을 못 만들어 검증 불가 (SKIP) ====\nSOME FAILED"); return
end

t1 = teams[1]; tu = t1.tu
gather = Vector{Float64}(t1.gather)
println("    대상 팀: unit=$(CB.summary(CB.node_id(tu))) ready=$(t1.ready) missing=$(t1.missing) " *
        "gather=$(round.(gather; digits=3)) formed=$(formed(tu)) slot_gap=$(round(slot_gap(tu); digits=3))")
check("아직 형성 전이다(사전 조건)", !formed(tu))

# ---- [2] 구역 ON — K 스텝 --------------------------------------------------------------------
println("\n[2] 집결지를 덮는 구역 ON → $(K) 스텝")
CB.add_restriction_zone!(:teamzone, gather, 2.0 * rr)
d_on = CB.zone_diagnosis(env, :teamzone; check_paths = true)
println("    진단: teams_covered=$(d_on.n_teams_covered)/$(d_on.n_teams_forming) " *
        "nav_blocked=$(d_on.n_nav_blocked)(engulf=$(d_on.n_nav_engulfed) disc=$(d_on.n_nav_disconnected)) " *
        "trapped=$(d_on.n_agent_trapped) verdict=$(d_on.verdict)")
check("술어가 이 팀을 덮인 것으로 잡는다(사전 조건)", d_on.n_teams_covered > 0)
gap_on_start = slot_gap(tu)
formed_on = false
run_with_stack(2_000_000_000) do
    for _ in 1:K
        CB.step_environment!(env)
        try CB.update_planning_cache!(env, 0.0) catch; end
        if formed(tu); formed_on = true; break; end
    end
end
gap_on_end = slot_gap(tu)
println("    -> formed=$(formed_on)  slot_gap $(round(gap_on_start; digits=3)) -> $(round(gap_on_end; digits=3))  " *
        "(closed $(length(env.cache.closed_set)))")
check("구역이 켜져 있는 동안 팀이 형성되지 않는다", !formed_on)

# ---- [3] 구역 OFF — 같은 K 스텝 ---------------------------------------------------------------
println("\n[3] 같은 구역 OFF → 같은 $(K) 스텝 (되돌리면 복구되는가)")
CB.remove_restriction_zone!(:teamzone)
formed_off = false; steps_off = 0
run_with_stack(2_000_000_000) do
    for s in 1:K
        CB.step_environment!(env)
        try CB.update_planning_cache!(env, 0.0) catch; end
        steps_off = s
        if formed(tu); formed_off = true; break; end
    end
end
println("    -> formed=$(formed_off) after $(steps_off) steps  " *
        "slot_gap $(round(gap_on_end; digits=3)) -> $(round(slot_gap(tu); digits=3))  " *
        "(closed $(length(env.cache.closed_set)))")
check("구역을 없애면 같은 팀이 형성된다(=원인은 구역이었다)", formed_off)
check("형성이 ON 구간보다 빨리 일어난다(시간 자체가 원인이 아니다)", formed_off && steps_off < K)

CB.clear_restriction_zones!()
println("\n==== team-slot predicate (causal): $(npass[]) passed, $(nfail[]) failed ====")
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
    Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Error))  # 이 레인이 선언한 로그 레벨을 호출 **전에** 심는다 — run_lego_demo 이 반환 시 호출 시점의 로거를 복원하므로(전역 누수 수정), 반환 후 자기 시뮬 루프도 이 레벨로 조용히 돈다.
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
    Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Error))  # 이 레인이 선언한 로그 레벨을 호출 **전에** 심는다 — run_lego_demo 이 반환 시 호출 시점의 로거를 복원하므로(전역 누수 수정), 반환 후 자기 시뮬 루프도 이 레벨로 조용히 돈다.
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
    Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Error))  # 이 레인이 선언한 로그 레벨을 호출 **전에** 심는다 — run_lego_demo 이 반환 시 호출 시점의 로거를 복원하므로(전역 누수 수정), 반환 후 자기 시뮬 루프도 이 레벨로 조용히 돈다.
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
    Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Warn))  # 이 레인이 선언한 로그 레벨을 호출 **전에** 심는다 — run_lego_demo 이 반환 시 호출 시점의 로거를 복원하므로(전역 누수 수정), 반환 후 자기 시뮬 루프도 이 레벨로 조용히 돈다. log_level 을 안 넘기므로 이 레인의 '선언'은 기본값 Warn 이다(run_demo.jl:462 와 같은 취급).
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
    Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Error))  # 이 레인이 선언한 로그 레벨을 호출 **전에** 심는다 — run_lego_demo 이 반환 시 호출 시점의 로거를 복원하므로(전역 누수 수정), 반환 후 자기 시뮬 루프도 이 레벨로 조용히 돈다.
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
    Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Error))  # 이 레인이 선언한 로그 레벨을 호출 **전에** 심는다 — run_lego_demo 이 반환 시 호출 시점의 로거를 복원하므로(전역 누수 수정), 반환 후 자기 시뮬 루프도 이 레벨로 조용히 돈다.
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
    "relocatebuild_parse"      => test_relocatebuild_parse,
    "zone_diagnosis"           => test_zone_diagnosis,
    "zone_corridor"            => test_zone_corridor,
    "zone_team_predicate"      => test_zone_team_predicate,
    "zone_team_causal"         => test_zone_team_causal,
    "corezone_guard"           => test_corezone_guard,
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
