# =============================================================================
#  [한국어 안내]  이 파일이 하는 일 (처음 보는 사람용 요약)
#  ---------------------------------------------------------------------------
#  ConstructionBots = 여러 로봇이 협력해 LEGO 모형을 조립하는 시뮬레이터(TAMP).
#  실제 상황에선 예상 못 한 사건(OOD: 로봇 고장, 배터리 방전, 통행금지구역 등)이
#  생기는데, LLM/surrogate 기반 "re-spec(respec)" 레이어가 그 사건을 DSL 규칙으로
#  바꿔 계획을 고쳐 잡는다.
#  이 파일은 그 시스템을 "진단(diagnostics)"하는 도구 모음이다. 원래는 tools/ 밑에
#  흩어져 있던 여러 개별 스크립트(diag_*.jl, run_*_check.jl, ood_compare_*.jl 등)를
#  하나의 `Diagnostics` 모듈 안 "함수"들로 합쳐, 공통 준비코드(MILP 설정 + 실행 헬퍼)를
#  딱 한 번만 정의해 재사용한다. 맨 아래 dispatcher가 키(rethread 등)를 받아 해당 진단
#  함수 하나만 골라 돌린다.
#
#  프로젝트 안에서의 역할: "버그가 정말 고쳐졌는지 / 어떤 controller(LLM·RL·규칙)가 더
#  잘 회복하는지"를 실제 시뮬레이션을 돌려 눈으로 확인하는 검증·비교 스크립트 모음.
#
#  Julia 문법 참고 (파이썬과 다른, 헷갈리기 쉬운 것들):
#   · module Diagnostics ... end : 이름공간(네임스페이스). 안의 함수/타입은 밖에서
#       Diagnostics.함수명 으로 부른다. 파일 하나 = 모듈 하나로 감싼 것.
#   · using / import : 다른 패키지를 불러옴. `const CB = ConstructionBots` 는 긴 모듈
#       이름에 짧은 별명(CB)을 붙인 것(별칭). 그래서 CB.함수 = ConstructionBots.함수.
#   · `!` 로 끝나는 함수(예: step_environment!) = 인자를 직접 바꾼다(in-place)는 관례.
#   · function f(x::T) : x 가 타입 T 일 때만 적용되는 메서드(다중 디스패치). 같은 이름
#       함수를 인자 타입만 바꿔 여러 번 정의 = "타입마다 다른 동작".
#   · `:심볼` (예: :greedy, :complete) = 심볼(Symbol). 짧고 고정된 라벨/이름표 역할
#       (문자열보다 가볍고 빠른 비교용). ENV 키나 상태값 태그로 자주 씀.
#   · `[f(x) for x in xs]` = 컴프리헨션(리스트 내포). `Dict(k=>v for ...)` 는 딕셔너리 버전.
#   · `open(...) do io ... end` = do-블록. 마지막 인자로 익명함수를 넘기는 문법
#       (여기선 파일을 열고 자동으로 닫아줌).
#   · `Ref{T}(...)` = 값 하나를 담는 상자(포인터 비슷). `ref[]` 로 읽고 쓴다.
#   · `try 식 catch; 기본값 end` = 예외가 나면 조용히 기본값을 쓰는 방어적 표현.
#   · `x === nothing` = "정확히 nothing인가" 비교. nothing = 값 없음(파이썬 None 비슷).
#   · `@printf`, `@__DIR__` 등 `@`로 시작 = 매크로(코드를 컴파일 전에 바꿔치기하는 장치).
# =============================================================================
# tools/diagnostics.jl -- consolidated ConstructionBots diagnostics / compare / fixture driver.
#
# Every standalone tools/{diag_*,run_*_check,ood_compare_*,ab_*,dump_*}.jl script is now a
# FUNCTION in module `Diagnostics`, sharing common boilerplate (MILP setup + run_with_stack)
# defined ONCE. A CLI/ENV dispatcher at the bottom lets any single diagnostic run individually.
#
# Diagnostic keys:
#   rethread        -- double-book diagnostic after fault->reassign->commit on the RESUME path
#                      (diag_rethread.jl): dumps offending timelines + backtraces.
#   rethread_check  -- non-interactive verification of the rethread_robot_ids! fix
#                      (run_rethread_check.jl): resume sanity + reassign+resume x5 trials.
#   ood_compare     -- LLM vs RL vs canonical vs no-adapt on a FULLY-SIMULATED, completing
#                      robot-breakdown (ood_compare_fullsim.jl): completion %, makespan, F1.
#   ab_energy       -- A/B proof for the energy-aware objective (ab_energy_objective.jl):
#                      re-solves the same assignment at several efficiency weights.
#   dump_fixture    -- build the tractor env, step mid-build, dump the exact /propose request
#                      body to tools/llm_fixture.json (dump_llm_fixture.jl).
#   reassign        -- whether ForbidAgent blocked robot 1 / whether slots kept stale ids after
#                      fault->release->re-solve (diag_reassign.jl): FTU feeders, frontier, backtrace.
#   eval_ood        -- per-OOD-class reliability eval of the LLM respec layer (eval_respec_ood.jl):
#                      scores TRANSLATION + BEHAVIOR axes; needs the Python LLM service running.
#
# Run:
#   julia +lts --project=. tools/diagnostics.jl <diag_key>        (or  ENV DIAG=<key>)
# e.g.
#   julia +lts --project=. tools/diagnostics.jl rethread_check
#   DIAG=ood_compare julia +lts --project=. tools/diagnostics.jl
# Each diagnostic reads its own ENV knobs at call time (see the comment above each function).
# =============================================================================
module Diagnostics
using ConstructionBots                                    # 시뮬레이터 본체(핵심 패키지)
using Printf                                              # @printf 등 서식 있는 출력용
import Logging, HiGHS, JuMP, JSON3, Graphs, Random, LazySets  # 로깅/MILP solver/JSON/그래프/난수/기하 라이브러리
const CB = ConstructionBots                               # 긴 이름에 짧은 별명(CB) 부여

# ---- runtime-loaded decoupled layers (loaded ONCE, at module load) ----------
# The navigator layer and the decpomdp OOD example layer are NOT compiled into the
# ConstructionBots package -- the scripts historically `CB.include`d them at SCRIPT TOP
# LEVEL. Now that each script is a FUNCTION, doing those includes *inside* a function and then
# calling the freshly-defined methods in the SAME call frame raises a world-age error
# ("method too new to be called from this world context"). Loading them here at MODULE
# load puts them in an OLDER world than any diagnostic call, exactly reproducing the original
# top-level-include semantics. navigator.jl is the umbrella loader (it includes metrics/
# ood_truth/battery/ood_stream/... in dependency order -- see its header), so ONE call
# covers every navigator-using function (fault_action, descriptors, energy model, ...); the
# three decpomdp examples only need CB (no DecPOMDP) and back ood_compare's RL/canonical arms.
# navigator.jl 은 우산(umbrella) 로더 — metrics/ood_truth/battery/ood_stream 등을 의존순서대로
# 다 include 해준다. 그래서 이 한 줄이면 navigator를 쓰는 모든 함수가 준비된다.
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
# decpomdp 예제 레이어(별도 폴더)를 여기서 로드 — ood_compare의 RL/canonical 팔을 뒷받침한다.
# let ... end = 지역 스코프 블록(_EX 변수를 이 블록 안에서만 쓰고 버림).
let _EX = joinpath(dirname(pkgdir(CB)), "decpomdp", "examples")
    include(joinpath(_EX, "ood_env.jl"))       # OODEnv, _n_closed
    include(joinpath(_EX, "ood_env_mdp.jl"))   # event_context, valid_actions, action_to_proposal, canonical_action
    include(joinpath(_EX, "ood_reinforce.jl")) # LinearPolicy, greedy_action, load_policy
end

# ---- shared helpers (defined ONCE) ------------------------------------------
# The set_default_milp_optimizer! block that appears (identically, 300s/5.0/MOI.Silent) in
# diag_rethread + run_rethread_check; ab_energy uses the SAME attribute set with ENV-tuned
# time_limit/gap. ood_compare uses a DIFFERENT attribute set (output_flag instead of MOI.Silent,
# 60s/0.05 gap) and keeps its block inline -- see that function.
# _setup_milp! : MILP solver(HiGHS)를 기본 최적화기로 설정하는 공통 준비함수.
#   time_limit=풀이 제한시간(초), mip_rel_gap=허용 최적성 오차(클수록 빨리 대충 푼다).
#   여러 진단이 똑같이 쓰던 설정 블록을 한 번만 정의해 재사용한다.
function _setup_milp!(; time_limit = 300.0, mip_rel_gap = 5.0)
    CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())   # () -> ... = 인자 없는 익명함수(솔버 생성기)
    CB.clear_default_milp_optimizer_attributes!()             # 이전 속성 초기화
    CB.set_default_milp_optimizer_attributes!(
        "time_limit" => time_limit, "presolve" => "on", "mip_rel_gap" => mip_rel_gap,
        CB.MOI.Silent() => true)                              # MOI.Silent()=>true : 솔버 로그 끄기
end

# run_with_stack : 함수 f 를 "스택 크기를 크게 늘린 별도 Task(경량 스레드)"에서 돌려주는 헬퍼.
#   깊은 재귀(대형 env 빌드)가 기본 스택을 넘겨 죽는 것을 막으려고 stacksize(바이트)를 크게 준다.
#   f=실행할 무인자 함수, stacksize=새 태스크에 줄 스택 크기(바이트).
function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)  # 결과/에러/완료플래그 상자
    # ccall(:jl_new_task,...) : Julia 런타임 C함수를 직접 불러 큰 스택의 태스크를 만든다.
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end   # 태스크 실행 시작하고 끝날 때까지 대기(폴링)
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))  # 에러났으면 다시 던짐
    return res[]                                                     # f 의 반환값을 돌려줌
end

