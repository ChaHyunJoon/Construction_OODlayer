# ============================================================================
#  greedy_edge_cost 디스패치 바이트-보존 증명 (spec §6.2, 계획 태스크 2)
#
#  이 파일이 test/greedy_assignment_regression.jl 을 대체하는 진짜 게이트다.
#
#  ⚠️ 이 파일은 CB.formulate_milp(::GreedyOrderedAssignment,...) 에 method piracy 를 한다
#  (아래 참조) — 그 오버라이드는 프로세스 전체 수명 동안 원본 메서드를 영구히 대체한다.
#  그래서 이 파일을 test/runtests.jl 에 절대 등록하지 않는다(수동 게이트로만 실행).
#
#  왜 대체하는가 (실측, 2026-08-13):
#    greedy_assignment_regression.jl 은 "코드변경 전 골든 해시 vs 코드변경 후 해시"를
#    서로 다른 두 julia 프로세스로 비교하려 했다. 5회 실측:
#      1 golden   (변경 전)                         c95e4c72…
#      2 repro    (변경 전, 같은 컴파일 세션)         c95e4c72…  = 1
#      3 gate     (디스패치 배선 후)                 20d5fe75…
#      4 control  (배선을 stash 로 되돌린 변경-전 코드) 5640226b…
#      5 control  (4 와 동일 코드, 재확인)            5640226b…  = 4
#    4·5 는 "변경 전 코드"인데도 1·2 와 다르다. 즉 프로세스(컴파일 상태)가 바뀌면
#    코드가 완전히 같아도 배정 지문이 달라진다 — **재컴파일 자체가 지문을 바꾼다.**
#    코드 변경은 매번 재컴파일을 유발하므로, 이 골든-해시 방식은 "코드가 바뀌었다"와
#    "프로세스가 바뀌었다"를 구분할 수 없다 = 구조적으로 통과 불가능한 게이트였다.
#    (반대로 같은 프로세스 안에서는 결정적이다 — 1=2, 4=5. 아래 게이트는 그 성질만 쓴다.)
#
#  진짜 계약 (spec §6.2): "GreedyFinalTimeCost 분기는 현행 클로저와 바이트 단위로
#  같은 값을 낸다" — 이것은 **비용함수 자체**에 대한 명제지, "두 프로세스가 같은 스케줄을
#  내야 한다"는 명제가 아니다. 그래서 이 파일은 그 명제를 직접, 프로세스 내부에서 증명한다:
#
#    (a) 공식 항등성 — sched 의 모든 정점 × dt 값 여러 개에 대해
#        greedy_edge_cost(gc, sched, v, v2, dt) === get_tF(sched, v) + dt  를 `===` 로 검사.
#        (`==` 가 아니라 `===` 를 쓰는 이유: -0.0/NaN 같은 비트 차이가 `==` 로는 안 걸린다.)
#    (b) 프로세스 내부 A/B — 같은 pre-assignment 스케줄의 두 deepcopy 에 대해
#        하나는 **실제 콜사이트** CB.assign_collaborative_tasks!(디스패치, GreedyFinalTimeCost)로,
#        하나는 **변경 전 콜사이트를 그대로 복사한** CB._legacy_assign!(하드코딩 클로저 원본
#        그대로)로 배정을 돌려 지문을 비교한다. 서로 다른 콜사이트 두 개를 실제로 실행해
#        비교하므로(단순히 같은 콜사이트를 서로 다른 이름의 동일 공식으로 두 번 부르는 게
#        아니므로) 콜사이트 자체의 결함(v/v2 뒤바뀜, distance_dict 키 순서, get_tF 를 읽는
#        시점 이동 등)도 잡는다. 같은 프로세스 안이므로(위에서 확인한 대로) 결정적이고,
#        이 비교는 유효하다.
#
#  사용법:  julia +lts --project=. test/greedy_cost_dispatch_equivalence.jl
#  (runtests.jl 에 등록하지 않음 — 수동 게이트. test/greedy_assignment_regression.jl 도 참고.)
# ============================================================================

using ConstructionBots
using Test
using Random
using Graphs
using SHA
const CB = ConstructionBots

