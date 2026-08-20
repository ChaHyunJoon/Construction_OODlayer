# =============================================================================
# spec §3 — 상태를 L1 하나로 통일한다.
#
#   s   Markov 상태.  모델 입력. 값(value)이고 콘텐츠 해시가 가능해야 한다.
#   ξ   재생 상태.    restore! 와 CRN 만 쓴다. s 에 넣지 않는다.
#   log 상태 아님.    스냅샷 대상도 아니다.
#
# 왜 쪼개는가: 안 쪼개면 두 요구가 서로 모순한다.
#   G1(§7)  : restore!(snapshot(env)) 후 같은 시드 → 바이트 동일 (난수 위치를 복원해야 성립)
#   §6.3    : 같은 s 에서 K번 재출발해 서로 다른 미래를 본다 (난수를 복원하면 K개가 전부 같아짐)
# hazard.jl 가 이미 답을 갖고 있다 — **문턱은 재생 대상, 비율은 상태.**
#
# 표현층(φ · ψ · 22차원 feature · dp 격자)을 만들지 않는다(spec §3.1·§4). 학습된 표현이
# 필요해지면 그것은 s 의 **파생**이고, 무엇을 남길지는 설계가 아니라 ablation 이 정한다.
#
# `SHA` 는 `Project.toml [deps]` 에 없다 — `Manifest.toml` 의 전이 의존성으로만 해결된다.
# 부칙 M2 는 `julia +lts --project=. -e 'import SHA'` 가 동작한다고 적었는데, 그건 **Main**
# 스코프(REPL/`-e`)에서의 이야기다. 실측(이 태스크에서 재확인): 이 파일은 `CB.include` 로
# `ConstructionBots` 모듈 코드로 로드되므로, 그 스코프에서 평범한 `import SHA` 는
# `ArgumentError: Package ConstructionBots does not have SHA in its dependencies` 로 죽는다 —
# 패키지 모듈 안에서는 [deps] 에 없는 전이 의존성을 이름으로 불러올 수 없다(Main 은 예외).
# `Project.toml` 을 건드리는 것은 이 태스크의 범위 밖이므로, UUID 로 직접 요청해 Manifest 의
# 전이 의존성을 우회 로드한다 — SHA 는 이미 Manifest 에 있으므로(`ea8e919c-...`) 항상 해결된다.
# ⚠️ 리뷰 라운드 1 이 잡은 두 번째 취약점: `Base.require` 를 **precompile 중에** 부르면 로드
# 에러다. 이 파일이 살아남는 유일한 이유는 `src/smdp/mdp.jl` 이 `CB.include` 로 **런타임에**
# 로드되고 결코 precompile 대상이 되지 않기 때문이다 — 이 include 를
# `src/ConstructionBots.jl`(컴파일되는 모듈 본체) 안으로 옮기는 "정리" 가 나중에 들어오면 이
# 한 줄이 원인이 안 보이는 방식으로 깨진다. 근본 해법은 여전히 `Project.toml [deps]` 한 줄이고,
# 그건 이 태스크 범위 밖으로 그대로 남겨둔다.
const SHA = Base.require(Base.PkgId(Base.UUID("ea8e919c-243c-51af-8825-aaa63cd721ce"), "SHA"))
using Base: @kwdef

# --- 블록 --------------------------------------------------------------------------------

"attributed schedule DAG. 위상만으로는 부족하다 — Replace 의 핵심 편집(replace_in_schedule!)은
로봇 id 를 **재스탬프**할 뿐 위상을 안 바꾼다. 그래서 `binding` 이 필수다."
@kwdef struct GraphBlock
    n_nodes::Int
    edges::Set{Tuple{Int,Int}}          # precedence + 배정 엣지. 태스크 14 의 T_plan 이 쓴다
    closed::Set{Int}
    active::Set{Int}
    binding::Dict{Int,Int}              # 정점 → 바인딩된 로봇 id
    edge_bias::Dict{Tuple{Int,Int},Float64}   # AGENT_COST_BIAS 가 만드는 가중치 배수
    wedge_edges::Set{Tuple{Int,Int}}    # ReformTeam 이 G 에 남기는 영구 편집 (spec §5.4-b)
    dissolved_gates::Set{Tuple{Int,Int}}
