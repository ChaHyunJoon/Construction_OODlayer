"""pick_k 의 계약: 결정론적이고, 판마다 깊이가 흩어지고, 항상 1 이상이다."""
import json, os, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sample_grid import pick_k, DEFAULT_N_HINT as N_HINT   # noqa: E402  (import sample_grid 가
import sample_grid as SG                                    # noqa: E402   WM 을 sys.path 에 넣어야
import objective                                             # noqa: E402   objective/derive_grid 가
from derive_grid import load_grid                            # noqa: E402   임포트된다)


def test_deterministic():
    assert pick_k("fault", 3, 1, N_HINT) == pick_k("fault", 3, 1, N_HINT)


def test_in_range():
    for case in ("fault", "battery", "zone", "all"):
        for seed in range(1, 13):
            for arm in (0, 1, 2, 3, 4, 7, 8):
                k = pick_k(case, seed, arm, N_HINT)
                assert 1 <= k <= N_HINT, (case, seed, arm, k)


def test_spreads_over_depth():
    """한 팔의 12 시드가 한 깊이에 몰리면 그 팔은 얕은 칸만 잰다."""
    for arm in (0, 1, 2, 3, 4, 7, 8):
        ks = {pick_k("fault", s, arm, N_HINT) for s in range(1, 13)}
        assert len(ks) >= 4, (arm, sorted(ks))


def test_all_arms_share_k_somewhere():
    """같은 (case, seed) 에서 모든 팔이 같은 k 를 쓰는 조합이 있어야
    그 칸이 7팔을 다 본다 = 단일팔 칸이 줄어드는 메커니즘."""
    hit = 0
    for seed in range(1, 13):
        ks = {pick_k("fault", seed, a, N_HINT) for a in (0, 1, 2, 3, 4, 7, 8)}
        if len(ks) == 1:
            hit += 1
    assert hit >= 3, hit


# =====================================================================================
# 라벨링(2026-08-17 리뷰 Critical 1) + R3/owner (컨트롤러 보강, 브리프에 없음) + 배제 술어
# (2026-08-17 2차 리뷰: deviate_valid -> enact_applied) + 무집행 판 대표(2026-08-17 3차 리뷰).
#
# 초판은 전이 행 전부를 판의 deviation 목표 팔(arm_id/arm_name)로 라벨했다. 그런데 엔진이 그
# 팔을 집행한 것은 결정 k 딱 하나뿐이라, i<k 결정은 canonical 그대로인데 팔만 다른 가짜 동점을
# 만들고(R3 가 판 단위로 죽이려던 동점이 결정 단위로 되살아난 것) i>k 결정은 갈라진 궤적 위의
# canonical 행동을 그 팔로 잘못 귀속시켰다(혼입). 리뷰가 지시한 수정:
#   - 라벨은 그 결정에서 실제로 집행된 매크로(`d["macro"]`)를 따른다.
#   - (case, seed) 마다 rows 를 낸 판 중 arm_id 최솟값이 **owner** — owner 만 전 결정을 낸다.
#   - owner 가 아닌 판은 `decision_index < k` 를 버리고(owner 의 prefix 와 중복), 그리고
#     deviation 이 안 걸렸으면(R3, "미발화") 아무것도 안 낸다.
#
# ⚠️ 판정 술어는 `deviate_valid` 가 **아니라 `enact_applied`/`deviated`** 다(2026-08-17
# 2차 리뷰). `deviate_valid`(그 팔이 valid_macros(env,truth) 안에 있는가)는 FaultTruth·
# ReformTruth 에서 `valid_macros` 가 항상 빈 리스트를 주고 policy.jl 규약("빈 메뉴 = 제한
# 없음")상 그럴 때 `deviate_valid` 가 사실상 항상 true 라서, fault·reform 축에서는 **아무것도
# 못 거른다.** `deviate_valid` 는 여전히 진단 키로 남아 있고 클래스 판정엔 안 쓴다.
#
# ⚠️ **그 두 신호는 서로 다른 세계다 — 하나로 합치면 안 된다(2026-08-17 4차 수정).**
# 3차까지는 `enact_applied == False` 와 `deviated == False` 를 "무집행" 하나로 묶고 그중 arm_id
# 최솟값 하나만 대표로 남겼는데, 그 전제("둘 다 canonical 과 바이트 동일")가 거짓이다:
#   · **클래스 A** = `deviated is False` — 강제한 팔이 canonical 이 이미 고르려던 것과 같았다
#     (policy.jl:1031) ⇒ **canonical 과** 바이트 동일.
#   · **클래스 B** = `enact_applied is False` — 집행 사슬(run_demo.jl:352-457)이 어떤 분기도 안
#     탔다 ⇒ **NOOP 팔 판과** 바이트 동일. canonical 과는 **다르다**(canonical 이었다면 자기
#     매크로의 분기를 탔을 것이다). 실측 반증: 같은 (case,seed) 에서 A 판은 n_decisions=4·
#     complete=True 인데 B 판은 n_decisions=14·complete=False 였다.
# 합쳐서 `min()` 을 취하면 클래스 B 의 팔 id 가 대체로 더 작아(zone: 1,2,8 이 B / reform:
# 1,2,3,7,8 이 B) **owner 와 중복인 판을 대표로 남기고 유일한 canonical 판을 버린다.**
# 꼬리 대표 규칙은 두 클래스에 원칙이 **하나**다(`_pick_deviation_representatives`) — **그 세계를
# 이미 i=0 부터 전부 내고 있는 판이 있으면 꼬리 대표를 두지 않고, 없을 때만 하나(arm_id 최솟값)에
# 꼬리를 남긴다.** 다른 것은 "누가 그 세계를 들고 있느냐" 뿐이다:
#   · A(= 꼬리가 canonical 과 바이트 동일): 그 세계를 들고 있는 판은 **owner 가 클래스 A 일 때의
#     owner** 다 — 그러면 0개(owner 가 canonical 을 i=0 부터 전부 낸다). 아니면 비owner 클래스
#     A 중 arm_id 최솟값 하나.
#   · B(= 꼬리가 NOOP 팔 판과 바이트 동일): 그 세계를 들고 있는 판은 **NOOP 팔 판**이거나
#     **owner 가 클래스 B 일 때의 owner** 다 — 둘 중 하나라도 있으면 0개. NOOP 판이 크래시했고
#     owner 도 클래스 B 가 아닐 때만 비owner 클래스 B 중 arm_id 최솟값 하나(2026-08-17 5차).
#   · 둘 다 False 인 판은 **A** 다(A 우선 — 강제 대입 자체가 무변경이므로).
#
# ★★ 2026-08-15 7차 — **지배 문장: deviation 행은 절대 중복이 아니다. 발화한 판은 전부 자기
# 결정 k 행을 내고, 중복 제거는 꼬리(`decision_index > k`)에만 적용한다.**
# 6차까지는 클래스 A/B 판을 (대표 하나를 빼고) **판 통째로** 뺐고, 그때 같이 사라진 결정 k 행이
# 그 판의 유일무이한 관측이었다 — 판마다 자기 팔을 k 에서 강제하므로 그 행의 라벨이 그 팔이고,
# 같은 칸에서 그 팔을 내는 판이 다른 데 없다. 보존된 588판 실측(같은 칸·같은 k, 전부 클래스 B):
#     판 all_s11_a1  k=8  macro=Replace / a2  Deprioritize / a3  ForbidZone
# 이걸 버린 귀결이 단일팔 칸 27/49 → 23/48(목표 ≤5)로 사실상 안 움직인 것이었다. 진짜 중복은
# 꼬리뿐이다(무동작 deviation 뒤에는 세계가 안 바뀌어 꼬리가 NOOP 판/canonical 을 되밟는다).
# `se` 논증은 그대로 산다 — 서로 다른 팔 라벨은 서로 **다른 (cell, arm) 버킷**에 들어간다.
# 아래 테스트에서 "억제된 판" 이 0행이 아니라 **정확히 1행(decision_index == k)** 을 요구하는
# 것이 그 계약이다.
# =====================================================================================
AXES = load_grid()["axes"]

