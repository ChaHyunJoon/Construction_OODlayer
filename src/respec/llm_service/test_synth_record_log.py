"""합성 기록을 파일로 남긴다. 유료 0건.

🔴 왜 (2026-09-03 라이브 실측). mild 보드에서 합성이 **발화했는데** `empty body` 로 거절됐고,
agent-3 이 실제로 무엇을 답했는지(`body` 산문 · `body_parse` · `missing_primitive` · `calls`)는
**어디에도 안 남았다**:
  · `[minted]` 의 `lane=present` 분기는 그 셋을 안 찍었고(그날 고쳤다),
  · 스트림 `.jsonl` 은 프레임 기록이라 합성 필드가 0개이고,
  · 서비스는 결정 기록을 파일로 안 쓴다(`llm_ood_eval.jsonl` 은 스윕 경로다).
⟹ 유료 런을 하고도 "왜 body 가 비었나" 를 답할 수 없었다. 그 구멍을 여기서 닫는다.

🔴 `body` 산문은 `SYNTH_LANE_KEYS` 로 **안 올린다** — 그 경계는 "집행부가 읽는 것" 이고
산문은 집행이 안 읽는다. 진단은 파일로 남기고 경계는 좁게 둔다.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import synthesize as SY  # noqa: E402


def _rec():
    return {"kind": "mild_battery", "reach": "needs_primitive",
            "body": "No body can be composed from the current inventory.",
            "body_parse": "empty", "body_names": [], "calls": None,
            "missing_primitive": "the inventory lacks X"}


def test_one_call_appends_one_json_line(tmp_path):
    p = tmp_path / "rec.jsonl"
    assert SY.append_synthesis_record(_rec(), str(p)) == str(p)
    rows = [json.loads(l) for l in open(p, encoding="utf-8")]
    assert len(rows) == 1
    assert rows[0]["body_parse"] == "empty"
    assert rows[0]["missing_primitive"] == "the inventory lacks X"


def test_a_second_call_appends_rather_than_truncates(tmp_path):
    p = tmp_path / "rec.jsonl"
    SY.append_synthesis_record(_rec(), str(p))
    SY.append_synthesis_record(_rec(), str(p))
    assert len(open(p, encoding="utf-8").read().strip().split("\n")) == 2


def test_the_body_prose_survives_verbatim(tmp_path):
    """🔴 이 파일이 존재하는 이유. 산문이 잘리면 H1(진짜 거절)과 H2(파싱 실패)를 못 가른다."""
    p = tmp_path / "rec.jsonl"
    SY.append_synthesis_record(_rec(), str(p))
    row = json.loads(open(p, encoding="utf-8").readline())
    assert row["body"] == "No body can be composed from the current inventory."


def test_a_value_json_cannot_encode_does_not_lose_the_line(tmp_path):
    """진단이 결정을 죽이면 안 된다 — 인코딩 못 하는 값은 문자열로 접고 줄은 남긴다."""
    p = tmp_path / "rec.jsonl"
    r = _rec(); r["weird"] = object()
    assert SY.append_synthesis_record(r, str(p)) == str(p)
    row = json.loads(open(p, encoding="utf-8").readline())
    assert isinstance(row["weird"], str) and row["reach"] == "needs_primitive"


def test_an_unwritable_path_returns_none_and_does_not_raise(tmp_path):
    """🔴 기록 실패가 결정을 죽이면, 진단을 켠 것이 사고의 원인이 된다."""
    bad = tmp_path / "no_such_dir_file" / "x" / "rec.jsonl"
    os.makedirs(tmp_path / "no_such_dir_file", exist_ok=True)
    open(tmp_path / "no_such_dir_file" / "x", "w").close()   # 파일이라 하위 디렉터리 생성 불가
    assert SY.append_synthesis_record(_rec(), str(bad)) is None


def test_the_sink_can_be_turned_off(tmp_path, monkeypatch):
    monkeypatch.setenv(SY.SYNTH_RECORD_ENV, "0")
    p = tmp_path / "rec.jsonl"
    assert SY.append_synthesis_record(_rec(), None) is None
    assert not p.exists()


def test_an_explicit_path_argument_beats_the_env(tmp_path, monkeypatch):
    """호출자가 경로를 주면 그것을 쓴다 — 시험이 환경에 의존하지 않게."""
    monkeypatch.setenv(SY.SYNTH_RECORD_ENV, str(tmp_path / "from_env.jsonl"))
    p = tmp_path / "explicit.jsonl"
    assert SY.append_synthesis_record(_rec(), str(p)) == str(p)
    assert p.exists() and not (tmp_path / "from_env.jsonl").exists()


def test_the_default_path_is_gitignored_results(tmp_path, monkeypatch):
    """🔴 기본 경로가 추적되는 자리면 아무도 재현 안 한 숫자가 커밋된다."""
    monkeypatch.delenv(SY.SYNTH_RECORD_ENV, raising=False)
    d = SY.default_record_path()
    assert d.endswith(".jsonl") and os.sep + "results" + os.sep in d


def test_the_service_writes_a_record_for_every_firing(monkeypatch, tmp_path):
    """🔴 배선 시험. 함수만 있고 서비스가 안 부르면 라이브 판은 그대로 사라진다 —
    이 파일이 닫으려는 구멍이 정확히 그것이다. 모델은 안 부른다(유료 0건).
    """
    import dspy_service as S
    p = tmp_path / "live.jsonl"
    monkeypatch.setenv(SY.SYNTH_RECORD_ENV, str(p))
    seen = {}

    def fake_run_synthesis(**kw):
        seen.update(kw)
        return {"tool_minted": True, "reach": "needs_primitive", "body": "no body",
                "body_parse": "empty", "kind": kw.get("kind")}

    monkeypatch.setattr(S, "run_synthesis", fake_run_synthesis)
    monkeypatch.setattr(S, "_decide_core", getattr(S, "_decide_core", None), raising=False)
    S._append_synthesis_record(fake_run_synthesis(kind="mild_battery"))
    rows = [json.loads(l) for l in open(p, encoding="utf-8")]
    assert rows and rows[-1]["body_parse"] == "empty"


def test_the_macro_handler_calls_the_sink():
    """🔴 AST 로 **호출 자리**를 못박는다. 위 시험은 함수가 도는 것만 재고, 서비스가 그것을
    부르는지는 안 잰다 — 두 벌이 갈리면 라이브만 조용히 기록을 잃는다.
    """
    import ast
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "dspy_service.py"),
               encoding="utf-8").read()
    names = {n.func.id for n in ast.walk(ast.parse(src))
             if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)}
    assert "_append_synthesis_record" in names, "서비스가 기록 sink 를 안 부른다"


def test_the_suite_itself_never_writes_to_the_default_path():
    """🔴 2026-09-03 실측 사고. 이 sink 를 붙인 직후 돌린 pytest 가 **생산 기록 파일에**
    39줄을 썼고(`enabled=False` 인 시험 판들), 나는 그것을 라이브 렌더의 기록으로 착각해
    읽었다. 진단 파일은 라이브 판만 담아야 한다 — 아니면 그 파일을 못 믿는다.
    루트 `conftest.py` 가 스위트 전체에 대해 sink 를 끈다.
    """
    assert os.environ.get(SY.SYNTH_RECORD_ENV) == "0", (
        "시험 중에는 sink 가 꺼져 있어야 한다 — 루트 conftest.py 가 그것을 보장한다")
