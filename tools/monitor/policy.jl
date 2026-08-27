# tools/monitor/policy.jl
# =============================================================================
# **결정 정책 레이어(공용)** — run_demo.jl(수동 루프)과 render_demo.jl(애니메이션 렌더)이
# 똑같은 결정을 내리도록 한 곳에 모은 파일. 여기만 고치면 두 엔진이 함께 바뀐다.
#
#   canonical : CB.canonical_respec 규칙 lookup (줄리아 내부)
#   oracle    : reference_policy.py 의 기준행동 a* 를 결정시점에 재계산해 집행(비교용 상한 lane)
#   surrogate : 배포 RandomForest      ┐ 파이썬 서비스 POST /decide 로 한 번에 받음
#   dspy      : MIPROv2 컴파일 gpt-4o  ┘
#
# 매 OOD 사건마다 **셋을 모두 계산해 기록**하고(UI 가 전환해 볼 수 있게), 실제로 실행되는 것은
# DEMO_POLICY 하나뿐이다. 서비스가 없으면 canonical 로 폴백하고 그 사실을 verdict 에 남긴다.
#
# ENV: DEMO_POLICY(canonical|noop|oracle|surrogate|dspy) · DSPY_URL · DEMO_ALL_POLICIES(0 이면 비교값 수집 생략)
# =============================================================================
import HTTP, JSON3

const POLICY   = lowercase(get(ENV, "DEMO_POLICY", "canonical"))
const DSPY_URL = rstrip(get(ENV, "DSPY_URL", "http://127.0.0.1:8077"), '/')

# ---- 순수 함수로 분리한 조각들 (2026-08-14) -------------------------------------------------
# 이 파일은 67KB 에 ENV·ConstructionBots 의존이라 **통째로는 단위검사가 안 된다.** 그래서
# 단위검사가 가능한 판단만 의존성 0 인 파일로 뺐다:
#   lane_select.jl : 레인 선택 분기표(3-way)        -> test_lane_select.jl
#   narrate.jl     : 레코드 -> 자연어 문장           -> test_narrate.jl
#   dp_lane.jl     : DEMO_POLICY=dp 전용 표 조회     (라우터/UI 에는 들어가지 않는다)
include(joinpath(@__DIR__, "lane_select.jl"))
include(joinpath(@__DIR__, "narrate.jl"))
include(joinpath(@__DIR__, "dp_lane.jl"))

# =============================================================================
#  라우터 (2026-07-28 추가)
# =============================================================================
# 여기까지의 데모는 실행 정책을 DEMO_POLICY 로 **런 전체에 고정**했다. 그래서 화면의 정책 버튼은
# "사람이 골라 보는 비교 도구"였지, 시스템의 결정이 아니었다. 목표 설계는 그 반대다:
#
#     처음 보는 사건  -> LLM 이 자연어 관찰을 읽고 대응     (adaptive)
#     익숙한 사건    -> surrogate 가 0.1 ms 에 대응        (cost efficient)
#     **그 판별을 시스템이 사건마다 스스로 한다**
#
# 판별기는 이미 src/safety/novelty.jl 에 다 있었다(novelty_verdict / event_descriptors /
# conformal p-value). 다만 아무도 호출하지 않았다 -- 라이브러리만 있고 배선이 없었다. 이 절이 그
# 배선이다.
#
# 신호로 covariate novelty 를 쓰는 이유(측정 결과이지 취향이 아님):
#   새 *종류* 탐지에서 forest 의 내부 이견(disagreement)은 recall 0.00 이다. 처음 보는 영역에서
#   나무들은 근거가 없어 **똑같이** 엉뚱한 답을 지지하므로 합의율이 오히려 높다 = "확신함"으로
#   읽힌다. covariate novelty 는 "학습 입력 분포에서 얼마나 먼가"를 재므로 recall 0.94.
#   (wm4spacecraft_manufacturing/md/DESIGN_ASSIMILATION.md 4-c 참조)
#
# ENV
#   DEMO_ROUTER  auto(기본) | 1 | 0
#                auto = 낯섦 감지기가 설치돼 있으면 켜고, 없으면 예전처럼 DEMO_POLICY 고정.
#   ROUTER_EPS   낯섦 p-value 임계. 기본은 교정파일의 alpha.
#   NOVELTY_CALIB  교정 JSON 경로(기본: wm4spacecraft_manufacturing/novelty/novelty_calibration.json)
const ROUTER_MODE = lowercase(get(ENV, "DEMO_ROUTER", "auto"))
const ROUTER_EPS  = (try parse(Float64, ENV["ROUTER_EPS"]) catch; nothing end)

"""
낯섦 감지기를 한 번 설치한다.

두 가지 실패를 **다르게** 다룬다(2026-07-30):

  · 교정파일이 **없다**        -> 경고만 하고 라우터를 끈 채 진행(fail-open).
    아직 교정을 안 만든 정상적인 상태이고, 데모는 고정 정책으로 계속 돌아야 한다.

  · 교정파일이 **있는데 안 맞는다** -> 즉시 에러를 던져 런을 세운다(fail-loud).
    예전에는 이것도 `@warn` 후 라우터만 끄고 넘어갔다. 그러면 "라우팅이 되는 줄 알고" 돌린
    실험이 사실은 라우터 없이 돈 것이 되고, 로그의 경고 한 줄은 긴 출력에 묻힌다. 낡은/깨진
    교정은 조용히 무시할 대상이 아니라 고쳐야 할 대상이므로 크게 실패시킨다.
    (정말로 무시하고 싶으면 DEMO_ROUTER=0 으로 명시적으로 끈다.)
"""
function install_novelty!()
    (try CB.novelty_detector() catch; nothing end) === nothing || return true
    # 2026-08-20 폴더 재편: 교정 JSON 이 wm4spacecraft_manufacturing/novelty/ 로 옮겨졌다.
    # 🔴 이 경로가 틀리면 아래 `isfile` 이 false 가 되어 라우터가 **조용히 꺼진 채**(fail-open)
    # 런이 계속되고, DEMO_SUMMARY 의 "router" 필드는 요청 모드만 되뇌므로 산출물이
    # 돌지도 않은 라우터를 주장하게 된다. 폴더를 옮길 때는 이 줄을 같이 옮길 것.
    path = get(ENV, "NOVELTY_CALIB",
               joinpath(@__DIR__, "..", "..", "wm4spacecraft_manufacturing",   # tools/monitor -> repo 루트
                        "novelty", "novelty_calibration.json"))
    isfile(path) || (@warn "novelty calibration not found -> router disabled (fail-open)" path;
                     return false)
    try
        CB.set_novelty_detector!(CB.load_novelty_detector(path))
        @info "[ROUTER] " * CB.novelty_report()
        return true
    catch e
        # 스키마/서술자 불일치는 조용히 넘기지 않는다.
        if e isa CB.CalibrationError
            @error """
            [ROUTER] novelty calibration at
                $path
            does not match this build. Refusing to run with a stale gate -- regenerate it:

                cd wm4spacecraft_manufacturing
                python wm4spacecraft_manufacturing/novelty/export_novelty_calibration.py

            (or set DEMO_ROUTER=0 to run deliberately without the router.)
            """
            rethrow()
        end
        @warn "novelty calibration failed to load -> router disabled" exception = e
        return false
    end
end

"라우터를 쓸 것인가."
router_enabled() = ROUTER_MODE == "0" ? false :
                   ROUTER_MODE == "1" ? install_novelty!() :
                   install_novelty!()          # auto: 감지기가 있으면 켠다

# 여기가 "누가 매크로를 고르는가"를 결정하는 유일한 지점이다. 아래 세 함수만 보면 된다:
#   ood_features  : 결정 순간의 공개 상태(정답 누수 없음) — 오프라인 라벨러의 capture_features 와 동일 항목
#   dspy_decide   : 그 상태를 DSPy 서비스에 POST → 매크로 + 순위 + margin
#   decide_macro  : 정책에 따라 canonical / dspy 중 하나를 고르고, 실패 시 canonical 로 폴백

# 대상 로봇이 아직 안 끝낸 운반 투입 작업 수(피해 규모 대리지표). 라벨러의 _agent_pending_tasks 와 동일 로직.
function _agent_pending(env, agent)
    agent === nothing && return -1
    sched = env.sched; n = 0
    for v in Graphs.vertices(sched)
        node = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        (node isa CB.RobotGo && CB.bound_to_agent(node, agent)) || continue
        v in env.cache.closed_set && continue
        outs = Graphs.outneighbors(sched, v); isempty(outs) && continue
        CB.get_node_from_id(sched, CB.get_vtx_id(sched, outs[1])) isa CB.FormTransportUnit || continue
        n += 1
    end
    return n
end

# zone 이 "아직 안 끝난" staging 원을 얼마나 덮는지(0~1) = zone 의 진짜 severity.
function _zone_overlap(env, zkey)
    z = try CB.RESTRICTION_ZONES[][zkey] catch; nothing end
    z === nothing && return -1.0
    zc = Vector{Float64}(CB.get_center(z)[1:2]); zr = Float64(CB.get_radius(z))
    best = 0.0
    for (aid, ball) in env.staging_circles
        ac = try CB._assembly_complete_node(env, aid) catch; nothing end
        ac === nothing && continue
        v = try CB.get_vtx(env.sched, CB.node_id(ac)) catch; nothing end
        (v === nothing || v in env.cache.closed_set) && continue      # PENDING staging 만
        bc = Vector{Float64}(CB.get_center(ball)[1:2]); br = Float64(CB.get_radius(ball))
        d = sqrt(sum((bc .- zc) .^ 2))
        d >= br + zr && continue
        area = if d <= abs(br - zr)
            π * min(br, zr)^2
        else
            a1 = acos(clamp((d^2 + zr^2 - br^2) / (2d * zr), -1.0, 1.0))
            a2 = acos(clamp((d^2 + br^2 - zr^2) / (2d * br), -1.0, 1.0))
            zr^2 * (a1 - sin(2a1) / 2) + br^2 * (a2 - sin(2a2) / 2)
        end
        best = max(best, area / (π * br^2))
    end
    return best
end

"결정 순간의 공개 상태만 뽑는다(시뮬 결과·오라클 라벨은 절대 포함하지 않음)."
function ood_features(env, truth)
    closed = length(env.cache.closed_set)
    total  = length(CB.get_nodes(env.sched))
    kind, agent = if truth isa CB.FaultTruth
        ("fault", truth.robot)
    elseif truth isa CB.BatteryTruth
        ("battery", truth.robot)
    elseif truth isa CB.ZoneTruth
        ("zone", nothing)
    else
        ("fault", nothing)
    end
    d = Dict{String,Any}(
        "kind"          => kind,
        "spare_count"   => (try length(CB.active_spares()) catch; 0 end),
        "agent_pending" => _agent_pending(env, agent),
        "progress"      => total > 0 ? closed / total : 0.0,
        "n_active"      => length(env.cache.active_set),
        "closed_at_fire"=> closed,          # surrogate 피처
        # 2026-08-14: 새 22차원 조립기(surrogate_features.build_features)의 work_at_risk 분모가
        # `total_nodes - closed_at_fire` 다. 라벨 행에는 처음부터 있던 필드인데 이 payload 에만
        # 없었다 -- 안 보내면 서비스가 progress 에서 역산하고(항등식이라 값은 같다), closed=0 인
        # 순간에는 역산이 불가능해 work_at_risk 가 1.0 으로 포화한다. 그냥 실어 보낸다.
        "total_nodes"   => total,           # surrogate 피처
        "n_spare_cfg"   => 3,               # surrogate 피처(데모의 spare 설정 수준)
    )
    if truth isa CB.BatteryTruth
        d["soc"] = Float64(truth.soc_after); d["severity"] = Float64(truth.soc_after)
    elseif truth isa CB.ZoneTruth
        local ov = _zone_overlap(env, truth.zone)
        d["zone_overlap"] = ov; d["severity"] = ov
        d["zone_radius"] = try Float64(CB.get_radius(CB.RESTRICTION_ZONES[][truth.zone])) catch; nothing end
        # STEP 3: 기하 **원시값**. zone_overlap 스칼라 하나로는 "무엇이 왜 막혔는가"를 말할 수 없어
        # 정책이 사실상 종류 이름만 보고 답할 수밖에 없었다. 진단기가 이미 계산한 술어를 그대로 준다.
        # ★ 최소수복 판정(verdict)은 **주지 않는다** — 그건 정답이라 오라클·게이트의 것이고,
        #   주는 순간 정책은 추론이 아니라 답을 읽게 된다(zone_diagnosis.jl 의 note).
        local zdg = try CB.zone_diagnosis(env, truth.zone) catch e
            @warn "[policy] zone_diagnosis failed -> 원시값 없이 진행" exception = e; nothing
        end
        if zdg !== nothing && zdg.exists
            d["zone_blocked"]           = zdg.n_blocked            # 구역이 덮은 미개시 조립체 수
            d["zone_restage_feasible"]  = zdg.n_restage_feasible   # 그중 옮길 자리가 있는 수
            d["zone_root_covered"]      = zdg.root_covered         # 갇힌 root 하역목표 수
            d["zone_root_total"]        = zdg.root_total
            d["zone_work_overlap"]      = zdg.n_work_overlap       # 겹친 미완 작업 디스크 수
            d["zone_teams_forming"]     = zdg.n_teams_forming      # 지금 형성 중인 운반팀 수
            d["zone_teams_covered"]     = zdg.n_teams_covered      # 그중 구역에 갇힌 팀 수
            d["zone_relocatable"]       = zdg.relocate_feasible    # 벗어날 강체이동이 존재하는가
            d["zone_relocate_norm"]     = isfinite(zdg.relocate_norm) ? zdg.relocate_norm : -1.0
            # ---- 막힘(blockage) 원시값 (2026-08-05) -------------------------------------
            # 위의 값들은 전부 **덮임**(coverage)이다. STEP 6 이 실측으로 보인 것: 덮임은 해로움이
            # 아니다(root 하역목표 8/8 을 삼켜도 완주했고 시간만 2.1배). 구역이 강제되는 곳은
            # enforce_restriction_zone_clearance! 한 곳뿐이고 거긴 **RVO 에이전트만** 스냅하므로,
            # 화물을 직접 옮기는 LiftIntoPlace 목표는 원리적으로 못 막힌다(zone_corridor.jl 상단).
            # 그래서 "막을 수 있는 목표"와 "그중 실제로 막힌 것"을 따로 싣는다. zone_diagnosis 가
            # 이미 계산해 둔 값이라 추가 계산 비용은 0이다. (-1 = 계산 안 됨 → 싣지 않는다.)
            if zdg.n_nav_goals >= 0
                d["zone_nav_goals"]        = zdg.n_nav_goals         # 막힐 수 있는 목표의 모수
                d["zone_nav_blocked"]      = zdg.n_nav_blocked       # 그중 지금 못 닫는 것
                d["zone_nav_engulfed"]     = zdg.n_nav_engulfed      #   포획볼이 배제원 안(확정)
                d["zone_nav_disconnected"] = zdg.n_nav_disconnected  #   목표는 비었는데 길이 끊김
                d["zone_agent_trapped"]    = zdg.n_agent_trapped     # 구역 안에 주차된 이동체 수
                # 막힌 노드 뒤에 걸려 함께 얼어붙는 미완 작업의 양. 이 값이 없으면 "120개 중 1개"가
                # 1/120 의 피해로 읽힌다 — 실측(2026-08-05): 두 LLM 프로그램이 모두 그렇게 읽고
                # "minimal impact, only one navigation goal" 이라며 NOOP 을 골랐다.
                d["zone_nav_downstream"]   = zdg.n_nav_downstream
                d["zone_unfinished_total"] = total - closed          # 위 값을 견줄 분모
            end
        end
    else
        d["severity"] = 1.0
    end
    return d
