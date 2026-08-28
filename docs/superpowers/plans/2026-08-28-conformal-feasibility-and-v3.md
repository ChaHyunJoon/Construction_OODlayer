# Plan — 축 2 실현가능성을 재고, 그 결과로 V3 계획서를 쓴다

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 설계서 §7 의 **R3**(축 2 가 교정돼 있는가)와 **R4**(잔차가 교환가능한가)를 **기존 33행 라벨셋으로 지금 잰다.** 그 측정이 나온 뒤에, 그 숫자를 근거로 **V3 계획서**(반사실 라벨 생산자 + 재학습 + `train_macros` 도장)를 쓴다.

**Architecture:** 재는 도구는 새로 짓지만 **추정기 부품은 전부 기존 하니스에서 빌려온다** — `eval_surrogate_v2.load_rows`(로딩 계약), `objective.J_row`(진실 J), `SurrogateV2.predict_J`(Ĵ), `LeaveOneGroupOut(groups=instance)`(폴드). 새로 쓰는 것은 conformal 층 하나뿐이다: OOF 잔차 → 유한표본 분위수 q → 팔별 구간 → top-1/top-2 겹침. 측정이 끝나면 그 결과를 **독립 에이전트가 처음부터 다시 유도해** 확인하고, 확인된 숫자만 V3 계획서의 근거로 들어간다.

**Tech Stack:** Python 3.12 (`.venv/bin/python`) · numpy 2.4.6 / scikit-learn 1.6.1 / pandas 2.2.3 · pytest 9.1.1 · 문서는 Markdown

**Spec:** `docs/superpowers/specs/2026-08-27-vocabulary-indexed-router-design.md` (특히 §3 축 2 · §6 순서 · §7 R3/R4)

## Global Constraints

- **Python 은 반드시 `.venv/bin/python`.** 🔴 **모든 pytest 호출에 `--ignore=src/respec/llm_service/test_propose.py` 를 붙인다** — 그 파일은 테스트가 아니라 import 시점에 `sys.exit(1)` 하는 스크립트이고, `ANTHROPIC_API_KEY` 가 있으면 수집 중에 **유료 API 호출을 발화시킨다.**
- **Julia 는 `julia +lts` (1.10), 항상 `--project=.`.** 이 계획은 Julia 를 건드리지 않는다.
- 🔴 **`git add` 는 언제나 명시 경로만.** 작업 트리에 **219개의 커밋 안 된 삭제**가 있다(다른 작업의 진행 중 상태다). `git add -A` / `git add .` / `git commit -a` 는 **금지**. 어기면 남의 작업을 커밋한다.
- 🔴 **라벨 파일을 수정하지 않는다.** `wm4spacecraft_manufacturing/oracle/out/oracle_dataset.jsonl` 은 읽기 전용이다. 이 계획의 어떤 태스크도 라벨을 생성·수정·삭제하지 않는다.
- 🔴 **`predict_delta_J` 를 쓰지 않는다** (설계서 §3). 그 뺄셈은 같은 instance 안에서 팔에 무관한 상수라 결정에 영향이 없다. conformal 은 **`predict_J`** 의 잔차를 쓴다.
- 🔴 **`surrogate_rank` 의 1순위를 top-1 으로 쓰지 않는다** (설계서 §3). `dspy_service.py:490-497` 이 `choose(rule=SURRO_RULE)` 의 `pick` 을 0번에 **고정**하므로 1순위가 `argmin Ĵ` 가 아니다. conformal 은 `Ĵ` 순서를 직접 쓴다.
- 🔴 **`nothing`/"못 쟀다" 를 `false`/"재서 아니었다" 로 뭉개지 않는다.** `q = ∞`(표본 부족)와 `q = 큰 수`(잔차가 큼)는 **다른 사실**이고 보고에서 구분한다.
- **진실 J 는 `objective.J_row` 하나에서만 온다.** 재구현 금지 — `e1_analyze.cost_lex_key_row` 는 `-J_row` 이고(실측 확인), 둘 다 같은 함수를 부른다.
- **어휘 단일 진실원은 `wm4spacecraft_manufacturing/core/action_registry.json`** — 현행 `v4-3arms`, 매크로 `0 NOOP` / `1 Replace` / `2 SwapBattery`. 리터럴 복붙 금지.
- 스레드는 `threadpool_limits(limits=1)` 로 묶는다. 공유 서버(56코어)에서 OpenMP 가 코어 수만큼 스레드를 띄우면 한 번의 적합이 0.58s → 132.6s 로 늘어난다(227배 실측).
- 파이썬 테스트는 소스 옆 `test_*.py`, `sys.path.insert(0, HERE)` 관용구를 따른다.

---

## 이 계획이 답하는 질문과, 답하지 않는 질문

| | |
|---|---|
| **답한다** | 축 2(conformal)를 **지금 지을 가치가 있는가.** R3·R4 의 실측값. |
| **답한다** | 그 측정 결과를 반영한 **V3 계획서** (폐루프 뒷절반). |
| **답하지 않는다** | 축 2 를 **짓지 않는다.** 이 계획은 재기만 한다. 프로덕션 라우터 코드를 건드리지 않는다. |
| **답하지 않는다** | V3 을 **실행하지 않는다.** 계획서까지다. |

🔴 **왜 재는 것이 먼저인가 (설계서 §7 R3 가 직접 시킨다):**

> known 사건의 escalation률이 α 근처인가. **0 이면 구간이 너무 넓어 축 2 가 아무것도 안 하는 것**이고, 그 사실을 짓기 전에 알아야 한다.

그리고 V1 계획서의 제약 한 줄 — *"축 2 는 반사실 라벨이 선행조건이라 별도 계획서다"* — 은 **두 가지를 뭉갠 것이다.** 폐루프가 **새 사건에서** 라벨을 키우는 것(V3)과, conformal 교정에 필요한 **같은 instance 의 팔별 잔차**(이미 있다)는 다른 것이다. 실측: 33행은 12 instance 에 팔 2~3개씩 붙어 있고(`arms_labeled` 필드 존재, 그룹당 행 수 `{3: 9, 2: 3}`), `SurrogateV2.fit` 이 요구하는 팔별 결과가 **이미 파일 안에 있다.** 그래서 설계서 §6 의 순서(축 2 가 다음)가 맞고 V1 계획서의 제약이 틀렸다.

⚠️ **그것이 "V2 를 지으라"는 뜻은 아니다.** 이 계획의 Task 2 가 그 판정을 낸다.

---

## File Structure

