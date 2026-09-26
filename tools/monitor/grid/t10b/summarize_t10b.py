"""summarize_t10b.py <t10b_root> <out_json> [--md <out_md>] — T10b 재생·fixture·자연 선택 결과를 표로 묶고 게이트를 판정한다.

<t10b_root>/cohort/<key>/episode.json (replay_repair_cohort.jl) · <t10b_root>/fixtures/t10b_fixtures.json
(test/repair_validation_fixtures.jl) · <t10b_root>/natural/<key>/zr/episode.json (natural_tool.jl, production shadow).
게이트(비-0 종료): easy_kept 판마다 NOOP 기준이 COMPLETE 면 선택이 NOOP/baseline_complete 여야 한다(설계 §7.2 첫 줄) ·
drift/anchor 판에서 TOOL 이 골라졌다면 그 후보가 COMPLETE + 검사 통과(eligible)여야 한다 · 모든 판에서 선택 결과가
SelectionReport 불변식과 맞는다(rescued ⟺ tool) · 판이 빠지면(episode.json 없음/driver_error) 실패.
"""
import json, os, sys, glob

root, out = sys.argv[1], sys.argv[2]
md = sys.argv[sys.argv.index("--md") + 1] if "--md" in sys.argv else None
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", "..", "..", ".."))
if not os.path.isdir(os.path.join(REPO, "test")):
    REPO = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
chains = json.load(open(os.path.join(REPO, "test/fixtures/repair_verification/tools/legacy_chains.json")))["episodes"]
b0 = {f"{e['model']}_{e['case']}_s{e['seed']}": e for e in
      json.load(open(os.path.join(REPO, "test/fixtures/repair_verification/b0/b0_episodes.json")))["episodes"]}

def g(d, *ks, default=None):
    for k in ks:
        if not isinstance(d, dict) or k not in d or d[k] is None:
            return default
        d = d[k]
    return d

def branch_row(x):
    if not x:
        return None
    t = x.get("terminal") or {}
    ct = x.get("contract_terminal") or {}
    return {"outcome": x.get("outcome"), "closed": t.get("closed"), "total": t.get("total"), "iter": t.get("iter"),
            "terminal_reason": g(x, "report", "terminal_reason"), "unknown_cause": g(x, "report", "unknown_cause"),
            "other_violations": x.get("other_violations"), "registration_footprint": x.get("registration_footprint"),
            "contract_violations": ct.get("violations"), "contract_unsupported": ct.get("unsupported"),
            "action": x.get("action"), "error": x.get("error")}