end

"""
> 2026-08-24: 아래 zone 논의는 **역사 기록**이다. zone 은 LLM 결정 레인에서 제거됐고
> (spec §5.1) 이 함수에 zone 분기는 더 이상 없다.

    valid_macros(env, truth) -> Vector{String}

이 사건에서 **실제로 무언가를 할 수 있는** 매크로들. 빈 벡터를 돌려주면 서비스가 kind 별 기본표를 쓴다.

왜 여기서 계산하는가(2026-08-05 회귀 수정): legal 을 kind 로만 정하면 전제조건이 있는 팔을 표현할
수 없다. `ForbidZone`(→ `restage_all_blocked!`)은 **아직 시작하지 않은** 조립체의 적치원만 옮길 수
있어서, 빌드 중반에는 도메인이 비어 NOOP 과 같아진다. 그 사실 때문에 2026-08-03 에 zone 어휘가
`[NOOP, RelocateBuild]` 로 바뀌었는데(오라클 라벨링 기준으로는 옳다), 그 바람에 **데모의 zone 사건도**
전부 빌드 전체를 통째로 옮기는 RelocateBuild 로 답해졌다. 데모의 zone 은 정확히 반대 상황이다 —
주입기(inject_staging_zone!)가 **아직 시작 안 한** 조립체를 골라 심으므로 국소 재적치가 언제나 가능하다.
실측 결과 전역 이동은 조립이 시작된 뒤 |Δ|=3.19 m 로 판을 통째로 옮겨 운반체가 교착됐다
(streams/tractor__zone.jsonl 264/287 미완주 · ForbidZone 으로 답하던 옛 녹화는 전부 287 완주).

그래서 **구역이 조립체를 지목했으면 ForbidZone 을 메뉴에 되돌린다**. RelocateBuild 는 전제조건이
없으므로 항상 남겨 둔다(중앙 core zone 처럼 국소 재적치로는 못 푸는 경우가 실재한다). 둘 다 legal 일
때 무엇을 고를지는 정책(LLM/surrogate)의 몫이고, 고른 뒤의 안전은 dispatcher 가 책임진다 —
ForbidZone 은 restage 로 안 풀리면 `:residual_blocked` 에서 자동으로 whole-build 이동으로 격상된다.

**"도메인이 비면 빼자"는 처음 시도했다가 실측으로 접었다(2026-08-05)**: 이 데모의 존은 sim 전에
미시작 조립체를 골라 심지만 respec 이 처리되는 시점(closed≈54)은 이미 첫 배치 경계(46) 뒤라
`zone_blocked_assemblies` 가 **항상 비어 있다**. 그 게이트를 쓰면 공간형 팔이 RelocateBuild 하나만
남아 지금 고치려는 회귀가 그대로 재현된다. 그리고 같은 seed·같은 존으로 매크로만 교차해 재보면
도메인이 빈 ForbidZone(= 사실상 no-op)이 **closed 231 · 조립체 7/8**, 전역 이동이 **closed 136 ·
조립체 1/8** 이다. 싼 팔이 이 트윈에서 명백히 우세하므로 메뉴에서 지울 이유가 없다. 대신 실행부가
실제로 한 일은 verdict 에 그대로 남는다(`navigation detour · moved 0`) — 조용한 no-op 을 성공으로
포장하지 않는다는 8/3 의 문제의식은 어휘가 아니라 **보고**로 지킨다.
"""
function valid_macros(env, truth)
    # ---- battery: SwapBattery 를 메뉴에 올린다 (2026-08-06, Ch-A) --------------------------
    # 이 함수는 zone 이 아니면 빈 목록을 돌려주고 서비스의 kind 기본표에 맡겼는데, 그 기본표에
    # SwapBattery 가 없었다. 그래서 **라이브 데모의 배터리 사건에서는 현장 배터리 교체(cost 0.2)를
    # 정책이 고를 수조차 없었고**, 방전된 로봇을 살리려면 창고 본체를 먹는 Replace(1.0) 뿐이었다.
    # 두 팔의 소모 자원이 다르다는 것이 SwapBattery 를 따로 둔 이유이므로(spec_dsl.jl), 그 선택을
    # 지우면 battery 사건에서 잴 수 있는 결정 구조 자체가 사라진다.
    # 전제조건: 배터리 레이어가 켜져 있어야 SoC 복구가 의미를 갖는다. 없으면 메뉴에서 뺀다.
    # 🔴 2026-08-25 (최종 브랜치 리뷰 C2): 이 메뉴는 하드코딩 튜플
    # `["NOOP","Replace","SwapBattery"]` 였다. 판정 R-46 이 같은 파일의 `enactable_macros()`
    # 를 레지스트리 파생으로 고쳤지만 **420줄 위의 이 진짜 메뉴는 그대로 남았다.** 실측:
    # `ACTION_REGISTRY=` 를 이름 바꾼 레지스트리로 돌리면 `enactable_macros()` 는 따라가고
    # `valid_macros` 는 안 따라간다 — 에러 없이. 그런데 이 반환값이 곧 LLM 의 메뉴
    # (`service_decide` 의 payload["valid"]) · oracle/canonical 규칙의 메뉴 · 채점기가 읽는
    # 결정 기록의 `valid` 필드(`run_demo.jl`)다. 즉 어휘의 **하중을 받는** 사본이었다.
    # `enactable_macros()` 와 같은 로더로 유도한다.
    if truth isa CB.BatteryTruth
        local have_fleet = (try CB.BATTERY_FLEET[] !== nothing catch; false end)
        # ---- SoC 분할: 라벨 레인과 **같은 함수**를 쓴다 (2026-08-25) ---------------------------
        # 여기는 `kind_valid("battery")`(= 상한) 를 그대로 냈고, 라벨 레인
        # (`ood_mdp_shim.valid_actions`)만 SoC 로 메뉴를 갈랐다. 즉 같은 사건에서 라벨을 만든
        # 세계와 실제로 굴린 세계의 **행동공간이 달랐다**: mild 에서 이 레인은 `Replace` 를 고를
        # 수 있는데 라벨 격자엔 그 행이 없어, 그 결정이 surrogate 가 본 적 없는 팔로 남는다.
        # 분할 규칙과 손잡이 판독점을 어휘 단일 진실원으로 올렸다(`ActionRegistry.battery_arms`
        # · `soc_split_enabled`). 게이트: `test/battery_menu_lanes_agree.jl`.
        local thr = try Float64(CB.REPLACE_SOC_THRESHOLD[]) catch; 0.2 end
        local ids = ActionRegistry.battery_arms(Float64(truth.soc_after), thr,
                                                ActionRegistry.soc_split_enabled())
        if !have_fleet
            # 전제조건: 배터리 레이어가 켜져 있어야 SoC 복구가 의미를 갖는다. 꺼져 있으면
            # **battery 사건에서만** 말이 되는 팔(레지스트리의 `kinds` 가 battery 하나뿐인
            # 팔 = 오늘의 SwapBattery)을 뺀다. 다른 kind 에도 붙는 팔(NOOP·Replace)은 "로봇
            # 하나가 멈췄다" 는 사실만으로 성립하므로 남는다.
            # 이름을 리터럴로 적지 않는 이유는 위 주석 그대로다 — 어휘의 단일 진실원은
            # `action_registry.json` 이고, 리터럴은 그것의 두 번째 진실원이 된다.
            ids = [i for i in ids if length(collect(ActionRegistry.REGISTRY[i].kinds)) > 1]
        end
        return [ActionRegistry.NAME[i] for i in ids]
    end
    # 🔴 2026-08-24 (spec §5.1, Task 4): 여기 있던 `truth isa CB.ZoneTruth` 분기를 통째로 지웠다.
    # 그 분기는 `named`/`zone_diagnosis(...; check_restage=true)` 로 도메인을 재서
    # `["NOOP","ForbidZone","RelocateBuild"]` 또는 `["NOOP","RelocateBuild"]` 를 냈다 — 즉 zone 을
    # **LLM 이 결정할 사건**으로 만드는 자리였다. zone 은 이제 surrogate 학습 증거로만 쓰고
    # 결정 epoch 를 만들지 않는다. 위 docstring 의 zone 논쟁은 역사로 남겨 뒀다.
    # 🔴 2026-08-24 (spec §5.4, Task 5): `Deprioritize` 를 이 메뉴에서 뺐다. 배터리 사건의 개입
    # 팔은 이제 `Replace`(창고 예비 본체를 먹음)와 `SwapBattery`(현장 교체) 둘뿐이고, 배터리
    # 레이어가 꺼져 있으면 `Replace` 하나다.
    # ---- zone: 닫힌 어휘에 수복이 없다는 사실을 **메뉴로** 말한다 (2026-08-25) ---------------
    # Task 4 가 zone 분기를 지운 뒤 이 함수는 zone 에 `String[]` 을 돌려줬고, 그러면
    # `service_decide` 가 `payload["valid"]` 를 안 실어 서비스의 `_valid_for` 가
    # `VALID.get("zone", MACROS)` 로 **전체 3팔로 폴백**한다(레지스트리에 zone 키가 없으므로).
    # 실측(2026-08-25, gpt-4o): 구역 사건에서 LLM 이 `SwapBattery` 를 2순위로 올렸다. 그 팔은
    # `ZoneTruth` 에 `:robot` 이 없어 집행 사슬의 가드에 걸려 **아무 일도 안 하는데**, 결정
    # 기록에는 그 이름이 그대로 남는다 = 집행되지 않은 팔이 라벨이 된다.
    #
    # 그래서 정직한 메뉴를 명시적으로 낸다. 오늘 그 값은 `["NOOP"]` 이고, 뜻은 **"닫힌 어휘에
    # 이 구역의 수복이 없다"**(= `zone_diagnosis` 의 `:line_stop`). 이건 결함이 아니라 OOD 경계
    # 표식이고, 아래 `decide_all` 의 표현력 에스컬레이션이 붙잡아야 할 바로 그 신호다
    # (L2 제약 신설 레인이 인계받을 자리). 어휘에 zone 팔이 다시 생기면 자동으로 따라온다.
    #
    # 규약은 `ood_mdp_shim._zone_arms()` 와 **같다**(NOOP + 레지스트리의 zone 팔) — 두 레인이
    # 다른 규약을 쓰면 라벨 레인과 실행 레인의 메뉴가 갈린다.
    # 게이트: `test/policy_macro_binding.jl` (E).
    if truth isa CB.ZoneTruth
        return [ActionRegistry.NAME[i]
                for i in sort(unique(vcat(0, ActionRegistry.kind_valid(:zone))))]
    end
    return String[]          # 그 외 종류는 서비스 기본표 그대로
end

"""
    event_descriptors_of(env, truth) -> Vector{Float64}

종류 이름 없이 계산되는 물리 서술자 6개
`[harm, work_at_risk, resource_loss, recovery_capacity, progress, slack]`.

**이게 라우터의 입력이자 LLM 에게 문장과 함께 주는 숫자다.** 종류를 안 읽으므로 처음 보는 사건에도
그대로 계산된다 -- 새 DSL 종류를 발명할 필요 없이 숫자 6개만 채우면 되는 개방세계 경로.
파이썬 features_agnostic.descriptors_from_row 와 계산이 같아야 교정이 의미를 갖는다(novelty.jl 주석).
"""
function event_descriptors_of(env, truth)
    f = ood_features(env, truth)
    total = length(CB.get_nodes(env.sched))
    return CB.event_descriptors(;
        soc            = get(f, "soc", NaN),
        agent_pending  = get(f, "agent_pending", -1.0),
        zone_overlap   = get(f, "zone_overlap", -1.0),
        severity       = get(f, "severity", 0.0),
        n_active       = get(f, "n_active", 1.0),
        spare_count    = get(f, "spare_count", 0.0),
        closed_at_fire = get(f, "closed_at_fire", 0.0),
        total_nodes    = total,
        progress       = get(f, "progress", 0.0))
