# ============================================================================
#  [한국어 설명] 이 파일은 ConstructionBots 의 "불변식/온전성 점검(check/probe) 실행기".
#  · 프로젝트 역할: 무거운 시뮬레이션을 돌리지 않고도, 부품·저장소·기하 헬퍼들이 "말이 되는지"
#    (invariant/sanity) 빠르게 확인하는 가벼운 점검들을 한 파일(module Checks)에 모아둔 것.
#    tests.jl 가 "기능이 맞나"를 본다면, checks.jl 는 "환경/부품이 정상인가(smoke/probe)"를 본다.
#  · 원래는 tools/*check*.jl / *probe*.jl 로 흩어져 있던 스크립트를 각각 함수 하나로 바꾸고
#    공통 준비코드(MILP 설정 + run_with_stack)를 한 번만 정의해 공유함.
#  · 맨 아래 dispatcher 가 CLI 인자/ENV 로 받은 check_key 하나만 골라 실행함.
#  각 점검이 무엇을 확인하는지는 함수마다 위에 한국어 요약을 달아둠(아래 참고).
#
#  Julia 문법 참고(처음 보는 사람을 위해):
#   · module Checks ... end : 이름공간. `const CB = ConstructionBots` = 긴 이름의 별칭.
#   · function f() ... end : 함수 정의. 함수 "안"에 또 함수를 정의(중첩)해 로컬 헬퍼로 쓸 수 있음.
#   · `!` 로 끝나는 함수(예: clear_spare_pools!) = 인자/전역 상태를 직접 바꾼다(in-place)는 관례.
#   · :symbol (예: :north, :east) = 가벼운 이름표(방위/키 구분에 씀). Dict 의 키로 자주 쓰임.
#   · Ref(0) / X[] : 값을 담는 1칸 상자와 그 안을 읽고/쓰기. 가변 카운터(npass/nfail)에 사용.
#   · CB.SPARE_POOL_CENTERS[][:north] : Ref 를 [] 로 열고 그 Dict 의 :north 키에 접근(중첩 접근).
#   · `cond ? A : B` = 삼항 조건식. `≈`(거의 같음), `÷`(정수나눗셈) 등 유니코드 연산자 사용.
#   · @noinline / ccall(:jl_new_task,...) : 컴파일러 힌트 / C 런타임 직접 호출(스택 크기 실험용, stack 점검).
#   · exit(0/1) : 프로세스 종료코드. 0=성공, 1=실패(CI 가 이 코드로 성패를 판단).
# ============================================================================
# =============================================================================
# tools/checks.jl -- consolidated ConstructionBots check/probe driver.
#
# Every standalone tools/*check*.jl / *probe*.jl script is now a FUNCTION in module
# `Checks`, sharing common boilerplate (MILP setup + run_with_stack) defined ONCE. A
# CLI/ENV dispatcher at the bottom lets any single check run individually.
#
# Check keys:
#   load          -- package loads; rethread_robot_ids! defined (smoke)
#   depot_render  -- draw_spare_depots! / draw_decommissioned_robots! run setobject! on headless MeshCat
#   stall_gate    -- battery->stall coupling symbols + set_battery_stall!/soc_speed_factor gating (env-free)
#   spare_pool    -- OOD 1-1 A1 directional spare-pool storage + geometry helpers (env-free)
#   hot_swap      -- identity-preserving spare-repository hot-swap bookkeeping + health reset (env-free)
#   scale_cap     -- per-project/per-scale "root-clear cap" geometry probe (no sim; rvo OFF)
#   rvo           -- PyCall/rvo2 sanity probe: import rvo2 + construct a PyRVOSimulator
#   stack         -- measure recursion depth on the main task (+ spawned/big-stack tasks)
#   stack_task    -- measure recursion depth on a spawned task with an explicit large C stack
#
# Run:
#   julia +lts --project=. tools/checks.jl <check_key>       (or  ENV CHECK=<key>)
# e.g.
#   julia +lts --project=. tools/checks.jl spare_pool
#   CHECK=stall_gate julia +lts --project=. tools/checks.jl
# Each check reads its own ENV knobs at call time (see the comment above each function).
# =============================================================================
module Checks
using ConstructionBots
import MeshCat, Logging, HiGHS, LinearAlgebra
import PyCall   # used only by check_rvo; pyimport("rvo2") runs at CALL time, not module load
const CB = ConstructionBots
const norm = LinearAlgebra.norm