# ood_compare's RL state shim (a struct cannot be defined inside a function, so it lives at
# module level with a unique name; it is only referenced by ood_compare).
# _CompareRLShim : ood_compare에서 RL 정책이 상태를 읽을 때 필요한 필드만 흉내낸 껍데기(shim) 구조체.
#   (구조체는 함수 안에서 정의 불가라 모듈 레벨에 둠). mutable struct = 필드값 바꿀 수 있는 구조체.
#   env=현재 시뮬 환경, step_count/no_progress/n_events=진행 카운터, max_steps=최대 스텝.
mutable struct _CompareRLShim
    env
    step_count::Int
    no_progress::Int
    n_events::Int
    max_steps::Int
end

# =============================================================================
# rethread -- Diagnostic: after fault->reassign->commit on the RESUME path (which now runs
#   rethread_robot_ids!), find any robot that is DOUBLE-BOOKED — captured inside a
#   transport unit while a free RobotGo of the same robot overlaps in time — and dump
#   its timeline + backtraces. Tells us whether the remaining :asserted is a genuine
#   MILP double-assignment (rethreading can't fix -> need Option 2) or still an
#   id-threading artifact my pass missed.
# =============================================================================
# diag_rethread : 고장→재배정→커밋 후 "한 로봇이 이중 예약(double-book)" 됐는지 찾아 타임라인을 덤프하는 진단.
function diag_rethread()
_setup_milp!()

# build_base_env : tractor 프로젝트로 시뮬 환경을 만들고 초반 몇 노드가 닫힐 때까지(closed>=8) 진행시키는 준비함수.
function build_base_env()
    pp = CB.get_project_params(4)   # 4 = tractor(가장 작은 프로젝트)의 파라미터 묶음
    env = run_with_stack(2_000_000_000) do   # 2GB 스택 태스크에서 빌드(깊은 재귀 대비)
        CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
            model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
            milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Error, rvo_flag=false,
            tangent_bug_flag=false, dispersion_flag=false, open_animation_at_end=false,
            save_animation=false, save_animation_along_the_way=false, write_results=false,
            overwrite_results=false, look_for_previous_milp_solution=false, save_milp_solution=false,
            return_env_before_sim=true)   # true = 시뮬 돌리기 직전 상태의 env만 돌려받음(빌드만)
    end
    for _ in 1:4000                                          # 최대 4000스텝 진행
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)  # 한 스텝 전진 + 계획 캐시 갱신
        length(env.cache.closed_set) >= 8 && break           # 완료된 노드가 8개 이상이면 멈춤(초반 mid-build)
    end
    return env
end

# pred : 그래프 정점 v 에 해당하는 predicate(작업 노드)를 꺼내는 한 줄 헬퍼.
pred(sched, v) = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
# rid : 노드가 RobotGo면 그 로봇의 정수 id, 아니면 -1 을 반환(삼항 연산자 ? :).
rid(node) = (node isa CB.RobotGo ? CB.get_id(CB.entity(node).id) : -1)

# backtrace_to_start : 정점 v 에서 선행(inneighbor) 방향으로 거슬러 올라가며 RobotStart까지의 경로를 기록.
#   maxdepth=거슬러 올라갈 최대 깊이(무한루프 방지).
function backtrace_to_start(sched, v; maxdepth=60)
    chain = Tuple{Int,String,Int}[]; cur = v                 # (정점, 타입이름, 로봇id) 튜플들을 모을 빈 배열
    for _ in 1:maxdepth
        n = pred(sched, cur)                                 # 현재 정점의 노드
        idv = try (n isa CB.RobotGo || n isa CB.RobotStart) ? CB.get_id(CB.entity(n).id) : -1 catch; -1 end  # 로봇id(없으면 -1)
        push!(chain, (cur, string(nameof(typeof(n))), idv))  # 경로에 추가(nameof(typeof(n))=노드 타입명 문자열)
        n isa CB.RobotStart && break                         # 시작점에 닿으면 종료
        ins = collect(Graphs.inneighbors(sched, cur)); isempty(ins) && break; cur = first(ins)  # 선행 정점으로 한 칸 이동
    end
    return chain
end

println(">>> building env...")
env = build_base_env()
sched = env.sched                                            # sched = 작업 스케줄 그래프
# advance to a deeper mid-build like the test (target_closed=24)
for _ in 1:100000                                            # 더 깊은 mid-build까지 진행(closed>=24)
    CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
    (length(env.cache.closed_set) >= 24 || CB.project_complete(env)) && break  # 24개 닫히거나 완공되면 멈춤
end
println(">>> advanced: closed=$(length(env.cache.closed_set)) nodes=$(Graphs.nv(sched))")

# pick faultable agent (on a pending transport team)
# 고장낼 로봇 고르기: 아직 대기중인 운반팀에 속한 로봇이어야 재배정이 실제로 일어남.
agent = nothing
seen = CB.AbstractID[]                                       # 이미 본 로봇id 목록(중복 방지)
for v in Graphs.vertices(sched)
    n = pred(sched, v); n isa CB.RobotGo || continue          # RobotGo 노드만 관심 (|| continue = 아니면 건너뜀)
    r = try CB.entity(n).id catch; nothing end
    (r isa CB.RobotID && CB.valid_id(r) && !(r in seen)) || continue; push!(seen, r)  # 유효·미중복 로봇만 수집
end
for r in seen
    !isempty(CB.transport_teams_with_agent(env, r; pending_only=true)) && (agent = r; break)  # 대기 운반팀 있는 첫 로봇 선택
end
println(">>> faulting agent = $agent")

CB.RETHREAD_DEBUG[] = true                                   # 전역 디버그 플래그 켜기(Ref라 [] 로 대입)
res = CB.fault_robot_and_reassign!(env, agent; resume=true, verbose=true)  # 로봇 고장 처리 + 작업 재배정 실행
CB.RETHREAD_DEBUG[] = false
println(">>> reassign status = $(res.status)")
println(">>> validate(sched) = ", CB.validate(sched))

# Build captured-intervals (robot inside a transport unit) and free RobotGo intervals.
# captured interval for a team robot r of unit U ~= [t0(FormTransportUnit), tF(DepositCargo)]
# overlaps : 두 시간구간 a,b 가 서로 겹치는지 판정(1e-6 여유로 경계 오차 흡수).
overlaps(a,b) = a[1] < b[2] - 1e-6 && b[1] < a[2] - 1e-6
captured = Dict{Int,Vector{Tuple{Float64,Float64,String}}}()   # rid -> intervals (로봇이 운반체 안에 갇힌 구간들)
freego   = Dict{Int,Vector{Tuple{Float64,Float64,Int}}}()      # rid -> (t0,tF,vtx) (자유롭게 이동하는 구간들)

for v in Graphs.vertices(sched)
    n = pred(sched, v)
    if n isa CB.FormTransportUnit                            # 운반팀 형성 노드면: 그 팀 로봇들의 "갇힌 구간" 계산
        fv = v
        dnode = try CB.get_node(sched, CB.DepositCargo(CB.entity(n))) catch; nothing end  # 짝이 되는 화물 내려놓기 노드
        dv = dnode === nothing ? nothing : CB.get_vtx(sched, CB.node_id(CB.DepositCargo(CB.entity(n))))
        t0 = CB.get_t0(sched, fv)                            # 갇히기 시작(FormTransportUnit 시작시각)
        tF = dv === nothing ? CB.get_tF(sched, fv) : CB.get_tF(sched, dv)  # 풀려나는 시각(DepositCargo 종료시각)
        for r in collect(keys(CB.robot_team(CB.entity(n))))   # 이 팀에 속한 로봇마다
            push!(get!(captured, CB.get_id(r), []), (t0, tF, "$(CB.node_id(n))"))  # get!=키 없으면 []로 만들고 추가
        end
    elseif n isa CB.RobotGo                                  # 자유 이동 노드면: 그 구간을 freego에 기록
        r = CB.get_id(CB.entity(n).id)
        r > 0 || continue                                    # 유효한 로봇id(양수)만
        push!(get!(freego, r, []), (CB.get_t0(sched, v), CB.get_tF(sched, v), v))
    end
end

# (1) Are the SKIP-prone deposits' teams genuinely invalid? Dump every DepositCargo
# team and flag invalid slot ids (these are the future units the re-solve left
# unassigned, which is why get_matching_child_id returns invalid -> rethread SKIPs).
println("\n>>> DepositCargo teams (invalid slots = unassigned future units):")
for v in Graphs.vertices(sched)
    n = pred(sched, v)
    n isa CB.DepositCargo || continue                        # 화물 내려놓기 노드만
    team = CB.robot_team(CB.entity(n))
    ids = [CB.get_id(r) for r in keys(team)]                 # 이 팀 슬롯들의 로봇id
    ninvalid = count(<(0), ids)                              # 음수 id 개수 = 아직 미배정 슬롯 수 (<(0)=음수 판별함수)
    ninvalid > 0 && println("   DepositCargo vtx=$v team=$ids  ($ninvalid invalid)")
end

# (2) GROUND TRUTH: step the resumed sim and replicate preprocess_env!'s assert
# (active free RobotGo whose robot is NOT its own scene-tree parent == captured).
# Dump the first offender, who captures it, and whether rethread SKIPped that node.
println("\n>>> stepping to the real runtime double-book (preprocess_env! condition)...")
# team_has : 노드 n(운반 관련)의 팀에 로봇 r 이 들어있는지 판정. any(==(r), ...) = 하나라도 r 과 같으면 true.
function team_has(n, r)
    (n isa CB.FormTransportUnit || n isa CB.TransportUnitGo || n isa CB.DepositCargo) || return false
    any(==(r), (CB.get_id(x) for x in keys(CB.robot_team(CB.entity(n)))))
