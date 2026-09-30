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
import os, sys, json, glob, math, re, uuid, hashlib
from typing import Any, Dict, List, Optional

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
WM = os.environ.get("DECISION_DIR") or os.environ.get("WM_DIR") or os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(HERE))),
    "src", "decision")
import repair_ablation as RA
#: 🔴 존 복구 base ablation(2026-09-23): 기동 때 한 번 정해진다. 레벨이 틀리면 import 에서
#:    죽는다(§ world_interface.py 의 ARTIFACT 와 같은 규약).
REPAIR_ABLATION = RA.level()
MODEL = os.environ.get("DSPY_MODEL", "gpt-4o")
# [2026-09-01] 캐시는 **기본 on** 이다: temperature 를 낮게 두어도 API 레벨 결정성은
# 보장되지 않으므로, 시드 고정 스윕의 재현성이 사실상 여기에 기대고 있다. 라이브 호출이
# 실제로 나가야 하는 측정(합성 레인 발화 / 지연·비용)에서만 `DSPY_CACHE=0` 으로
# **재시작**해 끈다. 장수 프로세스라 환경변수만 바꾸면 옛 레짐이 계속 돌기 때문에,
# 레짐(`cache`)은 `/health` 와 매 응답에 실어 보낸다 -- 산출물이 자기 레짐을 말해야 한다.
CACHE = os.environ.get("DSPY_CACHE", "1") != "0"
# 🔴 [2026-09-04] **트랜스포트 손잡이.** `gpt-4o` 는 /v1/chat/completions 로 돌지만 5.x 추론
#    계열은 function tools 와 reasoning 을 같이 쓰면 그 엔드포인트를 **거부한다**(실측:
#    `Function tools with reasoning_effort are not supported for gpt-5.6-sol in
#    /v1/chat/completions. To use function tools, use /v1/responses or set reasoning_effort
#    to 'none'`). 이 레인은 native FC 가 존재 이유라 `reasoning_effort='none'` 으로 물러서는
#    것은 답이 아니다 — 답은 /v1/responses 이고, dspy 3.3.0 에서 그 갈림길은
#    `dspy.LM(model_type=...)` 하나다(`clients/lm.py::LM.forward` 가 이 값으로
#    `litellm_completion` 과 `litellm_responses_completion` 중 하나를 고른다).
#
#    ⚠️ **모델 이름표를 코드에 박지 않는다**(`if model.startswith("gpt-5")` 류). 그런 표는
#    반드시 낡고 이 레포는 이미 그 부류에 물렸다. 어느 트랜스포트로 가는지는 서비스를 띄우는
#    쪽이 환경변수로 말하고, 산출물은 `/health` 로 자기 레짐을 다시 말한다(`cache` 와 같은
#    이유다 — 장수 프로세스는 자기가 어느 세계에서 도는지 스스로 신고해야 한다).
#    기본값이 "chat" 이라 오늘의 `gpt-4o` 요청은 **바이트 동일**하다.
#    🔴 함수인 이유: 상수는 import 시각에 한 번 정해지므로 **해석 규칙**을 시험하려면 모듈을
#    `importlib.reload` 해야 하는데, 그러면 `from dspy_service import X` 로 먼저 이름을 묶어 둔
#    다른 시험 파일들이 **낡은 객체를 계속 붙들어** 조용히 빨개진다(실측 2026-09-04:
#    reload 하는 시험 파일을 같은 프로세스에 넣자 `test_scorable_gap_prefix.py` 4건 +
#    `test_support_is_data.py` 1건이 무너졌고, 그 파일만 빼면 8 passed 로 돌아왔다).
#    규칙을 함수로 내놓으면 시험이 모듈을 다시 읽지 않고 규칙만 부를 수 있다.
def _resolve_model_type(env=None):
    """`DSPY_MODEL_TYPE` -> dspy 의 `model_type`. 기본 "chat"."""
    return (os.environ if env is None else env).get("DSPY_MODEL_TYPE", "chat")


MODEL_TYPE = _resolve_model_type()


# 🔴 [2026-09-04] temperature 도 같은 이유로 손잡이가 된다 — 이름표가 아니라 환경변수다.
#    실측(`gpt-5.6-sol` + /v1/responses + tools, 라이브 유료 호출 2026-09-04):
#      · temperature=0.2  -> BadRequest: "Unsupported parameter: 'temperature' is not
#        supported with this model." (프로바이더가 거절한다. chat 경로에서도 litellm 이
#        `UnsupportedParamsError` 로 먼저 막는다.)
#      · temperature 를 **아예 안 실으면** 같은 요청이 통과하고 tool_call 이 돌아온다.
#    그래서 이 값은 빈 문자열이나 "none" 을 주면 요청에서 **키째로 빠진다** — 1.0 이나 0 으로
#    바꿔치기하지 **않는다**. 그건 "온도를 안 정했다" 가 아니라 다른 요청이고, 조용히 그렇게
#    하면 산출물이 어느 온도에서 나왔는지 아무도 모른다.
#    (`dspy.LM(temperature=None)` 은 `self.kwargs` 에 None 으로 남지만 프로바이더 경계의
#     `openai_format.py::responses_config_kwargs` / `common_config_kwargs` 가 `is not None`
#     으로 거르므로 **전선에 안 나간다**. 실측: sent == {'model':..., 'max_output_tokens':2000}.)
#    안 주면 0.2 그대로다 — chat 경로는 안 변한다.
def _resolve_temperature(env=None):
    """`DSPY_TEMPERATURE` -> `dspy.LM(temperature=...)`. 기본 0.2. 빈 문자열/"none" 은
    **`None`** 이고, 그것은 "요청에서 키째로 뺀다"는 뜻이다 — 1.0 이나 0 이 아니다."""
    raw = (os.environ if env is None else env).get("DSPY_TEMPERATURE", "0.2").strip()
    return None if raw.lower() in ("", "none") else float(raw)


TEMPERATURE = _resolve_temperature()
# 🔴 [2026-09-03 B1] 이 값은 **한 줄로 첫 유료 런의 3단계를 통째로 죽였다.** 옛 값은 500 이고,
#    `WriteToolImpl` 은 여덟 필드(`reasoning` + 일곱)를 내야 하는데 그중 하나가 Julia 함수
#    **본문 전체**다. 라이브 응답은 `params` 한가운데서 잘렸고 JSONAdapter 는
#    `AdapterParseError` 로 죽었다 — 모델이 쓴 구현은 예외 문자열 안에만 남고 Julia 로는
#    아무것도 안 갔다(`stages == ['observe','design']`).
#
#    **숫자의 근거**(추측이 아니라 실측 위의 산술이다):
#      · 잘린 그 응답 자체가 tiktoken `o200k_base` 로 **501 토큰**(2103자) = 상한에 정확히 닿았다.
#      · 남은 것은 `params` 꼬리 + `calls`·`surface`·`reversible`·`wrote` ≈ 330자 ≈ 80 토큰
#        ⟹ **그 한 판이 완주하는 데 필요했던 값은 ~580** 이었다.
#      · 그 판의 `impl_code` 는 25줄(~1200자)이다. 이 설계가 재려는 것은 "모델이 감춰진 능력을
#        재유도하는가"(D6)이고, 그런 body 는 25줄보다 길 수 있다 — 60줄(~3000자 ≈ 750 토큰)을
#        상정하면 전체는 ~1100 토큰이다.
#    ⟹ **2000**. 관측된 요구의 3.4배, 60줄 body 상정의 1.8배다.
#
#    ⚠️ 이것은 **상한이지 지출이 아니다** — 과금은 실제로 낸 토큰에 붙는다. 그리고 이 LM 은
#    `dspy.configure` 로 설치되는 **전역**이라 네 프로그램이 전부 공유한다:
#    `SelectTool`(결정 레인) · `ObserveEvent` · `DesignToolSpec` · `WriteToolImpl`.
#    앞의 셋은 오늘 500 안에서 끝난다(첫 유료 런에서 셋 다 통과했다) — 상한을 올려도 그것들이
#    더 쓰게 되는 것은 모델이 스스로 길게 쓸 때뿐이다. 잃는 것은 병적으로 긴 생성 하나가
#    500 이 아니라 2000 토큰까지 갈 수 있다는 것이고, 그것이 이 상한의 유일한 비용이다.
# 🔴 [2026-09-05] `DSPY_MAX_TOKENS` — 상수였던 것을 knob 으로 낸다. 기본 2000 이라 chat 경로는
#    **바이트 불변**이다. 왜 필요한가: /v1/responses 에서 이 상한은 **추론 토큰까지 포함**하고
#    `LM._check_truncation` 은 `model_type != "responses"` 일 때만 경고하므로(dspy 3.3.0),
#    추론 모델이 상한에 닿으면 **경고 없이** 잘린다. `WriteToolImpl` 은 Julia 함수 **본문 전체**를
#    내야 하고, 옛 값 500 은 실제로 첫 유료 런의 3단계를 통째로 죽인 전적이 있다(위 B1 문단).
#    ⚠️ 상한이지 지출이 아니다 — 과금은 실제로 낸 토큰에 붙는다.
#    🔴 모델 이름으로 분기하지 않는다(이 레포가 낡은 표로 여러 번 당했다). 환경변수만 읽는다.
def _resolve_max_tokens(env=None):
    """`DSPY_MAX_TOKENS` -> `dspy.LM(max_tokens=...)`. 기본 2000."""
    raw = (os.environ if env is None else env).get("DSPY_MAX_TOKENS", "2000").strip()
    return 2000 if raw == "" else int(raw)


MAX_TOKENS = _resolve_max_tokens()

# 데이터셋 경로는 wm4 쪽 core/oracle_datasets.py 한 곳에서만 정의된다. 그걸 쓰려면 그 폴더를 import
# 경로에 넣어야 한다. insert(0,...) 이 아니라 append 인 이유: 이 프로세스에는 dspy/litellm 이
# 올라오므로 wm4 경로를 최우선으로 두면 동명 모듈을 가릴 위험이 있다(맨 뒤면 표준 패키지가
# 항상 먼저 이긴다). 그래서 wm4 자신의 부트스트랩(core/simulator_paths.py, insert(0,...))은 여기서
# 쓰지 않고 필요한 폴더만 직접 append 한다.
# 2026-08-18 폴더 분류: wm4 의 py 가 역할별 폴더로 나뉘었다 — 이 프로세스가 쓰는 것은
# core/(oracle_datasets) 과 surrogate/(eval_surrogate_v2 · surrogate_features · surrogate_v2) 둘이다.
WM_CODE_DIRS = [os.path.join(WM, "core"), os.path.join(WM, "surrogate")]
for _d in WM_CODE_DIRS:
    if _d not in sys.path:
        sys.path.append(_d)
import oracle_datasets                                            # noqa: E402

# ---- tool 레인 (Plan A, Task 6) --------------------------------------------------------------
# 🔴 C9: 이 두 줄은 **`import dspy`(위) 아래**에 있어야 한다. 계획서 본문은 "상단에" 라고 적지만
#    그러면 44행의 numpy/sklearn-before-dspy 계약이 깨진다(`tool_registry` 가 dspy 를 끌고 온다).
#    `tool_registry.py` 자신도 같은 순서 가드를 독립적으로 들고 있다(그 파일의 H2 주석) — 둘 중
#    하나만 남기지 말 것. 게이트: test_macro_returns_tool_call.py::
#    test_tool_registry_is_imported_below_import_dspy · test_tool_registry.py::
#    test_tool_registry_import_does_not_poison_a_later_sklearn_import
# ⚠️ `insert(0, ...)` 이 아니라 `append` 인 이유는 위 WM_CODE_DIRS 와 같다 — 이 폴더에는
#    `server.py`·`schema.py` 처럼 표준/서드파티와 이름이 겹칠 수 있는 모듈이 산다.
if HERE not in sys.path:
    sys.path.append(HERE)
# 🔴 `TOOL_TO_MACRO` 는 `MACRO_TO_TOOL` 에서 **유도된** 역표다(`tool_registry.py:91`).
#    단일 채널에서 `chosen` 이 나오는 유일한 통로라, 두 벌을 두면 결정이 갈린다.
#    `check_tool_args` 는 T2 의 인자 접지 계층 — `dspy.Tool` 에 `strict` 가 없어
#    (실측) enum·required 가 전부 권고라, 런타임이 대신 지킨다.
from tool_registry import (MACRO_TO_TOOL, TOOL_TO_MACRO, build_tools,   # noqa: E402
                          check_tool_args)
# ---- tool 합성 레인 (Plan B / T6b) --------------------------------------------------------
# 🔴 위 `tool_registry` 와 **같은 이유로** `import dspy` 아래다(numpy/sklearn-before-dspy).
#    `synthesize.py` 도 그 가드를 독립적으로 들고 있다 — 둘 중 하나만 남기지 말 것.
# 🔴 이 import 는 과금 0건이다: 모듈 최상위에서 LM 을 만들지도 부르지도 않는다.
#    합성이 실제로 도는 것은 `TOOL_SYNTHESIS=1` + `expressible == False` 두 조건이
#    함께 참일 때뿐이다(`run_synthesis` 가 부르는 `synthesize_multi` 의 docstring, 판정 R13).
from synthesize import (append_synthesis_record as _append_synthesis_record,  # noqa: E402
                        blank_synthesis_record, run_synthesis,    # noqa: E402
                        stamp_record as _stamp_record,            # noqa: E402
                        ledger_append_failures as _ledger_append_failures,          # noqa: E402
                        note_ledger_append_failure as _note_ledger_append_failure,  # noqa: E402
                        synthesis_enabled)
# ---- 세대 도장 (2026-09-03) ----------------------------------------------------------------
# 🔴 `generation` 은 stdlib 만 쓰므로 numpy/sklearn-before-dspy 계약과 무관하다.
import generation as _generation                                # noqa: E402
from dspy.utils.exceptions import AdapterParseError            # noqa: E402

# 이 모듈이 **실제로 로드된 자리**. cwd 가 아니다 — uvicorn 을 다른 디렉토리에서 띄우면
# 둘은 갈리고, 서빙되는 코드를 정하는 것은 후자다.
SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))

# 🔴 **임포트 시점에 한 번** 계산하고 얼린다. 요청마다 다시 재면 게이트가 반대 방향으로
#    거짓말한다: 소스를 고쳐도 uvicorn 은 옛 바이트를 계속 서빙하는데 `/health` 는 디스크를
#    읽어 "현행" 이라 보고한다 — 정확히 이 도장이 잡으라고 존재하는 판을 통과시킨다.
#    도장은 **임포트된 바이트**에 대한 주장이다. 게이트: `test_service_generation.py` 의
#    `test_the_fingerprint_is_frozen_at_import_not_recomputed_per_request`.
# `None` 이면 "자기 소스를 못 읽는다" — 삭제된 worktree 에서 뜬 프로세스가 내는 값이다.
CODE_FINGERPRINT = _generation.code_fingerprint(SOURCE_DIR)


# 🔴 2026-09-03 (판정 R-FLAG). `SYNTH_MULTI_AGENT` 는 **레인 스위치가 아니다.** 단일 agent
#    레인은 D8 로 삭제됐고 `synthesize.run_synthesis` 에는 분기가 없다 — 그래서 이 플래그를
#    읽는 함수도 `synthesize.py` 에서 사라졌다(`multi_agent_enabled`).
# 🔴 그런데 `/health` 의 `synth_multi_agent` 필드는 **세대 도장**으로 살아 있다:
#    `generation.check_health` 가 그것을 요구하고, 셸·Julia·시험 여섯 진입점이 그 판정을
#    거쳐 간다. 지금 필드를 지우면 그 여섯이 한꺼번에 죽는다.
# ⟹ 이 로컬 판독기가 그 자리를 잇는다. **`/health` 전용이고, 아무 레인도 이것을 안 읽는다.**
#    Task 11 이 레시피에서 플래그를 걷어낼 때 이 함수와 그 필드가 함께 사라진다.
# 🔴 raw echo 가 아니라 리터럴 `"1"` 판정인 것은 옛 함수와 같다 — `true`/`TRUE`/`on` 은 전부
#    OFF 로 읽혔고, 판독자가 그것을 "켜짐" 으로 오독하는 것을 막는 것이 이 규약의 이유였다.
SYNTH_MULTI_AGENT_ENV = "SYNTH_MULTI_AGENT"


def _synth_multi_agent_stamp() -> bool:
    """`/health` 의 `synth_multi_agent`. 세대 도장일 뿐, 레인은 이것을 안 본다."""
    return os.environ.get(SYNTH_MULTI_AGENT_ENV, "") == "1"


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

    # 🔴 유일한 출력 필드다 (2026-08-29, 단일 채널). `reasoning`·`expressible`·`macro`·
    #    `ranking`·`margin` 다섯 텍스트 OutputField 를 여기서 **삭제했다.**
    #    이유: `tool_choice="required"` 판에서 프로바이더가 message content 를 비우고,
    #    `adapters/base.py:168` 이 `value = ... if text and ... else {}`, `:181` 이
    #    `value.setdefault(field_name, None)` 을 하므로 **예외 없이** 전 필드가 `None` 이 된다
    #    (실측: 그 응답 모양을 어댑터에 직접 흘려 재현). 채울 수 없는 필드를 남기면 조용하다.
    #    결정 성분은 `tool_registry.COMMON_ARGS` 가 tool 인자로 나른다.
    action: dspy.ToolCalls = dspy.OutputField()


def build_adapter():
    """native FC 를 켠 어댑터. **site-packages 의 기본값(False)을 고치지 않는다** — 그건
    재설치에 날아가고 이 레포 밖에서 돌리는 사람과 조용히 갈린다(spec §2-4).

    ⚠️ 어댑터 **클래스**는 일부러 못박지 않는다. 변이 V10(`JSONAdapter` 반환)은 이 게이트에서
    살아남는데(실측: `16 passed *** SURVIVED ***`) 그게 옳다 — `JSONAdapter` 는
    `ChatAdapter` 의 자식이고 플래그를 그대로 물려주므로 §2-4 의 네 조건이 전부 그대로 선다.
    클래스를 못박으면 이 태스크가 재지 않은 **직렬화 형식**에 대한 불변식을 세우는 셈이고,
    그 불변식은 런타임에 이미 거짓이다: `ChatAdapter.__call__` 은 파싱 실패 시 스스로
    `JSONAdapter` 로 재시도한다. 우리가 주장하는 것은 네 조건이지 클래스가 아니다.

    🔴 **`parallel_tool_calls` 를 여기 걸지 않는다** (2026-08-29, T5 — 계획서 지시를 실측으로
    뒤집은 자리다). 이 생성자는 그 인자를 받고(`chat_adapter.py:47`) 값도 `lm_kwargs` 까지
    간다. 그런데 dspy 3.3.0 은 `tool_choice` 와 그것을 **프로바이더 경계에서 한 객체**
    (`LMToolChoice`)로 접어서, 이 키만 실린 요청에 `tool_choice: "auto"` 를 **지어내 붙인다**
    (실측: `core/types.py:538-542` + `clients/openai_format.py:396-398`).
    ⟹ 여기 걸면 그 값이 **모든** 요청에 실리므로 `DSPY_TOOL_CHOICE=""` 킬스위치가 더 이상
      2026-08-29 이전과 바이트 동일한 요청을 못 낸다 — 그 손잡이의 존재 이유 전체가 A/B
      비교판을 로직 편집 없이 내는 것이다. 실측: 그 한 줄만 넣으면 `test_tool_choice_forced.py`
      의 계약 넷이 빨개진다.
    그래서 `_ask` 가 `tool_choice` 와 **같은 조건 아래** 싣는다(그 함수의 같은 날짜 주석).
    잠금장치: test_tool_choice_forced.py::test_the_adapter_does_not_carry_the_parallel_flag
    """
    return dspy.ChatAdapter(use_native_function_calling=True)


