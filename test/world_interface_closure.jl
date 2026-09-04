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
end # module
