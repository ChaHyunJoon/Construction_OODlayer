# =============================================================================
#  tools/cbf_sim_eval.jl -- does the L1 filter actually REPLACE the teleport, in a real build?
#
#  Run:  julia +lts --project=. tools/cbf_sim_eval.jl            (both arms)
#        CBF_ARM=off julia +lts --project=. tools/cbf_sim_eval.jl  (one arm, for parallel lanes)
#
#  THE CLAIM UNDER TEST
#  --------------------
#  `enforce_restriction_zone_clearance!` keeps robots out of no-go zones by SNAPPING their
#  position to the boundary after RVO has already stepped them inside. The L1 CBF filter
#  (safety/cbf.jl) instead shapes the COMMANDED VELOCITY so they never enter in the first place.
#
#  If that story is true, then turning the filter on must make the snapper have nothing to do:
#
#      arm            zone_snaps      cbf.modified    min_h        build outcome
#      CBF off        > 0             (n/a)           < 0          baseline
#      CBF on         == 0            > 0             >= 0         must NOT regress
#
#  The last column is the honest cost check: a safety filter that guarantees the invariant by
#  freezing the build has not solved anything. `closed` / `complete` must hold up.
#
#  WHY BOTH ARMS RUN THE SAME SEED AND THE SAME ZONE
#  -------------------------------------------------
#  The only difference between arms is `enable_cbf!()`. Same RNG seed, same zone geometry, same
#  everything else -- so any difference in the counters is attributable to the filter and nothing
#  else. (Same discipline as the oracle labeler's control arm.)
#
#  [한국어] 이 스크립트가 검증하는 것: "CBF 필터를 켜면 사후 순간이동 보정이 할 일이 없어지는가".
#    · CBF off : 로봇이 구역에 들어감 -> 텔레포트 보정 발생(zone_snaps > 0), 최소 h < 0
#    · CBF on  : 애초에 안 들어감 -> 보정 0회, 최소 h >= 0, 대신 속도가 깎임(modified > 0)
#    · 그리고 중요: 빌드 성능(closed/complete)이 나빠지면 안 된다. 멈춰 세워서 지키는 건 해결이 아님.
#    두 팔은 seed·구역·설정이 완전히 같고 오직 enable_cbf!() 만 다르다 -> 차이의 원인이 필터로 특정됨.
# =============================================================================
using ConstructionBots
const CB = ConstructionBots
using Random
using Logging
using Printf

# ---- knobs -------------------------------------------------------------------------------
const SEED     = parse(Int,     get(ENV, "CBF_SEED",   "1"))
const NROBOTS  = parse(Int,     get(ENV, "CBF_ROBOTS", "10"))
const MODEL    = get(ENV, "CBF_MODEL", "tractor.mpd")
const ALPHA    = parse(Float64, get(ENV, "CBF_ALPHA",  "2.0"))
const MARGIN   = parse(Float64, get(ENV, "CBF_MARGIN", "0.0"))
const NOPROG   = parse(Int,     get(ENV, "CBF_NOPROG", "8000"))
# 금지구역: 빌드가 실제로 지나다니는 곳에 놓아야 의미가 있다. 반지름/중심은 환경변수로 조정 가능.
const ZONE_C   = [parse(Float64, get(ENV, "CBF_ZX", "0.0")), parse(Float64, get(ENV, "CBF_ZY", "0.0"))]
const ZONE_R   = parse(Float64, get(ENV, "CBF_ZR", "3000.0"))   # staging 원을 못 찾았을 때의 대비값
# staging 원 상대 배치 손잡이(라벨러 place_blocking_zone! 과 같은 의미).
#   offset 0 = staging 중심을 정통으로 덮음(빌드 불가에 가까움) / 1.1 = 가장자리로 비켜남(통행만 간섭)
const ZONE_OFFSET = parse(Float64, get(ENV, "CBF_ZOFF",  "1.1"))
const ZONE_RFRAC  = parse(Float64, get(ENV, "CBF_ZFRAC", "0.8"))

# 큰 스택이 필요한 재귀 호출이 있어 별도 태스크에서 돌린다(오라클 하니스와 동일한 관례).
function run_with_stack(f, stack_bytes::Int = 2_000_000_000)
    t = Task(f)
    t.sticky = false
    schedule(t)
    return fetch(t)
end

