# 원거리 스페어 창고 + 4지표 결과 행렬 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 4방위 예비 로봇 창고를 빌드에서 멀리 떨어진 절대 좌표에 고정하고, 예비 로봇이 그 창고에 실제로 머물게 하며, 재생성되는 모든 결과 표에 평가지표 3종(성공률·빌드 시간·에너지)을 기록한다.

**Architecture:** 기존 구조를 바꾸지 않고 이음새 3개만 손댄다 — (1) 창고 좌표를 로봇 격자 bbox 기반에서 절대 좌표로, (2) 미파견 스페어를 분산 포텐셜장에서 제외하고 슬롯에 정박, (3) 이미 존재하는 `nearest_pool` 최근접 선정의 의미를 복원. 그 위에 창고 상태를 모니터 스트림·대시보드로 노출하고, 오라클 라벨에 빠져 있던 에너지 필드를 채운 뒤 7케이스×4컨트롤러 행렬 생성기를 만든다.

**Tech Stack:** Julia 1.10 (LTS), MeshCat, RVO2 via PyCall, Python 3 (numpy/scikit-learn), 브라우저 대시보드(순수 JS).

**설계 스펙:** `docs/superpowers/specs/2026-08-12-far-depots-and-metric-matrix-design.md`

## Global Constraints

- Julia는 반드시 **`julia +lts`** (1.10). `Manifest.toml`이 1.10.11에 고정돼 있고 상위 버전에서 `Pkg.add`하면 빌드가 조용히 깨진다. 모든 호출에 `--project=.`를 붙인다.
- **런은 절대 병렬로 돌리지 않는다.** `run_lego_demo`는 HiGHS MILP로 스케줄을 푸는데 CPU 경합이 다르면 다른 해가 나온다. 병렬 실행은 정책 비교가 아니라 서로 다른 두 세계의 비교가 된다(프로세스당 ~2.5GB, OOM 위험도 있다).
- 행동 어휘(`wm4spacecraft_manufacturing/action_registry.json`)를 **변경하지 않는다.** 매크로 추가·수정 없음. 리터럴 복붙 금지.
- 기대 기준선(실패 아님): `julia +lts --project=. -e 'using Pkg; Pkg.test()'` = **11 pass / 1 error**(Gurobi 라이선스 없음, 이 작업과 무관).
- 런타임 `include`로 로드되는 navigator/battery 모듈 관련 코드는 **모듈 최상위**에 둔다(world-age 에러 방지).
- 새로 생성하는 모든 런 요약·라벨 레코드에 `geometry = {depot_mode, depot_distance, station_keeping}` 블록을 남긴다. 이 저장소는 과거 세대가 섞인 산출물을 잘못 인용한 적이 있다(`.claude/CLAUDE.md` §결과 세대).
- 재생성이 끝나기 전에는 기존 수치를 현재 성능으로 인용하지 않는다.
- 모든 검증 단계는 **실행한 명령과 그 결과를 그대로 보고**한다("passed" / "failed with X" / "not run because Y").

## 알려진 충돌 — Task 10에서 판정한다

D3(배터리 심각도 분기)를 확정할 때 전제했던 "SoC ≤ 0.2 → 최근접 창고에서 실물 교체"는 **현재 기준 정책과 어긋난다.** 코드 추적 결과:

- `SwapBattery` 제안 → `swap_battery!`(`src/respec/replan.jl:631`) — 창고 본체를 쓰지 않는 현장 교체.
- `ReplaceAgent` 제안 → `hot_swap_robot!`(`src/respec/replan.jl:700`) → `nearest_pool` — 창고 소모.

즉 창고 소모 여부는 심각도가 아니라 **어떤 매크로를 골랐는가**로 갈린다. 그리고 현재
`wm4spacecraft_manufacturing/reference_policy.py:52-62`의 기준 행동은 깊은 방전(SoC ≤ 0.2)에서
`SwapBattery`를 정답으로 삼는다 — 두 팔이 똑같이 완주했으므로(closed 291 동일) 더 싼 쪽이 이긴다는
**측정 결과**에 근거한 규칙이다.

창고가 멀어지면 `Replace`의 주행 비용이 커지므로 이 규칙은 더 굳어질 수도, 뒤집힐 수도 있다.
**규칙을 손으로 정하지 않는다.** Task 9에서 새 기하로 격자를 다시 만들고, Task 10에서 그 격자로
`reference_policy.py`를 재유도해 판정한다. 그때까지 이 계획의 어떤 작업도 배터리 분기 규칙을
코드에 새로 박아 넣지 않는다.

## 파일 구조

| 파일 | 역할 | 이 계획에서의 변경 |
|---|---|---|
| `src/respec/ood_injection.jl` | 창고 저장소·기하·시각화 | 절대 좌표 knob, `depot_centers_fixed`, `SPARE_SLOTS`, `station_keeping_goal`, 클리어런스 경고 |
| `src/route_planning.jl` | 에이전트 트위스트 계산 | `get_twist_cmd` 안에 정박 조기탈출 3줄 |
| `src/ConstructionBots.jl` | 공개 API | 새 심볼 export |
| `src/monitor/monitor.jl` | 모니터 프레임 방출 | `depots` 필드 신설 |
| `tools/monitor/run_demo.jl` | 데모 드라이버·요약 | `geometry` provenance 블록 |
| `tools/monitor/dashboard.html` | 관제 UI | 창고 재고 패널 |
| `tools/monitor/verify_depot_station.py` | **신규** | 스트림 기반 정박 회귀 검증기 |
| `tools/checks.jl` | 경량 점검 실행기 | `depot_geometry`, `station_keeping` 점검 2종 |
| `tools/demos.jl` | 데모 모음 | 옛 margin knob → 새 distance knob |
| `src/full_demo.jl` | 빌드 파이프라인 | 창고 주입 호출부 정리 |
| `wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl` | 오라클 라벨 생성 | 에너지 필드 + provenance |
| `wm4spacecraft_manufacturing/results_matrix.py` | **신규** | 7케이스×4컨트롤러×4지표 행렬 생성 |

---

### Task 1: 절대 좌표 창고

**Files:**
- Modify: `src/respec/ood_injection.jl:439-470` (`add_directional_spare_pools!`), `:548-550` (knob 영역)
- Modify: `src/ConstructionBots.jl:127-133` (export 목록)
- Modify: `src/full_demo.jl:431-438` (호출부)
- Test: `tools/checks.jl` (신규 `check_depot_geometry`, `CHECKS` 등록)

**Interfaces:**
- Produces: `SPARE_DEPOT_DISTANCE::Ref{Float64}`, `spare_depot_distance() -> Float64`, `set_spare_depot_distance!(d::Real) -> Nothing`, `depot_centers_fixed(d::Real = SPARE_DEPOT_DISTANCE[]) -> Dict{Symbol,Vector{Float64}}`
- Consumes: 기존 `register_spare!`, `DEPOT_INFO`, `SPARE_POOL_CENTERS`, `default_robot_radius()`

- [ ] **Step 1: 실패하는 점검을 쓴다**

먼저 `tools/checks.jl:49`의 import 줄에 `CoordinateTransformations`를 더한다(현재 없어서 아래
점검이 `UndefVarError`로 죽는다).

```julia
import MeshCat, Logging, HiGHS, LinearAlgebra, CoordinateTransformations
```

그 다음 `check_hot_swap` 함수 정의 **뒤**에 아래 함수를 추가한다.

```julia
# [점검 내용] 절대 좌표 창고 기하: 4방위 중심이 (0,±D),(±D,0) 인지, 로봇 위치와 무관한지,
#   그리고 그 중심들로 nearest_pool 이 발생 좌표에서 올바른 방위를 고르는지(요구사항 2).
function check_depot_geometry()
npass = Ref(0); nfail = Ref(0)
check(msg, cond) = (cond ? (npass[] += 1; println("  PASS  $msg")) :
                           (nfail[] += 1; println("  FAIL  $msg")))

CB.clear_spare_pools!()
CB.set_spare_depot_distance!(30.0)
check("spare_depot_distance reflects the setter", CB.spare_depot_distance() == 30.0)

c = CB.depot_centers_fixed()
check("north center is (0, D)",  c[:north] == [0.0, 30.0])
check("south center is (0, -D)", c[:south] == [0.0, -30.0])
check("east center is (D, 0)",   c[:east]  == [30.0, 0.0])
check("west center is (-D, 0)",  c[:west]  == [-30.0, 0.0])

# 로봇을 한쪽으로 치우쳐 놓아도 창고 중심은 절대 좌표라 흔들리지 않아야 한다.
st = CB.SceneTree()
for xy in ([5.0, 5.0], [6.0, 5.5], [5.5, 6.0])
    rid = CB.get_unique_id(CB.RobotID)
    node = CB.add_node!(st, CB.RobotNode(rid, CB.GeomNode(CB.default_robot_geom())))
    CB.set_local_transform!(node,
        CoordinateTransformations.Translation(xy[1], xy[2], 0.0) ∘ CB.identity_linear_map())
end
CB.add_directional_spare_pools!(st; n_spare = 2)
check("placement ignores robot bbox (north)", CB.spare_pool_centers()[:north] == [0.0, 30.0])
check("placement ignores robot bbox (west)",  CB.spare_pool_centers()[:west]  == [-30.0, 0.0])
check("each pool holds 2 spares",
    all(length(CB.spare_pools()[k]) == 2 for k in (:north, :south, :east, :west)))

# 요구사항 2: 발생 좌표에서 직선거리가 가장 가까운 창고가 뽑혀야 한다.
check("fault at +x picks :east",  CB.nearest_pool([9.0, 0.5]) == :east)
check("fault at -y picks :south", CB.nearest_pool([0.5, -9.0]) == :south)
check("fault at -x picks :west",  CB.nearest_pool([-9.0, 0.5]) == :west)
check("fault at +y picks :north", CB.nearest_pool([0.5, 9.0]) == :north)

# 가장 가까운 창고가 비면 그 다음으로 가까운 창고가 응답해야 한다.
CB.pop_spare!(:east); CB.pop_spare!(:east)
np = CB.nearest_pool([9.0, 0.5]; nonempty = true)
check("drained :east falls through to another depot", np !== :east && np !== nothing)

CB.clear_spare_pools!()
println("\ndepot geometry check: $(npass[]) PASS / $(nfail[]) FAIL")
nfail[] == 0 || error("depot geometry check had $(nfail[]) failure(s)")
end
```

