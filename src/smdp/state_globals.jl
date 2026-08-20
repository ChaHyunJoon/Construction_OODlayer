# =============================================================================
# spec §3.6 — 스냅샷 대상 전역의 전수 목록. **문서가 아니라 계약이다.**
#
# 처분 어휘:
#   :state   → s 로 들어간다 (Markov 상태. 모델 입력. 콘텐츠 해시 가능해야 한다)
#   :replay  → ξ 로 들어간다 (restore! 와 CRN 만 쓴다. s 에 넣지 않는다 — 넣으면 s 가
#              해시 불가가 되고, thr 을 넣으면 발화 시각이 s 로부터 결정론이 되어 전체
#              시스템이 확률성을 잃는다: spec §3.4)
#   :split   → 한 컨테이너가 s·ξ·log 로 쪼개진다
#   :log     → 상태 아님. 스냅샷 대상도 아님
#   :setup   → 셋업 상수 / 배선 훅 / ENV 손잡이. 에피소드 중 불변이면 스냅샷 불필요
#   :render  → 시각화 전용. 동역학에 안 닿는다
#   :meta    → meta-level 상태. **s 에 넣지 않는다**(spec §6.1: "이 OOD 를 본 적 있는가"는
#              환경 상태가 아니라 meta-state 다)
#
# 새 전역을 만들면 여기 등록해야 한다 — 안 하면 test/smdp_global_inventory.jl 이 이름을 찍고
# 죽는다. 그게 이 파일의 존재 이유다. 반대 방향(표에서 지웠는데 스캔이 못 보는 유령 엔트리)도
# `stale_globals` 가 잡는다 — 2026-08-20 fix round 1 의 발단(`_SIM_STEP` 이 태스크 8 로 사라졌는데
# 표에 남아 있었다)이 정확히 그 방향의 실패였다.
#
# ---- 스캐너 범위 결정 (2026-08-20, controller-addendum.md 태스크 7 판정 I12 + fix round 1) -----
# `src/` 만 훑으면 실제 에피소드 상태를 놓친다 — `run_demo.jl` 의 `_REFORM_CT`(ReformTruth 발화
# 게이팅), `policy.jl` 의 `_DECISION_N`(어느 팔이 실제로 집행되는지 게이팅, `should_deviate` 가
# 읽는다). `run_demo.jl` 이 `policy.jl` 을 직접 `include` 한다(`:240`) — **같은 실행 레인이다**,
# "무관한 도구 상수"가 아니다(fix round 1 의 지적). `zone_inject.jl` 도 같은 이유로 스캔 대상에
# 얹었다(현재는 매치되는 전역이 0개지만, 새 전역이 생기면 그때도 잡혀야 한다).
#
# `extra_files` 로 세 파일을 명시적으로 얹는다. 반대로 **의도적으로 범위 밖에 남긴 것**:
# `tools/` 의 나머지 파일(`server.jl` 등, `run_demo.jl` 이 include 하지 않는다) ·
# `wm4spacecraft_manufacturing/*.jl`(run_demo.jl 이 `objective.jl`/`action_registry.jl` 을
# include 하지만, 둘 다 실측 결과 순수 설정/캐시 전역뿐이고 그 디렉터리는 다른 에이전트가
# 리뷰 중이다) · `test/*.jl`(테스트 스캐폴딩용 상수, 예: `test/greedy_cost_dispatch_equivalence.jl`).
# 이 경계 밖에서 새 진짜 상태가 나오면 이 파일이 그 사실을 놓친다 — 그 한계를 여기 명시한다.
#
# ---- 스캐너 자체의 구조적 사각지대 (fix round 1, [Critical] #3) -------------------------------
# 원래 정규식은 `= Ref(...)` 만 봤다. 그래서 `const CARRIER_LAST_D = Dict{Any,Float64}()` 같은
# **Ref 로 안 감싼 가변 컨테이너 const**(Dict/Set/Vector 등)를 구조적으로 볼 수 없었다 —
# `replace_robot.jl` 의 이 컨테이너가 정확히 그 모양이고, 실제로 교체 로직의 텔레포트 판정을
# 가른다(`:826-829`). 이제 세 모양을 잡는다:
#   1. `Ref(...)` / `Ref{T}(...)`                              (원래 규칙)
#   2. `Dict/Set/Vector/OrderedDict/IdDict/Array/OODQueue(...)`  (알려진 가변 컨테이너 생성자)
#   3. `Any[...]` / `String[...]` 같은 대괄호 리터럴 배열
#
# 그래도 남는, **의도적으로 안 잡는** 모양(전부 src/ 전체를 grep 해 지금은 0건임을 확인했다 —
# 이론적 사각지대이지 지금 당장 새는 구멍은 아니다):
#   - 한 줄에 `const` 가 둘(`const A = 1; const B = 2`)
#   - 들여쓴 최상위 const(모듈 본문이 들여써진 경우)
#   - `Base.RefValue{T}()` 명시적 생성자(관용구는 항상 `Ref(...)`)
#   - `const` 없는 최상위 가변 전역
#   - 소문자 전역 이름(관례 위반 — 이 레포는 전부 대문자다)
#   - 위 2번 목록에 없는 **커스텀 가변 구조체 생성자**(예: 새 `mutable struct`). `OODQueue` 는
#     수작업 감사로 찾아 목록에 넣었다 — 일반적으로 감지할 수 없다(타입 정보 없이 "이 식별자가
#     가변 컨테이너 생성자인가"를 정규식으로 결정할 수 없다: `SMatrix{...}(...)` 처럼 **불변**
#     생성자도 똑같은 문법을 쓴다). 새 커스텀 가변 컨테이너 전역을 만들면 **2번 목록에 이름을
#     추가해야 스캐너가 본다** — 안 하면 코드 리뷰로만 잡힌다. 이 사실 자체가 이 인벤토리의
#     한계다.
#   면역: 불변 리터럴(숫자, 정규식 `r"..."`, 튜플, `SMatrix` 등 불변 타입)은 애초에 "상태"가
#   아니므로(내용이 절대 안 바뀐다) 스캐너가 놓쳐도 스냅샷 관점에서 무해하다 — 그래서 2번
#   목록을 "가변 컨테이너로 알려진 이름"으로 좁게 유지했다(범용 "식별자(...)" 매칭은 안 했다 —
#   그러면 `get(ENV, "X", "y")`/`parse(Int, ...)` 같은 흔한 ENV 파싱 표현식까지 전부 잡혀
#   `run_demo.jl`/`policy.jl` 의 setup 스칼라 수십 개가 쏟아져 들어온다. 실측 확인함).
# =============================================================================

