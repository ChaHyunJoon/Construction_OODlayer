# 라우터 3-way 데모 UI + 자연어 해석 + DP 천장 기록 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** UI 가 OOD/failure 사건을 **canonical / surrogate / LLM 3-way 라우터**로 배분하는 판을 렌더링하고, 각 사건을 자연어로 해석해 보여주며, 5개 control 의 결과 비교표를 `FINAL.md` 로 낸다. DP 는 라우터·UI 에 넣지 않고 **천장 행으로 기록만** 한다.

**Architecture:** 결정·근거·레인별 선택은 이미 `policy.jl` 이 한 레코드에 전부 기록하고 있다 — 그래서 새로 만드는 것은 (1) 레인 선택 분기표를 **순수 함수로 분리**해 3-way 로 넓힌 것, (2) 그 레코드를 문장으로 바꾸는 **순수 서술기**, (3) DP 표(격자 → replay 표집 → backward induction)뿐이다. 이 하니스는 프로세스 간 재현성이 없으므로 **모든 게이트는 순수 파이썬 단위검사이거나 인프로세스 검사**이고, 스윕 숫자는 산출물이지 검증 수단이 아니다.

**Tech Stack:** Julia 1.10 (`julia +lts --project=.`) — 라우터·서술기·표집기 / Python 3.12 (`/home/chahj578/Construction_OODlayer/.venv/bin/python`) — DP 솔버·표 조립 / 대시보드는 바닐라 JS (`tools/monitor/dashboard.html`)

**Spec:** `docs/superpowers/specs/2026-08-13-router-ui-demo-design.md`
(그 문서 §5 가 `docs/superpowers/specs/2026-08-13-dp-oracle-design.md` 를 개정한다. 원문에는 개정 배너가 붙어 있다 — **원문을 단독으로 읽지 말 것.**)

## Global Constraints

이 절의 요구사항은 **모든 태스크에 암묵적으로 포함**된다.

1. **작업 디렉토리 = `/home/chahj578/Construction_OODlayer`**, 브랜치 = `oracle-rebuild-night-2026-08-10` (main/master 아님).
2. **Python 은 언제나 `/home/chahj578/Construction_OODlayer/.venv/bin/python`.** Julia 는 언제나 `julia +lts --project=.` (Manifest 가 1.10.11 에 고정 — 새 Julia 로 `Pkg.add` 하면 조용히 빌드가 깨진다).
3. **목적함수 상수(`C_fail`·`C_unclosed`·`tie_eps`·`kappa`·`M_ref`·`E_ref`)를 리터럴로 복붙하지 않는다.** 반드시 `objective.load()` / `objective.J()` 로 읽는다. `audit_objective.py` 항목 1 이 12개 파일을 스캔해 잡는다. API: `objective.load() -> dict`, `objective.J(*, complete, closed, total, makespan, energy_J=None)`, `objective.J_row(row)`, `objective.objective_hash()`.
4. **`audit_objective.py` 는 언제나 exit 0 (9/9)** 이어야 한다. **문서에 `objective_hash` 를 문자열로 적지 않는다** — 항목 9 가 스테일 문서로 판정한다. 이 계획서에도 해시 리터럴이 없다.
5. **행동 어휘 단일 진실원 = `wm4spacecraft_manufacturing/action_registry.json`.** 매크로 id/이름/비용을 복붙하지 않는다. `audit_action_vocab.py` 6/6 유지.
6. **기대 baseline(실패 아님): `julia +lts --project=. -e 'using Pkg; Pkg.test()'` = 11 pass / 1 error** (Gurobi 라이선스 없음). 그보다 나빠지면 회귀다.
7. **`test_surrogate_support.py` 7/7 유지.**
8. **시뮬레이션 결과로 코드 변경을 검증하지 않는다.** 이 하니스는 프로세스 간 재현성이 없다(바이트 동일한 소스가 재컴파일 후 다른 배정 지문을 냈다 — CLAUDE.md Gotchas). 검증은 순수 함수 단위검사로 한다.
9. **비교 런·스윕은 순차 실행**(함정 30). 병렬이면 HiGHS 가 다른 스케줄을 내 비교가 무효가 되고, 판당 ~2.5GB 라 OOM 도 난다.
10. **DP 는 라우터/UI 에 들어가지 않는다.** `pol["dp"]` 를 대시보드에 노출하지 않고, `route()` 의 타깃 집합에도 넣지 않는다. DP 는 스윕 레인과 `FINAL.md` 천장 행에만 존재한다.
11. 커밋 메시지는 저장소 관례(한국어, `feat(scope):` / `fix(scope):` / `test(scope):` / `docs(scope):`). 각 태스크는 자기 커밋을 남긴다.
12. **조용한 폴백 금지.** 폴백·미커버·미측정은 반드시 산출물과 화면에 이름으로 남는다. 이 저장소의 반복된 사고 유형이다.

---

## 계획 수립 중 확인된 사실 (실행자가 다시 확인하지 않아도 되는 것)

측정 시각 2026-08-14 새벽, 이 계획을 쓰면서 직접 실행해 확인했다.

| 사실 | 근거 |
|---|---|
| `build_final_table.py` 는 **지금 실제로 죽는다** | `ObjectiveError: 완주 런인데 energy_J 가 없다: None`, 문제 행 `instance='fault_s1_sev1.0_sp3_f58' macro=1 complete=True closed=291 total=313 makespan=24.475 energy_J=None`. 천장 계산은 `build_md_report.compute_ceilings()` 가 한다 (`build_final_table.py:510,522`) |
| `audit_objective.py` 는 지금 exit 0 (9/9) | 직접 실행 |
| LLM 근거는 **이미 스트림에 있다** | `dspy_service.py:157` `reasoning: OutputField(desc="one sentence")` → `:553` `"rationale": d["reasoning"]` → `policy.jl:712` |
| 라우터는 지금 2-way | `policy.jl:350` `would = v.novel ? "dspy" : "surrogate"` |
| surrogate 미지원 팔은 **dspy 로만** escalate 한다 | `policy.jl:754` `escalation_reason = "no training support for $(miss)"` → `:758` `enacted = "dspy"` |
| DSPy 불가 시 canonical 로 떨어지는 경로가 이미 있다 | `policy.jl:730` `enacted = "canonical"; fell_back = (requested != "canonical")` |
| 스윕 기본 정책이 3개다 | `run_4pol.sh:30` · `run_shard.sh:41` `POLICIES="${4:-noop,surrogate,dspy}"`. `run_4pol.sh:57,196` 에 **`3` 이 하드코딩**돼 있다(`EXPECTED_ROWS=$(( N_SEEDS * 3 ))`) |
| 배포 레인은 배터리를 **무조건** 켠다 (kind 무관) | `run_demo.jl:500` `enable_battery!(env; params=BatteryParams())`, `:519` stall, `:522` derate |
| 라벨러는 **battery instance 에서만** 켠다 | `gen_oracle_dataset.jl:1176` `_arm_battery!` — 이것이 fault/zone 행의 `energy_J=None` 원인 |
| 표집 경로는 `replay` 이고 fork 는 구조적으로 불가 | `dp_oracle/PROBE_RESULT.md` — 지문 10/10 동일, 웜 **8.1s/rollout**, 콜드 88.0/91.0s |

**spec 대비 의도적 편차 1개 (실행자는 이대로 한다):** spec §5.3 은 energy-only 배터리 모드를 **라벨러에도** 적용하는 것을 선행조건으로 적었다. 이 계획은 **라벨러를 건드리지 않는다.** 라벨 재생성은 수 시간짜리 캠페인이고 오늘 밤 surrogate 재라벨과 CPU 를 다투며, 2일 기한 안에서 표를 내는 데 필요하지 않기 때문이다. 대신 Task 1 이 천장 계산을 **미측정으로 낮추고**, energy-only 모드는 **Task 6 의 DP 표집기 안에서만** 켠다. 이 편차는 spec §5.3·§6 에 반영돼 있어야 한다 — Task 1 Step 6 이 그 문서 갱신을 포함한다.

---

## File Structure

| 파일 | 신규/수정 | 책임 |
|---|---|---|
| `wm4spacecraft_manufacturing/build_md_report.py` | 수정 | `compute_ceilings()` 가 J 불가 행에서 죽지 않고 **미측정**으로 낮춘다 |
| `wm4spacecraft_manufacturing/test_ceilings_degrade.py` | 신규 | 위 계약의 단위검사 |
| `tools/monitor/narrate.jl` | 신규 | 레코드 → 자연어 문장. **순수 함수만.** 의존성 없음 |
| `tools/monitor/test_narrate.jl` | 신규 | 서술기 계약 5개 |
| `tools/monitor/lane_select.jl` | 신규 | 레인 선택 분기표(3-way). **순수 함수만.** 의존성 없음 |
| `tools/monitor/test_lane_select.jl` | 신규 | 분기표 전수 |
| `tools/monitor/policy.jl` | 수정 | 위 둘을 `include` 해서 쓴다. 판정 문구에 3-way 를 반영 |
| `tools/monitor/dashboard.html` | 수정 | `narrative` 노출 · `rationale` 상태 구분 · 라우터 OFF 배지 |
| `wm4spacecraft_manufacturing/dp_oracle/grid_spec.json` | 신규 | 축·구간·가지치기의 **단일 진실원** |
| `wm4spacecraft_manufacturing/dp_oracle/derive_grid.py` | 신규 | 현행 세대 스윕에서 축을 유도해 위 파일을 쓴다 |
| `wm4spacecraft_manufacturing/dp_oracle/test_derive_grid.py` | 신규 | 유도 규칙 단위검사 |
| `wm4spacecraft_manufacturing/dp_oracle/sample_grid.jl` | 신규 | replay 표집기 → `samples.jsonl` |
| `wm4spacecraft_manufacturing/dp_oracle/dp_solve.py` | 신규 | backward induction + value iteration → `value.json` |
| `wm4spacecraft_manufacturing/dp_oracle/test_dp_solve.py` | 신규 | 손계산 격자로 솔버 검증 |
| `wm4spacecraft_manufacturing/dp_oracle_policy.py` | 신규 | φ̃ → 표 조회 → a\*. **스윕 `dp` 레인 전용** |
| `wm4spacecraft_manufacturing/run_4pol.sh`·`run_shard.sh` | 수정 | 정책 수 하드코딩(`3`) 제거 |

---

## Task 1: 천장 계산이 죽지 않고 미측정으로 낮아지게

**목적:** `FINAL.md` 를 오늘 낼 수 있게 만든다. 지금은 fault kind 라벨 행의 `energy_J=None` 때문에 `ObjectiveError` 로 exit 1 이다.

**핵심:** 이것은 **숫자를 지어내는 변경이 아니다.** J 를 계산할 수 없는 행은 계산하지 않고 그 사실을 이름으로 남긴다. `build_final_table.py` 머리말의 기존 규약과 같다 — "결측은 절대 0 도 빈칸도 아니다. `미측정` 으로 명시한다."

**Files:**
- Modify: `wm4spacecraft_manufacturing/build_md_report.py` (`compute_ceilings`)
- Create: `wm4spacecraft_manufacturing/test_ceilings_degrade.py`

**Interfaces:**
- Consumes: `objective.J_row(row)`, `objective.ObjectiveError`
- Produces: `compute_ceilings(oracle_dir)` 가 예외를 던지지 않고, 반환 dict 의 각 축 키에 `unscorable`(int) 과 `scored`(int) 를 담는다. Task 9 의 `FINAL.md` 가 이 둘을 읽어 미측정 표기를 낸다.

- [ ] **Step 1: 지금 어떻게 죽는지 눈으로 본다**

