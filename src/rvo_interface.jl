using PyCall   # 줄리아 안에서 파이썬 라이브러리(여기선 rvo2)를 호출하기 위한 패키지

# =============================================================================
# RVO2 INTERFACE : 상호 충돌회피(③ 최하위 레이어)용 Python RVO2 래퍼
# -----------------------------------------------------------------------------
# RVO(Reciprocal Velocity Obstacles): 각 에이전트가 "선호속도(pref velocity)"를
#   내면, 모든 에이전트가 서로의 속도를 고려해 충돌 없는 새 속도를 동시에 푼다.
#   (책임을 절반씩 나눠 부담 → reciprocal). 실제 풀이는 sisl/Python-RVO2(C++).
# 이 파일의 역할:
#   (1) Julia AbstractID ↔ RVO 정수 인덱스 매핑(RVOAgentMap) 관리
#   (2) 시뮬레이터 생성/파라미터(반경·최대속도·이웃거리) 설정
#   (3) 매 스텝 pref velocity / alpha(우선순위) 주입, 결과 속도/위치 읽기
# 상위 레이어(tangent bug ①, potential field ②)가 만든 속도를 pref로 넣는다.
# =============================================================================

# struct = 새 데이터 타입(파이썬 class 와 비슷, 값을 담는 틀).
# RVO 시뮬레이터 내부의 에이전트 정수 인덱스를 감싸는 래퍼
struct IntWrapper
    idx::Int                          # 감싸고 있는 실제 정수 인덱스
end

# const = 상수(이름을 한 번 정하면 안 바꿈). 여기선 긴 그래프 타입에 짧은 별명(RVOAgentMap)을 붙임.
# NGraph{DiGraph,IntWrapper,AbstractID} : 방향그래프, 노드값=IntWrapper, ID=AbstractID 인 그래프 타입.
const RVOAgentMap = NGraph{DiGraph,IntWrapper,AbstractID}
# nv(m) = 그래프의 노드 개수(number of vertices) → 등록된 에이전트 수. `f(x) = ...` 는 한 줄 함수 정의.
rvo_map_num_agents(m::RVOAgentMap) = nv(m)
# id(줄리아 ID)와 idx(RVO 정수 인덱스)의 대응을 맵에 등록. 이름 끝 `!` = 인자를 직접 수정(in-place)함을 표시.
function set_rvo_id_map!(m::RVOAgentMap, id::AbstractID, idx::Int)
    # @assert 조건 "메시지" : 조건이 거짓이면 에러로 중단. $(...) 는 문자열 안에 값 끼워넣기.
    @assert nv(m) == idx "RVOAgentMap shows $(nv(m)) agents, but this index is $idx"  # 새 인덱스는 현재 노드 수와 같아야(순서대로 추가됨)
    @assert !has_vertex(m, id) "Agent with id $(id) has already been added to schedule"  # 같은 id 가 이미 있으면 안 됨
    add_node!(m, IntWrapper(idx), id)  # idx 를 감싸 노드로, id 를 그 노드 ID 로 그래프에 추가
end
# 같은 함수의 인자 순서만 바꾼 버전(idx 를 먼저 줘도 동작). 다중 디스패치로 인자 타입에 맞춰 자동 선택됨.
set_rvo_id_map!(m::RVOAgentMap, idx::Int, id::AbstractID) = set_rvo_id_map!(m, id, idx)

# 줄리아 ID 로 RVO 인덱스를 조회. `.idx` 는 IntWrapper 안의 필드 접근. 아래는 입력 타입별로 꺼내는 방법만 다름.
rvo_get_agent_idx(id::AbstractID) = node_val(get_node(rvo_global_id_map(), id)).idx  # ID → 노드 → IntWrapper → idx
rvo_get_agent_idx(node::SceneNode) = rvo_get_agent_idx(node_id(node))                # 장면노드면 그 ID 로 다시 조회
rvo_get_agent_idx(node::ConstructionPredicate) = rvo_get_agent_idx(entity(node))     # 술어(predicate)면 그 대상 entity 로
rvo_get_agent_idx(node::ScheduleNode) = rvo_get_agent_idx(node.node)                 # 스케줄노드면 그 안의 .node 로

# global = 전역변수 선언. id↔idx 매핑을 담는 전역 맵을 빈 상태로 초기화.
global RVO_ID_GLOBAL_MAP = RVOAgentMap()
# 전역 맵을 꺼내는 게터(getter) 함수.
function rvo_global_id_map()
    RVO_ID_GLOBAL_MAP   # 마지막 줄의 값이 반환값(return 생략 가능)
end
# 전역 맵을 통째로 교체하는 세터(setter). 함수 안에서 전역변수를 바꾸려면 global 키워드 필요.
function set_rvo_global_id_map!(val)
    global RVO_ID_GLOBAL_MAP = val
end
rvo_map_num_agents() = rvo_map_num_agents(rvo_global_id_map())                    # 인자 없는 버전: 전역 맵의 에이전트 수
set_rvo_id_map!(id::AbstractID, idx::Int) = set_rvo_id_map!(rvo_global_id_map(), id, idx)  # 인자 없는 버전: 전역 맵에 등록
# 전역 맵을 새 빈 맵으로 리셋(시뮬레이션 다시 시작할 때).
function rvo_reset_agent_map!()
    global RVO_ID_GLOBAL_MAP = RVOAgentMap()
