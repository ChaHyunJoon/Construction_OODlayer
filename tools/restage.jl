# =============================================================================
# tools/restage.jl -- consolidated ConstructionBots restage/relocation validators.
#
# Every standalone tools/restage_*.jl script is now a FUNCTION in module `Restage`,
# sharing common boilerplate (MILP setup + run_with_stack) defined ONCE. A CLI/ENV
# dispatcher at the bottom lets any single validator run individually.
#
# Restage keys:
#   wholebuild -- Phase B whole-build translation under FULL nav: a CENTRAL zone that
#                 covers the root's own deposit goals -> restage_all_blocked! is
#                 :residual_blocked -> translate_whole_build! shifts the ENTIRE build.
#   fullnav    -- restage_assembly! with NAVIGATION ON (TangentBug): forbid zone over a
#                 sub-assembly's staging, relocate, run to completion tracking zone entry.
#   navon      -- restage UNDER full motion stack with a root-clear zone that BLOCKS a
#                 target assembly's build; CONTROL(no restage)/single/all scenarios.
#   validate   -- nav-OFF standalone validation of restage_assembly! + control resume
#                 (+ multi-assembly restage_all), with a cached BASE_ENV for fast reruns.
#
# Run:
#   julia +lts --project=. tools/restage.jl <restage_key>        (or  ENV RESTAGE=<key>)
# e.g.
#   julia +lts --project=. tools/restage.jl navon
#   RESTAGE=validate julia +lts --project=. tools/restage.jl
# Each validator reads its own ENV knobs at call time (see the comment above each function).
# =============================================================================
# =============================================================================
# [한국어 설명]
#  이 파일이 하는 일:
#   - ConstructionBots(다중 로봇 건설 시뮬레이터)에서 "re-staging(재배치) 검증기"들을
#     한 파일(module Restage)에 모아 둔 것. 예전에는 restage_*.jl 로 흩어져 있던
#     스크립트들을 각각 하나의 "함수"로 합치고, MILP 세팅 같은 공통 준비코드를 한 번만
#     정의해 공유한다. 맨 아래 dispatcher가 키(key) 하나로 원하는 검증기를 골라 실행.
#
#  re-staging이란? (프로젝트 맥락)
#   - 시뮬레이션 도중 어떤 구역(zone)이 막히는 OOD(예상 밖 상황)가 생기면, 그 구역에서
#     조립을 준비(staging)하던 로봇/서브어셈블리를 다른 자리로 옮겨(=restage) 빌드를
#     끝까지 완주시키는 기하학적 복구 동작을 검증한다.
#   - 4가지 검증 키:
#       wholebuild -- 중앙 구역이 root의 못 옮기는 목표까지 덮을 때, 빌드 "전체"를 통째로
#                     평행이동(translate_whole_build!)해 구역을 벗어나게 함.
#       fullnav    -- 내비게이션(TangentBug) 켠 상태로 한 서브어셈블리를 재배치하고,
#                     로봇이 금지구역(no-go)에 한 번이라도 들어가는지 추적.
#       navon      -- 전체 모션 스택(rvo+tangent_bug+dispersion) 켠 상태에서 재배치.
#       validate   -- 내비 끈(직선 이동) 상태로 스케줄/기하만 빠르게 검증(BASE_ENV 캐시).
#
#  Julia 문법 참고 (초보용):
#   · module M ... end  = 이름공간(namespace). 여기 함수/상수는 M.foo 로 접근.
#   · const CB = ConstructionBots : 긴 모듈이름에 짧은 별칭(alias) 붙이기.
#   · function f(x::T) : x가 타입 T일 때만 쓰는 메서드(다중 디스패치). 같은 이름을
#     인자 타입만 바꿔 여러 번 정의하면 "타입마다 다른 동작"이 된다.
#   · `!`로 끝나는 함수(step_environment! 등) = 인자를 직접 바꾼다(in-place)는 관례.
#   · :block, :complete 처럼 콜론으로 시작하는 것 = Symbol(가벼운 상수 이름표/enum 대용).
#   · a => b = Pair(키=>값). 딕셔너리/키워드 인자에 자주 쓰임.
#   · f(; k=v) 의 세미콜론 뒤 = 키워드 인자. 호출도 f(; k=v) 또는 f(k=v).
#   · a .- b, norm.(...) 처럼 점(.)이 붙으면 broadcast(원소별 연산).
#   · cond && expr = "cond가 참이면 expr 실행"(짧은 if 대용). cond || expr 는 그 반대.
#   · (status=:x, closed=3) = NamedTuple(이름 붙은 튜플). st.status 처럼 꺼낸다.
#   · get(ENV,"KEY","기본") = 환경변수 읽되 없으면 "기본". ENV = OS 환경변수.
# =============================================================================
module Restage
using ConstructionBots
import Graphs, Logging, HiGHS, JuMP, LinearAlgebra, Serialization
const CB = ConstructionBots            # ConstructionBots를 CB로 줄여 씀(별칭)
const norm = LinearAlgebra.norm        # 벡터 길이/거리 계산 함수에 짧은 이름 붙임

# ---- shared helpers (defined ONCE) ------------------------------------------
# ---- 공통 헬퍼(딱 한 번만 정의해 4개 검증기가 공유) -------------------------
# The set_default_milp_optimizer! block that appears (identically) in all 4 scripts
# (time_limit=300.0, presolve=on, mip_rel_gap=5.0, MOI.Silent). Copied verbatim from
# tools/demos.jl so the two consolidations stay in lock-step.
# 작업 배정에 쓰는 MILP 최적화기(HiGHS)를 기본값으로 설정. time_limit=제한시간(초),
# mip_rel_gap=허용 최적화 오차. `!`이므로 전역 기본 설정을 바꾼다.
function _setup_milp!(; time_limit = 300.0, mip_rel_gap = 5.0)
    CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
    CB.clear_default_milp_optimizer_attributes!()
    CB.set_default_milp_optimizer_attributes!(
        "time_limit" => time_limit, "presolve" => "on", "mip_rel_gap" => mip_rel_gap,
        CB.MOI.Silent() => true)
end

# The identical stack-growing task helper from all 4 scripts (copied verbatim from demos.jl).
# 함수 f를 "스택 크기를 키운 별도 Task"에서 실행(깊은 재귀로 기본 스택이 터지는 걸 방지).
# 끝날 때까지 기다렸다가 결과를 반환하고, 그 Task에서 난 예외는 여기로 다시 던진다.
function run_with_stack(f, stacksize::Int)
    # Ref = 값을 담는 상자(다른 Task가 채운 결과를 밖에서 꺼내려고 사용). Atomic=스레드 안전 플래그.
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),   # ccall = Julia 런타임 C함수 직접 호출(스택 지정 Task 생성)
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end   # 실행 예약 후 끝날 때까지 폴링 대기
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))  # 에러 있으면 다시 던짐
    return res[]
end

