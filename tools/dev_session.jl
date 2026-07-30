# =============================================================================
#  [한국어 안내]  이 파일이 하는 일 (처음 보는 사람용 요약)
#  ---------------------------------------------------------------------------
#  ConstructionBots(여러 로봇 협력 조립 시뮬레이터)에서 Julia 코드를 "빠르게 반복 수정"
#  하기 위한 개발용 세션 도우미다. 문제는: 패키지 precompile(85초) + env 빌드(수 분)가
#  프로세스마다 드는 큰 비용이라는 것. 그래서 REPL(대화형 세션)을 한 번만 켜두고,
#  Revise(코드 자동 재적재 도구)로 소스 수정분만 즉시 반영한 뒤, 미리 만들어 캐시해 둔
#  base env의 deepcopy(깊은 복사) 위에서 검증 함수(t/resume_test/zone_test 등)를 다시
#  돌린다. → precompile·env 빌드를 매번 다시 하지 않아 반복이 훨씬 빠르다.
#
#  프로젝트 안에서의 역할: replan.jl / verifier.jl / llm_bridge.jl 같은 respec 관련
#  코드를 고칠 때, 실제 시뮬 동작(재개·재배정·구역회피·재배치)이 여전히 옳은지 빠르게
#  확인하는 "작업대(REPL harness)". 실행법은 아래 헤더의 커맨드 참고.
#
#  Julia 문법 참고 (파이썬과 다른, 헷갈리기 쉬운 것들):
#   · using Revise / using ConstructionBots : 패키지 불러오기. Revise는 소스 수정을
#       자동 감지해 다음 호출 전에 다시 적재해준다(REPL을 껐다 켤 필요 없음).
#   · const CB = ConstructionBots : 긴 모듈명에 짧은 별명(CB). CB.함수 = 모듈 안 함수.
#   · `!` 로 끝나는 함수(step_environment! 등) = 인자를 직접 바꾼다(in-place)는 관례.
#   · deepcopy(x) : 완전 독립 복사본. 원본 env를 건드리지 않고 실험하려고 씀
#       (주의: Serialization은 캐시된 transform을 망가뜨려 쓰면 안 됨 — 주석 참고).
#   · `Ref{T}(...)` = 값 하나 담는 상자, `ref[]` 로 읽고 씀. Threads.Atomic도 비슷.
#   · `x -> ...`, `function ... end` = 익명/명명 함수. `do ... end` = 마지막 인자로
#       넘기는 익명함수 블록.
#   · `x === nothing` = 정확히 nothing인가 비교. nothing = 값 없음(파이썬 None 비슷).
#   · `:심볼`(예: :complete, :asserted) = 짧고 고정된 라벨(상태 태그로 씀).
#   · 함수 위 """..."""(docstring) = 그 함수의 설명문서(help로 볼 수 있음).
#   · `@__MODULE__`, `@warn` 등 `@`로 시작 = 매크로(컴파일 전에 코드를 바꿔주는 장치).
# =============================================================================
# dev_session.jl  --  Persistent Revise REPL for FAST Julia-side iteration.
#
# The 85s precompile + minutes-long env build is a PER-PROCESS cost. Pay it ONCE
# by keeping a REPL open with Revise, then hot-reload code edits (replan.jl,
# verifier.jl, llm_bridge.jl, ...) with NO re-precompile and NO rebuild, and
# re-run the LLM-FREE timing test on a fresh deepcopy of the cached base env.
#
# Start it once:
#     julia +lts --project=. -i tools/dev_session.jl
#
# Then, after editing Julia source, at the REPL just call:
#     t()        # re-run the timing-persistence check on a fresh env copy
#     rebuild()  # only if you changed the env build / stepping itself
#
# Revise reloads the edited functions automatically before t() runs.
# =============================================================================
using Revise                                                # 소스 수정을 자동 재적재해주는 도구
using ConstructionBots                                      # 시뮬레이터 본체
import Graphs, Logging, HiGHS, JuMP                         # 그래프/로깅/MILP solver/모델링 라이브러리
const CB = ConstructionBots                                 # 짧은 별명

