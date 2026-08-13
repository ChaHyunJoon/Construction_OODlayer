# 라이브 세션 런 토큰 + 구역 확정 전 무기록 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 대시보드가 "지금 화면의 프레임이 내가 시작한 런의 것인지"를 판별할 수 있게 하고, 존 케이스는 조작자가 구역을 확정하기 전에는 스트림 파일을 아예 열지 않게 한다.

**Architecture:** 서버가 런마다 `run_id` 를 발급해 자식에게 넘긴다. 엔진은 스트림을 여는 바로 그 순간 사이드카 `commands/<key>.run.json` 에 그 `run_id` 를 남기고, 존 런에서는 스트림 열기 자체를 조작자 게이트 뒤로 미룬다. 대시보드는 사이드카의 `run_id` 가 자기 것과 같을 때만 스트림을 로드한다. 스트림 파일 형식은 **바꾸지 않는다**(소비자 4곳 보호).

**Tech Stack:** Julia 1.10 (`julia +lts --project=.`), HTTP.jl + JSON3, 순수 JS 대시보드(빌드 도구 없음).

**선행 문서:** `docs/superpowers/specs/2026-08-12-live-zone-run-token-design.md` (커밋 `0d0f4ff`). 증상·근본원인·설계 근거는 그 문서에 있다.

## Global Constraints

- Julia 는 반드시 **`julia +lts`** (1.10) + `--project=.`. `Pkg.add` 금지(Manifest 가 1.10.11 에 고정).
- **자동 주입기 `inject_blocking_zone!` / `inject_staging_zone!` 은 한 글자도 고치지 않는다.** 비대화형 녹화와 오라클 격자가 그 함수들의 세계이고, 2026-08-12 D=20 산출물의 재현성이 거기 걸려 있다.
- **스트림 jsonl 의 줄 형식을 바꾸지 않는다.** 헤더는 사이드카 파일로 간다. 스트림을 읽는 도구가 최소 네 곳이며 전부 "모든 줄 = 프레임"으로 읽는다: `tools/monitor/verify_depot_station.py`, `tools/monitor/artifacts_to_html.py`, `wm4spacecraft_manufacturing/diag_stall.py`, `wm4spacecraft_manufacturing/verify_night.py`.
- 행동 어휘(`wm4spacecraft_manufacturing/action_registry.json`)·정책·`reference_policy.py` 를 건드리지 않는다.
- `spawn_run` 의 **동시 실행 거절 응답은 평문**이어야 한다(`"busy — …"`, `"already running"`). 대시보드가 `dashboard.html:1541` 에서 정규식 `/^(busy|already running)/i` 로 판별한다. 성공 응답만 JSON 으로 바꾼다.
- 런은 동시에 하나만 돈다(MeshCat 포트 충돌 + HiGHS 스케줄 비교 무효화). 검증 중에도 두 개를 겹쳐 돌리지 않는다.
- 긴 런의 로그를 `| head` / `| grep -m` 으로 파이프하지 않는다(SIGPIPE 로 Julia 사망). `> file 2>&1` 로 받는다.
- 모든 검증 단계는 **실행한 명령과 그 결과를 그대로 보고**한다("passed" / "failed with X" / "not run because Y").

## 파일 구조

| 파일 | 역할 | 변경 |
|---|---|---|
| `tools/monitor/run_header.jl` | **신규.** 사이드카 레코드 생성/기록 (순수 함수 하나 + 쓰기 함수 하나). 별도 파일인 이유는 `render_demo.jl` 이 include 하면 전체 데모가 돌아버려 단위검사가 불가능하기 때문 | 생성 |
| `tools/monitor/server.jl` | `run_id` 발급·전달·노출, `/runinfo`, 이른 zone 거절, html no-store, serve 가드 | 수정 |
| `tools/monitor/render_demo.jl` | 스트림 열기를 게이트 뒤로 + 사이드카 기록 | 수정 |
| `tools/monitor/dashboard.html` | `run_id` 일치 시에만 스트림 로드 | 수정 |
| `tools/monitor/test_live_gate.jl` | **신규.** 단위·라우터 검사 (repo 의 `checks.jl` PASS/FAIL 스타일) | 생성 |
| `tools/monitor/README.md` | 흐름도에 사이드카·거절 규칙 반영 | 수정 |

---

### Task 1: 사이드카 레코드 모듈 + 서버가 run_id 를 발급한다

**Files:**
- Create: `tools/monitor/run_header.jl`
- Create: `tools/monitor/test_live_gate.jl`
- Modify: `tools/monitor/server.jl` (`spawn_run`, `/run` 라우트, `/status`, `serve_file`, 파일 끝 serve 가드)

**Interfaces:**
- Produces: `run_info(; run_id, case, requires_zone, started_at, stream, zone=nothing) -> NamedTuple` · `write_run_info(path, info) -> String` (쓴 경로를 돌려준다) · `run_info_path_of(cmdfile) -> String` (엔진용) · `run_info_path(key) -> String` (서버용, `server.jl` 에 정의). **두 이름은 달라야 한다** — 둘 다 문자열을 받으므로 같은 이름이면 디스패치가 구분하지 못한다.
- Produces: `POST /run` 성공 응답이 JSON `{"status":"started","run_id":"<digits>"}` · 자식 환경변수 `MONITOR_RUN_ID` · `GET /status` 에 `run_id` 필드
- Consumes: 없음

