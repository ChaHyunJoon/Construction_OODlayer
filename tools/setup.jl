# =============================================================================
# tools/setup.jl -- consolidated environment bootstrap (was setup_instantiate.jl,
# setup_pycall.jl, setup_110.jl). Each former script is a function in module Setup
# with a CLI/ENV dispatcher.
#
# Setup keys:
#   instantiate  -- Pkg.instantiate() only
#   pycall       -- point PyCall at the conda python and Pkg.build("PyCall")
#   all          -- julia-1.10 full bootstrap: instantiate + build PyCall (was setup_110)
#
# Run:
#   julia +lts --project=. tools/setup.jl <key>        (or  ENV SETUP=<key>)
# e.g.
#   julia +lts --project=. tools/setup.jl all
#
# The PyCall python path defaults to the conda env below; override with
# ENV["CB_PYTHON"] (or CB_PYTHON=... in the shell) if your python lives elsewhere.
# =============================================================================
module Setup
using Pkg

# machine-specific python for PyCall/rvo2; overridable via ENV["CB_PYTHON"].
_python() = get(ENV, "CB_PYTHON", raw"C:\Users\chahj\anaconda3\envs\lego_rvo2\python.exe")

# instantiate -- resolve + install the project's dependencies.
function setup_instantiate()
    Pkg.instantiate()
    println("INSTANTIATE_DONE")
end

# pycall -- point PyCall at the conda python, then (re)build it so rvo2 imports.
function setup_pycall()
    ENV["PYTHON"] = _python()
    Pkg.build("PyCall")
    println("PYCALL_BUILD_DONE")
end

# all -- julia 1.10 full bootstrap: instantiate + build PyCall (was setup_110.jl).
function setup_all()
    ENV["PYTHON"] = _python()
    println("Julia version: ", VERSION)
    Pkg.instantiate()
    Pkg.build("PyCall")
    println("SETUP_110_DONE")
end

# ---- dispatcher -------------------------------------------------------------
const SETUPS = Dict(
    "instantiate" => setup_instantiate,
    "pycall"      => setup_pycall,
    "all"         => setup_all,
)
end # module Setup

if abspath(PROGRAM_FILE) == @__FILE__
    key = get(ENV, "SETUP", isempty(ARGS) ? "all" : ARGS[1])
    haskey(Setup.SETUPS, key) || error("unknown setup '$key'. Available: $(join(sort(collect(keys(Setup.SETUPS))), ", "))")
    println(">>> running setup: $key")
    Setup.SETUPS[key]()
end
