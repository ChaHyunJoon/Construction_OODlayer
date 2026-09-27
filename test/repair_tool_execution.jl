# =============================================================================
# test/repair_tool_execution.jl — T6 격리 집행·효과별 후처리 게이트 (단독 실행, runtests.jl 미포함 — 브리프 요구 없음).
#
#   julia +lts --project=. test/repair_tool_execution.jl
#
# 실제 씬(colored_8x8)을 **production 루프로** 굴리다가 스텝 경계 훅(`HARNESS_HOOK`, T3 과 같은 자리)에서 worker 와
# 같은 함수 `ToolExecution.enact_proposal!` 를 부른다 — 진짜 `SimParameters`·`SimProcessingData`·배치 위치·RVO(T3 의
# `RVOSimHarness` 기록 모드, worker 와 같다)가 들어간다. 도구는 전부 손으로 쓴 fixture source(Julia 함수)이고
# production `register_minted_primitive!`(Core.eval)로 등록된다. 판정은 T5 CB-free 검증기(`validate_effects`)와 이
# 태스크의 `judge_candidate` 가 한다. 별도 프로세스 worker 경로는 `test/repair_tool_execution_branch.jl`.
#   T6_ONLY=2,7b julia +lts --project=. test/repair_tool_execution.jl   # 사례 부분 실행(변이 측정용)
# =============================================================================
using ConstructionBots, Test, Random, JSON3, SHA
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
include(joinpath(@__DIR__, "..", "tools", "monitor", "repair_branch_worker.jl"))   # T4 감사 + T6 (훅은 역할 env 없으면 안 깔린다)
const TX = ToolExecution
const TC = TaskContract
const EV = EffectValidation
const R = RepairTypes
const E = EpisodeCheckpointIO
const W = RepairBranchWorker
const ER = EpisodeReplay
CB.RVO_RECORD_BUILDS[] = true          # worker(T3 install!)와 같은 RVO 래퍼 — engine 카운터 `rvo_doSteps` 가 산다

struct _Stop <: Exception end
rt(x) = JSON3.read(JSON3.write(x), x isa AbstractVector ? Vector{Any} : Dict{String,Any})
# 교차 런 비교([2]: NOOP 런 대 도구 런 — 다른 객체)라 첫 방문 경로 표기(:path)다. 같은 런 안의 감사는 worker `audit_snapshot`(:identity).
fields(env) = (w = E.world_lines(env; modules = [CB]); E.field_digests(w.lines, w.fields))

"""
colored_8x8 을 production `run_lego_demo` 루프로 굴리다 `iter >= at` 인 첫 스텝 경계에서 `f(env, ctx)` 를 부르고
바깥 루프를 버린다(worker 의 `branch!` 와 같은 구조). `on_step(iter, batch_pos)`·`on_end(env, ctx)` 는 관측 전용.
"""
function at_step(f; at = 1, on_step = nothing, on_end = nothing)
    got = Ref{Any}(nothing); busy = Ref(false)
    CB.HARNESS_HOOK[] = (phase, env, ctx) -> begin
        phase === :sim_end && (on_end === nothing || on_end(env, ctx); return nothing)
        phase === :step || return nothing
        on_step === nothing || on_step(ctx.sim_process_data.iter, ctx.batch_pos)
        (f === nothing || busy[] || ctx.sim_process_data.iter < at) && return nothing
        busy[] = true
        got[] = f(env, ctx); throw(_Stop())
    end
    CB._CACHE_TIMESTAMP_COUNTER[] = 0.0     # 런마다 같은 캐시 논리 시계에서 시작(전역 — 런 경계에서 안 비워진다; 비교 [2] 가 요구)
    try
        CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "t6exec", num_robots = 6,
            assignment_mode = :greedy, n_spare_per_pool = 2, open_animation_at_end = false, save_animation = false,
            write_results = false, rng = Random.MersenneTwister(1), pre_sim_hook = e -> CB.enable_battery!(e))
    catch e
        e isa _Stop || rethrow()
    finally
        CB.HARNESS_HOOK[] = nothing
    end
    return got[]
end

