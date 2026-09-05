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
#     `HazardState`→`HAZARD_STATE`류는 Ref 로 감싼다). (b) 범위 안 모든 최상위
#     const/global 선언(**대문자 ALL_CAPS 와 소문자 snake_case 둘 다** — round 4 에서
#     소문자를 넣었다, `_PAT_RHS_HEAD` 주석의 실측 비교 참고)의
#     **RHS 머리 식별자**(대입 우변의 맨 앞 점-체인 식별자)를 전수
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
    :STANDING_CARGO_BANS    => :state,   # 화물 금지. swap_battery! 까지 산다 (cargo-ban Task 3)
                                          # 🔴 `AGENT_COST_BIAS`(바로 윗줄)와 **같은 부류**다:
                                          # 로봇 id → 스칼라의 `Ref{Dict}` 이고, OOD 처리 도중에
                                          # 채워져 다음 MILP 정식화를 가른다. 다른 점은 이쪽이
                                          # 소프트 비용편향이 아니라 **하드 제약**이라는 것뿐이라
                                          # 오염됐을 때의 대가가 더 크다(다음 판의 로봇이 이유
                                          # 없이 화물을 못 맡는다).
                                          # 🔴 :setup 이 아닌 이유 — `RESPEC_SCENE_TREE`(아래
                                          # :setup 절)는 `formulate_milp` 이 스스로 채우고 같은
                                          # 호출 안에서 지워 solve 밖에서는 항상 `nothing` 이지만,
                                          # 이 상자는 **에피소드 중에 걸려 그대로 살아 있는 것이
                                          # 목적**이다(수명 = 그 로봇의 swap_battery! 사건까지).
                                          # 롤아웃 경계에서 안 지우면 이전 판의 금지가 다음 판을
                                          # 오염시킨다 — 에러가 아니라 조용한 다른 세계로 샌다.
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
    :LAST_CARGO_BAN_ROWS    => :state,   # 측정용. 직전 formulate 이 화물 금지로 더한 행 수
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
    :INVALID_ID_COUNTERS    => :state,   # 신규(fix round 2, 사각지대 #4: `const` 없는 최상위
                                          # `global`). graph_utils_essentials.jl:24 —
                                          # `get_unique_invalid_id(T)` 가 발급하는 다음 무효
                                          # (placeholder) id 번호. reassign.jl:87 의
                                          # `release_pending_assignments!` 가 **에피소드 중**
                                          # (로봇 재배정 중) 발급해 스케줄에 새 RobotGo 노드로
                                          # 박아 넣는다 — 발급된 id 가 그래프 정체성의 일부가
                                          # 되므로 복원 안 되면 이후 발급 번호가 갈린다.
    :VALID_ID_COUNTERS      => :state,   # round 2 `:state` -> round 3 `:setup` -> **round 4 에서
                                          # `:state` 로 되돌림**(재리뷰 3 [Critical]). round 3 의
                                          # 강등 근거는 "`get_unique_id` 라고 **텍스트로 적힌**
                                          # 15개 호출 자리를 전부 재확인했다 — 전부 구성 단계" 였다.
                                          # 그 스윕이 **암묵 생성자 사슬**을 통째로 못 봤다. 이
                                          # 레포에서 유효 id 는 텍스트 호출 자리에서만 발급되지
                                          # 않는다 — 생성자가 안에서 발급한다:
                                          #   construction_schedule.jl:91-94
                                          #     `for T in (:RobotStart,...)  $T(n::SceneNode) = $T(n, TransformNode())`
                                          #   -> hierarchical_geom_essentials.jl:326 `TransformNode()`
                                          #   -> :313-317 내부 생성자 `t.id = get_unique_id(TransformNodeID)`
                                          # 그리고 그 `RobotStart(RobotNode(...))` 호출은 에피소드
                                          # 중 핫스왑 경로 한복판에 있다(replace_robot.jl:173 ·
                                          # reassign.jl:265). 도달 사슬(round 4 에서 직접 재확인):
                                          #   route_planning.jl:271 `respec_step!(env)` (**매 스텝**)
                                          #   -> replan.jl:162/166 `maybe_respecify!`
                                          #   -> replan.jl:768 `replace_robot!`   (:768 은 329줄에서
                                          #      시작하는 `maybe_respecify!` 본문 안이다 — 확인함)
                                          #   -> replace_robot.jl:1181/:1241 -> :157 `_restamp_robot_go!`
                                          #   -> :173 `RobotStart(...)` -> `get_unique_id`.
                                          # **라이브 실측(round 4 프로브, `julia +lts --project=.`):**
                                          #   before RobotStart: Dict(GeomID=>2, TransformNodeID=>2)
                                          #   after  RobotStart: Dict(GeomID=>2, TransformNodeID=>3)
                                          # 즉 카운터가 에피소드 중 실제로 +1 된다. 구성된
                                          # `RobotStart` 는 `get_node` 의 조회 키로만 쓰이고 버려지지만
                                          # **카운터는 이미 올라간 뒤**다 — 복원 안 되면 그 뒤 발급되는
                                          # TransformNodeID 가 원본 트레이스와 어긋나 그래프 정체성
                                          # 비교가 갈린다.
                                          # 같은 사각지대의 다른 암묵 발급 자리(전부 확인함):
                                          #   construction_schedule.jl:267 (`$T(n::TransportUnitNode)`
                                          #     가 `TransformNode()` 셋) · :282 (`$T(n::SceneNode)` 가 둘)
                                          #   hierarchical_geom_essentials.jl:482,486 (`GeomNode(geom)`)
                                          #   :527 (`Base.copy(::GeomNode)` — Base 오버로드다)
                                          #   graph_utils_essentials.jl:590 (`TreeNode{E,ID}` **내부
                                          #     생성자** — round 3 이 센 "15개 목록"에 아예 없다)
                                          # ⚠️ 방법론 교훈(이 표 전체에 적용된다): "이 이름의 텍스트
                                          # 호출 자리를 전부 훑었다"는 처분 근거로 **불충분하다** —
                                          # 생성자·`Base.` 오버로드·`@eval` 생성 메서드가 부르는
                                          # 헬퍼는 텍스트 스윕에 안 잡힌다. round 4 에서 이 표의
                                          # 비-:state/:replay 전역 전부(당시 :setup 71 · :log 16 ·
                                          # :render 14 · :meta 1 = 102 — round 4 가 적었던 `:setup 72`
                                          # 는 재검산에서 틀렸다)의 **쓰기 자리와 그 둘러싼 함수**를
                                          # 기계로 다시 뽑아 같은 클래스를 찾았다: 나머지는 전부
                                          # 이름 있는 setter/훅 설치 함수(`set_*!` · `install_*_hook!` ·
                                          # `clear_*!` · `monitor_record_*!` · `record_ood_truth!` ·
                                          # `_prime_ldraw_part_index!`) 안에서만 써지고, 생성자나
                                          # Base 오버로드 안에서 써지는 전역은 **이 항목 하나뿐**이다.
                                          # ⚠️ 2026-08-20 `src/safety/cbf.jl` 삭제가 커밋되면서 이 표에서
                                          # `CBF_*` 8 + `FAILCLOSED_STOP` 9개가 빠졌다. 현행 분포는
                                          # :setup 64 · :state 29 · :log 15 · :render 14 · :replay 6 ·
                                          # :split 2 · :meta 1 = **131** 이다(위 스윕은 그 이전 모집단).

    # ---- run_demo.jl / policy.jl 확장분 (I12 + fix round 1) --------------------------------
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
    :ENACT_ORDER_LOG        => :log,     # 신규(Task C1). replan.jl:523 — `maybe_respecify!` 가
                                          # 진입한 순차-집행 분기의 순서를 push! 로 쌓는 감사
                                          # 트레이스. 매 호출 **맨 앞**에서 `Symbol[]` 로 덮어써
                                          # 진다(replan.jl:832) — 그래서 이전 결정의 내용이 이번
                                          # 결정으로 새어 들어올 여지가 코드 안에서 이미 막혀
                                          # 있다(:log 는 그 사실을 "스냅샷 불필요"로 확인할 뿐,
                                          # 그 사실을 만드는 쪽은 아니다). 소비처는 테스트 단언
                                          # (`test/respec_sequential_enact.jl` 등)과 `@info` 방출
                                          # 뿐 — 다시 읽어 분기하는 프로덕션 코드가 없다(`_DECISIONS`
                                          # 와 같은 논리).
    :LAST_ENACT_REPORT      => :log,     # 신규(Task C1). replan.jl:536 — 집행 단위별
                                          # `(kind, status, n)` 행을 쌓는 감사 트레이스.
                                          # `ENACT_ORDER_LOG` 와 짝지어 매 호출 맨 앞에서
                                          # `NamedTuple[]` 로 리셋된다(replan.jl:833). `sum(r.n)`
                                          # 불변식은 **같은 호출 안에서** 검증되는 것이지 다음
                                          # 결정으로 이월되는 상태가 아니다 — 다음 호출은 빈
                                          # 벡터에서 다시 시작한다. 다시 읽어 분기하는 소비처가
                                          # 없다(테스트 단언 + `@info` 뿐) — `ENACT_ORDER_LOG` 와
                                          # 같은 이유로 :log.

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
    :RESOLVE_CALLS          => :log,     # respec/common_resolve.jl(2026-09-02 이전엔
                                          # smdp/generative.jl) — 공통 MILP 재풀이
                                          # 자리를 몇 번 지났나. 순수 진단 카운터라 s 도 ξ 도
                                          # 아니다. 스텁이 **조용히 무동작**이 아님을
                                          # test/smdp_generative.jl 이 이 값으로 본다.
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
    :UNWEDGE_INTERVAL      => :setup,   # 명목 레인 교착 해소 주기(무진전 modulo). 상수 손잡이
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
    :RESPEC_SCENE_TREE      => :setup,   # 신규(cargo-ban Task 2). compiler.jl — `formulate_milp`
                                          # 이 자기 `problem_spec`(= 씬트리)을 여기 넣고
                                          # `compile_proposal!` 직후 `finally` 로 되돌린다.
                                          # 🔴 `RESPEC_FROZEN`/`RESPEC_PINNED` 가 :setup → :state
                                          # 로 재분류된 이유(호출자가 solve 전에 채워 두면 그
                                          # 값이 프론티어 판정을 가른다)가 여기엔 **없다**:
                                          # 이 상자는 `formulate_milp` 자신이 채우고 같은 호출
                                          # 안에서 지우므로 solve 밖에서는 **항상 `nothing`**
                                          # 이고, 스냅샷이 찍히는 어떤 지점에서도 값이 없다 —
                                          # 복원할 내용이 없으므로 s 가 아니다. 배선 통로라는
                                          # 점에서 `EDGE_COST_MULTIPLIER`(바로 윗줄)와 같은 부류다.
    :ENERGY_MODEL           => :setup,
    :GREEDY_ENERGY_W        => :setup,
    :PLANNING_OBJECTIVE_WEIGHTS => :setup,
    :RHO                    => :setup,   # 신규(Task T8). tplan.jl:68 — 계획→실현 소요시간 보정
                                          # 배수. `EDGE_COST_MULTIPLIER`/`GREEDY_ENERGY_W` 와 같은
                                          # 모양의 튜닝 스칼라: `node_duration`/`T_plan_next`/
                                          # `T_done` 이 매 호출 **읽기만** 하고, 에피소드 시뮬
                                          # 루프 안에서 재대입하는 자리는 0건(확인함, `grep -rn
                                          # "RHO\[\]\s*="` — 쓰기는 `test/smdp_tplan.jl` 의
                                          # save/restore 쌍과 `tools/monitor/gen_ng1_pairs.jl` 의
                                          # 그리드서치 sweep(둘 다 옛값을 저장했다가 되돌린다)뿐).
                                          # 현재 `1.0` 은 잠정 기본값이고 **Task T10(게이트 N-G2)이
                                          # 무거운 레인에 적합해 이 `Ref` 를 덮어쓴다** — :setup
                                          # 은 "에피소드 중 불변"을 뜻하지 "영원히 1.0"을 뜻하지
                                          # 않는다(다른 setup 상수들도 실행 전 구성 단계에서
                                          # `set_*!` 로 채워진 뒤 에피소드 내내 고정된다, 예:
                                          # `LOADING_SPEED`/`MILP_OPTIMIZER`). T10 이 적합한 값은
                                          # 이 :setup 분류 아래 그대로 살아남는다 — snapshot/
                                          # restore! 는 :setup 을 건드리지 않으므로 롤아웃 사이
                                          # 리셋으로 조용히 1.0 에 되돌아가는 경로가 없다(적합값을
                                          # 버리는 방향의 버그를 피한다). 반대로 :state/:replay 로
                                          # 잘못 분류했다면 존재하지도 않는 "복원" 의미론을 이
                                          # 스칼라에 강제하게 된다 — 근거 없이 s 를 부풀리는 쪽.
    :_STATE_BASELINE        => :setup,   # 신규(D-13R, 이 파일 하단). 롤아웃 경계 리셋이 되돌릴
                                          # **기준선** — `capture_state_baseline!()` 이 트리 시작
                                          # 직전에 한 번 잡고 에피소드 내내 불변이다. 그래서
                                          # `RHO`/`DRAIN_DT` 와 같은 이유로 :setup 이다.
                                          # 🔴 **:state 로 분류하면 순환이다** — 리셋이 기준선을
                                          # 기준선으로 되돌리려 든다. `resettable_state_globals()`
                                          # 는 :state/:split 만 보므로 오늘은 안 걸리지만, 그
                                          # 안전이 **분류에 의존**한다는 것이 요점이다.
                                          # `test/smdp_state_reset.jl` 이 그 순환을 직접 단언한다.
    :DRAIN_DT               => :setup,   # 신규(Task T10). sojourn.jl — `dur == 0` 프론티어를 닫는
                                          # 데 부과하는 시뮬 시간. **`RHO` 와 같은 모양이고 같은
                                          # 이유로 :setup 이다**: `Ref{Float64}`, 커밋된 기본값
                                          # `0.0`(= T9 의 동작), `sample_sojourn` 이 매 호출
                                          # **읽기만** 하고, 쓰기는 프로브의 save/restore 쌍뿐이다
                                          # (`tools/monitor/gen_ng1_pairs.jl:250-257` ·
                                          # `test/smdp_sojourn.jl:308-311` — 둘 다 옛값을 저장했다
                                          # 되돌린다). 에피소드 시뮬 루프 안의 재대입은 0건.
                                          # ⚠️ :state 로 분류하면 롤아웃 사이 리셋이 프로브 값을
                                          # 조용히 0 으로 되돌려 2×2 요인설계가 무너진다 — `RHO`
                                          # 항목이 적은 것과 같은 방향의 사고다.
                                          # 🔴 이 등록이 T10 병합에서 빠져 있었다(레인이 globals
                                          # fix `bd311146` **이전**에 분기해 이 파일을 한 번도 안
                                          # 건드렸다). `test/smdp_global_inventory.jl` 이
                                          # `isempty([:DRAIN_DT])` 로 잡았다 — 횡단 시험이 레포
                                          # 범위로 돌 때만 보이는 종류다(보고서 §6 절차 실수).
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
                                          # (2026-08-23 재측정: full_demo.jl:308,605 +
                                          # tools/demos.jl 3곳 + tools/checks.jl·e2e.jl·restage.jl·
                                          # tests.jl·test_policy_oracle.jl·test_policy_zone.jl·
                                          # dev_session.jl·gen_oracle_dataset.jl·
                                          # test/stage_graph_plots.jl 각 1곳).
                                          # 🔴 옛 목록은 test/stage_graph_plots.jl 을 빠뜨리고
                                          # tools/diagnostics.jl 을 넣고 있었다 — 후자는 2026-08-23
                                          # 죽은 코드로 삭제됐고 그 자리를 전자가 메워 합계는 14로
                                          # 같다. 전부 확인함:
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
#
# ---- round 4, [Important]#3 + [Minor]: allowlist 는 **하나뿐이다** -----------------------------
# round 3 은 여기 `KNOWN_RHS_HEADS` 를 공시해 놓고, `_rhs_head!` 본문 안에 **공시되지 않은 두
# 번째 하드코딩 스킵 목록**(`get`·`parse`·`clamp`·`max`·`min`·`time`·`strip`·`lowercase`·
# `rstrip`·`haskey`·`PARAMS`·`DEMO_N`·`Objective.objective_hash`·`ConstructionBots` + 예약어)
# 을 따로 들고 있었다. allowlist 가 둘이면 공시된 쪽이 의미를 잃는다(재리뷰 3 [Minor]).
# round 4 에서 **합쳤다**: 실제 머리 식별자는 전부 이 집합 하나에 들어오고, `_rhs_head!` 에
# 남은 것은 `_NON_HEAD_TOKENS`(리터럴/예약어 — 애초에 "머리"가 아닌 토큰) 뿐이다.
#
# ⚠️ `get` 은 원리적 구멍이다 — `get(d, k, default)` 는 가변 컨테이너를 돌려줄 수 있으므로
# `const X = get(...)` 가 진짜 상태를 숨길 수 있다. 오늘 실히트 0건(범위 안 `get` 머리는 전부
# `get(ENV, "…", "…")` ENV 파싱)이라 알려진 머리로 둔다. 같은 논리가 `parse`/`clamp` 류에는
# 적용되지 않는다(불변 스칼라만 돌려준다).
const KNOWN_RHS_HEADS = Set([
    # (a) round 3 이 공시했던 15개 — 생성자/타입 머리
    "Any", "Base.require", "CachedElement", "Dict", "GeometryBasics.Cylinder", "OODQueue",
    "RGB", "RVOAgentMap", "ReentrantLock", "Ref", "Regex", "SMatrix", "Set", "String", "Vector",
    # (b) round 3 이 `_rhs_head!` 안에 숨겨 두었던 14개 — 순수 스칼라/ENV 파생 표현식의 머리와
    #     이미 분류된 전역 이름. 여기로 올려 공시한다.
    #     ⚠️ 실측 공시: 이 14개 중 `clamp`·`max`·`min`·`parse` 네 개는 **현재 범위에서 관측되지
    #     않는다**(round 3 이 왜 넣었는지는 그 라운드가 안 적었다). allowlist 는 관측 집합의
    #     상위집합이라 해는 없지만, "관측된 머리의 census" 라는 이름값은 그 넷에 대해 성립하지
    #     않는다 — 다음 라운드에서 지워도 계약은 안 깨진다(오늘 실측: 관측 30 · 등록 34).
    "get", "haskey", "lowercase", "rstrip", "strip", "time", "parse", "clamp", "max", "min",
    "ConstructionBots", "PARAMS", "DEMO_N", "Objective.objective_hash",
    # (c) round 4 에서 이름 그룹을 소문자까지 넓히며 **새로 보이게 된** 5개(실측: 정확히 이 5개).
    #     전부 `tools/monitor/run_demo.jl` 최상위의 스크립트 지역 바인딩이다:
    #       replace(:87 model_base) · joinpath(:88 stream_dir) · CB.run_lego_demo(:573 env)
    #       Graphs.nv(:578 n_total)  · isfile(:1021 n)
    #     넷은 불변 스칼라/문자열이고, `CB.run_lego_demo` 만 가변 env 를 돌려주지만 그 이름
    #     (`env`)은 스캐너 네 패턴이 보는 최상위 전역 후보가 아니다(대문자 관례 밖) — 즉 오늘
    #     이 표의 계약에는 안 닿는다. 새 소문자 머리가 나오면 여기서 죽는다는 것이 요점이다.
    "replace", "joinpath", "CB.run_lego_demo", "Graphs.nv", "isfile",
    # (d) 2026-08-21, Task T12 병합이 새로 들여온 1개. **이 census 가 설계대로 죽어서 보였다** —
    #     `src/smdp/generative.jl:54 const OBJECTIVE_JSON = normpath(joinpath(pkgdir(...), ...))`.
    #     판정(위 절차 (a)): `normpath` 는 `String` 을 돌려주는 **불변** 머리이고, 바로 위 (c) 의
    #     `joinpath` 과 같은 부류다. 가변 컨테이너를 만들 수 없으므로 `_CONTAINER_CTORS` 에는
    #     넣지 않는다. `OBJECTIVE_JSON` 자체도 재대입되지 않는 경로 문자열이라 상태가 아니다.
    #     ⚠️ 그래서 이 항목 뒤 실측은 관측 31 · 등록 35 다(위 (b) 의 30 · 34 에서 각 +1).
    "normpath",
])
# ---- round 4, [Important]#3: census 의 이름 그룹을 **소문자까지** 넓혔다 ---------------------
# round 3 의 이름 그룹은 `(_?[A-Z][A-Z_0-9]*)` — **전-대문자 전용**이었다. 그런데 바로 그
# round 3 이 "이 레포에 소문자 최상위 전역이 실재한다"(`project_params.jl:19 projects`,
# `:40 project_parameters`)를 발견해 `_PAT_CTOR` 을 넓혔다. 즉 **같은 커밋이 방금 실재를
# 증명한 클래스를, 같은 커밋이 새로 만든 발견 메커니즘은 구조적으로 못 봤다.** 실측(round 3
# 재리뷰 + round 4 재현): 스크래치 사본에 `baz_rr3_global = NovelLowerCtor(2)` 를 심어도
# `unknown_rhs_heads` 가 비어 있었다.
#
# 세 후보를 **실측으로** 비교한 뒤 골랐다(범위: src/ 전체 + monitor 3파일):
#   (i)   `_?[A-Z][A-Z_0-9]*`                        머리 15개 · 미확인 0  ← round 3 (소문자 실명)
#   (ii)  `_?[A-Z][A-Z_0-9]*|_?[a-z][a-z_0-9]*`      머리 20개 · 미확인 5  ← **채택**
#   (iii) `_?[A-Za-z][A-Za-z_0-9]*`                  머리 29개 · 미확인 14
# (iii) 이 추가로 끌어오는 9개는 전부 **PascalCase 타입 별칭**(`const RobotID = BotID{...}` ·
# `const RectType = Hyperrectangle` · `const SumOfMakeSpans = MultiDeadlineCost{SumCost}` 등
# — 불변 타입 바인딩이라 정의상 상태가 아니다) + 독스트링 오탐 1개(`a`)다. 그 9개를 알려진
# 머리로 등록하면 census 가 "타입 별칭 사전" 이 되어 진짜 신호를 묻는다. (ii) 는 이 레포의
# 두 실제 관례(ALL_CAPS 전역 · snake_case 소문자 전역)를 정확히 덮고 PascalCase 만 뺀다 —
# **그리고 (ii) 로 `baz_rr3_global = NovelLowerCtor(2)` 는 잡힌다**(레드 증명: 아래 함수
# 독스트링과 fix round 4 보고서). 남은 사각지대는 PascalCase 이름의 최상위 전역이고, 그건
# 여기 명시적으로 적어 둔다 — 오늘 그런 전역은 0건이다(위 9개는 전부 타입 별칭).
#
# `(?!")` 는 정규식/문자열 리터럴(`r"..."`)의 접두 문자(`r`)가 머리로 오인되는 것을 막는다.
const _PAT_RHS_HEAD = r"^(?:const\s+|global\s+)?(_?[A-Z][A-Z_0-9]*|_?[a-z][a-z_0-9]*)\s*=\s*([A-Za-z_][A-Za-z0-9_.]*)(?!\")"

