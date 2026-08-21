# =============================================================================
# observe.jl — env → s 의 **유일한** 경로 (spec §6 C2, 게이트 N-G0)
#
# 계약 셋. 어기면 롤아웃이 조용히 틀린다:
#   (1) **읽기 전용.** env·전역을 하나도 수정하지 않는다. 관측이 세계를 바꾸면 같은 상태를
#       두 번 관측한 것만으로 갈래가 갈린다. 🔴 이 계약은 "대입을 안 한다" 보다 넓다 —
#       **지연 초기화 헬퍼를 부르는 것도 수정이다.** 구체적으로 `_hz_ensure!`(hazard.jl:296)
#       를 부르면 안 된다: 그 함수는 Dict 를 채울 뿐 아니라 그 로봇 전용 스트림에서 난수를
#       **태운다**(ε_r · Exp(1) 문턱 네 개). 관측 한 번이 CRN 을 밀어버린다.
#       ⚠️ **한 군데는 원리적으로 아슬아슬하다**: `global_transform`(hierarchical_geom_essentials.jl:347)
#       은 `get_cached_value!` 라 캐시가 낡았으면 재계산하면서 `_CACHE_TIMESTAMP_COUNTER`
#       (graph_utils_essentials.jl:143, ξ 소속 — simstate.jl `ReplayState.cache_counter`)를 올린다.
#       pose 를 읽는 다른 방법은 없고(캐시를 안 갱신하면 **낡은 위치**를 읽는다), 스텝 직후
#       관측 지점에서는 전부 최신이라 실제로 0회다 — 게이트가 그 사실을 단언으로 지킨다
#       (test/smdp_observe_gate.jl, `_CACHE_TIMESTAMP_COUNTER` 검사).
#   (2) **파생 금지.** 여기서 새 값을 계산하지 않는다. 엔진이 이미 들고 있는 값을 옮길 뿐이다.
#       계산은 tplan.jl / rates.jl 의 몫이다.
#   (3) **`mode` 는 hazard 의 분류기를 재사용한다.** 여기서 다시 분류하면 두 레인의 λ 가 갈린다.
#
# 🔴 **계획서(task-4-brief.md Step 3)의 코드는 그대로 쓸 수 없다.** 갈린 지점과 근거는
# `.superpowers/sdd/2026-08-20-sojourn-generative-smdp/task-4-report.md` 에 전부 적혀 있다.
# 가장 큰 둘만 여기 남긴다(코드를 읽는 사람이 "왜 계획서와 다른가"를 여기서 알아야 하므로):
#
#   · `WEDGE_EDGES`·`DISSOLVED_GATES`·`RESTRICTION_ZONES` 는 전부 `Ref` 다
#     (replace_robot.jl:230·:235, ood_injection.jl:50). `[]` 없이 쓰면 `Ref` 자체를 담는다.
#   · `GeoBlock.poses` 는 **로봇 pose 가 아니라 빌드 기하**다. 계획서는 RobotNode 를 훑지만,
#     그러면 `RobotRec.pose` 와 **바이트 동일한 중복**이 되고 `poses` 의 자기 주석
#     (simstate.jl:80 "RelocateBuild 가 강체 Δ 를 건다")이 거짓이 된다. RelocateBuild 가 실제로
#     움직이는 것은 각 조립체의 `start_config` 변환트리 루트다(restage_zone.jl:610-624) —
#     그래서 여기서는 그것을 나른다. 안 그러면 **네 팔 중 RelocateBuild 하나가 `s` 에
#     아무 흔적도 안 남긴다.**
# =============================================================================

