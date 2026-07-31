# =============================================================================
# diag_decision_point.jl -- CHEAP diagnostic before paying for a 4-candidate sweep.
#
# The full sweep produced a DEGENERATE instance: no-op tied the best response, i.e.
# the injected fault was harmless. Before another expensive run we must answer:
#
#   Q1  What is the HEALTHY (no-fault) baseline? closed / project_complete / makespan.
#       -> tells us whether `closed=283/297 & project_complete=true` is the normal
#          ceiling, or whether 14 nodes are STRANDED work being masked by a weak
#          project_complete predicate.
#   Q2  Who is at the decision point? For every active RobotGo: its id/type, whether it
#       has a pending assignment, and its transport team sizes.
#       -> tells us why _pick_active_robot returned a DeliveryBot and whether a
#          CONSEQUENTIAL target (one whose loss actually blocks the build) exists.
#   Q3  Is the fault CONSEQUENTIAL? Roll `noop` WITH the fault and compare to Q1.
#       -> if noop == control, the instance is inadmissible for the oracle set.
#
# Run: julia +lts --project=<ConstructionBots.jl> diag_decision_point.jl
# =============================================================================
#
# ── 한국어 설명 (처음 읽는 사람을 위한 안내) ────────────────────────────────
# 이 파일이 하는 일: 비싼 4-후보 sweep(gen_oracle_dataset.jl 같은 것)을 돌리기 전에,
#   "이 결정 지점(decision point)이 애초에 쓸모 있는가"를 값싸게 진단하는 도구.
#   한 개의 결정 지점만 골라 세 가지 질문에 답한다:
#     Q1 정상(고장 없음) 기준선은 어디인가? (완주/닫힌수/makespan)
#     Q2 그 지점에 누가 활동 중인가? (각 로봇의 pending 작업·운반팀 크기)
#     Q3 이 고장이 정말 피해를 주는가(consequential)? = 고장+NOOP 를 Q1 과 비교.
#   만약 고장+NOOP 결과가 정상과 똑같다면 → 이 고장은 무해(harmless) → oracle 학습셋에 부적합(inadmissible).
# 프로젝트 안에서의 역할: 데이터 생성 전에 "무해한(=배울 게 없는) 결정 지점"을 걸러내는 사전 점검 스크립트.
#
# 문법 참고 (Julia 초심자용):
#   · const X = ...     : 값이 안 바뀌는 전역 상수. 5_000 처럼 밑줄은 자릿수 구분(=5000).
#   · f(x::Int)         : 인자 타입 표시(다중 디스패치). :symbol 은 가벼운 이름표 상수.
#   · foo!(...)         : 이름 끝 `!` = 인자를 직접 바꾼다는 관례. Ref(x) = `[]` 로 읽고 쓰는 한 칸 상자.
#   · cond && expr      : cond 참일 때만 expr(짧은 if). cond || expr 은 그 반대.
#   · (a=1, b=2)        : named tuple(이름표 달린 값 묶음). x.a 로 필드 접근.
#   · f() do ... end    : do-블록(마지막 함수에 블록을 첫 인자로 넘김). deepcopy = 완전 복제(원본 보존).
# ────────────────────────────────────────────────────────────────────────────
using ConstructionBots                                 # 시뮬레이터 본체 불러오기
import Graphs                                          # 스케줄을 그래프로 다룸
import HiGHS                                           # MILP 솔버
import Logging
const CB = ConstructionBots                            # 긴 이름을 CB 로 줄여 씀

const CLOSED_AT_DECISION = 8    # 결정 지점 정의: 닫힌(완료) 노드가 이 개수가 됐을 때
const N_SPARE = 1               # 풀당 예비 로봇 수
const ROLL_CAP = 5_000     # healthy path completes in <1k steps

# MILP 솔버를 HiGHS 로 지정하고 옵션 설정(진단용이라 오차 허용 크게, 조용히).
CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!(
    "time_limit" => 300.0, "presolve" => "on", "mip_rel_gap" => 5.0, CB.MOI.Silent() => true)