# ---- runtime-loaded decoupled layers (loaded ONCE, at module load) ----------
# The navigator layer is NOT compiled into the ConstructionBots package -- the checks
# historically `CB.include`d its pieces (metrics/ood_truth/battery/ood_stream) at SCRIPT
# TOP LEVEL. Now that each check is a FUNCTION, doing those includes *inside* a check and
# then calling the freshly-defined methods in the SAME call frame raises a world-age error
# ("method too new to be called from this world context"). Loading it here at MODULE load
# puts it in an OLDER world than any check call, exactly reproducing the original top-level-
# include semantics. navigator.jl is the umbrella loader (it includes metrics/ood_truth/
# battery/ood_stream/... in dependency order -- see its header), so ONE call covers every
# navigator-using check (stall_gate + hot_swap).
# navigator 레이어(배터리/stall 등)를 런타임 include 로 한 번만 불러옴(모듈 로드 시점 → world-age 에러 회피).
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))

# ---- shared helpers (defined ONCE) ------------------------------------------
# _setup_milp! : MILP 솔버(HiGHS)를 기본 옵티마이저로 등록/설정. time_limit=제한시간(초), mip_rel_gap=허용 오차.
function _setup_milp!(; time_limit = 300.0, mip_rel_gap = 5.0)
    CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
    CB.clear_default_milp_optimizer_attributes!()
    CB.set_default_milp_optimizer_attributes!(
        "time_limit" => time_limit, "presolve" => "on", "mip_rel_gap" => mip_rel_gap,
        CB.MOI.Silent() => true)
end

# run_with_stack : f() 를 C 스택을 크게(stacksize 바이트) 잡은 새 태스크에서 실행 — 깊은 재귀의 env 빌드가
#   스택오버플로 나지 않게 함. run_lego_demo 를 돌리는 모든 probe 가 공유.
function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))
    return res[]
end

# =============================================================================
# load -- trivial package-load smoke check: does ConstructionBots import, and is the
#   rethread_robot_ids! symbol defined? (originally tools/loadcheck.jl)
# =============================================================================
# [점검 내용] 가장 기본: 패키지가 import 되고, rethread_robot_ids! 심볼이 정의돼 있는지(로드 스모크).
function check_load()
    println("LOAD OK; rethread_robot_ids! defined = ", isdefined(ConstructionBots, :rethread_robot_ids!))
end

# =============================================================================
# depot_render -- proves draw_spare_depots! / draw_decommissioned_robots! actually
#   execute their setobject! calls on a REAL (headless) MeshCat visualizer -- i.e. the
#   depot pads and fault pin land in the scene tree (not just no-op'd). The draw fns push
#   their key into a drawn-set AFTER the setobject! loop, so a populated drawn-set proves
#   the geometry was created without error. (originally tools/depot_render_check.jl)
# =============================================================================
# [점검 내용] 예비 depot(주차장) 패드/고장 핀 그리기 함수가 실제 (headless) MeshCat 시각화기 위에서
#   setobject! 호출을 에러 없이 수행하는지 확인. 그린 뒤 drawn-set 에 키가 들어가면 성공으로 본다.
function check_depot_render()
npass = Ref(0); nfail = Ref(0)   # 통과/실패 카운터 상자
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))   # 로컬 검사 클로저

println(">>> depot / fault-marker render check (headless MeshCat)")
vis = MeshCat.Visualizer()          # headless(브라우저 없이) — 프로세스 내부 서버만 띄움

CB.clear_spare_pools!()
CB.clear_depot_markers!()
CB.clear_decommissioned_markers!()

# populate a depot the way add_directional_spare_pools! does
CB.SPARE_POOL_CENTERS[][:north] = [0.0, 6.0]
CB.SPARE_POOL_CENTERS[][:east]  = [6.0, 0.0]
CB.DEPOT_INFO[][:north] = (capacity = 2, halfw = 1.0, halfd = 0.5)
CB.DEPOT_INFO[][:east]  = (capacity = 2, halfw = 1.0, halfd = 0.5)

CB.draw_spare_depots!(vis)          # must run setobject! for each side without error
check("draw_spare_depots! drew :north pad+posts", :north in CB._DRAWN_DEPOT_MARKERS[])
check("draw_spare_depots! drew :east pad+posts",  :east  in CB._DRAWN_DEPOT_MARKERS[])

