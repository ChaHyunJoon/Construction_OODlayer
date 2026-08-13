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

println()
println("== server ==")
include(joinpath(@__DIR__, "server.jl"))     # serve 가드 덕분에 포트를 열지 않는다

ok(new_run_id() != new_run_id(), "run_id 가 매번 다르다")
# safe_base 는 splitext 로 **마지막 점 뒤를 통째로 떼므로** "tractor.mpd__zone" → "tractor" 다
# (계획서 초안은 "tractor_mpd__zone" 을 기대했는데 그건 이 저장소의 실제 규칙이 아니다 — 이미
# 디스크에 있는 commands/tractor.jsonl · tractor.layout.json 이 그 증거다). 케이스마다 파일이
# 갈리지 않는 것은 의도된 것이다: 런은 동시에 하나뿐이고 spawn_run 이 매번 지우고 새로 연다.
ok(basename(run_info_path("tractor.mpd__zone")) == "tractor.run.json",
   "서버의 사이드카 경로 규칙 (command_path/layout_path 와 같은 safe_base stem)")
ok(basename(command_path("tractor.mpd__zone")) == "tractor.jsonl",
   "그 규칙이 기존 command_path 와 같다(디스크의 실제 파일명과 일치)")

ACTIVE_KEY[] = "tractor.mpd__zone"; ACTIVE_RUN_ID[] = "abc123"
st = JSON3.read(String(router(HTTP.Request("GET", "/status")).body))
ok(String(st[:run_id]) == "abc123", "/status 가 run_id 를 싣는다")

# 이 검사가 이 계획에서 **가장 중요한 한 줄**이다. 두 경로가 어긋나면 엔진은 사이드카를 쓰는데
# 서버는 다른 자리를 보고 영원히 204 를 돌려주고, 대시보드는 정상적으로 시작된 런을 영영 못 올린다.
ok(run_info_path_of(command_path("tractor.mpd__zone")) == run_info_path("tractor.mpd__zone"),
   "명령파일 기준 경로 == key 기준 경로 (엔진과 서버가 같은 파일을 본다)")

# 평면도가 없으면 구역 주입을 거절한다 — 조작자가 볼 수 없는 상태에서 온 주입은 사람이 고른 것이 아니다.
ACTIVE_KEY[] = "tractor.mpd__zone"
# 이 검사는 **실제 commands/ 를 건드린다**(COMMAND_DIR 이 include 시점 const 라 갈아끼울 수 없다).
# 그 안의 tractor.jsonl · tractor.layout.json 은 저장소가 추적하는 파일이므로, 지우기 전에 원본을
# 떠 두었다가 끝나고 되돌린다. (되돌리지 않으면 검사를 한 번 돌릴 때마다 작업트리에 삭제가 남는다 —
# 실제로 그렇게 됐고 git checkout 으로 복구해야 했다.)
const _GUARDED = [layout_path(ACTIVE_KEY[]), command_path(ACTIVE_KEY[]), run_info_path(ACTIVE_KEY[])]
const _SAVED = Dict(f => (isfile(f) ? read(f) : nothing) for f in _GUARDED)
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

# 뒷정리 — 검사가 실제 commands/ 를 더럽히지 않아야 한다. 원래 없던 파일은 지우고,
# 원래 있던 파일은 **바이트 그대로 되돌린다**(추적 중인 파일이라 삭제가 작업트리에 남는다).
for f in _GUARDED
    try
        s = _SAVED[f]
        s === nothing ? rm(f; force=true) : write(f, s)
    catch end
end
ok(all(f -> (_SAVED[f] === nothing) == !isfile(f), _GUARDED), "검사가 commands/ 를 원상복구한다")

println()
println("== dashboard (구조 검사 — JS 런타임이 없어 동작 검사가 아니다) ==")
dash = read(joinpath(@__DIR__, "dashboard.html"), String)
ok(occursin("/runinfo", dash), "폴링이 /runinfo 를 부른다")
ok(occursin("myRunId", dash), "런 토큰을 보관한다")
ok(!occursin(r"if\(parseJSONL\(t\)\.length > 0\)\{", dash),
   "옛 무조건 수용 분기(parseJSONL(t).length > 0)가 남아 있지 않다")

println()
println("live-gate check: $(PASS[]) PASS / $(FAIL[]) FAIL")
exit(FAIL[] == 0 ? 0 : 1)
