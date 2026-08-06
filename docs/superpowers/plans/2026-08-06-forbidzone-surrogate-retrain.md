# ForbidZone 발화 + Surrogate 재학습 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `RESULTS_LLM7H.md` §5-f(배포 surrogate가 규칙과 바이트 동일)와 §7 마지막 행(ForbidZone 팔이 한 번도 발화하지 않음)을 **측정으로** 닫는다 — surrogate에 매크로 7·8 학습 근거를 실제로 넣고, ForbidZone이 발화 가능한 발화점이 존재하는지 값싸게 판정한 뒤 그 자리에서 라벨을 만든다.

**Architecture:** 사슬은 `진단 → 어휘 게이트 → 싼 재학습 → 라벨 → 완전 재학습 → 재측정` 이다. 시뮬레이션이 필요한 단계를 뒤로 미루고, 각 단계가 **그 자체로 반증 가능한 산출물**을 낸다. 세 개의 독립 주입기(`run_demo.jl::inject_blocking_zone!` = 스트림 / `gen_oracle_dataset.jl::place_blocking_zone!` = 라벨 / `render_demo.jl` = 녹화)가 존재하므로, 라벨 경로와 스트림 경로를 **따로** 다루고 녹화 경로는 건드리지 않는다.

**Tech Stack:** Julia 1.10 (`julia +lts --project=.`) · Python (`venv/hjcrl`, sklearn RandomForest, DSPy 3.2.1 + gpt-4o) · HiGHS MILP · JSONL 라벨 덤프.

## Global Constraints

이 절의 값은 모든 태스크의 요구사항에 **암묵적으로 포함**된다.

- **ForbidZone 구역의 주입은 pre-sim, 결정론적, 사람이 고른다.** 판이 시작되는 순간 구역이 어디 뜨는지가 확정돼 있어야 한다 — 런타임에 후보를 뒤져 심는 무작위 주입이 아니다. `DEMO_OOD_SEED` 로 확률적인 것은 fault·battery 이고, 공간 사건은 이 규칙에서 **예외**다. (근거: restageable 집합은 closed=0 에서 7, closed≈46 부터 0. ForbidZone 이 도메인을 갖는 자리는 원래부터 sim 시작 전뿐이었다.)
- **Julia는 반드시 `julia +lts --project=.`** (1.10.11 핀). 새 Julia에서 `Pkg.add` 하면 빌드가 조용히 깨진다.
- **비교 런은 순차 실행**(README 함정 30). 병렬이면 HiGHS가 다른 스케줄을 내 비교 자체가 무효 + 프로세스당 ~2.5 GB라 OOM. 라벨 격자의 팔 교차도 "비교"이므로 **Lanes=1**.
- **행동 어휘 단일 진실원 = `wm4spacecraft_manufacturing/action_registry.json`.** 리터럴 복붙 금지. 매크로를 건드린 뒤에는 반드시 `python audit_action_vocab.py` (exit 0 = 6/6).
- **비용표 일치**: `MACRO_COST` 는 `gen_oracle_dataset.jl` · `e1_analyze.py` · `export_surrogate.py` · `features_agnostic.py` · `action_registry.json` 다섯 곳이 **같은 값**이어야 한다 (함정 29). 현재 값: `{0:0.0, 1:1.0, 2:0.3, 3:1.0, 4:1.0, 7:1.5, 8:0.2}`.
- **기대 baseline(실패 아님)**: `Pkg.test()` = **11 pass / 1 error**(Gurobi 라이선스 없음). `verify.py` = **7/8**(Task 2에서 8/8로 바뀐다). 옛 문서의 "8/8"은 인용 금지.
- **`render_demo.jl` 은 수정 금지.** 덱 영상 4편의 녹화 경로다. 절차가 갈리면 두 파일 주석에 그 사실을 적는다(이미 그렇게 되어 있다).
- **LLM lane은 `DSPY_PROGRAM=__seed_only__`.** 컴파일된 `dspy_real_program_gpt4o.json` 은 battery 전용이라 zone·RelocateBuild 어휘가 없다.
- **`DSPY_URL` 포트는 문서 숫자가 아니라 실제 띄운 uvicorn 포트**에 맞춘다.
- 작업 디렉터리: Julia는 저장소 루트(`ConstructionBots.jl/`), Python은 `wm4spacecraft_manufacturing/`.
- 커밋은 `ConstructionBots.jl` 저장소에 한다(독립 repo). 작업 트리에 **미커밋 변경이 이미 있으므로** `git add -A` 금지 — 파일을 명시해서 add 한다.

---

## 진단 요약 — 이 계획이 딛고 있는 실측

착수 전에 코드·덤프에서 직접 확인한 것. 계획의 모든 분기가 이 다섯 줄에 걸려 있다.

| # | 사실 | 출처 |
|---|---|---|
| D1 | `zgrid_0805/` **24행 전부** `zone_blocked=0, zone_restage_feasible=0` → ForbidZone(3)은 이 저장소에서 **도메인을 가진 적이 없다** | `oracle/out/zgrid_0805/*.jsonl` 직접 파싱 |
| D2 | 그 격자의 "early(closed 10~16)"도 0이다. 이유는 **발화점 붕괴** — tractor는 첫 시뮬 배치에서 ~58 노드를 닫으므로 10~16 슬롯이 전부 closed≈50~58 에 due 된다 | `oracle/probe_fire_points.jl` 헤더 주석(실측: `closed_at_fire ∈ {50,58}`) |
| D3 | 그리고 restageable 집합은 **closed=0 에서 7, closed≈46 부터 0** 이다 | `gen_oracle_dataset.jl:359` 주석(2026-08-03 실측) |
| D4 | `run_demo.jl::inject_blocking_zone!` 는 후보를 `zone_relocatable`(RelocateBuild 가능) **하나로만** 거른다. ForbidZone 도메인은 검사조차 안 한다 | `tools/monitor/run_demo.jl:200` |
| D5 | 배포 surrogate 는 `graded_hs_n44` 로 기동 시 fit 되고 `surro_support={0,1,2,3,4}`. 7·8은 후보에서 **탈락**한다 | `src/respec/llm_service/dspy_service.py:167-195, 288-310` |

**D2+D3 이 §7 마지막 행의 진짜 원인이다.** "빌드 도중이라서"가 아니라 **"early 가 early 가 아니었다"** 이다. 존재 가능 구간은 `closed < 46` 인데 격자의 어떤 발화점도 거기 도달하지 못했다.

현재 라벨의 매크로 지원(완전 instance 기준, `instance_arms_complete` 통과분):

| 덤프 | 완전 instance | 매크로 지원 | kinds |
|---|---|---|---|
| `graded_hs_n44.jsonl` (배포 학습셋) | 44 | `[0,1,2,3,4]` | battery, fault, zoneblk |
| `battgrid_0805_s1.jsonl` | 18 | **`[0,1,2,8]`** ← SwapBattery 있음 | battery |
| `firegrid_merged.jsonl` | 108 | `[0,1,2,3,4]` | battery, fault, zoneblk |
| `openworld_merged.jsonl` | 60 | `[0,1,2,3,4]` | battery, fault, zoneblk |
| **매크로 7이 든 완전 instance** | **0** | — | — |

`graded_hs_n44` 와 `battgrid_0805_s1` 의 instance id 충돌은 **없다**(확인함).

---

## File Structure

**신규**

| 파일 | 책임 |
|---|---|
| `wm4spacecraft_manufacturing/oracle/probe_forbidzone_domain.jl` | 진행도별 ForbidZone 도메인 크기 + 후보 구역의 진단값을 CSV로. 시뮬 1판, 관찰만 |
| `wm4spacecraft_manufacturing/surrogate_data.py` | surrogate 학습 프레임의 **단일 정의**(`load_training_frame`). `dspy_service` 와 테스트가 같은 코드를 쓴다 |
| `wm4spacecraft_manufacturing/merge_labels.py` | 라벨 JSONL 병합기(instance id 충돌 검사 포함) |
| `wm4spacecraft_manufacturing/test_surrogate_support.py` | 배포 surrogate 의 매크로 지원 집합 계약 테스트 |
| `wm4spacecraft_manufacturing/oracle/run_fzgrid.ps1` | ForbidZone 팔교차 라벨 격자 러너(순차 강제) |

**수정**

| 파일 | 무엇을 |
|---|---|
| `wm4spacecraft_manufacturing/verify.py:24, 300-308` | V0 을 `instance_arms_complete` 기준으로(= 배포 필터와 동일). 배너 문구도 함께 |
| `wm4spacecraft_manufacturing/wm_datasets.py` | 새 병합 데이터셋 이름 등록 |
| `src/respec/llm_service/dspy_service.py:167-195` | 학습 프레임 로딩을 `surrogate_data` 로 위임, 기본 데이터셋 교체 |
| `tools/monitor/run_demo.jl:186-219` | `DEMO_ZONE_FAMILY` 분기 + restage-feasible 구역 주입기 (**Task 4, 분기 A일 때만**) |
| `wm4spacecraft_manufacturing/md/RESULTS_LLM7H.md` · `md/STATUS.md` · `.claude/CLAUDE.md` | 재측정 결과 반영 |

**절대 수정 금지**: `tools/monitor/render_demo.jl`.

---

### Task 1: ForbidZone 배치 카탈로그 + 도메인 절벽 (결정 게이트)

> **설계 제약 (2026-08-06, 사용자 지시).** ForbidZone 구역의 주입은 **시뮬레이션이 시작되기 전에 사람이 결정한다.** 런타임에 후보를 뒤져 무작위로 심는 것이 아니라, 판이 시작되는 순간 구역이 어디 뜨는지가 이미 확정돼 있어야 한다. (fault·battery 는 `DEMO_OOD_SEED` 로 계속 확률적이다 — 확정적인 것은 **공간 사건 하나**다.)
>
> 이 제약은 D3 과 정확히 맞물린다: restageable 집합은 **closed=0 에서 7 로 최대**이고 closed≈46 부터 0 이다. 즉 ForbidZone 이 도메인을 갖는 자리는 **원래부터 sim 시작 전**뿐이었고, 지금까지 실패한 이유는 그 자리를 런타임 추첨으로 찾으려 했기 때문이다. 사람이 미리 고르면 그 문제 자체가 사라진다.

산출물은 코드가 아니라 **두 개의 CSV와 하나의 판정**이다:
1. **배치 카탈로그** — sim 시작 전 기하에서, 어느 적치원에 어떤 반지름으로 구역을 놓으면 `n_restage_feasible ≥ 1` 이고 `n_nav_blocked ≥ 1` 인가. 사람이 이 표를 읽고 한 줄을 고른다.
2. **도메인 절벽** — 그 성질이 진행도에 따라 언제 사라지는가. "왜 pre-sim 이어야 하는가"의 증거이자 D2·D3(서로 다른 두 파일의 주석, 한 번도 같은 판에서 확인된 적 없음)의 첫 동시 확인.

**Files:**
- Create: `wm4spacecraft_manufacturing/oracle/probe_forbidzone_domain.jl`
- Read-only 참조: `wm4spacecraft_manufacturing/oracle/probe_fire_points.jl` (하네스 원본), `src/full_demo.jl:180,830` (`return_env_before_sim`), `src/respec/zone_diagnosis.jl:189`, `src/respec/restage_zone.jl:275`