같은 파일 맨 아래 `CHECKS` 사전에 한 줄을 추가한다.

```julia
    "depot_geometry" => check_depot_geometry,
```

- [ ] **Step 2: 점검을 돌려 실패를 확인한다**

Run: `julia +lts --project=. tools/checks.jl depot_geometry`
Expected: FAIL — `UndefVarError: set_spare_depot_distance! not defined`

- [ ] **Step 3: 절대 좌표 knob과 중심 계산을 만든다**

`src/respec/ood_injection.jl`의 `const SPARE_POOL_MARGIN_FACTOR = Ref(6.0)` (파일 내 knob 영역) **바로 아래**에 추가한다.

```julia
# 창고를 놓을 절대 거리 D (world 단위). 4방위 중심 = (0,±D),(±D,0).
# bbox 기반이던 옛 방식은 로봇 시작 격자만 보고 margin 을 붙여서, 적치 계획이 서기 전에
# 창고를 놓는 구조 탓에 창고가 빌드 안쪽에 박혔다. 절대 좌표는 그 순서 의존을 없앤다.
const SPARE_DEPOT_DISTANCE = Ref(25.0)
spare_depot_distance() = SPARE_DEPOT_DISTANCE[]
set_spare_depot_distance!(d::Real) = (SPARE_DEPOT_DISTANCE[] = Float64(d); nothing)

"""
    depot_centers_fixed(d = SPARE_DEPOT_DISTANCE[]) -> Dict{Symbol,Vector{Float64}}

원점 기준 절대 좌표 4방위 창고 중심. 씬 내용과 무관하다(= 호출 시점 의존이 없다).
"""
depot_centers_fixed(d::Real = SPARE_DEPOT_DISTANCE[]) = Dict(
    :north => [0.0,  Float64(d)],
    :south => [0.0, -Float64(d)],
    :east  => [Float64(d), 0.0],
    :west  => [-Float64(d), 0.0])
```

같은 파일의 `set_spare_pool_margin!` 정의를 아래로 교체한다(삭제하지 않는다 — `tools/checks.jl:236-243`의 `check_spare_pool`이 `pool_centers`를 계속 쓴다).

```julia
# 옛 knob. 절대 좌표 모드에서는 창고 위치에 영향을 주지 않는다(1회만 경고).
const _SPARE_MARGIN_DEPRECATED = Ref(false)
function set_spare_pool_margin!(factor::Real)
    SPARE_POOL_MARGIN_FACTOR[] = Float64(factor)
    if !_SPARE_MARGIN_DEPRECATED[]
        _SPARE_MARGIN_DEPRECATED[] = true
        @warn "set_spare_pool_margin! 는 절대좌표 창고에서 무시된다. set_spare_depot_distance!(d) 를 쓸 것."
    end
    return nothing
end
```

`add_directional_spare_pools!`의 시그니처와 첫 줄을 교체한다. `bbox`/`margin` 키워드는 외부
호출자 호환을 위해 **받되 무시**한다.

```julia
function add_directional_spare_pools!(scene_tree;
        n_spare::Int = 2,                                  # 방위당 예비 로봇 수
        distance::Real = SPARE_DEPOT_DISTANCE[],           # 원점에서 창고까지의 절대 거리 D
        bbox = nothing,                                    # (무시됨: 절대 좌표 모드)
        margin::Real = 0,                                  # (무시됨: 절대 좌표 모드)
        geom = default_robot_geom(),                       # 예비 로봇 형상
        spacing::Real = 3 * default_robot_radius())        # 클러스터 내 로봇 간격
    centers = depot_centers_fixed(distance)
```

(`for (key, c) in centers` 이하 본문은 그대로 둔다.)

- [ ] **Step 4: 새 심볼을 export 한다**

`src/ConstructionBots.jl`의 `pool_centers, nearest_pool, add_directional_spare_pools!,` 줄 **바로 아래**에 추가한다.

```julia
       spare_depot_distance, set_spare_depot_distance!, depot_centers_fixed,  # 절대좌표 창고 거리 knob + 중심 계산
```

- [ ] **Step 5: 호출부를 정리한다**

`src/full_demo.jl:433-436`을 교체한다.

```julia
        ConstructionBots.add_directional_spare_pools!(scene_tree;
            n_spare=n_spare_per_pool,
            spacing=3*robot_radius)
```

- [ ] **Step 6: 점검을 돌려 통과를 확인한다**

Run: `julia +lts --project=. tools/checks.jl depot_geometry`
Expected: PASS — `depot geometry check: 13 PASS / 0 FAIL`

- [ ] **Step 7: 기존 점검이 안 깨졌는지 확인한다**

Run: `julia +lts --project=. tools/checks.jl spare_pool`
Expected: PASS (기존 `pool_centers` 단위검사는 그대로 통과해야 한다)

- [ ] **Step 8: 커밋**

```bash
git add src/respec/ood_injection.jl src/ConstructionBots.jl src/full_demo.jl tools/checks.jl
git commit -m "feat(depot): 예비 창고를 절대 좌표 (0,±D),(±D,0) 에 고정"
```

---

### Task 2: 모니터 스트림에 창고 상태 노출

**Files:**
- Modify: `src/monitor/monitor.jl:474-490` (`frame` Dict), `:487-489` (`handoffs`)
- Modify: `src/respec/replace_robot.jl:1484` (`HOT_SWAP_ASSETS` 기록)
- Modify: `tools/monitor/run_demo.jl:618-660` (요약 레코드)

**Interfaces:**
- Consumes: Task 1의 `spare_depot_distance()`; 기존 `spare_pools()`, `spare_pool_centers()`, `depot_info()`
- Produces: 스트림 프레임의 `depots` 배열 — 원소는 `{"side": String, "center": [x,y], "available": Int, "capacity": Int, "spares": [String]}`. Task 3의 `verify_depot_station.py`와 Task 5의 대시보드가 이 스키마를 읽는다.
- Produces: 요약 레코드의 `geometry` 객체 — `{"depot_mode": "fixed", "depot_distance": Float, "station_keeping": Bool}`. Task 7의 `results_matrix.py`가 이 키로 세대를 판별한다.

- [ ] **Step 1: 프레임에 창고 블록을 추가한다**

`src/monitor/monitor.jl`의 `frame = Dict{String,Any}(...)` 리터럴 **뒤**, `fleet = _mon_fleet()` **앞**에 추가한다.

```julia
    # 창고(depot) 상태: 중심 좌표 + 남은 재고 + 그 창고에 아직 주차된 예비 id.
    # 이게 없으면 대시보드가 "어느 창고가 응답했는지"를 보여줄 방법이 없고, 정박 회귀
    # 검증기(verify_depot_station.py)도 무엇을 검사해야 할지 알 수 없다.
    let centers = try spare_pool_centers() catch; Dict{Symbol,Vector{Float64}}() end,
        pools = try spare_pools() catch; Dict{Symbol,Vector{Any}}() end,
        info = try depot_info() catch; Dict{Symbol,NamedTuple}() end
        if !isempty(centers)
            frame["depots"] = [Dict{String,Any}(
                "side"      => String(side),
                "center"    => [_mon_finite(c[1]), _mon_finite(c[2])],
                "available" => length(get(pools, side, [])),
                "capacity"  => (haskey(info, side) ? info[side].capacity : -1),
                "spares"    => [string(r) for r in get(pools, side, [])],
            ) for (side, c) in centers]
        end
    end
```

- [ ] **Step 2: 교체 사건에 응답한 창고를 싣는다**

