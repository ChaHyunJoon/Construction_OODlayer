# DP 를 baseline 으로 만든다 — 1-step deviation 표집 Implementation Plan

> **인수인계 문서다.** 2026-08-15 세션이 다음 세션에 넘긴다.
> 실행 전 `wm4spacecraft_manufacturing/md/RESULTS_ACTION_SET_CLOSURE_2026-08-16.md` **§4-B·§4-D**
> 와 `md/COMPARE_ACTIONSET_DELTA_2026-08-16.md` **§3-D** 를 먼저 읽을 것 — 이 계획이 무엇을
> 고치려는지가 거기 실측으로 적혀 있다.
>
> **Spec:** 이 계획은 별도 spec 이 없다. 근거 문서가 spec 을 대신한다 —
> `md/RESULTS_ACTION_SET_CLOSURE_2026-08-16.md`(무엇이 남았나) +
> `dp_oracle/PROBE_RESULT.md`(왜 replay 로 할 수 있나) +
> `dp_oracle/sample_grid.py` 머리말(비용 분해의 계약).

**Goal:** DP 의 `V` 를 **실제로 천장으로 쓸 수 있는 값**으로 만든다. 지금 `V` 는 실행 정책보다
나쁘고(§8.7 gap 89.3%), 그 원인은 알고리즘이 아니라 **표본을 만든 궤적**이다 — 판 전체를 한 팔로
굴리기 때문에 표집 판의 83.1% 가 미완주로 끝나고, `V` 가 실패 벌점(~15,000)에 눌린다.
팔을 **한 결정에서만** 바꾸고 나머지는 기준 정책으로 굴리면 그 오염이 사라진다.

**Architecture:** 표집 rollout 의 의미를 `DEMO_FORCE_MACRO=<팔>`(판 전체 고정)에서
`DS_DEVIATE_AT=<k> + DS_DEVIATE_ARM=<팔>`(k 번째 결정만 그 팔, 나머지는 canonical)로 바꾼다.
prefix 재현은 **replay** 로 한다 — 같은 build seed 로 처음부터 다시 굴리면 주입 시점 상태가
재현된다는 것이 `PROBE_RESULT.md` 에서 10/10 로 측정돼 있고, in-process fork 는 RVO/battery/
hazard 가 프로세스 전역 싱글턴이라 **구조적으로 막혀 있다**.

**Tech Stack:** Julia 1.10(`julia +lts --project=.`) · `.venv/bin/python` ·
`tools/monitor/policy.jl`(결정 지점) · `dp_oracle/sample_grid.py`(표집) ·
`dp_oracle/dp_solve.py`(backward induction, **변경 없음**).

---

## 0. 오늘 오후에 어디까지 되는가 — 실측 기반 예산

| 단계 | 비용 | 근거 |
|---|---|---|
| Task 1·2 구현 + 단위 테스트 | **1.5 ~ 2 h** | policy.jl 훅 + sample_grid 모드 전환 + 게이트 2개 |
| Task 3 표집 588판 | **~1.8 h** | 실측: 575판 / 26 워커 / 106분 (판당 ~287 s) |
| Task 3 `dp_solve.py` | **< 5 min** | 현행 실측(수렴 최대 반복 234) |
| Task 4 **dp 레인만** 재스윕 210판 | **~40 min** | 50 워커. ★ 아래 참조 |
| Task 5 판정 + 문서 | **~30 min** | `gap_breakdown.py` + 결과 문서 |
| **합계** | **~4.5 ~ 5 h** | |

