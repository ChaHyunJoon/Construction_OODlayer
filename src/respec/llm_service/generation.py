"""세대 도장 — 이 서비스가 **실제로 서빙 중인 코드**에 대한 기계가 읽는 사실.

🔴 왜 존재하나 (2026-09-03 실측). 08-30/08-31 기동 uvicorn 다섯이 사흘째 `/health` 200 을
내고 있었고, 그 다섯 중 어느 것도 `synthesize_multi`(09-02 16:45 도입)를 갖고 있지 않았다.
둘은 cwd 가 삭제된 worktree 였다. `/health` 에 세대 도장이 없었고 mtime 은 두 번 거짓
신호였다(S1 task-5). 남은 규약은 사람이 `ps lstart` 를 손으로 대조하는 것뿐이었는데 —
**규약은 게이트가 아니다.**

🔴 `git_rev` 는 **일부러 안 싣는다.** fingerprint 가 있는데 rev 를 같이 실으면 "어느 세대냐"
에 대한 두 번째 진실원이 생기고, 그 둘째는 더 약하다: 작업트리가 dirty 면 rev 는 같은데
서빙되는 바이트는 다르다. 커밋 식별이 필요하면 `ps -p <pid> -o lstart` × `git log` 로 한다
(그 규약은 `README.md` 에 있다).
"""
import hashlib
import os

__all__ = ["code_fingerprint", "SERVED_SUFFIX"]

SERVED_SUFFIX = ".py"


def _served_files(source_dir):
    """서빙되는 소스의 (상대경로, 절대경로) 목록. 정렬돼 있다.

    🔴 제외 셋과 이유:
      · `test_*.py` / `conftest.py` — 서비스가 임포트하지 않는다. 넣으면 시험 한 줄 고칠
        때마다 살아 있는 서비스가 **거짓으로 낡아지고**, 그러면 아무도 이 게이트를 안 믿는다.
      · `__pycache__/` — 임포트의 부산물이지 소스가 아니다. 넣으면 같은 소스를 두
        인터프리터가 돌렸다는 이유만으로 두 서비스가 다른 세대로 읽힌다.
      · 점으로 시작하는 디렉토리 — VCS·에디터 부산물.
    🔴 `os.walk` 다, `listdir` 이 아니다. 오늘 이 디렉토리는 평평하지만(실측), 하위 패키지가
       하나 생기는 날 `listdir` 은 그 파일을 조용히 빠뜨리고 낡은 서비스가 '현행' 이라 보고한다.
    """
    out = []
    for root, dirs, names in os.walk(source_dir):
        dirs[:] = sorted(d for d in dirs if d != "__pycache__" and not d.startswith("."))
        for n in sorted(names):
            if not n.endswith(SERVED_SUFFIX):
                continue
            if n.startswith("test_") or n == "conftest.py":
                continue
            p = os.path.join(root, n)
            out.append((os.path.relpath(p, source_dir).replace(os.sep, "/"), p))
    out.sort()
    return out


def code_fingerprint(source_dir):
    """`source_dir` 이 담고 있는 **서빙되는 소스**의 지문. 못 읽으면 `None`.

    🔴 반환이 **삼상**이다. 문자열 = 쟀다. `None` = **못 쟀다** — 디렉토리가 없거나 읽을 수
    없다(삭제된 worktree 에서 뜬 프로세스가 정확히 이 값을 낸다). 빈 문자열이나 상수 해시로
    접으면 바로 그 판이 '정상 세대' 로 조용히 읽힌다.

    경로도 재료에 들어간다 — 내용만 해싱하면 모듈 이름 변경이 안 잡힌다.
    """
    if not os.path.isdir(source_dir):
        return None
    try:
        files = _served_files(source_dir)
    except OSError:
        return None
    h = hashlib.sha256()
    for rel, path in files:
        try:
            with open(path, "rb") as f:
                blob = f.read()
        except OSError:
            return None
        h.update(rel.encode("utf-8"))
        h.update(b"\0")
        h.update(blob)
        h.update(b"\0")
    return h.hexdigest()[:16]


# =============================================================================================
# 판정기 — 살아 있는 서비스가 **이 트리를** 서빙 중인가
# =============================================================================================
_MISSING = object()

#: 필수 플래그의 이름 → `/health` 의 키. 🔴 리터럴을 두 벌 적지 않기 위한 단일 진실원 —
#: 판정 사유 문자열도 이 표에서 나오므로, 환경변수 이름이 바뀌면 한 자리만 고친다.
FLAG_KEYS = {"TOOL_SYNTHESIS": "synth_tool_synthesis",
             "SYNTH_MULTI_AGENT": "synth_multi_agent"}