"""
    simstate_of(env) -> SimState

현재 `env`(+ 배터리·hazard·창고·배송 전역)에서 `s` 를 읽는다. **읽기 전용**.

sojourn 소비처가 알아야 할 것: 이 함수는 관측만 한다. `hazard_step!` 이 아직 한 번도 안 돈
로봇(창고에 주차된 예비 등)은 hazard 장부에 항목이 없는데, 그 자리를 채우려고
`_hz_ensure!` 를 부르면 안 된다(계약 (1)). 그런 로봇은 `usage_s = 0.0`(엔진이 넣을 값과
동일) · `eff = 1.0`(ε_r 분포의 평균, 아직 뽑히지 않았다는 뜻)로 읽는다.
"""
function simstate_of(env)
    sched, cache = env.sched, env.cache
    fleet_b = BATTERY_FLEET[]
    st      = HAZARD_STATE[]
    fleet_b === nothing && error("simstate_of: BATTERY_FLEET[] 가 비어 있다 — " *
                                 "enable_battery!(env) 를 먼저 부를 것 (soc·energy 의 유일한 진실원)")

    # --- G: 행동이 편집하는 그래프 부분 -----------------------------------------------
    edges = Set{Tuple{Int,Int}}()
    for e in Graphs.edges(sched)
        push!(edges, (Graphs.src(e), Graphs.dst(e)))
    end
    binding = Dict{Int,Int}()
    for v in Graphs.vertices(sched)
        rs = _responsible_robots(get_node(sched, v).node)
        isempty(rs) && continue
        # 🔴 계획서는 "`_responsible_robots` 가 정렬돼 있으니 첫 번째를 쓰면 된다"고 적었는데
        # **틀렸다**: 팀 노드에서는 `collect(keys(robot_team(node)))`(battery.jl:184-192)라
        # Dict 순회 순서 = 정의되지 않은 순서다. 여기서 정렬하지 않으면 같은 세계가 프로세스마다
        # 다른 해시를 얻는다(spec §3.5 규칙 4 가 막으려는 바로 그 실패).
        binding[v] = _int_key(first(sort(rs; by = string)))
    end
    g = GraphBlock(edges = edges, binding = binding,
                   wedge_edges     = Set{Tuple{Int,Int}}(WEDGE_EDGES[]),
                   dissolved_gates = Set{Tuple{Int,Int}}(DISSOLVED_GATES[]))

    # --- Geo: 빌드 기하 + zone. zone 은 **중심·반지름까지** 나른다 -----------------------
    zones = Dict{Symbol,NTuple{3,Float64}}()
    for (k, ball) in RESTRICTION_ZONES[]
        c = get_center(ball)     # hierarchical_geom_essentials.jl:88-89 의 접근자를 그대로 쓴다
        zones[k] = (Float64(c[1]), Float64(c[2]), Float64(get_radius(ball)))
    end
    geo = GeoBlock(poses = _build_poses(env), build_delta = _build_delta(), zones = zones)

    # --- Fleet: write-set 5 + sojourn read-set 3 --------------------------------------
    modes  = _hz_modes(env)                     # 계약 (3): hazard 의 분류기를 재사용
    sroles = _sched_roles(env)
    fleet  = Dict{Int,RobotRec}()
    for rid in sort!(collect(keys(fleet_b.soc)); by = string)
        k = _int_key(rid)
        # 폴백을 두지 않는다. 배터리 함대는 씬의 RobotNode 를 그대로 열거해 만들어지고
        # (battery.jl:122-130) 어떤 경로도 씬트리에서 로봇 노드를 지우지 않는다 — 그래서
        # 이 분기는 도달 불가여야 한다. `(0,0,0)` 으로 때우면 "원점에 있다" 와 "없다" 가
        # 한 값으로 합쳐진다.
        has_vertex(env.scene_tree, rid) ||
            error("simstate_of: 배터리 함대의 $(rid) 가 씬트리에 없다 — pose 를 지어내지 않는다")
        tr = global_transform(get_node(env.scene_tree, rid)).translation
        fleet[k] = RobotRec(
            pose    = (Float64(tr[1]), Float64(tr[2]), Float64(tr[3])),
            soc     = Float64(fleet_b.soc[rid]),   # rid 는 이 Dict 의 키다 — get 폴백 불필요
            health  = _health_of(rid, st),
            payload = _payload_of(env, rid),
            role    = _role_of(rid, sroles),
            usage_s = st === nothing ? 0.0 : Float64(get(st.usage_s, rid, 0.0)),
            mode    = get(modes, rid, :idle),
            eff     = st === nothing ? 1.0 : Float64(get(st.eff, rid, 1.0)),
        )
    end

    # --- Prog: 스케줄 진행 + 시계 ------------------------------------------------------
    active = Dict{Int,Float64}()
    for v in cache.active_set
        active[v] = Float64(get_t0(sched, v))
    end
    prog = ProgBlock(t = Float64(sim_time(env.dt)),
                     closed = Set{Int}(cache.closed_set),
                     active = active)

    return SimState(g = g, geo = geo, fleet = fleet, prog = prog,
                    courier = _courier_recs(env))
