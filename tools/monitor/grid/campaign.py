#!/usr/bin/env python3
"""grid/campaign.py — 렌더 격자 campaign 의 manifest · 판 실행 · 스냅샷 · 요약.

(2026-09-23, tractor·X-wing 복구 계획서 Task 6b Step 3 · 6c · 7)

왜 파이썬인가: 판 하나의 env 를 **명시적으로** 짓고(상속 변수 제거 → manifest 값만 다시 넣기),
rc·timeout·elapsed·실제 스트림 경로·지문을 한 줄 JSON 으로 남기는 일은 셸보다 여기가 정확하다.
`render_one.sh`·`render_grid.sh` 는 이 파일을 부르는 얇은 래퍼다.

하위 명령
---------
  init <grid> --model M --lanes "…" --cases "…" --seeds "…" [--campaign-id ID]
        campaign.json 과 jobs.jsonl(계획된 판 전부)을 쓴다. 이미 있으면 **지문이 같을 때만**
        계획을 합친다(파일럿 → 전체 확대). 다르면 exit 3 — 새 campaign 으로 분리할 것.
        설정: 현재 셸 env + 격자 기본(DEMO_ANIM=0) + 복구 손잡이 명시 기본값
        (`policy.jl` `CONFIG_ENV_PINNED_DEFAULTS`) → `set_env`. 지문은 julia `run_fingerprint`
        가 계산한다(판정식을 여기 다시 적지 않는다). 파이썬 `tree_digest` 가 julia 의
        `code_dirty_digest` 와 같은지 init 때 대조한다(판마다의 표류 검사가 그 값을 쓴다).
  run-one <grid> <lane> <case> <seed>
        판 하나. 이미 채점됐고 지문·스트림이 맞으면 건너뛴다. 코드가 campaign 과 다르면
        **돌리지 않고** `error:fingerprint_drift`, 서비스 신원이 다르면 `error:service_drift` 를
        남기고 exit 255(xargs 가 격자를 멈춘다). 채점 안 된 이전 시도의 로그·스트림은
        `.attempt<N>` 으로 옮겨 보존한 뒤 다시 돈다.
  snapshot <grid>   복원 가능한 스냅샷(patch · 미추적 소스 tar · sha256 · HEAD)을 쓰고, 임시
                    clone 에 적용해 같은 code_dirty_digest 가 나오는지 확인한다(Task 6c Step 2).
  summarize <grid>  계획 판별 상태 표. 채점 안 된 판이 있으면 exit 1.
"""
import datetime
import hashlib
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
RENDER = os.path.join(ROOT, "tools", "monitor", "render_demo.jl")
POLICY = os.path.join(ROOT, "tools", "monitor", "policy.jl")

# policy.jl `_CODE_FINGERPRINT_PATHS` · `_CODE_FINGERPRINT_EXTS` 와 같아야 한다.
FP_PATHS = ("src", "tools", "test", "Project.toml", "Manifest.toml")
FP_EXTS = (".jl", ".py", ".sh", ".toml")

LANES = {"canonical": {"DEMO_ROUTER": "0", "DEMO_POLICY": "canonical"},
         "surrogate": {"DEMO_ROUTER": "0", "DEMO_POLICY": "surrogate"},
         "router":    {"DEMO_ROUTER": "1", "DEMO_POLICY": "canonical"}}
# 🔴 DEMO_OOD=zone* 은 render_demo.jl 에서 하드에러다. zone 은 DEMO_ZONE 으로 심는다.
CASES = {"battery": ("battery", False), "fault": ("fault", False),
         "all3": ("fault_battery", True), "zone": ("none", True)}
LANE_ORDER = ("all3", "zone", "battery", "fault")     # 긴 판을 먼저 — 꼬리에 몰리지 않게
GRID_DEFAULTS = {"DEMO_ANIM": "0"}
DRIFT_EXIT = 255                                      # xargs 는 255 에서 새 판을 안 띄운다


