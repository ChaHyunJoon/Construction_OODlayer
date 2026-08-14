# surrogate 재구축 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 배포 surrogate 가 OOD 종류와 무관하게 `Replace` 만 내는 상수 정책 붕괴를 고친다 — 학습 형식을 "절대값 회귀 후 순위" 에서 "NOOP 대비 ΔJ 2-헤드 예측" 으로 바꾸고, 그 전에 붕괴를 기계적으로 잡는 게이트를 세운다.

**Architecture:** 원인은 모델 클래스가 아니라 (a) 타깃 분산의 78% 가 instance 난이도라 팔 간 차이가 뭉개지고, (b) 라벨이 배포와 다른 배터리 물리에서 만들어졌고, (c) `psi(8) == psi(0)` 이라 agnostic 표현에서 SwapBattery 가 NOOP 과 구별 불가라는 점이다. 그래서 순서가 **게이트 → 물리 정렬 → 재라벨 → 모델** 이다. 모델을 먼저 바꾸면 틀린 세계를 더 잘 맞추게 될 뿐이다.

**Tech Stack:** Python 3.12 (`/home/chahj578/Construction_OODlayer/.venv/bin/python`), scikit-learn (`HistGradientBoosting*`, `Ridge`, `RandomForest*`), pandas/numpy, Julia 1.10 (`julia +lts --project=.`) — 라벨러만.

**Spec:** `docs/superpowers/specs/2026-08-13-surrogate-rebuild-design.md`

## Global Constraints

이 절의 요구사항은 **모든 태스크에 암묵적으로 포함**된다.

1. **작업 디렉토리 = `/home/chahj578/Construction_OODlayer`**, 브랜치 = `oracle-rebuild-night-2026-08-10` (main/master 아님).
2. **Python 은 언제나 `/home/chahj578/Construction_OODlayer/.venv/bin/python`.** Julia 는 언제나 `julia +lts --project=.`.
3. **목적함수 상수(`C_fail`·`C_unclosed`·`tie_eps`·`kappa`·`M_ref`·`E_ref`)를 리터럴로 복붙하지 않는다.** 반드시 `objective.load()` / `objective.J()` 로 읽는다. `audit_objective.py` 항목 1 이 12개 파일을 스캔해 잡는다.
4. **`audit_objective.py` 는 언제나 exit 0 (9/9)** 이어야 한다. 문서에 옛 `objective_hash` 를 문자열로 적으면 항목 9 가 스테일로 판정한다.
5. **행동 어휘 단일 진실원 = `wm4spacecraft_manufacturing/action_registry.json`.** 매크로 표를 복붙하지 않는다. `audit_action_vocab.py` 6/6 유지.
6. **기대 baseline(실패 아님): `julia +lts --project=. -e 'using Pkg; Pkg.test()'` = 11 pass / 1 error** (Gurobi 라이선스 없음). 그 이상 나빠지면 회귀다.
7. **`test_surrogate_support.py` 7/7 유지** — 배포 학습셋의 매크로 지원 집합 계약.
8. 커밋 메시지는 한 줄 요약 + 필요시 본문. 각 태스크는 자기 커밋을 남긴다.
9. **시뮬레이션 결과로 코드 변경을 검증하지 않는다.** 이 하니스는 프로세스 간 재현성이 없다(CLAUDE.md Gotchas: 바이트 동일한 소스도 재컴파일 후 다른 배정 지문을 냈다). 검증은 순수 파이썬 단위검사로 한다.
10. **현행 세대**: `objective_hash` = `19819377a7f8ebb2`, `generation` = `2026-08-13-global-kappa-precedence`. 배포 배터리 물리 = `capacity_J = 8.28e6`(축소 없음) · stall 0.15 · derate 0.5/0.35.

---

## File Structure

| 파일 | 신규/수정 | 책임 |
|---|---|---|
| `wm4spacecraft_manufacturing/features_agnostic.py` | 수정 | `MACRO_SPECS[8]` 추가 (D5) |
| `wm4spacecraft_manufacturing/test_features_agnostic.py` | 신규 | `psi(8) != psi(0)` 회귀 검사 |
| `wm4spacecraft_manufacturing/surrogate_gates.py` | 신규 | G3(상수 정책 대비)·G4(kind 판별) 게이트 — 재사용 가능한 함수 |
| `wm4spacecraft_manufacturing/test_surrogate_gates.py` | 신규 | 게이트 자체의 단위검사 |
| `wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl` | 수정 | 라벨러 배터리 물리를 배포와 정렬 (D3) + J 성분 기록 |
| `wm4spacecraft_manufacturing/surrogate_features.py` | 신규 | 21차원 feature 조립 (상태 6 + ψ 10 + 교차 5) |
| `wm4spacecraft_manufacturing/test_surrogate_features.py` | 신규 | feature 조립 단위검사 |
| `wm4spacecraft_manufacturing/surrogate_v2.py` | 신규 | 2-헤드 모델 + `predict_delta_J` |
| `wm4spacecraft_manufacturing/test_surrogate_v2.py` | 신규 | 2-헤드 모델 단위검사 |
| `wm4spacecraft_manufacturing/eval_surrogate_v2.py` | 신규 | G1·G2 평가 하니스 (LOIO / LOKO) |

---

## Task 1: `psi(8)` 수정 — SwapBattery 가 NOOP 과 구별되게

Spec D5. **데이터 없이 지금 할 수 있고 위험이 0 이다.** 이것을 먼저 하는 이유: 이 설계가
제안하는 agnostic 표현으로 재학습하는 순간, 이게 없으면 모델이 SwapBattery 를 "아무것도
안 하기" 로 인식한다.

**Files:**
- Create: `wm4spacecraft_manufacturing/test_features_agnostic.py`
- Modify: `wm4spacecraft_manufacturing/features_agnostic.py` (`MACRO_SPECS`, 386-396행 근처)

**Interfaces:**
- Consumes: 없음 (첫 태스크)
- Produces: `psi(8)` 이 `_PRIMITIVE_TABLE["SwapBattery"]` 를 반영하는 ψ 벡터를 돌려준다. Task 5 의 feature 조립이 이것을 쓴다.

- [ ] **Step 1: 실패하는 검사를 먼저 쓴다**

`wm4spacecraft_manufacturing/test_features_agnostic.py` 를 만든다:

```python
#!/usr/bin/env python3
"""features_agnostic 의 행동 서술자 회귀 검사.

핵심 계약: **SwapBattery(8) 는 NOOP(0) 과 구별되어야 한다.**
2026-08-13 실측 결함: MACRO_SPECS 에 키 8 이 없어 psi(8) 이 빈 리스트로 조회되고
NOOP 의 ψ 벡터를 그대로 돌려줬다(psi(8) == psi(0) -> True). _PRIMITIVE_TABLE 에는
"SwapBattery" 가 이미 정의돼 있었으므로 빠진 것은 매크로->primitive 매핑 한 줄뿐이다.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from features_agnostic import psi, PSI_AXES, MACRO_SPECS, MACRO_COST

FAILS = []


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + ("   " + detail if detail else ""))
    if not cond:
        FAILS.append(name)


def main():
    print("== features_agnostic 행동 서술자 ==")

    check("MACRO_SPECS 에 8(SwapBattery) 가 있다", 8 in MACRO_SPECS,
          "keys=%s" % sorted(MACRO_SPECS))

    p8, p0, p1 = psi(8), psi(0), psi(1)

    check("psi(8) != psi(0)  — SwapBattery 가 NOOP 과 구별된다", p8 != p0)
    check("psi(8) != psi(1)  — SwapBattery 가 Replace 와 구별된다", p8 != p1)

    # 두 팔을 가르는 축(설계 주석이 지목한 것): 스페어 소모 여부와 가역성.
    check("a_consumes_spare: Swap 0 vs Replace 1",
          p8["a_consumes_spare"] == 0.0 and p1["a_consumes_spare"] == 1.0,
          "swap=%s replace=%s" % (p8["a_consumes_spare"], p1["a_consumes_spare"]))
    check("a_reversible: Swap 1 vs Replace 0",
          p8["a_reversible"] == 1.0 and p1["a_reversible"] == 0.0,
          "swap=%s replace=%s" % (p8["a_reversible"], p1["a_reversible"]))
    check("a_restores_capacity: 둘 다 1 (능력을 되돌린다)",
          p8["a_restores_capacity"] == 1.0 and p1["a_restores_capacity"] == 1.0)
    check("a_intervenes: Swap 은 개입이다(1)", p8["a_intervenes"] == 1.0)

    # a_cost 는 MACRO_COST 와 같은 값이어야 한다(함정 29: 표가 복붙되면 조용히 갈린다).
    check("a_cost == MACRO_COST[8]", p8["a_cost"] == MACRO_COST[8],
          "psi=%s table=%s" % (p8["a_cost"], MACRO_COST[8]))

    check("ψ 축 개수가 PSI_AXES 와 같다", set(p8) == set(PSI_AXES))

    print("\n%s" % ("전부 통과" if not FAILS else "실패 %d개: %s" % (len(FAILS), FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: 검사가 실패하는지 확인한다 (수정 전)**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_features_agnostic.py; echo "exit=$?"
```

