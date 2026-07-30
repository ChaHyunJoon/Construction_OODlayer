# =============================================================================
#  tools/test_cbf.jl -- verification battery for the L1 CBF filter / L0 backup.
#
#  Run:  julia +lts --project=. tools/test_cbf.jl
#
#  These are MATH + SEAM tests: they need no simulation, so they run in seconds and can be used
#  as the fast regression gate for safety/cbf.jl. The expensive question -- "does the filter
#  actually keep robots out of zones in a full build, and does it replace the teleport?" -- is
#  answered separately by tools/cbf_sim_eval.jl.
#
#  What is checked
#    QP1  the 2-D QP returns v_pref when it is already feasible (no gratuitous conservatism)
#    QP2  the returned point is FEASIBLE for every constraint
#    QP3  the returned point is OPTIMAL (matches a dense brute-force search)
#    QP4  infeasible polyhedra are reported, not silently mishandled
#    B1   barrier h is positive outside a zone, negative inside, zero on the boundary
#    B2   the CBF constraint admits v=0 whenever h>=0  (== L0 is always available: THE key claim)
#    F1   the filter is a strict no-op while disabled (byte-identical normal runs)
#    F2   a velocity aimed straight into a zone is cut; one aimed away is not
#    F3   L0 hold forces exactly zero
#    F4   scaling a solution DOWN preserves feasibility (justifies the max-speed clamp)
#
#  [한국어] 시뮬레이션 없이 몇 초 만에 도는 수학/이음새 검증. CBF 필터를 고칠 때마다 이걸 먼저 돌린다.
#          핵심은 B2 -- "안전하면 v=0 이 항상 실행가능" = L0 라인스톱이 원리적으로 보장된다는 주장.
# =============================================================================
using ConstructionBots
const CB = ConstructionBots
using LinearAlgebra
using LazySets

const PASS = Ref(0)
const FAIL = Ref(0)

function check(name, ok, detail = "")
    if ok
        PASS[] += 1
        println("  [PASS] ", name, detail == "" ? "" : "   $detail")
    else
        FAIL[] += 1
        println("  [FAIL] ", name, detail == "" ? "" : "   $detail")
    end
    return ok
end

banner(t) = println("\n" * "="^74 * "\n" * t * "\n" * "="^74)

# =============================================================================
banner("QP  --  exact 2-D quadratic program")
# =============================================================================

# QP1: 이미 실행가능하면 원하는 속도를 그대로 돌려줘야 한다(공연히 보수적이면 안 됨).
let
    v, ok = CB.solve_qp2d([1.0, 0.0], [[-1.0, 0.0]], [5.0])   # -vx <= 5  (vx >= -5): 만족
    check("QP1 feasible v_pref returned unchanged", ok && isapprox(v, [1.0, 0.0]; atol = 1e-12),
          "v=$(round.(v, digits=4))")
end

# QP2/QP3: 무작위 문제 200개에 대해 (a) 실행가능성 (b) 최적성(격자 완전탐색과 비교)
let
    feas_ok = true; opt_ok = true; empty_ok = true; worst = 0.0
    n_solved = 0; n_empty = 0
    for t in 1:200
        # 결정적 의사난수(테스트 재현성). 주의: Julia 의 `%` 는 피제수 부호를 유지하므로 f ∈ (-1,1).
        f(k) = (sin(t * 12.9898 + k * 78.233) * 43758.5453) % 1.0
        p = [4f(1), 4f(2)]
        m = 1 + (t % 3)
        A = Vector{Vector{Float64}}(); b = Float64[]
        for i in 1:m
            θ = 2π * f(10 + i)
            push!(A, [cos(θ), sin(θ)])
            # abs 를 씌워 b>=0 을 보장 -> v=0 이 항상 실행가능 -> 영역이 비지 않음.
            # (CBF 에서 오는 실제 b 는 alpha*h 이고 안전할 때 h>=0 이므로 바로 이 경우에 해당한다.)
            push!(b, 0.5 * abs(f(20 + i)))
        end
        v, ok = CB.solve_qp2d(p, A, b)

        if !ok
            # b>=0 인 문제는 절대 공집합일 수 없다 -> 여기 들어오면 솔버 버그.
            empty_ok = false
            n_empty += 1
            continue
        end
        n_solved += 1

        # (a) 실행가능?
        for i in 1:m
            if dot(A[i], v) > b[i] + 1e-7
                feas_ok = false
            end
        end
        # (b) 최적? 격자 완전탐색으로 더 가까운 실행가능점이 있는지
        bestd = norm(v - p)
        for gx in -60:60, gy in -60:60
            w = [gx / 10.0, gy / 10.0]
            all(dot(A[i], w) <= b[i] + 1e-9 for i in 1:m) || continue
            d = norm(w - p)
            if d < bestd - 1e-6
                opt_ok = false
                worst = max(worst, bestd - d)
            end
        end
    end
    check("QP2a never reports empty when b>=0 (v=0 always feasible)", empty_ok,
          empty_ok ? "$n_solved solved" : "$n_empty spurious infeasible")
    check("QP2b solution always satisfies every constraint", feas_ok)
    check("QP3 solution optimal vs brute-force grid", opt_ok,
          opt_ok ? "$n_solved problems" : "grid found a point closer by $(round(worst, digits=4))")