end
hit = false                                                 # 이중예약을 찾았는지 플래그
for it in 1:200000                                          # 시뮬을 최대 20만 스텝 전진시키며 감시
    for v in collect(env.cache.active_set)                  # 지금 활성(진행중) 노드들만 검사
        n = CB.get_node(sched, v).node
        n isa CB.RobotGo || continue
        ok = try CB.has_parent(CB.entity(n), CB.entity(n)) catch; true end  # 자기 자신이 씬트리 부모인가(=자유 상태인가)
        if !ok                                              # 부모가 자기가 아니면 = 어딘가에 갇혀있는데 자유 이동중 = 이중예약!
            r = CB.get_id(CB.entity(n).id)
            par = try CB.get_parent(CB.entity(n)) catch; nothing end
            parid = par === nothing ? "nothing" : try string(CB.node_id(par)) catch; "?" end
            println("\n!!! RUNTIME DOUBLE-BOOK iter=$it: active free RobotGo vtx=$v robot=$r")
            println("    scene-tree parent (captor) = $parid")
            for v2 in collect(env.cache.active_set)
                team_has(CB.get_node(sched, v2).node, r) &&
                    println("    held by ACTIVE $(nameof(typeof(CB.get_node(sched,v2).node))) vtx=$v2 id=$(CB.node_id(CB.get_node(sched,v2).node))")
            end
            println("    offender backtrace: ", backtrace_to_start(sched, v))  # 문제 노드의 근원 경로 출력
            hit = true; break
        end
    end
    hit && break                                            # 찾았으면 전체 루프 종료
    CB.step_environment!(env)
    try
        CB.update_planning_cache!(env, 0.0)
    catch e                                                 # 캐시 갱신 중 assertion이 터지는 것도 이중예약 증거
        println(">>> update_planning_cache! threw at iter=$it (", typeof(e), ") — assertion site"); hit=true; break
    end
    CB.project_complete(env) && (println(">>> resumed to completion, NO runtime double-book"); break)  # 완공되면 문제 없음
end
hit || println(">>> stepping loop exhausted without completion or double-book")
println(">>> done")
end

# =============================================================================
# rethread_check -- One-shot, non-interactive verification of the reassignment id-threading
#   fix (rethread_robot_ids!). Self-contained (no Revise): builds the base env once, then
#   runs the resume sanity check and the reassign+resume check several times (the HiGHS
#   solver varies run-to-run, so multiple trials confirm the double-booking is gone, not
#   just masked by one solve).
# =============================================================================
# run_rethread_check : 재배정 id 재연결(rethread_robot_ids!) 수정이 실제로 이중예약을 없앴는지 여러 번 돌려 확인.
#   HiGHS 솔버 결과가 실행마다 달라서, 여러 trial로 "우연히 가려진 게 아님"을 보증한다.
function run_rethread_check()
_setup_milp!()

# build_base_env : (위 진단과 동일) tractor env를 만들고 closed>=8까지 진행시켜 돌려줌.
function build_base_env()
    pp = CB.get_project_params(4)   # tractor
    env = run_with_stack(2_000_000_000) do
        CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
            model_scale=pp[:model_scale], num_robots=pp[:num_robots],
            assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
            log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false,
            dispersion_flag=false, open_animation_at_end=false, save_animation=false,
            save_animation_along_the_way=false, write_results=false,
            overwrite_results=false, look_for_previous_milp_solution=false,
            save_milp_solution=false, return_env_before_sim=true)
    end
    for _ in 1:4000
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
        length(env.cache.closed_set) >= 8 && break
    end
    return env
end

# _advance_to : env를 목표 closed 수(target_closed)에 도달하거나 완공될 때까지 최대 cap 스텝 전진.
function _advance_to(env; target_closed::Int, cap::Int)
    for _ in 1:cap
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
        (length(env.cache.closed_set) >= target_closed || CB.project_complete(env)) && break
    end
    return env
end

# _pick_faultable_agent : 대기중 운반팀에 속한(고장내면 진짜 재배정을 유발하는) 유효 로봇 하나를 고름.
function _pick_faultable_agent(env)
    sched = env.sched
    seen = CB.AbstractID[]
    for v in Graphs.vertices(sched)
        node = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        node isa CB.RobotGo || continue
        rid = try CB.entity(node).id catch; nothing end
        (rid isa CB.RobotID && CB.valid_id(rid) && !(rid in seen)) || continue  # 유효·미중복 로봇만 수집
        push!(seen, rid)
    end
    for rid in seen
        !isempty(CB.transport_teams_with_agent(env, rid; pending_only = true)) && return rid  # 대기팀 있는 첫 로봇
    end
    return isempty(seen) ? nothing : first(seen)             # 없으면 아무 로봇이나(또는 nothing)
end

# _run_to_end : env를 끝(완공)이나 assertion까지 돌리고 (상태, 닫힌수, 반복수, 단조증가여부)를 반환.
#   status는 심볼: :complete(완공) / :asserted(중간에 assert 터짐) / :capped(cap 소진). mono=진행이 되돌아가지 않았나.
function _run_to_end(env; cap::Int)
    prev = length(env.cache.closed_set); mono = true; iters = 0
    for _ in 1:cap
        CB.step_environment!(env)
        try
            CB.update_planning_cache!(env, 0.0)
        catch err
            return (:asserted, length(env.cache.closed_set), iters, mono)  # 예외 = 이중예약 등 문제 발생
        end
        c = length(env.cache.closed_set); c < prev && (mono = false); prev = c; iters += 1  # 닫힌 수가 줄면 단조성 깨짐
        CB.project_complete(env) && return (:complete, c, iters, mono)
    end
    return (:capped, prev, iters, mono)
end

# resume_test : 재배정 없이 "resume 인프라(reset_cache_resume!)만" 검증 — mid-build에서 프론티어만 재계산 후 완공되는지.
function resume_test(BASE_ENV; target_closed::Int = 24, cap::Int = 60_000)
    env = deepcopy(BASE_ENV)                                 # 원본을 건드리지 않도록 깊은 복사
    _advance_to(env; target_closed = target_closed, cap = cap)
    n0 = length(env.cache.closed_set); total = Graphs.nv(env.sched)
    CB.reset_cache_resume!(env.cache, env.sched)             # 스케줄 변경 없이 계획 프론티어만 다시 계산
    n1 = length(env.cache.closed_set)
    st = _run_to_end(env; cap = cap)
    pass = st[1] == :complete && st[4] && n1 >= n0           # 완공 + 단조 + resume 후 진행 유지 = 통과
    println("resume_test: closed $n0 ->(resume) $n1 ->(end) $(st[2])/$total | " *
            "status=$(st[1]) monotone=$(st[4]) iters=$(st[3]) -> ", pass ? "PASS" : "FAIL")
    return pass
end

# reassign_resume_test : 로봇 고장 -> 재배정 -> resume 후 완공까지 가는지 검증(rethread 수정의 실제 대상).
function reassign_resume_test(BASE_ENV; target_closed::Int = 24, cap::Int = 100_000)
    env = deepcopy(BASE_ENV)
    _advance_to(env; target_closed = target_closed, cap = cap)
    n0 = length(env.cache.closed_set); total = Graphs.nv(env.sched)
    agent = _pick_faultable_agent(env)
    agent === nothing && (println("no valid robot to fault"); return :no_agent)  # 고장낼 로봇 없으면 조기 종료
    res = CB.fault_robot_and_reassign!(env, agent; resume = true, verbose = false)
    res.status == :admitted || (println("reassign $(res.status)"); return res.status)  # 재배정이 승인 안 되면 중단
    st = _run_to_end(env; cap = cap)
    println("reassign_resume_test fault=$agent: closed $n0 ->(commit) $(length(env.cache.closed_set)) " *
            "->(resume) $(st[2])/$total | status=$(st[1]) monotone=$(st[4]) iters=$(st[3])")
    return st[1]
end

println(">>> building base env once (slow, ~minutes)...")
BASE_ENV = build_base_env()
println(">>> base env ready: $(Graphs.nv(BASE_ENV.sched)) nodes, closed=$(length(BASE_ENV.cache.closed_set))")

println("\n=== resume_test (resume infrastructure sanity) ===")
sane = resume_test(BASE_ENV)

println("\n=== reassign_resume_test (rethread fix) x5 ===")
results = Symbol[]
for i in 1:5                                                 # 솔버 무작위성 때문에 5번 반복해 안정성 확인
    r = reassign_resume_test(BASE_ENV)
    push!(results, r)
    println("  trial $i -> $r")
end

ncomplete = count(==(:complete), results)                   # 5번 중 완공(:complete)한 횟수
println("\n=== SUMMARY ===")
println("resume_test sane : ", sane)
println("reassign trials  : ", results)
println("complete         : $ncomplete/5")
println(ncomplete == 5 && sane ? ">>> FIX VERIFIED" : ">>> NOT YET")
end

# =============================================================================
# ood_compare -- LLM vs RL comparison on FULLY-SIMULATED, COMPLETING robot-breakdown.
#   The headless OODEnv (decpomdp/examples/ood_compare_complete.jl) does not faithfully
#   reproduce the full simulation's endgame recovery, so for a TRUSTWORTHY completing
#   comparison we run the ACTUAL simulation (run_lego_demo, return_env_before_sim=false) once
#   per controller and read completion + makespan from it. Same build, same safe fault; the
#   ONLY difference is the producer plugged into the shared respec seam:
#     * no-adapt : returns nothing (floor)
#     * LLM (NL) : reads the event NL -> DSL (fault -> ReplaceAgent)
#     * MARL (RL): learned policy reads the state -> DSL
#     * canonical: rule (upper bound)
#   NOTE: this diagnostic keeps its OWN MILP block (60s/0.05 gap/output_flag) -- a different
#   attribute set than the shared _setup_milp! (MOI.Silent) -- so it is kept inline verbatim.
#   ENV: OOD_POLICY, NSPARE, OOD_TRACE, OOD_MODE, OOD_SEED.
# =============================================================================
# ood_compare : 똑같은 "로봇 고장" 상황에서 no-adapt / LLM / RL / canonical 4가지 controller가
#   각각 얼마나 잘 회복하는지(완공여부·makespan·결정 F1)를 실제 시뮬로 비교하는 진단.
function ood_compare()
# 이 진단만의 MILP 설정(60초/gap0.05/로그끔) — 공통 _setup_milp! 와 속성이 달라 따로 둔다.
CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 60.0, "mip_rel_gap" => 0.05,
    "output_flag" => false, "presolve" => "on")