end

# (...) 안의 for = "제너레이터"(파이썬의 제너레이터 표현식). 등록된 각 에이전트 노드를 scene_tree 에서 찾아 하나씩 내줌.
rvo_active_agents(scene_tree) = (get_node(scene_tree, node_id(n)) for n in get_nodes(rvo_global_id_map()))

global RVO_PYTHON_MODULE = nothing   # 파이썬 rvo2 모듈을 담을 전역 변수(아직 비어있음 = nothing)
# 로드된 rvo2 파이썬 모듈을 돌려주는 게터.
function rvo_python_module()
    RVO_PYTHON_MODULE
end
# rvo2 모듈 전역변수를 교체하는 세터.
function set_rvo_python_module!(val)
    global RVO_PYTHON_MODULE = val
end

# rvo2 파이썬 모듈을 다시 불러온다(reset 후 재import).
function reset_rvo_python_module!()
    set_rvo_python_module!(nothing)            # 먼저 비우고
    set_rvo_python_module!(pyimport("rvo2"))   # pyimport 로 파이썬 rvo2 모듈을 import 해 저장
end

# 새 RVO 시뮬레이터 생성. 파라미터 의미:
#   dt           : 시간 스텝 [s]
#   neighbor_dist: 충돌회피 시 고려할 이웃 탐색 반경 [m]
#   max_neighbors: 동시에 고려할 최대 이웃 수 (계산량 제한)
#   horizon      : 다른 '에이전트'와의 충돌을 내다보는 시간지평 [s]
#   horizon_obst : 정적 '장애물'에 대한 시간지평 [s]
#   radius       : 기본 에이전트 반경 [m]
#   max_speed    : 기본 최대 속도 [m/s]
# 함수 인자에서 첫 `;` 뒤는 모두 "키워드 인자"(이름 붙여 호출, 기본값 있음). `x::Float64=...` 는 타입+기본값.
function rvo_new_sim(;
    dt::Float64=1 / 40.0,                       # 시간 스텝 [s] (1/40 = 0.025초)
    neighbor_dist::Float64=2.0,                 # 이웃 탐색 반경 [m]
    max_neighbors::Int=5,                       # 동시에 고려할 최대 이웃 수
    horizon::Float64=2.0,                       # 다른 에이전트와의 충돌 예측 시간지평 [s]
    horizon_obst::Float64=1.0,                  # 정적 장애물에 대한 시간지평 [s]
    radius::Float64=0.5,                        # 기본 에이전트 반경 [m]
    max_speed::Float64=rvo_default_max_speed(), # 기본 최대 속도 [m/s] (전역 기본값 함수에서 가져옴)
    default_vel=(0.0, 0.0)                      # 기본 속도 (x, y) 튜플
)
    reset_rvo_python_module!()   # rvo2 모듈 재import
    rvo_reset_agent_map!()       # id↔idx 매핑 초기화
    rvo_python_module().PyRVOSimulator(   # 파이썬 모듈의 PyRVOSimulator(=C++ RVO2 시뮬레이터) 인스턴스 생성·반환
        dt, neighbor_dist, max_neighbors, horizon, horizon_obst, radius, max_speed, default_vel
    )
end

