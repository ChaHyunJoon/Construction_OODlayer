# =============================================================================
# tools/monitor/fit_rho.jl — Task T10 Step 1·2. **ρ 를 노드 소요시간 데이터에서 적합한다.**
#
#   julia +lts --project=. tools/monitor/fit_rho.jl
#
# 무엇을 재는가: 무거운 레인(= 실제 엔진, 3계층 reactive 스택 포함)을 **hazard 없이** 굴리면서
# 스케줄 정점마다
#
#     계획 소요시간 = node_duration(env, v) = get_min_duration(sched, v)   [하한, tplan.jl 축 2]
#     실현 소요시간 = (그 정점이 닫힌 시각) − (그 정점이 active_set 에 처음 들어온 시각)
#
# 을 기록하고 `ρ = median(실현/계획)` 을 낸다. **평균이 아니라 중앙값**이다 — 교착 한 번이
# 평균을 통째로 끌고 간다(브리프 Step 2).
#
# 🔴 활성화 시각은 `get_t0` 가 **아니다.** D-6 이 실측으로 남긴 대로 `get_t0` 는 런 내내 0.0 에
#    붙박여 있다(레포의 호출자가 전부 `t = 0.0` 을 넘겨 `update_schedule_times!` 가 실질적으로
#    도달하지 않는다). 그래서 이 스크립트가 **스텝 루프에서 직접** 활성화 시각을 기록한다.
#    그 선택이 실제로 값을 갖는다는 것을 §음성 대조 A 가 `get_t0` 판을 같이 재서 보인다.
#
# 🔴 **N-G1 을 보지 않는다.** 이 파일은 `sample_sojourn` 도 `gate_ng1` 도 `ng1_*.json` 도
#    참조하지 않는다(grep 으로 확인 가능). ρ 를 "게이트가 통과할 때까지" 올리는 것은 적합이
#    아니라 게이트에 맞춘 교정이고, 그렇게 얻은 ρ 는 N-G1 이 검사하기로 되어 있는 오차를
#    흡수한다. 적합 규칙(median)과 모집단(아래 FIT_* 손잡이)은 **결과를 보기 전에** 정해졌다.
#
# 🔴 **`dt_sim = 0.025 s` 눈금이 분모가 아니라 분자에 있다.** 계획 소요시간(분모)은 연속값이고,
#    실현 소요시간(분자)은 **스텝 수 × dt_sim** 이라 0.025 s 격자 위에 있다. 그래서 비 하나의
#    분해능은 `dt_sim / pred` 이고, 짧은 노드일수록 거칠다. 스크립트가 그 분포를 같이 찍는다
#    (`n_actual_le3_steps` · `ratio_quantum_median`) — 적합의 유효 자릿수가 거기서 정해진다.
#
# 🔴 조용한 폴백 금지: 비유한 비 · 빈 표본 · 음수 소요시간은 전부 `error()`.
# 🔴 결정성: 모든 `Set`/`Dict` 순회는 `sort!` 를 통과한다.
# =============================================================================
using ConstructionBots
import Random, Graphs
import JSON3
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
CB.include(joinpath(pkgdir(CB), "src", "smdp", "mdp.jl"))

# 🔴 **세계 지문(world fingerprint).** `nondeterminism-investigation.md` 가 규명한 대로, CB 를
#    재precompile 하면 `TypeName.hash` 가 다시 굴러 모든 ID 타입의 `hash`/`objectid` 가 바뀌고
#    배정 DAG 가 갈린다. 즉 **이 값이 같으면 두 실행이 같은 세계**다. ρ 적합과 N-G1 재검이
#    "같은 디렉토리·같은 세션" 이라는 주장을 산문이 아니라 **이 숫자**로 남긴다.
const WORLD_FP = hash(CB.ObjectID(1))
@info "세계 지문" hash_ObjectID_1=WORLD_FP pkgdir=pkgdir(CB)


# --- 적합 모집단 (결과를 보기 전에 정해진 것) --------------------------------
const FIT_FILE    = get(ENV, "FIT_FILE", "tractor.mpd")          # 브리프 지정
const FIT_ROBOTS  = parse(Int, get(ENV, "FIT_ROBOTS", "10"))     # project_params.jl 의 tractor 기본값
const FIT_MAXSTEP = parse(Int, get(ENV, "FIT_MAXSTEP", "60000"))
const FIT_STALL   = parse(Int, get(ENV, "FIT_STALL", "6000"))    # 이 스텝 동안 아무것도 안 닫히면 정지
const FIT_SEED    = parse(Int, get(ENV, "FIT_SEED", "1"))

