# tools/monitor/run_demo.jl
# =============================================================================
# 파라미터화된 OOD 데모 엔진 — MODEL × OOD_CASE 를 골라 자율 multi-robot assembly 를
# 돌리며 monitor 스트림(JSONL)을 만든다.
#
#   env = run_lego_demo(return_env_before_sim=true)  로 완성된 env 만 받고,
#   run_simulation! 대신 **수동 루프**를 직접 돌린다(프레임워크 respec-큐 라우팅 우회):
#     매 스텝:  ood_inject_step!  → 새 OOD truth 감지 → **결정 정책**이 매크로 선택 → 캡처
#               → 고른 매크로대로 복구(Replace=hot-swap / Deprioritize=rebalance·강등 / ForbidZone=restage / NOOP=무동작)
#               → step_environment! → update_planning_cache! → (주기적) monitor_emit!
#
# 결정 정책(DEMO_POLICY):
#   canonical (기본) — 규칙 lookup(`CB.canonical_respec`). 종전 동작과 완전히 동일.
#   dspy             — 별도 파이썬 서비스(src/respec/llm_service/dspy_service.py)의 DSPy producer.
#                      실제 gpt-4o 호출이며, 오프라인 벤치마크한 MIPROv2 컴파일 프로그램을 그대로 쓴다.
#                      서비스가 죽어 있거나 응답이 이상하면 canonical 로 폴백하고, 그 사실을
#                      스트림 verdict 에 남긴다(=UI 가 규칙 결과를 LLM 결과로 오인하지 않게).
#
# ENV:
#   DEMO_MODEL   LDraw 파일명 (기본 tractor.mpd)
#   DEMO_OOD     none|battery|fault|zone|fault_battery|fault_zone|battery_zone (기본 fault)
#   DEMO_ROBOTS  로봇 수 (기본 10)
#   DEMO_POLICY  canonical|dspy (기본 canonical)
#   DEMO_BSOC    battery OOD 의 SoC 낙폭 (기본 0.9=심각). 낮추면 애매한 구간이 되어 두 정책이 갈린다.
#   DSPY_URL     DSPy producer 주소 (기본 http://127.0.0.1:8077)
#   MONITOR_STREAM  출력 경로 (미지정 시 streams/<model>__<case>.jsonl)
#   DEMO_SEED    **world** = 로봇 초기 배치 (기본 1). 같은 공장/같은 제품이면 고정해서 쓴다.
#   DEMO_OOD_SEED  **확률성** = 언제·어떤 OOD 가·얼마나 심하게 (0=기본, 고정 슬롯 배치 = 예전 동작)
#   DEMO_OOD_LO/HI/SEVFRAC  무작위 스트림의 진행도 구간과 깊은방전 비율 (기본 0.10/0.75/0.5)
#   DEMO_SUMMARY  결과 한 줄 JSONL 을 덧붙일 경로 (스위프 하니스용, 미지정 시 안 씀)
# 실행: julia +lts --project=. tools/monitor/run_demo.jl
# =============================================================================
using ConstructionBots
using Random
import Graphs
import HTTP, JSON3                                    # DSPy producer 와 통신하는 HTTP 클라이언트
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))   # battery/ood_stream/ood_truth/baselines

const HERE   = @__DIR__
const MODEL  = get(ENV, "DEMO_MODEL", "tractor.mpd")
const OODC   = lowercase(get(ENV, "DEMO_OOD", "fault"))
const DEMO_N = try max(0, parse(Int, get(ENV, "DEMO_N", "0"))) catch; 0 end   # # OOD events (0=case default)
# battery OOD 의 severity 손잡이(떨어뜨릴 SoC 양). 0.9=심각(교체가 정답), 0.45 정도면 애매한 구간.
const DEMO_BSOC = try clamp(parse(Float64, get(ENV, "DEMO_BSOC", "0.9")), 0.05, 0.99) catch; 0.9 end
# 무진전 몇 스텝마다 "팀 교착" 사건을 결정 레이어에 올릴지. 0=끔(기존 데모 재현 그대로).
# 오라클 생성기의 DS_REFORM(기본 120)에 대응한다 — 데모에는 그동안 이 장치가 아예 없었다.
const DEMO_REFORM = try max(0, parse(Int, get(ENV, "DEMO_REFORM", "0"))) catch; 0 end
const DEMO_REFORM_MAX = try max(1, parse(Int, get(ENV, "DEMO_REFORM_MAX", "3"))) catch; 3 end
# 빌드 RNG seed. 기존 데모는 1 로 고정돼 있어 **한 판밖에 못 봤다** — 2x2 대조를 여러 seed 로
# 반복하려면 노브가 필요하다. 기본 1 이므로 기존 스트림 재현은 그대로다.
const DEMO_SEED = try parse(Int, get(ENV, "DEMO_SEED", "1")) catch; 1 end
# 방위별 예비 로봇 수. 기본 2 = 기존 데모 재현. 오라클 생성기는 3 을 쓴다(DS_SPARES) — 같은 사건에서
# 데모와 오라클의 결론이 정반대로 나와서(NOOP 완주 여부), 그 차이를 좁히려면 이 값을 맞출 수 있어야 한다.
const DEMO_SPARES = try max(0, parse(Int, get(ENV, "DEMO_SPARES", "2"))) catch; 2 end
# ---- 무작위 OOD 스트림 (2026-08-05) ------------------------------------------------------
# DEMO_OOD_SEED > 0 이면 로봇 OOD(fault/battery)의 **발화 시점·종류·심각도**를 이 시드로 뽑는다
# (CB.schedule_random_ood!). 0(기본)이면 예전의 고정 슬롯 배치 그대로 = 기존 스트림 재현 불변.
#
# 왜 별도 시드인가: DEMO_SEED 는 **world**(로봇 초기 배치)다. 같은 공장에서 같은 우주선을 반복
# 제조하는 도메인에서 초기 배치는 고정이어야 하므로 DEMO_SEED 는 1 로 두고, 확률성은 "언제 어떤
# 고장이 나는가"에만 준다. 두 축을 한 손잡이로 묶으면 "적응력"과 "다른 공장"이 섞여 측정된다.
#
# zone 은 여기서 무작위화하지 않는다: 이 데모의 zone 은 스텝을 돌리기 전에 한 번 터진다(재적치
# 변환이 조립체가 pristine 할 때만 안전하기 때문). 빌드 도중 zone 은 zonecore 케이스가 담당한다.
const DEMO_OOD_SEED = try max(0, parse(Int, get(ENV, "DEMO_OOD_SEED", "0"))) catch; 0 end
const DEMO_OOD_LO   = try clamp(parse(Float64, get(ENV, "DEMO_OOD_LO", "0.10")), 0.01, 0.95) catch; 0.10 end
const DEMO_OOD_HI   = try clamp(parse(Float64, get(ENV, "DEMO_OOD_HI", "0.75")), 0.02, 0.98) catch; 0.75 end
# 깊은 방전(→Replace)이 뽑힐 확률. 나머지는 DEMO_BSOC 만큼의 완만한 열화(→Deprioritize/NOOP).
const DEMO_OOD_SEVFRAC = try clamp(parse(Float64, get(ENV, "DEMO_OOD_SEVFRAC", "0.5")), 0.0, 1.0) catch; 0.5 end
const _REFORM_CT = Ref(0)   # 발화 횟수(상한 초과 시 더는 안 올림 → 진짜 정지가 정지로 보이게)
# 사건마다의 결정 기록(요약 JSONL 용). 스위프 하니스가 이걸 읽어 정책별 결정을 비교한다.
const _DECISIONS = Vector{Any}()
const NSUF   = DEMO_N > 0 ? "_n$(DEMO_N)" : ""   # stream name gets _nN so each count caches separately
const PARAMS = try CB.get_project_params(MODEL) catch; nothing end
const NROB   = haskey(ENV, "DEMO_ROBOTS") ? parse(Int, ENV["DEMO_ROBOTS"]) :
               (PARAMS === nothing ? 10 : PARAMS.num_robots)
