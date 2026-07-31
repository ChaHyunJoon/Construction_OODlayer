# =============================================================================
# gen_oracle_faults.jl  --  Oracle eval-set generator (SLICE 1: robot-fault class)
#
# For ONE OOD decision point, try EVERY candidate DSL macro, roll each to
# completion through the PRODUCTION dispatch, and record the TRUE outcome — giving
# a ground-truth ranking of candidates. This ground truth is what a learned
# surrogate is later scored against (decision-regret / NDCG@k vs true-planner
# compute; see ../EVALUATION.md).
#
# WHY the production seam: each candidate is applied via
# set_respec_producer! + push_ood! + respec_step!  (i.e. maybe_respecify!'s full
# verify->dispatch->re-solve->resume), so the oracle outcome is computed by the
# EXACT machinery the surrogate/LLM pipeline will use — a fairness invariant.
#
# CORRECTNESS PROTOCOL (why this is not just eval_respec_ood.jl):
#   * candidates touch DIFFERENT globals (ReplaceAgent pops a spare; DeprioritizeAgent
#     writes AGENT_COST_BIAS; a fallback sets RESPEC_HOLD and NEVER resets it) — so we
#     snapshot/restore ALL mutable module globals around every candidate, else
#     candidate k+1 starts contaminated by candidate k.
#   * RVO is OFF so deepcopy(env) is a complete checkpoint (the RVO2 sim is a Python
#     object in module globals, outside PlannerEnv, and would NOT deepcopy).
#
# LLM-FREE: needs no Python service. Just: julia +lts --project=. this_file.jl [--smoke]
# =============================================================================
#
# =============================================================================
#  [한국어 설명] gen_oracle_faults.jl — "oracle(정답)" 평가셋 생성기 (SLICE 1: 로봇 고장 부류)
#
#  무엇을 하나:
#   · 하나의 OOD(분포 밖 상황) 결정 시점에서, 가능한 모든 후보 DSL 매크로
#     (ReplaceAgent=로봇 교체 / ForbidZone=금지구역 / Deprioritize=우선순위 낮춤 / no-op=아무것도 안 함)를
#     하나씩 실제 시뮬레이터로 끝까지 돌려보고 "진짜 결과(완주 여부·makespan)"를 기록한다.
#   · 그 결과로 후보들의 "정답 순위"를 만든다 → 나중에 학습된 surrogate(대리모델)/LLM이
#     이 정답과 얼마나 맞는지(decision-regret 등)로 채점된다.
#
#  프로젝트에서의 역할:
#   · ConstructionBots.jl = 여러 로봇이 협동해 레고 구조물을 짓는 TAMP 시뮬레이터.
#   · 로봇이 고장 나는 등 예상 밖(OOD) 상황이 생기면 LLM/surrogate가 "re-spec(재명세)" 매크로로 복구.
#   · 이 파일은 그 복구 판단을 채점하기 위한 "정답지"를 만든다.
#
#  왜 production seam(실제 배선)을 통해 돌리나:
#   · 후보를 set_respec_producer! + push_ood! + respec_step! 로 적용 = 실제 파이프라인이 쓰는
#     바로 그 검증→디스패치→재풀이(re-solve)→재개 기계장치. 그래야 채점이 공정(fairness)하다.
#
#  오염 방지(핵심): 후보마다 서로 다른 전역상태를 건드리므로(스페어 pop, 비용 bias 기록, HOLD 설정 등),
#   후보 하나 돌린 뒤 반드시 전역상태를 스냅샷으로 되돌린다. RVO를 꺼서 deepcopy(env)만으로 완전한
#   체크포인트가 되게 한다(RVO2 시뮬은 Python 객체라 deepcopy가 안 됨).
#
#  Julia 문법 참고(처음 보는 사람용):
#   · f(x::T) = ... : x가 타입 T일 때 적용되는 메서드(다중 디스패치). 같은 이름을 타입만 바꿔 여러 번 정의 가능.
#   · :replace, :noop 처럼 콜론으로 시작 = Symbol(가벼운 상수 이름표). ===는 정확한 동일성 비교.
#   · `!`로 끝나는 함수 이름 = 인자를 직접 수정(in-place)한다는 관례. 예: restore_globals!, push_ood!.
#   · Ref{T}(...) = 한 칸짜리 가변 상자(포인터 비슷). 안의 값은 x[] 로 읽고 쓴다.
#   · a ? b : c = 삼항 연산(조건 b 참이면 b, 아니면 c). 여러 개 이어 쓰면 다단 분기.
#   · [f(x) for x in xs] = comprehension(리스트 축약식). do ... end = 익명함수를 마지막 인자로 넘기는 블록.
#   · @__DIR__ = 이 소스파일이 있는 폴더 경로(매크로). @warn = 경고 로그 출력 매크로.
#   · NamedTuple = (kind="x", steps=3) 처럼 이름표 붙은 값묶음(딕셔너리 비슷하나 불변).
# =============================================================================
using ConstructionBots
import Graphs                                 # 스케줄을 그래프로 다루는 라이브러리(노드 수 nv 등)
import HiGHS                                  # MILP(정수최적화) 솔버 — 재배정 문제를 푼다
import Logging
const CB = ConstructionBots                   # 긴 모듈 이름을 CB로 줄여 쓰기(별칭)

