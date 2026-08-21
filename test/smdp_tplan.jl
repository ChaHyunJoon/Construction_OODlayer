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
import JSON3
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
trace_modes  = Vector{Dict{Int,Symbol}}()   # 🔴 수정 1라운드: 모드 경계를 재기 위해
trace_closed = Vector{Set{Int}}()           # 🔴 수정 1라운드: always-DP 변형 대조용

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
        # 🔴 **이 단언은 이 창(400 스텝)에서 한 번도 실행되지 않는다** — `T_done` 이 내내
        # 27 s 아래로 안 내려간다(n_inf = 0). **커버리지로 세지 말 것.** 긴 런에서만 살아난다.
        # 수정 1라운드에 조건을 `isempty(활성)` → `T_done == 0` 으로 바꿨다: 폴백이 생긴 뒤
        # `Inf` 의 뜻이 "활성이 없다" 가 아니라 "남은 작업의 소요시간이 전부 0" 이기 때문이다.
        D == 0.0 && @test Δ == Inf
        # 불변식: 활성 정점은 열려 있으므로 그 정점의 finish 가 이미 ρ·d 이상이다.
        @test Δ <= D + 1e-9 || D == 0.0
        push!(trace_act, a); push!(trace_dnext, Δ); push!(trace_ddone, D)
        push!(trace_modes, CB.modes_of(s, env))   # λ 파라미터가 실제로 바뀌는 사건
        push!(trace_closed, s.prog.closed)
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

"z(dur==0) → w(dur>0) → u(dur>0) 사슬. 프론티어가 전부 0 인 상태를 **일관되게** 만든다."
function find_zero_frontier_chain(env, N::Int)
    G = CB.get_graph(env.sched)
    for z in 1:N
        dur(z) == 0.0 || continue
        for w in CB.Graphs.outneighbors(G, z)
            dur(w) > 0.0 || continue
            for u in CB.Graphs.outneighbors(G, w)
                dur(u) > 0.0 && return (z, w, u)
            end
        end
    end
    return nothing
end

@testset "🔴 Inf 는 이제 뜻이 하나다: 남은 작업의 소요시간이 전부 0" begin
    # (1) 흡수상태 — 남은 정점이 아예 없다
    s_abs = state_with_closed(s_end, 1:NV)
    @test CB.T_plan_next(s_abs, env) == Inf
    @test CB.T_done(s_abs, env) == 0.0
    # (2) 🔴 작업은 남았는데 전부 dur == 0 — 활성이 **비어 있지 않은데도** Inf 다.
    #     `state_with_active` 로 만들면 `s.g.edges` 와 `env.sched` 가 어긋나 폴백이 다른 세계를
    #     본다. 그래서 `closed` 로만 만든다(= `simstate_of` 가 내는 상태와 같은 모양).
    z0 = first(ZERO)
    s_z = state_with_closed(s_end, setdiff(Set(1:NV), Set([z0])))
    @test CB.active_of(s_z) == Set([z0])          # 활성이 비어 있지 않다
    @test dur(z0) == 0.0
    @test CB.T_plan_next(s_z, env) == Inf
    @test CB.T_done(s_z, env) == 0.0              # → 불변식은 `T_done == 0` 가지로 성립
end