# MILP solver(HiGHS) 기본 설정 — 제한시간 300초, gap 5.0(대충 빨리), 로그 끔.
CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!(
    "time_limit" => 300.0, "presolve" => "on", "mip_rel_gap" => 5.0,
    CB.MOI.Silent() => true)

# run_with_stack : 함수 f 를 스택을 크게 늘린 별도 Task에서 실행(깊은 재귀로 인한 스택 오버플로 방지).
#   f=실행할 무인자 함수, stacksize=새 태스크에 줄 스택 크기(바이트).
function run_with_stack(f, stacksize::Int)
    result = Ref{Any}(nothing); err = Ref{Any}(nothing)     # 결과/에러를 담을 상자
    done = Threads.Atomic{Bool}(false)                      # 완료 플래그(스레드 안전)
    wrapper = function ()                                    # 태스크가 실제로 돌릴 본문
        try result[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end
    end
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int), wrapper, nothing, stacksize)  # 큰 스택 태스크 생성(런타임 C함수 호출)
    t.sticky = false; schedule(t)                           # 실행 시작
    while !done[]; sleep(0.05); end                         # 끝날 때까지 대기(폴링)
    if err[] !== nothing                                    # 에러났으면 출력 후 다시 던짐
        e, bt = err[]; showerror(stderr, e, bt); println(stderr); rethrow(e)
    end
    return result[]                                         # f 의 반환값
end

# build_base_env : tractor 프로젝트로 env를 빌드하고 초반 mid-build(closed>=8)까지 진행시켜 돌려줌.
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
            save_milp_solution=false, return_env_before_sim=true)  # true = 시뮬 직전 상태의 env만(빌드만)
    end
    for _ in 1:4000
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)  # 한 스텝 전진 + 계획 캐시 갱신
        length(env.cache.closed_set) >= 8 && break           # 닫힌 노드 8개 이상이면 멈춤
    end
    return env
end

# Cached once; deepcopy per test (deepcopy is FAITHFUL — never use Serialization,
# which corrupts cached transforms; see the timing-persistence gap doc).
# BASE_ENV : 딱 한 번 만들어 캐시하는 기준 env. 각 테스트는 이걸 deepcopy해서 쓴다(원본 불변).
println(">>> building base env once (this is the slow part, ~minutes)...")
const BASE_ENV = build_base_env()
println(">>> base env ready: $(Graphs.nv(BASE_ENV.sched)) nodes, closed=$(length(BASE_ENV.cache.closed_set))")

# rebuild : env 빌드/스텝 로직 자체를 고쳤을 때만 BASE_ENV를 다시 만든다(const 재정의를 Core.eval로 강제).
rebuild() = (global BASE_ENV; Core.eval(@__MODULE__, :(const BASE_ENV = $(build_base_env()))); nothing)

