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
    else
        d["severity"] = 1.0
    end
    return d
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
    drives = have_det && router_enabled()
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
    descriptors === nothing || (payload["descriptors"] = collect(Float64, descriptors))
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

"canonical 규칙이 고른 매크로 이름."
function canonical_macro(truth)
    prop = try CB.canonical_respec(truth) catch; nothing end
    (prop === nothing || isempty(prop.constraints)) ? "NOOP" :
        string(typeof(prop.constraints[1]).name.name)
end

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
    canon = _macro_label(canonical_macro(truth))
    pol = Dict{String,Any}()
    pol["canonical"] = Dict("chosen" => canon, "ranking" => [canon],
                            "margin" => nothing, "rationale" => "rule lookup (severity threshold)",
                            "label" => "canonical", "available" => true)

    rt = route(env, truth)                        # ← 이 사건을 누구에게 보낼지, 시스템이 판정
    desc = get(rt, "descriptors", nothing)

    j = (POLICY == "canonical" && !get(rt, "enabled", false) &&
         get(ENV, "DEMO_ALL_POLICIES", "1") == "0") ?
        nothing : service_decide(env, truth; nl = nl, descriptors = desc)

    for (key, label) in (("dspy", "dspy:gpt-4o"), ("surrogate", "surrogate:RandomForest"))
        if j !== nothing && haskey(j, Symbol(key))
            local b = j[Symbol(key)]
            local err = get(b, :error, nothing)
            if err === nothing && !isempty(String(get(b, :chosen, "")))
                pol[key] = Dict("chosen" => String(b.chosen),
                                "ranking" => String.(collect(get(b, :ranking, String[]))),
                                "margin" => (try Float64(b.margin) catch; nothing end),
                                "rationale" => String(get(b, :rationale, "")),
                                "scores" => get(b, :scores, nothing),
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
    rt["enacted"] = enacted
    rt["fell_back"] = fell_back
    chosen = pol[enacted]["chosen"]

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
             (rt["novel"] ? "ROUTED→LLM (novel) · " : "ROUTED→surrogate (familiar) · ") : ""
    verdict = routed * "ADMITTED · $(pol[enacted]["label"])" *
              (fell_back ? " (requested $(requested) unavailable)" : "") *
              (isempty(others) ? " · all policies agree" :
               " · DIFFERS from " * join(["$(k)=$(pol[k]["chosen"])" for k in others], ", "))

    return (macro_name = chosen, candidates = cands, policies = pol, enacted = enacted,
            policy = pol[enacted]["label"], rule_macro = pol["canonical"]["chosen"],
            llm_macro = pol["dspy"]["chosen"], verdict = verdict, router = rt,
            detail = pol[enacted]["rationale"], agree = isempty(others))
end



# ---- 고른 매크로 → DSL 제안(RespecProposal). 프레임워크 dispatcher 가 검증·실행한다. ----
# NOOP 은 "제약 없음"이 정답이므로 빈 제안을 돌려준다(= 개입하지 않음).
function macro_to_proposal(truth, macro_name::AbstractString)
    rationale = "policy=$(POLICY) chose $(macro_name)"
    src = string(typeof(truth).name.name)
    if macro_name == "Replace" && hasproperty(truth, :robot)
        return CB.RespecProposal(CB.ConstraintSpec[CB.ReplaceAgent(truth.robot, 0.0)], rationale, src)
    elseif macro_name == "Deprioritize" && hasproperty(truth, :robot)
        return CB.RespecProposal(CB.ConstraintSpec[CB.DeprioritizeAgent(truth.robot)], rationale, src)
    elseif macro_name == "ForbidZone" && truth isa CB.ZoneTruth && truth.assembly !== nothing
        return CB.RespecProposal(CB.ConstraintSpec[CB.ForbidZone(truth.assembly, truth.zone)], rationale, src)
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
                         "rationale" => decision.detail,
                         "agrees_with_rule" => decision.agree),
            candidates = decision.candidates,
            chosen = strip("$(decision.macro_name) $(tgt)"), verdict = decision.verdict)
    catch e
        @warn "record_decision! failed" exception = e
    end
end