# =============================================================================
# NATIVE EXPORT/IMPORT ADAPTER (2026-09-24, zone-repair-verification T3)
# -----------------------------------------------------------------------------
# checkpoint(`src/verification/episode_checkpoint.jl`)가 RVO2(C++, PyCall) 상태를 옮기는 유일한 길.
# 바인딩이 읽고 쓰는 것(sisl/Python-RVO2 `rvo2.pyx`, 설치본 `dir(PyRVOSimulator)` 로 확인):
#   에이전트 i(= addAgent 순서 = id)마다 위치·실제 속도·pref 속도·반지름·최대속도·이웃거리·최대이웃수·
#   두 시간지평·alpha — **전부 get/set 둘 다 있다**(float32 로 저장되므로 get→set 은 비트 동일).
#   시간 스텝: get/set. 장애물: 읽기만(addObstacle 뿐) — 이 레포는 장애물을 안 쓰므로 0 이 아니면 gap.
# 바인딩이 **못 하는 것** 둘(측정: `logs/t3-rvo-probe.log`):
#   1. `globalTime_` — setter 가 없다. 새 sim 은 0 에서 시작한다. `RVOSimulator::doStep` 은 이 값을
#      더하기만 하고 동역학이 읽지 않으며(소스), 이 레포에 `getGlobalTime` 호출자가 0 개다. 측정: 원본
#      (t=15 s)과 복원본(t=10 s)의 400 스텝 궤적이 비트 동일. → 동역학 비관여(`residual`)로 남긴다.
#   2. `KdTree::agents_` 순열 — 매 `buildAgentTree` 가 **이전 순서 위에서** 제자리 분할하므로 원본의
#      순열은 sim 생성 이후 매 doStep 직전 위치의 전 이력에 의존한다. 읽을 수도 쓸 수도 없다. 이웃 목록은
#      거리 오름차순이라 순열은 **이웃 거리가 정확히 같을 때만** 결과를 바꾼다. 측정: 정확한 동률 격자에서
#      300 회 중 7~9 회 한 스텝 만에 상태가 갈렸다(무작위 배치 0 회).
#   → 두 겹으로 막는다.
#   (a) **이력 재연(정확 복원)**: `RVO_RECORD_BUILDS[]`(하니스가 켠다, 기본 false)이면 `rvo_set_new_sim!`
#       이 새 sim 을 `RVOSimHarness` 로 감싸 **생성 이후 매 doStep 직전 위치**를 기록한다. import 는 새 sim
#       에 그 위치들을 차례로 놓고 doStep 을 같은 횟수 돌려 KdTree 순열을 원본과 **같은 입력으로 다시 만든**
#       뒤 모든 필드를 덮어쓴다. `globalTime_` 도 같은 횟수의 float32 누적으로 원본과 같아진다(검사한다).
#       기록 수와 globalTime 이 맞지 않으면(= 기록 전에 doStep 이 있었다) 이 길을 쓰지 않는다.
#   (b) **동률 감시(대체)**: 이력이 없으면 복원 sim 을 감시 모드로 감싸 다음 재구축까지 매 doStep 직전에
#       동률을 검사한다. 동률이 있으면 ORCA 선을 다시 세워 순서 무관을 증명해 보고(`resolved`), 증명 못 한
#       동률이 하나라도 있으면 그 분기는 원본 궤적 재현을 **주장할 수 없다**(`ties` 가 비어야 한다).
#   globalTime_ 은 (a) 에서만 복원된다. (b) 에서는 0 에서 시작하고, 동역학이 읽지 않는다(소스·측정).
# 위치 일치만으로 복원 성공이라 하지 않는다: `rvo_export_state` 가 위 필드 전부를 정준 행으로 낸다.
# =============================================================================
const RVO_AGENT_FIELDS = (:Position, :Velocity, :PrefVelocity, :Radius, :MaxSpeed,
                          :NeighborDist, :MaxNeighbors, :TimeHorizon, :TimeHorizonObst, :Alpha)

"""
RVO sim 하니스 래퍼. `doStep` 만 가로채고 나머지 호출은 그대로 넘긴다(읽기 전용 — 동역학을 안 바꾼다).
  · `builds !== nothing` — 생성 이후 매 doStep 직전 에이전트 위치를 기록한다(KdTree 순열 재연용).
  · `watch = true` — 매 doStep 직전 이웃 거리 동률을 검사한다(이력이 없는 복원 sim).
"""
mutable struct RVOSimHarness
    py::PyObject
    builds::Union{Nothing,Vector{Vector{Tuple{Float64,Float64}}}}
    watch::Bool
    n_steps::Int                 # 이 래퍼가 본 doStep 수
    ties::Vector{String}         # 순서 무관을 증명 못 한 동률(비어야 인증 가능)
    resolved::Int                # 동률이 있었으나 순서 무관이 증명된 (에이전트, 스텝) 수
    kd_restored::Bool            # import 가 이력 재연으로 KdTree 순열을 복원했나
end
RVOSimHarness(py::PyObject; record = false, watch = false, builds = record ? Vector{Tuple{Float64,Float64}}[] : nothing,
              kd_restored = false) = RVOSimHarness(py, builds, watch, 0, String[], 0, kd_restored)
const RVOTieWatch = RVOSimHarness   # 옛 이름(시험·보고서)
function Base.getproperty(w::RVOSimHarness, s::Symbol)
    s in fieldnames(RVOSimHarness) && return getfield(w, s)
    s === :doStep && return () -> begin
        py = getfield(w, :py)
        getfield(w, :watch) && _rvo_tie_check!(w)
        b = getfield(w, :builds)
        b === nothing || push!(b, [py.getAgentPosition(i) for i in 0:py.getNumAgents()-1])
        w.n_steps += 1
        py.doStep()
    end
    return getproperty(getfield(w, :py), s)
end
_rvo_raw(x) = x isa RVOSimHarness ? getfield(x, :py) : x
"하니스가 켠다(기본 false = 모든 기존 런에서 sim 은 맨 PyObject). 켜면 `rvo_set_new_sim!` 이 기록 래퍼를 꽂는다."
const RVO_RECORD_BUILDS = Ref(false)

