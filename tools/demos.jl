# =============================================================================
# tools/demos.jl -- consolidated ConstructionBots demo driver.
#
# Every standalone tools/demo_*.jl script is now a FUNCTION in module `Demos`,
# sharing common boilerplate (MILP setup + run_with_stack) defined ONCE. A CLI/ENV
# dispatcher at the bottom lets any single demo run individually.
#
# Demo keys:
#   original_baseline   -- vanilla SISL build (no OOD / no respec)          [before]
#   run_zone            -- OOD 1-2 restriction no-go zone; robots detour (RESPEC off, physical)
#   wholebuild          -- central forbid zone -> whole-build translate (geom recovery direct)
#   respec_forbidzone   -- ForbidZone respec pipeline via mock LLM seam
#   respec_replace      -- OOD 1-1 ReplaceAgent (robot breakdown -> spare) via mock LLM seam
#   energy_adaptive     -- energy-aware adaptive replanning, multi-OOD, NO animation (metrics only)
#   energy_adaptive_anim-- energy-aware adaptive replanning, VISUAL (battery HUD sidebar)
#   energy_stall_replace-- closed battery loop: SoC=0 stall -> ReplaceAgent -> depot spare (VISUAL)
#   debug               -- DIRECT (no stack-task) colored_8x8 run, viz OFF; Ctrl+C shows real backtrace
#   fast                -- FAST tractor build, physics OFF (straight-line); LIVE MeshCat, waits on Enter
#   bigstack            -- LARGE x_wing on 4 GB C stack, MILP warm-start, full nav (~minutes)
#
# Run:
#   julia +lts --project=. tools/demos.jl <demo_key>        (or  ENV DEMO=<key>)
# e.g.
#   julia +lts --project=. tools/demos.jl respec_replace
# Each demo reads its own ENV knobs at call time (see the comment above each function).
# =============================================================================
#
# ==========================[ 한국어 설명 ]====================================
#  이 파일이 하는 일 (쉽게):
#   · ConstructionBots 는 "여러 로봇이 협력해 레고 같은 구조물을 조립"하는 시뮬레이터다.
#   · 조립 중 예상 못한 사건(OOD: Out-Of-Distribution)이 터진다 — 로봇 고장, 배터리 방전,
#     갑자기 생긴 통행금지 구역(no-go zone) 등.
#   · 이 repo 는 그런 사건이 나면 "다시 계획을 세워(respec)" 복구하는 여러 방식을 실험한다.
#       (1) LLM 이 자연어 사건설명 → DSL 매크로(ReplaceAgent 등) 로 번역해 대응.
#   · 이 demos.jl 은 실 LLM 실행 흐름을 "하나씩 실행해 눈으로 보는" 데모 모음(드라이버)이다.
#     예전엔 tools/demo_*.jl 로 흩어져 있던 스크립트들을, 공통 준비코드를 한 번만 정의하고
#     각 데모를 Demos 모듈 안의 "함수 하나"로 모아 통합했다.
#
#  프로젝트 안에서의 위치:
#   · 이 파일은 "실행/시연" 계층이다. 실제 계획·조립·복구 로직은 ConstructionBots 패키지(CB)와
#     src/navigator/ 안에 있고, 여기서는 그것들을 불러다 시나리오를 꾸미고 애니메이션(HTML)만 만든다.
#
#  실행 방법 (맨 아래 dispatcher 가 처리):
#     julia +lts --project=. tools/demos.jl <데모키>       또는   DEMO=<데모키> julia ... tools/demos.jl
#   <데모키> 목록은 위 "Demo keys" 표와 파일 맨 아래 const DEMOS 딕셔너리 참고.
#
#  ---- 문법 참고 (Julia 처음 보는 사람을 위한, 이 파일에 자주 나오는 것들) ----
#   · function f(x) ... end : 함수 정의. `f(x) = ...` 는 한 줄짜리 축약형(같은 뜻).
#   · f(x::T) : 인자 x 가 타입 T 일 때만 쓰는 메서드(다중 디스패치). 같은 이름 함수를 타입별로 여러 번 정의 가능.
#   · `!` 로 끝나는 함수(add_restriction_zone! 등) = 인자/상태를 직접 바꾼다(in-place)는 관례.
#   · `:zone`, `:fault` 처럼 콜론으로 시작 = Symbol(가벼운 상수 이름표). 문자열보다 빠른 "종류 태그"로 씀.
#   · @info, @sprintf, @__FILE__ 처럼 `@` 로 시작 = 매크로(컴파일 시 코드로 펼쳐짐). @info=로그출력, @sprintf=형식문자열.
#   · Ref(x) / r[] : 값 하나를 담는 "상자". r[] 로 읽고 쓴다. 클로저(중첩함수) 안에서 바깥값을 바꿀 때 씀.
#   · [f(x) for x in xs if cond] : 컴프리헨션(리스트 내포). xs 를 돌며 조건에 맞는 것만 모아 배열 생성.
#   · do ... end 블록 : 함수의 "첫 인자로 넘기는 익명함수"를 예쁘게 쓰는 문법.
#       run_with_stack(N) do ... end  ==  run_with_stack(()->(...), N) 와 같음.
#   · a ? b : c : 삼항 조건식(b if a else c). `&&`, `||` 는 "짧은회로"라 조건부 실행에도 쓰임(cond && do()).
#   · get(ENV, "KEY", "기본") : 환경변수 읽기(없으면 기본값). 데모마다 이걸로 ENV 노브(knob)를 읽는다.
#   · CB.xxx : ConstructionBots 패키지의 함수/전역을 부를 때 쓰는 별칭(맨 위 const CB = ConstructionBots).
#   · `$변수` / `$(식)` : 문자열 안에 값 끼워넣기(interpolation). "closed=$n" 처럼.
# =============================================================================
module Demos
# 이 파일 전체를 Demos 라는 모듈(namespace)로 감싼다 — 데모 함수들이 전역을 어지럽히지 않게.
using ConstructionBots          # 핵심 패키지: 계획/조립/복구 로직 전부 여기 있음
using Printf                    # @sprintf(형식맞춘 문자열) 사용용
import Logging, HiGHS, HTTP, JSON3, Graphs, LinearAlgebra, Random  # 로깅/MILP솔버/HTTP서버/JSON/그래프/선형대수/난수
const CB = ConstructionBots     # 긴 이름을 CB 로 줄여 씀 (CB.함수() 형태)
const norm = LinearAlgebra.norm # 벡터 길이(크기) 계산 함수에 짧은 별칭

# ---- runtime-loaded decoupled layers (loaded ONCE, at module load) ----------
# The navigator layer is NOT compiled into the ConstructionBots package -- the
# demos historically `CB.include`d it at SCRIPT TOP LEVEL. Now that each demo is
# a FUNCTION, doing those includes *inside* a demo and then calling the
# freshly-defined methods in the SAME call frame raises a world-age error
# ("method too new to be called from this world context"). Loading it here at
# MODULE load puts it in an OLDER world than any demo call, exactly reproducing
# the original top-level-include semantics.
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))

# ---- shared helpers (defined ONCE) ------------------------------------------
# The set_default_milp_optimizer! block that appears (identically) in 8 of the 10
# demos. The two surrogate demos use a DIFFERENT attribute set (output_flag instead
# of MOI.Silent, 60s/0.05 gap) and keep their block inline -- see those functions.
# _setup_milp! : 작업배정에 쓰는 MILP(정수최적화) 솔버(HiGHS)를 공통 설정. 10개 데모 중 8개가 이 블록을 그대로 씀.
#   time_limit=제한시간(초), mip_rel_gap=허용 최적성 갭(클수록 빨리 대충 풂). `;` 뒤 인자 = 키워드 인자(이름으로 넘김).
function _setup_milp!(; time_limit = 300.0, mip_rel_gap = 5.0)
    CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())   # 솔버 팩토리 등록(() -> ... = 인자없는 익명함수)
    CB.clear_default_milp_optimizer_attributes!()             # 이전 설정 초기화
    CB.set_default_milp_optimizer_attributes!(
        "time_limit" => time_limit, "presolve" => "on", "mip_rel_gap" => mip_rel_gap,
        CB.MOI.Silent() => true)                              # MOI.Silent()=솔버 로그 끄기
end

# run_with_stack : 함수 f 를 "C 스택 크기를 크게 잡은 별도 Task(경량 스레드)"에서 실행한다.
#   조립 시뮬레이션은 재귀가 깊어 기본 스택으론 넘칠 수 있어, 큰 stacksize(예: 2GB) 로 새 Task 를 만들어 돌린다.
#   do 블록으로 호출: run_with_stack(2_000_000_000) do ... end  (f 는 그 do 블록 본문).
# The identical stack-growing task helper from 9 of the 10 demos.
function run_with_stack(f, stacksize::Int)
    # res=결과 상자, err=에러 상자, done=완료 플래그(원자적). Ref/Atomic = Task 간 값 공유용 상자.
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    # ccall 로 Julia 런타임에 직접 "지정 스택크기의 새 Task" 생성. 본문에서 f() 실행 후 결과/에러를 상자에 저장.
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end  # 아무 스레드서 실행 허용→예약→끝날 때까지 대기
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))  # 에러났으면 역추적 출력 후 재던짐
    return res[]                                                    # f 의 반환값
end

# =============================================================================
# original_baseline -- the ORIGINAL SISL ConstructionBots demo, unchanged. Plain
#   run_lego_demo tractor build with the full nav stack; no OOD/respec/fault/zone.
#   ENV: OPEN_ANIM (open browser at end).
# =============================================================================
# demo_original_baseline : 아무 사건도 안 넣은 "원래 SISL 데모" — 트랙터를 그냥 조립(비교의 기준선 = before).
#   ENV: OPEN_ANIM(=1이면 끝나고 브라우저 자동열기, 0이면 HTML만 저장).
function demo_original_baseline()
OPEN_ANIM = get(ENV, "OPEN_ANIM", "1") == "1"   # set OPEN_ANIM=0 to only save the HTML  # ENV값 "1"이면 참

_setup_milp!()   # 공통 MILP 솔버 설정

# hygiene: make sure no OOD/zone/respec state leaks in from a shared session (fresh process anyway)
CB.clear_ood_schedule!(); CB.clear_restriction_zones!()   # 이전 세션의 OOD/구역 상태가 남지 않게 청소

project_params = CB.get_project_params(4)   # 4 = tractor (same as scripts/demos.jl)  # 4번=트랙터 모델 파라미터

println(">>> ORIGINAL SISL ConstructionBots demo: project=$(project_params[:project_name]) " *
        "(plain build, NO OOD / NO respec)")
println(">>> building + simulating with FULL NAV + ANIMATION (slow; HTML saved at end)...")

# run_lego_demo = 핵심 진입점: 모델 로드→작업배정(MILP/greedy)→물리 시뮬레이션→애니메이션 저장까지 한 번에.
#   아래 키워드들은 모두 그 동작 옵션. rvo/tangent_bug/dispersion = 충돌회피·경로 물리 스택(켜면 사실적, 느림).
env, stats = CB.run_lego_demo(;
    ldraw_file=project_params[:file_name],         # LDraw 부품 파일
    project_name=project_params[:project_name],
    model_scale=project_params[:model_scale],
    num_robots=project_params[:num_robots],
    assignment_mode=:greedy,                       # 작업배정 방식(그리디)
    milp_optimizer=:highs,
    optimizer_time_limit=60,
    rvo_flag=true,                                 # RVO = 상호 충돌회피 ON
    tangent_bug_flag=true,                         # TangentBug = 장애물 우회 경로 ON
    dispersion_flag=true,                          # 로봇 분산(뭉치지 않게) ON
    # --- animation ON (save; do not auto-open unless OPEN_ANIM=1) ---
    open_animation_at_end=OPEN_ANIM,
    save_animation=true,
    save_animation_along_the_way=false,
    anim_active_agents=true,
    anim_active_areas=true,
    update_anim_at_every_step=true,
    save_anim_interval=100,
    process_updates_interval=100,
    block_save_anim=false,
    # --- housekeeping ---
    write_results=false,
    overwrite_results=true,
    look_for_previous_milp_solution=false,
    save_milp_solution=false,
    previous_found_optimizer_time=30,
    max_num_iters_no_progress=2500,
    stop_after_task_assignment=false,
);

htmlpath = joinpath("results", project_params[:project_name], "greedy_RVO_Dispersion_TangentBug", "visualization.html")  # 결과 애니메이션 HTML 경로
println(">>> done. Animation saved: $htmlpath")
end   # demo_original_baseline 끝

# =============================================================================
# wholebuild -- VISUAL demo of whole-build translation. At OOD_STEP drops a CENTRAL
#   forbid zone over the root core, tries per-assembly restage_all, then
#   translate_whole_build! to shift the ENTIRE build clear of the zone.
#   ENV: NAVON_PROJECT, OOD_STEP, NAVON_ZONE_R, OPEN_ANIM, GRID_SCALE.
# =============================================================================
# demo_wholebuild : 조립물 "정중앙"에 통행금지 구역(ForbidZone)을 떨궈서, 개별 재배치로 안 되면
#   빌드 전체를 통째로 평행이동(translate_whole_build!)해 구역을 피하는 기하적 복구를 보여주는 시각 데모.
#   (LLM 없이 복구 함수를 직접 호출하는 버전.)  ENV: NAVON_PROJECT, OOD_STEP, NAVON_ZONE_R, OPEN_ANIM, GRID_SCALE.
function demo_wholebuild()
PROJECT  = parse(Int, get(ENV, "NAVON_PROJECT", "4"))      # 4 = tractor  # parse(Int, 문자열)=정수변환
# Inject EARLY (default 5): translate_whole_build! is an MVP that only relocates a build
# whose parts are not yet IN TRANSPORT. step_1_closed≈45 trivial nodes close at iter 1, so
# iter~5 ≈ the headless-validated closed=46 state (nothing carried yet). Larger OOD_STEP
# injects mid-transport and the moved deposit slots desync in-flight cargo -> capture assert.
OOD_STEP = parse(Int, get(ENV, "OOD_STEP", "5"))           # sim step to drop the zone + recover
ZONE_R   = parse(Float64, get(ENV, "NAVON_ZONE_R", "2.5")) # central zone radius (covers root core)
OPEN_ANIM = get(ENV, "OPEN_ANIM", "1") == "1"             # open browser at end (set OPEN_ANIM=0 to only save HTML)
GRID_SCALE = parse(Float64, get(ENV, "GRID_SCALE", "4.0")) # widen MeshCat default floor grid (cosmetic) so the relocated build stays on-grid

_setup_milp!()

# ood_recover! : OOD 발생 시 실행할 동작. 중앙에 금지구역을 놓고, 재배치→전체이동 순서로 복구 시도.
#   nothing 을 반환 = "LLM respec 경로는 건너뛰고 복구를 직접 몰겠다"는 뜻(respec 큐에 안 넣음).
# The OOD action: drop the central zone, then geometric recovery. Returns `nothing`
# (skip the LLM respec path -- we drive restage/whole-build directly).
function ood_recover!(env)
    gs = CB.root_deposit_goals(env)                          # 루트(최종) 조립물의 목표 놓는 위치들
    # rootc = staging_circles 중 반지름이 가장 큰(=루트) 원의 중심 [x,y]. argmax(k->..., 키들)=값 최대인 키.
    rootc = Vector{Float64}(CB.get_center(
        env.staging_circles[argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))])[1:2])
    zc = isempty(gs) ? rootc : sum(gs) ./ length(gs)         # 구역 중심 = 목표들 평균(없으면 루트중심). ./ = 원소별 나눗셈
    CB.add_restriction_zone!(:block, zc, ZONE_R)             # zc 중심, 반지름 ZONE_R 인 통행금지 구역 추가
    @info "[DEMO] OOD @ step $OOD_STEP: central zone@$(round.(zc;digits=2)) R=$ZONE_R (root@$(round.(rootc;digits=2)))"
    ra = CB.restage_all_blocked!(env; resume=true, verbose=true)   # 1차: 막힌 조립물들을 개별적으로 재배치 시도
    @info "[DEMO] restage_all -> $(ra.status) (residual $(get(ra,:residual,-1)))"
    if ra.status == :residual_blocked                              # 개별 재배치로도 여전히 막혀 있으면
        wb = CB.translate_whole_build!(env; resume=true, verbose=true)  # 2차: 빌드 전체를 통째로 평행이동
        @info "[DEMO] translate_whole_build! -> $(wb.status) Δ=$(get(wb,:delta,nothing)) residual=$(get(wb,:residual,-1))"
    elseif ra.status in (:restaged_all, :none)
        @info "[DEMO] zone cleared by per-assembly restage alone ($(ra.status)) -- no whole-build needed"
    end
    return nothing
end

CB.clear_ood_schedule!(); CB.clear_restriction_zones!()   # hygiene (fresh process anyway)
CB.schedule_ood!(OOD_STEP, ood_recover!)   # OOD_STEP 스텝에 ood_recover! 를 발동하도록 예약

pp = CB.get_project_params(PROJECT)
println(">>> VISUAL whole-build demo: project=$(pp[:project_name]) OOD_STEP=$OOD_STEP zone_R=$ZONE_R")
println(">>> building + simulating with FULL NAV + ANIMATION (slow; browser opens at end)...")

# 큰 스택(2GB)에서 시뮬레이션 실행. do 블록 = 이 익명함수를 run_with_stack 의 f 로 넘김.
run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots],
        assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
        log_level=Logging.Info, rvo_flag=true, tangent_bug_flag=true, dispersion_flag=true,
        # --- animation ON ---
        save_animation=true, open_animation_at_end=OPEN_ANIM, update_anim_at_every_step=true,
        anim_active_agents=true, anim_active_areas=true, grid_scale=GRID_SCALE,
        # --- housekeeping ---
        save_animation_along_the_way=false, write_results=false, overwrite_results=true,
        look_for_previous_milp_solution=false, save_milp_solution=false,
        return_env_before_sim=false)
end
println(">>> done. The browser tab shows the animation (press the play arrow, bottom-right).")
end

# =============================================================================
# respec_forbidzone -- VISUAL demo of the FULL ForbidZone respec pipeline, driven
#   through the REAL seam with a deterministic mock LLM (no Anthropic key). At OOD_STEP
#   a central zone + NL string route through /propose -> ForbidZone -> restage/translate.
#   ENV: USE_MOCK, MOCK_PORT, NAVON_PROJECT, OOD_STEP, NAVON_ZONE_R, GRID_SCALE, OPEN_ANIM.
# =============================================================================
# demo_respec_forbidzone : "자연어 사건설명 → LLM → DSL(ForbidZone) → 기하복구" 전체 파이프라인 시각 데모.
#   진짜 LLM 대신 결정적(deterministic) mock 서버를 띄워 API 키 없이도 돌아가게 한다(USE_MOCK=1 기본).
#   중앙에 구역을 놓고 자연어 문장을 발생 → /propose 호출 → ForbidZone → restage/translate 로 복구.
#   ENV: USE_MOCK, MOCK_PORT, NAVON_PROJECT, OOD_STEP, NAVON_ZONE_R, GRID_SCALE, OPEN_ANIM.
function demo_respec_forbidzone()
# USE_MOCK=1 (default): stand up a local deterministic mock /propose (no API key needed).
# USE_MOCK=0: use the REAL Python LLM service at RESPEC_SERVICE_URL (default :8000).
USE_MOCK  = get(ENV, "USE_MOCK", "1") == "1"   # true=가짜 로컬 LLM, false=진짜 파이썬 LLM 서비스 사용
MOCK_PORT = parse(Int, get(ENV, "MOCK_PORT", "8732"))
if USE_MOCK
    ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:$MOCK_PORT"
elseif !haskey(ENV, "RESPEC_SERVICE_URL")
    ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:8000"        # default real-service address
end

PROJECT   = parse(Int, get(ENV, "NAVON_PROJECT", "4"))
OOD_STEP  = parse(Int, get(ENV, "OOD_STEP", "5"))
ZONE_R    = parse(Float64, get(ENV, "NAVON_ZONE_R", "2.5"))
GRID_SCALE = parse(Float64, get(ENV, "GRID_SCALE", "4.0"))
OPEN_ANIM = get(ENV, "OPEN_ANIM", "1") == "1"

_setup_milp!()

# start_mock : 진짜 LLM 흉내내는 가짜 HTTP 서버 실행. /propose 로 온 요청의 zones/nodes 를 보고
#   항상 ForbidZone DSL 을 되돌려준다(결정적 = 매번 같은 답). 진짜 LLM 자리에 끼워 넣는 seam(이음매).
# deterministic mock /propose: grounds a ForbidZone from the request's own zones/nodes
function start_mock(port)
    handler = function (req::HTTP.Request)                 # 요청 하나를 처리하는 익명함수(핸들러)
        path = HTTP.URIs.URI(req.target).path              # 요청 경로(/health, /propose)
        if path == "/health"                               # 헬스체크 = 서버 살아있나 확인용
            return HTTP.Response(200, JSON3.write(Dict("status" => "ok")))
        elseif path == "/propose"                          # 실제 respec 제안 요청
            body  = JSON3.read(String(req.body))            # 요청 JSON 파싱
            zones = haskey(body, "zones") ? body["zones"] : []  # 있으면 zones, 없으면 빈 배열
            nodes = haskey(body, "nodes") ? body["nodes"] : []
            zkey  = isempty(zones) ? "zone" : String(zones[1]["key"])   # 구역 키(첫 zone)
            cov   = isempty(zones) ? [] : zones[1]["covers"]            # 그 구역이 덮는 조립물들
            aid   = !isempty(cov) ? String(first(cov)) : (isempty(nodes) ? "" : String(nodes[1]["id"]))  # 대상 assembly id
            @info "[MOCK-LLM] /propose -> ForbidZone(zone=$zkey, assembly=$aid)"
            return HTTP.Response(200, JSON3.write(Dict(
                "constraints" => [Dict("kind" => "ForbidZone", "zone" => zkey, "assembly" => aid)],
                "rationale" => "mock: spatial no-go zone over the build core")))
        end
        return HTTP.Response(404, "not found")
    end
    return HTTP.serve!(handler, "127.0.0.1", port)
end

# _root_id : staging_circles 중 반지름 최대(=루트 조립물)의 키를 찾는 한 줄 함수.
_root_id(env) = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))

