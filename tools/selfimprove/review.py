"""S4 사람 검토: 검토 묶음(packet.md)과 결정 파일 (spec §10). 검토자는 승인·거부만 — 코드는 안 고친다."""
import datetime, difflib, hashlib, json, os
from . import paths


def _cdir(exp, c):
    return os.path.join(paths.state_dir(exp), "cycles", c)


def _load(p, default=None):
    return json.load(open(p, encoding="utf-8")) if os.path.exists(p) else default


def called_names(behavior_key):
    names = behavior_key.split("|", 1)[1]
    return [] if names == "∅" else names.split(",")


def psi_table(exp):
    return _load(os.path.join(paths.data_dir(exp), "psi", "base_psi.json"), {})


def write_packet(exp, c):
    d = _cdir(exp, c)
    cy, cand = _load(os.path.join(d, "cycle.json")), _load(os.path.join(d, "candidate.json"))
    s0, s1 = _load(os.path.join(d, "s0.json"), {}), _load(os.path.join(d, "s1", "report.json"), {})
    s3 = _load(os.path.join(d, "s3_summary.json"), {})
    body = cand["body"]
    arm = cand.get("arm") or _load(os.path.join(d, "arms", "candidate.json"))
    sha = hashlib.sha256(body["impl_code"].encode()).hexdigest()
    diff = list(difflib.unified_diff(body["impl_code"].splitlines(), arm["impl_code"].splitlines(),
                                     "ledger", "arm", lineterm=""))
    names, table = called_names(cy["behavior_key"]), psi_table(exp)
    wi = {m["name"]: m.get("signature", "") for m in
          json.load(open(paths.WORLD_INTERFACE, encoding="utf-8"))["methods"]}
    crit = s3.get("criteria", {})
    rescued = [i for i, r in (s3.get("instances") or {}).items() if r.get("complete")][:3]
    failed = [(i, r.get("fail_mode")) for i, r in (s3.get("instances") or {}).items() if not r.get("complete")]
    L = ["# 검토 묶음 — 회전 %s" % c, "",
         "> 🔴 **판 완주는 인과 증거가 아니다.** 인과 판정은 C5(T vs T_null)와 C7(교체 트랙)뿐이다.", "",
         "## 1. 후보", "",
         "- impl_name `%s` → 등록 이름 `%s`" % (body["impl_name"], arm["impl_name"]),
         "- behavior_key `%s` · track `%s` · incumbent `%s`" % (cy["behavior_key"], cy.get("track"), cy.get("incumbent_arm_id")),
         "- 출처 %s/%s record `%s` (%s)" % ((body.get("run_ctx") or {}).get("campaign_id"),
                                          (body.get("run_ctx") or {}).get("run_id"), body.get("record_id"), body.get("logged_at")),
         "- artifact `%s`" % arm["artifact_sha256"], "",
         "## 2. body 원문 (ledger impl_code sha256 `%s`)" % sha, "", "```julia", body["impl_code"].rstrip(), "```", "",
         "arm 과의 diff (이름 교체 외 0 이어야 한다):", "", "```diff", *(diff or ["(no diff)"]), "```", "",
         "## 3. 호출 그래프", ""]
    L += ["- `%s%s` — ψ 행 %s" % (n, wi.get(n, ""), "있음" if n in table else "**없음 (R4: 작성 필요)**")
          for n in names] or ["- (world-interface 호출 없음 — ψ 기본값, spec §11.3)"]
    L += ["", "## 4. S0 소프트 플래그", "", "- " + (", ".join(s0.get("soft") or []) or "없음"), "",
          "## 5. S1", "", "```json", json.dumps(s1, indent=1, ensure_ascii=False)[:4000], "```", "",
          "## 6. S3 기준 (C1–C7) · 층별", "", "```json", json.dumps(crit, indent=1, ensure_ascii=False), "```", "",
          "실패 인스턴스: " + (", ".join("%s(%s)" % x for x in failed) or "없음"), "",
          "## 7. 재생 렌더 (구조된 인스턴스)", ""]
    L += ["- `%s`: S3 T 판을 `DEMO_ANIM=1` 로 다시 렌더" % i for i in rescued] or ["- 없음"]
    L += ["", "## 8. 같은 행동 키의 다른 1회용 body", ""]
    L += ["- %s `%s`" % (m.get("q_id"), m.get("impl_name")) for m in cand.get("members") or []]
    L += ["", "## 검토자 판단", "", "R1 현실성 · R2 편법(시뮬 허점) · R3 이름/설명 일치 · R4 ψ 주석 → `review` 명령으로 결정."]
    os.makedirs(os.path.join(d, "review"), exist_ok=True)
    p = os.path.join(d, "review", "packet.md")
    open(p, "w", encoding="utf-8").write("\n".join(L) + "\n")
    return p


def record_decision(exp, c, decision, reviewer, reason, R1, R2, R3, psi_rows_added):
    if decision not in ("approve", "reject"):
        raise ValueError("decision must be approve|reject")
    d = _cdir(exp, c)
    p = os.path.join(d, "review", "decision.json")
    if os.path.exists(p):
        raise FileExistsError("decision for %s already recorded — decisions are immutable" % c)
    if decision == "approve":
        table = psi_table(exp)
        missing = [n for n in called_names(_load(os.path.join(d, "cycle.json"))["behavior_key"]) if n not in table]
        claimed_absent = [n for n in psi_rows_added if n not in table]
        if missing or claimed_absent:
            raise ValueError("approve refused: ψ rows missing from the table for %s" % (missing or claimed_absent))
    os.makedirs(os.path.dirname(p), exist_ok=True)
    ev = {k: (hashlib.sha256(open(os.path.join(d, f), "rb").read()).hexdigest()
              if os.path.exists(os.path.join(d, f)) else None)
          for k, f in (("s3_summary_sha256", "s3_summary.json"), ("packet_sha256", os.path.join("review", "packet.md")))}
    rec = {"decision": decision, "reviewer": reviewer, "reason": reason, "R1": R1, "R2": R2, "R3": R3,
           "psi_rows_added": list(psi_rows_added), **ev,
           "decided_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}
    with open(p, "x", encoding="utf-8") as f:
        json.dump(rec, f, indent=1, ensure_ascii=False)
    return p
