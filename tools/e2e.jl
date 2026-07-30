# =============================================================================
# tools/e2e.jl -- consolidated ConstructionBots e2e / mock-LLM pipeline drivers.
#
# Every standalone tools/*_e2e.jl / full-loop / self-heal / spare-replace script is
# now a FUNCTION in module `E2E`, sharing common boilerplate (MILP setup +
# run_with_stack) defined ONCE. A CLI/ENV dispatcher at the bottom runs any one.
#
# Scenario keys:
#   mock_respec   -- LLM-free e2e of the FULL ForbidZone respec seam (mock /propose over HTTP)
#   mock_replace  -- LLM-free e2e of the OOD 1-1 ReplaceAgent respec seam (mock /propose over HTTP)
#   full_loop     -- enabled-seam full-loop RESUME driver (LLM seam or LLM-free reassign)
#   selfheal      -- headless autonomous self-healing verification harness (REAL LLM on :8000)
#   spare_replace -- OOD 1-1 spare 1:1 hand-off done-gate (LLM-free replace_robot!)
#   live_respec   -- LIVE e2e of the respec seam: real Claude (running Python service) NL->DSL->re-solve
#
# Run:
#   julia +lts --project=. tools/e2e.jl <key>        (or  ENV E2E=<key>)
# e.g.
#   julia +lts --project=. tools/e2e.jl mock_respec
#   E2E=spare_replace julia +lts --project=. tools/e2e.jl
# Each scenario reads its own ENV knobs at call time (see the comment above each function).
# These scenarios stand up local mock servers and/or run full sims -- run ONE at a time.
# =============================================================================

# =============================================================================
#  [한국어 설명] 이 파일 = ConstructionBots 의 "end-to-end(e2e) 통합 실행/검증" 드라이버 모음.
#
#  큰 그림(프로젝트에서의 역할):
#   ConstructionBots = 여러 로봇이 협력해 LEGO 구조물을 짓는 TAMP(작업+동작 계획) 시뮬레이터.
#   빌드 도중 예상 못 한 사건(OOD, out-of-distribution)이 터짐 → 로봇 고장, 중앙에 진입금지 구역 등.
#   이때 "respec 레이어"가 자연어(NL) 사건설명을 받아 → LLM(또는 mock/surrogate)이 → DSL 제약
#   (ForbidZone=진입금지구역 / ReplaceAgent=로봇 교체 등)으로 번역 → 검증(verify) → 계획 재수립(re-solve).
#   이 파일의 각 함수(scenario_*)는 그 전체 파이프라인이 실제로 동작하는지 한 번씩 끝까지 돌려보는 시험대.
#
#  시나리오(맨 아래 SCENARIOS 표의 키):
#   · mock_respec  : LLM 없이(mock 서버) ForbidZone respec 전 구간 e2e — 중앙 no-go 구역 주입→복구→완주.
#   · mock_replace : LLM 없이 ReplaceAgent respec — 로봇 고장→스페어(spare)로 1:1 교체 배선 확인.
#   · full_loop    : 빌드 중간에 고장 주입→재배정(reassign)으로 "이어서" 완주(끝난 일은 다시 안 함).
#   · selfheal     : 진짜 LLM 을 켜고 자율 self-healing 을 headless(화면無)로 검증 + 막히면 진단기록.
#   · spare_replace: LLM 없이 replace_robot! 스페어 1:1 인계가 빌드를 "완주"시키는지 done-gate 검증.
#   · live_respec  : 진짜 Claude(파이썬 서비스)로 NL→DSL→검증→재solve 하는 라이브 e2e.
#
#  문법 참고(처음 보는 Julia 문법):
#   · module E2E ... end        : 이름공간. 안의 함수는 E2E.함수명 으로 호출.
#   · using / import            : using=이름 그대로 노출, import=모듈명.기능 형태로 씀. const CB = ... 는 별칭.
#   · f(x::Int)                 : x 가 Int 타입일 때만 적용되는 메서드(다중 디스패치). ::타입 = 타입 제약.
#   · :symbol (예: :zone, :ok)  : 심볼 = 가볍고 변하지 않는 이름표(문자열보다 빠른 식별자, enum 비슷).
#   · "a" => b                  : Pair(짝). Dict("k"=>v) 로 딕셔너리를 만들 때 씀.
#   · Dict/Ref/Vector{Float64}  : Ref{T}=한 칸짜리 가변 상자(클로저 안에서 값을 바꿔 밖으로 빼낼 때). {T}=원소 타입.
#   · x[]                       : Ref/원소 하나짜리 컨테이너의 "안의 값"을 읽거나(r[]) 쓰기(r[]=v).
#   · 조건 && 식 / 조건 || 식    : &&=앞이 참일 때만 뒤 실행, ||=앞이 거짓일 때만 뒤 실행(if 축약 관용구).
#   · do ... end                : 함수의 첫 인자로 넘기는 익명함수 블록. f(args) do x; ...; end 형태.
#   · @info / @warn / @__FILE__ : @ 로 시작하면 매크로(코드 변형). @info=로그 출력, @__FILE__=이 소스 경로.
#   · [x for x in xs if cond]   : comprehension(한 줄 리스트 생성). map+filter 를 한 번에.
#   · function f!(...) 관례       : 이름 끝 `!` = 인자(env 등)를 그 자리에서 직접 바꾸는 함수라는 표시.
#   · NamedTuple (status=:ok,...): 이름표 붙은 튜플. r.status 처럼 필드명으로 꺼냄(가벼운 구조체).
#   · ccall(:jl_new_task, ...)   : Julia 런타임의 C 함수를 직접 호출. 여기선 "큰 스택을 가진 새 태스크" 생성용.
#   · world-age                  : 함수 정의 "세대" 개념. 방금 정의한 메서드를 같은 프레임에서 부르면 에러 나는 함정(아래 참고).
# =============================================================================
module E2E
using ConstructionBots
# [KO] HTTP=mock LLM 서버/요청, JSON3=요청·응답 JSON 파싱, Graphs=스케줄(작업 의존)그래프,
#      Logging=로그레벨, HiGHS/JuMP=MILP(정수계획) 최적화기, LinearAlgebra=벡터 연산.
import HTTP, JSON3, Graphs, Logging, HiGHS, JuMP, LinearAlgebra
const CB = ConstructionBots         # [KO] 긴 패키지명을 CB 로 줄여 씀(별칭). 이후 CB.함수 로 호출.
const norm = LinearAlgebra.norm     # [KO] norm = 벡터 크기(길이). 두 위치의 거리 계산에 씀.

# ---- runtime-loaded decoupled layers (loaded ONCE, at module load) ----------
# The navigator layer is NOT compiled into the ConstructionBots package -- the self-heal
# script historically `CB.include`d its battery/metrics/ood_truth/ood_stream files at SCRIPT
# TOP LEVEL. Now that each script is a FUNCTION, doing those includes *inside* the function and
# then calling the freshly-defined methods in the SAME call frame raises a world-age error
# ("method too new to be called from this world context"). Loading navigator.jl here at MODULE
# load puts those methods in an OLDER world than any scenario call, reproducing the original
# top-level-include semantics. navigator.jl is the umbrella loader (it includes metrics/
# ood_truth/battery/ood_stream/... in dependency order -- see its header), so this ONE call
# covers the self-heal scenario's battery layer.
# [KO] navigator 레이어(배터리/지표/OOD 진실값 등)는 패키지에 컴파일돼 있지 않고 런타임에 include 함.
#      핵심 함정(world-age): 이 include 를 "함수 안"에서 하고 같은 호출 프레임에서 그 메서드를 부르면
#      "메서드가 너무 새것"이라는 에러가 남. 그래서 모듈 로드 시점(=여기)에 딱 한 번 include 하여
#      메서드를 더 "오래된 세대"에 심어둠 → 이후 어떤 시나리오에서 불러도 안전. (예전 top-level include 재현)
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))

# ---- shared helpers (defined ONCE) ------------------------------------------
# The set_default_milp_optimizer! block that appears (identically -- 300s/5.0 gap/MOI.Silent)
# in all 5 e2e scripts.
# [KO] MILP(작업배정 정수최적화) 기본 최적화기를 HiGHS 로 세팅하는 공통 준비함수.
#      time_limit=한 번 풀 때 최대 시간(초), mip_rel_gap=이 정도 오차면 "충분히 좋다"고 멈춤(=속도 우선).
#      함수 이름 끝 `!` = 전역 설정을 바꾸는 부작용. 인자 앞의 `;` = 이후는 keyword(이름지정) 인자.
function _setup_milp!(; time_limit = 300.0, mip_rel_gap = 5.0)
    CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())   # () -> ... : 최적화기를 새로 만드는 익명함수(팩토리)
    CB.clear_default_milp_optimizer_attributes!()             # 이전 속성 초기화
    CB.set_default_milp_optimizer_attributes!(
        "time_limit" => time_limit, "presolve" => "on", "mip_rel_gap" => mip_rel_gap,
        CB.MOI.Silent() => true)                              # MOI.Silent()=>true : 최적화기 로그 침묵
end

# The identical stack-growing task helper (throws on error, returns the result). Used by
# mock_respec / mock_replace / full_loop / spare_replace. (selfheal keeps its OWN
# tuple-returning variant nested inside it -- different error-handling contract.)
# [KO] 함수 f 를 "아주 큰 스택(stacksize 바이트)을 가진 새 태스크"에서 돌리고 결과를 돌려줌.
#      왜? 빌드/시뮬은 재귀가 깊어 기본 스택으론 stack overflow 가 남 → 큰 스택 태스크로 우회.
#      에러가 나면 스택트레이스를 찍고 다시 throw(호출자에게 실패 전달). 결과는 res[] 로 빼냄.
function run_with_stack(f, stacksize::Int)
    # [KO] Ref = 한 칸짜리 가변 상자. 태스크(다른 실행맥락) 안에서 채운 값을 밖에서 읽으려는 통로.
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)  # done=완료 플래그(원자적)
    # [KO] ccall 로 Julia 런타임의 C 함수 jl_new_task 를 호출해 지정 스택크기의 태스크 생성.
    #      넘기는 익명함수: f() 실행→성공하면 res, 실패하면 err 에 담고, 끝나면 done=true.
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end   # 태스크를 예약·실행하고 끝날 때까지 대기(폴링)
    # [KO] 에러가 있으면(!== nothing) 화면에 찍고 다시 던짐. (&& 뒤는 앞이 참일 때만 실행)
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))
    return res[]
end

# =============================================================================
# mock_respec -- LLM-FREE end-to-end test of the FULL respec seam for ForbidZone
#   (Stage 2). Stands up a local mock /propose server that returns a fixed ForbidZone
#   (grounded from the request's own zones/nodes context, mimicking the LLM), enables the
#   RESPEC seam, injects a CENTRAL zone via schedule_ood! (returning an NL string), and runs
#   the real sim loop (ood_inject_step! -> step -> respec_step!). This drives the production
#   path: NL -> push_ood! -> maybe_respecify! -> llm_to_proposal(HTTP mock) -> _parse_proposal
#   -> ForbidZone -> verify_zone -> restage_all -> translate_whole_build! -> completion.
#   ENV: NAVON_ZONE_R, OOD_STEP.
# =============================================================================
# [KO] 시나리오1: LLM 없이 ForbidZone respec 전 구간을 실제 시뮬로 검증.
#      흐름 = 중앙에 no-go 구역 주입 → NL 방출 → mock 서버가 ForbidZone DSL 로 응답 →
#      검증(verify_zone) → 빌드 전체를 옆으로 이동(translate_whole_build!)해 구역 회피 → 완주.
function scenario_mock_respec()
MOCK_PORT = 8731
ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:$MOCK_PORT"   # CB reads the URL at call time
                                                            # [KO] CB 가 이 URL 을 실행 중 읽어 /propose 로 요청

ZONE_R = parse(Float64, get(ENV, "NAVON_ZONE_R", "2.5"))   # [KO] 진입금지 구역 반지름(환경변수로 조절)
OOD_STEP = parse(Int, get(ENV, "OOD_STEP", "5"))           # [KO] 몇 번째 스텝에서 OOD(구역)를 주입할지

_setup_milp!()

