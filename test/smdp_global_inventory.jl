# test/smdp_global_inventory.jl
# spec §3.6 — 스냅샷 대상 전역의 전수 목록을 **기계로** 지킨다.
#
# 왜 테스트여야 하는가: 표로만 두면 새 전역이 생겼을 때 아무것도 안 잡는다. snapshot/restore!
# 가 그 전역을 모르면 롤아웃마다 조용히 오염된다 — 에러가 아니라 **결과의 미세한 차이**로만
# 새는 실패 모양이라 사후에 못 찾는다(spec §3.5 규칙 3).
#
# 범위(controller-addendum.md 태스크 7, I12 + fix round 1): `scan_globals` 는 `src/` 를 재귀로
# 훑고, 거기에 `tools/monitor/run_demo.jl` · `policy.jl` · `zone_inject.jl` 을 `extra_files` 로
# **의도적으로** 얹는다 — run_demo.jl 이 policy.jl 을 직접 include 하므로(`:240`) 셋 다 같은
# 실행 레인이다. `tools/` 의 나머지·`wm4spacecraft_manufacturing/*.jl`·`test/*.jl` 은
# **의도적으로 범위 밖**이다(state_globals.jl 헤더에 근거를 적어 뒀다).
#
# ✅ 2026-08-20 해소: 예전에는 이 테스트를 작업 트리에서 돌리면 `유령 전역이 없다` 가 유령 9개로
# 빨갛게 났다 — `src/safety/cbf.jl` 의 삭제가 스테이징만 돼 있고(CBF_* 8개) `replan.jl` 의
# FAILCLOSED_STOP 제거가 미커밋이었기 때문이다. 그 둘이 커밋되면서 표에서도 아홉 엔트리를
# 같이 뺐고, 이제 작업 트리와 HEAD 가 같은 답을 낸다.
# **계약이 성립하는 자리는 여전히 HEAD**(`git archive` 로 뽑은 순정 체크아웃)다 — 작업 트리가
# 초록이라고 HEAD 가 초록인 것은 아니다. 이 레포는 그 차이로 이미 두 번 데였다.
#
#   julia +lts --project=. test/smdp_global_inventory.jl
using ConstructionBots
using Test
const CB = ConstructionBots

CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

const SRC = normpath(joinpath(@__DIR__, "..", "src"))
const RUN_DEMO_JL   = normpath(joinpath(@__DIR__, "..", "tools", "monitor", "run_demo.jl"))
const POLICY_JL     = normpath(joinpath(@__DIR__, "..", "tools", "monitor", "policy.jl"))
const ZONE_INJECT_JL = normpath(joinpath(@__DIR__, "..", "tools", "monitor", "zone_inject.jl"))
const EXTRA_FILES = [RUN_DEMO_JL, POLICY_JL, ZONE_INJECT_JL]

@testset "스캐너가 알려진 전역을 찾는다 (src/)" begin
    found = CB.scan_globals(SRC)
    for name in (:BATTERY_FLEET, :HAZARD_STATE, :SNAP_COUNT, :WEDGE_EDGES,
                 :RESTRICTION_ZONES, :SIM_STEP, :STALLED_ROBOTS, :BATTERY_DELIVERIES,
                 :CARRIER_LAST_D, :RESPEC_QUEUE,   # fix round 1: 구조적 사각지대 #3 (non-Ref 컨테이너)
                 :RVO_ID_GLOBAL_MAP, :RVO_SIM_WRAPPER,           # fix round 2: 사각지대 #4
                 :INVALID_ID_COUNTERS,                            # (const 없는 최상위 global)
                 :projects, :project_parameters)   # fix round 3: 소문자 컨테이너 리터럴 (const 없음)
        @test name in found
    end
    # 죽은 `>= 70` 하한을 round 3 이 `length(found) == length(scan_globals(SRC))` 로 바꿨는데
    # 그건 **순수 결정 함수를 두 번 불러 자기 자신과 비교하는 항진명제**라 실패할 수 없었다
    # (재리뷰 3 [Minor]) — 죽은 어서션을 다른 죽은 어서션으로 바꾼 것이다. round 4 에서 지웠다.
    # 진짜 계약은 아래 "분류되지 않은 전역이 없다"/"유령 전역이 없다" 의 **집합 등호** 둘이고,
    # "스캐너가 실제로 파일을 훑는가"는 바로 위 이름 15개 어서션이 이미 지킨다(그 15개는
    # 하나라도 스캔에서 빠지면 빨개진다 — 실패 가능한 검사다).