prop(name, code) = Dict{String,Any}("schema_version" => "tool-proposal/1", "checkpoint_id" => "t0",
    "proposal_id" => "p-" * name, "submission_index" => 1, "tool_name" => name, "specification" => Dict{String,Any}(),
    "impl_name" => name, "impl_code" => code, "params" => Dict{String,Any}(),
    "calls" => [Dict{String,Any}("primitive" => name, "args" => Dict{String,Any}())])
contract(env) = rt(TC.derive_task_contract(env, CB; checkpoint_id = "t0"))
enact(env, ctx, p; mode = :full, C = nothing, sp = ctx.sim_params, kw...) =
    TX.enact_proposal!(env, ctx.factory_vis, ctx.anim, sp, ctx.sim_process_data; proposal = p, mode, CB,
                       contract = C, audit = W.audit_snapshot, engine = W.engine_counters, batch_pos = ctx.batch_pos, kw...)
# 판정 쪽처럼 파일 모양(JSON 왕복)으로 읽는다
effects(C, en) = (x = rt(en.record); EV.validate_effects(C, x["before_state"], x["after_body_state"];
                                     audit = x["audit"], trace = rt(en.trace), proposal_id = "p"))
has(vs, p) = any(v -> occursin(p, v), vs)
runs(en) = en.record["postprocess"]["checks_run"]
hlog(en) = vcat(en.record["adapter_log"], en.record["postprocess"]["log"])

include(joinpath(@__DIR__, "fixtures", "repair_verification", "t6_tool_sources.jl"))
const SRC = T6_TOOL_SOURCES
src(k, name) = replace(SRC[k], r"function t6_\w+!" => "function $(name)", count = 1)
# 같은 프로세스에서 같은 이름을 두 번 주조할 수 없다(규약 5 — `Core.eval` 은 안 지워진다). 사례마다 새 이름.
const NAMECT = Ref(0)
"`T6_ONLY=2,7b` 면 그 사례만(변이 측정용). 비면 전부."
want(k) = (f = get(ENV, "T6_ONLY", ""); isempty(f) || k in split(f, ","))
fresh(k) = (NAMECT[] += 1; n = "t6_$(k)_$(NAMECT[])!"; prop(n, src(k, n)))

@testset "T6 tool execution (in-process, colored_8x8)" begin

want("1") && @testset "[1] 공통 봉투: production 은 한 번 씌우고, 검증 집행은 envelope=false 로 body 만" begin
    env = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "t6env", num_robots = 6,
        assignment_mode = :greedy, n_spare_per_pool = 2, open_animation_at_end = false, save_animation = false,
        write_results = false, return_env_before_sim = true, rng = Random.MersenneTwister(1))
    n0 = CB.RESOLVE_CALLS[]
    ev = CB.post_body_envelope!(env; resume = false, touched = false, resolve = false, resolve_skip_why = "x")
    @test (ev.resume, ev.resolve, ev.resolve_detail) == (:not_needed_untouched, :not_needed_surface, "x")
    @test CB.RESOLVE_CALLS[] == n0
    ev = CB.post_body_envelope!(env; resume = true, touched = true, resolve = true)
    @test ev.resume === :issued && ev.resolve in (:resolved, :infeasible, :commit_failed) && CB.RESOLVE_CALLS[] == n0 + 1
    # sched 표면 도구: production 봉투는 재풀이를 **한 번** 부르고, envelope=false 는 한 번도 안 부른다.
    for (envelope, want) in ((true, 1), (false, 0))
        nm = "t6_env_probe_$(envelope)!"
        @test CB.register_minted_primitive!(name = nm, code = "function $(nm)(env)\n    return :noted\nend",
                                            params = Dict{String,Any}(), surface = "sched") === nothing
        k0 = CB.RESOLVE_CALLS[]
        r = CB.enact_minted!(env, nothing, Dict{String,Any}("impl_name" => nm, "body_names" => [nm],
                             "calls" => [Dict("primitive" => nm, "args" => Dict())]); envelope)
        @test r.verdict === :admit && CB.RESOLVE_CALLS[] - k0 == want
        @test envelope ? (r.resolve !== :deferred && r.resume !== :deferred) : (r.resolve === :deferred && r.resume === :deferred)
    end
