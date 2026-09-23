"""grid/campaign.py 계약 시험 (Task 6b Step 3 · 6c · 7). julia·서비스 없이 순수 함수만 잰다.

실행: (repo 루트에서) `.venv/bin/python -m pytest tools/monitor/grid/test_campaign.py -q`
"""
import json
import os
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import campaign as C  # noqa: E402
import manifest_to_verify_args as M  # noqa: E402

CLASSES = {"result": ["RESTAGE_ZONE_MARGIN_FRAC", "DEMO_ANIM", "DSPY_URL", "ZONE_RESCUE"],
           "cell_axis": ["DEMO_SEED", "DEMO_ZONE_SEED", "DEMO_OOD", "DEMO_ZONE", "DEMO_POLICY",
                         "DEMO_ROUTER", "DEMO_MODEL", "DEMO_SYNTH_FIXTURE", "DEMO_CASE_TAG",
                         "DEMO_CAMPAIGN_ID", "MONITOR_RUN_ID", "DEMO_OOD_SEED"],
           "observational": ["DEMO_OUT_DIR", "NAV_DEBUG"],
           "prefixes": ["DEMO_", "DS_", "DSPY_", "TOOL_SYNTH", "SYNTH_"]}
CAMP = {"campaign_id": "c1", "model": "tractor.mpd", "model_base": "tractor",
        "code_rev": "r" * 40, "code_dirty_digest": "d" * 16, "config_digest": "f" * 16,
        "classes": CLASSES,
        "set_env": {"RESTAGE_ZONE_MARGIN_FRAC": "0.5", "DEMO_ANIM": "0",
                    "DSPY_URL": "http://127.0.0.1:8095", "DS_HOTSWAP": "1"}}


def _job(case, seed, lane="canonical", grid="/g"):
    return C.plan_jobs(CAMP, grid, [lane], [case], [seed])[0]


# ---- 판 env: 상속을 지우고 manifest 값만 다시 넣는다 -------------------------------------------
def test_run_env_strips_inherited_cell_and_fixture_variables():
    parent = {"PATH": "/bin", "HOME": "/h", "DEMO_ZONE": "1", "DEMO_SYNTH_FIXTURE": "/f.json",
              "MONITOR_RUN_ID": "old", "DEMO_OOD": "zone", "ZONE_RESCUE": "0",
              "DS_OTHER": "x", "NAV_DEBUG": "1", "SYNTH_RECORD_LOG": "/l"}
    env = C.run_env(CAMP, _job("battery", 4), parent, "/g")
    assert env["PATH"] == "/bin" and env["HOME"] == "/h"
    for k in ("DEMO_SYNTH_FIXTURE", "ZONE_RESCUE", "DS_OTHER", "NAV_DEBUG", "SYNTH_RECORD_LOG"):
        assert k not in env, k
    assert env["DEMO_ZONE"] == "0" and env["DEMO_OOD"] == "battery"
    assert env["DEMO_SEED"] == "4" and env["DEMO_ZONE_SEED"] == "4"
    assert env["MONITOR_RUN_ID"] == "canonical__battery__s4"
    assert env["RESTAGE_ZONE_MARGIN_FRAC"] == "0.5" and env["DS_HOTSWAP"] == "1"
    assert env["DEMO_CAMPAIGN_ID"] == "c1" and env["DEMO_OUT_DIR"] == "/g"
    assert env["DEMO_CASE_TAG"] == "canonical_battery"


def test_zone_cells_carry_demo_seed_explicitly():
    env = C.run_env(CAMP, _job("zone", 7), {}, "/g")
    assert env["DEMO_SEED"] == "7" and env["DEMO_ZONE_SEED"] == "7"
    assert env["DEMO_OOD"] == "none" and env["DEMO_ZONE"] == "1"


@pytest.mark.parametrize("lane,router,policy", [("canonical", "0", "canonical"),
                                                ("surrogate", "0", "surrogate"),
                                                ("router", "1", "canonical")])
def test_lane_variables(lane, router, policy):
    env = C.run_env(CAMP, _job("all3", 2, lane), {}, "/g")
    assert (env["DEMO_ROUTER"], env["DEMO_POLICY"]) == (router, policy)
    assert env["DEMO_OOD"] == "fault_battery" and env["DEMO_ZONE"] == "1"


# ---- jobs manifest: 정확한 스트림 이름 · 기대 run_ctx ----------------------------------------
def test_stream_name_follows_render_demo_suffix_rule():
    assert C.stream_name("tractor", "canonical", "zone", 1, 1) == "tractor__canonical_zone_z1.jsonl"
    assert C.stream_name("tractor", "router", "all3", 3, 3) == "tractor__router_all3_s3_z3.jsonl"


