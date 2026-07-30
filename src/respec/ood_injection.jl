# =============================================================================
# ood_injection.jl  --  PHYSICAL out-of-distribution event GENERATION.
#
# This is the front-end the respec layer always assumed but never had: instead
# of a human hand-calling `push_ood!("...")`, the SIMULATOR drives its own state
# into an out-of-distribution condition and (optionally) emits the matching NL
# event into the respec pipeline. See
#   docs/simulator_ood_generation_design_2026-06-23.md
#
# Two OOD families (per that design):
#   1-2  restriction district = navigation NO-GO ZONE  -> implemented here.
#        A zone is a static 2D Ball2 obstacle the WHOLE motion stack already
#        knows how to avoid: active_staging_circles (route_planning.jl) feeds
#        TangentBug/RVO, so appending a zone there makes every agent detour it.
#   1-1  robot fault + directional spare pool          -> later (spare pool).
#
# Design constraint honoured: PlannerEnv (route_planning.jl:97) is an immutable
# @with_kw struct, so NO new field is added. New state lives in module-level
# Refs, exactly like RESPEC_ENABLED / RESPEC_HOLD / RESPEC_QUEUE.
#
# [한국어 요약]
#   이 파일 = "물리적 OOD(분포 밖 상황) 생성기". 사람이 손으로 push_ood! 를 부르는 대신,
#   시뮬레이터가 스스로 자기 상태를 이상상황(OOD)으로 몰아넣고, 그에 맞는 자연어(NL) 이벤트를
#   respec(재명세) 파이프라인으로 흘려보낸다. 프로젝트 역할: OOD "발생" 쪽 front-end(respec 는 그 뒤 "대응").
#   두 가지 OOD 종류:
#     1-2 통행금지 구역(navigation no-go zone) — 정적 원형 장애물을 항법 스택에 넣어 우회 유발.
#     1-1 로봇 고장 + 방위별 예비(spare) 풀 — 고장 시 가장 가까운 풀이 예비 1대를 내줘 1:1 인계.
#   설계 제약: PlannerEnv 는 불변(immutable) 구조체라 새 필드를 못 넣음 → 모든 새 상태는
#   module-level Ref(전역 참조 상자)에 담는다(RESPEC_* 패턴과 동일).
# 문법 참고:
#   · const NAME = Ref(값) : "상수 이름"이지만 상자 안 내용물(Ref[])은 바꿀 수 있는 전역 가변 상태.
#   · 이름 끝 `!` : 인자/전역을 직접 수정(in-place)한다는 관례. `?` 는 술어(true/false) 반환 관례.
#   · f(x::T) = ... : x 가 타입 T 일 때만 쓰는 메서드(다중 디스패치). `::Symbol` 등 타입 표기.
#   · `:이름` : Symbol(가벼운 라벨 상수). `A && B` / `A || B` : 단락 평가(파이썬 한 줄 if 관용구).
# =============================================================================

# -----------------------------------------------------------------------------
# OOD 1-2 :: restriction zones (navigation no-go zones)
# -----------------------------------------------------------------------------

"""
Active navigation no-go zones, keyed by a scenario label. Each value is a 2D
`LazySets.Ball2` in the same world frame the staging circles use, so it drops
straight into the TangentBug obstacle set. Module-level (not on PlannerEnv) so
the env struct stays immutable; mirrors RESPEC_* refs.
"""
# const : 이 이름은 "상수"(다시 대입하지 않음)임을 표시 — 컴파일러가 최적화하게 해줌.
# Ref(...) : "한 칸짜리 가변 상자"(파이썬으로 치면 [x] 한 칸짜리 리스트). 상자 안 내용은 바꿀 수 있되, 상자 자체(RESTRICTION_ZONES)는 const 로 고정.
# 의미: 현재 활성화된 "통행금지 구역"들을 담는 딕셔너리. 키=시나리오 라벨(Symbol), 값=2D 원(Ball2).
const RESTRICTION_ZONES = Ref(Dict{Symbol,LazySets.Ball2}())

# 상자 안의 딕셔너리를 꺼내 돌려주는 한 줄 함수. `Ref[]` 의 `[]` 는 "상자 열어 내용 꺼내기"(역참조).
restriction_zones() = RESTRICTION_ZONES[]
# 통행금지 구역 전체 비우기. `(A; B)` 는 A 실행 후 B 를 반환(여러 식을 묶어 마지막 값을 돌려줌). empty! 의 `!` = 인자를 직접 비움.
clear_restriction_zones!() = (empty!(RESTRICTION_ZONES[]); nothing)
# 특정 키(key)의 구역 하나만 삭제. delete! 도 in-place 수정이라 `!` 가 붙음. 반환값은 nothing(파이썬 None).
remove_restriction_zone!(key::Symbol) = (delete!(RESTRICTION_ZONES[], key); nothing)

"""
    add_restriction_zone!(key, center, radius) -> Ball2

Register (or replace) a no-go zone. `center` may be 2D or 3D (only x,y are used);
stored as a 2D `Ball2`. Takes effect on the NEXT `get_twist_cmd` — every agent's
TangentBug policy will treat it as a static circular obstacle and route around it.
"""
# 통행금지 구역 하나를 등록(또는 같은 key 면 교체)하는 함수.
# center::AbstractVector : center 는 "벡터 종류 아무거나"(배열 등). radius::Real : 실수형 반지름.
function add_restriction_zone!(key::Symbol, center::AbstractVector, radius::Real)
    z = LazySets.Ball2(Float64[center[1], center[2]], Float64(radius))  # x,y 두 좌표만 떼어 2D 원(Ball2) 생성. Float64[...] 는 실수 배열 만들기
    RESTRICTION_ZONES[][key] = z   # 상자 안 딕셔너리에 key→원(z) 등록. 첫 [] 는 상자 열기, [key] 는 딕셔너리 키 접근
    return z                       # 만든 원을 반환
end

"""
    active_restriction_zones()

Iterator of `key => 2D Ball2` in the EXACT shape `active_staging_circles` yields,
so `circle_avoidance_policy` / `get_closest_interfering_circle` consume zones and
staging circles uniformly (both only call `get_center`/`get_radius` on the value
and treat the key opaquely). Zones are ALWAYS active — independent of
`active_build_steps` and never filtered by `exclude_ids`.
"""
# 등록된 구역들을 "key => 원" 쌍으로 하나씩 내보내는 제너레이터(파이썬의 generator expression 과 같은 문법).
# `=>` 는 키=값 쌍(Pair) 표기. 소괄호로 감싼 `( ... for ... )` 는 즉시 만들지 않고 필요할 때 하나씩 생성.
active_restriction_zones() = (k => c for (k, c) in RESTRICTION_ZONES[])

# -----------------------------------------------------------------------------
# Random / targeted zone generators (the "generate an OOD" action)
# -----------------------------------------------------------------------------

"""
    activity_bbox(env) -> (xmin, xmax, ymin, ymax)

2D bounding box of current activity: active agent positions plus staging-circle
extents. Used to place a random zone somewhere that actually interacts with the
ongoing build (a zone in empty space would force no detour).
"""
# 현재 활동 영역(활성 로봇 위치 + 적치원 범위)을 둘러싸는 2D 경계상자(bounding box)를 구한다.
function activity_bbox(env)
    xs = Float64[]    # x 좌표들을 모을 빈 실수 배열
    ys = Float64[]    # y 좌표들을 모을 빈 실수 배열
    # `for (_, p) in ...` : 각 항목을 (key, value) 로 풀되, key 는 `_` 로 받아 "안 씀"을 표시(파이썬과 동일).
    for (_, p) in get_active_pos(env)        # 활성 에이전트들의 (id, 위치) 쌍을 순회
        push!(xs, p[1]); push!(ys, p[2])     # 위치의 x,y 를 각각 배열에 추가. push! 는 배열 끝에 덧붙이기(in-place)
    end
    for (_, c) in env.staging_circles        # 적치원(staging circle)들의 (id, 원) 쌍을 순회
        ctr = get_center(c); r = get_radius(c)  # 원의 중심과 반지름을 가져옴
        push!(xs, ctr[1] - r); push!(xs, ctr[1] + r)  # 원의 좌/우 끝 x 좌표를 추가
        push!(ys, ctr[2] - r); push!(ys, ctr[2] + r)  # 원의 아래/위 끝 y 좌표를 추가
    end
    # `조건 && 식` : 조건이 참일 때만 뒤의 식을 실행(파이썬 `if 조건: 식` 의 한 줄 관용구). 비어있으면 기본 상자를 반환.
    isempty(xs) && return (-1.0, 1.0, -1.0, 1.0)
    return (minimum(xs), maximum(xs), minimum(ys), maximum(ys))  # (xmin, xmax, ymin, ymax) 튜플로 반환
end