end

want("2") && @testset "[2] trusted adapter: 도구 안 3 step ≡ production 루프 3 반복(배치 위치·훅·종료 궤적까지)" begin
    AT = 48                                            # 배치 50 의 48 번째 → 도구의 3 step 이 배치 경계를 넘는다
    ref = Dict{String,Any}(); refbp = Dict{Int,Int}()
    at_step(nothing; on_step = (i, b) -> (refbp[i] = b),
            on_end = (env, ctx) -> (ref["f"] = fields(env); ref["iter"] = ctx.sim_process_data.iter;
                                    ref["closed"] = length(env.cache.closed_set)))
    got = Dict{String,Any}(); gotbp = Dict{Int,Int}()
    r = at_step(; at = AT, on_step = (i, b) -> (gotbp[i] = b),
                on_end = (env, ctx) -> (got["f"] = fields(env); got["iter"] = ctx.sim_process_data.iter;
                                        got["closed"] = length(env.cache.closed_set))) do env, ctx
        C = contract(env)
        spd = ctx.sim_process_data
        it0, bp0, s0 = spd.iter, ctx.batch_pos, CB.SIM_STEP[]
        en = enact(env, ctx, fresh("step3"); C)
        it1, s1 = spd.iter, CB.SIM_STEP[]
        CB.continue_simulation!(env, ctx.factory_vis, ctx.anim, ctx.sim_params, spd;
                                first_batch = ctx.sim_params.sim_batch_size - en.adapter.batch_pos + 1, up_steps = en.adapter.up_steps)
        (; en, C, it0, it1, bp0, s0, s1)
    end
    x = r.en.record
    @test x["status"] == "enacted" && x["engine_steps"] == 3
    @test r.it1 - r.it0 == 3 && r.s1 - r.s0 == 3                       # 진행은 같은 절대 예산(iter·SIM_STEP)을 쓴다
    @test r.bp0 == AT && x["batch_pos"] == 1                           # 48 → 49·50 → 배치 끝(monitor_emit!) → 1
    @test [gotbp[i] for i in AT:AT+2] == [refbp[i] for i in AT:AT+2] == [48, 49, 50]   # 훅이 본 배치 위치 = 원본
    @test [e["kind"] for e in r.en.trace] == ["action_start", "pre_step", "post_step", "pre_step", "post_step",
                                              "pre_step", "post_step", "action_end"]
    v = effects(r.C, r.en)
    @test v.report.verdict === :accept && v.report.adapter_calls == [:step_environment!] && v.findings["engine_steps"] == 3
    @test isempty(x["effect_classes"]) && isempty(runs(r.en))          # 진행만 한 도구 — 후처리 대상 효과 없음
    # 필드 audit 은 코드 구간만: engine 반복이 바꾼 캐시는 engine 쪽에만 적히고 도구 탓(fields_changed_by_action)이 아니다
    eng, act = x["audit"]["fields_changed_by_engine"], x["audit"]["fields_changed_by_action"]
    println("[t6 [2]] fields_changed_by_engine=", eng, " fields_changed_by_action=", act)
    @test !isempty(eng) && isempty(intersect(eng, act))
    # 종료 세계가 NOOP(원본 루프만)과 같다 — adapter 반복이 production 반복과 구별되지 않는다(하니스 등록 필드만 다르다).
    @test got["iter"] == ref["iter"] && got["closed"] == ref["closed"]
    diff = [k for k in union(keys(got["f"]), keys(ref["f"])) if get(got["f"], k, nothing) != get(ref["f"], k, nothing)]
    @test sort!(setdiff(diff, EV.HARNESS_FIELDS)) == String[]
end