# =============================================================================================
# 순수 함수 (test_campaign.py)
# =============================================================================================
def model_base(model):
    import re
    return re.sub(r"[^A-Za-z0-9]+", "_", os.path.splitext(os.path.basename(model))[0])


def stream_name(base, lane, case, seed, zone_seed):
    """render_demo.jl: `<base>__<CASE_TAG><NSUF>.jsonl`, NSUF = SSUF * ZSUF (DEMO_N=0)."""
    ss = "" if seed == 1 else "_s%d" % seed
    zs = "" if zone_seed == 0 else "_z%d" % zone_seed
    return "%s__%s_%s%s%s.jsonl" % (base, lane, case, ss, zs)


def run_key(lane, case, seed):
    return "%s__%s__s%d" % (lane, case, seed)


def plan_jobs(camp, grid, lanes, cases, seeds):
    """계획된 판 목록. 모든 셀에 DEMO_SEED 와 DEMO_ZONE_SEED 를 명시한다(zone 포함)."""
    base = camp["model_base"]
    jobs = []
    for case in sorted(cases, key=lambda c: LANE_ORDER.index(c) if c in LANE_ORDER else 99):
        event, zone = CASES[case]
        for lane in lanes:
            for seed in seeds:
                seed = int(seed)
                k = run_key(lane, case, seed)
                jobs.append({
                    "run_key": k, "lane": lane, "case": case, "seed": seed, "zone_seed": seed,
                    "model": camp["model"],
                    "stream": os.path.join(grid, "streams",
                                           stream_name(base, lane, case, seed, seed)),
                    "log": os.path.join(grid, "log", k + ".log"),
                    "expect_ctx": {"campaign_id": camp["campaign_id"], "model": base,
                                   "seed": seed, "zone_seed": seed, "event": event,
                                   "zone": zone, "lane": lane, "case": "%s_%s" % (lane, case),
                                   "code_rev": camp["code_rev"],
                                   "code_dirty_digest": camp["code_dirty_digest"],
                                   "config_digest": camp["config_digest"]},
                    "lm_expected": lane == "router" and zone,
                })
    return jobs


def run_env(camp, job, parent, grid):
    """판 하나의 env. 분류된 이름·접두사 이름은 **전부 지우고** manifest 값만 다시 넣는다."""
    cl = camp["classes"]
    named = set(cl["result"]) | set(cl["cell_axis"]) | set(cl["observational"])
    pre = tuple(cl["prefixes"])
    env = {k: v for k, v in parent.items() if k not in named and not k.startswith(pre)}
    env.update(camp["set_env"])
    event, zone = CASES[job["case"]]
    env.update(LANES[job["lane"]])
    env.update({"DEMO_OOD": event, "DEMO_ZONE": "1" if zone else "0",
                "DEMO_SEED": str(job["seed"]), "DEMO_ZONE_SEED": str(job["zone_seed"]),
                "DEMO_MODEL": camp["model"],
                "DEMO_CASE_TAG": "%s_%s" % (job["lane"], job["case"]),
                "MONITOR_RUN_ID": job["run_key"], "DEMO_CAMPAIGN_ID": camp["campaign_id"],
                "DEMO_OUT_DIR": grid})
    return env


def run_ctx_of(txt):
    ctx = None
    for line in txt.splitlines():
        if line.startswith("[run-ctx] "):
            try:
                ctx = json.loads(line[len("[run-ctx] "):])
            except ValueError:
                ctx = None
    return ctx


def ctx_check(ctx, want):
    if not isinstance(ctx, dict):
        return ["run_ctx absent"]
    return ["%s=%r!=%r" % (k, ctx.get(k), v) if k in ctx else "%s absent" % k
            for k, v in want.items() if ctx.get(k, object()) != v]


def _stream_ok(path):
    if not os.path.isfile(path):
        return False
    last = None
    with open(path, "rb") as f:
        for line in f:
            if line.strip():
                last = line
    try:
        return last is not None and isinstance(json.loads(last), dict)
    except ValueError:
        return False