# ---- mock /propose server: deterministic, grounds ForbidZone from request context -----
# [KO] 진짜 LLM 대신 쓰는 가짜 HTTP 서버. /health=살아있음 확인, /propose=OOD 요청에 ForbidZone 응답.
#      "결정적(deterministic)" = 무작위 없이 요청 안의 실제 zone/node 정보를 그대로 근거로 답(LLM 흉내).
function start_mock(port)
    handler = function (req::HTTP.Request)                 # [KO] 들어온 요청 하나를 처리하는 익명함수
        path = HTTP.URIs.URI(req.target).path              # 요청 경로(/health 또는 /propose) 추출
        if path == "/health"
            return HTTP.Response(200, JSON3.write(Dict("status" => "ok")))   # [KO] 상태확인엔 ok
        elseif path == "/propose"
            body  = JSON3.read(String(req.body))            # [KO] 요청 본문(JSON) 파싱
            zones = haskey(body, "zones") ? body["zones"] : []   # [KO] 있으면 쓰고 없으면 빈 배열(?: = 삼항)
            nodes = haskey(body, "nodes") ? body["nodes"] : []
            zkey  = isempty(zones) ? "zone" : String(zones[1]["key"])     # ground the live zone key
                                                            # [KO] 실제 구역 키를 그대로 사용(없으면 "zone")
            # prefer an assembly the zone actually covers; else first milestone node
            # [KO] 구역이 실제로 덮는 조립품(covers)을 우선, 없으면 첫 노드를 대상(assembly)으로
            cov = isempty(zones) ? [] : zones[1]["covers"]
            aid = !isempty(cov) ? String(first(cov)) :
                  (isempty(nodes) ? "" : String(nodes[1]["id"]))
            # [KO] LLM 이 낼 법한 응답 형태: ForbidZone 제약 1개 + 근거문(rationale).
            resp = Dict("constraints" => [Dict("kind" => "ForbidZone", "zone" => zkey, "assembly" => aid)],
                        "rationale" => "mock: spatial no-go zone over the build core")
            return HTTP.Response(200, JSON3.write(resp))
        end
        return HTTP.Response(404, "not found")              # [KO] 그 외 경로는 404
    end
    return HTTP.serve!(handler, "127.0.0.1", port)   # non-blocking; returns a Server
                                                     # [KO] 블로킹 안 함 → 서버 객체를 돌려주고 계속 진행
end

# [KO] scene_tree(장면 트리)에서 로봇 노드만 골라내는 comprehension. matches_template=타입 일치 판정.
_robot_nodes(env) = [n for n in CB.get_nodes(env.scene_tree) if CB.matches_template(CB.RobotNode, n)]
# [KO] 3D 자세의 위치를 2D 평면 좌표(Vector{Float64})로 투영. p2 = point-2d.
_p2(t) = Vector{Float64}(CB.project_to_2d(t.translation))
# [KO] staging_circles(대기원) 중 반지름이 가장 큰 것의 키 = 빌드 중심(root)로 간주. argmax=최대를 주는 키.
_root_id(env) = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))

# OOD action: inject the physical zone AND return the NL string (-> push_ood! by ood_inject_step!)
# [KO] OOD 발동함수: 물리적으로 진입금지 구역을 실제로 추가하고, 사람이 쓸 법한 NL 문장을 반환.
#      반환된 NL 은 ood_inject_step! 이 push_ood! 로 respec 파이프라인에 밀어넣음.
function ood_action!(env)
    gs = CB.root_deposit_goals(env)     # [KO] 최종 조립 지점들의 좌표 목록
    # [KO] 목표가 있으면 그 평균(무게중심)을, 없으면 중심 대기원의 중심을 구역 중심 zc 로. ./ =원소별 나눗셈.
    zc = isempty(gs) ? Vector{Float64}(CB.get_center(env.staging_circles[_root_id(env)])[1:2]) : sum(gs) ./ length(gs)
    CB.add_restriction_zone!(:zone, zc, ZONE_R)   # [KO] 중심 zc, 반지름 ZONE_R 의 실제 금지구역 등록
    @info "[E2E] OOD action: injected zone@$(round.(zc;digits=2)) R=$ZONE_R; emitting NL"
    # [KO] LLM 이 받을 자연어 사건 설명. `*` = 문자열 이어붙이기.
    return "A safety exclusion zone is now active over the central build area; " *
           "robots must not enter or pass through it."
end

println(">>> building nav-ON env (tractor)...")
pp = CB.get_project_params(4)   # [KO] 4 = tractor 프로젝트 파라미터(파일/스케일/로봇수 등) 묶음
# [KO] 시뮬 시작 직전 상태의 env 를 큰 스택 태스크에서 빌드. do...end = run_with_stack 에 넘기는 함수블록.
ENV0 = run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,   # greedy=탐욕 배정
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Error,
        rvo_flag=true, tangent_bug_flag=true, dispersion_flag=true,      # [KO] nav-ON: RVO 충돌회피/TangentBug/분산 켬
        open_animation_at_end=false, save_animation=false, write_results=false,
        overwrite_results=false, look_for_previous_milp_solution=false,
        save_milp_solution=false, return_env_before_sim=true)           # [KO] 시뮬 돌리지 말고 준비된 env 만 반환
end
println(">>> env: $(Graphs.nv(ENV0.sched)) nodes")   # [KO] nv = 스케줄 그래프의 노드(작업) 개수

# bring up the mock + enable the seam
SRV = start_mock(MOCK_PORT)               # [KO] mock 서버 띄우기(서버 객체 보관 → 나중에 close)
CB.RESPEC_ENABLED[] = true                # [KO] respec 이음새(seam) 켜기. []=전역 스위치(Ref)에 값 대입
CB.clear_ood_schedule!(); CB.clear_restriction_zones!()   # [KO] 이전 OOD 예약/구역 깨끗이 초기화
CB.schedule_ood!(OOD_STEP, ood_action!)   # [KO] OOD_STEP 스텝에 ood_action! 을 한 번 발동하도록 예약
println(">>> mock /propose up at $(ENV["RESPEC_SERVICE_URL"]); respec_service_ready=$(CB.respec_service_ready()); RESPEC_ENABLED=$(CB.RESPEC_ENABLED[])")
Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Info))   # [KO] 이후 로그를 Info 레벨로 출력

# real seam loop (mirrors simulate!): ood_inject_step! -> step -> respec_step!
# [KO] 진짜 시뮬 루프(simulate! 를 흉내): 매 스텝 OOD주입 → 물리 한 스텝 → respec 처리 순서.
#      동시에 로봇이 금지구역을 침범(penetration)하는지 감시하고, 완주/정체(stall) 여부를 판정.
#      cap=최대 반복수, stall_limit=진전 없는 스텝이 이만큼이면 정체로 간주. 반환=NamedTuple(요약).
function run_seam_loop(env; cap=250_000, stall_limit=8000)
    rr = Float64(CB.default_robot_radius()); robots = _robot_nodes(env)   # rr=로봇 반지름, robots=로봇 노드들
    zc_ref = Ref{Any}(nothing)
    # [KO] prev=직전 완료개수, stall=정체 카운터, worst=최악 침범량, viol=침범 스텝수, first_v/last_v=처음/마지막 침범 시점
    prev = length(env.cache.closed_set); stall = 0; worst = -Inf; viol = 0; first_v = -1; last_v = -1
    respec_seen = Ref(false)   # [KO] respec 이 한 번이라도 발동했는지 기록(상자)
    for it in 1:cap
        CB.ood_inject_step!(env, it)     # [KO] 예약된 OOD 가 이 스텝이면 발동(NL 을 push_ood!)
        CB.step_environment!(env)        # [KO] 물리 시뮬을 한 스텝 전진(로봇 이동 등)
        st = CB.respec_step!(env)         # [KO] respec 처리: NL→DSL→검증→반영. 결과 상태(st) 반환
        # [KO] respec 이 뭔가 판정을 내렸으면(admitted/noop/fallback/rejected) 봤다고 표시+로그
        (st in (:admitted, :noop, :fallback, :rejected)) && (respec_seen[] = true; @info "[E2E] respec_step! @it=$it -> $st")
        try CB.update_planning_cache!(env, 0.0) catch e   # [KO] 계획 캐시 갱신(어느 작업이 열렸/닫혔는지)
            @warn "[E2E] update_planning_cache! threw @it=$it: $(typeof(e))"
            # [KO] 갱신이 에러를 던지면(assert류) 실패상태로 조기 반환
            return (status=:asserted, closed=length(env.cache.closed_set), iters=it, worst=worst, viol=viol, first_v=first_v, last_v=last_v, respec=respec_seen[])
        end
        if !isempty(CB.RESTRICTION_ZONES[])                 # track penetration once a zone exists
            # [KO] 구역이 존재하면 침범 감시: z=구역, zc=중심, zr=반지름
            z = first(values(CB.RESTRICTION_ZONES[])); zc = Vector{Float64}(CB.get_center(z)[1:2]); zr = Float64(CB.get_radius(z))
            sp = -Inf
            # [KO] 각 로봇마다 (구역+로봇 반지름) - 중심까지거리 = 침범 깊이. 양수면 겹침. 최댓값을 sp 로.
            for rb in robots; sp = max(sp, (zr + rr) - norm(_p2(CB.global_transform(rb)) .- zc)); end
            sp > 1e-6 && (viol += 1; first_v < 0 && (first_v = it); last_v = it)   # 미세오차 넘는 침범이면 카운트
            sp > worst && (worst = sp)     # [KO] 역대 최악 침범량 갱신
        end
        c = length(env.cache.closed_set)   # [KO] 현재까지 완료(closed)된 작업 수
        stall = c > prev ? 0 : stall + 1; prev = c   # 진전 있으면 정체 0, 없으면 +1
        CB.project_complete(env) && return (status=:complete, closed=c, iters=it, worst=worst, viol=viol, first_v=first_v, last_v=last_v, respec=respec_seen[])   # 완주
        stall >= stall_limit && return (status=:stalled, closed=c, iters=it, worst=worst, viol=viol, first_v=first_v, last_v=last_v, respec=respec_seen[])   # 정체 종료
    end
    return (status=:capped, closed=prev, iters=cap, worst=worst, viol=viol, first_v=first_v, last_v=last_v, respec=respec_seen[])   # cap 소진
end

env = deepcopy(ENV0)   # [KO] 원본 env 는 보존하고 복사본에서 시뮬(반복 실행 대비)
total = Graphs.nv(env.sched); n0 = length(env.cache.closed_set)   # total=전체 작업수, n0=시작 완료수
r = run_seam_loop(env)
try close(SRV) catch end   # [KO] mock 서버 닫기(실패해도 무시)
# [KO] transient(일시적 침범) = 침범이 전혀 없었거나, 마지막 침범이 초반부(=구역 생기기 전 잔여)라면 OK.
transient = r.viol == 0 || r.last_v < max(2000, 0.1 * r.iters)
# [KO] PASS 조건: 완주 + respec 발동 + 침범이 일시적(복구 후 재진입 없음).
pass = r.status == :complete && r.respec && transient
println("\n==== RESULT (mock e2e ForbidZone) ====")
println("closed $n0 -> $(r.closed)/$total  status=$(r.status)  respec_fired=$(r.respec)")
println("zone penetration: worst_pen=$(round(r.worst;digits=3)) viol_steps=$(r.viol) viol_iters=[$(r.first_v)..$(r.last_v)] of $(r.iters)  evac_transient=$transient")
println(pass ? "PASS (NL -> mock LLM -> ForbidZone -> verify -> recovery -> complete, no re-entry)" : "FAIL")
CB.RESPEC_ENABLED[] = false; CB.clear_ood_schedule!(); CB.clear_restriction_zones!()   # [KO] 전역 상태 원상복구
end

# =============================================================================
# mock_replace -- LLM-FREE end-to-end test of the FULL respec seam for OOD 1-1
#   ReplaceAgent (robot breakdown -> spare hand-off). Stands up a local mock /propose
#   that returns a ReplaceAgent grounded from the request's own `agents` context
#   (mimicking the LLM classifier), enables the RESPEC seam, injects a physical robot
#   fault via schedule_ood! (fault_robot! returns the NL), and runs the real sim loop
#   (ood_inject_step! -> step -> respec_step!). This drives the production path:
#     NL -> push_ood! -> maybe_respecify! -> llm_to_proposal(HTTP mock) -> _parse_proposal
#     -> ReplaceAgent -> verify_replace -> nearest_pool/pop_spare -> replace_robot!.
#   SCOPE: asserts the enabled-loop WIRING fires (respec admitted, spare hand-off enacted,
#   progress monotone). Full COMPLETION is gated on the known R1 frontier-graft stall.
#   ENV: OOD_STEP, NSPARE, FAULT_AT.
# =============================================================================
# [KO] 시나리오2: LLM 없이 ReplaceAgent respec 배선 검증. 로봇 고장 → mock 이 ReplaceAgent DSL 응답 →
#      검증 → 가장 가까운 스페어(spare) pool 에서 하나 꺼내 replace_robot! 로 1:1 교체까지 "이음새가 켜지는지".
#      (완주까지는 요구 안 함 — 완주는 알려진 R1 frontier-graft 정체 때문에 별도 이슈.)
function scenario_mock_replace()
MOCK_PORT = 8733
ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:$MOCK_PORT"   # CB reads the URL at call time

