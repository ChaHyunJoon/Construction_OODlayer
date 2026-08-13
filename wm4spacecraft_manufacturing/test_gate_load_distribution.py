"""gate_load_distribution.py 판정 로직 테스트.

판정이 틀리면 게이트가 있으나 마나다. 두 방향 다 확인한다: 분포가 같으면 통과해야 하고,
확실히 옮겨졌으면 불합격해야 한다. 합성 표본으로 검사하므로 시뮬레이션을 돌리지 않는다.
"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable
GATE = os.path.join(HERE, "gate_load_distribution.py")

FAILED = 0


def check(name, ok, detail=""):
    global FAILED
    print("  %s  %s   %s" % ("PASS" if ok else "FAIL", name, detail))
    if not ok:
        FAILED += 1


def build(root, samples):
    """samples = [(sim_seconds, closed, complete), ...] -> rep1..repN/rows.jsonl"""
    for i, (secs, closed, comp) in enumerate(samples, 1):
        d = os.path.join(root, "rep%d" % i)
        os.makedirs(d, exist_ok=True)
        row = {"case": "zone", "ood_seed": 1, "policy": "noop",
               "sim_seconds": secs, "closed": closed, "complete": comp,
               "geometry": {"depot_distance": 20.0}}
        with open(os.path.join(d, "rows.jsonl"), "w", encoding="utf-8") as fh:
            fh.write(json.dumps(row) + "\n")


def run_gate(solo, loaded, alpha="0.05"):
    p = subprocess.run([PY, GATE, "--solo-dir", solo, "--loaded-dir", loaded,
                        "--alpha", alpha], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


SAME_A = [(20.0, 100, True), (21.0, 101, True), (19.5, 99, True), (20.5, 100, True),
          (20.2, 102, True), (19.8, 98, True), (21.2, 101, True), (20.1, 100, True)]
SAME_B = [(20.3, 101, True), (19.7, 99, True), (20.8, 100, True), (20.0, 102, True),
          (19.9, 98, True), (21.1, 101, True), (20.4, 100, True), (20.6, 99, True)]
# 부하 하에서 sim_seconds 가 통째로 밀린 표본. 8 vs 8 완전 분리면 Mann-Whitney 양측 p 는
# 2/12870*2 ~= 0.00031 로 alpha 아래다.
SHIFTED = [(40.0, 100, True), (41.0, 101, True), (39.5, 99, True), (40.5, 100, True),
           (40.2, 102, True), (39.8, 98, True), (41.2, 101, True), (40.1, 100, True)]
# 완주율만 갈린 표본: 단독 8/8 완주 vs 부하 하 1/8 완주. Fisher exact 양측 p ~= 0.001.
COMPLETE_SPLIT = [(20.0, 100, True)] + [(20.0 + 0.1 * i, 100, False) for i in range(7)]

print("== gate_load_distribution.py ==")

with tempfile.TemporaryDirectory() as tmp:
    solo = os.path.join(tmp, "solo"); loaded = os.path.join(tmp, "loaded")
    build(solo, SAME_A); build(loaded, SAME_B)
    rc, log = run_gate(solo, loaded)
    check("같은 분포면 통과", rc == 0, "rc=%d %s" % (rc, log.strip()[-200:]))

with tempfile.TemporaryDirectory() as tmp:
    solo = os.path.join(tmp, "solo"); loaded = os.path.join(tmp, "loaded")
    build(solo, SAME_A); build(loaded, SHIFTED)
    rc, log = run_gate(solo, loaded)
    check("sim_seconds 가 옮겨지면 불합격", rc == 1, "rc=%d" % rc)
    check("sim_seconds 를 지목한다", "sim_seconds" in log, log.strip()[-300:])

with tempfile.TemporaryDirectory() as tmp:
    solo = os.path.join(tmp, "solo"); loaded = os.path.join(tmp, "loaded")
    build(solo, SAME_A); build(loaded, COMPLETE_SPLIT)
    rc, log = run_gate(solo, loaded)
    check("완주율이 갈리면 불합격", rc == 1, "rc=%d" % rc)
    check("complete 를 지목한다", "complete" in log, log.strip()[-300:])

with tempfile.TemporaryDirectory() as tmp:
    solo = os.path.join(tmp, "solo"); loaded = os.path.join(tmp, "loaded")
    build(solo, SAME_A[:2]); build(loaded, SAME_B)
    rc, log = run_gate(solo, loaded)
    check("표본이 너무 적으면 불합격 (조용한 통과 금지)", rc == 1, "rc=%d" % rc)

with tempfile.TemporaryDirectory() as tmp:
    solo = os.path.join(tmp, "solo"); loaded = os.path.join(tmp, "loaded")
    os.makedirs(solo); build(loaded, SAME_B)
    rc, log = run_gate(solo, loaded)
    check("한쪽이 비면 불합격", rc == 1, "rc=%d" % rc)

sys.exit(1 if FAILED else 0)
