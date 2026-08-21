# OOD layer + replay buffer — 구현 계획 (계획서 B)

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `zone` 을 **학습 세계 밖**으로 빼내 진짜 OOD 로 만들고, decision-space 기준(split conformal)으로 그것을 탐지해 `L_prim` 으로 escalate 시키고, 그 결과를 표준 replay buffer 에 모아 닫힌 고리를 만든다.

**Architecture:** known 세계는 "제조 현장에서 일어나는 일은 로봇 고장과 배터리 방전 둘뿐" 이고 대응은 `Replace`·`SwapBattery` 둘뿐이다. zone 은 그 세계관 **밖에서** 도착하므로 매크로로는 손댈 수 없고, LLM 이 `L_prim`(MILP 제약 문법 + `TranslateBuild`)에서 대응을 **합성**해야 한다. 탐지는 임계값이 아니라 `Ĵ(a)` 예측구간의 겹침으로 하고, 위험 예산 α 하나가 그 자리를 대신한다. 버퍼는 SMDP 5튜플 `(s, a, R, τ, s′)` 의 고정 용량 순환 버퍼 + uniform sampling 이다.

**Tech Stack:** Julia 1.10 LTS, Python 3 (`.venv`, dspy 3.3.0), scikit-learn, HiGHS/JuMP

**Spec:** `docs/superpowers/specs/2026-08-20-reduced-state-ood-smdp-design.md` §5-7 · §6 · §7

## Global Constraints

- 🔴 **선행 조건: 계획서 A 의 Phase 4 가 끝나 있어야 한다.** escalation 이 `L_prim` 에 닿지 않으면 zone 은 "감춰 둔 매크로" 로 남고 이 계획 전체가 L1 을 재는 것이 된다.
- **Python 스택은 `.venv`**(`/home/chahj578/Construction_OODlayer/.venv/bin/python`, dspy 3.3.0). `.venv` 에 pytest 가 없다 — `PYTHONPATH=/usr/lib/python3/dist-packages ../.venv/bin/python -m pytest` 로 돈다.
- **dspy 3.3.0 은 `import dspy` 시점에 `numpy` 를 lazy 프록시로 갈아 끼운다.** `import numpy, sklearn.ensemble` 은 `import dspy` **앞에** 있어야 한다.
- **`DSPY_URL` 포트는 레포에 6종이 흩어져 있다.** 문서 숫자가 아니라 **띄운 uvicorn 포트**에 맞춘다. 스윕 전에 `/health` 를 손으로 확인하고, 스윕 후에는 `decisions[].enacted` 레인 히스토그램으로 **사후 확인**한다 — 서비스가 죽으면 surrogate·dspy 레인이 조용히 canonical 로 내려앉은 채 판이 다 돈다.
- **비교 런은 순차 실행**(HiGHS 경합 + 프로세스당 ~2.5 GB).
- **결정성의 단위는 디렉토리**(컴파일 캐시). 비교 런은 한 디렉토리에서 돈다.
- 🔴 **라벨 레인은 실행 레인과 같은 세계여야 한다.** `DS_HOTSWAP=1` 을 빠뜨리면 `fault` 발화율이 100% → 23% 로 **에러 없이** 샌다(2026-08-15 실측). 세계를 가르는 `DS_*` 손잡이는 산출물 도장에 찍고, 적재 지점에서 대조한다.
- **조용한 폴백 금지.** 도장 불일치는 `error()`/`sys.exit(1)` 로 죽는다. 필터링·remap 하지 않는다.
- **게이트를 짤 때는 음성 대조를 먼저 실측한다.** 초록불은 증거가 아니다.

**총 추정: 26 h 집중 작업 + 8~12 h 대기** (Phase 6~7).

---

## File Structure

| 파일 | 책임 | 태스크 |
|---|---|---|
| `wm4.../oracle/gen_oracle_dataset.jl` | `EP_KINDS` 기본값 + `train_kinds` 도장 | O1 |
| `wm4.../core/filter_labels.py` | `train_kinds` 축 검사 | O1 |
| `wm4.../surrogate/conformal.py` | **신규.** split conformal 교정·구간·escalation 규칙 | O2 |
| `src/respec/escalate.jl` | **신규.** 문지기를 우회해 `L_prim` 으로 가는 경로 | O3 |
| `src/respec/llm_service/schema.py` | 프롬프트 5항목 + 재사용 우선 규칙 | O4 |
| `wm4.../smdp/gate_ng6.py` | **신규.** leave-one-failure-type-out 7축 | O5 |
| `src/smdp/replay.jl` | **신규.** `ReplayBuffer` · `Transition` · `Stamp` | B1 |
| `tools/monitor/collect_counterfactuals.jl` | **신규.** 체크포인트 전수 롤아웃 | B2 |
| `wm4.../surrogate/retrain_loop.py` | **신규.** 재학습 + coverage 트리거 | B3 |

---

# Phase 6 — OOD 분리

## Task O1: 라벨을 known 3 kind 로 제한 + `train_kinds` 도장 — **3시간** (+ 라벨 생성 대기 ~2시간)

🔴 실측: `gen_oracle_dataset.jl:1086` 이

```julia
const EP_KINDS = [Symbol(s) for s in split(get(ENV, "DS_EP_KINDS", "fault,battery,zoneblk"), ",")]
```

로 **기본값에 zone kind 가 들어 있다.** 이걸 바꾸는 것이 이 태스크의 전부이고, 나머지는 **그 변경이 조용히 되돌려지지 않게** 도장을 다는 일이다.

**Files:**
- Modify: `wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl:1086` (기본값), 행 출력부(`train_kinds` 필드)
- Modify: `wm4spacecraft_manufacturing/core/filter_labels.py` (축 검사)
- Test: `wm4spacecraft_manufacturing/smdp/test_train_kinds.py` (신규)

**Interfaces:**
- Produces: 라벨 행마다 `train_kinds :: String` — `"fault,battery"` (정렬·쉼표 결합)

- [ ] **Step 1: 실패하는 시험을 쓴다**

```python
# wm4spacecraft_manufacturing/smdp/test_train_kinds.py
"""train_kinds 는 '이 행이 어느 세계에서 나왔는가' 를 나른다.

🔴 왜 새 축이 필요한가: 기존 도장 셋 중 어느 것도 이 축을 못 나른다.
  · objective_hash — 목적함수는 안 바뀐다
  · vocab          — 어휘도 안 바뀐다 (RelocateBuild 는 레지스트리에 그대로 있다)
  · dynamics       — hazard on/off 에만 묶여 있다
즉 zone 을 뺀 라벨셋과 안 뺀 라벨셋이 **완전히 같은 도장**을 단다. 그 둘이 섞이면
'zone 은 학습에 없다' 는 이 계획의 전제가 조용히 거짓이 된다.

  PYTHONPATH=/usr/lib/python3/dist-packages ../.venv/bin/python -m pytest \
      wm4spacecraft_manufacturing/smdp/test_train_kinds.py -q
"""
import json, os, subprocess, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "core"))
import filter_labels


def _src(name):
    here = os.path.join(os.path.dirname(__file__), "..", "oracle", name)
    return open(here, encoding="utf-8").read()


def test_default_kinds_exclude_zone():
    """기본값이 zone 을 빼야 한다. 손잡이로만 빼면 누가 잊는 순간 되돌아간다."""
    src = _src("gen_oracle_dataset.jl").replace(" ", "")
    assert '"DS_EP_KINDS","fault,battery"' in src, "EP_KINDS 기본값에 zone 이 남아 있다"


def test_rows_carry_train_kinds():
    src = _src("gen_oracle_dataset.jl")
    assert "train_kinds" in src, "행이 train_kinds 를 안 찍는다"


def test_filter_rejects_mixed_train_kinds():
    """🔴 섞인 파일은 통과가 아니라 **에러**여야 한다."""
    rows = [{"train_kinds": "fault,battery", "macro": 0},
            {"train_kinds": "fault,battery,zone", "macro": 0}]
    try:
        filter_labels.require_train_kinds(rows, "fault,battery")
    except Exception as e:
        assert "train_kinds" in str(e)
    else:
        raise AssertionError("섞인 train_kinds 가 조용히 통과했다")


def test_filter_accepts_uniform():
    rows = [{"train_kinds": "fault,battery", "macro": 0}] * 3
    assert filter_labels.require_train_kinds(rows, "fault,battery") is None
```