# 멱등성(idempotency): 두 번째로 불러도 이미 그린 건 새로 추가하지 않아야 함(개수 그대로).
before = length(CB._DRAWN_DEPOT_MARKERS[])
CB.draw_spare_depots!(vis)
check("draw_spare_depots! idempotent", length(CB._DRAWN_DEPOT_MARKERS[]) == before)

# fault pin at a break spot
rid = CB.get_unique_id(CB.RobotID)
CB.decommissioned_bodies()[rid] = [1.4, 0.7]
CB.draw_decommissioned_robots!(vis)
check("draw_decommissioned_robots! drew the red fault pin", rid in CB._DRAWN_DECOMMISSIONED[])

println("\ndepot render check: $(npass[]) PASS / $(nfail[]) FAIL")
nfail[] == 0 || error("depot render check had $(nfail[]) failure(s)")
end

# =============================================================================
# stall_gate -- env-free smoke test for the battery->stall coupling (no sim, no MILP, no
#   MeshCat). Verifies: package loads with the route_planning SOC_SPEED_HOOK edit; battery.jl
#   symbols exist; set_battery_stall!/soc_speed_factor gate + fire-once guard behave.
#   (originally tools/stall_gate_check.jl; its per-file navigator includes are now hoisted.)
# =============================================================================
# [점검 내용] env 없이(시뮬/MILP/MeshCat 없음) 배터리->stall(정지) 연동을 스모크 검사:
#   route_planning 의 SOC_SPEED_HOOK 편집이 로드되는지, battery.jl 심볼이 있는지,
#   set_battery_stall!/soc_speed_factor 게이트와 "한 번만 발동" 가드가 제대로 동작하는지 본다.
function check_stall_gate()
pass = 0; fail = 0
check(name, cond) = (cond ? (pass += 1; println("  PASS  $name")) :
                            (fail += 1; println("  FAIL  $name")))

println("[1] symbols present")
check("SOC_SPEED_HOOK Ref",      isa(CB.SOC_SPEED_HOOK, Base.RefValue))
check("set_battery_stall! fn",   isa(CB.set_battery_stall!, Function))
check("soc_speed_factor fn",     isa(CB.soc_speed_factor, Function))
check("install_soc_speed_hook!", isa(CB.install_soc_speed_hook!, Function))
check("stalled_robots fn",       isa(CB.stalled_robots, Function))

println("[2] stall config toggling + guard reset")
CB.set_battery_stall!(enabled = true, threshold = 0.05)
check("enabled set true",   CB.BATTERY_STALL[].enabled == true)
check("threshold set",      CB.BATTERY_STALL[].threshold ≈ 0.05)
push!(CB.STALLED_ROBOTS[], :dummy)                  # 가짜 정지 로봇 하나 넣어두고
CB.set_battery_stall!(enabled = false)              # 재설정 시 "한 번만 발동" 가드가 비워져야 함
check("guard cleared on reconfigure", isempty(CB.stalled_robots()))

println("[3] soc_speed_factor is inert when stall disabled / no fleet")
CB.BATTERY_FLEET[] = nothing
CB.set_battery_stall!(enabled = false)
check("inert -> factor 1.0 (disabled)", CB.soc_speed_factor(nothing) == 1.0)
CB.set_battery_stall!(enabled = true, threshold = 0.1)
check("inert -> factor 1.0 (no fleet)", CB.soc_speed_factor(nothing) == 1.0)

println("[4] install hook wires the Ref, teardown clears it")
CB.install_soc_speed_hook!()
check("hook installed", CB.SOC_SPEED_HOOK[] === CB.soc_speed_factor)
CB.SOC_SPEED_HOOK[] = nothing
CB.set_battery_stall!(enabled = false); CB.clear_stalled_robots!()
check("hook cleared", CB.SOC_SPEED_HOOK[] === nothing)

println("\n$(fail == 0 ? "ALL GREEN" : "HAS FAILURES") — pass=$pass fail=$fail")
exit(fail == 0 ? 0 : 1)
end