_state = {"program": None, "instructions": None, "demos": 0, "calls": 0, "billed": 0,
          "surrogate": None, "surro_feats": None, "surro_data": None, "surro_error": None}


def _was_billed():
    """직전 LM 호출이 캐시 히트가 아니라 **실제 과금 호출**이었는가.
    dspy 3.3 의 history 엔트리는 `cache_hit` 을 싣고 `cost` 는 캐시 히트에서 None 이다.
    판별 불가면 False -- 세지 못한 호출이 남는 건 회복 가능하지만, 부풀린 과금 수는
    그대로 인용된다. `CACHE` 가 꺼져 있으면 애초에 히트가 없으므로 전부 과금이다."""
    if not CACHE:
        return True
    try:
        e = dspy.settings.lm.history[-1]
    except Exception:
        return False
    hit = getattr(e, "cache_hit", None)
    if hit is None:
        try:
            hit = e["cache_hit"]
        except Exception:
            hit = None
    if hit is not None:
        return not hit
    return bool(getattr(e, "cost", None))


def native_fc_active(signature=None):
    """native FC 가 **실제로** 켜졌는가 — 네 조건을 런타임에 전부 읽는다(spec §2-4).

    🔴 배선 여부가 아니라 발화 여부다. 조건 4(`lm.supports_function_calling`)는 LM 이 정하므로
    코드를 읽어서는 알 수 없다. 이 함수의 반환값을 응답에 실어야 라이브 런에서 "배선했다" 와
    "실제로 켜졌다" 가 구분된다.

    네 조건(어댑터 플래그 · `list[dspy.Tool]` 입력 · `dspy.ToolCalls` 출력 ·
    `lm.supports_function_calling`)이 전부 참일 때만 True.

    🔴 **어느 시그니처를 읽는가**: 인자가 없으면 모듈 상수 `SelectTool` 이 아니라 **실제로 도는
    프로그램**(`_state["program"].signature`)을 읽는다. 둘은 갈릴 수 있고 — `_load_program()`
    이 tool 필드 없는 시그니처를 얹으면 — 그때 `SelectTool` 을 읽으면 이 함수는 "native FC 가
    발화했다"고 답하면서 provider 로 나가는 tools 는 0개인 상태를 보고하게 된다. 그건 이 필드의
    존재 이유(배선 ≠ 발화)와 정확히 반대 방향의 거짓말이다. 실측(컨트롤러 B1):
    tool 필드를 뺀 프로그램에서 `native_fc_active()` -> True 인데 provider 로는 tool 이 0개 간다.
    (정확히는 키가 **없다**: `_call_preprocess` 뒤 `lm_kwargs == {}`, `"tools" in lm_kwargs` 는
    `False`. 전에 여기 적혀 있던 `lm_kwargs["tools"] -> []` 는 그대로 실행하면 `KeyError` 다.)

    🔴 `supports_function_calling`(조건 4)은 **로컬 조회가 아니다**(2026-08-28 정정). LM 생성은
    connect 0건이지만 그 속성을 **읽으면** litellm 이 원격 cost map(raw.githubusercontent.com)을
    가져오려 하고, 실패하면 로컬 백업으로 폴백한다 — 실측 connect 시도 **프로세스당** 8건
    (IPv4 4 + IPv6 4). 읽기당이 아니다: litellm 이 cost map 을 모듈 수준에 캐싱해서 두 번째
    읽기부터는 0건이다(실측: 새 LM 객체로 5회 읽어도 총계 8, 모델을 바꿔도 그대로).
    값은 옳고 **과금은 없다**(provider 호출이 아니다). 오프라인 CI 는 프로세스당 한 번 문다.
    아직 프로그램이 없으면(부팅 전) `SelectTool` 로 폴백한다.

    🔴 못 재면 `False` 가 아니라 `None` 을 낸다. "못 쟀다"(None)와 "재서 꺼져 있었다"(False)는
    다른 사건이다(spec §9-2). 아무도 `dspy.configure` 를 안 불렀으면 조건 1·4 를 **읽을 수
    없으므로** dspy 의 폴백 기본값을 추론해 False 를 내지 않는다 — 그건 측정이 아니다.

    ⚠️ **세 상태 중 라이브에서 도달 가능한 것은 둘뿐이다**(검증자 실측, 2026-08-28).
    `_startup()` 이 항상 `_configure_dspy()` 를 먼저 돌리므로 adapter/lm 이 비는 일이 없고,
    `DSPY_MODEL` 값 여덟 가지(빈 문자열·존재하지 않는 모델 포함)를 훑어도 `None` 이 나오지
    않았다. 즉 `None` 은 **부팅 전 / 시험 안에서만** 나오는 상태다. 이 값을 응답에 싣는 쪽
    (Task 6)은 "라이브에서 None 을 본 적이 없다"를 "못 잰 적이 없다"의 증거로 쓰면 안 된다 —
    그 상태는 애초에 그 경로로 도달하지 않는다.
    """
    try:
        sig = signature
        if sig is None:
            prog = _state["program"]
            sig = prog.signature if prog is not None else SelectTool
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
#  · 학습셋 : n44_plus78 -> RELABEL_20260814. **`oracle_datasets.resolve()` 를 쓰지 않는다** —
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
# ⚠️ `oracle_datasets.resolve()` 를 **쓰지 않는다** — 그 함수는 $WM_DATASET/$EVAL_DATA 를 읽으므로
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
# selfimprove(spec §5.1): 버전마다 다른 데이터셋으로 띄운다. 없으면 현행 라벨셋.
SURRO_DATA = os.environ.get("SURRO_DATA") or oracle_datasets.abspath(oracle_datasets.ORACLE_DATASET)
# selfimprove 조건 ②③(spec §5.3, §0.0 R2). 0 = 둘 다 끔 — 기본 서비스의 동작이 바뀌지 않는다.
SURRO_TAU = float(os.environ.get("SURRO_TAU", "0"))
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
SURRO_RULE = os.environ.get("SURRO_RULE", "deadband_Jbar")


def _check_selfimprove_manifest(model, rows, meta):
    """`SELFIMPROVE_MANIFEST` 가 있으면 이 프로세스가 그 버전의 정책인지 확인한다 (spec §5.4 규칙 6, R8).

    불일치는 `[selfimprove]` 예외 — `_load_surrogate` 가 다시 던져 기동을 실패시킨다."""
    man = os.environ.get("SELFIMPROVE_MANIFEST")
    if not man:
        return
    import hashlib
    from surrogate_probe import probe_sha256
    raw = open(man, "rb").read()
    msha = hashlib.sha256(raw).hexdigest()
    m = json.loads(raw)
    sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
    bad = []
    if open(os.path.join(os.path.dirname(man), "manifest.sha256")).read().strip() != msha:
        bad.append("manifest.sha256")
    if sha(SURRO_DATA) != m["dataset_sha256"]:
        bad.append("dataset")
    reg = os.environ.get("ACTION_REGISTRY")
    if not reg or sha(reg) != m["registry_sha256"]:
        bad.append("registry")
    if SURRO_TAU != float(m["surro_tau"]):
        bad.append("surro_tau")
    if SURRO_RULE != m["surro_rule"]:
        bad.append("surro_rule")
    if meta["objective_hash"] != m["objective_hash"]:
        bad.append("objective_hash")
    psha = probe_sha256(model, rows)
    if psha != m["model_probe_sha256"]:
        bad.append("model_probe")
    if bad:
        raise RuntimeError("[selfimprove] service identity mismatch: %s" % bad)
    _state.update(agent_version=m["version"], manifest_sha256=msha, model_probe_sha256=psha)


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
        # ---- kind 지원집합 (2026-08-29, T9) --------------------------------------------
        # 🔴 `support`(매크로)와 **같은 모양**으로 학습행에서 유도한다. 손으로 쓴 목록은
        #    두 번째 진실원이 되고, 이 파일은 그 사고를 이미 한 번 밟았다(:664-668 의
        #    `or set(range(5))`). 게이트: test_surro_kinds.py 의 리터럴 스캔.
        observed = sorted({r["kind"] for r in rows if r.get("kind")})
        stamps = {r.get("train_kinds") for r in rows}
        stamp = next(iter(stamps)) if len(stamps) == 1 else None
        declared = sorted(x for x in (stamp or "").split(",") if x)
        if stamp is None or declared != observed:
            # 🔴 **한쪽을 골라 믿지 않는다.** 도장과 행이 갈렸다는 것은 데이터셋 세대가
            #    섞였다는 뜻이고(C9/R-50 이 이 축을 만든 이유), 그 상태에서 낸 kind 집합은
            #    라우터를 조용히 틀린 쪽으로 민다. "못 쟀다"(None)로 떨어뜨린다.
            #    ⚠️ 모델 자체는 계속 적재한다 — kind 를 못 쟀다고 surrogate 를 못 쓰게 만들면
            #    라우팅과 무관한 회귀가 된다. 정지는 라우터(`select_lane`)가 한다.
            kinds = None
            kind_err = ("train_kinds stamp %r disagrees with the observed kinds %r"
                        % (stamp, observed))
        else:
            kinds, kind_err = set(observed), None
        # 스레드를 1로 묶는다. 공유 서버(56코어)에서 OpenMP 가 코어 수만큼 스레드를 띄우면
        # 355행짜리 적합이 0.58s -> 132.6s 로 늘어난다(Task 6 실측 227배). 결과는 안 바뀐다.
        with threadpool_limits(limits=1):
            model = SurrogateV2().fit(rows)
        _check_selfimprove_manifest(model, rows, meta)
        # **학습 근거가 있는 매크로 집합**을 같이 기록한다. 여기 없는 값을 예측하는 것은 근거 없는
        # 외삽이고, 조용히 점수를 내면 UI 가 "surrogate 가 NOOP 을 골랐다"로 보이지만 사실은
        # "고를 수조차 없었다"이다. 이 구분이 곧 라우터(낯선 것은 LLM)의 존재 이유다.
        _state.update(surrogate=model, surro_feats=list(FEATURE_NAMES),
                      surro_support=set(support), surro_kinds=kinds,
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
        if kind_err:
            # 🔴 기존 값을 **덮지 않는다** — 두 실패가 동시에 났으면 둘 다 보여야 한다.
            prev = _state.get("surro_error")
            _state["surro_error"] = ("%s; %s" % (prev, kind_err)) if prev else kind_err
    except (Exception, SystemExit) as e:
        if "[selfimprove]" in str(e):
            raise                     # 버전 신원 불일치는 보고가 아니라 기동 실패다(spec §5.4 규칙 6)
        # 🔴 여기 오면 kind 도 **못 쟀다.** 낡은 값을 남기면 /health 가 지난 세대의 kind 집합을
        #    현행이라고 주장하고, 라우터가 그것으로 레인을 고른다.
        _state["surro_kinds"] = None
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


def _configure_dspy():
    """LM 과 **native FC 어댑터를 실제로 설치하는** 줄. `_startup()` 에서 떼어낸 이유는 시험이
    이 줄을 직접 돌릴 수 있어야 하기 때문이다(`_startup` 은 SurrogateV2 적합까지 끌고 온다).

    🔴 아래 `adapter=` 가 프로덕션에서 native FC 를 켜는 **유일한 줄**이다. 이 줄이 사라져도
    `build_adapter()` 를 따로 부르는 시험은 전부 초록으로 남는다 — 컨트롤러 실측 변이 V6:
    `_startup() drops adapter=build_adapter() -> 12 passed *** SURVIVED ***`. 그리고 레인은
    조용히 텍스트 직렬화 경로로 돌아간다(spec §10 risk 4). 그래서
    `test_native_fc_active.py::test_configure_dspy_installs_the_native_fc_adapter` 가 이 줄
    하나만을 감시한다.

    LM **객체 생성**은 connect 0건이고, 이 함수는 provider 호출을 내지 않는다 — 과금 0건이다.
    (여기서 `supports_function_calling` 을 읽지는 않는다. 그 속성의 성질은 `native_fc_active`
    아래 주석 참조: 읽으면 원격 cost map fetch 를 시도한다.)
    🔴 [2026-09-04] `MAX_TOKENS` 는 트랜스포트를 건너도 **이름만 바뀌어 그대로 간다** — dspy 가
    `openai_format.py::responses_config_kwargs` 에서 `max_output_tokens` 로 옮긴다(실측: 보낸
    요청이 `{'model': ..., 'max_output_tokens': 2000}`). 그래서 여기서 손으로 개명하지 않는다.
    ⚠️ 다만 /v1/responses 에서 그 상한은 **추론 토큰까지 포함**하고, `LM._check_truncation` 은
      `model_type != "responses"` 일 때만 경고하므로(dspy 3.3.0) 추론 모델에서 상한에 닿으면
      **경고 없이** 잘린다. 2000 의 근거(위 `MAX_TOKENS` 주석)는 chat 경로에서 잰 것이다.
    """
    lm = dspy.LM("openai/%s" % MODEL, model_type=MODEL_TYPE,
                 temperature=TEMPERATURE, max_tokens=MAX_TOKENS, cache=CACHE)
    dspy.configure(lm=lm, adapter=build_adapter())
    return lm


@app.on_event("startup")
def _startup():
    # 🔴 킬스위치 오설정은 **부팅에서** 잡는다. `tool_choice()` 의 검증은 요청마다 걸리므로
    #    환경변수가 틀렸으면 **매 사건이 HTTP 500** 이 되고, 그 이유는 서비스 로그에만 남는다
    #    (실측: `TestClient` -> `status 500`, body `"Internal Server Error"`. 줄리아 쪽은
    #    `policy.jl:676` 의 `@warn "DSPy call failed"` 로 사실만 보고 이유를 못 받는다).
    #    여기서 한 번 태워 두면 그 판은 **뜨지도 않는다** — 반나절 돌린 뒤 산출물이 전부
    #    canonical 폴백이었다는 것을 나중에 발견하는 것보다 낫다.
    #    ⚠️ `tool_choice()` 는 여전히 **호출 시점에** 환경변수를 읽는다(시험이 monkeypatch 로
    #      두 레짐을 다 돌릴 수 있어야 한다). 이 줄은 그 계약을 안 바꾸고 부팅에 한 번 더 잰다.
    tool_choice(None)
    _configure_dspy()
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
    # ---- SMDP 상태 (2026-09-06) --------------------------------------------------------
    # 사용자 정의 6축 `{p, b, v, w, c, k}` 중 **페이로드에 없던 둘**. 나머지 넷은 이미 위에
    # 선언돼 있다: `p`=progress · `v`=spare_count · `w`=n_active · `k`=kind.
    # 🔴 `smdp_` 접두사는 장식이 아니다 — 라벨셋의 `min_soc`/`hz_break` 은 rollout 완주 후
    #    측정한 **사후** 필드라 피처로 쓰면 leakage 다. 이름을 갈라 두면 나중에 라벨 행과
    #    합칠 때 그 둘이 섞이지 않는다.
    # ★ Pydantic 은 선언 안 된 키를 조용히 버린다 — 이 두 줄이 없으면 policy.jl 이 실어
    #   보내도 무효이고, 프롬프트는 그 부재를 표시하지 않는다.
    smdp_n_broken: Optional[int] = None
    smdp_fleet_soc_min: Optional[float] = None
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
    # ---- 2026-09-05: 종단성(terminality) 술어. **비율이 아니다** ----------------------
    # 위 `zone_nav_downstream` 은 "얼마나 얼어붙나"(비율로 읽힌다)이고, 아래는 "완주가 아직
    # 가능한가"(술어)다. 둘은 다른 물음이고, 실측이 그 차이를 잡았다: 2026-09-05 의 두 라이브
    # zone 판에서 downstream 은 32/251(=13%)이었고 모델은 그것을 보고 *"minimally impacts the
    # build"* 라며 NOOP 을 골랐다 — 비율로서는 틀리지 않은 독해다. 그런데 그 판의 정답은
    # **완주 실패**였다(tool-off 대조: PROJECT INCOMPLETE, 270/305). 세계가 결정 시점에 이미
    # 알고 있던 사실은 비율이 아니라 그래프 술어였다: `project_complete(env)` 가 요구하는
    # ProjectComplete 정점이 막힌 노드의 후방 폐포 안에 있다.
    # ★ 삼상. `None` = **안 쟀다**. `False` = 재 봤더니 완주는 안 막혔다. 호출자
    #   (`policy.jl:ood_features`)는 못 쟀을 때 키 자체를 안 싣는다.
    zone_project_blocked: Optional[bool] = None    # 완주 정점이 막힘의 후방 폐포 안에 있는가
    zone_project_nodes_blocked: Optional[int] = None  # 그런 미완 ProjectComplete 정점 수
    zone_project_nodes_open: Optional[int] = None     # 아직 안 닫힌 ProjectComplete 정점 수(분모)
    zone_unfinished_total: Optional[int] = None    # 그 비교 분모(전체 미완 노드 수)

    # ---- battery 적재/함대 상태 (2026-08-31, S1/T2) ------------------------------------
    # 🔴 왜. 2026-08-30 실측: battery_mild 사건의 프롬프트에 payload 질량이 한 글자도 없어
    #    "낮은 SoC 로봇이 무거운 짐을 맡으면 SoC 가 더 빨리 떨어진다"는 추론이 원리적으로
    #    불가능했다. 여기 있는 것은 전부 **사실**이고 판정은 하나도 없다.
    # ⚠️ 다섯이 함께 오지 않는다: 배터리 레이어가 꺼져 있으면 SoC 셋이 빠지고, 그 로봇에
    #    미완 운반 작업이 없으면 payload 둘이 빠진다. `_battery_block` 이 키마다 거른다.
    battery_pending_transports: Optional[int] = None    # 이 로봇이 아직 맡고 있는 운반 작업 수
    battery_payload_proxy_max: Optional[float] = None      # 그중 가장 큰 화물의 대리값(밀도 x bbox 부피)
    battery_payload_proxy_total: Optional[float] = None    # 그 대리값을 그 작업들에 대해 합한 것
    battery_fleet_soc_median: Optional[float] = None    # 함대 SoC 의 중앙값
    battery_higher_soc_robots: Optional[int] = None     # 이 로봇보다 SoC 가 높은 활성 로봇 수
    # valid : 호출자가 **세계를 보고** 계산한 legal 매크로 목록(2026-08-05 추가).
    #   kind 만으로 정하면 전제조건이 있는 팔(구 어휘의 ForbidZone: 아직 시작 안 한 조립체만 옮길 수
    #   있음)을 "언제나 불법" 또는 "언제나 합법" 중 하나로만 둘 수 있다. 둘 다 틀린다 — 전자는 실행
    #   가능한 국소 복구를 어휘에서 지워 매번 전역 이동(구 RelocateBuild)을 시키고, 후자는 조용한 no-op 을
    #   고르게 한다. 상태를 아는 쪽(줄리아)이 계산해 실어 보내는 것이 유일하게 옳은 배치다.
    # agents : 이 요청 시점에 **실재하는** 로봇 목록 [{id, label}, ...].
    #   `llm_bridge.open_agent_descriptors` 가 만드는 형태를 그대로 받는다.
    #   ②접지의 재료다 — tool 파라미터의 enum 이 이 목록에서만 나오므로, 모델은 **살아 있는
    #   id 만 담긴 메뉴를 본다.**
    #   🔴 2026-08-29 정정. 여기 있던 *"여기 없는 id 는 모델이 생성할 수 없다(디코드 시점
    #      차단)"* 는 **거짓이다.** 실측: `format_as_litellm_function_call()` 의 `parameters` 는
    #      `{properties, required, type}` 뿐 — `strict` 도 `additionalProperties` 도 없고,
    #      dspy 3.3.0 의 `dspy.Tool` 에는 `strict` 필드 **자체가 없다**(`model_fields` =
    #      arg_desc·arg_types·args·desc·func·has_kwargs·name). `tool_choice` 도 안 보낸다.
    #      출하되는 것은 **보여준 것**이지 강제한 것이 아니다. 비-strict `enum` 에 프로바이더가
    #      문법 제약을 거는지는 **안 잰 프로바이더 동작**이고, 라이브 호출 없이는 못 정한다.
    # ★ 선언하지 않으면 pydantic 이 조용히 버린다. 그러면 enum 이 빈 목록으로 굳어 tool
    #   호출이 전부 막히는데, 원인이 호출자에 있는 것처럼 보인다.
    agents: Optional[List[Dict[str, str]]] = None
    # zones : 이 요청 시점에 **살아 있는** 출입금지 구역 목록.
    #   `llm_bridge.open_zone_descriptors(env)` 가 만드는 형태 그대로
    #   [{key, center, radius, covers, covers_root, build_center, build_radius, max_shift,
    #     work_reach}, ...], 구역 키로 정렬돼 있고 **활성 구역이 없으면 빈 목록**이다.
    #   🔴 spec §9-1 표에서 이것이 **기하 축의 유일한 입력**이다. 이게 없으면 zone 사건에서
    #      파라미터(어느 구역을, 무엇을 덮은 채로)를 유도하는 것이 원리적으로 불가능하다.
    #   ★ 선언하지 않으면 pydantic 이 조용히 버린다 — 호출자가 실어 보내도 서비스는 못 보고,
    #     증상은 **호출자 쪽 결함처럼** 보인다. 실측(선언 전, 2026-08-29):
    #     `MacroRequest(kind="zone", zones=[...]).zones` -> AttributeError, 즉 값이 사라진다.
    #     게이트: `test_zone_channel.py::test_zones_survives_the_pydantic_boundary`.
    zones: Optional[List[Dict[str, Any]]] = None
    valid: Optional[List[str]] = None
    # tool_choice : **이 사건에 대해 호출자가 정한** tool 강제 여부 (2026-08-29, Plan B / T-C).
    #   `"required"` = 이 요청은 tool 호출을 요구한다 · `None`/없음 = 요구하지 않는다(그러면
    #   `_ask` 가 그 키를 프로바이더 요청에 **아예 안 싣는다** = 2026-08-29 이전과 바이트 동일).
    #   🔴 **2026-08-29 (Ruling R15): 아래 유도는 더 이상 일어나지 않는다.** 옛 서술은 현재형으로
    #   *"유도는 호출자에 있다 — `policy.jl` 의 `tool_choice_for` 가 `novelty_measured`·`novel`
    #   둘만 보고 정한다"* 였다. 두 번 끊겼다: ① **T6** 이 `service_decide` 의 `tool_choice`
    #   키워드와 `decide_all` 의 유도 호출부를 지워 **줄리아가 이 키를 한 번도 안 싣는다**
    #   (`test/tool_choice_gate.jl` (3)·(4)절이 그것을 못박는다). ② **§B-1** 이 novelty 축을
    #   삭제해 `route_verdict` 가 `novelty_measured`·`novel` 을 **더 이상 내지 않는다**
    #   (`tool_choice_for` 는 되돌릴 때를 위해 남은 죽은 순수 함수이고, 그 docstring 이 근거를 진다).
    #   🔴 그래서 **"강제가 사건별로 게이팅된다" 고 읽지 말 것** — T5 가 이 서비스의
    #   `TOOL_CHOICE_DEFAULT` 를 `"required"` 로 세웠으므로, 호출자가 이 키를 안 싣는 것이 곧
    #   **모든 호출을 강제하는 것**이다. 오늘 강제를 끄는 자리는 이 필드가 아니라 호스트의
    #   `DSPY_TOOL_CHOICE` 하나다(아래 우선순위 줄).
    #   이 필드 자체는 남긴다 — 배선을 되돌릴 때 필요하고, 선언을 지우면 pydantic 이 조용히
    #   버려서 되돌린 호출자가 원인을 못 찾는다(바로 아래 ★).
    #   🔴 우선순위는 `tool_choice(req)` 가 정한다 — **환경변수가 이기고**, 없을 때만 이 값을
    #      쓴다. `DSPY_TOOL_CHOICE` 는 사람이 잡는 양방향 킬스위치이기 때문이다.
    #   ★ 선언하지 않으면 pydantic 이 **조용히 버린다**. 그러면 호출자가 실어 보내도 서비스는
    #     못 보고, 모든 사건이 "요청이 강제를 안 했다"로 굳는다 — 원인이 호출자에 있는 것처럼
    #     보인다. 이 레포가 `total_nodes`(위)에서 이미 밟은 함정이다.
    tool_choice: Optional[str] = None
    # lanes : 이 요청이 **실제로 청구하는** 레인 (2026-08-29, T10 / §0-C 충돌 ⑦).
    #   `None`(또는 키 없음) = 둘 다 = 2026-08-29 이전과 동일(하위호환).
    #   `["surrogate"]` = surrogate 만 → **LM 호출 0건**. 🔴 이것이 kind 색인 라우터의 비용
    #   절감이 실제로 사는 유일한 자리다: `select_lane` 만 고치면 이 함수가 맨 앞에서
    #   `macro(req)` 를 부르므로 비용이 1원도 안 준다.
    #   `[]` = 아무 레인도 안 청구했다 — `None` 과 **다른 사건**이다(삼상). falsy 로 접지 말 것.
    #   ★ 선언하지 않으면 pydantic 이 조용히 버리고 모든 사건이 "둘 다" 로 굳는다.
    #     게이트: test_decide_lanes.py::test_lanes_survives_the_pydantic_boundary
    lanes: Optional[List[str]] = None
    # routing_kind : 라우터가 **판정에 쓴** kind (2026-08-29, §A-1). 위 `kind` 와 **다른
    #   함수**에서 온다: 저쪽(`ood_features`)은 사건을 **자기 이름**으로 부르고(모르는 타입은
    #   `"unknown"`), 라우팅은 LLM 레인으로 갈 것 전부에 `"unknown:"` 접두사를 단다. 두 값이
    #   갈리는 사건이 곧 OOD 사건이고, 그 사실을 `_unfamiliar_block`(아래)이 프롬프트에 싣는다.
    #   🔴 2026-09-07 정정. 여기 있던 *"저쪽은 모르는 타입을 surrogate 피처로 쓰려고 "fault"
    #     로 접는다"* 는 **거짓이었다.** surrogate 는 `kind` 를 안 읽는다 — `_surro_row`(아래)
    #     가 일부러 안 싣고, `descriptors_from_row` 는 계약상 `row['kind']` 를 절대 안 읽는다.
    #     그 거짓 전제가 `else` 분기의 `"fault"` 리터럴을 지키고 있었고, 그 리터럴은 폴백
    #     경로에서 `_unfamiliar_block` 과 **같은 프롬프트 안에서 모순**이었다. 지금은
    #     `("unknown", nothing)` 이다(`policy.jl`, 사용자 결정).
    #   ★ pydantic 은 선언 안 된 키를 조용히 버린다 — 이 선언이 없으면 호출자
    #     (`policy.jl:service_decide`)가 실어 보내도 무효이고, 증상은 **호출자 쪽 결함처럼**
    #     보인다. 이 레포가 `total_nodes`·`zones`·`lanes` 에서 이미 세 번 밟은 함정이다.
    #   🔴 `Optional[...] = None` 이어야 한다 — 이 필드를 안 싣는 옛 호출자의 요청이 422 로
    #     죽으면 안 된다(하위호환).
    #   게이트: test_routing_kind_reaches_the_prompt.py
    routing_kind: Optional[str] = None
    # ---- 원장 신원 (2026-09-22, 재시도 body 보존) --------------------------------------
    # 🔴 줄리아가 **발급**한다. 서버가 만들면 `/decide` 의 HTTP 재전송(`retries=3`)이 같은
    #    결정을 다른 id 두 줄로 남긴다 — 같은 id 두 줄이면 소비자가 중복임을 안다.
    #    서버는 따로 처리마다 `response_id` 를 발급한다(`macro()`) — 둘의 쌍이 실제로 받은 응답이다.
    # ★ Pydantic 은 선언 안 된 키를 조용히 버린다 — 이 두 줄이 없으면 실어 보내도 무효다.
    record_id: Optional[str] = None
    run_ctx: Optional[Dict[str, Any]] = None


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

    🔴 2026-08-31 (S1). `zone_nav_blocked`/`zone_nav_downstream` 을 여기서 빠뜨리면
    `descriptors_from_row` 가 그 둘을 -1.0 센티널로 읽어 `zone_terminal=False` 로 접는다 —
    같은 사건인데 LLM 레인(`_llm_input`)은 새 nav-blockage `harm` 을, surrogate 레인은
    옛 area-ratio `harm` 을 본다. 두 레인이 **같은 req** 에서 값을 읽으므로 규약은
    `zone_overlap` 과 동일: 없으면 `None` -> -1.0 센티널("안 쟀다")로만 접는다.
    🔴 **0 으로 접지 말 것** — 0 은 "쟀는데 안 막혔다"이고 그러면 `zone_terminal` 판정 자체는
    `nblk >= 1.0` 이라 여전히 False 로 떨어지지만, 의미가 "안 쟀다"에서 "쟀다"로 거짓 이동한다.
    게이트: `test_surro_zone_nav_descriptors.py`.
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
        progress=float(req.progress),
        zone_nav_blocked=(-1.0 if req.zone_nav_blocked is None else float(req.zone_nav_blocked)),
        zone_nav_downstream=(-1.0 if req.zone_nav_downstream is None else float(req.zone_nav_downstream)))


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
        # ---- selfimprove 조건 ② (spec §5.3). τ=0(기본)이면 꺼진다 — 위 주석의 {NOOP} 규약 유지 --
        if SURRO_TAU > 0 and not [m for m in scorable if m != noop_id]:
            return None, "DEFER:no_arm"
        rows = [_surro_row(req, m) for m in scorable]
        ps = [float(x) for x in model.predict_complete_proba(rows)]
        # ---- selfimprove 조건 ③ (spec §0.0 R2): P̂(a) ≥ τ 인 팔만 선택 후보 -------------------
        #      "max P̂ ≥ τ" 만 보면 규칙이 P̂ < τ 인 팔을 고를 수 있다(검토 2).
        if SURRO_TAU > 0:
            keep = [i for i, p in enumerate(ps) if p >= SURRO_TAU]
            if not keep:
                return None, "DEFER:low_confidence:%.4f" % max(ps)
            rows, ps = [rows[i] for i in keep], [ps[i] for i in keep]
        pick = int(model.choose(rows, rule=SURRO_RULE)[_SURRO_INSTANCE])
        # 표시·margin 용 점수. NOOP 이 legal 이면 그 팔이 정확히 0 이 되어 읽기 쉽다
        # ("이 개입은 아무것도 안 하는 것보다 ΔĴ 만큼 낫다/나쁘다").
        dj = model.predict_delta_J(rows, ref_macro=0)
        order = sorted(range(len(rows)),
                       key=lambda i: (int(rows[i]["macro"]) != pick, float(dj[i])))
        scored = [(MN[int(rows[i]["macro"])], float(dj[i]), ps[i]) for i in order]
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


