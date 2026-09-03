"""생성 agent 가 읽는 세계 인터페이스 블록. 유료 0건."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import world_interface as WI  # noqa: E402


def test_the_artifact_loads():
    b = WI.load_world_interface()
    assert b["types"] and b["methods"]


def test_the_block_carries_the_env_schema():
    s = WI.build_world_interface_block()
    assert "PlannerEnv" in s
    for f in ("sched", "scene_tree", "cache", "staging_circles"):
        assert f in s, f


def test_the_block_carries_method_signatures():
    s = WI.build_world_interface_block()
    assert "reform_stuck_teams!" in s


def test_the_block_hides_the_non_exported_impls():
    """🔴 설계 D6. 이것이 참이라서 첫 측정이 뜻을 갖는다."""
    s = WI.build_world_interface_block()
    assert "release_pending_assignments!" not in s


def test_the_block_says_the_signature_convention():
    """모델이 규약 1 을 안 읽으면 등록이 전부 거절된다."""
    s = WI.build_world_interface_block()
    assert "(env;" in s and "keyword" in s.lower()


# =====================================================================================
# I4 — 산출물이 다시 생성되면 **프로세스를 안 죽이고** 그것을 읽는다. 유료 0건.
#
# 🔴 왜. `_CACHE` 가 경로만 키로 쓰면 한 번 읽은 blob 이 프로세스 수명 내내 굳는다. 그리고
#    DSPy 서비스는 오래 산다 — 이 레포는 나흘 묵은 uvicorn 이 `/health` 200 을 내는 사고를
#    이미 겪었고(CLAUDE.md gotchas · 세대 도장 기계는 그 사고 때문에 있다), 산출물의
#    최신성을 지키는 것은 **줄리아 시험**(`test/world_interface_current.jl`)인데 돌고 있는
#    서비스는 그것을 절대 안 본다. 낡은 스키마를 받은 모델이 쓴 코드는 "모델의 실패" 로
#    기록된다.
# =====================================================================================
def _write(p, payload):
    import json
    p.write_text(json.dumps(payload), encoding="utf-8")


def test_a_regenerated_artifact_is_seen_without_restarting_the_process(tmp_path):
    """🔴 재생성된 파일을 **같은 프로세스**가 읽는다."""
    import os
    p = tmp_path / "world_interface.json"
    _write(p, {"types": [{"name": "A", "fields": []}], "methods": []})
    os.utime(p, ns=(1_000_000_000_000_000_000, 1_000_000_000_000_000_000))
    assert WI.load_world_interface(str(p))["types"][0]["name"] == "A"

    _write(p, {"types": [{"name": "BB", "fields": []}], "methods": []})   # 크기도 다르다
    os.utime(p, ns=(2_000_000_000_000_000_000, 2_000_000_000_000_000_000))
    assert WI.load_world_interface(str(p))["types"][0]["name"] == "BB", \
        "낡은 blob 이 캐시에서 나왔다 — 오래 사는 서비스가 낡은 스키마를 모델에 준다"


def test_an_unchanged_artifact_is_not_re_read(tmp_path, monkeypatch):
    """비어-통과 방지. 위 시험은 캐시를 통째로 없애도 통과하므로 캐시가 캐시인 것을 따로 잰다."""
    import json as _json
    import os
    p = tmp_path / "world_interface.json"
    _write(p, {"types": [], "methods": []})
    os.utime(p, ns=(3_000_000_000_000_000_000, 3_000_000_000_000_000_000))
    WI.load_world_interface(str(p))

    n = []
    real = _json.load
    monkeypatch.setattr(_json, "load", lambda fh, *a, **k: (n.append(1), real(fh, *a, **k))[1])
    WI.load_world_interface(str(p))
    WI.load_world_interface(str(p))
    assert n == [], "안 바뀐 산출물을 매번 다시 읽는다 — 캐시가 캐시가 아니다"


def test_a_missing_artifact_still_raises_loudly(tmp_path):
    """🔴 조용한 폴백 금지. 빈 인터페이스로 돌면 모델은 아무것도 못 부르는 코드를 쓰고,
    그 실패가 **모델 탓**으로 기록된다 (모듈 docstring)."""
    import pytest
    with pytest.raises(OSError):
        WI.load_world_interface(str(tmp_path / "does_not_exist.json"))


def test_a_deleted_artifact_does_not_keep_serving_from_the_cache(tmp_path):
    """🔴 같은 규칙이 **캐시 히트에도** 걸린다 — 지워진 산출물은 조용히 살아남지 않는다."""
    import os
    import pytest
    p = tmp_path / "world_interface.json"
    _write(p, {"types": [], "methods": []})
    WI.load_world_interface(str(p))
    os.remove(p)
    with pytest.raises(OSError):
        WI.load_world_interface(str(p))
