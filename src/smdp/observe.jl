# =============================================================================
# observe.jl — env → s 의 **유일한** 경로 (spec §6 C2, 게이트 N-G0′)
#
# 계약. 어기면 관측이 조용히 틀린다:
#   (1) **읽기 전용 — 정확히는 `s` 와 세계의 동역학에 관찰 가능한 변화를 주지 않는다.**
#       관측이 세계를 바꾸면 같은 상태를 두 번 관측한 것만으로 갈래가 갈린다.
#       🔴 이 계약은 "대입을 안 한다" 보다 넓다 — **지연 초기화 헬퍼를 부르는 것도 수정이다.**
#       구체적으로 `_hz_ensure!`(hazard.jl:292)를 부르면 안 된다: 그 함수는 Dict 를 채울 뿐
#       아니라 그 로봇 전용 스트림에서 난수를 셋 태운다. 그래서 미등록 로봇은 `usage_s` 를
#       **지어내지 않고** `error()` 로 죽는다(아래 함수 본문) — `enable_hazard!` 가 이미 모든
#       배터리 함대 로봇을 등록해 두므로, 정상 경로에서는 도달하지 않는다.
#
#       ⚠️ **정확히 하나, 의도적으로 남긴 부작용이 있다.** `global_transform`(hierarchical_geom_essentials.jl:347)
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
# =============================================================================

"""
    simstate_of(env) -> SimState

현재 `env`(+ 배터리·hazard 전역)에서 `s` 를 읽는다. **읽기 전용.**

계약(어기면 관측이 조용히 틀린다):
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
    # 🔴 2026-09-02 (판정 1). 이 루프는 `assignment_binding`(`src/respec/common_resolve.jl`)
    #    으로 뽑혔다 — 공통 재풀이의 `n_reassigned` 가 **같은 함수**를 부른다. 배정을 읽는
    #    두 번째 구현을 만들지 않기 위해서다(그 규칙은 원래 재풀이 docstring 이 적어 뒀다).
    binding = assignment_binding(sched)
    g = GraphBlock(edges = edges, binding = binding)

    # --- Geo: 조립체 기하 + zone(중심·반지름까지) --------------------------------------
    #
    # 🔴 **poses 의 출처는 `AssemblyComplete.start_config` 다 — 씬트리가 아니다.** 조립체를
    # 옮기는 집행부 `_apply_uniform_translation!`(restage_zone.jl:610-624)이 무조건 쓰는 값이
    # `start_config` 이기 때문이다. 씬트리 쪽은 `_resync_scene_drift!`(restage_zone.jl:157-176)가
    # free(미포획) 노드에 한해, 드리프트가 `tol`(기본 `default_robot_radius()`)보다 클 때만
    # 되튕긴다. 실측: `Δ = 0.2·tol` 을 씬트리 출처로 적용하면 `state_hash` 가 **한 글자도 안
    # 바뀐다**(`h_small == h0`) — `tol` 미만의 평행이동이 `s` 에서 사라져 `NOOP` 과 구분
    # 불가능해질 뻔했다(`SwapBattery`/`NOOP` 트립와이어와 같은 부류의 사고). 아래 게이트의
    # 해당 testset 이 이 실측을 영구 트립와이어로 남긴다.
    #
    # ⚠️ **스케줄의 모든 `AssemblyComplete` 를 훑는다**:
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

# 🔴 2026-09-02 (판정 1). `_int_key` 는 여기 있었고 **`src/respec/common_resolve.jl`(CB 본체)로
#    옮겼다** — `assignment_binding` 이 부르는데 이 파일은 런타임 include 라서다. 이 파일의
#    나머지 호출자는 같은 모듈이라 그대로 돈다.