# ---- SMDP 상태 5축 (2026-09-06, `k` 는 2026-09-07 에 뺐다) -------------------------------------
# 사용자 정의 `{p, b, v, w, c}`. 두 축을 **일부러** 뺐고, 근거가 서로 다르다.
#
# `d`(time to done): 결정 시점 완료시간 추정량이 **세계에 없다**(`tplan.jl` 의 `T_plan_next` 는
#   λ 의 구간상수 경계이지 완료시간이 아니고, `metrics.jl` 의 makespan 은 런이 끝난 뒤 계산하는
#   사후 지표다). 즉 못 재는 축이다.
#
# 🔴 `k`(event_kind, 2026-09-07 사용자 결정): **잴 수는 있는데 정보가 0 이고, 유일하게 정보를
#    나를 순간에는 틀린다.** 논문의 상태 정의도 다섯으로 고친다. 근거 넷:
#      ① "처음 보는 사건인가" 는 `_unfamiliar_block` 이 별도 문단으로 이미 싣는다.
#      ② "어떤 종류인가" 는 `_geometry_block`/`_zones_block`/`_battery_block` 이 이미 말한다 —
#         셋 다 자기 kind 일 때만 비어 있지 않으므로 **블록의 존재 자체가 kind 다.** 게다가
#         그 블록들은 `k` 가 못 하는 일(얼마나 막혔는가)까지 한다.
#      ③ 이 레인은 `routing_kind` 가 `"unknown:"` 일 때만 도달하므로 모델이 `k` 를 보는 모든
#         순간 P(OOD)=1 이다. 유료 원장 497행에서 `k` 는 2값뿐이었다(zone 455 · battery 42).
#      ④ 🔴 그리고 `k` 가 일할 유일한 자리 — 어휘 밖의 새 타입 — 에서 정확히 틀린다.
#         `policy.jl:ood_features` 의 `else` 분기가 리터럴 `("fault", nothing)` 이던 탓에
#         `event_kind = fault` 가 찍히고, 바로 아래 `_unfamiliar_block` 이 "어떤 학습된
#         범주에도 못 놓았다" 고 말했다. **한 프롬프트 안의 자기모순이었다.**
#         (그 `else` 는 같은 날 `("unknown", nothing)` 이 됐다 — 하지만 `k` 를 되살릴 이유는
#          안 된다. ①~③ 이 그대로 서 있고, 저 수리는 모순만 없앨 뿐 정보를 안 만든다.)
#    같은 레포의 surrogate 22차원이 정확히 같은 이유로 kind one-hot 을 거부한다
#    (`surrogate_features.py` 헤더). 두 레인의 원칙이 이제 일치한다.
#    게이트: `test_smdp_state_axes.py` (축 이름을 **리터럴로** 들고 있다 — 여기서 유도하면 항진).
#
# ⚠️ 남은 구멍(범위 밖, 별도 결정): `nl` 없는 **폴백 경로**의 `_state_line` 은 여전히
#    `"OOD kind=%s" % r.kind` 를 찍는다. 같은 자기모순이 그 경로에는 남아 있다. 이 삭제는
#    SMDP 블록만 건드렸다 — 폴백은 pre-SMDP 렌더링이고 옛 호출자의 프롬프트를 바꾸는 일이다.
#
# 🔴 여기서 6개 **kind-agnostic 서술자**(harm·work_at_risk·…)를 **대체한다.** 그 여섯은
#    `descriptors_from_row` 가 별도로 다시 계산해 surrogate 레인이 쓰므로(`_surro_row` 는
#    `req.descriptors` 를 안 읽는다) 이 교체는 surrogate 의 입력 행을 한 비트도 안 바꾼다.
#
# 🔴 설명문은 **사실만** 적는다. "그러니 무엇을 하라" 를 적지 말 것 — 프롬프트가 세계에 없는
#    결과를 주장했을 때 완주가 0/8 이었고, 그 문장을 지우자 3/3 이 됐다(2026-09-05 실측).
_SMDP_AXES = [
    ("p", "progress", "progress",
     "fraction of the build's schedule nodes that are already closed"),
    ("b", "smdp_n_broken", "broken_robots",
     "robots currently recorded as broken and not yet replaced"),
    ("v", "spare_count", "spare_robots",
     "spare robots available to be checked out from the depots"),
    ("w", "n_active", "active_nodes",
     "schedule nodes activated right now -- the build's parallel width at this moment"),
    ("c", "smdp_fleet_soc_min", "min_fleet_soc",
     "lowest remaining charge among the active, non-spare robots"),
]


def _smdp_state_rows(r: "MacroRequest"):
    """`(라벨, 값문자열, 설명)` 목록. **못 쟀으면 그 축을 뺀다.**

    삼상 규약: 값이 `None` 인 축은 행이 아예 생기지 않는다. 0 으로 접으면 "재 봤더니 0"
    (고장 로봇 없음)과 "안 쟀다"가 한 값으로 뭉개지고, 프롬프트가 모델에게 거짓말을 한다.
    `n_active`/`spare_count` 의 `-1` 도 policy.jl 의 "못 쟀다" 센티널이므로 같이 뺀다.
    """
    out = []
    for _sym, field, label, doc in _SMDP_AXES:
        v = getattr(r, field, None)
        if v is None:
            continue
        if isinstance(v, str):
            out.append((label, v, doc))
            continue
        if isinstance(v, float) and v != v:          # NaN = 못 쟀다
            continue
        if isinstance(v, (int, float)) and float(v) < 0.0:
            continue                                  # -1 센티널
        out.append((label, ("%.2f" % v) if isinstance(v, float) else str(v), doc))
    return out


def _llm_input(r: MacroRequest) -> str:
    """**LLM 이 실제로 읽는 것.** surrogate 가 읽는 것과 의도적으로 다르다.

    왜 문장인가: `kind=battery, soc=0.55` 같은 파싱된 필드를 주면 순환 논리다 -- 그 필드가
    존재한다는 것 자체가 "이 사건은 이미 아는 3종류 중 하나로 분류됐다"는 뜻이고, 그게 바로
    검증하려는 능력이다. 진짜 새로운 사건에는 soc 열도 zone_overlap 열도 없다.
    (오프라인 실험의 llm_producer.py `nl+state` arm 과 같은 렌더링을 쓴다.)

    nl 이 없으면 예전 동작(_state_line)으로 폴백한다 -- 이 파일을 갱신하는 것만으로
    기존 호출자가 깨지지 않게.

    🔴 블록 함수(`_geometry_block`·`_zones_block`·`_battery_block`·`_unfamiliar_block`)는
    **두 반환 경로 모두**에 붙는다. 한쪽만 붙이면 그 사실이 옛 호출자(nl 없는 요청)의
    프롬프트에서 조용히 사라진다 — 그리고 그 누락은 문자열이 짧아진 것 말고는 아무 증상도 안 낸다.
    """
    if not (r.nl and r.nl.strip()):
        return (_state_line(r) + _geometry_block(r) + _zones_block(r)
                + _battery_block(r) + _unfamiliar_block(r))
    lines = ["OBSERVATION: " + _nl_for_producer(r.nl.strip(), getattr(r, "nl_mode", None))]
    smdp = _smdp_state_rows(r)
    if smdp:
        # 🔴 머리말의 첫 토큰 "MEASURED STATE" 를 **바꾸지 말 것.**
        #    `test_synthesize_multi.py` 의 누수 감시 둘이 `"MEASURED STATE" not in ctx` 로
        #    agent-2/agent-3 컨텍스트를 지킨다. 이름을 갈면 그 감시가 항진명제가 되어
        #    조용히 죽는다(이 레포가 이미 밟은 "닻이 어긋난 대조 시험" 실패 모드).
        lines += ["",
                  "MEASURED STATE (the decision-time state of the world, as measured by the",
                  "monitor; these are raw quantities in their own units, not scores):"]
        for name, val, doc in smdp:
            lines.append("  %-16s = %-8s (%s)" % (name, val, doc))
    return ("\n".join(lines) + _geometry_block(r) + _zones_block(r)
            + _battery_block(r) + _unfamiliar_block(r))


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
    # 🔴 2026-09-23 (존 복구 base ablation 명세 §5, 세 팔 공통): "of which movable" 행을 지웠다 —
    #    그 값은 find_clear_staging_center 가 **푼 답**(해법 정보)이다. 필드는 MacroRequest 에 남는다.
    ("zone_root_covered", "root_goals_trapped",
     "delivery goals of the ROOT assembly inside the zone. These "
     "are placed by a lift that moves the cargo directly, not by a navigating agent"),
    ("zone_work_overlap", "work_discs_overlapped",
     "unfinished work areas the zone intersects"),
    ("zone_teams_forming", "teams_forming",
     "transport teams currently gathering"),
    ("zone_teams_covered", "  of which trapped",
     "of those, how many must gather inside the zone (they cannot form where they stand)"),
    # 🔴 2026-08-29 (spec §1-4, Task T4a): 여기 있던 마지막 한 행을 지웠다 —
    #     ("zone_relocate_norm", "min_shift_to_clear_m",
    #      "smallest rigid translation of the whole build that puts every unfinished goal "
    #      "outside the zone; -1 means no such shift exists"),
    # 그 값은 `_find_min_translation`(`respec/restage_zone.jl`)이 **푼 답**이다. 답을 프롬프트에
    # 실으면 측정되는 것이 추론이 아니라 **프롬프트 준수**가 된다 — 이 파일 위(STEP 4 주석과
    # `_IMPERATIVE` 주석)에 그 실측 선례가 이미 있다: 서술자가 harm=0.02 인데도 "restage 하라"는
    # 문장을 따라간 결정. T2(합성 레인)가 기하 축에서 변위를 유도하기 시작하면 이 누수는 더
    # 세진다(정답 이동량을 그대로 보여주는 셈이라 §5-3 의 P-예측이 무의미해진다).
    # 🔴 **필드 자체는 남긴다** — 위 `MacroRequest.zone_relocate_norm` 은 대리모델 피처이고
    #    `src/decision/core/features_agnostic.py:595` 와
    #    `tools/oracle/gen_oracle_dataset.jl:893` 이 읽는다. 필드를 지우면
    #    무관한 레인이 깨진다. 지운 것은 **프롬프트 렌더 행 하나**뿐이다.
    #    게이트: `test_zone_channel.py::test_the_field_survives_even_though_the_row_is_gone`.
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