# run_with_stack : 함수 f 를 스택이 큰 별도 Task 에서 실행(깊은 재귀 스택 넘침 방지). 예외는 출력 후 재던짐.
function run_with_stack(f, stacksize::Int)
    result = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)   # 결과/에러/완료 상자
    wrapper = () -> (try result[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int), wrapper, nothing, stacksize)   # 큰 스택의 새 Task 생성(ccall=C 호출)
    t.sticky = false; schedule(t)                       # 실행 예약
    while !done[]; sleep(0.05); end                     # 끝날 때까지 대기
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); rethrow(err[][1]))
    return result[]
end

# build_base_env : tractor 프로젝트의 초기 환경을 만든다(시뮬 직전 상태 반환). RVO 등은 꺼서 진단을 빠르게.
function build_base_env()
    pp = CB.get_project_params(4)                       # 4번 프로젝트(tractor)의 파라미터 묶음
    run_with_stack(2_000_000_000) do                    # 큰 스택에서 데모 셋업 실행
        CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
            model_scale=pp[:model_scale], num_robots=pp[:num_robots],
            assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
            log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false,   # 진단이라 충돌회피(RVO)/tangent_bug 끔
            dispersion_flag=false, open_animation_at_end=false, save_animation=false,
            save_animation_along_the_way=false, write_results=false, overwrite_results=false,
            look_for_previous_milp_solution=false, save_milp_solution=false,
            n_spare_per_pool=N_SPARE, return_env_before_sim=true)   # 시뮬 전 환경을 돌려받음(직접 굴리려고)
    end
end

# roll! : env 를 완주(또는 cap 스텝)까지 직접 굴린다(개입 없음). 결과를 named tuple(완주/닫힌수/노드수/makespan/스텝)로.
function roll!(env, cap)
    steps = 0
    for i in 1:cap                                      # 최대 cap 스텝까지
        CB.RESPEC_HOLD[] && break                       # respec 보류 신호가 서면 멈춤
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)   # 한 스텝 전진 + 계획 캐시 갱신
        steps = i
        CB.project_complete(env) && break               # 완주하면 조기 종료
    end
    comp = CB.project_complete(env)                     # 최종 완주 여부
    (complete=comp, closed=length(env.cache.closed_set), nv=Graphs.nv(env.sched),
     makespan=(comp ? Float64(CB.makespan(env.sched)) : Inf), steps=steps)   # 미완주면 makespan=무한대
end

# ---- Q2: who is active at the decision point? -------------------------------
# inspect_actives : Q2 답 — 결정 지점에서 활동 중인 각 RobotGo 로봇의 id/pending 여부/운반팀 크기를 출력.
function inspect_actives(env)
    sched = env.sched
    println("--- active RobotGo agents at the decision point ---")
    n = 0
    for v in env.cache.active_set                       # 활성 노드들을 훑어
        node = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        node isa CB.RobotGo || continue                 # 이동 중 로봇 노드만
        rid = try CB.entity(node).id catch; nothing end
        rid === nothing && continue
        n += 1
        pend = try CB._first_pending_assignment(env, rid) !== nothing catch; "err" end   # 이 로봇에 남은 작업 있는지
        # transport team sizes for this robot's not-yet-closed FormTransportUnit nodes
        sizes = Int[]
        for w in Graphs.vertices(sched)
            w in env.cache.closed_set && continue        # 이미 끝난 노드 제외
            fnode = CB.get_node_from_id(sched, CB.get_vtx_id(sched, w))
            fnode isa CB.FormTransportUnit || continue   # 운반팀 형성 노드만
            team = try CB.robot_team(CB.entity(fnode)) catch; nothing end
            team === nothing && continue
            (try haskey(team, rid) catch; false end) && push!(sizes, length(team))   # 이 로봇이 낀 팀이면 그 크기 수집
        end
        println("  $(rid)   type=$(typeof(rid))   pending_assignment=$(pend)   team_sizes=$(sizes)")
    end
    n == 0 && println("  (none)")
    println("  pick_solo_fault_target => ", CB.pick_solo_fault_target(env))   # solo 고장 대상 후보 확인
    println("  _pick_active_robot     => ", CB._pick_active_robot(env))       # 기본 활성 로봇 선택 결과 확인
end