Expected: `exit=1`. `MACRO_SPECS 에 8 이 있다` · `psi(8) != psi(0)` · `a_consumes_spare` ·
`a_reversible` · `a_cost == MACRO_COST[8]` 이 FAIL 로 찍힌다.

**여기서 통과해 버리면 멈춘다** — 이미 누가 고쳤다는 뜻이므로 Step 3 을 건너뛰고 Step 4 로 간다.

- [ ] **Step 3: `MACRO_SPECS` 에 8 을 추가한다**

`wm4spacecraft_manufacturing/features_agnostic.py` 의 `MACRO_SPECS` (386-396행 근처)
현행 코드:

```python
MACRO_SPECS = {
    0: [],                       # NOOP
    1: ["ReplaceAgent"],
    2: ["DeprioritizeAgent"],
    3: ["ForbidZone"],
    4: ["ReformTeam"],
    # 조합 행동 예시(A1 스모크 대상). 여기 추가해도 **모델 입력 차원은 변하지 않는다** — 이게 요점.
    5: ["ForbidAgent", "ReformTeam"],
    6: ["DeprioritizeAgent", "ForbidWindow"],
    7: ["RelocateBuild"],        # zone 사건의 기본 개입 팔(3 을 대체). spec 하나짜리.
}
```

`7:` 줄 바로 아래에 추가한다:

```python
    7: ["RelocateBuild"],        # zone 사건의 기본 개입 팔(3 을 대체). spec 하나짜리.
    # 8 = SwapBattery. _PRIMITIVE_TABLE 에는 처음부터 있었는데 이 매핑만 빠져 있었다 —
    # psi() 는 MACRO_SPECS.get(m, []) 로 조회하므로 8 은 빈 리스트가 되어 **NOOP 의 ψ 를
    # 그대로 돌려줬다**(실측: psi(8) == psi(0) -> True). 그 상태로 agnostic 표현을 학습하면
    # 모델은 "배터리 교체 = 아무것도 안 하기" 로 배운다. test_features_agnostic.py 가 계약.
    8: ["SwapBattery"],
```

- [ ] **Step 4: 검사가 통과하는지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_features_agnostic.py; echo "exit=$?"
```

Expected: `exit=0`, `전부 통과`.

- [ ] **Step 5: 기존 계약이 안 깨졌는지 확인한다**

`psi` 는 `assimilation_gate.py` 와 `verify.py --features=agnostic` 이 쓴다.

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
P=/home/chahj578/Construction_OODlayer/.venv/bin/python
$P audit_action_vocab.py;     echo "audit_action_vocab=$?"
$P audit_objective.py;        echo "audit_objective=$?"
$P test_surrogate_support.py; echo "test_surrogate_support=$?"
$P assimilation_gate.py 2>&1 | tail -5; echo "assimilation_gate=$?"
```

Expected: 앞의 셋은 exit 0. `assimilation_gate.py` 는 **변경 전후 출력이 달라질 수 있다**
(macro 8 이 이제 NOOP 이 아니므로) — 달라졌다면 그것이 정상이며, 무엇이 어떻게 달라졌는지
report 파일에 적는다. 죽으면(traceback) 멈추고 보고한다.

- [ ] **Step 6: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/features_agnostic.py \
        wm4spacecraft_manufacturing/test_features_agnostic.py
git commit -m "fix(surrogate): map macro 8 to the SwapBattery primitive

psi(8) 이 MACRO_SPECS 에 키가 없어 빈 리스트로 조회됐고, 그래서 NOOP 의 ψ 벡터를
그대로 돌려줬다(실측 psi(8) == psi(0)). _PRIMITIVE_TABLE 의 SwapBattery 항목은
처음부터 있었으므로 빠진 것은 매핑 한 줄이다. 이게 없으면 agnostic 표현으로 학습한
모델은 배터리 교체를 '아무것도 안 하기' 로 인식한다. spec D5."
```

---

## Task 2: G3·G4 게이트 — 상수 정책 붕괴를 기계로 잡는다

Spec §4. **이 태스크의 핵심은 게이트가 "현행 모델에 대해 실패하는 것"을 먼저 확인하는 것이다.**
통과하는 게이트는 아무것도 지키지 않는다.

**Files:**
- Create: `wm4spacecraft_manufacturing/surrogate_gates.py`
- Create: `wm4spacecraft_manufacturing/test_surrogate_gates.py`

**Interfaces:**
- Consumes: 없음
- Produces:
  - `constant_policy_baseline(preds_by_instance) -> dict` — 상수 정책들의 regret
  - `gate_g3_beats_constant(preds, truth) -> (bool, dict)` — G3
  - `gate_g4_kind_discrimination(choices_by_kind) -> (bool, dict)` — G4
  - Task 6 의 평가 하니스가 이 셋을 그대로 부른다.

- [ ] **Step 1: 게이트 모듈을 쓴다**

`wm4spacecraft_manufacturing/surrogate_gates.py`:

```python
#!/usr/bin/env python3
"""surrogate 의 **상수 정책 붕괴**를 기계적으로 잡는 게이트 (spec §4 G3·G4).

왜 이 파일이 필요한가
====================
2026-08-13 실측: 배포 surrogate 가 OOD 종류와 무관하게 언제나 `Replace` 를 냈다
(battery 120/120, fault 120/120, fault_battery 120/120). 그런데 그때까지 쓰던 평가 지표
(leave-one-instance-out decision regret 평균)는 0.100 으로 "괜찮아" 보였다.

**평균 regret 은 상수 붕괴를 숨긴다.** 상수 정책도 대부분의 instance 에서 그럭저럭 맞기
때문이다. 그래서 두 가지를 따로 본다:

  G3  상수 정책("항상 Replace", "항상 NOOP", ...)보다 **엄격히** 나은가
  G4  kind 마다 실제로 **다른 답**을 내는가

두 검사 모두 모델 내부를 안 본다 — (instance, kind, 예측한 팔) 목록만 받는다. 그래서
어떤 모델 클래스에도, 배포된 서비스의 로그에도 그대로 적용된다.
"""
from collections import Counter, defaultdict


def _regret(chosen, truth_scores):
    """truth_scores = {macro: 점수(높을수록 좋음)}. regret = 최적 − 선택."""
    if not truth_scores:
        return 0.0
    best = max(truth_scores.values())
    return float(best - truth_scores.get(chosen, min(truth_scores.values())))


def constant_policy_baseline(instances):
    """모든 상수 정책의 평균 regret 을 돌려준다.

    instances: [{"instance": id, "kind": k, "truth": {macro: score}, "valid": [macro...]}]
    반환: {macro: 평균 regret}  — 그 macro 를 언제나 고르는 정책의 성적.
    """
    arms = sorted({m for r in instances for m in r["truth"]})
    out = {}
    for a in arms:
        tot, n = 0.0, 0
        for r in instances:
            if a not in r["truth"]:      # 그 instance 에서 쓸 수 없는 팔이면 최악으로 친다
                tot += _regret(None, r["truth"])
            else:
                tot += _regret(a, r["truth"])
            n += 1
        out[a] = tot / max(n, 1)
    return out