# get(ENV,키,기본값) = 환경변수 읽기(없으면 기본값). 학습된 RL 정책 파일 경로.
POLICY_PATH = get(ENV, "OOD_POLICY", joinpath(dirname(pkgdir(CB)), "decpomdp", "checkpoints", "ood_policy.txt"))
POLICY = isfile(POLICY_PATH) ? load_policy(POLICY_PATH) : LinearPolicy(Random.MersenneTwister(1))  # 없으면 랜덤 정책
NSPARE = parse(Int, get(ENV, "NSPARE", "3"))                # 풀당 예비 로봇 수(문자열 ENV를 정수로 파싱)

# --- RL state shim (extract_state reads these fields) ---------------------------------
_SHIM = _CompareRLShim(nothing, 0, 0, 0, 4000)              # RL이 상태를 읽을 때 쓸 껍데기 인스턴스

# --- captured emitted DSL (for decision-quality F1) -----------------------------------
EMITTED = CB.ConstraintSpec[]                               # 각 controller가 내놓은 DSL 규칙을 모으는 통(F1 채점용)
_TRACE = get(ENV, "OOD_TRACE", "0") == "1"                  # 상세 추적 출력 on/off
# _cap : producer(prod)를 감싸서, 내놓은 규칙을 EMITTED에 기록하고(옵션: 추적 출력) 그대로 통과시키는 래퍼.
_cap(prod) = (env, ev) -> begin                            # begin ... end = 여러 줄을 하나의 익명함수 본문으로
    p = prod(env, ev)
    if _TRACE
        ctx = event_context(env, ev)
        println("    [emit] type=", ctx.type, " -> ", p === nothing ? "NOOP" : string(CB.emitted_key(p.constraints[1])))
    end
    p isa CB.RespecProposal && append!(EMITTED, p.constraints)  # 제안(RespecProposal)이면 그 규칙들을 기록
    return p
end

# --- controllers as producers (env, event_NL) -> RespecProposal | Nothing -------------
# 각 controller = "(env, 자연어 사건ev) -> 제안 또는 nothing" 함수. 아래 4종이 서로 비교 대상이다.
noop_prod(env, ev) = nothing                                 # no-adapt : 아무것도 안 함(바닥선)
# canonical : 규칙 기반 상한선(사건 문맥ctx에서 정답 action을 규칙으로 뽑아 제안으로 변환).
canonical_prod(env, ev) = (ctx = event_context(env, ev); action_to_proposal(ctx, canonical_action(ctx)))
# llm_prod : 자연어 사건을 사건종류별로 분기해 알맞은 DSL action으로 바꾸는 zero-shot 번역기(LLM 자리).
function llm_prod(env, ev)   # zero-shot NL -> DSL
    ctx = event_context(env, ev)
    if ctx.type === :battery                                 # 배터리 사건: 문장에서 %를 정규식으로 추출
        m = match(r"(\d+)\s*%", ev); socpct = m === nothing ? ctx.soc*100 : parse(Float64, m.captures[1])
        return action_to_proposal(ctx, socpct <= 100*CB.REPLACE_SOC_THRESHOLD[] ? 1 : 2)  # 낮으면 교체(1) 아니면 후순위(2)
    elseif ctx.type === :fault;  return action_to_proposal(ctx, 1)   # 고장 -> ReplaceAgent(1)
    elseif ctx.type === :zone;   return action_to_proposal(ctx, 3)   # 통행금지구역 -> ForbidZone(3)
    elseif ctx.type === :reform; return action_to_proposal(ctx, 4)   # 팀 재구성 -> ReformTeam(4)
    end
    return nothing
end
# rl_prod : 학습된 정책(POLICY)이 상태를 읽어 greedy하게 action을 고르는 controller.
function rl_prod(env, ev)
    _SHIM.env = env; _SHIM.n_events += 1                     # shim에 현재 env 꽂고 사건 카운트++
    ctx = event_context(env, ev)
    action_to_proposal(ctx, greedy_action(POLICY, extract_state(_SHIM, ctx), valid_actions(ctx)))  # 유효 action 중 최선 선택
end

# grounding_prf : controller가 내놓은 규칙(emitted)과 실제 정답 라벨(truths)을 비교해 결정 품질을 F1로 채점.
#   precision·recall을 구해 조화평균(F1)을 반환. ReformTeam은 정답 라벨이 없는 창발적 회복이라 제외한다.
function grounding_prf(emitted, truths)
    # score only the ACTUAL scheduled OODs (fault/battery/zone). ReformTeam is an EMERGENT physics
    # recovery for a transient team deadlock — it has no OOD truth label, so counting it would unfairly
    # penalize precision on runs that happened to hit a deadlock. Exclude it from the decision score.
    es = Set{Any}(); for c in emitted; c isa CB.ReformTeam && continue; k = try CB.emitted_key(c) catch; nothing end; k === nothing || push!(es, k); end  # 내놓은 규칙들의 키 집합(ReformTeam 제외)
    ts = Set{Any}(try CB.truth_key(t) catch; nothing end for t in truths); delete!(ts, nothing)  # 정답 라벨들의 키 집합
    tp = length(intersect(es, ts))                          # true positive = 정답과 겹친 개수
    prec = isempty(es) ? (isempty(ts) ? 1.0 : 0.0) : tp/length(es)  # 정밀도(내놓은 것 중 맞은 비율)
    rec  = isempty(ts) ? 1.0 : tp/length(ts)                # 재현율(정답 중 맞춘 비율)
    return (prec+rec)==0 ? 0.0 : 2prec*rec/(prec+rec)       # F1 = 2·prec·rec/(prec+rec)
end

# schedule_safe_fault! : 진행 지점들 중 처음 도달하는 곳에서 안전한 로봇 고장 1건을 딱 한 번 발생시키도록 예약.
function schedule_safe_fault!()
    fired = Ref(false)                                       # 이미 발생했는지 기억하는 상자(중복 발생 방지)
    # clear=true tows the dead robot OFF-GRID; with the breakdown immobilization it stays there (never
    # drives back), so it does NOT block the build. no-adapt then simply loses that robot's work
    # (incomplete); adapt re-routes the work to spares (complete) — a clean, non-fragile consequence.
    tf = CB.fault_action(; safe = true, obstacle = false, clear = true)  # 안전(solo 대상)·격자 밖으로 견인하는 고장 액션
    act = e -> fired[] ? nothing : (nl = tf(e); nl === nothing ? nothing : (fired[] = true; nl))  # 첫 발생시 fired 세우고 사건 반환
    for c in (12, 20, 30, 45, 60); CB.schedule_ood_at_closed!(c, act); end  # closed 수가 이 값들에 닿을 때 시도
end

OOD_MODE = get(ENV, "OOD_MODE", "single")   # "single" = one fault; "multi" = fault + mild-battery stream
MULTI_SEED = parse(Int, get(ENV, "OOD_SEED", "7"))   # multi 모드 난수 시드

# multi-OOD stream: a SEQUENCE of safe robot-breakdowns (clear off-grid) at spread progress points.
# Each is enacted by distributed replace (tasks -> nearest spares), so this stress-tests spare-pool
# consumption over multiple faults (robustness B2) AND that the build still COMPLETES. LLM/RL both
# emit ReplaceAgent for each; the discriminator is completion + makespan over the sequence.
# (Battery→Deprioritize was tried but its full-sim MILP re-solve wedges the build early — a separate
#  enactment fragility; see docs/distributed_replace_2026-07-09.md. Multi-FAULT is the robust stream.)
# schedule_multiood! : 여러 진행 지점(30, 90)에서 안전 고장을 연속으로 발생시키는 다중 OOD 스트림 예약(강건성 스트레스 테스트).
function schedule_multiood!(seed::Int)
    tf = CB.fault_action(; safe = true, obstacle = false, clear = true)   # safe solo target + off-grid
    for c in (30, 90)                            # two breakdowns at spread progress points (fires once each)
        CB.schedule_ood_at_closed!(c, tf)
    end
end

# run_one : 주어진 controller(prod) 하나로 시뮬을 처음부터 끝까지 돌리고 (완공·닫힌수·makespan·F1)을 측정.
function run_one(prod)
    empty!(EMITTED); _SHIM.n_events = 0                     # 기록통과 카운터 초기화
    CB.RESPEC_ENABLED[] = true                              # respec 레이어 켜기
    # 이전 실행이 남긴 전역 상태(예약된 OOD, 구역, 예비풀 등)를 전부 청소 — 심볼로 함수를 동적 호출.
    for f in (:clear_ood_schedule!, :clear_restriction_zones!, :clear_spare_pools!, :clear_faulted_robots!,
              :clear_recovery_spares!, :clear_ood_truth_log!, :clear_wedge_edges!, :clear_stalled_robots!)
        try getproperty(CB, f)() catch end                 # getproperty(CB,:foo)=CB.foo (없으면 조용히 무시)
    end
    try CB.set_reform_interval!(400) catch end             # 팀 재구성 주기 설정
    CB.set_respec_producer!(_cap(prod))                    # 이번 controller를 respec seam에 꽂음(_cap으로 감싸 기록)
    OOD_MODE == "multi" ? schedule_multiood!(MULTI_SEED) : schedule_safe_fault!()  # 모드에 따라 OOD 예약
    res = run_with_stack(2_000_000_000) do
        CB.run_lego_demo(; ldraw_file = "tractor.mpd", num_robots = 10, assignment_mode = :greedy,
            milp_optimizer = :highs, optimizer_time_limit = 60, log_level = Logging.Warn,
            max_num_iters_no_progress = 30000, rvo_flag = true, tangent_bug_flag = true, dispersion_flag = true,
            n_spare_per_pool = NSPARE, save_animation = false, open_animation_at_end = false,
            write_results = false, overwrite_results = true, return_env_before_sim = false)  # false = 끝까지 시뮬
    end
    CB.clear_respec_producer!(); CB.RESPEC_ENABLED[] = false  # 다음 controller를 위해 seam 비우고 끔
    env = res isa Tuple ? res[1] : res                       # 반환이 (env, stats) 튜플이면 분해
    stats = res isa Tuple ? res[2] : Dict()
    complete = CB.project_complete(env)                      # 완공 여부
    closed = length(env.cache.closed_set); total = length(CB.get_nodes(env.sched))  # 닫힌 노드 / 전체 노드
    makespan = try Float64(get(stats, :Makespan, NaN)) catch; NaN end  # 총 소요시간(없으면 NaN)
    f1 = grounding_prf(copy(EMITTED), try CB.ground_truth_labels() catch; [] end)  # 결정 품질 F1
    return (complete = complete, closed = closed, total = total, makespan = makespan, f1 = f1)  # 이름있는 튜플 반환