"""
    _active_travel_segments(env; min_len) -> Vector{Tuple{Vector,Vector}}

(pos2d, goal2d) for every active EntityGo (robot / transport unit) currently in
transit far enough to be worth blocking. These are the segments a no-go zone can
be dropped onto so SOME agent must actually detour.
"""
# 현재 이동 중인 활성 에이전트(로봇/운반유닛)들의 (현재위치, 목표위치) 선분 목록을 만든다.
# 함수 인자에서 `;` 뒤는 키워드 인자. min_len 은 "막을 가치가 있을 만큼 충분히 긴" 최소 이동거리 기준.
function _active_travel_segments(env; min_len::Float64 = 10 * default_robot_radius())
    # Tuple{Vector{Float64},Vector{Float64}}[] : "(실수벡터, 실수벡터) 튜플"을 담는 빈 배열 만들기.
    segs = Tuple{Vector{Float64},Vector{Float64}}[]
    for v in env.cache.active_set            # 활성 작업(노드) 집합을 순회
        n = get_node(env.sched, v).node      # 정점 v 의 노드를 가져와 그 안의 .node 필드(실제 작업)를 꺼냄
        matches_template(EntityGo, n) || continue  # `A || continue` : A 가 거짓이면 다음 반복으로. 즉 "이동(EntityGo) 작업이 아니면 건너뜀"
        p = Vector{Float64}(project_to_2d(global_transform(entity(n)).translation))  # 현재 위치(3D 변환의 평행이동분)를 2D 로 투영해 실수벡터로
        g = Vector{Float64}(project_to_2d(global_transform(goal_config(n)).translation))  # 목표 위치도 같은 방식으로 2D 화
        # norm(g .- p) : 두 점 사이 거리. `.-` 는 원소별 뺄셈(브로드캐스트). 충분히 멀면 (p,g) 선분을 목록에 추가.
        norm(g .- p) >= min_len && push!(segs, (p, g))
    end
    return segs
end

# 활성 에이전트 위치들의 무게중심(centroid)과 퍼짐 정도(중심에서 가장 먼 거리)를 구한다.
function _active_centroid(env)
    # 배열 컴프리헨션 — `[식 for 항목 in ...]` (파이썬 리스트 컴프리헨션과 동일). p[1:2] 는 앞 두 좌표(x,y)만 잘라냄.
    pts = [Vector{Float64}(p[1:2]) for (_, p) in get_active_pos(env)]
    isempty(pts) && return (nothing, 0.0)        # 점이 없으면 (중심없음, 0) 반환
    c = sum(pts) ./ length(pts)                  # 모든 점을 더해 개수로 나눔 = 평균(무게중심). `./` 는 원소별 나눗셈
    spread = maximum(norm(p .- c) for p in pts)  # 각 점에서 중심까지 거리 중 최댓값 = 퍼짐 정도
    return (c, spread)                           # (중심, 퍼짐) 튜플 반환
end

"""
    _zone_clear_of_goals(center, r, env; margin) -> Bool

True iff a zone of radius `r` at `center` does NOT overlap any staging circle.
Staging circles are the GOAL regions robots must deposit into, so a zone that
covers one would make some future goal unreachable -> the build stalls (the
deadlock seen with a naive placement). Keeping the zone clear of them yields a
detour-not-deadlock obstacle.
"""
# 반지름 r 인 구역(center 중심)이 어떤 적치원(=로봇이 물건을 내려놓을 목표 영역)과도 겹치지 않으면 true.
# 겹치면 목표가 도달 불가능해져 빌드가 멈추므로(데드락), 그 전에 걸러내기 위한 검사 함수.
function _zone_clear_of_goals(center, r, env; margin::Float64 = default_robot_radius())
    for (_, c) in env.staging_circles            # 모든 적치원을 검사
        ctr = get_center(c)                      # 적치원의 중심
        # 두 중심 거리가 (적치원 반지름 + 구역 반지름 + 여유)보다 작으면 = 겹침 → 즉시 false 반환
        norm(center .- ctr[1:2]) < get_radius(c) + r + margin && return false
    end
    return true                                  # 어떤 적치원과도 안 겹치면 true
end

"""
    random_restriction_zone!(env; key, seed, placement, radius) -> (zone, nl)

Generate ONE no-go zone placed so it ACTUALLY restricts travel, and register it.
The old "uniform inside the activity bounding box" placement frequently landed in
an empty corner the robots never crossed (no detour). Placement strategies:

- `:on_path` (default) — drop the zone onto a random active agent's (pos -> goal)
  segment, sized so the agent must route around it while its GOAL stays OUTSIDE the
  zone (so the build is detoured, not deadlocked). Guarantees a visible effect.
- `:traffic_centroid` — center on the active-agent centroid (densest traffic) with
  a spread-scaled radius and random jitter; affects many agents at once.

Falls back `:on_path -> :traffic_centroid -> bbox-center` when no segments/agents
are available. `radius` overrides the auto-size. `seed` makes it reproducible.
Returns the `Ball2` and an NL description for the respec layer.
"""
# 실제로 통행을 방해하는 위치에 통행금지 구역 1개를 생성·등록하는 함수.
# 모든 인자가 `;` 뒤의 키워드 인자(이름 붙여 호출). `Union{Nothing,Int}` = "정수 또는 없음(nothing)" 둘 다 허용.
function random_restriction_zone!(env;
        key::Symbol = :zone,                            # 등록할 구역의 키(라벨)
        seed::Union{Nothing,Int} = nothing,             # 난수 시드(주면 재현 가능, 안 주면 무작위)
        placement::Symbol = :on_path,                   # 배치 전략: :on_path(경로 위) / :traffic_centroid(군집 중심)
        radius::Union{Nothing,Real} = nothing,          # 반지름 직접 지정(없으면 자동 계산)
        max_radius::Real = 2 * default_robot_radius(),  # keep it a LOCAL obstacle, not a wall (shrunk 3->2)  # 반지름 상한(벽이 아닌 국소 장애물로 유지)
        attempts::Int = 48)                             # 적합한 위치를 찾기 위한 최대 시도 횟수
    # 삼항식 `조건 ? A : B` (파이썬 A if 조건 else B). 시드 없으면 전역 난수기, 있으면 그 시드의 난수기 생성.
    rng = seed === nothing ? Random.GLOBAL_RNG : Random.MersenneTwister(seed)
    rr = default_robot_radius()                  # 로봇 반지름(여러 크기 계산의 기준 단위)
    margin = rr + staging_buffer_radius()        # keep endpoints clear of the bloated zone  # 선분 양끝이 구역에 안 닿게 둘 여유폭
    segs = _active_travel_segments(env)          # 활성 에이전트들의 이동 선분 목록
    c0, spread = _active_centroid(env)           # 활성 위치들의 중심과 퍼짐 (튜플을 두 변수로 동시에 풀기)

    # Propose a candidate (center, r); cap the radius so a STATIC zone stays a local
    # detour obstacle instead of swallowing a goal region (which deadlocks the build).
    # 후보 (중심, 반지름)을 하나 제안하는 "내부(중첩) 함수". 바깥 함수의 변수(segs, rng 등)를 그대로 사용(클로저).
    function _candidate()
        if placement == :on_path && !isempty(segs)        # 전략이 경로 위 + 선분이 있으면
            p, g = segs[rand(rng, 1:length(segs))]        # 무작위 선분 하나 골라 (시작 p, 끝 g) 로 풀기. rand(rng, 범위) 는 범위에서 무작위 선택
            seglen = norm(g .- p)                         # 선분 길이
            frac = 0.4 + 0.2 * rand(rng)                  # 0.4..0.6 along the path  # 선분의 40~60% 지점 비율(rand 은 0~1 난수)
            center = p .+ frac .* (g .- p)                # 그 비율 지점의 좌표(p 에서 방향벡터를 frac 만큼 이동). `.+`,`.*` 는 원소별 연산
            rmax = min(frac, 1 - frac) * seglen - margin  # both endpoints stay outside  # 양끝이 구역 밖에 남게 하는 최대 반지름
            cap = min(rmax, Float64(max_radius))          # 위 상한과 max_radius 중 작은 값으로 최종 상한
            cap < 1.2 * rr && return nothing              # segment too short to place safely (floor shrunk 1.5->1.2)
            # clamp(x, lo, hi) : x 를 [lo,hi] 범위로 자름. radius 가 주어지면 그 값, 아니면 자동 계산.
            r = radius === nothing ? clamp(0.18 * seglen, 1.2 * rr, cap) : Float64(radius)  # auto-size shrunk 0.25->0.18, floor 1.5->1.2
            return (collect(center), r)                   # collect 로 일반 배열화한 중심과 반지름을 튜플로 반환
        elseif c0 !== nothing                             # 선분은 없지만 활성 중심이 있으면 (군집 중심 전략)
            jit = 0.4 * spread                            # 흔들림(jitter) 크기 = 퍼짐의 40%
            # 중심에서 ±jit 범위로 무작위 이동. (2*rand-1) 은 -1~1 사이 난수 → 양방향 흔들기.
            center = [c0[1] + (2 * rand(rng) - 1) * jit, c0[2] + (2 * rand(rng) - 1) * jit]
            r = radius === nothing ? clamp(0.15 * spread, 1.2 * rr, Float64(max_radius)) : Float64(radius)  # 자동/지정 반지름 (shrunk 0.2->0.15, floor 1.5->1.2)
            return (center, r)
        else                                              # 선분도 중심도 없으면(최후 수단) 전체 활동영역 중앙에 둠
            (xmin, xmax, ymin, ymax) = activity_bbox(env)  # 경계상자 네 값을 풀기
            return ([(xmin + xmax) / 2, (ymin + ymax) / 2],  # 상자 중앙 좌표
                    radius === nothing ? Float64(max_radius) : Float64(radius))  # 반지름은 상한 또는 지정값
        end
    end

    # Retry until a candidate is clear of every staging/goal region (so the build
    # is detoured, not deadlocked). Keep the first candidate as a last resort.
    # 어떤 목표 영역과도 안 겹치는 후보가 나올 때까지 반복 시도. 첫 후보는 "최후 수단"으로 보관.
    best = nothing
    for _ in 1:attempts                          # attempts 번 시도 (`_` = 반복변수 안 씀)
        cand = _candidate()                      # 후보 하나 제안
        cand === nothing && continue             # 제안 실패면 다음 시도로
        best === nothing && (best = cand)        # 아직 보관된 게 없으면 이 후보를 최후 수단으로 저장
        if _zone_clear_of_goals(cand[1], cand[2], env; margin = rr)  # 목표 영역들과 안 겹치면(성공)
            z = add_restriction_zone!(key, cand[1], cand[2])         # 구역 등록(cand[1]=중심, cand[2]=반지름)
            return z, restriction_zone_event(cand[1][1], cand[1][2], cand[2])  # (구역, 자연어설명) 두 값을 반환
        end
    end

    # 적합한 후보를 끝내 못 찾은 경우: 보관해둔 best(없으면 기본값)를 그냥 등록.
    center, r = best === nothing ? ([0.0, 0.0], Float64(max_radius)) : best
    # @warn : 경고 로그. `이름 = 값` 형식으로 부가 데이터(center, radius)를 함께 출력.
    @warn "[OOD] no no-go zone clear of all staging/goal regions found; zone may impede the build" center = center radius = r
    z = add_restriction_zone!(key, center, r)
    return z, restriction_zone_event(center[1], center[2], r)