# 🔴 2026-09-05. 종단성은 **별도 줄**이다 — `_GEOM_BLOCKAGE` 의 숫자 목록에 섞어 넣으면 또 하나의
# 카운트로 읽히고, 이 결함이 바로 "카운트를 비율로 읽는 것"이었다. 이 줄이 말하는 것은 개수가
# 아니라 **완주 판정이 아직 가능한가**이고, 그 판정의 정의(`project_complete` = 모든
# ProjectComplete 정점이 닫힘)를 같이 적는다. 무엇을 하라는 말은 한 글자도 없다 — 동사도,
# 어휘도, 개입 여부도 언급하지 않는다(위 `_GEOM_COVERAGE` 의 STEP 4 규약 그대로).
def _terminality_line(r: "MacroRequest") -> list:
    if r.zone_project_blocked is None:
        return []                       # 삼상: 안 쟀으면 아무 말도 안 한다(0/no 로 접지 않는다)
    nb, no = r.zone_project_nodes_blocked, r.zone_project_nodes_open
    frac = ("" if (nb is None or no is None) else " (%s of %s)" % (nb, no))
    if r.zone_project_blocked:
        return ["  build_can_still_finish  = NO%s   (the schedule is declared finished only when "
                "every ProjectComplete node closes; those nodes sit behind the blocked nodes "
                "above, so while this zone stands the build cannot reach that state at all -- "
                "this is a reachability fact about the precedence graph, not a fraction of the "
                "work)" % frac]
    return ["  build_can_still_finish  = yes%s  (no ProjectComplete node sits behind a blocked "
            "node, so the blockage above delays work without making the finished state "
            "unreachable)" % frac]


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
        out += _terminality_line(r)
    return "\n".join(out)


# ---- 2026-08-29 (spec §9-1, Task T4a): 살아 있는 구역의 기하 원시값 --------------------------
# `open_zone_descriptors(env)` 가 잰 것을 **사실만** 산문으로 편다. 규약은 위 `_GEOM_COVERAGE`
# 와 같다 — **무엇이 있는가만 적고, 무엇을 하라는 절대 적지 않는다.**
# 🔴 특히 `covers_root` 를 *"루트는 재적치할 수 없으니 빌드 전체를 옮겨라"* 로 번역하지 않는다.
#    그건 오라클의 **판정(verdict)**이지 증거가 아니고, 그렇게 적는 순간 이 태스크가 (A)에서
#    막 지운 누수를 다른 문으로 그대로 들이는 셈이 된다. 판정은 모델이 이 사실들에서 한다.
# ⚠️ 싣는 것은 §9-1 표가 적은 `center · radius · covers` 와 그 root 포함 여부까지다.
#    `max_shift`/`work_reach`/`build_center`/`build_radius` 는 /propose 레인이 Δ 를 유도할 때
#    쓰는 값이고, §1-4 가 **결정 레인**의 유도 입력을 center·radius 까지로 못박으므로 여기서는
#    렌더하지 않는다(필드는 요청에 그대로 남아 있으니 나중에 되살릴 수 있다).
_ZONE_HEADER = "ACTIVE NO-GO ZONES (geometry as measured; one disc per live zone):"


def _zones_block(r: "MacroRequest") -> str:
    """구역이 하나도 없으면 **빈 문자열** — 비공간 사건의 입력이 바이트 단위로 예전과 같다.

    (`open_zone_descriptors` 가 활성 구역이 없을 때 빈 목록을 내므로, 그 경우가 곧 이 경우다.)
    """
    out = ["", _ZONE_HEADER]
    # 항목의 **형태 검사는 여기 없다**: 필드 타입이 `List[Dict[str, Any]]` 이라 pydantic 이
    # 경계에서 이미 거른다(실측: 항목에 문자열을 섞으면 `ValidationError: zones.1 Input should
    # be a valid dictionary`). 여기에 `isinstance` 가드를 또 두면 **도달 불가능한 코드**이고,
    # 그런 가드는 시험이 없는 척 통과해 "막고 있다"는 거짓 안심을 만든다.
    for z in (getattr(r, "zones", None) or []):
        out.append('  zone "%s"' % z.get("key", "?"))
        if z.get("center") is not None:
            out.append("    center            = %s" % (list(z["center"]),))
        if z.get("radius") is not None:
            out.append("    radius            = %s" % z["radius"])
        covers = z.get("covers")
        if covers is not None:
            out.append("    covers            = %d sub-assembl%s whose staging area this disc "
                       "overlaps%s"
                       % (len(covers), "y" if len(covers) == 1 else "ies",
                          (": " + ", ".join(str(c) for c in covers)) if covers else ""))
        if z.get("covers_root") is not None:
            out.append("    root_goals_inside = %s   (delivery goals of the ROOT assembly lie "
                       "inside this disc)" % ("yes" if z["covers_root"] else "no"))
    return "\n".join(out) if len(out) > 2 else ""


# ---- 2026-08-31 (S1/T2): battery 사건의 적재/함대 사실 블록 ---------------------------------
# 규약은 위 `_zones_block` 과 **정확히 같다** — 조건이 아니면 빈 문자열을 낸다. 그래야
# 비-battery 사건(과 이 필드를 안 싣는 옛 호출자)의 프롬프트가 바이트 단위로 예전과 같다.
#
# 🔴 **사실만 적는다.** "더 높은 SoC 로봇에게 넘겨라" 로 번역하지 않는다 — 그것은 오라클의
#    판정이고, 적는 순간 재는 것이 추론이 아니라 프롬프트 준수가 된다(spec §6-2). 같은 이유로
#    `_GEOM_COVERAGE` 도 `covers_root` 를 "빌드를 옮겨라" 로 안 적는다.
# 🔴 2026-09-01 — 아래 두 화물 값의 서술을 **참으로 고쳤다.** 옛 문구("mass of the heaviest
#    cargo" / "sum of cargo mass")는 두 번 과장했다. 실제 산출식은 `battery.jl:211`
#    `p.payload_density * 8.0 * prod(r)` = **밀도 x 경계상자 부피**이고,
#      (a) `prod(r)` 는 화물의 실제 기하가 아니라 **bounding box** 다 -- 과대추정이다.
#      (b) `payload_density = 100.0` 은 물성이 아니라 `# TUNING KNOB`(`battery.jl:72`)이다.
#    그래서 **렌더 라벨의 `_kg` 도 뗐다**(`heaviest_payload_kg` -> `heaviest_payload_proxy`).
#    괄호 안 설명만 고치는 것으로는 부족하다: 모델이 먼저 읽는 것은 설명이 아니라
#    `heaviest_payload_kg = 12.8` 이라는 **이름과 숫자**이고, 거기서 "12.8 킬로그램" 을
#    읽는다. 차원만 보면 kg 이 맞지만(`payload_density` 의 단위가 kg/부피단위),
#    그 100.0 이 손잡이라 **200 으로 바꾸면 모든 "킬로그램" 이 두 배가 되는데 물리적으로는
#    아무것도 안 변한다.** ⟹ 절대값에는 뜻이 없고 **화물 사이의 비율에만** 뜻이 있다.
#    그것이 이 값을 쓰는 유일하게 타당한 방법이라, 이름이 그렇게 말해야 한다.
#    ⚠️ 여기 적은 것은 **산출식과 그 값의 성질(사실)** 이지 "그러니 믿지 마라"(판정)가 아니다.
#    🔴 **와이어 필드명도 같이 바꿨다** (`battery_payload_proxy_max` -> `battery_payload_proxy_max`).
#    모델은 그 이름을 안 보지만, 거짓 이름은 그 값을 읽는 **사람**도 속인다. 이건 언어를
#    건너는 rename 이라 **반쪽으로 끝나면 초록으로 실패한다** -- 줄리아 키만 바뀌면 pydantic
#    이 그 키를 조용히 버리고 필드가 `None` 으로 남아 적재 절이 프롬프트에서 통째로 사라지는데,
#    파이썬 시험은 `MacroRequest` 를 파이썬 이름으로 직접 만들어서 전부 초록이다.
#    ⟹ `test_battery_block.py::test_every_battery_key_julia_emits_has_a_python_field` 를
#    **먼저 걸고**(반쪽 rename 에 RED 인 것을 실측) 그 다음에 바꿨다.
_BAT_LOAD = [
    ("battery_pending_transports", "pending_transports",
     "unfinished transport jobs this robot is committed to"),
    ("battery_payload_proxy_max", "heaviest_payload_proxy",
     "largest cargo among them, as density x bounding-box volume -- the density is a "
     "fixed model constant, so this number has no physical unit and only its ratio to "
     "the other cargo figures here carries information"),
    ("battery_payload_proxy_total", "total_payload_proxy",
     "that same proxy summed over those jobs"),
]
# 🔴 `soc` 는 **여기 없다.** battery 사건이면 그 필드가 언제나 실려 있어서, 이 목록에 넣으면
#    "값이 하나도 없으면 빈 문자열" 규약이 깨진다(블록이 항상 렌더된다). `soc` 는 아래에서
#    함대 절이 실제로 생길 때만 **머리 줄로** 붙인다 — 비교 대상(중앙값)이 있어야 뜻이 있는 값이다.
_BAT_FLEET = [
    ("battery_fleet_soc_median", "fleet_soc_median",
     "median charge across the robots the monitor is accounting for"),
    ("battery_higher_soc_robots", "robots_with_higher_soc",
     "active robots whose charge is above this robot's"),
]


def _battery_block(r: "MacroRequest") -> str:
    load = _rows(r, _BAT_LOAD)
    fleet = _rows(r, _BAT_FLEET)
    if not load and not fleet:
        return ""
    out = []
    if load:
        out += ["", "THIS ROBOT'S REMAINING TRANSPORT LOAD (measured):"]
        for lbl, v, doc in load:
            out.append("  %-22s = %-6s (%s)" % (lbl, v, doc))
    if fleet:
        out += ["", "FLEET STATE OF CHARGE (measured):"]
        if getattr(r, "soc", None) is not None:
            out.append("  %-22s = %-6s (%s)"
                       % ("this_robot_soc", r.soc, "this robot's remaining charge"))
        for lbl, v, doc in fleet:
            out.append("  %-22s = %-6s (%s)" % (lbl, v, doc))
    return "\n".join(out)


# ---- 2026-08-29 (§A-1): 라우터의 낯섦 판정을 프롬프트에 싣는다 -------------------------------
def _unfamiliar_block(r: MacroRequest) -> str:
    """라우터가 이 사건을 어떤 학습된 kind 로도 못 놓았다는 **사실**을 프롬프트에 싣는다.

    🔴 왜 필요한가 (2026-08-29, §A-1). 라우터는 `routing_kind` 가 `"unknown:"` 으로 시작하면
    이 사건을 LLM 으로 보낸다. 그런데 그 판정이 페이로드에 안 실려서, 모델은 자기가 처음 보는
    사건을 받았다는 것을 모른 채 위의 파싱된 필드(= 가장 가까운 알려진 스키마로의 투영)를
    사실로 읽었다. `Replace`(로봇 교체)는 빔 붕괴·측위 상실과 아무 상관이 없는데 그것이
    메뉴의 유일한 개입 팔이다.

    🔴 여기에 **지시절을 적지 않는다**(Global Constraint 5). 무엇을 할지는 모델이 정하고,
    어휘가 모자라면 `expressible=false` 로 신고한다.

    ────────────────────────────────────────────────────────────────────────────────
    🔴 2026-08-30 — 이 블록이 하던 **거짓 주장 둘을 지웠다.** 실측으로 반증됐다.
    ────────────────────────────────────────────────────────────────────────────────
    옛 본문은 사실 셋을 주장했다. 첫째만 참이었다.

      ① "학습된 어떤 범주에도 못 놓았다"                                    → **참**. 남긴다.
      ② "raw feature row 를 **가장 가까운** 알려진 스키마로 **접었다**"     → **거짓**.
      ③ "후보 목록이 그 투영에서 만들어졌다"                                 → **거짓**.

    ② 가 왜 거짓인가. 유사도 계산이 **어디에도 없다.** 접히는 것은 feature row 가 아니라
      `kind` **문자열**이고, 그것도 `policy.jl:ood_features` 의 `if/elseif` 사슬 마지막
      `else` 가 리터럴 `("fault", nothing)` 을 쓰던 것뿐이다 — "가장 가까워서" 가 아니라
      "사슬 끝이라서" 였다. 🔴 2026-09-07: 그 `else` 는 이제 `("unknown", nothing)` 이라
      **접히지도 않는다.** 미지 타입은 자기가 미지라고 말한다. 그리고 숫자 서술자는 애초에
      투영되지 않는다:
      `features_agnostic.descriptors_from_row` 가 **`row['kind']` 를 절대 읽지 않고**
      (그 함수의 계약 문구 그대로) 어떤 필드가 유한한지로만 갈린다. 미지 타입에서 일어나는
      일은 투영이 아니라 **종류별 측정값이 없는 것**이고, 그때 `severity` 는 재는 대신
      상수 `1.0` 이 박힌다(`policy.jl` 의 `else` 분기).
      🔴 그리고 2026-08-30 부터 `"unknown:"` 을 다는 사건이 셋으로 늘었는데
      (`battery_mild` · `zone` · 미지 타입) **앞의 둘은 접히지도 않는다** — 자기 분기를 타서
      `soc`/`zone_overlap` 이 실제 측정값으로 실린다. 옛 문구를 그대로 뒀으면 그 둘의
      프롬프트가 모델에게 거짓말을 했을 것이다.

    ③ 이 왜 거짓인가. 메뉴는 `kind` 에서 안 나온다. 줄리아의 `valid_macros(env, truth)` 가
      **그 순간 실제로 실행 가능한 매크로**를 세계에서 계산해 `payload["valid"]` 로 싣고,
      `_valid_for` 가 그것을 우선한다(`VALID.get(req.kind, ...)` 는 그 키가 없을 때의 폴백).

    ⟹ 오늘 싣는 것은 **항상 참인 한 문장** + **조건이 맞을 때만 붙는 한 문장**이다.
      조건은 `soc` 와 `zone_overlap` 이 **둘 다 없는 것** = 종류별 측정값이 하나도 없는 행
      = `ood_features` 의 `else` 분기를 탄 행. 새 키가 필요 없다(페이로드에서 바로 읽힌다).
      🔴 fault 행도 그 둘이 비지만, fault 는 `"unknown:"` 을 달지 않으므로 이 블록에
      도달하지 않는다 — 위 조기 반환이 그것을 보장한다.

    🔴 **왜 "the parsed fields above" 라고 안 쓰는가** (2026-08-29 fix round 1): `nl` 경로에서
    이 블록 **바로 위**에 서는 것은 서술자 블록이고, 그 머리말은 스스로
    *"computed by the monitor **without classifying the event** … means the same thing for any
    kind of disruption"* 이라고 적는다(`_llm_input` 의 "MEASURED STATE" 머리말 -- 🔴 줄번호로
    인용하지 않는다, 이 레포는 그 인용이 조용히 썩는 것을 반복해 겪었다).
    위치("above")로 가리키면 같은 프롬프트가 같은 줄에 대해 정반대 주장을 둘 하게 된다.
    그래서 아래 둘째 문장도 위치가 아니라 **무엇이 없는가**를 이름 붙인다.

    규약은 `_zones_block` 과 **정확히 같다**: 조건이 아니면 **빈 문자열**을 낸다 —
    알려진 kind 사건(과 이 필드를 안 싣는 옛 호출자)의 프롬프트는 바이트 단위로 예전과 같다.
    """
    rk = getattr(r, "routing_kind", None)
    # 🔴 2026-09-29 (selfimprove U1): zone 의 routing_kind 가 접두사 없는 `"zone"` 이 됐다. 접두사
    #    만 보면 v0 zone 프롬프트에서 이 문단이 빠진다. 그래서 "접두사 **또는** 서비스가 실제로 그
    #    kind 를 학습하지 않았다" 로 판정한다 — 학습 전 zone 은 예전과 바이트 동일, 학습 뒤(DEFER
    #    로 LLM 에 온 zone)에는 이 문단이 거짓이 되므로 빠진다. 지원집합을 못 쟀으면(None)
    #    낯섦을 주장하지 않는다.
    kinds = _state.get("surro_kinds")
    if not (rk and (rk.startswith("unknown:") or (kinds is not None and rk not in kinds))):
        return ""
    label = rk[len("unknown:"):] if rk.startswith("unknown:") else rk
    block = ("\n\nUNFAMILIAR EVENT: the router could not place this disruption in any event "
             "category the surrogate was trained on (its routing label is %r)."
             % label)
    # 종류별 측정값이 하나도 없는 행 = `ood_features` 의 `else` 분기를 탄 행. 그 행의
    # severity 는 잰 값이 아니라 상수다 — 모델이 그것을 측정으로 읽으면 안 된다.
    if getattr(r, "soc", None) is None and getattr(r, "zone_overlap", None) is None:
        block += (" No category-specific measurement was recorded for it -- neither state of "
                  "charge nor zone overlap -- so its severity is a placeholder rather than "
                  "something the monitor measured.")
    return block


