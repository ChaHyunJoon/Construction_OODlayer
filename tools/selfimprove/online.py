"""온라인 구동기 (spec §5.2, §5.4 규칙 5, §0.0 R8): 판마다 포인터를 **한 번** 읽어 그 버전에 고정한다.
코드·피처 스키마가 버전을 만든 때와 다르면 판을 안 띄운다(`--allow-code-drift` 는 없다)."""
import json, os, subprocess, sys, threading
from concurrent.futures import ThreadPoolExecutor
from . import harvest, paths, probe, service, versions

sys.path.insert(0, os.path.join(paths.ROOT, "tools", "monitor", "grid"))
import campaign  # noqa: E402

CAMPAIGN = os.path.join(paths.ROOT, "tools", "monitor", "grid", "campaign.py")


def _cfg(exp):
    return json.load(open(os.path.join(paths.state_dir(exp), "config.json")))


def code_identity():
    rev = subprocess.run(["git", "rev-parse", "HEAD"], cwd=paths.ROOT, capture_output=True, text=True).stdout.strip()
    return rev, campaign.tree_digest(paths.ROOT)


def launch_env(exp):
    v, _ = versions.read_current(exp)
    probs = versions.verify_version(exp, v)
    if probs:
        raise RuntimeError("current version %s fails verify: %s" % (v, probs))
    m = versions.load_manifest(exp, v)
    if code_identity() != (m["code_rev"], m["code_dirty_digest"]):
        raise RuntimeError("code drift: tree %s != version %s (%s, %s) — new experiment or rebuild"
                           % (code_identity(), v, m["code_rev"], m["code_dirty_digest"]))
    if probe.feature_schema_sha256() != m["feature_schema_sha256"]:
        raise RuntimeError("feature schema drift vs version %s" % v)
    sp = os.path.join(paths.state_dir(exp), "services.json")
    svc = json.load(open(sp)).get(v) if os.path.exists(sp) else None
    port = svc["port"] if svc else _cfg(exp)["port_base"] + int(v[1:])
    return service.version_env(exp, v, port)


def schedule(exp, n):
    """시드 수열 × (model, case) 라운드로빈. 다음 위치는 영속된다."""
    cfg = _cfg(exp)
    p = os.path.join(paths.state_dir(exp), "online", "next.json")
    i = json.load(open(p))["i"] if os.path.exists(p) else 0
    pairs = [(m, c) for m in cfg["models"] for c in cfg["zone_cases"]]
    out = [pairs[(i + k) % len(pairs)] + (cfg["harvest_seed0"] + i + k,) for k in range(n)]
    os.makedirs(os.path.dirname(p), exist_ok=True)
    json.dump({"i": i + n}, open(p, "w"))
    return out


_GRID_LOCKS = {}


def _one(exp, model, case, seed, runner):
    env = launch_env(exp)                                   # 🔴 이 판의 버전은 여기서 한 번 정해진다
    v = env["SELFIMPROVE_VERSION"]
    grid = os.path.join(paths.state_dir(exp), "online", v, model)
    rk = "router__%s__s%d" % (case, seed)
    mark = os.path.join(paths.state_dir(exp), "online", v, "inflight", "%s__%s" % (model, rk))
    os.makedirs(os.path.dirname(mark), exist_ok=True)
    open(mark, "w").close()
    try:
        with _GRID_LOCKS.setdefault(grid, threading.Lock()):
            runner(["init", grid, "--model", paths.MODEL_FILES[model], "--lanes", "router", "--cases", case,
                    "--seeds", str(seed), "--campaign-id", "si-%s-%s-%s" % (exp, v, model)], env)
        runner(["run-one", grid, "router", case, str(seed)], env)
        return harvest.harvest_run(exp, grid, rk, service.ledger_path(exp, v))
    finally:
        os.remove(mark)


def run(exp, n_runs=None, runner=None):
    """n_runs 판(None 이면 끝없이). runner(args, env) 는 시험이 주입한다(기본 campaign.py)."""
    runner = runner or (lambda args, env: subprocess.run([sys.executable, CAMPAIGN, *args], env=env,
                                                         cwd=paths.ROOT, check=False))
    workers = _cfg(exp)["online_workers"]
    done = 0
    with ThreadPoolExecutor(workers) as ex:
        while n_runs is None or done < n_runs:
            k = workers if n_runs is None else min(workers, n_runs - done)
            list(ex.map(lambda j: _one(exp, *j, runner), schedule(exp, k)))
            done += k