end

# 통행금지 구역이 생겼다는 사실을 자연어(NL) 문장으로 만들어 respec 계층에 넘겨줄 문자열 생성 함수.
# `*` 는 문자열 이어붙이기(파이썬의 `+`). `$(...)` 는 문자열 안에 식의 값을 끼워넣기. round(x; digits=2) 는 소수 2자리 반올림.
restriction_zone_event(cx, cy, r) =
    "A safety exclusion zone is now active, centered near " *
    "($(round(cx; digits=2)), $(round(cy; digits=2))) with radius " *
    "$(round(r; digits=2)); robots must not enter or pass through it."

# -----------------------------------------------------------------------------
# Minimal marker so a no-go zone is VISIBLE in the MeshCat render (so the detour
# can be confirmed by eye). This is the smallest useful OOD-1-2 visual; the full
# Piece-3 visualization (fault/hold/reassign overlays) is separate.
# -----------------------------------------------------------------------------

# 이미 시각화기에 그려진 구역 키들의 집합(같은 마커를 두 번 그리지 않기 위함). Set = 중복 없는 모음.
const _DRAWN_ZONE_MARKERS = Ref(Set{Symbol}())
# 그려진 마커 기록을 비우기(다시 그릴 수 있게 초기화).
clear_zone_markers!() = (empty!(_DRAWN_ZONE_MARKERS[]); nothing)

"""
    draw_restriction_zones!(vis)

Draw a translucent red disc (flat cylinder) for each active restriction zone into
MeshCat `vis` under `ood_zones/<key>`, once per zone. Mirrors
`render_staging_areas!`. Called every step from `visualizer_update_function!`, so a
zone injected mid-sim appears as soon as it exists. No-op when `vis === nothing`.
"""
# 활성 통행금지 구역들을 MeshCat 시각화기에 "반투명 빨간 원반"(납작한 원기둥)으로 그린다.
function draw_restriction_zones!(vis)
    vis === nothing && return nothing            # 시각화기가 없으면(헤드리스 실행) 아무것도 안 함
    isempty(RESTRICTION_ZONES[]) && return nothing  # 그릴 구역이 없으면 종료
    drawn = _DRAWN_ZONE_MARKERS[]                # 이미 그린 키 집합
    zone_vis = vis["ood_zones"]                  # 시각화 트리에서 "ood_zones" 하위 경로(폴더 같은 개념)
    for (key, ball) in active_restriction_zones()  # 각 구역의 (키, 원)에 대해
        key in drawn && continue                 # 이미 그린 키면 건너뜀(한 번만 그리기)
        ctr = get_center(ball); r = get_radius(ball)  # 원의 중심과 반지름
        top = Point(ctr[1], ctr[2], 0.03)        # 원반의 윗면 중심점(z=+0.03, 아주 얇게)
        bot = Point(ctr[1], ctr[2], -0.03)       # 원반의 아랫면 중심점(z=-0.03)
        # setobject! : 시각화기에 3D 물체를 올림. Cylinder(위,아래,반지름) 로 납작한 원기둥 생성.
        # RGBA{Float32}(1,0,0,0.35) : 빨강(R=1) + 투명도 0.35(반투명).
        setobject!(zone_vis[string(key)], Cylinder(top, bot, r),
                   MeshLambertMaterial(color = RGBA{Float32}(1, 0, 0, 0.35)))
        push!(drawn, key)                        # 그렸다고 기록
    end
    return nothing
end

# -----------------------------------------------------------------------------
# OOD 1-1 :: directional spare robot pools (backup robots for fault replacement)
#
# A spare pool is a cluster of IDLE robots parked at one of the four cardinal
# sides of the build area. They carry NO task assignment (a free RobotStart ->
# RobotGo node only). On a robot fault the NEAREST pool donates one spare whose
# empty task chain ADOPTS the faulted robot's remaining chain (1:1 hand-off, see
# replace_robot.jl) -- structurally side-stepping the reassignment double-booking
# (docs/resume_fulloop_status_2026-06-24.md). Module-level (NOT on PlannerEnv) so
# the env struct stays immutable; mirrors RESTRICTION_ZONES / RESPEC_* refs.
# -----------------------------------------------------------------------------

# 방위별(:north/:east/:south/:west) "미사용 예비 로봇 id" 목록. zone 의 RESTRICTION_ZONES 와 같은
# module-level Ref 패턴(PlannerEnv 불변 유지). 키=방위 라벨(Symbol), 값=그 풀의 RobotID 벡터.
const SPARE_POOLS = Ref(Dict{Symbol,Vector{RobotID}}())
# 각 풀의 중심 좌표(거리 계산 = 가장 가까운 풀 선택에 사용). 키=방위, 값=2D 중심 [x,y].
const SPARE_POOL_CENTERS = Ref(Dict{Symbol,Vector{Float64}}())

# 상자 안 딕셔너리를 그대로 돌려주는 한 줄 접근자(zone 의 restriction_zones() 와 동형).
spare_pools() = SPARE_POOLS[]
spare_pool_centers() = SPARE_POOL_CENTERS[]
# 두 저장소를 모두 비우기(데모/테스트 사이 초기화). `(A; B; C)` 는 차례로 실행 후 마지막 값을 반환.
# repository(창고) 부가 상태(DEPOT_INFO/decommissioned/checked-out)도 함께 초기화 — 정의는 아래(late-bound).
clear_spare_pools!() = (empty!(SPARE_POOLS[]); empty!(SPARE_POOL_CENTERS[]);
                        empty!(DEPOT_INFO[]); empty!(DECOMMISSIONED_BODIES[]);
                        empty!(CHECKED_OUT_SPARES[]); empty!(HOT_SWAP_ASSETS[]); nothing)

"""
    register_spare!(key, rid) -> RobotID

Register spare robot `rid` under directional pool `key` (creates the pool vector
on first use). `get!(dict, k, default)` returns the existing value for `k` or
inserts and returns `default` — so the first spare for a side seeds its vector.
"""
# get!(딕셔너리, 키, 기본값) : 키가 있으면 그 값을, 없으면 기본값(여기선 빈 RobotID 벡터)을 넣고 돌려줌.
# 그 벡터 끝에 rid 를 push! → 같은 방위의 예비 로봇들이 한 벡터에 쌓임.
function register_spare!(key::Symbol, rid::RobotID)
    push!(get!(SPARE_POOLS[], key, RobotID[]), rid)
    return rid
end

# 모든 풀에 남아있는 예비 로봇 id 를 한 평평한 벡터로(이중 컴프리헨션: 각 풀 벡터 v 의 각 원소 r).
active_spares() = RobotID[r for v in values(SPARE_POOLS[]) for r in v]