# =============================================================================
# wholebuild -- validate Phase B (whole-build translation) under the FULL motion
#   stack (rvo + tangent_bug + dispersion ON). A CENTRAL zone covers the root's own
#   (un-relocatable) deposit goals -> restage_all_blocked! returns :residual_blocked;
#   then translate_whole_build! shifts the ENTIRE build clear of the zone.
#   ENV: NAVON_PROJECT, NAVON_ZONE_R, NAVON_MODE (whole|none).
# =============================================================================
# wholebuild 검증기: 중앙 구역이 root의 못 옮기는 목표까지 덮으면 빌드 전체를 통째로 옮긴다.
function restage_wholebuild()
PROJECT  = parse(Int, get(ENV, "NAVON_PROJECT", "4"))     # 4 = tractor  # 어느 모델을 지을지(환경변수)
ZONE_R   = parse(Float64, get(ENV, "NAVON_ZONE_R", "2.5")) # central zone radius (covers root core)  # 중앙 금지구역 반지름
MODE     = get(ENV, "NAVON_MODE", "whole")               # whole=전체이동 검증 / none=대조군

_setup_milp!()   # MILP 최적화기 기본값 세팅

# 시뮬레이션 초기 환경(BASE_ENV) 구축: 모델 로드+계획 후 조립이 8개 닫힐(closed) 때까지 몇 스텝 전진.
function build_base_env()
    pp = CB.get_project_params(PROJECT)   # 프로젝트 번호로 LEGO 모델 파라미터(파일/스케일/로봇수) 가져오기
    env = run_with_stack(2_000_000_000) do   # 큰 스택(2GB)에서 실행 — 계획이 깊은 재귀를 씀
        CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
            model_scale=pp[:model_scale], num_robots=pp[:num_robots],
            assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,   # greedy 배정 + HiGHS MILP
            log_level=Logging.Error, rvo_flag=true, tangent_bug_flag=true,   # rvo=충돌회피, tangent_bug=내비 ON
            dispersion_flag=true, open_animation_at_end=false, save_animation=false,
            save_animation_along_the_way=false, write_results=false,
            overwrite_results=false, look_for_previous_milp_solution=false,
            save_milp_solution=false, return_env_before_sim=true)   # 시뮬 돌리기 전 env를 그대로 반환(여기서 직접 스텝)
    end
    for _ in 1:4000   # 조립이 8개 닫힐 때까지(초기 진행) 최대 4000스텝 전진
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)   # 물리 1스텝 + 계획 캐시 갱신
        length(env.cache.closed_set) >= 8 && break   # closed_set=완료된 스케줄 노드 집합
    end
    return env
end

# env를 target_closed개 닫힐 때까지(또는 완주까지) 최대 cap스텝 전진시키는 한 줄 함수(끝에 env 반환).
_advance_to(env; target_closed, cap) = (for _ in 1:cap
    CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
    (length(env.cache.closed_set) >= target_closed || CB.project_complete(env)) && break
end; env)

# 씬 트리에서 로봇 노드만 골라 리스트로(matches_template = 그 타입인지 검사).
_robot_nodes(env) = [n for n in CB.get_nodes(env.scene_tree) if CB.matches_template(CB.RobotNode, n)]
_p2(t) = Vector{Float64}(CB.project_to_2d(t.translation))   # 3D 위치를 2D 평면 좌표로 투영
_root_id(env) = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))
# ↑ root = staging circle(준비 원)이 가장 큰 어셈블리(빌드 전체를 감쌈); 절대 옮기지 않음.

# zone center = centroid of root deposit goals (the un-relocatable central core).
# 금지구역 중심 = root가 부품을 내려놓는 목표들(못 옮기는 중앙 코어)의 평균 위치(centroid).
function _central_zone_center(env)
    gs = CB.root_deposit_goals(env)   # root가 부품을 놓는 목표 좌표들
    isempty(gs) && return Vector{Float64}(CB.get_center(env.staging_circles[_root_id(env)])[1:2])  # 없으면 root 중심으로 대체
    return sum(gs) ./ length(gs)   # 평균(centroid). ./ = 원소별 나눗셈(broadcast)
end

# 끝까지(또는 정체/한도까지) 돌리며 매 스텝 "어떤 로봇이든 금지구역(zc중심, zr반지름)에 가장 깊이
# 침범한 정도"를 추적. zc=구역중심, zr=구역반지름, rr=로봇반지름. 결과를 NamedTuple로 반환.
function _run_to_end_tracked(env, zc, zr, rr; cap=250_000, stall_limit=8000)
    robots = _robot_nodes(env)
    prev = length(env.cache.closed_set); mono = true; iters = 0; stall = 0; worst = -Inf; viol = 0
    # mono=진행이 단조증가인가, stall=진전없는 연속스텝수, worst=최대침범량, viol=침범한 스텝수
    first_viol = -1; last_viol = -1                  # 침범이 일어난 첫/마지막 iter (대피 transient 판별용)
    for _ in 1:cap
        CB.step_environment!(env)
        try CB.update_planning_cache!(env, 0.0) catch; return (status=:asserted, closed=length(env.cache.closed_set), iters=iters, mono=mono, worst=worst, viol=viol, first_viol=first_viol, last_viol=last_viol) end
        step_pen = -Inf   # 이번 스텝에서 가장 깊은 침범량
        for rb in robots
            # 침범량 = (구역반지름+로봇반지름) - (로봇과 구역중심 거리). >0이면 로봇 몸통이 금지원과 겹침.
            pen = (zr + rr) - norm(_p2(CB.global_transform(rb)) .- zc)
            pen > step_pen && (step_pen = pen)   # 로봇들 중 최댓값 유지
        end
        if step_pen > 1e-6   # 아주 작은 값(부동소수 오차) 넘게 침범했으면 위반 1회 기록
            viol += 1; first_viol < 0 && (first_viol = iters); last_viol = iters
        end
        step_pen > worst && (worst = step_pen)   # 전체 최악 침범량 갱신
        c = length(env.cache.closed_set); c < prev && (mono = false)   # 닫힌 수가 줄면 단조성 깨짐
        stall = c > prev ? 0 : stall + 1   # 진전 있으면 stall 리셋, 없으면 +1 (삼항 연산자 ?:)
        prev = c; iters += 1
        CB.project_complete(env) && return (status=:complete, closed=c, iters=iters, mono=mono, worst=worst, viol=viol, first_viol=first_viol, last_viol=last_viol)  # 완주
        stall >= stall_limit && return (status=:stalled, closed=c, iters=iters, mono=mono, worst=worst, viol=viol, first_viol=first_viol, last_viol=last_viol)  # 정체(교착)
    end
    return (status=:capped, closed=prev, iters=iters, mono=mono, worst=worst, viol=viol, first_viol=first_viol, last_viol=last_viol)  # cap 소진
end

println(">>> building base env (PROJECT=$PROJECT) with FULL NAV STACK ON (slow)...")
BASE_ENV = build_base_env()
println(">>> base env: $(Graphs.nv(BASE_ENV.sched)) nodes, closed=$(length(BASE_ENV.cache.closed_set))")
Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Info))

