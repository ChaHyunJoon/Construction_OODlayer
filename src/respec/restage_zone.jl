# =============================================================================
# restage_zone.jl  --  ForbidZone enactment: relocate a staging-blocked assembly.
#
# OOD 1-2 (restriction district) recovery. When a no-go zone overlaps an
# assembly's STAGING AREA, that assembly can no longer be built/staged there
# (its parts' delivery goals fall inside a region robots must not enter), so the
# build deadlocks. This is the LLM-free geometric core that RECOVERS: it relocates
# the assembly's staging area clear of the zone.
#
# Why this is NOT a MILP re-spec (unlike ForbidAgent/Precede/...): a no-go zone is
# a SPATIAL constraint, not a timing/assignment one. The fix is geometric surgery,
# dispatched specially in maybe_respecify! (like fault_robot_and_reassign!), and
# needs NO solver call — assignment (Xa) and the schedule structure are unchanged;
# only WHERE the assembly is staged moves.
#
# KEY SIMPLIFICATION (verified against the staging planner): an assembly's parts
# are arranged RELATIVE to its origin, so a RIGID TRANSLATION of the assembly's
# `start_config` moves the whole staging subtree (every part-delivery goal_config,
# deposit config, ...) coherently via the transform tree's parent-child chain. So
# we do NOT re-run the ring-packing solver; we only search for a new CENTER for the
# assembly's staging circle (radius known) that clears the zone and overlaps no
# other staging circle. Runtime goals read `goal_config(node)` (route_planning.jl),
# which follows the rigid move.
#
# ── 한국어 요약 ───────────────────────────────────────────────────────────────
#  이 파일이 하는 일: OOD 1-2("진입 금지 구역"이 조립체의 적치영역(staging area)을
#  덮어 빌드가 막힘)를 기하학적으로 복구한다. LLM 이나 MILP 솔버를 부르지 않고,
#  막힌 조립체의 적치영역을 구역 밖으로 "통째로 평행이동(rigid translation)"시켜서 푼다.
#  프로젝트 안에서의 역할: respec(재명세) 레이어의 ForbidZone 처리 담당 — 시간/배정
#  제약이 아니라 "공간" 제약이라, 스케줄 구조·배정(Xa)은 그대로 두고 "어디에 두느냐"만 옮긴다.
#  핵심 착상: 부품들은 조립체 원점 기준 상대배치라, 조립체 start_config 하나만 옮기면
#  변환트리(부모-자식 사슬)를 따라 모든 부품 목표점이 함께 일관되게 이동한다(재계산 불필요).
#
#  Julia 문법 참고(처음 보는 사람용):
#   · function f(a, b; kw=기본값) ... end : 세미콜론(;) 뒤는 "키워드 인자"(이름으로 넘김).
#   · `x::T` : 인자 x 가 타입 T 일 때만 이 메서드 적용(다중 디스패치 — 파이썬엔 없는 개념).
#   · `!` 로 끝나는 함수 = 인자를 직접 수정(in-place)한다는 관례(예: restage_assembly!).
#   · `:심볼` : `:restaged` 처럼 콜론으로 시작하면 Symbol(가벼운 상수 이름표).
#   · `Ref` 의 `[]` : RESTRICTION_ZONES[] 는 참조상자를 역참조해 안의 실제 딕셔너리를 꺼냄.
#   · `.` (broadcast) : `.-`, `.+` 처럼 점이 붙으면 원소별(좌표별) 연산.
#   · `∘` : 함수 합성(수학의 f∘g) — 여기선 평행이동 변환을 기존 변환에 합성할 때 씀.
# =============================================================================

