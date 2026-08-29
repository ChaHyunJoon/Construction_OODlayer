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
from typing import Dict, List, Optional

from fastapi import FastAPI
from pydantic import BaseModel

# 2026-08-12 FIX -- 이 두 줄은 지울 수 있는 "우연히 딸려온" import 가 아니다. 순서가 계약이다.
# dspy 3.3.0(3.2.1 에서 업그레이드)은 `import dspy` 시점에 sys.modules["numpy"] 를
# `dspy/utils/lazy_import.py` 의 lazy-import 프록시로 바꿔치기한다. 이후 `_load_surrogate()`
# 가 sklearn -> joblib -> numpy 로 그 프록시를 건드리면, numpy 가 절반만 초기화된 자기 자신
# (numpy._core)으로 재진입하며 `numpy/_core/_methods.py:17: TypeError: data type 'bool' not
# understood` 로 죽는다. `_load_surrogate()` 는 그 예외를 삼켜 `_state["surro_error"]` 에 담기
# 때문에 서비스 자체는 정상 기동하지만, /health 의 surrogate 필드가 "ERROR: ..." 가 되고
# tools/monitor/policy.jl 이 이를 보고 surrogate 정책을 조용히 canonical 로 폴백시킨다
# (summary 에는 policy="surrogate" 로 찍히지만 실제 enacted 는 전부 canonical). 진짜 numpy/
# sklearn 을 dspy 보다 먼저 정상적으로 import 해 두면 dspy 가 프록시를 심을 이유가 없어져서
# 이 재진입 자체가 발생하지 않는다. 절대 "정리"한다고 아래 줄을 지우거나 dspy 뒤로 옮기지 말 것.
import numpy, sklearn.ensemble  # noqa: F401  -- 순서 고정: dspy 보다 먼저 진짜 numpy/sklearn 을 초기화

import dspy

HERE = os.path.dirname(os.path.abspath(__file__))
# HERE = <repo>/src/respec/llm_service -> 세 단계 위가 repo 루트, 그 안에 wm4...
# (2026-07-31: wm4 가 repo 옆의 형제 폴더에서 repo 내부로 이동해 단계가 넷 -> 셋으로 줄었다.)
WM = os.environ.get("WM_DIR") or os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(HERE))),
    "wm4spacecraft_manufacturing")
MODEL = os.environ.get("DSPY_MODEL", "gpt-4o")

# 데이터셋 경로는 wm4 쪽 core/wm_datasets.py 한 곳에서만 정의된다. 그걸 쓰려면 그 폴더를 import
# 경로에 넣어야 한다. insert(0,...) 이 아니라 append 인 이유: 이 프로세스에는 dspy/litellm 이
# 올라오므로 wm4 경로를 최우선으로 두면 동명 모듈을 가릴 위험이 있다(맨 뒤면 표준 패키지가
# 항상 먼저 이긴다). 그래서 wm4 자신의 부트스트랩(core/wmpath.py, insert(0,...))은 여기서
# 쓰지 않고 필요한 폴더만 직접 append 한다.
# 2026-08-18 폴더 분류: wm4 의 py 가 역할별 폴더로 나뉘었다 — 이 프로세스가 쓰는 것은
# core/(wm_datasets) 과 surrogate/(eval_surrogate_v2 · surrogate_features · surrogate_v2) 둘이다.
WM_CODE_DIRS = [os.path.join(WM, "core"), os.path.join(WM, "surrogate")]
for _d in WM_CODE_DIRS:
    if _d not in sys.path:
        sys.path.append(_d)
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
# [역사] 이 절 아래의 실측 기록은 구세대 어휘(v3-4arms 이전)의 것이다 — Deprioritize·ForbidZone·
# RelocateBuild 는 이제 레지스트리에 없고 zone·reform 은 사건 종류가 아니다. 그 산출물은 이미
# 폐기돼 재측정이 불가능하므로 숫자와 서술은 지우지 않고 그대로 둔다.
# 여기 있던 리터럴에는 SwapBattery 가 없었다. 그래서 이 서비스로 결정하는 **라이브 데모에서는**
# battery 사건의 싼 정답(현장 배터리 교체, cost 0.2)을 LLM 이 고를 수조차 없었고, 늘 Replace(1.0)
# 아니면 Deprioritize(0.3) 중에서만 답했다. 어휘가 정답을 담지 못하면 그 사건의 초과비용은
# 원리적으로 0 이 될 수 없다(PLAN_LLM_INFERENCE_7H Ch-A).
from action_registry import (MACRO_NAME as _REG_NAME, MACRO_COST as _REG_COST,   # noqa: E402
                             KIND_VALID as _REG_KIND_VALID, doc_lines as _reg_doc_lines,
                             ACTIVE_MACROS as _REG_ACTIVE)