# =============================================================================
# spare_pool -- LLM-free, env-free unit check of OOD 1-1 Part A1: the directional
#   spare-pool storage + geometry helpers (ood_injection.jl). No nav build, no MILP, no
#   Python service -- pure storage/geometry assertions. (originally tools/spare_pool_check.jl)
# =============================================================================
# [점검 내용] LLM/env 없이 OOD 1-1 Part A1 의 "방위별 예비 풀(spare pool) 저장 + 기하 헬퍼"를 단위 검사:
#   pool_centers(4방위 중심 계산), register/pop/active_spares 왕복, nearest_pool(가장 가까운 풀 선택,
#   nonempty 옵션 시 빈 풀 건너뛰기), clear 가 저장소를 비우는지 — 순수 저장/기하 단언들.
function check_spare_pool()
npass = Ref(0); nfail = Ref(0)
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))

println(">>> A1 spare-pool storage + geometry (env-free)")

CB.clear_spare_pools!()

# --- pool_centers: 4 cardinal centers placed `margin` outside a unit bbox -------
# bbox = (xmin,xmax,ymin,ymax) = (-1,1,-1,1); margin=2 -> centers at distance 2 outside.
centers = CB.pool_centers((-1.0, 1.0, -1.0, 1.0); margin = 2.0)
check("pool_centers has 4 cardinal keys",
    Set(keys(centers)) == Set([:north, :south, :east, :west]))
check("north center is +y outside bbox", centers[:north] == [0.0, 3.0])
check("south center is -y outside bbox", centers[:south] == [0.0, -3.0])
check("east center is +x outside bbox",  centers[:east]  == [3.0, 0.0])
check("west center is -x outside bbox",  centers[:west]  == [-3.0, 0.0])

# --- register_spare! / pop_spare! / active_spares round-trip --------------------
# env 없이 전역 id 카운터로 가짜 예비 RobotID 들을 만든다(각 방위 풀마다 3개씩) — 이중 comprehension.
rids = Dict(k => [CB.get_unique_id(CB.RobotID) for _ in 1:3] for k in keys(centers))
for (k, v) in rids, rid in v   # 한 줄 이중 for: 방위 k 의 리스트 v 를 돌며 각 rid 등록
    CB.register_spare!(k, rid)
end
# Record the centers too so nearest_pool can score them.
for (k, c) in centers
    CB.SPARE_POOL_CENTERS[][k] = Vector{Float64}(c)
end
check("active_spares counts all registered (4 pools x 3)", length(CB.active_spares()) == 12)
check("each pool holds 3 spares",
    all(length(CB.spare_pools()[k]) == 3 for k in keys(centers)))

popped = CB.pop_spare!(:north)
check("pop_spare! returns a registered north id", popped in rids[:north])
check("pop_spare! shrinks the north pool to 2", length(CB.spare_pools()[:north]) == 2)
check("active_spares now 11 after one pop", length(CB.active_spares()) == 11)

# --- nearest_pool: closest center wins; skips empty pools when nonempty ---------
check("nearest_pool near +y -> :north", CB.nearest_pool([0.0, 10.0]) == :north)
check("nearest_pool near -y -> :south", CB.nearest_pool([0.0, -10.0]) == :south)
check("nearest_pool near +x -> :east",  CB.nearest_pool([10.0, 0.0]) == :east)
check("nearest_pool near -x -> :west",  CB.nearest_pool([-10.0, 0.0]) == :west)

# 북쪽 풀을 다 비운다; nonempty=true 면 바로 위 위치라도 빈 :north 는 안 뽑고 그 다음 가까운 풀이 이겨야 함.
CB.pop_spare!(:north); CB.pop_spare!(:north)
check("drained north pool is empty", isempty(CB.spare_pools()[:north]))
np = CB.nearest_pool([0.0, 10.0]; nonempty = true)
check("nearest_pool(nonempty) skips drained :north", np !== :north && np !== nothing)
check("nearest_pool(nonempty=false) still returns :north",
    CB.nearest_pool([0.0, 10.0]; nonempty = false) == :north)

# --- clear_spare_pools! wipes both stores --------------------------------------
CB.clear_spare_pools!()
check("clear_spare_pools! empties pools", isempty(CB.spare_pools()))
check("clear_spare_pools! empties centers", isempty(CB.spare_pool_centers()))
check("nearest_pool on empty stores -> nothing", CB.nearest_pool([0.0, 0.0]) === nothing)

