"""세대 도장 — `/health` 가 **자기가 서빙 중인 코드**에 대해 기계가 읽을 수 있는 사실을 낸다.

🔴 왜 이 파일이 존재하나 (2026-09-03 실측). 08-30/08-31 에 뜬 uvicorn **다섯**이 사흘째
`/health` 200 을 내고 있었고, 그 다섯 중 어느 것도 `synthesize_multi`(09-02 16:45 도입)를
갖고 있지 않았다. 둘은 cwd 가 **삭제된 worktree** 였다. 그 위에서 잰 "합성이 안 터진다" 는
모델에 대한 사실이 아니라 **런처에 대한 사실**이었다.
`/health` 에는 세대 도장이 없었고, mtime 도 두 번 거짓 신호였다(S1 task-5). 사람이
`ps lstart` 를 손으로 대조하는 규약만 있었는데 — 규약은 게이트가 아니다.

재는 명제 여섯
  (1) fingerprint 는 **내용의 함수**다: 같은 바이트 → 같은 값, 한 바이트 달라지면 → 다른 값.
  (2) 시험 파일은 fingerprint 에 **안 들어간다** — 서비스가 서빙하지 않는 코드다.
      (안 그러면 이 파일을 고칠 때마다 살아 있는 서비스가 거짓으로 낡아진다.)
  (3) 자기 소스를 못 읽으면 `None` 이다 — **0 도 빈 문자열도 아니다**(삼상 규약). 삭제된
      worktree 에서 뜬 프로세스가 정확히 이 값을 낸다.
  (4) `/health` 가 그 값과 `source_dir` 를 싣는다.
  (5) 플래그는 **레인이 읽는 함수**의 값을 싣는다 — raw env echo 가 아니다.
      `SYNTH_MULTI_AGENT=true` 는 레인에서 OFF 이므로 `/health` 도 OFF 라고 말해야 한다.
  (6) 판정기는 낡음·플래그부족·자기소스못읽음 셋을 **서로 다른 사유**로 거절하고, 현행이면
      통과시킨다.
"""
import hashlib
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import generation as G  # noqa: E402


# ---- (1)(2)(3) fingerprint ----------------------------------------------------------------
def _pkg(tmp_path, files):
    d = tmp_path / "svc"
    d.mkdir(parents=True, exist_ok=True)
    for name, body in files.items():
        (d / name).write_text(body, encoding="utf-8")
    return str(d)


def test_same_bytes_give_the_same_fingerprint(tmp_path):
    a = _pkg(tmp_path / "a", {"m.py": "x = 1\n", "n.py": "y = 2\n"})
    b = _pkg(tmp_path / "b", {"m.py": "x = 1\n", "n.py": "y = 2\n"})
    assert G.code_fingerprint(a) == G.code_fingerprint(b)


def test_one_changed_byte_changes_the_fingerprint(tmp_path):
    a = _pkg(tmp_path / "a", {"m.py": "x = 1\n"})
    b = _pkg(tmp_path / "b", {"m.py": "x = 2\n"})
    assert G.code_fingerprint(a) != G.code_fingerprint(b)


def test_a_new_module_changes_the_fingerprint(tmp_path):
    a = _pkg(tmp_path / "a", {"m.py": "x = 1\n"})
    b = _pkg(tmp_path / "b", {"m.py": "x = 1\n", "extra.py": "z = 3\n"})
    assert G.code_fingerprint(a) != G.code_fingerprint(b)


def test_a_renamed_module_changes_the_fingerprint(tmp_path):
    """내용 해시만 하면 이름 변경이 안 잡힌다 — 경로도 재료에 들어가야 한다."""
    a = _pkg(tmp_path / "a", {"m.py": "x = 1\n"})
    b = _pkg(tmp_path / "b", {"renamed.py": "x = 1\n"})
    assert G.code_fingerprint(a) != G.code_fingerprint(b)


def test_test_files_are_not_part_of_the_fingerprint(tmp_path):
    """🔴 (2). 시험은 서빙되지 않는다. 넣으면 이 파일을 고칠 때마다 살아 있는 서비스가
    거짓으로 '낡음' 이 되고, 그러면 아무도 게이트를 안 믿게 된다."""
    a = _pkg(tmp_path / "a", {"m.py": "x = 1\n"})
    b = _pkg(tmp_path / "b", {"m.py": "x = 1\n", "test_thing.py": "assert True\n",
                              "conftest.py": "# fixtures\n"})
    assert G.code_fingerprint(a) == G.code_fingerprint(b)