const SCALE  = PARAMS === nothing ? 0.008 : PARAMS.model_scale
model_base   = replace(splitext(basename(MODEL))[1], r"[^A-Za-z0-9]+" => "_")
stream_dir   = joinpath(HERE, "streams"); mkpath(stream_dir)
stream_path  = get(ENV, "MONITOR_STREAM", joinpath(stream_dir, "$(model_base)__$(OODC)$(NSUF).jsonl"))

_rl(rid) = try "R" * string(getfield(rid, :id)) catch; replace(string(rid), r"\s+" => " ") end

# ---- OOD 케이스 → 어떤 disturbance 를 어느 진척지점에 예약할지 -------------------
# kinds 목록을 반환(진척 프랙션은 아래에서 n_total 기준으로 환산).
function case_kinds(c)
    c == "none"          && return Symbol[]
    c == "battery"       && return [:battery]
    c == "fault"         && return [:fault]
    c == "zone"          && return [:zone]
    c == "zonecore"      && return [:zonecore]   # 중앙 core zone, **빌드 도중** 발화(아래 주석 참조)
    c == "fault_battery" && return [:fault, :battery]
    c == "fault_zone"    && return [:zone, :fault]
    c == "battery_zone"  && return [:zone, :battery]
    # 2026-08-06: 세 종류가 **한 스트림 안에서** 섞이는 케이스. DEMO_OOD_STREAM3=1 과 함께 쓴다.
    # 기존 조합 케이스(fault_zone 등)는 각 종류가 정확히 한 번, 정해진 순서로 나온다 —
    # 즉 대본이다. 여기서는 무엇이 언제 몇 번 오는지가 전부 추첨이다.
    c == "all"           && return [:fault, :battery, :zone]
    return [:fault]   # fallback
end

# ---- CORE zone: RelocateBuild 를 실제로 요구하는 사건 (2026-08-04) --------------------------
# 기존 `zone` 케이스와 두 가지가 다르다.
#  (1) 위치: root 의 **못 옮기는 하역 목표**를 CORE_FRAC 만큼 삼킨다. 기존 케이스는 정반대로
#      미래 작업과 **가장 적게 겹치는** 자리를 고르므로(argmin) 개입이 손해라 NOOP 이 정답이다.
#      그래서 그 케이스로는 RelocateBuild 가 화면에서 실행되는 장면이 원리적으로 안 나온다.
#  (2) 시점: 빌드 **도중**(schedule_ood_at_closed!)에 터진다. 기존 zone 이 시작 전에 터지는 이유는
#      restage(ForbidZone)가 "조립체가 아직 pristine 할 때만" 변환 안전하기 때문인데,
#      translate_whole_build! 에는 그 전제가 없다 — 그게 RelocateBuild 를 만든 이유다.
# 안전: core_zone_for_severity 가 "빌드 전체를 옮겨도 못 벗어난다"고 하면 아무것도 주입하지 않는다.
const CORE_FRAC = try clamp(parse(Float64, get(ENV, "CORE_FRAC", "1.0")), 0.0, 1.0) catch; 1.0 end
function inject_core_zone!(env)
    sel = try CB.core_zone_for_severity(env, CORE_FRAC) catch; nothing end
    (sel === nothing || !sel.relocatable || sel.radius <= 0.0) && return nothing
    _ZONE_CT[] += 1; key = Symbol("zonecore_inj_$(_ZONE_CT[])")
    c = Vector{Float64}(sel.center)
    z = CB.add_restriction_zone!(key, c, sel.radius)
    nl = "A no-go exclusion zone has appeared at ($(round(c[1]; digits = 2)), $(round(c[2]; digits = 2))) " *
         "over the central build area, covering $(sel.covered) of the $(sel.total) final-assembly " *
         "delivery points; the remaining work cannot be delivered where it stands."
    # assembly=nothing : core zone 은 "막힌 조립체 하나"가 없다(코어 전체가 걸린다).
    #   ForbidZone 이 잘못 grounding 되지 않게 하는 효과도 있다.
    try CB.record_ood_truth!(nl, CB.ZoneTruth(key, Float64[c[1], c[2]], Float64(CB.get_radius(z)), nothing)) catch end
    println("[zonecore] injected @($(round(c[1];digits=2)), $(round(c[2];digits=2))) R=$(round(sel.radius;digits=3)) " *
            "covering $(sel.covered)/$(sel.total) root delivery goals")
    return nl
end