# 2026-08-19 (태스크 5, spec §2): `sorted(_REG_NAME)` 는 **전체** 레지스트리 항목(이름표는 은퇴
# 후에도 안 지운다)을 도니 3·5·6 이 그대로 섞여 나온다 — LLM 의 legal 어휘 목록·`_valid_for`의
# `caller` 필터(`m in MACROS`)가 이 리스트를 멤버십 검사에 쓰므로, 고치지 않으면 은퇴한 macro
# 이름이 이 서비스의 어휘로 조용히 되살아난다. `ACTIVE_MACROS` 는 은퇴(retired)와 실험 게이트
# (experimental) 를 **모두** 반영한 진짜 "지금 제안 가능한 팔" 목록이다.
MACROS = [_REG_NAME[i] for i in _REG_ACTIVE]
# 이벤트 종류별로 애초에 legal 한 매크로. 레지스트리의 `KIND_VALID` 파생이므로 gen_oracle_dataset
# 의 `valid_actions` 와 같은 출처를 읽는다. (여기 적혀 있던 "shim 의 `_zone_arms` 와 같은 규칙"
# 은 2026-08-24 3팔 축소 뒤 거짓이다: `_zone_arms()` 는 이제 `[0]` 이고 이 표에는 zone 키가 아예
# 없어 아래 `_valid_for` 가 MACROS 로 폴백한다.)
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
# [역사] "zone 만 예외로 ForbidZone 을 뺀다"는 규칙이 여기 있었다: 그 팔은 "아직 시작 안 한
# 조립체"라는 전제조건이 있어 상태를 모르면 legal 인지 알 수 없고, 중반에는 조용한 no-op 이
# 된다(2026-08-03 실측 36/36 동점). ForbidZone 도 zone kind 도 이제 레지스트리에 없다.
# 상태를 아는 호출자(policy.jl valid_macros)가 실어 보내면 그쪽이 언제나 이긴다 — 이건 그대로다.
VALID = {k: [_REG_NAME[i] for i in ids] for k, ids in _REG_KIND_VALID.items()}
# 🔴 2026-08-24 (spec §5.1, Task 4): 여기 있던 두 줄을 지웠다 —
#     VALID["zone"]   = [m for m in VALID.get("zone", []) if m != "ForbidZone"]
#     VALID["reform"] = ["NOOP", "ReformTeam"]
# 둘 다 레지스트리 밖에서 **키를 만들어 내는** 리터럴이었다. 3팔 축소로 `_REG_KIND_VALID` 에
# "zone" 키가 없어졌으므로 첫 줄은 `VALID.get("zone", [])` == [] 를 필터해 `VALID["zone"] = []`
# 를 **새로 만든다**. 그러면 아래 `_valid_for` 의 `VALID.get(req.kind, MACROS)` 가 MACROS 로
# 폴백하지 못하고 **빈 legal 메뉴**를 LLM 에 넘긴다 — 에러 없이. 둘째 줄은 레지스트리에 없는
# 이름(ReformTeam)을 kind 표에 못박고 있었다.
# 이제 VALID 는 순수 레지스트리 파생이고, 표에 없는 kind(zone/reform)는 MACROS 로 폴백한다.
# 폴백이지 raise 가 아닌 이유: 채점 대상이 아닌 사건 하나가 긴 측정 런을 죽이면 안 된다.


def _valid_for(req) -> List[str]:
    """이 사건에서 legal 한 매크로. 호출자가 준 목록이 있으면 그것이 우선(어휘 밖은 버림)."""
    caller = [m for m in (getattr(req, "valid", None) or []) if m in MACROS]
    return caller if caller else VALID.get(req.kind, MACROS)

# ---- 2026-08-05 (STEP 4): 결정표를 산문으로 주지 않는다 ---------------------------------
# [역사] 아래 실측(ForbidZone 선택)은 구세대 어휘(v3-4arms 이전)의 기록이다 — 그 팔은 이제 없다.
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


class SelectTool(dspy.Signature):
    __doc__ = SEED_DOC
    state: str = dspy.InputField(desc="decision-time observation of the OOD event")
    # 🔴 이 필드가 native FC 의 스위치다 (spec §2-4 조건 2). 없으면 dspy 가 ValueError.
    #    켜지면 이 필드와 `action` 은 시그니처에서 **삭제되어** 프롬프트 텍스트에 안 들어가고
    #    provider 의 tools 파라미터로만 간다 -- 모델이 읽는 tool 설명은 전부 Tool 객체 안에 있다.
    tools: List[dspy.Tool] = dspy.InputField(desc="the recovery tools available here")
    valid_actions: str = dspy.InputField(desc="ONLY these macros are legal for this event")

    reasoning: str = dspy.OutputField(desc="one sentence")
    expressible: bool = dspy.OutputField(
        desc="false if NO available tool can address what you observed")
    action: dspy.ToolCalls = dspy.OutputField()
    # 🔴 macro 를 tool 에 합치지 않는다: tool 호출이 실패해도 결정은 살아야 한다(spec §4-1).
    #    macro 는 **채점 어휘**(action_registry)의 것이고 tool 은 행동 어휘의 것이다.
    macro: str = dspy.OutputField(desc="the single best macro, from valid_actions")
    ranking: str = dspy.OutputField(
        desc="ALL legal macros ordered best-first, comma separated")
    margin: float = dspy.OutputField(
        desc="0..1 confidence gap between your 1st and 2nd choice; 0 means equally good")


def build_adapter():
    """native FC 를 켠 어댑터. **site-packages 의 기본값(False)을 고치지 않는다** — 그건
    재설치에 날아가고 이 레포 밖에서 돌리는 사람과 조용히 갈린다(spec §2-4)."""
    return dspy.ChatAdapter(use_native_function_calling=True)