# ood_action! : 시뮬레이션 도중 OOD 발생 시 실행. (1)물리적 금지구역을 실제로 넣고 (2)자연어 문장을 반환.
#   반환된 문자열이 respec 큐로 들어가(push_ood!) LLM 파이프라인을 태운다. 여기가 "사건이 말로 표현되는" 지점.
# OOD action fired inside the sim: inject the physical zone + emit the NL string (-> push_ood!)
function ood_action!(env)
    gs = CB.root_deposit_goals(env)
    zc = isempty(gs) ? Vector{Float64}(CB.get_center(env.staging_circles[_root_id(env)])[1:2]) : sum(gs) ./ length(gs)  # 구역 중심
    CB.add_restriction_zone!(:zone, zc, ZONE_R)   # 실제 통행금지 구역 배치
    @info "[DEMO] OOD @ step $OOD_STEP: zone@$(round.(zc;digits=2)) R=$ZONE_R; emitting NL event"
    return "A safety exclusion zone is now active over the central build area; " *   # * = 문자열 이어붙이기
           "robots must not enter or pass through it."                               # 이 자연어가 LLM 입력이 됨
end

# captured RESPEC pipeline log lines (filled by run_lego_demo via log_sink) -> embedded into the HTML
# _PIPE : respec 파이프라인 로그를 담을 문자열 배열(빈 배열로 시작). run_lego_demo 가 log_sink 로 채운다.
_PIPE = String[]
# _esc : HTML 특수문자(&,<,>) 를 안전하게 escape. 로그를 HTML 에 박아넣기 전 처리.
_esc(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")
# _log_panel : 수집한 로그 줄들을 색깔 입힌 HTML 패널(고정 오버레이)로 만든다. 애니메이션 HTML 위에 얹어 파이프라인을 보여줌.
function _log_panel(lines)
    isempty(lines) && return ""                    # 로그 없으면 빈 문자열
    rows = map(lines) do ln                          # 각 줄을 색칠된 <div> 로 변환(map+do 블록)
        c = occursin("OOD event:", ln) ? "#ffd479" :                                  # NL input (amber)  # 자연어=호박색
            (occursin("LLM proposal", ln) || occursin("MOCK-LLM", ln)) ? "#7ee787" :  # DSL out (green)
            (occursin("WHOLE-BUILD", ln) || occursin("admitted", ln)) ? "#79c0ff" :   # recovery (blue)
            "#d8e0ee"
        "<div style=\"color:$c;margin:2px 0\">$(_esc(ln))</div>"
    end
    return "<div id=\"respec-log\" style=\"position:fixed;top:8px;left:8px;max-width:46vw;max-height:92vh;" *
        "overflow:auto;background:rgba(16,18,26,.86);font:12px/1.5 ui-monospace,Consolas,monospace;" *
        "padding:10px 13px;border-radius:9px;z-index:99999;white-space:pre-wrap;box-shadow:0 3px 16px rgba(0,0,0,.55)\">" *
        "<div style=\"color:#9bd1ff;font-weight:700;margin-bottom:5px\">RESPEC pipeline &nbsp;—&nbsp; " *
        "natural language → DSL → geometric recovery</div>" * join(rows, "") * "</div>"
end

SRV = USE_MOCK ? start_mock(MOCK_PORT) : nothing   # mock 모드면 가짜 서버 실행, 아니면 nothing
CB.RESPEC_ENABLED[] = true                          # respec 파이프라인 켬 ([]=Ref 에 값 쓰기)
CB.clear_ood_schedule!(); CB.clear_restriction_zones!()
CB.schedule_ood!(OOD_STEP, ood_action!)             # OOD_STEP 스텝에 ood_action! 예약

pp = CB.get_project_params(PROJECT)
ready = CB.respec_service_ready()                   # LLM 서비스가 응답 가능한지 확인
println(">>> VISUAL ForbidZone respec demo: project=$(pp[:project_name]) OOD_STEP=$OOD_STEP  mode=$(USE_MOCK ? "MOCK" : "REAL-LLM")")
println(">>> /propose at $(ENV["RESPEC_SERVICE_URL"])  ready=$ready  RESPEC_ENABLED=$(CB.RESPEC_ENABLED[])")
(!USE_MOCK && !ready) && @warn "REAL-LLM mode but service not reachable — start `uvicorn server:app --port 8000` in a shell WITH ANTHROPIC_API_KEY first."
println(">>> building + simulating with FULL NAV + RESPEC SEAM + ANIMATION (slow)...")

# 시뮬레이션 실행. log_sink=_PIPE 로 respec 로그가 _PIPE 배열에 수집됨(나중에 HTML 에 박음).
run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Info,
        rvo_flag=true, tangent_bug_flag=true, dispersion_flag=true,
        save_animation=true, open_animation_at_end=false, update_anim_at_every_step=true,
        anim_active_agents=true, anim_active_areas=true, grid_scale=GRID_SCALE, log_sink=_PIPE,
        save_animation_along_the_way=false, write_results=false, overwrite_results=true,
        look_for_previous_milp_solution=false, save_milp_solution=false, return_env_before_sim=false)
end
try close(SRV) catch end                            # 가짜 서버 닫기(에러나도 무시)
CB.RESPEC_ENABLED[] = false; CB.clear_ood_schedule!(); CB.clear_restriction_zones!()   # 전역 상태 원복

# embed the captured NL->DSL->recovery log INTO the saved HTML (animation + log in ONE file)
# 저장된 애니메이션 HTML 의 </body> 앞에 로그 패널을 끼워넣어 "애니메이션+파이프라인 로그"를 한 파일로 만든다.
htmlpath = joinpath("results", pp[:project_name], "greedy_RVO_Dispersion_TangentBug", "visualization.html")
if isfile(htmlpath) && !isempty(_PIPE)
    html = read(htmlpath, String)
    panel = _log_panel(_PIPE)
    html = occursin("</body>", html) ? replace(html, "</body>" => panel * "\n</body>"; count = 1) : html * panel  # </body> 앞 삽입
    write(htmlpath, html)
    println(">>> embedded $(length(_PIPE)) RESPEC pipeline log lines into the HTML.")
else
    println(">>> WARNING: no RESPEC log captured to embed (_PIPE empty).")
end
println(">>> done. Open (animation + RESPEC log in ONE file): $htmlpath")
# OPEN_ANIM 이 참이고 파일 있으면 브라우저로 자동 열기(윈도우 start 명령). 실패해도 경고만.
OPEN_ANIM && isfile(htmlpath) && (try run(`cmd /c start "" $(abspath(htmlpath))`) catch e; @warn "auto-open failed; open it manually: $e" end)
end   # demo_respec_forbidzone 끝

# =============================================================================
# respec_replace -- VISUAL demo of the FULL OOD 1-1 ReplaceAgent respec pipeline
#   (robot breakdown -> spare hand-off) via the REAL seam with a mock LLM. 4 directional
#   spare pools; at OOD a clean solo transporter is faulted -> ReplaceAgent -> nearest spare.
#   ENV: USE_MOCK, MOCK_PORT, NAVON_PROJECT, OOD_STEP, FAULT_CLOSED, NSPARE, GRID_SCALE,
#        OPEN_ANIM, HOT_SWAP, TARGET_ROBOT, FAULT_TARGET, SAVE_ANIM, REFORM_INTERVAL, NOPROG.
# =============================================================================
# demo_respec_replace : OOD 1-1 "로봇 고장 → 예비 로봇으로 교체(ReplaceAgent)" 파이프라인 시각 데모.
#   방위별(N/S/E/W) 예비 로봇 풀을 두고, 혼자 부품 나르던 로봇(solo transporter)을 고장내면
#   자연어 사건 → mock LLM → ReplaceAgent → 가장 가까운 예비 로봇이 인계받는다.
#   "solo(팀크기1)" 로봇만 골라 고장내는 이유: 다른 로봇이 그 로봇을 기다리지 않아 깔끔히 완주 가능(MVP).
#   ENV: USE_MOCK, MOCK_PORT, NAVON_PROJECT, OOD_STEP, FAULT_CLOSED, NSPARE, GRID_SCALE, OPEN_ANIM,
#        HOT_SWAP, TARGET_ROBOT, FAULT_TARGET, SAVE_ANIM, REFORM_INTERVAL, NOPROG.
function demo_respec_replace()
USE_MOCK  = get(ENV, "USE_MOCK", "1") == "1"
MOCK_PORT = parse(Int, get(ENV, "MOCK_PORT", "8734"))
if USE_MOCK
    ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:$MOCK_PORT"
elseif !haskey(ENV, "RESPEC_SERVICE_URL")
    ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:8000"
end

PROJECT    = parse(Int, get(ENV, "NAVON_PROJECT", "4"))
OOD_STEP     = parse(Int, get(ENV, "OOD_STEP", "20"))     # fault at sim-step (used if FAULT_CLOSED=0)  # 몇 번째 스텝에 고장
FAULT_CLOSED = parse(Int, get(ENV, "FAULT_CLOSED", "0"))  # >0: fault when this many nodes CLOSED (build-progress; reproducible)  # 완료노드 수 기준(재현성↑)
NSPARE     = parse(Int, get(ENV, "NSPARE", "2"))          # 방위별 예비 로봇 수(총 4×NSPARE)
GRID_SCALE = parse(Float64, get(ENV, "GRID_SCALE", "4.0"))
OPEN_ANIM  = get(ENV, "OPEN_ANIM", "1") == "1"
SOLO_TARGET = get(ENV, "SOLO_TARGET", "1") == "1"   # fault a solo-transport robot (MVP-clean completion)

_setup_milp!()

# start_mock : 가짜 LLM. 요청의 자연어(event)+로봇목록(agents)을 보고 DSL 을 되돌려준다.
#   "교착/멈춤" 문구면 ReformTeam(팀 재구성), 아니면 ReplaceAgent(교체) 를 낸다.
# deterministic mock /propose: grounds a ReplaceAgent from the request's NL + agents.
function start_mock(port)
    handler = function (req::HTTP.Request)
        path = HTTP.URIs.URI(req.target).path
        if path == "/health"
            return HTTP.Response(200, JSON3.write(Dict("status" => "ok")))
        elseif path == "/propose"
            body   = JSON3.read(String(req.body))
            event  = haskey(body, "event") ? String(body["event"]) : ""      # 자연어 사건설명
            agents = haskey(body, "agents") ? body["agents"] : []            # 현재 로봇 목록
            # a "team is deadlocked / stuck forming" event -> ReformTeam (no fields).
            # r"..."a = 정규식(regex). (?i)=대소문자무시. 교착 관련 단어가 있으면 ReformTeam 반환.
            if occursin(r"(?i)deadlock|stuck|stall|cannot complete|re-establish|reform"a, event)
                @info "[MOCK-LLM] /propose -> ReformTeam()"
                return HTTP.Response(200, JSON3.write(Dict(
                    "constraints" => [Dict("kind" => "ReformTeam")],
                    "rationale" => "mock: transport team deadlocked -> re-establish the stuck team")))
            end
            m = match(r"R(\d+)", event); aid = ""      # 사건 문구에서 "R숫자"(로봇 번호)를 뽑음
            if m !== nothing
                want = "($(m.captures[1]))"             # 잡은 번호로 "(번호)" 패턴 만들어
                for a in agents; occursin(want, String(a["id"])) && (aid = String(a["id"]); break); end  # 일치하는 로봇 id 찾기
            end
            aid == "" && !isempty(agents) && (aid = String(agents[1]["id"]))  # 못 찾으면 첫 로봇으로 대체
            @info "[MOCK-LLM] /propose -> ReplaceAgent(agent=$aid)"
            return HTTP.Response(200, JSON3.write(Dict(
                "constraints" => [Dict("kind" => "ReplaceAgent", "agent" => aid, "after" => 0.0)],
                "rationale" => "mock: robot breakdown -> replace with nearest spare")))
        end
        return HTTP.Response(404, "not found")
    end
    return HTTP.serve!(handler, "127.0.0.1", port)
end

# _solo_fault_target : 고장내기 "안전한" 로봇을 고른다 — 남은 운반 작업이 전부 solo(팀 크기 1)인 로봇.
#   그래야 그 로봇을 대신 교체해도 다른 로봇이 공동운반을 기다리다 막히는 일이 없다. 없으면 nothing.
# pick a robot whose remaining transport tasks are ALL solo (team size 1): the MVP-clean
# fault case (no other robot waits for it as a co-carrier). nothing if none.
function _solo_fault_target(env)
    sched = env.sched                                # 스케줄(작업 의존 그래프)
    # team_sizes(rid) : rid 가 속한, 아직 안 끝난 FormTransportUnit(운반팀) 노드들의 팀 크기 목록(컴프리헨션).
    team_sizes(rid) = [length(CB.robot_team(CB.entity(CB.get_node_from_id(sched, CB.get_vtx_id(sched, v)))))
        for v in Graphs.vertices(sched)
        if !(v in env.cache.closed_set) &&           # 이미 완료된 노드 제외
           CB.get_node_from_id(sched, CB.get_vtx_id(sched, v)) isa CB.FormTransportUnit &&  # 운반팀 노드만
           (try haskey(CB.robot_team(CB.entity(CB.get_node_from_id(sched, CB.get_vtx_id(sched, v)))), rid) catch; false end)]  # rid 포함 팀만
    cands = CB.RobotID[]                              # 후보 로봇들(빈 배열, 원소타입 RobotID)
    for v in env.cache.active_set                     # 지금 활동 중인 노드들을 순회
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.RobotGo || continue                  # 로봇 이동 노드가 아니면 건너뜀(|| continue = 관용구)
        rid = try CB.entity(n).id catch; nothing end  # 그 노드의 로봇 id (실패 시 nothing)
        rid isa CB.RobotID || continue
        CB._first_pending_assignment(env, rid) === nothing && continue  # 남은 배정 작업 없으면 제외
        s = team_sizes(rid)
        (!isempty(s) && all(==(1), s)) && push!(cands, rid)   # 남은 작업이 모두 팀크기 1이면 후보에 추가
    end
    isempty(cands) && return nothing
    return sort(cands, by = r -> r.id)[1]            # DETERMINISTIC (lowest id), matches the verified test  # id 최소=결정적
end

# _solo_ftu_fault_target : "지금 실제로 부품 하나를 혼자 나르고 있는" 로봇을 찾는다(활동 중 FormTransportUnit 의 팀크기=1).
#   위 _solo_fault_target 은 "앞으로 남은 작업" 기준, 이건 "현재 실행 상태" 기준의 대체 타겟.
# A robot CURRENTLY carrying one part ALONE: an active FormTransportUnit whose team is size 1.
function _solo_ftu_fault_target(env)
    for v in env.cache.active_set
        m = CB.get_node_from_id(env.sched, CB.get_vtx_id(env.sched, v))
        m isa CB.FormTransportUnit || continue
        tm = try CB.robot_team(CB.entity(m)) catch; nothing end
        (tm === nothing || length(tm) != 1) && continue
        rid = try first(keys(tm)) catch; nothing end
        rid isa CB.RobotID && return rid
    end
    return nothing
end

# _single_solo_fault_target : 완주를 "보장"하는 가장 엄격한 타겟 — 남은 운반공급 RobotGo 슬롯이 정확히 1개이고
#   그 작업이 solo(팀크기 1)인 로봇. 교체 시 예비 로봇이 딱 하나의 깔끔한 작업만 물려받으므로 안전.
# STRICTER target for GUARANTEED completion: a robot with EXACTLY ONE remaining (non-closed)
# transport-feeding RobotGo slot, and that task is SOLO (team size 1).
function _single_solo_fault_target(env)
    sched = env.sched
    cands = CB.RobotID[]
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.RobotGo || continue
        rid = try CB.entity(n).id catch; nothing end
        rid isa CB.RobotID || continue
        CB._first_pending_assignment(env, rid) === nothing && continue
        n_slots = 0; all_solo = true
        for w in Graphs.vertices(sched)
            w in env.cache.closed_set && continue
            m = CB.get_node_from_id(sched, CB.get_vtx_id(sched, w))
            m isa CB.RobotGo || continue
            (try CB.entity(m).id == rid catch; false end) || continue
            outs = Graphs.outneighbors(sched, w); isempty(outs) && continue
            fn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, outs[1]))
            fn isa CB.FormTransportUnit || continue
            n_slots += 1
            (try length(CB.robot_team(CB.entity(fn))) == 1 catch; false end) || (all_solo = false)
        end
        (n_slots == 1 && all_solo) && push!(cands, rid)
    end
    isempty(cands) && return nothing
    return sort(cands, by = r -> r.id)[1]            # DETERMINISTIC (lowest id)
end

TARGET_ROBOT = parse(Int, get(ENV, "TARGET_ROBOT", "0"))   # >0: fault this exact robot id (else solo-pick)  # 0=자동선택
# _robot_by_id : 특정 번호(rid)의 활동 중 로봇을 찾는다(검증된 시나리오 재현용).
# find the active robot with a specific id (to reproduce a verified scenario)
function _robot_by_id(env, rid::Int)
    for v in env.cache.active_set
        n = CB.get_node_from_id(env.sched, CB.get_vtx_id(env.sched, v))
        n isa CB.RobotGo || continue
        r = try CB.entity(n).id catch; nothing end
        (r isa CB.RobotID && r.id == rid) && return r
    end
    return nothing
end

# OOD action fired inside the sim: fault EXACTLY ONE robot + emit the NL string (-> push_ood!).
# _FAULTED_ONCE : "이미 한 번 고장냈나" 표시 상자. 데모 전체에서 고장은 딱 한 번만.
_FAULTED_ONCE = Ref(false)
# ood_action! : OOD 시점에 로봇 딱 하나를 고장내고 자연어 문장을 반환(→respec 큐). 안전한 solo 타겟이 없으면 nothing(다음 스텝 재시도).
function ood_action!(env)
    _FAULTED_ONCE[] && return nothing                        # only one fault for the whole demo  # 이미 고장냈으면 종료
    if get(ENV, "FAULT_DIAG", "0") == "1"                    # TEMP diagnostic: why does the fault defer?  # 진단로그(왜 고장이 미뤄지나)
        nclosed = length(env.cache.closed_set)
        nrg = 0; npend = 0; nsolo = 0
        for v in env.cache.active_set
            n = CB.get_node_from_id(env.sched, CB.get_vtx_id(env.sched, v))
            n isa CB.RobotGo || continue
            nrg += 1
            rid = try CB.entity(n).id catch; nothing end
            rid isa CB.RobotID || continue
            CB._first_pending_assignment(env, rid) === nothing && continue
            npend += 1
        end
        st = _solo_fault_target(env); nsolo = st === nothing ? 0 : 1
        # ALSO count solo FormTransportUnit teams (a robot carrying ONE part alone) regardless of pending
        soloftu = String[]
        for v in env.cache.active_set
            m = CB.get_node_from_id(env.sched, CB.get_vtx_id(env.sched, v))
            m isa CB.FormTransportUnit || continue
            tm = try CB.robot_team(CB.entity(m)) catch; nothing end
            tm === nothing && continue
            if length(tm) == 1
                rid = try first(keys(tm)) catch; nothing end
                rid === nothing || push!(soloftu, string(rid))
            end
        end
        @info "[FAULT_DIAG] closed=$nclosed activeRobotGo=$nrg withPending=$npend soloTarget=$(st===nothing ? "none" : "R$(st.id)") soloFTU=$(length(soloftu))$(isempty(soloftu) ? "" : "["*join(soloftu,",")*"]")"
    end
    # Target preference (most completion-safe first):
    #   1. _single_solo_fault_target: EXACTLY ONE remaining solo task -> spare inherits a single clean task.
    #   2. _solo_fault_target: any solo-team RobotGo with a pending assignment (classic clean case).
    #   3. _solo_ftu_fault_target: a robot currently carrying a part ALONE (detected by execution state).
    # FAULT_TARGET=single|solo|ftu pins one picker (for A/B testing completion).
    pick = get(ENV, "FAULT_TARGET", "auto")                  # 타겟 선택 방식(ENV 로 고정 가능): single|solo|ftu|auto
    # tgt = if...elseif...end : Julia 에선 if 도 값을 반환하는 식(expression). 아래 결과가 tgt 에 담김.
    tgt = if TARGET_ROBOT > 0
        _robot_by_id(env, TARGET_ROBOT)
    elseif pick == "single"
        _single_solo_fault_target(env)                       # STRICT: only the completion-guaranteed target  # 완주보장 타겟만
    elseif pick == "solo"
        _solo_fault_target(env)
    elseif pick == "ftu"
        _solo_ftu_fault_target(env)
    else                                                     # "auto": try strictest first, then fall back  # 엄격→느슨 순서로 시도
        t = _single_solo_fault_target(env)
        t === nothing && (t = _solo_fault_target(env))       # 없으면 다음 방법으로 폴백
        t === nothing && (t = _solo_ftu_fault_target(env))
        t
    end
    tgt === nothing && return nothing                        # no safe solo target this step -> defer/retry  # 안전 타겟 없으면 미룸
    # obstacle=false: no no-go zone on the dead robot. clear=false: KEEP the broken robot visible (RED).
    # obstacle=false: 죽은 로봇 자리에 금지구역 안 만듦. clear=false: 고장난 로봇을 화면에 빨간색으로 남겨둠.
    nl = CB.fault_robot!(env; target = tgt, obstacle = false, clear = false)   # 실제로 로봇 고장 처리 + 자연어 문장 반환
    nl === nothing && return nothing
    _FAULTED_ONCE[] = true                                    # 고장 완료 표시(다시 안 함)
    @info "[DEMO] OOD: faulted R$(tgt.id) (solo transporter); marked it RED (faulted); emitting NL event"
    return nl
end