def check_health(health, source_dir, require_tool_synthesis=False, require_multi_agent=False):
    """`(ok, code, message)`. `ok` 가 거짓이면 `code` 가 **왜** 인지 말한다.

    사유를 가르는 이유는 다섯의 **처방이 전부 다르기** 때문이다:

    | code | 뜻 | 처방 |
    |---|---|---|
    | `ok` | 이 트리를 서빙 중이고 요구한 플래그가 켜져 있다 | — |
    | `unstamped` | 도장 자체가 없다 = **도장 이전 세대**다 | 재기동 |
    | `blind` | 도장은 있는데 `None` — 자기 소스를 못 읽는다(삭제된 worktree) | 재기동 |
    | `stale` | 읽었는데 이 트리와 다르다 | 재기동 |
    | `flag_off` | 세대는 맞는데 레인이 꺼져 있다 | 재기동 + 환경변수 |
    | `unreadable_tree` | **우리 쪽**을 못 쟀다 | 통과시키지 않는다 |

    🔴 순서가 계약이다. `unstamped` 를 **맨 먼저** 본다: 도장 이전 세대는 플래그 키도 없으므로,
    플래그를 먼저 보면 그 부재가 `False` 로 접혀 `flag_off` 가 나오고 **틀린 처방**("환경변수를
    붙여라")을 낸다. 실제 처방은 "그 서비스는 코드가 낡았다" 다.

    🔴 `unreadable_tree` 는 통과가 아니다. 우리 쪽을 못 쟀으면 "같다고 볼 수 없다" 이지
    "같다" 가 아니다(삼상 규약).

    🔴 플래그는 **요구했을 때만** 본다. 게이트는 넓어지기만 해야 한다 — 합성을 안 쓰는 런까지
    이 판정이 막으면 사람들이 게이트를 끄는 법부터 배운다.
    """
    served = health.get("code_fingerprint", _MISSING) if hasattr(health, "get") else _MISSING
    if served is _MISSING:
        return (False, "unstamped",
                "이 서비스의 /health 에는 세대 도장이 없다 — 도장 이전 세대다. "
                "새 코드로 재기동할 것 (src/respec/llm_service/README.md 의 실행줄).")
    if served is None:
        return (False, "blind",
                "서비스가 자기 소스를 못 읽는다(code_fingerprint=null). source_dir=%r — "
                "삭제된 디렉토리에서 뜬 프로세스다. 재기동할 것."
                % (health.get("source_dir"),))

    local = code_fingerprint(source_dir)
    if local is None:
        return (False, "unreadable_tree",
                "이 트리의 지문을 못 쟀다(%r 을 읽을 수 없다). '같다' 가 아니라 "
                "'같다고 볼 수 없다' 이므로 통과시키지 않는다." % (source_dir,))
    if served != local:
        return (False, "stale",
                "서비스가 다른 바이트를 서빙 중이다: served=%s tree=%s (source_dir=%r). "
                "재기동할 것." % (served, local, health.get("source_dir")))

    for env_name, want in (("TOOL_SYNTHESIS", require_tool_synthesis),
                           ("SYNTH_MULTI_AGENT", require_multi_agent)):
        if not want:
            continue
        if health.get(FLAG_KEYS[env_name]) is not True:
            return (False, "flag_off",
                    "세대는 맞는데 %s 가 이 서비스에서 꺼져 있다(리터럴 \"1\" 만 켠다 — "
                    "true/TRUE/on 은 전부 OFF). 그 환경변수를 붙여 재기동할 것." % env_name)

    return (True, "ok", "이 트리를 서빙 중이다 (fingerprint=%s)" % served)


# =============================================================================================
# CLI — 셸 레시피가 런 **전에** 부르는 자리
# =============================================================================================
# 🔴 stdlib 만 쓴다(`urllib`, `json`, `argparse`). 게이트는 환경이 반쯤 깨졌을 때도 돌아야
#    하는데, 서드파티 의존을 걸면 정확히 그 판에서 게이트가 먼저 죽고 런은 그냥 진행된다.
def fetch_health(url, timeout=5.0):
    """`(health_dict, None)` 또는 `(None, reason)`. 🔴 **못 닿은 것은 통과가 아니다.**"""
    import json
    import urllib.error
    import urllib.request

    target = url.rstrip("/") + "/health"
    try:
        with urllib.request.urlopen(target, timeout=timeout) as r:
            if r.status != 200:
                return None, "unreachable: %s 가 HTTP %s 를 냈다" % (target, r.status)
            return json.loads(r.read().decode("utf-8")), None
    except Exception as e:                       # URLError · timeout · JSONDecodeError 전부
        return None, "unreachable: %s (%s: %s)" % (target, type(e).__name__, e)


def main(argv=None):
    import argparse

    ap = argparse.ArgumentParser(
        prog="generation",
        description="살아 있는 DSPy 서비스가 이 트리를 서빙 중인지 판정한다. "
                    "통과 0, 그 밖 1. 사유는 stdout 에 코드로 찍는다.")
    ap.add_argument("--url", required=True, help="서비스 주소 (예: http://127.0.0.1:8077)")
    ap.add_argument("--source-dir", default=os.path.dirname(os.path.abspath(__file__)),
                    help="이 트리의 서비스 소스 디렉토리 (기본: 이 파일이 있는 곳)")
    ap.add_argument("--require-tool-synthesis", action="store_true")
    ap.add_argument("--require-multi-agent", action="store_true")
    ap.add_argument("--timeout", type=float, default=5.0)
    a = ap.parse_args(argv)

    health, why = fetch_health(a.url, a.timeout)
    if health is None:
        print("[generation] FAIL unreachable — %s" % why)
        return 1
    ok, code, msg = check_health(health, a.source_dir,
                                 require_tool_synthesis=a.require_tool_synthesis,
                                 require_multi_agent=a.require_multi_agent)
    print("[generation] %s %s — %s" % ("OK" if ok else "FAIL", code, msg))
    return 0 if ok else 1


if __name__ == "__main__":            # pragma: no cover - 진입점
    raise SystemExit(main())
