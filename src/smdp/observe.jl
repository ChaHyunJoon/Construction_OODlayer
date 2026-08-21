# =============================================================================
# observe.jl — env → s 의 **유일한** 경로 (spec §6 C2, 게이트 N-G0)
#
# 계약 셋. 어기면 롤아웃이 조용히 틀린다:
#   (1) **읽기 전용 — 정확히는 `s` 와 세계의 동역학에 관찰 가능한 변화를 주지 않는다.**
#       관측이 세계를 바꾸면 같은 상태를 두 번 관측한 것만으로 갈래가 갈린다.
#       🔴 이 계약은 "대입을 안 한다" 보다 넓다 — **지연 초기화 헬퍼를 부르는 것도 수정이다.**
#       구체적으로 `_hz_ensure!`(hazard.jl:292)를 부르면 안 된다: 그 함수는 Dict 를 채울 뿐
#       아니라 그 로봇 전용 스트림에서 난수를 **셋** 태운다(`_lognorm1` 의 `randn` 1 +
#       `_exp1` 2). 관측 한 번이 CRN 을 민다.
#
#       ⚠️ **정확히 하나, 의도적으로 남긴 부작용이 있다 (컨트롤러 판정).**
#       `global_transform`(hierarchical_geom_essentials.jl:347) = `get_cached_value!` 이고,
#       캐시가 **낡아 있으면** `propagate_forward!` 로 재계산하면서
#       `_next_cache_timestamp()`(graph_utils_essentials.jl:143-147)가 프로세스 전역
#       `_CACHE_TIMESTAMP_COUNTER` 를 올린다.
#         · 그 카운터는 **ξ** 다(simstate.jl `ReplayState.cache_counter`) — `s` 가 아니다.
#           어떤 시드에도, 어떤 정렬 키에도 안 쓰인다. 변하는 것은 캐시 신선도 비교뿐이다.
#         · 대안(갱신을 건너뛰기)은 **더 나쁘다**: `s` 에 낡은 pose 라는 **틀린 값**이 들어간다.
#         · 🔴 "실제로 0회" 라고 쓰면 **틀린 진술**이다. 그것은 스텝 직후처럼 캐시가 이미 전부
#           최신인 관측 지점의 실측일 뿐이다. 캐시가 낡은 지점에서는 실제로 오른다 — 이 파일의
#           게이트 시험 자신이 `set_desired_global_transform!` 로 캐시를 무효화한 직후
#           `state_hash(simstate_of(env))` 를 부르는 것이 바로 그 경우다.
#         · **Task 12 가 `apply_action!` 직후에 `simstate_of` 를 부른다** — 캐시가 가장 낡아
#           있을 자리다. 거기서 카운터가 오르는 것은 결함이 아니라 이 판정의 적용이다.
#       게이트는 "스텝 직후 관측 지점에서 0회" 라는 **좁은** 사실만 단언한다.
#   (2) **새 동역학을 만들지 않는다.** 계산은 tplan.jl / rates.jl 의 몫이다.
#       🔴 **2026-08-20 최종 리뷰 I4 로 문구를 정정했다.** 예전 문구는 "파생 금지 — 여기서 새
#       값을 계산하지 않는다" 였는데 **이 파일 자신이 그 문장을 지키지 않는다.** 실제로 파생하는
#       것을 전부 이름으로 적는다(빠짐없이 적는 것이 이 계약의 전부다):
#         · `prog.t`        = `sim_time(env.dt)`         — 스텝 인덱스 → 절대 sim 초 (단위 변환)
#         · `courier.t_out`/`t_swap` = `dt * step_*`     — 같은 변환. `-1` 센티넬은 보존한다(C-3)
#         · `g.binding[v]`  = `first(sort(rs; by = string))` — 담당 로봇이 여럿인 정점에서
#           **하나로 줄이는 축약**. 정렬 없이는 `active_set` 의 Set 순서가 해시로 샌다(P2)
#         · `fleet.role`    = `_role_of` 의 우선순위 규칙 + `_sched_roles` 의 분류 (아래 (3))
#         · `geo.zones`     = `Ball2` → `(cx, cy, r)` 튜플 (표현 변환)
#       기준은 "계산이 0 인가" 가 아니라 **"엔진이 이미 정한 사실 말고 새 사실을 지어내는가"** 다.
#       위 다섯은 전부 단위 변환·전순서 축약이고 새 사실이 아니다. 지어낼 뻔한 자리에서는
#       실제로 멈춰 섰다 — 미등록 로봇의 `usage_s`/`eff`, 씬트리에 없는 로봇의 pose(에러로 죽는다),
#       `prog.active` 의 "실제 시작 시각"(계획값을 그대로 나르고 결함으로 못 박았다).
#   (3) **`mode` 는 hazard 의 분류기를 재사용한다**(`_hz_modes`). 여기서 다시 분류하면 두 레인의
#       λ 가 갈린다.
#       ⚠️ **`role` 은 그 재사용이 안 된다 — 이 계약은 `mode` 에만 걸린다**(2026-08-20 리뷰 I4).
#       `_sched_roles`(아래)는 담당 로봇을 `_responsible_robots` 에서 받지만 **태그**
#       (`:transport` / `:team_member`)는 자기 분기 목록으로 정한다. 유일한 공유 분류기인
#       `_node_mode` 는 **경계가 다른 축**(전력 모드)이라 그대로 못 쓴다 — 실측으로 확인한 두 지점:
#         · `RobotStart` → `_node_mode` 는 `IDLE`, `_sched_roles` 는 `:transport`.
#           스케줄에 **14개** 있다(colored_8x8). `_node_mode` 에서 태그를 받으면 그 로봇들의
#           `role` 이 `:transport` → `:idle` 로 **바뀐다** = 동작 변경이다.
#         · `LiftIntoPlace` → `_node_mode` 는 `MANIPULATE` 인데 `_responsible_robots` 에는
#           분기가 없어 `Any[]` 다(스케줄에 **33개**). 그래서 들어올리는 중인 로봇은
#           `mode` 도 `role` 도 `:idle` 로 읽힌다 — **`_node_mode` 와 `_responsible_robots`
#           사이의 드리프트**이지 이 파일이 만든 것이 아니다.
#       그래서 코드를 바꾸는 대신 **분기 목록이 서로 어긋나면 빨개지는 시험**을 뒀다:
#       `test/smdp_observe_gate.jl` 의 "계약 (3) — role 분기 목록" testset 이 스케줄 342 정점
#       전부에서 `_sched_roles` 의 태그 술어와 `_responsible_robots` 의 비어있음 여부가
#       일치하는지 보고, 위 `LiftIntoPlace` 드리프트를 실측값으로 못 박는다.
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
    # ⚠️ 이 `sort!` 는 **결정성 보장이 아니다**(2026-08-20 최종 리뷰 Minor). 결과가 `Dict` 라
    # 삽입 순서는 어차피 안 남고, 직렬화 시점에 `simstate.jl` 의 `_c(::AbstractDict)` 가 다시
    # 정렬한다. 여기서는 순회를 읽기 좋게 고정할 뿐이니 **이 줄을 결정성 근거로 인용하지 말 것.**
    for rid in sort!(collect(keys(fleet_b.soc)); by = string)
        k = _int_key(rid)
        # 폴백을 두지 않는다. 배터리 함대는 씬의 RobotNode 를 그대로 열거해 만들어지고
        # (battery.jl:124-132) 어떤 경로도 씬트리에서 로봇 노드를 지우지 않는다 — 그래서
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
    #
    # 🔴 **알려진 결함 — `active` 의 값은 `simstate.jl:105`/spec §3-2 가 약속한 "그 정점이
    # **실제로 시작한** 시각" 이 아니라 계획된 시작이다.** 지어낼 수 없어서 그대로 나른다.
    #
    #   근거 1. `get_t0` 를 쓰는 유일한 실행 경로는 `process_schedule!` → `update_schedule_times!`
    #     (essential_tg_coponents.jl:372)이고, 그 갱신은 `Δt = t - get_tF(sched,v) > 0` 일 때만
    #     일어난다. 그런데 레포의 **모든 호출자가 `t = 0.0` 을 넘긴다** — demo_utils.jl:80·158 ·
    #     route_planning.jl:273 · tools/monitor/run_demo.jl:483·795·815 · render_demo.jl:597.
    #     즉 `t0` 는 MILP/구조적 계획값에서 런 도중 **움직이지 않는다**.
    #   근거 2. 실행 중 "실제로 언제 활성이 됐나" 를 적는 곳은 `MONITOR_NODE_T`(monitor.jl:220)
    #     하나뿐인데, 그것은 `STATE_GLOBALS` 에서 **`:log`** 이고(state_globals.jl:318)
    #     `MONITOR_IO[] === nothing`(= 모니터 꺼짐, 기본값)이면 한 줄도 안 채워진다.
    #     `:log` 를 `s` 의 출처로 삼는 것은 spec §3.6 이 금지한다.
    #   실측(step 120): 활성 10개 중 8개가 `t0 = 0.0`·계획 소요시간 `0.0` 인데 경과 3.0초 —
    #     실제 시작이라면 불가능한 값이다.
    #
    # ⚠️ **아래로 새는 곳**: Task 8 의 `T_plan_next` 가 `잔여 = ρ·duration − (t − t0)` 를 이
    # 값 위에 세우면 잔여가 상시 ≤ 0 이 되어 `eps` 클램프만 돌려준다. 그 수정은 이 태스크 밖이다.
    # 게이트(`test/smdp_observe_gate.jl`, "prog.active 는 계획된 시작" testset)가 이 사실을
    # 단언으로 못 박아 두었다 — 누가 진짜 출처를 배선하면 그 단언이 먼저 빨개진다.
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
    # 🔴 `Bool <: Integer` **다**. `v isa Integer` 만 보면 `.id === true` 인 id 가 통과해 `1` 이
    # 되고 `RobotID(1)` 과 **조용히 충돌한다** — 이 함수가 막으라고 존재하는 바로 그 사고가
    # 이 함수 안에서 일어난다(리뷰 라운드 2 실측: `_int_key((id=true,)) == _int_key(RobotID(1))`).
    # 오늘의 id 타입 중 `Bool` 페이로드는 없지만, 이 가드의 존재 이유는 **아무도 예상 못 한
    # id 모양**을 잡는 것이다 — 그 역할에 구멍이 있으면 가드가 아니다.
    v isa Bool &&
        error("_int_key: $(typeof(id)).id 가 Bool 이다(값: $(v)) — Julia 에서 `Bool <: Integer` 라 " *
              "`Int(true) == 1` 이 되어 RobotID(1) 과 조용히 충돌한다. 정수 키로 받지 않는다")
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

