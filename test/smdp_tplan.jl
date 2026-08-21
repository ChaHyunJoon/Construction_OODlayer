# =============================================================================
# test/smdp_tplan.jl — Task T8, `src/smdp/tplan.jl` (rate boundary, D-6)
#
#   julia +lts --project=. test/smdp_tplan.jl
#
# 이 시험이 지키는 것: **λ 가 구간상수인 구간의 경계가 실제로 양수이고, 실제로 움직인다.**
# `T_plan_next` 가 0(또는 eps)을 돌려주면 `sample_sojourn` 이 전진하지 못하고, 상수를
# 돌려주면 롤아웃이 스케줄과 무관한 세계를 판다. 둘 다 **에러 없이** 샌다.
#
# 🔴 씬 생성은 `SCENE-INCANTATION.md` 의 정본을 따른다(`return_env_before_sim = true`).
#    계획서 스니펫은 판을 끝까지 굴려 **퇴화한** 세계를 잰다.
#
# 🔴 SCENE-INCANTATION §2 의 규칙: **남의 픽스처에서 잰 스텝 번호를 인용하지 않는다.**
#    아래의 모든 픽스처는 이 파일이 **런타임에 직접 찾아서** 비퇴화를 그 자리에서 단언한다
#    (`@test` 로 "찾았다"까지 못박는다 — 못 찾으면 초록이 아니라 빨강이다).
#
# 🔴 음성 대조 설계 — 이 파일이 배제하는 구현들:
#      · 상수를 돌려주는 구현            → "값이 실제로 움직인다"(합성 · 실측 둘 다)
#      · `max`/`sum` 으로 쓴 T_plan_next → 두 노드짜리 합성 픽스처가 min 만 통과시킨다
#      · `sum`/`max-of-one` 으로 쓴 T_done → 사슬+고립 합성 픽스처가 셋을 갈라놓는다
#      · `Inf` 분기가 도달 불가인 구현    → 두 `Inf` 분기를 각각 **실제로** 태운다
#      · 경과시간을 빼는 구현(옛 식)      → "같은 활성집합 ⇒ 같은 값" 이 400 스텝에서 깨진다
# =============================================================================
using ConstructionBots, Test
import Random
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

# -----------------------------------------------------------------------------
# 🔴 임시 대역(T7 의 `t7_simstate` 와 같은 이유): `simstate_of` 는 이 브랜치에서 **아직
# 7필드가 아니다** — R1(b578cd3c)이 타입만 줄이고 `observe.jl` 은 안 고쳤다. 그것을 고치는
# 것은 Task R2 이고 아직 어느 레인에도 없다(실측: `git log --all`, 2026-08-21). 계획서
# T8 스니펫의 `CB.simstate_of(env)` 는 이 브랜치에서 `MethodError` 로 죽는다.
# ⚠️ R2 가 착지하면 이 헬퍼를 지우고 `CB.simstate_of(env)` 로 바꿀 것.
# 폴백이 아니라 대역이다 — try/catch 로 감싸지 않는다(조용한 폴백 금지).
# -----------------------------------------------------------------------------
function t8_simstate(env)
    sched, cache = env.sched, env.cache
    fleet_b = CB.BATTERY_FLEET[];  fleet_b === nothing && error("enable_battery! 먼저")
    st      = CB.HAZARD_STATE[];   st === nothing      && error("enable_hazard! 먼저")

    edges = Set{Tuple{Int,Int}}()
    for e in CB.Graphs.edges(sched)
        push!(edges, (CB.Graphs.src(e), CB.Graphs.dst(e)))
    end
    binding = Dict{Int,Int}()
    for v in CB.Graphs.vertices(sched)
        rs = CB._responsible_robots(CB.get_node(sched, v).node)
        isempty(rs) && continue
        binding[v] = CB._int_key(first(sort!(collect(rs); by = string)))
    end
    poses = Dict{Int,NTuple{3,Float64}}()
    for n in CB.get_nodes(env.scene_tree)
        CB.matches_template(CB.AssemblyNode, n) || continue
        tr = CB.global_transform(n).translation
        poses[CB._int_key(CB.node_id(n))] = (Float64(tr[1]), Float64(tr[2]), Float64(tr[3]))
    end
    zones = Dict{Symbol,NTuple{3,Float64}}()
    for (k, ball) in CB.RESTRICTION_ZONES[]
        c = CB.get_center(ball)
        zones[k] = (Float64(c[1]), Float64(c[2]), Float64(CB.get_radius(ball)))
    end
    excluded = CB._hz_excluded()
    fleet = Dict{Int,CB.RobotRec}()
    for rid in sort!(collect(keys(fleet_b.soc)); by = string)
        rid in excluded && continue
        haskey(st.usage_s, rid) || error("t8_simstate: $(rid) 가 hazard 상태에 없다")
        fleet[CB._int_key(rid)] = CB.RobotRec(soc     = Float64(fleet_b.soc[rid]),
                                              usage_s = Float64(st.usage_s[rid]))
    end
    return CB.SimState(g = CB.GraphBlock(edges = edges, binding = binding),
                       geo = CB.GeoBlock(poses = poses, zones = zones),
                       fleet = fleet,
                       prog = CB.ProgBlock(closed = Set{Int}(collect(cache.closed_set))))