def test_an_unreadable_source_dir_is_none_not_a_string(tmp_path):
    """🔴 (3) 삼상. 삭제된 worktree 에서 뜬 프로세스가 내는 값이다. `None` 은 '못 쟀다' 이고
    빈 문자열이나 상수 해시로 접으면 그 판이 '정상 세대' 로 조용히 읽힌다."""
    assert G.code_fingerprint(str(tmp_path / "does-not-exist")) is None


def test_a_module_in_a_subpackage_is_part_of_the_fingerprint(tmp_path):
    """오늘 `llm_service/` 는 평평하다(실측: 하위 .py 0개). 그래서 `listdir` 로도 지금은
    초록이다 — 바로 그것이 이 명제를 **지금** 못박는 이유다. 하위 패키지가 하나 생기는 날
    그 파일은 조용히 fingerprint 밖에 놓이고, 그 서비스는 낡은 채로 '현행' 이라 보고한다."""
    a = _pkg(tmp_path / "a", {"m.py": "x = 1\n"})
    b = _pkg(tmp_path / "b", {"m.py": "x = 1\n"})
    sub = os.path.join(b, "sub")
    os.makedirs(sub, exist_ok=True)
    open(os.path.join(sub, "deep.py"), "w").write("z = 3\n")
    assert G.code_fingerprint(a) != G.code_fingerprint(b)


def test_pycache_is_not_part_of_the_fingerprint(tmp_path):
    """`.pyc` 는 임포트의 부산물이지 소스가 아니다. 넣으면 같은 소스를 두 인터프리터가
    돌렸다는 이유만으로 두 서비스가 다른 세대로 읽힌다."""
    a = _pkg(tmp_path / "a", {"m.py": "x = 1\n"})
    b = _pkg(tmp_path / "b", {"m.py": "x = 1\n"})
    pyc = os.path.join(b, "__pycache__")
    os.makedirs(pyc, exist_ok=True)
    open(os.path.join(pyc, "m.cpython-312.pyc"), "wb").write(b"\x00\x01binary")
    open(os.path.join(pyc, "stray.py"), "w").write("noise = 1\n")
    assert G.code_fingerprint(a) == G.code_fingerprint(b)


# ---- (4)(5) `/health` 가 그 사실을 싣는다 ---------------------------------------------------
import dspy_service as svc  # noqa: E402  (numpy/sklearn-before-dspy 계약: generation 뒤에 온다)


def test_health_says_which_directory_it_imported_from():
    """🔴 오늘 두 프로세스를 즉시 진단했을 값이다. cwd 가 아니라 **모듈이 로드된 자리**여야
    한다 — 그 둘은 갈릴 수 있고(uvicorn 을 다른 데서 띄우면), 서빙되는 코드를 정하는 것은
    후자다."""
    h = svc.health()
    assert h["source_dir"] == os.path.dirname(os.path.abspath(svc.__file__))


def test_health_carries_the_fingerprint_of_that_directory():
    h = svc.health()
    assert h["code_fingerprint"] == G.code_fingerprint(h["source_dir"])
    assert isinstance(h["code_fingerprint"], str)      # 이 시험은 트리 안에서 도니 쟀어야 한다


def test_health_reports_the_flags_as_the_lane_actually_reads_them(monkeypatch):
    """🔴 raw env echo 가 **아니다**. 레인은 리터럴 `"1"` 만 참으로 읽으므로(실측:
    `true`·`TRUE`·`on` 전부 OFF), `/health` 가 raw 문자열을 그대로 실으면 판독자가
    `SYNTH_MULTI_AGENT=true` 인 서비스를 '켜져 있다' 로 읽는다 — 정확히 오늘 다섯 대에서
    일어난 일의 플래그 판본이다."""
    monkeypatch.setenv("TOOL_SYNTHESIS", "1")
    monkeypatch.setenv("SYNTH_MULTI_AGENT", "true")
    h = svc.health()
    assert h["synth_tool_synthesis"] is True
    assert h["synth_multi_agent"] is False

    monkeypatch.setenv("SYNTH_MULTI_AGENT", "1")
    assert svc.health()["synth_multi_agent"] is True

    monkeypatch.delenv("TOOL_SYNTHESIS", raising=False)
    assert svc.health()["synth_tool_synthesis"] is False


