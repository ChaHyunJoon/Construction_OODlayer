# T5 contract fixture (trusted test code, not a generated tool): plant the goal=start pattern that three of the four
# historical anchors used (T0 audit) — the first unclosed TransportUnitGo's goal is set to its own start pose, so the
# transport unit never drives to the deposit location. The episode may still complete; the task contract must not.
using ConstructionBots
const CB = ConstructionBots
function branch_action!(env)
    tus = sort!([n for n in CB.get_nodes(env.sched) if CB.matches_template(CB.TransportUnitGo, n) &&
                 !(CB.get_vtx(env.sched, CB.node_id(n)) in env.cache.closed_set)]; by = n -> string(CB.node_id(n)))
    isempty(tus) && error("no unclosed TransportUnitGo")
    t = first(tus)
    CB.set_desired_global_transform!(CB.goal_config(t), CB.global_transform(CB.start_config(t)))
    return "goal := start for $(CB.node_id(t))"
end
