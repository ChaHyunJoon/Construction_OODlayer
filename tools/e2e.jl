# =============================================================================
# tools/e2e.jl -- consolidated ConstructionBots e2e / mock-LLM pipeline drivers.
#
# Every standalone tools/*_e2e.jl / full-loop / self-heal / spare-replace script is
# now a FUNCTION in module `E2E`, sharing common boilerplate (MILP setup +
# run_with_stack) defined ONCE. A CLI/ENV dispatcher at the bottom runs any one.
#
# Scenario keys:
#   full_loop     -- full-loop RESUME driver (LLM-free reassign)
#   spare_replace -- OOD 1-1 spare 1:1 hand-off done-gate (LLM-free replace_robot!)
#
# 🔴 2026-08-29: four scenarios were REMOVED with the Anthropic lane -- `mock_respec`,
# `mock_replace`, `selfheal`, `live_respec`. All four drove the Python `/propose` seam
# (`CB.llm_to_proposal`), whose only server implementation called `anthropic.Anthropic()`.
# The two `mock_*` ones needed no API key, but they mocked exactly that seam, and the
# Julia client they exercised is gone too. The surviving LLM lane is DSPy (:8077 /macro).
#
# Run:
#   julia +lts --project=. tools/e2e.jl <key>        (or  ENV E2E=<key>)
# e.g.
#   julia +lts --project=. tools/e2e.jl full_loop
#   E2E=spare_replace julia +lts --project=. tools/e2e.jl
# Each scenario reads its own ENV knobs at call time (see the comment above each function).
# These scenarios stand up local mock servers and/or run full sims -- run ONE at a time.
# =============================================================================

# =============================================================================
#  [한국어 설명] 이 파일 = ConstructionBots 의 "end-to-end(e2e) 통합 실행/검증" 드라이버 모음.
#
#  큰 그림(프로젝트에서의 역할):
#   ConstructionBots = 여러 로봇이 협력해 LEGO 구조물을 짓는 TAMP(작업+동작 계획) 시뮬레이터.
#   빌드 도중 예상 못 한 사건(OOD, out-of-distribution)이 터짐 → 로봇 고장, 중앙에 진입금지 구역 등.
#   이때 "respec 레이어"가 자연어(NL) 사건설명을 받아 → LLM(또는 mock/surrogate)이 → DSL 제약
#   (ForbidZone=진입금지구역 / ReplaceAgent=로봇 교체 등)으로 번역 → 검증(verify) → 계획 재수립(re-solve).
#   이 파일의 각 함수(scenario_*)는 그 전체 파이프라인이 실제로 동작하는지 한 번씩 끝까지 돌려보는 시험대.
#
#  시나리오(맨 아래 SCENARIOS 표의 키):
#   · full_loop    : 빌드 중간에 고장 주입→재배정(reassign)으로 "이어서" 완주(끝난 일은 다시 안 함).
#   · spare_replace: LLM 없이 replace_robot! 스페어 1:1 인계가 빌드를 "완주"시키는지 done-gate 검증.
#  🔴 2026-08-29: 네 시나리오(mock_respec·mock_replace·selfheal·live_respec)는 Anthropic 레인과
#     함께 삭제됐다 — 넷 다 파이썬 `/propose` 이음새를 탔고 그 서비스의 유일한 구현이
#     `anthropic.Anthropic()` 이었다. mock 둘은 API 키를 안 썼지만 바로 그 이음새를 흉내 낸
#     것이었고, 그것을 타던 줄리아 클라이언트(`llm_to_proposal`)도 이제 없다.
#
#  문법 참고(처음 보는 Julia 문법):
#   · module E2E ... end        : 이름공간. 안의 함수는 E2E.함수명 으로 호출.
#   · using / import            : using=이름 그대로 노출, import=모듈명.기능 형태로 씀. const CB = ... 는 별칭.
#   · f(x::Int)                 : x 가 Int 타입일 때만 적용되는 메서드(다중 디스패치). ::타입 = 타입 제약.
#   · :symbol (예: :zone, :ok)  : 심볼 = 가볍고 변하지 않는 이름표(문자열보다 빠른 식별자, enum 비슷).
#   · "a" => b                  : Pair(짝). Dict("k"=>v) 로 딕셔너리를 만들 때 씀.
#   · Dict/Ref/Vector{Float64}  : Ref{T}=한 칸짜리 가변 상자(클로저 안에서 값을 바꿔 밖으로 빼낼 때). {T}=원소 타입.
#   · x[]                       : Ref/원소 하나짜리 컨테이너의 "안의 값"을 읽거나(r[]) 쓰기(r[]=v).
#   · 조건 && 식 / 조건 || 식    : &&=앞이 참일 때만 뒤 실행, ||=앞이 거짓일 때만 뒤 실행(if 축약 관용구).
#   · do ... end                : 함수의 첫 인자로 넘기는 익명함수 블록. f(args) do x; ...; end 형태.
#   · @info / @warn / @__FILE__ : @ 로 시작하면 매크로(코드 변형). @info=로그 출력, @__FILE__=이 소스 경로.
#   · [x for x in xs if cond]   : comprehension(한 줄 리스트 생성). map+filter 를 한 번에.
#   · function f!(...) 관례       : 이름 끝 `!` = 인자(env 등)를 그 자리에서 직접 바꾸는 함수라는 표시.
#   · NamedTuple (status=:ok,...): 이름표 붙은 튜플. r.status 처럼 필드명으로 꺼냄(가벼운 구조체).
#   · ccall(:jl_new_task, ...)   : Julia 런타임의 C 함수를 직접 호출. 여기선 "큰 스택을 가진 새 태스크" 생성용.
#   · world-age                  : 함수 정의 "세대" 개념. 방금 정의한 메서드를 같은 프레임에서 부르면 에러 나는 함정(아래 참고).
# =============================================================================
module E2E
using ConstructionBots
# [KO] HTTP=mock LLM 서버/요청, JSON3=요청·응답 JSON 파싱, Graphs=스케줄(작업 의존)그래프,
#      Logging=로그레벨, HiGHS/JuMP=MILP(정수계획) 최적화기, LinearAlgebra=벡터 연산.
import HTTP, JSON3, Graphs, Logging, HiGHS, JuMP, LinearAlgebra
const CB = ConstructionBots         # [KO] 긴 패키지명을 CB 로 줄여 씀(별칭). 이후 CB.함수 로 호출.
const norm = LinearAlgebra.norm     # [KO] norm = 벡터 크기(길이). 두 위치의 거리 계산에 씀.