def test_the_fingerprint_is_frozen_at_import_not_recomputed_per_request(monkeypatch):
    """🔴 이 파일에서 가장 중요한 명제다.

    요청마다 다시 계산하면 게이트가 **반대 방향으로 거짓말한다**: 누군가 소스를 고치면
    디스크는 새 바이트인데 uvicorn 은 여전히 임포트 시점의 옛 바이트를 서빙한다. 그런데
    `/health` 는 디스크를 읽어 '현행' 이라 보고한다 — 즉 게이트가 정확히 **자기가 잡으라고
    존재하는 그 판**을 통과시킨다. 도장은 **임포트된 바이트**에 대한 주장이어야 한다.
    """
    frozen = svc.health()["code_fingerprint"]
    monkeypatch.setattr(G, "code_fingerprint", lambda d: "deadbeefdeadbeef")
    assert svc.health()["code_fingerprint"] == frozen


# ---- (6) 판정기 ----------------------------------------------------------------------------
# 🔴 사유가 갈려야 하는 이유: 이 다섯은 대응이 전부 다르다.
#    unstamped  → 도장 이전 세대다. **오늘 죽인 다섯이 전부 이것이었다.**
#    blind      → 살아 있는데 자기 소스를 못 읽는다(삭제된 worktree).
#    stale      → 읽었는데 이 트리와 다르다. 재기동하면 된다.
#    flag_off   → 세대는 맞는데 레인이 꺼져 있다. 재기동 + 환경변수.
#    unreadable_tree → **우리 쪽**을 못 쟀다. 통과시키면 안 된다(삼상).
def _ok_health(fp, **kw):
    h = {"status": "ok", "source_dir": "/somewhere",
         "code_fingerprint": fp, "synth_tool_synthesis": True, "synth_multi_agent": True}
    h.update(kw)
    return h


def test_a_current_and_correctly_flagged_service_passes(tmp_path):
    d = _pkg(tmp_path, {"m.py": "x = 1\n"})
    ok, code, _ = G.check_health(_ok_health(G.code_fingerprint(d)), d,
                                 require_tool_synthesis=True, require_multi_agent=True)
    assert (ok, code) == (True, "ok")


def test_a_service_without_the_stamp_is_rejected_as_unstamped(tmp_path):
    """🔴 오늘 죽인 다섯이 전부 이 판이었다. `code_fingerprint` 키가 아예 없다."""
    d = _pkg(tmp_path, {"m.py": "x = 1\n"})
    h = _ok_health(None)
    del h["code_fingerprint"]
    ok, code, _ = G.check_health(h, d)
    assert (ok, code) == (False, "unstamped")


def test_a_service_that_cannot_read_its_own_source_is_rejected_as_blind(tmp_path):
    """삭제된 worktree 에서 뜬 프로세스. 키는 있고 값이 `None` 이다 — unstamped 와 다른 사건."""
    d = _pkg(tmp_path, {"m.py": "x = 1\n"})
    ok, code, _ = G.check_health(_ok_health(None), d)
    assert (ok, code) == (False, "blind")


def test_a_service_serving_other_bytes_is_rejected_as_stale(tmp_path):
    d = _pkg(tmp_path, {"m.py": "x = 1\n"})
    ok, code, msg = G.check_health(_ok_health("0123456789abcdef"), d)
    assert (ok, code) == (False, "stale")
    assert "0123456789abcdef" in msg and G.code_fingerprint(d) in msg   # 둘 다 보여야 진단이 된다


def test_a_current_service_with_the_lane_switched_off_is_rejected(tmp_path):
    """세대는 맞는데 플래그가 꺼진 판. 오늘 8077·8079·8095 가 이것이었다
    (`TOOL_SYNTHESIS=1` 은 있고 `SYNTH_MULTI_AGENT` 는 없음)."""
    d = _pkg(tmp_path, {"m.py": "x = 1\n"})
    h = _ok_health(G.code_fingerprint(d), synth_multi_agent=False)
    ok, code, msg = G.check_health(h, d, require_multi_agent=True)
    assert (ok, code) == (False, "flag_off")
    assert "SYNTH_MULTI_AGENT" in msg