"한 팔(arm)을 실행하고 계측치를 돌려준다. cbf=true 면 L1 필터를 켠다."
function run_arm(cbf::Bool)
    # ---- 판 사이 잔여 상태 청소 (오라클 run_one 과 같은 목록) ----------------------------
    for f in (:clear_ood_schedule!, :clear_restriction_zones!, :clear_spare_pools!,
              :clear_faulted_robots!, :clear_recovery_spares!, :clear_ood_truth_log!,
              :clear_wedge_edges!, :clear_stalled_robots!)
        try getproperty(CB, f)() catch end
    end
    CB.reset_zone_snap_stats!()
    CB.disable_cbf!()
    cbf && CB.enable_cbf!(alpha = ALPHA, margin = MARGIN)
    CB.reset_cbf_stats!()

    # ---- 구역을 pre_sim 시점에 등록: 두 팔이 완전히 같은 기하를 보도록 고정 --------------
    # 좌표를 손으로 찍으면 "로봇이 애초에 안 지나가는 곳"에 놓여 실험이 공허해진다. 그래서 라벨러의
    # place_blocking_zone! 과 같은 방식으로 **실제 staging 원에 상대적으로** 배치한다:
    #   중심 = 대상 staging 원 중심에서 빌드코어 방향으로 offset*r 만큼 이동, 반지름 = rfrac*r.
    #   offset 이 크면 원 가장자리로 비켜나 빌드는 계속 가능하되 로봇 통행로에는 걸친다
    #   -> "필터가 통행을 막지 않으면서 침범만 없애는가"를 볼 수 있는 조건.
    hook = function (env)
        placed = false
        try
            if !isempty(env.staging_circles)
                root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])),
                              collect(keys(env.staging_circles)))
                rc = Vector{Float64}(CB.get_center(env.staging_circles[root])[1:2])
                for (aid, ball) in env.staging_circles
                    aid == root && continue
                    c = Vector{Float64}(CB.get_center(ball)[1:2])
                    r = Float64(CB.get_radius(ball))
                    dir = rc .- c
                    nd = sqrt(sum(dir .^ 2))
                    dir = nd > 1e-6 ? dir ./ nd : [1.0, 0.0]
                    zc = c .+ (ZONE_OFFSET * r) .* dir
                    CB.add_restriction_zone!(:cbf_eval, zc, r * ZONE_RFRAC)
                    println("  [zone] placed at ($(round(zc[1];digits=1)), $(round(zc[2];digits=1))) " *
                            "r=$(round(r*ZONE_RFRAC;digits=1))  (staging r=$(round(r;digits=1)))")
                    placed = true
                    break
                end
            end
        catch e
            @warn "[zone] staging-relative placement failed; falling back to fixed centre" err = e
        end
        placed || CB.add_restriction_zone!(:cbf_eval, ZONE_C, ZONE_R)
        return nothing
    end

    t0 = time()
    res = run_with_stack() do
        CB.run_lego_demo(; ldraw_file = MODEL, num_robots = NROBOTS,
            assignment_mode = :greedy, milp_optimizer = :highs, optimizer_time_limit = 60,
            log_level = Logging.Warn, max_num_iters_no_progress = NOPROG,
            rvo_flag = true, tangent_bug_flag = true, dispersion_flag = true,
            save_animation = false, open_animation_at_end = false,
            write_results = false, overwrite_results = true, return_env_before_sim = false,
            pre_sim_hook = hook, rng = Random.MersenneTwister(SEED))
    end
    wall = time() - t0

    env   = res isa Tuple ? res[1] : res
    stats = res isa Tuple ? res[2] : Dict()

    cert = try CB.cbf_certificate(env) catch e; (min_h = NaN, n_violations = -1, n_agents = -1,
                                                enabled = cbf, hold = false) end
    snap = CB.zone_snap_stats()
    cs   = CB.cbf_stats()

    out = (
        arm            = cbf ? "CBF_ON" : "CBF_OFF",
        complete       = CB.project_complete(env),
        closed         = length(env.cache.closed_set),
        total          = length(CB.get_nodes(env.sched)),
        makespan       = (try Float64(get(stats, :Makespan, NaN)) catch; NaN end),
        wall_seconds   = wall,
        zone_snap_calls    = snap[:calls],
        zone_snaps         = snap[:agents_snapped],   # <-- 핵심 지표: 텔레포트 보정 횟수
        zone_snap_max_depth = snap[:max_depth],
        cbf_calls      = cs[:calls],
        cbf_modified   = cs[:modified],
        cbf_infeasible = cs[:infeasible],
        cbf_violations = cs[:violations],
        cbf_min_h      = cs[:min_h],
        cbf_total_cut  = cs[:total_cut],
        final_min_h    = cert.min_h,
        final_violations = cert.n_violations,
    )
    CB.disable_cbf!()
    return out
