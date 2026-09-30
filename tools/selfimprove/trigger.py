"""트리거와 후보 트랙 (spec §7, §0.0 R7).

- 묶음 = behavior_key. 셈 = lane=="dspy" ∧ complete ∧ body 있음 ∧ artifact 가 어느 회전의 후보도,
  승인된 artifact 도 아님.
- 그 키의 **끝난** 회전(거부·배포)이 있으면 그 회전이 열린 뒤 큐에 들어온 행만 센다(`queue_pos`).
  진행 중 회전이 있는 키는 제외.
- 현재 버전에 같은 키의 팔이 있으면 track="replace"(그 팔과 쌍대 비교, C7), 없으면 "add"."""
import re

TERMINAL = ("REJECTED", "DEPLOYED")


def _done(c):
    return str(c.get("state", "")).startswith(TERMINAL)


def due(queue, cycles, library_rows, active_arms, m=3):
    taken = {c.get("candidate_artifact") for c in cycles} | {r["artifact_sha256"] for r in library_rows}
    busy = {c["behavior_key"] for c in cycles if not _done(c)}
    since = {}
    for c in cycles:
        if _done(c):
            since[c["behavior_key"]] = max(since.get(c["behavior_key"], 0), int(c["queue_pos"]))
    incumbent = {a["behavior_key"]: a["arm_id"] for a in active_arms}
    groups = {}
    for pos, r in enumerate(queue):
        k = r.get("behavior_key")
        if (r.get("lane") != "dspy" or not r.get("complete") or not r.get("artifact_sha256")
                or r["artifact_sha256"] in taken or k in busy or pos < since.get(k, 0)):
            continue
        groups.setdefault(k, []).append(r)
    out = []
    for k, rows in groups.items():
        if len(rows) >= m:
            out.append({"behavior_key": k, "track": "replace" if k in incumbent else "add",
                        "incumbent_arm_id": incumbent.get(k), "members": rows})
    return sorted(out, key=lambda d: d["behavior_key"])


def normalized_len(code):
    code = re.sub(r"#=.*?=#", "", code, flags=re.S)
    code = re.sub(r"#[^\n]*", "", code)
    return len(re.sub(r"\s+", "", code))


def representative(members):
    """정규화(주석·공백 제거) 길이 최소 → logged_at 최소. members 는 impl_code 를 싣고 있어야 한다."""
    return min(members, key=lambda r: (normalized_len(r["impl_code"]), r.get("logged_at") or ""))
