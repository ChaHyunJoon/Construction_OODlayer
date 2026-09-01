# S1 — 모델이 받는 값을 옳게 만든다 (구현 계획)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 두 OOD 레인(zone · battery_mild)에서 모델이 받는 관측값을 고쳐, `expressible=false`
가 실제로 나오는지를 측정 가능하게 만든다.

**Architecture:** 세 갈래가 서로 독립이다. ① zone 서술자를 면적비에서 막힘 기반으로 옮긴다
(줄리아 `event_descriptors` + 파이썬 twin, 같은 커밋). ② battery 사건에 payload/SoC 사실
블록을 신설한다(`_zones_block` 과 같은 관용구 — 값 없으면 빈 문자열). ③ SoC 임계 여섯 상수를
정합적인 사다리로 다시 잡고 교차 게이트로 못박는다. 그 위에 ④ 후보 간선 상계 프로브(S2 전제)와
⑤ 유료 검증이 얹힌다.

**Tech Stack:** Julia 1.10 (`julia +lts --project=.`), Python `.venv` (dspy 3.3.0, pytest),
gpt-4o via DSPy 서비스.

**Spec:** `docs/superpowers/specs/2026-08-31-s1-observation-and-thresholds-design.md`
(커밋 `b100b84d` + 정정 `45caa9fa`)

## Global Constraints

- **`git add -A` / `git add .` / `git commit -a` 금지.** 작업 트리에 남의 미커밋 삭제가
  212건 있다. 반드시 **명시 경로**로 `git add` 할 것.
- **`julia +lts --project=.`** 를 항상 쓴다. Manifest 는 1.10.11 에 고정돼 있다.
- **파이썬은 레포 루트의 `.venv/bin/python`** 이다.
- **실행 파일은 줄번호가 아니라 심볼로 인용한다.** 이 레포는 줄번호 인용이 조용히 썩는 것을
  반복해 겪었다.
- **`severity` 는 한 글자도 안 건드린다.** surrogate 피처(43개 중 하나)다.
- **어휘 이름을 리터럴로 적지 않는다.** 단일 진실원은 `action_registry.json` 이다.
- **게이트마다 음성 대조를 실제로 돌려 빨간 것을 눈으로 볼 것.** "식을 베껴 쓴 시험"이
  24/24 초록을 받은 전례가 있다.
- **삼상 규약:** "못 쟀다"를 `0` 으로 접지 않는다. `-1`(줄리아 수치) 또는 `n/a`(로그)다.
- **유료 호출 예산 4건, 상한 6건.** 초과하면 멈추고 사용자에게 올린다.
- **유료 호출 전 서비스 세대 확인:** `ps -eo pid,lstart,cmd | grep "port <PORT>"` 로 기동
  시각을 마지막 관련 커밋과 대조. `/health` 200 은 세대 증거가 아니다.
- **인수 기준은 pass 문턱이 아니다:** `fail == 0 && error == 1`(Gurobi 라이선스, 기존) +
  pass 델타가 새 게이트의 단언 수로 설명될 것.

---

## 파일 구조

| 파일 | 책임 | 태스크 |
|---|---|---|
| `src/safety/novelty.jl` | `event_descriptors` — 6 서술자의 줄리아 진실원 | T1 |
| `wm4spacecraft_manufacturing/core/features_agnostic.py` | `descriptors_from_row` — 같은 계산의 파이썬 twin | T1 |
| `tools/monitor/policy.jl` | `event_descriptors_of`(서술자 공급) · `ood_features`(피처) · `decide_all`(프로브 호출) | T1·T2·T4 |
| `src/respec/llm_service/dspy_service.py` | `MacroRequest` 필드 + `_battery_block` 렌더 | T2 |
| `src/navigator/ood_truth.jl` | `REPLACE_SOC_THRESHOLD` · 신설 `STALL_SOC_DEFAULT` | T3 |
| `tools/monitor/run_demo.jl` · `render_demo.jl` | `DEMO_BSOC` · `DEMO_STALL_SOC` 기본값 | T3 |
| `wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl` | `DS_BSOC` · `DS_STALL` 기본값 | T3 |
| `wm4spacecraft_manufacturing/core/reference_policy.py` | `BATTERY_DEEP_SOC` | T3 |
| `test/zone_harm_is_blockage.jl` *(신설)* | T1 게이트 | T1 |
| `src/respec/llm_service/test_battery_block.py` *(신설)* | T2 파이썬 게이트 | T2 |
| `test/battery_load_features.jl` *(신설)* | T2 줄리아 게이트 | T2 |
| `test/soc_ladder_is_coherent.jl` *(신설)* | T3 교차 게이트 | T3 |
| `test/milp_slot_probe_is_pure.jl` *(신설)* | T4 게이트 | T4 |
| `test/runtests.jl` | 신설 게이트 넷을 등재 | T1·T2·T3·T4 |

---

## Task 0: 미커밋 라우팅 레인을 커밋하고 삭제를 정리한다

작업 트리에 `unknown:battery_mild` 라우팅 레인 전체가 **미커밋**으로 있다(실측:
`git show HEAD:tools/monitor/lane_select.jl | grep -c ROUTING_SEVERE_SOC` = 0). 이 상태로 S1
변경을 얹으면 두 작업이 한 diff 에 섞여 어느 쪽이 무엇을 깼는지 못 가른다.

**Files:**
- Modify: (커밋만) `tools/monitor/lane_select.jl` · `tools/monitor/policy.jl` ·
  `tools/monitor/test_lane_select.jl` · `src/respec/llm_service/dspy_service.py` ·
  `src/respec/llm_service/test_routing_kind_reaches_the_prompt.py` ·
  `test/policy_macro_binding.jl` · `test/service_decide_ships_routing_kind.jl` ·
  `test/tool_choice_gate.jl` · `test/tool_lane_keys_survive.jl`

**Interfaces:**
- Produces: `ROUTING_SEVERE_SOC` · `routing_kind(type_name, severity)` 가 HEAD 에 존재하게 된다.
  T3 의 교차 게이트가 이 심볼에 의존한다.

- [ ] **Step 1: 미커밋 변경이 그 레인의 것뿐인지 확인**

```bash
cd ~/Construction_OODlayer
git diff --stat HEAD -- tools/monitor/lane_select.jl tools/monitor/policy.jl \
  tools/monitor/test_lane_select.jl src/respec/llm_service/dspy_service.py \
  src/respec/llm_service/test_routing_kind_reaches_the_prompt.py \
  test/policy_macro_binding.jl test/service_decide_ships_routing_kind.jl \
  test/tool_choice_gate.jl test/tool_lane_keys_survive.jl
```

기대: 9개 파일, 총 200줄 내외. 다른 파일이 섞여 나오면 **멈추고 사용자에게 올린다.**

- [ ] **Step 2: 스위트가 이 상태에서 초록인지 먼저 잰다 (기준선)**

```bash
julia +lts --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3
.venv/bin/python -m pytest src/respec/llm_service/ --ignore=src/respec/llm_service/test_propose.py -q 2>&1 | tail -2
```

기대: `fail == 0`, `error == 1`(Gurobi), 파이썬 `194 passed, 5 skipped`.

**세 값을 적어 둔다** — 이후 모든 델타의 분모이고 T6 이 이것을 인용한다:

```bash
git rev-parse --short HEAD | tee /tmp/s1_base_head.txt
```

| | 값 |
|---|---|
| 착수 HEAD | `_______` (위 명령의 출력) |
| 줄리아 pass | `_______` |
| 파이썬 pass | `_______` |

- [ ] **Step 3: 명시 경로로만 커밋**

```bash
git add tools/monitor/lane_select.jl tools/monitor/policy.jl \
  tools/monitor/test_lane_select.jl src/respec/llm_service/dspy_service.py \
  src/respec/llm_service/test_routing_kind_reaches_the_prompt.py \
  test/policy_macro_binding.jl test/service_decide_ships_routing_kind.jl \
  test/tool_choice_gate.jl test/tool_lane_keys_survive.jl
git commit -m "feat(router): battery 심각도로 라우팅을 가른다 (ROUTING_SEVERE_SOC=0.1)

soc_after <= 0.1 만 'battery'(surrogate)이고 그 위는 'unknown:battery_mild'
로 LLM 레인에 간다. 대가는 lane_select.jl 의 상수 주석에 있다 — 오라클
학습셋 battery 27행 중 18행(0.30·0.50 칸)이 OOD 로 라우팅된다."
git status --short | grep -v '^ D' | head
```

기대: 위 9개 파일이 목록에서 사라지고 `?? ` 와 `` D `` 만 남는다.

---

## Task 1: zone 서술자를 면적비에서 막힘 기반으로 옮긴다

**Files:**
- Modify: `src/safety/novelty.jl` (symbol: `event_descriptors`)
- Modify: `wm4spacecraft_manufacturing/core/features_agnostic.py` (symbol: `descriptors_from_row`)
- Modify: `tools/monitor/policy.jl` (symbol: `event_descriptors_of`)
- Create: `test/zone_harm_is_blockage.jl`
- Modify: `test/runtests.jl`

**Interfaces:**
- Consumes: `ood_features` 가 이미 싣는 `"zone_nav_blocked"`, `"zone_nav_downstream"`
  (둘 다 `Int`, `zone_diagnosis` 가 계산한다).
- Produces:
  - `CB.event_descriptors(; …, nav_blocked::Real = -1.0, nav_downstream::Real = -1.0)
     -> Vector{Float64}` (길이 6, 순서 `[harm, work_at_risk, resource_loss,
     recovery_capacity, progress, slack]` 불변)
  - 파이썬 `descriptors_from_row(row) -> dict` — 행 키 `"zone_nav_blocked"` ·
    `"zone_nav_downstream"` 를 읽는다(없으면 `-1.0`).

- [ ] **Step 1: 실패하는 게이트를 쓴다**

Create `test/zone_harm_is_blockage.jl`:

```julia
# =============================================================================
# **공간 사건의 harm 은 덮임이 아니라 막힘에서 나온다.** (2026-08-31, S1/T1)
#
# 왜 이 파일이 필요한가
# ----------------------
# 2026-08-30 의 라이브 zone 판에서 프롬프트가 자기모순이었다: 기하 블록은
# "nav goal 3개가 막혀 251노드 중 32개가 얼어붙었다"고 적는데 서술자는
# harm=0.00 · work_at_risk=0.00 이었고, 모델의 reason 이 그 0 을 인용하며
# NOOP 을 골랐다(115/115 행이 expressible=True).
# 원인: `_zone_overlap` 은 **staging 원 면적비**인데 실제 피해 기전은
# **nav goal 도착 허용반경이 배제원 안에 들어간 것**이다. 기하가 다르다.
#
# 재는 명제 넷
#   (1) nav_blocked >= 1 이면 harm === 1.0 (종단성), war === downstream/pending
#   (2) nav_blocked == 0 이면 harm === zone_overlap 그대로
#       🔴 덮임만으로 1.0 을 만들면 안 된다 — 레포 실측: root 하역목표 8/8 을
#          덮은 판이 291노드를 전부 닫고 완주했다(시간만 2.1배).
#   (3) nav_blocked == -1(못 쟀다)이면 오늘 값 그대로 (삼상 규약)
#   (4) 비-공간 사건(battery/fault)의 6값이 **바이트 단위로 안 변한다**
#
# 변이시험 (실패하는 것을 실제로 볼 것)
#   · `zone_terminal` 판정에서 `nblk >= 1.0` 을 `nblk >= 0.0` 으로 바꾸면 (2)가
#     빨개진다(nav_blocked=0 인데 harm 이 1.0 이 된다).
#   · harm 의 `zone_terminal ? 1.0 :` 절을 지우면 (1)의 첫 어서션이
#     `1.0 === 0.001` 로 빨개진다 = 옛 공식을 이 fixture 에 대고 단언한 것과 같다.
#   · war 의 `ndown / pending_total` 을 `zov` 로 되돌리면 (1)의 둘째가 빨개진다.
#   · `nav_blocked` 기본값을 `-1.0` 에서 `0.0` 으로 바꾸면 (3)이 빨개진다.
#
# 실행: julia +lts --project=. test/zone_harm_is_blockage.jl
# =============================================================================
module ZoneHarmIsBlockage

using Test
using ConstructionBots
const CB = ConstructionBots

# 2026-08-30 라이브 판의 실제 값이다(streams/tractor__zone_minted.jsonl 에서 읽음).
const ZOV      = 0.002356843670973429
const NBLK     = 3
const NDOWN    = 32
const TOTAL    = 305
const CLOSED   = 54          # pending_total = 305 - 54 = 251 (그 판의 unfinished_total)
const PENDING  = TOTAL - CLOSED

_desc(; kw...) = CB.event_descriptors(; zone_overlap = ZOV, severity = ZOV,
                                        n_active = 18.0, spare_count = 8.0,
                                        closed_at_fire = CLOSED, total_nodes = TOTAL,
                                        progress = 0.177, kw...)

@testset "(1) 막힘이 있으면 harm 은 1.0 이고 war 는 얼어붙은 비율이다" begin
    d = _desc(nav_blocked = NBLK, nav_downstream = NDOWN)
    @test d[1] === 1.0
    @test d[2] ≈ NDOWN / PENDING
    @test d[2] > 0.12 && d[2] < 0.13      # 32/251 = 0.1275…
end

@testset "(2) 막힘이 0 이면 덮임만으로 1.0 을 만들지 않는다" begin
    d = _desc(nav_blocked = 0, nav_downstream = 0)
    @test d[1] === ZOV
    @test d[2] === ZOV
    # 큰 덮임에서도 마찬가지다 — 레포 실측(root 8/8 덮임 판)이 완주였다.
    big = CB.event_descriptors(zone_overlap = 0.8, severity = 0.8, n_active = 18.0,
                               spare_count = 8.0, closed_at_fire = CLOSED,
                               total_nodes = TOTAL, progress = 0.177,
                               nav_blocked = 0, nav_downstream = 0)
    @test big[1] === 0.8
end

@testset "(3) 못 쟀으면 오늘 값 그대로다 (삼상 규약)" begin
    unmeasured = _desc()                                  # 기본값 -1.0
    explicit   = _desc(nav_blocked = -1, nav_downstream = -1)
    legacy     = CB.event_descriptors(zone_overlap = ZOV, severity = ZOV, n_active = 18.0,
                                      spare_count = 8.0, closed_at_fire = CLOSED,
                                      total_nodes = TOTAL, progress = 0.177)
    @test unmeasured == explicit == legacy
    @test unmeasured[1] === ZOV
end

@testset "(4) 비-공간 사건은 바이트 단위로 안 변한다" begin
    # battery: soc 가 유한하므로 has_soc 분기. zone_overlap 은 -1(해당 없음).
    bat = CB.event_descriptors(soc = 0.55, agent_pending = 1.0, n_active = 17.0,
                               spare_count = 8.0, closed_at_fire = 245, total_nodes = 305,
                               progress = 0.803)
    @test bat[1] ≈ 0.45
    @test bat[3] ≈ 0.45
    # nav_* 를 줘도 비-공간 사건에서는 무시된다.
    @test bat == CB.event_descriptors(soc = 0.55, agent_pending = 1.0, n_active = 17.0,
                                      spare_count = 8.0, closed_at_fire = 245,
                                      total_nodes = 305, progress = 0.803,
                                      nav_blocked = 9, nav_downstream = 99)
end

end # module
```

- [ ] **Step 2: 실패를 확인한다**

```bash
julia +lts --project=. test/zone_harm_is_blockage.jl
```

기대: `MethodError` — `event_descriptors` 에 `nav_blocked` 키워드가 아직 없다.

- [ ] **Step 3: 줄리아 서술자를 고친다**

`src/safety/novelty.jl` 의 `event_descriptors` 시그니처에 두 키워드를 더한다:

```julia
function event_descriptors(; soc::Real = NaN, agent_pending::Real = -1.0,
                             zone_overlap::Real = -1.0, severity::Real = 0.0,
                             n_active::Real = 1.0, spare_count::Real = 0.0,
                             closed_at_fire::Real = 0.0, total_nodes::Real = 0.0,
                             progress::Real = 0.0,
                             nav_blocked::Real = -1.0, nav_downstream::Real = -1.0)
```

`is_agent` 를 정의하는 줄 바로 아래에 판정 하나를 더한다:

```julia
    # 🔴 2026-08-31 (S1/T1). 공간 사건의 피해는 **덮임이 아니라 막힘**에서 온다.
    #    `zone_overlap` 은 staging 원 면적비이고, 실제로 노드를 못 닫게 만드는 것은
    #    nav goal 의 도착 허용반경이 배제원 안에 통째로 들어간 것이다(다른 기하다).
    #    그 필드의 계약 문구가 종단성을 직접 주장한다 — "존이 사는 한 절대 안 닫힌다".
    #    ⚠️ `>= 1.0` 이지 `>= 0.0` 이 아니다: 덮임만으로 1.0 을 만들면 레포 실측
    #    (root 하역목표 8/8 을 덮은 판이 완주, 시간만 2.1배)과 충돌한다.
    nblk  = Float64(nav_blocked)
    ndown = Float64(nav_downstream)
    zone_terminal = is_spatial && isfinite(nblk) && nblk >= 1.0
```

`harm` 식을 바꾼다(기존 두 줄을 교체):

```julia
    harm = has_soc ? (1.0 - soc_f) :
           (zone_terminal ? 1.0 :
            (is_spatial ? zov : (is_agent ? 1.0 : Float64(severity))))
    harm = clamp(harm, 0.0, 1.0)
```

`war` 의 `elseif is_spatial` **앞에** 절 하나를 끼운다:

```julia
    war = if is_agent
        per_robot_share = max(1e-9, pending_total / nact)
        apend / per_robot_share
    elseif zone_terminal
        # 얼어붙은 미완 작업의 비율. 못 쟀으면(-1) 덮임으로 폴백한다 — 0 으로 접지 않는다.
        (isfinite(ndown) && ndown >= 0.0) ? ndown / pending_total : zov
    elseif is_spatial
        zov
    else
        0.0
    end
    war = clamp(war, 0.0, 1.0)
```

- [ ] **Step 4: 게이트가 통과하는지 확인한다**

```bash
julia +lts --project=. test/zone_harm_is_blockage.jl
```

기대: 4 testset 전부 PASS.

- [ ] **Step 5: 🔴 음성 대조를 실제로 돌린다**

`harm` 식에서 `zone_terminal ? 1.0 :` 절을 **일시적으로 지우고** 다시 돌린다.

```bash
julia +lts --project=. test/zone_harm_is_blockage.jl 2>&1 | grep -A2 "Test Failed"
```

기대: (1) 이 `1.0 === 0.002356843670973429` 로 **빨갛다**. 확인했으면 되돌린다.
같은 방식으로 `nblk >= 1.0` → `nblk >= 0.0` 변이를 넣고 (2) 가 빨간 것도 본다.

- [ ] **Step 6: 파이썬 twin 을 같은 규칙으로 고친다**

`wm4spacecraft_manufacturing/core/features_agnostic.py` 의 `descriptors_from_row` 에서
`is_agent` 정의 아래에 더한다:

```python
    # 🔴 2026-08-31 (S1/T1). 줄리아 `event_descriptors` 와 **같은 규칙**이다. 두 벌이
    #    갈리면 교정이 무의미해진다는 것이 이 함수의 계약이다.
    nblk = _f(row.get("zone_nav_blocked"), -1.0)
    ndown = _f(row.get("zone_nav_downstream"), -1.0)
    zone_terminal = is_spatial and math.isfinite(nblk) and nblk >= 1.0
```

harm 분기를 바꾼다:

```python
    if has_soc:
        harm = 1.0 - soc
    elif zone_terminal:
        harm = 1.0
    elif is_spatial:
        harm = zov
    elif is_agent:
        harm = 1.0
    else:
        harm = sev
    harm = float(np.clip(harm, 0.0, 1.0))
```

war 분기를 바꾼다:

```python
    if is_agent:
        per_robot_share = max(1e-9, pending_total / n_active)
        war = apend / per_robot_share
    elif zone_terminal:
        war = (ndown / pending_total) if (math.isfinite(ndown) and ndown >= 0.0) else zov
    elif is_spatial:
        war = zov
    else:
        war = 0.0
    work_at_risk = float(np.clip(war, 0.0, 1.0))
```

- [ ] **Step 7: 두 구현이 같은 값을 내는지 게이트로 못박는다**

`test/zone_harm_is_blockage.jl` 의 `end # module` **앞에** testset 을 더한다:

```julia
@testset "(5) 파이썬 twin 과 소수점까지 같다" begin
    py = joinpath(REPO_ROOT, ".venv", "bin", "python")
    core = joinpath(REPO_ROOT, "wm4spacecraft_manufacturing", "core")
    if !isfile(py)
        @test_skip "venv 가 없다 — twin 대조를 건너뛴다 (초록으로 세지 말 것)"
    else
    row = """{"kind":"zone","zone_overlap":$(ZOV),"severity":$(ZOV),"soc":null,
              "agent_pending":-1,"n_active":18,"spare_count":8,"closed_at_fire":$(CLOSED),
              "total_nodes":$(TOTAL),"progress":0.177,
              "zone_nav_blocked":$(NBLK),"zone_nav_downstream":$(NDOWN)}"""
    code = """
import sys, json; sys.path.insert(0, r'$(core)')
import features_agnostic as fa
d = fa.descriptors_from_row(json.loads(r'''$(row)'''))
print(json.dumps([d[k] for k in fa.STATE_DESCRIPTORS]))
"""
    out = read(`$(py) -c $(code)`, String)
    pyv = [parse(Float64, strip(x)) for x in split(strip(out, ['[', ']', '\n', ' ']), ",")]
    jlv = _desc(nav_blocked = NBLK, nav_downstream = NDOWN)
    @test length(pyv) == 6
    for i in 1:6
        @test isapprox(pyv[i], jlv[i]; atol = 1e-12)
    end
    end # if isfile(py)
end
```