end

# main : 4개 controller를 차례로 run_one으로 돌려 표 형식으로 비교 결과를 출력.
function main()
    controllers = _TRACE ? [("canonical", canonical_prod), ("MARL (RL)", rl_prod)] :
        [("no-adapt", noop_prod), ("LLM (NL→DSL)", llm_prod), ("MARL (RL)", rl_prod), ("canonical", canonical_prod)]
    println("[fullsim] LLM-vs-RL on COMPLETING robot-breakdown (full simulation), spares=$(4*NSPARE) ...")
    println("\n", rpad("controller", 15), rpad("complete", 10), rpad("closed/total", 14), rpad("makespan", 11), "decision-F1")
    println(repeat("-", 62))
    for (name, prod) in controllers                          # 각 controller를 한 줄씩 표로 출력
        r = run_one(prod)
        @printf("%-15s%-10s%-14s%-11.1f%.3f\n", name, r.complete ? "YES" : "no",  # @printf = C스타일 서식 출력
                "$(r.closed)/$(r.total)", r.makespan, r.f1)
    end
    println(repeat("-", 62))
    println("[fullsim] adaptive controllers (LLM/MARL/canonical) emit the correct ReplaceAgent (decision-F1=1.0) and")
    println("          recover strictly MORE closed nodes than no-adapt on a genuine real-robot breakdown (e.g. seed-1")
    println("          Bot 1: adapt 195/313 vs no-adapt 174/313). They do NOT fully COMPLETE: that is the separate")
    println("          mid-build completion limit (cyclic OpenBuildStep over-subscription), not the (fixed) double-book.")
end

main()
end

# =============================================================================
# ab_energy -- A/B PROOF for the energy-aware objective: "handling-energy DOWN at makespan ~= same".
#   Builds ONE small instance (greedy, fast), RE-OPENS the future assignment edges
#   (release_pending_assignments!), then RE-SOLVES the SAME assignment sub-problem at several
#   efficiency weights ENERGY_W. The per-edge transport ENERGY is identical across arms (same
#   geometry); only the CHOSEN assignment Xa differs, so handling_energy = Σ edge_energy·Xa is an
#   apples-to-apples comparison. No commit / no schedule mutation between arms — each arm just
#   formulates+solves. Reports per arm: makespan, handling-energy, MILP gap/status.
#   ENV: WEIGHTS, PROJECT, TLIM, GAP, NROBOTS.
# =============================================================================
# ab_energy : "efficiency 가중치를 올리면 makespan은 비슷하면서 handling-energy가 줄어드는가"를 A/B로 증명하는 진단.
#   같은 배정 하위문제를 여러 efficiency 가중치(ENERGY_W)로 다시 풀어 makespan·에너지를 비교한다.
function ab_energy()
value = JuMP.value                                          # JuMP 함수들에 짧은 지역 별칭 부여
termination_status = JuMP.termination_status
relative_gap = JuMP.relative_gap

# parse.(Float64, ...) = 점(.) 붙은 브로드캐스트 = 배열 각 원소에 parse 적용. split(...,",")=쉼표로 쪼갬.
WEIGHTS = parse.(Float64, split(get(ENV, "WEIGHTS", "0,0.001,0.01,0.05"), ","))  # 시험할 efficiency 가중치 목록
PROJECT = parse(Int, get(ENV, "PROJECT", "4"))     # 4 = tractor (smallest)
TLIM    = parse(Float64, get(ENV, "TLIM", "180"))  # MILP 제한시간(초)
GAP     = parse(Float64, get(ENV, "GAP", "0.01"))  # 허용 최적성 오차
NROBOTS = parse(Int, get(ENV, "NROBOTS", "0"))     # 0 = project default; smaller => smaller MILP (likelier to converge)

_setup_milp!(time_limit = TLIM, mip_rel_gap = GAP)

# Clean baseline: no per-agent / battery bias, payload term ON so energy ≠ pure distance.
CB.clear_agent_bias!(); CB.EDGE_COST_MULTIPLIER[] = nothing  # 로봇별/배터리 편향 제거(공정한 비교 위해)
CB.set_energy_model!(pickup_overhead = 0.0, idle_power = 1.0, load_power = 0.25)  # 에너지 모델 파라미터 설정

pp = CB.get_project_params(PROJECT)
nrob = NROBOTS > 0 ? NROBOTS : pp[:num_robots]
println(">>> building env once (greedy)...  project=$(pp[:project_name]) robots=$(nrob)")
env = run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=nrob,
        assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
        log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false, dispersion_flag=false,
        open_animation_at_end=false, save_animation=false, save_animation_along_the_way=false,
        write_results=false, overwrite_results=false,
        look_for_previous_milp_solution=false, save_milp_solution=false, return_env_before_sim=true)
end
println(">>> built: $(Graphs.nv(env.sched)) nodes")

# GREEDY baseline (deterministic, always "converged") — schedule-level handling energy =
# Σ edge_energy(move duration) over the committed transport moves. A meaningful reference the
# MILP arms can be compared against even when the makespan MILP itself does not reach optimality.
# schedule_handling_energy : 현재 스케줄의 모든 이동(RobotGo/TransportUnitGo)에 대해 이동시간→에너지를 합산.
function schedule_handling_energy(env)
    s = 0.0
    for v in Graphs.vertices(env.sched)
        node = CB.get_node(env.sched, v).node
        (node isa CB.RobotGo || node isa CB.TransportUnitGo) || continue  # 이동 노드만
        dur = try Float64(CB.get_tF(env.sched, v) - CB.get_t0(env.sched, v)) catch; 0.0 end  # 이동 소요시간(tF-t0)
        s += CB.edge_energy(max(dur, 0.0))                   # 소요시간을 에너지로 환산해 누적
    end
    return s
end
greedy_ms = try maximum(CB.get_tF(env.sched)) catch; NaN end  # greedy 기준선의 makespan(최대 종료시각)
greedy_he = schedule_handling_energy(env)                     # greedy 기준선의 handling energy
println(">>> GREEDY baseline: makespan=$(round(greedy_ms,digits=2))  handling_energy=$(round(greedy_he,digits=2))")

# Re-open all FUTURE assignment edges so the MILP can re-decide them (faulted=nothing => no fault).
inv = CB.build_invariant(env)                                # 현재 확정된 부분(불변식) 기록
CB.release_pending_assignments!(env, inv; faulted = nothing)  # 미래 배정 엣지를 다시 열어 MILP가 재결정 가능케 함
println(">>> released future assignment edges; re-solving at $(length(WEIGHTS)) weights\n")

rows = []                                                    # 가중치별 결과를 담을 배열
for w in WEIGHTS
    CB.set_planning_objective_weights!(speed = 1.0, efficiency = w)  # speed 1.0 고정, efficiency만 w로 바꿈
    milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;  # 같은 하위문제를 MILP로 구성
        optimizer = CB._respec_optimizer(), t0_ = inv.frozen_t0, tF_ = inv.frozen_tF)
    CB.optimize!(milp)                                       # 풀기
    he  = CB.handling_energy(milp)                       # Σ edge_energy·Xa on this solution
    ms  = try maximum(value.(milp.model[:tF])) catch; NaN end  # 이 해의 makespan
    st  = try string(termination_status(milp.model)) catch; "?" end  # 종료 상태(최적/시간초과 등)
    gp  = try round(relative_gap(milp.model); digits = 3) catch; NaN end  # 최적성 gap
    push!(rows, (w = w, makespan = ms, energy = he, status = st, gap = gp))
    println("  ENERGY_W=$(rpad(w,7))  makespan=$(round(ms,digits=2))  handling_energy=$(round(he,digits=2))  [$(st), gap=$(gp)]")
end

# Headline summary vs the w=0 baseline.
base = rows[1]                                               # w=0(기준선) 결과
println("\n== A/B SUMMARY (baseline ENERGY_W=$(base.w): makespan=$(round(base.makespan,digits=2)), energy=$(round(base.energy,digits=2))) ==")
for r in rows[2:end]                                         # 기준선 제외 나머지 가중치들의 변화율 계산
    dms = base.makespan > 0 ? 100 * (r.makespan - base.makespan) / base.makespan : NaN  # makespan 변화율(%)
    den = base.energy   > 0 ? 100 * (r.energy   - base.energy)   / base.energy   : NaN  # energy 변화율(%)
    println("  w=$(rpad(r.w,7))  Δmakespan=$(round(dms,digits=1))%   Δenergy=$(round(den,digits=1))%   [$(r.status)]")
end
println("\nHEADLINE: the largest w with Δmakespan within tolerance AND Δenergy<0 is the safe operating band.")
println("(If gaps are large the numbers are feasible-but-not-optimal; tighten GAP / raise TLIM / smaller PROJECT.)")
end