"""
    find_clear_staging_center(env, assembly_id, R; zone_keys, margin, ...) -> center | nothing

Search for a new 2D center for a radius-`R` staging circle that is clear of every
active restriction zone in `zone_keys` AND every OTHER assembly's staging circle
(each by radius-sum + `margin`). Concentric rings of increasing radius around the
current center are scanned, so the FIRST hit is the closest valid relocation
(minimal disruption). Returns `nothing` if none is found within `max_rings`
(⟹ infeasible ⟹ caller engages the safe fallback). This is the ring solver's
"place a circle without overlap" idea reduced to a single circle plus zone
exclusion — the geometric invariant the hardcoded planner enforces, reused.
"""
# function f(a, b; kw=기본값) ... end : 세미콜론(;) 뒤는 "키워드 인자"(파이썬의 f(a, b, *, kw=...) 와 비슷).
#   호출 시 이름으로 넘김. 여기 기본값들은 호출 시점에 계산됨(예: default_robot_radius() 매번 실행).
# assembly_id::AbstractID : 두 번째 인자는 AbstractID 타입일 때만 이 메서드 사용(다중 디스패치). R::Float64 도 동일.
# 반환: 금지구역을 벗어난 새 적치원 중심좌표(찾으면) 또는 nothing(못 찾으면).
function find_clear_staging_center(env, assembly_id::AbstractID, R::Float64;
        zone_keys = collect(keys(RESTRICTION_ZONES[])),  # 검사할 제한구역 키 목록. RESTRICTION_ZONES[] = Ref 역참조(아래 설명), keys()=딕셔너리 키들, collect()=배열로
        margin::Float64 = default_robot_radius(),         # 다른 적치원 사이 여유간격(로봇 반지름) — 존 여유와 별개
        # ZONE clearance uses a margin PROPORTIONAL to the zone's own radius, so the relocation distance
        # SCALES with zone size (작은 존→작은 이동, 큰 존→큰 이동). A fixed robot-radius margin here would
        # flatten that scaling (move ≈ overlap + const). Tunable via RESTAGE_ZONE_MARGIN_FRAC.
        zone_margin_frac::Float64 = try parse(Float64, get(ENV, "RESTAGE_ZONE_MARGIN_FRAC", "0.5")) catch; 0.5 end,
        # Finer ring step so a small required move isn't floored at one robot radius (which would also
        # flatten the scaling). Tunable via RESTAGE_RING_STEP_FRAC (× robot radius).
        ring_step::Float64 = default_robot_radius() *
            (try parse(Float64, get(ENV, "RESTAGE_RING_STEP_FRAC", "0.34")) catch; 0.34 end),
        n_angles::Int = 24,                                # 각 고리에서 검사할 각도 분할 수(24등분)
        max_rings::Int = 180)                              # 바깥으로 최대 몇 개의 고리까지 탐색할지(step 축소분 보상)
    # RESTRICTION_ZONES[] : `[]` 는 Ref(참조상자) 역참조 — 상자 안에 든 실제 딕셔너리를 꺼냄(파이썬엔 없는 개념).
    # env.staging_circles[assembly_id] : env 의 필드 staging_circles(딕셔너리)에서 이 조립체의 적치원(공)을 꺼냄.
    # [1:2] : 1~2번째 원소(x, y). 줄리아 인덱스는 1부터 시작(파이썬은 0부터). Vector{Float64}(...) = Float64 벡터로 변환.
    c0 = Vector{Float64}(get_center(env.staging_circles[assembly_id])[1:2])  # 현재 적치원 중심(x, y)
    R0 = Float64(get_radius(env.staging_circles[assembly_id]))               # 현재 적치원 반지름
    # 배열 컴프리헨션: [식 for k in 목록 if 조건] — 파이썬과 거의 동일. 존재하는 키에 해당하는 구역 객체만 모음.
    zones = [RESTRICTION_ZONES[][k] for k in zone_keys if haskey(RESTRICTION_ZONES[], k)]  # 활성 제한구역 객체들
    # Staging circles are HIERARCHICALLY NESTED: a parent assembly's circle CONTAINS
    # its children's. So only avoid circles that were ORIGINALLY non-overlapping with
    # this assembly (siblings / unrelated). The ones it already overlaps (its parent,
    # which contains it; its children, which it contains) must stay overlapping — never
    # treat the natural nesting as a collision to dodge.
    # Tuple{Vector{Float64},Float64}[] : "(벡터, 실수) 튜플들을 담는 빈 배열". 끝의 [] 가 "그 타입의 빈 배열"을 뜻함.
    others = Tuple{Vector{Float64},Float64}[]            # 피해야 할 다른 적치원들의 (중심, 반지름) 목록
    # for (a, b) in 딕셔너리 : 딕셔너리를 (키, 값) 쌍으로 순회(파이썬 .items() 와 같음).
    for (aid, b) in env.staging_circles
        # `cond && 실행문` : 줄리아 관용구 — cond 가 참일 때만 오른쪽 실행(파이썬 `if cond: ...` 의 한 줄 버전).
        # continue : 자기 자신(같은 조립체)이면 건너뜀.
        aid == assembly_id && continue
        oc = Vector{Float64}(get_center(b)[1:2]); orad = Float64(get_radius(b))  # 세미콜론(;)으로 두 문장을 한 줄에. 다른 원의 중심·반지름
        # norm(...) : 벡터 길이(유클리드 거리). `.-` 의 점(.)은 "원소별 연산(broadcast)" — c0 와 oc 를 좌표별로 뺌.
        # 두 원이 원래 떨어져 있었으면(중심거리 >= 반지름 합) 회피 대상에 추가. -1e-9 는 부동소수 오차 여유.
        norm(c0 .- oc) >= R0 + orad - 1e-9 && push!(others, (oc, orad))  # push!(배열,값)=배열 끝에 추가(! 는 배열을 직접 수정)
    end

    # clear_of(c) = ... : 한 줄짜리 "지역 함수" 정의(클로저). 위에서 만든 zones/others/R/margin 을 그대로 사용함.
    #   주어진 중심 c 가 모든 제한구역·다른 적치원과 겹치지 않으면 true.
    clear_of(c) =
        # ZONE clearance: distance ≥ zone_radius*(1+frac) + R. The proportional term (frac·zone_radius)
        # REPLACES the fixed robot-radius margin so the relocation distance scales with zone size.
        all(norm(c .- Vector{Float64}(get_center(z)[1:2])) >= get_radius(z) * (1.0 + zone_margin_frac) + R
            for z in zones) &&
        # 다른 적치원(sibling)과는 로봇이 지나갈 여유(margin=로봇반지름)를 유지 — 이건 존 크기와 무관.
        all(norm(c .- oc) >= or_ + R + margin for (oc, or_) in others)

    clear_of(c0) && return c0     # 현재 위치가 이미 깨끗하면 그대로 반환(방어용 — 보통은 안 깨끗함)
    # for i in 1:n : 1부터 n까지 반복(끝값 포함! 파이썬 range(1, n+1) 에 해당). 안쪽→바깥쪽 고리 순서로 탐색.
    for ring in 1:max_rings
        ρ = ring * ring_step                 # 이번 고리의 반지름(중심에서 떨어진 거리)
        for k in 0:(n_angles - 1)            # 한 고리를 n_angles 등분한 각 방향(0 ~ n-1)
            θ = 2π * k / n_angles            # 해당 각도(라디안). 2π = 한 바퀴
            c = c0 .+ [ρ * cos(θ), ρ * sin(θ)]   # 중심 c0 에서 (ρ, θ) 만큼 떨어진 후보 좌표(.+ 는 원소별 덧셈)
            clear_of(c) && return c          # 깨끗한 후보를 처음 찾으면 즉시 반환(가장 가까운 = 최소 이동)
        end
    end
    return nothing                           # 끝까지 못 찾으면 nothing(파이썬 None) — 호출자가 안전 대체동작 수행
end

# "한 줄 문자열" 을 함수 바로 위에 두면 그 함수의 docstring(문서) 이 됨. 이름 앞 `_` 는 "내부 전용" 관례(파이썬과 동일).
# 이 조립체에 해당하는 스케줄 노드 AssemblyComplete 를 찾아 반환(없으면 nothing).
function _assembly_complete_node(env, assembly_id::AbstractID)
    # try ... catch; nothing end : 예외가 나면 nothing 으로(파이썬 try/except 의 한 줄형). 노드가 없으면 안전하게 처리.
    asm = try get_node(env.scene_tree, assembly_id) catch; nothing end   # 씬트리에서 조립체 노드를 찾음
    asm === nothing && return nothing                                    # `===` : 동일 객체/값 여부(특히 nothing 검사에 사용). 없으면 종료
    return try get_node(env.sched, AssemblyComplete(asm)) catch; nothing end  # 스케줄에서 "조립완료" 노드를 찾아 반환