# ---- staging 을 실제로 막는 no-go 존 주입(→ ForbidZone restage 가 정답) ----------
const _ZONE_CT = Ref(0)
function inject_staging_zone!(env; frac = 0.55)   # 존 크기(staging 반경 대비). 너무 크면 restage 후에도 교착
    isempty(env.staging_circles) && return nothing
    ks   = collect(keys(env.staging_circles))
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), ks)
    for (aid, ball) in env.staging_circles
        aid == root && continue
        ac = try CB._assembly_complete_node(env, aid) catch; nothing end
        ac === nothing && continue
        v = try CB.get_vtx(env.sched, CB.node_id(ac)) catch; nothing end
        (v === nothing || v in env.cache.closed_set || v in env.cache.active_set ||
         CB._assembly_started(env, aid)) && continue
        c = Vector{Float64}(CB.get_center(ball)[1:2]); r = Float64(CB.get_radius(ball))
        zr = r * frac
        # Cross the staging boundary instead of covering its centre. Rank
        # deterministic candidates by overlap with unfinished physical work,
        # so the demo exercises re-staging without trapping fixed/active goals.
        overlap = min(0.25r, 0.5zr)
        offset = max(0.0, r + zr - overlap)
        work = CB._future_work_discs(env)
        candidates = [c .+ offset .* [cos(2pi*k/24), sin(2pi*k/24)]
                      for k in 0:23]
        candidates = [q for q in candidates
                      if CB.zone_clears_root_goals(q, zr, env)]
        if !isempty(candidates)
            score(q) = count(work) do disc
                wc, wr = disc
                hypot(q[1] - wc[1], q[2] - wc[2]) < zr + wr + 1e-4
            end
            c = candidates[argmin(score.(candidates))]
        end
        _ZONE_CT[] += 1; key = Symbol("zone_inj_$(_ZONE_CT[])")
        z = CB.add_restriction_zone!(key, c, zr)
        nl = "A no-go exclusion zone has appeared at ($(round(c[1]; digits = 2)), $(round(c[2]; digits = 2))) " *
             "blocking a staging area; restage the affected assembly out of the restricted region."
        try CB.record_ood_truth!(nl, CB.ZoneTruth(key, Float64[c[1], c[2]], Float64(CB.get_radius(z)), aid)) catch end
        return nl
    end
    return nothing
end

# ---- 실제로 **막는** 구역 (2026-08-06) -----------------------------------------------------
# 위의 inject_staging_zone! 은 미래 작업과 **가장 적게 겹치는** 자리를 argmin 으로 고른다 = 설계상
# 아무것도 막지 않는다. 그 가족만으로는 "언제 개입하고 언제 절제하는가"가 결정 문제가 못 된다
# (STEP 6 실측: 덮임 ≠ 막힘. root 하역목표를 8/8 삼켜도 완주했다).
#
# 이 함수는 `render_demo.jl::inject_blocking_zone!` 과 **같은 절차**다(그쪽이 검증된 원본:
# tools/restage.jl::place_blocking_zone_on_nav_goal! 의 순서를 옮긴 것). 왜 공유 모듈로 빼지 않고
# 옮겨 적었나 — render_demo.jl 은 덱 영상 4편의 녹화 경로이고 그 파일에 손을 대면 이미 발표에 쓴
# 산출물의 재현성이 걸린다. 절차가 갈리지 않게 두 곳을 같이 고쳐야 한다는 사실은 여기 적어 둔다.
#
# 순서: 아직 활성이 아닌 항법 목표만 후보 → 결정적 정렬 → 복구 가능한 것만 → 심은 뒤 실제로
# 막혔는지(n_blocked ≥ 1) 확인, 아니면 지우고 다음 후보.
const DEMO_ZONE_R = try max(0.05, parse(Float64, get(ENV, "DEMO_ZONE_R", "0.5"))) catch; 0.5 end
# 어느 가족의 구역을 심을지. render_demo.jl 과 **같은 이름·같은 기본값**이어야 한다(두 엔진이 같은
# 손잡이를 읽어야 같은 세계를 만든다). blocking = 실제로 막는다(개입이 정답) / harmless = 옛 주입기,
# 적치원 가장자리를 스치기만 한다(NOOP 이 정답).
const DEMO_ZONE_MODE = lowercase(get(ENV, "DEMO_ZONE_MODE", "blocking"))
# pre-sim 에 심은 blocking 존의 **결정을 첫 배치 뒤로 미뤘는가**. simulate_case! 가 소비한다.
const ZONE_DECIDE_DEFERRED = Ref(false)

function inject_blocking_zone!(env; frac = DEMO_ZONE_R)
    isempty(env.staging_circles) && return nothing
    r = frac * Float64(CB.default_robot_radius())
    navs = try CB._nav_goal_targets(env) catch e
        @warn "[zone] _nav_goal_targets 실패" exception = e; return nothing
    end
    isempty(navs) && return nothing
    ks = collect(keys(env.staging_circles))
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), ks)
    c0 = Vector{Float64}(CB.get_center(env.staging_circles[root])[1:2])
    cand = [t for t in navs if !(t.vtx in env.cache.active_set)]
    sort!(cand; by = t -> (t.kind === :transport ? 0 : 1, hypot(t.goal[1] - c0[1], t.goal[2] - c0[2])))
    _ZONE_CT[] += 1; key = Symbol("zone_blk_$(_ZONE_CT[])")
    for t in cand
        CB.zone_relocatable(t.goal, r, env) || continue          # 복구 가능한 것만 심는다
        z = CB.add_restriction_zone!(key, t.goal, r)
        b = try CB.zone_blockage(env; zone_keys = [key], check_paths = false) catch e
            @warn "[zone] zone_blockage 실패" exception = e; nothing
        end
        if b !== nothing && b.n_blocked >= 1
            c = Vector{Float64}(t.goal)
            println("[zone] blocking zone on $(t.kind) vtx=$(t.vtx) @$(round.(c; digits = 3)) " *
                    "r=$(round(r; digits = 3)) -> nav_blocked=$(b.n_blocked)/$(b.n_nav_goals)")
            # 관찰만 남기고 "그러니 무엇을 하라"는 붙이지 않는다 — 뒷절이 곧 정답이라,
            # 주는 순간 재는 것이 추론이 아니라 프롬프트 준수가 된다(STEP 4).
            nl = "A no-go exclusion zone has appeared at ($(round(c[1]; digits = 2)), " *
                 "$(round(c[2]; digits = 2))) with radius $(round(r; digits = 2)). " *
                 "Robots that enter the disc are pushed back out of it."
            try CB.record_ood_truth!(nl,
                CB.ZoneTruth(key, Float64[c[1], c[2]], Float64(CB.get_radius(z)), nothing)) catch end
            return nl
        end
        CB.remove_restriction_zone!(key)
    end
    println("[zone] no blocking placement found (every candidate was active or unrecoverable)")
    return nothing
end

include(joinpath(@__DIR__, "zone_inject.jl"))   # DEMO_ZONE_AT 용 선언적 주입기

include(joinpath(@__DIR__, "policy.jl"))   # 결정 정책 레이어(canonical/surrogate/dspy 공용)

# ---- 캡처: 결정 정책의 출력을 monitor respec 패널로 -------------------------------
# capture! 는 policy.jl 의 record_decision! 을 그대로 부른다.
#
# 예전에는 이 자리에 record_decision! 을 **복사해 놓은 쌍둥이**가 있었다. 그래서 policy.jl 에
# 필드를 하나 추가해도(router, nl 전문) render_demo.jl 스트림에는 실리고 run_demo.jl 스트림에는
# 안 실리는 조용한 어긋남이 생겼다 — 실제로 라우터 첫 실측에서 이 사고가 났다(스트림에 router 없음).
# 두 엔진이 "똑같은 결정을 내리도록 한 곳에 모은다"는 policy.jl 의 취지대로, 기록도 한 곳에서 한다.
capture!(env, truth, decision, nl) = record_decision!(env, truth, decision, nl)