problems, eps = [], {}
for key in sorted(chains):
    p = os.path.join(root, "cohort", key, "episode.json")
    if not os.path.isfile(p):
        problems.append(f"{key}: episode.json missing"); continue
    E = json.load(open(p))
    if E.get("driver_error"):
        problems.append(f"{key}: driver_error {E['driver_error'][:200]}")
    sel = g(E, "supervision", "selection") or {}
    gp = E.get("GP") or {}
    j = gp.get("judged") or {}
    noop = E.get("noop") or {}
    row = {"key": key, "group": E["group"], "legacy": E["legacy"], "t0_iter": E.get("t0_iter"),
           "b0_t10a": {"outcome": b0[key]["outcome"], "closed": b0[key]["closed"], "iter": b0[key]["iter"]},
           "noop": {"outcome": g(noop, "report", "outcome"), "closed": g(noop, "terminal", "closed"), "iter": g(noop, "terminal", "iter"),
                    "contract_violations": g(noop, "contract_terminal", "violations")},
           "gaps": g(E, "supervision", "gaps"), "states": [t["to"] for t in g(E, "supervision", "transitions", default=[])],
           "selection": {k: sel.get(k) for k in ("baseline_outcome", "selected", "selected_proposal_id", "classification",
                                                  "raw_regressions", "candidate_outcomes")},
           "GP": {"impl": g(E, "GP_proposal", "impl_name"), "gate": gp.get("gate"), "gate_reasons": gp.get("gate_reasons"),
                  "status": j.get("status"), "exception": j.get("exception"), "engine_steps": j.get("engine_steps"),
                  "effects": j.get("effects"), "effect_reasons": j.get("effect_reasons"), "effect_classes": j.get("effect_classes"),
                  "checks_run": j.get("checks_run"),
                  "harness_resync": [l.get("snapped") and len(l["snapped"]) for l in (j.get("harness_log") or [])
                                     if l.get("action") == "resync_scene_to_schedule!"],
                  "contract_post": j.get("contract_post"), "contract_post_reasons": j.get("contract_post_reasons"),
                  "outcome": j.get("outcome"), "terminal_reason": j.get("terminal_reason"),
                  "closed": g(gp, "terminal", "closed"), "iter": g(gp, "terminal", "iter"),
                  "contract_terminal": j.get("contract_terminal"), "contract_terminal_reasons": j.get("contract_terminal_reasons"),
                  "eligible": j.get("eligible"), "candidate_outcome": gp.get("candidate_outcome"), "reasons": gp.get("reasons")},
           "L0": branch_row(E.get("L0")), "L1": branch_row(E.get("L1")),
           "noop_matches_b0": (g(noop, "report", "outcome") == b0[key]["outcome"] and g(noop, "terminal", "closed") == b0[key]["closed"])}
    # --- 분류 -----------------------------------------------------------------------------
    base = row["selection"]["baseline_outcome"]
    if E["group"] == "easy_kept":
        ok = base == "COMPLETE" and row["selection"]["selected"] == "noop" and row["selection"]["classification"] == "baseline_complete"
        row["easy_preserved"] = ok
        row["raw_regression"] = row["GP"]["candidate_outcome"] in ("FAIL_WITHIN_BUDGET", "REJECTED")
        if base == "COMPLETE" and not ok:
            problems.append(f"{key}: easy_kept baseline COMPLETE but selection {row['selection']}")
        if base != "COMPLETE":
            problems.append(f"{key}: easy_kept but this run's NOOP baseline is {base} (B0 drift inside T10b)")
    else:
        if row["selection"]["selected"] == "tool" and row["GP"]["candidate_outcome"] != "COMPLETE":
            problems.append(f"{key}: TOOL selected but candidate outcome {row['GP']['candidate_outcome']}")
        if E["group"] == "drift":
            row["classification"] = ("historical harm not reproducible under pi0 (drift): B0 FAIL" if base == "FAIL_WITHIN_BUDGET"
                                     else f"B0 {base}")
    if E["group"] == "anchor":
        L0 = row["L0"] or {}
        if L0.get("outcome") == "COMPLETE":
            row["anchor_classification"] = ("historical_complete_but_contract_invalid" if L0.get("contract_violations")
                                            else "historical_complete_contract_valid")
        elif L0.get("outcome") == "FAIL_WITHIN_BUDGET":
            row["anchor_classification"] = "historical_success_not_reproduced_under_L0"
        else:
            row["anchor_classification"] = f"L0_not_replayable ({L0.get('unknown_cause')}: {(L0.get('error') or {}).get('message', '')[:160]})"
    if (row["selection"]["selected"] == "tool") != (row["selection"]["classification"] == "rescued"):
        problems.append(f"{key}: selection invariant broken")
    eps[key] = row

fx = None
fp = os.path.join(root, "fixtures", "t10b_fixtures.json")
if os.path.isfile(fp):
    F = json.load(open(fp))
    fx = {"episode": F["episode"], "parent_terminal": F["parent_terminal"], "N1_vs_parent": F["N1_vs_parent"],
          "host_write_probe_exists": F["host_write_probe_exists"],
          "parent_dir_unchanged": F["parent_dir"]["before"] == F["parent_dir"]["after"],
          "parent_verifies_ok": all((not v.get("mismatched_blocks")) and v.get("counters_equal") and v.get("rng_equal")
                                    for k, v in F["parent_verifies"].items() if k != "resume"),
          "results": {k: {kk: v.get(kk) for kk in ("gate", "gate_reasons", "status", "exception", "effects", "effect_reasons",
                                                   "effect_classes", "checks_run", "contract_post", "outcome", "terminal_reason",
                                                   "contract_terminal", "contract_terminal_reasons", "eligible")}
                      for k, v in F["results"].items() if k != "N1"},
          "N1": {k: F["results"]["N1"].get(k) for k in ("outcome", "terminal_reason", "sim_steps")}}