# ---- runtime-loaded decoupled layers (loaded ONCE, at module load) ----------
# The navigator layer is NOT compiled into the ConstructionBots package -- the self-heal
# script historically `CB.include`d its battery/metrics/ood_truth/ood_stream files at SCRIPT
# TOP LEVEL. Now that each script is a FUNCTION, doing those includes *inside* the function and
# then calling the freshly-defined methods in the SAME call frame raises a world-age error
# ("method too new to be called from this world context"). Loading navigator.jl here at MODULE
# load puts those methods in an OLDER world than any scenario call, reproducing the original
# top-level-include semantics. navigator.jl is the umbrella loader (it includes metrics/
# ood_truth/battery/ood_stream/... in dependency order -- see its header), so this ONE call
# covers the self-heal scenario's battery layer.
# [KO] navigator 레이어(배터리/지표/OOD 진실값 등)는 패키지에 컴파일돼 있지 않고 런타임에 include 함.
#      핵심 함정(world-age): 이 include 를 "함수 안"에서 하고 같은 호출 프레임에서 그 메서드를 부르면
#      "메서드가 너무 새것"이라는 에러가 남. 그래서 모듈 로드 시점(=여기)에 딱 한 번 include 하여
#      메서드를 더 "오래된 세대"에 심어둠 → 이후 어떤 시나리오에서 불러도 안전. (예전 top-level include 재현)
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))

# ---- shared helpers (defined ONCE) ------------------------------------------
# The set_default_milp_optimizer! block that appears (identically -- 300s/5.0 gap/MOI.Silent)
# in all 5 e2e scripts.
# [KO] MILP(작업배정 정수최적화) 기본 최적화기를 HiGHS 로 세팅하는 공통 준비함수.
#      time_limit=한 번 풀 때 최대 시간(초), mip_rel_gap=이 정도 오차면 "충분히 좋다"고 멈춤(=속도 우선).
#      함수 이름 끝 `!` = 전역 설정을 바꾸는 부작용. 인자 앞의 `;` = 이후는 keyword(이름지정) 인자.
function _setup_milp!(; time_limit = 300.0, mip_rel_gap = 5.0)
    CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())   # () -> ... : 최적화기를 새로 만드는 익명함수(팩토리)
    CB.clear_default_milp_optimizer_attributes!()             # 이전 속성 초기화
    CB.set_default_milp_optimizer_attributes!(
        "time_limit" => time_limit, "presolve" => "on", "mip_rel_gap" => mip_rel_gap,
        CB.MOI.Silent() => true)                              # MOI.Silent()=>true : 최적화기 로그 침묵
end

# The identical stack-growing task helper (throws on error, returns the result). Used by
# full_loop / spare_replace. (2026-08-29: mock_respec/mock_replace/selfheal, the other
# users of this helper, went with the Anthropic lane.)
# [KO] 함수 f 를 "아주 큰 스택(stacksize 바이트)을 가진 새 태스크"에서 돌리고 결과를 돌려줌.
#      왜? 빌드/시뮬은 재귀가 깊어 기본 스택으론 stack overflow 가 남 → 큰 스택 태스크로 우회.
#      에러가 나면 스택트레이스를 찍고 다시 throw(호출자에게 실패 전달). 결과는 res[] 로 빼냄.
function run_with_stack(f, stacksize::Int)
    # [KO] Ref = 한 칸짜리 가변 상자. 태스크(다른 실행맥락) 안에서 채운 값을 밖에서 읽으려는 통로.
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)  # done=완료 플래그(원자적)
    # [KO] ccall 로 Julia 런타임의 C 함수 jl_new_task 를 호출해 지정 스택크기의 태스크 생성.
    #      넘기는 익명함수: f() 실행→성공하면 res, 실패하면 err 에 담고, 끝나면 done=true.
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end   # 태스크를 예약·실행하고 끝날 때까지 대기(폴링)
    # [KO] 에러가 있으면(!== nothing) 화면에 찍고 다시 던짐. (&& 뒤는 앞이 참일 때만 실행)
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))
    return res[]
end

# =============================================================================
# full_loop -- Enabled-seam end-to-end driver for the RESUME full-loop.
#   Build a real env, run the sim to a mid-build state, inject an OOD (robot fault), and
#   confirm the build RESUMES through the verified reassignment and reaches project_complete
#   WITHOUT restarting finished work (closed_set never regresses). Drives the PRODUCTION seam
#   exactly as simulate! does: step_environment! -> respec_step! -> update_planning_cache!.
#   2026-08-29: LLM-free direct reassign is now the ONLY mode -- the auto-selected
#   "LLM seam" alternative went with the Anthropic lane, so RESPEC_FULLLOOP_NOLLM is
#   no longer read (this path is what that flag used to force).
# =============================================================================
# [KO] 시나리오3: 빌드 중간에 고장을 주입해도 "이어서(resume)" 끝까지 완주하는지 확인.
#      핵심 = 이미 끝난 작업(closed_set)이 절대 되돌아가지 않아야 함(monotone). 두 모드 자동선택:
#      LLM seam(서비스 있음) 또는 LLM 없이 직접 재배정(reassign). production 이음새와 동일 경로로 구동.
function scenario_full_loop()
_setup_milp!()

INJECT_AT_CLOSED = 24      # step to this many closed nodes, then inject the fault
                           # [KO] 완료수가 24 될 때까지 진행한 뒤 고장 주입
STEP_CAP         = 100_000 # hard cap on sim steps (build completes well before)
                           # [KO] 시뮬 스텝 상한(보통 이보다 훨씬 전에 완주)

# [KO] tractor env 를 큰 스택에서 빌드(시뮬 직전 상태). 여기선 nav 기능(RVO 등)을 꺼서 빠르게.
function build_env()
    pp = CB.get_project_params(4)   # tractor
    return run_with_stack(2_000_000_000) do
        Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Error))  # 이 레인이 선언한 로그 레벨을 호출 **전에** 심는다 — run_lego_demo 이 반환 시 호출 시점의 로거를 복원하므로(전역 누수 수정), 반환 후 자기 시뮬 루프도 이 레벨로 조용히 돈다.
        CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
            model_scale=pp[:model_scale], num_robots=pp[:num_robots],
            assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
            log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false,
            dispersion_flag=false, open_animation_at_end=false, save_animation=false,
            save_animation_along_the_way=false, write_results=false,
            overwrite_results=false, look_for_previous_milp_solution=false,
            save_milp_solution=false, return_env_before_sim=true)
    end
end