# ---- OOD 하나 처리: 결정 캡처 + **고른 매크로대로** 복구 ---------------------------
# 중요: 복구는 이벤트 종류가 아니라 **정책이 고른 매크로**를 따른다. 그래야 UI 에 표시된 결정과
# 엔진이 실제로 한 일이 일치한다(예전엔 종류별로 고정 복구라, LLM 이 NOOP 을 골라도 엔진은 고쳤다).
#   Replace      → hot_swap_robot!  (정체성보존 씬트리 hot-swap, 창고 스페어로 본체 교체)
#   Deprioritize → battery 면 rebalance_for_battery!(SoC-편향 재solve), 그 외엔 우선순위 강등
#   ForbidZone   → restage_all_blocked! (+필요시 translate_whole_build!)
#   NOOP         → 아무 것도 하지 않음
# canonical 정책에서는 규칙이 종전과 같은 매크로를 내므로 동작이 완전히 동일하다.
function handle_ood!(env, truth, nl)
    decision = decide_all(env, truth; nl = nl)      # nl = LLM 이 읽을 자연어 관찰
    let rt = decision.router
        get(rt, "enabled", false) && println("[router] $(rt["reason"]) → $(rt["target"])")
    end
    capture!(env, truth, decision, nl)
    tag = string(typeof(truth).name.name)
    mac = decision.macro_name
    # 스위프 요약용 기록. UI(monitor 스트림)와 별개로, 정책 비교를 기계가 읽을 수 있게 남긴다.
    push!(_DECISIONS, Dict(
        "truth"    => tag,
        "at"       => length(env.cache.closed_set),
        "macro"    => mac,
        # ---- 채점에 필요한 결정-시점 상태 (2026-08-06) ------------------------------------
        # "옳은 결정 비율"을 나중에 파이썬에서 계산하려면 **결정 순간의 공개 상태**가 그대로
        # 남아 있어야 한다. 사후에 스트림에서 복원하려 하면 시점이 어긋난다(shim 오분류 사고와
        # 같은 종류의 함정). 오라클 라벨과 같은 축(kind·severity·progress·spare)만 싣는다.
        "valid"    => (try valid_macros(env, truth) catch; String[] end),
        "progress" => (n_total > 0 ? length(env.cache.closed_set) / n_total : 0.0),
        "spare_count" => (try length(CB.active_spares()) catch; -1 end),
        "agent_pending" => (try _agent_pending(env, hasproperty(truth, :robot) ? truth.robot : nothing) catch; -1 end),
        "enacted"  => decision.enacted,
        "rule"     => decision.rule_macro,
        "llm"      => decision.llm_macro,
        "surrogate" => (try decision.policies["surrogate"]["chosen"] catch; "" end),
        "agree"    => decision.agree,
        # zone 사건의 채점에는 **막힘 원시값**이 있어야 한다. STEP 10 이 실측으로 보인 것:
        # 같은 zone kind 안에서 정답이 뒤집히고(blk→RelocateBuild / cov→NOOP), 그 둘을 가르는 것은
        # kind 도 zone_overlap 도 아니라 (nav_blocked, root_covered) 쌍이다. 이 값이 요약에 없으면
        # 나중에 "옳은 결정이었나"를 물을 수 없다(스트림에서 사후 복원하면 시점이 어긋난다).
        "zone_primitives" => (try get(decision.router, "zone_primitives", nothing) catch; nothing end),
        "router_novel" => (try get(decision.router, "novel", nothing) catch; nothing end),
        "router_p"     => (try get(decision.router, "p", nothing) catch; nothing end),
        "router_target" => (try get(decision.router, "target", nothing) catch; nothing end),
        "escalated"     => (try haskey(decision.router, "escalated_from") catch; false end),
        "soc"      => (truth isa CB.BatteryTruth ? (try Float64(truth.soc_after) catch; nothing end) : nothing),
        "nl"       => String(nl)))
    try
        if mac == "NOOP"
            println("[recover] $tag → NOOP (정책이 개입하지 않기로 결정)")
        elseif mac == "Replace"
            if hasproperty(truth, :robot)
                CB.hot_swap_robot!(env, truth.robot; mode = :via_depot, verbose = false)
                if truth isa CB.BatteryTruth
                    local f = CB.BATTERY_FLEET[]                   # 스왑된 본체=새 배터리 → SoC 회복
                    (f !== nothing && haskey(f.soc, truth.robot)) && (f.soc[truth.robot] = 1.0)
                end
            end
        elseif mac == "SwapBattery"
            # 2026-08-06 (Ch-A): 현장 배터리 교체. Replace 와 달리 **창고 예비 본체를 안 먹는다** —
            # 그게 두 팔을 따로 두는 이유이고(spec_dsl.jl), 방전 사건에서 싼 정답이 되는 근거다.
            # 씬트리·스케줄을 안 건드리므로 정체성 위반이 원리적으로 불가능하다.
            if hasproperty(truth, :robot)
                local sw = CB.swap_battery!(env, truth.robot; verbose = false)
                println("[battery] swap=$(sw.status) soc_before=$(get(sw, :soc_before, nothing))")
            end
        elseif mac == "Deprioritize"
            if truth isa CB.BatteryTruth
                CB.rebalance_for_battery!(env)
            elseif hasproperty(truth, :robot)
                try CB.deprioritize_agent!(truth.robot, 0.25) catch e
                    @warn "deprioritize_agent! failed" exception = e
                end
            end
        elseif mac == "ForbidZone" && truth isa CB.ZoneTruth
            # A zone can cover several staging workspaces. Relocate every
            # blocked subassembly, then minimally translate the whole build
            # only if fixed/root goals remain covered. Keep the zone active so
            # routing and the post-RVO clearance gate enforce it continuously.
            local keys = Symbol[truth.zone]
            local staged = CB.restage_all_blocked!(env;
                zone_keys = keys, resume = true, verbose = false)
            local recovery = staged
            local overlaps = CB._count_future_work_overlaps(env;
                zone_keys = keys)
            local corrections = 0
            while overlaps > 0 && corrections < 4
                recovery = CB.translate_whole_build!(env;
                    zone_keys = keys, resume = true, verbose = false)
                corrections += 1
                recovery.status in (:translated, :already_clear, :residual_blocked) || break
                overlaps = CB._count_future_work_overlaps(env;
                    zone_keys = keys)
            end
            local residual = CB._count_future_work_overlaps(env;
                zone_keys = keys)
            residual == 0 || error(
                "zone recovery left $residual future work discs inside $(truth.zone)")
            println("[zone] staging=$(staged.status) final=$(recovery.status) " *
                    "corrections=$corrections active_zone=$(truth.zone) residual=$residual")
            # 좁은 공장에선 지속 존이 로봇 경로를 막아 nav 교착 → 조립체를 안전지대로 옮긴 뒤
            # 일시 장애를 해제(transient obstruction)해 완주시킨다. respec(ForbidZone)은 이미 기록됨.
        elseif mac == "RelocateBuild" && truth isa CB.ZoneTruth
            # 2026-08-04: zone 사건의 기본 개입 팔. ForbidZone 분기와 달리 **조립체별 재적치를
            # 아예 건너뛰고** 빌드 전체를 한 번에 옮긴다(그 전제조건이 빌드 중반에 사라지므로).
            # 이 분기가 없으면 LLM 이 RelocateBuild 를 골라도 아무 일도 안 일어나고, UI 에는
            # "LLM 이 개입했다"고 찍히는 최악의 조용한 거짓말이 된다.
            local zkeys = Symbol[truth.zone]
            local wb = CB.translate_whole_build!(env; zone_keys = zkeys, resume = true, verbose = true)
            local left = CB._count_future_work_overlaps(env; zone_keys = zkeys)
            println("[zone] whole-build=$(wb.status) Δ=$(get(wb, :delta, nothing)) " *
                    "active_zone=$(truth.zone) residual_work_discs=$left")
            # :already_clear = Δ0. 구역이 미완 목표를 하나도 안 덮어 옮길 필요가 없었던 경우이며
            # 실패가 아니다(예전에는 :translated 로 뭉뚱그려져 "0 m 이동"이 성공으로 찍혔다).
            wb.status in (:translated, :already_clear) ||
                @warn "RelocateBuild 가 구역을 못 벗어남" status=wb.status residual=left
        elseif mac == "ReformTeam"
            # 루트 엔드게임 교착 복구. 2026-08-04 규명: 이 트윈의 완주 실패는 **전부 루트에서만**
            # 일어나고(하위 조립체는 항상 7/7 done), 얼어붙는 것은 TransportUnitGo/DepositCargo 사슬이다.
            # 오라클 생성기는 set_reform_interval! 로 배경 재정렬을 도는데 이 데모는 그게 없어서
            # 한 번 끼면 그대로 죽었다. 단계적으로 올린다: 팀 재정립 → 안 되면 직렬화 관문 해소.
            local rec = try CB.recover_stalled_teams!(env) catch e
                @warn "recover_stalled_teams! 실패" exception=e; (status = :error,)
            end
            println("[reform] recover=$(rec.status)")
            if rec.status in (:snapped, :force_snapped, :restaged, :carrier_closed, :carrier_advanced)
                CB.reset_cache_resume!(env.cache, env.sched)
            else
                local wedge = try CB.resolve_schedule_wedge!(env) catch e
                    @warn "resolve_schedule_wedge! 실패" exception=e; (status = :no_wedge,)
                end
                println("[reform] wedge=$(wedge.status)")
                wedge.status == :unwedged && CB.reset_cache_resume!(env.cache, env.sched)
            end
        end
        println("[recover] $tag → $mac  (closed=", length(env.cache.closed_set), ")")
    catch e
        println("[recover] $tag ($mac) FAILED: ", first(split(sprint(showerror, e), "\n")))
    end
    CB.update_planning_cache!(env, 0.0)
