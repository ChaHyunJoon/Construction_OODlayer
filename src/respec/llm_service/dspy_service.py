"""
dspy_service.py -- the DSPy macro producer, exposed over HTTP so Julia can use it as a decision
policy instead of the hard-coded `canonical_respec` rule.

WHY A SEPARATE SERVICE (and not PyCall):
  · dspy lives in the `hjcrl` venv; the existing Claude service (server.py) targets `hjcnlp`.
    Two different Python environments cannot be loaded into one Julia process.
  · The Julia process already links PyCall against rvo2 for the motion stack. Importing dspy +
    litellm into that same interpreter risks breaking the simulator for a decision-layer feature.
  · Keeping the boundary at HTTP means the producer stays swappable, exactly like server.py.
(줄리아에 파이썬을 직접 심지 않고 HTTP로 분리하는 이유: venv가 다르고, 시뮬의 PyCall(rvo2)을 건드리면 안 되며,
 producer를 통째로 갈아끼울 수 있어야 하기 때문.)

WHAT IT SERVES
  POST /macro  {kind, soc, severity, spare_count, agent_pending, zone_overlap, progress, n_active}
    -> {policy, chosen, ranking[], margin, reasoning, valid, llm_calls}
  The `chosen` field is produced by exactly the arm we benchmarked (A4 MIPROv2, gpt-4o): the
  MIPROv2-optimized instruction + its bootstrapped demos, single `macro` output. `ranking`/`margin`
  are EXTRA introspection for the UI and for the "what if several actions are optimal?" question --
  they never override `chosen`, so the deployed decision equals the measured one.
(chosen = 벤치마크한 그 arm 그대로. ranking/margin은 UI·동점 분석용 부가 정보이며 결정을 바꾸지 않는다.)

Run (hjcrl venv, from this directory):
  OPENAI_API_KEY must be set in the environment.
  python -m uvicorn dspy_service:app --host 127.0.0.1 --port 8077
"""
import os, sys, json, glob, math, re
from typing import List, Optional

from fastapi import FastAPI
from pydantic import BaseModel

import dspy

HERE = os.path.dirname(os.path.abspath(__file__))
# HERE = <venv>/ConstructionBots.jl/src/respec/llm_service -> 네 단계 위가 venv 루트, 그 옆이 wm4...
WM = os.environ.get("WM_DIR") or os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE)))),
    "wm4spacecraft_manufacturing")
MODEL = os.environ.get("DSPY_MODEL", "gpt-4o")
# 어떤 컴파일 산출물을 쓸지. 기본 = sweep_lab 에 있는 그 모델의 프로그램 중 가장 최근 것
# (현재는 n=44 로 컴파일된 dspy_real_program_gpt4o.json). DSPY_PROGRAM 으로 고정 가능.
def _default_program():
    pats = os.path.join(WM, "sweep_lab", "dspy_real_program_%s*.json" % MODEL.replace(".", "").replace("-", ""))
    hits = sorted(glob.glob(pats), key=os.path.getmtime, reverse=True)
    return hits[0] if hits else ""


PROGRAM = os.environ.get("DSPY_PROGRAM") or _default_program()

MACROS = ["NOOP", "Replace", "Deprioritize", "ForbidZone", "ReformTeam"]
# 이벤트 종류별로 애초에 legal 한 매크로(gen_oracle_dataset 의 valid_actions 와 동일한 규칙).
VALID = {
    "fault":   ["NOOP", "Replace", "Deprioritize"],
    "battery": ["NOOP", "Replace", "Deprioritize"],
    "zone":    ["NOOP", "ForbidZone"],
    "reform":  ["NOOP", "ReformTeam"],
}

SEED_DOC = """You choose ONE recovery macro for an out-of-distribution event during a multi-robot
assembly build. The 5 candidates (a re-specification DSL action):
- NOOP: do nothing / restraint. Best when the disruption is absorbed by slack or spares and
  intervening would waste a scarce resource.
- Replace: swap the affected robot for a spare from the pool. Best on a real fault or a deeply
  depleted battery WHEN spares remain. Costs 1 schedule-unit.
- Deprioritize: lower the affected robot's task priority (mild, cheap=0.3). A middle option.
- ForbidZone: mark a no-go region and reroute the build around it. Best when a spatial zone is
  blocked. Costs 1.
- ReformTeam: re-form the multi-robot assembly team. Costs 1.
Adaptation cost matters: NOOP is free, Deprioritize=0.3, Replace/ForbidZone/ReformTeam=1.0. An
intervention must recover more than it costs, otherwise NOOP (restraint) is the right call."""