def native_fc_active(signature=None):
    """native FC 가 **실제로** 켜졌는가 — 네 조건을 런타임에 전부 읽는다(spec §2-4).

    🔴 배선 여부가 아니라 발화 여부다. 조건 4(`lm.supports_function_calling`)는 LM 이 정하므로
    코드를 읽어서는 알 수 없다. 이 함수의 반환값을 응답에 실어야 라이브 런에서 "배선했다" 와
    "실제로 켜졌다" 가 구분된다.

    네 조건(어댑터 플래그 · `list[dspy.Tool]` 입력 · `dspy.ToolCalls` 출력 ·
    `lm.supports_function_calling`)이 전부 참일 때만 True.

    🔴 못 재면 `False` 가 아니라 `None` 을 낸다. "못 쟀다"(None)와 "재서 꺼져 있었다"(False)는
    다른 사건이다(spec §9-2). 아무도 `dspy.configure` 를 안 불렀으면 조건 1·4 를 **읽을 수
    없으므로** dspy 의 폴백 기본값을 추론해 False 를 내지 않는다 — 그건 측정이 아니다.
    """
    try:
        sig = signature if signature is not None else SelectTool
        adapter = dspy.settings.adapter
        lm = dspy.settings.lm
        return bool(
            adapter.use_native_function_calling                            # 조건 1
            and adapter._get_tool_call_input_field_name(sig) is not None   # 조건 2 (base.py:609)
            and adapter._get_tool_call_output_field_name(sig) is not None  # 조건 3 (base.py:619)
            and lm.supports_function_calling                               # 조건 4 (base.py:110)
        )
    except Exception:
        return None


_state = {"program": None, "instructions": None, "demos": 0, "calls": 0,
          "surrogate": None, "surro_feats": None, "surro_data": None, "surro_error": None}

# ---------------------------------------------------------------------------------------------
# surrogate 정책: **배포 모델(SurrogateV2, 2-헤드 ΔĴ)을 여기서 직접 적합**시켜 서비스한다.
# 왜 JSON export 를 읽지 않는가: export 포맷(선형/forest)이 평가에 쓴 모델과 어긋난 전력이 있어서
# (surrogate_model.py 의 기록 참조), 데모가 "벤치마크한 그 모델"과 다른 걸 보여줄 위험이 있다.
# 355행이라 적합이 1초 미만이므로, 학습 코드를 그대로 재사용하는 편이 정직하고 단순하다.
#
# 2026-08-14 (spec §6 단계 6) -- 무엇이 바뀌었나
# ----------------------------------------------
#  · 모델   : RandomForest(`closed − λ·MACRO_COST` 회귀) -> `SurrogateV2`(2-헤드 조립 Ĵ).
#             옛 모델은 861/861 결정을 "menu 안 최대 MACRO_COST 팔"로 냈다 = 상태를 한 비트도
#             안 봤다. λ 는 함께 사라진다(타깃이 J 자신이라 식별할 λ 가 없다).
#  · 학습셋 : n44_plus78 -> RELABEL_20260814. **`wm_datasets.resolve()` 를 쓰지 않는다** —
#             그 함수는 $WM_DATASET/EVAL_DATA 를 읽으므로 환경변수 하나로 조용히 옛 라벨
#             (= 이 계획이 제거하려는 결함을 가르치는 파일)이 다시 들어온다. Task 6 의
#             `eval_surrogate_v2.py` 와 같은 결정이고, 그래야 배포 모델과 평가 모델이 같다.
#  · 부호   : ΔĴ 는 **낮을수록 좋다**. 아래 `surrogate_rank` 의 오름차순 정렬이 그 계약이고,
#             `test_service_surrogate_rank.py` 가 그것을 검사로 못박는다.
#  · feature: `surrogate_features.build_features`(22차원)를 **import 해서** 쓴다. 여기서
#             재조립하면 학습/배포가 조용히 갈린다 — 이 저장소의 반복된 사고다.
#
# [역사] 아래 support 기록({0,1,2,7,8}·3·4·5·6·reform kind)은 구세대 어휘(v3-4arms 이전)의 것이다 —
# 그 팔들도 reform 사건 종류도 이제 레지스트리에 없다. 숫자는 재측정 불가라 그대로 보존한다.
# 알려진 능력 회귀 — **2026-08-16 에 해소했다. 이력으로 남긴다(왜 있었는지가 다음 사람에게
# 필요하다).** 2026-08-14 ~ 08-15 동안 배포 학습셋(RELABEL_20260814)의 macro support 는
# {0,1,2,7,8} 이었고 **ReformTeam(4)·ForbidZone(3) 행이 0줄**이었다. 아래 support 필터가 그
# 팔을 후보에서 떨어뜨리므로 reform 사건에서 surrogate 는 NOOP 밖에 못 냈다(`unsupported` 로
# 그 사실이 응답에 남았다). 원인은 "진 팔"이 아니라 **시험지에 나온 적이 없는 팔**이었다:
# support 는 학습 행의 `macro` 열에서 유도되는데(아래 `_load_surrogate`), 재라벨 격자에
# reform 인스턴스가 0건이었고 fault 의 팔 메뉴가 shim 리터럴 `[0,1]` 로 잘려 있었다.
# 그 대가는 DP 표집까지 번졌다 — 2026-08-15 판에서 Reform 축 §8.7 gap 이 13/13 = 100%.
#
# 2026-08-16: 라벨셋을 RELABEL_20260816 으로 바꾼다. shim 의 `valid_actions` 가 이제
# `core/action_registry.json` 파생이라 kind 마다 legal 한 팔을 전부 굴렸고, `reform` kind 가
# 격자에 들어왔다. 그래서 3·4 가 support 에 있다(조합 팔 5·6 도 — DS_COMBO_ARMS=1 로 생성).
#
# ⚠️ `wm_datasets.resolve()` 를 **쓰지 않는다** — 그 함수는 $WM_DATASET/$EVAL_DATA 를 읽으므로
# 환경변수 하나로 옛 라벨이 조용히 들어온다. 상수를 직접 가리킨다.
#
# 🔴 2026-08-25 (최종 브랜치 리뷰 C4): `RELABEL_20260816` 은 **구세대(v3-4arms 이전) 라벨**이고
# 축 C Task 1 이 작업 트리에서 지웠다. 그 상수를 가리키는 동안 `load_rows` 가
# `SystemExit("라벨 파일이 없다")` 를 던졌는데 SystemExit 은 BaseException 이라 아래
# `_load_surrogate` 의 `except Exception` 을 **빠져나가** FastAPI startup 을 통째로 죽였다
# (실측: `_load_surrogate() RAISED OUT: SystemExit`). 즉 서비스가 아예 뜨지 않아 `/health` 의
# 보고 경로에 도달조차 못 했다. 파일을 되살려도 결과는 같다 — 그 세대에는 `vocab` 열이 없어
# `require_vocab_stamps` 가 거부한다. v4-3arms 라벨셋을 가리킨다.
# ---------------------------------------------------------------------------------------------
SURRO_DATA = wm_datasets.abspath(wm_datasets.ORACLE_DATASET)
# 배포 결정 규칙. Task 6 의 4규칙 비교에서 모든 2차 지표의 최선(exact match 0.819 ·
# 베이스라인 대비 개선 50 / 악화 9 · battery regret 0.349). 규칙 자체는 `SurrogateV2.choose`
# 안에 한 번만 정의돼 있고 여기서는 이름으로만 고른다 — 재구현하면 배포와 평가가 갈린다.
#
# ⚠️ 이 선택의 대가를 여기 같이 적는다 (2026-08-14 최종 리뷰). 위 근거는 전부 **LOIO(G1)의
# 2차 지표**다. **일반화의 유일한 근거라고 하니스 자신이 부르는 지표는 LOKO(G2)** 이고,
# 거기서 이 규칙은 **자기가 대체한 전임(deadband_B)을 빼면 비교 대상 전부보다 나쁘다**:
#
#     G2 (LOKO, 평균 regret; 낮을수록 좋다)      G1 (LOIO, 평균 regret)
#       max-cost 바닥선     169.48 (학습 0)          169.48
#       argmin_jhat        169.48                  223.50
#       linear2h           169.31   <- 최선         686.29
#       deadband_Jbar    ** 924.96 **              223.33   <- 최선
#       deadband_B        1158.73                  600.07
#
# 즉 **처음 보는 kind 에서는 상태를 한 비트도 안 보는 max-cost 규칙(과 선형 바닥선)이 이
# 규칙을 5.5배 차이로 이긴다.** 그래도 이 규칙을 배포한 이유: 배포 레인이 실제로 마주치는 것은
# 학습된 세 kind 이고(새 kind 는 novelty 라우터가 LLM 으로 보낸다), G1 에서 이 규칙만이
# `{0,1,8}` 의 신호를 맞힌다(Replace 5 · Swap 10, 최빈답 오라클 일치). 그러나 이것은
# **트레이드오프이지 우세가 아니다** — kind 일반화를 근거로 이 규칙을 인용하지 말 것.
# 근거·전체 표: wm4spacecraft_manufacturing/md/RESULTS_SURROGATE_REBUILD_2026-08-14.md §3.
SURRO_RULE = "deadband_Jbar"