end

"""
    route_verdict(; desc, have_det, drives, policy, v=nothing, eps=nothing) -> Dict

라우팅 판정 Dict 를 만든다. **세 분기 전부 `"descriptors"` 키를 갖는다.**

🔴 왜 분리했나 (2026-08-26): 라우팅은 교정값이 있어야 하지만 서술자 계산은 **필요 없다**
(`event_descriptors_of` 는 교정값(novelty detector)을 안 읽는다 — 그래서 교정 유무와 무관하게
계산된다; `ood_features` 를 거쳐 env/CB 내부 상태를 읽고 던질 수 있어 순수 함수는 아니다).
둘이 한 게이트에 묶여 있어서, 교정 파일이 없는 동안 LLM 이 서술자를 한 번도 못 받았다. 이
함수는 교정 유무와 무관하게 `desc` 를 그대로 싣는다. `desc === nothing`(계산 실패)일 때도
**키를 지우지 않는다** — "못 쟀다"와 "안 실었다"는 다른 사건이고, 키가 없으면 소비처가 둘을
구분할 수 없다.

⚠️ `v` 를 주면서 `eps` 를 생략하면 아래에서 명시적으로 에러를 던진다(2026-08-26, F5) —
`round(nothing; digits=3)` 가 `MethodError` 로 죽는 것보다 원인이 뚜렷하다. `route()` 는 둘을
항상 같이 넘기므로 오늘은 이 경로에 도달하지 않지만, 키워드 기본값이 `nothing`/`nothing` 인 한
그 계약이 signature 만으로는 안 보인다.
"""
function route_verdict(; desc, have_det::Bool, drives::Bool, policy::AbstractString,
                       v = nothing, eps::Union{Nothing,Real} = nothing)
    base = Dict{String,Any}("descriptors" => desc)
    if !have_det
        return merge(base, Dict{String,Any}(
            "enabled" => false, "advisory" => false, "target" => policy,
            "novel" => false, "p" => nothing, "score" => nothing, "eps" => nothing,
            "reason" => "no novelty calibration installed -> gate inactive " *
                        "(DEMO_POLICY=$(policy) fixed for the run)"))
    end
    if v === nothing
        return merge(base, Dict{String,Any}(
            "enabled" => false, "advisory" => false, "target" => policy,
            "novel" => false, "p" => nothing, "score" => nothing, "eps" => nothing,
            "reason" => "descriptors unavailable"))
    end
    eps === nothing && error("route_verdict: v is given but eps is nothing -- " *
                             "caller must pass eps whenever v is non-nothing")
    would = v.novel ? "dspy" : "surrogate"
    msg = v.novel ?
        "novelty p=$(round(v.p; digits=3)) < eps=$(round(eps; digits=3)) — NEVER SEEN THIS BEFORE → ask the LLM" :
        "novelty p=$(round(v.p; digits=3)) ≥ eps=$(round(eps; digits=3)) — familiar → surrogate (0.11 ms)"
    return merge(base, Dict{String,Any}(
        "enabled" => drives, "advisory" => !drives,
        "target" => drives ? would : policy, "would_route_to" => would,
        "novel" => v.novel,
        "p" => (isfinite(v.p) ? v.p : nothing),
        "score" => (isfinite(v.score) ? v.score : nothing),
        "eps" => eps,
        "reason" => drives ? msg :
            msg * "  (advisory only — this recording enacted DEMO_POLICY=$(policy), fixed)"))
end

"""
    route(env, truth) -> Dict

이 사건을 누구에게 보낼지 **시스템이** 정한다.

  낯설다(p < eps)  -> "dspy"      : LLM 이 자연어 관찰을 읽는다
  익숙하다         -> "surrogate" : 학습된 forest 가 0.1 ms 에 답한다

돌려주는 Dict 는 그대로 monitor 레코드에 실려 UI 의 ROUTER 줄이 된다. 판정 근거(p, score, eps)를
전부 남기는 이유: "왜 이쪽으로 보냈는가"가 화면에서 검증 가능해야 하기 때문.
"""
function route(env, truth)
    # 판정은 **항상** 계산한다. DEMO_ROUTER=0 이어도 마찬가지다.
    #   enabled=true  : 라우터가 실행 정책을 정한다
    #   enabled=false : DEMO_POLICY 가 고정 실행되지만, 판정은 참고용(advisory)으로 기록한다
    # 왜: 정책 고정 비교 녹화(24런)에서도 "라우터였다면 어디로 보냈을까"를 화면에서 같이 보려면
    #     그 판정이 스트림에 있어야 한다. 계산 비용은 서술자 6개 + z-거리라 사실상 0 이다.
    # 감지기는 DEMO_ROUTER 설정과 무관하게 **항상** 설치를 시도한다(없으면 조용히 실패).
    # router_enabled() 는 "0" 일 때 설치 자체를 건너뛰므로, 여기서 먼저 설치해야 참고용 판정이 남는다.
    have_det = install_novelty!()
    # ---- no-adapt 바닥선은 라우팅 대상이 아니다 (2026-08-06, STATUS §5 버그) ----------------
    # 증상: `DEMO_POLICY=noop` 으로 돌린 lane 이 3건 모두 Replace 를 실행했다. 원인은 환경변수
    # 전달이 아니라 **여기**다 — DEMO_ROUTER 의 기본값이 auto 이고 교정파일이 설치돼 있으면
    # 라우터가 켜져서 아래 `requested = rt["target"]` 이 POLICY 를 통째로 덮어썼다. 라우터의
    # target 은 surrogate/dspy 뿐이므로 noop 은 절대 실행될 수 없었다.
    # noop 은 "정책 후보" 가 아니라 **통제 실험의 바닥선**이다. 개입이 실제로 이득인지 재려면
    # 아무도 이 lane 을 대신 판단해 주면 안 된다. 그래서 라우팅 자체를 끈다(판정은 참고용 기록).
    drives = have_det && router_enabled() && POLICY != "noop"

    # 🔴 서술자를 **먼저** 계산한다. 교정 유무와 무관하다 — 계산은 event_descriptors_of 의
    # docstring 이 말하듯 교정값(novelty detector)을 안 읽는다.
    desc = try event_descriptors_of(env, truth) catch e
        @warn "descriptor computation failed -> router falls back" exception = e
        nothing
    end

    have_det || return route_verdict(desc = desc, have_det = false, drives = false,
                                     policy = POLICY)
    desc === nothing && return route_verdict(desc = nothing, have_det = true, drives = drives,
                                             policy = POLICY)

    v = CB.novelty_verdict(desc; eps = ROUTER_EPS)
    eps = ROUTER_EPS === nothing ? (try CB.novelty_detector().alpha catch; 0.05 end) : ROUTER_EPS
    return route_verdict(desc = desc, have_det = true, drives = drives, policy = POLICY,
                         v = v, eps = eps)
end

const DSPY_HEALTHY = Ref{Union{Nothing,Bool}}(nothing)

"DSPy 서비스가 살아 있는지 한 번만 확인해 캐시한다(매 이벤트마다 찌르지 않도록)."
function dspy_ready()
    DSPY_HEALTHY[] === nothing || return DSPY_HEALTHY[]
    ok = try
        HTTP.get(DSPY_URL * "/health"; readtimeout = 5, retries = 0).status == 200
    catch; false end
    DSPY_HEALTHY[] = ok
    ok || @warn "DSPy service unreachable at $DSPY_URL -> falling back to canonical"
    return ok
end

"상태를 서비스에 POST 하고 **학습형 정책 전부**(dspy + surrogate)의 결정을 한 번에 받는다. 실패하면 nothing."
function service_decide(env, truth; nl::AbstractString = "", descriptors = nothing)
    dspy_ready() || return nothing
    # payload = 예전 스키마 피처(surrogate 용) + nl/descriptors(LLM 용). 서비스는 nl 이 있으면
    # LLM 에게 **문장**을 주고, 없으면 예전처럼 파싱된 필드를 준다(하위호환).
    payload = ood_features(env, truth)
    isempty(nl) || (payload["nl"] = String(nl))
    # 데모의 기본은 **observation**: 주입기 문장 뒤에 붙는 "그러니 무엇을 하라" 절을 떼고 관찰만 준다.
    # 그 뒷절이 곧 canonical 정답이라, 그대로 주면 재는 것이 추론이 아니라 프롬프트 준수가 된다
    # (실측: 서술자가 harm=0.02 인데도 "restage 하라"를 따라 ForbidZone 을 골랐다).
    # 서비스는 별도 프로세스라 환경변수로는 못 미치므로 요청에 실어 보낸다. LLM_NL_MODE=raw 로 옛 동작.
    payload["nl_mode"] = lowercase(get(ENV, "LLM_NL_MODE", "observation"))
    descriptors === nothing || (payload["descriptors"] = collect(Float64, descriptors))
    # 이 순간 **실제로 실행 가능한** 매크로만 legal 로 넘긴다(valid_macros 주석 참조).
    # 비어 있으면 서비스가 예전처럼 kind 별 기본표를 쓴다 = 기존 호출자 동작 그대로.
    local vm = valid_macros(env, truth)
    isempty(vm) || (payload["valid"] = vm)
    try
        # retry_non_idempotent=true 가 꼭 필요하다: HTTP.jl 은 POST 를 기본적으로 재시도하지 않는데,
        # 이벤트 간격이 길어 keep-alive 연결이 죽어 있으면 첫 시도가 "stream is closed or unusable"로
        # 실패한다(실제로 두 번째 OOD 에서 그렇게 폴백됐다). 이 호출은 부작용이 없으므로 재시도해도 안전.
        resp = HTTP.post(DSPY_URL * "/decide", ["Content-Type" => "application/json"],
                         JSON3.write(payload);
                         readtimeout = 60, retries = 3, retry_non_idempotent = true)
        resp.status == 200 || return nothing
        j = JSON3.read(String(resp.body))
        return j
    catch e
        @warn "DSPy call failed" exception = e
        return nothing
    end
end

"canonical 규칙이 고른 매크로 이름(규칙표 그대로, 실행 가능성 미고려)."
function canonical_macro(truth)
    prop = try CB.canonical_respec(truth) catch; nothing end
    (prop === nothing || isempty(prop.constraints)) ? "NOOP" :
        string(typeof(prop.constraints[1]).name.name)
end

"""
    canonical_macro(env, truth) -> String

규칙표의 답을 **지금 실행 가능한 어휘로 투영**한 것.

왜 필요한가(2026-08-05): 규칙과 LLM 이 서로 다른 어휘를 보면 화면의 "규칙 vs LLM 불일치"가
판단의 차이가 아니라 **어휘가 갈린 아티팩트**가 된다. 2026-08-03 에 zone 팔이 ForbidZone →
RelocateBuild 로 바뀔 때 `canonical_respec(::ZoneTruth)`(baselines.jl)는 오프라인 채점 기준이라
일부러 남겨 뒀고, 그 뒤로 데모 로그에는 늘 `rule=ForbidZone, dspy=RelocateBuild` 가 찍혔다.

여기서는 `baselines.jl` 을 건드리지 않고(그건 오프라인 실험의 B1 기준선이다) **데모 표시·집행용
규칙**만 투영한다: 규칙이 고른 팔이 지금 도메인이 비어 아무것도 못 하면 **NOOP** 이라고 말한다.

왜 "더 센 팔로 격상"이 아닌가(2026-08-05 실측으로 반증됨): 처음에는 ForbidZone 이 불가능하면
RelocateBuild 로 올리려 했다. 그런데 같은 seed·같은 존으로 매크로만 교차해 재보니,
국소 복구 대상이 하나도 없는 판에서 **아무것도 안 함 = closed 231(조립체 7/8)** 인 반면
**빌드 전체 이동 = closed 136(조립체 1/8)** 이었다. 전역 이동은 공짜가 아니라 진행 중인 운반을
통째로 흔든다. 규칙(기준선)의 정직한 답은 "내 팔은 지금 할 일이 없다"이고, 그럼에도 개입할지는
정책(LLM/surrogate)이 판단할 문제다 — 기준선이 대신 도박하면 baseline 이 아니게 된다.
"""
function canonical_macro(env, truth)
    m = _macro_label(canonical_macro(truth))
    vm = valid_macros(env, truth)
    (isempty(vm) || m in vm) && return m
    return "NOOP"      # 규칙이 고른 팔이 지금 도메인이 비었다 = 규칙은 할 말이 없다
end

