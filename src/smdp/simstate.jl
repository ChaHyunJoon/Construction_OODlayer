# =============================================================================
# spec §3 — 상태를 L1 하나로 통일한다.
#
#   s   Markov 상태.  모델 입력. 값(value)이고 콘텐츠 해시가 가능해야 한다.
#   ξ   재생 상태.    난수 문턱을 담는 자리. s 에 넣지 않는다.
#   log 상태 아님.
#
# 🔴 **2026-08-20 아키텍처 전환(설계문서 §11-2·§11-7)이 이 쪼갬의 원래 근거를 폐기했다.**
# 원래 근거는 두 요구의 모순이었다 — `G1`(restore!(snapshot(env)) 후 바이트 동일) vs
# `§6.3`(같은 s 에서 K번 재출발해 서로 다른 미래). 그런데 **`snapshot`/`restore!`/`fork`
# (구 Task 10·11)도 `G1` 도 짓지 않기로 했다**(구현 0 이라 철거 비용 0). ξ 기반 CRN 도
# 소비처가 0 이고 분산 감소는 root parallelization 으로 옮겼다 — **ξ 를 CRN 근거로 인용하지 말 것**
# (§11-2 표). 되살리자는 제안이 나오면 §11-2 를 먼저 읽을 것.
#
# 쪼갬 자체는 **다른 이유로** 살아남는다: `s` 는 콘텐츠 해시가 가능해야 하는데
# `MersenneTwister`/RVO 핸들 같은 불투명 객체는 해시할 수 없다. hazard.jl 의 분할이 그대로
# 답이다 — **문턱은 ξ, 비율은 상태.**
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

"""행동이 편집하는 스케줄 그래프 부분. 2026-08-21 축소에서 `wedge_edges`·`dissolved_gates` 가
빠졌다 — 전자는 `edges` 의 부분집합이고(실측: `replace_robot.jl:297-298`·`:424-425` 가
`add_edge!` **직후** 장부에 적는다), 후자는 하드코딩 복구 루틴의 메모라 손실 압축으로 뺐다
(spec §2-3). ⚠️ `dissolved_gates` 는 `edges` 로 복원되지 **않는다** — 그 손실은 감수한 것이다."""
@kwdef struct GraphBlock
    edges::Set{Tuple{Int,Int}}          # precedence + 배정 엣지. Replace 가 편집한다
    binding::Dict{Int,Int}              # 정점 → 바인딩된 로봇 id. Replace 가 재스탬프한다
end

"""행동이 편집하는 기하 + sojourn 이 읽는 zone. `build_delta` 는 2026-08-21 축소에서 빠졌다 —
엔진에 출처가 없어 **상수 `(0,0)`** 이었고 상수는 상태가 아니다.
⚠️ `zones` 는 **기하까지** 나른다. 이름만 나르면 반지름이 다른 두 상태가 같은 해시를 낸다.
⚠️ `poses` 는 **조립체** 위치다(로봇이 아니다). `RelocateBuild` 가 `s` 에 남기는 유일한 흔적."""
@kwdef struct GeoBlock
    poses::Dict{Int,NTuple{3,Float64}}
    zones::Dict{Symbol,NTuple{3,Float64}}   # key => (cx, cy, r)
end

"""로봇 하나의 레코드 — **두 필드뿐이다.** λ 와 에너지가 읽는 것이 이 둘이 전부다
(`λ = base·mult(mode)·exp(β_u·usage_s/U + β_s·(1−soc))`, spec §2-1).

2026-08-21 축소에서 빠진 여섯과 그 처분(spec §2-2):
  `pose`·`payload` — 3계층 reactive 스택 + 운반유닛 계층의 관할
  `role`·`health`  — **`fleet` 의 멤버십**으로 대체(아래 SimState docstring)
  `mode`           — `prog.closed`+`g.edges`+`g.binding` 의 파생. `derive.jl` 의 `mode_of`
  `eff` (ε_r)      — **D-5 로 동역학에서 없앴다**(`drain_sigma = 0.0`). 그냥 빼면 잠재변수
                     혼합이 되어 s 에서 Markov 가 아니다 — 뺀 게 아니라 없앤 것이다

🔴 `usage_s` 를 되돌리지 말 것: `_hz_ensure!`(hazard.jl:296)가 새 로봇에 `usage_s = 0.0` 을
찍으므로 **이 필드가 `Replace` 팔의 유일한 흔적**이다. 빼면 λ 관점에서 Replace 와 NOOP 이
구분되지 않는다."""
@kwdef struct RobotRec
    soc::Float64        # [0,1]. SwapBattery 가 되돌린다
    usage_s::Float64    # 누적 활동 초. Replace 가 0 으로 되돌린다
end

"""스케줄 진행. **`closed` 하나뿐이다.**
2026-08-21 축소에서 빠진 둘:
  `active` — `frontier(closed, edges)` 의 파생(실측 `essential_tg_coponents.jl:1921-1932`:
             "모든 선행이 closed_set 에 있으면 활성"). `derive.jl` 의 `active_of`
  `t`      — 이 정식화는 undiscounted · **time-homogeneous** SSP-SMDP 다. 절대시각이 상태에
             있으면 같은 상황이 시각별로 다른 트리 노드가 되어 통계가 쪼개진다"""
@kwdef struct ProgBlock
    closed::Set{Int}
end