def gate_g3_beats_constant(instances, choices, margin=0.0):
    """G3: 모델이 **모든** 상수 정책보다 엄격히 나은가.

    choices: {instance_id: 선택한 macro}
    margin:  이만큼은 더 좋아야 통과(기본 0 = 조금이라도 나으면 통과).
    """
    model = sum(_regret(choices.get(r["instance"]), r["truth"]) for r in instances) / max(len(instances), 1)
    base = constant_policy_baseline(instances)
    best_const = min(base.values()) if base else float("inf")
    best_arm = min(base, key=base.get) if base else None
    ok = model + margin < best_const
    return ok, {"model_regret": model, "best_constant_regret": best_const,
                "best_constant_arm": best_arm, "all_constant": base}


def gate_g4_kind_discrimination(instances, choices, min_kinds=2):
    """G4: kind 마다 실제로 다른 답 분포를 내는가.

    통과 조건: 답 분포가 **완전히 같은 kind 쌍이 하나도 없어야** 한다.
    (2026-08-13 결함이 정확히 이것이었다 — battery/fault/fault_battery 의 답 분포가
     Replace×120 으로 전부 동일했다.)
    """
    by_kind = defaultdict(Counter)
    for r in instances:
        c = choices.get(r["instance"])
        if c is not None:
            by_kind[r["kind"]][c] += 1
    kinds = sorted(by_kind)
    if len(kinds) < min_kinds:
        return False, {"reason": "kind 가 %d개뿐이라 판별을 검사할 수 없다" % len(kinds),
                       "by_kind": {k: dict(v) for k, v in by_kind.items()}}
    identical = []
    for i in range(len(kinds)):
        for j in range(i + 1, len(kinds)):
            a, b = kinds[i], kinds[j]
            # 분포를 비율로 정규화해 비교(표본 수가 달라도 "같은 정책"이면 같은 비율).
            na, nb = sum(by_kind[a].values()), sum(by_kind[b].values())
            pa = {m: c / na for m, c in by_kind[a].items()}
            pb = {m: c / nb for m, c in by_kind[b].items()}
            if pa == pb:
                identical.append((a, b))
    ok = not identical
    return ok, {"identical_kind_pairs": identical,
                "by_kind": {k: dict(v) for k, v in by_kind.items()}}