- [ ] **Step 1: 사이드카 모듈을 만든다**

Create `tools/monitor/run_header.jl`:

```julia
# tools/monitor/run_header.jl
# =============================================================================================
#  라이브 런 사이드카 — "이 스트림은 어느 런의 것인가"를 파일 하나로 못박는다.
# ---------------------------------------------------------------------------------------------
#  왜 스트림 안이 아니라 옆 파일인가: 이 저장소에서 스트림 jsonl 을 읽는 도구가 최소 네 곳이고
#  (verify_depot_station.py / artifacts_to_html.py / diag_stall.py / verify_night.py) 전부 **모든 줄을
#  프레임으로** 읽는다. 첫 줄에 헤더를 끼우면 그 넷이 조용히 깨진다. 사이드카는 아무도 안 건드린다.
#
#  왜 별도 파일인가: render_demo.jl 은 include 하면 데모 전체가 돌아버려 단위검사를 못 붙인다.
# =============================================================================================
using JSON3

# 이름이 server.jl 의 run_info_path(key) 와 **달라야 한다.** 둘 다 문자열을 받으므로 같은 이름으로
# 두면 다중 디스패치가 구분하지 못하고, 더 구체적인 쪽(AbstractString)이 서버 정의를 가려
# 엉뚱한 경로가 나온다(엔진과 서버가 서로 다른 파일을 보게 된다).
"명령 파일 경로 → 사이드카 경로. server.jl 의 run_info_path(key) 와 **같은 파일**을 가리켜야 한다."
run_info_path_of(cmdfile::AbstractString) =
    isempty(cmdfile) ? "" :
    joinpath(dirname(cmdfile), splitext(basename(cmdfile))[1] * ".run.json")

"""
    run_info(; run_id, case, requires_zone, started_at, stream, zone=nothing)

사이드카 레코드. `zone` 은 조작자가 확정한 구역이며 게이트가 있는 런에서만 채워진다
(게이트가 없는 런은 `nothing` = JSON 의 null).
"""
function run_info(; run_id::AbstractString, case::AbstractString, requires_zone::Bool,
                  started_at::Real, stream::AbstractString, zone = nothing)
    return (; run_id = String(run_id), case = String(case), requires_zone = requires_zone,
            started_at = Float64(started_at), stream = String(stream), zone = zone)
end

"사이드카를 원자적으로 쓴다. 대시보드가 반쯤 쓰인 파일을 읽고 JSON 파싱에 실패하면 안 된다."
function write_run_info(path::AbstractString, info)
    isempty(path) && return ""
    mkpath(dirname(path))
    tmp = path * ".tmp"
    open(tmp, "w") do io
        println(io, JSON3.write(info))
    end
    mv(tmp, path; force = true)
    return path
end
```

- [ ] **Step 2: 실패하는 검사를 먼저 쓴다**

Create `tools/monitor/test_live_gate.jl`:

```julia
# tools/monitor/test_live_gate.jl
# 라이브 게이트 단위·라우터 검사. 시뮬레이션을 돌리지 않는다(초 단위로 끝나야 한다).
#   julia +lts --project=. tools/monitor/test_live_gate.jl
using JSON3
include(joinpath(@__DIR__, "run_header.jl"))

const PASS = Ref(0); const FAIL = Ref(0)
function ok(cond, label)
    cond ? (PASS[] += 1; println("  PASS  $label")) : (FAIL[] += 1; println("  FAIL  $label"))
end

println("== run_header ==")
info = run_info(; run_id = "123", case = "zone", requires_zone = true,
                started_at = 1.0, stream = "tractor__zone.jsonl",
                zone = (; x = 0.5, y = 0.4, r = 0.3, id = "cmd1"))
ok(info.run_id == "123", "run_id 보존")
ok(info.zone.r == 0.3, "zone 보존")

rt = JSON3.read(JSON3.write(info))
ok(String(rt[:run_id]) == "123", "JSON 왕복 후 run_id")
ok(Bool(rt[:requires_zone]), "JSON 왕복 후 requires_zone")

tmpdir = mktempdir()
cmdfile = joinpath(tmpdir, "tractor.jsonl")
p = run_info_path_of(cmdfile)
ok(basename(p) == "tractor.run.json", "사이드카 경로 규칙")
write_run_info(p, info)
ok(isfile(p), "사이드카 기록")
ok(String(JSON3.read(read(p, String))[:run_id]) == "123", "사이드카 재파싱")
ok(!isfile(p * ".tmp"), "임시 파일이 남지 않는다")

println()
println("live-gate check: $(PASS[]) PASS / $(FAIL[]) FAIL")
exit(FAIL[] == 0 ? 0 : 1)
```

- [ ] **Step 3: 검사를 돌려 실패를 확인한다**

Run: `julia +lts --project=. tools/monitor/test_live_gate.jl`
Expected: `run_header.jl` 이 아직 없으면 include 에서 `SystemError`. Step 1 을 먼저 했다면 이 단계는 **8 PASS / 0 FAIL** 로 통과한다 — 그 경우 "이미 통과함"이라고 그대로 보고하고 다음으로 간다.

- [ ] **Step 4: 서버에 run_id 를 배선한다**

`tools/monitor/server.jl` 의 `const ACTIVE_KEY` 줄 **아래**에 추가한다:

```julia
const ACTIVE_RUN_ID = Ref{Union{Nothing,String}}(nothing)
```

