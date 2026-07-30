# tools/monitor/smoke_ood_run.jl
# -----------------------------------------------------------------------------
# OOD 가 주입되는 tractor 데모 + monitor 스트림 생성.
#   · producer = B1 canonical_respec (baselines.jl) — 검증된 규칙맵:
#       fault                         → ReplaceAgent (스페어 1:1 hot-swap)
#       battery SoC ≤ REPLACE 임계     → ReplaceAgent (깊은 방전=하드 교체)
#       battery SoC >  임계            → DeprioritizeAgent (가벼운 열화=소프트 강등)
#       zone (staging 차단)            → ForbidZone (그 조립체를 존 밖으로 restage)
#   · 배터리 용량을 완만하게(shrink 작게) → 자연 방전이 0에 안 닿고, 오직 주입된 severe 만 저SoC.
#   · fault/replace 는 scene-tree 수술이라 MeshCat 애니와 충돌 → save_animation=false.
# 실행:  julia +lts --project=. tools/monitor/smoke_ood_run.jl
# -----------------------------------------------------------------------------
using ConstructionBots
using Random
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))   # battery/ood_stream/ood_truth/baselines 로드

here = @__DIR__
ENV["MONITOR_STREAM"] = joinpath(here, "monitor_stream.jsonl")          # emit 자동 활성

# 로봇 id 를 깔끔한 라벨로: BotID{...}(7) 대신 "R7"
_rl(rid) = try "R" * string(getfield(rid, :id)) catch; replace(string(rid), r"\s+" => " ") end

# ---- staging 을 실제로 막는 no-go 존 주입(→ ForbidZone restage 가 정답이 되도록) ----
# demos.jl 의 place_blocking_zone! 과 동일 로직: 아직 안 놓인 조립물의 staging circle 위에 존을 겹침.
const _ZONE_CT = Ref(0)
function inject_staging_zone!(env; frac = 0.9)
    isempty(env.staging_circles) && return nothing
    ks   = collect(keys(env.staging_circles))
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), ks)   # 루트(전체)는 제외
    for (aid, ball) in env.staging_circles
        aid == root && continue
        ac = try CB._assembly_complete_node(env, aid) catch; nothing end
        ac === nothing && continue
        v = try CB.get_vtx(env.sched, CB.node_id(ac)) catch; nothing end
        (v === nothing || v in env.cache.closed_set || v in env.cache.active_set) && continue  # 이미 놓였거나 진행중이면 스킵
        c = Vector{Float64}(CB.get_center(ball)[1:2]); r = Float64(CB.get_radius(ball))
        _ZONE_CT[] += 1; key = Symbol("zone_inj_$(_ZONE_CT[])")
        z = CB.add_restriction_zone!(key, c, r * frac)
        nl = "A no-go exclusion zone has appeared at ($(round(c[1]; digits = 2)), $(round(c[2]; digits = 2))) " *
             "blocking a staging area; restage the affected assembly out of the restricted region."
        try CB.record_ood_truth!(nl, CB.ZoneTruth(key, Float64[c[1], c[2]], Float64(CB.get_radius(z)), aid)) catch end
        return nl
    end
    return nothing
end

# ---- producer: 최근 기록된 OOD truth 를 B1 규칙맵으로 올바른 DSL 로 변환 ----
function canonical_producer(env, event)
    log = CB.ood_truth_log()
    isempty(log) && return nothing
    truth = last(log).truth
    prop  = try CB.canonical_respec(truth) catch; return nothing end
    (prop === nothing || isempty(prop.constraints)) && return nothing   # nav-zone 등 계획 DSL 불필요(모션 우회)
    c0    = prop.constraints[1]
    macro_name = string(typeof(c0).name.name)                           # ReplaceAgent/DeprioritizeAgent/ForbidZone
    tgt   = try
        hasproperty(c0, :agent) ? _rl(c0.agent) : hasproperty(c0, :assembly) ? string(c0.assembly) : ""
    catch; "" end
    kind  = truth isa CB.FaultTruth ? "FAULT" : truth isa CB.BatteryTruth ? "BATTERY" :
            truth isa CB.ZoneTruth ? "ZONE" : "OOD"
    try
        (truth isa CB.FaultTruth) && CB.monitor_record_fault!(truth.robot)
        CB.monitor_record_respec!(; at = length(env.cache.closed_set),
            input = Dict("event" => kind, "target" => tgt,
                         "detail" => first(split(last(log).nl, "\n"))),
            candidates = [Dict("rank" => 1, "macro" => macro_name, "score" => "B1-rule",
                               "chosen" => true, "verified" => true)],
            chosen = strip("$(macro_name) $(tgt)"), verdict = "ADMITTED · B1 canonical")
    catch end
    return prop
end

pre = function (env)
    CB.enable_battery!(env; params = CB.demo_battery_params(shrink = 25.0))    # 완만한 용량(자연 방전이 0에 안 닿게)
    try CB.set_battery_penalty!(gain = 6.0, soc_target = 0.5, hard_mult = 1.0e3) catch end
    CB.RESPEC_ENABLED[] = true
    CB.set_respec_producer!(canonical_producer)
    CB.clear_ood_schedule!()
    # 1 fault(→Replace) + 1 severe battery(→Replace) + 1 staging-zone(→ForbidZone restage)
    CB.schedule_random_ood!(; n = 1, kinds = [:fault],   closed_lo = 18, closed_hi = 32, seed = 3, safe_fault = true)
    CB.schedule_random_ood!(; n = 1, kinds = [:battery], closed_lo = 55, closed_hi = 80, seed = 5,
                            battery_severe_frac = 1.0, severe_soc_drop = 1.0)  # 깊은 방전 → ReplaceAgent
    CB.schedule_ood_at_closed!(105, inject_staging_zone!)                      # staging 차단 → ForbidZone
    println(">>> OOD demo armed: fault + severe-battery(→Replace) + staging-zone(→ForbidZone), producer=B1 canonical")
end

try
    CB.run_lego_demo(; ldraw_file = "tractor.mpd", project_name = "tractor_ood", num_robots = 10,
        assignment_mode = :greedy, save_animation = false, overwrite_results = true,
        n_spare_per_pool = 2, pre_sim_hook = pre, rng = Random.MersenneTwister(1))
finally
    CB.monitor_disable!()
    try CB.clear_respec_producer!() catch end
    CB.RESPEC_ENABLED[] = false
end

n = isfile(ENV["MONITOR_STREAM"]) ? countlines(ENV["MONITOR_STREAM"]) : 0
println("[ood] DONE — ", n, " frames → ", ENV["MONITOR_STREAM"])