| 파일 | 책임 | 상태 |
|---|---|---|
| `wm4spacecraft_manufacturing/surrogate/conformal_feasibility.py` | LOIO OOF Ĵ · 잔차 · 유한표본 q · 구간 겹침 · 정직한 coverage. **순수 함수 + CLI** | **신규** |
| `wm4spacecraft_manufacturing/surrogate/test_conformal_feasibility.py` | 추정기 산술을 **합성 픽스처**로 못박는다 (실데이터 아님) | **신규** |
| `wm4spacecraft_manufacturing/surrogate/out/conformal_feasibility.json` | 실데이터 측정 산출물 (기계가 읽는 원본) | **신규** |
| `docs/superpowers/reports/2026-08-28-conformal-feasibility-measurement.md` | 그 측정의 사람용 보고 + R3/R4 판정 | **신규** |
| `docs/superpowers/reports/2026-08-28-conformal-feasibility-validation.md` | 독립 재유도 결과 (CONFIRMED/REFUTED) | **신규** |
| `docs/superpowers/reports/2026-08-28-v3-evidence.md` | V3 계획서가 딛는 실측 사실 시트 | **신규** |
| `docs/superpowers/plans/2026-08-28-closed-loop-counterfactual-labels-v3.md` | **V3 계획서** — 이 계획의 최종 산출물 | **신규** |

---

## 추정기 정의 — 여기서 한 번만 정한다

세 태스크가 같은 양을 재므로 정의를 여기 박는다. 태스크는 이 절을 참조한다.

**입력:** `rows` = `load_rows(ORACLE_DATASET)` 의 33행. `groups[i] = rows[i]["instance"]`.

**1. OOF 예측 (leave-one-INSTANCE-out).** instance 를 그룹으로 `LeaveOneGroupOut`. 폴드 `(tr, te)` 마다 `SurrogateV2().fit([rows[i] for i in tr])`, `oof[te] = model.predict_J([rows[i] for i in te])`.

🔴 **왜 OOF 인가:** 전량 적합 모델은 자기가 본 instance 를 암기한다. 배포 레인이 마주치는 것은 **처음 보는 사건**이므로 그 상황의 잔차를 재야 한다. 전량 적합 Ĵ 는 **보조 진단으로만** 같이 낸다.

**2. 잔차.** `res[i] = abs(oof[i] - objective.J_row(rows[i]))`. 절대잔차다(부호 없음) — 대칭 구간 `[Ĵ ± q]` 에 대응한다.

**3. 유한표본 분위수.** 잔차 집합 `S`(크기 `n`)와 `α` 에 대해
```
k = ceil((n + 1) * (1 - alpha))
q = sorted(S)[k - 1]   if k <= n
q = +inf               if k >  n      # 표본 부족 — "무한대"이지 "큰 수"가 아니다
```

**4. 격상 판정 (R3).** instance 마다 그 instance 의 OOF `Ĵ` 를 오름차순 정렬. `n_arms < 2` 면 퇴화 격상(`no_arms`/`single_arm`). 아니면 `gap = Ĵ_(2) - Ĵ_(1)`, **`gap <= 2q` 이면 격상**. `escalation_rate` = 격상 instance 수 / 전체 instance 수.

**5. 정직한 coverage (R4).** q 를 뽑은 표본으로 coverage 를 재면 정의상 `1-α` 라 순환논법이다. **instance 를 하나 빼고 q 를 만든다:** instance `i` 에 대해 `q_i` = `{res[j] : rows[j]["instance"] != i}` 의 분위수(`n = 그 집합의 크기`), `coverage_i` = instance `i` 의 행 중 `res <= q_i` 인 비율. `coverage_holdout` = 전체 33행에 대한 평균.

**두 갈래를 모두 낸다:**
- **pooled**: `q` 를 33개 잔차 전부에서 뽑는다 (격상 판정용, 4번)
- **leave-instance-out**: `q_i` 를 나머지 11 instance 에서 뽑는다 (coverage 용 5번, 그리고 격상 판정의 **정직판**도 같이 낸다)

**6. R3/R4 판정.**
- **R4 (멈춤 조건, spec §6-3):** `coverage_holdout < 1 - alpha - 0.05` 면 `R4 = FAIL`. FAIL 이면 그 α 에서의 축 2 는 근거가 없다.
- **R3 (손잡이가 손잡이인가):** α 를 훑었을 때 `escalation_rate` 가 **움직이는가**. 세 결론이 가능하다:
  - `escalation_rate ≈ 1.0` 전 구간 → 축 2 가 전부 격상. α 무의미.
  - `escalation_rate ≈ 0.0` 전 구간 → 축 2 가 영원히 침묵. 축 1 과 같은 병.
  - **`escalation_rate` 가 α 에 대해 상수** → α 는 손잡이가 아니라 **계단**이다. 이 경우 `2q` 의 도달 범위와 `gap` 분포를 겹쳐 그려 **왜** 안 움직이는지 보인다.

**α 격자:** `[0.01, 0.02, 0.03, 0.05, 0.1, 0.2, 0.3, 0.5, 0.7, 0.9, 0.95, 0.99]`. 🔴 0.5 를 넘는 값은 운용값이 아니라 **손잡이의 도달 범위**를 재려는 것이다 — 보고에서 그렇게 이름 붙인다.

---

### Task 1: 측정 도구 — `conformal_feasibility.py` + 합성 픽스처 테스트

**왜:** 재는 산술이 맞는지는 **실데이터로 확인할 수 없다** — 정답을 모르니까. 그래서 도구를 먼저 짓고, 그 산술을 손으로 답을 아는 **합성 픽스처**로 못박는다. 그 다음에야 실데이터를 넣는다. (레포 교훈: *"코드 읽기는 측정이 아니다"* — 그 역도 참이다. 검증 안 된 추정량으로 한 측정도 측정이 아니다.)

**Files:**
- Create: `wm4spacecraft_manufacturing/surrogate/conformal_feasibility.py`
- Create: `wm4spacecraft_manufacturing/surrogate/test_conformal_feasibility.py`

**Interfaces:**
- Consumes: `eval_surrogate_v2.load_rows`, `eval_surrogate_v2.group_by_instance`, `objective.J_row`, `surrogate_v2.SurrogateV2`
- Produces (Task 2 가 쓴다):
  - `conformal_quantile(residuals: Sequence[float], alpha: float) -> float` — `+inf` 가능
  - `oof_predictions(rows: list[dict]) -> np.ndarray` — 길이 `len(rows)`, LOIO
  - `escalation(oof: np.ndarray, rows: list[dict], q: float) -> dict` — `{"per_instance": {iid: {"n_arms","gap","escalate","reason"}}, "rate": float, "n": int}`
  - `coverage_leave_instance_out(res, rows, alpha) -> dict` — `{"coverage": float, "per_instance_q": {iid: float}}`
  - `measure(rows, alphas) -> dict` — 위를 전부 묶은 JSON 직렬화 가능한 dict
  - CLI: `python conformal_feasibility.py --labels <path> --out <json>`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`wm4spacecraft_manufacturing/surrogate/test_conformal_feasibility.py`:

```python
"""conformal 실현가능성 추정기의 **산술**을 합성 픽스처로 못박는다.

🔴 왜 합성인가: 실데이터에는 정답이 없다. 여기서 확인하는 것은 "측정값이 맞다"가 아니라
"추정량이 정의대로 계산된다"이다. 실데이터 측정은 Task 2 가 하고, 그 숫자의 재유도는
독립 에이전트(Task 3)가 한다. 이 파일이 그 둘 사이의 유일한 산술 보증이다.
"""
import math
import os
import sys

import numpy as np
import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "core"))

import conformal_feasibility as cf                            # noqa: E402


# ---- conformal_quantile: 유한표본 보정 k = ceil((n+1)(1-alpha)) --------------------------
def test_quantile_picks_kth_smallest():
    # n=9, alpha=0.1 -> k = ceil(10*0.9) = 9 -> 9번째로 작은 값 = 90
    res = [10, 20, 30, 40, 50, 60, 70, 80, 90]
    assert cf.conformal_quantile(res, 0.1) == 90


def test_quantile_is_infinite_when_sample_too_small():
    # n=9, alpha=0.05 -> k = ceil(10*0.95) = 10 > 9 -> 표본 부족
    # 🔴 이것은 "q 가 크다"가 아니라 "q 를 못 잰다"다. 큰 수로 뭉개지 않는다.
    assert cf.conformal_quantile([10, 20, 30, 40, 50, 60, 70, 80, 90], 0.05) == math.inf


def test_quantile_is_order_invariant():
    assert cf.conformal_quantile([90, 10, 50, 30, 70], 0.3) == \
           cf.conformal_quantile([10, 30, 50, 70, 90], 0.3)


def test_quantile_rejects_empty():
    with pytest.raises(ValueError):
        cf.conformal_quantile([], 0.1)


# ---- escalation: gap <= 2q -------------------------------------------------------------
def _rows(spec):
    """spec = {instance: [macro,...]} -> 최소 행들. Ĵ 는 oof 배열로 따로 준다."""
    out = []
    for iid, macros in spec.items():
        for m in macros:
            out.append({"instance": iid, "macro": m, "kind": "synthetic"})
    return out


def test_escalates_when_gap_below_two_q():
    rows = _rows({"i1": [0, 1]})
    oof = np.array([100.0, 105.0])          # gap = 5
    got = cf.escalation(oof, rows, q=3.0)   # 2q = 6 >= 5 -> 격상
    assert got["per_instance"]["i1"]["escalate"] is True
    assert got["per_instance"]["i1"]["gap"] == pytest.approx(5.0)
    assert got["rate"] == pytest.approx(1.0)


def test_does_not_escalate_when_gap_above_two_q():
    rows = _rows({"i1": [0, 1]})
    oof = np.array([100.0, 105.0])          # gap = 5
    got = cf.escalation(oof, rows, q=2.0)   # 2q = 4 < 5 -> 격상 안 함
    assert got["per_instance"]["i1"]["escalate"] is False
    assert got["rate"] == pytest.approx(0.0)


def test_gap_uses_top1_and_top2_not_file_order():
    # 파일 순서는 [큰, 작은, 중간]. top-1=10, top-2=20 이므로 gap=10.
    rows = _rows({"i1": [0, 1, 2]})
    oof = np.array([50.0, 10.0, 20.0])
    got = cf.escalation(oof, rows, q=100.0)
    assert got["per_instance"]["i1"]["gap"] == pytest.approx(10.0)


def test_single_arm_escalates_as_information_absence():
    # 🔴 팔이 하나면 확신이 아니라 **정보 부재**다 (설계서 §3).
    rows = _rows({"i1": [0]})
    got = cf.escalation(np.array([100.0]), rows, q=0.0)
    assert got["per_instance"]["i1"]["escalate"] is True
    assert got["per_instance"]["i1"]["reason"] == "single_arm"


def test_infinite_q_escalates_everything():
    rows = _rows({"i1": [0, 1], "i2": [0, 1, 2]})
    oof = np.array([1.0, 1e9, 1.0, 2.0, 3.0])
    got = cf.escalation(oof, rows, q=math.inf)
    assert got["rate"] == pytest.approx(1.0)


def test_rate_is_over_instances_not_rows():
    # i1: 3행 격상 / i2: 2행 격상 안 함 -> instance 기준 rate = 0.5 (행 기준이면 0.6)
    rows = _rows({"i1": [0, 1, 2], "i2": [0, 1]})
    oof = np.array([100.0, 101.0, 102.0, 0.0, 1000.0])
    got = cf.escalation(oof, rows, q=1.0)   # 2q = 2
    assert got["n"] == 2
    assert got["rate"] == pytest.approx(0.5)


# ---- coverage_leave_instance_out -------------------------------------------------------
def test_coverage_excludes_own_instance_from_quantile():
    # i1 의 잔차는 거대하다. 자기를 포함해 q 를 뽑으면 자기가 덮이지만,
    # 빼고 뽑으면 안 덮인다. 그 차이가 이 함수의 존재 이유다.
    rows = _rows({"i1": [0], "i2": [0], "i3": [0], "i4": [0], "i5": [0]})
    res = np.array([1000.0, 1.0, 2.0, 3.0, 4.0])
    got = cf.coverage_leave_instance_out(res, rows, alpha=0.5)
    # i1 의 q 는 {1,2,3,4} 에서 뽑히므로 1000 을 못 덮는다.
    assert got["per_instance_q"]["i1"] < 1000.0
    assert got["coverage"] < 1.0


def test_coverage_is_one_when_all_residuals_equal():
    rows = _rows({"i1": [0], "i2": [0], "i3": [0], "i4": [0], "i5": [0]})
    res = np.array([7.0, 7.0, 7.0, 7.0, 7.0])
    got = cf.coverage_leave_instance_out(res, rows, alpha=0.3)
    assert got["coverage"] == pytest.approx(1.0)
```

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

Run: `.venv/bin/python -m pytest wm4spacecraft_manufacturing/surrogate/test_conformal_feasibility.py -v --ignore=src/respec/llm_service/test_propose.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'conformal_feasibility'`

- [ ] **Step 3: 최소 구현을 쓴다**

`wm4spacecraft_manufacturing/surrogate/conformal_feasibility.py`:

```python
#!/usr/bin/env python3
"""축 2(conformal)의 **실현가능성**을 재는 도구 — 설계서 §7 의 R3·R4.

이 파일은 라우터가 아니다. 아무것도 격상시키지 않는다. `predict_J` 의 out-of-fold 잔차로
유한표본 분위수 q 를 만들고, 팔별 구간 `[Ĵ ± q]` 의 top-1/top-2 겹침을 세는 것이 전부다.

🔴 왜 out-of-fold 인가: 전량 적합 모델은 자기가 본 instance 를 암기한다. 배포 레인이 마주치는
것은 **처음 보는 사건**이므로 그 상황의 잔차를 재야 한다. 전량 적합 Ĵ 는 보조 진단이다.

🔴 `predict_delta_J` 를 쓰지 않는다 (설계서 §3): 같은 instance 안에서 빼는 값은 팔에 무관한
상수라 `argmin` 을 안 바꾸고, 구간 폭도 안 바꾼다. conformal 은 `predict_J` 를 직접 쓴다.

🔴 `surrogate_rank` 의 1순위를 top-1 으로 쓰지 않는다 (설계서 §3): `dspy_service.py:490-497`
이 `choose(rule=SURRO_RULE)` 의 `pick` 을 0번에 **고정**하므로 그 1순위는 `argmin Ĵ` 가
아니다. 여기서는 `Ĵ` 를 직접 정렬한다.
"""
import argparse
import json
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "core"))

import objective                                              # noqa: E402
from eval_surrogate_v2 import group_by_instance, load_rows    # noqa: E402
from surrogate_v2 import SurrogateV2                          # noqa: E402

from sklearn.model_selection import LeaveOneGroupOut
from threadpoolctl import threadpool_limits

# 손잡이의 **도달 범위**를 재는 격자다. 0.5 를 넘는 값은 운용값이 아니다 — 보고에서 그렇게
# 이름 붙인다. 0.01~0.03 구간을 촘촘히 두는 이유: n=33 에서 k=ceil(34(1-a)) 가 34 를 넘는
# 경계(alpha < 1/34 ≈ 0.0294)가 그 안에 있고, 그 경계에서 q 가 유한 -> 무한으로 튄다.
ALPHA_GRID = (0.01, 0.02, 0.03, 0.05, 0.1, 0.2, 0.3, 0.5, 0.7, 0.9, 0.95, 0.99)


def conformal_quantile(residuals, alpha):
    """유한표본 보정 분위수. k = ceil((n+1)(1-alpha)) 번째로 작은 잔차.

    🔴 `k > n` 이면 `+inf` 를 돌려준다 — **"q 가 크다"가 아니라 "표본이 모자라 q 를 못
    잰다"** 이고, 그 둘은 다른 사실이다. 큰 수로 뭉개면 보고가 거짓말한다.
    """
    s = np.sort(np.asarray(residuals, dtype=float))
    n = len(s)
    if n == 0:
        raise ValueError("잔차가 비었다 — q 를 정의할 수 없다. 0 으로 폴백하지 않는다.")
    k = math.ceil((n + 1) * (1.0 - float(alpha)))
    return math.inf if k > n else float(s[k - 1])


def oof_predictions(rows):
    """leave-one-INSTANCE-out out-of-fold `Ĵ`. 길이 == len(rows)."""
    groups = np.array([r["instance"] for r in rows])
    idx = np.arange(len(rows))
    oof = np.full(len(rows), np.nan)
    # 스레드를 1로 묶는다 (eval_surrogate_v2.run_folds 와 같은 이유, 227배 실측).
    with threadpool_limits(limits=1):
        for tr, te in LeaveOneGroupOut().split(idx, groups=groups):
            model = SurrogateV2().fit([rows[i] for i in tr])
            oof[te] = model.predict_J([rows[i] for i in te])
    if np.isnan(oof).any():
        raise RuntimeError("OOF 예측에 NaN 이 남았다 — 폴드가 모든 행을 덮지 않았다.")
    return oof


def true_J(rows):
    """진실 J. `objective.J_row` 하나에서만 온다 — 재구현 금지."""
    return np.array([float(objective.J_row(r)) for r in rows], dtype=float)


def escalation(oof, rows, q):
    """instance 마다 top-1/top-2 구간이 겹치는가. 반환 dict 는 JSON 직렬화 가능."""
    per = {}
    for iid, g in group_by_instance(rows).items():
        ii = [i for i, r in enumerate(rows) if r["instance"] == iid]
        s = np.sort(np.asarray(oof, dtype=float)[ii])
        n_arms = len(s)
        if n_arms == 0:
            per[iid] = dict(n_arms=0, gap=None, escalate=True, reason="no_arms")
        elif n_arms == 1:
            # 🔴 확신이 아니라 정보 부재다 (설계서 §3).
            per[iid] = dict(n_arms=1, gap=None, escalate=True, reason="single_arm")
        else:
            gap = float(s[1] - s[0])
            esc = bool(gap <= 2.0 * q)      # q=inf 이면 항상 True
            per[iid] = dict(n_arms=n_arms, gap=gap, escalate=esc,
                            reason="ambiguous" if esc else "confident")
    n = len(per)
    rate = float(sum(1 for v in per.values() if v["escalate"]) / n) if n else 0.0
    return {"per_instance": per, "rate": rate, "n": n}


def coverage_leave_instance_out(res, rows, alpha):
    """정직한 coverage: instance 를 하나 빼고 만든 q 로 그 instance 를 덮는가.

    🔴 q 를 뽑은 표본으로 coverage 를 재면 정의상 1-alpha 라 순환논법이다.
    """
    res = np.asarray(res, dtype=float)
    hits, qs = [], {}
    for iid in group_by_instance(rows):
        own = [i for i, r in enumerate(rows) if r["instance"] == iid]
        oth = [i for i, r in enumerate(rows) if r["instance"] != iid]
        q = conformal_quantile(res[oth], alpha)
        qs[iid] = q
        hits.extend(bool(res[i] <= q) for i in own)
    return {"coverage": float(np.mean(hits)) if hits else 0.0, "per_instance_q": qs}


def measure(rows, alphas=ALPHA_GRID):
    """R3/R4 를 alpha 격자에 대해 잰다. JSON 직렬화 가능한 dict."""
    oof = oof_predictions(rows)
    jt = true_J(rows)
    res = np.abs(oof - jt)

    by_inst = group_by_instance(rows)
    gaps = {}
    for iid in by_inst:
        s = np.sort(oof[[i for i, r in enumerate(rows) if r["instance"] == iid]])
        gaps[iid] = float(s[1] - s[0]) if len(s) >= 2 else None

    out = {
        "n_rows": len(rows), "n_instances": len(by_inst),
        "residual_summary": {
            "min": float(res.min()), "max": float(res.max()),
            "median": float(np.median(res)),
            "quantiles": {str(p): float(np.quantile(res, p))
                          for p in (0.5, 0.7, 0.8, 0.9, 0.95)},
        },
        "gap_distribution": gaps,
        "gap_sorted": sorted(v for v in gaps.values() if v is not None),
        "per_instance_kind": {iid: g[0]["kind"] for iid, g in by_inst.items()},
        "per_instance_argmin_macro": {
            iid: int(rows[min((i for i, r in enumerate(rows) if r["instance"] == iid),
                              key=lambda i: oof[i])]["macro"])
            for iid in by_inst},
        "alphas": [],
    }
    for a in alphas:
        q_pooled = conformal_quantile(res, a)
        esc_pooled = escalation(oof, rows, q_pooled)
        cov = coverage_leave_instance_out(res, rows, a)
        # 정직판 격상: instance 마다 자기를 뺀 q_i 를 쓴다.
        honest = {}
        for iid in by_inst:
            s = np.sort(oof[[i for i, r in enumerate(rows) if r["instance"] == iid]])
            qi = cov["per_instance_q"][iid]
            honest[iid] = bool(len(s) < 2 or (s[1] - s[0]) <= 2.0 * qi)
        need = 1.0 - a - 0.05
        out["alphas"].append({
            "alpha": a,
            "k": math.ceil((len(res) + 1) * (1.0 - a)), "n_residuals": len(res),
            "q_pooled": q_pooled,
            "two_q_pooled": (math.inf if math.isinf(q_pooled) else 2.0 * q_pooled),
            "escalation_rate_pooled": esc_pooled["rate"],
            "escalated_instances": sorted(i for i, v in esc_pooled["per_instance"].items()
                                          if v["escalate"]),
            "escalation_rate_honest": float(np.mean(list(honest.values()))),
            "coverage_holdout": cov["coverage"],
            "coverage_required": need,
            "R4": "PASS" if cov["coverage"] >= need else "FAIL",
        })
    return out


def _jsonable(o):
    if isinstance(o, float) and math.isinf(o):
        return "Infinity"
    if isinstance(o, dict):
        return {k: _jsonable(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [_jsonable(v) for v in o]
    return o


def main():
    import wm_datasets
    ap = argparse.ArgumentParser()
    ap.add_argument("--labels", default=wm_datasets.abspath(wm_datasets.ORACLE_DATASET))
    ap.add_argument("--out", default=os.path.join(HERE, "out", "conformal_feasibility.json"))
    args = ap.parse_args()

    rows, meta = load_rows(args.labels)
    res = measure(rows)
    res["meta"] = {k: meta[k] for k in ("path", "rows_after_fired_filter", "instances",
                                        "vocab", "objective_hash")}
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(_jsonable(res), f, indent=2, ensure_ascii=False, sort_keys=True)
    print("wrote %s" % args.out)
    for a in res["alphas"]:
        print("  alpha=%-5s k=%2d/%d q=%12s escalate=%.3f coverage=%.3f R4=%s"
              % (a["alpha"], a["k"], a["n_residuals"],
                 ("inf" if math.isinf(a["q_pooled"]) else "%.3f" % a["q_pooled"]),
                 a["escalation_rate_pooled"], a["coverage_holdout"], a["R4"]))


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: 테스트가 통과하는 것을 확인한다**

Run: `.venv/bin/python -m pytest wm4spacecraft_manufacturing/surrogate/test_conformal_feasibility.py -v --ignore=src/respec/llm_service/test_propose.py`
Expected: PASS — 13 passed

- [ ] **Step 5: 회귀가 없는지 확인한다**

Run: `.venv/bin/python -m pytest wm4spacecraft_manufacturing/surrogate/ -q --ignore=src/respec/llm_service/test_propose.py`
Expected: 이 태스크 전과 같은 pass/fail 수. 새 실패가 있으면 그것은 이 태스크의 회귀다.

- [ ] **Step 6: 커밋**

```bash
git add wm4spacecraft_manufacturing/surrogate/conformal_feasibility.py \
        wm4spacecraft_manufacturing/surrogate/test_conformal_feasibility.py