want("3") && @testset "[3] preflight: 첫 step 요청 직전에 멈춘다(requires_runtime — 거절 아님); t0 위반은 피드백 가능한 거절" begin
    r = at_step(; at = 10) do env, ctx
        C = contract(env); it0 = ctx.sim_process_data.iter
        en = enact(env, ctx, fresh("step3"); mode = :preflight, C)
        (; en, C, it0, it1 = ctx.sim_process_data.iter)
    end
    @test r.en.record["status"] == "requires_runtime" && r.it1 == r.it0 && r.en.record["engine_steps"] == 0
    @test r.en.trace[end]["kind"] == "preflight_stop" && !haskey(r.en.record, "postprocess")
    @test effects(r.C, r.en).report.verdict === :requires_runtime
    # step 앞에서 이미 위반(SoC 위조)이 있으면 preflight 가 그것을 t0 거절로 낸다(미래를 안 보고)
    r = at_step(; at = 10) do env, ctx
        C = contract(env); (; en = enact(env, ctx, fresh("soc_forge_then_step"); mode = :preflight, C), C)
    end
    v = effects(r.C, r.en)
    @test r.en.record["status"] == "requires_runtime" && v.report.verdict === :reject && has(v.report.reasons, "battery_soc")
    # full 모드에서는 같은 위반이 step 앞 검사에서 멈추고 worker 를 버린다(:partial) — 위반 세계를 한 스텝도 안 굴린다
    r = at_step(; at = 10) do env, ctx
        C = contract(env); it0 = ctx.sim_process_data.iter
        (; en = enact(env, ctx, fresh("soc_forge_then_step"); C), it0, it1 = ctx.sim_process_data.iter)
    end
    @test r.en.record["status"] == "partial" && has([r.en.record["exception"]], "pre_step_violation") && r.it1 == r.it0
end

want("4") && @testset "[4] episode 예산이 도구 안에서 끝나면 더 진행하지 않는다(시계/예산 직접 변경 없음)" begin
    r = at_step(; at = 51) do env, ctx                     # iter 51 = 배치 경계 직후(batch_pos 1; 첫 배치는 iter 1..50)
        spd = ctx.sim_process_data
        sp = CB.SimParameters(ctx.sim_params.sim_batch_size, spd.iter,
                              (getfield(ctx.sim_params, i) for i in 3:fieldcount(CB.SimParameters))...)
        it0 = spd.iter
        (; en = enact(env, ctx, fresh("step3"); sp), it0, it1 = spd.iter, bp = ctx.batch_pos)
    end
    @test r.bp == 1 && r.it1 == r.it0 && r.en.record["engine_steps"] == 0
    @test r.en.record["status"] == "enacted" && has(r.en.record["postprocess"]["notes"], "episode budget ended inside the tool")
end

want("5") && @testset "[5] 시계 직접 변경은 거절, adapter 우회 진행은 미관측(폐기)" begin
    r = at_step(; at = 10) do env, ctx
        C = contract(env); (; en = enact(env, ctx, fresh("clock"); C), C)
    end
    v = effects(r.C, r.en)
    @test v.report.verdict === :reject && has(v.report.reasons, "clock_manipulation")
    r = at_step(; at = 10) do env, ctx
        (; en = enact(env, ctx, fresh("bypass")), it0 = ctx.sim_process_data.iter)
    end
    @test r.en.record["status"] == "unobservable" && has(r.en.record["unobservable"], "unmediated_engine_advance:rvo_doSteps")
end

want("6") && @testset "[6] 비기하(자원): resync·기하 검사를 **실행하지 않는다**" begin
    r = at_step(; at = 10) do env, ctx
        C = contract(env); (; en = enact(env, ctx, fresh("swap"); C), C)
    end
    x = r.en.record
    @test x["status"] == "enacted" && x["effect_classes"] == ["resource"]
    @test runs(r.en) == String[]                                         # 자원은 T5 규칙(검증기)만 — worker 후처리 0
    @test x["postprocess"]["validator_adapters"] == ["resource_conservation"]
    @test !any(l -> l["action"] == "resync_scene_to_schedule!", hlog(r.en)) && isempty(hlog(r.en))
    @test x["harness_changes"] == String[] && "resources(2)" in x["body_changes"]
    @test effects(r.C, r.en).report.verdict === :accept
end

