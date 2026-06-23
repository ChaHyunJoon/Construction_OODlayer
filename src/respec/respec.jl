# =============================================================================
# respec.jl  --  Aggregator for the verified LLM re-specification layer.
# Include this ONCE from ConstructionBots.jl (see PATCHES.md, patch 3).
#
# Pipeline:  OOD event --(llm_bridge)--> typed DSL proposal
#                       --(verifier)----> Admit / Reject  (Reject -> fallback)
#                       --(compiler)----> @constraints injected into the MILP
#                       --(replan)------> re-solve from frozen state, resume
#
# Hard dependencies to add to Project.toml: HTTP, JSON3.
# =============================================================================

# include paths are relative to THIS file (already inside src/respec/).
include("spec_dsl.jl")
include("compiler.jl")
include("verifier.jl")
include("llm_bridge.jl")
include("replan.jl")
include("reassign.jl")
