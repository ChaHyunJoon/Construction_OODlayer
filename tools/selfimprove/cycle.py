"""회전 상태 기계 (spec §4.2, §0.0 R2·R9).

  TRIGGERED → S0_PASS → S1_PASS → S3_T_PASS → S3_CTRL_PASS → AWAITING_REVIEW   (멈춤: 사람 검토)
  --from APPROVED: APPROVED → ARTIFACT_RECORDED → VERSION_BUILT → D_PASS → DEPLOYED
  어디서든 → REJECTED(stage, reason). 버전이 빌드된 뒤 D 에서 떨어지면 버전은 built 로 남고 포인터는 불변.

각 단계는 산출물 sha 를 기록하고, `--from X` 는 X 앞 단계 산출물이 그대로일 때만 허용한다.
외부 작업(판·빌드·게이트·배포)은 `Ops` 가 한다 — 시험은 가짜를 주입한다."""
import contextlib, datetime, json, os
from . import harvest, panel, paths, review, static_check, versions

A_STAGES = ("S0", "S1", "S3_T", "S3_CTRL", "REVIEW")
OUTPUTS = {"S0": ["candidate.json", "s0.json"], "S1": ["s1/report.json", "arms/candidate.json"],
           "S3_T": ["s3_t.json"], "S3_CTRL": ["s3_summary.json"], "REVIEW": []}
S3_T_NEED = ("C1_honest", "C2_sound", "C3_rescue", "C4_harm", "C6_strata")


def _d(exp, c, *p):
    return os.path.join(paths.state_dir(exp), "cycles", c, *p)


def _now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def _load(p):
    return json.load(open(p, encoding="utf-8"))


def _save(p, obj):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=1, ensure_ascii=False)


