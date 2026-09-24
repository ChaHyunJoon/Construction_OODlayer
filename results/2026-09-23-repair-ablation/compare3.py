#!/usr/bin/env python3
"""none·A1(translate)·A2(all) 같은 시드 비교 + 팔 신원(I2) + 오라클 조건부 A2 + body 기전 분류.

헤드라인 수치에서 빠지는 판(따로 보고):
  · 채점 안 된 판(sweep.json `unscored`)
  · 팔 신원 실패: [ablation] 줄 없음(0 으로 접지 않는다) · level≠arm · armed≠true ·
    exempt 자리 ⊄ 허용 넷 · run_ctx.repair_ablation≠arm · campaign set_env.REPAIR_ABLATION≠arm ·
    health_<lvl>.pre.json repair_ablation≠arm
  · denied>0 판(denied_by: 로 분류)
McNemar 는 두 팔 모두 헤드라인에 남은 시드 쌍만 쓴다.
사용: python3 compare3.py   → stdout + compare3.json
"""
import json, math, os, re
from collections import Counter
R = os.path.dirname(os.path.abspath(__file__))
ALL_ARMS = ("none", "translate", "all")
# 🔴 2026-09-23 23:3x: A2(all) 팔은 사용자 결정으로 보류(STOP 파일). 두 모델 sweep.json 이 다 있는 팔만 비교한다;
#    나머지는 "not run (held by user)" 로 보고하고 실패로 치지 않는다. all-tractor 의 G4 파일럿 4판은 pilot 으로만 싣는다.
ARMS = tuple(a for a in ALL_ARMS if all(os.path.isfile(os.path.join(R, "%s-%s" % (a, m), "sweep.json"))
                                        for m in ("tractor", "xwing")))
HELD = tuple(a for a in ALL_ARMS if a not in ARMS)
MODELS = ("tractor", "xwing")
CASES = ("zone", "all3")
ALLOWED_EXEMPT = {"policy_payload", "reference_label", "monitor_record", "dp_lane"}
DENIED_ALL = ("translate_whole_build!", "_apply_uniform_translation!", "_find_min_translation",
              "_find_clear_translation", "_minimum_clear_translation", "zone_relocatable",
              "core_zone_for_severity", "zone_diagnosis", "zone_diagnoses",
              "find_clear_staging_center", "restage_assembly!", "restage_all_blocked!")
PRIOR = os.path.join(R, "..", "2026-09-23-router-sol-%s", "sweep.json")   # 9/23 오전 117판(m8 부수 보고)


def mcnemar(b, c):
    """정확 이항(양측). b = none 만 완주, c = 비교 팔만 완주."""
    n = b + c
    if n == 0:
        return 1.0
    k = min(b, c)
    return min(1.0, 2 * sum(math.comb(n, i) for i in range(k + 1)) / 2 ** n)


def mechanism(code):
    if not code:
        return "empty"
    # calls_base 를 가른다: A1 차단 목록(평행이동 해법) 호출 vs A2 에서만 차단되는 restage 해법만 호출
    if any(n + "(" in code for n in DENIED_ALL[:9]):
        return "calls_base:translate"
    if any(n + "(" in code for n in DENIED_ALL[9:]):
        return "calls_base:restage_only"
    if "set_desired_global_transform!" in code and "staging_circles" in code:
        return "hand_translate"
    if "set_desired_global_transform!" in code:
        return "hand_geometry"
    if re.search(r"rem_vertex!|add_edge!|rem_edge!", code):
        return "graph_surgery"
    return "other"


def detail(a):
    return dict((kv.split("=")[0], int(kv.split("=")[1])) for kv in (a or {}).get("detail", "").split(",") if "=" in kv)