"""
`KdTree` 순열이 결과를 바꿀 수 있는 조건 = 어떤 에이전트의 범위 안 이웃 거리²(float32) 중 결과에 들어가는
앞 `maxNeighbors+1` 개에 동률이 있을 때(`Agent::insertAgentNeighbor` 는 엄격 `<` 로 정렬 삽입한다).
FMA·반올림 차이를 덮으려고 상대 1e-6 이내를 동률로, 범위를 1e-5 넓게 본다(보수적 = 더 많이 잡는다).

동률이 있어도 결과가 순서와 무관함을 **증명할 수 있는** 경우가 있다: `linearProgram2` 는 시작점(= pref 속도,
최대속도 원 밖이면 원 위로 정규화 — 순서 무관)을 두고, 그것을 **위반하는** ORCA 선이 있을 때만 움직인다.
범위 안 **모든** 후보 이웃(어느 순서·어느 k-집합이든 그 부분집합이다)의 ORCA 선을 `Agent::computeNewVelocity`
그대로 Float64 로 다시 세워, 시작점이 모든 선을 여유 `1e-4` 이상으로 만족하면 그 에이전트의 새 속도는
순열과 무관하다(`resolved`). 하나라도 여유 안이면 증명 못 한다 → `ties` 에 남는다.
"""
function _rvo_tie_check!(w::RVOSimHarness)
    s = getfield(w, :py)
    n = s.getNumAgents()
    A = [NamedTuple{RVO_AGENT_FIELDS}(Tuple(getproperty(s, Symbol(:getAgent, f))(i) for f in RVO_AGENT_FIELDS))
         for i in 0:n-1]
    dt = s.getTimeStep()
    for i in 1:n
        a = A[i]
        a.MaxNeighbors == 0 && continue
        nd = Float32(a.NeighborDist)
        r2 = nd * nd * (1.0f0 + 1.0f-5)
        xi, yi = Float32(a.Position[1]), Float32(a.Position[2])
        d = Tuple{Float32,Int}[]
        for j in 1:n
            j == i && continue
            dx = Float32(A[j].Position[1]) - xi; dy = Float32(A[j].Position[2]) - yi
            q = dx * dx + dy * dy
            q < r2 && push!(d, (q, j))
        end
        sort!(d)
        tie = any(t -> d[t][1] - d[t-1][1] <= 1.0f-6 * max(d[t][1], 1.0f-30), 2:min(length(d), a.MaxNeighbors + 1))
        tie || continue
        bad = findfirst(jd -> !_rvo_orca_satisfied(a, A[jd[2]], dt), d)
        if bad === nothing
            w.resolved += 1
        else
            j = d[bad][2]; b = A[j]
            push!(w.ties, "doStep#$(w.n_steps + 1) agent=$(i - 1) n_in_range=$(length(d)) " *
                          "unproven_neighbor=$(j - 1) d2=$(d[bad][1]) det=$(_rvo_orca_det(a, b, dt)) " *
                          "alpha=($(a.Alpha),$(b.Alpha)) r=($(a.Radius),$(b.Radius)) " *
                          "pref=$(a.PrefVelocity) vel=$(a.Velocity) vel_nb=$(b.Velocity)")
        end
    end
    return nothing
end

"""
에이전트 a 의 LP 시작점(pref, 원 밖이면 정규화)이 이웃 b 의 ORCA 선을 여유 있게 만족하나(sisl Agent.cpp 이식).
정확한 경우 하나를 따로 판정한다: float32 로 `alpha == 1`(b.Alpha == 0 < a.Alpha)이면 선의 점이 a 의 현재 속도
**그 자체**라 시작점이 그 속도와 비트 같으면 `det` 이 정확히 0 → C++ 의 `> 0.0f` 는 거짓(위반 아님, 순서 무관).
"""
_rvo_orca_satisfied(a, b, dt; margin = 1e-4) = begin
    asum = Float32(a.Alpha) + Float32(b.Alpha)
    exact = asum > 0 && Float32(a.Alpha) / asum == 1.0f0 && _rvo_lp_start(a) == collect(Float64.(Float32.(a.Velocity)))
    exact || (v = _rvo_orca_det(a, b, dt); isfinite(v) && v < -margin)
end
function _rvo_lp_start(a)
    pv = collect(a.PrefVelocity); ms = a.MaxSpeed
    return sum(abs2, pv) > ms^2 ? pv ./ sqrt(sum(abs2, pv)) .* ms : pv
end
"a 의 LP 시작점에 대한 이웃 b 의 ORCA 선 `det(direction, point - start)`(> 0 이면 위반). Float64 재계산."
function _rvo_orca_det(a, b, dt)
    det2(u, v) = u[1] * v[2] - u[2] * v[1]
    start = _rvo_lp_start(a)
    rp = collect(b.Position) .- collect(a.Position)
    rv = collect(a.Velocity) .- collect(b.Velocity)
    dsq = sum(abs2, rp); cr = a.Radius + b.Radius; crsq = cr^2
    asum = a.Alpha + b.Alpha; alpha = asum > 0 ? a.Alpha / asum : 0.5
    if dsq > crsq
        inv = 1 / a.TimeHorizon
        wv = rv .- inv .* rp; wl2 = sum(abs2, wv); dot1 = sum(wv .* rp)
        if dot1 < 0 && dot1^2 > crsq * wl2
            wl = sqrt(wl2); uw = wv ./ wl
            dir = [uw[2], -uw[1]]; u = (cr * inv - wl) .* uw
        else
            leg = sqrt(dsq - crsq)
            dir = det2(rp, wv) > 0 ? [rp[1] * leg - rp[2] * cr, rp[1] * cr + rp[2] * leg] ./ dsq :
                                     -[rp[1] * leg + rp[2] * cr, -rp[1] * cr + rp[2] * leg] ./ dsq
            u = sum(rv .* dir) .* dir .- rv
        end
    else
        its = 1 / dt
        wv = rv .- its .* rp; wl = sqrt(sum(abs2, wv)); uw = wv ./ wl
        dir = [uw[2], -uw[1]]; u = (cr * its - wl) .* uw
    end
    pt = collect(a.Velocity) .+ (1 - alpha) .* u
    return det2(dir, pt .- start)