# captured RESPEC pipeline log lines -> embedded into the HTML
# _PIPE/_esc/_log_panel : respec_forbidzone 것과 같은 역할(로그수집/HTML escape/색깔 로그 패널).
#   여기 _log_panel 은 "같은 줄 반복은 ×N 배지로 접어서" 보여주는 점만 다르다(접힘/펼침 헤더 포함).
_PIPE = String[]
_esc(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")
function _log_panel(lines)
    isempty(lines) && return ""
    # Collapse repeats while keeping first-occurrence order.
    # 첫 등장 순서(order)는 유지하면서 각 줄의 등장 횟수(counts)를 세어 중복을 접는다.
    order = String[]; counts = Dict{String,Int}()
    for ln in lines
        haskey(counts, ln) || push!(order, ln)       # 처음 보는 줄이면 순서 목록에 추가
        counts[ln] = get(counts, ln, 0) + 1          # 횟수 +1
    end
    rows = map(order) do ln
        c = occursin("OOD event:", ln) ? "#ffd479" :                                  # NL input (amber)
            (occursin("LLM proposal", ln) || occursin("MOCK-LLM", ln)) ? "#7ee787" :  # DSL out (green)
            (occursin("ADMITTED", ln) || occursin("replace", ln) || occursin("spare", ln)) ? "#79c0ff" :  # recovery (blue)
            (occursin("declined", ln) || occursin("REJECTED", ln) || occursin("FALLBACK", ln)) ? "#ff9b9b" : # declined (red)
            "#d8e0ee"
        n = counts[ln]
        badge = n > 1 ? " <span style=\"opacity:.55\">×$n</span>" : ""
        "<div style=\"color:$c;margin:2px 0\">$(_esc(ln))$badge</div>"
    end
    return "<div id=\"respec-log\" style=\"position:fixed;top:10px;left:10px;width:340px;max-height:42vh;" *
        "overflow:auto;background:rgba(16,18,26,.82);font:11px/1.45 ui-monospace,Consolas,monospace;" *
        "border-radius:9px;z-index:99999;white-space:pre-wrap;box-shadow:0 3px 16px rgba(0,0,0,.55)\">" *
        "<div onclick=\"var b=document.getElementById('respec-body');" *
        "b.style.display=(b.style.display=='none'?'block':'none');\" " *
        "style=\"color:#9bd1ff;font-weight:700;padding:8px 11px;cursor:pointer;position:sticky;top:0;" *
        "background:rgba(16,18,26,.96);border-radius:9px 9px 0 0;user-select:none\">" *
        "RESPEC pipeline (OOD 1-1) <span style=\"opacity:.55;font-weight:400\">— click to hide ▾</span></div>" *
        "<div id=\"respec-body\" style=\"padding:6px 11px 9px\">" * join(rows, "") * "</div></div>"
end

SRV = USE_MOCK ? start_mock(MOCK_PORT) : nothing
CB.RESPEC_ENABLED[] = true
# 여러 전역 상태를 한꺼번에 청소(예비풀/고장로봇/복구예비/wedge 등) — 이전 실행의 찌꺼기 제거.
CB.clear_ood_schedule!(); CB.clear_restriction_zones!(); CB.clear_spare_pools!(); CB.clear_faulted_robots!()
CB.clear_recovery_spares!(); CB.clear_wedge_edges!()
# HOT_SWAP=1: enact ReplaceAgent as an IDENTITY-PRESERVING scene-tree hot-swap (keep the faulted
# RobotID, swap only its physical body from the depot) instead of the schedule-restamping replace.
# HOT_SWAP=1: 로봇 id 는 그대로 두고 "몸체만" 창고에서 갈아끼우는 정체성보존 교체(스케줄 재작성 없이 깔끔).
if get(ENV, "HOT_SWAP", "0") == "1"
    CB.set_hot_swap!(enabled = true, mode = Symbol(get(ENV, "HOT_SWAP_MODE", "via_depot")))   # Symbol(...) = 문자열→심볼
    println(">>> HOT_SWAP ON (mode=$(CB.HOT_SWAP_MODE[])): ReplaceAgent -> identity-preserving depot swap (no schedule re-stamp).")
else
    CB.set_hot_swap!(enabled = false)
end
try; CB.set_reform_interval!(parse(Int, get(ENV, "REFORM_INTERVAL", "120"))); catch; end   # 팀 재구성 점검 간격
# Fire the fault at a build-PROGRESS point (reproducible) where a clean solo transporter exists.
# 고장 시점 예약: FAULT_CLOSED>0 이면 "완료노드 수" 기준(재현성 좋음), 아니면 여러 스텝에 걸쳐 반복 예약(처음 안전할 때 발동).
if FAULT_CLOSED > 0
    CB.schedule_ood_at_closed!(FAULT_CLOSED, ood_action!)   # 완료노드가 FAULT_CLOSED 개일 때 발동
else
    # start:step:stop 범위(FAULT_STEP0 부터 FAULT_STEP1 까지 FAULT_STEPD 간격)마다 예약 — solo 타겟 생길 때까지 재시도.
    for s in (parse(Int, get(ENV, "FAULT_STEP0", "8"))):(parse(Int, get(ENV, "FAULT_STEPD", "1"))):(parse(Int, get(ENV, "FAULT_STEP1", "150")))
        CB.schedule_ood!(s, ood_action!)
    end
end

pp = CB.get_project_params(PROJECT)
# LLM 서비스가 준비될 때까지 최대 3초(0.1초×30) 폴링. `for _ in` 의 _ = 안 쓰는 변수 관례.
_rdy = Ref(false)
for _ in 1:30
    if CB.respec_service_ready(); _rdy[] = true; break; end
    sleep(0.1)
end
ready = _rdy[]
println(">>> VISUAL ReplaceAgent respec demo: project=$(pp[:project_name]) OOD_STEP=$OOD_STEP spares=$(4*NSPARE)  mode=$(USE_MOCK ? "MOCK" : "REAL-LLM")")
println(">>> /propose at $(ENV["RESPEC_SERVICE_URL"])  ready=$ready  RESPEC_ENABLED=$(CB.RESPEC_ENABLED[])")
(!USE_MOCK && !ready) && @warn "REAL-LLM mode but service not reachable — start `uvicorn server:app --port 8000` in a shell WITH ANTHROPIC_API_KEY first."
println(">>> building + simulating with FULL NAV + SPARE POOLS + RESPEC SEAM + ANIMATION (slow)...")

SAVE_ANIM = get(ENV, "SAVE_ANIM", "1") == "1"   # 0 = fast verification run (no animation recording)  # 0이면 애니메이션 없이 빠른 검증
run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Info,
        max_num_iters_no_progress=parse(Int, get(ENV, "NOPROG", "30000")),   # 진전없이 이 스텝수 넘으면 중단
        rvo_flag=true, tangent_bug_flag=true, dispersion_flag=true, n_spare_per_pool=NSPARE,   # n_spare_per_pool=풀당 예비 수
        save_animation=SAVE_ANIM, open_animation_at_end=false, update_anim_at_every_step=SAVE_ANIM,
        anim_active_agents=true, anim_active_areas=true, grid_scale=GRID_SCALE, log_sink=_PIPE,
        save_animation_along_the_way=false, write_results=false, overwrite_results=true,
        look_for_previous_milp_solution=false, save_milp_solution=false, return_env_before_sim=false)
end
try close(SRV) catch end
CB.RESPEC_ENABLED[] = false; CB.clear_ood_schedule!(); CB.clear_restriction_zones!()
CB.clear_spare_pools!(); CB.clear_faulted_robots!()

htmlpath = joinpath("results", pp[:project_name], "greedy_RVO_Dispersion_TangentBug", "visualization.html")
if isfile(htmlpath) && !isempty(_PIPE)
    html = read(htmlpath, String)
    panel = _log_panel(_PIPE)
    html = occursin("</body>", html) ? replace(html, "</body>" => panel * "\n</body>"; count = 1) : html * panel
    write(htmlpath, html)
    println(">>> embedded $(length(_PIPE)) RESPEC pipeline log lines into the HTML.")
else
    println(">>> WARNING: no RESPEC log captured to embed (_PIPE empty).")
end
println(">>> done. Open (animation + RESPEC log in ONE file): $htmlpath")
OPEN_ANIM && isfile(htmlpath) && (try run(`cmd /c start "" $(abspath(htmlpath))`) catch e; @warn "auto-open failed; open it manually: $e" end)  # 브라우저 자동열기
end   # demo_respec_replace 끝

# =============================================================================
# surrogate -- VISUAL demo of the LEARNED SURROGATE WORLD MODEL deciding the OOD response
#   (visual counterpart of E1/E2). At each OOD event the surrogate SCORES every candidate DSL
#   macro in imagination (predicted `closed` nodes), ranks them, and enacts the argmax -- 0 true
#   planner calls. Uses the LINEAR export (surrogate_linear.json); errors on a forest export.
#   NOTE: this demo keeps its OWN MILP block (60s/0.05 gap/output_flag) -- different from the
#   shared _setup_milp!. ENV: DEMO_OOD (fault|zone), NSPARE, GRID_SCALE, OPEN_ANIM, SAVE_ANIM,
#   SEED, SEVERITY, SURROGATE.
# =============================================================================
# demo_surrogate : "학습된 surrogate(가벼운 세계모델)"가 OOD 대응을 결정하는 시각 데모(E1/E2의 시각 버전).
#   사건마다 5개 DSL 매크로 각각을 "상상"으로 채점(재계획 없이 예상 closed 노드 수 예측)→ 랭킹→ 최고를 실행.
#   즉 진짜 플래너 호출 0번으로 결정. 선형(linear) surrogate export 만 읽는다(forest면 에러→surrogate_stream 사용).
#   ENV: DEMO_OOD(fault|zone), NSPARE, GRID_SCALE, OPEN_ANIM, SAVE_ANIM, SEED, SEVERITY, SURROGATE.
function demo_surrogate()
_EXAMPLES = joinpath(dirname(pkgdir(CB)), "decpomdp", "examples")
# navigator.jl + decpomdp examples are now loaded ONCE at module top (world-age).

DEMO_OOD   = Symbol(get(ENV, "DEMO_OOD", "fault"))    # :fault | :zone   # 사건 종류(고장 or 구역), Symbol 로 저장
NSPARE     = parse(Int, get(ENV, "NSPARE", "3"))
GRID_SCALE = parse(Float64, get(ENV, "GRID_SCALE", "4.0"))
OPEN_ANIM  = get(ENV, "OPEN_ANIM", "1") == "1"
SAVE_ANIM  = get(ENV, "SAVE_ANIM", "1") == "1"
SEED       = parse(Int, get(ENV, "SEED", "1"))
SEVERITY   = parse(Float64, get(ENV, "SEVERITY", "1.0"))   # zone: overlap frac; fault: 1.0  # 사건 심각도(구역=겹침비율)
SURRO_PATH = get(ENV, "SURROGATE",                          # 학습된 surrogate JSON 파일 경로
    joinpath(pkgdir(CB), "wm4spacecraft_manufacturing", "surrogate_linear.json"))   # wm4 는 2026-07-31 부터 repo 내부
MACROS = [0, 1, 2, 3, 4]                                    # 가능한 대응 매크로 번호 5개
MACRO_NAME = Dict(0=>"NOOP", 1=>"Replace", 2=>"Deprioritize", 3=>"ForbidZone", 4=>"ReformTeam")  # 번호→이름 매핑

# NOTE: surrogate demos use a DIFFERENT MILP config than _setup_milp! (kept verbatim).
CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 60.0, "mip_rel_gap" => 0.05,
    "output_flag" => false, "presolve" => "on")

# ---- the learned surrogate: y_hat = coef . ((x - mean)/scale) + intercept ----------------
# surrogate = 선형회귀. 입력 x 를 (평균빼고 스케일나눠) 정규화한 뒤 계수와 내적 + 절편 = 예측값(예상 closed 노드).
SURRO = JSON3.read(read(SURRO_PATH, String))            # JSON 파일 읽어 파싱
# This (superseded) demo only knows the LINEAR export with the original 19 columns.
# 이 데모는 (구버전이라) 원본 19열짜리 "선형" export 만 안다. forest 이거나 상호작용 열(__x__)이 있으면 에러.
if get(SURRO, "kind", "linear") == "forest" || any(occursin("__x__", String(f)) for f in SURRO["feature_names"])
    error("""demo_surrogate is SUPERSEDED and cannot read this surrogate ($(SURRO["meta"]["model"])).
             Use the surrogate_stream demo, or export a linear one:
               python export_surrogate.py <dataset>.jsonl --cost-aware --linear""")
end
FEATNAMES = String.(SURRO["feature_names"])            # 특징(feature) 이름들 — 학습 때의 열 순서와 정확히 맞춰야 함
println(">>> surrogate loaded: $(length(FEATNAMES)) features, trained on $(SURRO["meta"]["n_instances"]) " *
        "instances, LOO decision-regret=$(SURRO["meta"]["loo_decision_regret"])")

# surrogate_predict : 특징벡터 x 를 받아 선형모델로 예측값 하나 반환. Float64. = 한줄함수를 begin...end 로 씀.
surrogate_predict(x::Vector{Float64}) = begin
    m = Float64.(SURRO["mean"]); s = Float64.(SURRO["scale"]); c = Float64.(SURRO["coef"])  # 평균/스케일/계수. `.()`=원소별 변환
    z = (x .- m) ./ ifelse.(s .== 0.0, 1.0, s)          # 표준화(스케일 0이면 1로 나눠 0나눗셈 회피). ifelse.=원소별 조건
    LinearAlgebra.dot(c, z) + Float64(SURRO["intercept"])   # 계수·표준화입력 내적 + 절편
end

# count the agent's PENDING transport tasks (the consequence proxy the dataset used)
# agent_pending_tasks : 특정 로봇(agent)의 "아직 안 끝난 운반작업 수"를 센다(데이터셋이 쓴 결과 근사값).
function agent_pending_tasks(env, agent)
    agent === nothing && return -1.0
    sched = env.sched; n = 0
    for v in Graphs.vertices(sched)
        node = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        (node isa CB.RobotGo && CB.bound_to_agent(node, agent)) || continue
        v in env.cache.closed_set && continue
        outs = Graphs.outneighbors(sched, v); isempty(outs) && continue
        CB.get_node_from_id(sched, CB.get_vtx_id(sched, outs[1])) isa CB.FormTransportUnit || continue
        n += 1
    end
    return Float64(n)
end

# Build the SAME 19-d feature row the surrogate was trained on (e1_analyze.featurize order).
# features : surrogate 학습 때와 "똑같은 순서/구성"의 19차원 특징벡터를 만든다.
#   현재 상황(사건종류·진행도·예비수·심각도 등) + 후보 매크로(macro_id) 를 원-핫으로 인코딩해 한 행 생성.
function features(env, ctx, macro_id::Int)
    closed = length(env.cache.closed_set)               # 완료된 노드 수
    total  = length(CB.get_nodes(env.sched))            # 전체 노드 수
    valid  = valid_actions(ctx)                         # 지금 유효한(가능한) 액션 목록
    zrad = ctx.type === :zone ?
        (try Float64(CB.get_radius(CB.RESTRICTION_ZONES[][ctx.zone])) catch; -1.0 end) : -1.0
    d = Dict{String,Float64}(
        "kind_fault"     => ctx.type === :fault   ? 1.0 : 0.0,
        "kind_battery"   => ctx.type === :battery ? 1.0 : 0.0,
        "kind_zone"      => 0.0,
        "kind_zoneblk"   => ctx.type === :zone    ? 1.0 : 0.0,
        "severity"       => SEVERITY,
        "n_spare_cfg"    => Float64(NSPARE),
        "spare_count"    => Float64(try length(CB.active_spares()) catch; 0 end),
        "progress"       => total > 0 ? closed / total : 0.0,
        "agent_pending"  => agent_pending_tasks(env, ctx.agent),
        "closed_at_fire" => Float64(closed),
        "n_active"       => Float64(length(env.cache.active_set)),
        "soc"            => ctx.type === :battery ? Float64(ctx.soc) : -1.0,
        "zone_radius"    => zrad,
        "macro_in_valid" => (macro_id in valid) ? 1.0 : 0.0,
    )
    for m in MACROS; d["macro_$(m)"] = (m == macro_id) ? 1.0 : 0.0; end   # 후보 매크로 원-핫(macro_id 만 1.0)
    return [d[f] for f in FEATNAMES]          # exact training column order  # 학습 열 순서대로 값 뽑아 벡터화
end

_PIPE = String[]                              # 로그 수집 배열
_say(s) = (push!(_PIPE, s); @info s)          # _say: 화면 로그(@info)+수집을 동시에. 괄호식은 마지막 값 반환

# ---- THE PRODUCER: score every macro in imagination, enact the argmax --------------------
# surrogate_producer : 이 데모의 핵심 결정자. 사건이 오면 5개 매크로 각각을 surrogate 로 채점(상상)→최고 선택→실행.
#   fault/battery/zone 이 아닌 배경 사건(reform 등)은 그냥 정해진(canonical) 대응을 낸다.
function surrogate_producer(env, event)
    ctx = event_context(env, event)
    if !(ctx.type in (:fault, :battery, :zone))
        return action_to_proposal(ctx, canonical_action(ctx))     # reform etc: canonical background  # 그 외 사건=기본대응
    end
    scores = Dict(m => surrogate_predict(features(env, ctx, m)) for m in MACROS)  # 매크로별 예측점수(딕셔너리 컴프리헨션)
    best = argmax(m -> scores[m], MACROS)                          # 점수 최대인 매크로 = 선택
    ranked = sort(MACROS, by = m -> -scores[m])                    # 점수 내림차순 정렬(-붙여서)
    _say("[SURROGATE] OOD=$(ctx.type) — imagined outcome (predicted closed nodes), NO planner call:")
    for m in ranked
        mark = m == best ? "  <= CHOSEN" : ""                      # 선택된 것 표시
        _say(@sprintf("           %-13s %7.1f%s", MACRO_NAME[m], scores[m], mark))  # 이름/점수 형식맞춰 출력
    end
    _say("[SURROGATE] enacting $(MACRO_NAME[best]) — decided in imagination (0 true-planner calls)")
    return action_to_proposal(ctx, best)                          # 선택 매크로를 실제 제안으로 변환해 반환
end

# ---- OOD injection: a robot breakdown, or a CONSEQUENTIAL blocking zone ------------------
# place_blocking_zone! : "결과에 실제로 영향 주는" 통행금지 구역을 놓는다 — 아직 안 놓인 어떤 조립물의
#   staging 원 위에 겹치게 배치하고, 상황을 설명하는 자연어 문장을 반환(정답기록 record_ood_truth! 도 함께).
function place_blocking_zone!(env; key::Symbol = :zoneblk, frac::Float64 = 0.9)
    isempty(env.staging_circles) && return nothing
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))  # 루트 조립물
    for (aid, ball) in env.staging_circles                # (조립물id, 원) 쌍을 순회
        aid == root && continue                           # 루트(전체)는 건드리지 않음
        ac = try CB._assembly_complete_node(env, aid) catch; nothing end
        ac === nothing && continue
        v = try CB.get_vtx(env.sched, CB.node_id(ac)) catch; nothing end
        v === nothing && continue
        (v in env.cache.closed_set || v in env.cache.active_set) && continue
        c = Vector{Float64}(CB.get_center(ball)[1:2]); r = Float64(CB.get_radius(ball))
        z = CB.add_restriction_zone!(key, c, r * frac)
        nl = "A no-go exclusion zone has appeared at ($(round(c[1];digits=2)), $(round(c[2];digits=2))) " *
             "blocking a staging area; restage the affected assembly out of the restricted region."
        try CB.record_ood_truth!(nl, CB.ZoneTruth(key, Float64[c[1], c[2]], Float64(CB.get_radius(z)), aid)) catch end
        return nl
    end
    return nothing
end

# schedule_ood! : 선택한 종류(zone 또는 fault)의 OOD 를 여러 진행지점에 "한 번만" 발동되게 예약.
#   fired 상자로 이미 발동했는지 추적(클로저가 이 값을 공유). e -> ... 는 사건마다 호출되는 액션함수.
function schedule_ood!()
    fired = Ref(false)                                    # "이미 발동됨" 플래그
    if DEMO_OOD === :zone
        act = e -> fired[] ? nothing :                    # 이미 발동했으면 아무것도 안 함
            (nl = place_blocking_zone!(e; frac = SEVERITY); nl === nothing ? nothing : (fired[] = true; nl))
        for c in (8, 14, 20, 28); CB.schedule_ood_at_closed!(c, act); end   # 완료노드 8/14/20/28 개 시점에 시도
    else
        tf = CB.fault_action(; safe = true, obstacle = false, clear = true) # 안전한 로봇 고장 액션 생성
        act = e -> fired[] ? nothing : (nl = tf(e); nl === nothing ? nothing : (fired[] = true; nl))
        for c in (12, 20, 30, 45, 60); CB.schedule_ood_at_closed!(c, act); end
    end
end

# _esc/_log_panel : 다른 데모와 같은 역할(HTML escape + 색깔 로그 패널). 여기선 surrogate 의 상상/채점 줄을 강조.
_esc(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")
function _log_panel(lines)
    isempty(lines) && return ""
    order = String[]; counts = Dict{String,Int}()          # 중복 접기용(순서 유지 + 횟수 세기)
    for ln in lines
        haskey(counts, ln) || push!(order, ln)
        counts[ln] = get(counts, ln, 0) + 1
    end
    rows = map(order) do ln
        c = occursin("SURROGATE] OOD", ln) ? "#ffd479" :   # 색 결정: 사건줄=호박, 선택/실행=초록 등
            occursin("CHOSEN", ln) || occursin("enacting", ln) ? "#7ee787" :
            occursin("[SURROGATE]", ln) ? "#c9d1d9" :
            (occursin("ADMITTED", ln) || occursin("replace", ln) || occursin("spare", ln) ||
             occursin("restage", ln)) ? "#79c0ff" :
            (occursin("declined", ln) || occursin("REJECTED", ln)) ? "#ff9b9b" : "#8b949e"
        n = counts[ln]; badge = n > 1 ? " <span style=\"opacity:.55\">×$n</span>" : ""
        "<div style=\"color:$c;margin:2px 0\">$(_esc(ln))$badge</div>"
    end
    return "<div style=\"position:fixed;top:10px;left:10px;width:430px;max-height:52vh;overflow:auto;" *
        "background:rgba(16,18,26,.85);font:11px/1.45 ui-monospace,Consolas,monospace;border-radius:9px;" *
        "z-index:99999;white-space:pre-wrap;box-shadow:0 3px 16px rgba(0,0,0,.55)\">" *
        "<div onclick=\"var b=document.getElementById('surro-body');" *
        "b.style.display=(b.style.display=='none'?'block':'none');\" " *
        "style=\"color:#9bd1ff;font-weight:700;padding:8px 11px;cursor:pointer;position:sticky;top:0;" *
        "background:rgba(16,18,26,.96);border-radius:9px 9px 0 0;user-select:none\">" *
        "SURROGATE WORLD MODEL — decide in imagination, 0 planner calls " *
        "<span style=\"opacity:.55;font-weight:400\">— click to hide ▾</span></div>" *
        "<div id=\"surro-body\" style=\"padding:6px 11px 9px\">" * join(rows, "") * "</div></div>"
end

# ---- wire the seam: the SURROGATE is the producer ----------------------------------------
CB.RESPEC_ENABLED[] = true
# 청소 함수 이름(Symbol)들을 돌며 getproperty 로 CB 에서 꺼내 호출 — 여러 전역상태를 한 번에 초기화.
for f in (:clear_ood_schedule!, :clear_restriction_zones!, :clear_spare_pools!, :clear_faulted_robots!,
          :clear_recovery_spares!, :clear_ood_truth_log!, :clear_wedge_edges!, :clear_stalled_robots!)
    try getproperty(CB, f)() catch end               # getproperty(CB, :foo)() == CB.foo()
end
try CB.set_reform_interval!(400) catch end
CB.set_respec_producer!(surrogate_producer)          # <-- the ONLY substantive difference vs the LLM/RL demos  # 결정자=surrogate
schedule_ood!()                                      # OOD 예약

println(">>> VISUAL SURROGATE demo: OOD=$(DEMO_OOD) seed=$SEED spares=$(4*NSPARE) producer=LEARNED-SURROGATE")
println(">>> the surrogate ranks all 5 DSL macros in imagination and enacts the argmax — no planner call.")
println(">>> building + simulating with FULL NAV + SPARE POOLS + RESPEC SEAM + ANIMATION (slow)...")

# rng=MersenneTwister(SEED) 로 난수 고정 → 재현 가능한 실행. 모델은 tractor 고정.
run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file = "tractor.mpd", project_name = "tractor", num_robots = 10, assignment_mode = :greedy,
        milp_optimizer = :highs, optimizer_time_limit = 60, log_level = Logging.Info,
        max_num_iters_no_progress = 30000, rvo_flag = true, tangent_bug_flag = true,
        dispersion_flag = true, n_spare_per_pool = NSPARE,
        save_animation = SAVE_ANIM, open_animation_at_end = false, update_anim_at_every_step = SAVE_ANIM,
        anim_active_agents = true, anim_active_areas = true, grid_scale = GRID_SCALE, log_sink = _PIPE,
        save_animation_along_the_way = false, write_results = false, overwrite_results = true,
        look_for_previous_milp_solution = false, save_milp_solution = false,
        return_env_before_sim = false, rng = Random.MersenneTwister(SEED))