```bash
cd /home/chahj578/Construction_OODlayer
.venv/bin/python wm4spacecraft_manufacturing/build_final_table.py \
  --results-dir wm4spacecraft_manufacturing/results_4pol --out-dir /tmp/ft_probe 2>&1 | tail -6
echo "exit=${PIPESTATUS[0]}"
```

Expected: `ObjectiveError: 완주 런인데 energy_J 가 없다/유한하지 않다: None`, exit != 0.
**여기서 안 죽으면 멈추고 보고한다** — 누가 이미 고쳤다는 뜻이고, 그러면 이 태스크의 전제가 사라진다.

- [ ] **Step 2: `compute_ceilings` 의 현재 구조를 읽는다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
grep -n "def compute_ceilings" -A 60 build_md_report.py
```

**행마다 J 를 계산하는 자리**(`objective.J_row` 또는 `objective.J` 호출)를 찾는다. 아래 코드는 그 자리를 감싸는 것이고, 변수 이름은 실제 코드에 맞춘다 — **추측하지 않는다.**

- [ ] **Step 3: 실패하는 단위검사를 먼저 쓴다**

`wm4spacecraft_manufacturing/test_ceilings_degrade.py`:

```python
#!/usr/bin/env python3
"""compute_ceilings 가 J 불가 행에서 죽지 않고 미측정으로 낮추는지 검사한다.

왜 이 검사가 있는가
==================
2026-08-14 실측: fault kind 라벨 행은 `energy_J=None` 이다(배터리 레이어가
`kind===:battery` instance 에서만 켜지기 때문 — gen_oracle_dataset.jl:1176 `_arm_battery!`).
`objective.J` 는 그런 행을 설계대로 던진다. 그 예외가 build_final_table.py 전체를 죽여서
**표가 하나도 안 나왔다.**

고치는 방향이 중요하다: J 를 0 으로 채우거나 그 행을 조용히 빼면 천장이 낙관 편향된다.
계산할 수 없는 행은 **세어서 이름으로 남긴다.**
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import objective                      # noqa: E402
from build_md_report import compute_ceilings   # noqa: E402

FAILS = []


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + ("   " + detail if detail else ""))
    if not cond:
        FAILS.append(name)


def main():
    print("== compute_ceilings 미측정 강등 ==")

    # 계약 (a): 실제 라벨 디렉토리로 불러도 예외가 안 난다.
    oracle_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "oracle", "out")
    try:
        ceilings = compute_ceilings(oracle_dir)
        raised = None
    except objective.ObjectiveError as e:
        ceilings, raised = None, e
    check("실제 라벨셋에서 ObjectiveError 가 안 난다", raised is None, str(raised or ""))

    if ceilings is None:
        print("\n실패 1개 이상 — 아래 검사는 건너뛴다")
        return 1

    # 계약 (b): 축마다 scored/unscorable 를 센다.
    axes = sorted(ceilings)
    check("축이 하나 이상 있다", len(axes) > 0, str(axes))
    for k in axes:
        v = ceilings[k]
        check("축 %s 에 scored 가 있다" % k, isinstance(v, dict) and "scored" in v, str(v)[:120])
        check("축 %s 에 unscorable 이 있다" % k, isinstance(v, dict) and "unscorable" in v,
              str(v)[:120])

    # 계약 (c): unscorable 이 하나라도 있으면 그 축의 천장은 None 이다 (0 이 아니다).
    for k in axes:
        v = ceilings[k]
        if v.get("unscorable", 0) > 0 and v.get("scored", 0) == 0:
            check("축 %s: 채점 가능한 행이 0 이면 천장이 None" % k, v.get("ceiling") is None,
                  str(v.get("ceiling")))

    # 계약 (d): 아무 행도 0.0 으로 채워지지 않았다.
    zero_filled = [k for k, v in ceilings.items()
                   if v.get("ceiling") == 0.0 and v.get("scored", 0) == 0]
    check("채점 0건인 축이 0.0 으로 채워지지 않았다", not zero_filled, str(zero_filled))

    print("\n%s" % ("전부 통과" if not FAILS else "실패 %d개: %s" % (len(FAILS), FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: 검사가 실패하는지 확인한다 (수정 전)**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python test_ceilings_degrade.py; echo "exit=$?"
```

Expected: `exit=1`, 첫 검사 `실제 라벨셋에서 ObjectiveError 가 안 난다` 가 FAIL.

- [ ] **Step 5: `compute_ceilings` 를 고친다**

Step 2 에서 찾은 J 계산 자리를 아래 형태로 감싼다. **행을 버리지 않고 센다:**

```python
        # 2026-08-14: J 를 계산할 수 없는 행이 있다 — fault/zone kind 라벨은 배터리 레이어가
        # 안 켜진 채 만들어져 energy_J 가 없다(gen_oracle_dataset.jl:1176 `_arm_battery!` 는
        # kind===:battery 에서만 켠다). objective.J 는 그런 행을 설계대로 던진다.
        #
        # 그 예외를 여기서 잡는 이유: 던지게 두면 표 전체가 안 나오고, 0 으로 채우면 천장이
        # 낙관 편향된다. 계산할 수 없는 행은 **세어서 이름으로 남긴다** — build_final_table.py
        # 머리말의 규약과 같다("결측은 절대 0 도 빈칸도 아니다").
        try:
            j = objective.J_row(row)
        except objective.ObjectiveError:
            n_unscorable += 1
            continue
        n_scored += 1
```

그리고 축별 반환값에 두 수를 담는다:

```python
    out[axis_key] = {
        "ceiling": (best if n_scored else None),   # 채점 0건이면 None. 0.0 이 아니다.
        "scored": n_scored,
        "unscorable": n_unscorable,
    }
```

**주의:** 기존 반환값이 스칼라(천장 값 자체)였다면 소비처가 깨진다. `build_final_table.py:522` `oracle_ceiling_summary_for_case()` 와 `:531` `render_row_cells()` 가 이 값을 읽는다 — 두 곳을 dict 형태에 맞게 같이 고친다. **소비처를 안 고치고 반환형만 바꾸면 조용히 틀린 표가 나온다.**

- [ ] **Step 6: 검사가 통과하는지 + 표가 실제로 나오는지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer
.venv/bin/python wm4spacecraft_manufacturing/test_ceilings_degrade.py; echo "test_exit=$?"
.venv/bin/python wm4spacecraft_manufacturing/build_final_table.py \
  --results-dir wm4spacecraft_manufacturing/results_4pol --out-dir /tmp/ft_probe; echo "table_exit=$?"
grep -c "미측정" /tmp/ft_probe/FINAL.md || true
```

Expected: `test_exit=0`, `table_exit=0`, `FINAL.md` 가 생기고 미측정 표기가 1개 이상.

- [ ] **Step 7: spec 의 편차를 문서에 반영한다**

`docs/superpowers/specs/2026-08-13-router-ui-demo-design.md` §5.3 과 §6 에, 라벨러는 이 사이클에서 건드리지 않고 천장이 미측정으로 낮아진다는 결정을 적는다(이 계획서 "spec 대비 의도적 편차" 절과 같은 내용). **문서에 `objective_hash` 문자열을 적지 않는다.**

- [ ] **Step 8: 회귀 게이트 + 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
.venv/bin/python wm4spacecraft_manufacturing/audit_objective.py;      echo "audit_objective=$?"
.venv/bin/python wm4spacecraft_manufacturing/audit_action_vocab.py;   echo "audit_vocab=$?"
git add wm4spacecraft_manufacturing/build_md_report.py \
        wm4spacecraft_manufacturing/build_final_table.py \
        wm4spacecraft_manufacturing/test_ceilings_degrade.py \
        docs/superpowers/specs/2026-08-13-router-ui-demo-design.md
git commit -m "fix(report): 천장 계산이 J 불가 행에서 죽지 않고 미측정으로 낮아진다

fault kind 라벨 행은 energy_J 가 없어(배터리 레이어가 battery instance 에서만 켜진다)
objective.J 가 설계대로 던졌고, 그 예외 하나가 build_final_table.py 전체를 죽여 표가
하나도 안 나왔다. 계산 불가 행을 0 으로 채우거나 조용히 빼면 천장이 낙관 편향되므로
세어서 이름으로 남긴다. 라벨 재생성은 이 사이클 범위 밖."
```

---

## Task 2: 자연어 서술기 (`narrate.jl`)

Spec §4.1. **순수 함수만. LLM 호출 없음. 시뮬 0회.**

**Files:**
- Create: `tools/monitor/narrate.jl`
- Create: `tools/monitor/test_narrate.jl`

**Interfaces:**
- Consumes: 없음 (의존성 0 — 이것이 요점이다. 테스트가 즉시 돈다)
- Produces:
  - `narrate_event(ev::AbstractDict) -> String`
  - `narrate_outcome(sm::AbstractDict) -> String`
  - Task 3 이 `policy.jl` 에서 이 둘을 부르고, Task 4 가 화면에 띄운다.

- [ ] **Step 1: 실패하는 검사를 먼저 쓴다**

`tools/monitor/test_narrate.jl`:

```julia
# tools/monitor/test_narrate.jl
# 서술기 계약 검사. 합성 레코드만 쓴다 — 시뮬을 돌리지 않으므로 즉시 끝난다.
#
# 실행: julia +lts --project=. tools/monitor/test_narrate.jl
using Test
include(joinpath(@__DIR__, "narrate.jl"))

@testset "narrate_event" begin
    ev = Dict("kind" => "battery", "severity" => 0.9, "soc" => 0.02, "spare_count" => 3,
              "agent_pending" => 5, "progress" => 0.43, "robot" => "R7",
              "enacted" => "surrogate", "macro_name" => "SwapBattery",
              "fell_back" => false,
              "policies" => Dict("surrogate" => Dict("rationale" => "learned model",
                                                     "available" => true)))
    s = narrate_event(ev)
    @test occursin("battery", lowercase(s))
    @test occursin("SwapBattery", s)
    @test occursin("R7", s)

    # 계약 2: 없는 필드를 지어내지 않는다.
    bare = Dict("kind" => "fault", "enacted" => "canonical", "macro_name" => "Replace",
                "fell_back" => false)
    b = narrate_event(bare)
    @test !occursin("soc", lowercase(b))
    @test !occursin("nothing", lowercase(b))
    @test !occursin("missing", lowercase(b))

    # 계약 4: 폴백은 반드시 말한다.
    fb = Dict(bare..., "fell_back" => true, "requested" => "dspy")
    f = narrate_event(fb)
    @test occursin("fell back", lowercase(f)) || occursin("fallback", lowercase(f))
    @test occursin("dspy", lowercase(f))
end

@testset "narrate_outcome" begin
    # 계약 3: 완주인데 closed<total 을 미완주로 서술하지 않는다.
    #         이 하니스는 완주해도 closed<total 이다(실측 291/313, md/README.md §6).
    done = Dict("complete" => true, "closed" => 291, "total" => 313, "n_stalled" => 0)
    d = narrate_outcome(done)
    @test occursin("complete", lowercase(d))
    @test !occursin("incomplete", lowercase(d))
    @test !occursin("did not finish", lowercase(d))

    # 계약 5: 정지 0 을 "문제 없음" 으로 서술하지 않는다 — 미완주는 정지 없이도 일어난다.
    nostall = Dict("complete" => false, "closed" => 254, "total" => 313, "n_stalled" => 0)
    n = narrate_outcome(nostall)
    @test occursin("incomplete", lowercase(n))
    @test !occursin("no problem", lowercase(n))
    @test !occursin("healthy", lowercase(n))

    stalled = Dict("complete" => false, "closed" => 254, "total" => 313, "n_stalled" => 43)
    st = narrate_outcome(stalled)
    @test occursin("43", st)
    @test occursin("stall", lowercase(st))

    # 계약 2: n_stalled 가 없으면 정지를 아예 언급하지 않는다.
    #         (로그의 [STALL] 은 Logging.Warn 에 삼켜지므로 n_stalled 가 유일한 기계적 증거다.)
    unknown = Dict("complete" => false, "closed" => 254, "total" => 313)
    u = narrate_outcome(unknown)
    @test !occursin("stall", lowercase(u))
end

@testset "purity" begin
    ev = Dict("kind" => "zone", "enacted" => "canonical", "macro_name" => "RelocateBuild",
              "fell_back" => false)
    @test narrate_event(ev) == narrate_event(ev)
end
```

- [ ] **Step 2: 검사가 실패하는지 확인한다 (모듈이 아직 없다)**

```bash
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. tools/monitor/test_narrate.jl 2>&1 | tail -5; echo "exit=$?"
```

Expected: `narrate.jl` 이 없어서 `SystemError`/`could not open file`. exit != 0.

- [ ] **Step 3: 서술기를 쓴다**

`tools/monitor/narrate.jl`:

```julia
# tools/monitor/narrate.jl
# =============================================================================
# 스트림 레코드를 사람이 읽는 문장으로 바꾼다. **순수 함수만** — 파일·네트워크·시각을 읽지 않는다.
#
# 왜 LLM 을 안 쓰는가
# ------------------
#  (1) 입력이 이미 구조화된 수치다. 문장으로 바꾸는 데 모델이 필요하지 않다.
#  (2) 이 하니스는 프로세스 간 재현성이 없어서 시뮬 결과로는 아무것도 검증할 수 없는데,
#      순수 함수는 단위검사로 고정할 수 있다.
#  (3) 이 레인의 LLM 은 **정책 후보**다. 해석까지 LLM 이 하면 화면의 서술과 피고가 같은 모델이 된다.
#
# 절대 하지 않는 것
# ----------------
#  · 없는 필드를 지어내지 않는다. n_stalled 가 없으면 정지를 **언급하지 않는다**
#    (로그의 [STALL] 은 run_demo.jl:472 의 Logging.Warn 에 삼켜지므로 n_stalled 가 유일한
#     기계적 증거다 — "로그에 없다"를 "안 일어났다"로 읽으면 안 된다).
#  · complete==true 인데 closed<total 인 것을 미완주로 서술하지 않는다. 이 하니스는 완주해도
#    closed<total 이다(실측 291/313, md/README.md §6).
#  · 정지 0 을 "문제 없음" 으로 쓰지 않는다. 미완주는 정지 없이도 일어난다.
#  · 폴백이 있었으면 **반드시** 말한다(조용한 폴백 금지).
# =============================================================================

_has(d, k) = haskey(d, k) && d[k] !== nothing

_num(x, nd = 2) = try string(round(Float64(x); digits = nd)) catch; string(x) end

"""
    narrate_event(ev) -> String

