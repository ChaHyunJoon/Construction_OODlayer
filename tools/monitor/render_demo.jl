# tools/monitor/render_demo.jl
# =============================================================================
# run_lego_demo(save_animation=true) 경로로 OOD 데모를 돌려 한 번에:
#   (1) monitor JSONL 스트림  (run_simulation! 의 monitor seam)
#   (2) OOD 시각화가 담긴 per-case MeshCat static html
#       — 고장 로봇=빨강 디스크, 스페어=시안 링, forbid zone=빨간 디스크, depot=파랑 (전부 엔진 내장)
# 복구는 프레임워크 respec 루프가 수행: canonical_producer 가 truth→DSL, hot_swap 으로 완주.
#
# ENV: DEMO_MODEL(파일명) / DEMO_OOD(none|battery|fault|zone|fault_battery|fault_zone|battery_zone)
# 출력: streams/<base>__<case>.jsonl , anim/<base>__<case>.html
# =============================================================================
using ConstructionBots
using Random
using JSON3
import Graphs
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))

const HERE  = @__DIR__
const MODEL = get(ENV, "DEMO_MODEL", "tractor.mpd")
const OODC  = lowercase(get(ENV, "DEMO_OOD", "fault"))
# battery OOD 의 SoC 낙폭. run_demo.jl 과 **같은 이름·같은 기본값**이어야 한다(두 엔진이 같은
# 손잡이를 읽어야 같은 세계를 만든다). 0.9=심각, 0.45 정도면 정책이 갈리는 애매한 구간.
const DEMO_BSOC = try clamp(parse(Float64, get(ENV, "DEMO_BSOC", "0.9")), 0.05, 0.99) catch; 0.9 end
const DEMO_N = try max(0, parse(Int, get(ENV, "DEMO_N", "0"))) catch; 0 end   # # OOD events (0=case default)
# ---------------------------------------------------------------------------------------------
# DEMO_SEED — 로봇 OOD(fault/battery)의 **발생 시점을 확률적으로** 만든다. 이것이 이제 기본값이다.
#
# 왜: 예전에는 발화 지점이 slots=[0.10,0.32,0.55] 로 못박혀 있어 "언제 터질지 모르는 교란"이 아니라
# 대본이었다. schedule_random_ood! (src/navigator/ood_stream.jl) 은 구간을 n 등분한 뒤 각 슬롯 안에서
# ±반슬롯을 흔들고 종류도 kinds 에서 추첨하므로, 같은 케이스라도 seed 가 다르면 다른 세계가 나온다.
#
# ZONE 은 일부러 제외한다 — 공간 restage 는 build step 이 열리기 전에만 transform-safe 하므로
# 존은 예전대로 sim 시작 전 1 회 고정이다(zone 을 무작위 시점에 넣으려면 mid-build restage 가 먼저
# 필요하고, 그건 별건 작업이다).
#
#   DEMO_SEED=1 (기본)  확률적, 재현 가능. 파일 이름에 접미사 없음.
#   DEMO_SEED=k>1       다른 추첨 -> streams/…_sk.jsonl 로 따로 캐시된다.
#   DEMO_SEED=0         옛 고정 슬롯 스케줄(재현용) -> …_s0.jsonl
#
# severity 는 추첨하지 않는다: ① Battery=심각(0.9) / ⑦ Battery(mild)=애매(0.45) 라는 케이스의 의미가
# 무작위 심각도에 씻겨나가면 안 되기 때문. 심각도까지 추첨하려면 DEMO_BSEVERE_FRAC>0 을 준다.
# ---------------------------------------------------------------------------------------------
const DEMO_SEED = try max(0, parse(Int, get(ENV, "DEMO_SEED", "1"))) catch; 1 end
const DEMO_BSEVERE = try clamp(parse(Float64, get(ENV, "DEMO_BSEVERE_FRAC", "0.0")), 0.0, 1.0) catch; 0.0 end
# safe=true 는 "단독 운반체만 고장낸다"(팀 운반 중인 로봇을 고장내면 교체가 has_edge 에서 터질 수
# 있다는 옛 우려). 그런데 측정해 보니 tractor 에서 그 조건이 성립하는 구간은 **step 2~20 뿐**이고
# 이후 빌드 전체에서 한 번도 성립하지 않는다(DEMO_PROBE=1, 40 프로브 중 1 회). 그 창에 묶이면
# "언제 터질지 모르는 고장"이 성립하지 않는다 -- 늘 같은 순간, 늘 같은 로봇(R1)이 된다.
#
# safe=false 로 중반(step 188, 진척 43%) 고장을 실제로 넣어 확인했다: 교체 경로가 정상 동작하고
# 빌드가 완주했다(hot-swap enact 가 들어온 뒤로 옛 has_edge 우려는 해소된 것으로 보인다).
# 그래서 기본값을 false 로 둔다 -- 무작위 시점이 실제로 의미를 갖는 유일한 설정이다.
# 문제가 생기는 조합이 있으면 그 셀만 DEMO_FAULT_SAFE=1 로 되돌리면 된다.
const FAULT_SAFE = get(ENV, "DEMO_FAULT_SAFE", "0") != "0"
const SSUF   = DEMO_SEED == 1 ? "" : "_s$(DEMO_SEED)"
const NSUF   = (DEMO_N > 0 ? "_n$(DEMO_N)" : "") * SSUF   # stream/anim name suffix so each (count, seed) caches separately
const COMMAND_FILE = get(ENV, "MONITOR_COMMAND_FILE", "")
const INTERACTIVE = get(ENV, "MONITOR_INTERACTIVE", "0") == "1"

