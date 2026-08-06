# tools/monitor/policy.jl
# =============================================================================
# **결정 정책 레이어(공용)** — run_demo.jl(수동 루프)과 render_demo.jl(애니메이션 렌더)이
# 똑같은 결정을 내리도록 한 곳에 모은 파일. 여기만 고치면 두 엔진이 함께 바뀐다.
#
#   canonical : CB.canonical_respec 규칙 lookup (줄리아 내부)
#   surrogate : 배포 RandomForest      ┐ 파이썬 서비스 POST /decide 로 한 번에 받음
#   dspy      : MIPROv2 컴파일 gpt-4o  ┘
#
# 매 OOD 사건마다 **셋을 모두 계산해 기록**하고(UI 가 전환해 볼 수 있게), 실제로 실행되는 것은
# DEMO_POLICY 하나뿐이다. 서비스가 없으면 canonical 로 폴백하고 그 사실을 verdict 에 남긴다.
#
# ENV: DEMO_POLICY(canonical|surrogate|dspy) · DSPY_URL · DEMO_ALL_POLICIES(0 이면 비교값 수집 생략)
# =============================================================================
import HTTP, JSON3

const POLICY   = lowercase(get(ENV, "DEMO_POLICY", "canonical"))
const DSPY_URL = rstrip(get(ENV, "DSPY_URL", "http://127.0.0.1:8077"), '/')

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
#   NOVELTY_CALIB  교정 JSON 경로(기본: wm4spacecraft_manufacturing/novelty_calibration.json)
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
    path = get(ENV, "NOVELTY_CALIB",
               joinpath(@__DIR__, "..", "..", "wm4spacecraft_manufacturing",   # tools/monitor -> repo 루트
                        "novelty_calibration.json"))
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
                python export_novelty_calibration.py

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
    elseif truth isa CB.ReformTruth
        # 2026-08-04 버그 수정: 여기가 없어서 팀 교착 사건이 아래 else 로 떨어져 **"fault"** 로
        # 서비스에 전달됐다. 그러면 valid 가 [NOOP,Replace,Deprioritize] 가 되어 정책이
        # ReformTeam 을 아예 고를 수 없고, 실측에서 Deprioritize 를 골라 아무 복구도 안 됐다.
        ("reform", nothing)
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
    if truth isa CB.BatteryTruth
        local have_fleet = (try CB.BATTERY_FLEET[] !== nothing catch; false end)
        return have_fleet ? ["NOOP", "Replace", "Deprioritize", "SwapBattery"] :
                            ["NOOP", "Replace", "Deprioritize"]
    end
    truth isa CB.ZoneTruth || return String[]          # 그 외 종류는 서비스 기본표 그대로
    # 대상 조립체를 지목한 구역 = 국소 재적치가 말이 되는 사건.
    named = try truth.assembly !== nothing catch; false end
    # 2026-08-05(STEP 7): 지목이 없어도 **기하가 대상을 알고 있으면** ForbidZone 은 legal 이다.
    # 옛 판정("지목 없으면 grounding 할 대상이 없다")은 틀렸다 — proposal_for_macro 가 이미
    # zone_blocked_assemblies 에서 대상을 채워 넣는다(아래 그 분기 참조). 그래서 지목 유무로 팔을
    # 지우면, 대상이 실재하는데도 메뉴에서 빠져 정책이 **고를 수조차 없는** 상태가 된다. 그게
    # 이 파일이 고치고 있는 "표현력" 실패의 또 다른 얼굴이다. 진단기와 같은 계산을 쓴다.
    # (도메인이 비었다고 팔을 **지우지는** 않는다 — 그건 2026-08-05 에 실측으로 접었다. 위 주석 참조.)
    domain = try
        CB.zone_diagnosis(env, truth.zone; check_restage = true).n_restage_feasible
    catch e
        @warn "[policy] zone_diagnosis failed -> ForbidZone 메뉴는 지목 여부로만 판단" exception = e
        0
    end
    return (named || domain > 0) ? ["NOOP", "ForbidZone", "RelocateBuild"] :
                                   ["NOOP", "RelocateBuild"]
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
    if !have_det
        return Dict{String,Any}("enabled" => false, "advisory" => false, "target" => POLICY,
                                "novel" => false, "p" => nothing, "score" => nothing,
                                "eps" => nothing,
                                "reason" => "no novelty calibration installed -> gate inactive " *
                                            "(DEMO_POLICY=$(POLICY) fixed for the run)")
    end
    desc = try event_descriptors_of(env, truth) catch e
        @warn "descriptor computation failed -> router falls back" exception = e
        nothing
    end
    desc === nothing && return Dict{String,Any}("enabled" => false, "advisory" => false,
        "target" => POLICY, "novel" => false, "p" => nothing, "score" => nothing,
        "eps" => nothing, "reason" => "descriptors unavailable")
    v = CB.novelty_verdict(desc; eps = ROUTER_EPS)
    eps = ROUTER_EPS === nothing ? (try CB.novelty_detector().alpha catch; 0.05 end) : ROUTER_EPS
    would = v.novel ? "dspy" : "surrogate"
    base = v.novel ?
        "novelty p=$(round(v.p; digits=3)) < eps=$(round(eps; digits=3)) — NEVER SEEN THIS BEFORE → ask the LLM" :
        "novelty p=$(round(v.p; digits=3)) ≥ eps=$(round(eps; digits=3)) — familiar → surrogate (0.11 ms)"
    return Dict{String,Any}(
        "enabled"  => drives,                     # 실행을 정하는가
        "advisory" => !drives,                    # 참고용으로만 기록된 판정인가
        "target"   => drives ? would : POLICY,    # 실제로 실행될 정책
        "would_route_to" => would,                # 라우터라면 골랐을 정책
        "novel"    => v.novel,
        "p"        => (isfinite(v.p) ? v.p : nothing),
        "score"    => (isfinite(v.score) ? v.score : nothing),
        "eps"      => eps,
        "descriptors" => desc,
        # reason 은 대시보드 ROUTER 줄에 그대로 표시되므로 영어로 쓴다(화면 문구는 전부 영어).
        "reason"   => drives ? base :
            base * "  (advisory only — this recording enacted DEMO_POLICY=$(POLICY), fixed)")
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

