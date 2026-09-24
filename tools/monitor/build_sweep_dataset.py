#!/usr/bin/env python3
"""실패-사건 격자(4 사건 × 30 시드 × 3 레인)를 대시보드가 읽는 sweep360.json 으로 굽는다.

사용법
------
    python3 tools/monitor/build_sweep_dataset.py [옵션] <격자출력디렉터리> [...]

      --model <파일명>   기본 tractor.mpd
      --base  <스트림 base>  기본은 모델명에서 유도 (비영숫자 -> "_")
      --out   <경로>     기본 tools/monitor/sweep_<base>.json (tractor 는 sweep360.json)
      --streams-root <dir>  기본 tools/monitor (DEMO_OUT_DIR 로 돈 격자는 그 디렉터리)
      --lanes "<l …>" --cases "<c …>" --seeds "<s …>"
                         계획된 판 집합(분모). 기본 canonical surrogate router × 네 사건 × 1..30.
      --jobs <jobs.jsonl> 격자 manifest(`grid/campaign.py` 가 쓴다). 주면 **그 목록이 분모**이고
                         판마다 manifest 의 정확한 스트림 경로·기대 run_ctx 를 쓴다(옛 이름
                         fallback 없음). 같은 디렉터리의 runs.jsonl 에서 rc·timeout·드라이버 판정을
                         읽는다. --lanes/--cases/--seeds 는 무시된다.

판 상태(분모): planned ⊇ executed ⊇ scored ⊇ complete. 채점 전에 끝난 판은 timeout / error /
error:<사유>(fingerprint_drift · ctx_mismatch · stream_missing) / missing 으로 **분모에 남는다**
(`unscored` 목록과 셀별 `denominators`). `runs` 는 채점된 판만 담는다(대시보드 호환).

각 디렉터리는 `log/<lane>__<case>__s<seed>.log` 를 담고 있어야 한다(드라이버가 쓴 그대로).
스트림은 `tools/monitor/streams/<base>__<lane>_<case>_z<seed>.jsonl` 에서 찾는다 --
격자를 `DEMO_CASE_TAG=<lane>_<case>` 로 돌렸기 때문이고, 그래서 세 레인이 같은 파일을
덮어쓰지 않는다.

스케줄 노드 총수(진척도의 분모)는 **로그에서 읽는다**(`n_total: <N>`) -- 모델마다 다르므로
화면도 이 스크립트도 그 수를 상수로 갖지 않는다.

원칙
----
집계본을 안 믿는다. 완주 여부·진척도·makespan·에너지·주조 여부를 전부 **로그와 스트림에서
재추출**한다. 화면은 이 파일만 읽고 상수를 하나도 안 갖는다 -- 격자를 다시 돌리면 이 스크립트를
다시 돌리는 것으로 화면이 따라온다.

주의할 두 가지
-------------
1. `[minted]` 는 **줄의 유무가 아니라 `lane=present`** 로 세야 한다. 같은 줄이
   `lane=absent` / `lane=impl_name_nothing` 으로도 찍히기 때문에, 줄만 세면 도구를 하나도
   안 만든 레인이 "30/30 주조" 로 나온다.
2. 미완주를 한 덩어리로 세면 **완주율이 곧 합성 성적**이라는 오독이 생긴다. 존이 치워졌는데도
   (`n_blocked=0` 이고 project 가 안 막혔는데도) 안 끝난 판은 세계가 언 것이다 -- 여기서
   `fail_mode="world_deadlock"` 으로 따로 센다.
"""
import hashlib, json, os, re, sys, glob, statistics as st
from collections import Counter

HERE    = os.path.dirname(os.path.abspath(__file__))
MONITOR = HERE
STREAMS = os.path.join(MONITOR, "streams")
ENGINE  = "tools/monitor/render_demo.jl"      # 🔴 합성 집행은 이 엔진에만 있다(run_demo.jl 아님)
LANES   = ["canonical", "surrogate", "router"]
CASES   = ["battery", "fault", "zone", "all3"]


