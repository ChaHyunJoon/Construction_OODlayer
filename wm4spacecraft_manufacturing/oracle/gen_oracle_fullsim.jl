# =============================================================================
# gen_oracle_fullsim.jl -- Oracle eval-set generator, built on the VERIFIED full-sim harness.
#
# Supersedes gen_oracle_faults.jl (a hand-rolled bare-step-loop harness whose results were
# invalid — see ../ORACLE_FINDINGS.md). This one is a thin variant of
# `ConstructionBots.jl/tools/ood_compare_fullsim.jl`: instead of sweeping CONTROLLERS
# (no-adapt / LLM / RL / canonical) through `run_one(producer)`, we sweep the CANDIDATE
# DSL MACROS through the same `run_one`, plus a no-fault CONTROL.
#
# Why this harness (and not deepcopy-forking):
#   * `run_lego_demo(return_env_before_sim=false)` runs the PRODUCTION sim loop
#     (ood_inject_step! + respec_step! every step, reform recovery, no-progress guard).
#   * Full motion stack ON (RVO/TangentBug/dispersion). Each candidate REBUILDS the env,
#     so the non-deepcopyable Python RVO2 sim + module globals are never aliased.
#   * `stats[:Makespan]` is the REALIZED execution time (time_steps * dt) — the planned
#     `makespan(sched)` is invariant under no-op and is blind to the disruption cost.
#   * `fault_action(safe=true)` + breakdown immobilization makes an UNADDRESSED fault
#     actually stall the build, so no-adapt is genuinely worse (a consequential instance).
#   * ample spares (NSPARE x 4 dirs) let `replace_robot_distributed!` complete.
#
# Candidates (action ids from decpomdp/examples/ood_env_mdp.jl):
#   0:NOOP  1:ReplaceAgent  2:DeprioritizeAgent  4:ReformTeam
# For a :fault event `valid_actions` masks to [0,1]; we also sweep the UNMASKED mistake
# arms (2,4) because the oracle must rank the whole repertoire a decision-maker could emit.
#
# Run (from the ConstructionBots.jl repo root):
#   julia +lts --project=. <this file>
# Env: ORACLE_ACTIONS="0,1"  (default; add "2,4" for the mistake arms)  NSPARE=3
# =============================================================================
#
# =============================================================================
#  [한국어 설명] gen_oracle_fullsim.jl — "oracle(정답)" 평가셋 생성기 (검증된 full-sim 방식)
#
#  무엇을 하나 / 왜 이게 더 나은가:
#   · gen_oracle_faults.jl(맨-스텝 루프로 손수 짠 버전)을 대체한다. 그 옛 버전의 결과는
#     무효였다(ORACLE_FINDINGS.md 참고). 이 파일은 검증된 full-sim harness 위에 올린 얇은 변형이다.
#   · 각 후보 DSL 매크로를 "production 시뮬 루프 전체(run_lego_demo)"로 처음부터 다시 돌려
#     실제로 실현된(realized) 결과를 얻는다. 그래서 no-op에도 안 변하는 planned makespan이 아니라,
#     진짜 실행시간(stats[:Makespan] = time_steps * dt)을 지표로 쓴다.
#
#  옛 deepcopy-포크 대신 매번 env를 새로 짓는 이유:
#   · 모션 스택(RVO/TangentBug/dispersion)을 켜면 RVO2 시뮬이 deepcopy 안 되는 Python 객체라
#     복사로는 체크포인트가 안 된다 → 후보마다 아예 새로 build 해서 전역/파이썬 상태 공유를 원천 차단.
#   · fault_action(safe=true)+고장 로봇 immobilize로 "대응 안 하면 진짜로 빌드가 멈추게" 만들어야
#     no-adapt(무대응)이 실제로 더 나빠져서 이 사례가 의미(consequential)를 갖는다.
#
#  후보 액션 id(decpomdp/examples/ood_env_mdp.jl 기준):
#   · 0:NOOP 1:ReplaceAgent 2:DeprioritizeAgent 4:ReformTeam
#     (fault 이벤트의 valid_actions는 [0,1]로 마스킹되지만, 오답 팔(2,4)도 함께 재서 전체 레퍼토리를 순위매김)
#
#  프로젝트에서의 역할: ConstructionBots.jl(다중로봇 조립 TAMP 시뮬)에서 OOD 복구 판단을
#   채점할 "정답지"를 만든다. surrogate/LLM은 이 정답과 비교되어 평가된다.
#
#  Julia 문법 참고(처음 보는 사람용):
#   · import X as CB : 모듈 X를 CB라는 짧은 별칭으로. CB.foo 로 접근.
#   · """ ... """ 함수 위 문자열 = docstring(문서). 콜론 심볼 :fault, :reform = 이벤트 종류 이름표(Symbol).
#   · f(a::Int) = (x, y) -> begin ... end : 인자 a를 받아 "함수를 돌려주는 함수"(클로저). 반환된 함수가 (x,y)를 받음.
#   · Ref{T}(v) = 한 칸 가변 상자, v[]로 읽고 씀. get(ENV, "K", "기본") = 환경변수 K 읽되 없으면 기본값.
#   · a ? b : c = 삼항 조건식. `!==` = "같지 않음(정확 비교)". `&&` 뒤 문장 = 앞이 참일 때만 실행(짧은-회로).
#   · @printf, @sprintf = C 스타일 서식 출력 매크로. do ... end = 마지막 인자로 넘기는 익명함수 블록.
#   · try ... catch end (본문 비움) = 에러 나도 무시하고 넘어가기. NamedTuple = 이름표 붙은 값묶음.
# =============================================================================
import ConstructionBots as CB
import HiGHS, Logging, Random, Graphs         # HiGHS=MILP솔버, Random=난수, Graphs=그래프 유틸
using Printf                                  # @printf 서식 출력용