"""정점별 (활성화 시각, 닫힌 시각) 을 스텝 루프에서 직접 기록한다.

반환: `(env, act_at, close_at, t0_at, steps, stalled_at, dt_sim)`.
`t0_at[v] = get_t0(sched, v)` 는 **음성 대조 A** 전용이다 — 판정에 쓰지 않는다.
"""
function trace_durations(; file::String, robots::Int, maxstep::Int, stall::Int, seed::Int)
    t_build = time()
    env = CB.run_lego_demo(; ldraw_file = file, project_name = "fit_rho",
                             num_robots = robots, assignment_mode = :greedy,
                             n_spare_per_pool = 2,
                             open_animation_at_end = false, save_animation = false,
                             write_results = false, return_env_before_sim = true,
                             rng = Random.MersenneTwister(seed))
    CB.enable_battery!(env)
    # 🔴 hazard 는 켜지 않는다(브리프 Step 1: "hazard 없이 완주"). 확률적 고장이 섞이면
    #    실현 소요시간이 "계획이 하한이라서 길어진 것" 과 "고장이 나서 길어진 것" 의 혼합이
    #    되고, ρ 가 흡수해야 할 것과 아닌 것이 한 값으로 뭉개진다.
    CB.HAZARD_ENABLED[] == false ||
        error("fit_rho: HAZARD_ENABLED[] = true — 이 적합은 hazard-off 판에서만 뜻이 있다")

    NV     = Graphs.nv(env.sched)
    dt_sim = env.dt * CB.BATTERY_FLEET[].params.seconds_per_step
    @info "fit_rho 씬" file=file robots=robots n_vertices=NV dt_sim=dt_sim build_s=(time() - t_build)

    act_at   = Dict{Int,Float64}()
    close_at = Dict{Int,Float64}()
    for v in sort!(collect(env.cache.active_set)); act_at[v] = 0.0; end
    for v in sort!(collect(env.cache.closed_set)); close_at[v] = 0.0; act_at[v] = 0.0; end
    n_act0 = length(env.cache.active_set)

    CB.set_sim_step!(0)
    k, last_progress, n_closed_prev = 0, 0, length(env.cache.closed_set)
    t_run = time()
    while k < maxstep
        k += 1
        CB.step_environment!(env)
        newly = CB.update_planning_cache!(env, 0.0)
        CB.set_sim_step!(k)
        t = CB.sim_time(env.dt)          # = env.dt * SIM_STEP[]  (asset_ledger.jl:108)
        for v in sort!(collect(newly))
            # 같은 호출 안에서 활성화되고 곧바로 닫힌 정점은 여기서 처음 보인다 →
            # 활성화 시각도 지금이다(실현 소요시간 0). 조용히 버리지 않는다.
            haskey(act_at, v) || (act_at[v] = t)
            close_at[v] = t
        end
        for v in sort!(collect(env.cache.active_set))
            haskey(act_at, v) || (act_at[v] = t)
        end
        nc = length(env.cache.closed_set)
        nc > n_closed_prev && (last_progress = k; n_closed_prev = nc)
        nc >= NV && break
        (k - last_progress) >= stall && break
        (k % 5000 == 0) && @info "fit_rho 진행" step=k n_closed=nc nv=NV wall_s=(time() - t_run)
    end
    n_closed = length(env.cache.closed_set)
    @info "fit_rho 런 종료" steps=k sim_s=(k * dt_sim) n_closed=n_closed nv=NV n_active0=n_act0 last_progress_step=last_progress complete=(n_closed >= NV) wall_s=(time() - t_run)

    t0_at = Dict{Int,Float64}(v => Float64(CB.get_t0(env.sched, v)) for v in 1:NV)
    return (env, act_at, close_at, t0_at, k, last_progress, dt_sim, n_closed, NV)
end

"정렬된 표본의 p 분위(내림 보간 없음 — 순수 순서통계량)."
_pct(sv::Vector{Float64}, p::Float64) = sv[clamp(ceil(Int, p * length(sv)), 1, length(sv))]