- [ ] **Step 2: 실패를 확인한다**

Run: `PYTHONPATH=/usr/lib/python3/dist-packages ../.venv/bin/python -m pytest wm4spacecraft_manufacturing/smdp/test_train_kinds.py -q`
Expected: 4 FAIL

- [ ] **Step 3: 기본값을 바꾸고 도장을 단다**

`gen_oracle_dataset.jl:1086`:

```julia
# 🔴 2026-08-21: zone 을 뺐다. zone 은 **test-only OOD** 이므로 학습 세계에 없어야 한다
#    (spec §6-1). 되돌리려면 그것은 어휘 변경이 아니라 **세계 변경**이고, train_kinds 도장이
#    갈리므로 기존 라벨셋 전부가 구세대로 재분류된다.
const EP_KINDS = [Symbol(s) for s in split(get(ENV, "DS_EP_KINDS", "fault,battery"), ",")]
const TRAIN_KINDS_STAMP = join(sort(String.(EP_KINDS)), ",")
```

행 출력부에 `train_kinds = TRAIN_KINDS_STAMP` 를 추가한다 (`objective_hash`·`vocab` 을 찍는 자리 옆).

`filter_labels.py` 에 추가한다:

```python
def require_train_kinds(rows, expected: str):
    """행의 train_kinds 가 전부 `expected` 인가. 🔴 아니면 죽는다.

    이 축이 필요한 이유(spec §6-2): zone 을 뺀 라벨셋과 안 뺀 라벨셋은
    objective_hash·vocab·dynamics **셋 다 같다**. 기존 도장으로는 구분이 원리적으로 불가능하다.
    섞이면 "zone 은 학습에 없다" 가 조용히 거짓이 되고, 그 거짓 위에서 OOD 실험 전체가 돈다.
    """
    seen = {r.get("train_kinds") for r in rows}
    if seen != {expected}:
        raise ValueError(
            f"train_kinds 가 기대와 다르다: 기대 {{{expected!r}}}, 관측 {seen!r}. "
            "구세대 라벨이 섞였다 — 필터링하지 않고 죽는다")
    return None
```

- [ ] **Step 4: 통과 확인 + 라벨을 다시 만든다**

Run:
```bash
PYTHONPATH=/usr/lib/python3/dist-packages ../.venv/bin/python -m pytest \
    wm4spacecraft_manufacturing/smdp/test_train_kinds.py -q
```
Expected: 4 passed

그 다음 known 3 case 로 라벨을 생성한다. ⚠️ **`DS_HOTSWAP=1` 을 반드시 켠다** — 안 켜면 `fault` 발화율이 100% → 23% 로 조용히 샌다. 생성 후 `hot_swap` 필드가 `{"enabled": true, "mode": "via_depot"}` 인지 확인한다.

- [ ] **Step 5: 🔴 음성 대조 — RelocateBuild 가 정말 0행인지 센다**

```bash
python3 -c "
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
from collections import Counter
print('train_kinds:', Counter(r.get('train_kinds') for r in rows))
print('macro:', Counter(r.get('macro') for r in rows))
" wm4spacecraft_manufacturing/oracle/out/<새라벨>.jsonl
```
Expected: `train_kinds` 는 한 값뿐이고 `macro` 히스토그램에 **2(RelocateBuild)가 없다.**
🔴 있으면 zone 이 어딘가로 새 들어온 것이고, 그 경로를 찾기 전에는 다음 태스크로 안 간다.

- [ ] **Step 6: 커밋**

```bash
git add wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl \
        wm4spacecraft_manufacturing/core/filter_labels.py \
        wm4spacecraft_manufacturing/smdp/test_train_kinds.py
git commit -m "feat(labels): zone leaves the training world -- new train_kinds stamp carries the axis"
```

---

## Task O2: split conformal — `Ĵ(a)` 예측구간과 escalation 규칙 — **4시간**

spec §6-3. severity 임계값을 **decision-space 기준**으로 갈아 끼운다.

**Files:**
- Create: `wm4spacecraft_manufacturing/surrogate/conformal.py`
- Test: `wm4spacecraft_manufacturing/surrogate/test_conformal.py` (신규)

**Interfaces:**
- Produces:
  - `calibrate(residuals: list[float], alpha: float) -> float` — 분위수 `q`
  - `interval(j_hat: float, q: float) -> tuple[float, float]`
  - `should_escalate(j_hats: dict[int, float], q: float) -> tuple[bool, str]` — top-1/top-2 구간 겹침

- [ ] **Step 1: 실패하는 시험을 쓴다**

```python
# wm4spacecraft_manufacturing/surrogate/test_conformal.py
"""split conformal — 임계값 대신 위험 예산 α.

🔴 이 파일이 지키는 성질 둘:
  (1) **coverage** — 교정에 안 쓴 잔차의 (1−α) 이상이 구간 안에 들어야 한다.
      안 들면 구간이 좁아 escalation 이 과소 발화한다.
  (2) **비항진성** — 구간이 무한히 넓으면 언제나 겹쳐서 always-escalate 가 된다.
      그건 탐지가 아니라 포기다.

  PYTHONPATH=/usr/lib/python3/dist-packages ../.venv/bin/python -m pytest \
      wm4spacecraft_manufacturing/surrogate/test_conformal.py -q
"""
import random
import conformal


def test_quantile_is_finite_and_monotone_in_alpha():
    res = [abs(random.gauss(0, 1)) for _ in range(1000)]
    q10 = conformal.calibrate(res, 0.10)
    q01 = conformal.calibrate(res, 0.01)
    assert 0 < q10 < q01 < float("inf")     # α 가 작을수록 구간이 넓다


def test_coverage_holds_on_held_out():
    random.seed(0)
    cal = [abs(random.gauss(0, 1)) for _ in range(500)]
    tst = [abs(random.gauss(0, 1)) for _ in range(500)]
    alpha = 0.1
    q = conformal.calibrate(cal, alpha)
    covered = sum(1 for r in tst if r <= q) / len(tst)
    assert covered >= 1 - alpha - 0.05, covered      # 유한표본 여유 5pp


def test_escalates_when_top_two_overlap():
    q = 1.0
    ok, why = conformal.should_escalate({0: -10.0, 1: -10.5, 2: -30.0}, q)
    assert ok and "overlap" in why


def test_does_not_escalate_when_separated():
    q = 0.1
    ok, why = conformal.should_escalate({0: -10.0, 1: -20.0, 2: -30.0}, q)
    assert not ok


def test_single_arm_escalates():
    """🔴 팔이 하나뿐이면 비교가 없다 — 그건 확신이 아니라 정보 부재다."""
    ok, why = conformal.should_escalate({0: -10.0}, 1.0)
    assert ok and "single" in why


def test_not_always_escalate():
    """🔴 음성 대조: 규칙이 항진적이면 known case 에서도 100% escalate 한다."""
    q = 0.5
    cases = [{0: -1.0, 1: -5.0}, {0: -1.0, 1: -1.2}, {0: -1.0, 1: -9.0}]
    fired = [conformal.should_escalate(c, q)[0] for c in cases]
    assert any(fired) and not all(fired)
```