"""s = (G, Geo, Fleet, Prog) — **7 필드**. 판정 기준(spec §2-1):
**이미 하드코딩된 하위 정책의 관할이거나, `s` 안의 다른 값에서 다시 만들 수 있거나,
상수면 상태가 아니다.**

🔴 **`fleet` 의 멤버십이 곧 "지금 위험에 노출된 로봇" 이다.** `simstate_of` 가
`_hz_excluded()`(주차 예비 ∪ 반출 예비 ∪ 고장)를 직접 불러서 뺀다. 그래서 경량 레인과 무거운
레인이 **구성상 같은 집합** 위에서 위험을 적분한다(spec §2-4). 죽은 로봇은 태그가 아니라
**부재**로 표현된다 — `health` 필드를 되살리지 말 것.

⚠️ `SwapBattery` 는 결정 직후 `s` 에 흔적을 남기지 않는다(배송은 `env.BATTERY_DELIVERIES[]`
에 산다). **트리 노드를 `state_hash` 로 병합하는 소비처가 생기면 그 순간 SwapBattery 자식이
NOOP 자식과 합쳐진다** — spec §2-5 의 트립와이어."""
@kwdef struct SimState
    g::GraphBlock
    geo::GeoBlock
    fleet::Dict{Int,RobotRec}
    prog::ProgBlock
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
#   그것들을 `s` 에 다시 넣지 않고 어디에 둘지는 **아직 정해지지 않았다.** ⛔ 예전에는 이 결정을
#   Task 10(`snapshot`/`restore!`)이 물려받는다고 적었는데, 그 태스크는 설계문서 §11-2 에서
#   **짓지 않기로 폐기됐다.** 현재 소유자는 **N-11-1(트리 노드 키)** 이다(§11-6·§11-7): 생성
#   MCTS 에서 트리 노드를 무엇으로 색인하는가 — `s` 자체인가, `s` + read-set 요약인가 —
#   그리고 그 답은 §11-2 규칙대로 설계가 아니라 **N-11-2 ablation** 이 정한다.
#
# 🔴 **같은 날 후속: 위 목록 넷 중 셋이 `s` 안으로 되돌아왔다.** `usage_r`·`eff_r`(`λ_0r` 은
#   여전히 밖) · `closed`/`active`/zone(신규 `ProgBlock`·`GeoBlock.zones`) · 시계(`ProgBlock.t`,
#   `CourierRec.step_*` → `t_*` 로 개명해 그 시계로 해석)가 그것이다. **"이번 epoch 를 연
#   사건" 만 아직 s 밖**이다 — N-11-1(트리 노드 키)이 물려받을 결정은 그 하나로 좁혀졌다.
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

"""ξ — 재생 상태. **s 에 절대 안 들어간다.**
⛔ 이 자리에는 "`restore!(env, s, ξ')` 로 ξ 만 갈아 끼워 K 갈래를 만든다(spec §3.5 규칙 2)" 라고
적혀 있었다. `restore!` 는 **짓지 않기로 폐기됐고**(설계문서 §11-2) ξ 기반 CRN 도 소비처가 0 인
채로 root parallelization 에 자리를 내줬다 — 타입은 남기되 **CRN 근거로 인용하지 말 것**.
지금 이 타입이 하는 일은 하나다: 해시 불가능한 불투명 상태를 `s` 밖에 격리하는 것.
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

canonical(b::GraphBlock) = "G(edges=$(_c(b.edges)),bind=$(_c(b.binding)))"

canonical(b::GeoBlock) = "Geo(poses=$(_c(b.poses)),zones=$(_c(b.zones)))"

canonical(r::RobotRec) = "(soc=$(_c(r.soc)),usage=$(_c(r.usage_s)))"

# 브리프 Step 4 의 `_canonical_blocks` 는 `s.fleet::Dict{Int,RobotRec}` 를 `_c(s.fleet)` 하나로
# 찍는다(옛 코드처럼 `join(["R$(k)"*canonical(...)...])` 를 손으로 짜지 않는다) — `_c(::AbstractDict)`
# 가 값마다 `_c(v)` 를 부르므로, 그 다리를 놓는 이 한 줄이 없으면
# `MethodError: no method matching _c(::RobotRec)` 로 죽는다(실측: Step 4 첫 시도). `R<key>` 접두
# (I-3, 로봇 identity)는 `_c(::AbstractDict)` 의 `"$(_c(k)):$(_c(v))"` 가 이미 키를 찍으므로 그대로
# 보존된다 — 별도 접두를 덧붙일 필요가 없다.
_c(r::RobotRec) = canonical(r)

canonical(b::ProgBlock) = "Prog(closed=$(_c(b.closed)))"

# `canonical(s::SimState)` 는 네 블록 문자열을 **이름표 붙여** 모아뒀다가 합성한다 — 리터럴
# 하나로 이어붙이지 않는 이유(컨트롤러 부칙 B5): `omit` 키워드로 블록 이름을 빼고 합성할 수
# 있어야 한다(태스크 13 의 strip 류가 요구하는 모양).
const _BLOCK_NAMES = Set([:g, :geo, :fleet, :prog])

_canonical_blocks(s::SimState) = (
    :g     => canonical(s.g),
    :geo   => canonical(s.geo),
    :fleet => "Fleet=" * _c(s.fleet),
    :prog  => canonical(s.prog),
)

"""
    canonical(s::SimState; omit::Set{Symbol} = Set{Symbol}()) -> String

`s` 의 정준 문자열. **같은 상태는 프로세스가 달라도 같은 문자열을 낸다.**
`omit` 으로 `:g,:geo,:fleet,:prog` 중 일부 블록을 빼고 합성할
수 있다 — 예: `canonical(s; omit = Set([:prog]))` 은 prog 를 뺀 해시를 만든다(부칙 B5). `omit` 에 위 4개 이름이 아닌 것이 섞이면(오타 등, 2026-08-21 축소로 사라진 `:courier` 도 포함)
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