**Interfaces:**
- Consumes: 없음(첫 태스크)
- Produces:
  - `oracle/out/fz_presim.csv` — **배치 카탈로그**. 열 `mode,closed,total,n_pristine,family,target,cx,cy,zone_r,n_blocked,n_restage_feasible,n_nav_goals,n_nav_blocked,root_covered,relocate_feasible,verdict`
  - `oracle/out/fz_scan.csv` — **도메인 절벽**. 같은 열 스키마(`mode` 로 구분)
  - Task 4 가 카탈로그의 `target,cx,cy,zone_r` 를 그대로 주입기의 입력으로 받는다. Task 5 는 `closed` 절벽을 발화점 선택 근거로 쓴다.

- [ ] **Step 1: 프로브 스크립트를 쓴다 (두 모드)**

`probe_fire_points.jl` 의 import 블록(1~50행)과 큰 스택 Task 실행(`main()`, 265~305행)을 그대로 따르되 **두 모드**를 둔다.

| 모드 | 훅 | 비용 | 무엇을 답하나 |
|---|---|---|---|
| `FZ_MODE=presim` (기본) | `run_lego_demo(...; return_env_before_sim = true)` → env 를 그대로 돌려받는다(`src/full_demo.jl:830`, cache 비어 있음 = 아직 아무것도 실행 안 됨) | **시뮬 없음** (MILP 스케줄링만, 수 분) | 사람이 고를 **배치 카탈로그** |
| `FZ_MODE=scan` | `CB.schedule_ood_at_closed!(c, probe_zone_once)` 를 여러 c 에 건다. 콜백은 `nothing` 을 돌려주므로 respec 큐에 아무것도 안 들어간다 = 순수 관찰, 궤적 불변 | 시뮬 1판 (~15분) | 그 성질이 사라지는 **절벽** |

`presim` 이 기본인 이유: 사용자 제약상 실제로 쓰이는 것은 이 표다. `scan` 은 "왜 pre-sim 이어야 하는가"의 증거를 남기기 위한 것이고, 한 번 찍으면 다시 돌릴 일이 없다.

> **관련 seam.** `run_lego_demo` 에는 `pre_sim_hook` kwarg 도 있다(`src/full_demo.jl:835`) — 완성된 env 에 대해 sim 루프 직전에 호출되는 **생산 경로의 pre-sim 훅**이다. Task 4 가 사람이 고른 구역을 심을 자리가 바로 여기다. Task 1 은 아직 쓰지 않는다(관찰만).

```julia
# =============================================================================
# probe_forbidzone_domain.jl -- "ForbidZone(3) 이 도메인을 갖는 진행도가 존재하는가" 를 값싸게 판정한다.
#
# WHY THIS EXISTS
# ---------------
# zgrid_0805 의 24행이 전부 zone_restage_feasible=0 이다. 원인 후보가 둘인데 처방이 정반대다:
#   (a) 발화점 붕괴  — tractor 는 첫 배치에서 ~58 노드를 닫아 "early(10~16)" 슬롯이 전부 closed≈50~58
#                      에 due 된다(probe_fire_points.jl 헤더). restageable 집합은 closed≈46 부터 0
#                      (gen_oracle_dataset.jl:359) 이므로, early 가 실은 late 였을 뿐이다.
#                      -> 처방: 발화점을 앞당긴다. 주입기 기하는 그대로 둔다.
#   (b) 기하        — 어느 진행도에서도 "pristine 적치원을 덮으면서 항법 목표도 막는" 구역이 없다.
#                      -> 처방: ForbidZone 은 이 세계에서 죽은 팔이다. 어휘에서 그렇게 적는다.
# 두 주장은 서로 다른 문서의 주석이고 같은 판에서 확인된 적이 없다. 여기서 한 CSV 에 놓는다.
#
# 실행 (ConstructionBots.jl 저장소 루트에서):
#   julia +lts --project=. wm4spacecraft_manufacturing/oracle/probe_forbidzone_domain.jl
# ENV:
#   FZ_FROM/FZ_TO/FZ_EVERY  스캔 구간·간격(닫힌 노드 수). 기본 1 / 120 / 4
#                           -- 46 앞뒤를 촘촘히 봐야 하므로 기본이 probe_fire_points 보다 조밀하다
#   FZ_R      구역 반지름 배수. 기본 "0.5,0.8" (0.5=데모의 DEMO_ZONE_R, 0.8=라벨러의 rfrac)
#   FZ_SPARE / FZ_SEED / FZ_OUT
# =============================================================================
import ConstructionBots as CB
import HiGHS, Logging, Random, Graphs
using LinearAlgebra: norm
using Printf

CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 60.0, "mip_rel_gap" => 0.05,
    "output_flag" => false, "presolve" => "on")

const MODE  = lowercase(get(ENV, "FZ_MODE", "presim"))   # presim | scan
const FROM  = parse(Int, get(ENV, "FZ_FROM",  "1"))
const TO    = parse(Int, get(ENV, "FZ_TO",    "120"))
const EVERY = parse(Int, get(ENV, "FZ_EVERY", "4"))
# 반지름 후보. 전부 **로봇 반지름 배수**다(0.5 = 데모의 DEMO_ZONE_R). 라벨러
# place_blocking_zone! 의 rfrac 은 적치원 반지름 배수라 스케일이 다르므로 여기서 섞지 않는다 --
# 적치원 기준으로 환산해 보고 싶으면 CSV 의 zone_r(절대값)과 target 의 적치원 반지름을 비교한다.
const RFRACS = [parse(Float64, strip(s)) for s in split(get(ENV, "FZ_R", "0.5,0.8,1.5"), ",")]
const SPARE = parse(Int, get(ENV, "FZ_SPARE", "3"))
const SEED  = parse(Int, get(ENV, "FZ_SEED",  "1"))
const OUT   = get(ENV, "FZ_OUT",
                  joinpath(@__DIR__, "out", MODE == "scan" ? "fz_scan.csv" : "fz_presim.csv"))
const ROWS  = Ref(NamedTuple[])
const KEY   = :fz_probe

"""
`zone_blocked_assemblies` 의 전제조건만 뽑은 것 — **구역 겹침 검사를 뺀** pristine 집합.

이 수가 0 이면 어떤 구역을 어디에 놓아도 ForbidZone 도메인은 빈다(원인 (a)/(b) 중 (a)).
0 이 아닌데 n_blocked 가 0 이면 겹침이 안 나는 것이다(원인 (b)). 두 원인을 이 한 열이 가른다.
"""
function pristine_assemblies(env)
    isempty(env.staging_circles) && return CB.AbstractID[]
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])),
                  collect(keys(env.staging_circles)))
    out = CB.AbstractID[]
    for (aid, _) in env.staging_circles
        aid == root && continue
        ac = try CB._assembly_complete_node(env, aid) catch; nothing end
        ac === nothing && continue
        v = try CB.get_vtx(env.sched, CB.node_id(ac)) catch; nothing end
        v === nothing && continue
        (v in env.cache.closed_set || v in env.cache.active_set ||
         (try CB._assembly_started(env, aid) catch; false end)) && continue
        push!(out, aid)
    end
    return out
end

"구역을 잠깐 심고 진단한 뒤 반드시 지운다(관찰이 궤적을 바꾸면 안 된다)."
function diag_at(env, center, r)
    CB.add_restriction_zone!(KEY, center, r)
    d = try CB.zone_diagnosis(env, KEY; check_restage = true)
        catch e; @warn "[fz] zone_diagnosis 실패" exception = e; nothing end
    try CB.remove_restriction_zone!(KEY) catch end
    return d
end

function push_row!(env, family, target, center, r, d)
    closed = length(env.cache.closed_set)
    total  = Graphs.nv(CB.get_graph(env.sched))
    push!(ROWS[], (mode = MODE, closed = closed, total = total,
        n_pristine = length(pristine_assemblies(env)), family = family, target = target,
        cx = center[1], cy = center[2], zone_r = r,
        n_blocked = d === nothing ? -1 : d.n_blocked,
        n_restage_feasible = d === nothing ? -1 : d.n_restage_feasible,
        n_nav_goals = d === nothing ? -1 : d.n_nav_goals,
        n_nav_blocked = d === nothing ? -1 : d.n_nav_blocked,
        root_covered = d === nothing ? -1 : d.root_covered,
        relocate_feasible = d === nothing ? false : d.relocate_feasible,
        verdict = d === nothing ? "ERR" : String(d.verdict)))
end

"""
한 스냅샷에서 두 가족의 후보 구역을 **전부** 진단한다.

  :stage — pristine 조립체의 **적치원 중심** 위 (ForbidZone 이 겨냥하는 자리)
  :nav   — run_demo.jl::inject_blocking_zone! 이 고르는 자리(아직 활성이 아닌 항법 목표)

두 가족을 같은 스냅샷에서 재야 "막히기는 하는데 옮길 수는 없다"(= 지금 스트림의 상태)와
"옮길 수도 있고 막기도 한다"(= 우리가 찾는 자리)가 구분된다.

presim 모드에서는 **후보를 자르지 않는다** — 이 표가 곧 사람이 고르는 카탈로그이므로,
"프로브가 안 본 자리라 못 골랐다"가 생기면 안 된다. scan 모드는 절벽만 보면 되므로 nav 후보를
앞의 3개로 자른다(주입기도 정렬 후 앞에서 고른다).
"""
function probe_zone_once(env)
    pris = pristine_assemblies(env)
    for r_frac in RFRACS, aid in pris
        ball = env.staging_circles[aid]
        c = Vector{Float64}(CB.get_center(ball)[1:2])
        r = r_frac * Float64(CB.default_robot_radius())
        push_row!(env, "stage", string(aid), c, r, diag_at(env, c, r))
    end
    isempty(pris) && push_row!(env, "stage", "none", [NaN, NaN], 0.0, nothing)

    navs = try CB._nav_goal_targets(env) catch; [] end
    cand = [t for t in navs if !(t.vtx in env.cache.active_set)]
    nav_take = MODE == "presim" ? cand : first(cand, 3)
    for r_frac in RFRACS, t in nav_take
        r = r_frac * Float64(CB.default_robot_radius())
        c = Vector{Float64}(t.goal)
        push_row!(env, "nav", "vtx$(t.vtx)", c, r, diag_at(env, c, r))
    end

    @printf("[fz] closed=%3d pristine=%2d nav_cand=%3d rows=%d\n",
            length(env.cache.closed_set), length(pris), length(cand), length(ROWS[]))
    return nothing      # nothing = respec 큐에 아무것도 안 들어간다(순수 관찰)
end
```

`main()` 은 모드로 갈린다:

```julia
function main()
    for f in (:clear_ood_schedule!, :clear_restriction_zones!, :clear_spare_pools!,
              :clear_faulted_robots!, :clear_recovery_spares!, :clear_ood_truth_log!,
              :clear_wedge_edges!, :clear_stalled_robots!)
        try getproperty(CB, f)() catch end
    end
    try CB.set_reform_interval!(parse(Int, get(ENV, "DS_REFORM", "300"))) catch end

    if MODE == "scan"
        for c in FROM:EVERY:TO; CB.schedule_ood_at_closed!(c, probe_zone_once); end
        CB.RESPEC_ENABLED[] = true
    end
    println("[fz] mode=$(MODE) seed=$(SEED) spare=$(SPARE) radii=$(RFRACS)" *
            (MODE == "scan" ? " scan=$(FROM):$(EVERY):$(TO)" : " (시뮬 없음)"))

    # run_lego_demo 호출은 probe_fire_points.jl:288-303 과 **같다**. 단 하나가 다르다:
    #   return_env_before_sim = (MODE == "presim")
    # true 면 sim 루프 전에 완성된 env 를 그대로 돌려준다(full_demo.jl:830) -> 우리가 직접 진단한다.
    # 큰 스택 Task(ccall(:jl_new_task, ...)) 는 두 모드 모두 유지한다 -- 없으면 스택 오버플로.
    ...  # (probe_fire_points.jl 의 블록을 옮기고 위 한 줄만 바꾼다)
    if MODE == "presim"
        env = res[]
        env === nothing && error("presim: run_lego_demo 가 env 를 돌려주지 않았다")
        probe_zone_once(env)
    end

    mkpath(dirname(OUT))
    open(OUT, "w") do io
        println(io, "mode,closed,total,n_pristine,family,target,cx,cy,zone_r," *
                    "n_blocked,n_restage_feasible,n_nav_goals,n_nav_blocked," *
                    "root_covered,relocate_feasible,verdict")
        for r in ROWS[]
            println(io, join((r.mode, r.closed, r.total, r.n_pristine, r.family, r.target,
                              round(r.cx; digits = 4), round(r.cy; digits = 4),
                              round(r.zone_r; digits = 4),
                              r.n_blocked, r.n_restage_feasible, r.n_nav_goals, r.n_nav_blocked,
                              r.root_covered, Int(r.relocate_feasible), r.verdict), ","))
        end
    end
    println("[fz] wrote $(length(ROWS[])) rows -> $(OUT)")
end

main()
```

`probe_fire_points.jl:288-303` 의 `run_lego_demo` 호출 블록과 큰 스택 Task(`ccall(:jl_new_task, ...)`)는 **그대로 옮긴다** — 없으면 스택 오버플로로 죽는다. 배터리 활성화 블록(`PF_BATT`, 276~283행)은 **옮기지 않는다**(배터리 회계는 이 질문과 무관하고, 켜면 관찰이 상태를 건드린다).

- [ ] **Step 2: 배치 카탈로그를 만든다 (시뮬 없음, 수 분)**

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl
FZ_MODE=presim \
  julia +lts --project=. wm4spacecraft_manufacturing/oracle/probe_forbidzone_domain.jl
```
기대: `[fz] mode=presim ... (시뮬 없음)` → `[fz] closed=  0 pristine=<N> ...` 한 줄 → `oracle/out/fz_presim.csv`.
`pristine` 이 **7 이어야 한다**(D3: closed=0 에서 restageable = 7). 0 이면 프로브가 env 를 잘못 받은 것이므로 CSV 를 읽기 전에 그것부터 고친다.

- [ ] **Step 3: 카탈로그를 판정한다 — 사람이 고를 줄이 있는가**

```bash
cd wm4spacecraft_manufacturing && python -c "
import csv
rows=list(csv.DictReader(open('oracle/out/fz_presim.csv',encoding='utf-8')))
hit=[r for r in rows if int(r['n_restage_feasible'])>=1 and int(r['n_nav_blocked'])>=1]
print('총 %d 행 / ForbidZone 이 살아 있는 배치 %d 개' % (len(rows), len(hit)))
print()
print('%-6s %-22s %8s %8s %6s %6s %8s %s' % ('family','target','cx','cy','r','feas','navblk','verdict'))
for r in sorted(hit, key=lambda r:(-int(r['n_restage_feasible']), -int(r['n_nav_blocked'])))[:20]:
    print('%-6s %-22s %8s %8s %6s %6s %8s %s' % (r['family'],r['target'],r['cx'],r['cy'],
          r['zone_r'],r['n_restage_feasible'],r['n_nav_blocked'],r['verdict']))
print()
import collections
print('verdict 분포(전체):', dict(collections.Counter(r['verdict'] for r in rows)))
print('n_restage_feasible>=1 인 행:', sum(1 for r in rows if int(r['n_restage_feasible'])>=1))
print('n_nav_blocked>=1 인 행:     ', sum(1 for r in rows if int(r['n_nav_blocked'])>=1))
"
```

**분기 A (hit ≥ 1)** — ForbidZone 은 살아 있고, **사람이 고를 배치가 표에 있다**. Task 4 는 그 한 줄(`target, cx, cy, zone_r`)을 pre-sim 훅에 그대로 심는 선언적 주입기를 만든다. 런타임 탐색은 없다.
**분기 B (hit = 0)** — 두 카운트를 따로 본다. `n_restage_feasible ≥ 1` 은 많은데 `n_nav_blocked ≥ 1` 이 0 이면 **"덮지만 막지는 못한다"** = README 함정("커버리지 ≠ 막힘")의 재확인이고, ForbidZone 은 이 세계에서 죽은 팔이다. 둘 다 0 이면 프로브 자체를 의심한다(`zone_diagnosis` 가 빈 cache 에서 어떻게 도는지 먼저 확인).

어느 쪽이든 **결과를 그대로 적는다**. 원하는 답이 안 나왔다고 반지름 목록을 늘려 가며 찾지 않는다 — 그건 측정이 아니라 낚시다. 늘려야 한다고 판단되면 그 근거를 먼저 적는다.

- [ ] **Step 4: 절벽을 찍는다 (시뮬 1판, ~15분)**

카탈로그가 pre-sim 에서만 성립한다는 것이 이 계획의 전제다. 그 전제를 측정으로 남긴다.

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl
FZ_MODE=scan FZ_FROM=1 FZ_TO=120 FZ_EVERY=4 \
  julia +lts --project=. wm4spacecraft_manufacturing/oracle/probe_forbidzone_domain.jl
```
```bash
cd wm4spacecraft_manufacturing && python -c "
import csv, collections
rows=list(csv.DictReader(open('oracle/out/fz_scan.csv',encoding='utf-8')))
by=collections.defaultdict(lambda:[0,0,0])
for r in rows:
    a=by[int(r['closed'])]
    a[0]=max(a[0],int(r['n_pristine']))
    a[1]=max(a[1],int(r['n_restage_feasible']))
    a[2]=max(a[2],int(r['n_nav_blocked']))
print('%8s %10s %14s %12s' % ('closed','pristine','max_feasible','max_navblk'))
for c,(p,f,n) in sorted(by.items()): print('%8d %10d %14d %12d' % (c,p,f,n))
"
```
기대(D3 이 맞다면): `pristine` 과 `max_feasible` 이 closed≈46 부근에서 0 으로 떨어진다. **떨어지지 않으면 D3 이 틀린 것이고, 그건 이 계획 전체보다 중요한 발견이므로 보고하고 멈춘다.**

- [ ] **Step 5: 커밋**

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl
git add wm4spacecraft_manufacturing/oracle/probe_forbidzone_domain.jl \
        wm4spacecraft_manufacturing/oracle/out/fz_presim.csv \
        wm4spacecraft_manufacturing/oracle/out/fz_scan.csv
git commit -m "probe: ForbidZone 배치 카탈로그(pre-sim) + 도메인 절벽"
```

---

### Task 2: Ch-D — `verify.py` V0 을 valid_mask 기준으로 고친다

계획서가 Ch-D 를 "생성기 `MACROS` 에 7 을 넣어 V0 을 되살린다"로 적었지만, 그건 증상이다. V0 은 instance 마다 `len(MACROS)=7` 개 팔을 **전부** 요구하는데, `DS_VALID_ONLY` 로 만든 라벨은 그 사건에서 **유효한 팔만** 돈다(fault 는 2팔). 7을 채우는 것은 원리적으로 불가능하고, 채우려 드는 것은 "말이 안 되는 팔도 굴려라"라는 뜻이 된다. 배포 surrogate 는 이미 `instance_arms_complete`(valid_mask 기준)를 쓴다 — V0 도 같은 술어를 써야 검증과 배포가 같은 것을 본다.

**Files:**
- Modify: `wm4spacecraft_manufacturing/verify.py:24`, `verify.py:300-308`

**Interfaces:**
- Consumes: `e1_analyze.instance_arms_complete(g) -> bool` (이미 존재, `verify.py` 는 아직 안 씀)
- Produces: `verify.py` 가 canonical set 에서 **8/8**. Task 6이 이 숫자를 문서에 반영한다.

- [ ] **Step 1: 실패를 먼저 본다 (현재 7/8 을 눈으로 확인)**

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl/wm4spacecraft_manufacturing
python verify.py oracle/out/graded_hs_n44.jsonl 2>&1 | tail -15
```
기대: `V0 ... FAIL ... 0/44 instances have all 7 macro arms rolled out`, 마지막 줄 **7/8**.

- [ ] **Step 2: import 를 넓힌다**

`verify.py:24`:
```python
from e1_analyze import load, featurize, MACROS, MACRO_NAME, MACRO_COST, cost_lex_key
```
→
```python
from e1_analyze import (load, featurize, MACROS, MACRO_NAME, MACRO_COST, cost_lex_key,
                        instance_arms_complete)
```

- [ ] **Step 3: V0 의 완전성 판정을 교체한다**

`verify.py:300-301` 의 두 줄
```python
    arm_counts = df.groupby("instance").macro.nunique()          # instance별로 시도된 macro 종류 수
    full = int((arm_counts == len(MACROS)).sum())                # 5개 macro를 전부 rollout한 instance 수
```
→
```python
    # 완전성 판정은 **배포 필터와 같은 술어**를 쓴다(dspy_service._load_surrogate 가 쓰는 것).
    # 예전에는 `nunique() == len(MACROS)` = "7팔 전부"였는데, DS_VALID_ONLY 로 만든 라벨은 그 사건에서
    # 유효한 팔만 돌므로(fault 는 2팔) 그 조건은 원리적으로 충족 불가였다 -- V0 이 2026-08-06 이전부터
    # 실패하던 이유(RESULTS_LLM7H §6, "Ch-D"). 검증과 배포가 다른 필터를 쓰면 V0 이 배포되지 않는
    # 무언가를 검증하게 된다.
    full = sum(1 for _, g in df.groupby("instance") if instance_arms_complete(g))
```

`verify.py:306-308` 의 배너 문구도 함께 고친다 — **약한 검사를 강한 이름으로 부르면 안 된다**:
```python
    results["V0"] = (
        verdict("full-enumeration labels", full == len(insts),
                f"{full}/{len(insts)} instances have all {len(MACROS)} macro arms rolled out")
```
→
```python
    results["V0"] = (
        verdict("full-enumeration labels", full == len(insts),
                f"{full}/{len(insts)} instances rolled out every VALID arm "
                f"(valid_mask 기준; 전체 어휘는 {MACROS})")
```

- [ ] **Step 4: 통과를 확인한다**

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl/wm4spacecraft_manufacturing
python verify.py oracle/out/graded_hs_n44.jsonl 2>&1 | tail -15
```
기대: `V0 ... PASS ... 44/44 instances rolled out every VALID arm`, 마지막 줄 **8/8**.

- [ ] **Step 5: 다른 덤프에서도 회귀가 없는지 본다**

```bash
python verify.py oracle/out/openworld_merged.jsonl 2>&1 | tail -3
python verify.py oracle/out/firegrid_merged.jsonl  2>&1 | tail -3
```
`firegrid_merged` 는 126 instance 중 108 만 완전하다(확인된 사실) → V0 이 FAIL 하는 것이 **정상**이다. 그 사실을 출력 그대로 기록한다. 억지로 통과시키지 않는다.

- [ ] **Step 6: 커밋**

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl
git add wm4spacecraft_manufacturing/verify.py
git commit -m "fix(verify): V0 의 완전성 판정을 배포와 같은 valid_mask 기준으로"
```