class PickMacro(dspy.Signature):
    __doc__ = SEED_DOC
    state: str = dspy.InputField(desc="decision-time state of the OOD event")
    valid_actions: str = dspy.InputField(desc="ONLY these macros are legal for this event")
    reasoning: str = dspy.OutputField(desc="one sentence")
    macro: str = dspy.OutputField(desc="the single best macro, from valid_actions")
    ranking: str = dspy.OutputField(
        desc="ALL legal macros ordered best-first, comma separated")
    margin: float = dspy.OutputField(
        desc="0..1 confidence gap between your 1st and 2nd choice; 0 means they are equally good")


_state = {"program": None, "instructions": None, "demos": 0, "calls": 0,
          "surrogate": None, "surro_feats": None, "surro_data": None, "surro_error": None}

# ---------------------------------------------------------------------------------------------
# surrogate 정책: **배포 모델(RandomForest)을 여기서 직접 적합**시켜 서비스한다.
# 왜 JSON export 를 읽지 않는가: export 포맷(선형/forest)이 평가에 쓴 모델과 어긋난 전력이 있어서
# (surrogate_model.py 의 기록 참조), 데모가 "벤치마크한 그 모델"과 다른 걸 보여줄 위험이 있다.
# n=44 · 220행이라 적합이 1초 미만이므로, 학습 코드를 그대로 재사용하는 편이 정직하고 단순하다.
# ---------------------------------------------------------------------------------------------
LAM = 3.0
SURRO_DATA = os.environ.get("EVAL_DATA", os.path.join(WM, "oracle", "out", "graded_hs_n44.jsonl"))


def _load_surrogate():
    try:
        sys.path.insert(0, WM)
        from e1_analyze import load, featurize, MACRO_COST      # noqa: E402
        from surrogate_model import build_model                 # noqa: E402
        import numpy as np                                      # noqa: E402

        df = load(SURRO_DATA)
        df = df[df.fired == True].copy()
        full = [i for i, g in df.groupby("instance") if len(g) == 5]
        df = df[df.instance.isin(full)].reset_index(drop=True)
        X = featurize(df)
        y = df.closed.astype(float).values - LAM * np.array([MACRO_COST[int(m)] for m in df.macro])
        model = build_model()
        model.fit(X.values, y)
        _state.update(surrogate=model, surro_feats=list(X.columns),
                      surro_data="%s (%d instances)" % (os.path.basename(SURRO_DATA), len(full)))
    except Exception as e:
        _state["surro_error"] = "%s: %s" % (type(e).__name__, e)


def _load_program():
    """컴파일 산출물(instructions + demos)을 얹은 dspy 프로그램을 만든다."""
    prog = dspy.Predict(PickMacro)
    instr, demos = None, []
    if os.path.exists(PROGRAM):
        blob = json.load(open(PROGRAM, encoding="utf-8"))
        instr = blob.get("instructions")
        # demo 의 출력 필드는 (reasoning, macro) 뿐 -> ranking/margin 은 비어 있는 부분 demo.
        # dspy 는 이를 허용한다. chosen 은 macro 필드에서 나오므로 벤치마크한 계약과 동일하다.
        demos = [dspy.Example(**{k: v for k, v in d.items() if k in
                                 ("state", "reasoning", "macro")}).with_inputs("state")
                 for d in blob.get("demos", []) if d.get("state")]
    if instr:
        prog.signature = prog.signature.with_instructions(instr)
    if demos:
        prog.demos = demos
    _state.update(program=prog, instructions=instr or SEED_DOC, demos=len(demos))
    return prog


app = FastAPI(title="ConstructionBots DSPy macro producer")


@app.on_event("startup")
def _startup():
    lm = dspy.LM("openai/%s" % MODEL, temperature=0.0, max_tokens=300, cache=True)
    dspy.configure(lm=lm)
    _load_program()
    _load_surrogate()      # 배포 RandomForest 적합(220행이라 1초 미만)