# _EX = decpomdp/examples 폴더 경로. pkgdir(CB)=CB 패키지 루트, dirname=그 상위폴더.
const _EX = joinpath(dirname(pkgdir(CB)), "decpomdp", "examples")
include(joinpath(_EX, "ood_env.jl"))          # OOD 환경 정의를 이 스코프로 불러옴
include(joinpath(_EX, "ood_env_mdp.jl"))     # event_context, action_to_proposal, valid_actions
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))   # fault_action (world-age)

# MILP 솔버 설정(60초 제한, 5% gap 허용, 조용히).
CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 60.0, "mip_rel_gap" => 0.05,
    "output_flag" => false, "presolve" => "on")

# NSPARE = 방위별 예비 로봇 수(환경변수 NSPARE, 기본 3). 실제 스페어는 4방위 x NSPARE.
const NSPARE  = parse(Int, get(ENV, "NSPARE", "3"))
# ACTIONS = 재볼 후보 액션 id 목록("0,1"을 쉼표로 쪼개 정수 변환). comprehension으로 파싱.
const ACTIONS = [parse(Int, s) for s in split(get(ENV, "ORACLE_ACTIONS", "0,1"), ",")]
# RVO=1 (default): full motion stack — faithful but ~1h per candidate (25s/batch, 22 agents).
# RVO=0: production simulate! loop WITHOUT the reactive motion stack — ~10x cheaper. Use only
# after confirming the candidate RANKING is preserved vs an RVO=1 reference (see ORACLE_FINDINGS).
# RVO = 모션 스택 켜기 여부(기본 켜짐). 켜면 충실하지만 후보당 ~1시간, 끄면 ~10배 빠름(순위 보존 확인 후에만 사용).
const RVO     = get(ENV, "RVO", "1") == "1"
# ORACLE_LOG=info exposes the @info "[RESPEC] ..." dispatch lines (which branch a ReplaceAgent
# actually took: hot-swap / distributed / single-spare / reassign). Default warn = quiet.
# LOGLVL = 로그 상세도. ORACLE_LOG=info면 [RESPEC] 디스패치 로그까지 보임, 기본 warn은 조용.
const LOGLVL  = lowercase(get(ENV, "ORACLE_LOG", "warn")) == "info" ? Logging.Info : Logging.Warn
# ORACLE_ONLY: run exactly ONE unit in this process and write its own JSON, so candidates can be
# run as PARALLEL processes (the only viable cost reduction — RVO cannot be disabled, see
# ORACLE_FINDINGS §7). Values: "control" | "<action int>" | "" (= run everything in-process).
# ONLY = 이 프로세스에서 딱 한 유닛만 돌릴지("control" 또는 액션 숫자). 비면 전체를 한 프로세스에서. 병렬화용.
const ONLY    = get(ENV, "ORACLE_ONLY", "")
# SEED varies the build/assignment RNG -> a genuinely DIFFERENT oracle instance (different fault
# target and progress point). Each seed is one eval-set instance; sweep several to build the set.
# (`run_lego_demo`'s own default rng is MersenneTwister(1), so SEED=1 reproduces the default build.)
# SEED = 빌드/배정 난수 시드. 값이 다르면 고장 대상·진행지점이 달라져 "다른 oracle 사례"가 된다.
const SEED    = parse(Int, get(ENV, "ORACLE_SEED", "1"))
# _SUF = 출력 파일명 접미사(RVO끔/시드/단일유닛 여부에 따라 붙음). `*` = 문자열 이어붙이기.
const _SUF    = (RVO ? "" : "_norvo") * (SEED == 1 ? "" : "_s$(SEED)") *
                (isempty(ONLY) ? "" : "_$(ONLY)")