```

- [ ] **Step 2: 게이트 자체의 단위검사를 쓴다**

**게이트를 데이터에 물리기 전에 게이트가 옳은지부터 증명한다.** 합성 데이터로:
상수 정책은 G3·G4 를 반드시 실패하고, 완벽한 정책은 반드시 통과해야 한다.

`wm4spacecraft_manufacturing/test_surrogate_gates.py`:

```python
#!/usr/bin/env python3
"""surrogate_gates 의 단위검사 — 게이트가 실제로 붕괴를 잡는지 합성 데이터로 증명한다."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from surrogate_gates import (constant_policy_baseline, gate_g3_beats_constant,
                             gate_g4_kind_discrimination)

FAILS = []


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + ("   " + detail if detail else ""))
    if not cond:
        FAILS.append(name)


# battery 에서는 8(SwapBattery)이, fault 에서는 1(Replace)이 정답인 합성 격자.
INSTANCES = (
    [{"instance": "b%d" % i, "kind": "battery",
      "truth": {0: 0.0, 1: 5.0, 8: 10.0}, "valid": [0, 1, 8]} for i in range(10)] +
    [{"instance": "f%d" % i, "kind": "fault",
      "truth": {0: 0.0, 1: 10.0, 8: 2.0}, "valid": [0, 1, 8]} for i in range(10)]
)

PERFECT  = {r["instance"]: (8 if r["kind"] == "battery" else 1) for r in INSTANCES}
ALWAYS_1 = {r["instance"]: 1 for r in INSTANCES}          # 2026-08-13 의 실제 결함 모양
ALWAYS_0 = {r["instance"]: 0 for r in INSTANCES}


def main():
    print("== surrogate_gates 단위검사 ==")

    base = constant_policy_baseline(INSTANCES)
    check("상수 baseline 이 세 팔 전부를 계산한다", set(base) == {0, 1, 8}, str(base))
    # 항상 1 = battery 에서 5 손해, fault 에서 0 손해 -> 평균 2.5
    check("항상-Replace 의 평균 regret = 2.5", abs(base[1] - 2.5) < 1e-9, str(base[1]))

    ok, info = gate_g3_beats_constant(INSTANCES, PERFECT)
    check("G3: 완벽한 정책은 통과", ok, str(info["model_regret"]))

    ok, info = gate_g3_beats_constant(INSTANCES, ALWAYS_1)
    check("G3: 상수 정책은 **실패**해야 한다", not ok,
          "model=%.2f best_const=%.2f" % (info["model_regret"], info["best_constant_regret"]))

    ok, info = gate_g3_beats_constant(INSTANCES, ALWAYS_0)
    check("G3: 다른 상수 정책도 실패", not ok)

    ok, info = gate_g4_kind_discrimination(INSTANCES, PERFECT)
    check("G4: kind 마다 다른 답이면 통과", ok, str(info["by_kind"]))

    ok, info = gate_g4_kind_discrimination(INSTANCES, ALWAYS_1)
    check("G4: 모든 kind 에 같은 답이면 **실패**", not ok,
          str(info["identical_kind_pairs"]))

    print("\n%s" % ("전부 통과" if not FAILS else "실패 %d개: %s" % (len(FAILS), FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 3: 단위검사를 돌린다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_surrogate_gates.py; echo "exit=$?"
```

Expected: `exit=0`, `전부 통과`. 특히 `G3: 상수 정책은 실패해야 한다` 와
`G4: 모든 kind 에 같은 답이면 실패` 가 PASS 여야 한다 — 이 둘이 게이트의 존재 이유다.

- [ ] **Step 4: 현행 배포 모델을 게이트에 물린다 — 실패를 확인한다**

**이 스텝이 태스크 2 의 목적이다.** 게이트가 현행 결함을 실제로 잡는지 본다.

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python - <<'PY'
import sys, os, numpy as np
sys.path.insert(0, os.path.abspath("."))
from surrogate_data import load_training_frame
from surrogate_model import build_model
from surrogate_gates import gate_g3_beats_constant, gate_g4_kind_discrimination
from e1_analyze import load, instance_arms_complete, MACRO_COST
import wm_datasets

LAM = 3.0
path = wm_datasets.N44_PLUS78
X, y, support, n_full = load_training_frame(path, lam=LAM)
model = build_model().fit(X.values, y)

df = load(path); df = df[df.fired == True].copy()
full = [i for i, g in df.groupby("instance") if instance_arms_complete(g)]
df = df[df.instance.isin(full)].reset_index(drop=True)
df["y"] = df.closed.astype(float).values - LAM * np.array([MACRO_COST[int(m)] for m in df.macro])
pred = model.predict(X.values)
df["pred"] = pred

instances, choices = [], {}
for i, g in df.groupby("instance"):
    truth = {int(m): float(v) for m, v in zip(g.macro, g.y)}
    instances.append({"instance": i, "kind": g.kind.iloc[0], "truth": truth,
                      "valid": sorted(truth)})
    choices[i] = int(g.loc[g.pred.idxmax()].macro)

ok3, i3 = gate_g3_beats_constant(instances, choices)
ok4, i4 = gate_g4_kind_discrimination(instances, choices)
print("G3 pass=%s  model_regret=%.3f  best_constant=%.3f (arm %s)"
      % (ok3, i3["model_regret"], i3["best_constant_regret"], i3["best_constant_arm"]))
print("   all_constant=%s" % {k: round(v, 3) for k, v in i3["all_constant"].items()})
print("G4 pass=%s  identical_pairs=%s" % (ok4, i4["identical_kind_pairs"]))
print("   by_kind=%s" % i4["by_kind"])
PY
```

**Expected: G3 또는 G4 중 최소 하나가 `pass=False`.** 그것이 spec §1 의 결함이 재현됐다는
증거다. `by_kind` 출력을 report 파일에 그대로 붙인다 — Task 6 이 이 숫자와 비교한다.

**둘 다 통과하면 멈추고 보고한다.** 그 경우 이 계획의 전제(상수 붕괴)가 학습셋 위에서는
재현되지 않는다는 뜻이고, 결함이 배포 경로(서비스의 feature 조립)에만 있다는 뜻이므로
원인 재조사가 먼저다.

- [ ] **Step 5: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/surrogate_gates.py \
        wm4spacecraft_manufacturing/test_surrogate_gates.py
git commit -m "test(surrogate): G3/G4 gates that catch constant-policy collapse

평균 regret 은 상수 붕괴를 숨긴다 — 배포 모델이 kind 와 무관하게 Replace 만 내는데도
LOIO regret 은 0.100 이었다. G3=모든 상수 정책보다 엄격히 나은가, G4=kind 마다 다른 답
분포를 내는가. 합성 데이터 단위검사로 '상수 정책은 반드시 실패' 를 먼저 증명한다. spec §4."
```

---

## Task 3: 라벨러 배터리 물리를 배포와 정렬

Spec D3. **이 계획에서 가장 큰 실질 원인.** 라벨은 "배터리가 41초에 죽는 세계" 의 정답이고
배포는 2.30시간짜리 세계다.

**Files:**
- Modify: `wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl:1176-1187` (`_arm_battery!`)

**Interfaces:**
- Consumes: 없음
- Produces: 라벨러의 `capacity_J` 가 배포(`run_demo.jl`)와 같아진다. Task 4 의 재라벨이 이 물리로 돈다.

- [ ] **Step 1: 현행 값과 배포 값을 나란히 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer
sed -n '1176,1190p' wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl
grep -n "enable_battery!\|set_battery_stall!\|set_battery_derate!" tools/monitor/run_demo.jl
```

Expected: 라벨러는 `demo_battery_params(shrink = DS_SHRINK 기본 200.0)`, 배포는
`CB.BatteryParams()` (축소 없음). stall/derate 는 양쪽 다 0.15 / 0.5·0.35.

- [ ] **Step 2: `_arm_battery!` 의 용량을 배포와 맞춘다**

`wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl` 의 `_arm_battery!` 안,
현행 첫 줄:

```julia
        CB.enable_battery!(env; params = CB.demo_battery_params(
            shrink = parse(Float64, get(ENV, "DS_SHRINK", "200.0"))))          # 용량 축소(짧은 빌드에서 소모가 보이게)
```

이렇게 바꾼다:

```julia
        # 용량은 **배포 레인(tools/monitor/run_demo.jl)과 같아야 한다** — 라벨과 평가가 다른
        # 물리에서 나오면 라벨은 "그 세계의 정답" 일 뿐이다(2026-08-13 실측: DS_SHRINK=200 은
        # 최대부하 41초짜리 배터리라 자연 방전만으로 로봇이 죽는 세계였고, 그 라벨을 배운
        # surrogate 가 배포 물리에서 틀린 팔을 골랐다. spec D3).
        # 기본값을 1.0(축소 없음)으로 둔다: 스펙 2.3 kWh 는 최대부하 1000 W 에서 2.30 시간이라
        # 실제 작업로봇의 지속시간과 맞는다. 옛 라벨을 재현하려면 DS_SHRINK=200 을 준다.
        CB.enable_battery!(env; params = CB.demo_battery_params(
            shrink = parse(Float64, get(ENV, "DS_SHRINK", "1.0"))))
```

- [ ] **Step 3: 파싱과 값 확인**

```bash
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. -e 'Meta.parseall(read("wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl", String)); println("parses OK")'
julia +lts --project=. -e '
using ConstructionBots; const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
println("deploy capacity_J   = ", CB.BatteryParams().capacity_J)
println("labeler capacity_J  = ", CB.demo_battery_params(shrink = 1.0).capacity_J)
println("equal? ", CB.BatteryParams().capacity_J == CB.demo_battery_params(shrink = 1.0).capacity_J)'
```

Expected: `parses OK`, 두 용량이 같고 `equal? true`.

- [ ] **Step 4: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl
git commit -m "fix(oracle): align labeler battery capacity with the deployment lane

DS_SHRINK 기본값 200 -> 1.0(축소 없음). 라벨러는 최대부하 41초짜리 배터리 세계에서
정답을 만들고 있었고 배포는 2.30시간짜리다. 그 불일치가 배포 surrogate 가 battery 에서
Replace 를 고르는 실질 원인이다(spec D3). 옛 라벨 재현은 DS_SHRINK=200."
```

---

## Task 4: 재라벨 — 팔 전수 + J 성분 기록

Spec §5. **계산 캠페인이다(수 시간~수십 시간).** Task 3 이 끝난 뒤에만 의미가 있다.

**Files:**
- Modify: `wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl` (라벨 행 기록부)

**Interfaces:**
- Consumes: Task 3 의 정렬된 물리
- Produces: 새 라벨셋 JSONL. 각 행이 `complete`(bool) · `closed`(int) · `total`(int) · `makespan`(float) · `energy_J`(float) · `objective_hash`(str) 를 갖는다. Task 5·6 이 이것을 읽는다.

- [ ] **Step 1: 현행 라벨 행이 무엇을 담는지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python -c "
import json
r = json.loads(open('oracle/out/n44_plus78.jsonl').readline())
print(sorted(r.keys()))
for k in ('complete','closed','total','makespan','energy_J','objective_hash','kind','macro','valid_mask'):
    print('  %-16s %s' % (k, r.get(k, '<<MISSING>>')))
"
```

이 출력을 report 에 적는다. **`complete`/`makespan`/`energy_J` 중 없는 것이 J 계산의 구멍이다.**

- [ ] **Step 2: 빠진 J 성분을 라벨 행에 추가한다**

Step 1 에서 `<<MISSING>>` 으로 나온 키만 채운다. `gen_oracle_dataset.jl` 의 라벨 행 생성부에서
이미 계산돼 있는 값을 그대로 내보낸다(새로 계산하지 않는다 — `total_energy_J` 는
`:1500-1512` 근처에서 `CB.battery_report` 로 이미 읽고 있다).

**규약:** `energy_J` 가 유한하지 않으면 그 행은 **빈 필드로 낸다**(0 으로 채우지 않는다).
`Objective.J` 가 설계대로 던지게 해야 조용한 오염이 안 생긴다(spec §5, Global Constraint 3).

- [ ] **Step 3: 팔 커버리지를 전수로 올린다**

현행은 battery instance 43개 중 18개만 SwapBattery 팔을 갖는다. `DS_VALID_ONLY` 등
팔 선택 손잡이를 확인해 **각 instance 의 `valid_mask` 전부**를 돌게 한다.

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
grep -n "DS_VALID_ONLY\|valid_mask\|ARMS\|DS_ARMS" oracle/gen_oracle_dataset.jl | head -20
```

무엇을 어떻게 켰는지 report 에 적는다.

- [ ] **Step 4: 소규모 파일럿으로 스키마를 먼저 검증한다 (전체 재라벨 전에)**

**전체 캠페인 전에 반드시 한다.** 몇 instance 만 돌려 행 스키마가 맞는지 본다.

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
# 파일럿 규모 손잡이는 스크립트 상단 주석에서 읽는다 — 이름이 다르면 그쪽을 쓰고 report 에 적는다.
DS_LIMIT=3 ORACLE_OUT=/tmp/pilot_labels.jsonl \
  timeout 7200 julia +lts --project=/home/chahj578/Construction_OODlayer \
  oracle/gen_oracle_dataset.jl 2>&1 | tail -20

/home/chahj578/Construction_OODlayer/.venv/bin/python -c "
import json, sys
rows = [json.loads(l) for l in open('/tmp/pilot_labels.jsonl') if l.strip()]
print('rows:', len(rows))
need = ['complete','closed','total','makespan','kind','macro','valid_mask']
miss = [k for k in need if k not in rows[0]]
print('missing keys:', miss or 'none')
comp = [r for r in rows if r.get('complete')]
bad  = [r for r in comp if not isinstance(r.get('energy_J'), (int,float))]
print('complete rows:', len(comp), ' of those without finite energy_J:', len(bad))
sys.exit(1 if (miss or (comp and bad)) else 0)
"; echo "schema_exit=$?"
```

Expected: `missing keys: none`, `without finite energy_J: 0`, `schema_exit=0`.
**실패하면 여기서 멈춘다** — 스키마가 틀린 채 전체 캠페인을 돌리면 전부 버려야 한다.

- [ ] **Step 5: 전체 재라벨 캠페인**

파일럿이 통과한 뒤에만. 수 시간~수십 시간이다. 백그라운드로 돌리고 진행을 기록한다.
완료 후:

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python -c "
import json, collections
rows=[json.loads(l) for l in open('oracle/out/<NEW_LABELS>.jsonl') if l.strip()]
byk=collections.Counter(r['kind'] for r in rows)
inst=collections.defaultdict(set)
for r in rows: inst[(r['kind'], r['instance'])].add(int(r['macro']))
print('rows:', len(rows), 'by kind:', dict(byk))
print('instances:', len(inst))
cov=[1 for k,v in inst.items() if 8 in v]
bat=[1 for k,v in inst.items() if k[0]=='battery']
print('battery instances: %d, with SwapBattery arm: %d' % (len(bat), sum(1 for k,v in inst.items() if k[0]=='battery' and 8 in v)))
"
```

Expected: battery instance 의 SwapBattery 커버리지가 100% 에 가까울 것. 아니면 그 사실을
report 에 적는다(숨기지 않는다).

- [ ] **Step 6: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl
git commit -m "feat(oracle): record J components and run the full valid-arm set

라벨 행에 complete/makespan/energy_J 를 담는다 — closed 만으로는 2-헤드(완주 분류 +
시간·에너지 회귀)를 학습할 수 없다. 팔은 valid_mask 전수로 돌린다(battery 43개 중
18개만 SwapBattery 팔이 있었다). spec §5."
```

---

## Task 5: 21차원 feature 조립기

Spec §3.4. 상태 6 + ψ 10 + 교차 5.

**Files:**
- Create: `wm4spacecraft_manufacturing/surrogate_features.py`
- Create: `wm4spacecraft_manufacturing/test_surrogate_features.py`

**Interfaces:**
- Consumes: Task 1 의 `psi(8)`, `features_agnostic.descriptors_from_row`, `STATE_DESCRIPTORS`, `PSI_AXES`
- Produces:
  - `FEATURE_NAMES: list[str]` — 21개, 순서 고정
  - `build_features(rows) -> pandas.DataFrame` — 열 순서가 `FEATURE_NAMES` 와 정확히 같다
  - Task 6 의 모델이 이 둘을 쓴다.

- [ ] **Step 1: 실패하는 검사를 먼저 쓴다**

`wm4spacecraft_manufacturing/test_surrogate_features.py`:

```python
#!/usr/bin/env python3
"""surrogate_features 단위검사 — 21차원, 순서 고정, kind 누출 없음."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from surrogate_features import FEATURE_NAMES, build_features, INTERACTIONS
from features_agnostic import STATE_DESCRIPTORS, PSI_AXES

