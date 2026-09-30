"""정책 배포 게이트 D (spec §0.0 R2): 도구가 아니라 **정책**을 잰다.

개발 검증 풀(seeds 301–315) × 모델 × {zone, all3, fault, battery} 를 router 레인으로 새 버전과 부모
버전에서 각각 돈다. 부모 판은 버전별로 한 번만 돌고 캐시(state/<exp>/dev/<v>/). 논문 평가 풀(201–230)은
쓰지 않는다. 🔴 부모 판의 zone 사건은 LLM 으로 가므로 **유료**다(U3)."""
import json, os, subprocess
from collections import Counter
from . import harvest, paths, versions
from .stats import mcnemar_one_sided

DEV_CASES = ("zone", "all3", "fault", "battery")
_OK_INV = ("ok", "na")


def _case(inst):
    return inst.split("|")[1]


def _summary(runs):
    zone = [r for i, r in runs.items() if _case(i) in ("zone", "all3")]
    lanes = [r.get("zone_lane") for r in zone if r.get("zone_lane")]
    defers = Counter(str(r["defer_reason"]).split(":")[1] for r in runs.values()
                     if str(r.get("defer_reason") or "").startswith("DEFER:"))
    done = [r["sim_seconds"] for r in runs.values() if r["complete"] and r.get("sim_seconds") is not None]
    return {"n": len(runs), "complete": sum(r["complete"] for r in runs.values()),
            "llm_share_zone": (sum(l == "dspy" for l in lanes) / len(lanes)) if lanes else None,
            "llm_cost_per_run": sum(float(r.get("llm_cost_usd") or 0) for r in runs.values()) / max(1, len(runs)),
            "makespan_mean": sum(done) / len(done) if done else None, "defer_reasons": dict(defers)}


def criteria(parent_runs, new_runs):
    inst = sorted(set(parent_runs) & set(new_runs))
    zone = [i for i in inst if _case(i) in ("zone", "all3")]
    a0 = [i for i in inst if _case(i) in ("fault", "battery")]
    b = sum(parent_runs[i]["complete"] and not new_runs[i]["complete"] for i in zone)
    c = sum(new_runs[i]["complete"] and not parent_runs[i]["complete"] for i in zone)
    p = mcnemar_one_sided(b, c)
    b2 = sum(parent_runs[i]["complete"] and not new_runs[i]["complete"] for i in a0)
    bad3 = [i for i in inst
            if not (new_runs[i]["inv"] and new_runs[i]["inv"].get("I1") == "ok"
                    and new_runs[i]["inv"].get("I1b") in _OK_INV
                    and (not new_runs[i]["complete"] or new_runs[i]["inv"].get("I2") == "ok")
                    and all(x.get("execution_ok") for x in new_runs[i]["libarm"]))]
    out = {"D1": {"b": b, "c": c, "p_new_worse": p, "n": len(zone), "pass": c >= b and p >= 0.05},
           "D2": {"b": b2, "n": len(a0), "pass": b2 == 0},
           "D3": {"violations": bad3, "pass": not bad3},
           "missing": sorted(set(parent_runs) ^ set(new_runs)),
           "report": {"parent": _summary(parent_runs), "new": _summary(new_runs)}}
    out["all_pass"] = out["D1"]["pass"] and out["D2"]["pass"] and out["D3"]["pass"] and not out["missing"]
    return out


def dev_runs(exp, v, cfg, workers, port):
    """버전 v 의 개발 풀 판(캐시). 서비스는 여기서 띄우고 내린다."""
    from . import service
    d = os.path.join(paths.state_dir(exp), "dev", v)
    cache = os.path.join(d, "runs.json")
    if os.path.exists(cache):
        return json.load(open(cache))
    h = service.start(exp, v, port=port, register=False)
    grids = []
    try:
        for model in cfg["models"]:
            g = os.path.join(d, model)
            env = dict(service.version_env(exp, v, port), GRID_OUT=g, DEMO_MODEL=paths.MODEL_FILES[model],
                       CAMPAIGN_ID="si-%s-dev-%s-%s" % (exp, v, model))
            subprocess.run(["bash", os.path.join(paths.ROOT, "tools", "monitor", "grid", "render_grid.sh"),
                            "router", " ".join(DEV_CASES), " ".join(map(str, cfg["dev_seeds"])), str(workers)],
                           env=env, cwd=paths.ROOT, check=False)
            grids.append((model, g))
    finally:
        service.stop(h["pid"])
    ledger = [json.loads(l) for l in open(service.ledger_path(exp, v)) if l.strip()] \
        if os.path.exists(service.ledger_path(exp, v)) else []
    runs = {}
    for model, g in grids:
        for case in DEV_CASES:
            for seed in cfg["dev_seeds"]:
                rk = "router__%s__s%d" % (case, seed)
                r = harvest.collect_run(g, rk)
                if r is None:
                    continue
                z = harvest.zone_decision(r)
                cid = (r.get("run_ctx_full") or {}).get("campaign_id")
                runs["%s|%s|s%d" % (model, case, seed)] = {
                    "complete": r["complete"], "inv": r["inv"], "libarm": r["libarm"],
                    "sim_seconds": r.get("sim_seconds"),
                    "zone_lane": None if z is None else z["input"].get("enacted"),
                    "defer_reason": None if z is None else (z["input"].get("router") or {}).get("defer_reason"),
                    "llm_cost_usd": harvest.llm_cost(ledger, cid, rk)[0]}
    os.makedirs(d, exist_ok=True)
    json.dump(runs, open(cache, "w"), indent=1)
    return runs


def run(exp, new_v, workers=8):
    cfg = json.load(open(os.path.join(paths.state_dir(exp), "config.json")))
    parent = versions.load_manifest(exp, new_v)["parent"]
    base = cfg["port_base"] + 50
    P = dev_runs(exp, parent, cfg, workers, base + int(parent[1:]))
    N = dev_runs(exp, new_v, cfg, workers, base + int(new_v[1:]))
    c = criteria(P, N)
    rec = dict(c, parent=parent, version=new_v,
               manifest_sha256=versions.sha256_file(os.path.join(paths.version_dir(exp, new_v), "manifest.json")))
    p = os.path.join(paths.state_dir(exp), "dev", new_v, "gate.json")
    json.dump(rec, open(p, "w"), indent=1)
    return rec