# main : 진단 전체 흐름 — 결정 지점까지 굴린 뒤 Q2(활성 로봇)→Q1(정상 기준선)→Q3(고장 영향)을 순서대로 확인.
function main()
    println(">>> [diag] building base env (tractor, n_spare=$N_SPARE, RVO off)")
    base = build_base_env()                             # 기본 환경 생성
    CB.RESPEC_ENABLED[] = false                          # 여기선 개입 끔(순수 진행만)
    for i in 1:8_000
        length(base.cache.closed_set) >= CLOSED_AT_DECISION && break   # 닫힌 노드가 목표치에 도달하면 = 결정 지점
        CB.step_environment!(base); CB.update_planning_cache!(base, 0.0)
    end
    println(">>> decision point: closed=$(length(base.cache.closed_set)) / nv=$(Graphs.nv(base.sched))")

    inspect_actives(base)                               # Q2: 이 지점의 활성 로봇들 출력

    # ---- Q1: HEALTHY control (no fault at all) --------------------------------
    println("\n--- Q1: HEALTHY control (no fault injected) ---")
    ctrl = roll!(deepcopy(base), ROLL_CAP)              # base 를 복제(원본 보존)해 고장 없이 끝까지 굴림 = 정상 기준선
    println("  control: complete=$(ctrl.complete) closed=$(ctrl.closed)/$(ctrl.nv) makespan=$(ctrl.makespan) steps=$(ctrl.steps)")

    # ---- Q3: is the fault CONSEQUENTIAL? (noop WITH the fault) ----------------
    println("\n--- Q3: fault + no-op (is the fault consequential?) ---")
    target = CB.pick_solo_fault_target(base)            # 우선 solo 고장 대상을 고름
    is_solo = target !== nothing
    target === nothing && (target = CB._pick_active_robot(base))   # 없으면 기본 활성 로봇으로 대체
    println("  target = $target  (solo=$is_solo)")

    env = deepcopy(base)                                # 다시 복제본에서 실험(원본 base 는 그대로)
    nl = CB.fault_robot!(env; target=target, obstacle=false, clear=true)   # 대상 로봇 고장 발생 → NL 반환
    println("  NL: ", nl === nothing ? "(nothing!)" : first(nl, 80))       # NL 앞 80자만 미리보기
    CB.set_respec_producer!((_e,_ev) -> nothing)     # deliberate no-op   # 일부러 아무 개입 안 하는 정책(NOOP)
    CB.RESPEC_ENABLED[] = true
    CB.push_ood!(nl)                                    # OOD 사건을 대기열에 넣고
    st = CB.respec_step!(env)                           # 한 번 처리(NOOP 정책이라 실제 개입 없음)
    CB.RESPEC_ENABLED[] = false
    nores = roll!(env, ROLL_CAP)                        # 고장+NOOP 상태로 끝까지 굴린 결과
    println("  noop+fault: status=$st complete=$(nores.complete) closed=$(nores.closed)/$(nores.nv) makespan=$(nores.makespan) steps=$(nores.steps)")

    println("\n=========== VERDICT ===========")
    # 판정: 고장+NOOP 결과가 정상 기준선과 (완주·닫힌수·makespan) 전부 같으면 = 고장이 무해했다는 뜻.
    same = (nores.complete == ctrl.complete) && (nores.closed == ctrl.closed) &&
           (nores.makespan == ctrl.makespan)
    if same
        println("DEGENERATE: no-op == healthy control. The fault on $target is HARMLESS.")   # 무해 → 학습셋 부적합
        println("  -> this decision point is INADMISSIBLE for the oracle set.")
        println("  -> need a CONSEQUENTIAL target (one whose loss blocks the build).")
    else
        println("CONSEQUENTIAL: no-op is strictly worse than the healthy control.")          # 유해 → 회복할 여지가 있어 적합
        println("  control : complete=$(ctrl.complete) closed=$(ctrl.closed) makespan=$(ctrl.makespan)")
        println("  noop    : complete=$(nores.complete) closed=$(nores.closed) makespan=$(nores.makespan)")
        println("  -> admissible; adaptation has something to recover.")
    end
    if ctrl.closed < ctrl.nv                            # 정상인데도 모든 노드를 닫지 않고 완주로 표시된 경우 경고
        println("\nNOTE: healthy control closes only $(ctrl.closed)/$(ctrl.nv) nodes yet project_complete=$(ctrl.complete).")
        println("      => project_complete is a WEAK predicate; completion_rate=closed/nv is not 'fraction of build done'.")
    end
end

main()                                                   # 스크립트 실행 시작점