const SEED = 3
const NROB = 12

# ---------------------------------------------------------------------------
# pre-assignment 스케줄/문제명세를 캡처하기 위해 CB.formulate_milp(::GreedyOrderedAssignment,...)
# 를 감싼다. 원본(task_assignment.jl:347-361)의 본문을 그대로 재구현하고, 배정이 스케줄을
# 제자리에서(add_edge!) 변형하기 **전에** deepcopy 를 떠 둔다.
#
# ⚠️ METHOD PIRACY: 아래 정의는 CB.formulate_milp(::CB.GreedyOrderedAssignment,...) 의 기존
# 메서드를 이 프로세스가 살아있는 동안 영구히 덮어쓴다(Julia 는 같은 시그니처의 재정의를
# 허용하고 경고만 낸다). run_lego_demo 의 :greedy 경로가 내부적으로 이 메서드를 타므로,
# 이 파일을 로드한 뒤로는 그 경로가 항상 이 오버라이드로 간다 — 부작용은 CAPTURED_SCHED/
# CAPTURED_SPEC 를 채우는 것뿐이고 반환값은 원본과 동일하므로 정상 동작에는 영향 없지만,
# 이 파일을 다른 테스트와 같은 프로세스에서(예: test/runtests.jl 등록) 돌리면 그 쪽의
# :greedy 배정도 이 캡처를 몰래 타게 된다 — 그래서 절대 runtests.jl 에 등록하지 않는다.
# ---------------------------------------------------------------------------
const CAPTURED_SCHED = Ref{Any}(nothing)
const CAPTURED_SPEC = Ref{Any}(nothing)

function CB.formulate_milp(
        milp_model::CB.GreedyOrderedAssignment,
        sched,
        problem_spec;
        cost_model=CB.SumOfMakeSpans(),
        kwargs...
    )
    CAPTURED_SCHED[] = deepcopy(sched)
    CAPTURED_SPEC[] = problem_spec
    return CB.GreedyOrderedAssignment(
        schedule=sched,
        problem_spec=problem_spec,
        cost_model=cost_model,
        greedy_cost=milp_model.greedy_cost,
    )
end

# ---------------------------------------------------------------------------
# _legacy_assign! — assign_collaborative_tasks! 의 변경 전(커밋 4900206) 본문을 **한 글자도
# 손대지 않고** 복사(함수 이름만 바꿈). `git show 4900206:src/task_assignment.jl` 에서 추출.
# I-1 수정: (b)의 두 arm 이 같은 콜사이트(CB.assign_collaborative_tasks!)를 서로 다른 이름의
# 같은 공식으로 두 번 태우던 문제 — 그러면 콜사이트 자체의 결함(v/v2 뒤바뀜 등)을 이 테스트가
# 전혀 못 잡는다. 이제 arm B 는 이 함수(완전히 다른, 변경 전 콜사이트)를 그대로 태운다.
# ConstructionBots 모듈 스코프 안에서 정의해야 get_nodes/matches_template/AssemblyStart/...
# 같은 비export 심볼이 원본과 동일하게 풀린다(@eval CB 로 그 스코프에 주입).
# ---------------------------------------------------------------------------
@eval CB begin

