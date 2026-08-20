# tools/monitor/server.jl
# =============================================================================
# 모니터 컨트롤 서버 — 대시보드/스트림 static 서빙 + 온디맨드 OOD 데모 생성.
#   GET  /                         → dashboard.html
#   GET  /streams/<model>__<case>.jsonl , /visualization.html , 기타 static
#   GET  /models                   → LDraw_files 파일 목록(JSON)
#   POST /run  {model, case}       → run_demo.jl 서브프로세스 스폰(비차단) → 스트림 생성
#
# 실행:  ConstructionBots.jl 폴더에서 (python http.server 는 끄고)
#        julia +lts --project=. tools/monitor/server.jl
#        → 브라우저 http://127.0.0.1:8080/  (MeshCat live view remains on 8700)
# =============================================================================
using HTTP, Sockets, JSON3

const ROOT = @__DIR__                                   # tools/monitor
const REPO = abspath(joinpath(ROOT, "..", ".."))        # ConstructionBots.jl
const PORT = parse(Int, get(ENV, "MONITOR_PORT", "8080"))
const RUNNING = Set{String}()                           # 중복 스폰 방지

const ACTIVE_KEY = Ref{Union{Nothing,String}}(nothing)
const ACTIVE_RUN_ID = Ref{Union{Nothing,String}}(nothing)
const LAST_RUN = Ref{Any}((state="idle", key=nothing, error=nothing, log=nothing))
const COMMAND_DIR = joinpath(ROOT, "commands")
mkpath(COMMAND_DIR)

safe_base(s) = replace(splitext(basename(String(s)))[1], r"[^A-Za-z0-9]+" => "_")
command_path(key) = joinpath(COMMAND_DIR, "$(safe_base(key)).jsonl")
# render_demo.jl 의 layout_path 와 **같은 규칙**이어야 한다(둘이 어긋나면 평면도가 영영 안 뜬다).
layout_path(key) = joinpath(COMMAND_DIR, "$(safe_base(key)).layout.json")
# run_header.jl 의 run_info_path_of(cmdfile) 와 **같은 파일**을 가리켜야 한다(어긋나면 엔진은
# 사이드카를 쓰는데 서버는 다른 자리를 봐서 대시보드가 영영 기다린다). 이름을 일부러 다르게 둔다 —
# 둘 다 문자열을 받으므로 같은 이름이면 디스패치가 구분하지 못한다.
run_info_path(key) = joinpath(COMMAND_DIR, "$(safe_base(key)).run.json")
new_run_id() = string(time_ns())
# 구역이 사람이 정의하는 사건인 케이스. 이 셋은 조작자가 그리기 전에는 시뮬레이션을 시작하지 않는다.
has_zone(case) = occursin("zone", String(case))
available_models() = filter(f -> endswith(lowercase(f), ".mpd") || endswith(lowercase(f), ".ldr"),
                            readdir(joinpath(REPO, "LDraw_files")))
# 2026-08-13: `all` 을 넣는다. `run_demo.jl:99` 가 이미 `[:fault, :battery, :zone]` 로 지원하는데
# 이 집합에만 빠져 있어서, 대시보드가 그 케이스를 **재생은 하고 라이브 실행은 400** 으로 거절했다
# (30시드 스윕이 `all` 을 포함해 녹화를 남기면서 드러났다).
const VALID_CASES = Set(["none", "battery", "fault", "zone", "fault_battery", "fault_zone",
                         "battery_zone", "battery_mild", "all"])

# 정책 비교용 케이스: 같은 "애매한" 배터리 사건(SoC≈0.55)을 규칙 / DSPy 가 각각 결정한다.
# 케이스 이름 → run_demo.jl 에 넘길 (실제 OOD 케이스, 추가 환경변수).
# battery_mild = 애매한 구간(SoC≈0.55)의 배터리 사건. 정책은 케이스가 아니라 UI 의 정책 선택기에서
# 고르므로, 여기서는 "실행할 정책"만 정하고 세 정책의 결정은 어차피 모두 기록된다.
const CASE_PRESETS = Dict(
    "battery_mild" => ("battery", Dict("DEMO_BSOC" => "0.45",
                                       "DEMO_POLICY" => get(ENV, "DEMO_POLICY", "dspy"))),
)

