# tools/monitor/render_demo.jl
# =============================================================================
# run_lego_demo(save_animation=true) 경로로 OOD 데모를 돌려 한 번에:
#   (1) monitor JSONL 스트림  (run_simulation! 의 monitor seam)
#   (2) OOD 시각화가 담긴 per-case MeshCat static html
#       — 고장 로봇=빨강 디스크, 스페어=시안 링, forbid zone=빨간 디스크, depot=파랑 (전부 엔진 내장)
# 복구는 프레임워크 respec 루프가 수행: canonical_producer 가 truth→DSL, hot_swap 으로 완주.
#
# ENV: DEMO_MODEL(파일명) / DEMO_OOD(none|battery|fault|zone|fault_battery|fault_zone|battery_zone)
# 출력: streams/<base>__<case>.jsonl , anim/<base>__<case>.html
# =============================================================================
# ---- ZONE_REPAIR_VERIFICATION=off|shadow|enforce (zone-repair-verification T8) ------------------
# `off`(기본)는 여기서 아무것도 싣지 않는다 — 아래 스크립트가 오늘과 같이 돈다. 그 밖의 값은 이 프로세스를
# 에피소드 driver 로 바꾼다(`src/verification/repair_runtime.jl` — 원래 세계를 부모 worker 로 띄워 t0 에서 세우고
# supervisor 를 돌린다). 값 검사(오타 = 오류)도 그 쪽 `parse_mode` 한 곳이다. `ZRV_BRANCH_ROLE` 이 있으면 이 프로세스가
# 바로 그 worker(부모·분기·commit)이므로 스크립트를 그대로 돈다. 🔴 `let` 이라 Main 전역을 만들지 않는다(checkpoint 대상).
let m = get(ENV, "ZONE_REPAIR_VERIFICATION", "off")
    if m != "off" && !haskey(ENV, "ZRV_BRANCH_ROLE")
        include(joinpath(@__DIR__, "..", "..", "src", "verification", "repair_runtime.jl"))
        exit(Base.invokelatest(getfield(Main, :RepairRuntime).main))
    end
end
using ConstructionBots
using Random
using JSON3
import Graphs
import Logging
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))

const HERE  = @__DIR__
const MODEL = get(ENV, "DEMO_MODEL", "tractor.mpd")
const OODC  = lowercase(get(ENV, "DEMO_OOD", "fault"))
# battery OOD 의 SoC 낙폭. run_demo.jl 과 **같은 이름·같은 기본값**이어야 한다(두 엔진이 같은
# 손잡이를 읽어야 같은 세계를 만든다). 0.96=심각, 0.45 정도면 정책이 갈리는 애매한 구간.
const DEMO_BSOC = try clamp(parse(Float64, get(ENV, "DEMO_BSOC", "0.96")), 0.05, 0.99) catch; 0.96 end
const DEMO_N = try max(0, parse(Int, get(ENV, "DEMO_N", "0"))) catch; 0 end   # # OOD events (0=case default)
# ---------------------------------------------------------------------------------------------
# DEMO_SEED — 로봇 OOD(fault/battery)의 **발생 시점을 확률적으로** 만든다. 이것이 이제 기본값이다.
#
# 왜: 예전에는 발화 지점이 slots=[0.10,0.32,0.55] 로 못박혀 있어 "언제 터질지 모르는 교란"이 아니라
# 대본이었다. schedule_random_ood! (src/navigator/ood_stream.jl) 은 구간을 n 등분한 뒤 각 슬롯 안에서
# ±반슬롯을 흔들고 종류도 kinds 에서 추첨하므로, 같은 케이스라도 seed 가 다르면 다른 세계가 나온다.
#
# ZONE 은 일부러 제외한다 — 공간 restage 는 build step 이 열리기 전에만 transform-safe 하므로
# 존은 예전대로 sim 시작 전 1 회 고정이다(zone 을 무작위 시점에 넣으려면 mid-build restage 가 먼저
# 필요하고, 그건 별건 작업이다).
#
#   DEMO_SEED=1 (기본)  확률적, 재현 가능. 파일 이름에 접미사 없음.
#   DEMO_SEED=k>1       다른 추첨 -> streams/…_sk.jsonl 로 따로 캐시된다.
#   DEMO_SEED=0         옛 고정 슬롯 스케줄(재현용) -> …_s0.jsonl
#
# severity 는 추첨하지 않는다: ① Battery=심각(0.96) / ⑦ Battery(mild)=애매(0.45) 라는 케이스의 의미가
# 무작위 심각도에 씻겨나가면 안 되기 때문. 심각도까지 추첨하려면 DEMO_BSEVERE_FRAC>0 을 준다.
# ---------------------------------------------------------------------------------------------
const DEMO_SEED = try max(0, parse(Int, get(ENV, "DEMO_SEED", "1"))) catch; 1 end
# 🔴 2026-09-22: `DEMO_OOD_SEED` 는 헤드리스 엔진(`run_demo.jl`)의 이름이고 **이 엔진은 안 읽는다**.
#    09-06 SMDP 120판 드라이버가 그 이름을 넘겨 router all3 60판(두 모델)이 전부 seed=1 로 돌았다 —
#    조용히. 넘겼는데 DEMO_SEED 와 다르면 기동 시 멈춘다(같으면 무해하므로 통과).
let s = strip(get(ENV, "DEMO_OOD_SEED", ""))
    isempty(s) || s == string(DEMO_SEED) || error(
        "[render_demo] DEMO_OOD_SEED=$s 는 이 엔진이 읽지 않는다 — DEMO_SEED 를 쓸 것 (지금 DEMO_SEED=$(DEMO_SEED))")
end
const DEMO_BSEVERE = try clamp(parse(Float64, get(ENV, "DEMO_BSEVERE_FRAC", "0.0")), 0.0, 1.0) catch; 0.0 end
# ---------------------------------------------------------------------------------------------
# DEMO_ZONE_SEED — **금지구역의 위치와 크기**를 시드로 뽑는다. 0(기본) 이면 예전 결정적 배치와
# 바이트 동일하다. 🔴 `DEMO_SEED` 와 **다른 축이다**: `DEMO_SEED` 는 세계/로봇 배치와 사건 시점을
# 뽑고, 이쪽은 그 세계 위에 구역을 어디에 얼마나 크게 놓느냐만 뽑는다. 둘을 한 이름으로 묶으면
# "존만 바꾼 대조" 를 만들 수 없다(이 레인이 재려는 것이 정확히 그것이다).
const DEMO_ZONE_SEED = try max(0, parse(Int, get(ENV, "DEMO_ZONE_SEED", "0"))) catch; 0 end
const DEMO_ZONE_R_MIN = try parse(Float64, get(ENV, "DEMO_ZONE_R_MIN", "0.35")) catch; 0.35 end
const DEMO_ZONE_R_MAX = try parse(Float64, get(ENV, "DEMO_ZONE_R_MAX", "1.10")) catch; 1.10 end
# safe=true 는 "단독 운반체만 고장낸다"(팀 운반 중인 로봇을 고장내면 교체가 has_edge 에서 터질 수
# 있다는 옛 우려). 그런데 측정해 보니 tractor 에서 그 조건이 성립하는 구간은 **step 2~20 뿐**이고
# 이후 빌드 전체에서 한 번도 성립하지 않는다(DEMO_PROBE=1, 40 프로브 중 1 회). 그 창에 묶이면
# "언제 터질지 모르는 고장"이 성립하지 않는다 -- 늘 같은 순간, 늘 같은 로봇(R1)이 된다.
#
# safe=false 로 중반(step 188, 진척 43%) 고장을 실제로 넣어 확인했다: 교체 경로가 정상 동작하고
# 빌드가 완주했다(hot-swap enact 가 들어온 뒤로 옛 has_edge 우려는 해소된 것으로 보인다).
# 그래서 기본값을 false 로 둔다 -- 무작위 시점이 실제로 의미를 갖는 유일한 설정이다.
# 문제가 생기는 조합이 있으면 그 셀만 DEMO_FAULT_SAFE=1 로 되돌리면 된다.
const FAULT_SAFE = get(ENV, "DEMO_FAULT_SAFE", "0") != "0"
const SSUF   = DEMO_SEED == 1 ? "" : "_s$(DEMO_SEED)"
const ZSUF   = DEMO_ZONE_SEED == 0 ? "" : "_z$(DEMO_ZONE_SEED)"
const NSUF   = (DEMO_N > 0 ? "_n$(DEMO_N)" : "") * SSUF * ZSUF   # stream/anim name suffix so each (count, seed, zone-seed) caches separately
const COMMAND_FILE = get(ENV, "MONITOR_COMMAND_FILE", "")
const INTERACTIVE = get(ENV, "MONITOR_INTERACTIVE", "0") == "1"
const RUN_ID = get(ENV, "MONITOR_RUN_ID", "")
# 대화형 세션이 **첫 조작자 명령(보통 forbid zone)** 을 기다리는 시간[초]. 0 = 기다리지 않고
# 곧바로 시작한다 = "zone 없이 이 케이스만 돌려 본다".
#   왜 필요한가: 예전에는 300 초가 하드코딩이라, zone 을 넣을 생각이 없어도 5 분을 앉아 있거나
#   창을 닫아야 했다. 그런데 zone 주입 여부는 결과를 크게 가른다(2026-08-05 실측: 같은
#   fault_battery 판이 zone 없으면 완주, 라이브 zone→RelocateBuild 가 끼면 134/305 에서 정지).
#   그래서 "기다린다/안 기다린다"는 실험 조건이지 편의 옵션이 아니다 — 명시적으로 고를 수 있어야 한다.
#   0 으로 시작해도 조작 훅은 그대로 살아 있어서, 런 도중 대시보드에서 zone 을 쏘는 것은 여전히 된다.
const MONITOR_WAIT = try max(0.0, parse(Float64, get(ENV, "MONITOR_WAIT", "300"))) catch; 300.0 end
# MONITOR_REQUIRE_ZONE=1 — **조작자가 구역을 정의하기 전에는 시뮬레이션을 시작하지 않는다.**
#   왜 MONITOR_WAIT 로 안 되나: 그건 마감이 있는 대기라서, 시간이 지나면 **zone 없이 그냥 출발한다**.
#   그러면 ③⑤⑥ 은 "구역 사건"이라는 이름만 남고 구역이 없는 런이 조용히 성립한다 — 결과가 아니라
#   사고다(같은 함정을 zone 자동 주입기에서도 폴백으로 막아 두었다: 683-686 줄).
#   구역이 사람이 정하는 사건인 케이스에서는 마감이 아니라 **게이트**가 맞다. 무한 대기가 부담이면
#   조작자가 abort 명령으로 끝낼 수 있다(pending_command_kind 참조).
const REQUIRE_ZONE = get(ENV, "MONITOR_REQUIRE_ZONE", "0") == "1"
# 애니메이션(anim/*.html) 산출물을 남길지. 기본 켜짐 — 라이브 세션에서도 남는다(아래 주석 참조).
const DEMO_ANIM = get(ENV, "DEMO_ANIM", "1") != "0"
# 팀 교착(reform) OOD 발화 간격 = 연속 무진전 스텝 수. 프레임워크 기본은 2000 인데 이 데모의
# 종료 한계가 3000 이라 **단 한 번** 쏘고 실패하면 그대로 죽는다(실측: 7/8 에서 PROJECT INCOMPLETE).
# 400 이면 종료 전에 여러 번 시도할 수 있다. reform 은 교착이 없으면 안전한 no-op 이므로 낮춰도
# 정상 런에 영향이 없다(ood_injection.jl REFORM_INTERVAL 주석과 같은 논리). 0 = 프레임워크 기본 유지.
const DEMO_REFORM = try max(0, parse(Int, get(ENV, "DEMO_REFORM", "400"))) catch; 400 end
# 발화 횟수 상한. 상한이 없으면 교착이 reform 으로 안 풀리는 판에서 400 스텝마다 계속 쏴서
# (실측 9회) **LLM 을 9번 부르고** recover 가 :snapped → :force_snapped 로 굳어진다.
# force snap 은 팀 구성을 강제로 바꾸므로 반복하면 함대를 휘저을 뿐 진전을 만들지 못한다.
const DEMO_REFORM_MAX = try max(1, parse(Int, get(ENV, "DEMO_REFORM_MAX", "3"))) catch; 3 end
const _REFORM_CT = Ref(0)
const _REFORM_EXHAUSTED_SAID = Ref(false)   # 소진 표지를 판마다 한 번만 찍는다(관측 전용)
# ---------------------------------------------------------------------------------------------
# 로그 레벨. run_lego_demo 의 기본값은 Logging.Warn 이라 시뮬레이션 안의 **모든 @info 가 버려진다**.
# 2026-08-05 규명: 그래서 WEDGE_DEBUG=1 / NAV_DEBUG=1 을 켜도 이 경로에서는 아무것도 안 찍혔다 —
# 진단 덤프(_dump_forming_team_blockers, [carrier-rescue] is_goal 분석)가 전부 @info 이기 때문이다.
# 두 플래그는 "진단을 보겠다"는 뜻이므로, 켜져 있으면 로그 레벨도 같이 Info 로 내린다.
# (동시에 [RESPEC] OOD event / [WHOLE-BUILD] Δ / [ROUTER] 도 그제야 보인다.)
const DEMO_DEBUG = get(ENV, "WEDGE_DEBUG", "0") == "1" || get(ENV, "NAV_DEBUG", "0") == "1" ||
                   get(ENV, "DEMO_VERBOSE", "0") == "1"
const DEMO_LOGLEVEL = DEMO_DEBUG ? Logging.Info : Logging.Warn
# 직전 reform 시점의 closed 노드 수. "이번 reform 이 실제로 빌드를 전진시켰나"를 판정하는 기준선.
const _REFORM_LAST_CLOSED = Ref(-1)

# per-model 파라미터: project_params 에서 파일명으로 찾음(scale·robot 수).
function find_params(model)
    return try CB.get_project_params(model) catch; nothing end
end
pp    = find_params(MODEL)
NROB  = pp === nothing ? parse(Int, get(ENV, "DEMO_ROBOTS", "10")) : pp[:num_robots]
SCALE = pp === nothing ? 0.008 : pp[:model_scale]
model_base  = replace(splitext(basename(MODEL))[1], r"[^A-Za-z0-9]+" => "_")