OOD_STEP = parse(Int, get(ENV, "OOD_STEP", "3"))   # by step ~3 the frontier has opened (closed-count jumps early)
                                                   # [KO] 스텝 ~3 이면 작업 frontier 가 열려 고장 주입이 의미있음
NSPARE   = parse(Int, get(ENV, "NSPARE", "2"))     # [KO] pool(방위별) 당 스페어 수. 총 스페어 = 4*NSPARE
FAULT_AT = parse(Int, get(ENV, "FAULT_AT", "24"))  # [KO] 진전(완료수)이 이 값을 넘겼는지로 hand-off 성공 판정

_setup_milp!()

# ---- mock /propose: deterministic, grounds ReplaceAgent from request `agents` --------
# [KO] 가짜 서버: 고장 NL 을 받아 어느 로봇인지 파악해 ReplaceAgent DSL 로 응답(LLM 분류기 흉내).
function start_mock(port)
    handler = function (req::HTTP.Request)
        path = HTTP.URIs.URI(req.target).path
        if path == "/health"
            return HTTP.Response(200, JSON3.write(Dict("status" => "ok")))
        elseif path == "/propose"
            body   = JSON3.read(String(req.body))
            event  = haskey(body, "event") ? String(body["event"]) : ""    # [KO] 고장 NL 문장
            agents = haskey(body, "agents") ? body["agents"] : []           # [KO] 요청에 실린 실제 에이전트 목록
            # ground the faulted robot: parse "Robot R<id>" from the NL, else first agent.
            # [KO] NL 에서 "R숫자"를 정규식으로 뽑아 그 id 를 가진 에이전트를 찾음. r"..." = 정규식 리터럴.
            m = match(r"R(\d+)", event)     # \d+ = 숫자 한 개 이상, 괄호=캡처그룹(뽑아낼 부분)
            aid = ""
            if m !== nothing
                want = "($(m.captures[1]))"   # [KO] 캡처한 숫자를 "(3)" 형태로 → 에이전트 id 문자열에 포함되는지 검사
                for a in agents
                    occursin(want, String(a["id"])) && (aid = String(a["id"]); break)   # 찾으면 그 id 채택하고 중단
                end
            end
            aid == "" && !isempty(agents) && (aid = String(agents[1]["id"]))   # [KO] 못 찾으면 첫 에이전트로 fallback
            # [KO] ReplaceAgent 제약: 이 agent 를 after(=0.0, 지금 시점) 이후로 교체하라.
            resp = Dict("constraints" => [Dict("kind" => "ReplaceAgent", "agent" => aid, "after" => 0.0)],
                        "rationale" => "mock: robot breakdown -> replace with nearest spare")
            return HTTP.Response(200, JSON3.write(resp))
        end
        return HTTP.Response(404, "not found")
    end
    return HTTP.serve!(handler, "127.0.0.1", port)
end

# OOD action: fault an active robot once the build is underway, emit the NL. Fired
# once by the one-shot scheduler at OOD_STEP (by which point the frontier has opened).
# [KO] OOD 발동: 활동 중인 로봇 하나를 고장(fault) 처리하고 그 고장 NL 을 반환. 대상이 없으면 nothing.
function ood_action!(env)
    nl = CB.fault_robot!(env)          # [KO] 로봇 하나를 고장 상태로 만들고 설명 NL 을 돌려줌
    nl === nothing && return nothing   # [KO] 고장 낼 로봇이 없으면 아무 일도 안 함
    @info "[E2E-1-1] OOD action @closed=$(length(env.cache.closed_set)): faulted a robot; emitting NL"
    return nl
end

println(">>> building nav-ON env (tractor) WITH $(4*NSPARE) spares...")
pp = CB.get_project_params(4)
# [KO] 스페어풀/고장로봇/구역/OOD예약을 전부 초기화(깨끗한 시작 보장)
CB.clear_spare_pools!(); CB.clear_faulted_robots!(); CB.clear_restriction_zones!(); CB.clear_ood_schedule!()
ENV0 = run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Error,
        rvo_flag=true, tangent_bug_flag=true, dispersion_flag=true, n_spare_per_pool=NSPARE,   # [KO] pool 당 스페어 NSPARE개
        open_animation_at_end=false, save_animation=false, write_results=false,
        overwrite_results=false, look_for_previous_milp_solution=false,
        save_milp_solution=false, return_env_before_sim=true)
end
println(">>> env: $(Graphs.nv(ENV0.sched)) nodes; spares=$(length(CB.active_spares()))")

SRV = start_mock(MOCK_PORT)
CB.RESPEC_ENABLED[] = true
CB.schedule_ood!(OOD_STEP, ood_action!)   # one-shot fault injection once the frontier has opened
println(">>> mock /propose up; ready=$(CB.respec_service_ready()); RESPEC_ENABLED=$(CB.RESPEC_ENABLED[])")
Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Info))

# [KO] 통과/실패 카운터(상자)와 간단한 검사 헬퍼. cond 가 참이면 PASS 출력+통과+1, 아니면 FAIL+실패+1.
npass = Ref(0); nfail = Ref(0)
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))

# seam loop: ood_inject_step! -> step -> respec_step!; capture the respec verdict.
# [KO] mock_respec 의 루프와 같은 구조지만, respec 판정(admitted/fallback/rejected)과 진전 peak 만 추적.
function run_seam_loop(env; cap=120_000, stall_limit=8000)
    prev = length(env.cache.closed_set); stall = 0
    respec_status = Ref{Symbol}(:none); n0 = prev; peak = prev   # respec_status=마지막 판정, peak=최대 완료수
    for it in 1:cap
        CB.ood_inject_step!(env, it)
        CB.step_environment!(env)
        st = CB.respec_step!(env)
        if st in (:admitted, :fallback, :rejected)
            respec_status[] = st; @info "[E2E-1-1] respec_step! @it=$it -> $st"   # [KO] 판정을 기록
        end
        try CB.update_planning_cache!(env, 0.0) catch e
            return (status=:asserted, closed=length(env.cache.closed_set), iters=it, respec=respec_status[], peak=peak)
        end
        c = length(env.cache.closed_set); peak = max(peak, c)   # [KO] peak=지금까지 도달한 최대 완료수
        stall = c > prev ? 0 : stall + 1; prev = c
        CB.project_complete(env) && return (status=:complete, closed=c, iters=it, respec=respec_status[], peak=peak)
        stall >= stall_limit && return (status=:stalled, closed=c, iters=it, respec=respec_status[], peak=peak)
    end
    return (status=:capped, closed=prev, iters=cap, respec=respec_status[], peak=peak)
end

env = deepcopy(ENV0)
total = Graphs.nv(env.sched); n0 = length(env.cache.closed_set)
r = run_seam_loop(env)
try close(SRV) catch end

println("\n==== RESULT (mock e2e ReplaceAgent seam) ====")
println("closed $n0 -> $(r.closed) (peak $(r.peak))/$total  status=$(r.status)  respec_verdict=$(r.respec)")
# Assert the WIRING (not full completion, which is gated on the R1 stall):
# [KO] 검사하는 건 "배선이 작동하는가"(완주 아님). 아래 4개가 모두 참이어야 seam GREEN.
check("respec seam fired with :admitted (NL->ReplaceAgent->dispatch->replace_robot!)", r.respec == :admitted)   # respec 이 교체를 승인했는가
check("no RVO/identity assert (faulted robot didn't crash the sim)", r.status != :asserted)   # 고장 로봇이 시뮬을 크래시내지 않았는가
check("hand-off made progress past the fault point", r.peak > FAULT_AT)   # 교체 후 고장지점 이상으로 진전했는가
check("a spare was consumed from a pool", length(CB.active_spares()) == 4*NSPARE - 1)   # 스페어가 딱 1개 소모됐는가

CB.RESPEC_ENABLED[] = false; CB.clear_ood_schedule!(); CB.clear_restriction_zones!()   # [KO] 전역 상태 원상복구
CB.clear_spare_pools!(); CB.clear_faulted_robots!()
println("\n==== mock e2e ReplaceAgent: $(npass[]) passed, $(nfail[]) failed ====")
println(nfail[] == 0 ?
    "SEAM GREEN (NL -> mock LLM -> ReplaceAgent -> verify_replace -> spare hand-off enacted). " *
    "Full completion gated on the known R1 frontier-graft stall." :
    "SOME FAILED")
nfail[] == 0 || error("mock_replace_e2e had $(nfail[]) failure(s)")   # [KO] 하나라도 실패면 에러로 종료(CI 신호)
end

# =============================================================================
# full_loop -- Enabled-seam end-to-end driver for the RESUME full-loop.
#   Build a real env, run the sim to a mid-build state, inject an OOD (robot fault), and
#   confirm the build RESUMES through the verified reassignment and reaches project_complete
#   WITHOUT restarting finished work (closed_set never regresses). Drives the PRODUCTION seam
#   exactly as simulate! does: step_environment! -> respec_step! -> update_planning_cache!.
#   Two modes, auto-selected: LLM seam (respec_service_ready) or LLM-free direct reassign.
#   Force LLM-free with RESPEC_FULLLOOP_NOLLM=1.
# =============================================================================
# [KO] 시나리오3: 빌드 중간에 고장을 주입해도 "이어서(resume)" 끝까지 완주하는지 확인.
#      핵심 = 이미 끝난 작업(closed_set)이 절대 되돌아가지 않아야 함(monotone). 두 모드 자동선택:
#      LLM seam(서비스 있음) 또는 LLM 없이 직접 재배정(reassign). production 이음새와 동일 경로로 구동.
function scenario_full_loop()
_setup_milp!()

INJECT_AT_CLOSED = 24      # step to this many closed nodes, then inject the fault
                           # [KO] 완료수가 24 될 때까지 진행한 뒤 고장 주입
STEP_CAP         = 100_000 # hard cap on sim steps (build completes well before)
                           # [KO] 시뮬 스텝 상한(보통 이보다 훨씬 전에 완주)

# [KO] tractor env 를 큰 스택에서 빌드(시뮬 직전 상태). 여기선 nav 기능(RVO 등)을 꺼서 빠르게.
function build_env()
    pp = CB.get_project_params(4)   # tractor
    return run_with_stack(2_000_000_000) do
        CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
            model_scale=pp[:model_scale], num_robots=pp[:num_robots],
            assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
            log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false,
            dispersion_flag=false, open_animation_at_end=false, save_animation=false,
            save_animation_along_the_way=false, write_results=false,
            overwrite_results=false, look_for_previous_milp_solution=false,
            save_milp_solution=false, return_env_before_sim=true)
    end
end

# Pick a still-valid robot on a PENDING transport team so the fault forces a real reassign.
# [KO] 고장 낼 로봇 고르기: 아직 안 끝난(pending) 운반팀에 속한 유효 로봇 → 고장 시 진짜 재배정이 강제됨.
function pick_faultable_agent(env)
    seen = CB.AbstractID[]     # [KO] 이미 본 로봇 id 모음(중복 방지)
    for v in Graphs.vertices(env.sched)
        node = CB.get_node_from_id(env.sched, CB.get_vtx_id(env.sched, v))
        node isa CB.RobotGo || continue       # [KO] RobotGo(로봇 이동 작업) 노드만 관심
        rid = try CB.entity(node).id catch; nothing end   # [KO] 노드가 가리키는 로봇 id(없으면 nothing)
        (rid isa CB.RobotID && CB.valid_id(rid) && !(rid in seen)) || continue   # 유효+처음 본 로봇만
        push!(seen, rid)
    end
    for rid in seen
        # [KO] 그 로봇이 pending 운반팀에 속해 있으면 그걸 반환(재배정이 필요한 후보)
        !isempty(CB.transport_teams_with_agent(env, rid; pending_only = true)) && return rid
    end
    return isempty(seen) ? nothing : first(seen)   # [KO] 없으면 아무 로봇이라도(또는 nothing)
end

# one production-seam step; returns the new closed count
# [KO] production 이음새 한 스텝: 물리전진 → respec 처리 → 캐시갱신. 새 완료수 반환.
function seam_step!(env)
    CB.step_environment!(env)
    CB.respec_step!(env)                      # no-op unless RESPEC_ENABLED[]
                                              # [KO] RESPEC_ENABLED 가 꺼져 있으면 아무것도 안 함
    CB.update_planning_cache!(env, 0.0)
    return length(env.cache.closed_set)
end