end

# ============================ 빌드 + 수동 루프 =====================================
println(">>> build: model=$MODEL  case=$OODC  robots=$NROB")
haskey(ENV, "SPARE_DEPOT_DIST") &&
    CB.set_spare_depot_distance!(parse(Float64, ENV["SPARE_DEPOT_DIST"]))
env = CB.run_lego_demo(; ldraw_file = MODEL, project_name = "$(model_base)_ood", num_robots = NROB,
    model_scale = SCALE,
    assignment_mode = :greedy, save_animation = false, write_results = false, overwrite_results = true,
    n_spare_per_pool = DEMO_SPARES, return_env_before_sim = true, rng = Random.MersenneTwister(DEMO_SEED))

n_total = Graphs.nv(env.sched)
println(">>> env built: $n_total schedule nodes")

# 배터리 레이어(완만 용량 → 자연 방전이 0에 안 닿게; 주입된 severe 만 저SoC)
CB.enable_battery!(env; params = CB.demo_battery_params(shrink = 25.0))
try CB.set_battery_penalty!(gain = 6.0, soc_target = 0.5, hard_mult = 1.0e3) catch end
CB.RESPEC_ENABLED[] = false   # 우리가 직접 복구하므로 프레임워크 respec-루프는 끔
# ...하지만 **드리프트 완화는 켠다**(2026-08-06). 이 루프는 respec 을 안 하는 게 아니라 큐를 안 쓸
# 뿐이고, 실제로 RelocateBuild 같은 기하 복구를 집행한다. 두 스위치가 한 플래그에 묶여 있어서,
# 빌드 중반 전역 이동 뒤 "배달됐지만 아직 포획 안 된 부품"에서 @assert 로 시뮬이 통째로 죽었다
# (실측: closed=151, Δ=2.4 m). replan.jl 의 RESPEC_DRIFT_REPAIR 주석에 전말을 적어 뒀다.
CB.RESPEC_DRIFT_REPAIR[] = true
CB.set_hot_swap!(enabled = true, mode = :via_depot)   # 완주 가능한 정체성보존 교체 경로 켬
# CARRIER_RESCUE: render_demo.jl 과 **같은 기본값**이어야 두 엔진이 같은 세계를 만든다(2026-08-05).
# 이 데모의 endgame 정체는 형성된 운반체가 하역 목표에 못 닿는 것인데, 그걸 푸는 유일한 단이
# 이 환경변수로 잠겨 있었다. 오라클/덱 스크립트는 전부 =1 로 켜는데 모니터 데모 두 개만 빠져 있었다.
haskey(ENV, "CARRIER_RESCUE") || (ENV["CARRIER_RESCUE"] = "1")
try CB.reset_snap_count!() catch end            # 런 사이 전역 카운터 이월 방지(정의만 되고 아무도 안 부르던 API)
try CB.clear_carrier_progress!() catch end

