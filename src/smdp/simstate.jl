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
#
# 🔴 2026-08-20 **엄격 축소 (사용자 결정)**: `s` 는 **행동공간이 실제로 편집하는 변수만** 담는다.
#    네 팔(NOOP · Replace · RelocateBuild · SwapBattery)이 건드리는 19 필드가 전부다.
#    42 → 40 → **19**.
#
# ⚠️ **이 축소가 무엇을 포기했는지 명시한다 — 조용히 새면 안 되는 종류다.**
#
#   (1) `F(τ|s,a)` 를 이 `s` 로 정의할 수 없다. hazard 비율
#       `λ_r(u) = λ_0r + β_u·usage_r + β_s(1−soc_r) + β_c·1[carrying_r]` 의 인자 중
#       `λ_0r`(HazardBlock) · `usage_r` · `eff_r` 가 전부 빠졌다. `soc_r` 하나만 남는다.
#       → **sojourn 모델 Υ 는 `s` 밖에서 조달해야 한다.**
#   (2) `T_plan(s)` 을 이 `s` 로 계산할 수 없다. `closed`/`active`(스케줄 진행)와
#       `zones`(경로 차단)가 빠졌다. → **τ 의 첫 성분도 `s` 밖에서 와야 한다.**
#   (3) 이번 epoch 를 연 사건(`EventBlock`)이 없다. decision epoch 가 event-triggered 인데
#       어느 사건이 열었는지 `s` 가 모른다. → 행동 메뉴는 `s` 가 아니라 호출자의 ctx 가 정한다.
#   (4) `Clock` 이 없는데 `CourierRec.step_out`/`step_swap` 은 **절대 스텝 인덱스**다.
#       그 둘은 이제 `s` 안에서 해석 불가능한 값이다 — 상대시간으로 바꾸거나 소비처가
#       시계를 따로 들고 있어야 한다.
#
#   즉 이 `s` 는 "행동이 만드는 변화" 를 완전히 담지만 "시간이 만드는 변화" 는 안 담는다.
#   ⟨S, A, P, γ, R, Υ⟩ 중 **S 와 A 는 이것으로 충분하고, P·Υ 는 이것만으로 부족하다.**
#
# 🔴 **같은 날 후속 (sojourn read-set 확장, 19 → 26): 위 (1)(2)(4)는 이제 부분/전부 해소됐다.**
#   (1) `usage_r`·`eff_r` 는 `RobotRec.usage_s`/`RobotRec.eff` 로 돌아왔다. `λ_0r`(HazardBlock)
#       은 여전히 밖 — (1)은 **부분** 해소.
#   (2) `closed`/`active`(신규 `ProgBlock`)와 `zones`(`GeoBlock.zones`, 기하까지)가 돌아왔다 —
#       (2)는 **해소**.
#   (3) `EventBlock` 은 여전히 없다 — 그대로.
#   (4) `ProgBlock.t` 가 절대 sim 초 시계를 제공해 `CourierRec.t_out`/`t_swap` 이 그 시계로
#       해석 가능해졌다 — (4)는 **해소**(`step_out`/`step_swap` → `t_out`/`t_swap` 개명).
#   상세: `.superpowers/sdd/2026-08-20-sojourn-generative-smdp/task-3-brief.md`.

"""행동이 편집하는 스케줄 그래프 부분만. `n_nodes`·`closed`·`active` 는 2026-08-20 엄격
축소에서 빠졌다(어떤 팔도 안 건드린다 — 명목 TAMP 가 움직인다). `closed`/`active` 는 같은 날
후속에서 `ProgBlock` 으로 돌아왔다(GraphBlock 자체가 아니라 별도 블록으로) — 위 (2) 해소."""
@kwdef struct GraphBlock
    edges::Set{Tuple{Int,Int}}          # precedence + 배정 엣지. Replace 가 편집한다
    binding::Dict{Int,Int}              # 정점 → 바인딩된 로봇 id. Replace 가 재스탬프한다
    wedge_edges::Set{Tuple{Int,Int}}    # 스페어 인계 직렬화(Replace 경로)가 남기는 영구 편집
    dissolved_gates::Set{Tuple{Int,Int}}