class MacroRequest(BaseModel):
    kind: str                                  # fault | battery | zone | reform
    severity: float = 0.0
    soc: Optional[float] = None                # battery only
    zone_overlap: Optional[float] = None       # zone only
    spare_count: int = 0
    agent_pending: int = -1
    progress: float = 0.0
    n_active: int = 0
    n_spare_cfg: int = 3                       # surrogate 피처(설정된 spare 수준)
    closed_at_fire: int = 0                    # surrogate 피처(발화 시점 닫힌 노드 수)
    zone_radius: Optional[float] = None        # surrogate 피처(zone 반경)
    # ---- 아래 둘은 2026-07-28 추가: LLM 에게 **문장**을 주기 위한 채널 --------------------
    # nl : 주입 시점에 만들어진 자연어 관찰(OOD_TRUTH_LOG 의 nl 쪽). 없으면 예전처럼 파싱된
    #      필드로 렌더링한다(하위호환). 있으면 LLM 은 이 문장을 읽는다.
    # descriptors : kind-agnostic 물리 서술자 6개
    #      [harm, work_at_risk, resource_loss, recovery_capacity, progress, slack].
    #      종류 이름 없이 계산되므로 **처음 보는 종류에도 존재한다** -- 이게 nl+state arm 의 핵심.
    nl: Optional[str] = None
    descriptors: Optional[List[float]] = None


def surrogate_rank(req: "MacroRequest", valid: List[str]):
    """배포 RF 로 5개 매크로를 점수화해 순위를 낸다. 학습 때와 같은 featurize 를 쓴다."""
    model = _state["surrogate"]
    if model is None:
        return None, _state["surro_error"] or "surrogate not loaded"
    try:
        import pandas as pd
        from e1_analyze import featurize, MACRO_NAME as MN
        name2id = {v: k for k, v in MN.items()}
        valid_ids = [name2id[m] for m in valid if m in name2id]
        # 학습 데이터의 kind 어휘는 fault/battery/zoneblk 이다. 데모의 zone 은 staging 을 막는
        # 사건이므로 zoneblk 로 매핑한다(어휘가 어긋나면 one-hot 이 전부 0이 되어 예측이 무의미해짐).
        kind = "zoneblk" if req.kind == "zone" else req.kind
        rows = []
        for m in range(5):
            rows.append(dict(
                kind=kind, macro=m, severity=float(req.severity),
                n_spare_cfg=float(req.n_spare_cfg), spare_count=float(req.spare_count),
                progress=float(req.progress), agent_pending=float(req.agent_pending),
                closed_at_fire=float(req.closed_at_fire), n_active=float(req.n_active),
                soc=(math.nan if req.soc is None else float(req.soc)),
                zone_radius=(math.nan if req.zone_radius is None else float(req.zone_radius)),
                zone_overlap=(-1.0 if req.zone_overlap is None else float(req.zone_overlap)),
                valid_mask=valid_ids,
            ))
        X = featurize(pd.DataFrame(rows))
        X = X.reindex(columns=_state["surro_feats"], fill_value=0.0)   # 학습 때의 열 순서로 정렬
        pred = model.predict(X.values)
        scored = [(MN[m], float(pred[m])) for m in range(5) if MN[m] in valid]
        scored.sort(key=lambda t: -t[1])
        return scored, None
    except Exception as e:
        return None, "%s: %s" % (type(e).__name__, e)


def _state_line(r: MacroRequest) -> str:
    """gen_oracle_dataset 의 capture_features 와 같은 정보만 문자열로 렌더링(정답 누수 없음)."""
    parts = ["OOD kind=%s" % r.kind]
    if r.kind == "battery" and r.soc is not None:
        parts.append("SoC=%.2f" % r.soc)
    if r.kind == "zone" and r.zone_overlap is not None and r.zone_overlap >= 0:
        parts.append("zone_overlap=%.2f" % r.zone_overlap)
    parts += ["severity=%s" % r.severity, "spares_left=%d" % r.spare_count,
              "agents_pending=%d" % r.agent_pending, "progress=%.2f" % r.progress,
              "n_active=%d" % r.n_active]
    return ", ".join(parts)


# 서술자 5개. 순서는 features_agnostic.STATE_DESCRIPTORS / novelty.jl event_descriptors 와 동일.
DESCRIPTOR_NAMES = ["harm", "work_at_risk", "resource_loss",
                    "recovery_capacity", "progress", "slack"]