end

"""
    _resync_scene_drift!(env; tol) -> env

After a rigid translation of one or more schedule `start_config`s, snap the SCENE
(physical) nodes that DRIFTED to match. Sim start snapshots the scene from the
schedule (`set_scene_tree_to_initial_condition!`) and then runs it INDEPENDENTLY, so a
schedule translation leaves the scene body behind, desyncing pickup rendezvous /
capture. Rather than enumerate which nodes belong to a moved assembly (nested,
multi-step build steps make this brittle), DETECT drift directly: any FREE (root =
not yet picked/placed) ObjectStart/AssemblyComplete body — and its TransportUnit, if
any — that sits > `tol` from its (now-moved) schedule `start_config` is snapped there.
Nodes not swept by the translation have zero drift and are skipped automatically.
Robots are NOT touched (control drives them to goals). Idempotent — re-running only
re-snaps whatever still drifts, so it composes over N translations.
"""
# 강체이동 뒤 안 따라온 물리(scene) 노드들을 이동된 스케줄 위치로 스냅(맞춤)한다. 로봇은 안 건드림. 여러 번 실행해도 안전(idempotent).
"True once any build step for `assembly_id` has become active or completed."
function _assembly_started(env, assembly_id::AbstractID)
    for v in Graphs.vertices(get_graph(env.sched))
        n = get_node(env.sched, v).node
        n isa Union{OpenBuildStep,CloseBuildStep} || continue
        node_id(n.assembly) == assembly_id || continue
        (v in env.cache.active_set || v in env.cache.closed_set) && return true
    end
    return false
end

function _resync_scene_drift!(env; tol::Float64 = default_robot_radius())
    sched = env.sched
    # 한 씬 노드가 자기 스케줄 위치에서 tol 이상 벌어졌으면(=드리프트) 그 위치로 스냅. 스냅했으면 true.
    function _resync_if_drifted!(scene_node)
        has_parent(scene_node, scene_node) || return false              # free(루트) 인 것만 — 집히거나 놓인 건 제외
        has_vertex(sched, get_start_node(scene_node)) || return false
        g = global_transform(start_config(get_start_node(scene_node, sched)))  # 이동된 스케줄 기준위치
        norm(Vector{Float64}(g.translation[1:2]) .-
             Vector{Float64}(global_transform(scene_node).translation[1:2])) > tol || return false
        set_desired_global_transform!(scene_node, g)
        return true
    end
    # 그 개체의 운반유닛(랑데부 지점) 씬 노드도 함께 — 단 존재할 때만(최종 target 조립체는 운반 안 됨).
    function _resync_tu!(ent)
        tid = node_id(TransportUnitNode(ent))
        has_vertex(env.scene_tree, tid) || return
        _resync_if_drifted!(get_node(env.scene_tree, tid))
    end
    for n in get_nodes(sched)
        if matches_template(ObjectStart, n) || matches_template(AssemblyComplete, n)
            ent = entity(n)
            _resync_if_drifted!(get_node(env.scene_tree, node_id(ent)))  # 부품 object / 하위 조립체 본체(capture 기준)
            _resync_tu!(ent)                                             # 그 화물을 나르는 운반유닛(랑데부 지점)
        end
    end
    return env
end