@contextlib.contextmanager
def lock(exp):
    p = os.path.join(paths.state_dir(exp), "cycles", ".lock")
    os.makedirs(os.path.dirname(p), exist_ok=True)
    try:
        fd = os.open(p, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        raise RuntimeError("another cycle is running (%s)" % p)
    try:
        os.write(fd, str(os.getpid()).encode())
        yield
    finally:
        os.close(fd)
        os.remove(p)


def open_cycle(exp, c, body, representative, members, behavior_key, track, incumbent, queue_pos, parent_version):
    _save(_d(exp, c, "candidate.json"), {"body": body, "representative": representative, "members": members})
    _save(_d(exp, c, "cycle.json"), {
        "cycle": c, "state": "TRIGGERED", "behavior_key": behavior_key, "track": track,
        "incumbent_arm_id": incumbent, "candidate_artifact": representative["artifact_sha256"],
        "queue_pos": queue_pos, "parent_version": parent_version, "triggered_at": _now(),
        "history": [{"state": "TRIGGERED", "at": _now()}], "outputs": {}})


def _sha_outputs(exp, c, stage):
    return {f: versions.sha256_file(_d(exp, c, f)) for f in OUTPUTS[stage] if os.path.exists(_d(exp, c, f))}


def _set(exp, c, st, state, **kw):
    st["state"] = state
    st.update(kw)
    st["history"].append({"state": state, "at": _now()})
    _save(_d(exp, c, "cycle.json"), st)


def _reject(exp, c, st, stage, reason):
    _set(exp, c, st, "REJECTED", reject={"stage": stage, "reason": reason})


def _src(rep):
    base2name = {harvest.bsd.model_base(f): k for k, f in paths.MODEL_FILES.items()}
    return {"model": base2name.get(rep["model"], rep["model"]), "case": rep["case"], "seed": int(rep["seed"])}


def _summ(runs):
    return {i: {"complete": r["complete"], "fail_mode": r.get("fail_mode")} for i, r in runs.items()}


def _write_arm(exp, c, name, arm):
    p = _d(exp, c, "arms", name + ".json")
    os.makedirs(os.path.dirname(p), exist_ok=True)
    raw = versions.canonical(arm).encode()
    open(p, "wb").write(raw)
    return p, versions.sha256_bytes(raw)


def _check_from(exp, c, st, upto):
    for stage in upto:
        for f, sha in (st["outputs"].get(stage) or {}).items():
            if not os.path.exists(_d(exp, c, f)) or versions.sha256_file(_d(exp, c, f)) != sha:
                raise RuntimeError("--from refused: %s output %s changed since it was produced" % (stage, f))


def _part_a(exp, c, st, ops, start):
    cand = _load(_d(exp, c, "candidate.json"))
    body = cand["body"]
    tau = _load(os.path.join(paths.state_dir(exp), "config.json"))["tau"]
    memo = {}

    def pan(role, p=None, sha=None):                     # 같은 실행 안에서 같은 패널을 두 번 안 돈다
        if role not in memo:
            memo[role] = ops.panel(role, p, sha)
        return memo[role]

    for stage in A_STAGES[A_STAGES.index(start):]:
        if stage == "S0":
            s0 = static_check.s0(body, harvest.world_interface_names())
            _save(_d(exp, c, "s0.json"), s0)
            if not s0["ok"]:
                return _reject(exp, c, st, "S0", s0["hard"])
            nxt = "S0_PASS"
        elif stage == "S1":
            arm = static_check.arm_json(body, 900, "candidate", "cand_%s_%s" % (c, body["impl_name"]))
            p, sha = _write_arm(exp, c, "candidate", arm)
            rep = ops.s1(c, p, sha, _src(cand["representative"]))
            _save(_d(exp, c, "s1", "report.json"), rep)
            if not rep["pass"]:
                return _reject(exp, c, st, "S1", rep["why"])
            nxt = "S1_PASS"
        elif stage == "S3_T":
            p, sha = _d(exp, c, "arms", "candidate.json"), versions.sha256_file(_d(exp, c, "arms", "candidate.json"))
            noop, t = pan("noop"), pan("candidate", p, sha)
            miss = panel.unmeasured(noop, t)
            if miss:
                return _reject(exp, c, st, "S3_T", "unmeasured:%s" % miss[:5])
            crit = panel.criteria(noop, t, None, None, tau)
            _save(_d(exp, c, "s3_t.json"), {"criteria": crit, "instances": _summ(t)})
            bad = [k for k in S3_T_NEED if not crit[k]["pass"]]
            if bad:
                return _reject(exp, c, st, "S3_T", bad)
            nxt = "S3_T_PASS"
        elif stage == "S3_CTRL":
            arm = _load(_d(exp, c, "arms", "candidate.json"))
            p, sha = _write_arm(exp, c, "null", static_check.null_arm(arm))
            noop = pan("noop")
            t = pan("candidate", _d(exp, c, "arms", "candidate.json"),
                    versions.sha256_file(_d(exp, c, "arms", "candidate.json")))
            tnull = pan("null", p, sha)
            inc = ops.incumbent(st["incumbent_arm_id"]) if st.get("track") == "replace" else None
            miss = panel.unmeasured(noop, tnull) + (panel.unmeasured(noop, inc) if inc is not None else [])
            if miss:
                return _reject(exp, c, st, "S3_CTRL", "unmeasured:%s" % miss[:5])
            crit = panel.criteria(noop, t, tnull, inc, tau)
            _save(_d(exp, c, "s3_summary.json"), {"criteria": crit, "instances": _summ(t)})
            if not crit["all_pass"]:
                return _reject(exp, c, st, "S3_CTRL", [k for k, v in crit.items() if isinstance(v, dict) and not v.get("pass", True)])
            nxt = "S3_CTRL_PASS"
        else:
            review.write_packet(exp, c)
            nxt = "AWAITING_REVIEW"
        st["outputs"][stage] = _sha_outputs(exp, c, stage)
        _set(exp, c, st, nxt)


B_STATES = ("AWAITING_REVIEW", "APPROVED", "ARTIFACT_RECORDED", "VERSION_BUILT", "D_PASS")


def _check_decision_evidence(exp, c, dec):
    """승인은 그것이 본 증거(S3 요약·검토 묶음)에 묶인다. 결정 뒤 증거가 바뀌었으면 승인을 쓰지 않는다."""
    for k, f in (("s3_summary_sha256", "s3_summary.json"), ("packet_sha256", os.path.join("review", "packet.md"))):
        now = versions.sha256_file(_d(exp, c, f)) if os.path.exists(_d(exp, c, f)) else None
        if dec.get(k) != now:
            raise RuntimeError("--from APPROVED refused: %s changed after the decision" % f)


def _part_b(exp, c, st, ops):
    """중단된 곳에서 이어 간다: 빌드된 버전은 다시 빌드하지 않고, D_PASS 면 배포만 한다."""
    i = B_STATES.index(st["state"])
    if i <= 0:
        dec = _load(_d(exp, c, "review", "decision.json"))
        if dec["decision"] != "approve":
            return _reject(exp, c, st, "S4", dec["reason"])
        _set(exp, c, st, "APPROVED")
    if i <= 1:
        row = ops.record(c)
        _set(exp, c, st, "ARTIFACT_RECORDED", arm_id=row["arm_id"])
    if i <= 2:
        v = ops.build_version(c, None)
        _set(exp, c, st, "VERSION_BUILT", version_built=v)
    v = st["version_built"]
    if not ops.version_ok(v):
        raise RuntimeError("built version %s fails verify — refusing to gate/deploy it" % v)
    if i <= 3:
        g = ops.gate(v)
        if not g.get("all_pass"):
            return _reject(exp, c, st, "D", {k: g.get(k) for k in ("D1", "D2", "D3", "missing")})
        _set(exp, c, st, "D_PASS")
    ops.deploy(v)
    _set(exp, c, st, "DEPLOYED")


A_PASS = {"S0": "TRIGGERED", "S1": "S0_PASS", "S3_T": "S1_PASS", "S3_CTRL": "S3_T_PASS", "REVIEW": "S3_CTRL_PASS"}


def run(exp, c, from_stage=None, ops=None, reopen=False):
    """`from_stage` 없이 부르면 현재 상태에서 이어 간다. 거부된 회전을 다시 돌리려면 `reopen=True` 를
    명시해야 하고, 그 사실(이전 거부)이 history 에 남는다. 결정이 기록된 뒤에는 part A 를 다시 못 돈다."""
    with lock(exp):
        st = _load(_d(exp, c, "cycle.json"))
        ops = ops or RealOps(exp, c)
        if from_stage == "APPROVED":
            if st["state"] not in B_STATES:
                raise RuntimeError("cycle %s is %s — not awaiting a decision" % (c, st["state"]))
            _check_from(exp, c, st, A_STAGES)
            _check_decision_evidence(exp, c, _load(_d(exp, c, "review", "decision.json")))
            return _part_b(exp, c, st, ops)
        if os.path.exists(_d(exp, c, "review", "decision.json")):
            raise RuntimeError("cycle %s already has a review decision — part A is closed" % c)
        start = from_stage or next((s for s, pre in A_PASS.items() if pre == st["state"]), None)
        if start not in A_STAGES:
            raise RuntimeError("cycle %s is %s — nothing to run in part A" % (c, st["state"]))
        if st["state"] == "REJECTED":
            if not reopen:
                raise RuntimeError("cycle %s was rejected at %s — pass reopen=True (--reopen) to re-run it"
                                   % (c, st["reject"]["stage"]))
            st["history"].append({"state": "REOPENED", "at": _now(), "reopened_from": st.pop("reject")})
        elif st["state"] != A_PASS[start]:
            raise RuntimeError("cycle %s is %s — cannot start part A at %s" % (c, st["state"], start))
        _check_from(exp, c, st, A_STAGES[:A_STAGES.index(start)])
        return _part_a(exp, c, st, ops, start)


class RealOps:
    """실제 판·빌드·게이트·배포. NOOP 패널은 실험 캐시(모든 회전 공유), 교체 트랙의 incumbent 는 그 팔이
    승격된 회전의 T 패널을 다시 모은다."""

    def __init__(self, exp, c, workers=None):
        from . import online
        self.exp, self.c = exp, c
        self.cfg = _load(os.path.join(paths.state_dir(exp), "config.json"))
        self.workers = workers or self.cfg["offline_workers"]
        self.rev, self.dirty = online.code_identity()

    def _grid_dir(self, role):
        if role == "noop":
            k = panel.cache_key(self.rev, self.dirty, self.cfg, self.cfg["gate_seeds"], self.cfg["models"],
                                self.cfg["zone_cases"])
            return panel.cache_dir(self.exp, "noop", k)
        return panel.arm_dir(self.exp, self.c, role)

    def _collect(self, d):
        return panel.collect([(m, os.path.join(d, m)) for m in self.cfg["models"]], self.cfg["zone_cases"],
                             self.cfg["gate_seeds"])

    def panel(self, role, arm_path, arm_sha):
        d = self._grid_dir(role)
        panel.run_arm(self.exp, d, arm_path, arm_sha, self.cfg["gate_seeds"], self.cfg["models"],
                      self.cfg["zone_cases"], self.workers)          # 채점된 판은 campaign 이 건너뛴다(캐시)
        return self._collect(d)

    def incumbent(self, arm_id):
        from . import library
        row = next(r for r in library.read(self.exp) if r["arm_id"] == arm_id)
        return self._collect(panel.arm_dir(self.exp, row["cycle"], "candidate"))

    def s1(self, c, path, sha, src):
        return panel.s1(self.exp, c, path, sha, src)

    def record(self, c):
        from . import promote
        return promote.record_artifact(self.exp, c)

    def build_version(self, c, _panels):
        from . import library, promote, refit
        st = _load(_d(self.exp, c, "cycle.json"))
        row = next(r for r in library.read(self.exp) if r["cycle"] == c)
        panels = {0: self._collect(self._grid_dir("noop")), row["arm_id"]: self._collect(self._grid_dir("candidate"))}
        for a in promote.next_active_set(self.exp, st["parent_version"], c):
            if a["arm_id"] not in panels:
                prior = next(r for r in library.read(self.exp) if r["arm_id"] == a["arm_id"])
                panels[a["arm_id"]] = self._collect(panel.arm_dir(self.exp, prior["cycle"], "candidate"))
        return refit.build_version(self.exp, c, panels, code_rev=self.rev, dirty=self.dirty)

    def version_ok(self, v):
        return versions.verify_version(self.exp, v) == []

    def gate(self, v):
        from . import policy_gate
        return policy_gate.run(self.exp, v, workers=self.cfg["online_workers"])

    def deploy(self, v):
        from . import service
        return service.deploy(self.exp, v)