# OOD 예약: 케이스별 kinds 를 진척 프랙션에 배치
CB.monitor_enable!(stream_path)
CB.clear_ood_schedule!()
frac_of(f) = max(4, round(Int, f * n_total))
# DEMO_N = how many OOD events to inject (0 = one per case kind, the original behaviour). When >0 it
# OVERRIDES the fault/battery event count, cycling the case's robot kinds across the build so you can
# stress-test with N disturbances. A zone (if in the case) always fires ONCE up front, because spatial
# re-staging is only transform-safe while every affected assembly is still pristine.
demo_n = DEMO_N
let kinds = case_kinds(OODC), slots = [0.10, 0.32, 0.55]
    robot_kinds = filter(k -> k !== :zone, kinds)
    # ---- 확률적 3종 스트림 (2026-08-06) --------------------------------------------------
    # 지금까지 zone 은 **언제나 sim 전에 1회 고정**으로 터졌다(재적치 변환이 조립체가 pristine 할
    # 때만 안전하기 때문). 그래서 "무작위 스트림" 이라고 부른 실행에도 공간 사건은 늘 같은 시점의
    # 같은 사건이었고, 세 종류가 섞여 무작위로 오는 판은 이 저장소에 한 번도 없었다.
    # 여기서 그 구멍을 닫는다: DEMO_OOD_STREAM3=1 이면 fault/battery/zone 을 **하나의 추첨**으로
    # 뽑고, zone 은 sim 전이 아니라 뽑힌 진척 지점에서 `inject_blocking_zone!` 로 심는다.
    # 그 주입기는 pristine 전제가 없다(RelocateBuild 가 언제든 성립하므로).
    # 기본값 0 = 예전 경로 그대로이므로 기존 스트림 재현은 바뀌지 않는다.
    stream3 = get(ENV, "DEMO_OOD_STREAM3", "0") == "1" && DEMO_OOD_SEED > 0
    if stream3
        local skinds = isempty(kinds) ? Symbol[:fault, :battery] : copy(kinds)
        # zonecore 는 이 경로에서 다루지 않는다(중앙 core zone 은 NOOP 이 정답인 별개 가족).
        replace!(skinds, :zonecore => :zone)
        unique!(skinds)
        local n_ev = demo_n > 0 ? demo_n : max(3, length(skinds))
        local lo = frac_of(DEMO_OOD_LO); local hi = max(lo + 1, frac_of(DEMO_OOD_HI))
        local rng = Random.MersenneTwister(DEMO_OOD_SEED)
        local pts = CB._random_progress_points(n_ev, lo, hi, rng)
        local drawn = String[]
        for p in pts
            local kind = skinds[rand(rng, 1:length(skinds))]
            local severe = rand(rng) < DEMO_OOD_SEVFRAC
            if kind === :fault
                CB.schedule_ood_at_closed!(p, CB.fault_action(; safe = true, obstacle = false))
                push!(drawn, "fault@$(p)")
            elseif kind === :battery
                # 심각도 추첨은 고정 슬롯 경로와 같은 규칙: severe 면 깊은 방전(→살려야 함),
                # 아니면 DEMO_BSOC 만큼의 완만한 열화(→개입이 손해일 수 있음).
                CB.schedule_ood_at_closed!(p, CB.battery_action(soc_drop = severe ? 1.0 : DEMO_BSOC))
                push!(drawn, "battery$(severe ? "!" : "")@$(p)")
            else
                # 막는 구역. 후보를 못 찾으면 **사건이 통째로 사라지지 않게** 무해 가족으로 폴백한다
                # (zone 이 뽑혔는데 zone 이 없는 런은 결과가 아니라 사고다).
                CB.schedule_ood_at_closed!(p, function (e)
                    local nl = inject_blocking_zone!(e)
                    nl === nothing || return nl
                    println("[zone] blocking placement failed → harmless injector fallback")
                    return inject_staging_zone!(e; frac = 0.20)
                end)
                push!(drawn, "zone@$(p)")
            end
        end
        println(">>> OOD stream3 seed=$(DEMO_OOD_SEED): $(length(pts)) events " *
                "[$(join(drawn, ", "))] kinds=$(join(string.(skinds), "/")) " *
                "(range $lo..$hi of $n_total, severe_frac=$(DEMO_OOD_SEVFRAC))")
    else
    if :zone in kinds                                     # zone: inject + recover ONCE, before any build step
        # DEMO_ZONE_AT 이 있으면 **사람이 고른 좌표**를 심는다(oracle/out/fz_presim.csv 카탈로그).
        # 카탈로그 재현이 걸린 경로이므로 이 우선순위는 그대로 둔다.
        #
        # 없을 때의 기본이 2026-08-08 에 바뀌었다: 옛 기본인 `inject_staging_zone!` 은 **설계상
        # 아무것도 막지 않는다**(미래 작업과 가장 적게 겹치는 자리를 argmin 으로 고른다). 그래서
        # 같은 "zone" 케이스인데 렌더 엔진(render_demo.jl)은 막는 구역을, 배치 엔진은 안 막는
        # 구역을 만들고 있었다 — 두 엔진의 비대칭은 이 저장소가 이미 한 번 크게 데인 종류다.
        # 이제 둘 다 blocking 을 기본으로 한다. 옛 동작은 DEMO_ZONE_MODE=harmless.
        local spec = declared_zone_spec()
        nl = if spec !== nothing
            inject_declared_zone!(env; cx = spec.cx, cy = spec.cy, r = spec.r)
        elseif DEMO_ZONE_MODE == "blocking"
            # 후보를 못 찾으면 사건이 통째로 사라지므로(zone 케이스인데 zone 이 없는 런은 결과가
            # 아니라 사고다) 무해 가족으로 폴백하고 그 사실을 로그에 남긴다.
            local z = inject_blocking_zone!(env)
            z === nothing &&
                println("[zone] pre-sim blocking placement failed → falling back to the harmless injector")
            z === nothing ? inject_staging_zone!(env; frac = 0.20) : z
        else
            inject_staging_zone!(env; frac = 0.20)
        end
        # ---- 결정 시점 (2026-08-08) --------------------------------------------------------
        # 주입은 pre-sim 이지만 **결정은 첫 배치가 닫힌 뒤**에 한다(blocking 가족 한정).
        # 왜: pre-sim 에는 모든 조립체가 pristine 이라 ForbidZone(매크로 3)이 유효 후보에 들어온다.
        # 실측(같은 존·같은 seed): 즉시 결정 → ForbidZone → stall 204/313 / 뒤로 미룸 → RelocateBuild.
        # 렌더 엔진은 push_ood! 로 큐에 넣어 자연히 closed≈58 에 결정했고 거기서 완주했다.
        # 선언 좌표(DEMO_ZONE_AT)·harmless 경로는 오라클 카탈로그 재현이 걸려 있어 종전대로 즉시 결정.
        if nl !== nothing
            if spec === nothing && DEMO_ZONE_MODE == "blocking"
                ZONE_DECIDE_DEFERRED[] = true
            else
                log = CB.ood_truth_log(); handle_ood!(env, log[end].truth, nl)
            end
        end
    end
    n_robot = demo_n > 0 ? demo_n : length(robot_kinds)   # DEMO_N overrides the robot-OOD count
    ats = Int[]
    if DEMO_OOD_SEED > 0 && !isempty(robot_kinds)
        # ---- 무작위 스트림 경로 ----------------------------------------------------------
        # 시점(균등 슬롯 ± 반슬롯 jitter) · 종류 · battery 심각도를 전부 DEMO_OOD_SEED 로 뽑는다.
        # safe_fault=true / fault_obstacle=false 는 고정 슬롯 경로가 쓰는 것과 같은 조건이라
        # (fault_action(; safe=true, obstacle=false)) 두 경로의 사건 성질이 같다.
        lo = frac_of(DEMO_OOD_LO); hi = max(lo + 1, frac_of(DEMO_OOD_HI))
        trg = CB.schedule_random_ood!(; n = n_robot, kinds = robot_kinds,
            closed_lo = lo, closed_hi = hi, seed = DEMO_OOD_SEED,
            soc_drop = DEMO_BSOC, battery_severe_frac = DEMO_OOD_SEVFRAC,
            severe_soc_drop = 1.0, safe_fault = true, fault_obstacle = false)
        ats = [try t.closed_at catch; -1 end for t in trg]
        println(">>> OOD stream seed=$(DEMO_OOD_SEED): $(length(trg)) events " *
                "kinds=$(join(string.(robot_kinds), "/")) @closed≈$(ats) " *
                "(range $lo..$hi of $n_total, severe_frac=$(DEMO_OOD_SEVFRAC))")
    else
    for j in 1:n_robot
        isempty(robot_kinds) && break
        kind = robot_kinds[((j - 1) % length(robot_kinds)) + 1]   # cycle fault/battery across N events
        frac = demo_n > 0 ? (n_robot == 1 ? 0.10 : 0.10 + 0.65 * (j - 1) / (n_robot - 1)) :
                            slots[min(j, length(slots))]          # original slot placement when DEMO_N=0
        at = frac_of(frac); push!(ats, at)
        if kind === :fault
            CB.schedule_ood_at_closed!(at, CB.fault_action(; safe = true, obstacle = false))
        elseif kind === :zonecore
            # 빌드 도중 발화. 여기가 기존 :zone 분기(시작 전 1회)와 갈리는 지점.
            CB.schedule_ood_at_closed!(at, e -> inject_core_zone!(e))
        elseif kind === :battery
            # soc_drop 은 DEMO_BSOC 로 조절 가능(기본 0.9 = 심각 → 규칙이 ReplaceAgent 를 냄).
            # 낮추면(예: 0.45) 가벼운 열화가 되어 **규칙과 LLM 의 답이 갈리는** 장면을 만들 수 있다:
            # 규칙은 임계값만 보고 Deprioritize, DSPy 는 상태를 읽고 NOOP(개입 비용이 회수 안 됨)을 고르는 식.
            CB.schedule_ood_at_closed!(at, CB.battery_action(soc_drop = DEMO_BSOC))
        end
    end
    end   # if DEMO_OOD_SEED > 0 ... else ...
    n_zone = (:zone in kinds) ? 1 : 0                     # zone is ALWAYS fixed at 1 (transform-safe)
    rk_str = isempty(robot_kinds) ? "none" : join(string.(robot_kinds), "/")
    n_tag = demo_n > 0 ? " (DEMO_N)" : ""
    println(">>> OOD armed: zone×$(n_zone) + $(rk_str)×$(n_robot)$(n_tag) @closed≈$(ats)")
    end   # if stream3 ... else ...