"""
    is_spare(rid) -> Bool

`rid` 가 현재 어느 방위 예비 풀에든 등록된 예비 로봇인지. `SPARE_POOLS` 는 pop_spare! 로
소비되면 그 풀에서 제거되므로, 이 술어는 "아직 인계에 안 쓰인 예비"만 true. 초기 task 배정에서
예비 로봇을 후보에서 빼는 데 씀(assign_collaborative_tasks!) — 스페어를 '진짜 idle' 로 남겨
replace_robot! 의 free 노드 double-book 을 원천 차단. RobotID 가 아니면 false.
"""
is_spare(rid) = (rid isa RobotID) && any(rid in v for v in values(SPARE_POOLS[]))

"""
    pop_spare!(key) -> Union{RobotID,Nothing}

Remove and return one unused spare id from pool `key` (LIFO). `nothing` if the
pool is empty or absent — the caller (`replace_robot!` dispatch) then treats it as
"no backup available" and engages the safe fallback.
"""
# 풀 key 에서 예비 로봇 하나를 꺼내며 제거(pop! = 맨 뒤 원소 제거 후 반환). 없으면 nothing.
function pop_spare!(key::Symbol)
    haskey(SPARE_POOLS[], key) || return nothing   # 그런 풀이 없으면 없음
    v = SPARE_POOLS[][key]
    isempty(v) && return nothing                   # 풀은 있으나 비었으면 없음
    return pop!(v)                                 # 하나 꺼내 반환(그 풀에서 영구 제거)
end

"""
    pool_centers(bbox; margin) -> Dict{Symbol,Vector{Float64}}

The four cardinal pool centers placed `margin` OUTSIDE activity bounding box
`bbox == (xmin,xmax,ymin,ymax)`: north/south offset in +y/-y, east/west in +x/-x.
Used both to position the parked spares and to score `nearest_pool`.
"""
# 함수 인자에서 튜플을 바로 분해(destructuring): bbox 의 네 값을 xmin..ymax 로 풀어 받음.
# `; margin` 뒤는 키워드 인자. 활동영역 경계상자 바깥쪽 margin 만큼에 4방위 중심을 둠.
function pool_centers((xmin, xmax, ymin, ymax); margin::Real)
    cx = (xmin + xmax) / 2; cy = (ymin + ymax) / 2   # 경계상자 중심
    m = Float64(margin)
    return Dict(
        :north => [cx, ymax + m],   # 북: 위쪽(+y)
        :south => [cx, ymin - m],   # 남: 아래쪽(-y)
        :east  => [xmax + m, cy],   # 동: 오른쪽(+x)
        :west  => [xmin - m, cy])   # 서: 왼쪽(-x)
end

"""
    nearest_pool(pos; nonempty=true) -> Union{Symbol,Nothing}

The pool key whose center is closest to 2D `pos`. With `nonempty` (default), only
pools that still hold an available spare are considered — so the returned key is
directly poppable by `pop_spare!`. `nothing` if no eligible pool exists.
"""
# 위치 pos(고장 지점)에서 가장 가까운 풀의 키를 반환. nonempty=true 면 "예비가 남은 풀"만 후보.
function nearest_pool(pos; nonempty::Bool = true)
    p = Float64[pos[1], pos[2]]                      # x,y 만 추려 2D 점으로
    best = nothing; bestd = Inf                      # 최선 키와 그 거리(처음엔 무한대)
    for (key, c) in SPARE_POOL_CENTERS[]             # 각 풀 중심을 검사
        # nonempty 면, 그 풀에 남은 예비가 없으면 후보에서 제외(get 으로 없는 키도 안전 처리).
        nonempty && isempty(get(SPARE_POOLS[], key, RobotID[])) && continue
        d = norm(p .- c[1:2])                        # 중심까지 거리
        d < bestd && (bestd = d; best = key)         # 더 가까우면 갱신
    end
    return best                                      # 가장 가까운(예비 남은) 풀 키 또는 nothing
end

# 씬트리에 이미 있는 로봇들의 위치를 둘러싸는 2D 경계상자(예비 풀을 빌드 영역 바깥에 두기 위함).
function _scene_robot_bbox(scene_tree)
    xs = Float64[]; ys = Float64[]
    for node in get_nodes(scene_tree)                # 씬트리의 모든 노드 순회
        matches_template(RobotNode, node) || continue  # 로봇 노드가 아니면 건너뜀
        t = global_transform(node).translation       # 그 로봇의 전역 위치(평행이동분)
        push!(xs, t[1]); push!(ys, t[2])
    end
    isempty(xs) && return (-1.0, 1.0, -1.0, 1.0)      # 로봇이 없으면 기본 상자
    return (minimum(xs), maximum(xs), minimum(ys), maximum(ys))
end

"""
    add_directional_spare_pools!(scene_tree; n_spare, bbox, margin, geom, spacing) -> Dict

Add `n_spare` IDLE backup robots at each of the four cardinal pool centers
(N/E/S/W), placed `margin` outside `bbox` (default: a box around the existing
robots). Mirrors `add_robots_to_scene!` (construction_schedule.jl) but CAPTURES
each new `RobotID` and registers it into `SPARE_POOLS[key]` (and records the pool
center). Returns the per-key id vectors.

IMPORTANT: call BEFORE `set_robot_start_configs!` so each spare automatically gets
a free `RobotStart -> RobotGo` with NO task assignment. To keep spares idle through
the INITIAL plan, either add them after the initial assignment solve or exclude
their free->slot edges from that solve (wired in the A1b integration step).
"""
# 4방위에 각 n_spare 대의 예비 로봇을 씬트리에 추가하고, 생성된 RobotID 를 방위별 풀에 등록한다.
# add_robots_to_scene!(construction_schedule.jl:1519) 와 같은 방식이되, "만든 id 를 붙잡아" 풀에 넣는 게 핵심.
function add_directional_spare_pools!(scene_tree;
        n_spare::Int = 2,                                  # 방위당 예비 로봇 수
        bbox = nothing,                                    # 경계상자(없으면 기존 로봇 범위로 자동)
        margin::Real = 6 * default_robot_radius(),         # 빌드영역 바깥으로 띄울 거리
        geom = default_robot_geom(),                       # 예비 로봇 형상(기본 로봇 형상)
        spacing::Real = 3 * default_robot_radius())        # 클러스터 내 로봇 간격
    centers = pool_centers(bbox === nothing ? _scene_robot_bbox(scene_tree) : bbox; margin = margin)
    out = Dict{Symbol,Vector{RobotID}}()                   # 방위 → 만든 id 들(반환용)
    for (key, c) in centers                                # 4방위 각각에 대해
        ids = RobotID[]
        for i in 1:n_spare                                 # 그 풀에 n_spare 대 배치
            off = (i - (n_spare + 1) / 2) * Float64(spacing)  # 클러스터를 x축 따라 중앙정렬로 한 줄 배치
            pos = [c[1] + off, c[2]]
            rid = get_unique_id(RobotID)                   # 새 고유 로봇 id 발급
            node = add_node!(scene_tree, RobotNode(rid, GeomNode(geom)))  # 씬트리에 로봇 노드 추가
            # (x,y,0) 평행이동 변환을 만들어 로봇을 그 위치에 둠(add_robots_to_scene! 와 동일 형식).
            tform = CoordinateTransformations.Translation(pos[1], pos[2], 0.0) ∘ identity_linear_map()
            set_local_transform!(node, tform)
            push!(ids, rid)
            register_spare!(key, rid)                      # 이 방위 풀에 등록
        end
        SPARE_POOL_CENTERS[][key] = Vector{Float64}(c)     # 풀 중심 기록(nearest_pool 용)
        # repository 시각화용 패드 크기 기록: n_spare 대가 spacing 간격으로 x축에 한 줄 배치되므로
        # 그 클러스터를 감싸는 반폭(halfw)/반깊이(halfd)를 함께 저장. draw_spare_depots! 가 소비.
        rr = default_robot_radius()
        halfw = ((n_spare - 1) / 2) * Float64(spacing) + 2 * rr
        halfd = 2 * rr
        DEPOT_INFO[][key] = (capacity = n_spare, halfw = Float64(halfw), halfd = Float64(halfd))
        out[key] = ids
    end
    return out
end

# -----------------------------------------------------------------------------
# OOD 1-1 :: SPARE ROBOT REPOSITORY (first-class depot model + visualization)
#
# The directional spare pools above are physical RobotNodes parked N/E/S/W. This
# section makes the "repository" a FIRST-CLASS, VISIBLE station and adds the
# identity-preserving hot-swap bookkeeping the scene-tree refinement consumes
# (replace_robot.jl `hot_swap_robot!`):
#   * DEPOT_INFO         — per-side capacity + pad half-extents (for the visual).
#   * DECOMMISSIONED_BODIES — faulted robot id -> 2D spot where its greyed "retired"
#                          marker sits (so a swap visibly leaves the broken unit behind).
#   * CHECKED_OUT_SPARES — spare body ids dispatched out of a depot (their parked
#                          bodies are teleported off-grid, so depot inventory visibly drops).
# All module-level Refs (PlannerEnv stays immutable), mirroring RESTRICTION_ZONES.
# -----------------------------------------------------------------------------
# [한국어] OOD 1-1 :: 예비 로봇 창고(repository) — 위 방위별 풀을 "눈에 보이는 정식 정거장"으로 승격.
#   정체성 보존(identity-preserving) hot-swap(고장 로봇의 id 는 유지한 채 본체만 창고 것으로 교체)에
#   필요한 장부 3종을 둔다:
#     * DEPOT_INFO          — 방위별 창고 용량 + 시각화 패드 크기.
#     * DECOMMISSIONED_BODIES — 고장으로 은퇴한 로봇 id → 그 회색 "은퇴" 마커를 둘 2D 위치.
#     * CHECKED_OUT_SPARES  — 창고 밖으로 반출된 예비 본체 id(본체는 화면 밖으로 치워 재고가 준 듯 보이게).
#   전부 module-level Ref(PlannerEnv 불변 유지, RESTRICTION_ZONES 패턴 동일).