# [KO] 이 시나리오의 본체: 빌드→주입지점까지 진행→고장 주입(LLM 또는 직접 재배정)→완주까지 resume→판정.
function main()
    println(">>> building tractor env (slow, ~minutes)...")
    env = build_env()
    total = Graphs.nv(env.sched)
    println(">>> env ready: $total nodes, closed=$(length(env.cache.closed_set))")

    # --- phase 1: run to the injection point --------------------------------
    # [KO] 1단계: 완료수가 INJECT_AT_CLOSED 될 때까지(또는 완주하면 중단) 시뮬 진행.
    iters = 0
    while length(env.cache.closed_set) < INJECT_AT_CLOSED && iters < STEP_CAP
        seam_step!(env); iters += 1
        CB.project_complete(env) && break
    end
    n_inject = length(env.cache.closed_set)   # [KO] 고장 주입 직전의 완료수(되돌아가지 않아야 할 기준선)
    println(">>> reached injection point: closed=$n_inject after $iters steps")

    agent = pick_faultable_agent(env)
    agent === nothing && (println("!! no valid robot to fault — aborting"); return false)   # 고장 낼 로봇 없으면 중단

    # [KO] LLM 사용 여부: NOLLM 환경변수가 없고 서비스가 살아있으면 LLM seam, 아니면 직접 재배정.
    use_llm = !haskey(ENV, "RESPEC_FULLLOOP_NOLLM") && CB.respec_service_ready()
    if use_llm
        k = CB.get_id(agent)
        event = "Robot R$k has stopped responding and must be removed from service"   # [KO] LLM 에 줄 NL
        println(">>> OOD inject (LLM seam): \"$event\"  [agent=$agent]")
        CB.RESPEC_ENABLED[] = true
        CB.push_ood!(event)
        # the seam translates+verifies+commits on the next respec_step!
        # [KO] 다음 respec_step! 에서 번역→검증→반영이 일어남
    else
        println(">>> OOD inject (LLM-free): direct reassign of $agent")
        # [KO] LLM 없이: 로봇 고장+재배정을 직접 호출. resume=이어서, admitted 아니면 중단.
        res = CB.fault_robot_and_reassign!(env, agent; resume = true, verbose = true)
        res.status == :admitted || (println("!! reassign $(res.status) — cannot resume"); return false)
    end

    n_after = length(env.cache.closed_set)
    if n_after < n_inject
        println("❌ closed_set REGRESSED at commit: $n_inject -> $n_after"); return false   # [KO] 커밋에서 되돌아가면 실패
    end

    # --- phase 2: RESUME to completion --------------------------------------
    # [KO] 2단계: 완주까지 계속 진행하며, 완료수가 한 번이라도 줄면 monotone=false(되돌아감 감지).
    monotone = true; prev = n_after; resume_iters = 0
    while resume_iters < STEP_CAP
        c = seam_step!(env)
        c < prev && (monotone = false)     # [KO] 완료수가 감소 = 이미 끝낸 일을 다시 함 = 실패 신호
        prev = c; resume_iters += 1
        CB.project_complete(env) && break
    end
    CB.RESPEC_ENABLED[] = false   # leave the global switch off for any later use
                                  # [KO] 이후 사용을 위해 전역 스위치는 꺼둠

    done = CB.project_complete(env)
    ms = round(CB.makespan(env.sched), digits = 2)   # [KO] makespan = 전체 완료까지 걸리는 총 시간(작을수록 좋음)
    pass = done && monotone && n_after >= n_inject   # [KO] 완주 + 되돌아감 없음 + 커밋에서 안 줄어듦 = PASS
    println("="^70)
    println("RESULT  inject@closed=$n_inject  ->(commit) $n_after  ->(resume) $prev / $total")
    println("        complete=$done  monotone=$monotone  resume_steps=$resume_iters  makespan=$ms")
    println("        ", pass ? "✅ FULL LOOP PASS — reassigned and built to completion" :
                               "❌ FULL LOOP FAIL")
    println("="^70)
    return pass
end

ok = main()
exit(ok ? 0 : 1)   # [KO] PASS 면 종료코드 0, 아니면 1(스크립트 성공/실패를 셸에 알림)
end

# =============================================================================
# selfheal -- AUTONOMOUS SELF-HEALING VERIFICATION HARNESS (headless).
#   Run the REAL energy-adaptive build with the live LLM re-spec layer; whenever the LLM's
#   replan loops on the SAME warning/verdict while the sim makes NO progress, STOP that run,
#   record a structured diagnostic verdict, and move on. Drives run_lego_demo's FULL simulate!
#   loop HEADLESS (save_animation=false). Scenario: N_BATTERY soft battery OODs
#   (DeprioritizeAgent) + one central NO-GO zone (whole-build relocation) over a real physics
#   run. REAL LLM service must be UP on :8000 (health checked; aborts if down).
#   ENV: SEEDS (csv), MAXNP, MODE, N_BATTERY, N_OOD, CLOSED_HI, ZONE_CLOSED, ZONE_R, ENERGY_W,
#     PROJECT, VERDICT (jsonl out path), RESPEC_SERVICE_URL.
# =============================================================================
# [KO] 시나리오4: 진짜 LLM 을 켜고 에너지-적응형 빌드를 headless(화면無)로 돌리는 자율 self-healing 검증.
#      LLM 이 같은 경고/판정을 반복하는데 시뮬은 전혀 진전 없으면(=헛돎) 그 실행을 멈추고 구조화된 진단을
#      기록한 뒤 다음 seed 로 넘어감. soft=배터리+중앙구역 / hard=고장+배터리+구역 스트림. LLM 서비스 :8000 필수.
function scenario_selfheal()
ENV["RESPEC_SERVICE_URL"] = get(ENV, "RESPEC_SERVICE_URL", "http://127.0.0.1:8000")   # [KO] 진짜 LLM 서비스 주소

# ---- knobs ------------------------------------------------------------------
# [KO] 아래는 전부 환경변수로 조절하는 손잡이(knob)들. parse.(...) 의 점(.)=벡터 원소마다 parse 적용(브로드캐스트).
_seeds_env = get(ENV, "SEEDS", "7,11,13,17,23")
SEEDS       = parse.(Int, split(_seeds_env, ","))         # [KO] "7,11,.." 를 쉼표로 쪼개 정수 배열로
MAXNP       = parse(Int,     get(ENV, "MAXNP", "4500"))    # no-progress steps -> terminate (allows reform @2000,4000)
                                                          # [KO] 진전 없는 스텝이 이만큼이면 종료(2000/4000 에서 재형성 여유)
MODE        = get(ENV, "MODE", "soft")                    # soft = battery+central zone; hard = fault+battery+zone stream
N_BATTERY   = parse(Int,     get(ENV, "N_BATTERY", "2"))   # [KO] 배터리 OOD 개수
N_OOD       = parse(Int,     get(ENV, "N_OOD", "6"))       # hard-mode: # of random mixed OOD events
CLOSED_HI   = parse(Int,     get(ENV, "CLOSED_HI", "200")) # hard-mode: spread OOD up to this closed-count
ZONE_CLOSED = parse(Int,     get(ENV, "ZONE_CLOSED", "60"))# [KO] 완료수가 이 값일 때 중앙 no-go 구역 발동
ZONE_R      = parse(Float64, get(ENV, "ZONE_R", "2.5"))
ENERGY_W    = parse(Float64, get(ENV, "ENERGY_W", "0.01")) # [KO] objective 에서 에너지(효율) 가중치
PROJECT     = parse(Int,     get(ENV, "PROJECT", "4"))
VERDICT     = get(ENV, "VERDICT",                          # [KO] seed 별 결과를 한 줄 JSON 으로 남길 파일 경로
    joinpath(pkgdir(CB), "..", "verify_selfheal_verdicts.jsonl"))

_setup_milp!()

# [KO] 계획 objective 를 "속도 1.0 고정 + 에너지효율 ENERGY_W" 로 설정, 배터리 소모 모델도 세팅.
CB.set_planning_objective_weights!(speed = 1.0, efficiency = ENERGY_W)
CB.set_energy_model!(pickup_overhead = 0.0, idle_power = 1.0, load_power = 0.25)

# This scenario's run_with_stack RETURNS (:error, e)/(:ok, res) instead of throwing (its
# per-seed loop switches on the status), so it keeps its own variant nested here.
# [KO] 이 시나리오 전용 run_with_stack: 에러를 던지지 않고 (:error, e) / (:ok, 결과) 튜플로 돌려줌.
#      seed 하나가 예외로 죽어도 전체를 멈추지 않고 다음 seed 로 넘어가려는 것(공용 버전과 계약이 다름).
function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing)
    done = Threads.Atomic{Bool}(false)
    wrapper = function ()   # [KO] 태스크에서 돌 함수: 성공→res, 실패→err, 끝나면 done=true
        try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end
    end
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int), wrapper, nothing, stacksize)   # 큰 스택 태스크 생성
    t.sticky = false; schedule(t)
    while !done[]; sleep(0.05); end   # [KO] 완료까지 대기(폴링)
    if err[] !== nothing
        e, bt = err[]; showerror(stderr, e, bt); println(stderr)
        return (:error, e)   # [KO] 던지지 않고 에러를 값으로 반환
    end
    return (:ok, res[])
end

# [KO] 반지름 가장 큰 대기원 = 빌드 중심으로 보는 헬퍼(위 다른 시나리오와 동일).
_root_id(env) = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))
# [KO] 중앙 no-go 구역 발동: 빌드 중심에 진입금지 구역을 실제로 추가하고 NL 문장을 반환.
function central_zone_action!(env)
    gs = CB.root_deposit_goals(env)
    zc = isempty(gs) ? Vector{Float64}(CB.get_center(env.staging_circles[_root_id(env)])[1:2]) : sum(gs) ./ length(gs)
    CB.add_restriction_zone!(:zone, zc, ZONE_R)
    @info "[VERIFY] central no-go ZONE @ $(round.(zc; digits=2)) R=$ZONE_R"
    return "A safety exclusion zone is now active over the central build area; robots must not enter or pass through it."
end

# machine-readable verdict line (one JSON obj per seed)
# [KO] seed 하나의 결과를 기계가 읽을 JSON 한 줄로 파일에 덧붙임(append). 나중 집계/분석용.
function write_verdict(seed, complete, closed, total, term, extra)
    rate = total == 0 ? 0.0 : round(closed / total, digits = 4)   # [KO] 완료 비율(0 나눗셈 방지)
    esc(s) = replace(string(s), "\"" => "'", "\\" => "/")         # [KO] JSON 깨짐 방지용 간단 이스케이프
    line = string("{\"seed\":", seed,
        ",\"complete\":", complete,
        ",\"closed\":", closed, ",\"total\":", total, ",\"rate\":", rate,
        ",\"term\":\"", esc(term), "\"",
        ",\"note\":\"", esc(extra), "\"}")
    open(VERDICT, "a") do io; println(io, line); end   # [KO] "a"=append 모드로 파일 열어 한 줄 추가
    println("VERDICT ", line); flush(stdout)
end