# 머리가 **아닌** 토큰: 리터럴과 Julia 예약어. allowlist 가 아니다 — `NAME = true` 의 `true` 는
# "아직 사람이 안 본 생성자 모양" 이 될 수 없다(파싱 필터). 실제 식별자 머리는 전부
# `KNOWN_RHS_HEADS` 에 있다(round 4 에서 두 목록을 하나로 합쳤다, 위 참고).
const _NON_HEAD_TOKENS = ("true", "false", "nothing", "try", "if")

function _rhs_head!(out::Set{String}, path::AbstractString)
    isfile(path) || return out
    for line in eachline(path)
        m = match(_PAT_RHS_HEAD, line)
        m === nothing && continue
        head = m.captures[2]   # captures[1] 은 이름, [2] 가 RHS 머리(이름 그룹도 캡처하게 바뀌었다)
        # 리터럴/예약어는 애초에 "머리"가 아니다(파싱 필터, allowlist 아님). round 3 은 여기에
        # 실제 식별자 머리 14개까지 섞어 **공시되지 않은 두 번째 allowlist** 를 만들어 뒀었다 —
        # round 4 에서 그 14개를 `KNOWN_RHS_HEADS` 로 올렸다. 남은 건 리터럴/예약어뿐이다.
        head in _NON_HEAD_TOKENS && continue
        push!(out, head)
    end
    return out
