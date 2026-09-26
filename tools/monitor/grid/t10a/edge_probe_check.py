"""edge_probe 결과 판정: t0 의미적 선행(task_contract.semantic_edges) ⊆ 계획 직후(pre_injection) 건설↔건설 간선인가,
그리고 t0 까지 새로 생긴 간선(어느 종류든)이 있는가."""
import json, sys, os
from collections import Counter
CON = None
for d in sys.argv[1:]:
    pre, post, t0 = (json.load(open(os.path.join(d, f + ".json"))) for f in ("pre_injection", "post_injection", "t0"))
    c = json.load(open(os.path.join(d, "t0_task_contract.json")))
    kinds = t0["nodes"]
    req = c["required_nodes"]
    iscon = lambda i: i in req
    E = lambda s: set(map(tuple, s["edges"]))
    pre_con = {e for e in E(pre) if iscon(e[0]) and iscon(e[1])}
    sem = set(map(tuple, c["semantic_edges"]))
    added = E(t0) - E(pre); removed = E(pre) - E(t0)
    added_post = E(post) - E(pre)
    print(os.path.basename(d), json.dumps({
        "n_edges_pre": len(E(pre)), "n_edges_t0": len(E(t0)), "n_semantic_t0": len(sem), "n_con_con_pre": len(pre_con),
        "semantic_eq_pre_con_con": sem == pre_con, "semantic_minus_pre": len(sem - pre_con), "pre_con_minus_semantic": len(pre_con - sem),
        "edges_added_pre_to_t0": len(added), "edges_removed_pre_to_t0": len(removed), "edges_added_by_pre_hook": len(added_post),
        "added_kinds": dict(Counter((kinds.get(a), kinds.get(b)) for a, b in added).most_common()) if added else {},
        "wedge_edges_t0": len(t0["wedge_edges"]), "runtime_edges_at_t0": len(c["runtime_edges_at_t0"]),
        "runtime_edge_kinds": dict(Counter("%s->%s" % (kinds.get(a), kinds.get(b)) for a, b in c["runtime_edges_at_t0"]).most_common(8)),
        "semantic_edge_kinds": dict(Counter("%s->%s" % (kinds.get(a), kinds.get(b)) for a, b in sem).most_common()),
        "closed_t0": len(t0["closed"]), "t0_state_sha256": c["t0_state_sha256"]}, indent=1))