# 방위별 창고 메타데이터(용량 + 시각화 패드 반경). add_directional_spare_pools! 가 채움.
const DEPOT_INFO = Ref(Dict{Symbol,NamedTuple}())
# 교체로 은퇴(고장)한 로봇 id -> 그 회색 마커를 둘 2D 위치.
const DECOMMISSIONED_BODIES = Ref(Dict{AbstractID,Vector{Float64}}())
# 창고에서 반출(dispatch)된 예비 로봇 본체 id 들(본체는 화면 밖으로 치워 재고가 준 것처럼 보이게).
const CHECKED_OUT_SPARES = Ref(Set{AbstractID}())
const HOT_SWAP_ASSETS = Ref(Dict{AbstractID,Any}())

# 세 장부(창고 메타/은퇴 본체/반출 예비)를 그대로 돌려주는 한 줄 접근자들.
depot_info() = DEPOT_INFO[]
decommissioned_bodies() = DECOMMISSIONED_BODIES[]
checked_out_spares() = CHECKED_OUT_SPARES[]
hot_swap_assets() = HOT_SWAP_ASSETS[]
# 방위 key 창고에 남은 예비 재고 수(= 풀 벡터 길이).
depot_available(key::Symbol) = length(get(SPARE_POOLS[], key, RobotID[]))

# --- hot-swap dispatch flag (identity-preserving replacement path) -------------
# When ON, the ReplaceAgent dispatch (replan.jl) routes to the SCENE-TREE hot-swap
# (`hot_swap_robot!`) instead of the schedule re-stamp (`replace_robot!`). OFF by
# default so existing demos/tests keep the proven re-stamp path (A/B toggle).
# [한국어] hot-swap 켬/끔 플래그. ON 이면 ReplaceAgent 대응이 스케줄 재각인(replace_robot!) 대신
#          씬트리 hot-swap(hot_swap_robot!, id 유지 교체)으로 감. 기존 데모 호환 위해 기본 OFF(A/B 토글).
const HOT_SWAP_REPLACE = Ref(false)
# hot-swap 방식: :via_depot(창고에서 새 본체를 몰고 옴) | :in_place(그 자리에서 즉시 치유).
const HOT_SWAP_MODE    = Ref(:via_depot)   # :via_depot (route from repository) | :in_place (heal where it stands)
# 현재 hot-swap 이 켜져 있는지 알려주는 한 줄 술어.
hot_swap_enabled() = HOT_SWAP_REPLACE[]

# How far the spare depots sit OUTSIDE the build's bounding box, in units of robot_radius
# (full_demo.jl multiplies this by robot_radius for `add_directional_spare_pools!`'s margin).
# Bigger => depots parked farther from the build, so a hot-swap visibly drives in from afar.
# [한국어] 창고를 빌드 영역 바깥으로 얼마나 띄울지(로봇 반지름 배수). 값이 클수록 창고가 멀리 놓여,
#          hot-swap 때 예비가 멀리서 몰고 들어오는 게 눈에 보임.
const SPARE_POOL_MARGIN_FACTOR = Ref(6.0)
# 위 배수를 바꾸는 세터(`!`=전역 수정). Float64 로 변환해 저장.
set_spare_pool_margin!(factor::Real) = (SPARE_POOL_MARGIN_FACTOR[] = Float64(factor); nothing)

# How many CONSECUTIVE no-progress steps before the self-healing "team deadlocked" OOD
# fires (demo_utils.jl). The old hard-coded 2000 (~50 s at dt=1/40) is why a post-swap team
# wedge sat idle for ~a minute before reform kicked in. A small value makes the adaptive
# controller REACT FAST (a wedge is caught in ~a second) — reform is a safe no-op when there is
# nothing to reform, so a low interval just tightens the latency. Default 2000 (unchanged for
# other demos); the stall/replace demo sets it low.
# [한국어] 자가치유 "팀 교착(team deadlocked)" OOD 가 발동하기까지 필요한 "진전 없음" 연속 스텝 수.
#          작을수록 교착을 빨리 잡아 적응 컨트롤러가 즉각 반응(reform 은 교착이 없으면 안전한 no-op).
const REFORM_INTERVAL = Ref(2000)
# 위 임계값을 바꾸는 세터(최소 1 로 하한).
set_reform_interval!(n::Integer) = (REFORM_INTERVAL[] = max(1, Int(n)); nothing)

"""
    maybe_emit_reform_ood!(no_progress::Integer) -> Bool

Emit the self-healing "transport team deadlocked" OOD (→ ReformTeam) when a SUSTAINED wedge is
detected: `no_progress` consecutive no-progress steps crossing `REFORM_INTERVAL`. This is the
SECOND-ORDER OOD of a spare hand-off (a multi-robot transport team can't finish forming after a
Replace). Factored out of the inline `demo_utils.jl` loop so that BOTH the LLM full-sim loop AND the
RL event-triggered env can emit team-deadlock into the SAME respec queue — keeping the LLM-vs-RL
comparison symmetric (both controllers receive the 4th OOD identically; see
`decpomdp/docs/EVENT_MDP_DESIGN.md` §4). RESPEC-gated (a true no-op unless the respec hook is
enabled) and safe (reform is a verified no-op when nothing is actually wedged). Returns `true` iff an
event was enqueued.
"""
# 진전 없는 스텝이 REFORM_INTERVAL 을 넘기면 "팀 교착" OOD(→ ReformTeam)를 respec 큐에 넣는다. 넣었으면 true.
function maybe_emit_reform_ood!(no_progress::Integer)
    RESPEC_ENABLED[] || return false                                   # respec 꺼져 있으면 아무 일도 안 함(진짜 no-op)
    (no_progress > 0 && no_progress % REFORM_INTERVAL[] == 0) || return false  # 간격의 배수(=임계 도달)일 때만 발동
    # push_ood! : 자연어 이벤트를 respec 큐에 예약(LLM·RL 컨트롤러가 동일 큐로 4번째 OOD 를 똑같이 받게 함).
    push_ood!("A multi-robot transport team is deadlocked while forming: " *
              "some members are waiting in their carrying positions but the team cannot complete and " *
              "the build has stalled. Re-establish the stuck transport team(s).")
    return true
end
"""
    set_hot_swap!(; enabled=true, mode=:via_depot)

Toggle the identity-preserving scene-tree hot-swap replacement path. `mode`:
`:via_depot` (broken robot's stable id re-homes to the repository and drives back
out) or `:in_place` (healed where it stands). A robot faulted MID-CARRY is always
healed in place (never disband a formed transport unit), regardless of `mode`.
"""
# 정체성 보존 hot-swap 경로를 한 번에 켜고(mode 까지) 설정하는 편의 세터. 모든 인자는 키워드.
set_hot_swap!(; enabled::Bool = true, mode::Symbol = :via_depot) =
    (HOT_SWAP_REPLACE[] = enabled; HOT_SWAP_MODE[] = mode; nothing)

# --- repository VISUALIZATION (mirrors draw_restriction_zones!) ----------------
# 이미 그린 창고 마커 키 집합(같은 창고를 두 번 그리지 않게). draw_restriction_zones! 의 마커 기록과 동형.
const _DRAWN_DEPOT_MARKERS = Ref(Set{Symbol}())
# 창고 마커 기록 비우기(다시 그릴 수 있게 초기화).
clear_depot_markers!() = (empty!(_DRAWN_DEPOT_MARKERS[]); nothing)

