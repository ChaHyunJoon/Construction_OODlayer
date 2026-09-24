"""build_sweep_dataset.py 의 정지 서명·스트림 뿌리·분모·attempts 분류 (Task 7). 고정문만 쓴다.

실행: (repo 루트에서) `.venv/bin/python -m pytest tools/monitor/test_build_sweep_dataset.py -q`

🔴 왜 (2026-09-22 실측): 미완주 183판 중 177판이 `No progress for N iterations` 로 끝났고
라인 정지·reform 예산 소진은 0판이었다. `fail_mode` 두 범주로는 그 셋을 못 가른다.
🔴 왜 (2026-09-23 리뷰): 채점 전에 죽은 판이 분모에서 사라졌고(`[score]` 없는 로그를 건너뛰었다),
다른 시드의 스트림 파일을 옛 이름 fallback 으로 주워 읽을 수 있었다.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import build_sweep_dataset as B  # noqa: E402

SCORE = "[score] complete=false closed=120 n_blocked=0 project_blocked=false n_zones=1\n"
SCORE_OK = "[score] complete=true closed=305 n_zones=1 n_blocked=0 project_blocked=false\n"
CTX = {"campaign_id": "c1", "model": "tractor", "seed": 3, "zone_seed": 3, "event": "none",
       "zone": True, "code_rev": "r" * 40, "code_dirty_digest": "d" * 16,
       "config_digest": "f" * 16, "config_env": {"ZONE_RESCUE": "1"}}


def _ctx_line(**over):
    return "[run-ctx] " + json.dumps(dict(CTX, **over)) + "\n"


def _frame(sim_t=12.0, ood=None, robots=None, n_closed=10, history=None):
    return {"sim_t": sim_t, "battery": {}, "ood": ood or [], "robots": robots or [],
            "n_closed": n_closed, "respec_history": history or []}


def _write_stream(path, frames):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(f) + "\n" for f in frames))


# ---- 계획서 예시 ---------------------------------------------------------------------------
def test_stop_signature_reads_the_three_markers():
    txt = ("┌ Warning: [RESPEC] FALLBACK engaged: holding all agents (line stop).\n"
           "┌ Warning: No progress for 3000 iterations. Terminating.\n"
           "[reform] attempt 1/3\n[reform] attempt 3/3\n")
    assert B.stop_signature(txt) == ["line_stop", "stall", "reform_limit_reached"]


def test_reform_below_budget_is_not_a_budget_stop():
    assert B.stop_signature("[reform] attempt 2/3\n") == []


def test_collect_reads_logs_and_streams_under_a_given_root(tmp_path):
    grid = tmp_path / "grid"
    (grid / "log").mkdir(parents=True)
    (grid / "log" / "canonical__zone__s3.log").write_text(
        "n_total: 305\n┌ Warning: No progress for 3000 iterations. Terminating.\n" + SCORE)
    (grid / "streams").mkdir()
    (grid / "streams" / "tractor__canonical_zone_s3_z3.jsonl").write_text(
        json.dumps({"sim_t": 12.0, "battery": {}, "ood": []}) + "\n")
    runs, totals = B.collect([str(grid)], "tractor", root=str(grid))
    assert len(runs) == 1
    r = runs[0]
    assert r["stop_sig"] == ["stall"]
    assert r["fail_mode"] == "world_deadlock"           # 옛 범주는 그대로
    assert r["stream"] == "streams/tractor__canonical_zone_s3_z3.jsonl"
    assert r["sim_seconds"] == 12.0
    assert totals[305] == 1


# ---- 추가 수락 조건: reform 표지는 관측 표지다 ----------------------------------------------
def test_reform_limit_reached_can_still_complete(tmp_path):
    grid = tmp_path / "g"
    (grid / "log").mkdir(parents=True)
    (grid / "log" / "canonical__fault__s2.log").write_text(
        "n_total: 305\n[reform] attempt 3/3\n[reform] recover=snapped\n" + SCORE_OK)
    runs, _ = B.collect([str(grid)], "tractor", root=str(grid))
    r = runs[0]
    assert r["complete"] is True and r["fail_mode"] is None
    assert r["stop_sig"] == ["reform_limit_reached"]
    assert r["reform_exhausted"] is None                # 이 로그의 엔진은 소진 표지를 모른다


def test_reform_exhausted_needs_the_explicit_marker(tmp_path):
    grid = tmp_path / "g"
    (grid / "log").mkdir(parents=True)
    (grid / "log" / "canonical__zone__s1.log").write_text(
        _ctx_line() + "n_total: 305\n[reform] attempt 3/3\n"
        "[reform] budget exhausted 3/3 at closed=120 — further alarms ignored\n" + SCORE)
    (grid / "log" / "canonical__zone__s2.log").write_text(
        _ctx_line(seed=2) + "n_total: 305\n[reform] attempt 3/3\n" + SCORE)
    runs, _ = B.collect([str(grid)], "tractor", root=str(grid))
    ex = {r["seed"]: r["reform_exhausted"] for r in runs}
    assert ex == {1: True, 2: False}                    # 표지를 아는 엔진(run-ctx 에 config_env)


# ---- null 을 false 로 접지 않는다 -------------------------------------------------------------
def test_unavailable_blockage_is_not_folded_into_world_deadlock(tmp_path):
    grid = tmp_path / "g"
    (grid / "log").mkdir(parents=True)
    (grid / "log" / "canonical__zone__s1.log").write_text(
        "n_total: 305\n[score] complete=false closed=100 n_zones=1 zone_blockage=unavailable\n")
    runs, _ = B.collect([str(grid)], "tractor", root=str(grid))
    r = runs[0]
    assert r["n_blocked"] is None and r["project_blocked"] is None
    assert r["fail_mode"] == "unresolved"


# ---- 분모: 채점 전 죽은 판·timeout·누락·다른 시드 -------------------------------------------
def _jobs(grid, keys, **ctx):
    """campaign.py 가 쓰는 jobs.jsonl 모양(판마다 정확한 스트림 경로와 기대 run_ctx)."""
    with open(grid / "jobs.jsonl", "w") as f:
        for lane, case, seed in keys:
            zs = seed
            stream = str(grid / "streams" / ("tractor__%s_%s%s_z%d.jsonl"
                                             % (lane, case, "" if seed == 1 else "_s%d" % seed, zs)))
            f.write(json.dumps({
                "run_key": "%s__%s__s%d" % (lane, case, seed), "lane": lane, "case": case,
                "seed": seed, "zone_seed": zs, "stream": stream,
                "log": str(grid / "log" / ("%s__%s__s%d.log" % (lane, case, seed))),
                "expect_ctx": dict({"seed": seed, "zone_seed": zs, "model": "tractor",
                                    "campaign_id": "c1"}, **ctx)}) + "\n")


def _runs_jsonl(grid, recs):
    with open(grid / "runs.jsonl", "w") as f:
        for r in recs:
            f.write(json.dumps(r) + "\n")


def test_jobs_mode_keeps_every_planned_key_in_the_denominator(tmp_path):
    grid = tmp_path / "g"
    (grid / "log").mkdir(parents=True)
    keys = [("canonical", "zone", 1), ("canonical", "zone", 2), ("canonical", "zone", 3),
            ("canonical", "zone", 4)]
    _jobs(grid, keys)
    # s1: 채점됨 · s2: 채점 전 죽음(rc=1) · s3: timeout · s4: 로그 없음
    (grid / "log" / "canonical__zone__s1.log").write_text(_ctx_line(seed=1, zone_seed=1)
                                                           + "n_total: 305\n" + SCORE)
    _write_stream(grid / "streams" / "tractor__canonical_zone_z1.jsonl", [_frame()])
    (grid / "log" / "canonical__zone__s2.log").write_text(_ctx_line(seed=2, zone_seed=2)
                                                           + "ERROR: LoadError: boom\n")
    (grid / "log" / "canonical__zone__s3.log").write_text(_ctx_line(seed=3) + "n_total: 305\n")
    _runs_jsonl(grid, [{"run_key": "canonical__zone__s2", "rc": 1, "timeout": False},
                       {"run_key": "canonical__zone__s3", "rc": 124, "timeout": True}])
    runs, unscored, den = B.collect_jobs(str(grid))
    assert [r["seed"] for r in runs] == [1]
    st = {u["run_key"]: u["status"] for u in unscored}
    assert st == {"canonical__zone__s2": "error", "canonical__zone__s3": "timeout",
                  "canonical__zone__s4": "missing"}
    d = den[("canonical", "zone")]
    assert (d["planned"], d["executed"], d["scored"], d["complete"], d["timeout"], d["error"],
            d["missing"]) == (4, 3, 1, 0, 1, 1, 1)


def test_jobs_mode_never_reads_another_seeds_stream(tmp_path):
    grid = tmp_path / "g"
    (grid / "log").mkdir(parents=True)
    _jobs(grid, [("canonical", "zone", 3)])
    (grid / "log" / "canonical__zone__s3.log").write_text(_ctx_line() + "n_total: 305\n" + SCORE)
    # 이 판의 스트림(_s3_z3)은 없고 옛 규약 이름(_z3)과 시드 1 이름만 있다 — 주워 오면 안 된다.
    _write_stream(grid / "streams" / "tractor__canonical_zone_z3.jsonl", [_frame(sim_t=99.0)])
    _write_stream(grid / "streams" / "tractor__canonical_zone.jsonl", [_frame(sim_t=98.0)])
    runs, unscored, den = B.collect_jobs(str(grid))
    assert runs == []
    assert unscored[0]["status"] == "error:stream_missing"
    assert den[("canonical", "zone")]["error"] == 1


def test_jobs_mode_ctx_mismatch_is_an_error(tmp_path):
    grid = tmp_path / "g"
    (grid / "log").mkdir(parents=True)
    _jobs(grid, [("canonical", "zone", 3)])
    (grid / "log" / "canonical__zone__s3.log").write_text(_ctx_line(seed=1)   # DEMO_SEED 가 샜다
                                                           + "n_total: 305\n" + SCORE)
    _write_stream(grid / "streams" / "tractor__canonical_zone_s3_z3.jsonl", [_frame()])
    runs, unscored, _ = B.collect_jobs(str(grid))
    assert runs == [] and unscored[0]["status"] == "error:ctx_mismatch"
    assert "seed" in unscored[0]["detail"]


def test_jobs_mode_fingerprint_drift_from_the_driver_is_kept(tmp_path):
    grid = tmp_path / "g"
    (grid / "log").mkdir(parents=True)
    _jobs(grid, [("canonical", "zone", 3)])
    _runs_jsonl(grid, [{"run_key": "canonical__zone__s3", "rc": None, "timeout": False,
                        "status": "error:fingerprint_drift"}])
    runs, unscored, den = B.collect_jobs(str(grid))
    assert unscored[0]["status"] == "error:fingerprint_drift"
    assert den[("canonical", "zone")]["executed"] == 0


def test_legacy_planned_keys_follow_the_lane_case_seed_arguments():
    keys = B.planned_keys(["canonical", "surrogate"], ["zone"], [1, 2])
    assert keys == {("canonical", "zone", 1), ("canonical", "zone", 2),
                    ("surrogate", "zone", 1), ("surrogate", "zone", 2)}


# ---- attempts 는 LM 호출 수가 아니다 ----------------------------------------------------------
def test_attempts_are_split_by_roundtrip_wrote_install_and_enactment():
    hist = [{"attempts": [
        {"roundtrip": "ok", "wrote": True, "install_why": None, "steps": ["a:success"],
         "steps_ref": None},
        {"roundtrip": "ok", "wrote": True, "install_why": "bad schema", "steps": None,
         "steps_ref": None},
        {"roundtrip": "ok", "wrote": False, "install_why": None, "steps": None,
         "steps_ref": None},
        {"roundtrip": "failed:timeout", "wrote": None, "install_why": None, "steps": None,
         "steps_ref": None},
        {"roundtrip": "not_requested", "wrote": None, "install_why": None, "steps": None,
         "steps_ref": None},
        {"roundtrip": "skipped_not_rewritable", "wrote": None, "install_why": None,
         "steps": None, "steps_ref": None},
        {"roundtrip": "ok", "wrote": True, "install_why": None, "steps": None,
         "steps_ref": "respec.steps"}]}]
    a = B.attempt_counts(hist)
    assert a == {"attempts_total": 7, "rewrite_roundtrip_ok": 4, "rewrite_roundtrip_failed": 1,
                 "rewrite_not_requested": 1, "rewrite_skipped_not_rewritable": 1,
                 "rewrite_wrote": 3, "rewrite_wrote_false": 1, "rewrite_wrote_null": 0,
                 "rewrite_installed": 2, "rewrite_install_rejected": 1,
                 "rewrite_enacted": 2, "rewrite_roundtrip_null": 0,
                 "rewrite_wrote_not_installed": 0}


# ---- OOD 실제 발생 · 초기 상태 지문 · restage 상태 -----------------------------------------
def test_ood_events_and_initial_state_fingerprint(tmp_path):
    rob = [{"id": "R1", "pos": [0.123456, 1.0], "soc": 0.98765}]
    ood = [{"kind": "fault", "at": 40, "target": "R1"}, {"kind": "zone", "at": None,
                                                         "zone": "zone_blk_1"}]
    p1, p2, p3 = tmp_path / "a.jsonl", tmp_path / "b.jsonl", tmp_path / "c.jsonl"
    _write_stream(p1, [_frame(robots=rob, n_closed=5), _frame(ood=ood)])
    _write_stream(p2, [_frame(robots=rob, n_closed=5), _frame(ood=ood[:1])])
    _write_stream(p3, [_frame(robots=[dict(rob[0], soc=0.5)], n_closed=5), _frame(ood=ood)])
    f1, f2, f3 = (B.stream_facts(str(p)) for p in (p1, p2, p3))
    assert f1["init_fp"] == f2["init_fp"] != f3["init_fp"]
    assert f1["ood_events"] == [{"kind": "fault", "at": 40, "target": "R1"},
                                {"kind": "zone", "at": None, "target": "zone_blk_1"}]
    assert f1["ood_fp"] != f2["ood_fp"]


def test_armed_line_gives_the_intended_ood_and_all3_reach():
    armed = (">>> OOD armed: zone×1 [blocking, pre-sim] + fault/battery×2 [stochastic seed=4, "
             "step-window draw]  model=tractor.mpd scale=0.008 robots=10\n")
    exp = B.ood_intended(armed)
    assert exp == {"zone": 1, "robot_kinds": ["fault", "battery"], "n_robot": 2, "seed": 4}
    assert B.ood_reached(exp, {"zone": 1, "fault": 1, "battery": 1}) is True
    assert B.ood_reached(exp, {"zone": 1, "fault": 1}) is False
    assert B.ood_intended("no armed line\n") is None


def test_restage_statuses_are_read_from_warn_and_info_lines():
    txt = ("┌ Warning: [RESPEC] restage_all infeasible (moved 0, failed 2) -> fallback\n"
           "[ Info: [RESPEC] restage_all residual_blocked (residual 1) -> whole-build translate\n")
    assert B.restage_statuses(txt) == ["infeasible", "residual_blocked"]
    assert B.restage_statuses("") == []


# ---- [ablation] 줄 → 판 레코드 ablation (Task 9) --------------------------------------------
def test_parse_log_reads_ablation_line():
    import build_sweep_dataset as B
    txt = ("[score] complete=true closed=287 n_zones=1 n_blocked=0 n_nav_goals=40 n_engulfed=0 "
           "n_agent_trapped=0 project_blocked=false\n"
           "[ablation] level=all armed=true denied=2 exempt=5 ladder_zone_skipped=1 ladder_zone_fired=0 "
           "detail=denied:translate_whole_build!=2,exempt:policy_payload=5,ladder_zone_skipped=1\n")
    r = B.parse_log(txt, "router", "zone", 1)
    assert r["ablation"] == {"level": "all", "armed": True, "denied": 2, "exempt": 5,
                             "ladder_zone_skipped": 1, "ladder_zone_fired": 0,
                             "detail": "denied:translate_whole_build!=2,exempt:policy_payload=5,ladder_zone_skipped=1"}


def test_parse_log_without_ablation_line_is_none_not_zero():
    import build_sweep_dataset as B
    r = B.parse_log("[score] complete=false closed=10 n_zones=1 zone_blockage=unavailable\n", "router", "zone", 1)
    assert r["ablation"] is None


def test_installed_requires_a_reenactment_and_null_roundtrip_has_a_bucket():
    # 최종 리뷰 M3(→ Important 재등급): `install_why` 는 처음부터 nothing 이라, 설치 없이 돌아온 칸
    # (impl_code 가 문자열이 아닌 판 — enact.jl `_rewrite_once`)도 "설치됨" 으로 셌다.
    hist = [{"attempts": [
        {"roundtrip": "ok", "wrote": True, "install_why": None, "steps": None, "steps_ref": None},
        {"roundtrip": None, "wrote": None, "install_why": None, "steps": None, "steps_ref": None}]}]
    a = B.attempt_counts(hist)
    assert a["rewrite_wrote"] == 1 and a["rewrite_installed"] == 0
    assert a["rewrite_wrote_not_installed"] == 1
    assert a["rewrite_roundtrip_null"] == 1
    assert (a["rewrite_roundtrip_ok"] + a["rewrite_roundtrip_failed"] + a["rewrite_not_requested"]
            + a["rewrite_skipped_not_rewritable"] + a["rewrite_roundtrip_null"]) == a["attempts_total"]


def test_parse_log_lifts_repair_ablation_into_run_ctx():
    """최종 리뷰 I2: 판 레코드의 run_ctx 가 팔 신원을 싣는다(없던 옛 판은 None — none 으로 접지 않는다)."""
    import build_sweep_dataset as B
    txt = _ctx_line(repair_ablation="translate") + SCORE
    assert B.parse_log(txt, "router", "zone", 3)["run_ctx"]["repair_ablation"] == "translate"
    assert B.parse_log(_ctx_line() + SCORE, "router", "zone", 3)["run_ctx"]["repair_ablation"] is None