def test_flags_are_not_required_unless_asked(tmp_path):
    """게이트는 **넓어지기만** 해야 한다 — 합성을 안 쓰는 런까지 이 판정이 막으면 안 된다."""
    d = _pkg(tmp_path, {"m.py": "x = 1\n"})
    h = _ok_health(G.code_fingerprint(d), synth_multi_agent=False, synth_tool_synthesis=False)
    assert G.check_health(h, d)[0] is True


def test_an_unreadable_local_tree_does_not_pass(tmp_path):
    """🔴 우리 쪽을 **못 쟀다**. '같다고 볼 수 없다' 이지 '같다' 가 아니다."""
    ok, code, _ = G.check_health(_ok_health("0123456789abcdef"), str(tmp_path / "gone"))
    assert (ok, code) == (False, "unreadable_tree")


def test_a_missing_flag_key_is_not_read_as_off(tmp_path):
    """도장 이전 세대는 플래그 키도 없다. 그 부재를 `False` 로 접으면 사유가 `flag_off` 로
    나와서 '재기동하고 환경변수 붙여라' 라는 **틀린 처방**을 낸다 — 실제 처방은 '그 서비스는
    코드가 낡았다' 다. 부재는 `unstamped` 가 먼저 잡는다."""
    d = _pkg(tmp_path, {"m.py": "x = 1\n"})
    h = {"status": "ok"}
    ok, code, _ = G.check_health(h, d, require_multi_agent=True)
    assert (ok, code) == (False, "unstamped")


# ---- (7) CLI — 셸 레시피가 부르는 자리 ------------------------------------------------------
# 🔴 mock 을 안 쓴다. 진짜 HTTP 서버를 띄우고 진짜 서브프로세스로 CLI 를 부른다 — 이 게이트가
#    막으려는 사고가 **프로세스 경계에서** 일어나므로, 그 경계를 안 건너는 시험은 이 게이트가
#    실제로 도는지 말해 주지 않는다.
import json as _json
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer


def _serve(payload):
    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            body = _json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass

    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, "http://127.0.0.1:%d" % srv.server_address[1]


def _cli(url, *args):
    return subprocess.run([sys.executable, os.path.join(HERE, "generation.py"),
                           "--url", url, *args],
                          capture_output=True, text=True, timeout=30)


def test_cli_exits_zero_for_a_service_serving_this_tree():
    srv, url = _serve({"status": "ok", "source_dir": HERE,
                       "code_fingerprint": G.code_fingerprint(HERE),
                       "synth_tool_synthesis": True, "synth_multi_agent": True})
    try:
        r = _cli(url, "--require-multi-agent")
        assert r.returncode == 0, r.stdout + r.stderr
        assert "ok" in r.stdout
    finally:
        srv.shutdown()


def test_cli_exits_nonzero_and_names_the_reason_for_a_stale_service():
    srv, url = _serve({"status": "ok", "source_dir": "/gone",
                       "code_fingerprint": "0123456789abcdef"})
    try:
        r = _cli(url)
        assert r.returncode != 0
        assert "stale" in (r.stdout + r.stderr)
    finally:
        srv.shutdown()


def test_cli_exits_nonzero_for_a_pre_stamp_service():
    """🔴 오늘 죽인 다섯의 응답 모양 그대로다 — 도장 키가 없다."""
    srv, url = _serve({"status": "ok", "policy": "dspy:gpt-4o", "calls": 3,
                       "surro_support": [0, 1, 2], "surro_kinds": ["battery", "fault"]})
    try:
        r = _cli(url)
        assert r.returncode != 0
        assert "unstamped" in (r.stdout + r.stderr)
    finally:
        srv.shutdown()


def test_cli_exits_nonzero_when_nothing_is_listening():
    """🔴 서비스가 죽어 있는 것도 '통과' 가 아니다. 오늘의 셸 레시피 넷 중 셋은 이 판에서
    경고만 찍고 스윕을 계속 돌린다."""
    r = _cli("http://127.0.0.1:1/nothing-here")
    assert r.returncode != 0
    assert "unreachable" in (r.stdout + r.stderr)