# SMOKE = 빠른 점검 모드(명령줄에 --smoke 있으면 true) → 스텝 상한을 작게.
const SMOKE   = ("--smoke" in ARGS)
# MAXROLL = 후보 하나를 "끝까지" 굴릴 때 허용하는 최대 스텝 수(무한루프 방지 상한).
const MAXROLL = SMOKE ? 3_000 : 20_000       # steps to roll a candidate to completion
                                             # (full build completes in <8k from scratch; a
                                             #  stranded/failing candidate hits the cap -> infeasible)
# CLOSED_AT_DECISION = 이만큼 노드가 닫힌(=완료된) 시점에 고장을 주입한다(빌드 중반의 의미있는 결정 지점).
const CLOSED_AT_DECISION = 8                  # inject the fault after this many closed nodes
# N_SPARE = 예비(spare) 로봇 수 — 1 이상이어야 ReplaceAgent가 1:1 교체를 실제로 해볼 수 있다.
const N_SPARE = 1                             # >=1 so ReplaceAgent can do a real 1:1 hand-off
# OUTFILE = 결과 JSON 저장 경로(smoke면 별도 파일). joinpath = OS에 맞게 경로 이어붙이기.
const OUTFILE = joinpath(@__DIR__, "out", SMOKE ? "oracle_faults_smoke.json" : "oracle_faults.json")

# MILP 솔버 설정: "일단 실현가능한 정수해 하나"를 빠르고 조용히(silent) 찾도록 지정.
# Feasibility-first re-solve (first feasible integer soln; reliable & fast), silent.
CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!(
    "time_limit" => 300.0, "presolve" => "on", "mip_rel_gap" => 5.0, CB.MOI.Silent() => true)

# --- big-stack task wrapper (deep schedules overflow the default task stack) -----
# 함수 f를 "큰 스택 크기"의 별도 Task로 실행. 깊은 스케줄은 기본 스택을 넘쳐(overflow) 이 우회가 필요.
# stacksize = 바이트 단위 스택 크기. 결과/에러를 Ref 상자에 담아 되돌려준다.
function run_with_stack(f, stacksize::Int)
    result = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)  # 결과/에러/완료플래그 상자
    wrapper = () -> (try result[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end)  # f 실행+에러포착
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int), wrapper, nothing, stacksize)  # C API로 큰 스택 Task 생성
    t.sticky = false; schedule(t)                 # 아무 스레드서나 실행 가능케 하고 스케줄에 올림
    while !done[]; sleep(0.05); end               # 끝날 때까지 대기(폴링)
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); rethrow(err[][1]))  # 에러 있으면 다시 던짐
    return result[]
end

# --- build the base env ONCE (assignment only; sim state = pre-step) --------------
# 기준 환경(env)을 딱 한 번 만든다: 작업 배정까지만 하고 시뮬레이션은 시작 전 상태로 반환.
function build_base_env()
    pp = CB.get_project_params(4)   # tractor  # 4번 프로젝트 = tractor(견인차) 모델의 파라미터 묶음
    run_with_stack(2_000_000_000) do           # 20억 바이트 큰 스택으로 아래 데모를 실행(do-블록 = 익명함수)
        CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
            model_scale=pp[:model_scale], num_robots=pp[:num_robots],
            assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
            log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false,
            dispersion_flag=false, open_animation_at_end=false, save_animation=false,
            save_animation_along_the_way=false, write_results=false, overwrite_results=false,
            look_for_previous_milp_solution=false, save_milp_solution=false,
            n_spare_per_pool=N_SPARE, return_env_before_sim=true)  # 시뮬 시작 직전 env를 돌려받음(rvo_flag=false 등 모션 스택 OFF)
    end
