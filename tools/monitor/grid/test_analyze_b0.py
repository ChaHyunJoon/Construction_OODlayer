"""analyze_b0.classify 계약(T10a). 실행: .venv/bin/python -m pytest tools/monitor/grid/test_analyze_b0.py -q"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import analyze_b0 as A  # noqa: E402


def test_classify_outcomes_and_unknown_causes():
    ok = {"status": "scored", "timeout": False}
    assert A.classify(ok, {"terminal_reason": "project_complete"}) == ("COMPLETE", None)
    assert A.classify(ok, {"terminal_reason": "no_progress_limit"}) == ("FAIL_WITHIN_BUDGET", None)
    assert A.classify(ok, {"terminal_reason": "max_sim_steps"}) == ("FAIL_WITHIN_BUDGET", None)
    # 시한초과는 terminal 이 있어도 UNKNOWN(설계 §7.1 — simulation failure 가 아니다)
    assert A.classify({"status": "timeout", "timeout": True}, {"terminal_reason": "no_progress_limit"}) == ("UNKNOWN", "wall_timeout")
    assert A.classify({}, {}) == ("UNKNOWN", "missing")
    assert A.classify({"status": "error:fingerprint_drift"}, {}) == ("UNKNOWN", "driver:error:fingerprint_drift")
    # 채점 안 된 판은 terminal 이 있어도 UNKNOWN — 지문이 다른 세계(ctx_mismatch)·스트림 없음을 결과로 세지 않는다
    done = {"terminal_reason": "project_complete"}
    assert A.classify({"status": "error:ctx_mismatch"}, done) == ("UNKNOWN", "driver:error:ctx_mismatch")
    assert A.classify({"status": "error:stream_missing"}, done) == ("UNKNOWN", "driver:error:stream_missing")
    assert A.classify({"status": "error", "rc": 3}, done) == ("UNKNOWN", "driver:error")
    # driver(하니스) 실패는 시한초과로 오표기하지 않는다
    assert A.classify({"status": "timeout", "timeout": True}, {}, "ArgumentError: …") == ("UNKNOWN", "harness_failure")
    # 종료 사유 없는 terminal(atexit 기록) 은 crash — COMPLETE 로 접지 않는다
    assert A.classify(ok, {"terminal_reason": "none", "complete": True}) == ("UNKNOWN", "worker_crash")


def test_manifest_build_mismatches_names_differing_fields():
    build = {"code_rev": "r", "code_dirty_digest": "d", "config_digest": "c", "julia_version": "1.10.11", "manifest_digest": "m",
             "build_id": "b", "julia_threads": 1, "solver": {"name": "HiGHS", "version": "1.23.0", "seed": 0, "threads": 0}}
    fp = {"code_rev": "r", "code_dirty_digest": "d", "config_digest": "c", "julia_version": "1.10.11", "manifest_digest": "m",
          "build_id": "b", "julia_threads": 1, "solver_name": "HiGHS", "solver_version": "1.23.0", "solver_seed": 0, "solver_threads": 0}
    assert A.manifest_build_mismatches(build, fp) == []
    assert A.manifest_build_mismatches(build, dict(fp, code_rev="x", solver_threads=4)) == ["code_rev", "solver_threads"]
    assert A.manifest_build_mismatches(build, None) is None


def test_general_recovery_reads_recovery_keys_only():
    ab = A.ablation("level=all armed=true denied=0 exempt=4 ladder_zone_skipped=0 ladder_zone_fired=0 "
                    "detail=exempt:monitor_record=1,recovery:unwedge_nominal:force_snapped=2,recovery:unwedge_nominal:no_team=1")
    assert A.general_recovery(ab) == {"recovery:unwedge_nominal:force_snapped": 2, "recovery:unwedge_nominal:no_team": 1}
    assert A.general_recovery(None) == {}