want("7") && @testset "[7] 비기하(배정): 가용성·재개·재풀이는 돌고 resync 는 안 돈다; 하니스 변경은 따로 기록" begin
    r = at_step(; at = 10) do env, ctx
        C = contract(env); (; en = enact(env, ctx, fresh("replace"); C), C)
    end
    x = r.en.record
    @test x["status"] == "enacted" && "assignment" in x["effect_classes"] && !("geometry" in x["effect_classes"])
    @test issubset(["assignment_availability", "assignment_completeness", "cache_resume"], runs(r.en))
    @test !("scene_resync" in runs(r.en)) && !("geometry_residual" in runs(r.en))
    # 인계가 팀을 채운 채 끝났으므로 재풀이는 필요 없다 — 하니스가 부르지 않고 그 사유를 남긴다
    @test !("assignment_resolve" in runs(r.en)) && has(x["postprocess"]["notes"], "assignment_resolve_not_needed")
    env_log = [l for l in hlog(r.en) if l["action"] == "post_body_envelope!"]
    @test length(env_log) == 1 && env_log[1]["by"] == "harness" && env_log[1]["resume"] == "issued" &&
          env_log[1]["resolve"] == "not_needed_surface"
    @test !any(l -> l["action"] == "resync_scene_to_schedule!", hlog(r.en))
    @test effects(r.C, r.en).report.verdict === :accept
end

want("7b") && @testset "[7b] 배정 해제로 팀이 모자라지면 하니스가 공통 재풀이를 **한 번** 보충하고 결과를 따로 기록한다" begin
    r = at_step(; at = 10) do env, ctx
        C = contract(env); n0 = CB.RESOLVE_CALLS[]
        en = enact(env, ctx, fresh("release"); C)
        (; en, C, calls = CB.RESOLVE_CALLS[] - n0)
    end
    x = r.en.record
    @test x["status"] == "enacted" && "assignment" in x["effect_classes"]
    @test issubset(["assignment_completeness", "assignment_resolve", "cache_resume"], runs(r.en)) && r.calls == 1
    env_log = [l for l in hlog(r.en) if l["action"] == "post_body_envelope!"]
    @test length(env_log) == 1 && env_log[1]["resolve"] == "resolved"
    @test any(c -> startswith(c, "edges"), x["body_changes"])            # body 가 뗐고
    @test any(c -> startswith(c, "edges"), x["harness_changes"])         # 하니스가 다시 붙였다 — 따로 기록
    @test effects(r.C, r.en).report.verdict === :accept
end

want("8") && @testset "[8] 기하 — body 가 resync 를 잊었다: 하니스가 필요한 만큼 보충하고 잔차 0, 로봇 불변, 하니스 변경으로 기록" begin
    r = at_step(; at = 2) do env, ctx
        C = contract(env)
        en = enact(env, ctx, fresh("shift"); C)
        (; en, C, drift = CB.scene_drift(env))
    end
    x = r.en.record
    @test x["status"] == "enacted" && "geometry" in x["effect_classes"]
    @test issubset(["scene_resync", "geometry_residual", "cache_resume"], runs(r.en))
    rs = [l for l in hlog(r.en) if l["action"] == "resync_scene_to_schedule!"]
    @test length(rs) == 1 && rs[1]["by"] == "harness" && rs[1]["when"] == "after_body" && !isempty(rs[1]["snapped"])
    @test any(c -> startswith(c, "scene("), x["harness_changes"])        # 씬을 옮긴 것은 하니스다(body 변경과 분리)
    @test !any(c -> startswith(c, "scene("), x["body_changes"]) && any(c -> startswith(c, "poses("), x["body_changes"])
    @test all(d -> !d.would_snap, r.drift) && isempty(x["postprocess"]["failures"])
    @test x["post_state"]["robots"] == x["after_body_state"]["robots"]
    @test effects(r.C, r.en).report.verdict === :accept
end