`layout_path(key)` 정의 **아래**에 추가한다:

```julia
# run_header.jl 의 run_info_path_of(cmdfile) 와 **같은 파일**을 가리켜야 한다(어긋나면 엔진은
# 사이드카를 쓰는데 서버는 다른 자리를 봐서 대시보드가 영영 기다린다). 이름을 일부러 다르게 둔다 —
# 둘 다 문자열을 받으므로 같은 이름이면 디스패치가 구분하지 못한다.
run_info_path(key) = joinpath(COMMAND_DIR, "$(safe_base(key)).run.json")
new_run_id() = string(time_ns())
```

`spawn_run` 안에서, `ACTIVE_KEY[] = key` 줄 **아래**에 추가한다:

```julia
    run_id = new_run_id()
    ACTIVE_RUN_ID[] = run_id
```

`try rm(layout_path(key); force=true) catch end` 줄 **아래**에 추가한다:

```julia
    # 직전 런의 사이드카도 지운다. 남겨 두면 대시보드가 옛 런의 토큰을 보고 옛 녹화를 새 런으로 오인한다.
    try rm(run_info_path(key); force=true) catch end
```

`addenv(...)` 의 `"MONITOR_INTERACTIVE" => (interactive ? "1" : "0"),` 줄 **아래**에 추가한다:

```julia
                "MONITOR_RUN_ID" => run_id,
```

`spawn_run` 의 마지막 `return "started"` 를 교체한다:

```julia
    # 성공 응답만 JSON 이다. "busy — …" / "already running" 은 평문으로 남겨야 한다 —
    # dashboard.html:1541 이 그 두 문자열을 정규식으로 판별한다.
    return JSON3.write((; status = "started", run_id = run_id))
```

- [ ] **Step 5: `/status` 에 run_id 를 싣고, html 캐시를 끄고, serve 가드를 단다**

`/status` 라우트의 응답을 교체한다:

```julia
            return HTTP.Response(200, [cors(); "Content-Type" => "application/json"],
                JSON3.write((active = ACTIVE_KEY[], run_id = ACTIVE_RUN_ID[],
                             running = collect(RUNNING), last = LAST_RUN[])))
```

`serve_file` 를 교체한다:

```julia
function serve_file(path)
    isfile(path) || return HTTP.Response(404, cors(), "not found: $(basename(path))")
    hdrs = [cors(); "Content-Type" => _ctype(path)]
    # 대시보드를 고쳐도 브라우저가 옛 파일을 쓰면 소용이 없다. html 은 항상 새로 받는다.
    endswith(path, ".html") && push!(hdrs, "Cache-Control" => "no-store")
    return HTTP.Response(200, hdrs, read(path))
end
```

파일 맨 끝 두 줄(`println("[server] http://…")` 부터 `HTTP.serve(...)` 까지)을 교체한다:

```julia
# 스크립트로 실행할 때만 포트를 연다. 검사에서 include 할 수 있어야 하기 때문
# (include 하면 라우터 함수만 쓰고 서버는 안 띄운다).
if abspath(PROGRAM_FILE) == @__FILE__
    println("[server] http://127.0.0.1:$PORT   (dashboard + streams + POST /run)")
    println("[server] root=$ROOT")
    HTTP.serve(router, "127.0.0.1", PORT)
end
```

- [ ] **Step 6: 서버 쪽 검사를 추가한다**

`tools/monitor/test_live_gate.jl` 의 `println("live-gate check: …")` **앞**에 추가한다:

```julia
println()
println("== server ==")
include(joinpath(@__DIR__, "server.jl"))     # serve 가드 덕분에 포트를 열지 않는다

ok(new_run_id() != new_run_id(), "run_id 가 매번 다르다")
ok(basename(run_info_path("tractor.mpd__zone")) == "tractor_mpd__zone.run.json",
   "서버의 사이드카 경로 규칙")

ACTIVE_KEY[] = "tractor.mpd__zone"; ACTIVE_RUN_ID[] = "abc123"
st = JSON3.read(String(router(HTTP.Request("GET", "/status")).body))
ok(String(st[:run_id]) == "abc123", "/status 가 run_id 를 싣는다")
```

- [ ] **Step 7: 검사를 돌린다**

Run: `julia +lts --project=. tools/monitor/test_live_gate.jl`
Expected: `live-gate check: 11 PASS / 0 FAIL`, 종료 코드 0. 서버가 **뜨지 않아야** 한다(명령이 즉시 끝난다).

- [ ] **Step 8: 커밋**

```bash
git add tools/monitor/run_header.jl tools/monitor/test_live_gate.jl tools/monitor/server.jl
git commit -m "feat(monitor): 런마다 run_id 를 발급하고 사이드카 레코드 모듈을 만든다"
```

---

### Task 2: 엔진이 게이트 뒤에 스트림을 열고 사이드카를 쓴다

**Files:**
- Modify: `tools/monitor/render_demo.jl` (상단 상수, `pre` 훅의 `monitor_enable!` 위치, 게이트 블록)
- Test: `tools/monitor/test_live_gate.jl` (확정 구역 파서 검사 추가)

**Interfaces:**
- Consumes: Task 1 의 `run_header.jl`(`run_info`, `write_run_info`, `run_info_path_of`), 환경변수 `MONITOR_RUN_ID`
- Produces: 존 런에서 조작자 확정 **전에는** `stream_path` 파일이 생성·수정되지 않는다 · 스트림을 여는 순간 `commands/<key>.run.json` 이 생긴다 · `last_zone_command(path) -> Union{Nothing,NamedTuple}`

