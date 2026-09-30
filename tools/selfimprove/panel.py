"""S1 재생 · S3 반사실 패널과 판정 (spec §9.2, §9.4, §0.0 R1·R7·R9).

경로: 후보·대조 팔 = state/<exp>/cycles/<c>/s3/<role>/<model>/, NOOP·incumbent 팔 =
state/<exp>/cache/<arm_key>/<cache_key>/<model>/ (모든 회전이 공유). 판은 전부 canonical 레인 —
서비스·LLM 호출이 없다(강제 팔은 `SELFIMPROVE_ARM` 으로 등록·집행된다)."""
import json, os, subprocess
from . import harvest, paths
from .stats import mcnemar_one_sided, wilson_lower
from .versions import canonical, sha256_bytes

RENDER_GRID = os.path.join(paths.ROOT, "tools", "monitor", "grid", "render_grid.sh")


def arm_dir(exp, c, role):
    return os.path.join(paths.state_dir(exp), "cycles", c, "s3", role)


def cache_key(code_rev, dirty, config, seeds, models, cases):
    return sha256_bytes(canonical([code_rev, dirty, config, list(seeds), list(models), list(cases)]).encode())[:16]


def cache_dir(exp, arm_key, key):
    return os.path.join(paths.state_dir(exp), "cache", arm_key, key)


def run_arm(exp, grid_dir, arm_path, arm_sha, seeds, models, cases, workers, runner=None):
    """모델마다 그리드 하나. `runner(argv, env)` 는 시험이 주입한다(기본 subprocess)."""
    runner = runner or (lambda argv, env: subprocess.run(argv, env=env, cwd=paths.ROOT, check=False))
    grids = []
    for model in models:
        g = os.path.join(grid_dir, model)
        env = dict(os.environ, GRID_OUT=g, DEMO_MODEL=paths.MODEL_FILES[model],
                   CAMPAIGN_ID="si-%s-%s-%s" % (exp, os.path.basename(grid_dir.rstrip("/")), model))
        env.pop("DSPY_URL", None)                    # canonical 레인: 서비스 신원 검사를 안 태운다
        for k in ("SELFIMPROVE_ARM", "SELFIMPROVE_ARM_SHA"):
            env.pop(k, None)
        if arm_path:
            env.update(SELFIMPROVE_ARM=os.path.abspath(arm_path), SELFIMPROVE_ARM_SHA=arm_sha)
        runner(["bash", RENDER_GRID, "canonical", " ".join(cases), " ".join(map(str, seeds)),
                str(workers)], env)
        grids.append((model, g))
    return grids


def collect(grids, cases, seeds):
    """{instance: run}. instance = "<model>|<case>|s<seed>", run 에 stratum 을 붙인다."""
    out = {}
    for model, g in grids:
        for case in cases:
            for seed in seeds:
                r = harvest.collect_run(g, "canonical__%s__s%d" % (case, seed))
                if r is not None:
                    r["stratum"] = "%s|%s" % (model, case)
                    out["%s|%s|s%d" % (model, case, seed)] = r
    return out


def _inv_ok(r):
    inv = r.get("inv") or {}
    return inv.get("I1") == "ok" and inv.get("I1b") in ("ok", "na") and \
        (not r["complete"] or inv.get("I2") == "ok")