@app.get("/health")
def health():
    return {"status": "ok", "policy": "dspy:%s" % MODEL,
            "program": os.path.basename(PROGRAM) if os.path.exists(PROGRAM) else "(seed only)",
            "demos": _state["demos"], "calls": _state["calls"],
            # calls 는 요청 수(캐시 히트 포함), billed 가 실제 과금 호출 수다. 둘을 한
            # 이름으로 뭉치면 캐시 재생이 라이브 유료 측정처럼 보인다.
            "cache": CACHE, "billed": _state["billed"],
            # 🔴 [2026-09-04] 트랜스포트 레짐. `cache` 와 같은 이유로 싣는다 — 이 프로세스는
            #    오래 살고 환경변수는 재시작 때만 읽히므로, 어느 엔드포인트로 나가는지는
            #    **산출물이 스스로 말해야** 한다. `model_type == "chat"` 인데 모델이 5.x 추론
            #    계열이면 native FC 요청이 전부 BadRequest 로 죽는다는 뜻이다.
            "model_type": MODEL_TYPE, "temperature": TEMPERATURE,
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
            # 축(2026-08-29 T9): kind 색인 라우터의 **유일한** 판정 입력.
            # None = 못 쟀다 — 그때 `select_lane` 은 고르지 않고 **죽는다**(§0-C 결정 3).
            # [] 는 "쟀는데 비었다" 로 다른 사건이다(삼상 규약, `surro_support` 와 같다).
            "surro_kinds": (None if _state.get("surro_kinds") is None
                            else sorted(_state["surro_kinds"])),
            # selfimprove 버전 신원 (spec §5.4 규칙 6). 버전 없이 뜨면 None.
            "agent_version": _state.get("agent_version"),
            "manifest_sha256": _state.get("manifest_sha256"),
            "model_probe_sha256": _state.get("model_probe_sha256"),
            "surro_tau": SURRO_TAU, "surro_rule": SURRO_RULE,
            # ---- 세대 도장 (2026-09-03) ------------------------------------------------
            # 🔴 왜: 08-30/08-31 기동 uvicorn 다섯이 사흘째 200 을 냈고 그중 어느 것도
            #    `synthesize_multi`(09-02 도입)를 안 갖고 있었다. 둘은 cwd 가 삭제된
            #    worktree 였다. `/health` 200 이 세대 증거가 아니었기 때문에 그 위에서 잰
            #    "합성이 안 터진다" 가 모델에 대한 사실로 읽혔다.
            # `code_fingerprint`: 임포트 시점에 **얼린** 값. `None` = 자기 소스를 못 읽는다.
            "source_dir": SOURCE_DIR,
            "code_fingerprint": CODE_FINGERPRINT,
            # 🔴 raw env echo 가 **아니다** — 둘 다 리터럴 `"1"` 만 참으로 읽는다
            #    (`true`/`TRUE`/`on` 은 전부 OFF). raw 를 실으면 판독자가
            #    `SYNTH_MULTI_AGENT=true` 인 서비스를 "켜짐" 으로 읽는다.
            # ⚠️ 2026-09-03. 둘의 **의미가 갈렸다.** `synth_tool_synthesis` 는 레인이 실제로
            #    부르는 함수의 값이지만, `synth_multi_agent` 는 이제 **어느 레인도 안 읽는
            #    세대 도장**이다(위 `_synth_multi_agent_stamp` 의 판정 R-FLAG 주석).
            #    호출 시점에 잰다 — 앞엣것은 레인도 호출 시점에 읽기 때문이다.
            "synth_tool_synthesis": synthesis_enabled(),
            "synth_multi_agent": _synth_multi_agent_stamp(),
            # 🔴 2026-09-22 (global-constraints.md "Task 3, 원장 신뢰성"). 이 프로세스가 잃은
            #    원장 행 수. append 는 결정을 지키려고 **안 던지므로**, 이 값이 0 이 아닌 판의
            #    원장은 불완전하다 — 측정 게이트는 이 값을 읽고 실패해야 한다.
            "ledger_append_failures": _ledger_append_failures(),
            # 🔴 존 복구 base ablation(2026-09-23): 이 서비스가 실제로 기동한 레벨. Julia 는
            #    기동 때 /health 로 먼저 막는다(policy.jl assert_service_repair_ablation);
            #    campaign.py 의 SERVICE_KEYS 도 이 키로 재기동 드리프트를 잡는다.
            "repair_ablation": REPAIR_ABLATION,
            "policies": ["dspy", "surrogate"]}


# ---- tool 레인 (Plan A, Task 6) --------------------------------------------------------------
# 🔴 이 세 이름은 `SelectTool` 의 필드명과 **같아야 한다.** `Signature.delete` 는 없는 이름에
#    에러를 내지 않으므로(`dspy/signatures/signature.py:446`, `fields.pop(name, None)`), 갈리면
#    아래 두 축약이 조용히 아무것도 안 지운다 — C8 축약은 `KeyError: 'tools'`(아래 참조)를
#    도로 열고, §4-1 구제는 같은 파싱 실패를 그대로 다시 밟는다. **둘 다 에러가 안 난다.**
#    게이트: test_macro_returns_tool_call.py::test_the_stripped_field_names_are_real_fields...
# 🔴 이 두 이름은 `SelectTool` 의 필드명과 **같아야 한다.** `Signature.delete` 는 없는 이름에
#    에러를 내지 않으므로(`dspy/signatures/signature.py:446`, `fields.pop(name, None)`), 갈리면
#    축약이 조용히 아무것도 안 지운다.
#    🔴 2026-08-29: `_EXPR` 를 없앴다 — `expressible` 은 이제 시그니처 필드가 아니라 tool
#    인자다. 남겨 두면 `delete(_EXPR)` 가 조용히 no-op 이 되어 "지웠다" 는 거짓을 만든다.
_FC_IN, _FC_OUT = "tools", "action"

# ---- tool_choice 손잡이 (Plan B, 2026-08-29) -------------------------------------------------
# 🔴 왜 생겼나 (실측, 2026-08-28 유료 스윕). tool 을 내밀고 native FC 가 **진짜로** 켜진 판에서
#    gpt-4o 는 tool 을 **안 부르고** 텍스트로 답했다. 두 사건 종류에서 두 번 잰 값:
#      fault  : tools_offered=2 · native_fc=True · tool_called=None · tool_calls_n=0 · 오류 없음
#      battery: tools_offered=3 · native_fc=True · tool_called=None · tool_calls_n=0 · 오류 없음
#    유력한 설명은 **아무것도 부르라고 압박하지 않았다**는 것이다 — 이 레인은 `tool_choice` 를
#    한 번도 안 보냈다. 설계 근거: 모든 실패는 tool 로 끝난다(익숙한 실패는 있는 tool, 낯선
#    실패는 새로 주조된 tool). 그러므로 호출을 요구하는 것이 설계와 어긋나지 않는다.
#
# 🔴 이것이 `strict` 가 **아님**을 분명히 해 둔다. `dspy.Tool` 에는 `strict` 필드가 없다
#    (모델 필드는 정확히 `arg_desc · arg_types · args · desc · func · has_kwargs · name`).
#    즉 이 손잡이가 강제하는 것은 **호출 여부**이지 인자 스키마 준수가 아니다.
#
# 🔴 전달 경로 (설치된 라이브러리에서 실측한 것이지 추정이 아니다):
#      `prog(config={"tool_choice": ...})` -> `predict.py:_forward_preprocess` 의
#      `config = {**self.config, **kwargs.pop("config", {})}` -> `predict.py:forward` 의
#      `adapter(lm, lm_kwargs=config, ...)` -> `adapters/base.py:_call_preprocess`
#      -> `adapters/base.py:_render_request` -> `LMRequest.from_call(**lm_kwargs)`
#      -> `clients/openai_format.py:81-82` 의 `to_openai_chat_request`.
#    ⚠️ **반드시 `config=` 로 넘긴다.** 맨 kwarg(`prog(tool_choice=...)`)로 주면 dspy 가
#      "시그니처에 없는 입력 필드" 로 보고 **경고 한 줄 내고 조용히 버린다**
#      (`predict.py:191-198`). 프로바이더에는 아무것도 안 간다.
#    ⚠️ 어댑터는 native FC 가 켜진 분기에서 `tool_choice` 를 **넣지도 지우지도 않는다** —
#      `adapters/base.py:97` 의 pop 루프는 `if not self.use_native_function_calling:` 안에만
#      있다. 그래서 호출자가 실은 값이 프로바이더까지 살아서 간다.
#
# 🔴 **tool 이 0개일 때는 절대 보내면 안 된다.** `clients/openai_format.py` 는 `tool_choice`
#    를 `:81` 에서 싣는데 그것이 `tools` 를 싣는 `:83` 의 `if request.tools:` 와 **무관하다.**
#    즉 tool 없는 요청에 `tool_choice="required"` 를 실으면 그대로 프로바이더로 나가 400 이
#    된다. 그래서 아래 `_ask` 는 `if tools:` 안에서만 이 값을 싣는다.
#    🔴 2026-08-29 (T4): 그 방어는 이제 **두 겹**이다 — `macro()` 가 tool 0개인 요청에서
#    LM 을 아예 안 부른다(`decision_source="no_tools"`). 이 `if tools:` 는 남겨 둔다:
#    `_ask` 는 `macro()` 말고도 불릴 수 있고, 400 을 막는 마지막 줄이 한 함수 안에 있는 편이
#    낫다. (예전에 이 자리가 제외하던 두 호출 — C8 축약과 §4-1 구제 — 은 둘 다 사라졌다.)
TOOL_CHOICE_ENV = "DSPY_TOOL_CHOICE"
# 🔴 2026-08-29 (Plan B / T-C): `"required"` 였다. **무조건 강제는 실측으로 반증됐다.**
#    컨트롤러가 같은 요청·같은 빌드로 `DSPY_TOOL_CHOICE` 만 갈라 유료 2콜을 냈고, `required`
#    판에서 프로바이더가 tool 호출만 내고 message content 를 **비웠다**:
#      chosen  Replace -> NOOP (`coerced=True`) · reasoning 180자+ -> `""`
#      expressible  true -> null · tool_called  null -> "no_intervention"
#      error / tool_lane_error 는 **양쪽 다 null** — 예외가 안 난다.
#    즉 텍스트 OutputField 전부가 빈 채로 파싱되고, spec §4-1 의 `AdapterParseError` 구제는
#    **발화조차 하지 않는다.** 모델이 마음을 바꾼 게 아니라 **채널이 없다.**
#    ⟹ 기본값은 `None`(안 보냄)이고, 강제는 **요청이 사건마다 정한다**(`MacroRequest.tool_choice`,
#      유도는 `policy.jl` 의 `tool_choice_for`).
#
# 🔴 2026-08-29 (T4) 정정 — **위 문단의 마지막 줄이 폐기됐다.** 거기 적혀 있던 *"강제한
#    사건에서 텍스트 채널이 무너지면 `macro()` 의 텍스트 구제가 두 번째 호출로 그것을
#    되찾는다(`text_rescue`)"* 는 이제 거짓이다: T3 이 텍스트 `OutputField` 다섯을 전부
#    지웠으므로 **되찾을 채널 자체가 없고**, 구제 코드와 `text_rescue` 키를 T4 가 지웠다.
#    위 실측이 보고한 붕괴는 여전히 참이지만, 그 대응이 "2차 호출로 되찾기" 에서 "결정
#    성분을 애초에 tool 인자로 받기" 로 바뀌었다(`tool_registry.COMMON_ARGS`).
#
# 🔴 2026-08-29 (T5): 기본값이 `None` 에서 **`"required"` 로 되돌아갔다.** 반증됐던 것은
#    "무조건 강제" 자체가 아니라 **텍스트 채널을 죽이면서 강제하는 것**이었고, T3 이 그 채널을
#    없애 인과를 끊었다(위 실측의 `chosen`·`reasoning`·`expressible` 붕괴는 전부 텍스트
#    `OutputField` 의 사건이다 — 그 필드들이 이제 없다).
#    되돌리는 근거(실측, F3): 강제 없이 tool 호출률이 **0/3** 이었고, 프롬프트에 호출 지시를
#    넣어도 · 텍스트 출력 필드를 전부 없애도 · 행위자 프레이밍을 지시문 맨 앞에 놔도 전부
#    0/3 이었다. 양성 대조(산술 과제)는 tool 3개에도 부른다 — 배선이 아니라 **과제의 성질**이라
#    프롬프트로 대체 불가능하다.
#    ⟹ 요청(`MacroRequest.tool_choice`)은 여전히 사건마다 다른 값을 실을 수 있고, 환경변수는
#      여전히 양방향 킬스위치다. 바뀐 것은 **둘 다 없을 때**의 값 하나뿐이다.
TOOL_CHOICE_DEFAULT = "required"
# 🔴 허용 집합. **이 목록은 우리가 정한 정책이 아니라 프로바이더 스펙의 사본이다** —
#    `openai/types/chat/chat_completion_tool_choice_option_param.py:15` 의
#    `Literal["none", "auto", "required"]`, 그리고 dspy 가 그것을 그대로 물려받은
#    `dspy/core/types.py:327` 의 `mode` (+ `ConfigDict(extra="forbid")`).
#    ⚠️ 여기만 늘리면 통과시킨 값이 dspy 나 프로바이더에서 죽는다. 그래서
#    `test_the_allowed_set_matches_what_the_provider_accepts` 가 이 목록을 dspy 에 직접
#    태워 두 쪽이 갈리지 않는지 감시한다.
#    🔴 `""` 는 여기 없다 — 그건 "값"이 아니라 **"키를 안 보낸다"** 이고, 아래 `tool_choice()`
#      가 `None` 으로 접는다. 두 사건을 같은 자리에 두면 킬스위치의 OFF 방향이 사라진다.
TOOL_CHOICE_ALLOWED = ("auto", "required", "none")


def tool_choice(req=None):
    """이 요청에 실을 `tool_choice` 값. `None` 이면 **그 키를 아예 안 보낸다.**

    **우선순위는 환경변수 > 요청 > 기본값이다.**
    🔴 2026-08-29 (T12 정정): 이 docstring 은 기본값을 `None` 이라 적고 있었다. **거짓이다** —
    T5 가 `TOOL_CHOICE_DEFAULT` 를 `"required"` 로 세웠고(위 `:1096`) 문서만 안 고쳤다.
    현행 기본값은 **`"required"`**: 환경변수도 요청도 값을 안 정하면 **강제된다.**

      · `os.environ[TOOL_CHOICE_ENV]` 가 **존재하면** 그 값이 이긴다 — 요청이 무엇을 실었든.
        사람이 잡는 **양방향 킬스위치**라 그렇다: `""` 면 `None`(키 자체를 안 보냄 =
        2026-08-29 이전과 바이트 동일), `"required"` 면 라우터가 뭐라 했든 전부 강제.
        ⚠️ 판정은 `os.environ.get(...) is not None` 이지 truthiness 가 **아니다** — 빈
        문자열은 "안 걸었다" 가 아니라 "끄라고 걸었다" 이고, 그 둘을 접으면 킬스위치의 OFF
        방향이 사라진다.
      · 환경변수가 **아예 없으면** `req.tool_choice` 를 쓴다. 그 값은 호출자가 사건마다
        계산한 것이다(`policy.jl` 의 `tool_choice_for` — novelty 를 **실제로 재서** familiar
        인 사건에만 `"required"`).
      · 둘 다 없으면 `TOOL_CHOICE_DEFAULT` = **`"required"`** = 강제한다.
        🔴 이 줄은 `= None = 안 보낸다` 라고 적혀 있었다(T5 가 상수만 바꿨다). 그 문구를 믿고
        "요청이 키를 안 실으면 예전과 같다" 로 읽으면 틀린다 — 그 등가는 T5 에 깨졌고, 그것이
        `policy.jl` 의 라우터 게이팅을 죽인 이유다(§0-B ⑯).

    🔴 되돌리는 법(비교 판을 돌리는 법)은 **로직 편집이 아니라 환경변수 하나다** — 이 문단은
    기본값이 `"required"` 인 지금도 참이다. `DSPY_TOOL_CHOICE=""` 로 두면
    호출자가 무엇을 실어 보내든 2026-08-29 이전과 **바이트 단위로 같은 요청**이 나간다(키
    자체가 없다). 달라진 것은 그 환경변수를 **안 걸었을 때의 동작**이다: 예전에는 무조건
    `"required"` 였고 지금은 **요청이 정한다.**
    `DSPY_TOOL_CHOICE=auto` 는 `""` 와 다르다 — 프로바이더 기본값과 의미는 같아도 요청에 키가
    실리고, 그 사실이 응답의 `tool_choice` 에 남아 두 판이 구별된다.
    ⚠️ 그리고 아래 "예전에는 무조건 required 였고 지금은 요청이 정한다" 는 **더는 정확하지
    않다**: 요청이 아무 말도 안 하면 기본값이 다시 `"required"` 다. 요청이 정할 수 있는 것은
    `"auto"`/`"none"` 으로 **낮추는** 방향뿐이다.

    호출 시점에 읽는다(모듈 상수로 굳히지 않는다) — `synthesize.synthesis_enabled()` 와 같은
    규약이라 시험이 monkeypatch 로 두 레짐을 다 돌릴 수 있다.
    """
    v = os.environ.get(TOOL_CHOICE_ENV)
    src = TOOL_CHOICE_ENV
    if v is None:
        v, src = getattr(req, "tool_choice", None), "MacroRequest.tool_choice"
        if v is None:
            v = TOOL_CHOICE_DEFAULT
    v = (v.strip() or None) if isinstance(v, str) else None
    # 🔴 오설정을 **여기서** 죽인다. 안 죽이면 값은 dspy 의 닫힌 enum 까지 흘러가
    #    `LMRequest.from_call` 안에서 pydantic `ValidationError` 가 되고, 그것은
    #    `AdapterParseError` 가 **아니므로** `macro()` 의 포괄 except 로 떨어져 `error` 가 된다.
    #    그러면 `policy.jl:1301` 의 `policy_entry` 가 `err !== nothing` 을 보고 레인을 통째로
    #    `available=false` 로 버린다 — **tool 하나가 아니라 결정 전체가 매 사건 사라지고,**
    #    이 레포의 스윕 도구는 per-decision `error` 를 안 읽으므로 아무도 그 말을 안 해 준다.
    #    오타 하나가 조용한 전면 폴백이 되는 자리라 시끄러운 쪽을 고른다.
    if v is not None and v not in TOOL_CHOICE_ALLOWED:
        raise ValueError(
            "%s=%r is not a legal tool_choice. Allowed: %s. "
            "To send nothing at all (byte-identical to the pre-2026-08-29 request) use \"\"."
            % (src, v, ", ".join(repr(a) for a in TOOL_CHOICE_ALLOWED)))
    return v


def _first_tool_call(action):
    """`dspy.ToolCalls` 에서 (이름, 인자, 개수) 를 꺼낸다. 안 불렀으면 (None, {}, 0).

    하나만 본다 — 이 레인의 결정은 사건당 행동 하나다. 여럿 오면 첫 번째만 쓰고 나머지는
    버리되, 개수를 함께 돌려줘 응답의 `tool_calls_n` 에 남긴다(조용히 버리지 않는다).
    """
    calls = list(getattr(action, "tool_calls", None) or [])
    if not calls:
        return None, {}, 0
    c = calls[0]
    return getattr(c, "name", None), dict(getattr(c, "args", None) or {}), len(calls)


