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
# HERE = <repo>/src/respec/llm_service -> 세 단계 위가 repo 루트, 그 안에 wm4...
# (2026-07-31: wm4 가 repo 옆의 형제 폴더에서 repo 내부로 이동해 단계가 넷 -> 셋으로 줄었다.)
WM = os.environ.get("WM_DIR") or os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(HERE))),
    "wm4spacecraft_manufacturing")
MODEL = os.environ.get("DSPY_MODEL", "gpt-4o")

# 데이터셋 경로는 wm4 쪽 wm_datasets.py 한 곳에서만 정의된다. 그걸 쓰려면 WM 을 import 경로에
# 넣어야 한다. insert(0,...) 이 아니라 append 인 이유: 이 프로세스에는 dspy/litellm 이 올라오므로
# WM 을 최우선 경로로 두면 동명 모듈을 가릴 위험이 있다(맨 뒤면 표준 패키지가 항상 먼저 이긴다).
if WM not in sys.path:
    sys.path.append(WM)
import wm_datasets                                            # noqa: E402


def _model_tag(model=None):
    """'gpt-4o' -> 'gpt4o'. 컴파일 산출물 파일명에 쓰는 태그(dspy_real_experiment.py 와 동일 규칙)."""
    return (model or MODEL).replace(".", "").replace("-", "")


def _default_program():
    """이 모델로 컴파일된 프로그램 파일을 **정확한 이름으로** 찾는다.

    FIXED 2026-07-30 -- 예전에는 glob 이었다:

        "dspy_real_program_%s*.json" % _model_tag()      # gpt-4o -> "dspy_real_program_gpt4o*.json"

    끝의 `*` 때문에 그 패턴이 `dspy_real_program_gpt4omini.json` 까지 매칭했고, 그중 **mtime 이
    최신인 것**을 골랐다. 즉 gpt-4o-mini 프로그램을 새로 컴파일하는 순간, gpt-4o 로 뜬 서비스가
    조용히 mini 의 지시문·demo 를 쓰기 시작한다 -- 에러도 로그도 없이 벤치마크한 것과 다른 arm 이
    배포된다. 이제 와일드카드 없이 정확히 일치하는 파일만 쓴다.
    (와일드카드가 gpt4o 와 gpt4omini 를 함께 잡아 최신 것을 고르던 버그를 제거했다.)
    """
    exact = os.path.join(WM, "sweep_lab", "dspy_real_program_%s.json" % _model_tag())
    return exact if os.path.exists(exact) else ""


PROGRAM = os.environ.get("DSPY_PROGRAM") or _default_program()

# ---- 행동 어휘: 레지스트리에서 읽는다 (2026-08-06, Ch-A) ---------------------------------
# 여기 있던 리터럴에는 SwapBattery 가 없었다. 그래서 이 서비스로 결정하는 **라이브 데모에서는**
# battery 사건의 싼 정답(현장 배터리 교체, cost 0.2)을 LLM 이 고를 수조차 없었고, 늘 Replace(1.0)
# 아니면 Deprioritize(0.3) 중에서만 답했다. 어휘가 정답을 담지 못하면 그 사건의 초과비용은
# 원리적으로 0 이 될 수 없다(PLAN_LLM_INFERENCE_7H Ch-A).
from action_registry import (MACRO_NAME as _REG_NAME, MACRO_COST as _REG_COST,   # noqa: E402
                             KIND_VALID as _REG_KIND_VALID, doc_lines as _reg_doc_lines)