- [ ] **Step 2: 실패를 확인한다**

Run: `PYTHONPATH=/usr/lib/python3/dist-packages ../.venv/bin/python -m pytest wm4spacecraft_manufacturing/surrogate/test_conformal.py -q`
Expected: 6 FAIL (`ModuleNotFoundError: conformal`)

- [ ] **Step 3: 구현한다**

```python
"""split conformal 로 Ĵ(a) 에 예측구간을 붙이고, 구간 겹침으로 escalation 을 정한다.

왜 임계값이 아닌가(spec §6-3): severity 임계값은 "얼마나 심한가" 를 묻는데, 정작 필요한 것은
"내가 고른 팔이 정말 최선인가" 다. 후자는 **결정 공간**의 질문이고, 구간이 겹치면 그 답은
"모른다" 다. 임계값이 사라지고 위험 예산 α 하나만 남는다.

⚠️ 이 모듈은 **교정 데이터가 known 세계에서만 와야 한다.** zone 행이 섞이면 그 잔차가 분위수를
부풀려 구간이 넓어지고, 정작 zone 에서 escalate 해야 할 때 "이 정도 오차는 정상" 이 된다.
`filter_labels.require_train_kinds` 로 먼저 막는다.
"""
import math


def calibrate(residuals, alpha: float) -> float:
    """|Ĵ − J| 잔차의 conformal 분위수. split conformal 의 유한표본 보정을 쓴다."""
    if not residuals:
        raise ValueError("calibrate: 교정 잔차가 비었다 — 구간을 지어내지 않는다")
    if not (0.0 < alpha < 1.0):
        raise ValueError(f"calibrate: alpha 는 (0,1) 이어야 한다 (받은 값: {alpha})")
    r = sorted(abs(x) for x in residuals)
    n = len(r)
    k = math.ceil((n + 1) * (1 - alpha))     # 유한표본 보정: (n+1) 이 요점이다
    return r[-1] if k > n else r[k - 1]


def interval(j_hat: float, q: float):
    return (j_hat - q, j_hat + q)


def should_escalate(j_hats, q: float):
    """top-1 과 top-2 의 구간이 겹치면 escalate.

    반환: (bool, 이유 문자열). 이유는 산출물에 그대로 실린다 — 나중에 "왜 escalate 했나" 를
    되물을 때 로그가 답을 들고 있어야 한다.
    """
    if not j_hats:
        return (True, "no_arms: 평가된 팔이 없다")
    if len(j_hats) == 1:
        return (True, "single_arm: 비교할 팔이 없다 — 확신이 아니라 정보 부재다")
    ranked = sorted(j_hats.items(), key=lambda kv: kv[1], reverse=True)  # Ĵ 는 −J 라 클수록 좋다
    (a1, v1), (a2, v2) = ranked[0], ranked[1]
    lo1, _hi1 = interval(v1, q)
    _lo2, hi2 = interval(v2, q)
    if lo1 <= hi2:
        return (True, f"overlap: arm{a1}[{lo1:.3f},..] vs arm{a2}[..,{hi2:.3f}] (q={q:.3f})")
    return (False, f"separated: gap={v1 - v2:.3f} > 2q={2 * q:.3f}")
```

- [ ] **Step 4: 통과 확인**

Run: `PYTHONPATH=/usr/lib/python3/dist-packages ../.venv/bin/python -m pytest wm4spacecraft_manufacturing/surrogate/test_conformal.py -q`
Expected: 6 passed

- [ ] **Step 5: 실제 라벨로 `q` 를 잰다**

O1 이 만든 known 라벨셋을 8:2 로 나눠 뒤쪽으로 `calibrate` 하고, `results/ood/conformal.json` 에 `{"alpha": 0.1, "q": …, "n_cal": …, "coverage_holdout": …}` 를 낸다.

🔴 `coverage_holdout < 1 − α − 0.05` 면 **여기서 멈춘다** — surrogate 의 잔차가 교환가능하지 않다는 뜻이고, 그 위에 세운 escalation 은 근거가 없다.

- [ ] **Step 6: 커밋**

```bash
git add wm4spacecraft_manufacturing/surrogate/conformal.py \
        wm4spacecraft_manufacturing/surrogate/test_conformal.py results/ood/conformal.json
git commit -m "feat(ood): split-conformal intervals on J-hat; escalate when top-1 and top-2 overlap"
```

---

## Task O3: escalation 경로 — 문지기를 우회해 `L_prim` 으로 — **3시간**

🔴 spec §6-4. `ood_mdp_shim.action_to_proposal` 이 `a in valid_actions(ctx) || return nothing` 으로 거른다. escalation 이 그 문을 지나면 **닫힌 4팔로 되떨어진다.**

**Files:**
- Create: `src/respec/escalate.jl`
- Modify: `src/ConstructionBots.jl` (export)
- Test: `test/respec_escalate.jl` (신규)

**Interfaces:**
- Consumes: `verify`·`verify_translate`(계획서 A C4), `maybe_respecify!`(A C1), `llm_bridge` 의 파서
- Produces: `escalate!(env, ctx; url, timeout) -> NamedTuple` — `(status, proposal, kinds, detail)`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/respec_escalate.jl
# 🔴 escalation 은 팔 번호를 안 고른다. RespecProposal 을 직접 만들어 verify → maybe_respecify!
#    로 간다. action_to_proposal 을 지나면 그 순간 4팔로 좁혀진다.
#   julia +lts --project=. test/respec_escalate.jl
using ConstructionBots, Test
const CB = ConstructionBots
include(joinpath(@__DIR__, "smdp_fixtures.jl"))

@testset "🔴 문지기를 안 지난다 (음성 대조)" begin
    # action_to_proposal 은 zone kind 에서 매크로 2 밖에 못 낸다. escalate! 는
    # 그 함수를 아예 안 부르므로, 문지기를 좁혀도 결과가 안 바뀌어야 한다.
    env, ctx = _zone_fixture()
    CB.VALID_ACTIONS_OVERRIDE[] = Dict(:zone => Int[0])   # 문지기를 NOOP 만으로 조인다
    r = CB.escalate!(env, ctx; url = _stub_llm_url())
    @test r.status === :enacted
    @test :TranslateBuild in r.kinds                      # 문지기가 막았다면 여기 못 온다
    CB.VALID_ACTIONS_OVERRIDE[] = nothing
end

@testset "검증에서 죽은 제안은 집행되지 않는다" begin
    env, ctx = _zone_fixture()
    before = _assembly_poses(env)
    r = CB.escalate!(env, ctx; url = _stub_llm_url(; delta = (0.0, 0.0)))
    @test r.status === :rejected
    @test _assembly_poses(env) == before                  # 세계가 안 바뀌었다
end

@testset "🔴 LLM 이 죽어 있으면 조용히 폴백하지 않는다" begin
    env, ctx = _zone_fixture()
    @test_throws ErrorException CB.escalate!(env, ctx; url = "http://127.0.0.1:1")
end

@testset "문법 제약도 통과한다" begin
    env, ctx = _fault_fixture()
    r = CB.escalate!(env, ctx; url = _stub_llm_url(; kind = "LinearConstraint"))
    @test r.status === :enacted
    @test :LinearConstraint in r.kinds
end
```

`_stub_llm_url(; kind, delta)` 는 `smdp_fixtures.jl` 에 두는 **로컬 스텁 서버**다 — 고정된 `{"constraints": [...], "rationale": "..."}` 를 돌려준다. 실제 LLM 을 시험에 매달지 않는다(비결정적이고 느리다).

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. test/respec_escalate.jl`
Expected: FAIL with `UndefVarError: escalate! not defined`