⚠️ `_int_key` 는 **id 의 타입 태그를 지운다** — `TransportUnitID(3)` 과 `AssemblyID(3)` 은 둘 다
`3` 이 된다. 로봇의 부모는 실측상 항상 `TransportUnitNode` 라 오늘은 충돌하지 않지만, `s` 는
이 값을 벌거벗은 `Int` 로 들고 있으므로 **소비처가 타입을 되살릴 수 없다**(Task 9 의 역변환이
그 자리에서 막힌다). 타입을 살리려면 `payload` 를 `Union{Nothing,Int}` 가 아닌 모양으로 바꿔야
하는데 그것은 태스크 3 의 타입 결정이다 — 여기서 조용히 바꾸지 않고 적어 둔다.
"""
function _payload_of(env, rid)
    p = get_parent(env.scene_tree, rid)
    has_vertex(env.scene_tree, p) || return nothing
    return _int_key(node_id(get_node(env.scene_tree, p)))
end

"""
    _sched_roles(env) -> Dict{Any,Symbol}

활성 스케줄 노드에서 "이 로봇이 지금 무엇을 하는 중인가" 를 읽는다. **담당 로봇은
`_responsible_robots`(battery.jl:184-192)에서 받고**(그 목록을 손으로 복제하지 않는다),
태그만 그 함수의 **분기 구조와 같은 모양으로** 정한다:

  `RobotGo`/`RobotStart`                              → `:transport`   (혼자 주행)
  `TransportUnitGo`/`FormTransportUnit`/`DepositCargo` → `:team_member` (운반팀 소속)