DESCRIPTOR_DOC = {
    "harm": "how damaging the event is (1 = maximally damaging)",
    # 설명 문구도 정의를 따라 바꾼다. 예전 문구("남은 일 전체 중 비율")를 그대로 두면 LLM 이 0.35 를
    # "전체의 35%"로 읽어 과대평가한다 -- 숫자만 고치고 설명을 안 고치면 새로운 오해를 만든다.
    "work_at_risk": ("how much work this event threatens, measured in units of ONE ROBOT'S "
                     "AVERAGE SHARE of the remaining work (1.0 = this agent alone was holding "
                     "a full average robot's worth of work; 0 = it was holding none)"),
    "resource_loss": ("how much of the AFFECTED ROBOT'S own capability was lost "
                      "(1.0 = the robot is gone; 0 = this event does not involve a robot at all)"),
    "recovery_capacity": "spare provisioning relative to the active fleet",
    "progress": "build progress when the event fired",
    "slack": "remaining parallelism (active fleet vs reference fleet)",
}


# 주입기 문장은 "무슨 일이 있었는가" 뒤에 **"무엇을 하라"**를 붙인다:
#   "... and cannot move; dispatch the nearest backup robot to take over its remaining work."
#   "... blocking a staging area; restage the affected assembly out of the restricted region."
# 그 뒷절이 곧 canonical 정답이므로, 그대로 주면 LLM 은 해석하지 않고 지시를 따르기만 해도 맞힌다
# (라이브 데모에서 실제로 관측: 서술자가 harm=0.02 인데도 "restage 하라"는 문장을 따라 ForbidZone).
# LLM_NL_MODE=observation 이면 그 절을 떼고 관찰만 남긴다. 기본은 raw(기존 동작 유지).
_IMPERATIVE = re.compile(
    r"(?:;|—|--|,)?\s*(?:dispatch\b|restage\b|treat it as\b|hand its work\b|hand it\b|"
    r"replace\b|reroute\b|re-?stage\b|it should avoid\b|avoid\b|lower its\b|"
    r"deprioriti[sz]e\b)", re.I)


def _observation_only(text: str) -> str:
    t = " ".join(str(text or "").split())
    if not t:
        return t
    m = _IMPERATIVE.search(t)
    if not m or m.start() == 0:
        return t
    head = t[:m.start()].rstrip(" ;,—-")
    return t if len(head) < 20 else head + "."


def _nl_for_producer(text: str) -> str:
    mode = os.environ.get("LLM_NL_MODE", "raw").lower()
    return _observation_only(text) if mode.startswith("obs") else text


def _llm_input(r: MacroRequest) -> str:
    """**LLM 이 실제로 읽는 것.** surrogate 가 읽는 것과 의도적으로 다르다.

    왜 문장인가: `kind=battery, soc=0.55` 같은 파싱된 필드를 주면 순환 논리다 -- 그 필드가
    존재한다는 것 자체가 "이 사건은 이미 아는 3종류 중 하나로 분류됐다"는 뜻이고, 그게 바로
    검증하려는 능력이다. 진짜 새로운 사건에는 soc 열도 zone_overlap 열도 없다.
    (오프라인 실험의 llm_producer.py `nl+state` arm 과 같은 렌더링을 쓴다.)

    nl 이 없으면 예전 동작(_state_line)으로 폴백한다 -- 이 파일을 갱신하는 것만으로
    기존 호출자가 깨지지 않게.
    """
    if not (r.nl and r.nl.strip()):
        return _state_line(r)
    lines = ["OBSERVATION: " + _nl_for_producer(r.nl.strip())]
    if r.descriptors and len(r.descriptors) == len(DESCRIPTOR_NAMES):
        lines += ["",
                  "MEASURED STATE (computed by the monitor without classifying the event;",
                  "each is in [0,1] and means the same thing for any kind of disruption):"]
        for name, v in zip(DESCRIPTOR_NAMES, r.descriptors):
            lines.append("  %-18s = %.2f   (%s)" % (name, float(v), DESCRIPTOR_DOC[name]))
    return "\n".join(lines)


