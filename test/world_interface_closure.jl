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
@testset "(7) 🔴 R11 + 설계 §6.2: 경로는 접지 않고, 없는 것은 `missing` 으로 이름을 댄다" begin
    j = JSON3.read(read(ART, String))
    ms = collect(j.methods)
    @test all(m -> haskey(m, :missing), ms)

    # 🔴 R11. 이전 판은 인자당 `first(ps)` **하나**만 실었다 — `AbstractID` 의 9개 경로 중
    #    사전순 첫째 하나. 그 컬렉션의 실측 조성은 {TemplatedID 28, ObjectID 20, BotID 18,
    #    AssemblyID 8} 이라 로봇 id 를 요구하는 메서드가 로봇을 받을 확률이 18/74 였다.
    #    이제 인자당 최대 4개를 싣는다 — 설계 §6.2 의 예시 경로가 그 안에 있어야 한다.
    ag = only(filter(m -> String(m.name) == "asset_generation", ms))
    @test length(ag.argpaths) == 4                       # 인자 하나 × 최대 4
    @test any(p -> occursin("env.sched.vtx_ids", String(p)), ag.argpaths)
    rr = only(filter(m -> String(m.name) == "replace_robot!", ms))
    @test length(rr.argpaths) == 8                       # AbstractID 인자 둘 × 4

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
@testset "(8) 🔴 N2: 인자당 상한은 사전순이 아니라 **정밀도순**으로 자른다" begin
    # R11 이 `first(ps)` 를 최대 4개로 바꿨지만 **어느 4개인가** 는 여전히 사전순이었다.
    # 실측(이 산출물, R11 이후): `swap_battery!(env, role::AbstractID)` 가 받은 넷은
    # {scene_tree.vtx_ids, sched.vtx_ids, active_build_steps, agent_parent_build_step_active}
    # 이고, `keys(env.agent_policies)` — env 위에서 **로봇 id 만** 담긴 유일한 컬렉션 —
    # 은 사전순 5번째라 잘려 나갔다. R11 의 논거("모델이 고를 수 있는 선택지")는
    # 고를 것 중에 답이 있을 때만 성립한다.
    #
    # 🔴 여기서 고정하는 것은 기전이 아니라 **성질**이다: 어떤 타입의 가장 정밀한 원은
    #    상한에 잘려서는 안 된다. 정밀함의 정적 정의는 생성기가 정한다(진실원 하나) —
    #    이 시험은 그 정의가 산출물에서 실제로 지켜졌는지만 본다.
    j = JSON3.read(read(ART, String))
    ms = collect(j.methods)
    acc = Dict(String(k) => String[String(x) for x in v] for (k, v) in pairs(j.access))
    ids = acc["AbstractID"]

    # 색인 자체는 아무것도 안 잃는다 — 상한은 **렌더에만** 건다.
    @test length(ids) == 9
    # 정밀원이 첫째다. `Dict{AbstractID,VelocityController}` 의 키집합은 "정책을 가진
    # 것들" = 에이전트(로봇)다. 나머지 여덟은 전체 모집단(vtx_ids)이거나 값 타입이
    # 스칼라/서드파티인 조회표(vtx_map·staging_*·..._active)라 무엇의 id 인지 말하지 않는다.
    @test first(ids) == "keys(env.agent_policies)"
    # 🔴 음성 대조: 순서가 진짜로 사전순에서 벗어났다(안 그러면 위 단언이 우연이다).
    @test ids != sort(ids)

    # 로봇 id 를 요구하는 메서드들이 로봇 id 원을 **본다**.
    for nm in ("swap_battery!", "hot_swap_robot!", "dispatch_battery_courier!")
        m = only(filter(x -> String(x.name) == nm, ms))
        @test any(p -> occursin("keys(env.agent_policies)", String(p)), m.argpaths)
    end

    # 빈-통과 방지 ①: 상한은 여전히 문다 — 아홉 중 넷만 실린다.
    sb = only(filter(x -> String(x.name) == "swap_battery!", ms))
    @test length(sb.argpaths) == 4
    # 빈-통과 방지 ②: 잘려 나간 쪽은 값 타입이 세계 타입이 아닌 조회표다.
    @test !any(p -> occursin("vtx_map", String(p)), sb.argpaths)
end
end # module