`src/respec/replace_robot.jl`의 `HOT_SWAP_ASSETS[][faulted] = (spare=spare, ...)` 대입을 아래로
교체한다(어느 창고가 응답했는지가 지금은 로그에만 있고 구조화된 기록에는 없다).

```julia
    HOT_SWAP_ASSETS[][faulted] = (spare=spare, failed_soc=failed_soc,
                                  position=Vector{Float64}(pos), cause=cause, depot=key)
```

`src/monitor/monitor.jl`의 `handoffs` 항목에 방위를 더한다.

```julia
        "handoffs"   => [Dict("failed"=>string(rid), "spare"=>string(info.spare),
                              "at"=>MONITOR_HANDOFF_T[rid], "failed_soc"=>info.failed_soc,
                              "depot"=>string(hasproperty(info, :depot) ? info.depot : ""))
                         for (rid, info) in swaps],
```

- [ ] **Step 3: 요약에 provenance 를 추가한다**

`tools/monitor/run_demo.jl`의 요약 레코드에서 `"stream" => stream_path)` 줄 **바로 앞**에 추가한다.

```julia
            # 기하 세대(provenance). 창고 배치가 바뀌면 makespan·에너지가 전부 달라지므로,
            # 이 블록 없이 서로 다른 세대의 런을 한 표에 섞으면 조용히 틀린 비교가 된다.
            "geometry" => Dict("depot_mode" => "fixed",
                               "depot_distance" => CB.spare_depot_distance(),
                               "station_keeping" => true),
```

- [ ] **Step 4: 짧은 런으로 필드가 실제로 나오는지 확인한다**

Run:
```bash
DEMO_MODEL=tractor.mpd DEMO_OOD=battery DEMO_POLICY=canonical DEMO_SPARES=2 \
DEMO_SEED=1 DEMO_OOD_SEED=1 \
MONITOR_STREAM=tools/monitor/streams/_probe_depots.jsonl \
DEMO_SUMMARY=tools/monitor/streams/_probe_summary.jsonl \
julia +lts --project=. tools/monitor/run_demo.jl
```

Expected: 완료 후 아래 확인 명령이 4개 창고와 `geometry` 블록을 찍는다.

```bash
python -c "
import json
f=[json.loads(l) for l in open('tools/monitor/streams/_probe_depots.jsonl',encoding='utf-8')]
print('depots in frame0:', json.dumps(f[0].get('depots'), ensure_ascii=False))
s=[json.loads(l) for l in open('tools/monitor/streams/_probe_summary.jsonl',encoding='utf-8')]
print('geometry:', s[-1].get('geometry'))
"
```

Expected 출력: `depots` 가 4개 원소(side 각 north/south/east/west, center 가 (0,±25)/(±25,0)),
`geometry` 가 `{'depot_mode': 'fixed', 'depot_distance': 25.0, 'station_keeping': True}`.

- [ ] **Step 5: 확인용 산출물을 지운다**

```bash
rm -f tools/monitor/streams/_probe_depots.jsonl tools/monitor/streams/_probe_summary.jsonl
```

- [ ] **Step 6: 커밋**

```bash
git add src/monitor/monitor.jl src/respec/replace_robot.jl tools/monitor/run_demo.jl
git commit -m "feat(monitor): 스트림에 창고 재고/중심/응답 방위와 기하 provenance 를 남긴다"
```

---

### Task 3: 정박 — 스페어가 창고에 머문다

**Files:**
- Modify: `src/respec/ood_injection.jl` (`SPARE_SLOTS`, `station_keeping_goal`, `clear_spare_pools!`, `add_directional_spare_pools!` 본문)
- Modify: `src/route_planning.jl:1020` (`get_twist_cmd` 안)
- Modify: `src/ConstructionBots.jl` (export)
- Create: `tools/monitor/verify_depot_station.py`
- Test: `tools/checks.jl` (신규 `check_station_keeping`)

**Interfaces:**
- Consumes: Task 1의 `depot_centers_fixed`; Task 2의 스트림 `depots` 스키마
- Produces: `SPARE_SLOTS::Ref{Dict{AbstractID,Vector{Float64}}}`, `spare_slots() -> Dict`, `station_keeping_goal(rid) -> Union{Vector{Float64},Nothing}` (미파견 스페어면 슬롯 2D 좌표, 아니면 `nothing`)

- [ ] **Step 1: 실패하는 점검을 쓴다**

`tools/checks.jl`에 `check_depot_geometry` 뒤로 추가한다.

```julia
# [점검 내용] 정박(station-keeping): 스페어마다 슬롯 좌표가 기록되는지, station_keeping_goal 이
#   미파견 스페어에만 슬롯을 주고 파견(pop) 후에는 nothing 을 주는지(= 파견 로봇은 정상 주행 복귀).
function check_station_keeping()
npass = Ref(0); nfail = Ref(0)
check(msg, cond) = (cond ? (npass[] += 1; println("  PASS  $msg")) :
                           (nfail[] += 1; println("  FAIL  $msg")))

CB.clear_spare_pools!()
CB.set_spare_depot_distance!(25.0)
st = CB.SceneTree()
ids = CB.add_directional_spare_pools!(st; n_spare = 2)

check("a slot is recorded for every spare",
    all(haskey(CB.spare_slots(), r) for v in values(ids) for r in v))
check("slot count equals spare count", length(CB.spare_slots()) == 8)

east1 = ids[:east][1]
slot = CB.station_keeping_goal(east1)
check("station_keeping_goal returns a 2D slot for a parked spare",
    slot !== nothing && length(slot) == 2)
check("the east slot sits on the east depot (x = D)", slot[1] == 25.0)
check("the slot matches the recorded body position",
    slot == CB.spare_slots()[east1])

# 파견되면(풀에서 제거되면) 더 이상 정박 대상이 아니다.
while CB.is_spare(east1); CB.pop_spare!(:east); end
check("a dispatched spare is no longer station-kept",
    CB.station_keeping_goal(east1) === nothing)

rid_other = CB.get_unique_id(CB.RobotID)
check("a non-spare robot is never station-kept",
    CB.station_keeping_goal(rid_other) === nothing)

CB.clear_spare_pools!()
check("clear_spare_pools! empties the slot store", isempty(CB.spare_slots()))

println("\nstation-keeping check: $(npass[]) PASS / $(nfail[]) FAIL")
nfail[] == 0 || error("station-keeping check had $(nfail[]) failure(s)")
end
```

`CHECKS` 사전에 추가한다.

```julia
    "station_keeping" => check_station_keeping,
```

- [ ] **Step 2: 점검을 돌려 실패를 확인한다**

Run: `julia +lts --project=. tools/checks.jl station_keeping`
Expected: FAIL — `UndefVarError: spare_slots not defined`

- [ ] **Step 3: 슬롯 저장소와 술어를 만든다**

`src/respec/ood_injection.jl`의 `const SPARE_POOL_CENTERS = ...` 줄 **아래**에 추가한다.

```julia
# 예비 로봇별 "주차 슬롯" 절대 좌표. 창고 중심이 아니라 그 로봇이 실제로 서 있어야 할 자리다
# (한 창고에 여러 대가 줄지어 서므로 중심과 다르다).
const SPARE_SLOTS = Ref(Dict{AbstractID,Vector{Float64}}())
spare_slots() = SPARE_SLOTS[]

"""
    station_keeping_goal(rid) -> Union{Vector{Float64},Nothing}

`rid` 가 **아직 파견되지 않은** 예비 로봇이면 그 주차 슬롯 좌표, 아니면 `nothing`.
`pop_spare!` 가 풀에서 빼는 순간 `is_spare` 가 false 가 되므로, 파견된 로봇은 별도 플래그 없이
자동으로 정상 주행으로 돌아온다.
"""
station_keeping_goal(rid) = (is_spare(rid) ? get(SPARE_SLOTS[], rid, nothing) : nothing)
```

같은 파일의 `clear_spare_pools!` 정의에서 `empty!(SPARE_POOL_CENTERS[]);` 뒤에 `empty!(SPARE_SLOTS[]);` 를 추가한다.

`add_directional_spare_pools!` 본문의 `register_spare!(key, rid)` 줄 **바로 아래**에 추가한다.

```julia
            SPARE_SLOTS[][rid] = Float64[pos[1], pos[2]]   # 이 로봇이 지켜야 할 주차 자리
```

- [ ] **Step 4: export 한다**

`src/ConstructionBots.jl`의 Task 1에서 추가한 줄 아래에 추가한다.

```julia
       SPARE_SLOTS, spare_slots, station_keeping_goal,                        # 정박(station-keeping) 슬롯 저장소/술어
```

- [ ] **Step 5: 점검을 돌려 통과를 확인한다**

Run: `julia +lts --project=. tools/checks.jl station_keeping`
Expected: PASS — `station-keeping check: 8 PASS / 0 FAIL`

- [ ] **Step 6: 분산 포텐셜장에서 스페어를 빼낸다**