# wholebuild 시나리오 한 번: 중앙 구역 주입 -> 빌드 전체 평행이동 -> 끝까지 돌려 침범 없이 완주하는지 판정.
function scenario(; target_closed=18, cap=60_000)
    env = deepcopy(BASE_ENV); _advance_to(env; target_closed, cap)   # BASE_ENV 복제 후 어느 정도 진행시킴
    rr = Float64(CB.default_robot_radius())   # 로봇 반지름
    zc = _central_zone_center(env); zr = ZONE_R   # 구역 중심/반지름
    rootc = Vector{Float64}(CB.get_center(env.staging_circles[_root_id(env)])[1:2])   # root 준비원 중심
    n0 = length(env.cache.closed_set); total = Graphs.nv(env.sched)   # 시작 closed 수 / 전체 노드 수(nv)
    CB.clear_restriction_zones!(); CB.add_restriction_zone!(:block, zc, zr)   # 기존 구역 지우고 :block 금지구역 추가
    println("MODE=$MODE: CENTRAL zone@$(round.(zc;digits=2)) R=$zr  root@$(round.(rootc;digits=2)) " *
            "clears_root=$(CB.zone_clears_root_goals(zc, zr, env))  closed0=$n0")
    moved = "(none)"
    if MODE == "whole"
        # 먼저 막힌 어셈블리들만 재배치 시도 -> 중앙코어가 root목표까지 덮으면 :residual_blocked(잔여 막힘)로 실패.
        ra = CB.restage_all_blocked!(env; resume=true, verbose=true)
        println("  restage_all -> status=$(ra.status) residual=$(get(ra,:residual,-1))  (expect residual_blocked)")
        wb = CB.translate_whole_build!(env; resume=true, verbose=true)   # 그래서 빌드 "전체"를 통째로 평행이동
        println("  translate_whole_build! -> status=$(wb.status) Δ=$(get(wb,:delta,nothing)) residual=$(get(wb,:residual,-1))")
        wb.status != :translated && (CB.clear_restriction_zones!(); println("RESULT: whole-build $(wb.status) -> FAIL (no clear translate)"); return)
        moved = "wholebuild Δ=$(round.(Vector{Float64}(wb.delta);digits=2))"
        # after translating the build away, robots must not enter the (fixed) zone; track vs new zone too
    end
    st = _run_to_end_tracked(env, zc, zr, rr)   # 이동 후 끝까지 돌리며 침범 추적
    # 침범이 초반(주입 직후 대피)에만 몰리는지: last_viol 가 전체 iter 대비 매우 이른가?
    evac_window = st.last_viol < 0 ? 0 : st.last_viol
    transient = st.viol == 0 || st.last_viol < max(2000, 0.1 * st.iters)   # 침범이 첫 10%(또는 2000스텝) 안에서 끝나면 대피 transient
    avoided_strict = st.worst <= 1e-6   # 엄격 기준: 한 번도 침범 안 함
    # 합격 판정 두 종류: strict(전혀 침범X) / evac-aware(완주하고 재진입만 없으면 OK). MODE≠whole이면 정체가 정답.
    pass_strict = MODE == "whole" ? (st.status == :complete && st.mono && avoided_strict) : (st.status == :stalled)
    pass_evac   = MODE == "whole" ? (st.status == :complete && st.mono && transient)       : (st.status == :stalled)
    println("RESULT MODE=$MODE moved=$moved | closed $n0->$(st.closed)/$total status=$(st.status) monotone=$(st.mono) | " *
            "worst_pen=$(round(st.worst;digits=3)) viol_steps=$(st.viol) viol_iters=[$(st.first_viol)..$(st.last_viol)] of $(st.iters) | " *
            "strict_avoided=$avoided_strict evac_transient=$transient")
    println("  -> PASS(strict no-entry)=$pass_strict   PASS(evac-aware: completes + no RE-entry)=$pass_evac")
    CB.clear_restriction_zones!()
end

scenario()
end

# =============================================================================
# fullnav -- restage_assembly! relocation with NAVIGATION ON (TangentBug): a forbid
#   zone over a future sub-assembly's staging area, relocate, run to completion while
#   TRACKING whether any robot ever enters the zone. TangentBug makes the injected
#   zone a real no-go region (active_staging_circles). No ENV knobs (project 4 fixed).
# =============================================================================
# fullnav 검증기: 내비(TangentBug) ON 상태에서 한 서브어셈블리를 재배치하고, 로봇이 금지구역에
# 한 번이라도 들어가는지 추적. TangentBug가 주입된 구역을 진짜 no-go로 취급하는지 확인.
function restage_fullnav()
_setup_milp!()

# NOTE: tangent_bug_flag=true here (vs false in restage_validate) — navigation avoidance ON.
# 참고: 여기선 tangent_bug_flag=true(내비 회피 ON) — restage_validate의 false와 대비된다.
function build_base_env()
    pp = CB.get_project_params(4)
    env = run_with_stack(2_000_000_000) do
        CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
            model_scale=pp[:model_scale], num_robots=pp[:num_robots],
            assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
            log_level=Logging.Error, rvo_flag=true, tangent_bug_flag=true,
            dispersion_flag=true, open_animation_at_end=false, save_animation=false,
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

_advance_to(env; target_closed, cap) = (for _ in 1:cap
    CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
    (length(env.cache.closed_set) >= target_closed || CB.project_complete(env)) && break
end; env)

_robot_nodes(env) = [n for n in CB.get_nodes(env.scene_tree) if CB.matches_template(CB.RobotNode, n)]

# run to completion; each step measure the deepest penetration of ANY robot into the
# zone disc (center c0, radius R). penetration = (R + robot_radius) - dist(robot, c0);
# >0 means the robot's body overlaps the no-go disc = a violation.
# 끝까지 돌리며 매 스텝 로봇들의 구역(c0중심,R반지름) 최대 침범량 측정. 결과는 일반 튜플로 반환.
function _run_to_end_tracked(env, c0, R, rr; cap=250_000, stall_limit=8000)
    robots = _robot_nodes(env)
    prev = length(env.cache.closed_set); mono = true; iters = 0; stall = 0
    worst = -Inf; viol_steps = 0   # worst=최대침범, viol_steps=침범한 스텝수
    for _ in 1:cap
        CB.step_environment!(env)
        try CB.update_planning_cache!(env, 0.0) catch; return (:asserted, length(env.cache.closed_set), iters, mono, worst, viol_steps) end
        step_pen = -Inf
        for rb in robots
            p = Vector{Float64}(CB.project_to_2d(CB.global_transform(rb).translation))
            pen = (R + rr) - norm(p .- c0)
            pen > step_pen && (step_pen = pen)
        end
        step_pen > 1e-6 && (viol_steps += 1)
        step_pen > worst && (worst = step_pen)
        c = length(env.cache.closed_set); c < prev && (mono = false)
        stall = c > prev ? 0 : stall + 1
        prev = c; iters += 1
        CB.project_complete(env) && return (:complete, c, iters, mono, worst, viol_steps)
        stall >= stall_limit && return (:stalled, c, iters, mono, worst, viol_steps)
    end
    return (:capped, prev, iters, mono, worst, viol_steps)
end

println(">>> building base env with NAVIGATION ON (slow)...")
BASE_ENV = build_base_env()
println(">>> base env: $(Graphs.nv(BASE_ENV.sched)) nodes, closed=$(length(BASE_ENV.cache.closed_set))")