@testset "🔴 폴백: 프론티어가 전부 dur==0 이어도 Inf 가 아니다 (불변식 복원)" begin
    # 🔴 수정 1라운드 이전에는 여기서 `T_plan_next = Inf`, `T_done = 유한 양수` 였다 —
    #    즉 `T_plan_next ≤ T_done` 이 **거짓**이었고, 그 상태의 소저너는 남은 모드 변화를
    #    앞에 두고 적분 상한으로 Inf 를 받았다.
    found = find_zero_frontier_chain(env, NV)
    @test found !== nothing            # 못 찾으면 초록이 아니라 빨강
    z, w, u = found
    s_f = state_with_closed(s_end, setdiff(Set(1:NV), Set([z, w, u])))
    @info "T8 fallback fixture" z=z w=w u=u dz=dur(z) dw=dur(w) du=dur(u)
    @test dur(z) == 0.0 && dur(w) > 0.0 && dur(u) > 0.0
    @test CB.active_of(s_f) == Set([z])           # 프론티어는 z 하나, 그리고 dur(z) == 0
    got, done = CB.T_plan_next(s_f, env), CB.T_done(s_f, env)
    @test isfinite(got)                           # 🔴 Inf 가 아니다 (수정의 핵심)
    @test got ≈ dur(w)                            # z 를 뚫고 지나간 첫 양수 경계
    @test done ≈ dur(w) + dur(u)
    @test got < done                              # 🔴 불변식이 **엄격하게** 성립한다
    @test CB.T_plan_next(s_f, env; rho = 3.0) ≈ 3.0 * got rtol = 1e-9   # 폴백도 ρ 선형
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
    # ⚠️ 이 픽스처가 가르는 것은 longest-path vs **열린 정점 전체의 합** vs **한 노드의 최댓값**
    #    이다. **선행들의 합**(`head += finish[u]`)은 가르지 **못한다** — 선형 사슬에서는 열린
    #    선행이 정점마다 하나뿐이라 `+=` 와 `max` 가 같은 값을 낸다. 그 변이는 위의 독립 구현
    #    대조(`lp_ref`)와 `got < tot` 가 잡는다.
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

@testset "RHO 는 적합된 값이고 키워드가 그것을 읽는다" begin
    # 🔴 2026-08-21 (T10): 이 단언의 **뜻이 바뀌었다.** 예전엔 "아직 아무도 안 채운 잠정값"
    #    이었고, 지금은 "`tools/monitor/fit_rho.jl` 이 노드 소요시간에 적합한 값" 이다.
    #    값이 같은 것은 우연이 아니라 측정 결과다(tplan.jl 의 `RHO` docstring 이 근거 전부를
    #    적는다). 그래서 아래에서 **산출물과 대조**한다 — 값 하나만 보면 "T10 이 안 돌았다" 와
    #    "T10 이 돌았고 1.0 이 나왔다" 가 구분되지 않기 때문이다.
    @test CB.RHO isa Ref{Float64}
    @test CB.RHO[] == 1.0                       # 적합값(fit_rho.jl → results/smdp/rho.json)
    let path = joinpath(@__DIR__, "..", "results", "smdp", "rho.json")
        if isfile(path)
            rj = JSON3.read(read(path, String))
            @test abs(Float64(rj["rho"]) - CB.RHO[]) <= 1e-12   # 두 출처가 갈리면 빨강
            @test rj["fit_rule"] == "median(actual/planned) over closed vertices with planned > 0"
            @test rj["meta"]["ng1_consulted"] == false          # 게이트에 맞춘 교정이 아니다
            @info "T8/T10 RHO 출처" rho=CB.RHO[] n_nodes=rj["n_nodes"] p10=rj["ratio_p10"] p90=rj["ratio_p90"] file=rj["meta"]["file"]
        else
            @warn "results/smdp/rho.json 이 없다 — RHO 의 출처를 대조하지 못했다" path
        end
    end
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
# 🔴 **수정 1라운드 (리뷰 지적 Important 1): 재는 사건이 틀렸었다.**
#    1라운드 이전에는 "**활성집합**이 바뀔 때까지"를 actual 로 썼다. 그런데 이 함수가 예측하는
#    것은 "**모드**가 바뀔 때까지"다. `modes_of`(derive.jl:55-66)는 `active_of(s)` 와 함대 키의
#    순함수이므로 **모드 변화 ⟹ 활성집합 변화**이지만 **역은 거짓**이다. 즉 모드상수 구간은
#    활성상수 구간들의 **합집합**이라 `actual_mode ≥ actual_active` 이고, 옛 표의 모든 비는
#    참값의 **상한**이었다 — 과대예측(운영상 해로운 방향)은 **부풀려졌고** 과소예측은
#    **축소돼** 있었다. 그래서 아래는 **모드 경계**를 주 측정으로 삼고, 옛 활성집합 기준은
#    비교용으로만 남긴다.
#
# 예측: `T_plan_next(s)`. 실측: 그 사건이 실제로 일어날 때까지 흐른 시뮬 초 = 구간 스텝 수 × DT_SIM.
# 두 편향이 반대로 걸린다 — 경과시간을 안 빼는 것(과대) vs `min_duration` 이 하한인 것(과소).
# 그래서 순 부호는 **선험이 아니라 실측**이다.
# =============================================================================
_pct(sv, p) = sv[clamp(ceil(Int, p * length(sv)), 1, length(sv))]