def _ask(prog, sig, line, valid, tools, choice=None):
    """프로그램을 한 번 부른다.

    🔴 `tools` 가 비면 그 kwarg 를 **아예 안 넘긴다**(C8). `signature` 는 dspy 의 특권 kwarg 라
    (`predict.py:144`) 이 한 번의 호출에만 적용되고 `prog.signature` 는 안 건드린다.
    """
    kw = {"signature": sig, "state": line, "valid_actions": ", ".join(valid)}
    if tools:
        kw[_FC_IN] = tools
        # 🔴 `tools` 가 있을 때만. 위 `TOOL_CHOICE_ENV` 주석의 마지막 문단이 이유다 —
        #    tool 0개 + `tool_choice` 는 프로바이더 400 이다. `config=` 여야 도달한다.
        if choice:
            # 🔴 F11 (2026-08-29, T5). `parallel_tool_calls=False` 를 **`tool_choice` 와 같은
            #    조건 아래** 싣는다. 계획서는 이것을 `build_adapter()` 에 걸라고 했는데
            #    **실측으로 반증됐다**: dspy 3.3.0 은 두 손잡이를 프로바이더 경계에서 한 객체로
            #    접는다 — `core/types.py:538-542` 가 둘 중 **하나만 있어도**
            #    `LMToolChoice.from_value(...)` 를 만들고, `clients/openai_format.py:396-398` 이
            #    `{"tool_choice": choice.mode}` 를 먼저 깐 뒤 `parallel` 을 얹는다.
            #    ⟹ `parallel_tool_calls` 만 실으면 dspy 가 `tool_choice: "auto"` 를 **지어낸다**
            #      (실측: `parallel=False 만 -> {"tool_choice":"auto","parallel_tool_calls":false}`).
            #    어댑터에 걸면 그 값이 모든 요청에 실리므로 `DSPY_TOOL_CHOICE=""` 킬스위치가
            #    **2026-08-29 이전과 바이트 동일한 요청을 못 낸다** — 그 손잡이의 존재 이유가
            #    A/B 비교판이고, 기준선이 조용히 다른 세계가 되는 것이 이 레포의 상습 실패다.
            #    (실측: 어댑터에 건 판에서 이 파일의 계약 넷이 빨개진다.)
            # ⚠️ `tool_calls_n` 은 **그대로 잰다.** 프로바이더가 이 플래그를 안 지킬 수 있고,
            #    그때 조용해지면 안 된다 — 그리고 그 값은 F8 의 판별키이기도 하다.
            # 게이트: test_tool_choice_forced.py::test_the_two_knobs_are_decided_in_one_place
            #        (구조) · ::test_parallel_tool_calls_reaches_the_provider_request (도달)
            #        · ::test_turning_the_knob_off_sends_neither_key (킬스위치 OFF 방향)
            kw["config"] = {"tool_choice": choice, "parallel_tool_calls": False}
    pred = prog(**kw)
    _state["calls"] += 1                    # 요청 수(캐시 히트 포함) -- 과금 수가 아니다
    if _was_billed():
        _state["billed"] += 1
    return pred


# ---- 단일 채널 조립 (2026-08-29, T4) ----------------------------------------------------------
# 🔴 줄리아 `TOOL_PARAM_SCHEMA`(`src/respec/llm_bridge.jl:148-151`)가 선언하는 인자 이름 전부.
#    `tool_args` 로 나가는 것은 **이 집합뿐이다** — 공통 인자가 섞이면 `ground_tool_args` 가
#    `reject:off_schema_param` 을 내고 집행이 전 사건에서 멈춘다(F9).
#    교차 게이트: test_macro_returns_tool_call.py::test_the_python_and_julia_param_schemas_agree
#
# ⚠️ **이 집합은 `check_tool_args` 의 `want` 와 같은 것이 아니다.** 저쪽은 다섯 키(고유 인자 +
#    공통 인자 넷)를 기준집합으로 `off_schema_args` 를 판정한다 — 모델이 **보내도 되는** 것의
#    목록이다. 이쪽은 줄리아로 **나가도 되는** 것의 목록이다. 두 검증기는 "off-schema" 의 뜻에
#    대해 설계상 영원히 불일치하고, 그건 결함이 아니라 방향이 다른 두 경계다. 한 게이트로 읽지
#    말 것(계획서 §0-B ⑥).
_GROUNDING_ARGS = frozenset(("agent", "reason"))


def _blank_decision(valid, line, source, tools_offered):
    """결정을 못 낸 사건의 응답. `error` 는 **비운다** — 장애가 아니다.

    🔴 `chosen=""` 이면 `policy.jl` 의 `policy_entry` 가 `available=false` 로 떨어뜨려
    canonical 폴백이 선다. 그 경로는 이미 있고, 여기서 하는 일은 **왜 그렇게 됐는지**를
    `decision_source` 로 남기는 것뿐이다.

    🔴 호출자가 `error` / `tool_lane_error` / `tool_calls_n` 을 **덮어쓴다.** 그 셋이
    `no_call` 안의 세 사건을 가르는 유일한 키다(아래 `macro()` 의 같은 이름 주석).
    """
    _blank = blank_synthesis_record(kind=None, expressible=None)
    return {"policy": "dspy:%s" % MODEL, "chosen": "", "ranking": list(valid),
            "margin": None, "reasoning": "", "valid": valid, "coerced": False,
            "state": line, "llm_calls": _state["calls"],
            "cache": CACHE, "llm_billed": _state["billed"], "error": None,
            "decision_source": source,
            "tool_called": None, "tool_args": {},
            "tool_called_forced": None, "tool_args_forced": {},
            "tool_calls_n": 0, "tools_offered": tools_offered, "tool_arg_error": None,
            "expressible": None, "menu_expressible": None, "macro_tool_agree": None,
            "native_fc": None, "tool_choice": None, "tool_lane_error": None,
            # 🔴 합성 레인은 `expressible == False` 하나로만 발화한다. 여기서는 그것을 **못
            #    쟀으므로**(None) 부르지만 안 돈다 — 그 사실이 `synthesis["reason"]` 에 남는다.
            #    상수 dict 을 지어 두지 않는 이유: 그러면 그 상수와 `synthesize.py` 의
            #    `blank_synthesis_record` 반환 모양이 조용히 갈릴 수 있다(이 레포가 반복해
            #    밟은 두 벌 문제). 빈 기록의 **모양**은 진실원이 하나다.
            "tool_minted": _blank["tool_minted"], "synthesis": _blank}


def _macro_decision(req: MacroRequest, raw: Dict[str, Any]):
    """한 번의 tool 호출에서 결정의 **모든 성분**을 꺼낸다 (2026-08-29, 단일 채널).

    ✅ 2026-09-22: 엔드포인트는 아래 `macro()` 이고 이 함수는 그 본체다. 원장 행은 여기서
       안 쓴다 — `macro()` 가 **모든** 출구(조기 반환·예외 포함)에서 한 줄을 쓴다. `raw` 는
       합성 단계가 채우는 요청 국소 원시 응답이다(조기 반환에서는 빈 채로 남는다).

    🔴 이 함수가 T3 이전과 갈리는 지점 셋:
      ① 텍스트 `OutputField` 가 없다. `reasoning`·`expressible`·`macro`·`ranking` 은 전부
         tool **인자**로 온다(`tool_registry.COMMON_ARGS`). 그러므로 `text_rescue`(2차 호출로
         텍스트 채널을 되찾던 것)는 **되찾을 채널이 없어서** 사라졌다 — 키까지 사라진다.
      ② `chosen` 은 tool **이름**에서 나온다(`TOOL_TO_MACRO`). `enact_target` 이 읽는 값과
         정의상 같으므로 집행과 채점이 갈릴 수 없다(F5 — 실측 3/3 갈렸었다).
      ③ 결정을 못 낸 사건에 **이름이 붙는다**(`decision_source`): `no_tools`(우리가 메뉴를 못
         만들었다) · `no_call`(프로바이더가 `required` 계약을 어겼다). 둘을 접지 않는다.
    """
    valid = _valid_for(req)
    prog = _state["program"] or _load_program()
    line = _llm_input(req)          # 문장(있으면) / 없으면 예전처럼 파싱된 필드
    # 🔴 `req.valid` 가 아니라 **해소된 메뉴**(`valid`)를 넘긴다. `req.valid` 는 fault 사건에서
    #    언제나 None 이다 — `policy.jl:553-554` 가 `valid_macros` 의 결과가 비면 payload 에 키를
    #    안 싣고, `valid_macros`(`policy.jl:362`)는 Battery/Zone 이 아닌 truth 에 `String[]` 을
    #    낸다. 날것을 주면 **모든 fault 사건에서 tool 레인이 조용히 꺼진다**.
    agent_ids = [a["id"] for a in (getattr(req, "agents", None) or []) if a.get("id")]
    tools = build_tools(getattr(req, "agents", None), valid)

    # ---- F2 · spec §5-2: 메뉴가 비면 LM 을 안 부른다 ----------------------------------------
    # 🔴 단일 채널에서는 tool 이 0개면 결정을 받을 채널이 **아예 없다**(출력 필드가 `action`
    #    하나뿐이다). 예전의 C8 축약(tool 필드를 뺀 시그니처로 텍스트로 묻기)은 이 설계에
    #    존재하지 않는다 — 물어봐야 담을 그릇이 없다.
    # 🔴 그리고 tool 0개 + `tool_choice` 는 프로바이더 400 이다
    #    (`clients/openai_format.py:81-83` 이 `tool_choice` 를 `tools` 와 **무관하게** 싣는다).
    #    여기서 조기 반환하면 그 조합이 구조적으로 불가능해진다.
    if not tools:
        return _blank_decision(valid, line, "no_tools", tools_offered=0)

    sig = prog.signature
    # 🔴 배선이 아니라 **발화**를 잰다. 그리고 이 요청이 **실제로 쓴** 시그니처로 잰다.
    native_fc = native_fc_active(sig)
    tool_choice_sent = tool_choice(req)
    pred, err, tool_lane_err = None, None, None
    try:
        pred = _ask(prog, sig, line, valid, tools, tool_choice_sent)
    except AdapterParseError as e:
        # ---- F14 재정의 (2026-08-29). 계획서 §0-B ③ 이 반증한 자리다 ------------------------
        # 계획서는 "§4-1 구제는 이 설계에서 뺄 것이 없어 무의미" 라 적고 이 자리에서 `error` 를
        # 채우게 했다. **그 판단은 틀렸다.** `dspy/adapters/base.py:171-176` 은 텍스트도
        # tool_calls 도 없으면 **시그니처와 무관하게** `AdapterParseError("The LM returned an
        # empty or null response.")` 를 던진다 — 즉 텍스트 필드를 다 지운 이 판에서도 이 분기는
        # 살아 있고, 그것이 도달하는 사건은 정확히 spec §5-1 의 `no_call`(프로바이더가 아무것도
        # 안 냈다)이다.
        #
        # 🔴 그러므로 `error` 에 넣지 않는다. `policy.jl` 의 `policy_entry` 는
        #    `error !== nothing` 을 보면 **레인을 통째로** `available=false` 로 버린다 — 계약
        #    위반이 프로바이더 장애로 보고되고, 그 사건의 결정이 아니라 그 사건의 **레인 전체**가
        #    사라진다. 장애와 계약 위반을 가르는 것이 `error` 키의 존재 이유다.
        # 🔴 대신 `tool_lane_error` 가 나른다 — 그 키의 계약이 정확히 "레인은 실패했는데 결정은
        #    버리면 안 되는 사건" 이다(§4-1 이 그 자리를 그렇게 정의했고, 그 정의는 구제 코드가
        #    사라진 뒤에도 그대로 유효하다).
        # ⚠️ **다시 묻지 않는다.** §4-1 구제는 "tool 레인 필드를 뺀 시그니처로 재질의" 였는데
        #    이 설계에서 그 시그니처는 출력 필드가 **0개**다. 살릴 것이 없으므로 leg 만 태운다.
        tool_lane_err = "%s: %s" % (type(e).__name__, e)
    except Exception as e:      # 서비스가 죽지 않게: 줄리아가 canonical 로 폴백할 수 있도록 표시
        # 🔴 F16. 진짜 프로바이더 장애는 전부 `LMError` 다(`dspy/clients/lm.py:185` 가 감싼다).
        #    **여기만** `error` 를 채운다.
        err = "%s: %s" % (type(e).__name__, e)

    if pred is None:
        # 🔴 spec §5-1 `no_call` 은 **세 사건을 덮는다.** 가르는 키는 `error`·`tool_lane_error`
        #    ·`tool_calls_n` 이고, 셋 다 이미 응답에 있다(새 키를 안 짓는 이유):
        #      ⓐ `error is not None`             = 프로바이더 장애 (F16)
        #      ⓑ `tool_lane_error is not None`   = 빈/파싱 불가 응답 (F14) — 계약 위반
        #      ⓒ 둘 다 None · `tool_calls_n==0`  = 응답은 왔는데 호출이 없다 (F15) — 계약 위반
        #    ⓐ만 장애다. ⓑ·ⓒ를 `error` 로 접으면 레인이 통째로 버려진다(위 except 주석).
        d = _blank_decision(valid, line, "no_call", tools_offered=len(tools))
        d.update(error=err, tool_lane_error=tool_lane_err,
                 native_fc=native_fc, tool_choice=tool_choice_sent)
        return d

    tool_called, tool_args_all, n_calls = _first_tool_call(getattr(pred, _FC_OUT, None))
    if tool_called is None:
        # 🔴 F15 (위 ⓒ). `required` 를 걸었는데 호출이 없다 = 프로바이더 계약 위반.
        #    `error` 에 넣지 않는다 — 장애와 계약 위반은 다른 사건이고 가려져야 한다.
        d = _blank_decision(valid, line, "no_call", tools_offered=len(tools))
        d.update(native_fc=native_fc, tool_choice=tool_choice_sent, tool_calls_n=n_calls)
        return d

    # ---- F10 · F12 · F13: 인자 접지 ---------------------------------------------------------
    # 🔴 `check_tool_args` 는 총함수다(T2) — 맨입력에도 예외 대신 사유 문자열을 낸다.
    # ⚠️ 이 값이 `None` 인 것을 **"접지 성공"** 으로 세지 말 것: 규약대로 만들어진
    #    `no_intervention` 호출도 `None` 이다(접지할 인자가 없다). 줄리아는 같은 호출에
    #    `deferred:no_groundable_param` 을 낸다(`llm_bridge.jl:200-203`). 두 레인이 같은 이름의
    #    비율을 서로 다른 분모로 계산하게 된다(계획서 §0-B ⑤).
    # ⚠️ 이 문자열로 **실패 종류를 세지도 말 것** — `check_tool_args` 는 처음 걸린 사유 하나만
    #    내고 `agent_outside_enum`(F10)이 순서상 마지막이라 언제나 과소집계다(§0-B ④).
    tool_arg_error = check_tool_args(tool_called, tool_args_all, valid, agent_ids)
    # 🔴 `said` 는 접지 실패 여부와 **무관하게** 읽는다. 중간 판은 `tool_arg_error is not None`
    #    이면 `None` 으로 접었는데, 음성 대조로 재 보니 그 가드는 **어떤 시험도 안 붙잡았고**
    #    (변이 M6: 지워도 168 전부 초록) 게다가 이 파일 자신의 논증과 어긋난다: 접지 실패의
    #    대부분은 `agent` 축에서 나는데, 그때 `macro_tool_agree` 를 통째로 "못 쟀다" 로 접으면
    #    **접지 실패 부분모집단 전체가 분모에서 조용히 빠진다** — R26 억제 값을 안 쓰는
    #    아래 `called_said` 주석이 반대하는 것과 정확히 같은 편향이다.
    #    ⟹ 못 잴 때는 `MACRO_TO_TOOL.get(said)` 가 이미 `None` 을 낸다(빈 값·환각한 이름).
    #    그것으로 충분하고, 그 이상 접는 것은 측정을 지우는 것이다.
    #    게이트: test_bad_tool_args_are_reported_not_enacted (agent 축 실패에서 일치 판정이
    #    살아 있는지) — 그 단언이 이 결정의 하중을 진다.
    said = tool_args_all.get("macro")
    expressible = tool_args_all.get("expressible")
    # 🔴 `bool()` 로 **감싸지 않는다**(F13). 감싸면 `bool("False") is True` 라 거짓 `True` 가
    #    조용히 기록된다. 못 읽었으면 None = "못 쟀다"(spec §9-2).
    expressible = expressible if isinstance(expressible, bool) else None
    # 🔴 2026-09-02 — 대조용 두 번째 질문(spec §3-1). 기존 `expressible` 과 **같은 삼상 규약**:
    #    bool 이 아니면 `None`("못 쟀다")이지 `False` 가 아니다. 이 필드는 **측정 전용**이고
    #    결정(`chosen`·`ranking`)과 합성 발화 조건에는 절대 안 들어간다.
    menu_expressible = tool_args_all.get("menu_expressible")
    menu_expressible = menu_expressible if isinstance(menu_expressible, bool) else None
    reasoning = (tool_args_all.get("reasoning") or "").strip()
    raw_rank = (tool_args_all.get("ranking") or "").strip()

    # 🔴 F9. `tool_args` 에는 **줄리아가 선언한 인자만.** 공통 인자가 새면 `ground_tool_args` 가
    #    `reject:off_schema_param` 을 내고 집행이 전 사건에서 멈춘다(T1~T4 사이 HEAD 에서 실제로
    #    발화하고 있던 상태다). 교차 게이트가 이 집합 등식을 지킨다.
    tool_args = {k: v for k, v in tool_args_all.items() if k in _GROUNDING_ARGS}

    # 🔴 F5 · F7. 결정은 tool **이름**에서 나온다 — R26 억제 **전** 이름이다.
    #    억제는 집행을 막는 것이지 결정을 지우는 것이 아니다(R26 규약).
    chosen = TOOL_TO_MACRO.get(tool_called, "")
    coerced = chosen not in valid
    if coerced:
        chosen = "NOOP" if "NOOP" in valid else valid[0]

    # 🔴 F8 · `macro_tool_agree`. 일치 판정은 **억제 전** 이름으로 잰다. 재려는 것은 "채점
    #    어휘와 행동 어휘가 갈리는 빈도" — 모델의 출력에 대한 사실이지 집행 가능성에 대한
    #    사실이 아니다. 억제된 값을 쓰면 R26 부분모집단 전체가 조용히 `None` 으로 빠진다.
    # 🔴 "못 쟀다"(None)는 두 가지다: ① 부른 tool 이 없다 ② 모델의 `macro` 인자가 표 밖이다
    #    (빈 값 · 환각한 이름 · 접지 실패로 안 읽었다). ②를 안 가르면 `MACRO_TO_TOOL.get(None)`
    #    이 None 이고 None 은 어떤 tool 이름과도 같지 않으므로 그 부분모집단이 **언제나 False**
    #    로 기록된다 = "못 쟀다" 가 "재서 어긋났다" 로 둔갑한다.
    expected_tool = MACRO_TO_TOOL.get(said)
    called_said = tool_called

    # ---- R26 + 접지 실패: 집행에서 뺀다 -------------------------------------------------------
    # 🔴 컨트롤러 판정 R26. 모델이 `expressible == False` 라고 말한 사건에서 `required` 때문에
    #    **어쩔 수 없이** 나온 호출은 어느 로봇에 손대야 하는지에 대한 증거가 아니다. 기록은
    #    하되(그것은 데이터다) 집행에는 안 넘긴다. 접지에 실패한 호출도 같다 — 다만 이유가
    #    다르고, 그 둘을 가르는 키가 `tool_arg_error` 다(둘 다 `tool_called is None` 이다).
    # 🔴 구현이 여기 있는 이유: 줄리아 집행 경로(`enact.jl:178-179` 의 `enact_target`)가 읽는
    #    것은 `tool_called` · `tool_args` **두 값**이다. `tool_called = None` 이면
    #    `ground_tool_args` 가 첫 줄에서 `("deferred:no_tool_call", ...)` 를 내고 agent 를 안
    #    들인다 — 줄리아를 한 줄도 안 고치고 성립한다.
    # 🔴 `n_calls` 는 **절대 0 으로 안 덮는다** — 억제된 행(`tool_called is None` & `n>0`)과
    #    호출이 아예 없는 행(`n==0`)을 가르는 유일한 키다(F8).
    tool_called_forced, tool_args_forced = None, {}
    if expressible is False or tool_arg_error is not None:
        tool_called_forced, tool_args_forced = tool_called, tool_args
        tool_called, tool_args = None, {}

    ranking = [m for m in (s.strip() for s in raw_rank.replace("[", "").replace("]", "").split(","))
               if m in valid]
    for m in valid:                 # 빠진 legal 매크로는 뒤에 채워 항상 완전한 순위표가 되게
        if m not in ranking:
            ranking.append(m)

    # ---- T2: tool 합성 레인 (Plan B / T6b, spec §5) -----------------------------------------
    # 🔴 발화 조건은 **`expressible == False`** 하나다. `None`("못 쟀다")은 발화가 아니다.
    # ⚠️ `line` 을 그대로 넘긴다: T4a 가 프롬프트에서 지운 정답 행의 제거를 합성 레인이 승계한다.
    # 🔴 `run_synthesis` 가 단일 입구이고 **분기가 없다** — 단일 agent 레인은 D8 로 삭제됐다
    #    (2026-09-03). 남은 3-agent 레인은 여기서 넘기는 `expressible` 을 **안 쓴다**: 그
    #    판정을 agent-2 가 자기 출력 필드로 내기 때문이다(출처가 하나가 되어 "모델이 인자를
    #    생략해서 못 쟀다" 가 사라진다).
    synthesis = run_synthesis(expressible=expressible, kind=req.kind, state=line,
                              tools=tools, raw_out=raw)
    # 🔴 2026-09-03. 라이브 판의 합성 기록을 파일로 남긴다. 그 전에는 `body` 산문도
    #    `missing_primitive` 도 `stages` 도 **어디에도 안 남아서**, 유료 런에서 합성이
    #    발화하고 `empty body` 로 거절된 판을 놓고 "왜 비었나" 를 답할 수 없었다.
    #    (옛 주석은 `body_parse` 를 들었는데 그 필드는 Task 1 이 `parse_body` 와 함께
    #     지웠다 — 기록에 없는 필드를 근거로 들면 다음 독자가 그것을 찾다 못 찾는다.)
    #    던지지 않는다 — 진단이 결정을 죽이면 진단을 켠 것이 사고의 원인이 된다.
    # ✅ 2026-09-22: 그 append 는 `macro()` 로 옮겼다 — 여기서만 쓰면 위 조기 반환 셋과
    #    예외가 행을 못 남긴다(global-constraints.md "Task 3, 조기 반환").
    return {"policy": "dspy:%s" % MODEL, "chosen": chosen, "ranking": ranking,
            # 🔴 `margin` 은 이 설계가 없앴다(spec §3-3). **키는 남기고 값은 안 채운다** —
            #    키가 사라지면 소비자가 "레인이 안 돌았다" 와 "값이 없다" 를 못 가른다.
            #    그 내용은 `reasoning` 이 산문으로 나른다.
            "margin": None, "reasoning": reasoning, "valid": valid,
            "coerced": coerced, "state": line, "llm_calls": _state["calls"],
            "cache": CACHE, "llm_billed": _state["billed"], "error": err,
            # ---- tool 레인 (Plan A) ----------------------------------------------------------
            # 🔴 `decision_source` 가 C8 의 옛 세 사건 서술을 대체한다. 예전에는 소비자가
            #    `tools_offered` · `tool_called` · `tool_lane_error` · `tool_calls_n` ·
            #    `tool_choice` 다섯 키로 사건 종류를 **재구성**해야 했고, 이 레포는 그 재구성을
            #    두 번 틀렸다. 이제 이름이 응답에 직접 실린다:
            #      `"no_tools"` = 부를 tool 이 없었다 (레인이 꺼졌다)
            #      `"no_call"`  = 메뉴는 냈는데 호출을 못 받았다 (위 세 하위 사건)
            #      `"tool"`     = 호출을 받았다 (억제 여부와 무관 — 억제는 `tool_called` 가 말한다)
            # 🔴 이 키의 **존재 자체**가 세대 표식이다: 없는 행은 단일 채널 이전의 것이고,
            #    `expressible` 이 다른 채널에서 온 값이므로 한 표에 섞으면 안 된다.
            "decision_source": "tool",
            "tool_called": tool_called, "tool_args": tool_args,
            # 여럿 왔으면 첫 번째만 썼다는 사실을 남긴다(조용히 버리지 않는다). T5 가
            # `parallel_tool_calls=False` 로 원천 차단해도 이 값은 계속 잰다 — 프로바이더가
            # 그 플래그를 안 지키면 조용해지면 안 되고, F8 의 판별키이기도 하다.
            "tool_calls_n": n_calls, "tools_offered": len(tools),
            # 🔴 레짐 표식. 이 요청에 **실제로 실린** 값이다(소스가 아니라 그 요청의 사실).
            "tool_choice": tool_choice_sent,
            # 집행에서 뺀 호출의 원본. 억제가 없었으면 None/{} 다. 🔴 이것이 `tool_called`
            # 자리로 돌아가면 안 된다 — 줄리아가 그 값을 집행에 먹인다.
            "tool_called_forced": tool_called_forced,
            "tool_args_forced": tool_args_forced,
            # 🔴 인자 접지 실패 사유(`None` 이면 통과). R26 억제와 접지 실패 억제를 가르는
            #    유일한 키다 — 둘 다 `tool_called is None` 이다.
            "tool_arg_error": tool_arg_error,
            "expressible": expressible,
            # 🔴 측정 전용. `expressible` 과 나란히 두는 이유는 소비자가 둘의 **차이**를
            #    읽기 때문이다(spec §3-1 의 2x2 표). 결정에는 안 쓴다.
            "menu_expressible": menu_expressible,
            # 배선이 아니라 발화. 이 요청이 실제로 쓴 시그니처 기준(None = 못 쟀다).
            "native_fc": native_fc,
            # §4-1: 레인은 실패했는데 결정은 살아남은 사건. `error` 와 **다른 자리**여야 한다.
            #       단일 채널에서 이 값이 채워지는 자리는 위 `AdapterParseError` 분기 하나뿐이고,
            #       거기서는 결정이 없으므로 언제나 `no_call` 과 함께 온다.
            "tool_lane_error": tool_lane_err,
            # 🔴 재기만 한다. 강제하지 않는다 (spec §4-1). 못 쟀으면 None 이고,
            #    False("재서 어긋났다") 와 섞지 않는다 (spec §9-2).
            "macro_tool_agree": (None if (called_said is None or expected_tool is None)
                                 else called_said == expected_tool),
            # ---- 합성 레인 (T2, Plan B / T6b, spec §9-2) --------------------------------------
            # 🔴 네 값: "disabled" | False | True | None. **네 값은 분할이 아니다** — 다섯 번째
            #    사건(돌았는데 실패)이 `None` 을 공유하고, 그것을 가르는 키는 같은 응답의
            #    `synthesis["ran"]` · `synthesis["error"]` 다.
            # 🔴 2026-09-03 최종 리뷰. **이 값은 전선에 두 번 실린다** — 여기 최상위 사본과
            #    `synthesis["tool_minted"]` 원본. 그것을 명시해 둔다(policy.jl 의
            #    `SYNTH_LANE_KEYS` docstring 이 오래 "최상위에만 있다" 처럼 읽히게 적혀
            #    있었고, 이번 리뷰가 그 문장을 고쳤다). 진실원은 **합성 기록 안의 것**이고
            #    이 줄은 그 투영이다: 값을 여기서 계산하지 않고 그대로 읽는다. 사본이 사는
            #    이유는 `out["dspy"]` 의 `# ---- tool 레인` 표식 **위**에 이 키가 있어야
            #    하고(아래 그 dict 의 주석), 줄리아의 `_synth_view` 가 최상위만 읽기
            #    때문이다 — 그래서 둘이 갈릴 자리는 없다.
            "tool_minted": synthesis["tool_minted"],
            "synthesis": synthesis}