end

"기하. 운반 중이 아닌 부품/조립체의 world pose · 활성 no-go 구역 · 누적 build translation Δ."
@kwdef struct GeoBlock
    poses::Dict{Int,NTuple{3,Float64}}
    zones::Set{Symbol}
    build_delta::NTuple{2,Float64}
end

"""로봇 하나의 레코드. 로봇 집합에는 **창고의 spare 도 포함한다**(실측 작업 10 + 예비 12 = 22).
`spares_left` 는 이 집합에서 유도되는 값이지 따로 들고 다니는 스칼라가 아니다."""
@kwdef struct RobotRec
    id::Int
    pose::NTuple{3,Float64}             # SE(2)
    vel::NTuple{2,Float64}              # 빼면 반응형 컨트롤러가 memoryless 가 아니다
    soc::Float64
    energy_J::Float64
    usage_s::Float64                    # hazard 항 β_u·usage. 빼면 F(τ|s,a) 정의 불능
    eff::Float64                        # frailty. 한 번 뽑고 재추첨 없음 → 무기억성 미적용 → 상태다
    health::Symbol                      # :healthy | :degraded | :dead
    stalled::Bool                       # SoC 0 으로 멈춰 선 로봇. 빼면 복구 판정이 갈린다
    payload::Union{Nothing,Int}
    role::Symbol                        # :transport|:team_member|:idle|:spare_parked|:courier
end

"""비율의 인자와 발화 상태만. **누적값(cum_*)과 문턱(thr_*)은 안 넣는다**(spec §3.4).
예외: `expired_*` — `_hz_fire_break!` 가 유예하면서 아무것도 리셋하지 않아 "만료됐는데 대기 중"
상태가 관측 물리량 `(usage, soc, mode)` 만으로 복원되지 않는다. **값이 아니라 불리언만.**"""
@kwdef struct HazardBlock
    lambda0::Dict{Int,Float64}
    mode::Symbol
    broken::Set{Int}                    # 발화한 위험은 재발화 없음
    expired_break::Set{Int}
    expired_cell::Set{Int}
end

"배송 레코드. `target`/`courier` 는 **좌표가 아니라 로봇 id** 이고 `step_*` 는 **절대 스텝 인덱스**
(→ Clock 없이는 복원 불가). 실제 `BatteryDelivery`(src/respec/battery_courier.jl:86-95)와
필드명이 일치한다(순서는 다르지만 `@kwdef` 라 무관)."
@kwdef struct CourierRec
    target::Int
    courier::Int
    depot::Symbol
    home::NTuple{2,Float64}
    goal::NTuple{2,Float64}
    phase::Symbol                       # :outbound | :returning
    step_out::Int
    step_swap::Int
end

"1차 개정이 빠뜨린 블록. Courier.step_out/step_swap 이 절대 스텝 인덱스라 필수다."
@kwdef struct ClockBlock
    t::Float64
    step::Int
end

"""**이 블록이 이 문제를 semi-Markov 로 만든다**(spec §5.4).
Ascione Thm 2.2: `X` 가 semi-Markov ⟺ `(X, γ)` 가 Markov. 이 둘이 그 age 과정 `γ` 다.
- `no_progress` — `maybe_emit_reform_ood!` 가 `% REFORM_INTERVAL == 0` 로 발화시킨다.
  **결정의 34%(485/1438)가 이 카운터에 걸려 있다** — 코너 케이스가 아니다.
- `snap_count`  — `>= SNAP_ESCALATE_AT(3)` 에서 복구 경로가 갈린다."""
@kwdef struct AgeBlock
    no_progress::Int
    snap_count::Int
end