println("\nA1 spare-pool check: $(npass[]) PASS / $(nfail[]) FAIL")
nfail[] == 0 || error("A1 spare-pool check had $(nfail[]) failure(s)")
end

# =============================================================================
# hot_swap -- LLM-free, env-free unit check of the identity-preserving spare-repository
#   HOT-SWAP machinery (ood_injection.jl + replace_robot.jl). No nav build, no MILP, no
#   Python service -- pure storage/flag/reset assertions. The full scene-tree swap
#   (hot_swap_robot!) needs a built env and is exercised by the demo / spare_replace_test;
#   this gates the new bookkeeping + health reset. (originally tools/hot_swap_check.jl; its
#   per-file navigator includes are now hoisted.)
# =============================================================================
# [점검 내용] LLM/env 없이 "정체성 보존 hot-swap"(고장 로봇을 id 유지한 채 창고 예비로 몸통만 교체)의
#   장부 기록/플래그/리셋을 단위 검사: hot-swap 온오프 플래그, depot 재고 반영,
#   decommissioned/checked-out 기록, _reset_robot_health!(배터리 만충+stall/deplete/fault/장애물 zone 정리).
function check_hot_swap()
npass = Ref(0); nfail = Ref(0)
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))

println(">>> hot-swap repository machinery (env-free)")

CB.clear_spare_pools!()
CB.clear_faulted_robots!()

# --- hot-swap flag toggle -------------------------------------------------------
check("hot-swap OFF by default", CB.hot_swap_enabled() == false)
CB.set_hot_swap!(enabled = true, mode = :via_depot)
check("set_hot_swap! turns it on", CB.hot_swap_enabled() == true)
check("mode recorded", CB.HOT_SWAP_MODE[] == :via_depot)
CB.set_hot_swap!(enabled = false)
check("set_hot_swap!(false) turns it off", CB.hot_swap_enabled() == false)

# --- depot inventory (depot_available) reflects pool + pop ----------------------
# Populate a depot the way add_directional_spare_pools! would (storage-only).
rids = [CB.get_unique_id(CB.RobotID) for _ in 1:3]
for r in rids
    CB.register_spare!(:east, r)
end
CB.SPARE_POOL_CENTERS[][:east] = [5.0, 0.0]
CB.DEPOT_INFO[][:east] = (capacity = 3, halfw = 1.2, halfd = 0.5)
check("depot_available counts registered spares", CB.depot_available(:east) == 3)
CB.pop_spare!(:east)
check("depot_available drops after checkout", CB.depot_available(:east) == 2)
check("depot_available on unknown side is 0", CB.depot_available(:north) == 0)
check("depot_info records capacity", CB.depot_info()[:east].capacity == 3)

# --- decommissioned-body bookkeeping -------------------------------------------
retired = CB.get_unique_id(CB.RobotID)
CB.decommissioned_bodies()[retired] = [3.0, 4.0]
check("decommissioned body recorded", haskey(CB.decommissioned_bodies(), retired))

# --- checked-out spare bookkeeping ---------------------------------------------
co = CB.get_unique_id(CB.RobotID)
push!(CB.checked_out_spares(), co)
check("checked-out spare recorded", co in CB.checked_out_spares())

# --- _reset_robot_health!: 배터리 만충 + stall/deplete/fault + 장애물 zone 을 모두 정리하는지 ---
rid = CB.get_unique_id(CB.RobotID)
fleet = CB.BatteryFleet(CB.BatteryParams(),
    Dict{Any,Float64}(rid => 0.0),      # soc=0.0 (완전 방전 상태로 세팅)
    Dict{Any,Float64}(rid => 5.0),      # 누적 소비 에너지
    Dict{Any,Int}(rid => 3),            # 재충전 등 카운트
    Set{Any}([rid]))                    # depleted(방전) 집합에도 넣어둠
CB.BATTERY_FLEET[] = fleet
push!(CB.STALLED_ROBOTS[], rid)
CB.faulted_robots()[rid] = [1.0, 2.0]
zone_key = Symbol("fault_$(CB.get_id(rid))")   # 고장 지점을 장애물로 막는 zone 키 이름 만들기
CB.add_restriction_zone!(zone_key, [1.0, 2.0], 0.5)
check("fault obstacle zone registered pre-reset", haskey(CB.restriction_zones(), zone_key))

