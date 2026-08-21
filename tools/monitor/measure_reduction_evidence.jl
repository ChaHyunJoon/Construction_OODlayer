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
#   julia +lts --project=. tools/monitor/measure_reduction_evidence.jl
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
    alive_samples = NamedTuple[]

    for k in 1:N
        CB.step_environment!(env)
        CB.update_planning_cache!(env, 0.0)
        CB.set_sim_step!(k)

        s     = CB.simstate_of(env)
        verts = collect(CB.Graphs.vertices(env.sched))

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
        #     정점 v 의 담당 로봇을, v 로 들어오는 엣지의 출발점 중 로봇 정점인 것으로 유도해 본다.
        derived = Dict{Int,Int}()
        for (u, v) in s.g.edges
            haskey(s.g.binding, u) && !haskey(derived, v) && (derived[v] = s.g.binding[u])
        end
        all(k2 -> get(derived, k2, nothing) == s.g.binding[k2],
            collect(keys(s.g.binding))) && (n_binding_ok += 1)

        if k in (1, 50, 100, 200, 300, 400)
            push!(alive_samples, (step = k, n_closed = length(env.cache.closed_set),
                                   n_active = length(env.cache.active_set),
                                   n_verts = length(verts)))
        end
    end

    out = Dict("n_steps" => N,
               "dissolved_nonempty_frac" => n_dissolved / N,
               "binding_derivable_frac"  => n_binding_ok / N,
               "active_is_frontier_frac" => n_frontier_ok / N,
               "wedge_subset_frac"       => n_wedge_ok / N)
    mkpath(joinpath(pkgdir(CB), "results", "smdp"))
    open(joinpath(pkgdir(CB), "results", "smdp", "reduction_evidence.json"), "w") do io
        JSON3.pretty(io, out)
    end
    println(JSON3.write(out))
    println("ALIVE_SAMPLES: ", alive_samples)
    println("FIRST_FRONTIER_FAIL: ", first_frontier_fail)
    println("FIRST_WEDGE_FAIL: ", first_wedge_fail)
end

main()