const OUTFILE = joinpath(@__DIR__, "out", "oracle_fullsim_fault$(_SUF).json")  # 결과 JSON 경로
const ACTION_NAME = Dict(0=>"NOOP", 1=>"Replace", 2=>"Deprioritize", 3=>"ForbidZone", 4=>"ReformTeam")  # 액션 id→이름

# --- record the context of the STUDIED (fault) event ------------------------------------
# 연구 대상(fault) 이벤트의 맥락을 기록해 두는 전역 상자들.
const SEEN     = Ref{Any}(nothing)   # ctx of the FIRST :fault event (not the last event seen)  # 첫 fault 이벤트 맥락
const N_EVENTS = Ref(0)              # how many OOD events the producer was asked about          # producer가 물어본 OOD 이벤트 수

# oracle_prod(a) : 액션 a를 "연구 대상 fault 이벤트에서만" 내는 producer 함수를 만들어 반환(클로저).
# 그 외 모든 이벤트(특히 자동 :reform 알람)에는 후보와 무관하게 항상 canonical(표준) 대응을 준다 → 공정성 불변식.
"""
    oracle_prod(a) -> (env, event) -> proposal | nothing

Plays candidate action `a` **only at the studied `:fault` event**. Every OTHER event —
notably the auto-emitted `:reform` "team deadlocked" alarm (`set_reform_interval!`) — gets the
CANONICAL response, identically for every candidate.

Why: the sim emits reform events whose ReformTeam response drives the endgame recovery
(`recover_stalled_teams!` -> `resolve_schedule_wedge!`). Replaying a fixed action at *every*
event silently disables that recovery for all candidates, so nothing completes and the ranking
is measured in a crippled world (observed: control COMPLETE 291/313 but every candidate stuck
at 237-263). Holding the background policy fixed makes the fault response the ONLY variable —
the fairness invariant — and mirrors how `ood_compare_fullsim.jl`'s controllers behave.
"""
oracle_prod(a::Int) = (env, ev) -> begin
    ctx = event_context(env, ev)                 # 이벤트의 맥락(종류·대상 에이전트 등) 추출
    N_EVENTS[] += 1                              # 물어본 이벤트 수 카운트
    if ctx.type === :fault
        SEEN[] === nothing && (SEEN[] = (type=String(ctx.type), agent=string(ctx.agent),
                                         valid=valid_actions(ctx)))  # 첫 fault 이벤트만 기록
        a == 0 && return nothing                 # deliberate NOOP on the studied event
        return action_to_proposal(ctx, a)        # nothing if ungrounded -> degenerates to NOOP
    end
    # background events (reform / anything else): canonical, identical across candidates
    return action_to_proposal(ctx, canonical_action(ctx))  # 배경 이벤트는 모든 후보에 동일한 표준 대응
end