end

# -----------------------------------------------------------------------------
# 합성 픽스처 생성기 — **활성집합을 내가 고른다.**
#
# `active_of` 는 "모든 선행이 닫혔고 자신은 안 닫힌 정점"이다(derive.jl). 그래서
# 닫힌 sentinel 정점 하나에서 원하는 정점들로 간선을 그으면 활성집합이 정확히 그것이 된다.
# sentinel 은 **항상 closed** 라 `node_duration` 이 조회하지 않는다(스케줄에 없어도 된다).
# 이렇게 해야 실측 트레이스의 잡음에 기대지 않고 min/max/sum 을 갈라놓을 수 있다.
# -----------------------------------------------------------------------------
const SENTINEL = -1
function state_with_active(s::CB.SimState, A)
    edges = Set{Tuple{Int,Int}}((SENTINEL, v) for v in A)
    return CB.SimState(g = CB.GraphBlock(edges = edges, binding = Dict{Int,Int}()),
                       geo = s.geo, fleet = s.fleet,
                       prog = CB.ProgBlock(closed = Set{Int}([SENTINEL])))
end
function state_with_closed(s::CB.SimState, closed)
    return CB.SimState(g = s.g, geo = s.geo, fleet = s.fleet,
                       prog = CB.ProgBlock(closed = Set{Int}(closed)))
end

# --- 씬 (SCENE-INCANTATION.md 정본) ------------------------------------------
env = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "t8tplan",
                         num_robots = 6, assignment_mode = :greedy,
                         n_spare_per_pool = 2,
                         open_animation_at_end = false, save_animation = false,
                         write_results = false, return_env_before_sim = true,
                         rng = Random.MersenneTwister(1))
CB.enable_battery!(env)
CB.enable_hazard!(env; seed = 5)

const NSTEPS  = 400
const DT_SIM  = env.dt * CB.BATTERY_FLEET[].params.seconds_per_step   # 스텝당 시뮬 초
const NV      = CB.Graphs.nv(env.sched)

trace_act    = Vector{Set{Int}}()
trace_dnext  = Float64[]
trace_ddone  = Float64[]

@testset "🔴 T_plan_next 는 언제나 양수다 ($(NSTEPS) 스텝 내내)" begin
    # 선행 설계가 죽은 자리가 정확히 여기다: eps 클램프로 1.8e-15 를 돌려주면
    # sample_sojourn 이 전진하지 못하고 n_boundary 상한에서 죽거나 시뮬 시간 0 초 만에
    # DAG 를 통과한다. 전수로 못박는다.
    for k in 1:NSTEPS
        CB.step_environment!(env)
        CB.update_planning_cache!(env, 0.0)
        CB.set_sim_step!(k)
        s = t8_simstate(env)
        a = CB.active_of(s)
        Δ = CB.T_plan_next(s, env)
        D = CB.T_done(s, env)
        @test Δ > 0.0
        @test !isnan(Δ)
        isempty(a) && @test Δ == Inf
        # 불변식: 활성 정점은 열려 있으므로 그 정점의 finish 가 이미 ρ·d 이상이다.
        @test Δ <= D + 1e-9 || D == 0.0
        push!(trace_act, a); push!(trace_dnext, Δ); push!(trace_ddone, D)
    end
end