- [ ] **Step 3: 구현한다**

```julia
# =============================================================================
# escalate.jl — 닫힌 어휘로 못 푸는 사건에서 LLM 에게 **제약을 합성시키는** 경로.
#
# 🔴 `action_to_proposal` 을 **부르지 않는다.** 그 함수는 `a in valid_actions(ctx)` 로 거르는
#    문지기라, 지나가는 순간 4팔로 좁혀진다(CLAUDE.md: "팔 메뉴가 아니라 문지기다").
#    여기서는 LLM 이 낸 RespecProposal 을 그대로 verify → maybe_respecify! 로 보낸다.
# =============================================================================

"""
    escalate!(env, ctx; url, timeout = 30.0) -> (status, proposal, kinds, detail)

`status ∈ {:enacted, :partial, :rejected}`.

⚠️ **LLM 이 응답하지 않으면 죽는다.** 조용히 NOOP 으로 폴백하면 "escalation 이 아무것도 못
했다" 와 "escalation 이 안 돌았다" 가 한 결과로 합쳐진다 — 이 레포가 DSPy `/health` 에서
이미 데인 실패 모양이다.
"""
function escalate!(env, ctx; url::AbstractString, timeout::Float64 = 30.0)
    payload = build_escalation_prompt(env, ctx)      # O4 가 채운다
    raw = try
        llm_post(url, payload; timeout = timeout)
    catch e
        error("escalate!: LLM 응답 실패 ($(url)) — 조용히 폴백하지 않는다: $(e)")
    end
    proposal = parse_proposal(raw)                    # llm_bridge.jl 의 기존 파서
    isempty(proposal.constraints) &&
        return (status = :rejected, proposal = proposal, kinds = Symbol[],
                detail = "empty proposal")

    inv = build_invariant(env)
    v = verify(proposal, env, inv)
    v isa Reject &&
        return (status = :rejected, proposal = proposal,
                kinds = Symbol[nameof(typeof(c)) for c in proposal.constraints],
                detail = "verify: $(v.reason)")

    st = maybe_respecify!(env, proposal)              # 순차 집행(계획서 A C1)
    return (status = st === :admitted ? :enacted : st === :partial ? :partial : :rejected,
            proposal = proposal,
            kinds = Symbol[nameof(typeof(c)) for c in proposal.constraints],
            detail = string(LAST_ENACT_REPORT[]))
end
```

⚠️ `llm_post` · `parse_proposal` · `build_invariant` 의 실제 이름을
`grep -n "function.*post\|function parse\|function build_invariant" src/respec/llm_bridge.jl src/respec/verifier.jl` 로 확인한다.

- [ ] **Step 4: 통과 확인 + 커밋**

Run: `julia +lts --project=. test/respec_escalate.jl`
Expected: PASS

```bash
git add src/respec/escalate.jl src/ConstructionBots.jl test/respec_escalate.jl test/smdp_fixtures.jl
git commit -m "feat(ood): escalation bypasses the arm gatekeeper and synthesizes constraints instead"
```

---

## Task O4: 프롬프트 — `L_prim` 문법 + 재사용 우선 규칙 — **3시간**

spec §6-5 의 다섯 항목과 §5-7 의 D-8 규칙.

**Files:**
- Modify: `src/respec/llm_service/schema.py` (docstring), `src/respec/llm_bridge.jl` (`build_escalation_prompt`)
- Test: `src/respec/llm_service/test_prompt.py` (신규)

**Interfaces:**
- Produces: `build_escalation_prompt(env, ctx) -> Dict` — `KNOWN_MACROS` · `PRIMITIVES` · `ZONES` · `NODES` · `AGENTS` · `RULES` 섹션

- [ ] **Step 1: 실패하는 시험을 쓴다**

```python
# src/respec/llm_service/test_prompt.py
"""프롬프트가 spec §6-5 의 다섯 항목을 실제로 담는가.

🔴 이 시험이 없으면 프롬프트가 조용히 낡는다 — 문법을 추가해 놓고 LLM 에 안 알려 주면
"LLM 이 그 제약을 한 번도 안 냈다" 가 추론 실패로 오독된다.
"""
import prompt_fixtures    # 실제 env 에서 뽑아 둔 프롬프트 스냅샷


def test_declares_the_menu_may_be_insufficient():
    p = prompt_fixtures.escalation_prompt()
    assert "may not be enough" in p["RULES"] or "부족" in p["RULES"]


def test_states_reuse_first_rule():
    p = prompt_fixtures.escalation_prompt()
    assert "reuse" in p["RULES"].lower()
    assert "KNOWN_MACROS" in p


def test_lists_primitives_with_preconditions():
    p = prompt_fixtures.escalation_prompt()
    for k in ("LinearConstraint", "Disjunction", "TranslateBuild"):
        assert k in p["PRIMITIVES"], k
    assert "precondition" in p["PRIMITIVES"].lower() or "전제" in p["PRIMITIVES"]


def test_zones_carry_geometry_not_just_names():
    p = prompt_fixtures.escalation_prompt()
    z = p["ZONES"]
    assert z and all(("cx" in e and "cy" in e and "r" in e) for e in z), z


def test_says_constraints_compose():
    p = prompt_fixtures.escalation_prompt()
    assert "compose" in p["RULES"].lower() or "합성" in p["RULES"]


def test_grounding_is_enforced():
    """🔴 좌표를 지어내지 말라는 규약이 명시돼 있는가."""
    p = prompt_fixtures.escalation_prompt()
    assert "never invent" in p["RULES"].lower() or "지어내지" in p["RULES"]
```

- [ ] **Step 2: 실패를 확인한다**

Run: `PYTHONPATH=/usr/lib/python3/dist-packages ../.venv/bin/python -m pytest src/respec/llm_service/test_prompt.py -q`
Expected: 6 FAIL

- [ ] **Step 3: 프롬프트를 쓴다**

`build_escalation_prompt(env, ctx)` 가 여섯 섹션을 낸다:

| 섹션 | 내용 |
|---|---|
| `KNOWN_MACROS` | 오늘 학습된 매크로와 각각이 대응하는 사건. **재사용 후보** |
| `PRIMITIVES` | `LinearConstraint` · `Disjunction` · `TranslateBuild` 문법 + 각 전제조건(`schema.py` docstring 수준) |
| `ZONES` | 활성 구역의 `(key, cx, cy, r)` — **grounding 의 유일한 출처** |
| `NODES` | 참조 가능한 스케줄 노드 id (닫힌 노드는 뺀다 — `verify` 의 (2)가 어차피 거부한다) |
| `AGENTS` | 참조 가능한 로봇 id |
| `RULES` | 아래 넷 |

`RULES` 본문:

```
1. The known macros may not be enough for this event. If none of them addresses it,
   compose a proposal from PRIMITIVES instead of forcing a macro.
2. Reuse first: if a known macro does address this event, emit that macro. Do not
   synthesize when reuse works.
3. Constraints compose: `constraints` is a list. Emit more than one when the event
   needs more than one repair.
4. Ground every reference: echo ids and zone keys exactly as listed above.
   Never invent coordinates, node ids, or agent ids.
```

- [ ] **Step 4: `DSPY_PROGRAM` 을 못박는다**

🔴 컴파일된 `dspy_real_program_gpt4o.json` 은 **battery 전용이라 zone 어휘가 없다**(CLAUDE.md). 그걸로 zone 을 재면 어휘 밖 사건을 재는 것이다.

escalation 경로가 뜰 때 `DSPY_PROGRAM` 이 `__seed_only__` 가 아니면 **죽는다**:

```python
if os.environ.get("DSPY_PROGRAM", "__seed_only__") != "__seed_only__":
    raise RuntimeError(
        "escalation 은 __seed_only__ 로만 돈다. 컴파일된 프로그램은 battery 전용이라 "
        "zone 어휘가 없고, 그걸로 재면 추론 실패와 어휘 부재가 구분되지 않는다")
```

- [ ] **Step 5: 통과 확인 + 커밋**

```bash
PYTHONPATH=/usr/lib/python3/dist-packages ../.venv/bin/python -m pytest \
    src/respec/llm_service/test_prompt.py -q
git add src/respec/llm_service/schema.py src/respec/llm_bridge.jl \
        src/respec/llm_service/test_prompt.py src/respec/llm_service/prompt_fixtures.py
git commit -m "feat(ood): the escalation prompt carries the primitive grammar and the reuse-first rule"
```

---

## Task O5: 게이트 N-G6 — leave-one-failure-type-out — **4시간** (+ 스윕 대기 ~6~10시간)

spec §8-1 의 **일곱 축**. escalation률만 재면 안 된다.

**Files:**
- Create: `tools/monitor/run_ood_matrix.jl`, `wm4spacecraft_manufacturing/smdp/gate_ng6.py`

**Interfaces:**
- Consumes: `escalate!`(O3), `conformal`(O2), `_find_min_translation`(baseline)
- Produces: `results/ood/ng6_matrix.json`

- [ ] **Step 1: 스윕 설계를 못박는다**

7 case × 15 seed × 2 레인(`macro_only` · `escalating`) = 210 판. **순차 실행.**

각 결정마다 기록한다: `case` · `kind` · `escalated` · `escalate_reason` · `proposal_kinds` · `verify_status` · `enact_report` · `world_changed`(집행 전후 `state_hash` 비교) · `delta`(TranslateBuild 면) · `baseline_delta`.

🔴 `world_changed` 가 이 게이트의 심장이다. `enact_applied = true` 는 *"효과 지점에 도달했다"* 이지 *"세계가 바뀌었다"* 가 아니다.

- [ ] **Step 2: 게이트를 쓴다**

```python
#!/usr/bin/env python3
"""게이트 N-G6 — leave-one-failure-type-out. 일곱 축을 함께 본다(spec §8-1).

  1 kind 분포        zone 에서 TranslateBuild 가 나오는가
  2 verify 통과율    내긴 냈는데 게이트에서 죽는가
  3 world_changed    🔴 집행이 **실제로** 세계를 바꿨는가
  4 macro 음성 대조  같은 판을 4팔만으로 굴리면 NOOP 뿐인가
  5 known escalation known 3 case 의 발화율이 α 근처인가
  6 합성/재사용      🔴 양방향 대조 (spec §5-7)
  7 Δ vs baseline    LLM 의 변위가 _find_min_translation 대비 얼마나 좋은가

  python3 wm4spacecraft_manufacturing/smdp/gate_ng6.py results/ood/ng6_matrix.json 0.10
"""
import json, sys
from collections import Counter

KNOWN = {"fault", "battery", "fault_battery"}

def main(path, alpha):
    d = json.load(open(path))
    dec = d["decisions"]
    esc = [r for r in dec if r["lane"] == "escalating"]
    known = [r for r in esc if r["case"] in KNOWN]
    zone  = [r for r in esc if r["case"] == "zone"]
    ok = True

    # 1
    kinds = Counter(k for r in zone if r["escalated"] for k in r["proposal_kinds"])
    print(f"1 zone kind 분포: {dict(kinds)}")
    if kinds.get("TranslateBuild", 0) == 0:
        print("  FAIL: zone 에서 TranslateBuild 를 한 번도 안 냈다"); ok = False

    # 2
    fired = [r for r in zone if r["escalated"]]
    passed = [r for r in fired if r["verify_status"] == "admitted"]
    rate = len(passed) / max(len(fired), 1)
    print(f"2 verify 통과율: {len(passed)}/{len(fired)} = {rate:.1%}")
    if fired and rate == 0.0:
        print("  FAIL: 전부 검증에서 죽는다 — 문법이나 grounding 이 안 맞는다"); ok = False

    # 3  🔴
    changed = sum(1 for r in passed if r["world_changed"])
    print(f"3 world_changed: {changed}/{len(passed)}")
    if passed and changed == 0:
        print("  FAIL: 집행했다는데 세계가 한 번도 안 바뀌었다 — 무성 no-op"); ok = False

    # 4
    mac_zone = [r for r in dec if r["lane"] == "macro_only" and r["case"] == "zone"]
    macs = Counter(r["macro"] for r in mac_zone)
    print(f"4 macro_only zone 매크로 분포: {dict(macs)}")
    if set(macs) - {0}:
        print("  FAIL: 4팔 레인이 zone 에서 NOOP 아닌 팔을 골랐다 — zone 이 학습에서 안 빠졌다")
        ok = False

    # 5
    kr = sum(1 for r in known if r["escalated"]) / max(len(known), 1)
    zr = sum(1 for r in zone  if r["escalated"]) / max(len(zone), 1)
    print(f"5 escalation률: known={kr:.1%} (α={alpha:.0%})  zone={zr:.1%}")
    if kr > 3 * alpha:
        print("  FAIL: known 발화율이 α 의 3배를 넘는다 — conformal 미교정"); ok = False
    if zr <= kr:
        print("  FAIL: zone 발화율이 known 이하다 — 탐지가 작동하지 않는다"); ok = False

    # 6  🔴 양방향
    syn = lambda rs: sum(1 for r in rs if r["escalated"] and
                         any(k in ("LinearConstraint", "Disjunction", "TranslateBuild")
                             for k in r["proposal_kinds"])) / max(len(rs), 1)
    print(f"6 합성률: known={syn(known):.1%}  zone={syn(zone):.1%}")
    if syn(known) > 3 * alpha:
        print("  FAIL: known 에서 과잉 합성 — 재사용 우선 규칙이 안 먹는다"); ok = False
    if syn(zone) <= syn(known):
        print("  FAIL: zone 합성률이 known 이하 — 신설이 안 일어난다"); ok = False

    # 7
    ds = [(r["delta"], r["baseline_delta"]) for r in passed if r.get("delta")]
    if ds:
        ratios = [ (dx**2+dy**2)**0.5 / max((bx**2+by**2)**0.5, 1e-9)
                   for (dx,dy),(bx,by) in ds ]
        ratios.sort()
        print(f"7 |Δ_llm|/|Δ_baseline| 중앙={ratios[len(ratios)//2]:.2f} "
              f"min={ratios[0]:.2f} max={ratios[-1]:.2f}  (n={len(ratios)})")
        print("   ⚠️ 1.0 미만은 baseline 보다 적게 움직였다는 뜻 — 검증을 통과했다면 더 좋다")
    else:
        print("7 Δ 비교: 표본 없음 (TranslateBuild 가 통과한 적이 없다)")

    print("PASS" if ok else "FAIL")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1], float(sys.argv[2]) if len(sys.argv) > 2 else 0.10))
```

- [ ] **Step 3: 돌린다**

Run:
```bash
julia +lts --project=. tools/monitor/run_ood_matrix.jl        # 순차, ~6~10 h
python3 wm4spacecraft_manufacturing/smdp/gate_ng6.py results/ood/ng6_matrix.json 0.10
```
Expected: `PASS`

⚠️ 스윕 전에 `DSPY_URL` 의 `/health` 를 손으로 확인하고, 스윕 후에 `decisions[].enacted` 레인 히스토그램으로 **교차 레인 폴백 0** 을 사후 확인한다.