# Pick a still-valid robot on a PENDING transport team so the fault forces a real reassign.
# [KO] 고장 낼 로봇 고르기: 아직 안 끝난(pending) 운반팀에 속한 유효 로봇 → 고장 시 진짜 재배정이 강제됨.
function pick_faultable_agent(env)
    seen = CB.AbstractID[]     # [KO] 이미 본 로봇 id 모음(중복 방지)
    for v in Graphs.vertices(env.sched)
        node = CB.get_node_from_id(env.sched, CB.get_vtx_id(env.sched, v))
        node isa CB.RobotGo || continue       # [KO] RobotGo(로봇 이동 작업) 노드만 관심
        rid = try CB.entity(node).id catch; nothing end   # [KO] 노드가 가리키는 로봇 id(없으면 nothing)
        (rid isa CB.RobotID && CB.valid_id(rid) && !(rid in seen)) || continue   # 유효+처음 본 로봇만
        push!(seen, rid)
    end
    for rid in seen
        # [KO] 그 로봇이 pending 운반팀에 속해 있으면 그걸 반환(재배정이 필요한 후보)
        !isempty(CB.transport_teams_with_agent(env, rid; pending_only = true)) && return rid
    end
    return isempty(seen) ? nothing : first(seen)   # [KO] 없으면 아무 로봇이라도(또는 nothing)
end

# one production-seam step; returns the new closed count
# [KO] production 이음새 한 스텝: 물리전진 → respec 처리 → 캐시갱신. 새 완료수 반환.
function seam_step!(env)
    CB.step_environment!(env)
    CB.respec_step!(env)                      # no-op unless RESPEC_ENABLED[]
                                              # [KO] RESPEC_ENABLED 가 꺼져 있으면 아무것도 안 함
    CB.update_planning_cache!(env, 0.0)
    return length(env.cache.closed_set)
end

# [KO] 이 시나리오의 본체: 빌드→주입지점까지 진행→고장 주입(LLM 또는 직접 재배정)→완주까지 resume→판정.
function main()
    println(">>> building tractor env (slow, ~minutes)...")
    env = build_env()
    total = Graphs.nv(env.sched)
    println(">>> env ready: $total nodes, closed=$(length(env.cache.closed_set))")

    # --- phase 1: run to the injection point --------------------------------
    # [KO] 1단계: 완료수가 INJECT_AT_CLOSED 될 때까지(또는 완주하면 중단) 시뮬 진행.
    iters = 0
    while length(env.cache.closed_set) < INJECT_AT_CLOSED && iters < STEP_CAP
        seam_step!(env); iters += 1
        CB.project_complete(env) && break
    end
    n_inject = length(env.cache.closed_set)   # [KO] 고장 주입 직전의 완료수(되돌아가지 않아야 할 기준선)
    println(">>> reached injection point: closed=$n_inject after $iters steps")

    agent = pick_faultable_agent(env)
    agent === nothing && (println("!! no valid robot to fault — aborting"); return false)   # 고장 낼 로봇 없으면 중단

    # 🔴 2026-08-29: 예전엔 여기서 두 갈래였다 — 서비스가 살아 있으면 LLM 이음새
    #   (`push_ood!` → `respec_step!` → `llm_to_proposal` → :8000 `/propose`)로, 아니면
    #   직접 재배정으로. 그 `/propose` 레인이 Anthropic 레인과 함께 삭제됐으므로 갈래가
    #   하나만 남는다. `RESPEC_FULLLOOP_NOLLM` 은 이제 없는 손잡이다(항상 이 경로다).
    #   ⚠️ 이 시나리오가 재개(resume)에 대해 재던 성질은 그대로다 — 아래 closed_set 회귀
    #   검사와 완주 판정은 어느 갈래로 주입했든 같은 것을 봤다.
    println(">>> OOD inject (LLM-free): direct reassign of $agent")
    # [KO] 로봇 고장+재배정을 직접 호출. resume=이어서, admitted 아니면 중단.
    res = CB.fault_robot_and_reassign!(env, agent; resume = true, verbose = true)
    res.status == :admitted || (println("!! reassign $(res.status) — cannot resume"); return false)

    n_after = length(env.cache.closed_set)
    if n_after < n_inject
        println("❌ closed_set REGRESSED at commit: $n_inject -> $n_after"); return false   # [KO] 커밋에서 되돌아가면 실패
    end

    # --- phase 2: RESUME to completion --------------------------------------
    # [KO] 2단계: 완주까지 계속 진행하며, 완료수가 한 번이라도 줄면 monotone=false(되돌아감 감지).
    monotone = true; prev = n_after; resume_iters = 0
    while resume_iters < STEP_CAP
        c = seam_step!(env)
        c < prev && (monotone = false)     # [KO] 완료수가 감소 = 이미 끝낸 일을 다시 함 = 실패 신호
        prev = c; resume_iters += 1
        CB.project_complete(env) && break
    end
    CB.RESPEC_ENABLED[] = false   # leave the global switch off for any later use
                                  # [KO] 이후 사용을 위해 전역 스위치는 꺼둠

    done = CB.project_complete(env)
    ms = round(CB.makespan(env.sched), digits = 2)   # [KO] makespan = 전체 완료까지 걸리는 총 시간(작을수록 좋음)
    pass = done && monotone && n_after >= n_inject   # [KO] 완주 + 되돌아감 없음 + 커밋에서 안 줄어듦 = PASS
    println("="^70)
    println("RESULT  inject@closed=$n_inject  ->(commit) $n_after  ->(resume) $prev / $total")
    println("        complete=$done  monotone=$monotone  resume_steps=$resume_iters  makespan=$ms")
    println("        ", pass ? "✅ FULL LOOP PASS — reassigned and built to completion" :
                               "❌ FULL LOOP FAIL")
    println("="^70)
    return pass
end

ok = main()
exit(ok ? 0 : 1)   # [KO] PASS 면 종료코드 0, 아니면 1(스크립트 성공/실패를 셸에 알림)
end