# --- 실측 요약 + 비퇴화 -------------------------------------------------------
const FIN     = [d for d in trace_dnext if isfinite(d)]
const NDIST_A = length(unique(trace_act))
const NDIST_D = length(unique(trace_dnext))
@info "T8 trace" nsteps=NSTEPS dt_sim=DT_SIM n_vertices=NV distinct_active_sets=NDIST_A distinct_Tplan=NDIST_D n_finite=length(FIN) n_inf=(NSTEPS-length(FIN)) min_finite=(isempty(FIN) ? NaN : minimum(FIN)) max_finite=(isempty(FIN) ? NaN : maximum(FIN)) Tdone_first=trace_ddone[1] Tdone_last=trace_ddone[end]

@testset "🔴 비퇴화: 픽스처가 납작하지 않다" begin
    @test NDIST_A >= 2          # 활성집합이 실제로 변한다
    @test NDIST_D >= 2          # 🔴 음성 대조: T_plan_next 가 상수가 아니다
    @test !isempty(FIN)         # 유한값이 실제로 나온다(전부 Inf 이면 아무것도 안 잰다)
    @test trace_ddone[1] > 0.0  # T_done 이 0 으로 납작하지 않다
end

@testset "🔴 음성 대조: 활성집합이 바뀔 때만 값이 바뀐다 (경과시간을 안 쓴다)" begin
    # T_plan_next 는 (활성집합, 노드 소요시간) 만의 함수다. `set_min_duration!` 는 이 레포의
    # 어떤 실행 경로도 부르지 않으므로 소요시간은 런 내내 상수다 → 같은 활성집합이면 같은 값.
    # 옛 식(`ρ·dur − (t − t0)`)은 t 가 흘러서 이 단언을 깬다. 이 시험은 그 회귀를 잡는다.
    # 동시에 이 단언은 **스케줄 소요시간이 런 중에 변조되면** 먼저 빨개지는 트립와이어다.
    seen = Dict{Set{Int},Float64}()
    nchange_pairs = 0
    for i in 1:NSTEPS
        if haskey(seen, trace_act[i])
            @test seen[trace_act[i]] == trace_dnext[i]
        else
            seen[trace_act[i]] = trace_dnext[i]
        end
        i > 1 && trace_act[i] != trace_act[i-1] && trace_dnext[i] != trace_dnext[i-1] &&
            (nchange_pairs += 1)
    end
    @info "T8 active-set/value coupling" n_distinct_sets=length(seen) n_steps_where_both_moved=nchange_pairs
    @test nchange_pairs >= 1    # 🔴 활성집합이 바뀌면서 값도 실제로 움직인 자리가 있다
end

# =============================================================================
# 합성 픽스처 — min/max/sum 과 두 개의 Inf 분기를 **직접** 갈라놓는다.
# =============================================================================
s_end = t8_simstate(env)
dur(v) = CB.node_duration(env, v)
const POS  = [v for v in 1:NV if dur(v) > 0.0]
const ZERO = [v for v in 1:NV if dur(v) == 0.0]
@info "T8 duration domain" n_vertices=NV n_pos=length(POS) n_zero=length(ZERO) min_pos=(isempty(POS) ? NaN : minimum(dur, POS)) max_pos=(isempty(POS) ? NaN : maximum(dur, POS))

@testset "🔴 비퇴화: 스케줄에 dur>0 도 dur==0 도 있고, dur 이 서로 다르다" begin
    @test length(POS)  >= 2
    @test length(ZERO) >= 1
    @test length(unique(dur.(POS))) >= 2   # 전부 같은 값이면 min/max 를 못 가른다
end

@testset "🔴 T_plan_next 는 min 이다 (max 도 sum 도 아니다)" begin
    sp = sort(POS; by = dur)
    v1, v2 = sp[1], sp[end]
    @test dur(v1) < dur(v2)                       # 픽스처가 둘을 실제로 가른다
    s2 = state_with_active(s_end, [v1, v2])
    @test CB.active_of(s2) == Set([v1, v2])       # 합성 픽스처가 의도대로 섰다
    got = CB.T_plan_next(s2, env)
    @test got ≈ dur(v1)                           # min
    @test got != dur(v2)                          # 음성 대조: max 구현 배제
    @test got != dur(v1) + dur(v2)                # 음성 대조: sum 구현 배제
end

@testset "🔴 dur == 0 정점은 경계 후보에서 빠진다" begin
    z, p = first(ZERO), first(sort(POS; by = dur))
    s2 = state_with_active(s_end, [z, p])
    @test CB.active_of(s2) == Set([z, p])
    @test dur(z) == 0.0 && dur(p) > 0.0
    @test CB.T_plan_next(s2, env) ≈ dur(p)        # 0 을 돌려주지 않는다
