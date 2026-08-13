"""P8 -- DSPy 서비스가 동시 K 요청을 견디는지 확인한다.

왜 필요한가: 이 스윕의 dspy 레인은 210 판이고 판당 4~9 결정이라 약 840~1,890 회의 gpt-4o
호출이 발생한다. 샤드 안에서 정책이 순차이므로 동시 dspy 판은 최대 K 개다. 계정 rate limit 을
넘으면 429 가 돌아오는데, run_demo.jl 쪽에서는 그게 "그 판의 결정 실패"로 조용히 흡수될 수
있다 -- 스윕이 끝난 뒤 표를 보고서야 dspy 레인이 비었음을 알게 된다. 미리 K 개를 던져 본다.
"""
import argparse, json, sys, time
from concurrent.futures import ThreadPoolExecutor

import urllib.request
import urllib.error

PROBE = {
    "kind": "battery", "severity": 0.6, "soc": 0.12, "spare_count": 2,
    "agent_pending": 1, "progress": 0.4, "n_active": 4,
    "nl": "A transport robot reports state of charge 12 percent while carrying an assembly.",
}


def one(url, timeout):
    """(ok, detail) 를 돌려준다."""
    body = json.dumps(PROBE).encode("utf-8")
    req = urllib.request.Request(url + "/macro", data=body,
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            code = resp.getcode()
            payload = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return False, "HTTP %d (%.1fs)" % (e.code, time.time() - t0)
    except Exception as e:
        return False, "%s (%.1fs)" % (type(e).__name__, time.time() - t0)
    dt = time.time() - t0
    if code != 200:
        return False, "http_code=%d" % code
    if payload.get("error") is not None:
        return False, "error=%r" % payload.get("error")
    pol = payload.get("policy") or ""
    if not (isinstance(pol, str) and pol.startswith("dspy")):
        return False, "policy=%r (dspy 로 시작해야 한다)" % pol
    return True, "%.1fs" % dt


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", default="http://127.0.0.1:8090")
    ap.add_argument("--jobs", type=int, default=16)
    ap.add_argument("--timeout", type=float, default=120.0)
    args = ap.parse_args()

    print("== P8 LLM 동시성: %s 에 동시 %d 요청 ==" % (args.url, args.jobs))
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        results = list(ex.map(lambda _: one(args.url, args.timeout), range(args.jobs)))
    wall = time.time() - t0

    n_ok = sum(1 for ok, _ in results if ok)
    for i, (ok, detail) in enumerate(results):
        if not ok:
            print("  FAIL  요청 %d: %s" % (i, detail))
    print("  %d/%d 성공, 벽시계 %.1fs" % (n_ok, args.jobs, wall))
    if n_ok < args.jobs:
        print("  실패. K 를 낮추거나 계정 rate limit 을 확인할 것.")
        return 1
    print("  PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