end

"""
    rhs_heads(root; extra_files=String[]) -> Vector{String}

`root`(+ `extra_files`)의 최상위 `const`/`global`/맨 대입 선언에서 RHS 머리 식별자를 전수
조사한다. 이름 그룹은 ALL_CAPS **와 snake_case 소문자** 둘 다 본다(round 4, `_PAT_RHS_HEAD`
주석에 세 후보의 실측 비교가 있다). `KNOWN_RHS_HEADS` 와의 차집합이 비어 있지 않으면
새로운(=아직 사람이 본 적 없는) 생성자 모양이 나타났다는 뜻 —
test/smdp_global_inventory.jl 이 그 경우 죽는다.

레드 증명(round 4, 레포 밖 스크래치 사본에 세 줄을 심고 실측):
```
+ const FOO_RR4_GLOBAL = MyBrandNewCtor(1)
+ const BAR_RR4_GLOBAL = ConstructionBots.some_new_mutable()
+ baz_rr4_global       = NovelLowerCtor(2)
round 3 census: ["ConstructionBots.some_new_mutable", "MyBrandNewCtor"]        # 소문자 놓침 🔴
round 4 census: ["ConstructionBots.some_new_mutable", "MyBrandNewCtor",
                 "NovelLowerCtor"]                                            # 셋 다 잡는다 ✅
```
세 줄 모두 `unclassified_globals` 로는 안 잡힌다(스캔 패턴 넷의 사각지대) — 그래서 이 census
가 그 클래스의 유일한 그물이다.
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


# =============================================================================
# 롤아웃 경계 리셋 (2026-08-21, 사용자 결정 D-13 의 단서 · briefs/task-D13R-brief.md)
#
# 🔴 **왜 필요한가.** `RESPEC_HOLD[]` 는 프로세스 전역 **영구 래치**이고 그것을 푸는
#    production 호출자가 0 개다(그게 D-13 의 설계다). MCTS 는 한 프로세스·한 디렉토리에서
#    `G(s,a)` 를 수천 번 부르므로(§4: "트리는 한 디렉토리 안에서 굴린다"), **fallback 을 한 번
#    밟은 롤아웃이 그 뒤 전부를 오염시킨다** — 에러가 아니라 "아무것도 안 움직이는 세계"로.
#
#    실측(2026-08-21): 시험 파일을 **파일당 별도 프로세스**로 돌리면 22/22 PASS 인데, 같은
#    파일들을 **한 프로세스**에서 연달아 돌리면 5 개가 실패한다. `respec_grammar.jl` 이
#    `RESPEC_HOLD = true` 를 남기고 그 다음 두 파일이 던지며, `smdp_tplan.jl` 의 비퇴화 단언은
#    `NDIST_A >= 2` 에서 `1 >= 2` 로 깨진다(= 활성집합이 트레이스 내내 안 바뀐다 = 라인이 서 있다).
#
#    계획서 A 의 Global Constraint 는 이 누수를 **이미 알고** 프로세스 격리로 우회했다.
#    트리는 그 우회를 쓸 수 없다(프로세스를 가르면 세계가 갈린다). **여기서 격리를 프로세스가
#    아니라 명시적 리셋으로 얻는다.**
#
# 🔴 **기준선은 "모듈 초기값"이 아니라 "트리 시작 시점"이다.** 이게 이 설계의 핵심 판단이다.
#    `VALID_ID_COUNTERS` 를 모듈 초기값(빈 Dict)으로 되돌리면 **setup 단계에서 이미 발급된 id 를
#    가진 살아 있는 객체들과 충돌한다** — 그 카운터는 에피소드 중 실제로 전진한다(핫스왑 경로가
#    `RobotStart(RobotNode(...))` 를 만들면서 `get_unique_id` 를 탄다, 위 :VALID_ID_COUNTERS 항목의
#    라이브 프로브 참조). 반대로 **아예 안 되돌리면** id 가 롤아웃마다 단조 증가해 N 번째 롤아웃이
#    1 번째와 다른 세계를 보게 된다 — §4 가 규명한 바로 그 결함 부류(id hash → Dict 순회 순서 →
#    기하)다. 그래서 기준선을 **호출자가 잡는다**: 환경 셋업이 끝나고 트리가 시작되기 직전.
#
# ⚠️ `:setup` 은 **절대 건드리지 않는다.** 특히 `RHO`/`DRAIN_DT` — 위 두 항목이 적어 둔 대로,
#    리셋이 그것을 되돌리면 T10 이 적합한 값이 매 롤아웃마다 버려지고 λ 가 **에러 없이** 틀린다.
# =============================================================================

"기준선. `capture_state_baseline!()` 가 채운다. `nothing` 이면 아직 안 잡힌 것이고, 그 상태의 리셋은 **에러**다."
const _STATE_BASELINE = Ref{Union{Nothing,Dict{Symbol,Any}}}(nothing)

"`Ref` 는 내용물이, 나머지는 객체 자체가 스냅샷 대상이다."
_snapshot_of(x::Base.RefValue) = x[]
_snapshot_of(x) = x

_restore_into!(x::Base.RefValue, v) = (x[] = deepcopy(v); nothing)
_restore_into!(x::AbstractDict, v)  = (empty!(x); merge!(x, deepcopy(v)); nothing)
_restore_into!(x::AbstractSet, v)   = (empty!(x); union!(x, deepcopy(v)); nothing)
_restore_into!(x::AbstractVector, v)= (empty!(x); append!(x, deepcopy(v)); nothing)
function _restore_into!(x, v)                      # 가변 struct (예: OODQueue)
    ismutable(x) || error("_restore_into!: $(typeof(x)) 는 가변이 아니다 — 리셋할 수 없다")
    for f in fieldnames(typeof(x))
        setfield!(x, f, deepcopy(getfield(v, f)))
    end
    return nothing
end

"""
    resettable_state_globals() -> Vector{Symbol}