한 OOD 결정을 서술한다: 무엇이 주입됐고, 누가 정했고, 무슨 팔을 골랐는가.
`ev` 는 policy.jl 이 만드는 레코드(또는 그 부분집합)를 담은 Dict.
"""
function narrate_event(ev::AbstractDict)
    parts = String[]

    kind = _has(ev, "kind") ? String(ev["kind"]) : "unknown"
    ctx = String[]
    _has(ev, "severity")      && push!(ctx, "severity " * _num(ev["severity"]))
    _has(ev, "soc")           && push!(ctx, "SoC " * _num(ev["soc"]))
    _has(ev, "spare_count")   && push!(ctx, string(ev["spare_count"]) * " spares left")
    _has(ev, "agent_pending") && push!(ctx, string(ev["agent_pending"]) * " pending jobs")
    _has(ev, "progress")      && push!(ctx, "at " * _num(100 * Float64(ev["progress"]), 0) * "% progress")
    who = _has(ev, "robot") ? " on " * String(ev["robot"]) : ""
    push!(parts, "A " * kind * " event fired" * who *
                 (isempty(ctx) ? "." : " (" * join(ctx, ", ") * ")."))

    lane = _has(ev, "enacted") ? String(ev["enacted"]) : "unknown"
    act  = _has(ev, "macro_name") ? String(ev["macro_name"]) : "no action"
    push!(parts, "The " * lane * " lane chose " * act * ".")

    # 폴백은 반드시 말한다.
    if get(ev, "fell_back", false) === true
        req = _has(ev, "requested") ? String(ev["requested"]) : "the routed lane"
        push!(parts, "It fell back to " * lane * " because " * req * " was unavailable.")
    end

    # 그 레인이 남긴 근거가 있으면 그대로 인용한다(지어내지 않는다).
    pol = get(ev, "policies", nothing)
    if pol isa AbstractDict && haskey(pol, lane) && pol[lane] isa AbstractDict
        why = get(pol[lane], "rationale", "")
        why isa AbstractString && !isempty(why) && push!(parts, "Its reason: " * why)
    end

    return join(parts, " ")
end

"""
    narrate_outcome(sm) -> String

런 하나의 결과를 서술한다. `sm` 은 DEMO_SUMMARY 레코드(또는 그 부분집합)를 담은 Dict.
"""
function narrate_outcome(sm::AbstractDict)
    parts = String[]

    complete = get(sm, "complete", nothing)
    closed   = _has(sm, "closed") ? sm["closed"] : nothing
    total    = _has(sm, "total")  ? sm["total"]  : nothing
    ledger = (closed === nothing || total === nothing) ? "" :
             " (" * string(closed) * "/" * string(total) * " nodes closed)"

    if complete === true
        # 완주해도 closed<total 이 정상이다 — 이 차이를 미완주로 쓰지 않는다.
        push!(parts, "The build completed" * ledger * ".")
    elseif complete === false
        push!(parts, "The build was incomplete" * ledger * ".")
    else
        push!(parts, "Completion is not recorded for this run" * ledger * ".")
    end

    if _has(sm, "n_stalled")
        n = sm["n_stalled"]
        push!(parts, n == 0 ?
            "No robot stalled; the shortfall came from something other than battery stalls." :
            string(n) * " robot stalls were recorded.")
    end
    # n_stalled 가 없으면 정지를 **언급하지 않는다**.

    return join(parts, " ")
end
```

- [ ] **Step 4: 검사가 통과하는지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. tools/monitor/test_narrate.jl; echo "exit=$?"
```

Expected: `exit=0`, `Test Summary` 에 실패 0.

- [ ] **Step 5: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add tools/monitor/narrate.jl tools/monitor/test_narrate.jl
git commit -m "feat(monitor): 결정적 자연어 서술기 + 계약 검사

레코드를 문장으로 바꾸는 순수 함수. LLM 을 쓰지 않는 이유는 셋이다 — 입력이 이미
구조화돼 있고, 순수 함수라야 단위검사로 고정되며(이 하니스는 프로세스 간 재현성이 없다),
LLM 은 이 레인의 정책 후보라 해석까지 맡기면 화면의 서술과 피고가 같은 모델이 된다.
계약: 없는 필드를 지어내지 않는다 · 완주(closed<total)를 미완주로 쓰지 않는다 ·
정지 0 을 '문제 없음' 으로 쓰지 않는다 · 폴백을 반드시 말한다. spec §4.1."
```

---

## Task 3: 라우터 3-way (`lane_select.jl`) + `policy.jl` 배선

Spec §3. **분기표를 순수 함수로 분리하는 것이 이 태스크의 핵심이다** — `policy.jl` 은 67KB 이고 ENV·CB 의존이라 통째로는 단위검사가 안 된다.

**Files:**
- Create: `tools/monitor/lane_select.jl`
- Create: `tools/monitor/test_lane_select.jl`
- Modify: `tools/monitor/policy.jl` (`route()` 부근 `:317-370`, escalation 블록 `:749-758`, 레코드 방출부 `:860-883`)

**Interfaces:**
- Consumes: 없음 (순수)
- Produces:
  - `select_lane(; novel::Bool, available::AbstractDict, supported::Bool, policy::AbstractString) -> NamedTuple{(:lane, :reason)}`
  - `policy.jl` 이 이것을 쓰고, Task 4 가 `reason` 을 화면에 띄운다.

- [ ] **Step 1: 실패하는 검사를 먼저 쓴다**

`tools/monitor/test_lane_select.jl`:

```julia
# tools/monitor/test_lane_select.jl
# 3-way 분기표 전수 검사. 순수 함수라 즉시 끝난다.
#
# 실행: julia +lts --project=. tools/monitor/test_lane_select.jl
using Test
include(joinpath(@__DIR__, "lane_select.jl"))

const ALL_UP = Dict("surrogate" => true, "dspy" => true, "canonical" => true)

@testset "3-way 분기" begin
    # 낯설다 -> LLM
    r = select_lane(novel = true, available = ALL_UP, supported = true, policy = "router")
    @test r.lane == "dspy"
    @test occursin("novel", lowercase(r.reason))

    # 익숙하다 -> surrogate
    r = select_lane(novel = false, available = ALL_UP, supported = true, policy = "router")
    @test r.lane == "surrogate"
    @test occursin("familiar", lowercase(r.reason))

    # 익숙한데 surrogate 가 그 팔을 지원하지 않는다 -> LLM 으로 에스컬레이션(기존 동작)
    r = select_lane(novel = false, available = ALL_UP, supported = false, policy = "router")
    @test r.lane == "dspy"
    @test occursin("support", lowercase(r.reason))

    # 지원도 없고 LLM 도 죽었다 -> canonical (신규 3번째 주자)
    down = Dict("surrogate" => true, "dspy" => false, "canonical" => true)
    r = select_lane(novel = false, available = down, supported = false, policy = "router")
    @test r.lane == "canonical"
    @test occursin("canonical", lowercase(r.reason))
    @test occursin("unavailable", lowercase(r.reason))

    # 낯선데 LLM 이 죽었다 -> canonical. surrogate 로 조용히 떨어지지 않는다.
    r = select_lane(novel = true, available = down, supported = true, policy = "router")
    @test r.lane == "canonical"

    # surrogate 도 dspy 도 죽었다 -> canonical
    allx = Dict("surrogate" => false, "dspy" => false, "canonical" => true)
    r = select_lane(novel = false, available = allx, supported = true, policy = "router")
    @test r.lane == "canonical"
end

@testset "noop 은 라우팅 대상이 아니다" begin
    # 통제 실험의 바닥선. 아무도 이 레인을 대신 판단해 주면 안 된다(policy.jl:333 규칙).
    r = select_lane(novel = true, available = ALL_UP, supported = true, policy = "noop")
    @test r.lane == "noop"
end

@testset "DP 는 절대 타깃이 아니다" begin
    # Global Constraint 10. DP 는 천장이라 실행 정책과 같은 줄에 세우지 않는다.
    for nov in (true, false), sup in (true, false)
        r = select_lane(novel = nov, available = Dict("surrogate" => sup, "dspy" => sup,
                                                      "canonical" => true, "dp" => true),
                        supported = sup, policy = "router")
        @test r.lane != "dp"
    end
end

@testset "reason 은 언제나 비지 않는다" begin
    for nov in (true, false), sup in (true, false), d in (true, false)
        r = select_lane(novel = nov,
                        available = Dict("surrogate" => true, "dspy" => d, "canonical" => true),
                        supported = sup, policy = "router")
        @test !isempty(r.reason)
    end
end
```

- [ ] **Step 2: 검사가 실패하는지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. tools/monitor/test_lane_select.jl 2>&1 | tail -5; echo "exit=$?"
```

Expected: `lane_select.jl` 부재로 exit != 0.

- [ ] **Step 3: 분기표를 쓴다**

`tools/monitor/lane_select.jl`:

```julia
# tools/monitor/lane_select.jl
# =============================================================================
# 라우터의 **레인 선택 분기표**. 순수 함수 하나뿐이고 의존성이 없다 — policy.jl 은 67KB 에
# ENV·ConstructionBots 의존이라 통째로는 단위검사가 안 되기 때문에, 판단 규칙만 여기로 뺀다.
#
# 3-way 인 이유 (2026-08-14):
#   예전에는 타깃이 {surrogate, dspy} 뿐이었다(policy.jl:350). 그런데 surrogate 가 그 팔을
#   지원하지 않으면 dspy 로만 에스컬레이션하고(:754), dspy 가 죽어 있으면 :730 에서 조용히
#   canonical 로 떨어졌다. 즉 **canonical 은 이미 사실상 세 번째 주자인데 판정에는 그 사실이
#   안 적혔다.** 여기서 명시적으로 적는다.
#
# DP 는 여기 없다(Global Constraint 10): DP 의 a* 는 오프라인 표집 + backward induction 의
# 산물이라 "결정 시점에 이미 표가 있다" = 그 사건을 미리 다 굴려봤다는 뜻이다. 실행 정책과
# 같은 줄에 세우면 비교가 무의미해진다.
# =============================================================================

"""
    select_lane(; novel, available, supported, policy) -> (lane, reason)