# Re-run the LLM-FREE timing-persistence check on a FRESH copy. Edit replan.jl etc.,
# then call t() — Revise reloads first. Returns true iff a binding ForbidWindow
# (the timing-only re-spec, which adds NO edge) persists past commit via the
# written MILP times alone.
# t : "타이밍만 바꾸는 re-spec(ForbidWindow)이 커밋 후에도 유지되는가"를 빠르게 확인하는 검증 함수.
#   ForbidWindow는 엣지를 추가하지 않고 MILP가 쓴 시각(t0/tF)만으로 효과가 남아야 한다 — 그게 유지되는지 본다.
function t()
    env = deepcopy(BASE_ENV)                                # 원본 보호용 복사
    asm = CB.AbstractID[]                                   # 아직 안 닫히고 안 활성인 조립완료 노드 후보들
    for v in Graphs.vertices(env.sched)
        (v in env.cache.closed_set || v in env.cache.active_set) && continue  # 이미 닫힘/활성이면 제외
        get_node(env.sched, v).node isa CB.AssemblyComplete && push!(asm, CB.get_vtx_id(env.sched, v))
    end
    chosen = nothing
    for tgt in asm                                         # 승인 가능한(binding) ForbidWindow를 하나 찾는다
        vt  = CB.get_vtx(env.sched, tgt)
        t0n = Float64(CB.get_t0(env.sched, vt))            # 이 노드의 현재 시작시각
        prop = CB.RespecProposal([CB.ForbidWindow(tgt, 0.0, t0n + 10.0)])  # [0, t0+10] 금지창 제안(시작을 10 미룸)
        inv = CB.build_invariant(env)
        CB.verify(prop, env, inv) isa CB.Admit || continue  # 검증 통과(Admit)하는 것만 채택
        chosen = (tgt, vt, t0n + 10.0, prop, inv); break
    end
    chosen === nothing && (println("no admittable binding ForbidWindow"); return false)  # 없으면 실패로 종료
    tgt, vt, t_hi, prop, inv = chosen                      # 튜플 분해 대입
    milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;  # 제안을 넣어 MILP 재구성
        optimizer=CB._respec_optimizer(), t0_=inv.frozen_t0, tF_=inv.frozen_tF,
        extra_constraints=prop)
    CB.optimize!(milp)
    CB.commit_respec!(env, milp, prop)                     # 결과 커밋
    t0a = CB.get_t0(env.sched, vt)                         # 커밋 후 실제 시작시각
    ok = t0a >= t_hi - 1e-6                                # 시작이 금지창 끝(t_hi) 이후로 밀렸으면 성공
    println("ForbidWindow($tgt, 0, $(round(t_hi,digits=2))): t0[node]=$(round(t0a,digits=2)) >= t_hi ? ", ok ? "✅ PASS" : "❌ FAIL")
    return ok
end

# -----------------------------------------------------------------------------
# RESUME full-loop fast check (LLM-free). Mirrors the user's actual scenario:
# a robot faults mid-build -> verified reassignment -> the sim RESUMES and drives
# the build to completion WITHOUT restarting already-finished work. Asserts the
# resume invariants the autonomy workflow's done-gate requires:
#   (1) closed_set never regresses at the commit (resume keeps progress), and
#   (2) the sim reaches project_complete with closed_set monotone throughout.
# Edit reset_cache_resume!/commit_respec!/fault_robot_and_reassign! -> Revise
# reloads -> call resume_test() again. No rebuild, no LLM.
# -----------------------------------------------------------------------------

# _advance_to : env를 목표 closed 수 또는 완공까지 최대 cap 스텝 전진(더 깊은 mid-build 상태로).
"Advance a fresh sim copy to a deeper mid-build state (>= `target_closed` closed)."
function _advance_to(env; target_closed::Int, cap::Int)
    for _ in 1:cap
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
        (length(env.cache.closed_set) >= target_closed || CB.project_complete(env)) && break
    end
    return env
end

# _pick_faultable_agent : 대기중 운반팀에 속한(고장내면 진짜 재배정을 유발하는) 유효 로봇 하나를 고름.
"Pick a still-valid robot that is on a PENDING transport team (so faulting it forces a real reassign)."
function _pick_faultable_agent(env)
    sched = env.sched
    seen = CB.AbstractID[]                                   # 이미 본 로봇id(중복 방지)
    for v in Graphs.vertices(sched)
        node = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        node isa CB.RobotGo || continue
        rid = try CB.entity(node).id catch; nothing end
        (rid isa CB.RobotID && CB.valid_id(rid) && !(rid in seen)) || continue  # 유효·미중복 로봇만
        push!(seen, rid)
    end
    for rid in seen
        !isempty(CB.transport_teams_with_agent(env, rid; pending_only = true)) && return rid  # 대기팀 있는 첫 로봇
    end
    return isempty(seen) ? nothing : first(seen)             # 없으면 아무 로봇이나(또는 nothing)