def _load_surrogate():
    try:
        # 2026-08-18 폴더 분류: 이 셋은 전부 wm4 의 surrogate/ 에 있다(위 WM_CODE_DIRS 참조).
        for _d in WM_CODE_DIRS:
            if _d not in sys.path:
                sys.path.append(_d)
        # 로딩·필터링 계약(`e1_analyze.load()` 로 읽기 · `fired==False` stub 10행 제거)은
        # Task 6 하니스에 **단일 정의**로 있다. 여기서 다시 쓰면 배포가 학습과 다른 행으로
        # 적합될 수 있으므로 그 함수를 그대로 부른다.
        from eval_surrogate_v2 import load_rows                 # noqa: E402
        from surrogate_features import FEATURE_NAMES            # noqa: E402
        from surrogate_v2 import SurrogateV2                    # noqa: E402
        from threadpoolctl import threadpool_limits             # noqa: E402

        rows, meta = load_rows(SURRO_DATA)
        support = sorted({int(r["macro"]) for r in rows})
        # 스레드를 1로 묶는다. 공유 서버(56코어)에서 OpenMP 가 코어 수만큼 스레드를 띄우면
        # 355행짜리 적합이 0.58s -> 132.6s 로 늘어난다(Task 6 실측 227배). 결과는 안 바뀐다.
        with threadpool_limits(limits=1):
            model = SurrogateV2().fit(rows)
        # **학습 근거가 있는 매크로 집합**을 같이 기록한다. 여기 없는 값을 예측하는 것은 근거 없는
        # 외삽이고, 조용히 점수를 내면 UI 가 "surrogate 가 NOOP 을 골랐다"로 보이지만 사실은
        # "고를 수조차 없었다"이다. 이 구분이 곧 라우터(낯선 것은 LLM)의 존재 이유다.
        _state.update(surrogate=model, surro_feats=list(FEATURE_NAMES),
                      surro_support=set(support),
                      surro_data="%s (%d rows / %d instances, macro support %s, rule %s, "
                                 "objective_hash %s, vocab %s)"
                                 % (os.path.basename(SURRO_DATA),
                                    meta["rows_after_fired_filter"], meta["instances"],
                                    support, SURRO_RULE, meta["objective_hash"],
                                    meta.get("vocab")))
    # 🔴 2026-08-25 (최종 브랜치 리뷰 C4): `SystemExit` 을 함께 잡는다. 이 함수가 부르는
    # `eval_surrogate_v2.load_rows` 는 로딩 계약 위반(파일 없음 · `fired` 열 없음)을
    # **`SystemExit`** 으로 알리는데 그것은 `Exception` 이 아니라 `BaseException` 의 자식이라
    # `except Exception` 을 그대로 통과했다. 이 함수는 `@app.on_event("startup")` 에서 돌므로
    # 그 예외 하나가 LLM 레인 서비스 전체를 못 뜨게 만든다 — R-25 가 의도한 모양은 "실패를
    # /health 에 실어 보고한다" 이고, 아래 한 줄이 그 의도를 실제로 집행한다.
    # `KeyboardInterrupt` 는 일부러 안 잡는다(Ctrl-C 로 서버를 못 죽이게 되면 안 된다).
    except (Exception, SystemExit) as e:
        _state["surro_error"] = "%s: %s" % (type(e).__name__, e)