function _legacy_assign!(model,
        # D = construct_schedule_distance_matrix(model.schedule,model.problem_spec)
    )
    sched       = model.schedule                # 작업 스케줄
    scene_tree  = model.problem_spec            # 장면 트리(여기에 부품/조립체 형상·위치 정보)
    # D = construct_schedule_distance_matrix(sched,scene_tree)
    # 모든 "조립체 시작" 노드를 ID→노드 딕셔너리로 수집 (Dict(... for ...) = 파이썬 dict comprehension 과 동일)
    assembly_starts = Dict(node_id(n)=>n for n in get_nodes(sched) if matches_template(AssemblyStart,n))
    assemblies_completed = Set{AbstractID}()    # 완성된 조립체 ID 들을 기록할 집합
    active_build_steps = Dict()                 # 현재 "진행 가능한 조립단계" → 그 단계의 남은 작업집합
    for (k,n) in assembly_starts                # 각 조립체의 시작 노드에 대해
        open_build_step = get_first_build_step(sched,n)  # 그 조립체의 첫 번째 조립단계
        step_id = node_id(open_build_step)
        active_build_steps[step_id] = construct_build_step_task_set(sched,scene_tree,step_id)  # 그 단계의 작업집합을 활성목록에 등록
    end
    # fill robots with go nodes
    robots = Set{Int}()                         # 배정 가능한(놀고 있는) 로봇들의 정점번호 집합
    for n in get_nodes(sched)
        if matches_template(RobotStart,n)        # 로봇 시작 노드면
            # OOD 1-1: 예비 풀(SPARE_POOLS)에 등록된 예비 로봇은 초기 배정에서 제외 → 진짜 idle 로 남겨
            # replace_robot! 인계 대상으로 보존. (예비 주입이 배정보다 먼저라 SPARE_POOLS 는 이미 채워짐.)
            # is_spare 는 respec/ood_injection.jl 에 정의(같은 모듈, 런타임 해석). Symbol 로 안전 호출.
            rid = try node_id(entity(n)) catch; nothing end
            if rid !== nothing && (try is_spare(rid) catch; false end)
                continue                         # 예비 로봇 → 후보 집합에 넣지 않음(작업 미배정 = idle 유지)
            end
            go_vtx = first(outneighbors(sched,n))  # 그 로봇의 첫 이동(RobotGo) 노드
            @assert isempty(outneighbors(sched,go_vtx))  # 아직 아무 작업도 안 붙은(말단) 상태인지 확인
            push!(robots,go_vtx)                 # 가용 로봇 집합에 추가
        end
    end
    robots, active_build_steps                  # (이 줄은 두 변수를 가리키는 표현식일 뿐 — 효과 없음)
    # assign tasks

    # 전체 조립단계 수 세기: OpenBuildStep 노드 개수 ([true for ...] 길이로 셈)
    NUM_BUILD_STEPS = length([true for n in get_nodes(sched) if matches_template(OpenBuildStep,n)])
    BUILD_STEPS_CLOSED = 0                       # 지금까지 완료(닫힌) 단계 수

    @info "Beginning task assignment"            # 배정 시작 로그
    # initialize dependency graph to track and prevent cycles
    dependency_graph = build_step_dependency_graph(sched,scene_tree)  # 순환 방지용 의존그래프 초기화
    # cost_func = (v,v2)->get_edge_cost(model,D,v,v2)
    distance_dict = Dict{Tuple{Int,Int},Float64}()  # (정점v, 정점v2) → 이동시간 캐시(같은 계산 반복 방지)
    # cost_func : 로봇 v 가 작업슬롯 v2 를 맡을 때의 "예상 완료시각"을 돌려주는 익명함수.
    # (v,v2)->begin ... end : 여러 줄짜리 익명함수(파이썬의 lambda 를 여러 줄로 쓴 것).
    cost_func = (v,v2)->begin
        if !haskey(distance_dict,(v,v2))         # 이 쌍의 거리(시간)를 아직 안 구했으면
            new_node = align_with_successor(get_node(sched,v).node,get_node(sched,v2).node)  # v 를 v2 에 맞춰 정렬한 가상 노드
            distance_dict[(v,v2)] = generate_path_spec(sched,scene_tree,new_node).min_duration  # 그 이동의 최소 소요시간을 캐시
        end
        return get_tF(sched,v) + distance_dict[(v,v2)]  # 로봇 v 가 지금 끝나는 시각 + 이동시간 = 작업 완료 예상시각
        # return distance_dict[(v,v2)]
        # get_edge_cost(model,D,v,v2)
    end
    while !isempty(active_build_steps)          # 진행 가능한 단계가 남아있는 동안 반복(메인 루프)
        # get best possible assignment of robots to a team task
        best_cost       = Inf                   # 지금까지 찾은 최소 비용(Inf = 무한대, 초기값)
        build_step_id   = nothing               # 최선 선택의 단계 ID
        task_id         = nothing               # 최선 선택의 작업 ID
        best_assignments = nothing              # 최선 선택의 (로봇=>슬롯) 배정 목록
        for (step_id,tasks) in active_build_steps  # 활성 단계들과 그 작업들을 모두 살펴봄
            step_vtx = get_vtx(sched,step_id)
            # filter out robots that would cause a cycle
            # filt_func = (v,v2)->!has_path(dependency_graph,step_vtx,v)
            # filt_func = (v,v2)->!has_path(sched,step_vtx,v)
            for task in tasks                   # 그 단계의 각 작업(운반팀 형성)에 대해
                task_node = get_node(sched,task)
                cargo = get_node(scene_tree,cargo_id(entity(task_node)))  # 이 작업이 나르는 화물 노드
                if matches_template(AssemblyNode,cargo) && !(node_id(cargo) in assemblies_completed)
                    continue                    # 화물이 하위조립체인데 아직 미완성이면 이 작업은 건너뜀(준비 안 됨)
                end
                # 이 작업에 필요한 "로봇 자리(슬롯)"들 = 들어오는 RobotGo 더미 노드들
                team_slots = Set(v for v in inneighbors(sched,task) if matches_template(RobotGo,get_node(sched,v)))
                assignments = []                # 이 작업에 대한 (로봇=>슬롯) 임시 배정 목록
                # filt_func : 순환을 만들 로봇은 제외하는 필터(이 작업에서 로봇 v 로 가는 경로가 이미 있으면 안 됨)
                filt_func = (v,v2)->!has_path(dependency_graph,get_vtx(sched,task),v)
                cost = 0.0                      # 이 팀 작업의 비용(가장 늦게 도착하는 로봇 기준)
                while !isempty(team_slots)      # 모든 슬롯이 채워질 때까지
                    robot, slot, c = get_best_pair(robots, team_slots,  # 가용 로봇×남은 슬롯 중 비용 최소 쌍 찾기
                        cost_func,              # 비용 함수
                        filt_func,              # 순환 방지 필터
                        )
                    cost = max(c,cost)          # 팀 비용 = 슬롯들 중 가장 큰(가장 늦는) 비용
                    if cost >= best_cost        # 이미 현재 최선보다 나쁘면
                        break                   # 더 볼 필요 없이 중단(가지치기)
                    end
                    push!(assignments,robot=>slot)  # 이 (로봇=>슬롯) 배정 기록
                    @assert slot in team_slots  # 안전 점검
                    @assert robot in robots
                    setdiff!(team_slots,slot) # remove slot from team_slots  # 채운 슬롯 제거
                    setdiff!(robots,robot) # remove robots from robots        # 쓴 로봇을 가용목록에서 임시 제거
                end
                # @info "assignment for $(summary(task)): $assignments"
                # replace robot in robot set
                for (robot,slot) in assignments # 위에서 임시로 뺀 로봇들을 다시 가용목록에 복원
                    push!(robots,robot)         # (아직 확정 배정이 아니라 "후보 평가"였으므로 되돌림)
                end
                # update best assignment
                if cost < best_cost             # 이 작업의 비용이 지금까지 최선보다 작으면
                    build_step_id = step_id     # 최선 후보 정보 갱신
                    task_id = task
                    best_assignments = assignments
                    best_cost = cost
                    # @info "updating best assignment to $(summary(task)): $assignments"
                end
            end
        end
        # update schedule
        @assert !(best_assignments === nothing) "no assignment found!"  # 배정을 못 찾았으면 에러(있어야 정상)
        # @info "best assignment selected $(summary(task_id)): $best_assignments"
        team_task_vtx = get_vtx(sched,task_id)       # 확정된 팀 작업의 정점
        open_step_vtx = get_vtx(sched,build_step_id)  # 그 단계 시작 정점
        close_step_vtx = get_vtx(sched,CloseBuildStep(get_node(sched,build_step_id).node))  # 단계 종료 정점
        for (robot,task) in best_assignments         # 확정된 각 (로봇=>슬롯) 배정을 실제 스케줄에 반영
            add_edge!(sched,robot,task)              # 로봇 → 작업슬롯 엣지(이 로봇이 이 자리를 맡음)
            # add RobotNode -> TeamTask and OpenBuildStep -> TeamTask edges to dependency graph.
            add_edge!(dependency_graph, robot,          team_task_vtx)  # 의존그래프에도 로봇→팀작업
            add_edge!(dependency_graph, open_step_vtx,  team_task_vtx)  # 단계시작→팀작업
            add_edge!(dependency_graph, team_task_vtx,  close_step_vtx) # 팀작업→단계종료
            setdiff!(robots,robot) # remove robots    # 이번엔 진짜로 배정됐으니 가용 로봇에서 제거
        end
        # add new robots
        # 작업이 끝나면 로봇들은 화물 내려놓기(DepositCargo) 후 다시 자유로워짐 → 그 로봇들을 가용목록에 추가
        deposit_node = get_node(sched,DepositCargo(entity(get_node(sched,task_id))))  # 이 작업의 화물 내려놓기 노드
        for v in outneighbors(sched,deposit_node)    # 내려놓기 다음에 나오는 노드들 중
            if matches_template(RobotGo,get_node(sched,v))  # 로봇 이동 노드면(=풀려난 로봇)
                robot = v
                push!(robots,robot)                  # 가용 로봇 집합에 다시 넣음
                # add TeamTask -> RobotNode edge to dependency graph
                add_edge!(dependency_graph, team_task_vtx,  robot)  # 팀작업→풀려난로봇 의존(작업 후 가용)
            end
        end
        # update schedule times
        update_schedule_times!(sched)                # 변경된 배정에 맞춰 스케줄의 시작/종료 시각 재계산
        # update active build step list
        delete!(active_build_steps[build_step_id], task_id)  # 방금 처리한 작업을 그 단계의 남은 작업집합에서 제거
        if isempty(active_build_steps[build_step_id])  # 그 단계의 모든 작업이 끝났으면
            BUILD_STEPS_CLOSED += 1                  # 완료 단계 수 +1
            @info "Assignment: closing build step $(summary(build_step_id)). $(BUILD_STEPS_CLOSED)/$(NUM_BUILD_STEPS) complete. "  # 진행상황 로그
            delete!(active_build_steps, build_step_id)  # 활성목록에서 이 단계 제거
            close_build_step = get_node(sched,CloseBuildStep(get_node(sched,build_step_id).node))  # 종료 노드
            next_node = get_node(sched,first(outneighbors(sched,close_build_step)))  # 그 다음 노드
            if matches_template(OpenBuildStep,next_node)  # 다음이 또 다른 조립단계면
                step_id = node_id(next_node)
                active_build_steps[step_id] = construct_build_step_task_set(  # 그 단계의 작업집합을 새로 활성화
                    sched,
                    scene_tree,
                    step_id)
                # @info "new build step $(summary(step_id)) with tasks $(active_build_steps[step_id])"
            else
                # assembly complete
                @assert matches_template(AssemblyComplete,next_node)  # 아니면 조립체 완성 노드여야 함
                push!(assemblies_completed,node_id(entity(next_node)))  # 그 조립체를 완성 목록에 등록(다른 작업의 화물로 쓸 수 있게)
                @info "Closing Assembly $(summary(node_id(entity(next_node))))"  # 조립체 완성 로그
            end
        end
    end
    @info "Assignment Complete!"                     # 전체 배정 완료 로그
    model                                            # 배정이 반영된 모델 반환