CB._reset_robot_health!(nothing, rid)
check("reset -> SoC restored to 1.0", fleet.soc[rid] == 1.0)
check("reset -> cleared from depleted", !(rid in fleet.depleted))
check("reset -> cleared from stalled", !(rid in CB.stalled_robots()))
check("reset -> cleared from faulted", !haskey(CB.faulted_robots(), rid))
check("reset -> fault obstacle zone removed", !haskey(CB.restriction_zones(), zone_key))

# --- visualization draws are safe no-ops when headless (vis === nothing) --------
check("draw_spare_depots!(nothing) is a no-op", CB.draw_spare_depots!(nothing) === nothing)
check("draw_decommissioned_robots!(nothing) is a no-op", CB.draw_decommissioned_robots!(nothing) === nothing)

# --- clear_spare_pools! wipes the new repository stores too ---------------------
CB.clear_spare_pools!()
check("clear_spare_pools! empties depot_info", isempty(CB.depot_info()))
check("clear_spare_pools! empties decommissioned", isempty(CB.decommissioned_bodies()))
check("clear_spare_pools! empties checked-out", isempty(CB.checked_out_spares()))

println("\nhot-swap check: $(npass[]) PASS / $(nfail[]) FAIL")
nfail[] == 0 || error("hot-swap check had $(nfail[]) failure(s)")
end

# =============================================================================
# scale_cap -- per-project, per-scale measurement of the "root-clear cap" (max distance
#   from any relocatable sub-assembly's staging center to the nearest UN-RELOCATABLE root
#   deposit goal). This is the geometric quantity that decides whether a meaningful forbid
#   zone can ever be restage-recovered. Pure geometry: rvo OFF, NO sim warmup
#   (return_env_before_sim) -> fast. We only build the scene/schedule/staging plan, then read
#   staging_circles + root goals. ENV: PROBE_PROJECTS, PROBE_MULTS. (originally
#   tools/scale_cap_probe.jl; its inline MILP + local run_with_stack are now shared.)
# =============================================================================
# [점검 내용] 프로젝트/스케일별 "root-clear cap"(옮길 수 있는 하위 조립품의 staging 중심에서 가장 가까운
#   '옮길 수 없는' root 목표점까지의 최대 거리)을 측정. 이 값이 forbid zone 을 restage 로 복구할 수 있는지
#   결정하는 기하량임. 순수 기하만: rvo OFF + 시뮬 워밍업 없이(return_env_before_sim) 빠르게 잰다.
#   ENV: PROBE_PROJECTS, PROBE_MULTS 로 대상 프로젝트/스케일 배수를 지정.
function check_scale_cap()
_setup_milp!()

# build_geom : staging/place_objects 단계까지만 env 를 만든다(시뮬 없음). scale_mult 는 model_scale 배수.
function build_geom(project::Int, scale_mult::Float64)
    pp = CB.get_project_params(project)
    run_with_stack(2_000_000_000) do
        CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
            model_scale=pp[:model_scale]*scale_mult, num_robots=pp[:num_robots],
            assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
            log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false,
            dispersion_flag=false, open_animation_at_end=false, save_animation=false,
            save_animation_along_the_way=false, write_results=false,
            overwrite_results=false, look_for_previous_milp_solution=false,
            save_milp_solution=false, return_env_before_sim=true)
    end
end

# max_cap : root 가 아닌 모든 조립품에 대해 root-clear cap 의 최댓값을 구함(아직 아무것도 안 돌았으니 전부 "미래").
#   root = staging 원이 가장 큰 조립품, rootgoals = 옮길 수 없는 root 목표점들; 각 조립품 중심에서 최근접 목표까지 거리의 최대.
function max_cap(env)
    isempty(env.staging_circles) && return (nothing, -1.0, 0)
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))
    rootgoals = CB.root_deposit_goals(env)
    isempty(rootgoals) && return (root, -1.0, 0)
    best = -Inf; n = 0
    for k in keys(env.staging_circles)
        k == root && continue
        n += 1
        c = Vector{Float64}(CB.get_center(env.staging_circles[k])[1:2])
        d = minimum(norm(c .- g) for g in rootgoals)
        d > best && (best = d)
    end
    return (root, best, n)
end