end

# --- global snapshot / restore (the contamination firewall) ----------------------
# Snapshot the pre-OOD state once; restore it byte-for-byte before every candidate.
# GlobalSnap = 되돌릴 전역상태를 담는 구조체(스페어 pool과 그 중심좌표).
struct GlobalSnap
    spare_pools;  spare_centers
end
# 현재 전역상태를 깊은 복사(deepcopy)로 통째로 스냅샷 떠서 GlobalSnap으로 반환.
snapshot_globals() = GlobalSnap(deepcopy(CB.SPARE_POOLS[]), deepcopy(CB.SPARE_POOL_CENTERS[]))

# 스냅샷 s를 이용해 모든 가변 전역상태를 후보 실행 전 상태로 되돌린다(오염 방화벽).
function restore_globals!(s::GlobalSnap)
    CB.SPARE_POOLS[]        = deepcopy(s.spare_pools)     # pop_spare! consumed one -> restore full pool
    CB.SPARE_POOL_CENTERS[] = deepcopy(s.spare_centers)
    empty!(CB.FAULTED_ROBOTS[])                           # pre-OOD these are empty -> clearing == restoring
    empty!(CB.RECOVERY_SPARES[])
    empty!(CB.RESTRICTION_ZONES[])
    try CB.clear_agent_bias!() catch; end                 # DeprioritizeAgent wrote AGENT_COST_BIAS
    empty!(CB.RESPEC_QUEUE.pending)                       # 대기 중인 re-spec 요청 큐 비우기
    try CB.clear_ood_schedule!() catch; end
    CB.RESPEC_HOLD[]    = false                           # engage_fallback! sets this and never resets it
    CB.RESPEC_ENABLED[] = true                            # re-spec 기능 다시 켬
    CB.clear_respec_producer!()                           # 후보를 내보내던 producer 함수 제거
    return nothing
end

# --- candidate repertoire for a fault on robot r (deterministic enumeration) ------
# Mirrors random_macro_respec(::FaultTruth) (baselines.jl) but transitions to a full
# sweep incl. the no-op arm.
# 채점 대상 후보 종류 목록(no-op 포함해 전수 조사).
candidate_kinds() = [:replace, :forbid, :deprioritize, :noop]
# kind에 해당하는 DSL 제안(RespecProposal)을 만든다. r = 고장난 로봇. :noop이면 제안 없음(nothing).
function build_candidate(kind::Symbol, r)
    kind === :noop && return nothing              # no-op = 아무 매크로도 내지 않음(고의적 무대응)
    c = kind === :replace      ? CB.ReplaceAgent(r, 0.0) :          # 로봇 r을 예비 로봇으로 교체
        kind === :forbid       ? CB.ForbidAgent(r, 0.0)  :          # r 주변을 ForbidZone(금지구역)으로
        kind === :deprioritize ? CB.DeprioritizeAgent(r, 50.0) :    # r의 작업 비용을 50만큼 올려 뒤로 미룸
        error("unknown kind $kind")                                # 그 외 = 알 수 없는 종류(오류)
    return CB.RespecProposal(CB.ConstraintSpec[c], "oracle-enum: $kind", "oracle")  # 제약 c 하나를 담은 제안으로 포장
end

# --- run ONE candidate from the decision-point env; return its true metrics -------
# 후보 하나를 결정시점 env에서 끝까지 돌려 "진짜 지표"를 반환. crash가 나도 전체 sweep이 죽지 않게 감싼다.
# dp_env=결정시점 환경, target=고장 로봇, kind=후보 종류, snap=전역 스냅샷.
function eval_candidate(dp_env, target, kind, snap)
    try
        return _eval_candidate(dp_env, target, kind, snap)
    catch err
        # A candidate can crash the engine (e.g. ReplaceAgent tripping the has_edge
        # assertion on a multi-robot co-carrier). Isolate it: record as infeasible
        # rather than killing the whole sweep. env is a local deepcopy (discarded);
        # the NEXT candidate's restore_globals! cleans any dirtied global state.
        msg = first(split(sprint(showerror, err), "\n"))   # 에러 메시지 첫 줄만 뽑아 기록
        return (kind=String(kind), status="crash", stopped="crash", steps=0,
                feasible=false, completion_rate=0.0, makespan=Inf, n_nodes=0, n_closed=0,
                error=msg)                          # crash한 후보는 "실현불가(infeasible)"로 처리
    end
end

