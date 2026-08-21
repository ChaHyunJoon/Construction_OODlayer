# tools/monitor/measure_reduction_evidence.jl
# spec §2-3 의 세 명제를 **실측한다**. 추정하지 않는다.
#   (a) dissolved_gates 가 비어 있지 않은 스텝의 비율  — 손실 압축의 크기
#   (b) binding 이 edges 에서 유도되는가              — 유도되면 다음 세대에서 뺀다
#   (c) active == frontier(closed, edges)             — active 를 뺀 근거의 재확인
#   (d) wedge_edges ⊆ edges                           — wedge 를 뺀 근거의 재확인
#
# 🔴 씬 생성은 SCENE-INCANTATION.md 가 정본이다. 브리프(task-R3-brief.md)의 원안은
# `return_env_before_sim` 없이 `run_lego_demo` 를 불러 판을 끝까지 굴리고(88 s 실측, 작은 씬
# 기준) `closed_set` 이 가득 찬 채 `active_set` 이 빈 **퇴화한 세계**를 재게 되며, 반환값도
# `PlannerEnv` 가 아니라 `Tuple{PlannerEnv,Dict}` 라 다음 줄에서 죽는다. 아래는 SCENE-INCANTATION
# 의 정본 형태(return_env_before_sim=true · write_results=false · n_spare_per_pool=2 ·
# rng 고정 · step_environment! → update_planning_cache! → set_sim_step! 순서)를 따르되, 씬
# 파일(tractor.mpd)·로봇 수(12)·hazard seed(3)·스텝 수(400)는 브리프가 지정한 값 그대로 쓴다
# (작은 게이트 씬보다 훨씬 크다 — 시간이 걸리는 게 정상이다, 시험이 아니라 측정이다).
#
# 🔴 브리프의 Step-1 코드 원안은 for 루프 본문에서 `cond || (x += 1)` 형태로만 카운터를 갱신해서
# 스크립트 최상위(top-level) soft-scope 문제를 우연히 피했다. 아래는 실패 스텝의 반례(Ruling C)
# 까지 남기려고 `if/elseif` 를 썼는데, 그러면 최상위 for 루프 안 중첩 if 블록의 대입이 Julia
# soft-scope 규칙 때문에 새 지역변수로 잡혀 다음 반복에서 `UndefVarError` 로 죽는다(실측). 그래서
# 전체를 함수로 감쌌다 — 관용적인 해법이고, 전역변수 루프보다 더 빠르기도 하다.
#
# 🔴 컨트롤러 라운드 1 피드백: `dissolved_nonempty_frac`·`binding_derivable_frac` 이 둘 다 0.0
# 이었는데, 0.0 은 두 가지 다른 뜻일 수 있다(① 실제로 한 번도 안 일어났다 ② 애초에 이 하네스가
# 그 일이 일어나는지 확인조차 안 한다). 아래 두 블록이 그 구분을 기계적으로 남긴다.
using ConstructionBots, JSON3
import Random
import Graphs
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
CB.include(joinpath(pkgdir(CB), "src", "smdp", "mdp.jl"))

"frontier(closed, edges) — essential_tg_coponents.jl:1921-1932 의 활성화 규칙 그대로."
function frontier(closed, edges, verts)
    preds = Dict(v => Int[] for v in verts)
    for (u, v) in edges; push!(preds[v], u); end
    return Set(v for v in verts if !(v in closed) && all(u -> u in closed, preds[v]))
end

"""
binding 진단: 정점 v 의 담당 로봇을 v 로 들어오는 엣지의 출발점(u)의 binding 으로 유도해 본다.
전체 분해(총계·무유도·오유도·정답)와 표본(카테고리별 최대 5개 정점)을 함께 남긴다 — `n_binding_ok`
(step 전체 all-match) 하나만으로는 "대부분 맞는데 몇 개가 틀렸다" 와 "거의 다 틀렸다" 를 구분 못
한다. 🔴 컨트롤러 라운드 2, Important 1: JSON 이 직렬화 가능한 `Dict` 로 리턴한다(`NamedTuple`
아님) — 이 진단이 `binding_derivable_frac=0.0` 재해석의 **유일한 근거**이므로 산출물 JSON 안에
그대로 남아야 한다(println 프로세로만 남으면 다음 사람이 JSON 만 열었을 때 근거가 없다).
"""
function binding_diag(g_edges, g_binding)
    derived = Dict{Int,Int}()
    for (u, v) in g_edges
        haskey(g_binding, u) && !haskey(derived, v) && (derived[v] = g_binding[u])
    end
    no_pred_verts, wrong_verts, correct_verts = Int[], Int[], Int[]
    for v in sort(collect(keys(g_binding)))
        d = get(derived, v, nothing)
        if d === nothing
            push!(no_pred_verts, v)
        elseif d == g_binding[v]
            push!(correct_verts, v)
        else
            push!(wrong_verts, v)
        end
    end
    mk(v) = Dict("v" => v, "actual" => g_binding[v], "derived" => get(derived, v, nothing))
    return Dict(
        "n_total"                    => length(g_binding),
        "n_derived_correct"          => length(correct_verts),
        "n_no_predecessor"           => length(no_pred_verts),   # 유도할 선행자 자체가 없음(루트형 정점)
        "n_derived_different"        => length(wrong_verts),     # 선행자는 있지만 binding 이 다름
        "all_ok"                     => isempty(no_pred_verts) && isempty(wrong_verts),
        "examples_no_predecessor"    => mk.(first(no_pred_verts, 5)),
        "examples_derived_different" => mk.(first(wrong_verts, 5)),
        "examples_correct"           => mk.(first(correct_verts, 5)),
    )