def identity_problems(r, arm, camp_ok, health_ok):
    a = r.get("ablation")
    bad = []
    if not a:
        bad.append("no_ablation_line")
    else:
        if a["level"] != arm: bad.append("level=%s" % a["level"])
        if not a["armed"]: bad.append("armed=false")
        ex = {k.split(":", 1)[1] for k in detail(a) if k.startswith("exempt:")}
        if not ex <= ALLOWED_EXEMPT: bad.append("exempt_sites=%s" % sorted(ex - ALLOWED_EXEMPT))
    if (r.get("run_ctx") or {}).get("repair_ablation") != arm:
        bad.append("run_ctx.repair_ablation=%s" % (r.get("run_ctx") or {}).get("repair_ablation"))
    if not camp_ok: bad.append("campaign.set_env.REPAIR_ABLATION!=arm")
    if not health_ok: bad.append("health.pre.repair_ablation!=arm")
    return bad


# 팔별 서비스 신원·격자별 campaign 신원
health_ok = {a: json.load(open(os.path.join(R, "health_%s.pre.json" % a))).get("repair_ablation") == a for a in ARMS}
S, meta, excluded, denied_list, unscored = {}, {}, [], [], []
for a in ARMS:
    for m in MODELS:
        g = os.path.join(R, "%s-%s" % (a, m))
        camp = json.load(open(os.path.join(g, "campaign.json")))
        sw = json.load(open(os.path.join(g, "sweep.json")))
        camp_ok = camp["set_env"].get("REPAIR_ABLATION") == a
        meta["%s-%s" % (a, m)] = {"campaign_id": camp["campaign_id"], "config_digest": camp["config_digest"],
                                  "code_rev": camp["code_rev"][:8], "set_env.REPAIR_ABLATION": camp["set_env"].get("REPAIR_ABLATION"),
                                  "planned": sw["n_planned"], "scored": sw["n_runs"], "unscored": sw["n_unscored"]}
        unscored += [dict(u, arm=a, model=m) for u in sw["unscored"]]
        for r in sw["runs"]:
            if r["lane"] != "router":
                continue
            k = (m, r["case"], r["seed"])
            bad = identity_problems(r, a, camp_ok, health_ok[a])
            d = detail(r.get("ablation"))
            den = (r.get("ablation") or {}).get("denied", 0)
            r["_valid"] = not bad and den == 0
            r["_bad"] = bad
            r["_d"] = d
            if bad:
                excluded.append({"arm": a, "model": m, "case": r["case"], "seed": r["seed"], "why": bad})
            if den > 0:
                denied_list.append({"arm": a, "model": m, "case": r["case"], "seed": r["seed"], "denied": den,
                                    "complete": r["complete"],
                                    "denied_by": {k2: v for k2, v in d.items() if k2.startswith("denied")}})
            S.setdefault(a, {})[k] = r

orc = {(r["model"], r["case"], r["seed"]): bool(r["complete"])
       for r in json.load(open(os.path.join(R, "g3", "tally.json")))}