# per-model 파라미터: project_params 에서 파일명으로 찾음(scale·robot 수).
function find_params(model)
    return try CB.get_project_params(model) catch; nothing end
end
pp    = find_params(MODEL)
NROB  = pp === nothing ? parse(Int, get(ENV, "DEMO_ROBOTS", "10")) : pp[:num_robots]
SCALE = pp === nothing ? 0.008 : pp[:model_scale]
model_base  = replace(splitext(basename(MODEL))[1], r"[^A-Za-z0-9]+" => "_")
# 산출물 이름에 쓰는 케이스 이름. 보통 DEMO_OOD 와 같지만, 프리셋 케이스(⑦ battery_mild = battery 를
# 애매한 SoC 로 돌린 것)는 **실행 케이스와 표시 이름이 다르다**. 그때 서버가 DEMO_CASE_TAG 로 표시
# 이름을 넘겨 주지 않으면 ⑦ 의 녹화가 ① battery 파일을 덮어썼다.
const CASE_TAG = get(ENV, "DEMO_CASE_TAG", OODC)
stream_dir  = joinpath(HERE, "streams"); mkpath(stream_dir)
anim_dir    = joinpath(HERE, "anim");    mkpath(anim_dir)
stream_path = joinpath(stream_dir, "$(model_base)__$(CASE_TAG)$(NSUF).jsonl")

_rl(rid) = try "R" * string(getfield(rid, :id)) catch; replace(string(rid), r"\s+" => " ") end

function case_kinds(c)
    c == "none"          && return Symbol[]
    c == "battery"       && return [:battery]
    c == "fault"         && return [:fault]
    c == "zone"          && return [:zone]
    c == "fault_battery" && return [:fault, :battery]
    # Spatial recovery must run while assemblies are still pristine. Robot
    # health events are scheduled after this pre-build geometry recovery.
    c == "fault_zone"    && return [:zone, :fault]
    c == "battery_zone"  && return [:zone, :battery]
    return [:fault]
end

const _ZONE_CT = Ref(0)

function assembly_at_zone(env, c, r)
    best = nothing; best_overlap = -Inf
    for (aid, ball) in env.staging_circles
        bc = Vector{Float64}(CB.get_center(ball)[1:2])
        overlap = Float64(CB.get_radius(ball)) + r - hypot(bc[1] - c[1], bc[2] - c[2])
        if overlap > best_overlap
            best, best_overlap = aid, overlap
        end
    end
    return best_overlap >= 0 ? best : nothing
end

function inject_live_zone!(env, x, y, r, command_id, iter)
    c = Float64[x, y]
    key = Symbol("live_zone_", replace(String(command_id), r"[^A-Za-z0-9]" => "_"))
    z = CB.add_restriction_zone!(key, c, r)
    aid = assembly_at_zone(env, c, r)
    nl = "A human operator injected a no-go exclusion zone at ($(round(x; digits=2)), " *
         "$(round(y; digits=2))) with radius $(round(r; digits=2))." *
         (aid === nothing ? " Reroute robots around the forbidden region." :
          " It overlaps staging for assembly $aid; restage that assembly.")
    CB.record_ood_truth!(nl, CB.ZoneTruth(key, c, Float64(CB.get_radius(z)), aid); at=iter)
    # Scheduled OOD wrappers enqueue automatically, but a live command bypasses
    # that scheduler. Explicitly enqueue so respec_step! handles it immediately.
    CB.push_ood!(nl)
    println("[live] forbid zone id=$command_id center=($x,$y) r=$r assembly=$aid")
    return nothing