FAILS = []


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + ("   " + detail if detail else ""))
    if not cond:
        FAILS.append(name)


ROW_BATTERY = dict(kind="battery", macro=8, severity=0.10, soc=0.10, spare_count=3,
                   agent_pending=5, progress=0.4, n_active=10, n_spare_cfg=3,
                   closed_at_fire=120, total=313, zone_overlap=None, zone_radius=None,
                   valid_mask=[0, 1, 2, 8])
ROW_FAULT = dict(ROW_BATTERY, kind="fault", macro=1, soc=None, severity=1.0,
                 valid_mask=[0, 1, 2, 4])


def main():
    print("== surrogate_features ==")
    check("FEATURE_NAMES 가 21개", len(FEATURE_NAMES) == 21, str(len(FEATURE_NAMES)))
    check("상태 6축이 전부 있다", all(s in FEATURE_NAMES for s in STATE_DESCRIPTORS))
    check("ψ 10축이 전부 있다", all(a in FEATURE_NAMES for a in PSI_AXES))
    check("교차 5개가 있다", len(INTERACTIONS) == 5, str(INTERACTIONS))

    # kind 누출 금지: 열 이름 어디에도 kind 이름이 없어야 한다.
    leaked = [c for c in FEATURE_NAMES
              if any(k in c for k in ("fault", "battery", "zone", "kind"))]
    check("kind 이름이 feature 에 누출되지 않는다", not leaked, str(leaked))

    X = build_features([ROW_BATTERY, ROW_FAULT])
    check("열 순서가 FEATURE_NAMES 와 정확히 같다", list(X.columns) == FEATURE_NAMES)
    check("행 수가 입력과 같다", len(X) == 2)
    check("NaN 이 없다", not X.isna().any().any(), str(X.isna().sum().sum()))

    # 핵심 교차항이 실제로 두 팔을 가른다.
    swap = build_features([dict(ROW_BATTERY, macro=8)]).iloc[0]
    repl = build_features([dict(ROW_BATTERY, macro=1)]).iloc[0]
    check("SwapBattery 와 Replace 의 feature 가 다르다", not swap.equals(repl))
    check("a_consumes_spare 가 두 팔을 가른다",
          swap["a_consumes_spare"] != repl["a_consumes_spare"],
          "swap=%s replace=%s" % (swap["a_consumes_spare"], repl["a_consumes_spare"]))
    noop = build_features([dict(ROW_BATTERY, macro=0)]).iloc[0]
    check("SwapBattery 와 NOOP 의 feature 가 다르다 (Task 1 의 psi 수정 의존)",
          not swap.equals(noop))

    print("\n%s" % ("전부 통과" if not FAILS else "실패 %d개: %s" % (len(FAILS), FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: 검사가 실패하는지 확인 (모듈이 아직 없으므로 ImportError)**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_surrogate_features.py; echo "exit=$?"
```

Expected: `ModuleNotFoundError: No module named 'surrogate_features'` (exit != 0).

- [ ] **Step 3: 조립기를 쓴다**

`wm4spacecraft_manufacturing/surrogate_features.py`:

```python
#!/usr/bin/env python3
"""surrogate 의 21차원 feature 조립기 (spec §3.4).

  상태 6  (features_agnostic.STATE_DESCRIPTORS) — kind 불변, 부호 일관
  행동 10 (features_agnostic.PSI_AXES)          — macro 를 이름표가 아니라 '무엇을 하는가' 로
  교차 5                                        — 물리적 의미가 있는 것만

왜 kind one-hot 을 안 넣는가: 넣으면 처음 보는 OOD kind 에서 one-hot 이 전부 0 인
미지원 영역이 되어 무너진다. 이 시스템의 존재 이유가 처음 보는 사건 대응이다.
`resource_loss × a_restores_capacity` 가 kind 를 대신하면서 일반화까지 얻는 경로다.

왜 legacy e1_analyze.featurize 를 안 쓰는가: `severity` 의 물리적 의미가 kind 마다
부호가 뒤집힌다(fault 高=위험, battery 低=위험). fault 에서 배운 규칙이 battery 에서
정확히 반대로 작동한다 — 데이터를 더 모아도 안 고쳐진다(features_agnostic.py 헤더).

왜 21개인가: 학습셋이 286행이다. 행당 13.6개로, 교차항을 남발하면 과적합으로 돌아온다.
"""
import os
import sys

import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from features_agnostic import (STATE_DESCRIPTORS, PSI_AXES, psi,   # noqa: E402
                               descriptors_from_row)

# (상태축, 행동축) — 물리적 근거가 있는 교차만.
INTERACTIONS = [
    ("resource_loss",     "a_restores_capacity"),   # 핵심: 잃은 능력 × 되돌리는 행동
    ("harm",              "a_intervenes"),          # 무해한 사건에 개입하면 손해
    ("recovery_capacity", "a_consumes_spare"),      # 예비가 없으면 Replace 를 못 쓴다
    ("work_at_risk",      "a_scope"),               # 큰 일일 때만 전역 개입이 값을 한다
    ("slack",             "a_soft"),                # 병렬성이 남을 때만 soft 가 통한다
]

FEATURE_NAMES = (list(STATE_DESCRIPTORS) + list(PSI_AXES) +
                 ["%s__x__%s" % (s, a) for s, a in INTERACTIONS])


def build_features(rows):
    """rows: 라벨 행(dict) 목록. 각 행은 최소한 `macro` 와 상태 서술자 계산에 필요한 필드를 갖는다.

    반환: 열 순서가 FEATURE_NAMES 와 **정확히** 같은 DataFrame.
    (순서가 흔들리면 배포 쪽 조립기와 조용히 어긋난다 — 그게 이 저장소의 반복된 사고다.)
    """
    out = []
    for r in rows:
        s = descriptors_from_row(r)                 # kind-agnostic 상태 서술자
        a = psi(int(r["macro"]))                    # 행동 서술자 (Task 1 이 macro 8 을 고쳤다)
        row = {}
        for k in STATE_DESCRIPTORS:
            row[k] = float(s[k])
        for k in PSI_AXES:
            row[k] = float(a[k])
        for sk, ak in INTERACTIONS:
            row["%s__x__%s" % (sk, ak)] = float(s[sk]) * float(a[ak])
        out.append(row)
    return pd.DataFrame(out, columns=FEATURE_NAMES).fillna(0.0)
```

**주의:** `descriptors_from_row` 의 실제 시그니처를 먼저 확인한다:

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
grep -n "def descriptors_from_row" -A 12 features_agnostic.py
```

인자 이름이나 반환형이 다르면 위 코드를 거기 맞춘다(추측하지 않는다).

- [ ] **Step 4: 검사가 통과하는지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_surrogate_features.py; echo "exit=$?"
```

Expected: `exit=0`, `전부 통과`. 특히 `SwapBattery 와 NOOP 의 feature 가 다르다` 가 PASS —
Task 1 이 제대로 됐다는 종단 확인이다.

- [ ] **Step 5: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/surrogate_features.py \
        wm4spacecraft_manufacturing/test_surrogate_features.py
git commit -m "feat(surrogate): 21-dim kind-agnostic feature assembler

상태 6(features_agnostic) + 행동 ψ 10 + 물리적 교차 5. kind one-hot 을 넣지 않아
처음 보는 OOD kind 에서도 서술자 조합으로 유추된다. legacy featurize 는 severity 의
부호가 kind 마다 뒤집혀 쓰지 않는다. 286행이라 21차원으로 예산을 묶었다. spec §3.4."
```

---

## Task 6: 2-헤드 모델 + ΔJ 예측 + G1·G2 평가

Spec §3.2·§3.3·§3.5·§3.6·§4.

**Files:**
- Create: `wm4spacecraft_manufacturing/surrogate_v2.py`
- Create: `wm4spacecraft_manufacturing/test_surrogate_v2.py`
- Create: `wm4spacecraft_manufacturing/eval_surrogate_v2.py`

**Interfaces:**
- Consumes: Task 5 의 `build_features`/`FEATURE_NAMES`, Task 4 의 라벨셋, `objective.load()`
- Produces:
  - `SurrogateV2.fit(rows) -> self`
  - `SurrogateV2.predict_J(rows) -> np.ndarray` — 절대 Ĵ
  - `SurrogateV2.predict_delta_J(rows, ref_macro=0) -> np.ndarray` — NOOP 대비 ΔĴ (낮을수록 좋음)
  - `SurrogateV2.predict_complete_proba(rows) -> np.ndarray`

- [ ] **Step 1: 실패하는 검사를 먼저 쓴다**

`wm4spacecraft_manufacturing/test_surrogate_v2.py`:

```python
#!/usr/bin/env python3
"""SurrogateV2 단위검사 — 합성 데이터로 계약을 고정한다(실제 라벨 없이 돈다)."""
import sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from surrogate_v2 import SurrogateV2

FAILS = []


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + ("   " + detail if detail else ""))
    if not cond:
        FAILS.append(name)


def synth():
    """battery 에서는 8 이 완주시키고 1 은 못 시키는 합성 격자."""
    rows = []
    for i in range(40):
        base = dict(kind="battery", severity=0.1, soc=0.1, spare_count=3, agent_pending=5,
                    progress=0.4, n_active=10, n_spare_cfg=3, closed_at_fire=120,
                    total=313, zone_overlap=None, zone_radius=None,
                    valid_mask=[0, 1, 8], instance="b%d" % i)
        rows.append(dict(base, macro=0, complete=False, closed=150, makespan=70.0, energy_J=90000.0))
        rows.append(dict(base, macro=1, complete=False, closed=240, makespan=60.0, energy_J=95000.0))
        rows.append(dict(base, macro=8, complete=True,  closed=291, makespan=22.0, energy_J=73000.0))
    return rows


def main():
    print("== SurrogateV2 ==")
    rows = synth()
    m = SurrogateV2().fit(rows)

    J = m.predict_J(rows)
    check("predict_J 가 행 수만큼 돌려준다", len(J) == len(rows), str(len(J)))
    check("predict_J 가 전부 유한하다", np.all(np.isfinite(J)))

    p = m.predict_complete_proba(rows)
    check("완주 확률이 [0,1]", np.all((p >= 0) & (p <= 1)))
    # macro 8 만 완주하는 데이터이므로 8 의 완주확률이 1 보다 확실히 높아야 한다.
    p8 = p[[i for i, r in enumerate(rows) if r["macro"] == 8]].mean()
    p1 = p[[i for i, r in enumerate(rows) if r["macro"] == 1]].mean()
    check("P(complete) 가 8 > 1", p8 > p1, "p8=%.3f p1=%.3f" % (p8, p1))

    d = m.predict_delta_J(rows, ref_macro=0)
    check("predict_delta_J 가 행 수만큼", len(d) == len(rows))
    # NOOP 행의 ΔJ 는 정의상 0 이어야 한다.
    d0 = d[[i for i, r in enumerate(rows) if r["macro"] == 0]]
    check("NOOP 의 ΔJ == 0", np.allclose(d0, 0.0, atol=1e-6), str(d0[:3]))
    # 완주시키는 팔의 ΔJ 가 확실히 음수(개선)여야 한다 — C_fail 절벽 때문에 크게 갈린다.
    d8 = d[[i for i, r in enumerate(rows) if r["macro"] == 8]].mean()
    check("완주시키는 팔의 ΔJ 가 음수(개선)", d8 < 0, "mean=%.1f" % d8)

    # argmin 이 8 을 고르는가 = 결정 규칙의 종단 계약
    picks = []
    for i in range(40):
        idx = [k for k, r in enumerate(rows) if r["instance"] == "b%d" % i]
        picks.append(rows[idx[int(np.argmin(d[idx]))]]["macro"])
    check("argmin ΔJ 가 SwapBattery(8) 를 고른다", all(x == 8 for x in picks),
          str(sorted(set(picks))))

    print("\n%s" % ("전부 통과" if not FAILS else "실패 %d개: %s" % (len(FAILS), FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: 검사가 실패하는지 확인**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_surrogate_v2.py; echo "exit=$?"
```

Expected: `ModuleNotFoundError: No module named 'surrogate_v2'`.

- [ ] **Step 3: 2-헤드 모델을 쓴다**

`wm4spacecraft_manufacturing/surrogate_v2.py`:

```python
#!/usr/bin/env python3
"""SurrogateV2 — J 의 분기 구조를 그대로 모사하는 2-헤드 예측기 (spec §3.3).

    A: P(complete | s,a)                                 분류
    B: E[makespan + w_E*energy_J | s,a, complete]         회귀
    C: E[total - closed | s,a, not complete]              회귀

    Ĵ = P*B + (1-P)*(C_fail + C_unclosed*C + tie_eps*B)
    ΔĴ(a) = Ĵ(a) - Ĵ(NOOP)      <- 결정에 쓰는 값(낮을수록 좋음)

왜 2-헤드인가: J 는 완주 여부에서 C_fail(=10000) 짜리 절벽이 있다. 이봉분포를 하나의
제곱오차 회귀로 넘으면 안 된다. 나누면 절벽이 분류기로 흡수되고, "이 개입이 빌드를
완주시키는가" 가 독립된 학습 문제가 된다 — 2026-08-13 결함이 정확히 그 지점이었다.

왜 ΔJ 인가: 학습셋에서 타깃 분산의 78% 가 'instance 난이도' 다(between 2130 vs within 612).
같은 instance 안에서 빼면 그 성분이 정의상 소거되고, 모델 용량 전부가 팔 간 차이에 간다.

상수는 전부 objective.json 에서 읽는다 — 리터럴 복붙 금지(audit_objective 항목 1).
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import objective                                        # noqa: E402
from surrogate_features import build_features           # noqa: E402

from sklearn.ensemble import HistGradientBoostingClassifier, HistGradientBoostingRegressor

# 286행 예산에 맞춘 하이퍼파라미터. max_depth=3 이 핵심 — 현행 배포의 6 은 instance 를 암기한다.
_HP = dict(max_depth=3, max_iter=300, learning_rate=0.05,
           min_samples_leaf=5, l2_regularization=1.0, early_stopping=True, random_state=0)


def _w_E(cfg):
    """w_E = kappa * M_ref / E_ref. 스케일이 null 이면 에러(0/1 로 폴백하지 않는다)."""
    for k in ("kappa", "M_ref", "E_ref"):
        if cfg.get(k) is None:
            raise objective.ObjectiveError("objective.json 의 %s 가 null 이라 w_E 를 만들 수 없다" % k)
    return float(cfg["kappa"]) * float(cfg["M_ref"]) / float(cfg["E_ref"])


class SurrogateV2:
    def __init__(self, cfg=None):
        self.cfg = cfg or objective.load()
        self.w_E = _w_E(self.cfg)
        self.head_a = HistGradientBoostingClassifier(**_HP)
        self.head_b = HistGradientBoostingRegressor(loss="absolute_error", **_HP)
        self.head_c = HistGradientBoostingRegressor(loss="absolute_error", **_HP)
        self._b_fallback = 0.0
        self._c_fallback = 0.0

    # ---- 학습 ----------------------------------------------------------------
    def fit(self, rows):
        X = build_features(rows).values
        comp = np.array([bool(r.get("complete")) for r in rows])

        self.head_a.fit(X, comp.astype(int))

        # B: 완주 행만. 시간 + 에너지 (= J 의 완주 분기)
        if comp.any():
            yb = np.array([float(r["makespan"]) + self.w_E * float(r["energy_J"])
                           for r, c in zip(rows, comp) if c])
            self.head_b.fit(X[comp], yb)
            self._b_fallback = float(np.median(yb))
        # C: 미완주 행만. 남은 노드 수
        if (~comp).any():
            yc = np.array([float(r["total"]) - float(r["closed"])
                           for r, c in zip(rows, comp) if not c])
            self.head_c.fit(X[~comp], yc)
            self._c_fallback = float(np.median(yc))
        self._fitted_b = bool(comp.any())
        self._fitted_c = bool((~comp).any())
        return self

    # ---- 예측 ----------------------------------------------------------------
    def predict_complete_proba(self, rows):
        X = build_features(rows).values
        p = self.head_a.predict_proba(X)
        # 한 클래스만 본 경우 predict_proba 가 1열이다.
        return p[:, 1] if p.shape[1] == 2 else np.full(len(rows), float(self.head_a.classes_[0]))

    def predict_J(self, rows):
        X = build_features(rows).values
        p = self.predict_complete_proba(rows)
        b = self.head_b.predict(X) if self._fitted_b else np.full(len(rows), self._b_fallback)
        c = self.head_c.predict(X) if self._fitted_c else np.full(len(rows), self._c_fallback)
        c = np.clip(c, 0.0, None)
        C_fail = float(self.cfg["C_fail"])
        C_unclosed = float(self.cfg["C_unclosed"])
        tie_eps = float(self.cfg["tie_eps"])
        return p * b + (1.0 - p) * (C_fail + C_unclosed * c + tie_eps * b)

    def predict_delta_J(self, rows, ref_macro=0):
        """같은 instance 의 ref_macro 행을 기준으로 뺀다. 기준 행이 없으면 그 instance 의 평균."""
        J = self.predict_J(rows)
        by_inst = {}
        for i, r in enumerate(rows):
            by_inst.setdefault(r.get("instance"), []).append(i)
        out = np.array(J, dtype=float)
        for _, idx in by_inst.items():
            ref = [i for i in idx if int(rows[i]["macro"]) == int(ref_macro)]
            base = J[ref[0]] if ref else float(np.mean(J[idx]))
            out[idx] = J[idx] - base
        return out
```

- [ ] **Step 4: 검사가 통과하는지 확인**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_surrogate_v2.py; echo "exit=$?"
```

Expected: `exit=0`, `전부 통과`. 특히 `argmin ΔJ 가 SwapBattery(8) 를 고른다` 가 PASS.

- [ ] **Step 5: G1·G2 평가 하니스를 쓰고 돌린다**

`wm4spacecraft_manufacturing/eval_surrogate_v2.py` 를 만든다. 요구사항:

- `LeaveOneGroupOut` 을 `instance` 로 그룹핑 → **G1** (leave-one-instance-out regret)
- `kind` 로 그룹핑 → **G2** (leave-one-KIND-out regret)
- 각 폴드에서 `SurrogateV2` 를 학습, `predict_delta_J` 의 argmin 으로 팔 선택
- 진실 점수 = `-J_row` (`e1_analyze.cost_lex_key_row` 와 같은 규칙 — 재구현 금지, import 해서 쓴다)
- **`surrogate_gates.gate_g3_beats_constant` 와 `gate_g4_kind_discrimination` 을 그대로 호출해 G3·G4 를 함께 낸다**
- **Ridge 베이스라인을 같은 폴드로 함께 보고**한다(spec §3.6: 선형이 이기면 트리를 쓸 이유가 없다)
- 결과를 JSON 으로 낸다: `{"G1":..., "G2":..., "G3":{...}, "G4":{...}, "ridge_G1":...}`

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python eval_surrogate_v2.py \
  --labels oracle/out/<NEW_LABELS>.jsonl -o /tmp/eval_v2.json
```

Expected: **G3 pass=True, G4 pass=True**, G1 이 현행 배포 모델(Task 2 Step 4 에서 기록한 값)보다
개선. **하나라도 실패하면 그 사실을 그대로 report 에 적는다** — 통과했다고 쓰지 않는다.

- [ ] **Step 6: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/surrogate_v2.py \
        wm4spacecraft_manufacturing/test_surrogate_v2.py \
        wm4spacecraft_manufacturing/eval_surrogate_v2.py
git commit -m "feat(surrogate): two-head DeltaJ predictor + G1..G4 evaluation

J 의 분기 구조를 그대로 모사한다(완주 분류 + 시간·에너지 회귀 + 미완주 잔여 회귀).
결정값은 같은 instance 의 NOOP 대비 ΔJ — 타깃 분산의 78%인 instance 난이도 성분이
정의상 소거된다. 상수는 objective.json 에서 읽는다. max_depth=3(현행 6 은 286행에서
instance 를 암기). Ridge 베이스라인 동시 보고. spec §3.2-3.6, §4."
```

---

## Task 7: 배포 배선 + 재스윕

Spec §6 단계 6.

**Files:**
- Modify: `src/respec/llm_service/dspy_service.py:181-198` (`_load_surrogate`), `288-330` (`surrogate_rank`)

**Interfaces:**
- Consumes: Task 6 의 `SurrogateV2`
- Produces: 배포 서비스가 ΔĴ 로 순위를 낸다.

- [ ] **Step 1: 서비스가 `SurrogateV2` 를 쓰도록 바꾼다**

`_load_surrogate()` 가 `SurrogateV2().fit(rows)` 를 쓰고, `surrogate_rank()` 가
`predict_delta_J` 의 **오름차순**(낮을수록 좋음)으로 정렬하게 한다. **현행은 내림차순
(`scored.sort(key=lambda t: -t[1])`)이므로 부호를 뒤집지 않으면 정확히 최악의 팔을 고른다** —
이 한 줄이 이 태스크에서 가장 위험한 지점이다.

`surro_support` 기반 후보 탈락 로직과 `UNSUPPORTED:` 반환 규약은 **그대로 유지**한다.

- [ ] **Step 2: 서비스 스모크**

```bash
cd /home/chahj578/Construction_OODlayer/src/respec/llm_service
/home/chahj578/Construction_OODlayer/.venv/bin/python -m uvicorn dspy_service:app \
  --host 127.0.0.1 --port 8090 &
sleep 20
curl -s -X POST http://127.0.0.1:8090/macro -H 'Content-Type: application/json' -d '{
  "kind":"battery","severity":0.1,"soc":0.10,"spare_count":3,"agent_pending":1,
  "progress":0.4,"n_active":4,
  "nl":"A transport robot reports state of charge 10 percent."}' | head -c 600
```

Expected: 200 응답. **battery 에서 `SwapBattery` 가 1순위로 나오는지 확인한다** — 그것이
이 계획 전체의 종단 검증이다. 아니면 그 사실을 report 에 적는다.

- [ ] **Step 3: 계약 재확인**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
P=/home/chahj578/Construction_OODlayer/.venv/bin/python
$P test_features_agnostic.py;  echo "features_agnostic=$?"
$P test_surrogate_gates.py;    echo "gates=$?"
$P test_surrogate_features.py; echo "features=$?"
$P test_surrogate_v2.py;       echo "v2=$?"
$P test_surrogate_support.py;  echo "support=$?"
$P audit_objective.py;         echo "audit_objective=$?"
$P audit_action_vocab.py;      echo "audit_action_vocab=$?"
cd /home/chahj578/Construction_OODlayer
timeout 5400 julia +lts --project=. -e 'using Pkg; Pkg.test()' 2>&1 | grep -a -A 8 "Test Summary:"
```

Expected: 파이썬 전부 exit 0, `Pkg.test()` = **11 pass / 1 error**.

- [ ] **Step 4: 630판 재스윕**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
# ★ 누적 파일이라 반드시 회전 — 안 하면 옛 ok 항목이 남아 거짓 합격이 난다
mv _night/status_shards.jsonl _night/status_shards_pre_surrogate_v2.jsonl
mkdir -p results_4pol_pre_surrogate_v2 && mv results_4pol/shards results_4pol_pre_surrogate_v2/shards
bash run_4pol_parallel.sh --jobs 40
```

완료 후 병합·분석:

```bash
/home/chahj578/Construction_OODlayer/.venv/bin/python merge_shards.py \
  --shards-dir results_4pol/shards --out-dir results_4pol \
  --cases battery,fault,all,fault_battery,fault_zone,battery_zone,zone --seeds $(seq -s, 1 30)
```

**핵심 확인:** `battery` / `fault` / `fault_battery` 의 surrogate 매크로 분포가 **서로 달라야
한다.** 2026-08-13 에는 셋 다 `Replace×120 · ReformTeam×17` 로 동일했다.

- [ ] **Step 5: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add src/respec/llm_service/dspy_service.py
git commit -m "feat(surrogate): deploy the two-head DeltaJ ranker

서비스가 SurrogateV2 의 ΔJ 오름차순으로 순위를 낸다(현행은 내림차순이라 부호를
뒤집지 않으면 최악의 팔을 고른다). support 기반 후보 탈락과 UNSUPPORTED 규약은 유지.
spec §6 단계 6."
```

---

## 부록 A: 시간 추정

| 태스크 | 코드 | 검증 | 합계 |
|---|---|---|---|
| 1 psi(8) | ~10분 | ~5분 | **15분** |
| 2 G3·G4 게이트 | ~40분 | ~10분 | **50분** |
| 3 라벨러 물리 정렬 | ~15분 | ~10분 (Julia 로드) | **25분** |
| 4 재라벨 캠페인 | ~40분 | **수 시간~수십 시간** (계산) | **가장 긴 항목** |
| 5 feature 조립기 | ~40분 | ~10분 | **50분** |
| 6 2-헤드 + 평가 | ~90분 | ~30분 | **2시간** |
| 7 배포 + 재스윕 | ~40분 | ~70분 (스윕 62분) | **2시간** |

**태스크 1·2 는 데이터 없이 즉시 가능하고 위험이 0 이다.** 4 가 이 계획의 병목이다.

## 부록 B: 이 계획이 다루지 않는 것

- 신경망 (데이터 부족 — spec §3.1, §7)
- λ 재튜닝 (식별되지 않음 — J 단위 전환으로 λ 자체를 없앤다)
- `build_final_table.py` 의 오라클 ceiling (별개 게이트)
- DP 계획 (`docs/superpowers/plans/2026-08-13-dp-oracle.md`)

---

## Self-Review

**Spec coverage:**

| Spec 절 | 담당 태스크 |
|---|---|
| D1 (절대값 회귀 → 순위) | 태스크 6 (ΔJ) |
| D2 (λ 식별 불가) | 태스크 6 (J 단위 전환으로 λ 제거) |
| D3 (학습/배포 물리 불일치) | 태스크 3 |
| D4 (팔 커버리지) | 태스크 4 Step 3·5 |
| D5 (`psi(8) == psi(0)`) | 태스크 1 |
| D6 (학습 타깃 ≠ 채점) | 태스크 6 (타깃이 J 성분) |
| §3.3 (2-헤드) | 태스크 6 Step 3 |
| §3.4 (21차원 입력) | 태스크 5 |
| §3.5 (출력 3종) | 태스크 6 (`predict_delta_J`/`predict_complete_proba`; **σ̂ 는 미구현 — 아래 참조**) |
| §3.6 (하이퍼파라미터·Ridge 베이스라인) | 태스크 6 Step 3·5 |
| §4 G1·G2 | 태스크 6 Step 5 |
| §4 G3·G4 | 태스크 2 |
| §4 G5 | 태스크 7 Step 3 |
| §5 데이터 요구사항 | 태스크 3·4 |
| §6 순서 | 태스크 1→2→3→4→5→6→7 |

**미커버 (의도적):** spec §3.5 의 3차 출력 `σ̂`(불확실성)는 태스크에 없다. `HistGradientBoosting`
은 트리 분산을 안 주므로 RF 로 바꾸거나 분위수 회귀를 붙여야 하는데, 그것은 라우터 배선
(`novelty p` 와의 결합)까지 건드리는 **별도 설계**다. 이 계획은 상수 붕괴를 고치는 데 집중한다.
`σ̂` 가 필요해지면 태스크 6 의 `_HP` 를 RF 로 바꾸고 `predict_delta_J` 옆에
`predict_sigma` 를 붙이는 후속 태스크로 낸다.

**Placeholder scan:** "TBD"/"적절히"/"비슷하게" 없음. 태스크 4 Step 2·3 과 태스크 6 Step 5,
태스크 7 Step 1 은 코드 전문 대신 **요구사항 + 확인 명령**으로 썼다 — 그 셋은 저장소의 현재
스크립트 구조(라벨러의 팔 손잡이 이름, 라벨 파일명, 서비스 함수 본문)에 의존하므로, 실행자가
먼저 읽고 맞춰야 하고 여기서 코드를 지어내면 틀린 코드를 그대로 심게 된다. 각 스텝에 **무엇을
먼저 grep 해서 확인할지**를 명시했다.

**Type consistency:**
- `psi(m) -> dict[str, float]` (키 = `PSI_AXES`) — 태스크 1 이 정의, 태스크 5 가 소비
- `build_features(rows) -> DataFrame[FEATURE_NAMES]` — 태스크 5 정의, 태스크 6 소비
- `SurrogateV2.predict_delta_J(rows, ref_macro=0) -> np.ndarray` (낮을수록 좋음) — 태스크 6 정의,
  태스크 7 소비. **부호 규약이 현행 서비스와 반대**라는 점을 태스크 7 Step 1 에 명시했다.
- `gate_g3_beats_constant(instances, choices, margin=0.0) -> (bool, dict)` /
  `gate_g4_kind_discrimination(instances, choices, min_kinds=2) -> (bool, dict)` — 태스크 2 정의,
  태스크 6 Step 5 소비. `instances` 원소 스키마 `{"instance","kind","truth","valid"}` 를 양쪽에 동일하게 적었다.