`module ZoneHarmIsBlockage` 아래에 상수 하나를 더한다:

```julia
const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
```

- [ ] **Step 8: twin 게이트를 돌린다**

```bash
julia +lts --project=. test/zone_harm_is_blockage.jl
```

기대: 5 testset 전부 PASS. 실패하면 **파이썬 쪽을 고친다** — 줄리아가 진실원이다.

- [ ] **Step 9: 서술자 공급자가 두 값을 나르게 한다**

`tools/monitor/policy.jl` 의 `event_descriptors_of` 에서 `CB.event_descriptors(` 호출에
두 인자를 더한다(마지막 `progress` 줄 뒤):

```julia
        progress       = get(f, "progress", 0.0),
        # 🔴 2026-08-31 (S1/T1). `ood_features` 가 이미 싣는 값이다 — 새 계산이 없다.
        #    없으면 `-1.0`(못 쟀다)이고, 그때 서술자는 옛 공식으로 폴백한다.
        nav_blocked    = get(f, "zone_nav_blocked", -1.0),
        nav_downstream = get(f, "zone_nav_downstream", -1.0))
```

- [ ] **Step 10: 게이트를 스위트에 등재한다**

`test/runtests.jl` 의 `@testset "battery ladder is deep-only"` 블록 **앞에** 넣는다:

```julia
    # 2026-08-31 (S1/T1): 공간 사건의 harm 이 덮임(면적비)이 아니라 막힘에서 나오는가.
    # 2026-08-30 라이브 판에서 프롬프트가 자기모순이었다 — 기하 블록은 "32/251 이 얼어붙었다"
    # 고 적는데 서술자는 harm=0.00 이었고, 모델의 reason 이 그 0 을 인용하며 NOOP 을 골랐다.
    @testset "zone harm is blockage" begin
        include("zone_harm_is_blockage.jl")
    end
```

- [ ] **Step 11: 전체 스위트를 돌린다**

```bash
julia +lts --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3
.venv/bin/python -m pytest wm4spacecraft_manufacturing/core/ -q 2>&1 | tail -2
```

기대: `fail == 0`, `error == 1`. pass 델타가 새 게이트의 단언 수와 같아야 한다 —
**다르면 그 차이를 설명하기 전에 넘어가지 않는다.**

- [ ] **Step 12: 커밋**

```bash
git add src/safety/novelty.jl \
        wm4spacecraft_manufacturing/core/features_agnostic.py \
        tools/monitor/policy.jl test/zone_harm_is_blockage.jl test/runtests.jl
git commit -m "T1: 공간 사건의 harm 을 덮임에서 막힘으로 옮긴다

nav_blocked >= 1 이면 harm=1.0(종단성), war=nav_downstream/pending(크기).
그 아래면 오늘의 zone_overlap 그대로다 — 덮임만으로 1.0 을 만들면 레포 실측
(root 8/8 덮인 판이 완주, 시간만 2.1배)과 충돌한다.

severity 는 안 건드렸다(surrogate 피처). 파이썬 twin 을 같은 커밋에서 같은
규칙으로 고쳤고, 게이트 (5)가 두 구현을 소수점까지 대조한다."
```

---

## Task 2: battery 사건에 payload/SoC 사실 블록을 신설한다

**Files:**
- Modify: `tools/monitor/policy.jl` (symbol: `ood_features`, 신설 `_battery_load_features`)
- Modify: `src/respec/llm_service/dspy_service.py` (symbol: `MacroRequest`, 신설
  `_battery_block`, `_llm_input`)
- Create: `test/battery_load_features.jl`
- Create: `src/respec/llm_service/test_battery_block.py`
- Modify: `test/runtests.jl`

**Interfaces:**
- Consumes: `CB._payload_mass(env, node, p::CB.BatteryParams) -> Float64`(가드가
  `TransportUnitGo`/`DepositCargo`/`FormTransportUnit` 셋을 받는다) ·
  `CB.BATTERY_FLEET[]` (`nothing` 또는 `BatteryFleet`, 필드 `soc::Dict{Any,Float64}`) ·
  `CB.bound_to_agent(node, agent)`.
- Produces: `ood_features` 가 다섯 키를 더 싣는다 —
  `"battery_pending_transports"::Int` · `"battery_payload_max_kg"::Float64` ·
  `"battery_payload_total_kg"::Float64` · `"battery_fleet_soc_median"::Float64` ·
  `"battery_higher_soc_robots"::Int`. **다섯 다 조건부다**(배터리 레이어가 꺼져 있거나
  운반 작업이 없으면 안 실린다). 파이썬 `MacroRequest` 가 같은 이름의 `Optional` 필드로 받는다.

- [ ] **Step 1: 파이썬 렌더의 실패하는 게이트를 쓴다**

Create `src/respec/llm_service/test_battery_block.py`:

```python
"""battery 사건의 payload/SoC 사실 블록. (2026-08-31, S1/T2)

왜 이 파일이 필요한가
----------------------
2026-08-30 라이브 판에서 battery_mild 사건이 받은 것은 관찰문 한 줄과 서술자 6개뿐이었고
(harm=0.45 = 1-soc, work_at_risk=0.28 = 쥔 **작업 수**), **payload 질량은 어느 채널에도
없었다.** 모델의 답은 "55% charge, which is sufficient for continued operation" 이고
6/6 행이 expressible=True 였다. 그 입력에서 그것은 반박 불가한 독해다.

규약은 `_zones_block` 과 **정확히 같다**: 값이 하나도 없으면 **빈 문자열**을 낸다.
🔴 그리고 **사실만 적고 "그러니 무엇을 하라"는 절대 안 적는다** — 그것은 판정이고,
적는 순간 재는 것이 추론이 아니라 프롬프트 준수가 된다(spec §6-2 정답 누수).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import dspy_service as svc  # noqa: E402  (numpy/sklearn-before-dspy 계약)

_BASE = dict(kind="battery", severity=0.55, soc=0.55, spare_count=8, agent_pending=1,
             progress=0.80, n_active=17, nl="Robot R1's battery is degraded.")

_LOAD = dict(battery_pending_transports=4, battery_payload_max_kg=12.80,
             battery_payload_total_kg=21.34, battery_fleet_soc_median=0.94,
             battery_higher_soc_robots=7)


def test_the_block_is_empty_when_no_value_is_shipped():
    """규약 ①: 값이 하나도 없으면 빈 문자열 — 기존 호출자의 프롬프트가 바이트 동일."""
    assert svc._battery_block(svc.MacroRequest(**_BASE)) == ""


def test_the_block_renders_every_shipped_value():
    out = svc._battery_block(svc.MacroRequest(**_BASE, **_LOAD))
    assert "pending_transports" in out and "4" in out
    assert "heaviest_payload_kg" in out and "12.8" in out
    assert "fleet_soc_median" in out and "0.94" in out
    assert "robots_with_higher_soc" in out and "7" in out
    assert "this_robot_soc" in out and "0.55" in out


def test_a_partial_payload_renders_only_what_was_measured():
    """규약 ②: 배터리 레이어가 꺼져 있으면 SoC 셋이 안 실린다 — 그 부분만 빠진다."""
    part = dict(battery_pending_transports=4, battery_payload_max_kg=12.80,
                battery_payload_total_kg=21.34)
    out = svc._battery_block(svc.MacroRequest(**_BASE, **part))
    assert "heaviest_payload_kg" in out
    assert "fleet_soc_median" not in out
    assert "robots_with_higher_soc" not in out


def test_the_block_carries_no_verdict():
    """🔴 정답 누수 금지. 매크로 이름도, 지시절도 없다."""
    out = svc._battery_block(svc.MacroRequest(**_BASE, **_LOAD)).lower()
    for banned in ("swapbattery", "replace", "noop", "should", "recommend", "must ",
                   "hand off", "reassign"):
        assert banned not in out, "판정이 프롬프트에 샜다: %r" % banned


def test_the_block_reaches_both_llm_input_paths():
    """🔴 `_llm_input` 의 **두 반환 경로 모두**에 붙어야 한다. 한쪽만 붙이면 nl 없는
    옛 호출자의 프롬프트에서 조용히 사라지고, 그 누락은 문자열 길이 말고 아무 증상도 없다."""
    with_nl = svc._llm_input(svc.MacroRequest(**_BASE, **_LOAD))
    no_nl_base = dict(_BASE); no_nl_base.pop("nl")
    without_nl = svc._llm_input(svc.MacroRequest(**no_nl_base, **_LOAD))
    assert "heaviest_payload_kg" in with_nl
    assert "heaviest_payload_kg" in without_nl
```

- [ ] **Step 2: 실패를 확인한다**

```bash
.venv/bin/python -m pytest src/respec/llm_service/test_battery_block.py -q
```

기대: 5개 전부 실패 — `AttributeError: module 'dspy_service' has no attribute '_battery_block'`
(첫 둘) 및 `ValidationError`(`MacroRequest` 에 그 필드가 없다).

- [ ] **Step 3: `MacroRequest` 에 다섯 필드를 더한다**

`src/respec/llm_service/dspy_service.py` 의 `MacroRequest` 에서 `zone_unfinished_total`
줄 **바로 아래**에 넣는다:

```python
    # ---- battery 적재/함대 상태 (2026-08-31, S1/T2) ------------------------------------
    # 🔴 왜. 2026-08-30 실측: battery_mild 사건의 프롬프트에 payload 질량이 한 글자도 없어
    #    "낮은 SoC 로봇이 무거운 짐을 맡으면 SoC 가 더 빨리 떨어진다"는 추론이 원리적으로
    #    불가능했다. 여기 있는 것은 전부 **사실**이고 판정은 하나도 없다.
    # ⚠️ 다섯이 함께 오지 않는다: 배터리 레이어가 꺼져 있으면 SoC 셋이 빠지고, 그 로봇에
    #    미완 운반 작업이 없으면 payload 둘이 빠진다. `_battery_block` 이 키마다 거른다.
    battery_pending_transports: Optional[int] = None    # 이 로봇이 아직 맡고 있는 운반 작업 수
    battery_payload_max_kg: Optional[float] = None      # 그중 가장 무거운 화물의 질량
    battery_payload_total_kg: Optional[float] = None    # 그 작업들의 화물 질량 합
    battery_fleet_soc_median: Optional[float] = None    # 함대 SoC 의 중앙값
    battery_higher_soc_robots: Optional[int] = None     # 이 로봇보다 SoC 가 높은 활성 로봇 수
```

- [ ] **Step 4: `_battery_block` 을 쓴다**

`_zones_block` 정의 **바로 아래**에 넣는다:

```python
# ---- 2026-08-31 (S1/T2): battery 사건의 적재/함대 사실 블록 ---------------------------------
# 규약은 위 `_zones_block` 과 **정확히 같다** — 조건이 아니면 빈 문자열을 낸다. 그래야
# 비-battery 사건(과 이 필드를 안 싣는 옛 호출자)의 프롬프트가 바이트 단위로 예전과 같다.
#
# 🔴 **사실만 적는다.** "더 높은 SoC 로봇에게 넘겨라" 로 번역하지 않는다 — 그것은 오라클의
#    판정이고, 적는 순간 재는 것이 추론이 아니라 프롬프트 준수가 된다(spec §6-2). 같은 이유로
#    `_GEOM_COVERAGE` 도 `covers_root` 를 "빌드를 옮겨라" 로 안 적는다.
_BAT_LOAD = [
    ("battery_pending_transports", "pending_transports",
     "unfinished transport jobs this robot is committed to"),
    ("battery_payload_max_kg", "heaviest_payload_kg",
     "mass of the heaviest cargo among them"),
    ("battery_payload_total_kg", "total_payload_kg",
     "sum of cargo mass over those jobs"),
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
```

⚠️ `_rows(r, spec)` 는 이미 있는 헬퍼다(`[(lbl, getattr(r, f), doc) for f, lbl, doc in spec
if getattr(r, f, None) is not None]`) — `None` 을 자동으로 거른다.

🔴 **`soc` 를 `_BAT_FLEET` 에 넣으면 안 된다.** battery 사건에는 그 필드가 언제나 실려 있어서
`fleet` 이 절대 비지 않고, 그러면 `test_the_block_is_empty_when_no_value_is_shipped` 가
정당하게 빨개진다(빈 문자열 규약이 깨진다). 위 구현은 그것을 피하려고 `soc` 를 **함대 절이
실제로 생길 때만** 머리 줄로 붙인다.

- [ ] **Step 5: `_llm_input` 의 두 반환 경로 모두에 붙인다**

```python
    if not (r.nl and r.nl.strip()):
        return (_state_line(r) + _geometry_block(r) + _zones_block(r)
                + _battery_block(r) + _unfamiliar_block(r))
    ...
    return ("\n".join(lines) + _geometry_block(r) + _zones_block(r)
            + _battery_block(r) + _unfamiliar_block(r))
```

`_llm_input` 의 docstring 에서 블록 함수를 열거하는 문장에 `_battery_block` 을 더한다.

- [ ] **Step 6: 파이썬 게이트가 통과하는지 확인한다**

```bash
.venv/bin/python -m pytest src/respec/llm_service/test_battery_block.py -q
```

기대: `5 passed`.

- [ ] **Step 7: 🔴 음성 대조 — 한쪽 경로만 붙여 본다**

`_llm_input` 의 **첫 번째** `return` 에서 `+ _battery_block(r)` 를 지우고 돌린다.

```bash
.venv/bin/python -m pytest src/respec/llm_service/test_battery_block.py -q 2>&1 | tail -5
```

기대: `test_the_block_reaches_both_llm_input_paths` 가 **빨갛다**. 확인했으면 되돌린다.

- [ ] **Step 8: 줄리아 피처의 실패하는 게이트를 쓴다**

Create `test/battery_load_features.jl`:

```julia
# =============================================================================
# **battery 사건이 payload/함대 사실을 싣는가.** (2026-08-31, S1/T2)
#
# 이 게이트는 세계를 짓지 않는다 — `_battery_load_features` 는 `(env, agent)` 만 보는
# 함수이므로 최소 fixture 로 잰다. 진짜 빌드에서의 값은 T5 의 보드가 낸다.
#
# 변이시험
#   · `_payload_mass` 호출을 상수 `0.0` 으로 바꾸면 (2)가 빨개진다.
#   · `succ isa CB.FormTransportUnit` 필터를 지우면 (1)의 개수가 늘어 빨개진다.
#   · `count(>(mine), socs)` 를 `count(<(mine), socs)` 로 바꾸면 (3)이 빨개진다.
#
# 실행: julia +lts --project=. test/battery_load_features.jl
# =============================================================================
module BatteryLoadFeatures

using Test
using ConstructionBots
const CB = ConstructionBots
const REPO = normpath(joinpath(@__DIR__, ".."))
isdefined(CB, :BatteryFleet) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))
include(joinpath(REPO, "tools", "monitor", "policy.jl"))

@testset "(3) 함대 SoC 통계는 fleet 에서 유도된다" begin
    # `_battery_load_features` 의 함대 절만 잰다 — env 없이 fleet 전역만 세운다.
    p = CB.BatteryParams()
    fleet = CB.BatteryFleet(p, Dict{Any,Float64}(), Dict{Any,Float64}(),
                            Dict{Any,Int}(), Set{Any}())
    ids = [CB.RobotID(i) for i in 1:5]
    for (i, id) in enumerate(ids)
        fleet.soc[id] = [0.20, 0.55, 0.80, 0.90, 0.95][i]
    end
    old = CB.BATTERY_FLEET[]
    try
        CB.BATTERY_FLEET[] = fleet
        d = _battery_fleet_features(ids[2])          # soc = 0.55
        @test d["battery_fleet_soc_median"] === 0.80
        @test d["battery_higher_soc_robots"] === 3   # 0.80 · 0.90 · 0.95
    finally
        CB.BATTERY_FLEET[] = old
    end
end

@testset "(4) 배터리 레이어가 꺼져 있으면 SoC 셋이 안 실린다" begin
    old = CB.BATTERY_FLEET[]
    try
        CB.BATTERY_FLEET[] = nothing
        d = _battery_fleet_features(CB.RobotID(1))
        @test isempty(d)                             # 🔴 0 으로 접지 않는다 — 아예 안 싣는다
    finally
        CB.BATTERY_FLEET[] = old
    end
end

end # module
```

⚠️ (1)·(2)(운반 작업 순회)는 진짜 `env` 가 필요하므로 이 파일에서 재지 않는다. **그 사실을
파일 머리말에 적는다** — "여기 없는 것"을 안 적으면 다음 사람이 이 초록을 레인 건강의 증거로
읽는다. 그 두 명제는 T5 의 보드가 `battery_payload_max_kg` 를 실제로 싣는지로 확인한다.

- [ ] **Step 9: 실패를 확인한다**

```bash
julia +lts --project=. test/battery_load_features.jl
```

기대: `UndefVarError: _battery_fleet_features not defined`.

- [ ] **Step 10: 줄리아 피처를 구현한다**

`tools/monitor/policy.jl` 의 `_agent_pending` 정의 **바로 아래**에 두 함수를 넣는다:

```julia
# 함대 SoC 통계만. 세계를 안 보므로 단위검사가 된다(`test/battery_load_features.jl`).
# 🔴 배터리 레이어가 꺼져 있으면 **빈 Dict** 다 — 0 으로 접지 않는다. "재 봤더니 0" 과
#    "안 쟀다" 는 다른 사건이고, 0 을 실으면 프롬프트가 모델에게 거짓말을 한다.
function _battery_fleet_features(agent)
    d = Dict{String,Any}()
    local fleet = try CB.BATTERY_FLEET[] catch; nothing end
    (fleet === nothing || isempty(fleet.soc)) && return d
    local socs = collect(Float64, values(fleet.soc))
    local s = sort(socs); local n = length(s)
    d["battery_fleet_soc_median"] = isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2
    local mine = get(fleet.soc, agent, nothing)
    mine === nothing || (d["battery_higher_soc_robots"] = count(>(Float64(mine)), socs))
    return d
end

# 이 로봇이 아직 맡고 있는 운반 작업의 화물 질량. 순회는 `_agent_pending` 과 **같다** —
# 그 함수가 이미 "미완 RobotGo 중 후속이 FormTransportUnit 인 것"을 세므로, 여기서는 같은
# 후속 노드에 `_payload_mass` 를 걸기만 한다(추가 계산 없음).
# 🔴 `_payload_mass` 의 가드가 받는 셋 중 하나가 `FormTransportUnit` 이다 — 그래서 후속
#    노드를 넘긴다. `RobotGo` 를 넘기면 가드에 걸려 조용히 0.0 이 된다.
function _battery_load_features(env, agent)
    d = Dict{String,Any}()
    agent === nothing && return merge(d, _battery_fleet_features(agent))
    local sched = env.sched
    local p = CB.BatteryParams()
    local masses = Float64[]
    for v in Graphs.vertices(sched)
        local node = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        (node isa CB.RobotGo && CB.bound_to_agent(node, agent)) || continue
        v in env.cache.closed_set && continue
        local outs = Graphs.outneighbors(sched, v); isempty(outs) && continue
        local succ = CB.get_node_from_id(sched, CB.get_vtx_id(sched, outs[1]))
        succ isa CB.FormTransportUnit || continue
        push!(masses, try Float64(CB._payload_mass(env, succ, p)) catch; 0.0 end)
    end
    if !isempty(masses)
        d["battery_pending_transports"] = length(masses)
        d["battery_payload_max_kg"]     = maximum(masses)
        d["battery_payload_total_kg"]   = sum(masses)
    end
    return merge(d, _battery_fleet_features(agent))
end
```

`ood_features` 의 battery 분기에 한 줄을 더한다:

```julia
    if truth isa CB.BatteryTruth
        d["soc"] = Float64(truth.soc_after); d["severity"] = Float64(truth.soc_after)
        # 2026-08-31 (S1/T2): 적재/함대 사실. 값이 없으면 키가 아예 안 생긴다.
        merge!(d, _battery_load_features(env, agent))
```

- [ ] **Step 11: 줄리아 게이트가 통과하는지 확인한다**

```bash
julia +lts --project=. test/battery_load_features.jl
```

기대: 2 testset PASS.

- [ ] **Step 12: 게이트를 스위트에 등재하고 전체를 돌린다**

`test/runtests.jl` 의 `@testset "zone harm is blockage"` 블록 **바로 아래**:

```julia
    # 2026-08-31 (S1/T2): battery 사건이 payload/함대 사실을 싣는가. 🔴 이 게이트는 함대 절만
    # 잰다 — 운반 작업 순회는 진짜 env 가 필요하므로 여기 없다(파일 머리말이 그 경계를 적는다).
    @testset "battery load features" begin
        include("battery_load_features.jl")
    end
```

```bash
julia +lts --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3
.venv/bin/python -m pytest src/respec/llm_service/ --ignore=src/respec/llm_service/test_propose.py -q 2>&1 | tail -2
```

기대: `fail == 0 && error == 1`, 파이썬 `199 passed, 5 skipped`(194 + 새 5).

- [ ] **Step 13: 커밋**

```bash
git add tools/monitor/policy.jl src/respec/llm_service/dspy_service.py \
        src/respec/llm_service/test_battery_block.py \
        test/battery_load_features.jl test/runtests.jl
git commit -m "T2: battery 사건에 payload/함대 사실 블록을 신설한다

2026-08-30 실측: battery_mild 프롬프트에 payload 질량이 한 글자도 없어
'낮은 SoC 로봇이 무거운 짐을 맡으면 안 된다'는 추론이 원리적으로 불가능했다.
모델은 '55%면 충분'이라고 답했고 6/6 행이 expressible=True 였다.

_zones_block 과 같은 관용구다 — 값이 없으면 빈 문자열이라 비-battery 사건의
프롬프트가 바이트 동일. 사실만 싣고 판정은 안 싣는다(게이트가 매크로 이름과
지시어를 금지한다). 순회는 _agent_pending 과 같아 추가 계산이 없다."
```