- [ ] **Step 4: 커밋**

```bash
git add tools/monitor/run_ood_matrix.jl wm4spacecraft_manufacturing/smdp/gate_ng6.py \
        results/ood/ng6_matrix.json
git commit -m "test(ood): leave-one-failure-type-out over seven axes, not just an escalation rate"
```

---

# Phase 7 — replay buffer

## Task B1: 표준 uniform replay buffer — **3시간**

spec §7. **층화 reservoir 도, 우선순위도 안 짓는다.** 기준선을 먼저 세운다.

**Files:**
- Create: `src/smdp/replay.jl`
- Modify: `src/smdp/mdp.jl`
- Test: `test/smdp_replay.jl` (신규)

**Interfaces:**
- Produces:
  - `Stamp(objective_hash::String, generation::String, vocab::String, train_kinds::String)`
  - `current_stamp() -> Stamp`
  - `Transition(s, a, R, tau, s_next, terminal, stamp)`
  - `ReplayBuffer(capacity::Int)`
  - `push_transition!(rb, tr) -> Nothing` — 🔴 도장 불일치면 죽는다
  - `sample_batch(rb, n; rng) -> Vector{Transition}` — uniform, 비복원
  - `Base.length(rb)`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/smdp_replay.jl
# 표준 순환 버퍼 + uniform sampling. 여기서 검사할 것은 **버퍼 자체**와 **도장 하드스톱**뿐이다.
#   julia +lts --project=. test/smdp_replay.jl
using ConstructionBots, Test, Random
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

_s() = CB.SimState(g = CB.GraphBlock(edges = Set([(1, 2)]), binding = Dict(1 => 7)),
                   geo = CB.GeoBlock(poses = Dict(1 => (0.0, 0.0, 0.0)),
                                     zones = Dict{Symbol,NTuple{3,Float64}}()),
                   fleet = Dict(7 => CB.RobotRec(soc = 0.9, usage_s = 1.0)),
                   prog = CB.ProgBlock(closed = Set{Int}()))
_tr(a; stamp = CB.current_stamp()) =
    CB.Transition(_s(), a, -1.0, 2.0, _s(), false, stamp)

@testset "순환 버퍼가 오래된 것부터 덮어쓴다" begin
    rb = CB.ReplayBuffer(3)
    for a in 0:4; CB.push_transition!(rb, _tr(a)); end
    @test length(rb) == 3
    @test Set(t.a for t in CB.sample_batch(rb, 3; rng = MersenneTwister(1))) == Set([2, 3, 4])
end

@testset "uniform sampling 은 비복원이고 재현된다" begin
    rb = CB.ReplayBuffer(100)
    for a in 1:50; CB.push_transition!(rb, _tr(a)); end
    b1 = CB.sample_batch(rb, 10; rng = MersenneTwister(7))
    b2 = CB.sample_batch(rb, 10; rng = MersenneTwister(7))
    @test [t.a for t in b1] == [t.a for t in b2]
    @test length(unique(t.a for t in b1)) == 10
end

@testset "🔴 세대 도장이 다르면 죽는다 (필터링하지 않는다)" begin
    rb = CB.ReplayBuffer(10)
    stale = CB.Stamp("deadbeef", "2026-08-19-old", "v2-6arms", "fault,battery,zone")
    @test_throws ErrorException CB.push_transition!(rb, _tr(0; stamp = stale))
    @test length(rb) == 0                     # 부분 적재도 안 된다
end

@testset "🔴 음성 대조 — 도장 검사가 항진적이 아니다" begin
    rb = CB.ReplayBuffer(10)
    CB.push_transition!(rb, _tr(0))           # 현행 도장은 통과한다
    @test length(rb) == 1
    # 네 축 각각이 단독으로 거부를 만든다
    cur = CB.current_stamp()
    for f in (:objective_hash, :generation, :vocab, :train_kinds)
        bad = CB.Stamp((k === f ? "XX" : getfield(cur, k) for k in fieldnames(CB.Stamp))...)
        @test_throws ErrorException CB.push_transition!(rb, _tr(1; stamp = bad))
    end
end

@testset "빈 버퍼에서 표집하면 죽는다" begin
    @test_throws ErrorException CB.sample_batch(CB.ReplayBuffer(5), 1; rng = MersenneTwister(1))
end
```

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. test/smdp_replay.jl`
Expected: FAIL with `UndefVarError: ReplayBuffer not defined`

- [ ] **Step 3: 구현한다**

```julia
# =============================================================================
# replay.jl — spec §7. **표준 uniform replay buffer.**
#
# ⛔ 이 세대에 안 짓는 것 (전부 ablation 후보로 격하):
#    층화 reservoir(event type × severity) · |Ĵ−실현 J| 우선순위 · instance 키 dict ·
#    pairwise 선호 환원.
#    이유 하나: **기준선 없이 복잡한 쪽으로 바로 가면 그 복잡도가 무엇을 사는지 영영 모른다.**
#
# 🔴 세대 도장이 버퍼에서 가장 조용하게 샌다. 동역학이 갈린 뒤에도 옛 transition 이 남아
#    있으면 **한 minibatch 안에 두 세계가 섞이고**, 에러 없이 학습 곡선으로만 드러난다.
# =============================================================================

using Random: randperm      # sample_batch 가 쓴다. mdp.jl 로드 시점에 없으면 UndefVarError 다

struct Stamp
    objective_hash::String
    generation::String
    vocab::String
    train_kinds::String
end

"""O1 의 `EP_KINDS` 도장과 **같은 값**이어야 한다. 갈리면 버퍼가 라벨셋과 다른 세계를 든다."""
const TRAIN_KINDS = Ref("fault,battery")

"""현행 도장. 네 축 전부 **파일에서 읽는다** — 여기서 리터럴을 쓰지 않는다."""
function current_stamp()
    c = Objective.load()
    return Stamp(String(Objective.objective_hash(c)), String(c["generation"]),
                 String(ActionRegistry.VOCAB), String(TRAIN_KINDS[]))
end

struct Transition
    s::SimState
    a::Int                  # L_macro 0..3, escalation 이면 -1 (proposal 은 meta 에)
    R::Float64
    tau::Float64
    s_next::SimState
    terminal::Bool
    stamp::Stamp
end

mutable struct ReplayBuffer
    capacity::Int
    data::Vector{Transition}
    idx::Int
    full::Bool
    ReplayBuffer(capacity::Int) = capacity > 0 ?
        new(capacity, Vector{Transition}(undef, capacity), 0, false) :
        error("ReplayBuffer: capacity 는 양수여야 한다")
end

Base.length(rb::ReplayBuffer) = rb.full ? rb.capacity : rb.idx

"""
    push_transition!(rb, tr)

🔴 도장이 현행과 다르면 **죽는다.** 필터링·remap 하지 않는다 — 그러면 낡은 행이 신세대로
위장한다(이 레포가 `value.json`·`grid_spec.json` 에서 반복해 데인 실패 모양).
"""
function push_transition!(rb::ReplayBuffer, tr::Transition)
    cur = current_stamp()
    tr.stamp == cur || error(
        "push_transition!: 세대 도장이 다르다.\n  기대: $(cur)\n  받음: $(tr.stamp)\n" *
        "세대가 갈렸으면 버퍼를 비울 것 — 한 minibatch 에 두 세계가 섞이면 에러 없이 " *
        "학습 곡선으로만 샌다")
    rb.idx = rb.idx % rb.capacity + 1
    rb.data[rb.idx] = tr
    rb.idx == rb.capacity && (rb.full = true)
    return nothing
end

"""uniform, 비복원. 버퍼가 비었거나 `n` 이 크면 죽는다."""
function sample_batch(rb::ReplayBuffer, n::Int; rng)
    m = length(rb)
    m > 0 || error("sample_batch: 버퍼가 비었다")
    n <= m || error("sample_batch: n=$(n) > 버퍼 크기 $(m)")
    return [rb.data[i] for i in randperm(rng, m)[1:n]]
end

"세대가 갈렸을 때. 비우는 것이 필터링보다 안전하다."
clear!(rb::ReplayBuffer) = (rb.idx = 0; rb.full = false; nothing)
```

