# =============================================================================
# probe_fire_points.jl -- "이 진행도에서 그 OOD 를 애초에 터뜨릴 수 있는가?" 를 값싸게 스캔한다.
#
# WHY THIS EXISTS
# ---------------
# `gen_oracle_dataset.jl` 의 FIRE_POINTS 는 (12,20,30,45,60) 처럼 **초반 값들**이다. 그런데 tractor
# 는 첫 시뮬 배치에서 이미 ~58 노드를 닫으므로, 그 다섯 시점이 **전부 같은 순간에 due** 가 되어
# 실제 발화점은 항상 closed=50 또는 58 하나로 붕괴한다(실측: openworld_merged.jsonl 60 인스턴스의
# closed_at_fire ∈ {50,58}, progress sd=0.005). 그 결과 novelty 교정의 `progress` 축이 사실상 점
# 하나가 되고, 배포 데모처럼 중반에 터지는 battery 는 z=45 → cap(8) 로 잘려도 혼자 score 를 지배해
# **종류와 무관하게 novel** 로 판정된다.
#
# 고치려면 발화 시점을 instance 차원으로 올려 여러 진행도에서 라벨을 만들어야 한다. 그런데 아무
# 진행도에서나 사건이 성립하지는 않는다:
#   · fault    : 안전한 대상(단독 운반 로봇)이 그 순간 존재해야 한다. 후반엔 없을 수 있다.
#   · zoneblk  : **아직 안 끝난** staging 원이 있어야 막을 대상이 생긴다. 후반엔 없을 수 있다.
#   · battery  : 건강한 활성 로봇만 있으면 되므로 거의 항상 가능하다.
# 몇 시간짜리 라벨링을 돌린 뒤에 "그 시점엔 사건이 안 터졌다"를 발견하는 것을 막기 위해, 이 스크립트가
# **시뮬 한 판**만 돌면서 진행도별로 세 종류의 발화 가능성을 표로 찍는다.
#
# 실행 (ConstructionBots.jl 저장소 루트에서):
#   julia +lts --project=. wm4spacecraft_manufacturing/oracle/probe_fire_points.jl
# ENV:
#   PF_EVERY   진행도 스캔 간격(닫힌 노드 수). 기본 20
#   PF_FROM    스캔 시작점. 기본 40
#   PF_TO      스캔 끝점.   기본 300
#   PF_SPARE   n_spare_per_pool. 기본 3
#   PF_SEED    난수 씨앗.  기본 1
#   PF_OUT     결과 CSV 경로. 기본 out/fire_probe.csv
#
# [Julia 문법 참고]
#   · Ref(x)            : 한 칸짜리 상자. `[]` 로 읽고 쓴다(전역 가변 상태).
#   · try f() catch; d end : 오류 나면 조용히 d 를 쓴다(방어적 코드).
#   · x === nothing     : "값이 없음" 비교는 == 가 아니라 === 로 한다.
# =============================================================================
import ConstructionBots as CB
import HiGHS, Logging, Random, Graphs
using Printf

# navigator 계층(battery/ood_stream/ood_truth/baselines)은 런타임 include 다 — `_pick_battery_target`
# 를 부르려면 여기서도 로드해야 한다(gen_oracle_dataset.jl 과 같은 방식).
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 60.0, "mip_rel_gap" => 0.05,
    "output_flag" => false, "presolve" => "on")

const EVERY = parse(Int, get(ENV, "PF_EVERY", "20"))
const FROM  = parse(Int, get(ENV, "PF_FROM",  "40"))
const TO    = parse(Int, get(ENV, "PF_TO",    "300"))
const SPARE = parse(Int, get(ENV, "PF_SPARE", "3"))
const SEED  = parse(Int, get(ENV, "PF_SEED",  "1"))
const OUT   = get(ENV, "PF_OUT", joinpath(@__DIR__, "out", "fire_probe.csv"))