# =============================================================================
# spare_replace -- OOD 1-1 Part A4 done-gate (LLM-free).
#   Builds a nav-ON env WITH 4 directional spare pools, steps to mid-build, faults an active
#   robot, hands its remaining chain to the nearest spare via replace_robot! (no MILP), and
#   resumes to completion. The core hypothesis test: does the spare 1:1 hand-off let the build
#   COMPLETE where reassignment double-books? Asserts: spares idle pre-fault; replace_robot!
#   -> :replaced; closed_set monotone; project_complete; faulted robot never crashes RVO.
#   ENV: FAULT_AT, NSPARE, FAULT_OBSTACLE, FAULT (0=control), PROJECT, TARGET, CLEAR_FAULTED,
#     PARK_RESTS, PARK_FAULTED, DYN_SERIAL, REFORM_TEAMS, REFORM_AT.
# =============================================================================
# [KO] 시나리오5: LLM 없이 replace_robot! 스페어 1:1 인계가 빌드를 "완주"시키는지 done-gate 검증.
#      가설 = 재배정(reassign)은 이중배정(double-book) 때문에 막히지만, 스페어 1:1 교체는 완주시킨다.
#      확인: 고장 전 스페어 유휴 → replace_robot!→:replaced → closed 단조증가 → project_complete → 고장로봇이 RVO 를 크래시내지 않음.
function scenario_spare_replace()
FAULT_AT = parse(Int, get(ENV, "FAULT_AT", "24"))   # [KO] 이 완료수까지 진행한 뒤 고장 주입
NSPARE   = parse(Int, get(ENV, "NSPARE", "2"))       # [KO] pool 당 스페어 수(총 4*NSPARE)
FAULT_OBSTACLE = get(ENV, "FAULT_OBSTACLE", "1") == "1"   # diag: drop a static obstacle on the dead robot?
                                                          # [KO] 죽은 로봇 자리에 정적 장애물을 둘지(== "1" 로 bool 화)
DO_FAULT = get(ENV, "FAULT", "1") == "1"                  # diag: FAULT=0 => control (spares present, no fault/replace)
                                                          # [KO] FAULT=0 이면 대조군: 스페어만 있고 고장/교체 없이 완주하나?

_setup_milp!()

# [KO] 통과/실패 카운터 + 검사 헬퍼(다른 시나리오와 동일 패턴).
npass = Ref(0); nfail = Ref(0)
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))

PROJECT = parse(Int, get(ENV, "PROJECT", "4"))   # 4=tractor(team carries), 1=colored_8x8(flat, solo)
                                                 # [KO] 4=팀운반 tractor, 1=단독운반 평면 모델
pp = CB.get_project_params(PROJECT)
println(">>> building nav-ON env ($(pp[:project_name])) WITH $(4*NSPARE) spares ($(NSPARE)/pool)...")
CB.clear_spare_pools!(); CB.clear_faulted_robots!(); CB.clear_restriction_zones!()
ENV0 = run_with_stack(2_000_000_000) do
    Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Error))  # 이 레인이 선언한 로그 레벨을 호출 **전에** 심는다 — run_lego_demo 이 반환 시 호출 시점의 로거를 복원하므로(전역 누수 수정), 반환 후 자기 시뮬 루프도 이 레벨로 조용히 돈다.
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Error,
        rvo_flag=true, tangent_bug_flag=true, dispersion_flag=true,
        n_spare_per_pool=NSPARE,
        open_animation_at_end=false, save_animation=false, write_results=false,
        overwrite_results=false, look_for_previous_milp_solution=false,
        save_milp_solution=false, return_env_before_sim=true)
end
println(">>> env: $(Graphs.nv(ENV0.sched)) nodes; spare pools = $(collect(keys(CB.spare_pools())))")

# PRE-FAULT scan: does the BASE env already have any FTU fed by the SAME robot twice?
# (tells us if the duplicate-feeder is pre-existing build structure vs replace-induced)
# [KO] 고장 전 사전 점검: 원본 env 에 이미 "같은 로봇이 한 FTU 를 두 번 먹이는" 중복이 있나?
#      = 중복feeder 버그가 원래 구조 탓인지, 교체(replace) 탓인지 구분하려는 것. let...end = 지역 스코프.
let sched = ENV0.sched
    dup = 0
    for v in Graphs.vertices(sched)
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.FormTransportUnit || continue   # [KO] FTU(운반팀 형성) 노드만
        ids = Int[]
        for vp in Graphs.inneighbors(sched, v)   # [KO] 이 FTU 를 먹이는 선행(inneighbor) 노드들
            pn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vp))
            pn isa CB.RobotGo || continue
            r = try CB.entity(pn).id catch; nothing end
            r isa CB.RobotID && push!(ids, r.id)
        end
        if length(ids) != length(unique(ids))    # [KO] id 목록에 중복이 있으면(고유개수 < 전체개수)
            dup += 1
            dup <= 5 && println("[PRE-FAULT] FTU v=$v fed by robot ids $ids (DUPLICATE same-robot feeder)")
        end
    end
    println("[PRE-FAULT] FTUs with a same-robot duplicate feeder in BASE env: $dup")
end

env = deepcopy(ENV0)
total = Graphs.nv(env.sched)

# --- [1] spares present and IDLE (have an idle free node) pre-fault -------------
# [KO] [1] 고장 전: 스페어들이 등록돼 있고 모두 유휴(배정 안 됨) 상태인지 확인.
println("\n[1] spare pools idle pre-fault")
spares = CB.active_spares()
check("4*NSPARE spares registered", length(spares) == 4*NSPARE)
idle = count(s -> CB._idle_free_node(env.sched, s) !== nothing, spares)   # [KO] 유휴 노드를 가진 스페어 수
println("    -> $(idle)/$(length(spares)) spares have an idle free node")
check("all spares are idle (unassigned)", idle == length(spares))

# --- step helper: returns status NamedTuple --------------------------------------
# [KO] 시뮬을 특정 조건까지 진행시키는 헬퍼. until_closed 도달/완주/정체/상한 중 하나로 멈추고 상태 반환.
#      옵션(환경변수): DYN_SERIAL=스페어 frontier 직렬화, REFORM_TEAMS=끼인 팀 재형성, REFORM_AT=재형성 임계.
function step_to(env; until_closed=nothing, cap=250_000, stall_limit=8000)
    prev = length(env.cache.closed_set); stall = 0
    dyn = get(ENV, "DYN_SERIAL", "0") == "1"            # E1: dynamic serialization of spare frontiers
    reform = get(ENV, "REFORM_TEAMS", "0") == "1"       # ReformTeam: snap wedged teams on stall
    reform_at = parse(Int, get(ENV, "REFORM_AT", "1500"))   # no-progress steps before a re-formation
    for it in 1:cap
        CB.step_environment!(env)
        try CB.update_planning_cache!(env, 0.0) catch e
            return (status=:asserted, closed=length(env.cache.closed_set), iters=it, err=typeof(e))   # 캐시갱신 에러=실패
        end
        dyn && CB._enforce_serial_frontiers!(env)   # [KO] 켜져 있으면 스페어 작업을 순차로 강제
        c = length(env.cache.closed_set)
        stall = c > prev ? 0 : stall + 1; prev = c
        # CLOSED-LOOP: a sustained wedge -> re-form the stuck team(s), then keep going.
        # [KO] 오래 끼어 있으면(closed-loop) 끼인 팀을 재형성하고 정체 시계를 리셋한 뒤 계속.
        if reform && stall >= reform_at
            nmv = CB.reform_stuck_teams!(env)
            println("    [REFORM] stall=$stall -> repositioned $nmv straggler(s) into formation")
            stall = 0                                   # gave the team a chance; reset the wedge clock
        end
        until_closed !== nothing && c >= until_closed && return (status=:reached, closed=c, iters=it)   # 목표 완료수 도달
        CB.project_complete(env) && return (status=:complete, closed=c, iters=it)   # 완주
        stall >= stall_limit && return (status=:stalled, closed=c, iters=it)        # 정체
    end
    return (status=:capped, closed=prev, iters=cap)   # 상한 소진
