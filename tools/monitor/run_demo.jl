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
    c == "fault_battery" && return [:fault, :battery]
    c == "fault_zone"    && return [:zone, :fault]
    c == "battery_zone"  && return [:zone, :battery]
    return [:fault]   # fallback
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
                recovery.status in (:translated, :residual_blocked) || break
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
        end
        println("[recover] $tag → $mac  (closed=", length(env.cache.closed_set), ")")
    catch e
        println("[recover] $tag ($mac) FAILED: ", first(split(sprint(showerror, e), "\n")))
    end
    CB.update_planning_cache!(env, 0.0)
end

# ============================ 빌드 + 수동 루프 =====================================
println(">>> build: model=$MODEL  case=$OODC  robots=$NROB")
env = CB.run_lego_demo(; ldraw_file = MODEL, project_name = "$(model_base)_ood", num_robots = NROB,
    model_scale = SCALE,
    assignment_mode = :greedy, save_animation = false, write_results = false, overwrite_results = true,
    n_spare_per_pool = 2, return_env_before_sim = true, rng = Random.MersenneTwister(1))

n_total = Graphs.nv(env.sched)
println(">>> env built: $n_total schedule nodes")

# 배터리 레이어(완만 용량 → 자연 방전이 0에 안 닿게; 주입된 severe 만 저SoC)
CB.enable_battery!(env; params = CB.demo_battery_params(shrink = 25.0))
try CB.set_battery_penalty!(gain = 6.0, soc_target = 0.5, hard_mult = 1.0e3) catch end
CB.RESPEC_ENABLED[] = false   # 우리가 직접 복구하므로 프레임워크 respec-루프는 끔
CB.set_hot_swap!(enabled = true, mode = :via_depot)   # 완주 가능한 정체성보존 교체 경로 켬

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
    if :zone in kinds                                     # zone: inject + recover ONCE, before any build step
        nl = inject_staging_zone!(env; frac = 0.20)
        if nl !== nothing
            log = CB.ood_truth_log(); handle_ood!(env, log[end].truth, nl)
        end
    end
    n_robot = demo_n > 0 ? demo_n : length(robot_kinds)   # DEMO_N overrides the robot-OOD count
    ats = Int[]
    for j in 1:n_robot
        isempty(robot_kinds) && break
        kind = robot_kinds[((j - 1) % length(robot_kinds)) + 1]   # cycle fault/battery across N events
        frac = demo_n > 0 ? (n_robot == 1 ? 0.10 : 0.10 + 0.65 * (j - 1) / (n_robot - 1)) :
                            slots[min(j, length(slots))]          # original slot placement when DEMO_N=0
        at = frac_of(frac); push!(ats, at)
        if kind === :fault
            CB.schedule_ood_at_closed!(at, CB.fault_action(; safe = true, obstacle = false))
        elseif kind === :battery
            # soc_drop 은 DEMO_BSOC 로 조절 가능(기본 0.9 = 심각 → 규칙이 ReplaceAgent 를 냄).
            # 낮추면(예: 0.45) 가벼운 열화가 되어 **규칙과 LLM 의 답이 갈리는** 장면을 만들 수 있다:
            # 규칙은 임계값만 보고 Deprioritize, DSPy 는 상태를 읽고 NOOP(개입 비용이 회수 안 됨)을 고르는 식.
            CB.schedule_ood_at_closed!(at, CB.battery_action(soc_drop = DEMO_BSOC))
        end
    end
    n_zone = (:zone in kinds) ? 1 : 0                     # zone is ALWAYS fixed at 1 (transform-safe)
    rk_str = isempty(robot_kinds) ? "none" : join(string.(robot_kinds), "/")
    n_tag = demo_n > 0 ? " (DEMO_N)" : ""
    println(">>> OOD armed: zone×$(n_zone) + $(rk_str)×$(n_robot)$(n_tag) @closed≈$(ats)")
end

# 수동 루프를 함수로 감싼다(Julia 최상위 for-루프 soft-scope 회피).
function simulate_case!(env, n_total; max_steps = 20_000, stall_limit = 2_500)
    CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)   # 초기 1스텝(캐시 채움)
    seen = length(CB.ood_truth_log())
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
        if nc > last_closed; last_closed = nc; stall = 0; else; stall += 1; end
        if CB.project_complete(env)
            CB.monitor_emit!(env, k); println(">>> PROJECT COMPLETE @ step $k (closed=$nc)"); return :complete
        elseif stall > stall_limit
            CB.monitor_emit!(env, k); println(">>> STALL: no progress $stall_limit steps @ closed=$nc / $n_total"); return :stall
        end
    end
    println(">>> reached max_steps"); return :maxsteps
end

try
    simulate_case!(env, n_total)
finally
    CB.monitor_disable!()
end

n = isfile(stream_path) ? countlines(stream_path) : 0
println("[run_demo] DONE — case=$OODC  $n frames → $stream_path")