"""
    restage_assembly!(env, assembly_id; zone_keys, resume=true, verbose=true) -> NamedTuple

Relocate `assembly_id`'s staging area clear of the active restriction zone(s), by
a rigid translation of its `start_config` (the whole staging subtree follows). No
MILP re-solve. Returns a status NamedTuple:
- `:restaged`     — moved; `from`, `to`, `delta` included. Cache rebuilt if `resume`.
- `:infeasible`   — no zone-clear, non-overlapping location found → caller falls back.
- `:already_built`— the assembly is already complete (closed) → nothing to relocate.
- `:no_node` / `:no_staging` — id not found / no staging circle on record.

SAFETY / SCOPE (MVP): only relocates an assembly that is NOT yet complete. Parts
already physically delivered to the OLD staging area are NOT relocated here (that
is future work); the gate below refuses an already-built assembly.
"""
# 이름 끝 `!` : 관례 — 이 함수가 인자(env)를 직접 수정(in-place)한다는 표시.
# 조립체의 적치영역을 제한구역 밖으로 "통째로 평행이동"시킴(MILP 재계산 없음). 결과를 NamedTuple(이름붙은 튜플)로 반환.
function restage_assembly!(env, assembly_id::AbstractID;
        zone_keys = collect(keys(RESTRICTION_ZONES[])),  # 검사할 제한구역 키 목록
        resume::Bool = true,                              # 끝나고 실행 캐시를 다시 만들어 진행을 재개할지
        verbose::Bool = true)                             # 로그 출력 여부
    sched = env.sched                                     # 스케줄 객체를 짧은 이름으로
    # `cond || 실행문` : cond 가 거짓일 때만 오른쪽 실행(&& 의 반대). 적치원 기록이 없으면 즉시 반환.
    # (key=value, ...) : 괄호 안 이름붙은 값들 → NamedTuple. :no_staging 처럼 `:` 로 시작하면 Symbol(가벼운 상수 이름표).
    # $(...) : 문자열 안에 값을 끼워넣는 보간(파이썬 f-string 의 {}).
    haskey(env.staging_circles, assembly_id) ||
        return (status = :no_staging, detail = "no staging circle for $(summary(assembly_id))")  # 적치원 없음
    ac = _assembly_complete_node(env, assembly_id)        # 이 조립체의 "조립완료" 스케줄 노드
    ac === nothing &&
        return (status = :no_node, detail = "no AssemblyComplete node for $(summary(assembly_id))")  # 노드 없음

    v = get_vtx(sched, node_id(ac))                       # 스케줄 그래프에서 그 노드의 정점(vertex) 인덱스
    # `x in 집합` : 포함 여부(파이썬과 동일). 이미 완료(closed_set 에 있음)면 옮길 게 없음.
    v in env.cache.closed_set &&
        return (status = :already_built, detail = "$(summary(assembly_id)) already complete")  # 이미 조립 완료
    _assembly_started(env, assembly_id) &&
        return (status = :already_started,
                detail = "$(summary(assembly_id)) has active/completed build steps")

    ball = env.staging_circles[assembly_id]               # 현재 적치원(공)
    R  = Float64(get_radius(ball))                         # 반지름
    c0 = Vector{Float64}(get_center(ball)[1:2])            # 현재 중심(x, y)
    c1 = find_clear_staging_center(env, assembly_id, R; zone_keys = zone_keys)  # 구역 밖의 새 중심 찾기
    c1 === nothing &&
        return (status = :infeasible, detail = "no zone-clear staging location for $(summary(assembly_id))")  # 자리 못 찾음

    Δ = c1 .- c0                                           # 이동량(새 중심 - 옛 중심), 원소별 뺄셈. Δ 는 그리스문자 변수명(허용됨)
    tnode = start_config(ac)                               # 이 조립체의 시작배치 노드(변환트리의 한 노드)
    gt = global_transform(tnode)                           # 그 노드의 현재 전역 변환(위치+회전)
    # `∘` : 함수 합성 연산자(수학의 f∘g). 여기서는 "Δ만큼 평행이동" 변환을 기존 변환 gt 앞에 합성.
    # Translation(dx, dy, dz) : 평행이동 변환. z는 0.0(평면 이동). set_..._! 로 새 목표 변환을 설정(! = 수정).
    set_desired_global_transform!(tnode,
        CoordinateTransformations.Translation(Δ[1], Δ[2], 0.0) ∘ gt)
    env.staging_circles[assembly_id] = LazySets.Ball2(c1, R)  # 기록상의 적치원도 새 중심·반지름으로 갱신(Ball2 = 2D 원)

    # --- 씬(scene) 재동기화: 안 따라온 물리 노드를 이동한 스케줄 config 로 맞춤 ---
    # 위 강체이동으로 스케줄 transform 트리(start_config(ac) 의 자손)는 전부 Δ만큼 움직였다:
    #   start_config(ac) → ObjectStart.config → FormTransportUnit.config(=tu 형성점),
    #   그리고 부품 delivery/lift goal 까지. 그러나 씬의 물리 노드(assembly 본체, 부품 object,
    #   운반유닛 tu)는 set_scene_tree_to_initial_condition! 가 sim 시작 때 "스냅샷 복사"한 뒤
    #   독립이다(construction_schedule.jl). 그래서 강체이동에 안 따라와 옛 자리에 남고, 로봇
    #   RobotGo goal 만 Δ 이동 → 로봇·화물·tu·assembly 기준이 정확히 Δ 어긋나 (a)FormTransportUnit
    #   랑데부 불성립(랑데부 deadlock) 또는 (b)최종 capture 실패(has_edge assert) → 빌드 정지.
    #
    # 어느 부품이 이 assembly 소속인지 열거하는 대신(중첩/다단계 빌드스텝이라 까다로움),
    # **드리프트를 직접 감지**한다: 이동 직후 아직 시작 안 한(free=루트) 씬 노드 중 자기 스케줄
    # start_config 에서 tol 이상 벌어진 것만 그 위치로 스냅. 이동에 안 휩쓸린 다른 assembly 의
    # 진행 중 노드는 드리프트가 없어 자동 제외된다. (로봇은 제어가 goal 로 몰고 가므로 제외 —
    # ObjectStart/AssemblyComplete/그에 딸린 TransportUnit 만 본다. RobotStart 는 안 건드림.)
    _resync_scene_drift!(env)   # 드리프트한 free 씬 노드(부품·본체·tu)를 이동된 스케줄 위치로 스냅(아래 헬퍼)

    # `*` 로 문자열을 이어붙임(파이썬의 + 에 해당). round.(벡터; digits=n) = 벡터의 각 원소를 반올림(점은 broadcast).
    verbose && @info "[RESTAGE] $(summary(assembly_id)) staging moved Δ=$(round.(Δ; digits=3)) " *
                     "$(round.(c0; digits=2)) -> $(round.(c1; digits=2))"   # 이동 정보 로그
    resume && reset_cache_resume!(env.cache, sched)       # 요청 시 캐시 재설정 후 진행 재개
    return (status = :restaged, from = c0, to = c1, delta = Δ)  # 성공: 옮긴 출발/도착/이동량을 담아 반환
end