end

# --- [2] step to mid-build -------------------------------------------------------
# [KO] [2] 빌드 중간(완료수 FAULT_AT)까지 진행. reached 로 멈춰야 정상.
println("\n[2] step to mid-build (target closed=$FAULT_AT)")
r1 = step_to(env; until_closed=FAULT_AT)
println("    -> $(r1.status) closed=$(r1.closed) iters=$(r1.iters)")
check("reached mid-build without assert/stall", r1.status == :reached)

# --- CONTROL: spares present, NO fault -> does the base build still complete? -----
# [KO] 대조군(FAULT=0): 스페어만 있고 고장/교체는 없이 완주하는지. 완주하면 "유휴 스페어 자체는 무해"가 증명됨.
if !DO_FAULT
    println("\n[CONTROL] spares present, NO fault -- run base build to completion")
    rc = step_to(env; cap=400_000)
    println("    -> $(rc.status) closed=$(rc.closed)/$total iters=$(rc.iters)")
    check("CONTROL base-with-spares completes", rc.status == :complete)
    CB.clear_spare_pools!(); CB.clear_faulted_robots!(); CB.clear_restriction_zones!()
    println("\n==== A4 CONTROL: $(npass[]) passed, $(nfail[]) failed ====")
    println(nfail[] == 0 ? "CONTROL GREEN (spares idle don't block; stall is the hand-off)" :
            "CONTROL FAILED (the idle spares themselves break the build)")
    exit(nfail[] == 0 ? 0 : 1)   # [KO] 대조군은 여기서 종료(교체 경로로 안 감)
end

# A CLEANLY-replaceable target: a robot at a free frontier (heading to its NEXT
# pickup, NOT mid-carry), so its hand-off doesn't strand an in-progress transport
# team. = an active RobotGo that is a `_first_pending_assignment` frontier whose
# robot is not also sitting in an active transport-unit team.
# [KO] "깔끔히 교체 가능한" 대상 고르기: 다음 픽업으로 가는 중(운반 중이 아닌) 로봇.
#      그래야 교체가 진행 중인 운반팀을 좌초시키지 않음. = pending frontier 이면서 활성 운반팀에 안 낀 로봇.
function pick_clean_target(env)
    sched = env.sched
    # [KO] 로봇 rid 가 지금 활성 운반팀에 끼어 있는지 판정(do 블록=any 에 넘기는 술어함수).
    in_active_team(rid) = any(env.cache.active_set) do v
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        (n isa CB.FormTransportUnit || n isa CB.TransportUnitGo) || return false
        team = try CB.robot_team(CB.entity(n)) catch; nothing end
        team !== nothing && haskey(team, rid)
    end
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.RobotGo || continue
        rid = try CB.entity(n).id catch; nothing end
        rid isa CB.RobotID || continue
        pend = CB._first_pending_assignment(env, rid)        # has a clean frontier + pending work
        pend === nothing && continue                          # [KO] 남은 일이 없으면 건너뜀
        in_active_team(rid) && continue                       # skip mid-carry robots (MVP scope)
                                                              # [KO] 운반 중 로봇은 제외(MVP 범위)
        return rid
    end
    return nothing
end

# A SOLO-transport target: a robot whose remaining (non-closed) transport tasks are
# ALL solo (team size 1). Faulting such a robot is the MVP-clean case: no OTHER robot
# is waiting for it as a co-carrier, so the single-spare hand-off has no multi-robot
# timing coordination to satisfy. (Multi-robot-carry faults are future work.)
# [KO] "단독운반(solo)" 대상 고르기: 남은 운반 작업이 전부 팀크기 1 인 로봇.
#      그런 로봇을 고장 내면 공동운반자를 기다리는 다른 로봇이 없어 = 스페어 1:1 교체에 타이밍 조율이 필요 없음(MVP 깔끔).
function pick_solo_target(env)
    sched = env.sched
    # map robot id -> set of team sizes of its non-closed FTU memberships
    # [KO] 로봇 rid 가 속한 (미완료) FTU 들의 팀크기 목록을 반환.
    function robot_team_sizes(rid)
        sizes = Int[]
        for v in Graphs.vertices(sched)
            v in env.cache.closed_set && continue   # [KO] 이미 끝난 건 제외
            n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
            n isa CB.FormTransportUnit || continue
            team = try CB.robot_team(CB.entity(n)) catch; nothing end
            team !== nothing && haskey(team, rid) && push!(sizes, length(team))
        end
        sizes
    end
    cands = CB.RobotID[]
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.RobotGo || continue
        rid = try CB.entity(n).id catch; nothing end
        rid isa CB.RobotID || continue
        CB._first_pending_assignment(env, rid) === nothing && continue   # has pending work
        sizes = robot_team_sizes(rid)
        (!isempty(sizes) && all(==(1), sizes)) || continue               # ALL solo
                                                                          # [KO] 팀크기가 전부 1 이어야 후보
        push!(cands, rid)
    end
    isempty(cands) && return nothing
    return sort(cands, by = r -> r.id)[1]                                # DETERMINISTIC: lowest id
                                                                         # [KO] id 가장 작은 것 선택(결정적=재현성)
end

# --- [3] fault a SOLO-transport robot (MVP-clean), hand off to nearest spare ------
# [KO] [3] solo 로봇 하나 고장 → 가장 가까운 pool 에서 스페어 꺼내 replace_robot! 로 남은 작업 인계.
println("\n[3] fault a solo-transport robot + replace_robot! with nearest spare")
mode = get(ENV, "TARGET", "solo")   # [KO] 대상 선정 모드: solo/clean/그외(아무 활성 로봇)
faulted = mode == "solo" ? pick_solo_target(env) :
          mode == "clean" ? pick_clean_target(env) : CB._pick_active_robot(env)