end

CB.RESPEC_ENABLED[] = false; CB.clear_respec_producer!()
CB.clear_ood_schedule!(); CB.clear_restriction_zones!(); CB.clear_spare_pools!(); CB.clear_faulted_robots!()

htmlpath = joinpath("results", "tractor", "greedy_RVO_Dispersion_TangentBug", "visualization.html")
if isfile(htmlpath) && !isempty(_PIPE)
    html = read(htmlpath, String)
    panel = _log_panel(_PIPE)
    html = occursin("</body>", html) ? replace(html, "</body>" => panel * "\n</body>"; count = 1) : html * panel
    write(htmlpath, html)
    println(">>> embedded $(length(_PIPE)) surrogate-decision log lines into the HTML.")
end
println(">>> done. Open (animation + surrogate reasoning in ONE file): $htmlpath")
OPEN_ANIM && isfile(htmlpath) && (try run(`cmd /c start "" $(abspath(htmlpath))`) catch e; @warn "auto-open failed: $e" end)
end   # demo_surrogate 끝

# =============================================================================
# energy_adaptive -- ENERGY-AWARE ADAPTIVE REPLANNING (NO animation, metrics only). As
#   robots break down / batteries degrade / no-go zones appear at MULTIPLE random times, the
#   system re-plans at EACH event, minimizing battery-energy + handling-distance + makespan,
#   biased away from low-SoC robots. LLM mode if the service is up; else OFFLINE canonical
#   reassign. ENV: ENERGY_W, SEED, N_OOD, PROJECT.
# =============================================================================
# demo_energy_adaptive : "에너지를 신경 쓰는 적응형 재계획" 데모(애니메이션 없이 지표만 출력).
#   빌드 도중 여러 무작위 시점에 고장/배터리열화/금지구역이 터지고, 매 사건마다 재계획한다.
#   목적함수 = makespan + w·(에너지+운반거리), 게다가 SoC 낮은 로봇은 피하도록 편향. LLM 켜져있으면 LLM, 아니면 오프라인 재배정.
#   ENV: ENERGY_W, SEED, N_OOD, PROJECT.
function demo_energy_adaptive()
# ---- knobs (env-overridable) ------------------------------------------------
ENERGY_W = parse(Float64, get(ENV, "ENERGY_W", "1.0e-3"))   # efficiency weight (energy+distance) vs makespan  # 효율 가중치(vs 속도)
SEED     = parse(Int,     get(ENV, "SEED", "7"))
N_OOD    = parse(Int,     get(ENV, "N_OOD", "4"))           # number of random OOD events across the build  # 무작위 OOD 개수
PROJECT  = parse(Int,     get(ENV, "PROJECT", "4"))         # 4 = tractor

# ---- load the navigator layer into the module scope (manual-include pattern) -
# navigator layer (metrics/ood_truth/battery/ood_stream) now loaded ONCE at module top (world-age).

# ---- solver for the re-solves (feasibility-first, quiet) ---------------------
_setup_milp!()

# ---- ENERGY-AWARE OBJECTIVE: every (re)solve minimizes makespan + w·(energy/dist) ----
# 계획 목적함수 가중치: 속도(makespan) 1.0 고정 + 효율(에너지/거리) ENERGY_W. 에너지 모델(대기/적재 소비전력)도 설정.
CB.set_planning_objective_weights!(speed = 1.0, efficiency = ENERGY_W)
CB.set_energy_model!(pickup_overhead = 0.0, idle_power = 1.0, load_power = 0.25)

pp = get_project_params(PROJECT)
println(">>> building env (assignment only)...  project=$(pp[:project_name]) robots=$(pp[:num_robots])")
# 여기선 배정까지만 하고 시뮬레이션은 아래 루프에서 수동으로 돌린다(return_env_before_sim=true → env 만 받음).
env = run_with_stack(2_000_000_000) do
    run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots],
        assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
        log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false, dispersion_flag=false,
        open_animation_at_end=false, save_animation=false, save_animation_along_the_way=false,
        write_results=false, overwrite_results=false,
        look_for_previous_milp_solution=false, save_milp_solution=false,
        return_env_before_sim=true)
end
n_total = Graphs.nv(env.sched)
println(">>> env built: $n_total schedule nodes")

# ---- enable the battery layer + SoC bias ------------------------------------
# 배터리 레이어 켜기: 각 로봇에 SoC(충전상태) 부여, 낮은 SoC 로봇에 페널티(재계획이 건강한 로봇을 선호하게).
fleet = CB.enable_battery!(env; params = CB.demo_battery_params())
CB.set_battery_penalty!(gain = 6.0, soc_target = 0.5, hard_mult = 1.0e3)   # soc_target 아래로 갈수록 페널티↑
println(">>> battery ON: $(length(fleet.soc)) robots @ SoC 1.0, energy objective w=$ENERGY_W")

# ---- schedule MULTI-TIME random OOD across the build ------------------------
# 빌드 진행 여러 시점에 무작위 OOD(고장/배터리/구역)를 seed 로 재현가능하게 예약. ÷=정수나눗셈.
CB.clear_ood_schedule!()
triggers = CB.schedule_random_ood!(; n = N_OOD, kinds = [:fault, :battery, :zone],
    closed_lo = max(4, n_total ÷ 12), closed_hi = max(8, n_total ÷ 2), seed = SEED)
println(">>> scheduled $(length(triggers)) random OOD events at closed-counts: ",
        join(sort([t.closed_at for t in triggers]), ", "))

service_up = CB.respec_service_ready()
CB.RESPEC_ENABLED[] = service_up
println(service_up ? ">>> LLM service UP — full translate->verify->re-solve per OOD\n"
                   : ">>> LLM service DOWN — OFFLINE canonical-reassign fallback per fault\n")

# ---- adaptive run loop (manual stepping; no visualizer) ---------------------
# report(tag) : 현재 진행/에너지/최소SoC/편차를 한 줄로 출력하는 도우미(tag 는 어느 시점인지 라벨).
report(tag) = begin
    r = CB.battery_report(fleet)
    println("    [$tag] closed=$(length(env.cache.closed_set))/$n_total  makespan=",
        round(CB.makespan(env.sched), digits=2),
        "  energy=", round(r.total_energy_J, digits=1),
        "  min_soc=", round(r.min_soc, digits=3),
        "  spread=", round(r.soc_spread, digits=3))
end

# initial step so the freeze path has some completed work
CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)   # 시뮬레이션 한 스텝 진행 + 계획 캐시 갱신
report("start")

seen_faults = Set{Any}()                        # 이미 처리한 고장 로봇 집합(중복 처리 방지)
n_fired = Ref(0)                                # 지금까지 발동된 OOD 수
prev_ms = Ref(CB.makespan(env.sched))           # 직전 makespan(바뀌면 재계획이 일어난 것)
MAX_STEPS = 60_000
# 메인 루프: 매 스텝 (1)due OOD 발동 (2)배터리/respec 대응 (3)한 스텝 전진 (4)makespan 변화 감지 후 리포트.
for k in 2:MAX_STEPS
    n_before = count(t -> t.fired, triggers)    # 발동 전 개수
    CB.ood_inject_step!(env, k)                 # fire any due OOD (pushes NL to respec queue)  # 이번 스텝의 OOD 발동
    n_after = count(t -> t.fired, triggers)     # 발동 후 개수(늘었으면 방금 사건 발생)
    battery_event = false
    if n_after > n_before                       # an OOD just fired this step
        n_fired[] = n_after
        last_nl = isempty(CB.RESPEC_QUEUE.pending) ? "" : last(CB.RESPEC_QUEUE.pending)
        battery_event = occursin("battery", lowercase(last_nl))
        println("\n>>> OOD #$(n_after) fired at step $k (closed=$(length(env.cache.closed_set))): ",
                first(split(last_nl, "\n")))
        report("at-OOD")
    end

    # Battery-health OOD: re-solve the remaining schedule with the SoC-biased objective.
    # 배터리 사건이면: 남은 스케줄을 SoC 편향 목적함수로 다시 풀어(rebalance) 약한 로봇 부담을 줄임.
    if battery_event
        try
            st = CB.rebalance_for_battery!(env)
            println("    [battery] SoC-biased rebalance -> :$(st)")
        catch e
            println("    [battery] rebalance failed: ", first(split(sprint(showerror, e), "\n")))  # 에러 첫 줄만 출력
        end
    end

    if service_up
        outcome = CB.respec_step!(env)          # LLM translate->verify->re-solve; returns the verdict  # LLM 번역→검증→재계획, 판정 반환
        outcome in (:noop, :disabled) || println("    [respec] verdict = :$(outcome)")
    else
        # OFFLINE: route any freshly-faulted robot through canonical reassign (energy-aware re-solve).
        # LLM 없으면: 새로 고장난 로봇마다 정해진(canonical) 재배정 경로로 처리(에너지 인식 재계획).
        for (rid, _) in CB.faulted_robots()
            rid in seen_faults && continue      # 이미 처리했으면 건너뜀
            push!(seen_faults, rid)
            try
                res = CB.fault_robot_and_reassign!(env, rid; verbose = false)
                println("    [OOD fault $(rid)] canonical reassign -> $(res.status)")
            catch e
                println("    [OOD fault $(rid)] reassign failed: ", first(split(sprint(showerror, e), "\n")))
            end
        end
    end
    CB.step_environment!(env)                   # 시뮬레이션 한 스텝 전진
    CB.update_planning_cache!(env, 0.0)

    ms = CB.makespan(env.sched)                 # a re-solve changes the makespan -> a replan happened
    if abs(ms - prev_ms[]) > 1e-6               # makespan 이 바뀌었으면 재계획이 발생한 것
        println("    [replan] makespan $(round(prev_ms[], digits=2)) -> $(round(ms, digits=2))")
        report("post-replan")
        prev_ms[] = ms
    end
    k % 5000 == 0 && report("step $k")          # 5000 스텝마다 중간 리포트(% = 나머지)
    CB.project_complete(env) && (println(">>> build complete at step $k"); break)   # 완성되면 루프 종료
end

# ---- final metrics ----------------------------------------------------------
println("\n== FINAL METRICS ==")
bm = CB.battery_metrics_kwargs(fleet)
placed = length(env.cache.closed_set)
m = CB.metrics_from_schedule(env.sched;
    n_parts = n_total, placed_parts = placed,
    robot_busy_time = [Float64(get(fleet.active_steps, id, 0)) * env.dt for id in keys(fleet.soc)],
    transport_distance = NaN, bm...)
println("  feasible=$(m.feasible)  completion=$(round(m.completion_rate, digits=3))  makespan=$(round(m.makespan, digits=2))")
println("  energy(J)=$(round(m.energy, digits=1))  min_soc=$(round(m.min_soc, digits=3))  soc_spread=$(round(m.soc_spread, digits=3))")
println("  per-robot SoC: ", join([string("R", id.id, "=", round(s, digits=3)) for (id, s) in sort(collect(fleet.soc); by = p -> p.first.id)], "  "))
println("\nDONE. (energy↓ at makespan≈same is the headline; compare ENERGY_W=0 vs >0 runs.)")   # 핵심결과: makespan 비슷하되 에너지↓ (ENERGY_W=0 vs >0 비교)
end   # demo_energy_adaptive 끝

# =============================================================================
# energy_adaptive_anim -- VISUAL (MeshCat) demo of the ENERGY-AWARE ADAPTIVE replanning
#   stack: per-robot SoC accounting + energy objective + multi-time OOD, with a live per-robot
#   battery HUD sidebar. Story: build starts -> a robot's BATTERY degrades -> DeprioritizeAgent
#   (soft) -> energy-aware re-solve -> central NO-GO ZONE -> ForbidZone -> whole-build translate.
#   ENV: USE_MOCK, MOCK_PORT, PROJECT, N_BATTERY, ZONE_CLOSED, ZONE_R, SEED, ENERGY_W, GRID_SCALE,
#        OPEN_ANIM, CAM_MAP, CAM_FOLLOW, SIDEBAR_W.
# =============================================================================
# demo_energy_adaptive_anim : 위 energy_adaptive 의 "시각(MeshCat) 버전". 로봇별 배터리 HUD 사이드바가 실시간으로 뜬다.
#   스토리: 조립 시작 → 한 로봇 배터리 열화 → DeprioritizeAgent(부드러운 우선순위 낮추기) → 에너지인식 재계획 →
#           중앙 금지구역 등장 → ForbidZone → 빌드 전체 평행이동. 사건마다 자연어→DSL→재계획을 사이드바에 보여줌.
#   ENV: USE_MOCK, MOCK_PORT, PROJECT, N_BATTERY, ZONE_CLOSED, ZONE_R, SEED, ENERGY_W, GRID_SCALE, OPEN_ANIM, CAM_MAP, CAM_FOLLOW, SIDEBAR_W.
function demo_energy_adaptive_anim()
USE_MOCK  = get(ENV, "USE_MOCK", "1") == "1"
MOCK_PORT = parse(Int, get(ENV, "MOCK_PORT", "8733"))
if USE_MOCK
    ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:$MOCK_PORT"
elseif !haskey(ENV, "RESPEC_SERVICE_URL")
    ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:8000"
end

# navigator layer (manual-include pattern) — battery + multi-OOD stream
# navigator layer now loaded ONCE at module top (world-age).

PROJECT     = parse(Int, get(ENV, "PROJECT", "4"))           # 4 = tractor
N_BATTERY   = parse(Int, get(ENV, "N_BATTERY", "2"))         # # of battery-degradation OOD
ZONE_CLOSED = parse(Int, get(ENV, "ZONE_CLOSED", "60"))      # closed-count to drop the central zone
ZONE_R      = parse(Float64, get(ENV, "ZONE_R", "2.5"))      # central zone radius (big -> whole-build move)
SEED        = parse(Int, get(ENV, "SEED", "7"))
ENERGY_W    = parse(Float64, get(ENV, "ENERGY_W", "0.01"))
GRID_SCALE  = parse(Float64, get(ENV, "GRID_SCALE", "4.0"))
OPEN_ANIM   = get(ENV, "OPEN_ANIM", "1") == "1"
CAM_MAP     = get(ENV, "CAM_MAP", "x0-y")                   # world (x,y)->cam target; DEFAULT x0-y

_setup_milp!()

# ENERGY-AWARE objective (every re-solve minimizes makespan + w·energy, biased off low-SoC robots).
CB.set_planning_objective_weights!(speed = 1.0, efficiency = ENERGY_W)
CB.set_energy_model!(pickup_overhead = 0.0, idle_power = 1.0, load_power = 0.25)

# camera-follow DISABLED by default. Set CAM_FOLLOW=1 to re-enable centre-on-active-agents.
# 카메라 추적 기본 꺼짐. CAM_FOLLOW=1 이면 켬. 아래는 world(x,y)→카메라 타깃 좌표 매핑을 CAM_MAP 문자열로 선택.
CB.CAMERA_FOLLOW[] = get(ENV, "CAM_FOLLOW", "0") == "1"
CB.CAMERA_FOLLOW[] && CB.set_camera_follow_map!(          # 켜졌을 때만 매핑 설정(&& 짧은회로)
    CAM_MAP == "xy0"  ? ((x, y) -> (Float64(x), Float64(y), 0.0)) :
    CAM_MAP == "x0y"  ? ((x, y) -> (Float64(x), 0.0, Float64(y))) :
    CAM_MAP == "-x0y" ? ((x, y) -> (-Float64(x), 0.0, Float64(y))) :
    ((x, y) -> (Float64(x), 0.0, -Float64(y))))   # default "x0-y"

# --- deterministic mock /propose: battery->DeprioritizeAgent, zone->ForbidZone, fault->ReplaceAgent ---
# _agent_for_rn : 사건 문구에서 "R숫자"를 뽑아, id 가 "(숫자)" 로 끝나는 로봇을 찾는다(못 찾으면 첫 로봇).
_agent_for_rn(event, agents) = begin
    m = match(r"[Rr](\d+)", String(event))               # 정규식으로 R1, r2 같은 로봇 번호 추출
    m === nothing && return (isempty(agents) ? "" : String(agents[1]["id"]))
    n = m.captures[1]                                    # 잡힌 숫자 부분
    for a in agents
        endswith(String(a["id"]), "($n)") && return String(a["id"])
    end
    isempty(agents) ? "" : String(agents[1]["id"])
end
# start_mock : 가짜 LLM. 자연어 사건을 소문자로 훑어 종류를 판단 → 배터리=DeprioritizeAgent, 고장=ReplaceAgent, 구역=ForbidZone.
function start_mock(port)
    handler = function (req::HTTP.Request)
        path = HTTP.URIs.URI(req.target).path
        path == "/health" && return HTTP.Response(200, JSON3.write(Dict("status" => "ok")))
        path == "/propose" || return HTTP.Response(404, "not found")   # /propose 아니면 404
        body   = JSON3.read(String(req.body))
        event  = String(get(body, "event", ""))
        ev     = lowercase(event)                        # 소문자로 통일해 키워드 매칭
        agents = get(body, "agents", []); zones = get(body, "zones", []); nodes = get(body, "nodes", [])
        cons =                                            # cons = 반환할 DSL 제약(constraints) 목록. if 식의 결과가 담김.
            if occursin("battery", ev) || occursin("charge", ev) || occursin("degraded", ev)
                aid = _agent_for_rn(event, agents)
                @info "[MOCK-LLM] battery -> DeprioritizeAgent(agent=$aid, factor=50)"
                [Dict("kind" => "DeprioritizeAgent", "agent" => aid, "factor" => 50.0)]
            elseif occursin("broken", ev) || occursin("immobile", ev) || occursin("cannot move", ev)
                aid = _agent_for_rn(event, agents)
                @info "[MOCK-LLM] breakdown -> ReplaceAgent(agent=$aid)"
                [Dict("kind" => "ReplaceAgent", "agent" => aid, "after" => 0.0)]
            elseif occursin("zone", ev) || occursin("exclusion", ev) || occursin("no-go", ev)
                zkey = isempty(zones) ? "zone" : String(zones[1]["key"])
                cov  = isempty(zones) ? [] : zones[1]["covers"]
                asm  = !isempty(cov) ? String(first(cov)) : (isempty(nodes) ? "" : String(nodes[1]["id"]))
                @info "[MOCK-LLM] zone -> ForbidZone(zone=$zkey, assembly=$asm)"
                [Dict("kind" => "ForbidZone", "zone" => zkey, "assembly" => asm)]
            else
                @info "[MOCK-LLM] no-op"
                []
            end
        return HTTP.Response(200, JSON3.write(Dict("constraints" => cons, "rationale" => "mock")))
    end
    return HTTP.serve!(handler, "127.0.0.1", port)
end

_root_id(env) = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))   # 루트(최대) 조립물 키
# central no-go zone over the build core -> forces the WHOLE-build translate (the camera-follow case)
# central_zone_action! : 빌드 정중앙에 큰 금지구역을 놓아 "빌드 전체 이동"을 유발(카메라 추적 시연 케이스). 자연어 반환.
function central_zone_action!(env)
    gs = CB.root_deposit_goals(env)
    zc = isempty(gs) ? Vector{Float64}(CB.get_center(env.staging_circles[_root_id(env)])[1:2]) : sum(gs) ./ length(gs)
    CB.add_restriction_zone!(:zone, zc, ZONE_R)
    @info "[DEMO] central no-go ZONE @ $(round.(zc; digits=2)) R=$ZONE_R -> expect whole-build relocation"
    return "A safety exclusion zone is now active over the central build area; robots must not enter or pass through it."
end

# --- OOD schedule -------------------------------------------------------------
SRV = USE_MOCK ? start_mock(MOCK_PORT) : nothing
CB.RESPEC_ENABLED[] = true
CB.clear_ood_schedule!(); CB.clear_restriction_zones!(); CB.clear_agent_bias!()

# Per-step SoC snapshots for the LIVE (time-synced) battery UI.
# SOC_HISTORY : 매 스텝의 로봇별 SoC 스냅샷을 쌓는 배열. 나중에 애니메이션 재생위치에 맞춰 배터리바를 움직이는 데 씀.
SOC_HISTORY = Vector{Dict{Any,Float64}}()

# step 1: turn the battery layer ON (needs env; the action receives it).
# 스텝 1 에서 배터리 레이어 켜기(env 가 필요해 OOD 액션으로 예약). 익명함수를 액션으로 넘김.
CB.schedule_ood!(1, function (env)
    CB.enable_battery!(env; params = CB.demo_battery_params())
    CB.set_battery_penalty!(gain = 6.0, soc_target = 0.5, hard_mult = 1.0e3)
    # Wrap the accounting hook so every step also records a SoC snapshot for the live UI.
    # 배터리 회계 훅을 감싸서, 매 스텝 SoC 를 계산한 뒤 스냅샷도 함께 기록하게 만든다(라이브 UI용).
    CB.BATTERY_STEP_HOOK[] = function (e, prev)
        CB.account_battery_step!(e, prev)                # 원래 회계(소비/충전 반영)
        f = CB.BATTERY_FLEET[]
        f === nothing || push!(SOC_HISTORY, copy(f.soc)) # copy = 그 순간 값 복사(참조 공유 방지)
        return nothing
    end
    @info "[DEMO] battery ON ($(length(CB.BATTERY_FLEET[].soc)) robots), energy objective w=$ENERGY_W, camera-follow=$(CB.CAMERA_FOLLOW[])"
    return nothing   # no respec
end)
# a few BATTERY-degradation OODs (soft DeprioritizeAgent) spread over the early build
# 초반에 배터리 열화 OOD 몇 개(부드러운 DeprioritizeAgent 유발) 무작위 예약.
CB.schedule_random_ood!(; n = N_BATTERY, kinds = [:battery], closed_lo = 8,
    closed_hi = max(12, ZONE_CLOSED - 10), seed = SEED)
