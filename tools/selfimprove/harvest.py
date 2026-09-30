"""수확: 판 하나 → 큐 행 (spec §6, §0.0 R6·R7).

🔴 body 는 **실제로 설치·집행된** 기록만이다: 재집행된 rewrite 가 있으면 그 시도의 원장 행, 없으면 decide
행이 굴렀을 때만(결정 기록 steps 비지 않음), 그 밖은 None. 신원은 artifact 해시. 판 완주는 그 body 가
원인이라는 증거가 아니라 트리거의 약한 신호일 뿐이다."""
import hashlib, json, os, re, sys
from . import library, paths
from .versions import canonical

sys.path.insert(0, os.path.join(paths.ROOT, "tools", "monitor"))
import build_sweep_dataset as bsd  # noqa: E402


def world_interface_names(path=paths.WORLD_INTERFACE):
    return {m["name"] for m in json.load(open(path, encoding="utf-8"))["methods"]}


def behavior_key(impl_code, kind, names):
    """kind | 정렬된 world-interface 호출 집합 — **트리거 묶음 전용**(R7). 정확한 중복은 artifact 해시."""
    called = sorted(n for n in names
                    if re.search(r"(?<![\w!])" + re.escape(n) + r"\(", impl_code))
    return kind + "|" + (",".join(called) if called else "∅")


def arm_like(row):
    """원장 행 → artifact 해시·arm.json 이 보는 필드. rewrite 행은 body_names 가 없어 calls 에서 유도한다."""
    calls = row.get("calls") or []
    return {"impl_name": row["impl_name"], "impl_code": row["impl_code"], "calls": calls,
            "params": row.get("params") or {}, "surface": row.get("surface") or "unknown",
            "reversible": bool(row.get("reversible")),
            "body_names": row.get("body_names") or [c["primitive"] for c in calls]}


def artifact_of(row):
    return library.artifact_hash(arm_like(row))


def _ctx_match(row, campaign_id, run_id):
    c = row.get("run_ctx") or {}
    return c.get("campaign_id") == campaign_id and c.get("run_id") == run_id


def executed_body(ledger_rows, campaign_id, run_id, decision):
    decides = [r for r in ledger_rows if r.get("row_type") == "decide" and _ctx_match(r, campaign_id, run_id)]
    if not decides:
        return None
    d = next((r for r in decides if r.get("kind") == "zone"), decides[0])
    installed = [o for o in bsd.rewrite_outcome(decision) if o["installed"]]
    if installed:
        rid = installed[-1]["record_id"]
        hit = [r for r in ledger_rows if r.get("record_id") == rid and r.get("row_type") == "rewrite"]
        return hit[0] if hit else None
    return d if (decision.get("steps") or []) else None


def llm_cost(ledger_rows, campaign_id, run_id):
    cost, models = 0.0, set()
    for r in ledger_rows:
        if not _ctx_match(r, campaign_id, run_id):
            continue
        for calls in (r.get("raw_lm") or {}).values():
            for c in calls or []:
                cost += float(c.get("cost") or 0.0)
                c.get("model") and models.add(c["model"])
    return cost, sorted(models)


def save_body(exp, row):
    d = os.path.join(paths.state_dir(exp), "bodies")
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, artifact_of(row) + ".json")
    if not os.path.exists(p):
        with open(p, "w", encoding="utf-8") as f:
            f.write(canonical(row))
    return p


def _jsonl(path):
    return [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()] if os.path.exists(path) else []


_LIBARM_RE = re.compile(r"^\[libarm\] (\{.*\})\s*$", re.M)
_INV_RE = re.compile(r"^\[invariant\] (\{.*\})\s*$", re.M)