git commit -m "feat(conformal): 축 2 실현가능성 추정기를 짓고 산술을 합성 픽스처로 못박는다"
```

🔴 **`git add -A` 금지** (Global Constraints). 위 두 경로만 스테이징한다.

---

### Task 2: 실데이터 측정과 R3/R4 판정 보고

**왜:** 도구의 산술은 Task 1 이 보증했다. 이제 33행에 넣고, 나온 숫자가 **무엇을 뜻하는지** 쓴다. 이 보고가 "V2 를 지을 것인가"의 근거다.

⚠️ **이 태스크는 숫자를 만들고 해석하는 것이지, 미리 정해진 결론을 확인하는 것이 아니다.** 어떤 결과가 나오든 그대로 쓴다.

**Files:**
- Create: `wm4spacecraft_manufacturing/surrogate/out/conformal_feasibility.json` (도구가 만든다)
- Create: `docs/superpowers/reports/2026-08-28-conformal-feasibility-measurement.md`

**Interfaces:**
- Consumes: Task 1 의 `conformal_feasibility.py` CLI
- Produces: 위 두 파일. Task 3 이 JSON 을 재유도 대상으로 삼고, Task 5 가 보고의 결론을 인용한다.

- [ ] **Step 1: 측정을 돌린다**

Run:
```bash
.venv/bin/python wm4spacecraft_manufacturing/surrogate/conformal_feasibility.py \
  --out wm4spacecraft_manufacturing/surrogate/out/conformal_feasibility.json
```
Expected: `wrote ...` + alpha 격자 한 줄씩. 12 alpha 행. 오래 걸리면(>10분) 스레드 제한이
안 걸린 것이다 — `threadpool_limits` 를 확인한다.

- [ ] **Step 2: 세 가지 보조 사실을 같이 확인한다**

JSON 에서 직접 읽어 보고에 넣는다 (별도 코드 없이 `python -c` 로 읽는다):

1. **`gap_sorted` 에 빈 구간이 있는가.** 정렬된 gap 을 인접비(`g[i+1]/g[i]`)로 훑어 가장 큰 도약을 찾는다. 그 도약이 `two_q_pooled` 의 도달 범위 전체를 덮으면 **α 는 손잡이가 아니라 계단이다.**
2. **격상 집합이 `kind` 와 일치하는가.** `escalated_instances` 를 `per_instance_kind` 로 분류한다. 🔴 **완전히 일치하면 그것은 이 설계 전체에 대한 반증 후보다** — 설계서 §1 의 논증은 *"kind 색인은 경계를 얼린다"* 인데, 축 2 가 kind 와 같은 분할을 낸다면 kind 를 안 쓰고 kind 를 재현한 것이다.
3. **gap 의 봉우리가 완주 절벽에서 오는가.** 큰 gap 을 가진 instance 의 top-2 팔이 `complete == false` 인지 본다. 그렇다면 gap ≈ `C_fail` 이고, **J 가 이봉분포라 conformal 이 어느 봉우리 안에서도 해상도를 못 낸다**는 뜻이다.

- [ ] **Step 3: 보고서를 쓴다**

`docs/superpowers/reports/2026-08-28-conformal-feasibility-measurement.md`. 아래 구조를 그대로 따른다 — 숫자만 실측으로 채운다:

```markdown
# 축 2(conformal) 실현가능성 측정 — R3 · R4

**날짜:** 2026-08-28
**설계서:** `docs/superpowers/specs/2026-08-27-vocabulary-indexed-router-design.md` §3 · §7
**라벨셋:** <meta.path> — <rows> 행 / <instances> instance · vocab `<vocab>` · objective_hash `<hash>`
**도구:** `wm4spacecraft_manufacturing/surrogate/conformal_feasibility.py` (재현: 위 CLI 한 줄)
**원본:** `wm4spacecraft_manufacturing/surrogate/out/conformal_feasibility.json`

## 0. 한 줄 판정

<R3 PASS/FAIL · R4 PASS/FAIL · "V2 를 지을 가치가 있는가" 에 대한 한 문장>

## 1. 무엇을 어떻게 쟀나

<추정기 정의 6단계를 요약. OOF 인 이유, 정직한 coverage 인 이유.>

## 2. 실측 표

| α | k/n | q | 2q | 격상률(pooled) | 격상률(정직) | coverage | 필요 | R4 |
|---|---|---|---|---|---|---|---|---|
<12행>

## 3. gap 분포 — 왜 그 값이 나왔나

| instance | kind | n_arms | gap | argmin macro |
|---|---|---|---|---|
<instance 수만큼>

<인접비 도약 분석. 2q 의 도달 범위 [min, max] 와 gap 분포를 겹쳐서.>

## 4. R3 판정

