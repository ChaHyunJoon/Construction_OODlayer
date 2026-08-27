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

    # 2026-08-24 (spec §5.5, Task 6): grounding 키가 남은 두 사건(fault·battery)에 맞는지.
    # `emitted_key` 에 `SwapBattery` 분기가 없으면 battery grounding 이 **에러 없이** 0 이 된다.
    @testset "OOD grounding keys" begin
        include("ood_truth_keys.jl")
    end

    # 2026-08-24 (Task 6 수정 라운드 1, 판정 R-46): `policy.jl` 의 집행 가능 매크로 화이트리스트가
    # `action_registry.json`(어휘 단일 진실원)에 묶여 있는지. 리터럴로 되돌아가면 어휘 밖 팔이
    # **에러 없이** 집행돼 판에 거짓 라벨로 박힌다.
    @testset "policy macro whitelist ↔ action registry" begin
        include("policy_macro_binding.jl")
    end

    # 2026-08-26 (tool-lane step A, Task 1): 교정 파일이 없어도 event_descriptors_of 의
    # 결과가 route() 의 모든 반환 분기에 "descriptors" 키로 실리는지. 이 키가 빠지면 LLM 이
    # 문장 한 줄만 받고 숫자 서술자를 못 받는다(교정 유무와 서술자 계산이 한 게이트에 묶였던
    # 옛 결함의 재발 방지).
    @testset "router descriptors survive a missing calibration" begin
        include("route_descriptors_survive.jl")
    end

    # 🔴 2026-08-25 (최종 브랜치 리뷰 F1): 아래 셋은 **레지스트리 파생과 도장 계약을 지키는
    # 게이트인데 이 진입점에 실려 있지 않았다** — 누가 손으로 `julia +lts --project=.
    # test/<파일>.jl` 를 칠 때만 돌았다. "돌지 않는 게이트" 는 "실패할 수 없는 게이트" 의
    # 사촌이다(이 계획이 후자를 여섯 개 찾았다). 셋 다 단독 실행에서 초록임을 확인하고 싣는다.
    #   smdp_action_name_smoke : gen_oracle_dataset.jl 의 ACTION_NAME/MACRO_COST 가 레지스트리
    #                            파생인가 (리터럴이 되살아나면 라벨 행에 틀린 이름·비용이 찍힌다)
    #   smdp_stamp_smoke       : 어휘 도장 v4-3arms · 동역학 도장 · surrogate 산출물 도장
    #   smdp_hazard_knobs      : D-3/D-4/D-5 손잡이와 λ 단일 진실원, 라벨 레인 == 실행 레인
    @testset "SMDP action-name derivation" begin
        include("smdp_action_name_smoke.jl")
    end
    @testset "SMDP stamps" begin
        include("smdp_stamp_smoke.jl")
    end
    @testset "SMDP hazard knobs" begin
        include("smdp_hazard_knobs.jl")
    end

    # 🔴 2026-08-25 (R-66): `tools/test_policy_oracle.jl` 는 위 F1 배선에서 **빠진 네 번째
    # 고아 게이트**였다. 그 결과 `policy.jl` 의 `ORACLE_BATTERY_DEEP_SOC` 가 0.5 로 남아
    # `reference_policy.BATTERY_DEEP_SOC`(0.2)와 갈린 회귀가 최종 리뷰까지 살아남았다
    # (실효: `(0.2, 0.5]` 구간에서 oracle 레인은 팔을 내고 파이썬 채점기는 unscored 로 뺀다).
    # 두 언어의 그 임계값을 묶는 것은 이 게이트 0절 하나뿐이다 — 줄리아 쪽에서 파이썬 상수를
    # 유도할 수 없기 때문이다(이유는 policy.jl 의 그 상수 위 주석).
    #
    # 🔴 **하위 프로세스로 부른다(include 가 아니다).** 그 파일은 스크립트라 마지막 줄이
    # `exit(nfail == 0 ? 0 : 1)` 이다. 여기서 `include` 하면 초록일 때 `exit(0)` 이 걸려
    # **뒤따르는 테스트가 하나도 안 돌았는데 Pkg.test 는 성공으로 보인다** — include 배선은
    # 그 자체로 "실패할 수 없는 게이트" 를 하나 더 만드는 셈이다. 하위 프로세스는 종료코드를
    # 그대로 나르고, 그 파일이 심는 전역 로거·ENV 도 이쪽으로 새지 않는다.
    @testset "policy oracle lane (tools/test_policy_oracle.jl)" begin
        gate = normpath(joinpath(@__DIR__, "..", "tools", "test_policy_oracle.jl"))
        repo = normpath(joinpath(@__DIR__, ".."))
        @test isfile(gate)
        logf = tempname()
        ok = success(pipeline(`$(Base.julia_cmd()) --project=$(repo) $(gate)`;
                              stdout = logf, stderr = logf))
        txt = isfile(logf) ? read(logf, String) : ""
        # 요약 줄은 언제나 보여 준다(초록이어도 몇 개를 쟀는지가 보여야 한다).
        for l in split(txt, '\n')
            occursin("policy oracle lane:", l) && println("    ", strip(l))
        end
        ok || println("---- tools/test_policy_oracle.jl 전체 출력 ----\n", txt)
        @test ok
    end
end