# Full dump of the TERMINAL stuck state when a run ends INCOMPLETE — the "stop and
# diagnose the problem at that point" the harness exists for.
# [KO] 완주 못 하고 끝났을 때, 그 "막힌 최종 상태"를 자세히 덤프(진단). 이 harness 의 존재 이유.
#      활동 중 노드 유형별 개수, 목표 도달/이동중 로봇 수, 구역 수, 한 로봇이 여러 팀을 먹이는 과구독 등.
function terminal_report(env)
    try CB.diagnose_transport_stall(env) catch e; println("  [TERMINAL] diag failed: $e") end   # 내장 진단(실패해도 무시)
    sched = env.sched
    types = Dict{String,Int}(); atg = 0; enr = 0; ds = Float64[]   # types=유형별개수, atg=목표도달수, enr=이동중수, ds=거리들
    team_load = Dict{Any,Int}()   # robot -> # of FormTransportUnit it feeds (over-subscription)
                                  # [KO] 로봇 -> 그 로봇이 먹이는 FTU 개수(1 초과면 과구독=정체 원인 후보)
    ttol = CB.capture_distance_tolerance()   # [KO] "도착했다"고 볼 허용 거리
    for v in collect(env.cache.active_set)   # [KO] 활동 중(active) 노드들을 순회
        node = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        nm = string(nameof(typeof(node)))    # [KO] 노드의 타입 이름(문자열)
        types[nm] = get(types, nm, 0) + 1     # [KO] 유형별 카운트 +1
        if node isa CB.RobotGo || node isa CB.TransportUnitGo
            d = try
                # [KO] 현재 위치 s 와 목표 g 사이의 2D 거리 계산(abs2=제곱, sum→sqrt=유클리드거리)
                s = CB.global_transform(CB.entity(node)); g = CB.global_transform(CB.goal_config(node))
                sqrt(sum(abs2, (Vector{Float64}(s.translation) .- Vector{Float64}(g.translation))[1:2]))
            catch; NaN end
            isnan(d) || (push!(ds, d); d <= ttol ? (atg += 1) : (enr += 1))   # 허용거리 내면 도달, 아니면 이동중
        end
        if node isa CB.RobotGo
            outs = CB.Graphs.outneighbors(sched, v)   # [KO] 이 노드의 다음(후속) 노드들
            if !isempty(outs)
                nx = CB.get_node_from_id(sched, CB.get_vtx_id(sched, outs[1]))
                # [KO] 다음이 FormTransportUnit 이면 = 이 로봇이 그 팀을 먹임 → team_load 카운트 +1
                nx isa CB.FormTransportUnit && (team_load[string(CB.node_id(CB.entity(node)))] = get(team_load, string(CB.node_id(CB.entity(node))), 0) + 1)
            end
        end
    end
    # [KO] 거리들의 최소/최대/평균 요약 문자열(비었으면 n/a)
    dsum = isempty(ds) ? "n/a" : "min=$(round(minimum(ds),digits=2)) max=$(round(maximum(ds),digits=2)) mean=$(round(sum(ds)/length(ds),digits=2))"
    over = sort([(k, c) for (k, c) in team_load if c > 1]; by = x -> -x[2])   # [KO] 과구독(>1) 로봇을 많이 먹인 순으로 정렬
    println("  [TERMINAL] RESPEC_HOLD=$(CB.RESPEC_HOLD[])  active_types=$types")
    println("  [TERMINAL] Go-nodes: AT-goal/waiting=$atg EN-ROUTE=$enr dist[$dsum] zones=$(length(CB.RESTRICTION_ZONES[]))")
    println("  [TERMINAL] over-subscribed robots (feeding >1 forming team): $(isempty(over) ? "none" : over)")
    flush(stdout)
end

# [KO] seed 사이에 전역 상태(스위치/예약/구역/편향/배터리/카메라)를 모두 원상복구. 오염 방지.
function reset_globals!()
    CB.RESPEC_ENABLED[] = false
    CB.clear_ood_schedule!(); CB.clear_restriction_zones!(); CB.clear_agent_bias!()
    try CB.BATTERY_FLEET[] = nothing catch end   # [KO] 배터리 상태 초기화(실패해도 무시)
    CB.CAMERA_FOLLOW[] = false
end

# assert the real LLM service is reachable BEFORE burning a build
# [KO] 비싼 빌드를 시작하기 전에 진짜 LLM 서비스가 살아있는지 먼저 확인, 아니면 즉시 종료(1).
if !CB.respec_service_ready()
    println("FATAL: LLM service not reachable at $(ENV["RESPEC_SERVICE_URL"]) — start uvicorn on :8000 first.")
    exit(1)
end
println(">>> LLM service UP at $(ENV["RESPEC_SERVICE_URL"]); verdicts -> $VERDICT")
println(">>> seeds=$(SEEDS)  MAXNP=$MAXNP  N_BATTERY=$N_BATTERY  ZONE_CLOSED=$ZONE_CLOSED  ZONE_R=$ZONE_R  ENERGY_W=$ENERGY_W")

pp = CB.get_project_params(PROJECT)

# [KO] 각 seed 마다: 상태 초기화 → OOD 대본 예약 → 전체 시뮬 실행 → 결과 판정/기록.
for seed in SEEDS
    println("\n", "="^78)
    println("===== SEED $seed =====")
    println("="^78); flush(stdout)
    reset_globals!()

    # --- schedule the OOD story (battery x N_BATTERY + one central zone) --------
    CB.RESPEC_ENABLED[] = true
    # [KO] 스텝 1 에 배터리 기능을 켜는 OOD 예약(익명함수를 do 없이 인자로 직접 넘김).
    #      soc_target=0.5 목표로 페널티, hard_mult 는 방전 임박 시 강한 벌점.
    CB.schedule_ood!(1, function (env)
        CB.enable_battery!(env; params = CB.demo_battery_params())
        CB.set_battery_penalty!(gain = 6.0, soc_target = 0.5, hard_mult = 1.0e3)
        @info "[VERIFY] battery ON ($(length(CB.BATTERY_FLEET[].soc)) robots)"
        return nothing   # [KO] nothing 반환 = 이 OOD 는 NL 을 방출하지 않음(내부 상태만 바꿈)
    end)
    if MODE == "hard"
        # full multi-OOD stream: robot FAULTS (-> ReplaceAgent -> spare hand-off -> the
        # team-wedge/reform/recovery chain), battery degradations, and no-go zones, at
        # random build-progress points. This is the path the self-heal recovery exists for.
        # [KO] hard 모드: 고장/배터리/구역 3종을 무작위 진행지점에 섞어 예약(self-heal 이 진짜 필요한 경로).
        trg = CB.schedule_random_ood!(; n = N_OOD, kinds = [:fault, :battery, :zone],
            closed_lo = 8, closed_hi = CLOSED_HI, seed = seed)
        println("  [hard] scheduled $(length(trg)) mixed OOD at closed=",
            join(sort([t.closed_at for t in trg]), ","))
    else
        # [KO] soft 모드: 배터리 OOD 여러 개 + 완료수 ZONE_CLOSED 에 중앙 구역 하나.
        CB.schedule_random_ood!(; n = N_BATTERY, kinds = [:battery], closed_lo = 8,
            closed_hi = max(12, ZONE_CLOSED - 10), seed = seed)
        CB.schedule_ood_at_closed!(ZONE_CLOSED, central_zone_action!)
    end

    # --- run the FULL sim loop, headless --------------------------------------
    # [KO] 전체 시뮬(simulate!)을 화면저장 없이 끝까지 실행. status 는 :ok/:error, payload 는 결과.
    status, payload = run_with_stack(2_000_000_000) do
        CB.run_lego_demo(; ldraw_file = pp[:file_name], project_name = pp[:project_name],
            model_scale = pp[:model_scale], num_robots = pp[:num_robots], assignment_mode = :greedy,
            milp_optimizer = :highs, optimizer_time_limit = 60, log_level = Logging.Info,
            rvo_flag = true, tangent_bug_flag = true, dispersion_flag = true,
            save_animation = false, open_animation_at_end = false,
            save_animation_along_the_way = false, write_results = false, overwrite_results = false,
            look_for_previous_milp_solution = false, save_milp_solution = false,
            max_num_iters_no_progress = MAXNP, return_env_before_sim = false)
    end

    if status == :error
        # [KO] 실행이 예외로 죽었으면 예외 첫 줄을 verdict 에 기록하고 다음 seed 로.
        write_verdict(seed, false, -1, -1, "exception",
            first(split(sprint(showerror, payload), "\n")))
        reset_globals!(); continue
    end

    env, _stats = payload          # [KO] 성공 payload 는 (env, 통계) 튜플. 통계는 여기선 안 씀(_stats).
    total  = Graphs.nv(env.sched)
    closed = length(env.cache.closed_set)
    complete = CB.project_complete(env)
    term = complete ? "complete" : "no_progress_terminate"   # [KO] 종료 사유
    complete || terminal_report(env)          # dump the exact terminal stuck state for diagnosis
                                              # [KO] 완주 못 했으면 막힌 상태를 진단 덤프
    # [KO] 배터리가 켜져 있었으면 최소 SoC/편차 요약을 verdict 에 덧붙임.
    batt = CB.BATTERY_FLEET[] === nothing ? "" :
        (r = CB.battery_report(); "min_soc=$(round(r.min_soc,digits=3)) spread=$(round(r.soc_spread,digits=3))")
    write_verdict(seed, complete, closed, total, term, batt)
    reset_globals!()
end

println("\n>>> DONE. verdicts written to $VERDICT")
end

# =============================================================================
# spare_replace -- OOD 1-1 Part A4 done-gate (LLM-free).
#   Builds a nav-ON env WITH 4 directional spare pools, steps to mid-build, faults an active
#   robot, hands its remaining chain to the nearest spare via replace_robot! (no MILP), and
#   resumes to completion. The core hypothesis test: does the spare 1:1 hand-off let the build
#   COMPLETE where reassignment double-books? Asserts: spares idle pre-fault; replace_robot!
#   -> :replaced; closed_set monotone; project_complete; faulted robot never crashes RVO.
#   ENV: FAULT_AT, NSPARE, FAULT_OBSTACLE, FAULT (0=control), PROJECT, TARGET, CLEAR_FAULTED,
#     PARK_RESTS, PARK_FAULTED, DYN_SERIAL, REFORM_TEAMS, REFORM_AT.
# =============================================================================
# [KO] 시나리오5: LLM 없이 replace_robot! 스페어 1:1 인계가 빌드를 "완주"시키는지 done-gate 검증.
#      가설 = 재배정(reassign)은 이중배정(double-book) 때문에 막히지만, 스페어 1:1 교체는 완주시킨다.
#      확인: 고장 전 스페어 유휴 → replace_robot!→:replaced → closed 단조증가 → project_complete → 고장로봇이 RVO 를 크래시내지 않음.
function scenario_spare_replace()
FAULT_AT = parse(Int, get(ENV, "FAULT_AT", "24"))   # [KO] 이 완료수까지 진행한 뒤 고장 주입
NSPARE   = parse(Int, get(ENV, "NSPARE", "2"))       # [KO] pool 당 스페어 수(총 4*NSPARE)
FAULT_OBSTACLE = get(ENV, "FAULT_OBSTACLE", "1") == "1"   # diag: drop a static obstacle on the dead robot?
                                                          # [KO] 죽은 로봇 자리에 정적 장애물을 둘지(== "1" 로 bool 화)
DO_FAULT = get(ENV, "FAULT", "1") == "1"                  # diag: FAULT=0 => control (spares present, no fault/replace)
                                                          # [KO] FAULT=0 이면 대조군: 스페어만 있고 고장/교체 없이 완주하나?

_setup_milp!()

# [KO] 통과/실패 카운터 + 검사 헬퍼(다른 시나리오와 동일 패턴).
npass = Ref(0); nfail = Ref(0)
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))

PROJECT = parse(Int, get(ENV, "PROJECT", "4"))   # 4=tractor(team carries), 1=colored_8x8(flat, solo)
                                                 # [KO] 4=팀운반 tractor, 1=단독운반 평면 모델
pp = CB.get_project_params(PROJECT)
println(">>> building nav-ON env ($(pp[:project_name])) WITH $(4*NSPARE) spares ($(NSPARE)/pool)...")
CB.clear_spare_pools!(); CB.clear_faulted_robots!(); CB.clear_restriction_zones!()
ENV0 = run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Error,
        rvo_flag=true, tangent_bug_flag=true, dispersion_flag=true,
        n_spare_per_pool=NSPARE,
        open_animation_at_end=false, save_animation=false, write_results=false,
        overwrite_results=false, look_for_previous_milp_solution=false,
        save_milp_solution=false, return_env_before_sim=true)
end
println(">>> env: $(Graphs.nv(ENV0.sched)) nodes; spare pools = $(collect(keys(CB.spare_pools())))")

# PRE-FAULT scan: does the BASE env already have any FTU fed by the SAME robot twice?
# (tells us if the duplicate-feeder is pre-existing build structure vs replace-induced)
# [KO] 고장 전 사전 점검: 원본 env 에 이미 "같은 로봇이 한 FTU 를 두 번 먹이는" 중복이 있나?
#      = 중복feeder 버그가 원래 구조 탓인지, 교체(replace) 탓인지 구분하려는 것. let...end = 지역 스코프.
let sched = ENV0.sched
    dup = 0
    for v in Graphs.vertices(sched)
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.FormTransportUnit || continue   # [KO] FTU(운반팀 형성) 노드만
        ids = Int[]
        for vp in Graphs.inneighbors(sched, v)   # [KO] 이 FTU 를 먹이는 선행(inneighbor) 노드들
            pn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vp))
            pn isa CB.RobotGo || continue
            r = try CB.entity(pn).id catch; nothing end
            r isa CB.RobotID && push!(ids, r.id)
        end
        if length(ids) != length(unique(ids))    # [KO] id 목록에 중복이 있으면(고유개수 < 전체개수)
            dup += 1
            dup <= 5 && println("[PRE-FAULT] FTU v=$v fed by robot ids $ids (DUPLICATE same-robot feeder)")
        end
    end
    println("[PRE-FAULT] FTUs with a same-robot duplicate feeder in BASE env: $dup")
end

env = deepcopy(ENV0)
total = Graphs.nv(env.sched)