<escalation_rate 가 α 에 대해 어떻게 움직이는가 / 안 움직이는가. 세 결론 중 어느 것인가.>

## 5. R4 판정

<coverage_holdout 대 1-α-0.05. 어느 α 에서 FAIL 인가.>

## 6. 🔴 이 측정이 못 말하는 것

- n = <instances> instance / <kinds> kind 다. 어떤 결론도 이 표본 크기를 넘지 못한다.
- `eval_surrogate_v2.duplicate_pairs` 가 보고하는 kind 간 쌍둥이 누출이 이 라벨셋에 있다
  (근거: 그 함수의 docstring). LOIO 는 같은 kind 의 다른 instance 를 이미 보므로
  **낙관적**이다.
- 이 측정은 **오늘의 surrogate 와 오늘의 라벨셋**에 대한 것이다. 둘 중 하나가 바뀌면 다시 재야 한다.

## 7. 그래서 다음은 무엇인가

<V2 를 지을 것인가에 대한 근거 있는 답. 그리고 그 답이 V3 에 무엇을 요구하는가.>
```

- [ ] **Step 4: 커밋**

```bash
git add wm4spacecraft_manufacturing/surrogate/out/conformal_feasibility.json \
        docs/superpowers/reports/2026-08-28-conformal-feasibility-measurement.md
git commit -m "measure(conformal): R3/R4 를 33행 라벨셋으로 재고 판정을 기록한다"
```

---

### Task 3: 독립 재유도 (검증 전용 에이전트)

**왜:** 이 레포의 기록된 교훈 두 개가 정확히 이 자리를 겨눈다 — *"계획서·보고서의 주장이 실제로 자주 틀린다"* 와 *"잘못된 추정량으로 한 측정도 뒤집혔다"*. Task 1 의 테스트는 **내 정의대로 계산됐는가**만 보증한다. **정의 자체가 맞는가**는 다른 코드로 다시 유도해야 안다.

🔴 **이 태스크의 에이전트는 Task 2 의 보고서를 읽기 전에 자기 숫자를 먼저 낸다.** 순서를 바꾸면 확인이 아니라 추인이다.

**Files:**
- Create: `docs/superpowers/reports/2026-08-28-conformal-feasibility-validation.md`
- 🔴 이 태스크는 **프로덕션 코드를 수정하지 않는다.** 재유도 스크립트는 스크래치에 쓰고 커밋하지 않는다.

**Interfaces:**
- Consumes: `docs/superpowers/specs/2026-08-27-vocabulary-indexed-router-design.md` §3 · §7, 라벨셋, `Task 2` 의 JSON
- Produces: 주장별 `CONFIRMED` / `REFUTED` / `UNVERIFIABLE` 판정

- [ ] **Step 1: 설계서만 읽고 추정기를 처음부터 다시 유도한다**

`conformal_feasibility.py` 를 **읽지 않은 채로** 설계서 §3 의 정의(잔차 → `(1−α)` 분위수 `q`,
유한표본 보정 `k = ceil((n+1)(1−α))`, 구간 `[Ĵ ± q]`, top-1/top-2 겹침)만 보고 자기 스크립트를
스크래치 디렉터리에 쓴다.

- [ ] **Step 2: 자기 숫자를 낸다**

α ∈ {0.05, 0.1, 0.3} 최소. 각각에 대해 `q`, `escalation_rate`, `coverage_holdout`.

- [ ] **Step 3: Task 2 의 JSON 과 대조하고 판정한다**

주장마다 한 줄:
- `q(α)` 값이 일치하는가
- `escalation_rate(α)` 가 일치하는가
- `coverage_holdout(α)` 가 일치하는가
- 보고서 §0 의 한 줄 판정이 자기 숫자에서도 따라 나오는가
- 보고서 §3 의 gap 분포 해석이 데이터에서 실제로 따라 나오는가
- 보고서 §6 의 한계 목록에 **빠진 한계**가 있는가

- [ ] **Step 4: 적대적 점검 — 추정량 자체를 공격한다**

다음 각각에 답한다. 답이 "그렇다"면 그것은 REFUTED 이거나 보고서에 빠진 한계다.

1. OOF 대신 전량 적합 Ĵ 를 쓰면 결론이 바뀌는가? (바뀌면 보고서가 그 민감도를 적어야 한다)
2. 절대잔차 대신 부호 있는 잔차 + 비대칭 구간을 쓰면 바뀌는가?
3. `escalation_rate` 를 instance 가 아니라 행 기준으로 세면 바뀌는가?
4. `coverage_holdout` 이 `1-α` 근처인 것은 잔차 교환가능성의 증거인가, 아니면 leave-instance-out
   구성이 자동으로 만들어내는 값인가? (구별할 수 있는 대조를 제시하라)
5. `gap` 이 이봉이라는 관찰이 **surrogate 의 성질**인가 **J 의 성질**(완주 절벽)인가?
   진실 J 의 gap 분포를 같이 재서 답하라.

- [ ] **Step 5: 판정 보고서를 쓴다**

`docs/superpowers/reports/2026-08-28-conformal-feasibility-validation.md`:

```markdown
# 축 2 실현가능성 측정 — 독립 재유도

**날짜:** 2026-08-28
**대상:** `docs/superpowers/reports/2026-08-28-conformal-feasibility-measurement.md`
**방법:** 설계서 §3 정의만 보고 독립 스크립트로 재유도한 뒤 대조.

## 판정 요약

| # | 주장 | 판정 | 근거 |
|---|---|---|---|

## 적대적 점검 5문

<각 문항의 답과 그 근거 숫자>

## 보고서에 추가돼야 할 것

<빠진 한계 · 틀린 해석 · 과장된 결론>
```

- [ ] **Step 6: 커밋**

```bash
git add docs/superpowers/reports/2026-08-28-conformal-feasibility-validation.md
git commit -m "verify(conformal): R3/R4 측정을 독립 재유도로 대조한다"
```

---

### Task 4: 측정 결과를 Task 2 보고서에 반영한다

**왜:** Task 3 이 REFUTED 나 빠진 한계를 냈다면 보고서가 틀린 채로 남는다. 그리고 V3 계획서는 이 보고서를 인용하므로, 틀린 채로 두면 **틀린 근거 위에 계획서를 쓴다** — 이 레포가 여러 번 당한 실패다.

⚠️ Task 3 이 전부 CONFIRMED 이고 빠진 한계가 없으면 이 태스크는 **"수정 없음"** 한 줄을 보고서 끝에 붙이고 끝난다. 없는 문제를 만들지 않는다.

**Files:**
- Modify: `docs/superpowers/reports/2026-08-28-conformal-feasibility-measurement.md`
- Modify (필요시): `wm4spacecraft_manufacturing/surrogate/conformal_feasibility.py` — 추정량 자체가 REFUTED 인 경우에만. 그 경우 Task 1 의 테스트도 같이 고치고 **측정을 다시 돌린다.**

**Interfaces:**
- Consumes: Task 3 의 판정 보고서
- Produces: 확정된 R3/R4 숫자. Task 6 이 이것만 인용한다.

- [ ] **Step 1: 판정을 하나씩 처리한다**

REFUTED 마다: 보고서의 어느 문장이 틀렸는지 적고, 고치고, 무엇을 근거로 고쳤는지 남긴다.
빠진 한계마다: §6 에 추가한다.

- [ ] **Step 2: 추정량이 바뀌었으면 다시 돌린다**

Run: Task 2 Step 1 의 CLI. 그리고 `.venv/bin/python -m pytest wm4spacecraft_manufacturing/surrogate/test_conformal_feasibility.py -v --ignore=src/respec/llm_service/test_propose.py`

- [ ] **Step 3: 보고서 끝에 검증 이력을 붙인다**

```markdown
## 부록 — 독립 검증 이력 (2026-08-28)