end

function main()
    env = CB.run_lego_demo(; ldraw_file = "tractor.mpd", project_name = "redevid",
                             num_robots = 12, assignment_mode = :greedy,
                             n_spare_per_pool = 2,
                             open_animation_at_end = false, save_animation = false,
                             write_results = false, return_env_before_sim = true,
                             rng = Random.MersenneTwister(1))
    CB.enable_battery!(env); CB.enable_hazard!(env; seed = 3)

    N = 400
    n_dissolved, n_binding_ok, n_frontier_ok, n_wedge_ok = 0, 0, 0, 0

    # 조용한 폴백 금지 — stop-condition 이 트립하면 첫 실패 스텝과 구체적 반례를 남긴다.
    # (측정값을 맞추려고 튜닝하지 않는다: 이 둘은 진단용이지 out 의 필드가 아니다.)
    first_frontier_fail = nothing
    first_wedge_fail = nothing
    # 🔴 컨트롤러 라운드 2, Important 1: 둘 다 Dict 로 모아 산출물 JSON 에 그대로 싣는다(아래
    # `out["alive_samples"]`·`out["binding_diag"]`) — 이전엔 println 으로만 남아서 JSON 만 읽는
    # 사람에게는 근거가 안 보였다.
    alive_samples = Dict[]
    binding_diag_samples = Dict[]

    # --- (a)-보강: dissolved_nonempty_frac=0.0 이 "안 일어났다" 인지 "안 쟀다" 인지 구분한다 ---
    # `maybe_unwedge_nominal!(env, no_progress)` 가 `DISSOLVED_GATES` 를 채우는 유일한 진입로다
    # (`resolve_schedule_wedge!` 경유, replace_robot.jl:1036). 그건 두 시뮬 루프(demo_utils.jl
    # `simulate!` · tools/monitor/run_demo.jl)에만 배선돼 있고, 이 스크립트의 수동 루프는 원래
    # 그걸 안 부른다(SCENE-INCANTATION 정본이 요구하는 세 호출에 없다) — 그래서 그 사실 자체를
    # 기계적으로 확인하려고 여기서 **같은 트리거로 직접** 불러 본다(무해함은 아래서 실측 확인).
    last_closed = length(env.cache.closed_set)
    no_progress = 0
    n_no_progress_steps = 0
    max_no_progress_streak = 0
    n_unwedge_fired = 0
    unwedge_interval = CB.UNWEDGE_INTERVAL[]

    for k in 1:N
        CB.step_environment!(env)
        CB.update_planning_cache!(env, 0.0)
        CB.set_sim_step!(k)

        s     = CB.simstate_of(env)
        verts = collect(CB.Graphs.vertices(env.sched))

        # simulate!(demo_utils.jl:255-266) 와 동일한 무진전 카운터 로직.
        nc = length(env.cache.closed_set)
        if nc == last_closed
            no_progress += 1
            n_no_progress_steps += 1
        else
            no_progress = 0
        end
        last_closed = nc
        max_no_progress_streak = max(max_no_progress_streak, no_progress)
        # 두 시뮬 루프가 부르는 것과 정확히 같은 함수·같은 인자를 여기서도 부른다(기계적 카운트,
        # 로그 아님). `UNWEDGE_INTERVAL[]`(기본 2000) > N(400) 이므로 `no_progress` 가 그 배수에
        # 닿을 수 없다 — 즉 아래 호출은 이 실행 전체에서 **항상 false 를 반환하도록 산술적으로
        # 보장돼 있다**(no_progress ≤ 400 < 2000). 부작용 없음이 실측이 아니라 산술로도 보장된다.
        #
        # 🔴 컨트롤러 라운드 2, minor 2 — 함정 경고: 이건 관찰(observe)이 아니라 **진짜 호출**이다.
        # `maybe_unwedge_nominal!` 이 트리거되면 `recover_stalled_teams!` 를 실제로 실행해 env 를
        # 고친다(부작용 있음) — 지금은 위 산술 때문에 안전할 뿐이다. **누군가 나중에 `N` 을 2000
        # 이상으로 올리면 이 줄이 측정 도중 조용히 복구 로직을 실행하기 시작한다** — 관측이 세계를
        # 바꾸는 계약 위반이자, "측정"이 "개입"으로 바뀌는 것이다. N 을 올릴 사람은 이 호출을
        # 지우거나(그러면 dissolved_nonempty_status 계측이 다시 원점) `UNWEDGE_INTERVAL[]` 을
        # `set_unwedge_interval!` 로 같이 올려서 계속 산술적으로 무해하게 만들 것.
        CB.maybe_unwedge_nominal!(env, no_progress) && (n_unwedge_fired += 1)

        isempty(CB.DISSOLVED_GATES[]) || (n_dissolved += 1)

        # (c) active 가 frontier 인가
        fr = frontier(s.prog.closed, s.g.edges, verts)
        act = Set(env.cache.active_set)
        if fr == act
            n_frontier_ok += 1
        elseif first_frontier_fail === nothing
            first_frontier_fail = (step = k,
                                    frontier_minus_active = sort(collect(setdiff(fr, act))),
                                    active_minus_frontier = sort(collect(setdiff(act, fr))))
        end

        # (d) wedge_edges ⊆ edges 인가
        missing_wedge = [e for e in CB.WEDGE_EDGES[] if !(e in s.g.edges)]
        if isempty(missing_wedge)
            n_wedge_ok += 1
        elseif first_wedge_fail === nothing
            first_wedge_fail = (step = k, missing_edges = missing_wedge)
        end

        # (b) binding 이 edges 만으로 재구성되는가.
        bd = binding_diag(s.g.edges, s.g.binding)
        bd["all_ok"] && (n_binding_ok += 1)

        if k in (1, 50, 100, 200, 300, 400)
            push!(alive_samples, Dict("step" => k, "n_closed" => length(env.cache.closed_set),
                                       "n_active" => length(env.cache.active_set),
                                       "n_verts" => length(verts)))
            push!(binding_diag_samples, merge(Dict("step" => k), bd))
        end
    end

    out = Dict("n_steps" => N,
               "dissolved_nonempty_frac" => n_dissolved / N,
               "binding_derivable_frac"  => n_binding_ok / N,
               "active_is_frontier_frac" => n_frontier_ok / N,
               "wedge_subset_frac"       => n_wedge_ok / N,
               # --- 컨트롤러 라운드 1 요청: 0.0 의 두 뜻을 구분하는 필드들 ---
               "unwedge_interval"          => unwedge_interval,
               "n_unwedge_fired"           => n_unwedge_fired,
               "n_no_progress_steps"       => n_no_progress_steps,
               "max_no_progress_streak"    => max_no_progress_streak,
               "dissolved_nonempty_status" => n_unwedge_fired > 0 ? "measured_nonzero_source" :
                   (max_no_progress_streak >= unwedge_interval ?
                    "measured_zero_despite_reachable_trigger" :
                    "NOT_MEASURED_trigger_unreachable_in_this_run"),
               # --- 컨트롤러 라운드 2, Important 1: 산출물 JSON 이 스스로 근거를 실어야 한다 ---
               # `alive_samples` = R3 가 퇴화한 세계를 재지 않았다는 증거(closed 단조증가, active
               # 한 번도 0/전체 안 됨). `binding_diag` = binding_derivable_frac=0.0 을 "binding
               # 은 유도 불가"가 아니라 "이 1-hop 휴리스틱이 21% 에서 실패"로 재해석하는 유일한
               # 근거 — 둘 다 프로세싱 없이 JSON 만 읽어도 보이게 여기 싣는다.
               "alive_samples" => alive_samples,
               "binding_diag"  => binding_diag_samples)
    mkpath(joinpath(pkgdir(CB), "results", "smdp"))
    open(joinpath(pkgdir(CB), "results", "smdp", "reduction_evidence.json"), "w") do io
        JSON3.pretty(io, out)
    end
    println(JSON3.write(out))
    println("ALIVE_SAMPLES: ", alive_samples)
    println("FIRST_FRONTIER_FAIL: ", first_frontier_fail)
    println("FIRST_WEDGE_FAIL: ", first_wedge_fail)
    println("BINDING_DIAG_SAMPLES:")
    for bd in binding_diag_samples
        println("  ", bd)
    end
end

main()
