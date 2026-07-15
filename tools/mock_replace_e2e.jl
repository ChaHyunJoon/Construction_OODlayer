# =============================================================================
# mock_replace_e2e.jl -- LLM-FREE end-to-end test of the FULL respec seam for OOD 1-1
# ReplaceAgent (robot breakdown -> spare hand-off). Stands up a local mock /propose
# that returns a ReplaceAgent grounded from the request's own `agents` context
# (mimicking the LLM classifier), enables the RESPEC seam, injects a physical robot
# fault via schedule_ood! (fault_robot! returns the NL), and runs the real sim loop
# (ood_inject_step! -> step -> respec_step!). This drives the production path:
#   NL -> push_ood! -> maybe_respecify! -> llm_to_proposal(HTTP mock) -> _parse_proposal
#   -> ReplaceAgent -> verify_replace -> nearest_pool/pop_spare -> replace_robot!.
#
# SCOPE: this asserts the full enabled-loop WIRING fires correctly (respec admitted,
# spare hand-off enacted, progress monotone). Full build COMPLETION is gated on the
# known R1 frontier-graft stall (see docs/simulator_ood_1-1_robot_breakdown_design,
# progress log 2026-06-26(c)) and is NOT asserted here.
#
# Run:  julia +lts --project=. tools/mock_replace_e2e.jl
# =============================================================================
const MOCK_PORT = 8733
ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:$MOCK_PORT"   # MUST be set before `using` (const reads ENV at load)

using ConstructionBots
import HTTP, JSON3, Graphs, Logging, HiGHS, LinearAlgebra
const CB = ConstructionBots
const norm = LinearAlgebra.norm

const OOD_STEP = parse(Int, get(ENV, "OOD_STEP", "3"))   # by step ~3 the frontier has opened (closed-count jumps early)
const NSPARE   = parse(Int, get(ENV, "NSPARE", "2"))
const FAULT_AT = parse(Int, get(ENV, "FAULT_AT", "24"))

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 300.0, "presolve" => "on",
    "mip_rel_gap" => 5.0, CB.MOI.Silent() => true)

# ---- mock /propose: deterministic, grounds ReplaceAgent from request `agents` --------
function start_mock(port)
    handler = function (req::HTTP.Request)
        path = HTTP.URIs.URI(req.target).path
        if path == "/health"
            return HTTP.Response(200, JSON3.write(Dict("status" => "ok")))
        elseif path == "/propose"
            body   = JSON3.read(String(req.body))
            event  = haskey(body, "event") ? String(body["event"]) : ""
            agents = haskey(body, "agents") ? body["agents"] : []
            # ground the faulted robot: parse "Robot R<id>" from the NL, else first agent.
            m = match(r"R(\d+)", event)
            aid = ""
            if m !== nothing
                want = "($(m.captures[1]))"
                for a in agents
                    occursin(want, String(a["id"])) && (aid = String(a["id"]); break)
                end
            end
            aid == "" && !isempty(agents) && (aid = String(agents[1]["id"]))
            resp = Dict("constraints" => [Dict("kind" => "ReplaceAgent", "agent" => aid, "after" => 0.0)],
                        "rationale" => "mock: robot breakdown -> replace with nearest spare")
            return HTTP.Response(200, JSON3.write(resp))
        end
        return HTTP.Response(404, "not found")
    end
    return HTTP.serve!(handler, "127.0.0.1", port)
end

function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))
    return res[]
end

# OOD action: fault an active robot once the build is underway, emit the NL. Fired
# once by the one-shot scheduler at OOD_STEP (by which point the frontier has opened).
function ood_action!(env)
    nl = CB.fault_robot!(env)
    nl === nothing && return nothing
    @info "[E2E-1-1] OOD action @closed=$(length(env.cache.closed_set)): faulted a robot; emitting NL"
    return nl
end