# 실제 action_registry.json 의 부분집합(2026-08-15 실측, `python -c "import action_registry as
# reg; print(reg.MACRO_NAME)"` 로 재확인 가능). id_by_name 을 모든 테스트가 매번 재구성하지
# 않도록 고정한다 — main() 이 arm_menu() 결과로 만드는 것과 같은 이름 집합이어야 하므로 여기
# 하드코딩한 것은 그 소비처 흉내일 뿐, 진실원(action_registry.json)을 복제하는 게 아니다(팔
# **id 숫자**를 검사하는 게 아니라 "라벨이 d[macro] 를 따라가는가" 라는 배선을 검사한다).
ID_BY_NAME = {"NOOP": 0, "Replace": 1, "Deprioritize": 2, "ForbidZone": 3,
              "ReformTeam": 4, "RelocateBuild": 7, "SwapBattery": 8}


def _decision(at, t, e, macro="NOOP", decision_index=None, deviate_at=None,
              deviate_arm=None, deviated=None, deviate_from=None, deviate_valid=None,
              enact_applied=None):
    """합성 결정 하나. `deviate_at`/`deviate_valid`/`enact_applied` 등은 policy.jl·run_demo.jl
    실측과 같게 **항상** 키를 낸다(값이 None 일 뿐 키가 사라지지 않는다 — 2026-08-17 스모크에서
    확인한 계약)."""
    return {"at": at, "closed_at": at, "sim_t_at": t, "energy_at_J": e,
            "truth": "BatteryTruth", "progress": 0.5, "spare_count": 10,
            "agent_pending": 1, "soc": 0.03, "macro": macro, "zone_primitives": None,
            "decision_index": decision_index, "deviate_at": deviate_at,
            "deviate_arm": deviate_arm, "deviated": deviated,
            "deviate_from": deviate_from, "deviate_valid": deviate_valid,
            "enact_applied": enact_applied}


def _board(decs, complete=True, makespan=20.0, energy=120000.0, closed=250, total=300):
    return {"complete": complete, "closed": closed, "total": total,
            "makespan": makespan, "battery": {"total_energy_J": energy},
            "decisions": decs, "objective_hash": objective.objective_hash(),
            "energy_objective": 1}


def _write_board_file(row, tmpdir, name="rows.jsonl"):
    p = os.path.join(tmpdir, name)
    with open(p, "w") as f:
        f.write(json.dumps(row) + "\n")
    return p


def _rows_to_samples_for_one_board(row, case, seed, arm_id, arm_name, k, is_owner=True,
                                    is_class_representative=False):
    with tempfile.TemporaryDirectory() as td:
        p = _write_board_file(row, td)
        rep = SG.new_report()
        out = SG.rows_to_samples(p, case, seed, arm_id, arm_name, AXES, k,
                                  is_owner=is_owner,
                                  is_class_representative=is_class_representative,
                                  id_by_name=ID_BY_NAME, report=rep)
    return out, rep


def test_owner_emits_all_decisions():
    """(a) owner 판은 deviation 발화 여부와 무관하게 전 결정을 낸다."""
    ds = [_decision(10, 2.0, 1000.0, macro="ReformTeam", decision_index=1),
          _decision(50, 8.0, 40000.0, macro="Replace", decision_index=2,
                    deviate_at=2, deviate_arm="Replace", deviated=True,
                    deviate_from="ReformTeam", deviate_valid=True),
          _decision(90, 15.0, 90000.0, macro="ReformTeam", decision_index=3)]
    out, rep = _rows_to_samples_for_one_board(_board(ds), "all", 1, 4, "ReformTeam", 2,
                                               is_owner=True)
    assert len(out) == 3, out
    assert rep["owner_boards"] == 1, rep
    assert rep["decisions_dropped_prefix_dup"] == 0, rep
    assert [t["decision_index"] for t in out] == [1, 2, 3], out


def test_non_owner_emits_only_from_k():
    """(b) owner 아닌 판은 decision_index >= k 만 낸다(owner 의 prefix 와 중복인 앞부분은
    뺀다)."""
    ds = [_decision(10, 2.0, 1000.0, macro="ReformTeam", decision_index=1),
          _decision(30, 5.0, 20000.0, macro="ReformTeam", decision_index=2),
          _decision(50, 8.0, 40000.0, macro="Replace", decision_index=3,
                    deviate_at=3, deviate_arm="Replace", deviated=True,
                    deviate_from="ReformTeam", deviate_valid=True, enact_applied=True),
          _decision(70, 11.0, 60000.0, macro="ReformTeam", decision_index=4),
          _decision(90, 15.0, 90000.0, macro="ReformTeam", decision_index=5)]
    out, rep = _rows_to_samples_for_one_board(_board(ds), "all", 1, 1, "Replace", 3,
                                               is_owner=False)
    assert len(out) == 3, out                              # decision_index 3,4,5
    assert [t["decision_index"] for t in out] == [3, 4, 5], out
    assert rep["decisions_dropped_prefix_dup"] == 2, rep    # decision_index 1,2 뺐다
    assert rep["boards_no_deviation"] == 0, rep


def test_non_owner_no_deviation_emits_nothing():
    """(c) owner 아닌 판인데 deviation 이 한 번도 안 걸렸으면(k > 결정 수) 아무것도 안 낸다."""
    ds = [_decision(10, 2.0, 1000.0), _decision(50, 8.0, 40000.0),
          _decision(90, 15.0, 90000.0)]           # deviate_at 키는 있지만 전부 None
    out, rep = _rows_to_samples_for_one_board(_board(ds), "fault", 1, 1, "Replace", 99,
                                               is_owner=False)
    assert out == [], out
    assert rep["boards_no_deviation"] == 1, rep
    assert rep["no_deviation_by_arm"]["Replace"] == 1, rep["no_deviation_by_arm"]
    # §충실성 게이트의 판정 대상 집합은 이 제외로 줄지 않는다 — 이 판도 여전히 "실행된 판"으로
    # 세어진다(Global Constraint 6). 여기서 빠지는 것은 게이트 통과 *이후*, 표본 목록뿐이다.
    assert rep["boards"] == 1 and rep["boards_bad"] == 0, rep


def test_owner_emits_all_even_if_deviation_never_fired():
    """(d) 대조군 — 같은 미발화 판이라도 owner 면 전 결정을 낸다. owner 는 그 (case,seed) 의
    canonical 궤적을 대표하므로 deviation 발화 여부와 무관하게 유효한 표본이다."""
    ds = [_decision(10, 2.0, 1000.0), _decision(50, 8.0, 40000.0),
          _decision(90, 15.0, 90000.0)]
    out, rep = _rows_to_samples_for_one_board(_board(ds), "fault", 1, 1, "Replace", 99,
                                               is_owner=True)
    assert len(out) == 3, out
    assert rep["boards_no_deviation"] == 0, rep
    assert rep["owner_boards"] == 1, rep