end

@testset "스캐너가 run_demo.jl/policy.jl 의 전역도 찾는다 (범위 확장, I12 + fix round 1)" begin
    found = CB.scan_globals(SRC; extra_files=EXTRA_FILES)
    for name in (:_ZONE_CT, :ZONE_DECIDE_DEFERRED, :_DECISION_N, :DSPY_HEALTHY, :_DECISIONS,
                 :RUN_CTX, :_RID_CTR)     # 2026-09-22(R12): `_RID_CTR` 은 `Threads.Atomic` 모양
        @test name in found
    end
    # `_REFORM_CT` 는 2026-08-24 축 C(Task 6)가 run_demo.jl 에서 지웠다 — `ReformTruth` 발화
    # 경로 전체를 삭제하면서 그 카운터도 같이 없앴고, `state_globals.jl` 의 표 항목도 지웠다.
    # `_SIM_STEP` 과 같은 모양의 음성 대조 — 여기 있으면 유령 엔트리다.
    @test !(:_REFORM_CT in found)
    # _SIM_STEP 은 태스크 8(시계 단일 진실원 통일)이 run_demo.jl 에서 지웠다 — 여기 있으면 안 된다.
    # 이 음성 대조가 바로 fix round 1 이 잡은 살아있는 레드(유령 엔트리)의 반대쪽 증거다.
    @test !(:_SIM_STEP in found)
    # extra_files 없이 SRC 만 훑으면 이 여섯은 안 보여야 한다 — 확장이 실제로 그 파일들을 보는지,
    # 이미 src/ 안에 있는 이름과 우연히 겹친 게 아닌지 구분하는 음성 대조.
    without_extra = CB.scan_globals(SRC)
    for name in (:_REFORM_CT, :_ZONE_CT, :ZONE_DECIDE_DEFERRED, :_DECISION_N, :DSPY_HEALTHY, :_DECISIONS,
                 :RUN_CTX, :_RID_CTR)
        @test !(name in without_extra)
    end
end

@testset "분류되지 않은 전역이 없다 (src/ + run_demo.jl/policy.jl/zone_inject.jl, 그 밖은 범위 밖)" begin
    missing = CB.unclassified_globals(SRC; extra_files=EXTRA_FILES)
    isempty(missing) || @info "분류 안 된 전역" missing
    @test isempty(missing)
end

@testset "표에 있는데 스캔에는 없는 유령 전역이 없다 (fix round 1 — 반대 방향)" begin
    # unclassified_globals 는 "새 전역이 생겼는데 표가 모른다" 만 잡는다. _SIM_STEP 이 정확히
    # 보여준 실패는 반대 방향이다 — "표가 아는 전역이 이제 코드에 없다". 둘 다 지켜야 인벤토리가
    # 닫힌다. round 3 note: 이 테스트셋은 HEAD(커밋된 트리) 기준으로 초록이어야 하는 것이지,
    # 다른 태스크의 미완료 작업 트리 변경(cbf.jl 삭제 스테이징) 기준이 아니다 — 위 파일 헤더 참고.
    stale = CB.stale_globals(SRC; extra_files=EXTRA_FILES)
    isempty(stale) || @info "유령 전역(표에는 있는데 스캔에는 없다)" stale
    @test isempty(stale)
    # 진짜 계약은 등호다: 표의 키 집합이 스캔 결과와 정확히 같아야 한다.
    found = Set(CB.scan_globals(SRC; extra_files=EXTRA_FILES))
    @test Set(keys(CB.STATE_GLOBALS)) == found
end