end

function command_file_hook(path)
    offset = Ref{Int64}(0)
    return function (env, factory_vis, anim, iter)
        isempty(path) && return nothing
        isfile(path) || return nothing
        open(path, "r") do io
            seek(io, min(offset[], filesize(path)))
            for line in eachline(io)
                isempty(strip(line)) && continue
                try
                    cmd = JSON3.read(line)
                    String(cmd[:type]) == "forbid_zone" &&
                        inject_live_zone!(env, Float64(cmd[:x]), Float64(cmd[:y]), Float64(cmd[:r]), String(cmd[:id]), iter)
                catch e
                    println("[live] rejected command: ", sprint(showerror, e))
                end
            end
            offset[] = position(io)
        end
        return nothing
    end
end
function inject_staging_zone!(env; frac = parse(Float64, get(ENV, "DEMO_ZONE_SCALE", "0.20")))
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
        overlap = min(0.25r, 0.5zr)
        offset = max(0.0, r + zr - overlap)
        work = CB._future_work_discs(env)
        candidates = [c .+ offset .* [cos(2pi*k/24), sin(2pi*k/24)]
                      for k in 0:23]
        candidates = [q for q in candidates if CB.zone_clears_root_goals(q, zr, env)]
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

# 제안(proposal)에서 표시용 매크로 이름·타깃 뽑기
function _proposal_macro(prop)
    (prop === nothing || isempty(prop.constraints)) && return ("NOOP", "")
    c0   = prop.constraints[1]
    name = string(typeof(c0).name.name)
    tgt  = try hasproperty(c0, :agent) ? _rl(c0.agent) :
               hasproperty(c0, :assembly) ? string(c0.assembly) : "" catch; "" end
    return (name, tgt)
end

# Resolve the truth record that emitted this exact queued event. Using the last
# truth record caused later internal recovery events to be mistaken for a second
# copy of the most recent zone event.
function truth_for_event(event)
    ev = String(event)
    log = CB.ood_truth_log()
    i = findlast(e -> String(e.nl) == ev, log)
    return i === nothing ? nothing : log[i]
end

# respec 패널 캡처. source="canonical" 또는 "claude-opus-4-8"(진짜 LLM). rationale 는 LLM 경로에서만 채워짐.
function capture!(env, truth, prop, nl; source = "canonical", rationale = "")
    macro_name, tgt = _proposal_macro(prop)
    kind = truth isa CB.FaultTruth ? "FAULT" : truth isa CB.BatteryTruth ? "BATTERY" :
           truth isa CB.ZoneTruth ? "ZONE" : "OOD"
    (truth isa CB.FaultTruth) && try CB.monitor_record_fault!(truth.robot) catch end
    verdict = "PENDING · awaiting verifier"
    cand = Dict("rank" => 1, "macro" => macro_name, "score" => source,
                "chosen" => true, "verified" => false,
                "decision_source" => source)
    isempty(rationale) || (cand["rationale"] = rationale)
    try
        CB.monitor_record_respec!(; at = length(env.cache.closed_set),
            input = Dict("event" => kind, "target" => tgt, "detail" => first(split(String(nl), "\n"))),
            candidates = [cand], chosen = strip("$(macro_name) $(tgt)"), verdict = verdict)
    catch end
end