end

end # @eval CB begin

"고정 시드로 env 를 배정 직후 상태까지만 세운다(시뮬 안 함). golden 스크립트와 동일 파라미터."
function build_env()
    model = get(ENV, "GREEDY_REG_MODEL", "tractor.mpd")
    return CB.run_lego_demo(; ldraw_file = model, project_name = "greedy_reg_equiv",
        num_robots = NROB, assignment_mode = :greedy,
        save_animation = false, write_results = false, overwrite_results = true,
        return_env_before_sim = true, rng = Random.MersenneTwister(SEED))
end

"골든 스크립트와 동일한 정규 지문(엣지 정렬 목록 + 전 정점 tF)."
function fingerprint(sched)
    io = IOBuffer()
    for e in sort(collect(Graphs.edges(sched.graph)), by = x -> (Graphs.src(x), Graphs.dst(x)))
        println(io, Graphs.src(e), "->", Graphs.dst(e))
    end
    println(io, "--tF--")
    for v in 1:Graphs.nv(sched)
        println(io, v, "=", round(CB.get_tF(sched, v), digits = 6))
    end
    body = String(take!(io))
    return bytes2hex(SHA.sha256(body)), body
end

# ---------------------------------------------------------------------------
# 실제 런 1회 — formulate_milp 오버라이드가 pre-assignment 스케줄을 캡처한다.
# (전체 파이프라인 재구현을 피하려고 실제 run_lego_demo 경로를 그대로 태운다.)
# ---------------------------------------------------------------------------
println("[equiv] building env (captures pre-assignment schedule via formulate_milp override)...")
env = build_env()
@assert CAPTURED_SCHED[] !== nothing "formulate_milp 오버라이드가 호출되지 않음 — assignment_mode=:greedy 경로 확인 필요"
pre_sched = CAPTURED_SCHED[]
scene_tree = CAPTURED_SPEC[]
println("[equiv] captured pre-assignment schedule: nv=", Graphs.nv(pre_sched))

