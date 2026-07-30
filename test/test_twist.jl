# ============================================================================
#  이 파일이 하는 일: "twist"(순간 속도 = 병진속도 + 각속도)를 이용해 한 자세(pose)에서
#  다른 자세로 이동/회전하는 로직이 수학적으로 맞는지 검증하는 단위 테스트.
#  프로젝트 속 역할: 로봇/운반유닛이 목표 자세로 부드럽게 다가갈 때 쓰는 optimal_twist /
#  integrate_twist 함수의 정확성 확인. twist 는 속도 제한(v_max, ω_max) 아래서 한 스텝(dt)씩
#  적분(integrate)하며 목표에 수렴해야 함.
#  Julia 문법 참고:
#   · ∘ : 함수 합성 연산자(수학의 f∘g). 여기선 변환(Translation·LinearMap)을 이어붙임.
#   · inv(a) : 변환 a 의 역변환. a 로 옮긴 걸 원래대로 되돌림.
#   · @test 표현식 : 표현식이 true 면 통과, false 면 실패로 기록하는 테스트 매크로.
#   · a(p) : 변환 a 를 점 p 에 적용(변환 객체를 함수처럼 호출).
#   · π 는 원주율, RotX/RotZ 는 x축/z축 기준 회전.
#   · array_isapprox : runtests.jl 에 정의된 헬퍼 — 두 배열이 오차범위 내면 true.
# ============================================================================

# twist 로 자세를 옮기는 세 방법(직접 계산·1스텝 점프·여러 스텝 누적)이 모두 목표 b 에 도달하는지 검증하는 블록.
let
    # Interpolate from one transform to another
    p = SVector(0.0, 1.0, 0.0) # point p starts at origin  # 테스트용 기준점(변환을 적용해 결과 비교)
    a = CoordinateTransformations.Translation(0, 2, 0) ∘ CoordinateTransformations.LinearMap(RotX(0.25 * π))  # 시작 자세 a: y로 2 이동 + x축 회전
    b = CoordinateTransformations.Translation(4, 0, 0) ∘ CoordinateTransformations.LinearMap(RotZ(0.75 * π))  # 목표 자세 b: x로 4 이동 + z축 회전
    t = inv(a) ∘ b  # a 기준에서 본 b 로의 상대 변환(a 를 없앤 뒤 b 로 가는 변환)
    @test array_isapprox(b(p), a(t(p)); atol=1e-6, rtol=1e-6)  # 정의상 b = a∘t 이므로 두 결과가 같아야 함

    # Jump straight from a to the goal
    dt = 0.2  # 한 스텝의 시간간격
    twist = optimal_twist(t, Inf, Inf, dt)  # 속도 제한이 무한(Inf)이면 한 번에 목표까지 가는 twist 를 얻음
    Δ = integrate_twist(twist, dt)          # 그 twist 를 dt 만큼 적분 → 실제 이동/회전 변환 Δ
    @test array_isapprox(b(p), a(Δ(p)); atol=1e-6, rtol=1e-6)  # a 에 Δ 를 더하면 목표 b 와 같아야 함

    # Now build to the goal transform incrementally
    v_max = 2.0  # 병진(직선) 속도 상한
    ω_max = 1.0  # 각(회전) 속도 상한
    c = a        # 현재 자세(시작은 a), 반복하며 목표에 다가감
    goal = b
    for k in 1:15  # 15스텝 동안 조금씩 이동/회전
        delta = inv(c) ∘ goal  # 현재 자세 c 에서 목표까지 남은 상대 변환
        twist = ConstructionBots.optimal_twist(delta, v_max, ω_max, dt)  # 속도 제한 안에서 최적 twist 계산
        Δ = ConstructionBots.integrate_twist(twist, dt)  # dt 만큼 적분한 이번 스텝의 이동량
        c = c ∘ Δ  # 현재 자세를 이번 스텝만큼 전진
    end
    @test array_isapprox(b(p), c(p); atol=1e-6, rtol=1e-6)  # 15스텝 뒤 누적 자세 c 가 목표 b 에 수렴했는지 확인

end
