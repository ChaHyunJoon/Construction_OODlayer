# =============================================================================
# selfimprove 라이브러리 팔 경로 (spec §9.1, §5.4, §0.0 R4·R8) — `tools/monitor/libarm.jl`.
#   (a) 정상 body → execution_ok=true
#   (b) 두 번째 호출에서 던지는 body → enact_minted! 는 **반환**하지만 execution_ok=false, steps 에 :threw
#   (c) arm 파일 한 바이트 변조 → register_minted_primitive! **전에** error, minted_table 에 이름 없음
#   (d) 원래 이름이 같은 두 arm(m100_x!, m101_x!) 둘 다 등록
#   (e) libarm.jl 소스에 service_·rewrite·enact_minted_decision! 0건 (LLM 경로 없음)
#   (f) 디스패치: 버전 팔 id ≥ 100 은 레지스트리 이름으로, SELFIMPROVE_ARM 은 zone 사건에만
# 실행: julia +lts --project=. test/selfimprove_libarm.jl
# =============================================================================
module SelfimproveLibarm

using Test
using ConstructionBots
const CB = ConstructionBots
import JSON3, HTTP
using SHA

isdefined(CB, :ZoneTruth) || CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))

const TMP = mktempdir()
const A0 = JSON3.read(read(joinpath(@__DIR__, "..", "src", "decision", "core", "action_registry.json"), String),
                      Dict{String,Any})

# 레지스트리 v5-4arms: A₀ + 팔 100 (libarm_for 가 이름 → id 를 여기서 찾는다)
let reg = deepcopy(A0)
    reg["vocab"] = "v5-4arms"
    reg["macros"]["100"] = Dict{String,Any}("name" => "m100_si_ok!", "cost" => 1.0, "kinds" => ["zone"],
                                            "mechanism" => "t", "when_to_use" => "t", "library_arm" => 100)
    write(joinpath(TMP, "reg.json"), JSON3.write(reg))
end
const _PREV_REG = get(ENV, "ACTION_REGISTRY", nothing)
ENV["ACTION_REGISTRY"] = joinpath(TMP, "reg.json")
include(joinpath(@__DIR__, "..", "src", "decision", "core", "action_registry.jl"))
_PREV_REG === nothing ? delete!(ENV, "ACTION_REGISTRY") : (ENV["ACTION_REGISTRY"] = _PREV_REG)

# policy.jl 의 두 이름 — 이 시험은 서비스 없이(라우터 꺼짐) 돈다.
router_drives() = false
const DSPY_URL = "http://127.0.0.1:1"
include(joinpath(@__DIR__, "..", "tools", "monitor", "enact.jl"))
include(joinpath(@__DIR__, "..", "tools", "monitor", "libarm.jl"))

"`reset_cache_resume!` 이 실제로 나갈 수 있는 최소 env (test/minted_end_to_end.jl 의 관용구)."
function live_env()
    sched = CB.OperatingSchedule()
    cache = CB.initialize_planning_cache(sched)
    return (cache = cache, sched = sched, active_build_steps = Set{CB.AbstractID}(), dt = 0.1)
end

arm(id, name; code = "function $(name)(env; k::Int = 1)\n    return (status = :si_ok, k = k)\nend\n",
    calls = [Dict{String,Any}("primitive" => name, "args" => Dict{String,Any}("k" => 1))],
    role = "promoted") =
    Dict{String,Any}("arm_id" => id, "impl_name" => name, "impl_code" => code, "calls" => calls,
                     "params" => Dict{String,Any}("k" => Dict{String,Any}("type" => "integer")),
                     "surface" => "geom", "reversible" => false,   # RESOLVE_SURFACES 밖: 최소 env 는 재풀이를 못 한다
                     "body_names" => [c["primitive"] for c in calls], "role" => role,
                     "artifact_sha256" => "art$(id)")

"버전 디렉터리 하나를 만든다 — manifest 의 arm_json_sha256 은 **쓴 바이트**의 sha."
function write_version(dir, arms)
    mkpath(joinpath(dir, "arms"))
    meta = Any[]
    for a in arms
        raw = JSON3.write(a)
        write(joinpath(dir, "arms", "m$(a["arm_id"]).json"), raw)
        push!(meta, Dict("arm_id" => a["arm_id"], "arm_json_sha256" => bytes2hex(sha256(raw))))
    end
    m = JSON3.write(Dict("version" => "v1", "arms" => meta,
                         "registry_sha256" => bytes2hex(sha256(read(joinpath(TMP, "reg.json"))))))
    write(joinpath(dir, "manifest.json"), m)
    write(joinpath(dir, "manifest.sha256"), bytes2hex(sha256(m)) * "\n")
    return bytes2hex(sha256(m))
end

function with_env(f, kv)
    old = Dict(k => get(ENV, k, nothing) for k in keys(kv))
    try
        for (k, v) in kv; ENV[k] = v; end
        f()
    finally
        for (k, v) in old; v === nothing ? delete!(ENV, k) : (ENV[k] = v); end
    end
end

reset_libarms!() = (empty!(LIBARMS); FORCED_ARM[] = nothing; CB.reset_minted_table!())

