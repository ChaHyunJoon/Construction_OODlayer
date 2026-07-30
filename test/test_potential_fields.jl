# ============================================================================
#  이 파일이 하는 일: "potential field(전위장/포텐셜 필드)" 계산이 맞는지 검증하는 단위 테스트.
#  프로젝트 속 역할: 로봇 충돌회피/유도에 쓰는 potential fields — 각 위치에서의 값 p(x)와
#  그 gradient(기울기, = 로봇이 밀려나는 방향/힘)를 여러 potential 종류마다 확인.
#  종류: ConePotential(원뿔), TentPotential(텐트/능선), RotationalPotential(회전),
#  BarrierPotential(장벽), 그리고 이들을 여러 개 겹친 superposition(중첩).
#  Julia 문법 참고:
#   · let ... end : 각 테스트 케이스를 독립 스코프로 격리(변수 이름 재사용 가능).
#   · p(x1) : potential 객체 p 를 위치 x1 에서 함수처럼 호출해 값을 얻음.
#   · potential_gradient(p, x) : p 의 x 지점 기울기(벡터). 방향 = 밀려나는 쪽.
#   · normalize(v) : 벡터를 크기 1로 정규화. norm(v) = 벡터 크기.
#   · isapprox(a, b; atol=..) : 부동소수 오차를 감안한 근사 같음 판정.
#   · [rp] 처럼 배열로 넘기면 "여러 potential 중첩" 버전이 호출됨(다중 디스패치).
# ============================================================================

using Test

# Cone potential
# ConePotential(원뿔형): 중심에서 멀어지는 방향의 기울기 크기가 1이고, 사거리 밖에선 0인지 검증하는 블록.
let
    p = ConstructionBots.ConePotential(-1.0,1.0,Point(0.0,0.0))  # (세기 -1, 반경 1, 중심 원점)인 원뿔 potential
    x1 = Point(0.5,0.5)                   # 사거리 안쪽 시험점
    d1 = normalize(Point(-1.0,-1.0))      # 기대되는 기울기 방향(중심 쪽, 정규화)

    y = p(x1)                             # 그 지점의 potential 값(여기선 크기 확인용으로만 호출)
    dx1 = ConstructionBots.potential_gradient(p,x1)  # x1 에서의 기울기 벡터
    @test isapprox(norm(dx1),1)                      # 원뿔은 기울기 크기가 일정(=1)해야 함
    @test isapprox(norm(dx1 - d1), 0.0, atol=1e-10)  # 방향도 기대값 d1 과 일치해야 함

    # out of range
    x2 = Point(2.0,2.0)                   # 반경 밖 시험점
    dx2 = ConstructionBots.potential_gradient(p, x2)
    @test isapprox(norm(dx2),0)           # 사거리 밖에선 힘이 0이어야 함

end
# Rotational Potential
# RotationalPotential(회전형): gradient 계산이 단일/배열 입력 모두 에러 없이 도는지 훑는 smoke 블록.
let
    p = ConstructionBots.ConePotential(-1.0,2.0,Point(0.0,0.0))  # 바탕이 되는 원뿔 potential
    rp = ConstructionBots.RotationalPotential(p,1.0,1.0)         # 그걸 회전시킨 potential 로 감쌈
    x = Point(1.0,1.0)
    ConstructionBots.potential_gradient(p,x)   # 원본에 대한 기울기(호출만, 예외 없는지 확인)

    ConstructionBots.potential_gradient(rp,x)    # 회전 potential 에 대한 기울기
    ConstructionBots.potential_gradient([rp],x)  # 배열로 넘기면 중첩(superposition) 버전 경로가 돎

end
# tent potential
# TentPotential(텐트/능선형): 능선과 수직인 방향으로 기울기가 나오는지, 사거리 밖은 0인지 검증하는 블록.
let
    p = ConstructionBots.TentPotential(-1.0,1.0,Point(0.0,0.0),Point(0.0,2.0))  # 두 점을 잇는 능선을 가진 텐트 potential
    x1 = Point(0.5,0.5)
    d1 = normalize(Point(-1.0,-0.0))  # 능선(세로선)에 수직인 기대 방향(x축 -방향)
    dx1 = ConstructionBots.potential_gradient(p, x1)
    @test isapprox(norm(dx1),1)                      # 기울기 크기 1
    @test isapprox(norm(dx1 - d1), 0.0, atol=1e-10)  # 방향 일치

    # out of range
    x2 = Point(2.0,2.0)
    dx2 = ConstructionBots.potential_gradient(p, x2)
    @test isapprox(norm(dx2),0)  # 사거리 밖 힘 0

end
# BarrierPotential
# BarrierPotential(장벽형): 중심에서의 potential 값이 이론식(c/z)과 맞는지 검증하는 블록.
let
    p = ConstructionBots.ConePotential(1.0,1.0,Point(0.0,0.0))
    pb = ConstructionBots.BarrierPotential(p,1.0,0.1)  # 원뿔을 감싼 장벽 potential (c=1.0, z=0.1)
    y = ConstructionBots.potential(pb,p.x)             # 원뿔 중심 p.x 에서 장벽 값
    @test isapprox(y,pb.c/pb.z,atol=1e-10)             # 중심에선 값이 c/z 로 떨어져야 함

end
# superposed potentials
# 여러 potential 을 배열로 겹쳤을 때, 전체 기울기가 각 기울기의 합과 같은지(선형 중첩) 검증하는 블록.
let
    p = [
        ConstructionBots.ConePotential(-1.0,1.0,Point(0.0,0.0)),                    # 원뿔
        ConstructionBots.TentPotential(-1.0,1.0,Point(0.0,0.0),Point(0.0,2.0))      # + 텐트
    ]
    x1 = Point(0.5,0.5)
    d1 = normalize(Point(-1.0,-1.0)) + normalize(Point(-1.0,-0.0))  # 각 potential 기울기 방향을 더한 기대값
    dx1 = ConstructionBots.potential_gradient(p, x1)  # 배열 입력 → 중첩된 총 기울기
    @test isapprox(norm(dx1 - d1), 0.0, atol=1e-10)   # 합과 일치해야 함(중첩 = 벡터 덧셈)
end