def log_status(txt, job, rc, timed_out):
    """(status, detail). scored | timeout | error | error:ctx_mismatch | error:stream_missing."""
    bad = ctx_check(run_ctx_of(txt), job["expect_ctx"])
    if bad and run_ctx_of(txt) is not None:
        return "error:ctx_mismatch", "; ".join(bad)
    if "\n[score] " not in "\n" + txt:
        return ("timeout" if timed_out else "error"), "rc=%s, no [score] line" % rc
    if bad:
        return "error:ctx_mismatch", "; ".join(bad)
    if not _stream_ok(job["stream"]):
        return "error:stream_missing", "manifest stream %s" % job["stream"]
    return "scored", ""


# 서비스 **신원** 키(최종 리뷰 I1). calls·billed 같은 카운터는 판마다 바뀌므로 대조하지 않는다.
SERVICE_KEYS = ("code_fingerprint", "policy", "synth_tool_synthesis", "synth_multi_agent",
                "model_type", "temperature", "program", "surrogate", "source_dir",
                "repair_ablation")


def service_check(camp, fetch):
    """campaign 을 연 서비스와 지금 서비스가 같은가. 다르면 문제 목록(빈 목록 = 같다).

    surrogate·router 레인의 결정은 서비스가 내므로, 도중 재기동(다른 코드·플래그·모델)이면 판이
    조용히 섞인다 — julia 의 config_digest 는 서비스 쪽 env 를 못 본다.
    """
    svc = camp.get("service")
    if not svc or not svc.get("url"):
        return []
    now = fetch(svc["url"])
    if "unreachable" in now:
        return ["unreachable: %s" % now["unreachable"]]
    want = svc.get("health") or {}
    return ["%s=%r!=%r" % (k, now.get(k), want.get(k)) for k in SERVICE_KEYS
            if k in want and now.get(k) != want.get(k)]


REPAIR_ABLATION_LEVELS = ("none", "translate", "all")
SERVICE_LANES = ("router", "surrogate")            # 결정을 DSPy 서비스가 내는 레인
DSPY_URL_DEFAULT = "http://127.0.0.1:8077"         # policy.jl `const DSPY_URL` 의 기본값과 같아야 한다


def ablation_init_problems(set_env, lanes, fetch):
    """init 의 빠른 실패(최종 리뷰 m5). 빈 목록 = 통과.

    - `set_env` 에 얼린 REPAIR_ABLATION 이 정확히 none/translate/all 인가(오타면 판마다 하나씩
      죽는다 — 크지만 느리다).
    - 서비스가 결정하는 레인(router·surrogate)이 있으면, 판이 쓸 서비스(얼린 DSPY_URL, 없으면 julia
      기본 포트)의 `/health.repair_ablation` 이 같은 레벨인가(다른 팔의 포트를 가리키면 첫 판 전에
      멈춘다). 닿지 않아도 멈춘다 — 레벨을 확인할 수 없다.
    """
    lvl = set_env.get("REPAIR_ABLATION")
    if lvl not in REPAIR_ABLATION_LEVELS:
        return ["REPAIR_ABLATION=%r — allowed exactly: none, translate, all" % (lvl,)]
    if not any(l in SERVICE_LANES for l in lanes):
        return []
    # 비어 있으면 julia 가 쓰는 기본 포트(policy.jl `DSPY_URL`) — 변수를 안 준 잘못된 포트 기동도 잡는다
    url = set_env.get("DSPY_URL") or DSPY_URL_DEFAULT
    h = fetch(url)
    if "unreachable" in h:
        return ["service %s unreachable (%s) — cannot confirm repair_ablation=%s"
                % (url, h["unreachable"], lvl)]
    if h.get("repair_ablation") != lvl:
        return ["service %s repair_ablation=%r != campaign REPAIR_ABLATION=%r"
                % (url, h.get("repair_ablation"), lvl)]
    return []


