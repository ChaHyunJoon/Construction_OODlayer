# Proves draw_spare_depots! / draw_decommissioned_robots! actually execute their
# setobject! calls on a REAL (headless) MeshCat visualizer -- i.e. the depot pads and
# fault pin land in the scene tree (not just no-op'd). The draw fns push their key into
# a drawn-set AFTER the setobject! loop, so a populated drawn-set proves the geometry
# was created without error. Run: julia +lts --project=. tools/depot_render_check.jl
using ConstructionBots
import MeshCat
const CB = ConstructionBots

npass = Ref(0); nfail = Ref(0)
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))

println(">>> depot / fault-marker render check (headless MeshCat)")
vis = MeshCat.Visualizer()          # headless (no browser); starts an in-proc server

CB.clear_spare_pools!()
CB.clear_depot_markers!()
CB.clear_decommissioned_markers!()

# populate a depot the way add_directional_spare_pools! does
CB.SPARE_POOL_CENTERS[][:north] = [0.0, 6.0]
CB.SPARE_POOL_CENTERS[][:east]  = [6.0, 0.0]
CB.DEPOT_INFO[][:north] = (capacity = 2, halfw = 1.0, halfd = 0.5)
CB.DEPOT_INFO[][:east]  = (capacity = 2, halfw = 1.0, halfd = 0.5)

CB.draw_spare_depots!(vis)          # must run setobject! for each side without error
check("draw_spare_depots! drew :north pad+posts", :north in CB._DRAWN_DEPOT_MARKERS[])
check("draw_spare_depots! drew :east pad+posts",  :east  in CB._DRAWN_DEPOT_MARKERS[])

# idempotency: a second call adds nothing new (already drawn)
before = length(CB._DRAWN_DEPOT_MARKERS[])
CB.draw_spare_depots!(vis)
check("draw_spare_depots! idempotent", length(CB._DRAWN_DEPOT_MARKERS[]) == before)

# fault pin at a break spot
rid = CB.get_unique_id(CB.RobotID)
CB.decommissioned_bodies()[rid] = [1.4, 0.7]
CB.draw_decommissioned_robots!(vis)
check("draw_decommissioned_robots! drew the red fault pin", rid in CB._DRAWN_DECOMMISSIONED[])

println("\ndepot render check: $(npass[]) PASS / $(nfail[]) FAIL")
nfail[] == 0 || error("depot render check had $(nfail[]) failure(s)")