env, act_at, close_at, t0_at, STEPS, LASTPROG, DT_SIM, N_CLOSED, NV =
    trace_durations(; file = FIT_FILE, robots = FIT_ROBOTS, maxstep = FIT_MAXSTEP,
                      stall = FIT_STALL, seed = FIT_SEED)

# --- 짝을 만든다 --------------------------------------------------------------
# 🔴 `pred == 0` 인 정점은 비의 분모가 0 이라 **표본에서 뺀다**(0 으로 때우지 않는다 — 그러면
#    "즉시 끝나는 노드" 와 "계획이 하한이라 늘어난 노드" 가 한 값으로 합쳐진다). 몇 개를 뺐는지
#    는 산출물에 적는다. 이 정점들이야말로 T10 의 **드레인 프로브**가 다루는 모집단이다.
"닫힌 정점마다 (비, 계획, 실현, 스텝수, get_t0-판 비) 를 낸다. `pred == 0` 은 세고 뺀다."
function make_pairs(env, act_at, close_at, t0_at, dt::Float64)
    vs        = sort!(collect(keys(close_at)))
    ratios    = Float64[]
    preds     = Float64[]
    actuals   = Float64[]
    steps_of  = Int[]
    ratios_t0 = Float64[]                 # 음성 대조 A
    n_zero_pred = 0
    for v in vs
        haskey(act_at, v) ||
            error("fit_rho: 정점 $(v) 가 닫혔는데 활성화 시각이 없다 — 기록기가 프론티어를 놓쳤다")
        d = CB.node_duration(env, v)      # 스케줄 밖 정점·음수·비유한은 여기서 죽는다
        a = close_at[v] - act_at[v]
        a < 0.0 &&
            error("fit_rho: 정점 $(v) 의 실현 소요시간이 $(a) < 0 — 닫힘이 활성화보다 먼저다")
        if d <= 0.0
            n_zero_pred += 1
            continue
        end
        r = a / d
        isfinite(r) || error("fit_rho: 정점 $(v) 의 비가 비유한($(r)) — 조용히 건너뛰지 않는다")
        push!(ratios, r); push!(preds, d); push!(actuals, a)
        push!(steps_of, round(Int, a / dt))
        push!(ratios_t0, (close_at[v] - t0_at[v]) / d)
    end
    return (vs, ratios, preds, actuals, steps_of, ratios_t0, n_zero_pred)
end

"""🔴 `pred == 0` 인 정점의 **실현** 소요시간(스텝 수). 비의 분모가 0 이라 적합에서는 빠지지만
이 분포가 T10 드레인 프로브의 모집단 그 자체다 — "엔진은 그런 정점에도 `dt_sim` 을 쓴다" 는
서술이 참인지 여기서 직접 잰다(추측하지 않는다)."""
function zero_pred_actual_steps(env, act_at, close_at, dt::Float64)
    out = Int[]
    for v in sort!(collect(keys(close_at)))
        haskey(act_at, v) || continue
        CB.node_duration(env, v) <= 0.0 || continue
        push!(out, round(Int, (close_at[v] - act_at[v]) / dt))
    end
    return out
end

vs, ratios, preds, actuals, steps_of, ratios_t0, n_zero_pred =
    make_pairs(env, act_at, close_at, t0_at, DT_SIM)

isempty(ratios) &&
    error("fit_rho: 비 표본이 비어 있다 — `pred > 0` 이고 닫힌 정점이 하나도 없다. " *
          "기본값으로 때우지 않는다")

# 🔴 음성 대조 B — 표본이 납작하면 중앙값은 적합이 아니라 상수다.
length(unique(ratios)) >= 2 ||
    error("fit_rho: 비 표본이 상수($(first(ratios)))다 — 적합할 것이 없다")
length(unique(preds)) >= 2 ||
    error("fit_rho: 계획 소요시간이 전부 같다 — 이 모집단으로는 ρ 를 적합할 수 없다")

sr   = sort(ratios)
RHO_FIT = _pct(sr, 0.50)                 # 🔴 적합 규칙: 중앙값. 결과를 보기 전에 정한 것
P10  = _pct(sr, 0.10)
P90  = _pct(sr, 0.90)
MEAN = sum(ratios) / length(ratios)