"Background-only producer (no fault is injected): canonical on every event. Used for the control."
# canonical_bg : 고장을 주입하지 않는 대조군(control)용 producer — 모든 이벤트에 표준 대응만.
canonical_bg(env, ev) = begin
    ctx = event_context(env, ev)
    N_EVENTS[] += 1
    action_to_proposal(ctx, canonical_action(ctx))
end

# run_with_stack : 함수 f를 큰 스택 크기의 별도 Task로 실행(깊은 스케줄의 스택 오버플로 방지). 파일1과 동일 패턴.
function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)  # 결과/에러/완료 상자
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)  # 큰스택 Task 생성
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end   # 스케줄 후 끝날 때까지 대기
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))  # 에러 있으면 다시 던짐
    return res[]
end

"Schedule ONE safe (solo-target) robot breakdown; fires at the first progress point where a
 solo target exists. Identical to tools/ood_compare_fullsim.jl::schedule_safe_fault!."
# 안전한(solo 대상) 로봇 고장 1건을 예약. solo 대상이 처음 생기는 진행지점에서 딱 한 번 발동.
function schedule_safe_fault!()
    fired = Ref(false)                            # 이미 발동했는지 표시(한 번만 터지게)
    tf = CB.fault_action(; safe = true, obstacle = false, clear = true)  # 순수 교체형 고장 생성기
    act = e -> fired[] ? nothing : (nl = tf(e); nl === nothing ? nothing : (fired[] = true; nl))  # 아직 안 터졌고 대상 있으면 발동
    for c in (12, 20, 30, 45, 60); CB.schedule_ood_at_closed!(c, act); end  # 닫힌노드 수가 이 값들일 때 시도
end

# run_one : producer prod를 re-spec seam에 꽂고 full 시뮬을 한 번 완주시켜 결과지표 반환.
# inject=false면 고장 없는 건강한 대조군(control).
"Run ONE full simulation with `prod` plugged into the respec seam. `inject=false` => healthy control."
function run_one(prod; inject::Bool = true)
    SEEN[] = nothing; N_EVENTS[] = 0             # 실행마다 기록 상자 초기화
    CB.RESPEC_ENABLED[] = true
    for f in (:clear_ood_schedule!, :clear_restriction_zones!, :clear_spare_pools!, :clear_faulted_robots!,
              :clear_recovery_spares!, :clear_ood_truth_log!, :clear_wedge_edges!, :clear_stalled_robots!)
        try getproperty(CB, f)() catch end        # 이전 실행이 남긴 전역상태를 이름으로 하나씩 clear(없으면 무시)
    end
    try CB.set_reform_interval!(400) catch end    # reform 알람 주기 설정
    CB.set_respec_producer!(prod)                 # 이번 실행이 쓸 producer 장착
    inject && schedule_safe_fault!()              # 고장 주입 모드면 안전 고장 예약
    res = run_with_stack(2_000_000_000) do        # 큰 스택으로 production 데모 실행
        CB.run_lego_demo(; ldraw_file = "tractor.mpd", num_robots = 10, assignment_mode = :greedy,
            milp_optimizer = :highs, optimizer_time_limit = 60, log_level = LOGLVL,
            max_num_iters_no_progress = 30000, rvo_flag = RVO, tangent_bug_flag = RVO,
            dispersion_flag = RVO, n_spare_per_pool = NSPARE, save_animation = false,
            open_animation_at_end = false, write_results = false, overwrite_results = true,
            return_env_before_sim = false, rng = Random.MersenneTwister(SEED))  # 시뮬을 끝까지 실행(SEED로 재현)
    end
    CB.clear_respec_producer!(); CB.RESPEC_ENABLED[] = false   # 뒷정리: producer 제거, re-spec 끔
    env   = res isa Tuple ? res[1] : res          # 반환이 (env, stats)면 첫째가 env
    stats = res isa Tuple ? res[2] : Dict()       # 둘째가 통계(없으면 빈 Dict)
    complete = CB.project_complete(env)           # 완주 여부
    closed   = length(env.cache.closed_set)       # 닫힌(완료) 노드 수
    total    = length(CB.get_nodes(env.sched))    # 전체 노드 수
    mk       = try Float64(get(stats, :Makespan, NaN)) catch; NaN end   # REALIZED time  # 실현 makespan(실행시간)
    return (complete=complete, closed=closed, total=total, makespan=mk, seen=SEEN[],
            n_events=N_EVENTS[])