# ── 목적함수 가중치 (spec §5·§6.3, 계획 단계 6) ────────────────────────────────
# run_demo.jl:430-440 과 같은 스위치를 이 레인에도 둔다. 이것이 없으면
# `AUTO_EFFICIENCY_KAPPA[]` 가 기본값 `nothing` 으로 남고(essential_tg_coponents.jl:1319),
# `get_objective_expr` 의 auto 경로는 `w_eff == 0.0 && AUTO_EFFICIENCY_KAPPA[] !== nothing`
# 일 때만 발화하므로(:1439) **에너지 항이 이 레인에서 영영 안 실린다.**
#
# ⚠️ run_demo.jl 과 달리 여기서는 이 블록이 **동작 중립이 아니다.**
#    · 초기 배정은 여기서도 안 바뀐다 — `assignment_mode=:greedy` 이고 greedy 는
#      `get_objective_expr` 를 부르지 않는다(run_demo.jl:422 의 논증과 동일).
#    · 그러나 이 레인은 :731 에서 `RESPEC_ENABLED[] = true` 로 두고 **respec 재풀이를 돌린다.**
#      그 재풀이가 `get_objective_expr` 를 타므로 κ 가 OOD 이후의 계획을 실제로 바꾼다.
#      run_demo.jl 은 :484 에서 `RESPEC_ENABLED[] = false` 라 그 경로가 없다 — 그래서 저쪽은
#      중립이고 이쪽은 아니다. 이 차이 때문에 대시보드에 올라가는 판은 이 블록이 없으면
#      **구세대 동역학으로 렌더된다.**
const ENERGY_ON = get(ENV, "ENERGY_OBJECTIVE", "1") == "1"
if ENERGY_ON
    let w = CB.init_objective_weights!()
        println(">>> objective weights: κ=$(w.kappa) w_g=$(w.w_g)")
    end
else
    println(">>> objective weights: DISABLED (ENERGY_OBJECTIVE=0) — 구세대 동작")
end
# 세대 딱지. 이 렌더가 어느 목적함수로 만들어졌는지 로그에 남긴다(spec §7) — 산출물이
# 스트림/애니 뿐이라 행에 박을 자리가 없으므로 로그가 유일한 provenance 다.
let _objjl = joinpath(HERE, "..", "..", "src", "decision", "core", "objective.jl")
    try
        Base.include(Main, _objjl)
        println(">>> objective_hash: $(Main.Objective.objective_hash())  energy_objective=$(ENERGY_ON ? 1 : 0)")
    catch e
        @warn "objective_hash 를 읽지 못했다 — 이 렌더의 세대를 로그로 판정할 수 없다" exception = e
    end
end

# 산출물 이름에 쓰는 케이스 이름. 보통 DEMO_OOD 와 같지만, 프리셋 케이스(⑦ battery_mild = battery 를
# 애매한 SoC 로 돌린 것)는 **실행 케이스와 표시 이름이 다르다**. 그때 서버가 DEMO_CASE_TAG 로 표시
# 이름을 넘겨 주지 않으면 ⑦ 의 녹화가 ① battery 파일을 덮어썼다.
const CASE_TAG = get(ENV, "DEMO_CASE_TAG", OODC)
# 산출물 뿌리. 비어 있으면(기본) tools/monitor/ 그대로 — 공유 streams/·anim/ 에 쓴다.
# 값을 주면 그 아래 streams/·anim/ 을 만든다: 탐침 판이 대시보드가 읽는 공유 폴더를 덮지 않게 한다.
# 켜져 있을 때만 미완주 판의 애니도 `__INCOMPLETE` 를 붙여 남긴다(아래 거절 분기).
const DEMO_OUT_DIR = get(ENV, "DEMO_OUT_DIR", "")
out_root    = isempty(DEMO_OUT_DIR) ? HERE : abspath(DEMO_OUT_DIR)
stream_dir  = joinpath(out_root, "streams"); mkpath(stream_dir)
anim_dir    = joinpath(out_root, "anim");    mkpath(anim_dir)
stream_path = joinpath(stream_dir, "$(model_base)__$(CASE_TAG)$(NSUF).jsonl")
# 정지 탐침(관측 전용). 꺼져 있으면 파일을 읽지도 않는다 — 훅이 `nothing` 으로 남는다.
if get(ENV, "STALL_PROBE", "0") == "1"
    include(joinpath(@__DIR__, "stall_probe.jl"))
    STALL_PROBE_OUT[] = get(ENV, "STALL_PROBE_OUT", replace(stream_path, r"\.jsonl$" => ".stall.jsonl"))
    isfile(STALL_PROBE_OUT[]) && rm(STALL_PROBE_OUT[])
    CB.STALL_PROBE_HOOK[] = stall_snapshot
    println("[stall-probe] ON → ", STALL_PROBE_OUT[])
end

_rl(rid) = try "R" * string(getfield(rid, :id)) catch; replace(string(rid), r"\s+" => " ") end

function case_kinds(c)
    c == "none"          && return Symbol[]
    c == "battery"       && return [:battery]
    c == "fault"         && return [:fault]
    c == "fault_battery" && return [:fault, :battery]
    # 2026-08-16: run_demo.jl(스윕 엔진)의 case_kinds 와 여기(렌더 엔진)의 표가 갈라져 있었다 —
    # "all" 분기가 여기 없어서 폴백 [:fault] 로 떨어졌고, all case 72판(canonical/surrogate/dspy
    # × 30 seed)이 battery(그리고 zone) 사건을 한 번도 armed 하지 않은 채 fault-only 로
    # 조용히 렌더됐다(courier 자체가 화면에 안 나온 원인). 두 엔진의 케이스 표는 **반드시
    # 일치**해야 한다 — run_demo.jl 의 case_kinds 와 같은 값을 낸다.
    c == "all"            && return [:fault, :battery]
    # 🔴 2026-08-24 (spec §5.1, Task 4): zone 계열(zone/fault_zone/battery_zone)을 여기서도 뺐다.
    # run_demo.jl 만 고치고 이 표를 그대로 뒀다면 위 2026-08-16 회귀가 **거울상으로** 재현된다:
    # `DEMO_OOD=all` 이 스윕 엔진에서는 [:fault,:battery], 렌더 엔진에서는 [:fault,:battery,:zone]
    # 이 되어 두 엔진이 다른 세계를 굴린다. 폴백도 같이 없앤다 — 없앤 케이스를 요청하면 조용히
    # fault 판으로 돌지 말고 큰 소리로 죽어야 한다.
    error("DEMO_OOD=$(c) 는 없는 케이스다. zone 계열은 2026-08-24 에 LLM 결정 레인에서 " *
          "제거됐다(spec §5.1). 가능한 값: none|fault|battery|fault_battery|all")
end

const _ZONE_CT = Ref(0)

function assembly_at_zone(env, c, r)
    best = nothing; best_overlap = -Inf
    for (aid, ball) in env.staging_circles
        bc = Vector{Float64}(CB.get_center(ball)[1:2])
        overlap = Float64(CB.get_radius(ball)) + r - hypot(bc[1] - c[1], bc[2] - c[2])
        if overlap > best_overlap
            best, best_overlap = aid, overlap
        end
    end
    return best_overlap >= 0 ? best : nothing
end

function inject_live_zone!(env, x, y, r, command_id, iter)
    c = Float64[x, y]
    key = Symbol("live_zone_", replace(String(command_id), r"[^A-Za-z0-9]" => "_"))
    z = CB.add_restriction_zone!(key, c, r)
    aid = assembly_at_zone(env, c, r)
    # 관찰만 적는다 — 뒷절("reroute" / "restage that assembly")은 곧 정답이라 지시가 된다.
    nl = "A human operator injected a no-go exclusion zone at ($(round(x; digits=2)), " *
         "$(round(y; digits=2))) with radius $(round(r; digits=2))." *
         (aid === nothing ? " Robots that enter the disc are pushed back out of it." :
          " It overlaps the staging area of assembly $aid.")
    CB.record_ood_truth!(nl, CB.ZoneTruth(key, c, Float64(CB.get_radius(z)), aid); at=iter)
    # Scheduled OOD wrappers enqueue automatically, but a live command bypasses
    # that scheduler. Explicitly enqueue so respec_step! handles it immediately.
    CB.push_ood!(nl)
    println("[live] forbid zone id=$command_id center=($x,$y) r=$r assembly=$aid")
    return nothing
end

function command_file_hook(path)
    offset = Ref{Int64}(0)
    return function (env, factory_vis, anim, iter)
        isempty(path) && return nothing
        isfile(path) || return nothing
        open(path, "r") do io
            seek(io, min(offset[], filesize(path)))
            for line in eachline(io)
                isempty(strip(line)) && continue
                try
                    cmd = JSON3.read(line)
                    String(cmd[:type]) == "forbid_zone" &&
                        inject_live_zone!(env, Float64(cmd[:x]), Float64(cmd[:y]), Float64(cmd[:r]), String(cmd[:id]), iter)
                catch e
                    println("[live] rejected command: ", sprint(showerror, e))
                end
            end
            offset[] = position(io)
        end
        return nothing
    end
end

# =============================================================================================
#  평면도 덤프 — 조작자가 **어디에** 구역을 그을지 볼 수 있게 한다 (2026-08-08)
# =============================================================================================
# 지금까지 라이브 zone 은 대시보드의 X/Y/R 숫자 칸으로 넣었다. 그런데 그 화면에는 공장 바닥이 어떻게
# 생겼는지가 **없다** — MeshCat 뷰는 시뮬레이션이 시작돼야 뜨는데, 구역은 시작 전에 정해야 한다.
# 즉 조작자는 눈을 감고 좌표를 치고 있었고, 그 상태로는 "사람이 구역을 정의한다"가 성립하지 않는다:
# 아무것도 안 막는 자리를 찍으면 정답이 NOOP 인 판이 되는데, 그건 고른 것이 아니라 뽑기다.
#
# sim 전 기하는 이미 전부 정해져 있다(적치원은 env 빌드 때 select_assembly_start_configs_layered! 가
# 배치한다). 그래서 첫 스텝 전에 한 번 JSON 으로 떨어뜨리면 대시보드가 2D 평면도를 그릴 수 있다.
# env 를 **읽기만** 한다 — 이 덤프는 시뮬레이션 상태를 바꾸지 않는다.
layout_path(cmdfile) = isempty(cmdfile) ? "" :
    joinpath(dirname(cmdfile), splitext(basename(cmdfile))[1] * ".layout.json")

function dump_layout(env, cmdfile)
    path = layout_path(cmdfile)
    isempty(path) && return false
    staging = Vector{Dict{String,Any}}()
    for (aid, ball) in env.staging_circles
        c = try Vector{Float64}(CB.get_center(ball)[1:2]) catch; continue end
        r = try Float64(CB.get_radius(ball)) catch; continue end
        (length(c) == 2 && all(isfinite, c) && isfinite(r)) || continue
        push!(staging, Dict{String,Any}("id" => string(aid), "x" => c[1], "y" => c[2], "r" => r))
    end
    # 로봇 위치는 있으면 좋은 참고이지 평면도의 필수 요소가 아니다(구역은 적치원·통로에 대해 정한다).
    # 그래서 여기서 실패해도 덤프 전체를 포기하지 않는다 — 그러면 그리기 화면 자체가 안 뜬다.
    robots = Vector{Dict{String,Any}}()
    try
        for n in CB.get_nodes(env.scene_tree)
            CB.matches_template(CB.RobotNode, n) || continue
            p = try collect(CB.global_transform(n).translation)[1:2] catch; continue end
            (length(p) == 2 && all(isfinite, p)) || continue
            push!(robots, Dict{String,Any}("id" => _rl(CB.node_id(n)), "x" => p[1], "y" => p[2]))
        end
    catch e
        println("[layout] 로봇 위치 수집 실패 — 적치원만으로 평면도를 그린다: ", sprint(showerror, e))
    end
    isempty(staging) && isempty(robots) && return false
    xs = vcat([s["x"] - s["r"] for s in staging], [s["x"] + s["r"] for s in staging],
              [r["x"] for r in robots])
    ys = vcat([s["y"] - s["r"] for s in staging], [s["y"] + s["r"] for s in staging],
              [r["y"] for r in robots])
    pad = max(0.5, 0.08 * max(maximum(xs) - minimum(xs), maximum(ys) - minimum(ys)))
    rr = try Float64(CB.default_robot_radius()) catch; 0.25 end
    # focus = 화면을 맞출 창. **가장 큰 적치원 하나를 뺀** 나머지에 맞춘다.
    #   루트 조립체의 적치원은 구성상 현장 전체를 감싼다(실측 tractor: r=9.64 vs 나머지 0.48~3.79).
    #   거기에 맞추면 실제로 구역을 놓을 자리(로봇 무리·작은 적치원, 반경 0.3 안팎)가 화면의 몇 % 로
    #   쪼그라들어 사람이 크기를 가늠할 수 없다. 큰 원은 그려지되 화면 밖으로 넘칠 뿐이다.
    focus = Dict{String,Any}()
    if length(staging) > 1 || !isempty(robots)
        keep = length(staging) > 1 ?
               sort(staging; by = s -> -s["r"])[2:end] : staging   # 최대 반지름 하나 제외
        fxs = vcat([s["x"] - s["r"] for s in keep], [s["x"] + s["r"] for s in keep],
                   [r["x"] for r in robots])
        fys = vcat([s["y"] - s["r"] for s in keep], [s["y"] + s["r"] for s in keep],
                   [r["y"] for r in robots])
        if !isempty(fxs)
            fpad = max(0.5, 0.15 * max(maximum(fxs) - minimum(fxs), maximum(fys) - minimum(fys)))
            focus = Dict{String,Any}("xmin" => minimum(fxs) - fpad, "xmax" => maximum(fxs) + fpad,
                                     "ymin" => minimum(fys) - fpad, "ymax" => maximum(fys) + fpad)
        end
    end
    payload = Dict{String,Any}(
        "model" => MODEL, "case" => CASE_TAG, "requires_zone" => REQUIRE_ZONE,
        "robot_radius" => rr, "staging" => staging, "robots" => robots,
        "extent" => Dict{String,Any}("xmin" => minimum(xs) - pad, "xmax" => maximum(xs) + pad,
                                     "ymin" => minimum(ys) - pad, "ymax" => maximum(ys) + pad),
        "focus" => isempty(focus) ? nothing : focus)
    # 대시보드가 폴링으로 읽으므로 **반쯤 쓰인 파일**을 보면 안 된다 → 임시 파일에 쓴 뒤 이름을 바꾼다.
    tmp = path * ".tmp"
    open(tmp, "w") do io; JSON3.write(io, payload); end
    mv(tmp, path; force = true)
    println("[layout] 평면도 → $(basename(path))  (적치원 $(length(staging)) · 로봇 $(length(robots)))")
    return true
end

include(joinpath(@__DIR__, "run_header.jl"))
include(joinpath(@__DIR__, "zone_gate.jl"))    # DEMO_ZONE/DEMO_ZONE_AT 게이트(run_demo.jl 과 공용)
include(joinpath(@__DIR__, "zone_command.jl"))