# 완주 보장 enactment(검증된 manual-loop 경로). truth(고장/배터리/존)와 — 있으면 — LLM 이 고른 macro 를 반영.
#   prop 이 주어지면 그 매크로대로(ReplaceAgent→hot_swap, ForbidZone→restage, DeprioritizeAgent→SoC 회복+rebalance),
#   없거나 NOOP 면 truth 종류로 기본 복구. 어느 경로든 빌드가 멈추지 않게 함.
function enact_recovery!(env, truth, prop)
    macro_name, _ = _proposal_macro(prop)
    try
        if prop !== nothing && CB._is_robot_replace(prop)          # LLM: 로봇 고장 → 스페어 교체
            rid = first(c for c in prop.constraints if c isa CB.ReplaceAgent).agent
            CB.hot_swap_robot!(env, rid; mode = :via_depot, verbose = false)
            local f = CB.BATTERY_FLEET[]; (f !== nothing && haskey(f.soc, rid)) && (f.soc[rid] = 1.0)
        elseif prop !== nothing && CB._is_zone_respec(prop)        # LLM: 공간 no-go → 리스테이지
            truth isa CB.ZoneTruth && truth.assembly !== nothing &&
                CB.restage_assembly!(env, truth.assembly; resume = true, verbose = false)
        elseif prop !== nothing && CB._is_deprioritize(prop)       # LLM: 배터리 저하(soft) → SoC 회복 후 재분배(무정지)
            local f = CB.BATTERY_FLEET[]
            if truth isa CB.BatteryTruth && f !== nothing && haskey(f.soc, truth.robot)
                f.soc[truth.robot] = max(f.soc[truth.robot], 0.55)
            end
            CB.rebalance_for_battery!(env)
        else                                                       # NOOP/미상 or producer=canonical → truth 기반 기본 복구
            if truth isa CB.FaultTruth
                CB.hot_swap_robot!(env, truth.robot; mode = :via_depot, verbose = false)
            elseif truth isa CB.BatteryTruth
                if truth.soc_after <= CB.REPLACE_SOC_THRESHOLD[]
                    CB.hot_swap_robot!(env, truth.robot; mode = :via_depot, verbose = false)
                    local f = CB.BATTERY_FLEET[]; (f !== nothing && haskey(f.soc, truth.robot)) && (f.soc[truth.robot] = 1.0)
                else
                    CB.rebalance_for_battery!(env)
                end
            elseif truth isa CB.ZoneTruth && truth.assembly !== nothing
                CB.restage_assembly!(env, truth.assembly; resume = true, verbose = false)
            end
        end
    catch e
        println("[recover] ", typeof(truth).name.name, "/", macro_name, " FAILED: ",
                first(split(sprint(showerror, e), "\n")))
    end
    return nothing
end

# ---------------------------------------------------------------------------------------------
# 확률적 시점의 불발을 막는 재무장 래퍼.
#
# 왜 필요한가(실측): 고정 슬롯 시절에는 발화 지점이 늘 "적격 대상이 있는" 순간으로 손수 골라져 있었다.
# 시점을 추첨하기 시작하자 첫 실행부터 불발했다 — closed=77 에서 pick_solo_fault_target 이 단독 운반체를
# 하나도 못 찾아 fault_action 이 nothing 을 돌려줬고, 사건은 기록도 없이 사라졌다(스트림의 ood=[]).
# 무작위 시점이 "사건이 일어나지 않는" 이유가 되면 안 된다. 실패하면 조금 더 진행된 시점에 다시 시도한다.
#
# 액션이 nothing 을 돌려준다는 것은 **아무 상태도 바꾸지 못했다**는 뜻이므로(fault_robot! 은 대상이
# 없으면 즉시 return nothing) 재시도해도 이중 주입이 되지 않는다.
function retrying_action(inner; at::Int, every::Int, max_tries::Int = 200, tag::String = "ood")
    tries = Ref(0); nxt = Ref(at)
    function act(env)
        closed = length(env.cache.closed_set)
        nl = inner(env)
        if nl !== nothing
            println("[ood] $tag fired at step≈$(nxt[]) closed=$(closed)" *
                    (tries[] > 0 ? " (after $(tries[]) deferrals)" : ""))
        elseif tries[] < max_tries
            tries[] += 1
            nxt[] += every
            # 조용히 사라지지 않게 다음 스텝에 다시 무장한다. 액션이 nothing 을 돌려줬다는 것은
            # 아무 상태도 바꾸지 못했다는 뜻이므로(대상 없음) 재시도해도 이중 주입이 아니다.
            tries[] % 20 == 1 &&
                println("[ood] $tag no eligible target at step≈$(nxt[] - every) closed=$(closed) → deferring")
            CB.schedule_ood!(nxt[], act)
        else
            println("[ood] $tag GAVE UP at step≈$(nxt[]) closed=$(closed) after $(max_tries) deferrals " *
                    "— no feasible instant existed for the rest of the build")
        end
        return nl
    end
    return act