# one big CENTRAL ZONE mid-build -> whole-build translate -> camera follows
CB.schedule_ood_at_closed!(ZONE_CLOSED, central_zone_action!)   # 중반에 큰 중앙구역 1개 → 전체이동 유발

pp = CB.get_project_params(PROJECT)
_rdy = Ref(false)
for _ in 1:30
    if CB.respec_service_ready(); _rdy[] = true; break; end
    sleep(0.1)
end
ready = _rdy[]
println(">>> ENERGY-ADAPTIVE visual demo: project=$(pp[:project_name])  mode=$(USE_MOCK ? "MOCK" : "REAL-LLM")")
println(">>> battery OOD x$N_BATTERY (DeprioritizeAgent) + central zone @closed=$ZONE_CLOSED; /propose=$(ENV["RESPEC_SERVICE_URL"]) ready=$ready")
(!USE_MOCK && !ready) && @warn "REAL-LLM mode but service not reachable — start uvicorn server:app --port 8000 in a shell WITH ANTHROPIC_API_KEY first."

_PIPE = String[]
run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Info,
        rvo_flag=true, tangent_bug_flag=true, dispersion_flag=true,
        save_animation=true, open_animation_at_end=false, update_anim_at_every_step=true,
        anim_active_agents=true, anim_active_areas=true, grid_scale=GRID_SCALE, log_sink=_PIPE,
        save_animation_along_the_way=false, write_results=false, overwrite_results=true,
        look_for_previous_milp_solution=false, save_milp_solution=false, return_env_before_sim=false)
end

# battery summary for the log panel
batt = CB.BATTERY_FLEET[] === nothing ? nothing : CB.battery_report()
batt === nothing || push!(_PIPE, "[BATTERY] min_soc=$(round(batt.min_soc,digits=3)) spread=$(round(batt.soc_spread,digits=3)) total_energy_J=$(round(batt.total_energy_J,digits=1))")

# reset all globals so later runs are byte-for-byte normal
try close(SRV) catch end
CB.RESPEC_ENABLED[] = false; CB.clear_ood_schedule!(); CB.clear_restriction_zones!()
CB.CAMERA_FOLLOW[] = false; CB.clear_agent_bias!()
CB.BATTERY_ACCOUNTING[] = false; CB.BATTERY_STEP_HOOK[] = nothing; CB.EDGE_COST_MULTIPLIER[] = nothing
CB.set_planning_objective_weights!(speed = 1.0, efficiency = 0.0); CB.set_energy_model!()

# --- embed the NL->DSL->recovery + battery UI into the saved HTML -------------
SIDEBAR_W = parse(Int, get(ENV, "SIDEBAR_W", "360"))   # sidebar width in px (env-tunable)
_esc(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")

# compact colored respec/recovery log rows (inner html only; the card wraps them)
# _log_rows : respec/복구 로그 줄들을 색깔 입힌 HTML div 문자열로(사이드바 카드 안에 들어갈 내용만).
function _log_rows(lines)
    isempty(lines) && return "<div style=\"color:#8891a5\">(no respec events)</div>"   # 없으면 안내 문구
    rows = map(lines) do ln
        c = occursin("OOD event:", ln) ? "#ffd479" :
            (occursin("LLM proposal", ln) || occursin("MOCK-LLM", ln)) ? "#7ee787" :
            (occursin("BATTERY", ln) || occursin("deprioritize", ln)) ? "#f0a0ff" :
            (occursin("WHOLE-BUILD", ln) || occursin("admitted", ln) || occursin("relocation", ln)) ? "#79c0ff" :
            "#d8e0ee"
        "<div style=\"color:$c;margin:2px 0\">$(_esc(ln))</div>"
    end
    return join(rows, "")
end

# LIVE per-robot battery bars, ALIGNED BY ROBOT NUMBER (R1,R2,…,Rn).
# _battery_live : 로봇별 배터리 막대 HTML + 그것을 애니메이션 재생위치(playhead)에 맞춰 움직이는 JS 를 만든다.
#   반환은 (막대HTML, 스크립트) 튜플. SoC 이력을 프레임별로 JSON 에 담아 브라우저가 보간(interpolate)해 그린다.
#   maxpts = 이력이 너무 길면 이 개수로 다운샘플링. 로봇 번호(R1..Rn) 순서로 정렬.
function _battery_live(history; maxpts::Int = 500)
    isempty(history) && return ("", "")
    li = findlast(!isempty, history)                     # 비어있지 않은 마지막 프레임 인덱스
    li === nothing && return ("", "")
    okeys = sort(collect(keys(history[li])); by = k -> (try Int(k.id) catch; 0 end))  # by robot number
    nums  = [ (try Int(k.id) catch; 0 end) for k in okeys ]
    n = length(history)
    idxs = n <= maxpts ? collect(1:n) : unique(round.(Int, range(1, n; length = maxpts)))
    mat  = [ [ round(Float64(get(history[i], k, NaN)); digits = 3) for k in okeys ] for i in idxs ]
    bars = join(map(nums) do rn
        "<div style=\"display:flex;align-items:center;gap:6px;margin:3px 0\">" *
            "<span style=\"width:30px;color:#cdd6e0\">R$rn</span>" *
            "<div style=\"flex:1;height:11px;background:#20242e;border-radius:5px;overflow:hidden\">" *
                "<div id=\"bat-$rn\" style=\"height:100%;width:100%;background:#7ee787;transition:width .1s linear\"></div></div>" *
            "<span id=\"batp-$rn\" style=\"width:34px;text-align:right;color:#7ee787\">100%</span></div>"
    end, "")
    data = JSON3.write(Dict("r" => nums, "s" => mat))
    script = """
    <script>
    (function(){
      var D = $data, R = D.r, S = D.s, N = S.length;
      function col(s){ return s<=0.25?'#ff6b6b':(s<=0.5?'#ffb454':'#7ee787'); }
      // Read the animation playhead: max action time (tracks PLAY and SCRUB), duration from the clip.
      function playhead(){
        var an = window.viewer && window.viewer.animator; if(!an) return {t:0,d:0};
        var acts = an.actions||[], t=0, d=an.duration||0;
        for(var i=0;i<acts.length;i++){ t=Math.max(t, acts[i].time||0);
          if(acts[i]._clip){ d=Math.max(d, acts[i]._clip.duration||0); } }
        return {t:t, d:d};
      }
      function socAt(frac){
        if(N===0) return null;
        var x=frac*(N-1), i=Math.floor(x), g=x-i;
        var a=S[Math.max(0,Math.min(N-1,i))], b=S[Math.max(0,Math.min(N-1,i+1))], o=[];
        for(var k=0;k<R.length;k++){ o.push(a[k]+(b[k]-a[k])*g); } return o;
      }
      function tick(){
        var p=playhead(), frac=p.d>0?Math.max(0,Math.min(1,p.t/p.d)):0, soc=socAt(frac);
        if(soc){ for(var k=0;k<R.length;k++){ var s=soc[k]; if(s==null||isNaN(s)) continue;
          var pct=Math.round(100*Math.max(0,Math.min(1,s)));
          var bar=document.getElementById('bat-'+R[k]), lab=document.getElementById('batp-'+R[k]);
          if(bar){ bar.style.width=pct+'%'; bar.style.background=col(s); }
          if(lab){ lab.textContent=pct+'%'; lab.style.color=col(s); } } }
        requestAnimationFrame(tick);
      }
      requestAnimationFrame(tick);
    })();
    </script>
    """
    return (bars, script)
end

# left sidebar wrapper: shrinks #meshcat-pane and docks the two cards beside it (no overlap).
# _sidebar : 왼쪽 고정 사이드바 HTML/CSS 를 만든다 — 3D 화면(#meshcat-pane)을 줄이고 그 옆에 배터리·로그 카드를 붙임(겹침 없음).
function _sidebar(log_html, batt_html, batt_script)
    batt_card = isempty(batt_html) ? "" :                # 배터리 카드(내용 없으면 생략)
        "<div class=\"cb-card\"><div class=\"cb-title\">🔋 Battery SoC — per robot" *
        " <span style=\"color:#8891a5;font-weight:400\">(live · red ≤25% · orange ≤50%)</span></div>" *
        batt_html * "</div>"
    log_card =                                            # respec 로그 카드
        "<div class=\"cb-card\"><div class=\"cb-title\">ENERGY-ADAPTIVE respec" *
        " <span style=\"color:#8891a5;font-weight:400\">(OOD → DSL → re-solve)</span></div>" *
        "<div class=\"cb-log\">$log_html</div></div>"
    return """
    <style>
      #meshcat-pane { width: calc(100vw - $(SIDEBAR_W)px) !important; margin-left: $(SIDEBAR_W)px !important; }
      #cb-sidebar { position:fixed; top:0; left:0; width:$(SIDEBAR_W)px; height:100vh; box-sizing:border-box;
        overflow-y:auto; background:#0b0e15; border-right:1px solid #2a3346; z-index:99999;
        font:11px/1.45 ui-monospace,Consolas,monospace; padding:9px; }
      #cb-sidebar .cb-card { background:rgba(16,18,26,.92); border-radius:8px; padding:8px 10px;
        margin-bottom:9px; box-shadow:0 2px 10px rgba(0,0,0,.5); }
      #cb-sidebar .cb-title { color:#9bd1ff; font-weight:700; margin-bottom:6px; }
      #cb-sidebar .cb-log { max-height:56vh; overflow:auto; white-space:pre-wrap; }
    </style>
    <div id="cb-sidebar">$batt_card$log_card</div>
    <script>
      (function(){ function fit(){ try{ window.dispatchEvent(new Event('resize')); }catch(e){} }
        window.addEventListener('load', function(){ fit(); setTimeout(fit,80); setTimeout(fit,500); });
        setTimeout(fit,150); })();
    </script>
    $batt_script
    """
end

# 저장된 애니메이션 HTML 에 배터리 HUD + respec 로그 사이드바를 삽입.
htmlpath = joinpath("results", pp[:project_name], "greedy_RVO_Dispersion_TangentBug", "visualization.html")
if isfile(htmlpath)
    html  = read(htmlpath, String)
    bars, bscript = _battery_live(SOC_HISTORY)           # 배터리 막대 + 구동 스크립트
    panel = _sidebar(_log_rows(_PIPE), bars, bscript)    # 사이드바 전체 조립
    html  = occursin("</body>", html) ? replace(html, "</body>" => panel * "\n</body>"; count = 1) : html * panel
    write(htmlpath, html)
    println(">>> embedded sidebar (LIVE per-robot battery over $(length(SOC_HISTORY)) frames + $(length(_PIPE))-line respec log).")
end
println(">>> done. Open: $htmlpath")
OPEN_ANIM && isfile(htmlpath) && (try run(`cmd /c start "" $(abspath(htmlpath))`) catch e; @warn "auto-open failed; open manually: $e" end)
end   # demo_energy_adaptive_anim 끝

# =============================================================================
# energy_stall_replace -- VISUAL demo of the CLOSED battery loop: motion drains SoC ->
#   a robot hits 0% and STALLS -> raises a breakdown OOD -> LLM (mock) re-specs ReplaceAgent ->
#   the NEAREST spare depot dispatches a fresh robot that adopts the dead robot's chain.
#   ENV: USE_MOCK, MOCK_PORT, PROJECT, N_SPARE, SHRINK, STALL_SOC, ENERGY_W, SEED, GRID_SCALE,
#        OPEN_ANIM, FAST, SPARE_MARGIN, REFORM_INTERVAL, HOT_SWAP, STALL_CLEAR, DISCHARGE_AT, SIDEBAR_W.
# =============================================================================
# demo_energy_stall_replace : "닫힌 배터리 루프" 시각 데모. 움직임이 SoC 를 소모 → 한 로봇이 0%가 되어 멈춤(stall) →
#   고장 OOD 발생 → (mock)LLM 이 ReplaceAgent 로 재명세 → 가장 가까운 예비 창고(depot)가 새 로봇을 보내 죽은 로봇의
#   작업 사슬을 물려받는다. 여기선 OOD 를 미리 예약하지 않고 "움직임 소모"에서 자연히 stall 이 생기게 한다.
#   ENV: USE_MOCK, MOCK_PORT, PROJECT, N_SPARE, SHRINK, STALL_SOC, ENERGY_W, SEED, GRID_SCALE, OPEN_ANIM,
#        FAST, SPARE_MARGIN, REFORM_INTERVAL, HOT_SWAP, STALL_CLEAR, DISCHARGE_AT, SIDEBAR_W.
function demo_energy_stall_replace()
USE_MOCK  = get(ENV, "USE_MOCK", "1") == "1"
MOCK_PORT = parse(Int, get(ENV, "MOCK_PORT", "8744"))
if USE_MOCK
    ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:$MOCK_PORT"
elseif !haskey(ENV, "RESPEC_SERVICE_URL")
    ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:8000"
end

# navigator layer (manual-include pattern) — battery accounting + stall coupling
# navigator layer now loaded ONCE at module top (world-age).

PROJECT    = parse(Int, get(ENV, "PROJECT", "4"))          # 4 = tractor
N_SPARE    = parse(Int, get(ENV, "N_SPARE", "2"))          # spares per depot (x4 dirs)  # 창고당 예비 수(방위 4곳)
SHRINK     = parse(Float64, get(ENV, "SHRINK", "200.0"))   # battery capacity /SHRINK  # 배터리 용량을 /SHRINK 로 줄여 빨리 방전
STALL_SOC  = parse(Float64, get(ENV, "STALL_SOC", "0.02")) # SoC at/below which a robot dies  # 이 SoC 이하면 로봇 정지
ENERGY_W   = parse(Float64, get(ENV, "ENERGY_W", "0.01"))
SEED       = parse(Int, get(ENV, "SEED", "7"))
GRID_SCALE = parse(Float64, get(ENV, "GRID_SCALE", "4.0"))
OPEN_ANIM  = get(ENV, "OPEN_ANIM", "1") == "1"
FAST       = get(ENV, "FAST", "0") == "1"   # tuning: skip per-step anim frames (much faster, coarse video)
SPARE_MARGIN = parse(Float64, get(ENV, "SPARE_MARGIN", "18.0"))  # depot distance outside build  # 창고를 빌드에서 얼마나 멀리
CB.set_spare_pool_margin!(SPARE_MARGIN)           # park the depots FAR from the build (visible re-emergence)  # 예비가 멀리서 등장해 눈에 띔
# ADAPTIVITY: react to a post-swap team wedge in ~a second, not the old ~50 s.
# 적응성: 교체 후 팀이 끼는(wedge) 상황을 옛날처럼 ~50초가 아니라 ~1초 만에 감지·복구하도록 점검 간격을 줄임.
REFORM_INTERVAL = parse(Int, get(ENV, "REFORM_INTERVAL", "300"))
CB.set_reform_interval!(REFORM_INTERVAL)

_setup_milp!()

# ENERGY-AWARE objective so replans still prefer healthy robots (soft), on top of the hard stall.
CB.set_planning_objective_weights!(speed = 1.0, efficiency = ENERGY_W)
CB.set_energy_model!(pickup_overhead = 0.0, idle_power = 1.0, load_power = 0.25)

# --- deterministic mock /propose: breakdown/stall -> ReplaceAgent (nearest spare hand-off) ---
_agent_for_rn(event, agents) = begin
    m = match(r"[Rr](\d+)", String(event))
    m === nothing && return (isempty(agents) ? "" : String(agents[1]["id"]))
    n = m.captures[1]
    for a in agents
        endswith(String(a["id"]), "($n)") && return String(a["id"])
    end
    isempty(agents) ? "" : String(agents[1]["id"])
end
# start_mock : 가짜 LLM. stall/고장="broken/immobile"=ReplaceAgent, 교착="deadlock/stuck"=ReformTeam, 열화=DeprioritizeAgent.
#   검사 순서 주의: 배터리 방전은 "broken" 로 먼저 잡혀 교체가 된다.
function start_mock(port)
    handler = function (req::HTTP.Request)
        path = HTTP.URIs.URI(req.target).path
        path == "/health" && return HTTP.Response(200, JSON3.write(Dict("status" => "ok")))
        path == "/propose" || return HTTP.Response(404, "not found")
        body   = JSON3.read(String(req.body))
        event  = String(get(body, "event", ""))
        ev     = lowercase(event)
        agents = get(body, "agents", [])
        cons =
            if occursin("broken", ev) || occursin("immobile", ev) || occursin("cannot move", ev)
                aid = _agent_for_rn(event, agents)                       # battery breakdown (checked FIRST)  # 방전=고장으로 먼저 처리
                @info "[MOCK-LLM] battery-stall -> ReplaceAgent(agent=$aid)"
                [Dict("kind" => "ReplaceAgent", "agent" => aid, "after" => 0.0)]
            elseif occursin("deadlock", ev) || occursin("stuck", ev) || occursin("stall", ev) ||
                   occursin("cannot complete", ev) || occursin("re-establish", ev) || occursin("reform", ev)
                @info "[MOCK-LLM] team deadlock -> ReformTeam()"    # auto-emitted no-progress event
                [Dict("kind" => "ReformTeam")]                     # -> recover_stalled_teams! (un-wedges the build)
            elseif occursin("degraded", ev) || occursin("charge", ev)
                aid = _agent_for_rn(event, agents)
                @info "[MOCK-LLM] battery-degraded -> DeprioritizeAgent(agent=$aid, factor=50)"
                [Dict("kind" => "DeprioritizeAgent", "agent" => aid, "factor" => 50.0)]
            else
                @info "[MOCK-LLM] no-op"
                []
            end
        return HTTP.Response(200, JSON3.write(Dict("constraints" => cons, "rationale" => "mock")))
    end
    return HTTP.serve!(handler, "127.0.0.1", port)
end

# --- OOD schedule: NONE. Stalls emerge from motion drain. We only turn the battery+stall
#     layer ON at step 1 (needs env). Spare depots are injected by run_lego_demo (n_spare>0). --
SRV = USE_MOCK ? start_mock(MOCK_PORT) : nothing
CB.RESPEC_ENABLED[] = true
CB.clear_ood_schedule!(); CB.clear_restriction_zones!(); CB.clear_agent_bias!()
CB.clear_faulted_robots!(); CB.clear_recovery_spares!()

# Per-step SoC snapshots for the LIVE (time-synced) battery UI.
SOC_HISTORY = Vector{Dict{Any,Float64}}()

# 스텝 1: 배터리 레이어 + "SoC 임계 이하면 정지"하는 stall 커플링을 켠다(env 필요해 OOD 액션으로).
CB.schedule_ood!(1, function (env)
    CB.enable_battery!(env; params = CB.demo_battery_params(shrink = SHRINK))
    CB.set_battery_penalty!(gain = 6.0, soc_target = 0.5, hard_mult = 1.0e3)
    # clear=true tows the dead robot off-grid so the spare takes over cleanly and the build completes.
    # clear=true 면 죽은 로봇을 격자 밖으로 치워 예비가 깔끔히 인계하고 빌드가 완주된다(hot-swap 이면 false).
    hot = get(ENV, "HOT_SWAP", "0") == "1"
    CB.set_battery_stall!(enabled = true, threshold = STALL_SOC,   # SoC≤threshold 면 정지 트리거
        clear = hot ? false : (get(ENV, "STALL_CLEAR", "1") == "1"),
        obstacle = get(ENV, "STALL_OBSTACLE", "0") == "1")   # <-- the new coupling  # 정지 지점을 장애물로 둘지
    if hot
        CB.set_hot_swap!(enabled = true, mode = Symbol(get(ENV, "HOT_SWAP_MODE", "via_depot")))
        @info "[DEMO] identity-preserving HOT-SWAP repository replacement ON (mode=$(CB.HOT_SWAP_MODE[]))"
    end
    # Wrap the accounting hook (which also runs the stall trigger) so every step records a SoC snapshot.
    CB.BATTERY_STEP_HOOK[] = function (e, prev)
        CB.account_battery_step!(e, prev)
        f = CB.BATTERY_FLEET[]
        f === nothing || push!(SOC_HISTORY, copy(f.soc))
        return nothing
    end
    @info "[DEMO] battery ON ($(length(CB.BATTERY_FLEET[].soc)) robots incl spares), " *
          "stall<=$(STALL_SOC), energy w=$ENERGY_W, spares=$(4*N_SPARE) at N/S/E/W depots"
    return nothing   # no respec here
end)

# Deterministic "run flat mid-haul": at chosen build-progress points, drain an ACTIVE transport robot to empty.
# _pick_active_worker : 지금 실제로 일하는(예비 아닌) 로봇 하나를 고른다 — 방전시켜 stall 을 일부러 만들 대상.
#   1순위: 돌아갈 작업이 남은 활동 RobotGo. 폴백: 운반유닛(TransportUnitGo) 팀의 비-예비 로봇.
function _pick_active_worker(env)
    spares = Set(CB.active_spares())            # 예비 로봇들(제외 대상)
    sched  = env.sched
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.RobotGo || continue
        rid = try CB.entity(n).id catch; nothing end
        (rid === nothing || rid in spares) && continue    # 예비는 건너뜀
        CB._first_pending_assignment(env, rid) === nothing && continue   # has a task to return to  # 남은 작업 있어야 함
        return rid
    end
    for v in env.cache.active_set                                        # fallback: a non-spare carrier  # 폴백: 운반 중인 비-예비
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.TransportUnitGo || continue
        for rid in keys(CB.robot_team(n))
            rid in spares || return rid
        end
    end
    return nothing
end

# deep_discharge_active! : 일하는 로봇 하나의 SoC 를 0 으로 만들어 "운반 중 방전"을 강제. 그러면 stall 트리거가 알아서 OOD 를 일으킴.
function deep_discharge_active!(env)
    fleet = CB.BATTERY_FLEET[]; fleet === nothing && return nothing
    id = _pick_active_worker(env)            # a real working robot (never a parked spare)  # 진짜 일하는 로봇(예비 아님)
    (id === nothing || !haskey(fleet.soc, id)) && return nothing
    fleet.soc[id] = 0.0                        # run flat mid-haul  # 운반 도중 방전시킴
    @info "[DEMO] deep-discharge R$(id.id) mid-haul (SoC->0) -> expect stall + spare replace"
    return nothing                             # the battery stall trigger raises the OOD itself  # OOD 는 stall 트리거가 냄
end
# DISCHARGE_AT : "완료노드 몇 개일 때 방전시킬지" 목록(ENV 콤마구분). 각 지점에 deep_discharge_active! 예약.
DISCHARGE_AT = [parse(Int, strip(x)) for x in split(get(ENV, "DISCHARGE_AT", "60"), ",") if strip(x) != ""]
for k in DISCHARGE_AT
    CB.schedule_ood_at_closed!(k, deep_discharge_active!)
end

pp = CB.get_project_params(PROJECT)
_rdy = Ref(false)
for _ in 1:30
    if CB.respec_service_ready(); _rdy[] = true; break; end
    sleep(0.1)
end
ready = _rdy[]
println(">>> ENERGY-STALL-REPLACE demo: project=$(pp[:project_name])  mode=$(USE_MOCK ? "MOCK" : "REAL-LLM")")
println(">>> spares=$(4*N_SPARE) (N/S/E/W depots), battery shrink=$SHRINK, stall<=$STALL_SOC; /propose=$(ENV["RESPEC_SERVICE_URL"]) ready=$ready")

_PIPE = String[]
run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Info,
        max_num_iters_no_progress=parse(Int, get(ENV, "NOPROG", "10000")), # must exceed the 2000-step
                                                                           # reform interval so the auto-
                                                                           # emitted ReformTeam recovery
                                                                           # fires and un-wedges the build
                                                                           # (한국어) 진전없음 허용 스텝. 팀 재구성 간격보다
                                                                           # 커야 자동 ReformTeam 복구가 발동해 끼임을 푼다.
        rvo_flag=true, tangent_bug_flag=true, dispersion_flag=true,
        n_spare_per_pool=N_SPARE,                        # <-- VISIBLE spare depots at grid sides  # 격자 가장자리에 보이는 예비 창고
        save_animation=!FAST, open_animation_at_end=false, update_anim_at_every_step=!FAST,
        anim_active_agents=true, anim_active_areas=true, grid_scale=GRID_SCALE, log_sink=_PIPE,
        save_animation_along_the_way=false, write_results=false, overwrite_results=true,
        look_for_previous_milp_solution=false, save_milp_solution=false, return_env_before_sim=false)