# 2026-08-13: 아래 독스트링이 이 두 `include` **앞에** 있었다. Julia 는 독스트링 바로 뒤의 식을
# 문서화 대상으로 삼는데 `include(...)` 는 문서화할 수 없어서, 파일 전체가
# `ERROR: cannot document the following expression` 로 로드조차 되지 않았다(0063e6a 이후 계속).
# render_demo.jl 은 3D 애니메이션 경로이자 대시보드의 `POST /run` 이 부르는 파일이므로,
# 그동안 라이브 렌더도 같이 죽어 있었다. 독스트링을 원래 설명 대상 함수 위로 되돌린다.
"명령 파일에 이미 들어와 있는 조작자 명령의 종류. `:abort` 가 하나라도 있으면 그게 이긴다."
function pending_command_kind(path)
    (isfile(path) && filesize(path) > 0) || return :none
    kind = :none
    try
        for line in eachline(path)
            isempty(strip(line)) && continue
            cmd = try JSON3.read(line) catch; continue end
            t = try String(cmd[:type]) catch; "" end
            t == "abort" && return :abort
            t == "forbid_zone" && (kind = :zone)
        end
    catch
    end
    return kind
end

# =============================================================================================
#  구역 OOD 의 **두 가족** (2026-08-05)
# =============================================================================================
# 지금까지 이 데모의 zone 은 `inject_staging_zone!` 하나였고, 그 함수는 읽어 보면 **무해하도록
# 설계돼 있다**: 후보를 `zone_clears_root_goals` 로 걸러 root 목표를 일부러 피하고(195줄),
# 미완 작업 디스크와 겹침이 최소인 후보를 고르며(197-201줄), sim 시작 **전에** 심는다.
# 그래서 "적치원 가장자리를 스치는, 최대한 안 겹치는 작은 원"이 되고 — 완주는 늘 확인됐지만
# 그건 결정이 옳아서가 아니라 **애초에 아무것도 안 막았기 때문**이다(zone_corridor.jl 의 측정:
# 구역 강제는 RVO 에이전트만 스냅하므로 화물 운동학 목표는 원리적으로 못 막는다).
#
# 두 가족이 다 있어야 "언제 개입하고 언제 절제하는가"가 비로소 결정 문제가 된다:
#   DEMO_ZONE_MODE=blocking (기본) — RVO 로 움직이는 주체의 **미래 목표** 위에 심는다.
#       개입하지 않으면 그 노드는 구역이 살아 있는 한 절대 못 닫는다 → 개입이 정답.
#   DEMO_ZONE_MODE=harmless — 옛 주입기 그대로. 아무것도 막지 않으므로 NOOP 이 정답이고,
#       "막힘을 보이기 시작한 정책이 개입 쪽으로 쏠리지 않았는지" 재는 반대 방향 대조군.
#
# ★ 완주 검증(2026-08-05): 세 zone 케이스 모두 blocking 으로 완주한다. 한때 `battery_zone` 이
#   미완주해 기본값을 harmless 로 두었었는데, 그건 구역 탓이 아니라 **두 시뮬을 동시에 돌린 탓**이었다:
#   run_lego_demo 는 HiGHS MILP 로 스케줄을 푸는데 CPU 경합이 다르면 다른 해를 돌려준다(같은 목표
#   좌표인데 vtx 148 vs 143). 단독 실행 3/3 완주(277·275·277). 그래서 **런은 절대 병렬로 돌리지 말 것** —
#   병렬로 비교하면 정책 비교가 아니라 서로 다른 두 세계의 비교가 된다.
#   자세한 기록: wm4spacecraft_manufacturing/md/ZONE_REDESIGN_STEP1_7_2026-08-05.md 부록 C.
const DEMO_ZONE_MODE = lowercase(get(ENV, "DEMO_ZONE_MODE", "blocking"))
# 막는 구역의 반지름 = 로봇 반지름의 배수. tools/restage.jl 의 causal 하니스(ZC_R)와 같은 기본값.
const DEMO_ZONE_R = try max(0.05, parse(Float64, get(ENV, "DEMO_ZONE_R", "0.5"))) catch; 0.5 end
# 발화 시점(닫힌 노드 수). restage.jl causal 이 blk_reloc 완주를 얻은 그 지점(ZC_FIRE=58)과 동일.
#
# 왜 sim 전이 아니라 **발화 시점**인가: `_nav_goal_targets` 는 살아 있는 env 에서 평가해야 뜻이 있고
# (아직 활성이 아닌 미래 목표를 골라야 한다), 어차피 ForbidZone 의 "미시작 조립체" 전제는 respec 이
# 처리되는 시점(closed≈54)이면 이미 깨져 있다. 그래서 로봇 OOD 와 같은 스케줄러 경로에 얹는다.
const DEMO_ZONE_CLOSED = try max(0, parse(Int, get(ENV, "DEMO_ZONE_CLOSED", "58"))) catch; 58 end
# 존을 **첫 시뮬레이션 스텝 이전**에 심을지(기본 1 = 심는다, 2026-08-08).
#
# 왜 바꿨나: 위 예약 방식은 세 zone 케이스(③⑤⑥)에서 "구역이 빌드 도중에 나타난다"를 뜻하지 않았다.
# tractor 는 첫 배치에서 노드 58 개를 한꺼번에 닫으므로 closed=58 예약은 **시작 직후**에 due 되고
# (SUMMARY_FORBIDZONE_RETRAIN §1), 그 사이 구간은 예약으로 도달할 수 없다. 게다가 배치 엔진
# run_demo.jl 은 처음부터 pre-sim 주입이었다 — 같은 케이스를 두 엔진이 다르게 만들고 있었다.
# 이제 렌더 엔진도 pre-sim 으로 맞춘다: 구역이 먼저 서고, 그 위에서 시뮬레이션이 시작된다.
# 로봇 OOD(fault/battery)의 확률적 발화 시점은 이 값과 무관하다 — 그쪽은 DEMO_SEED 가 정한다.
# 0 = 예전 동작(DEMO_ZONE_CLOSED 예약) 재현.
const DEMO_ZONE_PRESIM = get(ENV, "DEMO_ZONE_PRESIM", "1") != "0"

"""
    inject_blocking_zone!(env; frac) -> Union{Nothing,String}

**실제로 막는** no-go 구역을 하나 심고 그 관찰문을 돌려준다.
`tools/restage.jl::place_blocking_zone_on_nav_goal!` 의 절차를 그대로 옮긴 것(이미 검증된 순서):

1. 후보 = `_nav_goal_targets` 중 **아직 활성이 아닌** 목표(로봇이 이미 그리로 날아가는 중이면
   구역이 그 로봇을 원 밖으로 밀어내 사고가 된다 — 결정 문제가 아니다).
2. 운반유닛 목표를 먼저, 그다음 빌드 중심에 가까운 순 — **결정적** 정렬(재현 가능).
3. `zone_relocatable` 을 통과한 것만 = **복구 가능한 것만** 심는다. 복구 불가한 구역을 심는 것은
   결정을 재는 게 아니라 사고를 연출하는 것이다.
4. 심은 뒤 `zone_blockage(...).n_blocked >= 1` 로 **실제로 막혔는지 확인**하고, 아니면 지우고 다음 후보.

관찰문에는 "그러니 무엇을 하라"를 붙이지 않는다(STEP 4). 무엇이 막혔는지는 정책이 기하 원시값에서
읽어야 하고, 문장이 답을 흘리면 재는 것이 추론이 아니라 프롬프트 준수가 된다.
"""
function inject_blocking_zone!(env; frac = DEMO_ZONE_R)
    isempty(env.staging_circles) && return nothing
    navs = try CB._nav_goal_targets(env) catch e
        @warn "[zone] _nav_goal_targets 실패" exception = e; return nothing
    end
    isempty(navs) && return nothing
    ks = collect(keys(env.staging_circles))
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), ks)
    c0 = Vector{Float64}(CB.get_center(env.staging_circles[root])[1:2])
    cand = [t for t in navs if !(t.vtx in env.cache.active_set)]
    # 🔴 정준 정렬을 **먼저** 한다. 난수를 쓰든 안 쓰든 뒤이은 순회 순서가 재현되게 하려면
    #    셔플의 입력 자체가 결정적이어야 한다(`Dict` 순회 순서에 물린 옛 재현성 사고와 같은 논거).
    sort!(cand; by = t -> (t.kind === :transport ? 0 : 1, hypot(t.goal[1] - c0[1], t.goal[2] - c0[2])))
    # ---- 존 배치 난수화 (DEMO_ZONE_SEED) -------------------------------------------------
    # 0 이면 아무것도 안 뽑는다 -- `rng` 를 만들지도, `frac` 을 건드리지도, 셔플하지도 않으므로
    # 예전 배치와 **바이트 동일**하다(음성 대조가 이 성질을 잰다).
    rng = DEMO_ZONE_SEED == 0 ? nothing : Random.MersenneTwister(DEMO_ZONE_SEED)
    if rng !== nothing
        lo, hi = minmax(DEMO_ZONE_R_MIN, DEMO_ZONE_R_MAX)
        frac = lo + (hi - lo) * rand(rng)          # 크기를 뽑는다
        Random.shuffle!(rng, cand)                 # 위치(어느 목표 위에 놓을지)를 뽑는다
    end
    r = frac * Float64(CB.default_robot_radius())
    _ZONE_CT[] += 1; key = Symbol("zone_blk_$(_ZONE_CT[])")
    for t in cand
        # 중심을 목표점에서 살짝 흔든다 -- 안 흔들면 원의 중심이 늘 어떤 목표의 정확한 좌표라
        # "위치가 다양하다" 가 목표 격자 위에서만 성립한다. 반지름의 절반까지만 흔들어
        # 그 목표가 여전히 원 안에 남게 한다(안 그러면 아무것도 안 막고 후보만 태운다).
        goal = if rng === nothing
            t.goal
        else
            θ = 2π * rand(rng); ρ = 0.5 * r * sqrt(rand(rng))
            g = Vector{Float64}(t.goal)
            g[1] += ρ * cos(θ); g[2] += ρ * sin(θ); g
        end
        CB.zone_relocatable(goal, r, env) || continue          # 복구 가능한 것만
        z = CB.add_restriction_zone!(key, goal, r)
        b = try CB.zone_blockage(env; zone_keys = [key], check_paths = false) catch e
            @warn "[zone] zone_blockage 실패" exception = e; nothing
        end
        if b !== nothing && b.n_blocked >= 1
            c = Vector{Float64}(goal)
            println("[zone] blocking zone on $(t.kind) vtx=$(t.vtx) @$(round.(c; digits = 3)) " *
                    "r=$(round(r; digits = 3)) -> nav_blocked=$(b.n_blocked)/$(b.n_nav_goals)")
            # ---- 구역 진단 계측 (2026-08-30, T4) -----------------------------------------
            # 🔴 위 줄의 `nav_blocked=` 는 `zone_blockage(...).n_blocked` = **항법 차단**이다.
            #    아래 `zd.n_blocked` 는 `zone_diagnosis` 의 것으로 **막힌 조립체 수**다 —
            #    다른 술어다. 둘을 합치지 않는다. 왜 이 값이 필요한가: `zd.n_blocked == 0` 이면
            #    zone 원시들(`restage_all_blocked` …)이 `:none` 으로 조기 반환해 zone 레인이
            #    **알파벳 이유로** 실패한다. 모델 이유(합성이 틀린 body 를 냈다)와 구분되지
            #    않으면 다음 태스크가 유료 보드를 그 구분에 쓰게 된다.
            #
            # 🔴 **오라클 라벨은 찍지 않는다**: `verdict` · `relocate_norm`(= 오라클의
            #    `min_shift_to_clear_m`) · `relocate_delta` · `relocate_feasible`. 원시값
            #    (`n_*` · `root_*`)만 찍는다 — 정답을 프롬프트 경로에 실을 수 있는 자리다.
            local zd = try CB.zone_diagnosis(env, key; check_paths = false) catch e
                println("[zone] diag FAILED: ", first(split(sprint(showerror, e), "\n"))); nothing end
            zd === nothing || println("[zone] diag n_blocked=$(zd.n_blocked) n_nav_blocked=$(zd.n_nav_blocked) ",
                "root_covered=$(zd.root_covered)/$(zd.root_total) n_work_overlap=$(zd.n_work_overlap) ",
                "n_teams_covered=$(zd.n_teams_covered) n_nav_goals=$(zd.n_nav_goals) ",
                "n_nav_engulfed=$(zd.n_nav_engulfed) n_agent_trapped=$(zd.n_agent_trapped)")
            nl = "A no-go exclusion zone has appeared at ($(round(c[1]; digits = 2)), " *
                 "$(round(c[2]; digits = 2))) with radius $(round(r; digits = 2)). " *
                 "Robots that enter the disc are pushed back out of it."
            try CB.record_ood_truth!(nl,
                CB.ZoneTruth(key, Float64[c[1], c[2]], Float64(CB.get_radius(z)), nothing)) catch end
            return nl
        end
        CB.remove_restriction_zone!(key)
    end
    println("[zone] no blocking placement found (every candidate was active or unrecoverable)")
    return nothing
end

function inject_staging_zone!(env; frac = parse(Float64, get(ENV, "DEMO_ZONE_SCALE", "0.20")))
    isempty(env.staging_circles) && return nothing
    ks   = collect(keys(env.staging_circles))
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), ks)
    for (aid, ball) in env.staging_circles
        aid == root && continue
        ac = try CB._assembly_complete_node(env, aid) catch; nothing end
        ac === nothing && continue
        v = try CB.get_vtx(env.sched, CB.node_id(ac)) catch; nothing end
        (v === nothing || v in env.cache.closed_set || v in env.cache.active_set ||
         CB._assembly_started(env, aid)) && continue
        c = Vector{Float64}(CB.get_center(ball)[1:2]); r = Float64(CB.get_radius(ball))
        zr = r * frac
        overlap = min(0.25r, 0.5zr)
        offset = max(0.0, r + zr - overlap)
        work = CB._future_work_discs(env)
        candidates = [c .+ offset .* [cos(2pi*k/24), sin(2pi*k/24)]
                      for k in 0:23]
        candidates = [q for q in candidates if CB.zone_clears_root_goals(q, zr, env)]
        if !isempty(candidates)
            score(q) = count(work) do disc
                wc, wr = disc
                hypot(q[1] - wc[1], q[2] - wc[2]) < zr + wr + 1e-4
            end
            c = candidates[argmin(score.(candidates))]
        end
        _ZONE_CT[] += 1; key = Symbol("zone_inj_$(_ZONE_CT[])")
        z = CB.add_restriction_zone!(key, c, zr)
        # 관찰만. 예전 문장의 뒷절("restage the affected assembly out of the restricted region")은
        # 그 자체가 canonical 정답이라, 주는 순간 재는 것이 추론이 아니라 지시 준수가 된다.
        # 서비스 쪽 정규식(_IMPERATIVE)으로 떼는 길도 있지만 문장 형태에 의존해 취약하므로,
        # 애초에 안 붙인다(LLM_NL_MODE=observation 은 옛 녹화·다른 하니스를 위한 백스톱으로 남긴다).
        nl = "A no-go exclusion zone has appeared at ($(round(c[1]; digits = 2)), $(round(c[2]; digits = 2))) " *
             "overlapping the staging area of an assembly that has not started building."
        try CB.record_ood_truth!(nl, CB.ZoneTruth(key, Float64[c[1], c[2]], Float64(CB.get_radius(z)), aid)) catch end
        return nl
    end
    return nothing