def preserve_prior_attempt(job):
    """채점 안 된 이전 시도의 로그·스트림을 `.attempt<N>` 으로 옮긴다(최종 리뷰 I2).

    다시 돌리면 로그는 "wb" 로, 스트림은 monitor 가 잘라 원래 오류가 사라졌다 — 계획서 Task 8
    "원래 오류를 보존한다". 옮긴 경로 목록을 돌려준다.
    """
    moved = []
    log, stream = job["log"], job["stream"]
    if not os.path.exists(log) and not os.path.exists(stream):
        return moved
    n = 1
    while os.path.exists("%s.attempt%d.log" % (log[:-4], n)) or \
            os.path.exists("%s.attempt%d.jsonl" % (stream[:-6], n)):
        n += 1
    for src, dst in ((log, "%s.attempt%d.log" % (log[:-4], n)),
                     (stream, "%s.attempt%d.jsonl" % (stream[:-6], n))):
        if os.path.exists(src):
            os.replace(src, dst)
            moved.append(dst)
    return moved


def _git_bytes(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, check=True).stdout


def tree_digest(repo):
    """policy.jl `_code_dirty_digest` 의 파이썬 판(같은 입력·같은 해시). 깨끗하면 ""."""
    tracked = _git_bytes(repo, "diff", "--no-color", "--no-ext-diff", "HEAD", "--", *FP_PATHS)
    raw = _git_bytes(repo, "ls-files", "--others", "--exclude-standard", "-z", "--", *FP_PATHS)
    untracked = sorted(p for p in raw.decode("utf-8").split("\0")
                       if p and p.endswith(FP_EXTS))
    if not tracked and not untracked:
        return ""
    h = hashlib.sha256(tracked)
    for p in untracked:
        h.update(("\0untracked\0%s\0" % p).encode("utf-8"))
        try:
            with open(os.path.join(repo, p), "rb") as f:
                h.update(f.read())
        except OSError:
            h.update(b"\0unreadable\0")
    return h.hexdigest()[:16]


def head_rev(repo):
    return _git_bytes(repo, "rev-parse", "HEAD").decode().strip()


# =============================================================================================
# init
# =============================================================================================
_JL = r'''
include(ARGS[1]); import JSON3
raw = Dict{String,String}(String(k) => String(v) for (k, v) in JSON3.read(read(ARGS[2], String)))
set = Dict{String,String}()
for k in CONFIG_ENV_RESULT
    haskey(raw, k) ? (set[k] = raw[k]) :
    haskey(CONFIG_ENV_PINNED_DEFAULTS, k) && (set[k] = CONFIG_ENV_PINNED_DEFAULTS[k])
end
for (k, v) in raw
    (haskey(set, k) || k in _CONFIG_ENV_EXCLUDED) && continue
    any(p -> startswith(k, p), _CONFIG_ENV_PREFIXES) && (set[k] = v)
end
fp = run_fingerprint(; env = set)
println("@@CAMPAIGN@@", JSON3.write(Dict(
    "classes" => Dict("result" => CONFIG_ENV_RESULT, "cell_axis" => CONFIG_ENV_CELL_AXIS,
                      "observational" => CONFIG_ENV_OBSERVATIONAL,
                      "prefixes" => collect(_CONFIG_ENV_PREFIXES)),
    "pinned" => CONFIG_ENV_PINNED_DEFAULTS, "set_env" => set,
    "code_rev" => fp.code_rev, "code_dirty_digest" => fp.code_dirty_digest,
    "config_digest" => fp.config_digest, "config_env" => fp.config_env,
    "julia" => string(VERSION))))
'''


def _julia_campaign(raw_env):
    with tempfile.TemporaryDirectory() as d:
        ep, sp = os.path.join(d, "env.json"), os.path.join(d, "c.jl")
        with open(ep, "w") as f:
            json.dump(raw_env, f)
        with open(sp, "w") as f:
            f.write(_JL)
        out = subprocess.run(["julia", "+lts", "--project=%s" % ROOT, sp, POLICY, ep],
                             capture_output=True, text=True, cwd=ROOT)
    for line in out.stdout.splitlines():
        if line.startswith("@@CAMPAIGN@@"):
            return json.loads(line[len("@@CAMPAIGN@@"):])
    raise SystemExit("julia campaign step failed (rc=%d):\n%s" % (out.returncode,
                                                                  out.stderr[-3000:]))