---

### Task 3: Surrogate 재학습 ① — `SwapBattery`(8) 지원 (시뮬 없음)

§5-f 의 기전은 두 개다: battery 축의 `SwapBattery` 부재와 zone 축의 `RelocateBuild` 부재. 앞의 것은 **오늘 있는 덤프로 닫을 수 있다** — `battgrid_0805_s1.jsonl` 이 18 instance × 매크로 `[0,1,2,8]` 로 완전하다. 시뮬을 한 판도 안 돌리고 배포 surrogate 의 battery 축 행동을 바꿀 수 있는지 여기서 판정한다.

**Files:**
- Create: `wm4spacecraft_manufacturing/merge_labels.py`
- Create: `wm4spacecraft_manufacturing/surrogate_data.py`
- Create: `wm4spacecraft_manufacturing/test_surrogate_support.py`
- Modify: `wm4spacecraft_manufacturing/wm_datasets.py`
- Modify: `src/respec/llm_service/dspy_service.py:167-195`

**Interfaces:**
- Consumes: `e1_analyze.load / featurize / MACRO_COST / instance_arms_complete`, `surrogate_model.build_model`
- Produces:
  - `surrogate_data.load_training_frame(path, lam=3.0) -> (X: pd.DataFrame, y: np.ndarray, support: set[int], n_instances: int)`
  - `wm_datasets.N44_PLUS8: str` — 병합 덤프 경로
  - `merge_labels.py` CLI: `python merge_labels.py --out <path> <in1.jsonl> <in2.jsonl> ...`

> **주의(import 순환).** `e1_analyze` 가 `surrogate_model` 을 import 한다(`e1_analyze.py:64`). 따라서 학습 프레임 로더를 `surrogate_model.py` 안에 두면 순환이 생긴다. 그래서 **새 모듈** `surrogate_data.py` 에 둔다.

- [ ] **Step 1: 병합기의 실패 테스트를 먼저 쓴다**

`wm4spacecraft_manufacturing/test_surrogate_support.py`:
```python
"""배포 surrogate 의 **매크로 지원 집합** 계약 테스트.

왜 이 테스트가 필요한가: 학습 근거가 없는 매크로는 dspy_service.surrogate_rank 에서 후보에서
탈락한다. 그래서 어휘가 빠지면 에러가 아니라 **성능으로만** 샌다 -- RESULTS_LLM7H §5-f 에서
배포 surrogate 가 규칙과 5판 전부 바이트 동일한 결과를 낸 것이 그 증상이었다.
지원 집합은 주장이 아니라 검사여야 한다.
"""
import sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import wm_datasets
from surrogate_data import load_training_frame

FAILED = 0


def check(name, ok, detail=""):
    global FAILED
    print("  %s  %s   %s" % ("PASS" if ok else "FAIL", name, detail))
    if not ok:
        FAILED += 1


print("== 배포 학습셋의 매크로 지원 ==")
path = wm_datasets.resolve(None, default=wm_datasets.N44_PLUS8)
X, y, support, n_inst = load_training_frame(path)
check("데이터셋이 존재한다", os.path.exists(path), path)
check("instance 수 >= 60", n_inst >= 60, "n=%d" % n_inst)
check("SwapBattery(8) 학습 근거 있음", 8 in support, "support=%s" % sorted(support))
check("기존 5팔 보존", {0, 1, 2, 3, 4} <= support, "support=%s" % sorted(support))
check("X/y 길이 일치", len(X) == len(y), "%d vs %d" % (len(X), len(y)))

sys.exit(1 if FAILED else 0)
```

- [ ] **Step 2: 실패를 확인한다**

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl/wm4spacecraft_manufacturing
python test_surrogate_support.py
```
기대: `ModuleNotFoundError: No module named 'surrogate_data'` (또는 `AttributeError: N44_PLUS8`).

- [ ] **Step 3: 병합기를 쓴다**

`wm4spacecraft_manufacturing/merge_labels.py`:
```python
#!/usr/bin/env python
"""merge_labels.py -- 오라클 라벨 JSONL 을 합친다.

왜 스크립트인가: 손으로 cat 하면 **instance id 충돌**을 못 본다. 같은 id 가 두 파일에 있으면
groupby("instance") 가 서로 다른 세계의 팔을 한 instance 로 뭉쳐 랭킹이 조용히 망가진다.
여기서는 충돌을 에러로 만든다(--prefix 로 명시적으로 해소).

사용:
    python merge_labels.py --out oracle/out/n44_plus8.jsonl \
        oracle/out/graded_hs_n44.jsonl oracle/out/battgrid_0805_s1.jsonl
"""
import argparse, io, json, os, sys
from collections import defaultdict


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--prefix", action="store_true",
                    help="instance id 앞에 파일 stem 을 붙여 충돌을 해소한다")
    ap.add_argument("inputs", nargs="+")
    a = ap.parse_args()

    seen = defaultdict(set)          # instance -> {source stem}
    rows = []
    for p in a.inputs:
        stem = os.path.splitext(os.path.basename(p))[0]
        with io.open(p, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                r = json.loads(line)
                inst = str(r.get("instance", ""))
                if a.prefix:
                    inst = "%s::%s" % (stem, inst)
                    r["instance"] = inst
                seen[inst].add(stem)
                rows.append(r)

    clash = {i: sorted(s) for i, s in seen.items() if len(s) > 1}
    if clash:
        print("ERROR: instance id 가 여러 파일에 있다 (%d 개). --prefix 로 해소하라." % len(clash),
              file=sys.stderr)
        for i, s in list(clash.items())[:5]:
            print("  %s <- %s" % (i, s), file=sys.stderr)
        return 2

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with io.open(a.out, "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    print("wrote %d rows / %d instances -> %s" % (len(rows), len(seen), a.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: 병합 덤프를 만든다**

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl/wm4spacecraft_manufacturing
python merge_labels.py --out oracle/out/n44_plus8.jsonl \
    oracle/out/graded_hs_n44.jsonl oracle/out/battgrid_0805_s1.jsonl
```
기대: `wrote 274 rows / 62 instances -> oracle/out/n44_plus8.jsonl` (220+54 행, 44+18 instance). 충돌 에러가 나면 **--prefix 로 넘어가지 말고 왜 충돌하는지 먼저 본다** — 사전 확인에서는 충돌이 없었다.

- [ ] **Step 5: 학습 프레임 로더를 쓴다**

`wm4spacecraft_manufacturing/surrogate_data.py`:
```python
"""surrogate_data.py -- 배포 surrogate 의 **학습 프레임 단일 정의**.

왜 이 파일이 있나: 이 로직(fired 필터 -> 완전 instance 필터 -> featurize -> 비용 차감 보상)이
dspy_service._load_surrogate 안에만 있었다. 그래서 "배포 모델이 무슨 매크로를 본 적 있는가"를
테스트하려면 fastapi/dspy 를 통째로 import 해야 했고, 결국 아무도 테스트하지 않았다 --
RESULTS_LLM7H §5-f 의 5판 동일 결과가 그 대가다.

surrogate_model.py 에 두지 않는 이유: e1_analyze 가 surrogate_model 을 import 하므로(순환).
"""
import os
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))

LAM = 3.0    # 보상 = closed - LAM * macro_cost. dspy_service 가 쓰던 값 그대로.


def load_training_frame(path, lam=LAM):
    """(X, y, support, n_instances) 를 돌려준다.

    support = 학습 근거가 있는 매크로 id 집합. 여기 없는 팔은 배포 시 후보에서 탈락한다.
    """
    import sys
    if HERE not in sys.path:
        sys.path.insert(0, HERE)
    from e1_analyze import load, featurize, MACRO_COST, instance_arms_complete

    df = load(path)
    df = df[df.fired == True].copy()
    full = [i for i, g in df.groupby("instance") if instance_arms_complete(g)]
    df = df[df.instance.isin(full)].reset_index(drop=True)
    X = featurize(df)
    y = df.closed.astype(float).values - lam * np.array([MACRO_COST[int(m)] for m in df.macro])
    support = {int(m) for m in df.macro.unique()}
    return X, y, support, len(full)
```

- [ ] **Step 6: `wm_datasets.py` 에 이름을 등록한다**

`CANONICAL` 정의 블록 **뒤**에 추가:
```python
# ==========================================================================================
#  N44_PLUS8 — 배포 surrogate 의 학습셋 (2026-08-06)
# ==========================================================================================
# graded_hs_n44(44 instance, 매크로 [0,1,2,3,4]) + battgrid_0805_s1(18 instance, [0,1,2,8]).
# 왜 합치나: 배포 surrogate 는 8(SwapBattery) 행을 한 줄도 본 적이 없어서 그 팔을 후보에서
# 탈락시켰고, 그 결과 battery 사건에서 언제나 규칙과 같은 Replace 를 냈다(RESULTS_LLM7H §5-f,
# battery 적중 0/6). 어휘가 아니라 **학습 근거**가 없던 것이라 action_registry 를 고쳐도 안 낫는다.
# instance id 충돌은 없음을 merge_labels.py 가 에러로 강제한다.
N44_PLUS8 = "oracle/out/n44_plus8.jsonl"
```

- [ ] **Step 7: 테스트가 통과하는지 본다**

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl/wm4spacecraft_manufacturing
python test_surrogate_support.py
```
기대: 5개 PASS, `support=[0, 1, 2, 3, 4, 8]`, `n=62`.

- [ ] **Step 8: `dspy_service` 가 그 로더를 쓰도록 바꾼다**

`src/respec/llm_service/dspy_service.py` 의 `SURRO_DATA` 선언(약 163행):
```python
SURRO_DATA = wm_datasets.resolve(os.environ.get("EVAL_DATA"), default=wm_datasets.HS_N44)
```
→
```python
# 2026-08-06: 기본 학습셋을 N44_PLUS8 로 옮긴다. HS_N44 는 매크로 8(SwapBattery) 행이 없어
# 그 팔을 후보에서 탈락시켰다 -- 배포 surrogate 가 5판 전부 규칙과 동일한 결과를 낸 기전
# (RESULTS_LLM7H §5-f). 옛 모델을 재현하려면 EVAL_DATA=oracle/out/graded_hs_n44.jsonl.
SURRO_DATA = wm_datasets.resolve(os.environ.get("EVAL_DATA"), default=wm_datasets.N44_PLUS8)
```

