# ============================================================================
#  이 파일이 하는 일: 씬 트리(scene tree)의 여러 "노드 타입"이 각자 고유한 ID를
#  제대로 만들어 내는지 확인하는 단위 테스트.
#  프로젝트 속 역할: ConstructionBots 는 로봇/부품/조립체를 그래프 노드로 다루는데,
#  각 노드는 node_id 로 구분됨. 서로 다른 종류의 스케줄 노드들이 만든 ID 들을
#  하나의 Set 에 모아 보며, 생성 과정에서 에러가 안 나는지 훑는 smoke 테스트.
#  Julia 문법 참고:
#   · let ... end : 지역 스코프 블록. 안에서 만든 변수는 밖으로 새지 않음(테스트 격리용).
#   · Module.Name : ConstructionBots.ObjectID 처럼 모듈 안의 이름을 점(.)으로 접근.
#   · Set{T}() : 원소 타입이 T 인 빈 집합 생성. AbstractID = 모든 ID 타입의 상위(추상) 타입.
#   · push!(s, x) : s 에 x 를 추가(!-접미사 = 인자를 직접 수정한다는 관례).
#   · [a, b, c] 안의 for 루프 : 배열 리터럴 안 요소들을 하나씩 순회.
# ============================================================================

# 여러 노드 타입의 ID 생성이 에러 없이 되고, 모은 ID 들이 Set 에 잘 담기는지 확인하는 블록.
let
    geom = LazySets.Ball2(zeros(SVector{3,Float64}), 1.0)  # 반지름 1인 3차원 공(근사 기하) — 모든 노드에 재사용
    o = ConstructionBots.ObjectNode(ConstructionBots.ObjectID(1), ConstructionBots.GeomNode(deepcopy(geom)))      # 부품(Object) 노드. deepcopy = 기하를 각자 독립 복사
    r = ConstructionBots.RobotNode(ConstructionBots.RobotID(1), ConstructionBots.GeomNode(deepcopy(geom)))        # 로봇(Robot) 노드
    a = ConstructionBots.AssemblyNode(ConstructionBots.AssemblyID(1), ConstructionBots.GeomNode(deepcopy(geom)))  # 조립체(Assembly) 노드
    t = ConstructionBots.TransportUnitNode(ConstructionBots.node_id(a))  # 운반유닛(TransportUnit) 노드 — 조립체 a 를 화물(cargo)로 지목

    s = Set{ConstructionBots.AbstractID}()  # 여러 종류의 ID 를 함께 담을 집합
    for n in [                              # 아래 각 스케줄 노드를 하나씩 만들어 순회
        ConstructionBots.ObjectStart(o),        # 부품이 시작 위치에 놓인 상태
        ConstructionBots.RobotStart(r),         # 로봇 시작 상태
        ConstructionBots.RobotGo(r),            # 로봇 이동 작업
        ConstructionBots.AssemblyStart(a),      # 조립 시작
        ConstructionBots.AssemblyComplete(a),   # 조립 완료
        ConstructionBots.LiftIntoPlace(a),      # 조립체를 들어 제자리에 끼우기
        ConstructionBots.LiftIntoPlace(o),      # 부품을 들어 제자리에 끼우기
        ConstructionBots.FormTransportUnit(t),  # 운반유닛 형성(로봇들이 화물을 들 준비)
        ConstructionBots.TransportUnitGo(t),    # 운반유닛 이동
        ConstructionBots.DepositCargo(t),       # 화물 내려놓기
    ]
        push!(s, ConstructionBots.node_id(n))  # 각 노드의 고유 ID 를 집합에 넣음(에러 없이 되면 통과)
    end
end
