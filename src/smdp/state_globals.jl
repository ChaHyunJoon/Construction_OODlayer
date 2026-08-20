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
# ---- 스캐너 자체의 구조적 사각지대 (fix round 1 [Critical]#3 / round 2 [Blocker]#1 / round 3 [Critical]#3) --
# 원래 정규식은 `= Ref(...)` 만 봤다. 그래서 `const CARRIER_LAST_D = Dict{Any,Float64}()` 같은
# **Ref 로 안 감싼 가변 컨테이너 const**(Dict/Set/Vector 등)를 구조적으로 볼 수 없었다 —
# `replace_robot.jl` 의 이 컨테이너가 정확히 그 모양이고, 실제로 교체 로직의 텔레포트 판정을
# 가른다(`:826-829`). fix round 1 에서 세 모양을 추가했고, fix round 2 에서 **네 번째** 모양을
# 추가했다 — round 1 이 "지금은 0건" 이라고 적었던 "`const` 없는 최상위 가변 전역"이 재검증
# 결과 **32건**이었고(재리뷰가 "33건"이라 부른 것과 근사), 그중 `RVO_ID_GLOBAL_MAP`(spec: RVO
# 핸들은 ξ)·`RVO_SIM_WRAPPER`·`INVALID_ID_COUNTERS`(무효 id 가 `reassign.jl:87` 에서 에피소드
# 중 발급돼 스케줄 그래프에 그대로 박힌다) 는 진짜 상태였다 — round 1 의 "0건" 이라는 디스클로저
# 자체가 틀렸었다(측정 없이 믿은 값). 이제 네 모양을 잡는다:
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
# ⚠️ round 3, [Minor]#4: 넷째 패턴은 RHS 에 아무 제약이 없다 — 패턴 1-3 이 일부러 유지하는
# "알려진 컨테이너 생성자로 좁힌다"는 원칙을 넷째만 깬다(그럴 수밖에 없다 — `const` 없는
# 선언은 "컨테이너냐 아니냐"를 이름만으로 가려낼 신호가 없다). 대가: 새로 잡힌 32개 중
# **27개는 상태가 아니다**(RGB 리터럴 5개, 죽은 `1e-3` 허용오차, RVO 스칼라 기본값들,
# `nothing` 핸들 등). 과다 포함은 안전한 방향(빠뜨리는 것보다 낫다)이라 결함은 아니지만
# 이전 라운드에서 이 비용을 적어두지 않았다 — 여기 밝힌다.
#
# 재검증(fix round 2) 결과 나머지 다섯 이론적 사각지대 중 넷은 재확인 결과도 0건이었으나,
# round 3 재리뷰가 **다섯째 재확인 자체가 틀렸음을 실측으로 잡았다** — "소문자 전역"은 0건이
# 아니라 **2건**(`src/project_params.jl:19 projects`, `:40 project_parameters` — 최상위 비-const
# `Dict` 리터럴, 둘 다 재대입 없음). round 2 가 "다시 그렙해서 재확인했다"고 적은 게 실은
# 정확한 재확인이 아니었다 — 이번엔 아래 표에 두 이름을 분류해 넣고 다시 셌다:
#   - 한 줄에 `const` 가 둘(`const A = 1; const B = 2`)                          — 0건 (재확인)
#   - 들여쓴 최상위 const(모듈 본문이 들여써진 경우)                              — 0건 (재확인)
#   - `Base.RefValue{T}()` 명시적 생성자(관용구는 항상 `Ref(...)`)                — 0건 (재확인)
#   - 소문자 전역 이름(관례 위반 — 이 레포는 전부 대문자다)                        — **2건**(위),
#     분류해 넣었다(둘 다 :setup). "0건"을 두 번 잘못 적었으므로 이제부터 이 클레임은 이
#     파일에서 다시 안 쓴다 — 대신 아래 RHS-머리어휘 목록으로 대체한다.
#   - 위 2번 목록에 없는 **커스텀 가변 구조체 생성자**(예: 새 `mutable struct`). round 2 는
#     이걸 "영구적으로 측정 불가능"이라고 적었는데, round 3 재리뷰가 **그건 과장이라고 지적**
#     했다 — 실제로는 두 방향으로 유계다: (a) 레포의 `mutable struct` 25개 중 최상위 전역이
#     되는 건 단 2개뿐이고 둘 다 이미 분류돼 있다(`OODQueue`→`RESPEC_QUEUE`,
#     `HazardState`→`HAZARD_STATE`류는 Ref 로 감싼다). (b) 범위 안 모든 대문자
#     const/global 선언의 **RHS 머리 식별자**(대입 우변의 맨 앞 점-체인 식별자)를 전수
#     조사하면 유한 목록이 나온다 — 아래 `KNOWN_RHS_HEADS`/`rhs_heads` 가 그 목록을
#     **어서션**으로 만든다. 실제로 이 조치가 필요했던 살아있는 사례가 있다:
#     `src/smdp/simstate.jl:24 const SHA = Base.require(...)` 는 위 네 패턴 중 **어느 것에도**
#     안 걸린다(Ref 도, 알려진 컨테이너 생성자도, 대괄호 리터럴도 아니고 `const` 라 4번도
#     스킵한다) — 내 태스크 한 판 뒤에 커밋된 실제 사각지대 사례다. `SHA` 자체는 불변
#     모듈 바인딩이라 상태는 아니지만(면역, 아래), **측정 없이 "0건"이라 우기면 이런 게
#     조용히 새는 것**이 바로 round 2 의 실수였다. `rhs_heads`/`KNOWN_RHS_HEADS` 로 지금부터는
#     새 RHS 머리가 나오면(예: 다음 태스크가 또 다른 `Base.XXX` 나 새 커스텀 구조체를 최상위에
#     박으면) 테스트가 죽는다 — "발견 메커니즘이 없다"던 round 2 의 고백을 여기서 갚는다.
#   면역: 불변 리터럴(숫자, 정규식 `r"..."`, 튜플, `SMatrix`/`Base.require` 결과처럼 재대입되지
#   않는 불변 바인딩)은 애초에 "상태"가 아니므로(내용이 절대 안 바뀐다) 스캐너가 놓쳐도 스냅샷
#   관점에서 무해하다 — 그래서 2번 목록을 "가변 컨테이너로 알려진 이름"으로 좁게 유지했다
#   (범용 "식별자(...)" 매칭은 안 했다 — 그러면 `get(ENV, "X", "y")`/`parse(Int, ...)` 같은 흔한
#   ENV 파싱 표현식까지 전부 잡혀 `run_demo.jl`/`policy.jl` 의 setup 스칼라 수십 개가 쏟아져
#   들어온다. 실측 확인함).
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
    :CBF_HOLD               => :state,   # 신규(round 3, [Critical]#1). cbf.jl:163 — L0
                                          # line-stop 플래그. `replan.jl`의 `engage_fallback!`
                                          # (:1130)/`release_fallback!`(:1145)가 RESPEC_HOLD 와
                                          # **같은 자리에서 짝지어** 토글한다(진짜 respec 폴백
                                          # 경로, "14곳에서 호출된다"는 그 함수 — eval 스크립트
                                          # 전용이 아니다). CBF_ENABLED 가 꺼져 있으면 오늘은
                                          # 물리적 효과가 없지만(cbf.jl:413 이 먼저 early-return),
                                          # RESPEC_HOLD 의 companion 으로 실제 제어 흐름에서
                                          # 바뀌므로 :state.

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
    :INVALID_ID_COUNTERS    => :state,   # 신규(fix round 2, 사각지대 #4: `const` 없는 최상위
                                          # `global`). graph_utils_essentials.jl:24 —
                                          # `get_unique_invalid_id(T)` 가 발급하는 다음 무효
                                          # (placeholder) id 번호. reassign.jl:87 의
                                          # `release_pending_assignments!` 가 **에피소드 중**
                                          # (로봇 재배정 중) 발급해 스케줄에 새 RobotGo 노드로
                                          # 박아 넣는다 — 발급된 id 가 그래프 정체성의 일부가
                                          # 되므로 복원 안 되면 이후 발급 번호가 갈린다.

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
    :CBF_STATS              => :log,     # 신규. cbf.jl:181 — 호출/수정/hold/infeasible
                                          # 횟수 누적 딕셔너리. `_bump!`(:200,:448-449)가
                                          # 채우고 `cbf_stats()` 로만 노출된다 — 유일한 소비처는
                                          # `tools/cbf_sim_eval.jl:129`(리포팅), 어떤 분기도
                                          # 이 값으로 안 갈린다.
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
    :KNOWN_RHS_HEADS         => :setup,  # 자기 참조(round 3). RHS 머리 census 어록집도
                                          # `Set([...])` 라 스캐너에 스스로 걸린다 — 모듈 로드
                                          # 후 절대 안 바뀌는 정적 목록이므로 :setup.
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
    :DEFAULT_MILP_OPTIMIZER_ATTRIBUTES => :setup, # essential_tg_coponents.jl:1946.
                                          # round 2 의 "호출자 0건"은 틀렸다(round 3 재리뷰가
                                          # 잡음) — 실측 14개 호출쌍이 있다
                                          # (full_demo.jl:307-308,604-605 + tools/checks.jl·
                                          # demos.jl·diagnostics.jl·e2e.jl·restage.jl·
                                          # test_policy_oracle.jl·test_policy_zone.jl·tests.jl·
                                          # dev_session.jl·gen_oracle_dataset.jl). 전부 확인함:
                                          # full_demo.jl 안의 두 자리(:307-308,:604-605)는
                                          # 둘 다 `run_simulation!`(:875) **이전**의 MILP
                                          # 작업배정 단계이고, 나머지는 각자 독립 스크립트가
                                          # 자기 실행 전에 한 번 설정하는 자리다 — 에피소드 루프
                                          # 안에서 재설정되는 곳은 없다. 처분은 그대로 :setup,
                                          # 근거만 정정했다.
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
    :VALID_ID_COUNTERS      => :setup,   # ex-:state(round 2) -> :setup(round 3, [Important]#2).
                                          # round 2 의 근거(ood_injection.jl:478 이 에피소드 중
                                          # 발급한다)가 재리뷰에 반박됐다: 그 줄은
                                          # `add_directional_spare_pools!` 안이고, 그 함수는
                                          # `full_demo.jl:464` 에서만 불리는데 그 자리는
                                          # `run_simulation!`(:875) 보다 411줄 앞, 즉 설정
                                          # 단계다. `get_unique_id` 의 15개 호출자를 전부
                                          # 재확인했다(ConstructionBots.jl·construction_schedule.jl·
                                          # hierarchical_geom_essentials.jl·ood_injection.jl:478 +
                                          # tools/checks.jl·tests.jl 의 스크립트 호출) — 전부
                                          # 씬/스케줄/기하 **구성** 단계뿐, 에피소드 루프 안에서
                                          # 부르는 곳은 0건. 그래서 다른 setup 상수들과 같은
                                          # 기준으로 :setup 이 맞다(INVALID_ID_COUNTERS 는 여전히
                                          # :state — reassign.jl:87 이 실제로 에피소드 중 부른다).
    :projects               => :setup,   # 신규(round 3, [Important]#2: "소문자=0건" 은
                                          # 틀렸다). project_params.jl:19 — 번호->프로젝트
                                          # 이름표 카탈로그(최상위 비-const `Dict`), 재대입
                                          # 없음(읽기 전용 접근만: `:149,:173`).
    :project_parameters     => :setup,   # 신규. project_params.jl:40 — 이름표->파라미터
                                          # NamedTuple 표, 같은 이유로 :setup(`:181` 읽기만).
    :_BLOCK_NAMES            => :setup,  # 신규(태스크 9 가 내 라운드 사이에 커밋한
                                          # `src/smdp/simstate.jl:203` — 내 스캔 범위(`src/`)
                                          # 안이라 잡혔다, 내가 건드리는 파일은 아니다).
                                          # `canonical(s::SimState)` 의 `omit=` 키워드가 받을 수
                                          # 있는 블록 이름 허용집합(`Set([:g,:geo,...])`).
                                          # `setdiff(omit, _BLOCK_NAMES)` 로 검증에만 쓰이고
                                          # push!/reassign 되는 자리가 없다(확인함).
    # ---- round 3, [Critical]#1: HEAD:src/safety/cbf.jl · HEAD:src/respec/replan.jl 의 9개.
    # 작업 트리에는 cbf.jl 삭제가 스테이징돼 있고(다른 태스크 소관) replan.jl 도 FAILCLOSED_STOP
    # 이 지워진 버전으로 바뀌어 있다 — 그러나 **이 커밋의 트리에서는 둘 다 그대로 존재한다**
    # (내가 pathspec 으로 이 두 파일만 커밋하므로 나머지 파일은 부모 커밋 그대로 남는다). HEAD
    # 기준으로 계약이 성립하려면 여기서 분류해야 한다 — 나중에 그 삭제가 실제로 커밋되면
    # `stale_globals` 가 이 아홉 중 남은 것들을 유령으로 잡을 것이고, 그게 정상 동작이다.
    :CBF_ENABLED            => :setup,   # cbf.jl:141 — `enable_cbf!()`/`disable_cbf!()` 호출자는
                                          # `tools/cbf_sim_eval.jl`·`tools/test_cbf.jl` 뿐(둘 다
                                          # 독립 평가/테스트 스크립트, 실행 전 1회 설정).
                                          # `route_planning.jl:1147` 주석: "Inert unless
                                          # enable_cbf!() was called, so normal runs are
                                          # byte-identical" — 기본 실행 레인(run_demo.jl)은 이
                                          # 서브시스템을 아예 안 부른다.
    :CBF_ALPHA              => :setup,   # cbf.jl:151, enable_cbf!() 의 kwarg 로만 설정(같은 호출자)
    :CBF_MARGIN             => :setup,   # cbf.jl:154, 같은 이유
    :CBF_INTER_AGENT        => :setup,   # cbf.jl:167, 같은 이유
    :CBF_DEFAULT_RADIUS     => :setup,   # cbf.jl:170, setter 없음(고정 기본 반경)
    :CBF_SCENE_TREE         => :setup,   # cbf.jl:387, `set_cbf_scene_tree!`/`scene_tree_for_cbf`
                                          # 외부 호출자 0건 — 죽은 배선 훅, 영원히 `nothing`.
    :FAILCLOSED_STOP        => :setup,   # replan.jl:1139 — "opt-in switch... Default `false`
                                          # preserves the historical behaviour exactly"
                                          # (제작자 docstring 그대로). `set_failclosed_stop!`
                                          # 호출자는 레포 전체에 0건(verifier.jl:256 은 문서
                                          # 문자열일 뿐 실제 호출이 아님) — 오늘은 항상 꺼져 있다.

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
# round 3, [Important]#2: 이름 문자클래스가 대문자만 받았다("_?[A-Z]...") — 그래서
# `projects = Dict(...)`/`project_parameters = Dict(...)`(project_params.jl:19,40, 소문자
# 최상위 비-const 대입)를 놓쳤고, round 2 는 "소문자 전역 0건"이라고 잘못 적었다(실측: 2건).
# 대괄호 패턴(`_PAT_BRACKET`)·`Ref`(`_PAT_REF`)·넷째 패턴(`_PAT_GLOBAL_MUT`)은 대문자만으로도
# 재확인 결과 문제없어(0건/이미 대문자만 쓰는 관례) 그대로 두고, 컨테이너 생성자 패턴만
# 대소문자 모두 받게 넓혔다 — 실측으로 노이즈 없이 딱 이 두 개만 추가로 잡힌다(다른 패턴을
# 똑같이 넓히면 46개까지 쏟아진다: 흔한 소문자 지역 바인딩이 너무 많다).
const _PAT_CTOR     = Regex("^(?:const\\s+)?(_?[A-Za-z][A-Za-z_0-9]*)\\s*=\\s*(?:" *
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

# =============================================================================
# round 3, [Critical]#3 — "커스텀 가변 구조체 생성자는 영구적으로 측정 불가능하다"는 round 2 의
# 주장은 과장이었다(재리뷰 지적). RHS(대입 우변)의 **머리 식별자**(맨 앞 점-체인 토큰, 예:
# `Dict{...}(...)` 의 "Dict", `Base.require(...)` 의 "Base.require")를 전수 조사하면 유한
# 목록이 나온다 — 오늘 이 범위에서 실제로 관측된 15개가 `KNOWN_RHS_HEADS` 다. 살아있는 사례로
# `src/smdp/simstate.jl:24 const SHA = Base.require(...)` 가 있다(내 태스크 한 판 뒤에 커밋됨,
# 위 네 패턴 어디에도 안 걸린다 — `SHA` 자체는 불변 모듈 바인딩이라 상태는 아니지만, "이런 모양이
# 존재하는지조차 몰랐다"가 문제였다). 이 census 를 어서션으로 만들어 **새 머리가 나오면 이
# 테스트가 죽게** 한다 — round 2 의 "발견 메커니즘이 없다"는 고백을 갚는 조치다.
#
# 이 목록은 "지금 코드가 실제로 쓰는 15개 머리"의 census 이지, "허용되는 전부"가 아니다 — 새
# 머리가 나오면 그게 진짜 가변 상태인지 사람이 보고 판단한 뒤 (a) 무해한 불변 타입이면 이
# 목록에 추가, (b) 진짜 가변 컨테이너면 `_CONTAINER_CTORS` 에도 추가해 스캐너가 보게 해야 한다.
const KNOWN_RHS_HEADS = Set([
    "Any", "Base.require", "CachedElement", "Dict", "GeometryBasics.Cylinder", "OODQueue",
    "RGB", "RVOAgentMap", "ReentrantLock", "Ref", "Regex", "SMatrix", "Set", "String", "Vector",
])
# 이름 그룹은 패턴 1-4 와 같은 전-대문자 관례(`_?[A-Z][A-Z_0-9]*`)로 좁힌다 — 처음엔
# `[A-Za-z]` 로 느슨하게 했다가 타입 별칭(`const RobotID = BotID{DeliveryBot}` 류,
# PascalCase 라 전-대문자가 아니다)과 스크립트 지역변수(`run_demo.jl` 최상위의
# `model_base = replace(...)` 류, 소문자라 애초에 관례 위반)가 대거 새어 들어와서(실측:
# 미확인 15개) 다시 좁혔다. `(?!")` 는 정규식/문자열 리터럴(`r"..."`)의 접두 문자(`r`)가
# 머리로 오인되는 것을 막는다.
const _PAT_RHS_HEAD = r"^(?:const\s+|global\s+)?(_?[A-Z][A-Z_0-9]*)\s*=\s*([A-Za-z_][A-Za-z0-9_.]*)(?!\")"

function _rhs_head!(out::Set{String}, path::AbstractString)
    isfile(path) || return out
    for line in eachline(path)
        m = match(_PAT_RHS_HEAD, line)
        m === nothing && continue
        head = m.captures[2]   # captures[1] 은 이름, [2] 가 RHS 머리(이름 그룹도 캡처하게 바뀌었다)
        # 리터럴/키워드 머리(숫자, `true`/`false`/`nothing`/`try`/`if` 등)는 census 대상이 아니다
        # — 이 census 는 "무언가를 생성하는 호출/타입 이름"만 본다. Julia 예약어와 순수
        # 스칼라 파생 표현식(get/parse/lowercase 류)은 이미 다른 이유로 스캐너의 컨테이너
        # 판정에서 제외돼 있으므로 여기서도 제외한다 — census 목적이 "새 불투명 생성자 모양"을
        # 잡는 것이지 이미 이해된 ENV 파싱 관용구를 다시 세는 게 아니다.
        head in ("true", "false", "nothing", "try", "if", "get", "haskey", "lowercase",
                 "rstrip", "strip", "time", "parse", "clamp", "max", "min", "ConstructionBots",
                 "PARAMS", "DEMO_N", "Objective.objective_hash") && continue
        push!(out, head)
    end
    return out
end

"""
    rhs_heads(root; extra_files=String[]) -> Vector{String}

`root`(+ `extra_files`)의 최상위 `const`/`global`/맨 대입 선언에서 RHS 머리 식별자를 전수
조사한다. `KNOWN_RHS_HEADS` 와의 차집합이 비어 있지 않으면 새로운(=아직 사람이 본 적 없는)
생성자 모양이 나타났다는 뜻 — test/smdp_global_inventory.jl 이 그 경우 죽는다.
"""
function rhs_heads(root::AbstractString; extra_files::AbstractVector{<:AbstractString}=String[])
    out = Set{String}()
    for (dir, _, fs) in walkdir(root), f in fs
        endswith(f, ".jl") || continue
        _rhs_head!(out, joinpath(dir, f))
    end
    for path in extra_files
        _rhs_head!(out, path)
    end
    return sort!(collect(out))
end

"`KNOWN_RHS_HEADS` 에 없는 새 RHS 머리(사람이 아직 안 본 생성자 모양). 비어 있지 않으면 테스트가 죽는다."
unknown_rhs_heads(root::AbstractString; extra_files::AbstractVector{<:AbstractString}=String[]) =
    [h for h in rhs_heads(root; extra_files=extra_files) if !(h in KNOWN_RHS_HEADS)]