MACROS = [_REG_NAME[i] for i in sorted(_REG_NAME)]
# 이벤트 종류별로 애초에 legal 한 매크로(gen_oracle_dataset 의 valid_actions / ood_mdp_shim 의
# _zone_arms 와 **같은 규칙이어야 한다**).
#
# zone 이 2026-08-03 에 ForbidZone -> RelocateBuild 로 바뀌었다. ForbidZone 의 실행부
# (restage_all_blocked!)는 "아직 시작 안 한 조립체"만 옮길 수 있는데 그 집합이 빌드 중반에
# 영구히 비어서, 그 팔은 NOOP 과 바이트 단위로 같은 결과를 냈다(측정: zoneblk 36/36 동점).
# 여기 목록을 안 고치면 **LLM 에게 조용한 no-op 을 고르라고 시키는 것**이 된다.
#
# ---- 2026-08-05: 이 표는 이제 **상태를 모르는 호출자를 위한 폴백**이다 -----------------
# 위 교체는 오라클 라벨링(=빌드 중반 발화)에서는 옳지만, 그것을 kind 하나로 못박아 두자
# 라이브 데모까지 같이 바뀌었다: 데모의 zone 은 **아직 시작 안 한 조립체**를 겨냥해 심어지므로
# ForbidZone 이 실제로 실행 가능한데도 어휘에서 빠져 있어, 모든 zone 사건이 빌드 전체를 통째로
# 옮기는 RelocateBuild 로 답해졌다(실측: 조립 개시 후 Δ=3.19m 전역 이동 -> 운반체 교착,
# streams/tractor__zone.jsonl 264/287 미완주. ForbidZone 으로 답하던 옛 녹화는 전부 287 완주).
# "legal" 은 kind 가 아니라 **그 순간 그 팔이 실제로 무언가를 할 수 있는가**로 정해져야 한다.
# 그래서 호출자(policy.jl)가 세계를 보고 계산한 목록을 `valid` 로 실어 보내면 그것을 쓴다.
# 상태를 모르는 호출자에게는 전제조건 없는 팔만 남긴 이 보수적 표를 그대로 준다.
# 2026-08-06: 이 폴백표도 레지스트리의 kinds 에서 유도한다. 손으로 적으면 레지스트리에 팔을
# 늘려도 이 표는 옛 목록 그대로라, 상태를 모르는 호출자에게는 새 팔이 영영 안 보인다.
# zone 만 예외로 ForbidZone 을 뺀다: 그 팔은 "아직 시작 안 한 조립체"라는 전제조건이 있어
# 상태를 모르면 legal 인지 알 수 없고, 중반에는 조용한 no-op 이 된다(2026-08-03 실측 36/36 동점).
# 상태를 아는 호출자(policy.jl valid_macros)가 실어 보내면 그쪽이 언제나 이긴다.
VALID = {k: [_REG_NAME[i] for i in ids] for k, ids in _REG_KIND_VALID.items()}
VALID["zone"] = [m for m in VALID.get("zone", []) if m != "ForbidZone"]
VALID["reform"] = ["NOOP", "ReformTeam"]


def _valid_for(req) -> List[str]:
    """이 사건에서 legal 한 매크로. 호출자가 준 목록이 있으면 그것이 우선(어휘 밖은 버림)."""
    caller = [m for m in (getattr(req, "valid", None) or []) if m in MACROS]
    return caller if caller else VALID.get(req.kind, MACROS)