const STATE_GLOBALS = Dict{Symbol,Symbol}(
    # ---- s (Markov 상태) ---------------------------------------------------------------
    :BATTERY_FLEET          => :state,   # Fleet: soc_r · energy_r
    :STALLED_ROBOTS         => :state,   # Fleet.stalled_r — 빼면 복구 판정이 갈린다
    :BATTERY_DELIVERIES     => :state,   # Courier 블록 전체
    :AGENT_COST_BIAS        => :state,   # G 의 엣지 가중치 배수 (Deprioritize 의 지연 효과)
    :RESTRICTION_ZONES      => :state,   # Geo: 활성 no-go 구역
    :SPARE_POOLS            => :state,   # Fleet.role_r 이 여기서 유도된다
    :SPARE_SLOTS            => :state,
    :FAULTED_ROBOTS         => :state,   # Fleet.health_r
    :RECOVERY_SPARES        => :state,   # Fleet.role_r
    :CHECKED_OUT_SPARES     => :state,
    :DECOMMISSIONED_BODIES  => :state,
    :HOT_SWAP_ASSETS        => :state,
    :WEDGE_EDGES            => :state,   # G: ReformTeam 이 남기는 **영구 편집** (spec §5.4-b)
    :DISSOLVED_GATES        => :state,   # G: 같은 이유
    :SNAP_COUNT             => :state,   # Age: 3회 임계 escalation — C1 위반 (spec §5.4-b)
    :SIM_STEP               => :state,   # Clock: 시계 단일 진실원 (태스크 8)
    :LAST_EDGE_COSTS        => :state,   # G6 센티넬이 읽는다 (spec §3.6)
    :RESPEC_HOLD            => :state,   # ⚠️ 에피소드 중 변한다. G1 이 최종 판정한다

    # ---- fix round 1: 오분류 정정 (재확인 완료, 아래 각 줄에 근거) -------------------------
    :RESPEC_FROZEN          => :state,   # ex-:setup. reassign.jl:365 에서 매 재배정마다 다시 쓴다
                                          # (완료 노드 집합). compiler.jl:147 의 is_agent_frontier
                                          # 가 그 값으로 "이 정점이 이미 완료됐나"를 판정한다 —
                                          # 없으면 재계획 가능 여부 판정 자체가 갈린다.
    :RESPEC_PINNED          => :state,   # ex-:setup. 같은 자리(reassign.jl:366)에서 함께 쓴다
                                          # (완료∪진행중 집합). compiler.jl:148 이 프론티어 판정의
                                          # 두 번째 조건으로 읽는다.
    :_IDENTITY_SEEN         => :state,   # ex-:log. identity.jl:281-282 — 이미 본 위반은 "새로움"
                                          # 판정에서 빠진다. identity.jl:284 의 `IDENTITY_STRICT[]
                                          # && fresh > 0` 이 그 판정으로 `error()` 를 던질지 정한다.
                                          # 즉 이 집합의 내용이 프로그램이 죽는지 여부를 가른다 —
                                          # 복원 안 되면 이미 봤던 위반이 "새로" 보여 잘못 죽는다.
    :CARRIER_LAST_D         => :state,   # 신규(구조적 사각지대 #3). replace_robot.jl:731 —
                                          # `const CARRIER_LAST_D = Dict{Any,Float64}()`, Ref 로
                                          # 안 감쌌다. :826-829 에서 이전 스텝 대비 남은 거리를
                                          # 비교해 "정체됐다" 를 판정하고 그 판정이 텔레포트 복구를
                                          # 트리거한다 — 실제 동역학 분기.
    :RESPEC_QUEUE           => :state,   # 신규(구조적 사각지대 #3). replan.jl:138 —
                                          # `const RESPEC_QUEUE = OODQueue()`(가변 struct, Ref
                                          # 아님). `.pending` 에 쌓인 NL 이벤트 문자열이 아직
                                          # `maybe_respecify!` 로 소비되지 않았으면, 그 대기열
                                          # 자체가 "곧 실행될 재명세"라는 진짜 미래 상태다 —
                                          # 복원 안 되면 그 이벤트가 통째로 증발한다.

    # ---- run_demo.jl / policy.jl 확장분 (I12 + fix round 1) --------------------------------
    :_REFORM_CT             => :state,   # 발화 횟수 게이팅 — SNAP_COUNT 와 같은 모양의 임계
                                          # 카운터(연속 무성과 N 회마다 ReformTeam 재발화, :849-850)
    :_ZONE_CT                => :state,  # 존 주입 키 접미사(`zone_inj_$(_ZONE_CT[])` 등) — 이
                                          # 카운터 값이 RESTRICTION_ZONES 딕셔너리의 실제 키에
                                          # 그대로 들어간다. 복원 안 되면 재주입 시 기존 키와
                                          # 충돌할 수 있다 — 로그가 아니라 상태다.
    :ZONE_DECIDE_DEFERRED   => :state,   # pre-sim 존 결정을 첫 배치 완료 뒤로 미룰지 — 실제
                                          # 분기를 가르는 제어 상태 (:754, :815-816)
    :_DECISION_N            => :state,   # policy.jl:710 — `_next_decision_index!()` 가 매 결정마다
                                          # 증가시키고, `should_deviate(at, arm, idx)` 가 그 idx 로
                                          # "지금 이 결정에서 팔을 갈아쓸지" 를 정한다(:719 이하).
                                          # 복원 안 되면 재생 시 다른 결정에서 deviation 이 걸린다.
    :_DECISIONS             => :log,     # run_demo.jl:77 — 결정마다 push! 하는 리포팅용 트레이스
                                          # (:337 push!, :905-906 DEMO_SUMMARY 로 그대로 방출).
                                          # 다시 읽어 분기하는 소비처가 없다 — 순수 출력.

    # ---- 분할 --------------------------------------------------------------------------
    # 비율 인자·broken·eff·usage_s·expired → s
    # cum_*·thr_*·rng_*·pending_drop      → ξ   (무기억성: cum 은 미래에 정보를 안 나른다)
    # events                              → log
    :HAZARD_STATE           => :split,
    :OOD_SCHEDULE           => :split,   # ex-:setup(fix round 1, [Critical] #1). 컨테이너 자체
                                          # (`Vector{OODTrigger}`)는 스케줄링 시점에 고정되지만,
                                          # 원소인 `OODTrigger.fired::Bool` 이
                                          # ood_injection.jl:1197 에서 발동 시 true 로 뒤집힌다 —
                                          # HAZARD_STATE 와 같은 모양(컨테이너 일부는 setup 처럼
                                          # 고정, 일부는 에피소드 중 변한다). step/action!/closed_at
                                          # 은 setup 성격(스케줄 시점에 고정) · fired 는 상태.

    # ---- ξ (재생 상태) -----------------------------------------------------------------
    :_CACHE_TIMESTAMP_COUNTER => :replay, # 부기 카운터. 복원해야 바이트 동일이 성립한다
    :ASSET_LEDGER           => :replay,   # ex-:log(fix round 1, [Important] #5). 재확인: `asset_of`
                                          # (`:118-119`)·`asset_generation` 의 유일한 소비처는
                                          # replace_robot.jl:1473,1478,1553 이고 전부 `@info` 진단
                                          # 문자열/다른 장부 기록에 값을 실어 나를 뿐, 어떤 분기도
                                          # 그 반환값으로 갈리지 않는다(결정에 안 쓰인다 — 그래서
                                          # `:state` 는 아니다). 그러나 "빌드 경계에서 일부러 안
                                          # 비운다"는 append-only 이력이라, 복원 안 되면
                                          # `asset_of`/`asset_generation` 이 다시 부를 때 다른 세대
                                          # 번호를 내고 그게 이후 로그 문자열·기록으로 새 나가
                                          # 바이트 동일 재현이 깨진다 — `_CACHE_TIMESTAMP_COUNTER`
                                          # 와 같은 이유로 `:log` 가 아니라 `:replay`.

    # ---- log ---------------------------------------------------------------------------
    :OOD_TRUTH_LOG          => :log,
    :_DRAWN_ZONE_MARKERS    => :log,
    :_DRAWN_DEPOT_MARKERS   => :log,
    :_DRAWN_DECOMMISSIONED  => :log,
    :ZONE_SNAP_STATS        => :log,
    :LAST_AUTO_EFFICIENCY_W => :log,     # 진단용 — 결정에 안 쓰인다
    :MONITOR_IO             => :log,
    :MONITOR_RESPEC         => :log,
    :MONITOR_CONTROL_HOOK   => :log,
    :MONITOR_RESPEC_HISTORY => :log,     # 신규(구조적 사각지대 #3). monitor.jl:19 — "이 런의 모든
                                          # OOD 결정"을 push! 로 쌓는 출력 전용 트레이스.
    :MONITOR_RECOVERY_LOG   => :log,     # 신규. monitor.jl:20 — 컨트롤러 자체 복구 조치 로그.

    # ---- meta (s 에 넣지 않는다 — spec §6.1) --------------------------------------------
    :NOVELTY_DETECTOR       => :meta,

    # ---- 셋업 상수 / 배선 훅 / ENV 손잡이 ----------------------------------------------
    :SPARE_POOL_CENTERS     => :setup,   # spec §3.6: 셋업 상수 — 스냅샷 불필요
    :DEPOT_INFO             => :setup,
    :HAZARD_ENABLED         => :setup,
    :_HAZARD_PREV_STEP_HOOK => :setup,
    :BATTERY_STEP_HOOK      => :setup,
    :SOC_SPEED_HOOK         => :setup,
    :DRAIN_FACTOR_HOOK      => :setup,
    :BATTERY_ACCOUNTING     => :setup,
    :BATTERY_COURIER_CFG    => :setup,
    :BATTERY_DERATE         => :setup,
    :BATTERY_PENALTY        => :setup,
    :BATTERY_STALL          => :setup,
    :DEPRIORITIZE_KAPPA     => :setup,
    :HOT_SWAP_MODE          => :setup,
    :HOT_SWAP_REPLACE       => :setup,
    :IDENTITY_CHECK         => :setup,
    :IDENTITY_CHECK_EVERY   => :setup,
    :IDENTITY_STRICT        => :setup,
    :REFORM_INTERVAL        => :setup,   # ⚠️ 이 값이 Age.no_progress 의 modulo 를 정한다
    :RELOCATE_GATE          => :setup,
    :REPLACE_SOC_THRESHOLD  => :setup,
    :RESPEC_DRIFT_REPAIR    => :setup,
    :RESPEC_ENABLED         => :setup,
    :RESPEC_PRODUCER        => :setup,
    :SNAP_ESCALATE_AT       => :setup,
    :SPARE_DEPOT_DISTANCE   => :setup,
    :SPARE_POOL_MARGIN_FACTOR => :setup,
    :_SPARE_MARGIN_DEPRECATED => :setup,
    :ZONE_DOMAIN_GATE       => :setup,
    :AUTO_EFFICIENCY_KAPPA  => :setup,
    :EDGE_COST_MULTIPLIER   => :setup,
    :ENERGY_MODEL           => :setup,
    :GREEDY_ENERGY_W        => :setup,
    :PLANNING_OBJECTIVE_WEIGHTS => :setup,
    :NOVELTY_FLEET_REF      => :setup,   # ex-:meta(fix round 1, [Minor] #7). 재확인: novelty.jl:293
                                          # 선언 뒤 어디서도 대입되지 않는다(레포 전체 grep 0건) —
                                          # 고정 스케일 상수(명목 함대 크기 30.0)일 뿐, 관측 이력을
                                          # 쌓는 meta-state 가 아니다.
    :NOVELTY_FEATURES       => :setup,   # 신규(구조적 사각지대 #3). novelty.jl:110 — 고정 피처
                                          # 스키마 이름 목록(bracket 리터럴). 비교만 되고
                                          # push!/append! 되는 자리가 없다(확인함).
    :_LDRAW_INDEXED_LIBRARIES => :setup, # 신규. full_demo.jl:26 — LDraw 파트 라이브러리 경로
                                          # 캐시를 한 번만 채우는 프라이밍 집합(모델 로드 설정
                                          # 단계, 에피소드 동역학과 무관).
    :STATE_GLOBALS          => :setup,   # 자기 참조. 이 Dict 자신도 확장된 스캐너의 컨테이너
                                          # 모양(Dict{...}(...))에 걸린다 — 모듈 로드 후 절대
                                          # mutate 되지 않는 정적 분류표이므로 :setup.
    :DSPY_HEALTHY           => :setup,   # 신규(policy.jl:384). "이미 확인했으면 그 값을 그대로
                                          # 돌려준다"(:388) 는 멱등 메모이제이션 — 프로세스
                                          # 수명 동안 한 번 정해지면 안 바뀌는 헬스체크 캐시.

    # ---- 시각화 전용 --------------------------------------------------------------------
    :LIVE_PUSH              => :render,
    :CAMERA_FOLLOW          => :render,
    :CAMERA_FOLLOW_MAP      => :render,
    :_VIS_FRAME             => :render,
    :_COURIER_TINT_FRAMES   => :render,
    :_BATTERY_TINT_FRAMES   => :render,
    :BATTERY_TINT_HOLD_FRAMES => :render,
    :BATTERY_DELIVERY_FRAME_EVERY => :render,
    :_BATTERY_SWAP_FRAME    => :render,  # 신규. render_tools.jl:821 — _VIS_FRAME 과 짝지어 쓰는
                                          # 애니메이션 프레임 인덱스 부기(:917 에서 함께 리셋).
    :MONITOR_FAULTED        => :render,  # 신규. monitor.jl:21 — "FAULT 로 표시할 로봇 id"
                                          # (monitor.jl:150). 실제 고장 판정은 FAULTED_ROBOTS(:state)
                                          # 가 갖고 있고, 이건 그걸 반영한 디스플레이 전용 거울.
    :MONITOR_NODE_T         => :render,  # 신규. monitor.jl:22 — Gantt 차트용 정점 타이밍(:216-226).
    :MONITOR_HANDOFF_T      => :render,  # 신규. monitor.jl:23 — 예비 인계 시각, monitor emit 의
                                          # JSON 필드로만 나간다(:213,:420-496).
)