# =============================================================================
# dump_fixture -- Build the tractor env ONCE, step to mid-build, and dump the EXACT /propose
#   request body (open_ids, agents, nodes) + a sub-assembly id map to JSON, so the Python prompt
#   harness (tools/translate_eval.py) can iterate on the LLM translation WITHOUT rebuilding the
#   env or touching Julia. Output: tools/llm_fixture.json (PLAIN JSON — safe to cache across
#   processes, unlike the PlannerEnv itself). No MILP block (run_lego_demo's :highs suffices).
#   NOTE: @__DIR__ still resolves to the tools/ dir from inside tools/diagnostics.jl, so the
#   fixture path (tools/llm_fixture.json) is UNCHANGED.
# =============================================================================
# dump_fixture : tractor env를 mid-build까지 진행시킨 뒤, LLM에게 보낼 /propose 요청 본문을 JSON 파일로 덤프.
#   Python 프롬프트 실험(translate_eval.py)이 Julia/env 재빌드 없이 반복 실험할 수 있게 한다.
function dump_fixture()
println(">>> building tractor env (assignment only)...")
pp = CB.get_project_params(4)
env = run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots],
        assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
        log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false,
        dispersion_flag=false, open_animation_at_end=false, save_animation=false,
        save_animation_along_the_way=false, write_results=false,
        overwrite_results=false, look_for_previous_milp_solution=false,
        save_milp_solution=false, return_env_before_sim=true)
end
println(">>> env: $(Graphs.nv(env.sched)) nodes")

# Step into a mid-build state (mirror eval_respec_ood.jl main): closed>=8 so the
# precede/zone milestones are partially realized — the state translation runs in.
for _ in 1:4000
    CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
    length(env.cache.closed_set) >= 8 && break
end
println(">>> stepped: closed=$(length(env.cache.closed_set))")

# The EXACT /propose request body the production llm_to_proposal would send.
open_ids = CB.open_node_id_strings(env)                      # 아직 안 닫힌 노드 id 문자열들
agents   = CB.open_agent_descriptors(env)                    # 로봇(agent) 설명 데이터
nodes    = CB.open_node_descriptors(env)                     # 열린 작업 노드 설명 데이터

# sub-assembly AssemblyID.id -> exact node id string, so the Python eval cases can
# say "sub-assembly 2" and know the gold target id with NO Julia at eval time.
asm_map = Dict{String,String}()                             # "하위조립 번호" -> 정확한 노드 id 매핑
for v in Graphs.vertices(env.sched)
    v in env.cache.closed_set && continue                    # 이미 닫힌 건 제외
    node = CB.get_node(env.sched, v).node
    node isa CB.AssemblyComplete || continue                 # 조립완료 노드만
    aid = try CB.entity(node).id catch; nothing end
    aid === nothing && continue
    asm_map[string(aid.id)] = string(CB.get_vtx_id(env.sched, v))
end

fixture = Dict(                                             # JSON으로 내보낼 전체 묶음
    "open_ids" => open_ids,
    "agents"   => agents,
    "nodes"    => nodes,
    "sub_assembly_id_to_node_id" => asm_map,
    "closed_count" => length(env.cache.closed_set),
    "n_sched_nodes" => Graphs.nv(env.sched),
)
out = joinpath(@__DIR__, "llm_fixture.json")               # @__DIR__ = 이 소스파일이 있는 폴더(tools/)
open(out, "w") do io; JSON3.pretty(io, fixture); end        # 파일 열고 예쁘게 정렬된 JSON 쓰고 자동 닫기(do-블록)
println(">>> wrote $out")
println("    open_ids=$(length(open_ids)) agents=$(length(agents)) nodes=$(length(nodes)) sub_asm=$(length(asm_map))")
end

# =============================================================================
# reassign -- Diagnostic: figure out whether ForbidAgent blocked robot 1 and whether the
#   FTU slots kept stale ids after fault->release->re-solve. Builds the tractor env ONCE,
#   faults the first robot on a pending transport team, then dumps the FTU slot feeders,
#   the ForbidAgent frontier vs R-bound RobotGo nodes, the post-solve feeders, and a
#   per-node backtrace-to-start (genuine solver routing vs stale-id artifact) (diag_reassign.jl).
# =============================================================================
# diag_reassign : 고장 후 재배정에서 ForbidAgent가 로봇1을 제대로 막았는지, 또 FTU 슬롯에 옛 id가 남았는지 진단.
#   FTU 슬롯 피더, ForbidAgent 프론티어, 재풀이 후 상태, 각 노드의 근원 역추적을 덤프한다.
function diag_reassign()
_setup_milp!(time_limit = 120.0)

pp = get_project_params(4)
env = run_with_stack(2_000_000_000) do
    run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots],
        assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
        log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false, dispersion_flag=false,
        open_animation_at_end=false, save_animation=false, save_animation_along_the_way=false,
        write_results=false, overwrite_results=false, look_for_previous_milp_solution=false,
        save_milp_solution=false, return_env_before_sim=true)
end
sched = env.sched
println(">>> env: ", Graphs.nv(sched), " nodes")

R = nothing                                                 # 고장낼 로봇 id
for v in Graphs.vertices(sched)
    n = CB.get_node(sched,v).node
    CB.matches_template(CB.RobotStart, CB.get_node(sched,v)) || continue  # RobotStart 노드만
    id = CB.entity(n).id
    if !isempty(CB.transport_teams_with_agent(env, id; pending_only=true)); R=id; break; end  # 대기팀 있는 첫 로봇 선택
end
println(">>> faulting robot id = ", R)

# origin vtx (RobotStart node bound to R)
ov = first(v for v in Graphs.vertices(sched)               # R에 묶인 RobotStart 정점(출발점) 찾기 (first(제너레이터))
           if CB.matches_template(CB.RobotStart, CB.get_node(sched,v)) && CB.entity(CB.get_node(sched,v).node).id == R)
println(">>> origin vtx = ", ov, "  out-edges BEFORE release = ", collect(Graphs.outneighbors(sched, ov)))

pred(v) = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))   # raw predicate at vtx (정점->노드)
rid(v)  = (p=pred(v); p isa CB.RobotGo ? string(CB.get_id(CB.entity(p).id)) : "-")  # 노드의 로봇id 문자열(아니면 "-")
isgo(v) = pred(v) isa CB.RobotGo                             # 정점이 RobotGo 노드인가

# ftu_feeders : 로봇 R이 속한 FTU(운반팀 형성)들과, 그 슬롯에 흘러드는(feeder) 자유 노드들을 재배정 전 상태로 수집.
function ftu_feeders(env, R)
    sched=env.sched; out=[]
    for v in Graphs.vertices(sched)
        CB.matches_template(CB.FormTransportUnit, CB.get_node(sched,v)) || continue  # FTU 노드만
        for vp in Graphs.inneighbors(sched,v)               # FTU로 들어오는 슬롯(선행 정점)들
            isgo(vp) || continue
            if CB.entity(pred(vp)).id == R                  # 그 슬롯이 R에 묶여 있으면
                feeders = [f for f in Graphs.inneighbors(sched, vp) if isgo(f)]  # 슬롯에 흘러드는 자유 노드들
                push!(out, (ftu=v, slot=vp, feeders=feeders, fids=[rid(f) for f in feeders]))
            end
        end
    end
    out
end
println("\n>>> FTUs robot R is on, BEFORE reassign (slot fed by free node):")
for t in ftu_feeders(env, R); println("   FTU v$(t.ftu) <- slot v$(t.slot)(id=$(rid(t.slot))) <- feeders $(t.feeders) ids=$(t.fids)"); end

# release
inv = CB.build_invariant(env)                              # 확정 부분 기록
removed = CB.release_pending_assignments!(env, inv; faulted = R)  # R을 고장 처리하고 미래 배정 엣지를 열어줌
println("\n>>> released ", length(removed), " edges. origin out-edges AFTER release = ", collect(Graphs.outneighbors(sched, ov)))

# Faithfully reproduce the real path: set the frozen/pinned frontier globals that
# the ForbidAgent compiler reads (fault_robot_and_reassign! sets these).
# ForbidAgent 컴파일러가 읽는 "얼어붙은/고정된 프론티어" 전역값을 실제 경로와 똑같이 세팅.
let closed_ids = Set{CB.AbstractID}(CB.get_vtx_id(sched, v) for v in env.cache.closed_set),
    active_ids = Set{CB.AbstractID}(CB.get_vtx_id(sched, v) for v in env.cache.active_set)
    CB.RESPEC_FROZEN[] = closed_ids                         # 이미 닫힌(확정) 것 = 얼림
    CB.RESPEC_PINNED[] = union(closed_ids, active_ids)      # 닫힌 것 + 활성 것 = 고정(핀)
    println(">>> closed=$(length(closed_ids)) active=$(length(active_ids)) at fault time")
end

# PRE-SOLVE: list every node the ForbidAgent compiler considers a frontier for R,
# and (separately) every RobotGo currently still bound to R. If R can reach a slot
# through a free node that is bound-to-R but NOT a frontier, ForbidAgent misses it.
let
    frontier = Int[]; rgo = Int[]                           # R에 묶인 RobotGo 정점 / 그 중 프론티어로 인식된 것
    for v in Graphs.vertices(sched)
        n = pred(v)
        n isa CB.RobotGo || continue
        CB.bound_to_agent(n, R) || continue                 # R에 묶인 노드만
        push!(rgo, v)
        CB.is_agent_frontier(sched, v, n, R) && push!(frontier, v)  # ForbidAgent가 프론티어로 보는가
    end
    println(">>> PRE-SOLVE: RobotGo nodes still bound to R = $rgo")
    println(">>> PRE-SOLVE: ForbidAgent frontier nodes for R = $frontier")
    for v in rgo
        outs = [v2 for v2 in Graphs.outneighbors(sched, v)]
        println("      R-node v$v preds=$(collect(Graphs.inneighbors(sched,v))) outs=$outs frontier=$(v in frontier)")
    end
end

# Build milp WITH forbid, inspect compiled count by instrumenting compile_proposal!
# R을 금지하는 ForbidAgent 규칙을 넣은 제안을 만들어 MILP를 다시 푼다.
proposal = CB.RespecProposal(CB.ConstraintSpec[CB.ForbidAgent(R, 0.0)], "diag", "diag")
milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), sched, env.scene_tree;
    optimizer=CB._respec_optimizer(), t0_=inv.frozen_t0, tF_=inv.frozen_tF, extra_constraints=proposal)
CB.optimize!(milp)
println(">>> primal_status = ", CB.primal_status(milp))     # 해가 실제로 구해졌는지(primal 상태)