그리고 `_load_surrogate()`(167~195행)의 본문을 로더 호출로 줄인다. **주석은 남긴다** — 왜 JSON export 를 안 읽는지, 왜 완전 instance 필터가 `len(g)==5` 가 아닌지는 여전히 유효한 기록이다:
```python
def _load_surrogate():
    try:
        sys.path.insert(0, WM)
        from surrogate_data import load_training_frame          # noqa: E402
        from surrogate_model import build_model                 # noqa: E402

        X, y, support, n_full = load_training_frame(SURRO_DATA, lam=LAM)
        model = build_model()
        model.fit(X.values, y)
        # **학습 근거가 있는 매크로 집합**을 같이 기록한다. 여기 없는 값을 예측하는 것은 근거 없는
        # 외삽이고, 조용히 점수를 내면 UI 가 "surrogate 가 NOOP 을 골랐다"로 보이지만 사실은
        # "고를 수조차 없었다"이다. 이 구분이 곧 라우터(낯선 것은 LLM)의 존재 이유다.
        _state.update(surrogate=model, surro_feats=list(X.columns),
                      surro_support=set(sorted(support)),
                      surro_data="%s (%d instances, macro support %s)"
                                 % (os.path.basename(SURRO_DATA), n_full, sorted(support)))
    except Exception as e:
        _state["surro_error"] = "%s: %s" % (type(e).__name__, e)
```

- [ ] **Step 9: 서비스를 띄워 지원 집합을 눈으로 확인한다**

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl/src/respec/llm_service
DSPY_MODEL=gpt-4o DSPY_PROGRAM=__seed_only__ \
  /c/Users/chahj/PythonCodes/venv/hjcrl/Scripts/python.exe -m uvicorn dspy_service:app --host 127.0.0.1 --port 8090
# 다른 셸에서:
curl -s http://127.0.0.1:8090/health
```
기대: `surrogate` 필드가 `n44_plus8.jsonl (62 instances, macro support [0, 1, 2, 3, 4, 8])`.
(`/health` 의 정확한 경로는 `dspy_service.py:500` 근처의 라우트 정의를 읽어 확인한다.)

- [ ] **Step 10: 어휘 감사 + 커밋**

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl/wm4spacecraft_manufacturing
python audit_action_vocab.py && python test_llm7h.py
```
기대: `6/6 consistent` (exit 0) · `16/16 passed` (exit 0).

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl
git add wm4spacecraft_manufacturing/merge_labels.py \
        wm4spacecraft_manufacturing/surrogate_data.py \
        wm4spacecraft_manufacturing/test_surrogate_support.py \
        wm4spacecraft_manufacturing/wm_datasets.py \
        wm4spacecraft_manufacturing/oracle/out/n44_plus8.jsonl \
        src/respec/llm_service/dspy_service.py
git commit -m "feat(surrogate): 학습셋에 SwapBattery 라벨을 넣어 매크로 8 지원을 만든다"
```

---

### Task 4: ForbidZone 이 발화하는 자리를 만든다 (Task 1 결과로 분기)

**Task 1 Step 3 의 판정을 읽고 해당 분기만 수행한다.** 두 분기의 산출물이 다르다.

> **✅ Task 1 결과 (2026-08-06 실측) — 분기 A. 인터페이스가 확정됐다.**
>
> | | pre-sim (closed=0) | scan (closed 58~117, 15지점) |
> |---|---|---|
> | `pristine` | **7** | **0** (전 구간) |
> | `n_restage_feasible ≥ 1` ∧ `n_nav_blocked ≥ 1` | **238 / 426** | **0 / 300** |
> | `verdict` | `forbid_zone` **238** · `noop` 188 | `noop` 270 · `ERR`(=pristine 없음 sentinel) 30 |
> | `max_nav_blocked` | 1 | 3 |
>
> - **절벽은 "closed≈46 부근"이 아니라 관측 불가능하다.** 첫 시뮬 배치가 58 노드를 한꺼번에 닫아 `schedule_ood_at_closed!` 로는 closed<58 에 **도달 자체가 안 된다**. 즉 pre-sim 주입은 선호가 아니라 **유일한 방법**이다.
> - `max_nav_blocked` 는 전 구간 3 으로 유지된다 → 사라지는 것은 막힘이 아니라 **재적치 도메인**이다("덮임≠막힘"과 다른 별개 기전).
> - **`n_nav_blocked` 는 presim 에서도 유효하다.** `ZONE_CHECK_PATHS` 가 기본 off 라(`zone_diagnosis.jl:194`) `zone_corridor` 의 연결성 분기가 아예 안 돌고 `n_disconnected ≡ 0` → `n_nav_blocked ≡ n_engulfed` = **로봇 위치와 무관한 신호**. 빈 cache 우려는 닫혔다.
> - **`target` 은 생성 라벨이지 집행 약속이 아니다.** `zone_blocked_assemblies` 의 겹침 검사는 *후보 조립체 자신의* 적치 반지름 `bR`(0.48~3.79)을 쓰지 프로브 구역 반지름(0.07~0.21)을 쓰지 않는다 — 그래서 작은 구역도 7 을 낸다(단 `n_restage_feasible=7` 은 238 중 22 건뿐).
>   → **주입기는 `(cx, cy, zone_r)` 로 받는다. assembly id 로 받으면 안 된다.**
>
> **⚠ 아래 분기 A 의 코드는 계획 초안 시점의 런타임 탐색 주입기라 폐기한다.** 사용자 제약(pre-sim · 사람이 결정 · 결정론적)에 따라 실제 구현은 **선언적 주입기**가 된다: Task 1 의 카탈로그에서 고른 한 줄(`target, cx, cy, zone_r`)을 환경변수로 받아 `run_lego_demo` 의 `pre_sim_hook`(`src/full_demo.jl:835`)에서 그대로 심는다. 탐색 루프도, `zone_relocatable` 필터도, 폴백도 없다 — 사람이 이미 골랐기 때문이다. 아래 코드는 **탐색 로직이 아니라 진단 조건(`n_restage_feasible ≥ 1 ∧ n_nav_blocked ≥ 1`)과 nl 문구·`ZoneTruth` 기록 형태를 참고용으로** 남겨 둔 것이다. 카탈로그의 실제 값이 나오면 이 절을 그 값으로 다시 쓴다.

**Files (분기 A):**
- Create: `tools/monitor/zone_inject.jl` — 새 주입기 하나만 담는다(단위검사가 데모를 돌리지 않고 include 할 수 있도록)
- Modify: `tools/monitor/run_demo.jl` — `zone_inject.jl` include + 호출부에 `DEMO_ZONE_FAMILY` 분기. **기존 `inject_blocking_zone!`(186행)은 이동도 수정도 하지 않는다**
- Create: `wm4spacecraft_manufacturing/oracle/test_forbidzone_injector.jl`

**Files (분기 B):**
- Modify: `wm4spacecraft_manufacturing/action_registry.json` (macro 3 의 `doc`)
- Modify: `wm4spacecraft_manufacturing/md/RESULTS_LLM7H.md` (§7 마지막 행)

**Interfaces:**
- Consumes: `oracle/out/fz_domain.csv` (Task 1), `CB.zone_diagnosis(env, key; check_restage=true)`
- Produces (분기 A): 환경변수 `DEMO_ZONE_FAMILY ∈ {nav, restage, auto}` — 기본 `nav`(= 기존 동작, §5 세계 보존). Task 5·6이 이 값을 쓴다.

#### 분기 A — `n_restage_feasible ≥ 1 ∧ n_nav_blocked ≥ 1` 인 행이 있었다

- [ ] **A-Step 1: 주입기 단위검사를 먼저 쓴다**

`wm4spacecraft_manufacturing/oracle/test_forbidzone_injector.jl` — `oracle/test_relocate_build.jl` 의 형식(`check(name, cond, detail)` + 실패 카운터 + 시뮬 없음)을 그대로 따른다. 다만 이 검사는 **씬이 필요하므로** 짧은 시뮬을 Task 1 이 찾은 `closed` 값까지만 돌린 뒤 한 번 검사한다.

```julia
# =============================================================================
# test_forbidzone_injector.jl -- restage-feasible 구역 주입기가 실제로 ForbidZone 도메인을
# 만드는지 검사한다. Task 1 의 fz_domain.csv 가 "존재한다"고 말한 그 진행도에서 확인한다.
#
#   FZ_AT=<closed>  검사할 발화점(기본은 fz_domain.csv 의 첫 hit). 필수는 아님.
#   julia +lts --project=. wm4spacecraft_manufacturing/oracle/test_forbidzone_injector.jl
# =============================================================================
```
본문(하네스는 `probe_forbidzone_domain.jl` 의 것을 재사용한다 — 같은 import 블록 + 큰 스택 Task):

```julia
const FZ_AT = parse(Int, get(ENV, "FZ_AT", "12"))   # fz_domain.csv 의 첫 hit 의 closed 값
const FAILED = Ref(0)
check(name, cond, detail = "") = (cond ? println("  PASS  $name") :
    (FAILED[] += 1; println("  FAIL  $name   $detail")))

# run_demo.jl 을 통째로 include 하면 데모가 돌아버린다. 주입기 함수만 필요하므로
# 그 함수 정의 블록을 이 파일에서 다시 평가한다 -- 두 곳이 갈리지 않도록 정의는
# run_demo.jl 을 단일 출처로 두고, 여기서는 include_string 으로 그 범위만 떼어 온다.
# (더 간단한 대안: 주입기를 tools/monitor/zone_inject.jl 로 빼고 양쪽에서 include.
#  이번에는 run_demo.jl 한 곳만 건드리는 쪽을 택했다 -- 태스크 3 의 surgical 원칙.)
include(joinpath(pkgdir(CB), "tools", "monitor", "zone_inject.jl"))
include(joinpath(@__DIR__, "ood_mdp_shim.jl"))

function probe_inject_once(env)
    nl = inject_restageable_blocking_zone!(env)
    check("주입기가 nl 을 돌려준다", nl !== nothing, "nothing = 후보를 못 찾음")
    nl === nothing && return nothing

    key = last(sort(collect(keys(CB.RESTRICTION_ZONES[])); by = string))
    d = CB.zone_diagnosis(env, key; check_restage = true)
    check("ForbidZone 도메인이 비어 있지 않다", d.n_restage_feasible >= 1,
          "n_restage_feasible=$(d.n_restage_feasible)")
    check("그 구역이 실제로 막는다", d.n_nav_blocked >= 1,
          "n_nav_blocked=$(d.n_nav_blocked)/$(d.n_nav_goals)")   # 덮임 != 막힘 (STEP 6/8)

    arms = _zone_arms_for((type = :zone, zone = key))            # shim 의 결정시점 팔 계산
    check("valid 팔에 3(ForbidZone) 이 들어온다", 3 in arms, "arms=$(arms)")

    tr = last(CB.ood_truth_log())
    check("ZoneTruth 가 대상 조립체를 지목한다", tr.truth.target !== nothing,
          "target=nothing 이면 '대상이 없어 조용히 NOOP' 구멍이 열린다")
    return nothing
end
```

> `_zone_arms_for` 의 인자 형태(`ctx`)와 `ood_truth_log()` 의 반환 형태는 `oracle/ood_mdp_shim.jl:194` 와 `src/navigator/ood_truth.jl` 을 읽어 맞춘다. 어긋나면 **테스트가 먼저 죽으므로** 조용히 틀리지 않는다.
>
> **주입기 정의를 어디 둘지**: 위 코드는 `tools/monitor/zone_inject.jl` 을 가정한다. A-Step 3 에서 주입기를 `run_demo.jl` 안에 쓰면 이 테스트가 그것을 볼 수 없다. **A-Step 3 을 먼저 읽고**, 새 함수를 `tools/monitor/zone_inject.jl` 에 두고 `run_demo.jl` 이 그 파일을 `include` 하도록 한다(기존 `inject_blocking_zone!` 은 이동하지 않는다 — 그 함수를 건드리지 않는 것이 A-Step 6 의 전제다).

- [ ] **A-Step 2: 실패를 확인한다**

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl
julia +lts --project=. wm4spacecraft_manufacturing/oracle/test_forbidzone_injector.jl
```
기대: `UndefVarError: inject_restageable_blocking_zone! not defined`.

