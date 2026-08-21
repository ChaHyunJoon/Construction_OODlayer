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

bench(f, n) = (f(); [(@elapsed f()) * 1000 for _ in 1:n])   # 첫 회는 컴파일 — 버린다

N = 20
d  = bench(() -> deepcopy(env), N)
s  = bench(() -> CB.simstate_of(env), N)
out = Dict("n" => N,
           "deepcopy_ms"    => (median = median(d), min = minimum(d), max = maximum(d)),
           "simstate_of_ms" => (median = median(s), min = minimum(s), max = maximum(s)),
           "n_robots" => length(CB.BATTERY_FLEET[].soc),
           "n_closed" => length(env.cache.closed_set))
mkpath(joinpath(pkgdir(CB), "results", "smdp"))
open(joinpath(pkgdir(CB), "results", "smdp", "branch_cost.json"), "w") do io
    JSON3.pretty(io, out)
end
println(JSON3.write(out))