# ENV 문자열("4,5,6")을 쪼개 숫자 배열로 파싱. `parse.` 의 점(.)=벡터 각 원소에 parse 적용(broadcast).
PROJECTS = parse.(Int, split(get(ENV, "PROBE_PROJECTS", "4,5,6"), ","))
MULTS    = parse.(Float64, split(get(ENV, "PROBE_MULTS", "1,2,3,4"), ","))
RR = Float64(CB.default_robot_radius())   # 로봇 반지름(cap 을 이 단위로 비교)
TARGET_CAP = 1.5   # 여유 두고 로봇 1반지름짜리 zone 이 들어갈 만한 cap 목표값

println("robot_radius=$RR   target_cap=$TARGET_CAP")
println("proj  name                scaleMult  model_scale   maxCap   #subasm   cap/RR   zone_fits?")
for p in PROJECTS
    pp = CB.get_project_params(p)
    base = pp[:model_scale]
    caps = Tuple{Float64,Float64}[]   # (mult, cap)
    for m in MULTS
        local cap, n
        try
            env = build_geom(p, m)
            _, cap, n = max_cap(env)
        catch e
            println("  proj $p x$m -> BUILD FAILED: $(typeof(e))")
            continue
        end
        push!(caps, (m, cap))
        fits = cap > RR + 0.25*RR
        println(rpad(p,5), " ", rpad(string(pp[:project_name]),18), " ",
                rpad("x"*string(m),9), " ", rpad(round(base*m;digits=5),12), " ",
                rpad(round(cap;digits=3),8), " ", rpad(n,8), " ",
                rpad(round(cap/RR;digits=2),7), " ", fits ? "YES" : "no")
    end
    # 측정점들로 cap ≈ a*mult + b 직선 적합(선형회귀) -> TARGET_CAP 을 맞추는 데 필요한 배수 mult 추천.
    if length(caps) >= 2
        xs = [c[1] for c in caps]; ys = [c[2] for c in caps]
        x̄ = sum(xs)/length(xs); ȳ = sum(ys)/length(ys)
        a = sum((xs .- x̄).*(ys .- ȳ)) / sum((xs .- x̄).^2)
        b = ȳ - a*x̄
        mult_needed = (TARGET_CAP - b)/a
        println("  -> $(pp[:project_name]): cap ≈ $(round(a;digits=3))*mult + $(round(b;digits=3))" *
                "  => for cap=$TARGET_CAP need mult≈$(round(mult_needed;digits=2)) " *
                "(model_scale≈$(round(base*mult_needed;digits=5)))")
    end
end
println("DONE")
end

# =============================================================================
# rvo -- PyCall/rvo2 sanity probe: confirm the PyCall python has the `rvo2` module and
#   that a PyRVOSimulator can be constructed. The pyimport runs at CALL time, so a
#   missing rvo2 does not break module load. (originally test_rvo.jl)
# =============================================================================
# [점검 내용] PyCall 이 붙은 python 에 rvo2 모듈이 있고 PyRVOSimulator 를 만들 수 있는지 확인.
#   (RVO = 로봇 간 충돌회피 라이브러리; pyimport 는 CALL 시점에 실행되어 모듈 로드는 안 깨짐.)
function check_rvo()
    println("PyCall python: ", PyCall.python)
    rvo = PyCall.pyimport("rvo2")
    println("rvo2 imported: ", rvo)
    sim = rvo.PyRVOSimulator(1/60, 1.5, 5, 1.5, 2.0, 0.4, 2.0)
    println("sim created: ", sim)
    println("RVO2_OK")
end

