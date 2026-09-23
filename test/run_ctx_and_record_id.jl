# =============================================================================
# test/run_ctx_and_record_id.jl — 원장 행 id 와 판 신원 (2026-09-22)
#
#   julia +lts --project=. test/run_ctx_and_record_id.jl
#
# 🔴 id 생성이 전역 RNG 를 한 칸이라도 밀면 같은 시드가 다른 세계가 된다
#    (memory: sim-runs-must-be-seed-reproducible). 그래서 (1) 이 첫 명제다.
#    판 지문(`run_fingerprint`, (6))도 같은 명제를 진다 — git 을 서브프로세스로 부르므로
#    "프로세스·태스크를 띄우는 것이 전역 RNG 를 안 민다" 를 가정하지 않고 **잰다**.
# =============================================================================
module RunCtxAndRecordId

using Test
import JSON3
import Random
include(joinpath(@__DIR__, "..", "tools", "monitor", "policy.jl"))

@testset "(1) record id 는 전역 RNG 를 안 민다" begin
    Random.seed!(7); local a = rand()
    Random.seed!(7); new_record_id(); new_record_id(); local b = rand()
    @test a == b
end

@testset "(2) record id 는 매번 다르고 24 hex 다" begin
    local ids = [new_record_id() for _ in 1:1000]
    @test length(unique(ids)) == 1000
    @test all(i -> occursin(r"^[0-9a-f]{24}$", i), ids)
end

@testset "(3) RUN_CTX — 기본은 빈 dict, set_run_ctx! 는 문자열 키로 통째로 바꾼다" begin
    set_run_ctx!()
    @test RUN_CTX[] isa Dict{String,Any} && isempty(RUN_CTX[])
    set_run_ctx!(run_id = "r", seed = 3)
    @test RUN_CTX[] == Dict{String,Any}("run_id" => "r", "seed" => 3)
    set_run_ctx!()
    @test isempty(RUN_CTX[])
end

@testset "(4) _stamp_identity! 가 페이로드에 id 와 신원을 싣고 JSON 으로 왕복한다" begin
    set_run_ctx!(run_id = "r", seed = 3, zone_seed = 3)
    local p = _stamp_identity!(Dict{String,Any}("kind" => "zone"))
    @test occursin(r"^[0-9a-f]{24}$", p["record_id"])
    local back = JSON3.read(JSON3.write(p))
    @test back[:run_ctx][:seed] == 3
    @test back[:kind] == "zone"
    local q = _stamp_identity!(Dict{String,Any}())
    @test q["record_id"] != p["record_id"]
    # 🔴 사본이다 — 페이로드 쪽을 고쳐도 판 신원(공유 Dict)은 안 변한다.
    @test p["run_ctx"] == RUN_CTX[]
    @test p["run_ctx"] !== RUN_CTX[]
    p["run_ctx"]["seed"] = 99
    @test RUN_CTX[]["seed"] == 3
    @test q["run_ctx"]["seed"] == 3
    set_run_ctx!()
end

@testset "(5) SYNTH_LANE_KEYS 가 record_id·response_id 를 나른다" begin
    @test "record_id" in SYNTH_LANE_KEYS
    @test "response_id" in SYNTH_LANE_KEYS
    # 서비스는 둘을 `synthesis` dict 안에 싣는다 → `_synth_view` 가 그대로 뽑는다.
    local fake = JSON3.read(JSON3.write(Dict{String,Any}(
        "tool_minted" => false,
        "synthesis" => Dict{String,Any}("record_id" => "abc", "response_id" => "def"))))
    local v = _synth_view(fake)
    @test v["record_id"] == "abc"
    @test v["response_id"] == "def"
    @test _synth_view(nothing)["record_id"] === nothing
    @test _synth_view(nothing)["response_id"] === nothing
end

