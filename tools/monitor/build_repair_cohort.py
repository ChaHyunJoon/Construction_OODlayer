#!/usr/bin/env python3
"""역사적 존 복구 코호트와 실제 집행 body 사슬 고정 (zone-repair-verification T0, spec §3.2 · §9.1 · §10 게이트 1).

canonical(9/23 무료 기준선, `results/2026-09-23-baseline-free-{tractor,xwing}`)과 A2(`all` 팔,
`results/2026-09-23-repair-ablation/all-{tractor,xwing}`)를 `(model, case, seed, zone_seed)` 로 join 해
easy/hard · A2 easy-success/regression/rescue membership 을 뽑고, A2 의 존 결정마다 **실제로 집행된**
body 사슬을 스트림 `respec_history[].attempts` ↔ 원장(`ledger_all.final.jsonl`)의 `record_id` /
`parent_record_id` 로 잇는다. 🔴 "함수명이 맞는 마지막 원장 행" 을 집행 body 로 쓰지 않는다
(compare3.py `mechanism_last_body_x_outcome` 가 그 방식이다 — 여기선 쓰지 않는다).

집행 판정 규칙(정본: tools/monitor/enact.jl `_open_attempt!` · `_rewrite_retry!` docstring):
  · 첫 시도(decide) body: attempts 없음 → `steps` 가 있으면 집행 · trigger threw/noop → 집행(prev_steps) ·
    trigger register_reject/prerun → 집행 전 거절(미집행).
  · 재작성(attempt 2): roundtrip=="ok" ∧ install_why is None ∧ (steps 있음 ∨ steps_ref=="respec.steps") → 집행.
  · 두 body 가 **같은 세계에 차례로** 집행된 판(retried/noop_retried)은 첫 body 의 변경이 남은 채 둘째가 돈다.

입력은 results/ 아래(gitignore — 디스크에만 있다)이고 출력은 커밋되는 fixture 다:
  test/fixtures/repair_verification/cohort.json
  test/fixtures/repair_verification/legacy/<model>_<case>_s<seed>/{manifest.json, NN_<role>.jl}
  test/fixtures/repair_verification/legacy/source_snapshots/baseline-free/{snapshot.json,tree.patch,untracked_sources.tar}

사용: python3 tools/monitor/build_repair_cohort.py            # 쓰기 + 수 검사(어긋나면 exit 1)
      python3 tools/monitor/build_repair_cohort.py --verify-restore   # 임시 clone 두 개로 소스 복원 digest 재확인
결정적이다: 시각·절대경로를 출력에 넣지 않고 키를 정렬한다.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
RES = os.path.join(ROOT, "results")
ABL = os.path.join(RES, "2026-09-23-repair-ablation")
OUT = os.path.join(ROOT, "test", "fixtures", "repair_verification")
MODELS = ("tractor", "xwing")
CASES = ("zone", "all3")
BASE_GRID = "2026-09-23-baseline-free-%s"
A2_GRID = "all-%s"
LEDGER = os.path.join(ABL, "ledger_all.final.jsonl")
CTX_MODEL = {"tractor": "tractor", "30051_1_X_wing_Fighter_Mini": "xwing"}   # 원장 run_ctx.model → 격자 이름
ANCHORS = (("tractor", "all3", 2), ("tractor", "zone", 5), ("tractor", "zone", 16), ("xwing", "zone", 4))
EXPECT = {"easy": 27, "hard": 93, "a2_easy_success": 14, "a2_regression": 13, "a2_rescue": 4}

# 정적 호출 스캔(코드 텍스트 — 실행 여부가 아니다). 이름은 spec §6·§10 금지/필수 목록에서 왔다.
STATIC = {
    "set_desired_global_transform!": r"set_desired_global_transform!\(",
    "resync_scene_to_schedule!": r"resync_scene_to_schedule!\(",
    "reset_cache_resume!": r"reset_cache_resume!\(",
    "update_planning_cache!": r"update_planning_cache!\(",
    "preprocess_env!": r"preprocess_env!\(",
    "step_call": r"\bstep_environment!\(|\bstep!\(|\bsimulate!\(",
    "graph_edit": r"\b(?:add_edge!|rem_edge!|rem_vertex!|add_vertex!|add_node!)\(",
    "closed_active_write": r"\b(?:closed_set|active_set)\b\s*(?:\[|=|\))|push!\(\s*env\.cache\.(?:closed|active)_set",
    "validate_schedule_transform_tree": r"validate_schedule_transform_tree\(",
}

# 앵커 수동 감사 — 코드 정독 + 로그/스트림에서 나온 사실과 가설을 가른다. T5 계약·T10 재생이 판정한다.
ANCHOR_AUDIT = {
    "tractor|all3|s2": {
        "effective_body": "01_decide (가설): 두 body 가 거의 같고(첫째 active_restriction_zones · 둘째 "
                          "restriction_zones), 첫째가 이미 막힌 goal 을 옮겼다면 둘째는 report.blocked 가 비어 "
                          "곧장 :success. `enact_noop` 판정은 6축(closed/active/edges/binding/weights/staging)만 "
                          "잰 것이라 transform 변경을 못 본다.",
        "setter_targets": "blocked nav 노드의 goal_config (블록 목록 = zone_blockage(check_paths=true) — 로그: "
                          "transport vtx=88, nav_blocked=2). 후보 순서: 그 노드의 start_config 전역 자세 → "
                          "agent_policies 의 각 로봇 씬 노드 자세. 첫 후보가 막힘을 풀면 채택.",
        "transform": "goal := start (첫 후보) 또는 goal := 어떤 로봇의 현재 자세. 평행이동이 아니라 자세 통째 대입.",
        "resync": "호출 없음", "cache": "body 안 없음(하네스가 resume=issued 로 reset_cache_resume! 1회)",
        "step_calls": "없음",
        "assembly_semantics": "🔴 의심: TransportUnitGo.goal_config 는 DepositCargo.start_config 의 자식이다"
                              "(construction_schedule.jl populate_schedule_build_step!). goal=start 면 운반 "
                              "이동이 사라지고 하역 자세와 불일치할 수 있다 — spec §10 게이트 5 의 'goal=start "
                              "허위 complete' 후보. 스트림에 부품 최종 자세가 없어 여기서 판정 불가.",
        "contract_status": "unverified_suspect",
    },
    "tractor|zone|s5": {
        "effective_body": "01_decide: 첫째가 :success 로 끝났고(6축 무변화 → noop 되먹임), 둘째(rewrite)는 "
                          "'no unfinished blocked navigation node was found' 로 **던졌다** — 첫째가 이미 막힘을 "
                          "풀었다는 뜻. 마지막 원장 행(rewrite)을 집행 body 로 읽으면 틀린다.",
        "setter_targets": "blocked RobotGo/TransportUnitGo 하나의 goal_config + zone_blocked_assemblies(env) "
                          "의 씬 노드 전부.",
        "transform": "goal := 후보 자세(첫 후보 = 그 노드의 start_config, 이어 미완 nav 노드들의 start), "
                     "영향 조립체는 rigid_delta = candidate ∘ inv(original_goal) 로 강체 이동.",
        "resync": "호출 없음(첫째). 둘째에도 없음", "cache": "첫째 body 없음; 둘째 body 의 "
                  "reset_cache_resume!·update_planning_cache! 는 throw 앞이라 미도달",
        "step_calls": "없음",
        "assembly_semantics": "🔴 의심: goal=start 패턴 + 조립체 씬 노드 강체 이동 — 조립체 설치 위치가 "
                              "바뀌었을 수 있다(원래 build 좌표 보존 여부 미확인).",
        "contract_status": "unverified_suspect",
    },
    "tractor|zone|s16": {
        "effective_body": "01_decide 의 **부분 실행 + 되돌리기**: 첫째가 setter 들을 적용한 뒤 "
                          "validate_schedule_transform_tree 실패로 옛 전역 자세를 다시 setter 로 넣고 throw. "
                          "둘째는 'no unfinished blocked transport navigation goal found' 로 던졌다 — 첫째의 "
                          "'되돌리기' 뒤에 막힘이 이미 없었다. 두 body 모두 throw 인데 판은 complete.",
        "setter_targets": "막힌 TransportUnitGo 의 goal_config + 같은 운반유닛의 DepositCargo config·"
                          "cargo_goal_config + 화물의 LiftIntoPlace start/goal + 화물 ObjectStart/"
                          "AssemblyStart/AssemblyComplete config.",
        "transform": "Translation(displacement), displacement = 존 중심 둘레 8겹×96점 링 탐색으로 고른 점 − 옛 goal.",
        "resync": "호출 없음", "cache": "body 안 없음(하네스 resume=issued)",
        "step_calls": "없음",
        "assembly_semantics": "🔴 정적 유도(재생 미검증): set_desired_global_transform! 은 부모 기준 local 을 "
                              "쓰고 자식은 local 을 유지한다(hierarchical_geom_essentials.jl). configs[1] = "
                              "TUGo.goal_config 이고 그 부모 DepositCargo.config 가 뒤에 온다(construction_schedule.jl "
                              "populate_schedule_build_step! 의 set_parent!). 그러면 전진 패스에서 자식은 +2Δ, "
                              "같은 순서의 '되돌리기' 뒤엔 −Δ 에 남는다 — 되돌리기가 항등이 아니어서 운반 목표가 "
                              "반대쪽으로 옮겨진 채 판이 완주했을 수 있다(둘째 body 가 막힌 목표를 못 찾은 것과 합치). "
                              "LiftIntoPlace start/goal·AssemblyComplete 도 목록에 있어 조립 슬롯 변경 후보. "
                              "T10 재생으로 판정.",
        "contract_status": "unverified_suspect",
    },
    "xwing|zone|s4": {
        "effective_body": "02_rewrite: 첫째는 본문 첫 줄에서 error — 세계 변경 없음. 둘째가 :success.",
        "setter_targets": "zone_blockage(check_paths=true) 의 status==:engulfed 인 막힌 노드마다 goal_config.",
        "transform": "goal := start_config 전역 자세(goal=start 패턴).",
        "resync": "resync_scene_to_schedule!(env) 호출(setter 뒤)",
        "cache": "reset_cache_resume!(env.cache, env.sched) · preprocess_env!(env) 호출",
        "step_calls": "🔴 step_environment!(env) 1회 — body 가 시뮬레이션을 직접 한 걸음 민다(spec §6 금지 항목; "
                      "L1 resync 삽입 위치 명시 대상)",
        "assembly_semantics": "🔴 의심: goal=start 패턴(허위 complete 후보). 또 이 판은 canonical 과 init_fp 가 "
                              "다르다(첫 프레임 로봇 위치가 다름) — 같은 세계라고 할 수 없다.",
        "contract_status": "unverified_suspect",
    },
}


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def sha(s):
    return None if s is None else hashlib.sha256(s.encode()).hexdigest()


def rel(p):
    return os.path.relpath(p, ROOT)


def last_line(p):
    last = None
    with open(p) as f:
        for last in f:
            pass
    return json.loads(last)


def key(m, case, seed, zs):
    return "%s|%s|s%d|z%d" % (m, case, seed, zs)


def decisions(r):
    return [{k: d.get(k) for k in ("at", "event", "chosen", "enacted")} for d in (r.get("decisions") or [])]


def load_grid(grid, lane, inputs):
    """sweep.json(채점) + unscored + missing + jobs.jsonl(zone_seed) → {(m,case,seed): row}."""
    sw_p = os.path.join(grid, "sweep.json")
    inputs[rel(sw_p)] = sha256_file(sw_p)
    sw = json.load(open(sw_p))
    jobs = {}
    for l in open(os.path.join(grid, "jobs.jsonl")):
        j = json.loads(l)
        if j["lane"] == lane and j["case"] in CASES:
            jobs[(j["case"], j["seed"])] = j
    camp = json.load(open(os.path.join(grid, "campaign.json")))
    out = {}
    for r in sw["runs"]:
        if r["lane"] != lane or r["case"] not in CASES:
            continue
        out[(r["case"], r["seed"])] = dict(r, _status="complete" if r["complete"] else "incomplete")
    for u in sw["unscored"]:
        if u["lane"] == lane and u["case"] in CASES:
            out[(u["case"], u["seed"])] = dict(u, _status=u["status"])     # timeout 등 — 미관측
    for m in sw["missing"]:
        if m.get("lane") == lane and m.get("case") in CASES:
            out[(m["case"], m["seed"])] = dict(m, _status="missing")
    for (case, seed), j in jobs.items():
        out.setdefault((case, seed), {"case": case, "seed": seed, "_status": "missing"})
        out[(case, seed)]["_zone_seed"] = j["zone_seed"]
    fp = {k: camp[k] for k in ("campaign_id", "code_rev", "code_dirty_digest", "config_digest")}
    fp["versions"] = camp.get("versions")
    return out, fp, camp


def run_summary(r):
    s = {"status": r["_status"], "closed": r.get("closed"), "fail_mode": r.get("fail_mode"),
         "stop_sig": r.get("stop_sig"), "rc": r.get("rc"), "elapsed": r.get("elapsed"),
         "n_blocked": r.get("n_blocked"), "project_blocked": r.get("project_blocked"),
         "zone_place": r.get("zone_place"), "init_fp": r.get("init_fp"), "ood_fp": r.get("ood_fp"),
         "decisions": decisions(r)}
    ctx = r.get("run_ctx") or {}
    s["run_fp"] = {k: ctx.get(k) for k in ("code_rev", "code_dirty_digest", "config_digest")} if ctx else None
    return s


def static_calls(code):
    return {n: len(re.findall(p, code)) for n, p in STATIC.items()} if code else None


def body_chain(stream_p, ledger):
    """스트림 마지막 프레임의 존 결정 → 집행 사슬. 원장과 record_id·parent·code 를 대조한다."""
    H = [h for h in last_line(stream_p)["respec_history"]
         if ((h.get("input") or {}).get("policies") or {}).get("dspy", {}) and
         h["input"]["policies"]["dspy"].get("record_id")]
    assert len(H) == 1, "%s: dspy 존 결정 %d 개" % (stream_p, len(H))
    h = H[0]
    p = h["input"]["policies"]["dspy"]
    atts = h.get("attempts") or []
    problems = []
    dec = ledger.get(p["record_id"])
    if dec is None or dec["row_type"] != "decide":
        problems.append("decide record_id %s not a ledger decide row" % p["record_id"])
    dec_code = (dec or {}).get("impl_code") or None
    if p.get("impl_code") and p["impl_code"] != dec_code:
        problems.append("decide impl_code stream != ledger")
    trig = atts[0]["trigger"] if atts else None
    dec_exec = bool(h.get("steps")) if not atts else trig in ("threw", "noop")
    chain = [{"n": 1, "role": "decide", "record_id": p["record_id"], "parent_record_id": None,
              "ledger_row_type": (dec or {}).get("row_type"), "impl_name": (dec or {}).get("impl_name"),
              "code_sha256": sha(dec_code), "executed": dec_exec,
              "executed_basis": ("attempts=[] ∧ steps" if not atts else "attempts[0].trigger=%s" % trig),
              "steps": (h.get("steps") if not atts else atts[0].get("prev_steps")),
              "decide_error": (dec or {}).get("decide_error"), "_code": dec_code}]
    for i, a in enumerate(atts, start=2):
        row = ledger.get(a["record_id"]) if a.get("record_id") else None
        if a.get("record_id") and (row is None or row["row_type"] != "rewrite"):
            problems.append("attempt record_id %s not a ledger rewrite row" % a["record_id"])
        if row is not None and row.get("parent_record_id") != a.get("parent_record_id"):
            problems.append("attempt parent mismatch stream/ledger")
        if a.get("parent_record_id") != p["record_id"]:
            problems.append("attempt parent_record_id != decide record_id")
        if row is not None and (row.get("impl_code") or None) != (a.get("impl_code") or None):
            problems.append("rewrite impl_code stream != ledger")
        ex = a.get("roundtrip") == "ok" and a.get("install_why") is None and \
            (a.get("steps") is not None or a.get("steps_ref") == "respec.steps")
        chain.append({"n": i, "role": "rewrite", "record_id": a.get("record_id"),
                      "parent_record_id": a.get("parent_record_id"), "attempt": a.get("attempt"),
                      "trigger": a.get("trigger"), "why": a.get("why"), "roundtrip": a.get("roundtrip"),
                      "install_why": a.get("install_why"),
                      "ledger_row_type": (row or {}).get("row_type"),
                      "impl_name": a.get("impl_name"), "code_sha256": sha(a.get("impl_code")),
                      "executed": ex, "executed_basis": "roundtrip=%s install_why=%s steps_ref=%s" % (
                          a.get("roundtrip"), a.get("install_why") is None and "None" or "set",
                          a.get("steps_ref")),
                      "steps": a.get("steps") if a.get("steps") is not None else
                      (h.get("steps") if a.get("steps_ref") == "respec.steps" else None),
                      "_code": a.get("impl_code")})
    for c in chain:
        c["static_calls"] = static_calls(c["_code"])
    return {"zone_at": h.get("at"), "enact_retry": h.get("enact_retry"), "final_steps": h.get("steps"),
            "world_delta": h.get("world_delta"), "interface_calls": h.get("interface_calls"),
            "n_executed_bodies": sum(c["executed"] for c in chain), "chain": chain,
            "link_problems": problems}


def ledger_only_chain(m, case, seed, rows):
    """스트림이 없는 판(시한초과): 원장만으로 사슬 — 집행 여부는 미관측."""
    mine = [r for r in rows if CTX_MODEL.get((r.get("run_ctx") or {}).get("model")) == m and
            (r.get("run_ctx") or {}).get("case") == "router_" + case and (r.get("run_ctx") or {}).get("seed") == seed]
    out = []
    for r in sorted(mine, key=lambda r: (r["row_type"] != "decide", r.get("attempt") or 0)):
        out.append({"role": r["row_type"], "record_id": r["record_id"], "parent_record_id": r["parent_record_id"],
                    "impl_name": r.get("impl_name"), "code_sha256": sha(r.get("impl_code") or None),
                    "executed": None, "executed_basis": "stream empty (killed) — unobserved"})
    return {"chain": out, "n_executed_bodies": None, "link_problems": []}


def build():
    inputs = {}
    rows = [json.loads(l) for l in open(LEDGER)]
    inputs[rel(LEDGER)] = sha256_file(LEDGER)
    ledger = {r["record_id"]: r for r in rows}
    assert len(ledger) == len(rows), "duplicate record_id in ledger"
    overload = {(CTX_MODEL[r["run_ctx"]["model"]], r["run_ctx"]["case"].replace("router_", ""), r["run_ctx"]["seed"])
                for r in rows if "overloaded" in str(r.get("decide_error") or r.get("error") or "")}
    campaigns, runs, bodies = {}, [], {}
    for m in MODELS:
        bg = os.path.join(RES, BASE_GRID % m)
        ag = os.path.join(ABL, A2_GRID % m)
        B, bfp, _ = load_grid(bg, "canonical", inputs)
        A, afp, acamp = load_grid(ag, "router", inputs)
        assert acamp["set_env"].get("REPAIR_ABLATION") == "all", "A2 grid is not the all arm"
        snap = os.path.join(bg, "snapshot", "snapshot.json")
        bfp["snapshot"] = json.load(open(snap)) if os.path.exists(snap) else None
        campaigns["canonical|" + m] = dict(bfp, grid=rel(bg), lane="canonical")
        campaigns["a2|" + m] = dict(afp, grid=rel(ag), lane="router", repair_ablation="all", snapshot=None)
        for (case, seed) in sorted(set(B) | set(A)):
            b, a = B.get((case, seed)), A.get((case, seed))
            assert b is not None and a is not None, (m, case, seed)
            zs = b["_zone_seed"]
            assert a["_zone_seed"] == zs, "zone_seed mismatch %s" % ((m, case, seed),)
            k = key(m, case, seed, zs)
            cs, as_ = b["_status"], a["_status"]
            cls = ("easy" if cs == "complete" else "hard") if cs in ("complete", "incomplete") else "canonical_" + cs
            sub = None
            if cls == "easy":
                sub = "a2_easy_success" if as_ == "complete" else "a2_regression"
            elif cls == "hard":
                sub = "a2_rescue" if as_ == "complete" else ("a2_hard_fail" if as_ == "incomplete" else "a2_hard_unobserved")
            bs, asum = run_summary(b), run_summary(a)
            flags = []
            if as_ not in ("complete", "incomplete"):
                flags.append("a2_" + as_)
            if (m, case, seed) in overload:
                flags.append("a2_provider_overload")
            prefix = None
            if as_ in ("complete", "incomplete"):
                za = [d["at"] for d in bs["decisions"] if d["event"] == "ZONE"]
                zb = [d["at"] for d in asum["decisions"] if d["event"] == "ZONE"]
                prefix = {"zone_place": bs["zone_place"] == asum["zone_place"], "zone_at": za == zb,
                          "init_fp": bs["init_fp"] == asum["init_fp"], "ood_fp": bs["ood_fp"] == asum["ood_fp"]}
                for f, ok in sorted(prefix.items()):
                    if not ok:
                        flags.append("prefix_differs:" + f)
            if case == "all3":
                flags.append("all3_nonzone_policy_differs:canonical_vs_surrogate")
            # A2 사슬
            if as_ in ("complete", "incomplete"):
                sp = os.path.join(ag, a["stream"])
                inputs[rel(sp)] = sha256_file(sp)
                ch = body_chain(sp, ledger)
            else:
                ch = ledger_only_chain(m, case, seed, rows)
            if ch["link_problems"]:
                flags.append("chain_link_problem")
            bodies[k] = ch
            runs.append({"key": k, "model": m, "case": case, "seed": seed, "zone_seed": zs,
                         "class": cls, "a2_class": sub, "flags": sorted(flags),
                         "canonical": bs, "a2": asum,
                         "a2_chain": [{x: c.get(x) for x in ("n", "role", "record_id", "parent_record_id",
                                                             "trigger", "executed", "code_sha256", "impl_name")}
                                      for c in ch["chain"]],
                         "a2_enact_retry": ch.get("enact_retry"),
                         "a2_n_executed_bodies": ch["n_executed_bodies"],
                         "prefix_match": prefix})
    runs.sort(key=lambda r: r["key"])
    member = {c: [r["key"] for r in runs if r["class"] == c] for c in ("easy", "hard")}
    for c in ("a2_easy_success", "a2_regression", "a2_rescue", "a2_hard_fail", "a2_hard_unobserved"):
        member[c] = [r["key"] for r in runs if r["a2_class"] == c]
    member["anchors"] = sorted(key(m, c, s, s) for m, c, s in ANCHORS)
    counts = {c: len(v) for c, v in member.items()}
    cohort = {
        "spec": "docs/superpowers/specs/2026-09-24-zone-repair-verification-design.md §3.2 §9.1 §10-1",
        "generator": "tools/monitor/build_repair_cohort.py",
        "definitions": {
            "easy": "canonical(bfree, lane=canonical) complete", "hard": "canonical not complete",
            "a2_easy_success": "easy ∧ A2(all arm, router) complete",
            "a2_regression": "easy ∧ A2 not complete (incomplete|timeout|missing — a2.status 로 가른다)",
            "a2_rescue": "hard ∧ A2 complete", "a2_hard_unobserved": "hard ∧ A2 timeout/missing (분모에서 빼지 않는다)",
            "join_key": "(model, case, seed, zone_seed)",
        },
        "expected_counts": EXPECT, "counts": counts, "membership": member,
        "campaigns": campaigns, "inputs_sha256": dict(sorted(inputs.items())),
        "a2_service": {"code_fingerprint": sorted({r["code_fingerprint"] for r in rows}),
                       "ledger_rows": len(rows)},
        "runs": runs,
    }
    return cohort, bodies


def write(cohort, bodies):
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "cohort.json"), "w") as f:
        json.dump(cohort, f, indent=1, ensure_ascii=False, sort_keys=True)
        f.write("\n")
    leg = os.path.join(OUT, "legacy")
    keep = set(cohort["membership"]["easy"]) | set(cohort["membership"]["a2_rescue"])
    byk = {r["key"]: r for r in cohort["runs"]}
    for k in sorted(keep):
        r = byk[k]
        d = os.path.join(leg, "%s_%s_s%d" % (r["model"], r["case"], r["seed"]))
        if os.path.isdir(d):
            shutil.rmtree(d)
        os.makedirs(d)
        ch = bodies[k]
        files = []
        for c in ch["chain"]:
            if c.get("_code"):
                fn = "%02d_%s.jl" % (c["n"], c["role"])
                with open(os.path.join(d, fn), "w") as f:
                    f.write(c["_code"])          # 바이트 그대로 — code_sha256 이 이 파일의 sha256 이다
                files.append(fn)
        anc = "%s|%s|s%d" % (r["model"], r["case"], r["seed"])
        man = {"key": k, "class": r["class"], "a2_class": r["a2_class"], "flags": r["flags"],
               "anchor": anc in ANCHOR_AUDIT, "audit": ANCHOR_AUDIT.get(anc),
               "canonical": {x: r["canonical"][x] for x in ("status", "closed", "run_fp", "decisions")},
               "a2": {x: r["a2"][x] for x in ("status", "closed", "run_fp", "decisions", "fail_mode",
                                                "n_blocked", "project_blocked")},
               "chain": {x: ch.get(x) for x in ("zone_at", "enact_retry", "final_steps", "world_delta",
                                                  "interface_calls", "n_executed_bodies", "link_problems")},
               "bodies": [dict({x: v for x, v in c.items() if x != "_code"},
                               file=("%02d_%s.jl" % (c["n"], c["role"])) if c.get("_code") else None)
                          for c in ch["chain"]],
               "provenance": {"source": "stream respec_history[].attempts ⋈ %s by record_id" % rel(LEDGER),
                              "a2_campaign": cohort["campaigns"]["a2|" + r["model"]]["campaign_id"],
                              "a2_code": "git %s + untracked (see legacy/source_snapshots)"
                                         % cohort["campaigns"]["a2|" + r["model"]]["code_rev"][:8]},
               "files": files}
        with open(os.path.join(d, "manifest.json"), "w") as f:
            json.dump(man, f, indent=1, ensure_ascii=False, sort_keys=True)
            f.write("\n")
    sd = os.path.join(leg, "source_snapshots", "baseline-free")
    os.makedirs(sd, exist_ok=True)
    src = os.path.join(RES, BASE_GRID % "tractor", "snapshot")
    for n in ("snapshot.json", "tree.patch", "untracked_sources.tar"):
        shutil.copyfile(os.path.join(src, n), os.path.join(sd, n))


def check(cohort):
    c, mem = cohort["counts"], cohort["membership"]
    bad = ["%s: expected %d, derived %d" % (k, v, c.get(k, 0)) for k, v in EXPECT.items() if c.get(k) != v]
    if sorted(mem["a2_rescue"]) != sorted(mem["anchors"]):
        bad.append("rescue set %s != anchors %s" % (mem["a2_rescue"], mem["anchors"]))
    if len(cohort["runs"]) != 120:
        bad.append("planned runs %d != 120" % len(cohort["runs"]))
    probs = [r["key"] for r in cohort["runs"] if "chain_link_problem" in r["flags"]]
    if probs:
        bad.append("chain link problems: %s" % probs)
    return bad


def verify_restore():
    """임시 clone 두 개: (1) bfree = e326b43d + tree.patch + tar (2) A2 = 13d18a19 + 같은 tar. digest 대조."""
    sys.path.insert(0, os.path.join(HERE, "grid"))
    import campaign as C  # noqa: E402  — tree_digest 는 policy.jl `_code_dirty_digest` 의 파이썬 판
    sd = os.path.join(OUT, "legacy", "source_snapshots", "baseline-free")
    snap = json.load(open(os.path.join(sd, "snapshot.json")))
    coh = json.load(open(os.path.join(OUT, "cohort.json")))
    ok = True
    for name, rev, patch, want in (
            ("baseline-free", snap["head"], os.path.join(sd, "tree.patch"),
             coh["campaigns"]["canonical|tractor"]["code_dirty_digest"]),
            ("a2-all", coh["campaigns"]["a2|tractor"]["code_rev"], None,
             coh["campaigns"]["a2|tractor"]["code_dirty_digest"])):
        with tempfile.TemporaryDirectory() as tmp:
            cl = os.path.join(tmp, "c")
            subprocess.run(["git", "clone", "-q", "--shared", "--no-checkout", ROOT, cl], check=True)
            # 🔴 campaign.py cmd_snapshot 은 `checkout --detach` 를 capture_output 으로 삼킨다 — 원 레포 HEAD 가
            #    rev 에서 움직인 뒤엔 그 detach 가 조용히 실패해 HEAD 가 브랜치 끝에 남고 digest 가 틀린다.
            #    clone 안에서 HEAD 를 rev 로 옮긴다(`reset --soft`, clone 의 브랜치만 바뀐다).
            subprocess.run(["git", "-C", cl, "reset", "-q", "--soft", rev], check=True)
            subprocess.run(["git", "-C", cl, "checkout", "-q", rev, "--", *C.FP_PATHS, ".gitignore"], check=True)
            if patch:
                subprocess.run(["git", "-C", cl, "apply", "--binary", patch], check=True)
            subprocess.run(["tar", "-xf", os.path.join(sd, "untracked_sources.tar"), "-C", cl], check=True)
            got = C.tree_digest(cl)
        print("[restore] %s rev=%s digest=%s want=%s %s" % (name, rev[:8], got, want, "OK" if got == want else "MISMATCH"))
        ok &= got == want
    return ok


if __name__ == "__main__":
    if "--verify-restore" in sys.argv:
        sys.exit(0 if verify_restore() else 1)
    coh, bod = build()
    write(coh, bod)
    print(json.dumps(coh["counts"], sort_keys=True))
    bad = check(coh)
    for b in bad:
        print("[cohort] MISMATCH " + b)
    sys.exit(1 if bad else 0)