"""
    zone_blocked_assemblies(env; zone_keys, margin) -> Vector{AbstractID}

Every RELOCATABLE assembly whose staging circle (its goal region) is overlapped by
an active restriction zone — i.e., the set a single `restage_assembly!` misses when
ONE zone covers SEVERAL assemblies' goals. "Relocatable" = NOT the root (the largest
staging circle encompasses the whole build; it can't be moved) and NOT yet started
(its `AssemblyComplete` is neither closed nor active — an in-progress/built assembly
can't be cleanly translated). Overlap test mirrors `_zone_clear_of_goals`
(ood_injection.jl): center distance < sum of radii + margin.
"""
# 활성 제한구역과 적치원이 겹쳐 "막힌" 조립체들의 ID 목록을 돌려준다(옮길 수 있는 것만: root 아님 + 아직 시작 안 함).
function zone_blocked_assemblies(env;
        zone_keys = collect(keys(RESTRICTION_ZONES[])),
        margin::Float64 = default_robot_radius())
    isempty(env.staging_circles) && return AbstractID[]  # 적치원이 하나도 없으면 빈 배열
    zones = [RESTRICTION_ZONES[][k] for k in zone_keys if haskey(RESTRICTION_ZONES[], k)]  # 활성 제한구역 객체들
    isempty(zones) && return AbstractID[]                # 활성 구역이 없으면 막힌 것도 없음
    # root = the assembly whose staging circle is largest (encompasses the build); never relocate it
    # argmax(f, 목록) : f 값이 가장 큰 원소를 고름. 적치원이 가장 큰 조립체 = root(빌드 전체를 품음 → 못 옮김)
    root = argmax(k -> Float64(get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))
    blocked = AbstractID[]                               # 막힌 조립체 id 를 담을 빈 배열
    for (aid, ball) in env.staging_circles
        aid == root && continue                                       # root 는 옮길 수 없음 — 제외
        ac = _assembly_complete_node(env, aid); ac === nothing && continue
        v = get_vtx(env.sched, node_id(ac))
        (v in env.cache.closed_set || v in env.cache.active_set ||
         _assembly_started(env, aid)) && continue   # only pristine future assemblies
        bc = Vector{Float64}(get_center(ball)[1:2]); bR = Float64(get_radius(ball))
        # 활성 zone 중 하나라도 이 적치원과 겹치면 막힌 것
        any(z -> norm(bc .- Vector{Float64}(get_center(z)[1:2])) < bR + Float64(get_radius(z)) + margin, zones) &&
            push!(blocked, aid)
    end
    return blocked
end

"""
    _count_future_goals_in_zone(env; zone_keys, margin) -> Int

How many NOT-yet-done EntityGo goals still sit INSIDE an active zone (strict — within
the bare zone radius, the radius at which TangentBug makes a robot wait forever at the
rim, route_planning.jl:673). After relocating every RELOCATABLE assembly, a nonzero
count means the zone also covers goals that CAN'T be moved — chiefly the ROOT
assembly's own delivery goals (the root encompasses the build and is never relocated).
That is a genuine infeasibility: no amount of restaging clears it, so the caller must
fall back rather than march into a guaranteed stall (which `restage_all_blocked!`
would otherwise hide behind a `:restaged_all`).
"""
# 아직 안 끝난 EntityGo 목표점 중 활성 구역 "안"에 남아있는 것의 개수를 센다(0 이 아니면 못 옮기는 root 목표가 걸린 진짜 infeasible).
function _count_future_goals_in_zone(env; zone_keys = collect(keys(RESTRICTION_ZONES[])),
        margin::Float64 = 0.0)
    zones = [RESTRICTION_ZONES[][k] for k in zone_keys if haskey(RESTRICTION_ZONES[], k)]  # 활성 제한구역 객체들
    isempty(zones) && return 0                            # 활성 구역 없으면 0
    cnt = 0                                               # 구역 안에 남은 목표 개수
    G = get_graph(env.sched)                              # 스케줄 그래프
    for v in Graphs.vertices(G)
        v in env.cache.closed_set && continue                 # 이미 끝난 건 제외(future/active 만)
        nn = get_node(env.sched, v).node
        matches_template(EntityGo, nn) || continue            # 항법으로 이동하는 노드만(RobotGo/TransportUnitGo/LiftIntoPlace)
        g = Vector{Float64}(project_to_2d(global_transform(goal_config(nn)).translation))  # 그 노드 목표점의 2D 좌표
        # 활성 구역 중 하나라도 목표점을 (구역반지름+margin) 안에 품으면 카운트 +1
        any(z -> norm(g .- Vector{Float64}(get_center(z)[1:2])) < Float64(get_radius(z)) + margin, zones) &&
            (cnt += 1)
    end
    return cnt
end

"""
    root_deposit_goals(env; root) -> Vector{Vector{Float64}}

World-frame (x,y) of every place the ROOT assembly's direct components get deposited
(`LiftIntoPlace` goal of each component the root is built from). These are the
UN-RELOCATABLE goals: the root is the build's reference frame and is never moved, so a
zone covering any of these can't be cleared by restaging — it dooms the build. Used to
keep generated forbid zones away from the root (so an injected OOD stays RECOVERABLE).
"""
# root 조립체 직속 부품들이 놓이는(LiftIntoPlace) 자리들의 (x,y) 좌표 목록 — root 는 안 옮기므로 이 목표를 덮는 구역은 복구 불가.
function root_deposit_goals(env;
        root = isempty(env.staging_circles) ? nothing :            # 적치원 없으면 root 없음
               argmax(k -> Float64(get_radius(env.staging_circles[k])), collect(keys(env.staging_circles))))  # 가장 큰 적치원 = root
    root === nothing && return Vector{Float64}[]
    ac = _assembly_complete_node(env, root); ac === nothing && return Vector{Float64}[]  # root 의 "조립완료" 노드
    out = Vector{Float64}[]                                        # 결과 좌표들
    for (id, _) in assembly_components(entity(ac))                 # root 를 이루는 직속 부품들을 순회 (`_` = 값 무시, 키만 사용)
        cargo = try get_node(env.scene_tree, id) catch; continue end          # 그 부품의 씬 노드(없으면 건너뜀)
        lift = try get_node(env.sched, LiftIntoPlace(cargo)) catch; continue end  # 그 부품을 끼우는 LiftIntoPlace 노드
        push!(out, Vector{Float64}(project_to_2d(global_transform(goal_config(lift)).translation)))  # 그 목표점 2D 좌표를 추가
    end
    return out
end

"""
    zone_clears_root_goals(center, r, env; margin) -> Bool

True iff a zone of radius `r` at `center` does NOT cover any root deposit goal — i.e.
the zone is RESTAGE-RECOVERABLE (it can only block relocatable sub-assemblies, never
the immovable root). Generation guard, complementary to `_zone_clear_of_goals`
(ood_injection.jl): that one yields a pure-detour zone (clears ALL staging); this one
ALLOWS overlapping a sub-assembly's staging but forbids trapping the root's goals.
"""
# center 에 반지름 r 인 구역이 root 의 어떤 deposit 목표도 안 덮으면 true(= restage 로 복구 가능한 구역). OOD 생성 시 가드로 씀.
function zone_clears_root_goals(center, r, env; margin::Float64 = default_robot_radius())
    c = Vector{Float64}(center)[1:2]                              # 구역 중심(x,y)
    all(g -> norm(c .- g) >= r + margin, root_deposit_goals(env))  # 모든 root 목표점이 (r+margin) 밖에 있으면 true