end

# =============================================================================
# 보조 함수 — 전부 읽기 전용
# =============================================================================

"""
    _int_key(id) -> Int

`AbstractID` 를 `s` 의 정수 키로. **`hash` 폴백을 두지 않는다** — 조용한 충돌은 서로 다른 두
로봇을 한 레코드로 합치고(그러면 `s` 가 거짓말을 한다), 그 사고는 에러 없이 성능으로만 샌다.
모양이 다르면 죽는 편이 낫다.
"""
function _int_key(id)
    hasproperty(id, :id) ||
        error("_int_key: $(typeof(id)) 에 `.id` 가 없다 — s 의 정수 키를 만들 수 없다 " *
              "(hash 폴백은 두지 않는다: 조용한 충돌보다 죽는 편이 낫다)")
    v = getproperty(id, :id)
    v isa Integer ||
        error("_int_key: $(typeof(id)).id 가 $(typeof(v)) 다(Integer 가 아니다) — 값: $(v)")
    return Int(v)
end

"""
    _build_poses(env) -> Dict{Int,NTuple{3,Float64}}

`GeoBlock.poses` = **빌드 기하**. 각 조립체의 `AssemblyComplete.start_config`(변환트리 루트)의
전역 위치를 조립체 id 로 키잉한다.

왜 이것인가: `RelocateBuild` 의 집행부 `_apply_uniform_translation!`(restage_zone.jl:610-624)이
움직이는 것이 정확히 이 노드들이다(`set_desired_global_transform!(start_config(ac), T ∘ …)`).
로봇 pose 를 담으면 `RobotRec.pose` 와 중복이 되고 RelocateBuild 는 `s` 에서 사라진다.

⚠️ 스케줄의 **모든** `AssemblyComplete` 를 훑는다. `_apply_uniform_translation!` 은
`env.staging_circles` 에 등재된 조립체만 옮기므로 여기 담기는 집합은 그 상위집합이다 —
빠뜨리는 쪽이 아니라 더 담는 쪽이라 관측이 눈멀지 않는다.
"""
function _build_poses(env)
    out = Dict{Int,NTuple{3,Float64}}()
    for v in Graphs.vertices(env.sched)
        n = get_node(env.sched, v).node
        matches_template(AssemblyComplete, n) || continue
        tr = global_transform(start_config(n)).translation
        out[_int_key(node_id(entity(n)))] = (Float64(tr[1]), Float64(tr[2]), Float64(tr[3]))
    end
    return out
end

