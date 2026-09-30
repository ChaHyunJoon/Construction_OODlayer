"""큐를 보고 트리거되면 회전을 연다 — 한 번에 하나 (spec §7, §4.2)."""
import glob, json, os, time
from . import cycle, library, paths, trigger, versions


def _jsonl(p):
    return [json.loads(l) for l in open(p, encoding="utf-8") if l.strip()] if os.path.exists(p) else []


def _cycles(exp):
    return [json.load(open(p)) for p in sorted(glob.glob(os.path.join(paths.state_dir(exp), "cycles", "c*", "cycle.json")))]


def _active_arms(exp, v):
    d = paths.version_dir(exp, v)
    return [json.load(open(os.path.join(d, "arms", "m%d.json" % a["arm_id"])))
            for a in versions.load_manifest(exp, v)["arms"]]


def tick(exp, run_cycle=True):
    sd = paths.state_dir(exp)
    queue = _jsonl(os.path.join(sd, "queue.jsonl"))
    for q in queue:
        b = os.path.join(sd, "bodies", "%s.json" % q.get("artifact_sha256"))
        if q.get("artifact_sha256") and os.path.exists(b):
            q["impl_code"] = json.load(open(b))["impl_code"]
    queue = [q for q in queue if not q.get("artifact_sha256") or "impl_code" in q]
    v, _ = versions.read_current(exp)
    due = trigger.due(queue, _cycles(exp), library.read(exp), _active_arms(exp, v), m=_cfg(exp)["m"])
    if not due:
        return None
    d = due[0]
    c = "c%d" % len(_cycles(exp))
    rep = trigger.representative(d["members"])
    body = json.load(open(os.path.join(sd, "bodies", "%s.json" % rep["artifact_sha256"])))
    cycle.open_cycle(exp, c, body, {k: v2 for k, v2 in rep.items() if k != "impl_code"},
                     [{k: v2 for k, v2 in m.items() if k != "impl_code"} for m in d["members"]],
                     d["behavior_key"], d["track"], d["incumbent_arm_id"], len(queue), v)
    if run_cycle:
        cycle.run(exp, c)
    return c


def _cfg(exp):
    return json.load(open(os.path.join(paths.state_dir(exp), "config.json")))


def run(exp, poll_s=60, once=False):
    while True:
        tick(exp)
        if once:
            return
        time.sleep(poll_s)