"""이번 epoch 를 연 사건. SMDP 의 decision epoch 는 event-triggered 이므로 트리거한 사건이
상태의 일부다. ⚠️ **`kind` 는 kind 지름길의 입구다**(spec §4.4) — 모델에 넣을 때는 타입 라벨이
아니라 **물리적 귀결**로 넣고, 타입 문자열은 로그에만 남긴다. 방어선은 §6.4 의
leave-one-failure-type-out 행렬이고 그것이 유일한 방어선이다."""
@kwdef struct EventBlock
    kind::Symbol
    robot::Union{Nothing,Int}
    severity::Float64
end

"""s = (G, Geo, Fleet, Hazard, Courier, Clock, Age, e)  — spec §3.3 확정 정의."""
@kwdef struct SimState
    g::GraphBlock
    geo::GeoBlock
    fleet::Dict{Int,RobotRec}
    hazard::HazardBlock
    courier::Vector{CourierRec}
    clock::ClockBlock
    age::AgeBlock
    event::EventBlock
end

"""ξ — 재생 상태. **s 에 절대 안 들어간다.** restore! 와 CRN 만 쓴다.
`restore!(env, s, ξ')` 로 `ξ` 만 갈아 끼워 K 갈래를 만든다(spec §3.5 규칙 2).
`MersenneTwister`/RVO 핸들 같은 불투명 객체는 여기 산다 — `SimState` 의 어떤 블록에도
이런 필드를 두지 않는다(그러면 콘텐츠 해시가 불가능해진다)."""
@kwdef struct ReplayState
    cum_break::Dict{Int,Float64}
    thr_break::Dict{Int,Float64}
    cum_cell::Dict{Int,Float64}
    thr_cell::Dict{Int,Float64}
    cum_zone::Float64
    thr_zone::Float64
    rng_robot::Dict{Int,Random.MersenneTwister}
    rng_zone::Random.MersenneTwister
    pending_drop::Dict{Int,Float64}     # 태스크 2 의 CRN 캐시
    cache_counter::Int                  # _CACHE_TIMESTAMP_COUNTER
end

# --- 정준 직렬화 --------------------------------------------------------------------------
# spec §3.5 규칙 4: 모든 Set/Dict 는 **정렬해서** 직렬화한다. L5(_pick_active_robot 의 Set
# 순회, 태스크 4)의 일반형이다. 정렬을 빼면 같은 상태가 프로세스마다 다른 해시를 얻는다.
#
# 리뷰 라운드 1, C-2 (delimiter injection): 구분자(`, ; : | [ ] { } ( ) =`)를 문자열에 그대로
# 쓰면서 `Symbol` payload 를 이스케이프 없이 꽂으면, 그 구분자를 담은 Symbol 하나가 임의의
# 구조를 위조한다(측정된 예: 1로봇 fleet 이 오염된 role 로 2로봇 fleet 과 해시가 같아짐).
# `Int`/`Bool`/`Nothing`/`Float64` 렌더는 고정된 문자 집합(숫자·`.`·`-`·`true`/`false`/
# `nothing`)이라 구분자를 낼 수 없으므로 안전하다. 위험한 건 자유 텍스트를 담을 수 있는
# `Symbol` 뿐이다 — 길이-프리픽스(`"<len>:<text>"`)로 감싸서 내용이 몇 바이트인지 먼저 밝히면,
# 내부에 구분자·세미콜론이 몇 개 있든 그 Symbol 은 정확히 하나의 원자 토큰으로만 읽힌다.
# 부수 효과: `Symbol("")` 은 `"0:"` 로 렌더돼 빈 집합 `"[]"` 과도 더 이상 겹치지 않는다.
_c(x::Float64) = string(round(x; digits = 9) + 0.0)   # I-1: `round(-1e-12;digits=9)` 이
    # 관측 가능한 -0.0 을 **만들어낸다**(`-0.0 == 0.0` 인데 `string` 은 다르게 찍는다) — vel·
    # pose·build_delta 처럼 float 연산에서 나온 값이 노이즈 이하 부호 차이로 해시를 가른다.
    # `+ 0.0` 은 `-0.0 + 0.0 == 0.0` 이라 부호를 정규화한다(round 뒤에 적용해 반올림 자체는 그대로).