end

"""행동이 편집하는 기하 + **sojourn 이 읽는 zone**. `zones` 는 2026-08-20 엄격 축소에서
빠졌다가 이 설계에서 돌아왔다 — zone 이 `T_plan_next` 를 가르기 때문이다(spec §3-3).
⚠️ **기하까지** 나른다. 이름만 나르면 반지름이 다른 두 상태가 같은 해시를 낸다."""
@kwdef struct GeoBlock
    poses::Dict{Int,NTuple{3,Float64}}  # RelocateBuild 가 강체 Δ 를 건다
    build_delta::NTuple{2,Float64}      # 누적 build translation
    zones::Dict{Symbol,NTuple{3,Float64}}   # key => (cx, cy, r)
end

"""로봇 하나의 레코드. 다섯 필드는 행동의 write-set, 뒤 셋은 sojourn 의 read-set 이다.
`usage_s`·`mode` 는 λ_r 의 인자이고, `eff`(ε_r)는 soc 감소율의 인자다 — 상수라 동역학
비용이 0 인데, 빼면 모델이 잠재변수 혼합이 되어 s 에서 Markov 가 아니다(spec §3-3).
`mode ∈ {:idle, :transit, :carry, :manip}` — 실측 hazard.jl:333-338, `:transit` 이 기준(배수 1.0).

로봇 집합에는 창고의 spare 도 포함한다(실측 작업 10 + 예비 12 = 22).
`id` 는 필드가 아니라 **`fleet` Dict 의 키**다(중복 진실원을 두지 않는다). 빠진 것들:
`vel`(RVO 파생) · `energy_J`(비용 누적기) · `stalled`(soc 파생)."""
@kwdef struct RobotRec
    pose::NTuple{3,Float64}             # SE(2). Replace 의 본체 교체·복구 스냅이 움직인다
    soc::Float64                        # [0,1]. SwapBattery 가 되돌린다
    health::Symbol                      # :healthy | :degraded | :dead. Replace 가 바꾼다
    payload::Union{Nothing,Int}         # 운반 중인 것. Replace 가 재부모화한다
    role::Symbol                        # :transport|:team_member|:idle|:spare_parked|:courier
    usage_s::Float64
    mode::Symbol
    eff::Float64
end

"""스케줄 진행 + 시계. `T_plan_next` 와 흡수상태 판정이 이것을 읽는다(spec §3-3).
`t` 는 절대 sim 초이고 `CourierRec.t_*` 의 해석 기준이다.

🔴 **`active` 의 값에 대한 정정 (2026-08-20 태스크 4).** 이 자리에는 원래 "그 정점이 **실제로
시작한 시각**" 이라고 적혀 있었다. **그렇지 않다.** 유일한 생산 경로 `simstate_of` 가 넣는 값은
`get_t0(sched, v)` = **MILP/구조적으로 계획된** 시작이고, 그것은 런 도중 움직이지 않는다
(`process_schedule!` 호출자가 전부 `t = 0.0` 을 넘긴다). 실제 시작을 적는 곳은 `:log` 로 분류된
`MONITOR_NODE_T` 하나뿐이라 `s` 의 출처로 쓸 수 없다 — 그래서 지어내지 않고 계획값을 나른다.

⚠️ **이 문단을 읽지 않고 "진행 중 노드의 잔여 소요시간" 을 이 필드로 내리면 틀린다.**
`잔여 = ρ·duration − (t − active[v])` 는 상시 ≤ 0 이 되어 `T_plan_next` 가 클램프만 돌려준다
(실측: step 120 에서 활성 10개 중 8개가 `t0 = 0.0`·계획 소요시간 `0.0` 인데 경과 3.0초).
전체 근거 사슬: `src/smdp/observe.jl:94-114`. 이 사실을 못 박는 시험:
`test/smdp_observe_gate.jl` 의 "prog.active 는 계획된 시작" testset — **결함이 고쳐지면 그 시험이
빨개진다**(그것이 이 갭을 열어둔 채 표시해 두는 방식이다)."""
@kwdef struct ProgBlock
    t::Float64
    closed::Set{Int}
    active::Dict{Int,Float64}