`docs/superpowers/reports/2026-08-28-conformal-feasibility-validation.md` 의 판정으로
<수정한 것 / 수정 없음>.
```

- [ ] **Step 4: 커밋**

```bash
git add docs/superpowers/reports/2026-08-28-conformal-feasibility-measurement.md
git commit -m "fix(report): 독립 검증 판정을 R3/R4 보고에 반영한다"
```

(추정량을 고쳤다면 `conformal_feasibility.py`, `test_conformal_feasibility.py`,
`out/conformal_feasibility.json` 도 같은 커밋에 명시 경로로 넣는다.)

---

### Task 5: V3 이 딛는 실측 사실 시트

**왜:** 이 레포의 기록된 교훈: *"계획서 주장은 실행 전에 재검증 — 시그니처 3건, 폐기된 숫자 인용, 자기 요약 오류"*. V3 계획서는 존재하지 않는 기전(반사실 라벨 생산자, 재학습 자동화)을 짓는 계획이므로 **오늘 무엇이 있고 무엇이 없는지**를 먼저 실측으로 고정해야 한다. 사실 시트가 없으면 계획서가 설계서의 산문을 그대로 베낀다.

**Files:**
- Create: `docs/superpowers/reports/2026-08-28-v3-evidence.md`
- 🔴 코드를 수정하지 않는다. 읽기·실행 전용.

**Interfaces:**
- Consumes: 레포 전체 (읽기)
- Produces: V3 계획서가 인용할 `file:line` 수준의 사실 목록

- [ ] **Step 1: 여덟 가지를 실측한다**

각 항목마다 **`file:line` 과 실행 출력**을 남긴다. "코드를 읽어 보니" 는 근거가 아니다.

1. **결정 행이 무엇을 적는가.** `tools/monitor/run_demo.jl` 의 결정 행 write site — 필드 목록. 집행된 팔만 적는가, 팔별로 적는가.
2. **`SurrogateV2.fit` 이 무엇을 요구하는가.** `surrogate_v2.py:86-105` 의 입력 계약 — 어떤 열이 필수인가. 그 열들이 결정 행에 있는가 (1번과 대조).
3. **`DS_DEVIATE_AT` / `DS_DEVIATE_ARM` 이 무엇을 하는가.** `tools/monitor/policy.jl:815-848`. 그 가드가 스스로 뭐라고 적는가. 반사실 rollout 에 쓸 수 있는가, 왜 못 쓰는가.
4. **라벨 생성 경로의 실제 진입점.** `wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl` 의 CLI/환경변수. 오늘 33행을 만든 명령이 무엇인가 (스크립트가 레포에 있는가). `regen_d20.sh` 를 찾아 어디서 멈추는지 확인한다.
5. **재적재 경로.** `dspy_service.py:336` 의 startup 훅. `SURRO_DATA` 를 다시 읽는 경로가 정말 없는가 — `_load_surrogate` 호출부를 전부 센다.
6. **`train_kinds` 도장의 write site 와 read site.** write 를 전부 세고(설계서는 4곳이라 한다 — 확인하라), `load_rows` 의 `meta` 에 없다는 것을 확인한다. **읽는 곳이 0인가.**
7. **`require_vocab_stamps` 의 소비처.** 설계서 부록은 6곳이라 한다. 세어서 확인하고 목록을 낸다. 각각이 `vocab` 을 **동등 비교**하는지 확인한다 (§5 의 "성장을 구조적으로 처벌한다" 주장의 근거).
8. **매크로 하나를 추가하려면 몇 파일을 고쳐야 하는가.** 설계서 §8 은 6파일이라 한다. `action_registry.json` 부터 시작해 실제로 세고, `macro_to_proposal`(`policy.jl:1286-1305`)이 빠지면 무슨 일이 나는지 확인한다.

- [ ] **Step 2: 사실 시트를 쓴다**

`docs/superpowers/reports/2026-08-28-v3-evidence.md`:

```markdown
# V3 이 딛는 실측 — 오늘 무엇이 있고 무엇이 없는가

**날짜:** 2026-08-28
**방법:** 전부 `file:line` + 실행 출력. 정적 추론은 근거로 안 친다.

## 요약 표

| # | 질문 | 실측 | 근거 |
|---|---|---|---|

## 1~8. <각 항목: 질문 · 명령 · 출력 · 결론>

## 🔴 설계서와 어긋나는 것