def test_non_owner_class_b_emits_only_the_deviation_row_when_tail_dropped():
    """(1, 2026-08-15 7차) owner 아닌 판에서 게이트는 걸렸지만 run_demo.jl 집행 사슬이 그 이름에
    대해 분기를 안 탔으면(`enact_applied == False`, `deviated=True`) **클래스 B** 다 — 꼬리가
    NOOP 팔 판과 바이트 동일하다. NOOP 판이 살아 있으면 이 판은 대표가 아니므로
    (`is_class_representative=False`) **꼬리를 뺀다. 그러나 결정 k 행은 낸다** — 그 행의 라벨은
    이 판이 k 에서 강제한 팔(`d["macro"]` = ForbidZone)이고, 그 칸에서 그 팔을 내는 판은 다른
    데 없다(6차까지는 판 통째로 빼서 이 관측을 잃었다 = §1-B 가 안 움직인 원인).

    `deviate_valid` 는 **True** 로 둔다 — fault/reform 축에서는 그게 항상 true 라(빈 메뉴=제한
    없음) 판정 신호가 될 수 없다는 것을 바로 이 조합으로 보인다."""
    ds = [_decision(10, 2.0, 1000.0, decision_index=1),
          _decision(50, 8.0, 40000.0, macro="ForbidZone", decision_index=2, deviate_at=2,
                    deviate_arm="ForbidZone", deviated=True, deviate_from="NOOP",
                    deviate_valid=True, enact_applied=False),
          _decision(90, 15.0, 90000.0, decision_index=3)]
    out, rep = _rows_to_samples_for_one_board(_board(ds), "fault", 1, 3, "ForbidZone", 2,
                                               is_owner=False, is_class_representative=False)
    assert len(out) == 1, out                               # 결정 k 행 하나만
    assert out[0]["decision_index"] == 2, out               # == k
    assert out[0]["arm_name"] == "ForbidZone", out          # 이 판이 강제한 팔로 라벨된다
    assert out[0]["arm"] == ID_BY_NAME["ForbidZone"], out
    assert rep["boards_class_b_tail_dropped"] == 1, rep
    assert rep["class_b_tail_dropped_by_arm"]["ForbidZone"] == 1, rep["class_b_tail_dropped_by_arm"]
    assert rep["decisions_dropped_tail_dup"] == 1, rep      # decision_index 3 하나
    assert rep["deviation_rows_kept_from_suppressed"] == 1, rep
    assert rep["deviation_rows_kept_by_arm"]["ForbidZone"] == 1, rep["deviation_rows_kept_by_arm"]
    assert rep["boards_class_b_representative"] == 0, rep   # 꼬리 대표는 아니었다
    assert rep["boards_class_a_tail_dropped"] == 0, rep     # 클래스 A 로 세면 안 된다
    assert rep["boards_class_a_representative"] == 0, rep
    assert rep["boards_no_deviation"] == 0, rep             # 다른 사건 — 미발화가 아니라 클래스 B
    assert rep["boards_deviate_valid_false"] == 0, rep      # deviate_valid=True 였다(정보성 카운터)
    assert rep["boards"] == 1 and rep["boards_bad"] == 0, rep


def test_non_owner_class_b_representative_emits_normally():
    """클래스 B 판이라도 그 (case,seed) 의 **꼬리 대표**로 뽑혔으면(NOOP 팔 판이 크래시해 그
    세계를 아무도 안 들고 있는 경우, `is_class_representative=True`) 비owner 규칙 그대로(i >= k)
    꼬리까지 낸다 — 그 세계가 통째로 안 잡히는 걸 막기 위해서다. 위 테스트(꼬리 배제)와 이
    테스트의 차이는 **꼬리뿐**이다: 결정 k 행은 둘 다 낸다."""
    ds = [_decision(10, 2.0, 1000.0, decision_index=1),
          _decision(50, 8.0, 40000.0, macro="ForbidZone", decision_index=2, deviate_at=2,
                    deviate_arm="ForbidZone", deviated=True, deviate_from="NOOP",
                    deviate_valid=True, enact_applied=False),
          _decision(90, 15.0, 90000.0, decision_index=3)]
    out, rep = _rows_to_samples_for_one_board(_board(ds), "fault", 1, 3, "ForbidZone", 2,
                                               is_owner=False, is_class_representative=True)
    assert len(out) == 2, out                                # decision_index 2,3
    assert [t["decision_index"] for t in out] == [2, 3], out
    assert out[0]["arm_name"] == "ForbidZone", out           # 결정 k 행의 라벨은 강제한 팔
    assert rep["boards_class_b_representative"] == 1, rep
    assert rep["class_b_representative_by_arm"]["ForbidZone"] == 1, rep
    assert rep["boards_class_b_tail_dropped"] == 0, rep
    assert rep["decisions_dropped_tail_dup"] == 0, rep       # 꼬리 대표라 뺀 꼬리가 없다
    assert rep["deviation_rows_kept_from_suppressed"] == 0, rep   # 억제된 판이 아니었다
    assert rep["boards_class_a_representative"] == 0, rep    # 클래스 A 로 세면 안 된다


def test_non_owner_emits_when_valid_false_but_applied_true():
    """deviate_valid=False 인데 enact_applied=True/deviated=True 면(메뉴 밖이라고 표시됐어도
    집행 사슬은 실제로 분기를 탄 경우) 어느 클래스도 아니므로 **대표 여부와 무관하게 정상
    방출한다** — 클래스 판정은 enact_applied/deviated 로만 하고, deviate_valid=False 는 정보성
    카운터에만 잡힌다."""
    ds = [_decision(10, 2.0, 1000.0, macro="ReformTeam", decision_index=1),
          _decision(50, 8.0, 40000.0, macro="ForbidZone", decision_index=2, deviate_at=2,
                    deviate_arm="ForbidZone", deviated=True, deviate_from="ReformTeam",
                    deviate_valid=False, enact_applied=True),
          _decision(90, 15.0, 90000.0, macro="ForbidZone", decision_index=3)]
    out, rep = _rows_to_samples_for_one_board(_board(ds), "zone", 1, 3, "ForbidZone", 2,
                                               is_owner=False, is_class_representative=False)
    assert len(out) == 2, out                               # decision_index 2,3
    assert [t["decision_index"] for t in out] == [2, 3], out
    assert rep["boards_class_b_tail_dropped"] == 0, rep
    assert rep["boards_class_a_tail_dropped"] == 0, rep
    assert rep["decisions_dropped_tail_dup"] == 0, rep      # 어느 클래스도 아니라 꼬리가 산다
    # 어느 클래스도 아니었으니 대표 집계도 0
    assert rep["boards_class_a_representative"] == 0, rep
    assert rep["boards_class_b_representative"] == 0, rep
    assert rep["boards_deviate_valid_false"] == 1, rep
    assert rep["deviate_valid_false_by_arm"]["ForbidZone"] == 1, rep["deviate_valid_false_by_arm"]


