# test/abstractid_content_hash.jl — AbstractID 의 내용 기반 해시 (2026-08-24)
#   julia +lts --project=. test/abstractid_content_hash.jl
#
# 이 시험이 지키는 계약 (근거: .superpowers/sdd/2026-08-23-measured-smdp/repro-root-cause.md):
#   Julia 기본 해시는 `hash(x,h) = hash_uint(3h - objectid(x))` 이고 불변 구조체의
#   `objectid` 하위 32비트는 타입 해시(`jl_type_hash`)에서 온다. `ConstructionBots` 의
#   프리컴파일은 바이트 재현되지 않아 그 타입 해시가 **빌드마다 다르다** ⟹ ID 를 키로 쓰는
#   모든 Dict/Set 의 순회 순서가 빌드마다 달라지고, 같은 시드가 다른 세계를 냈다.
#   `src/graph_utils_essentials.jl` 의 `Base.hash(::AbstractID, ::UInt)` 가 그것을 끊는다.
#
# 🔴 §3 의 리터럴이 이 시험의 핵심이다 — `objectid`/`hash(::Type)`/`hash(::Symbol)` 이
#    다시 들어오면 새 프로세스에서 값이 달라져 여기서 죽는다.
using ConstructionBots
const CB = ConstructionBots
using Test

const BOT1 = CB.BotID{CB.DeliveryBot}
const TID1 = CB.TemplatedID{CB.TransportUnitNode}

@testset "§1 내용이 같으면 해시도 같다 (isequal ⟹ hash)" begin
    for T in (CB.ObjectID, CB.AssemblyID, CB.LocationID, CB.ActionID,
              CB.OperationID, CB.AgentID, CB.VtxID, CB.TransformNodeID,
              CB.GeomID, CB.BuildStepID, BOT1)
        for i in (-1, 0, 1, 7, 12345)
            a, b = T(i), T(i)
            @test isequal(a, b)
            @test hash(a) == hash(b)
            @test hash(a, UInt(17)) == hash(b, UInt(17))
        end
    end
    @test hash(TID1(3)) == hash(TID1(3))
end

@testset "§2 서로 다른 ID 타입은 같은 번호라도 충돌하지 않는다" begin
    types = (CB.ObjectID, CB.AssemblyID, CB.LocationID, CB.ActionID,
             CB.OperationID, CB.AgentID, CB.VtxID, CB.TransformNodeID,
             CB.GeomID, CB.BuildStepID, CB.SubModelPlanID, CB.SubFileRefID, BOT1)
    for i in (1, 2, 42)
        hs = [hash(T(i)) for T in types]
        @test length(unique(hs)) == length(types)          # 전부 다른 해시
        @test !isequal(CB.ObjectID(i), CB.AssemblyID(i))   # 키로서도 다르다
    end
    # 같은 Dict 안에서 실제로 별개 키로 산다 (오늘의 동작을 보존한다는 증명)
    d = Dict{CB.AbstractID,Symbol}(CB.ObjectID(1) => :obj, CB.AssemblyID(1) => :asm)
    @test length(d) == 2
    @test d[CB.ObjectID(1)] === :obj
    @test d[CB.AssemblyID(1)] === :asm
    # 매개변수도 내용으로 구분된다
    @test CB.id_type_tag(BOT1) != CB.id_type_tag(CB.BotID)
    @test hash(TID1(1)) != hash(CB.ObjectID(1))
end

@testset "§3 🔴 새 프로세스에서 **같은 리터럴 값** 이어야 한다 (재발 감지기)" begin
    # 타입 태그는 문맥 독립이어야 한다 — `string(T)`/`show` 는 모듈 접두사가 붙었다 말았다 한다.
    @test CB.id_type_tag(CB.ObjectID) == "ObjectID"
    @test CB.id_type_tag(CB.AssemblyID) == "AssemblyID"
    @test CB.id_type_tag(BOT1) == "BotID{DeliveryBot}"

    # 태그 시드 (= hash(태그문자열))
    @test CB.id_type_seed(CB.ObjectID)   === 0x9baebc9708c33bec
    @test CB.id_type_seed(CB.AssemblyID) === 0x33f2a978796abb61
    @test CB.id_type_seed(BOT1)          === 0x916916de93d421c7
    @test CB.id_type_seed(CB.LocationID) === 0x64527c4961fd4a9b
    @test CB.id_type_seed(CB.VtxID)      === 0xee7832ccbe31791c
    @test CB.id_type_seed(CB.ActionID)   === 0x3c52e3bc50809fbf

    # ID 값의 해시
    @test hash(CB.ObjectID(1))   === 0x93832cebf2aa3fe2
    @test hash(CB.ObjectID(7))   === 0xba42fd46c029e077
    @test hash(CB.AssemblyID(1)) === 0x0e9fdb087c3fdb9c
    @test hash(BOT1(1))          === 0xa59069904927a1d7
    @test hash(CB.LocationID(1)) === 0xee3be24347880d1a
    @test hash(TID1(1))          === 0x7e819a5088e1aaa6
end

@testset "§4 Dict 순회 순서가 빌드에 무관하다 (결함 자체의 회귀 가드)" begin
    d = Dict{CB.AbstractID,Int}()
    for i in 1:20; d[CB.ObjectID(i)] = i; end
    for i in 1:8;  d[CB.AssemblyID(i)] = i; end
    order = join([string(CB.id_type_tag(typeof(k)), "(", k.id, ")") for k in keys(d)], ",")
    @test order == "AssemblyID(2),ObjectID(4),ObjectID(13),ObjectID(15),ObjectID(2)," *
                   "ObjectID(10),ObjectID(18),AssemblyID(5),ObjectID(5),ObjectID(16)," *
                   "ObjectID(20),AssemblyID(8),ObjectID(12),AssemblyID(1),ObjectID(8)," *
                   "ObjectID(17),AssemblyID(6),ObjectID(1),ObjectID(19),ObjectID(6)," *
                   "ObjectID(11),ObjectID(9),AssemblyID(3),ObjectID(14),ObjectID(3)," *
                   "AssemblyID(7),ObjectID(7),AssemblyID(4)"
end

@testset "§5 음성 대조: 해시가 objectid 를 타고 있지 않다" begin
    # 기본 구현이었다면 이 값이 나왔을 것이다. 같으면 처방이 안 걸린 것이다.
    default_hash(x) = Base.hash_uint(3 * zero(UInt) - objectid(x))
    @test hash(CB.ObjectID(1)) != default_hash(CB.ObjectID(1))
    @test hash(CB.AssemblyID(1)) != default_hash(CB.AssemblyID(1))
end