# ---- oracle lane: 기준 행동 a* 의 실행판 (2026-08-12) -----------------------------------
# `wm4spacecraft_manufacturing/core/reference_policy.py` 의 a* 규칙을 **결정 시점에** 계산한 것.
# 저쪽은 판이 끝난 뒤 decisions[] 를 읽는 사후 채점기라 실행 lane 이 될 수 없다.
#
# 왜 신설했는가(2026-08-12 진단): 이 함수가 없던 동안 `DEMO_POLICY=oracle` 은 아래 decide_all 의
# `enacted = "canonical"` 폴백(존재하지 않는 정책 키)으로 **조용히** 떨어졌다. 경고도 종료코드도
# 없이 요약 행만 `"policy":"oracle"` 로 남아, 이름만 oracle 인 canonical 판이 만들어졌다.
# 실측 증상은 a* 대비 결정 적중률 0/4 였다(정의상 4/4 여야 하는 lane).
#
# 매크로 이름 문자열은 일부러 reference_policy.py 와 **같은 리터럴**을 쓴다(레지스트리 경유 금지 —
# 경유하면 두 파일이 다른 이름 체계를 쓰게 된다). 두 구현이 갈려도 에러는 안 난다: 표의 `oracle`
# 행이 "a* 를 집행했다"는 이름으로 다른 것을 집행할 뿐이다.
#
# ★ a* 가 미정의인 자리에서는 **언제나 `canonical_macro` 로 위임한다. NOOP 이 아니다.**
#   (reform 사건 · 근거 없는 SoC 구간 · agent_pending 미기록 · zone_diagnosis 실패)
#   두 가지 이유가 겹친다:
#     1) reference_policy 는 정확히 같은 자리에서 a*=None(unscored)을 낸다. "Julia 가 위임한 사건"
#        과 "Python 이 채점에서 뺀 사건" 이 겹쳐야 "채점된 사건에서 oracle 적중률 1.0" 계약이 선다.
#     2) NOOP 으로 떨어지면 재형성이 필요한 교착을 그대로 두게 되고 **그것이 곧 미완주다**
#        (md/README.md §6: 복구를 되살린 처방이 DEMO_REFORM). canonical_macro 는 규칙의 답을 지금
#        실행 가능한 어휘로 투영하므로(바로 위 함수) 실행 불가능한 팔은 절대 내지 않는다.
#
# 아래 상수는 `reference_policy.py` 의 `BATTERY_DEEP_SOC` 와 **같은 값이어야 한다**(줄번호로
# 찾지 말 것 — 이 레포는 줄번호가 계속 밀린다. 심볼로 찾는다). 갈리면 그 사이 SoC 구간에서 두
# 구현이 다른 팔을 내고, 증상은 에러가 아니라 **oracle 레인의 결정 적중률이 1.0 미만**으로
# 나타난다.
#
# 왜 0.2 인가 (2026-08-25): `reference_policy.BATTERY_DEEP_SOC` 가 0.5 -> 0.2 로 내려갔는데
# (그쪽 주석대로 `src/navigator/ood_truth.jl` 의 `REPLACE_SOC_THRESHOLD` = 0.2 와 통일한
# 값이다) 이 상수만 0.5 로 남아 있었다. 그 사이 구간 `(0.2, 0.5]` 에서 oracle 레인은 팔을
# 내는데 파이썬 채점기는 같은 사건을 unscored 로 뺐다 — 실측: 현행 라벨셋
# `oracle/out/oracle_dataset.jsonl` 의 battery 행 27개 중 **18개**가 그 구간에 있다.
#
# 🔴 왜 리터럴인가 — 유도를 시도했고 **못 한다**. (추론이 아니라 배선 제약이다.)
#   · 파이썬 쪽 `BATTERY_DEEP_SOC` 는 다른 언어라 로드 시점에 읽을 수 없다.
#   · 줄리아 쪽 진실원 `CB.REPLACE_SOC_THRESHOLD[]` 로는 유도할 수 있어 **보이지만**, 이 파일은
#     `CB` 도 navigator 레이어도 없는 맨 모듈에서 로드될 수 있어야 한다:
#     `test/policy_macro_binding.jl` 의 (B)·(C) 양성대조가 정확히 그 형태
#     (`module _M; import HTTP, JSON3; include("policy.jl") end`)로 이 파일을 띄우고, 그 게이트는
#     `test/runtests.jl` 에 실려 있다. 최상위에서 `CB.` 를 만지면 그 게이트가 UndefVarError 로
#     빨개진다. `isdefined(...) ? ...[] : 0.2` 식 폴백은 **리터럴을 조용히 되살리는 것**이라
#     더 나쁘다(이 레포에 이미 셋 있다: battery.jl · hazard.jl · replace_robot.jl).
#
# 그래서 값은 리터럴로 두고 **둘을 묶는 일은 게이트가 한다**: `tools/test_policy_oracle.jl` 의
# 0절이 `reference_policy.py` 를 정규식으로 직접 읽어 이 상수와 대조한다. 그 게이트는
# 2026-08-25 부터 `test/runtests.jl` 에 배선돼 있다 — 그 전까지 **고아 게이트**였고, 그래서
# 이 회귀(0.5 대 0.2)가 최종 리뷰까지 살아남았다. 배선을 빼면 방어선이 사라진다.
const ORACLE_BATTERY_DEEP_SOC = 0.2      # == reference_policy.py `BATTERY_DEEP_SOC` (게이트: tools/test_policy_oracle.jl 0절)

# ---- "지금 운반체가 이동 중인가" 술어 (2026-08-13) ------------------------------------------
# **oracle 레인 전용이다.** 이 함수는 `oracle_macro` 만 부른다 — 공유 장부(RECOVERY_SPARES)를
# 건드리지 않으므로 noop/surrogate/dspy/canonical 의 결정은 한 비트도 바뀌지 않는다.
#
# 무엇을 재는가: RelocateBuild 는 **남아 있는 항법 목표 전부를 한 번에 평행이동**시킨다
# (verifier.jl RELOCATE_GATE: "it moves every future goal and staging circle at once, while
# carriers are mid-transit"). 그래서 위험한 상태는 "이 판에서 Replace 가 있었는가"(래치)가 아니라
# **복구 임무 중인 로봇이 지금 자기 발로 목표를 향해 가고 있는가** 다.
#
# 어느 로봇을 보는가: RECOVERY_SPARES 는 세 경로에서 채워지는데(replace_robot.jl:1182 · :1271 ·
# :1503) **창고 왕복이 있는 것은 :1503(hot_swap_robot! :via_depot) 하나뿐**이다. 앞의 둘은 이미
# 현장에 있던 예비를 스케줄에 접합할 뿐이라 "먼 창고에서 걸어 돌아오는 중" 이 아니다. 그 셋을
# 가르는 표식이 `DECOMMISSIONED_BODIES` 다 -- :via_depot 가지에서만(replace_robot.jl:1499)
# `mark_recovery_spare!` 와 **같은 자리에서** 기록된다. 그래서 게이트는
# `RECOVERY_SPARES ∩ keys(decommissioned_bodies())` 만 본다(읽기 전용 조회, 공유 상태 불변).
#
# 그 로봇이 아직 오는 중인가(`_nav_goal_targets` 로 — zone_diagnosis 가 이미 쓰는 같은 계산기다.
# 게이트와 진단이 서로 다른 기하를 보면 안 된다, verifier.jl:307 과 같은 원칙):
#   · 남은 항법 목표가 **없다**                    -> 도착(더 갈 곳이 없다)
#   · 운반팀에 **포획돼 있다**(_transport_unit_parent) -> 도착. 인계가 끝나 팀의 일부로 실려 간다;
#     이 상태에서는 RVO 주체도 팀이라 "혼자 걸어오는 중"이 아니다.
#   · 그 외: 남은 목표 중 **가장 가까운 것까지의 거리**가 제 몸 반경보다 멀면 = 아직 오는 중.
#     임의 상수가 아니라 그 에이전트의 반경(`_nav_goal_targets` 가 실어 주는 값)을 쓴다.
#
# 왜 "빌드 프레임 밖" 이 아닌가(2026-08-13 실측으로 기각): 프레임(남은 항법 목표의 중심·최대
# 이심거리)은 R≈20 으로 커서 depot(D=20)에서 나온 로봇도 몇 걸음 만에 안쪽으로 들어온다. 그
# 술어로 5판을 재보니 게이트가 **한 번도 발화하지 않아** 사실상 게이트 없는 상태(= df92c37
# 이전)로 되돌아갔고, 그 조건에서 완주하던 fault_zone s1/s5 가 다시 186/185 에서 멎었다.
#   실측(s1 closed=99):  spare R1 pos=[-8.01,0.93] 가장 가까운 목표까지 5.72, 팀 미포획 → 오는 중
#   실측(s14 closed=189): spare R5 팀에 포획됨, dgoal=0.0                       → 인계 완료
#
# 실패 시 **true(=이동 중)로 폴백**한다: 못 읽는 상태에서 전역 이동을 허용하는 쪽이 더 위험하다.
# ENV ORACLE_TRANSIT_DEBUG=1 이면 판정 근거를 남긴다(진단용, 동작 무영향).
function _recovery_in_transit(env)
    local spares = try CB.recovery_spares() catch; return true end
    isempty(spares) && return false                 # 복구 임무 중인 로봇이 아예 없다
    local navs = try CB._nav_goal_targets(env) catch; return true end
    local depot = try CB.decommissioned_bodies() catch; return true end
    local dbg = get(ENV, "ORACLE_TRANSIT_DEBUG", "0") == "1"
    local intransit = false
    for rid in spares
        local viadepot = haskey(depot, rid)          # 창고 왕복이 있었던 역할만 "돌아오는 중" 후보
        if !viadepot
            dbg && println("[oracle-transit]   R$(try rid.id catch; "?" end) via_depot=false -> moving=false")
            continue
        end
        local mine = [t for t in navs if t.kind === :robot && t.id == rid]
        isempty(mine) && continue                                  # 남은 항법 목표 없음 = 도착
        local captured = try CB._transport_unit_parent(env.scene_tree, rid) !== nothing catch; false end
        local dmin = minimum(t -> hypot(t.pos[1] - t.goal[1], t.pos[2] - t.goal[2]), mine)
        local tol  = max(maximum(t -> Float64(t.radius), mine), CB.capture_distance_tolerance())
        local mv   = !captured && dmin > tol
        mv && (intransit = true)
        # println 이다(@info 가 아니다): 실판은 log_level=Logging.Error 로 돌아 @info 가 삼켜진다.
        dbg && println("[oracle-transit]   R$(try rid.id catch; "?" end) goals=$(length(mine)) " *
                       "dmin=$(round(dmin,digits=2)) tol=$(round(tol,digits=2)) captured=$(captured) -> moving=$(mv)")
        (mv && !dbg) && return true
    end
    dbg && println("[oracle-transit] spares=$(length(spares)) -> in_transit=$(intransit)")
    return intransit
end