def _load_program():
    """컴파일 산출물(instructions + demos)을 얹은 dspy 프로그램을 만든다."""
    prog = dspy.Predict(SelectTool)
    instr, demos = None, []
    if os.path.exists(PROGRAM):
        blob = json.load(open(PROGRAM, encoding="utf-8"))
        instr = blob.get("instructions")
        # demo 는 입력이 state 하나, 출력이 (reasoning, macro) 뿐이다 -> tools/valid_actions
        # 입력과 expressible/action/ranking/margin 출력이 비어 있는 **부분 demo**.
        # dspy 는 이를 허용한다 -- 실측: 이 모양의 demo 로
        # `build_adapter().format(SelectTool, demos, inputs)` 가 예외 없이 메시지 4개를 낸다
        # (system/user/assistant/user). 그래서 컴파일 산출물을 다시 만들 필요가 없다.
        # chosen 은 macro 필드에서 나오므로 벤치마크한 계약과 동일하다.
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
    lm = dspy.LM("openai/%s" % MODEL, temperature=0.2, max_tokens=500, cache=True)
    dspy.configure(lm=lm, adapter=build_adapter())
    _load_program()
    _load_surrogate()      # 배포 SurrogateV2 적합(355행이라 1초 미만)


class MacroRequest(BaseModel):
    kind: str                                  # fault | battery (레지스트리 KIND_VALID 의 사건 종류).
    #   "zone" 요청은 아직 도착할 수 있으나 어휘에 zone 팔이 없어 채점되지 않고(reference_policy),
    #   "reform" 은 2026-08-24 3팔 축소에서 사건 종류에서 빠졌다.
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
    # total_nodes : 빌드 전체 노드 수. **2026-08-14 추가** — 새 22차원 조립기의 work_at_risk
    #   분모(`pending_total = total_nodes − closed_at_fire`)가 이 값이다. 라벨 행에는 처음부터
    #   있었지만 이 스키마에 없어서, 선언하지 않으면 Pydantic 이 조용히 버리고 서비스는 0 으로
    #   본다 -> pending_total 이 1.0 으로 접혀 work_at_risk 가 포화 = 학습과 다른 feature.
    #   없으면 `_total_nodes()` 가 closed_at_fire/progress 로 복원한다.
    total_nodes: Optional[int] = None
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
    #   kind 만으로 정하면 전제조건이 있는 팔(구 어휘의 ForbidZone: 아직 시작 안 한 조립체만 옮길 수
    #   있음)을 "언제나 불법" 또는 "언제나 합법" 중 하나로만 둘 수 있다. 둘 다 틀린다 — 전자는 실행
    #   가능한 국소 복구를 어휘에서 지워 매번 전역 이동(구 RelocateBuild)을 시키고, 후자는 조용한 no-op 을
    #   고르게 한다. 상태를 아는 쪽(줄리아)이 계산해 실어 보내는 것이 유일하게 옳은 배치다.
    # agents : 이 요청 시점에 **실재하는** 로봇 목록 [{id, label}, ...].
    #   `llm_bridge.open_agent_descriptors` 가 만드는 형태를 그대로 받는다.
    #   ②접지의 재료다 — tool 파라미터의 enum 이 이 목록에서만 나오므로, 여기 없는 id 는
    #   모델이 **생성할 수 없다**(디코드 시점 차단).
    # ★ 선언하지 않으면 pydantic 이 조용히 버린다. 그러면 enum 이 빈 목록으로 굳어 tool
    #   호출이 전부 막히는데, 원인이 호출자에 있는 것처럼 보인다.
    agents: Optional[List[Dict[str, str]]] = None
    valid: Optional[List[str]] = None


_SURRO_INSTANCE = "live"        # 요청 하나 = instance 하나. `choose`/`predict_delta_J` 의 그룹 키.