end

"""
    restage_all_blocked!(env; zone_keys, resume=true, verbose=true) -> NamedTuple

Multi-assembly recovery: relocate EVERY assembly the zone(s) block (Phase (a)), not
just one. Greedy — largest staging circle first (hardest to place), each call reusing
`restage_assembly!`, which reads `env.staging_circles` live so later moves avoid the
already-relocated ones, and whose drift-based scene re-sync is idempotent (re-running
it only snaps whatever still drifted). The per-call cache rebuild is suppressed
(`resume=false`) and done ONCE at the end.

Returns `(status, moved, failed)`:
- `:restaged_all` — every blocked assembly relocated.
- `:partial`      — some moved, some `:infeasible` (no zone-clear, non-overlapping spot).
- `:infeasible`   — none could be placed → caller engages the safe fallback.
- `:none`         — no blocked assemblies (zone clears all goals already).
"""
# 구역에 막힌 조립체를 하나가 아니라 전부 옮기는 다중 복구. 큰 것부터 그리디로 restage_assembly! 반복, 캐시 재빌드는 끝에 1회.
function restage_all_blocked!(env;
        zone_keys = collect(keys(RESTRICTION_ZONES[])),
        resume::Bool = true, verbose::Bool = true)
    blocked = zone_blocked_assemblies(env; zone_keys = zone_keys)  # 막힌 조립체 목록
    isempty(blocked) && return (status = :none, moved = NamedTuple[], failed = NamedTuple[])  # 없으면 :none
    # 큰 적치원부터 배치(작은 것이 그 둘레에 끼워지도록 = bin-packing 휴리스틱)
    order = sort(blocked; by = a -> -Float64(get_radius(env.staging_circles[a])))  # 반지름 내림차순 정렬(큰 것 먼저). 앞의 `-` 로 내림차순
    moved = NamedTuple[]; failed = NamedTuple[]           # 옮긴 것 / 실패한 것 기록용 배열
    for a in order                                       # 큰 조립체부터
        res = restage_assembly!(env, a; zone_keys = zone_keys, resume = false, verbose = verbose)  # 하나씩 옮김(캐시 재빌드는 미룸)
        # 삼항식: 성공(:restaged)이면 moved 에, 아니면 failed 에 결과를 기록.
        res.status == :restaged ?
            push!(moved, (id = a, from = res.from, to = res.to)) :
            push!(failed, (id = a, status = res.status))
    end
    (resume && !isempty(moved)) && reset_cache_resume!(env.cache, env.sched)  # 캐시 재빌드는 끝에 1회만
    # Phase 3: residual feasibility — after relocating all RELOCATABLE assemblies, are
    # there goals STILL in the zone? If so they're un-relocatable (root/fixed) -> the
    # build cannot complete -> report honestly so the caller falls back (don't pretend
    # :restaged_all when a root-overlapping zone dooms the build).
    residual = _count_future_goals_in_zone(env; zone_keys = zone_keys)  # 다 옮기고도 구역 안에 남은 목표 수
    # 연쇄 삼항식(a ? x : b ? y : ...) : 위에서부터 처음 참인 조건의 값을 status 로. 최종 결과 상태 판정.
    status = (isempty(moved) && !isempty(failed)) ? :infeasible :      # nothing could be placed  # 하나도 못 옮김
             residual > 0                        ? :residual_blocked : # zone still covers un-relocatable goals  # 못 옮기는 목표가 남음
             !isempty(failed)                    ? :partial :          # some moved, some couldn't  # 일부만 성공
                                                   :restaged_all       # fully cleared  # 전부 성공
    verbose && @info "[RESTAGE-ALL] moved $(length(moved))/$(length(order)) blocked; failed=$(length(failed)); residual_goals_in_zone=$residual -> $status"
    return (status = status, moved = moved, failed = failed, residual = residual)
end

"""
    _build_footprint(env; root) -> (center, radius)

Bounding disc of the WHOLE build in the (x,y) plane: smallest circle about the root's
staging center that contains every staging circle AND every root deposit goal. This is
what a whole-build translation must carry clear of the zone.
"""
# 빌드 전체를 감싸는 최소원(중심, 반지름)을 구한다 — 모든 적치원과 root deposit 목표를 다 품는 원. 통째 이동이 구역 밖으로 날라야 할 대상.
function _build_footprint(env;
        root = argmax(k -> Float64(get_radius(env.staging_circles[k])), collect(keys(env.staging_circles))))  # 가장 큰 적치원 = root
    fc = Vector{Float64}(get_center(env.staging_circles[root])[1:2])  # 감싸는 원의 중심 = root 적치원 중심
    fR = 0.0                                                          # 감싸는 원의 반지름(0 에서 키워감)
    for (_, b) in env.staging_circles                                   # 모든 적치원을 품도록
        bc = Vector{Float64}(get_center(b)[1:2]); br = Float64(get_radius(b))
        fR = max(fR, norm(bc .- fc) + br)
    end
    for g in root_deposit_goals(env)                                   # 중앙 deposit goal 들도 품도록
        fR = max(fR, norm(Vector{Float64}(g)[1:2] .- fc))
    end
    return (fc, fR)
end