# 실제 평가 본체: 전역 되돌리기 → env 복사 → 고장 주입 → 후보 적용 → 끝까지 굴려 지표 계산.
function _eval_candidate(dp_env, target, kind, snap)
    restore_globals!(snap)                         # 이전 후보의 오염 제거(전역 초기화)
    env = deepcopy(dp_env)                          # 결정시점 env를 깊은 복사(원본 보존, RVO OFF라 완전복사 가능)
    nl  = CB.fault_robot!(env; target=target, obstacle=false, clear=true)  # physical breakdown (pure replace)
    prop = build_candidate(kind, target)           # 이 후보의 DSL 제안 생성
    CB.set_respec_producer!((_e, _ev) -> prop)     # producer returns THIS candidate (nothing => deliberate no-op)
    CB.push_ood!(nl)                                # 방금 만든 OOD(고장) 이벤트를 큐에 넣음
    status = CB.respec_step!(env)                  # full production verify->dispatch->re-solve->resume

    # roll to completion (or line-stop / cap)  # 완주하거나 라인정지/상한에 닿을 때까지 스텝 반복
    steps = 0; stopped = :cap                      # stopped = 멈춘 이유(기본값 = 상한 도달)
    for i in 1:MAXROLL
        CB.RESPEC_HOLD[] && (stopped = :line_stop; break)   # fallback engaged => build frozen
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)  # 시뮬 한 스텝 + 계획 캐시 갱신
        steps = i
        CB.project_complete(env) && (stopped = :complete; break)  # 다 지었으면 완주로 종료
    end

    nv        = Graphs.nv(env.sched)                # 스케줄의 전체 노드 수
    closed    = length(env.cache.closed_set)        # 완료된(닫힌) 노드 수
    feasible  = CB.project_complete(env)            # 프로젝트 전체 완주 여부
    comp_rate = nv == 0 ? 0.0 : closed / nv         # 완료율 = 닫힌노드/전체노드
    mkspan    = feasible ? Float64(CB.makespan(env.sched)) : Inf  # 완주 시 makespan(총 소요시간), 아니면 무한대
    return (kind=String(kind), status=String(status), stopped=String(stopped),
            steps=steps, feasible=feasible, completion_rate=comp_rate,
            makespan=mkspan, n_nodes=nv, n_closed=closed, error="")
end

# --- feasibility-lexicographic ranking (feasible first, then makespan) ------------
# a가 b보다 나은가? 사전식 우선순위: 완주여부 먼저 → 완료율 → makespan(작을수록 좋음).
# Matches is_better's spirit: a non-completing macro auto-loses to any completing one.
better(a, b) = a.feasible != b.feasible ? a.feasible :                       # 완주하는 쪽이 무조건 이김
               a.completion_rate != b.completion_rate ? a.completion_rate > b.completion_rate :  # 다음은 완료율 높은 쪽
               a.makespan < b.makespan                                       # 그 다음은 makespan 짧은 쪽

# --- minimal JSON writer (all-scalar schema; no external dep) ---------------------
# 외부 라이브러리 없이 쓰는 최소 JSON 도구들.
jesc(s) = replace(replace(String(s), "\\" => "\\\\"), "\"" => "\\\"")   # 문자열 내 역슬래시·따옴표 escape
# jval : 값 하나를 JSON 표기로 바꿈(불리언/문자열/수 각각 다르게, 무한대는 문자열로).
jval(x) = x isa Bool ? (x ? "true" : "false") :
          x isa AbstractString ? "\"$(jesc(x))\"" :
          x isa Real ? (isfinite(x) ? string(x) : "\"$(x)\"") : "\"$(x)\""
# jobj : NamedTuple을 JSON 객체 문자열로. propertynames = 필드 이름들.
function jobj(nt)
    "{" * join(["\"$(k)\":$(jval(getproperty(nt,k)))" for k in propertynames(nt)], ",") * "}"
end
# write_json : meta(요약)와 후보 목록 cands를 한 JSON 파일로 저장.
function write_json(path, meta, cands)
    open(path, "w") do io
        println(io, "{")
        println(io, "  \"meta\": $(jobj(meta)),")
        println(io, "  \"candidates\": [")
        for (i,c) in enumerate(cands)
            println(io, "    ", jobj(c), i < length(cands) ? "," : "")
        end
        println(io, "  ]")
        println(io, "}")
    end
end

