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
const LAST_RUN = Ref{Any}((state="idle", key=nothing, error=nothing, log=nothing))
const COMMAND_DIR = joinpath(ROOT, "commands")
mkpath(COMMAND_DIR)

safe_base(s) = replace(splitext(basename(String(s)))[1], r"[^A-Za-z0-9]+" => "_")
command_path(key) = joinpath(COMMAND_DIR, "$(safe_base(key)).jsonl")
available_models() = filter(f -> endswith(lowercase(f), ".mpd") || endswith(lowercase(f), ".ldr"),
                            readdir(joinpath(REPO, "LDraw_files")))
const VALID_CASES = Set(["none", "battery", "fault", "zone", "fault_battery", "fault_zone",
                         "battery_zone", "battery_mild"])

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
    return HTTP.Response(200, [cors(); "Content-Type" => _ctype(path)], read(path))
end

"OOD 추첨 seed → 스트림/애니 파일 접미사. seed=1(기본)은 접미사 없음 = 기존 이름 그대로."
seed_suffix(seed::Int) = seed == 1 ? "" : "_s$(seed)"

function spawn_run(model, case; interactive::Bool=false, n::Int=0, seed::Int=1)
    key = "$(model)__$(case)"
    key in RUNNING && return "already running"
    isempty(RUNNING) || return "busy — 다른 렌더 진행 중(동시 1개; MeshCat 포트 충돌 방지). 잠시 후 재시도."
    push!(RUNNING, key)
    ACTIVE_KEY[] = key
    cmdfile = command_path(key)
    LAST_RUN[] = (state="starting", key=key, error=nothing, log=nothing)
    open(cmdfile, "w") do io end
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
    return "started"
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
            model in available_models() || return HTTP.Response(400, cors(), "unknown model")
            case in VALID_CASES || return HTTP.Response(400, cors(), "unknown OOD case")
            return HTTP.Response(200, cors(), spawn_run(model, case; interactive=interactive, n=n, seed=seed))
        end
        if req.method == "POST" && path == "/inject/zone"
            key = ACTIVE_KEY[]
            key === nothing && return HTTP.Response(409, cors(), "no active simulation; start a run first")
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
        if req.method == "GET" && path == "/status"
            return HTTP.Response(200, [cors(); "Content-Type" => "application/json"],
                JSON3.write((active = ACTIVE_KEY[], running = collect(RUNNING), last = LAST_RUN[])))
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
            stream = "streams/$(base)__$(case)$(nsuf).jsonl"
            anim = "anim/$(base)__$(case)$(nsuf).html"
            return HTTP.Response(200, [cors(); "Content-Type" => "application/json"],
                JSON3.write((stream=stream, stream_exists=isfile(joinpath(ROOT, stream)),
                             anim=anim, anim_exists=isfile(joinpath(ROOT, anim)))))
        end

        rel = path == "/" ? "dashboard.html" : lstrip(path, '/')
        occursin("..", rel) && return HTTP.Response(403, cors(), "forbidden")
        return serve_file(joinpath(ROOT, rel))
    catch e
        return HTTP.Response(500, cors(), string(e))
    end
end

println("[server] http://127.0.0.1:$PORT   (dashboard + streams + POST /run)")
println("[server] root=$ROOT")
HTTP.serve(router, "127.0.0.1", PORT)