def model_base(model):
    """render_demo.jl:117 과 **같은 규칙**이어야 스트림 이름이 맞는다."""
    return re.sub(r"[^A-Za-z0-9]+", "_", os.path.splitext(os.path.basename(model))[0])


def grab(txt, pat, cast=str, default=None):
    m = re.search(pat, txt)
    return cast(m.group(1)) if m else default


def find_stream(base, lane, case, seed, root=MONITOR):
    """render_demo.jl:65-67 의 이름 규칙을 그대로 훑는다.

        NSUF = [_n<N>] * SSUF * ZSUF
        SSUF = DEMO_SEED == 1      ? "" : "_s<k>"     (로봇 OOD 추첨 축)
        ZSUF = DEMO_ZONE_SEED == 0 ? "" : "_z<k>"     (존 배치 축)

    두 축을 다 쓰는 격자와 존 축만 쓰던 옛 격자가 섞여 있으므로 후보를 순서대로 본다.
    맨 앞이 현행 규칙이다 -- 옛 이름을 먼저 보면 새 격자가 옛 판을 집어 올 수 있다.
    🔴 이 fallback 은 **legacy 입력 전용**이다(seed≠1 에서 "" 후보가 시드 1 의 파일을 줍는다).
    manifest(--jobs) 로 돈 격자는 `collect_jobs` 가 정확한 경로만 쓴다.
    """
    ss = "" if seed == 1 else "_s%d" % seed
    for suf in ("%s_z%d" % (ss, seed), "_z%d" % seed, ss, ""):
        rel = "streams/%s__%s_%s%s.jsonl" % (base, lane, case, suf)
        if os.path.exists(os.path.join(root, rel)):
            return rel
    return None


def last_json_line(path):
    last = None
    try:
        with open(path, errors="replace") as f:
            for line in f:
                if line.strip():
                    last = line
    except FileNotFoundError:
        return None
    if not last:
        return None
    try:
        return json.loads(last)
    except Exception:
        return None


def first_json_line(path):
    try:
        with open(path, errors="replace") as f:
            for line in f:
                if line.strip():
                    return json.loads(line)
    except (FileNotFoundError, ValueError):
        return None
    return None


def _fp(obj):
    return hashlib.sha256(json.dumps(obj, sort_keys=True).encode()).hexdigest()[:16]


def stream_facts(path):
    """스트림 한 판의 사실: 마지막 프레임 · 실제 발생한 OOD · 초기 상태 지문.

    `init_fp` = 첫 프레임의 (n_closed, 로봇별 id·위치(1e-3)·SoC(1e-4)) 해시 — 같은 시드의 두 판은
    같고 다른 시드끼리는 달라야 한다(Task 8 Step 2 의 주 검사). `ood_events` 는 마지막 프레임의
    `ood` 목록(kind·at·대상). 🔴 로봇 OOD 항목의 `at` 은 스트림에서 null 이다 — 발생 시각은
    결정 이력의 `at`(closed 수)이 나른다(`decisions[].at`).
    """
    last = last_json_line(path)
    if last is None:
        return None
    first = first_json_line(path) or {}
    robots = sorted((str(r.get("id")),
                     [round(float(x), 3) for x in (r.get("pos") or [])],
                     None if r.get("soc") is None else round(float(r["soc"]), 4))
                    for r in (first.get("robots") or []) if isinstance(r, dict))
    ev = [{"kind": e.get("kind"), "at": e.get("at"),
           "target": e.get("target") or e.get("robot") or e.get("zone") or e.get("assembly")}
          for e in (last.get("ood") or []) if isinstance(e, dict)]
    return {"last": last, "init_fp": _fp({"n_closed": first.get("n_closed"), "robots": robots}),
            "ood_events": ev, "ood_fp": _fp(ev)}


_ARMED_RE = re.compile(r">>> OOD armed: zone\u00d7(\d+).*? \+ ([A-Za-z_/]+)\u00d7(\d+)(.*)")


