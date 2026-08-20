# =============================================================================
# spec §3.6 — 스냅샷 대상 전역의 전수 목록. **문서가 아니라 계약이다.**
#
# 처분 어휘:
#   :state   → s 로 들어간다 (Markov 상태. 모델 입력. 콘텐츠 해시 가능해야 한다)
#   :replay  → ξ 로 들어간다 (restore! 와 CRN 만 쓴다. s 에 넣지 않는다 — 넣으면 s 가
#              해시 불가가 되고, thr 을 넣으면 발화 시각이 s 로부터 결정론이 되어 전체
#              시스템이 확률성을 잃는다: spec §3.4)
#   :split   → 한 컨테이너가 s·ξ·log 로 쪼개진다 (지금은 HAZARD_STATE 하나)
#   :log     → 상태 아님. 스냅샷 대상도 아님
#   :setup   → 셋업 상수 / 배선 훅 / ENV 손잡이. 에피소드 중 불변이면 스냅샷 불필요
#   :render  → 시각화 전용. 동역학에 안 닿는다
#   :meta    → meta-level 상태. **s 에 넣지 않는다**(spec §6.1: "이 OOD 를 본 적 있는가"는
#              환경 상태가 아니라 meta-state 다)
#
# 새 전역을 만들면 여기 등록해야 한다 — 안 하면 test/smdp_global_inventory.jl 이 이름을 찍고
# 죽는다. 그게 이 파일의 존재 이유다.
#
# ---- 스캐너 범위 결정 (2026-08-20, controller-addendum.md 태스크 7 판정 I12) --------------------
# 브리프의 스캐너는 `src/` 만 훑는다. 그런데 `tools/monitor/run_demo.jl` 은 그 밖에서 실제
# 에피소드 상태를 쥐고 있다 — 특히 `_REFORM_CT` 는 ReformTruth 발화를 게이팅하는 진짜 동역학
# 상태다. "분류 안 된 전역이 없다"는 주장이 `src/` 안에서만 참이면 그 자체가 조용한 커버리지
# 구멍이라, `scan_globals`/`unclassified_globals` 에 `extra_files` 키워드를 추가해 그 한 파일을
# **의도적으로** 포함시켰다 (테스트 이름·이 주석에 그대로 적는다).
#
# 반대로 `tools/` 의 나머지 파일과 `wm4spacecraft_manufacturing/*.jl` 은 **의도적으로 범위 밖에
# 남겼다** — 실측(`grep -rlP '^const\s+_?[A-Z][A-Z_0-9]*\s*=\s*Ref' --include='*.jl' .`)으로 그
# 파일들에는 테스트 스캐폴딩용 상수(`test/greedy_cost_dispatch_equivalence.jl` 등)·이 태스크가
# 다루지 않는 다른 도구의 상수(`tools/monitor/server.jl`, `tools/monitor/policy.jl` 등)가 섞여
# 있어, 전부 인벤토리에 넣는 것은 이 태스크(spec §3.6, 스냅샷 대상)의 범위를 벗어난다 —
# 스냅샷/복원이 실제로 걷는 것은 시뮬레이션 상태(`src/`)와 그 상태를 직접 바꾸는 데모 하니스
# (`run_demo.jl`) 뿐이고, 테스트 픽스처나 렌더/서버 도구의 전역은 롤아웃 오염 경로가 아니다.
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

    # ---- run_demo.jl 확장분 (I12, :state) ------------------------------------------------
    :_REFORM_CT             => :state,   # 발화 횟수 게이팅 — SNAP_COUNT 와 같은 모양의 임계
                                          # 카운터(연속 무성과 N 회마다 ReformTeam 재발화, :849-850)
    :_SIM_STEP              => :state,   # run_demo.jl 자체 시계 카운터(`src/smdp` 의 SIM_STEP 과는
                                          # 별개 심볼 — 태스크 8 전까지 시계가 둘이다)
    :_ZONE_CT               => :state,   # 존 주입 키 접미사(`zone_inj_$(_ZONE_CT[])` 등) — 이
                                          # 카운터 값이 RESTRICTION_ZONES 딕셔너리의 실제 키에
                                          # 그대로 들어간다. 복원 안 되면 재주입 시 기존 키와
                                          # 충돌할 수 있다 — 로그가 아니라 상태다.
    :ZONE_DECIDE_DEFERRED   => :state,   # pre-sim 존 결정을 첫 배치 완료 뒤로 미룰지 — 실제
                                          # 분기를 가르는 제어 상태 (:754, :815-816)

    # ---- 분할 --------------------------------------------------------------------------
    # 비율 인자·broken·eff·usage_s·expired → s
    # cum_*·thr_*·rng_*·pending_drop      → ξ   (무기억성: cum 은 미래에 정보를 안 나른다)
    # events                              → log
    :HAZARD_STATE           => :split,

    # ---- ξ (재생 상태) -----------------------------------------------------------------
    :_CACHE_TIMESTAMP_COUNTER => :replay, # 부기 카운터. 복원해야 바이트 동일이 성립한다

    # ---- log ---------------------------------------------------------------------------
    :ASSET_LEDGER           => :log,
    :OOD_TRUTH_LOG          => :log,
    :_IDENTITY_SEEN         => :log,
    :_DRAWN_ZONE_MARKERS    => :log,
    :_DRAWN_DEPOT_MARKERS   => :log,
    :_DRAWN_DECOMMISSIONED  => :log,
    :ZONE_SNAP_STATS        => :log,
    :LAST_AUTO_EFFICIENCY_W => :log,     # 진단용 — 결정에 안 쓰인다
    :MONITOR_IO             => :log,
    :MONITOR_RESPEC         => :log,
    :MONITOR_CONTROL_HOOK   => :log,

    # ---- meta (s 에 넣지 않는다 — spec §6.1) --------------------------------------------
    :NOVELTY_DETECTOR       => :meta,
    :NOVELTY_FLEET_REF      => :meta,

    # ---- 셋업 상수 / 배선 훅 / ENV 손잡이 ----------------------------------------------
    :SPARE_POOL_CENTERS     => :setup,   # spec §3.6: 셋업 상수 — 스냅샷 불필요
    :DEPOT_INFO             => :setup,
    :OOD_SCHEDULE           => :setup,   # 에피소드 중 불변이면 상수
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
    :RESPEC_FROZEN          => :setup,
    :RESPEC_PINNED          => :setup,
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

    # ---- 시각화 전용 --------------------------------------------------------------------
    :LIVE_PUSH              => :render,
    :CAMERA_FOLLOW          => :render,
    :CAMERA_FOLLOW_MAP      => :render,
    :_VIS_FRAME             => :render,
    :_COURIER_TINT_FRAMES   => :render,
    :_BATTERY_TINT_FRAMES   => :render,
    :BATTERY_TINT_HOLD_FRAMES => :render,
    :BATTERY_DELIVERY_FRAME_EVERY => :render,
)