def collect_run(grid, run_key):
    """판 하나의 사실: `parse_log` + `attach_stream` + `[invariant]`·`[libarm]` + 결정 기록 원본 + rc.
    채점 줄이 없으면 None. 모양은 `rows.row_from_run` 이 소비한다."""
    lane, case, s = run_key.split("__")
    log = os.path.join(grid, "log", run_key + ".log")
    if not os.path.exists(log):
        return None
    txt = open(log, encoding="utf-8", errors="replace").read()
    r = bsd.parse_log(txt, lane, case, int(s.lstrip("s")))
    if r is None:
        return None
    job = next((j for j in _jsonl(os.path.join(grid, "jobs.jsonl")) if j["run_key"] == run_key), {})
    stream = job.get("stream")
    bsd.attach_stream(r, stream if stream and os.path.exists(stream) else None, stream, r["closed"])
    last = bsd.last_json_line(stream) if stream and os.path.exists(stream) else None
    r["decisions_raw"] = (last or {}).get("respec_history") or []
    nt = re.findall(r"n_total: (\d+)", txt)
    r["n_total"] = int(nt[-1]) if nt else None
    m = _INV_RE.search(txt)
    r["inv"] = json.loads(m.group(1)) if m else None
    r["libarm"] = [json.loads(x) for x in _LIBARM_RE.findall(txt)]
    r["minted_verdict"] = bsd.grab(txt, r"\[minted\] lane=present tool=\S+ verdict=(\S+)")
    r["run_ctx_full"] = bsd.run_ctx_of(txt) or {}
    run = [x for x in _jsonl(os.path.join(grid, "runs.jsonl")) if x.get("run_key") == run_key]
    r["rc"] = run[-1].get("rc") if run else None
    return r


def zone_decision(run):
    for h in run.get("decisions_raw") or []:
        rt = (h.get("input") or {}).get("router") or {}
        if (rt.get("ood_features") or {}).get("kind") == "zone" or \
                str(rt.get("routing_kind", "")).endswith("zone"):
            return h
    return None


def harvest_run(exp, grid, run_key, ledger_path, names=None):
    """큐 행 하나를 append 하고 돌려준다. zone 결정이 없는 판·이미 수확한 판은 None."""
    run = collect_run(grid, run_key)
    if run is None:
        return None
    ctx = run["run_ctx_full"]
    q_id = "%s/%s" % (ctx.get("campaign_id"), run_key)
    qp = os.path.join(paths.state_dir(exp), "queue.jsonl")
    if any(q["q_id"] == q_id for q in _jsonl(qp)):
        return None
    h = zone_decision(run)
    if h is None:
        return None
    rt = h["input"].get("router") or {}
    lane = h["input"].get("enacted")
    ledger = _jsonl(ledger_path) if lane == "dspy" else []
    body = executed_body(ledger, ctx.get("campaign_id"), run_key, h) if lane == "dspy" else None
    cost, models = llm_cost(ledger, ctx.get("campaign_id"), run_key)
    names = names if names is not None else world_interface_names()
    q = {"q_id": q_id, "version": ctx.get("agent_version") or None, "model": ctx.get("model"),
         "case": run["case"], "seed": run["seed"], "lane": lane,
         "router_axis": rt.get("router_axis"), "defer_reason": rt.get("defer_reason"),
         "complete": run["complete"], "fail_mode": run.get("fail_mode"), "closed": run["closed"],
         "n_total": run["n_total"], "record_id": None, "final_row": None, "impl_name": None,
         "artifact_sha256": None, "impl_code_sha256": None, "behavior_key": None,
         "llm_model": models, "llm_cost_usd": round(cost, 6), "logged_at": None}
    if body is not None:
        q.update(record_id=body["record_id"], final_row=body["row_type"], impl_name=body["impl_name"],
                 artifact_sha256=artifact_of(body), logged_at=body.get("logged_at"),
                 impl_code_sha256=hashlib.sha256(body["impl_code"].encode()).hexdigest(),
                 behavior_key=behavior_key(body["impl_code"], "zone", names))
        save_body(exp, body)
    os.makedirs(os.path.dirname(qp), exist_ok=True)
    with open(qp, "a", encoding="utf-8") as f:
        f.write(canonical(q) + "\n")
    return q