_c(x::Union{Int,Bool,Nothing}) = string(x)
_c(x::Symbol) = (t = string(x); string(ncodeunits(t), ":", t))
_c(t::Tuple) = "(" * join(map(_c, t), ",") * ")"
_c(s::AbstractSet) = "[" * join(map(_c, sort!(collect(s); by = string)), ",") * "]"
_c(d::AbstractDict) = "{" * join(["$(_c(k)):$(_c(v))"
                                  for (k, v) in sort!(collect(d); by = p -> string(p[1]))], ",") * "}"

canonical(b::GraphBlock) = "G(n=$(b.n_nodes),edges=$(_c(b.edges)),closed=$(_c(b.closed))," *
    "active=$(_c(b.active)),"  *
    "bind=$(_c(b.binding)),bias=$(_c(b.edge_bias)),wedge=$(_c(b.wedge_edges))," *
    "dissolved=$(_c(b.dissolved_gates)))"

canonical(b::GeoBlock) = "Geo(poses=$(_c(b.poses)),zones=$(_c(b.zones)),delta=$(_c(b.build_delta)))"

# health/role 은 예전엔 raw `$(...)` 로 꽂혔다 — 그것이 C-2 의 실제 진입점이었다. 이제 `_c(...)`
# 를 통해서만 나간다.
canonical(r::RobotRec) = "R$(r.id)(pose=$(_c(r.pose)),vel=$(_c(r.vel)),soc=$(_c(r.soc))," *
    "E=$(_c(r.energy_J)),usage=$(_c(r.usage_s)),eff=$(_c(r.eff)),health=$(_c(r.health))," *
    "stalled=$(r.stalled),payload=$(_c(r.payload)),role=$(_c(r.role)))"

canonical(b::HazardBlock) = "Hz(l0=$(_c(b.lambda0)),mode=$(_c(b.mode)),broken=$(_c(b.broken))," *
    "expired_break=$(_c(b.expired_break)),expired_cell=$(_c(b.expired_cell)))"

canonical(c::CourierRec) = "Cr(target=$(c.target),courier=$(c.courier),depot=$(_c(c.depot))," *
    "home=$(_c(c.home)),goal=$(_c(c.goal)),phase=$(_c(c.phase))," *
    "out=$(c.step_out),swap=$(c.step_swap))"

canonical(b::ClockBlock) = "Clk(t=$(_c(b.t)),step=$(b.step))"
canonical(b::AgeBlock)   = "Age(no_progress=$(b.no_progress),snap_count=$(b.snap_count))"
canonical(b::EventBlock) = "E(kind=$(_c(b.kind)),robot=$(_c(b.robot)),sev=$(_c(b.severity)))"

# `canonical(s::SimState)` 는 8개 블록 문자열을 **이름표 붙여** 모아뒀다가 합성한다 — 리터럴
# 하나로 이어붙이지 않는 이유(컨트롤러 부칙 B5): `canonical(s.clock)`(t, step) 이 해시 안에
# 있으면 두 상태의 해시가 같으려면 step 까지 같아야 하고, 결정론적 시뮬에서 그런 충돌은 전부
# 복제본이다 — 태스크 13(G-M)의 `strip_age` 류가 나중에 clock(과 age) 을 뺀 해시를 요구한다.
# `omit` 키워드로 블록 이름을 빼고 합성할 수 있게 해서, clock 을 문자열에 하드코딩하지 않는다.
const _BLOCK_NAMES = Set([:g, :geo, :fleet, :hazard, :courier, :clock, :age, :event])

