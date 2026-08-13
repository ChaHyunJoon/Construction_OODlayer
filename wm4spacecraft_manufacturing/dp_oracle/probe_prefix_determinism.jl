# wm4spacecraft_manufacturing/dp_oracle/probe_prefix_determinism.jl
#
# 묻는 것: "닫힌 노드 c 에서 사건을 주입할 때, 그 주입 순간의 상태가 재실행에서 같은가?"
# 런 전체의 재현성이 아니다 -- DP 표집이 요구하는 것은 prefix 뿐이다.
# 배경: gen_oracle_mc.jl 은 CB.schedule_ood_at_closed!(c, act) 로 닫힌 노드 수 c 에 도달하면
# 사건을 주입한다(gen_oracle_mc.jl:284 schedule_studied_fault!). 2026-08-11 에 관측된 발산
# (n_closed 149->123)은 런 "전체"의 숫자이므로 이 질문에 답하지 않는다 -- 그래서 이 프로브가 있다.
#
# 실행: julia +lts --project=. wm4spacecraft_manufacturing/dp_oracle/probe_prefix_determinism.jl
#
# 구현 메모 (task-1-report.md 에 상세 근거):
#   브리프의 예시 코드는 `CB.schedule_ood_at_closed!(AT_CLOSED, act)` 를 run_one() 호출 **전에**
#   등록한다. 그런데 gen_oracle_mc.jl 의 run_one 은 시작하자마자 `CB.clear_ood_schedule!()` 를
#   불러 그 등록을 지워버린다(gen_oracle_mc.jl:299-305) -- 그대로 쓰면 지문 트리거가 한 번도
#   발동하지 않는다. 그래서 run_one 을 그대로 재사용하는 대신, run_one 의 셋업 순서를 그대로
#   복제하되 "연구 대상 고장 주입" 자리에 "지문 찍기(주입 없음)" 트리거를 꽂은 `probe_run_one`
#   을 이 파일 안에 둔다. 시뮬레이션 로직(회로/파라미터/HOT_SWAP/배터리/스택 크기 등)은 전부
#   gen_oracle_mc.jl 의 상수를 그대로 재사용한다 -- 새 파라미터를 만들지 않는다.
using JSON3
include(joinpath(@__DIR__, "..", "oracle", "gen_oracle_mc.jl"))   # 상수·CB·K/SEED/HOT_SWAP/NSPARE/... 재사용

const N_REPEAT  = 10
const AT_CLOSED = 30            # prog_b 중간 구간을 대표하는 주입점