def test_plan_jobs_expect_ctx_and_lm_expectation():
    jobs = C.plan_jobs(CAMP, "/g", ["surrogate", "router"], ["zone", "battery"], [1, 2])
    assert len(jobs) == 8 and len({j["run_key"] for j in jobs}) == 8
    j = [x for x in jobs if x["run_key"] == "router__zone__s2"][0]
    assert j["stream"] == "/g/streams/tractor__router_zone_s2_z2.jsonl"
    assert j["log"] == "/g/log/router__zone__s2.log"
    assert j["expect_ctx"] == {"campaign_id": "c1", "model": "tractor", "seed": 2,
                               "zone_seed": 2, "event": "none", "zone": True,
                               "lane": "router", "case": "router_zone",
                               "code_rev": "r" * 40, "code_dirty_digest": "d" * 16,
                               "config_digest": "f" * 16}
    assert j["lm_expected"] is True
    assert [x for x in jobs if x["run_key"] == "router__battery__s1"][0]["lm_expected"] is False
    assert [x for x in jobs if x["run_key"] == "surrogate__zone__s1"][0]["lm_expected"] is False


def test_ctx_check_reports_every_mismatch():
    j = _job("zone", 3)
    ctx = dict(j["expect_ctx"], seed=1, config_digest="0" * 16)
    bad = C.ctx_check(ctx, j["expect_ctx"])
    assert any(b.startswith("seed") for b in bad) and any(b.startswith("config_digest")
                                                           for b in bad)
    assert C.ctx_check(dict(j["expect_ctx"]), j["expect_ctx"]) == []
    assert C.ctx_check(None, j["expect_ctx"]) == ["run_ctx absent"]


def test_log_status_classifies_a_finished_run(tmp_path):
    j = _job("zone", 3, grid=str(tmp_path))
    os.makedirs(os.path.dirname(j["stream"]))
    ctx_line = "[run-ctx] " + json.dumps(j["expect_ctx"]) + "\n"
    score = "[score] complete=false closed=10 n_zones=1\n"
    assert C.log_status(ctx_line + score, j, rc=1, timed_out=False)[0] == "error:stream_missing"
    with open(j["stream"], "w") as f:
        f.write(json.dumps({"sim_t": 1.0}) + "\n")
    assert C.log_status(ctx_line + score, j, rc=1, timed_out=False)[0] == "scored"
    assert C.log_status(ctx_line, j, rc=124, timed_out=True)[0] == "timeout"
    assert C.log_status(ctx_line, j, rc=1, timed_out=False)[0] == "error"
    bad_ctx = "[run-ctx] " + json.dumps(dict(j["expect_ctx"], seed=1)) + "\n"
    assert C.log_status(bad_ctx + score, j, rc=1, timed_out=False)[0] == "error:ctx_mismatch"


# ---- 코드 지문: policy.jl `_code_dirty_digest` 와 같은 알고리즘 ----------------------------
def _git(repo, *args):
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t",
                    "-c", "commit.gpgsign=false", *args], check=True, capture_output=True)


def test_tree_digest_tracks_diffs_and_untracked_sources_only(tmp_path):
    repo = tmp_path / "r"
    (repo / "src").mkdir(parents=True)
    _git(repo, "init", "-q")
    (repo / "src" / "a.jl").write_text("x = 1\n")
    _git(repo, "add", "-A"); _git(repo, "commit", "-qm", "init")
    assert C.tree_digest(str(repo)) == ""
    (repo / "src" / "data.json").write_text("{}")             # 소스 확장자가 아니다
    assert C.tree_digest(str(repo)) == ""
    (repo / "src" / "new.jl").write_text("y = 2\n")
    d1 = C.tree_digest(str(repo))
    assert len(d1) == 16
    (repo / "src" / "new.jl").write_text("y = 3\n")
    d2 = C.tree_digest(str(repo))
    assert d2 not in ("", d1)
    (repo / "src" / "new.jl").unlink()
    (repo / "src" / "a.jl").write_text("x = 2\n")
    assert C.tree_digest(str(repo)) not in ("", d1, d2)