@testset "(6) run_fingerprint — 전역 RNG 를 안 밀고, 세 키를 내고, git 이 없어도 안 죽는다" begin
    Random.seed!(11); local a = rand()
    Random.seed!(11); local fp = run_fingerprint(); local b = rand()
    @test a == b
    @test Set(keys(fp)) == Set([:code_rev, :code_dirty_digest, :config_digest])
    @test occursin(r"^[0-9a-f]{40}$", fp.code_rev)                  # 이 트리는 git 저장소다
    @test fp.code_dirty_digest == "" || occursin(r"^[0-9a-f]{16}$", fp.code_dirty_digest)
    @test occursin(r"^[0-9a-f]{16}$", fp.config_digest)

    # 설정 지문만 보는 호출은 저장소가 아닌 디렉터리로 부른다 — 이 트리의 untracked 는 수백 MB 라
    # 매번 코드 지문까지 재면 절이 수십 초가 된다(config_digest 는 repo 와 무관하다).
    local nonrepo = mktempdir()
    local cfg(e) = run_fingerprint(nonrepo; env = e).config_digest
    # 설정 지문: 접두사 키만 보고, 순서에 무관하고, 값 하나가 바뀌면 바뀐다.
    local e1 = Dict("DEMO_SEED" => "3", "DS_HOTSWAP" => "1", "HOME" => "/x", "PATH" => "/y")
    local e2 = Dict("DS_HOTSWAP" => "1", "DEMO_SEED" => "3", "HOME" => "/other")
    local e3 = Dict("DEMO_SEED" => "3", "DS_HOTSWAP" => "0")          # 셀 축이 아닌 값 하나가 다르다
    @test cfg(e1) == cfg(e2)
    @test cfg(e1) != cfg(e3)
    for k in ("DSPY_URL", "TOOL_SYNTHESIS", "SYNTH_RECORD_LOG")
        @test cfg(merge(e1, Dict(k => "v"))) != cfg(e1)
    end

    # 🔴 R5a: 셀 불변 — run_ctx 가 따로 싣는 셀 축(과 산출물 위치)은 설정 지문에서 빠진다.
    local cell_a = merge(e1, Dict("DEMO_SEED" => "3", "DEMO_ZONE_SEED" => "1", "DEMO_CASE_TAG" => "zone",
                                  "DEMO_CAMPAIGN_ID" => "c1", "DEMO_OOD" => "none", "DEMO_ZONE" => "1",
                                  "DEMO_POLICY" => "dspy", "DEMO_ROUTER" => "1",
                                  "DEMO_MODEL" => "tractor.mpd", "DEMO_SYNTH_FIXTURE" => "",
                                  "DEMO_OUT_DIR" => "/a"))
    local cell_b = merge(e1, Dict("DEMO_SEED" => "9", "DEMO_ZONE_SEED" => "7", "DEMO_CASE_TAG" => "all3",
                                  "DEMO_CAMPAIGN_ID" => "c2", "DEMO_OOD" => "all", "DEMO_ZONE" => "0",
                                  "DEMO_POLICY" => "surrogate", "DEMO_ROUTER" => "0",
                                  "DEMO_MODEL" => "X-wing.mpd", "DEMO_SYNTH_FIXTURE" => "/f.json",
                                  "DEMO_OUT_DIR" => "/b"))
    @test cfg(cell_a) == cfg(cell_b)
    @test cfg(cell_a) == cfg(filter(kv -> !(kv.first in _CONFIG_ENV_EXCLUDED), cell_a))
    for (k, v) in ("DEMO_BSOC" => "0.45", "DS_HOTSWAP" => "0", "DSPY_PROGRAM" => "x")
        @test cfg(merge(cell_a, Dict(k => v))) != cfg(cell_a)
    end

    # 🔴 R5a: 코드 지문은 **추적 안 된 소스**도 본다. 임시 git 저장소에서 잰다.
    mktempdir() do repo
        local g(args...) = run(pipeline(`git -C $repo -c user.name=t -c user.email=t@t
                                         -c commit.gpgsign=false $(collect(args))`;
                                        stdout = devnull, stderr = devnull))
        g("init", "-q")
        mkpath(joinpath(repo, "src")); write(joinpath(repo, "src", "a.jl"), "x = 1\n")
        g("add", "src/a.jl"); g("commit", "-q", "--no-verify", "-m", "init")
        @test run_fingerprint(repo).code_dirty_digest == ""               # 깨끗 → ""
        write(joinpath(repo, "src", "new.jl"), "y = 1\n")                   # untracked 소스
        local d1 = run_fingerprint(repo).code_dirty_digest
        @test occursin(r"^[0-9a-f]{16}$", d1)
        write(joinpath(repo, "src", "new.jl"), "y = 2\n")                   # 내용만 바꾼다
        local d2 = run_fingerprint(repo).code_dirty_digest
        @test occursin(r"^[0-9a-f]{16}$", d2) && d2 != d1
        mv(joinpath(repo, "src", "new.jl"), joinpath(repo, "src", "renamed.jl"))  # 경로만 바꾼다
        @test run_fingerprint(repo).code_dirty_digest ∉ ("", d1, d2)
        rm(joinpath(repo, "src", "renamed.jl"))
        # 못 읽는 untracked 파일 — 던지지 않고 경로 + `unreadable` 표식으로 싣는다.
        local locked = joinpath(repo, "src", "locked.jl")
        write(locked, "z = 1\n"); chmod(locked, 0o000)
        try
            local dl = run_fingerprint(repo).code_dirty_digest
            @test occursin(r"^[0-9a-f]{16}$", dl)
        finally
            chmod(locked, 0o644); rm(locked)
        end
        write(joinpath(repo, "notes.txt"), "outside\n")                     # src/tools/test 밖
        @test run_fingerprint(repo).code_dirty_digest == ""
        write(joinpath(repo, "src", "a.jl"), "x = 2\n")                     # 추적 파일 편집
        @test occursin(r"^[0-9a-f]{16}$", run_fingerprint(repo).code_dirty_digest)
    end

    # git 이 실패하는 자리(저장소가 아닌 디렉터리) — 던지지 않고 "unknown" 으로 적는다.
    mktempdir() do dir
        local bad = run_fingerprint(dir)
        @test bad.code_rev == "unknown"
        @test bad.code_dirty_digest == "unknown"
        @test occursin(r"^[0-9a-f]{16}$", bad.config_digest)
    end