# gen_oracle_dataset.jl 의 동명 함수와 **같은 로직**(복사본). 라벨러가 실제로 쓰는 1순위 피커라
# 여기서 다른 판정을 내면 프로브가 거짓말을 한다.
function single_solo_fault_target(env)
    sched = env.sched; cands = CB.RobotID[]
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.RobotGo || continue
        rid = try CB.entity(n).id catch; nothing end
        rid isa CB.RobotID || continue
        (try CB.is_spare(rid) || CB.is_recovery_spare(rid) catch; false end) && continue
        CB._first_pending_assignment(env, rid) === nothing && continue
        n_slots = 0; all_solo = true
        for w in Graphs.vertices(sched)
            w in env.cache.closed_set && continue
            m = CB.get_node_from_id(sched, CB.get_vtx_id(sched, w))
            m isa CB.RobotGo || continue
            (try CB.entity(m).id == rid catch; false end) || continue
            outs = Graphs.outneighbors(sched, w); isempty(outs) && continue
            fn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, outs[1]))
            fn isa CB.FormTransportUnit || continue
            n_slots += 1
            (try length(CB.robot_team(CB.entity(fn))) == 1 catch; false end) || (all_solo = false)
        end
        (n_slots == 1 && all_solo) && push!(cands, rid)
    end
    isempty(cands) && return nothing
    return sort(cands, by = r -> r.id)[1]
end

"아직 **안 닫힌** staging 원의 개수 = zoneblk 가 막을 수 있는 대상 수(0 이면 zone 사건 자체가 무의미)."
function pending_staging(env)
    n = 0
    for (aid, _) in env.staging_circles
        ac = try CB._assembly_complete_node(env, aid) catch; nothing end
        ac === nothing && continue
        v = try CB.get_vtx(env.sched, CB.node_id(ac)) catch; nothing end
        (v === nothing || v in env.cache.closed_set) && continue
        n += 1
    end
    return n
end

"""
왜 안전한 fault 대상이 없는가를 **진단**한다.

`pick_solo_frontier_target` 은 "다음(frontier) 운반팀 크기 == 1" 인 로봇을 찾는다. 그게 실패할 때
이유는 둘 중 하나이고, 둘은 처방이 완전히 다르다:

  (a) pending frontier 를 가진 활성 로봇이 아예 없다  -> 술어가 아니라 **시점**의 문제
  (b) 있지만 그 운반팀이 전부 2대 이상이다            -> 술어를 고쳐도 소용없다. 다중로봇 운반팀을
      Replace 가 복구하지 못하는 **엔진 쪽 한계**(route_planning.jl 의 has_edge @assert)가 진짜 벽

그래서 frontier 팀 크기의 히스토그램을 그대로 찍는다.
"""
function frontier_team_sizes(env)
    sched = env.sched; sizes = Int[]
    for v in env.cache.active_set
        node = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        node isa CB.RobotGo || continue
        rid = try CB.entity(node).id catch; nothing end
        rid isa CB.RobotID || continue
        (try CB.is_spare(rid) || CB.is_recovery_spare(rid) catch; false end) && continue
        fa = try CB._first_pending_assignment(env, rid) catch; nothing end
        fa === nothing && continue                      # pending frontier 없음 = (a) 쪽
        sz = 0
        for v2 in Graphs.outneighbors(sched, fa[2])
            n2 = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v2))
            if n2 isa CB.FormTransportUnit
                sz = length(CB.robot_team(CB.entity(n2))); break
            end
        end
        sz > 0 && push!(sizes, sz)
    end
    return sizes
end

