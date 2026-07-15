# =============================================================================
# spare_pool_check.jl -- LLM-free, env-free unit check of OOD 1-1 Part A1:
# the directional spare-pool storage + geometry helpers (ood_injection.jl).
# No nav build, no MILP, no Python service -- pure storage/geometry assertions.
# Run: julia +lts --project=. tools/spare_pool_check.jl
# =============================================================================
using ConstructionBots
import LinearAlgebra
const CB = ConstructionBots
const norm = LinearAlgebra.norm

npass = Ref(0); nfail = Ref(0)
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))

println(">>> A1 spare-pool storage + geometry (env-free)")

CB.clear_spare_pools!()

# --- pool_centers: 4 cardinal centers placed `margin` outside a unit bbox -------
# bbox = (xmin,xmax,ymin,ymax) = (-1,1,-1,1); margin=2 -> centers at distance 2 outside.
centers = CB.pool_centers((-1.0, 1.0, -1.0, 1.0); margin = 2.0)
check("pool_centers has 4 cardinal keys",
    Set(keys(centers)) == Set([:north, :south, :east, :west]))
check("north center is +y outside bbox", centers[:north] == [0.0, 3.0])
check("south center is -y outside bbox", centers[:south] == [0.0, -3.0])
check("east center is +x outside bbox",  centers[:east]  == [3.0, 0.0])
check("west center is -x outside bbox",  centers[:west]  == [-3.0, 0.0])

# --- register_spare! / pop_spare! / active_spares round-trip --------------------
# Fabricate spare RobotIDs (env-free) via the global id counter.
rids = Dict(k => [CB.get_unique_id(CB.RobotID) for _ in 1:3] for k in keys(centers))
for (k, v) in rids, rid in v
    CB.register_spare!(k, rid)
end
# Record the centers too so nearest_pool can score them.
for (k, c) in centers
    CB.SPARE_POOL_CENTERS[][k] = Vector{Float64}(c)
end
check("active_spares counts all registered (4 pools x 3)", length(CB.active_spares()) == 12)
check("each pool holds 3 spares",
    all(length(CB.spare_pools()[k]) == 3 for k in keys(centers)))

popped = CB.pop_spare!(:north)
check("pop_spare! returns a registered north id", popped in rids[:north])
check("pop_spare! shrinks the north pool to 2", length(CB.spare_pools()[:north]) == 2)
check("active_spares now 11 after one pop", length(CB.active_spares()) == 11)

# --- nearest_pool: closest center wins; skips empty pools when nonempty ---------
check("nearest_pool near +y -> :north", CB.nearest_pool([0.0, 10.0]) == :north)
check("nearest_pool near -y -> :south", CB.nearest_pool([0.0, -10.0]) == :south)
check("nearest_pool near +x -> :east",  CB.nearest_pool([10.0, 0.0]) == :east)
check("nearest_pool near -x -> :west",  CB.nearest_pool([-10.0, 0.0]) == :west)

# Drain the north pool; with nonempty=true it must no longer be selected even for
# a position right on top of it (the next-nearest non-empty pool wins instead).
CB.pop_spare!(:north); CB.pop_spare!(:north)
check("drained north pool is empty", isempty(CB.spare_pools()[:north]))
np = CB.nearest_pool([0.0, 10.0]; nonempty = true)
check("nearest_pool(nonempty) skips drained :north", np !== :north && np !== nothing)
check("nearest_pool(nonempty=false) still returns :north",
    CB.nearest_pool([0.0, 10.0]; nonempty = false) == :north)

# --- clear_spare_pools! wipes both stores --------------------------------------
CB.clear_spare_pools!()
check("clear_spare_pools! empties pools", isempty(CB.spare_pools()))
check("clear_spare_pools! empties centers", isempty(CB.spare_pool_centers()))
check("nearest_pool on empty stores -> nothing", CB.nearest_pool([0.0, 0.0]) === nothing)

println("\nA1 spare-pool check: $(npass[]) PASS / $(nfail[]) FAIL")
nfail[] == 0 || error("A1 spare-pool check had $(nfail[]) failure(s)")