def _health(url):
    try:
        with urllib.request.urlopen(url.rstrip("/") + "/health", timeout=10) as r:
            return json.loads(r.read().decode())
    except Exception as e:  # noqa: BLE001
        return {"unreachable": "%s: %s" % (type(e).__name__, e)}


def _words(v):
    return v.replace(",", " ").split()


def cmd_init(grid, model, lanes, cases, seeds, campaign_id=None):
    grid = os.path.abspath(grid)
    os.makedirs(os.path.join(grid, "log"), exist_ok=True)
    raw = dict(os.environ)
    for k, v in GRID_DEFAULTS.items():
        raw.setdefault(k, v)
    j = _julia_campaign(raw)
    bad = ablation_init_problems(j["set_env"], lanes, _health)
    if bad:
        raise SystemExit("[campaign] init refused: " + "; ".join(bad))
    py = tree_digest(ROOT)
    if py != j["code_dirty_digest"]:
        raise SystemExit("tree_digest (python %r) != julia code_dirty_digest (%r) — the "
                         "per-run drift check would be meaningless" % (py, j["code_dirty_digest"]))
    cpath = os.path.join(grid, "campaign.json")
    fresh = {
        "model": model, "model_base": model_base(model),
        "code_rev": j["code_rev"], "code_dirty_digest": j["code_dirty_digest"],
        "config_digest": j["config_digest"], "config_env": j["config_env"],
        "set_env": j["set_env"], "classes": j["classes"], "pinned": j["pinned"],
        "versions": {"julia": j["julia"], "python": sys.version.split()[0]},
    }
    if os.path.isfile(cpath):
        with open(cpath) as f:
            camp = json.load(f)
        diff = [k for k in ("model", "code_rev", "code_dirty_digest", "config_digest")
                if camp[k] != fresh[k]]
        if diff:
            print("campaign %s: fingerprint differs in %s — start a NEW campaign (new grid "
                  "dir); runs are never mixed across fingerprints" % (camp["campaign_id"], diff),
                  file=sys.stderr)
            return 3
    else:
        url = fresh["set_env"].get("DSPY_URL")
        camp = dict(fresh, campaign_id=campaign_id or "%s-%s" % (
            os.path.basename(grid), datetime.datetime.now().strftime("%Y%m%dT%H%M%S")),
            created=datetime.datetime.now().astimezone().isoformat(), root=ROOT, grid=grid,
            service=({"url": url, "health": _health(url)} if url else None))
        with open(cpath, "w") as f:
            json.dump(camp, f, indent=1, sort_keys=True)
    jpath = os.path.join(grid, "jobs.jsonl")
    old = {}
    if os.path.isfile(jpath):
        with open(jpath) as f:
            old = {x["run_key"]: x for x in map(json.loads, filter(str.strip, f))}
    new = plan_jobs(camp, grid, lanes, cases, seeds)
    merged = list(old.values()) + [x for x in new if x["run_key"] not in old]
    with open(jpath, "w") as f:
        for x in merged:
            f.write(json.dumps(x) + "\n")
    print("[campaign] %s planned=%d (+%d) code_rev=%s dirty=%s config=%s"
          % (camp["campaign_id"], len(merged), len(merged) - len(old), camp["code_rev"][:8],
             camp["code_dirty_digest"] or "clean", camp["config_digest"]))
    return 0


# =============================================================================================
# run-one
# =============================================================================================
def _load(grid):
    with open(os.path.join(grid, "campaign.json")) as f:
        camp = json.load(f)
    with open(os.path.join(grid, "jobs.jsonl")) as f:
        jobs = {x["run_key"]: x for x in map(json.loads, filter(str.strip, f))}
    return camp, jobs


def _append(path, obj):
    line = (json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8")
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, line)                 # 한 번의 write — 동시 판의 줄이 섞이지 않는다
    finally:
        os.close(fd)