# ===========================================================================
# (a) 공식 항등성 — 모든 정점 × dt 스프레드, `===` 로 검사
# ===========================================================================

# 캡처용 래퍼: 실제 GreedyFinalTimeCost 디스패치를 감싸서, (b)에서 쓸 실제 dt 표본을 모은다.
struct _CapturingCost{C<:CB.GreedyCost} <: CB.GreedyCost
    inner::C
end
const REAL_DTS = Float64[]
function CB.greedy_edge_cost(gc::_CapturingCost, sched, v, v2, dt::Float64)
    push!(REAL_DTS, dt)
    return CB.greedy_edge_cost(gc.inner, sched, v, v2, dt)
end

# dt_spread 는 (a) 와 (a-real) 둘 다 참조하므로 최상위 상수로 뺐다(@testset 은 자체 스코프를 만들어
# 내부에서 정의한 지역변수가 바깥/다른 testset 에서 안 보인다).
const DT_SPREAD = Float64[0.0, -0.0, 1e-12, 0.5, 1.0, 3.7, 100.0, 1e6, Inf, NaN]

@testset "(a) greedy_edge_cost 공식 항등성 (===, 모든 정점 × dt 스프레드)" begin
    # v2 는 세 메서드 공식(get_tF(sched,v)+dt) 어디에도 등장하지 않는다(정의만 받고 안 씀) —
    # 그래도 시그니처가 그걸 요구하므로 유효한 정점 아무거나(v 자신) 넘긴다.
    nv_sched = Graphs.nv(pre_sched)
    checked = 0
    for gc in (CB.GreedyPathLengthCost(), CB.GreedyFinalTimeCost(), CB.GreedyLowerBoundCost())
        for v in 1:nv_sched
            tF = CB.get_tF(pre_sched, v)
            for dt in DT_SPREAD
                expected = tF + dt
                got = CB.greedy_edge_cost(gc, pre_sched, v, v, dt)
                @test got === expected
                checked += 1
            end
        end
    end
    # M-2: non-vacuity — pre_sched 가 비어 캡처됐다면(예: 캡처 실패) 위 루프는 0 번 돌고도
    # 이 testset 은 "통과"로 보일 수 있다. 정확한 기대 횟수를 명시적으로 검증한다.
    @test checked == 3 * nv_sched * length(DT_SPREAD)
    println("[equiv] (a) checked ", checked, " (type × vertex × dt) triples via ===",
        " (expected 3 × ", nv_sched, " × ", length(DT_SPREAD), " = ", 3 * nv_sched * length(DT_SPREAD), ")")
