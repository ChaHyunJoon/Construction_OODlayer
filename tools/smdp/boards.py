"""588 board(= 1-step deviation 표집 판) 로더. G-S · G2 · G-M 이 공용으로 쓴다.

board_id 규약: "<case>_s<seed>_a<arm_id>"  (예: battery_s1_a0)
그룹 = (case, seed). 한 그룹 안의 board 들은 **deviate_at 결정 하나만 다르고 그 앞은
바이트 동일**하다 — 2026-08-17 결정성 게이트가 84그룹 전부에서 확인했다. 그래서 이 그룹이
"같은 s 에서 팔만 바꾼" 짝지은 비교의 단위가 된다.

⚠️ rows.jsonl 은 board 당 **한 줄**이고 그 안의 "decisions" 가 결정 리스트다.
"""
import json
import os

DEFAULT_WORK = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                            "data", "dp_oracle", "_sample_work")
DEFAULT_MANIFEST = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                                "data", "dp_oracle", "boards.jsonl")


def load_groups(work_dir=DEFAULT_WORK, boards_path=DEFAULT_MANIFEST, require_fired=True):
    """(case, seed) -> {arm_id: board_dict} 를 돌려준다.

    board_dict = {arm_name, deviate_at, crashed, complete, makespan, decisions}
    rows.jsonl 이 없는 board 는 조용히 빼지 않고 dropped 로 세어 stderr 로 알린다.
    """
    groups, dropped = {}, {"no_rows": 0, "not_fired": 0, "bad_json": 0}
    with open(boards_path) as fh:
        for line in fh:
            rec = json.loads(line)
            if require_fired and not rec.get("deviation_fired"):
                dropped["not_fired"] += 1
                continue
            path = os.path.join(work_dir, rec["board_id"], "rows.jsonl")
            if not os.path.exists(path):
                dropped["no_rows"] += 1
                continue
            try:
                with open(path) as rf:
                    row = json.loads(rf.readline())
            except (ValueError, OSError):
                dropped["bad_json"] += 1
                continue
            groups.setdefault((rec["case"], int(rec["seed"])), {})[int(rec["arm_id"])] = {
                "board_id": rec["board_id"],
                "arm_name": rec.get("arm_name"),
                "deviate_at": rec.get("deviate_at"),
                "crashed": bool(rec.get("crashed")),
                "complete": bool(row.get("complete")),
                "makespan": row.get("makespan"),
                "decisions": row.get("decisions") or [],
            }
    if any(dropped.values()):
        import sys
        print("[boards] dropped: %s" % dropped, file=sys.stderr)
    return groups


def decision_at(board, k):
    """decision_index == k 인 결정을 돌려준다(없으면 None). 1-based."""
    for d in board["decisions"]:
        if d.get("decision_index") == k:
            return d
    return None
