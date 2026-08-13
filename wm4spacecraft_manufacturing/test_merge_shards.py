"""merge_shards.py 계약 테스트.

왜 필요한가: 병렬 실행에서는 샤드 완료 순서가 실행마다 다르다. 그 순서대로 병합하면
results_4pol/<case>.jsonl 의 행 순서가 실행마다 달라지고, 그걸 먹는 리포트 산출물도 따라
달라진다. 병합은 완료 순서가 아니라 (ood_seed, policy) 로 결정적이어야 한다.
또 하나: 조용한 부분 병합을 막아야 한다. 90행이어야 할 파일이 87행인 채로 통과하면 표는
"n=30" 이라고 주장하면서 실제로는 29 시드로 계산된다.
"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable
MERGER = os.path.join(HERE, "merge_shards.py")

FAILED = 0


def check(name, ok, detail=""):
    global FAILED
    print("  %s  %s   %s" % ("PASS" if ok else "FAIL", name, detail))
    if not ok:
        FAILED += 1


def row(case, seed, policy):
    return {"case": case, "ood_seed": seed, "policy": policy,
            "complete": True, "sim_seconds": 1.0 * seed, "closed": 10 + seed,
            "geometry": {"depot_distance": 20.0}}


def build_shards(root, case, seeds, policies, skip=()):
    """샤드 트리를 만든다. skip 에 든 (seed, policy) 는 일부러 빠뜨린다."""
    for s in seeds:
        d = os.path.join(root, case, "s%d" % s)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "rows.jsonl"), "w", encoding="utf-8") as fh:
            # 정책을 일부러 뒤섞어 쓴다 -- 병합이 정렬하는지 보려면 입력이 정렬돼 있으면 안 된다.
            for p in reversed(policies):
                if (s, p) in skip:
                    continue
                fh.write(json.dumps(row(case, s, p)) + "\n")


def run_merge(shards, out, cases, seeds, policies):
    p = subprocess.run([PY, MERGER, "--shards-dir", shards, "--out-dir", out,
                        "--cases", cases, "--seeds", seeds, "--policies", policies],
                       capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


POLICIES = ["noop", "surrogate", "dspy"]

print("== merge_shards.py ==")

with tempfile.TemporaryDirectory() as tmp:
    shards = os.path.join(tmp, "shards"); out = os.path.join(tmp, "out")
    build_shards(shards, "battery", [1, 2, 3], POLICIES)
    rc, log = run_merge(shards, out, "battery", "1,2,3", ",".join(POLICIES))
    check("완전한 샤드 트리는 통과", rc == 0, "rc=%d %s" % (rc, log.strip()[-200:]))

    merged = [json.loads(l) for l in
              open(os.path.join(out, "battery.jsonl"), encoding="utf-8") if l.strip()]
    check("행 수 = seeds x policies", len(merged) == 9, "n=%d" % len(merged))

    got = [(r["ood_seed"], r["policy"]) for r in merged]
    want = [(s, p) for s in (1, 2, 3) for p in POLICIES]
    check("(ood_seed, policy 정의 순서)로 정렬된다", got == want, "%s" % (got,))

with tempfile.TemporaryDirectory() as tmp:
    shards = os.path.join(tmp, "shards"); out = os.path.join(tmp, "out")
    build_shards(shards, "battery", [1, 2, 3], POLICIES, skip={(2, "dspy")})
    rc, log = run_merge(shards, out, "battery", "1,2,3", ",".join(POLICIES))
    check("행이 모자라면 실패", rc == 1, "rc=%d" % rc)
    check("빠진 (seed, policy)를 찍는다",
          "seed=2" in log and "dspy" in log, log.strip()[-300:])

with tempfile.TemporaryDirectory() as tmp:
    shards = os.path.join(tmp, "shards"); out = os.path.join(tmp, "out")
    build_shards(shards, "battery", [1], POLICIES)
    rc, log = run_merge(shards, out, "battery,fault", "1", ",".join(POLICIES))
    check("샤드 디렉토리가 통째로 없는 case 는 실패", rc == 1, "rc=%d" % rc)
    check("없는 case 이름을 찍는다", "fault" in log, log.strip()[-300:])

with tempfile.TemporaryDirectory() as tmp:
    shards = os.path.join(tmp, "shards"); out = os.path.join(tmp, "out")
    build_shards(shards, "battery", [1, 2, 3], POLICIES)
    run_merge(shards, out, "battery", "1,2,3", ",".join(POLICIES))
    first = open(os.path.join(out, "battery.jsonl"), encoding="utf-8").read()
    run_merge(shards, out, "battery", "1,2,3", ",".join(POLICIES))
    second = open(os.path.join(out, "battery.jsonl"), encoding="utf-8").read()
    check("두 번 돌려도 같은 파일 (덮어쓰기, 이어붙이기 아님)", first == second,
          "len %d vs %d" % (len(first), len(second)))

# ---- 행의 자기 신고 검사 (2026-08-13) --------------------------------------------------
# 병합기는 오래 행을 **디렉토리 이름**으로만 키잉했다. 샤드가 엉뚱한 자리에 놓이면 한 시드가
# 중복되고 다른 시드가 통째로 빠지는데, 행 수는 그대로 90 이라 `OK 90/90` 이 나온다.
with tempfile.TemporaryDirectory() as tmp:
    shards = os.path.join(tmp, "shards"); out = os.path.join(tmp, "out")
    build_shards(shards, "battery", [1, 2, 3], POLICIES)
    # s3/ 자리에 seed=1 을 신고하는 행을 넣는다 (= s1 샤드를 s3 로 복사한 꼴).
    d = os.path.join(shards, "battery", "s3")
    with open(os.path.join(d, "rows.jsonl"), "w", encoding="utf-8") as fh:
        for p in POLICIES:
            fh.write(json.dumps(row("battery", 1, p)) + "\n")
    rc, log = run_merge(shards, out, "battery", "1,2,3", ",".join(POLICIES))
    check("자리를 잘못 잡은 샤드(행의 ood_seed 불일치)는 실패", rc == 1, "rc=%d" % rc)
    check("행이 신고한 ood_seed 를 찍는다", "ood_seed=1" in log, log.strip()[-400:])
    check("행 수만으로 OK 를 내지 않는다", "OK " not in log, log.strip()[-400:])

with tempfile.TemporaryDirectory() as tmp:
    shards = os.path.join(tmp, "shards"); out = os.path.join(tmp, "out")
    build_shards(shards, "battery", [1, 2], POLICIES)
    # battery/s2 안에 case=fault 를 신고하는 행을 심는다.
    d = os.path.join(shards, "battery", "s2")
    with open(os.path.join(d, "rows.jsonl"), "w", encoding="utf-8") as fh:
        for p in POLICIES:
            fh.write(json.dumps(row("fault", 2, p)) + "\n")
    rc, log = run_merge(shards, out, "battery", "1,2", ",".join(POLICIES))
    check("자리를 잘못 잡은 샤드(행의 case 불일치)도 실패", rc == 1, "rc=%d" % rc)
    check("행이 신고한 case 를 찍는다", "case='fault'" in log, log.strip()[-400:])

# ---- 불완전 병합은 출력 파일을 남기지 않는다 (2026-08-13) --------------------------------
# rc=1 을 내기 전에 이미 <case>.jsonl 을 써 두면, rc 를 보지 않는 다음 도구가 그 부분 파일을
# 완전한 결과인 양 먹는다.
with tempfile.TemporaryDirectory() as tmp:
    shards = os.path.join(tmp, "shards"); out = os.path.join(tmp, "out")
    build_shards(shards, "battery", [1, 2, 3], POLICIES, skip={(2, "dspy")})
    rc, log = run_merge(shards, out, "battery", "1,2,3", ",".join(POLICIES))
    check("불완전 병합은 rc=1", rc == 1, "rc=%d" % rc)
    check("불완전 병합은 <case>.jsonl 을 만들지 않는다",
          not os.path.exists(os.path.join(out, "battery.jsonl")),
          "존재 여부=%s" % os.path.exists(os.path.join(out, "battery.jsonl")))

with tempfile.TemporaryDirectory() as tmp:
    shards = os.path.join(tmp, "shards"); out = os.path.join(tmp, "out")
    build_shards(shards, "battery", [1, 2, 3], POLICIES)
    rc, _ = run_merge(shards, out, "battery", "1,2,3", ",".join(POLICIES))
    good = open(os.path.join(out, "battery.jsonl"), encoding="utf-8").read()
    # 같은 out 디렉토리에 대고 이번엔 망가진 샤드 트리로 병합한다.
    os.remove(os.path.join(shards, "battery", "s2", "rows.jsonl"))
    rc2, _ = run_merge(shards, out, "battery", "1,2,3", ",".join(POLICIES))
    after = open(os.path.join(out, "battery.jsonl"), encoding="utf-8").read()
    check("실패한 재병합이 기존 완전본을 덮어쓰지 않는다", rc2 == 1 and after == good,
          "rc2=%d, 같은 내용=%s" % (rc2, after == good))

sys.exit(1 if FAILED else 0)