function oracle_macro(env, truth)
    vm = valid_macros(env, truth)
    if truth isa CB.BatteryTruth
        local soc = try Float64(truth.soc_after) catch; nothing end
        # NaN <= x 는 조용히 false 라 mild 가지로 새어 들어간다 -- reference_policy._finite_soc 와
        # 같은 게이트를 여기서도 통과시킨다.
        (soc === nothing || !isfinite(soc)) && return canonical_macro(env, truth)
        # 깊은 방전. D=20 사다리(n44_plus78_d20)에서 SwapBattery 가 세 칸(0.02·0.30·0.50)
        # 전부에서 이겼지만(0.02 = 완주 여부, 0.30·0.50 = makespan), 임계값이 0.2 로 내려가면서
        # **이 가지에 남는 것은 0.02 칸 하나뿐이다** — 나머지 두 칸은 아래 unscored 구간으로
        # 밀려났다(대가는 reference_policy.py 의 `BATTERY_DEEP_SOC` 대입부 주석에 적혀 있다).
        # SwapBattery 가 메뉴에 없는 배선에서는 Replace 가 그 자리를 대신한다 --
        # reference_policy.py `a_star` 의 `"SwapBattery" if ... else "Replace"` 와 같은 규칙.
        soc <= ORACLE_BATTERY_DEEP_SOC && return ("SwapBattery" in vm ? "SwapBattery" : "Replace")
        # SoC > ORACLE_BATTERY_DEEP_SOC 는 채점 근거가 없는 구간이다(사다리의 0.30·0.50 rung 이
        # 여기로 밀려났다 — 측정은 있었지만 임계값이 그 아래에 있다). reference_policy.py 의
        # 같은 자리가 이 구간을 unscored(a*=None)로 뺀다 -- 없는 정답을 지어내지 않는다.
        # ★ NOOP 이 아니라 canonical 위임이다(이 함수 위 ★ 주석).
        return canonical_macro(env, truth)
    elseif truth isa CB.FaultTruth
        local pend = try _agent_pending(env, truth.robot) catch; -1 end
        pend < 0 && return canonical_macro(env, truth)   # 미기록 = reference_policy.py:190 도 unscored
        # firegrid 실측은 완전 분리다(24/24, 18/18): "고장났으니 교체" 가 아니라 **일을 지고
        # 있었는가** 가 가른다.
        return pend > 0 ? "Replace" : "NOOP"
    elseif truth isa CB.ZoneTruth
        local zdg = try CB.zone_diagnosis(env, truth.zone) catch; nothing end
        # 진단이 없거나 구역이 죽었으면 run_demo 요약의 zone_primitives 도 비고(아래 zone 블록이
        # 같은 조건으로 기록한다) reference_policy.py:199 가 그 사건을 unscored 로 뺀다.
        (zdg === nothing || !zdg.exists) && return canonical_macro(env, truth)
        # (1) **개입할 이유가 있는가** -- 여기까지는 reference_policy.py:203 과 글자 그대로 같다.
        #     막힌 것이 **항법 목표**이고 root 하역목표는 안 걸렸을 때만 공간형 팔이 값을 한다
        #     (zcausal_reform STEP 10: blk 279 완주 vs NOOP 254 정지 / cov 는 반대로 뒤집힌다).
        (zdg.n_nav_blocked > 0 && zdg.root_covered == 0) || return "NOOP"
        # ---------------------------------------------------------------------------------
        # (2) **그 팔이 지금 실제로 무엇을 할 수 있는가** (2026-08-13 추가)
        #     원칙은 이 저장소가 이미 적어 둔 것이다(dspy_service.py:96):
        #     "legal 은 kind 가 아니라 그 순간 그 팔이 실제로 무언가를 할 수 있는가로 정해져야 한다."
        #
        #     ⓐ ForbidZone 은 도메인이 비면 **별개의 팔이 아니다.** restage_all_blocked! 이
        #        :residual_blocked 를 내면 maybe_respecify! 가 자동으로 whole-build 평행이동으로
        #        격상한다. 2026-08-13 실측(zone s1, DEMO_FORCE_MACRO 교차): ForbidZone 판과
        #        RelocateBuild 판이 closed 270 · sim 138.425 · steps 5537 로 **완전히 같았고**,
        #        로그에 `[zone] staging=none final=translated` 가 남았다. 그래서 실제 선택지는
        #        "전역 평행이동인가 아닌가" 둘뿐이며, ForbidZone 은 `n_restage_feasible > 0`
        #        (= 실제로 옮길 조립체가 있다) 일 때만 자기 이름값을 한다.
        #
        #     ⓑ 전역 평행이동은 **빌드 프레임 밖에 돌아올 로봇이 없을 때만** 수복이다.
        #        verifier.jl RELOCATE_GATE 독스트링이 이미 그 위험을 적어 뒀다("it moves every
        #        future goal and staging circle at once, while carriers are mid-transit").
        #        depot 에서 몸체를 갈아 끼운 역할(hot_swap_robot! :via_depot)은 창고 자리에서 다시
        #        등장해 빌드까지 **걸어 돌아와야** 하고, 그 사실이 `mark_recovery_spare!` 로
        #        RECOVERY_SPARES 에 남는다. 그 상태에서 빌드를 통째로 옮기면 그 로봇의 목표가
        #        발밑에서 사라진다.
        #
        #        ‼ **[해소됨 2026-08-13] 이 자리에 있던 술어는 그 문장을 구현하지 않았다.**
        #          `!isempty(CB.recovery_spares())` 가 실제로 뜻한 것은 "지금 돌아오는 중인
        #          로봇이 있다" 가 아니라 **"이 판에서 Replace 가 한 번이라도 일어났는가"** 였다.
        #          런 범위(run-scoped)의 **단방향 래치**다. 근거:
        #            · ood_injection.jl:787-795 의 RECOVERY_SPARES 인터페이스는 `push!`
        #              (mark_recovery_spare!) 와 `empty!`(clear_recovery_spares!) 뿐이다 --
        #              **도착했다고 원소를 빼는 경로가 아예 없다.** clear_ 는 판 시작 시 초기화
        #              (demos.jl:792/1636/1744/2800)에서만 불린다.
        #            · 표식을 다는 곳도 depot 스왑만이 아니다: 평범한 예비 접합(spare-splice)
        #              Replace 경로인 replace_robot.jl:1182 와 :1271 이 이미 단다. depot 스왑
        #              (:1503)은 셋 중 하나일 뿐이다. 즉 창고 왕복이 없는 Replace 도 래치를 걸었다.
        #
        #          ⇒ **대가(실측 v1, results_oracle/ 210판):** `fault_zone` 22/30. 8개 미완주 중
        #            7개가 정확히 `Replace → ZoneTruth→NOOP` 모양으로 closed=285 에 멎었다.
        #            Replace 가 한참 전에 끝나 예비가 이미 도착했는데도 뒤따르는 zone 사건이
        #            전부 NOOP 을 받아 `n_nav_blocked > 0` 이 수복되지 않았고, 이 게이트가
        #            막으려던 바로 그 교착이 **반대편에서** 생겼다(전역 이동으로 목표를 지워
        #            stall 하는 대신, 아무것도 안 해서 막힌 채로 stall).
        #
        #          ⇒ **고친 방식: `_recovery_in_transit(env)` (위 정의).** RECOVERY_SPARES 에
        #            "도착하면 뺀다" 경로를 넣는 쪽이 '진짜' 수정이지만 **그 집합은 oracle 만
        #            읽는 것이 아니다**: route_planning.jl:200(RVO alpha) · ood_injection.jl:869
        #            /918/968(고장 표적 선정) · navigator/battery.jl:440 · mdp/hazard.jl:453 ·
        #            replace_robot.jl:1070 이 전부 읽는다. 원소를 빼면 **모든 레인의 물리와 고장
        #            표적이 바뀌어** 이미 커밋된 630판 noop/surrogate/dspy 스윕이 조용히 무효가
        #            된다. 그래서 술어를 **oracle 레인 안에서만** 다시 계산한다(공유 상태 불변).
        #            새 술어의 뜻: "복구 임무 중인 로봇이 지금 **혼자 목표를 향해 오는 중인가**"
        #            (팀에 포획됐거나 제 몸 반경 안에 목표가 있으면 도착). 인계가 끝나면 스스로
        #            풀리므로 래치가 아니다.
        #
        #        아래 실측은 위 정정과 무관하게 유효하다(둘 다 Replace 직후의 zone 사건이다):
        #        2026-08-13 실측(seed 1, 같은 구역·같은 Δ=[-1.75984, -1.60557]):
        #          battery_zone: closed=58 에 SwapBattery(창고 왕복 없음) → RECOVERY_SPARES 빈 채로
        #                        closed=100 에 RelocateBuild → **완주 291/313** (30.3 s)
        #          fault_zone  : closed=58 에 Replace(:via_depot)         → closed=99 에
        #                        RelocateBuild → **stall 186/313** (2판 소수점까지 동일)
        #        두 판의 zone_primitives 는 n_teams_forming(3 vs 5) 말고 **전부 동일**하다
        #        (nav_goals 112 · nav_blocked 3 · root 0/8 · n_restage_feasible 0 · relocate_feasible).
        #        즉 구역 기하만으로는 두 사건을 구분할 수 없다 — 구분하는 것은 "빌드 밖에 돌아올
        #        로봇이 있는가" 라는 **상태**다. 복구 사다리로는 못 푼다(DEMO_REFORM_MAX 6 → 186,
        #        12 → 191, 둘 다 stall).
        #
        #     ⚠ 이 가지는 **reference_policy.py 와 의도적으로 갈린다.** 저쪽은 RECOVERY_SPARES 를
        #       볼 수 없어(요약의 zone_primitives 에 그 칸이 없다) 언제나 RelocateBuild 를 낸다.
        #       그래서 Replace 가 선행한 zone 사건에서 oracle 레인의 결정 적중률은 1.0 미만이 된다.
        #       그 값을 1.0 으로 되돌리려면 reference_policy.py 의 zone 규칙도 같이 고쳐야 하는데,
        #       그러면 이미 발행된 표의 decision_acc 열이 전부 조용히 재채점된다
        #       (build_md_report.py:417 이 같은 이유로 그 파일을 고정해 뒀다). 그래서 **여기만**
        #       고치고 갈림을 보고서에 명시한다.
        # `returning` = "복구 임무 중인 로봇이 지금 빌드 프레임 밖에서 돌아오는 중인가".
        # 도착하면 스스로 풀린다(래치 아님). 정의는 위 `_recovery_in_transit` 참조.
        local returning = _recovery_in_transit(env)
        (!returning && zdg.relocate_feasible && "RelocateBuild" in vm) && return "RelocateBuild"
        (zdg.n_restage_feasible > 0 && "ForbidZone" in vm) && return "ForbidZone"
        return "NOOP"
    end
    # reform 등: 실측 격자가 없어 a* 가 미정의다(reference_policy.py:208 이 unscored 로 뺀다).
    return canonical_macro(env, truth)
end

# ---- 통제 실험용 강제 매크로 -----------------------------------------------------------
# DEMO_FORCE_MACRO=<이름> 이면 **어느 정책이 실행되든** 그 매크로를 집행한다.
# 용도는 하나뿐이다: "결과가 갈린 이유가 매크로인가 정책인가"를 가르는 교차 대조
# (같은 매크로를 다른 정책이 내게 해서 세계가 같은지 본다). 강제 사실은 verdict 에 남긴다 —
# 기록이 "canonical 이 RelocateBuild 를 골랐다"로 읽히면 그게 곧 거짓말이 되기 때문.
const FORCE_MACRO = strip(get(ENV, "DEMO_FORCE_MACRO", ""))

# 🔴 2026-08-24 (Task 6 · 컨트롤러 판정 R-42): FORCE_MACRO 는 **메뉴와 대조된 적이 없었다.**
# `macro_to_proposal` 이 모르는 이름은 아래쪽에서 조용히 **빈 제안**으로 떨어지고
# (`policy.jl` 맨 아래 `return CB.RespecProposal(CB.ConstraintSpec[], ...)`) `enact_applied`
# 가 false 로 남는데, 그 판의 결정 기록에는 `forced_macro=<그 이름>` 과 `chosen=<그 이름>` 이
# 그대로 찍힌다 — 즉 **고르지 않은(집행되지 않은) 팔을 골랐다고 적힌 판**이 만들어진다.
# 축 C 로 어휘가 3팔이 되면서 `Deprioritize`(Task 5) · `ForbidZone`·`RelocateBuild`(Task 4)
# 세 이름이 전부 이 상태가 됐고, `wm4spacecraft_manufacturing/smdp/gate_g6.py` 의 머리말이
# `DEMO_FORCE_MACRO=Deprioritize DEMO_OOD=battery` 를 재현 레시피로 적어 두고 있다 — 가상의
# 조합이 아니라 도달 가능한 설정이다. 그래서 **읽는 자리에서 바로, 시끄럽게** 죽인다.
#
# 🔴 2026-08-24 리뷰 라운드 1 (Important #2): 이 목록은 처음에 리터럴 튜플이었고
# `ReformTeam` 을 포함했다 -- 그 이름은 `action_registry.json` 이 2026-08-20 에 **삭제**한
# 팔이라, `DEMO_FORCE_MACRO=ReformTeam` 이 검사를 통과한 뒤 실제로 집행돼(`macro_to_proposal`
# → `run_demo.jl` 의 `mac == "ReformTeam"` 분기) **어휘 도장이 v4-3arms 인 판에 어휘 밖 팔이
# 라벨로 박히는** 결과를 냈다. 리터럴은 레지스트리의 네 번째 진실원이었다.
# 그래서 **레지스트리에서 유도한다** — Task 2 가 세운 단일 진실원 그대로.
# 바인딩은 `test/policy_macro_binding.jl` 이 지킨다(runtests.jl 에 실려 있다). 그 게이트는
# 세 방향을 전부 잰다: 리터럴 복원 · 레지스트리에만 팔이 늘어난 경우(= `macro_to_proposal`
# 분기 누락) · 아래 두 손잡이 중 하나의 검사만 지운 경우. 셋 다 변형으로 RED 를 확인했다.
#
# ⚠️ **상수가 아니라 함수다.** 두 가지 이유:
#    (1) `ActionRegistry.is_active` 자체가 의도적으로 함수다 — experimental 게이트
#        (`DS_COMBO_ARMS`)를 **호출 시점**에 읽어야 하고, 상수로 접으면 로드 순서에 따라
#        플래그가 조용히 무시된다(action_registry.jl 의 `is_active` 독스트링). 그 함수를
#        상수로 스냅샷하면 여기서 그 계약을 되돌리는 셈이다.
#    (2) `const` 로 두면 `test/smdp_global_inventory.jl` 의 RHS 머리 census 가 새 머리
#        (`Tuple`)를 보고 죽는다 — 그 게이트를 통과시키려면 `src/smdp/state_globals.jl`
#        (이번 라운드에 손대지 못하게 묶인 파일)에 새 hunk 를 얹어야 한다. 함수 정의는
#        최상위 바인딩을 새로 만들지 않으므로 그 census 의 대상이 아니다(실측: 아래 두
#        게이트 모두 초록).
isdefined(@__MODULE__, :ActionRegistry) ||
    include(joinpath(@__DIR__, "..", "..", "wm4spacecraft_manufacturing", "oracle",
                     "action_registry.jl"))
enactable_macros() = Tuple(ActionRegistry.NAME[i] for i in ActionRegistry.active_ids())
if !isempty(FORCE_MACRO) && !(FORCE_MACRO in enactable_macros())
    error("DEMO_FORCE_MACRO=\"$(FORCE_MACRO)\" 는 집행 가능한 매크로가 아니다 — 현행 메뉴는 " *
          join(enactable_macros(), " · ") * ". 모르는 이름은 빈 제안으로 떨어져 집행은 안 되는데 " *
          "결정 기록에는 '그 팔을 골랐다' 고 남는다(= 거짓 라벨). 오타/구세대 이름을 의심하라.")
end

# ---- 1-step deviation (DP 표집 전용) ---------------------------------------------------
# DS_DEVIATE_AT=k · DS_DEVIATE_ARM=<이름> 이면 **k 번째 결정에서만** 그 팔을 집행하고
# 나머지 결정은 실행 정책(canonical)이 고른 것을 그대로 쓴다.
#
# 왜 FORCE_MACRO 와 따로 두는가: FORCE_MACRO 는 판 전체를 덮는 통제 실험용이고, 그 의미는
# 그대로 남겨야 한다(기존 교차 대조가 그걸 쓴다). 여기서 조건을 붙이면 그 용도가 조용히
# 바뀐다. 두 손잡이가 동시에 켜지면 예외를 던진다 — 어느 쪽이 이겼는지 모르는 판을 만드는
# 것이 이 표집에서 제일 비싼 실패다.
#
# DS_DEVIATE_AT 파싱은 **끄는 것과 오타 낸 것이 같은 코드 경로여선 안 된다.** 이 레포에는
# 정확히 이 모양의 폴백(파싱 실패를 조용히 기본값으로 삼는 것)이 DS_HOTSWAP 하나만 빠뜨려도
# fault 발화율을 100%→23% 로 조용히 무너뜨린 전례가 있다(CLAUDE.md 2026-08-16). 빈 문자열/
# 미설정만 정상 OFF 다. 그 외(정수로 안 읽히는 값·0·음수)는 죽는다 — `something(tryparse(...), 0)`
# 은 그 셋을 전부 "OFF" 로 뭉갠다.
const _DEVIATE_AT_RAW = get(ENV, "DS_DEVIATE_AT", "")
const DEVIATE_AT = if isempty(_DEVIATE_AT_RAW)
    0