end

end # module

# =============================================================================
# (7) 배선 — `service_decide` 가 **실제로 나간 본문**에 id 와 신원을 싣는다
#
# 🔴 위 (4) 는 `_stamp_identity!` 를 따로 부른다. 그것만으로는 `service_decide` 안의 한 줄이
#    지워져도 전부 초록이다("배선했다" ≠ "작동한다", memory `wired-is-not-working…`). 그래서
#    `test/service_decide_ships_routing_kind.jl` 의 관용구 그대로 루프백 `/decide` 를 띄워
#    `decide_all` 이 보낸 본문을 붙잡는다. 유료 호출 0건(8077 로 나가는 요청 없음).
# =============================================================================
module RunCtxWire

using Test
using ConstructionBots
const CB = ConstructionBots
import HTTP, JSON3
import Random

const REPO = normpath(joinpath(@__DIR__, ".."))
isdefined(CB, :ZoneTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))

const _BODIES = String[]
const _SERVER = HTTP.serve!(HTTP.Sockets.localhost, 0; listenany = true, verbose = -1) do req
    if req.target == "/health"
        return HTTP.Response(200, "{\"status\":\"ok\",\"surro_kinds\":[\"battery\",\"fault\"]}")
    elseif req.target == "/decide"
        push!(_BODIES, String(req.body))
        local lanes = try
            local pl = JSON3.read(_BODIES[end])
            haskey(pl, :lanes) ? String.(collect(pl[:lanes])) : ["dspy", "surrogate"]
        catch
            ["dspy", "surrogate"]
        end
        local ok = Dict{String,Any}("chosen" => _NOOP_NAME, "ranking" => [_NOOP_NAME],
                                    "margin" => 0.0, "rationale" => "fake (identity gate)",
                                    "policy" => "test", "unsupported" => String[])
        return HTTP.Response(200, JSON3.write(Dict{String,Any}(l => ok for l in lanes)))
    end
    return HTTP.Response(404, "")
end

const _PREV_DSPY_URL = get(ENV, "DSPY_URL", nothing)
ENV["DSPY_URL"] = "http://127.0.0.1:$(HTTP.Servers.port(_SERVER))"
try
    include(joinpath(REPO, "tools", "monitor", "policy.jl"))
catch
    close(_SERVER); rethrow()
finally
    _PREV_DSPY_URL === nothing ? delete!(ENV, "DSPY_URL") : (ENV["DSPY_URL"] = _PREV_DSPY_URL)
end

const _NOOP_NAME = try ActionRegistry.NAME[0] catch; close(_SERVER); rethrow() end

const TENV = try
    CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "run_ctx_wire",
                       num_robots = 4, assignment_mode = :greedy, n_spare_per_pool = 2,
                       open_animation_at_end = false, save_animation = false,
                       write_results = false, return_env_before_sim = true,
                       rng = Random.MersenneTwister(1))
catch
    close(_SERVER); rethrow()
end

try
    @testset "(7) service_decide 의 본문에 record_id·run_ctx 가 실린다" begin
        set_run_ctx!(run_id = "wire", seed = 5, zone_seed = 0, model = "colored_8x8")
        local truth = CB.FaultTruth(CB.RobotID(1), Float64[0.0, 0.0])
        empty!(_BODIES)
        decide_all(TENV, truth; nl = "")
        decide_all(TENV, truth; nl = "")
        @test length(_BODIES) == 2              # 못 받았으면 아무것도 안 잰 것이다
        local b = [JSON3.read(s) for s in _BODIES]
        @test all(x -> occursin(r"^[0-9a-f]{24}$", String(x[:record_id])), b)
        @test b[1][:record_id] != b[2][:record_id]      # 결정마다 새 id
        for x in b
            @test Dict(String(k) => v for (k, v) in pairs(x[:run_ctx])) ==
                  Dict{String,Any}("run_id" => "wire", "seed" => 5, "zone_seed" => 0,
                                   "model" => "colored_8x8")
        end
        # 빈 신원(시험·헤드리스)도 싣는다 — 키가 빠지면 "모른다" 와 "안 보냈다" 가 섞인다.
        set_run_ctx!()
        empty!(_BODIES)
        decide_all(TENV, truth; nl = "")
        @test length(_BODIES) == 1
        local e = JSON3.read(_BODIES[1])
        @test haskey(e, :run_ctx) && isempty(e[:run_ctx])
        @test haskey(e, :record_id)
    end
finally
    set_run_ctx!()
    close(_SERVER)
end

end # module