# =============================================================================
# stack -- measure how deep we can recurse on (a) the main task, (b) a spawned task, and
#   (c) a low-level task with an explicit large C stack via jl_new_task. Purely diagnostic
#   (no sim/MILP); `deep` is nested so it stays local to this check. (originally test_stack.jl)
# =============================================================================
# [점검 내용] 재귀를 얼마나 깊이 할 수 있는지(=스택 여유) 측정: (a) 메인 태스크, (b) spawn 한 태스크,
#   (c) jl_new_task 로 명시적 큰 C 스택을 준 저수준 태스크. 순수 진단용(시뮬/MILP 없음).
function check_stack()
    @noinline function deep(n::Int)   # @noinline: 컴파일러가 인라인하지 못하게(진짜 재귀 스택을 쌓게) 강제
        n == 0 && return 0
        return 1 + deep(n - 1)
    end

    # max_depth : 성공하는 최대 재귀깊이를 찾는다 — 먼저 지수적으로 키우다가(exponential probe),
    #   실패 지점을 잡으면 이분탐색(binary search)으로 좁힌다.
    function max_depth()
        lo, hi = 0, 0
        # exponential probe: 1000부터 2배씩 늘리며 성공하는 한계를 넓힘
        d = 1000
        while true
            ok = try
                deep(d); true
            catch e
                false
            end
            if ok
                lo = d; d *= 2
                d > 20_000_000 && return lo
            else
                hi = d; break
            end
        end
        # binary search
        while hi - lo > 1000
            mid = (lo + hi) ÷ 2
            ok = try; deep(mid); true catch; false end
            ok ? (lo = mid) : (hi = mid)
        end
        return lo
    end

    println("MAIN task max depth ~ ", max_depth())

    # Spawned task on a thread
    t = Threads.@spawn max_depth()
    println("SPAWNED task max depth ~ ", fetch(t))

    # 저수준: jl_new_task 로 명시적 큰 스택을 준 태스크에서 실행
    function bigstack_run(f, stacksize::Int)
        t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int), f, nothing, stacksize)
        t.sticky = false
        schedule(t)
        return fetch(t)
    end
    println("BIGSTACK(512MB) max depth ~ ", bigstack_run(max_depth, 512*1024*1024))
    println("STACK_TEST_DONE")
end

# =============================================================================
# stack_task -- measure recursion depth on a freshly created task that has an explicit
#   (large) C stack. Uses its OWN run_with_stack (verbatim from the source, kept local so it
#   does not shadow the shared module helper); `deep` is nested. (originally test_stack2.jl)
# =============================================================================
# [점검 내용] 명시적 큰 C 스택(1GB)을 준 새 태스크에서 재귀깊이를 측정(stack 점검의 저수준 변형).
#   자신만의 run_with_stack 을 로컬로 둬 공유 헬퍼를 가리지 않게 함(원본 그대로).
function check_stack_task()
    @noinline function deep(n::Int)
        n == 0 && return 0
        return 1 + deep(n - 1)
    end

    # Run f() on a freshly created task that has an explicit (large) C stack.
    function run_with_stack(f, stacksize::Int)
        result = Ref{Any}(nothing)
        err = Ref{Any}(nothing)
        done = Threads.Atomic{Bool}(false)
        wrapper = function ()
            try
                result[] = f()
            catch e
                err[] = e
            finally
                done[] = true
            end
        end
        t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int), wrapper, nothing, stacksize)
        t.sticky = false
        schedule(t)
        while !done[]
            sleep(0.02)
        end
        err[] === nothing || throw(err[])
        return result[]
    end

    # Probe max depth with the big stack.
    function probe(maxtry)
        d = 1000
        last = 0
        while d <= maxtry
            ok = try; deep(d); true catch; false end
            ok || break
            last = d
            d *= 2
        end
        return last
    end

    println("1GB stack max depth ~ ", run_with_stack(() -> probe(200_000_000), 1024*1024*1024))
    println("STACK2_DONE")
end

# ---- dispatcher -------------------------------------------------------------
# CHECKS : check_key(문자열) -> 해당 점검 함수 사전. 아래 진입점이 이 사전에서 하나를 골라 실행.
const CHECKS = Dict(
    "load"         => check_load,
    "depot_render" => check_depot_render,
    "stall_gate"   => check_stall_gate,
    "spare_pool"   => check_spare_pool,
    "hot_swap"     => check_hot_swap,
    "scale_cap"    => check_scale_cap,
    "rvo"          => check_rvo,
    "stack"        => check_stack,
    "stack_task"   => check_stack_task,
)
end # module Checks

# 이 파일을 `julia tools/checks.jl <key>` 로 직접 실행했을 때만 아래가 돈다(import 시엔 X).
if abspath(PROGRAM_FILE) == @__FILE__
    # 실행할 점검 키: 환경변수 CHECK 우선, 없으면 첫 CLI 인자, 그것도 없으면 기본값 "load".
    key = get(ENV, "CHECK", isempty(ARGS) ? "load" : ARGS[1])
    haskey(Checks.CHECKS, key) || error("unknown check '$key'. Available: $(join(sort(collect(keys(Checks.CHECKS))), ", "))")
    println(">>> running check: $key")
    Checks.CHECKS[key]()
end