- [ ] **Step 4: 로더 등록 + 통과 확인**

`src/smdp/mdp.jl` 에 `include("replay.jl")` 를 `generative.jl` 다음에 추가한다.

Run: `julia +lts --project=. test/smdp_replay.jl`
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add src/smdp/replay.jl src/smdp/mdp.jl test/smdp_replay.jl
git commit -m "feat(smdp): standard uniform replay buffer with a hard stop on generation stamps"
```

---

## Task B2: counterfactual 적재 — **4시간** (+ 실행 대기 ~2시간)

랩미팅 합의 #3. 체크포인트에서 **팔 전수** 롤아웃한다. RW 의 *"exploration 용 stochasticity 가 필요한가"* 도 여기서 닫힌다 — 확률로 넣는 대신 전수로 넣는다.

**Files:**
- Create: `tools/monitor/collect_counterfactuals.jl`
- Test: `test/smdp_counterfactual.jl` (신규)

**Interfaces:**
- Consumes: `generate`(계획서 A T12), `push_transition!`(B1)
- Produces: `results/ood/counterfactuals.jsonl` + 적재된 `ReplayBuffer`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/smdp_counterfactual.jl
# 🔴 네 롤아웃은 **같은 시드·같은 월드**에서 갈라져야 한다. 라벨 레인이 실행 레인과 세계가
#    갈려 fault 발화율이 100% → 23% 로 조용히 샌 적이 있다(DS_HOTSWAP 하나 빠뜨려서).
#   julia +lts --project=. test/smdp_counterfactual.jl
using ConstructionBots, Test, Random
const CB = ConstructionBots
include(joinpath(@__DIR__, "smdp_fixtures.jl"))

@testset "체크포인트에서 팔 전수가 나온다" begin
    trs = CB.collect_counterfactuals(_fault_fixture; seed = 11)
    @test Set(t.a for t in trs) == Set(CB.legal_actions_kind(:fault))
    @test all(t -> t.tau > 0.0, trs)
end

@testset "🔴 같은 s 에서 갈라졌다" begin
    trs = CB.collect_counterfactuals(_fault_fixture; seed = 11)
    @test length(unique(CB.state_hash(t.s) for t in trs)) == 1
end

@testset "🔴 세계 도장이 같다 (음성 대조)" begin
    trs = CB.collect_counterfactuals(_fault_fixture; seed = 11)
    @test length(unique(t.stamp for t in trs)) == 1
    @test first(trs).stamp == CB.current_stamp()
end

@testset "🔴 팔이 서로 다른 결과를 낸다" begin
    # 전부 같으면 그 체크포인트는 정보를 안 나른다. 조합 팔 5·6 이 정보량 0 이던 실패 모양.
    trs = CB.collect_counterfactuals(_fault_fixture; seed = 11)
    @test length(unique(CB.state_hash(t.s_next) for t in trs)) > 1
end

@testset "같은 시드면 재현된다" begin
    a = CB.collect_counterfactuals(_fault_fixture; seed = 5)
    b = CB.collect_counterfactuals(_fault_fixture; seed = 5)
    @test [(t.a, t.R, t.tau) for t in a] == [(t.a, t.R, t.tau) for t in b]
end
```

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. test/smdp_counterfactual.jl`
Expected: FAIL with `UndefVarError: collect_counterfactuals not defined`

- [ ] **Step 3: 구현한다**

```julia
"""
    collect_counterfactuals(fixture; seed) -> Vector{Transition}

한 체크포인트에서 **legal 한 팔 전부**를 굴려 transition 을 만든다.

🔴 갈래마다 `fixture()` 를 **새로 만든다.** 한 env 를 재사용하면 첫 팔의 집행이 남아 다음
팔이 다른 세계에서 출발한다. `deepcopy` 로는 부족하다 — RVO2 가 프로세스 전역이라
격리되지 않는다(계획서 A T11 의 `rvo_rebuild!` 가 그래서 있다).

⚠️ 네 갈래의 `s` 가 바이트 동일한지 **단언한다.** 다르면 그건 counterfactual 이 아니다.
"""
function collect_counterfactuals(fixture; seed::Int)
    out = Transition[]
    s_ref = nothing
    for a in legal_actions_kind(:fault)          # ctx 의 kind 로 바꿔 부른다
        env, ctx = fixture()
        s = simstate_of(env)
        s_ref === nothing && (s_ref = s)
        state_hash(s) == state_hash(s_ref) || error(
            "collect_counterfactuals: 갈래 $(a) 의 출발 상태가 다르다 — 같은 시드·같은 월드가 " *
            "아니면 counterfactual 라벨이 아니다")
        bp = BATTERY_FLEET[].params
        s2, R, τ, ev = generate(s, env, ctx, a, HazardParams(), bp, MersenneTwister(seed))
        push!(out, Transition(s, a, R, τ, s2, ev[1] === :terminal, current_stamp()))
    end
    return out
end
```

- [ ] **Step 4: 수집 스크립트를 쓰고 돌린다**

`tools/monitor/collect_counterfactuals.jl` 이 known 3 case × 20 seed 에서 체크포인트마다 위 함수를 부르고, 결과를 `ReplayBuffer` 에 적재하면서 `results/ood/counterfactuals.jsonl` 로도 낸다. **순차 실행.**

Run: `julia +lts --project=. tools/monitor/collect_counterfactuals.jl`

- [ ] **Step 5: 🔴 적재 결과를 음성 대조한다**

```bash
python3 -c "
import json,sys
from collections import Counter
rows=[json.loads(l) for l in open(sys.argv[1])]
print('n:', len(rows))
print('stamp 유일성:', len({(r['objective_hash'],r['generation'],r['vocab'],r['train_kinds']) for r in rows}))
print('팔 분포:', Counter(r['a'] for r in rows))
same = sum(1 for r in rows if r['s_hash'] == r['s_next_hash'])
print('s == s_next 인 행:', same, '(전부면 아무 팔도 세계를 안 바꾼 것)')
" results/ood/counterfactuals.jsonl
```
Expected: 도장 유일성 **1**, 팔 분포가 고르고, `s == s_next` 가 전부는 아니다.

- [ ] **Step 6: 커밋**

```bash
git add tools/monitor/collect_counterfactuals.jl test/smdp_counterfactual.jl \
        results/ood/counterfactuals.jsonl
git commit -m "feat(ood): counterfactual labels -- every legal arm from one checkpoint, same world"
```

---

## Task B3: 재학습 루프 + coverage 트리거 — **5시간** (+ 실행 대기 ~2시간)

**Files:**
- Create: `wm4spacecraft_manufacturing/surrogate/retrain_loop.py`
- Test: `wm4spacecraft_manufacturing/surrogate/test_retrain_loop.py` (신규)

**Interfaces:**
- Consumes: `conformal`(O2), 버퍼 덤프(B2)
- Produces:
  - `coverage(residuals, q) -> float`
  - `should_retrain(cov, alpha, slack=0.05) -> bool`
  - `run_episode_loop(n_episodes, ...) -> list[dict]` — 에피소드마다 `{escalation_rate, coverage, n_buffer, retrained}`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```python