- `novel`     : novelty 판정 (p < eps)
- `available` : 레인 가용성 Dict, 예 `Dict("surrogate"=>true, "dspy"=>false, "canonical"=>true)`
- `supported` : surrogate 가 이 사건에 필요한 팔을 학습셋에서 지원하는가
- `policy`    : DEMO_POLICY. `"noop"` 이면 라우팅하지 않는다(통제 바닥선)

`reason` 은 화면 ROUTER 줄에 그대로 나가므로 영어로 쓴다(이 저장소의 화면 문구 규약).
"""
function select_lane(; novel::Bool, available::AbstractDict, supported::Bool,
                     policy::AbstractString)
    up(k) = get(available, k, false) === true

    # noop 은 후보가 아니라 통제 실험의 바닥선이다. 개입이 실제로 이득인지 재려면 아무도
    # 이 레인을 대신 판단해 주면 안 된다(policy.jl:333 의 기존 규칙).
    policy == "noop" && return (lane = "noop",
        reason = "no-adapt floor — routing disabled for this control lane")

    if novel
        up("dspy") && return (lane = "dspy",
            reason = "novelty p < eps — never seen this before → ask the LLM")
        return (lane = "canonical",
            reason = "novelty p < eps → LLM, but the LLM lane is unavailable → canonical rule")
    end

    if !supported
        up("dspy") && return (lane = "dspy",
            reason = "familiar, but the surrogate has no training support for this arm → escalate to LLM")
        return (lane = "canonical",
            reason = "familiar, but the surrogate has no training support for this arm " *
                     "and the LLM lane is unavailable → canonical rule")
    end

    up("surrogate") && return (lane = "surrogate",
        reason = "novelty p ≥ eps — familiar → surrogate")

    up("dspy") && return (lane = "dspy",
        reason = "familiar, but the surrogate lane is unavailable → LLM")

    return (lane = "canonical",
        reason = "familiar, but both the surrogate and LLM lanes are unavailable → canonical rule")
end
```

- [ ] **Step 4: 검사가 통과하는지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. tools/monitor/test_lane_select.jl; echo "exit=$?"
```

Expected: `exit=0`.

- [ ] **Step 5: `policy.jl` 에 배선한다**

1. 파일 상단 `include` 구역에 두 줄을 넣는다:

```julia
include(joinpath(@__DIR__, "lane_select.jl"))
include(joinpath(@__DIR__, "narrate.jl"))
```

2. `route()`(`:317`)의 `would = v.novel ? "dspy" : "surrogate"`(`:350`) 는 **그대로 둔다** — 그것은 "판정" 이고, 실제 레인 선택은 가용성·지원 여부를 아는 뒤에야 가능하다. `would_route_to` 의 의미가 바뀌지 않아야 기존 녹화와 비교가 된다.

3. 레인이 확정되는 자리(`:697-760` 블록)에서 `select_lane` 을 부르고 그 결과로 `enacted` 를 정한다. `available` 은 이미 계산돼 있는 `pol[k]["available"]` 에서 만들고, `supported` 는 기존 에스컬레이션 조건(`:749-754` 의 "no training support" 판정)을 그대로 쓴다. `rt["reason"]` 에 `select_lane` 의 `reason` 을 **덧붙인다**(덮어쓰지 않는다 — novelty 수치가 든 기존 문구가 화면에서 사라지면 안 된다).

4. 레코드 방출부(`:875-883`)의 NamedTuple 에 두 필드를 추가한다:

```julia
            narrative = narrate_event(Dict("kind" => string(typeof(truth).name.name),
                                           "enacted" => enacted, "macro_name" => chosen,
                                           "fell_back" => fell_back, "requested" => requested,
                                           "policies" => pol)),
```

**주의:** 위 Dict 의 키 이름은 `narrate.jl` 이 읽는 것과 정확히 같아야 한다. `severity`/`soc`/
`spare_count`/`agent_pending`/`progress`/`robot` 은 `truth` 와 서술자에서 꺼내 같은 Dict 에
넣는다 — 그 이름들은 `policy.jl:295-308` 의 `event_descriptors_of` 가 이미 쓰고 있다.

- [ ] **Step 6: 배선이 살아 있는지 인프로세스로 확인한다 (시뮬 없이)**

```bash
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. -e '
include("tools/monitor/lane_select.jl")
r = select_lane(novel=false, available=Dict("surrogate"=>true,"dspy"=>false,"canonical"=>true),
                supported=false, policy="router")
println(r.lane, " | ", r.reason)
@assert r.lane == "canonical"
println("OK")'
julia +lts --project=. -e 'Meta.parseall(read("tools/monitor/policy.jl", String)); println("policy.jl parses OK")'
```

Expected: `canonical | ...`, `OK`, `policy.jl parses OK`.

- [ ] **Step 7: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add tools/monitor/lane_select.jl tools/monitor/test_lane_select.jl tools/monitor/policy.jl
git commit -m "feat(monitor): 라우터를 3-way 로 넓히고 분기표를 순수 함수로 분리

canonical 은 이미 사실상 세 번째 주자였다 — surrogate 가 팔을 지원하지 않으면 dspy 로만
올라갔고(policy.jl:754), dspy 가 죽으면 :730 에서 조용히 canonical 로 떨어졌는데 판정에는
그 사실이 안 적혔다. select_lane 이 그 규칙을 명시적으로 적고, policy.jl 이 67KB·ENV 의존이라
통째로는 검사할 수 없으므로 판단만 의존성 0 인 파일로 뺐다. DP 는 타깃 집합에 넣지 않는다
(천장이라 실행 정책과 같은 줄에 세우면 비교가 무의미하다). spec §3."
```

---

## Task 4: 대시보드 노출

Spec §4. **새로 계산하지 않는다 — 이미 스트림에 있는 것을 화면에 올린다.**

**Files:**
- Modify: `tools/monitor/dashboard.html` (`renderRespec`, `:1143` 부근)

**Interfaces:**
- Consumes: Task 2·3 이 스트림에 넣은 `narrative`, 기존 `policies[lane].rationale`·`available`, `router.enabled`/`advisory`/`reason`
- Produces: 화면. 다른 태스크가 소비하지 않는다.

- [ ] **Step 1: 현재 렌더 지점을 읽는다**

```bash
cd /home/chahj578/Construction_OODlayer
sed -n '1143,1200p' tools/monitor/dashboard.html
```

`renderRespec(rs, history)` 가 결정 하나를 그리는 자리다. `rhead`·`inCode`·`outCode`·`candBody`·
`verifyBody`·`decisionHistory` 의 DOM id 를 확인한다.

- [ ] **Step 2: 세 가지를 넣는다**

1. **narrative** — `selectedDecision.narrative` 가 있으면 결정 카드 위에 문장으로 띄운다.
   **없으면 그 자리를 비운다.** 재스윕 이전 녹화에는 이 필드가 없다 — 지어내지 않는다.

```javascript
      // narrative 는 녹화 시점의 코드가 스트림에 찍은 문장이다. 옛 녹화에는 없다 —
      // 그 경우 자리를 비운다(화면이 문장을 지어내면 그건 측정이 아니라 창작이다).
      var nar = selectedDecision && selectedDecision.narrative;
      $("narrative").textContent = nar ? nar : "";
      $("narrative").style.display = nar ? "" : "none";
```

2. **rationale 의 상태 구분** — 레인별 근거를 표시하되, `available === false` 와
   `rationale === ""` 를 **다르게** 쓴다:

```javascript
      function whyText(p){
        if(!p) return "—";
        if(p.available === false) return "(lane unavailable — no decision was made)";
        if(!p.rationale)          return "(no reason recorded)";
        return p.rationale;
      }
```

   서비스 다운을 "근거 없음" 으로 읽으면 LLM 레인을 오독한다.

3. **라우터 OFF 배지** — `router.enabled === false` 이면 배지를 띄운다:

```javascript
      // NOVELTY_CALIB 이 없으면 라우터가 fail-open 으로 꺼진 채 DEMO_POLICY 가 고정 실행된다
      // (policy.jl:335-339). 그 사실이 화면에 안 보이면 "라우터 ON" 인 판으로 오독된다.
      var rt = selectedDecision && selectedDecision.router;
      var off = rt && rt.enabled === false;
      $("routerBadge").textContent = off ? "ROUTER OFF (advisory only)" : "ROUTER ON";
      $("routerBadge").className = off ? "badge badge-warn" : "badge";
```

   `narrative`·`routerBadge` DOM 노드는 결정 카드 마크업에 추가한다.

- [ ] **Step 3: 옛 녹화로 열어 회귀가 없는지 본다 (시뮬 없이)**

```bash
cd /home/chahj578/Construction_OODlayer
ls tools/monitor/streams/*.jsonl 2>/dev/null | head -3
```

스트림이 하나라도 있으면 서버를 띄워 그 판을 열고, **narrative 자리가 비어 있고 나머지가
예전처럼 뜨는지** 확인한다(없으면 이 스텝은 Task 9 의 데모 렌더 뒤로 미루고 그 사실을 적는다).

```bash
julia +lts --project=. tools/monitor/server.jl   # 포트는 스크립트 상단에서 확인
```

- [ ] **Step 4: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add tools/monitor/dashboard.html
git commit -m "feat(monitor): 결정 카드에 자연어 서술·근거 상태·라우터 배지 노출

셋 다 이미 스트림에 있는 값이다(narrative 는 Task 2·3 이 찍는다). 새로 계산하지 않는다.
서비스 다운(available=false)과 근거 없음(rationale='')을 다르게 표시한다 — 같게 쓰면
LLM 레인이 죽은 판을 '근거를 안 낸 판' 으로 오독한다. 옛 녹화에는 narrative 가 없으므로
그 자리는 비운다. spec §4."
```

---

## Task 5: 격자 축을 현행 세대에서 재유도 (`grid_spec.json`)

Spec §5.4 (개정 D4). **원 설계의 축 구간은 구세대 스윕에서 나왔다** — 배터리 물리 복구로 세계가 갈렸다(`noop` battery 완주 30/30 → 0/30).

**Files:**
- Create: `wm4spacecraft_manufacturing/dp_oracle/derive_grid.py`
- Create: `wm4spacecraft_manufacturing/dp_oracle/test_derive_grid.py`
- Create (산출): `wm4spacecraft_manufacturing/dp_oracle/grid_spec.json`

**Interfaces:**
- Consumes: `results_4pol/*.jsonl` (현행 세대 스윕)
- Produces:
  - `grid_spec.json` — `{"axes": {name: {"bins": [...], "source": "..."}}, "prune": [...], "generation": "...", "objective_hash": "..."}`
  - `cell_key(state: dict) -> str` — Task 6·7·8 이 **모두 이 함수를 쓴다**(격자 정의가 두 곳이 되면 조용히 갈린다)
  - `load_grid(path=None) -> dict`

- [ ] **Step 1: 스윕 행의 실제 스키마를 확인한다 (추측 금지)**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python -c "
import json, collections
rows=[json.loads(l) for l in open('results_4pol/all.jsonl') if l.strip()]
print('rows:', len(rows))
print('keys:', sorted(rows[0]))
for k in ('kind','policy','seed','soc','spare_count','agent_pending','progress','zone_overlap','complete','closed','total','n_stalled','objective_hash','energy_objective'):
    print('  %-16s %s' % (k, rows[0].get(k, '<<MISSING>>')))
"
```

**이 출력을 그대로 report 에 붙인다.** 아래 코드의 필드 이름은 이 출력에 맞춘다. 결정 시점
상태가 이 행에 없고 스트림(`shards/<case>/s<seed>/logs/*.jsonl`)에만 있다면, 그쪽을 읽도록
경로를 바꾸고 그 사실을 적는다.

- [ ] **Step 2: 세대 단일성을 먼저 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python -c "
import json, collections
rows=[json.loads(l) for l in open('results_4pol/all.jsonl') if l.strip()]
print(collections.Counter((r.get('objective_hash'), r.get('energy_objective')) for r in rows))
"
```

Expected: **쌍이 하나뿐이어야 한다.** 둘 이상이면 세대가 섞인 것이므로 **멈추고 보고한다** —
섞인 표본에서 축을 유도하면 혼입이 격자에 각인된다(CLAUDE.md 의 스케일 재교정 사고와 같은 형태).

- [ ] **Step 3: 실패하는 단위검사를 먼저 쓴다**

`wm4spacecraft_manufacturing/dp_oracle/test_derive_grid.py`:

```python
#!/usr/bin/env python3
"""격자 유도 규칙 단위검사. 합성 표본만 쓴다 — 스윕 파일에 의존하지 않는다."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from derive_grid import bins_from_support, cell_key, PRUNE_RULES, is_infeasible  # noqa: E402