end

# 제안(proposal)에서 표시용 매크로 이름·타깃 뽑기
function _proposal_macro(prop)
    (prop === nothing || isempty(prop.constraints)) && return ("NOOP", "")
    c0   = prop.constraints[1]
    name = string(typeof(c0).name.name)
    tgt  = try hasproperty(c0, :agent) ? _rl(c0.agent) :
               hasproperty(c0, :assembly) ? string(c0.assembly) : "" catch; "" end
    return (name, tgt)
end

# Resolve the truth record that emitted this exact queued event. Using the last
# truth record caused later internal recovery events to be mistaken for a second
# copy of the most recent zone event.
function truth_for_event(event)
    ev = String(event)
    log = CB.ood_truth_log()
    i = findlast(e -> String(e.nl) == ev, log)
    i === nothing || return log[i]
    return nothing
end

"이 이벤트가 컨트롤러 **자기 자신이 낸** 팀 교착 알람인가(외부 교란 OOD 가 아니라)."
is_reform_alarm(ev::AbstractString) = occursin("transport team is deadlocked", ev)

# respec 패널 캡처. source="canonical" 또는 "claude-opus-4-8"(진짜 LLM). rationale 는 LLM 경로에서만 채워짐.
function capture!(env, truth, prop, nl; source = "canonical", rationale = "")
    macro_name, tgt = _proposal_macro(prop)
    kind = truth isa CB.FaultTruth ? "FAULT" : truth isa CB.BatteryTruth ? "BATTERY" :
           truth isa CB.ZoneTruth ? "ZONE" : "OOD"
    (truth isa CB.FaultTruth) && try CB.monitor_record_fault!(truth.robot) catch end
    verdict = "PENDING · awaiting verifier"
    cand = Dict("rank" => 1, "macro" => macro_name, "score" => source,
                "chosen" => true, "verified" => false,
                "decision_source" => source)
    isempty(rationale) || (cand["rationale"] = rationale)
    try
        CB.monitor_record_respec!(; at = length(env.cache.closed_set),
            input = Dict("event" => kind, "target" => tgt, "detail" => first(split(String(nl), "\n"))),
            candidates = [cand], chosen = strip("$(macro_name) $(tgt)"), verdict = verdict)
    catch end
end

# 루트 엔드게임 교착 복구(run_demo.jl handle_ood! 의 ReformTeam 분기와 동일한 사다리).
# 규명된 사실: 이 트윈의 완주 실패는 **전부 루트 조립체에서만** 일어나고(하위는 항상 7/7 done),
# 얼어붙는 것은 TransportUnitGo/DepositCargo 사슬이다. 단계적으로 올린다:
#   ① recover_stalled_teams!  — 낙오 멤버를 운반 슬롯에 스냅해 팀 재정립
#   ② 안 되면 resolve_schedule_wedge! — 직렬화 관문 해소
# 어느 쪽이든 성공하면 planning cache 를 resume 시켜 얼어붙은 프론티어를 다시 연다.
function enact_reform!(env)
    _REFORM_CT[] += 1
    println("[reform] attempt $(_REFORM_CT[])/$(DEMO_REFORM_MAX)")
    # 진단을 **먼저** 찍는다. 프레임워크의 ReformTeam 분기(replan.jl)는 복구를 시도하기 전에
    # diagnose_transport_stall 로 "형성 중 팀이 몇 개인지 / 항법 정체인지 스케줄 대기인지"를 남기는데,
    # policy_producer 가 reform 알람을 가로채 이 함수로 직접 처리하면서 그 진단이 통째로 사라졌다.
    # 그래서 로그에는 정보량 0 인 "recover=no_team · wedge=no_wedge" 만 남고 진짜 원인(하역 목표에
    # 못 닿는 운반체)은 기록조차 되지 않았다. 읽기 전용이라 세계를 바꾸지 않는다.
    try CB.diagnose_transport_stall(env) catch e
        @warn "[reform] diagnose_transport_stall 실패" exception = e
    end
    # NAV_DEBUG=1 이면 **매 reform 마다** 이동체별 목표거리를 찍는다. diagnose_transport_stall 은
    # "형성 중 팀이 하나도 없을 때"만 at-goal/en-route 분해를 내주는데, 실제 정체에서는 팀이 몇 개
    # 잡혀 있어서 그 분기를 안 타고 → 정작 필요한 "누가 얼마나 멀리 있나"가 안 나왔다.
    # 항법 정체(멀리서 못 옴)와 스케줄 대기(도착했는데 is_goal 이 false)를 가르는 유일한 측정이다.
    if get(ENV, "NAV_DEBUG", "0") == "1"
        try CB._dump_nav_stall(env) catch e; @warn "[reform] nav dump 실패" exception = e end
    end
    rec = try CB.recover_stalled_teams!(env; verbose = false) catch e
        @warn "recover_stalled_teams! 실패" exception = e; (status = :error,)
    end
    println("[reform] recover=$(rec.status)")
    ok = rec.status in (:snapped, :force_snapped, :restaged, :carrier_closed, :carrier_advanced)
    ok && CB.reset_cache_resume!(env.cache, env.sched)
    # 2026-08-04 실측 교훈: `recover` 가 :snapped/:force_snapped 를 돌려줘도 **빌드가 재개된다는
    # 보장이 없다**. fault_battery 판에서 9회 연속 "성공" 을 보고하고도 closed 는 121 에 고정,
    # 8개 조립체 전부 frontier=false(5개 blocked) 였다 — 팀이 아니라 **스케줄이 물린 것**이다.
    # 그런데 옛 사다리는 recover 성공 시 wedge 해소를 아예 건너뛰어, 진짜 원인을 영영 안 건드렸다.
    # → 첫 시도가 지났는데도 또 불려 왔다는 것 자체가 "직전 복구가 안 먹혔다"는 증거이므로,
    #    2회차부터는 recover 결과와 무관하게 wedge 해소까지 같이 올린다.
    attempt = _REFORM_CT[]
    unwedged = false
    if !ok || attempt >= 2
        local wedge = try CB.resolve_schedule_wedge!(env; verbose = false) catch e
            @warn "resolve_schedule_wedge! 실패" exception = e; (status = :no_wedge,)
        end
        println("[reform] wedge=$(wedge.status)")
        unwedged = wedge.status == :unwedged
        unwedged && CB.reset_cache_resume!(env.cache, env.sched)
        wedge_status = string(wedge.status)
        # 두 단이 모두 "해당 없음"으로 떨어진 fall-through = 진짜 원인이 팀도 스케줄도 아닌 경우.
        # 여기서 이동체별 목표거리 덤프를 남긴다(프레임워크 경로의 NAV_DEBUG 와 같은 증거).
        if !ok && !unwedged
            try CB._dump_nav_stall(env) catch e; @warn "[reform] nav dump 실패" exception = e end
        end
    else
        wedge_status = "skipped"
    end
    # ---- ③ 공간 수복 (2026-08-05) ----------------------------------------------------------
    # 위 두 단은 **팀**과 **스케줄**을 고친다. 세 번째 정체 원인이 있다: 살아 있는 no-go 구역이
    # 아직 안 닫힌 항법 목표를 실제로 막고 있는 경우다. 그때는 팀도 스케줄도 멀쩡하고
    # (recover=:no_team, wedge=:no_wedge) 막힌 것이 **공간**이라 두 단이 구조적으로 아무것도 못 한다.
    #
    # 왜 결정 레이어가 아니라 여기인가: 결정(개입할까 절제할까)은 정책의 몫이고, 정책이 절제를
    # 골랐다면 그 판단은 기록에 그대로 남아야 한다. 하지만 그 결과가 **영구 정체**여서는 안 된다 —
    # 완주는 데모의 전제 조건이다. 그래서 이건 판정이 아니라 carrier-rescue 와 같은 급의 **복구 사다리**
    # 마지막 칸이고, recovery 타임라인에 따로 남아 "정책이 뭘 골랐나"와 섞이지 않는다.
    # ZONE_RESCUE=0 으로 끄면 옛 동작(구역 정체를 그대로 둠).
    #
    # 조건에 `attempt >= 2` 를 함께 두는 이유: `recover_stalled_teams!` 은 :force_snapped 를
    # 돌려줄 때 **항상** ok=true 라(위 예산 주석의 실측) `!ok` 만 보면 이 단이 영영 도달 불가가 된다.
    # _REFORM_CT 는 실제로 노드가 닫히면 0 으로 되돌아가므로, attempt>=2 는 "복구 알람이 두 번
    # 울리는 동안 한 노드도 안 닫혔다" = 진짜 정체를 뜻한다.
    zone_status = "skipped"
    if ((!ok && !unwedged) || attempt >= 2) && get(ENV, "ZONE_RESCUE", "1") != "0"
        local blk = try CB.zone_blockage(env; check_paths = false) catch e
            @warn "[reform] zone_blockage 실패" exception = e; nothing
        end
        # 🔴 존 복구 base ablation (2026-09-23, 컨트롤러 판정 — 명세 §6 층 4 를 이 두 번째 자동 사다리에도).
        #    이 단은 LLM 없이 사람이 쓴 translate 를 부른다. ablation 팔에서는 부르지 않고 센다 —
        #    `denied` 는 LLM 이 낸 호출에만 남긴다. none 에서는 그대로 돌되 발동을 센다.
        if blk !== nothing && blk.n_blocked > 0 && CB.ablation_blocks_zone_ladder()
            CB._ablation_bump!("ladder_zone_skipped")
            CB._ablation_bump!("zone_rescue_skipped")
            zone_status = "blocked $(blk.n_blocked)/$(blk.n_nav_goals) → skipped (repair_ablation=$(CB.REPAIR_ABLATION[]))"
            println("[reform] zone-rescue: $(zone_status)")
        elseif blk !== nothing && blk.n_blocked > 0
            CB._ablation_bump!("ladder_zone_fired")
            CB._ablation_bump!("zone_rescue_fired")
            local wb = try CB.translate_whole_build!(env; resume = true, verbose = false) catch e
                @warn "translate_whole_build! 실패" exception = e; (status = :error,)
            end
            zone_status = "blocked $(blk.n_blocked)/$(blk.n_nav_goals) → $(wb.status)"
            println("[reform] zone-rescue: $(zone_status)")
            if wb.status in (:translated, :residual_blocked)
                CB.reset_cache_resume!(env.cache, env.sched)
                unwedged = true          # 이 사다리에서 "무언가를 실제로 했다"로 센다
            end
        else
            # 아무것도 안 했을 때도 **무엇을 보고 안 했는지** 남긴다. 첫 라이브 런에서 이 줄이 없어
            # "구역이 정체의 원인인가"를 로그만으로는 가릴 수 없었다.
            zone_status = blk === nothing ? "unavailable" :
                          "no live zone blocks a navigable goal (0/$(blk.n_nav_goals))"
            println("[reform] zone-rescue: $(zone_status)")
        end
    end
    acted = ok || unwedged
    CB.update_planning_cache!(env, 0.0)
    # OOD 결정이 아니라 **복구 타임라인**에 남긴다(대시보드가 OOD 피드와 분리해 보여준다).
    try CB.monitor_record_recovery!(; at = length(env.cache.closed_set),
        action = "ReformTeam",
        detail = "attempt $(attempt)/$(DEMO_REFORM_MAX) · " *
                 "stalled-team recovery=$(rec.status) · schedule-wedge=$(wedge_status) · " *
                 "zone-rescue=$(zone_status)",
        status = acted ? "recovered" : "no-op") catch end
    # 시도 예산을 되돌리는 기준 = **직전 reform 이후 실제로 작업이 닫혔는가**.
    #
    # 왜 rec.status 가 기준이 아닌가(2026-08-05 실측): 판정을 "뭔가 했다(acted)"로 두면
    # force_snapped 가 항상 참이라 예산이 영영 안 줄고 reform 이 400 스텝마다 무한 반복된다
    # (측정: 한 런에서 12회, closed 는 263 에서 제자리). DEMO_REFORM_MAX 가 원래 막으려던 것이
    # 바로 그 "함대만 휘젓는 반복"이다. 반대로 예전처럼 모든 시도를 깎으면 진짜로 복구가 되고 있는
    # 중에도 3회에서 끊긴다. 두 실패 사이의 올바른 기준은 상태 이름이 아니라 **진전**이다.
    nc = length(env.cache.closed_set)
    if nc > _REFORM_LAST_CLOSED[]
        _REFORM_LAST_CLOSED[] = nc
        _REFORM_CT[] = 0                 # 빌드가 실제로 전진했다 → 예산 복구
    end
    return nothing
end