한 로봇이 둘 다에 걸리면 팀 소속이 이긴다(`_hz_modes` 가 무거운 모드를 채택하는 것과 같은 규약).

🔴 **왜 `_node_mode` 에서 태그를 유도하지 않는가** (2026-08-20 리뷰 I4, 실측 후 판정).
`_node_mode` 는 **전력 모드** 분류기라 경계가 다르다: `RobotStart → IDLE`(여기서는 `:transport`,
스케줄에 14개) · `LiftIntoPlace → MANIPULATE`(여기서는 태그 없음, 33개). 그래서 거기서 태그를
받으면 RobotStart 위의 로봇 `role` 이 `:transport` → `:idle` 로 **바뀐다**. 게이트 픽스처
(step 120)의 active_set 은 `RobotGo`·`TransportUnitGo` 뿐이라 그 자리에서는 두 구현이 같은 값을
내지만(실측: role 차이 0/14), 그 등호는 **분기가 안 걸린 도메인의 등호**라 근거로 못 쓴다.
대신 여기 분기 목록이 `_responsible_robots` 와 어긋나면 빨개지는 시험을 뒀다 —
`test/smdp_observe_gate.jl` 의 "계약 (3) — role 분기 목록" (스케줄 342 정점 전수, 실측 불일치 0).
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
`pop_spare!` 의 courier-aware 스캔(ood_injection.jl:394)이 그 전제 위에 있다) `is_spare` 가 여전히 true 다 — courier
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
확률 과정(`HazardState.broken`, hazard.jl:141). 계획서는 뒤 하나만 봤는데, 실행 레인의 fault 는
대부분 앞 레인에서 나므로 그것만 보면 **주입된 고장이 `s` 에서 안 보인다.**

⚠️ `:degraded` 는 지금 **아무도 안 만든다**. 그 자리를 채울 만한 전역은 `STALLED_ROBOTS` 뿐인데
태스크 3 이 `stalled` 를 "soc 파생" 이라며 일부러 뺐다(simstate.jl:92). 여기서 되살리면 그
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
