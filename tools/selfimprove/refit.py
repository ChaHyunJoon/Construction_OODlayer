"""재적합 데이터셋 조립과 버전 빌드 (spec §11.4, §0.0 R2·R10). 여기까지는 **배포하지 않는다**(D 게이트·deploy 가 한다).

데이터셋 v_{k+1} = A₀ render 재라벨 + 게이트 풀 zone 인스턴스의 NOOP 행 + 활성 팔 행. 전부 render 엔진 라벨,
T_null·거부 후보·비활성 팔 행은 없다. zone 행은 변환 동등성(parity)을 통과해야 한다."""
import json, os, subprocess, sys
from . import library, paths, probe, promote, review, rows, versions

sys.path.insert(0, os.path.join(paths.ROOT, "src", "decision", "core"))
import objective  # noqa: E402

TRAIN_KINDS = "battery,fault,zone"


def stamps_for(active):
    reg = promote.registry_for(active)
    return {"vocab": reg["vocab"], "train_kinds": TRAIN_KINDS, "objective_hash": objective.objective_hash(),
            "names": {int(k): m["name"] for k, m in reg["macros"].items()}}


def assemble_rows(a0_rows, panels, active_ids, stamps):
    """panels: {arm_id(0=NOOP): {"<model>|<case>|s<seed>": run}}."""
    out = []
    for r in a0_rows:
        if r.get("label_engine") != "render":
            raise ValueError("non-render label row %s — v1+ datasets are render-engine only (R10)" % r.get("instance"))
        out.append(dict(r, vocab=stamps["vocab"], train_kinds=stamps["train_kinds"]))
    menu = [0] + sorted(active_ids)
    for inst in sorted(panels.get(0, {})):
        runs = [panels.get(a, {}).get(inst) for a in menu]
        if any(r is None or rows.first_decision(r, "zone") is None for r in runs):
            continue
        model, case, s = inst.split("|")
        iid = "zone_%s_%s_%s" % (model, case, s)
        for a, run in zip(menu, runs):
            row = rows.row_from_run(run, a, iid, "zone", menu, stamps)
            if not rows.parity_ok(row, rows.first_decision(run, "zone")["input"]["router"]["descriptors"]):
                raise ValueError("parity failed for %s arm %d — refusing to refit" % (iid, a))
            out.append(row)
    return out


def _git(*a):
    return subprocess.run(["git", *a], cwd=paths.ROOT, capture_output=True, text=True).stdout.strip()


def build_version(exp, c, panels, code_rev=None, dirty=None):
    """artifact 기록(멱등) → 활성 집합 → G3 → 레지스트리·데이터셋 → F1·F2·F5 → 불변 버전. 새 버전 이름."""
    cfg = promote._config(exp)
    cy = json.load(open(os.path.join(promote._cdir(exp, c), "cycle.json")))
    parent = cy.get("parent_version") or versions.read_current(exp)[0]
    row = promote.record_artifact(exp, c)
    active = promote.next_active_set(exp, parent, c)
    if not promote.g3_psi_distinct(active):
        raise RuntimeError("G3: psi_duplicate among active arms %s" % [a["arm_id"] for a in active])
    build = os.path.join(promote._cdir(exp, c), "build")
    os.makedirs(build, exist_ok=True)
    reg = promote.registry_for(active)
    reg_p, ds_p = os.path.join(build, "action_registry.json"), os.path.join(build, "dataset.jsonl")
    json.dump(reg, open(reg_p, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    a0 = [json.loads(l) for l in open(os.path.join(paths.data_dir(exp), "labels", "a0_render.jsonl")) if l.strip()]
    ds = assemble_rows(a0, panels, [a["arm_id"] for a in active], stamps_for(active))
    with open(ds_p, "w", encoding="utf-8") as f:
        for r in ds:
            f.write(json.dumps(r, sort_keys=True) + "\n")
    pr = probe.fit_probe(ds_p, reg_p)                                                 # F1
    if pr["surro_kinds"] != ["battery", "fault", "zone"]:                             # F2
        raise RuntimeError("F2: surro_kinds %s" % pr["surro_kinds"])
    if not {a["arm_id"] for a in active} <= set(pr["surro_support"]):
        raise RuntimeError("F2: support %s misses active arms" % pr["surro_support"])
    if probe.fit_probe(ds_p, reg_p)["probe_sha256"] != pr["probe_sha256"]:            # F5
        raise RuntimeError("F5: refit is not deterministic")
    v = versions.next_version(exp)
    psi_p = os.path.join(paths.data_dir(exp), "psi", "base_psi.json")
    versions.write_version(exp, dict(
        exp=exp, version=v, parent=parent, a0_sha256=cfg["a0_sha256"],
        library_head=library.head(exp, cfg["a0_sha256"]),
        active_artifacts=[{"arm_id": a["arm_id"], "artifact_sha256": a["library_artifact_sha256"]} for a in active],
        surro_tau=cfg["tau"], surro_rule=cfg["surro_rule"],
        feature_schema_sha256=probe.feature_schema_sha256(), objective_hash=pr["objective_hash"],
        psi_table_sha256=versions.sha256_file(psi_p), label_engine="render", vocab=reg["vocab"],
        code_rev=code_rev or _git("rev-parse", "HEAD"),
        code_dirty_digest=dirty if dirty is not None else _tree_digest(), model_probe_sha256=pr["probe_sha256"],
        cycle=c), reg_p, ds_p, active, {"psi_table.json": psi_p})
    return v


def _tree_digest():
    sys.path.insert(0, os.path.join(paths.ROOT, "tools", "monitor", "grid"))
    import campaign
    return campaign.tree_digest(paths.ROOT)