# 완주 보장 enactment(검증된 manual-loop 경로). truth(고장/배터리/존)와 — 있으면 — LLM 이 고른 macro 를 반영.
#   prop 이 주어지면 그 매크로대로(ReplaceAgent→hot_swap, ForbidZone→restage),
#   없거나 NOOP 면 truth 종류로 기본 복구. 어느 경로든 빌드가 멈추지 않게 함.
function enact_recovery!(env, truth, prop)
    macro_name, _ = _proposal_macro(prop)
    try
        if prop !== nothing && CB._is_robot_replace(prop)          # LLM: 로봇 고장 → 스페어 교체
            rid = first(c for c in prop.constraints if c isa CB.ReplaceAgent).agent
            CB.hot_swap_robot!(env, rid; mode = :via_depot, verbose = false)
            local f = CB.BATTERY_FLEET[]; (f !== nothing && haskey(f.soc, rid)) && (f.soc[rid] = 1.0)
        elseif prop !== nothing && CB._is_zone_respec(prop)        # LLM: 공간 no-go → 리스테이지
            truth isa CB.ZoneTruth && truth.assembly !== nothing &&
                CB.restage_assembly!(env, truth.assembly; resume = true, verbose = false)
        # 🔴 2026-08-24 (spec §5.4, Task 5): 여기 있던 `CB._is_deprioritize(prop)` 분기(SoC 회복 +
        # rebalance)를 지웠다 — 그 판정자와 `DeprioritizeAgent` kind 가 함께 삭제됐다. 배터리
        # 사건은 아래 `else` 의 truth 기반 기본 복구(임계값 아래=hot_swap / 위=rebalance)로 간다.
        else                                                       # NOOP/미상 or producer=canonical → truth 기반 기본 복구
            if truth isa CB.FaultTruth
                CB.hot_swap_robot!(env, truth.robot; mode = :via_depot, verbose = false)
            elseif truth isa CB.BatteryTruth
                if truth.soc_after <= CB.REPLACE_SOC_THRESHOLD[]
                    CB.hot_swap_robot!(env, truth.robot; mode = :via_depot, verbose = false)
                    local f = CB.BATTERY_FLEET[]; (f !== nothing && haskey(f.soc, truth.robot)) && (f.soc[truth.robot] = 1.0)
                else
                    # 🔴 2026-08-30 (T0, 음성 대조로 수정): 애초 이 주석은 `enact_recovery!` 가
                    # battery_mild 에서 LLM 의 NOOP 을 조용히 무시한다고 주장했다. 독립 검증으로
                    # 반증됐다 — `enact_recovery!`(이 파일, 같은 함수)의 호출부는 **0개**다. 이
                    # 시뮬레이션 루프가 실제로 쓰는 producer 는 `policy_producer`(이 파일)이고,
                    # `set_respec_producer!` 로 꽂힌다 — 이 `else` 분기와는 다른 경로다. 그래서
                    # 이 println 은 "폴백이 실제로 이 판을 침묵으로 덮었다"의 계측이 아니라
                    # **음성 대조**다: 찍히면 안 되는 게 정상이고, 찍히면 죽은 줄 알았던 경로가
                    # 실은 살아 있다는 뜻이라 그 자체가 중대 발견이다.
                    local _rb = CB.rebalance_for_battery!(env)
                    println("[recover] SILENT-FALLBACK battery rebalance=$(_rb) " *
                            "(macro_name=$(macro_name) — 이 분기는 결정을 안 본다)")
                end
            elseif truth isa CB.ZoneTruth && truth.assembly !== nothing
                CB.restage_assembly!(env, truth.assembly; resume = true, verbose = false)
            end
        end
    catch e
        println("[recover] ", typeof(truth).name.name, "/", macro_name, " FAILED: ",
                first(split(sprint(showerror, e), "\n")))
    end
    return nothing
end

# ---------------------------------------------------------------------------------------------
# 확률적 시점의 불발을 막는 재무장 래퍼.
#
# 왜 필요한가(실측): 고정 슬롯 시절에는 발화 지점이 늘 "적격 대상이 있는" 순간으로 손수 골라져 있었다.
# 시점을 추첨하기 시작하자 첫 실행부터 불발했다 — closed=77 에서 pick_solo_fault_target 이 단독 운반체를
# 하나도 못 찾아 fault_action 이 nothing 을 돌려줬고, 사건은 기록도 없이 사라졌다(스트림의 ood=[]).
# 무작위 시점이 "사건이 일어나지 않는" 이유가 되면 안 된다. 실패하면 조금 더 진행된 시점에 다시 시도한다.
#
# 액션이 nothing 을 돌려준다는 것은 **아무 상태도 바꾸지 못했다**는 뜻이므로(fault_robot! 은 대상이
# 없으면 즉시 return nothing) 재시도해도 이중 주입이 되지 않는다.
function retrying_action(inner; at::Int, every::Int, max_tries::Int = 200, tag::String = "ood")
    tries = Ref(0); nxt = Ref(at)
    function act(env)
        closed = length(env.cache.closed_set)
        nl = inner(env)
        if nl !== nothing
            println("[ood] $tag fired at step≈$(nxt[]) closed=$(closed)" *
                    (tries[] > 0 ? " (after $(tries[]) deferrals)" : ""))
        elseif tries[] < max_tries
            tries[] += 1
            nxt[] += every
            # 조용히 사라지지 않게 다음 스텝에 다시 무장한다. 액션이 nothing 을 돌려줬다는 것은
            # 아무 상태도 바꾸지 못했다는 뜻이므로(대상 없음) 재시도해도 이중 주입이 아니다.
            tries[] % 20 == 1 &&
                println("[ood] $tag no eligible target at step≈$(nxt[] - every) closed=$(closed) → deferring")
            CB.schedule_ood!(nxt[], act)
        else
            println("[ood] $tag GAVE UP at step≈$(nxt[]) closed=$(closed) after $(max_tries) deferrals " *
                    "— no feasible instant existed for the rest of the build")
        end
        return nl
    end
    return act
end

include(joinpath(@__DIR__, "policy.jl"))   # 결정 정책 레이어(canonical/surrogate/dspy 공용)

# ---- 세대 게이트 (2026-09-03) ---------------------------------------------------------------
# 🔴 왜 여기인가. 08-30/08-31 기동 uvicorn **다섯**이 사흘째 `/health` 200 을 냈고 그중 어느
#    것도 `synthesize_multi`(09-02 도입)를 안 갖고 있었다 — 그 위에서 잰 결과가 "모델이 이렇게
#    답했다" 로 읽혔다. 셸 레시피 넷은 이제 `tools/require_current_service.sh` 로 막지만,
#    S1 이 실제로 쓴 경로는 **`julia … render_demo.jl` 직접 호출**이라 그 넷을 안 지난다.
# 🔴 판정식을 Julia 에 다시 적지 않는다 — 정본은 `generation.py` 의 `check_health` 하나이고
#    여기서는 그것을 **부른다**. 두 벌이면 갈린다(이 레포가 반복해 밟은 실패 모양).
# 🔴 탈출구를 두지 않았다. 게이트를 끄는 환경변수를 만들면 그것을 켜는 법부터 배우게 되고,
#    그 순간 이 게이트는 오늘 지운 `curl … >/dev/null` 과 같은 것이 된다. 틀리면 **닫히는
#    쪽으로** 틀린다(런이 안 뜬다) — 조용히 낡은 세대를 재는 것보다 압도적으로 싸다.
# 🔴 `policy.jl` 은 안 건드린다: 그 파일의 `dspy_ready()` 는 시험 여섯이 가짜 `/health` 를
#    띄워 부르는 자리이고(`test/service_decide_ships_*.jl` 외 3), 거기에 도장을 요구하면
#    그 여섯이 세대와 무관하게 빨개진다. 게이트는 **런 진입점**에 산다.
let _need = (POLICY in ("dspy", "surrogate")) || ROUTER_MODE != "0"
    if _need
        _gate = joinpath(pkgdir(CB), "tools", "require_current_service.sh")
        _cmd  = "source '" * _gate * "' && require_current_service '" * DSPY_URL * "'"
        if !success(pipeline(`bash -c $_cmd`; stdout = stdout, stderr = stderr))
            error("[generation] 이 런은 DSPy 서비스를 쓴다(DEMO_POLICY=$(POLICY), " *
                  "DEMO_ROUTER=$(ROUTER_MODE))는데 그 서비스가 이 트리를 서빙하고 있지 않다. " *
                  "위 [generation] 줄이 사유다. 실행줄: src/respec/llm_service/README.md")
        end
    end
end
# 🔴 2026-08-29 (Plan B / T2b): 집행 대상 선택 seam. `run_demo.jl` 과 **같은 함수**를 부른다.
# 두 엔진이 각자 규칙을 들고 있으면 갈릴 수 있고, 이 레포는 그 사고를 이미 여러 번 밟았다
# (`has_zone` 술어, `record_decision!` 쌍둥이). `enact.jl` 은 최상위 부작용이 없다.
include(joinpath(@__DIR__, "enact.jl"))
# ---- 원장 신원 (2026-09-22, retry-body 보존 Phase 1 / Task 4) ---------------------------------
# 🔴 서비스는 seed·레인·판을 모른다(요청에 없었다). 여기서 한 번 채우면 `/decide` 가 매 요청에
#    싣는다(`policy.jl::_stamp_identity!`). 기동 때 **한 번** 계산한다 — 도중에 코드·설정이
#    바뀌어도 이 판의 신원은 기동 시점의 것이다.
# 🔴 `run_id` 는 **유일 키가 아니다**: 비면 스트림 이름이고, `router__zone__s3` 같은 값은 모델·
#    campaign 사이에 겹친다. 조인은 이 dict 전체(campaign·모델·두 시드·코드/설정 지문)로 한다.
#  · `lane`  — 규칙을 다시 적지 않는다. `router_drives()` 가 라우터 손잡이의 유일한 술어다.
#  · `case`/`event` — `case` 는 표시 이름(`DEMO_CASE_TAG`), `event` 는 실제로 돈 사건
#    (`DEMO_OOD`). 둘이 갈리는 판이 있다(위 `CASE_TAG` 주석). zone 은 `DEMO_OOD` 가 아니라
#    `zone_requested()` 게이트로 심으므로 `zone` 으로 따로 싣는다.
#  · `policy`/`router` 는 **env 원문**이다(빈 문자열 = 기본값으로 돌았다).
# 존 복구 base ablation(2026-09-23, 명세 §6). 레벨이 틀리면 여기서 죽는다.
# 🔴 `set_run_ctx!` **앞**이어야 한다: 계획은 `pre` 훅(CARRIER_RESCUE 기본값 줄 아래)에 두라 했지만
#    그 훅은 시뮬 직전에 돌아 run_ctx 와 아래 서비스 단언이 언제나 기본값 `none` 을 읽게 된다.
CB.set_repair_ablation!(CB.repair_ablation_from_env())
set_run_ctx!(; run_id = isempty(RUN_ID) ? basename(stream_path) : RUN_ID,
             campaign_id = get(ENV, "DEMO_CAMPAIGN_ID", ""),
             stream = basename(stream_path), case = CASE_TAG, event = OODC,
             zone = zone_requested(), model = model_base,
             lane = router_drives() ? "router" : POLICY,
             policy = get(ENV, "DEMO_POLICY", ""), router = get(ENV, "DEMO_ROUTER", ""),
             seed = DEMO_SEED, zone_seed = DEMO_ZONE_SEED,
             synth_fixture = get(ENV, "DEMO_SYNTH_FIXTURE", ""),
             repair_ablation = String(CB.REPAIR_ABLATION[]),
             run_fingerprint()...)
println("[run-ctx] ", JSON3.write(RUN_CTX[]))
router_drives() && assert_service_repair_ablation()   # 🔴 레벨 불일치면 첫 결정 전에 죽는다(Review Focus 1)
# ⚠️ `run_demo.jl:248` 과 달리 여기서는 `_reset_decision_counter!()` 를 부르지 않는다. 그래도
# 안전한 이유는 **하나뿐이다**: 이 스크립트의 유일한 호출자인 `server.jl:117` 이 실행마다
# `julia … render_demo.jl` **새 프로세스**를 띄우므로 `policy.jl:711` 의 `_DECISION_N[]` 이
# 언제나 0 에서 시작한다. 이 파일을 같은 프로세스 안에서 두 번 굴리는 호출자가 생기면
# `DS_DEVIATE_AT=k` 가 두 번째 판에서 어긋난다 — 그때는 여기에 리셋을 넣을 것.
# (2026-08-17 최종 리뷰: 동작 변경 없음, 근거 기록만.)