def ood_intended(txt):
    """`>>> OOD armed:` 줄이 말하는 의도한 사건 — {zone, robot_kinds, n_robot, seed} 또는 None."""
    m = _ARMED_RE.search(txt)
    if not m:
        return None
    kinds = [] if m.group(2) == "none" else m.group(2).split("/")
    sd = re.search(r"seed=(-?\d+)", m.group(4))
    return {"zone": int(m.group(1)), "robot_kinds": kinds, "n_robot": int(m.group(3)),
            "seed": int(sd.group(1)) if sd else None}


def ood_reached(exp, kinds):
    """의도한 사건이 실제로 다 났나. 실행 중단으로 미발생한 사건은 복구로 세지 않는다."""
    if exp is None:
        return None
    if kinds.get("zone", 0) < exp["zone"]:
        return False
    rk = exp["robot_kinds"]
    if sum(kinds.get(k, 0) for k in rk) < exp["n_robot"]:
        return False
    return sum(1 for k in rk if kinds.get(k, 0) >= 1) >= min(exp["n_robot"], len(rk))


_RESTAGE_RE = re.compile(r"\[RESPEC\] restage_all (\w+)")


def restage_statuses(txt):
    """로그에 찍힌 `restage_all` 결과 상태들(순서대로).

    ⚠️ 계측 한계: infeasible·partial 은 `@warn`(항상 보인다), residual_blocked 는 `@info`
    (render 기본 Warn 에서 **안 보인다**), ok·none 은 아예 안 찍힌다 — `restage_observed`.
    """
    return _RESTAGE_RE.findall(txt)


def restage_observed(txt):
    """"info": Info 수준 로그라 residual_blocked 까지 보인다. "warn": infeasible·partial 만."""
    return "info" if re.search(r"Info: \[RESPEC\]", txt) else "warn"


_CTX_RE = re.compile(r"^\[run-ctx\] (\{.*\})\s*$", re.M)


def run_ctx_of(txt):
    """로그의 `[run-ctx] {…}` 줄(render_demo 가 기동 때 한 번 찍는다). 없거나 깨지면 None."""
    m = None
    for m in _CTX_RE.finditer(txt):
        pass
    if not m:
        return None
    try:
        return json.loads(m.group(1))
    except ValueError:
        return None


def reform_exhausted(txt, ctx):
    """실제 reform 예산 소진(`[reform] budget exhausted` — 소진 뒤 알람이 무시되기 시작했다).

    `reform_limit_reached`(마지막 허용 시도에 **도달**)와 다르다 — 그 뒤 성공할 수 있다.
    표지는 2026-09-23 render_demo 에 들어왔다: run-ctx 에 `config_env` 가 있는(같은 판 이후의)
    엔진이면 표지 부재 = False, 그 전 엔진이면 None(unknown).
    """
    if "[reform] budget exhausted" in txt:
        return True
    return False if isinstance(ctx, dict) and "config_env" in ctx else None


