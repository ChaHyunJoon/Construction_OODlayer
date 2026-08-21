# =============================================================================
# observe.jl — env → s 의 **유일한** 경로 (spec §6 C2, 게이트 N-G0′)
#
# 2026-08-21 축소(Task R1)로 `SimState` 가 26 → **7 필드**(로봇당 8 → 2)가 됐다. 이 파일은
# Task R2 에서 그 축소를 따라잡는다 — `_role_of`·`_sched_roles`·`_payload_of`·`_courier_recs`·
# `_build_delta`(그리고 이제 호출자가 없어진 `_build_poses`·`_health_of`)는 전부 삭제됐다.
# `_int_key` 만 그대로 남는다.
#
# 계약 셋. 어기면 롤아웃이 조용히 틀린다:
#   (1) **읽기 전용 — 정확히는 `s` 와 세계의 동역학에 관찰 가능한 변화를 주지 않는다.**
#       관측이 세계를 바꾸면 같은 상태를 두 번 관측한 것만으로 갈래가 갈린다.
#       🔴 이 계약은 "대입을 안 한다" 보다 넓다 — **지연 초기화 헬퍼를 부르는 것도 수정이다.**
#       구체적으로 `_hz_ensure!`(hazard.jl:292)를 부르면 안 된다: 그 함수는 Dict 를 채울 뿐
#       아니라 그 로봇 전용 스트림에서 난수를 셋 태운다. 그래서 미등록 로봇은 `usage_s` 를
#       **지어내지 않고** `error()` 로 죽는다(아래 함수 본문) — `enable_hazard!` 가 이미 모든
#       배터리 함대 로봇을 등록해 두므로, 정상 경로에서는 도달하지 않는다.
#
#       ⚠️ **정확히 하나, 의도적으로 남긴 부작용이 있다 (컨트롤러 판정, base 부터 그대로 —
#       R2 가 새로 만든 것이 아니다).** `global_transform`(hierarchical_geom_essentials.jl:347)
#       = `get_cached_value!` 이고, 캐시가 **낡아 있으면** `propagate_forward!` 로 재계산하면서
#       `_next_cache_timestamp()`(graph_utils_essentials.jl:143-147)가 프로세스 전역
#       `_CACHE_TIMESTAMP_COUNTER` 를 올린다. 그 카운터는 **ξ** 다(simstate.jl `ReplayState.
#       cache_counter`) — `s` 가 아니다. 대안(갱신을 건너뛰기)은 더 나쁘다: `s` 에 낡은 pose 라는
#       **틀린 값**이 들어간다. 게이트는 "스텝 직후 관측 지점에서 0회" 라는 좁은 사실만
#       단언한다(`test/smdp_observe_gate.jl` "simstate_of 는 읽기 전용이다").
#   (2) **새 동역학을 만들지 않는다.** 계산은 tplan.jl / rates.jl 의 몫이다. 실제로 파생하는
#       것은 둘뿐이다:
#         · `g.binding[v]` = `first(sort(rs; by = string))` — 담당 로봇이 여럿인 정점에서
#           하나로 줄이는 축약. 정렬 없이는 Dict/Set 순회 순서가 해시로 샌다(P2).
#         · `geo.zones`    = `Ball2` → `(cx, cy, r)` 튜플 (표현 변환).
#       기준은 "계산이 0 인가" 가 아니라 **"엔진이 이미 정한 사실 말고 새 사실을 지어내는가"** 다.
#   (3) 🔴 **`fleet` 멤버십은 `_hz_excluded()` 를 직접 부른다.** 여기서 role·health 로
#       다시 유도하면 두 레인이 서로 다른 집합 위에서 위험을 적분한다(spec §2-4, 완료 보고서
#       §4-2 가 반례 둘을 실측했다). `_hz_excluded()` = 주차 예비 ∪ 반출 예비 ∪ 고장(주입 레인).
#
# 🔴 **Task R2 진행 중 실측한, 계획서 브리프와의 불일치(전부 실제 이름을 확인하고 그대로 씀)**:
#   이름은 전부 일치한다 — `CHECKED_OUT_SPARES` · `_hz_excluded` · `RESTRICTION_ZONES` ·
#   `LazySets.Ball2` 의 `center`/`radius` 필드 · `_responsible_robots` · `global_transform` ·
#   `node_id` · `get_nodes` (grep 으로 실측 확인, task-R2-report.md 참조). **딱 하나, 이름이 아니라
#   출처가 틀렸다 — 그리고 그 오류는 브리프 안에서만 있었다, 이 파일(base 부터 커밋된 코드)에는
#   없었다.** 브리프는 `poses` 를 `get_nodes(env.scene_tree)` + `matches_template(AssemblyNode,·)`
#   로 읽으라고 적었다. **base(`b578cd3c`)의 `simstate_of` 는 이미 `_build_poses(env)` 를 통해
#   `AssemblyComplete.start_config` 를 읽고 있었다** — 씬트리 출처는 브리프의 스니펫과 이 태스크의
#   진행 중이던 초안에만 있었지, 커밋된 코드에 있던 적이 없다. 독립 검증자가 지적하고 이 파일이
#   실측으로 확인한 바 `_apply_uniform_translation!`(restage_zone.jl:610-624, RelocateBuild 의
#   실제 집행부)이 무조건 쓰는 값은 씬트리가 아니라 `AssemblyComplete.start_config` 다 — 씬트리
#   쪽은 드리프트가 `default_robot_radius()` 미만이면 `_resync_scene_drift!` 가 아예 안 건드린다
#   (실측: `Δ=0.2·tol` 적용 후 `state_hash` 불변). 그래서 최종 구현은 브리프가 아니라 base 와
#   같은 출처(`start_config`)를 쓴다 — **찾은 것은 계획서의 오류이지 코드의 퇴행이 아니다.**
#   아래 게이트의 "geo.poses 가 RelocateBuild 의 실제 집행부를 관측하는가" testset이 이 실측을
#   영구 트립와이어로 남긴다.
# =============================================================================