# ---- 2026-08-05 (STEP 4): 결정표를 산문으로 주지 않는다 ---------------------------------
# 이 프롬프트의 마지막 두 문장은 원래 결정 규칙 그 자체였다("빌드 전체를 옮기는 게 그 교란보다
# 이득인가 -- 적치영역 가장자리만 스치는 구역은 보통 아니다"). 규칙을 문장으로 주면 측정되는 것은
# **추론이 아니라 프롬프트 준수**다. 같은 파일 아래(_IMPERATIVE 주석)에 그 증거가 이미 있다:
# 서술자가 harm=0.02 인데도 "restage 하라"는 지시문을 따라 ForbidZone 을 고른 실측.
# 그래서 남기는 것은 **원리 하나**(위반된 것을 전부 해소하는 가장 싼 개입, 위반이 없으면 NOOP)와
# 각 액션이 무엇을 해소하는가뿐이다. 어떤 것이 위반됐는지는 모델이 상태(원시값)에서 판단한다.
# 최소수복 판정 자체(zone_diagnosis 의 verdict)는 오라클/게이트의 것이며 여기 오면 안 된다.
SEED_DOC = """You choose ONE recovery macro for an out-of-distribution event during a multi-robot
assembly build. The candidates (a re-specification DSL action):
%s
Adaptation cost matters: %s.

THE PRINCIPLE:""" % (
    # 어휘 설명을 레지스트리에서 렌더링한다. 손으로 적힌 목록이었을 때 SwapBattery 가 빠졌고,
    # 그 누락은 "LLM 이 못 고른다"가 아니라 "LLM 이 그 팔의 존재를 모른다"였다.
    "\n".join(_reg_doc_lines()),
    ", ".join("%s=%.1f" % (_REG_NAME[i], _REG_COST[i]) for i in sorted(_REG_NAME))) + """ choose the CHEAPEST action that resolves every constraint the event actually
violates. If the event violates nothing the schedule still needs, NOOP is not a cop-out -- it is
the correct answer, and intervening spends a resource for nothing. Decide which constraints are
violated from the state you are given; do not assume an event of a given type always violates
something."""


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
# HS_N44 고정: 배포 surrogate 는 n=44 셋으로 적합한 그 모델이어야 벤치마크와 일치한다.
# EVAL_DATA / WM_DATASET 로 덮어쓸 수 있다(wm_datasets.py 가 우선순위를 정의).
SURRO_DATA = wm_datasets.resolve(os.environ.get("EVAL_DATA"), default=wm_datasets.HS_N44)