리셋 대상. 처분이 `:state` 또는 `:split` 이면서 **이 모듈 안에서 해석되는** 이름 전부.
표에서 유도하므로 손으로 나열한 목록이 뒤처지는 사고가 구조적으로 불가능하다
(`tools/demos.jl` 의 `clear_*!` 여섯 줄이 정확히 그 사고였다 — `RESPEC_HOLD` 가 거기 없다).
"""
resettable_state_globals() =
    sort!([k for (k, v) in STATE_GLOBALS
           if (v === :state || v === :split) && isdefined(@__MODULE__, k)]; by = string)

"""
    unresettable_state_globals() -> Vector{Symbol}

처분은 `:state`/`:split` 인데 **이 모듈 밖**에 사는 이름(= `run_demo.jl`/`policy.jl` 의 스크립트
지역 전역). 여기서는 되돌릴 수 없으므로 호출자가 책임진다.
🔴 이 목록이 **커지면 시험이 죽는다** — 새 에피소드 상태가 모듈 밖에 생겼다는 뜻이고, 그러면
트리가 그것을 리셋하지 못한 채 돈다.
"""
unresettable_state_globals() =
    sort!([k for (k, v) in STATE_GLOBALS
           if (v === :state || v === :split) && !isdefined(@__MODULE__, k)]; by = string)

"""
    capture_state_baseline!() -> Int