# fullnav 시나리오: 아직 안 지은 미래 서브어셈블리 하나를 골라 그 위에 금지구역을 씌우고 재배치한 뒤,
# 내비 켠 채 끝까지 돌려 로봇이 구역에 안 들어가고 완주하는지 판정.
function restage_fullnav_scenario(; target_closed=24, cap=60_000)
    env = deepcopy(BASE_ENV); _advance_to(env; target_closed, cap)
    rr = Float64(CB.default_robot_radius())
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))   # 가장 큰 준비원=root
    aid = nothing; bestt0 = -Inf   # 대상 어셈블리 id, 가장 늦게 시작하는(미래) 것을 고름
    for k in keys(env.staging_circles)
        k == root && continue   # root는 대상에서 제외
        ac = CB._assembly_complete_node(env, k); ac === nothing && continue   # 완성 노드 없으면 건너뜀
        v = CB.get_vtx(env.sched, CB.node_id(ac))   # 스케줄 그래프에서의 정점 번호
        (v in env.cache.closed_set || v in env.cache.active_set) && continue   # 이미 완료/진행중이면 미래 아님 -> 제외
        t0 = Float64(CB.get_t0(env.sched, v)); t0 > bestt0 && (bestt0 = t0; aid = k)   # 시작시각 t0가 가장 큰(가장 미래) 것 선택
    end
    aid === nothing && (println("restage_fullnav: no future sub-assembly"); return :no_assembly)
    ball = env.staging_circles[aid]   # 대상 어셈블리의 준비원(중심+반지름)
    c0 = Vector{Float64}(CB.get_center(ball)[1:2]); R = Float64(CB.get_radius(ball))   # 옛 위치 c0, 반지름 R
    n0 = length(env.cache.closed_set); total = Graphs.nv(env.sched)
    # inject the forbid zone over this assembly's OLD staging, then relocate the assembly.
    # Zone stays active for the whole run below -> TangentBug treats it as a no-go disc.
    # 옛 준비 위치에 금지구역 주입 후 어셈블리를 옮긴다. 구역은 실행 내내 유지 -> TangentBug가 no-go로 취급.
    CB.clear_restriction_zones!(); CB.add_restriction_zone!(:block, c0, R)
    res = CB.restage_assembly!(env, aid)   # 실제 재배치 시도(`!` = env 변경)
    if res.status != :restaged   # 재배치 실패면 구역 지우고 그 상태 반환
        CB.clear_restriction_zones!(); println("restage_fullnav: status=$(res.status)"); return res.status
    end
    c1 = Vector{Float64}(res.to); clear = norm(c1 .- c0) >= 2R   # 새 위치 c1이 옛 위치서 2R 이상 떨어졌으면 충분히 비켜남
    # how many robots are ALREADY inside the freshly-injected zone at restage time?
    # 재배치 시점에 이미 구역 안에 갇혀 있는 로봇 수(주입 직후 대피가 필요한 로봇).
    trapped0 = 0
    for rb in _robot_nodes(env)
        p = Vector{Float64}(CB.project_to_2d(CB.global_transform(rb).translation))
        (R + rr) - norm(p .- c0) > 1e-6 && (trapped0 += 1)   # 침범량>0이면 갇힘
    end
    println("restage_fullnav: robots INSIDE zone at injection time = $trapped0")
    st = _run_to_end_tracked(env, c0, R, rr; cap=250_000, stall_limit=8000)
    if st[1] == :stalled
        println("--- STALL @ closed=$(st[2]): active EntityGo frontier (pos/goal/d, zone_pen) ---")
        for v in env.cache.active_set
            n = CB.get_node(env.sched, v).node
            CB.matches_template(CB.EntityGo, n) || continue
            p = Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.entity(n)).translation))
            g = Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.goal_config(n)).translation))
            pen = (R + rr) - norm(p .- c0)
            println("  $(string(typeof(n).name.name)) $(CB.summary(CB.node_id(n))) pos=$(round.(p;digits=2)) " *
                    "goal=$(round.(g;digits=2)) d=$(round(norm(g.-p);digits=2)) zone_pen=$(round(pen;digits=2))")
        end
    end
    CB.clear_restriction_zones!()
    status, closed, iters, mono, worst, viol = st   # 튜플 언패킹(여러 변수에 한 번에 분해 대입)
    avoided = worst <= 1e-6   # 한 번도 침범 안 함?
    pass = status == :complete && mono && clear && avoided   # 완주+단조+비켜남+무침범 이면 PASS
    println("restage_fullnav: asm=$(CB.summary(aid)) zone@$(round.(c0;digits=2)) R=$(round(R;digits=2)) " *
            "-> $(round.(c1;digits=2)) | closed $n0 ->(end) $closed/$total status=$status monotone=$mono " *
            "zone_clear=$clear | NAV: worst_penetration=$(round(worst;digits=3)) (>0=entered) " *
            "violation_steps=$viol -> ", pass ? "PASS" : "FAIL")
    return pass
end

println("=== RESTAGE + NAV ==="); restage_fullnav_scenario()
end

# =============================================================================
# navon -- restage UNDER the full motion stack (rvo + tangent_bug + dispersion ON),
#   with a forbid zone that actually blocks an assembly's build. The zone is centered
#   on a target assembly's staging center but SHRUNK below the nearest sibling goal so
#   it blocks the target's build origin yet spares siblings (restage-RECOVERABLE).
#   ENV: NAVON_ZONE_R, NAVON_TARGET (central|peripheral|bestclear), NAVON_PROJECT,
#        NAVON_MODE (none|single|all).
# =============================================================================
# navon 검증기: 전체 모션 스택(rvo+tangent_bug+dispersion) ON에서, 한 어셈블리의 빌드를 실제로
# 막는 금지구역을 주입하고 재배치로 복구되는지 검증. 구역은 root 목표는 안 건드리게 반지름을 줄인다.
function restage_navon()
# zone radius: NAVON_ZONE_R if set, else the chosen target's own staging radius (covers
# exactly that assembly's staging). NAVON_TARGET=central|peripheral picks the assembly.
# 구역 반지름: 환경변수 있으면 그 값, 없으면 대상 어셈블리 준비원 반지름. TARGET이 어느 어셈블리를 고를지 결정.
ZONE_R_ENV = haskey(ENV, "NAVON_ZONE_R") ? parse(Float64, ENV["NAVON_ZONE_R"]) : nothing   # 없으면 nothing(자동)
TARGET = get(ENV, "NAVON_TARGET", "central")

_setup_milp!()

# FULL motion stack ON (rvo + tangent_bug + dispersion) — matches run_zone_demo.
PROJECT = parse(Int, get(ENV, "NAVON_PROJECT", "4"))   # 4=tractor; try roomier models (6=x_wing_mini, etc.)
function build_base_env()
    pp = CB.get_project_params(PROJECT)
    env = run_with_stack(2_000_000_000) do
        CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
            model_scale=pp[:model_scale], num_robots=pp[:num_robots],
            assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
            log_level=Logging.Error, rvo_flag=true, tangent_bug_flag=true,
            dispersion_flag=true, open_animation_at_end=false, save_animation=false,
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

_advance_to(env; target_closed, cap) = (for _ in 1:cap
    CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
    (length(env.cache.closed_set) >= target_closed || CB.project_complete(env)) && break
end; env)

_robot_nodes(env) = [n for n in CB.get_nodes(env.scene_tree) if CB.matches_template(CB.RobotNode, n)]
_p2(t) = Vector{Float64}(CB.project_to_2d(t.translation))

