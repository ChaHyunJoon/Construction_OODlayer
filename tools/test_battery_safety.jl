# tools/test_battery_safety.jl
# OFFLINE safety/verifiability test for the TIER-2 soft re-spec (DeprioritizeAgent) and the
# AGENT_COST_BIAS objective-bias registry. NO env build, NO LLM. Running it also PRECOMPILES the
# whole module, so it doubles as an integration check that the spec_dsl/compiler/verifier/replan
# + essential_tg_coponents edits all load.
# Run:  julia +lts --project=. tools/test_battery_safety.jl
using ConstructionBots
const CB = ConstructionBots

const PASS = Ref(0); const FAILN = Ref(0)
macro check(ex)
    quote
        if $(esc(ex)); PASS[] += 1
        else; FAILN[] += 1; println("  FAIL: ", $(string(ex))); end
    end
end

println("== closed-union: DeprioritizeAgent is a ConstraintSpec (LLM can only emit grammar) ==")
@check CB.DeprioritizeAgent <: CB.ConstraintSpec
r5 = CB.RobotID(5); r6 = CB.RobotID(6)
da = CB.DeprioritizeAgent(r5)
@check da.factor == 50.0                                  # default advisory severity
@check CB.referenced_ids(da) == (r5,)                     # grounding key for the closed-node check

println("== SAFETY: factor is CLAMPED to [1, MAX] (LLM cannot weaponize the knob) ==")
CB.clear_agent_bias!()
@check CB.agent_cost_bias(r5) == 1.0                      # unknown agent -> identity
@check CB.deprioritize_agent!(r5, 50.0) == 50.0          # in-range passes through
@check CB.agent_cost_bias(r5) == 50.0
@check CB.deprioritize_agent!(r5, 0.3) == 1.0            # < 1 clamped UP: can never INCENTIVIZE a robot
@check CB.deprioritize_agent!(r5, -100.0) == 1.0         # negative clamped: cannot invert the objective
@check CB.deprioritize_agent!(r5, 1.0e9) == CB.MAX_AGENT_COST_BIAS   # blowup clamped: numerical safety
@check CB.MAX_AGENT_COST_BIAS == 1.0e3
CB.clear_agent_bias!(r5)
@check CB.agent_cost_bias(r5) == 1.0                      # single-clear works
CB.deprioritize_agent!(r5, 10.0); CB.deprioritize_agent!(r6, 20.0)
@check length(CB.AGENT_COST_BIAS[]) == 2
CB.clear_agent_bias!()
@check isempty(CB.AGENT_COST_BIAS[])                      # global clear works

println("== SAFETY: feasibility-preserving BY CONSTRUCTION — compiles to ZERO hard constraints ==")
# The structural proof that a soft re-spec cannot shrink the feasible set / stall the build:
@check CB.compile_constraint!(nothing, nothing, nothing, nothing, nothing, da) == 0

println("== objective-bias composition: agent_bias × battery_fn, both default-identity ==")
CB.clear_agent_bias!(); CB.EDGE_COST_MULTIPLIER[] = nothing
@check CB.edge_cost_multiplier(nothing, 1) == 1.0        # both off -> edge_costs byte-for-byte unchanged
CB.EDGE_COST_MULTIPLIER[] = (s, v) -> 3.0                # stub battery fn
@check CB.edge_cost_multiplier(nothing, 1) == 3.0        # agent registry empty -> battery only
CB.EDGE_COST_MULTIPLIER[] = nothing                      # reset

println("== dispatch predicate: pure-soft proposals routed to the soft path ==")
@check CB._is_deprioritize(CB.RespecProposal([CB.DeprioritizeAgent(r5)]))
@check CB._is_deprioritize(CB.RespecProposal([CB.DeprioritizeAgent(r5), CB.DeprioritizeAgent(r6)]))
mixed = CB.RespecProposal(CB.ConstraintSpec[CB.DeprioritizeAgent(r5), CB.ForbidWindow(r5, 0.0, 1.0)])
@check !CB._is_deprioritize(mixed)                       # mixed -> NOT soft path (hard spec governs)
@check !CB._is_deprioritize(CB.RespecProposal(CB.ConstraintSpec[]))   # empty -> not soft
# a mixed proposal's DeprioritizeAgent is harmless on the generic compile path (no-op):
@check CB.compile_constraint!(nothing, nothing, nothing, nothing, nothing, mixed.constraints[1]) == 0

println("== LLM->Julia decode: _parse_proposal maps DeprioritizeAgent JSON -> typed spec ==")
resolver = s -> CB.RobotID(7)                            # trivial id resolver for the test
payload = Dict("constraints" => [Dict("kind" => "DeprioritizeAgent", "agent" => "RobotID(7)", "factor" => 80.0)],
               "rationale" => "battery low")
prop = CB._parse_proposal(payload, "R7 battery low"; id_resolver = resolver)
@check length(prop.constraints) == 1
@check prop.constraints[1] isa CB.DeprioritizeAgent
@check prop.constraints[1].agent == CB.RobotID(7)
@check prop.constraints[1].factor == 80.0
payload2 = Dict("constraints" => [Dict("kind" => "DeprioritizeAgent", "agent" => "RobotID(7)")], "rationale" => "")
@check CB._parse_proposal(payload2, "x"; id_resolver = resolver).constraints[1].factor == 50.0   # default
threw = Ref(false)
try CB._parse_proposal(Dict("constraints" => [Dict("kind" => "Sabotage")], "rationale" => ""), "x"; id_resolver = resolver)
catch; threw[] = true end
@check threw[]                                           # closed union: unknown kind throws on Julia side too

println("\n== RESULT: $(PASS[]) passed, $(FAILN[]) failed ==")
exit(FAILN[] == 0 ? 0 : 1)