# --- 눈금(양자화) 진단 --------------------------------------------------------
# 🔴 T8 이 D-6 표에서 부딪힌 자리와 **같은 자리**다: 비가 "정확히 1.0" 인 것들이 곧 눈금이
#    거친 짧은 구간들이면, 중앙값 1.0 은 측정이 아니라 **시계**다. 그래서 두 집합이
#    일치하는지를 여기서 직접 센다(인용하지 않고 이 실행에서 다시 잰다).
quanta   = sort!([DT_SIM / p for p in preds])
n_le3    = count(<=(3), steps_of)
n_step0  = count(==(0), steps_of)
sr_t0    = sort(ratios_t0)

# 계획 소요시간도 같은 눈금 위에 있는가 — 분모가 격자면 비가 유리수 격자에 갇힌다.
pred_steps      = [p / DT_SIM for p in preds]
n_pred_on_grid  = count(p -> abs(p - round(p)) <= 1e-9, pred_steps)
idx_exact1      = [i for i in eachindex(ratios) if ratios[i] == 1.0]
n_exact1        = length(idx_exact1)
n_exact1_le3    = count(i -> steps_of[i] <= 3, idx_exact1)
# 계획이 4스텝 이상인 부분모집단 = 비 하나의 분해능이 25% 보다 고운 자리
idx_ge4         = [i for i in eachindex(ratios) if pred_steps[i] >= 4.0 - 1e-9]
idx_ge8         = [i for i in eachindex(ratios) if pred_steps[i] >= 8.0 - 1e-9]
_sub(idx, p)    = isempty(idx) ? NaN : _pct(sort([ratios[i] for i in idx]), p)
@info "🔴 fit_rho 눈금 일치 검사 (T8 이 D-6 표에서 부딪힌 자리)" n_pred_on_dt_grid=n_pred_on_grid n_pred=length(preds) n_ratio_exactly_1=n_exact1 n_ratio_exactly_1_with_actual_le3_steps=n_exact1_le3 sets_coincide=(n_exact1 == n_exact1_le3) frac_ratio_exactly_1=(n_exact1 / length(ratios))
@info "🔴 fit_rho 부분모집단(눈금이 덜 지배하는 자리)" n_pred_ge4_steps=length(idx_ge4) median_ge4=_sub(idx_ge4, 0.5) p10_ge4=_sub(idx_ge4, 0.1) p90_ge4=_sub(idx_ge4, 0.9) n_pred_ge8_steps=length(idx_ge8) median_ge8=_sub(idx_ge8, 0.5) p10_ge8=_sub(idx_ge8, 0.1) p90_ge8=_sub(idx_ge8, 0.9)

@info "fit_rho 적합" n_nodes=length(ratios) rho_median=RHO_FIT ratio_p10=P10 ratio_p90=P90 ratio_mean=MEAN ratio_min=first(sr) ratio_max=last(sr) spread_p90_over_p10=(P10 > 0 ? P90 / P10 : Inf)
@info "fit_rho 모집단" n_closed=N_CLOSED n_vertices=NV n_zero_pred_excluded=n_zero_pred pred_min=minimum(preds) pred_median=_pct(sort(preds), 0.5) pred_max=maximum(preds) actual_median=_pct(sort(actuals), 0.5)
@info "fit_rho 눈금(양자화)" dt_sim=DT_SIM n_actual_le3_steps=n_le3 frac_le3=(n_le3 / length(steps_of)) n_actual_0_steps=n_step0 ratio_quantum_median=_pct(quanta, 0.5) ratio_quantum_p90=_pct(quanta, 0.9) ratio_quantum_max=last(quanta)
@info "🔴 fit_rho 음성 대조 A — get_t0 를 활성화 시각으로 쓰면(D-6 이 금지한 것)" rho_median_t0=_pct(sr_t0, 0.5) p10=_pct(sr_t0, 0.1) p90=_pct(sr_t0, 0.9) n_t0_nonzero=count(!=(0.0), [t0_at[v] for v in vs]) max_t0=maximum(t0_at[v] for v in vs)

# --- 🔴 `pred == 0` 정점의 실현 시간 (드레인 프로브의 모집단) -------------------
zp = sort(zero_pred_actual_steps(env, act_at, close_at, DT_SIM))
@info "🔴 fit_rho — pred==0 정점이 엔진에서 실제로 쓴 시간(스텝)" n=length(zp) n_0_steps=count(==(0), zp) n_1_step=count(==(1), zp) n_le3_steps=count(<=(3), zp) median_steps=(isempty(zp) ? -1 : zp[max(1, div(length(zp), 2))]) max_steps=(isempty(zp) ? -1 : last(zp)) mean_steps=(isempty(zp) ? NaN : sum(zp)/length(zp)) dt_sim=DT_SIM