# run to end; track deepest robot penetration into the zone disc (center zc, radius zr).
function _run_to_end_tracked(env, zc, zr, rr; cap=250_000, stall_limit=8000)
    robots = _robot_nodes(env)
    prev = length(env.cache.closed_set); mono = true; iters = 0; stall = 0
    worst = -Inf; viol_steps = 0
    for _ in 1:cap
        CB.step_environment!(env)
        try CB.update_planning_cache!(env, 0.0) catch; return (:asserted, length(env.cache.closed_set), iters, mono, worst, viol_steps) end
        step_pen = -Inf
        for rb in robots
            pen = (zr + rr) - norm(_p2(CB.global_transform(rb)) .- zc)
            pen > step_pen && (step_pen = pen)
        end
        step_pen > 1e-6 && (viol_steps += 1)
        step_pen > worst && (worst = step_pen)
        c = length(env.cache.closed_set); c < prev && (mono = false)
        stall = c > prev ? 0 : stall + 1
        prev = c; iters += 1
        CB.project_complete(env) && return (:complete, c, iters, mono, worst, viol_steps)
        stall >= stall_limit && return (:stalled, c, iters, mono, worst, viol_steps)
    end
    return (:capped, prev, iters, mono, worst, viol_steps)
end

_root_id(env) = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))   # 최대 준비원=root
# 어셈블리 k가 "미래(아직 완료도 진행중도 아님)"인지 판정. ac 없으면 false 반환(한 줄 안에서 return).
_is_future(env, k) = (ac = CB._assembly_complete_node(env, k); ac === nothing && return false;
    v = CB.get_vtx(env.sched, CB.node_id(ac)); !(v in env.cache.closed_set || v in env.cache.active_set))

# central 대상 선택: root 아닌 미래 서브어셈블리 중 시작시각 t0가 가장 큰 것(준비원이 작업공간 중앙 근처).
function _pick_target(env)  # central: largest-t0 future non-root sub-assembly (its staging ~ workspace center)
    root = _root_id(env); aid = nothing; bestt0 = -Inf
    for k in keys(env.staging_circles)
        (k == root || !_is_future(env, k)) && continue
        t0 = Float64(CB.get_t0(env.sched, CB.get_vtx(env.sched, CB.node_id(CB._assembly_complete_node(env, k)))))
        t0 > bestt0 && (bestt0 = t0; aid = k)
    end
    return aid
end

# peripheral: the future non-root sub-assembly with the SMALLEST staging circle (a
# leaf / self-contained assembly). A zone sized to its small radius covers just that
# one assembly's staging — NOT the root's central build goals — so restage can fully
# clear it (residual 0). (Picking "farthest from root" instead grabbed the BIGGEST
# sub-assembly whose huge circle re-engulfed everything -> residual_blocked.)
# peripheral 대상: 준비원이 가장 "작은" 미래 서브어셈블리(잎/독립 어셈블리). 작은 구역은 그 하나만
# 덮어 root 중앙 목표는 안 건드리므로 재배치로 완전히 비울 수 있다(잔여 0).
function _pick_peripheral_target(env)
    root = _root_id(env)
    aid = nothing; bestR = Inf
    for k in keys(env.staging_circles)
        (k == root || !_is_future(env, k)) && continue
        R = Float64(CB.get_radius(env.staging_circles[k]))
        R < bestR && (bestR = R; aid = k)
    end
    return aid
end

# bestclear: the future sub-assembly whose staging center is FARTHEST from the nearest
# root deposit goal -> the largest restage-recoverable zone fits there. Also prints the
# root-clear cap of every candidate so we can see if the model has ANY roomy spot.
# bestclear 대상: 준비 중심이 가장 가까운 root 목표에서 가장 "멀리" 있는 미래 어셈블리(가장 큰
# 재배치-복구 가능 구역이 들어감). 후보별 root-clear 한계도 출력해 모델에 여유 공간이 있는지 본다.
function _pick_bestclear_target(env)
    root = _root_id(env)
    rootgoals = CB.root_deposit_goals(env)
    isempty(rootgoals) && return _pick_peripheral_target(env)
    aid = nothing; best = -Inf
    println("  per-assembly root-clear cap (dist to nearest root deposit goal):")
    for k in sort(collect(keys(env.staging_circles)); by = x -> string(x))   # 출력 재현성 위해 이름순 정렬
        (k == root || !_is_future(env, k)) && continue   # root거나 미래 아니면 건너뜀
        c = Vector{Float64}(CB.get_center(env.staging_circles[k])[1:2])
        d = minimum(norm(c .- g) for g in rootgoals)   # 이 중심에서 가장 가까운 root 목표까지 거리(=구역 최대 허용 반지름 근처)
        println("    $(CB.summary(k)): cap=$(round(d;digits=2))  stagingR=$(round(Float64(CB.get_radius(env.staging_circles[k]));digits=2))")
        d > best && (best = d; aid = k)
    end
    return aid
end