def s1(exp, c, cand_path, cand_sha, src, workers=2, runner=None):
    """출처 (model, case, seed) 에서 후보를 두 번. 통과: 등록·집행 전부 execution_ok, 두 판 완주,
    `[score]`·`[invariant]` 바이트 동일, 불변식 통과. 출처 판과 결과가 달라도 거부하지 않는다."""
    base = os.path.join(paths.state_dir(exp), "cycles", c, "s1")
    runs = []
    for rep in ("a", "b"):
        grids = run_arm(exp, os.path.join(base, rep), cand_path, cand_sha, [src["seed"]],
                        [src["model"]], [src["case"]], workers, runner)
        runs.append(collect(grids, [src["case"]], [src["seed"]]).get(
            "%s|%s|s%d" % (src["model"], src["case"], src["seed"])))
    lines = []
    for rep, r in zip("ab", runs):
        if r is None:
            lines.append(None)
            continue
        txt = open(os.path.join(base, rep, src["model"], "log",
                                "canonical__%s__s%d.log" % (src["case"], src["seed"])), errors="replace").read()
        lines.append([l for l in txt.splitlines() if l.startswith(("[score]", "[invariant]"))])
    why = []
    if any(r is None for r in runs):
        why.append("unmeasured")
    else:
        if not all(r["libarm"] for r in runs):
            why.append("arm_never_enacted")
        if not all(x["execution_ok"] for r in runs for x in r["libarm"]):
            why.append("execution_not_ok")
        if not all(r["complete"] for r in runs):
            why.append("incomplete")
        if lines[0] != lines[1]:
            why.append("nondeterministic")
        if not all(_inv_ok(r) for r in runs):
            why.append("invariant")
    rep = {"pass": not why, "why": why, "lines": lines,
           "runs": [None if r is None else {k: r.get(k) for k in ("complete", "closed", "inv", "libarm", "rc")}
                    for r in runs]}
    os.makedirs(base, exist_ok=True)
    with open(os.path.join(base, "report.json"), "w") as f:
        json.dump(rep, f, indent=1)
    return rep


def criteria(noop, t, tnull, incumbent, tau):
    inst = sorted(noop)
    E = [i for i in inst if not noop[i]["complete"]]                     # R1: 고정 분모
    rescued = [i for i in E if t[i]["complete"]]
    harm = [i for i in inst if noop[i]["complete"] and not t[i]["complete"]]
    honest = all(t[i]["inv"]["I1"] == "ok" and t[i]["inv"]["I1b"] in ("ok", "na") and
                 (not t[i]["complete"] or t[i]["inv"]["I2"] == "ok") for i in inst)
    sound = all((not t[i]["complete"] or t[i]["inv"]["I3"] == 0) and
                all(x["execution_ok"] and x["wall_s"] <= 60 for x in t[i]["libarm"]) and
                t[i]["rc"] != 124 for i in inst)
    lo = wilson_lower(len(rescued), len(E))
    out = {
        "C1_honest": {"pass": honest},
        "C2_sound": {"pass": sound},
        "C3_rescue": {"k": len(rescued), "n": len(E), "lower": lo, "pass": lo >= tau,
                      "aux_world_deadlock": sum(1 for i in E if t[i]["fail_mode"] == "world_deadlock")},
        "C4_harm": {"n_harm": len(harm), "of": len(inst) - len(E), "pass": not harm},
    }
    strata = {}
    for i in E:
        strata.setdefault(t[i]["stratum"], []).append(t[i]["complete"])
    out["C6_strata"] = {"by": {s: sum(v) / len(v) for s, v in strata.items()},
                        "n": {s: len(v) for s, v in strata.items()},
                        "pass": all(sum(v) / len(v) >= 0.5 for v in strata.values() if len(v) >= 5)}
    if tnull is not None:
        b = sum(1 for i in inst if t[i]["complete"] and not tnull[i]["complete"])
        c = sum(1 for i in inst if tnull[i]["complete"] and not t[i]["complete"])
        out["C5_causal"] = {"b": b, "c": c, "p": mcnemar_one_sided(b, c),
                            "pass": mcnemar_one_sided(b, c) < 0.05}
    if incumbent is not None:                                             # R7: 교체 트랙
        b = sum(1 for i in inst if t[i]["complete"] and not incumbent[i]["complete"])
        c = sum(1 for i in inst if incumbent[i]["complete"] and not t[i]["complete"])
        out["C7_beats_incumbent"] = {"b": b, "c": c, "p": mcnemar_one_sided(b, c),
                                     "pass": mcnemar_one_sided(b, c) < 0.05}
    need = ["C1_honest", "C2_sound", "C3_rescue", "C4_harm", "C6_strata"] + \
           (["C5_causal"] if tnull is not None else []) + \
           (["C7_beats_incumbent"] if incumbent is not None else [])
    out["all_pass"] = all(out[k]["pass"] for k in need)
    return out


def unmeasured(noop, arm):
    """판이 없거나 `[invariant]` 줄을 못 찍은 인스턴스 → 회전은 REJECTED(S3, unmeasured) (spec §13)."""
    return sorted(i for i in noop if i not in arm or arm[i].get("inv") is None)