def _load_surrogate():
    try:
        sys.path.insert(0, WM)
        from e1_analyze import (load, featurize, MACRO_COST,     # noqa: E402
                                instance_arms_complete)
        from surrogate_model import build_model                 # noqa: E402
        import numpy as np                                      # noqa: E402

        df = load(SURRO_DATA)
        df = df[df.fired == True].copy()
        # "랭킹이 정의되는 instance만" 학습에 쓴다. 예전에는 `len(g) == 5` 였는데, DS_VALID_ONLY 로 만든
        # 라벨은 그 사건의 **유효한 팔만** 돌아 5를 영영 못 채운다 -> EVAL_DATA 를 새 덤프로 바꿔도
        # 새 instance 가 전부 조용히 버려진다(2026-08-05: firegrid_merged 126개 중 60개만 통과, 그
        # 60개는 전부 옛 5-arm 덤프였다). 판정은 e1_analyze 의 것을 그대로 쓴다 -- 평가와 배포가
        # 다른 필터를 쓰면 "벤치마크한 그 모델"이라는 이 파일의 전제가 깨진다.
        full = [i for i, g in df.groupby("instance") if instance_arms_complete(g)]
        df = df[df.instance.isin(full)].reset_index(drop=True)
        X = featurize(df)
        y = df.closed.astype(float).values - LAM * np.array([MACRO_COST[int(m)] for m in df.macro])
        model = build_model()
        model.fit(X.values, y)
        # **학습 근거가 있는 매크로 집합**을 같이 기록한다. 배포 모델은 0~4 만 본 적이 있고
        # 7(RelocateBuild)은 행이 한 줄도 없다 -> 그 값을 예측하는 것은 근거 없는 외삽이다.
        # 조용히 점수를 내면 UI 가 "surrogate 가 NOOP 을 골랐다"로 보이지만 사실은
        # "고를 수조차 없었다"이다. 이 구분이 곧 라우터(낯선 것은 LLM)의 존재 이유다.
        support = sorted({int(m) for m in df.macro.unique()})
        _state.update(surrogate=model, surro_feats=list(X.columns), surro_support=set(support),
                      surro_data="%s (%d instances, macro support %s)"
                                 % (os.path.basename(SURRO_DATA), len(full), support))
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
    # nl_mode : "observation" 이면 관찰문 뒤의 **지시절**을 떼고 준다(raw = 옛 동작).
    #   서비스는 별도 프로세스라 호출자의 LLM_NL_MODE 가 여기 닿지 않는다 -> 요청에 실어 보낸다.
    nl_mode: Optional[str] = None
    # ---- 2026-08-05 (STEP 3): 공간 사건의 기하 **원시값** ---------------------------------
    # zone_overlap 스칼라 하나로는 "무엇이 왜 막혔는가"를 말할 수 없다. 호출자(policy.jl)가
    # zone_diagnosis 로 계산한 술어를 그대로 실어 보내면 아래 _llm_input 이 측정 블록으로 렌더링한다.
    # ★ 최소수복 판정(verdict)은 이 스키마에 **없다**. 그건 정답이라 오라클·게이트의 것이고,
    #   여기 실으면 모델이 추론이 아니라 답을 베낀다. 필드가 없으면 블록 자체가 생기지 않는다.
    zone_blocked: Optional[int] = None            # 구역이 덮은 미개시 조립체 수
    zone_restage_feasible: Optional[int] = None   # 그중 옮길 빈 자리가 있는 수
    zone_root_covered: Optional[int] = None       # 갇힌 root 하역목표 수(국소 재적치로 못 구함)
    zone_root_total: Optional[int] = None
    zone_work_overlap: Optional[int] = None       # 겹친 미완 작업 디스크 수
    zone_teams_forming: Optional[int] = None      # 지금 형성 중인 운반팀 수
    zone_teams_covered: Optional[int] = None      # 그중 집결지/슬롯이 구역에 갇힌 팀 수
    zone_relocatable: Optional[bool] = None       # 구역을 벗어나는 강체이동이 존재하는가
    zone_relocate_norm: Optional[float] = None    # 그 최소 이동거리(m)
    # ---- 2026-08-05: 덮임(coverage)이 아니라 **막힘**(blockage) 원시값 -----------------
    # 위의 값들은 전부 "구역이 무엇을 덮었나"이고, 실측상 덮임은 해로움이 아니다(root 목표를
    # 8/8 덮어도 완주). 구역 강제는 RVO 에이전트만 스냅하므로 화물을 직접 옮기는 목표는 못 막는다.
    # 아래 두 값이 "이 구역이 **실제로** 못 닫게 만드는 것"이고, 그게 개입의 유일한 근거다.
    # ★ Pydantic 은 선언 안 된 키를 조용히 버린다 — 이 선언이 없으면 호출자가 실어 보내도 무효.
    zone_nav_goals: Optional[int] = None           # 막힐 수 있는 목표(RVO 구동)의 모수
    zone_nav_blocked: Optional[int] = None         # 그중 지금 못 닫는 것
    zone_nav_engulfed: Optional[int] = None        #   (감사용 분해) 포획볼이 배제원 안
    zone_nav_disconnected: Optional[int] = None    #   (감사용 분해) 길이 끊김 — 통로검사 ON 일 때만 잼
    zone_agent_trapped: Optional[int] = None       # 구역 안에 주차된 이동체 수
    zone_nav_downstream: Optional[int] = None      # 막힌 노드 뒤에 걸려 함께 얼어붙는 미완 작업 수
    zone_unfinished_total: Optional[int] = None    # 그 비교 분모(전체 미완 노드 수)
    # valid : 호출자가 **세계를 보고** 계산한 legal 매크로 목록(2026-08-05 추가).
    #   kind 만으로 정하면 전제조건이 있는 팔(ForbidZone: 아직 시작 안 한 조립체만 옮길 수 있음)을
    #   "언제나 불법" 또는 "언제나 합법" 중 하나로만 둘 수 있다. 둘 다 틀린다 — 전자는 실행 가능한
    #   국소 복구를 어휘에서 지워 매번 전역 이동(RelocateBuild)을 시키고, 후자는 조용한 no-op 을
    #   고르게 한다. 상태를 아는 쪽(줄리아)이 계산해 실어 보내는 것이 유일하게 옳은 배치다.
    valid: Optional[List[str]] = None


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
        support = _state.get("surro_support") or set(range(5))
        unsupported = [m for m in valid if m in name2id and name2id[m] not in support]
        scorable = [name2id[m] for m in valid if m in name2id and name2id[m] in support]
        if not scorable:
            return None, ("no training support for any valid macro %s "
                          "(surrogate saw %s)" % (valid, sorted(support)))
        rows = []
        for m in scorable:
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
        scored = [(MN[m], float(p)) for m, p in zip(scorable, pred)]
        scored.sort(key=lambda t: -t[1])
        # 근거 없는 매크로는 점수 대신 **없다는 사실**을 돌려준다(호출부가 UI 에 그대로 표시).
        return scored, (None if not unsupported else
                        "UNSUPPORTED:" + ",".join(unsupported))
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