**핵심 주의:** `CB.monitor_enable!` 은 파일을 `"w"` 로 열어 **즉시 0바이트로 자른다**(`src/monitor/monitor.jl:31`). 그래서 "게이트 뒤로 옮긴다"가 곧 "확정 전에는 옛 녹화를 파괴하지 않는다"가 된다.

- [ ] **Step 1: 확정 구역 파서 검사를 먼저 쓴다**

`tools/monitor/test_live_gate.jl` 의 `println("== server ==")` **앞**에 추가한다:

```julia
println()
println("== last_zone_command ==")
include(joinpath(@__DIR__, "zone_command.jl"))

cf = joinpath(tmpdir, "cmds.jsonl")
open(cf, "w") do io
    println(io, """{"id":"a","type":"forbid_zone","x":0.1,"y":0.2,"r":0.3}""")
    println(io, """{"id":"b","type":"forbid_zone","x":0.5,"y":0.4,"r":0.25}""")
end
z = last_zone_command(cf)
ok(z !== nothing && z.id == "b", "마지막 구역 명령을 고른다")
ok(z !== nothing && z.r == 0.25, "반지름 보존")

open(cf, "w") do io; println(io, """{"id":"c","type":"abort"}"""); end
ok(last_zone_command(cf) === nothing, "abort 만 있으면 구역 없음")
ok(last_zone_command(joinpath(tmpdir, "nope.jsonl")) === nothing, "파일이 없으면 구역 없음")
```

- [ ] **Step 2: 검사를 돌려 실패를 확인한다**

Run: `julia +lts --project=. tools/monitor/test_live_gate.jl`
Expected: FAIL — `zone_command.jl` 이 없어 `SystemError: opening file … zone_command.jl`.

- [ ] **Step 3: 파서를 만든다**

Create `tools/monitor/zone_command.jl`:

```julia
# tools/monitor/zone_command.jl
# 명령 파일에서 **조작자가 확정한 마지막 구역**을 읽는다. 사이드카에 그대로 실어
# "이 런은 사람이 정의한 이 구역으로 출발했다"를 파일 하나로 증명하기 위한 것.
using JSON3

"마지막 forbid_zone 명령. 없으면 nothing. 깨진 줄은 건너뛴다(부분 기록 중일 수 있다)."
function last_zone_command(path::AbstractString)
    (isfile(path) && filesize(path) > 0) || return nothing
    found = nothing
    for line in eachline(path)
        isempty(strip(line)) && continue
        cmd = try JSON3.read(line) catch; continue end
        (try String(cmd[:type]) catch; "" end) == "forbid_zone" || continue
        found = try
            (; id = String(cmd[:id]), x = Float64(cmd[:x]), y = Float64(cmd[:y]), r = Float64(cmd[:r]))
        catch; found end
    end
    return found
end
```

- [ ] **Step 4: 검사를 돌려 통과를 확인한다**

Run: `julia +lts --project=. tools/monitor/test_live_gate.jl`
Expected: `live-gate check: 15 PASS / 0 FAIL`

- [ ] **Step 5: 엔진에 배선한다**

`tools/monitor/render_demo.jl` 의 `const INTERACTIVE = …`(60행 부근) **아래**에 추가한다:

```julia
const RUN_ID = get(ENV, "MONITOR_RUN_ID", "")
```

같은 파일에서 `pending_command_kind` 정의 **앞**(다른 include 들과 같은 자리, 모듈 최상위)에 추가한다:

```julia
include(joinpath(@__DIR__, "run_header.jl"))
include(joinpath(@__DIR__, "zone_command.jl"))
```

`pre` 훅 안의 `CB.monitor_enable!(stream_path)` 한 줄(755행)을 교체한다:

```julia
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
```

같은 훅의 게이트 `while true … end` 루프 **바로 뒤**(`elseif MONITOR_WAIT > 0` 분기의 `while` 이 아니라 `if REQUIRE_ZONE` 쪽 루프 뒤)에 추가한다:

```julia
                # 조작자가 확정한 구역을 사이드카에 실어 남기고, 그때 비로소 스트림을 연다.
                enable_stream!(last_zone_command(COMMAND_FILE))
```

`MONITOR_WAIT` 분기와 `else` 분기 뒤, 즉 `control(env, nothing, nothing, 0)` 호출 **바로 앞**에 추가한다:

```julia
            # 게이트가 없는 대화형 런(MONITOR_WAIT 경로)도 첫 명령 적용 전에는 스트림이 열려 있어야
            # 한다 — control 이 inject_live_zone! 을 부르고 그것이 OOD 를 기록하기 때문.
            enable_stream!()
```

- [ ] **Step 6: 게이트 앞에서 스트림에 쓰는 코드가 없는지 확인한다**

`monitor_enable!` 이 늦어지면 그 사이에 기록되는 이벤트가 유실된다. 게이트 앞 구간(`pre` 훅 시작 ~ 게이트)에서 모니터에 쓰는 호출이 없는지 본다.