# ---- 정규식 ----------------------------------------------------------------------------
# 셋 다 앵커(`^const\s+`)로 최상위(들여쓰기 없는) 선언만 잡는다.
const _PAT_REF     = r"^const\s+(_?[A-Z][A-Z_0-9]*)\s*=\s*Ref\b"
const _CONTAINER_CTORS = ("Dict", "Set", "Vector", "OrderedDict", "IdDict", "Array", "OODQueue")
const _PAT_CTOR     = Regex("^const\\s+(_?[A-Z][A-Z_0-9]*)\\s*=\\s*(?:" *
                             join(_CONTAINER_CTORS, "|") * ")\\b.*\\(")
const _PAT_BRACKET = r"^const\s+(_?[A-Z][A-Z_0-9]*)\s*=\s*[A-Za-z_][A-Za-z0-9_]*\["

function _scan_file!(out::Vector{Symbol}, path::AbstractString)
    isfile(path) || return out
    for line in eachline(path)
        for pat in (_PAT_REF, _PAT_CTOR, _PAT_BRACKET)
            m = match(pat, line)
            m === nothing || push!(out, Symbol(m.captures[1]))
        end
    end
    return out
end

"""
    scan_globals(root; extra_files=String[]) -> Vector{Symbol}

`root` 아래 모든 `.jl` 에서 최상위 `const NAME = <가변 컨테이너>` 전역 이름을 모은다
(`Ref(...)`, 알려진 컨테이너 생성자, 대괄호 배열 리터럴 — 위 헤더의 세 모양). 파일 헤더의
"구조적 사각지대" 절이 이 스캐너가 놓치는 나머지 모양을 명시한다.

`extra_files` 는 `root` 재귀 훑기 밖에 있는 개별 파일을 추가로 훑는다 — `tools/monitor/run_demo.jl`
· `policy.jl` · `zone_inject.jl` 이 실제 실행 레인인데 `src/` 밖이라(I12 + fix round 1), `root`
를 `tools/` 전체로 넓히지 않고 그 파일들만 명시적으로 얹기 위한 통로다.
"""
function scan_globals(root::AbstractString; extra_files::AbstractVector{<:AbstractString}=String[])
    out = Symbol[]
    for (dir, _, fs) in walkdir(root), f in fs
        endswith(f, ".jl") || continue
        _scan_file!(out, joinpath(dir, f))
    end
    for path in extra_files
        _scan_file!(out, path)
    end
    return sort!(unique!(out))