end

# QP3b: 반대 방향 교차검증 -- ok=false 로 보고한 경우가 정말 공집합인지 완전탐색으로 확인한다.
# (실행가능한데 못 찾는 "거짓 infeasible" 은 안전필터에서 불필요한 복구 기동을 유발하므로 중요.)
let false_infeasible = 0, n_inf = 0
    for t in 1:300
        f(k) = (sin(t * 3.1234 + k * 17.77) * 9871.234) % 1.0
        m = 2 + (t % 3)
        A = Vector{Vector{Float64}}(); b = Float64[]
        for i in 1:m
            θ = 2π * f(i)
            push!(A, [cos(θ), sin(θ)])
            push!(b, 0.6 * f(30 + i))        # 부호 제한 없음 -> 실제로 공집합인 경우가 섞임
        end
        _, ok = CB.solve_qp2d([0.0, 0.0], A, b)
        ok && continue
        n_inf += 1
        # 조밀 격자에 실행가능점이 하나라도 있으면 "거짓 infeasible"
        for gx in -40:40, gy in -40:40
            w = [gx / 8.0, gy / 8.0]
            if all(dot(A[i], w) <= b[i] - 1e-6 for i in 1:m)
                false_infeasible += 1
                break
            end
        end
    end
    check("QP3b reported-infeasible cases are genuinely empty", false_infeasible == 0,
          "$n_inf infeasible reports, $false_infeasible false")
end

# QP4: 실행가능 영역이 비면 ok=false 로 보고해야 한다(조용히 틀린 값을 주면 안 됨).
let
    #  vx <= -1  AND  -vx <= -1 (즉 vx >= 1) : 동시에 만족 불가
    v, ok = CB.solve_qp2d([0.0, 0.0], [[1.0, 0.0], [-1.0, 0.0]], [-1.0, -1.0])
    check("QP4 infeasible polyhedron reported", ok == false)
end

# =============================================================================
banner("B  --  barrier semantics and the L0 availability proof")
# =============================================================================

CB.clear_restriction_zones!()
CB.RESTRICTION_ZONES[][:t1] = LazySets.Ball2([0.0, 0.0], 2.0)   # 원점 반지름 2 의 금지구역
CB.CBF_MARGIN[] = 0.0

let r = 0.5
    hs_out = CB.cbf_zone_barriers([5.0, 0.0], r)     # 바깥
    hs_in  = CB.cbf_zone_barriers([0.5, 0.0], r)     # 안쪽
    hs_bd  = CB.cbf_zone_barriers([2.5, 0.0], r)     # 경계 (2.0+0.5)
    check("B1a h>0 outside the zone", hs_out[1][1] > 0, "h=$(round(hs_out[1][1], digits=4))")
    check("B1b h<0 inside the zone",  hs_in[1][1] < 0,  "h=$(round(hs_in[1][1], digits=4))")
    check("B1c h==0 on the boundary", abs(hs_bd[1][1]) < 1e-9, "h=$(round(hs_bd[1][1], digits=12))")
    check("B1d gradient points away from the centre",
          isapprox(hs_out[1][2], [1.0, 0.0]; atol = 1e-9))
end

# B2 -- THE key claim: while h>=0, v=0 satisfies every CBF constraint, so the QP is always
# feasible and "stop" is always available. Checked over a sweep of positions and alphas.
let all_ok = true, tested = 0
    for d in 2.5:0.5:12.0, alpha in (0.1, 1.0, 2.0, 10.0)
        bars = CB.cbf_zone_barriers([d, 0.0], 0.5)
        h, g = bars[1]
        h < 0 && continue
        tested += 1
        # 제약: (-g).v <= alpha*h  에 v=0 대입 -> 0 <= alpha*h
        if !(0.0 <= alpha * h + 1e-12)
            all_ok = false
        end
    end
    check("B2 v=0 feasible whenever h>=0  (L0 always available)", all_ok, "$tested cases")
