"""무료 종단 시험 보조 (plan Task 19, spec §14).

🔴 시험 전용. 오라클 fixture(사람이 쓴 body)를 **실행된 원장 행** 모양으로 감싸 큐에 넣고, 시험용 ψ 행을
쓰고, 시험용 승인을 기록한다. 이 경로로 만든 팔은 LLM 출처 주장에 쓸 수 없다 — 원장 행과 큐 행에
`origin="oracle_fixture"` · `llm_model=["oracle-fixture"]` 가 남는다."""
import argparse, datetime, json, os
from . import harvest, paths, review

# 시험용 ψ 행 (검토자 R4 자리를 대신한다 — 값은 _PRIMITIVE_TABLE 의 가장 가까운 원시에서 빌렸다)
TEST_PSI = {"translate_whole_build!": [1.5, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 3.0],   # ~ RelocateBuild
            "restage_all_blocked!": [1.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 2.0],     # ~ ForbidZone
            "active_restriction_zones": [0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0]}  # 읽기 전용


def inject_fixture(exp, fixture, n=3, model="tractor", case="zone", seed0=1001):
    fx = json.load(open(fixture, encoding="utf-8"))
    names = harvest.world_interface_names()
    qp = os.path.join(paths.state_dir(exp), "queue.jsonl")
    out = []
    for i in range(n):
        seed = seed0 + i
        rk = "router__%s__s%d" % (case, seed)
        body = {"row_type": "decide", "record_id": "e2e-fixture-%d" % i, "parent_record_id": None,
                "kind": "zone", "origin": "oracle_fixture", "impl_name": fx["impl_name"],
                "impl_code": fx["impl_code"], "calls": fx["calls"], "params": fx["params"],
                "surface": fx["surface"], "reversible": fx["reversible"], "body_names": fx["body_names"],
                "logged_at": datetime.datetime.now().isoformat(), "response_id": None,
                "run_ctx": {"campaign_id": "e2e-fixture", "run_id": rk, "model": model, "seed": seed}}
        harvest.save_body(exp, body)
        q = {"q_id": "e2e-fixture/%s" % rk, "version": "v0", "model": model, "case": case, "seed": seed,
             "lane": "dspy", "router_axis": "ood_kind", "defer_reason": None, "complete": True, "fail_mode": None,
             "closed": None, "n_total": None, "record_id": body["record_id"], "final_row": "decide",
             "impl_name": fx["impl_name"], "artifact_sha256": harvest.artifact_of(body),
             "impl_code_sha256": None, "behavior_key": harvest.behavior_key(fx["impl_code"], "zone", names),
             "llm_model": ["oracle-fixture"], "llm_cost_usd": 0.0, "logged_at": body["logged_at"],
             "origin": "oracle_fixture"}
        with open(qp, "a", encoding="utf-8") as f:
            f.write(json.dumps(q, sort_keys=True) + "\n")
        out.append(q)
    return out


def add_test_psi(exp):
    p = os.path.join(paths.data_dir(exp), "psi", "base_psi.json")
    t = review.psi_table(exp)
    t.update(TEST_PSI)
    json.dump(t, open(p, "w"), indent=1)
    return sorted(TEST_PSI)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="selfimprove.e2e")
    ap.add_argument("cmd", choices=("inject", "psi"))
    ap.add_argument("--exp", required=True)
    ap.add_argument("--fixture", default=os.path.join(paths.ROOT, "tools", "fixtures", "oracle_zone_clear.json"))
    a = ap.parse_args(argv)
    print(json.dumps(inject_fixture(a.exp, a.fixture) if a.cmd == "inject" else add_test_psi(a.exp), indent=1))


if __name__ == "__main__":
    main()