end

"""
    rvo_export_state(; residual = true) -> (; state, residual, gaps)

현재 RVO 상태를 순수 데이터로 읽는다(**읽기만** 한다). `state` 는 checkpoint 의 정준 행이 되는 부분,
`residual` 은 옮길 수 없고 동역학 비관여이거나 분기 감시로 넘기는 값, `gaps` 는 인증을 막는 사유.
"""
function rvo_export_state(; residual::Bool = true)
    w = rvo_global_sim_wrapper()
    m = rvo_python_module()
    modfile = m === nothing ? nothing : String(m.__file__)
    s = _rvo_raw(w.element)
    s === nothing && return (state = (element = nothing, is_up_to_date = w.is_up_to_date,
                                      timestamp = w.timestamp, module_file = modfile),
                             residual = (;), gaps = String[])
    n = s.getNumAgents()
    agents = [NamedTuple{RVO_AGENT_FIELDS}(Tuple(getproperty(s, Symbol(:getAgent, f))(i)
                                                 for f in RVO_AGENT_FIELDS)) for i in 0:n-1]
    nobs = s.getNumObstacleVertices()
    gaps = nobs == 0 ? String[] :
        ["native: RVO has $(nobs) obstacle vertices — the adapter does not rebuild obstacles"]
    return (state = (element = (time_step = s.getTimeStep(), n_agents = n, agents = agents),
                     is_up_to_date = w.is_up_to_date, timestamp = w.timestamp, module_file = modfile),
            residual = residual ? _rvo_residual(w.element, s) : (;), gaps = gaps)
end

"옮기지 않는 값: globalTime 과 KdTree 순열의 재연 이력(있고 globalTime 과 맞을 때만 `kd_known`)."
function _rvo_residual(el, s)
    gt = s.getGlobalTime(); dt = s.getTimeStep()
    b = el isa RVOSimHarness ? getfield(el, :builds) : nothing
    t = 0.0f0
    b === nothing || for _ in b; t += Float32(dt); end
    known = b !== nothing && t == Float32(gt)
    return (global_time = gt, n_builds = b === nothing ? nothing : length(b), kd_known = known,
            builds = known ? copy(b) : nothing)
end

"""
    rvo_import_state!(state, residual = nothing) -> Union{Nothing,RVOSimHarness}

`rvo_export_state()` 로 새 sim 을 만들어 전역 래퍼에 꽂는다. 에이전트는 id 순서로 addAgent 한다.
`residual.kd_known` 이면 기록된 doStep 직전 위치들로 doStep 을 같은 횟수 돌려 KdTree 순열과 globalTime 을
재연한 뒤(검사한다) 모든 필드를 setter 로 되돌린다 — 정확 복원. 아니면 동률 감시 모드로 감싼다.
`RVO_ID_GLOBAL_MAP` 은 **건드리지 않는다**(checkpoint 가 먼저 복원한다 — `rvo_new_sim` 이 맵을 비우므로
전후로 보존한다). 래퍼의 `timestamp` 는 기록값 그대로(`_CACHE_TIMESTAMP_COUNTER` 를 올리지 않는다).
반환값 = 분기가 끝날 때 읽을 하니스(`kd_restored`·`ties`).
"""
function rvo_import_state!(st, residual = nothing)
    idmap = rvo_global_id_map()
    w = rvo_global_sim_wrapper()
    e = st.element
    h = nothing
    if e === nothing
        st.module_file === nothing ? set_rvo_python_module!(nothing) : reset_rvo_python_module!()
    else
        s = rvo_new_sim(; dt = e.time_step)          # 생성자 기본값 = 원본 생성 경로와 같은 함수
        set_rvo_global_id_map!(idmap)                # rvo_new_sim 이 비운 맵을 되돌린다
        for (i, a) in enumerate(e.agents)
            idx = s.addAgent(a.Position)
            idx == i - 1 || error("rvo_import_state!: addAgent returned $(idx), expected $(i - 1)")
        end
        known = residual !== nothing && get(residual, :kd_known, false) === true
        if known
            for P in residual.builds                 # KdTree 순열·globalTime 재연(결과 상태는 아래서 덮는다)
                length(P) == length(e.agents) || error("rvo_import_state!: build history agent count drift")
                for (i, p) in enumerate(P)
                    s.setAgentPosition(i - 1, p); s.setAgentVelocity(i - 1, (0.0, 0.0))
                    s.setAgentPrefVelocity(i - 1, (0.0, 0.0))
                end
                s.doStep()
            end
            s.getGlobalTime() == residual.global_time ||
                error("rvo_import_state!: replayed globalTime $(s.getGlobalTime()) != $(residual.global_time)")
        end
        for (i, a) in enumerate(e.agents), f in RVO_AGENT_FIELDS
            getproperty(s, Symbol(:setAgent, f))(i - 1, getfield(a, f))
        end
        h = known ? RVOSimHarness(s; builds = RVO_RECORD_BUILDS[] ? copy(residual.builds) : nothing, kd_restored = true) :
                    RVOSimHarness(s; watch = true)
    end
    f = rvo_python_module() === nothing ? nothing : String(rvo_python_module().__file__)
    f == st.module_file || error("rvo_import_state!: rvo2 module $(f) != captured $(st.module_file)")
    w.element = h; w.is_up_to_date = st.is_up_to_date; w.timestamp = st.timestamp
    return h
