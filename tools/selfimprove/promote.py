"""승인된 회전 → artifact 기록(라이브러리 원장) → 다음 버전의 활성 팔 집합·레지스트리 (spec §11.1–11.2, §0.0 R7·R9).

원장은 "승인됨"만 기록한다(멱등, arm_id 는 승인 시점에 고정). 어느 버전에서 활성인지는 manifest 가 정한다."""
import copy, hashlib, json, os
from . import harvest, library, paths, psi_calc, review, static_check, versions


def _cdir(exp, c):
    return os.path.join(paths.state_dir(exp), "cycles", c)


def _load(p):
    return json.load(open(p, encoding="utf-8"))


def _config(exp):
    return _load(os.path.join(paths.state_dir(exp), "config.json"))


def record_artifact(exp, c):
    d = _cdir(exp, c)
    dec = _load(os.path.join(d, "review", "decision.json"))
    if dec["decision"] != "approve":
        raise RuntimeError("cycle %s was not approved" % c)
    cy, cand = _load(os.path.join(d, "cycle.json")), _load(os.path.join(d, "candidate.json"))
    body = cand["body"]
    a = harvest.arm_like(body)
    ctx = body.get("run_ctx") or {}
    a0 = _config(exp)["a0_sha256"]
    entry = dict(
        artifact_sha256=harvest.artifact_of(body), impl_name=body["impl_name"],
        impl_code_sha256=hashlib.sha256(body["impl_code"].encode()).hexdigest(),
        behavior_key=cy["behavior_key"], calls=a["calls"], params=a["params"], surface=a["surface"],
        body_names=a["body_names"], reversible=a["reversible"], track=cy.get("track"),
        incumbent_arm_id=cy.get("incumbent_arm_id"),
        psi=psi_calc.psi_for(review.called_names(cy["behavior_key"]), review.psi_table(exp)),
        source={"exp": exp, "campaign_id": ctx.get("campaign_id"), "run_id": ctx.get("run_id"),
                "record_id": body.get("record_id"), "response_id": body.get("response_id"),
                "parent_record_id": body.get("parent_record_id"), "logged_at": body.get("logged_at"),
                "llm_model": (cand.get("representative") or {}).get("llm_model")},
        s3_summary_sha256=versions.sha256_file(os.path.join(d, "s3_summary.json")),
        decision_sha256=versions.sha256_file(os.path.join(d, "review", "decision.json")),
        a0_sha256=a0)
    row = library.approve(exp, c, entry, a0)
    library.write_source(exp, row["arm_id"], body["impl_name"], body["impl_code"], [
        "selfimprove arm %d — DO NOT EDIT (provenance: library.jsonl entry %d)" % (row["arm_id"], row["arm_id"]),
        "source: %s/%s record %s (%s, %s)" % (ctx.get("campaign_id"), ctx.get("run_id"), body.get("record_id"),
                                             entry["source"]["llm_model"], body.get("logged_at")),
        "impl_code sha256: %s" % entry["impl_code_sha256"]])
    return row


def _version_arms(exp, v):
    m = versions.load_manifest(exp, v)
    d = paths.version_dir(exp, v)
    return [_load(os.path.join(d, "arms", "m%d.json" % a["arm_id"])) for a in m["arms"]]


def next_active_set(exp, parent_v, c):
    row = next(r for r in library.read(exp) if r["cycle"] == c)
    body = _load(os.path.join(_cdir(exp, c), "candidate.json"))["body"]
    arm = static_check.arm_json(body, row["arm_id"], "promoted", "m%d_%s" % (row["arm_id"], body["impl_name"]))
    arm.update(psi=row["psi"], behavior_key=row["behavior_key"], library_artifact_sha256=row["artifact_sha256"])
    drop = row["incumbent_arm_id"] if row.get("track") == "replace" else None
    keep = [a for a in _version_arms(exp, parent_v) if a["arm_id"] != drop and a["arm_id"] != row["arm_id"]]
    return sorted(keep + [arm], key=lambda a: a["arm_id"])


def g3_psi_distinct(active):
    """활성 팔끼리 ψ 10축이 전부 같은 쌍이 있으면 False (표현의 한계를 막는 방어선일 뿐)."""
    seen = [json.dumps(a["psi"], sort_keys=True) for a in active]
    return len(seen) == len(set(seen))


def registry_for(active):
    reg = copy.deepcopy(_load(paths.A0_REGISTRY))
    if "zone" not in reg["macros"]["0"]["kinds"]:
        reg["macros"]["0"]["kinds"].append("zone")
    for a in active:
        reg["macros"][str(a["arm_id"])] = {
            "name": a["impl_name"], "cost": float(a["psi"]["a_cost"]), "kinds": ["zone"],
            "mechanism": "selfimprove library arm %d (%s): %s" % (a["arm_id"], a["source_impl_name"], a["behavior_key"]),
            "when_to_use": "promoted by the selfimprove gate for zone events", "origin": "minted",
            "library_arm": a["arm_id"], "psi": a["psi"], "artifact_sha256": a["library_artifact_sha256"]}
    n = len(active)
    reg["vocab"] = "v%d-%darms" % (4 + n, 3 + n)
    return reg