end

# ===========================================================================
# (b) 프로세스 내부 A/B — 실제 콜사이트(디스패치, 캡처 래퍼) vs 변경 전 콜사이트(_legacy_assign!,
#     하드코딩 클로저 원본 그대로). 두 개의 서로 다른 함수를 실제로 실행해서 비교한다 — 단순히
#     같은 함수를 다른 이름의 동일 공식으로 두 번 부르는 게 아니다(I-1 참고).
#     같은 pre-assignment 스케줄의 두 독립 deepcopy 로 배정을 각각 돌린다.
#     같은 프로세스(같은 컴파일 상태) 안이므로 위에서 확인한 결정성이 적용된다.
# ===========================================================================
println("[equiv] (b) running assignment A (production call site: CB.assign_collaborative_tasks!, dispatch via GreedyFinalTimeCost)...")
modelA = CB.GreedyOrderedAssignment(
    schedule = deepcopy(pre_sched),
    problem_spec = scene_tree,
    greedy_cost = _CapturingCost(CB.GreedyFinalTimeCost()),
)
CB.assign_collaborative_tasks!(modelA)
CB.set_leaf_vtxs!(modelA.schedule, CB.ProjectComplete)
digestA, _ = fingerprint(modelA.schedule)

println("[equiv] (b) running assignment B (pre-change call site: CB._legacy_assign!, hardcoded closure verbatim from 4900206)...")
modelB = CB.GreedyOrderedAssignment(
    schedule = deepcopy(pre_sched),
    problem_spec = scene_tree,
    # greedy_cost 는 _legacy_assign! 이 아예 읽지 않는다(변경 전 코드엔 그 필드를 쓰는 코드가
    # 없었다는 사실 자체가 이 태스크의 출발점이었다) — 기본값을 그대로 둔다.
)
CB._legacy_assign!(modelB)
CB.set_leaf_vtxs!(modelB.schedule, CB.ProjectComplete)
digestB, _ = fingerprint(modelB.schedule)