"""
    draw_spare_depots!(vis)

Draw a visible repository STATION for each active spare pool into MeshCat `vis`
under `vis["spare_depot"][<key>]`, once per side: a translucent blue floor PAD
enclosing the parked spare cluster plus four corner POSTS so it reads as a rack /
depot (distinct from the red no-go zones and magenta staging discs). Called every
step from `visualizer_update_function!`, so depots appear as soon as spares exist.
No-op when `vis === nothing`.
"""
# 활성 예비 풀마다 창고 "정거장"을 MeshCat 에 그린다(반투명 파란 바닥 패드 + 네 모서리 기둥).
function draw_spare_depots!(vis)
    vis === nothing && return nothing                  # 시각화기 없으면(헤드리스) 그냥 종료
    isempty(SPARE_POOL_CENTERS[]) && return nothing    # 그릴 창고가 없으면 종료
    drawn = _DRAWN_DEPOT_MARKERS[]                      # 이미 그린 창고 키 집합
    depot_vis = vis["spare_depot"]                     # 시각화 트리의 "spare_depot" 하위 경로
    pad_col  = RGBA{Float32}(0.20, 0.55, 0.95, 0.45)   # translucent steel-blue pad (bright enough to spot)  # 반투명 강청색 바닥
    post_col = RGBA{Float32}(0.10, 0.40, 0.95, 0.95)   # solid posts  # 불투명 기둥
    rr = default_robot_radius()                        # 로봇 반지름(크기 계산 기준)
    for (key, c) in SPARE_POOL_CENTERS[]               # 각 방위 창고(키, 중심)에 대해
        key in drawn && continue                       # 이미 그린 창고면 건너뜀(한 번만)
        # get 으로 DEPOT_INFO 조회, 없으면 기본 크기 사용. info.halfw/halfd = 패드 반폭/반깊이.
        info = get(DEPOT_INFO[], key, (capacity = 1, halfw = 3 * rr, halfd = 2 * rr))
        hw = info.halfw; hd = info.halfd
        g = depot_vis[string(key)]                     # 이 창고의 시각화 하위 경로
        # HyperRectangle(모서리, 크기벡터) 로 납작한 바닥 패드(높이 0.04)를 만들어 올림.
        setobject!(g["pad"],
            GeometryBasics.HyperRectangle(
                GeometryBasics.Vec(Float64(c[1] - hw), Float64(c[2] - hd), -0.02),
                GeometryBasics.Vec(Float64(2hw), Float64(2hd), 0.04)),
            MeshLambertMaterial(color = pad_col))
        ph = 6 * rr                                    # 기둥 높이
        for (sx, sy) in ((-1, -1), (-1, 1), (1, -1), (1, 1))  # 네 모서리 부호(±1) 조합 순회
            px = c[1] + sx * hw; py = c[2] + sy * hd    # 각 모서리 좌표
            # 얇은 세로 원기둥(기둥)을 각 모서리에 세워 "선반/창고"처럼 보이게.
            setobject!(g["post_$(sx)_$(sy)"],
                Cylinder(Point(px, py, 0.0), Point(px, py, ph), 0.35 * rr),
                MeshLambertMaterial(color = post_col))
        end
        push!(drawn, key)                              # 그렸다고 기록
    end
    return nothing
end

# 이미 그린 "은퇴(고장) 로봇" 마커 id 집합(중복 방지). AbstractID = id 종류 아무거나.
const _DRAWN_DECOMMISSIONED = Ref(Set{AbstractID}())
# 은퇴 로봇 마커 기록 비우기.
clear_decommissioned_markers!() = (empty!(_DRAWN_DECOMMISSIONED[]); nothing)

"""
    draw_decommissioned_robots!(vis)

Draw a dark-grey "retired" disc where each hot-swapped (decommissioned) robot broke
down, under `vis["decommissioned"][<id>]`, once each — so a via-depot swap visibly
leaves the broken unit behind while a fresh one drives out of the repository. No-op
when `vis === nothing`. Called every step beside `draw_spare_depots!`.
"""
# hot-swap 으로 은퇴한(고장난) 각 로봇이 무너진 자리에 빨간 "여기서 고장" 원반+핀을 그린다.
function draw_decommissioned_robots!(vis)
    vis === nothing && return nothing                  # 시각화기 없으면 종료
    isempty(DECOMMISSIONED_BODIES[]) && return nothing # 은퇴 기록이 없으면 종료
    drawn = _DRAWN_DECOMMISSIONED[]                    # 이미 그린 id 집합
    dv = vis["decommissioned"]                         # 시각화 트리의 "decommissioned" 하위 경로
    rr = default_robot_radius()
    disc_col = RGBA{Float32}(0.85, 0.10, 0.10, 0.85)   # red "faulted here" disc  # 빨간 "여기서 고장" 원반
    post_col = RGBA{Float32}(0.85, 0.10, 0.10, 0.95)   # a tall red pin so the fault spot is unmissable  # 눈에 띄는 긴 빨간 핀
    for (id, p) in DECOMMISSIONED_BODIES[]             # (은퇴 로봇 id, 고장 2D 위치) 순회
        id in drawn && continue                        # 이미 그렸으면 건너뜀
        g = dv[string(id)]                             # 이 로봇의 시각화 하위 경로
        # 납작한 빨간 원반(바닥 표식)을 고장 위치 (p[1],p[2]) 에 올림.
        setobject!(g["disc"],
            Cylinder(Point(p[1], p[2], 0.02), Point(p[1], p[2], 0.06), 1.4 * rr),
            MeshLambertMaterial(color = disc_col))
        # 그 위에 높이 8*rr 의 가느다란 빨간 핀을 세워 위치를 멀리서도 보이게.
        setobject!(g["pin"],
            Cylinder(Point(p[1], p[2], 0.0), Point(p[1], p[2], 8 * rr), 0.25 * rr),
            MeshLambertMaterial(color = post_col))
        # A persistent red robot-sized body marks the retired physical asset.
        # The replacement drives away under its own spare id in monitor output.
        setobject!(g["body"],
            Cylinder(Point(p[1], p[2], 0.03), Point(p[1], p[2], default_robot_height()), rr),
            MeshLambertMaterial(color = RGBA{Float32}(1.0, 0.05, 0.05, 0.9)))
        push!(drawn, id)                               # 그렸다고 기록
    end
    return nothing
end

# -----------------------------------------------------------------------------
# OOD 1-1 :: physical robot FAULT injection (the "generate an OOD" action)
#
# Faults a robot mid-sim: records it as faulted, drops a static obstacle on its
# body (so other agents detour around the dead robot, mirroring a no-go zone), and
# returns the NL event that drives the respec layer (-> ReplaceAgent -> spare
# hand-off). The schedule-side removal of the faulted robot from future driving is
# done by `replace_robot!` (it re-stamps the robot's productive nodes to the spare);
# this front-end only injects the PHYSICAL fault + NL.
# -----------------------------------------------------------------------------
# [한국어] OOD 1-1 :: 물리적 로봇 고장 주입("OOD 생성" 액션). 시뮬레이션 도중 로봇 하나를 고장내고,
#   (1) 고장으로 기록하고 (2) 그 자리에 정적 장애물을 얹어 다른 로봇이 우회하게 하고
#   (3) respec 레이어를 구동할 자연어(NL) 이벤트를 반환한다(→ ReplaceAgent → 예비 인계).
#   스케줄에서 고장 로봇을 실제로 빼는 일은 replace_robot! 이 함(이 front-end 는 물리 고장 + NL 만 주입).

# 현재 "고장난" 로봇들을 기록(로봇 id → 고장 당시 2D 위치). 다른 곳에서 조회/시각화에 쓸 수 있게 module-level.
const FAULTED_ROBOTS = Ref(Dict{RobotID,Vector{Float64}}())
faulted_robots() = FAULTED_ROBOTS[]
clear_faulted_robots!() = (empty!(FAULTED_ROBOTS[]); nothing)

# Recovery spares in use (donated to replace a faulted robot). A spare adopts a faulted
# robot's tasks OUT OF ORDER and must traverse a now-congested late build, so it can RVO-
# gridlock (proposal V5). Marking it lets `set_rvo_priority!` (route_planning.jl) give it a
# higher RVO priority (lower alpha) so other robots yield and it cuts through to finish the
# hand-off. Empty in nominal/baseline runs, so priority is unchanged there.
# [한국어] 현재 "복구 임무 중"인 예비 로봇들의 집합. 고장 로봇 일을 넘겨받은 예비는 붐비는 후반부를
#          역주행하듯 통과해야 해 RVO 교착이 나기 쉬움 → 이 표식이 있으면 set_rvo_priority! 가
#          더 높은 RVO 우선순위(낮은 alpha)를 줘 다른 로봇이 양보하게 함. 평상시/baseline 에선 빈 집합.
const RECOVERY_SPARES = Ref(Set{RobotID}())
# 복구 중 예비 집합을 그대로 반환.
recovery_spares() = RECOVERY_SPARES[]
# 예비 id 를 "복구 중"으로 표시(집합에 추가).
mark_recovery_spare!(id::RobotID) = (push!(RECOVERY_SPARES[], id); nothing)
# id 가 복구 중 예비인지 술어(RobotID 가 아니면 false).
is_recovery_spare(id) = (id isa RobotID) && (id in RECOVERY_SPARES[])
# 복구 중 예비 기록 비우기.
clear_recovery_spares!() = (empty!(RECOVERY_SPARES[]); nothing)

# 로봇 agent 의 2D 위치(씬트리 본체). 못 읽으면 원점. (replan.jl 의 _robot_position_2d 와 같은 의도, 생성기 쪽 복제.)
function _ood_robot_pos2d(env, agent::RobotID)
    try
        t = global_transform(get_node(env.scene_tree, agent)).translation
        return Float64[t[1], t[2]]
    catch
        return Float64[0.0, 0.0]
    end
end