def _total_nodes(req: "MacroRequest") -> float:
    """이 빌드의 전체 노드 수. `descriptors_from_row` 의 work_at_risk 분모다.

    호출자(policy.jl `ood_features`)가 실어 보내는 것이 정답이다. 안 보내는 옛 호출자를 위해
    `closed_at_fire / progress` 로 복원한다 — `ood_features` 가 `progress = closed/total` 로
    정의하므로 이건 근사가 아니라 **항등식**이다. 둘 다 없으면 0.0 을 돌려주고,
    `descriptors_from_row` 가 그 경우를 pending_total=1.0 으로 처리한다(그 함수의 계약).
    왜 이 값이 중요한가: 0 으로 두면 pending_total 이 1.0 으로 접혀 work_at_risk 가 거의 항상
    1.0 으로 포화한다 = 학습 때와 다른 feature 로 배포되는 조용한 발산.
    """
    if req.total_nodes is not None and float(req.total_nodes) > 0:
        return float(req.total_nodes)
    if req.progress and float(req.progress) > 0:
        return float(req.closed_at_fire) / float(req.progress)
    return 0.0


def _surro_row(req: "MacroRequest", macro: int) -> dict:
    """요청 + 팔 하나 -> **라벨 행과 같은 스키마**의 dict.

    `surrogate_features.build_features` 가 읽는 필드만 채운다(그 함수가 `psi(macro)` 와
    `features_agnostic.descriptors_from_row` 만 부른다). kind 는 **일부러 넣지 않는다** —
    새 표현은 종류 이름을 한 번도 읽지 않으므로, 예전의 `zone -> zoneblk` 매핑 같은
    어휘 정렬 자체가 필요 없어졌다(그 매핑이 어긋나면 one-hot 이 전부 0이 되던 실패 모드가
    구조적으로 사라진 것).
    """
    return dict(
        instance=_SURRO_INSTANCE, macro=int(macro),
        severity=float(req.severity),
        soc=(math.nan if req.soc is None else float(req.soc)),
        zone_overlap=(-1.0 if req.zone_overlap is None else float(req.zone_overlap)),
        agent_pending=float(req.agent_pending),
        n_active=float(req.n_active),
        spare_count=float(req.spare_count),
        closed_at_fire=float(req.closed_at_fire),
        total_nodes=_total_nodes(req),
        progress=float(req.progress))


def _unsupported_for(req, valid):
    """이 메뉴에서 surrogate 가 학습 근거를 못 가진 팔들. **못 쟀으면 빈 목록이 아니라 None.**

    🔴 유도는 여기 한 곳에만 둔다. `surrogate_rank` 도 `decide` 도 이 함수(또는 그것이 만든
    `UNSUPPORTED:` 문자열)에서만 값을 얻는다 — 두 벌 두면 조용히 갈린다.
    ⚠️ `req` 는 지금 안 쓰지만 시그니처에 남긴다: 앞으로 지원 여부가 사건 의존이 되면
    (예: SoC 로 갈린 메뉴) 여기서 읽어야 하고, 그때 호출부를 다시 고치지 않는다.
    """
    from e1_analyze import MACRO_NAME as MN
    name2id = {v: k for k, v in MN.items()}
    support = _state.get("surro_support")
    if support is None:
        return None
    return [m for m in valid if m in name2id and name2id[m] not in support]