end

"""배송 레코드. `SwapBattery` 가 만든다. `target`/`courier` 는 **좌표가 아니라 로봇 id**.
`t_out`/`t_swap` 은 절대 sim 초다(`ProgBlock.t` 와 같은 시계) — 2026-08-20 엄격 축소가 남긴
절대 스텝 인덱스 부채(위 (4))는 `ProgBlock.t` 가 시계를 돌려주면서 해소됐다."""
@kwdef struct CourierRec
    target::Int
    courier::Int
    depot::Symbol
    home::NTuple{2,Float64}
    goal::NTuple{2,Float64}
    phase::Symbol                       # :outbound | :returning
    t_out::Float64
    t_swap::Float64
end

# ---- 2026-08-20 엄격 축소에서 사라진 채로 남은 블록 셋 -----------------------------------------
#   `HazardBlock`(lambda0·mode·broken·expired_break·expired_cell) — 위 (1). `usage_s`·`mode`·
#     `eff` 가 `RobotRec` 으로 돌아오면서 부분적으로만 해소됐다 — `lambda0`·`broken` 류는 여전히 밖.
#   `AgeBlock`(snap_count)   ← 명목 레인 복구가 증가시킨다, 팔이 아니다
#   `EventBlock`(kind·robot·severity)                             — 위 (3), 그대로 남음

"""s = (G, Geo, Fleet, Prog, Courier) — 26 필드. 행동공간이 편집하는 write-set(19필드)에
sojourn 샘플러·보상함수가 읽는 read-set(zones·usage_s·mode·eff·prog) 을 합쳤다(spec §3-3).
남은 부채(EventBlock 등)는 위 목록."""
@kwdef struct SimState
    g::GraphBlock
    geo::GeoBlock
    fleet::Dict{Int,RobotRec}
    prog::ProgBlock
    courier::Vector{CourierRec}
end