def _nl_for_producer(text: str, mode: Optional[str] = None) -> str:
    """지시절 제거 여부. 요청이 mode 를 실어 보내면 그것이 우선하고, 없으면 서비스 환경변수.

    왜 요청 필드가 필요한가(2026-08-05): 서비스는 별도 프로세스(uvicorn)라 데모 스크립트가
    LLM_NL_MODE 를 export 해도 서비스에는 닿지 않는다. "이 런은 관찰만 준다"가 실험 조건인 이상
    그 조건은 **호출자가** 정할 수 있어야 한다. 서비스 기본값(raw)은 그대로 두므로 옛 호출자
    (오프라인 llm_producer.py 등)의 렌더링은 한 글자도 안 바뀐다.
    """
    m = (mode or os.environ.get("LLM_NL_MODE", "raw")).lower()
    return _observation_only(text) if m.startswith("obs") else text


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
        return _state_line(r) + _geometry_block(r)
    lines = ["OBSERVATION: " + _nl_for_producer(r.nl.strip(), getattr(r, "nl_mode", None))]
    if r.descriptors and len(r.descriptors) == len(DESCRIPTOR_NAMES):
        lines += ["",
                  "MEASURED STATE (computed by the monitor without classifying the event;",
                  "each is in [0,1] and means the same thing for any kind of disruption):"]
        for name, v in zip(DESCRIPTOR_NAMES, r.descriptors):
            lines.append("  %-18s = %.2f   (%s)" % (name, float(v), DESCRIPTOR_DOC[name]))
    return "\n".join(lines) + _geometry_block(r)


# 각 원시값이 무엇인지 -- 값만 주면 모델이 뜻을 지어낸다. 설명은 **사실**만 적고
# "그러니 무엇을 하라"는 절대 적지 않는다(그게 STEP 4 가 지운 결정표다).
#
# 블록을 **둘로 가른다**(2026-08-05). 이유는 문체가 아니라 측정이다: 아래 첫 묶음은 전부
# "구역이 무엇을 **덮었나**"(coverage)인데, 덮임은 해로움이 아니다 — root 하역목표를 8/8 삼킨
# 판이 291 노드를 전부 닫고 완주했다(시간만 2.1배). 구역이 강제되는 곳은
# enforce_restriction_zone_clearance! 한 곳뿐이고 그 함수는 **RVO 에이전트만** 원 밖으로 밀어내는데,
# root 하역목표는 LiftIntoPlace 의 목표 = 화물 변환을 직접 적분해 옮기는 노드라 RVO 를 안 거친다.
# 그래서 한 덩어리로 주면 "8/8 갇힘"이라는 큰 숫자가 모델을 계속 개입 쪽으로 끈다. 두 번째 묶음이
# 실제로 못 닫게 만드는 것이고, 개입의 근거는 거기에만 있다.
_GEOM_COVERAGE = [
    ("zone_blocked", "zone_blocked",
     "sub-assemblies whose staging area the zone covers AND that have not started building"),
    ("zone_restage_feasible", "  of which movable",
     "of those, how many have a zone-clear spot to be restaged into"),
    ("zone_root_covered", "root_goals_trapped",
     "delivery goals of the ROOT assembly inside the zone; the root cannot be restaged. These "
     "are placed by a lift that moves the cargo directly, not by a navigating agent"),
    ("zone_work_overlap", "work_discs_overlapped",
     "unfinished work areas the zone intersects"),
    ("zone_teams_forming", "teams_forming",
     "transport teams currently gathering"),
    ("zone_teams_covered", "  of which trapped",
     "of those, how many must gather inside the zone (they cannot form where they stand)"),
    ("zone_relocate_norm", "min_shift_to_clear_m",
     "smallest rigid translation of the whole build that puts every unfinished goal outside "
     "the zone; -1 means no such shift exists"),
]