# producer(정책): 매 OOD 마다 **세 정책을 모두 계산·기록**하고, DEMO_POLICY 가 고른 매크로를
# DSL 제안으로 바꿔 프레임워크 dispatcher 에 넘긴다(검증된 restage/translate 경로를 그대로 씀).
# run_demo.jl 의 수동 루프와 동일한 decide_all 을 쓰므로 두 엔진의 결정이 어긋날 수 없다.
function policy_producer(env, event)
    # 팀 교착 알람은 **OOD 가 아니라 내부 복구 조치**다. 결정 레이어를 태우지 않는다.
    #   · 외부 교란이 아니라 우리 복구(hot-swap 등)가 만든 2차 부작용이다.
    #   · novelty 교정에 이 종류가 없어 항상 p=0.012 "처음 보는 사건"으로 뜬다(발견이 아니라 아티팩트).
    #   · 액션이 [NOOP, ReformTeam] 뿐이라 세 정책이 늘 일치 — 결정 패널에 정보량 0 인 항목만 쌓인다.
    #   · NL 이 고정 템플릿이고 ReformTruth 에 팀 식별자가 없어 LLM 이 읽을 것도 없다.
    # → 여기서 직접 복구하고 recovery 타임라인에만 기록한다(LLM 호출 0).
    if is_reform_alarm(String(event))
        if _REFORM_CT[] < DEMO_REFORM_MAX
            enact_reform!(env)
        elseif !_REFORM_EXHAUSTED_SAID[]
            # 관측 전용(2026-09-23, 복구 계획서 Task 7): 예산 소진 뒤의 알람은 여기서 **조용히**
            # 버려졌다 — `[reform] attempt N/N` 은 마지막 시도에 도달했다는 뜻일 뿐이라(그 시도가
            # 성공할 수 있다) 실제 소진을 로그로 가를 수 없었다. 판마다 한 번만 찍는다
            # (소진 뒤에는 `enact_reform!` 이 안 불려 예산이 다시 안 차므로 소진은 영구다).
            _REFORM_EXHAUSTED_SAID[] = true
            println("[reform] budget exhausted $(_REFORM_CT[])/$(DEMO_REFORM_MAX) at closed=" *
                    "$(length(env.cache.closed_set)) — further alarms ignored")
        end
        return nothing
    end
    rec = truth_for_event(event)
    rec === nothing && return nothing
    truth = rec.truth
    # T8: 검증 모드(`ZONE_REPAIR_VERIFICATION != off`)의 worker 에서만 — 존 사건 dispatch 를 크게 적는다. 부모가 t0 capture 없이
    #     존 사건을 받으면(지연/라이브 존) `certification_unavailable` 기록. 세계는 안 건드린다(결정은 아래 pi0 그대로).
    truth isa CB.ZoneTruth && isdefined(Main, :RepairBranchWorker) &&
        Base.invokelatest(getfield(Main, :RepairBranchWorker).zone_dispatch_note, String(event))
    decision = decide_all(env, truth; nl = rec.nl)   # nl = LLM 이 읽을 자연어 관찰
    # ---- 결정 시점의 **에너지 상태와 그 가격**을 레코드에 싣는다 (2026-08-14) ----------------
    # 요구: "UI 에서 목적함수에 energy 가 고려된 제어를 본다". 화면의 OBJECTIVE 스트립이
    # J = makespan/M_ref + κ·energy_J/E_ref + … 를 objective.json 에서 읽어 보여주는데, 거기
    # **실제로 들어가는 두 수**(지금까지 쓴 에너지, 그것을 매기는 κ)가 결정마다 없으면 그 식은
    # 화면에서 여전히 주장으로만 남는다. 둘 다 이미 계산돼 있으므로 새로 재지 않고 읽어 싣는다.
    #
    # 이 파일에만 넣는 이유: 대시보드의 라이브 런(server.jl POST /run)과 녹화(regen_router_cases.sh)
    # 가 **둘 다 render_demo.jl** 을 쓴다. policy.jl 을 건드리면 지금 도는 비교 스윕의 코드
    # 세대가 갈리므로 건드리지 않는다 — 이 값은 비교 숫자가 아니라 화면 표시용이다.
    try
        local br = CB.battery_report()
        decision.router["energy_so_far_J"] = br.total_energy_J
        decision.router["energy_min_soc"]  = br.min_soc
        # κ 는 목적함수가 에너지에 매기는 가격. nothing 이면 이 레인에 전역 κ 가 안 걸린 것이고,
        # 그 사실도 그대로 남긴다(0 으로 채우지 않는다 — 안 걸린 것과 0 은 다르다).
        decision.router["energy_kappa"] = CB.AUTO_EFFICIENCY_KAPPA[]
    catch e
        @warn "[energy] battery_report failed -> 화면에 에너지 상태를 싣지 않는다" exception = e
    end
    record_decision!(env, truth, decision, rec.nl)
    rt = decision.router
    haskey(rt, "lane_reason") && println("[router] $(rt["lane_reason"]) " *
        "(kind=$(get(rt, "routing_kind", "?")), axis=$(get(rt, "router_axis", "?")))")
    # 🔴 2026-08-29 (T12): 여기 있던 `surro=… , dspy=…` **비교 줄을 지웠다.** 라우터가 사건당
    #    레인 하나만 부르므로 안 부른 레인의 `chosen` 이 존재하지 않는다 — 그대로 두면
    #    `KeyError` 로 죽는다(§0-C 결정 4). 집행된 레인은 `enacted` 가 말한다.
    println("[policy] $(typeof(truth).name.name) → $(decision.macro_name) " *
            "(enacted=$(decision.enacted); rule=$(decision.rule_macro))")
    # ---- 집행 대상 agent (2026-08-29, Plan B / T2b) ------------------------------------
    # 🔴 여기까지 이 엔진에서 LLM 의 tool 호출은 세계에 대해 인과가 없었다. `macro_to_proposal`
    # 이 `truth.robot`(주입기가 이미 아는 값)으로 `ReplaceAgent`/`SwapBattery` 를 만들고,
    # `enact_recovery!` 는 그 제약의 `.agent` 를 성실히 집행했다 — 끊긴 자리는 한 곳이었다.
    #
    # 🔴 **`run_demo.jl` 과 같은 함수를 부른다**(`enact.jl` 의 `enact_target`). 규칙을 복사하지
    # 않는 이유: 두 엔진이 각자 규칙을 들고 있으면 R16(강제/이탈 판에서 tool 인자 거절)과
    # R2/R6(폴백 기록)이 한쪽에서만 조용히 썩는다. 같은 함수를 부르면 갈릴 수 없다.
    #
    # ⚠️ 이 엔진에는 `run_demo.jl` 의 `this_decision` 같은 **결정 행 화이트리스트가 없다**
    # (2026-08-29 실측: `_DECISIONS` 가 이 파일에 0건이고, 기록은 `record_decision!` →
    # 모니터 respec 스트림 하나뿐이다). 그래서 세 키를 실을 자리가 이 파일에는 존재하지
    # 않는다 — 있는 척 만들지 않는다. `enact_agent_source` 는 아래 한 줄로 stdout 에만 남는다.
    local _tgt = enact_target(env, truth, decision.tool_lane,
                              (try decision.router catch; nothing end),
                              decision.macro_name)
    # 🔴 문구는 `enact.jl` 의 `log_enact` **한 벌**이다. (2026-08-29: 같은 함수를 부르던
    #    두 번째 producer `llm_producer` 는 Anthropic 레인과 함께 삭제됐다 — 아래 노트.)
    # 두 producer 가 각자 println 을 들면 한쪽이 `reject` 를 빠뜨리는 순간 폴백이 조용해진다.
    log_enact(_tgt)
    # ---- 합성 tool 집행 (2026-08-30, T4) --------------------------------------------------
    # 🔴 `macro_to_proposal` **앞**이다. 합성 tool 이 처리한 사건은 닫힌 어휘의 매크로로
    #    번역될 수 없다 — 그 어휘에 이 행동이 없다는 것이 애초에 합성이 발화한 이유다.
    #    처리했으면 `nothing` 을 돌려 프레임워크 dispatch 를 건너뛴다(enact_reform! 과 같은 패턴).
    #
    # 🔴 채점기를 오염시키지 않는다: 합성 tool 은 `RespecProposal` 을 만들지 않으므로
    #    `emitted_key` 로 가지 않는다(spec §7-2). `decision.macro_name` 은 그대로 NOOP 이고
    #    그것이 옳다 — 채점 어휘에서 이 사건의 정답은 실제로 없다.
    #
    # 🔴 `handled` 의 **정본은 `tools/monitor/enact.jl` 의 `minted_handled`**(네 연언지)다 — 여기에
    #    다시 베끼지 않는다(손베낀 복사본이 프로덕션과 갈린 것을 2026-09-02 검증이 실측했다).
    #    verdict 항은 `CB.minted_handled_verdict_ok` 이고 `:admit` 하나가 아니다.
    #    `applied` 로 판정하면 "1단계가 세계를 바꾸고 2단계가 던진" 판에서
    #    **반쯤 편집된 세계 위에** 기본 복구 사슬을 얹게 된다.
    local _m = enact_minted_decision!(env, truth, decision)
    # 🔴 F1(2026-09-03 리뷰): `world_delta` 를 **구조화된 행**에도 싣는다. `record_decision!`
    #    (위)이 결정 행을 집행 **앞**에서 닫으므로, 집행이 낸 유일한 "세계가 실제로 바뀌었나"
    #    관측이 여기서 버려지면 stdout 파싱 말고는 채점 수단이 없다(사전등록 결정 6 은
    #    `world_delta` 하나를 L4 판정으로 쓴다). 🔴 `_m.handled` 판정 **앞**이다 — 뒤에 두면
    #    생성 body 의 지배적인 판(handled=true)에서 행이 통째로 비어 버린다.
    #    🔴 함수의 정본은 `enact.jl::record_world_delta!` 하나다(직렬화 모양·삼상·안 던짐의
    #    근거를 그 docstring 이 소유한다). 여기 다시 적지 않는다.
    record_world_delta!(_m)
    _m.handled && return nothing
    # ReformTeam 은 프레임워크 dispatcher 의 기본 reform 만으로는 **루트 엔드게임 교착**을 못 푼다.
    # run_demo.jl 이 완주를 얻어낸 단계적 사다리(팀 재정립 → 안 되면 직렬화 관문 해소)를 그대로 쓴다.
    # 직접 집행하므로 dispatch 는 생략(nothing) — canonical_producer 와 같은 패턴.
    return macro_to_proposal(truth, decision.macro_name; env = env, agent = _tgt.agent)
end

# producer(canonical): 최근 OOD truth → canonical 휴리스틱 분석 캡처 + 직접 복구 → nothing(dispatch 생략).
function canonical_producer(env, event)
    rec = truth_for_event(event)
    rec === nothing && return nothing
    truth = rec.truth
    prop  = try CB.canonical_respec(truth) catch; nothing end
    capture!(env, truth, prop, rec.nl; source = "canonical")
    # Return the proposal to the shared production dispatcher. It performs the
    # verified multi-assembly restage and whole-build translation fallback.
    return prop
end

# 🔴 2026-08-29: producer(LLM) — `llm_producer` 와 `USE_LLM`(`DEMO_LLM`) 스위치를 **삭제**했다.
#   그 레인은 `CB.llm_to_proposal` 로 진짜 Claude API(파이썬 `/propose` 서비스, :8000)를 불렀고,
#   그 서비스가 Anthropic 레인과 함께 사라졌다(측정된 죽은 코드: :8000 에 아무도 없음,
#   ANTHROPIC_API_KEY 없음, 실행 스크립트 없음). 이제 이 엔진의 producer 는 `policy_producer`
#   하나뿐이라 `set_respec_producer!` 가 조건 없이 그것을 꽂는다 — `DEMO_LLM` 은 죽은 손잡이가
#   아니라 **없는 손잡이**다(설정해도 아무 일도 안 일어난다).
#
#   ⚠️ 같이 사라진 것: T2c 가 세운 접지 게이트를 이 레인에서 통과시키던 배선
#   (`llm_enact_target` 호출)과 그것을 지키던 `test/llm_producer_grounds_agent.jl`.
#   `enact.jl` 의 `llm_enact_target` 자체는 남아 있으나 **호출자가 0개**다.
#   `policy_producer` 는 T2b 에서 이미 `enact_target` 뒤로 들어가 있으므로, 이 엔진에서
#   집행 대상이 접지를 거친다는 성질은 그대로다.