# =============================================================================
# 🔴 알려진 한계 — 2026-08-20 엄격 축소 이후
#
# 이전 세대의 이 자리에는 "`:state` 인벤토리 30개 중 무엇이 `SimState` 에 안 담겼는가" 표가
# 있었다. 그 표의 전제는 "`s` 는 에피소드 상태를 전부 담아야 한다" 였는데, 엄격 축소가 그
# 전제를 **의도적으로 버렸다** — 이제 `s` 는 **행동이 편집하는 것만** 담는다. 그래서 그 표는
# 통째로 무의미해졌고(대부분의 이름이 "일부러 안 담는다" 로 답이 정해진다) 삭제했다.
#
# 대신 이 축소가 만든 **구조적 부채**를 적는다. 위 (1)~(4)가 그것이고, 요약하면:
#
#   `s` 만으로는 **다음 사건이 언제 오는지(τ)** 도 **다음 상태가 무엇인지(P)** 도 모른다.
#   `s` 는 `(s, a) → s⁺` 의 **행동 편집 부분**에 대해서만 닫혀 있다.
#
# → 그러므로 소비처는 반드시 `s` 와 **함께** 다음을 따로 들고 다녀야 한다:
#     · hazard 비율 인자 (`λ_0r` · `usage_r` · `eff_r`)        → `F(τ|s,a)` 용
#     · 스케줄 진행 (`closed`/`active`) 과 활성 zone            → `T_plan` 용
#     · 시계 (`t`/`step`)                                       → `CourierRec.step_*` 해석용
#     · 이번 epoch 를 연 사건                                   → 행동 메뉴 결정용
#   그것들을 `s` 에 다시 넣지 않고 어디에 둘지는 **아직 정해지지 않았다** — Task 10
#   (`snapshot`/`restore!`)이 그 결정을 물려받는다.
#
# 🔴 **같은 날 후속: 위 목록 넷 중 셋이 `s` 안으로 되돌아왔다.** `usage_r`·`eff_r`(`λ_0r` 은
#   여전히 밖) · `closed`/`active`/zone(신규 `ProgBlock`·`GeoBlock.zones`) · 시계(`ProgBlock.t`,
#   `CourierRec.step_*` → `t_*` 로 개명해 그 시계로 해석)가 그것이다. **"이번 epoch 를 연
#   사건" 만 아직 s 밖**이다 — Task 10 이 물려받을 결정은 그 하나로 좁혀졌다.
#
# 🔴 **남아 있던 손실 매핑 하나 — 이 태스크에서 해소됐다** (해시 기반 dedup/재출발을 켜기 전에
#   닫을 것으로 적혀 있던 항목):
#   구 `GeoBlock.zones :: Set{Symbol}` 이 `RESTRICTION_ZONES :: Dict{Symbol,Ball2}` 의 키만
#   나르고 공 기하(중심·반지름)를 버리던 결함은 필드가 통째로 빠지면서 한때 s 에서 사라졌었다.
#   신규 `GeoBlock.zones :: Dict{Symbol,NTuple{3,Float64}}` 는 **기하까지**(cx,cy,r) 나른다 —
#   이름만 나르는 옛 결함이 그대로 되풀이되지 않도록 이 태스크의 설계 자체가 그 경고를 반영했다.
#
# ✅ 2026-08-20 에 소멸한 것: `AGENT_COST_BIAS`(로봇→배수) vs 구 `GraphBlock.edge_bias`
#   (간선→배수)의 키 공간 불일치 — `Deprioritize` 가 어휘에서 빠지며 필드 자체가 없어졌다.
#   (`deprioritize_agent!` 집행부는 TIER-2 소프트 재명세 기전으로 남아 있다.)
# =============================================================================

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
# 리뷰 라운드 2 잔여 항목 (기록만 — 사소하고, 지금 고치지 않는다):
#   - `_c(NaN) == "NaN"` 이라 `NaN` 을 담은 두 상태는 (IEEE754 상 `NaN != NaN` 이지만) 해시가
#     같다 — 콘텐츠 해시가 원하는 "같은 값이면 같은 문자열" 의미로는 원하는 동작일 가능성이
#     높지만, 명시적으로 그렇다고 밝혀둔 적은 없었다.
#   - `_c(::AbstractSet)`/`_c(::AbstractDict)` 는 정렬 키로 `string(elem)`/`string(key)` 를
#     쓰고 실제로 내보내는 건 `_c(elem)`/`_c(key)` 다 — 오늘의 모든 키 타입(Int, Tuple{Int,Int},
#     그리고 `GeoBlock.zones` 가 쓰는 Symbol)에서는 `string` 이 injective 라 문제가 없지만,
#     `string` 이 non-injective 인 타입이 나중에 Set/Dict 키로 들어오면 total order 가 깨질 수 있다.
#   - `SHA` 는 여전히 `Base.require` 로 Manifest 전이 의존성을 우회 로드한다 — 근본 해법인
#     `Project.toml [deps]` 한 줄은 이 태스크 범위 밖으로 아직 안 갚은 채로 남아 있다.

canonical(b::GraphBlock) = "G(edges=$(_c(b.edges)),bind=$(_c(b.binding))," *
    "wedge=$(_c(b.wedge_edges)),dissolved=$(_c(b.dissolved_gates)))"

canonical(b::GeoBlock) = "Geo(poses=$(_c(b.poses)),delta=$(_c(b.build_delta))," *
    "zones=$(_c(b.zones)))"

# health/role 은 예전엔 raw `$(...)` 로 꽂혔다 — 그것이 C-2(구분자 위조)의 실제 진입점이었다.
# 이제 `_c(...)` 를 통해서만 나간다.
# ⚠️ 2026-08-20: `RobotRec.id` 가 필드에서 빠졌다. 로봇 identity 는 `fleet` Dict 의 키가
# 나르므로, 그 키를 문자열에 **반드시** 넣어야 한다 — 안 넣으면 I-3 이 잡았던 결함이 되살아난다
# (`Dict(1=>rec)` 와 `Dict(2=>rec)` 가 같은 해시를 낸다). 그래서 접두 `R<key>` 는 아래
# `_canonical_blocks` 가 **키에서** 붙인다. 이 메서드는 레코드 내용만 찍는다.
canonical(r::RobotRec) = "(pose=$(_c(r.pose)),soc=$(_c(r.soc)),health=$(_c(r.health))," *
    "payload=$(_c(r.payload)),role=$(_c(r.role)),usage=$(_c(r.usage_s))," *
    "mode=$(_c(r.mode)),eff=$(_c(r.eff)))"