end

@testset "🔴 Inf 분기 둘을 각각 **실제로** 태운다" begin
    # (1) 활성이 비었다
    s_empty = state_with_active(s_end, Int[])
    @test isempty(CB.active_of(s_empty))
    @test CB.T_plan_next(s_empty, env) == Inf
    # (2) 활성은 있는데 전부 dur == 0 — 가정이 아니라 실제로 도달한다
    s_zero = state_with_active(s_end, ZERO[1:min(3, length(ZERO))])
    @test !isempty(CB.active_of(s_zero))
    @test all(v -> dur(v) == 0.0, CB.active_of(s_zero))
    @test CB.T_plan_next(s_zero, env) == Inf
end

@testset "ρ 는 선형 배수다" begin
    s2 = state_with_active(s_end, [first(sort(POS; by = dur))])
    a = CB.T_plan_next(s2, env; rho = 1.0)
    @test isfinite(a) && a > 0.0
    @test CB.T_plan_next(s2, env; rho = 2.0) ≈ 2.0 * a rtol = 1e-9
    @test CB.T_plan_next(s2, env; rho = 0.5) ≈ 0.5 * a rtol = 1e-9
    d1 = CB.T_done(state_with_closed(s_end, Int[]), env; rho = 1.0)
    @test isfinite(d1) && d1 > 0.0
    @test CB.T_done(state_with_closed(s_end, Int[]), env; rho = 3.0) ≈ 3.0 * d1 rtol = 1e-9
end

# =============================================================================
# T_done 이 **longest path** 임을 증명한다 — sum 도 max-of-one 도 아니다.
# =============================================================================

"독립 구현: 위상정렬이 아니라 **전방 메모이제이션 재귀**로 잰 longest path."
function lp_ref(env, open::Set{Int}, rho::Float64)
    G = CB.get_graph(env.sched)
    memo = Dict{Int,Float64}()
    function f(v)   # v 에서 **끝나는** 최장경로 길이
        haskey(memo, v) && return memo[v]
        memo[v] = -1.0    # 재진입하면 사이클 — DAG 가정 위반
        head = 0.0
        for u in CB.Graphs.inneighbors(G, v)
            u in open || continue
            fu = f(u)
            fu < 0.0 && error("lp_ref: 사이클")
            head = max(head, fu)
        end
        return memo[v] = head + rho * CB.node_duration(env, v)
    end
    best = 0.0
    for v in sort!(collect(open)); best = max(best, f(v)); end
    return best
end

@testset "🔴 T_done == longest path (독립 구현과 일치)" begin
    open_all = Set(1:NV)
    got  = CB.T_done(state_with_closed(s_end, Int[]), env)
    want = lp_ref(env, open_all, 1.0)
    @test got ≈ want rtol = 1e-12
end

@testset "🔴 음성 대조: T_done 은 sum 도 max-of-one 도 아니다 (전 스케줄)" begin
    s_open = state_with_closed(s_end, Int[])
    got    = CB.T_done(s_open, env)
    tot    = sum(dur(v) for v in 1:NV)
    mx     = maximum(dur(v) for v in 1:NV)
    @info "T8 T_done vs sum/max (full schedule)" T_done=got sum_all=tot max_one=mx
    @test got < tot - 1e-9      # 병렬 가지가 있으므로 합보다 작다 → sum 구현 배제
    @test got > mx + 1e-9       # 사슬이 있으므로 한 노드보다 크다 → max-of-one 구현 배제
end

"사슬 a→b→c(전부 dur>0) + 그 셋과 간선이 하나도 없는 고립 정점 x(0 < dur(x) < 사슬합)."
function find_chain_and_isolate(env, N::Int)
    G = CB.get_graph(env.sched)
    for b in 1:N
        dur(b) > 0.0 || continue
        for a in CB.Graphs.inneighbors(G, b)
            dur(a) > 0.0 || continue
            for c in CB.Graphs.outneighbors(G, b)
                dur(c) > 0.0 || continue
                S3 = (a, b, c); lp = dur(a) + dur(b) + dur(c)
                for x in 1:N
                    (x in S3 || !(dur(x) > 0.0) || dur(x) >= lp) && continue
                    any(y -> CB.Graphs.has_edge(G, x, y) || CB.Graphs.has_edge(G, y, x), S3) && continue
                    return (a, b, c, x)
                end
            end
        end
    end
    return nothing