def surrogate_rank(req: "MacroRequest", valid: List[str]):
    """배포 SurrogateV2 로 legal 매크로를 점수화해 순위를 낸다.

    **부호 규약: ΔĴ 는 낮을수록 좋다.** 그래서 오름차순으로 정렬한다.
    2026-08-14 이전 이 함수는 `scored.sort(key=lambda t: -t[1])`(내림차순)이었다 — 옛 모델의
    타깃이 `closed − λ·MACRO_COST`(높을수록 좋음)였기 때문이다. 새 모델을 그 정렬에 그대로
    꽂으면 서비스는 에러도 경고도 없이 **legal 팔 중 가장 나쁜 것**을 고른다.
    `wm4spacecraft_manufacturing/test_service_surrogate_rank.py` 가 이 방향을 검사로 못박는다.

    1위는 `argmin ΔĴ` 가 아니라 **배포 규칙(`SurrogateV2.choose(rule=SURRO_RULE)`)의 답**이다.
    둘은 갈릴 수 있다 — `deadband_Jbar` 는 완주확률 차이가 헤드 A 의 교정오차 밖인 팔을 먼저
    떨어낸 뒤 공유 P̄ 로 J 를 조립하기 때문이다. 규칙을 여기서 다시 쓰지 않고 그 메서드를
    부르는 이유가 그것이다: 배포된 정책과 평가한 정책이 같아야 한다.
    """
    model = _state["surrogate"]
    if model is None:
        return None, _state["surro_error"] or "surrogate not loaded"
    try:
        from e1_analyze import MACRO_NAME as MN
        name2id = {v: k for k, v in MN.items()}
        # 🔴 `or set(range(5))` 였다 (2026-08-27 수정). 그건 구세대 리터럴(매크로 5개)이고,
        #    surrogate 로드가 실패하면 지원집합이 조용히 {0,1,2,3,4} 가 되어 현행 어휘
        #    ({0,1,2})의 모든 팔이 '지원됨' 으로 읽혔다. 그러면 어휘 미달 축이 **정확히 그
        #    상황에서** 영원히 침묵한다 — 모델이 없는데 "전부 배웠다" 고 답하는 셈이다.
        #    못 읽으면 답하지 않는다.
        support = _state.get("surro_support")
        if support is None:
            return None, ("surrogate macro support is unknown (model not loaded) -- "
                          "refusing to answer rather than assuming every arm is supported")
        unsupported = _unsupported_for(req, valid)      # 유도는 한 곳에만 (위 도우미)
        scorable = [name2id[m] for m in valid if m in name2id and name2id[m] in support]
        if not scorable:
            # 🔴 2026-08-28 수정: 이 분기는 `support is None` 가드를 이미 지났으므로
            # 지원집합을 **읽었다** — `policy.jl` 의 구조 계약(`missing ≠ ∅` ⟹
            # `UNSUPPORTED:` 규약이 나왔다 ⟹ 쟀다)대로 `unsupported` 가 비어있지
            # 않으면 여기서도 그 규약을 써야 한다. 예전엔 산문으로 돌려보내 "못 쟀다"로
            # 잘못 기록됐다(안전한 방향이지만 부정확 — `tools/monitor/policy.jl:1001-1005`
            # 가 이 자리를 정확히 지목했다).
            #
            # 진단(`valid`, `support`)을 문자열에 욱여넣지 않는 이유: 소비처
            # (`decide()` L789·L799, `test_vocabulary_gap_fires.py:97`)가
            # `err.split(":", 1)[1].split(",")` 로 **이름 목록만** 기대한다 — 텍스트를
            # 덧붙이면 그 파싱이 깨진다. 정보는 안 사라진다: `valid` 는 `decide()` 응답의
            # top-level `valid` 필드에, 지원집합은 `/health` 의 `surro_support` 에 이미
            # 나간다(둘 다 `surrogate_rank` 의 유일한 호출부인 `decide()` 를 통해서만
            # 도달하므로 재구성 가능).
            if unsupported is None:
                # 🔴 리뷰 라운드 1: `_unsupported_for` 는 `_state["surro_support"]` 를
                # (위의 `support = _state.get(...)` 와는) **독립적으로 다시 읽는다**. 스레드
                # 서버에서 그 사이 모델이 리로드돼 지원집합이 지워지면 이 함수는 "못 쟀다"(None)
                # 를 돌려준다 — `if unsupported:` 로 None 과 [] 를 뭉개면 이 경우가 "다 모른다"
                # (아래 규약 밖 메시지)로 잘못 떨어진다. 이 파일에서 그 세 값(None/[]/[이름])을
                # 일부러 구분하는 자리이므로 여기서도 구분한다 — 위 가드와 같은 메시지로
                # 되돌린다(둘 다 "지원집합을 못 읽었다"는 같은 사실이다).
                return None, ("surrogate macro support is unknown (model not loaded) -- "
                              "refusing to answer rather than assuming every arm is supported")
            if unsupported:
                return None, "UNSUPPORTED:" + ",".join(unsupported)
            # `unsupported` 도 비었는데 `scorable` 도 비었다는 것은 `valid` 의 어떤 이름도
            # `name2id`(레지스트리)에 없다는 뜻이다 — "지원 안 됨"이 아니라 "애초에 모르는
            # 매크로"라 다른 사건이다. 빈 이름 목록으로 `UNSUPPORTED:` 를 내면 그것도 거짓말
            # (재긴 했는데 뺄 것이 없다는 주장)이므로 여기서는 규약 밖 메시지를 유지한다.
            return None, "no training support for any valid macro (all unknown to registry)"
        # ---- 개입이 하나도 안 남았으면 그것은 예측이 아니다 (2026-08-14, Task 7) ------------
        # [역사] 아래 실측 대가는 구세대 어휘(v3-4arms 이전)의 기록이다 — ReformTeam 도 reform
        # 메뉴도 이제 없다. 규약 자체(UNSUPPORTED 로 되돌린다)는 현행이다.
        # `supported ∩ legal` 이 {NOOP} 하나면 랭커는 후보가 하나뿐이라 그것을 "골랐다"고
        # 답한다 — **빈 후보 집합이 예측의 옷을 입은 것**이다. 그리고 그 답은 확신에 차서
        # 나가므로 호출부는 폴백할 기회조차 얻지 못한다.
        # 실측 대가(battery seed 1, reform 메뉴 {NOOP, ReformTeam}, support {0,1,2,7,8}):
        #   ReformTeam 이 탈락 -> NOOP -> 팀 교착이 안 풀려 같은 사건이 6회 재발화 ->
        #   complete True->False, closed 291/313 -> 260/313, J 35.42 -> 15300.13.
        # 그래서 여기서는 NOOP 을 답하지 않고 **UNSUPPORTED 규약으로 되돌린다** — 이미 있는
        # 그 규약이 정확히 이 상황을 위한 것인데 지금까지 도달하지 못하고 있었다. 모델은
        # reform 사건에 대해 할 말이 정말로 없고, 없다고 말하는 편이 "아무것도 하지 말라"보다
        # 정직하다. 호출부(policy.jl)는 이걸 보고 명시적으로 폴백하고 그 사실을 기록한다.
        # 주의: `unsupported` 가 비어 있으면 이 분기로 오지 않는다 — legal 이 처음부터 {NOOP}
        # 뿐이었던 경우(보류할 개입 자체가 없다)에는 NOOP 이 정직한 답이기 때문이다.
        noop_id = name2id.get("NOOP")
        if unsupported and all(m == noop_id for m in scorable):
            return None, "UNSUPPORTED:" + ",".join(unsupported)
        rows = [_surro_row(req, m) for m in scorable]
        pick = int(model.choose(rows, rule=SURRO_RULE)[_SURRO_INSTANCE])
        # 표시·margin 용 점수. NOOP 이 legal 이면 그 팔이 정확히 0 이 되어 읽기 쉽다
        # ("이 개입은 아무것도 안 하는 것보다 ΔĴ 만큼 낫다/나쁘다").
        dj = model.predict_delta_J(rows, ref_macro=0)
        order = sorted(range(len(rows)),
                       key=lambda i: (int(rows[i]["macro"]) != pick, float(dj[i])))
        scored = [(MN[int(rows[i]["macro"])], float(dj[i])) for i in order]
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