`src/route_planning.jl`의 `get_twist_cmd` 안, `policy = agent_policies[node_id(agent)].dispersion_policy` 줄 **바로 아래**에 추가한다.

```julia
        # 미파견 스페어는 창고 슬롯에 정박시킨다. 이 줄이 없으면 유휴 스페어는
        # `!(build_step_active && ready_for_pickup)` 에 영구히 걸려 분산 포텐셜장에 계속 밀리고,
        # 결국 창고를 떠나 한쪽 구석에 어깨를 맞대고 정체한다(2026-08-12 스트림 실측).
        # policy 를 nothing 으로 만들면 아래 포텐셜장 블록이 통째로 건너뛰어진다.
        slot = station_keeping_goal(node_id(agent))
        if slot !== nothing
            policy = nothing
            spos = project_to_2d(global_transform(agent).translation)
            if norm(spos .- slot) <= default_robot_radius()
                twist = Twist(0.0 * twist.vel, twist.ω)          # 슬롯 안 → 정지
            else
                slot_goal = CoordinateTransformations.Translation(slot[1], slot[2], 0.0) ∘
                            identity_linear_map()
                twist = compute_twist_from_goal(agent, slot_goal, dt)   # 슬롯으로 복귀
            end
        end
```

- [ ] **Step 7: 스트림 기반 회귀 검증기를 만든다**

Create `tools/monitor/verify_depot_station.py`:

```python
#!/usr/bin/env python3
"""verify_depot_station.py -- 파견되지 않은 예비 로봇이 자기 창고를 지켰는지 스트림으로 검증한다.

이 검사가 존재하는 이유: 유휴 스페어도 RVO 에이전트라, 분산 포텐셜장에 밀려 창고를 떠나
한쪽 구석에 정체하던 버그가 있었다(2026-08-12). 그 버그는 단위검사로는 안 잡히고 오직
"오래 돌린 뒤의 위치"로만 드러난다.

사용법:
    python tools/monitor/verify_depot_station.py <stream.jsonl> [--tol 1.0]

허용오차 tol 의 기본값 1.0 은 창고 패드 반폭(halfw)을 넉넉히 덮는 값이다. 창고에 주차된
로봇은 패드 안에 있어야 하므로, 이보다 크게 벗어나면 정박이 깨진 것이다.
종료코드 0 = 통과, 1 = 위반.
"""
import json
import math
import sys


def main(argv):
    if not argv:
        print("usage: verify_depot_station.py <stream.jsonl> [--tol T]")
        return 2
    path = argv[0]
    tol = 1.0
    if "--tol" in argv:
        tol = float(argv[argv.index("--tol") + 1])

    frames = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                frames.append(json.loads(line))
    if not frames:
        print("FAIL  empty stream: %s" % path)
        return 1
    if "depots" not in frames[0]:
        print("FAIL  stream has no 'depots' field -- regenerate it after Task 2")
        return 1

    violations = []
    n_checked = 0
    for fi, fr in enumerate(frames):
        pos = {r["id"]: r["pos"] for r in fr.get("robots", []) if r.get("pos")}
        for depot in fr.get("depots", []):
            cx, cy = depot["center"]
            for rid in depot.get("spares", []):
                p = pos.get(rid)
                if p is None:          # 창고에 있으나 프레임에 위치가 없으면 검사 불가
                    continue
                n_checked += 1
                d = math.hypot(p[0] - cx, p[1] - cy)
                if d > tol:
                    violations.append((fi, depot["side"], rid, round(d, 2)))

    if n_checked == 0:
        print("FAIL  no parked spare was observed -- nothing was verified")
        return 1
    if violations:
        print("FAIL  %d/%d parked-spare observations drifted beyond tol=%.2f" %
              (len(violations), n_checked, tol))
        for v in violations[:10]:
            print("      frame %d  depot :%s  robot %s  dist %.2f" % v)
        return 1
    print("PASS  %d parked-spare observations, all within tol=%.2f of their depot" %
          (n_checked, tol))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

- [ ] **Step 8: 실제 런으로 정박을 확인한다**

Run:
```bash
DEMO_MODEL=tractor.mpd DEMO_OOD=battery DEMO_POLICY=canonical DEMO_SPARES=2 \
DEMO_SEED=1 DEMO_OOD_SEED=1 \
MONITOR_STREAM=tools/monitor/streams/_probe_station.jsonl \
julia +lts --project=. tools/monitor/run_demo.jl
python tools/monitor/verify_depot_station.py tools/monitor/streams/_probe_station.jsonl
```

Expected: `PASS  <n> parked-spare observations, all within tol=1.00 of their depot`

수정 전 코드에서는 이 검사가 반드시 실패한다. 확신이 서지 않으면 Step 6의 블록을 잠시
주석 처리하고 같은 명령을 돌려 FAIL 이 나오는지 확인한 뒤 되돌린다(회귀 검사가 진짜로
그 버그를 잡는지 증명하는 절차다).

- [ ] **Step 9: 확인용 산출물을 지운다**

```bash
rm -f tools/monitor/streams/_probe_station.jsonl
```

- [ ] **Step 10: 커밋**

```bash
git add src/respec/ood_injection.jl src/route_planning.jl src/ConstructionBots.jl \
        tools/checks.jl tools/monitor/verify_depot_station.py
git commit -m "fix(depot): 미파견 스페어를 창고 슬롯에 정박시켜 분산 드리프트를 막는다"
```

---

### Task 4: 클리어런스 경고 + 옛 knob 이관

**Files:**
- Modify: `src/respec/ood_injection.jl` (신규 `warn_depot_clearance`)
- Modify: `src/full_demo.jl` (시뮬 시작 전 1회 호출)
- Modify: `tools/demos.jl:1576`, `tools/demos.jl:2754`

**Interfaces:**
- Consumes: Task 1의 `spare_depot_distance()`
- Produces: `warn_depot_clearance(env) -> Float64` (계산한 빌드 footprint 반경을 돌려준다)

- [ ] **Step 1: 클리어런스 경고 함수를 만든다**

`src/respec/ood_injection.jl`의 `depot_centers_fixed` 아래에 추가한다.

```julia
"""
    warn_depot_clearance(env) -> Float64

빌드 footprint 반경(원점에서 각 적치원의 `center + radius`, 그리고 각 로봇/부품 노드의 전역
위치까지의 거리 중 최댓값)을 구해, 창고 거리 D 가 그 1.2배보다 작으면 경고한다. **자동 조정은
하지 않는다** — 절대 좌표 고정이라는 선택을 코드가 뒤집으면 안 된다. 반환값은 계산한 반경.
"""
function warn_depot_clearance(env)
    r = 0.0
    for (_, c) in env.staging_circles
        r = max(r, norm(Float64[get_center(c)[1], get_center(c)[2]]) + Float64(get_radius(c)))
    end
    for node in get_nodes(env.scene_tree)
        t = try global_transform(node).translation catch; continue end
        r = max(r, norm(Float64[t[1], t[2]]))
    end
    d = spare_depot_distance()
    d < 1.2 * r && @warn "창고 거리 D 가 빌드 footprint 안쪽에 가깝다 — 창고가 빌드에 겹칠 수 있다" D=d footprint_radius=round(r; digits=2)
    return r
end
```

`src/ConstructionBots.jl`의 export 목록(Task 3에서 추가한 줄 아래)에 추가한다.

```julia
       warn_depot_clearance,                                                  # 창고-빌드 간격 경고(자동 조정 없음)