@testset "RHS 머리 census 가 닫혀 있다 (fix round 3, [Critical]#3)" begin
    # "커스텀 가변 구조체 생성자는 영구 측정 불가능"이라던 round 2 의 주장이 과장이었다 —
    # 재리뷰가 지적한 대로 실제 RHS 머리 식별자는 유한(15개)하고 열거 가능하다. 이 census 가
    # 비어 있지 않은 새 머리를 보면(예: 다음 태스크가 또 다른 `Base.XXX` 를 최상위에 박으면)
    # 여기서 죽는다 — round 2 의 "발견 메커니즘이 없다"는 고백을 갚는 조치.
    unknown = CB.unknown_rhs_heads(SRC; extra_files=EXTRA_FILES)
    isempty(unknown) || @info "새로운 RHS 머리(사람이 아직 안 봄)" unknown
    @test isempty(unknown)
    # round 4, [Important]#3: round 3 의 이름 그룹은 ALL_CAPS 전용이라, 같은 커밋이 방금 실재를
    # 증명한 소문자 최상위 전역 클래스(projects · project_parameters)를 census 가 구조적으로 못
    # 봤다. 이제 snake_case 소문자도 본다 — 스크래치 사본에서 `baz = NovelLowerCtor(2)` 로
    # 레드 재현했다(state_globals.jl `rhs_heads` 독스트링에 그 실측). 여기서는 census 가 실제로
    # 소문자 선언줄을 읽고 있다는 살아있는 증거를 건다: run_demo.jl 최상위의 소문자 바인딩에서만
    # 나오는 머리들이다(ALL_CAPS 전용 그룹으로는 절대 안 나온다).
    heads = CB.rhs_heads(SRC; extra_files=EXTRA_FILES)
    for h in ("replace", "joinpath", "CB.run_lego_demo", "Graphs.nv", "isfile")
        @test h in heads
    end
    # allowlist 는 하나뿐이다(round 4): `_rhs_head!` 안의 두 번째 하드코딩 목록을 합쳤다.
    # 옛 숨은 목록의 원소가 이제 공시된 집합 안에 있어야 한다.
    for h in ("get", "parse", "ConstructionBots", "Objective.objective_hash")
        @test h in CB.KNOWN_RHS_HEADS
    end
    @test !("true" in CB.KNOWN_RHS_HEADS)   # 리터럴/예약어는 allowlist 가 아니라 파싱 필터다
    # 살아있는 사례: src/smdp/simstate.jl:24 의 `const SHA = Base.require(...)` 가 이전엔 네
    # 패턴 중 어디에도 안 걸렸다 — 지금은 이 census 가 "Base.require" 를 알려진 머리로 잡는다.
    @test "Base.require" in CB.rhs_heads(SRC; extra_files=EXTRA_FILES)
end

@testset "처분 어휘가 닫혀 있다" begin
    ok = Set([:state, :replay, :split, :log, :setup, :render, :meta])
    @test all(v -> v in ok, values(CB.STATE_GLOBALS))
end