def cmd_run_one(grid, lane, case, seed, timeout_s=None):
    grid = os.path.abspath(grid)
    camp, jobs = _load(grid)
    key = run_key(lane, case, int(seed))
    job = jobs.get(key)
    if job is None:
        print("[FAIL] %s is not in jobs.jsonl" % key)
        return 2
    runs = os.path.join(grid, "runs.jsonl")
    rec = {"run_key": key, "lane": lane, "case": case, "seed": int(seed),
           "campaign_id": camp["campaign_id"], "stream": job["stream"], "log": job["log"]}
    # 재개: 채점까지 갔고 지문·스트림이 맞는 판만 건너뛴다.
    if os.path.isfile(job["log"]):
        with open(job["log"], errors="replace") as f:
            prev = f.read()
        if log_status(prev, job, None, False)[0] == "scored":
            print("[skip] %s" % key)
            return 0
    # 표류: campaign 을 연 코드와 지금 트리가 다르면 **돌리지 않는다**.
    now_rev, now_dirty = head_rev(ROOT), tree_digest(ROOT)
    if (now_rev, now_dirty) != (camp["code_rev"], camp["code_dirty_digest"]):
        rec.update(status="error:fingerprint_drift", rc=None, timeout=False, elapsed=0,
                   detail="now rev=%s dirty=%s vs campaign rev=%s dirty=%s"
                   % (now_rev[:8], now_dirty, camp["code_rev"][:8], camp["code_dirty_digest"]),
                   at=datetime.datetime.now().astimezone().isoformat())
        _append(runs, rec)
        print("[DRIFT] %s — %s" % (key, rec["detail"]))
        return DRIFT_EXIT
    bad = service_check(camp, _health)
    if bad:
        rec.update(status="error:service_drift", rc=None, timeout=False, elapsed=0,
                   detail="; ".join(bad), at=datetime.datetime.now().astimezone().isoformat())
        _append(runs, rec)
        print("[DRIFT] %s — service %s" % (key, rec["detail"]))
        return DRIFT_EXIT
    rec["prior_attempts_moved"] = preserve_prior_attempt(job)
    env = run_env(camp, job, os.environ, grid)
    timeout_s = timeout_s or int(os.environ.get("RUN_TIMEOUT", "3600"))
    os.makedirs(os.path.dirname(job["log"]), exist_ok=True)
    st = time.time()
    timed_out = False
    with open(job["log"], "wb") as lf:
        p = subprocess.Popen(["julia", "+lts", "--project=%s" % ROOT, RENDER], env=env,
                             stdout=lf, stderr=subprocess.STDOUT, cwd=ROOT,
                             start_new_session=True)
        try:
            rc = p.wait(timeout=timeout_s)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(p.pid, signal.SIGTERM)
            try:
                p.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL)
                p.wait()
            rc = 124
    el = round(time.time() - st, 1)
    with open(job["log"], errors="replace") as f:
        txt = f.read()
    status, detail = log_status(txt, job, rc, timed_out)
    ctx = run_ctx_of(txt) or {}
    rec.update(status=status, detail=detail, rc=rc, timeout=timed_out, elapsed=el,
               stream_bytes=(os.path.getsize(job["stream"]) if os.path.isfile(job["stream"])
                             else None),
               run_fp={k: ctx.get(k) for k in ("code_rev", "code_dirty_digest", "config_digest")},
               at=datetime.datetime.now().astimezone().isoformat())
    _append(runs, rec)
    with open(os.path.join(grid, "wall.csv"), "a") as f:
        f.write("%s,%s,%d\n" % (key, rc, int(el)))
    print("[%s %.0fs rc=%s] %s%s" % ("ok" if status == "scored" else "FAIL " + status, el, rc,
                                    key, (" — " + detail) if detail else ""))
    return 0 if status == "scored" else 1