end

# global RVO_SIM_WRAPPER = RVOSimWrapper(nothing)   # (옛 코드 — 무시)
# CachedElement{Any} : 값을 캐시(저장)해두는 래퍼. {Any} = 아무 타입이나 담는다는 타입 매개변수. (값, 유효플래그, 시각) 으로 초기화.
global RVO_SIM_WRAPPER = CachedElement{Any}(nothing, false, time())
rvo_global_sim_wrapper() = RVO_SIM_WRAPPER   # 시뮬레이터 캐시 래퍼를 돌려주는 게터
# 새 시뮬레이터를 전역 캐시에 설정. sim 인자를 안 주면 rvo_new_sim() 으로 기본 시뮬레이터를 새로 만든다.
function rvo_set_new_sim!(sim=rvo_new_sim())
    # 검증 하니스(T3): 켜져 있으면 doStep 직전 위치를 기록하는 래퍼로 감싼다(기본 false = 기존 그대로).
    RVO_RECORD_BUILDS[] && (sim = RVOSimHarness(sim; record = true))
    set_element!(rvo_global_sim_wrapper(), sim)   # 캐시 래퍼 안에 새 시뮬레이터를 넣음
    # rvo_global_sim_wrapper().sim = sim          # (옛 코드 — 무시)
end
# rvo_global_sim() = rvo_global_sim_wrapper().sim  # (옛 코드 — 무시)
rvo_global_sim() = get_element(rvo_global_sim_wrapper())  # 전역 시뮬레이터 인스턴스를 캐시에서 꺼냄

# RVO PARAMETERS  (아래 전역변수들은 속도·이웃거리의 기본값. 각각 게터/세터 쌍으로 읽고 바꿈)
global RVO_MAX_SPEED_VOLUME_FACTOR = 0.01   # 부피 1당 깎이는 최대속도 양(부피가 클수록 느려짐)
global RVO_MAX_SPEED = 4.0                  # 기본 최대 속도 [m/s]
global RVO_MIN_MAX_SPEED = 1.0              # 최대속도의 하한(아무리 느려도 이 값 이상)
function rvo_default_max_speed()            # 기본 최대속도 게터
    RVO_MAX_SPEED
end
function set_rvo_default_max_speed!(val)    # 기본 최대속도 세터
    global RVO_MAX_SPEED = val
end
function rvo_default_max_speed_volume_factor()      # 부피 감속 계수 게터
    RVO_MAX_SPEED_VOLUME_FACTOR
end
function set_rvo_default_max_speed_volume_factor!(val)  # 부피 감속 계수 세터
    global RVO_MAX_SPEED_VOLUME_FACTOR = val
end
function rvo_default_min_max_speed()        # 최대속도 하한 게터
    RVO_MIN_MAX_SPEED
end
function set_rvo_default_min_max_speed!(val)  # 최대속도 하한 세터
    global RVO_MIN_MAX_SPEED = val
end

""" get_rvo_max_speed(node) """
# `::RobotNode` 처럼 값 이름 없이 타입만 적으면 "이 타입일 때만 이 메서드를 쓴다"(다중 디스패치).
# 단일 로봇은 기본 최대속도.
get_rvo_max_speed(::RobotNode) = rvo_default_max_speed()
# 운반팀/적재물은 부피가 클수록 느리게:
#   vmax_eff = max(vmax - vol·factor, min_max_speed)
#   → 큰 payload를 든 팀은 기동성이 떨어진다는 물리적 직관을 모델링.
function get_rvo_max_speed(node)
    rect = get_base_geom(node, HyperrectangleKey())  # 노드의 기본 형상을 "직육면체(경계상자)"로 가져옴
    vol = LazySets.volume(rect)              # 경계상자 부피
    # Speed limited by volume
    vmax = rvo_default_max_speed()           # 기본 최대속도에서 출발
    delta_v = vol * rvo_default_max_speed_volume_factor()  # 부피 비례 감속량
    return max(vmax - delta_v, rvo_default_min_max_speed())# 하한 보장
end

""" get_rvo_radius(node) """
# 노드의 기본 형상을 "구(hypersphere)"로 가져와 그 반지름을 RVO 에이전트 반경으로 사용.
get_rvo_radius(node) = get_base_geom(node, HypersphereKey()).radius


global RVO_DEFAULT_TIME_STEP = 1 / 40.0     # 기본 시간 스텝 [s]
function rvo_default_time_step()            # 기본 시간 스텝 게터
    RVO_DEFAULT_TIME_STEP