Run:
```bash
sed -n '/^    CB.set_respec_producer/,/^            if REQUIRE_ZONE/p' tools/monitor/render_demo.jl | grep -nE "monitor_|record_ood_truth!|push_ood!"
```
Expected: `push_ood!` 은 **자동 주입기 분기 안에만** 나타나야 한다(그 분기는 `INTERACTIVE` 일 때 실행되지 않는다 — 776행 `if has_zone && INTERACTIVE` 가 건너뛴다). 그 밖에 `monitor_*` 호출이 나오면 **멈추고 보고한다**(그 이벤트가 유실된다는 뜻).

- [ ] **Step 7: 검사를 돌린다**

Run: `julia +lts --project=. tools/monitor/test_live_gate.jl`
Expected: `live-gate check: 15 PASS / 0 FAIL` (엔진 변경은 이 검사가 직접 안 건드리지만, include 하는 두 모듈이 여전히 로드되는지 확인한다).

- [ ] **Step 8: 커밋**

```bash
git add tools/monitor/zone_command.jl tools/monitor/render_demo.jl tools/monitor/test_live_gate.jl
git commit -m "feat(monitor): 구역 확정 전에는 스트림을 열지 않고, 열 때 런 사이드카를 남긴다"
```

---

### Task 3: 평면도 이전의 zone 주입을 거절하고 사이드카를 노출한다

**Files:**
- Modify: `tools/monitor/server.jl` (`/inject/zone` 라우트, 새 `/runinfo` 라우트)
- Test: `tools/monitor/test_live_gate.jl`

**Interfaces:**
- Consumes: Task 1 의 `run_info_path(key)`, `ACTIVE_KEY`
- Produces: `POST /inject/zone` 이 평면도 부재 시 **409** · `GET /runinfo` 가 사이드카 JSON 또는 **204**

**왜 이 규칙인가:** 문제의 zone 명령은 런 시작 **14 ms 뒤**에 도착했다. 평면도는 env 빌드(수 분) 뒤에야 나오므로 조작자가 그것을 보고 고른 좌표일 수 없다. 출처를 특정하지 못했으므로(스펙 §2-C) **조건**을 막는다.

- [ ] **Step 1: 실패하는 검사를 먼저 쓴다**

`tools/monitor/test_live_gate.jl` 의 `/status` 검사 **아래**에 추가한다:

```julia
# 평면도가 없으면 구역 주입을 거절한다 — 조작자가 볼 수 없는 상태에서 온 주입은 사람이 고른 것이 아니다.
ACTIVE_KEY[] = "tractor.mpd__zone"
try rm(layout_path(ACTIVE_KEY[]); force=true) catch end
try rm(command_path(ACTIVE_KEY[]); force=true) catch end
body = JSON3.write((; x = 0.5, y = 0.4, r = 0.3))
res = router(HTTP.Request("POST", "/inject/zone", ["Content-Type" => "application/json"], body))
ok(res.status == 409, "평면도 이전 주입은 409 (받은 값: $(res.status))")
ok(!isfile(command_path(ACTIVE_KEY[])) || filesize(command_path(ACTIVE_KEY[])) == 0,
   "거절된 주입은 명령 파일에 기록되지 않는다")

# 평면도가 생기면 통과한다.
write(layout_path(ACTIVE_KEY[]), "{}")
res2 = router(HTTP.Request("POST", "/inject/zone", ["Content-Type" => "application/json"], body))
ok(res2.status == 202, "평면도 이후 주입은 202 (받은 값: $(res2.status))")
ok(last_zone_command(command_path(ACTIVE_KEY[])) !== nothing, "명령 파일에 구역이 기록된다")

# /runinfo: 없으면 204, 있으면 그대로.
try rm(run_info_path(ACTIVE_KEY[]); force=true) catch end
ok(router(HTTP.Request("GET", "/runinfo")).status == 204, "사이드카 부재 시 204")
write_run_info(run_info_path(ACTIVE_KEY[]),
               run_info(; run_id = "abc123", case = "zone", requires_zone = true,
                        started_at = 1.0, stream = "s.jsonl"))
r3 = router(HTTP.Request("GET", "/runinfo"))
ok(r3.status == 200 && String(JSON3.read(String(r3.body))[:run_id]) == "abc123", "/runinfo 가 토큰을 준다")

# 뒷정리 — 검사가 실제 commands/ 를 더럽히지 않아야 한다.
for f in (layout_path(ACTIVE_KEY[]), command_path(ACTIVE_KEY[]), run_info_path(ACTIVE_KEY[]))
    try rm(f; force=true) catch end
end
```

- [ ] **Step 2: 검사를 돌려 실패를 확인한다**

Run: `julia +lts --project=. tools/monitor/test_live_gate.jl`
Expected: FAIL — "평면도 이전 주입은 409 (받은 값: 202)" 와 "사이드카 부재 시 204"(라우트 없음 → 404).

- [ ] **Step 3: 서버에 두 규칙을 넣는다**

`server.jl` 의 `/inject/zone` 라우트에서 `key === nothing && return …` 줄 **아래**에 추가한다:

```julia
            # 평면도가 나오기 전에 도착한 주입은 조작자가 고른 것일 수 없다(평면도는 env 빌드 뒤에 나온다).
            # 2026-08-12 실측: 런 시작 14ms 뒤에 도착한 구역이 존 케이스를 사람이 정의하지 않은 런으로
            # 만들었다. 출처는 규명하지 못했으므로 조건을 막는다.
            isfile(layout_path(key)) || return HTTP.Response(409, cors(),
                "floor plan not published yet — draw the zone after it appears")
```