| 설계서 주장 | 실측 | 어느 쪽이 맞나 |
|---|---|---|
```

- [ ] **Step 3: 커밋**

```bash
git add docs/superpowers/reports/2026-08-28-v3-evidence.md
git commit -m "docs(v3): 폐루프 뒷절반이 딛는 실측 사실을 고정한다"
```

---

### Task 6: V3 계획서를 쓴다

**왜:** 이 계획의 최종 산출물. **경계가 실제로 움직이는가(R2)** 를 측정 가능하게 만드는 것이 V3 이고, 그것 없이는 축 1 이 죽은 코드로 남는다(V1 의 헤드라인 발견: 지원집합 = 어휘 전체라 축 1 은 오늘 구조적으로 침묵한다).

**Files:**
- Create: `docs/superpowers/plans/2026-08-28-closed-loop-counterfactual-labels-v3.md`

**Interfaces:**
- Consumes: Task 4 의 확정된 R3/R4 숫자 · Task 5 의 사실 시트 · 설계서 §4 ④⑤ · §5 · §8
- Produces: 실행 가능한 V3 계획서

- [ ] **Step 1: 계획서를 쓴다**

superpowers:writing-plans 의 형식을 따른다 (헤더 · Global Constraints · File Structure · Task 별 Files/Interfaces/Steps). 아래를 **반드시** 담는다:

1. **범위 선언.** V3 이 짓는 것: 설계서 §4 의 ④(반사실 라벨 생산자) · ⑤(재학습) · §5 의 `train_macros` 도장. 안 짓는 것: LLM → 새 매크로 id 경로(§8).

2. 🔴 **`train_macros` 도장은 소비처와 같은 커밋에 들어간다.** Task 5 의 6번이 `train_kinds` 가 4곳에서 찍히고 **아무도 안 읽은 채** kind 경계를 얼려 둔 것을 실측으로 보였다. V1 에서 `router_axis` 가 정확히 같은 실수를 반복할 뻔했고 F7 에서 소비처를 붙여 막았다. 계획서는 도장 태스크와 소비처 태스크를 **하나로 묶는다** — 두 태스크로 나누면 리뷰가 통과시킨다.

3. **측정 결과가 요구하는 것.** Task 4 의 R3/R4 판정이 라벨셋에 무엇을 요구하는지 계획서 안에 명시한다. (예: gap 분포에 중간대 질량이 없다면, 반사실 라벨 생산자는 **그 중간대를 만드는 팔**을 뽑아야 한다. 아무 팔이나 늘리면 같은 이봉분포가 커질 뿐이다.)

4. **R2 를 측정 가능하게 만드는 태스크를 반드시 포함한다.** 설계서 §7 R2: *"같은 사건이, 라벨 추가 + 재적재 전에는 `vocabulary_gap` 으로 dspy 로 가고 후에는 surrogate 로 가는가."* 이것이 V3 완료의 판정 기준이다.

5. **`psi()` 호출 시점 방어의 상태.** V1 Task 1 이 이미 고쳤는지 확인하고(Task 5 의 사실 시트), 고쳤으면 그 사실을 적고 다시 안 짓는다.

6. **`require_vocab_stamps` 의 동등 비교를 어떻게 통과할 것인가.** Task 5 의 7번이 준 소비처 목록 각각에 대해, 어휘가 자랄 때 무슨 일이 나는지와 계획이 그것을 어떻게 다루는지.

7. **Global Constraints** 에 이 계획서의 것을 물려받는다: `git add` 명시 경로 · venv · `--ignore=test_propose.py` · julia +lts · 어휘 단일 진실원.

- [ ] **Step 2: 자기 검토 (writing-plans 의 Self-Review)**

1. **Spec coverage:** 설계서 §4 ④⑤ · §5 · §7 R2 의 각 요구가 어느 태스크에 있는가. 빈 곳을 적는다.
2. **Placeholder scan:** "TBD" · "적절히 처리" · "Task N 과 유사" · 코드 없는 코드 스텝을 찾아 고친다.
3. **Type consistency:** 앞 태스크가 정의한 함수명·시그니처를 뒤 태스크가 그대로 쓰는가.

- [ ] **Step 3: 커밋**

```bash
git add docs/superpowers/plans/2026-08-28-closed-loop-counterfactual-labels-v3.md
git commit -m "plan(v3): 폐루프 뒷절반 계획서를 측정 결과 위에 쓴다"
```

---

### Task 7: V3 계획서 preflight 검증 (검증 전용 에이전트)

**왜:** 이 레포의 기록된 교훈이 직접 시킨다 — *"이 레포에서 계획서·보고서의 주장이 실제로 자주 틀린다(시그니처 3건, 폐기된 숫자 인용, 자기 요약 오류)"*. V1 도 preflight 검증 보고서를 남겼다(`2026-08-27-vocabulary-gap-router-v1-preflight-verification.md`) — 같은 관문을 통과시킨다.

**Files:**
- Create: `docs/superpowers/reports/2026-08-28-v3-preflight-verification.md`
- 🔴 코드도 계획서도 수정하지 않는다. 판정만 낸다.

**Interfaces:**
- Consumes: Task 6 의 V3 계획서
- Produces: 주장별 `CONFIRMED` / `REFUTED` / `UNVERIFIABLE`

- [ ] **Step 1: 계획서의 모든 사실 주장을 뽑는다**

`file:line` 인용 · 함수 시그니처 · 명령줄 · 인용된 숫자 · "오늘 이렇게 동작한다" 형태의 문장.

- [ ] **Step 2: 하나씩 확인한다**

- `file:line` 은 실제로 그 내용인가 (열어서 본다)
- 시그니처는 실제 시그니처와 같은가 (호출해 본다)
- 명령줄은 실제로 도는가 (돌려 본다 — 라벨 파일을 수정하는 명령은 **돌리지 않고** 근거만 확인한다)
- 인용된 숫자는 Task 4 의 확정 숫자와 같은가 (폐기된 숫자를 인용하지 않는가)

- [ ] **Step 3: 계획 내부 충돌을 훑는다**

- 파일을 공유하는 태스크 쌍마다: 한쪽이 만드는 것과 다른 쪽이 쓰는 것이 맞는가
- 태스크마다: 자기 텍스트가 자기와 모순되지 않는가 (지정한 테스트 대 지정한 코드)
- Global Constraints 를 어기는 태스크가 있는가
- 🔴 **`train_macros` 도장과 그 소비처가 정말 같은 태스크에 있는가** (Task 6 의 요구 2)

- [ ] **Step 4: 보고서를 쓰고 커밋한다**

```bash
git add docs/superpowers/reports/2026-08-28-v3-preflight-verification.md
git commit -m "verify(v3): V3 계획서의 사실 주장을 실행 전에 대조한다"
```

---

### Task 8: 검증 판정을 V3 계획서에 반영한다

**왜:** 검증 보고서가 커밋됐는데 계획서가 안 고쳐지면, 다음 세션이 **틀린 계획서를 읽고 실행한다.** 판정과 문서는 같이 움직여야 한다.

⚠️ 전부 CONFIRMED 면 계획서 끝에 검증 이력 한 줄만 붙이고 끝난다.

**Files:**
- Modify: `docs/superpowers/plans/2026-08-28-closed-loop-counterfactual-labels-v3.md`

**Interfaces:**
- Consumes: Task 7 의 판정
- Produces: 실행 가능한 최종 V3 계획서

- [ ] **Step 1: REFUTED 를 하나씩 고친다**

- [ ] **Step 2: 계획서 끝에 검증 이력을 붙인다**

```markdown
---

## 부록 — preflight 검증 (2026-08-28)

`docs/superpowers/reports/2026-08-28-v3-preflight-verification.md`.
판정: CONFIRMED <n> · REFUTED <n> · UNVERIFIABLE <n>. REFUTED 는 전부 본문에 반영했다.
```

- [ ] **Step 3: 커밋**

```bash
git add docs/superpowers/plans/2026-08-28-closed-loop-counterfactual-labels-v3.md
git commit -m "fix(plan): preflight 판정을 V3 계획서에 반영한다"
```

---

## 범위 밖 — 사용자가 별도로 열거한 30분짜리들

사용자 메시지가 *"지금 30분이면 닫히는 것들"* 로 따로 묶은 항목들이다. **이 계획의 (1)·(2) 가 끝난 뒤에만** 손댄다.

| # | 무엇 | 어디 |
|---|---|---|
| C1 | `surrogate_rank` 의 `UNSUPPORTED:` 접두사 누락 | `dspy_service.py:493-495` |
| C2 | `test_gate_ng2.py` 3 failed — 픽스처의 팔 id 3 이 `v4-3arms` 에 없다 (선존 결함) | `wm4spacecraft_manufacturing/smdp/` |
| C3 | CLAUDE.md 정정 4건 (`Pkg.test()` 254/1 · `v4-3arms` · `N44_PLUS78` 사망 · `require_vocab` 소비처 6곳) | `.claude/CLAUDE.md` |

C3 은 Task 5 의 6·7번이 실측을 내므로 그 뒤에 하는 것이 맞다.