else
    local _v = tryparse(Int, _DEVIATE_AT_RAW)
    (_v === nothing || _v <= 0) &&
        error("DS_DEVIATE_AT=\"$(_DEVIATE_AT_RAW)\" 는 정수로 파싱되지 않거나 0 이하다 — " *
              "손잡이를 끄려면 아예 미설정/빈 문자열로 둬라.")
    _v
end
const DEVIATE_ARM = strip(get(ENV, "DS_DEVIATE_ARM", ""))

# 🔴 2026-08-24 (Task 6, 컨트롤러 판정 R-44): `FORCE_MACRO` 와 **정확히 같은 구멍**이 여기에도
# 있었다. 위 파싱 게이트는 `DS_DEVIATE_AT` 의 오타만 잡고 `DS_DEVIATE_ARM` 의 **이름**은 메뉴와
# 대조하지 않는다. 모르는 이름은 `macro_to_proposal` 에서 빈 제안으로 떨어져 집행이 안 되는데
# `should_deviate` 는 그 결정을 "deviated" 로 표시한다 — DP 표집이 **일어나지 않은 이탈**을
# 표본으로 삼게 된다. 같은 `enactable_macros()` 로 같은 자리에서 죽인다.
if !isempty(DEVIATE_ARM) && !(DEVIATE_ARM in enactable_macros())
    error("DS_DEVIATE_ARM=\"$(DEVIATE_ARM)\" 는 집행 가능한 매크로가 아니다 — 현행 메뉴는 " *
          join(enactable_macros(), " · ") * ". 모르는 이름은 빈 제안으로 떨어져 집행은 안 되는데 " *
          "그 결정은 '이탈했다' 고 표본에 남는다(= 거짓 라벨). 오타/구세대 이름을 의심하라.")
end

# ARM 만 있고 AT 이 없으면 언제나 설정 실수다(어느 결정에서 갈아 쓸지가 없다) — 조용한 완전
# canonical 판으로 새지 않게 여기서 잡는다.
!isempty(DEVIATE_ARM) && DEVIATE_AT <= 0 &&
    error("DS_DEVIATE_ARM=\"$(DEVIATE_ARM)\" 만 설정되고 DS_DEVIATE_AT 이 없다 — " *
          "그 조합은 언제나 설정 실수로 본다.")

if !isempty(FORCE_MACRO) && DEVIATE_AT > 0
    error("DEMO_FORCE_MACRO 와 DS_DEVIATE_AT 를 같이 켤 수 없다 — 집행 규칙이 둘이 된다.")
end

# 이 프로세스(=이 판)가 어느 레인인지 board.log 각각이 스스로 말하게 한다.
@info (DEVIATE_AT > 0 ? "[policy] deviation ON: at=$(DEVIATE_AT) arm=$(DEVIATE_ARM)" :
                        "[policy] deviation OFF (DS_DEVIATE_AT unset)")

const _DECISION_N = Ref(0)
_reset_decision_counter!() = (_DECISION_N[] = 0)
_next_decision_index!()    = (_DECISION_N[] += 1; _DECISION_N[])

"""
    should_deviate(at, arm, idx) -> String | nothing

`idx` 번째 결정에서 집행을 `arm` 으로 갈아쓸지. 갈아쓰지 않으면 `nothing`.
순수 함수다 — env·시뮬레이터 없이 검사된다(2026-08-14 의 `escalation_target` 과 같은 이유).
"""
should_deviate(at::Int, arm::AbstractString, idx::Int) =
    (at > 0 && !isempty(arm) && idx == at) ? String(arm) : nothing

# ConstraintSpec 타입 이름 → 매크로 이름 정규화(ReplaceAgent → Replace 등).
_macro_label(s) = s == "ReplaceAgent" ? "Replace" :
                  s == "ForbidZone" ? "ForbidZone" :
                  s == "ReformTeam" ? "ReformTeam" : s

"""
    escalation_target(pol, requested, allowed) -> (target::String, missing::Vector{String})

**표현력 격상** 판정. `requested` 정책이 이 사건의 유효 매크로 중 일부를 **표현조차 못 하면**
(학습 근거 0) LLM 으로 올린다. `target` 이 `"dspy"` 면 격상, `""` 면 그대로 둔다.

왜 순수 함수로 뽑았는가 (2026-08-14)
------------------------------------
이 판정이 `decide_all` 안에 인라인으로 있는 동안에는 env·truth·파이썬 서비스가 전부 살아
있어야만 검사할 수 있었고, 그래서 **한 번도 검사되지 않았다**. 그 사이 조건이
`pol[enacted]["available"]` 를 요구한 채로 남아 회귀가 조용히 들어왔다:
surrogate 가 "개입 후보가 전멸했다"(UNSUPPORTED)를 알리는 방법은 빈 chosen 이라
`available=false` 이고, 그러면 `enacted` 는 이 판정 **전에** 이미 canonical 로 떨어져 있다.
`pol["canonical"]` 에는 `unsupported` 키가 없으므로 게이트는 영원히 안 열렸다 —
격상이 존재하는 이유가 바로 그 사건인데도. 순수 함수면 Dict 만으로 검사된다
(`tools/test_policy_escalation.jl`).

판정 기준은 **요청된** 정책이다(enacted 가 아니다). 못 골라서 아예 못 쓰는 것은 격상의
**더 강한** 근거이지 약한 근거가 아니므로, `available` 은 요구하지 않는다.
"""
function escalation_target(pol, requested, allowed)
    haskey(pol, requested) || return ("", String[])
    local missing = String.(collect(get(pol[requested], "unsupported", String[])))
    isempty(missing) && return ("", String[])
    (allowed && requested != "dspy" &&
     haskey(pol, "dspy") && pol["dspy"]["available"]) || return ("", missing)
    return ("dspy", missing)
end


"""
    policy_entry(b, label) -> Dict

서비스 응답 하나(`b`, 없으면 `nothing`)를 **`decide_all` 이 `pol[key]` 에 넣는 dict** 로 바꾼다.

왜 함수로 뽑았는가 (2026-08-14 최종 리뷰)
----------------------------------------
`escalation_target` 은 순수 함수로 뽑혀 검사되고 있었는데, **그 함수가 읽는 dict 를 만드는
쪽**은 `decide_all` 안에 인라인이라 검사되지 않았다. 그래서 `tools/test_policy_escalation.jl`
의 `unavail()` 은 이 dict 의 **손으로 쓴 복제본**이었고, 실측 확인: 아래 폴백 분기에서
`"unsupported" => miss0` 를 지워도 9개 검사가 전부 초록이었다(= 회귀가 그대로 복원된다).
복제본을 검사하면 복제본만 지켜진다 — 그래서 테스트가 **실제 생산자**를 부르도록 여기 뽑았다.

`b` 는 서비스 응답(JSON3 object) 또는 `nothing`. `get(b, :key, default)` 만 쓰므로 NamedTuple
로도 부를 수 있다(테스트가 그렇게 부른다).
"""
function policy_entry(b, label)
    if b !== nothing
        local err = get(b, :error, nothing)
        if err === nothing && !isempty(String(get(b, :chosen, "")))
            return Dict("chosen" => String(b.chosen),
                        "ranking" => String.(collect(get(b, :ranking, String[]))),
                        "margin" => (try Float64(b.margin) catch; nothing end),
                        "rationale" => String(get(b, :rationale, "")),
                        "scores" => get(b, :scores, nothing),
                        # 이 정책이 **아예 고를 수 없었던** 유효 매크로들(학습 근거 0).
                        # "NOOP 을 골랐다"와 "새 행동을 못 본다"는 전혀 다른 사건이다.
                        "unsupported" => String.(collect(get(b, :unsupported, String[]))),
                        "label" => String(get(b, :policy, label)), "available" => true)
        end
    end
    # ---- 폴백 dict 도 `unsupported` 와 **사유**를 싣는다 (2026-08-14 회귀 수정) ----------
    # 왜: 서비스가 "개입 후보가 전멸했다"를 알리는 방법은 `UNSUPPORTED:` + 빈 chosen 이라
    # 이 분기로 떨어진다. 여기서 unsupported 를 버리면 **표현력 격상 게이트**가
    # 정확히 그 사건에서 근거를 잃는다 — 게이트가 존재하는 이유가 그 사건인데도.
    # rationale 도 남긴다: 기록에 `fell_back=true` 만 있고 **어느 팔이 없었는지**가 없으면,
    # 나중에 이 폴백을 디버깅할 사람이 제일 먼저 찾을 정보가 빠져 있다.
    local miss0 = b === nothing ? String[] : String.(collect(get(b, :unsupported, String[])))
    local err0 = b === nothing ? "" : String(something(get(b, :error, nothing), ""))
    return Dict("chosen" => "", "ranking" => String[], "margin" => nothing,
                "rationale" => (isempty(miss0) ? err0 :
                                "no training support for " * join(miss0, ",")),
                "unsupported" => miss0, "error" => err0,
                "label" => label, "available" => false)
end