"""
    _build_delta() -> NTuple{2,Float64}

🔴 **이 필드에는 출처가 없다.** HEAD 어디에도 "누적 build translation" 을 들고 있는 전역이나
env 필드가 없다 — `_apply_uniform_translation!`(restage_zone.jl:610-624)은 Δ 를 변환트리와
`env.staging_circles` 에 **적용만 하고 아무 데도 기록하지 않는다**. `translate_whole_build!`
이 돌려주는 `delta` 는 호출자(replan.jl:492)가 모니터 패널(`:log`)로 흘려보내고 버린다.
`STATE_GLOBALS`(state_globals.jl) 에도 이 축을 나르는 이름이 없다.

그래서 여기서는 **값을 지어내지 않고** 상수를 돌려준다. 이 필드는 지금 아무것도 못 가른다.

⚠️ **그래도 RelocateBuild 자체는 `s` 에서 안 보이지 않는다** — 그 편집의 *결과*를
`_build_poses` 가 나른다(빌드를 Δ 만큼 옮기면 조립체 pose 가 전부 Δ 만큼 움직인다).
즉 지금 없는 것은 "얼마나 옮겼는가의 **누적 스칼라**" 이지 "옮겼다는 사실" 이 아니다.
그러므로 선택지는 둘이고 **어느 쪽도 이 태스크가 혼자 정할 일이 아니다**:
  (a) 필드를 없앤다 (`_build_poses` 가 이미 그 정보를 나르므로 중복이다), 또는
  (b) `_apply_uniform_translation!` 에 누적기 전역(`const BUILD_DELTA = Ref((0.0,0.0))`)을
      달고 `STATE_GLOBALS` 에 `:state` 로 등록한다.
보고서의 "출처 없는 필드" 항목을 볼 것.
"""
_build_delta() = (0.0, 0.0)

"""
    _payload_of(env, rid) -> Union{Nothing,Int}

로봇이 지금 무엇에 **붙잡혀 있는가**. 씬트리에서 그 로봇의 부모 노드 id(= 그 로봇이 포획된
`TransportUnitNode`)를 그대로 옮긴다. free(루트)면 `nothing`.

`capture_robots!`(hierarchical_geom_essentials.jl:818-826)가 팀의 로봇들을 운반유닛의 자식으로
붙이고, `Replace` 경로가 그 부모 관계를 재스탬프한다 — 그래서 이 한 값이 "운반 중인가/무엇의
일부인가" 를 나른다. `get_parent`(graph_utils_essentials.jl:1112)는 부모 **꼭짓점 번호**를
돌려주고 부모가 없으면 `-1` 이다.
"""
function _payload_of(env, rid)
    p = get_parent(env.scene_tree, rid)
    has_vertex(env.scene_tree, p) || return nothing
    return _int_key(node_id(get_node(env.scene_tree, p)))
end

"""
    _sched_roles(env) -> Dict{Any,Symbol}

활성 스케줄 노드에서 "이 로봇이 지금 무엇을 하는 중인가" 를 읽는다. 분류를 새로 만들지 않고
`_responsible_robots`(battery.jl:184-192)의 **자기 분기 구조를 그대로 옮긴다**:

  `RobotGo`/`RobotStart`                              → `:transport`   (혼자 주행)
  `TransportUnitGo`/`FormTransportUnit`/`DepositCargo` → `:team_member` (운반팀 소속)

한 로봇이 둘 다에 걸리면 팀 소속이 이긴다(`_hz_modes` 가 무거운 모드를 채택하는 것과 같은 규약).
⚠️ `env.cache.active_set` 은 `Set` 이라 순회 순서가 정의돼 있지 않다(이 레포가 이미 데인 L5
결함). 그래서 승자 규칙을 **순서 무관**으로 짰다: `:team_member` 는 언제나 `:transport` 를
이기고, 같은 등급끼리는 결과가 같다. 정렬로 막는 게 아니라 **연산이 교환법칙을 만족하게** 막는다.
"""
function _sched_roles(env)
    out = Dict{Any,Symbol}()
    for v in env.cache.active_set
        node = get_node(env.sched, v).node
        r = (node isa RobotGo || node isa RobotStart) ? :transport :
            (node isa TransportUnitGo || node isa FormTransportUnit ||
             node isa DepositCargo)                   ? :team_member : nothing
        r === nothing && continue
        for id in _responsible_robots(node)
            (r === :team_member || !haskey(out, id)) && (out[id] = r)
        end
    end
    return out
end