# mode: "none" (zone, no restage) | "single" (restage_assembly! on the one target) |
#       "all" (restage_all_blocked! — Phase a: relocate EVERY assembly the zone covers)
# navon 시나리오: 대상 선택 -> root목표 안 건드리게 구역반지름 축소 -> mode에 따라(none/single/all)
# 재배치 -> 끝까지 돌려 완주+무침범 판정. label=출력용 이름, mode=재배치 방식.
function scenario(label; mode, target_closed=24, cap=60_000)
    env = deepcopy(BASE_ENV); _advance_to(env; target_closed, cap)
    rr = Float64(CB.default_robot_radius())
    aid = TARGET == "peripheral" ? _pick_peripheral_target(env) :   # TARGET 값에 따라 대상 선택 전략 분기(중첩 삼항)
          TARGET == "bestclear"  ? _pick_bestclear_target(env)  : _pick_target(env)
    aid === nothing && (println("$label: no future sub-assembly"); return)
    ball = env.staging_circles[aid]
    zc = Vector{Float64}(CB.get_center(ball)[1:2])              # zone over the target's staging center  # 구역 중심=대상 준비 중심
    zr_req = ZONE_R_ENV === nothing ? Float64(CB.get_radius(ball)) : ZONE_R_ENV  # requested = target's staging radius  # 요청 반지름
    rootc = Vector{Float64}(CB.get_center(env.staging_circles[_root_id(env)])[1:2])
    # GENERATION CONSTRAINT: keep the zone clear of the root's (un-relocatable) deposit
    # goals — shrink its radius so it never reaches the nearest one. Guarantees the
    # injected zone is restage-RECOVERABLE (can only block relocatable sub-assemblies).
    # 생성 제약: 구역이 root의 못 옮기는 목표에 닿지 않게 반지름을 줄인다. 그래야 주입 구역이
    # "재배치로 복구 가능"(옮길 수 있는 서브어셈블리만 막음)함이 보장된다.
    rootgoals = CB.root_deposit_goals(env)
    maxclear = isempty(rootgoals) ? Inf : minimum(norm(zc .- g) for g in rootgoals) - rr   # root목표에 안 닿는 최대 반지름
    zr = min(zr_req, maxclear)   # 요청값과 안전상한 중 작은 쪽
    zr <= rr && (println("$label: no root-clear radius at $(CB.summary(aid)) (nearest root goal $(round(maxclear+rr;digits=2))) -> SKIP"); return)  # 여유 없으면 건너뜀
    n0 = length(env.cache.closed_set); total = Graphs.nv(env.sched)
    CB.clear_restriction_zones!(); CB.add_restriction_zone!(:block, zc, zr)   # 금지구역 주입
    trapped0 = count(rb -> (zr + rr) - norm(_p2(CB.global_transform(rb)) .- zc) > 1e-6, _robot_nodes(env))   # 주입 시점 구역 안 로봇 수
    println("$label: target=$(CB.summary(aid)) zone@$(round.(zc;digits=2)) R=$(round(zr;digits=2)) (req $(round(zr_req;digits=2)), root-clear cap $(round(maxclear;digits=2))) " *
            "root@$(round.(rootc;digits=2)) clears_root=$(CB.zone_clears_root_goals(zc, zr, env))")
    moved = "(none)"
    if mode == "single"   # 대상 하나만 재배치
        res = CB.restage_assembly!(env, aid)
        res.status != :restaged && (CB.clear_restriction_zones!(); println("$label: restage status=$(res.status)"); return)
        moved = "1 asm -> $(round.(Vector{Float64}(res.to);digits=2))"
    elseif mode == "all"   # 구역이 막는 모든 어셈블리를 한꺼번에 재배치(Phase a)
        blocked = CB.zone_blocked_assemblies(env)   # 구역에 막힌 어셈블리 목록
        println("$label: zone blocks $(length(blocked)) assemblies: $([CB.summary(b) for b in blocked])")
        res = CB.restage_all_blocked!(env)
        moved = "$(length(res.moved)) asm (status=$(res.status), failed=$(length(res.failed)), residual=$(get(res,:residual,-1)))"
        res.status in (:none, :infeasible, :residual_blocked) &&   # 하나도 못 옮기거나 잔여 막힘이면 실패로 처리
            (CB.clear_restriction_zones!(); println("$label: restage_all $(moved) -> INFEASIBLE/SKIP (fallback)"); return res.status)
    end
    st = _run_to_end_tracked(env, zc, zr, rr; cap=250_000, stall_limit=8000)
    status, closed, iters, mono, worst, viol = st
    if status != :complete
        println("  [$label $(status) @ closed=$closed] frontier goals vs zone (dist<$(round(zr;digits=2))=goal trapped IN zone):")
        for v in env.cache.active_set
            n = CB.get_node(env.sched, v).node
            CB.matches_template(CB.EntityGo, n) || continue
            g = _p2(CB.global_transform(CB.goal_config(n)))
            println("    $(string(typeof(n).name.name)) $(CB.summary(CB.node_id(n))) goal=$(round.(g;digits=2)) dist_to_zone_ctr=$(round(norm(g.-zc);digits=2))")
        end
    end
    avoided = worst <= 1e-6
    pass = status == :complete && mono && avoided
    println("$label: mode=$mode moved=$moved | closed $n0->$closed/$total status=$status monotone=$mono | " *
            "trapped@inject=$trapped0 worst_pen=$(round(worst;digits=3)) viol_steps=$viol avoided=$avoided -> ", pass ? "PASS" : "FAIL")
    CB.clear_restriction_zones!()
    return status
end

println(">>> building base env with FULL NAV STACK ON (slow)...")
BASE_ENV = build_base_env()
println(">>> base env: $(Graphs.nv(BASE_ENV.sched)) nodes, closed=$(length(BASE_ENV.cache.closed_set))")
Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Warn))

# NOTE: RVO sim/map is PROCESS-GLOBAL, so a 2nd scenario on a fresh deepcopy crashes
# (rvo_get_agent_idx BoundsError) — run ONE scenario per process. CONTROL (zone, no
# restage) was confirmed to STALL @152 in a prior run; here we run the RESTAGE case.
# NAVON_MODE: none | single | all (default "all" = Phase a multi-assembly relocation)
MODE = get(ENV, "NAVON_MODE", "all")
println("=== NAV-ON scenario mode=$MODE target=$TARGET zone_R=$(ZONE_R_ENV===nothing ? "auto" : ZONE_R_ENV) ===")
scenario(uppercase(MODE); mode=MODE)
end

# =============================================================================
# validate -- standalone (no Revise) validation of restage_assembly! + control resume,
#   run with NAV OFF (rvo/tangent_bug/dispersion=false: robots beeline to goals) so it
#   proves the SCHEDULE/geometry of restage. Caches the freshly-built BASE_ENV to a temp
#   file (stdlib Serialization) for fast edit-rerun. CONTROL / RESTAGE(single) /
#   RESTAGE-ALL(multi) scenarios. No ENV knobs.
# =============================================================================
# validate 검증기: 내비 끈(로봇 직선 이동) 상태로 재배치의 스케줄/기하만 빠르게 검증. BASE_ENV를
# 임시파일에 캐시해 편집-재실행을 빠르게 한다. CONTROL/RESTAGE(single)/RESTAGE-ALL 3가지 시나리오.
function restage_validate()
# --- BASE_ENV cache -----------------------------------------------------------
# build_base_env() runs run_lego_demo + 4000 steps (~minutes). That cost is paid
# EVERY process invocation, which makes edit-rerun debugging painful. PlannerEnv is
# pure Julia (no PyObject RVO state here: rvo_flag=false), so stdlib Serialization
# round-trips it safely — unlike JLD2, which warns on anonymous functions. We cache
# the freshly-built env to a temp file (keyed by project + a version tag) and reuse
# it on later runs. Bump CACHE_VERSION (or delete the file) when build params change.
CACHE_VERSION = "v1"   # 빌드 파라미터 바뀌면 이 값을 올려 캐시 무효화
BASE_ENV_CACHE = joinpath(tempdir(), "cb_base_env_p4_$(CACHE_VERSION).jls")   # 캐시 파일 경로(.jls=Julia 직렬화)

_setup_milp!()

# BASE_ENV를 캐시에서 로드, 없으면 새로 빌드(내비 OFF)하고 캐시에 저장.
function build_base_env()
    if isfile(BASE_ENV_CACHE)   # 캐시 있으면 빠르게 역직렬화해서 씀
        println(">>> loading cached BASE_ENV from $BASE_ENV_CACHE (delete to force rebuild)")
        try
            return Serialization.deserialize(BASE_ENV_CACHE)
        catch e
            @warn "cached BASE_ENV failed to load; rebuilding" exception=e
        end
    end
    pp = CB.get_project_params(4)
    env = run_with_stack(2_000_000_000) do
        CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
            model_scale=pp[:model_scale], num_robots=pp[:num_robots],
            assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
            log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false,   # 내비/충돌회피 OFF: 로봇이 목표로 직선 이동
            dispersion_flag=false, open_animation_at_end=false, save_animation=false,
            save_animation_along_the_way=false, write_results=false,
            overwrite_results=false, look_for_previous_milp_solution=false,
            save_milp_solution=false, return_env_before_sim=true)
    end
    for _ in 1:4000
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
        length(env.cache.closed_set) >= 8 && break
    end
    try
        Serialization.serialize(BASE_ENV_CACHE, env)
        println(">>> cached BASE_ENV to $BASE_ENV_CACHE")
    catch e
        @warn "could not cache BASE_ENV (will rebuild next run)" exception=e
    end
    return env