"""
    _find_clear_translation(fc, fR, env; zone_keys, margin, ...) -> Vector{Float64} | nothing

Smallest Δ (ring search out from the current footprint center `fc`) such that the
translated footprint disc `(fc+Δ, fR)` clears EVERY active zone by `margin`. `[0,0]`
if already clear, `nothing` if no spot within `max_rings` (caller falls back).
Mirrors `find_clear_staging_center`'s concentric-ring scan, but on the whole-build disc.
"""
# 감싸는 원(fc,fR)이 모든 구역을 margin 만큼 벗어나게 하는 최소 이동량 Δ 를 동심원 탐색으로 찾음. 이미 깨끗하면 [0,0], 못 찾으면 nothing.
function _find_clear_translation(fc, fR, env;
        zone_keys = collect(keys(RESTRICTION_ZONES[])),
        margin::Float64 = default_robot_radius(),
        ring_step::Float64 = default_robot_radius(),
        n_angles::Int = 24, max_rings::Int = 200)
    zones = [RESTRICTION_ZONES[][k] for k in zone_keys if haskey(RESTRICTION_ZONES[], k)]  # 활성 제한구역들
    isempty(zones) && return [0.0, 0.0]                  # 구역 없으면 이동 불필요
    # 중심 c 가 모든 구역과 (구역반지름+감싸는반지름+여유) 이상 떨어져 있으면 true(깨끗).
    clear_of(c) = all(norm(c .- Vector{Float64}(get_center(z)[1:2])) >= Float64(get_radius(z)) + fR + margin
                      for z in zones)
    clear_of(fc) && return [0.0, 0.0]                    # 현 위치가 이미 깨끗하면 안 움직임
    for ring in 1:max_rings                              # 안쪽 고리부터 바깥으로
        ρ = ring * ring_step                             # 이번 고리의 반지름
        for k in 0:(n_angles - 1)                        # 고리를 n_angles 등분한 각 방향
            θ = 2π * k / n_angles                        # 해당 각도(라디안)
            c = fc .+ [ρ * cos(θ), ρ * sin(θ)]           # 후보 중심
            clear_of(c) && return c .- fc                # 처음 깨끗한 후보의 이동량(=후보-현재)을 반환
        end
    end
    return nothing                                       # 못 찾으면 nothing(호출자 폴백)
end

"""
    _apply_uniform_translation!(env, Δ) -> env

Rigidly shift the WHOLE build by Δ (x,y): translate every assembly's `start_config`
(root included) — each subtree carries its staging + components' deposit goals — update
the staging-circle records, then `_resync_scene_drift!` snaps drifted scene bodies/TUs.
Translations COMPOSE: calling this twice with Δ₁ then Δ₂ leaves a net shift of Δ₁+Δ₂,
which the two-tier `translate_whole_build!` relies on to top a minimal move up to the
conservative one without any undo.
"""
# 빌드 전체를 Δ 만큼 강체이동한다: 모든 조립체의 start_config 를 옮기고 적치원 기록도 갱신한 뒤, 안 따라온 씬 노드를 스냅. 이동은 누적됨(compose).
function _apply_uniform_translation!(env, Δ)
    T = CoordinateTransformations.Translation(Δ[1], Δ[2], 0.0)  # Δ 만큼의 평행이동 변환(z=0, 평면 이동)
    for aid in collect(keys(env.staging_circles))        # 모든 조립체에 대해
        ac = _assembly_complete_node(env, aid)           # 그 조립체의 "조립완료" 노드
        ac === nothing && continue                       # 없으면 건너뜀
        tnode = start_config(ac)                          # 시작배치 노드(변환트리 루트)
        set_desired_global_transform!(tnode, T ∘ global_transform(tnode))  # 기존 변환 앞에 T 를 합성해 Δ 이동(∘ = 합성)
        b = env.staging_circles[aid]                      # 이 조립체의 적치원
        env.staging_circles[aid] =                        # 기록상의 적치원 중심도 Δ 만큼 옮김
            LazySets.Ball2(Vector{Float64}(get_center(b)[1:2]) .+ Δ, Float64(get_radius(b)))
    end
    _resync_scene_drift!(env)                                # 드리프트한 free 씬 노드(부품·본체·tu)를 이동된 스케줄 위치로 스냅
    return env
end

"Physical work-goal discs that the unfinished schedule still has to reach."
function _future_goal_discs(env)
    elems = Tuple{Vector{Float64},Float64}[]
    for v in Graphs.vertices(get_graph(env.sched))
        v in env.cache.closed_set && continue
        n = get_node(env.sched, v).node
        matches_template(EntityGo, n) || continue
        c = try
            Vector{Float64}(project_to_2d(global_transform(goal_config(n)).translation))
        catch
            continue
        end
        r = try
            ent = entity(n)
            sn = get_node(env.scene_tree, node_id(ent))
            Float64(get_radius(get_cached_geom(sn, HypersphereKey())))
        catch
            default_robot_radius()
        end
        push!(elems, (c[1:2], max(r, 0.0)))
    end
    return elems
end

"Unfinished physical goals plus non-root staging workspaces."
function _future_work_discs(env)
    elems = _future_goal_discs(env)
    isempty(env.staging_circles) && return elems
    root = argmax(k -> Float64(get_radius(env.staging_circles[k])),
                  collect(keys(env.staging_circles)))
    for (aid, b) in env.staging_circles
        aid == root && continue  # the oversized global envelope is not occupied workspace
        ac = _assembly_complete_node(env, aid)
        ac === nothing && continue
        get_vtx(env.sched, node_id(ac)) in env.cache.closed_set && continue
        push!(elems, (Vector{Float64}(get_center(b)[1:2]), Float64(get_radius(b))))
    end
    return elems
end

"Count unfinished physical work discs that overlap any active restriction zone."
function _count_future_work_overlaps(env;
        zone_keys = collect(keys(RESTRICTION_ZONES[])),
        margin::Float64 = 1e-4)
    zones = [RESTRICTION_ZONES[][k] for k in zone_keys
             if haskey(RESTRICTION_ZONES[], k)]
    return count(_future_work_discs(env)) do disc
        c, r = disc
        any(z -> norm(c .- Vector{Float64}(get_center(z)[1:2])) + 1e-9 <
                 Float64(get_radius(z)) + r + margin, zones)
    end
end

