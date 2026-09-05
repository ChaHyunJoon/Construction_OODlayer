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
    """🔴 설계 D6. 이것이 참이라서 첫 측정이 뜻을 갖는다.

    🔴 S4 (2026-09-04): `release_pending_assignments!` 는 이 목록에서 **빠졌다** — 첫 측정이
    끝났고(세계 delta 5축 전부 0, 모델이 재배정을 주석으로 썼다) 그 동사를 광고하는 것이
    다음 측정이다. 남은 넷은 그대로 감춘다.
    """
    s = WI.build_world_interface_block()
    for hidden in ("recover_stalled_teams!", "resolve_schedule_wedge!",
                   "force_advance_stuck_carrier!", "forbid_heavy_cargo!"):
        assert hidden not in s, hidden


def test_the_block_advertises_the_reassignment_verb():
    """🔴 S4 의 양성 단언 — 감춤 게이트만 남기면 광고가 도착했는지 아무도 안 본다.

    🔴 그리고 **어느 표제 아래인지**가 이 태스크의 성패다. 둘째 표제("...CANNOT OBTAIN
    YET") 아래 실리면 모델은 "지금은 못 부른다" 로 읽고 광고가 무동작이 된다 — 실측으로
    한 번 그렇게 됐다(`export` 만 하면 `InvariantSpec` 이 타입 폐포 밖이라
    `callable=false`). 생성기의 `_CURATED_SEEDS` 가 그것을 고쳤다.
    """
    s = WI.build_world_interface_block()
    head, _, tail = s.partition("FUNCTIONS THAT NEED SOMETHING YOU CANNOT OBTAIN YET")
    assert "release_pending_assignments!" in head
    assert "release_pending_assignments!" not in tail
    # 조합 부담은 **일부러** 남긴다: `invariant` 는 env 의 필드가 아니라
    # `build_invariant(env)` 가 만든다. 그 이음매를 모델이 스스로 잇는지가 실험이다.
    assert "build_invariant" in head


def test_the_block_says_the_signature_convention():
    """모델이 규약 1 을 안 읽으면 등록이 전부 거절된다."""
    s = WI.build_world_interface_block()
    assert "(env;" in s and "keyword" in s.lower()


def test_the_block_allows_helper_closures_inside_the_body():
    """🔴 F21(2026-09-03 최종 리뷰). R15: check_impl_conventions 는 몸통 안의 도우미
    클로저를 허용한다(최상위 정의가 정확히 하나이면 됨) — 규약 4 문구가 예전엔
    "no helper functions" 라고만 적어 그 검사기와 글자로 어긋났다(Task 9 최종 리뷰
    라운드 4 가 고쳤다). 옛 문구를 그대로 되돌리는 다음 드리프트가 이 단언 없이는
    조용히 통과한다 — 여기서 빨갛게 만든다.
    """
    s = WI.build_world_interface_block()
    assert "TOP-LEVEL" in s or "top-level" in s
    assert "inside your function body are fine" in s.lower()
    assert "no helper functions.\n" not in s   # 옛 무조건 금지 문구가 되살아나지 않았다


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