# --- [1] spares present and IDLE (have an idle free node) pre-fault -------------
# [KO] [1] 고장 전: 스페어들이 등록돼 있고 모두 유휴(배정 안 됨) 상태인지 확인.
println("\n[1] spare pools idle pre-fault")
spares = CB.active_spares()
check("4*NSPARE spares registered", length(spares) == 4*NSPARE)
idle = count(s -> CB._idle_free_node(env.sched, s) !== nothing, spares)   # [KO] 유휴 노드를 가진 스페어 수
println("    -> $(idle)/$(length(spares)) spares have an idle free node")
check("all spares are idle (unassigned)", idle == length(spares))

# --- step helper: returns status NamedTuple --------------------------------------
# [KO] 시뮬을 특정 조건까지 진행시키는 헬퍼. until_closed 도달/완주/정체/상한 중 하나로 멈추고 상태 반환.
#      옵션(환경변수): DYN_SERIAL=스페어 frontier 직렬화, REFORM_TEAMS=끼인 팀 재형성, REFORM_AT=재형성 임계.
function step_to(env; until_closed=nothing, cap=250_000, stall_limit=8000)
    prev = length(env.cache.closed_set); stall = 0
    dyn = get(ENV, "DYN_SERIAL", "0") == "1"            # E1: dynamic serialization of spare frontiers
    reform = get(ENV, "REFORM_TEAMS", "0") == "1"       # ReformTeam: snap wedged teams on stall
    reform_at = parse(Int, get(ENV, "REFORM_AT", "1500"))   # no-progress steps before a re-formation
    for it in 1:cap
        CB.step_environment!(env)
        try CB.update_planning_cache!(env, 0.0) catch e
            return (status=:asserted, closed=length(env.cache.closed_set), iters=it, err=typeof(e))   # 캐시갱신 에러=실패
        end
        dyn && CB._enforce_serial_frontiers!(env)   # [KO] 켜져 있으면 스페어 작업을 순차로 강제
        c = length(env.cache.closed_set)
        stall = c > prev ? 0 : stall + 1; prev = c
        # CLOSED-LOOP: a sustained wedge -> re-form the stuck team(s), then keep going.
        # [KO] 오래 끼어 있으면(closed-loop) 끼인 팀을 재형성하고 정체 시계를 리셋한 뒤 계속.
        if reform && stall >= reform_at
            nmv = CB.reform_stuck_teams!(env)
            println("    [REFORM] stall=$stall -> repositioned $nmv straggler(s) into formation")
            stall = 0                                   # gave the team a chance; reset the wedge clock
        end
        until_closed !== nothing && c >= until_closed && return (status=:reached, closed=c, iters=it)   # 목표 완료수 도달
        CB.project_complete(env) && return (status=:complete, closed=c, iters=it)   # 완주
        stall >= stall_limit && return (status=:stalled, closed=c, iters=it)        # 정체
    end
    return (status=:capped, closed=prev, iters=cap)   # 상한 소진
end

# --- [2] step to mid-build -------------------------------------------------------
# [KO] [2] 빌드 중간(완료수 FAULT_AT)까지 진행. reached 로 멈춰야 정상.
println("\n[2] step to mid-build (target closed=$FAULT_AT)")
r1 = step_to(env; until_closed=FAULT_AT)
println("    -> $(r1.status) closed=$(r1.closed) iters=$(r1.iters)")
check("reached mid-build without assert/stall", r1.status == :reached)

# --- CONTROL: spares present, NO fault -> does the base build still complete? -----
# [KO] 대조군(FAULT=0): 스페어만 있고 고장/교체는 없이 완주하는지. 완주하면 "유휴 스페어 자체는 무해"가 증명됨.
if !DO_FAULT
    println("\n[CONTROL] spares present, NO fault -- run base build to completion")
    rc = step_to(env; cap=400_000)
    println("    -> $(rc.status) closed=$(rc.closed)/$total iters=$(rc.iters)")
    check("CONTROL base-with-spares completes", rc.status == :complete)
    CB.clear_spare_pools!(); CB.clear_faulted_robots!(); CB.clear_restriction_zones!()
    println("\n==== A4 CONTROL: $(npass[]) passed, $(nfail[]) failed ====")
    println(nfail[] == 0 ? "CONTROL GREEN (spares idle don't block; stall is the hand-off)" :
            "CONTROL FAILED (the idle spares themselves break the build)")
    exit(nfail[] == 0 ? 0 : 1)   # [KO] 대조군은 여기서 종료(교체 경로로 안 감)
end

# A CLEANLY-replaceable target: a robot at a free frontier (heading to its NEXT
# pickup, NOT mid-carry), so its hand-off doesn't strand an in-progress transport
# team. = an active RobotGo that is a `_first_pending_assignment` frontier whose
# robot is not also sitting in an active transport-unit team.
# [KO] "깔끔히 교체 가능한" 대상 고르기: 다음 픽업으로 가는 중(운반 중이 아닌) 로봇.
#      그래야 교체가 진행 중인 운반팀을 좌초시키지 않음. = pending frontier 이면서 활성 운반팀에 안 낀 로봇.
function pick_clean_target(env)
    sched = env.sched
    # [KO] 로봇 rid 가 지금 활성 운반팀에 끼어 있는지 판정(do 블록=any 에 넘기는 술어함수).
    in_active_team(rid) = any(env.cache.active_set) do v
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        (n isa CB.FormTransportUnit || n isa CB.TransportUnitGo) || return false
        team = try CB.robot_team(CB.entity(n)) catch; nothing end
        team !== nothing && haskey(team, rid)
    end
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.RobotGo || continue
        rid = try CB.entity(n).id catch; nothing end
        rid isa CB.RobotID || continue
        pend = CB._first_pending_assignment(env, rid)        # has a clean frontier + pending work
        pend === nothing && continue                          # [KO] 남은 일이 없으면 건너뜀
        in_active_team(rid) && continue                       # skip mid-carry robots (MVP scope)
                                                              # [KO] 운반 중 로봇은 제외(MVP 범위)
        return rid
    end
    return nothing
end

# A SOLO-transport target: a robot whose remaining (non-closed) transport tasks are
# ALL solo (team size 1). Faulting such a robot is the MVP-clean case: no OTHER robot
# is waiting for it as a co-carrier, so the single-spare hand-off has no multi-robot
# timing coordination to satisfy. (Multi-robot-carry faults are future work.)
# [KO] "단독운반(solo)" 대상 고르기: 남은 운반 작업이 전부 팀크기 1 인 로봇.
#      그런 로봇을 고장 내면 공동운반자를 기다리는 다른 로봇이 없어 = 스페어 1:1 교체에 타이밍 조율이 필요 없음(MVP 깔끔).
function pick_solo_target(env)
    sched = env.sched
    # map robot id -> set of team sizes of its non-closed FTU memberships
    # [KO] 로봇 rid 가 속한 (미완료) FTU 들의 팀크기 목록을 반환.
    function robot_team_sizes(rid)
        sizes = Int[]
        for v in Graphs.vertices(sched)
            v in env.cache.closed_set && continue   # [KO] 이미 끝난 건 제외
            n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
            n isa CB.FormTransportUnit || continue
            team = try CB.robot_team(CB.entity(n)) catch; nothing end
            team !== nothing && haskey(team, rid) && push!(sizes, length(team))
        end
        sizes
    end
    cands = CB.RobotID[]
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.RobotGo || continue
        rid = try CB.entity(n).id catch; nothing end
        rid isa CB.RobotID || continue
        CB._first_pending_assignment(env, rid) === nothing && continue   # has pending work
        sizes = robot_team_sizes(rid)
        (!isempty(sizes) && all(==(1), sizes)) || continue               # ALL solo
                                                                          # [KO] 팀크기가 전부 1 이어야 후보
        push!(cands, rid)
    end
    isempty(cands) && return nothing
    return sort(cands, by = r -> r.id)[1]                                # DETERMINISTIC: lowest id
                                                                         # [KO] id 가장 작은 것 선택(결정적=재현성)
end

# --- [3] fault a SOLO-transport robot (MVP-clean), hand off to nearest spare ------
# [KO] [3] solo 로봇 하나 고장 → 가장 가까운 pool 에서 스페어 꺼내 replace_robot! 로 남은 작업 인계.
println("\n[3] fault a solo-transport robot + replace_robot! with nearest spare")
mode = get(ENV, "TARGET", "solo")   # [KO] 대상 선정 모드: solo/clean/그외(아무 활성 로봇)
faulted = mode == "solo" ? pick_solo_target(env) :
          mode == "clean" ? pick_clean_target(env) : CB._pick_active_robot(env)
faulted === nothing && (println("    (no solo target; falling back to clean)"); faulted = pick_clean_target(env))  # solo 없으면 clean 으로
faulted === nothing && (faulted = CB._pick_active_robot(env))   # fallback if none clean
                                                                # [KO] 그래도 없으면 아무 활성 로봇
println("    -> faulting robot R$(faulted === nothing ? "?" : faulted.id)")
check("found an active robot to fault", faulted !== nothing)
clear_faulted = get(ENV, "CLEAR_FAULTED", "0") == "1"     # tow dead robot off-grid (demo config)
                                                          # [KO] 죽은 로봇을 그리드 밖으로 견인할지(데모 설정)
nl = CB.fault_robot!(env; target=faulted, obstacle=FAULT_OBSTACLE, clear=clear_faulted)   # [KO] 실제 고장 처리 + NL 반환
println("    -> clear_faulted = $clear_faulted")
println("    -> fault obstacle registered: $FAULT_OBSTACLE")
println("    -> NL: $nl")
fpos = CB._robot_position_2d(env, faulted)   # [KO] 고장 로봇의 현재 2D 위치
pool = CB.nearest_pool(fpos)                 # [KO] 그 위치에서 가장 가까운 스페어 pool
println("    -> nearest pool = $(pool)")
check("a nearest spare pool exists", pool !== nothing)
spare = CB.pop_spare!(pool)                  # [KO] 그 pool 에서 스페어 하나 꺼냄(소모)
println("    -> donating spare R$(spare === nothing ? "?" : spare.id) from :$(pool)")
check("popped a spare from the pool", spare !== nothing)
park_rests = get(ENV, "PARK_RESTS", "1") == "1"   # [KO] 인계 후 남는 잔여 작업을 주차(park)할지
println("    -> park_rests = $park_rests")
res = CB.replace_robot!(env, faulted, spare; resume=true, park_rests=park_rests)   # [KO] 핵심: 고장로봇→스페어 1:1 인계
println("    -> replace_robot! status=$(res.status) slots=$(get(res,:slots,-1)) serialized=$(get(res,:serialized,-1)) fg=$(get(res,:fg,-1)) slot1=$(get(res,:slot1,-1))")
# DIAG R3: optionally PARK the faulted robot's dead frontier (force-close fg) so the
# faulted robot leaves the active frontier entirely, then rebuild the resume cache.
if get(ENV,"PARK_FAULTED","0") == "1" && haskey(res,:fg)
    # [KO] 진단옵션: 고장 로봇의 죽은 frontier(fg)를 강제로 닫아(active→closed) 활성에서 완전히 빼고 캐시 재구성.
    fg = res.fg
    fg in env.cache.active_set && delete!(env.cache.active_set, fg)
    push!(env.cache.closed_set, fg)
    CB.reset_cache_resume!(env.cache, env.sched)
    println("    -> PARK_FAULTED: force-closed faulted dead frontier fg=$fg; rebuilt cache")
end
check("replace_robot! -> :replaced", res.status == :replaced)      # [KO] 교체가 성공했는가
check("hand-off moved >=1 downstream task", get(res,:slots,0) >= 1) # [KO] 인계된 하위작업이 1개 이상인가

# --- [4] resume to completion (the done-gate) ------------------------------------
# [KO] [4] 교체 후 완주까지 진행 = 이 시나리오의 핵심 관문(done-gate). closed 가 되돌아가지 않아야 함.
println("\n[4] resume to completion")
closed_after_replace = length(env.cache.closed_set)   # [KO] 교체 직후 완료수(되돌아감 판정 기준)
r2 = step_to(env; cap=400_000)
println("    -> $(r2.status) closed=$(closed_after_replace) -> $(r2.closed)/$total iters=$(r2.iters)$(haskey(r2,:err) ? "  err=$(r2.err)" : "")")
check("closed_set monotone across replace (no regress)", r2.closed >= closed_after_replace)   # 단조증가(되돌아감 없음)
check("no RVO/identity assert on the faulted robot", r2.status != :asserted)   # 고장 로봇이 크래시 안 냄
check("PROJECT COMPLETE (core done-gate)", r2.status == :complete)             # 핵심: 완주했는가