**★ 이번에는 4 정책 전면 재스윕이 필요 없다.** `canonical`·`surrogate`·`dspy` 세 레인은
`value.json` 을 **읽지 않는다** — 2026-08-15 판이 그 통제를 이미 냈다("실행 레인 세 열은
case 별 수치까지 완전히 동일"). 이번 변경은 표집과 `value.json` 만 건드리므로 **dp 열만**
다시 굴리면 되고, 그게 90분을 아낀다. 나머지 세 열은 현행 세대 값을 그대로 옮겨 적는다.

**판정:** 오후 12:00 에 시작하면 **표집 착수까지(Task 1·2)가 오후 안에 확실히 끝나고**,
표집·풀이·재스윕까지 밀어붙이면 17:00~18:00 에 새 표가 나온다 — 다만 여유가 없다.
**권장 분할:**

- **오늘 오후**: Task 1 → Task 2 → **Task 3 의 표집을 걸어 두고 끝낸다.**
- **다음 세션**: Task 3 나머지(풀이·검증) → Task 4 → Task 5.

표집은 재개 가능하다(`run_board` 가 `rows.jsonl` 이 있으면 건너뛴다), 그래서 중간에 끊어도 손해가 없다.

---

## Global Constraints

이 절은 **모든 태스크에 암묵적으로 포함된다.** 앞 두 세션이 실제로 데인 것들이다.

1. **작업 디렉토리 = `/home/chahj578/Construction_OODlayer`**, 브랜치 `oracle-rebuild-night-2026-08-10`.
2. Python 은 언제나 `/home/chahj578/Construction_OODlayer/.venv/bin/python`. Julia 는 `julia +lts --project=.`.
3. **목적함수 상수를 리터럴로 복붙하지 않는다** — `objective.load()` / `objective.J()` 경유.
   **문서에 `objective_hash` 를 문자열로 적지 않는다**(`audit_objective.py` 항목 9 가 스테일로 판정).
4. **행동 어휘는 `action_registry.json` 파생으로만 받는다.** `audit_action_vocab.py` 는 여분 id 도
   실패로 다룬다.
5. **★ 스윕·표집이 도는 중에 `run_demo.jl`·`policy.jl` 을 절대 건드리지 않는다.** 계측 변경은
   표집 시작 **전에** 커밋하고, 도는 동안 `git status --porcelain tools/monitor/` 가 비어 있어야 한다.
6. **★ 4정책 스윕이 도는 중에는 커밋하지 않는다.** `run_shard.sh` 의 provenance 도장이 HEAD SHA 라
   중간에 HEAD 가 바뀌면 한 스윕 안에서 세대가 갈린다. `sample_grid.py` 에는 그 도장이 **없으므로**
   표집 중에는 커밋해도 된다.
7. **★ 스윕 드라이버를 죽일 때 `xargs` 가 살아남는다.** `pgrep -f "xargs -a"` 로 따로 확인해 죽일 것.
   `pkill -f "sleep N"` 같은 넓은 패턴은 자기 자신이 도는 셸까지 죽인다(실측).
8. **표집 중 서비스(:8090)를 재시작하지 않는다.** 표집 판은 `--policies canonical` 이라 LLM 을
   부르지 않지만, `llm_ood_eval.py run` 이 기동 시 `/health` 를 친다.
9. **`DS_HOTSWAP=1`** — 실행 레인(`run_demo.jl:557`)이 hot-swap ON 이다. 안 켜면 fault 발화율이
   100% → 23% 로 조용히 무너진다.
10. **조용히 빼지 않는다.** 어떤 팔·판·전이를 제외하면 그 사실을 **이름과 수로 로그에 찍는다.**

---

## 1. 지금 DP 가 baseline 이 아닌 이유 — 실측 셋

`dp_oracle/gap_breakdown.py` 와 `dp_oracle/samples.jsonl`(575판 / 5045 전이) 재집계.

### 1-A. 표집 판이 완주하지 않아 `V` 가 실패 벌점에 눌려 있다 — **지배 원인**

```
표집 판 575개 중 완주  97 (16.9%)          <- 실행 레인은 ~98.6%
V 중앙값 4743.6                             (정상 완주 규모는 20~60)
팔별 완주율: NOOP 0% · Deprioritize 0% · ReformTeam 4.2% · ForbidZone 14.3%
             RelocateBuild 14.3% · Replace 34.5% · SwapBattery 48.8%
```

gap 이 큰 칸 상위 12 의 margin 이 **전부 14,813 ~ 14,972** 다. 미완주 판의
`J ≈ 10000 + 100·(total − closed)` 가 그 칸의 `V` 를 지배하고, 같은 칸에서 실행 레인은 20~60 을
낸다. **이건 정책 비교가 아니라 "표집 판이 죽었다"를 재고 있는 것이다.**

### 1-B. 칸의 절반이 팔을 하나만 본다 — argmin 이 성립하지 않는다

```
표본이 있는 고유 칸 49개 · 고유 (칸,팔) 쌍 156개
칸당 관측된 팔 수:  1팔 → 27칸   2팔 → 4칸   5팔 → 2칸   6팔 → 1칸   7팔 → 15칸
```

팔을 판 전체에 고정하면 궤적이 팔마다 갈라져 **서로 다른 칸에 착지한다.** 그래서 27칸이
단일팔이고, `V` 는 있지만 `a*` 가 없다. 그 귀결이 dp 레인의 조회 실패다:

| dp 레인 결정 1502건 | |
|---|---|
| `single_arm` | 841 (**56.0%**) |
| `tie_unresolved` | 545 (36.3%) |
| **표 조회 성공** | **116 (7.7%)** |

**dp 열은 사실상 92.3% 가 canonical 폴백이다.** 실제로 Keep-out zone 칸에서 dp 의 결과
(56.4 s · 492 J)가 canonical 과 **자릿수까지 같아졌다.**

### 1-C. φ̃ 추상화 손실 — 남지만 이 계획의 범위 밖

레벨별 gap 이 그 크기의 하한이다: L0 97.9% · **L1 42.1%** · L2 100%.
`spares_b` 를 뭉개면 오히려 `V` 가 겨룰 만해진다 = 정밀 칸의 표본이 얇다는 뜻이고,
그건 1-A 와 같은 방향이다. **1-A 를 고친 뒤에도 gap 이 남으면 그때 남는 것이 이것이다.**

---

## 2. 무엇을 바꾸는가 — 한 문단

지금 한 rollout = `DEMO_FORCE_MACRO=Replace` 로 굴린 **판 전체**다. 그래서 Reform 사건이 뜬 판에
Replace 를 계속 먹이고, 판이 죽는다. 바꾼 뒤 한 rollout = **k 번째 결정에서만** 그 팔을 집행하고
**k+1 부터는 canonical** 로 굴린 판이다. 그러면

- 판이 canonical 만큼 완주한다(~98.6%) → `V` 가 실패 벌점에서 풀린다 (1-A 해소)
- 모든 팔의 판이 같은 prefix 를 공유하므로 **같은 칸에 착지한다** → 그 칸이 여러 팔을 본다 (1-B 해소)
- `Q(s,a)` 가 "그 팔을 **한 번** 썼을 때의 한계 효과" 라는 원래 정의를 되찾는다

**비용은 그대로다.** 판 수를 늘리지 않는다 — 판당 deviation 을 하나만 넣고, 그 위치 `k` 를
`(case, seed, arm)` 에서 결정론적으로 흩뿌려 깊이를 덮는다.

---

## 3. 판정 기준 — 성공/실패를 미리 못박는다

Task 5 는 아래 표를 채우는 것이 전부다. **하나라도 "미달" 이면 그렇게 적는다.**

| # | 지표 | 현재 | 목표 | 어디서 나오나 |
|---|---|---|---|---|
| 1 | 표집 판 완주율 | 16.9% | **≥ 90%** | `sample_grid.py` 요약 |
| 2 | `V` 중앙값 | 4743.6 | **20 ~ 200** | `dp_solve.py` 요약 |
| 3 | 단일팔 칸 | 27 / 49 | **≤ 5** | Task 3 Step 8 스니펫 |
| 4 | dp 레인 표 조회 성공률 | 7.7% | **≥ 50%** | 4pol 행의 `dp_miss` 집계 |
| 5 | §8.7 gap | 89.3% | **≤ 20%** | `gap_breakdown.py` |
| 6 | 분해 충실성 위반 판 | 0 | **0 (유지)** | `sample_grid.py` exit code |

**1차 판정 = #1 과 #3.** 이 둘은 이번 변경이 **직접** 만드는 것이라, 안 오르면 구현이 틀린 것이다.
**2차 판정 = #5.** 이건 가설이다 — #1·#3 이 올랐는데도 gap 이 안 내려가면 남은 원인은 §1-C(φ̃)
하나이고, 그건 **다음 사이클 거리**다. 그 경우에도 **DP 열 부제를 "ceiling" 으로 되돌리지 않는다.**

---

## 4. 이미 끝나 있는 것 — 다시 하지 말 것

- **prefix 결정성 측정.** `dp_oracle/PROBE_RESULT.md` — `sampling_mode: replay` 확정,
  10/10 지문 동일. **다시 재지 않는다.** 단, 그 프로브가 잰 것은 *주입 시점*의 결정성이고
  이 계획이 필요로 하는 것은 *k 번째 결정까지의 prefix* 결정성이라 **더 강한 요구**다 —
  그래서 Task 1 Step 6 이 그것을 별도로 잰다.
- **행동집합 폐쇄.** `arm_menu()` 는 이미 레지스트리 파생이고 실행가능 7팔이다. 손대지 않는다.
- **비용 분해 · 충실성 게이트.** `c_prefix + Σc_k + terminal == J_row` 가 이미 돌고 실측 위반 0.
  **이 계획은 그 게이트를 바꾸지 않는다** — deviation 은 어느 팔이 집행됐는지만 바꾸고
  비용 분해의 형태는 안 바꾼다.
- **`dp_solve.py`.** backward induction 은 그대로다. 입력 표본만 좋아진다.
- **라벨 재생성 · surrogate 재학습.** 이번 사이클과 무관하다. `:8090` 은 그대로 둔다.

---

## Task 1: `policy.jl` 이 "k 번째 결정에서만" 팔을 갈아 쓴다

**Files:**
- Modify: `tools/monitor/policy.jl:664-668` (FORCE_MACRO 상수 근처 — 새 상수 추가)
- Modify: `tools/monitor/policy.jl:953-961` (강제 집행 지점 — 조건 추가)
- Test: `tools/monitor/test_deviation.jl` (신규)

**Interfaces:**
- Consumes: 없음 (이 계획의 첫 태스크)
- Produces: 환경변수 계약 **두 개**, Task 2 가 이 이름 그대로 세팅한다 —
  - `DS_DEVIATE_AT` : 1-기반 결정 인덱스(정수 문자열). 미설정/빈 문자열이면 기능 OFF.
  - `DS_DEVIATE_ARM` : 매크로 **이름**(`"Replace"` 등, id 아님 — `FORCE_MACRO` 와 같은 규약).
  - 결정 행에 추가되는 키: `deviated`(Bool) · `deviate_at`(Int) · `deviate_from`(String)

> **찾을 때 주의.** `sample_grid.py:100` 주석이 "`run_demo.jl` 의 `handle_ood!` 가 해석한다" 고
> 적어 놨는데 **틀렸다.** 실제 소비처는 `tools/monitor/policy.jl:668` 의 `FORCE_MACRO` 다.
> `grep -rn "DEMO_FORCE_MACRO" src tools wm4spacecraft_manufacturing` 로 확인할 것.
> (이 주석도 Step 7 에서 같이 고친다.)

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`tools/monitor/test_deviation.jl` 생성:

```julia
# 결정 카운터와 deviation 게이트의 순수 로직 검사.
# 시뮬레이터를 띄우지 않는다 — policy.jl 의 판정 함수만 부른다.
using Test
include(joinpath(@__DIR__, "policy.jl"))

@testset "should_deviate" begin
    # (deviate_at, deviate_arm, 현재 결정 인덱스) -> 갈아쓸 이름 또는 nothing
    @test Policy.should_deviate(3, "Replace", 3) == "Replace"   # 그 결정에서만
    @test Policy.should_deviate(3, "Replace", 2) === nothing     # 이전 결정은 기준 정책
    @test Policy.should_deviate(3, "Replace", 4) === nothing     # 이후 결정도 기준 정책
    @test Policy.should_deviate(0, "Replace", 1) === nothing     # OFF (at<=0)
    @test Policy.should_deviate(3, "",        3) === nothing     # 팔 이름이 비면 OFF
end

@testset "decision counter" begin
    Policy._reset_decision_counter!()
    @test Policy._next_decision_index!() == 1
    @test Policy._next_decision_index!() == 2
    @test Policy._next_decision_index!() == 3
    Policy._reset_decision_counter!()
    @test Policy._next_decision_index!() == 1
end
```

- [ ] **Step 2: 실패를 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. tools/monitor/test_deviation.jl
```

기대: `UndefVarError: should_deviate not defined` 로 FAIL.

- [ ] **Step 3: 최소 구현 — `policy.jl:668` 의 `FORCE_MACRO` 바로 아래에 추가**

```julia
# ---- 1-step deviation (DP 표집 전용) ---------------------------------------------------
# DS_DEVIATE_AT=k · DS_DEVIATE_ARM=<이름> 이면 **k 번째 결정에서만** 그 팔을 집행하고
# 나머지 결정은 실행 정책(canonical)이 고른 것을 그대로 쓴다.
#
# 왜 FORCE_MACRO 와 따로 두는가: FORCE_MACRO 는 판 전체를 덮는 통제 실험용이고, 그 의미는
# 그대로 남겨야 한다(기존 교차 대조가 그걸 쓴다). 여기서 조건을 붙이면 그 용도가 조용히
# 바뀐다. 두 손잡이가 동시에 켜지면 예외를 던진다 — 어느 쪽이 이겼는지 모르는 판을 만드는
# 것이 이 표집에서 제일 비싼 실패다.
const DEVIATE_AT  = something(tryparse(Int, get(ENV, "DS_DEVIATE_AT", "")), 0)
const DEVIATE_ARM = strip(get(ENV, "DS_DEVIATE_ARM", ""))

if !isempty(FORCE_MACRO) && DEVIATE_AT > 0
    error("DEMO_FORCE_MACRO 와 DS_DEVIATE_AT 를 같이 켤 수 없다 — 집행 규칙이 둘이 된다.")
end

const _DECISION_N = Ref(0)
_reset_decision_counter!() = (_DECISION_N[] = 0)
_next_decision_index!()    = (_DECISION_N[] += 1; _DECISION_N[])

"""
    should_deviate(at, arm, idx) -> String | nothing

`idx` 번째 결정에서 집행을 `arm` 으로 갈아쓸지. 갈아쓰지 않으면 `nothing`.
순수 함수다 — env·시뮬레이터 없이 검사된다(2026-08-14 의 `escalation_target` 과 같은 이유).
"""
should_deviate(at::Int, arm::AbstractString, idx::Int) =
    (at > 0 && !isempty(arm) && idx == at) ? String(arm) : nothing
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

```bash
julia +lts --project=. tools/monitor/test_deviation.jl
```

기대: `Test Summary: | Pass 7 | Total 7`.

- [ ] **Step 5: 집행 지점에 배선한다 — `policy.jl:953` 의 `forced` 블록을 이렇게 바꾼다**

```julia
    rt["enacted"] = enacted
    rt["fell_back"] = fell_back
    chosen = pol[enacted]["chosen"]

    # 이 판에서 몇 번째 결정인가. deviation 이 꺼져 있어도 센다 — 행에 남겨 두면
    # 나중에 "왜 그 칸에 표본이 없나" 를 로그만으로 답할 수 있다.
    didx = _next_decision_index!()
    rt["decision_index"] = didx

    # 통제 실험(FORCE_MACRO): 정책의 결정은 그대로 기록하고 집행만 덮어쓴다.
    forced = !isempty(FORCE_MACRO) && FORCE_MACRO != chosen
    if forced
        rt["forced_macro"] = FORCE_MACRO
        rt["forced_from"] = chosen
        @info "[policy] FORCED enactment $(chosen) → $(FORCE_MACRO) (DEMO_FORCE_MACRO, 통제 실험)"
        chosen = String(FORCE_MACRO)
    end

    # 1-step deviation: k 번째 결정에서만 갈아쓴다.
    dev = should_deviate(DEVIATE_AT, DEVIATE_ARM, didx)
    if dev !== nothing && dev != chosen
        rt["deviated"] = true
        rt["deviate_at"] = didx
        rt["deviate_from"] = chosen
        @info "[policy] DEVIATE #$(didx): $(chosen) → $(dev) (DS_DEVIATE_AT, 1-step)"
        chosen = dev
    end
```

⚠️ `_DECISION_N` 은 프로세스 전역이다. 표집은 판마다 **새 프로세스**라 초기화가 필요 없지만,
같은 프로세스에서 판을 두 번 굴리는 경로(UI·`render_demo.jl`)가 있으므로 **판 시작 시
`_reset_decision_counter!()` 를 부른다.** `run_demo.jl` 에서 `_SIM_STEP` 을 초기화하는 자리 옆이다:

```bash
grep -n "_SIM_STEP\[\] = 0\|_SIM_STEP\[\]=0" tools/monitor/run_demo.jl
```

그 줄 바로 다음에 `Policy._reset_decision_counter!()` 를 넣는다.

- [ ] **Step 6: ★ prefix 결정성 게이트 — 이 계획 전체가 여기 걸려 있다**

`PROBE_RESULT.md` 가 잰 것은 *주입 시점*의 결정성이다. 이 계획이 필요로 하는 것은
**k 번째 결정까지의 prefix 가 재현되는가** 이고, 그게 더 강한 요구다. 직접 잰다 —
**deviation 을 결정 수보다 뒤에 걸면 그 판은 순수 canonical 판과 같아야 한다.**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
mkdir -p /tmp/devgate

# (a) 순수 canonical 판
DS_HOTSWAP=1 JULIA_NUM_THREADS=1 ../.venv/bin/python llm_ood_eval.py run \
  --case fault --seeds 1 --policies canonical --world-seed 1 --router 0 \
  --dspy-url http://127.0.0.1:8090 --out /tmp/devgate/base.jsonl

# (b) 결정 수보다 뒤(999)에 deviation 을 건 판 — 집행은 한 번도 안 바뀐다
DS_HOTSWAP=1 JULIA_NUM_THREADS=1 DS_DEVIATE_AT=999 DS_DEVIATE_ARM=Replace \
  ../.venv/bin/python llm_ood_eval.py run \
  --case fault --seeds 1 --policies canonical --world-seed 1 --router 0 \
  --dspy-url http://127.0.0.1:8090 --out /tmp/devgate/late.jsonl

../.venv/bin/python - <<'EOF'
import json
KEYS = ["closed", "complete", "makespan", "n_decisions", "status", "steps"]
a = json.loads(open("/tmp/devgate/base.jsonl").readline())
b = json.loads(open("/tmp/devgate/late.jsonl").readline())
diff = {k: (a.get(k), b.get(k)) for k in KEYS if a.get(k) != b.get(k)}
ea = (a.get("battery") or {}).get("total_energy_J")
eb = (b.get("battery") or {}).get("total_energy_J")
print("종단 지표 차이:", diff or "없음")
print("energy_J:", ea, "vs", eb)
da = [(d["at"], d["macro"]) for d in a["decisions"]]
db = [(d["at"], d["macro"]) for d in b["decisions"]]
print("결정 열 동일:", da == db, "(%d vs %d 결정)" % (len(da), len(db)))
print("PASS" if not diff and da == db else "FAIL — replay 가 재현되지 않는다")
EOF
```

기대: `PASS`.

**FAIL 이면 여기서 멈추고 계획을 축소한다.** 그 경우 replay prefix 가 재현되지 않는다는 뜻이고,
`k ≥ 2` 의 deviation 은 "다른 팔의 효과"가 아니라 "다른 궤적"을 재는 것이 된다.
**축소판:** `DS_DEVIATE_AT` 을 **1 로 고정**한다 — 첫 결정 시점의 상태는 `PROBE_RESULT.md` 가
이미 10/10 로 재현을 확인한 바로 그 지점이라 안전하다. 깊이 커버리지는 잃지만 §1-A(완주율)와
§1-B(단일팔)는 그대로 해소된다. Task 2 Step 3 의 `pick_k` 를 `return 1` 로 바꾸고,
그 사실을 **결과 문서에 이름으로 적는다**(Global Constraint 10).

- [ ] **Step 7: 틀린 주석을 고친다**

`dp_oracle/sample_grid.py:100` 의 "`run_demo.jl` 의 `handle_ood!` 문자열 디스패치" 를
"`tools/monitor/policy.jl:668` 의 `FORCE_MACRO` / `DEVIATE_ARM` 디스패치" 로 정정한다.

- [ ] **Step 8: 기존 회귀가 안 깨졌는지 확인하고 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. tools/monitor/test_narrate.jl
julia +lts --project=. tools/monitor/test_lane_select.jl
julia +lts --project=. tools/test_policy_escalation.jl
julia +lts --project=. tools/monitor/test_deviation.jl
```

넷 다 exit 0 이어야 한다. 그 다음:

```bash
git add tools/monitor/policy.jl tools/monitor/run_demo.jl \
        tools/monitor/test_deviation.jl wm4spacecraft_manufacturing/dp_oracle/sample_grid.py
git commit -m "feat(dp): 결정 하나만 갈아쓰는 1-step deviation 훅

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

⚠️ **이 커밋은 표집 시작 전에 끝나 있어야 한다**(Global Constraint 5).

---

## Task 2: 표집기를 deviation 모드로 바꾼다

**Files:**
- Modify: `wm4spacecraft_manufacturing/dp_oracle/sample_grid.py` (`run_board`, `main`, 머리말)
- Test: `wm4spacecraft_manufacturing/dp_oracle/test_deviation_plan.py` (신규)

**Interfaces:**
- Consumes: Task 1 의 `DS_DEVIATE_AT` · `DS_DEVIATE_ARM` 환경변수 계약
- Produces:
  - `pick_k(case, seed, arm_id, n_hint) -> int` — 판마다 deviation 위치를 결정론적으로 고른다
  - `samples.jsonl` 의 `sampling_mode` 값이 `"transition"` → **`"one_step_deviation"`**
  - 전이 행에 `deviate_at`(Int) 추가 — `dp_solve.py` 는 이 키를 **읽지 않는다**(진단용)

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`dp_oracle/test_deviation_plan.py` 생성:

```python
"""pick_k 의 계약: 결정론적이고, 판마다 깊이가 흩어지고, 항상 1 이상이다."""
import os, sys, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sample_grid import pick_k

N_HINT = 8   # 실측 중앙값(samples.jsonl: mean 8.77 / median 8)


def test_deterministic():
    assert pick_k("fault", 3, 1, N_HINT) == pick_k("fault", 3, 1, N_HINT)


def test_in_range():
    for case in ("fault", "battery", "zone", "all"):
        for seed in range(1, 13):
            for arm in (0, 1, 2, 3, 4, 7, 8):
                k = pick_k(case, seed, arm, N_HINT)
                assert 1 <= k <= N_HINT, (case, seed, arm, k)


def test_spreads_over_depth():
    """한 팔의 12 시드가 한 깊이에 몰리면 그 팔은 얕은 칸만 잰다."""
    for arm in (0, 1, 2, 3, 4, 7, 8):
        ks = {pick_k("fault", s, arm, N_HINT) for s in range(1, 13)}
        assert len(ks) >= 4, (arm, sorted(ks))


def test_all_arms_share_k_somewhere():
    """같은 (case, seed) 에서 모든 팔이 같은 k 를 쓰는 조합이 있어야
    그 칸이 7팔을 다 본다 = 단일팔 칸이 줄어드는 메커니즘."""
    hit = 0
    for seed in range(1, 13):
        ks = {pick_k("fault", seed, a, N_HINT) for a in (0, 1, 2, 3, 4, 7, 8)}
        if len(ks) == 1:
            hit += 1
    assert hit >= 3, hit
```

- [ ] **Step 2: 실패를 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python -m pytest dp_oracle/test_deviation_plan.py -v
```

기대: `ImportError: cannot import name 'pick_k'` 로 FAIL.

- [ ] **Step 3: `pick_k` 를 `sample_grid.py` 의 `arm_menu()` 아래에 구현한다**

```python
# ---- deviation 위치 배분 -----------------------------------------------------------------
# 판마다 deviation 을 **하나만** 넣는다. 판 수를 늘리지 않기 위해서다(588판 = 현행과 동일 비용).
# 그 대신 위치 k 를 (case, seed) 에서 흩뿌려 깊이를 덮고, **한 (case,seed) 안에서는 모든 팔이
# 같은 k 를 쓴다** — 그래야 일곱 팔이 같은 칸에 착지해서 그 칸에 argmin 이 생긴다(§1-B).
# 즉 깊이 다양성은 seed 축이 만들고, 팔 비교 가능성은 seed 를 고정해서 만든다. 두 목적을
# 같은 축에 얹으면(팔마다 다른 k) 둘 다 잃는다.
#
# 난수를 안 쓴다: 재현이 이 표집의 계약이고(README 함정), 시드 상태를 하나 더 들고 다니면
# 그 자체가 재현 실패의 원인이 된다.
def pick_k(case, seed, arm_id, n_hint):
    """이 판에서 몇 번째 결정을 갈아쓸지. 1-기반. arm_id 는 **일부러 안 쓴다**(위 주석)."""
    del arm_id
    h = (hash((case, int(seed))) & 0x7FFFFFFF)
    return 1 + (h % max(1, int(n_hint)))
```

⚠️ Python 의 `hash()` 는 문자열에 대해 프로세스마다 달라진다(`PYTHONHASHSEED`).
**표집 워커는 별개 프로세스이므로 이대로면 재현이 깨진다.** 결정론적 해시를 쓴다:

```python
import zlib

def pick_k(case, seed, arm_id, n_hint):
    """이 판에서 몇 번째 결정을 갈아쓸지. 1-기반. arm_id 는 **일부러 안 쓴다**(위 주석).

    zlib.crc32 를 쓰는 이유: 내장 hash() 는 문자열에 대해 PYTHONHASHSEED 로 프로세스마다
    달라진다. 표집 워커는 별개 프로세스라 그걸 쓰면 판마다 다른 k 가 나와 재현이 깨진다.
    """
    del arm_id
    h = zlib.crc32(("%s|%d" % (case, int(seed))).encode())
    return 1 + (h % max(1, int(n_hint)))
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

```bash
../.venv/bin/python -m pytest dp_oracle/test_deviation_plan.py -v
```

기대: 4 passed. `test_spreads_over_depth` 가 실패하면 `n_hint` 대비 시드가 부족한 것이다 —
`--seeds` 를 12개보다 늘려야 한다는 신호이므로 **테스트를 느슨하게 고치지 말고 시드를 늘린다.**

- [ ] **Step 5: `run_board` 를 deviation 모드로 바꾼다**

`sample_grid.py` 의 `run_board`(현행 126행 근처)에서 `env.update(...)` 블록을 교체:

```python
def run_board(case, seed, arm_id, arm_name, outroot, world_seed=1, n_hint=8):
    """판 하나를 **k 번째 결정만** 그 팔로 굴린다. 반환: (rows 경로 또는 None, k)."""
    k = pick_k(case, seed, arm_id, n_hint)
    outdir = os.path.join(outroot, "%s_s%d_a%d" % (case, seed, arm_id))
    rows = os.path.join(outdir, "rows.jsonl")
    if os.path.exists(rows) and os.path.getsize(rows) > 0:
        return rows, k                                 # 재개: 이미 끝난 판은 다시 굴리지 않는다
    os.makedirs(outdir, exist_ok=True)
    env = dict(os.environ)
    env.update(
        # ★ DEMO_FORCE_MACRO 를 **쓰지 않는다**. 판 전체 고정이 §1-A 의 원인이었다.
        DS_DEVIATE_AT=str(k),
        DS_DEVIATE_ARM=arm_name,
        DS_HOTSWAP="1",                                # Global Constraint 9
        DEMO_ALL_POLICIES="0",
        JULIA_NUM_THREADS="1", OPENBLAS_NUM_THREADS="1",
        OMP_NUM_THREADS="1", MKL_NUM_THREADS="1")
    env.pop("DEMO_FORCE_MACRO", None)                  # 부모 환경에 남아 있으면 policy.jl 이 죽는다
    cmd = [PY, os.path.join(WM, "llm_ood_eval.py"), "run",
           "--case", case, "--seeds", str(seed), "--policies", "canonical",
           "--out", rows, "--dspy-url", DSPY_URL, "--router", "0",
           "--world-seed", str(world_seed)]
    with open(os.path.join(outdir, "board.log"), "w") as lg:
        rc = subprocess.call(cmd, stdout=lg, stderr=subprocess.STDOUT, cwd=WM, env=env)
    if rc != 0 or not os.path.exists(rows) or os.path.getsize(rows) == 0:
        return None, k
    return rows, k
```

호출부(`main` 안의 `ThreadPoolExecutor` 블록)에서 반환값이 튜플이 된 것을 반영하고,
전이 행을 만들 때 `sampling_mode` 를 `"one_step_deviation"` 으로, `deviate_at` 을 `k` 로 찍는다.

- [ ] **Step 6: 엔진 크래시를 세되 죽지는 않는다**

`ReformTeam` 팔은 표집 판의 15.5% 에서 엔진을 죽인다
(`AssertionError: has_edge(scene_tree, agent, robot_id)`). deviation 모드에서는 그 팔이
판당 한 번만 집행되므로 빈도가 떨어질 것으로 **예상되지만 확인 대상이다.**
`main()` 의 요약에 팔별 실패 수를 이름으로 찍는다:

```python
    # 표집 실패를 팔 이름으로 센다. 뭉뚱그리면 "왜 Reform 축이 얇은가" 를 로그로 답할 수 없다.
    print("[표집] 판 %d개 중 실패 %d개" % (n_boards, sum(fail_by_arm.values())))
    for name, n in sorted(fail_by_arm.items(), key=lambda t: -t[1]):
        print("[표집]   %-14s %d" % (name, n))
```

⚠️ **실패 판을 조용히 버리지 않는다.** 충실성 위반(`boards_bad`)은 지금처럼 exit 1 이고,
엔진 크래시는 exit 0 이되 **수가 로그에 남는다** — 둘은 다른 사건이다.

- [ ] **Step 7: 머리말을 고친다**

`sample_grid.py` 첫 줄 docstring 의 "한 rollout = **한 판 전체**를 `DEMO_FORCE_MACRO=<팔>` 로
굴린 것이다" 를 새 의미로 바꾸고, **왜 바꿨는지**(§1-A 의 16.9%)를 숫자와 함께 적는다.
구세대 상수-팔 표본은 `samples_gen_backward_2026-08-15.jsonl` 처럼 이름 붙여 보존한다.

- [ ] **Step 8: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/dp_oracle/sample_grid.py \
        wm4spacecraft_manufacturing/dp_oracle/test_deviation_plan.py
git commit -m "feat(dp): 표집을 1-step deviation 으로 바꾼다 — 상수-팔 판이 83% 죽던 것을 끝낸다

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: 표집 · 풀이 · 1차 판정

**Files:**
- Create: `wm4spacecraft_manufacturing/dp_oracle/samples.jsonl` (덮어씀 — 구세대는 먼저 이름 붙여 보존)
- Create: `wm4spacecraft_manufacturing/dp_oracle/value.json` (덮어씀)

**Interfaces:**
- Consumes: Task 2 의 `sampling_mode == "one_step_deviation"` 표본
- Produces: `value.json` — Task 4 의 dp 레인이 조회한다

- [ ] **Step 1: 구세대 표본을 이름 붙여 보존한다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/dp_oracle
cp samples.jsonl samples_gen_constantarm_2026-08-16.jsonl
cp value.json    value_gen_constantarm_2026-08-16.json
```

**지우지 않는다** — 두 세대를 나란히 놔야 이번 변경이 무엇을 바꿨는지 말할 수 있다
(2026-08-15 이 `solve_constant_arm()` 을 보존한 것과 같은 이유).

- [ ] **Step 2: 작업 트리가 깨끗한지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer
git status --porcelain tools/monitor/
```

기대: **빈 출력**(Global Constraint 5). 비어 있지 않으면 표집을 시작하지 않는다.

- [ ] **Step 3: 서비스가 살아 있는지 확인한다**

```bash
curl -s http://127.0.0.1:8090/health
```

`"status":"ok"` 여야 한다. 죽어 있으면 `md/RESULTS_ACTION_SET_CLOSURE_2026-08-16.md` §5 (2) 로 띄운다.
**표집 도중에는 재시작하지 않는다**(Global Constraint 8).

- [ ] **Step 4: 표집을 건다 (약 1.8시간)**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
export DSPY_URL=http://127.0.0.1:8090
nohup ../.venv/bin/python dp_oracle/sample_grid.py --jobs 26 \
  --seeds 1,2,3,4,5,6,7,8,9,10,11,12 > /tmp/sample_dev.log 2>&1 &
echo $!
```

진행 확인: `tail -f /tmp/sample_dev.log` (표집기가 판 수·경과·예상 총시간을 찍는다).

- [ ] **Step 5: 표집이 exit 0 인지 확인한다**

```bash
tail -30 /tmp/sample_dev.log
```

`분해 충실성 위반` 으로 죽었으면(**exit 1**) 그 뒤 숫자는 전부 무효다. 위반 판의 case/seed/arm 이
로그에 남으므로 그 판 하나를 단독 재현해 원인을 본다 — **게이트를 느슨하게 하지 않는다.**

- [ ] **Step 6: 1차 판정 #1 — 완주율**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python - <<'EOF'
import json, collections
rows = [json.loads(l) for l in open("dp_oracle/samples.jsonl")]
boards = {r["board_id"]: r for r in rows}
comp = collections.Counter(); tot = collections.Counter()
for b in boards.values():
    tot[b["arm_name"]] += 1
    if b["complete"]:
        comp[b["arm_name"]] += 1
n, c = sum(tot.values()), sum(comp.values())
print("표집 판 %d개 중 완주 %d (%.1f%%)   [2026-08-16: 97/575 = 16.9%%]" % (n, c, 100 * c / n))
for a in sorted(tot):
    print("  %-14s %3d/%3d = %5.1f%%" % (a, comp[a], tot[a], 100 * comp[a] / tot[a]))
print("판정 #1:", "PASS" if 100 * c / n >= 90 else "FAIL — 목표 90%")
EOF
```

- [ ] **Step 7: backward induction 을 푼다**

```bash
../.venv/bin/python dp_oracle/dp_solve.py --out dp_oracle/value_L0_nobackoff.json
../.venv/bin/python dp_oracle/dp_solve.py --backoff
```

⚠️ 백오프 없는 표를 **먼저** 만든다 — `gap_breakdown.py` §1 이 두 표를 대조한다.

- [ ] **Step 8: 1차 판정 #2·#3 — V 중앙값과 단일팔 칸**

```bash
../.venv/bin/python - <<'EOF'
import json, statistics, collections
v = json.load(open("dp_oracle/value.json"))
vals = [c["V"] for c in v["cells"].values() if c.get("V") is not None]
print("V 중앙값 %.1f   [2026-08-16: 4743.6]" % statistics.median(vals))
print("판정 #2:", "PASS" if 20 <= statistics.median(vals) <= 200 else "FAIL — 목표 20~200")

rows = [json.loads(l) for l in open("dp_oracle/samples.jsonl")]
per = collections.defaultdict(set)
for r in rows:
    per[r["cell"]].add(r["arm"])
dist = collections.Counter(len(a) for a in per.values())
single = dist.get(1, 0)
print("고유 칸 %d · 단일팔 칸 %d   [2026-08-16: 49칸 중 27]" % (len(per), single))
print("칸당 팔 수 분포:", dict(sorted(dist.items())))
print("판정 #3:", "PASS" if single <= 5 else "FAIL — 목표 5칸 이하")
EOF
```

- [ ] **Step 9: 게이트 + 커밋**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python -m pytest dp_oracle/test_dp_solve.py dp_oracle/test_cost_decomposition.py \
                              dp_oracle/test_cellkey_parity.py dp_oracle/test_deviation_plan.py -q
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/dp_oracle/
git commit -m "data(dp): 1-step deviation 표본 + backward induction 재풀이

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

**★ 이 커밋은 Task 4 의 스윕을 걸기 전에 끝나 있어야 한다**(Global Constraint 6).

---

## Task 4: dp 레인만 재스윕하고 표를 낸다

**Files:**
- Create: `wm4spacecraft_manufacturing/results_4pol/shards_dp/**` (덮어씀)
- Modify: `wm4spacecraft_manufacturing/artifacts_4pol/{COMPARE.md,compare.html,*.json}`

**Interfaces:**
- Consumes: Task 3 의 `value.json`
- Produces: `artifacts_4pol/COMPARE.md` 의 **DP 열** — 나머지 세 열은 현행 세대 값 그대로

- [ ] **Step 1: 세 실행 레인을 다시 굴리지 않아도 된다는 근거를 재확인한다**

**이미 확인된 사실이다**(2026-08-15 계획 작성 시 실측). `value.json` 의 유일한 독자는
`tools/monitor/dp_lane.jl:31` 이고, 그것을 부르는 `dp_macro` 는 `policy.jl:788` 의
**`if POLICY == "dp"` 안에서만** 호출된다. 즉 `canonical`·`surrogate`·`dspy` 판은
`pol["dp"]` 를 만들지도 않는다. 회귀가 없는지만 한 줄로 재확인한다:

```bash
cd /home/chahj578/Construction_OODlayer
grep -rn "value.json" tools/monitor/ | grep -v test        # dp_lane.jl:31 한 줄만 나와야 한다
grep -n "POLICY == \"dp\"" -A 2 tools/monitor/policy.jl | head -5
```

`dp_lane.jl` 밖에서 `value.json` 이 나오거나 `dp_macro` 호출이 그 `if` 밖으로 나와 있으면
**네 열 전부 재스윕**이 필요하고, 그러면 오후 예산이 깨진다 — 그 경우 Task 4 를 다음 세션으로 넘긴다.

- [ ] **Step 2: dp 샤드를 굴린다 (약 40분)**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
nohup bash run_4pol_parallel.sh --jobs 50 --policies dp \
  --shards-dir results_4pol/shards_dp > /tmp/sweep_dp.log 2>&1 &
```

⚠️ **`--shards-dir` 를 반드시 준다.** `run_shard.sh` 의 provenance 도장이 `(commit, policies)`
쌍이라, 같은 OUTDIR 에 다른 정책 목록으로 넣으면 **끝나 있는 세 정책 결과를 지우고 다시 돈다.**

- [ ] **Step 3: 표를 만든다**

```bash
bash finish_tables.sh
```

- [ ] **Step 4: 판정 #4 — dp 레인이 표를 실제로 쓴 비율**

```bash
../.venv/bin/python - <<'EOF'
import json, collections
c = collections.Counter()
for ck in ["battery","fault","zone","fault_battery","fault_zone","battery_zone","all"]:
    for l in open("results_4pol/%s.jsonl" % ck):
        r = json.loads(l)
        if r["policy"] != "dp":
            continue
        for d in r["decisions"]:
            c[d.get("dp_miss") or "표 조회 성공"] += 1
n = sum(c.values())
print("dp 레인 결정 %d건   [2026-08-16: 1502건]" % n)
for k, v in c.most_common():
    print("  %-18s %4d (%4.1f%%)" % (k, v, 100 * v / n))
hit = 100 * c["표 조회 성공"] / n
print("판정 #4:", "PASS" if hit >= 50 else "FAIL — 목표 50%%  (현재 %.1f%%, 2026-08-16 은 7.7%%)" % hit)
EOF
```

- [ ] **Step 5: 표를 원자료에서 재검증한다**

`md/COMPARE_ACTIONSET_DELTA_2026-08-16.md` §1-A 의 스니펫을 그대로 돌려 28칸 + 4합계가
발행된 표와 일치하는지 확인한다. **일치하지 않으면 표가 아니라 표를 만든 코드를 의심한다.**

- [ ] **Step 6: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/results_4pol wm4spacecraft_manufacturing/artifacts_4pol
git commit -m "data(dp): 1-step deviation 세대 — dp 레인 재스윕 + 표

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: 판정과 문서

**Files:**
- Create: `wm4spacecraft_manufacturing/md/RESULTS_ONE_STEP_DEVIATION_2026-08-17.md`
- Modify: `.claude/CLAUDE.md` (★ 결과 세대 절 맨 위에 새 세대 추가, 직전 세대는 **지우지 않는다**)

- [ ] **Step 1: gap 을 재고 §3 의 판정표를 채운다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python dp_oracle/gap_breakdown.py | tee /tmp/gap_dev.txt
```

§3 의 6행을 **전부** 채운다. 미달 항목은 "미달" 이라고 적는다.

- [ ] **Step 2: 결과 문서를 쓴다**

`md/RESULTS_ONE_STEP_DEVIATION_2026-08-17.md`. 반드시 포함할 절:

1. **한 줄 요약** — 1차 판정(#1·#3)과 2차 판정(#5)을 각각 충족/미충족으로 적는다.
2. **비교표** — DP 열만 바뀐 4열 표. 세 실행 레인이 안 바뀐 이유(= `value.json` 을 안 읽는다)를
   각주로 적는다. **이게 이번 판의 통제다.**
3. **전/후 대비** — §1 의 세 숫자(완주율 16.9% · 단일팔 27/49 · 조회 7.7%)가 어떻게 됐는가.
4. **§8.7 gap 과 DP 열의 이름.** gap 이 0 이 아니면 **부제를 "ceiling" 으로 되돌리지 않는다.**
   0 에 가까워졌으면 그때 비로소 "천장" 이라 부를 수 있고, 그 판단은 이 문서에 근거를 적어 남긴다.
5. **알려진 구멍** — 최소한 아래 넷은 재서 적는다:
   - Task 1 Step 6 의 결정성 게이트 결과 (PASS 였나, 축소판으로 갔나)
   - 엔진 크래시 팔별 수 (Task 2 Step 6)
   - φ̃ 추상화 손실 — 레벨별 gap 이 여전히 갈리는가
   - 라벨 레인 재현성 결함(4/365)은 **이 사이클과 무관하다** — 라벨을 안 건드렸다

- [ ] **Step 3: CLAUDE.md 를 갱신한다**

`★ 결과 세대` 절 맨 위에 새 세대를 추가하고, `2026-08-16` 절 제목을 `— **직전 세대**` 로 바꾼다.
**2026-08-16 절의 내용은 지우지 않는다** — §4-B(표집 완주율이 안 올랐다)가 이 작업의 동기다.

- [ ] **Step 4: 전 게이트 + 커밋**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python audit_objective.py && ../.venv/bin/python audit_action_vocab.py
../.venv/bin/python test_surrogate_support.py
../.venv/bin/python -m pytest dp_oracle/ -q
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. tools/monitor/test_deviation.jl
git add -A && git commit -m "docs(dp): 1-step deviation 결과 + 판정

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## 실패해도 이상하지 않은 것 (미리 적어 둔다)

미리 이름을 붙여 두면, 벌어졌을 때 그게 *발견*이지 *실수*가 아니다.

1. **replay prefix 가 재현되지 않는다** (Task 1 Step 6 FAIL). 이게 제일 큰 위험이다 —
   `PROBE_RESULT.md` 는 *주입 시점* 결정성만 쟀고, CLAUDE.md 의 함정("컴파일을 다시 하면
   배정이 재현되지 않는다")은 **프로세스 간** 비교를 이미 한 번 무너뜨린 적이 있다.
   대응은 Task 1 Step 6 에 축소판으로 적어 뒀다(`DS_DEVIATE_AT=1` 고정).
2. **완주율은 올랐는데 gap 이 안 내려간다.** 그러면 남은 원인은 φ̃ 추상화 손실 하나이고,
   그건 격자 재설계라 **다음 사이클 거리**다. 이 경우에도 판정 #1·#3 이 PASS 면 이 작업은
   성공이다 — "무엇이 원인이 아닌지" 를 하나 더 지운 것이기 때문이다.
3. **단일팔 칸이 안 줄어든다.** deviation 이후 canonical 궤적이 팔마다 갈라진다는 뜻이다
   (= 한 번의 개입이 궤적을 크게 흔든다). 그 자체가 발견이고, 그러면 `pick_k` 를
   `k=1` 고정으로 좁혀 prefix 를 최대한 공유시키는 것이 다음 수다.
4. **`ReformTeam` 크래시가 안 줄어든다.** 판당 1회 집행으로도 `has_edge` 어서션이 터지면
   그건 표집 방식이 아니라 **엔진 결함**이고, `apply_cmd!(::FormTransportUnit)` 를 고치는 것이
   별도 작업으로 올라온다.
5. **표집이 1.8시간보다 오래 걸린다.** deviation 판은 완주까지 굴러가므로(현행은 83% 가 일찍
   죽는다) **판당 시간이 늘어날 수 있다.** 실측이 판당 400s 를 넘으면 `--seeds` 를 8개로 줄이고
   그 사실을 결과 문서에 적는다 — 조용히 줄이지 않는다.

---

## Self-Review

- **판정 기준 커버리지**: §3 의 6개 지표가 각각 Task 3 Step 6·8, Task 4 Step 4, Task 5 Step 1 에서
  측정된다. #6(충실성)은 Task 3 Step 5 의 exit code 다. 빠진 것 없음.
- **인터페이스 일관성**: `DS_DEVIATE_AT`/`DS_DEVIATE_ARM` 은 Task 1 Produces 와 Task 2 Step 5 의
  `env.update` 에서 같은 철자다. `pick_k(case, seed, arm_id, n_hint)` 는 Task 2 Step 1 의 테스트,
  Step 3 의 구현, Step 5 의 호출에서 같은 시그니처다. `sampling_mode == "one_step_deviation"` 은
  Task 2 Produces 와 Task 3 Step 1 의 보존 파일명에서 일관된다.
- **placeholder 없음**: 모든 코드 단계에 실제 코드가 있고, 모든 명령에 실제 인자가 있다.
  "적절히 처리한다" 류 문장 없음.
- **알려진 편차 하나**: Task 2 Step 3 이 `hash()` 판을 먼저 보여 준 뒤 `zlib.crc32` 로 정정한다.
  일부러 그렇게 뒀다 — `PYTHONHASHSEED` 함정을 실행자가 모르면 같은 버그를 다시 만든다.