def test_non_owner_enact_applied_missing_not_excluded_but_counted():
    """enact_applied 키 자체가 없고 deviated 로도 클래스를 판정할 수 없으면(Task 1 미완료
    구세대 산출물) 모르는 것을 아는 척 배제하지 않는다 — 통과시키고 카운터만 늘린다.
    (4차 수정의 클래스 분리가 이 폴백을 무력화하지 않는지 지키는 테스트다.)"""
    ds = [_decision(10, 2.0, 1000.0, macro="ReformTeam", decision_index=1),
          _decision(50, 8.0, 40000.0, macro="Replace", decision_index=2, deviate_at=2,
                    deviate_arm="Replace", deviated=True, deviate_from="ReformTeam",
                    deviate_valid=True),                     # enact_applied 를 아예 안 준다
          _decision(90, 15.0, 90000.0, macro="ReformTeam", decision_index=3)]
    out, rep = _rows_to_samples_for_one_board(_board(ds), "fault", 1, 1, "Replace", 2,
                                               is_owner=False, is_class_representative=False)
    assert len(out) == 2, out                               # decision_index 2,3 — 배제 안 됨
    assert rep["boards_class_a_tail_dropped"] == 0, rep
    assert rep["boards_class_b_tail_dropped"] == 0, rep
    assert rep["decisions_dropped_tail_dup"] == 0, rep      # 꼬리도 안 뺐다
    assert rep["enact_applied_missing"] == 1, rep


# =====================================================================================
# `_pick_deviation_representatives` 자체 — (case,seed) 마다 **클래스 A·B 각각의** 대표
# (arm_id 최솟값)를 고르는 순수 함수. `main()` 이 **성공한 판 전부**(owner 포함)와
# `owner_arm`·`noop_arm_id` 를 넘긴다 — owner 를 미리 빼면 "owner 자신이 클래스 A 인가"와
# "NOOP 팔 판이 살아 있는가"를 알 수 없기 때문이다(3차 구현이 정확히 그래서 틀렸다).
#
# 아래 네 테스트는 3차 리뷰 때 만든 (a)-(d) 를 새 API·새 계약으로 갱신한 것이다(느슨해지지
# 않았다 — 클래스별 대표를 확인하고, owner 판과 NOOP 판 존재 여부를 명시적으로 세팅한다).
# =====================================================================================
# 클래스 A: deviated=False — 강제한 팔이 canonical 이 이미 고르려던 것과 같았다.
_CLASS_A_DECISION = _decision(10, 2.0, 1000.0, macro="Replace", decision_index=1, deviate_at=1,
                               deviate_arm="Replace", deviated=False, deviate_from="Replace",
                               deviate_valid=True, enact_applied=True)
# 클래스 B: enact_applied=False (deviated=True) — 집행 사슬이 아무 분기도 안 탔다.
_CLASS_B_DECISION = _decision(10, 2.0, 1000.0, macro="ForbidZone", decision_index=1, deviate_at=1,
                               deviate_arm="ForbidZone", deviated=True, deviate_from="Replace",
                               deviate_valid=True, enact_applied=False)
# 실제로 갈린 판(어느 클래스도 아님) — owner 판 픽스처로 쓴다.
_REAL_DECISION = _decision(10, 2.0, 1000.0, macro="Deprioritize", decision_index=1, deviate_at=1,
                            deviate_arm="Deprioritize", deviated=True, deviate_from="Replace",
                            deviate_valid=True, enact_applied=True)
# 둘 다 False — 클래스 A 가 우선한다.
_BOTH_FALSE_DECISION = _decision(10, 2.0, 1000.0, macro="Replace", decision_index=1, deviate_at=1,
                                  deviate_arm="Replace", deviated=False, deviate_from="Replace",
                                  deviate_valid=True, enact_applied=False)
_NO_FIRE_DECISIONS = [_decision(10, 2.0, 1000.0, decision_index=1),
                      _decision(50, 8.0, 40000.0, decision_index=2)]   # deviate_at 전부 None

NOOP_ARM_ID = ID_BY_NAME["NOOP"]   # 숫자를 하드코딩하지 않는다 — main() 도 이름으로 찾는다


def test_representative_picks_min_arm_id_among_multiple_class_a_boards():
    """(a) 같은 (case,seed) 에 클래스 A 비owner 판이 둘 이상이면 arm_id 최솟값 하나만 대표가
    된다(owner 는 클래스 A 가 아니다 — 실제로 갈린 판이라 canonical 연속을 안 들고 있다)."""
    with tempfile.TemporaryDirectory() as td:
        own = _write_board_file(_board([_REAL_DECISION]), td, "a1.jsonl")
        p3 = _write_board_file(_board([_CLASS_A_DECISION]), td, "a3.jsonl")
        p5 = _write_board_file(_board([_CLASS_A_DECISION]), td, "a5.jsonl")
        p8 = _write_board_file(_board([_CLASS_A_DECISION]), td, "a8.jsonl")
        rep_map = SG._pick_deviation_representatives(
            [("fault", 1, 8, p8), ("fault", 1, 1, own), ("fault", 1, 3, p3), ("fault", 1, 5, p5)],
            {("fault", 1): 1}, NOOP_ARM_ID)
    assert rep_map[("fault", 1)] == {"A": 3}, rep_map


def test_representative_is_the_only_class_a_board_when_alone():
    """(b) 클래스 A 판이 하나뿐이면 그것이 대표가 된다."""
    with tempfile.TemporaryDirectory() as td:
        own = _write_board_file(_board([_REAL_DECISION]), td, "a1.jsonl")
        p = _write_board_file(_board([_CLASS_A_DECISION]), td, "a7.jsonl")
        rep_map = SG._pick_deviation_representatives(
            [("zone", 2, 1, own), ("zone", 2, 7, p)], {("zone", 2): 1}, NOOP_ARM_ID)
    assert rep_map[("zone", 2)] == {"A": 7}, rep_map


def test_no_fire_boards_are_not_representative_candidates():
    """(c) 미발화 판(발화한 결정이 아예 없음)은 어느 클래스도 아니라 대표 후보가 아니다 —
    대표가 하나도 없는 (case,seed) 는 반환 dict 에 키조차 없다."""
    with tempfile.TemporaryDirectory() as td:
        own = _write_board_file(_board([_REAL_DECISION]), td, "a1.jsonl")
        p = _write_board_file(_board(_NO_FIRE_DECISIONS), td, "a2.jsonl")
        rep_map = SG._pick_deviation_representatives(
            [("battery", 4, 1, own), ("battery", 4, 2, p)], {("battery", 4): 1}, NOOP_ARM_ID)
    assert ("battery", 4) not in rep_map, rep_map


def test_representative_selection_is_order_independent():
    """(d) 대표 선정은 입력 순서를 섞어도 같다 — `min()` 을 풀 전체에서 취하지, 도착/등장
    순서에 기대지 않는다(owner 선정과 같은 결정론 원칙)."""
    with tempfile.TemporaryDirectory() as td:
        own = _write_board_file(_board([_REAL_DECISION]), td, "a0.jsonl")
        p1 = _write_board_file(_board([_CLASS_A_DECISION]), td, "a1.jsonl")
        p2 = _write_board_file(_board([_CLASS_A_DECISION]), td, "a2.jsonl")
        p9 = _write_board_file(_board([_CLASS_A_DECISION]), td, "a9.jsonl")
        pool = [("fault", 3, 9, p9), ("fault", 3, 2, p2), ("fault", 3, 1, p1),
                ("fault", 3, 0, own)]
        rep_a = SG._pick_deviation_representatives(pool, {("fault", 3): 0}, NOOP_ARM_ID)
        rep_b = SG._pick_deviation_representatives(list(reversed(pool)), {("fault", 3): 0},
                                                    NOOP_ARM_ID)
    assert rep_a == rep_b == {("fault", 3): {"A": 1}}, (rep_a, rep_b)