"`key` 가 상수인 구간으로 트레이스를 쪼개 (pred/actual) 를 낸다. 잘린 마지막 구간과 Inf 는 뺀다."
function interval_ratios(key::Vector, pred::Vector{Float64}, dt::Float64)
    ratios, preds, acts, lens = Float64[], Float64[], Float64[], Int[]
    n, i = length(key), 1
    while i <= n
        j = i
        while j < n && key[j + 1] == key[i]; j += 1; end
        if j < n && isfinite(pred[i])          # 끝까지 안 잘린 구간만
            m = j - i + 1
            push!(lens, m); push!(preds, pred[i]); push!(acts, m * dt)
            push!(ratios, pred[i] / (m * dt))
        end
        i = j + 1
    end
    return ratios, preds, acts, lens
end

function report_bias(label, key)
    r, pr, ac, ln = interval_ratios(key, trace_dnext, DT_SIM)
    if isempty(r)
        @warn "T8 D-6: 잴 수 있는 구간이 없다" label
        return
    end
    sr = sort(r)
    le3 = [k for k in eachindex(r) if ln[k] <= 3]
    @info label n_intervals=length(r) ratio_min=minimum(sr) ratio_p25=_pct(sr, 0.25) ratio_median=_pct(sr, 0.50) ratio_p75=_pct(sr, 0.75) ratio_max=maximum(sr) n_over=count(>(1.0), r) n_exact=count(==(1.0), r) n_under=count(<(1.0), r) mean_pred=sum(pr)/length(pr) mean_actual=sum(ac)/length(ac) mean_ratio_of_means=(sum(pr)/sum(ac)) interval_steps_min=minimum(ln) interval_steps_median=_pct(sort(ln), 0.50) interval_steps_max=maximum(ln) n_intervals_le3_steps=length(le3) n_exact_of_which_le3=count(k -> r[k] == 1.0, le3) n_under_of_which_le3=count(k -> r[k] < 1.0, le3) n_over_of_which_le3=count(k -> r[k] > 1.0, le3) ratio_quantum_at_1_step=1.0 median_ratio_of_intervals_ge4_steps=(isempty(setdiff(eachindex(r), le3)) ? NaN : _pct(sort([r[k] for k in setdiff(eachindex(r), le3)]), 0.50)) n_intervals_ge4_steps=(length(r) - length(le3)) dt_sim=DT_SIM
end

# 🔴 주 측정 — **모드 경계** (이 함수가 실제로 예측하는 사건)
report_bias("🔴 T8 D-6 bias vs MODE boundary (measured, NOT asserted — N-G1 sizes it)", trace_modes)
# 비교용 — 옛(틀린) 기준. 두 표의 차이가 곧 위 주석의 편향이다.
report_bias("T8 D-6 bias vs ACTIVE-SET change (superseded; upper bound on the true ratio)", trace_act)

# 🔴 주 경로 vs "항상 DP" 변형의 격차 — T_plan_next docstring 의 "남은 느슨함" 을 수치화한다.
let
    gaps, n_tighter = Float64[], 0
    for i in 1:NSTEPS
        dp = CB._zero_frontier_fallback(env, trace_closed[i], 1.0)   # = min{finish > 0}
        isfinite(dp) || continue
        dp < trace_dnext[i] - 1e-12 && (n_tighter += 1)
        push!(gaps, trace_dnext[i] / dp)
    end
    sg = sort(gaps)
    @info "T8 primary-path vs always-DP variant (how loose is the fallback-only choice)" n=length(gaps) n_steps_where_DP_is_tighter=n_tighter ratio_min=minimum(sg) ratio_median=_pct(sg, 0.50) ratio_max=maximum(sg)
end