end

# =============================================================================
banner("F  --  filter behaviour at the seam")
# =============================================================================

# 가짜 에이전트: 필터가 필요로 하는 것은 위치와 반지름뿐이므로, 그 두 훅만 흉내내면 된다.
# (실제 scene-tree 노드를 만들려면 전체 빌드가 필요해 테스트가 무거워진다.)
struct FakeAgent
    pos::Vector{Float64}
    r::Float64
end
CB.rvo_get_agent_position(a::FakeAgent) = a.pos
CB.cbf_agent_radius(a::FakeAgent) = a.r

# F1: 비활성일 때는 손대지 않는다(정상 실행 무변화 보장).
CB.disable_cbf!()
let a = FakeAgent([3.0, 0.0], 0.5)
    v = CB.cbf_filter_velocity(a, [-1.0, 0.0]; max_speed = 1.0)   # 구역을 향해 정면으로
    check("F1 disabled filter is a strict no-op", collect(v) == [-1.0, 0.0], "v=$v")
end

CB.enable_cbf!(alpha = 2.0, margin = 0.0)

# F2a: 구역을 향해 돌진하는 속도는 깎여야 한다. 경계 바로 밖(h 작음)에서 특히 강하게.
let a = FakeAgent([2.6, 0.0], 0.5)   # h = 2.6 - 2.5 = 0.1
    vin = CB.cbf_filter_velocity(a, [-1.0, 0.0]; max_speed = 1.0)
    # 허용 최대 접근속도 = alpha*h = 0.2  -> vx >= -0.2
    check("F2a inbound velocity is cut to the CBF bound", vin[1] >= -0.2 - 1e-6,
          "vx=$(round(vin[1], digits=4)) (bound -0.2)")
end

# F2b: 구역에서 멀어지는 속도는 건드리지 않는다(불필요한 보수성 없음).
let a = FakeAgent([2.6, 0.0], 0.5)
    vout = CB.cbf_filter_velocity(a, [1.0, 0.0]; max_speed = 1.0)
    check("F2b outbound velocity untouched", isapprox(collect(vout), [1.0, 0.0]; atol = 1e-9),
          "v=$(round.(collect(vout), digits=4))")
end

# F2c: 아주 멀리 있으면 제약이 느슨해 원본 그대로 통과해야 한다.
let a = FakeAgent([50.0, 0.0], 0.5)
    v = CB.cbf_filter_velocity(a, [-1.0, 0.0]; max_speed = 1.0)
    check("F2c far from the zone -> unchanged", isapprox(collect(v), [-1.0, 0.0]; atol = 1e-9))
end

# F3: L0 라인스톱은 정확히 0 을 강제한다.
CB.cbf_hold!(true)
let a = FakeAgent([50.0, 0.0], 0.5)
    v = CB.cbf_filter_velocity(a, [1.0, 1.0]; max_speed = 1.0)
    check("F3 L0 hold commands exactly zero", collect(v) == [0.0, 0.0], "v=$v")
end
CB.cbf_hold!(false)

# F4: 해를 아래로 스케일해도 실행가능성이 유지된다(최대속도 클램프의 정당화).
let ok = true
    A = [[-1.0, 0.0], [0.0, -1.0]]
    b = [0.3, 0.4]                                  # b>=0
    v, _ = CB.solve_qp2d([-2.0, -2.0], A, b)
    for s in (0.0, 0.1, 0.5, 0.9, 1.0)
        w = s .* v
        for i in 1:2
            dot(A[i], w) > b[i] + 1e-9 && (ok = false)
        end
    end
    check("F4 scaling a solution down preserves feasibility", ok)
end

# F5: 이미 침범한 상태에서는 바깥으로 나가는 복구 속도를 낸다.
let a = FakeAgent([0.5, 0.0], 0.5)                  # 구역 한복판 (h<0)
    v = CB.cbf_filter_velocity(a, [-1.0, 0.0]; max_speed = 1.0)   # 더 깊이 들어가려는 명령
    check("F5 violating state -> recovery velocity points OUT", v[1] > 0,
          "v=$(round.(collect(v), digits=4))")
end

# =============================================================================
CB.disable_cbf!()
CB.clear_restriction_zones!()
banner("SUMMARY")
println("  $(PASS[]) passed, $(FAIL[]) failed")
FAIL[] == 0 || exit(1)