FAILS = []


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + ("   " + detail if detail else ""))
    if not cond:
        FAILS.append(name)


def main():
    print("== derive_grid ==")

    # 규칙: 관측 지지집합 + 한 칸 밖 (spec 원문 §3 격자 B)
    b = bins_from_support([8, 9, 10, 11, 12], max_bins=4)
    check("지지집합을 덮는다", min(b) <= 8 and max(b) >= 12, str(b))
    check("칸 수가 상한 이하", len(b) <= 4, str(b))

    # 같은 입력 같은 출력 (DP 단계는 결정적이어야 한다 — 원문 §8.8)
    check("결정적", bins_from_support([8, 9, 10, 11, 12], max_bins=4) == b)

    # cell_key 는 축 순서를 고정한다. 순서가 흔들리면 표집과 솔버가 다른 칸을 가리킨다.
    s = dict(prog_b=1, soc_b=0, spares_b=2, pend_f=1, zone_s="none", evt="Battery")
    k1 = cell_key(s)
    k2 = cell_key(dict(reversed(list(s.items()))))
    check("키가 dict 순서에 안 흔들린다", k1 == k2, "%s vs %s" % (k1, k2))
    check("키가 문자열", isinstance(k1, str), k1)

    # 가지치기: 정의상 불가능한 칸은 표집하지 않는다 (원문 §3.2)
    check("가지치기 규칙이 비어 있지 않다", len(PRUNE_RULES) >= 4, str(len(PRUNE_RULES)))
    check("evt=Zone & zone_s=none 은 INFEASIBLE",
          is_infeasible(dict(s, evt="Zone", zone_s="none")))
    check("evt=Fault & pend_f=0 은 INFEASIBLE",
          is_infeasible(dict(s, evt="Fault", pend_f=0)))
    check("정상 칸은 INFEASIBLE 아님", not is_infeasible(s))

    print("\n%s" % ("전부 통과" if not FAILS else "실패 %d개: %s" % (len(FAILS), FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: 검사가 실패하는지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/dp_oracle
../../.venv/bin/python test_derive_grid.py; echo "exit=$?"
```

Expected: `ModuleNotFoundError: No module named 'derive_grid'`.

- [ ] **Step 5: `derive_grid.py` 를 쓴다**

아래는 **스키마와 무관한 순수부**다. 그대로 쓴다 — Task 7 의 `dp_solve._bucket()` 이
`cell_key` 의 문자열 형식(`prog_b=<int>|...`)에 의존하므로 **형식을 바꾸면 솔버가 조용히
전부 버킷 0 으로 본다.** 스윕 파일을 읽어 `bins` 를 채우는 부분만 Step 1 의 실제 스키마에 맞춘다.

```python
#!/usr/bin/env python3
"""격자 축을 **현행 세대 스윕에서** 유도해 grid_spec.json 을 쓴다.

왜 재유도하는가: 원 설계(dp-oracle-design.md §3)의 구간은 구세대 스윕에서 나왔다. 2026-08-13
저녁 배터리 물리 복구(용량 축소 제거 + stall/derate 켬)로 세계가 갈렸다 — noop 의 battery
완주가 30/30 -> 0/30 으로 뒤집혔고, 자연 방전이 무시할 수준이 되어 SoC 를 떨어뜨리는 것은
주입된 OOD 뿐이다. 옛 구간으로 격자를 깔면 예산의 다수가 도달하지 않는 칸에 들어간다.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))

# 축 순서는 **고정**이다. cell_key 가 이 순서로 문자열을 만들고, dp_solve._bucket() 이
# 첫 성분(prog_b)을 잘라 backward induction 의 버킷으로 쓴다. 순서를 바꾸면 조용히 갈린다.
AXES = ("prog_b", "soc_b", "spares_b", "pend_f", "zone_s", "evt")

# 정의상 불가능한 조합(원문 §3.2). **데이터로 적는다** — 코드에 흩어 놓으면 격자 정의가 두 곳이 된다.
# 각 규칙은 (축, 연산, 값) 목록이며 전부 만족하면 INFEASIBLE 이다.
PRUNE_RULES = [
    {"name": "battery_but_high_soc", "when": {"evt": "Battery"}, "and_": {"soc_b": "max"}},
    {"name": "zone_but_no_zone",     "when": {"evt": "Zone"},    "and_": {"zone_s": "none"}},
    {"name": "fault_but_no_pending", "when": {"evt": "Fault"},   "and_": {"pend_f": 0}},
    {"name": "early_but_no_spares",  "when": {"prog_b": 0},      "and_": {"spares_b": 0}},
]


def bins_from_support(values, max_bins=4):
    """관측 지지집합 + 한 칸 밖으로 경계를 만든다 (원문 §3, 격자 B).

    전구간을 깔지 않는 이유: 630판 실측에서 spare_count 는 8~12 만, soc 는 0~0.0999 만
    나왔다. 축을 전구간으로 깔면 예산의 다수가 현재 스트림이 절대 만들지 않는 칸에 들어간다.
    """
    vs = sorted(set(float(v) for v in values if v is not None))
    if not vs:
        return []
    if len(vs) <= max_bins:
        return vs
    # 분위로 자른다(결정적: 같은 입력 같은 출력).
    out = []
    for i in range(max_bins):
        idx = int(round(i * (len(vs) - 1) / (max_bins - 1)))
        if not out or vs[idx] != out[-1]:
            out.append(vs[idx])
    return out


def cell_key(state):
    """축 순서를 고정한 격자칸 키. dict 삽입 순서에 흔들리지 않는다.

    형식: "prog_b=1|soc_b=0|spares_b=2|pend_f=1|zone_s=none|evt=Battery"
    **dp_solve._bucket() 이 첫 성분을 자른다 — 형식을 바꾸면 솔버가 버킷을 못 읽는다.**
    """
    return "|".join("%s=%s" % (a, state.get(a)) for a in AXES)


def is_infeasible(state, axes_spec=None):
    """정의상 불가능한 칸인가 (원문 §3.2). 표집하지 않고 INFEASIBLE 로 기록한다."""
    for rule in PRUNE_RULES:
        cond = dict(rule["when"])
        cond.update(rule["and_"])
        hit = True
        for k, want in cond.items():
            got = state.get(k)
            if want == "max":
                # soc_b 의 최상단 칸 = "배터리 결정이 뜨는 조건 자체를 위반"
                top = (len(axes_spec[k]["bins"]) - 1) if axes_spec else 3
                hit = hit and (got == top)
            else:
                hit = hit and (got == want)
            if not hit:
                break
        if hit:
            return True
    return False


def load_grid(path=None):
    return json.load(open(path or os.path.join(HERE, "grid_spec.json")))
```

나머지(스윕을 읽어 축을 채우고 `grid_spec.json` 을 쓰는 `main()`)는 Step 1 의 스키마에 맞춰
쓰되, 아래 규약을 지킨다(원문 §3·§3.2 승계):

- 축은 `prog_b`(4구간, **단조 비감소** — backward induction 의 DAG 를 보장하는 유일한 축) ·
  `soc_b` · `spares_b` · `pend_f` · `zone_s` · `evt`
- 구간은 **관측 지지집합 + 한 칸 밖**. 전구간을 깔면 예산의 다수가 현재 스트림이 절대 만들지
  않는 칸에 들어간다.
- 가지치기 규칙은 **`grid_spec.json` 에 데이터로 적는다.** 코드에 흩어 놓으면 격자 정의가
  두 곳이 된다.
- `evt` 는 팔 메뉴 선택에만 쓰고 값함수의 입력 축으로는 물리 서술자만 쓴다(kind one-hot 금지 —
  새 kind 가 들어올 자리가 없어진다).
- 팔 메뉴는 `action_registry.json` 에서 가져온다. **630판 로그의 `valid` 를 읽으면 안 된다** —
  `FaultTruth`·`ReformTruth` 는 빈 리스트라 fault 축이 조용히 0팔이 된다(원문 §3.3).
- `grid_spec.json` 에 `generation` 과 `objective_hash` 를 `objective.load()`/
  `objective.objective_hash()` 에서 읽어 담는다(리터럴 금지).

- [ ] **Step 6: 검사 통과 + 격자 생성 + 예산 확인**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/dp_oracle
../../.venv/bin/python test_derive_grid.py; echo "test_exit=$?"
../../.venv/bin/python derive_grid.py --results ../results_4pol --out grid_spec.json
../../.venv/bin/python -c "
import json; g=json.load(open('grid_spec.json'))
cells=g['n_feasible_cells']; arms=g['arms_per_cell_max']; K=3
print('feasible cells:', cells, ' rollout 예산:', cells*arms*K)
assert cells*arms*K <= 220, 'rollout 상한 220 초과 — 칸을 줄인다(K 를 줄이지 않는다)'
print('OK')"
```

Expected: `OK`. **상한을 넘으면 칸을 줄인다. K 를 줄이지 않는다**(K 가 작으면 tie 가 늘어날
뿐이지만, 칸이 많고 K 가 1이면 tie 판정 자체가 불가능해진다).

- [ ] **Step 7: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/dp_oracle/derive_grid.py \
        wm4spacecraft_manufacturing/dp_oracle/test_derive_grid.py \
        wm4spacecraft_manufacturing/dp_oracle/grid_spec.json
git commit -m "feat(dp): 격자 축을 현행 세대 스윕에서 유도한다

원 설계(dp-oracle-design.md §3)의 구간(soc 0~0.0999, spares 8~12)은 구세대 스윕에서 나왔다.
배터리 물리 복구로 세계가 갈렸으므로(noop battery 완주 30/30 -> 0/30) 축을 다시 유도한다.
가지치기는 코드가 아니라 grid_spec.json 에 데이터로 적는다 — 격자 정의가 두 곳이 되면
조용히 갈린다. 팔 메뉴는 action_registry.json 에서 온다(로그의 valid 는 Fault/Reform 에서
빈 리스트라 축이 조용히 0팔이 된다). spec §5.4."
```

---

## Task 6: replay 표집기 (`sample_grid.jl`)

Spec §5.1 (개정 D1) + §5.3 (개정 D3). **`fork`/`deepcopy` 경로를 쓰지 않는다** — 구조적으로 불가능하다.

**Files:**
- Create: `wm4spacecraft_manufacturing/dp_oracle/sample_grid.jl`
- Create (산출): `wm4spacecraft_manufacturing/dp_oracle/samples.jsonl`

**Interfaces:**
- Consumes: `grid_spec.json`(Task 5), `oracle/gen_oracle_mc.jl` 의 `run_one` 계열 하니스
- Produces: `samples.jsonl` — 행마다
  `{"cell": str, "arm": int, "k": int, "cost": float, "next_cell": str|null, "terminal": "goal"|"dead_end"|null, "capped": bool, "sampling_mode": "replay", "seed": int, "objective_hash": str, "complete": bool, "closed": int, "total": int, "makespan": float, "energy_J": float}`
  Task 7 의 솔버가 이것만 읽는다.

- [ ] **Step 1: `run_one` 의 실제 시그니처를 확인한다 (추측 금지)**

```bash
cd /home/chahj578/Construction_OODlayer
grep -n "function run_one" -A 25 wm4spacecraft_manufacturing/oracle/gen_oracle_mc.jl
grep -n "run_one\|AT_CLOSED\|ORACLE_SEED\|schedule_ood_at_closed!" \
     wm4spacecraft_manufacturing/dp_oracle/probe_prefix_determinism.jl | head -20
```

프로브가 이미 `run_one` 을 부르고 있으므로 **그 호출 형태를 그대로 베낀다.** 프로브는 지문을
찍고 즉시 죽이는 fast-abort 트릭을 쓰는데, 표집기는 **끝까지 굴려야 하므로 그 트릭을 쓰지
않는다**(PROBE_RESULT.md 의 경고).

- [ ] **Step 2: energy-only 배터리 모드를 표집기 안에서 켠다**

fault/zone 사건에서도 J 를 계산하려면 에너지가 적산돼야 한다. **동역학을 바꾸지 않는 방식으로만** 켠다:

```julia
# battery.jl:486 의 energy-only 모드: enable_battery! 만 부르고 stall/derate 는 켜지 않는다.
# 소비만 적산하고 로봇을 멈추지도 늦추지도 않으므로 **동역학이 바뀌지 않는다.**
# 이게 없으면 evt=Fault/Zone 칸의 완주 런에 energy_J 가 없어 Objective.J 가 설계대로 던진다
# (2026-08-14 실측: fault 라벨 행 energy_J=None). run_demo.jl:500 이 이미 이 형태로 켠다.
CB.enable_battery!(env; params = CB.BatteryParams())
# set_battery_stall! / set_battery_derate! 는 **부르지 않는다** — 부르면 다른 세계가 된다.
```

배터리 사건 칸에서는 기존 주입기가 stall/derate 를 켠다. 표집기는 **칸의 `evt` 에 따라
어느 모드인지 행에 기록한다**(`"battery_mode": "energy_only"|"full"`).

- [ ] **Step 3: 착수비를 상각하는 배치 구조로 쓴다**

PROBE_RESULT.md 실측: 콜드 88.0/91.0s, **웜 8.1s/rollout**. 비용의 거의 전부가 프로세스당
1회 JIT/패키지 로드다. 따라서 **한 프로세스에서 여러 rollout 을 연속 실행**한다. 프로세스당
rollout 1개(구세대 `MC_ONLY` 방식)로 짜면 실효비용이 ~90s/rollout 으로 11배가 된다.

- [ ] **Step 4: 요청 칸이 아니라 착지 칸으로 라벨한다**

주입 후 실제 상태에서 φ̃ 를 다시 계산해 기록한다(원문 §4.2·§5). 요청 칸과 다르면 그 표본을
**버리지 않고 착지한 칸의 표본으로 센다.** 어떤 요청으로도 표본이 안 생기는 칸은
`UNREACHABLE` 로 기록하고 **값을 지어내지 않는다.**

- [ ] **Step 5: 파일럿 — 스키마를 먼저 검증한다 (전체 표집 전에)**

**반드시 한다.** 몇 칸만 돌려 행 스키마를 본다.

```bash
cd /home/chahj578/Construction_OODlayer
DP_LIMIT=2 DP_K=1 DP_OUT=/tmp/dp_pilot.jsonl \
  timeout 3600 julia +lts --project=. wm4spacecraft_manufacturing/dp_oracle/sample_grid.jl 2>&1 | tail -20

.venv/bin/python -c "
import json, sys
rows=[json.loads(l) for l in open('/tmp/dp_pilot.jsonl') if l.strip()]
print('rows:', len(rows))
need=['cell','arm','k','cost','sampling_mode','objective_hash','complete','closed','total','makespan','energy_J','capped']
miss=[k for k in need if rows and k not in rows[0]]
print('missing:', miss or 'none')
bad=[r for r in rows if r.get('complete') and not isinstance(r.get('energy_J'),(int,float))]
print('완주인데 energy_J 없음:', len(bad))
print('sampling_mode:', {r.get('sampling_mode') for r in rows})
sys.exit(1 if (miss or bad) else 0)"; echo "schema_exit=$?"
```

Expected: `missing: none`, `완주인데 energy_J 없음: 0`, `sampling_mode: {'replay'}`, `schema_exit=0`.
**실패하면 여기서 멈춘다** — 스키마가 틀린 채 전체를 돌리면 전부 버려야 한다.

- [ ] **Step 6: 전체 표집 (예산 상한 220 rollout)**

```bash
cd /home/chahj578/Construction_OODlayer
DP_K=3 DP_OUT=wm4spacecraft_manufacturing/dp_oracle/samples.jsonl \
  nohup julia +lts --project=. wm4spacecraft_manufacturing/dp_oracle/sample_grid.jl \
  > /tmp/dp_sample.log 2>&1 &
```

**순차 실행**(Global Constraint 9). 다른 julia 시뮬을 동시에 띄우지 않는다. 완료 후 커버리지를 센다:

```bash
cd /home/chahj578/Construction_OODlayer
.venv/bin/python -c "
import json, collections
rows=[json.loads(l) for l in open('wm4spacecraft_manufacturing/dp_oracle/samples.jsonl') if l.strip()]
by=collections.Counter(r['cell'] for r in rows)
print('rows:', len(rows), 'cells with samples:', len(by))
print('capped rows:', sum(1 for r in rows if r.get('capped')))
g=json.load(open('wm4spacecraft_manufacturing/dp_oracle/grid_spec.json'))
print('feasible cells:', g['n_feasible_cells'], '-> coverage:', round(100*len(by)/g['n_feasible_cells'],1), '%')"
```

**커버리지가 낮아도 실패가 아니다**(원문 §4.2). 다만 숫자를 report 에 적고, Task 9 의
`FINAL.md` 가 그 비율을 같이 싣는다. `capped` 행이 있으면 경고와 함께 보고한다(원문 §8.5 —
미래가 잘리면 라벨이 낙관 편향되는데 "사건 N건" 만 보고하면 잘렸는지 알 수 없다).

- [ ] **Step 7: 커밋** (`samples.jsonl` 이 크면 `.gitignore` 확인 후 커밋 여부를 결정하고, 뺐으면 그 사실을 report 에 적는다)

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/dp_oracle/sample_grid.jl
git commit -m "feat(dp): replay 표집기 — 착수비 상각 배치 + energy-only 배터리

원 설계 §4.2 의 fork-per-arm(deepcopy)은 구조적으로 불가능하다(RVO2 C++ 싱글턴 ·
BATTERY_FLEET · HAZARD_STATE · OOD_SCHEDULE · SIM_STEP 이 프로세스 전역이라 두 가지가
같은 물리를 밟는다). PROBE_RESULT.md 가 주입 순간 지문 10/10 동일을 측정해 replay 를
확정했으므로 팔마다 build seed 를 고정해 다시 굴린다. 비용의 거의 전부가 프로세스당 1회
JIT(콜드 90s vs 웜 8.1s)이라 한 프로세스에서 연속 실행한다. fault/zone 칸은 energy-only
모드로 에너지만 적산한다 — stall/derate 를 켜면 다른 세계가 된다. spec §5.1·§5.3."
```

---

## Task 7: DP 솔버 (`dp_solve.py`)

Spec §5.2 (개정 D2) + 원문 §7. **순수 파이썬. 시뮬 호출 0회. 같은 입력에 같은 출력**(원문 §8.8).

**Files:**
- Create: `wm4spacecraft_manufacturing/dp_oracle/dp_solve.py`
- Create: `wm4spacecraft_manufacturing/dp_oracle/test_dp_solve.py`
- Create (산출): `wm4spacecraft_manufacturing/dp_oracle/value.json`

**Interfaces:**
- Consumes: `samples.jsonl`(Task 6), `grid_spec.json`(Task 5), `objective.load()`
- Produces:
  - `solve(samples, grid, cfg) -> dict` — `{cell: {"V": float, "Q": {arm: float}, "a_star": int|None, "tie": [int], "se": {arm: float}, "n": {arm: int}, "converged": bool}}`
  - Task 8 의 `dp_oracle_policy.py` 가 이 dict 를 읽는다.

- [ ] **Step 1: 실패하는 단위검사를 먼저 쓴다 — 손계산이 가능한 격자로**

`wm4spacecraft_manufacturing/dp_oracle/test_dp_solve.py`:

```python
#!/usr/bin/env python3
"""dp_solve 단위검사. 손계산 가능한 합성 격자만 쓴다 — 시뮬도 실제 표본도 안 쓴다."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from dp_solve import solve   # noqa: E402

FAILS = []


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + ("   " + detail if detail else ""))
    if not cond:
        FAILS.append(name)


CFG = {"C_fail": 100.0}


def row(cell, arm, k, cost, terminal="goal", nxt=None):
    return {"cell": cell, "arm": arm, "k": k, "cost": cost,
            "terminal": terminal, "next_cell": nxt, "capped": False}


def main():
    print("== dp_solve ==")

    # (1) 한 칸, 두 팔, 전부 goal 로 종료. V(goal)=0 이므로 Q = 평균 비용.
    #     팔 8 = 평균 2.0, 팔 1 = 평균 5.0  ->  a* = 8, V = 2.0
    s1 = ([row("c0", 8, k, c) for k, c in enumerate([1.0, 2.0, 3.0])] +
          [row("c0", 1, k, c) for k, c in enumerate([4.0, 5.0, 6.0])])
    v = solve(s1, grid=None, cfg=CFG)
    check("V = 최소 Q", abs(v["c0"]["V"] - 2.0) < 1e-9, str(v["c0"]["V"]))
    check("a* = 8", v["c0"]["a_star"] == 8, str(v["c0"]["a_star"]))
    check("Q 를 팔마다 낸다", set(v["c0"]["Q"]) == {8, 1} or set(v["c0"]["Q"]) == {"8", "1"},
          str(v["c0"]["Q"]))
    check("표본수를 기록한다", v["c0"]["n"][8] == 3 or v["c0"]["n"]["8"] == 3, str(v["c0"]["n"]))

    # (2) dead-end 는 C_fail 을 문다 (유한벌점 SSP).
    s2 = ([row("c1", 8, k, 1.0) for k in range(3)] +
          [row("c1", 1, k, 1.0, terminal="dead_end") for k in range(3)])
    v = solve(s2, grid=None, cfg=CFG)
    check("dead-end 팔이 C_fail 을 문다", abs(v["c1"]["Q"][1] - 101.0) < 1e-9
          if 1 in v["c1"]["Q"] else abs(v["c1"]["Q"]["1"] - 101.0) < 1e-9, str(v["c1"]["Q"]))
    check("a* 는 완주하는 팔", v["c1"]["a_star"] == 8, str(v["c1"]["a_star"]))

    # (3) 동점은 단일 a* 를 뽑지 않고 tie 집합으로 낸다 (원문 §7).
    s3 = ([row("c2", 8, k, 2.0) for k in range(3)] +
          [row("c2", 1, k, 2.0) for k in range(3)])
    v = solve(s3, grid=None, cfg=CFG)
    check("완전 동점이면 tie 집합이 둘 다 담는다", set(map(int, v["c2"]["tie"])) == {1, 8},
          str(v["c2"]["tie"]))

    # (4) 결정성 — 같은 입력 같은 출력 (원문 §8.8)
    check("결정적", solve(s1, grid=None, cfg=CFG) == solve(s1, grid=None, cfg=CFG))

    # (5) 표본 0 인 칸은 값을 지어내지 않는다.
    v = solve([], grid=None, cfg=CFG)
    check("표본이 없으면 빈 표", v == {}, str(v))

    print("\n%s" % ("전부 통과" if not FAILS else "실패 %d개: %s" % (len(FAILS), FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: 검사가 실패하는지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/dp_oracle
../../.venv/bin/python test_dp_solve.py; echo "exit=$?"
```

Expected: `ModuleNotFoundError: No module named 'dp_solve'`.

- [ ] **Step 3: 솔버를 쓴다**

`wm4spacecraft_manufacturing/dp_oracle/dp_solve.py`:

```python
#!/usr/bin/env python3
"""samples.jsonl -> value.json. **순수 파이썬, 시뮬 호출 0회, 결정적**(원문 §8.8).

Bellman (원문 §7):
    V(goal)     = 0
    V(dead-end) = C_fail                      <- objective.load() 에서 읽는다. 리터럴 금지.
    Q(s,a)      = (1/K) sum_k [ c_k + V(s'_k) ]
    V(s)        = min_a Q(s,a)
    a*(s)       = argmin_a Q(s,a)

버킷 사이는 prog_b 역순 backward induction(progress 단조성이 DAG 를 보장), 버킷 내부는
같은 prog_b 안에서 결정이 여러 번 나 자기순환이 생기므로 value iteration 으로 수렴시킨다
(유한벌점 SSP 라 proper policy 아래 수축). 수렴 실패 노드는 조용히 넘기지 않고 표시한다.

동점(원문 §7): |dQ| < 1.96 * SE_paired 이면 **단일 a* 를 뽑지 않고 tie 집합으로 보고**한다.
없는 확신을 만들지 않는 것이 채점에서 중요하다.
"""
import argparse
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))

TOL = 1e-9
MAX_ITER = 500
Z = 1.96


def _bucket(cell):
    """prog_b 는 cell key 의 첫 성분이다 (derive_grid.cell_key 규약)."""
    try:
        return int(str(cell).split("|", 1)[0].split("=", 1)[-1])
    except Exception:
        return 0


def _mean(xs):
    return sum(xs) / len(xs) if xs else 0.0


def _se(xs):
    n = len(xs)
    if n < 2:
        return float("inf")
    m = _mean(xs)
    var = sum((x - m) ** 2 for x in xs) / (n - 1)
    return math.sqrt(var / n)


def solve(samples, grid=None, cfg=None):
    """samples: dict 목록. 반환: {cell: {V, Q, a_star, tie, se, n, converged}}"""
    if cfg is None:
        import objective
        cfg = objective.load()
    c_fail = float(cfg["C_fail"])

    # (cell, arm) -> [(k, cost, terminal, next_cell)]
    by = {}
    for r in samples:
        by.setdefault((r["cell"], int(r["arm"])), []).append(r)
    cells = sorted({c for c, _ in by})
    if not cells:
        return {}

    V = {c: 0.0 for c in cells}

    def q_values(cell):
        """이 칸의 팔별 (Q, per-k 값 목록)."""
        out = {}
        for (c, a), rows in by.items():
            if c != cell:
                continue
            vals = []
            for r in rows:
                term = r.get("terminal")
                if term == "goal":
                    tail = 0.0
                elif term == "dead_end":
                    tail = c_fail
                else:
                    nxt = r.get("next_cell")
                    tail = V.get(nxt, c_fail if nxt is None else 0.0)
                vals.append(float(r["cost"]) + tail)
            out[a] = (_mean(vals), vals)
        return out

    converged = {}
    for b in sorted({_bucket(c) for c in cells}, reverse=True):
        bucket_cells = [c for c in cells if _bucket(c) == b]
        ok = False
        for _ in range(MAX_ITER):
            delta = 0.0
            for c in bucket_cells:
                qs = q_values(c)
                if not qs:
                    continue
                nv = min(q for q, _ in qs.values())
                delta = max(delta, abs(nv - V[c]))
                V[c] = nv
            if delta < TOL:
                ok = True
                break
        for c in bucket_cells:
            converged[c] = ok

    out = {}
    for c in cells:
        qs = q_values(c)
        if not qs:
            continue
        best_arm = min(qs, key=lambda a: qs[a][0])
        best_q, best_vals = qs[best_arm]
        tie = []
        for a, (q, vals) in qs.items():
            if a == best_arm:
                tie.append(a)
                continue
            # 같은 k 로 짝지어 비교한다(replay 라 k 가 대응된다). 짝이 안 맞으면 합산 SE.
            n = min(len(vals), len(best_vals))
            if n >= 2:
                diffs = [vals[i] - best_vals[i] for i in range(n)]
                se = _se(diffs)
            else:
                se = math.inf
            if not math.isfinite(se) or abs(q - best_q) < Z * se:
                tie.append(a)
        tie = sorted(tie)
        out[c] = {
            "V": best_q,
            "Q": {a: qs[a][0] for a in sorted(qs)},
            # tie 가 둘 이상이면 단일 a* 를 뽑지 않는다 — 없는 확신을 만들지 않는다.
            "a_star": (best_arm if len(tie) == 1 else None),
            "tie": tie,
            "se": {a: _se(qs[a][1]) for a in sorted(qs)},
            "n": {a: len(qs[a][1]) for a in sorted(qs)},
            "converged": bool(converged.get(c, False)),
        }
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", default=os.path.join(HERE, "samples.jsonl"))
    ap.add_argument("--grid", default=os.path.join(HERE, "grid_spec.json"))
    ap.add_argument("--out", default=os.path.join(HERE, "value.json"))
    a = ap.parse_args()

    import objective
    rows = [json.loads(l) for l in open(a.samples) if l.strip()]

    # 세대 단일성: 표본이 두 세대에서 왔으면 멈춘다. 섞인 값을 표에 각인시키지 않는다.
    hashes = {r.get("objective_hash") for r in rows}
    if len(hashes) > 1:
        sys.exit("표본에 objective_hash 가 %d 종 섞여 있다: %s" % (len(hashes), hashes))
    cur = objective.objective_hash()
    if hashes and cur not in hashes:
        sys.exit("표본의 objective_hash 가 현행과 다르다(구세대 표본): %s" % hashes)

    val = solve(rows, grid=json.load(open(a.grid)), cfg=objective.load())
    n_tie = sum(1 for v in val.values() if v["a_star"] is None)
    n_bad = sum(1 for v in val.values() if not v["converged"])
    with open(a.out, "w") as f:
        json.dump({"cells": val, "generation": objective.load()["generation"],
                   "objective_hash": cur, "n_cells": len(val),
                   "n_tie_unresolved": n_tie, "n_not_converged": n_bad}, f, indent=1)
    print("cells=%d  tie(a* 미확정)=%d  수렴실패=%d  -> %s" % (len(val), n_tie, n_bad, a.out))


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: 검사 통과 + 실제 표본으로 푼다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/dp_oracle
../../.venv/bin/python test_dp_solve.py; echo "test_exit=$?"
../../.venv/bin/python dp_solve.py
```

Expected: `test_exit=0`. 두 번째 명령이 `value.json` 을 만들고 `tie(a* 미확정)`·`수렴실패`
개수를 찍는다. **둘 다 report 에 적는다.**

- [ ] **Step 5: 단조성 위생검사 (원문 §8.4)**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/dp_oracle
../../.venv/bin/python -c "
import json
v=json.load(open('value.json'))['cells']
# spares 가 클수록 V 는 비증가 / pend_f 가 클수록 비감소 / soc 가 높을수록 비증가.
# 위반은 자동 실패가 아니라 **조사 대상**이다(표본 노이즈일 수 있으므로 SE 와 함께 본다).
print('cells:', len(v))
print('※ 위반 목록을 report 에 적고, SE 와 함께 판단한다')
"
```

- [ ] **Step 6: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/dp_oracle/dp_solve.py \
        wm4spacecraft_manufacturing/dp_oracle/test_dp_solve.py \
        wm4spacecraft_manufacturing/dp_oracle/value.json
git commit -m "feat(dp): backward induction 솔버 — 순수 파이썬, 결정적

버킷 사이는 prog_b 역순(단조성이 DAG 를 보장), 버킷 내부는 value iteration(자기순환).
C_fail 은 objective.load() 에서 읽는다(리터럴 금지 — audit_objective.py 항목 1).
동점은 |dQ| < 1.96*SE_paired 로 판정해 **단일 a* 를 뽑지 않고 tie 집합으로** 낸다.
표본의 objective_hash 가 섞였거나 구세대면 멈춘다. spec §5.2, 원문 §7·§8.8."
```

---

## Task 8: `dp` 레인 — 스윕 전용 (라우터·UI 제외)

Spec §5.7 + Global Constraint 10.

**Files:**
- Create: `wm4spacecraft_manufacturing/dp_oracle_policy.py`
- Modify: `tools/monitor/policy.jl` (`DEMO_POLICY=dp` 분기)
- Modify: `wm4spacecraft_manufacturing/run_4pol.sh:30,57,196`, `run_shard.sh:41`

**Interfaces:**
- Consumes: `dp_oracle/value.json`(Task 7), `derive_grid.cell_key`(Task 5)
- Produces: `dp_action(ev) -> str|None` — 미수록·`INFEASIBLE`·`UNREACHABLE`·tie 미확정은 `None`

- [ ] **Step 1: `reference_policy.py` 의 시그니처를 읽는다 (대체하지 않고 **닮게** 만든다)**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
grep -n "def reference_action" -A 20 reference_policy.py
```

**`reference_policy.py` 를 수정하지 않는다.** 발행된 표가 전부 그것으로 채점돼 있어서, 건드리면
숫자가 조용히 재채점된다(원문 §8.6 이 막으려던 것). DP 는 새 파일로만 들어간다.

- [ ] **Step 2: `dp_oracle_policy.py` 를 쓴다**

```python
#!/usr/bin/env python3
"""value.json 조회 정책. **reference_policy.py 를 대체하지 않는다** — 발행된 표가 전부
그것으로 채점돼 있어 건드리면 숫자가 조용히 재채점된다(원 설계 §8.6 이 막으려던 것).

이 모듈은 스윕의 `dp` 레인만 쓴다. 라우터에도 대시보드에도 들어가지 않는다
(Global Constraint 10): DP 의 a* 는 오프라인 표집 + backward induction 의 산물이라,
결정 시점에 표가 있다는 것 자체가 "그 사건을 미리 다 굴려봤다" 는 뜻이다.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "dp_oracle"))
from derive_grid import cell_key, is_infeasible, load_grid   # noqa: E402

_TABLE = None


def _table(path=None):
    global _TABLE
    if _TABLE is None:
        p = path or os.path.join(HERE, "dp_oracle", "value.json")
        _TABLE = json.load(open(p))
    return _TABLE


def phi_tilde(ev, grid):
    """사건 레코드 -> 격자칸 상태. 축 이름은 derive_grid.AXES 와 같아야 한다.

    구현은 grid_spec.json 의 bins 로 값을 버킷팅하는 것뿐이다 — 새 규칙을 만들지 않는다.
    """
    raise NotImplementedError("Task 5 의 grid_spec.json bins 로 버킷팅한다")


def dp_action(ev, table=None, grid=None):
    """-> (macro_name|None, reason). None 의 이유를 네 가지로 **구분해서** 돌려준다.

    조용한 폴백 금지(Global Constraint 12): 호출자는 이 reason 을 행에 남겨야 한다.
    """
    grid = grid or load_grid()
    st = phi_tilde(ev, grid)
    if is_infeasible(st, grid.get("axes")):
        return None, "infeasible"
    key = cell_key(st)
    cells = (table or _table()).get("cells", {})
    cell = cells.get(key)
    if cell is None:
        return None, "not_in_table"
    if not cell.get("n"):
        return None, "unreachable"
    if cell.get("a_star") is None:
        # tie 를 tie 로 보고하는 것이 채점에서 중요하다(원문 §7). 없는 확신을 만들지 않는다.
        return None, "tie_unresolved"
    return cell["a_star"], "dp_cell=%s" % key
```

`phi_tilde` 만 Step 1 에서 확인한 실제 사건 레코드 필드에 맞춰 채운다. **새 버킷팅 규칙을
만들지 않는다** — `grid_spec.json` 의 `bins` 가 단일 진실원이다.

- [ ] **Step 3: `policy.jl` 에 `dp` 레인을 넣는다 — 라우터에는 넣지 않는다**

```julia
# DEMO_POLICY=dp 는 **스윕 전용 실행 레인**이다. route() 의 타깃 집합에는 들어가지 않는다
# (Global Constraint 10): DP 의 a* 는 오프라인 표집 + backward induction 의 산물이라
# 결정 시점에 표가 있다는 것 자체가 "그 사건을 미리 다 굴려봤다" 는 뜻이다.
# 대시보드도 이 레인을 그리지 않는다 — pol["dp"] 를 만들지 않는다.
```

a\* 가 `None` 이면 **canonical 로 폴백하고 그 사실과 이유를 행에 남긴다.**

- [ ] **Step 4: 스윕 스크립트의 정책 수 하드코딩을 없앤다**

`run_4pol.sh:57` 과 `:196` 의 `3` 이 정책 개수다. 정책을 5개로 늘리면 **행 수 기대값과 비용
추정이 조용히 틀린다.**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
grep -n "N_SEEDS \* 3\|\* 3 ))" run_4pol.sh
```

`N_POLICIES` 를 `POLICIES` 에서 세어(이미 `run_shard.sh:57` 이 같은 일을 한다) 그 자리에 넣는다.

- [ ] **Step 5: 시뮬 없이 인프로세스로 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python -c "
import sys; sys.path.insert(0,'.')
from dp_oracle_policy import dp_action
print(dp_action({'kind':'battery','soc':0.02,'spare_count':3,'agent_pending':5,'progress':0.4}))
print('미수록 칸:', dp_action({'kind':'zone','zone_overlap':0.9,'progress':0.99}))"
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. -e 'Meta.parseall(read("tools/monitor/policy.jl", String)); println("parses OK")'
bash -n wm4spacecraft_manufacturing/run_4pol.sh && echo "run_4pol.sh syntax OK"
```

- [ ] **Step 6: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/dp_oracle_policy.py tools/monitor/policy.jl \
        wm4spacecraft_manufacturing/run_4pol.sh wm4spacecraft_manufacturing/run_shard.sh
git commit -m "feat(dp): dp 실행 레인 — 스윕 전용, 라우터·UI 에서 제외

reference_policy.py 를 건드리지 않는다: 발행된 표가 전부 그것으로 채점돼 있어 수정하면
숫자가 조용히 재채점된다(원 설계 §8.6 이 막으려던 것). DP 는 새 파일로만 들어가고
route() 의 타깃 집합에도 대시보드에도 없다. a* 가 없으면 canonical 로 폴백하되 이유를
네 가지(not_in_table/infeasible/unreachable/tie_unresolved)로 구분해 남긴다.
정책 수 하드코딩(run_4pol.sh:57,196 의 3)을 없앴다 — 5정책에서 행 수 기대값이 틀린다."
```

---

## Task 9: 재스윕 · FINAL.md · 데모 렌더 · 게이트 전수

**선행: surrogate 재구축이 끝나 있어야 한다.** 구 모델로 스윕하면 surrogate 열이 kind 를 구분 못 하는 그 모델의 숫자가 된다.

**Files:**
- 산출: `wm4spacecraft_manufacturing/artifacts_4pol/FINAL.md`, `tools/monitor/streams/*`, `tools/monitor/anim/*`

- [ ] **Step 1: 선행조건을 기계로 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python test_surrogate_support.py;  echo "support=$?"
../.venv/bin/python audit_objective.py > /dev/null;   echo "audit_objective=$?"
../.venv/bin/python audit_action_vocab.py > /dev/null; echo "audit_vocab=$?"
ls -la dp_oracle/value.json
```

Expected: 앞의 셋 전부 `0`, `value.json` 존재. **하나라도 아니면 스윕을 시작하지 않는다** —
1.7시간을 버리게 된다.

- [ ] **Step 2: 재스윕 (7 case × 30 seed × 5 policy = 1050 판, 순차)**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
nohup bash run_4pol.sh --policies noop,canonical,surrogate,dspy,dp \
      --seeds 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30 \
      > /tmp/resweep.log 2>&1 &
```

**약 1.7시간 예상**(630판/62분에서 선형 외삽 — 측정값이 아니다). 실제 벽시계를 report 에 적는다.
크게 벗어나면 **seed 를 줄이지 말고 case 를 줄인다** — seed 를 줄이면 기존 발행 표와의 비교
가능성이 깨진다.

- [ ] **Step 3: 세대 단일성 확인**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python -c "
import json, collections, glob
rows=[json.loads(l) for p in glob.glob('results_4pol/*.jsonl') for l in open(p) if l.strip()]
print('rows:', len(rows))
print(collections.Counter((r.get('objective_hash'), r.get('energy_objective')) for r in rows))
print('policies:', collections.Counter(r.get('policy') for r in rows))"
```

Expected: `(hash, energy_objective)` 쌍이 **하나**, 정책 5종.

- [ ] **Step 4: FINAL.md 생성**

```bash
cd /home/chahj578/Construction_OODlayer
.venv/bin/python wm4spacecraft_manufacturing/build_final_table.py \
  --results-dir wm4spacecraft_manufacturing/results_4pol \
  --out-dir wm4spacecraft_manufacturing/artifacts_4pol; echo "exit=$?"
```

**표에 반드시 들어가야 하는 것:**
- `dp` 행이 **천장(ceiling)으로 표시**되고 "실행 가능한 온라인 정책이 아니다" 가 명시된다.
- DP 격자 **커버리지 비율**과 `tie 미확정` 칸 수(Task 6·7 의 숫자).
- **§8.7 gap**: 실행 정책의 실현 결과가 DP 의 V 를 넘는 경우 수. **넘으면 "천장" 이라는 이름을
  쓰지 않는다** — φ̃ 의 정보손실이 ceiling 을 참값 아래로 끌어내린 것이므로 이름을 유지하면
  그 자체가 거짓 주장이 된다.
- 천장이 `미측정` 인 축과 그 이유(Task 1).

- [ ] **Step 5: 데모 판 렌더 (라우터 ON)**

```bash
cd /home/chahj578/Construction_OODlayer
ls -la "$NOVELTY_CALIB" 2>/dev/null || echo "!! NOVELTY_CALIB 미설정 — 라우터가 fail-open 으로 꺼진다"
bash tools/monitor/regen_router_cases.sh --dry-run     # 먼저 명령/경로만 본다
bash tools/monitor/regen_router_cases.sh               # 순차, 판당 수 분
```

렌더 후 `regen_router_logs/*.log` 에서 `[router] ... → <target>` 줄을 확인한다 — 그 줄은
**라우터가 실제로 그 사건을 몰았을 때만** 찍힌다.

- [ ] **Step 6: 화면 확인**

```bash
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. tools/monitor/server.jl
```

대시보드에서: 결정마다 **narrative 문장** · **라우터 reason(3-way 문구)** · **레인별 rationale
(available=false 와 빈 문자열이 다르게 보이는지)** · **ROUTER ON/OFF 배지** · `dp` 가 화면
어디에도 없는지.

- [ ] **Step 7: 게이트 전수**

```bash
cd /home/chahj578/Construction_OODlayer
.venv/bin/python wm4spacecraft_manufacturing/audit_objective.py    > /dev/null; echo "audit_objective=$?"
.venv/bin/python wm4spacecraft_manufacturing/audit_action_vocab.py > /dev/null; echo "audit_vocab=$?"
.venv/bin/python wm4spacecraft_manufacturing/test_surrogate_support.py > /dev/null; echo "support=$?"
.venv/bin/python wm4spacecraft_manufacturing/test_ceilings_degrade.py  > /dev/null; echo "ceilings=$?"
.venv/bin/python wm4spacecraft_manufacturing/dp_oracle/test_derive_grid.py > /dev/null; echo "grid=$?"
.venv/bin/python wm4spacecraft_manufacturing/dp_oracle/test_dp_solve.py   > /dev/null; echo "dp_solve=$?"
julia +lts --project=. tools/monitor/test_narrate.jl     > /dev/null; echo "narrate=$?"
julia +lts --project=. tools/monitor/test_lane_select.jl > /dev/null; echo "lane_select=$?"
julia +lts --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3
```

Expected: 파이썬·Julia 단위검사 전부 `0`. `Pkg.test()` 는 **11 pass / 1 error**(Gurobi 라이선스
없음) — 그보다 나빠지면 회귀다.

- [ ] **Step 8: 결과 문서 + 커밋**

`wm4spacecraft_manufacturing/md/RESULTS_ROUTER3WAY_2026-08-15.md` 를 쓴다. **반드시 포함:**
스윕 벽시계와 샤드 ok/fail · 세대 쌍 · 정책 5종의 case 별 결과 · DP 커버리지와 tie 수 ·
§8.7 gap 결과와 "천장" 이름을 쓸 수 있는지 · 미측정 축과 이유 · 재현 절차.
**문서에 `objective_hash` 문자열을 적지 않는다**(Global Constraint 4).

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/artifacts_4pol wm4spacecraft_manufacturing/md/RESULTS_ROUTER3WAY_2026-08-15.md
git commit -m "data(sweep): 5정책 재스윕 + FINAL.md + 라우터 3-way 데모 판

7 case x 30 seed x 5 policy. dp 행은 천장으로만 표시하고 실행 정책과 같은 줄에 세우지
않는다. DP 격자 커버리지·tie 미확정 칸 수·gap(§8.7) 을 표에 같이 싣는다 — 실행 정책이
V 를 넘으면 '천장' 이라는 이름을 쓰지 않는다."
```

---

## 실행 순서 요약

| 날 | 태스크 | 시뮬 | 비고 |
|---|---|---|---|
| 8/14 낮 | 1 · 2 · 3 · 4 | **0회** | surrogate 재구축과 병행 가능 |
| 8/14 밤 | 5 · 6 · 7 | 표집만 (상한 220 rollout) | 순차. 다른 julia 시뮬과 겹치지 않게 |
| 8/15 | 8 · 9 | 재스윕 ~1.7h + 데모 판 | Task 9 Step 1 의 선행조건 확인을 먼저 |

되돌리기 비싼 의존성 둘: **Task 5 → 6**(격자 없이 표집하면 라벨할 칸이 없다), **surrogate 완료 → 9**(구 모델 스윕은 버려야 한다).