# --- 산출 --------------------------------------------------------------------
out = Dict(
    "rho"        => RHO_FIT,
    "n_nodes"    => length(ratios),
    "ratio_p10"  => P10,
    "ratio_p90"  => P90,
    "ratio_mean" => MEAN,
    "ratio_min"  => first(sr),
    "ratio_max"  => last(sr),
    "spread_p90_over_p10" => (P10 > 0 ? P90 / P10 : Inf),
    "fit_rule"   => "median(actual/planned) over closed vertices with planned > 0",
    "meta" => Dict(
        "file" => FIT_FILE, "robots" => FIT_ROBOTS, "seed" => FIT_SEED,
        "hazard" => "off", "battery" => "on",
        "n_vertices" => NV, "n_closed" => N_CLOSED, "complete" => (N_CLOSED >= NV),
        "steps" => STEPS, "last_progress_step" => LASTPROG, "sim_s" => STEPS * DT_SIM,
        "dt_sim" => DT_SIM,
        "n_zero_pred_excluded" => n_zero_pred,
        "n_actual_le3_steps" => n_le3, "frac_actual_le3_steps" => n_le3 / length(steps_of),
        "n_actual_0_steps" => n_step0,
        "ratio_quantum_median" => _pct(quanta, 0.5),
        "ratio_quantum_p90"    => _pct(quanta, 0.9),
        "zero_pred_actual_steps" => Dict(
            "n" => length(zp), "n_0_steps" => count(==(0), zp), "n_1_step" => count(==(1), zp),
            "n_le3_steps" => count(<=(3), zp),
            "median_steps" => (isempty(zp) ? -1 : zp[max(1, div(length(zp), 2))]),
            "max_steps" => (isempty(zp) ? -1 : last(zp))),
        "n_pred_on_dt_grid" => n_pred_on_grid,
        "n_ratio_exactly_1" => n_exact1,
        "n_ratio_exactly_1_with_actual_le3_steps" => n_exact1_le3,
        "subpop_pred_ge4_steps" => Dict("n" => length(idx_ge4), "median" => _sub(idx_ge4, 0.5),
                                        "p10" => _sub(idx_ge4, 0.1), "p90" => _sub(idx_ge4, 0.9)),
        "subpop_pred_ge8_steps" => Dict("n" => length(idx_ge8), "median" => _sub(idx_ge8, 0.5),
                                        "p10" => _sub(idx_ge8, 0.1), "p90" => _sub(idx_ge8, 0.9)),
        "pred_min" => minimum(preds), "pred_median" => _pct(sort(preds), 0.5),
        "pred_max" => maximum(preds),
        "negative_control_t0" => Dict(
            "rho_median_if_get_t0_were_used" => _pct(sr_t0, 0.5),
            "n_t0_nonzero" => count(!=(0.0), [t0_at[v] for v in vs]),
            "max_t0" => maximum(t0_at[v] for v in vs),
            "note" => "D-6: get_t0 는 런 내내 0.0 이다. 이 값이 위의 rho 와 크게 다르면 " *
                      "기록기가 실제로 활성화 시각을 재고 있다는 뜻이다"),
        "ng1_consulted" => false,
    ),
)
outdir = joinpath(pkgdir(CB), "results", "smdp")
const FIT_OUT = get(ENV, "FIT_OUT", "rho.json")
mkpath(outdir)
open(joinpath(outdir, FIT_OUT), "w") do io
    JSON3.write(io, out)
end
@info "fit_rho 기록" path=joinpath(outdir, FIT_OUT) rho=RHO_FIT

# 🔴 브리프 Step 4 의 판정: 산포가 3배를 넘으면 **스칼라 ρ 하나로 부족하다**(spec §10 미해결 5).
#    여기서 모델을 늘리지 않는다 — 사실만 적는다.
if P10 > 0 && P90 / P10 > 3.0
    @warn "🔴 fit_rho: ratio_p90/ratio_p10 > 3 — 스칼라 ρ 하나로 부족하다(spec §10 미해결 5번). " *
          "혼잡도 의존 ρ 는 후속 작업이다. 이 태스크에서 모델을 늘리지 않는다" p10=P10 p90=P90 spread=(P90 / P10)
end