canonical(b::ProgBlock) = "Prog(t=$(_c(b.t)),closed=$(_c(b.closed)),active=$(_c(b.active)))"

# ⚠️ t_out/t_swap 은 이제 Float64 다 — 예전 Int 는 `$(c.step_out)` 로 직접 꽂아도 안전했지만
# float 은 -0.0 정규화가 필요해 반드시 `_c(...)` 를 통해서 찍는다(`_c(::Float64)` 의 `+ 0.0`).
canonical(c::CourierRec) = "Cr(target=$(c.target),courier=$(c.courier),depot=$(_c(c.depot))," *
    "home=$(_c(c.home)),goal=$(_c(c.goal)),phase=$(_c(c.phase))," *
    "out=$(_c(c.t_out)),swap=$(_c(c.t_swap)))"

# `canonical(s::SimState)` 는 다섯 블록 문자열을 **이름표 붙여** 모아뒀다가 합성한다 — 리터럴
# 하나로 이어붙이지 않는 이유(컨트롤러 부칙 B5): `omit` 키워드로 블록 이름을 빼고 합성할 수
# 있어야 한다(태스크 13 의 strip 류가 요구하는 모양).
const _BLOCK_NAMES = Set([:g, :geo, :fleet, :prog, :courier])

function _canonical_blocks(s::SimState)
    # I-3: 로봇 identity 는 이제 **오직 Dict 키**에만 있다(`RobotRec.id` 삭제). 그래서 키를
    # 문자열에 넣는 것이 선택이 아니라 필수다 — 예전에는 `canonical(rec)` 이 찍는 `rec.id` 와
    # 키가 중복 진실원이라 "키 == rec.id" 를 단언으로 지켰는데, 이제 진실원이 하나뿐이라
    # 단언할 대상이 없고 대신 키가 반드시 해시에 닿아야 한다.
    fleet = join(["R$(k)" * canonical(s.fleet[k]) for k in sort!(collect(keys(s.fleet)))], ";")
    # I-2: `by = canonical` 로 정렬한다 — 키가 콘텐츠 전체라 total order 다. `(target, courier)`
    # 로 정렬하면 두 레코드가 그 쌍을 공유할 때 Julia 안정 정렬이 삽입 순서를 새어보낸다.
    cour  = join(map(canonical, sort(s.courier; by = canonical)), ";")
    return Pair{Symbol,String}[
        :g       => canonical(s.g),
        :geo     => canonical(s.geo),
        :prog    => canonical(s.prog),
        :fleet   => "Fleet[$fleet]",
        :courier => "Courier[$cour]",
    ]
end