rep = {"grids": meta, "health_pre_ok": health_ok}
for m in MODELS:
    for case in CASES:
        keys = sorted(k for k in set().union(*(S[a] for a in ARMS)) if k[0] == m and k[1] == case)
        row = {"n_seen": len(keys)}
        for a in ARMS:
            got = [S[a][k] for k in keys if k in S[a]]
            val = [r for r in got if r["_valid"]]
            row[a] = {
                "scored": len(got), "valid": len(val), "complete": sum(r["complete"] for r in val),
                "identity_fail": sum(1 for r in got if r["_bad"]),
                "denied_runs": sum(1 for r in got if (r.get("ablation") or {}).get("denied", 0) > 0),
                # ladder_zone_* = replace_robot 사다리 + render_demo zone rescue 의 합 → detail 로 가른다
                "zone_rescue_skipped": sum(r["_d"].get("zone_rescue_skipped", 0) for r in got),
                "zone_rescue_fired": sum(r["_d"].get("zone_rescue_fired", 0) for r in got),
                "replace_ladder_skipped": sum(r["_d"].get("ladder_zone_skipped", 0) - r["_d"].get("zone_rescue_skipped", 0) for r in got),
                "replace_ladder_fired": sum(r["_d"].get("ladder_zone_fired", 0) - r["_d"].get("zone_rescue_fired", 0) for r in got),
                "minted": sum(bool(r.get("minted")) for r in got),
                "threw": sum(bool(r.get("threw")) for r in got),
            }
        for a in ARMS[1:]:
            pairs = [k for k in keys if k in S["none"] and k in S[a] and S["none"][k]["_valid"] and S[a][k]["_valid"]]
            b = sum(1 for k in pairs if S["none"][k]["complete"] and not S[a][k]["complete"])
            c = sum(1 for k in pairs if S[a][k]["complete"] and not S["none"][k]["complete"])
            row["none_vs_%s" % a] = {"pairs": len(pairs), "none_only": b, "%s_only" % a: c, "p_mcnemar": mcnemar(b, c)}
            row["zone_place_mismatch_%s" % a] = sum(1 for k in keys if k in S["none"] and k in S[a]
                                                   and S[a][k].get("zone_place") != S["none"][k].get("zone_place"))
        if "translate" in ARMS and "all" in ARMS:          # 보조: A1 vs A2
            pairs = [k for k in keys if k in S["translate"] and k in S["all"] and S["translate"][k]["_valid"] and S["all"][k]["_valid"]]
            b = sum(1 for k in pairs if S["translate"][k]["complete"] and not S["all"][k]["complete"])
            c = sum(1 for k in pairs if S["all"][k]["complete"] and not S["translate"][k]["complete"])
            row["translate_vs_all"] = {"pairs": len(pairs), "translate_only": b, "all_only": c, "p_mcnemar": mcnemar(b, c)}
        feas = [k for k in keys if orc.get(k)]
        row["oracle_feasible_seeds"] = len(feas)
        # G3 오라클은 A2(all) 어휘 오라클이다 — A1 에 대한 조건부 수치는 참고용
        for a in ARMS:
            row["%s_complete_on_feasible" % a] = sum(1 for k in feas if k in S[a] and S[a][k]["_valid"] and S[a][k]["complete"])
            row["%s_valid_on_feasible" % a] = sum(1 for k in feas if k in S[a] and S[a][k]["_valid"])
        # m8 부수 보고: 새 none vs 9/23 오전 117판(같은 시드)
        p = PRIOR % m
        if os.path.isfile(p):
            pr = {(m, r["case"], r["seed"]): r for r in json.load(open(p))["runs"] if r["lane"] == "router"}
            both = [k for k in keys if k in pr and k in S["none"]]
            row["none_vs_0923_sol"] = {"sol_complete": sum(pr[k]["complete"] for k in both),
                                       "none_complete": sum(S["none"][k]["complete"] for k in both), "pairs": len(both),
                                       "none_only": sum(1 for k in both if S["none"][k]["complete"] and not pr[k]["complete"]),
                                       "sol_only": sum(1 for k in both if pr[k]["complete"] and not S["none"][k]["complete"])}
        rep["%s|%s" % (m, case)] = row

tot = {a: {"valid": 0, "complete": 0} for a in ARMS}
for m in MODELS:
    for case in CASES:
        for a in ARMS:
            tot[a]["valid"] += rep["%s|%s" % (m, case)][a]["valid"]
            tot[a]["complete"] += rep["%s|%s" % (m, case)][a]["complete"]
for a in ARMS[1:]:
    b = c = 0
    for m in MODELS:
        for case in CASES:
            x = rep["%s|%s" % (m, case)]["none_vs_%s" % a]; b += x["none_only"]; c += x["%s_only" % a]
    tot["none_vs_%s" % a] = {"none_only": b, "%s_only" % a: c, "p_mcnemar": mcnemar(b, c)}
tot["oracle_feasible_seeds"] = sum(rep["%s|%s" % (m, c)]["oracle_feasible_seeds"] for m in MODELS for c in CASES)
for a in ARMS:
    for f in ("complete_on_feasible", "valid_on_feasible"):
        tot["%s_%s" % (a, f)] = sum(rep["%s|%s" % (m, c)]["%s_%s" % (a, f)] for m in MODELS for c in CASES)