end

"인벤토리에 없는 전역(새로 생겼는데 미분류). 비어 있지 않으면 테스트가 죽는다."
unclassified_globals(root::AbstractString; extra_files::AbstractVector{<:AbstractString}=String[]) =
    [g for g in scan_globals(root; extra_files=extra_files) if !haskey(STATE_GLOBALS, g)]

"""
    stale_globals(root; extra_files=String[]) -> Vector{Symbol}

인벤토리에는 있는데 스캔된 소스에는 더는 없는 전역(유령 엔트리 — 삭제됐는데 표에 남았다).
비어 있지 않으면 테스트가 죽는다. 이 방향은 `unclassified_globals` 의 거울이다: 저쪽은
"새 전역이 생겼는데 표가 모른다" 를 잡고, 이쪽은 "표가 아는 전역이 실은 이제 없다" 를 잡는다 —
2026-08-20 fix round 1 에서 `_SIM_STEP` 이 태스크 8 의 시계 통일로 `run_demo.jl` 에서 지워졌는데
표에는 그대로 남아 `unclassified_globals` 만으로는 절대 못 잡던 바로 그 실패 모양이다.
"""
function stale_globals(root::AbstractString; extra_files::AbstractVector{<:AbstractString}=String[])
    found = Set(scan_globals(root; extra_files=extra_files))
    return sort!([k for k in keys(STATE_GLOBALS) if !(k in found)])
end

"처분이 `disp` 인 전역 이름들 (오름차순). snapshot/restore! 가 이 목록으로 돈다."
globals_with(disp::Symbol) = sort!([k for (k, v) in STATE_GLOBALS if v === disp])