```

- [ ] **Step 2: 시뮬 시작 전에 1회 호출한다**

`src/full_demo.jl`에서 `env = PlannerEnv(` 로 만들어진 `env` 가 완성된 직후(그 블록이 끝나는
지점, 시뮬레이션 루프 시작 전)에 한 줄을 넣는다.

```julia
    ConstructionBots.warn_depot_clearance(env)   # 창고가 빌드 안쪽인지 1회 점검(경고만)
```

- [ ] **Step 3: 옛 knob 호출을 새 knob 으로 바꾼다**

옛 `SPARE_MARGIN` 은 `robot_radius` 배수였고 새 knob 은 절대 거리다. 의미가 달라졌으므로 환경변수
이름도 `SPARE_DEPOT_DIST` 로 통일한다.

`tools/demos.jl:1575-1576` 두 줄을 교체한다.

```julia
SPARE_DEPOT_D = parse(Float64, get(ENV, "SPARE_DEPOT_DIST", "25.0"))  # 원점에서 창고까지 절대 거리  # 창고를 빌드에서 얼마나 멀리
CB.set_spare_depot_distance!(SPARE_DEPOT_D)       # park the depots FAR from the build (visible re-emergence)  # 예비가 멀리서 등장해 눈에 띔
```

`tools/demos.jl:2754` 를 교체한다.

```julia
CB.set_spare_depot_distance!(parse(Float64, get(ENV, "SPARE_DEPOT_DIST", "25.0")))
```

`tools/demos.jl:1547` 과 `:1553` 의 환경변수 목록 주석에서 `SPARE_MARGIN` 을 `SPARE_DEPOT_DIST` 로
바꾼다. 그리고 `grep -n 'SPARE_MARGIN' tools/demos.jl` 로 남은 참조가 없는지 확인한다(0건이어야 한다).

- [ ] **Step 4: 데모 드라이버에도 knob 을 붙인다**

`tools/monitor/run_demo.jl` 은 아직 이 knob 을 읽지 않는다. `run_lego_demo` 를 호출하는 줄
(`env = CB.run_lego_demo(...)`, 현재 385행) **바로 앞**에 추가한다. Task 8의 D 스윕이 이 줄에 의존한다.

```julia
haskey(ENV, "SPARE_DEPOT_DIST") &&
    CB.set_spare_depot_distance!(parse(Float64, ENV["SPARE_DEPOT_DIST"]))
```

- [ ] **Step 5: 로드가 깨지지 않았는지 확인한다**

Run: `julia +lts --project=. tools/checks.jl load`
Expected: PASS

Run: `julia +lts --project=. tools/checks.jl depot_geometry`
Expected: PASS

- [ ] **Step 6: 커밋**

```bash
git add src/respec/ood_injection.jl src/ConstructionBots.jl src/full_demo.jl \
        tools/demos.jl tools/monitor/run_demo.jl
git commit -m "feat(depot): 창고-빌드 간격 경고 추가 + 옛 margin knob 을 거리 knob 으로 이관"
```

---

### Task 5: 대시보드 창고 재고 패널

**Files:**
- Modify: `tools/monitor/dashboard.html:350` (마크업), `:948` (호출), `:987` 앞(렌더 함수)

**Interfaces:**
- Consumes: Task 2의 프레임 `depots` 스키마

- [ ] **Step 1: 마크업을 추가한다**

`tools/monitor/dashboard.html:350` 의 `<div class="body" id="fleetBody">...</div>` 줄 **바로 위**에 추가한다.

```html
    <div class="body" id="depotBody" style="border-bottom:1px solid #e5e5e5;padding:6px 8px"><div class="empty">no depots</div></div>
```

- [ ] **Step 2: 렌더 함수를 추가한다**

`function renderFleet(robots){` **바로 위**에 추가한다.

```javascript
  /* 4방위 창고 재고. 응답 직후(재고가 줄어든 창고)를 눈에 띄게 하려고 available==0 을 흐리게 표시한다. */
  function renderDepots(depots){
    var el = $("depotBody");
    if(!depots || !depots.length){ el.innerHTML = '<div class="empty">no depots</div>'; return; }
    var order = {north:0, east:1, south:2, west:3};
    var sorted = depots.slice().sort(function(a,b){ return (order[a.side]||9)-(order[b.side]||9); });
    var h = '<div class="mono" style="display:flex;gap:10px;flex-wrap:wrap;font-size:11px">';
    sorted.forEach(function(d){
      var dim = (d.available === 0) ? ';opacity:.45' : '';
      h += '<span title="center ('+d.center[0].toFixed(1)+', '+d.center[1].toFixed(1)+')" style="white-space:nowrap'+dim+'">'
         + esc(d.side.toUpperCase()) + ' <b>' + d.available + '</b>/' + d.capacity + '</span>';
    });
    el.innerHTML = h + '</div>';
  }
```

- [ ] **Step 3: 프레임 렌더에서 호출한다**

`tools/monitor/dashboard.html:948` 의 `renderFleet(robots);` **바로 아래**에 추가한다.

```javascript
    renderDepots(fr.depots || []);
```

`renderFleet([]);` 로 초기화하는 자리(파일 내 `renderFleet([]);` 가 나오는 줄) 아래에도 추가한다.

```javascript
    renderDepots([]);
```

- [ ] **Step 4: 브라우저로 확인한다**

Run:
```bash
DEMO_MODEL=tractor.mpd DEMO_OOD=fault DEMO_POLICY=canonical DEMO_SPARES=2 \
DEMO_SEED=1 DEMO_OOD_SEED=1 \
MONITOR_STREAM=tools/monitor/streams/_probe_ui.jsonl \
julia +lts --project=. tools/monitor/run_demo.jl
julia +lts --project=. tools/monitor/server.jl
```

브라우저에서 대시보드를 열고 그 스트림을 선택한다.
Expected: Fleet States 패널 위에 `NORTH 2/2  EAST 2/2  SOUTH 2/2  WEST 2/2` 가 보이고,
고장 사건 후 응답한 방위의 숫자가 1 줄어든다. FACTORY VIEW 에서 파란 창고 패드가 빌드에서
멀리 떨어져 보이고 그 위에 예비 로봇이 서 있다.

확인 후: `rm -f tools/monitor/streams/_probe_ui.jsonl`

- [ ] **Step 5: 커밋**

```bash
git add tools/monitor/dashboard.html
git commit -m "feat(dashboard): 4방위 창고 재고 패널"
```

---

### Task 6: 오라클 라벨에 에너지 지표 추가

**Files:**
- Modify: `wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl:1385-1410` (라벨 NamedTuple), `:1546-1556`, `:1720-1730`, `:1770-1782` (덤프 3곳)

**Interfaces:**
- Consumes: `CB.battery_report(fleet)` (`src/navigator/battery.jl:318`) — `run_demo.jl:652` 가 쓰는 것과 같은 함수
- Produces: 라벨 레코드의 추가 필드 `total_energy_J::Float64`, `energy_per_closed::Float64`, `mean_soc::Float64`, `n_depleted::Int`, 그리고 `geometry` 객체. Task 7의 `results_matrix.py` 가 이 이름들을 읽는다.

- [ ] **Step 1: 라벨 계산에서 에너지 블록을 함께 뽑는다**

`gen_oracle_dataset.jl` 의 `min_soc = try ... catch; NaN end` 블록을 아래로 교체한다.

```julia
    # efficiency-axis labels: 배터리 리포트를 한 번만 읽어 최소 SoC 와 에너지를 같이 뽑는다.
    # 총 에너지만 보면 미완주가 유리해지므로(일을 덜 해서) 닫힌 노드당 에너지도 같이 남긴다.
    _batt = try
        fl = CB.BATTERY_FLEET[]
        fl === nothing ? nothing : CB.battery_report(fl)
    catch; nothing end
    min_soc  = _batt === nothing ? NaN : Float64(_batt.min_soc)
    mean_soc = _batt === nothing ? NaN : Float64(_batt.mean_soc)
    total_energy_J = _batt === nothing ? NaN : Float64(_batt.total_energy_J)
    n_depleted = _batt === nothing ? -1 : Int(_batt.n_depleted)
```

- [ ] **Step 2: 반환 NamedTuple 에 필드를 추가한다**

같은 함수의 `return (` 블록에서 `min_soc  = min_soc,` 줄 **아래**에 추가한다.

```julia
        mean_soc = mean_soc,                                     # 평균 잔량(효율 축)
        total_energy_J = total_energy_J,                         # 총 구동 에너지[J]
        n_depleted = n_depleted,                                 # 끝에 방전된 로봇 수
```

- [ ] **Step 3: 덤프 3곳에 필드를 싣는다**

`gen_oracle_dataset.jl` 에서 `"min_soc"=>r.min_soc` 가 나오는 **모든** 줄 뒤에 아래를 추가한다
(`grep -n '"min_soc"=>' wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl` 로 위치를 확인할 것 —
현재 3곳이다).

```julia
                "mean_soc"=>r.mean_soc, "total_energy_J"=>r.total_energy_J,
                "energy_per_closed"=>(r.closed > 0 ? r.total_energy_J / r.closed : NaN),
                "n_depleted"=>r.n_depleted,
                "geometry"=>Dict("depot_mode"=>"fixed",
                                 "depot_distance"=>CB.spare_depot_distance(),
                                 "station_keeping"=>true),
```

`ctrl` 레코드(제어군)를 덤프하는 자리에서는 `r.` 대신 `ctrl.` 을 쓴다.

- [ ] **Step 4: 라벨 2개만 만들어 필드가 나오는지 확인한다**

Run:
```bash
cd wm4spacecraft_manufacturing/oracle
DS_KINDS=battery DS_SEEDS=1 DS_SPARES=2 DS_SMOKE=1 \
DS_OUT=out/_probe_energy.jsonl \
julia +lts --project=../.. gen_oracle_dataset.jl
python -c "
import json
rows=[json.loads(l) for l in open('out/_probe_energy.jsonl',encoding='utf-8')]
r=rows[0]
for k in ('complete','makespan','min_soc','mean_soc','total_energy_J','energy_per_closed','n_depleted','geometry'):
    print(' ',k,'=',r.get(k))
"
```

Expected: 8개 키가 전부 출력되고 `geometry.depot_distance == 25.0`.
(`DS_SMOKE=1` 은 instance 하나만 돌린다 — 필드 존재 확인이 목적이라 이것으로 충분하다.)

확인 후: `rm -f out/_probe_energy.jsonl`

- [ ] **Step 5: 커밋**

```bash
git add wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl
git commit -m "feat(oracle): 라벨에 에너지 지표와 기하 provenance 를 남긴다"
```

---

### Task 7: 결과 행렬 생성기

**Files:**
- Create: `wm4spacecraft_manufacturing/results_matrix.py`

**Interfaces:**
- Consumes: 런 요약 jsonl(`case`, `policy`, `complete`, `sim_seconds`, `battery.*`, `decisions[]`, `geometry`), 오라클 라벨 jsonl(Task 6의 필드), `reference_policy.score`, `ood_sweep_report.wilson`
- Produces: CLI `python results_matrix.py --runs <jsonl> --oracle <jsonl> --out <경로 접두사>` → `<접두사>.csv`, `<접두사>.md`

- [ ] **Step 1: 생성기를 만든다**

Create `wm4spacecraft_manufacturing/results_matrix.py`:

```python
#!/usr/bin/env python3
"""results_matrix.py -- 실패 케이스 7종 x 컨트롤러 4종 결과 행렬을 지표 4개로 만든다.

지금까지 발표용 표에는 칸마다 완주 k/n 과 결정 적중률 둘뿐이었다. 여기서는
llm_ood_eval.py 헤더가 정의한 4지표를 전부 같은 칸에 적는다.

  ① 성공률       complete 비율 + Wilson 95% CI
  ② 결정 적중률   reference_policy 의 기준 행동 a* 대비 적중
  ③ 빌드 시간     sim_seconds -- **완주한 판만** 평균. 그래서 n_complete 를 항상 같이 적는다
                 (완주율이 낮은 정책이 시간만 보면 유리해 보이는 censoring 을 숨기지 않으려고)
  ④ 에너지        energy_per_closed 를 주지표로. 총 에너지는 미완주에 유리하므로 쓰지 않는다.
                 min_soc 는 마모 신호로 함께 적는다.

오라클 열은 단축 격자에서 유도한 **상한**이지 온라인 정책이 아니다. 조합 케이스(fault+battery
등)는 격자가 없으므로 '-' 로 남긴다. 없는 숫자를 지어내지 않는다.

세대 혼용 차단: 모든 입력 레코드의 geometry 가 같아야 한다. 창고 배치가 바뀌면 makespan 과
에너지가 통째로 달라지므로, 섞인 입력으로 만든 표는 조용히 틀린 비교가 된다.
"""
import argparse
import json
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from ood_sweep_report import wilson          # noqa: E402
import reference_policy                       # noqa: E402

CASES = ["battery", "fault", "zone", "fault_battery", "fault_zone", "battery_zone", "all"]
CASE_LABEL = {
    "battery": "Battery depletion",
    "fault": "Robot breakdown",
    "zone": "Keep-out zone",
    "fault_battery": "Breakdown + battery",
    "fault_zone": "Breakdown + zone",
    "battery_zone": "Battery + zone",
    "all": "All three at once",
}
# 오라클 격자는 단축 사건에만 존재한다. 조합 케이스는 격자가 없다.
ORACLE_KIND = {"battery": "battery", "fault": "fault", "zone": "zone"}
POLICIES = ["canonical", "surrogate", "dspy"]
POLICY_LABEL = {"canonical": "CANONICAL", "surrogate": "SURROGATE", "dspy": "LLM"}


def load(path):
    rows = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def check_geometry(rows, path):
    """모든 레코드의 geometry 가 같은지 확인한다. 다르면 표를 만들지 않고 죽는다."""
    seen = {}
    for r in rows:
        g = r.get("geometry")
        key = "MISSING" if g is None else json.dumps(g, sort_keys=True)
        seen.setdefault(key, 0)
        seen[key] += 1
    if len(seen) > 1:
        print("ERROR  %s 에 서로 다른 기하 세대가 섞여 있다:" % path)
        for k, n in sorted(seen.items(), key=lambda kv: -kv[1]):
            print("       %6d rows  %s" % (n, k))
        raise SystemExit(2)
    return list(seen)[0]


def _mean(xs):
    xs = [x for x in xs if x is not None and x == x]      # None/NaN 제거
    return statistics.mean(xs) if xs else None


def cell_from_runs(runs):
    """한 (케이스, 정책) 칸의 4지표. runs 는 그 칸에 속한 런 요약 목록."""
    n = len(runs)
    done = [r for r in runs if r.get("complete")]
    k = len(done)
    scored = correct = 0
    for r in runs:
        s, c, _ = reference_policy.score(r.get("decisions") or [])
        scored += s
        correct += c
    return dict(
        n=n, k=k,
        success=(k / n if n else None),
        success_ci=(wilson(k, n) if n else (None, None)),
        acc=(correct / scored if scored else None),
        n_scored=scored,
        sim_seconds=_mean([r.get("sim_seconds") for r in done]),
        energy_per_closed=_mean([(r.get("battery") or {}).get("energy_per_closed") for r in done]),
        min_soc=_mean([(r.get("battery") or {}).get("min_soc") for r in done]),
    )


def cell_from_oracle(labels, kind):
    """오라클 칸: instance 마다 최선 팔(완주 우선, 동점이면 makespan 최소)을 골라 그 값들을 평균."""
    by_inst = {}
    for r in labels:
        if r.get("kind") != kind:
            continue
        by_inst.setdefault(r["instance"], []).append(r)
    if not by_inst:
        return None

    def key(r):
        ms = r.get("makespan")
        try:
            ms = float(ms)
        except (TypeError, ValueError):
            ms = float("inf")
        if ms != ms:
            ms = float("inf")
        return (0 if r.get("complete") else 1, ms)      # 완주 우선, 그다음 makespan 최소

    best = [sorted(v, key=key)[0] for v in by_inst.values()]
    k = sum(1 for r in best if r.get("complete"))
    n = len(best)
    done = [r for r in best if r.get("complete")]
    return dict(
        n=n, k=k, success=(k / n if n else None), success_ci=wilson(k, n),
        acc=1.0, n_scored=n,                            # 정의상 오라클은 a* 를 고른다
        sim_seconds=_mean([r.get("makespan") for r in done]),
        energy_per_closed=_mean([r.get("energy_per_closed") for r in done]),
        min_soc=_mean([r.get("min_soc") for r in done]),
    )


def fmt(cell):
    if cell is None:
        return "—"
    pct = "%d/%d" % (cell["k"], cell["n"])
    acc = "—" if cell["acc"] is None else "%.0f%%" % (100 * cell["acc"])
    t = "—" if cell["sim_seconds"] is None else "%.1fs" % cell["sim_seconds"]
    e = "—" if cell["energy_per_closed"] is None else "%.0f J/cl" % cell["energy_per_closed"]
    s = "—" if cell["min_soc"] is None else "SoC %.2f" % cell["min_soc"]
    return "%s · acc %s · %s · %s · %s" % (pct, acc, t, e, s)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", required=True, help="런 요약 jsonl (llm_ood_eval 출력)")
    ap.add_argument("--oracle", required=True, help="오라클 라벨 jsonl")
    ap.add_argument("--out", required=True, help="출력 접두사 (.csv/.md 가 붙는다)")
    args = ap.parse_args()

    runs = load(args.runs)
    labels = load(args.oracle)
    geo_runs = check_geometry(runs, args.runs)
    geo_lab = check_geometry(labels, args.oracle)
    if geo_runs != geo_lab:
        print("ERROR  런과 오라클의 기하 세대가 다르다:\n  runs   %s\n  oracle %s" % (geo_runs, geo_lab))
        raise SystemExit(2)

    table = {}
    for case in CASES:
        table[(case, "oracle")] = (cell_from_oracle(labels, ORACLE_KIND[case])
                                   if case in ORACLE_KIND else None)
        for pol in POLICIES:
            sel = [r for r in runs if r.get("case") == case and r.get("policy") == pol]
            table[(case, pol)] = cell_from_runs(sel) if sel else None

    cols = ["oracle"] + POLICIES
    csv_lines = ["case,controller,n,n_complete,success,success_lo,success_hi,"
                 "decision_acc,n_scored,sim_seconds,energy_per_closed,min_soc"]
    for case in CASES:
        for col in cols:
            c = table[(case, col)]
            if c is None:
                csv_lines.append("%s,%s,0,0,,,,,0,,," % (case, col))
                continue
            lo, hi = c["success_ci"]
            csv_lines.append("%s,%s,%d,%d,%s,%s,%s,%s,%d,%s,%s,%s" % (
                case, col, c["n"], c["k"],
                "" if c["success"] is None else "%.4f" % c["success"],
                "" if lo is None else "%.4f" % lo,
                "" if hi is None else "%.4f" % hi,
                "" if c["acc"] is None else "%.4f" % c["acc"], c["n_scored"],
                "" if c["sim_seconds"] is None else "%.3f" % c["sim_seconds"],
                "" if c["energy_per_closed"] is None else "%.3f" % c["energy_per_closed"],
                "" if c["min_soc"] is None else "%.4f" % c["min_soc"]))
    Path(args.out + ".csv").write_text("\n".join(csv_lines) + "\n", encoding="utf-8")

    md = ["# 실패 케이스 x 컨트롤러 결과 행렬", "",
          "각 칸: 완주 k/n · 결정 적중률 · 빌드 시간(완주 판 평균) · 닫힌 노드당 에너지 · 평균 최소 SoC",
          "", "기하 세대: `%s`" % geo_runs, "",
          "| FAILURE CASE | ORACLE | CANONICAL | SURROGATE | LLM |",
          "|---|---|---|---|---|"]
    for case in CASES:
        md.append("| %s | %s |" % (CASE_LABEL[case],
                                   " | ".join(fmt(table[(case, col)]) for col in cols)))
    md += ["",
           "- ORACLE 은 단축 라벨 격자에서 유도한 상한이며 온라인 정책이 아니다. 조합 케이스는 격자가 없어 `—`.",
           "- 빌드 시간은 완주한 판만 평균한다. 완주율이 낮은 칸의 시간은 그만큼 낙관적이다 — k/n 을 같이 볼 것.",
           "- 에너지 주지표는 닫힌 노드당(J/cl)이다. 총 에너지는 일을 덜 한 미완주에 유리해 쓰지 않는다."]
    Path(args.out + ".md").write_text("\n".join(md) + "\n", encoding="utf-8")

    print("wrote %s.csv and %s.md" % (args.out, args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: 기존 산출물로 세대 혼용 차단이 작동하는지 확인한다**

Run:
```bash
cd wm4spacecraft_manufacturing
python results_matrix.py --runs results/llm_ood_eval.jsonl \
    --oracle oracle/out/n44_plus78.jsonl --out results/_probe_matrix
```

Expected: 종료코드 2 와 `ERROR  ... 서로 다른 기하 세대가 섞여 있다` 또는
`geometry ... MISSING` 보고. **이것이 정상이다** — 기존 산출물에는 `geometry` 가 없으므로
새 표를 만들면 안 된다. 이 단계는 안전장치가 실제로 막는지 확인하는 것이다.

- [ ] **Step 3: 합성 입력으로 정상 경로를 확인한다**

Run:
```bash
cd wm4spacecraft_manufacturing
python - <<'PY'
import json, pathlib
g = {"depot_mode": "fixed", "depot_distance": 25.0, "station_keeping": True}
runs = []
for pol in ("canonical", "surrogate", "dspy"):
    for seed in range(1, 6):
        runs.append(dict(case="battery", policy=pol, complete=(seed != 5),
                         sim_seconds=30.0 + seed, geometry=g,
                         battery={"energy_per_closed": 400.0 + seed, "min_soc": 0.5},
                         decisions=[dict(truth="BatteryTruth", soc=0.05,
                                         valid=["NOOP", "SwapBattery"], macro="SwapBattery")]))
labels = [dict(instance="i1", kind="battery", complete=True, makespan=31.0,
               energy_per_closed=390.0, min_soc=0.6, geometry=g)]
pathlib.Path("results/_probe_runs.jsonl").write_text(
    "\n".join(json.dumps(r) for r in runs) + "\n", encoding="utf-8")
pathlib.Path("results/_probe_labels.jsonl").write_text(
    "\n".join(json.dumps(r) for r in labels) + "\n", encoding="utf-8")
PY
python results_matrix.py --runs results/_probe_runs.jsonl \
    --oracle results/_probe_labels.jsonl --out results/_probe_matrix
cat results/_probe_matrix.md
```

Expected: `wrote results/_probe_matrix.csv and results/_probe_matrix.md` 이후 표가 출력되고,
Battery 행의 세 정책 칸이 `4/5 · acc 100% · 32.5s · 403 J/cl · SoC 0.50`,
ORACLE 칸이 `1/1 · acc 100% · 31.0s · 390 J/cl · SoC 0.60`,
조합 케이스 4행의 ORACLE 칸이 `—`.

확인 후: `rm -f results/_probe_runs.jsonl results/_probe_labels.jsonl results/_probe_matrix.*`

- [ ] **Step 4: 커밋**

```bash
git add wm4spacecraft_manufacturing/results_matrix.py
git commit -m "feat(eval): 7케이스 x 4컨트롤러 x 4지표 결과 행렬 생성기"
```

---

### Task 8: 창고 거리 D 스윕 → 기본값 확정

**Files:**
- Modify: `src/respec/ood_injection.jl` (`SPARE_DEPOT_DISTANCE` 기본값, 측정 결과에 따라)
- Create: `wm4spacecraft_manufacturing/md/DEPOT_DISTANCE_SWEEP_2026-08-12.md`

**Interfaces:**
- Consumes: Task 1~4의 전 구현, Task 3의 `verify_depot_station.py`

- [ ] **Step 1: 세 거리에서 순차로 돌린다**

**병렬 금지.** 아래를 그대로, 한 줄씩 순서대로 실행한다(전체 ~1시간 규모).

```bash
for D in 15 25 40; do
  for CASE in battery fault; do
    SPARE_DEPOT_DIST=$D DEMO_MODEL=tractor.mpd DEMO_OOD=$CASE \
    DEMO_POLICY=canonical DEMO_SPARES=2 DEMO_SEED=1 DEMO_OOD_SEED=1 \
    MONITOR_STREAM=tools/monitor/streams/_sweep_D${D}_${CASE}.jsonl \
    DEMO_SUMMARY=wm4spacecraft_manufacturing/results/_sweep_depot.jsonl \
    julia +lts --project=. tools/monitor/run_demo.jl
  done
done
```

(`SPARE_DEPOT_DIST` 는 Task 4 Step 4에서 `run_demo.jl` 에 붙인 knob 이다.)

- [ ] **Step 2: 정박이 모든 거리에서 유지되는지 확인한다**

```bash
for f in tools/monitor/streams/_sweep_D*.jsonl; do
  echo "== $f"; python tools/monitor/verify_depot_station.py "$f"
done
```

Expected: 6개 전부 PASS.

- [ ] **Step 3: 완주율과 빌드 시간을 표로 뽑는다**

```bash
python -c "
import json
rows=[json.loads(l) for l in open('wm4spacecraft_manufacturing/results/_sweep_depot.jsonl',encoding='utf-8')]
print('%-6s %-8s %-9s %-10s %-10s' % ('D','case','complete','sim_s','J/closed'))
for r in rows:
    b=r.get('battery') or {}
    print('%-6s %-8s %-9s %-10s %-10s' % (r['geometry']['depot_distance'], r['case'],
          r['complete'], round(r.get('sim_seconds') or 0,1),
          round(b.get('energy_per_closed') or 0,1)))
"
```

- [ ] **Step 4: 결과를 문서로 남기고 기본값을 정한다**

`wm4spacecraft_manufacturing/md/DEPOT_DISTANCE_SWEEP_2026-08-12.md` 에 Step 3의 표를 그대로 적고,
아래 규칙으로 기본값을 고른다.

> **완주한** 거리 중 가장 큰 값을 고른다(창고가 눈에 띄게 멀어야 한다는 것이 이 작업의 목적이므로).
> 세 거리 모두 완주하면 40, 15만 완주하면 15. 어느 것도 완주하지 못하면 D=15 로 두고
> "창고 거리와 무관한 완주 실패"를 별도 문제로 기록한다(이 계획의 범위 밖).

고른 값으로 아래 세 곳의 기본값을 **모두** 같은 숫자로 맞춘다(하나라도 어긋나면 드라이버마다
다른 세계가 된다):

- `src/respec/ood_injection.jl` 의 `const SPARE_DEPOT_DISTANCE = Ref(25.0)`
- `tools/demos.jl:1575` 의 `get(ENV, "SPARE_DEPOT_DIST", "25.0")`
- `tools/demos.jl:2754` 의 `get(ENV, "SPARE_DEPOT_DIST", "25.0")`

- [ ] **Step 5: 정리하고 커밋**

```bash
rm -f tools/monitor/streams/_sweep_D*.jsonl wm4spacecraft_manufacturing/results/_sweep_depot.jsonl
git add src/respec/ood_injection.jl tools/demos.jl \
        wm4spacecraft_manufacturing/md/DEPOT_DISTANCE_SWEEP_2026-08-12.md
git commit -m "chore(depot): D 스윕 실측으로 기본 창고 거리 확정"
```

---

### Task 9: 전면 재생성

**Files:**
- 코드 변경 없음. 산출물만 생성한다.

**Interfaces:**
- Consumes: Task 1~8 전부

- [ ] **Step 1: 어휘와 학습셋 계약을 먼저 확인한다**

```bash
python wm4spacecraft_manufacturing/audit_action_vocab.py
python wm4spacecraft_manufacturing/test_surrogate_support.py
```

Expected: 첫 명령 exit 0 (6/6), 둘째 `support=[0, 1, 2, 3, 4, 7, 8]` 7/7 PASS.
실패하면 여기서 멈추고 원인을 먼저 해결한다(재생성은 그 뒤다).

- [ ] **Step 2: 데모 스트림을 재생성한다**

```bash
bash tools/monitor/regen_router_cases.sh
```

Expected: 마지막 줄 `STATUS render ok cases=3/3 failed=none`.

- [ ] **Step 3: 새 스트림에서 정박을 확인한다**

```bash
for f in tools/monitor/streams/tractor__*.jsonl; do
  echo "== $f"; python tools/monitor/verify_depot_station.py "$f"
done
```

Expected: 전부 PASS.

- [ ] **Step 4: 오라클 라벨을 재생성한다 (수 시간, 순차)**

격자 파라미터(어떤 kind·seed·severity·macro 를 도는지)의 단일 진실원은
`wm4spacecraft_manufacturing/md/ORACLE_REBUILD_2026-08-09.md` §II 다. 그 절차를 그대로 따르되
`DS_OUT` 만 세대를 표시한 새 이름으로 바꾼다. **기존 파일을 덮어쓰지 않는다.**

기준 형태는 다음과 같다(§II가 다른 격자를 지시하면 §II를 따른다):

```bash
cd wm4spacecraft_manufacturing/oracle
DS_KINDS=fault,zone,battery DS_SEEDS=1,2,3,4 DS_SPARES=3 DS_VALID_ONLY=1 \
DS_OUT=out/n44_plus78_fardepot.jsonl \
julia +lts --project=../.. gen_oracle_dataset.jl
```

Expected: 생성된 jsonl 의 모든 레코드가 `geometry.depot_distance == <Task 8에서 정한 D>` 를 갖는다.

```bash
python -c "
import json,collections
p='wm4spacecraft_manufacturing/oracle/out/n44_plus78_fardepot.jsonl'
c=collections.Counter(json.dumps(json.loads(l).get('geometry'),sort_keys=True) for l in open(p,encoding='utf-8'))
print(c)
"
```

- [ ] **Step 5: surrogate 를 재학습하고 계약을 다시 확인한다**

`wm4spacecraft_manufacturing/wm_datasets.py` 의 배포 학습셋 상수를 새 파일로 가리키게 바꾼 뒤:

```bash
python wm4spacecraft_manufacturing/export_surrogate.py
python wm4spacecraft_manufacturing/test_surrogate_support.py
```

Expected: `support=[0, 1, 2, 3, 4, 7, 8]` 7/7 PASS.

- [ ] **Step 6: 7케이스 x 4컨트롤러 런을 순차로 돌린다**

```bash
cd wm4spacecraft_manufacturing
for CASE in battery fault zone fault_battery fault_zone battery_zone all; do
  python llm_ood_eval.py run --case $CASE --seeds 1,2,3,4,5 \
      --policies canonical,surrogate,dspy --out results/matrix_fardepot.jsonl
done
```

**한 번에 하나씩.** 이 루프는 순차이며, 여러 터미널로 나눠 돌리면 안 된다.

- [ ] **Step 7: 커밋**

```bash
git add wm4spacecraft_manufacturing/oracle/out/n44_plus78_fardepot.jsonl \
        wm4spacecraft_manufacturing/results/matrix_fardepot.jsonl \
        wm4spacecraft_manufacturing/wm_datasets.py \
        tools/monitor/streams tools/monitor/anim
git commit -m "data: 원거리 창고 기하로 스트림/라벨/런 전면 재생성"
```

---

### Task 10: 기준 정책 재유도 + 최종 표

**Files:**
- Modify: `wm4spacecraft_manufacturing/reference_policy.py` (규칙과 BASIS)
- Create: `wm4spacecraft_manufacturing/md/RESULTS_FARDEPOT_2026-08-12.md`
- Modify: 낡게 된 결과 문서에 세대 배너

**Interfaces:**
- Consumes: Task 9의 `out/n44_plus78_fardepot.jsonl`, `results/matrix_fardepot.jsonl`; Task 7의 `results_matrix.py`

- [ ] **Step 1: 새 격자에서 팔별 결과를 뽑는다**

```bash
cd wm4spacecraft_manufacturing
python -c "
import json, collections
rows=[json.loads(l) for l in open('oracle/out/n44_plus78_fardepot.jsonl',encoding='utf-8')]
agg=collections.defaultdict(list)
for r in rows:
    agg[(r['kind'], r.get('severity'), r['macro_name'])].append(r)
print('%-9s %-9s %-14s %-4s %-9s %-10s' % ('kind','sev','macro','n','complete','makespan'))
for k in sorted(agg, key=lambda t:(str(t[0]),str(t[1]),str(t[2]))):
    v=agg[k]
    nc=sum(1 for r in v if r['complete'])
    ms=[float(r['makespan']) for r in v if r['complete'] and str(r['makespan'])!='Inf']
    print('%-9s %-9s %-14s %-4d %-9s %-10s' % (k[0],k[1],k[2],len(v),
          '%d/%d'%(nc,len(v)), round(sum(ms)/len(ms),1) if ms else '-'))
"
```

- [ ] **Step 2: 배터리 깊은 방전의 정답이 무엇인지 판정한다**

Step 1의 표에서 `kind=battery`, 깊은 방전(severity ≤ 0.2) 행을 본다.

- `SwapBattery` 와 `Replace` 의 완주가 **같으면** → 더 싼 팔(`SwapBattery`)이 정답. 현재 규칙 유지.
- `Replace` 만 완주하거나 makespan 이 뚜렷이 짧으면 → 정답을 `Replace` 로 바꾼다.
- `SwapBattery` 만 완주하면 → 현재 규칙이 더 강해진 것이다. 유지하고 근거만 갱신.

판정 결과에 맞게 `reference_policy.py:52-62` 의 깊은 방전 분기와 파일 상단 `BASIS["battery"]`
문자열을 새 격자 파일 이름·instance 수로 갱신한다. **표를 만들기 전에 이 단계를 끝낸다** —
낡은 기준으로 채점하면 "결정 적중률" 열 전체가 옛 진실을 재는 숫자가 된다.

- [ ] **Step 3: fault·zone 규칙도 같은 방식으로 확인한다**

`kind=fault` 는 `agent_pending > 0 → Replace` 분리가 유지되는지, `kind=zone` 은
`nav_blocked > 0 && root_covered == 0 → RelocateBuild` 가 유지되는지 Step 1의 표로 확인한다.
어긋나면 규칙과 BASIS 를 갱신하고, 어긋난 내용을 Step 5의 문서에 적는다.

- [ ] **Step 4: 최종 행렬을 만든다**

```bash
cd wm4spacecraft_manufacturing
python results_matrix.py --runs results/matrix_fardepot.jsonl \
    --oracle oracle/out/n44_plus78_fardepot.jsonl \
    --out results/matrix_fardepot
cat results/matrix_fardepot.md
```

Expected: 7행 × 4열, 각 칸에 완주 k/5 · 적중률 · 빌드 시간 · J/closed · 최소 SoC.
조합 케이스 4행의 ORACLE 칸만 `—`.

- [ ] **Step 5: 결과 문서를 쓰고 옛 문서에 배너를 단다**

`wm4spacecraft_manufacturing/md/RESULTS_FARDEPOT_2026-08-12.md` 에 다음을 담는다:
Step 4의 표, 재현 명령(Task 9 Step 2·4·6 그대로), 기하 세대(`depot_mode`/`depot_distance`/
`station_keeping`), Step 2·3에서 규칙이 바뀌었으면 무엇이 왜 바뀌었는지.

`md/RESULTS_LLM7H.md` 와 이번 재생성으로 낡게 된 결과 문서 맨 위에 한 줄을 넣는다.

```markdown
> 🔴 **구세대(가까운 창고 기하) 측정치.** 현재 성능은 `RESULTS_FARDEPOT_2026-08-12.md` 를 볼 것.
```

`.claude/CLAUDE.md` 의 "★ 결과 세대" 절에 현행 문서를 `RESULTS_FARDEPOT_2026-08-12.md` 로 갱신한다.

- [ ] **Step 6: 전체 테스트로 마무리한다**

```bash
julia +lts --project=. -e 'using Pkg; Pkg.test()'
julia +lts --project=. tools/checks.jl depot_geometry
julia +lts --project=. tools/checks.jl station_keeping
julia +lts --project=. tools/checks.jl spare_pool
python wm4spacecraft_manufacturing/audit_action_vocab.py
python wm4spacecraft_manufacturing/test_surrogate_support.py
```

Expected: `Pkg.test()` = 11 pass / 1 error(Gurobi, 무관) · 나머지 전부 PASS.

- [ ] **Step 7: 커밋**

```bash
git add wm4spacecraft_manufacturing/reference_policy.py \
        wm4spacecraft_manufacturing/md wm4spacecraft_manufacturing/results \
        .claude/CLAUDE.md
git commit -m "docs(eval): 새 기하 격자로 기준 정책 재유도 + 4지표 결과 행렬 확정"
```