# [역사] 아래 관측(ForbidZone 선택)은 구세대 어휘(v3-4arms 이전)의 기록이다 — 그 팔은 이제 없다.
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
            # 축 1(어휘 미달)의 입력. 산문(`surrogate` 필드)이 아니라 **기계가 읽는 목록**이다.
            # None 은 "못 쟀다"(모델 미적재)이고 [] 는 "아무 팔도 지원 안 한다" — 다른 사건이다.
            #
            # 🔴 커밋 메시지 정정 (2026-08-27, 최종 리뷰 F8). `bdb0bdda` 의 메시지는
            #    *"`/health` 와 `/decide` 가 목록을 싣는다"* 라고 적었지만 **거짓이다** —
            #    지원집합 목록을 싣는 것은 이 `/health` 하나뿐이고, `/decide` 는 그 사건의
            #    `unsupported`(= 목록에서 유도된 결과)만 싣는다. 커밋 메시지는 못 고치므로
            #    정정을 여기 남긴다.
            #    귀결: Julia 쪽(`policy.jl:decide_all`)은 지원집합을 직접 못 읽는다. 그래서
            #    "쟀는가" 는 응답의 **구조**에서 유도한다 — `available == true`(점수를 냈다
            #    ⟹ support 가 None 이 아니었다) 또는 `unsupported ≠ ∅`(`UNSUPPORTED:` 규약이
            #    나왔다 ⟹ support 를 읽었다). 그 값이 결정 행의 `support_measured` 다.
            "surro_support": (None if _state.get("surro_support") is None
                              else sorted(_state["surro_support"])),
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

    scored, err = surrogate_rank(req, valid)         # surrogate 정책(배포 SurrogateV2)
    if scored:
        top = scored[0][1]
        runner = scored[1][1] if len(scored) > 1 else top
        # 정규화 분모는 **실제 점수 범위**(max-min)여야 한다 (2026-08-14 수정).
        # 예전에는 `abs(top - scored[-1][1])` 이었다 — 순위가 점수 오름차순일 때는 그것이 곧
        # 전체 폭이었지만, 이제 1위 자리는 규칙(`deadband_Jbar`)이 고른 팔이라 꼴찌가 극값이
        # 아닐 수 있다. 그러면 분모가 실제 폭보다 작아져 margin 이 1 을 넘는다
        # (실측: 점수 [+5, −7, 0] 에서 2.4). 아래 형태면 |top−runner| ≤ max−min 이 항상
        # 성립하므로 0..1 불변식이 정의상 복원된다.
        _vals = [s for _, s in scored]
        spread = max(max(_vals) - min(_vals), 1e-9)
        out["surrogate"] = {
            "chosen": scored[0][0],
            "ranking": [m for m, _ in scored],
            "scores": {m: round(s, 2) for m, s in scored},
            # margin = 1·2위 점수차를 전체 점수 폭으로 정규화한 0..1 값(0 이면 사실상 동점).
            "margin": round(abs(top - runner) / spread, 3),
            # 점수는 냈지만 **일부 유효 매크로는 학습 근거가 없어 아예 못 본** 경우를 그대로 싣는다.
            # 이걸 None 으로 뭉개면 UI 가 "surrogate 가 NOOP 을 골랐다"로 보이는데, 실제로는
            # "새 행동을 고를 수조차 없었다"이다 — 라우터가 LLM 에게 넘겨야 하는 바로 그 상황.
            "unsupported": ([] if not err or not str(err).startswith("UNSUPPORTED:")
                            else str(err).split(":", 1)[1].split(",")),
            "policy": "surrogate:SurrogateV2",
            "error": (None if (not err or str(err).startswith("UNSUPPORTED:")) else err)}
    else:
        # 점수를 못 낸 경우에도 `unsupported` 를 **반드시 실어 보낸다** (2026-08-14).
        # 여기 오는 주된 이유가 "개입 후보가 support 밖이라 전멸했다"인데, 그 목록을 빼면
        # 호출부는 왜 못 골랐는지 알 수 없고 라우터의 '표현력 격상'(unsupported -> dspy)도
        # 근거를 잃는다. 위 분기와 같은 규약을 그대로 쓴다.
        out["surrogate"] = {"chosen": "", "ranking": [], "scores": {}, "margin": 0.0,
                            "unsupported": ([] if not err or not str(err).startswith("UNSUPPORTED:")
                                            else str(err).split(":", 1)[1].split(",")),
                            "policy": "surrogate:SurrogateV2", "error": err}
    return out
