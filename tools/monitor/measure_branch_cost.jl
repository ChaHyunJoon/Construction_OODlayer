# tools/monitor/measure_branch_cost.jl
# G(s,a) 1단계(갈래용 env 만들기)의 비용을 잰다. **추정하지 말고 잰다** — MCTS 예산이 여기서 나온다.
#   julia +lts --project=. tools/monitor/measure_branch_cost.jl
#
# task-5-brief.md 의 스크립트를 그대로 두지 않고 두 곳을 고쳤다 (task-5-brief.md 의 "Verified
# facts"·controller ruling C-4 근거):
#   1. `rendering=false, process_animation_tasks=false` 삭제. `_run_lego_demo_impl`
#      (src/full_demo.jl:163-212) 에 `rendering` 키워드가 없고, `process_animation_tasks` 는
#      `:216` 에서 계산되는 지역변수라 kwarg 로 넘기면 `unsupported keyword argument` 로 죽는다
#      (Task 4 가 이미 실측: task-4-report.md §3-P5).
#   2. `return_env_before_sim=true, write_results=false` 추가. 없으면 `run_lego_demo` 가
#      시뮬레이션을 끝까지 돌려버려서(최대 100000 스텝) 이 스크립트가 바라는 "정확히 200 스텝
#      수동 전진"이 성립하지 않는다 — `return_env_before_sim` 은 시뮬 루프 직전의 완성된 env 를
#      그대로 돌려준다(src/full_demo.jl:861, Task 4 가 같은 이유로 씀).
# 그 외(팔 이름, 트랙터 씬 파일명 "tractor.mpd")는 브리프 그대로다.
#   3. 🔴 Task R3R4 재측정 시 SCENE-INCANTATION.md 대조 중 발견: 스텝 루프 안의 호출 순서가
#      `step_environment! → set_sim_step! → update_planning_cache!` 로 돼 있었는데, 정본은
#      `step_environment! → update_planning_cache! → set_sim_step!` 다(SCENE-INCANTATION.md:
#      "계획서는 가운데 둘이 뒤바뀌어 있다"). 고쳤다. n_spare_per_pool·rng 는 **의도적으로
#      추가하지 않았다** — 이 스크립트의 목적이 상태 축소 전/후 비용의 before/after 비교이므로
#      씬 크기(로봇 수 등)를 이전 측정과 최대한 동일하게 유지하는 편이 낫다(Ruling B: 디렉토리
#      교란은 이미 있으니 추가로 씬 자체를 바꿔 잡음을 더 얹지 않는다).
using ConstructionBots, Statistics, JSON3
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
CB.include(joinpath(pkgdir(CB), "src", "smdp", "mdp.jl"))

env = CB.run_lego_demo(; ldraw_file = "tractor.mpd", project_name = "branchcost",
                         num_robots = 12, assignment_mode = :greedy,
                         open_animation_at_end = false, save_animation = false,
                         return_env_before_sim = true, write_results = false)
CB.enable_battery!(env); CB.enable_hazard!(env; seed = 1)
for k in 1:200
    CB.step_environment!(env)
    CB.update_planning_cache!(env, 0.0)
    CB.set_sim_step!(k)
end

# 🔴 컨트롤러 라운드 3, minor 1: `@elapsed` 는 GC 시간을 **버린다**(측정에서 빠짐) — 그래서
# 이전 라운드의 스파이크(simstate_of_ms.max=61.567 vs median=17.230) 설명이 "GC 일 것 같다"는
# 미검증 추측에 머물렀다. `@timed` 로 바꾸면 같은 호출에서 경과시간과 GC 시간을 **동시에** 얻어
# 그 추측을 공짜로 검증할 수 있다(추가 실행 비용 없음, `@elapsed` 와 같은 호출 1번).
function bench(f, n)
    f()   # 첫 회는 컴파일 — 버린다
    elapsed_ms = Float64[]
    gc_ms      = Float64[]
    for _ in 1:n
        r = @timed f()
        push!(elapsed_ms, r.time * 1000)
        push!(gc_ms, r.gctime * 1000)
    end
    return elapsed_ms, gc_ms
end

N = 20
d, d_gc = bench(() -> deepcopy(env), N)
s, s_gc = bench(() -> CB.simstate_of(env), N)
d_max_i = argmax(d)   # 가장 느렸던 호출의 인덱스 — 그 호출의 GC 시간을 바로 대응시켜 본다
s_max_i = argmax(s)
out = Dict("n" => N,
           "deepcopy_ms"    => (median = median(d), min = minimum(d), max = maximum(d)),
           "simstate_of_ms" => (median = median(s), min = minimum(s), max = maximum(s)),
           # --- 컨트롤러 라운드 3, minor 1: GC 가설을 직접 검정한다(더 이상 추측이 아니다) ---
           "deepcopy_gc_ms"    => (median = median(d_gc), min = minimum(d_gc), max = maximum(d_gc),
                                    at_max_elapsed_call = d_gc[d_max_i]),
           "simstate_of_gc_ms" => (median = median(s_gc), min = minimum(s_gc), max = maximum(s_gc),
                                    at_max_elapsed_call = s_gc[s_max_i]),
           "n_robots" => length(CB.BATTERY_FLEET[].soc),
           "n_closed" => length(env.cache.closed_set))
mkpath(joinpath(pkgdir(CB), "results", "smdp"))
open(joinpath(pkgdir(CB), "results", "smdp", "branch_cost.json"), "w") do io
    JSON3.pretty(io, out)
end
println(JSON3.write(out))