"""
    decide_all(env, truth; nl="") -> (policies, enacted, router, ...)

**세 정책을 모두 계산**해 기록용 구조를 만든다. UI 가 "규칙이라면 / surrogate 라면 / LLM 이라면
무엇을 했을까"를 전환해 볼 수 있어야 하므로 매 사건마다 셋 다 남긴다.

실행될 정책(`enacted`)은 **라우터가 사건마다 고른다**(낯설면 LLM, 익숙하면 surrogate).
라우터가 꺼져 있으면 예전대로 DEMO_POLICY 로 런 전체 고정 -- 기존 데모 재현이 깨지지 않게.
"""
function decide_all(env, truth; nl::AbstractString = "")
    canon = canonical_macro(env, truth)     # 규칙표 → 지금 실행 가능한 어휘로 투영
    pol = Dict{String,Any}()
    pol["canonical"] = Dict("chosen" => canon, "ranking" => [canon],
                            "margin" => nothing, "rationale" => "rule lookup (severity threshold)",
                            "label" => "canonical", "available" => true)
    # no-adapt 바닥선(2026-08-05). DEMO_POLICY=noop 으로 고정해 돌리면 어떤 사건에도 개입하지
    # 않는다. "적응이 실제로 이득인가"를 재려면 이 바닥선이 있어야 하고, 없으면 완주율 비교의
    # 분모가 없다. 라우터는 이쪽으로 보내지 않는다(target 은 surrogate/dspy 뿐).
    pol["noop"] = Dict("chosen" => "NOOP", "ranking" => ["NOOP"], "margin" => nothing,
                       "rationale" => "no-adapt floor (never intervenes)",
                       "label" => "no-adapt", "available" => true)
    # ---- a* 집행 lane (2026-08-12) ----------------------------------------------------------
    # "천장을 정말 달릴 수 있었나"를 재는 다섯 번째 주자. 이 lane 의 **결정 적중률은 정의상 1.0**
    # 이라 성능 정보가 없다 -- 그 숫자는 Julia oracle_macro 와 Python reference_policy 가 일치하는지
    # 보는 자기검사 계기판이다. 정보가 있는 것은 그 결정을 실제로 집행했을 때의 완주율·시간·에너지다.
    # 라우터는 이쪽으로 보내지 않는다(target 은 surrogate/dspy 뿐) — noop 과 같은 통제 대조 lane 이다.
    local a_star = oracle_macro(env, truth)
    pol["oracle"] = Dict("chosen" => a_star, "ranking" => [a_star], "margin" => nothing,
                         "rationale" => "reference action a* (measured grids; see reference_policy.py)",
                         "label" => "oracle", "available" => true)

    # ---- DP 레인 (2026-08-14) -- **스윕 전용**, 라우터·UI 에서 제외 ---------------------------
    # `pol["dp"]` 를 DEMO_POLICY=dp 일 때만 만든다. 그러면 대시보드가 도는 판(router/canonical/…)
    # 에는 이 키가 아예 없어서 화면이 DP 를 그릴 수 없다 — Global Constraint 10 을 구조로 지킨다.
    # (조건을 안 걸고 매번 만들면 "화면에 안 그리기로 했다" 는 규약이 렌더러 쪽 약속으로만 남는다.)
    if POLICY == "dp"
        local dp_m, dp_why = dp_macro(env, truth)
        if isempty(dp_m)
            # 조용한 폴백 금지: 표를 못 읽은 **이유**를 그대로 rationale 에 싣는다. 그래야
            # FINAL.md 가 "커버리지가 낮아서" 와 "동점이라 보류" 를 구분해 셀 수 있다.
            pol["dp"] = Dict("chosen" => canon, "ranking" => [canon], "margin" => nothing,
                             "rationale" => "DP table miss (" * dp_why * ") → canonical rule",
                             "label" => "dp:table-miss→canonical", "available" => true,
                             "dp_miss" => dp_why)
        else
            pol["dp"] = Dict("chosen" => dp_m, "ranking" => [dp_m], "margin" => nothing,
                             "rationale" => "DP backward induction a* (" * dp_why * ")",
                             "label" => "dp", "available" => true, "dp_miss" => nothing)
        end
    end

    rt = route(env, truth)                        # ← 이 사건을 누구에게 보낼지, 시스템이 판정
    desc = get(rt, "descriptors", nothing)

    # oracle 은 canonical/noop 과 마찬가지로 DSPy 서비스 없이도 결정을 내야 한다(a* 는 상태에서
    # 곧바로 나온다). 여기 빠져 있으면 DEMO_ALL_POLICIES=0 인 oracle 판이 사건마다 서비스를 부른다.
    j = (POLICY in ("canonical", "noop", "oracle") && !get(rt, "enabled", false) &&
         get(ENV, "DEMO_ALL_POLICIES", "1") == "0") ?
        nothing : service_decide(env, truth; nl = nl, descriptors = desc)

    # 폴백 라벨은 모델 이름을 박지 않는다 — 실제 라벨은 서비스가 돌려주는 b.policy
    # (DSPY_MODEL 에 따라 "dspy:gpt-4.1" 등)를 그대로 쓴다. 여기 gpt-4o 를 박아두면 다른 모델로
    # 띄웠을 때 UI 가 거짓말을 한다.
    # dict 조립은 `policy_entry`(위) 한 곳에만 있다 — 여기서 다시 쓰면 테스트가 검사하는 것과
    # 실행되는 것이 갈린다(그게 정확히 이 회귀가 검사를 빠져나간 방식이다).
    for (key, label) in (("dspy", "dspy:LLM"), ("surrogate", "surrogate:RandomForest"))
        pol[key] = policy_entry((j !== nothing && haskey(j, Symbol(key))) ? j[Symbol(key)] : nothing,
                                label)
    end

    # ---- 실행할 레인: 3-way 분기표 (2026-08-14, spec §3) --------------------------------------
    # 예전에는 `would = novel ? dspy : surrogate` 뿐이었고(:355 — 그 **판정**은 그대로 둔다,
    # 기존 녹화와의 비교 가능성이 거기 걸려 있다), canonical 은 아래 폴백에서만 등장했다.
    # 즉 canonical 은 **이미 사실상 세 번째 주자인데 판정에는 그 사실이 안 적혔다.**
    # select_lane 이 그 규칙을 명시적으로 적는다(의존성 0 · 전수 단위검사 대상).
    requested = get(rt, "enabled", false) ? String(rt["target"]) : POLICY
    local avail = Dict{String,Bool}(k => (haskey(pol, k) && pol[k]["available"] === true)
                                    for k in ("canonical", "surrogate", "dspy", "noop"))
    # surrogate 가 이 사건의 팔을 학습셋에서 지원하는가 = 기존 에스컬레이션 판정과 **같은 근거**
    # (`escalation_target` 의 `unsupported` 목록). 프로브 대상은 **언제나 surrogate** 다 —
    # `requested` 로 물으면 라우터가 이미 dspy 를 고른 사건에서 "지원됨" 이 나와 분기가 뒤집힌다.
    local _esc_probe, _esc_miss = escalation_target(pol, "surrogate", true)
    local supported = isempty(_esc_miss)

    enacted = requested
    fell_back = false
    # 🔴 `get(rt, "enabled", false)` 였다 (2026-08-27). 그 값은 have_det 을 포함하므로 교정 파일이
    #    없으면 **레인 선택 자체가 안 돌았다** — 축 1 이 select_lane 에 도달조차 못 한다.
    #    레인 선택은 novelty 수치가 없어도 성립한다: 축 1 은 지원집합만 보고, 축 2(임시 novelty)는
    #    `rt["novel"]` 이 없으면 false 로 읽혀 그냥 발화하지 않는다.
    if router_enabled() && POLICY != "noop"
        local sel = select_lane(novel = get(rt, "novel", false) === true, available = avail,
                                supported = supported, policy = POLICY)
        enacted = sel.lane
        # 기존 문구를 **덮어쓰지 않고 덧붙인다** — novelty 수치가 든 줄이 화면에서 사라지면 안 된다.
        rt["reason"] = get(rt, "reason", "") * " · LANE: " * sel.reason
        rt["lane_reason"] = sel.reason
        # 어느 축이 이 판정을 냈는가. 산문에서 역파싱하지 않는다 — 설계서 R5 가 이 값을 센다.
        rt["router_axis"] = sel.axis
        fell_back = (enacted != requested && enacted == "canonical")
    end
    # 고정 정책 실행(라우터 OFF)이거나, 고른 레인이 실제로는 쓸 수 없을 때의 마지막 그물.
    if !(haskey(pol, enacted) && pol[enacted]["available"])
        enacted = "canonical"; fell_back = (requested != "canonical")
    end

    # ---- 에스컬레이션은 **라우팅 기능**이다 (2026-08-06) --------------------------------------
    # 아래 두 블록(행동 표현력 · 관측 표현력)은 지금까지 라우터 설정과 무관하게 항상 돌았다.
    # 그러면 `DEMO_ROUTER=0` 으로 정책을 고정한 비교 실행에서도 사건에 따라 조용히 dspy 로
    # 넘어가고, "surrogate 를 쟀다"고 적은 판이 사실은 LLM 판이 된다 — STATUS §5 가 정책 비교 시
    # 라우터를 끄라고 적은 바로 그 사고다. 그래서 격상은 라우터가 실제로 몰 때만 허용한다.
    # (진단 기록은 아래에서 조건과 무관하게 계속 남는다 — 감사 증거는 언제나 남긴다는 원칙.)
    # ---- 격상 손잡이 (2026-08-27, 설계서 §3) -------------------------------------------------
    # 🔴 예전에는 `get(rt, "enabled", false)` 였다. 그 값은 `have_det && router_enabled() &&
    #    POLICY != "noop"` 이라 **novelty 교정 파일이 있어야만** 어휘 미달 격상이 열렸다.
    #    그런데 "이 팔을 학습한 적이 있는가" 는 교정과 아무 상관이 없는 사실이다. 교정 디렉토리가
    #    없는 동안(= 지금) 어휘 미달은 한 번도 격상할 수 없었다.
    # ⚠️ 원래 그 게이트가 막으려던 것은 실재한다: DEMO_ROUTER=0 으로 정책을 고정한 비교 실행에서
    #    사건에 따라 조용히 dspy 로 넘어가면 "surrogate 를 쟀다"고 적은 판이 LLM 판이 된다.
    #    그래서 그 보호는 **사람이 켠 손잡이**로 보존하고, 교정 유무(have_det)만 뗀다.
    escalation_allowed = router_enabled() && POLICY != "noop"

    # ---- 표현력 에스컬레이션 (2026-08-04) ---------------------------------------------------
    # novelty 라우터는 **상태**가 낯선지만 본다. 그런데 싼 정책이 못 하는 이유가 하나 더 있다:
    # 그 상황의 유효 매크로를 **표현조차 못 할 때**다. 배포 surrogate 는 매크로 0~4 로 학습돼
    # RelocateBuild(7) 행이 한 줄도 없다 → 고를 수가 없고 조용히 NOOP 으로 떨어진다.
    # 실측(2026-08-04, zonecore 데모): 구역이 root 하역 목표 8/8 을 삼켰는데 novelty p=0.205 라
    # "익숙함 → surrogate" 로 갔고, surrogate 는 RelocateBuild 를 못 봐서 NOOP 을 냈다.
    # 상태가 익숙한 것과 행동을 표현할 수 있는 것은 **다른 조건**이므로, 후자가 깨지면 novelty 와
    # 무관하게 LLM 으로 올린다. 이게 "새 행동은 LLM, 익숙한 것은 surrogate" 분담의 정확한 형태다.
    local esc_tgt, esc_missing = escalation_target(pol, requested, escalation_allowed)
    isempty(esc_missing) || (rt["requested_unsupported"] = esc_missing)
    if esc_tgt == "dspy"
        local miss = join(esc_missing, ",")
        rt["escalated_from"] = requested
        rt["escalation_reason"] = "no training support for $(miss)"
        rt["reason"] = get(rt, "reason", "") *
            " · ESCALATED: $(requested) cannot represent [$(miss)] → dspy"
        @info "[router] escalate $(requested) → dspy: 학습 근거 없는 매크로 [$(miss)]"
        enacted = "dspy"
        # canonical 로 **떨어진** 게 아니라 LLM 으로 **올라갔다**. 플래그를 정직하게 되돌린다.
        fell_back = false
    end
    # ---- 어휘 밖 수복 에스컬레이션 (2026-08-05, STEP 7) -------------------------------------
    # 위 블록은 "싼 정책이 그 매크로를 학습한 적이 없다"를 본다. 그 위에 한 겹 더 있다:
    # **닫힌 어휘 자체에 수복이 없는 경우**다. zone_diagnosis 가 :line_stop 을 내면 그 뜻은
    # "위반은 실재하는데(root 하역목표나 형성 중인 팀이 갇힘) ForbidZone 도 RelocateBuild 도
    # 그걸 못 치운다" — 즉 NOOP 밖에 못 고르는데 NOOP 은 답이 아니다. 그 자리가 정확히
    # LLM 에게 **새 수복을 제안**(PROPOSE_NEW)하게 해야 하는 자리다.
    # novelty(상태가 낯선가)도 아니고 액션 학습근거(그 팔을 본 적 있나)도 아닌, 세 번째 조건 =
    # **표현 가능성**이다. 상태는 익숙하고 팔도 학습돼 있는데 어떤 팔도 위반을 못 해소할 수 있다.
    #
    # ★ 진단은 **에스컬레이션이 필요한지와 무관하게** 돌린다(2026-08-05 첫 라이브 런에서 발견):
    #   예전 조건은 `enacted != "dspy"` 를 블록 전체에 걸어 두어서, 라우터가 이미 LLM 으로 보낸
    #   사건에서는 zone_primitives 가 스트림에 **한 줄도 안 남았다**. 그런데 그 값이야말로 "이 구역이
    #   실제로 무엇을 막았나"라는 사후 감사의 유일한 증거다. 기록은 언제나, 격상만 조건부로 한다.
    if truth isa CB.ZoneTruth
        local zdg = try
            CB.zone_diagnosis(env, truth.zone; check_restage = true)
        catch e
            @warn "[router] zone_diagnosis failed -> expressiveness gate skipped" exception = e
            nothing
        end
        local can_escalate = escalation_allowed && enacted != "dspy" &&
                             haskey(pol, "dspy") && pol["dspy"]["available"]
        if zdg !== nothing && zdg.exists
            # 판정 자체는 오라클의 것이라 정책에 주지 않는다. 여기 남기는 것은 **원시값**과
            # "어휘에 수복이 없다"는 사실뿐이다(UI/감사 로그용).
            rt["zone_primitives"] = Dict(
                "n_blocked" => zdg.n_blocked, "n_restage_feasible" => zdg.n_restage_feasible,
                "root_covered" => zdg.root_covered, "root_total" => zdg.root_total,
                "n_teams_forming" => zdg.n_teams_forming, "n_teams_covered" => zdg.n_teams_covered,
                "relocate_feasible" => zdg.relocate_feasible,
                # 막힘(blockage) 원시값 — 위 전부가 coverage 이고 아래만 blockage 다.
                "n_nav_goals" => zdg.n_nav_goals, "n_nav_blocked" => zdg.n_nav_blocked,
                "n_nav_engulfed" => zdg.n_nav_engulfed,
                "n_nav_disconnected" => zdg.n_nav_disconnected,
                "n_agent_trapped" => zdg.n_agent_trapped,
                "n_nav_downstream" => zdg.n_nav_downstream)
            # ---- 관측 표현력 에스컬레이션 (2026-08-05) --------------------------------------
            # 위 블록(액션 표현력)은 "싼 정책이 그 **매크로**를 학습한 적이 없다"를 본다. 여기 있는 것은
            # 그 쌍둥이인 **관측** 표현력이다: 배포 서로게이트는 graded_hs_n44 로 적합되고 그 열 목록에
            # blockage 열이 아예 없다(kind/severity/zone_overlap/progress/… 뿐, features_agnostic 참조).
            # 즉 "이 구역이 항법 목표를 실제로 막고 있다"는 사실을 담을 **칸 자체가 없으므로**, 이 사건에서
            # 서로게이트는 원리적으로 옳을 수 없다. 그런데 novelty 는 상태 서술자 6개만 보고 "익숙하다"고
            # 말한다 — 그게 지금의 오작동이다. 위반이 실재하면(n_nav_blocked>0) novelty 와 무관하게 올린다.
            #
            # :line_stop 조건(아래)과의 차이: 저쪽은 "닫힌 어휘에 수복이 **없다**", 이쪽은 "수복은 있는데
            # 싼 정책이 그 위반을 **볼 수 없다**". 실측상 :line_stop 은 거의 잠들어 있고(작업공간이
            # 무한이라 Δ 가 늘 존재) 실제로 발화하는 것은 이쪽이다.
            if zdg.n_nav_blocked > 0 && can_escalate
                rt["escalated_from"] = enacted
                rt["escalation_reason"] =
                    "zone blocks $(zdg.n_nav_blocked)/$(zdg.n_nav_goals) navigable goals " *
                    "(engulfed $(zdg.n_nav_engulfed), unreachable $(zdg.n_nav_disconnected)); " *
                    "the surrogate's feature vector has no column for blockage"
                rt["reason"] = get(rt, "reason", "") *
                    " · ESCALATED: zone actually blocks $(zdg.n_nav_blocked) navigable goal(s) → dspy"
                @info "[router] escalate $(enacted) → dspy: 이 구역이 항법 목표 $(zdg.n_nav_blocked)개를 실제로 막는다"
                enacted = "dspy"
            elseif zdg.verdict === :line_stop && can_escalate
                rt["escalated_from"] = enacted
                rt["escalation_reason"] = "closed vocabulary has no repair for this zone " *
                    "(root $(zdg.root_covered)/$(zdg.root_total) trapped, " *
                    "$(zdg.n_teams_covered) team(s) trapped, no clearing translation)"
                rt["reason"] = get(rt, "reason", "") *
                    " · ESCALATED: no DSL action clears this zone → dspy (propose new)"
                @info "[router] escalate $(enacted) → dspy: 닫힌 어휘에 이 구역의 수복이 없다(:line_stop)"
                enacted = "dspy"
            end
        end
    end

    rt["enacted"] = enacted
    rt["fell_back"] = fell_back
    chosen = pol[enacted]["chosen"]

    # 이 판에서 몇 번째 결정인가. deviation 이 꺼져 있어도 센다 — 행에 남겨 두면
    # 나중에 "왜 그 칸에 표본이 없나" 를 로그만으로 답할 수 있다.
    didx = _next_decision_index!()
    rt["decision_index"] = didx

    # 통제 실험(FORCE_MACRO): 정책의 결정은 그대로 기록하고 집행만 덮어쓴다.
    forced = !isempty(FORCE_MACRO) && FORCE_MACRO != chosen
    if forced
        rt["forced_macro"] = FORCE_MACRO
        rt["forced_from"] = chosen
        @info "[policy] FORCED enactment $(chosen) → $(FORCE_MACRO) (DEMO_FORCE_MACRO, 통제 실험)"
        chosen = String(FORCE_MACRO)
    end

    # 1-step deviation: k 번째 결정에서만 갈아쓴다.
    dev = should_deviate(DEVIATE_AT, DEVIATE_ARM, didx)
    if dev !== nothing
        # 게이트가 이 인덱스에 걸렸다는 사실은 **팔이 바뀌었는지와 무관하게** 남긴다.
        # 안 남기면 "k 가 결정 수보다 커서 한 번도 안 걸린 판" 과 "걸렸는데 canonical 이 이미
        # 그 팔이었던 판" 이 로그에서 구분되지 않고, 둘 다 그 팔의 표본으로 잘못 라벨된다.
        rt["deviate_at"] = didx
        rt["deviate_arm"] = dev
        rt["deviated"] = (dev != chosen)
        rt["deviate_from"] = chosen
        # 이 사건에 그 팔이 **메뉴에 있는지**를 같이 남긴다. `valid_macros` 는 빈 배열로
        # "메뉴 없음(=서비스의 kind 기본표를 쓰라)"을 뜻한다 — `String[]` 을 "아무것도 유효하지
        # 않다"로 읽으면 안 된다. 그 규약은 `:413`(`isempty(vm) || (payload["valid"] = vm)`)과
        # `:460`(`(isempty(vm) || m in vm) && return m`)이 이미 쓰고 있다. FaultTruth·ReformTruth
        # 는 `valid_macros` 가 항상 `String[]` 을 돌려주므로(전용 메뉴가 없다는 뜻), 여기서
        # `isempty` 를 "유효" 로 안 세면 그 두 축의 deviation 이 무조건 invalid 로 찍힌다.
        # ⚠️ 이 키는 "메뉴 안에 있는가" 만 답한다 — "집행 사슬이 실제로 뭔가 했는가" 는 다른
        # 질문이고 `run_demo.jl` 의 `enact_applied` 가 그 진실원이다(메뉴가 비어 valid=true 인데
        # 사슬은 truth 타입 가드로 무동작일 수 있다, 예: fault 사건에 ForbidZone).
        local _vm = try valid_macros(env, truth) catch; String[] end
        rt["deviate_valid"] = isempty(_vm) || dev in _vm
        rt["deviate_valid"] ||
            @warn "[policy] DEVIATE #$(didx): $(dev) 는 이 사건($(typeof(truth).name.name))의 " *
                  "메뉴 $(_vm) 밖이다 — 정책이 애초에 고를 수 없는 팔로 갈아 끼웠다"
        if dev != chosen
            @info "[policy] DEVIATE #$(didx): $(chosen) → $(dev) (DS_DEVIATE_AT, 1-step)"
            chosen = dev
        else
            @info "[policy] DEVIATE #$(didx): 이미 $(chosen) — 집행 무변경 (DS_DEVIATE_AT, 1-step)"
        end
    end

    # 서비스가 돌려준 "각 producer 가 실제로 본 것" -- UI 가 나란히 보여줄 두 입력.
    if j !== nothing
        rt["llm_input"] = String(get(j, :llm_input, ""))
        rt["surrogate_input"] = String(get(j, :surrogate_input, ""))
        rt["llm_input_mode"] = String(get(j, :llm_input_mode, "parsed-fields"))
    end

    # 후보표: 실행 정책의 순위를 쓰되, 각 매크로를 어느 정책이 골랐는지 표시한다.
    ranking = pol[enacted]["ranking"]
    for m in [pol[k]["chosen"] for k in ("canonical", "surrogate", "dspy") if pol[k]["available"]]
        (isempty(m) || m in ranking) || push!(ranking, m)
    end
    (forced && !(chosen in ranking)) && push!(ranking, chosen)   # 강제 집행 매크로도 표에 보이게
    (get(rt, "deviated", false) && !(chosen in ranking)) && push!(ranking, chosen)   # deviate 로 갈아 쓴 매크로도 표에 보이게
    cands = [Dict("rank" => i, "macro" => m,
                  "score" => (i == 1 && pol[enacted]["margin"] !== nothing ?
                              "margin $(round(pol[enacted]["margin"]; digits = 2))" : ""),
                  "chosen" => (m == chosen),
                  "rule"   => (m == pol["canonical"]["chosen"]),
                  "by"     => join([k for k in ("canonical", "surrogate", "dspy")
                                    if pol[k]["available"] && pol[k]["chosen"] == m], "+"),
                  "verified" => (m == chosen))
             for (i, m) in enumerate(ranking)]

    others = [k for k in ("canonical", "surrogate", "dspy")
              if k != enacted && pol[k]["available"] && pol[k]["chosen"] != chosen]
    routed = get(rt, "enabled", false) ?
             # 표현력 에스컬레이션이 일어났으면 그 사실을 **먼저** 말한다. novelty 판정만 적으면
             # "familiar → surrogate" 로 보이는데 실제로 실행된 것은 dspy 라 UI 가 거짓말을 한다.
             (haskey(rt, "escalated_from") ?
                "ROUTED→$(rt["escalated_from"]) (familiar) → ESCALATED→LLM ($(rt["escalation_reason"])) · " :
              rt["novel"] ? "ROUTED→LLM (novel) · " : "ROUTED→surrogate (familiar) · ") : ""
    verdict = routed * "ADMITTED · $(pol[enacted]["label"])" *
              # 폴백 사유를 같이 적는다: "requested surrogate unavailable" 만으로는 **왜**
              # 못 썼는지가 안 남아, 나중에 이 줄을 읽는 사람이 로그를 다시 파야 한다.
              (fell_back ? " (requested $(requested) unavailable" *
                           (haskey(pol, requested) && !isempty(get(pol[requested], "rationale", "")) ?
                            ": $(pol[requested]["rationale"])" : "") * ")" : "") *
              (forced ? " · FORCED→$(FORCE_MACRO) (control run; policy chose $(rt["forced_from"]))" : "") *
              (get(rt, "deviated", false) ? " · DEVIATE→$(rt["deviate_arm"]) (1-step; policy chose $(rt["deviate_from"]))" : "") *
              (isempty(others) ? " · all policies agree" :
               " · DIFFERS from " * join(["$(k)=$(pol[k]["chosen"])" for k in others], ", "))

    # ---- 자연어 서술 (2026-08-14, spec §4.1) --------------------------------------------------
    # 결정적 템플릿이다(LLM 호출 없음). 여기서 **찍어 넣는** 이유: 대시보드는 스트림을 그대로
    # 재생하므로, 화면(JS)에서 문장을 조립하면 단위검사 대상이 되지 않는다. 키 이름은 narrate.jl
    # 이 읽는 것과 정확히 같아야 한다.
    local _f = try ood_features(env, truth) catch; Dict{String,Any}() end
    local narrative = try
        narrate_event(Dict{String,Any}(
            "kind"          => get(_f, "kind", string(typeof(truth).name.name)),
            "severity"      => get(_f, "severity", nothing),
            "soc"           => get(_f, "soc", nothing),
            "spare_count"   => get(_f, "spare_count", nothing),
            "agent_pending" => get(_f, "agent_pending", nothing),
            "progress"      => get(_f, "progress", nothing),
            "enacted"       => enacted,
            "macro_name"    => chosen,
            "fell_back"     => fell_back,
            "requested"     => requested,
            "policies"      => pol))
    catch e
        # 서술이 실패해도 결정은 계속한다. 다만 **빈 문자열로 조용히 덮지 않는다** — 화면이
        # "서술 없음" 과 "서술기가 죽었음" 을 구분할 수 있어야 한다.
        @warn "[narrate] narrate_event failed" exception = e
        ""
    end

    return (macro_name = chosen, candidates = cands, policies = pol, enacted = enacted,
            policy = pol[enacted]["label"], rule_macro = pol["canonical"]["chosen"],
            llm_macro = pol["dspy"]["chosen"], verdict = verdict, router = rt,
            narrative = narrative,
            detail = pol[enacted]["rationale"], agree = isempty(others))
