# ============================================================================
#  이 파일이 하는 일: 패키지 전체 테스트의 "진입점(entry point)". `julia --project -e 'using Pkg; Pkg.test()'`
#  로 실행하면 이 파일이 돌며, 아래 @testset 들이 각 하위 테스트 파일을 include 해서 순서대로 돌림.
#  프로젝트 속 역할: IDs / Potential Fields / Twist / Demo 네 묶음을 한 번에 검증.
#  여기서는 여러 테스트가 공통으로 쓰는 헬퍼 array_isapprox(배열 근사비교)도 정의함.
#  Julia 문법 참고:
#   · using X : 패키지 X 를 불러와 이름을 현재 범위로 가져옴.
#   · @testset "이름" begin ... end : 테스트 묶음. 안의 @test 결과를 모아 요약 보고(중첩 가능).
#   · @inline function f(...) where {F<:AbstractFloat} : F 는 타입 파라미터(제네릭). where 로 F 를
#     "부동소수 하위 타입"으로 제약. @inline = 컴파일러에 인라인 힌트.
#   · f(x::AbstractArray{F}) vs f(x::AbstractArray{F}, y::F) : 인자 타입만 다른 두 메서드(다중 디스패치) —
#     "배열 vs 배열" 비교와 "배열 vs 단일값" 비교를 같은 이름으로 구분.
#   · zip(x,y) : 두 배열을 짝지어 동시 순회. eps(F) = F 타입의 기계 정밀도(아주 작은 수).
# ============================================================================

using ConstructionBots

using StaticArrays
using CoordinateTransformations
using GeometryBasics
using Rotations

using Graphs
using LazySets
using LinearAlgebra

using Test
using Logging

# Set logging level
global_logger(SimpleLogger(stderr, Logging.Warn))  # 테스트 중 로그는 Warn 이상만 출력(수다스러운 로그 억제)

# 두 배열 x, y 를 원소별로 근사 비교하는 헬퍼(길이 다르면 false). 테스트 전반에서 재사용.
@inline function array_isapprox(x::AbstractArray{F},
                  y::AbstractArray{F};
                  rtol::F=sqrt(eps(F)),   # 상대 허용오차(기본: 정밀도의 제곱근)
                  atol::F=zero(F)) where {F<:AbstractFloat}  # 절대 허용오차(기본 0)

    # Easy check on matching size
    if length(x) != length(y)  # 길이부터 다르면 비교 불가 → 바로 false
        return false
    end

    for (a,b) in zip(x,y)  # 두 배열을 짝지어 순회
        if !isapprox(a,b, rtol=rtol, atol=atol)  # 한 쌍이라도 오차범위 벗어나면
            return false
        end
    end
    return true  # 모두 근사 일치
end

# Check if array equals a single value
# 위 array_isapprox 의 다른 버전: 배열 x 의 모든 원소가 하나의 값 y 에 근사한지 검사(다중 디스패치).
@inline function array_isapprox(x::AbstractArray{F},
                  y::F;
                  rtol::F=sqrt(eps(F)),
                  atol::F=zero(F)) where {F<:AbstractFloat}

    for a in x  # 원소를 하나씩 y 와 비교
        if !isapprox(a, y, rtol=rtol, atol=atol)
            return false
        end
    end
    return true
end

# Define package tests
# 전체 테스트를 담는 최상위 묶음 — 아래 네 하위 묶음을 순서대로 include 해서 실행.
@testset "ConstructionBots Tests" begin
    @testset "IDs" begin                 # 노드 ID 생성 테스트
        include("test_ids.jl")
    end
    @testset "Potential Fields" begin     # potential field(충돌회피/유도) 테스트
        include("test_potential_fields.jl")
    end
    @testset "Twist" begin                # twist(속도)로 자세 이동 테스트
        include("test_twist.jl")
    end

    @testset "Demo" begin                 # 실제 레고 빌드 데모를 끝까지 돌리는 통합 테스트
        include("test_demo.jl")
    end
end