# main : 전체 흐름 — 기준 env 만들기 → 결정시점까지 진행 → 후보 전수 평가 → 순위 매겨 JSON 저장.
function main()
    println(">>> [oracle] build base env (tractor, n_spare=$N_SPARE, RVO off)  smoke=$SMOKE")
    base = build_base_env()
    println(">>> base env: $(Graphs.nv(base.sched)) nodes")

    # Stop at an EARLY, CONSEQUENTIAL mid-build decision point (closed==CLOSED_AT_DECISION):
    # the faulted robot must still have real pending downstream work, or every candidate
    # (incl. no-op) trivially completes and the ranking is degenerate. Do NOT keep stepping
    # to hunt a solo target — that runs the whole build (observed: it reached closed=283).
    CB.RESPEC_ENABLED[] = false                    # no auto-respec while advancing to the decision point
    DECISION_CAP = 8_000                            # 결정시점까지 진행할 때의 안전 상한
    for i in 1:DECISION_CAP
        length(base.cache.closed_set) >= CLOSED_AT_DECISION && break  # 목표만큼 노드가 닫히면 멈춤
        CB.step_environment!(base); CB.update_planning_cache!(base, 0.0)
    end
    # prefer a SOLO target (safe for ReplaceAgent) at THIS point; else any active robot
    # with a pending frontier (eval_candidate isolates any ReplaceAgent has_edge crash).
    target = CB.pick_solo_fault_target(base)       # ReplaceAgent에 안전한 "혼자 일하는(solo)" 로봇 우선 선택
    is_solo = target !== nothing                   # solo 대상을 찾았는지 여부
    if target === nothing
        target = CB._pick_active_robot(base)       # 없으면 아무 활동 중 로봇이나 선택(교체 시 crash 가능 → infeasible 기록)
        @warn "no SOLO target at closed=$(length(base.cache.closed_set)); using active robot $target — ReplaceAgent may crash (recorded as infeasible)."
    end
    target === nothing && error("no fault target at all (closed=$(length(base.cache.closed_set)))")  # 대상이 아예 없으면 오류
    println(">>> decision point: closed=$(length(base.cache.closed_set)), fault target = $target (solo=$is_solo)")

    snap = snapshot_globals()                      # 후보들 돌리기 전 깨끗한 전역상태 스냅샷
    cands = NamedTuple[]                            # 후보별 결과 담을 빈 배열
    for kind in candidate_kinds()
        print(">>> candidate :$kind ... ")
        c = eval_candidate(base, target, kind, snap)  # 후보 하나 평가
        push!(cands, c)
        println("feasible=$(c.feasible) comp=$(round(c.completion_rate;digits=3)) mkspan=$(c.makespan) status=$(c.status) stopped=$(c.stopped) steps=$(c.steps)")
    end

    order = sortperm(cands, lt=(a,b)->better(a,b))  # better 기준으로 정렬 순서 계산(좋은 것부터)
    ranked = cands[order]                           # 순위대로 재배열
    best   = ranked[1]                              # 1등 = oracle 정답
    feas_best_mk = best.feasible ? best.makespan : Inf  # 정답이 완주할 때의 makespan(기준값)
    # attach ground-truth rank (1=best) + makespan-regret vs oracle-best (feasible only)
    # 각 후보에 정답순위(1=최고)와 정답 대비 makespan regret(손해)을 붙인다.
    cands2 = NamedTuple[]
    for c in cands
        rank = findfirst(==(c), ranked)             # 이 후보가 순위 몇 번째인지
        regret = (c.feasible && best.feasible) ? c.makespan - feas_best_mk : (c.feasible ? 0.0 : Inf)  # 완주 못하면 무한 regret
        push!(cands2, merge(c, (oracle_rank=rank, makespan_regret=regret)))  # merge = 필드 추가한 새 NamedTuple
    end

    meta = (project="tractor", ood_class="robot_fault", target=string(target),
            solo_target=is_solo,
            closed_at_decision=length(base.cache.closed_set), n_spare=N_SPARE,
            maxroll=MAXROLL, smoke=SMOKE, n_candidates=length(cands),
            oracle_best_kind=best.kind, oracle_best_makespan=feas_best_mk)
    write_json(OUTFILE, meta, cands2)               # 정답셋을 JSON으로 기록
    println("\n>>> ORACLE BEST = :$(best.kind)  (makespan=$(feas_best_mk))")
    println(">>> wrote $(OUTFILE)")
    println(">>> ranking: ", join(["$(c.kind)#$(findfirst(==(c),ranked))" for c in cands], "  "))
end

main()   # 스크립트 실행 시작점