- [ ] **A-Step 3: 주입기를 쓴다**

**새 파일** `tools/monitor/zone_inject.jl` 에 쓴다(단위검사가 데모 전체를 돌리지 않고 include 하기 위해서). `run_demo.jl` 의 기존 `inject_blocking_zone!`(186행)은 **한 글자도 고치지 않고 그 자리에 둔다** — §5 의 20판이 그 함수의 세계이고, 그 재현성이 Task 6 A/B 비교의 전제다. 파일 첫 줄에 그 이유를 적는다:

```julia
# =============================================================================
# zone_inject.jl -- ForbidZone 도메인을 갖는 구역 주입기.
#
# 왜 run_demo.jl 안이 아니라 별도 파일인가: 단위검사(oracle/test_forbidzone_injector.jl)가
# 데모를 통째로 돌리지 않고 이 함수만 include 할 수 있어야 한다. 기존 주입기
# (run_demo.jl::inject_blocking_zone!) 는 **옮기지 않는다** -- RESULTS_LLM7H §5 의 20판이
# 그 함수가 만든 세계이고, Task 6 의 A/B 비교가 그 재현성에 걸려 있다.
#
# 호출부: run_demo.jl 의 stream3 분기 (DEMO_ZONE_FAMILY=restage|auto 일 때만).
# 전제: 이 파일을 include 하는 쪽에 CB, DEMO_ZONE_R, _ZONE_CT 가 이미 정의돼 있다.
# =============================================================================
```

그 아래에 함수를 쓴다:

```julia
# ---- restage-feasible **하면서** 막는 구역 (2026-08-06) ------------------------------------
# 위 inject_blocking_zone! 은 후보를 `zone_relocatable`(=RelocateBuild 로 벗어날 Δ 가 있는가) 하나로만
# 거른다. ForbidZone(국소 재적치)의 도메인은 검사조차 안 하므로 zone 메뉴가 구조적으로 [NOOP,
# RelocateBuild] 였다 -- RESULTS_LLM7H §7 마지막 행의 `n_restage_feasible = 0` 이 그것이다.
#
# 도메인이 비는 진짜 이유는 "빌드 도중이라서"가 아니라 **발화점 붕괴**다: tractor 는 첫 시뮬 배치에서
# ~58 노드를 닫는데 restageable 집합은 closed≈46 부터 0 이므로(gen_oracle_dataset.jl:359),
# 진척 슬롯으로 잡은 "early" 가 전부 그 절벽 뒤에 떨어졌다(probe_forbidzone_domain.jl 로 재확인).
#
# 그래서 이 주입기는 **pristine 조립체의 적치원**을 겨냥하고, 심은 뒤 두 조건을 함께 확인한다:
#   n_restage_feasible >= 1  (ForbidZone 이 실제로 옮길 자리가 있다)
#   n_nav_blocked      >= 1  (그런데 실제로 막기도 한다 -- 덮임 != 막힘, STEP 6)
# 둘 중 하나라도 안 되면 지우고 다음 후보로 간다. 하나도 못 찾으면 nothing 을 돌려주고,
# 호출부는 기존 nav 가족으로 폴백한다(사건을 조용히 빠뜨리지 않는다).
function inject_restageable_blocking_zone!(env; frac = DEMO_ZONE_R)
    isempty(env.staging_circles) && return nothing
    r = frac * Float64(CB.default_robot_radius())
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])),
                  collect(keys(env.staging_circles)))
    # 결정적 정렬: root 에서 가까운 pristine 적치원부터(주입기가 시드에 따라 흔들리면 비교가 무효)
    c0 = Vector{Float64}(CB.get_center(env.staging_circles[root])[1:2])
    cand = [aid for (aid, _) in env.staging_circles if aid != root]
    sort!(cand; by = aid -> hypot(
        (Vector{Float64}(CB.get_center(env.staging_circles[aid])[1:2]) .- c0)...))
    _ZONE_CT[] += 1; key = Symbol("zone_fz_$(_ZONE_CT[])")
    for aid in cand
        c = Vector{Float64}(CB.get_center(env.staging_circles[aid])[1:2])
        z = CB.add_restriction_zone!(key, c, r)
        d = try CB.zone_diagnosis(env, key; check_restage = true) catch e
            @warn "[zone] zone_diagnosis 실패" exception = e; nothing
        end
        if d !== nothing && d.n_restage_feasible >= 1 && d.n_nav_blocked >= 1
            println("[zone] restageable blocking zone on $(aid) @$(round.(c; digits = 3)) " *
                    "r=$(round(r; digits = 3)) -> restage_feasible=$(d.n_restage_feasible) " *
                    "nav_blocked=$(d.n_nav_blocked)/$(d.n_nav_goals)")
            # 관찰만 남기고 "그러니 무엇을 하라"는 붙이지 않는다(STEP 4).
            nl = "A no-go exclusion zone has appeared at ($(round(c[1]; digits = 2)), " *
                 "$(round(c[2]; digits = 2))) with radius $(round(r; digits = 2)). " *
                 "Robots that enter the disc are pushed back out of it."
            try CB.record_ood_truth!(nl,
                CB.ZoneTruth(key, Float64[c[1], c[2]], Float64(CB.get_radius(z)),
                             first(d.feasible))) catch end
            return nl
        end
        CB.remove_restriction_zone!(key)
    end
    println("[zone] no restageable+blocking placement found")
    return nothing
end
```

- [ ] **A-Step 4: 호출부에 가족 스위치를 단다**

먼저 `run_demo.jl` 에서 새 파일을 올린다. `inject_blocking_zone!` 정의(186~219행) **바로 뒤**, `include(joinpath(@__DIR__, "policy.jl"))` **앞**에 한 줄:
```julia
include(joinpath(@__DIR__, "zone_inject.jl"))   # DEMO_ZONE_FAMILY=restage 용 주입기
```
(순서가 중요하다 — `zone_inject.jl` 이 `DEMO_ZONE_R`·`_ZONE_CT` 를 참조하므로 그 정의 뒤여야 한다.)

그 다음 stream3 분기(약 447행)에서 `inject_blocking_zone!(e)` 를 부르는 자리를:
```julia
                    local nl = inject_blocking_zone!(e)
```
→
```julia
                    # DEMO_ZONE_FAMILY: nav(기본, RESULTS_LLM7H §5 의 세계) / restage(ForbidZone 도메인
                    # 을 가진 구역) / auto(restage 먼저, 못 찾으면 nav 로 폴백).
                    # 기본이 nav 인 이유: §5 의 20판과 **같은 세계**를 유지해야 surrogate 재학습의
                    # A/B 가 성립한다. 세계와 모델을 한꺼번에 바꾸면 무엇이 원인인지 못 가른다.
                    local fam = lowercase(get(ENV, "DEMO_ZONE_FAMILY", "nav"))
                    local nl = if fam == "restage"
                        inject_restageable_blocking_zone!(e)
                    elseif fam == "auto"
                        # something(...) 을 쓰면 안 된다 -- 인자를 **먼저 전부 평가**하므로
                        # 두 주입기가 다 돌아 구역이 두 개 심긴다. 명시적 단락 평가로 쓴다.
                        local a = inject_restageable_blocking_zone!(e)
                        a === nothing ? inject_blocking_zone!(e) : a
                    else
                        inject_blocking_zone!(e)
                    end
```

- [ ] **A-Step 5: 단위검사를 통과시킨다**

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl
julia +lts --project=. wm4spacecraft_manufacturing/oracle/test_forbidzone_injector.jl
```
기대: 5/5 PASS.

- [ ] **A-Step 6: 기본 경로 불변 증명**

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl
DEMO_OOD=all DEMO_OOD_STREAM3=1 DEMO_N=4 DEMO_OOD_SEED=1 \
DEMO_POLICY=canonical DEMO_ROUTER=0 DEMO_SPARES=3 DEMO_REFORM=300 DEMO_REFORM_MAX=6 \
DEMO_SUMMARY="$PWD/wm4spacecraft_manufacturing/results/fam_nav_check.jsonl" \
  julia +lts --project=. tools/monitor/run_demo.jl 2>&1 | tail -20
```
`DEMO_ZONE_FAMILY` 를 **주지 않은** 이 실행의 요약이 §5 표의 `seed 1 / canonical` 행(complete, closed **291**, steps **2734**, 매크로 `Replace,Replace,NOOP,NOOP`)과 일치해야 한다. 어긋나면 기존 함수를 건드린 것이므로 되돌린다.

- [ ] **A-Step 7: 커밋**

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl
git add tools/monitor/zone_inject.jl tools/monitor/run_demo.jl \
        wm4spacecraft_manufacturing/oracle/test_forbidzone_injector.jl
git commit -m "feat(zone): ForbidZone 도메인을 갖는 구역 주입기 (DEMO_ZONE_FAMILY=restage)"
```

#### 분기 B — 조건을 만족하는 행이 하나도 없었다

ForbidZone 은 tractor 세계에서 **행동 불가능한 팔**이다. 코드를 늘리지 않고 그 사실을 적는다.

- [ ] **B-Step 1: `action_registry.json` 의 macro 3 `doc` 을 실측으로 교체한다**

```json
      "doc": "relocate the staging areas of the sub-assemblies blocked by a no-go zone. MEASURED DEAD ON THE TRACTOR TWIN (2026-08-06, oracle/out/fz_domain.csv): its domain (pristine, non-root assemblies whose staging circle a zone can cover) is non-empty only below closed~46, and no such zone also blocks a navigable goal -- so on this model the arm is byte-identical to NOOP wherever an event can fire. Kept in the vocabulary because the domain is model-dependent, not because it has ever acted here."
```

- [ ] **B-Step 2: 어휘 감사 + 기준 정책 검사**

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl/wm4spacecraft_manufacturing
python audit_action_vocab.py && python test_llm7h.py
```
기대: `6/6 consistent` · `16/16 passed`. (감사는 이름·비용만 보므로 `doc` 변경은 영향 없다 — 그 사실도 확인하는 것이다.)

- [ ] **B-Step 3: `RESULTS_LLM7H.md` §7 마지막 행을 교체한다**

기존:
> `ForbidZone` 팔의 실제 발화 | zone 8건 모두 `n_restage_feasible = 0` 이었다 = 국소 재적치 도메인이 비어 메뉴가 `[NOOP, RelocateBuild]` 였다. 데모의 구역이 **빌드 도중** 뜨기 때문이고, 이는 2026-08-03 부터 알려진 구조다. 공간 사건 자체는 매 판 발화한다

교체:
> `ForbidZone` 팔의 실제 발화 | **원인을 특정했고, 그 결과 이 팔은 이 세계에서 죽은 팔이다.** `probe_forbidzone_domain.jl` 이 closed 1~120 을 4 간격으로 훑어 `n_restage_feasible ≥ 1 ∧ n_nav_blocked ≥ 1` 인 (진행도, 배치) 를 **하나도** 찾지 못했다(`oracle/out/fz_domain.csv`). 이전 설명("빌드 도중이라서")은 절반만 맞았다 — restageable 집합은 closed≈46 에서 0 이 되는데, 그 앞 구간에서도 적치원을 덮는 구역이 항법 목표를 막지는 못한다. tractor 에서 공간 수복은 `RelocateBuild` 하나뿐이다