cors() = ["Access-Control-Allow-Origin" => "*",
          "Access-Control-Allow-Headers" => "Content-Type",
          "Access-Control-Allow-Methods" => "GET,POST,OPTIONS"]

_ctype(p) = endswith(p, ".html") ? "text/html; charset=utf-8" :
            (endswith(p, ".jsonl") || endswith(p, ".json")) ? "application/json" :
            endswith(p, ".js") ? "text/javascript" :
            endswith(p, ".css") ? "text/css" : "application/octet-stream"

function serve_file(path)
    isfile(path) || return HTTP.Response(404, cors(), "not found: $(basename(path))")
    hdrs = [cors(); "Content-Type" => _ctype(path)]
    # 대시보드를 고쳐도 브라우저가 옛 파일을 쓰면 소용이 없다. html 은 항상 새로 받는다.
    endswith(path, ".html") && push!(hdrs, "Cache-Control" => "no-store")
    return HTTP.Response(200, hdrs, read(path))
end

"OOD 추첨 seed → 스트림/애니 파일 접미사. seed=1(기본)은 접미사 없음 = 기존 이름 그대로."
seed_suffix(seed::Int) = seed == 1 ? "" : "_s$(seed)"

"""
애니 파일을 이름으로 찾되, **앞에 접두사가 붙은 보관본까지** 찾는다(예: `2026-08-08_tractor__zone__router.html`).
녹화를 날짜별로 구분해 두면 정확한 이름 검사만으로는 화면에서 사라지기 때문. 여러 개면 가장 최근 것.

접두사 뒤에 `_` 를 요구하는 이유: 그냥 `endswith` 로 하면 `tractor__zone__router.html` 이
`tractor__fault_zone__router.html` 에도 걸려 **다른 케이스의 애니가 조용히 대신 뜬다**.
"""
function resolve_anim(name::AbstractString)
    dir = joinpath(ROOT, "anim")
    isdir(dir) || return name
    cands = filter(f -> f == name || endswith(f, "_" * name), readdir(dir))
    isempty(cands) && return name
    return argmax(f -> mtime(joinpath(dir, f)), cands)
end