같은 파일의 `/layout` 라우트 **아래**에 새 라우트를 추가한다:

```julia
        # 활성 런의 사이드카. 대시보드는 이 토큰이 자기 것과 같을 때만 스트림을 화면에 올린다.
        # 아직 스트림이 열리지 않았으면 204 — 존 런에서는 조작자가 구역을 확정할 때까지 그렇다.
        if req.method == "GET" && path == "/runinfo"
            key = ACTIVE_KEY[]
            key === nothing && return HTTP.Response(409, cors(), "no active simulation; start a run first")
            p = run_info_path(key)
            isfile(p) || return HTTP.Response(204, cors())
            return HTTP.Response(200, [cors(); "Content-Type" => "application/json"], read(p))
        end
```

`server.jl` 에는 **새 include 를 넣지 않는다.** 서버가 쓰는 것은 자기 `run_info_path(key)` 하나뿐이고, 검사 파일이 `run_header.jl` · `zone_command.jl` 을 이미 직접 include 한다. 두 경로 규칙이 같은 파일을 가리키는지는 Step 4 에서 검사한다.

- [ ] **Step 4: 두 경로 규칙이 일치하는지 검사한다**

`test_live_gate.jl` 의 "서버의 사이드카 경로 규칙" 검사 **아래**에 추가한다:

```julia
ok(run_info_path_of(command_path("tractor.mpd__zone")) == run_info_path("tractor.mpd__zone"),
   "명령파일 기준 경로 == key 기준 경로 (엔진과 서버가 같은 파일을 본다)")
```

이 검사가 이 계획에서 **가장 중요한 한 줄**이다. 두 경로가 어긋나면 엔진은 사이드카를 쓰는데 서버는 다른 자리를 보고 영원히 204 를 돌려주고, 대시보드는 정상적으로 시작된 런을 영영 화면에 못 올린다.

- [ ] **Step 5: 검사를 돌린다**

Run: `julia +lts --project=. tools/monitor/test_live_gate.jl`
Expected: `live-gate check: 22 PASS / 0 FAIL`, 종료 코드 0.

- [ ] **Step 6: 커밋**

```bash
git add tools/monitor/server.jl tools/monitor/test_live_gate.jl
git commit -m "feat(monitor): 평면도 이전 구역 주입을 거절하고 GET /runinfo 로 런 토큰을 노출한다"
```

---

### Task 4: 대시보드가 자기 런의 프레임만 화면에 올린다

**Files:**
- Modify: `tools/monitor/dashboard.html` (`requestGeneration` 의 응답 처리와 폴링 조건)
- Test: 구조 검사(아래 Step 4) + 사람이 브라우저로 확인(Task 5 Step 5)

**Interfaces:**
- Consumes: Task 1 의 `POST /run` JSON 응답(`run_id`), Task 3 의 `GET /runinfo`
- Produces: 없음(UI 종단)

**정직하게 적어 둘 것:** 이 저장소에는 지금 JS 런타임이 없다(`node`·`qjs` 둘 다 없음). 그래서 Step 4 의 검사는 **동작 검사가 아니라 구조 검사(린트)** 다. 실제 동작 확인은 Task 5 Step 5 의 사람 확인이 담당한다. 이 사실을 리뷰어에게 숨기지 말 것.

- [ ] **Step 1: 응답에서 run_id 를 꺼내 보관한다**

`dashboard.html` 의 `requestGeneration` 안, `var runStreamUrl = streamFile(...)` 줄 **아래**에 추가한다:

```javascript
    // 이 런의 토큰. 서버가 발급하고 엔진이 사이드카에 남긴다. 화면에 올릴 프레임을 이걸로 고른다.
    var myRunId = null;
```

같은 함수의 `.then(function(txt){` 블록에서 `showLivePreparing();` **앞**에 추가한다:

```javascript
        // 성공 응답만 JSON 이다(busy/already running 은 위에서 평문으로 걸러졌다).
        try { myRunId = JSON.parse(txt).run_id || null; } catch(e){ myRunId = null; }
```

- [ ] **Step 2: 폴링 조건을 "내 런인가"로 바꾼다**

같은 함수의 `genPoll = setInterval(function(){` 안에서, `fetch(runStreamUrl, …)` 로 시작하는 블록 전체를 교체한다.

교체 전(현재):

```javascript
          fetch(runStreamUrl, {cache:"no-store"}).then(function(r){ return r.ok ? r.text() : ""; })
            .then(function(t){
              if(parseJSONL(t).length > 0){
```

교체 후:

```javascript
          // 옛 녹화가 디스크에 그대로 있는 동안(env 빌드에 3~4분) "파일이 비었나"만 보면 그 옛 녹화를
          // 라이브로 착각한다 — 실측: 존 케이스에서 사람이 그리기도 전에 자동 주입기의 구역이 피드에
          // 떴다. 그래서 **내 런의 사이드카가 뜬 뒤에만** 스트림을 읽는다.
          fetch(CONFIG.CONTROL_URL + "/runinfo", {cache:"no-store"})
            .then(function(r){ return r.status === 200 ? r.json() : null; })
            .then(function(info){
              if(!info) return "";                                  // 아직 스트림이 안 열렸다
              if(myRunId && info.run_id !== myRunId) return "";      // 다른 런의 것 — 화면에 올리지 않는다
              return fetch(runStreamUrl, {cache:"no-store"}).then(function(r){ return r.ok ? r.text() : ""; });
            })
            .then(function(t){
              if(t && parseJSONL(t).length > 0){
```