end

include(joinpath(@__DIR__, "policy.jl"))   # 결정 정책 레이어(canonical/surrogate/dspy 공용)

# producer(정책): 매 OOD 마다 **세 정책을 모두 계산·기록**하고, DEMO_POLICY 가 고른 매크로를
# DSL 제안으로 바꿔 프레임워크 dispatcher 에 넘긴다(검증된 restage/translate 경로를 그대로 씀).
# run_demo.jl 의 수동 루프와 동일한 decide_all 을 쓰므로 두 엔진의 결정이 어긋날 수 없다.
function policy_producer(env, event)
    rec = truth_for_event(event)
    rec === nothing && return nothing
    truth = rec.truth
    decision = decide_all(env, truth; nl = rec.nl)   # nl = LLM 이 읽을 자연어 관찰
    record_decision!(env, truth, decision, rec.nl)
    rt = decision.router
    get(rt, "enabled", false) && println("[router] $(rt["reason"]) → $(rt["target"])")
    println("[policy] $(typeof(truth).name.name) → $(decision.macro_name) " *
            "(enacted=$(decision.enacted); rule=$(decision.rule_macro), " *
            "surro=$(decision.policies["surrogate"]["chosen"]), dspy=$(decision.policies["dspy"]["chosen"]))")
    return macro_to_proposal(truth, decision.macro_name)
end

# producer(canonical): 최근 OOD truth → canonical 휴리스틱 분석 캡처 + 직접 복구 → nothing(dispatch 생략).
function canonical_producer(env, event)
    rec = truth_for_event(event)
    rec === nothing && return nothing
    truth = rec.truth
    prop  = try CB.canonical_respec(truth) catch; nothing end
    capture!(env, truth, prop, rec.nl; source = "canonical")
    # Return the proposal to the shared production dispatcher. It performs the
    # verified multi-assembly restage and whole-build translation fallback.
    return prop
end

# producer(LLM): 최근 OOD 의 자연어 설명을 **진짜 Claude API**(llm_to_proposal→Python 서비스)로 보내
#   검증된 DSL 제안을 받고(패널에 macro+rationale 표시), 그 결정대로 완주 보장 enactment 실행 → nothing.
#   LLM 호출/파싱 실패 시 canonical 로 안전 폴백(빌드 계속).
function llm_producer(env, event)
    rec = truth_for_event(event)
    truth = rec === nothing ? nothing : rec.truth
    nl    = String(event)
    prop  = try
        CB.llm_to_proposal(nl, env; id_resolver = ref -> CB._default_id_resolver(env, ref))
    catch e
        println("[llm] llm_to_proposal FAILED → canonical fallback: ",
                first(split(sprint(showerror, e), "\n")))
        nothing
    end
    if prop === nothing || isempty(prop.constraints)              # LLM 실패/빈 제안 → canonical
        truth === nothing && return nothing
        cprop = try CB.canonical_respec(truth) catch; nothing end
        capture!(env, truth, cprop, nl; source = "canonical (LLM fallback)")
        return cprop
    else
        rat = try prop.rationale catch; "" end
        println("[llm] Claude → ", _proposal_macro(prop)[1], "  rationale: ", first(split(String(rat), "\n")))
        capture!(env, truth, prop, nl; source = "claude-opus-4-8", rationale = rat)
        return prop
    end
end

const USE_LLM = get(ENV, "DEMO_LLM", "0") == "1"   # DEMO_LLM=1 → 진짜 Claude, 기본(0) → canonical 휴리스틱