"""
HOT-SWAP 세계에서 안전한 고장 대상 후보 (2026-08-04 추가).

`pick_solo_*` 두 피커는 전부 `_first_pending_assignment` 를 요구한다. 그 술어는 "아직 안 닫힌
RobotGo 인데 **선행자가 RobotStart 이거나 이미 closed**" 인 노드, 즉 **깨끗한 작업 경계**에 서 있는
로봇만 통과시킨다. 빌드가 굴러가기 시작하면 로봇 대부분은 운반 사슬(FTU→TUGo→DepositCargo) 안에
들어가 있고 그 경계에 잠깐만 머무르므로, 중반 이후 스냅샷에서는 후보가 0 이 된다(실측 fire_probe_why).

그런데 그 술어가 지키려던 것은 **스케줄 재각인(re-stamp) 경로**의 제약이다: 고장 로봇의 배정
엣지를 예비에게 넘겨야 하니 넘길 엣지(=frontier)가 있어야 하고, 다인 운반팀 한가운데면
route_planning.jl 의 `@assert has_edge(scene_tree, agent, robot_id)` 가 터진다.

정체성 보존 **HOT-SWAP** 은 id 를 유지한 채 본체만 창고에서 갈아끼우므로 넘길 엣지 자체가 필요
없고 운반 도중에도 안전하다 — 엔진 안에서 이미 그렇게 판정하고 있다:
`src/mdp/hazard.jl:454 (_hz_safe_target)` 과 `src/navigator/battery.jl:505` 이 같은 예외를 둔다.

그래서 hot-swap 세계의 올바른 안전 조건은 훨씬 넓다:
  · 예비/복구 예비가 아니고,
  · **아직 안 닫힌 FormTransportUnit 팀의 멤버**다(= 앞으로 할 운반 일이 남아 있다 = 고장이 결과를 낳는다).
이 함수는 그 후보 집합과, 그중 **지금 진행 중인 팀**(active_set 에 든 FTU)의 멤버 수를 함께 센다.
"""
function hotswap_fault_candidates(env)
    sched = env.sched
    cands = Set{CB.RobotID}(); inprog = Set{CB.RobotID}()
    for v in Graphs.vertices(sched)
        v in env.cache.closed_set && continue            # 이미 끝난 운반은 남은 일이 아니다
        node = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        node isa CB.FormTransportUnit || continue
        team = try CB.robot_team(CB.entity(node)) catch; nothing end
        team === nothing && continue
        for (rid, _) in team
            rid isa CB.RobotID || continue
            (try CB.is_spare(rid) || CB.is_recovery_spare(rid) catch; false end) && continue
            push!(cands, rid)
            (v in env.cache.active_set) && push!(inprog, rid)   # 지금 형성/운반 중인 팀 = 가장 결과가 큰 대상
        end
    end
    return (sort(collect(cands), by = r -> r.id), sort(collect(inprog), by = r -> r.id))
end

"""
`_pick_battery_target` 의 **수정 전(OLD)** 사본 (2026-08-05).

수정 전 순서는 (1) pick_solo_fault_target → (2) pick_solo_frontier_target →
(3) `_first_pending_assignment` 를 통과하는 비-예비 로봇 중 SoC 최고 → (4) `_pick_low_margin_robot`
(= 전체에서 SoC 최고, **예비 포함**) 이었다. (1)~(3)이 전부 `_first_pending_assignment` 에 의존하므로
중반 이후 전부 실패하고 (4)로 떨어지는데, 주차된 예비는 전원이 꺼져 있어 SoC 가 안 닳으므로 (4)는
**항상 주차된 예비**를 고른다 = 배터리 사건이 무해해진다.

여기서는 그 옛 경로를 그대로 재현해 새 피커와 나란히 찍어, 그 주장이 실제로 참인지 **측정**한다.
"""
function pick_battery_target_OLD(env, fleet)
    isempty(fleet.soc) && return nothing
    for f in (CB.pick_solo_fault_target, CB.pick_solo_frontier_target)
        rid = try f(env) catch; nothing end
        rid !== nothing && haskey(fleet.soc, rid) && return rid
    end
    working = [id for (id, s) in fleet.soc
               if s > fleet.params.floor_soc &&
                  !(try CB.is_spare(id) catch; false end) &&
                  (try CB._first_pending_assignment(env, id) !== nothing catch; false end)]
    isempty(working) || return argmax(id -> fleet.soc[id], working)
    return CB._pick_low_margin_robot(fleet)
end