end

# _run_to_end : env를 완공 또는 assertion까지 돌리고 (상태, 닫힌수, 반복수, 단조증가여부)를 반환.
#   status 심볼: :complete(완공)/:asserted(중간 assert)/:capped(cap 소진). mono=진행이 되돌아가지 않았나.
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

"""
    resume_test(; target_closed=24, cap=60_000) -> Bool

VERIFIED green check for the resume INFRASTRUCTURE (`reset_cache_resume!`): take a
mid-build env, rebuild the planning frontier WITHOUT a schedule change, and confirm
the sim resumes to a complete, valid build with `closed_set` monotone. This is the
isolation that proved the frontier recompute is sound (no reassignment involved).
"""
# resume_test : 재배정 없이 "resume 인프라(reset_cache_resume!)만" 검증 — 프론티어만 재계산 후 완공되는지.
function resume_test(; target_closed::Int = 24, cap::Int = 60_000)
    env = deepcopy(BASE_ENV)                                 # 원본 보호용 복사
    _advance_to(env; target_closed = target_closed, cap = cap)
    n0 = length(env.cache.closed_set); total = Graphs.nv(env.sched)
    CB.reset_cache_resume!(env.cache, env.sched)     # frontier recompute, no schedule change (스케줄 변경 없이 프론티어만 재계산)
    n1 = length(env.cache.closed_set)
    st = _run_to_end(env; cap = cap)
    pass = st[1] == :complete && st[4] && n1 >= n0           # 완공 + 단조 + resume 후 진행 유지 = 통과
    println("resume_test: closed $n0 ->(resume) $n1 ->(end) $(st[2])/$total | " *
            "status=$(st[1]) monotone=$(st[4]) iters=$(st[3]) -> ", pass ? "✅ PASS" : "❌ FAIL")
    return pass
end

"""
    reassign_resume_test(; target_closed=24, cap=100_000) -> Symbol

KNOWN-OPEN check: robot-fault -> reassign -> resume to completion. Currently returns
`:asserted` because the reassignment double-books a healthy robot (see
docs/resume_fulloop_status_2026-06-23.md). Use this to iterate on the reassignment
id-threading fix; it should return `:complete` once that bug is closed.
"""
# reassign_resume_test : 로봇 고장 -> 재배정 -> resume 완공까지 가는지 검증(재배정 id 재연결 버그의 반복 수정용).
function reassign_resume_test(; target_closed::Int = 24, cap::Int = 100_000)
    env = deepcopy(BASE_ENV)
    _advance_to(env; target_closed = target_closed, cap = cap)
    n0 = length(env.cache.closed_set); total = Graphs.nv(env.sched)
    agent = _pick_faultable_agent(env)
    agent === nothing && (println("no valid robot to fault"); return :no_agent)  # 고장낼 로봇 없으면 종료
    res = CB.fault_robot_and_reassign!(env, agent; resume = true, verbose = false)  # 고장 + 재배정
    res.status == :admitted || (println("reassign $(res.status)"); return res.status)  # 재배정 승인 안 되면 중단
    st = _run_to_end(env; cap = cap)
    println("reassign_resume_test fault=$agent: closed $n0 ->(commit) $(length(env.cache.closed_set)) " *
            "->(resume) $(st[2])/$total | status=$(st[1]) monotone=$(st[4]) iters=$(st[3])")
    return st[1]
end