end

# --- feasibility-lexicographic: completion first, then REALIZED makespan ---------------
# a가 b보다 나은가? 사전식: 완주여부 → 닫힌노드 수(많을수록) → 실현 makespan(짧을수록).
better(a, b) = a.complete != b.complete ? a.complete :
               a.closed   != b.closed   ? a.closed > b.closed :
               a.makespan < b.makespan

# 최소 JSON 도구(파일1과 동일): 문자열 escape, 값 변환, 객체 변환, 파일 쓰기.
jesc(s) = replace(replace(String(s), "\\" => "\\\\"), "\"" => "\\\"")   # 역슬래시·따옴표 escape
jval(x) = x isa Bool ? (x ? "true" : "false") :
          x isa AbstractString ? "\"$(jesc(x))\"" :
          x isa Real ? (isfinite(x) ? string(x) : "\"$(x)\"") : "\"$(x)\""  # 무한대/NaN은 문자열로
jobj(nt) = "{" * join(["\"$(k)\":$(jval(getproperty(nt,k)))" for k in propertynames(nt)], ",") * "}"  # NamedTuple→JSON객체
function write_json(path, meta, rows)
    open(path, "w") do io
        println(io, "{"); println(io, "  \"meta\": $(jobj(meta)),"); println(io, "  \"candidates\": [")
        for (i,c) in enumerate(rows); println(io, "    ", jobj(c), i < length(rows) ? "," : ""); end
        println(io, "  ]"); println(io, "}")
    end
end

# main_only : 유닛 하나(control 또는 액션 하나)만 돌려 자기 JSON을 쓴다 → 여러 프로세스로 병렬 실행용.
"Run exactly one unit (control or a single action) and write its own JSON. For parallel processes."
function main_only(tag::String)
    println("[oracle] SINGLE unit '$tag'  rvo=$RVO  spares=$(4*NSPARE)")
    if tag == "control"                            # 대조군: 고장 없이 실행
        r = run_one(canonical_bg; inject = false)
        @printf("CONTROL(nofault) %s %d/%d  makespan=%.1f  events=%d\n", r.complete ? "YES" : "no",
                r.closed, r.total, r.makespan, r.n_events)
        row = (unit="control", action=-1, name="control", complete=r.complete, closed=r.closed,
               total=r.total, makespan=r.makespan, fault_seen=false, n_events=r.n_events,
               event_type="none", agent="none")   # 대조군 한 줄 기록
    else
        a = parse(Int, tag)                        # tag를 액션 숫자로 파싱
        r = run_one(oracle_prod(a))                # 그 액션을 fault 이벤트에 넣어 실행
        @printf("%d:%s %s %d/%d  makespan=%.1f  events=%d fault_seen=%s\n", a, ACTION_NAME[a],
                r.complete ? "YES" : "no", r.closed, r.total, r.makespan, r.n_events,
                r.seen !== nothing)
        row = (unit="candidate", action=a, name=ACTION_NAME[a], complete=r.complete, closed=r.closed,
               total=r.total, makespan=r.makespan,
               fault_seen=(r.seen !== nothing), n_events=r.n_events,
               event_type=(r.seen===nothing ? "NO_FAULT_EVENT" : r.seen.type),
               agent=(r.seen===nothing ? "none" : r.seen.agent))
    end
    meta = (project="tractor", ood_class="robot_fault", n_robots=10, rvo=RVO, seed=SEED,
            n_spare_per_pool=NSPARE, spares=4*NSPARE, unit=tag)   # 이 유닛의 메타정보
    write_json(OUTFILE, meta, [row])
    println("wrote $(OUTFILE)")
end