function spawn_run(model, case; interactive::Bool=false, n::Int=0, seed::Int=1, wait_s::Float64=300.0)
    key = "$(model)__$(case)"
    key in RUNNING && return "already running"
    isempty(RUNNING) || return "busy — 다른 렌더 진행 중(동시 1개; MeshCat 포트 충돌 방지). 잠시 후 재시도."
    push!(RUNNING, key)
    ACTIVE_KEY[] = key
    run_id = new_run_id()
    ACTIVE_RUN_ID[] = run_id
    cmdfile = command_path(key)
    LAST_RUN[] = (state="starting", key=key, error=nothing, log=nothing)
    open(cmdfile, "w") do io end
    # 직전 세션의 평면도를 지운다. 안 지우면 대시보드가 **옛 배치 위에** 구역을 그리게 되는데,
    # 모델이나 로봇 수가 바뀌었으면 그건 이 런에 없는 자리다(그리고 화면상으로는 구분이 안 된다).
    try rm(layout_path(key); force=true) catch end
    # 직전 런의 사이드카도 지운다. 남겨 두면 대시보드가 옛 런의 토큰을 보고 옛 녹화를 새 런으로 오인한다.
    try rm(run_info_path(key); force=true) catch end
    @async begin
        try
            println("[server] spawn: model=$model case=$case")
            LAST_RUN[] = (state="running", key=key, error=nothing, log=nothing)
            # 프리셋 케이스면 실제 OOD 케이스로 풀고 추가 환경변수(정책·severity)를 얹는다.
            # 스트림 파일 이름은 프리셋 이름을 유지해야 대시보드가 두 정책을 따로 재생할 수 있다.
            base_case, extra = get(CASE_PRESETS, case, (case, Dict{String,String}()))
            # 표시 이름(=파일 이름)은 프리셋 이름을 유지해야 대시보드가 ⑦ 을 ① 과 따로 재생한다.
            # 예전에는 MONITOR_STREAM 으로 우회했는데 render_demo.jl 은 그 변수를 읽지 않아
            # (run_demo.jl 만 읽는다) ⑦ 녹화가 ① battery 파일을 덮어썼다. 이제 두 산출물(스트림·애니)
            # 이름을 한 손잡이(DEMO_CASE_TAG)로 함께 정한다.
            stream_override = Dict("DEMO_CASE_TAG" => case)
            cmd = addenv(`julia +lts --project=$REPO --startup-file=no $(joinpath(ROOT, "render_demo.jl"))`,
                "DEMO_MODEL" => model, "DEMO_OOD" => base_case,
                "DEMO_N" => string(n),                          # how many OOD events to inject (0 = case default)
                # OOD 추첨 seed. 로봇 OOD(fault/battery)의 발화 시점·종류가 이 값으로 정해진다.
                # 0 이면 옛 고정 슬롯 스케줄로 되돌아간다(재현용). zone 은 seed 와 무관하게 pre-sim 고정.
                "DEMO_SEED" => string(seed),
                "MONITOR_COMMAND_FILE" => cmdfile,
                "MONITOR_INTERACTIVE" => (interactive ? "1" : "0"),
                "MONITOR_RUN_ID" => run_id,
                # 라이브 zone 케이스(③⑤⑥)는 조작자가 평면도에 구역을 그릴 때까지 **시작하지 않는다**.
                # MONITOR_WAIT(마감 있는 대기)로는 시간이 지나면 zone 없이 출발해 버린다.
                "MONITOR_REQUIRE_ZONE" => (interactive && has_zone(case) ? "1" : "0"),
                # 첫 조작자 명령(zone)을 기다리는 시간[초]. 0 = 기다리지 않음 = zone 없이 시작.
                # zone 주입 여부는 결과를 크게 가르는 실험 조건이므로 호출자가 명시적으로 고른다.
                "MONITOR_WAIT" => string(wait_s),
                extra..., stream_override...)
            run(cmd)                                    # @async 안이라 다른 요청 처리를 막지 않음
            println("[server] done: model=$model case=$case")
            LAST_RUN[] = (state="complete", key=key, error=nothing, log=nothing)
        catch e
            # ProcessFailedException includes the complete child environment in
            # its rendered form. Never expose that through the dashboard API.
            public_error = e isa ProcessFailedException ?
                "simulation process exited unexpectedly" : string(typeof(e))
            LAST_RUN[] = (state="failed", key=key, error=public_error, log=nothing)
            println("[server] run failed ($model/$case): ", public_error)
        finally
            delete!(RUNNING, key)
            ACTIVE_KEY[] == key && (ACTIVE_KEY[] = nothing)
        end
    end
    # 성공 응답만 JSON 이다. "busy — …" / "already running" 은 평문으로 남겨야 한다 —
    # dashboard.html:1541 이 그 두 문자열을 정규식으로 판별한다.
    return JSON3.write((; status = "started", run_id = run_id))
end