faulted === nothing && (println("    (no solo target; falling back to clean)"); faulted = pick_clean_target(env))  # solo 없으면 clean 으로
faulted === nothing && (faulted = CB._pick_active_robot(env))   # fallback if none clean
                                                                # [KO] 그래도 없으면 아무 활성 로봇
println("    -> faulting robot R$(faulted === nothing ? "?" : faulted.id)")
check("found an active robot to fault", faulted !== nothing)
clear_faulted = get(ENV, "CLEAR_FAULTED", "0") == "1"     # tow dead robot off-grid (demo config)
                                                          # [KO] 죽은 로봇을 그리드 밖으로 견인할지(데모 설정)
nl = CB.fault_robot!(env; target=faulted, obstacle=FAULT_OBSTACLE, clear=clear_faulted)   # [KO] 실제 고장 처리 + NL 반환
println("    -> clear_faulted = $clear_faulted")
println("    -> fault obstacle registered: $FAULT_OBSTACLE")
println("    -> NL: $nl")
fpos = CB._robot_position_2d(env, faulted)   # [KO] 고장 로봇의 현재 2D 위치
pool = CB.nearest_pool(fpos)                 # [KO] 그 위치에서 가장 가까운 스페어 pool
println("    -> nearest pool = $(pool)")
check("a nearest spare pool exists", pool !== nothing)
spare = CB.pop_spare!(pool)                  # [KO] 그 pool 에서 스페어 하나 꺼냄(소모)
println("    -> donating spare R$(spare === nothing ? "?" : spare.id) from :$(pool)")
check("popped a spare from the pool", spare !== nothing)
park_rests = get(ENV, "PARK_RESTS", "1") == "1"   # [KO] 인계 후 남는 잔여 작업을 주차(park)할지
println("    -> park_rests = $park_rests")
res = CB.replace_robot!(env, faulted, spare; resume=true, park_rests=park_rests)   # [KO] 핵심: 고장로봇→스페어 1:1 인계
println("    -> replace_robot! status=$(res.status) slots=$(get(res,:slots,-1)) serialized=$(get(res,:serialized,-1)) fg=$(get(res,:fg,-1)) slot1=$(get(res,:slot1,-1))")
# DIAG R3: optionally PARK the faulted robot's dead frontier (force-close fg) so the
# faulted robot leaves the active frontier entirely, then rebuild the resume cache.
if get(ENV,"PARK_FAULTED","0") == "1" && haskey(res,:fg)
    # [KO] 진단옵션: 고장 로봇의 죽은 frontier(fg)를 강제로 닫아(active→closed) 활성에서 완전히 빼고 캐시 재구성.
    fg = res.fg
    fg in env.cache.active_set && delete!(env.cache.active_set, fg)
    push!(env.cache.closed_set, fg)
    CB.reset_cache_resume!(env.cache, env.sched)
    println("    -> PARK_FAULTED: force-closed faulted dead frontier fg=$fg; rebuilt cache")
end
check("replace_robot! -> :replaced", res.status == :replaced)      # [KO] 교체가 성공했는가
check("hand-off moved >=1 downstream task", get(res,:slots,0) >= 1) # [KO] 인계된 하위작업이 1개 이상인가

# --- [4] resume to completion (the done-gate) ------------------------------------
# [KO] [4] 교체 후 완주까지 진행 = 이 시나리오의 핵심 관문(done-gate). closed 가 되돌아가지 않아야 함.
println("\n[4] resume to completion")
closed_after_replace = length(env.cache.closed_set)   # [KO] 교체 직후 완료수(되돌아감 판정 기준)
r2 = step_to(env; cap=400_000)
println("    -> $(r2.status) closed=$(closed_after_replace) -> $(r2.closed)/$total iters=$(r2.iters)$(haskey(r2,:err) ? "  err=$(r2.err)" : "")")
check("closed_set monotone across replace (no regress)", r2.closed >= closed_after_replace)   # 단조증가(되돌아감 없음)
check("no RVO/identity assert on the faulted robot", r2.status != :asserted)   # 고장 로봇이 크래시 안 냄
check("PROJECT COMPLETE (core done-gate)", r2.status == :complete)             # 핵심: 완주했는가

# --- [5] stall diagnosis: dump the active frontier + faulted/spare involvement ----
# [KO] 노드 n 에서 로봇 id 를 안전하게 뽑는 헬퍼(없으면 nothing). rid = robot id.
_rid(n) = (try entity(n).id catch; nothing end)
# [KO] 정체 진단: 활성 frontier 를 덤프하고 그중 고장로봇(fid)/스페어(sid)가 어디에 얽혀 있는지 표시.
#      고장로봇이 아직 몇 개 노드에 묶였는지, 스페어가 pool 밖으로 나와 자기 작업으로 이동했는지 등.
function diagnose_stall(env, fid, sid)
    sched = env.sched
    println("    faulted=R$(fid===nothing ? "?" : fid.id)  spare=R$(sid===nothing ? "?" : sid.id)")
    nactive = 0
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        rid = _rid(n)
        tag = rid === nothing ? "" : (rid == fid ? "  <== FAULTED" : (rid == sid ? "  <== SPARE" : "  (R$(rid.id))"))
        nactive += 1
        nactive <= 40 && println("      active: $(typeof(n).name.name)$(tag)")
    end
    println("    total active frontier nodes: $nactive")
    isbound(n, who) = (n isa CB.RobotGo) && (_rid(n) == who)   # [KO] 노드 n 이 로봇 who 의 RobotGo 인지
    # [KO] fleft/sleft = 고장로봇/스페어가 아직 묶여 있는 "미완료 RobotGo" 개수. count(...) do v = 조건 만족 개수.
    fleft = fid === nothing ? 0 : count(Graphs.vertices(sched)) do v
        !(v in env.cache.closed_set) && isbound(CB.get_node_from_id(sched, CB.get_vtx_id(sched, v)), fid)
    end
    sleft = sid === nothing ? 0 : count(Graphs.vertices(sched)) do v
        !(v in env.cache.closed_set) && isbound(CB.get_node_from_id(sched, CB.get_vtx_id(sched, v)), sid)
    end
    println("    faulted robot still bound to $fleft non-closed RobotGo(s) (dead frontier fg expected = 1)")
    println("    spare   robot still bound to $sleft non-closed RobotGo(s) (its remaining adopted work)")
    # classify the stuck frontier by node type
    types = Dict{Symbol,Int}()
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        t = typeof(n).name.name
        types[t] = get(types, t, 0) + 1
    end
    println("    active frontier by type: $types")
    # did the spare actually move out of its pool toward its work?
    if sid !== nothing
        spos = CB._robot_position_2d(env, sid)
        pc = get(CB.spare_pool_centers(), :east, nothing)
        for (k, c) in CB.spare_pool_centers()   # find the pool the spare came from (nearest center)
            pc === nothing && (pc = c)
        end
        # nearest goal among the spare's active RobotGo nodes
        sgoal_d = Inf
        for v in env.cache.active_set
            n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
            (n isa CB.RobotGo && _rid(n) == sid) || continue
            g = try Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.goal_config(n)).translation)) catch; continue end
            sgoal_d = min(sgoal_d, norm(spos .- g))
        end
        println("    spare pos=$(round.(spos;digits=2)); dist to its nearest active goal=$(round(sgoal_d;digits=2)) (robot_r=$(round(CB.default_robot_radius();digits=3)))")
    end