end

# 수동 루프를 함수로 감싼다(Julia 최상위 for-루프 soft-scope 회피).
function simulate_case!(env, n_total; max_steps = 20_000, stall_limit = 2_500)
    CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)   # 초기 1스텝(캐시 채움)
    seen = length(CB.ood_truth_log())
    # pre-sim 에 심어 두고 결정을 미뤄 둔 존을 **여기서** 정책에 올린다(위 ZONE_DECIDE_DEFERRED 주석).
    # 첫 배치가 닫힌 뒤라 유효 매크로 집합이 실제 세계와 맞는다. seen 은 이미 이 truth 를 포함하므로
    # 아래 루프가 중복 처리하지 않는다.
    if ZONE_DECIDE_DEFERRED[]
        ZONE_DECIDE_DEFERRED[] = false
        local log0 = CB.ood_truth_log()
        isempty(log0) || handle_ood!(env, log0[end].truth, log0[end].nl)
    end
    last_closed = length(env.cache.closed_set); stall = 0
    for k in 2:max_steps
        CB.ood_inject_step!(env, k)                        # 예약 OOD 발화(truth 기록)
        log = CB.ood_truth_log()
        while seen < length(log)                           # 새로 뜬 OOD 마다 처리
            seen += 1
            handle_ood!(env, log[seen].truth, log[seen].nl)
            stall = 0                                      # 복구 직후 교착 카운터 리셋
        end
        CB.step_environment!(env)
        CB.update_planning_cache!(env, 0.0)
        CB.monitor_track_schedule_step!(env, k; dt=env.dt)
        (k % 50 == 0) && CB.monitor_emit!(env, k)          # 배치마다 프레임 방출
        nc = length(env.cache.closed_set)
        # 빌드가 실제로 전진했으면 reform 예산도 되돌린다(`render_demo.jl:566-571` 과 동일 규칙).
        # 즉 DEMO_REFORM_MAX 는 "평생 N 회"가 아니라 "**연속** 무성과 N 회"를 뜻한다.
        if nc > last_closed; last_closed = nc; stall = 0; _REFORM_CT[] = 0; else; stall += 1; end
        # DEMO_REFORM>0 이면 무진전이 그 간격을 넘을 때마다 팀 교착 사건을 **truth 로그에 올려**
        # 위의 `while seen < length(log)` 가 정책 레이어(canonical/surrogate/LLM)로 라우팅하게 한다.
        # CB.maybe_emit_reform_ood! 를 안 쓰는 이유: 그건 RESPEC_ENABLED 게이트 + 전역 respec 큐로 가는데,
        # 이 데모는 RESPEC_ENABLED=false 로 두고 truth 로그를 직접 읽어 복구를 몬다(두 경로가 다르다).
        # 발화 횟수를 제한한다. handle_ood! 뒤에 stall 이 0 으로 리셋되므로, 무제한이면 정지 판정이
        # 영영 안 나고 max_steps 까지 헛돈다(실측: reform 20회 이상 반복, closed 는 266 고정).
        if DEMO_REFORM > 0 && _REFORM_CT[] < DEMO_REFORM_MAX && stall > 0 && stall % DEMO_REFORM == 0
            _REFORM_CT[] += 1
            local rnl = "A multi-robot transport team is deadlocked while forming: some members are " *
                        "waiting in their carrying positions but the team cannot complete and the " *
                        "build has stalled. Re-establish the stuck transport team(s)."
            try CB.record_ood_truth!(rnl, CB.ReformTruth()) catch e
                @warn "reform truth 기록 실패" exception=e
            end
        end
        if CB.project_complete(env)
            CB.monitor_emit!(env, k); println(">>> PROJECT COMPLETE @ step $k (closed=$nc)")
            return (status = :complete, steps = k, closed = nc)
        elseif stall > stall_limit
            CB.monitor_emit!(env, k); println(">>> STALL: no progress $stall_limit steps @ closed=$nc / $n_total")
            return (status = :stall, steps = k, closed = nc)
        end
    end
    println(">>> reached max_steps")
    return (status = :maxsteps, steps = max_steps, closed = length(env.cache.closed_set))