"""
    canonical(s::SimState; omit::Set{Symbol} = Set{Symbol}()) -> String

`s` 의 정준 문자열. **같은 상태는 프로세스가 달라도 같은 문자열을 낸다.**
`omit` 으로 `:g,:geo,:prog,:fleet,:courier` 중 일부 블록을 빼고 합성할
수 있다 — 예: `canonical(s; omit = Set([:courier]))` 은 courier 를 뺀 해시를 만든다(부칙 B5). `omit` 에 위 5개 이름이 아닌 것이 섞이면(오타 등)
**에러를 던진다** — M-1: 검증 없이 조용히 무시하면 `omit=Set([:clok])` 이 아무 일도 안 하고
전체 해시를 돌려주고, Task 13 의 strip 이 아무 것도 안 벗겨냈다는 사실이 조용히 샌다.
**주의**: `omit` 이 있는 해시와 없는 해시는 같은 키공간을 공유하지 않는다 — 블록 하나를 뺀
문자열이 다른 상태의 전체 문자열과 우연히 같아질 수는 있지만(그것이 clock/age 를 뺀 의도된
용도다), `omit=Set([:g])`/`omit=Set([:geo])` 끼리는 각 블록 문자열이 서로 다른 접두
(`G(`/`Geo(` 등)를 갖기 때문에 절대 혼동되지 않는다. `ReplayState` 에는 메서드를 정의하지
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

`s` 의 콘텐츠 해시(sha256 앞 32자). `omit` 은 `canonical` 로 그대로 전달된다.

🔴 **2026-08-20 이후 이 해시로 상태를 병합·dedup 하지 말 것.** 역할이 바뀌었다.

  옛 계약: "dp 격자가 하던 '같은 칸인가' 판정을 이것이 대신한다 — 롤아웃 dedup · G-M 검사 ·
  상태 재방문 탐지가 전부 이 위에 선다"(구 spec §3.2). 그 계약은 `s` 가 **충분통계**라는
  전제 위에 있었다.

  지금: 엄격 축소로 `s` 는 행동의 write-set 만 담는 **손실 압축**이다(hazard 비율·스케줄
  진행·zone·시계·사건이 전부 밖에 있다). 그래서 **서로 다른 두 세계가 같은 해시를 낸다.**
  이 해시로 MCTS 트리 노드를 병합하면 그 둘이 한 노드로 합쳐지고, 한쪽의 롤아웃 통계가
  다른 쪽의 가치로 읽힌다 — 에러는 안 나고 정책만 조용히 틀어진다. 이 레포가 반복해서
  데인 실패 모양(낡은/다른 것이 이번 판단의 참·거짓을 정하는 것) 그대로다.

  **지금 이 해시가 정당하게 쓰이는 곳**: 같은 결정론적 replay 안에서 "이 두 스냅샷이
  글자 그대로 같은가" 를 싸게 확인하는 것(테스트·회귀 검사). 그 밖은 없다.

  생산 소비처는 현재 **0개**다. 늘리기 전에 이 문단을 다시 읽을 것.

**오라클 전제조건 — `_c(::Float64)` 의 반올림 허용오차(`digits=9`)는 절대값이다.**
그래서 필드 크기에 따라 실효 상대 허용오차가 균일하지 않다. 2026-08-20 엄격 축소로 가장
위험했던 필드(`energy_J`, ~5e-15 = 34 ULP 로 사실상 스무딩이 없었다)는 여전히 `s` 밖이다.
🔴 **`usage_s`·`clock.t` 는 이 태스크(2026-08-20 sojourn read-set 확장)로 `RobotRec.usage_s`·
`ProgBlock.t`(+ 파생 `active` 값·`CourierRec.t_*`)로 되돌아왔다** — 지금 아는 sim 시간 스케일
(makespan 수십 초대)에서는 O(10⁰)~O(10²) 대이므로 `digits=9` 가 여전히 충분해 보이지만,
`soc` 처럼 **실측으로 확인된 값은 아니다**. 남은 float 필드는 `pose`·`soc`·`build_delta`·
`poses`·`zones`·`eff`·courier 좌표까지 대부분 O(10⁰)~O(10²) 라 `digits=9` 가 충분한 흡수폭을
준다(실측 기준 `soc ≈ 0.87` 에서 ~5.7e-10). **그래도 전제는 전제다**: 서로 다른 실행 경로로
도달한 두 상태를 이 해시로 동일하다고 판정하는 순간, 부동소수 누적 드리프트가 이 허용오차를
넘으면 조용히 다른 해시가 난다 — 아무 데도 에러가 안 나고 오라클의 캐싱·CRN 분산 축소가 그냥
멈춘다. 결정론적 replay 하나 안에서는 무해하다. `usage_s` 가 장기 시뮬레이션에서 실제로 이
허용오차 안에 드는지는 아직 실측되지 않았다 — Task 4(`simstate_of`)가 실측할 자리다.
"""
state_hash(s; omit::Set{Symbol} = Set{Symbol}()) = bytes2hex(SHA.sha256(canonical(s; omit = omit)))[1:32]
