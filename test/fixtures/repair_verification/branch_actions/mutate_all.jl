# T4 isolation fixture (trusted test code, not a generated tool): mutate RVO / zone / cache / spare / ID / RNG
# at t0 inside a branch worker. The parent and every other branch must not see any of it.
using ConstructionBots, Random
const CB = ConstructionBots
function branch_action!(env)
    did = String[]
    sim = CB.rvo_global_sim()                                   # RVO native state
    p = sim.getAgentPosition(0); sim.setAgentPosition(0, (p[1] + 0.05, p[2])); push!(did, "rvo agent 0 x+0.05")
    zs = CB.RESTRICTION_ZONES[]                                 # zone (a protected world object)
    if !isempty(zs)
        k = first(sort!(collect(keys(zs)); by = string)); delete!(zs, k); push!(did, "zone $(k) deleted")
    end
    q = env.cache.node_queue                                    # planning cache
    if !isempty(q)
        k = first(sort!(collect(keys(q)))); q[k] = (q[k][1], q[k][2] + 1.0); push!(did, "cache slack of $(k) +1")
    end
    pools = CB.SPARE_POOLS[]                                    # spares
    for k in sort!(collect(keys(pools)); by = string)
        isempty(pools[k]) && continue
        pop!(pools[k]); push!(did, "spare popped from $(k)"); break
    end
    T = first(sort!(collect(keys(CB.VALID_ID_COUNTERS)); by = string))   # ID counters
    for _ in 1:5; CB.get_unique_id(T); end; push!(did, "5 ids of $(T)")
    rand(1000); push!(did, "default RNG advanced")              # RNG
    return did
end