# =====================================================================================
# ★ 2026-08-17 4차 수정 — 클래스 A/B 를 **섞은** 풀. 3차까지의 병합 구현은 여기서 깨진다:
# 두 클래스를 "무집행" 하나로 묶고 `min()` 을 취하면 팔 id 가 더 작은 클래스 B 를 대표로
# 뽑아, owner/NOOP 판과 중복인 판을 남기고 **유일한 canonical 판(클래스 A)을 버린다.**
# =====================================================================================
def _mixed_pool(td, owner_decs):
    """owner(arm 0 = NOOP 팔) + 클래스 B 둘(arm 1, 2) + 클래스 A 하나(arm 3)."""
    own = _write_board_file(_board(owner_decs), td, "a0.jsonl")
    b1 = _write_board_file(_board([_CLASS_B_DECISION]), td, "a1.jsonl")
    b2 = _write_board_file(_board([_CLASS_B_DECISION]), td, "a2.jsonl")
    a3 = _write_board_file(_board([_CLASS_A_DECISION]), td, "a3.jsonl")
    return [("fault", 1, 0, own), ("fault", 1, 1, b1), ("fault", 1, 2, b2), ("fault", 1, 3, a3)]


def test_mixed_pool_class_a_is_representative_and_class_b_is_dropped():
    """(1) 클래스 A·B 가 섞인 (case,seed) 에서 NOOP 팔 판(arm 0)이 살아 있으면:
      · 대표는 **클래스 A 인 arm 3** 이다 — 그 판만 canonical 연속을 들고 있다.
      · 클래스 B(arm 1,2)는 **0개** — NOOP 판이 이미 그 세계를 들고 있다.
    3차 구현은 여기서 `{('fault',1): 1}` 을 내놨다(클래스 B 를 남기고 클래스 A 를 버림)."""
    with tempfile.TemporaryDirectory() as td:
        # owner 를 NOOP 팔 자리(arm 0)에 놓아 "성공한 판 중에 NOOP 팔 판이 있다"를 흉내낸다 —
        # 대표 억제는 그 판의 **클래스가 아니라 존재**(arm_id == noop_arm_id)만 본다(아래 assert
        # 가 그 배선을 검사한다). 편의상 클래스 B 픽스처(`_CLASS_B_DECISION`)를 재사용했을 뿐,
        # 실제 강제 NOOP 판은 이 모습이 **아니다** — run_demo.jl:354-355 가 `mac == "NOOP"`
        # 분기에서 `enact_applied = true` 를 무조건 세운다(NOOP 의 무동작 자체가 그 매크로의
        # 집행이다). 그래서 실제 NOOP 팔 판은 언제나 **클래스 A 또는 real** 이지 클래스 B 일 수
        # 없다.
        pool = _mixed_pool(td, [_CLASS_B_DECISION])
        rep_map = SG._pick_deviation_representatives(pool, {("fault", 1): 0}, NOOP_ARM_ID)
    assert rep_map == {("fault", 1): {"A": 3}}, rep_map
    assert "B" not in rep_map[("fault", 1)], rep_map


def test_mixed_pool_emission_class_a_emits_tail_and_class_b_emits_only_deviation_row():
    """(1-b) 위 꼬리 대표 선정을 `rows_to_samples` 까지 흘려서 **실제 방출**로 확인한다 —
    클래스 A 꼬리 대표는 `i >= k` 를 전부 내고, 꼬리 대표가 아닌 클래스 B 판은 **결정 k 행
    하나만** 낸다(2026-08-15 7차 이전에는 0행이었다)."""
    ds_a = [_decision(10, 2.0, 1000.0, macro="Replace", decision_index=1),
            _decision(50, 8.0, 40000.0, macro="Replace", decision_index=2, deviate_at=2,
                      deviate_arm="Replace", deviated=False, deviate_from="Replace",
                      deviate_valid=True, enact_applied=True),
            _decision(90, 15.0, 90000.0, macro="Replace", decision_index=3)]
    ds_b = [_decision(10, 2.0, 1000.0, macro="Replace", decision_index=1),
            _decision(50, 8.0, 40000.0, macro="ForbidZone", decision_index=2, deviate_at=2,
                      deviate_arm="ForbidZone", deviated=True, deviate_from="Replace",
                      deviate_valid=True, enact_applied=False),
            _decision(90, 15.0, 90000.0, macro="Replace", decision_index=3)]
    out_a, rep_a = _rows_to_samples_for_one_board(_board(ds_a), "fault", 1, 3, "Replace", 2,
                                                   is_owner=False, is_class_representative=True)
    out_b, rep_b = _rows_to_samples_for_one_board(_board(ds_b), "fault", 1, 1, "ForbidZone", 2,
                                                   is_owner=False, is_class_representative=False)
    assert [t["decision_index"] for t in out_a] == [2, 3], out_a
    assert rep_a["boards_class_a_representative"] == 1, rep_a
    assert [t["decision_index"] for t in out_b] == [2], out_b        # 결정 k 행 하나만
    assert out_b[0]["arm_name"] == "ForbidZone", out_b               # 그 판이 강제한 팔
    assert rep_b["boards_class_b_tail_dropped"] == 1, rep_b
    assert rep_b["class_b_tail_dropped_by_arm"]["ForbidZone"] == 1, \
        rep_b["class_b_tail_dropped_by_arm"]
    assert rep_b["deviation_rows_kept_from_suppressed"] == 1, rep_b
    assert rep_b["decisions_dropped_tail_dup"] == 1, rep_b           # decision_index 3