def attempt_counts(hist):
    """`respec.attempts` 를 칸으로 가른다. 🔴 LM 호출 수가 아니다 — "LM 호출" 로 부를 수 있는
    것은 roundtrip=="ok" 뿐이고 그것도 provider 재시도는 모른다."""
    c = dict.fromkeys(("attempts_total", "rewrite_roundtrip_ok", "rewrite_roundtrip_failed",
                       "rewrite_not_requested", "rewrite_skipped_not_rewritable",
                       "rewrite_roundtrip_null",
                       "rewrite_wrote", "rewrite_wrote_false", "rewrite_wrote_null",
                       "rewrite_installed", "rewrite_install_rejected",
                       "rewrite_wrote_not_installed", "rewrite_enacted"), 0)
    for h in hist or []:
        for a in (h.get("attempts") or []) if isinstance(h, dict) else []:
            if not isinstance(a, dict):
                continue
            c["attempts_total"] += 1
            rt = a.get("roundtrip")
            reenacted = isinstance(a.get("steps"), list) or a.get("steps_ref") is not None
            if rt == "ok":
                c["rewrite_roundtrip_ok"] += 1
                w = a.get("wrote")
                if w is True:
                    c["rewrite_wrote"] += 1
                    # `install_why` 는 처음부터 nothing 이다(enact.jl `_open_attempt!`) — 설치 없이
                    # 돌아온 칸(impl 이 문자열이 아닌 판)과 가르려면 재집행 흔적이 있어야 한다.
                    if a.get("install_why") is not None:
                        c["rewrite_install_rejected"] += 1
                    elif reenacted:
                        c["rewrite_installed"] += 1
                    else:
                        c["rewrite_wrote_not_installed"] += 1
                elif w is False:
                    c["rewrite_wrote_false"] += 1
                else:
                    c["rewrite_wrote_null"] += 1
            elif isinstance(rt, str) and rt.startswith("failed:"):
                c["rewrite_roundtrip_failed"] += 1
            elif rt == "not_requested":
                c["rewrite_not_requested"] += 1
            elif rt == "skipped_not_rewritable":
                c["rewrite_skipped_not_rewritable"] += 1
            elif rt is None:
                c["rewrite_roundtrip_null"] += 1      # 열렸는데 안 채워졌다(검증기 attempt_open)
            if reenacted:
                c["rewrite_enacted"] += 1
    return c


_ABLATION_RE = re.compile(
    r"^\[ablation\] level=(\w+) armed=(true|false) denied=(\d+) exempt=(\d+) "
    r"ladder_zone_skipped=(\d+) ladder_zone_fired=(\d+) detail=(\S*)", re.M)


def ablation_of(txt):
    """`[ablation]` 줄 → dict. 줄이 없으면 None(0 으로 접지 않는다 — 옛 판은 이 줄을 안 찍었다)."""
    m = _ABLATION_RE.search(txt)
    if not m:
        return None
    return {"level": m[1], "armed": m[2] == "true", "denied": int(m[3]), "exempt": int(m[4]),
            "ladder_zone_skipped": int(m[5]), "ladder_zone_fired": int(m[6]), "detail": m[7]}


def parse_log(txt, lane, case, seed):
    """로그 한 판 → 판 레코드(채점 줄이 없으면 None). 스트림 칸은 호출자가 붙인다."""
    closed = grab(txt, r"\[score\] complete=\w+ closed=(\d+)", int)
    if closed is None:                  # [score] 가 없으면 채점 전에 죽은 판이다
        return None
    minted_line = grab(txt, r"(\[minted\] lane=[^\r\n]*)") or ""
    pb = grab(txt, r"\[score\].* project_blocked=(true|false)")
    ctx = run_ctx_of(txt)
    exp = ood_intended(txt)
    return dict(
        lane=lane, case=case, seed=seed, closed=closed,
        complete=grab(txt, r"\[score\] complete=(true|false)") == "true",
        # 🔴 null 을 false 로 접지 않는다: `zone_blockage=unavailable` 이면 둘 다 None.
        n_blocked=grab(txt, r"\[score\].* n_blocked=(\d+)", int),
        project_blocked=None if pb is None else pb == "true",
        n_zones=grab(txt, r"\[score\].* n_zones=(\d+)", int, 0),
        minted="lane=present" in minted_line,                      # 주의 1
        tool=grab(txt, r"\[minted\] lane=\w+ tool=(\S+)"),
        tool_verdict=grab(txt, r"\[minted\] lane=\w+ tool=\S+ verdict=(\S+)"),
        threw=":threw(" in minted_line,
        retry=grab(txt, r"\[minted\][^\r\n]* enact_retry=(\S+)"),
        router_line=grab(txt, r"\[router\] ([^\r\n]*)"),
        zone_place=grab(txt, r"\[zone\] (blocking zone on [^\r\n]*)"),
        stop_sig=stop_signature(txt),
        restage_statuses=restage_statuses(txt),
        restage_observed=restage_observed(txt),
        reform_exhausted=reform_exhausted(txt, ctx),
        ood_intended=exp,
        # repair_ablation: 팔 신원(최종 리뷰 I2) — 옛 판은 키가 없어 None 이다(`none` 으로 접지 않는다)
        run_ctx={k: ctx.get(k) for k in ("campaign_id", "model", "seed", "zone_seed", "event",
                                         "code_rev", "code_dirty_digest", "config_digest",
                                         "repair_ablation")}
        if isinstance(ctx, dict) else None,
        ablation=ablation_of(txt),
    )