"그 로봇이 '남은 운반 일'을 가지고 있는가 = 안 닫힌 FormTransportUnit 팀의 멤버인가."
function owns_carry_work(env, rid)
    sched = env.sched
    for v in Graphs.vertices(sched)
        v in env.cache.closed_set && continue
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.FormTransportUnit || continue
        (try haskey(CB.robot_team(CB.entity(n)), rid) catch; false end) && return true
    end
    return false
end

"배터리 사건 대상이 될 수 있는 로봇 수(예비·복구 로봇 제외한 활성 일반 로봇)."
function battery_targets(env)
    n = 0
    for v in env.cache.active_set
        node = CB.get_node_from_id(env.sched, CB.get_vtx_id(env.sched, v))
        rid = try CB.entity(node).id catch; nothing end
        rid isa CB.RobotID || continue
        (try CB.is_spare(rid) || CB.is_recovery_spare(rid) catch; false end) && continue
        n += 1
    end
    return n
end

const ROWS = Ref(Vector{NamedTuple}())

"한 진행도 지점에서 세 종류의 발화 가능성을 기록한다(물리 상태는 절대 안 건드림)."
function probe_once(env)
    closed = length(env.cache.closed_set)
    total  = length(CB.get_nodes(env.sched))
    single = try single_solo_fault_target(env) catch; nothing end
    solo   = try CB.pick_solo_fault_target(env) catch; nothing end
    front  = try CB.pick_solo_frontier_target(env) catch; nothing end
    fts = try frontier_team_sizes(env) catch; Int[] end
    hs, hsp = try hotswap_fault_candidates(env) catch; (CB.RobotID[], CB.RobotID[]) end
    # --- battery 대상 피커: 수정 전 vs 수정 후를 나란히 (2026-08-05) ---
    fleet = CB.BATTERY_FLEET[]
    bold  = fleet === nothing ? nothing : (try pick_battery_target_OLD(env, fleet) catch; nothing end)
    bnew  = fleet === nothing ? nothing : (try CB._pick_battery_target(env, fleet) catch; nothing end)
    isspare(r) = r === nothing ? false : (try CB.is_spare(r) || CB.is_recovery_spare(r) catch; false end)
    haswork(r) = r === nothing ? false : (try owns_carry_work(env, r) catch; false end)
    row = (closed = closed, total = total, progress = total > 0 ? closed / total : 0.0,
           n_active = length(env.cache.active_set),
           spares = (try length(CB.active_spares()) catch; 0 end),
           fault_single = single !== nothing, fault_solo = solo !== nothing,
           fault_frontier = front !== nothing,
           zone_pending = pending_staging(env), battery_targets = battery_targets(env),
           n_frontier = length(fts), fts_min = isempty(fts) ? 0 : minimum(fts),
           fts_hist = join(sort(fts), "|"),
           n_hotswap = length(hs), n_hotswap_inprog = length(hsp),
           hotswap_pick = isempty(hs) ? 0 : first(hs).id,
           batt_old = bold === nothing ? 0 : bold.id, batt_old_spare = isspare(bold),
           batt_old_work = haswork(bold),
           batt_new = bnew === nothing ? 0 : bnew.id, batt_new_spare = isspare(bnew),
           batt_new_work = haswork(bnew))
    push!(ROWS[], row)
    @printf("[probe] closed=%3d/%3d prog=%.3f act=%2d sp=%2d | fault: single=%s solo=%s frontier=%s hotswap=%2d(진행중 %2d) | zone_pending=%2d | batt_tgt=%2d | frontier팀크기 n=%d min=%d [%s]\n",
            row.closed, row.total, row.progress, row.n_active, row.spares,
            row.fault_single ? "Y" : "-", row.fault_solo ? "Y" : "-", row.fault_frontier ? "Y" : "-",
            row.n_hotswap, row.n_hotswap_inprog,
            row.zone_pending, row.battery_targets, row.n_frontier, row.fts_min, row.fts_hist)
    @printf("        battery 대상: OLD=R%-3d(예비 %s, 남은일 %s)  NEW=R%-3d(예비 %s, 남은일 %s)\n",
            row.batt_old, row.batt_old_spare ? "Y" : "-", row.batt_old_work ? "Y" : "-",
            row.batt_new, row.batt_new_spare ? "Y" : "-", row.batt_new_work ? "Y" : "-")
    return nothing   # nothing 을 돌려주면 respec 큐에 아무것도 안 들어간다 = 순수 관찰