def test_two_class_b_boards_at_same_cell_give_two_distinct_arms():
    """(5, 2026-08-15 7차 — 이 사이클이 존재하는 이유) 같은 (case,seed,k) 의 클래스 B 판 둘이
    **서로 다른 팔**을 강제하면, 둘 다 꼬리 대표가 아니어도 그 칸에 **팔이 둘** 생긴다.
    보존된 588판의 실측(all_s11_a1/a2/a3, k=8 에 Replace/Deprioritize/ForbidZone)이 이 모양이다.

    6차까지는 두 판이 통째로 빠져 그 칸이 단일팔로 남았다 — §1-B(한 칸이 여러 팔을 본다)가
    27/49 → 23/48 로 안 움직인 원인이 정확히 이것이다.

    `c` 와 `next_cell` 이 **같다**는 것도 같이 못박는다: 둘 다 그 결정에서 무동작이라 세계가
    안 바뀌었으니 값이 같은 게 맞다. 그건 제조된 동점이 아니라 **진짜 동점**이고, 라벨이 달라
    `(cell, arm)` 버킷이 **갈리므로** `dp_solve._decide` 의 `se = std/√n` 도 안 흔들린다."""
    def _class_b_board(forced):
        return _board([_decision(10, 2.0, 1000.0, macro="NOOP", decision_index=1),
                       _decision(50, 8.0, 40000.0, macro=forced, decision_index=2, deviate_at=2,
                                 deviate_arm=forced, deviated=True, deviate_from="NOOP",
                                 deviate_valid=True, enact_applied=False),
                       _decision(90, 15.0, 90000.0, macro="NOOP", decision_index=3)])

    out1, _ = _rows_to_samples_for_one_board(_class_b_board("Replace"), "all", 11, 1,
                                             "Replace", 2, is_owner=False,
                                             is_class_representative=False)
    out2, _ = _rows_to_samples_for_one_board(_class_b_board("Deprioritize"), "all", 11, 2,
                                             "Deprioritize", 2, is_owner=False,
                                             is_class_representative=False)
    assert len(out1) == 1 and len(out2) == 1, (out1, out2)
    r1, r2 = out1[0], out2[0]
    assert r1["arm"] != r2["arm"], (r1["arm"], r2["arm"])          # 팔이 실제로 갈린다
    assert (r1["arm_name"], r2["arm_name"]) == ("Replace", "Deprioritize"), (r1, r2)
    assert r1["cell"] == r2["cell"], (r1["cell"], r2["cell"])      # 같은 칸
    assert r1["c"] == r2["c"], (r1["c"], r2["c"])                  # 무동작이라 구간비용이 같다
    assert r1["next_cell"] == r2["next_cell"], (r1["next_cell"], r2["next_cell"])
    # 그래서 이 칸의 (cell, arm) 버킷은 **둘**이다 — se 를 낮추는 같은 버킷 중복이 아니다.
    assert len({(r1["cell"], r1["arm"]), (r2["cell"], r2["arm"])}) == 2, (r1, r2)


def test_no_class_a_tail_representative_when_owner_itself_is_class_a():
    """(3) owner 자신이 클래스 A 면(= canonical 의 매크로가 그 결정에서 owner 의 강제 팔과
    같았다) owner 가 canonical 궤적을 `i=0` 부터 전부 내고 있으므로 클래스 A **꼬리** 대표를
    **하나도** 안 뽑는다 — 뽑으면 owner 꼬리의 정확한 복제가 된다.

    ★ 2026-08-15 7차: 그래도 그 비owner 클래스 A 판은 **결정 k 행 하나를 낸다**(예전엔 0행).
    그 행은 이 판이 k 에서 강제한 팔로 라벨되므로 owner 행과 같은 (칸,팔) 이 아니다.
    (실판에서 한 (case,seed) 에 클래스 A 판은 최대 하나라 이 배치 자체가 합성이지만, 규칙이
    꼬리에만 걸린다는 것을 이 자리에서 못박는다.)"""
    with tempfile.TemporaryDirectory() as td:
        own = _write_board_file(_board([_CLASS_A_DECISION]), td, "a0.jsonl")
        a3 = _write_board_file(_board([_CLASS_A_DECISION]), td, "a3.jsonl")
        a5 = _write_board_file(_board([_CLASS_A_DECISION]), td, "a5.jsonl")
        rep_map = SG._pick_deviation_representatives(
            [("fault", 1, 0, own), ("fault", 1, 3, a3), ("fault", 1, 5, a5)],
            {("fault", 1): 0}, NOOP_ARM_ID)
    assert rep_map == {}, rep_map
    # 그 결과 비owner 클래스 A 판은 결정 k 행만 내고 꼬리(decision_index 3)를 뺀다.
    ds = [_decision(10, 2.0, 1000.0, macro="Replace", decision_index=1),
          _decision(50, 8.0, 40000.0, macro="Replace", decision_index=2, deviate_at=2,
                    deviate_arm="Replace", deviated=False, deviate_from="Replace",
                    deviate_valid=True, enact_applied=True),
          _decision(90, 15.0, 90000.0, macro="Deprioritize", decision_index=3)]
    out, rep = _rows_to_samples_for_one_board(_board(ds), "fault", 1, 3, "Replace", 2,
                                               is_owner=False, is_class_representative=False)
    assert [t["decision_index"] for t in out] == [2], out
    assert out[0]["arm_name"] == "Replace", out
    assert rep["boards_class_a_tail_dropped"] == 1, rep
    assert rep["class_a_tail_dropped_by_arm"]["Replace"] == 1, rep["class_a_tail_dropped_by_arm"]
    assert rep["decisions_dropped_tail_dup"] == 1, rep
    assert rep["deviation_rows_kept_from_suppressed"] == 1, rep
    assert rep["deviation_rows_kept_by_arm"]["Replace"] == 1, rep["deviation_rows_kept_by_arm"]
    assert rep["boards_class_a_representative"] == 0, rep


def test_class_a_non_owner_emits_k_row_and_tail_when_owner_deviated():
    """(2) owner 가 실제로 갈린(real) (case,seed) 에서는 canonical 연속을 들고 있는 판이 클래스
    A 판뿐이라 그 판이 **꼬리 대표**가 되고, 결정 k 행 + 꼬리를 전부 낸다. 위 (3) 과 같은
    픽스처·같은 판인데 `is_class_representative` 만 다르다 = 갈리는 것이 꼬리뿐임을 보인다."""
    ds = [_decision(10, 2.0, 1000.0, macro="Replace", decision_index=1),
          _decision(50, 8.0, 40000.0, macro="Replace", decision_index=2, deviate_at=2,
                    deviate_arm="Replace", deviated=False, deviate_from="Replace",
                    deviate_valid=True, enact_applied=True),
          _decision(90, 15.0, 90000.0, macro="Deprioritize", decision_index=3)]
    out, rep = _rows_to_samples_for_one_board(_board(ds), "fault", 1, 3, "Replace", 2,
                                               is_owner=False, is_class_representative=True)
    assert [t["decision_index"] for t in out] == [2, 3], out
    assert [t["arm_name"] for t in out] == ["Replace", "Deprioritize"], out
    assert rep["boards_class_a_representative"] == 1, rep
    assert rep["class_a_representative_by_arm"]["Replace"] == 1, rep
    assert rep["boards_class_a_tail_dropped"] == 0, rep
    assert rep["decisions_dropped_tail_dup"] == 0, rep
    assert rep["deviation_rows_kept_from_suppressed"] == 0, rep


def test_class_b_representative_kept_when_noop_board_absent():
    """(3) NOOP 팔 판이 크래시해서 없으면 그 세계를 아무도 안 들고 있으므로 클래스 B 대표를
    **정확히 하나**(arm_id 최솟값) 남긴다."""
    with tempfile.TemporaryDirectory() as td:
        own = _write_board_file(_board([_REAL_DECISION]), td, "a1.jsonl")   # arm 0 은 없다
        b2 = _write_board_file(_board([_CLASS_B_DECISION]), td, "a2.jsonl")
        b8 = _write_board_file(_board([_CLASS_B_DECISION]), td, "a8.jsonl")
        pool = [("zone", 5, 8, b8), ("zone", 5, 1, own), ("zone", 5, 2, b2)]
        rep_absent = SG._pick_deviation_representatives(pool, {("zone", 5): 1}, NOOP_ARM_ID)
        # 대조군: 같은 풀에 NOOP 팔 자리(arm 0)의 판을 하나 넣으면 클래스 B 대표가 사라진다 —
        # 억제는 그 판의 클래스가 아니라 arm_id == noop_arm_id 라는 **존재**만 본다. 여기서도
        # 편의상 `_CLASS_B_DECISION` 을 재사용했을 뿐 — 실제 NOOP 팔 판은 클래스 B 가 될 수
        # 없다(run_demo.jl:354-355 가 NOOP 분기에서 `enact_applied = true` 를 무조건 세운다;
        # 위 test_mixed_pool_class_a_is_representative_and_class_b_is_dropped 참고).
        n0 = _write_board_file(_board([_CLASS_B_DECISION]), td, "a0.jsonl")
        rep_present = SG._pick_deviation_representatives(
            pool + [("zone", 5, 0, n0)], {("zone", 5): 0}, NOOP_ARM_ID)
    assert rep_absent == {("zone", 5): {"B": 2}}, rep_absent
    assert rep_present == {}, rep_present