"""
    _minimum_clear_translation(elems, zones; margin, n_angles)

Compute a minimum-displacement rigid translation for physical goal discs. Along
each candidate direction, circle exclusions become scalar forbidden intervals;
their union is solved analytically. Displacement therefore scales continuously
with either a small or a large forbid-zone radius, without fixed ring steps.
"""
function _minimum_clear_translation(elems, zones;
        margin::Float64 = 1e-4, n_angles::Int = 96)
    (isempty(zones) || isempty(elems)) && return [0.0, 0.0]
    zc(z) = Vector{Float64}(get_center(z)[1:2])
    clear(Δ) = all(norm((c .+ Δ) .- zc(z)) + 1e-9 >=
                       Float64(get_radius(z)) + r + margin
                       for (c, r) in elems for z in zones)
    clear([0.0, 0.0]) && return [0.0, 0.0]

    dirs = [[cos(2π*k/n_angles), sin(2π*k/n_angles)] for k in 0:(n_angles-1)]
    # Include exact outward normals for overlapping pairs. This gives a tiny
    # zone a tangent-size move instead of rounding up to a search-ring radius.
    for (c, r) in elems, z in zones
        q = c .- zc(z)
        R = Float64(get_radius(z)) + r + margin
        d = norm(q)
        d < R || continue
        push!(dirs, d > 1e-10 ? q ./ d : [1.0, 0.0])
    end

    best, bestnorm = nothing, Inf
    for u in dirs
        intervals = Tuple{Float64,Float64}[]
        for (c, r) in elems, z in zones
            q = c .- zc(z)
            R = Float64(get_radius(z)) + r + margin
            b = dot(q, u)
            disc = b*b - (dot(q, q) - R*R)
            disc <= 0 && continue
            s = sqrt(max(disc, 0.0))
            lo, hi = -b-s, -b+s
            hi >= 0 && push!(intervals, (max(lo, 0.0), hi))
        end
        sort!(intervals; by=first)
        t = 0.0
        for (lo, hi) in intervals
            lo <= t + 1e-10 && t < hi + 1e-10 && (t = hi + 1e-7)
        end
        Δ = t .* u
        if t < bestnorm && clear(Δ)
            best, bestnorm = Δ, t
        end
    end
    return best
end

function _find_min_translation(env;
        zone_keys = collect(keys(RESTRICTION_ZONES[])),
        margin::Float64 = 1e-4, n_angles::Int = 96)
    zones = [RESTRICTION_ZONES[][k] for k in zone_keys if haskey(RESTRICTION_ZONES[], k)]
    return _minimum_clear_translation(_future_work_discs(env), zones;
                                      margin=margin, n_angles=n_angles)
end

"""
    translate_whole_build!(env; zone_keys, resume=true, verbose=true) -> NamedTuple

WHOLE-BUILD relocation (Phase B): when a zone covers the root's OWN (un-relocatable)
deposit goals — the dense central core `restage_all_blocked!` reports as
`:residual_blocked` — no per-assembly move clears it. Translate the ENTIRE build by one
rigid Δ so its whole work region clears the zone.

Mechanism: every assembly's `start_config` is an independent transform-tree root whose
subtree carries BOTH its staging area AND its components' deposit goals
(`goal_config(LiftIntoPlace)` descends from `start_config(AssemblyComplete)`), so a
uniform Δ on all of them shifts the schedule with no internal desync; `_resync_scene_drift!`
follows on the scene side.

Δ = `_find_min_translation` — the minimum shift that clears every unfinished physical
goal disc and every non-root local staging workspace. The oversized root planning
envelope is deliberately excluded because it is not occupied geometry. Small zones
therefore cause local-size moves, while large zones expand the analytic exclusion
intervals and produce proportionally larger moves. The conservative whole-footprint
disc remains only as a last-resort fallback if no analytic candidate exists.

Returns `(status, delta, footprint_radius, residual)`:
- `:translated`       — moved; zone clear of all future goals (residual 0).
- `:residual_blocked` — moved but goals STILL in zone → caller falls back.
- `:infeasible`       — no zone-clear destination at all.
- `:no_staging`       — no staging circles on record.
"""
# 빌드 전체를 하나의 Δ 로 통째 옮겨 구역을 벗어나게 하는 Phase B 복구(root 자신의 목표까지 구역에 걸린 조밀한 중앙 코어용). MILP 재계산 없음.
function translate_whole_build!(env;
        zone_keys = collect(keys(RESTRICTION_ZONES[])),
        resume::Bool = true, verbose::Bool = true)
    isempty(env.staging_circles) && return (status = :no_staging,)        # 적치원 없으면 옮길 게 없음
    Δ = _find_min_translation(env; zone_keys = zone_keys)                  # physical goals + local staging 기준 최소 이동
    fc, fR = _build_footprint(env)                                        # 빌드 전체를 감싸는 원(폴백용)
    if Δ === nothing                                                      # 폴백: 보수적 bounding-disc
        Δ = _find_clear_translation(fc, fR, env; zone_keys = zone_keys)
    end
    Δ === nothing &&                                                      # 그래도 못 찾으면 복구 불가
        return (status = :infeasible, detail = "no clear destination for footprint R=$(round(fR; digits=2))")
    _apply_uniform_translation!(env, Δ)                                   # 실제로 빌드 전체를 Δ 만큼 옮김
    resume && reset_cache_resume!(env.cache, env.sched)                   # 요청 시 캐시 재빌드 후 재개
    residual = _count_future_goals_in_zone(env; zone_keys = zone_keys)    # 옮기고도 구역 안에 남은 목표 수
    status = residual > 0 ? :residual_blocked : :translated               # 남았으면 :residual_blocked, 깨끗하면 :translated
    verbose && @info "[WHOLE-BUILD] translated Δ=$(round.(Δ; digits=3)) |Δ|=$(round(norm(Δ); digits=2)) " *
                     "footprint(R=$(round(fR; digits=2))); residual=$residual -> $status"
    return (status = status, delta = Δ, footprint_radius = fR,
            solver = :physical_goal_and_local_staging_discs,
            n_goal_discs = length(_future_goal_discs(env)),
            n_work_discs = length(_future_work_discs(env)), residual = residual)
end
