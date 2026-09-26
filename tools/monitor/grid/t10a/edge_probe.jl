# edge_probe.jl — T5 이월 확인(T10a): X-wing t0 의 의미적 선행(건설↔건설 − WEDGE)에 런타임 복구가 더한 간선이 있는가.
#   julia +lts --project=. -L <this> tools/monitor/render_demo.jl   (pi0 셀 env, ZRV_EDGE_PROBE_OUT=<dir>)
# pre_sim_begin(계획 직후, 존 주입 전) · pre_sim_end(주입 후) · 첫 :step(= T3/T8 의 t0: iter 1 경계, 존 사건 대기)에서
# task_state 의 간선·노드 종류·WEDGE 를 떠서 JSON 으로 쓰고, t0 에서 derive_task_contract 를 부른 뒤 exit(0).
using ConstructionBots, JSON3
const CB = ConstructionBots
include(joinpath(pkgdir(CB), "src", "verification", "task_contract.jl"))
const OUT = ENV["ZRV_EDGE_PROBE_OUT"]; mkpath(OUT)
dumpstate(tag, env) = (s = TaskContract.task_state(env, CB);
    open(io -> JSON3.write(io, Dict("edges" => s["edges"], "nodes" => s["nodes"], "wedge_edges" => s["wedge_edges"],
                                    "closed" => s["closed"], "sim_step" => s["clock"]["sim_step"])), joinpath(OUT, tag * ".json"), "w"))
CB.HARNESS_HOOK[] = function (phase, env, ctx)
    if phase === :pre_sim_begin
        dumpstate("pre_injection", env)
    elseif phase === :pre_sim_end
        dumpstate("post_injection", env)
    elseif phase === :step
        dumpstate("t0", env)
        c = TaskContract.derive_task_contract(env, CB; checkpoint_id = "t0")
        open(io -> JSON3.write(io, c), joinpath(OUT, "t0_task_contract.json"), "w")
        println("[edge-probe] t0 iter=", ctx.sim_process_data.iter, " pending=", length(CB.RESPEC_QUEUE.pending)); flush(stdout)
        exit(0)
    end
end