# ---- 통제 실험용 강제 매크로 -----------------------------------------------------------
# DEMO_FORCE_MACRO=<이름> 이면 **어느 정책이 실행되든** 그 매크로를 집행한다.
# 용도는 하나뿐이다: "결과가 갈린 이유가 매크로인가 정책인가"를 가르는 교차 대조
# (같은 매크로를 다른 정책이 내게 해서 세계가 같은지 본다). 강제 사실은 verdict 에 남긴다 —
# 기록이 "canonical 이 RelocateBuild 를 골랐다"로 읽히면 그게 곧 거짓말이 되기 때문.
const FORCE_MACRO = strip(get(ENV, "DEMO_FORCE_MACRO", ""))

# ConstraintSpec 타입 이름 → 매크로 이름 정규화(ReplaceAgent → Replace 등).
_macro_label(s) = s == "ReplaceAgent" ? "Replace" :
                  s == "DeprioritizeAgent" ? "Deprioritize" :
                  s == "ForbidZone" ? "ForbidZone" :
                  s == "ReformTeam" ? "ReformTeam" : s

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

    rt = route(env, truth)                        # ← 이 사건을 누구에게 보낼지, 시스템이 판정
    desc = get(rt, "descriptors", nothing)

    j = (POLICY in ("canonical", "noop") && !get(rt, "enabled", false) &&
         get(ENV, "DEMO_ALL_POLICIES", "1") == "0") ?
        nothing : service_decide(env, truth; nl = nl, descriptors = desc)

    # 폴백 라벨은 모델 이름을 박지 않는다 — 실제 라벨은 서비스가 돌려주는 b.policy
    # (DSPY_MODEL 에 따라 "dspy:gpt-4.1" 등)를 그대로 쓴다. 여기 gpt-4o 를 박아두면 다른 모델로
    # 띄웠을 때 UI 가 거짓말을 한다.
    for (key, label) in (("dspy", "dspy:LLM"), ("surrogate", "surrogate:RandomForest"))
        if j !== nothing && haskey(j, Symbol(key))
            local b = j[Symbol(key)]
            local err = get(b, :error, nothing)
            if err === nothing && !isempty(String(get(b, :chosen, "")))
                pol[key] = Dict("chosen" => String(b.chosen),
                                "ranking" => String.(collect(get(b, :ranking, String[]))),
                                "margin" => (try Float64(b.margin) catch; nothing end),
                                "rationale" => String(get(b, :rationale, "")),
                                "scores" => get(b, :scores, nothing),
                                # 이 정책이 **아예 고를 수 없었던** 유효 매크로들(학습 근거 0).
                                # "NOOP 을 골랐다"와 "새 행동을 못 본다"는 전혀 다른 사건이다.
                                "unsupported" => String.(collect(get(b, :unsupported, String[]))),
                                "label" => String(get(b, :policy, label)), "available" => true)
                continue
            end
        end
        pol[key] = Dict("chosen" => "", "ranking" => String[], "margin" => nothing,
                        "rationale" => "", "label" => label, "available" => false)
    end

    # 실행할 정책: 라우터가 켜져 있으면 라우터가, 아니면 DEMO_POLICY. 쓸 수 없으면 canonical 폴백.
    requested = get(rt, "enabled", false) ? String(rt["target"]) : POLICY
    enacted = requested
    fell_back = false
    if !(haskey(pol, enacted) && pol[enacted]["available"])
        enacted = "canonical"; fell_back = (requested != "canonical")
    end

    # ---- 에스컬레이션은 **라우팅 기능**이다 (2026-08-06) --------------------------------------
    # 아래 두 블록(행동 표현력 · 관측 표현력)은 지금까지 라우터 설정과 무관하게 항상 돌았다.
    # 그러면 `DEMO_ROUTER=0` 으로 정책을 고정한 비교 실행에서도 사건에 따라 조용히 dspy 로
    # 넘어가고, "surrogate 를 쟀다"고 적은 판이 사실은 LLM 판이 된다 — STATUS §5 가 정책 비교 시
    # 라우터를 끄라고 적은 바로 그 사고다. 그래서 격상은 라우터가 실제로 몰 때만 허용한다.
    # (진단 기록은 아래에서 조건과 무관하게 계속 남는다 — 감사 증거는 언제나 남긴다는 원칙.)
    escalation_allowed = get(rt, "enabled", false)

    # ---- 표현력 에스컬레이션 (2026-08-04) ---------------------------------------------------
    # novelty 라우터는 **상태**가 낯선지만 본다. 그런데 싼 정책이 못 하는 이유가 하나 더 있다:
    # 그 상황의 유효 매크로를 **표현조차 못 할 때**다. 배포 surrogate 는 매크로 0~4 로 학습돼
    # RelocateBuild(7) 행이 한 줄도 없다 → 고를 수가 없고 조용히 NOOP 으로 떨어진다.
    # 실측(2026-08-04, zonecore 데모): 구역이 root 하역 목표 8/8 을 삼켰는데 novelty p=0.205 라
    # "익숙함 → surrogate" 로 갔고, surrogate 는 RelocateBuild 를 못 봐서 NOOP 을 냈다.
    # 상태가 익숙한 것과 행동을 표현할 수 있는 것은 **다른 조건**이므로, 후자가 깨지면 novelty 와
    # 무관하게 LLM 으로 올린다. 이게 "새 행동은 LLM, 익숙한 것은 surrogate" 분담의 정확한 형태다.
    if escalation_allowed && enacted != "dspy" && haskey(pol, enacted) && pol[enacted]["available"] &&
       !isempty(get(pol[enacted], "unsupported", String[])) &&
       haskey(pol, "dspy") && pol["dspy"]["available"]
        local miss = join(get(pol[enacted], "unsupported", String[]), ",")
        rt["escalated_from"] = enacted
        rt["escalation_reason"] = "no training support for $(miss)"
        rt["reason"] = get(rt, "reason", "") *
            " · ESCALATED: $(enacted) cannot represent [$(miss)] → dspy"
        @info "[router] escalate $(enacted) → dspy: 학습 근거 없는 매크로 [$(miss)]"
        enacted = "dspy"
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
    # 통제 실험(FORCE_MACRO): 정책의 결정은 그대로 기록하고 집행만 덮어쓴다.
    forced = !isempty(FORCE_MACRO) && FORCE_MACRO != chosen
    if forced
        rt["forced_macro"] = FORCE_MACRO
        rt["forced_from"] = chosen
        @info "[policy] FORCED enactment $(chosen) → $(FORCE_MACRO) (DEMO_FORCE_MACRO, 통제 실험)"
        chosen = String(FORCE_MACRO)
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
              (fell_back ? " (requested $(requested) unavailable)" : "") *
              (forced ? " · FORCED→$(FORCE_MACRO) (control run; policy chose $(rt["forced_from"]))" : "") *
              (isempty(others) ? " · all policies agree" :
               " · DIFFERS from " * join(["$(k)=$(pol[k]["chosen"])" for k in others], ", "))

    return (macro_name = chosen, candidates = cands, policies = pol, enacted = enacted,
            policy = pol[enacted]["label"], rule_macro = pol["canonical"]["chosen"],
            llm_macro = pol["dspy"]["chosen"], verdict = verdict, router = rt,
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
    elseif macro_name == "Deprioritize" && hasproperty(truth, :robot)
        return CB.RespecProposal(CB.ConstraintSpec[CB.DeprioritizeAgent(truth.robot)], rationale, src)
    elseif macro_name == "ForbidZone" && truth isa CB.ZoneTruth
        # 지목할 조립체: truth 가 들고 있으면 그것, 없으면 지금 그 구역에 막힌 것 중 하나.
        # dispatch 는 어차피 막힌 것 **전부**를 기하로 찾아 옮기지만(restage_all_blocked!),
        # DSL 제약은 대상 id 를 하나 요구한다. 여기서 nothing 이면 빈 제안 = 조용한 NOOP 이 되므로
        # (그 침묵이 바로 이 파일이 고치고 있는 실패 양식이다) 반드시 채워서 내보낸다.
        local aid = truth.assembly
        if aid === nothing && env !== nothing
            local blocked = try CB.zone_blocked_assemblies(env) catch; [] end
            isempty(blocked) || (aid = first(blocked))
        end
        aid === nothing ||
            return CB.RespecProposal(CB.ConstraintSpec[CB.ForbidZone(aid, truth.zone)], rationale, src)
    elseif macro_name == "RelocateBuild" && truth isa CB.ZoneTruth
        # 2026-08-04: zone 사건의 기본 개입 팔. ForbidZone 과 달리 assembly 를 안 지목하므로
        # truth.assembly 가 nothing(중앙 core zone)이어도 성립한다 — 이 분기가 없으면 LLM 이
        # RelocateBuild 를 골라도 아래 빈 제안으로 떨어져 **조용히 NOOP 이 실행된다**.
        return CB.RespecProposal(CB.ConstraintSpec[CB.RelocateBuild(truth.zone)], rationale, src)
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
           truth isa CB.ZoneTruth ? "ZONE" : truth isa CB.ReformTruth ? "REFORM" : "OOD"
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
                         "rationale" => decision.detail,
                         "agrees_with_rule" => decision.agree),
            candidates = decision.candidates,
            chosen = strip("$(decision.macro_name) $(tgt)"), verdict = decision.verdict)
    catch e
        @warn "record_decision! failed" exception = e
    end
end