end



# ---- 고른 매크로 → DSL 제안(RespecProposal). 프레임워크 dispatcher 가 검증·실행한다. ----
# NOOP 은 "제약 없음"이 정답이므로 빈 제안을 돌려준다(= 개입하지 않음).
function macro_to_proposal(truth, macro_name::AbstractString; env = nothing)
    rationale = "policy=$(POLICY) chose $(macro_name)"
    src = string(typeof(truth).name.name)
    if macro_name == "Replace" && hasproperty(truth, :robot)
        return CB.RespecProposal(CB.ConstraintSpec[CB.ReplaceAgent(truth.robot, 0.0)], rationale, src)
    elseif macro_name == "SwapBattery" && hasproperty(truth, :robot)
        # 2026-08-06: 이 분기가 없으면 정책이 SwapBattery 를 골라도 아래 빈 제안으로 떨어져
        # **조용히 NOOP 이 실행된다** — RelocateBuild 에서 한 번 겪은 것과 똑같은 실패 양식이다.
        return CB.RespecProposal(CB.ConstraintSpec[CB.SwapBattery(truth.robot)], rationale, src)
    # 🔴 2026-08-24 (spec §5.4, Task 5): 여기 있던 `Deprioritize` 분기(→ `CB.DeprioritizeAgent`)
    # 를 지웠다. 그 kind 가 DSL 에서 삭제됐고 `valid_macros` 의 배터리 메뉴에서도 빠졌다.
    # 🔴 2026-08-24 (spec §5.1, Task 4): 여기 있던 `ForbidZone` · `RelocateBuild` 두 분기를
    # 지웠다. zone 은 LLM 결정 레인에서 빠졌고 `valid_macros` 가 zone 메뉴를 더는 안 내므로
    # 그 이름이 여기 도달할 경로가 없다. (Julia 타입 `CB.ForbidZone`/`CB.RelocateBuild` 는
    # 시뮬레이터 쪽에 그대로 살아 있다 — 어휘에서만 빠졌다.)
    elseif macro_name == "ReformTeam"
        return CB.RespecProposal(CB.ConstraintSpec[CB.ReformTeam()], rationale, src)
    end
    return CB.RespecProposal(CB.ConstraintSpec[], rationale, src)   # NOOP / 적용 불가
end

# ---- 세 정책의 결정을 monitor respec 레코드로 기록(두 엔진 공용) ----
function record_decision!(env, truth, decision, nl)
    tgt = try
        truth isa CB.ZoneTruth ? string(truth.assembly) :
        hasproperty(truth, :robot) ? _rl(truth.robot) : ""
    catch; "" end
    kind = truth isa CB.FaultTruth ? "FAULT" : truth isa CB.BatteryTruth ? "BATTERY" :
           truth isa CB.ZoneTruth ? "ZONE" : "OOD"
    (truth isa CB.FaultTruth) && try CB.monitor_record_fault!(truth.robot) catch end
    try
        CB.monitor_record_respec!(; at = length(env.cache.closed_set),
            input = Dict("event" => kind, "target" => tgt,
                         "detail" => first(split(String(nl), "
")),
                         # nl = 관찰 **전문**. detail 은 첫 줄만이라 UI 가 문장을 온전히 못 보여줬다.
                         # 이게 LLM 이 실제로 읽는 채널이므로 화면에도 원문 그대로 있어야 한다.
                         "nl" => String(nl),
                         "policy" => decision.policy,
                         "rule_macro" => decision.rule_macro,
                         "llm_macro"  => decision.llm_macro,
                         "policies"   => decision.policies,
                         "enacted"    => decision.enacted,
                         # router = 이 사건을 왜 그쪽으로 보냈는지(p, eps, 판정, 각 producer 의 입력).
                         "router"     => (hasproperty(decision, :router) ? decision.router : nothing),
                         # 자연어 해석(spec §4.1). 결정 시점에 **찍어 넣는다** — 화면(JS)에서
                         # 조립하면 단위검사 대상이 되지 않고, 파이썬 후처리로 만들면 라이브
                         # 화면에 안 뜬다. 재스윕 이전 녹화에는 이 키가 없다(화면이 자리를 비운다).
                         "narrative"  => (hasproperty(decision, :narrative) ? decision.narrative : nothing),
                         "rationale" => decision.detail,
                         "agrees_with_rule" => decision.agree),
            candidates = decision.candidates,
            chosen = strip("$(decision.macro_name) $(tgt)"), verdict = decision.verdict)
    catch e
        @warn "record_decision! failed" exception = e
    end
end