"""
    probe_run_one(fingerprint_act) -> env

`gen_oracle_mc.jl` 의 `run_one`(:297)과 **동일한** 셋업 순서를 그대로 복제한 것 -- 유일한 차이는
`inject && schedule_studied_fault!(hz_seed)` 자리에 우리 지문 트리거를 꽂는다는 점뿐이다(그 자리에
꽂아야 하는 이유는 위 코멘트 참조: run_one 이 시작하면서 스케줄을 지우므로, 지우는 지점보다
"뒤"에서 등록해야 한다). run_lego_demo 호출부의 키워드 인자는 run_one 과 바이트 단위로 동일.
"""
function probe_run_one(fingerprint_act)
    SEEN[] = nothing; N_EVENTS[] = 0
    CB.RESPEC_ENABLED[] = true
    try
        CB.disable_hazard!()
    catch
    end          # 이전 실행 잔여 상태 + 스텝 훅 원복
    for f in (:clear_ood_schedule!, :clear_restriction_zones!, :clear_spare_pools!,
        :clear_faulted_robots!, :clear_recovery_spares!, :clear_ood_truth_log!,
        :clear_wedge_edges!, :clear_stalled_robots!)
        try
            getproperty(CB, f)()
        catch
        end
    end
    try
        CB.set_reform_interval!(400)
    catch
    end
    HOT_SWAP && CB.set_hot_swap!(enabled = true, mode = :via_depot)
    CB.set_respec_producer!((env, ev) -> nothing)   # 지문 트리거는 나서지 않는다 -- 제안을 만들지 않음

    # 배터리 계층은 run_one 과 동일하게 스텝 1 에 켠다(SoC 지문을 찍으려면 배터리가 켜져 있어야 함).
    CB.schedule_ood!(1, function (env)
        CB.enable_battery!(env; params = CB.demo_battery_params(shrink = SHRINK))
        CB.set_battery_penalty!(gain = 6.0, soc_target = 0.5, hard_mult = 1.0e3)
        return nothing
    end)

    # *** run_one 의 `inject && schedule_studied_fault!(hz_seed)` 자리 -- 여기서는 위험 프로세스를
    # 켜지 않고(hz_seed 없음), 실제 고장도 주입하지 않는다(action 이 nothing 을 반환). 순수 지문. ***
    CB.schedule_ood_at_closed!(AT_CLOSED, fingerprint_act)

    res = run_with_stack(parse(Int, get(ENV, "MC_STACK", "1000000000"))) do
        CB.run_lego_demo(; ldraw_file = "tractor.mpd", num_robots = 10, assignment_mode = :greedy,
            milp_optimizer = :highs, optimizer_time_limit = 60, log_level = LOGLVL,
            max_num_iters_no_progress = NOPROG, rvo_flag = RVO, tangent_bug_flag = RVO,
            dispersion_flag = RVO, n_spare_per_pool = NSPARE, save_animation = false,
            open_animation_at_end = false, write_results = false, overwrite_results = true,
            return_env_before_sim = false, rng = Random.MersenneTwister(SEED))
    end
    try
        CB.disable_hazard!()
    catch
    end
    CB.clear_respec_producer!()
    CB.RESPEC_ENABLED[] = false

    return res isa Tuple ? res[1] : res
end

"""
주입 순간의 상태 지문. 값이 아니라 **재현되는가**만 본다.

접근자는 전부 저장소에 있는 것을 그대로 재사용한다(새로 만들지 않음):
  - closed/active/pending : `env.cache.closed_set` / `.active_set` / `.node_queue`
    (route_planning.jl:123-124, essential_tg_coponents.jl:1662 PlanningCache -- run_one 이
    `closed = length(env.cache.closed_set)` 로 결과를 만들 때 쓰는 것과 같은 필드)
  - sim_step  : `CB._current_sim_step()` (respec/asset_ledger.jl:102, `CB.set_sim_step!`
    이 매 스텝 갱신하는 전역 카운터의 getter)
  - soc       : `CB.battery_report().soc` (navigator/battery.jl:316 -- gen_oracle_mc.jl 도
    쓰지 않지만 배터리 모듈이 이미 제공하는 리포터를 그대로 씀; 로봇ID -> SoC Dict)
  브리프가 가정한 CB.n_closed / CB.sim_seconds / CB.n_active_agents / CB.agent_socs /
  CB.total_pending 이라는 이름의 함수는 저장소에 없다(확인: grep -rn "function n_closed" src/
  등으로 검색해도 무결과) -- 위 실제 접근자로 대체했다.

FAST-ABORT (프로브 전용 속도 트릭, 프로덕션 코드 아님):

`run_lego_demo` 는 `run_simulation!` 이 `project_complete(env)` 가 참이 될 때까지(또는
무진전 상한) 계속 스텝을 돈다 -- 첫 실측(스모크)에서 AT_CLOSED=30 지문은 sim_step=2 에서 이미
찍히는데도(closed_set 이 초기 스텝에 많은 "장부성" 노드를 한꺼번에 닫기 때문 -- 실측: closed=58),
전체 런은 끝까지(총 313 노드, 실측 makespan 스텝 ~800) 계속 돌아 1 회 83~91초가 든다. 지문은
찍힌 뒤로는 값이 다시 안 바뀌므로(Ref 로 잠금) 나머지 시뮬은 이 질문에 필요 없는 낭비다.

그래서 지문을 찍은 **직후**(스냅샷은 이미 불변 Dict 로 복사됐으므로 이 조작이 지문 값을 건드릴
수 없다) `ProjectComplete` 노드들을 강제로 closed_set 에 넣어 `project_complete(env)` 를 다음
스텝 체크에서 즉시 참으로 만든다(route_planning.jl:578 `project_complete`, demo_utils.jl:369-401
`simulate!` 의 `project_stop_bool` 체크가 매 스텝 안에서 이뤄지므로 `run_simulation!` 이 배치
루프 도중 즉시 break 한다). 실측: 이후 반복은 83s -> ~3s 로 떨어짐(1회차는 JIT/컴파일 워밍업
비용이 섞여 여전히 느림). `gen_oracle_mc.jl` 은 건드리지 않았다 -- 이 트릭은 이 프로브 파일에만
있다.
"""
function prefix_fingerprint()
    fp = Ref{Any}(nothing)
    act = function (env)
        fp[] === nothing || return nothing
        fp[] = Dict(
            "closed" => length(env.cache.closed_set),
            "active" => length(env.cache.active_set),
            "pending_queue" => length(env.cache.node_queue),
            "sim_step" => CB._current_sim_step(),
            "sim_seconds" => CB._current_sim_step() * env.dt,
            "soc_sorted" => sort(round.(collect(values(CB.battery_report().soc)); digits = 6)),
        )
        # 지문 스냅샷 완료 후에만 실행 -- fast-abort (위 문서 참조)
        for n in CB.get_nodes(env.sched)
            if CB.matches_template(CB.ProjectComplete, n)
                push!(env.cache.closed_set, CB.get_vtx(env.sched, n))
            end
        end
        return nothing            # 주입하지 않는다. 지문만 찍는다.
    end
    env = probe_run_one(act)
    fp[] === nothing && error("fingerprint trigger never fired -- AT_CLOSED=$AT_CLOSED not reached " *
                               "(closed_set 최종 크기 확인 필요)")
    return fp[], env