def test_no_class_b_representative_when_owner_itself_is_class_b():
    """(3-b, 2026-08-17 5차) NOOP 판이 없어도 **owner 자신이 클래스 B** 면 대표를 두지 않는다 —
    owner 가 그 세계를 이미 `i=0` 부터 전부 내고 있어 대표가 owner 꼬리의 복제가 되기 때문이다.
    클래스 A 쪽의 owner 예외와 **같은 원칙**(그 세계를 이미 들고 있는 판이 있으면 대표를 안 둔다)
    의 다른 얼굴이다.

    대조군을 같은 테스트에 둔다: 판·풀·owner_arm 을 그대로 두고 **owner 판의 클래스만** 바꾸면
    (`_REAL_DECISION`) 대표가 정확히 하나(arm_id 최솟값) 생긴다 — 즉 이 예외가 "NOOP 판 없음"
    자체를 무력화하는 게 아니라 owner 클래스 하나에만 반응한다는 것을 보인다."""
    with tempfile.TemporaryDirectory() as td:
        own_b = _write_board_file(_board([_CLASS_B_DECISION]), td, "a1_b.jsonl")
        own_real = _write_board_file(_board([_REAL_DECISION]), td, "a1_real.jsonl")
        b2 = _write_board_file(_board([_CLASS_B_DECISION]), td, "a2.jsonl")
        b8 = _write_board_file(_board([_CLASS_B_DECISION]), td, "a8.jsonl")
        # arm 0(NOOP 팔) 은 크래시해서 풀에 없다. owner 는 arm 1.
        rep_owner_b = SG._pick_deviation_representatives(
            [("zone", 5, 8, b8), ("zone", 5, 1, own_b), ("zone", 5, 2, b2)],
            {("zone", 5): 1}, NOOP_ARM_ID)
        rep_owner_real = SG._pick_deviation_representatives(
            [("zone", 5, 8, b8), ("zone", 5, 1, own_real), ("zone", 5, 2, b2)],
            {("zone", 5): 1}, NOOP_ARM_ID)
    assert rep_owner_b == {}, rep_owner_b                        # (a) owner 가 B류 ⇒ 0개
    assert rep_owner_real == {("zone", 5): {"B": 2}}, rep_owner_real   # (b) 대조군 ⇒ 정확히 1개
    # 그 결과 비owner 클래스 B 판은 꼬리를 안 내지만 **결정 k 행은 낸다**(2026-08-15 7차).
    ds = [_decision(10, 2.0, 1000.0, macro="Replace", decision_index=1),
          _decision(50, 8.0, 40000.0, macro="ForbidZone", decision_index=2, deviate_at=2,
                    deviate_arm="ForbidZone", deviated=True, deviate_from="Replace",
                    deviate_valid=True, enact_applied=False),
          _decision(90, 15.0, 90000.0, macro="Replace", decision_index=3)]
    out, rep = _rows_to_samples_for_one_board(_board(ds), "zone", 5, 2, "Deprioritize", 2,
                                               is_owner=False, is_class_representative=False)
    assert [t["decision_index"] for t in out] == [2], out
    assert out[0]["arm_name"] == "ForbidZone", out          # 그 결정에서 실제 집행된 매크로
    assert rep["boards_class_b_tail_dropped"] == 1, rep
    assert rep["decisions_dropped_tail_dup"] == 1, rep
    assert rep["deviation_rows_kept_from_suppressed"] == 1, rep
    assert rep["boards_class_b_representative"] == 0, rep


def test_both_flags_false_is_class_a_and_not_double_counted():
    """(4) `deviated is False` 와 `enact_applied is False` 가 **둘 다** 참인 판은 클래스 A 다
    (A 우선 — 강제 대입 자체가 무변경이라 그 판은 canonical 이다). 두 클래스에 동시에 들어가
    중복 집계되지 않는다."""
    assert SG._deviation_class(_BOTH_FALSE_DECISION) == "A"
    with tempfile.TemporaryDirectory() as td:
        own = _write_board_file(_board([_REAL_DECISION]), td, "a0.jsonl")
        p3 = _write_board_file(_board([_BOTH_FALSE_DECISION]), td, "a3.jsonl")
        assert SG._board_deviation_status(p3) == "A"
        rep_map = SG._pick_deviation_representatives(
            [("fault", 6, 0, own), ("fault", 6, 3, p3)], {("fault", 6): 0}, NOOP_ARM_ID)
    # NOOP 판(arm 0)이 살아 있는데도 "B" 키가 안 생긴다 = 이 판은 B 로도 세어지지 않았다.
    assert rep_map == {("fault", 6): {"A": 3}}, rep_map
    # 방출 경로에서도 한 클래스로만 세어진다.
    ds = [_decision(10, 2.0, 1000.0, macro="Replace", decision_index=1),
          _decision(50, 8.0, 40000.0, macro="Replace", decision_index=2, deviate_at=2,
                    deviate_arm="Replace", deviated=False, deviate_from="Replace",
                    deviate_valid=True, enact_applied=False)]
    out, rep = _rows_to_samples_for_one_board(_board(ds), "fault", 6, 3, "Replace", 2,
                                               is_owner=False, is_class_representative=True)
    assert len(out) == 1, out
    assert rep["boards_class_a_representative"] == 1, rep
    assert rep["boards_class_b_representative"] == 0, rep
    assert rep["boards_class_b_tail_dropped"] == 0, rep


def test_mixed_pool_selection_is_order_independent():
    """(5) 섞인 풀에서도 대표 선정은 입력 순서에 의존하지 않는다 — `min()` 을 풀 전체에서
    취한다(도착 순서가 아니다)."""
    with tempfile.TemporaryDirectory() as td:
        pool = _mixed_pool(td, [_CLASS_B_DECISION])
        # 클래스 A 판을 하나 더 넣어 min() 이 실제로 고를 것이 있게 한다(arm 7).
        a7 = _write_board_file(_board([_CLASS_A_DECISION]), td, "a7.jsonl")
        pool = pool + [("fault", 1, 7, a7)]
        results = [SG._pick_deviation_representatives(order, {("fault", 1): 0}, NOOP_ARM_ID)
                   for order in (pool, list(reversed(pool)),
                                 [pool[3], pool[0], pool[4], pool[2], pool[1]])]
    assert results[0] == results[1] == results[2] == {("fault", 1): {"A": 3}}, results