# main : 전체 진입점 — 대조군 + 모든 후보 액션을 순서대로 돌려 순위·admissibility 계산 후 JSON 저장.
function main()
    isempty(ONLY) || return main_only(ONLY)        # ONLY 지정돼 있으면 단일유닛 모드로 빠짐

    println("[oracle] full-sim candidate sweep. rvo=$RVO spares=$(4*NSPARE)  actions=$(ACTIONS)")
    println(rpad("candidate",16), rpad("complete",10), rpad("closed/total",14), "makespan(realized)")
    println(repeat("-", 62))

    # --- healthy control (no fault at all): the admissibility reference -----------------
    ctrl = run_one(canonical_bg; inject = false)   # 고장 없는 대조군 실행(=기준선)
    @printf("%-16s%-10s%-14s%.1f\n", "CONTROL(nofault)", ctrl.complete ? "YES" : "no",
            "$(ctrl.closed)/$(ctrl.total)", ctrl.makespan)

    rows = NamedTuple[]
    for a in ACTIONS
        r = run_one(oracle_prod(a))                # 각 후보 액션을 하나씩 실행
        @printf("%-16s%-10s%-14s%.1f\n", "$(a):$(ACTION_NAME[a])", r.complete ? "YES" : "no",
                "$(r.closed)/$(r.total)", r.makespan)
        push!(rows, (action=a, name=ACTION_NAME[a], complete=r.complete, closed=r.closed,
                     total=r.total, makespan=r.makespan,
                     event_type=(r.seen===nothing ? "none" : r.seen.type),
                     agent=(r.seen===nothing ? "none" : r.seen.agent)))
    end
    println(repeat("-", 62))

    ranked = sort(rows, lt=(a,b)->better(a,b))     # better 기준 정렬(좋은 것부터)
    best = ranked[1]                               # 1등 = oracle 정답
    # 각 후보에 정답순위와 정답 대비 regret(makespan 손해)을 붙인 새 목록.
    rows2 = [merge(c, (oracle_rank = findfirst(x -> x.action == c.action, ranked),
                       makespan_regret = (c.complete && best.complete) ? c.makespan - best.makespan : Inf))
             for c in rows]

    # --- admissibility: is this OOD instance informative? -------------------------------
    # admissibility = 이 OOD 사례가 "배울 게 있는" 사례인지 판정(no-op이 대조군보다 확실히 나쁠 때만 유의미).
    noop = findfirst(c -> c.action == 0, rows)     # no-op(액션 0) 결과 찾기
    admissible = false
    if noop !== nothing
        n = rows[noop]                             # no-op의 결과
        # DIRECTION-AWARE: admissible iff no-op is STRICTLY WORSE than the healthy control, in the same
        # feasibility-lexicographic order the oracle ranks by (completion → closed-count → realized
        # makespan). A no-op that merely DIFFERS from the control (e.g. closes MORE nodes, or completes
        # when the control did not) is NOT admissible — the fault would have been harmless or helpful.
        admissible = (ctrl.complete && !n.complete) ||           # 대조군은 완주하는데 no-op은 못하거나
                     (n.closed < ctrl.closed) ||                 # no-op이 노드를 더 적게 닫거나
                     (n.closed == ctrl.closed && isfinite(n.makespan) && isfinite(ctrl.makespan) &&
                      n.makespan > ctrl.makespan + 1e-9)         # 같은 노드수면 makespan이 더 길 때(=더 나쁨)
    end
    println("ORACLE BEST = $(best.action):$(best.name)  (complete=$(best.complete), makespan=$(best.makespan))")
    println("ADMISSIBLE  = $admissible   (no-op must be strictly worse than the healthy control)")
    admissible || println("  !! no-op == control => the fault was harmless; this instance teaches nothing.")

    meta = (project="tractor", ood_class="robot_fault", n_robots=10, rvo=RVO, n_spare_per_pool=NSPARE,
            spares=4*NSPARE, control_complete=ctrl.complete, control_closed=ctrl.closed,
            control_total=ctrl.total, control_makespan=ctrl.makespan,
            admissible=admissible, oracle_best_action=best.action, oracle_best_name=best.name,
            oracle_best_makespan=best.makespan, n_candidates=length(rows2))
    write_json(OUTFILE, meta, rows2)                # 정답셋 JSON 저장
    println("wrote $(OUTFILE)")
end

main()   # 스크립트 실행 시작점