end

# Explain WHY an active EntityGo node refuses to close, mirroring is_goal()'s gate
# exactly (route_planning.jl). Distance d=0.0 is NOT the close condition — the gate
# is successor-readiness + (for FormTransportUnit) whole-team capture.
# 진행중(active)인 EntityGo 노드가 왜 안 닫히는지 진단 출력. 닫힘 조건은 "거리 0"이 아니라
# 후속 노드 준비 + (운반팀이면) 팀 전원이 제자리에 왔는지. 정체(stall) 디버깅용.
function explain_block(env)
    sched = env.sched; cache = env.cache
    for v in cache.active_set
        wrap = CB.get_node(sched, v); node = wrap.node
        tname = string(typeof(node).name.name)
        if !CB.matches_template(CB.EntityGo, node)
            println("    [$tname $(CB.summary(CB.node_id(node)))] non-EntityGo (is_goal=>$(CB.is_goal(wrap, env)))")
            continue
        end
        state = CB.global_transform(CB.entity(node))
        goal  = CB.global_transform(CB.goal_config(node))
        if !CB.is_within_capture_distance(state, goal)
            println("    [$tname $(CB.summary(CB.node_id(node)))] NOT at goal yet"); continue
        end
        if CB.is_terminal_node(sched, node)
            println("    [$tname $(CB.summary(CB.node_id(node)))] TERMINAL node -> is_goal false by design (never closes)"); continue
        end
        outs = CB.outneighbors(sched, node)
        if isempty(outs); println("    [$tname $(CB.summary(CB.node_id(node)))] no successor"); continue; end
        nxt = CB.get_node(sched, outs[1]); nx = nxt.node
        nxname = string(typeof(nx).name.name)
        blockers = String[]
        for vp in CB.inneighbors(sched, nxt)
            if !((vp in cache.active_set) || (vp in cache.closed_set))
                np = CB.get_node(sched, vp).node
                push!(blockers, "$(string(typeof(np).name.name)) $(CB.summary(CB.node_id(np)))")
            end
        end
        if !isempty(blockers)
            bstr = join(blockers, ", ")
            println("    [$tname $(CB.summary(CB.node_id(node)))] succ=$nxname $(CB.summary(CB.node_id(nx))) NOT ready; missing preds: $bstr"); continue
        end
        if CB.matches_template(CB.FormTransportUnit, nxt)
            tu = CB.entity(nxt); notinplace = String[]
            tuc = Vector{Float64}(CB.project_to_2d(CB.global_transform(tu).translation))
            # where is the CARGO (object being picked up) right now? resolves A vs B:
            #   cargo ≈ tu  -> formation anchored at fixed pickup (B)
            #   cargo moved with assembly -> formation should follow assembly (A)
            cargo = CB.get_node(env.scene_tree, CB.cargo_id(tu))
            cpos = Vector{Float64}(CB.project_to_2d(CB.global_transform(cargo).translation))
            println("        cargo $(CB.summary(CB.cargo_id(tu))) pos=$(round.(cpos;digits=2))  tu@$(round.(tuc;digits=2))  d(cargo,tu)=$(round(norm(cpos.-tuc);digits=2))")
            for (id, _) in CB.robot_team(tu)
                robot = CB.get_node(env.scene_tree, id)
                if !CB.is_within_capture_distance(tu, robot)
                    rp = Vector{Float64}(CB.project_to_2d(CB.global_transform(robot).translation))
                    # where is this robot actually parked? find its own active EntityGo
                    own = ""
                    for vv in cache.active_set
                        nn = CB.get_node(sched, vv).node
                        if CB.matches_template(CB.EntityGo, nn) && CB.entity(nn) === robot
                            gg = Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.goal_config(nn)).translation))
                            own = " | own-node $(string(typeof(nn).name.name)) $(CB.summary(CB.node_id(nn))) goal=$(round.(gg;digits=2)) dgoal=$(round(norm(gg.-rp);digits=2))"
                            break
                        end
                    end
                    push!(notinplace, "$(string(id)) robotpos=$(round.(rp;digits=2)) d2tu=$(round(norm(rp.-tuc);digits=2))$own")
                end
            end
            if !isempty(notinplace)
                println("    [$tname $(CB.summary(CB.node_id(node)))] succ=FormTransportUnit tu@$(round.(tuc;digits=2)) waiting OFF-position robots:")
                for s in notinplace; println("        - $s"); end
                continue
            end
        end
        println("    [$tname $(CB.summary(CB.node_id(node)))] is_goal SHOULD be true -> $(CB.is_goal(wrap, env)) (unexpected)")
    end
end

_advance_to(env; target_closed, cap) = (for _ in 1:cap
    CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
    (length(env.cache.closed_set) >= target_closed || CB.project_complete(env)) && break
end; env)

# 침범 추적 없이 그냥 끝까지 돌리는 버전(내비 OFF용). 도중 계획 캐시 갱신에서 예외가 나면
# 실패한 부품의 carry chain(운반 사슬) 정보를 덤프하고 :asserted로 반환.
function _run_to_end(env; cap, stall_limit=20000)
    prev = length(env.cache.closed_set); mono = true; iters = 0; stall = 0
    for _ in 1:cap
        CB.step_environment!(env)
        try CB.update_planning_cache!(env, 0.0) catch e   # 실패해도 죽지 않고 원인 덤프
            println("--- ASSERTED @ closed=$(length(env.cache.closed_set)) ---")
            showerror(stdout, e, catch_backtrace()); println()
            # probe: for the part that failed capture, dump the carry chain globals
            for v in env.cache.active_set ∪ env.cache.closed_set
                n = CB.get_node(env.sched, v).node
                CB.matches_template(CB.LiftIntoPlace, n) || continue
                cargo = CB.entity(n)
                CB.matches_template(CB.ObjectNode, cargo) || continue
                oid = CB.node_id(cargo)
                op  = round.(Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.get_node(env.scene_tree, oid)).translation)); digits=2)
                lg  = round.(Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.goal_config(n)).translation)); digits=2)
                ls  = round.(Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.start_config(n)).translation)); digits=2)
                println("    LiftIntoPlace $(CB.summary(oid)): obj@$op  lift_start@$ls  lift_goal@$lg")
            end
            return (:asserted, length(env.cache.closed_set), iters, mono)
        end
        c = length(env.cache.closed_set); c < prev && (mono = false)
        stall = c > prev ? 0 : stall + 1
        prev = c; iters += 1
        CB.project_complete(env) && return (:complete, c, iters, mono)
        stall >= stall_limit && return (:stalled, c, iters, mono)
    end
    return (:capped, prev, iters, mono)
end

println(">>> building base env (slow)...")
BASE_ENV = build_base_env()
println(">>> base env: $(Graphs.nv(BASE_ENV.sched)) nodes, closed=$(length(BASE_ENV.cache.closed_set))")

# control: resume infra (no schedule change) completes
# 대조군: 스케줄을 바꾸지 않고 이어서(resume) 돌려도 정상 완주하는지 확인(재배치 없는 기준선).
function control_resume(; target_closed=24, cap=60_000)
    env = deepcopy(BASE_ENV); _advance_to(env; target_closed, cap)
    n0 = length(env.cache.closed_set)
    CB.reset_cache_resume!(env.cache, env.sched)   # 재개용으로 캐시 리셋(스케줄 변경 없음)
    st = _run_to_end(env; cap)
    println("control_resume: closed $n0 ->(end) $(st[2]) | status=$(st[1]) monotone=$(st[4])")
    return st[1] == :complete && st[4]