def attach_stream(r, path, rel, closed):
    """스트림 사실을 판 레코드에 붙인다(없으면 칸을 비운다)."""
    r["stream"] = rel
    fx = stream_facts(path) if path else None
    if fx:
        d = fx["last"]
        b = d.get("battery") or {}
        tot = b.get("total_energy_J")
        r["sim_seconds"] = d.get("sim_t")
        r["total_energy_J"] = tot
        r["energy_per_closed"] = (tot / closed) if (tot and closed) else None
        r["min_soc"] = b.get("min_soc")
        ood = d.get("ood") or []
        r["n_ood"] = len(ood)
        r["ood_kinds"] = dict(Counter(e.get("kind") for e in ood))
        r["ood_events"] = fx["ood_events"]
        r["ood_fp"] = fx["ood_fp"]
        r["init_fp"] = fx["init_fp"]
        r["ood_reached"] = ood_reached(r.get("ood_intended"), r["ood_kinds"])
        hist = d.get("respec_history") or ([d["respec"]] if d.get("respec") else [])
        r["decisions"] = [decision(h) for h in hist]
        r.update(attempt_counts(hist))
    r.setdefault("decisions", [])
    r["fail_mode"] = fail_mode(r)
    return r


def collect(dirs, base, root=MONITOR):
    runs, seen, totals = [], set(), Counter()
    for out in dirs:
        for log in sorted(glob.glob(os.path.join(out, "log", "*.log"))):
            stem = os.path.basename(log)[:-4]
            try:
                lane, case, s = stem.split("__")
                seed = int(s[1:])
            except ValueError:
                continue
            if (lane, case, seed) in seen:      # 같은 판이 여러 디렉터리에 있으면 처음 것만
                continue
            txt = open(log, errors="replace").read()
            r = parse_log(txt, lane, case, seed)
            if r is None:                       # legacy: 채점 전 죽은 판은 main 이 missing 으로 센다
                continue
            seen.add((lane, case, seed))
            # 진척도의 분모. 진행 표시줄이 매 틱 찍으므로 마지막 값을 쓴다(전 구간 동일하다).
            nt = re.findall(r"n_total:\s*(\d+)", txt)
            if nt:
                totals[int(nt[-1])] += 1
            rel = find_stream(base, lane, case, seed, root)
            attach_stream(r, os.path.join(root, rel) if rel else None, rel, r["closed"])
            runs.append(r)
    return runs, totals


def planned_keys(lanes, cases, seeds):
    return {(l, c, int(s)) for l in lanes for c in cases for s in seeds}


def _read_jsonl(path):
    out = []
    if os.path.isfile(path):
        with open(path, errors="replace") as f:
            for line in f:
                if line.strip():
                    out.append(json.loads(line))
    return out


def _ctx_mismatch(ctx, want):
    if not isinstance(ctx, dict):
        return ["run_ctx absent"]
    bad = []
    for k, v in (want or {}).items():
        if k not in ctx:
            bad.append("%s absent" % k)
        elif ctx[k] != v:
            bad.append("%s=%r!=%r" % (k, ctx[k], v))
    return bad