end
function set_rvo_default_time_step!(val)    # 기본 시간 스텝 세터
    global RVO_DEFAULT_TIME_STEP = val
end


global RVO_DEFAULT_NEIGHBOR_DISTANCE = 2.0                     # 기본 이웃 탐색 거리 [m]
global RVO_DEFAULT_MIN_NEIGHBOR_DISTANCE = 1.0                 # 이웃 탐색 거리의 하한 [m]
global RVO_DEFAULT_NEIGHBORHOOD_VELOCITY_SCALE_FACTOR = 1.0    # 속도에 따라 탐색거리를 조절하는 비례계수
function rvo_default_neighbor_distance()            # 기본 이웃거리 게터
    RVO_DEFAULT_NEIGHBOR_DISTANCE
end
function set_rvo_default_neighbor_distance!(val)    # 기본 이웃거리 세터
    global RVO_DEFAULT_NEIGHBOR_DISTANCE = val
end
function rvo_default_min_neighbor_distance()        # 이웃거리 하한 게터
    RVO_DEFAULT_MIN_NEIGHBOR_DISTANCE
end
function set_rvo_default_min_neighbor_distance!(val)  # 이웃거리 하한 세터
    global RVO_DEFAULT_MIN_NEIGHBOR_DISTANCE = val
end
function rvo_default_neighborhood_velocity_scale_factor()      # 속도-탐색거리 비례계수 게터
    RVO_DEFAULT_NEIGHBORHOOD_VELOCITY_SCALE_FACTOR
end
function set_rvo_default_neighborhood_velocity_scale_factor!(val)  # 속도-탐색거리 비례계수 세터
    global RVO_DEFAULT_NEIGHBORHOOD_VELOCITY_SCALE_FACTOR = val
end

# 이웃 탐색 거리: 빠른(느린) 에이전트일수록 더 멀리(가까이) 살핀다.
#   d = max(default - (v/vmax)·scale, min_dist)
function get_rvo_neighbor_distance(node)
    d = rvo_default_neighbor_distance()                            # 기본 탐색거리에서 시작
    v_ratio = get_rvo_max_speed(node) / rvo_default_max_speed()    # 이 노드 최대속도가 기본대비 얼마나 빠른지(비율)
    delta_d = v_ratio * rvo_default_neighborhood_velocity_scale_factor()  # 비율에 따른 탐색거리 조정량
    d = max(d - delta_d, rvo_default_min_neighbor_distance())      # 조정 후 하한 보장(마지막 줄 값이 반환됨)
end

# 에이전트(로봇/운반팀)를 RVO 시뮬레이터에 등록하고 id↔idx 매핑을 저장.
# `Union{A,B}` = A 또는 B 둘 중 아무 타입이나 받는다는 합집합 타입.
# 반경/최대속도/이웃거리를 위 함수들로 산출해 개별 설정.
function rvo_add_agent!(agent::Union{RobotNode,TransportUnitNode}, sim)
    rad = get_rvo_radius(agent) * 1.05 # Add a little bit of padding for visualization  # 시각화용 여유 5% 추가
    max_speed = get_rvo_max_speed(agent)                     # 이 에이전트의 최대속도 산출
    neighbor_dist = get_rvo_neighbor_distance(agent)         # 이 에이전트의 이웃 탐색거리 산출
    pt = project_to_2d(global_transform(agent).translation)  # 3D 포즈 → 2D 평면위치
    agent_idx = sim.addAgent((pt[1], pt[2]))                 # RVO에 추가, 인덱스 획득 (sim.addAgent 는 파이썬 메서드 호출)
    set_rvo_id_map!(node_id(agent), agent_idx)               # Julia id ↔ RVO idx 저장
    sim.setAgentNeighborDist(agent_idx, neighbor_dist)       # 이 에이전트의 이웃거리 설정
    sim.setAgentMaxSpeed(agent_idx, max_speed)               # 최대속도 설정
    sim.setAgentRadius(agent_idx, rad)                       # 반경 설정
    return agent_idx                                         # RVO 인덱스 반환
end


# 에이전트의 현재 위치를 RVO 시뮬레이터에서 읽어옴.
function rvo_get_agent_position(n)
    rvo_idx = rvo_get_agent_idx(n)                  # 노드 → RVO 인덱스
    rvo_global_sim().getAgentPosition(rvo_idx)      # 시뮬레이터에서 (x,y) 위치 조회
end
# 에이전트 위치를 강제로 설정(텔레포트). pos[1],pos[2] = x,y.
function rvo_set_agent_position!(node, pos)
    idx = rvo_get_agent_idx(node)
    rvo_global_sim().setAgentPosition(idx, (pos[1], pos[2]))
end

# pref velocity 주입: 상위 레이어(①②)가 계산한 "가고 싶은 속도"를 RVO에 전달.
#   다음 sim.doStep() 에서 RVO가 이걸 최대한 존중하되 충돌 없는 속도로 보정한다.
function rvo_set_agent_pref_velocity!(node, vel)
    idx = rvo_get_agent_idx(node)
    rvo_global_sim().setAgentPrefVelocity(idx, (vel[1], vel[2]))  # 선호속도 (vx,vy) 설정