end

# ---- Step 2: N_REPEAT 회 반복, prefix 지문이 재현되는지 -------------------------------------
println("[probe] Step 2: prefix fingerprint x $N_REPEAT (AT_CLOSED=$AT_CLOSED, build_seed=$SEED)")
t0 = time()
fps = NamedTuple[]
envs = Any[]
for i in 1:N_REPEAT
    tr0 = time()
    fp, env = prefix_fingerprint()
    dt = time() - tr0
    push!(fps, (run = i, dt_s = dt, fp = fp))
    push!(envs, env)
    println("  [$i/$N_REPEAT] $(round(dt; digits = 1))s  $(JSON3.write(fp))")
end
identical = all(r -> r.fp == fps[1].fp, fps)
total_dt = time() - t0
mean_dt = total_dt / N_REPEAT

println(JSON3.write(Dict(
    "identical" => identical, "n" => N_REPEAT,
    "wall_s_total" => round(total_dt; digits = 1),
    "wall_s_mean" => round(mean_dt; digits = 1),
    "fingerprints" => [r.fp for r in fps],
)))

# ---- Step 3: deepcopy 충실성 (Step 2 가 false 일 때만) ---------------------------------------
# 주입 직후 상태(마지막 반복의 env)를 deepcopy 하고, 두 복제본을 **같은** 팔(NOOP)로 계속
# 진행시켜 결과가 같은지 본다. 다르면 PyCall 너머 rvo2(C++) 상태가 공유되고 있다는 뜻
# -> fork 경로 불가.
#
# 실측(소스 확인, 시뮬레이션이 아니라 grep 근거):
#   1) `deepcopy(env)` 자체는 시도해서 성공/실패를 기록한다.
#   2) 그런데 "두 복제본을 같은 팔로 계속 굴린다"는 전제가 이 하니스 구조상 성립하지 않는다:
#      - `run_lego_demo`(full_demo.jl:137)는 매번 **새** PlannerEnv 를 처음부터 만든다.
#        기존 env 를 이어받아 계속 진행시키는 재개(resume) 진입점이 없다(grep 결과: `run_one`,
#        `main_batch`, `main_sweep` 전부 `run_lego_demo(...)` 를 처음부터 새로 부른다).
#      - 물리 상태의 상당 부분이 **PlannerEnv 필드가 아니라 프로세스 전역 Ref/싱글턴**이다:
#          rvo_global_sim() / rvo_global_id_map()   (src/rvo_interface.jl:46 -- RVO2(C++, PyCall)
#              시뮬레이터 자체가 전역 하나뿐. step_environment!(env, sim=rvo_global_sim()) 의
#              기본 인자가 이 전역을 직접 가리킨다.)
#          BATTERY_FLEET  (src/navigator/battery.jl:111, Ref{Union{Nothing,BatteryFleet}})
#          HAZARD_STATE   (src/mdp/hazard.jl)
#          OOD_SCHEDULE   (src/respec/ood_injection.jl:1077)
#          SIM_STEP / asset ledger (src/respec/asset_ledger.jl:100)
#      `deepcopy(env)` 는 PlannerEnv 구조체만 복제한다 -- 위 전역들은 **복제되지 않고 두 "가지"가
#      계속 공유**한다. 즉 완벽하게 deepcopy 가 성공하더라도, 그 복제본 두 개를 각자 진행시키면
#      RVO 물리 스텝 하나가 동시에 두 계보 모두에 영향을 준다(같은 C++ 시뮬레이터 인스턴스이므로).
#      이건 시뮬레이션으로 재확인할 필요가 없는 구조적 사실이다 -- 소스에 싱글턴으로 박혀 있다.
if !identical
    println("\n[probe] Step 3: identical=false -> deepcopy fidelity probe (fork 후보 성립 여부)")

    base_env = envs[end]
    result = Dict{String,Any}("attempted" => true)
    try
        env_a = deepcopy(base_env)
        env_b = deepcopy(base_env)
        result["deepcopy_struct_succeeded"] = true
    catch e
        result["deepcopy_struct_succeeded"] = false
        result["deepcopy_error"] = sprint(showerror, e)
    end
    result["resume_entry_point_exists"] = false
    result["shared_global_state"] = [
        "rvo_global_sim() / rvo_global_id_map() -- src/rvo_interface.jl:46 (single RVO2/PyCall instance)",
        "BATTERY_FLEET -- src/navigator/battery.jl:111 (Ref, not a PlannerEnv field)",
        "HAZARD_STATE -- src/mdp/hazard.jl",
        "OOD_SCHEDULE -- src/respec/ood_injection.jl:1077",
        "SIM_STEP -- src/respec/asset_ledger.jl:100",
    ]
    result["verdict"] = "fork_not_viable"
    result["reasoning"] = "deepcopy(env) only clones the PlannerEnv struct. The RVO physics " *
        "simulator, battery fleet, hazard clocks, and OOD schedule all live in process-global " *
        "Refs/singletons outside PlannerEnv, so two deepcopy'd branches would still be driven " *
        "by the SAME RVO instance if stepped -- and there is no resume-from-env entry point to " *
        "step them at all (run_lego_demo always builds a fresh PlannerEnv from scratch)."
    println(JSON3.write(result))
    global DEEPCOPY_RESULT = result
    global DEEPCOPY_FIDELITY_OK = false
else
    println("\n[probe] Step 2 identical=true -> Step 3 (deepcopy) 건너뜀 (replay 경로가 이미 성립).")
    global DEEPCOPY_RESULT = nothing
    global DEEPCOPY_FIDELITY_OK = nothing
end

sampling_mode = identical ? "replay" : (DEEPCOPY_FIDELITY_OK === true ? "fork" : "measured")

raw = Dict(
    "identical" => identical, "n_repeat" => N_REPEAT, "at_closed" => AT_CLOSED,
    "build_seed" => SEED, "wall_s_total" => round(total_dt; digits = 1),
    "wall_s_mean" => round(mean_dt; digits = 1),
    "wall_s_per_run" => [round(r.dt_s; digits = 2) for r in fps],
    "fingerprints" => [r.fp for r in fps],
    "deepcopy_step3" => DEEPCOPY_RESULT,
    "sampling_mode" => sampling_mode,
)
open(joinpath(@__DIR__, "probe_result_raw.json"), "w") do io
    JSON3.write(io, raw)
end

println("\n[probe] DONE. identical=$identical  sampling_mode=$sampling_mode  " *
        "mean_wall_s=$(round(mean_dt; digits=1))")