want("8b") && @testset "[8b] 기하 — 운행 중 운반 유닛째 snap 이 로봇을 옮기면 하니스는 그 보충을 성공으로 쓰지 않는다(폐기)" begin
    # iter 95 = 첫 화물이 들려 있는 시점(test/repair_resync.jl [3] 실측). 큰 이동이면 형성된 운반 유닛이 snap 대상이 된다.
    r = at_step(; at = 95) do env, ctx
        n = "t6_shift_far_$(NAMECT[] += 1)!"
        p = prop(n, src("shift", n))
        p["params"] = Dict{String,Any}("dx" => Dict("type" => "number"), "dy" => Dict("type" => "number"))
        p["calls"][1]["args"] = Dict{String,Any}("dx" => 1.5, "dy" => 1.0)
        C = contract(env); (; en = enact(env, ctx, p; C), C)
    end
    x = r.en.record
    @test x["status"] == "partial" && has([x["exception"]], "postprocess_robot_moved")
    @test has([x["exception"]], "via snapped transport unit")                  # 원인(운반 유닛 snap)까지 사유에 실린다
    @test any(l -> l["action"] == "resync_scene_to_schedule!", hlog(r.en))     # 하니스가 보충을 시도했고
    @test x["post_state"]["robots"] != x["after_body_state"]["robots"]         # 실제로 로봇이 옮겨졌다(항진 아님) → 폐기
end

want("9") && @testset "[9] 기하 — body 가 스스로 resync: 정합성은 검사하되 보충하지 않는다" begin
    r = at_step(; at = 2) do env, ctx
        n = "t6_shift_self_$(NAMECT[] += 1)!"
        code = replace(src("shift", n), "    return :shifted" => "    resync_scene_to_schedule!(env)\n    return :shifted")
        (; en = enact(env, ctx, prop(n, code)))
    end
    @test r.en.record["status"] == "enacted" && "scene_resync" in runs(r.en) && "geometry_residual" in runs(r.en)
    @test !any(l -> l["action"] == "resync_scene_to_schedule!", hlog(r.en))
    @test has(r.en.record["postprocess"]["notes"], "scene_resync_not_needed")
    @test any(c -> startswith(c, "scene("), r.en.record["body_changes"])
end

want("10") && @testset "[10] 혼합(기하 + 배정 + 자원): 관련 검사를 모두 수행" begin
    r = at_step(; at = 2) do env, ctx
        C = contract(env); (; en = enact(env, ctx, fresh("mixed"); C), C)
    end
    x = r.en.record
    @test x["status"] == "enacted" && issubset(["geometry", "assignment", "resource"], x["effect_classes"])
    @test issubset(["scene_resync", "geometry_residual", "cache_resume",
                    "assignment_completeness", "assignment_availability"], runs(r.en))
    @test issubset(["resource_conservation", "team_slot", "transform_attachment"], x["postprocess"]["validator_adapters"])
    @test effects(r.C, r.en).report.verdict === :accept
end

want("11") && @testset "[11] 검사 adapter 가 없는 효과는 unsupported 로 드러난다" begin
    ad = Dict(k => v for (k, v) in TX.CHECK_ADAPTERS if k !== :resource)
    r = at_step(; at = 10) do env, ctx
        (; en = enact(env, ctx, fresh("swap"); adapters = ad))
    end
    @test r.en.record["status"] == "enacted" && r.en.record["postprocess"]["unsupported"] == ["missing_check_adapter:resource"]
end

want("12") && @testset "[12] 폐기: 첫 변경 뒤 throw · 변경 전 throw · 일부 API 성공 후 실패 · 후처리 실패 · 등록 거절" begin
    r = at_step(; at = 10) do env, ctx; (; en = enact(env, ctx, fresh("throw_after"))); end
    @test r.en.record["status"] == "partial" && has([r.en.record["exception"]], "boom after") && !haskey(r.en.record, "postprocess")
    r = at_step(; at = 10) do env, ctx; (; en = enact(env, ctx, fresh("throw_before"))); end
    @test r.en.record["status"] == "threw" && has([r.en.record["exception"]], "boom before")
    r = at_step(; at = 10) do env, ctx; (; en = enact(env, ctx, fresh("api_then_fail"))); end
    @test r.en.record["status"] == "partial" && !haskey(r.en.record, "postprocess")
    @test any(c -> startswith(c, "edges") || startswith(c, "resources"), r.en.record["body_changes"])  # API 가 실제로 바꿨다
    # 후처리 실패(주입): 하니스가 이미 세계를 바꾼 뒤 실패해도 폐기(되돌리지 않는다 — worker 를 버린다)
    r = at_step(; at = 2) do env, ctx; (; en = enact(env, ctx, fresh("shift"); fail_probe = true)); end
    @test r.en.record["status"] == "partial" && has([r.en.record["exception"]], "postprocess_failed")
    @test any(l -> l["action"] == "resync_scene_to_schedule!", hlog(r.en))  # 실패 전 하니스가 씬을 이미 옮겼다
    # 등록 규약 거절: body 를 굴리지 않는다
    r = at_step(; at = 10) do env, ctx
        (; en = enact(env, ctx, prop("t6_two_defs!", "function t6_two_defs!(env)\n    1\nend\nfunction t6_other!(env)\n    2\nend")))
    end
    @test r.en.record["status"] == "registration_rejected" && isempty(r.en.trace)