end

# 현재 설정된 선호속도를 읽어옴.
function rvo_get_agent_pref_velocity(node)
    idx = rvo_get_agent_idx(node)
    rvo_global_sim().getAgentPrefVelocity(idx)
end
# doStep() 후 RVO가 실제로 정한 충돌회피 속도를 읽어옴(위치 적분에 사용).
function rvo_get_agent_velocity(node)
    idx = rvo_get_agent_idx(node)
    rvo_global_sim().getAgentVelocity(idx)
end

# 에이전트의 최대속도를 설정. speed 를 안 주면 노드로부터 계산한 기본값 사용.
function rvo_set_agent_max_speed!(node, speed=get_rvo_max_speed(node))
    idx = rvo_get_agent_idx(node)
    rvo_global_sim().setAgentMaxSpeed(idx, speed)
end
# alpha = 동적 우선순위(작을수록 높음). sisl이 RVO2를 fork해 추가한 기능으로,
#   충돌회피 책임 분담을 비대칭으로 만든다(우선순위 낮은 쪽이 더 많이 양보).
#   값은 route_planning.set_rvo_priority! 가 작업 상태에 따라 매 스텝 갱신.
function rvo_set_agent_alpha!(node, alpha=0.5)
    idx = rvo_get_agent_idx(node)
    rvo_global_sim().setAgentAlpha(idx, alpha)   # 우선순위 alpha 설정
end
# 현재 alpha(우선순위) 값을 읽어옴.
function rvo_get_agent_alpha(node)
    idx = rvo_get_agent_idx(node)
    rvo_global_sim().getAgentAlpha(idx)
end

# 메타프로그래밍: 아래 타입 목록 각각에 대해 같은 메서드를 자동으로 찍어낸다(반복 코드 줄이기).
# `:RobotStart` 처럼 `:` 가 붙으면 "심볼"(이름 자체를 값으로 다룸). @eval 은 코드를 만들어 실행하는 매크로.
for T in (
    :RobotStart,           # 로봇 시작
    :RobotGo,              # 로봇 이동
    :FormTransportUnit,    # 운반팀 대형 형성
    :TransportUnitGo,      # 운반팀 이동
    :DepositCargo          # 적재물 내려놓기
)
    @eval begin
        # $T 는 위 루프의 T(타입 이름)를 코드 안에 끼워넣음 → 이 5개 타입에 대해 "RVO 에이전트 자격 있음(true)" 메서드 생성.
        rvo_eligible_node(n::$T) = true
    end
end
# 위 5개에 해당하지 않는 그 외 모든 노드는 RVO 에이전트 자격 없음(false). (가장 일반적인 fallback 메서드)
rvo_eligible_node(n) = false

# 현재 scene_tree에서 "독립적으로 움직이는 단위"만 RVO 에이전트로 등록:
#   - 자유 로봇: 다른 노드에 매달려 있지 않은 root 로봇(=팀에 안 묶인 단독 로봇)
#   - 운반팀(TransportUnit): 대형(formation)이 갖춰진 팀 전체를 하나의 에이전트로
#   (팀에 묶인 개별 로봇은 팀 에이전트로 대표되므로 따로 등록하지 않음)
# sim 인자를 안 주면 전역 시뮬레이터를 사용.
function rvo_add_agents!(scene_tree, sim=rvo_global_sim())
    for node in get_nodes(scene_tree)                 # 장면 트리의 모든 노드를 순회
        if matches_template(RobotNode, node)          # 이 노드가 로봇이면 (matches_template = 타입 일치 검사)
            if is_root_node(scene_tree, node)        # 팀에 안 묶인 단독 로봇
                idx = rvo_add_agent!(node, sim)       # RVO 에이전트로 등록
            end
        elseif matches_template(TransportUnitNode, node)  # 운반팀 노드면
            if is_in_formation(node, scene_tree)     # 대형 완성된 운반팀
                idx = rvo_add_agent!(node, sim)       # RVO 에이전트로 등록
            end
        end
    end
end

# 위 등록 대상 중 아직 전역 맵에 없는 에이전트가 있는지 검사 → 있으면 시뮬레이터 갱신 필요(true).
function rvo_sim_needs_update(scene_tree)
    for node in get_nodes(scene_tree)                 # 모든 노드를 순회하며
        if matches_template(RobotNode, node)          # 로봇이고
            if is_root_node(scene_tree, node)         # 단독 로봇인데
                if !has_vertex(rvo_global_id_map(), node_id(node))  # 아직 맵에 등록 안 됐으면
                    return true                       # 갱신 필요
                end
            end
        elseif matches_template(TransportUnitNode, node)  # 운반팀이고
            if is_in_formation(node, scene_tree)      # 대형이 완성됐는데
                if !has_vertex(rvo_global_id_map(), node_id(node))  # 아직 맵에 없으면
                    return true                       # 갱신 필요
                end
            end
        end
    end
    return false                                      # 빠진 에이전트 없음 → 갱신 불필요
end