def test_label_follows_enacted_macro_not_board_arm():
    """(f) 라벨은 그 결정에서 실제로 집행된 매크로(d["macro"])를 따른다 — 판에 넘긴
    arm_id/arm_name(여기서는 일부러 결정들의 macro 와 다른 값을 준다) 이 아니다."""
    ds = [_decision(10, 2.0, 1000.0, macro="ReformTeam", decision_index=1),
          _decision(50, 8.0, 40000.0, macro="Replace", decision_index=2),
          _decision(90, 15.0, 90000.0, macro="Deprioritize", decision_index=3)]
    # owner 판 호출인데 arm_id/arm_name 을 결정들의 macro 와 무관한 값(8/"SwapBattery")으로
    # 준다 — 라벨이 그걸 따라간다면 이 테스트가 바로 잡는다.
    out, rep = _rows_to_samples_for_one_board(_board(ds), "all", 1, 8, "SwapBattery", None,
                                               is_owner=True)
    assert len(out) == 3, out
    assert [t["arm_name"] for t in out] == ["ReformTeam", "Replace", "Deprioritize"], \
        [t["arm_name"] for t in out]
    assert [t["arm"] for t in out] == [4, 1, 2], [t["arm"] for t in out]
    assert not any(t["arm_name"] == "SwapBattery" for t in out), out


def test_unknown_macro_row_is_dropped_and_counted():
    """arm_menu() 밖의 이름이 집행됐으면 그 행만 버리고 이름별로 센다(Global Constraint 10)
    — 판 전체를 버리지 않는다(형제 결정은 정상적으로 남는다)."""
    ds = [_decision(10, 2.0, 1000.0, macro="NOOP", decision_index=1),
          _decision(50, 8.0, 40000.0, macro="TotallyUnknownMacro", decision_index=2),
          _decision(90, 15.0, 90000.0, macro="NOOP", decision_index=3)]
    out, rep = _rows_to_samples_for_one_board(_board(ds), "all", 1, 0, "NOOP", None,
                                               is_owner=True)
    assert len(out) == 2, out                              # 가운데 하나만 빠졌다
    assert [t["decision_index"] for t in out] == [1, 3], out
    assert rep["dropped_unknown_macro"]["TotallyUnknownMacro"] == 1, rep["dropped_unknown_macro"]


def test_run_board_env_wires_deviation_not_force_macro(tmp_path, monkeypatch):
    """`run_board` 가 DEMO_FORCE_MACRO 를 안 쓰고 DS_DEVIATE_AT/DS_DEVIATE_ARM/DS_HOTSWAP 을
    올바르게 배선하는지 실제 서브프로세스 없이 확인한다(subprocess.call 을 갈아 끼운다).

    DS_HOTSWAP 이 빠지면 fault 발화율이 100%->23% 로 **조용히** 무너진 전례가 이 레포에
    기록돼 있다(CLAUDE.md 2026-08-16) — 나머지 둘(DS_DEVIATE_AT/ARM)은 틀리면 policy.jl 이
    시끄럽게 죽지만 이건 아니라서 이 테스트가 있다."""
    captured = {}

    def fake_call(cmd, stdout=None, stderr=None, cwd=None, env=None):
        captured["env"] = env
        return 0

    monkeypatch.setattr(SG.subprocess, "call", fake_call)
    # DEMO_FORCE_MACRO 를 부모 환경에 미리 심어서 env.pop() 이 실제로 태우는지 본다 — 안 심어
    # 두면 "원래 없었다" 와 "지웠다" 를 구별할 수 없다.
    monkeypatch.setenv("DEMO_FORCE_MACRO", "StaleControlValue")

    p, k = SG.run_board("fault", 1, 1, "Replace", str(tmp_path), n_hint=8)
    env = captured["env"]
    assert env["DS_HOTSWAP"] == "1", env.get("DS_HOTSWAP")
    assert env["DS_DEVIATE_AT"] == str(k), env.get("DS_DEVIATE_AT")
    assert env["DS_DEVIATE_ARM"] == "Replace", env.get("DS_DEVIATE_ARM")
    assert "DEMO_FORCE_MACRO" not in env, env.get("DEMO_FORCE_MACRO")


# =====================================================================================
# 2026-08-17 최종 리뷰 Important 3·4 — 게이트가 자기 증거를 파괴하지 않는다 + 판별 매니페스트
# =====================================================================================

def test_fidelity_gate_runs_before_output_and_cleanup():
    """충실성 위반 시 exit 1 이 **표본 쓰기와 작업 디렉토리 삭제보다 먼저** 나야 한다.

    왜 소스 순서를 보나: 이 불변식은 `main()` 안의 **문장 순서** 그 자체이고, 실제로 위반을
    재현하려면 588판 표집을 굴려야 한다(51분·비가역). 예전 순서는 위반한 런이
    (1) 직전의 정상 `samples.jsonl` 을 덮어쓰고 (2) `--keep-work` 없으면 진단용 판 원자료까지
    지운 뒤에 죽는 것이었다 — 게이트가 자기 증거를 파괴했다. 순서가 되돌아가면 여기서 잡힌다."""
    import inspect
    src = inspect.getsource(SG.main)
    # 주석 안에도 같은 표현이 있으므로(왜 옮겼는지를 적어 둔 자리) **실제 호출 형태**로 찾는다.
    i_gate = src.index('sys.exit("분해 충실성 위반')
    i_write = src.index('with open(a.out, "w") as f:')
    i_rm = src.index("shutil.rmtree(a.work, ignore_errors=True)")
    assert i_gate < i_write, "충실성 게이트가 samples.jsonl 쓰기보다 뒤에 있다"
    assert i_gate < i_rm, "충실성 게이트가 작업 디렉토리 rmtree 보다 뒤에 있다"


def test_board_manifest_records_every_board_including_crashes(tmp_path):
    """`write_board_manifest` 는 판을 하나도 빠뜨리지 않고, 크래시 판을 완주 실패와 구분한다.

    판정 #1(표집 판 완주율)의 유일한 레포 내 근거가 이 파일이다 — `_sample_work/` 는
    gitignore 이고 `samples.jsonl` 로는 꼬리 중복 제거 때문에 판 목록이 복원되지 않는다."""
    work = tmp_path / "work"
    (work / "fault_s1_a1").mkdir(parents=True)
    (work / "fault_s1_a1" / "rows.jsonl").write_text(json.dumps({
        "complete": True, "closed": 10, "total": 10, "objective_hash": "x", "energy_objective": 1,
        "decisions": [{"decision_index": 1, "deviate_at": 3}, {"decision_index": 2}],
    }) + "\n")
    (work / "fault_s1_a4").mkdir(parents=True)          # 디렉토리는 있는데 rows 가 없다 = 크래시

    out = tmp_path / "boards.jsonl"
    n_ran, n_ok = SG.write_board_manifest(
        str(out), str(work), [("fault", 1, 1, "Replace"), ("fault", 1, 4, "ReformTeam")])

    recs = {r["board_id"]: r for r in map(json.loads, open(out))}
    assert set(recs) == {"fault_s1_a1", "fault_s1_a4"}, sorted(recs)
    assert (n_ran, n_ok) == (1, 1), (n_ran, n_ok)       # 크래시 판은 #1 의 분모에서 빠진다
    ok = recs["fault_s1_a1"]
    assert ok["crashed"] is False and ok["complete"] is True
    assert ok["n_decisions"] == 2 and ok["arm_name"] == "Replace"
    assert ok["deviate_at"] == 3                        # 판이 실제로 발화한 k 를 쓴다
    bad = recs["fault_s1_a4"]
    assert bad["crashed"] is True and bad["complete"] is None