@testset "(b) 프로세스 내부 A/B: 실제 콜사이트 vs 변경 전 콜사이트 (같은 스케줄, 같은 프로세스)" begin
    println("[equiv] (b) digestA(CB.assign_collaborative_tasks!, dispatch)=", digestA)
    println("[equiv] (b) digestB(CB._legacy_assign!, hardcoded)          =", digestB)
    @test digestA == digestB
end

# ---------------------------------------------------------------------------
# (a-real) — (b) 실행 중 실제로 관측된 dt 표본(REAL_DTS, distance_dict 에서 나온 진짜 값들)이
# (a)에서 이미 항등성을 검증해 둔 합성 스프레드(DT_SPREAD)의 범위 안에 드는지 확인한다.
#
# 정직하게 밝혀둘 순서: REAL_DTS 는 (b) 실행 중에 채워지고, (b)는 (a) *다음*에 실행된다.
# 그러므로 (a) 자체는 실전 dt 값을 검사하지 않았다 — (a)가 검사한 건 DT_SPREAD 라는 합성
# 스프레드뿐이다. 이 testset은 그 스프레드가 실전에서 실제로 나오는 dt 규모를 덮고 있었는지를
# (b) 이후 시점에 사후 확인하는 것이지, "실전 dt 자체에 대해 === 항등성을 재검사"하는 게 아니다
# (그러려면 (b) 실행 도중의 실시간 sched 상태가 필요한데, (b)가 끝난 지금은 이미 배정이 끝나
# tF 가 갱신돼 있어 그 시점 값을 재현할 수 없다).
# ---------------------------------------------------------------------------
@testset "(a-real) 실전 dt 표본이 (a)의 합성 스프레드 범위 안에 있는가" begin
    @test !isempty(REAL_DTS)
    if !isempty(REAL_DTS)
        finite_spread = filter(isfinite, DT_SPREAD)
        lo = minimum(finite_spread)  # 0.0 (== -0.0)
        hi = maximum(finite_spread)  # 1e6
        real_lo = minimum(REAL_DTS)
        real_hi = maximum(REAL_DTS)
        println("[equiv] (a-real) real dt samples captured: n=", length(REAL_DTS),
            " min=", real_lo, " max=", real_hi, "  (synthetic spread finite range: [", lo, ", ", hi, "])")
        @test real_lo >= lo
        @test real_hi <= hi
    end
end

println("[equiv] DONE — (a) formula identity + (b) in-process A/B (two distinct call sites) both executed. See testset results above.")