# 현재 이동/운반 작업 중인(=시각적으로 고장이 드러나는) 로봇 하나를 고른다. 없으면 아무 RobotGo 의 로봇.
function _pick_active_robot(env)
    sched = env.sched
    # (0) PREFER a robot that still has a PENDING frontier (non-closed downstream work). A fault on such
    #     a robot is CONSEQUENTIAL — NOOP permanently loses that work (the build can't complete), while
    #     Replace hands it to a spare. A fault on an ALREADY-DONE robot is a no-op either way, which
    #     makes adaptation look irrelevant (the whole point of the OOD comparison). `_first_pending_
    #     assignment` is the exact frontier test replace_robot! uses; late-bound (loaded later). Falls
    #     through to the original active/any pick if none has a frontier.
    # [한국어] (0) 아직 "남은 할 일(frontier)"이 있는 로봇을 우선 고름. 그런 로봇의 고장은 결과가 큼
    #          (NOOP 이면 그 일이 영영 사라져 빌드가 못 끝남; Replace 면 예비가 넘겨받음) → OOD 비교의 핵심.
    for v in env.cache.active_set
        node = get_node_from_id(sched, get_vtx_id(sched, v))
        node isa RobotGo || continue                          # RobotGo 노드가 아니면 건너뜀
        rid = try entity(node).id catch; nothing end          # 그 노드의 로봇 id(실패 시 nothing)
        rid isa RobotID || continue
        # _first_pending_assignment 가 nothing 이 아니면 = 남은 할 일이 있음 → 이 로봇을 고장 대상으로 반환.
        (try _first_pending_assignment(env, rid) !== nothing catch; false end) && return rid
    end
    for v in env.cache.active_set                         # 진행중 작업부터(가장 자연스러운 고장 대상)
        node = get_node_from_id(sched, get_vtx_id(sched, v))
        node isa RobotGo || continue
        rid = try entity(node).id catch; nothing end
        rid isa RobotID && return rid
    end
    for v in Graphs.vertices(sched)                       # 폴백: 임의의 RobotGo 로봇
        node = get_node_from_id(sched, get_vtx_id(sched, v))
        node isa RobotGo || continue
        rid = try entity(node).id catch; nothing end
        rid isa RobotID && return rid
    end
    return nothing
end

"""
    pick_solo_fault_target(env) -> Union{RobotID,Nothing}

A SAFE fault target: an active `RobotGo` robot with a pending assignment whose remaining transport
tasks are ALL solo (team size 1). Faulting such a robot never trips `has_edge(scene_tree, agent,
robot_id)` in `FormTransportUnit.apply_cmd!` (which happens when a robot that is a co-carrier of an
ACTIVE multi-robot transport unit is replaced). Returns the lowest-id candidate for determinism, or
`nothing` if none is available yet (caller should defer to a later trigger). Shared by the demos and
the headless completing comparison. `_first_pending_assignment` is late-bound (replace_robot.jl).
"""
# 안전한 고장 대상 고르기(엄격판): 남은 운반 작업이 전부 단독(solo, 팀 크기 1)인 활성 RobotGo 로봇.
# 이런 로봇을 고장내면 FormTransportUnit 의 has_edge 단정문을 절대 건드리지 않음. 없으면 nothing.
function pick_solo_fault_target(env)
    sched = env.sched
    # rid 가 낀(멤버인) 미완료 FormTransportUnit 팀들의 크기 목록을 만드는 내부 함수(컴프리헨션+조건절).
    team_sizes(rid) = [length(robot_team(entity(get_node_from_id(sched, get_vtx_id(sched, v)))))
        for v in Graphs.vertices(sched)
        if !(v in env.cache.closed_set) &&                                # 아직 안 끝난 노드이고
           get_node_from_id(sched, get_vtx_id(sched, v)) isa FormTransportUnit &&  # 운반팀 형성 노드이고
           (try haskey(robot_team(entity(get_node_from_id(sched, get_vtx_id(sched, v)))), rid) catch; false end)]  # 그 팀에 rid 가 속함
    cands = RobotID[]                                # 후보 로봇들
    for v in env.cache.active_set                    # 활성 노드 순회
        node = get_node_from_id(sched, get_vtx_id(sched, v))
        node isa RobotGo || continue                 # RobotGo 만 대상
        rid = try entity(node).id catch; nothing end
        rid isa RobotID || continue
        # never fault a robot already doing recovery work (a spare handed a Replace) — faulting it
        # mid-hand-off re-tangles the schedule and can trip has_edge on a later multi-fault.
        (try is_recovery_spare(rid) catch; false end) && continue   # 복구 중 예비는 절대 고장내지 않음
        (try _first_pending_assignment(env, rid) !== nothing catch; false end) || continue  # 남은 할 일 없으면 제외
        s = team_sizes(rid)                          # 이 로봇이 낀 팀 크기들
        (!isempty(s) && all(==(1), s)) && push!(cands, rid)  # 팀이 있고 모두 크기 1(단독)이면 후보에 추가
    end
    isempty(cands) && return nothing                 # 후보 없으면 없음(나중 트리거로 미룸)
    return sort(cands, by = r -> r.id)[1]            # 재현성 위해 id 가장 작은 후보 반환
end

"""
    pick_solo_frontier_target(env) -> Union{RobotID,Nothing}

A SAFE fault target under the RELAXED (and actually-correct) safety condition: an active robot at a
CLEAN task boundary whose FRONTIER transport is SOLO (team size 1). `_first_pending_assignment`
requires the frontier free-node `fg`'s predecessor to be a `RobotStart` or a CLOSED node — i.e. the
robot just finished a task and is about to START the frontier, so it is NOT a co-carrier mid multi-
carry. If that frontier FTU's team is size 1, faulting the robot re-routes only a solo future carry
to a spare and never trips `has_edge` in `FormTransportUnit.apply_cmd!` (validated: Bot7@closed58
fires cleanly and Replace beats NOOP).

This is the accurate form of `pick_solo_fault_target`'s intent. The strict "ALL remaining teams solo"
predicate is over-conservative: once phantom spares are excluded from the initial assignment
(`is_spare` skip in task_assignment.jl) NO real robot on tractor satisfies it, so `fault_robot!(safe)`
could not fire a fault AT ALL (control==NOOP==Replace, inadmissible). Faulting on a solo FRONTIER
restores a genuine, consequential, safe breakdown. Lowest-id for determinism; `nothing` if none yet.
"""
# 안전한 고장 대상 고르기(완화판, 실제로 더 정확): "깨끗한 작업 경계"에서 다음 운반(frontier)이 단독인 로봇.
# 엄격판이 과보수적이라 tractor 에선 아무도 통과 못 하는 문제를 풀어, 진짜로 결과 있는 안전한 고장을 낼 수 있게 함.
function pick_solo_frontier_target(env)
    sched = env.sched
    # size of the FormTransportUnit team that this robot's pending FRONTIER carry joins (0 = no frontier)
    # 이 로봇의 다음(frontier) 운반이 합류할 FormTransportUnit 팀 크기(0 = frontier 없음)를 구하는 내부 함수.
    frontier_team_size(rid) = begin
        fa = try _first_pending_assignment(env, rid) catch; nothing end  # 다음 대기 배정
        fa === nothing && return 0                             # 없으면 0
        slot1 = fa[2]                                          # the RobotGo slot the frontier feeds  # frontier 가 이어지는 RobotGo 슬롯
        for v2 in Graphs.outneighbors(sched, slot1)            # 그 슬롯의 후속 노드들 순회
            n2 = get_node_from_id(sched, get_vtx_id(sched, v2))
            n2 isa FormTransportUnit &&                        # 운반팀 형성 노드를 찾으면
                return length(robot_team(entity(n2)))          # 그 팀 크기를 반환
        end
        return 0
    end
    cands = RobotID[]
    for v in env.cache.active_set                              # 활성 RobotGo 로봇 순회
        node = get_node_from_id(sched, get_vtx_id(sched, v))
        node isa RobotGo || continue
        rid = try entity(node).id catch; nothing end
        rid isa RobotID || continue
        (try is_recovery_spare(rid) catch; false end) && continue    # never fault a recovery spare  # 복구 중 예비 제외
        frontier_team_size(rid) == 1 && push!(cands, rid)            # solo frontier carry -> safe target  # 단독 frontier 운반이면 안전 후보
    end
    isempty(cands) && return nothing
    return sort(cands, by = r -> r.id)[1]                     # id 최소 후보(결정적)
end

