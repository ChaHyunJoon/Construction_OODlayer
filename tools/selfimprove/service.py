"""버전당 서비스 프로세스 하나 · 배포 · 배수 (spec §5.1, §5.4 규칙 5–7, §0.0 R8).

🔴 서비스는 기동 시에만 적합하고 reload 가 없다 → 버전마다 새 프로세스, 판이 포트로 고정된다.
🔴 `/health` 200 은 세대 증거가 아니다 — agent_version·manifest_sha256·surro_tau·surro_rule 을 manifest 와
   대조하고 `generation.check_health` 를 **직접** 부른다(셸 래퍼는 아무것도 재지 않는다)."""
import datetime, json, os, signal, subprocess, sys, time, urllib.request
from . import paths, versions

SERVICE_DIR = os.path.join(paths.ROOT, "src", "respec", "llm_service")
sys.path.insert(0, SERVICE_DIR)
import generation  # noqa: E402

# results/2026-09-23-router-sol/README.md 의 기동 설정 그대로 (+ 비과금 캐시 재생 금지)
LLM_ENV = {"DSPY_MODEL_TYPE": "responses", "DSPY_TEMPERATURE": "none", "DSPY_MAX_TOKENS": "16000",
           "DSPY_CACHE": "0", "TOOL_SYNTHESIS": "1", "SYNTH_MULTI_AGENT": "1", "DSPY_PROGRAM": "__seed_only__"}


def _cfg(exp):
    return json.load(open(os.path.join(paths.state_dir(exp), "config.json")))


def ledger_path(exp, v):
    return os.path.join(paths.state_dir(exp), "ledgers", "%s.jsonl" % v)


def _msha(exp, v):
    return versions.sha256_file(os.path.join(paths.version_dir(exp, v), "manifest.json"))


def service_env(exp, v):
    m, vd = versions.load_manifest(exp, v), paths.version_dir(exp, v)
    env = dict(os.environ)
    env.update(LLM_ENV, DSPY_MODEL=_cfg(exp).get("llm_model", "gpt-5.6-sol"),
               ACTION_REGISTRY=os.path.join(vd, "action_registry.json"),
               SURRO_DATA=os.path.join(vd, "dataset.jsonl"), SURRO_TAU=repr(float(m["surro_tau"])),
               SURRO_RULE=m["surro_rule"], SELFIMPROVE_MANIFEST=os.path.join(vd, "manifest.json"),
               SYNTH_RECORD_LOG=ledger_path(exp, v))
    return env


def version_env(exp, v, port):
    """이 버전에 고정된 판(Julia)이 받는 env (spec §5.4 규칙 5)."""
    vd = paths.version_dir(exp, v)
    return dict(os.environ, SELFIMPROVE_VERSION=v, SELFIMPROVE_VERSION_DIR=vd, SELFIMPROVE_MANIFEST_SHA=_msha(exp, v),
                ACTION_REGISTRY=os.path.join(vd, "action_registry.json"), DSPY_URL="http://127.0.0.1:%d" % port)


def _get(url):
    with urllib.request.urlopen(url, timeout=5) as r:
        return json.loads(r.read())


def identity_problems(exp, v, h):
    m = versions.load_manifest(exp, v)
    bad = [k for k, want in (("agent_version", v), ("manifest_sha256", _msha(exp, v)),
                             ("surro_tau", float(m["surro_tau"])), ("surro_rule", m["surro_rule"]))
           if h.get(k) != want]
    ok, code, msg = generation.check_health(h, SERVICE_DIR, require_tool_synthesis=True, require_multi_agent=True)
    return bad + ([] if ok else ["generation:%s" % code])


def start(exp, v, port=None, cmd=None, wait_s=300):
    probs = versions.verify_version(exp, v)
    if probs:
        raise RuntimeError("version %s fails verify: %s" % (v, probs))
    port = port or _cfg(exp)["port_base"] + int(v[1:])
    argv = cmd(port) if cmd else [sys.executable, "-m", "uvicorn", "dspy_service:app", "--host", "127.0.0.1",
                                  "--port", str(port), "--workers", "1"]
    os.makedirs(os.path.join(paths.state_dir(exp), "services"), exist_ok=True)
    os.makedirs(os.path.dirname(ledger_path(exp, v)), exist_ok=True)
    log = open(os.path.join(paths.state_dir(exp), "services", "%s.log" % v), "a")
    p = subprocess.Popen(argv, env=service_env(exp, v), cwd=SERVICE_DIR, stdout=log, stderr=subprocess.STDOUT,
                         start_new_session=True)
    h, t0 = None, time.time()
    while time.time() - t0 < wait_s and p.poll() is None:
        try:
            h = _get("http://127.0.0.1:%d/health" % port)
            break
        except Exception:
            time.sleep(0.5)
    bad = ["no_health"] if h is None else identity_problems(exp, v, h)
    if bad:
        stop(p.pid)
        raise RuntimeError("[selfimprove] service %s on :%d refused: %s" % (v, port, bad))
    sp = os.path.join(paths.state_dir(exp), "services.json")
    reg = json.load(open(sp)) if os.path.exists(sp) else {}
    reg[v] = {"port": port, "pid": p.pid, "manifest_sha256": _msha(exp, v),
              "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "code_fingerprint": h.get("code_fingerprint")}
    json.dump(reg, open(sp, "w"), indent=1)
    return {"port": port, "pid": p.pid}


def stop(pid):
    try:
        os.killpg(os.getpgid(pid), signal.SIGTERM)
    except ProcessLookupError:
        return
    for _ in range(50):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        try:
            os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            pass
        time.sleep(0.1)


def deploy(exp, v, port=None, cmd=None):
    """D 게이트 통과 기록이 있어야만: verify → 기동 → 포인터 교체 → 부모 draining."""
    g = os.path.join(paths.state_dir(exp), "dev", v, "gate.json")
    rec = json.load(open(g)) if os.path.exists(g) else None
    if not rec or not rec.get("all_pass") or rec.get("manifest_sha256") != _msha(exp, v):
        raise RuntimeError("deploy %s refused: no passing D-gate record for this manifest" % v)
    h = start(exp, v, port=port, cmd=cmd)
    cur, csha = versions.read_current(exp)
    versions.activate(exp, v)
    versions.append_index(exp, cur, "draining", csha)
    return h


def inflight(exp, v):
    """이 버전으로 띄운 온라인 판 중 아직 안 끝난 것 (online.run 이 판마다 marker 를 쓰고 지운다)."""
    d = os.path.join(paths.state_dir(exp), "online", v, "inflight")
    return len(os.listdir(d)) if os.path.isdir(d) else 0


def drain_and_stop(exp, v):
    if inflight(exp, v):
        return False
    sp = os.path.join(paths.state_dir(exp), "services.json")
    reg = json.load(open(sp)) if os.path.exists(sp) else {}
    if v in reg:
        stop(reg[v]["pid"])
    versions.append_index(exp, v, "retired", _msha(exp, v))
    return True