pre = function (env)
    # 배터리 물리는 run_demo.jl(:482 부근)과 **같아야 한다** — 두 엔진이 다른 물리를 쓰면
    # 대시보드에 보이는 판과 논문 표의 근거(results_4pol)가 다른 세계가 된다.
    # 용량 축소(shrink)는 하지 않는다: 스펙 2.3 kWh 가 최대부하에서 2.30시간이라 실제
    # 작업로봇의 지속시간과 맞고, shrink=25 는 5.5분짜리 배터리라 물리적으로 말이 안 됐다.
    CB.enable_battery!(env; params = CB.BatteryParams())
    try CB.set_battery_penalty!(gain = 6.0, soc_target = 0.5, hard_mult = 1.0e3) catch end
    # 방전 → 정지 / 감속. 이게 없으면 배터리가 방전돼도 로봇이 멈추지 않아서, 대시보드가
    # "로봇이 그 자리에 멈췄다"는 NL 을 띄우면서 화면에서는 멀쩡히 계속 움직인다.
    CB.set_battery_stall!(enabled = get(ENV, "DEMO_STALL", "1") == "1",
                          threshold = (try parse(Float64, get(ENV, "DEMO_STALL_SOC", "0.05")) catch; 0.05 end),
                          clear = true, obstacle = false)
    CB.set_battery_derate!(enabled = get(ENV, "DEMO_DERATE", "1") == "1",
                           hi = 0.5, min_factor = 0.35)
    # ---- SwapBattery 를 물리적 배송으로 (respec/battery_courier.jl) -------------------------
    # 예전 `swap_battery!` 는 같은 스텝에 SoC 만 1.0 으로 찍고 끝나서, 화면에서는 아무 일도
    # 일어나지 않았고(방전 프레임이 0개라 BATTERY_TINT_HOLD_FRAMES 로 빨강을 연출해야 했다)
    # 어휘상 가장 싼 팔이 **시간도 자원도 안 드는 공짜 팔**이 되어 있었다. 이제 가장 가까운
    # 창고의 예비 로봇이 배터리를 들고 나와(초록) 현장에 도착한 순간에 교체가 적용되고, 그때까지
    # 방전 로봇은 실제로 방전 상태(빨강)이며 조립 라인은 선다.
    CB.set_battery_courier!(
        enabled    = get(ENV, "DEMO_BATTERY_COURIER", "1") == "1",
        speed      = (try parse(Float64, get(ENV, "DEMO_COURIER_SPEED", "0")) catch; 0.0 end),
        halt_build = get(ENV, "DEMO_SWAP_HALT", "1") == "1")
    # 배송이 켜지면 방전 구간이 **실재**하므로 연출용 hold 는 필요 없다(그 상수는 방전 프레임이
    # 하나도 없던 시절의 보정이다). 명시적으로 준 값은 그대로 존중한다.
    CB.battery_courier_enabled() && !haskey(ENV, "BATTERY_TINT_HOLD_FRAMES") &&
        (ENV["BATTERY_TINT_HOLD_FRAMES"] = "0")
    println(">>> battery: capacity=", CB.BatteryParams().capacity_J, " J (spec, no shrink)",
            "  stall=", CB.BATTERY_STALL[].enabled, "@", CB.BATTERY_STALL[].threshold,
            "  derate=", CB.BATTERY_DERATE[].enabled,
            "  courier=", CB.battery_courier_enabled(),
            " halt=", CB.BATTERY_COURIER_CFG[].halt_build)
    CB.RESPEC_ENABLED[] = true
    CB.set_hot_swap!(enabled = true, mode = :via_depot)
    # ---------------------------------------------------------------------------------------
    # CARRIER_RESCUE — 2026-08-05 규명. 이 데모만 이 손잡이가 꺼진 채 돌고 있었다.
    #
    # 측정된 endgame 정체의 실체는 "팀 교착"이 아니라 **이미 형성된 운반체(TransportUnit)가
    # 하역 목표에 영영 못 닿는 것**이다(스트림 증거: 정체 구간 내내 TransportUnitGo 2~3 개가
    # CARRY 상태로 얼어 있고 형성 중인 팀은 0). 그 상태에서
    #   · recover_stalled_teams! 는 형성 중 팀이 없으니 :no_team
    #   · resolve_schedule_wedge! 는 WEDGE_EDGES 가 (Replace 가 없었으므로) 비어 있어 무조건 :no_wedge
    # 라서 reform 사다리가 **구조적으로** 아무것도 못 한다. 그 상황을 위해 만들어진 유일한 단
    # (force_advance_stuck_carrier!)이 CARRIER_RESCUE 환경변수로 잠겨 있었고, 오라클/덱 스크립트는
    # 전부 CARRIER_RESCUE=1 을 켜는데(run_graded.sh, run_parallel*.ps1, verify_fault_completion.sh,
    # render_deck_videos.sh …) 모니터 데모 경로만 빠져 있었다 = 데모만 완주를 못 하던 이유.
    # 여기서 기본값을 켠다(명시적으로 CARRIER_RESCUE=0 을 주면 옛 동작 재현). 데이터셋 생성 경로는
    # 자기 스크립트에서 이미 값을 정하므로 이 줄에 영향받지 않는다.
    haskey(ENV, "CARRIER_RESCUE") || (ENV["CARRIER_RESCUE"] = "1")
    # ---------------------------------------------------------------------------------------
    # RelocateBuild 비례성 게이트 — 이 데모 경로에서만 기본 ON (verifier.jl RELOCATE_GATE 주석).
    # 근거(2026-08-05, 같은 seed·같은 존·매크로만 교차): 전역 이동 closed 136(조립체 1/8) vs
    # 국소/무개입 231(7/8). 정책만 다르고 매크로가 같은 두 런은 Δ 15자리까지 동일 = 손해는
    # 매크로의 것이다. 오라클/데이터셋 경로는 이 팔을 **측정 대상**으로 쓰므로 기본값은 꺼져 있고,
    # 여기서만 켠다. 명시적으로 RELOCATE_GATE=0 을 주면 옛 동작(무조건 허용) 재현.
    try CB.set_relocate_gate!(get(ENV, "RELOCATE_GATE", "1") == "1") catch end
    # 런 사이에 새는 전역 카운터 초기화. 두 함수는 정의만 되어 있고 **아무도 부르지 않았다** —
    # 한 프로세스에서 여러 케이스를 도는 하니스(regen_all_cases.sh)에서 직전 런의 force-snap 횟수와
    # carrier 거리 기록이 그대로 이월돼 복구 사다리의 격상 시점이 런마다 달라졌다.
    try CB.reset_snap_count!() catch end
    try CB.clear_carrier_progress!() catch end
    DEMO_REFORM > 0 && try CB.set_reform_interval!(DEMO_REFORM) catch end
    CB.set_respec_producer!(policy_producer)   # 2026-08-29: producer 는 하나뿐이다(위 삭제 노트)
    CB.clear_ood_schedule!()
    empty!(CB.RESPEC_QUEUE.pending)
    # 스트림을 **여는 순간** 옛 녹화가 0바이트로 잘린다(monitor.jl 이 "w" 로 연다). 그래서 존 런은
    # 조작자가 구역을 확정한 뒤에야 연다 — 확정 전에 취소하면 기존 녹화본이 그대로 살아남아야 한다.
    # 스트림을 열면서 사이드카를 남긴다: 대시보드는 이 토큰으로 "내가 시작한 런"만 화면에 올린다.
    stream_opened = Ref(false)
    function enable_stream!(zone = nothing)
        stream_opened[] && return nothing
        CB.monitor_enable!(stream_path)
        write_run_info(run_info_path_of(COMMAND_FILE),
                       run_info(; run_id = RUN_ID, case = CASE_TAG, requires_zone = REQUIRE_ZONE,
                                started_at = time(), stream = basename(stream_path), zone = zone))
        stream_opened[] = true
        return nothing
    end
    REQUIRE_ZONE || enable_stream!()
    n_total = Graphs.nv(env.sched)
    fr(f) = max(4, round(Int, f * n_total))
    slots = [0.10, 0.32, 0.55]
    kinds = case_kinds(OODC)
    initial_closed = length(env.cache.closed_set)
    # 🔴 2026-08-25: `:zone in kinds` 였다. spec §5.1 이 zone 을 `case_kinds` 에서 빼면서 이 값이
    # 영원히 false 가 됐고, 아래 zone arming 블록 전체(:891 대화형 · :893 pre-sim/at-closed)가
    # 도달 불가가 됐다. run_demo.jl 과 **같은 술어**를 쓴다 — 두 엔진이 갈리면 그것 자체가
    # 이 레포의 반복된 사고다(2026-08-16 `all` 케이스 72판). 기본값 0 = 기존 녹화 재현 불변.
    has_zone = zone_requested()
    robot_kinds = filter(k -> k !== :zone, kinds)
    # DEMO_N (const above) = how many OOD events to inject (0 = one per case kind, the original
    # behaviour). When >0 it OVERRIDES the fault/battery event count, cycling the case's robot kinds
    # across the build. A zone always fires ONCE up front: spatial re-staging is only transform-safe
    # before any build step opens.
    demo_n = DEMO_N
    zone_at = 0
    # ---- 라이브 세션에서는 존을 **자동으로 심지 않는다** (2026-08-08) -----------------------
    # 존은 조작자가 시뮬레이션 시작 전에 ⛔(POST /inject/zone)로 넣는 사건이다. 그런데 이 블록은
    # 아래의 "interactive ready: waiting for the first operator command" 대기보다 **먼저** 돈다.
    # 자동 주입을 그대로 두면 사람이 넣기도 전에 존이 하나 서 있고, 사람이 넣은 것은 두 번째 존이
    # 되어 케이스의 뜻이 바뀐다(존 1개 → 2개). 그래서 대화형 런에서는 건너뛴다.
    # 로봇 OOD(fault/battery)는 그대로 확률 추첨된다 — 그쪽은 사람이 넣는 사건이 아니다.
    # 녹화(비대화형) 런은 종전대로 자동 주입한다: 그게 ③⑤⑥ 녹화를 만든 경로다.
    if has_zone && INTERACTIVE
        println("    · zone: 자동 주입 생략 — 조작자의 forbid-zone 명령을 기다린다(live session)")
    elseif has_zone
        if DEMO_ZONE_PRESIM
            # 첫 스텝 이전에 심는다 = 구역이 이미 서 있는 현장에서 빌드가 시작된다(케이스 ③⑤⑥ 동일).
            # blocking 가족을 먼저 시도한다: 후보를 못 찾으면 사건이 통째로 사라지므로(zone 케이스인데
            # zone 이 없는 런은 결과가 아니라 사고다) 무해 가족으로 폴백하고 그 사실을 남긴다.
            nl = DEMO_ZONE_MODE == "blocking" ? inject_blocking_zone!(env) : nothing
            nl === nothing && DEMO_ZONE_MODE == "blocking" &&
                println("[zone] pre-sim blocking placement failed → falling back to the harmless injector")
            nl === nothing && (nl = inject_staging_zone!(env))
            nl === nothing || CB.push_ood!(nl)
            println("    · zone($(DEMO_ZONE_MODE)) injected pre-sim")
            CB.arm_repair_ablation!()   # presim: 주입이 끝난 뒤에 무장한다(주입은 zone_relocatable 로 존을 고른다)
        elseif DEMO_ZONE_MODE == "blocking"
            # 옛 동작(DEMO_ZONE_PRESIM=0): 발화 시점에 심는다. 최소 몇 스텝은 굴린 뒤에
            # 골라야 `_nav_goal_targets` 의 "활성/비활성" 구분과 실제 위치가 뜻을 갖는다.
            zone_at = max(DEMO_ZONE_CLOSED, initial_closed + 4)
            # 후보를 하나도 못 찾으면(전부 활성이거나 복구 불가) 사건이 **통째로 사라진다** —
            # zone 케이스인데 zone 이 없는 런이 조용히 성립한다. 그건 결과가 아니라 사고이므로
            # 무해 가족으로 폴백해 사건 자체는 반드시 존재하게 하고, 그 사실을 로그에 남긴다.
            CB.schedule_ood_at_closed!(zone_at, function (e)
                nl = inject_blocking_zone!(e)
                nl === nothing && (println("[zone] blocking placement failed → falling back to the harmless injector");
                                   nl = inject_staging_zone!(e))
                CB.arm_repair_ablation!()   # deferred: 주입 직후 무장
                return nl
            end)
            println("    · zone(blocking) armed at closed=$(zone_at) " *
                    "(r=$(DEMO_ZONE_R)×robot radius)")
        else
            # Queue the zone before the first simulation step, while all affected assemblies
            # can still be safely re-staged.
            nl = inject_staging_zone!(env)
            nl === nothing || CB.push_ood!(nl)
            println("    · zone(harmless) injected pre-sim")
        end
    end
    (has_zone && !DEMO_ZONE_PRESIM && DEMO_ZONE_MODE == "blocking") || CB.repair_ablation_armed() ||
        CB.arm_repair_ablation!()   # 존이 없거나 harmless 판: 시뮬 시작 전에 무장
    n_robot = demo_n > 0 ? demo_n : length(robot_kinds)   # DEMO_N overrides the robot-OOD count
    # 로봇 OOD 가 들어갈 수 있는 진척 구간 [lo, hi] (닫힌 노드 수 단위).
    #   lo : 너무 이르면 아직 아무 일도 안 벌어진 빈 현장에서 터진다.
    #   hi : 너무 늦으면 복구할 일이 남아 있지 않아 어떤 정책을 써도 결과가 같다.
    # zone 케이스에서는 lo 를 더 밀어 둔다 — sim 전에 심은 존의 기하 복구(restage)와 같은 배치에서
    # 건강 사건 인계가 겹치면 안 되기 때문(기존 고정 스케줄의 recovery_fraction 가드와 같은 뜻).
    lo = fr(0.10)
    hi = fr(0.75)
    if has_zone
        lo = max(lo, fr(0.32), initial_closed + max(10, round(Int, 0.08 * n_total)))
    end
    hi = max(hi, lo + max(4, round(Int, 0.10 * n_total)))
    if get(ENV, "DEMO_PROBE", "0") == "1"
        # 진단 모드: OOD 를 넣지 않고 "어느 진척 구간에서 어떤 사건이 **가능한가**"만 훑는다.
        # 확률적 시점을 도입하면서 알게 된 것 — safe fault 는 단독 운반체가 있을 때만 가능하고,
        # 그 구간은 빌드 초반에 몰려 있다. 창을 추측으로 정하지 않으려면 이 측정이 필요하다.
        # 스텝 단위로 훑는다. closed 단위는 너무 성기다 — tractor 는 **첫 스텝에 이미 54 개**가 닫혀
        # 있어서(모션 없이 닫히는 노드가 많다) closed 로는 초반을 전혀 분해하지 못한다.
        # 판정은 fault_robot!(safe=true) 와 **같은 두 단계**를 그대로 쓴다(strict → frontier 폴백).
        probe = nothing
        probe_step = try parse(Int, get(ENV, "DEMO_PROBE_EVERY", "20")) catch; 20 end
        probe_next = Ref(probe_step)
        probe = function (env)
            closed = length(env.cache.closed_set)
            strict = try CB.pick_solo_fault_target(env) catch e; "ERR:" * string(typeof(e)) end
            front  = try CB.pick_solo_frontier_target(env) catch e; "ERR:" * string(typeof(e)) end
            ok = (strict !== nothing && !(strict isa String)) || (front !== nothing && !(front isa String))
            println("[probe] closed=$closed strict=$(strict === nothing ? "-" : string(strict)) " *
                    "frontier=$(front === nothing ? "-" : string(front)) faultable=$(ok ? "YES" : "no")")
            probe_next[] += probe_step
            CB.schedule_ood!(probe_next[], probe)
            return nothing
        end
        CB.schedule_ood!(probe_step, probe)
        println(">>> PROBE MODE: no OOD injected; scanning fault feasibility every $probe_step sim steps")
    elseif DEMO_SEED > 0 && !isempty(robot_kinds)
        # --- 확률적 스케줄(기본) -------------------------------------------------------------
        # **스텝 단위**로 뽑는다. closed(완료 노드 수) 단위는 초반을 전혀 분해하지 못한다 --
        # tractor 는 모션 없이 닫히는 노드가 많아 첫 스텝에 이미 54/313 이 닫혀 있다(측정).
        #
        # 창은 종류마다 다르다. 이것도 측정 결과다(DEMO_PROBE=1 로 재현 가능):
        #   · battery : 건강한 로봇만 있으면 되므로 빌드 어디서나 가능 -> 넓은 창
        #   · fault(safe) : 단독 운반체(또는 solo frontier carry)가 있어야 하는데, tractor 에서 그 조건은
        #     step 2~20 에만 성립하고 그 뒤로는 전 구간 불가능하다. 창을 넓게 잡으면 사건이 통째로
        #     사라진다(실제로 첫 확률 실행이 그렇게 불발했다).
        #
        #     [2026-08-05 갱신] 위 (2,20) 은 **hot-swap 이전 조건**이다. 이 데모는 426 줄에서
        #     `set_hot_swap!(enabled=true)` 를 켜므로, `fault_robot!(safe=true)` 의 3단 사다리 마지막
        #     칸(`pick_hotswap_fault_target`)이 살아 있어 **빌드 중반·후반에도 안전한 대상이 있다**
        #     (측정: wm4.../oracle/out/fire_probe_hotswap.csv 의 n_hotswap 열 = closed 58~240 에서 10).
        #     후반 고장을 보고 싶으면 DEMO_FAULT_SAFE=1 과 함께 창을 넓히면 된다:
        #         DEMO_FAULT_SAFE=1 DEMO_FAULT_STEPS=60,600
        #     기본값은 바꾸지 않았다 — 녹화된 데모 스트림의 재현성을 지키기 위해서다.
        # 창 밖으로 뽑혀도 아래 retrying_action 이 **다음 가능한 순간까지 미룬다**.
        parse_win = function (s, dflt)
            try
                p = split(s, ","); (parse(Int, strip(p[1])), parse(Int, strip(p[2])))
            catch; dflt end
        end
        fault_win = parse_win(get(ENV, "DEMO_FAULT_STEPS", ""), FAULT_SAFE ? (2, 20) : (60, 600))
        batt_win  = parse_win(get(ENV, "DEMO_BATTERY_STEPS", ""), (40, 700))
        if has_zone
            # 존 케이스는 sim 전에 심은 존의 기하 복구(restage)가 먼저 끝나야 한다. 건강 사건이 같은
            # 배치에 끼면 스케줄이 엉킨다 -- 고정 슬롯 시절의 recovery_fraction 가드와 같은 뜻.
            fault_win = (max(fault_win[1], 6), max(fault_win[2], 26))
            batt_win  = (max(batt_win[1], 60), batt_win[2])
        end
        rng = Random.MersenneTwister(DEMO_SEED)
        # ---- 종류 추첨은 **비복원**이다 (2026-09-06) ------------------------------------------
        # 예전에는 사건마다 `robot_kinds` 전체에서 복원추출했다. 그래서 `fault_battery` 같은 혼합
        # 케이스에서 같은 종류가 두 번 뽑혔고(실측: X-wing all3 30판 중 7판), 이미 `DEPLETED` 인
        # 로봇을 또 방전시키는 **무해한 재타격**이 생겼다 — 그 판의 all3 는 교란이 사실상 둘이다.
        # 아래 옛 고정 슬롯 분기(:1134)는 `((j-1) % length)+1` 로 종류를 번갈아 써서 "한 종류씩"이
        # 보장돼 있었는데, 확률 분기로 오면서 그 성질만 사라졌다. 그것을 되돌린다.
        #
        # 🔴 **RNG 소비를 바꾸지 않는다.** 종류가 하나뿐인 케이스(battery 단독 / fault 단독)에서는
        #    pool 이 늘 1 원소라 호출이 `rand(rng, 1:1)` 로 예전과 같고, 따라서 그 두 열의 녹화는
        #    **바이트 동일**하다(음성 대조가 이 성질을 잰다). zone 은 robot_kinds 가 비어 이 분기를
        #    아예 안 탄다. 바뀌는 것은 혼합 케이스뿐이다.
        kind_pool = copy(robot_kinds)
        for j in 1:n_robot
            isempty(kind_pool) && (kind_pool = copy(robot_kinds))   # 사건 수 > 종류 수면 다시 채운다
            ki   = rand(rng, 1:length(kind_pool))
            kind = kind_pool[ki]; deleteat!(kind_pool, ki)
            win  = kind === :fault ? fault_win : batt_win
            at   = rand(rng, win[1]:win[2])
            inner = kind === :fault ?
                CB.fault_action(; safe = FAULT_SAFE, obstacle = false) :
                CB.battery_action(soc_drop = (DEMO_BSEVERE > 0 && rand(rng) < DEMO_BSEVERE ?
                                              1.0 : DEMO_BSOC))
            CB.schedule_ood!(at, retrying_action(inner; at = at,
                                                 every = kind === :fault ? 2 : 8,
                                                 max_tries = 300, tag = String(kind)))
            println("    · $(kind) drawn at step=$(at)  (window $(win[1])–$(win[2]), safe_fault=$(FAULT_SAFE))")
        end
    else
        # --- 옛 고정 슬롯 스케줄(DEMO_SEED=0, 재현용) ------------------------------------------
        for j in 1:n_robot
            isempty(robot_kinds) && break
            kind = robot_kinds[((j - 1) % length(robot_kinds)) + 1]   # cycle fault/battery across N events
            frac = demo_n > 0 ? (n_robot == 1 ? 0.10 : 0.10 + 0.65 * (j - 1) / (n_robot - 1)) :
                                slots[min(j, 3)]                      # original slot placement when DEMO_N=0
            at = fr(frac)
            if has_zone
                # Keep a health hand-off out of the same simulation batch as the pre-build geometry recovery.
                recovery_fraction = kind === :fault ? 0.20 : 0.32
                at = max(at, fr(recovery_fraction), initial_closed + max(10, round(Int, 0.08 * n_total)))
            end
            if kind === :fault
                # A breakdown is an asset-health event, not an implicit spatial exclusion zone. obstacle=false
                # avoids creating a hidden second zone that could block compound Break+Zone construction.
                CB.schedule_ood_at_closed!(at, CB.fault_action(; safe = true, obstacle = false))
            elseif kind === :battery
                # soc_drop 은 DEMO_BSOC 로 조절한다(기본 0.96 = 심각 -> 규칙이 ReplaceAgent 를 냄).
                # 0.45 정도면 애매한 구간이 되어 정책마다 답이 갈린다(대시보드 ⑦ Battery (mild)).
                CB.schedule_ood_at_closed!(at, CB.battery_action(soc_drop = DEMO_BSOC))
            end
        end
    end
    n_zone = has_zone ? 1 : 0                             # zone is ALWAYS fixed at 1
    zone_tag = n_zone == 0 ? "" :
               DEMO_ZONE_PRESIM ? " [$(DEMO_ZONE_MODE), pre-sim]" :
               DEMO_ZONE_MODE == "blocking" ? " [blocking, @closed=$(zone_at)]" : " [harmless, pre-sim]"
    rk_str = isempty(robot_kinds) ? "none" : join(string.(robot_kinds), "/")
    n_tag = demo_n > 0 ? " (DEMO_N)" : ""
    sched_tag = DEMO_SEED > 0 ? "stochastic seed=$(DEMO_SEED), step-window draw" : "fixed slots (legacy)"
    println(">>> OOD armed: zone×$(n_zone)$(zone_tag) + $(rk_str)×$(n_robot)$(n_tag) [$sched_tag]" *
            "  model=$MODEL scale=$SCALE robots=$NROB")
    if !isempty(COMMAND_FILE)
        control = command_file_hook(COMMAND_FILE)
        CB.monitor_set_control_hook!(control)
        if INTERACTIVE
            # 기다리기 **전에** 평면도를 떨어뜨린다 — 대기 중에 조작자가 봐야 할 그림이기 때문.
            # 실패해도 런을 죽이지 않는다: 평면도는 고르는 것을 **돕는** 그림이고, 대시보드 상단의
            # 숫자 X/Y/R inject 바로도 구역을 넣을 수 있다(그 경로는 평면도와 무관하게 살아 있다).
            drew = try dump_layout(env, COMMAND_FILE) catch e
                println("[layout] 평면도 덤프 실패 — 숫자 X/Y/R inject 바로 넣으면 된다: ",
                        sprint(showerror, e)); false
            end
            if REQUIRE_ZONE
                # 마감 없는 게이트. 구역이 이 케이스의 사건 그 자체이므로 "시간이 지나서 없이 시작"은
                # 있을 수 없다. 조작자가 그만두려면 abort 명령을 보낸다(대시보드의 Cancel).
                println(">>> interactive ready: **waiting for the operator to define a forbid zone** " *
                        "(MONITOR_REQUIRE_ZONE=1 — no deadline; send an abort command to cancel)" *
                        (drew ? "" : "  [no floor plan — use the numeric X/Y/R inject bar]"))
                waited = 0.0
                while true
                    k = pending_command_kind(COMMAND_FILE)
                    k === :zone && break
                    if k === :abort
                        println(">>> operator aborted before the first step — no simulation was run")
                        exit(0)
                    end
                    sleep(0.2); waited += 0.2
                    # 10 초마다 살아 있다는 표시. 로그만 보고 "멈춘 것"과 "기다리는 것"을 구분할 수 있어야 한다.
                    (waited % 10 < 0.2) && println("    · still waiting for the operator zone " *
                                                   "($(round(Int, waited))s)")
                end
                # 조작자가 확정한 구역을 사이드카에 실어 남기고, 그때 비로소 스트림을 연다.
                enable_stream!(last_zone_command(COMMAND_FILE))
            elseif MONITOR_WAIT > 0
                println(">>> interactive ready: waiting up to $(round(Int, MONITOR_WAIT))s for the " *
                        "first operator command (MONITOR_WAIT=0 to start immediately with no zone)")
                deadline = time() + MONITOR_WAIT
                while (!isfile(COMMAND_FILE) || filesize(COMMAND_FILE) == 0) && time() < deadline
                    sleep(0.2)
                end
            else
                println(">>> interactive ready: MONITOR_WAIT=0 — starting immediately, no pre-sim zone " *
                        "(zones injected later in the run still take effect)")
            end
            # 게이트가 없는 대화형 런(MONITOR_WAIT 경로)도 첫 명령 적용 전에는 스트림이 열려 있어야
            # 한다 — control 이 inject_live_zone! 을 부르고 그것이 OOD 를 기록하기 때문.
            enable_stream!()
            # Apply the initial zone before the first motion/planning step. This
            # keeps all physical parts relocatable by the production respec path.
            control(env, nothing, nothing, 0)
        end
    end