---

## Task 3: SoC 임계 사다리를 정합적으로 다시 잡는다

🔴 **이 태스크가 여섯 상수를 동시에 옮긴다.** 하나만 옮기면 게이트가 정당하게 빨개진다.

**Files:**
- Modify: `src/navigator/ood_truth.jl` (symbol: `REPLACE_SOC_THRESHOLD`, 신설 `STALL_SOC_DEFAULT`)
- Modify: `tools/monitor/run_demo.jl` (symbol: `DEMO_BSOC`, `set_battery_stall!` 호출)
- Modify: `tools/monitor/render_demo.jl` (같은 두 지점)
- Modify: `wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl` (`DS_BSOC` · `DS_STALL` 기본값)
- Modify: `wm4spacecraft_manufacturing/core/reference_policy.py` (symbol: `BATTERY_DEEP_SOC`)
- Modify: `tools/monitor/lane_select.jl` (주석의 `DEMO_BSOC=0.9` 인용 갱신)
- Create: `test/soc_ladder_is_coherent.jl`
- Modify: `test/runtests.jl`

**Interfaces:**
- Consumes: `routing_kind(type_name, severity)` (T0 이 커밋한 심볼) ·
  `ActionRegistry.battery_arms(soc, thr, split)`.
- Produces: `CB.STALL_SOC_DEFAULT :: Ref{Float64}` (= 0.05). `run_demo.jl`·`render_demo.jl`
  의 `DEMO_STALL_SOC` 기본값이 이것에서 나온다.

- [ ] **Step 1: 실패하는 교차 게이트를 쓴다**

Create `test/soc_ladder_is_coherent.jl`:

```julia
# =============================================================================
# **SoC 임계 넷이 하나의 사다리인가.** (2026-08-31, S1/T3)
#
# 왜 이 파일이 필요한가 — 2026-08-31 실측
# ----------------------------------------
# 임계 셋이 갈라져 (0.1, 0.2] 구간이 조용히 죽어 있었다: 그 구간은 `routing_kind` 가
# `unknown:battery_mild`(LLM 레인)를 내면서 `battery_arms` 는 개입 팔 셋을 다 준다 —
# 즉 그 구간에서 합성 레인은 구조적으로 절대 발화하지 않는다.
# 🔴 그리고 두 임계를 **함께 보는 게이트가 레포에 0개였다**: `test_lane_select.jl` 은
# REPLACE_SOC_THRESHOLD/battery_arms 를 0회 언급하고, 그 시절의 `test/mild_menu_is_noop_only.jl`
# 은 ROUTING_SEVERE_SOC/routing_kind 를 0회 언급했다(이 파일이 생기던 당시 실측 — 그 파일은
# 2026-08-31 뒤이은 정리로 지워졌다). 이 파일이 그 사이를 잇는다.
#
# 재는 명제 다섯
#   (1) 라우팅 경계와 메뉴 경계가 **같다** — 사다리 전 구간에서 두 판정이 일치한다
#   (2) 정지 임계가 deep 경계보다 **엄격히 낮다**
#       (같으면 deep 안에 감속 구간이 없어져 battery_ladder_is_deep_only 단언 2 가
#        만족 불가능해진다 — D-6 이 그래서 폐기됐다)
#   (3) severe 데모 프리셋이 **정지 임계 아래로 확실히 떨어진다**
#       soc_after <= 1 - DEMO_BSOC 이므로 (1 - DEMO_BSOC) <= stall 이면 충분하다
#   (4) 두 엔진(run_demo · render_demo)의 DEMO_BSOC·DEMO_STALL_SOC 기본값이 같다
#   (5) 라벨 레인의 DS_STALL 이 실행 레인의 정지 임계와 같다
#
# 변이시험
#   · ROUTING_SEVERE_SOC 만 0.2 로 되돌리면 (1)이 빨개진다.
#   · STALL_SOC_DEFAULT 를 REPLACE_SOC_THRESHOLD 와 같게 두면 (2)가 빨개진다.
#   · DEMO_BSOC 기본값을 0.9 로 되돌리면 (3)이 빨개진다(1-0.9=0.10 > 0.05).
#   · 두 엔진 중 하나만 고치면 (4)가 빨개진다.
#
# 🔴 **오늘의 HEAD 에 대고 돌리면 (1)(2)(3) 이 전부 빨갛다.** 그것이 이 게이트가 존재하는
#    이유이고, T3 이 그 셋을 초록으로 만든다.
#
# 실행: julia +lts --project=. test/soc_ladder_is_coherent.jl
# =============================================================================
module SocLadderIsCoherent

using Test
using ConstructionBots
const CB = ConstructionBots
const REPO = normpath(joinpath(@__DIR__, ".."))
isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))
isdefined(@__MODULE__, :ActionRegistry) ||
    include(joinpath(REPO, "wm4spacecraft_manufacturing", "oracle", "action_registry.jl"))
include(joinpath(REPO, "tools", "monitor", "lane_select.jl"))
const AR = ActionRegistry

const DEEP  = Float64(CB.REPLACE_SOC_THRESHOLD[])
const STALL = Float64(CB.STALL_SOC_DEFAULT[])

"소스에서 리터럴 기본값을 읽는다 — 숫자를 여기 박으면 두 번째 진실원이 된다."
function envdefault(path, name)
    src = read(joinpath(REPO, path), String)
    m = match(Regex("get\\(ENV,\\s*\"$(name)\",\\s*\"([^\"]*)\"\\)"), src)
    m === nothing && error("$(path) 에서 $(name) 기본값을 못 찾았다 — 정규식을 고칠 것")
    return m.captures[1]
end

@testset "(1) 라우팅 경계와 메뉴 경계가 같다" begin
    for s in (0.0, 0.02, 0.05, DEEP - 1e-9, DEEP, nextfloat(DEEP), 0.15, 0.2, 0.3, 0.45, 0.9)
        local severe_by_routing = routing_kind("BatteryTruth", s) == "battery"
        local severe_by_menu    = length(AR.battery_arms(s, DEEP, true)) > 1
        @test severe_by_routing == severe_by_menu
    end
end

@testset "(2) 정지 임계가 deep 보다 엄격히 낮다" begin
    @test STALL < DEEP
    # 그래야 deep 안에 "정지하는 칸"과 "감속만 하는 칸"이 둘 다 존재할 수 있다.
    @test AR.battery_arms(STALL, DEEP, true) == AR.battery_arms(DEEP, DEEP, true)
end

@testset "(3) severe 프리셋이 정지 임계 아래로 확실히 떨어진다" begin
    for f in ("tools/monitor/run_demo.jl", "tools/monitor/render_demo.jl")
        local drop = parse(Float64, envdefault(f, "DEMO_BSOC"))
        # soc_after = max(floor_soc=0.0, soc_at_fire - drop) <= 1.0 - drop
        @test (1.0 - drop) <= STALL
        @test (1.0 - drop) <= DEEP        # 라우팅도 severe 로 간다
    end
end

@testset "(4) 두 엔진의 배터리 기본값이 같다" begin
    for name in ("DEMO_BSOC", "DEMO_STALL_SOC")
        @test envdefault("tools/monitor/run_demo.jl", name) ==
              envdefault("tools/monitor/render_demo.jl", name)
    end
    @test parse(Float64, envdefault("tools/monitor/run_demo.jl", "DEMO_STALL_SOC")) === STALL
end

@testset "(5) 라벨 레인의 정지 임계가 실행 레인과 같다" begin
    local gen = "wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl"
    @test parse(Float64, envdefault(gen, "DS_STALL")) === STALL
    # 학습 사다리의 모든 칸이 새 경계에서도 비교 가능해야 한다(battery_ladder_is_deep_only
    # 단언 1 과 같은 명제를 새 경계에서 다시 확인한다 — 그 파일과 겹치는 것이 의도다).
    for s in [parse(Float64, x) for x in split(envdefault(gen, "DS_BSOC"), ",")]
        @test length(AR.battery_arms(s, DEEP, true)) > 1
    end
end

end # module
```

- [ ] **Step 2: 오늘의 HEAD 에 대고 돌려 빨간 것을 본다 (음성 대조)**

```bash
julia +lts --project=. test/soc_ladder_is_coherent.jl 2>&1 | tail -20
```

기대: `UndefVarError: STALL_SOC_DEFAULT` — 아직 없다. 임시로 `const STALL = 0.15` 를 박고
다시 돌리면 **(1)(2)(3) 이 빨갛다.** 그 출력을 보고 나서 되돌린다.
🔴 **이 확인을 건너뛰지 말 것** — 이 게이트가 실제 결함을 잡는다는 유일한 증거다.

- [ ] **Step 3: 줄리아 임계 둘을 옮긴다**

`src/navigator/ood_truth.jl` 에서:

```julia
# 배터리 사건의 깊은 방전 판정 SoC 경계값. 전역 조정 가능.
# 🔴 2026-08-31 (S1/T3): 0.2 -> 0.1. `tools/monitor/lane_select.jl` 의 라우팅 경계
#    `ROUTING_SEVERE_SOC` 와 **같은 값**이어야 한다. 갈라져 있던 동안 (0.1, 0.2] 구간이
#    LLM 레인으로 가면서 개입 팔을 다 갖는 죽은 밴드였다(합성이 구조적으로 발화 불가).
#    두 값이 갈리는 것은 `test/soc_ladder_is_coherent.jl` (1) 이 막는다.
const REPLACE_SOC_THRESHOLD = Ref(0.1)
"Set the SoC at/below which a battery event's canonical response flips soft→hard (Replace)."
set_replace_soc_threshold!(x::Real) = (REPLACE_SOC_THRESHOLD[] = Float64(x); nothing)

# 로봇이 물리적으로 멈추는 SoC 의 **기본값**. `DEMO_STALL_SOC`/`DS_STALL` 이 이 값을 쓴다.
# 🔴 `REPLACE_SOC_THRESHOLD` 에서 **유도하지 않는다.** 같게 두면 deep 구간 전체가 "정지"라
#    감속 구간이 사라지고, `test/battery_ladder_is_deep_only.jl` 단언 2(사다리가 정지 임계를
#    걸친다 — 2026-08-05 "심각도 축이 점 하나" 회귀 방지)를 만족하는 사다리가 **존재하지
#    않게 된다.** 그래서 별개의 상수이고, `stall < deep` 만 게이트가 강제한다.
const STALL_SOC_DEFAULT = Ref(0.05)
```

- [ ] **Step 4: 두 엔진의 기본값을 옮긴다**

`tools/monitor/run_demo.jl` 과 `tools/monitor/render_demo.jl` **양쪽 모두**에서:

```julia
const DEMO_BSOC = try clamp(parse(Float64, get(ENV, "DEMO_BSOC", "0.96")), 0.05, 0.99) catch; 0.96 end
```

그리고 `set_battery_stall!` 호출의 `threshold` 를:

```julia
    CB.set_battery_stall!(enabled = get(ENV, "DEMO_STALL", "1") == "1",
                          threshold = (try parse(Float64, get(ENV, "DEMO_STALL_SOC", "0.05")) catch; 0.05 end),
                          clear = true, obstacle = false)
```

⚠️ 리터럴 `"0.05"` 를 남기는 이유: `test/soc_ladder_is_coherent.jl (4)` 가 **소스를 정규식으로
읽어** `STALL_SOC_DEFAULT` 와 대조한다. 문자열 보간을 쓰면 그 파서가 못 읽고, 그러면
"두 엔진이 같은가"를 기계로 못 지킨다.

`run_demo.jl` 의 stall 주석에서 낡은 논증을 고친다:

```julia
#   · threshold 0.05 — 주입 OOD 의 결과 SoC 는 DEMO_BSOC=0.96 → ≈0.04 이므로 확실히 정지한다.
#     🔴 2026-08-31: 이 셋(0.05 / 0.96 / deep 0.1)은 함께 움직인다. 하나만 고치면
#     test/soc_ladder_is_coherent.jl 이 빨개진다.
```

- [ ] **Step 5: 라벨 레인의 두 기본값을 옮긴다**

`wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl`:

```julia
            threshold = parse(Float64, get(ENV, "DS_STALL", "0.05")), clear = true, obstacle = false)
```

```julia
            for s in [parse(Float64, x) for x in split(get(ENV, "DS_BSOC", "0.02,0.09"), ",")]
```

그리고 그 위 주석 블록의 낡은 사다리 서술을 고친다:

```julia
#  [2026-08-31 경계 이동] deep 경계가 0.2 -> 0.1 로 내려가면서 옛 사다리 "0.02,0.18" 의
#  0.18 칸이 mild(= ["NOOP"], 대조가 0인 행)로 넘어갔다. 새 사다리(DS_BSOC = 0.02 / 0.09):
#      0.02  < DS_STALL(0.05)        -> 즉시 정지          (개입 필요)
#      0.09  in (0.05, deep 0.1]     -> 감속·계속 일함      (개입은 선택)
#  🔴 이전 주석은 "기본 = 0.02 / 0.3 / 0.5" 라고 적었으나 그때 이미 코드는 "0.02,0.18"
#  이었다 — 낡은 주석이었다. 이 값을 인용하기 전에 코드를 볼 것.
```

- [ ] **Step 6: 파이썬 twin 상수를 옮긴다**

`wm4spacecraft_manufacturing/core/reference_policy.py`:

```python
BATTERY_DEEP_SOC = 0.1      # Julia ood_truth.jl 의 REPLACE_SOC_THRESHOLD 와 통일(2026-08-31,
                            # 심볼로 파싱해 대조: core/test_soc_threshold_agrees.py)
```

- [ ] **Step 7: `lane_select.jl` 의 낡은 인용을 고친다**

`ROUTING_SEVERE_SOC` 주석에서 `DEMO_BSOC=0.9` · `1.0 - 0.9 = 0.099…` 를 인용하는 두 곳을
갱신한다:

```julia
# 🔴 값의 근거는 **"SoC 가 90% 깎였는가"** 다. 그 정의는 그대로이고, 2026-08-31 부터 데모의
#    severe 프리셋은 `DEMO_BSOC=0.96` 으로 그 경계보다 **더 깊다**(soc_after ≈ 0.04).
#    옛 프리셋(0.9)은 soc_after 가 0.0994 라 경계 여유가 6e-4 였고, 정지 임계가 0.05 로
#    내려가면서 "확실히 정지한다"는 논증이 깨졌다 — 그래서 프리셋을 같이 옮겼다.
#    이 셋의 정합성은 `test/soc_ladder_is_coherent.jl` 이 지킨다.
```

- [ ] **Step 8: 교차 게이트가 통과하는지 확인한다**

```bash
julia +lts --project=. test/soc_ladder_is_coherent.jl
```

기대: 5 testset 전부 PASS.

- [ ] **Step 9: 기존 임계 게이트 셋이 여전히 초록인지 확인한다**

```bash
julia +lts --project=. test/battery_ladder_is_deep_only.jl
julia +lts --project=. test/battery_menu_lanes_agree.jl
.venv/bin/python -m pytest wm4spacecraft_manufacturing/core/test_soc_threshold_agrees.py -q
```

기대: 전부 PASS. 🔴 **2026-08-31 뒤이은 정리로 `test/mild_menu_is_noop_only.jl` 은 지워졌다**
(mild 가 NOOP-only 라는 (1)(2)(3) 을 사용자가 의도적으로 뒤집을 예정이라 그 게이트가 앞길을
막았다) — 명제 (4)("미기록 soc 는 메뉴를 안 좁힌다")만 `battery_menu_lanes_agree.jl` 로 옮겨
살아 있다. 이 커맨드 목록에서 그 파일을 빼는 것이 그 삭제의 귀결이다.

- [ ] **Step 10: 🔴 severe 데모가 실제로 정지하는지 확인한다 (유료 0건)**

```bash
DEMO_MODEL=tractor.mpd DEMO_OOD=battery DEMO_POLICY=noop DEMO_ROUTER=0 \
  julia +lts --project=. tools/monitor/run_demo.jl 2>&1 | tr '\r' '\n' \
  | grep -E "n_stalled|\[ood\] battery|soc_after|PROJECT" | head
```

기대: `n_stalled` 가 **1 이상**. 🔴 `n_stalled == 0` 이면 severe 로봇이 안 멈춘 것이고,
NL 은 여전히 "stopped where it stands" 라고 말하므로 **NL 과 화면이 어긋난다** —
그러면 `DEMO_BSOC` 를 더 올리고 (3) 게이트와 함께 다시 잰다.

⚠️ `n_stalled` 가 정지의 **유일한 기계적 증거**다. `run_demo.jl` 이 `global_logger` 를
`Logging.Warn` 으로 심어 `[STALL]`(`@info`)이 통째로 버려진다 — **"로그에 없다"를 "안 났다"로
읽지 말 것.**

- [ ] **Step 11: 게이트 등재 + 전체 스위트**

`test/runtests.jl` 의 `@testset "battery ladder is deep-only"` **바로 앞**:

```julia
    # 2026-08-31 (S1/T3): 라우팅 경계·메뉴 경계·정지 임계·두 엔진 기본값·라벨 레인이 하나의
    # 사다리인가. 🔴 이 게이트가 없던 동안 (0.1, 0.2] 구간이 죽어 있었다 — LLM 레인으로
    # 가면서 개입 팔을 다 갖는 구간이라 합성이 구조적으로 발화 불가였다.
    @testset "SoC ladder is coherent" begin
        include("soc_ladder_is_coherent.jl")
    end
```

```bash
julia +lts --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3
.venv/bin/python -m pytest wm4spacecraft_manufacturing/core/ -q 2>&1 | tail -2
```

기대: `fail == 0 && error == 1`.

- [ ] **Step 12: 커밋**

```bash
git add src/navigator/ood_truth.jl tools/monitor/run_demo.jl tools/monitor/render_demo.jl \
        tools/monitor/lane_select.jl \
        wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl \
        wm4spacecraft_manufacturing/core/reference_policy.py \
        test/soc_ladder_is_coherent.jl test/runtests.jl
git commit -m "T3: SoC 임계 여섯 상수를 하나의 사다리로 다시 잡는다

deep/메뉴 0.2 -> 0.1 (라우팅 경계와 통일), stall 0.15 -> 0.05,
DS_BSOC \"0.02,0.18\" -> \"0.02,0.09\", DEMO_BSOC 0.9 -> 0.96.

연쇄의 근거: 경계를 0.1 로 내리면 학습 칸 0.18 이 [\"NOOP\"] 이 되어 라벨
레인이 대조가 0인 행을 만든다. stall==deep 은 deep 안에 감속 구간을 없애
battery_ladder_is_deep_only 단언 2 를 만족 불가능하게 만든다. 그리고
stall 0.05 에서는 옛 severe 프리셋(soc_after 0.0994)이 안 멈춘다.

신설 게이트가 다섯을 함께 본다 — 이 축을 함께 보는 게이트가 레포에 0개였다.
재라벨은 하지 않는다: 저장된 셋은 이미 다른 세대다(battery_physics 도장이
stall=false, derate=false)."
```

---

## Task 4: 결정 시점의 후보 간선 상계를 비개입으로 잰다

S2(결정 시점 payload 재가격)의 전제조건이다. 후보 간선이 0이면 `edge_costs` 가 비고
목적식이 **순수 makespan 으로 후퇴**하므로(`get_objective_expr` 의 `isempty(edge_costs)`
조기 반환), 어떤 배수도 목적식에 못 닿는다.

**Files:**
- Modify: `tools/monitor/policy.jl` (신설 `candidate_slot_upper_bound`, `decide_all` 에서 호출)
- Create: `test/milp_slot_probe_is_pure.jl`
- Modify: `test/runtests.jl`

**Interfaces:**
- Consumes: `CB.preprocess_project_schedule(sched)` — **`sched` 만의 순수 함수**이고
  8-튜플을 낸다. 3번째가 `n_eligible_successors::Vector{Int}` 다.
- Produces: `candidate_slot_upper_bound(env) -> Union{Nothing,Int}`.
  `nothing` = 못 쟀다. `decide_all` 이 매 결정에 `[milp-probe]` 줄을 찍는다.

- [ ] **Step 1: 실패하는 게이트를 쓴다**

Create `test/milp_slot_probe_is_pure.jl`:

```julia
# =============================================================================
# **후보 간선 상계 프로브가 세계를 안 건드리는가.** (2026-08-31, S1/T4)
#
# 무엇을 재는가 — 그리고 무엇을 안 재는가
# ----------------------------------------
# 이 프로브는 Big-M 후보 루프의 **외곽 게이트**(`outdegree(v) < n_eligible_successors[v]`)
# 만 센다. 그것은 후보 (v,v2) 쌍의 **상계**다:
#   · 0 이면 후보 간선이 **증명 가능하게 0** — S2 의 "재가격 단독" 경로는 죽는다.
#   · >0 이면 결론을 못 낸다. 정확한 카운트는 S2 의 몫이다.
# 🔴 상계만 재는 이유는 두 벌 방지다. 정확히 세려면 Big-M 루프의 3중 조건을 복제해야 하고,
#    안 갈리게 하려면 hot loop 를 수술해야 한다 — S1 범위 밖이다.
#
# 🔴 이 값은 **"MILP 가 돌았는가"를 주장하지 않는다.** 그건 `enact.jl` 의 센티넬
#    (`ran_milp = !(LAST_EDGE_COSTS[] === _sent)`)의 몫이고 다른 관측이다.
#
# 재는 명제 셋
#   (1) `preprocess_project_schedule` 이 정말 `sched` 만의 순수 함수다 — 두 번 불러도
#       n_eligible_successors 가 같고 스케줄 지문이 안 변한다
#   (2) 프로브 전후 env 지문(nv · ne · closed 수)이 같다
#   (3) 못 쟀으면 `nothing` 이다 — 🔴 `0` 이 아니다(삼상 규약: "후보 0" 과 "못 쟀다"를
#       같은 값으로 만들면 그 판별이 영원히 사라진다)
#
# 변이시험
#   · `candidate_slot_upper_bound` 의 `try ... catch; nothing end` 를 `catch; 0 end` 로
#     바꾸면 (3)이 빨개진다.
#   · 프로브 안에서 `sched` 를 변경하는 줄을 넣으면 (2)가 빨개진다.
#
# 실행: julia +lts --project=. test/milp_slot_probe_is_pure.jl
# =============================================================================
module MilpSlotProbeIsPure

using Test
using ConstructionBots
const CB = ConstructionBots
const REPO = normpath(joinpath(@__DIR__, ".."))
isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))
include(joinpath(REPO, "tools", "monitor", "policy.jl"))

@testset "(3) 못 쟀으면 nothing 이지 0 이 아니다" begin
    # `env` 가 스케줄을 안 가진 물건이면 프로브는 던지지 않고 `nothing` 을 낸다.
    @test candidate_slot_upper_bound((sched = nothing,)) === nothing
    @test candidate_slot_upper_bound(nothing) === nothing
    # 🔴 `0` 으로 접히면 안 된다 — 그러면 "후보 0"(S2 를 죽이는 관측)과 "못 쟀다"가
    #    같은 값이 되어 판별이 사라진다.
    @test candidate_slot_upper_bound(nothing) !== 0
end

end # module
```

⚠️ (1)(2)는 진짜 `env` 가 필요하므로 이 파일에서 재지 않는다 — **그 경계를 머리말에 적었다.**
두 명제는 T5 의 보드가 `[milp-probe]` 줄을 찍고 그 판이 정상 완주하는 것으로 확인한다.

- [ ] **Step 2: 실패를 확인한다**

```bash
julia +lts --project=. test/milp_slot_probe_is_pure.jl
```

기대: `UndefVarError: candidate_slot_upper_bound not defined`.

- [ ] **Step 3: 프로브를 구현한다**

`tools/monitor/policy.jl` 의 `_zone_overlap` 정의 **바로 위**에 넣는다:

```julia
"""
    candidate_slot_upper_bound(env) -> Union{Nothing,Int}

결정 시점에 **배정 슬롯이 몇 개나 비어 있는가**의 상계. `nothing` 은 "못 쟀다"다.

🔴 왜 상계인가. `formulate_milp` 의 Big-M 루프는 세 조건을 모두 만족하는 `(v, v2)` 쌍에만
`edge_costs` 를 채우는데, 그 첫 조건이 `outdegree(sched, v) < n_eligible_successors[v]` 다.
여기서는 **그 조건만** 센다 — 나머지 둘(선행 여유 · 템플릿 매치)을 복제하면 hot loop 의
판정식이 두 벌이 되고, 이 레포는 그런 두 벌이 조용히 갈리는 사고를 반복해 겪었다.
⟹ **0 이면 후보 간선이 증명 가능하게 0 이고, >0 이면 아무 결론도 안 준다.**

🔴 왜 이 값이 중요한가. `edge_costs` 가 비면 `get_objective_expr` 이 조기 반환해 목적식이
**순수 makespan 으로 후퇴한다.** 그러면 `EDGE_COST_MULTIPLIER` 든 payload 든 어떤 배수도
목적식에 닿지 못한다 — 결정 시점 재가격이 원리적으로 무효가 된다.

🔴 이 값은 **"MILP 가 돌았는가"를 주장하지 않는다.** 그건 `enact.jl` 의 센티넬이 잰다.
두 관측을 한 숫자로 섞지 말 것.

**순수하다** — `preprocess_project_schedule` 은 `sched` 만 읽고 아무것도 안 바꾼다.
"""
function candidate_slot_upper_bound(env)
    local sched = try env.sched catch; nothing end
    sched === nothing && return nothing
    return try
        local pp = CB.preprocess_project_schedule(sched)
        local nes = pp[3]                      # n_eligible_successors (8-튜플의 3번째)
        count(v -> Graphs.outdegree(sched, v) < nes[v], Graphs.vertices(sched))
    catch
        nothing                                # 🔴 0 이 아니다 — 삼상 규약
    end
end
```

`decide_all` 의 본문 첫 줄(`canon = canonical_macro(env, truth)`) **바로 앞**에 넣는다:

```julia
    # ---- 후보 간선 상계 프로브 (2026-08-31, S1/T4) -----------------------------------------
    # S2(결정 시점 payload 재가격)의 전제조건을 결정 시점에 **비개입으로** 잰다.
    # 🔴 "못 쟀다"를 0 으로 찍지 않는다 — 그러면 "후보 0"(재가격이 원리적으로 무효라는 관측)과
    #    구별이 안 된다.
    local _slots = candidate_slot_upper_bound(env)
    println("[milp-probe] slots_upper_bound=", _slots === nothing ? "n/a" : string(_slots),
            " measured_at_closed=", (try string(length(env.cache.closed_set)) catch; "n/a" end))
```

- [ ] **Step 4: 게이트가 통과하는지 확인한다**

```bash
julia +lts --project=. test/milp_slot_probe_is_pure.jl
```

기대: 1 testset PASS.

- [ ] **Step 5: 🔴 음성 대조**

`catch; nothing end` 를 `catch; 0 end` 로 바꾸고 다시 돌린다. (3)이 빨간 것을 확인하고 되돌린다.

- [ ] **Step 6: 게이트 등재 + 전체 스위트 + 커밋**

`test/runtests.jl` 의 `@testset "SoC ladder is coherent"` **바로 아래**:

```julia
    # 2026-08-31 (S1/T4): 결정 시점 후보 간선 상계 프로브가 세계를 안 건드리는가.
    # 🔴 이 프로브는 상계만 낸다 — 0 이면 결론이고 >0 이면 아무 결론도 아니다(파일 머리말).
    @testset "MILP slot probe is pure" begin
        include("milp_slot_probe_is_pure.jl")
    end
```

```bash
julia +lts --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3
git add tools/monitor/policy.jl test/milp_slot_probe_is_pure.jl test/runtests.jl
git commit -m "T4: 결정 시점 후보 간선 상계를 비개입으로 잰다

preprocess_project_schedule 은 sched 만의 순수 함수이므로 solve 없이 읽힌다 —
2026-08-30 마감 보고서 §6-4 ①이 이것을 '닭과 달걀'이라 적었으나 그렇지 않다.

외곽 게이트만 세어 **상계**를 낸다: 0 이면 후보 간선이 증명 가능하게 0(= S2 의
재가격 단독 경로가 죽는다), >0 이면 아무 결론도 아니다. 정확한 카운트는 Big-M
루프의 3중 조건 복제를 요구하고, 그 두 벌은 조용히 갈린다."
```

---

## Task 5: 유료 검증 — 프로브 격리 후 보드 2판

🔴 **예산 4건, 상한 6건.** 각 호출 전에 서비스 세대를 확인한다.

**Files:**
- Create: `results/2026-08-31-s1/` (판별 산출물)

**Interfaces:**
- Consumes: T1~T4 가 배선한 전부.
- Produces: `results/2026-08-31-s1/{zone_probe.json, zone_board.log, mild_board.log}` —
  T6 보고서가 읽는다.

- [ ] **Step 1: 🔴 서비스 세대를 확인한다 (유료 0건)**

```bash
ps -eo pid,lstart,cmd | grep "[p]ort 8077"
git log -1 --format='%h %cd' -- src/respec/llm_service/dspy_service.py
```

기대: 프로세스 기동 시각이 마지막 커밋 시각 **뒤**. 아니면 **남의 프로세스를 건드리지 말고**
빈 포트에 새로 띄워 `DSPY_URL` 로 가리킨다:

```bash
(cd src/respec/llm_service && TOOL_SYNTHESIS=1 .venv/bin/python -m uvicorn dspy_service:app --port 8091 &)
export DSPY_URL=http://127.0.0.1:8091
curl -s $DSPY_URL/health | head -c 400
```

빠른 세대 판별: `/health` 에 `surro_support` 필드가 있으면 신 코드.

- [ ] **Step 2: zone 프로브 — 새 서술자 단독 효과 (유료 1건)**

저장된 스트림에서 `/macro` **요청 본문**을 재구성하고 서술자만 새 공식으로 갈아끼운다.
물리를 안 건드리므로 서술자 효과가 격리된다.

```bash
mkdir -p results/2026-08-31-s1
.venv/bin/python - <<'PY' > results/2026-08-31-s1/zone_probe.json
import json, os, urllib.request
url = os.environ.get("DSPY_URL", "http://127.0.0.1:8077") + "/macro"
# 2026-08-30 zone_minted 보드의 실제 값 (streams/tractor__zone_minted.jsonl 에서 읽음)
NBLK, NDOWN, TOTAL, CLOSED, ZOV = 3, 32, 305, 54, 0.002356843670973429
pending = TOTAL - CLOSED
body = {
    "kind": "zone", "routing_kind": "unknown:zone",
    "severity": ZOV, "zone_overlap": ZOV, "zone_radius": 0.07,
    "spare_count": 8, "progress": 0.177, "n_active": 18,
    "closed_at_fire": CLOSED, "total_nodes": TOTAL,
    "nl": "A no-go exclusion zone has appeared at (1.09, 0.42) with radius 0.07. "
          "Robots that enter the disc are pushed back out of it.",
    "zone_nav_goals": 131, "zone_nav_blocked": NBLK, "zone_nav_engulfed": 3,
    "zone_agent_trapped": 0, "zone_nav_downstream": NDOWN,
    "zone_unfinished_total": pending, "zone_blocked": 0, "zone_root_covered": 0,
    "zone_root_total": 8, "zone_work_overlap": 6, "zone_teams_forming": 7,
    "zone_teams_covered": 0,
    # 🔴 새 공식으로 계산한 값. harm=1.0(막힘 3개) · war=32/251
    "descriptors": [1.0, NDOWN / pending, 0.0, 0.31, 0.177, 0.6],
    "valid": ["NOOP"],
    "zones": [{"key": "zone_blk_1", "center": [1.09, 0.42], "radius": 0.07,
               "covers": [], "covers_root": False}],
}
req = urllib.request.Request(url, json.dumps(body).encode(),
                             {"Content-Type": "application/json"})
print(json.dumps(json.loads(urllib.request.urlopen(req).read()), indent=1, ensure_ascii=False))
PY
.venv/bin/python -c "
import json; d=json.load(open('results/2026-08-31-s1/zone_probe.json'))
for k in ('expressible','chosen','tool_called','tools_offered','tool_arg_error'): print(k,'=',d.get(k))
print('synthesis =', d.get('synthesis'))
print('---STATE---'); print(d.get('state'))
"
```