@app.get("/health")
def health():
    return {"status": "ok", "policy": "dspy:%s" % MODEL,
            "program": os.path.basename(PROGRAM) if os.path.exists(PROGRAM) else "(seed only)",
            "demos": _state["demos"], "calls": _state["calls"],
            "surrogate": _state["surro_data"] or ("ERROR: " + str(_state["surro_error"])),
            "policies": ["dspy", "surrogate"]}


@app.post("/macro")
def macro(req: MacroRequest):
    valid = VALID.get(req.kind, MACROS)
    prog = _state["program"] or _load_program()
    line = _llm_input(req)          # 문장(있으면) / 없으면 예전처럼 파싱된 필드
    try:
        pred = prog(state=line, valid_actions=", ".join(valid))
        _state["calls"] += 1
        chosen = (getattr(pred, "macro", "") or "").strip()
        raw_rank = (getattr(pred, "ranking", "") or "").strip()
        reasoning = (getattr(pred, "reasoning", "") or "").strip()
        try:
            margin = float(getattr(pred, "margin", 0.0) or 0.0)
        except Exception:
            margin = 0.0
        err = None
    except Exception as e:                      # 서비스가 죽지 않게: 줄리아가 canonical 로 폴백할 수 있도록 표시
        chosen, raw_rank, reasoning, margin, err = "", "", "", 0.0, "%s: %s" % (type(e).__name__, e)

    # 어휘 밖 / 이 이벤트에 불법인 응답은 NOOP 으로 강제(오프라인 평가와 동일 규칙).
    coerced = chosen not in valid
    if coerced:
        chosen = "NOOP" if "NOOP" in valid else valid[0]
    ranking = [m.strip() for m in raw_rank.replace("[", "").replace("]", "").split(",") if m.strip()]
    ranking = [m for m in ranking if m in valid]
    for m in valid:                              # 빠진 legal 매크로는 뒤에 채워 넣어 항상 완전한 순위표가 되게
        if m not in ranking:
            ranking.append(m)
    return {"policy": "dspy:%s" % MODEL, "chosen": chosen, "ranking": ranking,
            "margin": margin, "reasoning": reasoning, "valid": valid,
            "coerced": coerced, "state": line, "llm_calls": _state["calls"], "error": err}


@app.post("/decide")
def decide(req: MacroRequest):
    """한 번의 호출로 **모든 비-규칙 정책**의 결정을 돌려준다.
    줄리아는 canonical(규칙)을 자기가 계산해 합치므로, 이 응답 + canonical = 세 정책 전부.
    UI 는 이 셋 중 무엇을 볼지 고르고, 실제로 실행된 것은 enacted 로 따로 표시한다."""
    valid = VALID.get(req.kind, MACROS)
    # 두 producer 가 **서로 다른 것을 본다**. UI 가 그 차이를 나란히 보여줄 수 있도록 둘 다 돌려준다.
    #   llm_input       : 자연어 관찰 (+ 종류-무관 서술자 6개)
    #   surrogate_input : 학습 때와 같은 스키마 피처
    out = {"valid": valid, "state": _state_line(req),
           "llm_input": _llm_input(req), "surrogate_input": _state_line(req),
           "llm_input_mode": "nl" if (req.nl and req.nl.strip()) else "parsed-fields"}

    d = macro(req)                                   # dspy 정책(위 엔드포인트 재사용)
    out["dspy"] = {"chosen": d["chosen"], "ranking": d["ranking"], "margin": d["margin"],
                   "rationale": d["reasoning"], "policy": d["policy"],
                   "coerced": d["coerced"], "error": d["error"]}

    scored, err = surrogate_rank(req, valid)         # surrogate 정책(배포 RandomForest)
    if scored:
        top = scored[0][1]
        runner = scored[1][1] if len(scored) > 1 else top
        spread = max(abs(top - scored[-1][1]), 1e-9)
        out["surrogate"] = {
            "chosen": scored[0][0],
            "ranking": [m for m, _ in scored],
            "scores": {m: round(s, 2) for m, s in scored},
            # margin = 1·2위 점수차를 전체 폭으로 정규화(0에 가까우면 사실상 동점)
            "margin": round(abs(top - runner) / spread, 3),
            "policy": "surrogate:RandomForest", "error": None}
    else:
        out["surrogate"] = {"chosen": "", "ranking": [], "scores": {}, "margin": 0.0,
                            "policy": "surrogate:RandomForest", "error": err}
    return out