# -----------------------------------------------------------------------------
# OOD 1-2 :: restriction-district (navigation no-go zone) GENERATION check.
# LLM-free, no full motion stack needed: validates the injection plumbing and the
# REAL avoidance consumer (get_closest_interfering_circle, the live TangentBug
# path) — NOT the buggy/dead circle_avoidance_policy. Confirms:
#   control       — with no zone, nothing interferes;
#   plumbing      — a registered zone enters active_staging_circles(env) (the
#                   obstacle set get_twist_cmd feeds TangentBug) with right geom;
#   detour        — a zone ON the pos->goal segment is flagged as interfering;
#   no-false-pos  — a zone OFF the path is NOT flagged.
# Edit ood_injection.jl / active_staging_circles -> Revise reloads -> zone_test().
# -----------------------------------------------------------------------------
# zone_test : 통행금지구역(ForbidZone) 주입과 실제 회피 소비자(TangentBug 경로)가 제대로 작동하는지 4가지로 확인.
function zone_test()
    env = deepcopy(BASE_ENV)
    CB.clear_restriction_zones!()                            # 기존 구역 청소
    pol = CB.TangentBugPolicy(; agent_radius = 0.5)          # 실제 회피 정책(로봇 반경 0.5)
    L = 20.0
    pos = [0.0, 0.0]; goal = [L, 0.0]                        # 출발점 -> 목표점(원점에서 x축으로 20)

    # (control) no zones registered -> nothing interferes on the path
    # (대조군) 구역이 없으면 경로에 걸리는 게 없어야 한다
    id0, _, _ = CB.get_closest_interfering_circle(pol, CB.active_restriction_zones(), pos, goal)  # _,_ = 안 쓰는 반환값
    ctrl_ok = id0 === nothing

    # inject a zone squarely on the pos->goal segment
    CB.add_restriction_zone!(:t, [L / 2, 0.0], 1.0)         # 경로 한가운데(x=10)에 반경1 구역 :t 주입

    # (plumbing) the zone is in the obstacle set TangentBug actually reads
    # (배선) 주입한 구역이 TangentBug가 실제로 읽는 장애물 집합에 올바른 기하로 들어갔나
    obs = Dict{Any,Any}(collect(CB.active_staging_circles(env)))
    plumb_ok = haskey(obs, :t) &&
               isapprox(CB.get_center(obs[:t]), [L / 2, 0.0]; atol = 1e-9) &&  # isapprox = 부동소수 근사비교
               isapprox(CB.get_radius(obs[:t]), 1.0; atol = 1e-9)

    # (avoidance) the on-path zone is flagged as the closest interfering circle
    # (회피) 경로 위 구역이 "가장 가까운 방해 원"으로 잡히는가
    id1, _, _ = CB.get_closest_interfering_circle(pol, CB.active_restriction_zones(), pos, goal)
    detour_ok = id1 == :t

    # (no false positive) a zone far OFF the path is NOT flagged
    # (오탐 없음) 경로에서 멀리 떨어진(y=100) 구역은 잡히면 안 된다
    CB.clear_restriction_zones!()
    CB.add_restriction_zone!(:off, [L / 2, 100.0], 1.0)
    id2, _, _ = CB.get_closest_interfering_circle(pol, CB.active_restriction_zones(), pos, goal)
    fp_ok = id2 === nothing

    CB.clear_restriction_zones!()
    pass = ctrl_ok && plumb_ok && detour_ok && fp_ok        # 4가지 모두 통과해야 성공
    println("zone_test: control=$ctrl_ok plumbing=$plumb_ok detour=$detour_ok no-false-pos=$fp_ok -> ",
            pass ? "✅ PASS" : "❌ FAIL")
    return pass
end

