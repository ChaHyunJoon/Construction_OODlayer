"""extract_legacy_chains.py [ledger] — T10b: 역사적 A2 집행 사슬을 재생 입력으로 고정한다.

입력: T0 fixture `test/fixtures/repair_verification/legacy/<key>/`(manifest.json + 집행 body 원문, 바이트 그대로) ·
A2 원장(`results/2026-09-23-repair-ablation/ledger_all.final.jsonl`, gitignore — 이 머신에만 있다) · T10a
`b0/b0_episodes.json`(동시대 B0 결과·drift).
출력: `test/fixtures/repair_verification/tools/legacy_chains.json` — 판마다 **집행된 body 만** 순서대로
(`executed == true`, T0 판정 규칙), body 마다 원장 행에서 surface·reversible·params·calls(등록·집행에 들어간 값).
body 원문은 여기 싣지 않는다(파일 경로 + sha256 — 재생기가 원문 파일을 읽고 digest 를 다시 잰다).
원장 impl_code 의 sha256 == 원문 파일 sha256 == manifest code_sha256 이 아니면 exit 1.
"""
import hashlib, json, os, sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
FX = os.path.join(ROOT, "test", "fixtures", "repair_verification")
LEDGER = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "results", "2026-09-23-repair-ablation", "ledger_all.final.jsonl")
sha = lambda b: hashlib.sha256(b).hexdigest()

rows = {}
for line in open(LEDGER):
    r = json.loads(line)
    rows[r.get("record_id")] = r
b0 = {(e["model"], e["case"], e["seed"]): e for e in json.load(open(os.path.join(FX, "b0", "b0_episodes.json")))["episodes"]}

out, bad = {}, []
for key in sorted(os.listdir(os.path.join(FX, "legacy"))):
    d = os.path.join(FX, "legacy", key)
    mp = os.path.join(d, "manifest.json")
    if not os.path.isfile(mp):
        continue
    m = json.load(open(mp))
    model, case, s = key.split("_")
    e = b0[(model, case, int(s[1:]))]
    group = "anchor" if m.get("anchor") else {"easy_kept": "easy_kept", "easy_lost": "drift"}.get(e["drift"], e["drift"])
    bodies = []
    for b in m["bodies"]:
        if b.get("executed") is not True:
            continue
        code = open(os.path.join(d, b["file"]), "rb").read()
        r = rows.get(b["record_id"])
        if r is None:
            bad.append(f"{key}: ledger row {b['record_id']} missing"); continue
        if not (sha(code) == b["code_sha256"] == sha(r["impl_code"].encode())):
            bad.append(f"{key}/{b['file']}: sha256 file/manifest/ledger disagree")
        if r["impl_name"] != b["impl_name"]:
            bad.append(f"{key}/{b['file']}: impl_name {r['impl_name']} != {b['impl_name']}")
        bodies.append({"n": b["n"], "role": b["role"], "record_id": b["record_id"], "impl_name": b["impl_name"],
                       "file": f"legacy/{key}/{b['file']}", "code_sha256": b["code_sha256"],
                       "surface": r.get("surface") or "unknown", "reversible": r.get("reversible") is True,
                       "params": r.get("params") or {}, "calls": r.get("calls"),
                       "historical_steps": b.get("steps"), "executed_basis": b.get("executed_basis")})
    out[key] = {"model": model, "case": case, "seed": int(s[1:]), "group": group, "a2_class": m["a2_class"],
                "enact_retry": m["chain"]["enact_retry"], "historical_a2_status": m["a2"]["status"],
                "historical_a2_closed": m["a2"]["closed"], "b0_outcome": e["outcome"], "b0_closed": e["closed"],
                "b0_iter": e["iter"], "bodies": bodies}
if bad:
    print("\n".join(bad)); sys.exit(1)
dst = os.path.join(FX, "tools", "legacy_chains.json")
os.makedirs(os.path.dirname(dst), exist_ok=True)
json.dump({"schema": "zrv-legacy-chains/1", "generator": "tools/monitor/grid/t10b/extract_legacy_chains.py",
           "ledger": os.path.relpath(LEDGER, ROOT), "ledger_sha256": sha(open(LEDGER, "rb").read()),
           "episodes": out}, open(dst, "w"), indent=1, sort_keys=True)
cnt = {}
for v in out.values():
    cnt[v["group"]] = cnt.get(v["group"], 0) + 1
print("wrote", os.path.relpath(dst, ROOT), cnt)