- [ ] **B-Step 4: 커밋**

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl
git add wm4spacecraft_manufacturing/action_registry.json \
        wm4spacecraft_manufacturing/md/RESULTS_LLM7H.md
git commit -m "docs(zone): ForbidZone 이 tractor 세계에서 행동 불가임을 실측으로 기록"
```

---

### Task 5: zone 팔교차 라벨 격자 — 매크로 7 학습 근거 (~2시간, 순차)

매크로 7 이 든 **완전한 instance 는 현재 0개**다. surrogate 가 zone 축에서 규칙과 갈리려면 그 행이 있어야 한다. 예산은 순차 ~2시간이므로 격자를 좁게 잡고, **모자란 것을 모자랐다고 적는다**.

**Files:**
- Create: `wm4spacecraft_manufacturing/oracle/run_fzgrid.ps1`
- Create (산출): `wm4spacecraft_manufacturing/oracle/out/fzgrid_0806/`

**Interfaces:**
- Consumes: `gen_oracle_dataset.jl` (`DS_EP_*` 환경변수 인터페이스), Task 1 의 발화점, Task 4 분기 A 의 `DEMO_ZONE_FAMILY`(라벨 경로는 별도 주입기를 쓰므로 직접 소비하지는 않는다 — 아래 주의)
- Produces: `oracle/out/fzgrid_0806/merged.jsonl` — 매크로 7 을 포함한 완전 instance

> **주의 — 주입기가 두 개다.** 라벨 경로는 `run_demo.jl` 이 아니라 `gen_oracle_dataset.jl::place_blocking_zone!`(334행)을 쓴다. 그 함수는 이미 `DS_ZONE_ELIGIBLE=restageable` 스위치를 갖고 있고, 그 주석이 D3 의 출처다. 따라서 Task 4 의 Julia 코드는 여기 필요 없고, **필요한 것은 발화점을 절벽 앞으로 옮기는 것**이다.

- [ ] **Step 1: 발화점이 실제로 어디에 떨어지는지 먼저 잰다 (1런, ~15분)**

라벨러의 발화점은 슬롯이 아니라 `closed` 카운터에 걸리므로, 요청한 값과 실제 값이 다르다(D2). 격자를 돌리기 전에 한 판으로 확인한다.

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl
DS_EPISODE_N=1 DS_EP_KINDS=zoneblk DS_VALID_ONLY=1 DS_EP_MACROS=0 \
DS_ZONE_DIAG=1 DS_ZONE_ELIGIBLE=restageable DS_SPARES=3 DS_NOPROG=8000 DS_NOCTRL=1 \
DS_REFORM=300 CARRIER_RESCUE=1 DS_HOTSWAP=1 DS_SEEDS=1 \
DS_EP_LO=4 DS_EP_HI=8 \
DS_OUT=wm4spacecraft_manufacturing/oracle/out/fzgrid_0806/probe_fire.jsonl \
  julia +lts --project=. wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl 2>&1 | tail -30
```
> `DS_EP_LO`/`DS_EP_HI` 는 `gen_oracle_dataset.jl:971-972` 의 실제 이름이다(기본 8/60). 이 값은 **요청한 구간**일 뿐이고, 사건이 실제로 due 되는 `closed` 는 시뮬 배치 경계에 붙는다(D2) — 그 차이를 재는 것이 이 Step 의 전부다.

그 뒤 실제 발화점을 읽는다:
```bash
cd wm4spacecraft_manufacturing && python -c "
import json
for ln in open('oracle/out/fzgrid_0806/probe_fire.jsonl',encoding='utf-8'):
    r=json.loads(ln)
    print('closed_at_fire',r.get('closed_at_fire'),'zone_blocked',r.get('zone_blocked'),
          'restage_feasible',r.get('zone_restage_feasible'),'valid_mask',r.get('valid_mask'))
"
```
**게이트:** `zone_restage_feasible >= 1` 이고 `valid_mask` 에 `3` 이 들어 있으면 진행한다. 아니면 **여기서 멈추고 Task 1 의 CSV 와 대조해 왜 다른지 적는다** — 두 주입기의 기하가 다르다는 뜻이고, 그건 라벨을 더 만든다고 해결되지 않는다.

- [ ] **Step 2: 격자 러너를 쓴다**

`wm4spacecraft_manufacturing/oracle/run_fzgrid.ps1` — `run_step6_zonegrid.ps1` 을 원형으로 하되 **세 가지를 바꾼다**:
1. `$Lanes = 1` 고정 (함정 30 — 팔 교차는 비교다)
2. `DS_ZONE_ELIGIBLE = "restageable"` (매크로 3 의 수리기와 주입 자격을 맞춘다)
3. 발화 구간을 Step 1 이 실측한 값으로 (요청값이 아니라 **도달값** 기준)

job 목록(예산 ~2시간, 런당 ~10분 가정 → 12런):
```powershell
# 발화점 2 x 팔 3(0,3,7) x seed 2 = 12 런. 순차. 예산 초과 시 seed 를 1개로 줄인다.
$Jobs = @()
foreach ($fire in @(@{tag="f1"; lo="4";  hi="8"},
                    @{tag="f2"; lo="20"; hi="28"})) {
    foreach ($s in @(1, 2)) {
        $Jobs += @{ tag = ("fz_{0}_s{1}" -f $fire.tag, $s); seed = $s; lo = $fire.lo; hi = $fire.hi }
    }
}
```
각 job 은 `DS_EP_MACROS="0,3,7"` 로 **세 팔을 한 프로세스 안에서** 돌린다(생성기가 팔 루프를 갖고 있다 — 1685·1745행). 즉 job 4개 × 3팔 = 12런이고 프로세스는 4개다.

`-MaxMinutes 120` 을 기본으로 두고, 초과하면 남은 job 을 건너뛰되 **건너뛴 목록을 stdout 에 찍는다**(조용한 절단 금지).

- [ ] **Step 3: 격자를 돌린다 (~2시간)**

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl
powershell -NoProfile -ExecutionPolicy Bypass \
  -File wm4spacecraft_manufacturing/oracle/run_fzgrid.ps1 -MaxMinutes 120
```

- [ ] **Step 4: 매크로 7 이 실제로 들어왔는지 확인한다**

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl/wm4spacecraft_manufacturing
python merge_labels.py --out oracle/out/fzgrid_0806/merged.jsonl \
    oracle/out/fzgrid_0806/fz_*.jsonl
python -c "
import sys; sys.path.insert(0,'.')
from e1_analyze import load, instance_arms_complete
df=load('oracle/out/fzgrid_0806/merged.jsonl'); df=df[df.fired==True]
full=[i for i,g in df.groupby('instance') if instance_arms_complete(g)]
d2=df[df.instance.isin(full)]
print('완전 instance', len(full), '매크로 지원', sorted({int(m) for m in d2.macro.unique()}))
print(d2.groupby(['instance','macro_name']).closed.first().to_string())
"
```
**성공 기준:** 완전 instance ≥ 2, 매크로 지원에 **7 포함**. 3 이 함께 들어오면 ForbidZone 축의 첫 라벨이다.
**부분 실패 시:** 매크로 7 만 있고 3 이 없어도 진행한다(§5-f 의 zone 축은 7 이 없어서 막힌 것이다). 그 사실을 적는다.

- [ ] **Step 5: 커밋**

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl
git add wm4spacecraft_manufacturing/oracle/run_fzgrid.ps1 \
        wm4spacecraft_manufacturing/oracle/out/fzgrid_0806/
git commit -m "labels: zone 팔교차 격자 -- 매크로 7(RelocateBuild) 의 첫 학습 근거"
```

---

### Task 6: Surrogate 재학습 ② + 재측정 + 문서 갱신

Task 3 이 battery 축을, Task 5 가 zone 축을 열었다. 이제 둘을 합쳐 배포 모델을 다시 적합하고, **§5 와 같은 세계에서** surrogate lane 만 다시 돌려 §5-f 를 반증한다.

**Files:**
- Modify: `wm4spacecraft_manufacturing/wm_datasets.py` (`N44_PLUS78` 추가)
- Modify: `wm4spacecraft_manufacturing/test_surrogate_support.py` (7 지원 검사 추가)
- Modify: `src/respec/llm_service/dspy_service.py` (기본 데이터셋)
- Modify: `wm4spacecraft_manufacturing/md/RESULTS_LLM7H.md` · `md/STATUS.md` · `.claude/CLAUDE.md`

**Interfaces:**
- Consumes: `wm_datasets.N44_PLUS8`(Task 3), `oracle/out/fzgrid_0806/merged.jsonl`(Task 5), `surrogate_data.load_training_frame`(Task 3)
- Produces: `oracle/out/n44_plus78.jsonl`, 갱신된 §5 표

- [ ] **Step 1: 최종 학습셋을 병합한다**

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl/wm4spacecraft_manufacturing
python merge_labels.py --out oracle/out/n44_plus78.jsonl \
    oracle/out/graded_hs_n44.jsonl \
    oracle/out/battgrid_0805_s1.jsonl \
    oracle/out/fzgrid_0806/merged.jsonl
```
instance id 충돌 에러가 나면 `--prefix` 를 쓰기 전에 **어느 파일끼리 겹치는지 출력을 읽는다**.

- [ ] **Step 2: 테스트에 매크로 7 계약을 추가한다**

`test_surrogate_support.py` 의 `wm_datasets.N44_PLUS8` 을 `wm_datasets.N44_PLUS78` 로 바꾸고, 마지막 `check(...)` 아래에 두 줄 추가:
```python
check("RelocateBuild(7) 학습 근거 있음", 7 in support, "support=%s" % sorted(support))
check("instance 수가 늘었다", n_inst >= 64, "n=%d (n44_plus8 은 62였다)" % n_inst)
```

- [ ] **Step 3: 데이터셋을 등록하고 배포 기본값을 옮긴다**

`wm_datasets.py`:
```python
# N44_PLUS78 — N44_PLUS8 + fzgrid_0806 (매크로 7 = RelocateBuild, 2026-08-06)
# 이 파일이 배포 surrogate 의 학습셋이 되면서 zone 사건에서 점수 낼 수 있는 팔이 처음으로
# 둘이 된다. 그 전까지 zone 메뉴는 [NOOP, RelocateBuild] 인데 지원이 {NOOP} 뿐이라
# surrogate 는 **언제나** NOOP 이었다(RESULTS_LLM7H §5-f 표).
N44_PLUS78 = "oracle/out/n44_plus78.jsonl"
```
`dspy_service.py` 의 `SURRO_DATA` 기본값을 `wm_datasets.N44_PLUS78` 로.