end

result = (status = :error, steps = 0, closed = length(env.cache.closed_set))
const T_START = time()
try
    global result = simulate_case!(env, n_total)
finally
    CB.monitor_disable!()
end
const WALL_S = time() - T_START

# ---- 기계가 읽는 한 줄 요약 (2026-08-05) --------------------------------------------------
# DEMO_SUMMARY 가 있으면 이 런의 결과를 JSONL 한 줄로 **덧붙인다**. OOD_SEED 스위프 하니스가
# 이걸 모아 정책별 완주율·결정 분포를 낸다. 지정 안 하면 아무 것도 안 하므로 기존 동작 불변.
let path = get(ENV, "DEMO_SUMMARY", "")
    if !isempty(path)
        mkpath(dirname(abspath(path)))
        rec = Dict(
            # policy 는 ENV 를 다시 읽지 않고 **정책 레이어가 실제로 쓴 상수**를 적는다.
            # STATUS §5 의 증상("noop lane 인데 요약에 canonical")이 정확히 이 어긋남의 모양이라,
            # 값이 두 곳에서 따로 계산되면 요약 자체를 못 믿게 된다.
            "model" => MODEL, "case" => OODC, "policy" => POLICY,
            "router" => get(ENV, "DEMO_ROUTER", "auto"),
            "stream3" => (get(ENV, "DEMO_OOD_STREAM3", "0") == "1"),
            "world_seed" => DEMO_SEED,           # 로봇 초기 배치 = 공장(고정하고 쓰는 축)
            "ood_seed"   => DEMO_OOD_SEED,       # 언제/무엇이 터지는가 = 확률성(스위프하는 축)
            "n_events_armed" => DEMO_N, "spares" => DEMO_SPARES, "robots" => NROB,
            "bsoc" => DEMO_BSOC, "sev_frac" => DEMO_OOD_SEVFRAC,
            "ood_lo" => DEMO_OOD_LO, "ood_hi" => DEMO_OOD_HI,
            "status" => String(Symbol(result.status)),
            "complete" => (result.status === :complete),
            "steps" => result.steps, "closed" => result.closed, "total" => n_total,
            "progress" => (n_total > 0 ? result.closed / n_total : 0.0),
            "n_decisions" => length(_DECISIONS),
            "decisions" => _DECISIONS,
            # ---- 평가지표 4종의 원자료 (2026-08-06) ------------------------------------------
            # 지금까지 요약 행에는 완주 여부와 closed 밖에 없어서, "얼마나 잘 지은 빌드인가"를
            # 물으면 답할 수 있는 축이 하나뿐이었다. 네 축을 여기서 한 번에 남긴다:
            #   ① 성공률          -> complete (기존)
            #   ② 옳은 결정 비율   -> decisions[] (위에서 결정-시점 상태까지 실었다; 채점은 파이썬)
            #   ③ 빌드 시간       -> steps · sim_seconds(시뮬 초) · wall_seconds(실측 벽시계)
            #   ④ 에너지 효율     -> 아래 battery 블록. **총 에너지만 보면 안 된다** — 미완주 런은
            #      일을 덜 해서 에너지도 적게 쓰므로 총량은 미완주에 유리하다. 그래서 닫힌 노드당
            #      에너지(energy_per_closed)를 같이 남긴다. min_soc 는 마모 신호(가장 나쁜 로봇).
            "dt" => (try Float64(env.dt) catch; nothing end),
            "sim_seconds" => (try Float64(env.dt) * result.steps catch; nothing end),
            # 실현 makespan[sim s] — 이 레인은 return_env_before_sim=true 로 수동 루프를 돌기 때문에
            # 플래너의 stats[:Makespan] 이 존재하지 않는다. 실현 시간 = dt × steps 가 곧 makespan 이다.
            # sim_seconds 와 같은 값이지만, 목적함수 J 의 소비처가 이름으로 읽게 하려고 별도 키로 낸다.
            "makespan" => (try Float64(env.dt) * result.steps catch; nothing end),
            "wall_seconds" => round(WALL_S; digits = 1),
            "spares_left" => (try length(CB.active_spares()) catch; -1 end),
            "battery" => (try
                    local f = CB.BATTERY_FLEET[]
                    if f === nothing
                        nothing
                    else
                        local r = CB.battery_report(f)
                        Dict("total_energy_J" => r.total_energy_J,
                             "energy_per_closed" => (result.closed > 0 ?
                                                     r.total_energy_J / result.closed : nothing),
                             "mean_soc" => r.mean_soc, "min_soc" => r.min_soc,
                             "soc_spread" => r.soc_spread, "n_depleted" => r.n_depleted,
                             "n_robots" => length(r.soc))
                    end
                catch e
                    @warn "battery_report 실패" exception = e; nothing
                end),
            # 기하 세대(provenance). 창고 배치가 바뀌면 makespan·에너지가 전부 달라지므로,
            # 이 블록 없이 서로 다른 세대의 런을 한 표에 섞으면 조용히 틀린 비교가 된다.
            "geometry" => Dict("depot_mode" => "fixed",
                               "depot_distance" => CB.spare_depot_distance(),
                               "station_keeping" => true),
            "stream" => stream_path)
        open(path, "a") do io; println(io, JSON3.write(rec)); end
        println("[run_demo] summary → $path")
    end
end

n = isfile(stream_path) ? countlines(stream_path) : 0
println("[run_demo] DONE — case=$OODC  status=$(result.status)  $n frames → $stream_path")