# 두 번째 묶음. `zone_nav_disconnected` 는 일부러 안 싣는다: 결정 경로에서는 통로 flood-fill 을
# 끄고 부르므로(목표 123개마다 격자를 도는 비용) 그 값이 늘 0 이고, 0 을 보여주면 "재 봤더니 0"
# 으로 읽힌다. 재지 않은 것을 0 으로 보고하지 않는다 — 대신 `of which blocked` 가 하한임을 명시한다.
_GEOM_BLOCKAGE = [
    ("zone_nav_goals", "nav_goals",
     "unfinished goals whose mover is a navigating agent; the zone is enforced only on "
     "navigating agents, so these are the only goals it can stop"),
    ("zone_nav_blocked", "  of which blocked",
     "their arrival tolerance lies entirely inside the enforced exclusion disc, so the node can "
     "never close while the zone lives. This is a lower bound: a goal that is still clear but "
     "has no surviving route to it is not counted here"),
    ("zone_nav_downstream", "  work frozen by those",
     "unfinished schedule nodes that are those blocked nodes or wait on them further down the "
     "precedence graph; none of them can close while the zone lives. Compare this with how much "
     "of the build is left -- a blocked count that looks small can still freeze most of it"),
    ("zone_agent_trapped", "agents_parked_inside",
     "movers standing inside the zone right now (they were parked when it appeared)"),
]


def _rows(r: MacroRequest, spec) -> list:
    return [(lbl, getattr(r, f), doc) for f, lbl, doc in spec if getattr(r, f, None) is not None]


def _geometry_block(r: MacroRequest) -> str:
    """공간 사건의 기하 원시값 블록. 필드가 하나도 없으면 빈 문자열(= 기존 입력과 동일)."""
    cov = _rows(r, _GEOM_COVERAGE)
    blk = _rows(r, _GEOM_BLOCKAGE)
    if not cov and not blk:
        return ""
    out = []
    if cov:
        out += ["", "WHAT THIS ZONE COVERS (geometry only):"]
        for lbl, v, doc in cov:
            out.append("  %-22s = %-6s (%s)" % (lbl, v, doc))
        if r.zone_root_total is not None:
            out.append("  (the root has %s delivery goals in total)" % r.zone_root_total)
    if blk:
        out += ["", "WHAT THIS ZONE CAN ACTUALLY BLOCK:"]
        for lbl, v, doc in blk:
            out.append("  %-22s = %-6s (%s)" % (lbl, v, doc))
        if r.zone_unfinished_total is not None:
            out.append("  (the build has %s unfinished nodes in total)" % r.zone_unfinished_total)
    return "\n".join(out)


@app.get("/health")
def health():
    return {"status": "ok", "policy": "dspy:%s" % MODEL,
            "program": os.path.basename(PROGRAM) if os.path.exists(PROGRAM) else "(seed only)",
            "demos": _state["demos"], "calls": _state["calls"],
            "surrogate": _state["surro_data"] or ("ERROR: " + str(_state["surro_error"])),
            "policies": ["dspy", "surrogate"]}


@app.post("/macro")
def macro(req: MacroRequest):
    valid = _valid_for(req)
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
    valid = _valid_for(req)
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
            # 점수는 냈지만 **일부 유효 매크로는 학습 근거가 없어 아예 못 본** 경우를 그대로 싣는다.
            # 이걸 None 으로 뭉개면 UI 가 "surrogate 가 NOOP 을 골랐다"로 보이는데, 실제로는
            # "새 행동을 고를 수조차 없었다"이다 — 라우터가 LLM 에게 넘겨야 하는 바로 그 상황.
            "unsupported": ([] if not err or not str(err).startswith("UNSUPPORTED:")
                            else str(err).split(":", 1)[1].split(",")),
            "policy": "surrogate:RandomForest",
            "error": (None if (not err or str(err).startswith("UNSUPPORTED:")) else err)}
    else:
        out["surrogate"] = {"chosen": "", "ranking": [], "scores": {}, "margin": 0.0,
                            "policy": "surrogate:RandomForest", "error": err}
    return out