pre = function (env)
    CB.enable_battery!(env; params = CB.demo_battery_params(shrink = 25.0))
    try CB.set_battery_penalty!(gain = 6.0, soc_target = 0.5, hard_mult = 1.0e3) catch end
    CB.RESPEC_ENABLED[] = true
    CB.set_hot_swap!(enabled = true, mode = :via_depot)
    CB.set_respec_producer!(USE_LLM ? llm_producer : policy_producer)
    CB.clear_ood_schedule!()
    empty!(CB.RESPEC_QUEUE.pending)
    CB.monitor_enable!(stream_path)
    n_total = Graphs.nv(env.sched)
    fr(f) = max(4, round(Int, f * n_total))
    slots = [0.10, 0.32, 0.55]
    kinds = case_kinds(OODC)
    initial_closed = length(env.cache.closed_set)
    has_zone = :zone in kinds
    robot_kinds = filter(k -> k !== :zone, kinds)
    # DEMO_N (const above) = how many OOD events to inject (0 = one per case kind, the original
    # behaviour). When >0 it OVERRIDES the fault/battery event count, cycling the case's robot kinds
    # across the build. A zone always fires ONCE up front: spatial re-staging is only transform-safe
    # before any build step opens.
    demo_n = DEMO_N
    if has_zone
        # Queue the zone before the first simulation step, while all affected assemblies
        # can still be safely re-staged.
        nl = inject_staging_zone!(env)
        nl === nothing || CB.push_ood!(nl)
    end
    n_robot = demo_n > 0 ? demo_n : length(robot_kinds)   # DEMO_N overrides the robot-OOD count
    # 로봇 OOD 가 들어갈 수 있는 진척 구간 [lo, hi] (닫힌 노드 수 단위).
    #   lo : 너무 이르면 아직 아무 일도 안 벌어진 빈 현장에서 터진다.
    #   hi : 너무 늦으면 복구할 일이 남아 있지 않아 어떤 정책을 써도 결과가 같다.
    # zone 케이스에서는 lo 를 더 밀어 둔다 — sim 전에 심은 존의 기하 복구(restage)와 같은 배치에서
    # 건강 사건 인계가 겹치면 안 되기 때문(기존 고정 스케줄의 recovery_fraction 가드와 같은 뜻).
    lo = fr(0.10)
    hi = fr(0.75)
    if has_zone
        lo = max(lo, fr(0.32), initial_closed + max(10, round(Int, 0.08 * n_total)))
    end
    hi = max(hi, lo + max(4, round(Int, 0.10 * n_total)))
    if get(ENV, "DEMO_PROBE", "0") == "1"
        # 진단 모드: OOD 를 넣지 않고 "어느 진척 구간에서 어떤 사건이 **가능한가**"만 훑는다.
        # 확률적 시점을 도입하면서 알게 된 것 — safe fault 는 단독 운반체가 있을 때만 가능하고,
        # 그 구간은 빌드 초반에 몰려 있다. 창을 추측으로 정하지 않으려면 이 측정이 필요하다.
        # 스텝 단위로 훑는다. closed 단위는 너무 성기다 — tractor 는 **첫 스텝에 이미 54 개**가 닫혀
        # 있어서(모션 없이 닫히는 노드가 많다) closed 로는 초반을 전혀 분해하지 못한다.
        # 판정은 fault_robot!(safe=true) 와 **같은 두 단계**를 그대로 쓴다(strict → frontier 폴백).
        probe = nothing
        probe_step = try parse(Int, get(ENV, "DEMO_PROBE_EVERY", "20")) catch; 20 end
        probe_next = Ref(probe_step)
        probe = function (env)
            closed = length(env.cache.closed_set)
            strict = try CB.pick_solo_fault_target(env) catch e; "ERR:" * string(typeof(e)) end
            front  = try CB.pick_solo_frontier_target(env) catch e; "ERR:" * string(typeof(e)) end
            ok = (strict !== nothing && !(strict isa String)) || (front !== nothing && !(front isa String))
            println("[probe] closed=$closed strict=$(strict === nothing ? "-" : string(strict)) " *
                    "frontier=$(front === nothing ? "-" : string(front)) faultable=$(ok ? "YES" : "no")")
            probe_next[] += probe_step
            CB.schedule_ood!(probe_next[], probe)
            return nothing
        end
        CB.schedule_ood!(probe_step, probe)
        println(">>> PROBE MODE: no OOD injected; scanning fault feasibility every $probe_step sim steps")
    elseif DEMO_SEED > 0 && !isempty(robot_kinds)
        # --- 확률적 스케줄(기본) -------------------------------------------------------------
        # **스텝 단위**로 뽑는다. closed(완료 노드 수) 단위는 초반을 전혀 분해하지 못한다 --
        # tractor 는 모션 없이 닫히는 노드가 많아 첫 스텝에 이미 54/313 이 닫혀 있다(측정).
        #
        # 창은 종류마다 다르다. 이것도 측정 결과다(DEMO_PROBE=1 로 재현 가능):
        #   · battery : 건강한 로봇만 있으면 되므로 빌드 어디서나 가능 -> 넓은 창
        #   · fault(safe) : 단독 운반체(또는 solo frontier carry)가 있어야 하는데, tractor 에서 그 조건은
        #     step 2~20 에만 성립하고 그 뒤로는 전 구간 불가능하다. 창을 넓게 잡으면 사건이 통째로
        #     사라진다(실제로 첫 확률 실행이 그렇게 불발했다).
        # 창 밖으로 뽑혀도 아래 retrying_action 이 **다음 가능한 순간까지 미룬다**.
        parse_win = function (s, dflt)
            try
                p = split(s, ","); (parse(Int, strip(p[1])), parse(Int, strip(p[2])))
            catch; dflt end
        end
        fault_win = parse_win(get(ENV, "DEMO_FAULT_STEPS", ""), FAULT_SAFE ? (2, 20) : (60, 600))
        batt_win  = parse_win(get(ENV, "DEMO_BATTERY_STEPS", ""), (40, 700))
        if has_zone
            # 존 케이스는 sim 전에 심은 존의 기하 복구(restage)가 먼저 끝나야 한다. 건강 사건이 같은
            # 배치에 끼면 스케줄이 엉킨다 -- 고정 슬롯 시절의 recovery_fraction 가드와 같은 뜻.
            fault_win = (max(fault_win[1], 6), max(fault_win[2], 26))
            batt_win  = (max(batt_win[1], 60), batt_win[2])
        end
        rng = Random.MersenneTwister(DEMO_SEED)
        for j in 1:n_robot
            kind = robot_kinds[rand(rng, 1:length(robot_kinds))]     # 종류도 추첨(mixed 케이스는 순서까지 달라짐)
            win  = kind === :fault ? fault_win : batt_win
            at   = rand(rng, win[1]:win[2])
            inner = kind === :fault ?
                CB.fault_action(; safe = FAULT_SAFE, obstacle = false) :
                CB.battery_action(soc_drop = (DEMO_BSEVERE > 0 && rand(rng) < DEMO_BSEVERE ?
                                              1.0 : DEMO_BSOC))
            CB.schedule_ood!(at, retrying_action(inner; at = at,
                                                 every = kind === :fault ? 2 : 8,
                                                 max_tries = 300, tag = String(kind)))
            println("    · $(kind) drawn at step=$(at)  (window $(win[1])–$(win[2]), safe_fault=$(FAULT_SAFE))")
        end
    else
        # --- 옛 고정 슬롯 스케줄(DEMO_SEED=0, 재현용) ------------------------------------------
        for j in 1:n_robot
            isempty(robot_kinds) && break
            kind = robot_kinds[((j - 1) % length(robot_kinds)) + 1]   # cycle fault/battery across N events
            frac = demo_n > 0 ? (n_robot == 1 ? 0.10 : 0.10 + 0.65 * (j - 1) / (n_robot - 1)) :
                                slots[min(j, 3)]                      # original slot placement when DEMO_N=0
            at = fr(frac)
            if has_zone
                # Keep a health hand-off out of the same simulation batch as the pre-build geometry recovery.
                recovery_fraction = kind === :fault ? 0.20 : 0.32
                at = max(at, fr(recovery_fraction), initial_closed + max(10, round(Int, 0.08 * n_total)))
            end
            if kind === :fault
                # A breakdown is an asset-health event, not an implicit spatial exclusion zone. obstacle=false
                # avoids creating a hidden second zone that could block compound Break+Zone construction.
                CB.schedule_ood_at_closed!(at, CB.fault_action(; safe = true, obstacle = false))
            elseif kind === :battery
                # soc_drop 은 DEMO_BSOC 로 조절한다(기본 0.9 = 심각 -> 규칙이 ReplaceAgent 를 냄).
                # 0.45 정도면 애매한 구간이 되어 정책마다 답이 갈린다(대시보드 ⑦ Battery (mild)).
                CB.schedule_ood_at_closed!(at, CB.battery_action(soc_drop = DEMO_BSOC))
            end
        end
    end
    n_zone = (:zone in kinds) ? 1 : 0                     # zone is ALWAYS fixed at 1 (transform-safe)
    rk_str = isempty(robot_kinds) ? "none" : join(string.(robot_kinds), "/")
    n_tag = demo_n > 0 ? " (DEMO_N)" : ""
    sched_tag = DEMO_SEED > 0 ? "stochastic seed=$(DEMO_SEED), step-window draw" : "fixed slots (legacy)"
    println(">>> OOD armed: zone×$(n_zone) [pre-sim, fixed] + $(rk_str)×$(n_robot)$(n_tag) [$sched_tag]" *
            "  model=$MODEL scale=$SCALE robots=$NROB")
    if !isempty(COMMAND_FILE)
        control = command_file_hook(COMMAND_FILE)
        CB.monitor_set_control_hook!(control)
        if INTERACTIVE
            println(">>> interactive ready: waiting for first operator command")
            deadline = time() + 300.0
            while (!isfile(COMMAND_FILE) || filesize(COMMAND_FILE) == 0) && time() < deadline
                sleep(0.2)
            end
            # Apply the initial zone before the first motion/planning step. This
            # keeps all physical parts relocatable by the production respec path.
            control(env, nothing, nothing, 0)
        end
    end