# --- [5] stall diagnosis: dump the active frontier + faulted/spare involvement ----
# [KO] 노드 n 에서 로봇 id 를 안전하게 뽑는 헬퍼(없으면 nothing). rid = robot id.
_rid(n) = (try entity(n).id catch; nothing end)
# [KO] 정체 진단: 활성 frontier 를 덤프하고 그중 고장로봇(fid)/스페어(sid)가 어디에 얽혀 있는지 표시.
#      고장로봇이 아직 몇 개 노드에 묶였는지, 스페어가 pool 밖으로 나와 자기 작업으로 이동했는지 등.
function diagnose_stall(env, fid, sid)
    sched = env.sched
    println("    faulted=R$(fid===nothing ? "?" : fid.id)  spare=R$(sid===nothing ? "?" : sid.id)")
    nactive = 0
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        rid = _rid(n)
        tag = rid === nothing ? "" : (rid == fid ? "  <== FAULTED" : (rid == sid ? "  <== SPARE" : "  (R$(rid.id))"))
        nactive += 1
        nactive <= 40 && println("      active: $(typeof(n).name.name)$(tag)")
    end
    println("    total active frontier nodes: $nactive")
    isbound(n, who) = (n isa CB.RobotGo) && (_rid(n) == who)   # [KO] 노드 n 이 로봇 who 의 RobotGo 인지
    # [KO] fleft/sleft = 고장로봇/스페어가 아직 묶여 있는 "미완료 RobotGo" 개수. count(...) do v = 조건 만족 개수.
    fleft = fid === nothing ? 0 : count(Graphs.vertices(sched)) do v
        !(v in env.cache.closed_set) && isbound(CB.get_node_from_id(sched, CB.get_vtx_id(sched, v)), fid)
    end
    sleft = sid === nothing ? 0 : count(Graphs.vertices(sched)) do v
        !(v in env.cache.closed_set) && isbound(CB.get_node_from_id(sched, CB.get_vtx_id(sched, v)), sid)
    end
    println("    faulted robot still bound to $fleft non-closed RobotGo(s) (dead frontier fg expected = 1)")
    println("    spare   robot still bound to $sleft non-closed RobotGo(s) (its remaining adopted work)")
    # classify the stuck frontier by node type
    types = Dict{Symbol,Int}()
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        t = typeof(n).name.name
        types[t] = get(types, t, 0) + 1
    end
    println("    active frontier by type: $types")
    # did the spare actually move out of its pool toward its work?
    if sid !== nothing
        spos = CB._robot_position_2d(env, sid)
        pc = get(CB.spare_pool_centers(), :east, nothing)
        for (k, c) in CB.spare_pool_centers()   # find the pool the spare came from (nearest center)
            pc === nothing && (pc = c)
        end
        # nearest goal among the spare's active RobotGo nodes
        sgoal_d = Inf
        for v in env.cache.active_set
            n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
            (n isa CB.RobotGo && _rid(n) == sid) || continue
            g = try Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.goal_config(n)).translation)) catch; continue end
            sgoal_d = min(sgoal_d, norm(spos .- g))
        end
        println("    spare pos=$(round.(spos;digits=2)); dist to its nearest active goal=$(round(sgoal_d;digits=2)) (robot_r=$(round(CB.default_robot_radius();digits=3)))")
    end
end
# FTU formation diagnosis: for every active RobotGo whose next node is a
# FormTransportUnit, dump the team's per-member capture status (route_planning.jl:480
# requires ALL members in position simultaneously). Pinpoints who is blocking.
# [KO] FTU 형성 진단: 다음이 FormTransportUnit 인 활성 RobotGo 마다, 팀원 각자가 제자리(capture)에 왔는지 표시.
#      FTU 는 팀원 "전원"이 동시에 자리 잡아야 발동 → 누구 하나 안 오면 팀 전체가 막힘. 그 범인을 짚어냄.
function diagnose_ftu(env)
    sched = env.sched; st = env.scene_tree
    fr = CB.faulted_robots()
    shown = 0
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.RobotGo || continue
        outs = Graphs.outneighbors(sched, v); isempty(outs) && continue
        nxt = CB.get_node_from_id(sched, CB.get_vtx_id(sched, outs[1]))
        nxt isa CB.FormTransportUnit || continue
        feeder = _rid(n)   # [KO] 이 FTU 를 먹이는 로봇 id
        atgoal = CB.is_within_capture_distance(CB.global_transform(CB.entity(n)),   # [KO] feeder 가 자기 목표에 도달했나
                                               CB.global_transform(CB.goal_config(n)))
        # inneighbor readiness (route_planning.jl:474-478)
        inn = Graphs.inneighbors(sched, outs[1])
        inn_ready = all(vp -> (vp in env.cache.active_set) || (vp in env.cache.closed_set), inn)   # [KO] 선행들이 전부 준비됐나
        tu = CB.entity(nxt); team = CB.robot_team(tu)   # [KO] tu=운반유닛, team=팀원(로봇id->슬롯) 딕셔너리
        shown += 1
        shown > 6 && (println("    ... (more FTUs)"); break)   # [KO] 너무 많으면 6개까지만
        ftuv = outs[1]
        dep = CB._adopted_task_deposit(env, v)
        # --- STEP 0: slot goal_config(SCHEDULE) vs tu's expected capture slot(SCENE) drift ---
        # feeder_at_goal targets global_transform(goal_config(slot)); in_capture targets
        # global_transform(tu) ∘ child_transform(tu, rid) (hierarchical_geom_essentials.jl:1032-33).
        # If these disagree the spare can satisfy in_capture but never feeder_at_goal -> FTU never fires.
        # [KO] drift(어긋남) = "스케줄상 슬롯 목표"와 "장면상 실제 캡처 슬롯"의 위치 차이.
        #      둘이 다르면 스페어가 in_capture 는 만족해도 feeder_at_goal 은 영영 못 채워 FTU 가 안 켜짐(교체 함정).
        #      ∘ = 변환 합성(먼저 오른쪽, 그다음 왼쪽). NaN=계산못함, -1.0=예외.
        drift = NaN
        if feeder !== nothing
            try
                slot_goal = CB.global_transform(CB.goal_config(n))   # 스케줄상 슬롯의 목표 자세
                ct        = CB.child_transform(tu, feeder)            # tu 기준 이 feeder 의 자식 변환
                expected  = CB.global_transform(tu) ∘ ct             # 장면상 기대되는 캡처 위치
                drift = norm(Vector{Float64}(slot_goal.translation[1:2]) .-
                             Vector{Float64}(expected.translation[1:2]))   # 두 위치의 2D 거리
            catch e
                drift = -1.0
            end
        end
        println("    [slot v=$v -> FTU v=$ftuv -> deposit v=$(dep)] fed by R$(feeder===nothing ? "?" : feeder.id) (feeder_at_goal=$atgoal, inneighbors_ready=$inn_ready, GOAL_DRIFT=$(round(drift;digits=3))), team=$(length(team)):")
        for (mid, _) in team   # [KO] 팀원마다: 제자리(in_capture)에 왔는지 점검. mid=팀원 로봇 id.
            rn = try CB.get_node(st, mid) catch; nothing end   # [KO] 장면트리에서 그 로봇 노드
            rn === nothing && (println("      member R$(mid.id): <no scene node>"); continue)
            incap = CB.is_within_capture_distance(tu, rn)   # [KO] tu 의 캡처 자리에 이 팀원이 들어왔나
            ftag = haskey(fr, mid) ? " [FAULTED]" : (mid == spare ? " [SPARE]" : "")   # 고장/스페어 태그
            # for a member NOT in position, locate it: pos, whether it's a ROOT (drivable) or
            # captured elsewhere, its active node type, and dist to its nearest active goal.
            extra = ""
            if !incap
                pos = try Vector{Float64}(CB.project_to_2d(CB.global_transform(rn).translation)) catch; [NaN,NaN] end
                isroot = try CB.has_parent(rn, rn) catch; "?" end
                # find this member's active node(s)
                mact = Int[]; mgoal_d = Inf
                for vv in env.cache.active_set
                    nn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vv))
                    (_rid(nn) == mid) || continue
                    push!(mact, vv)
                    g = try Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.goal_config(nn)).translation)) catch; continue end
                    mgoal_d = min(mgoal_d, norm(pos .- g))
                end
                acttypes = join([string(typeof(CB.get_node_from_id(sched,CB.get_vtx_id(sched,vv))).name.name) for vv in mact], ",")
                extra = "  pos=$(round.(pos;digits=2)) root=$isroot active=[$acttypes] dist2goal=$(round(mgoal_d;digits=2))"
            end
            println("      member R$(mid.id): in_capture=$incap$ftag$extra")
        end
    end
    shown == 0 && println("    (no active RobotGo feeding a FormTransportUnit found)")
    # find any FTU with >1 spare feeder (the duplicate-feeder bug) and dump ALL its inneighbors
    # [KO] 같은 스페어가 한 FTU 를 2번 이상 먹이는 경우(=이중배정 버그)를 찾아 그 FTU 의 모든 선행을 덤프.
    println("    --- FTUs with duplicate spare feeders (the bug) ---")
    seen_ftu = Set{Int}()
    for v in Graphs.vertices(sched)
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.FormTransportUnit || continue
        v in seen_ftu && continue
        ins = Graphs.inneighbors(sched, v)
        # [KO] 이 FTU 의 선행 중 "스페어가 먹이는 RobotGo" 만 골라냄(filter+begin...end 블록 술어).
        sp_feeders = filter(vp -> begin
            pn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vp))
            pn isa CB.RobotGo && _rid(pn) == spare
        end, ins)
        length(sp_feeders) >= 2 || continue   # [KO] 2개 이상일 때만(=중복) 리포트
        push!(seen_ftu, v)
        println("    FTU v=$v has $(length(sp_feeders)) spare feeders; ALL inneighbors:")
        for vp in ins
            pn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vp))
            rid = _rid(pn)
            cl = vp in env.cache.closed_set ? "closed" : (vp in env.cache.active_set ? "active" : "future")   # [KO] 노드 상태 분류
            ppreds = join([string(typeof(CB.get_node_from_id(sched,CB.get_vtx_id(sched,vpp))).name.name) for vpp in Graphs.inneighbors(sched,vp)], ",")   # 선행의 선행 유형들
            println("      in v=$vp $(typeof(pn).name.name) R$(rid===nothing ? "?" : rid.id) [$cl] <-preds[$ppreds]")
        end
    end
end
# [KO] 완주 못 했을 때만 [5][6][7] 상세 진단을 돌림(왜 막혔는지 추적용).
if r2.status != :complete
    println("\n[5] STALL DIAGNOSIS (active frontier at stall)")
    diagnose_stall(env, faulted, spare)
    println("\n[6] FTU FORMATION DIAGNOSIS (who blocks each pending transport team)")
    diagnose_ftu(env)
    println("\n[7] SPARE THREAD STRUCTURE (is the adopted work a single sequential chain?)")
    # [KO] [7] 스페어가 받은 일이 "하나의 순차 사슬"인지 점검. 동시에 활성인 RobotGo 가 2개 이상이면 병렬화돼 꼬임.
    let sched = env.sched
        nactive_spare = 0
        for v in Graphs.vertices(sched)
            n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
            (n isa CB.RobotGo && _rid(n) == spare) || continue
            v in env.cache.closed_set && continue
            preds = Graphs.inneighbors(sched, v)
            predinfo = join([begin
                pn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vp))
                pc = vp in env.cache.closed_set ? "closed" : (vp in env.cache.active_set ? "active" : "future")
                "$(typeof(pn).name.name)[$pc]"
            end for vp in preds], ",")
            isact = v in env.cache.active_set
            isact && (nactive_spare += 1)
            outs = Graphs.outneighbors(sched, v)
            sucinfo = join([begin
                sn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vs))
                "$(typeof(sn).name.name)"
            end for vs in outs], ",")
            isterm = isempty(outs)   # [KO] 후속이 없으면 사슬의 끝(terminal)
            t0 = try round(Float64(CB.get_t0(sched, v)); digits=2) catch; "?" end   # [KO] 이 작업의 시작시각
            atg = try CB.is_within_capture_distance(CB.global_transform(CB.entity(n)),
                                                    CB.global_transform(CB.goal_config(n))) catch; "?" end   # 목표 도달 여부
            println("    spare RobotGo v=$v active=$isact t0=$t0 at_goal=$atg terminal=$isterm  preds=[$predinfo]  succs=[$sucinfo]")
        end
        println("    => spare has $nactive_spare CONCURRENTLY ACTIVE RobotGo(s) (should be 1 for a sequential thread)")
    end
end

