module WorldInterfaceClosure
using Test
using ConstructionBots
import JSON3
const CB = ConstructionBots
const ART = normpath(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "core",
                              "world_interface.json"))

@testset "(1) 폐포가 run 3 이 지어낸 타입들에 실제로 도달한다" begin
    j = JSON3.read(read(ART, String))
    names_in = Set(String[String(t.name) for t in j.types])
    # 🔴 run 3 은 `node.assigned_robot` 을 지어냈다. ScheduleNode 의 실제 필드는 (id, node, spec).
    @test "ScheduleNode" in names_in
    # 🔴 run 3 은 `robot.charge` 를 지어냈다. 값 타입은 VelocityController 이고 그런 필드가 없다.
    @test "VelocityController" in names_in
    @test "PathSpec" in names_in
    @test "AbstractID" in names_in
end

@testset "(2) 추상 타입은 필드가 아니라 subtypes 를 싣는다" begin
    # 🔴 `fieldnames(SceneTreeEdge)` 는 ArgumentError 를 **던진다**(실측).
    #    순진한 전이 전개는 생성기를 죽인다.
    j = JSON3.read(read(ART, String))
    e = only(filter(x -> x.name == "SceneTreeEdge", collect(j.types)))
    @test haskey(e, :subtypes) && !haskey(e, :fields)
    @test Set(String.(collect(e.subtypes))) == Set(["PermanentEdge", "TemporaryEdge"])
    # 빈-통과 방지: 구상 타입은 반대여야 한다
    s = only(filter(x -> x.name == "ScheduleNode", collect(j.types)))
    @test haskey(s, :fields) && !haskey(s, :subtypes)
    @test Set(String[String(f.name) for f in s.fields]) == Set(["id", "node", "spec"])
end

@testset "(3) 🔴 서드파티 타입은 절대 안 들어온다 — 폐포가 폭발한다" begin
    # 실측: 필터를 풀면 깊이 2 에서 1,302 타입, 깊이 3 에서 25,160 타입.
    j = JSON3.read(read(ART, String))
    ns = Set(String[String(t.name) for t in j.types])
    for gone in ("Dict", "Set", "SimpleDiGraph", "PriorityQueue", "Ball2")
        @test !(gone in ns)
    end
    @test 40 <= length(ns) <= 120   # 상한: 폭발 트립와이어. 실측 67(Task 1 이전 66 + VelocityController).
end

@testset "(4) 폐포는 이름으로 정렬돼 결정적이다" begin
    # 🔴 `subtypes` 의 반환 순서는 계약이 아니다. 정렬이 없으면 게이트 (2) 의 바이트
    #    비교가 실행마다 이유 없이 흔들린다 (`method_entries` 의 MergeSort 와 같은 논거).
    j = JSON3.read(read(ART, String))
    ns = String[String(t.name) for t in j.types]
    @test ns == sort(ns)
end

@testset "(5) 도달 경로 색인이 run 3 이 필요로 한 타입들을 짚는다" begin
    j = JSON3.read(read(ART, String))
    @test haskey(j, :access)
    acc = Dict(String(k) => String[String(x) for x in v] for (k, v) in pairs(j.access))
    @test any(p -> occursin("env.sched.nodes", p), acc["ScheduleNode"])
    @test any(p -> occursin("env.agent_policies", p), acc["VelocityController"])
    # 🔴 색인의 계약: **키가 있으면 경로가 있다.** 도달 못 하는 타입은 키 자체가 없다
    #    (`add!` 는 push 와 함께만 키를 만든다) — 빈 목록으로 실리면 렌더가 "경로가 있다"
    #    고 읽고 `missing` 주석을 안 붙인다. 이전 판의 `v isa Vector` 단언은 바로 윗줄의
    #    `String[...]` 내포가 값을 이미 Vector 로 짓기 때문에 **항진**이었다(리뷰 M1).
    @test all(!isempty, values(acc))
end