end
# FTU formation diagnosis: for every active RobotGo whose next node is a
# FormTransportUnit, dump the team's per-member capture status (route_planning.jl:480
# requires ALL members in position simultaneously). Pinpoints who is blocking.
# [KO] FTU 형성 진단: 다음이 FormTransportUnit 인 활성 RobotGo 마다, 팀원 각자가 제자리(capture)에 왔는지 표시.
#      FTU 는 팀원 "전원"이 동시에 자리 잡아야 발동 → 누구 하나 안 오면 팀 전체가 막힘. 그 범인을 짚어냄.
function diagnose_ftu(env)
    sched = env.sched; st = env.scene_tree
    fr = CB.faulted_robots()
    shown = 0
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.RobotGo || continue
        outs = Graphs.outneighbors(sched, v); isempty(outs) && continue
        nxt = CB.get_node_from_id(sched, CB.get_vtx_id(sched, outs[1]))
        nxt isa CB.FormTransportUnit || continue
        feeder = _rid(n)   # [KO] 이 FTU 를 먹이는 로봇 id
        atgoal = CB.is_within_capture_distance(CB.global_transform(CB.entity(n)),   # [KO] feeder 가 자기 목표에 도달했나
                                               CB.global_transform(CB.goal_config(n)))
        # inneighbor readiness (route_planning.jl:474-478)
        inn = Graphs.inneighbors(sched, outs[1])
        inn_ready = all(vp -> (vp in env.cache.active_set) || (vp in env.cache.closed_set), inn)   # [KO] 선행들이 전부 준비됐나
        tu = CB.entity(nxt); team = CB.robot_team(tu)   # [KO] tu=운반유닛, team=팀원(로봇id->슬롯) 딕셔너리
        shown += 1
        shown > 6 && (println("    ... (more FTUs)"); break)   # [KO] 너무 많으면 6개까지만
        ftuv = outs[1]
        dep = CB._adopted_task_deposit(env, v)
        # --- STEP 0: slot goal_config(SCHEDULE) vs tu's expected capture slot(SCENE) drift ---
        # feeder_at_goal targets global_transform(goal_config(slot)); in_capture targets
        # global_transform(tu) ∘ child_transform(tu, rid) (hierarchical_geom_essentials.jl:1032-33).
        # If these disagree the spare can satisfy in_capture but never feeder_at_goal -> FTU never fires.
        # [KO] drift(어긋남) = "스케줄상 슬롯 목표"와 "장면상 실제 캡처 슬롯"의 위치 차이.
        #      둘이 다르면 스페어가 in_capture 는 만족해도 feeder_at_goal 은 영영 못 채워 FTU 가 안 켜짐(교체 함정).
        #      ∘ = 변환 합성(먼저 오른쪽, 그다음 왼쪽). NaN=계산못함, -1.0=예외.
        drift = NaN
        if feeder !== nothing
            try
                slot_goal = CB.global_transform(CB.goal_config(n))   # 스케줄상 슬롯의 목표 자세
                ct        = CB.child_transform(tu, feeder)            # tu 기준 이 feeder 의 자식 변환
                expected  = CB.global_transform(tu) ∘ ct             # 장면상 기대되는 캡처 위치
                drift = norm(Vector{Float64}(slot_goal.translation[1:2]) .-
                             Vector{Float64}(expected.translation[1:2]))   # 두 위치의 2D 거리
            catch e
                drift = -1.0
            end
        end
        println("    [slot v=$v -> FTU v=$ftuv -> deposit v=$(dep)] fed by R$(feeder===nothing ? "?" : feeder.id) (feeder_at_goal=$atgoal, inneighbors_ready=$inn_ready, GOAL_DRIFT=$(round(drift;digits=3))), team=$(length(team)):")
        for (mid, _) in team   # [KO] 팀원마다: 제자리(in_capture)에 왔는지 점검. mid=팀원 로봇 id.
            rn = try CB.get_node(st, mid) catch; nothing end   # [KO] 장면트리에서 그 로봇 노드
            rn === nothing && (println("      member R$(mid.id): <no scene node>"); continue)
            incap = CB.is_within_capture_distance(tu, rn)   # [KO] tu 의 캡처 자리에 이 팀원이 들어왔나
            ftag = haskey(fr, mid) ? " [FAULTED]" : (mid == spare ? " [SPARE]" : "")   # 고장/스페어 태그
            # for a member NOT in position, locate it: pos, whether it's a ROOT (drivable) or
            # captured elsewhere, its active node type, and dist to its nearest active goal.
            extra = ""
            if !incap
                pos = try Vector{Float64}(CB.project_to_2d(CB.global_transform(rn).translation)) catch; [NaN,NaN] end
                isroot = try CB.has_parent(rn, rn) catch; "?" end
                # find this member's active node(s)
                mact = Int[]; mgoal_d = Inf
                for vv in env.cache.active_set
                    nn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vv))
                    (_rid(nn) == mid) || continue
                    push!(mact, vv)
                    g = try Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.goal_config(nn)).translation)) catch; continue end
                    mgoal_d = min(mgoal_d, norm(pos .- g))
                end
                acttypes = join([string(typeof(CB.get_node_from_id(sched,CB.get_vtx_id(sched,vv))).name.name) for vv in mact], ",")
                extra = "  pos=$(round.(pos;digits=2)) root=$isroot active=[$acttypes] dist2goal=$(round(mgoal_d;digits=2))"
            end
            println("      member R$(mid.id): in_capture=$incap$ftag$extra")
        end
    end
    shown == 0 && println("    (no active RobotGo feeding a FormTransportUnit found)")
    # find any FTU with >1 spare feeder (the duplicate-feeder bug) and dump ALL its inneighbors
    # [KO] 같은 스페어가 한 FTU 를 2번 이상 먹이는 경우(=이중배정 버그)를 찾아 그 FTU 의 모든 선행을 덤프.
    println("    --- FTUs with duplicate spare feeders (the bug) ---")
    seen_ftu = Set{Int}()
    for v in Graphs.vertices(sched)
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.FormTransportUnit || continue
        v in seen_ftu && continue
        ins = Graphs.inneighbors(sched, v)
        # [KO] 이 FTU 의 선행 중 "스페어가 먹이는 RobotGo" 만 골라냄(filter+begin...end 블록 술어).
        sp_feeders = filter(vp -> begin
            pn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vp))
            pn isa CB.RobotGo && _rid(pn) == spare
        end, ins)
        length(sp_feeders) >= 2 || continue   # [KO] 2개 이상일 때만(=중복) 리포트
        push!(seen_ftu, v)
        println("    FTU v=$v has $(length(sp_feeders)) spare feeders; ALL inneighbors:")
        for vp in ins
            pn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vp))
            rid = _rid(pn)
            cl = vp in env.cache.closed_set ? "closed" : (vp in env.cache.active_set ? "active" : "future")   # [KO] 노드 상태 분류
            ppreds = join([string(typeof(CB.get_node_from_id(sched,CB.get_vtx_id(sched,vpp))).name.name) for vpp in Graphs.inneighbors(sched,vp)], ",")   # 선행의 선행 유형들
            println("      in v=$vp $(typeof(pn).name.name) R$(rid===nothing ? "?" : rid.id) [$cl] <-preds[$ppreds]")
        end
    end