end

render_result = Ref{Any}(nothing)
try
    # -----------------------------------------------------------------------------------------
    # save_animation 은 **라이브 시청과 상호배타적**이다.
    #
    # animate_update_visualizer!(render_tools.jl) 은 anim 이 있으면 갱신을 `atframe(...)` 안에서
    # 수행한다 = 그 스텝의 변환을 **애니메이션에 기록만 하고 라이브 장면에는 적용하지 않는다.**
    # 그래서 save_animation=true 로 라이브 세션을 열면 MeshCat 화면은 초기 배치 이후 그대로 멈춰
    # 있고, 브라우저는 주기적으로 발행되는 짧은 녹화(예: 5.4 초짜리)를 재생할 뿐이다 --
    # "시뮬레이션이 5 초 만에 멈춘 것처럼" 보이는 정체가 이것이다.
    #
    # 그래서 사람이 개입하는 세션(MONITOR_INTERACTIVE=1)에서는 애니메이션을 끄고 라이브 장면을
    # 직접 구동한다. 대신 그 런은 anim html 산출물을 남기지 않는다(스트림은 그대로 기록되므로
    # 왼쪽 패널 재생·검증에는 아무 지장이 없다). 배치 렌더(비대화형)는 예전과 동일하다.
    render_result[] = CB.run_lego_demo(;
        ldraw_file = MODEL, project_name = "$(model_base)_render", num_robots = NROB,
        model_scale = SCALE, assignment_mode = :greedy,
        save_animation = !INTERACTIVE, anim_active_agents = true, anim_active_areas = true,
        update_anim_at_every_step = INTERACTIVE,   # 라이브에서는 매 스텝 장면을 밀어 준다
        overwrite_results = true, n_spare_per_pool = 2, pre_sim_hook = pre,
        max_num_iters_no_progress = 3000, rng = Random.MersenneTwister(1))
