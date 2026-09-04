module WorldInterfaceCurrent
using Test
using ConstructionBots
import JSON3
const CB = ConstructionBots
const ART = normpath(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "core",
                              "world_interface.json"))

@testset "(1) 산출물이 있고 모양이 맞다" begin
    @test isfile(ART)
    j = JSON3.read(read(ART, String))
    @test haskey(j, :types) && haskey(j, :methods)
    @test !isempty(j.types) && !isempty(j.methods)
end

@testset "(2) 🔴 현행 코드와 일치한다 — 재생성해서 대조한다" begin
    # 손으로 유지되는 사본은 반드시 낡는다. `code_fingerprint` 와 같은 논거다.
    #
    # 🔴 Task 3 실측 (2026-09-04): 이 testset 은 **단독 실행에서는 초록이고 `Pkg.test()`
    #    안에서만 빨갛다** — 전역 오염이 아니라 **환경변수 오염**이다. `Pkg.jl`
    #    (`Operations.jl:1857`)이 샌드박스 테스트 프로세스에 `JULIA_LOAD_PATH="@:<tmp>"`
    #    를 심는데, 그 값에는 `@stdlib` 가 없다. 이 testset 이 그 프로세스 **안에서** 또
    #    자식 `julia` 를 띄우면 그 env var 를 그대로 물려받고, `--project=` 플래그는
    #    LOAD_PATH 의 `@` 자리만 바꿀 뿐 `@stdlib` 부재는 못 고친다 — 그래서
    #    `gen_world_interface.jl` 의 `using InteractiveUtils`(Task 2, D9 가 도입)가
    #    자식 프로세스에서 `ArgumentError: Package InteractiveUtils not found in current
    #    path` 로 죽는다(실측, 재현: `JULIA_LOAD_PATH="@:/tmp/x" julia +lts --project=.
    #    tools/gen_world_interface.jl` 로 격리 재현). Task 2 는 전체 `Pkg.test()` 를
    #    지시대로 돌리지 않아 이 결함이 그때부터 안 잡혔다. 고침: 자식 프로세스에서
    #    두 env var 를 지워 기본 LOAD_PATH(`@stdlib` 포함)로 돌아가게 한다.
    mktempdir() do dir
        out = joinpath(dir, "regen.json")
        cmd = `julia +lts --project=$(normpath(joinpath(@__DIR__, ".."))) $(normpath(joinpath(@__DIR__, "..", "tools", "gen_world_interface.jl"))) $(out)`
        env = copy(ENV)
        delete!(env, "JULIA_LOAD_PATH")
        delete!(env, "JULIA_PROJECT")
        run(setenv(cmd, env))
        @test read(out, String) == read(ART, String)
    end
end

@testset "(3) PlannerEnv 의 필드가 전부 실려 있다" begin
    j = JSON3.read(read(ART, String))
    t = only(filter(x -> x.name == "PlannerEnv", collect(j.types)))
    @test Set(String.([f.name for f in t.fields])) ==
          Set(String.(collect(fieldnames(CB.PlannerEnv))))
end

@testset "(4) 🔴 비공개 impl 은 실리지 않는다 (설계 D6)" begin
    # 사용자 결정: 표면은 `names(CB)` 그대로. 모델은 `release_pending_assignments!` 를
    # 모른다 — 그 능력을 처음부터 다시 써야 하는 것이 이 설계의 첫 측정 대상이다.
    j = JSON3.read(read(ART, String))
    ms = Set(String.([m.name for m in j.methods]))
    @test !("release_pending_assignments!" in ms)
    # 컨트롤러 판정(Task 3 범위 추가): export 목록을 편집하는 것이 D6 이 새는 정확한 경로이므로,
    # 감춘 다섯 전부를 여기서 단언한다 — 하나만 지키면 나머지 넷의 회귀를 못 잡는다.
    @test !("recover_stalled_teams!" in ms)
    @test !("resolve_schedule_wedge!" in ms)
    @test !("force_advance_stuck_carrier!" in ms)
    @test !("forbid_heavy_cargo!" in ms)
    @test "reform_stuck_teams!" in ms          # 빈-통과 방지: export 된 것은 실린다
end

@testset "(5) 🔴 D10: 무타입 Dict 두 개가 값 타입을 말한다" begin
    j = JSON3.read(read(ART, String))
    t = only(filter(x -> x.name == "PlannerEnv", collect(j.types)))
    ft = Dict(String(f.name) => String(f.type) for f in t.fields)
    # 🔴 이것이 없으면 모델은 `robot.charge` 를 지어낸다 (설계 §1.5)
    @test occursin("VelocityController", ft["agent_policies"])
    @test occursin("Bool", ft["agent_parent_build_step_active"])
    # 빈-통과 방지: 이미 타입이 실려 있던 필드는 그대로여야 한다
    @test occursin("Ball2", ft["staging_circles"])
    @test occursin("Float64", ft["staging_buffers"])
end

@testset "(6) 🔴 폐포가 폭발하지 않았다" begin
    j = JSON3.read(read(ART, String))
    @test 40 <= length(j.types) <= 120     # 실측 67. 서드파티 필터를 풀면 1,302 이상이다.
    @test !isempty(j.methods)
end

@testset "(7) 🔴 D12: env 밖 세계 상태가 실리고, 그 접근자는 실제로 부를 수 있다" begin
    j = JSON3.read(read(ART, String))
    @test haskey(j, :ambient) && !isempty(j.ambient)
    accs = Set(String[String(a.accessor) for a in j.ambient])
    @test "battery_report()" in accs
    # 🔴 산출물이 **부를 수 없는 이름을 광고하면 안 된다**. 접근자의 이름이 실제로
    #    export 표면에 있어야 한다 — 없으면 모델이 그것을 부르고 UndefVarError 로 죽는다.
    ms = Set(String[String(m.name) for m in j.methods])
    for a in j.ambient
        base = first(split(String(a.accessor), "("))
        @test base in ms
    end
end
end # module