"""
    simstate_of(env) -> SimState

현재 `env`(+ 배터리·hazard 전역)에서 `s` 를 읽는다. **읽기 전용.**

계약 셋(어기면 롤아웃이 조용히 틀린다):
  (1) env·전역을 하나도 수정하지 않는다 — **단, `global_transform` 의 캐시 재계산이 `ξ`
      (`_CACHE_TIMESTAMP_COUNTER`)를 올리는 것은 의도적으로 남긴 유일한 예외다**(파일 머리
      코멘트, base 부터 그대로).
  (2) 새 값을 계산하지 않는다 — 엔진이 이미 들고 있는 값을 옮길 뿐이다.
  (3) 🔴 **`fleet` 멤버십은 `_hz_excluded()` 를 직접 부른다.** 여기서 role·health 로 다시
      유도하면 두 레인이 서로 다른 집합 위에서 위험을 적분한다(spec §2-4, 완료 보고서 §4-2 가
      반례 둘을 실측했다).
"""
function simstate_of(env)
    sched, cache = env.sched, env.cache
    fleet_b = BATTERY_FLEET[]
    fleet_b === nothing && error("simstate_of: BATTERY_FLEET[] 가 비어 있다 — " *
                                 "enable_battery!(env) 를 먼저 부를 것")
    st = HAZARD_STATE[]
    st === nothing && error("simstate_of: HAZARD_STATE[] 가 비어 있다 — " *
                            "enable_hazard!(env) 없이는 usage_s 가 전부 0 이라 λ 가 평평해진다 " *
                            "(이슈 E). 조용히 0 을 채우지 않는다")

    # --- G ---------------------------------------------------------------------------
    edges = Set{Tuple{Int,Int}}()
    for e in Graphs.edges(sched)
        push!(edges, (Graphs.src(e), Graphs.dst(e)))
    end
    binding = Dict{Int,Int}()
    for v in Graphs.vertices(sched)
        # 🔴 리뷰 라운드 1 이 잡은 결함: 옛 초안은 여기를 `try ... catch; () end` 로 감쌌다(브리프
        # verbatim). `_responsible_robots`(battery.jl:184-192)는 else 분기에서 항상 `Any[]` 를
        # 반환하고 **절대 던지지 않는다** — 그래서 그 catch 는 죽은 방어 코드가 아니라 "조용한
        # 폴백 금지" 원칙 위반이었다: 어느 날 새 노드 타입이 추가돼 이 호출이 정말로 던지면, 그
        # 정점이 `binding` 에서 **조용히** 빠진다(이 루프는 `binding` 에 들어간 것만 보므로 그
        # 누락은 어디서도 안 보인다). base 는 이 호출을 그대로 bare 로 뒀다 — 그 형태로 되돌린다.
        rs = _responsible_robots(get_node(sched, v).node)
        isempty(rs) && continue
        # ⚠️ `_responsible_robots` 는 **정렬돼 있지 않다**(Dict 순회 순서 — 선행 계획의 오류 P2).
        # 정렬 첫째를 쓴다. 안 하면 같은 세계가 프로세스마다 다른 binding 을 얻는다.
        binding[v] = _int_key(first(sort!(collect(rs); by = string)))
    end
    g = GraphBlock(edges = edges, binding = binding)

    # --- Geo: 조립체 기하 + zone(중심·반지름까지) --------------------------------------
    #
    # 🔴 **poses 의 출처는 `AssemblyComplete.start_config` 다 — base(`b578cd3c`, 옛 `_build_poses`)
    # 부터 그대로이고, 이 태스크가 바꾼 것이 아니다.** 계획서 브리프의 스니펫은 이것 대신
    # `get_nodes(env.scene_tree)` + `matches_template(AssemblyNode,·)` + `global_transform(n)` 을
    # 시켰는데(**브리프의 오류**, 이 태스크의 진행 중이던 초안에만 잠깐 있었고 커밋된 적은 없다),
    # 독립 검증자가 지적하고 실측으로 확인한 바 `RelocateBuild` 의 실제 집행부
    # `_apply_uniform_translation!`(restage_zone.jl:610-624)이 무조건 옮기는 값은 `start_config`
    # 이지 씬트리가 아니다 — 씬트리 쪽은 `_resync_scene_drift!`(restage_zone.jl:157-176)가
    # free(미포획) 노드에 한해, 드리프트가 `tol`(기본 `default_robot_radius()`)보다 클 때만
    # 되튕긴다. 실측: `Δ = 0.2·tol` 을 씬트리 출처로 적용하면 `state_hash` 가 **한 글자도 안
    # 바뀐다**(`h_small == h0`, 아래 게이트의 "geo.poses 가 RelocateBuild 의 실제 집행부를
    # 관측하는가" testset이 이 실측을 영구 트립와이어로 남긴다) — `tol` 미만의 RelocateBuild 가
    # `s` 에서 사라져 `NOOP` 과 구분 불가능해질 뻔했다(`SwapBattery`/`NOOP` 트립와이어와 같은
    # 부류의 사고).
    #
    # ⚠️ **스케줄의 모든 `AssemblyComplete` 를 훑는다**(옛 `_build_poses` docstring 그대로 옮김):
    # `_apply_uniform_translation!` 은 `env.staging_circles` 에 등재된 조립체만 옮기므로 여기
    # 담기는 집합은 그 상위집합이다 — 빠뜨리는 쪽이 아니라 더 담는 쪽이라 관측이 눈멀지 않는다.
    poses = Dict{Int,NTuple{3,Float64}}()
    for v in Graphs.vertices(sched)
        n = get_node(sched, v).node
        matches_template(AssemblyComplete, n) || continue
        tr = global_transform(start_config(n)).translation
        poses[_int_key(node_id(entity(n)))] = (Float64(tr[1]), Float64(tr[2]), Float64(tr[3]))
    end
    zones = Dict{Symbol,NTuple{3,Float64}}()
    for (k, ball) in RESTRICTION_ZONES[]
        zones[k] = (Float64(ball.center[1]), Float64(ball.center[2]), Float64(ball.radius))
    end
    geo = GeoBlock(poses = poses, zones = zones)

    # --- Fleet: 멤버십 = 위험에 노출된 로봇, 레코드는 두 필드 --------------------------
    excluded = _hz_excluded()
    fleet = Dict{Int,RobotRec}()
    for rid in sort!(collect(keys(fleet_b.soc)); by = string)
        rid in excluded && continue
        haskey(st.usage_s, rid) ||
            error("simstate_of: $(rid) 가 hazard 상태에 없다 — usage_s 를 지어내지 않는다")
        fleet[_int_key(rid)] = RobotRec(soc     = Float64(fleet_b.soc[rid]),
                                        usage_s = Float64(st.usage_s[rid]))
    end

    return SimState(g = g, geo = geo, fleet = fleet,
                    prog = ProgBlock(closed = Set{Int}(collect(cache.closed_set))))
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