@testset "(6) 🔴 호출 가능성 분할 — PlannerEnv 메서드 23 중 23, 그중 세계 변경자 16" begin
    # ⚠️ 표제의 수는 전부 **오늘 잰 값**이다. 이전 판 표제의 "오늘 5 에서" 의 5 는 계획서·
    #    설계 어디에서도 재유도되지 않아 지웠다(리뷰 M3).
    j = JSON3.read(read(ART, String))
    ms = collect(j.methods)
    @test all(m -> haskey(m, :callable), ms)
    envms = [m for m in ms if occursin("PlannerEnv", String(m.signature))]
    @test length(envms) == 23                      # 실측
    ok = [m for m in envms if m.callable === true]
    @test length(ok) == 23                         # D9 의 씨앗 확장이 전부 연다
    bang = [m for m in ok if endswith(String(m.name), "!")]
    @test length(bang) == 16
    @test "apply_cmd!" in Set(String[String(m.name) for m in bang])
    @test "close_node!" in Set(String[String(m.name) for m in bang])
    # 🔴 I2: `Vararg{Any}` 는 `isa DataType` 가 false 라 `_arg_obtainable` 이 통째로
    #    떨어뜨렸다 — 그래서 **경로가 이미 있는** 기하 변경자가 "못 부른다" 쪽에 실렸다.
    #    이 다섯이 유일하게 Vararg 하나로만 막혀 있던 것들이다(실측).
    for (nm, sig) in (
            ("set_desired_global_transform!", "(g::ConstructionBots.GeomNode, args::Vararg{Any})"),
            ("set_desired_global_transform!", "(n::ConstructionBots.SceneNode, args::Vararg{Any})"),
            ("set_desired_global_transform!", "(n::ConstructionBots.TransformNode, t, args::Vararg{Any})"),
            ("set_desired_global_transform_without_affecting_children!",
             "(n::ConstructionBots.TransformNode, t, args::Vararg{Any})"),
            ("is_within_capture_distance",
             "(parent::ConstructionBots.SceneNode, child::ConstructionBots.SceneNode, args::Vararg{Any})"))
        m = only(filter(x -> String(x.name) == nm && String(x.signature) == sig, ms))
        @test m.callable === true
    end
    @test count(m -> m.callable === true, ms) == 186   # 실측. Vararg 고침 전에는 181
end
@testset "(7) 🔴 R11·R33 + 설계 §6.2: 경로는 접지 않고, 없는 것은 `missing` 으로 이름을 댄다" begin
    j = JSON3.read(read(ART, String))
    ms = collect(j.methods)
    @test all(m -> haskey(m, :missing), ms)

    # 🔴 R11 → R33. 이전 판은 인자당 `first(ps)` **하나**만 실었다 — `AbstractID` 의 9개
    #    경로 중 사전순 첫째 하나. R11 이 그것을 넷으로 올렸고, 판정 R33 이 **상한을 아예
    #    안 물리게** 했다(어느 경로가 더 정밀한지는 선언에서 유도할 수 없다 — 아홉 경로의
    #    선언된 산출 타입이 9/9 동일하다는 실측). 이제 인자 하나가 아홉을 다 본다.
    ag = only(filter(m -> String(m.name) == "asset_generation", ms))
    @test length(ag.argpaths) == 9                       # 인자 하나 × 경로 아홉 (안 자른다)
    @test any(p -> occursin("env.sched.vtx_ids", String(p)), ag.argpaths)
    rr = only(filter(m -> String(m.name) == "replace_robot!", ms))
    @test length(rr.argpaths) == 18                      # AbstractID 인자 둘 × 9

    # 🔴 설계 §6.2. 둘째 표제의 **모든** 항목은 무엇이 없는지를 말해야 한다.
    later = [m for m in ms if m.callable !== true]
    @test !isempty(later)
    @test all(m -> !isempty(m.missing), later)

    # 🔴 I1. 첫째 표제도 거짓말을 했다 — `callable=true` 인데 경로가 없는 인자를 가진 항목
    #    32건이 "every argument is obtainable" 아래 앉아 있었다. 같은 `missing` 채널로 갚는다.
    ap = only(filter(m -> String(m.name) == "apply_cmd!" &&
                          occursin("DepositCargo", String(m.signature)), ms))
    @test ap.callable === true
    @test Set(String.(collect(ap.missing))) == Set(["DepositCargo", "Twist"])
    @test count(m -> m.callable === true && !isempty(m.missing), ms) == 32   # 실측
    # 빈-통과 방지: 경로가 다 있는 항목은 missing 이 비어야 한다
    cn = only(filter(m -> String(m.name) == "close_node!" &&
                          occursin("ScheduleNode", String(m.signature)), ms))
    @test isempty(cn.missing) && !isempty(cn.argpaths)