@testset "s 로 가는 전역이 spec §3.6 을 덮는다" begin
    st = Set(k for (k, v) in CB.STATE_GLOBALS if v === :state)
    for name in (:BATTERY_FLEET, :STALLED_ROBOTS, :BATTERY_DELIVERIES, :AGENT_COST_BIAS,
                 :RESTRICTION_ZONES, :SPARE_POOLS, :SPARE_SLOTS, :FAULTED_ROBOTS,
                 :RECOVERY_SPARES, :CHECKED_OUT_SPARES, :DECOMMISSIONED_BODIES,
                 :HOT_SWAP_ASSETS, :WEDGE_EDGES, :DISSOLVED_GATES, :SNAP_COUNT,
                 :SIM_STEP, :LAST_EDGE_COSTS, :RESPEC_FROZEN, :RESPEC_PINNED,
                 :_IDENTITY_SEEN, :CARRIER_LAST_D, :RESPEC_QUEUE, :_DECISION_N,
                 :INVALID_ID_COUNTERS)   # fix round 2: 사각지대 #4, mid-episode 발급
    # 2026-08-20: `:CBF_HOLD` 가 여기 있었다. `src/safety/cbf.jl` 삭제가 커밋되면서 그 전역이
    # 사라졌고, 같은 커밋에서 표의 `CBF_*` 8 + `FAILCLOSED_STOP` 도 함께 빠졌다.
        @test name in st
    end
    @test CB.STATE_GLOBALS[:HAZARD_STATE] === :split     # 셋으로 쪼개진다
    @test CB.STATE_GLOBALS[:OOD_SCHEDULE] === :split     # fired 만 상태, 나머지는 setup (fix round 1)
    @test CB.STATE_GLOBALS[:ASSET_LEDGER] === :replay    # 결정에 안 쓰인다, 바이트 동일 재현용 (fix round 1/2)
    @test CB.STATE_GLOBALS[:NOVELTY_DETECTOR] === :meta  # spec §6.1 — s 에 넣지 않는다
    @test CB.STATE_GLOBALS[:NOVELTY_FLEET_REF] === :setup  # never-written 상수 (fix round 1)
    # fix round 2 재분류 (re-derived, review 근거 정정 포함):
    @test CB.STATE_GLOBALS[:RVO_ID_GLOBAL_MAP] === :replay  # spec: RVO 핸들은 ξ
    @test CB.STATE_GLOBALS[:RVO_SIM_WRAPPER] === :replay    # 같은 서브시스템, 같은 트리거
    @test CB.STATE_GLOBALS[:RVO_PYTHON_MODULE] === :replay  # 같은 호출 사슬에서 같이 재로드
    @test CB.STATE_GLOBALS[:DSPY_HEALTHY] === :replay       # ex-:setup — _CACHE_TIMESTAMP_COUNTER 와 같은 논리
    # monitor.jl 다섯 전역은 전부 monitor_emit! 을 거쳐 MONITOR_IO(:log) 파일로 나간다 — 통일.
    for name in (:MONITOR_FAULTED, :MONITOR_NODE_T, :MONITOR_HANDOFF_T,
                 :MONITOR_RESPEC_HISTORY, :MONITOR_RECOVERY_LOG)
        @test CB.STATE_GLOBALS[name] === :log
    end
    # fix round 4, [Critical]#1: VALID_ID_COUNTERS 는 **:state 다**. round 3 이 `get_unique_id`
    # 의 **텍스트** 호출 15자리만 훑고 :setup 으로 강등했는데, 실제 발급은 암묵 생성자 사슬에서
    # 일어난다: construction_schedule.jl:91-94 `$T(n::SceneNode) = $T(n, TransformNode())`
    # -> hierarchical_geom_essentials.jl:326 `TransformNode()` -> :317 `get_unique_id`.
    # 그 자리(replace_robot.jl:173 · reassign.jl:265)는 route_planning.jl:271 `respec_step!`
    # 이 매 스텝 도는 핫스왑 경로다. 라이브 프로브 실측: `RobotStart(rn)` 한 번에
    # TransformNodeID 2 -> 3. 근거 전문은 state_globals.jl 의 이 항목 주석.
    @test CB.STATE_GLOBALS[:VALID_ID_COUNTERS] === :state
    @test :VALID_ID_COUNTERS in st
    # fix round 3, [Critical]#1 이 여기서 `CBF_ENABLED`/`CBF_STATS`/`FAILCLOSED_STOP` 의 처분을
    # 못박고 있었다. 2026-08-20 에 `src/safety/cbf.jl` 삭제 + `replan.jl` 의 FAILCLOSED_STOP
    # 제거가 커밋되면서 세 전역이 소스에서 사라졌고 표에서도 같이 빠졌다 — 아래 집합 등호
    # (`Set(keys(STATE_GLOBALS)) == found`)가 그 동시성을 강제한다.
    # fix round 3, [Important]#2: 소문자 전역도 존재한다(project_params.jl) — 둘 다 재대입 없음.
    @test CB.STATE_GLOBALS[:projects] === :setup
    @test CB.STATE_GLOBALS[:project_parameters] === :setup
end