CB.clear_spare_pools!(); CB.clear_faulted_robots!(); CB.clear_restriction_zones!()   # [KO] 전역 상태 정리
println("\n==== A4 spare_replace_test: $(npass[]) passed, $(nfail[]) failed ====")
println(nfail[] == 0 ? "ALL GREEN (spare 1:1 hand-off completes the build)" :
        "SOME FAILED (see above; likely R1 frontier-graft / R3 faulted-driving -- diagnose)")
end

# =============================================================================
# live_respec -- LIVE end-to-end: OOD -> Claude -> DSL -> verify -> admit -> re-solve,
#   through the RUNNING Python LLM service. This is the LIVE sibling of mock_respec/
#   mock_replace: real Claude does the NL->DSL translation. Builds the tractor env,
#   steps to some completed work, then runs 2 live OOD rounds. Bad refs route to the
#   safe fallback; valid re-specs are verified (completed work frozen) and re-solved.
#   REQUIRES: the Python service UP (RESPEC_SERVICE_URL, default :8000) with a valid
#   ANTHROPIC_API_KEY. If the service is down it reports and exits(0) (no LLM call).
# =============================================================================
# [KO] 시나리오6: 진짜 Claude(실행 중인 파이썬 서비스)로 NL→DSL→검증→admit→재solve 하는 라이브 e2e.
#      mock_respec/mock_replace 의 "진짜 LLM" 버전. tractor env 를 짓고 일부 진행시킨 뒤 라이브 OOD 2라운드.
#      잘못된 참조는 안전 fallback 으로, 유효한 re-spec 은 (끝난 일 freeze 후) 검증·재solve. 서비스 없으면 exit(0).
function scenario_live_respec()
# A robot-fault re-spec triggers a real MILP re-solve (reassignment). Greedy
# assembly never set a default optimizer, so set one with a feasibility-first gap
# (return the first feasible integer solution rather than proving optimality) so
# the re-solve is fast & reliable, and silence the per-solve HiGHS log spam.
# [KO] 로봇 고장 re-spec 은 실제 MILP 재solve(재배정)를 유발함. greedy 조립은 기본 최적화기를 안 세웠으므로
#      여기서 "최적 증명 말고 첫 실현해(feasible)만 빨리" 반환하도록 세팅(속도·안정) + HiGHS 로그 침묵.
_setup_milp!()

project_params = get_project_params(4)   # tractor

println(">>> building env (assignment only, no simulation)...")
env = run_with_stack(2_000_000_000) do   # [KO] 시뮬 없이 배정까지만 된 env 를 큰 스택에서 빌드
    run_lego_demo(;
        ldraw_file=project_params[:file_name],
        project_name=project_params[:project_name],
        model_scale=project_params[:model_scale],
        num_robots=project_params[:num_robots],
        assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
        log_level=Logging.Error,   # silence the benign greedy-assignment @warn spam
        rvo_flag=false, tangent_bug_flag=false, dispersion_flag=false,
        open_animation_at_end=false, save_animation=false,
        save_animation_along_the_way=false,
        write_results=false, overwrite_results=false,
        look_for_previous_milp_solution=false, save_milp_solution=false,
        return_env_before_sim=true,
    )
end
println(">>> env built: $(Graphs.nv(env.sched)) nodes")

# Step a little so the freeze path is exercised live too (some completed work).
# [KO] 조금 진행시켜 "완료된 일"을 만들어 둠 → freeze(끝난 일 고정) 경로도 라이브로 시험되게. _ = 안 쓰는 변수.
for _ in 1:1500
    CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
    length(env.cache.closed_set) >= 20 && break   # [KO] 완료 20개 되면 멈춤
end
println(">>> stepped: closed=$(length(env.cache.closed_set)) active=$(length(env.cache.active_set))")

# --- Service gate ------------------------------------------------------------
# [KO] 서비스 관문: LLM 서비스가 없으면 (시뮬은 안 죽음, fallback 으로 감) 안내 후 정상 종료(0).
if !CB.respec_service_ready()
    println("""

    !!! Python LLM service is NOT reachable at $(CB._RESPEC_SERVICE_URL).
        Start it in another terminal (see header of this file), then re-run.
        (The simulation itself never crashes on a down service — a missing
         service just routes to the safe fallback.)
    """)
    exit(0)
end
println(">>> LLM service is UP. Running live OOD rounds...\n")

# One live round: generate -> verify -> (admit:re-solve | reject:fallback).
# Crash-safe: an unresolvable / ungrammatical LLM proposal is caught and treated
# exactly as the production maybe_respecify! does — a Reject that routes to the
# safe fallback, never reaching the solver.
# [KO] 라이브 1라운드: LLM 생성 → 검증 → (admit 이면 재solve / reject 면 fallback).
#      크래시 안전: 해석 불가/문법 오류 제안은 잡아서 solver 근처도 못 가게 안전 reject 처리(production 과 동일).
function live_round(env, title, event)
    println("\n┌──────────────  $title")
    println("│ OOD event: ", event)
    inv = CB.build_invariant(env)   # [KO] 불변식(끝난 일의 시작/끝 시각 고정 등)을 만들어 이후 재solve 를 제약
    println("│ freeze: $(length(inv.frozen_t0)) t0 bounds, $(length(inv.frozen_tF)) tF bounds (completed work pinned)")

    local proposal   # [KO] try 밖에서도 쓰기 위해 스코프를 미리 선언
    try
        # [KO] NL(event)을 Claude 에 보내 DSL 제안으로 번역. id_resolver = "R3" 같은 참조를 실제 노드 id 로 변환.
        proposal = CB.llm_to_proposal(event, env; id_resolver = ref -> CB._default_id_resolver(env, ref))
    catch err
        msg = first(split(sprint(showerror, err), "\n"))
        println("│ Claude's proposal could NOT be resolved to the DSL: ", msg)
        println("└ RESULT: SAFELY REJECTED → fallback (nothing reached the solver).")
        return (title, "REJECT (unresolvable) → fallback", "—")   # [KO] 해석 실패 = 안전 reject
    end

    println("│ Claude proposed $(length(proposal.constraints)) constraint(s):")
    for c in proposal.constraints; println("│     ", c); end
    isempty(proposal.rationale) || println("│ rationale: ", first(split(proposal.rationale, "\n")))

    # A robot-fault (single ForbidAgent) cannot go through the generic compile path
    # (it would silently compile to zero constraints -> hollow admit). Dispatch to
    # the reassign machinery, exactly as the production maybe_respecify! now does.
    # [KO] 로봇 고장(ForbidAgent 하나)은 일반 컴파일 경로로 가면 제약 0개로 조용히 "빈 admit"이 됨.
    #      그래서 별도 재배정(reassign) 기계로 보냄(production maybe_respecify! 와 동일 처리).
    if CB._is_robot_fault(proposal)
        agent  = proposal.constraints[1].agent   # [KO] 고장난 에이전트
        teams0 = length(CB.transport_teams_with_agent(env, agent; pending_only = true))   # 이전에 속했던 pending 팀 수
        ms0    = CB.makespan(env.sched)          # [KO] 재배정 전 makespan
        res    = CB.fault_robot_and_reassign!(env, agent; verbose = false)   # 고장+재배정 실행
        if res.status == :admitted
            ms1 = CB.makespan(env.sched)
            println("│ ForbidAgent → reassign: $(agent) was on $(teams0) pending team(s), now on $(res.teams_after).")
            println("└ RESULT: ADMIT (reassigned) → makespan $(round(ms0, digits=2)) → $(round(ms1, digits=2))")
            return (title, "ADMIT (reassigned)",
                    "teams $(teams0)→$(res.teams_after), makespan $(round(ms0,digits=2))→$(round(ms1,digits=2))")
        else
            println("└ RESULT: $(res.status) → fallback (reassignment infeasible; safe-stop, schedule uncorrupted).")
            return (title, "$(res.status) → fallback", string(get(res, :reason, "—")))
        end
    end

    # [KO] 그 외 제약(예: ForbidZone/deadline)은 검증(verify) → Admit 이면 freeze 제약 걸고 MILP 재solve 후 커밋.
    verdict = CB.verify(proposal, env, inv)
    if verdict isa CB.Admit
        ms0 = CB.makespan(env.sched)
        # [KO] 끝난 일(t0_/tF_)을 고정한 채, 승인된 제약을 추가로 넣어 스케줄을 다시 최적화.
        milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
            optimizer=CB._respec_optimizer(), t0_=inv.frozen_t0, tF_=inv.frozen_tF,
            extra_constraints=verdict.proposal)
        CB.optimize!(milp)
        CB.commit_respec!(env, milp, verdict.proposal)   # [KO] 재solve 결과를 env 에 반영(커밋)
        ms1 = CB.makespan(env.sched)
        println("└ RESULT: ADMIT ($(verdict.n_constraints) constr) → re-solved; makespan $(round(ms0,digits=2)) → $(round(ms1,digits=2))")
        return (title, "ADMIT → re-solved", "makespan $(round(ms0,digits=2)) → $(round(ms1,digits=2))")
    else
        println("└ RESULT: REJECT(:$(verdict.reason)) → fallback. $(verdict.detail)")
        return (title, "REJECT(:$(verdict.reason)) → fallback", verdict.detail)   # [KO] 검증 실패 = 안전 fallback
    end
end

summary = Vector{Any}()   # [KO] 라운드별 결과(title, outcome, detail) 모음

# ROUND 1: a natural-language robot fault. The model tends to name the robot
# ("R3") rather than a schedule id — a real translation error the gate catches.
# [KO] 라운드1: 자연어 로봇 고장. 모델은 스케줄 id 대신 "R3" 처럼 부르기 쉬움 → 그 번역 오류를 관문이 잡음.
push!(summary, live_round(env, "ROUND 1: natural robot-fault event",
    "Robot R3 reports a motor fault and is immobile and cannot perform any task."))

# ROUND 2: a re-spec the model CAN express against real ids — we embed an actual
# open node id and a generous deadline so it resolves, verifies, and admits.
# [KO] 라운드2: 모델이 실제 id 로 표현 가능한 re-spec. 진짜 열린 노드 id + 넉넉한 deadline 을 심어 admit 되게.
open_ids = [CB.get_vtx_id(env.sched, v) for v in Graphs.vertices(env.sched)
            if !(CB.get_vtx_id(env.sched, v) in CB.build_invariant(env).closed_nodes)]   # [KO] 아직 안 끝난 노드 id 들
tgt = string(open_ids[end])   # [KO] 그중 하나를 대상 노드로
push!(summary, live_round(env, "ROUND 2: explicit deadline on a real node id",
    "Operations note: node $tgt must be completed no later than time 100000."))

println("\n╔══════════════  LIVE END-TO-END SUMMARY  ══════════════")
for (title, outcome, detail) in summary
    println("║ ", rpad(split(title, ":")[1], 8), " → ", outcome, detail == "—" ? "" : "   [$detail]")
end
println("╠═══════════════════════════════════════════════════════")
println("║ Real OOD text → Claude → formal DSL → verified (completed work frozen).")
println("║ Bad refs are rejected to the safe fallback; valid re-specs admitted & re-solved.")
println("║ PROOF the LLM was really called: see 'POST /propose 200 OK' in the uvicorn")
println("║ terminal — one line per round above.")
println("╚═══════════════════════════════════════════════════════")
end

# ---- dispatcher -------------------------------------------------------------
# [KO] "시나리오 키 -> 실행 함수" 표. 아래 실행부에서 이 표로 하나를 골라 부름.
const SCENARIOS = Dict(
    "mock_respec"   => scenario_mock_respec,
    "mock_replace"  => scenario_mock_replace,
    "full_loop"     => scenario_full_loop,
    "selfheal"      => scenario_selfheal,
    "spare_replace" => scenario_spare_replace,
    "live_respec"   => scenario_live_respec,
)
end # module E2E

# [KO] 이 파일을 직접 실행했을 때만 아래가 돎(엔트리포인트). 다른 데서 include 만 하면 실행 안 됨.
if abspath(PROGRAM_FILE) == @__FILE__
    # [KO] 키 우선순위: 환경변수 E2E > 명령줄 첫 인자 > 기본값 "mock_respec".
    key = get(ENV, "E2E", isempty(ARGS) ? "mock_respec" : ARGS[1])
    # [KO] 표에 없는 키면 사용 가능한 목록을 알려주며 에러(|| = 앞이 false 일 때만 뒤 실행).
    haskey(E2E.SCENARIOS, key) || error("unknown scenario '$key'. Available: $(join(sort(collect(keys(E2E.SCENARIOS))), ", "))")
    println(">>> running e2e scenario: $key")
    E2E.SCENARIOS[key]()   # [KO] 고른 시나리오를 실제 실행
end