end

function show_arm(r)
    @printf("\n  %-8s  complete=%-5s closed=%d/%d  makespan=%.1f  wall=%.0fs\n",
            r.arm, string(r.complete), r.closed, r.total, r.makespan, r.wall_seconds)
    @printf("            zone teleports: %d  (snapper invoked %d times, deepest snap %.3f)\n",
            r.zone_snaps, r.zone_snap_calls, r.zone_snap_max_depth)
    @printf("            cbf: calls=%d modified=%d infeasible=%d violations=%d min_h=%.4f cut=%.2f\n",
            r.cbf_calls, r.cbf_modified, r.cbf_infeasible, r.cbf_violations,
            r.cbf_min_h == Inf ? NaN : r.cbf_min_h, r.cbf_total_cut)
    @printf("            final certificate: min_h=%.4f  violating agents=%d\n",
            r.final_min_h, r.final_violations)
end

# =============================================================================
arm_sel = get(ENV, "CBF_ARM", "both")
println("="^78)
println("CBF SIM EVAL   model=$MODEL robots=$NROBOTS seed=$SEED zone=(c=$ZONE_C, r=$ZONE_R)")
println("               alpha=$ALPHA margin=$MARGIN  arm=$arm_sel")
println("="^78)

results = Any[]
if arm_sel in ("both", "off")
    push!(results, run_arm(false)); show_arm(results[end])
end
if arm_sel in ("both", "on")
    push!(results, run_arm(true));  show_arm(results[end])
end

# ---- verdicts ----------------------------------------------------------------------------
if length(results) == 2
    off, on = results[1], results[2]
    println("\n" * "="^78)
    println("VERDICTS")
    println("="^78)
    v1 = on.zone_snaps == 0
    v2 = on.zone_snaps < off.zone_snaps || off.zone_snaps == 0
    v3 = on.final_violations <= off.final_violations
    v4 = on.closed >= off.closed - 5          # 5 노드 이내 오차는 RVO 미세 요동 범위로 허용
    @printf("  [%s] filter eliminates teleports        CBF_ON snaps=%d (was %d)\n",
            v1 ? "PASS" : "FAIL", on.zone_snaps, off.zone_snaps)
    @printf("  [%s] teleports strictly reduced         %d -> %d\n",
            v2 ? "PASS" : "FAIL", off.zone_snaps, on.zone_snaps)
    @printf("  [%s] no more end-state violations       %d -> %d\n",
            v3 ? "PASS" : "FAIL", off.final_violations, on.final_violations)
    @printf("  [%s] build does NOT regress             closed %d -> %d (complete %s -> %s)\n",
            v4 ? "PASS" : "FAIL", off.closed, on.closed, string(off.complete), string(on.complete))
    if off.zone_snaps == 0
        println("\n  NOTE: the OFF arm never violated either -- this zone/seed never puts a robot")
        println("        inside the disc, so the comparison is vacuous. Move the zone onto a")
        println("        travelled corridor (CBF_ZX/CBF_ZY/CBF_ZR) for a meaningful test.")
    end
end

# ---- machine-readable line for the artifact log ------------------------------------------
for r in results
    println("\nRESULT_JSON ", "{",
        "\"arm\":\"", r.arm, "\",",
        "\"complete\":", r.complete, ",",
        "\"closed\":", r.closed, ",\"total\":", r.total, ",",
        "\"zone_snaps\":", r.zone_snaps, ",",
        "\"zone_snap_max_depth\":", r.zone_snap_max_depth, ",",
        "\"cbf_modified\":", r.cbf_modified, ",",
        "\"cbf_violations\":", r.cbf_violations, ",",
        "\"cbf_infeasible\":", r.cbf_infeasible, ",",
        "\"final_min_h\":", r.final_min_h, ",",
        "\"final_violations\":", r.final_violations, ",",
        "\"wall_seconds\":", round(r.wall_seconds, digits = 1),
        "}")
end