nat = {}
for p in sorted(glob.glob(os.path.join(root, "natural", "*", "zr", "episode.json"))):
    key = p.split(os.sep)[-3]
    N = json.load(open(p))
    sup = N.get("supervision") or {}
    nat[key] = {"exit_code": N.get("exit_code"), "certification": N.get("certification"),
                "states": [t["to"] for t in sup.get("transitions", [])], "gaps": sup.get("gaps"),
                "selection": sup.get("selection"), "baseline": g(sup, "baseline", "outcome"),
                "candidates": {k: {kk: v.get(kk) for kk in ("outcome", "eligible", "reasons")} for k, v in (sup.get("candidates") or {}).items()},
                "replay": sup.get("replay"), "active_world": g(N, "active_world", "kind")}

grp = lambda gname: [r for r in eps.values() if r["group"] == gname]
summary = {"schema": "zrv-t10b-summary/1", "problems": problems,
           "counts": {gname: len(grp(gname)) for gname in ("anchor", "drift", "easy_kept")},
           "easy_preserved": sum(1 for r in grp("easy_kept") if r.get("easy_preserved")),
           "easy_raw_regressions": sorted(r["key"] for r in grp("easy_kept") if r.get("raw_regression")),
           "noop_matches_b0": sum(1 for r in eps.values() if r["noop_matches_b0"]),
           "episodes": eps, "fixtures": fx, "natural": nat}
json.dump(summary, open(out, "w"), indent=1, sort_keys=True)

if md:
    L = []
    c = lambda r, arm: (r[arm] or {}) if r.get(arm) else {}
    def cv(v): return "0" if not v else f"{len(v)}: " + "; ".join(v[:2])[:140]
    L.append("## Anchor\n\n| key | 역사 A2 | B0(T10a) | NOOP(이 런) | L0 | L0 계약 | L1 | L1 계약 | GP 집행/효과/계약post | GP rollout | GP 계약 terminal | eligible | 선택 | 판정 |\n|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in grp("anchor"):
        L0, L1, G = c(r, "L0"), c(r, "L1"), r["GP"]
        L.append(f"| {r['key']} | {r['legacy']['historical_a2_status']} {r['legacy']['historical_a2_closed']} | {r['b0_t10a']['outcome']} {r['b0_t10a']['closed']} | "
                 f"{r['noop']['outcome']} {r['noop']['closed']} | {L0.get('outcome')} {L0.get('closed')} | {cv(L0.get('contract_violations'))} | "
                 f"{L1.get('outcome')} {L1.get('closed')} | {cv(L1.get('contract_violations'))} | {G['status']}/{G['effects']}/{G['contract_post']} | "
                 f"{G['outcome']} {G['closed']} | {G['contract_terminal']} {cv(G['contract_terminal_reasons'])} | {G['eligible']} | "
                 f"{r['selection']['selected']}/{r['selection']['classification']} | {r.get('anchor_classification')} |")
    for gname, title in (("drift", "13-drift (역사 A2 regression = 새 B0 easy_lost)"), ("easy_kept", "easy-14 보존 (B0 COMPLETE)")):
        L.append(f"\n## {title}\n\n| key | B0(T10a) | NOOP(이 런) | GP 집행/효과/계약post | GP rollout | GP 계약 terminal | 후보 결과 | 선택 | raw regression | L0 | L1 |\n|---|---|---|---|---|---|---|---|---|---|---|")
        for r in grp(gname):
            G = r["GP"]; L0, L1 = c(r, "L0"), c(r, "L1")
            L.append(f"| {r['key']} | {r['b0_t10a']['outcome']} {r['b0_t10a']['closed']} | {r['noop']['outcome']} {r['noop']['closed']} | "
                     f"{G['status']}/{G['effects']}/{G['contract_post']} | {G['outcome']} {G['closed']} | {G['contract_terminal']} {cv(G['contract_terminal_reasons'])} | "
                     f"{G['candidate_outcome']} | {r['selection']['selected']}/{r['selection']['classification']} | {r.get('raw_regression', '-')} | "
                     f"{L0.get('outcome', '-')} {L0.get('closed', '')} | {L1.get('outcome', '-')} {L1.get('closed', '')} |")
    L.append(f"\n**problems**: {problems or 'none'}\n")
    open(md, "w").write("\n".join(L) + "\n")
print(json.dumps({k: summary[k] for k in ("counts", "easy_preserved", "easy_raw_regressions", "noop_matches_b0", "problems")}, indent=1))
sys.exit(1 if problems else 0)
