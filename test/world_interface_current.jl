module WorldInterfaceCurrent
using Test
using ConstructionBots
import JSON3
const CB = ConstructionBots
const ART = normpath(joinpath(@__DIR__, "..", "src", "decision", "core",
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

@testset "(4) 🔴 비공개 impl 은 실리지 않는다 — 감춘 것은 이제 **셋**이다 (설계 D6 · S4 · S5)" begin
    # 사용자 결정: 표면은 `names(CB)` 그대로. 감춘 능력을 모델이 처음부터 다시 써야 하는
    # 것이 이 설계의 첫 측정 대상이다.
    # 🔴 S4 (2026-09-04): `release_pending_assignments!` 가 다섯에서 빠졌다 — 세계 delta 5축이
    #    전부 0 이었고 모델이 재배정 로직을 **주석으로** 썼기 때문이다.
    # 🔴 S5 (2026-09-05): `forbid_heavy_cargo!` 가 넷에서 빠졌다. 그 재배정 동사의 오라클
    #    측정이 끝났고 답은 **release 가 빌드를 교착시킨다** 였다(진행 중 운반을 뜯는다).
    #    다음 가설은 "미래 배정을 **제약**하면 아무것도 안 뜯고 같은 목적을 이룬다" 이고,
    #    그 동사를 광고하는 것이 이 태스크다. 남은 셋은 그대로 감춘다.
    j = JSON3.read(read(ART, String))
    ms = Set(String.([m.name for m in j.methods]))
    # 컨트롤러 판정(Task 3 범위 추가): export 목록을 편집하는 것이 D6 이 새는 정확한 경로이므로,
    # 감춘 셋 전부를 여기서 단언한다 — 하나만 지키면 나머지 둘의 회귀를 못 잡는다.
    @test !("recover_stalled_teams!" in ms)
    @test !("resolve_schedule_wedge!" in ms)
    @test !("force_advance_stuck_carrier!" in ms)
    @test "reform_stuck_teams!" in ms          # 빈-통과 방지: export 된 것은 실린다
    # 🔴 S4·S5 의 양성 단언. 위 감춤 게이트만 남기면 "넷을 셋으로 줄였다" 가 **빈 통과**가
    #    된다 — 광고가 실제로 산출물에 도착했는지는 아무도 안 본다.
    @test "release_pending_assignments!" in ms
    @test "forbid_heavy_cargo!" in ms
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
        # 🔴 S3 (2026-09-04). 네 런 연속 식별자 환각(run4: `AbstractID` 자리에 bare `Int64`)의
        #    처방이 이 항목이다. 그리고 **반환 타입 문자열이 처방의 전부다** — 그것이 `Any` 로
        #    넓어지면 광고는 남고 효과만 조용히 사라진다. 그래서 이름과 타입을 둘 다 단언한다.
        @test "ood_event_target()" in accs
        ot = only(filter(a -> String(a.accessor) == "ood_event_target()", collect(j.ambient)))
        rs = String(get(ot, :returns, ""))
        @test occursin("BotID", rs)      # 진짜 id 타입이 프롬프트에 실린다
        @test occursin("Nothing", rs)    # 3-상태: "기록 없음" 이 유효한 id 와 안 섞인다
        @test rs != "Any"
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
@testset "(10) 🔴 키워드 인자에 타입이 실린다 — 유료 런 여섯이 죽은 자리다" begin
    # 🔴 왜 이 게이트가 (2) 와 별개인가. (2) 는 "산출물이 생성기와 일치한다" 만 잰다 —
    #    `_kwarg_types` 를 통째로 지워도 산출물을 같이 재생성하면 **초록으로 남는다**.
    #    그러면 프롬프트에서 키워드 타입이 조용히 사라지고, 그 부재가 정확히 여섯 런을
    #    죽인 조건이다(환각이 전부 키워드 자리에서 났다: `agent` 에 bare `Int64`,
    #    `zone_keys` 에 좌표 튜플, dict 키에 `"R1"`). 그래서 **부재를 직접** 잰다.
    #    (7) 이 앰비언트의 `returns` 문자열에 대해 하는 것과 같은 모양이다.
    j = JSON3.read(read(ART, String))
    sigs = Dict(String(m.name) => String(m.signature) for m in j.methods)
    # 🔴 양성 단언 1 — id 를 나르는 키워드. run4/run5 는 `AbstractID` 자리에 각각
    #    bare `Int64` 와 `"R1"` 을 넣어 죽었다. 이 한 줄이 그 자리를 광고한다.
    @test occursin("target::Union{Nothing, ConstructionBots.BotID", sigs["fault_robot!"])
    # 🔴 양성 단언 2 — 삼상 키워드. `Nothing` 이 유효값과 안 섞인다는 것이 타입에 있다.
    @test occursin("agent::Union{Nothing, AbstractString}",
                   sigs["release_pending_assignments!"])
    # 🔴 양성 단언 3 — 평범한 스칼라 키워드도 실린다(빈-통과 방지: 위 둘만 특별대우한
    #    하드코딩이 아니라 유도가 돌고 있다).
    @test occursin("resume::Bool", sigs["restage_all_blocked!"])
    @test occursin("resume::Bool", sigs["translate_whole_build!"])
    # 🔴 삼상 규율의 양성 대조. 유도가 안 되는 키워드(선언 타입이 없다 = `Any`)는
    #    **오늘과 같이 이름만** 실려야 한다 — `Any` 를 싣는 것은 위치인자와 같은 이유로
    #    정보 0이고, 지어낸 타입은 이 파일이 없애려는 실패 그 자체다. 이 단언이 없으면
    #    "유도가 전부에 붙었다"(= 어딘가에서 `Any` 를 싣고 있다)를 아무도 못 본다.
    #    ⚠️ 함수를 이름으로 고정하지 않는다 — 어느 시그니처를 좁히는 것은 이 게이트가
    #    막을 결정이 아니다(그것은 그 함수 쪽의 판정이고, (2) 가 산출물 갱신을 지킨다).
    bare = [n for (n, s) in sigs if occursin(";", s) &&
            any(t -> !occursin("::", t),
                split(strip(last(split(s, ";")), [' ', ')']), ","))]
    @test !isempty(bare)
    @test !any(s -> occursin("::Any", s), values(sigs))
end

@testset "(11) 🔴 메서드에 반환 모양이 실린다 — 유료 런 6 이 자기신고로 초록이 된 자리다" begin
    # 🔴 왜 이 게이트가 (2) 와 별개인가. (2) 는 "산출물이 생성기와 일치한다" 만 잰다 —
    #    `_method_returns` 를 통째로 지우고 산출물을 같이 재생성하면 **초록으로 남는다**.
    #    (10) 을 만들 때 실측한 그 결함이다. 그래서 여기서 **부재를 직접** 잰다.
    #    실패의 모양: 런 6 에서 모델이 tier-1 동사를 부르고 **그 반환을 안 보고** 무조건
    #    `:success` 를 냈다. 하네스는 모델의 심볼을 읽으므로 L2b 가 자기신고로 초록이 됐고
    #    `world_delta_body` 는 6축 전부 0, 빌드는 PROJECT INCOMPLETE 로 끝났다.
    j = JSON3.read(read(ART, String))
    ms = collect(j.methods)
    rets = Dict{String,String}()
    for m in ms
        haskey(m, :returns) && (rets[String(m.name)] = String(m.returns))
    end

    # 🔴 양성 단언 1 — tier-1 동사의 **상태 반환**이 보인다. 이것이 없으면 "반환을 확인한다"
    #    가 유도 불가능하다(프롬프트 어디에도 그런 것이 있다는 사실이 없다).
    # 🔴 리뷰 m2 의 모양: 첨자 대신 `get`. 키가 사라지면 KeyError 가 Fail 이 아니라
    #    **Error** 로 세어져 스위트의 바이트 고정 기준 "1 errored (Gurobi)" 를 흔든다 —
    #    즉 회귀가 환경 문제로 오독된다.
    _ret(k) = get(rets, k, "")
    @test occursin("status::Symbol", _ret("restage_all_blocked!"))
    # 🔴 양성 단언 2 — 간선 목록 반환. 재배정 동사가 무엇을 돌려주는지가 타입에 있다.
    @test _ret("release_pending_assignments!") == "Vector{Tuple{Int64, Int64}}"
    # 🔴 양성 단언 3 — `zone_keys` 의 키 타입을 나르는 두 접근자. 좌표 튜플(런 6)이 아니라
    #    `Symbol` 이라는 사실이 이 두 줄에만 실린다. `restriction_zones` 쪽이 직접적이다.
    @test occursin("Dict{Symbol,", _ret("restriction_zones"))
    @test occursin("Symbol", _ret("active_restriction_zones"))
    # 🔴 빈-통과 방지: 위 넷만 특별대우한 하드코딩이 아니라 유도가 213 전체에 돌고 있다.
    #    실측 197/213 메서드. 하한은 그보다 낮게 잡아 무해한 시그니처 변화로는 안 흔들리게
    #    한다. ⚠️ `rets` 는 **이름**으로 색인되므로 개수 단언은 `ms` 에서 직접 센다
    #    (이름이 같은 메서드가 여럿이라 148 로 접힌다 — 실측).
    @test count(m -> haskey(m, :returns), ms) >= 150

    # ── 삼상 규율 (판정 R-RET1/R-RET2/R-RET3). 세 상태를 **서로 다른 단언**으로 고정한다.
    # R-RET1: 유도됐는데 `Any` 인 것은 **정직하게 `"Any"` 로 실린다**(실측 38건). 이것을
    #   빼면 그 순간 "유도했더니 Any" 와 "유도 못 했다" 가 산출물에서 구별 불가가 되고,
    #   필드의 부재가 아무 정보도 안 나르게 된다.
    @test any(v -> v == "Any", values(rets))
    # R-RET2: 유도 불가는 **키 자체가 없다**(실측 16건 = 다중 매치 13 + `Union{}` 3).
    #   그리고 빈 문자열·`"unknown"` 같은 자리표시자는 어디에도 없다 — 모델은 그것을
    #   타입으로 읽는다.
    @test any(m -> !haskey(m, :returns), ms)
    @test !any(isempty, values(rets))
    @test !any(v -> occursin("unknown", lowercase(v)), values(rets))
    # R-RET3: **절단이 없다.** 넓은 것을 잘라 적으면 요약이 아니라 진실보다 좁게 읽히는
    #   거짓이다. 생략 표식이 하나도 없어야 하고, 가장 긴 것(실측 `zone_diagnosis`, 708자)이
    #   통째로 실려 있어야 한다.
    @test !any(v -> occursin("…", v) || occursin("...", v), values(rets))
    @test maximum(length, values(rets); init = 0) > 600

    # 🔴 실험적 타당성의 게이트. 이 태스크가 프롬프트에 더한 것은 **기계가 유도한 타입뿐**
    #    이어야 한다 — 어떤 동사 이름도, 어떤 산문도, "무엇을 부르라" 도 실리면 안 된다.
    #    광고가 답을 흘리면 그 뒤의 측정은 모델에 대한 사실이 아니게 된다.
    #    실측: 새 텍스트에 `!` 가 0건이고, export 된 Function 이름 150개 중 어느 것도
    #    반환 문자열 197개 안에 부분문자열로조차 안 나타난다.
    @test !any(v -> occursin("!", v), values(rets))
    verbs = String[String(n) for n in names(CB) if isdefined(CB, n) && getfield(CB, n) isa Function]
    @test !isempty(verbs)                       # 빈-통과 방지
    @test !any(v -> any(w -> occursin(w, v), verbs), values(rets))
end
end # module