기대: `expressible = False`. 🔴 **`True` 면 멈추고 사용자에게 올린다** — 서술자를 고쳐도
안 뒤집혔다는 것이 S1 의 가장 값나가는 관측이고, 프롬프트로 뒤집으려 하지 않는다.
`state` 출력에서 `harm = 1.00` 과 `of which blocked = 3` 이 **함께** 보이는지 확인한다
(둘이 더 이상 모순되지 않는다는 것이 이 태스크의 요점이다).

- [ ] **Step 3: zone 보드 1판 (유료 1건)**

```bash
DEMO_MODEL=tractor.mpd DEMO_ZONE=1 DEMO_POLICY=router DEMO_ROUTER=auto \
DEMO_CASE_TAG=zone_s1 TOOL_SYNTHESIS=1 \
  julia +lts --project=. tools/monitor/render_demo.jl 2>&1 \
  | tee results/2026-08-31-s1/zone_board.log | tail -40
tr '\r' '\n' < results/2026-08-31-s1/zone_board.log \
  | grep -E "\[zone\]|\[router\]|\[policy\]|\[milp-probe\]|\[minted\]|PROJECT" | head -20
```

기대: `[milp-probe] slots_upper_bound=<n> measured_at_closed=<c>` 줄이 찍힌다(T4 의 첫 실측).
`[minted]` 줄의 `synthesis_event` 가 `True` 면 발화한 것이다.

- [ ] **Step 4: battery_mild 보드 1판 (유료 1건)**

```bash
DEMO_MODEL=tractor.mpd DEMO_OOD=battery DEMO_BSOC=0.45 DEMO_POLICY=router DEMO_ROUTER=auto \
DEMO_CASE_TAG=mild_s1 TOOL_SYNTHESIS=1 \
  julia +lts --project=. tools/monitor/render_demo.jl 2>&1 \
  | tee results/2026-08-31-s1/mild_board.log | tail -40
tr '\r' '\n' < results/2026-08-31-s1/mild_board.log \
  | grep -E "\[ood\]|\[router\]|\[policy\]|\[milp-probe\]|\[minted\]|n_stalled|PROJECT" | head -20
```

기대: `[router]` 가 `unknown:battery_mild` 로 간다.
🔴 프롬프트에 `heaviest_payload_kg` 가 실제 값으로 실렸는지 스트림에서 확인한다:

```bash
.venv/bin/python -c "
import json
rows=[json.loads(l) for l in open('tools/monitor/streams/tractor__mild_s1.jsonl')]
g=[d for d in rows if d.get('respec')]
print('결정행', len(g))
li=(g[0]['respec']['input'].get('router') or {}).get('llm_input','')
print('payload 블록 있음:', 'heaviest_payload_kg' in li)
print(li)
"
```

- [ ] **Step 5: (조건부) 판별 프로브 (유료 0–1건)**

Step 4 에서 `expressible` 이 **뒤집혔으면 이 단계를 건너뛴다.** 안 뒤집혔으면, 그 보드가
**실제로 실은** 값으로 `/macro` 를 한 번 더 던져 "값이 안 실린 것인가, 실렸는데 모델이
불충분하다고 본 것인가"를 가른다. 두 원인은 T6 의 결론을 정반대로 만든다.

```bash
.venv/bin/python - <<'PY' > results/2026-08-31-s1/mild_discriminating_probe.json
import json, os, urllib.request
rows = [json.loads(l) for l in open("tools/monitor/streams/tractor__mild_s1.jsonl")]
g = [d for d in rows if d.get("respec")]
assert g, "결정행이 없다 — 보드가 결정에 도달하지 못했다"
inp = g[0]["respec"]["input"]
rt = inp.get("router") or {}
li = rt.get("llm_input", "")
# 🔴 먼저 판별한다: 블록이 실렸는가.
print(json.dumps({"payload_block_present": "heaviest_payload_kg" in li,
                  "llm_input": li}, ensure_ascii=False, indent=1)[:200],
      file=__import__("sys").stderr)
# 실렸는데 True 였다면 = 모델의 판단이다. 그때만 아래를 돈다(같은 값을 다시 던져 재현 확인).
url = os.environ.get("DSPY_URL", "http://127.0.0.1:8077") + "/macro"
body = {k: v for k, v in inp.get("payload", {}).items()} if inp.get("payload") else None
assert body, "스트림에 요청 본문이 없다 — 이 프로브는 못 돈다. 그 사실을 T6 에 적을 것."
req = urllib.request.Request(url, json.dumps(body).encode(),
                             {"Content-Type": "application/json"})
print(json.dumps(json.loads(urllib.request.urlopen(req).read()), indent=1, ensure_ascii=False))
PY
```

🔴 **`payload_block_present` 가 `False` 면 유료 호출을 하지 말 것** — 배선 결함이고
T2 로 돌아가야 한다. 그때 유료 호출은 낭비다(2026-08-30 에 정확히 그 낭비가 1건 있었다).
⚠️ 스트림이 요청 본문을 영속하지 않으면 이 프로브는 못 돈다 — 그 경우 **그 사실 자체를**
T6 에 적고 넘어간다(없는 것을 지어내지 않는다).

- [ ] **Step 6: 유료 호출 수를 세고 커밋**

```bash
curl -s $DSPY_URL/health | .venv/bin/python -c "import json,sys; print('calls =', json.load(sys.stdin)['calls'])"
git add results/2026-08-31-s1/
git commit -m "T5: S1 라이브 검증 — zone 프로브 1건 + 보드 2판

프로브 격리는 zone 에만 가능하다(battery 의 payload 값은 새로 재는 값이라
저장된 스트림에 없다). 그 비대칭을 T6 보고서가 적는다."
```

---

## Task 6: 보고서 — 무엇의 증거가 **아닌가**

**Files:**
- Create: `docs/superpowers/reports/2026-08-31-s1-observation-and-thresholds.md`

- [ ] **Step 1: 착수·종료 실측을 재유도한다**

```bash
julia +lts --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3
.venv/bin/python -m pytest src/respec/llm_service/ --ignore=src/respec/llm_service/test_propose.py -q 2>&1 | tail -2
.venv/bin/python -m pytest wm4spacecraft_manufacturing/core/ -q 2>&1 | tail -2
git log --oneline "$(cat /tmp/s1_base_head.txt)"..HEAD          # T0 Step 2 가 적어 둔 착수 HEAD
```

- [ ] **Step 2: 보고서를 쓴다**

반드시 담을 절:

1. **착수·종료 두 스위트** — pass 델타를 태스크별로, **어느 게이트의 어느 단언이 그 델타를
   냈는지**까지. 설명 안 되는 델타가 있으면 그것을 먼저 조사한다.
2. **판 대조표** — `expressible` 이 뒤집혔는가. 대조군은 2026-08-30 의 저장된 스트림
   (zone 115/115 · mild 6/6 `True`)이다.
3. 🔴 **이 작업이 무엇의 증거가 아닌가** — 최소한 이 여섯:
   - **판은 각각 n=1 이다.** 시드 하나, 모델 하나(gpt-4o), 모델 파일 하나(tractor.mpd).
     인과의 증거도 비율의 증거도 아니다.
   - **`expressible == False` 비율은 부분적으로 프롬프트 준수를 잰다.** 그 필드의
     description 이 모델에게 *언제* false 라고 말할지를 가르친다.
   - **프로브 격리는 zone 에만 됐다.** mild 의 결과를 zone 과 같은 종류의 증거로 인용하면
     안 된다 — payload 값은 보드가 있어야 나온다.
   - **임계 변경이 물리를 같이 바꿨다.** (a) 프로브와 (b) 보드가 다른 것을 잰다.
   - **`slots_upper_bound > 0` 은 아무 결론도 아니다.** 0 만이 결론을 준다.
   - **저장된 오라클 데이터셋은 이미 다른 세대다**(`battery_physics` = `stall:false,
     derate:false`). 🔴 **이 데이터셋으로 거동을 주장하면 안 된다.**
4. **S2 에 넘기는 것** — `slots_upper_bound` 의 실측값과 그것이 S2 의 재가격 경로에 대해
   말하는 것/말하지 않는 것.
5. **parked 항목** — `export_novelty_calibration.py` 의 DESCRIPTOR 지문이 이름만 해싱해
   공식 변경을 못 잡는다(그 축은 생산 호출자가 0개라 오늘은 무해하지만 되살릴 때 터진다).

- [ ] **Step 3: 커밋**

```bash
git add docs/superpowers/reports/2026-08-31-s1-observation-and-thresholds.md
git commit -m "docs: S1 마감 보고 — 무엇이 뒤집혔고 무엇의 증거가 아닌가"
```

---

## 🔴 이 계획이 spec 게이트 표에서 **미룬 것** (조용히 좁히지 않는다)

spec §7 의 게이트 표 중 **둘은 진짜 `env` 를 요구해서** 단위 게이트로 못 만들었다. 지우지
않고 여기 적고, T5 의 보드가 대신 확인하게 한다.

| spec §7 항목 | 왜 미뤘나 | 무엇이 대신 확인하나 |
|---|---|---|
| *"`heaviest_payload_kg` 가 실제 화물에서 나온다 — `_payload_mass` 를 상수 0 으로 변이시키면 빨개진다"* | `_payload_mass` 는 `env.scene_tree` 에서 화물 형상을 읽는다. 최소 fixture 로는 못 만든다 | T5 Step 4 가 `tractor__mild_s1.jsonl` 의 `llm_input` 에서 `heaviest_payload_kg` 가 **0 이 아닌 값**으로 실렸는지 본다 |
| *"프로브 전후 env 지문(`nv`·`ne`·`closed`) 동일"* | 같은 이유 — 진짜 `OperatingSchedule` 이 필요하다 | T5 Step 3 의 보드가 `[milp-probe]` 를 찍고 **정상 완주**하는 것. 프로브가 세계를 건드렸다면 그 판이 달라진다 |

🔴 **T6 보고서는 이 표를 그대로 인용해야 한다.** 두 명제는 "게이트가 지킨다"가 아니라
**"보드 한 판이 증거다"** 이고, 그것은 n=1 이다.

---

## 완료 판정

- [ ] `julia +lts --project=. -e 'using Pkg; Pkg.test()'` → `fail == 0 && error == 1`(Gurobi)
- [ ] `.venv/bin/python -m pytest src/respec/llm_service/ --ignore=…/test_propose.py -q` → 초록
- [ ] `.venv/bin/python -m pytest wm4spacecraft_manufacturing/core/ -q` → 초록
- [ ] pass 델타가 태스크별로 새 게이트의 단언 수로 설명된다
- [ ] 음성 대조 다섯을 **실제로 돌려 빨간 것을 봤다** (T1×2 · T2×1 · T3×1 · T4×1)
- [ ] `n_stalled >= 1` 로 severe 데모가 여전히 정지한다
- [ ] 유료 호출 총계가 **6건 이하**
- [ ] 보고서 §3(무엇의 증거가 아닌가)이 여섯 항목을 다 담았다