function router(req)
    try
        req.method == "OPTIONS" && return HTTP.Response(204, cors())
        path = HTTP.URI(req.target).path

        if req.method == "POST" && path == "/run"
            b = JSON3.read(String(req.body))
            model = String(get(b, :model, "tractor.mpd"))
            case  = String(get(b, :case, "fault"))
            interactive = Bool(get(b, :interactive, false))
            n = try clamp(Int(get(b, :n, 0)), 0, 20) catch; 0 end   # OOD event count (0 = case default; capped at 20)
            seed = try clamp(Int(get(b, :seed, 1)), 0, 9999) catch; 1 end  # OOD draw seed (0 = legacy fixed slots)
            # wait: 대화형 런이 첫 zone 명령을 기다릴 초. 0 = 기다리지 않고 zone 없이 시작.
            wait_s = try clamp(Float64(get(b, :wait, 300.0)), 0.0, 3600.0) catch; 300.0 end
            model in available_models() || return HTTP.Response(400, cors(), "unknown model")
            case in VALID_CASES || return HTTP.Response(400, cors(), "unknown OOD case")
            return HTTP.Response(200, cors(),
                                 spawn_run(model, case; interactive=interactive, n=n, seed=seed, wait_s=wait_s))
        end
        if req.method == "POST" && path == "/inject/zone"
            key = ACTIVE_KEY[]
            key === nothing && return HTTP.Response(409, cors(), "no active simulation; start a run first")
            # 평면도가 나오기 전에 도착한 주입은 조작자가 고른 것일 수 없다(평면도는 env 빌드 뒤에 나온다).
            # 2026-08-12 실측: 런 시작 14ms 뒤에 도착한 구역이 존 케이스를 사람이 정의하지 않은 런으로
            # 만들었다. 출처는 규명하지 못했으므로 조건을 막는다.
            isfile(layout_path(key)) || return HTTP.Response(409, cors(),
                "floor plan not published yet — draw the zone after it appears")
            b = JSON3.read(String(req.body))
            x = Float64(b[:x]); y = Float64(b[:y]); r = Float64(b[:r])
            all(isfinite, (x, y, r)) || return HTTP.Response(400, cors(), "x, y and r must be finite")
            (0.05 <= r <= 100.0) || return HTTP.Response(400, cors(), "r must be between 0.05 and 100")
            msg = (; id = string(time_ns()), type = "forbid_zone", x, y, r,
                    requested_at = time(), session = key)
            open(command_path(key), "a") do io
                println(io, JSON3.write(msg)); flush(io)
            end
            return HTTP.Response(202, [cors(); "Content-Type" => "application/json"], JSON3.write(msg))
        end
        # 활성 세션의 **sim 전 평면도**. 아직 안 쓰였으면 204 — 대시보드는 그동안 "환경 빌드 중"을 보여준다.
        # (env 빌드에 수 분이 걸리므로 이 사이가 짧지 않다.)
        if req.method == "GET" && path == "/layout"
            key = ACTIVE_KEY[]
            key === nothing && return HTTP.Response(409, cors(), "no active simulation; start a run first")
            p = layout_path(key)
            isfile(p) || return HTTP.Response(204, cors())
            return HTTP.Response(200, [cors(); "Content-Type" => "application/json"], read(p))
        end
        # 활성 런의 사이드카. 대시보드는 이 토큰이 자기 것과 같을 때만 스트림을 화면에 올린다.
        # 아직 스트림이 열리지 않았으면 204 — 존 런에서는 조작자가 구역을 확정할 때까지 그렇다.
        if req.method == "GET" && path == "/runinfo"
            key = ACTIVE_KEY[]
            key === nothing && return HTTP.Response(409, cors(), "no active simulation; start a run first")
            p = run_info_path(key)
            isfile(p) || return HTTP.Response(204, cors())
            return HTTP.Response(200, [cors(); "Content-Type" => "application/json"], read(p))
        end
        # 구역 정의를 그만둔다. 게이트가 마감 없이 기다리므로 취소 경로가 없으면 프로세스가 영영 남는다.
        if req.method == "POST" && path == "/abort"
            key = ACTIVE_KEY[]
            key === nothing && return HTTP.Response(409, cors(), "no active simulation")
            open(command_path(key), "a") do io
                println(io, JSON3.write((; id = string(time_ns()), type = "abort", session = key))); flush(io)
            end
            return HTTP.Response(202, cors(), "abort requested")
        end
        if req.method == "GET" && path == "/status"
            return HTTP.Response(200, [cors(); "Content-Type" => "application/json"],
                JSON3.write((active = ACTIVE_KEY[], run_id = ACTIVE_RUN_ID[],
                             running = collect(RUNNING), last = LAST_RUN[])))
        end
        if req.method == "GET" && path == "/live/ready"
            ready = false
            sock = nothing
            try
                sock = connect(ip"127.0.0.1", 8700)
                ready = true
            catch
            finally
                sock === nothing || close(sock)
            end
            return HTTP.Response(200, [cors(); "Content-Type" => "application/json"],
                JSON3.write((ready=ready, active=ACTIVE_KEY[])))
        end
        if req.method == "GET" && path == "/models"
            files = available_models()
            return HTTP.Response(200, [cors(); "Content-Type" => "application/json"], JSON3.write(files))
        end
        if req.method == "POST" && path == "/artifact"
            b = JSON3.read(String(req.body))
            model = String(get(b, :model, "tractor.mpd")); case = String(get(b, :case, "none"))
            n = try clamp(Int(get(b, :n, 0)), 0, 20) catch; 0 end   # OOD count → _nN suffix on stream/anim
            seed = try clamp(Int(get(b, :seed, 1)), 0, 9999) catch; 1 end
            nsuf = (n > 0 ? "_n$(n)" : "") * seed_suffix(seed)
            base = safe_base(model)
            # 실행정책 녹화(케이스 × 정책)는 이름에 __<policy> 가 붙는다. 예전에는 대시보드가 그 이름을
            # 직접 만들어 썼는데, 그러면 신선도 검사(아래)와 접두사 해석을 못 받는다 → 여기서 함께 푼다.
            policy = String(get(b, :policy, ""))
            psuf = isempty(policy) ? "" : "__$(policy)"
            stream = "streams/$(base)__$(case)$(psuf)$(nsuf).jsonl"
            anim = "anim/" * resolve_anim("$(base)__$(case)$(psuf)$(nsuf).html")
            # 2026-08-04: 존재검사만으로는 **옛 애니가 새 런을 가장한다**. 라이브 인터랙티브 런은
            # 애니 산출물을 만들지 않고(save_animation=!INTERACTIVE) 라이브 MeshCat 을 직접 몰기
            # 때문에, 같은 이름의 낡은 anim/*.html 이 남아 있으면 대시보드가 그걸 Factory View 에
            # 끼워 넣는다. 실측: 07-29 완주 애니(34.7초에 완성)가 08-04 미완주 런 화면에 떠서
            # 데이터 패널(7/8, 95.8초)과 정면으로 모순됐다. → **스트림보다 오래된 애니는 없는 것으로 취급**.
            streamp, animp = joinpath(ROOT, stream), joinpath(ROOT, anim)
            has_anim = isfile(animp)
            fresh = has_anim && (!isfile(streamp) || mtime(animp) >= mtime(streamp))
            return HTTP.Response(200, [cors(); "Content-Type" => "application/json"],
                JSON3.write((stream=stream, stream_exists=isfile(streamp),
                             anim=anim, anim_exists=fresh,
                             # 낡아서 숨긴 것인지(=이번 런이 애니를 안 만든 것) UI 가 구분할 수 있게.
                             anim_stale=(has_anim && !fresh))))
        end

        # ---- /objective : 목적함수 J 의 **단일 진실원**을 화면에 그대로 노출한다 -------------
        # 왜 라우트로 뺐는가: 대시보드가 상수(κ·E_ref·M_ref·C_fail·C_unclosed)를 자기 안에
        # 복붙하면 objective.json 이 바뀌는 순간 화면만 옛 값을 주장한다. audit_objective.py
        # 항목 1 이 잡는 바로 그 결함이다. 파일을 그대로 서빙해 화면이 **읽기만** 하게 한다.
        if req.method == "GET" && path == "/objective"
            local op = joinpath(ROOT, "..", "..", "wm4spacecraft_manufacturing", "core", "objective.json")
            isfile(op) || return HTTP.Response(404, cors(), "objective.json not found")
            return HTTP.Response(200, [cors(); "Content-Type" => "application/json"], read(op))
        end

        rel = path == "/" ? "dashboard.html" : lstrip(path, '/')
        occursin("..", rel) && return HTTP.Response(403, cors(), "forbidden")
        return serve_file(joinpath(ROOT, rel))
    catch e
        return HTTP.Response(500, cors(), string(e))
    end
end

# 스크립트로 실행할 때만 포트를 연다. 검사에서 include 할 수 있어야 하기 때문
# (include 하면 라우터 함수만 쓰고 서버는 안 띄운다).
if abspath(PROGRAM_FILE) == @__FILE__
    println("[server] http://127.0.0.1:$PORT   (dashboard + streams + POST /run)")
    println("[server] root=$ROOT")
    HTTP.serve(router, "127.0.0.1", PORT)
end