end

# battery summary
batt = CB.BATTERY_FLEET[] === nothing ? nothing : CB.battery_report()
batt === nothing || push!(_PIPE, "[BATTERY] min_soc=$(round(batt.min_soc,digits=3)) " *
    "n_depleted=$(batt.n_depleted) total_energy_J=$(round(batt.total_energy_J,digits=1))")
push!(_PIPE, "[STALL] robots stalled+replaced this run: $(length(CB.stalled_robots()))")

# reset all globals so later runs are byte-for-byte normal
try close(SRV) catch end
CB.RESPEC_ENABLED[] = false; CB.clear_ood_schedule!(); CB.clear_restriction_zones!()
CB.clear_agent_bias!(); CB.clear_faulted_robots!(); CB.clear_recovery_spares!()
CB.BATTERY_ACCOUNTING[] = false; CB.BATTERY_STEP_HOOK[] = nothing; CB.EDGE_COST_MULTIPLIER[] = nothing
CB.SOC_SPEED_HOOK[] = nothing; CB.set_battery_stall!(enabled = false); CB.clear_stalled_robots!()
CB.set_planning_objective_weights!(speed = 1.0, efficiency = 0.0); CB.set_energy_model!()

# --- embed the LIVE battery HUD + stall/replace log into the saved HTML -------
SIDEBAR_W = parse(Int, get(ENV, "SIDEBAR_W", "360"))   # sidebar width in px (env-tunable)
_esc(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")

# compact colored stall/replace/respec log rows (inner html; the card wraps them)
# _log_rows : stall/교체/respec 로그를 색깔 HTML 로(STALL=빨강, 교체/예비=파랑 등). 사이드바 카드 안에 들어갈 내용.
function _log_rows(lines)
    isempty(lines) && return "<div style=\"color:#8891a5\">(no respec events)</div>"
    rows = map(lines) do ln
        c = occursin("OOD event:", ln) ? "#ffd479" :
            (occursin("MOCK-LLM", ln) || occursin("LLM proposal", ln)) ? "#7ee787" :
            occursin("STALL", ln) ? "#ff7b72" :          # 정지(stall) 줄은 빨강
            (occursin("REPLACE", ln) || occursin("spare", ln) || occursin("ADMITTED", ln) || occursin("took over", ln)) ? "#79c0ff" :
            occursin("BATTERY", ln) ? "#f0a0ff" : "#d8e0ee"
        "<div style=\"color:$c;margin:2px 0\">$(_esc(ln))</div>"
    end
    return join(rows, "")
end

# LIVE per-robot battery bars aligned by robot number (R1..Rn), driven from the SoC-per-frame history.
# _battery_live : 위 데모의 것과 같은 배터리 HUD 생성기 + "hot-swap 된 로봇"(swapped) 은 파란 ⇄ 배지로 구분 표시.
#   swapped = 창고에서 몸체 교체된 로봇 번호 집합(두 번째 인자, 기본 빈 집합).
function _battery_live(history, swapped = Set{Int}(); maxpts::Int = 500)
    isempty(history) && return ("", "")
    li = findlast(!isempty, history); li === nothing && return ("", "")
    okeys = sort(collect(keys(history[li])); by = k -> (try Int(k.id) catch; 0 end))
    nums  = [ (try Int(k.id) catch; 0 end) for k in okeys ]
    n = length(history)
    idxs = n <= maxpts ? collect(1:n) : unique(round.(Int, range(1, n; length = maxpts)))
    mat  = [ [ round(Float64(get(history[i], k, NaN)); digits = 3) for k in okeys ] for i in idxs ]
    bars = join(map(nums) do rn
        sw = rn in swapped                                   # this worker was hot-swapped from a depot
        tag = sw ? " <span style=\"color:#58a6ff\">&#8646;</span>" : ""   # ⇄ badge
        "<div style=\"display:flex;align-items:center;gap:6px;margin:3px 0\">" *
            "<span style=\"width:44px;color:#cdd6e0\">R$rn$tag</span>" *
            "<div style=\"flex:1;height:11px;background:#20242e;border-radius:5px;overflow:hidden\">" *
                "<div id=\"bat-$rn\" style=\"height:100%;width:100%;background:#7ee787;transition:width .1s linear\"></div></div>" *
            "<span id=\"batp-$rn\" style=\"width:34px;text-align:right;color:#7ee787\">100%</span></div>"
    end, "")
    data = JSON3.write(Dict("r" => nums, "s" => mat, "swap" => collect(swapped)))
    script = """
    <script>
    (function(){
      var D = $data, R = D.r, S = D.s, N = S.length, SW = D.swap||[];
      function isSwap(rn){ return SW.indexOf(rn) >= 0; }
      function col(s){ return s<=0.25?'#ff6b6b':(s<=0.5?'#ffb454':'#7ee787'); }
      function playhead(){
        var an = window.viewer && window.viewer.animator; if(!an) return {t:0,d:0};
        var acts = an.actions||[], t=0, d=an.duration||0;
        for(var i=0;i<acts.length;i++){ t=Math.max(t, acts[i].time||0);
          if(acts[i]._clip){ d=Math.max(d, acts[i]._clip.duration||0); } }
        return {t:t, d:d};
      }
      function socAt(frac){
        if(N===0) return null;
        var x=frac*(N-1), i=Math.floor(x), g=x-i;
        var a=S[Math.max(0,Math.min(N-1,i))], b=S[Math.max(0,Math.min(N-1,i+1))], o=[];
        for(var k=0;k<R.length;k++){ o.push(a[k]+(b[k]-a[k])*g); } return o;
      }
      function tick(){
        var p=playhead(), frac=p.d>0?Math.max(0,Math.min(1,p.t/p.d)):0, soc=socAt(frac);
        if(soc){ for(var k=0;k<R.length;k++){ var s=soc[k]; if(s==null||isNaN(s)) continue;
          var pct=Math.round(100*Math.max(0,Math.min(1,s)));
          var c = isSwap(R[k]) ? '#58a6ff' : col(s);      // hot-swapped worker -> blue (distinct from SoC colors)
          var bar=document.getElementById('bat-'+R[k]), lab=document.getElementById('batp-'+R[k]);
          if(bar){ bar.style.width=pct+'%'; bar.style.background=c; }
          if(lab){ lab.textContent=pct+'%'; lab.style.color=c; } } }
        requestAnimationFrame(tick);
      }
      requestAnimationFrame(tick);
    })();
    </script>
    """
    return (bars, script)
end

# left sidebar wrapper: shrinks #meshcat-pane and docks the two cards beside it (no overlap).
# _sidebar : 배터리 HUD + stall/교체 로그 두 카드를 왼쪽에 고정 배치(3D 화면을 줄여 옆에 붙임). 이전 데모와 같은 구조.
function _sidebar(log_html, batt_html, batt_script)
    batt_card = isempty(batt_html) ? "" :
        "<div class=\"cb-card\"><div class=\"cb-title\">🔋 Battery SoC — per robot" *
        " <span style=\"color:#8891a5;font-weight:400\">(live · red ≤25% · orange ≤50% · <span style=\"color:#58a6ff\">blue &#8646; = hot-swapped</span> · spares stay full)</span></div>" *
        batt_html * "</div>"
    log_card =                                            # stall→교체 로그 카드
        "<div class=\"cb-card\"><div class=\"cb-title\">BATTERY STALL → SPARE REPLACE" *
        " <span style=\"color:#8891a5;font-weight:400\">(SoC=0 → OOD → DSL ReplaceAgent → depot spare)</span></div>" *
        "<div class=\"cb-log\">$log_html</div></div>"
    return """
    <style>
      #meshcat-pane { width: calc(100vw - $(SIDEBAR_W)px) !important; margin-left: $(SIDEBAR_W)px !important; }
      #cb-sidebar { position:fixed; top:0; left:0; width:$(SIDEBAR_W)px; height:100vh; box-sizing:border-box;
        overflow-y:auto; background:#0b0e15; border-right:1px solid #2a3346; z-index:99999;
        font:11px/1.45 ui-monospace,Consolas,monospace; padding:9px; }
      #cb-sidebar .cb-card { background:rgba(16,18,26,.92); border-radius:8px; padding:8px 10px;
        margin-bottom:9px; box-shadow:0 2px 10px rgba(0,0,0,.5); }
      #cb-sidebar .cb-title { color:#9bd1ff; font-weight:700; margin-bottom:6px; }
      #cb-sidebar .cb-log { max-height:56vh; overflow:auto; white-space:pre-wrap; }
    </style>
    <div id="cb-sidebar">$batt_card$log_card</div>
    <script>
      (function(){ function fit(){ try{ window.dispatchEvent(new Event('resize')); }catch(e){} }
        window.addEventListener('load', function(){ fit(); setTimeout(fit,80); setTimeout(fit,500); });
        setTimeout(fit,150); })();
    </script>
    $batt_script
    """
end

# 저장된 HTML 에 배터리 HUD + stall/교체 로그 사이드바 삽입. swapped_ids=교체(hot-swap)된 로봇 번호들(파란 배지용).
htmlpath = joinpath("results", pp[:project_name], "greedy_RVO_Dispersion_TangentBug", "visualization.html")
if isfile(htmlpath)
    html  = read(htmlpath, String)
    swapped_ids = Set{Int}(try Int(k.id) catch; 0 end for k in keys(CB.decommissioned_bodies()))   # 교체돼 창고로 간 본체들의 id
    bars, bscript = _battery_live(SOC_HISTORY, swapped_ids)
    panel = _sidebar(_log_rows(_PIPE), bars, bscript)
    html  = occursin("</body>", html) ? replace(html, "</body>" => panel * "\n</body>"; count = 1) : html * panel
    write(htmlpath, html)
    println(">>> embedded sidebar (LIVE per-robot battery over $(length(SOC_HISTORY)) frames + $(length(_PIPE))-line stall/replace log).")
end
println(">>> done. Open: $htmlpath")
OPEN_ANIM && isfile(htmlpath) && (try run(`cmd /c start "" $(abspath(htmlpath))`) catch e; @warn "auto-open failed; open manually: $e" end)
end   # demo_energy_stall_replace 끝

# =============================================================================
# surrogate_stream -- the LEARNED SURROGATE WORLD MODEL adapting to a STREAM of DIFFERENT
#   OOD events (fault / battery / zone) at random build-progress points, with a live battery-SoC
#   HUD in a docked sidebar. At EVERY event the surrogate predicts the re-plan outcome for all 5
#   DSL macros in imagination (0 true-planner calls), ranks, and enacts the argmax.
#   NOTE: keeps its OWN MILP block (60s/0.05 gap/output_flag). ENV: OOD_N, OOD_KINDS, OOD_SEED,
#   NSPARE, SEED, GRID_SCALE, SHRINK, STALL_SOC, OPEN_ANIM, SAVE_ANIM, SIDEBAR_W, NOPROG,
#   CARRIER_RESCUE, HOT_SWAP, REFORM_INTERVAL, SURROGATE.
# =============================================================================
# demo_surrogate_stream : 학습된 surrogate 세계모델이 "서로 다른 종류의 OOD가 줄줄이(stream) 터지는" 상황에 적응하는 데모.
#   무작위 진행지점마다 고장/배터리/구역 사건이 발생하고, 매 사건마다 surrogate 가 5개 매크로를 상상으로 예측·랭킹·실행(플래너 0호출).
#   로봇별 배터리 SoC HUD + OOD 타임라인 + surrogate 추론 로그를 사이드바로 보여준다. forest(랜덤포레스트) surrogate 도 읽는다.
#   ENV: OOD_N, OOD_KINDS, OOD_SEED, NSPARE, SEED, GRID_SCALE, SHRINK, STALL_SOC, OPEN_ANIM, SAVE_ANIM,
#        SIDEBAR_W, NOPROG, CARRIER_RESCUE, HOT_SWAP, REFORM_INTERVAL, SURROGATE.
function demo_surrogate_stream()
_EXAMPLES = joinpath(dirname(pkgdir(CB)), "decpomdp", "examples")
# navigator.jl + decpomdp examples are now loaded ONCE at module top (world-age).

OOD_N      = parse(Int, get(ENV, "OOD_N", "4"))          # 스트림에 넣을 OOD 사건 개수
# OOD_KINDS : "fault,battery,zone" 를 콤마로 쪼개 각각 Symbol 로. strip=공백제거. 컴프리헨션으로 배열 생성.
OOD_KINDS  = [Symbol(strip(s)) for s in split(get(ENV, "OOD_KINDS", "fault,battery,zone"), ",")]
OOD_SEED   = parse(Int, get(ENV, "OOD_SEED", "3"))
NSPARE     = parse(Int, get(ENV, "NSPARE", "3"))
SEED       = parse(Int, get(ENV, "SEED", "1"))
GRID_SCALE = parse(Float64, get(ENV, "GRID_SCALE", "4.0"))
# MUST match the oracle data-gen's battery physics (DS_SHRINK / DS_STALL).
SHRINK     = parse(Float64, get(ENV, "SHRINK", "200.0"))    # == DS_SHRINK
STALL_SOC  = parse(Float64, get(ENV, "STALL_SOC", "0.15"))  # == DS_STALL
OPEN_ANIM  = get(ENV, "OPEN_ANIM", "1") == "1"
SAVE_ANIM  = get(ENV, "SAVE_ANIM", "1") == "1"
SIDEBAR_W  = parse(Int, get(ENV, "SIDEBAR_W", "380"))
NOPROG     = parse(Int, get(ENV, "NOPROG", "6000"))   # no-progress cap
RESCUE     = get(ENV, "CARRIER_RESCUE", "0") == "1"   # see force_advance_stuck_carrier!

# Pin the project name so the animation and the injected panels land in the same results/ folder.
PROJECT    = "tractor"
HTMLPATH   = joinpath("results", PROJECT, "greedy_RVO_Dispersion_TangentBug", "visualization.html")
SURRO_PATH = get(ENV, "SURROGATE",
    joinpath(pkgdir(CB), "wm4spacecraft_manufacturing", "surrogate_linear.json"))   # wm4 는 2026-07-31 부터 repo 내부
MACROS = [0, 1, 2, 3, 4]
MACRO_NAME = Dict(0=>"NOOP", 1=>"Replace", 2=>"Deprioritize", 3=>"ForbidZone", 4=>"ReformTeam")

# NOTE: surrogate demos use a DIFFERENT MILP config than _setup_milp! (kept verbatim).
CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 60.0, "mip_rel_gap" => 0.05,
    "output_flag" => false, "presolve" => "on")

# ---- the learned surrogate: y_hat = coef . ((x - mean)/scale) + intercept ----------------
SURRO = JSON3.read(read(SURRO_PATH, String))
FEATNAMES = String.(SURRO["feature_names"])
IS_FOREST = get(SURRO, "kind", "linear") == "forest"
println(">>> surrogate: $(IS_FOREST ? "RandomForest ($(length(SURRO["trees"])) trees)" : "Ridge"), " *
        "$(length(FEATNAMES)) features, $(SURRO["meta"]["n_instances"]) instances, " *
        "LOO decision-regret=$(round(Float64(SURRO["meta"]["loo_decision_regret"]); digits=3))")
haskey(SURRO["meta"], "kinds") && println(">>> trained on OOD kinds: $(SURRO["meta"]["kinds"])")

# A FOREST, not a line. The graded task flips the correct macro at a THRESHOLD.
# _tree_predict : 결정트리 하나로 예측. 뿌리에서 시작해 feature<=threshold 면 왼쪽, 아니면 오른쪽으로 내려가 잎값 반환.
#   (선형이 아니라 트리라야 "임계값에서 정답 매크로가 뒤집히는" graded 과제를 표현 가능.)
function _tree_predict(t, x::Vector{Float64})
    left = t["left"]; right = t["right"]; feat = t["feature"]; thr = t["threshold"]; val = t["value"]  # 트리 배열들
    i = 1                                              # Julia is 1-based; sklearn's arrays are 0-based  # Julia 1시작 vs sklearn 0시작
    while feat[i] >= 0                                 # feat<0 = 잎(leaf) 노드
        i = x[feat[i] + 1] <= thr[i] ? left[i] + 1 : right[i] + 1   # +1 = 0기반 인덱스를 1기반으로 보정
    end
    return Float64(val[i])                             # 잎의 예측값
end

# surrogate_predict : forest 면 모든 트리 예측의 평균, 아니면 위와 같은 선형모델. IS_FOREST 로 분기.
function surrogate_predict(x::Vector{Float64})
    if IS_FOREST
        trees = SURRO["trees"]
        return sum(_tree_predict(t, x) for t in trees) / length(trees)   # 트리들 평균(앙상블)
    end
    m = Float64.(SURRO["mean"]); s = Float64.(SURRO["scale"]); c = Float64.(SURRO["coef"])
    return LinearAlgebra.dot(c, (x .- m) ./ ifelse.(s .== 0.0, 1.0, s)) + Float64(SURRO["intercept"])
end

"""
    surrogate_member_scores(feats_by_macro) -> Vector{Vector{Float64}}

Per-TREE scores for each candidate macro, shaped for `escalation_verdict(member_values=...)`.

WHY: averaging the trees (above) throws away the single most useful runtime signal there is.
Measured on 60 leave-one-kind-out instances (`openworld_experiments.py gate`), how split the
forest is about WHICH macro wins predicts the surrogate's actual error better than covariate
novelty and better than the decision margin -- it beat a same-budget random control at every
budget, reaching regret 0 while verifying only 10% of decisions with the true planner.

`feats_by_macro` is an ordered vector of feature rows, one per candidate macro (SAME order the
caller will interpret the votes in). Returns one inner vector per tree, holding that tree's score
for each macro -- so `vote_disagreement` can count each tree's argmax.

Falls back to a single "member" for a linear export, which correctly reports zero disagreement
(a linear model has no internal spread to measure).

(요약) 나무들의 예측을 평균내 버리면 "나무들이 서로 갈리는가"라는 정보가 사라진다. 그 정보가
  런타임에서 가장 쓸모있는 신호로 측정됐다 -- 같은 예산의 무작위 대조군을 모든 예산에서 이겼고,
  결정의 10%만 진짜 플래너로 확인해도 손해 0 을 달성했다. 그래서 평균 이전의 나무별 점수를 그대로
  돌려주는 함수를 따로 둔다. 선형 export 면 멤버가 하나뿐이라 '이견 0' 으로 정확히 보고된다.
"""
function surrogate_member_scores(feats_by_macro::Vector{Vector{Float64}})
    if !IS_FOREST
        return [[surrogate_predict(x) for x in feats_by_macro]]   # 멤버 1개 = 이견 0
    end
    trees = SURRO["trees"]
    return [[_tree_predict(t, x) for x in feats_by_macro] for t in trees]
end

# agent_pending_tasks : 특정 로봇의 남은 운반작업 수(데이터셋이 쓴 결과 근사값). demo_surrogate 의 동명 함수와 같은 역할.
function agent_pending_tasks(env, agent)                # consequence proxy used by the dataset
    agent === nothing && return -1.0
    sched = env.sched; n = 0
    for v in Graphs.vertices(sched)
        node = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        (node isa CB.RobotGo && CB.bound_to_agent(node, agent)) || continue
        v in env.cache.closed_set && continue
        outs = Graphs.outneighbors(sched, v); isempty(outs) && continue
        CB.get_node_from_id(sched, CB.get_vtx_id(sched, outs[1])) isa CB.FormTransportUnit || continue
        n += 1
    end
    return Float64(n)
end

# severity of the event currently being handled (set by the injector)
# CUR_SEV : 지금 처리 중인 사건의 심각도(severity) 상자. 사건 주입기(injector)가 값을 넣고 features 가 읽는다.
CUR_SEV = Ref(1.0)

# Fraction of a PENDING staging circle the zone actually covers — the physical severity of a zone event.
# zone_overlap_frac : 금지구역이 "아직 안 놓인" staging 원을 얼마나 덮는지 그 넓이 비율(0~1)을 계산 = zone 사건의 물리적 심각도.
#   두 원의 교집합 넓이 공식을 직접 계산한다(아래 area 부분).
function zone_overlap_frac(env, zkey)
    z = try CB.RESTRICTION_ZONES[][zkey] catch; nothing end
    z === nothing && return -1.0
    zc = Vector{Float64}(CB.get_center(z)[1:2]); zr = Float64(CB.get_radius(z))   # 구역 중심/반지름
    best = 0.0
    for (aid, ball) in env.staging_circles
        ac = try CB._assembly_complete_node(env, aid) catch; nothing end
        ac === nothing && continue
        v = try CB.get_vtx(env.sched, CB.node_id(ac)) catch; nothing end
        (v === nothing || v in env.cache.closed_set) && continue
        bc = Vector{Float64}(CB.get_center(ball)[1:2]); br = Float64(CB.get_radius(ball))   # 조립물 원 중심/반지름
        d = sqrt(sum((bc .- zc) .^ 2)); d >= br + zr && continue   # 두 중심 거리. 안 겹치면 건너뜀
        # 겹침 넓이: 한 원이 다른 원 안에 완전히 들어가면 작은 원 넓이, 아니면 원-원 교집합(렌즈) 넓이 공식.
        area = d <= abs(br - zr) ? π * min(br, zr)^2 : begin
            a1 = acos(clamp((d^2 + zr^2 - br^2) / (2d * zr), -1.0, 1.0))   # clamp=범위밖 값 잘라 acos 안전하게
            a2 = acos(clamp((d^2 + br^2 - zr^2) / (2d * br), -1.0, 1.0))
            zr^2 * (a1 - sin(2a1) / 2) + br^2 * (a2 - sin(2a2) / 2)
        end
        best = max(best, area / (π * br^2))              # 조립물 원 대비 덮인 비율 중 최댓값
    end
    return best