**주의:** 뒤따르는 `.catch(function(){});` 와 중괄호 짝은 그대로 둔다. 교체는 위 세 줄 → 열 줄이며, 그 아래의 `$("genHint").textContent = …` 부터는 손대지 않는다.

- [ ] **Step 3: 존 케이스 대기 문구를 정확하게 고친다**

같은 함수에서 `$("genHint").textContent = "Preparing the environment and simulation (OOD seed " + runSeed + "). This may take several minutes.";` 를 교체한다:

```javascript
    $("genHint").textContent = "Preparing the environment and simulation (OOD seed " + runSeed +
      "). This may take several minutes." +
      (isZoneCase(runCase) ? " Nothing is recorded until you confirm a zone on the floor plan." : "");
```

- [ ] **Step 4: 구조 검사를 추가한다**

`tools/monitor/test_live_gate.jl` 의 `println("live-gate check: …")` **앞**에 추가한다:

```julia
println()
println("== dashboard (구조 검사 — JS 런타임이 없어 동작 검사가 아니다) ==")
dash = read(joinpath(@__DIR__, "dashboard.html"), String)
ok(occursin("/runinfo", dash), "폴링이 /runinfo 를 부른다")
ok(occursin("myRunId", dash), "런 토큰을 보관한다")
ok(!occursin(r"if\(parseJSONL\(t\)\.length > 0\)\{", dash),
   "옛 무조건 수용 분기(parseJSONL(t).length > 0)가 남아 있지 않다")
```

- [ ] **Step 5: 검사를 돌린다**

Run: `julia +lts --project=. tools/monitor/test_live_gate.jl`
Expected: `live-gate check: 25 PASS / 0 FAIL`

- [ ] **Step 6: 커밋**

```bash
git add tools/monitor/dashboard.html tools/monitor/test_live_gate.jl
git commit -m "feat(dashboard): 자기 런의 사이드카가 뜬 뒤에만 스트림을 화면에 올린다"
```

---

### Task 5: 실제 런으로 끝까지 확인하고 문서를 맞춘다

**Files:**
- Modify: `tools/monitor/README.md` (흐름도)
- 코드 변경 없음(Step 1~4 에서 결함이 나오면 그 수정만)

**Interfaces:**
- Consumes: Task 1~4 전부

**이 Task 가 필요한 이유:** 앞의 검사들은 시뮬레이션을 돌리지 않는다. "확정 전에는 녹화본이 안 잘린다"는 이 계획의 핵심 보장이고, 그건 실제 엔진을 띄워야만 증명된다.

- [ ] **Step 1: 녹화본을 백업한다**

검증이 녹화본을 파괴할 수 있다. 되돌릴 수 있게 먼저 뜬다.

```bash
cp -r tools/monitor/streams /tmp/streams_backup_task5
ls /tmp/streams_backup_task5 | wc -l
md5sum tools/monitor/streams/tractor__zone.jsonl | tee /tmp/zone_md5_before.txt
```

- [ ] **Step 2: 서버를 띄우고 존 라이브 런을 시작한다**

```bash
DSPY_URL=http://127.0.0.1:8077 \
NOVELTY_CALIB=$PWD/wm4spacecraft_manufacturing/novelty_calibration_no_zoneblk.json \
julia +lts --project=. tools/monitor/server.jl > /tmp/task5_server.log 2>&1 &
```

서버가 뜬 뒤(`curl -s --max-time 3 http://127.0.0.1:8080/ >/dev/null` 성공) 런을 시작한다:

```bash
curl -s -X POST http://127.0.0.1:8080/run -H 'Content-Type: application/json' \
  -d '{"model":"tractor.mpd","case":"zone","interactive":true,"n":0,"seed":1,"wait":300}' | tee /tmp/task5_run.json
```
Expected: `{"status":"started","run_id":"<숫자>"}`

- [ ] **Step 3: 게이트 전 무기록·이른 주입 거절을 확인한다 (핵심 검증)**

env 빌드가 도는 동안(평면도가 나오기 전에) 주입을 시도한다:

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://127.0.0.1:8080/inject/zone \
  -H 'Content-Type: application/json' -d '{"x":0.5,"y":0.4,"r":0.3}'
```
Expected: `409`

평면도가 나올 때까지 기다린 뒤(수 분) 상태를 확인한다:

```bash
until curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/layout | grep -q 200; do sleep 10; done
echo "layout published"
curl -s -o /dev/null -w "runinfo=%{http_code}\n" http://127.0.0.1:8080/runinfo
md5sum tools/monitor/streams/tractor__zone.jsonl
```
Expected: `runinfo=204`(아직 스트림이 안 열렸다) 그리고 md5 가 `/tmp/zone_md5_before.txt` 와 **같다**(녹화본이 안 잘렸다). 다르면 이 계획의 핵심 보장이 깨진 것이므로 **멈추고 크게 보고한다.**

- [ ] **Step 4: 구역을 확정하고 토큰이 맞는지 확인한다**

```bash
curl -s -X POST http://127.0.0.1:8080/inject/zone -H 'Content-Type: application/json' \
  -d '{"x":0.5,"y":0.4,"r":0.3}'
until curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/runinfo | grep -q 200; do sleep 5; done
curl -s http://127.0.0.1:8080/runinfo
```
Expected: 202 뒤에 사이드카가 200 으로 뜨고, 그 `run_id` 가 Step 2 의 `/tmp/task5_run.json` 과 **같다**. `zone` 필드가 `{"x":0.5,"y":0.4,"r":0.3,...}` 이다. `requires_zone` 이 `true` 다.

- [ ] **Step 5: 사람이 브라우저로 확인한다**

`http://127.0.0.1:8080/` 를 새로고침(캐시 무효화가 붙었으므로 강제 새로고침 불필요)하고 ③ Forbid Zone 케이스로 `Start live session` 을 누른다. 확인할 것:

- 평면도가 나오기 전까지 **OOD 이벤트 피드가 비어 있다**(옛 녹화의 "A no-go exclusion zone has appeared at (1.09, 0.42)" 가 뜨지 않는다 — 이것이 원래 증상이다).
- 평면도에 구역을 그리고 `Confirm zone & start` 를 눌러야 프레임이 흐르기 시작한다.
- 피드의 첫 구역 문장이 `A human operator injected …` 이고 좌표가 **자기가 그린 값**이다.

- [ ] **Step 6: 취소가 녹화본을 보존하는지 확인한다**

새 런을 시작해 평면도가 나온 뒤 취소한다:

```bash
curl -s -X POST http://127.0.0.1:8080/run -H 'Content-Type: application/json' \
  -d '{"model":"tractor.mpd","case":"zone","interactive":true,"n":0,"seed":1,"wait":300}'
until curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/layout | grep -q 200; do sleep 10; done
curl -s -X POST http://127.0.0.1:8080/abort
sleep 5
md5sum tools/monitor/streams/tractor__zone.jsonl
```
Expected: md5 가 Step 4 에서 만들어진 값과 같다(취소한 런이 녹화본을 건드리지 않았다).

- [ ] **Step 7: 비대화형 녹화가 종전대로 도는지 확인한다 (회귀)**

라이브 경로를 고치면서 녹화 경로를 깨지 않았는지 본다. **런을 겹쳐 돌리지 말 것** — 서버의 런이 끝난 뒤에 한다.

```bash
DSPY_URL=http://127.0.0.1:8077 bash tools/monitor/regen_router_cases.sh zone > /tmp/task5_regen.log 2>&1
tail -3 /tmp/task5_regen.log
python - <<'PY'
import json
p='tools/monitor/streams/tractor__zone.jsonl'
first=json.loads(open(p,encoding='utf-8').readline())
print('첫 줄이 프레임인가(형식 불변 확인):', 'depots' in first or 'sim_t' in first)
print('run_id 가 스트림에 새지 않았는가:', 'run_id' not in first)
PY
```
Expected: `STATUS render ok cases=1/1 failed=none`, 그리고 첫 줄이 **프레임**이다(`run_id` 없음). 스트림 형식 불변이 이 계획의 Global Constraint 다.

- [ ] **Step 8: 문서를 맞춘다**

`tools/monitor/README.md` 의 "지금의 흐름" 블록을 교체한다:

```
케이스 ③⑤⑥ 선택        → 아무것도 재생하지 않는다. "구역을 정의하라"는 상태.
                          (옛 녹화를 보려면 `Load previous recording` — "자동 주입" 배지가 붙는다)
Start live session      → 서버가 run_id 를 발급하고 MONITOR_REQUIRE_ZONE=1 로 render_demo.jl 을 띄운다
                          (직전 런의 layout.json·run.json 을 지운다)
env 빌드(수 분)          → pre_sim_hook 이 commands/<key>.layout.json 을 쓴다
                        → **첫 스텝 전에 멈춰 무한 대기**(마감 없음)
                        → 이 시점까지 **스트림 파일은 손대지 않는다** = 옛 녹화본이 살아 있다
대시보드                 → GET /layout 으로 평면도. GET /runinfo 는 아직 204.
                          (평면도 이전에 POST /inject/zone 이 오면 409 — 사람이 고른 것일 수 없다)
`Confirm zone & start`  → POST /inject/zone → 게이트 통과 → 그때 스트림을 열고
                          commands/<key>.run.json 에 {run_id, zone} 을 남긴다
                        → 대시보드는 그 run_id 가 자기 것일 때만 프레임을 화면에 올린다
`Cancel session`        → POST /abort → 시뮬레이션을 돌리지 않고 종료. 옛 녹화본 보존.
```

- [ ] **Step 9: 커밋**

```bash
git add tools/monitor/README.md
git commit -m "docs(monitor): 런 토큰·게이트 전 무기록을 흐름도에 반영"
```

---

## 실행 순서 요약

| Task | 내용 | 소요 |
|---|---|---|
| 1 | 사이드카 모듈 + 서버 run_id 발급 + serve 가드 | ~25분 |
| 2 | 엔진: 게이트 뒤 스트림 열기 + 사이드카 기록 | ~30분 |
| 3 | 평면도 이전 주입 409 + `/runinfo` | ~20분 |
| 4 | 대시보드 토큰 게이팅 | ~20분 |
| 5 | 실제 런 e2e + 회귀 + 문서 | ~60분(대부분 env 빌드 대기) |

Task 1~4 의 검사는 전부 초 단위다. 시간은 Task 5 가 거의 전부이고 그중 대부분이 env 빌드 대기다.
