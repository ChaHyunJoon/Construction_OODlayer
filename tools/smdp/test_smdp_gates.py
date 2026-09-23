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


# ============================================================================
# 2026-08-19 리뷰 라운드 1 수정: 아래부터는 controller ruling A/B 를 구현하는 검사다.
# Ruling A: block_permutation_p 는 그룹 내 순열이라 그룹 내 τ 산포에 원리적으로 눈이
#   멀어 있다(팔 순위가 그룹을 가로질러 일관돼야만 유의해진다) — 대체 통계량
#   spread_test/fisher_exact_greater 를 검정한다.
# Ruling B: valid == [] 는 '제한 없음'(전체 메뉴) 규약인데 브리프 필터가 그것을
#   '메뉴 없음'으로 오독해 결합이 있는 관측을 통째로 지운다 — 수정 필터를 검정한다.
# ============================================================================

def test_spread_test_detects_rotating_arm_effect_that_old_stat_misses():
    """양성 대조 + 회귀 락: τ 가 100% 팔로 결정되지만 어느 팔이 느린지 그룹마다
    회전하면, 그룹을 가로지르는 일관된 팔 주효과가 없어 옛 block_permutation_p 는
    이 의존성을 놓친다(그래서 대체됐다) — 그러나 새 spread_test 는 그룹 '내부'
    산포를 직접 보므로 100% 잡아야 한다."""
    tau = {("c", g): {a: (100.0 if a == g % 4 else 1.0) for a in range(4)} for g in range(20)}
    n_spread, n_groups = gate_gs.spread_test(tau)
    assert n_spread == 20 and n_groups == 20

    # 회귀 락: 옛 통계량은 바로 이 자료에서 원리적 결함을 보인다 — 유의성을 놓친다.
    p_old, ss_obs, ss_null = gate_gs.block_permutation_p(tau, n_perm=400, seed=0)
    assert p_old > 0.5


def test_spread_test_finds_nothing_when_tau_is_group_only():
    """음성 대조: τ 가 그룹에만 의존하고(팔 간 완전 동일) 그룹마다 절대 수준만
    다르면, 그룹 내 산포는 전혀 없어야 한다. 이 검사가 없으면 spread_test 가
    '언제나 스프레드 있음' 을 내는 항진명제인지 알 수 없다."""
    tau = {("c", g): {a: 3.0 + 0.5 * g for a in range(4)} for g in range(20)}
    n_spread, n_groups = gate_gs.spread_test(tau)
    assert n_spread == 0 and n_groups == 20


def test_fisher_exact_greater_matches_hand_computed_example():
    """math.comb 로 손으로 짠 Fisher exact 구현 자체의 정확성 검사(스켑틱: 새 유의성
    검정이 또 하나의 '항상 그럴듯한 숫자를 내는' 장식이 아니라는 확인).
    표 [[2,0],[0,2]] (n1=2,n2=2,K=2,N=4) 의 단측 p = C(2,2)C(2,0)/C(4,2) = 1/6."""
    p = gate_gs.fisher_exact_greater(2, 0, 0, 2)
    assert abs(p - (1.0 / 6.0)) < 1e-9


def test_g2_brief_filter_drops_valid_empty_coupled_group():
    """Ruling B 의 핵심 반증: valid==[] ('제한 없음'=전체 메뉴) 인 그룹에서 결합이
    실제로 일어나도(팔마다 다른 macro) 브리프의 필터는 그 그룹을 통째로 자격에서
    지운다 — n_eligible == 0."""
    groups = {
        ("fault", 3): {
            0: {"crashed": False, "deviate_at": 1, "makespan": 9.0, "decisions": [
                _dec(1, 0.0, "NOOP", []), _dec(2, 1.0, "ReformTeam", [])]},
            1: {"crashed": False, "deviate_at": 1, "makespan": 9.0, "decisions": [
                _dec(1, 0.0, "Replace", []), _dec(2, 1.0, "Replace", [])]},
        },
    }
    brief_out = gate_g2.coupling_rate(groups)
    assert brief_out["n_eligible"] == 0

    corrected_out = gate_g2.coupling_rate_corrected(groups)
    assert corrected_out["n_eligible"] == 1
    assert corrected_out["n_coupled"] == 1
    assert abs(corrected_out["rate"] - 1.0) < 1e-9