end

# features : surrogate 입력 특징벡터 생성(demo_surrogate 버전에 zone_overlap 특징이 추가된 확장판). 상호작용 열도 처리.
function features(env, ctx, macro_id::Int)
    closed = length(env.cache.closed_set)
    total  = length(CB.get_nodes(env.sched))
    valid  = valid_actions(ctx)
    zrad = ctx.type === :zone ?                          # 구역 사건이면 구역 반지름, 아니면 -1(해당없음)
        (try Float64(CB.get_radius(CB.RESTRICTION_ZONES[][ctx.zone])) catch; -1.0 end) : -1.0
    zovl = ctx.type === :zone ? (try zone_overlap_frac(env, ctx.zone) catch; -1.0 end) : -1.0   # 겹침비율
    soc  = ctx.type === :battery ? Float64(ctx.soc) : -1.0   # 배터리 사건이면 SoC
    d = Dict{String,Float64}(
        "kind_fault"     => ctx.type === :fault   ? 1.0 : 0.0,
        "kind_battery"   => ctx.type === :battery ? 1.0 : 0.0,
        "kind_zone"      => 0.0,
        "kind_zoneblk"   => ctx.type === :zone    ? 1.0 : 0.0,
        "severity"       => CUR_SEV[],      # nominal, exactly as the dataset records it per kind
        "n_spare_cfg"    => Float64(NSPARE),
        "spare_count"    => Float64(try length(CB.active_spares()) catch; 0 end),
        "progress"       => total > 0 ? closed / total : 0.0,
        "agent_pending"  => agent_pending_tasks(env, ctx.agent),
        "closed_at_fire" => Float64(closed),
        "n_active"       => Float64(length(env.cache.active_set)),
        "soc"            => soc,
        "zone_radius"    => zrad,
        "zone_overlap"   => zovl,
        "macro_in_valid" => (macro_id in valid) ? 1.0 : 0.0,
    )
    for m in MACROS; d["macro_$(m)"] = (m == macro_id) ? 1.0 : 0.0; end   # 후보 매크로 원-핫
    # interaction terms `<state>__x__macro_<m>` (export_surrogate.py::add_interactions).
    # 상호작용 항목(예: soc__x__macro_1)은 get_feature 가 두 열을 곱해 만든다.
    return [get_feature(d, f) for f in FEATNAMES]
end

# get_feature : 특징 이름으로 값 조회. 이름에 "__x__" 가 있으면 두 기본특징을 곱한 상호작용 항으로 계산. 못 만들면 에러.
function get_feature(d::Dict{String,Float64}, name::AbstractString)
    haskey(d, name) && return d[name]                    # 기본 특징이면 그대로
    parts = split(name, "__x__")                         # 상호작용 항 이름 쪼개기
    length(parts) == 2 && haskey(d, parts[1]) && haskey(d, parts[2]) &&
        return d[parts[1]] * d[parts[2]]                 # 두 특징의 곱
    error("surrogate wants feature '$name' but the demo cannot build it")
end

_PIPE = String[]                 # engine + surrogate log (sidebar card 2)  # 엔진+surrogate 로그(사이드바 카드2)
_TIMELINE = String[]             # one row per OOD event (sidebar card 1)   # OOD 사건별 한 줄(사이드바 카드1)
# (robot, post-drop SoC, HUD frame index) for each battery OOD, so the HUD can HOLD the critical bar.
# BATT_CRIT : 배터리 OOD 마다 (로봇, 떨어진 직후 SoC, HUD 프레임번호) 튜플 저장 → HUD 가 그 순간 낮은 값을 잠깐 "붙잡아" 보여줌.
BATT_CRIT = Vector{Tuple{Any,Float64,Int}}()
_say(s) = (push!(_PIPE, s); @info s)   # 로그 수집+출력 동시

# ---- THE PRODUCER: score every macro in imagination, enact the argmax --------------------
# surrogate_producer : 핵심 결정자. 사건마다 5매크로를 surrogate 로 예측·랭킹·최고 실행 + 타임라인/로그 기록. (플래너 0호출)
_EVENT_NO = Ref(0)               # 몇 번째 OOD 인지 카운터
function surrogate_producer(env, event)
    ctx = event_context(env, event)
    if !(ctx.type in (:fault, :battery, :zone))
        return action_to_proposal(ctx, canonical_action(ctx))     # background (:reform): canonical  # 배경 사건=기본대응
    end
    _EVENT_NO[] += 1
    k = _EVENT_NO[]; closed = length(env.cache.closed_set)
    scores = Dict(m => surrogate_predict(features(env, ctx, m)) for m in MACROS)   # 매크로별 상상 점수
    best   = argmax(m -> scores[m], MACROS)                        # 최고 점수 매크로
    ranked = sort(MACROS, by = m -> -scores[m])                    # 내림차순 랭킹
    detail = ctx.type === :battery ? @sprintf("SoC=%.2f", Float64(ctx.soc)) :
             ctx.type === :zone    ? "no-go zone" : "robot down"
    _say("[OOD #$k] @closed=$closed  kind=$(uppercase(String(ctx.type)))  ($detail)")
    _say("[SURROGATE] imagined outcome (predicted closed nodes) — NO planner call:")
    for m in ranked
        _say(@sprintf("           %-13s %7.1f%s", MACRO_NAME[m], scores[m], m == best ? "   <= CHOSEN" : ""))
    end
    # ---- ESCALATION GATE: 이 결정을 그냥 믿을 것인가, 진짜 플래너로 확인할 것인가 ----------
    # 여기까지 계산은 전부 "상상"이고 플래너 호출 0회다. 문제는 처음 보는 상황에서 그 상상이 틀릴 수
    # 있다는 것. 그래서 두 가지를 본다: ① 나무들이 서로 갈리는가(모델 내부 이견) ② 입력이 학습 때
    # 범위를 벗어났는가(낯섦도). 측정상 ①이 더 강한 신호이고, ②는 상보적이라 둘 중 하나라도 걸리면
    # 승격한다. 여기서는 판정만 로그로 남긴다 -- 실제 오라클 호출 배선은 별개 작업이고, 조용히
    # 켰다고 말하지 않기 위해 판정과 집행을 분리해 둔다.
    members = surrogate_member_scores([features(env, ctx, m) for m in MACROS])
    gate = CB.escalation_verdict(values = [scores[m] for m in MACROS], member_values = members)
    _say(@sprintf("[GATE] 모델 내부 이견=%.2f  결정 마진=%.2f  ->  %s (%s)",
                  isnan(gate.disagreement) ? 0.0 : gate.disagreement,
                  isnan(gate.margin) ? 1.0 : gate.margin,
                  gate.escalate ? "진짜 플래너로 확인 권고" : "surrogate 결정 신뢰", String(gate.reason)))

    _say("[SURROGATE] enacting $(MACRO_NAME[best])  (0 true-planner calls)")
    push!(_TIMELINE, @sprintf("#%d  closed=%-3d  %-8s %-12s  →  %s", k, closed,
          uppercase(String(ctx.type)), detail, MACRO_NAME[best]))
    # MONITOR: surrogate 가 상상한 5매크로 랭킹을 대시보드 respec 패널로 흘려보냄(비활성 시 무해).
    try
        CB.monitor_record_respec!(;
            at    = closed,
            input = Dict("event" => uppercase(String(ctx.type)), "detail" => detail,
                         "closed_nodes" => closed, "macros" => [MACRO_NAME[m] for m in MACROS]),
            candidates = [Dict("rank" => i, "macro" => MACRO_NAME[m],
                               "score" => round(Float64(scores[m]); digits = 1),
                               "chosen" => (m === best), "verified" => (m === best))
                          for (i, m) in enumerate(ranked)],
            chosen  = MACRO_NAME[best],
            verdict = "ADMITTED · surrogate (0 planner calls)")
    catch err
        @warn "[monitor] respec record skipped" exception = err
    end
    return action_to_proposal(ctx, best)
end

# ---- OOD STREAM: several events of DIFFERENT kinds at random build-progress points --------
# place_blocking_zone! : demo_surrogate 의 동명 함수와 같음 — 아직 안 놓인 조립물 원 위에 금지구역을 겹쳐 놓고 자연어 반환.
function place_blocking_zone!(env; key::Symbol, frac::Float64 = 0.9)
    isempty(env.staging_circles) && return nothing
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))
    for (aid, ball) in env.staging_circles
        aid == root && continue
        ac = try CB._assembly_complete_node(env, aid) catch; nothing end
        ac === nothing && continue
        v = try CB.get_vtx(env.sched, CB.node_id(ac)) catch; nothing end
        v === nothing && continue
        (v in env.cache.closed_set || v in env.cache.active_set) && continue
        c = Vector{Float64}(CB.get_center(ball)[1:2]); r = Float64(CB.get_radius(ball))
        z = CB.add_restriction_zone!(key, c, r * frac)
        nl = "A no-go exclusion zone has appeared at ($(round(c[1];digits=2)), $(round(c[2];digits=2))) " *
             "blocking a staging area; restage the affected assembly out of the restricted region."
        try CB.record_ood_truth!(nl, CB.ZoneTruth(key, Float64[c[1], c[2]], Float64(CB.get_radius(z)), aid)) catch end
        return nl
    end
    return nothing
end

# evenly spaced progress points with jitter (same idea as navigator/ood_stream.jl)
# stream_points : lo~hi 사이를 n 등분한 지점들에 약간의 무작위 흔들림(jitter)을 더해 정렬해 돌려준다(사건 발생 진행지점).
function stream_points(n, lo, hi, rng)
    n <= 0 && return Int[]
    span = max(hi - lo, 1)                            # 전체 폭(0 방지)
    # 각 i 등분점 + [-폭/2n, +폭/2n] 흔들림을 lo~hi 로 clamp. rand(rng)=0~1 난수.
    sort([clamp(lo + round(Int, span * (i - 0.5) / n) +
                round(Int, (2rand(rng) - 1) * span / (2n)), lo, hi) for i in 1:n])
end

# n kinds drawn WITHOUT replacement (cycling the list if n > #kinds), then shuffled.
# shuffle_kinds : 사건 종류들을 "중복 없이"(부족하면 목록을 반복해 채운 뒤) 섞어 n 개 뽑는다.
#   4개 스트림이 정말 4가지 다른 disruption 이 되도록.
function shuffle_kinds(rng, kinds, n)
    bag = Symbol[]
    while length(bag) < n
        append!(bag, Random.shuffle(rng, collect(kinds)))   # 종류 목록을 섞어 봉지에 추가
    end
    return bag[1:n]                                   # 앞에서 n 개
end

# schedule_stream! : OOD 스트림을 짜서 예약한다. 종류별로 다른 액션(고장/배터리/구역)을 만들고 각 진행지점에 한 번씩 발동.
#   반환은 사람이 읽는 계획 문자열 목록(예: "fault@40  battery@90 ...").
function schedule_stream!()
    rng  = Random.MersenneTwister(OOD_SEED)          # 스트림 전용 난수(재현성)
    # Spread the events across the WHOLE build (it closes ~291 nodes).
    pts  = stream_points(OOD_N, 20, 190, rng)        # 발생 진행지점들(완료노드 20~190 사이)
    # Draw kinds WITHOUT replacement so a 4-event stream really is 4 DIFFERENT disruptions.
    bag  = shuffle_kinds(rng, OOD_KINDS, OOD_N)       # 각 지점에 배정할 사건 종류들
    zct  = Ref(0)                                    # 구역 사건 카운터(고유 key 만들기용)
    plan = String[]
    for (i, p) in enumerate(pts)                     # enumerate=(순번 i, 값 p) 쌍으로 순회
        kind = bag[i]
        # act = 이 사건이 발동될 때 실행할 함수. 종류에 따라 다르게 구성(if 식이 함수를 반환).
        act = if kind === :fault
            # clear=false: keep the faulted robot's scene node so ReplaceAgent can hot-swap it.
            # clear=false: 고장 로봇의 장면노드를 남겨둬 ReplaceAgent 가 hot-swap 할 수 있게.
            tf = CB.fault_action(; safe = true, obstacle = false, clear = false)
            e -> (CUR_SEV[] = 1.0; tf(e))            # 심각도 1.0 설정 후 고장 실행
        elseif kind === :battery
            # the SEVERITY LADDER measured by the oracle (GRADED_OOD_DESIGN.md §2.1).
            # 오라클이 측정한 심각도 사다리: SoC 를 세 단계 중 하나로 떨어뜨림(0.05/0.20/0.55).
            soc  = [0.05, 0.20, 0.55][rand(rng, 1:3)]   # 세 값 중 무작위 하나
            drop = 1.0 - soc                          # 떨어뜨릴 양
            bf = CB.battery_action(soc_drop = drop)
            e -> begin
                CUR_SEV[] = soc                       # 이 사건의 심각도 = 떨어진 SoC
                f = CB.BATTERY_FLEET[]
                before = f === nothing ? Dict{Any,Float64}() : copy(f.soc)   # 떨어뜨리기 전 SoC 스냅샷
                nl = bf(e)                                   # drops a robot's SoC (may then be hot-swapped -> reset to 1.0)  # 어떤 로봇 SoC 떨굼
                f2 = CB.BATTERY_FLEET[]
                if f2 !== nothing
                    dropped = [id for (id, s) in f2.soc if get(before, id, s) - s > 0.05]   # 실제로 크게 떨어진 로봇들
                    if !isempty(dropped)
                        rid = argmax(id -> get(before, id, 0.0) - f2.soc[id], dropped)      # 가장 많이 떨어진 로봇
                        push!(BATT_CRIT, (rid, f2.soc[rid], length(SOC_HISTORY)))  # for the HUD critical-hold  # HUD 강조용 기록
                    end
                end
                nl
            end
        else
            zct[] += 1; key = Symbol("zone_stream_$(zct[])")   # 구역마다 고유 key
            e -> (CUR_SEV[] = 0.9; place_blocking_zone!(e; key = key, frac = 0.9))
        end
        fired = Ref(false)
        # 각 지점에 예약. 한 번만 발동(one-shot)하되 자연어가 안 나오면(아직 대상 없음) 다음 점검 때 재시도.
        CB.schedule_ood_at_closed!(p, e -> begin                 # one-shot, retried at later checks
            fired[] && return nothing
            nl = act(e)
            (nl === nothing || isempty(nl)) && return nothing
            fired[] = true; return nl
        end)
        push!(plan, "$(kind)@$(p)")                   # 계획 로그에 "종류@지점" 추가
    end
    println(">>> OOD STREAM (seed=$OOD_SEED): " * join(plan, "  "))
    return plan
end

# ---- wire the seam + the battery layer ----------------------------------------------------
CB.RESPEC_ENABLED[] = true
for f in (:clear_ood_schedule!, :clear_restriction_zones!, :clear_spare_pools!, :clear_faulted_robots!,
          :clear_recovery_spares!, :clear_ood_truth_log!, :clear_wedge_edges!, :clear_stalled_robots!,
          :clear_agent_bias!)
    try getproperty(CB, f)() catch end
end
try CB.set_reform_interval!(parse(Int, get(ENV, "REFORM_INTERVAL", "120"))) catch end
# HOT_SWAP=1 (default): enact a fault-event Replace as an identity-preserving depot hot-swap.
# HOT_SWAP=1(기본): 고장 교체를 "id 유지·몸체만 창고서 교체"하는 정체성보존 방식으로(스케줄 재작성 없이 완주).
if get(ENV, "HOT_SWAP", "1") == "1"
    CB.set_hot_swap!(enabled = true, mode = Symbol(get(ENV, "HOT_SWAP_MODE", "via_depot")))
    println(">>> HOT_SWAP ON: fault Replace -> identity-preserving depot swap (no re-stamp, completes).")
else
    CB.set_hot_swap!(enabled = false)
end
CB.set_respec_producer!(surrogate_producer)          # 결정자 = surrogate 등록

# per-step SoC snapshots -> the live, playhead-synced battery HUD
SOC_HISTORY = Vector{Dict{Any,Float64}}()
CB.schedule_ood!(1, function (env)
    CB.enable_battery!(env; params = CB.demo_battery_params(shrink = SHRINK))
    CB.set_battery_stall!(enabled = true, threshold = STALL_SOC, clear = true, obstacle = false)
    CB.BATTERY_STEP_HOOK[] = function (e, prev)
        CB.account_battery_step!(e, prev)
        f = CB.BATTERY_FLEET[]; f === nothing || push!(SOC_HISTORY, copy(f.soc))
        return nothing
    end
    @info "[DEMO] battery ON ($(length(CB.BATTERY_FLEET[].soc)) robots incl spares), stall<=$STALL_SOC"
    return nothing
end)
schedule_stream!()   # OOD 스트림 예약

# Remove any previous render (so a failed run leaves NO stale html).
# 이전 실행 HTML 을 지운다 — 실행 실패 시 낡은 결과가 남아 오해하지 않도록.
isfile(HTMLPATH) && (rm(HTMLPATH); println(">>> removed stale $(HTMLPATH)"))

println(">>> SURROGATE + OOD-STREAM demo: $(OOD_N) events from $(OOD_KINDS), spares=$(4*NSPARE)")
println(">>> the surrogate ranks all 5 DSL macros in imagination at EVERY event — no planner call.")

run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file = "tractor.mpd", project_name = PROJECT, num_robots = 10, assignment_mode = :greedy,
        milp_optimizer = :highs, optimizer_time_limit = 60, log_level = Logging.Info,
        max_num_iters_no_progress = NOPROG, rvo_flag = true, tangent_bug_flag = true,
        dispersion_flag = true, n_spare_per_pool = NSPARE,
        save_animation = SAVE_ANIM, open_animation_at_end = false, update_anim_at_every_step = SAVE_ANIM,
        anim_active_agents = true, anim_active_areas = true, grid_scale = GRID_SCALE, log_sink = _PIPE,
        save_animation_along_the_way = false, write_results = false, overwrite_results = true,
        look_for_previous_milp_solution = false, save_milp_solution = false,
        return_env_before_sim = false, rng = Random.MersenneTwister(SEED))
end

batt = CB.BATTERY_FLEET[] === nothing ? nothing : CB.battery_report()
batt === nothing || push!(_PIPE, "[BATTERY] min_soc=$(round(batt.min_soc,digits=3)) n_depleted=$(batt.n_depleted)")
push!(_PIPE, "[STALL] robots stalled this run: $(length(CB.stalled_robots()))")

# Prove the SoC series actually MOVES before we ship bars that claim to show it.
# 배터리 막대를 내보내기 전, SoC 이력이 실제로 "변했는지" 확인 로그(처음 vs 마지막 프레임의 하락량 상위 몇 개).
if !isempty(SOC_HISTORY)
    lastf = SOC_HISTORY[findlast(!isempty, SOC_HISTORY)]     # 마지막 유효 프레임
    firstf = SOC_HISTORY[findfirst(!isempty, SOC_HISTORY)]   # 처음 유효 프레임
    drops = [(k, get(firstf, k, 1.0) - v) for (k, v) in lastf]   # 로봇별 하락량
    sort!(drops; by = x -> -x[2])                           # 많이 떨어진 순으로 정렬(제자리 정렬 sort!)
    println(">>> SoC over $(length(SOC_HISTORY)) frames: final min=$(round(minimum(values(lastf)); digits=3)) " *
            "max=$(round(maximum(values(lastf)); digits=3)); biggest drains: " *
            join(["R$(try Int(k.id) catch; 0 end) -$(round(d; digits=2))" for (k, d) in drops[1:min(4, end)]], ", "))
end

CB.RESPEC_ENABLED[] = false; CB.clear_respec_producer!()
CB.clear_ood_schedule!(); CB.clear_restriction_zones!(); CB.clear_spare_pools!(); CB.clear_faulted_robots!()
CB.BATTERY_ACCOUNTING[] = false; CB.BATTERY_STEP_HOOK[] = nothing; CB.EDGE_COST_MULTIPLIER[] = nothing
CB.SOC_SPEED_HOOK[] = nothing; CB.set_battery_stall!(enabled = false); CB.clear_stalled_robots!()