end

render_result = Ref{Any}(nothing)
# `[ablation]` 줄은 판마다 **정확히 한 번**(Task 8 M1). 정상 경로에서는 `[score]` 뒤에 찍고, 시뮬이
# 던지면(render_result 가 비어 있으면) 아래 `finally` 에서 찍는다 — 던진 판도 카운터를 남긴다.
const _ABLATION_LINE_PRINTED = Ref(false)
function print_ablation_line!()
    _ABLATION_LINE_PRINTED[] && return nothing
    _ABLATION_LINE_PRINTED[] = true
    println("[ablation] ", CB.ablation_summary_line())
    return nothing
end
try
    # -----------------------------------------------------------------------------------------
    # save_animation 과 라이브 시청은 **더 이상 상호배타가 아니다** (2026-08-05).
    #
    # 과거 이력: animate_update_visualizer!(render_tools.jl) 은 anim 이 있으면 갱신을 `atframe(...)`
    # 안에서 수행한다 = 그 스텝의 변환을 애니메이션에 기록만 하고 라이브 장면에는 적용하지 않는다.
    # 그래서 save_animation=true 로 라이브 세션을 열면 MeshCat 화면이 초기 배치에서 멈춘 것처럼
    # 보였고, 그 때문에 대화형 세션은 애니메이션을 아예 끄고 돌렸다 — 대신 anim 산출물이 없어서
    # "라이브로 본 런은 나중에 3D 로 다시 볼 수 없다"는 대가를 치렀다.
    #
    # 이제 demo_utils.simulate! 이 기록(atframe)과 라이브 표시(update_visualizer!)를 **독립적으로**
    # 수행한다(LIVE_PUSH). 그래서 두 개를 같이 켤 수 있고, 애니메이션이 기본값이다.
    # 끄려면 DEMO_ANIM=0.
    render_result[] = CB.run_lego_demo(;
        ldraw_file = MODEL, project_name = "$(model_base)_render", num_robots = NROB,
        model_scale = SCALE, assignment_mode = :greedy,
        save_animation = DEMO_ANIM, anim_active_agents = true, anim_active_areas = true,
        # live_view: MeshCat 장면을 매 스텝 직접 구동한다(기록 여부와 무관). 애니메이션을 끈 런
        # (DEMO_ANIM=0)에서는 이게 없으면 시각화기 자체가 안 만들어져 **8700 에 아무것도 없다**.
        live_view = INTERACTIVE,
        update_anim_at_every_step = INTERACTIVE,   # 라이브에서는 매 스텝 장면을 밀어 준다
        overwrite_results = true, n_spare_per_pool = 2, pre_sim_hook = pre,
        log_level = DEMO_LOGLEVEL,                 # WEDGE_DEBUG/NAV_DEBUG 켜면 Info 까지 통과(위 주석 참조)
        max_num_iters_no_progress = 3000, rng = Random.MersenneTwister(1))
finally
    CB.monitor_disable!()
    try CB.monitor_clear_control_hook!() catch end
    try CB.clear_respec_producer!() catch end
    CB.RESPEC_ENABLED[] = false
    render_result[] === nothing && print_ablation_line!()   # 시뮬이 던졌다 — 그래도 한 줄
end

render_result[] === nothing && error("render did not return a simulation environment")
render_env, _render_stats = render_result[]

# 이번 런이 만든 visualization.html 을 anim/ 로 퍼블리시한다. DEMO_ANIM=0 이면 아무것도 안 한다.
function publish_anim!(; suffix = "")
    DEMO_ANIM || return false
    viz = joinpath(dirname(pathof(CB)), "..", "results", "$(model_base)_render",
                   "greedy_RVO_Dispersion_TangentBug", "visualization.html")
    if isfile(viz)
        dst = joinpath(anim_dir, "$(model_base)__$(CASE_TAG)$(NSUF)$(suffix).html")
        cp(viz, dst; force = true)
        println("[render] anim → ", dst)
        return true
    end
    println("[render] visualization.html not found at ", viz)
    return false
end

# 대화형 세션은 사람이 개입하므로 완주하지 않는 것이 정상이다(원하는 지점에서 멈추거나, 주입한
# 존이 감당 못 할 만큼 클 수도 있다). 그래서 미완주를 오류로 보지 않는다.
#
# 2026-08-05: 예전에는 여기서 애니메이션 없이 그냥 나갔다("no anim artifact"). 이제 라이브
# 세션도 기록을 남기므로 같이 퍼블리시한다. **이번 런이 만든** 파일이라 왼쪽 패널의 스트림과
# 같은 런이며, 대시보드가 경고하던 "옛 런의 애니가 지금 런인 척하는" 상황이 되지 않는다.
# 🔴 zone 레인의 채점은 **두 축**이다(2026-09-05 실측). "존이 치워졌나" 와 "빌드가 끝났나" 는
# 다른 사실이다: z1·z3 는 수리가 성공해 `n_blocked=0 project_blocked=false` 가 된 **뒤에** 얼었다
# (운반유닛 셋이 로봇 한 대에 겹쳐 걸린 교착). 완주율 하나로 채점하면 세계의 교착이 합성 레인의
# 실패로 집계된다 — 앞서 "존 랜덤화 6/8" 이 그렇게 잘못 읽힌 자리다. 그래서 완주·미완주 양쪽에서,
# 미완주가 error 로 죽기 **전에**, 기계가 읽을 수 있는 한 줄로 남긴다.
try let e = render_env
    zb = try CB.zone_blockage(e) catch; nothing end
    nz = try length(collect(CB.active_restriction_zones())) catch; -1 end
    println("[score] complete=", CB.project_complete(e),
            " closed=", length(e.cache.closed_set),
            " n_zones=", nz,
            zb === nothing ? " zone_blockage=unavailable" :
              string(" n_blocked=", zb.n_blocked, " n_nav_goals=", zb.n_nav_goals,
                     " n_engulfed=", zb.n_engulfed, " n_agent_trapped=", zb.n_agent_trapped,
                     " project_blocked=", zb.project_blocked))
end
finally
    print_ablation_line!()      # `[score]` 뒤 — `[score]` 가 던져도 한 줄
end

if INTERACTIVE
    ok = publish_anim!()
    n_live = isfile(stream_path) ? countlines(stream_path) : 0
    println("[render] DONE (interactive) — case=$CASE_TAG  $n_live frames, live view driven directly " *
            "$(ok ? "+ anim" : "(no anim artifact)")  complete=$(CB.project_complete(render_env))")
    exit(0)
end

(!CB.project_complete(render_env) && !isempty(DEMO_OUT_DIR)) &&
    publish_anim!(; suffix = "__INCOMPLETE")      # 탐침 폴더에서만 — 공유 anim/ 은 여전히 거절한다
CB.project_complete(render_env) ||
    error("refusing to publish incomplete animation for model=$MODEL case=$OODC")

publish_anim!()
n = isfile(stream_path) ? countlines(stream_path) : 0
println("[render] DONE — case=$OODC  $n frames + anim")
# 진단: 애니 프레임 수 = visualizer_update_function! 호출 횟수(render_tools._VIS_FRAME).
# 방전 틴트 유지(BATTERY_TINT_HOLD_FRAMES)가 **이 단위**로 세므로, 그 값이 화면에서 몇 초인지
# 알려면 이 수와 sim 길이의 비를 봐야 한다. 모니터 스트림 프레임 수(n)와는 다른 시계다.
# ⚠️ Ref 기본값(BATTERY_TINT_HOLD_FRAMES[])이 아니라 **실제 적용값**을 찍는다 — 환경변수
# BATTERY_TINT_HOLD_FRAMES 가 Ref 를 이기므로, Ref 를 찍으면 3 으로 돌린 런이 17 로 보고된다
# (2026-08-15 에 실제로 그렇게 오독했다).
println("[render] anim frames=$(try CB._VIS_FRAME[] catch; "?" end)  " *
        "battery tint hold=$(try CB._tint_hold_frames() catch; "?" end) frames (적용값)")
# 화면 사건을 **세어서** 남긴다. MeshCat 정적 HTML 은 노드 경로를 평문으로 담지 않으므로
# 산출물 grep 으로는 "빨강/초록이 실제로 켜졌나"를 사후 확인할 수 없다.
#   red   = 방전 로봇 본체가 빨갛던 프레임 수(배송 대기 구간)
#   green = 배터리 배송 중인 창고 예비가 초록이던 프레임 수(출발~복귀 도킹)
println("[render] battery tint frames: red=$(try CB._BATTERY_TINT_FRAMES[] catch; "?" end) " *
        "green(courier)=$(try CB._COURIER_TINT_FRAMES[] catch; "?" end)  " *
        "courier=$(try CB.battery_courier_enabled() catch; "?" end)")