function _canonical_blocks(s::SimState)
    # I-3: `sort!(collect(keys(s.fleet)))` 는 순서만 정하고, 실제로 나가는 문자열은
    # `canonical(rec)` 이 찍는 `rec.id` 뿐이라 Dict 키 자체는 해시에 한 번도 안 닿는다 —
    # `Dict(1 => R(id=2))` 와 `Dict(2 => R(id=2))` 가 해시가 같아진다(측정됨). 이 상태가
    # 유지하려는 불변식은 "키 == rec.id" 이므로, 키를 문자열에 또 넣는 대신(중복 진실원을
    # 만드는 대신) 그 불변식을 단언한다 — 깨지면 (Task 10 추출기 버그처럼) 여기서 시끄럽게
    # 죽는다. 이 레포의 원칙과 같다: 조용히 remap 하지 않고 죽는다.
    for (k, rec) in s.fleet
        k == rec.id || error("SimState.fleet key $k does not match RobotRec.id $(rec.id) — " *
                              "fleet must be keyed by robot id (invariant violated)")
    end
    fleet = join([canonical(s.fleet[k]) for k in sort!(collect(keys(s.fleet)))], ";")
    # I-2: `by = c -> (c.target, c.courier)` 는 total order 가 아니다 — 두 레코드가 같은
    # (target, courier) 를 공유하면(오늘의 유일한 생산자 `BATTERY_DELIVERIES` 에서는 안 나지만,
    # 이 타입 자체는 그걸 막지 않는다) Julia 의 안정 정렬이 삽입 순서를 그대로 새어보낸다.
    # `canonical` 로 정렬하면 키가 콘텐츠 전체라 total order 다(측정됨: 이제 두 삽입 순서가
    # 같은 문자열을 낸다).
    cour  = join(map(canonical, sort(s.courier; by = canonical)), ";")
    return Pair{Symbol,String}[
        :g       => canonical(s.g),
        :geo     => canonical(s.geo),
        :fleet   => "Fleet[$fleet]",
        :hazard  => canonical(s.hazard),
        :courier => "Courier[$cour]",
        :clock   => canonical(s.clock),
        :age     => canonical(s.age),
        :event   => canonical(s.event),
    ]
end

"""
    canonical(s::SimState; omit::Set{Symbol} = Set{Symbol}()) -> String

`s` 의 정준 문자열. **같은 상태는 프로세스가 달라도 같은 문자열을 낸다.**
`omit` 으로 `:g,:geo,:fleet,:hazard,:courier,:clock,:age,:event` 중 일부 블록을 빼고 합성할
수 있다 — 예: `canonical(s; omit = Set([:clock]))` 은 clock 을 뺀 해시를 만든다(부칙 B5,
태스크 13 의 `strip_age` 가 요구하는 모양). `omit` 에 위 8개 이름이 아닌 것이 섞이면(오타 등)
**에러를 던진다** — M-1: 검증 없이 조용히 무시하면 `omit=Set([:clok])` 이 아무 일도 안 하고
전체 해시를 돌려주고, Task 13 의 strip 이 아무 것도 안 벗겨냈다는 사실이 조용히 샌다.
**주의**: `omit` 이 있는 해시와 없는 해시는 같은 키공간을 공유하지 않는다 — 블록 하나를 뺀
문자열이 다른 상태의 전체 문자열과 우연히 같아질 수는 있지만(그것이 clock/age 를 뺀 의도된
용도다), `omit=Set([:clock])`/`omit=Set([:age])` 끼리는 각 블록 문자열이 서로 다른 접두
(`Clk(`/`Age(` 등)를 갖기 때문에 절대 혼동되지 않는다. `ReplayState` 에는 메서드를 정의하지
않는다 — ξ 는 해시 대상이 아니다.
"""
function canonical(s::SimState; omit::Set{Symbol} = Set{Symbol}())
    bad = setdiff(omit, _BLOCK_NAMES)
    isempty(bad) || error("canonical: unknown block name(s) in omit: $(bad) " *
                           "(valid: $(_BLOCK_NAMES))")
    parts = [v for (k, v) in _canonical_blocks(s) if !(k in omit)]
    return join(parts, "|")
end

"""
    state_hash(s; omit = Set{Symbol}()) -> String

`s` 의 콘텐츠 해시(sha256 앞 32자). dp 격자가 하던 "같은 칸인가" 판정을 이것이 대신한다 —
롤아웃 dedup · G-M 검사 · 상태 재방문 탐지가 전부 이 위에 선다(spec §3.2). `omit` 은
`canonical` 로 그대로 전달된다.
"""
state_hash(s; omit::Set{Symbol} = Set{Symbol}()) = bytes2hex(SHA.sha256(canonical(s; omit = omit)))[1:32]