end
# [KO] 완주 못 했을 때만 [5][6][7] 상세 진단을 돌림(왜 막혔는지 추적용).
if r2.status != :complete
    println("\n[5] STALL DIAGNOSIS (active frontier at stall)")
    diagnose_stall(env, faulted, spare)
    println("\n[6] FTU FORMATION DIAGNOSIS (who blocks each pending transport team)")
    diagnose_ftu(env)
    println("\n[7] SPARE THREAD STRUCTURE (is the adopted work a single sequential chain?)")
    # [KO] [7] 스페어가 받은 일이 "하나의 순차 사슬"인지 점검. 동시에 활성인 RobotGo 가 2개 이상이면 병렬화돼 꼬임.
    let sched = env.sched
        nactive_spare = 0
        for v in Graphs.vertices(sched)
            n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
            (n isa CB.RobotGo && _rid(n) == spare) || continue
            v in env.cache.closed_set && continue
            preds = Graphs.inneighbors(sched, v)
            predinfo = join([begin
                pn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vp))
                pc = vp in env.cache.closed_set ? "closed" : (vp in env.cache.active_set ? "active" : "future")
                "$(typeof(pn).name.name)[$pc]"
            end for vp in preds], ",")
            isact = v in env.cache.active_set
            isact && (nactive_spare += 1)
            outs = Graphs.outneighbors(sched, v)
            sucinfo = join([begin
                sn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vs))
                "$(typeof(sn).name.name)"
            end for vs in outs], ",")
            isterm = isempty(outs)   # [KO] 후속이 없으면 사슬의 끝(terminal)
            t0 = try round(Float64(CB.get_t0(sched, v)); digits=2) catch; "?" end   # [KO] 이 작업의 시작시각
            atg = try CB.is_within_capture_distance(CB.global_transform(CB.entity(n)),
                                                    CB.global_transform(CB.goal_config(n))) catch; "?" end   # 목표 도달 여부
            println("    spare RobotGo v=$v active=$isact t0=$t0 at_goal=$atg terminal=$isterm  preds=[$predinfo]  succs=[$sucinfo]")
        end
        println("    => spare has $nactive_spare CONCURRENTLY ACTIVE RobotGo(s) (should be 1 for a sequential thread)")
    end
end

CB.clear_spare_pools!(); CB.clear_faulted_robots!(); CB.clear_restriction_zones!()   # [KO] 전역 상태 정리
println("\n==== A4 spare_replace_test: $(npass[]) passed, $(nfail[]) failed ====")
println(nfail[] == 0 ? "ALL GREEN (spare 1:1 hand-off completes the build)" :
        "SOME FAILED (see above; likely R1 frontier-graft / R3 faulted-driving -- diagnose)")
end

# =============================================================================
# 🔴 2026-08-29: `live_respec` 와 `selfheal` 시나리오를 **삭제**했다.
#   둘 다 :8000 의 파이썬 `/propose` 서비스가 떠 있어야 했고(ANTHROPIC_API_KEY 필요),
#   그 서비스의 유일한 구현이 `anthropic.Anthropic()` 이었다. 그 레인 전체가 죽은 것으로
#   실측돼 삭제됐으므로(:8000 에 아무도 없음, 키 없음, 실행 스크립트 없음) 두 시나리오는
#   되살릴 서비스가 없다. `mock_respec`·`mock_replace` 도 같은 이유로 사라졌다 —
#   API 키는 안 썼지만 둘 다 `CB.llm_to_proposal` 로 그 `/propose` 이음새를 탔고,
#   그 클라이언트가 이제 없다. 살아 있는 LLM 레인은 DSPy 하나이고 자기 이음새를 쓴다.
# =============================================================================


# ---- dispatcher -------------------------------------------------------------
# [KO] "시나리오 키 -> 실행 함수" 표. 아래 실행부에서 이 표로 하나를 골라 부름.
const SCENARIOS = Dict(
    "full_loop"     => scenario_full_loop,
    "spare_replace" => scenario_spare_replace,
)
end # module E2E

# [KO] 이 파일을 직접 실행했을 때만 아래가 돎(엔트리포인트). 다른 데서 include 만 하면 실행 안 됨.
if abspath(PROGRAM_FILE) == @__FILE__
    # [KO] 키 우선순위: 환경변수 E2E > 명령줄 첫 인자 > 기본값 "full_loop".
    key = get(ENV, "E2E", isempty(ARGS) ? "full_loop" : ARGS[1])
    # [KO] 표에 없는 키면 사용 가능한 목록을 알려주며 에러(|| = 앞이 false 일 때만 뒤 실행).
    haskey(E2E.SCENARIOS, key) || error("unknown scenario '$key'. Available: $(join(sort(collect(keys(E2E.SCENARIOS))), ", "))")
    println(">>> running e2e scenario: $key")
    E2E.SCENARIOS[key]()   # [KO] 고른 시나리오를 실제 실행
end
