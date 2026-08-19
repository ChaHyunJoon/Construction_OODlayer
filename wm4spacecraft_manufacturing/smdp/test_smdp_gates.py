"""SMDP 게이트(G-S · G2 · G6 · G-M)의 단위검사. 합성 입력만 쓴다 —
2.4GB 짜리 _sample_work 없이도 돌아야 로직 회귀를 잡을 수 있다."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import boards  # noqa: E402
import gate_gs  # noqa: E402
import gate_g2  # noqa: E402


def _mk_board(tmp_path, board_id, decisions, makespan=100.0, crashed=False):
    d = tmp_path / board_id
    d.mkdir()
    row = {"makespan": makespan, "complete": True, "decisions": decisions}
    (d / "rows.jsonl").write_text(json.dumps(row) + "\n")
    return {"board_id": board_id, "case": board_id.split("_s")[0],
            "seed": int(board_id.split("_s")[1].split("_a")[0]),
            "arm_id": int(board_id.split("_a")[1]), "arm_name": "A%s" % board_id[-1],
            "deviate_at": 2, "deviation_fired": True, "crashed": crashed}


def _dec(i, t, macro, valid):
    return {"decision_index": i, "sim_t_at": t, "macro": macro,
            "valid": valid, "truth": "BatteryTruth", "at": int(t * 10)}


def test_load_groups_keys_by_case_seed(tmp_path):
    manifest = tmp_path / "boards.jsonl"
    recs = []
    for arm in (0, 1):
        recs.append(_mk_board(tmp_path, "battery_s1_a%d" % arm,
                              [_dec(1, 0.0, "NOOP", ["NOOP", "Replace"]),
                               _dec(2, 1.0, "Replace", ["NOOP", "Replace"]),
                               _dec(3, 2.0 + arm, "NOOP", ["NOOP", "Replace"])]))
    manifest.write_text("".join(json.dumps(r) + "\n" for r in recs))
    groups = boards.load_groups(str(tmp_path), str(manifest))
    assert list(groups.keys()) == [("battery", 1)]
    assert sorted(groups[("battery", 1)].keys()) == [0, 1]
    assert len(groups[("battery", 1)][0]["decisions"]) == 3


def test_tau_at_uses_next_decision():
    b = {"decisions": [_dec(1, 0.0, "NOOP", []), _dec(2, 1.5, "Replace", []),
                       _dec(3, 4.0, "NOOP", [])], "makespan": 9.0}
    assert gate_gs.tau_at(b, 2) == (2.5, False)


def test_tau_at_right_censors_on_last_decision():
    b = {"decisions": [_dec(1, 0.0, "NOOP", []), _dec(2, 1.5, "Replace", [])],
         "makespan": 9.0}
    tau, censored = gate_gs.tau_at(b, 2)
    assert censored is True and abs(tau - 7.5) < 1e-9


def test_permutation_detects_arm_effect():
    """양성 대조: 팔 id 가 τ 를 결정하면 p 가 작아야 한다."""
    tau = {("c", g): {a: 1.0 + a + 0.01 * g for a in range(4)} for g in range(20)}
    p, ss_obs, ss_null = gate_gs.block_permutation_p(tau, n_perm=400, seed=0)
    assert p < 0.01 and ss_obs > ss_null


def test_permutation_finds_nothing_when_tau_is_exogenous():
    """음성 대조: τ 가 그룹에만 의존하면 p 가 커야 한다. 이 검사가 없으면
    게이트가 '언제나 유의' 를 내는 항진명제인지 알 수 없다."""
    tau = {("c", g): {a: 3.0 + 0.5 * g for a in range(4)} for g in range(20)}
    p, _, _ = gate_gs.block_permutation_p(tau, n_perm=400, seed=0)
    assert p > 0.2


def test_coupling_counts_only_multi_option_decisions():
    """분모는 481 규약 — valid 가 2개 미만이면 그 결정은 세지 않는다.
    valid == [] 는 '제한 없음' 규약(policy.jl:413)이라 메뉴가 있는 게 아니다."""
    groups = {
        ("battery", 1): {
            0: {"crashed": False, "deviate_at": 1, "makespan": 9.0, "decisions": [
                _dec(1, 0.0, "NOOP", ["NOOP", "Replace"]),
                _dec(2, 1.0, "Replace", ["NOOP", "Replace"])]},
            1: {"crashed": False, "deviate_at": 1, "makespan": 9.0, "decisions": [
                _dec(1, 0.0, "Replace", ["NOOP", "Replace"]),
                _dec(2, 1.0, "NOOP", ["NOOP", "Replace"])]},
        },
        ("fault", 2): {  # valid == [] → 분모에서 빠진다
            0: {"crashed": False, "deviate_at": 1, "makespan": 9.0, "decisions": [
                _dec(1, 0.0, "NOOP", []), _dec(2, 1.0, "Replace", [])]},
            1: {"crashed": False, "deviate_at": 1, "makespan": 9.0, "decisions": [
                _dec(1, 0.0, "Replace", []), _dec(2, 1.0, "NOOP", [])]},
        },
    }
    out = gate_g2.coupling_rate(groups)
    assert out["n_eligible"] == 1
    assert out["n_coupled"] == 1
    assert abs(out["rate"] - 1.0) < 1e-9


def test_coupling_zero_when_next_decision_is_identical():
    groups = {("battery", 1): {
        0: {"crashed": False, "deviate_at": 1, "makespan": 9.0, "decisions": [
            _dec(1, 0.0, "NOOP", ["NOOP", "Replace"]),
            _dec(2, 1.0, "Replace", ["NOOP", "Replace"])]},
        1: {"crashed": False, "deviate_at": 1, "makespan": 9.0, "decisions": [
            _dec(1, 0.0, "Replace", ["NOOP", "Replace"]),
            _dec(2, 1.0, "Replace", ["NOOP", "Replace"])]},
    }}
    out = gate_g2.coupling_rate(groups)
    assert out["n_eligible"] == 1 and out["n_coupled"] == 0