def collect_jobs(grid, jobs_path=None, totals=None):
    """manifest(jobs.jsonl) 가 분모다. (runs, unscored, denominators[(lane,case)]).

    판마다: 드라이버 판정(runs.jsonl 의 `status`, 예: error:fingerprint_drift) → 로그 유무 →
    `[run-ctx]` 대조(error:ctx_mismatch) → `[score]` 유무(timeout·error) → manifest 의 **정확한**
    스트림(error:stream_missing). 옛 이름 fallback 은 쓰지 않는다.
    """
    jobs = _read_jsonl(jobs_path or os.path.join(grid, "jobs.jsonl"))
    drv = {}
    for rec in _read_jsonl(os.path.join(grid, "runs.jsonl")):
        drv[rec.get("run_key")] = rec            # 같은 판을 다시 돌렸으면 마지막 기록
    totals = Counter() if totals is None else totals
    runs, unscored, den = [], [], {}
    for j in jobs:
        lane, case, seed = j["lane"], j["case"], int(j["seed"])
        d = den.setdefault((lane, case), dict.fromkeys(
            ("planned", "executed", "scored", "complete", "timeout", "error", "missing"), 0))
        d["planned"] += 1
        key, log = j["run_key"], j.get("log") or os.path.join(grid, "log", j["run_key"] + ".log")
        dr = drv.get(key) or {}

        def miss(status, detail=""):
            unscored.append({"run_key": key, "lane": lane, "case": case, "seed": seed,
                             "status": status, "detail": detail, "rc": dr.get("rc"),
                             "timeout": dr.get("timeout"), "elapsed": dr.get("elapsed"),
                             "log": log if os.path.isfile(log) else None})
            d["missing" if status == "missing" else
              "timeout" if status == "timeout" else "error"] += 1

        st0 = dr.get("status") or ""
        if st0.startswith("error:") and st0 != "error:ctx_mismatch":
            miss(st0, dr.get("detail", ""))       # 드라이버가 판을 안 돌렸다(예: 지문 표류)
            continue
        if not os.path.isfile(log):
            miss("missing")
            continue
        d["executed"] += 1
        txt = open(log, errors="replace").read()
        bad = _ctx_mismatch(run_ctx_of(txt), j.get("expect_ctx"))
        if bad:
            miss("error:ctx_mismatch", "; ".join(bad))
            continue
        r = parse_log(txt, lane, case, seed)
        if r is None:
            miss("timeout" if dr.get("timeout") else "error",
                 "rc=%s, no [score] line" % dr.get("rc"))
            continue
        path = j.get("stream")
        if not path or not os.path.isfile(path) or last_json_line(path) is None:
            miss("error:stream_missing", "manifest stream %s" % path)
            continue
        nt = re.findall(r"n_total:\s*(\d+)", txt)
        if nt:
            totals[int(nt[-1])] += 1
        attach_stream(r, path, os.path.relpath(path, grid), r["closed"])
        r["run_key"], r["rc"], r["elapsed"] = key, dr.get("rc"), dr.get("elapsed")
        d["scored"] += 1
        d["complete"] += bool(r["complete"])
        runs.append(r)
    return runs, unscored, den


def decision(h):
    din = h.get("input") or {}
    rt  = din.get("router") or {}
    pol = (din.get("policies") or {}).get("dspy") or {}
    return dict(
        at=h.get("at"), event=din.get("event"), chosen=h.get("chosen"),
        verdict=h.get("verdict"), enacted=din.get("enacted"),
        axis=rt.get("router_axis"), lane_target=rt.get("target"),
        routing_kind=rt.get("routing_kind"),
        expressible=pol.get("expressible"),            # 발화 조건: False 하나뿐이다
        synthesis_ran=pol.get("synthesis_ran"),
        tool_name=pol.get("tool_name"),
        steps=[(s.get("name"), s.get("status")) for s in (h.get("steps") or [])],
    )


_STOP_MARKERS = (
    ("line_stop", re.compile(r"FALLBACK engaged")),                 # replan.jl engage_fallback! (@warn)
    ("stall", re.compile(r"No progress for \d+ iterations")),       # demo_utils.jl simulate! (@warn)
)
_REFORM_RE = re.compile(r"\[reform\] attempt (\d+)/(\d+)")