if "translate" in ARMS and "all" in ARMS:
    b = sum(rep["%s|%s" % (m, c)]["translate_vs_all"]["translate_only"] for m in MODELS for c in CASES)
    c2 = sum(rep["%s|%s" % (m, c)]["translate_vs_all"]["all_only"] for m in MODELS for c in CASES)
    tot["translate_vs_all"] = {"translate_only": b, "all_only": c2, "p_mcnemar": mcnemar(b, c2)}
rep["total"] = tot

# body 기전: 원장 행 전부(첫 시도) + 판별 마지막 body(재시도 포함) × 완주
mech, mech_rewrite, mech_by_run, resync = {}, {}, {}, {}
for a in ALL_ARMS:
    p = os.path.join(R, "ledger_%s.jsonl" % a)
    rows = [json.loads(l) for l in open(p)] if os.path.exists(p) else []
    mech[a] = dict(Counter(mechanism(r.get("impl_code") or "") for r in rows if r.get("row_type") != "rewrite"))
    mech_rewrite[a] = dict(Counter(mechanism(r.get("impl_code") or "") for r in rows if r.get("row_type") == "rewrite"))
    last, last_rs = {}, {}
    for r in sorted(rows, key=lambda r: r.get("logged_at") or ""):
        ctx = r.get("run_ctx") or {}
        if (r.get("impl_code") or "").strip():
            mk = "tractor" if "tractor" in str(ctx.get("model")) else "xwing"
            kk = (mk, str(ctx.get("case", "")).replace("router_", ""), ctx.get("seed"))
            last[kk] = mechanism(r["impl_code"])
            last_rs[kk] = "resync_scene_to_schedule!(" in r["impl_code"]
    c = Counter()
    for k, r in S.get(a, {}).items():
        if r["_valid"]:
            c["%s|%s" % (last.get(k, "no_body"), "complete" if r["complete"] else "incomplete")] += 1
    mech_by_run[a] = dict(sorted(c.items()))
    c = Counter()
    for k, r in S.get(a, {}).items():
        if r["_valid"] and k in last_rs:
            c["%s|%s" % ("resync" if last_rs[k] else "no_resync", "complete" if r["complete"] else "incomplete")] += 1
    resync[a] = {"rows_calling_resync": sum(1 for r in rows if "resync_scene_to_schedule!(" in (r.get("impl_code") or "")),
                 "rows_with_body": sum(1 for r in rows if (r.get("impl_code") or "").strip()),
                 "last_body_x_outcome": dict(sorted(c.items()))}
rep["mechanism_first_attempt_rows"] = mech
rep["mechanism_rewrite_rows"] = mech_rewrite
rep["mechanism_last_body_x_outcome"] = mech_by_run
rep["resync_scene_to_schedule"] = resync
rep["held_arms"] = {a: "not run (held by user, STOP file 2026-09-23); ledger rows above = G4 pilot only" for a in HELD}
# G4 파일럿(all-tractor zone s1–4)은 팔 결과가 아니다 — 판별 완주·신원만 참고로 싣는다
import sys
sys.path.insert(0, os.path.join(R, "..", "..", "tools", "monitor"))
from build_sweep_dataset import parse_log  # noqa: E402
pilot = {}
for a in HELD:
    for m in MODELS:
        d = os.path.join(R, "%s-%s" % (a, m), "log")
        for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            mm = re.match(r"router__(\w+)__s(\d+)\.log$", f)
            if not mm:
                continue
            r = parse_log(open(os.path.join(d, f), errors="replace").read(), "router", mm[1], int(mm[2]))
            pilot["%s-%s|%s|s%s" % (a, m, mm[1], mm[2])] = None if r is None else {
                "complete": r["complete"], "closed": r["closed"], "ablation": r["ablation"],
                "run_ctx.repair_ablation": (r["run_ctx"] or {}).get("repair_ablation")}
rep["pilot_only_held_arms"] = pilot
rep["identity_failures"] = excluded
rep["denied_runs"] = denied_list
rep["unscored"] = unscored

print(json.dumps(rep, indent=1, ensure_ascii=False))
json.dump(rep, open(os.path.join(R, "compare3.json"), "w"), indent=1, ensure_ascii=False)