end

want("13") && @testset "[13] judge_candidate: 계약을 어긴 COMPLETE 는 선택 불가(T4 validator 는 계약을 안 본다)" begin
    dir = mktempdir(); par = joinpath(dir, "parent"); br = joinpath(dir, "b1"); mkpath(par); mkpath(br)
    p13 = fresh("swap")
    r = at_step(; at = 10) do env, ctx
        C = contract(env)
        en = enact(env, ctx, p13; C)
        CB.continue_simulation!(env, ctx.factory_vis, ctx.anim, ctx.sim_params, ctx.sim_process_data;
                                first_batch = ctx.sim_params.sim_batch_size - en.adapter.batch_pos + 1)
        (; en, C, term = rt(TC.task_state(env, CB)), complete = CB.project_complete(env))
    end
    @test r.complete
    open(io -> JSON3.write(io, r.C), joinpath(par, "task_contract.json"), "w")
    open(io -> JSON3.write(io, Dict("checkpoint_id" => "t0", "task_contract" => Dict("sha256" =>
         bytes2hex(sha256(read(joinpath(par, "task_contract.json"))))))), joinpath(par, "contract.json"), "w")
    TX.write_enactment(br, r.en)
    open(io -> JSON3.write(io, p13), br * ".proposal.json", "w")          # supervisor 가 쓴 제안 파일(T7 교차검사 대상)
    rollout(t) = (open(io -> JSON3.write(io, Dict("branch" => Dict("task_state" => t))), joinpath(br, "terminal.json"), "w");
                  (report = R.RolloutReport("p", "t0", :COMPLETE, nothing, :project_complete, 100, 1.0, 1.0, 0, Dict{String,Int}()),
                   violations = String[], supervisor = (wall_s = 1.0, cpu_s = 1.0, timed_out = false)))
    j = TX.judge_candidate(par, br; rollout = rollout(r.term))
    @test j.eligible && j.precommit_ok && j.enactment.status === :enacted && j.contract_terminal.verdict === :accept && !j.feedback_allowed
    # terminal 에서 선행 검사는 공허하다 — 관측 경계로 남는다(T7)
    @test any(u -> startswith(u, "terminal_precedence_vacuous") || startswith(u, "precedence_vacuous"), j.unobserved)
    # 교차검사(T7): 제출한 제안과 다른 파일 · post_state digest 위조 → 선택 불가
    open(io -> JSON3.write(io, merge(p13, Dict("impl_code" => replace(p13["impl_code"], "verbose = false" => "verbose = false ")))), br * ".proposal.json", "w")
    j = TX.judge_candidate(par, br; rollout = rollout(r.term))
    @test !j.eligible && !j.precommit_ok && has(j.reasons, "cross_check: proposal_sha256")
    open(io -> JSON3.write(io, p13), br * ".proposal.json", "w")
    X = rt(r.en.record); X["post_state"]["closed"] = Any[]
    open(io -> JSON3.write(io, X), joinpath(br, "enactment.json"), "w")
    j = TX.judge_candidate(par, br; rollout = rollout(r.term))
    @test !j.eligible && has(j.reasons, "cross_check: post_state_sha256")
    TX.write_enactment(br, r.en)
    bad = deepcopy(r.term)
    pc = [id for (id, t) in bad["nodes"] if t == "ProjectComplete"]
    filter!(id -> !(id in pc), bad["closed"])
    j = TX.judge_candidate(par, br; rollout = rollout(bad))
    @test !j.eligible && j.rollout.outcome === :COMPLETE && has(j.reasons, "terminal contract: required_tasks_not_closed")
    # 운반 닻 검사를 건너뛴 사슬은 숨기지 않고 unobserved 로 센다
    C2 = deepcopy(r.C); isempty(C2["transport_chains"]) || (C2["transport_chains"][1]["source"] = nothing)
    @test isempty(C2["transport_chains"]) || has(TX.anchor_unobserved(C2), "transport_anchor_unchecked: 1/")
    @test TX.anchor_unobserved(r.C) == String[] || has(TX.anchor_unobserved(r.C), "transport_anchor_unchecked")