def stop_signature(txt):
    """로그가 **어떻게** 멈췄나. `fail_mode` 와 달리 잔여 범주가 아니라 관측된 표지다.

    ⚠️ 표지가 없다고 그 일이 없었다는 뜻은 아니다 — 셋 다 `@warn`/`println` 이라 로그
    수준에 달렸다(`render_demo.jl` 기본 Warn 에서 셋 다 찍힌다).
    ⚠️ `reform_limit_reached` 는 마지막 허용 시도에 **도달**했다는 뜻이다 — 그 시도가 성공해
    완주할 수 있다. 실제 예산 소진은 `reform_exhausted` 가 따로 잰다. 인과 판정이 아니다.
    """
    sig = [name for name, rx in _STOP_MARKERS if rx.search(txt)]
    if any(a == b for a, b in _REFORM_RE.findall(txt)):
        sig.append("reform_limit_reached")
    return sig


def fail_mode(r):
    """⚠️ `world_deadlock` 은 **교착 후보**다(`n_blocked=0` 휴리스틱) — 물리적 교착이나 모델
    무책임을 확정하지 않는다. null(계측 불가)은 false 로 접지 않고 `unresolved` 에 남긴다."""
    if r["complete"]:
        return None
    # 주의 2 — 존이 치워졌는데 안 끝난 판은 세계 교착이지 결정 레인의 패배가 아니다.
    if (r["case"] in ("zone", "all3") and r["n_blocked"] == 0
            and r["project_blocked"] is False):
        return "world_deadlock"
    return "unresolved"


def summarise(runs, TOTAL, lanes=LANES, cases=CASES, den=None):
    out = {}
    for lane in lanes:
        for case in cases:
            rs = [r for r in runs if r["lane"] == lane and r["case"] == case]
            dn = (den or {}).get((lane, case))
            if not rs and not dn:
                continue
            prog = [r["closed"] / TOTAL for r in rs]
            mk = [r["sim_seconds"] for r in rs if r.get("sim_seconds") is not None]
            en = [r["energy_per_closed"] for r in rs if r.get("energy_per_closed")]
            cleared = [r for r in rs if r["n_blocked"] == 0 and r["project_blocked"] is False]
            out["%s|%s" % (lane, case)] = dict(
                n=len(rs),
                complete=sum(1 for r in rs if r["complete"]),
                progress_mean=(st.mean(prog) if prog else None),
                progress_sd=(st.pstdev(prog) if prog else None),
                closed_mean=(st.mean([r["closed"] for r in rs]) if rs else None),
                makespan_mean=(st.mean(mk) if mk else None),
                makespan_sd=(st.pstdev(mk) if mk else None),
                energy_mean=(st.mean(en) if en else None),
                energy_sd=(st.pstdev(en) if en else None),
                zone_cleared=(len(cleared) if case in ("zone", "all3") else None),
                minted=sum(1 for r in rs if r["minted"]),
                minted_clean=sum(1 for r in rs if r["minted"] and not r["threw"]),
                world_deadlock=sum(1 for r in rs if r["fail_mode"] == "world_deadlock"),
                unresolved=sum(1 for r in rs if r["fail_mode"] == "unresolved"),
                stop_sig=dict(Counter(x for r in rs for x in r.get("stop_sig", []))),
                denominators=dn,
                # 🔴 완주율의 분모는 **계획된 판 전부**다(채점 전 죽은 판 포함).
                complete_rate_planned=(sum(1 for r in rs if r["complete"]) / dn["planned"]
                                       if dn and dn["planned"] else None),
            )
    return out


def _words(v):
    return v.replace(",", " ").split()