# ---- `/decide` 원장 행 (2026-09-22, 재시도 body 보존 Task 3) -------------------------------
# 🔴 `macro()` 에 들어온 요청은 **어느 출구로 나가든** `row_type="decide"` 행을 정확히 하나
#    남긴다. 전에는 정상 경로(합성 단계까지 간 요청)만 append 했고, 아래 앞의 넷과 마지막 하나는
#    원장에 흔적이 없었다 — 소비자는 "행이 없다" 를 "요청이 안 왔다" 와 못 갈랐다.
# 🔴 `decide_outcome` 은 그 출구의 이름이다. `_decide_outcome` 이 응답에서 **유도**한다 — 출구마다
#    손으로 적으면 새 출구가 생길 때 조용히 빠진다. 이 튜플이 정의역이고, 시험
#    (`test_ledger_rows.py::test_the_outcome_vocabulary_is_exactly_the_paths_exercised_here`)이
#    값 하나하나를 실제 경로로 태운다 — 죽은 값도, 시험이 모르는 경로도 없다.
# ⚠️ 원장 전용이다. 전선(`synthesis`)에는 안 싣는다 — 줄리아는 `decision_source`·`synthesis` 로
#    같은 사실을 이미 읽고, 전선 키를 늘리면 `SYNTH_LANE_KEYS` 교차 게이트가 움직인다.
DECIDE_OUTCOMES = (
    # -- 결정이 없다 (`chosen == ""`, 줄리아는 canonical 로 폴백) ---------------------------
    "no_tools",              # 메뉴가 비어 LM 을 안 불렀다 (`decision_source == "no_tools"`)
    "no_call_lm_error",      # ⓐ 프로바이더 장애 — `error` (F16)
    "no_call_parse_error",   # ⓑ 빈/파싱 불가 응답 — `tool_lane_error` (F14)
    "no_call_no_tool_call",  # ⓒ 응답은 왔는데 tool 호출이 없다 (F15)
    # -- 결정이 났다 (`decision_source == "tool"`) — 합성 단계의 결말로 가른다 ----------------
    "synthesis_disabled",    # 합성 미실행: `TOOL_SYNTHESIS != "1"`
    "synthesis_refused",     # 합성 미실행: G1 — 과금 전 거절(`refused` 가 사유 문자열)
    "synthesis_failed",      # 합성 실패: 단계 하나가 던졌다(`error`)
    "synthesis_not_fired",   # 합성 미발화: agent-2 가 expressible≠False — agent-3 안 불렀다
    "synthesis_ran",         # 합성 성공: agent-3 까지 돌았다(쓴 것은 `wrote` 가 따로 말한다)
    # -- 응답이 없다 ------------------------------------------------------------------------
    "raised",                # 예외가 `macro()` 밖으로 샜다(HTTP 500) — `decide_error` 가 이유
)


def _decide_outcome(d) -> str:
    """`_macro_decision` 의 응답이 어느 출구였나. `DECIDE_OUTCOMES` 의 한 값."""
    src = d.get("decision_source")
    if src == "no_tools":
        return "no_tools"
    if src == "no_call":
        # 🔴 순서가 아니라 배타다 — `error` 와 `tool_lane_error` 는 서로 다른 except 에서 온다.
        if d.get("error") is not None:
            return "no_call_lm_error"
        if d.get("tool_lane_error") is not None:
            return "no_call_parse_error"
        return "no_call_no_tool_call"
    syn = d.get("synthesis") or {}
    if syn.get("tool_minted") == "disabled":
        return "synthesis_disabled"
    if isinstance(syn.get("refused"), str):
        return "synthesis_refused"
    if syn.get("error") is not None:
        return "synthesis_failed"
    if syn.get("ran") is not True:
        return "synthesis_not_fired"
    return "synthesis_ran"


def _append_decide_row(req, d, raw, response_id, exc=None):
    """`/decide` 행 하나를 조립해 append 한다. **절대 안 던진다.**

    행 = 합성 기록(조기 반환이면 blank 기록)의 사본 + 신원(`stamp_record`) + `raw_lm` +
    `decide_outcome` + `decide_error`. `d is None` 이면 `macro()` 가 던진 판이다.
    """
    try:
        if d is not None:
            syn, outcome = d["synthesis"], _decide_outcome(d)
            why = d.get("error") or d.get("tool_lane_error")
        else:
            syn, outcome = blank_synthesis_record(kind=req.kind, expressible=None), "raised"
            syn["reason"] = "macro() raised before a decision existed; see decide_error"
            why = "%s: %s" % (type(exc).__name__, exc)
        row = _stamp_record(
            dict(syn, raw_lm=dict(raw), decide_outcome=outcome, decide_error=why),
            row_type="decide", record_id=req.record_id, response_id=response_id,
            attempt=1, trigger="first", run_ctx=req.run_ctx,
            code_fingerprint=CODE_FINGERPRINT)
    except Exception as e:  # noqa: BLE001 -- 원장이 결정을 죽이면 안 된다
        _note_ledger_append_failure(e, where="dspy_service._append_decide_row")
        return None
    return _append_synthesis_record(row)


@app.post("/macro")
def macro(req: MacroRequest):
    """결정 본체(`_macro_decision`)를 돌리고 **어느 출구로 나가든** 원장에 `decide` 행을 하나 남긴다.

    🔴 `response_id` 는 서버가 **처리마다** 새로 발급한다(`uuid4`, controller R2). `record_id` 는
       줄리아의 논리 요청 id 라 HTTP 재전송은 같은 `record_id` 로 서로 다른 응답을 만들 수 있고,
       원장 append 순서는 클라이언트가 받은 순서가 아니다 — `(record_id, response_id)` 쌍이
       줄리아가 **실제로 받은** 응답을 특정한다. 중복 행은 전부 남긴다(dedup·멱등 아님).
    🔴 두 id 는 전선의 `synthesis` 안에 싣는다(`/decide` → `dspy.synthesis.record_id` /
       `.response_id`). 예외로 끝난 요청은 응답이 없으므로 원장 행에만 남는다(`raised`).
    ⚠️ 원시 응답(`raw_lm`)은 합성 단계(observe/design/compose)의 것뿐이다. 결정 프로그램
       (`_state["program"]`)은 모듈 수준에서 요청 간 공유되므로 그 history 는 요청 국소가 아니고,
       여기 안 싣는다(global-constraints.md "Task 1·2, 원시 응답"의 범위).
    """
    response_id = uuid.uuid4().hex
    raw: Dict[str, Any] = {}
    try:
        d = _macro_decision(req, raw)
    except Exception as e:
        _append_decide_row(req, None, raw, response_id, exc=e)
        raise
    d["synthesis"]["record_id"] = req.record_id
    d["synthesis"]["response_id"] = response_id
    _append_decide_row(req, d, raw, response_id)
    return d


class RewriteRequest(BaseModel):
    tool_name: str = ""
    spec: str = ""
    impl_name: str = ""
    impl_code: str = ""
    impl_rejected_why: str = ""
    # ---- 원장 신원 (2026-09-22) — 뜻은 `MacroRequest` 의 같은 이름 필드 주석 -------------
    record_id: Optional[str] = None
    parent_record_id: Optional[str] = None     # 이 되먹임이 고치는 `/decide` 행의 id
    attempt: int = 2                           # 재시도 상한이 1 이라 언제나 2 다(구조)
    trigger: str = ""                          # register_reject | threw | noop | prerun
    run_ctx: Optional[Dict[str, Any]] = None


@app.post("/rewrite")
def rewrite(req: RewriteRequest):
    """D17. 등록/바인딩 거절 사유를 agent-3 에게 **한 번** 되먹인다.

    🔴 재시도 상한은 호출자(Julia)가 지킨다 — 이 엔드포인트는 상태가 없다. `enact.jl` 의
       `_rewrite_once` 는 두 번째 거절을 `_reject_malformed` 로 **즉시 반환**하므로 상한이
       루프가 아니라 **구조**로 하나다. 여기에 카운터를 두면 진실원이 둘이 된다.

    🔴 이 함수는 던지지 않는다 — `rewrite_impl` 이 자기 규약으로 그것을 보장하고
       (그 docstring 이 근거의 진실원이다), 여기서 다시 감싸면 두 벌이 된다. 500 이
       올라가면 줄리아는 원래 거절을 그대로 들고 돌아선다(그것도 정상 경로다).

    2026-09-22: 원장 행을 남긴다 — `append_synthesis_record` 는 던지지 않으므로 이 함수의
    '안 던진다' 규약은 그대로다. 행은 `row_type="rewrite"`, 원시 응답은 `raw_lm={"rewrite": [...]}`,
    고치기 전 body 는 `rejected_impl_code` 로 남는다. 응답에는 `record_id`(되돌림)와 서버가 이
    처리에 발급한 `response_id` 를 최상위에 싣는다(`macro()` docstring 과 같은 규약).
    프로그램은 주입하지 않는다 — `rewrite_impl` 이 요청마다 새로 만들어야 history 가 요청 국소다.
    """
    _why = RA.check_handshake(req.run_ctx, REPAIR_ABLATION)
    if _why:
        # 🔴 존 복구 base ablation: 레벨이 다른 판이 이 서비스로 오면 **결정을 내지 않는다**.
        #    Julia 는 기동 때 /health 로 먼저 막는다(policy.jl assert_service_repair_ablation) — 이것은 둘째 층이다.
        raise ValueError(_why)
    import synthesize as SY
    response_id = uuid.uuid4().hex
    raw: Dict[str, Any] = {}
    out = SY.rewrite_impl(tool_name=req.tool_name, spec=req.spec,
                          impl_name=req.impl_name, impl_code=req.impl_code,
                          impl_rejected_why=req.impl_rejected_why, raw_out=raw)
    out["record_id"] = req.record_id
    out["response_id"] = response_id
    try:
        row = _stamp_record(
            dict(out, raw_lm=dict(raw), tool_name=req.tool_name,
                 rejected_impl_code=req.impl_code, impl_rejected_why=req.impl_rejected_why),
            row_type="rewrite", record_id=req.record_id, response_id=response_id,
            parent_record_id=req.parent_record_id, attempt=req.attempt,
            trigger=req.trigger, run_ctx=req.run_ctx, code_fingerprint=CODE_FINGERPRINT)
    except Exception as e:  # noqa: BLE001 -- 원장이 되먹임을 죽이면 안 된다
        _note_ledger_append_failure(e, where="dspy_service.rewrite")
    else:
        _append_synthesis_record(row)
    return out