"""
    scan_globals(root; extra_files=String[]) -> Vector{Symbol}

`root` 아래 모든 `.jl` 에서 최상위 `const NAME = Ref(...)` 전역 이름을 모은다.
정규식은 인벤토리를 만들 때 쓴 것과 **같은 것**이어야 한다 — 다르면 검사가 새 전역을 놓친다.

`extra_files` 는 `root` 재귀 훑기 밖에 있는 개별 파일을 추가로 훑는다 — `tools/monitor/run_demo.jl`
이 실제 에피소드 상태를 갖고 있는데 `src/` 밖이라(I12), `root` 를 `tools/` 전체로 넓히지 않고
이 한 파일만 명시적으로 얹기 위한 통로다.
"""
function scan_globals(root::AbstractString; extra_files::AbstractVector{<:AbstractString}=String[])
    pat = r"^const\s+(_?[A-Z][A-Z_0-9]*)\s*=\s*Ref"
    out = Symbol[]
    files = String[]
    for (dir, _, fs) in walkdir(root), f in fs
        endswith(f, ".jl") || continue
        push!(files, joinpath(dir, f))
    end
    append!(files, extra_files)
    for path in files
        isfile(path) || continue
        for line in eachline(path)
            m = match(pat, line)
            m === nothing || push!(out, Symbol(m.captures[1]))
        end
    end
    return sort!(unique!(out))
end

"인벤토리에 없는 전역. 비어 있지 않으면 테스트가 죽는다."
unclassified_globals(root::AbstractString; extra_files::AbstractVector{<:AbstractString}=String[]) =
    [g for g in scan_globals(root; extra_files=extra_files) if !haskey(STATE_GLOBALS, g)]

"처분이 `disp` 인 전역 이름들 (오름차순). snapshot/restore! 가 이 목록으로 돈다."
globals_with(disp::Symbol) = sort!([k for (k, v) in STATE_GLOBALS if v === disp])