def main(argv):
    model, base, out = "tractor.mpd", None, None
    root, jobs = MONITOR, None
    lanes, cases, seeds = list(LANES), list(CASES), list(range(1, 31))
    dirs = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--model":   model = argv[i + 1]; i += 2
        elif a == "--base":  base = argv[i + 1];  i += 2
        elif a == "--out":   out = argv[i + 1];   i += 2
        elif a == "--streams-root": root = argv[i + 1]; i += 2
        elif a == "--jobs":  jobs = argv[i + 1];  i += 2
        elif a == "--lanes": lanes = _words(argv[i + 1]); i += 2
        elif a == "--cases": cases = _words(argv[i + 1]); i += 2
        elif a == "--seeds": seeds = [int(x) for x in _words(argv[i + 1])]; i += 2
        else:                dirs.append(a);      i += 1
    if not dirs and not jobs:
        print(__doc__.strip())
        return 2
    base = base or model_base(model)
    out = out or os.path.join(MONITOR,
        "sweep360.json" if base == "tractor" else "sweep_%s.json" % base)

    if jobs:
        grid = os.path.dirname(os.path.abspath(jobs))
        totals = Counter()
        runs, unscored, den = collect_jobs(grid, jobs, totals)
        lanes = sorted({k[0] for k in den}, key=lambda x: (LANES + [x]).index(x))
        cases = sorted({k[1] for k in den}, key=lambda x: (CASES + [x]).index(x))
        missing = sorted([u["lane"], u["case"], u["seed"]] for u in unscored
                         if u["status"] == "missing")
    else:
        runs, totals = collect(dirs, base, root)
        have = {(r["lane"], r["case"], r["seed"]) for r in runs}
        want = planned_keys(lanes, cases, seeds)
        runs = [r for r in runs if (r["lane"], r["case"], r["seed"]) in want]
        missing = sorted(want - have)
        unscored = [{"lane": l, "case": c, "seed": s, "status": "missing"} for l, c, s in missing]
        den = {}
        for l, c, s in want:
            d = den.setdefault((l, c), dict.fromkeys(("planned", "executed", "scored",
                                                      "complete", "timeout", "error",
                                                      "missing"), 0))
            d["planned"] += 1
        for r in runs:
            d = den[(r["lane"], r["case"])]
            d["executed"] += 1; d["scored"] += 1; d["complete"] += bool(r["complete"])
        for l, c, s in missing:
            den[(l, c)]["missing"] += 1      # legacy: 로그 없음·채점 전 죽음을 가르지 못한다
    if not totals:
        print("n_total 을 어느 로그에서도 못 읽었다 -- 진척도의 분모가 없다.", file=sys.stderr)
        return 3
    TOTAL, ntot = totals.most_common(1)[0]
    if len(totals) > 1:                       # 판마다 다르면 그 사실을 감추지 않는다
        print("⚠ n_total 이 판마다 다르다: %s -- 최빈값 %d 를 쓴다" % (dict(totals), TOTAL), file=sys.stderr)
    doc = dict(
        generated=__import__("datetime").date.today().isoformat(),
        engine=ENGINE, model=model, model_base=base, total_nodes=TOTAL,
        lanes=lanes, cases=cases,
        n_runs=len(runs), n_missing=len(missing), missing=missing,
        n_planned=sum(d["planned"] for d in den.values()),
        n_unscored=len(unscored), unscored=unscored,
        denominators={"%s|%s" % k: v for k, v in sorted(den.items())},
        summary=summarise(runs, TOTAL, lanes, cases, den), runs=runs,
        tools=Counter(r["tool"] for r in runs if r["minted"] and r["tool"]).most_common(),
    )
    with open(out, "w") as f:
        json.dump(doc, f, separators=(",", ":"))
    print("model=%s base=%s n_total=%d (로그 %d판 일치)" % (model, base, TOTAL, ntot))
    print("planned=%d scored=%d unscored=%d (missing=%d) -> %s (%.0f KB)"
          % (doc["n_planned"], len(runs), len(unscored), len(missing), out,
             os.path.getsize(out) / 1024))
    for lane in lanes:
        print("  %-10s %s" % (lane, "  ".join(
            "%s %d/%d(plan %d)" % (c, doc["summary"]["%s|%s" % (lane, c)]["complete"],
                                   doc["summary"]["%s|%s" % (lane, c)]["n"],
                                   (den.get((lane, c)) or {}).get("planned", 0))
            for c in cases if "%s|%s" % (lane, c) in doc["summary"])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