@testset "selfimprove libarm" begin
    ZT = CB.ZoneTruth(:si_zone, [0.0, 0.0, 0.0], 1.0)

    @testset "(a) 정상 body → execution_ok" begin
        reset_libarms!()
        d = joinpath(TMP, "va"); msha = write_version(d, [arm(100, "m100_si_ok!")])
        with_env(Dict("SELFIMPROVE_VERSION_DIR" => d, "SELFIMPROVE_MANIFEST_SHA" => msha,
                      "ACTION_REGISTRY" => joinpath(TMP, "reg.json"))) do
            assert_selfimprove_version()
            load_library_arms!()
        end
        @test haskey(LIBARMS, 100)
        r = enact_libarm!(live_env(), ZT, LIBARMS[100])
        @test r.execution_ok === true
    end

    @testset "(b) 절반 편집하고 던지는 body → execution_ok=false, :threw" begin
        reset_libarms!()
        code = "function si_boom!(env; k::Int = 1)\n    k == 2 && error(\"boom\")\n    return (status = :si_ok, k = k)\nend\n"
        calls = [Dict{String,Any}("primitive" => "si_boom!", "args" => Dict{String,Any}("k" => k)) for k in (1, 2)]
        a = arm(900, "si_boom!"; code = code, calls = calls, role = "candidate")
        p = joinpath(TMP, "boom.json"); write(p, JSON3.write(a))
        with_env(Dict("SELFIMPROVE_ARM" => p, "SELFIMPROVE_ARM_SHA" => bytes2hex(sha256(read(p))))) do
            load_library_arms!()
        end
        r = redirect_stdout(() -> enact_libarm!(live_env(), ZT, FORCED_ARM[]), devnull)
        @test r.execution_ok === false
        @test any(s -> s.status == "threw", r.rec["steps"])
    end

    @testset "(c) 변조된 arm 파일은 등록 전에 죽는다" begin
        reset_libarms!()
        d = joinpath(TMP, "vc"); msha = write_version(d, [arm(100, "m100_si_ok!")])
        f = joinpath(d, "arms", "m100.json")
        b = read(f); b[end-1] = b[end-1] == UInt8('"') ? UInt8(' ') : b[end-1]; b[2] = UInt8(' ')
        write(f, b)
        with_env(Dict("SELFIMPROVE_VERSION_DIR" => d, "SELFIMPROVE_MANIFEST_SHA" => msha,
                      "ACTION_REGISTRY" => joinpath(TMP, "reg.json"))) do
            @test_throws ErrorException load_library_arms!()
        end
        @test !haskey(CB.minted_table(), "m100_si_ok!")
        @test isempty(LIBARMS)
    end

    @testset "(c2) 고정 manifest sha 와 다른 버전 디렉터리는 죽는다" begin
        reset_libarms!()
        d = joinpath(TMP, "vc2"); write_version(d, [arm(100, "m100_si_ok!")])
        with_env(Dict("SELFIMPROVE_VERSION_DIR" => d, "SELFIMPROVE_MANIFEST_SHA" => "0"^64,
                      "ACTION_REGISTRY" => joinpath(TMP, "reg.json"))) do
            @test_throws ErrorException assert_selfimprove_version()
        end
    end

    @testset "(d) 원래 이름이 같은 두 팔 둘 다 등록" begin
        reset_libarms!()
        d = joinpath(TMP, "vd")
        msha = write_version(d, [arm(100, "m100_x!"), arm(101, "m101_x!")])
        with_env(Dict("SELFIMPROVE_VERSION_DIR" => d, "SELFIMPROVE_MANIFEST_SHA" => msha,
                      "ACTION_REGISTRY" => joinpath(TMP, "reg.json"))) do
            load_library_arms!()
        end
        @test sort(collect(keys(LIBARMS))) == [100, 101]
        @test haskey(CB.minted_table(), "m100_x!") && haskey(CB.minted_table(), "m101_x!")
    end

    @testset "(e) LLM·/rewrite 경로 문자열 0건" begin
        src = read(joinpath(@__DIR__, "..", "tools", "monitor", "libarm.jl"), String)
        for bad in ("service_", "rewrite", "enact_minted_decision!")
            @test !occursin(bad, src)
        end
    end

    @testset "(f) 디스패치" begin
        # 등록은 (a)(d) 가 쟀다. 여기는 이름 → 팔 해석만 잰다(같은 프로세스에서 같은 이름을 두 번
        # `Core.eval` 할 수 없으므로 — 생산에서는 판마다 새 프로세스다).
        empty!(LIBARMS); FORCED_ARM[] = nothing
        LIBARMS[100] = arm(100, "m100_si_ok!")
        @test libarm_for(ZT, "m100_si_ok!")["arm_id"] == 100
        @test libarm_for(ZT, "NOOP") === nothing
        @test libarm_for(CB.FaultTruth(CB.RobotID(1), [0.0, 0.0]), "m100_si_ok!") === nothing
        FORCED_ARM[] = arm(900, "si_forced!", role = "candidate")
        @test libarm_for(ZT, "NOOP")["arm_id"] == 900                  # S1·S3: zone 이면 강제 팔
        @test libarm_for(CB.FaultTruth(CB.RobotID(1), [0.0, 0.0]), "NOOP") === nothing
        FORCED_ARM[] = nothing; empty!(LIBARMS)
        @test_throws ErrorException libarm_for(ZT, "m100_si_ok!")   # 레지스트리엔 있는데 검증된 팔이 없다
    end
end

end # module