@app.post("/decide")
def decide(req: MacroRequest):
    """한 번의 호출로 **모든 비-규칙 정책**의 결정을 돌려준다.
    줄리아는 canonical(규칙)을 자기가 계산해 합치므로, 이 응답 + canonical = 세 정책 전부.
    UI 는 이 셋 중 무엇을 볼지 고르고, 실제로 실행된 것은 enacted 로 따로 표시한다."""
    _why = RA.check_handshake(req.run_ctx, REPAIR_ABLATION)
    if _why:
        # 🔴 존 복구 base ablation: 레벨이 다른 판이 이 서비스로 오면 **결정을 내지 않는다**.
        #    Julia 는 기동 때 /health 로 먼저 막는다(policy.jl assert_service_repair_ablation) — 이것은 둘째 층이다.
        raise ValueError(_why)
    valid = _valid_for(req)
    # 두 producer 가 **서로 다른 것을 본다**. UI 가 그 차이를 나란히 보여줄 수 있도록 둘 다 돌려준다.
    #   llm_input       : 자연어 관찰 (+ 종류-무관 서술자 6개)
    #   surrogate_input : 학습 때와 같은 스키마 피처
    out = {"valid": valid, "state": _state_line(req),
           "llm_input": _llm_input(req), "surrogate_input": _state_line(req),
           "llm_input_mode": "nl" if (req.nl and req.nl.strip()) else "parsed-fields"}

    # ---- 레인 청구 (2026-08-29, T10) ---------------------------------------------------------
    # 🔴 `req.lanes is None` 과 `req.lanes == []` 는 **다른 사건이다.** `or LANES` 로 쓰면
    #    빈 목록이 falsy 라 "아무것도 안 물었다" 가 조용히 "둘 다" 가 되고, 이 태스크가
    #    없애려는 그 비용이 그대로 돌아온다.
    LANES = ("dspy", "surrogate")
    want = tuple(req.lanes) if req.lanes is not None else LANES
    bad = [l for l in want if l not in LANES]
    if bad:
        # 🔴 F1 과 같은 규약. 조용히 무시하면 "surrogat" 오타 하나가 그 레인을 통째로
        #    사라지게 만들고, 줄리아는 그것을 "서비스 장애"(available=false) 로 읽는다.
        raise ValueError("unknown lane(s) %r; allowed: %s" % (bad, ", ".join(LANES)))
    # ⚠️ `out["valid"]`·`out["state"]`·`out["llm_input"]`·`out["surrogate_input"]` 은 레인과
    #    무관하게 위에서 이미 나갔다 — 둘 다 **요청 자체의 기록**이고, 빼면 결정 행의 `valid`
    #    열이 사라진다(채점기가 읽는다).

    if "dspy" in want:
        d = macro(req)                                   # dspy 정책(위 엔드포인트 재사용)
        out["dspy"] = {"chosen": d["chosen"], "ranking": d["ranking"], "margin": d["margin"],
                       "rationale": d["reasoning"], "policy": d["policy"],
                       "coerced": d["coerced"], "error": d["error"],
                       # ---- 합성 레인 (T2, Plan B / T6b) --------------------------------------
                       # 🔴 이 둘은 **Plan A 의 tool 레인 키가 아니다.** 아래 `# ---- tool 레인`
                       #    표식이 이 dict 안에서 그 경계를 선언하고, `test/tool_lane_keys_survive.jl`
                       #    (6)절이 표식 **아래** 키 집합을 Julia 의 `TOOL_LANE_KEYS` 여덟과
                       #    양방향 등호로 대조한다. 그래서 합성 레인 키는 표식 **위**에 둔다 —
                       #    표식 아래에 두면 그 게이트가 정당하게 빨개진다(다른 레인의 키를
                       #    tool 레인 목록에 밀어 넣는 셈이므로).
                       # 🔴 그러므로 줄리아가 이 값을 결정 행으로 나르려면 `TOOL_LANE_KEYS` 에
                       #    이름을 더하는 것과 **같은 커밋에서** 이 두 줄을 표식 아래로 옮겨야
                       #    한다. 그 배선은 이 태스크의 범위 밖이고 T6b 보고서가 줄을 짚는다.
                       # 🔴 `/macro` 에는 이 레포에 **호출자가 0개**다(아래 주석). 라이브 레인은
                       #    `/decide` 로만 들어오므로(`tools/monitor/policy.jl:559`), 여기 안
                       #    실으면 `tool_minted` 는 실제로 도는 곳에서 영원히 안 보인다.
                       "tool_minted": d["tool_minted"], "synthesis": d["synthesis"],
                       # ---- 레짐 표식 · R26 기록 (Plan B, 2026-08-29) --------------------------
                       # 🔴 이 셋도 **아래 표식 위**에 산다. `tool_minted`/`synthesis` 와 같은
                       #    이유다: `test/tool_lane_keys_survive.jl` (6)절이 표식 **아래** 키
                       #    집합을 Julia 의 `TOOL_LANE_KEYS` 여덟과 **양방향 등호**로 대조하므로,
                       #    여기 아래에 키를 하나라도 더하면 그 게이트가 정당하게 빨개진다.
                       #    파이썬 쪽 그물은 `test_synthesize.py` 의
                       #    `test_synthesis_keys_sit_above_the_tool_lane_marker_in_out_dspy`.
                       # ⚠️ 그러므로 줄리아의 **결정 행**에는 아직 이 셋이 안 실린다. 실으려면
                       #    `tools/monitor/policy.jl` 의 `const TOOL_LANE_KEYS` 튜플에 이름을
                       #    더하고 **같은 커밋에서** 이 줄들을 표식 아래로 옮겨야 한다. 그 배선은
                       #    이 태스크의 파일 범위 밖이다(보고서가 줄을 짚는다).
                       # ⚠️ 위 주석 줄은 `# ---- tool ` 로 시작하면 안 된다 — 줄리아 추출기는
                       #    그 모양의 표식이 이 dict 안에 **정확히 하나**일 것을 요구하고, 둘이면
                       #    게이트가 죽는다(빨간색이 아니라 추출 실패로).
                       # 🔴 2026-08-29 (T-C): `tool_choice` 는 여기 있었고 **표식 아래로 내려갔다**.
                       #    줄리아의 `TOOL_LANE_KEYS` 가 그것을 나르게 됐으므로 양방향 등호가
                       #    그것을 요구한다. `tool_called_forced` · `tool_args_forced` 는 줄리아가
                       #    아직 안 읽으므로 그대로 위에 남는다.
                       "tool_called_forced": d["tool_called_forced"],
                       "tool_args_forced": d["tool_args_forced"],
                       # ---- tool 레인 (Plan A) ------------------------------------------------
                       # 🔴 `/macro` 에는 이 레포에 **호출자가 없다** — 실측(`grep -rn '/macro'
                       #    --include='*.jl' --include='*.py' src tools wm4spacecraft_manufacturing
                       #    test`): 정의 1건(`@app.post("/macro")`) · 주석/독스트링 언급 3건 ·
                       #    **호출 0건**.
                       #    라이브 레인은 `/decide` 로만 들어온다(`tools/monitor/policy.jl:559`).
                       #    여기 안 실으면 ②접지가 실제로 도는 곳에서 영원히 안 보인다.
                       # ⚠️ 여기까지가 Plan A 다. 줄리아의 `policy_entry`(`policy.jl:1034-1046`)는
                       #    키 목록을 손으로 들고 있어 아래 여덟을 **아직 결정 행으로 안 나른다** —
                       #    그 배선(`run_demo.jl` 의 `this_decision`)은 Plan B 의 첫 태스크다.
                       "tool_called": d["tool_called"], "tool_args": d["tool_args"],
                       "tool_calls_n": d["tool_calls_n"], "tools_offered": d["tools_offered"],
                       "expressible": d["expressible"], "native_fc": d["native_fc"],
                       # 🔴 2026-09-02 — 대조용 두 번째 질문. 라이브 레인은 `/decide` 로만
                       #    들어오므로(`policy.jl` 의 `decide_all`) 여기 없으면 그 필드는
                       #    `/macro` 에서만 사는 죽은 값이 된다. 표식 **아래**에 둔다:
                       #    위로 숨기면 `TOOL_LANE_KEYS` 와의 양방향 등호가 그것을 못 보고,
                       #    줄리아가 영영 안 나르는 상태가 조용해진다.
                       "menu_expressible": d["menu_expressible"],
                       "tool_lane_error": d["tool_lane_error"],
                       "macro_tool_agree": d["macro_tool_agree"],
                       # ---- 레짐 표식 · 단일 채널 (2026-08-29) --------------------------------
                       # 🔴 이 셋은 표식 **아래**다 — 줄리아의 `TOOL_LANE_KEYS` 가 그것을 나르고
                       #    `test/tool_lane_keys_survive.jl` (6)절이 양방향 등호로 대조한다.
                       #    (위 `# ---- 레짐 표식 · R26 기록` 주석이 `# ---- tool ` 로 시작하지
                       #     않는 것이 중요하다 — 표식은 이 dict 안에 정확히 하나여야 한다.)
                       #
                       # 🔴 **T4 는 이 자리를 일부러 줄리아와 어긋난 채로 남긴다.** `text_rescue`
                       #    는 사라졌고(되찾을 텍스트 채널이 없다) `decision_source`·`tool_arg_error`
                       #    는 새로 생겼는데, `tools/monitor/policy.jl` 의 `TOOL_LANE_KEYS` 는 아직
                       #    옛 열 개다. 그래서 `test/tool_lane_keys_survive.jl` 의 **(6)절만**
                       #    정당하게 빨갛다(실측: 이 커밋이 더한 실패는 정확히 2개다 — 그 파일은
                       #    T4 **전에도** (3)절에서 13개가 빨갰고 그건 이 레인과 무관하다) —
                       #    T6 이 그 튜플 하나를 고치면 닫힌다(줄리아 단독
                       #    편집이고, 그것이 T6 의 첫 스텝이다). 파이썬 쪽에서 키를 위로 숨겨
                       #    초록을 만들지 않는 이유: 그러면 줄리아가 이 셋을 **영원히 안 나르는**
                       #    상태가 조용해진다 — 이 레포가 반복해 데인 자리다.
                       "tool_choice": d["tool_choice"],
                       "decision_source": d["decision_source"],
                       "tool_arg_error": d["tool_arg_error"]}

    if "surrogate" not in want:
        # 🔴 **키 자체를 안 싣는다.** 빈 dict 으로 실으면 소비자가 "안 물었다" 와
        #    "물었는데 실패했다" 를 못 가른다 — 후자만 `policy_entry(nothing, …)` 의 뜻이다.
        return out

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
        _vals = [s for _, s, _p in scored]
        spread = max(max(_vals) - min(_vals), 1e-9)
        out["surrogate"] = {
            "chosen": scored[0][0],
            "ranking": [m for m, _, _p in scored],
            "scores": {m: round(s, 2) for m, s, _p in scored},
            # selfimprove(spec §5.3): 고른 팔의 P̂ 와 τ 필터 뒤 남은 팔
            "surro_p_selected": round(scored[0][2], 4),
            "surro_eligible": [m for m, _, _p in scored],
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


# ==========================================================================================
# 존 복구 제안 레인 (T9, 설계 2026-09-24 §4.1·§7.2·§9.2) — `/zone_repair/propose` · `/zone_repair/revise`
# ==========================================================================================
# 🔴 호출자는 `src/verification/repair_runtime.jl` 의 CB 없는 에피소드 driver 하나다. 관측(`request`)은 driver 가
#    t0 checkpoint 에서 복원한 **일회용 observe worker** 가 `policy.jl` 의 `service_payload` 로 만든 바로 그
#    `/decide` 페이로드다 — 그래서 모델이 읽는 문장은 `_llm_input` 한 벌이고, 결정 레인과 갈리지 않는다.
# 🔴 두 엔드포인트는 **던지지 않고 기록으로 거절한다**(ablation 레벨 불일치 포함) — driver 가 사유를 에피소드
#    기록에 싣는다. 팔 이름은 pydantic `Literal` 이 경계에서 막는다(오타가 주 팔로 접히지 않는다).
# 🔴 원장: 요청마다 한 줄(`row_type = zone_repair_propose | zone_repair_revise`), 원시 LM 응답 포함.
from typing import Literal  # noqa: E402
import synthesize as _SY  # noqa: E402  (이미 위에서 임포트된 모듈 — numpy/sklearn-before-dspy 계약 무관)


class ZoneRepairBudget(BaseModel):
    max_model_calls: int
    max_candidates: int
    max_total_tokens: int
    # 🔴 C1: required, no default -- the lane's per-call output cap (manifest `budget.model.max_output_tokens_per_call`).
    max_output_tokens: int
    max_cost_usd: Optional[float] = None


class ZoneRepairProposeRequest(BaseModel):
    request: MacroRequest
    arm: Literal["general", "geometry"]
    checkpoint_id: str
    budget: ZoneRepairBudget
    capability_contract_version: str
    geometry_context: Optional[Dict[str, Any]] = None
    # 🔴 존 복구 관측 전용 센서(로봇·팀·배정). `MacroRequest` 에 두지 않는다 — 결정 레인 프롬프트를 안 바꾸려고.
    robot_bindings: Optional[List[Dict[str, Any]]] = None
    record_id: str
    run_ctx: Optional[Dict[str, Any]] = None


class ZoneRepairReviseRequest(BaseModel):
    arm: Literal["general", "geometry"]
    checkpoint_id: str
    budget: ZoneRepairBudget
    capability_contract_version: str
    ledger: Dict[str, Any]
    compose_input: Dict[str, Any]
    rejected: List[Dict[str, Any]]
    geometry_context: Optional[Dict[str, Any]] = None
    record_id: str
    parent_record_id: Optional[str] = None
    run_ctx: Optional[Dict[str, Any]] = None


def _repair_lm():
    """이 레인이 부를 LM. 시험은 이 함수를 가짜로 바꾼다(요청 스레드와 무관하게)."""
    return dspy.settings.lm


def _repair_lm_config(lm):
    """I2: the sampling/transport configuration of the LM this lane will actually call -- read from the request-local
    copy (`synthesize._request_local_lm`), not from the service globals, so the stamp says what was sent."""
    if lm is None:
        return {}
    c = _SY._request_local_lm(lm)
    kw = dict(getattr(c, "kwargs", {}) or {})
    temp = kw.get("temperature", getattr(c, "temperature", None))
    return {"model": getattr(c, "model", None), "model_type": getattr(c, "model_type", MODEL_TYPE),
            # None = the key is dropped from the request (`_resolve_temperature`) -- stamped as a word, not absent
            "temperature": "omitted" if temp is None else temp,
            "cache": getattr(c, "cache", None),
            "num_retries": getattr(c, "num_retries", kw.get("num_retries")), "max_retries": kw.get("max_retries")}


#: 🔴 I2: the zone-repair lane is pinned to the chat transport. On /v1/responses the output cap includes reasoning
#:    tokens, `LM._check_truncation` is silent (dspy 3.3.0) and the OpenAI-client retry path was never traced.
REPAIR_MODEL_TYPE = "chat"


def _repair_transport_refusal(lm):
    mt = _repair_lm_config(lm).get("model_type")
    return (None if lm is None or mt == REPAIR_MODEL_TYPE else
            "the zone-repair lane is pinned to model_type=%r; this service's LM runs model_type=%r" % (REPAIR_MODEL_TYPE, mt))


def _repair_provenance(req, response_id):
    """후보마다 싣는 도장 — Julia `RepairRuntime.decision_gaps` 가 요구한다(schema digest · 권한 계약 · 서비스 source 지문 ·
    I2 의 샘플링/전송 설정 · 출력 상한 · prompt digest · 세계 인터페이스 digest). ⚠️ `capability_contract_version` 은 **요청의
    값을 되돌려 싣는다**: 권한 계약은 Julia 가 집행하고 이 서비스는 그 계약을 모른다 — 이 도장은 "그 계약을 선언한 요청에 대해
    생성됐다" 까지만 말한다."""
    p = {"source": "service", "arm": req.arm, "record_id": req.record_id, "response_id": response_id,
         "tool_proposal_schema_sha256": _SY.TOOL_PROPOSAL_SCHEMA_SHA256,
         "geometry_patch_schema_sha256": _SY.GEOMETRY_PATCH_SCHEMA_SHA256,
         "capability_contract_version": req.capability_contract_version,
         "service_code_fingerprint": CODE_FINGERPRINT, "repair_ablation": REPAIR_ABLATION,
         "max_output_tokens": req.budget.max_output_tokens}
    p.update(_repair_lm_config(_repair_lm()))
    p.update(_SY.repair_prompt_digest(req.arm, dspy.settings.adapter))
    if req.arm == "general":                       # only the general compose stage reads the world interface
        p.update(_SY.world_interface_stamp())
    # 🔴 못 잰 도장(None)은 **키째 뺀다** — null 로 실으면 "있다" 로 읽힐 자리가 생긴다(Julia 는 부재를 gap 으로 본다).
    return {k: v for k, v in p.items() if v is not None}


def _zone_repair_observation(req):
    """존 복구 팔의 Observe 입력 = 결정 레인과 같은 `_llm_input` + 존 복구 전용 센서(로봇·팀·배정)."""
    return _llm_input(req.request) + _SY.render_robot_bindings(req.robot_bindings)


def _observation_stamps(req, state):
    """관측 지문: Observe 가 실제로 받은 문장의 digest 와 센서별 판·digest(설계 §4.1 — 새 센서는 지문을 남긴다)."""
    sensors = {}
    if req.robot_bindings is not None:
        sensors["robot_bindings"] = {"version": _SY.ROBOT_BINDINGS_SENSOR,
                                     "sha256": _SY.canonical_sha256(req.robot_bindings)}
    return {"observation_sha256": hashlib.sha256(state.encode("utf-8")).hexdigest(), "observation_sensors": sensors}


def _repair_row(req, out, raw, response_id, row_type, parent=None):
    try:
        row = _stamp_record(dict(out, raw_lm=dict(raw)), row_type=row_type, record_id=req.record_id,
                            response_id=response_id, parent_record_id=parent,
                            attempt=2 if row_type == "zone_repair_revise" else 1, trigger=req.arm,
                            run_ctx=req.run_ctx, code_fingerprint=CODE_FINGERPRINT)
    except Exception as e:  # noqa: BLE001 -- 원장이 제안을 죽이면 안 된다
        _note_ledger_append_failure(e, where="dspy_service." + row_type)
    else:
        _append_synthesis_record(row)


def _repair_refusal(req, why):
    out = _SY._repair_blank(req.arm, req.checkpoint_id)
    out["error"] = "refused: %s -- no model call was made" % why
    return out


@app.post("/zone_repair/propose")
def zone_repair_propose(req: ZoneRepairProposeRequest):
    response_id = uuid.uuid4().hex
    why = RA.check_handshake(req.run_ctx, REPAIR_ABLATION) or _repair_transport_refusal(_repair_lm())
    raw: Dict[str, Any] = {}
    prov = _repair_provenance(req, response_id)
    if why:
        out = _repair_refusal(req, why)
    else:
        r = req.request
        state = _zone_repair_observation(req)
        try:
            out = _SY.propose_repair(
                state, arm=req.arm, checkpoint_id=req.checkpoint_id, budget=req.budget.model_dump(),
                lm=_repair_lm(), id_prefix=req.record_id, tools=build_tools(getattr(r, "agents", None), _valid_for(r)),
                geometry_context=req.geometry_context, provenance=dict(prov, **_observation_stamps(req, state)), raw_out=raw)
        except ValueError as e:                    # budget that cannot hold its call plan -- refused, zero calls
            out = _repair_refusal(req, "budget: %s" % e)
        out["observation_stamps"] = _observation_stamps(req, state)
    out["provenance"] = prov                       # I2: the stamps travel even when no candidate does
    out.update(record_id=req.record_id, response_id=response_id)
    _repair_row(req, out, raw, response_id, "zone_repair_propose")
    return out


@app.post("/zone_repair/revise")
def zone_repair_revise(req: ZoneRepairReviseRequest):
    response_id = uuid.uuid4().hex
    why = RA.check_handshake(req.run_ctx, REPAIR_ABLATION) or _repair_transport_refusal(_repair_lm())
    raw: Dict[str, Any] = {}
    prov = _repair_provenance(req, response_id)
    if why:
        out = _repair_refusal(req, why)
    else:
        try:
            out = _SY.revise_repair(
                arm=req.arm, checkpoint_id=req.checkpoint_id, budget=req.budget.model_dump(), ledger_state=req.ledger,
                compose_input=req.compose_input, rejected=req.rejected, lm=_repair_lm(), id_prefix=req.record_id,
                geometry_context=req.geometry_context, provenance=prov, raw_out=raw)
        except ValueError as e:
            out = _repair_refusal(req, "budget: %s" % e)
    out["provenance"] = prov
    out.update(record_id=req.record_id, response_id=response_id)
    _repair_row(req, out, raw, response_id, "zone_repair_revise", parent=req.parent_record_id)
    return out