- [ ] **Step 4: 테스트 통과 + 지원 집합 확인**

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl/wm4spacecraft_manufacturing
python test_surrogate_support.py
python audit_action_vocab.py && python test_llm7h.py && python verify.py oracle/out/graded_hs_n44.jsonl 2>&1 | tail -3
```
기대: 지원 `[0,1,2,3,4,7,8]` (3 이 없으면 `[0,1,2,4,7,8]`), 어휘 6/6, `test_llm7h` 16/16, `verify.py` 8/8.

- [ ] **Step 5: 학습셋 교체가 결정을 바꾸는지 값싸게 먼저 본다 (시뮬 없음)**

20판을 돌리기 전에, 같은 사건에 대해 옛/새 모델의 랭킹이 실제로 갈리는지 확인한다.
```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl/wm4spacecraft_manufacturing
python -c "
import sys; sys.path.insert(0,'.')
import wm_datasets
from surrogate_data import load_training_frame
for name in ('HS_N44','N44_PLUS8','N44_PLUS78'):
    p = wm_datasets.resolve(None, default=getattr(wm_datasets, name))
    X,y,sup,n = load_training_frame(p)
    print('%-12s n=%3d support=%s' % (name, n, sorted(sup)))
"
```
`HS_N44` → `[0,1,2,3,4]`, `N44_PLUS78` → 7·8 포함이어야 한다. 안 그러면 아래 20판은 돌릴 가치가 없다.

- [ ] **Step 6: LLM 서비스를 띄운다**

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl/src/respec/llm_service
DSPY_MODEL=gpt-4o DSPY_PROGRAM=__seed_only__ \
  /c/Users/chahj/PythonCodes/venv/hjcrl/Scripts/python.exe -m uvicorn dspy_service:app --host 127.0.0.1 --port 8090
```
`DSPY_PROGRAM=__seed_only__` 는 필수다(컴파일된 프로그램은 zone 어휘가 없다).

- [ ] **Step 7: surrogate lane 만 다시 돌린다 (5런, 순차)**

**noop·canonical·dspy 는 다시 돌리지 않는다.** 규칙 정책과 LLM(temperature 0, 캐시 ON)은 이번 변경의 영향을 받지 않고, 세계도 `DEMO_ZONE_FAMILY` 기본값 `nav` 로 §5 와 동일하다. 바뀐 것은 surrogate 뿐이므로 **짝지은 비교의 한쪽만** 다시 잰다. `llm_ood_eval.py::load_rows` 는 같은 `(ood_seed, policy)` 의 **마지막 행**만 쓰므로 옛 행이 자동으로 대체된다.

먼저 재사용할 옛 행이 실제로 있는지 확인한다(2026-08-06 확인: 4정책 × 5시드 전부 존재):
```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl/wm4spacecraft_manufacturing
python -c "
import json, collections
c = collections.Counter(json.loads(l)['policy'] for l in open('results/llm_ood_eval.jsonl', encoding='utf-8'))
print(dict(c))
"
```
기대: `{'dspy': 5, 'noop': 5, 'canonical': 5, 'surrogate': 5}`. **noop/canonical/dspy 가 5개씩이 아니면 그 lane 도 함께 다시 돌려야 한다** — 없는 행을 그대로 두고 리포트를 내면 표가 조용히 다른 표본을 섞는다.

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl/wm4spacecraft_manufacturing
python llm_ood_eval.py run --seeds 1,2,3,4,5 --policies surrogate --dspy-url http://127.0.0.1:8090
```

- [ ] **Step 8: 리포트를 다시 만든다**

```bash
python llm_ood_eval.py report --json artifacts_llm7h/final.json --md artifacts_llm7h/results_table.md
cat artifacts_llm7h/results_table.md
```
**판정:** `canonical` vs `surrogate` 의 짝지은 비교가 더 이상 **5무**가 아니면 §5-f 는 반증된 것이다. 여전히 5무이면 그것도 결과다 — 그때는 로그의 `enacted`/`ranking` 을 읽어 surrogate 가 7·8 을 **점수는 냈으나 지지 않았는지**(= 모델이 그 팔을 나쁘게 본다) 아니면 **여전히 탈락했는지**(= 지원 집합이 안 들어갔다)를 가른다. 두 결론은 완전히 다르다.

- [ ] **Step 9: (Task 4 분기 A였다면) ForbidZone 가족을 스트림에서 한 판 본다**

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl
DEMO_OOD=all DEMO_OOD_STREAM3=1 DEMO_N=4 DEMO_OOD_SEED=1 DEMO_ZONE_FAMILY=restage \
DEMO_POLICY=dspy DEMO_ROUTER=0 DSPY_URL=http://127.0.0.1:8090 \
DEMO_SPARES=3 DEMO_REFORM=300 DEMO_REFORM_MAX=6 LLM_NL_MODE=observation \
DEMO_SUMMARY="$PWD/wm4spacecraft_manufacturing/results/fz_stream_s1.jsonl" \
  julia +lts --project=. tools/monitor/run_demo.jl 2>&1 | tail -30
```
요약의 zone 결정에서 `valid` 에 `ForbidZone` 이 들어 있는지 확인한다. **이것이 이 저장소에서 ForbidZone 이 메뉴에 오른 첫 기록이다.** n=1 이므로 결론이 아니라 존재 증명으로만 적는다.

- [ ] **Step 10: 문서를 갱신한다**

`md/RESULTS_LLM7H.md`:
- §5 표의 `surrogate` 행을 새 숫자로 (표는 `results_table.md` 에서 생성된 것을 옮긴다 — 손으로 계산하지 않는다)
- §5-f 를 **다시 쓴다**: 기전(어휘가 아니라 학습 근거)은 그대로 두고, "학습된 정책이 값을 하려면 (a) 7·8 팔이 들어간 라벨로 재적합" 이라고 적어둔 그 (a) 를 **실제로 했고 결과가 무엇이었는지** 이어 붙인다
- §7 마지막 행: Task 4 의 분기에 따라 (A) "발화 가능해졌다 + 첫 스트림 기록" 또는 (B) "죽은 팔임을 실측"
- §6 검사 표: `verify.py` **8/8**, 새 테스트 `test_surrogate_support.py` 추가
- §4 재현 절차: `EVAL_DATA` 기본값이 바뀐 사실

`md/STATUS.md` §0 표:
- "라우터 / novelty" 행의 "surrogate 재학습 후 …" 를 실제 상태로
- "행동 어휘 (Ch-A)" 행의 "오라클 생성기에 7팔 추가(Ch-D)" 를 완료로

`.claude/CLAUDE.md` 의 **기대 baseline** 절:
```
**기대 baseline(실패 아님):** `Pkg.test()` = 11 pass / **1 error**(Gurobi 라이선스 없음, 변경과 무관) ·
`verify.py` = **8/8**(2026-08-06 V0 을 valid_mask 기준으로 고친 뒤. 그 이전 문서의 "7/8"·"8/8" 은
서로 다른 판정이라 함께 인용하면 안 된다).
```
그리고 Gotchas 에 한 줄 추가:
```
- 배포 surrogate 의 **매크로 지원 집합**은 학습셋이 정한다(`wm_datasets.N44_PLUS78`). 지원 밖 팔은
  에러 없이 후보에서 탈락해 **성능으로만** 샌다 — `python test_surrogate_support.py` 가 그 계약이다.
```

- [ ] **Step 11: 전체 검사 + 커밋**

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl
julia +lts --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -20
cd wm4spacecraft_manufacturing
python audit_action_vocab.py && python test_llm7h.py && python test_surrogate_support.py
python verify.py oracle/out/graded_hs_n44.jsonl 2>&1 | tail -3
```
기대: Julia **11 pass / 1 error**(Gurobi) · 6/6 · 16/16 · surrogate 지원 PASS · **8/8**.
결과를 **그대로** 보고한다. "통과했다"가 아니라 명령과 출력을 적는다.

```bash
cd /c/Users/chahj/PythonCodes/venv/ConstructionBots.jl
git add wm4spacecraft_manufacturing/wm_datasets.py \
        wm4spacecraft_manufacturing/test_surrogate_support.py \
        wm4spacecraft_manufacturing/oracle/out/n44_plus78.jsonl \
        wm4spacecraft_manufacturing/artifacts_llm7h/ \
        wm4spacecraft_manufacturing/results/llm_ood_eval.jsonl \
        src/respec/llm_service/dspy_service.py \
        wm4spacecraft_manufacturing/md/RESULTS_LLM7H.md \
        wm4spacecraft_manufacturing/md/STATUS.md \
        .claude/CLAUDE.md
git commit -m "feat(surrogate): 매크로 7·8 학습 근거로 재적합 + 스트림 재측정"
```

---

## 이 계획이 하지 않는 것 (그리고 왜)

계획서에 없는 것을 나중에 "빠뜨렸다"고 읽지 않도록 여기 적는다.

| 안 하는 것 | 이유 |
|---|---|
| **Ch-E (자기일관성 K=5 · 기권 · risk–coverage)** | 사용자가 범위를 zone+surrogate 사슬로 한정했다. §5-e 의 2건이 표적이라는 근거는 그대로 유효하므로 **다음 plan** 의 첫 항목이다 |
| **반사실 오라클 기반 `optimal_action_rate`** | 스트림에서는 사건당 트리가 지수(사건 4 × 팔 4 = 256 런/시드). §3-b 의 기준 정책을 계속 쓰고, 표에 "반사실 오라클이 아니다"를 계속 적는다 |
| **zone 기준 규칙(n=2)의 재유도** | Task 5 가 라벨을 만들지만 ~2시간 예산으로는 instance 2~4개다. 규칙을 다시 쓰기에는 부족하고, **매크로 7 의 학습 근거**를 만드는 것이 이번 목적이다. `reference_policy.py` 의 zone 항은 손대지 않는다 |
| **부호검정 유의성** | 시드 5개에서 최소 p = 0.062. 5-0 완승이어도 p<0.05 는 원리적으로 불가능하다(함정 18). 방향과 효과 크기만 보고한다 |
| **`gen_oracle_dataset.jl::MACROS` 에 7 추가** | 기본 `MACROS` 를 바꾸면 `expected_arms`(1457행)가 바뀌어 **기존 덤프의 완전성 판정이 소급으로 흔들린다**. Task 5 는 `DS_EP_MACROS="0,3,7"` 로 필요한 자리에서만 넓힌다 |
| **`render_demo.jl` 동기화** | 덱 영상 4편의 녹화 경로다. 두 주입기의 절차가 갈렸다는 사실은 양쪽 주석에 이미 적혀 있고, Task 4 는 `run_demo.jl` 에 **새 함수를 추가**할 뿐 기존 함수를 바꾸지 않는다 |
| **battery 라벨 경로의 `SwapBattery` 정식화** | `gen_oracle_dataset.jl:1519` 의 episode 경로는 battery 에 `[0,1]`/`[0,2]` 만 준다 = 8 이 없다. `battgrid` 는 다른 경로로 만들어졌다. 이 구멍은 실재하지만 이번 사슬에는 필요 없다(라벨이 이미 있다) — **다음 plan 의 항목**으로 남긴다 |

## 실패 시 되돌리는 법

각 태스크가 독립 커밋이므로 `git revert <sha>` 로 하나씩 되돌릴 수 있다. 특히:

- **Task 3/6 의 학습셋 교체**를 되돌리지 않고 옛 모델을 재현하려면 `EVAL_DATA=oracle/out/graded_hs_n44.jsonl` 를 서비스에 준다.
- **Task 4 의 주입기**는 `DEMO_ZONE_FAMILY` 를 주지 않으면 기존 경로 그대로다(A-Step 6 이 그것을 증명한다).
- **Task 2 의 V0 변경**은 `verify.py` 단독 revert 로 충분하다.