end

want("14") && @testset "[14] 감사 @ref 는 객체 신원 — 정점 제거(색인 재번호)는 정책·씬 트리 변경이 아니다; 제어기 상태 사유는 따로 (T10b 리뷰)" begin
    r = at_step(; at = 40) do env, ctx
        # 같은 편집을 옛 방식(첫 방문 경로 @ref)으로 먼저 재 본다 — 회귀의 증거(오인이 실제로 났었다)
        pd(e) = (w = E.world_lines(e; modules = ER.MODULES(), refs = :path); E.field_digests(w.lines, w.fields))
        C = contract(env)
        p0 = pd(env)
        en = enact(env, ctx, fresh("prune_vertex"); C)
        p1 = pd(env)
        (; en, C, path_changed = sort!([k for k in keys(p0) if get(p1, k, nothing) != p0[k]]))
    end
    a = r.en.record["audit"]["fields_changed_by_action"]
    @test "env.agent_policies" in r.path_changed && "env.scene_tree" in r.path_changed      # 옛 감사라면 오인했을 것
    @test "env.sched" in a && !("env.agent_policies" in a) && !("env.scene_tree" in a)        # 신원 감사는 오인하지 않는다
    v = effects(r.C, r.en).report
    @test !any(x -> occursin("agent_policies", x), v.reasons) && has(v.reasons, "required_task_deleted")
    # 대조 1: 진짜 정책 변경(파라미터)은 여전히 잡히고 generic 파생 계획 사유다
    r2 = at_step(; at = 40) do env, ctx
        C = contract(env); (; en = enact(env, ctx, fresh("policy_param"); C), C)
    end
    @test "env.agent_policies" in r2.en.record["audit"]["fields_changed_by_action"]
    dp = r2.en.record["audit"]["derived_paths_changed_by_action"]["env.agent_policies"]
    @test length(dp) == 1 && endswith(dp[1], ".dispersion_policy.vmax")
    v2 = effects(r2.C, r2.en).report
    @test v2.verdict === :unsupported && has(v2.reasons, "unverifiable:derived_plan_changed_by_code:env.agent_policies")
    # 대조 2: 인터페이스 `get_cmd` 조회는 제어기 런타임 상태를 쓴다 → 판정은 같은 unsupported, 사유는 제어기 상태
    r3 = at_step(; at = 40) do env, ctx
        C = contract(env); (; en = enact(env, ctx, fresh("get_cmd"); C), C)
    end
    dp3 = get(r3.en.record["audit"]["derived_paths_changed_by_action"], "env.agent_policies", String[])
    @test !isempty(dp3) && all(EV.controller_state_path, dp3)
    v3 = effects(r3.C, r3.en).report
    @test v3.verdict === :unsupported && has(v3.reasons, "unsupported_effect:controller_state_mutated_by_code:env.agent_policies")
    @test !has(v3.reasons, "derived_plan_changed_by_code")
    # 경로 규칙 자체: 제어기 칸만 참, 파라미터·키·정책 추가는 거짓
    @test EV.controller_state_path("env.agent_policies{3}.nominal_policy.config.translation[1]")
    @test EV.controller_state_path("env.agent_policies{3}.dispersion_policy.node")
    @test !EV.controller_state_path("env.agent_policies{3}.dispersion_policy.vmax")
    @test !EV.controller_state_path("env.agent_policies{3}.key") && !EV.controller_state_path("env.agent_policies")
end

end