"""
    _clear_faulted_robot!(env, faulted; graveyard=(40.0, 40.0)) -> Bool

Visually REMOVE a faulted robot from the build area: teleport its body — and its RVO
agent, so the per-step RVO->scene position sync (route_planning.jl) does not snap it
back — to a far off-grid `graveyard`. Its breakdown position is preserved in
`FAULTED_ROBOTS`, and `_robot_position_2d` (replan.jl) reads THAT record (not the live
body), so the nearest-spare-pool pick is unaffected by the relocation. No-op if the
robot has no scene node. Used for the "broken robot is towed away, spare takes over"
demo (vs leaving it parked in place / as a static obstacle).
"""
# 고장 로봇 본체를 빌드 영역에서 시각적으로 제거: 본체와 그 RVO 에이전트를 멀리 graveyard(무덤) 좌표로 순간이동.
# 고장 위치는 FAULTED_ROBOTS 에 따로 보존되므로, 가장 가까운 예비 풀 선택은 이 이동에 영향받지 않음.
function _clear_faulted_robot!(env, faulted::AbstractID; graveyard = (40.0, 40.0))
    node = try get_node(env.scene_tree, faulted) catch; nothing end  # 씬 노드(없으면 nothing)
    node === nothing && return false                 # 씬 노드가 없으면 할 일 없음
    # move the RVO agent first (else next step's RVO->scene sync overwrites the scene move)
    # RVO 에이전트를 먼저 옮김(안 그러면 다음 스텝의 RVO→씬 동기화가 방금 옮긴 씬 위치를 되돌려버림).
    if use_rvo() && has_vertex(rvo_global_id_map(), faulted)
        try rvo_set_agent_position!(node, graveyard) catch end
    end
    try
        # 본체의 목표 전역 변환을 무덤 좌표로 설정(= 그쪽으로 치움).
        set_desired_global_transform!(node,
            CoordinateTransformations.Translation(graveyard[1], graveyard[2], 0.0))
    catch end
    return true
end

"""
    fault_robot!(env; target=nothing, obstacle=true, clear=false) -> Union{String,Nothing}

Inject a physical robot breakdown. Picks `target` (or an active transport robot),
records it faulted, and returns the NL event for the respec layer (or `nothing` if no
robot could be faulted). Designed as a `schedule_ood!` action.

- `obstacle` (default true): drop a static obstacle (`add_restriction_zone!`) on the
  body so others detour. NOTE: that obstacle is a no-go ZONE — it is surfaced to the LLM
  (`open_zone_descriptors`) and can make it ALSO emit `ForbidZone`/restage on top of the
  intended `ReplaceAgent`. For a pure spare-replacement demo pass `obstacle=false`.
- `clear` (default false): immediately tow the faulted body off-grid
  (`_clear_faulted_robot!`) so it visibly disappears and the spare takes over.
"""
# 로봇 고장을 물리적으로 주입하고, respec 레이어로 보낼 자연어(NL) 이벤트 문자열을 반환한다.
function fault_robot!(env; target::Union{Nothing,RobotID} = nothing,
                      obstacle::Bool = true, clear::Bool = false, safe::Bool = false)
    # `safe=true`: only fault a SOLO transporter (never a co-carrier of an active multi-robot unit),
    # so the replace never trips the has_edge assertion. Returns nothing (defer) if none is available.
    # STRICT (all remaining teams solo) is tried first for backward-compat; if none qualifies (the
    # usual case once phantom spares are excluded from assignment), fall back to the correct RELAXED
    # condition (solo FRONTIER carry at a clean task boundary) so a genuine fault can still fire.
    faulted = target !== nothing ? target :
              safe ? (let t = pick_solo_fault_target(env)
                          t !== nothing ? t : pick_solo_frontier_target(env)
                      end) :
              _pick_active_robot(env)
    faulted === nothing && return nothing
    pos = _ood_robot_pos2d(env, faulted)
    FAULTED_ROBOTS[][faulted] = pos                        # 고장 기록(nearest_pool 이 이 위치를 씀)
    # 고장 로봇 본체를 정적 장애물로 등록(다른 로봇이 우회) — zone 메커니즘 재사용.
    # 단, 이 zone 은 LLM 에 no-go 구역으로 노출되어 ForbidZone 과분류를 유발할 수 있음 → 순수 교체 데모는 obstacle=false.
    obstacle && add_restriction_zone!(Symbol("fault_$(faulted.id)"), pos, default_robot_radius())
    clear && _clear_faulted_robot!(env, faulted)           # 고장 본체를 즉시 화면 밖으로 치움(스페어가 교대)
    return "Robot R$(faulted.id) has broken down at " *
           "($(round(pos[1]; digits=2)), $(round(pos[2]; digits=2))) and cannot move; " *
           "dispatch the nearest backup robot to take over its remaining work."
end

# -----------------------------------------------------------------------------
# Common injection scheduler -- drive OOD generators at chosen sim steps.
# Inert (zero cost) until a trigger is scheduled, so normal runs are unaffected.
# -----------------------------------------------------------------------------
# [한국어] 공통 주입 스케줄러 — 위의 OOD 생성기들을 "정해둔 시점(스텝/진행도)"에 자동 발동시킨다.
#   트리거를 하나도 예약하지 않으면 사실상 비용 0(그냥 지나감)이라 평소 실행엔 아무 영향 없음.

"""
A one-shot OOD trigger: at sim step >= `step`, run `action!(env)` once. The
action mutates physical state (e.g. registers a zone / faults a robot) and
returns either an NL event `String` to enqueue for the respec layer, or
`nothing` (physical-only, no respec action yet).
"""
# mutable struct : "내용을 바꿀 수 있는" 구조체(기본 struct 는 한 번 만들면 필드 변경 불가). fired 를 나중에 true 로 바꿔야 하므로 mutable.
# 의미: 한 번만 발동하는 OOD 트리거 — 시뮬레이션 step 에 도달하면 action!(env) 을 1회 실행.
mutable struct OODTrigger
    step::Int           # 발동할 시뮬레이션 스텝(이 시점 이상이 되면 실행). closed_at>0 이면 무시.
    action!::Function   # 실행할 함수(물리 상태를 바꿈). 타입이 Function — 함수도 값처럼 필드에 담을 수 있음
    fired::Bool         # 이미 발동했는지 여부(중복 발동 방지)
    closed_at::Int      # >0 이면 step 대신 "완료(closed) 노드 수 >= closed_at" 일 때 발동(빌드 진행도 기준 — sim-step보다 재현성↑)
end

# 아직 발동 안 한 OOD 트리거들을 담는 프로세스 전역 목록(Ref 상자 안의 배열).
const OOD_SCHEDULE = Ref(Vector{OODTrigger}())

"""
    schedule_ood!(step, action!) -> OODTrigger

Register a one-shot OOD trigger. `action!(env)::Union{Nothing,String}` runs the
first time the sim reaches `step`. Returns the trigger for inspection.
"""
# OOD 트리거 하나를 등록하는 함수. step 도달 시 action!(env) 가 처음 한 번 실행됨.
function schedule_ood!(step::Int, action!::Function)
    t = OODTrigger(step, action!, false, 0)       # closed_at=0 → step 기반(기존 동작)
    push!(OOD_SCHEDULE[], t)                      # 전역 목록에 추가
    return t                                      # 만든 트리거 반환(확인/조작용)
end

"""
    schedule_ood_at_closed!(n_closed, action!) -> OODTrigger

Register a one-shot OOD trigger that fires the first time the build has CLOSED (completed)
`>= n_closed` schedule nodes. Build-progress is more reproducible than a raw sim-step count
across machines/speeds, so this is preferred for "fault mid-build at a known progress point."
"""
# 스텝 대신 "완료(closed) 노드 수 >= n_closed"(빌드 진행도)에 발동하는 트리거 등록. 진행도 기준이 재현성↑.
function schedule_ood_at_closed!(n_closed::Int, action!::Function)
    t = OODTrigger(0, action!, false, n_closed)   # closed_at>0 → 진행도 기반
    push!(OOD_SCHEDULE[], t)
    return t
end

# 예약된 OOD 트리거 목록을 모두 비우기.
clear_ood_schedule!() = (empty!(OOD_SCHEDULE[]); nothing)

"""
    ood_inject_step!(env, k) -> Nothing

Called once per sim step (before `respec_step!`). Fires any due, unfired
trigger: mutate physical state, and if it returns an NL string, `push_ood!` it so
the verified respec pipeline handles it the same step. No-op (and effectively
free) when no triggers are scheduled, so existing demos are unaffected.
"""
# 매 시뮬레이션 스텝마다(respec_step! 직전) 호출되어, 발동 시점이 된 트리거를 실행하는 함수.
function ood_inject_step!(env, k::Int)           # k = 현재 스텝 번호
    isempty(OOD_SCHEDULE[]) && return nothing    # 예약된 트리거가 없으면 즉시 종료(평소엔 사실상 비용 0)
    for t in OOD_SCHEDULE[]                       # 각 트리거에 대해
        # 발동 조건: closed_at>0 이면 "완료 노드 수 >= closed_at"(진행도 기준), 아니면 "스텝 >= step".
        due = t.closed_at > 0 ? (length(env.cache.closed_set) >= t.closed_at) : (k >= t.step)
        if !t.fired && due                        # 아직 발동 안 했고 + 발동 시점에 도달했으면
            nl = t.action!(env)                   # 액션 실행(물리 상태 변경). 자연어 문자열 또는 nothing 반환
            t.fired = true                        # 발동 표시(다시 실행 안 되게). mutable 이라 필드 변경 가능
            nl === nothing || push_ood!(nl)       # `A || B` : A 가 거짓일 때만 B 실행 → 문자열이 있으면 respec 큐에 넣음
        end
    end
    return nothing
end