end

function main()
    for f in (:clear_ood_schedule!, :clear_restriction_zones!, :clear_spare_pools!,
              :clear_faulted_robots!, :clear_recovery_spares!, :clear_ood_truth_log!,
              :clear_wedge_edges!, :clear_stalled_robots!)
        try getproperty(CB, f)() catch end
    end
    try CB.set_reform_interval!(parse(Int, get(ENV, "DS_REFORM", "120"))) catch end
    # PF_BATT=1(기본): 배터리 회계를 켜서 BATTERY_FLEET 이 존재하게 한다 — 그래야 battery 대상
    # 피커(OLD/NEW)를 실제로 호출해 비교할 수 있다. stall/derate 는 켜지 않는다(궤적을 바꾸지
    # 않고 관찰만 하기 위해서 — 회계 자체는 SoC 장부만 갱신하고 모션에 손대지 않는다).
    if get(ENV, "PF_BATT", "1") == "1"
        CB.schedule_ood_at_closed!(1, function (env)
            try CB.enable_battery!(env; params = CB.demo_battery_params(
                    shrink = parse(Float64, get(ENV, "DS_SHRINK", "200.0"))))
            catch e; @warn "enable_battery! failed" exception = e end
            return nothing
        end)
    end
    pts = collect(FROM:EVERY:TO)
    for c in pts; CB.schedule_ood_at_closed!(c, probe_once); end
    println("[probe] scanning closed = $(pts) (spare=$(SPARE) seed=$(SEED))")
    CB.RESPEC_ENABLED[] = true
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try
                   res[] = CB.run_lego_demo(; ldraw_file = "tractor.mpd", num_robots = 10,
                       assignment_mode = :greedy, milp_optimizer = :highs,
                       optimizer_time_limit = 60, log_level = Logging.Warn,
                       max_num_iters_no_progress = parse(Int, get(ENV, "DS_NOPROG", "8000")),
                       rvo_flag = true, tangent_bug_flag = true, dispersion_flag = true,
                       n_spare_per_pool = SPARE, save_animation = false,
                       open_animation_at_end = false, write_results = false,
                       overwrite_results = true, return_env_before_sim = false,
                       rng = Random.MersenneTwister(SEED))
               catch e; err[] = (e, catch_backtrace())
               finally done[] = true end), nothing, parse(Int, get(ENV, "DS_STACK", "2000000000")))
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr))

    mkpath(dirname(OUT))
    open(OUT, "w") do io
        println(io, "closed,total,progress,n_active,spares,fault_single,fault_solo,fault_frontier," *
                    "zone_pending,battery_targets,n_frontier,fts_min,fts_hist," *
                    "n_hotswap,n_hotswap_inprog,hotswap_pick," *
                    "batt_old,batt_old_spare,batt_old_work,batt_new,batt_new_spare,batt_new_work")
        for r in ROWS[]
            println(io, join((r.closed, r.total, round(r.progress; digits = 4), r.n_active, r.spares,
                              Int(r.fault_single), Int(r.fault_solo), Int(r.fault_frontier),
                              r.zone_pending, r.battery_targets,
                              r.n_frontier, r.fts_min, "\"$(r.fts_hist)\"",
                              r.n_hotswap, r.n_hotswap_inprog, r.hotswap_pick,
                              r.batt_old, Int(r.batt_old_spare), Int(r.batt_old_work),
                              r.batt_new, Int(r.batt_new_spare), Int(r.batt_new_work)), ","))
        end
    end
    println("[probe] wrote $(length(ROWS[])) rows -> $(OUT)")
end

main()