# wm4spacecraft_manufacturing/surrogate/test_retrain_loop.py
"""재학습 트리거는 **conformal coverage 하락**이다 — 에피소드 수가 아니다.

🔴 왜: 고정 주기로 재학습하면 "아직 안 배웠는데 재학습" 과 "이미 배웠는데 또 재학습" 을
구분하지 못하고, 논문 그림(에피소드 대비 escalation률 감소)이 재학습 주기의 아티팩트가 된다.
"""
import retrain_loop as R


def test_coverage_is_a_fraction():
    assert R.coverage([0.1, 0.2, 5.0], 1.0) == 2 / 3


def test_triggers_only_below_target():
    assert not R.should_retrain(0.92, alpha=0.10)          # 목표 0.90 위 → 유지
    assert not R.should_retrain(0.86, alpha=0.10)          # slack 안 → 유지
    assert R.should_retrain(0.70, alpha=0.10)              # 아래 → 재학습


def test_no_retrain_on_empty_evidence():
    """🔴 표본이 없으면 재학습하지 않는다 — 0/0 을 0.0 으로 읽으면 매 에피소드 재학습한다."""
    try:
        R.coverage([], 1.0)
    except ValueError:
        pass
    else:
        raise AssertionError("빈 잔차에서 coverage 를 지어냈다")


def test_loop_records_the_headline_curve():
    hist = R.run_episode_loop(3, dry_run=True)
    assert len(hist) == 3
    for h in hist:
        assert {"escalation_rate", "coverage", "n_buffer", "retrained"} <= set(h)


def test_stamp_mismatch_is_fatal():
    """🔴 버퍼에 옛 세대가 섞이면 학습이 아니라 에러다."""
    try:
        R.load_buffer([{"generation": "old"}], expected_generation="new")
    except ValueError as e:
        assert "generation" in str(e)
    else:
        raise AssertionError("세대가 섞였는데 조용히 통과했다")
```

- [ ] **Step 2: 실패를 확인한다**

Run: `PYTHONPATH=/usr/lib/python3/dist-packages ../.venv/bin/python -m pytest wm4spacecraft_manufacturing/surrogate/test_retrain_loop.py -q`
Expected: 5 FAIL

- [ ] **Step 3: 구현한다**

```python
"""닫힌 고리: 에피소드를 굴리고 → counterfactual 을 버퍼에 넣고 → coverage 가 떨어지면
재적합한다. 논문 헤드라인 그림이 이 루프의 산출물이다 — **에피소드 수 대비 escalation률**.

⚠️ 재학습은 `sample_batch` 로 uniform 표집한 배치로 한다. 층화·우선순위는 이 세대에 없다
(spec §7-2). 그 둘을 넣고 싶으면 먼저 **이 곡선을 기준선으로** 재고 나서 비교한다.
"""
import json


def coverage(residuals, q: float) -> float:
    if not residuals:
        raise ValueError("coverage: 잔차가 비었다 — 0/0 을 0.0 으로 읽으면 매 에피소드 재학습한다")
    return sum(1 for r in residuals if abs(r) <= q) / len(residuals)


def should_retrain(cov: float, alpha: float, slack: float = 0.05) -> bool:
    """목표는 1−α. `slack` 만큼은 유한표본 흔들림으로 보고 넘긴다."""
    return cov < (1.0 - alpha - slack)


def load_buffer(rows, expected_generation: str):
    """🔴 세대가 섞이면 죽는다. 필터링하지 않는다."""
    gens = {r.get("generation") for r in rows}
    if gens != {expected_generation}:
        raise ValueError(
            f"load_buffer: generation 이 섞였다 (기대 {expected_generation!r}, 관측 {gens!r}). "
            "버퍼를 비우고 다시 모을 것")
    return rows


def run_episode_loop(n_episodes: int, *, alpha: float = 0.10, dry_run: bool = False):
    """에피소드마다 한 줄씩 기록한다. `dry_run` 은 시뮬레이터를 안 부르고 구조만 만든다."""
    hist = []
    for ep in range(n_episodes):
        stats = _run_one_episode(ep, alpha, dry_run)
        cov = stats["coverage"]
        retrain = (not dry_run) and should_retrain(cov, alpha)
        retrain and _refit_from_buffer()
        hist.append({"episode": ep, "escalation_rate": stats["escalation_rate"],
                     "coverage": cov, "n_buffer": stats["n_buffer"],
                     "retrained": retrain})
    return hist
```

`_run_one_episode` 과 `_refit_from_buffer` 는 같은 파일 아래에 둔다. 전자는
`tools/monitor/run_ood_matrix.jl` 을 한 에피소드 분량으로 부르고 `results/ood/` 산출물을 읽는다.
후자는 버퍼에서 `sample_batch` 로 뽑아 surrogate 를 재적합하고 `conformal.calibrate` 로 `q` 를 갱신한다.

- [ ] **Step 4: 통과 확인 + 짧은 루프를 돌린다**

Run:
```bash
PYTHONPATH=/usr/lib/python3/dist-packages ../.venv/bin/python -m pytest \
    wm4spacecraft_manufacturing/surrogate/test_retrain_loop.py -q
PYTHONPATH=/usr/lib/python3/dist-packages ../.venv/bin/python \
    wm4spacecraft_manufacturing/surrogate/retrain_loop.py --episodes 5
```

- [ ] **Step 5: 🔴 헤드라인 곡선을 음성 대조와 함께 낸다**

곡선 하나만으로는 아무것도 못 말한다. **두 곡선**을 낸다:

| 곡선 | 무엇 |
|---|---|
| **treatment** | 재학습 켬 — escalation률이 에피소드에 따라 **내려가야 한다** |
| **control** | 재학습 끔(버퍼는 그대로 쌓되 적합 안 함) — **평평해야 한다** |

control 이 같이 내려가면 그 감소는 학습이 아니라 **에피소드 순서·시드 드리프트**다. 이 레포가
"canonical 은 평평한데 추론 레인이 올랐다" 를 근거로 썼다가 직접 반례에 부딪힌 적이 있다 —
같은 실수를 여기서 미리 막는다.

- [ ] **Step 6: 커밋**

```bash
git add wm4spacecraft_manufacturing/surrogate/retrain_loop.py \
        wm4spacecraft_manufacturing/surrogate/test_retrain_loop.py \
        results/ood/closed_loop_curve.json
git commit -m "feat(ood): closed loop -- retrain on coverage drop, with a no-retrain control curve"
```

---

# 소요시간 요약

| Phase | 태스크 | 집중 작업 | 대기 |
|---|---|---|---|
| 6 | O1, O2, O3, O4, O5 | 17 h | 8~12 h |
| 7 | B1, B2, B3 | 12 h | ~4 h |
| | **합** | **29 h** | **12~16 h** |

리뷰·수정 왕복을 15% 얹으면 **약 33 h 집중 작업**. 하루 5 h 기준 **7 근무일**.

**임계 경로**: O1 → O2 → O3 → O5 → B2 → B3.

**멈춤 지점 셋**:
1. **O1 Step 5** — 새 라벨에 `macro == 2`(RelocateBuild)가 한 행이라도 있으면 zone 이 새 들어온 것이다
2. **O2 Step 5** — `coverage_holdout` 이 목표에 못 미치면 잔차가 교환가능하지 않다는 뜻이고, 그 위의 escalation 은 근거가 없다
3. **O5** — 일곱 축 중 3(`world_changed`) 또는 6(합성/재사용 양방향)이 실패하면 escalation 이 **보고만 하고 아무 일도 안 하는** 상태다

**계획서 A 의 Phase 4 가 선행 조건이다** — `L_prim` 이 없으면 O3·O4·O5 가 전부 L1 을 잰다.