end

# RESTAGE(single) 검증: 미래 서브어셈블리 하나 위에 구역을 씌우고 재배치한 뒤 완주하는지(내비 OFF).
function restage_check(; target_closed=24, cap=60_000)
    env = deepcopy(BASE_ENV); _advance_to(env; target_closed, cap)
    # root = the assembly whose staging circle is largest (encompasses the build); never relocate it
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))   # 최대 준비원=root(안 옮김)
    aid = nothing; bestt0 = -Inf
    for k in keys(env.staging_circles)
        k == root && continue
        ac = CB._assembly_complete_node(env, k); ac === nothing && continue
        v = CB.get_vtx(env.sched, CB.node_id(ac))
        (v in env.cache.closed_set || v in env.cache.active_set) && continue
        t0 = Float64(CB.get_t0(env.sched, v)); t0 > bestt0 && (bestt0 = t0; aid = k)
    end
    aid === nothing && (println("restage_check: no future sub-assembly"); return :no_assembly)
    ball = env.staging_circles[aid]
    c0 = Vector{Float64}(CB.get_center(ball)[1:2]); R = Float64(CB.get_radius(ball))
    n0 = length(env.cache.closed_set); total = Graphs.nv(env.sched)
    CB.clear_restriction_zones!(); CB.add_restriction_zone!(:block, c0, R)
    res = CB.restage_assembly!(env, aid)
    if res.status != :restaged
        CB.clear_restriction_zones!()
        d = get(res, :detail, "")
        println("restage_check: status=$(res.status) ($d)")
        return res.status
    end
    c1 = Vector{Float64}(res.to); clear = norm(c1 .- c0) >= 2R
    st = _run_to_end(env; cap=250_000, stall_limit=8000)
    if st[1] == :stalled
        println("--- STALL @ closed=$(st[2]): active frontier ---")
        for v in env.cache.active_set
            n = CB.get_node(env.sched, v).node
            tname = string(typeof(n).name.name)
            extra = ""
            if CB.matches_template(CB.EntityGo, n)
                p = Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.entity(n)).translation))
                g = Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.goal_config(n)).translation))
                extra = " pos=$(round.(p;digits=2)) goal=$(round.(g;digits=2)) d=$(round(norm(g.-p);digits=2))"
            end
            println("  $tname $(CB.summary(CB.node_id(n)))$extra")
        end
        println("--- WHY each frontier node won't close (is_goal gate) ---")
        explain_block(env)
    end
    CB.clear_restriction_zones!()
    pass = st[1] == :complete && st[4] && clear
    println("restage_check: asm=$(CB.summary(aid)) $(round.(c0;digits=2))->$(round.(c1;digits=2)) closed $n0 ->(end) $(st[2])/$total | status=$(st[1]) monotone=$(st[4]) zone_clear=$clear -> ", pass ? "PASS" : "FAIL")
    return pass
end

# Phase 5.1: multi-assembly recovery. Inject ONE zone big enough to overlap SEVERAL
# assemblies' staging circles (zone = a sub-assembly's full staging circle already
# engulfs its dense-center siblings), then restage_all_blocked! must relocate ALL of
# them and the build must still complete (vs restage_check which moves only one).
# RESTAGE-ALL(multi) 검증: 여러 어셈블리를 겹쳐 덮을 만큼 큰 구역 하나를 주입하고,
# restage_all_blocked!가 그 전부를 재배치해도 빌드가 완주하는지 확인(restage_check는 하나만 옮김).
function restage_all_check(; target_closed=24, cap=60_000)
    env = deepcopy(BASE_ENV); _advance_to(env; target_closed, cap)
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))
    aid = nothing; bestt0 = -Inf
    for k in keys(env.staging_circles)
        k == root && continue
        ac = CB._assembly_complete_node(env, k); ac === nothing && continue
        v = CB.get_vtx(env.sched, CB.node_id(ac))
        (v in env.cache.closed_set || v in env.cache.active_set) && continue
        t0 = Float64(CB.get_t0(env.sched, v)); t0 > bestt0 && (bestt0 = t0; aid = k)
    end
    aid === nothing && (println("restage_all_check: no future sub-assembly"); return :no_assembly)
    ball = env.staging_circles[aid]
    c0 = Vector{Float64}(CB.get_center(ball)[1:2]); R = Float64(CB.get_radius(ball))
    n0 = length(env.cache.closed_set); total = Graphs.nv(env.sched)
    CB.clear_restriction_zones!(); CB.add_restriction_zone!(:block, c0, R)
    blocked = CB.zone_blocked_assemblies(env)
    println("restage_all_check: zone@$(round.(c0;digits=2)) R=$(round(R;digits=2)) blocks $(length(blocked)) assemblies: $([CB.summary(b) for b in blocked])")
    res = CB.restage_all_blocked!(env)
    println("restage_all_check: restage_all status=$(res.status) moved=$(length(res.moved)) failed=$(length(res.failed))")
    if res.status in (:none, :infeasible)
        CB.clear_restriction_zones!(); println("restage_all_check: nothing relocated -> SKIP"); return res.status
    end
    st = _run_to_end(env; cap=250_000, stall_limit=8000)
    if st[1] != :complete
        println("--- restage_all STALL/abort @ closed=$(st[2]) ---"); explain_block(env)
    end
    CB.clear_restriction_zones!()
    pass = st[1] == :complete && st[4]
    println("restage_all_check: blocked=$(length(blocked)) moved=$(length(res.moved)) closed $n0 ->(end) $(st[2])/$total | status=$(st[1]) monotone=$(st[4]) -> ", pass ? "PASS" : "FAIL")
    return pass
end

println("=== CONTROL ==="); control_resume()
Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Warn))  # surface capture @warn during restage
println("=== RESTAGE (single) ==="); restage_check()
println("=== RESTAGE-ALL (multi, Phase a) ==="); restage_all_check()
end

# ---- dispatcher -------------------------------------------------------------
# ---- 디스패처: 키 문자열 -> 실행할 검증기 함수 매핑(Dict) --------------------
const RESTAGES = Dict(
    "wholebuild" => restage_wholebuild,   # 각 키가 위에서 정의한 검증기 함수를 가리킴
    "fullnav"    => restage_fullnav,
    "navon"      => restage_navon,
    "validate"   => restage_validate,
)
end # module Restage

# 이 파일을 스크립트로 직접 실행했을 때만 동작(다른 곳에서 include하면 실행 안 함).
if abspath(PROGRAM_FILE) == @__FILE__
    key = get(ENV, "RESTAGE", isempty(ARGS) ? "wholebuild" : ARGS[1])   # RESTAGE 환경변수 > 첫 인자 > 기본 wholebuild
    haskey(Restage.RESTAGES, key) || error("unknown restage '$key'. Available: $(join(sort(collect(keys(Restage.RESTAGES))), ", "))")  # 없는 키면 에러
    println(">>> running restage: $key")
    Restage.RESTAGES[key]()   # 선택된 검증기 실행
end