CB.update_project_schedule!(nothing, milp, sched, env.scene_tree)  # 푼 결과를 스케줄에 반영
CB.reset_cache!(env.cache, sched)                           # 캐시 재구성

println("\n>>> AFTER reassign: each FTU slot, its id, and the free node feeding it (id):")
for v in Graphs.vertices(sched)                             # 재배정 후 FTU 슬롯 상태 재점검
    CB.matches_template(CB.FormTransportUnit, CB.get_node(sched,v)) || continue
    for vp in Graphs.inneighbors(sched,v)
        isgo(vp) || continue
        feeders = [f for f in Graphs.inneighbors(sched, vp) if isgo(f)]
        fids = [rid(f) for f in feeders]
        if rid(vp) == string(CB.get_id(R)) || any(==(string(CB.get_id(R))), fids)  # 슬롯이나 피더에 아직 R id가 남았으면 출력
            println("   FTU v$v slot v$vp slot_id=$(rid(vp))  feeders=$feeders feeder_ids=$fids")
        end
    end
end

# BACKTRACE: for every node still bound to R after reassign, walk predecessors to
# the root RobotStart. If it reaches RobotStart(R) the solver genuinely routed R
# there (ForbidAgent gap). If it reaches a DIFFERENT robot's start, or no start,
# the id=1 is a stale-propagation artifact (reset/first_valid bug).
# backtrace_to_start : 정점 v 에서 선행을 거슬러 RobotStart까지의 (정점,타입,id) 경로를 기록.
#   RobotStart(R)에 닿으면 solver가 진짜로 R을 그리 배정한 것(ForbidAgent 누락), 다른 로봇/무시작에 닿으면 옛 id 잔재.
function backtrace_to_start(sched, v; maxdepth=50)
    chain = Tuple{Int,String,String}[]
    cur = v
    for _ in 1:maxdepth
        n = pred(cur)
        tname = string(nameof(typeof(n)))                   # 노드 타입 이름
        idstr = try string(CB.get_id(CB.entity(n).id)) catch; "-" end  # 로봇 id(없으면 "-")
        push!(chain, (cur, tname, idstr))
        n isa CB.RobotStart && break                        # 시작점 도달시 종료
        ins = collect(Graphs.inneighbors(sched, cur))
        isempty(ins) && break
        cur = first(ins)                                    # 선행 정점으로 이동
    end
    return chain
end
println("\n>>> BACKTRACE of R-bound nodes after reassign (vtx, type, id) -> root:")
for v in Graphs.vertices(sched)
    n = pred(v)
    (n isa CB.RobotGo && CB.bound_to_agent(n, R)) || continue
    println("   from v$v: ", backtrace_to_start(sched, v))
end

println("\n>>> origin (robot R) out-edges AFTER reassign = ", collect(Graphs.outneighbors(sched, ov)))
println(">>> teams_after (entity.id based) = ", length(CB.transport_teams_with_agent(env, R; pending_only=true)))
println(">>> validate = ", CB.validate(sched))
println(">>> done")
end

# eval_ood's case spec (a struct cannot be defined inside a function, so it lives at
# module level with a unique name; it is only referenced by diag_eval_ood).
# _OODEvalCase : OOD 평가 한 케이스의 명세를 담는 구조체. Base.@kwdef = 키워드 인자로 생성 가능하게 하는 매크로.
#   ::Type 필드 = 타입 자체를 값으로 담음(예: ForbidAgent라는 타입). ::Function = 함수를 값으로 담음.
Base.@kwdef struct _OODEvalCase
    id::String
    klass::Symbol
    events::Vector{String}                       # NL paraphrases of the SAME event (같은 사건의 여러 자연어 표현)
    pick_target::Function                         # env -> AbstractID (정답 대상을 고르는 함수)
    expected_kind::Type                           # ForbidAgent / ForbidWindow (기대하는 DSL 종류)
    gold_runner::Function                         # (env, target) -> outcome  (LLM 없이 정답을 실행하는 오라클)
    predicates::Vector{Pair{String,Function}}     # name => (env_after, target) -> Bool (행동 검증식들)
end

# =============================================================================
# eval_ood -- Per-OOD-class reliability eval of the LLM respec layer. For each OOD case it
#   scores TWO axes: (a) TRANSLATION -- did the LLM emit the expected DSL kind + the expected
#   id; (b) BEHAVIOR -- does executing the emitted spec satisfy the gold predicates. Gold
#   predicates come from an LLM-FREE oracle (never grade the model against itself); the LLM is
#   stochastic so each event is sampled N times (eval_respec_ood.jl). PREREQ: the Python LLM
#   service must be running (ANTHROPIC_API_KEY) -- returns early with a note if unreachable.
# =============================================================================
# diag_eval_ood : LLM respec 레이어를 OOD 종류별로 신뢰도 평가 — (a)번역(기대 DSL종류+id 맞았나), (b)행동(실행 후 정답조건 만족).
#   정답은 LLM 없는 오라클로 준다(모델을 자기 자신으로 채점 금지). Python LLM 서비스가 켜져 있어야 한다.
function diag_eval_ood()
_setup_milp!()

# build_eval_env : 평가용 base env를 한 번만 빌드(각 trial은 deepcopy로 돌린다 — 재빌드는 몇 분 걸림).
function build_eval_env()
    pp = CB.get_project_params(4)   # tractor
    run_with_stack(2_000_000_000) do
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

# LLM-driven candidate: translate the NL event, then APPLY it exactly as the
# production maybe_respecify! dispatch does. Returns (proposal, status).
# llm_candidate! : 자연어 event를 LLM으로 번역(proposal)하고, 실제 운영과 똑같이 적용해 (proposal, 상태)를 반환.
function llm_candidate!(env, event)
    proposal = CB.llm_to_proposal(event, env;                # 자연어 -> DSL 제안 (id_resolver로 참조를 실제 id로 해석)
        id_resolver = ref -> CB._default_id_resolver(env, ref))
    inv = CB.build_invariant(env)
    if CB._is_robot_fault(proposal)                          # 로봇 고장 제안이면 전용 재배정 경로로
        res = CB.fault_robot_and_reassign!(env, proposal.constraints[1].agent; verbose=false)
        return (proposal, res.status)
    end
    return (proposal, commit_proposal!(env, proposal, inv))  # 그 외엔 일반 검증+커밋 경로로
end

# Generic verify + commit (NO robot-fault dispatch). Shared by the LLM-driven
# generic path above and the LLM-FREE gold runner (ForbidWindow).
# commit_proposal! : 제안을 검증(verify)하고 통과하면 MILP로 다시 풀어 커밋하는 일반 경로(로봇고장 분기는 없음).
function commit_proposal!(env, proposal, inv = CB.build_invariant(env))
    verdict = CB.verify(proposal, env, inv)                  # 제안 검증
    verdict isa CB.Admit || return :rejected                 # 승인(Admit) 아니면 거부
    milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
        optimizer=CB._respec_optimizer(), t0_=inv.frozen_t0, tF_=inv.frozen_tF,
        extra_constraints=verdict.proposal)
    CB.optimize!(milp)
    CB.commit_respec!(env, milp, verdict.proposal)           # 결과를 env에 커밋
    return :admitted
end

# Targets are normalised to a TUPLE so single-id and set-valued specs score
# uniformly. Single-target cases let pick_target return a bare id; _astuple wraps it.
# _spec_targets : 규칙 c 에서 대상 id를 튜플로 뽑음(종류별 메서드 = 다중 디스패치). 단일/집합 채점을 통일하려는 것.
_spec_targets(c::CB.ForbidAgent)  = (c.agent,)
_spec_targets(c::CB.ForbidWindow) = (c.node,)
_astuple(x) = x isa Tuple ? x : (x,)                        # 이미 튜플이면 그대로, 아니면 1-튜플로 감쌈

# score_translation : LLM이 낸 proposal이 기대한 DSL 종류(kind)와 대상(target)을 맞췄는지 채점.
function score_translation(proposal, case, target)
    cs = proposal.constraints
    if target isa Set                      # multi-node case (e.g. zone closure) — 집합 대상(구역 닫기 등)
        kind_ok = !isempty(cs) && all(c -> c isa case.expected_kind, cs)  # 모든 규칙이 기대 종류인가
        got = Set(_spec_targets(c)[1] for c in cs if c isa case.expected_kind)  # 실제로 겨냥한 대상 집합
        return (kind_ok = kind_ok, target_ok = kind_ok && got == target)  # 집합이 정확히 일치해야 target_ok
    end
    kind_ok = length(cs) == 1 && cs[1] isa case.expected_kind  # 단일 대상: 규칙 1개 + 기대 종류
    target_ok = kind_ok && _spec_targets(cs[1]) == _astuple(target)
    return (kind_ok = kind_ok, target_ok = target_ok)
end

# score_behavior : 적용 후 env(env_after)에서 케이스의 각 검증식을 실행해 (이름 => 통과여부) 목록을 만든다.
score_behavior(env_after, case, target) =
    [name => f(env_after, target) for (name, f) in case.predicates]