end
@testset "(8) 🔴 R33: 인자당 경로는 **자르지 않는다** — 정당화할 수 없는 순위를 프롬프트가 암시하지 않는다" begin
    # ── 이 testset 이 지키는 것과 지키지 **않는** 것 (리뷰 I3 를 정직하게 갚는다) ──────────
    #
    #  지킨다 (전부 산출물만 읽어서 판정된다):
    #    (a) `access` 색인이 아홉을 다 들고 있다,
    #    (b) 🔴 **어떤 인자의 경로 목록도 잘리지 않는다** — 렌더에 실린 경로 집합이 색인의
    #        경로 집합과 **같다**. `_MAX_PATHS` 는 이제 무음 절단기가 아니라 **트립와이어**다:
    #        상한이 물면 이 단언이 빨개진다(조용히 사전순으로 넷을 고르는 대신),
    #    (c) 목록이 **사전순**이다 — 즉 위치가 순위를 뜻하지 않는다,
    #    (d) 설계 §6.2 가 이름 댄 두 경로와 `restage_assembly!` 의 전제조건 집합이 실제로 실린다.
    #
    #  🔴 지키지 **못한다**: "1위가 실제로 로봇 id 를 준다" 같은 **실행시각 조성**은 이 파일이
    #     `env` 를 안 만들므로 잴 수 없다. 그것은 정적 성질이 아니다 — wave-b-review 가 살아
    #     있는 `PlannerEnv` 에서 한 번 쟀고(`keys(env.agent_policies)` = {BotID 18,
    #     TemplatedID{TransportUnitNode} 27}), 그 조성은 보드·함대 크기에 따라 움직인다.
    #     예전 판의 주석은 "기전이 아니라 성질을 고정한다" 고 적어 놓고 문자열 하나
    #     (`first(ids) == "keys(env.agent_policies)"`)를 단언했다 — 그 문장이 거짓이었다.
    #
    # ── 왜 더 나은 순위가 아니라 **컷 제거**인가 (판정 R33) ──────────────────────────────
    #  R21 은 "정밀한 출처를 남기라" 였고 wave B 는 그것을 `Dict` 의 **선언된 값 타입**으로
    #  구현했다(CB 소유면 "키가 역할을 이름한다"). 그 규칙은 오늘 데이터에서 **반상관**이다:
    #  `agent_policies`(값=`VelocityController`, 1등급) 키는 40% 만 로봇이고,
    #  `staging_circles`(값=`Ball2`, 최하등급) 키는 **8/8 이 `AssemblyID`** 다.
    #  그리고 정적으로는 가를 수가 없다 — 실측: `AbstractID` 를 내는 아홉 경로의 **선언된
    #  산출 타입은 9/9 가 `ConstructionBots.AbstractID` 하나**다(distinct = 1). 선언에는
    #  정밀도 정보가 0비트 들어 있다. 그래서 순위를 매기는 대신 **아무것도 안 자른다.**
    j = JSON3.read(read(ART, String))
    ms = collect(j.methods)
    acc = Dict(String(k) => String[String(x) for x in v] for (k, v) in pairs(j.access))
    ids = acc["AbstractID"]

    # (a) 색인은 아홉을 다 들고 있다.
    @test length(ids) == 9
    # (c) 사전순이다 — 위치가 순위가 아니다. (옛 판의 `ids != sort(ids)` 는 정확히 반대를
    #     요구했고, 그것은 "정밀도순" 이라는 정당화 못 하는 주장의 대리였다.)
    @test ids == sort(ids)

    # (b) 🔴 어떤 메서드의 어떤 인자도 잘리지 않는다. `argpaths` 는 `"<인자이름> <- <경로>"`
    #     줄이므로 인자 이름으로 묶으면 한 묶음이 곧 한 인자의 경로 집합이다. 그 집합은
    #     반드시 **어떤 타입의 색인 전체**와 같아야 한다 — 부분집합이면 상한이 문 것이다.
    full = Set(Set(v) for v in values(acc))
    ntrunc = 0
    for m in ms
        isempty(m.argpaths) && continue
        byarg = Dict{String,Set{String}}()
        for line in m.argpaths
            s = String(line); i = findfirst(" <- ", s)
            nm = s[1:first(i)-1]; pt = s[last(i)+1:end]
            push!(get!(byarg, nm, Set{String}()), pt)
        end
        for (_, ps) in byarg
            ps in full || (ntrunc += 1)
        end
    end
    @test ntrunc == 0
    # 빈-통과 방지: 위 루프가 실제로 무언가를 봤다.
    @test count(m -> !isempty(m.argpaths), ms) > 0

    # (d) `AbstractID` 인자는 아홉을 다 본다 — 예전엔 넷이었다.
    sb = only(filter(x -> String(x.name) == "swap_battery!", ms))
    @test length(sb.argpaths) == 9
    _rhs(line) = (s = String(line); i = findfirst(" <- ", s); s[last(i)+1:end])
    sbp = Set(String[_rhs(p) for p in sb.argpaths])
    @test sbp == Set(ids)
    # 🔴 설계 §6.2 가 `swap_battery!` 의 예시로 직접 이름 댄 두 경로가 **둘 다** 있다
    #    (리뷰 I4: 상한이 4 였을 때 `env.sched.vtx_ids[i]` 는 마지막 칸에 겨우 걸려 있었다).
    @test "env.sched.vtx_ids[i]" in sbp
    @test "keys(env.agent_policies)" in sbp
    # 🔴 리뷰 I1 회귀: `keys(env.staging_circles)` 는 `restage_assembly!` 의 **전제조건 집합**
    #    이다(`haskey(env.staging_circles, assembly_id) || return (status = :no_staging, …)`,
    #    src/respec/restage_zone.jl). 등급 규칙은 그것을 컷 아래로 보냈다 — 값 타입이
    #    서드파티(`LazySets.Ball2`)라서. 실측하면 그 키집합은 8/8 이 `AssemblyID` 다.
    for nm in ("restage_assembly!", "find_clear_staging_center")
        m = only(filter(x -> String(x.name) == nm, ms))
        @test any(p -> occursin("keys(env.staging_circles)", String(p)), m.argpaths)
    end
    # 로봇 id 를 요구하는 메서드들도 그 출처를 여전히 본다.
    for nm in ("swap_battery!", "hot_swap_robot!", "dispatch_battery_courier!")
        m = only(filter(x -> String(x.name) == nm, ms))
        @test any(p -> occursin("keys(env.agent_policies)", String(p)), m.argpaths)
    end
    # 빈-통과 방지: 옛 판이 "잘려 나갔다" 의 증거로 쓰던 `vtx_map` 둘이 이제 **실린다**.
    #    (옛 단언 `!any(occursin("vtx_map", …))` 은 등급을 어떻게 뒤집어도 참이라 사실상
    #     항진이었다 — 리뷰 m-3.)
    @test count(p -> occursin("vtx_map", String(p)), sb.argpaths) == 2
end
end # module