# ================= sidebar (docked, does NOT overlap the 3D scene) =========================
_esc(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")

# _timeline_rows : OOD 타임라인 각 줄을 종류별 색으로(FAULT=빨강, BATTERY=보라, ZONE=호박) HTML 화.
function _timeline_rows(rows)
    isempty(rows) && return "<div style=\"color:#8891a5\">(no OOD events fired)</div>"
    join(map(rows) do ln
        c = occursin("FAULT", ln) ? "#ff9b9b" : occursin("BATTERY", ln) ? "#f0a0ff" :
            occursin("ZONE", ln) ? "#ffd479" : "#d8e0ee"
        "<div style=\"color:$c;margin:3px 0\">$(_esc(ln))</div>"
    end, "")
end

# _log_rows : surrogate/엔진 로그 줄들을 색깔 HTML 로(중복은 ×N 로 접음). 다른 데모의 _log_rows 와 같은 역할.
function _log_rows(lines)
    isempty(lines) && return "<div style=\"color:#8891a5\">(empty)</div>"
    order = String[]; counts = Dict{String,Int}()
    for ln in lines
        haskey(counts, ln) || push!(order, ln); counts[ln] = get(counts, ln, 0) + 1
    end
    join(map(order) do ln
        c = occursin("[OOD #", ln) ? "#ffd479" :
            occursin("CHOSEN", ln) || occursin("enacting", ln) ? "#7ee787" :
            occursin("[SURROGATE]", ln) ? "#c9d1d9" :
            occursin("STALL", ln) ? "#ff7b72" :
            (occursin("ADMITTED", ln) || occursin("spare", ln) || occursin("restage", ln) ||
             occursin("replace", ln)) ? "#79c0ff" :
            occursin("BATTERY", ln) ? "#f0a0ff" :
            (occursin("declined", ln) || occursin("REJECTED", ln)) ? "#ff9b9b" : "#8b949e"
        n = counts[ln]; badge = n > 1 ? " <span style=\"opacity:.5\">×$n</span>" : ""
        "<div style=\"color:$c;margin:2px 0\">$(_esc(ln))$badge</div>"
    end, "")
end

# LIVE per-robot SoC bars, interpolated against the MeshCat playhead (one history entry per frame)
# _battery_live : 로봇별 SoC 막대 + 재생위치 동기화 JS 생성. 여기선 "한 번이라도 위험(<=0.25)했던 로봇을 맨 위"로 정렬.
function _battery_live(history; maxpts::Int = 500)
    isempty(history) && return ("", "")
    li = findlast(!isempty, history); li === nothing && return ("", "")
    # Order: any robot that hits a CRITICAL low (<=0.25) anywhere in the run is listed FIRST.
    # 정렬 기준용: 각 로봇이 전 구간에서 도달한 최소 SoC.
    minsoc = Dict{Any,Float64}()
    for k in keys(history[li])
        minsoc[k] = minimum((get(h, k, 1.0) for h in history if !isempty(h)); init = 1.0)   # 최소 SoC(빈 프레임 제외)
    end
    # 정렬키: (위험했으면 0 아니면 1, 로봇번호) → 위험 로봇이 먼저, 그 안에서 번호순.
    okeys = sort(collect(keys(history[li]));
                 by = k -> ((get(minsoc, k, 1.0) <= 0.25 ? 0 : 1), (try Int(k.id) catch; 0 end)))
    nums  = [(try Int(k.id) catch; 0 end) for k in okeys]
    n = length(history)
    idxs = n <= maxpts ? collect(1:n) : unique(round.(Int, range(1, n; length = maxpts)))
    mat  = [[round(Float64(get(history[i], k, NaN)); digits = 3) for k in okeys] for i in idxs]
    bars = join(map(nums) do rn
        "<div style=\"display:flex;align-items:center;gap:6px;margin:3px 0\">" *
        "<span style=\"width:40px;color:#cdd6e0\">R$rn</span>" *
        "<div style=\"flex:1;height:10px;background:#20242e;border-radius:5px;overflow:hidden\">" *
        "<div id=\"bat-$rn\" style=\"height:100%;width:100%;background:#7ee787;transition:width .1s linear\"></div></div>" *
        "<span id=\"batp-$rn\" style=\"width:34px;text-align:right;color:#7ee787\">100%</span></div>"
    end, "")
    data = JSON3.write(Dict("r" => nums, "s" => mat))
    script = """
    <script>
    (function(){
      var D = $data, R = D.r, S = D.s, N = S.length;
      function col(s){ return s<=0.25?'#ff6b6b':(s<=0.5?'#ffb454':'#7ee787'); }
      // MeshCat's Animator keeps the playhead on ITSELF (`this.time`, `this.duration`).
      function playhead(){
        var an = window.viewer && window.viewer.animator; if(!an) return {t:0,d:0};
        var t = (typeof an.time === 'number') ? an.time : 0;
        var d = (typeof an.duration === 'number' && an.duration > 0) ? an.duration : 0;
        if(d === 0){                                   // fall back to the clips if duration is unset
          var acts = an.actions||[];
          for(var i=0;i<acts.length;i++){
            var c = acts[i]._clip || (acts[i].getClip && acts[i].getClip());
            if(c && c.duration) d = Math.max(d, c.duration);
          }
        }
        return {t:t, d:d};
      }
      function socAt(frac){
        if(N===0) return null;
        var x=frac*(N-1), i=Math.floor(x), g=x-i;
        var a=S[Math.max(0,Math.min(N-1,i))], b=S[Math.max(0,Math.min(N-1,i+1))], o=[];
        for(var k=0;k<R.length;k++){ o.push(a[k]+(b[k]-a[k])*g); } return o;
      }
      function tick(){
        var p=playhead(), frac=p.d>0?Math.max(0,Math.min(1,p.t/p.d)):0, soc=socAt(frac);
        if(soc){ for(var k=0;k<R.length;k++){ var s=soc[k]; if(s==null||isNaN(s)) continue;
          var pct=Math.round(100*Math.max(0,Math.min(1,s))), c=col(s);
          var bar=document.getElementById('bat-'+R[k]), lab=document.getElementById('batp-'+R[k]);
          if(bar){ bar.style.width=pct+'%'; bar.style.background=c; }
          if(lab){ lab.textContent=pct+'%'; lab.style.color=c; } } }
        requestAnimationFrame(tick);
      }
      requestAnimationFrame(tick);
    })();
    </script>"""
    return (bars, script)
end

# _sidebar : 세 카드(OOD 타임라인 + 배터리 HUD + surrogate 로그)를 담은 왼쪽 고정 사이드바 HTML/CSS 생성.
function _sidebar(timeline_html, log_html, batt_html, batt_script)
    batt_card = isempty(batt_html) ? "" :
        "<div class=\"cb-card\"><div class=\"cb-title\">🔋 BATTERY SoC — per robot" *
        "<span class=\"cb-sub\"> live · red ≤25% · orange ≤50% · spares stay full</span></div>" *
        "<div class=\"cb-bars\">$batt_html</div></div>"
    return """
    <style>
      #meshcat-pane { width: calc(100vw - $(SIDEBAR_W)px) !important; margin-left: $(SIDEBAR_W)px !important; }
      #cb-sidebar { position:fixed; top:0; left:0; width:$(SIDEBAR_W)px; height:100vh; box-sizing:border-box;
        overflow-y:auto; background:#0b0e15; border-right:1px solid #2a3346; z-index:99999;
        font:11px/1.45 ui-monospace,Consolas,monospace; padding:9px; }
      #cb-sidebar .cb-card { background:rgba(16,18,26,.92); border-radius:8px; padding:8px 10px;
        margin-bottom:9px; box-shadow:0 2px 10px rgba(0,0,0,.5); }
      #cb-sidebar .cb-title { color:#9bd1ff; font-weight:700; margin-bottom:6px; }
      #cb-sidebar .cb-sub { color:#8891a5; font-weight:400; }
      #cb-sidebar .cb-log  { max-height:40vh; overflow:auto; white-space:pre-wrap; }
      #cb-sidebar .cb-bars { max-height:26vh; overflow:auto; }
    </style>
    <div id="cb-sidebar">
      <div class="cb-card"><div class="cb-title">OOD STREAM — adaptive re-plan<span class="cb-sub"> each event → a DSL macro</span></div>
        $timeline_html
        $(RESCUE ? "<div style=\"color:#ffb454;margin-top:7px\">CARRIER_RESCUE is ON: a formed carrier that " *
                   "stalls en route is advanced to its deposit, so a mid-build Replace can finish. The " *
                   "surrogate's predicted values were learned WITHOUT it (see DEMO.md).</div>" : "")</div>
      $batt_card
      <div class="cb-card"><div class="cb-title">SURROGATE WORLD MODEL<span class="cb-sub"> decide in imagination · 0 planner calls</span></div>
        <div class="cb-log">$log_html</div></div>
    </div>
    <script>
      (function(){ function fit(){ try{ window.dispatchEvent(new Event('resize')); }catch(e){} }
        window.addEventListener('load', function(){ fit(); setTimeout(fit,80); setTimeout(fit,500); });
        setTimeout(fit,150); })();
    </script>
    $batt_script"""
end

htmlpath = HTMLPATH
if isfile(htmlpath)
    # Make each DEEP battery drop VISIBLE: re-inject the post-drop SoC as a short HOLD.
    # 깊은 방전 순간이 눈에 띄게: 떨어진 직후 SoC 값을 몇 프레임 동안 "붙잡아" 유지시킨다(HOLD).
    if !isempty(BATT_CRIT) && !isempty(SOC_HISTORY)
        HOLD = max(1, round(Int, 0.05 * length(SOC_HISTORY)))   # 전체 프레임의 약 5% 길이만큼 유지
        for (rid, crit, f0) in BATT_CRIT
            crit > 0.30 && continue                  # 충분히 낮았던 경우만 강조
            for fr in max(1, f0):min(length(SOC_HISTORY), f0 + HOLD)   # 해당 프레임 구간에
                isempty(SOC_HISTORY[fr]) && continue
                haskey(SOC_HISTORY[fr], rid) && (SOC_HISTORY[fr][rid] = crit)   # 그 로봇 값을 낮게 고정
            end
        end
    end
    bars, bscript = _battery_live(SOC_HISTORY)
    # 패널을 주석 마커로 감싼다 → 재실행 시 아래 while 로 이전 패널만 깔끔히 제거(idempotent).
    panel = "<!--CB-PANEL-START-->" * _sidebar(_timeline_rows(_TIMELINE), _log_rows(_PIPE), bars, bscript) *
            "<!--CB-PANEL-END-->"
    html  = read(htmlpath, String)
    # IDEMPOTENT: strip any panel this demo (or an older one) already injected.
    # 이 데모(또는 예전 실행)가 넣은 패널이 이미 있으면 마커 사이를 잘라내 중복 삽입 방지.
    while occursin("<!--CB-PANEL-START-->", html) && occursin("<!--CB-PANEL-END-->", html)
        i = findfirst("<!--CB-PANEL-START-->", html); j = findfirst("<!--CB-PANEL-END-->", html)
        html = html[1:(first(i) - 1)] * html[(last(j) + 1):end]   # 마커 앞부분 + 마커 뒷부분
    end
    html  = occursin("</body>", html) ? replace(html, "</body>" => panel * "\n</body>"; count = 1) : html * panel
    write(htmlpath, html)
    println(">>> sidebar embedded: $(length(_TIMELINE)) OOD events, $(length(_PIPE)) log lines, " *
            "$(length(SOC_HISTORY)) SoC frames -> $(htmlpath)")
else
    @warn "no animation was written to $htmlpath — nothing to inject (did the run save_animation?)"
end
println("\n>>> OOD TIMELINE (what the surrogate decided, in order):")   # surrogate 가 순서대로 무엇을 결정했는지 요약
for r in _TIMELINE; println("    ", r); end
println(">>> done. Open: $htmlpath")
OPEN_ANIM && isfile(htmlpath) && (try run(`cmd /c start "" $(abspath(htmlpath))`) catch e; @warn "auto-open failed: $e" end)
end   # demo_surrogate_stream 끝

# =============================================================================
# run_zone -- full-render visual check of OOD 1-2 (restriction zone). Builds the
#   tractor with the full motion stack + render, injects a navigation no-go zone
#   mid-sim (RESPEC OFF), and opens a MeshCat animation so you can SEE robots
#   detour around the red-disc zone. Isolates the physical/navigation effect.
#   Tuning: INJECT_STEP (below) and the zone seed/placement.
# =============================================================================
# demo_run_zone : OOD 1-2(통행금지 구역)의 순수 "물리/항법" 효과만 보는 데모. respec 를 끈 채 구역을 넣어
#   로봇들이 빨간 원반을 실제로 "우회"하는 걸 눈으로 확인. (LLM/재계획 없음 — 회피는 순전히 항법 스택 때문.)
function demo_run_zone()
INJECT_STEP = 150          # sim step at which the no-go zone appears  # 이 스텝에 구역 등장

CB.clear_ood_schedule!()
CB.clear_restriction_zones!()
CB.clear_zone_markers!()

CB.schedule_ood!(INJECT_STEP, function (env)
    # Place a random no-go zone within the current activity area (seeded =
    # reproducible). Swap for an explicit placement if you want a fixed spot:
    #     z = CB.add_restriction_zone!(:demo, [x, y], r)
    # 현재 활동 영역 안에 무작위 금지구역 배치(seed 고정=재현가능). 고정위치 원하면 위 주석의 명시적 호출로 교체.
    z, nl = CB.random_restriction_zone!(env; key = :demo, seed = 7)   # z=구역객체, nl=자연어(반환은 튜플 분해)
    @info "[OOD] restriction zone injected" center=CB.get_center(z) radius=CB.get_radius(z)
    return nl     # enqueued for respec (a no-op here: RESPEC disabled). Detour is physical.  # respec 꺼져 있어 무효, 우회는 물리적
end)

# ---- build + simulate with full motion stack and render --------------------
pp = CB.get_project_params(4)    # tractor

CB.run_lego_demo(;
    ldraw_file   = pp[:file_name],
    project_name = pp[:project_name],
    model_scale  = pp[:model_scale],
    num_robots   = pp[:num_robots],
    assignment_mode      = :greedy,
    rvo_flag             = true,
    tangent_bug_flag     = true,
    dispersion_flag      = true,
    open_animation_at_end = true,    # opens the MeshCat animation in the browser
    save_animation        = true,
    write_results         = false,
    overwrite_results     = false,
    log_level             = Logging.Warn,
)

println(">>> done. The red disc is the injected no-go zone; watch robots route around it.")   # 빨간 원반=금지구역, 로봇이 우회하는지 관찰
end   # demo_run_zone 끝

# =============================================================================
# debug -- DIRECT runner (NO run_with_stack task wrapper) so pressing Ctrl+C while
#   it is stuck prints the backtrace of the ACTUAL runaway loop. Uses the lightest
#   model (colored_8x8), visualizer OFF. Runs the demo INLINE on purpose (no wrap).
# =============================================================================
# demo_debug : 디버깅용 직접 실행기. run_with_stack(별도 Task) 로 감싸지 않아서, 멈췄을 때 Ctrl+C 를 누르면
#   "진짜 무한루프가 도는 지점"의 backtrace 가 그대로 찍힌다. 가장 가벼운 모델(colored_8x8), 시각화 OFF.
function demo_debug()
project_params = get_project_params(1)   # colored_8x8 (가장 가벼움)

env, stats = run_lego_demo(;
    ldraw_file=project_params[:file_name],
    project_name=project_params[:project_name],
    model_scale=project_params[:model_scale],
    num_robots=project_params[:num_robots],
    assignment_mode=:greedy,
    milp_optimizer=:highs,
    optimizer_time_limit=60,
    rvo_flag=false,
    tangent_bug_flag=false,
    dispersion_flag=false,
    open_animation_at_end=false,
    save_animation=false,
    save_animation_along_the_way=false,
    anim_active_agents=false,
    anim_active_areas=false,
    update_anim_at_every_step=false,
    save_anim_interval=100,
    process_updates_interval=100,
    block_save_anim=false,
    write_results=false,
    overwrite_results=false,
    look_for_previous_milp_solution=false,
    save_milp_solution=false,
    previous_found_optimizer_time=30,
    max_num_iters_no_progress=2500,
    stop_after_task_assignment=false,
)

println("DEMO_DONE")
end   # demo_debug 끝

# =============================================================================
# fast -- FAST tractor build: physics/collision-avoidance OFF (rvo/tangent_bug/
#   dispersion) so agents move in straight lines and the sim finishes quickly while
#   the assembly animation is still produced. Keeps the process alive on the LIVE
#   MeshCat visualizer (http://127.0.0.1:8700) until Enter is pressed (readline).
# =============================================================================
# demo_fast : 빠른 트랙터 조립 데모. 물리/충돌회피(rvo/tangent_bug/dispersion)를 꺼서 로봇이 직선으로 움직이고
#   시뮬레이션이 빨리 끝난다(조립 애니메이션은 여전히 생성). 끝나면 라이브 MeshCat 서버를 켜둔 채 Enter 를 기다림.
function demo_fast()
project_params = get_project_params(4)   # tractor (원래 목표 모델) — 1로 바꾸면 colored_8x8

# --- FAST settings: physics/collision-avoidance OFF -> agents move in straight lines,
#     simulation finishes quickly, assembly animation still produced. ---
open_animation_at_end = true
save_animation_at_end = true              # also save a standalone HTML
save_animation_along_the_way = false
anim_active_agents = true
anim_active_areas = true

update_anim_at_every_step = true   # record a frame every sim step -> smooth, plenty of keyframes
save_anim_interval = 100
process_updates_interval = 100
block_save_anim = false

tangent_bug_flag = false
rvo_flag = false
dispersion_flag = false
assignment_mode = :greedy
milp_optimizer = :highs
optimizer_time_limit = 60

env, stats = run_with_stack(2_000_000_000) do
    run_lego_demo(;
        ldraw_file=project_params[:file_name],
        project_name=project_params[:project_name],
        model_scale=project_params[:model_scale],
        num_robots=project_params[:num_robots],
        assignment_mode=assignment_mode,
        milp_optimizer=milp_optimizer,
        optimizer_time_limit=optimizer_time_limit,
        rvo_flag=rvo_flag,
        tangent_bug_flag=tangent_bug_flag,
        dispersion_flag=dispersion_flag,
        open_animation_at_end=open_animation_at_end,
        save_animation=save_animation_at_end,
        save_animation_along_the_way=save_animation_along_the_way,
        anim_active_agents=anim_active_agents,
        anim_active_areas=anim_active_areas,
        update_anim_at_every_step=update_anim_at_every_step,
        save_anim_interval=save_anim_interval,
        process_updates_interval=process_updates_interval,
        block_save_anim=block_save_anim,
        write_results=false,
        overwrite_results=false,
        look_for_previous_milp_solution=false,
        save_milp_solution=false,
        previous_found_optimizer_time=30,
        max_num_iters_no_progress=2500,
        stop_after_task_assignment=false,
    )
end

println("DEMO_DONE")

# Keep the process (and the MeshCat server) alive so the live visualizer stays
# reachable. The live server fully supports animation playback (play/slider),
# unlike the exported static HTML. View at http://127.0.0.1:8700, open the
# controls (top-right), expand "Animations", and press play.
println("\n=== Visualizer is LIVE at http://127.0.0.1:8700 ===")
println("Open Controls (top-right) -> Animations -> play to watch the assembly.")
println("Press Enter in THIS window to quit and shut down the visualizer.")
readline()   # 이 창에서 Enter 를 입력할 때까지 프로세스(및 시각화 서버)를 살려둔다
end   # demo_fast 끝

# =============================================================================
# bigstack -- LARGE x_wing (309 parts x 28 assemblies; README large example, ~minutes)
#   on a 4 GB C stack. MILP warm-start assignment (:milp_w_greedy_warm_start -- pure
#   greedy deadlocks at N=9), full nav stack, frames recorded only at node completions
#   (update_anim_at_every_step=false) so big models stay tractable.
# =============================================================================
# demo_bigstack : 큰 모델(x_wing, 309부품×28조립체) 데모 — 수 분 소요. 4GB C 스택, MILP warm-start 배정 사용
#   (순수 greedy 는 이 규모에서 교착). 프레임은 노드 완료 시점에만 기록해(update_anim_at_every_step=false) 큰 모델도 다룰 만하게.
function demo_bigstack()
project_params = get_project_params(9)   # x_wing (309 parts x 28 assemblies) — README large example, ~minutes

open_animation_at_end = true
save_animation_along_the_way = false
save_animation_at_end = false
anim_active_agents = true
anim_active_areas = true

update_anim_at_every_step = false   # fast: record only at node completions (big models). true = smooth motion/RVO but very slow
save_anim_interval = 100
process_updates_interval = 100
block_save_anim = false

tangent_bug_flag = true
rvo_flag = true
dispersion_flag = true
assignment_mode = :milp_w_greedy_warm_start   # at_te_walker(N=9) needs MILP warm-start; pure :greedy deadlocks  # greedy 로 워밍 후 MILP 개선(순수 greedy 는 교착)
milp_optimizer = :highs
optimizer_time_limit = 60

# 4GB 스택으로 실행(대형 모델이라 기본보다 큰 스택 필요).
env, stats = run_with_stack(4_000_000_000) do
    run_lego_demo(;
        ldraw_file=project_params[:file_name],
        project_name=project_params[:project_name],
        model_scale=project_params[:model_scale],
        num_robots=project_params[:num_robots],
        assignment_mode=assignment_mode,
        milp_optimizer=milp_optimizer,
        optimizer_time_limit=optimizer_time_limit,
        rvo_flag=rvo_flag,
        tangent_bug_flag=tangent_bug_flag,
        dispersion_flag=dispersion_flag,
        open_animation_at_end=open_animation_at_end,
        save_animation=save_animation_at_end,
        save_animation_along_the_way=save_animation_along_the_way,
        anim_active_agents=anim_active_agents,
        anim_active_areas=anim_active_areas,
        update_anim_at_every_step=update_anim_at_every_step,
        save_anim_interval=save_anim_interval,
        process_updates_interval=process_updates_interval,
        block_save_anim=block_save_anim,
        write_results=false,
        overwrite_results=false,
        look_for_previous_milp_solution=false,
        save_milp_solution=false,
        previous_found_optimizer_time=30,
        max_num_iters_no_progress=2500,
        stop_after_task_assignment=false,
    )
end

println("DEMO_DONE")
end   # demo_bigstack 끝

# ---- dispatcher -------------------------------------------------------------
# DEMOS : "데모키(문자열) → 데모함수" 매핑 딕셔너리. 맨 아래 실행부가 이 표에서 함수를 찾아 부른다.
#   (여기 값은 함수 자체 — Julia 에선 함수도 값처럼 변수/딕셔너리에 담아 나중에 호출할 수 있다.)
const DEMOS = Dict(
    "original_baseline"    => demo_original_baseline,
    "run_zone"             => demo_run_zone,
    "wholebuild"           => demo_wholebuild,
    "respec_forbidzone"    => demo_respec_forbidzone,
    "respec_replace"       => demo_respec_replace,
    "energy_adaptive"      => demo_energy_adaptive,
    "energy_adaptive_anim" => demo_energy_adaptive_anim,
    "energy_stall_replace" => demo_energy_stall_replace,
    "debug"                => demo_debug,
    "fast"                 => demo_fast,
    "bigstack"             => demo_bigstack,
)
end # module Demos

# ---- CLI/ENV 실행부 -----------------------------------------------------------
# 이 파일을 "직접" 실행했을 때만(=다른 파일이 include 한 게 아닐 때) 아래가 돈다.
#   abspath(PROGRAM_FILE) == @__FILE__  : "지금 실행 중인 스크립트가 바로 이 파일인가?" 검사.
if abspath(PROGRAM_FILE) == @__FILE__
    # 실행할 데모키 결정: 우선순위는 ENV["DEMO"] > 명령행 첫 인자 ARGS[1] > 기본값 "original_baseline".
    key = get(ENV, "DEMO", isempty(ARGS) ? "original_baseline" : ARGS[1])
    # 없는 키면 사용 가능한 목록을 알려주며 에러(|| = 앞이 참이면 통과, 거짓이면 뒤 실행).
    haskey(Demos.DEMOS, key) || error("unknown demo '$key'. Available: $(join(sort(collect(keys(Demos.DEMOS))), ", "))")
    println(">>> running demo: $key")
    Demos.DEMOS[key]()   # 표에서 함수를 꺼내 () 로 호출 = 그 데모 실행
end