end

@testset "🔴 손으로 검산되는 픽스처: longest path ≠ sum ≠ max" begin
    found = find_chain_and_isolate(env, NV)
    @test found !== nothing        # 🔴 못 찾으면 초록이 아니라 빨강 — 조건부로 건너뛰지 않는다
    a, b, c, x = found
    open  = Set([a, b, c, x])
    lp    = dur(a) + dur(b) + dur(c)
    tot   = lp + dur(x)
    mx    = max(dur(a), dur(b), dur(c), dur(x))
    @info "T8 hand fixture" a=a b=b c=c x=x da=dur(a) db=dur(b) dc=dur(c) dx=dur(x) longest_path=lp sum=tot max_one=mx
    @test lp != tot && lp != mx && tot != mx      # 셋이 실제로 다른 픽스처인가
    got = CB.T_done(state_with_closed(s_end, setdiff(Set(1:NV), open)), env)
    @test got ≈ lp rtol = 1e-12
    @test got != tot
    @test got != mx
end

@testset "완주 상태에서 T_done = 0, T_plan_next = Inf" begin
    s2 = state_with_closed(s_end, 1:NV)
    @test CB.T_done(s2, env) == 0.0
    @test CB.T_plan_next(s2, env) == Inf
end

@testset "🔴 조용한 폴백 금지" begin
    @test_throws ErrorException CB.node_duration(env, NV + 10^6)      # 스케줄에 없는 정점
    @test_throws ErrorException CB.node_duration(env, 0)              # 정점 번호가 아니다
    s_bad = state_with_active(s_end, [NV + 10^6])
    @test_throws ErrorException CB.T_plan_next(s_bad, env)            # 다른 세계의 정점
end

@testset "RHO 는 잠정 기본값이고 키워드가 그것을 읽는다" begin
    @test CB.RHO isa Ref{Float64}
    @test CB.RHO[] == 1.0                       # T10(N-G2)이 채우기 전의 잠정값
    s2 = state_with_active(s_end, [first(sort(POS; by = dur))])
    old = CB.RHO[]
    try
        CB.RHO[] = 4.0
        @test CB.T_plan_next(s2, env) ≈ 4.0 * CB.T_plan_next(s2, env; rho = 1.0) rtol = 1e-9
    finally
        CB.RHO[] = old
    end
    @test CB.RHO[] == 1.0
end

# =============================================================================
# 🔴 D-6 상한 근사의 **부호와 크기를 잰다**(단언하지 않는다 — N-G1 이 판정한다).
#
# 예측: T_plan_next(s) = 다음 모드 변화까지의 시간.
# 실측: 활성집합이 실제로 바뀔 때까지 흐른 시뮬 초 = (그 구간의 스텝 수) · DT_SIM.
# 두 편향이 반대로 걸린다 — 경과시간을 안 빼는 것(과대) vs `min_duration` 이 하한인 것(과소).
# 그래서 순 부호는 **선험이 아니라 실측**이다.
# =============================================================================
let
    ratios = Float64[]; preds = Float64[]; acts = Float64[]
    i = 1
    while i <= NSTEPS
        j = i
        while j < NSTEPS && trace_act[j+1] == trace_act[i]; j += 1; end
        if j < NSTEPS && isfinite(trace_dnext[i])          # 끝까지 안 잘린 구간만
            pred = trace_dnext[i]; act = (j - i + 1) * DT_SIM
            push!(preds, pred); push!(acts, act); push!(ratios, pred / act)
        end
        i = j + 1
    end
    if isempty(ratios)
        @warn "T8 D-6: 잴 수 있는 구간이 없다"
    else
        sr = sort(ratios)
        med = sr[cld(length(sr), 2)]
        @info "🔴 T8 D-6 upper-bound bias (measured, NOT asserted — N-G1 sizes it)" n_intervals=length(ratios) ratio_min=minimum(sr) ratio_p25=sr[max(1,cld(length(sr),4))] ratio_median=med ratio_p75=sr[max(1,cld(3*length(sr),4))] ratio_max=maximum(sr) n_over=count(>(1.0), ratios) n_under=count(<(1.0), ratios) mean_pred=sum(preds)/length(preds) mean_actual=sum(acts)/length(acts) dt_sim=DT_SIM
    end
end
