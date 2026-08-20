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
# ---- 스캐너 자체의 구조적 사각지대 (fix round 1, [Critical] #3 / fix round 2, [Blocker] #1) ----
# 원래 정규식은 `= Ref(...)` 만 봤다. 그래서 `const CARRIER_LAST_D = Dict{Any,Float64}()` 같은
# **Ref 로 안 감싼 가변 컨테이너 const**(Dict/Set/Vector 등)를 구조적으로 볼 수 없었다 —
# `replace_robot.jl` 의 이 컨테이너가 정확히 그 모양이고, 실제로 교체 로직의 텔레포트 판정을
# 가른다(`:826-829`). fix round 1 에서 세 모양을 추가했고, fix round 2 에서 **네 번째** 모양을
# 추가했다 — round 1 이 "지금은 0건" 이라고 적었던 "`const` 없는 최상위 가변 전역"이 재검증
# 결과 **32건**이었고(재리뷰가 "33건"이라 부른 것과 근사, 아래 참고), 그중 `RVO_ID_GLOBAL_MAP`
# (spec: RVO 핸들은 ξ)·`RVO_SIM_WRAPPER`·`VALID_ID_COUNTERS`/`INVALID_ID_COUNTERS`(무효 id 가
# `reassign.jl:87` 에서 에피소드 중 발급돼 스케줄 그래프에 그대로 박힌다) 는 진짜 상태였다 —
# round 1 의 "0건" 이라는 디스클로저 자체가 틀렸었다(측정 없이 믿은 값). 이제 네 모양을 잡는다:
#   1. `Ref(...)` / `Ref{T}(...)`                                (원래 규칙)
#   2. `Dict/Set/Vector/OrderedDict/IdDict/Array/OODQueue(...)`    (알려진 가변 컨테이너 생성자)
#   3. `Any[...]` / `String[...]` 같은 대괄호 리터럴 배열
#   4. `global NAME = ...` 또는 `NAME = ...`(모듈 최상위, `const` 없음) — Julia 관용구:
#      `global` 키워드는 최상위 선언에서는 생략 가능하고 함수 안에서 그 전역을 바꿀 때만 필요
#      하다(`function f(); global NAME = val; end`). 이 넷째 패턴은 **선언줄**(들여쓰기 없는
#      `global NAME = ...` 또는 `NAME = ...`)만 잡는다 — 함수 본문 안의 `global NAME = val` 재대입
#      줄은 들여써져 있어 앵커(`^`)에 안 걸린다. 그건 의도된 것이다: 선언줄 하나만 잡아도
#      `unclassified_globals`/`stale_globals` 계약은 성립한다(그 이름이 존재하는지만 알면 된다).
#
# 재검증(fix round 2) 결과, 나머지 다섯 이론적 사각지대는 **직접 다시 그렙해서** 지금도 0건임을
# 재확인했다(아래는 이번에 재실행한 grep 결과, round 1 의 값을 그대로 믿지 않았다):
#   - 한 줄에 `const` 가 둘(`const A = 1; const B = 2`)                          — 0건
#   - 들여쓴 최상위 const(모듈 본문이 들여써진 경우)                              — 0건
#   - `Base.RefValue{T}()` 명시적 생성자(관용구는 항상 `Ref(...)`)                — 0건
#   - 소문자 전역 이름(관례 위반 — 이 레포는 전부 대문자다)                        — 0건
#   - 위 2번 목록에 없는 **커스텀 가변 구조체 생성자**(예: 새 `mutable struct`). `OODQueue` 는
#     수작업 감사로 찾아 목록에 넣었다 — 일반적으로 감지할 수 없다(타입 정보 없이 "이 식별자가
#     가변 컨테이너 생성자인가"를 정규식으로 결정할 수 없다: `SMatrix{...}(...)` 처럼 **불변**
#     생성자도 똑같은 문법을 쓴다). 새 커스텀 가변 컨테이너 전역을 만들면 **2번 목록에 이름을
#     추가해야 스캐너가 본다** — 안 하면 코드 리뷰로만 잡힌다. 이 사실 자체가 이 인벤토리의
#     한계다. (이 다섯째는 "0건"이 정의상 재확인 불가능한 종류다 — 새 구조체가 생기기 전엔 항상
#     0건이므로, 위 넷과 달리 "지금 안전하다"는 보장이 아니라 "발견 메커니즘이 없다"는 고백이다.)
#   면역: 불변 리터럴(숫자, 정규식 `r"..."`, 튜플, `SMatrix` 등 불변 타입)은 애초에 "상태"가
#   아니므로(내용이 절대 안 바뀐다) 스캐너가 놓쳐도 스냅샷 관점에서 무해하다 — 그래서 2번
#   목록을 "가변 컨테이너로 알려진 이름"으로 좁게 유지했다(범용 "식별자(...)" 매칭은 안 했다 —
#   그러면 `get(ENV, "X", "y")`/`parse(Int, ...)` 같은 흔한 ENV 파싱 표현식까지 전부 잡혀
#   `run_demo.jl`/`policy.jl` 의 setup 스칼라 수십 개가 쏟아져 들어온다. 실측 확인함).
#
# 의도적으로 쫓지 않은 것(코디네이터 지시, fix round 2): `render_demo.jl:88/99/172` ·
# `gen_oracle_dataset.jl:1015,1139-1142` — 둘 다 이 스캐너의 `extra_files`/`root` 범위 밖이다.
# `HZ_SEED_USED`(`run_demo.jl:640`)는 범위 안이라 스캔되고 분류도 했지만(:setup, pre-sim 전용
# 이라는 지시를 따랐고 그 이상 깊이 검증하지 않았다) — 아래 표에 그렇게 적어 뒀다.
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
    :VALID_ID_COUNTERS      => :state,   # 신규(fix round 2, [Blocker] #1, 사각지대 #4: `const`
                                          # 없는 최상위 `global`). graph_utils_essentials.jl:23 —
                                          # `get_unique_id(T)` 가 발급하는 다음 유효 id 번호.
                                          # 초기 장면 구성뿐 아니라 ood_injection.jl:478 에서
                                          # **에피소드 중**(고장 로봇 재발급 등)에도 발급된다.
                                          # 발급된 id 는 스케줄 그래프 노드에 그대로 박힌다 —
                                          # 복원 안 되면 이후 발급되는 id 번호가 원본 트레이스와
                                          # 달라져 그래프 정체성 비교가 갈린다.
    :INVALID_ID_COUNTERS    => :state,   # 신규. graph_utils_essentials.jl:24 —
                                          # `get_unique_invalid_id(T)` 가 발급하는 다음 무효
                                          # (placeholder) id 번호. reassign.jl:87 의
                                          # `release_pending_assignments!` 가 **에피소드 중**
                                          # 발급해 스케줄에 새 RobotGo 노드로 박아 넣는다 — 위와
                                          # 같은 이유로 상태.

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
    :ASSET_LEDGER           => :replay,   # ex-:log(fix round 1, [Important] #5). fix round 2 가
                                          # round 1 의 근거를 고쳤다(처분은 그대로 `:replay`,
                                          # 근거가 틀렸었다) — 재확인한 소비처 넷:
                                          # (a) replace_robot.jl:1473 `asset_of(role)` 을 다시
                                          #     장부 행에 실어 나른다(진단 문자열 아님, 다른 장부
                                          #     기록의 인자다) — 그 자체로는 분기 안 함.
                                          # (b) :1478/:1553 은 `@info` 인데 이 프로젝트 기본
                                          #     로거가 `Logging.Warn`(runtests.jl:31)이라 **버려
                                          #     진다** — 진단으로도 기능하지 않는다.
                                          # (c) render_tools.jl:914-916 이 **실제로 분기한다**:
                                          #     `isempty(ledger) && (empty!(_BATTERY_SWAP_FRAME);
                                          #     _VIS_FRAME[]=0; ...)`. 하지만 그 분기는 렌더
                                          #     레인 안(프레임 카운터 리셋)이라 동역학/결정에
                                          #     안 닿는다 — 그래서 여전히 `:state` 는 아니다.
                                          # (d) ood_injection.jl:343 주석: "ASSET_LEDGER 는
                                          #     여기서 일부러 안 비운다 — 빌드 경계를 넘어
                                          #     살아남아야 하는 유일한 상태(캠페인의 시간축)".
                                          #     append-only 로 설계됐고, 복원 안 되면 이후
                                          #     `asset_of`/`asset_generation` 이 다른 세대 번호를
                                          #     내 로그·(c)의 렌더 분기가 원본과 달라진다 —
                                          #     `_CACHE_TIMESTAMP_COUNTER` 와 같은 이유로
                                          #     `:log` 가 아니라 `:replay`.
    :RVO_ID_GLOBAL_MAP      => :replay,   # 신규(fix round 2, [Blocker] #1, 사각지대 #4).
                                          # rvo_interface.jl:44 — Julia AbstractID ↔ RVO(외부
                                          # Python rvo2 라이브러리) 정수 인덱스 매핑. 재리뷰가
                                          # 지적한 대로 spec 은 이미 "RVO 핸들은 ξ" 라고
                                          # 정한다. route_planning.jl:464 `update_rvo_sim!` 이
                                          # 활성 에이전트 구성이 바뀔 때마다(에피소드 중 수시로)
                                          # `rvo_reset_agent_map!()` 으로 통째로 재생성한다 —
                                          # 외부 라이브러리 인터페이스 상태라 s 로 해시할 내용은
                                          # 아니지만(:state 아님), 복원/CRN 연속성엔 필요하다.
    :RVO_SIM_WRAPPER        => :replay,   # 신규. rvo_interface.jl:107 — 실제 RVO(C++/Python)
                                          # 시뮬레이터 인스턴스를 담는 `CachedElement` 래퍼.
                                          # `update_rvo_sim!`(route_planning.jl:464-471)가
                                          # `RVO_ID_GLOBAL_MAP` 과 **같은 트리거로 같이**
                                          # 재생성한다 — 같은 서브시스템, 같은 이유로 `:replay`.
    :RVO_PYTHON_MODULE      => :replay,   # 신규. rvo_interface.jl:63 — 로드된 rvo2 파이썬 모듈
                                          # 핸들. `update_rvo_sim!` -> `rvo_set_new_sim!` ->
                                          # `rvo_new_sim()` -> `reset_rvo_python_module!()` 로
                                          # 위 둘과 **같은 호출 사슬**에서 에피소드 중 재로드된다
                                          # (route_planning.jl:470) — 재리뷰가 이름대지 않은
                                          # 셋째 항목이지만 같은 서브시스템·같은 트리거라 같은
                                          # 근거로 `:replay` 로 분류했다.
    :DSPY_HEALTHY           => :replay,   # ex-:setup(fix round 1) -> :replay(fix round 2,
                                          # [Important] #3). round 1 은 "프로세스 수명 동안
                                          # 한 번 정해지면 안 바뀐다"고 적었는데 그 자체가
                                          # `_CACHE_TIMESTAMP_COUNTER` 를 :replay 로 만든 논리와
                                          # 같다 — policy.jl:392 에서 `nothing -> Bool` 로 뒤집힌
                                          # 뒤 `dspy_ready()`(:387-388)가 그 캐시값을 그대로
                                          # 돌려주고, `service_decide` 가 그 값으로 dspy/canonical
                                          # 폴백을 가른다. 복원 안 되면 재생 시 서비스에 다시
                                          # 물어봐서(원본 시점과 다른 실제 헬스 상태를 받을 수
                                          # 있어) 원본과 다른 분기를 탈 수 있다 — s 콘텐츠는
                                          # 아니지만(:state 아님) 재생 연속성엔 필요.

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
    # fix round 2, [Important] #3: 아래 셋은 round 1 에서 :render 로 뒀었다 — 재리뷰가 옳게
    # 지적한 대로, monitor.jl 의 다섯 전역(이 셋 + 위 둘)이 **전부** monitor_emit!(monitor.jl:407,
    # 493-496)을 거쳐 MONITOR_IO(:log, 파일 핸들 — monitor.jl:31 `open(path,"w")`)로 JSON 한
    # 줄로 나간다 — 진짜 렌더러(Makie 애니메이션, render_tools.jl 의 `_VIS_FRAME`/색상/틴트
    # 프레임)와는 **다른 소비처**다. 그래서 실체가 있는 구분선은 "render_tools.jl(Makie 렌더
    # 파이프라인) vs monitor.jl(JSON-lines 로그 파일 작성기)" 이지 "표시용이냐 이력용이냐" 가
    # 아니다 — 후자는 임의적이었다(다섯 다 같은 함수로 나가므로). monitor.jl 소속은 전부 :log 로
    # 통일한다.
    :MONITOR_FAULTED        => :log,     # monitor.jl:21 — "FAULT 로 표시할 로봇 id". monitor.jl:150
                                          # 에서 한 번 더 읽혀 emit 되는 다른 필드("mode") 계산에
                                          # 쓰이지만, 그 결과도 결국 monitor_emit! 출력일 뿐이다.
    :MONITOR_NODE_T         => :log,     # monitor.jl:22 — Gantt 차트용 정점 타이밍(:216-226),
                                          # monitor_emit! 의 "schedule" 필드로 나간다.
    :MONITOR_HANDOFF_T      => :log,     # monitor.jl:23 — 예비 인계 시각, monitor_emit! 의
                                          # "handoffs" 필드로 나간다(:213,:493-496).

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
    # ---- fix round 2, [Important] #3: 아래 22개는 사각지대 #4(`const` 없는 최상위 `global`)
    # 확장으로 새로 잡혔다. 전부 setter 호출 경로를 추적해 "에피소드 루프가 시작되기 전
    # (`full_demo.jl` 의 `_run_lego_demo_impl`, 즉 씬/스케줄 구성 단계) 에만 바뀐다"를
    # 확인했다 — 시뮬레이션 스텝 루프 안에서 재설정되는 호출은 0건.
    :ALIGNMENT_CHECK_TOLERANCE => :setup,   # task_assignment.jl:151, setter 없음(고정 리터럴)
    :AVOID_STAGING_AREAS    => :setup,   # route_planning.jl:27, set_avoid_staging_areas! 호출은
                                          # full_demo.jl:855 하나뿐(설정 단계)
    :CAPTURE_DISTANCE_TOLERANCE => :setup, # hierarchical_geom_essentials.jl:1033, setter 호출 0건
    :CAPTURE_ROTATION_TOLERANCE => :setup, # 같은 파일:1038, setter 호출 0건
    :DEFAULT_GEOM_OPTIMIZER  => :setup,   # hierarchical_geom_essentials.jl:26, full_demo.jl:390 에서만 설정
    :DEFAULT_GEOM_OPTIMIZER_ATTRIBUTES => :setup, # 같은 파일:28, 같은 설정 경로
    :DEFAULT_MILP_OPTIMIZER_ATTRIBUTES => :setup, # essential_tg_coponents.jl:1946,
                                          # set/clear_default_milp_optimizer_attributes! 호출자 0건
    :DEFAULT_ROBOT_GEOM     => :setup,   # hierarchical_geom_essentials.jl:104,
                                          # set_default_robot_geom! 호출은 full_demo.jl:376 뿐
    :HZ_SEED_USED           => :setup,   # run_demo.jl:640 — 코디네이터 지시: pre-sim 전용,
                                          # 추적 보류(deferred). 스캔 범위 안이라 미분류로 둘 수
                                          # 없어 지시받은 분류만 기록한다.
    :LOADING_SPEED          => :setup,   # route_planning.jl:239, set_default_loading_speed! 호출은
                                          # full_demo.jl:382,580 뿐(둘 다 _run_lego_demo_impl 의
                                          # 작업배정 이전 구성 단계)
    :MILP_OPTIMIZER         => :setup,   # essential_tg_coponents.jl:1944,
                                          # set_default_milp_optimizer! 호출은 full_demo.jl:306 뿐
    :ROBOT_RADIUS           => :setup,   # potential_fields.jl:388, 재대입 없음(고정 기본 반경)
    :ROTATIONAL_LOADING_SPEED => :setup, # route_planning.jl:251, set_default_rotational_loading_speed!
                                          # 호출은 full_demo.jl:383,581 뿐
    :RVO_DEFAULT_TIME_STEP  => :setup,   # rvo_interface.jl:161, setter 호출은 full_demo.jl:381 뿐
    :RVO_DEFAULT_NEIGHBOR_DISTANCE => :setup,     # 같은 파일:170, full_demo.jl:386 뿐
    :RVO_DEFAULT_MIN_NEIGHBOR_DISTANCE => :setup, # 같은 파일:171, full_demo.jl:387 뿐
    :RVO_DEFAULT_NEIGHBORHOOD_VELOCITY_SCALE_FACTOR => :setup, # 같은 파일:172, setter 호출자 0건
    :RVO_MAX_SPEED          => :setup,   # rvo_interface.jl:119, setter 호출자 0건
    :RVO_MAX_SPEED_VOLUME_FACTOR => :setup, # 같은 파일:118, setter 호출자 0건
    :RVO_MIN_MAX_SPEED      => :setup,   # 같은 파일:120, setter 호출자 0건
    :STAGING_BUFFER_RADIUS  => :setup,   # route_planning.jl:32, set_staging_buffer_radius! 호출은
                                          # full_demo.jl:384 뿐
    :USE_RVO                => :setup,   # route_planning.jl:22, set_use_rvo! 호출은 full_demo.jl:854 뿐

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
    :BRIGHT_BLUE            => :render,  # 신규(fix round 2, 사각지대 #4). render_tools.jl:1108 —
                                          # 고정 RGB 색상 리터럴, 재대입 없음(마커 색).
    :BRIGHT_RED             => :render,  # render_tools.jl:1105 — 같은 이유.
    :LIGHT_BROWN            => :render,  # render_tools.jl:1106 — 같은 이유.
    :LIME_GREEN             => :render,  # render_tools.jl:1107 — 같은 이유.
    :SPACE_GRAY             => :render,  # render_tools.jl:1104 — 같은 이유.
)

