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
    #    `JULIA_LOAD_PATH` 를 지워 기본 LOAD_PATH(`@stdlib` 포함)로 돌아가게 한다.
    #    ⚠️ 인과는 `JULIA_LOAD_PATH` **하나**다. 이전 판은 `JULIA_PROJECT` 도 같이 지우고
    #    주석에 "두 env var" 라 적었는데, 자식이 항상 넘기는 `--project=` 플래그가 어느
    #    조합에서도 `JULIA_PROJECT` 를 이긴다(실측). 없는 기전을 찾게 만드는 죽은 줄이라 뺐다.
    mktempdir() do dir
        out = joinpath(dir, "regen.json")
        cmd = `julia +lts --project=$(normpath(joinpath(@__DIR__, ".."))) $(normpath(joinpath(@__DIR__, "..", "tools", "gen_world_interface.jl"))) $(out)`
        env = copy(ENV)
        delete!(env, "JULIA_LOAD_PATH")
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

@testset "(4) 🔴 비공개 impl 은 실리지 않는다 — 감춘 것은 이제 **넷**이다 (설계 D6 · S4)" begin
    # 사용자 결정: 표면은 `names(CB)` 그대로. 감춘 능력을 모델이 처음부터 다시 써야 하는
    # 것이 이 설계의 첫 측정 대상이다.
    # 🔴 S4 (2026-09-04): `release_pending_assignments!` 는 **감춘 다섯에서 빠졌다**.
    #    측정한 것은 "모델이 재배정 동사 없이 세계를 못 바꾼다" 였고(세계 delta 5축 전부 0),
    #    모델은 재배정 로직을 **주석으로** 썼다. 그 동사를 광고 목록에 넣는 것이 이 태스크다.
    #    남은 넷은 그대로 감춘다.
    j = JSON3.read(read(ART, String))
    ms = Set(String.([m.name for m in j.methods]))
    # 컨트롤러 판정(Task 3 범위 추가): export 목록을 편집하는 것이 D6 이 새는 정확한 경로이므로,
    # 감춘 넷 전부를 여기서 단언한다 — 하나만 지키면 나머지 셋의 회귀를 못 잡는다.
    @test !("recover_stalled_teams!" in ms)
    @test !("resolve_schedule_wedge!" in ms)
    @test !("force_advance_stuck_carrier!" in ms)
    @test !("forbid_heavy_cargo!" in ms)
    @test "reform_stuck_teams!" in ms          # 빈-통과 방지: export 된 것은 실린다
    # 🔴 S4 의 양성 단언. 위 감춤 게이트만 남기면 "다섯을 넷으로 줄였다" 가 **빈 통과**가
    #    된다 — 광고가 실제로 산출물에 도착했는지는 아무도 안 본다.
    @test "release_pending_assignments!" in ms
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
    # ⚠️ 이 게이트가 증명하는 것은 **산출물↔산출물 자기일관성**이다 — `ambient` 와
    #    `methods` 가 **같은 생성기 실행**에서 나오기 때문이다. 집행 프로세스에서의
    #    도달성은 증명하지 않는다(리뷰 I5); 그것은 아래 (8) 이 따로 지킨다.
    j = JSON3.read(read(ART, String))
    @test haskey(j, :ambient)
    # 🔴 리뷰 m2: 아래를 `@test` **밖에서** 던지게 두면(예전 판) 키가 없을 때 KeyError 가
    #    Fail 이 아니라 **Error** 로 세어져 스위트의 바이트 고정 기준 "1 errored (Gurobi)"
    #    가 "2 errored" 가 된다 — 환경 문제로 오독되는 모양이다.
    if haskey(j, :ambient)
        @test !isempty(j.ambient)
        accs = Set(String[String(a.accessor) for a in j.ambient])
        @test "battery_report()" in accs
        # 🔴 산출물이 **부를 수 없는 이름을 광고하면 안 된다**. 접근자의 이름이 실제로
        #    export 표면에 있어야 한다 — 없으면 모델이 그것을 부르고 UndefVarError 로 죽는다.
        ms = Set(String[String(m.name) for m in j.methods])
        for a in j.ambient
            base = first(split(String(a.accessor), "("))
            @test base in ms
        end
        # 🔴 I4. 전제조건이 빠진 광고는 **모델이 못 지킨 것을 모델 탓으로** 기록하게 만든다.
        #    실측: `BATTERY_FLEET[] === nothing`(배터리 회계는 opt-in 이라 이것이 기본값)
        #    에서 `battery_report()` 는 `MethodError: no method matching
        #    battery_report(::Nothing)` 를 던진다. 프로덕션 호출자 둘이 전부 try/catch 로
        #    감싸는 이유가 그것이고, 그 사실이 프롬프트에는 한 글자도 없었다.
        for a in j.ambient
            @test haskey(a, :precondition) && !isempty(String(a.precondition))
        end
        bf = only(filter(a -> String(a.accessor) == "battery_report()", collect(j.ambient)))
        @test occursin("BATTERY_FLEET", String(get(bf, :precondition, "")))
    end
end

@testset "(8) 🔴 I5: 집행 프로세스가 그 접근자를 실제로 볼 수 있다" begin
    # 🔴 (7) 이 증명하지 **못하는** 것을 여기서 증명한다. 주조 body 는 `Core.eval` 로 CB 에
    #    심겨(`src/respec/minted_registration.jl`) `tools/monitor/*.jl` 이 만든 프로세스에서
    #    돈다. 그 프로세스가 navigator 를 include 하지 않거나 `enact.jl` **뒤에** 하면
    #    `battery_report` 는 그 세계에 없고 body 는 UndefVarError 로 죽는데 — (7) 은 초록으로
    #    남는다(실측: 이 include 를 고정하는 시험이 레포에 하나도 없었다).
    #    두 스크립트는 최상위 부작용이 있어 include 할 수 없으므로(runtests.jl:254) 텍스트로
    #    고정한다. 이 단언이 곧 "주석이 아니라 게이트" 다.
    navpat = "CB.include(joinpath(pkgdir(CB), \"src\", \"navigator\", \"navigator.jl\"))"
    enapat = "include(joinpath(@__DIR__, \"enact.jl\"))"
    for f in ("render_demo.jl", "run_demo.jl")
        src = read(joinpath(@__DIR__, "..", "tools", "monitor", f), String)
        nav = findfirst(navpat, src)
        ena = findfirst(enapat, src)
        @test nav !== nothing
        @test ena !== nothing
        @test !(nav === nothing || ena === nothing) && first(nav) < first(ena)
    end
end

@testset "(9) 🔴 m4: export 표면에 정의 없는 이름은 battery_report 하나뿐이다" begin
    # D12 가 `battery_report` 를 export 하면서 이 패키지의 첫 **exported-but-undefined**
    # 이름이 생겼다(실측: 그 전에는 공집합). 정당한 예외다 — navigator 층은 런타임
    # `include` 라서 `using ConstructionBots` 만으로는 정의되지 않는다. 정당한 예외가
    # **하나뿐**이라는 것이 계약이고, export 줄의 주석이 아니라 이 단언이 그것을 지킨다.
    # ⚠️ 부분집합인 이유: 앞선 시험이 navigator 를 이미 include 했으면 좌변이 공집합이 된다.
    undefd = Symbol[n for n in names(CB) if !isdefined(CB, n)]
    @test issubset(Set(undefd), Set([:battery_report]))
end
end # module