"""
    _role_of(rid, sroles) -> Symbol

`:courier | :spare_parked | :team_member | :transport | :idle`.

우선순위가 중요하다. 배송 중인 예비는 **풀에 등록된 채로** 나가므로(battery_courier.jl 머리말,
`pop_spare!` 의 courier-aware 스캔이 그 전제 위에 있다) `is_spare` 가 여전히 true 다 — courier
검사를 먼저 하지 않으면 배송 중인 로봇이 `:spare_parked` 로 읽힌다.

⚠️ **어휘가 못 담는 것 둘**: `RECOVERY_SPARES`(고장 로봇의 일을 넘겨받은 예비)와
`CHECKED_OUT_SPARES`(창고 밖으로 반출된 본체)는 `RobotRec.role` 의 다섯 값 중 어디에도 안
들어간다. 태스크 3 이 못박은 어휘라 여기서 여섯째 값을 조용히 만들지 않는다 — 보고서에 적었다.
"""
function _role_of(rid, sroles)
    is_battery_courier(rid) && return :courier
    is_spare(rid)           && return :spare_parked
    return get(sroles, rid, :idle)
end

"""
    _health_of(rid, st) -> Symbol

`:healthy | :dead`. 고장은 **두 레인**에서 온다 — 주입(`FAULTED_ROBOTS`, ood_injection.jl:829)과
확률 과정(`HazardState.broken`, hazard.jl:140). 계획서는 뒤 하나만 봤는데, 실행 레인의 fault 는
대부분 앞 레인에서 나므로 그것만 보면 **주입된 고장이 `s` 에서 안 보인다.**

⚠️ `:degraded` 는 지금 **아무도 안 만든다**. 그 자리를 채울 만한 전역은 `STALLED_ROBOTS` 뿐인데
태스크 3 이 `stalled` 를 "soc 파생" 이라며 일부러 뺐다(simstate.jl:95). 여기서 되살리면 그
결정을 조용히 뒤집는 것이라 안 한다 — 보고서에 적었다.
"""
function _health_of(rid, st)
    haskey(FAULTED_ROBOTS[], rid) && return :dead
    st === nothing && return :healthy
    return (rid in st.broken) ? :dead : :healthy
end

"""
    _courier_recs(env) -> Vector{CourierRec}

`BATTERY_DELIVERIES`(battery_courier.jl:99, `Ref` 다)의 각 `BatteryDelivery` 를 `CourierRec` 로.

컨트롤러 판정 C-3 을 그대로 따른다:
  · id 는 `_int_key`
  · 좌표 `Vector{Float64}` → `(v[1], v[2])`
  · 시각 `step < 0 ? -1.0 : dt * step`

시각 변환의 근거는 `sim_time(dt) = dt * SIM_STEP[]`(asset_ledger.jl:108) 하나뿐이고, 배송의
`step_out`/`step_swap` 은 `_current_sim_step()` 이 그대로 찍은 절대 스텝이다
(battery_courier.jl:179·:238). `-1` 은 "아직 안 바뀜" 센티넬이라(:179) 그대로 `-1.0` 로 남긴다 —
`dt * (-1)` 로 접으면 dt 에 따라 값이 흔들리고, `0.0` 으로 접으면 **실재하는 절대시각 0.0**
과 구별이 안 된다.

정렬은 하지 않는다 — `canonical(::SimState)` 가 `by = canonical` 로 다시 정렬한다
(simstate.jl `_canonical_blocks`, I-2).
"""
function _courier_recs(env)
    dt = Float64(env.dt)
    _t(step::Integer) = step < 0 ? -1.0 : dt * step
    out = CourierRec[]
    for d in values(BATTERY_DELIVERIES[])
        push!(out, CourierRec(
            target  = _int_key(d.target),
            courier = _int_key(d.courier),
            depot   = d.depot,
            home    = (Float64(d.home[1]), Float64(d.home[2])),
            goal    = (Float64(d.goal[1]), Float64(d.goal[2])),
            phase   = d.phase,
            t_out   = _t(d.step_out),
            t_swap  = _t(d.step_swap)))
    end
    return out
end