# ---- 정규식 ----------------------------------------------------------------------------
# 넷 다 앵커(`^`)로 최상위(들여쓰기 없는) 선언만 잡는다.
const _PAT_REF     = r"^const\s+(_?[A-Z][A-Z_0-9]*)\s*=\s*Ref\b"
const _CONTAINER_CTORS = ("Dict", "Set", "Vector", "OrderedDict", "IdDict", "Array", "OODQueue")
const _PAT_CTOR     = Regex("^const\\s+(_?[A-Z][A-Z_0-9]*)\\s*=\\s*(?:" *
                             join(_CONTAINER_CTORS, "|") * ")\\b.*\\(")
const _PAT_BRACKET = r"^const\s+(_?[A-Z][A-Z_0-9]*)\s*=\s*[A-Za-z_][A-Za-z0-9_]*\["
# 넷째: `const` 없는 최상위 가변 전역(`global NAME = ...` 또는 맨 `NAME = ...`) — fix round 2,
# [Blocker] #1. `(?!=)` 로 `==` 를 걸러낸다(비교식이 대입으로 오매칭되지 않게).
const _PAT_GLOBAL_MUT = r"^(?:global\s+)?(_?[A-Z][A-Z_0-9]*)\s*=(?!=)"

function _scan_file!(out::Vector{Symbol}, path::AbstractString)
    isfile(path) || return out
    for line in eachline(path)
        is_const = startswith(line, "const")
        # _PAT_GLOBAL_MUT 는 `const` 가 없는 선언만 노린다 — const 줄에도 함께 돌리면
        # (예) `const NAME = Ref(0)` 의 `NAME` 을 또 잡아 중복 매치가 나지만 해는 안 된다
        # (같은 Symbol 이 push! 두 번 → sort!/unique! 로 어차피 합쳐진다). 그래도 의도를
        # 분명히 하려고 const 줄에서는 넷째 패턴을 건너뛴다.
        pats = is_const ? (_PAT_REF, _PAT_CTOR, _PAT_BRACKET) :
                          (_PAT_REF, _PAT_CTOR, _PAT_BRACKET, _PAT_GLOBAL_MUT)
        for pat in pats
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