# -----------------------------------------------------------------------------
# OOD 1-2 :: ForbidZone RE-STAGING check (LLM-free geometric recovery).
# A no-go zone is dropped ON a not-yet-built assembly's staging area (which would
# deadlock the build), restage_assembly! relocates that assembly clear of the
# zone, and the sim must RESUME to a complete build. Asserts:
#   (1) status :restaged and the new center clears the zone,
#   (2) closed_set monotone + reaches project_complete (the rigid move kept the
#       staging subtree coherent -> the done-gate for §7.3).
# Edit restage_zone.jl -> Revise reloads -> restage_test().
# -----------------------------------------------------------------------------
# restage_test : 아직 안 지은 조립의 스테이징 구역에 금지구역을 떨어뜨렸을 때, restage_assembly!가 그 조립을 옮기고 완공되는지 검증.
function restage_test(; target_closed::Int = 24, cap::Int = 60_000)
    env = deepcopy(BASE_ENV)
    _advance_to(env; target_closed = target_closed, cap = cap)
    # root = the assembly whose staging circle is largest (encompasses the whole
    # build); never relocate it. Pick the DEEPEST-future SUB-assembly (max t0) that
    # is neither closed nor active.
    # root = 스테이징 원이 가장 큰 조립(빌드 전체를 감쌈) — 절대 옮기지 않는다. argmax(f, xs)=f 최대인 원소.
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))
    aid = nothing; bestt0 = -Inf                            # 옮길 대상: 가장 미래(t0 최대)의 하위조립 찾기
    for k in keys(env.staging_circles)
        k == root && continue                               # root는 제외
        ac = CB._assembly_complete_node(env, k)
        ac === nothing && continue
        v = CB.get_vtx(env.sched, CB.node_id(ac))
        (v in env.cache.closed_set || v in env.cache.active_set) && continue  # 이미 닫힘/활성은 제외
        t0 = Float64(CB.get_t0(env.sched, v))
        t0 > bestt0 && (bestt0 = t0; aid = k)               # 더 미래면 갱신
    end
    aid === nothing && (println("restage_test: no future sub-assembly to restage"); return :no_assembly)

    ball = env.staging_circles[aid]                         # 대상 조립의 스테이징 원(중심·반경)
    c0 = Vector{Float64}(CB.get_center(ball)[1:2]); R = Float64(CB.get_radius(ball))  # 원래 중심(x,y)과 반경
    n0 = length(env.cache.closed_set); total = CB.Graphs.nv(env.sched)

    CB.clear_restriction_zones!()
    CB.add_restriction_zone!(:block, c0, R)            # zone smack on its staging area (스테이징 자리에 정확히 구역 투하)
    res = CB.restage_assembly!(env, aid)               # 그 조립을 구역 밖으로 재배치 시도
    if res.status != :restaged                         # 재배치 실패면 정리하고 종료
        CB.clear_restriction_zones!()
        println("restage_test: status=$(res.status) ($(get(res, :detail, "")))"); return res.status
    end
    c1 = Vector{Float64}(res.to)                       # 옮겨진 새 중심
    clear = CB.norm(c1 .- c0) >= 2R                    # zone r=R, circle r=R -> centers >= 2R apart (중심간 거리>=2R이면 구역서 벗어남)
    st = _run_to_end(env; cap = cap)                   # 재배치 후 끝까지 돌려봄
    CB.clear_restriction_zones!()

    pass = st[1] == :complete && st[4] && clear         # 완공 + 단조 + 구역 벗어남 = 통과
    println("restage_test: asm=$(CB.summary(aid)) $(round.(c0; digits=2))->$(round.(c1; digits=2)) " *
            "closed $n0 ->(end) $(st[2])/$total | status=$(st[1]) monotone=$(st[4]) zone_clear=$clear -> ",
            pass ? "✅ PASS" : "❌ FAIL")
    return pass
end

println("""
>>> dev session ready.
    t()                    timing-persistence check on a fresh env copy
    resume_test()          VERIFIED: resume infrastructure -> build completes
    reassign_resume_test() KNOWN-OPEN: reassign+resume (asserts on double-booking)
    zone_test()            OOD 1-2: restriction-zone injection + TangentBug avoidance
    restage_test()         OOD 1-2: ForbidZone re-staging recovery -> build completes
    rebuild()              rebuild BASE_ENV (only if you changed the build/stepping)
""")