def test_tree_digest_equals_the_julia_algorithm_on_a_known_input(tmp_path):
    # policy.jl `_code_dirty_digest`: sha256(diff bytes, then per untracked file
    # "\0untracked\0<path>\0" + contents)[:16] — 같은 입력을 손으로 해시해 대조한다.
    import hashlib
    repo = tmp_path / "r"
    (repo / "tools").mkdir(parents=True)
    _git(repo, "init", "-q")
    (repo / "tools" / "a.py").write_text("a = 1\n")
    _git(repo, "add", "-A"); _git(repo, "commit", "-qm", "init")
    (repo / "tools" / "a.py").write_text("a = 2\n")
    (repo / "tools" / "b.sh").write_text("echo b\n")
    diff = subprocess.run(["git", "-C", str(repo), "diff", "--no-color", "--no-ext-diff", "HEAD",
                           "--", "src", "tools", "test", "Project.toml", "Manifest.toml"],
                          capture_output=True, check=True).stdout
    h = hashlib.sha256(diff)
    h.update(b"\0untracked\0tools/b.sh\0")
    h.update(b"echo b\n")
    assert C.tree_digest(str(repo)) == h.hexdigest()[:16]


# ---- Task 9 의 얇은 도구 --------------------------------------------------------------------
def test_manifest_to_verify_args_lines(tmp_path):
    p = tmp_path / "jobs.jsonl"
    jobs = C.plan_jobs(CAMP, "/g", ["router"], ["zone", "battery"], [3])
    p.write_text("".join(json.dumps(j) + "\n" for j in jobs))
    lines = list(M.lines(str(p)))
    assert len(lines) == 2
    z = [l for l in lines if l.startswith("router__zone__s3\t")][0].split("\t")
    assert z[1] == "/g/streams/tractor__router_zone_s3_z3.jsonl"
    assert "--expect-ctx seed=3" in z[2] and "--expect-ctx model=tractor" in z[2]
    assert "--expect-ctx campaign_id=c1" in z[2] and "--expect-ctx config_digest=" in z[2]
    assert "--expect-ctx zone_seed=3" in z[2] and "--expect-ctx event=none" in z[2]
    assert z[3] == "--require-decisions 1"
    b = [l for l in lines if l.startswith("router__battery__s3\t")][0].split("\t")
    assert b[3] == ""


# ---- 최종 리뷰 I1: 서비스 표류는 판마다 잰다 --------------------------------------------------
HEALTH = {"status": "ok", "policy": "dspy:gpt-4o", "code_fingerprint": "72b8b5af417e6b2c",
          "synth_tool_synthesis": True, "synth_multi_agent": True, "model_type": "chat",
          "temperature": 0.2, "calls": 0, "billed": 0}


def test_service_check_passes_when_identity_matches_and_ignores_counters():
    camp = dict(CAMP, service={"url": "http://x", "health": HEALTH})
    assert C.service_check(camp, lambda url: dict(HEALTH, calls=9, billed=3)) == []


@pytest.mark.parametrize("key,val", [("code_fingerprint", "0" * 16), ("policy", "dspy:gpt-5"),
                                     ("synth_multi_agent", False), ("temperature", 0.7)])
def test_service_check_reports_identity_drift(key, val):
    camp = dict(CAMP, service={"url": "http://x", "health": HEALTH})
    bad = C.service_check(camp, lambda url: dict(HEALTH, **{key: val}))
    assert bad and bad[0].startswith(key)


def test_service_check_unreachable_is_drift_and_no_service_is_fine():
    camp = dict(CAMP, service={"url": "http://x", "health": HEALTH})
    assert C.service_check(camp, lambda url: {"unreachable": "boom"}) == ["unreachable: boom"]
    assert C.service_check(dict(CAMP, service=None), lambda url: {}) == []


# ---- 최종 리뷰 I2: 다시 돌리기 전에 실패한 판의 원래 증거를 보존한다 -----------------------------
def test_prior_failed_attempt_is_moved_aside_not_truncated(tmp_path):
    j = _job("zone", 3, grid=str(tmp_path))
    os.makedirs(os.path.dirname(j["log"])); os.makedirs(os.path.dirname(j["stream"]))
    open(j["log"], "w").write("first failure\n")
    open(j["stream"], "w").write("{}\n")
    moved = C.preserve_prior_attempt(j)
    assert not os.path.exists(j["log"]) and not os.path.exists(j["stream"])
    assert sorted(os.path.basename(m) for m in moved) == [
        "canonical__zone__s3.attempt1.log", "tractor__canonical_zone_s3_z3.attempt1.jsonl"]
    open(j["log"], "w").write("second failure\n")
    moved2 = C.preserve_prior_attempt(j)
    assert os.path.basename(moved2[0]) == "canonical__zone__s3.attempt2.log"
    assert open(moved[0] if moved[0].endswith(".log") else moved[1]).read() == "first failure\n"
    assert C.preserve_prior_attempt(j) == []               # 옮길 것이 없으면 아무것도 안 한다


def test_service_keys_include_repair_ablation():
    import campaign
    assert "repair_ablation" in campaign.SERVICE_KEYS