println(">>> building nav-ON env (tractor) WITH $(4*NSPARE) spares...")
pp = CB.get_project_params(4)
CB.clear_spare_pools!(); CB.clear_faulted_robots!(); CB.clear_restriction_zones!(); CB.clear_ood_schedule!()
const ENV0 = run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Error,
        rvo_flag=true, tangent_bug_flag=true, dispersion_flag=true, n_spare_per_pool=NSPARE,
        open_animation_at_end=false, save_animation=false, write_results=false,
        overwrite_results=false, look_for_previous_milp_solution=false,
        save_milp_solution=false, return_env_before_sim=true)
end
println(">>> env: $(Graphs.nv(ENV0.sched)) nodes; spares=$(length(CB.active_spares()))")

const SRV = start_mock(MOCK_PORT)
CB.RESPEC_ENABLED[] = true
CB.schedule_ood!(OOD_STEP, ood_action!)   # one-shot fault injection once the frontier has opened
println(">>> mock /propose up; ready=$(CB.respec_service_ready()); RESPEC_ENABLED=$(CB.RESPEC_ENABLED[])")
Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Info))

npass = Ref(0); nfail = Ref(0)
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))

# seam loop: ood_inject_step! -> step -> respec_step!; capture the respec verdict.
function run_seam_loop(env; cap=120_000, stall_limit=8000)
    prev = length(env.cache.closed_set); stall = 0
    respec_status = Ref{Symbol}(:none); n0 = prev; peak = prev
    for it in 1:cap
        CB.ood_inject_step!(env, it)
        CB.step_environment!(env)
        st = CB.respec_step!(env)
        if st in (:admitted, :fallback, :rejected)
            respec_status[] = st; @info "[E2E-1-1] respec_step! @it=$it -> $st"
        end
        try CB.update_planning_cache!(env, 0.0) catch e
            return (status=:asserted, closed=length(env.cache.closed_set), iters=it, respec=respec_status[], peak=peak)
        end
        c = length(env.cache.closed_set); peak = max(peak, c)
        stall = c > prev ? 0 : stall + 1; prev = c
        CB.project_complete(env) && return (status=:complete, closed=c, iters=it, respec=respec_status[], peak=peak)
        stall >= stall_limit && return (status=:stalled, closed=c, iters=it, respec=respec_status[], peak=peak)
    end
    return (status=:capped, closed=prev, iters=cap, respec=respec_status[], peak=peak)
end

env = deepcopy(ENV0)
total = Graphs.nv(env.sched); n0 = length(env.cache.closed_set)
r = run_seam_loop(env)
try close(SRV) catch end

println("\n==== RESULT (mock e2e ReplaceAgent seam) ====")
println("closed $n0 -> $(r.closed) (peak $(r.peak))/$total  status=$(r.status)  respec_verdict=$(r.respec)")
# Assert the WIRING (not full completion, which is gated on the R1 stall):
check("respec seam fired with :admitted (NL->ReplaceAgent->dispatch->replace_robot!)", r.respec == :admitted)
check("no RVO/identity assert (faulted robot didn't crash the sim)", r.status != :asserted)
check("hand-off made progress past the fault point", r.peak > FAULT_AT)
check("a spare was consumed from a pool", length(CB.active_spares()) == 4*NSPARE - 1)

CB.RESPEC_ENABLED[] = false; CB.clear_ood_schedule!(); CB.clear_restriction_zones!()
CB.clear_spare_pools!(); CB.clear_faulted_robots!()
println("\n==== mock e2e ReplaceAgent: $(npass[]) passed, $(nfail[]) failed ====")
println(nfail[] == 0 ?
    "SEAM GREEN (NL -> mock LLM -> ReplaceAgent -> verify_replace -> spare hand-off enacted). " *
    "Full completion gated on the known R1 frontier-graft stall." :
    "SOME FAILED")
nfail[] == 0 || error("mock_replace_e2e had $(nfail[]) failure(s)")