finally
    CB.monitor_disable!()
    try CB.monitor_clear_control_hook!() catch end
    try CB.clear_respec_producer!() catch end
    CB.RESPEC_ENABLED[] = false
end

render_result[] === nothing && error("render did not return a simulation environment")
render_env, _render_stats = render_result[]

# 대화형 세션은 애니메이션을 만들지 않는다(위 주석). 사람이 개입하는 런은 완주하지 않는 것이 정상이므로
# (원하는 지점에서 멈추거나, 주입한 존이 감당 못 할 만큼 클 수도 있다) 미완주를 오류로 보지 않는다.
if INTERACTIVE
    n_live = isfile(stream_path) ? countlines(stream_path) : 0
    println("[render] DONE (interactive) — case=$CASE_TAG  $n_live frames, live view driven directly " *
            "(no anim artifact)  complete=$(CB.project_complete(render_env))")
    exit(0)
end

CB.project_complete(render_env) ||
    error("refusing to publish incomplete animation for model=$MODEL case=$OODC")

viz = joinpath(dirname(pathof(CB)), "..", "results", "$(model_base)_render",
               "greedy_RVO_Dispersion_TangentBug", "visualization.html")
if isfile(viz)
    cp(viz, joinpath(anim_dir, "$(model_base)__$(CASE_TAG)$(NSUF).html"); force = true)
    println("[render] anim → anim/$(model_base)__$(CASE_TAG)$(NSUF).html")
else
    println("[render] visualization.html not found at ", viz)
end
n = isfile(stream_path) ? countlines(stream_path) : 0
println("[render] DONE — case=$OODC  $n frames + anim")