지금의 `:state`/`:split` 전역 값을 기준선으로 잡는다. 잡은 개수를 돌려준다.

**언제 부르는가:** 환경 셋업이 끝나고 **트리(또는 롤아웃 루프)가 시작되기 직전** 한 번.
모듈 로드 시점이 아니다 — 위 헤더의 `VALID_ID_COUNTERS` 논증 참조.
"""
function capture_state_baseline!()
    d = Dict{Symbol,Any}()
    for k in resettable_state_globals()
        d[k] = deepcopy(_snapshot_of(getfield(@__MODULE__, k)))
    end
    _STATE_BASELINE[] = d
    return length(d)
end

"기준선이 잡혀 있는가."
state_baseline_captured() = _STATE_BASELINE[] !== nothing

"""
    reset_state_globals!() -> Int

`:state`/`:split` 전역을 기준선으로 되돌린다. 되돌린 개수를 돌려준다.

🔴 기준선이 없으면 **죽는다.** 모듈 초기값으로 조용히 폴백하지 않는다 — 그 폴백은
`VALID_ID_COUNTERS` 를 빈 Dict 로 만들어 살아 있는 객체와 id 를 충돌시키고, 그 사고는
**에러 없이 다른 세계**로 나타난다(이 레포가 반복해서 데인 모양).

⚠️ `:setup` 은 건드리지 않는다 — `RHO`·`DRAIN_DT` 의 적합값이 살아남아야 한다.
"""
function reset_state_globals!()
    b = _STATE_BASELINE[]
    b === nothing && error(
        "reset_state_globals!: 기준선이 없다. `capture_state_baseline!()` 를 셋업 직후 · 트리 " *
        "시작 직전에 먼저 부를 것. 모듈 초기값으로 폴백하지 않는다 — VALID_ID_COUNTERS 가 " *
        "빈 Dict 가 되어 살아 있는 객체와 id 가 충돌하고, 그 사고는 에러 없이 다른 세계로 " *
        "나타난다(state_globals.jl 의 롤아웃 리셋 헤더 참조)")
    n = 0
    for (k, v) in b
        isdefined(@__MODULE__, k) || error(
            "reset_state_globals!: $(k) 가 기준선에는 있는데 지금 모듈에 없다 — 기준선이 다른 " *
            "세계에서 잡혔다")
        _restore_into!(getfield(@__MODULE__, k), v)
        n += 1
    end
    return n
end