# =============================================================================================
# snapshot (Task 6c Step 2)
# =============================================================================================
def cmd_snapshot(grid):
    grid = os.path.abspath(grid)
    camp, _ = _load(grid)
    sd = os.path.join(grid, "snapshot")
    os.makedirs(sd, exist_ok=True)
    head = head_rev(ROOT)
    patch = _git_bytes(ROOT, "diff", "--binary", "HEAD", "--", *FP_PATHS)
    with open(os.path.join(sd, "tree.patch"), "wb") as f:
        f.write(patch)
    raw = _git_bytes(ROOT, "ls-files", "--others", "--exclude-standard", "-z", "--", *FP_PATHS)
    untracked = sorted(p for p in raw.decode().split("\0") if p and p.endswith(FP_EXTS))
    tar = os.path.join(sd, "untracked_sources.tar")
    subprocess.run(["tar", "-cf", tar, "-C", ROOT, "--", *untracked], check=True)
    sums = {}
    for n in ("tree.patch", "untracked_sources.tar"):
        with open(os.path.join(sd, n), "rb") as f:
            sums[n] = hashlib.sha256(f.read()).hexdigest()
    with tempfile.TemporaryDirectory() as tmp:
        clone = os.path.join(tmp, "c")
        subprocess.run(["git", "clone", "-q", "--shared", "--no-checkout", ROOT, clone],
                       check=True)
        subprocess.run(["git", "-C", clone, "checkout", "-q", head, "--", *FP_PATHS,
                        ".gitignore"], check=True)
        subprocess.run(["git", "-C", clone, "checkout", "-q", "--detach", head],
                       capture_output=True)       # HEAD 를 같은 커밋에 둔다(작업 트리는 안 건드림)
        if patch:
            subprocess.run(["git", "-C", clone, "apply", "--binary",
                            os.path.join(sd, "tree.patch")], check=True)
        subprocess.run(["tar", "-xf", tar, "-C", clone], check=True)
        restored = tree_digest(clone)
        clone_head = head_rev(clone)
    ok = restored == camp["code_dirty_digest"] and clone_head == camp["code_rev"] == head
    meta = {"head": head, "sha256": sums, "untracked": untracked,
            "restored_code_dirty_digest": restored, "campaign_code_dirty_digest":
            camp["code_dirty_digest"], "restore_verified": ok,
            "restore": "git checkout %s && git apply --binary tree.patch && "
                       "tar -xf untracked_sources.tar" % head}
    with open(os.path.join(sd, "snapshot.json"), "w") as f:
        json.dump(meta, f, indent=1)
    print("[snapshot] %s restored=%s campaign=%s verified=%s"
          % (sd, restored, camp["code_dirty_digest"], ok))
    return 0 if ok else 1


# =============================================================================================
# summarize
# =============================================================================================
def cmd_summarize(grid):
    grid = os.path.abspath(grid)
    camp, jobs = _load(grid)
    last = {}
    rp = os.path.join(grid, "runs.jsonl")
    if os.path.isfile(rp):
        with open(rp) as f:
            for r in map(json.loads, filter(str.strip, f)):
                last[r["run_key"]] = r
    from collections import Counter
    c = Counter()
    for k, j in jobs.items():
        r = last.get(k)
        if r is None:
            st = "scored" if os.path.isfile(j["log"]) and log_status(
                open(j["log"], errors="replace").read(), j, None, False)[0] == "scored" \
                else "missing"
        else:
            st = r["status"]
        c[st] += 1
    print("[summary] %s planned=%d %s" % (camp["campaign_id"], len(jobs), dict(sorted(c.items()))))
    return 0 if c.get("scored", 0) == len(jobs) else 1


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "init":
        import argparse
        ap = argparse.ArgumentParser()
        ap.add_argument("grid"); ap.add_argument("--model", required=True)
        ap.add_argument("--lanes", required=True); ap.add_argument("--cases", required=True)
        ap.add_argument("--seeds", required=True); ap.add_argument("--campaign-id")
        a = ap.parse_args(rest)
        return cmd_init(a.grid, a.model, _words(a.lanes), _words(a.cases),
                        [int(s) for s in _words(a.seeds)], a.campaign_id)
    if cmd == "run-one":
        return cmd_run_one(*rest)
    if cmd == "snapshot":
        return cmd_snapshot(*rest)
    if cmd == "summarize":
        return cmd_summarize(*rest)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