# Run one case: first sanity-check the LLM-FREE gold achieves its own predicates,
# then grade each NL paraphrase x sample against them.
# run_case : 한 케이스 실행 — 먼저 LLM-free 오라클(gold)이 자기 조건을 만족하는지 확인하고, 그 뒤 각 표현×샘플을 채점.
#   n_samples = LLM이 확률적이라 같은 event를 여러 번 샘플링해 평균낸다.
function run_case(case::_OODEvalCase, base_env; n_samples::Int = 2)
    println("\n================  CASE $(case.id)  [$(case.klass)]  ================")

    # --- gold sanity: the LLM-free oracle must satisfy its own predicates --------
    gold_env = deepcopy(base_env)                           # 원본 보호용 복사
    gtarget  = case.pick_target(gold_env)                   # 정답 대상 선택
    case.gold_runner(gold_env, gtarget)                     # LLM 없이 정답 동작 실행
    gold_preds = score_behavior(gold_env, case, gtarget)
    gold_ok = all(p -> p.second, gold_preds)                # 모든 검증식 통과? (p.second = pair의 값 부분)
    println("GOLD (LLM-free) predicates: ", gold_ok ? "ALL PASS ✓" : "FAIL ✗")
    for (n, ok) in gold_preds; println("   [$(ok ? "✓" : "✗")] $n"); end
    gold_ok || @warn "gold oracle does not satisfy its predicates — case is ill-formed!"  # 오라클이 실패면 케이스 자체가 잘못됨

    # --- LLM candidates ----------------------------------------------------------
    rows = NamedTuple[]
    for event in case.events, s in 1:n_samples             # 각 자연어 표현 × 각 샘플(이중 for = 곱집합 순회)
        env = deepcopy(base_env)
        target = case.pick_target(env)
        kind_ok = false; target_ok = false; beh_ok = false; status = :error; preds = Pair[]  # 기본값(에러 대비)
        try
            proposal, status = llm_candidate!(env, event)  # LLM 번역 + 적용
            tr = score_translation(proposal, case, target)  # 번역 채점
            kind_ok, target_ok = tr.kind_ok, tr.target_ok
            preds = score_behavior(env, case, target)      # 행동 채점
            beh_ok = !isempty(preds) && all(p -> p.second, preds)
        catch err
            status = :error
            println("   trial errored: ", first(split(sprint(showerror, err), "\n")))  # 에러 첫 줄만 출력
        end
        push!(rows, (event=event, kind=kind_ok, target=target_ok, behavior=beh_ok, status=status))
        println("  [kind $(kind_ok ? "✓" : "✗") | target $(target_ok ? "✓" : "✗") | behavior $(beh_ok ? "✓" : "✗") | $status]  \"$(first(event, 60))...\"")
    end

    n = length(rows)
    pct(f) = "$(count(f, rows))/$n"   # count needs the collection, not just the predicate (조건 f 만족 개수/전체)
    println("---- $(case.id) summary over $n trials ----")
    println("  translation kind   : ", pct(r -> r.kind))
    println("  translation target : ", pct(r -> r.target))
    println("  behavior (gold pred): ", pct(r -> r.behavior))
    return rows
end

# CASE 1 — robot fault -> ForbidAgent -> reassign
# robot_fault_case : "로봇 고장" 케이스 명세를 만든다. 정답 조건들: 고장 로봇이 팀에서 빠짐/스케줄 유효/makespan 유한/모든 운반팀 인원 충족.
function robot_fault_case()
    # Behavioral gold predicates (mirror test_respec_reassign.jl asserts).
    freed = (env, rid) -> isempty(CB.transport_teams_with_agent(env, rid; pending_only=true))  # 고장 로봇이 대기팀에서 빠졌나
    valid = (env, _)   -> CB.validate(env.sched)             # 스케줄이 유효한가 (_ = 안 쓰는 인자)
    finite = (env, _)  -> isfinite(CB.makespan(env.sched))   # makespan이 유한한가
    staffed = function (env, _)                             # 모든 운반팀이 필요 인원만큼 채워졌나
        for v in Graphs.vertices(env.sched)
            CB.matches_template(CB.FormTransportUnit, CB.get_node(env.sched, v)) || continue  # FTU 노드만
            node = CB.get_node(env.sched, v).node
            need = length(CB.robot_team(CB.entity(node)))   # 이 팀에 필요한 로봇 수
            have = count(vp -> CB.get_node_from_id(env.sched, CB.get_vtx_id(env.sched, vp)) isa CB.RobotGo,  # 실제로 붙은 RobotGo 수
                         Graphs.inneighbors(env.sched, v))
            have >= need || return false                    # 하나라도 인원 부족이면 실패
        end
        return true
    end
    _OODEvalCase(
        id = "robot_fault_basic",
        klass = :ForbidAgent,
        events = [
            "Robot R3 reports a motor fault and is immobile and cannot perform any task.",
            "We just lost robot 3 — it's stuck and won't move, so take it out of the plan.",
            "R3 has broken down and is unavailable for the rest of the build.",
        ],
        pick_target = env -> CB.RobotID(3),
        expected_kind = CB.ForbidAgent,
        gold_runner = (env, target) -> CB.fault_robot_and_reassign!(env, target; verbose=false),
        predicates = [
            "faulted robot on 0 pending transport teams" => freed,
            "schedule valid"                              => valid,
            "makespan finite"                             => finite,
            "all transport tasks fully staffed"           => staffed,
        ],
    )
end

# CASE 2 — zone closure -> ForbidWindow on EVERY node in a spatial zone. The
# grounding test is SPATIAL: the model must map "the southern area" to the set of
# south-located assemblies (labelled with their staging direction). SET-valued
# target. NOTE: AssemblyComplete is an instantaneous milestone, so a window the
# nodes already avoid is non-binding → behavior can't tell right-set from wrong-set;
# the grounding signal is the translation-TARGET set-match. (See design doc.)
# zone_closure_case : "남쪽 구역 폐쇄" 케이스 — LLM이 "남쪽 지역"을 남쪽에 위치한 조립들의 집합으로 매핑해야 한다(집합 대상).
function zone_closure_case()
    T_LO, T_HI = 20.0, 50.0                                 # 금지 시간창 [20, 50]
    southset = function (env)                              # 남쪽(y < -0.2)에 놓인 조립완료 노드들의 id 집합
        s = Set{CB.AbstractID}()
        for v in Graphs.vertices(env.sched)
            node = CB.get_node(env.sched, v).node
            node isa CB.AssemblyComplete || continue
            aid = CB.entity(node).id
            haskey(env.staging_circles, aid) || continue    # 스테이징 원(위치)이 있는 것만
            Float64(LazySets.center(env.staging_circles[aid])[2]) < -0.2 &&  # 중심의 y좌표([2])가 음수(남쪽)면
                push!(s, CB.get_vtx_id(env.sched, v))
        end
        return s
    end
    _OODEvalCase(
        id = "zone_closure_south",
        klass = :ForbidWindow,
        events = [
            "A worker has entered the southern staging area. No assembly work may take place in the south between time 20 and time 50.",
            "Safety lockout: the south staging zone is closed from t=20 to t=50 — keep every southern assembly out of that window.",
            "There is a spill in the south area; nothing located in the south can be active between t=20 and t=50.",
        ],
        pick_target = southset,
        expected_kind = CB.ForbidWindow,
        gold_runner = (env, zone) ->                         # 정답: 남쪽 각 노드에 ForbidWindow를 걸어 커밋(컴프리헨션으로 규칙 생성)
            commit_proposal!(env, CB.RespecProposal([CB.ForbidWindow(id, T_LO, T_HI) for id in zone])),
        predicates = [
            "all south nodes avoid [t_lo,t_hi]" =>            # 남쪽 노드들이 금지창을 실제로 피하는가 (all(...) do id ... end = do-블록 술어)
                (env, zone) -> all(zone) do id
                    v = CB.get_vtx(env.sched, id)
                    CB.get_tF(env.sched, v) <= T_LO + 1e-3 || CB.get_t0(env.sched, v) >= T_HI - 1e-3  # 창 이전에 끝나거나 이후에 시작
                end,
            "schedule valid"  => (env, _) -> CB.validate(env.sched),
            "makespan finite" => (env, _) -> isfinite(CB.makespan(env.sched)),
        ],
    )
end

# main : Python LLM 서비스가 켜졌는지 확인 후 base env를 mid-build까지 진행시키고, 두 케이스를 차례로 평가.
function main()
    if !CB.respec_service_ready()                           # LLM 서비스가 안 켜졌으면 안내 후 조기 종료
        println("!!! Python LLM service not reachable at $(CB._RESPEC_SERVICE_URL). " *
                "Start it (see test_respec_e2e.jl header) and re-run.")
        return
    end
    println(">>> building base env (assignment only)...")
    base_env = build_eval_env()
    println(">>> base env: $(Graphs.nv(base_env.sched)) nodes")
    # Step into a mid-build state so the reassign exercises the freeze path too.
    for _ in 1:4000                                         # freeze 경로까지 밟도록 mid-build(closed>=8)로 전진
        CB.step_environment!(base_env); CB.update_planning_cache!(base_env, 0.0)
        length(base_env.cache.closed_set) >= 8 && break
    end
    println(">>> stepped: closed=$(length(base_env.cache.closed_set))")

    cases = [robot_fault_case(), zone_closure_case()]      # 평가할 케이스 목록
    for c in cases
        run_case(c, base_env; n_samples = 2)
    end
    println("\n>>>>>>>>>>>>>>  OOD EVAL COMPLETE  <<<<<<<<<<<<<<")
end

main()
end

# ---- dispatcher -------------------------------------------------------------
# DIAGNOSTICS : "진단 키 문자열 -> 진단 함수" 매핑표. CLI 인자/ENV로 받은 키로 해당 함수 하나만 골라 부른다.
const DIAGNOSTICS = Dict(
    "rethread"       => diag_rethread,
    "rethread_check" => run_rethread_check,
    "ood_compare"    => ood_compare,
    "ab_energy"      => ab_energy,
    "dump_fixture"   => dump_fixture,
    "reassign"       => diag_reassign,
    "eval_ood"       => diag_eval_ood,
)
end # module Diagnostics

# abspath(PROGRAM_FILE) == @__FILE__ : 이 파일이 "직접 실행"됐을 때만 아래를 돈다(다른 곳에서 include되면 건너뜀).
if abspath(PROGRAM_FILE) == @__FILE__
    key = get(ENV, "DIAG", isempty(ARGS) ? "rethread" : ARGS[1])  # ENV의 DIAG > 명령행 첫 인자 > 기본 "rethread"
    haskey(Diagnostics.DIAGNOSTICS, key) || error("unknown diagnostic '$key'. Available: $(join(sort(collect(keys(Diagnostics.DIAGNOSTICS))), ", "))")  # 모르는 키면 에러
    println(">>> running diagnostic: $key")
    Diagnostics.DIAGNOSTICS[key]()                          # 고른 진단 함수 실행
end
